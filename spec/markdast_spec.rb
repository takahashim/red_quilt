# frozen_string_literal: true

RSpec.describe Markdast do
  describe ".parse" do
    it "returns a document with traversable root children" do
      doc = described_class.parse("# Title\n\nBody")

      expect(doc).to be_a(Markdast::Document)
      expect(doc.root.type).to eq(:document)
      expect(doc.root.children.map(&:type)).to eq([:heading, :paragraph])
    end

    it "builds block AST nodes for major block constructs" do
      source = <<~MD
        # Heading

        ---

        > quote

        - first
        - second

            puts "hi"

        | A | B |
        | - | - |
        | 1 | 2 |

        <aside>html</aside>
      MD

      doc = described_class.parse(source)

      expect(doc.root.children.map(&:type)).to eq([
        :heading,
        :thematic_break,
        :blockquote,
        :list,
        :code_block,
        :table,
        :html_block
      ])
    end

    it "parses nested block content for blockquotes and list items" do
      source = <<~MD
        > quoted *text*

        2. item one
        3. item two
      MD

      doc = described_class.parse(source)
      blockquote = doc.root.children.first
      list = doc.root.children.last

      expect(blockquote.children.map(&:type)).to eq([:paragraph])
      expect(blockquote.walk.map(&:type)).to include(:emphasis)
      expect(list.children.map(&:type)).to eq([:list_item, :list_item])
    end

    it "parses inline children for paragraph, heading, and table cell" do
      source = <<~MD
        # Hello *world*

        Alpha **beta** `gamma` [site](https://example.com)

        | Name |
        | ---- |
        | hi *there* |
      MD

      doc = described_class.parse(source)
      heading = doc.root.children[0]
      paragraph = doc.root.children[1]
      table_cell = doc.root.children[2].children[1].children[0]

      expect(heading.children.map(&:type)).to eq([:text, :emphasis])
      expect(paragraph.children.map(&:type)).to eq([:text, :strong, :text, :code_span, :text, :link])
      expect(table_cell.walk.map(&:type)).to include(:emphasis)
    end

    it "keeps malformed inline syntax as text instead of raising" do
      doc = described_class.parse("broken [link](\n\n*unterminated")

      expect { doc.to_html }.not_to raise_error
      expect(doc.root.walk.map(&:type)).to include(:text)
    end

    it "exposes text and source_span for source-backed nodes" do
      doc = described_class.parse("# Hello\n")
      heading = doc.root.children.first

      expect(heading.text).to eq("Hello")
      expect(heading.source_span).to eq(Markdast::SourceSpan.new(2, 7))
    end

    it "tracks source spans for inline nodes parsed from source-backed content" do
      doc = described_class.parse("# Hello *world*\n")
      heading = doc.root.children.first
      text, emphasis = heading.children

      expect(text.source_span).to eq(Markdast::SourceSpan.new(2, 8))
      expect(emphasis.source_span).to eq(Markdast::SourceSpan.new(8, 15))
      expect(emphasis.children.first.source_span).to eq(Markdast::SourceSpan.new(9, 14))
    end

    it "finds nodes by type through the AST wrapper" do
      doc = described_class.parse("# One\n\nTwo *three*")

      expect(doc.root.find_all(:heading).map(&:text)).to eq(["One"])
      expect(doc.root.find_all(:emphasis).map(&:text)).to eq(["three"])
    end
  end

  describe ".render_html" do
    it "renders basic inline markup" do
      html = described_class.render_html("a *b* **c** `d` [e](https://example.com) ![alt](https://img.test/x.png)")

      expect(html).to eq("<p>a <em>b</em> <strong>c</strong> <code>d</code> <a href=\"https://example.com\">e</a> <img src=\"https://img.test/x.png\" alt=\"alt\" /></p>\n")
    end

    it "renders link and image titles" do
      html = described_class.render_html("[e](https://example.com \"title\") ![alt](https://img.test/x.png \"caption\")")

      expect(html).to eq("<p><a href=\"https://example.com\" title=\"title\">e</a> <img src=\"https://img.test/x.png\" alt=\"alt\" title=\"caption\" /></p>\n")
    end

    it "renders softbreaks and hardbreaks" do
      expect(described_class.render_html("a\nb")).to eq("<p>a\nb</p>\n")
      expect(described_class.render_html("a  \nb")).to eq("<p>a<br />\nb</p>\n")
    end

    it "escapes raw html by default" do
      html = described_class.render_html("<span>ok</span>\n\nHi <em>tag</em>")

      expect(html).to include("&lt;span&gt;ok&lt;/span&gt;")
      expect(html).to include("&lt;em&gt;tag&lt;/em&gt;")
    end

    it "passes through raw html when allow_html is true" do
      html = described_class.render_html("<span>ok</span>\n\nHi <em>tag</em>", allow_html: true)

      expect(html).to include("<span>ok</span>")
      expect(html).to include("Hi <em>tag</em>")
    end

    it "suppresses unsafe url schemes" do
      html = described_class.render_html("[x](javascript:alert(1)) ![y](data:text/html,boom)")

      expect(html).to include('<a href="">x</a>')
      expect(html).to include('<img src="" alt="y" />')
    end

    it "renders tables with header and body sections" do
      source = <<~MD
        | Name | Score |
        | ---- | ----- |
        | A | 1 |
      MD

      html = described_class.render_html(source)

      expect(html).to include("<table>")
      expect(html).to include("<thead>")
      expect(html).to include("<th>Name</th>")
      expect(html).to include("<tbody>")
      expect(html).to include("<td>1</td>")
    end

    it "matches Document#to_html" do
      source = "# Head\n\nBody"
      doc = described_class.parse(source)

      expect(doc.to_html).to eq(described_class.render_html(source))
    end
  end
end
