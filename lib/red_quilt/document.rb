# frozen_string_literal: true

module RedQuilt
  class Document
    attr_reader :source, :arena, :root_id, :references, :footnotes

    def initialize(source, arena, root_id, allow_html: false, disallow_raw_html: false, references: {}, footnotes: nil)
      @source = source
      @arena = arena
      @root_id = root_id
      @allow_html = allow_html
      @disallow_raw_html = disallow_raw_html
      @references = references
      @footnotes = footnotes
    end

    def allow_html?
      @allow_html
    end

    # When true, raw HTML output filters the 9 dangerous tags defined by
    # GFM's "Disallowed Raw HTML" extension (title, textarea, style, xmp,
    # iframe, noembed, noframes, script, plaintext) by replacing their
    # leading `<` with `&lt;`. Only meaningful when allow_html? is true;
    # when allow_html? is false everything is already escaped.
    def disallow_raw_html?
      @disallow_raw_html
    end

    def root
      NodeRef.new(self, @root_id)
    end

    def walk(&)
      root.walk(&)
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
      Renderer::Mdast.new(self).render
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
        return PlainText.from(@arena, node_id)
      end

      child = @arena.raw_first_child_id(node_id)
      while child != -1
        text = first_heading_text_walk(child)
        return text if text

        child = @arena.raw_next_sibling_id(child)
      end
      nil
    end
  end
end
