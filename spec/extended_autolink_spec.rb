# frozen_string_literal: true

RSpec.describe "GFM extended autolinks" do
  def render(src)
    Mdarena.render_html(src, extended_autolinks: true)
  end

  describe "URL forms" do
    it "linkifies bare http URLs" do
      expect(render("see http://example.com here\n"))
        .to eq(%(<p>see <a href="http://example.com">http://example.com</a> here</p>\n))
    end

    it "linkifies bare https URLs" do
      expect(render("https://example.com\n"))
        .to eq(%(<p><a href="https://example.com">https://example.com</a></p>\n))
    end

    it "linkifies bare www. URLs with implicit http:// scheme" do
      expect(render("www.commonmark.org\n"))
        .to eq(%(<p><a href="http://www.commonmark.org">www.commonmark.org</a></p>\n))
    end

    it "linkifies ftp URLs" do
      expect(render("ftp://example.com/file\n"))
        .to include(%(<a href="ftp://example.com/file">ftp://example.com/file</a>))
    end
  end

  describe "trailing punctuation handling" do
    it "excludes a trailing period from the link" do
      expect(render("Visit www.commonmark.org.\n"))
        .to include(%(<a href="http://www.commonmark.org">www.commonmark.org</a>.))
    end

    it "excludes trailing comma" do
      expect(render("at http://example.com, then\n"))
        .to include(%(<a href="http://example.com">http://example.com</a>,))
    end

    it "drops trailing unmatched closing parens" do
      out = render("(see https://example.com/x)\n")
      expect(out).to include(%(<a href="https://example.com/x">https://example.com/x</a>))
      expect(out).to end_with(")</p>\n")
    end

    it "keeps balanced parens inside the URL" do
      url = "https://en.wikipedia.org/wiki/Foo(bar)"
      out = render("see #{url}\n")
      expect(out).to include(%(<a href="#{url}">#{url}</a>))
    end

    it "strips a trailing entity-like &xxx;" do
      out = render("www.google.com/search?q=commonmark&hl;\n")
      expect(out).to include(%(<a href="http://www.google.com/search?q=commonmark">www.google.com/search?q=commonmark</a>))
    end
  end

  describe "email addresses" do
    it "linkifies plain emails with mailto:" do
      expect(render("reach me at user@example.com please\n"))
        .to include(%(<a href="mailto:user@example.com">user@example.com</a>))
    end
  end

  describe "skip contexts" do
    it "does not linkify inside an existing link" do
      out = render("[click](http://x.test) www.example.com\n")
      expect(out).to include(%(<a href="http://x.test">click</a>))
      expect(out).to include(%(<a href="http://www.example.com">www.example.com</a>))
    end

    it "does not linkify inside code spans" do
      out = render("`see www.example.com`\n")
      expect(out).to include("<code>see www.example.com</code>")
      expect(out).not_to include("<a href=")
    end

    it "does not linkify when preceded by a word character" do
      out = render("xhttp://example.com\n")
      expect(out).not_to include("<a href=")
    end
  end

  describe "opt-in" do
    it "is disabled by default" do
      expect(Mdarena.render_html("http://example.com\n"))
        .to eq("<p>http://example.com</p>\n")
    end
  end
end
