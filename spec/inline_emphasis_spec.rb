# frozen_string_literal: true

require "spec_helper"

# Coverage for the CommonMark spec section 6.2 (emphasis and strong
# emphasis) behaviors that the Lexer + Builder pipeline gained over
# the legacy heuristic parser. Test inputs follow CommonMark 0.31.2
# examples and the expected HTML matches commonmark.js output.

RSpec.describe "Inline emphasis" do
  def render(src)
    RedQuilt.render_html(src)
  end

  describe "basic asterisk emphasis" do
    it "wraps a simple run in <em>" do
      expect(render("*foo bar*\n")).to eq("<p><em>foo bar</em></p>\n")
    end

    it "leaves asterisks surrounded by punctuation as text" do
      expect(render("a*\"foo\"*\n")).to eq("<p>a*&quot;foo&quot;*</p>\n")
    end

    it "does not open emphasis when the asterisk is whitespace-flanked" do
      expect(render("a * b * c\n")).to eq("<p>a * b * c</p>\n")
    end
  end

  describe "basic underscore emphasis" do
    it "wraps a simple run in <em>" do
      expect(render("_foo bar_\n")).to eq("<p><em>foo bar</em></p>\n")
    end

    it "does not form emphasis inside a word" do
      expect(render("foo_bar_baz\n")).to eq("<p>foo_bar_baz</p>\n")
    end

    it "does not form emphasis when both sides are word characters (CJK)" do
      # CommonMark example 378-style: Cyrillic letters count as word characters
      expect(render("_пристаням_стремятся\n"))
        .to eq("<p>_пристаням_стремятся</p>\n")
    end
  end

  describe "strong emphasis (**)" do
    it "wraps a simple run in <strong>" do
      expect(render("**foo bar**\n")).to eq("<p><strong>foo bar</strong></p>\n")
    end

    it "does not form strong when whitespace-flanked" do
      expect(render("** a **\n")).to eq("<p>** a **</p>\n")
    end
  end

  describe "strong emphasis (__)" do
    it "wraps a simple run in <strong>" do
      expect(render("__foo bar__\n")).to eq("<p><strong>foo bar</strong></p>\n")
    end
  end

  describe "nested emphasis" do
    it "nests strong inside emphasis" do
      expect(render("*foo **bar** baz*\n"))
        .to eq("<p><em>foo <strong>bar</strong> baz</em></p>\n")
    end

    it "nests emphasis inside strong" do
      expect(render("**foo *bar* baz**\n"))
        .to eq("<p><strong>foo <em>bar</em> baz</strong></p>\n")
    end

    it "splits *** into outer emphasis + inner strong" do
      expect(render("foo***bar***baz\n"))
        .to eq("<p>foo<em><strong>bar</strong></em>baz</p>\n")
    end
  end

  describe "interaction with code spans" do
    it "does not interpret asterisks inside a code span" do
      expect(render("*foo `*bar*` baz*\n"))
        .to eq("<p><em>foo <code>*bar*</code> baz</em></p>\n")
    end
  end

  describe "interaction with links" do
    it "renders emphasis inside link labels" do
      expect(render("[*foo*](/url)\n"))
        .to eq("<p><a href=\"/url\"><em>foo</em></a></p>\n")
    end
  end

  describe "incomplete emphasis stays as text" do
    it "treats a stray opener as a literal asterisk" do
      expect(render("*foo\n")).to eq("<p>*foo</p>\n")
    end

    it "treats a stray closer as a literal asterisk" do
      expect(render("foo*\n")).to eq("<p>foo*</p>\n")
    end
  end
end
