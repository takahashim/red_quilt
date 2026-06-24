# frozen_string_literal: true

require "spec_helper"

# Public API surface relied on by external consumers that partition a
# document and render the pieces themselves (e.g. slide generators).
RSpec.describe "RedQuilt public node/renderer API" do
  describe "NodeRef#info" do
    def code_block(source)
      RedQuilt.parse(source).root.children.find { |n| n.type == :code_block }
    end

    it "returns the fence info string of a fenced code block" do
      node = code_block("```ruby\nputs 1\n```\n")

      expect(node.info).to eq("ruby")
    end

    it "preserves the full info string, not just the language word" do
      node = code_block(%(```vtt audio="sample.mp3"\nWEBVTT\n```\n))

      expect(node.info).to eq('vtt audio="sample.mp3"')
    end

    it "returns an empty string for a code block without an info string" do
      node = code_block("```\nplain\n```\n")

      expect(node.info).to eq("")
    end

    it "returns an empty string for non-code-block nodes" do
      doc = RedQuilt.parse("# Heading\n\npara\n")

      expect(doc.root.children.map(&:info)).to all(eq(""))
    end

    it "exposes the raw code body via #text alongside #info" do
      node = code_block("```ruby\nputs 1\n```\n")

      expect(node.text).to eq("puts 1\n")
    end
  end

  describe "Renderer::HTML#render_fragment" do
    it "renders the given nodes in order as an HTML fragment" do
      doc = RedQuilt.parse("# One\n\npara\n\n## Two\n")
      renderer = RedQuilt::Renderer::HTML.new(doc)
      nodes = doc.root.children

      fragment = renderer.render_fragment([nodes[0], nodes[1]])

      expect(fragment).to eq("<h1>One</h1>\n<p>para</p>\n")
    end

    it "does not disturb the main render output" do
      doc = RedQuilt.parse("# One\n\npara\n")
      renderer = RedQuilt::Renderer::HTML.new(doc)

      renderer.render_fragment(doc.root.children)

      expect(renderer.render).to eq("<h1>One</h1>\n<p>para</p>\n")
    end

    it "preserves shared slugger state across fragments" do
      doc = RedQuilt.parse("# Dup\n\n# Dup\n")
      renderer = RedQuilt::Renderer::HTML.new(doc, heading_ids: true)
      headings = doc.root.children

      first = renderer.render_fragment([headings[0]])
      second = renderer.render_fragment([headings[1]])

      expect(first).to include(%(id="dup"))
      expect(second).to include(%(id="dup-1"))
    end
  end
end
