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

    it "returns nil for non-code-block nodes" do
      # nil distinguishes "not a code block" from a code block whose info
      # string is empty, which returns "".
      doc = RedQuilt.parse("# Heading\n\npara\n")

      expect(doc.root.children.map(&:info)).to all(be_nil)
    end

    it "exposes the raw code body via #text alongside #info" do
      node = code_block("```ruby\nputs 1\n```\n")

      expect(node.text).to eq("puts 1\n")
    end
  end

  describe "NodeRef node attributes" do
    def node_of(source, type, **options)
      RedQuilt.parse(source, **options).root.walk.find { |n| n.type == type }
    end

    it "exposes the heading level" do
      expect(node_of("## Two\n", :heading).heading_level).to eq(2)
    end

    it "exposes list attributes" do
      list = node_of("3. a\n4. b\n", :list)

      expect(list.list_ordered?).to be(true)
      expect(list.list_start).to eq(3)
      expect(list.list_tight?).to be(true)
      expect(list.list_delimiter).to eq(".")
    end

    it "distinguishes bullet lists from ordered ones" do
      expect(node_of("- a\n", :list).list_ordered?).to be(false)
      expect(node_of("- a\n", :list).list_delimiter).to eq("-")
    end

    it "exposes link and image destinations and titles" do
      link = node_of(%([a](http://e.com "t")\n), :link)
      image = node_of(%(![a](http://e.com/i.png)\n), :image)

      expect(link.link_destination).to eq("http://e.com")
      expect(link.link_title).to eq("t")
      expect(image.link_destination).to eq("http://e.com/i.png")
      expect(image.link_title).to be_nil
    end

    it "exposes footnote labels and numbers on both definition and reference" do
      source = "f[^a]\n\n[^a]: note\n"
      reference = node_of(source, :footnote_reference, footnotes: true)
      definition = node_of(source, :footnote_definition, footnotes: true)

      expect(reference.footnote_label).to eq("a")
      expect(reference.footnote_number).to eq(1)
      expect(definition.footnote_label).to eq("a")
      expect(definition.footnote_number).to eq(1)
    end

    it "reports header membership for table rows and cells" do
      source = "| a |\n| - |\n| 1 |\n"
      rows = RedQuilt.parse(source).root.walk.select { |n| n.type == :table_row }
      cells = RedQuilt.parse(source).root.walk.select { |n| n.type == :table_cell }

      expect(rows.map(&:header?)).to eq([true, false])
      expect(cells.map(&:header?)).to eq([true, false])
    end

    it "returns nil for attributes the node's type does not carry" do
      # The Arena layer skips this check and shares storage columns between
      # attributes, so reading one off a mismatched node there yields another
      # field's value. These wrappers must not pass that through.
      paragraph = node_of("just text\n", :paragraph)

      expect(paragraph.heading_level).to be_nil
      expect(paragraph.link_destination).to be_nil
      expect(paragraph.list_delimiter).to be_nil
      expect(paragraph.list_start).to be_nil
      expect(paragraph.footnote_label).to be_nil
      expect(paragraph.header?).to be_nil
      expect(paragraph.info).to be_nil
    end

    it "does not leak a code block's info string through link_title" do
      # Arena#link_title and Arena#code_block_info share a column.
      code = node_of("```rb\nc\n```\n", :code_block)

      expect(code.link_title).to be_nil
      expect(code.info).to eq("rb")
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
