# frozen_string_literal: true

require "cgi"
require "strscan"

require_relative "html_entities"

module RedQuilt
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
      # Same set as SPECIAL_BYTES, for String#byteindex to jump over long
      # plain-text runs at C speed.
      SPECIAL_BYTE_RE = /[*_`\[\]!<&\\\n~]/

      # Anchored regexes for StringScanner#scan (still used by
      # scan_angle / scan_amp). StringScanner anchors at the current pos,
      # so no `\G` is needed.
      #
      # URI autolink rejects every ASCII control char (U+0000-U+001F, U+007F)
      # plus space (U+0020); CommonMark 6.5 forbids ASCII control characters,
      # space, <, or >.
      URI_AUTOLINK_RE = /<([A-Za-z][A-Za-z0-9+.-]{1,31}:[^<>\u0000-\u0020\u007F]*)>/
      EMAIL_AUTOLINK_RE = /<([a-zA-Z0-9.!#$%&'*+\/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*)>/
      # CommonMark spec 6.6 "Raw HTML": six forms — open tag, closing tag,
      # HTML comment, processing instruction, declaration, CDATA section.
      # Attribute values are allowed to span lines.
      # HTML tag separators are restricted to space/tab/CR/LF per spec --
      # \s would also match form feed (U+000C) and vertical tab (U+000B),
      # which CommonMark disallows.
      HTML_OPEN_TAG_RE = %r{<[A-Za-z][A-Za-z0-9-]*(?:[ \t\r\n]+[A-Za-z_:][A-Za-z0-9_.:-]*(?:[ \t\r\n]*=[ \t\r\n]*(?:"[^"]*"|'[^']*'|[^ \t\r\n"'=<>`]+))?)*[ \t\r\n]*/?>}
      HTML_CLOSING_TAG_RE = %r{</[A-Za-z][A-Za-z0-9-]*[ \t\r\n]*>}
      # Comment: `<!-->`, `<!--->`, or `<!-- text -->` where text doesn't
      # start with `>` or `->`, end with `-`, or contain `--`.
      HTML_COMMENT_RE = %r{<!-->|<!--->|<!--(?!>)(?!->)[\s\S]*?(?<!-)-->}
      HTML_PROC_INST_RE = %r{<\?[\s\S]*?\?>}
      HTML_DECLARATION_RE = %r{<![A-Za-z][^>]*>}
      HTML_CDATA_RE = %r{<!\[CDATA\[[\s\S]*?\]\]>}
      ENTITY_RE = /&(?:[A-Za-z][A-Za-z0-9]+|#\d+|#[xX][0-9A-Fa-f]+);/

      def initialize(source)
        @source = source
        # A binary-encoded view for String#byteindex hot paths (byteindex
        # on a UTF-8 string raises when the offset falls inside a
        # multibyte sequence; binary treats every byte as its own char).
        @source_b = source.b
        @ss = StringScanner.new(source)
      end

      # Scans @source[start_byte...end_byte] and emits tokens.
      # Returns the tokens object that was passed in.
      def lex_into(tokens, start_byte, end_byte)
        @ss.pos = start_byte
        @start = start_byte
        @end = end_byte
        scan(tokens)
        tokens
      end

      private

      def scan(tokens)
        # Hot loop. `pos` is the source of truth during the scan; @ss.pos
        # is only synced when entering scan_angle / scan_amp (which still
        # use StringScanner for the regex match) and at loop exit. The
        # other scan_* helpers take `pos` as an arg and return the new
        # position, so the round-trip through @ss.pos is avoided.
        pos = @ss.pos
        end_pos = @end
        while pos < end_pos
          byte = @source.getbyte(pos)
          case byte
          when 0x0A # \n
            pos = scan_line_ending(tokens, pos)
          when 0x5C # \\ (backslash)
            pos = scan_backslash(tokens, pos, end_pos)
          when 0x60 # `
            pos = scan_code_delimiter(tokens, pos, end_pos)
          when 0x2A # *
            pos = scan_delim_run(tokens, pos, end_pos, "*", 0x2A)
          when 0x5F # _
            pos = scan_delim_run(tokens, pos, end_pos, "_", 0x5F)
          when 0x7E # ~ (GFM strikethrough)
            pos = scan_delim_run(tokens, pos, end_pos, "~", 0x7E)
          when 0x5B # [
            tokens.emit(TokenKind::LBRACKET, start_byte: pos, end_byte: pos + 1)
            pos += 1
          when 0x5D # ]
            tokens.emit(TokenKind::RBRACKET, start_byte: pos, end_byte: pos + 1)
            pos += 1
          when 0x21 # !
            pos = scan_bang(tokens, pos, end_pos)
          when 0x3C # <
            @ss.pos = pos
            scan_angle(tokens)
            pos = @ss.pos
          when 0x26 # &
            @ss.pos = pos
            scan_amp(tokens)
            pos = @ss.pos
          else
            # Inlined scan_text. Always make progress: consume the
            # current byte, then byteindex against the binary view to
            # leap to the next special byte at C speed.
            start = pos
            pos += 1
            if pos < end_pos
              next_special = @source_b.byteindex(SPECIAL_BYTE_RE, pos)
              pos = next_special.nil? || next_special >= end_pos ? end_pos : next_special
            end
            tokens.emit(TokenKind::TEXT, start_byte: start, end_byte: pos)
          end
        end
        @ss.pos = pos
      end

      def scan_line_ending(tokens, pos)
        # Count trailing ASCII spaces immediately before the newline; the
        # builder uses this to decide softbreak vs hardbreak (>= 2 spaces).
        trailing_spaces = 0
        i = pos - 1
        while i >= 0 && @source.getbyte(i) == 0x20
          trailing_spaces += 1
          i -= 1
        end
        new_pos = pos + 1
        tokens.emit(TokenKind::LINE_ENDING,
                    start_byte: pos, end_byte: new_pos,
                    int1: trailing_spaces)
        new_pos
      end

      def scan_backslash(tokens, pos, end_pos)
        nxt_pos = pos + 1
        if nxt_pos >= end_pos
          tokens.emit(TokenKind::TEXT, start_byte: pos, end_byte: nxt_pos)
          return nxt_pos
        end

        nxt = @source.getbyte(nxt_pos)
        if nxt == 0x0A
          # "\\\n" → hardbreak (backslash form). int2 = 1 signals the form.
          tokens.emit(TokenKind::LINE_ENDING,
                      start_byte: pos, end_byte: nxt_pos + 1,
                      int1: 0, int2: 1)
          nxt_pos + 1
        elsif ascii_punct?(nxt)
          tokens.emit(TokenKind::ESCAPED_CHAR,
                      start_byte: pos, end_byte: nxt_pos + 1,
                      str1: nxt.chr)
          nxt_pos + 1
        else
          tokens.emit(TokenKind::TEXT, start_byte: pos, end_byte: nxt_pos)
          nxt_pos
        end
      end

      def scan_code_delimiter(tokens, pos, end_pos)
        # Manual byte loop. Backtick runs are usually short (1-3 bytes),
        # so a regex skip's setup cost outweighs the per-byte compare.
        i = pos
        while i < end_pos && @source.getbyte(i) == 0x60
          i += 1
        end
        tokens.emit(TokenKind::CODE_DELIMITER,
                    start_byte: pos, end_byte: i,
                    int1: i - pos)
        i
      end

      def scan_delim_run(tokens, pos, end_pos, char, byte)
        i = pos
        while i < end_pos && @source.getbyte(i) == byte
          i += 1
        end
        count = i - pos
        prev_char = Flanking.char_before(@source, pos, @start)
        next_char = Flanking.char_at(@source, i, end_pos)
        can_open, can_close = Flanking.can_open_close(char, prev_char, next_char)
        # A run that can neither open nor close (e.g. underscores inside
        # a word) can never participate in emphasis, so emit it as plain
        # TEXT to allow text coalescing with neighbours.
        if !can_open && !can_close
          tokens.emit(TokenKind::TEXT, start_byte: pos, end_byte: i)
          return i
        end
        flags = (can_open ? 0b10 : 0) | (can_close ? 0b01 : 0)
        tokens.emit(TokenKind::DELIM_RUN,
                    start_byte: pos, end_byte: i,
                    int1: byte, int2: count, int3: flags)
        i
      end

      def scan_bang(tokens, pos, end_pos)
        if pos + 1 < end_pos && @source.getbyte(pos + 1) == 0x5B # [
          tokens.emit(TokenKind::BANG_LBRACKET, start_byte: pos, end_byte: pos + 2)
          pos + 2
        else
          tokens.emit(TokenKind::TEXT, start_byte: pos, end_byte: pos + 1)
          pos + 1
        end
      end

      def scan_angle(tokens)
        start = @ss.pos
        if scan_within_end(URI_AUTOLINK_RE)
          tokens.emit(TokenKind::AUTOLINK_URI,
                      start_byte: start, end_byte: @ss.pos,
                      str1: @ss[1])
        elsif scan_within_end(EMAIL_AUTOLINK_RE)
          tokens.emit(TokenKind::AUTOLINK_EMAIL,
                      start_byte: start, end_byte: @ss.pos,
                      str1: @ss[1])
        elsif (matched = scan_within_end(HTML_OPEN_TAG_RE)) ||
              (matched = scan_within_end(HTML_CLOSING_TAG_RE)) ||
              (matched = scan_within_end(HTML_COMMENT_RE)) ||
              (matched = scan_within_end(HTML_PROC_INST_RE)) ||
              (matched = scan_within_end(HTML_DECLARATION_RE)) ||
              (matched = scan_within_end(HTML_CDATA_RE))
          tokens.emit(TokenKind::HTML_INLINE,
                      start_byte: start, end_byte: @ss.pos,
                      str1: matched)
        else
          @ss.pos += 1
          tokens.emit(TokenKind::TEXT, start_byte: start, end_byte: @ss.pos)
        end
      end

      def scan_amp(tokens)
        start = @ss.pos
        if (matched = scan_within_end(ENTITY_RE))
          tokens.emit(TokenKind::ENTITY,
                      start_byte: start, end_byte: @ss.pos,
                      str1: decode_entity(matched))
        else
          @ss.pos += 1
          tokens.emit(TokenKind::TEXT, start_byte: start, end_byte: @ss.pos)
        end
      end

      # StringScanner#scan but constrained to @end. Returns the matched
      # string on success (rewinding when the match extends past @end),
      # nil otherwise.
      def scan_within_end(regex)
        before = @ss.pos
        matched = @ss.scan(regex)
        return nil unless matched
        if @ss.pos > @end
          @ss.pos = before
          return nil
        end
        matched
      end

      # Decodes a single entity reference. CommonMark requires the full
      # HTML5 named-entity set, plus the numeric forms. U+0000 is
      # replaced with U+FFFD; unknown names fall through unchanged.
      def decode_entity(raw)
        if raw.start_with?("&#")
          decoded = CGI.unescapeHTML(raw)
          return decoded.tr("\u0000", "\uFFFD")
        end
        encoded = HTML_ENTITIES[raw[1..-2]]
        return raw unless encoded
        encoded.dup.force_encoding(Encoding::UTF_8)
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
