# frozen_string_literal: true

module RedQuilt
  module Renderer
    # Builds an MDAST-compatible Hash from the document arena.
    #
    # MDAST (https://github.com/syntax-tree/mdast) is the unified.js AST
    # format for Markdown; emitting it lets external tooling (linters,
    # editor plugins) consume red_quilt output without bespoke adapters.
    class Mdast
      MDAST_TYPE_NAMES = {
        document: "root",
        paragraph: "paragraph",
        heading: "heading",
        thematic_break: "thematicBreak",
        blockquote: "blockquote",
        list: "list",
        list_item: "listItem",
        code_block: "code",
        html_block: "html",
        table: "table",
        table_row: "tableRow",
        table_cell: "tableCell",
        text: "text",
        softbreak: "break",
        hardbreak: "break",
        emphasis: "emphasis",
        strong: "strong",
        code_span: "inlineCode",
        link: "link",
        image: "image",
        html_inline: "html",
        strikethrough: "delete",
        footnote_reference: "footnoteReference",
        footnote_definition: "footnoteDefinition",
      }.freeze

      def initialize(document)
        @document = document
        @arena = document.arena
      end

      def render
        node(@document.root_id)
      end

      private

      def node(node_id, parent_spread: false)
        type_int = @arena.type(node_id)
        type_sym = NodeType.name_for(type_int)

        result = { "type" => mdast_type_name(type_sym) }

        span = @arena.source_span(node_id)
        result["position"] = position(span) if span

        case type_int
        when NodeType::HEADING
          result["depth"] = @arena.int1(node_id)
          result["children"] = children(node_id)
        when NodeType::LIST
          result["ordered"] = @arena.int1(node_id) == 1
          tight = @arena.int3(node_id) == 1
          result["start"] = @arena.int2(node_id) if result["ordered"]
          result["spread"] = !tight
          result["children"] = children(node_id, parent_spread: !tight)
        when NodeType::LIST_ITEM
          result["spread"] = parent_spread
          result["children"] = children(node_id)
        when NodeType::CODE_BLOCK
          info = @arena.str2(node_id)
          lang = info && !info.empty? ? info.split.first : nil
          result["lang"] = lang
          result["value"] = @arena.text(node_id).to_s
        when NodeType::TEXT
          result["value"] = @arena.text(node_id).to_s
        when NodeType::SOFTBREAK
          result["type"] = "text"
          result["value"] = "\n"
        when NodeType::CODE_SPAN
          result["value"] = @arena.text(node_id).to_s
        when NodeType::LINK
          result["url"] = @arena.str1(node_id).to_s
          title = @arena.str2(node_id)
          result["title"] = title && !title.empty? ? title : nil
          result["children"] = children(node_id)
        when NodeType::IMAGE
          result["url"] = @arena.str1(node_id).to_s
          title = @arena.str2(node_id)
          result["title"] = title && !title.empty? ? title : nil
          result["alt"] = NodeRef.new(@document, node_id).text.to_s
        when NodeType::FOOTNOTE_REFERENCE
          label = @arena.str1(node_id).to_s
          result["identifier"] = label
          result["label"] = label
        when NodeType::FOOTNOTE_DEFINITION
          label = @arena.str1(node_id).to_s
          result["identifier"] = label
          result["label"] = label
          result["children"] = children(node_id)
        when NodeType::HTML_BLOCK, NodeType::HTML_INLINE
          result["value"] = NodeRef.new(@document, node_id).text.to_s
        when NodeType::TABLE
          result["align"] = []
          result["children"] = children(node_id)
        when NodeType::DOCUMENT, NodeType::PARAGRAPH, NodeType::BLOCKQUOTE,
             NodeType::TABLE_ROW, NodeType::TABLE_CELL,
             NodeType::EMPHASIS, NodeType::STRONG, NodeType::STRIKETHROUGH
          result["children"] = children(node_id)
        end

        result
      end

      def children(node_id, parent_spread: false)
        result = []
        @arena.child_ids(node_id).each do |child_id|
          # mdast has no footnotes-section wrapper: footnote definitions are
          # plain root-level nodes, so splice the section's children in.
          if @arena.type(child_id) == NodeType::FOOTNOTES_SECTION
            @arena.child_ids(child_id).each { |def_id| result << node(def_id, parent_spread: parent_spread) }
          else
            result << node(child_id, parent_spread: parent_spread)
          end
        end
        result
      end

      def position(span)
        start_loc = @document.source_map.line_column(span.start_byte)
        end_loc = @document.source_map.line_column(span.end_byte)
        {
          "start" => {
            "line" => start_loc[:line],
            "column" => start_loc[:column],
            "offset" => span.start_byte,
          },
          "end" => {
            "line" => end_loc[:line],
            "column" => end_loc[:column],
            "offset" => span.end_byte,
          },
        }
      end

      def mdast_type_name(type_sym)
        MDAST_TYPE_NAMES.fetch(type_sym, type_sym.to_s)
      end
    end
  end
end
