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
end
