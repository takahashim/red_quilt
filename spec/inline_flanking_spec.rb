# frozen_string_literal: true

RSpec.describe RedQuilt::Inline::Flanking do
  describe ".whitespace?" do
    it "treats nil (line edge) as whitespace" do
      expect(described_class.whitespace?(nil)).to be(true)
    end

    it "treats ASCII space / tab / newline as whitespace" do
      [" ", "\t", "\n"].each do |c|
        expect(described_class.whitespace?(c)).to be(true)
      end
    end

    it "treats letters and punctuation as non-whitespace" do
      ["a", "_", "*", "1", "あ"].each do |c|
        expect(described_class.whitespace?(c)).to be(false)
      end
    end
  end

  describe ".punctuation?" do
    it "matches ASCII punctuation" do
      [".", ",", "!", "?", "(", ")", "[", "]"].each do |c|
        expect(described_class.punctuation?(c)).to be(true)
      end
    end

    it "does not match letters / digits / whitespace / nil" do
      ["a", "1", " ", nil, "あ"].each do |c|
        expect(described_class.punctuation?(c)).to be(false)
      end
    end
  end

  describe ".can_open_close for *" do
    it "opens at the start of a word (no prev / next is letter)" do
      expect(described_class.can_open_close("*", nil, "a")).to eq([true, false])
    end

    it "closes at the end of a word (prev is letter / no next)" do
      expect(described_class.can_open_close("*", "a", nil)).to eq([false, true])
    end

    it "both opens and closes inside a word (foo*bar)" do
      can_open, can_close = described_class.can_open_close("*", "o", "b")
      expect(can_open).to be(true)
      expect(can_close).to be(true)
    end

    it "does not flank when surrounded by whitespace" do
      expect(described_class.can_open_close("*", " ", " ")).to eq([false, false])
    end
  end

  describe ".can_open_close for _" do
    it "does not open inside a word (foo_bar) because next is not punct" do
      can_open, can_close = described_class.can_open_close("_", "o", "b")
      expect(can_open).to be(false)
      expect(can_close).to be(false)
    end

    it "opens at the start of a word" do
      expect(described_class.can_open_close("_", nil, "a")).to eq([true, false])
    end

    it "closes at the end of a word" do
      expect(described_class.can_open_close("_", "a", nil)).to eq([false, true])
    end
  end

  describe ".char_before / .char_at with multibyte source" do
    let(:source) { "日本語" } # 3 chars, 9 bytes in UTF-8

    it "reads the multibyte char immediately before a byte position" do
      # byte 9 is end of source; the char before should be "語" (3 bytes, starting at byte 6)
      expect(described_class.char_before(source, 9, 0)).to eq("語")
    end

    it "reads the multibyte char at a byte position" do
      expect(described_class.char_at(source, 0, source.bytesize)).to eq("日")
      expect(described_class.char_at(source, 3, source.bytesize)).to eq("本")
      expect(described_class.char_at(source, 6, source.bytesize)).to eq("語")
    end

    it "returns nil at the edges of the range" do
      expect(described_class.char_before(source, 0, 0)).to be_nil
      expect(described_class.char_at(source, source.bytesize, source.bytesize)).to be_nil
    end
  end
end
