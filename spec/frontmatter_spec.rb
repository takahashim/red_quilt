# frozen_string_literal: true

require "spec_helper"

RSpec.describe "frontmatter" do
  describe "opt-in behavior" do
    it "treats a leading --- block as content when frontmatter is off (default)" do
      source = "---\ntitle: Hi\n---\n\n# Body\n"
      doc = RedQuilt.parse(source)
      expect(doc.frontmatter).to be_nil
      html = doc.to_html
      # The --- / setext heading interpretation keeps the block in the body.
      expect(html).to include("Hi")
    end

    it "extracts the frontmatter when enabled and removes it from the body" do
      source = "---\ntitle: Hi\nlang: ja\n---\n\n# Body\n"
      doc = RedQuilt.parse(source, frontmatter: true)
      expect(doc.frontmatter).to eq("title" => "Hi", "lang" => "ja")
      html = doc.to_html
      expect(html).to include("<h1>Body</h1>")
      expect(html).not_to include("title: Hi")
    end

    it "exposes frontmatter through render_html's frontmatter: option" do
      source = "---\ntitle: Hi\n---\n\nText\n"
      html = RedQuilt.render_html(source, frontmatter: true)
      expect(html).not_to include("title: Hi")
      expect(html).to include("<p>Text</p>")
    end
  end

  describe "delimiters and edge cases" do
    it "accepts ... as a closing delimiter" do
      source = "---\ntitle: Hi\n...\n\n# Body\n"
      doc = RedQuilt.parse(source, frontmatter: true)
      expect(doc.frontmatter).to eq("title" => "Hi")
    end

    it "does not treat --- in the middle of the document as frontmatter" do
      source = "# Heading\n\n---\n\ntitle: nope\n"
      doc = RedQuilt.parse(source, frontmatter: true)
      expect(doc.frontmatter).to be_nil
    end

    it "ignores an unterminated --- block" do
      source = "---\ntitle: Hi\n\n# Body\n"
      doc = RedQuilt.parse(source, frontmatter: true)
      expect(doc.frontmatter).to be_nil
    end

    it "treats an empty frontmatter block as nil data" do
      source = "---\n---\n\n# Body\n"
      doc = RedQuilt.parse(source, frontmatter: true)
      expect(doc.frontmatter).to be_nil
      expect(doc.to_html).to include("<h1>Body</h1>")
    end

    it "records a warning diagnostic and keeps rendering on invalid YAML" do
      source = "---\ntitle: : :\n  bad\n---\n\n# Body\n"
      doc = RedQuilt.parse(source, frontmatter: true)
      expect(doc.frontmatter).to be_nil
      expect(doc.diagnostics.map(&:rule)).to include(:frontmatter)
      expect(doc.to_html).to include("<h1>Body</h1>")
    end
  end

  describe "source position preservation" do
    it "keeps body line numbers relative to the start of the file" do
      source = "---\ntitle: Hi\n---\n# Body\n"
      doc = RedQuilt.parse(source, frontmatter: true)
      heading = doc.root.children.first
      # The heading is on line 4 of the original source.
      expect(heading.source_location[:start_line]).to eq(4)
    end
  end

  describe "standalone HTML integration" do
    it "fills <title> and <html lang> from frontmatter" do
      source = "---\ntitle: My Page\nlang: ja\n---\n\n# Body\n"
      doc = RedQuilt.parse(source, frontmatter: true)
      html = doc.to_html(standalone: true)
      expect(html).to include("<title>My Page</title>")
      expect(html).to include('<html lang="ja">')
    end

    it "prefers explicit arguments over frontmatter" do
      source = "---\ntitle: From FM\nlang: ja\n---\n\n# Body\n"
      doc = RedQuilt.parse(source, frontmatter: true)
      html = doc.to_html(standalone: true, title: "Explicit", lang: "en")
      expect(html).to include("<title>Explicit</title>")
      expect(html).to include('<html lang="en">')
    end

    it "falls back to en when neither argument nor frontmatter supplies lang" do
      source = "---\ntitle: Hi\n---\n\n# Body\n"
      doc = RedQuilt.parse(source, frontmatter: true)
      html = doc.to_html(standalone: true)
      expect(html).to include('<html lang="en">')
    end
  end
end
