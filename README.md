# Markdast

`markdast` is a Ruby Markdown processor built around an arena-style AST. Internally it stores nodes in parallel arrays keyed by `node_id`, while the public API exposes lightweight `Document` and `NodeRef` wrappers for traversal.

## Installation

Add this line to your application's Gemfile:

```ruby
gem "markdast"
```

## Usage

```ruby
require "markdast"

doc = Markdast.parse("# Hello\n\nThis is *markdast*.")
doc.root.children.each do |node|
  p [node.type, node.text, node.source_span]
end

html = doc.to_html
# => "<h1>Hello</h1>\n<p>This is <em>markdast</em>.</p>\n"
```

You can also render directly:

```ruby
Markdast.render_html("Hi <em>tag</em>")
# => "<p>Hi &lt;em&gt;tag&lt;/em&gt;</p>\n"

Markdast.render_html("Hi <em>tag</em>", allow_html: true)
# => "<p>Hi <em>tag</em></p>\n"
```

## Supported in v1

- Block nodes: document, paragraph, ATX heading, thematic break, blockquote, ordered and unordered list, list item, fenced and indented code block, table, raw HTML block
- Inline nodes: text, softbreak, hardbreak, emphasis, strong, code span, link, image, raw HTML inline
- Traversal: `Document#root`, `NodeRef#children`, `NodeRef#walk`, `NodeRef#text`, `NodeRef#source_span`
- Rendering: `Document#to_html`, `Markdast.render_html`

## Development

Run:

```bash
bundle exec rake spec
```
