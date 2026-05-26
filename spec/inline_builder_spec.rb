# frozen_string_literal: true

RSpec.describe Markdast::Inline::Builder do
  let(:source) { "" }
  let(:arena) { Markdast::Arena.new(source) }
  let(:references) { {} }
  let(:tokens) { Markdast::Inline::Tokens.new }
  let(:builder) { described_class.new(arena, source, references) }

  def paragraph_id
    @paragraph_id ||= arena.add_node(
      Markdast::NodeType::PARAGRAPH,
      source_start: 0,
      source_len: source.bytesize
    )
  end

  def children_summary(parent_id)
    out = []
    child = arena.first_child(parent_id)
    until child == -1
      out << {
        type: Markdast::NodeType.name_for(arena.type(child)),
        text: arena.text(child),
        children: child_text_kinds(child)
      }
      child = arena.next_sibling(child)
    end
    out
  end

  def child_text_kinds(parent_id)
    child = arena.first_child(parent_id)
    arr = []
    until child == -1
      arr << Markdast::NodeType.name_for(arena.type(child))
      child = arena.next_sibling(child)
    end
    arr
  end

  describe "empty input" do
    it "accepts an empty token stream without raising" do
      expect { builder.build(paragraph_id, tokens) }.not_to raise_error
      expect(arena.first_child(paragraph_id)).to eq(-1)
    end
  end

  describe "TEXT" do
    let(:source) { "hello" }

    it "emits a TEXT arena node for a TEXT token" do
      tokens.emit(Markdast::Inline::TokenKind::TEXT, start_byte: 0, end_byte: 5)
      builder.build(paragraph_id, tokens)
      summary = children_summary(paragraph_id)
      expect(summary.size).to eq(1)
      expect(summary[0][:type]).to eq(:text)
      expect(summary[0][:text]).to eq("hello")
    end

    it "coalesces adjacent span-based TEXT tokens" do
      tokens.emit(Markdast::Inline::TokenKind::TEXT, start_byte: 0, end_byte: 3)
      tokens.emit(Markdast::Inline::TokenKind::TEXT, start_byte: 3, end_byte: 5)
      builder.build(paragraph_id, tokens)
      summary = children_summary(paragraph_id)
      expect(summary.size).to eq(1)
      expect(summary[0][:text]).to eq("hello")
    end
  end

  describe "ENTITY / ESCAPED_CHAR" do
    let(:source) { "a&amp;b" }

    it "stores the decoded literal in str1 and merges with adjacent TEXT" do
      tokens.emit(Markdast::Inline::TokenKind::TEXT, start_byte: 0, end_byte: 1)
      tokens.emit(Markdast::Inline::TokenKind::ENTITY, start_byte: 1, end_byte: 6, str1: "&")
      tokens.emit(Markdast::Inline::TokenKind::TEXT, start_byte: 6, end_byte: 7)
      builder.build(paragraph_id, tokens)

      summary = children_summary(paragraph_id)
      expect(summary.size).to eq(1)
      expect(summary[0][:text]).to eq("a&b")
    end
  end

  describe "LINE_ENDING" do
    let(:source) { "a\nb" }

    it "creates SOFTBREAK by default" do
      tokens.emit(Markdast::Inline::TokenKind::TEXT, start_byte: 0, end_byte: 1)
      tokens.emit(Markdast::Inline::TokenKind::LINE_ENDING, start_byte: 1, end_byte: 2, int1: 0)
      tokens.emit(Markdast::Inline::TokenKind::TEXT, start_byte: 2, end_byte: 3)
      builder.build(paragraph_id, tokens)

      kinds = child_text_kinds(paragraph_id)
      expect(kinds).to eq([:text, :softbreak, :text])
    end

    context "with two or more trailing spaces" do
      let(:source) { "a  \nb" }

      it "creates HARDBREAK and strips trailing spaces" do
        tokens.emit(Markdast::Inline::TokenKind::TEXT, start_byte: 0, end_byte: 3) # "a  "
        tokens.emit(Markdast::Inline::TokenKind::LINE_ENDING, start_byte: 3, end_byte: 4, int1: 2)
        tokens.emit(Markdast::Inline::TokenKind::TEXT, start_byte: 4, end_byte: 5)
        builder.build(paragraph_id, tokens)

        kinds = child_text_kinds(paragraph_id)
        expect(kinds).to eq([:text, :hardbreak, :text])

        first_text = arena.first_child(paragraph_id)
        expect(arena.text(first_text)).to eq("a")
      end
    end

    context "with backslash-form hardbreak" do
      let(:source) { "a\\\nb" }

      it "creates HARDBREAK when int2 == 1" do
        tokens.emit(Markdast::Inline::TokenKind::TEXT, start_byte: 0, end_byte: 1)
        tokens.emit(Markdast::Inline::TokenKind::LINE_ENDING, start_byte: 1, end_byte: 3, int1: 0, int2: 1)
        tokens.emit(Markdast::Inline::TokenKind::TEXT, start_byte: 3, end_byte: 4)
        builder.build(paragraph_id, tokens)

        kinds = child_text_kinds(paragraph_id)
        expect(kinds).to eq([:text, :hardbreak, :text])
      end
    end
  end

  describe "HTML_INLINE" do
    let(:source) { "<span>" }

    it "emits an HTML_INLINE node with the matched text in str1" do
      tokens.emit(Markdast::Inline::TokenKind::HTML_INLINE,
                  start_byte: 0, end_byte: 6, str1: "<span>")
      builder.build(paragraph_id, tokens)

      kinds = child_text_kinds(paragraph_id)
      expect(kinds).to eq([:html_inline])
      child = arena.first_child(paragraph_id)
      expect(arena.str1(child)).to eq("<span>")
    end
  end

  describe "AUTOLINK" do
    context "URI autolink" do
      let(:source) { "<https://example.com>" }

      it "emits LINK with TEXT child, str1 = destination" do
        tokens.emit(Markdast::Inline::TokenKind::AUTOLINK_URI,
                    start_byte: 0, end_byte: source.bytesize, str1: "https://example.com")
        builder.build(paragraph_id, tokens)

        kinds = child_text_kinds(paragraph_id)
        expect(kinds).to eq([:link])

        link = arena.first_child(paragraph_id)
        expect(arena.str1(link)).to eq("https://example.com")
        text = arena.first_child(link)
        expect(arena.str1(text)).to eq("https://example.com")
      end
    end

    context "email autolink" do
      let(:source) { "<a@b.example>" }

      it "wraps destination with mailto:" do
        tokens.emit(Markdast::Inline::TokenKind::AUTOLINK_EMAIL,
                    start_byte: 0, end_byte: source.bytesize, str1: "a@b.example")
        builder.build(paragraph_id, tokens)

        link = arena.first_child(paragraph_id)
        expect(arena.str1(link)).to eq("mailto:a@b.example")
        text = arena.first_child(link)
        expect(arena.str1(text)).to eq("a@b.example")
      end
    end
  end

  describe "CODE_SPAN" do
    # Convenience: lex via the real Lexer so token offsets are correct.
    def lex(src)
      tokens.clear
      Markdast::Inline::Lexer.new(src).lex_into(tokens, 0, src.bytesize)
      tokens
    end

    context "simple `code`" do
      let(:source) { "a`code`b" }

      it "emits a CODE_SPAN node and skips inner tokens" do
        lex(source)
        builder.build(paragraph_id, tokens)
        kinds = child_text_kinds(paragraph_id)
        expect(kinds).to eq([:text, :code_span, :text])

        cs = arena.first_child(paragraph_id)
        cs = arena.next_sibling(cs)
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

        cs = arena.first_child(paragraph_id)
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
        expect(arena.text(arena.first_child(paragraph_id))).to eq("a`b")
      end
    end

    context "code span containing `*` is not interpreted as emphasis" do
      let(:source) { "`*foo*`" }

      it "treats the asterisks as plain code content" do
        lex(source)
        builder.build(paragraph_id, tokens)
        kinds = child_text_kinds(paragraph_id)
        expect(kinds).to eq([:code_span])
        cs = arena.first_child(paragraph_id)
        expect(arena.str1(cs)).to eq("*foo*")
      end
    end
  end
end
