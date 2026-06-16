# frozen_string_literal: true

require "spec_helper"

RSpec.describe "mermaid" do
  describe "RedQuilt.render_html mermaid:" do
    it "renders mermaid code blocks as plain code blocks by default" do
      source = "```mermaid\ngraph LR\n  A --> B\n```"
      html = RedQuilt.render_html(source)
      expect(html).to include('<pre><code class="language-mermaid">')
      expect(html).not_to include('class="mermaid"')
    end

    it "renders mermaid code blocks as <pre class=\"mermaid\"> when enabled" do
      source = "```mermaid\ngraph LR\n  A --> B\n```"
      html = RedQuilt.render_html(source, mermaid: true)
      expect(html).to include('<pre class="mermaid">')
      expect(html).to include("graph LR")
      expect(html).not_to include("<code")
    end

    it "escapes the diagram source so the browser decodes it back into textContent" do
      source = "```mermaid\ngraph LR\n  A[\"<x>\"] --> B\n```"
      html = RedQuilt.render_html(source, mermaid: true)
      expect(html).to include("&lt;x&gt;")
      expect(html).not_to include("<x>")
    end

    it "leaves non-mermaid code blocks untouched when enabled" do
      source = "```ruby\nputs 1\n```"
      html = RedQuilt.render_html(source, mermaid: true)
      expect(html).to include('<pre><code class="language-ruby">')
    end
  end

  describe "Document#to_html standalone mermaid runtime" do
    def doc(source)
      RedQuilt.parse(source)
    end

    it "injects the mermaid.js CDN script in standalone output when enabled" do
      html = doc("```mermaid\ngraph LR\n  A --> B\n```").to_html(standalone: true, mermaid: true)
      expect(html).to include('<pre class="mermaid">')
      expect(html).to include("cdn.jsdelivr.net/npm/mermaid")
      expect(html).to include("mermaid.initialize")
    end

    it "wires up svg-pan-zoom for interactive zoom and pan" do
      html = doc("```mermaid\ngraph LR\n  A --> B\n```").to_html(standalone: true, mermaid: true)
      expect(html).to include("svg-pan-zoom")
      expect(html).to include("svgPanZoom(")
      expect(html).to include("controlIconsEnabled: true")
      expect(html).to include(".rq-mermaid-pz")
    end

    it "does not inject the runtime in fragment output" do
      html = doc("```mermaid\ngraph LR\n```").to_html(mermaid: true)
      expect(html).not_to include("cdn.jsdelivr.net")
    end

    it "does not inject the runtime when mermaid is disabled" do
      html = doc("```mermaid\ngraph LR\n```").to_html(standalone: true)
      expect(html).not_to include("cdn.jsdelivr.net")
    end
  end
end
