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
    # title / lang / css / theme: applied only when standalone is true.
    # theme: a bundled stylesheet to inline (`:none` embeds nothing, keeping
    #   the bare template; `:default` embeds RedQuilt's default theme). `css`
    #   (an external stylesheet link) is independent and may be combined.
    # heading_ids: when true, every heading gets a slugified `id` (Unicode
    #   preserving, deduplicated within the document) for anchor links.
    # mermaid: when true, fenced code blocks tagged `mermaid` render as
    #   `<pre class="mermaid">` containers instead of `<pre><code>`. In
    #   standalone mode the mermaid.js runtime is also loaded from a CDN so
    #   the diagrams render in the browser without further setup.
    def to_html(standalone: false, title: nil, lang: "en", css: nil, theme: :none, heading_ids: false, mermaid: false)
      body = Renderer::HTML.new(self, heading_ids: heading_ids, mermaid: mermaid).render
      return body unless standalone

      wrap_standalone_html(body, title: title.to_s, lang: lang.to_s, css: css, theme: Theme.css(theme), mermaid: mermaid)
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

    # Self-contained assets embedded in standalone output when mermaid
    # support is enabled. Loads the mermaid.js runtime from a CDN as an ES
    # module, renders every `<pre class="mermaid">` container, then makes
    # each diagram interactive with svg-pan-zoom (also from a CDN): mouse
    # wheel zooms, drag pans, and a small control panel offers +/-/reset.
    MERMAID_SCRIPT = <<~HTML
      <style>
      .rq-mermaid-pz {
        /* Break out of the body's max-width column so the viewport isn't a
           narrow peephole: span most of the viewport width, centered. */
        width: 80vw;
        margin-left: calc(50% - 40vw);
        height: 80vh;
        border: 1px solid #d0d7de;
        border-radius: 6px;
        overflow: hidden;
      }
      .rq-mermaid-pz svg {
        width: 100%;
        height: 100%;
        max-width: none;
        display: block;
        cursor: grab;
      }
      @media (prefers-color-scheme: dark) {
        .rq-mermaid-pz { border-color: #30363d; }
      }
      </style>
      <script type="module">
      import mermaid from "https://cdn.jsdelivr.net/npm/mermaid/dist/mermaid.esm.min.mjs";
      import svgPanZoom from "https://cdn.jsdelivr.net/npm/svg-pan-zoom@3.6.1/+esm";
      mermaid.initialize({ startOnLoad: false });
      await mermaid.run();

      for (const pre of document.querySelectorAll("pre.mermaid")) {
        const svg = pre.querySelector("svg");
        if (!svg) continue;
        // Drop mermaid's inline max-width and let the SVG fill a sized box so
        // svg-pan-zoom has room to zoom/pan. The whole viewBox scales as one,
        // so every element stays aligned.
        svg.removeAttribute("style");
        svg.setAttribute("width", "100%");
        svg.setAttribute("height", "100%");
        const box = document.createElement("div");
        box.className = "rq-mermaid-pz";
        pre.replaceWith(box);
        box.appendChild(svg);
        svgPanZoom(svg, {
          zoomEnabled: true,
          controlIconsEnabled: true,
          fit: true,
          center: true,
          zoomScaleSensitivity: 0.3,
          minZoom: 0.2,
          maxZoom: 20,
        });
      }
      </script>
    HTML
    private_constant :MERMAID_SCRIPT

    def wrap_standalone_html(body, title:, lang:, css:, theme:, mermaid: false)
      out = +"<!DOCTYPE html>\n"
      out << %(<html lang="#{html_escape_attr(lang)}">\n)
      out << "<head>\n"
      out << %(<meta charset="utf-8">\n)
      out << "<title>#{html_escape_text(title)}</title>\n"
      out << %(<link rel="stylesheet" href="#{html_escape_attr(css)}">\n) if css
      out << "<style>\n#{theme}</style>\n" if theme
      out << "</head>\n<body>\n"
      out << body
      out << MERMAID_SCRIPT if mermaid
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
