# frozen_string_literal: true

RSpec.describe Mdarena::Diagnostic do
  describe "construction" do
    it "stores severity / rule / message" do
      d = described_class.new(severity: :warning, rule: :unsafe_url, message: "bad")
      expect(d.severity).to eq(:warning)
      expect(d.rule).to eq(:unsafe_url)
      expect(d.message).to eq("bad")
      expect(d.source_span).to be_nil
    end

    it "rejects unknown severities" do
      expect {
        described_class.new(severity: :debug, rule: :x, message: "")
      }.to raise_error(ArgumentError, /unknown severity/)
    end
  end

  describe "Document#diagnostics" do
    it "starts as an empty array" do
      doc = Mdarena.parse("plain text")
      expect(doc.diagnostics).to eq([])
    end

    it "records unsafe URL schemes" do
      doc = Mdarena.parse("[click](javascript:alert(1))")
      expect(doc.diagnostics.size).to eq(1)
      d = doc.diagnostics.first
      expect(d.severity).to eq(:warning)
      expect(d.rule).to eq(:unsafe_url)
      expect(d.message).to include("javascript")
    end

    it "records missing references for the full-form `[text][ref]`" do
      doc = Mdarena.parse("[anchor][missing]\n")
      expect(doc.diagnostics.size).to eq(1)
      d = doc.diagnostics.first
      expect(d.rule).to eq(:missing_reference)
      expect(d.message).to include("missing")
    end

    it "does NOT record shortcut references that fail to resolve" do
      # Bare `[unknown]` could just be plain text, not a real link
      # attempt, so we keep quiet about it.
      doc = Mdarena.parse("[unknown]\n")
      expect(doc.diagnostics).to be_empty
    end

    it "collects multiple diagnostics across the document" do
      src = "[a](javascript:1) and [b][undef]\n"
      doc = Mdarena.parse(src)
      rules = doc.diagnostics.map(&:rule)
      expect(rules).to contain_exactly(:unsafe_url, :missing_reference)
    end

    it "still renders HTML alongside the diagnostics" do
      doc = Mdarena.parse("[x](javascript:1)\n")
      expect(doc.to_html).to include("<a href=\"\">x</a>")
      expect(doc.diagnostics).not_to be_empty
    end
  end
end
