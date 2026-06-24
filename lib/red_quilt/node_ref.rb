# frozen_string_literal: true

module RedQuilt
  class NodeRef
    include Enumerable

    attr_reader :document, :node_id

    def initialize(document, node_id)
      @document = document
      @arena = document.arena
      @node_id = node_id
    end

    def each(&)
      walk(&)
    end

    def type
      @arena.type_name(@node_id)
    end

    def children
      @arena.child_ids(@node_id).map { |child_id| NodeRef.new(@document, child_id) }
    end

    def walk(&block)
      return enum_for(:walk) unless block_given?

      yield self
      @arena.child_ids(@node_id).each do |child_id|
        NodeRef.new(@document, child_id).walk(&block)
      end
    end

    def text
      first_child_id = @arena.raw_first_child_id(@node_id)
      return @arena.text(@node_id) if first_child_id == -1

      text = +""
      @arena.child_ids(@node_id).each do |child_id|
        child = NodeRef.new(@document, child_id)
        fragment = child.text
        text << fragment.to_s unless fragment.nil?
      end
      text
    end

    # Returns the fence info string of a CODE_BLOCK node.
    def info
      return "" unless @arena.type(@node_id) == NodeType::CODE_BLOCK

      @arena.code_block_info(@node_id).to_s
    end

    def source_span
      @arena.source_span(@node_id)
    end

    def find_all(type)
      walk.select { |node| node.type == type }
    end

    def source_location
      span = source_span
      return nil unless span

      start_loc = @document.source_map.line_column(span.start_byte)
      end_loc = @document.source_map.line_column(span.end_byte)

      {
        start_line: start_loc[:line],
        start_column: start_loc[:column],
        end_line: end_loc[:line],
        end_column: end_loc[:column],
      }
    end

    def to_h
      ast = {
        type: type,
        source_span: source_span,
        children: children.map(&:to_h),
      }

      attributes = ast_attributes
      ast[:attributes] = attributes unless attributes.empty?
      ast
    end

    private

    def ast_attributes
      case @arena.type(@node_id)
      when NodeType::HEADING
        { level: @arena.heading_level(@node_id), text: text }
      when NodeType::LIST
        {
          ordered: @arena.list_ordered?(@node_id),
          start_number: @arena.list_start(@node_id),
          tight: @arena.list_tight?(@node_id),
          delimiter: @arena.list_delimiter(@node_id),
        }
      when NodeType::TABLE_ROW
        { header: @arena.table_row_header?(@node_id), text: text }
      when NodeType::TABLE_CELL
        { header: @arena.table_cell_header?(@node_id), text: text }
      when NodeType::TEXT, NodeType::CODE_SPAN, NodeType::HTML_BLOCK, NodeType::HTML_INLINE, NodeType::PARAGRAPH
        { text: text }
      when NodeType::CODE_BLOCK
        { text: @arena.text(@node_id), info: @arena.code_block_info(@node_id) }
      when NodeType::LINK, NodeType::IMAGE
        { destination: @arena.link_destination(@node_id), title: @arena.link_title(@node_id), text: text }
      when NodeType::FOOTNOTE_REFERENCE
        { label: @arena.footnote_label(@node_id), number: @arena.footnote_number(@node_id) }
      when NodeType::FOOTNOTE_DEFINITION
        { label: @arena.footnote_label(@node_id) }
      else
        {}
      end
    end
  end
end
