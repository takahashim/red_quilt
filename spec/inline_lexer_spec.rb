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
end
