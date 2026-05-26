# frozen_string_literal: true

module Mdarena
  module Inline
    # CommonMark spec 6.2 flanking delimiter run helpers.
    #
    # Determines whether a delimiter run can open and/or close an emphasis.
    # All input positions are byte offsets into the document source.
    module Flanking
      UNICODE_WHITESPACE_RE = /\A[\s   -   　]\z/.freeze
      # CommonMark 0.31.2 expanded the definition of "punctuation" for
      # flanking purposes to also include Unicode S (symbol) category, so
      # currency / math / other symbols form delimiter-run boundaries.
      UNICODE_PUNCT_RE = /\A[\p{P}\p{S}]\z/.freeze

      module_function

      # Returns the character immediately before the byte position, or nil
      # if at the start of source / outside the inline range.
      def char_before(source, byte_pos, range_start)
        return nil if byte_pos <= range_start

        # Walk back at most 4 bytes to find a UTF-8 code point start.
        i = byte_pos - 1
        while i >= range_start && i > byte_pos - 4
          b = source.getbyte(i)
          # Code point start: ASCII (0xxxxxxx) or 11xxxxxx
          if b < 0x80 || b >= 0xC0
            return source.byteslice(i, byte_pos - i)
          end
          i -= 1
        end
        nil
      end

      # Returns the character at the byte position, or nil if past range_end.
      def char_at(source, byte_pos, range_end)
        return nil if byte_pos >= range_end

        b = source.getbyte(byte_pos)
        len = if b < 0x80
                1
              elsif b < 0xC0
                # mid-sequence byte; should not happen at a code point start
                1
              elsif b < 0xE0
                2
              elsif b < 0xF0
                3
              else
                4
              end
        source.byteslice(byte_pos, [len, range_end - byte_pos].min)
      end

      def whitespace?(char)
        return true if char.nil? # line start / line end count as whitespace
        UNICODE_WHITESPACE_RE.match?(char)
      end

      def punctuation?(char)
        return false if char.nil?
        UNICODE_PUNCT_RE.match?(char)
      end

      # CommonMark spec: left-flanking delimiter run.
      def left_flanking?(prev_char, next_char)
        return false if whitespace?(next_char)
        return true unless punctuation?(next_char)
        whitespace?(prev_char) || punctuation?(prev_char)
      end

      # CommonMark spec: right-flanking delimiter run.
      def right_flanking?(prev_char, next_char)
        return false if whitespace?(prev_char)
        return true unless punctuation?(prev_char)
        whitespace?(next_char) || punctuation?(next_char)
      end

      # Returns [can_open, can_close] for a delimiter run.
      #
      # char must be "*", "_", or "~". For "_", word-character adjacency
      # rules apply on top of the flanking rules; "*" and "~" use plain
      # flanking only.
      def can_open_close(char, prev_char, next_char)
        left = left_flanking?(prev_char, next_char)
        right = right_flanking?(prev_char, next_char)
        if char == "_"
          can_open = left && (!right || punctuation?(prev_char))
          can_close = right && (!left || punctuation?(next_char))
        else
          can_open = left
          can_close = right
        end
        [can_open, can_close]
      end
    end
  end
end
