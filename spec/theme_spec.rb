# frozen_string_literal: true

RSpec.describe "standalone themes" do
  def doc
    RedQuilt.parse("# Title\n\nbody")
  end

  describe "RedQuilt::Theme.css" do
    it "returns nil for :none / nil (no embedded CSS)" do
      expect(RedQuilt::Theme.css(:none)).to be_nil
      expect(RedQuilt::Theme.css(nil)).to be_nil
    end

    it "returns the bundled stylesheet for :default" do
      expect(RedQuilt::Theme.css(:default)).to be_a(String).and include("max-width")
    end

    it "raises for an unknown theme" do
      expect { RedQuilt::Theme.css(:bogus) }.to raise_error(ArgumentError, /unknown theme/)
    end
  end

  describe "Document#to_html theme:" do
    it "embeds the stylesheet inline with theme: :default" do
      html = doc.to_html(standalone: true, theme: :default)
      expect(html).to include("<style>").and include("</style>")
    end

    it "embeds nothing with theme: :none, and omitting theme keeps bare output" do
      expect(doc.to_html(standalone: true, theme: :none)).not_to include("<style>")
      expect(doc.to_html(standalone: true)).not_to include("<style>")
    end

    it "combines an external --css link with an embedded theme" do
      html = doc.to_html(standalone: true, theme: :default, css: "x.css")
      expect(html).to include(%(<link rel="stylesheet" href="x.css">)).and include("<style>")
    end

    it "ignores theme for a non-standalone fragment" do
      expect(doc.to_html(theme: :default)).to eq("<h1>Title</h1>\n<p>body</p>\n")
    end
  end
end
