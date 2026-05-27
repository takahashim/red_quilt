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

  describe "duplicate_reference (always-on)" do
    it "records a warning when a label is defined twice" do
      src = <<~MD
        [foo]: /a
        [foo]: /b

        [foo]
      MD
      doc = Mdarena.parse(src)
      dup = doc.diagnostics.find { |d| d.rule == :duplicate_reference }
      expect(dup).not_to be_nil
      expect(dup.severity).to eq(:warning)
      expect(dup.message).to include("foo")
    end

    it "still renders using the first definition" do
      src = "[foo]: /first\n[foo]: /second\n\n[foo]\n"
      html = Mdarena.render_html(src)
      expect(html).to include('href="/first"')
    end

    it "does not warn for unique labels" do
      doc = Mdarena.parse("[a]: /1\n[b]: /2\n\n[a] [b]\n")
      expect(doc.diagnostics.map(&:rule)).not_to include(:duplicate_reference)
    end
  end

  describe "LintPass (lint: true)" do
    it "emits empty_link for [text]() with no destination" do
      doc = Mdarena.parse("[text]()\n", lint: true)
      d = doc.diagnostics.find { |x| x.rule == :empty_link }
      expect(d).not_to be_nil
      expect(d.severity).to eq(:warning)
    end

    it "emits missing_alt for images with no alt text" do
      doc = Mdarena.parse("![](/img.png)\n", lint: true)
      d = doc.diagnostics.find { |x| x.rule == :missing_alt }
      expect(d).not_to be_nil
      expect(d.severity).to eq(:info)
    end

    it "skips missing_alt when the image has alt text" do
      doc = Mdarena.parse("![alt text](/img.png)\n", lint: true)
      expect(doc.diagnostics.map(&:rule)).not_to include(:missing_alt)
    end

    it "emits heading_level_skip when h2 is skipped" do
      doc = Mdarena.parse("# top\n\n### deep\n", lint: true)
      d = doc.diagnostics.find { |x| x.rule == :heading_level_skip }
      expect(d).not_to be_nil
      expect(d.message).to include("h1").and include("h3")
    end

    it "does not emit heading_level_skip for adjacent levels" do
      doc = Mdarena.parse("# a\n\n## b\n\n### c\n", lint: true)
      expect(doc.diagnostics.map(&:rule)).not_to include(:heading_level_skip)
    end

    it "does not emit heading_level_skip when going up the hierarchy" do
      doc = Mdarena.parse("### deep\n\n# top\n", lint: true)
      expect(doc.diagnostics.map(&:rule)).not_to include(:heading_level_skip)
    end

    it "is inert when lint: false (the default)" do
      doc = Mdarena.parse("[text]()\n\n![](/img.png)\n\n# a\n\n### c\n")
      lint_rules = %i[empty_link missing_alt heading_level_skip]
      expect(doc.diagnostics.map(&:rule) & lint_rules).to be_empty
    end
  end
end
