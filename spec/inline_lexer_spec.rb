# frozen_string_literal: true

RSpec.describe RedQuilt::Inline::Lexer do
  let(:source) { "hello" }
  let(:lexer) { described_class.new(source) }
  let(:tokens) { RedQuilt::Inline::Tokens.new }

  describe "#lex_into" do
    it "accepts a tokens storage and a byte range without raising" do
      expect { lexer.lex_into(tokens, 0, source.bytesize) }.not_to raise_error
    end

    it "returns the same tokens object that was passed in" do
      result = lexer.lex_into(tokens, 0, source.bytesize)
      expect(result).to equal(tokens)
    end
  end

  def lex(source, range_start: 0, range_end: nil)
    range_end ||= source.bytesize
    tokens = RedQuilt::Inline::Tokens.new
    described_class.new(source).lex_into(tokens, range_start, range_end)
    tokens
  end

  def token_summary(tokens)
    tokens.each_id.map do |id|
      {
        kind: RedQuilt::Inline::TokenKind.name(tokens.kind(id)),
        range: [tokens.start_byte(id), tokens.end_byte(id)],
        str1: tokens.str1(id),
      }
    end
  end

  describe "TEXT" do
    it "emits a single TEXT token for plain ASCII input" do
      result = lex("hello")
      expect(token_summary(result)).to eq([
        { kind: :text, range: [0, 5], str1: nil },
      ])
    end

    it "emits a single TEXT token for plain multibyte input" do
      result = lex("日本語")
      expect(token_summary(result)).to eq([
        { kind: :text, range: [0, 9], str1: nil },
      ])
    end

    it "stops at a special byte and emits TEXT for the leading run" do
      result = lex("hello*world")
      expect(token_summary(result).first).to eq(
        { kind: :text, range: [0, 5], str1: nil },
      )
    end
  end

  describe "LINE_ENDING" do
    it "emits LINE_ENDING for a plain newline with zero trailing spaces" do
      result = lex("a\nb")
      summary = token_summary(result)
      expect(summary[0]).to eq({ kind: :text, range: [0, 1], str1: nil })
      expect(summary[1][:kind]).to eq(:line_ending)
      expect(summary[1][:range]).to eq([1, 2])
      expect(result.int1(1)).to eq(0)
    end

    it "records trailing-space count for hardbreak detection" do
      result = lex("a   \nb")
      le_id = result.each_id.find { |id| result.kind(id) == RedQuilt::Inline::TokenKind::LINE_ENDING }
      expect(result.int1(le_id)).to eq(3)
    end
  end

  describe "ESCAPED_CHAR" do
    it "emits ESCAPED_CHAR for backslash + ASCII punctuation" do
      result = lex("a\\*b")
      summary = token_summary(result)
      expect(summary[1]).to eq({ kind: :escaped_char, range: [1, 3], str1: "*" })
    end

    it "treats a backslash before a non-punct character as literal text" do
      result = lex("a\\xb")
      summary = token_summary(result)
      kinds = summary.map { |t| t[:kind] }
      expect(kinds).not_to include(:escaped_char)
    end

    it "treats `\\\\n` as a hardbreak-style LINE_ENDING with int2 = 1" do
      result = lex("a\\\nb")
      le_id = result.each_id.find { |id| result.kind(id) == RedQuilt::Inline::TokenKind::LINE_ENDING }
      expect(result.int2(le_id)).to eq(1)
    end
  end

  describe "CODE_DELIMITER" do
    it "emits CODE_DELIMITER with run length for a single backtick" do
      result = lex("a`b")
      cd = result.each_id.find { |id| result.kind(id) == RedQuilt::Inline::TokenKind::CODE_DELIMITER }
      expect(result.int1(cd)).to eq(1)
      expect([result.start_byte(cd), result.end_byte(cd)]).to eq([1, 2])
    end

    it "groups consecutive backticks into a single token" do
      result = lex("a```b")
      cd = result.each_id.find { |id| result.kind(id) == RedQuilt::Inline::TokenKind::CODE_DELIMITER }
      expect(result.int1(cd)).to eq(3)
      expect([result.start_byte(cd), result.end_byte(cd)]).to eq([1, 4])
    end
  end

  describe "DELIM_RUN for *" do
    it "emits with can_open and can_close inside a word (foo*bar)" do
      result = lex("foo*bar")
      dr = result.each_id.find { |id| result.kind(id) == RedQuilt::Inline::TokenKind::DELIM_RUN }
      expect(result.int1(dr)).to eq("*".ord)
      expect(result.int2(dr)).to eq(1)
      expect(result.int3(dr)).to eq(0b11)
    end

    it "is only can_open when preceded by whitespace" do
      result = lex("a *b")
      dr = result.each_id.find { |id| result.kind(id) == RedQuilt::Inline::TokenKind::DELIM_RUN }
      expect(result.int3(dr) & 0b10).to eq(0b10)
      expect(result.int3(dr) & 0b01).to eq(0)
    end

    it "is only can_close when followed by whitespace" do
      result = lex("a* b")
      dr = result.each_id.find { |id| result.kind(id) == RedQuilt::Inline::TokenKind::DELIM_RUN }
      expect(result.int3(dr) & 0b10).to eq(0)
      expect(result.int3(dr) & 0b01).to eq(0b01)
    end

    it "counts a multi-character run" do
      result = lex("***foo")
      dr = result.each_id.find { |id| result.kind(id) == RedQuilt::Inline::TokenKind::DELIM_RUN }
      expect(result.int2(dr)).to eq(3)
      expect([result.start_byte(dr), result.end_byte(dr)]).to eq([0, 3])
    end
  end

  describe "DELIM_RUN for _" do
    it "downgrades to TEXT inside a word (foo_bar) since it cannot flank" do
      result = lex("foo_bar")
      dr = result.each_id.find { |id| result.kind(id) == RedQuilt::Inline::TokenKind::DELIM_RUN }
      expect(dr).to be_nil
    end

    it "opens at the start of a word" do
      result = lex("a _b")
      dr = result.each_id.find { |id| result.kind(id) == RedQuilt::Inline::TokenKind::DELIM_RUN }
      expect(result.int3(dr) & 0b10).to eq(0b10)
    end
  end

  describe "brackets" do
    it "emits LBRACKET / RBRACKET as single-byte tokens" do
      result = lex("[a]")
      kinds = result.each_id.map { |id| RedQuilt::Inline::TokenKind.name(result.kind(id)) }
      expect(kinds).to eq([:lbracket, :text, :rbracket])
    end

    it "emits BANG_LBRACKET as a 2-byte token for '!['" do
      result = lex("![alt]")
      first = 0
      expect(RedQuilt::Inline::TokenKind.name(result.kind(first))).to eq(:bang_lbracket)
      expect([result.start_byte(first), result.end_byte(first)]).to eq([0, 2])
    end

    it "emits a lone '!' (not followed by '[') as TEXT" do
      result = lex("!a")
      first = 0
      expect(RedQuilt::Inline::TokenKind.name(result.kind(first))).to eq(:text)
      expect([result.start_byte(first), result.end_byte(first)]).to eq([0, 1])
    end
  end

  describe "AUTOLINK" do
    it "emits AUTOLINK_URI for <https://example.com>" do
      result = lex("<https://example.com>")
      id = 0
      expect(RedQuilt::Inline::TokenKind.name(result.kind(id))).to eq(:autolink_uri)
      expect(result.str1(id)).to eq("https://example.com")
    end

    it "emits AUTOLINK_EMAIL for <a@b.example>" do
      result = lex("<a@b.example>")
      id = 0
      expect(RedQuilt::Inline::TokenKind.name(result.kind(id))).to eq(:autolink_email)
      expect(result.str1(id)).to eq("a@b.example")
    end
  end

  describe "HTML_INLINE" do
    it "emits HTML_INLINE for a recognized tag" do
      result = lex("<span>")
      id = 0
      expect(RedQuilt::Inline::TokenKind.name(result.kind(id))).to eq(:html_inline)
      expect(result.str1(id)).to eq("<span>")
    end

    it "emits TEXT for an unrecognized '<' followed by non-tag input" do
      result = lex("<>")
      id = 0
      expect(RedQuilt::Inline::TokenKind.name(result.kind(id))).to eq(:text)
    end
  end

  describe "ENTITY" do
    it "emits ENTITY for a named entity and decodes via str1" do
      result = lex("&amp;")
      id = 0
      expect(RedQuilt::Inline::TokenKind.name(result.kind(id))).to eq(:entity)
      expect(result.str1(id)).to eq("&")
    end

    it "emits ENTITY for a numeric entity" do
      result = lex("&#65;")
      id = 0
      expect(RedQuilt::Inline::TokenKind.name(result.kind(id))).to eq(:entity)
      expect(result.str1(id)).to eq("A")
    end

    it "emits TEXT for an unrecognized '&'" do
      result = lex("&notanentity")
      id = 0
      expect(RedQuilt::Inline::TokenKind.name(result.kind(id))).to eq(:text)
    end
  end
end
