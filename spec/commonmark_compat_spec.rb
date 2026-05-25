# frozen_string_literal: true

# Examples are sourced from the CommonMark 0.31.2 specification:
# https://spec.commonmark.org/0.31.2/

RSpec.describe "CommonMark compatibility" do
  PASSING_EXAMPLES = [
    {
      number: 43,
      section: "Thematic breaks",
      markdown: "***\n---\n___\n",
      html: "<hr />\n<hr />\n<hr />\n"
    },
    {
      number: 62,
      section: "ATX headings",
      markdown: "# foo\n## foo\n### foo\n#### foo\n##### foo\n###### foo\n",
      html: "<h1>foo</h1>\n<h2>foo</h2>\n<h3>foo</h3>\n<h4>foo</h4>\n<h5>foo</h5>\n<h6>foo</h6>\n"
    },
    {
      number: 142,
      section: "Fenced code blocks",
      markdown: "```ruby\ndef foo(x)\n  return 3\nend\n```\n",
      html: "<pre><code class=\"language-ruby\">def foo(x)\n  return 3\nend\n</code></pre>\n"
    },
    {
      number: 228,
      section: "Block quotes",
      markdown: "> # Foo\n> bar\n> baz\n",
      html: "<blockquote>\n<h1>Foo</h1>\n<p>bar\nbaz</p>\n</blockquote>\n"
    },
    {
      number: 301,
      section: "Lists",
      markdown: "- foo\n- bar\n+ baz\n",
      html: "<ul>\n<li>foo</li>\n<li>bar</li>\n</ul>\n<ul>\n<li>baz</li>\n</ul>\n"
    },
    {
      number: 277,
      section: "Lists",
      markdown: "-  foo\n\n   bar\n",
      html: "<ul>\n<li>\n<p>foo</p>\n<p>bar</p>\n</li>\n</ul>\n"
    },
    {
      number: 328,
      section: "Code spans",
      markdown: "`foo`\n",
      html: "<p><code>foo</code></p>\n"
    },
    {
      number: 329,
      section: "Code spans",
      markdown: "`` foo ` bar ``\n",
      html: "<p><code>foo ` bar</code></p>\n"
    },
    {
      number: 416,
      section: "Emphasis and strong emphasis",
      markdown: "foo***bar***baz\n",
      html: "<p>foo<em><strong>bar</strong></em>baz</p>\n"
    },
    {
      number: 482,
      section: "Inline links",
      markdown: "[link](/uri \"title\")\n",
      html: "<p><a href=\"/uri\" title=\"title\">link</a></p>\n"
    },
    {
      number: 527,
      section: "Reference links",
      markdown: "[foo][bar]\n\n[bar]: /url \"title\"\n",
      html: "<p><a href=\"/url\" title=\"title\">foo</a></p>\n"
    },
    {
      number: 566,
      section: "Reference links",
      markdown: "[foo][]\n\n[foo]: /url1\n",
      html: "<p><a href=\"/url1\">foo</a></p>\n"
    },
    {
      number: 588,
      section: "Reference images",
      markdown: "![foo]\n\n[foo]: /url \"title\"\n",
      html: "<p><img src=\"/url\" alt=\"foo\" title=\"title\" /></p>\n"
    },
    {
      number: 572,
      section: "Images",
      markdown: "![foo](/url \"title\")\n",
      html: "<p><img src=\"/url\" alt=\"foo\" title=\"title\" /></p>\n"
    },
    {
      number: 633,
      section: "Hard line breaks",
      markdown: "foo  \nbaz\n",
      html: "<p>foo<br />\nbaz</p>\n"
    },
    {
      number: 648,
      section: "Soft line breaks",
      markdown: "foo\nbaz\n",
      html: "<p>foo\nbaz</p>\n"
    }
  ].freeze

  KNOWN_GAPS = [].freeze

  PASSING_EXAMPLES.each do |example|
    it "matches CommonMark 0.31.2 example #{example[:number]} (#{example[:section]})" do
      expect(Markdast.render_html(example[:markdown], allow_html: true)).to eq(example[:html])
    end
  end

  KNOWN_GAPS.each do |example|
    it "does not yet match CommonMark 0.31.2 example #{example[:number]} (#{example[:section]})" do
      pending(example[:reason])
      expect(Markdast.render_html(example[:markdown], allow_html: true)).to eq(example[:html])
    end
  end
end
