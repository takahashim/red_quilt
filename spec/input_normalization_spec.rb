# frozen_string_literal: true

require "spec_helper"

# CommonMark spec 2.3 (Insecure characters) and 2.4 (Line endings)
# normalization, plus blank-line definition from 4 (Leaf blocks).

RSpec.describe "input normalization" do
  let(:nul) { 0.chr }
  let(:replacement) { 0xFFFD.chr(Encoding::UTF_8) }

  def render(src)
    RedQuilt.render_html(src)
  end

  describe "line endings (spec 2.4)" do
    it "treats CRLF as a single line ending in a thematic break" do
      expect(render("***\r\n")).to eq("<hr />\n")
    end

    it "treats a lone CR as a line ending" do
      expect(render("***\r")).to eq("<hr />\n")
    end

    it "treats CRLF as paragraph-internal line break (soft break)" do
      expect(render("foo\r\nbar\r\n")).to eq("<p>foo\nbar</p>\n")
    end

    it "treats CR (alone) as paragraph-internal line break" do
      expect(render("foo\rbar\r")).to eq("<p>foo\nbar</p>\n")
    end

    it "splits paragraphs across a CRLF blank line" do
      expect(render("foo\r\n\r\nbar\r\n")).to eq("<p>foo</p>\n<p>bar</p>\n")
    end

    it "closes a fenced code block whose opening uses CRLF" do
      src = "```\r\nfoo\r\n```\r\n"
      expect(render(src)).to eq("<pre><code>foo\n</code></pre>\n")
    end
  end

  describe "NUL replacement (spec 2.3)" do
    it "replaces a literal NUL inside a paragraph with U+FFFD" do
      expect(render("a#{nul}b\n")).to eq("<p>a#{replacement}b</p>\n")
    end

    it "replaces a literal NUL at start of line" do
      expect(render("#{nul}foo\n")).to eq("<p>#{replacement}foo</p>\n")
    end

    it "keeps existing &#0; escape behavior (entity-decoded NUL still becomes U+FFFD)" do
      # Pre-existing behavior: numeric character references for U+0000 are
      # already mapped to U+FFFD by the inline pass. Guard against regression.
      expect(render("a&#0;b\n")).to eq("<p>a#{replacement}b</p>\n")
    end
  end

  describe "blank-line definition (spec 4)" do
    it "does NOT treat a form-feed-only line as blank" do
      # A blank line is empty or contains only spaces/tabs. Form feed
      # (U+000C) is whitespace but does not constitute a blank line, so
      # the paragraph must continue across it.
      out = render("foo\n\fbar\n")
      expect(out).to eq("<p>foo\n\fbar</p>\n")
    end

    it "still treats space-and-tab-only lines as blank (paragraph split)" do
      expect(render("foo\n \t \nbar\n")).to eq("<p>foo</p>\n<p>bar</p>\n")
    end
  end
end
