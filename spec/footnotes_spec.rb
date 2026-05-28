# frozen_string_literal: true

# GitHub-style footnotes (opt-in via `footnotes: true`). References render
# as superscript links; only referenced definitions render, numbered in
# first-reference order, in a trailing <section class="footnotes">.
RSpec.describe "footnotes" do
  def render(src)
    RedQuilt.render_html(src, footnotes: true)
  end

  it "renders a reference as a superscript link and a trailing definition" do
    html = render("Here is a ref.[^1]\n\n[^1]: The note.\n")

    expect(html).to include(%(<sup><a href="#fn-1" id="fnref-1">1</a></sup>))
    expect(html).to include(%(<section class="footnotes">\n<ol>\n<li id="fn-1">))
    expect(html).to include(%(<p>The note. <a href="#fnref-1">&#8617;</a></p>))
  end

  it "numbers footnotes in first-reference order, not definition order" do
    html = render("See[^b] and[^a].\n\n[^a]: A.\n[^b]: B.\n")

    expect(html).to include(%(See<sup><a href="#fn-1" id="fnref-1">1</a></sup>))
    expect(html).to include(%(and<sup><a href="#fn-2" id="fnref-2">2</a></sup>))
    # The definition list is ordered by reference: B (fn-1) before A (fn-2).
    expect(html.index(%(<li id="fn-1">\n<p>B.))).to be < html.index(%(<li id="fn-2">\n<p>A.))
  end

  it "supports a forward reference (ref before its definition)" do
    expect(render("Ref[^1] first.\n\n[^1]: defined later\n")).to include(%(<a href="#fn-1" id="fnref-1">1</a>))
  end

  it "emits one backref per reference for a footnote referenced multiple times" do
    html = render("A[^a] then B[^a].\n\n[^a]: Shared.\n")

    expect(html).to include(%(B<sup><a href="#fn-1" id="fnref-1-2">1</a></sup>))
    expect(html).to include(%(Shared. <a href="#fnref-1">&#8617;</a> <a href="#fnref-1-2">&#8617;<sup>2</sup></a>))
  end

  it "drops definitions that are never referenced" do
    html = render("Ref[^used].\n\n[^used]: kept\n[^unused]: DROPPED\n")

    expect(html).to include("kept")
    expect(html).not_to include("DROPPED")
    expect(html.scan("<li").length).to eq(1)
  end

  it "leaves an undefined reference as literal text" do
    html = render("Missing[^x] here.\n")

    expect(html).to eq("<p>Missing[^x] here.</p>\n")
  end

  it "matches labels case- and whitespace-folded" do
    expect(render("Ref[^Foo].\n\n[^foo]: matches\n")).to include(%(<li id="fn-1">))
  end

  it "lazily continues a definition's paragraph onto an unindented line" do
    html = render("Ref[^1].\n\n[^1]: line one\nline two\n")

    expect(html).to include("<p>line one\nline two <a href=\"#fnref-1\">&#8617;</a></p>")
  end

  it "does not absorb a following footnote definition as lazy continuation" do
    html = render("A[^1] B[^2]\n\n[^1]: first\n[^2]: second\n")

    expect(html.scan("<li").length).to eq(2)
    expect(html).to include("<p>first <a")
    expect(html).to include("<p>second <a")
  end

  it "ends lazy continuation at a block-start line" do
    html = render("Ref[^1].\n\n[^1]: note text\n# Heading\n")

    expect(html).to include("<p>note text <a href=\"#fnref-1\">&#8617;</a></p>")
    expect(html).to include("<h1>Heading</h1>")
  end

  it "puts the backref in the last paragraph of a multi-paragraph definition" do
    html = render("Ref[^1].\n\n[^1]: Para one.\n\n    Para two.\n")

    expect(html).to include("<p>Para one.</p>\n<p>Para two. <a href=\"#fnref-1\">&#8617;</a></p>")
  end

  it "numbers footnotes referenced only from inside another footnote" do
    html = render("Ref[^a].\n\n[^a]: See[^b].\n[^b]: B.\n")

    expect(html).to include(%(See<sup><a href="#fn-2" id="fnref-2">2</a></sup>))
    expect(html).to include(%(<li id="fn-2">))
  end

  it "takes precedence over inline-link syntax after the reference" do
    html = render("X[^1](http://e.com)\n\n[^1]: n\n")

    expect(html).to include(%(X<sup><a href="#fn-1" id="fnref-1">1</a></sup>(http://e.com)))
    expect(html).not_to include(%(href="http://e.com"))
  end

  it "keeps the arena consistent after reordering and dropping definitions" do
    doc = RedQuilt.parse("A[^x] B[^y]\n\n[^x]: x\n[^y]: y\n[^z]: z\n", footnotes: true)

    expect { doc.arena.check_integrity!(doc.root_id) }.not_to raise_error
  end

  it "exports footnote nodes to mdast" do
    mdast = RedQuilt.parse("Ref[^1]\n\n[^1]: note\n", footnotes: true).to_mdast
    types = []
    walk = lambda do |n|
      types << n["type"]
      (n["children"] || []).each(&walk)
    end
    walk.call(mdast)

    expect(types).to include("footnoteReference", "footnoteDefinition")
  end

  describe "when disabled (default)" do
    it "does not produce a footnotes section or superscript references" do
      html = RedQuilt.render_html("Ref[^1]\n\n[^1]: note\n")

      expect(html).not_to include("<section")
      expect(html).not_to include("<sup>")
    end
  end
end
