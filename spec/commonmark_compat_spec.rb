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
      number: 418,
      section: "Emphasis and strong emphasis",
      markdown: "*foo **bar *baz* bim** bop*\n",
      html: "<p><em>foo <strong>bar <em>baz</em> bim</strong> bop</em></p>\n"
    },
    {
      number: 482,
      section: "Inline links",
      markdown: "[link](/uri \"title\")\n",
      html: "<p><a href=\"/uri\" title=\"title\">link</a></p>\n"
    },
    {
      number: 594,
      section: "Autolinks",
      markdown: "<http://foo.bar.baz>\n",
      html: "<p><a href=\"http://foo.bar.baz\">http://foo.bar.baz</a></p>\n"
    },
    {
      number: 595,
      section: "Autolinks",
      markdown: "<https://foo.bar.baz/test?q=hello&id=22&boolean>\n",
      html: "<p><a href=\"https://foo.bar.baz/test?q=hello&amp;id=22&amp;boolean\">https://foo.bar.baz/test?q=hello&amp;id=22&amp;boolean</a></p>\n"
    },
    {
      number: 193,
      section: "Link reference definitions",
      markdown: "   [foo]:\n      /url\n           'the title'\n[foo]\n",
      html: "<p><a href=\"/url\" title=\"the title\">foo</a></p>\n"
    },
    {
      number: 196,
      section: "Link reference definitions",
      markdown: "[foo]: /url '\ntitle\nline1\nline2\n'\n\n[foo]\n",
      html: "<p><a href=\"/url\" title=\"\ntitle\nline1\nline2\n\">foo</a></p>\n"
    },
    {
      number: 217,
      section: "Link reference definitions",
      markdown: "[foo]: /foo-url \"foo\"\n[bar]: /bar-url\n  \"bar\"\n[baz]: /baz-url\n\n[foo],\n[bar],\n[baz]\n",
      html: "<p><a href=\"/foo-url\" title=\"foo\">foo</a>,\n<a href=\"/bar-url\" title=\"bar\">bar</a>,\n<a href=\"/baz-url\">baz</a></p>\n"
    },
    {
      number: 218,
      section: "Link reference definitions",
      markdown: "[foo]\n\n> [foo]: /url\n",
      html: "<p><a href=\"/url\">foo</a></p>\n<blockquote>\n</blockquote>\n"
    },
    {
      number: 617,
      section: "Raw HTML",
      markdown: "Foo <responsive-image src=\"foo.jpg\" />\n",
      html: "<p>Foo <responsive-image src=\"foo.jpg\" /></p>\n"
    },
    {
      number: 618,
      section: "Raw HTML",
      markdown: "<33> <__>\n",
      html: "<p>&lt;33&gt; &lt;__&gt;</p>\n"
    },
    {
      number: 619,
      section: "Raw HTML",
      markdown: "<a h*#ref=\"hi\">\n",
      html: "<p>&lt;a h*#ref=&quot;hi&quot;&gt;</p>\n"
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
    },
    {
      number: 596,
      section: "Autolinks",
      markdown: "<foo@bar.example.com>\n",
      html: "<p><a href=\"mailto:foo@bar.example.com\">foo@bar.example.com</a></p>\n"
    },
    {
      number: 597,
      section: "Autolinks",
      markdown: "<foo+special@Bar.baz-bar0.com>\n",
      html: "<p><a href=\"mailto:foo+special@Bar.baz-bar0.com\">foo+special@Bar.baz-bar0.com</a></p>\n"
    },
    {
      number: 148,
      section: "HTML blocks",
      markdown: "<table>\n  <tr>\n    <td>\n           hi\n    </td>\n  </tr>\n</table>\n\nokay.\n",
      html: "<table>\n  <tr>\n    <td>\n           hi\n    </td>\n  </tr>\n</table>\n<p>okay.</p>\n"
    },
    {
      number: 149,
      section: "HTML blocks",
      markdown: "<pre>\n *foo*\n</pre>\n*bar*\n",
      html: "<pre>\n *foo*\n</pre>\n<p><em>bar</em></p>\n"
    },
    {
      number: 152,
      section: "HTML blocks",
      markdown: "<!-- foo -->\n\n    <!-- foo -->\n",
      html: "<!-- foo -->\n<pre><code>&lt;!-- foo --&gt;\n</code></pre>\n"
    },
    {
      number: 192,
      section: "Link reference definitions",
      markdown: "[foo]: /url \"title\"\n\n[foo]\n",
      html: "<p><a href=\"/url\" title=\"title\">foo</a></p>\n"
    },
    {
      number: 206,
      section: "Link reference definitions",
      markdown: "[foo]\n\n[foo]: /url\n[foo]: /url2\n",
      html: "<p><a href=\"/url\">foo</a></p>\n"
    },
    {
      number: 207,
      section: "Link reference definitions",
      markdown: "[FOO]:\n   /url\n\n[Foo]\n",
      html: "<p><a href=\"/url\">Foo</a></p>\n"
    },
    {
      number: 209,
      section: "Link reference definitions",
      markdown: "[foo][]\n\n[foo]: /url \"title\"\n",
      html: "<p><a href=\"/url\" title=\"title\">foo</a></p>\n"
    },
    {
      number: 545,
      section: "Reference links",
      markdown: "[foo *bar*]\n\n[foo *bar*]: /url\n",
      html: "<p><a href=\"/url\">foo <em>bar</em></a></p>\n"
    },
    {
      number: 571,
      section: "Images",
      markdown: "![foo](/url \"title\")\n",
      html: "<p><img src=\"/url\" alt=\"foo\" title=\"title\" /></p>\n"
    },
    {
      number: 589,
      section: "Reference images",
      markdown: "![foo]\n\n[foo]: /url \"title\"\n",
      html: "<p><img src=\"/url\" alt=\"foo\" title=\"title\" /></p>\n"
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
