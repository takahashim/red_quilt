# frozen_string_literal: true

module RedQuilt
  # GFM table detection (spec 4.10). Pure functions over line text: whether
  # a line could be a table row and whether a header+delimiter pair starts a
  # table. Cell splitting lives here too so the recognition rules and the
  # splitting rules they depend on stay together. Node construction stays in
  # BlockParser.
  module Table
    module_function

    # True when lines[index] / lines[index+1] form a header + delimiter pair
    # that starts a GFM table.
    def start?(lines, index)
      return false if index + 1 >= lines.length
      return false unless row?(lines[index].content)

      header_cells = split_row(lines[index].content)
      separators = split_row(lines[index + 1].content)
      return false if separators.empty?

      # GFM spec: separator row must have valid delimiters AND match header column count.
      # "The header row must match the delimiter row in the number of cells.
      #  If not, a table will not be recognized."
      return false unless header_cells.length == separators.length

      separators.all? { |cell| cell.strip.match?(/\A:?-+:?\z/) }
    end

    def row?(text)
      text.include?("|")
    end

    def split_row(text)
      body = text.strip
      body = body[1..] if body.start_with?("|")
      body = body[0...-1] if body.end_with?("|")
      body.split("|", -1)
    end

    # Cached collaborator for BlockParser. A single instance is created in
    # BlockParser#initialize and reused; per-call state lives in method
    # locals so reentrant calls are safe.
    class Parser
      def initialize(block_parser)
        @arena = block_parser.arena
      end

      # Parses the table starting at lines[index] (already confirmed by
      # Table.start?). Returns the index past the table.
      def parse(parent_id, lines, index)
        start_index = index
        header_cells = Table.split_row(lines[index].content)
        row_lines = [lines[index]]
        index += 2
        while index < lines.length
          break if lines[index].blank
          break unless Table.row?(lines[index].content)

          row_lines << lines[index]
          index += 1
        end

        table_id = @arena.add_node(NodeType::TABLE,
                                   source_start: lines[start_index].start_byte,
                                   source_len: row_lines.last.end_byte - lines[start_index].start_byte)
        @arena.append_child(parent_id, table_id)

        append_row(table_id, lines[start_index], header_cells, true)
        row_lines.drop(1).each do |row_line|
          append_row(table_id, row_line, Table.split_row(row_line.content), false)
        end

        index
      end

      private

      def append_row(table_id, line, cells, header)
        row_id = @arena.add_node(NodeType::TABLE_ROW,
                                 source_start: line.start_byte,
                                 source_len: line.span_len,
                                 int1: header ? 1 : 0)
        @arena.append_child(table_id, row_id)
        cells.each do |cell_text|
          stripped = cell_text.strip
          cell_id = @arena.add_node(NodeType::TABLE_CELL,
                                    source_start: line.start_byte,
                                    source_len: line.span_len,
                                    int1: header ? 1 : 0,
                                    str1: stripped)
          @arena.append_child(row_id, cell_id)
        end
      end
    end
  end
end
