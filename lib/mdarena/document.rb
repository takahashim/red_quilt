# frozen_string_literal: true

module Mdarena
  class Document
    attr_reader :source, :arena, :root_id

    def initialize(source, arena, root_id, allow_html: false, references: {})
      @source = source
      @arena = arena
      @root_id = root_id
      @allow_html = allow_html
      @references = references
    end

    def allow_html?
      @allow_html
    end

    def references
      @references
    end

    def root
      NodeRef.new(self, @root_id)
    end

    def walk(&block)
      root.walk(&block)
    end

    # Renders the document to HTML.
    #
    # standalone: when true, wrap the rendered body in a `<!DOCTYPE html>`
    #   template with `<head>` (charset / title / optional stylesheet)
    #   and `<body>`. When false (the default), only the rendered body
    #   fragment is returned.
    # title / lang / css: applied only when standalone is true.
    def to_html(standalone: false, title: nil, lang: "en", css: nil)
      body = Renderer::HTML.new(self).render
      return body unless standalone

      wrap_standalone_html(body, title: title.to_s, lang: lang.to_s, css: css)
    end

    def to_ast
      root.to_h
    end

    def to_json(*)
      require "json"
      JSON.pretty_generate(to_mdast)
    end

    def to_mdast
      mdast_node(@root_id)
end

    # Returns the plain-text content of the first HEADING in the
    # document, or nil if there is no heading. Used by callers (e.g. the
    # CLI's --auto-title) to derive a document title.
    def first_heading_text
      first_heading_text_walk(@root_id)
    end

    def source_map
      @source_map ||= SourceMap.new(@source)
    end

    # Returns the array of diagnostics collected during parse / render.
    # The array is mutable and shared with the parser / renderer; new
    # entries appear here without further calls.
    def diagnostics
      @diagnostics ||= []
    end

    private

    def mdast_node(node_id, parent_spread: false)
      type_int = @arena.type(node_id)
      type_sym = NodeType.name_for(type_int)
      mdast_type = mdast_type_name(type_sym)

      result = { "type" => mdast_type }

      span = @arena.source_span(node_id)
      if span
        result["position"] = mdast_position(span)
      end

      case type_int
      when NodeType::HEADING
        result["depth"] = @arena.int1(node_id)
        result["children"] = mdast_children(node_id)
      when NodeType::LIST
        result["ordered"] = @arena.int1(node_id) == 1
        tight = @arena.int3(node_id) == 1
        if result["ordered"]
          result["start"] = @arena.int2(node_id)
        end
        result["spread"] = !tight
        result["children"] = mdast_children(node_id, parent_spread: !tight)
      when NodeType::LIST_ITEM
        result["spread"] = parent_spread
        result["children"] = mdast_children(node_id)
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
        result["children"] = mdast_children(node_id)
      when NodeType::IMAGE
        result["url"] = @arena.str1(node_id).to_s
        title = @arena.str2(node_id)
        result["title"] = title && !title.empty? ? title : nil
        result["alt"] = NodeRef.new(self, node_id).text.to_s
      when NodeType::HTML_BLOCK, NodeType::HTML_INLINE
        result["value"] = NodeRef.new(self, node_id).text.to_s
      when NodeType::TABLE
        result["align"] = []
        result["children"] = mdast_children(node_id)
      when NodeType::DOCUMENT, NodeType::PARAGRAPH, NodeType::BLOCKQUOTE,
           NodeType::TABLE_ROW, NodeType::TABLE_CELL,
           NodeType::EMPHASIS, NodeType::STRONG, NodeType::STRIKETHROUGH
        result["children"] = mdast_children(node_id)
      end

      result
    end

    def mdast_children(node_id, parent_spread: false)
      @arena.child_ids(node_id).map { |child_id| mdast_node(child_id, parent_spread: parent_spread) }
    end

    def mdast_position(span)
      start_loc = source_map.line_column(span.start_byte)
      end_loc = source_map.line_column(span.end_byte)
      {
        "start" => {
          "line" => start_loc[:line],
          "column" => start_loc[:column],
          "offset" => span.start_byte
        },
        "end" => {
          "line" => end_loc[:line],
          "column" => end_loc[:column],
          "offset" => span.end_byte
        }
      }
    end

    def mdast_type_name(type_sym)
      {
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
        strikethrough: "delete"
      }.fetch(type_sym, type_sym.to_s)
    end

    def wrap_standalone_html(body, title:, lang:, css:)
      out = +"<!DOCTYPE html>\n"
      out << %(<html lang="#{html_escape_attr(lang)}">\n)
      out << "<head>\n"
      out << %(<meta charset="utf-8">\n)
      out << "<title>#{html_escape_text(title)}</title>\n"
      out << %(<link rel="stylesheet" href="#{html_escape_attr(css)}">\n) if css
      out << "</head>\n<body>\n"
      out << body
      out << "</body>\n</html>\n"
      out
    end

    def html_escape_text(str)
      str.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
    end

    def html_escape_attr(str)
      html_escape_text(str).gsub('"', "&quot;")
    end

    def first_heading_text_walk(node_id)
      return nil if node_id == -1
      if @arena.type(node_id) == NodeType::HEADING
        return collect_plain_text(node_id)
      end
      child = @arena.raw_first_child_id(node_id)
      while child != -1
        text = first_heading_text_walk(child)
        return text if text
        child = @arena.raw_next_sibling_id(child)
      end
      nil
    end

    def collect_plain_text(node_id)
      out = +""
      collect_plain_text_walk(node_id, out)
      out
    end

    def collect_plain_text_walk(node_id, out)
      case @arena.type(node_id)
      when NodeType::TEXT
        out << @arena.text(node_id).to_s
      when NodeType::CODE_SPAN
        out << @arena.str1(node_id).to_s
      when NodeType::SOFTBREAK, NodeType::HARDBREAK
        out << " "
      else
        child = @arena.raw_first_child_id(node_id)
        while child != -1
          collect_plain_text_walk(child, out)
          child = @arena.raw_next_sibling_id(child)
        end
      end
    end
  end
end
