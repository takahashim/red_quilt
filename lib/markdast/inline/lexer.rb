# frozen_string_literal: true

module Markdast
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
      SPECIAL_RE = /[*_`\[\]!<&\\\n]/.freeze

      # ASCII punctuation that is allowed to follow a backslash as an
      # escaped character per CommonMark.
      ASCII_PUNCT_RE = /[!-\/:-@\[-`{-~]/.freeze

      def initialize(source)
        @source = source
      end

      # Scans @source[start_byte...end_byte] and emits tokens.
      # Returns the tokens object that was passed in.
      def lex_into(tokens, start_byte, end_byte)
        @pos = start_byte
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
          else
            # TODO(commit 3..4): handle other special bytes here.
            # For now, treat any non-newline / non-backslash byte as text.
            scan_text(tokens)
          end
        end
      end

      def scan_text(tokens)
        start = @pos
        # Search from @pos + 1 so we always make forward progress, even if
        # the current byte is itself "special" (handlers for *, _, etc. are
        # added by commits 3 and 4; until then they fall through to this
        # method and need to be consumed as plain text).
        nxt = @source.index(SPECIAL_RE, @pos + 1)
        @pos = nxt && nxt < @end ? nxt : @end
        @pos = start + 1 if @pos == start && @pos < @end
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
          # Trailing backslash at end of range — treat as plain text.
          tokens.emit(TokenKind::TEXT, start_byte: start, end_byte: nxt_pos)
          @pos = nxt_pos
          return
        end

        nxt = @source.getbyte(nxt_pos)
        if nxt == 0x0A
          # "\\\n" → hardbreak. Emit a LINE_ENDING that carries the
          # hardbreak intent via int2 = 1 (backslash form).
          @pos = nxt_pos + 1
          tokens.emit(TokenKind::LINE_ENDING,
                      start_byte: start, end_byte: @pos,
                      int1: 0, int2: 1)
        elsif ascii_punct?(nxt)
          # "\X" where X is ASCII punct → ESCAPED_CHAR; str1 holds the
          # decoded character (1 byte, ASCII).
          @pos = nxt_pos + 1
          tokens.emit(TokenKind::ESCAPED_CHAR,
                      start_byte: start, end_byte: @pos,
                      str1: nxt.chr)
        else
          # "\X" where X is not punct → treat the backslash as literal text;
          # the following byte will be picked up on the next iteration.
          tokens.emit(TokenKind::TEXT, start_byte: start, end_byte: nxt_pos)
          @pos = nxt_pos
        end
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
