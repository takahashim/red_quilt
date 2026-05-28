# frozen_string_literal: true

require "spec_helper"

RSpec.describe RedQuilt::Inline::Tokens do
  let(:tokens) { described_class.new }

  describe "#emit" do
    it "appends a token and returns its id" do
      id = tokens.emit(RedQuilt::Inline::TokenKind::TEXT, start_byte: 0, end_byte: 5)
      expect(id).to eq(0)
      expect(tokens.length).to eq(1)
      expect(tokens.kind(0)).to eq(RedQuilt::Inline::TokenKind::TEXT)
      expect(tokens.start_byte(0)).to eq(0)
      expect(tokens.end_byte(0)).to eq(5)
    end

    it "stores per-token int/str payloads" do
      id = tokens.emit(
        RedQuilt::Inline::TokenKind::DELIM_RUN,
        start_byte: 3, end_byte: 5,
        int1: "*".ord, int2: 2, int3: 0b11,
        str1: nil,
      )
      expect(tokens.int1(id)).to eq("*".ord)
      expect(tokens.int2(id)).to eq(2)
      expect(tokens.int3(id)).to eq(0b11)
      expect(tokens.str1(id)).to be_nil
    end

    it "assigns monotonically increasing ids" do
      a = tokens.emit(RedQuilt::Inline::TokenKind::TEXT, start_byte: 0, end_byte: 1)
      b = tokens.emit(RedQuilt::Inline::TokenKind::TEXT, start_byte: 1, end_byte: 2)
      expect([a, b]).to eq([0, 1])
    end
  end

  describe "#clear" do
    it "drops length to zero while remaining usable" do
      3.times { |i| tokens.emit(RedQuilt::Inline::TokenKind::TEXT, start_byte: i, end_byte: i + 1) }
      expect(tokens.length).to eq(3)

      tokens.clear
      expect(tokens.length).to eq(0)
      expect(tokens.empty?).to be(true)

      # capacity is preserved; we can keep emitting and ids restart from 0
      id = tokens.emit(RedQuilt::Inline::TokenKind::TEXT, start_byte: 0, end_byte: 1)
      expect(id).to eq(0)
      expect(tokens.length).to eq(1)
    end
  end

  describe "#each_id" do
    it "yields token ids in emit order" do
      3.times { |i| tokens.emit(RedQuilt::Inline::TokenKind::TEXT, start_byte: i, end_byte: i + 1) }
      expect(tokens.each_id.to_a).to eq([0, 1, 2])
    end
  end
end
