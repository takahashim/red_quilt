# frozen_string_literal: true

require "spec_helper"

# GFM strikethrough: ~~foo~~ -> <del>foo</del>
# Based on the GFM spec extension. Strikethrough uses run length 2 (~~);
# a single `~` is left as text. Triple-tilde at the start of a paragraph
# is not tested here because the block parser claims `~~~` as a fenced
# code block fence (which is the CommonMark / GFM behavior).

RSpec.describe "GFM strikethrough" do
  def render(src)
    RedQuilt.render_html(src)
  end

  it "wraps a simple run in <del>" do
    expect(render("~~foo~~\n")).to eq("<p><del>foo</del></p>\n")
  end

  it "works in the middle of a word" do
    expect(render("a~~b~~c\n")).to eq("<p>a<del>b</del>c</p>\n")
  end

  it "leaves single tildes as text" do
    expect(render("~not strikethrough~\n"))
      .to eq("<p>~not strikethrough~</p>\n")
  end

  it "covers multi-word content" do
    expect(render("foo ~~bar baz~~ qux\n"))
      .to eq("<p>foo <del>bar baz</del> qux</p>\n")
  end

  it "nests inside emphasis" do
    expect(render("*em ~~struck~~ rest*\n"))
      .to eq("<p><em>em <del>struck</del> rest</em></p>\n")
  end

  it "nests strikethrough containing emphasis" do
    expect(render("~~struck *em* rest~~\n"))
      .to eq("<p><del>struck <em>em</em> rest</del></p>\n")
  end

  it "does not interpret tildes inside a code span" do
    expect(render("`~~foo~~`\n"))
      .to eq("<p><code>~~foo~~</code></p>\n")
  end

  it "leaves trailing single tilde as text after a closed strikethrough" do
    expect(render("~~foo~~~\n"))
      .to eq("<p><del>foo</del>~</p>\n")
  end

  it "renders strikethrough inside a link label" do
    expect(render("[~~struck~~](/url)\n"))
      .to eq("<p><a href=\"/url\"><del>struck</del></a></p>\n")
  end
end
