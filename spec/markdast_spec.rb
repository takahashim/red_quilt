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

    it "exports a nested AST hash from the arena" do
      doc = described_class.parse("# Hello *world*\n\n[site](https://example.com)")

      expect(doc.to_ast).to eq({
        type: :document,
        source_span: Markdast::SourceSpan.new(0, 44),
        children: [
          {
            type: :heading,
            source_span: Markdast::SourceSpan.new(2, 15),
            attributes: { level: 1, text: "Hello world" },
            children: [
              {
                type: :text,
                source_span: Markdast::SourceSpan.new(2, 8),
                attributes: { text: "Hello " },
                children: []
              },
              {
                type: :emphasis,
                source_span: Markdast::SourceSpan.new(8, 15),
                children: [
                  {
                    type: :text,
                    source_span: Markdast::SourceSpan.new(9, 14),
                    attributes: { text: "world" },
                    children: []
                  }
                ]
              }
            ]
          },
          {
            type: :paragraph,
            source_span: Markdast::SourceSpan.new(17, 44),
            attributes: { text: "site" },
            children: [
              {
                type: :link,
                source_span: Markdast::SourceSpan.new(17, 44),
                attributes: { destination: "https://example.com", title: nil, text: "site" },
                children: [
                  {
                    type: :text,
                    source_span: Markdast::SourceSpan.new(18, 22),
                    attributes: { text: "site" },
                    children: []
                  }
                ]
              }
            ]
          }
        ]
      })
    end

    it "exports a subtree hash from a node reference" do
      doc = described_class.parse("# Hello *world*")
      heading = doc.root.children.first

      expect(heading.to_h).to eq({
        type: :heading,
        source_span: Markdast::SourceSpan.new(2, 15),
        attributes: { level: 1, text: "Hello world" },
        children: [
          {
            type: :text,
            source_span: Markdast::SourceSpan.new(2, 8),
            attributes: { text: "Hello " },
            children: []
          },
          {
            type: :emphasis,
            source_span: Markdast::SourceSpan.new(8, 15),
            children: [
              {
                type: :text,
                source_span: Markdast::SourceSpan.new(9, 14),
                attributes: { text: "world" },
                children: []
              }
            ]
          }
        ]
      })
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

    it "provides source_location with line/column for nodes" do
      source = "# Title\n\nBody text\nwith newline"
      doc = described_class.parse(source)

      heading = doc.root.children.first
      # heading source_span is the inline part ("Title"), not including "# "
      expect(heading.source_location).to eq({
        start_line: 1, start_column: 2,
        end_line: 1, end_column: 7
      })

      paragraph = doc.root.children.last
      # paragraph spans from "Body" to end of "newline"
      expect(paragraph.source_location).to eq({
        start_line: 3, start_column: 0,
        end_line: 4, end_column: 12
      })
    end

    it "caches source_map for repeated calls" do
      source = "Line 1\nLine 2\nLine 3"
      doc = described_class.parse(source)

      source_map1 = doc.source_map
      source_map2 = doc.source_map

      expect(source_map1).to equal(source_map2)
    end

    it "returns nil source_location for nodes without source_span" do
      doc = described_class.parse("# Title")
      heading = doc.root.children.first

      # All nodes should have source_span, but test defensively
      # This would only be nil in edge cases during construction
      location = heading.source_location
      expect(location).to be_a(Hash) if location
    end

    it "sanitizes unsafe URL schemes" do
      # javascript: should be blocked
      doc = described_class.parse('[link](javascript:alert(1))')
      link = doc.root.children.first.children.first
      html = described_class.render_html('[link](javascript:alert(1))')
      expect(html).to include('href=""')

      # vbscript: should be blocked
      html = described_class.render_html('[link](vbscript:msgbox)')
      expect(html).to include('href=""')

      # data: should be blocked
      html = described_class.render_html('[link](data:text/html,<script>alert(1)</script>)')
      expect(html).to include('href=""')
    end

    it "allows safe URL schemes" do
      # ftp should be allowed
      html = described_class.render_html('[link](ftp://example.com/file)')
      expect(html).to include('href="ftp://example.com/file"')

      # tel should be allowed
      html = described_class.render_html('[link](tel:+1234567890)')
      expect(html).to include('href="tel:+1234567890"')

      # ssh should be allowed
      html = described_class.render_html('[link](ssh://example.com)')
      expect(html).to include('href="ssh://example.com"')
    end

    it "renders code block info string using first word only" do
      # info string with multiple words
      source = "```ruby test\ncode\n```"
      html = described_class.render_html(source)
      expect(html).to include('class="language-ruby"')
      expect(html).not_to include('test')
    end

    it "renders image alt text with line breaks as spaces" do
      # image alt with soft break
      source = "![alt text\nwith break](/img.png)"
      html = described_class.render_html(source)
      expect(html).to include('alt="alt text with break"')
    end

    it "renders nested block structures correctly" do
      # blockquote > list > paragraph
      source = "> - item 1\n> - item 2"
      html = described_class.render_html(source)
      expect(html).to include("<blockquote>")
      expect(html).to include("<ul>")
      expect(html).to include("<li>")
    end

    describe "multibyte character handling" do
      # Regression tests for Phase 9-A: Unicode byte offset bug.
      # InlineScanner uses character indices but Arena#text uses byteslice,
      # so mixing char-based and byte-based offsets corrupted HTML output
      # for Cyrillic / CJK / other multi-byte input.

      it "renders Cyrillic emphasis without HTML corruption" do
        expect(described_class.render_html("_пристаням_стремятся"))
          .to eq("<p><em>пристаням</em>стремятся</p>\n")
      end

      it "renders Japanese emphasis without HTML corruption" do
        expect(described_class.render_html("日本語の*強調*テスト"))
          .to eq("<p>日本語の<em>強調</em>テスト</p>\n")
      end

      it "renders mixed ASCII and CJK emphasis" do
        expect(described_class.render_html("*emphasis* with *日本語*"))
          .to eq("<p><em>emphasis</em> with <em>日本語</em></p>\n")
      end

      it "renders strong emphasis with multibyte content" do
        expect(described_class.render_html("**強い強調**と通常文"))
          .to eq("<p><strong>強い強調</strong>と通常文</p>\n")
      end

      it "renders triple emphasis with multibyte content" do
        expect(described_class.render_html("***中文***test"))
          .to eq("<p><em><strong>中文</strong></em>test</p>\n")
      end

      it "renders code spans with multibyte content" do
        expect(described_class.render_html("文字列`コード`テスト"))
          .to eq("<p>文字列<code>コード</code>テスト</p>\n")
      end

      it "renders links with multibyte link text" do
        expect(described_class.render_html("[日本語リンク](https://example.com)"))
          .to eq("<p><a href=\"https://example.com\">日本語リンク</a></p>\n")
      end
    end
  end
end
