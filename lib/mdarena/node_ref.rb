# frozen_string_literal: true

module Mdarena
  class NodeRef
    include Enumerable

    attr_reader :document, :node_id

    def initialize(document, node_id)
      @document = document
      @arena = document.arena
      @node_id = node_id
    end

    def each(&block)
      walk(&block)
    end

    def type
      @arena.type_name(@node_id)
    end

    def children
      @arena.child_ids(@node_id).map { |child_id| NodeRef.new(@document, child_id) }
    end

    def walk
      return enum_for(:walk) unless block_given?

      yield self
      @arena.child_ids(@node_id).each do |child_id|
        NodeRef.new(@document, child_id).walk { |node| yield node }
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
        end_column: end_loc[:column]
      }
    end

    def to_h
      ast = {
        type: type,
        source_span: source_span,
        children: children.map(&:to_h)
      }

      attributes = ast_attributes
      ast[:attributes] = attributes unless attributes.empty?
      ast
    end

    private

    def ast_attributes
      case @arena.type(@node_id)
      when NodeType::HEADING
        { level: @arena.int1(@node_id), text: text }
      when NodeType::LIST
        {
          ordered: @arena.int1(@node_id) == 1,
          start_number: @arena.int2(@node_id),
          tight: @arena.int3(@node_id) == 1,
          delimiter: @arena.str1(@node_id)
        }
      when NodeType::TABLE_ROW, NodeType::TABLE_CELL
        { header: @arena.int1(@node_id) == 1, text: text }
      when NodeType::TEXT, NodeType::CODE_SPAN, NodeType::HTML_BLOCK, NodeType::HTML_INLINE, NodeType::PARAGRAPH
        { text: text }
      when NodeType::CODE_BLOCK
        { text: @arena.text(@node_id), info: @arena.str2(@node_id) }
      when NodeType::LINK, NodeType::IMAGE
        { destination: @arena.str1(@node_id), title: @arena.str2(@node_id), text: text }
      else
        {}
      end
    end
  end
end
