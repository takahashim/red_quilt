# frozen_string_literal: true

require "spec_helper"

# Position reporting follows the unist Point convention, which cmark
# sourcepos and mdast both use. The expected values below were verified by
# running the same input through the reference implementations
# (commonmark.js and mdast-util-from-markdown); where the two disagree, the
# divergence is called out on the example.
RSpec.describe "source positions" do
  def start_of(source)
    loc = RedQuilt.parse(source).root.children.first.source_location
    [loc[:start_line], loc[:start_column]]
  end

  def span_of(source)
    loc = RedQuilt.parse(source).root.children.first.source_location
    [loc[:start_line], loc[:start_column], loc[:end_line], loc[:end_column]]
  end

  describe "coordinate basis" do
    it "reports lines and columns as 1-based" do
      expect(start_of("text\n")).to eq([1, 1])
    end

    it "counts columns in characters, not bytes" do
      # "日本語" is 3 characters but 9 bytes; the strong run starts at the
      # 4th character.
      doc = RedQuilt.parse("日本語**強調**テスト")
      strong = doc.root.walk.find { |n| n.type == :strong }

      expect(strong.source_location[:start_column]).to eq(4)
    end

    it "keeps line numbers correct across multibyte lines" do
      # The line-start table is indexed by byte offset. Building it with
      # String#index (which counts characters) makes every line after the
      # first multibyte character drift. A single-line multibyte source does
      # not catch this, so span several lines.
      doc = RedQuilt.parse("# 見出し\n\n本文\n")
      heading, paragraph = doc.root.children

      expect(heading.source_location[:start_line]).to eq(1)
      expect(heading.source_location[:end_line]).to eq(1)
      expect(paragraph.source_location[:start_line]).to eq(3)
      expect(paragraph.source_location[:end_line]).to eq(3)
    end

    it "keeps line numbers correct when widths are mixed within a line" do
      doc = RedQuilt.parse("# 見出し H1\n\n本文 text\n\n- 項目\n")
      heading, paragraph, list = doc.root.children

      expect(heading.source_location[:start_line]).to eq(1)
      expect(paragraph.source_location[:start_line]).to eq(3)
      expect(list.source_location[:start_line]).to eq(5)
    end
  end

  describe "block spans cover the block as authored" do
    it "includes the ATX heading marker" do
      expect(span_of("# H1\n")).to eq([1, 1, 1, 5])
    end

    it "starts at the marker rather than the line for an indented heading" do
      expect(span_of("   # H1\n")).to eq([1, 4, 1, 8])
    end

    it "includes closing hashes and trailing spaces" do
      expect(span_of("# H1 ###\n")).to eq([1, 1, 1, 9])
      expect(span_of("# H1   \n")).to eq([1, 1, 1, 8])
    end

    it "includes the blockquote marker" do
      expect(span_of("> quote\n")).to eq([1, 1, 1, 8])
      expect(span_of(">quote\n")).to eq([1, 1, 1, 7])
      expect(span_of("  > quote\n")).to eq([1, 3, 1, 10])
    end

    it "covers every line of a multiline blockquote, including lazy ones" do
      expect(span_of("> a\n> b\n")).to eq([1, 1, 2, 4])
      expect(span_of("> a\nb\n")).to eq([1, 1, 2, 2])
    end

    it "includes both fences of a fenced code block" do
      # Previously the span covered only the content, which reported the
      # block as starting one line below its opening fence.
      expect(span_of("```rb\ncode\n```\n")).to eq([1, 1, 3, 4])
      expect(span_of("~~~\ncode\n~~~\n")).to eq([1, 1, 3, 4])
      expect(span_of("  ```rb\n  code\n  ```\n")).to eq([1, 3, 3, 6])
    end

    it "ends at the last line when a fence is never closed" do
      # commonmark.js agrees; mdast instead extends to a phantom line past
      # the final newline.
      expect(span_of("```rb\ncode\n")).to eq([1, 1, 2, 5])
    end

    it "includes the setext underline" do
      expect(span_of("Title\n=====\n")).to eq([1, 1, 2, 6])
      expect(span_of("a\nb\n===\n")).to eq([1, 1, 3, 4])
    end

    it "leaves marker-less blocks at the line start" do
      expect(start_of("- item\n")).to eq([1, 1])
      expect(start_of("1. item\n")).to eq([1, 1])
      expect(start_of("***\n")).to eq([1, 1])
      expect(start_of("<div>\nx\n</div>\n")).to eq([1, 1])
    end
  end

  describe "leading indent is excluded from spans" do
    # Indent is not part of the block as authored, so `  text` starts at
    # column 3 in both reference implementations.
    it "skips indent for every indentable block type" do
      expect(start_of("   # H1\n")).to eq([1, 4])
      expect(start_of("  Title\n===\n")).to eq([1, 3])
      expect(start_of("  text\n")).to eq([1, 3])
      expect(start_of("  > quote\n")).to eq([1, 3])
      expect(start_of("  ```\nc\n  ```\n")).to eq([1, 3])
      expect(start_of("  - item\n")).to eq([1, 3])
      expect(start_of("  ***\n")).to eq([1, 3])
    end
  end

  describe "list items" do
    it "starts a list item at its bullet, not its content" do
      doc = RedQuilt.parse("- a\n  - b\n")
      outer_item = doc.root.children.first.children.first

      expect(outer_item.type).to eq(:list_item)
      expect(outer_item.source_location.values_at(:start_line, :start_column)).to eq([1, 1])
    end

    it "starts a nested list item at its own bullet" do
      doc = RedQuilt.parse("- a\n  - b\n")
      nested_item = doc.root.walk.select { |n| n.type == :list_item }.last

      expect(nested_item.source_location.values_at(:start_line, :start_column)).to eq([2, 3])
    end
  end

  describe "mdast position (unist Point)" do
    let(:position) { RedQuilt.parse("# H1\n").to_mdast["children"].first["position"] }

    it "reports 1-based line and column" do
      expect(position["start"]).to include("line" => 1, "column" => 1)
      expect(position["end"]).to include("line" => 1, "column" => 5)
    end

    it "reports offset as a 0-based character index" do
      expect(position["start"]["offset"]).to eq(0)
      expect(position["end"]["offset"]).to eq(4)
    end

    it "counts offset in characters rather than bytes for multibyte sources" do
      # "見出し\n\n" is 5 characters but 11 bytes, so a byte offset would
      # report 11 for the paragraph on line 3.
      mdast = RedQuilt.parse("見出し\n\nあ\n").to_mdast
      paragraph = mdast["children"][1]

      expect(paragraph["position"]["start"]["offset"]).to eq(5)
      expect(paragraph["position"]["start"]).to include("line" => 3, "column" => 1)
    end
  end
end
