# frozen_string_literal: true

module RedQuilt
  module Inline
    # CommonMark spec 6.2 flanking delimiter run helpers.
    #
    # Determines whether a delimiter run can open and/or close an emphasis.
    # All input positions are byte offsets into the document source.
    module Flanking
      UNICODE_WHITESPACE_RE = /\A[\s   -   　]\z/
      # CommonMark 0.31.2 expanded the definition of "punctuation" for
      # flanking purposes to also include Unicode S (symbol) category, so
      # currency / math / other symbols form delimiter-run boundaries.
      UNICODE_PUNCT_RE = /\A[\p{P}\p{S}]\z/

      # Fast-path lookup tables for ASCII bytes. Flanking inputs are mostly
      # single-byte ASCII; the tables let us skip regex matches entirely
      # on the hot path.
      ASCII_WHITESPACE = Array.new(128, false)
      [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20].each { |b| ASCII_WHITESPACE[b] = true }
      ASCII_WHITESPACE.freeze

      ASCII_PUNCT = Array.new(128, false)
      (0x21..0x2F).each { |b| ASCII_PUNCT[b] = true }
      (0x3A..0x40).each { |b| ASCII_PUNCT[b] = true }
      (0x5B..0x60).each { |b| ASCII_PUNCT[b] = true }
      (0x7B..0x7E).each { |b| ASCII_PUNCT[b] = true }
      ASCII_PUNCT.freeze

      module_function

      # Returns the character immediately before the byte position, or nil
      # if at the start of source / outside the inline range.
      def char_before(source, byte_pos, range_start)
        return nil if byte_pos <= range_start

        prev = byte_pos - 1
        b = source.getbyte(prev)
        # ASCII fast path: 1-byte chr (avoids byteslice).
        return b.chr if b < 0x80

        # Walk back at most 4 bytes to find the UTF-8 code point start.
        i = prev
        while i >= range_start && i > byte_pos - 4
          b = source.getbyte(i)
          if b < 0x80 || b >= 0xC0
            return source.byteslice(i, byte_pos - i)
          end

          i -= 1
        end
        nil
      end

      def char_at(source, byte_pos, range_end)
        return nil if byte_pos >= range_end

        b = source.getbyte(byte_pos)
        return b.chr if b < 0x80

        len = if b < 0xC0
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
        return true if char.nil?
        if char.bytesize == 1
          return ASCII_WHITESPACE[char.getbyte(0)]
        end

        UNICODE_WHITESPACE_RE.match?(char)
      end

      def punctuation?(char)
        return false if char.nil?
        if char.bytesize == 1
          return ASCII_PUNCT[char.getbyte(0)]
        end

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
