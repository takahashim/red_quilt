# frozen_string_literal: true

module Markdast
  class InlinePass
    INLINE_TARGETS = [NodeType::PARAGRAPH, NodeType::HEADING, NodeType::TABLE_CELL].freeze

    def initialize(document)
      @document = document
      @arena = document.arena
    end

    def apply
      visit(@document.root_id)
    end

    private

    def visit(node_id)
      if INLINE_TARGETS.include?(@arena.type(node_id))
        source_text = @arena.text(node_id).to_s
        base_offset = @arena.str1(node_id).nil? ? @arena.source_start(node_id) : nil
        InlineParser.new(
          @arena,
          parent_id: node_id,
          source_text: source_text,
          base_offset: base_offset,
          references: @document.references
        ).parse
        return
      end

      child_id = @arena.first_child(node_id)
      until child_id == -1
        visit(child_id)
        child_id = @arena.next_sibling(child_id)
      end
    end
  end
end
