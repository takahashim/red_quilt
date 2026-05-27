# frozen_string_literal: true

module RedQuilt
  class SourceMap
    def initialize(source)
      @source = source
      @line_starts = build_line_starts(source)
    end

    def line_column(byte_offset)
      line = (@line_starts.bsearch_index { |s| s > byte_offset } || @line_starts.length) - 1
      line_start = @line_starts[line]
      column = @source.byteslice(line_start, byte_offset - line_start).to_s.length
      { line: line + 1, column: column }
    end

    private

    def build_line_starts(source)
      starts = [0]
      pos = 0
      while (idx = source.index("\n", pos))
        starts << idx + 1
        pos = idx + 1
      end
      starts
    end
  end
end
