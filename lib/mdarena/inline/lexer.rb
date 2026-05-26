# frozen_string_literal: true

require "cgi"

module Mdarena
  module Inline
    # Scans a byte range of the document source and emits inline tokens
    # into a caller-owned Tokens storage.
    #
    # The lexer never copies the source string; all positions are absolute
    # byte offsets into @source. The caller is responsible for clearing the
    # Tokens storage between invocations if it is being reused.
    class Lexer
      # Bytes whose appearance ends a TEXT run. Anything not in this set is
      # plain text content. Newline is included so LINE_ENDING gets its own
      # token.
      SPECIAL_BYTES = begin
        a = Array.new(256, false)
        # *, _, `, [, ], !, <, &, \, \n, ~ (GFM strikethrough)
        [0x2A, 0x5F, 0x60, 0x5B, 0x5D, 0x21, 0x3C, 0x26, 0x5C, 0x0A, 0x7E].each { |b| a[b] = true }
        a.freeze
      end

      # \G-anchored regexes reused from the legacy InlineParser. Each is
      # invoked with String#match(re, @pos), so the match must begin at
      # @pos and not extend past @end.
      URI_AUTOLINK_RE = /\G<([A-Za-z][A-Za-z0-9+.-]{1,31}:[^<>\u0000-\u0020]*)>/.freeze
      EMAIL_AUTOLINK_RE = /\G<([a-zA-Z0-9.!#$%&'*+\/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*)>/.freeze
      HTML_TAG_RE = %r{\G</?[A-Za-z][A-Za-z0-9-]*(?:\s+[A-Za-z_:][A-Za-z0-9_.:-]*(?:\s*=\s*(?:"[^"\n]*"|'[^'\n]*'|[^\s"'=<>`]+))?)*\s*/?>}.freeze
      ENTITY_RE = /\G&(?:[A-Za-z][A-Za-z0-9]+|#\d+|#x[0-9A-Fa-f]+);/.freeze

      def initialize(source)
        @source = source
      end

      # Scans @source[start_byte...end_byte] and emits tokens.
      # Returns the tokens object that was passed in.
      def lex_into(tokens, start_byte, end_byte)
        @pos = start_byte
        @start = start_byte
        @end = end_byte
        scan(tokens)
        tokens
      end

      private

      def scan(tokens)
        until @pos >= @end
          byte = @source.getbyte(@pos)
          case byte
          when 0x0A # \n
            scan_line_ending(tokens)
          when 0x5C # \\ (backslash)
            scan_backslash(tokens)
          when 0x60 # `
            scan_code_delimiter(tokens)
          when 0x2A # *
            scan_delim_run(tokens, "*", 0x2A)
          when 0x5F # _
            scan_delim_run(tokens, "_", 0x5F)
          when 0x7E # ~ (GFM strikethrough)
            scan_delim_run(tokens, "~", 0x7E)
          when 0x5B # [
            scan_one_byte_token(tokens, TokenKind::LBRACKET)
          when 0x5D # ]
            scan_one_byte_token(tokens, TokenKind::RBRACKET)
          when 0x21 # !
            scan_bang(tokens)
          when 0x3C # <
            scan_angle(tokens)
          when 0x26 # &
            scan_amp(tokens)
          else
            scan_text(tokens)
          end
        end
      end

      def scan_text(tokens)
        start = @pos
        # Always make progress: consume the current byte even if it's a
        # "special" byte that fell through to scan_text (e.g. a `&` that
        # didn't match ENTITY_RE). Subsequent bytes are added to the TEXT
        # run until we hit a special byte. Byte-by-byte walk avoids the
        # String#index pitfall of char vs byte offsets on multibyte input.
        @pos += 1 if @pos < @end
        while @pos < @end
          b = @source.getbyte(@pos)
          break if SPECIAL_BYTES[b]
          @pos += 1
        end
        tokens.emit(TokenKind::TEXT, start_byte: start, end_byte: @pos) if @pos > start
      end

      def scan_line_ending(tokens)
        start = @pos
        @pos += 1
        # Count trailing ASCII spaces immediately before the newline; the
        # builder uses this to decide softbreak vs hardbreak (>= 2 spaces).
        trailing_spaces = 0
        i = start - 1
        while i >= 0 && @source.getbyte(i) == 0x20
          trailing_spaces += 1
          i -= 1
        end
        tokens.emit(TokenKind::LINE_ENDING,
                    start_byte: start, end_byte: @pos,
                    int1: trailing_spaces)
      end

      def scan_backslash(tokens)
        start = @pos
        nxt_pos = start + 1
        if nxt_pos >= @end
          tokens.emit(TokenKind::TEXT, start_byte: start, end_byte: nxt_pos)
          @pos = nxt_pos
          return
        end

        nxt = @source.getbyte(nxt_pos)
        if nxt == 0x0A
          # "\\\n" → hardbreak (backslash form). int2 = 1 signals the form.
          @pos = nxt_pos + 1
          tokens.emit(TokenKind::LINE_ENDING,
                      start_byte: start, end_byte: @pos,
                      int1: 0, int2: 1)
        elsif ascii_punct?(nxt)
          @pos = nxt_pos + 1
          tokens.emit(TokenKind::ESCAPED_CHAR,
                      start_byte: start, end_byte: @pos,
                      str1: nxt.chr)
        else
          tokens.emit(TokenKind::TEXT, start_byte: start, end_byte: nxt_pos)
          @pos = nxt_pos
        end
      end

      def scan_code_delimiter(tokens)
        start = @pos
        @pos += 1 while @pos < @end && @source.getbyte(@pos) == 0x60
        tokens.emit(TokenKind::CODE_DELIMITER,
                    start_byte: start, end_byte: @pos,
                    int1: @pos - start)
      end

      def scan_delim_run(tokens, char, byte)
        start = @pos
        @pos += 1 while @pos < @end && @source.getbyte(@pos) == byte
        count = @pos - start
        prev_char = Flanking.char_before(@source, start, @start)
        next_char = Flanking.char_at(@source, @pos, @end)
        can_open, can_close = Flanking.can_open_close(char, prev_char, next_char)
        # A run that can neither open nor close (e.g. underscores inside a
        # word) can never participate in emphasis, so emit it as plain TEXT
        # to allow text coalescing with neighbours.
        if !can_open && !can_close
          tokens.emit(TokenKind::TEXT, start_byte: start, end_byte: @pos)
          return
        end
        flags = (can_open ? 0b10 : 0) | (can_close ? 0b01 : 0)
        tokens.emit(TokenKind::DELIM_RUN,
                    start_byte: start, end_byte: @pos,
                    int1: byte, int2: count, int3: flags)
      end

      def scan_one_byte_token(tokens, kind)
        start = @pos
        @pos += 1
        tokens.emit(kind, start_byte: start, end_byte: @pos)
      end

      def scan_bang(tokens)
        start = @pos
        if @pos + 1 < @end && @source.getbyte(@pos + 1) == 0x5B # [
          @pos += 2
          tokens.emit(TokenKind::BANG_LBRACKET, start_byte: start, end_byte: @pos)
        else
          @pos += 1
          tokens.emit(TokenKind::TEXT, start_byte: start, end_byte: @pos)
        end
      end

      def scan_angle(tokens)
        start = @pos
        if (m = match_at(URI_AUTOLINK_RE))
          @pos = m.end(0)
          tokens.emit(TokenKind::AUTOLINK_URI,
                      start_byte: start, end_byte: @pos,
                      str1: m[1])
        elsif (m = match_at(EMAIL_AUTOLINK_RE))
          @pos = m.end(0)
          tokens.emit(TokenKind::AUTOLINK_EMAIL,
                      start_byte: start, end_byte: @pos,
                      str1: m[1])
        elsif (m = match_at(HTML_TAG_RE))
          @pos = m.end(0)
          tokens.emit(TokenKind::HTML_INLINE,
                      start_byte: start, end_byte: @pos,
                      str1: m[0])
        else
          @pos += 1
          tokens.emit(TokenKind::TEXT, start_byte: start, end_byte: @pos)
        end
      end

      def scan_amp(tokens)
        start = @pos
        if (m = match_at(ENTITY_RE))
          @pos = m.end(0)
          tokens.emit(TokenKind::ENTITY,
                      start_byte: start, end_byte: @pos,
                      str1: CGI.unescapeHTML(m[0]))
        else
          @pos += 1
          tokens.emit(TokenKind::TEXT, start_byte: start, end_byte: @pos)
        end
      end

      # Returns a MatchData for a \G-anchored regex applied at @pos, or nil
      # if no match or if the match would extend past @end.
      def match_at(regex)
        m = regex.match(@source, @pos)
        return nil unless m
        return nil if m.end(0) > @end
        m
      end

      def ascii_punct?(byte)
        # !-/ : 0x21..0x2F
        # :-@ : 0x3A..0x40
        # [-` : 0x5B..0x60
        # {-~ : 0x7B..0x7E
        (byte >= 0x21 && byte <= 0x2F) ||
          (byte >= 0x3A && byte <= 0x40) ||
          (byte >= 0x5B && byte <= 0x60) ||
          (byte >= 0x7B && byte <= 0x7E)
      end
    end
  end
end
