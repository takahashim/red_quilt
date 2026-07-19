# frozen_string_literal: true

module RedQuilt
  # Translates byte offsets from SourceSpan into human-facing positions.
  #
  # Positions follow the unist Point convention, which cmark sourcepos and
  # mdast both use: `line` and `column` are 1-based, while character offsets
  # are 0-based. Columns and offsets are counted in characters, not bytes, so
  # a multibyte source reports the position a reader would count.
  class SourceMap
    def initialize(source)
      @source = source
      @line_starts = build_line_starts(source)
      @line_char_starts = build_line_char_starts(source, @line_starts)
    end

    # Returns { line:, column: }, both 1-based.
    def line_column(byte_offset)
      line = line_index(byte_offset)
      { line: line + 1, column: chars_from_line_start(line, byte_offset) + 1 }
    end

    # Returns the 0-based character offset, as unist Point#offset requires.
    # Byte offsets are what SourceSpan carries, and the two differ as soon as
    # the source contains a multibyte character.
    def char_offset(byte_offset)
      line = line_index(byte_offset)
      @line_char_starts[line] + chars_from_line_start(line, byte_offset)
    end

    private

    def line_index(byte_offset)
      (@line_starts.bsearch_index { |s| s > byte_offset } || @line_starts.length) - 1
    end

    def chars_from_line_start(line, byte_offset)
      line_start = @line_starts[line]
      @source.byteslice(line_start, byte_offset - line_start).to_s.length
    end

    # Line starts are byte offsets, matching SourceSpan#start_byte / #end_byte
    # and the argument of #line_column. Scanning the binary view is what makes
    # them bytes: index on a UTF-8 string counts characters, so a multibyte
    # source would yield offsets that line_column then misreads as bytes.
    def build_line_starts(source)
      starts = [0]
      source_b = source.b
      pos = 0
      while (idx = source_b.index("\n", pos))
        starts << (idx + 1)
        pos = idx + 1
      end
      starts
    end

    # Character offset of each line start, so char_offset stays O(1) per call
    # instead of recounting the source prefix every time.
    def build_line_char_starts(source, line_starts)
      chars = 0
      prev_byte = 0
      line_starts.map do |byte_start|
        chars += source.byteslice(prev_byte, byte_start - prev_byte).to_s.length
        prev_byte = byte_start
        chars
      end
    end
  end
end
