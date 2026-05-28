# frozen_string_literal: true

require "spec_helper"

RSpec.describe RedQuilt::Inline::Builder do
  let(:source) { "" }
  let(:arena) { RedQuilt::Arena.new(source) }
  let(:references) { {} }
  let(:tokens) { RedQuilt::Inline::Tokens.new }
  let(:builder) { described_class.new(arena, source, references) }

  def paragraph_id
    @paragraph_id ||= arena.add_node(
      RedQuilt::NodeType::PARAGRAPH,
      source_start: 0,
      source_len: source.bytesize,
    )
  end

  def children_summary(parent_id)
    out = []
    child = arena.raw_first_child_id(parent_id)
    until child == -1
      out << {
        type: RedQuilt::NodeType.name_for(arena.type(child)),
        text: arena.text(child),
        children: child_text_kinds(child),
      }
      child = arena.raw_next_sibling_id(child)
    end
    out
  end

  def child_text_kinds(parent_id)
    child = arena.raw_first_child_id(parent_id)
    arr = []
    until child == -1
      arr << RedQuilt::NodeType.name_for(arena.type(child))
      child = arena.raw_next_sibling_id(child)
    end
    arr
  end

  describe "empty input" do
    it "accepts an empty token stream without raising" do
      expect { builder.build(paragraph_id, tokens) }.not_to raise_error
      expect(arena.raw_first_child_id(paragraph_id)).to eq(-1)
    end
  end

  describe "TEXT" do
    let(:source) { "hello" }

    it "emits a TEXT arena node for a TEXT token" do
      tokens.emit(RedQuilt::Inline::TokenKind::TEXT, start_byte: 0, end_byte: 5)
      builder.build(paragraph_id, tokens)
      summary = children_summary(paragraph_id)
      expect(summary.size).to eq(1)
      expect(summary[0][:type]).to eq(:text)
      expect(summary[0][:text]).to eq("hello")
    end

    it "coalesces adjacent span-based TEXT tokens" do
      tokens.emit(RedQuilt::Inline::TokenKind::TEXT, start_byte: 0, end_byte: 3)
      tokens.emit(RedQuilt::Inline::TokenKind::TEXT, start_byte: 3, end_byte: 5)
      builder.build(paragraph_id, tokens)
      summary = children_summary(paragraph_id)
      expect(summary.size).to eq(1)
      expect(summary[0][:text]).to eq("hello")
    end
  end

  describe "ENTITY / ESCAPED_CHAR" do
    let(:source) { "a&amp;b" }

    it "stores the decoded literal in str1 and merges with adjacent TEXT" do
      tokens.emit(RedQuilt::Inline::TokenKind::TEXT, start_byte: 0, end_byte: 1)
      tokens.emit(RedQuilt::Inline::TokenKind::ENTITY, start_byte: 1, end_byte: 6, str1: "&")
      tokens.emit(RedQuilt::Inline::TokenKind::TEXT, start_byte: 6, end_byte: 7)
      builder.build(paragraph_id, tokens)

      summary = children_summary(paragraph_id)
      expect(summary.size).to eq(1)
      expect(summary[0][:text]).to eq("a&b")
    end
  end

  describe "LINE_ENDING" do
    let(:source) { "a\nb" }

    it "creates SOFTBREAK by default" do
      tokens.emit(RedQuilt::Inline::TokenKind::TEXT, start_byte: 0, end_byte: 1)
      tokens.emit(RedQuilt::Inline::TokenKind::LINE_ENDING, start_byte: 1, end_byte: 2, int1: 0)
      tokens.emit(RedQuilt::Inline::TokenKind::TEXT, start_byte: 2, end_byte: 3)
      builder.build(paragraph_id, tokens)

      kinds = child_text_kinds(paragraph_id)
      expect(kinds).to eq([:text, :softbreak, :text])
    end

    context "with two or more trailing spaces" do
      let(:source) { "a  \nb" }

      it "creates HARDBREAK and strips trailing spaces" do
        tokens.emit(RedQuilt::Inline::TokenKind::TEXT, start_byte: 0, end_byte: 3) # "a  "
        tokens.emit(RedQuilt::Inline::TokenKind::LINE_ENDING, start_byte: 3, end_byte: 4, int1: 2)
        tokens.emit(RedQuilt::Inline::TokenKind::TEXT, start_byte: 4, end_byte: 5)
        builder.build(paragraph_id, tokens)

        kinds = child_text_kinds(paragraph_id)
        expect(kinds).to eq([:text, :hardbreak, :text])

        first_text = arena.raw_first_child_id(paragraph_id)
        expect(arena.text(first_text)).to eq("a")
      end
    end

    context "with backslash-form hardbreak" do
      let(:source) { "a\\\nb" }

      it "creates HARDBREAK when int2 == 1" do
        tokens.emit(RedQuilt::Inline::TokenKind::TEXT, start_byte: 0, end_byte: 1)
        tokens.emit(RedQuilt::Inline::TokenKind::LINE_ENDING, start_byte: 1, end_byte: 3, int1: 0, int2: 1)
        tokens.emit(RedQuilt::Inline::TokenKind::TEXT, start_byte: 3, end_byte: 4)
        builder.build(paragraph_id, tokens)

        kinds = child_text_kinds(paragraph_id)
        expect(kinds).to eq([:text, :hardbreak, :text])
      end
    end
  end

  describe "HTML_INLINE" do
    let(:source) { "<span>" }

    it "emits an HTML_INLINE node with the matched text in str1" do
      tokens.emit(RedQuilt::Inline::TokenKind::HTML_INLINE,
                  start_byte: 0, end_byte: 6, str1: "<span>")
      builder.build(paragraph_id, tokens)

      kinds = child_text_kinds(paragraph_id)
      expect(kinds).to eq([:html_inline])
      child = arena.raw_first_child_id(paragraph_id)
      expect(arena.str1(child)).to eq("<span>")
    end
  end

  describe "AUTOLINK" do
    context "URI autolink" do
      let(:source) { "<https://example.com>" }

      it "emits LINK with TEXT child, str1 = destination" do
        tokens.emit(RedQuilt::Inline::TokenKind::AUTOLINK_URI,
                    start_byte: 0, end_byte: source.bytesize, str1: "https://example.com")
        builder.build(paragraph_id, tokens)

        kinds = child_text_kinds(paragraph_id)
        expect(kinds).to eq([:link])

        link = arena.raw_first_child_id(paragraph_id)
        expect(arena.str1(link)).to eq("https://example.com")
        text = arena.raw_first_child_id(link)
        expect(arena.str1(text)).to eq("https://example.com")
      end
    end

    context "email autolink" do
      let(:source) { "<a@b.example>" }

      it "wraps destination with mailto:" do
        tokens.emit(RedQuilt::Inline::TokenKind::AUTOLINK_EMAIL,
                    start_byte: 0, end_byte: source.bytesize, str1: "a@b.example")
        builder.build(paragraph_id, tokens)

        link = arena.raw_first_child_id(paragraph_id)
        expect(arena.str1(link)).to eq("mailto:a@b.example")
        text = arena.raw_first_child_id(link)
        expect(arena.str1(text)).to eq("a@b.example")
      end
    end
  end

  describe "CODE_SPAN" do
    # Convenience: lex via the real Lexer so token offsets are correct.
    def lex(src)
      tokens.clear
      RedQuilt::Inline::Lexer.new(src).lex_into(tokens, 0, src.bytesize)
      tokens
    end

    context "simple `code`" do
      let(:source) { "a`code`b" }

      it "emits a CODE_SPAN node and skips inner tokens" do
        lex(source)
        builder.build(paragraph_id, tokens)
        kinds = child_text_kinds(paragraph_id)
        expect(kinds).to eq([:text, :code_span, :text])

        cs = arena.raw_first_child_id(paragraph_id)
        cs = arena.raw_next_sibling_id(cs)
        expect(arena.str1(cs)).to eq("code")
      end
    end

    context "multi-backtick `` foo ` bar ``" do
      let(:source) { "`` foo ` bar ``" }

      it "matches by run length and trims one leading + trailing space" do
        lex(source)
        builder.build(paragraph_id, tokens)
        kinds = child_text_kinds(paragraph_id)
        expect(kinds).to eq([:code_span])

        cs = arena.raw_first_child_id(paragraph_id)
        expect(arena.str1(cs)).to eq("foo ` bar")
      end
    end

    context "unmatched single backtick" do
      let(:source) { "a`b" }

      it "leaves the backtick as plain text" do
        lex(source)
        builder.build(paragraph_id, tokens)
        kinds = child_text_kinds(paragraph_id)
        expect(kinds).to eq([:text])
        expect(arena.text(arena.raw_first_child_id(paragraph_id))).to eq("a`b")
      end
    end

    context "code span containing `*` is not interpreted as emphasis" do
      let(:source) { "`*foo*`" }

      it "treats the asterisks as plain code content" do
        lex(source)
        builder.build(paragraph_id, tokens)
        kinds = child_text_kinds(paragraph_id)
        expect(kinds).to eq([:code_span])
        cs = arena.raw_first_child_id(paragraph_id)
        expect(arena.str1(cs)).to eq("*foo*")
      end
    end
  end

  describe "inline links" do
    def lex(src)
      tokens.clear
      RedQuilt::Inline::Lexer.new(src).lex_into(tokens, 0, src.bytesize)
      tokens
    end

    context "basic `[label](url)`" do
      let(:source) { "[foo](https://example.com)" }

      it "emits a LINK node with the label as a TEXT child" do
        lex(source)
        builder.build(paragraph_id, tokens)
        kinds = child_text_kinds(paragraph_id)
        expect(kinds).to eq([:link])

        link = arena.raw_first_child_id(paragraph_id)
        expect(arena.str1(link)).to eq("https://example.com")
        expect(child_text_kinds(link)).to eq([:text])
        text = arena.raw_first_child_id(link)
        expect(arena.text(text)).to eq("foo")
      end
    end

    context "link with title" do
      let(:source) { %([foo](https://example.com "t")) }

      it "stores destination in str1 and title in str2" do
        lex(source)
        builder.build(paragraph_id, tokens)
        link = arena.raw_first_child_id(paragraph_id)
        expect(arena.str1(link)).to eq("https://example.com")
        expect(arena.str2(link)).to eq("t")
      end
    end

    context "unmatched `]`" do
      let(:source) { "foo]bar" }

      it "renders the bracket as plain text" do
        lex(source)
        builder.build(paragraph_id, tokens)
        kinds = child_text_kinds(paragraph_id)
        expect(kinds).to eq([:text])
        expect(arena.text(arena.raw_first_child_id(paragraph_id))).to eq("foo]bar")
      end
    end

    context "image syntax `![alt](url)`" do
      let(:source) { "![alt](https://img.test/x.png)" }

      it "emits an IMAGE node with the alt as a TEXT child" do
        lex(source)
        builder.build(paragraph_id, tokens)
        kinds = child_text_kinds(paragraph_id)
        expect(kinds).to eq([:image])

        img = arena.raw_first_child_id(paragraph_id)
        expect(arena.str1(img)).to eq("https://img.test/x.png")
        text = arena.raw_first_child_id(img)
        expect(arena.text(text)).to eq("alt")
      end
    end

    context "unsafe URL scheme is dropped" do
      let(:source) { "[x](javascript:alert(1))" }

      it "produces a LINK with an empty destination" do
        lex(source)
        builder.build(paragraph_id, tokens)
        link = arena.raw_first_child_id(paragraph_id)
        expect(arena.str1(link)).to eq("")
      end
    end
  end

  describe "reference links" do
    def lex(src)
      tokens.clear
      RedQuilt::Inline::Lexer.new(src).lex_into(tokens, 0, src.bytesize)
      tokens
    end

    let(:references) do
      { "ref" => { destination: "https://ref.example", title: "T" } }
    end

    context "shortcut `[ref]`" do
      let(:source) { "[ref]" }

      it "resolves the reference and emits a LINK" do
        lex(source)
        builder.build(paragraph_id, tokens)
        link = arena.raw_first_child_id(paragraph_id)
        expect(arena.str1(link)).to eq("https://ref.example")
        expect(arena.str2(link)).to eq("T")
      end
    end

    context "full `[text][ref]`" do
      let(:source) { "[anchor][ref]" }

      it "uses the reference label, not the anchor text, for lookup" do
        lex(source)
        builder.build(paragraph_id, tokens)
        link = arena.raw_first_child_id(paragraph_id)
        expect(arena.str1(link)).to eq("https://ref.example")
      end
    end

    context "collapsed `[ref][]`" do
      let(:source) { "[ref][]" }

      it "uses the anchor label when the secondary label is empty" do
        lex(source)
        builder.build(paragraph_id, tokens)
        link = arena.raw_first_child_id(paragraph_id)
        expect(arena.str1(link)).to eq("https://ref.example")
      end
    end

    context "missing reference falls back to text" do
      let(:source) { "[unknown]" }

      it "leaves the brackets as plain text" do
        lex(source)
        builder.build(paragraph_id, tokens)
        kinds = child_text_kinds(paragraph_id)
        expect(kinds.first).to eq(:text)
      end
    end
  end

  describe "emphasis" do
    def lex(src)
      tokens.clear
      RedQuilt::Inline::Lexer.new(src).lex_into(tokens, 0, src.bytesize)
      tokens
    end

    context "basic `*em*`" do
      let(:source) { "a*foo*b" }

      it "emits TEXT, EMPHASIS, TEXT in order" do
        lex(source)
        builder.build(paragraph_id, tokens)
        expect(child_text_kinds(paragraph_id)).to eq([:text, :emphasis, :text])
        em = arena.raw_first_child_id(paragraph_id)
        em = arena.raw_next_sibling_id(em)
        expect(child_text_kinds(em)).to eq([:text])
        expect(arena.text(arena.raw_first_child_id(em))).to eq("foo")
      end
    end

    context "basic `**strong**`" do
      let(:source) { "a**foo**b" }

      it "emits STRONG when both delimiters have count >= 2" do
        lex(source)
        builder.build(paragraph_id, tokens)
        expect(child_text_kinds(paragraph_id)).to eq([:text, :strong, :text])
      end
    end

    context "triple `***x***`" do
      let(:source) { "foo***bar***baz" }

      it "produces nested emphasis > strong over the inner text" do
        lex(source)
        builder.build(paragraph_id, tokens)
        kinds = child_text_kinds(paragraph_id)
        expect(kinds).to eq([:text, :emphasis, :text])
        em = arena.raw_first_child_id(paragraph_id)
        em = arena.raw_next_sibling_id(em)
        expect(child_text_kinds(em)).to eq([:strong])
        st = arena.raw_first_child_id(em)
        expect(arena.text(arena.raw_first_child_id(st))).to eq("bar")
      end
    end

    context "underscore in word stays plain" do
      let(:source) { "foo_bar_baz" }

      it "does not form emphasis" do
        lex(source)
        builder.build(paragraph_id, tokens)
        expect(child_text_kinds(paragraph_id)).to eq([:text])
      end
    end

    context "unmatched `*` stays plain" do
      let(:source) { "a *b" }

      it "leaves the asterisk as plain text content" do
        lex(source)
        builder.build(paragraph_id, tokens)
        # the `*` survives as TEXT (its provisional node is released)
        text = arena.raw_first_child_id(paragraph_id)
        expect(arena.type(text)).to eq(RedQuilt::NodeType::TEXT)
      end
    end

    context "code span shields its delimiters" do
      let(:source) { "*foo `*bar*` baz*" }

      it "does not let backticked `*` participate in emphasis pairing" do
        lex(source)
        builder.build(paragraph_id, tokens)
        kinds = child_text_kinds(paragraph_id)
        expect(kinds).to eq([:emphasis])
        em = arena.raw_first_child_id(paragraph_id)
        # The interior should contain TEXT and a CODE_SPAN (no nested emphasis)
        interior_kinds = child_text_kinds(em)
        expect(interior_kinds).to include(:code_span)
        expect(interior_kinds).not_to include(:emphasis, :strong)
      end
    end

    context "link containing emphasis" do
      let(:source) { "[*foo*](url)" }

      it "constructs LINK > EMPHASIS > TEXT" do
        lex(source)
        builder.build(paragraph_id, tokens)
        expect(child_text_kinds(paragraph_id)).to eq([:link])
        link = arena.raw_first_child_id(paragraph_id)
        expect(child_text_kinds(link)).to eq([:emphasis])
        em = arena.raw_first_child_id(link)
        expect(arena.text(arena.raw_first_child_id(em))).to eq("foo")
      end
    end
  end
end
