# frozen_string_literal: true

RSpec.describe Markdast::Inline::Lexer do
  let(:source) { "hello" }
  let(:lexer) { described_class.new(source) }
  let(:tokens) { Markdast::Inline::Tokens.new }

  describe "#lex_into" do
    it "accepts a tokens storage and a byte range without raising" do
      expect { lexer.lex_into(tokens, 0, source.bytesize) }.not_to raise_error
    end

    it "returns the same tokens object that was passed in" do
      result = lexer.lex_into(tokens, 0, source.bytesize)
      expect(result).to equal(tokens)
    end

    # Token-emission behavior is verified in dedicated specs added by the
    # upcoming commits (TEXT / LINE_ENDING / DELIM_RUN / ...).
  end

  def lex(source, range_start: 0, range_end: nil)
    range_end ||= source.bytesize
    tokens = Markdast::Inline::Tokens.new
    described_class.new(source).lex_into(tokens, range_start, range_end)
    tokens
  end

  def token_summary(tokens)
    tokens.each_id.map do |id|
      {
        kind: Markdast::Inline::TokenKind.name(tokens.kind(id)),
        range: [tokens.start_byte(id), tokens.end_byte(id)],
        str1: tokens.str1(id)
      }
    end
  end

  describe "TEXT" do
    it "emits a single TEXT token for plain ASCII input" do
      result = lex("hello")
      expect(token_summary(result)).to eq([
        { kind: :text, range: [0, 5], str1: nil }
      ])
    end

    it "emits a single TEXT token for plain multibyte input" do
      result = lex("日本語")
      expect(token_summary(result)).to eq([
        { kind: :text, range: [0, 9], str1: nil }
      ])
    end

    it "stops at a special byte and emits TEXT for the leading run" do
      result = lex("hello*world")
      expect(token_summary(result).first).to eq(
        { kind: :text, range: [0, 5], str1: nil }
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
      le_id = result.each_id.find { |id| result.kind(id) == Markdast::Inline::TokenKind::LINE_ENDING }
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
      le_id = result.each_id.find { |id| result.kind(id) == Markdast::Inline::TokenKind::LINE_ENDING }
      expect(result.int2(le_id)).to eq(1)
    end
  end

  describe "CODE_DELIMITER" do
    it "emits CODE_DELIMITER with run length for a single backtick" do
      result = lex("a`b")
      cd = result.each_id.find { |id| result.kind(id) == Markdast::Inline::TokenKind::CODE_DELIMITER }
      expect(result.int1(cd)).to eq(1)
      expect([result.start_byte(cd), result.end_byte(cd)]).to eq([1, 2])
    end

    it "groups consecutive backticks into a single token" do
      result = lex("a```b")
      cd = result.each_id.find { |id| result.kind(id) == Markdast::Inline::TokenKind::CODE_DELIMITER }
      expect(result.int1(cd)).to eq(3)
      expect([result.start_byte(cd), result.end_byte(cd)]).to eq([1, 4])
    end
  end

  describe "DELIM_RUN for *" do
    it "emits with can_open and can_close inside a word (foo*bar)" do
      result = lex("foo*bar")
      dr = result.each_id.find { |id| result.kind(id) == Markdast::Inline::TokenKind::DELIM_RUN }
      expect(result.int1(dr)).to eq("*".ord)
      expect(result.int2(dr)).to eq(1)
      expect(result.int3(dr)).to eq(0b11)
    end

    it "is only can_open when preceded by whitespace" do
      result = lex("a *b")
      dr = result.each_id.find { |id| result.kind(id) == Markdast::Inline::TokenKind::DELIM_RUN }
      expect(result.int3(dr) & 0b10).to eq(0b10)
      expect(result.int3(dr) & 0b01).to eq(0)
    end

    it "is only can_close when followed by whitespace" do
      result = lex("a* b")
      dr = result.each_id.find { |id| result.kind(id) == Markdast::Inline::TokenKind::DELIM_RUN }
      expect(result.int3(dr) & 0b10).to eq(0)
      expect(result.int3(dr) & 0b01).to eq(0b01)
    end

    it "counts a multi-character run" do
      result = lex("***foo")
      dr = result.each_id.find { |id| result.kind(id) == Markdast::Inline::TokenKind::DELIM_RUN }
      expect(result.int2(dr)).to eq(3)
      expect([result.start_byte(dr), result.end_byte(dr)]).to eq([0, 3])
    end
  end

  describe "DELIM_RUN for _" do
    it "is neither can_open nor can_close inside a word (foo_bar)" do
      result = lex("foo_bar")
      dr = result.each_id.find { |id| result.kind(id) == Markdast::Inline::TokenKind::DELIM_RUN }
      expect(result.int3(dr)).to eq(0)
    end

    it "opens at the start of a word" do
      result = lex("a _b")
      dr = result.each_id.find { |id| result.kind(id) == Markdast::Inline::TokenKind::DELIM_RUN }
      expect(result.int3(dr) & 0b10).to eq(0b10)
    end
  end
end
