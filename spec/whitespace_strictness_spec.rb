# frozen_string_literal: true

# CommonMark spec restricts certain "whitespace" contexts more narrowly
# than Ruby's \s class:
#   - URI autolinks (6.5): no ASCII control char, no space, no <, no >.
#   - Raw HTML tags (6.6): attribute separators are space/tab or up to
#     one line ending -- not form feed (U+000C) or vertical tab (U+000B).
#   - Inline link tails (6.3): separator inside `(...)` is space/tab plus
#     up to one line ending; FF/VT are not allowed.

RSpec.describe "whitespace strictness" do
  def render(src, **opts)
    RedQuilt.render_html(src, **opts)
  end

  describe "URI autolink (CommonMark 6.5)" do
    it "rejects U+007F (DEL) inside an autolink URI" do
      out = render("<http://example.com/\u007F>")
      expect(out).not_to include("<a href=")
    end

    it "still accepts a clean URI autolink" do
      out = render("<http://example.com/>")
      expect(out).to include(%(<a href="http://example.com/">))
    end

    it "rejects ASCII control bytes (e.g. U+001F) inside URI autolink" do
      out = render("<http://example.com/\u001Fpath>")
      expect(out).not_to include("<a href=")
    end
  end

  describe "raw HTML tag whitespace (CommonMark 6.6)" do
    # The block-level "type 7" detector and the inline raw-HTML lexer both
    # restrict tag separators to space/tab/CR/LF. Form feed and vertical
    # tab between tag name and attribute, or around `=`, no longer let
    # the tag through.

    it "does not treat a tag with form-feed-separated attribute as raw HTML (inline)" do
      out = render("foo <a\fh=\"x\">bar", allow_html: true)
      expect(out).to eq("<p>foo &lt;a\fh=&quot;x&quot;&gt;bar</p>\n")
    end

    it "does not treat a tag with vertical-tab separator as raw HTML (inline)" do
      out = render("foo <a\vh=\"x\">bar", allow_html: true)
      expect(out).to eq("<p>foo &lt;a\vh=&quot;x&quot;&gt;bar</p>\n")
    end

    it "does not treat form-feed-around-equals as raw HTML (inline)" do
      out = render("foo <a h=\f\"x\">bar", allow_html: true)
      expect(out).to eq("<p>foo &lt;a h=\f&quot;x&quot;&gt;bar</p>\n")
    end

    it "does not treat </tag\\f> as raw HTML closing tag" do
      out = render("foo </a\f> bar", allow_html: true)
      expect(out).to eq("<p>foo &lt;/a\f&gt; bar</p>\n")
    end

    it "does not open an HTML block when tag separator is form feed (type 7)" do
      out = render("<a\fh=\"x\">", allow_html: true)
      expect(out).not_to start_with("<a")
      expect(out).to include("&lt;a\fh=")
    end

    it "still accepts a tab as attribute separator" do
      out = render("foo <a\th=\"x\">bar", allow_html: true)
      expect(out).to include(%(<a\th="x">))
    end

    it "still accepts a regular space as attribute separator" do
      out = render("foo <a h=\"x\">bar", allow_html: true)
      expect(out).to include(%(<a h="x">))
    end
  end

  describe "inline link tail whitespace (CommonMark 6.3)" do
    it "does not consume form feed between destination and title" do
      out = render(%([x](url\f"title")))
      expect(out).not_to include("<a href=")
      expect(out).to start_with("<p>[x](url\f")
    end

    it "does not consume vertical tab between destination and title" do
      out = render(%([x](url\v"title")))
      expect(out).not_to include("<a href=")
    end

    it "does not consume form feed before destination" do
      out = render("[x](\furl)")
      expect(out).not_to include("<a href=")
    end

    it "still accepts a space between destination and title" do
      out = render(%([x](url "title")))
      expect(out).to include(%(<a href="url" title="title">))
    end

    it "still accepts a tab between destination and title" do
      out = render(%([x](url\t"title")))
      expect(out).to include(%(<a href="url" title="title">))
    end

    it "still accepts one line ending between destination and title" do
      out = render(%([x](url\n"title")))
      expect(out).to include(%(<a href="url" title="title">))
    end
  end
end
