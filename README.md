# RedQuilt

A modern Markdown document processor in pure Ruby, with an arena-style AST.
Passes the full CommonMark spec test suite, and as fast as kramdown, sometimes faster.

## Installation

Add this line to Gemfile:

```ruby
gem "red_quilt"
```

## Quick Start

### Parsing and rendering

```ruby
require "red_quilt"

# Parse Markdown to a document
doc = RedQuilt.parse("# Hello\n\nThis is **bold**.")
html = doc.to_html
# => "<h1>Hello</h1>\n<p>This is <strong>bold</strong>.</p>\n"

# Or render directly (without building AST)
html = RedQuilt.render_html("# Hello\n\n**bold**")
```

### HTML is safe by default

```ruby
RedQuilt.render_html("Hi <em>tag</em>")
# => "<p>Hi &lt;em&gt;tag&lt;/em&gt;</p>\n"

RedQuilt.render_html("Hi <em>tag</em>", allow_html: true)
# => "<p>Hi <em>tag</em></p>\n"
```

## API Reference

### Document

```ruby
doc = RedQuilt.parse("# Title\n\nBody")

doc.root              # Root node (NodeRef)
doc.walk              # Traverse all nodes (block: { |node| ... } or Enumerator)
doc.to_html           # Render as HTML
doc.to_ast            # Export complete AST as Hash
doc.to_json           # Export as MDAST-compatible JSON
doc.to_mdast          # Export as MDAST Hash
doc.source_map        # Line/column lookup (lazy memoized)
doc.allow_html?       # Check HTML pass-through setting
```

### NodeRef (AST node wrapper)

```ruby
node = doc.root.children.first

# Traversal
node.type             # :heading, :paragraph, :link, etc. (Symbol)
node.children         # Array[NodeRef]
node.walk             # Enumerator[NodeRef] or { |node| ... } block
node.find_all(:link)  # Array[NodeRef] with matching type
node.text             # String (concatenated child text)

# Position information (byte offset)
node.source_span      # SourceSpan with start_byte, end_byte

# Position information (line/column)
node.source_location  # { start_line, start_column, end_line, end_column }
                      # line: 1-indexed, column: 0-indexed (character-based)

# AST export
node.to_h             # Export subtree as Hash[Symbol, untyped]
```

### SourceSpan

```ruby
span = node.source_span
span.start_byte       # Integer (0-indexed byte offset)
span.end_byte         # Integer (exclusive)
span.length           # Computed: end_byte - start_byte
```

## Supported Syntax

### Block elements

- Paragraphs: Plain text blocks
- Headings: ATX headings (`# Title`)
- Thematic breaks: `---`, `***`, `___`
- Code blocks: Indented and fenced (with info string)
- Block quotes: `> quote text`
- Lists: Ordered (`1.`) and unordered (`-`, `*`, `+`)
- List items: Nested blocks, tight/loose detection
- Tables: GFM syntax with header/body rows
- Raw HTML blocks: 7 types (script, comment, etc.)
- Link reference definitions: `[foo]: /url "title"`

### Inline elements

- Text: Plain strings
- Emphasis/Strong: `*em*`, `**strong**`, `_em_`, `__strong__`
- Code spans: `` `code` ``
- Links: `[text](/url)`, `[text](/url "title")`, reference links
- Images: `![alt](/url)`, `![alt](/url "title")`, reference images
- Soft/Hard line breaks: Implicit (soft) and explicit `\` or two spaces
- Raw HTML inline: `<a href="#">link</a>`
- Autolinks: `<http://example.com>`, `<user@example.com>`
- Character references: `&amp;`, `&#x27;`, etc.

## CommonMark Compatibility

RedQuilt achieves 100% compliance with the CommonMark v0.31.2 specification.

## Command-line Tool

RedQuilt ships with a `redquilt` CLI for converting Markdown files to HTML or inspecting the AST.

### Basic usage

```bash
# Convert Markdown file to HTML
redquilt input.md > output.html

# Convert from stdin
echo "# Hello" | redquilt

# Output as AST (for debugging)
redquilt --format ast input.md

# Output as MDAST-compatible JSON (for external tools)
redquilt --format json input.md

# Standalone HTML document with title
redquilt --standalone --title "My Document" input.md

# Enable GFM extended autolinks
redquilt --extended-autolinks input.md
```

### Options

```
--format FORMAT          Output format: html (default), ast, json
--allow-html             Pass raw HTML through to the output
--extended-autolinks     Linkify bare URLs and email addresses (GFM)
--[no-]standalone        Wrap HTML in full document (default: on)
--auto-title             Use the first heading's text as <title>
--title TITLE            Explicit <title> text
--lang LANG              html lang attribute (default: "en")
--css URL                Add a stylesheet link
--diagnostics            Print diagnostics to stderr
--diagnostics-only       Print diagnostics only (suppress output)
-h, --help               Show help
-v, --version            Show version
```

Exit code is 0 on success, 1 if errors are detected.

## Safe-by-Default HTML Rendering

### Security model

RedQuilt prioritizes security by default:

```ruby
# Default: All HTML is escaped, dangerous URLs blocked
RedQuilt.render_html("<script>alert('xss')</script>")
# => "<p>&lt;script&gt;alert('xss')&lt;/script&gt;</p>"

RedQuilt.render_html("[click](javascript:alert(1))")
# => "<p><a href=\"\">click</a></p>"
```

### Allowed URL schemes

In link/image destinations, only these schemes are permitted:

- Absolute: `http://`, `https://`, `ftp://`, `tel:`, `ssh://`
- Relative: `/path`, `#anchor`, `path/to/file`
- Special: `mailto:` (autolinks only)

All other schemes (`javascript:`, `data:`, `vbscript:`, etc.) are blocked by replacing the URL with an empty string.

### Opting into HTML pass-through

```ruby
# Allow raw HTML (use with trusted input only)
RedQuilt.render_html(user_markdown, allow_html: true)

# This passes HTML blocks and inline tags through unchanged
```

## Usage Examples

### Extract all headings

```ruby
doc = RedQuilt.parse(source)
headings = doc.root.find_all(:heading)

headings.each do |node|
  level = node.to_h[:attributes][:level]
  text = node.text
  puts "#{'#' * level} #{text}"
end
```

### Walk the AST with line numbers

```ruby
doc = RedQuilt.parse(source)

doc.root.walk do |node|
  loc = node.source_location
  if loc
    puts "#{node.type} at line #{loc[:start_line]}"
  end
end
```

### Export and transform

```ruby
doc = RedQuilt.parse("# Title\n\nBody with [link](/url)")
ast = doc.to_ast

# Print AST structure (for debugging)
pp ast

# Process nodes
doc.root.find_all(:link).each do |link|
  attrs = link.to_h[:attributes]
  puts "Link: #{link.text} → #{attrs[:destination]}"
end
```

## Development

### Running tests

```bash
bundle exec rake spec
```

Runs 70+ CommonMark compatibility and feature tests.

### Benchmark

```bash
ruby spec/bench_inline.rb
ruby spec/bench_block.rb
```

Profiles parse performance on various Markdown patterns.

## Performance (v0.6.0, Ruby 4.0.5)

Comparison against [kramdown](https://kramdown.gettalong.org/) on arm64-darwin (Apple Silicon), measured with `spec/bench_vs_kramdown.rb` (benchmark-ips):

| Fixture | Size | RedQuilt (i/s) | kramdown (i/s) | RedQuilt vs kramdown |
|---------|-----:|---------------:|---------------:|---------------------:|
| short_paragraph | 49 B | 26,543 | 5,846 | 4.54x faster |
| long_paragraph | 1.4 KB | 1,184 | 932 | 1.27x faster |
| nested_emphasis | 1.4 KB | 907 | 783 | within error |
| many_links | 2.0 KB | 1,012 | 734 | 1.38x faster |
| mixed_markup | 1.8 KB | 950 | 768 | 1.24x faster |
| deep_nesting | 800 B | 758 | 332 | 2.29x faster |
| cmark_spec | 205 KB | 33.0 | 28.4 | within error |

Reproduce locally:

```bash
bundle exec ruby spec/bench_vs_kramdown.rb
```

## License

MIT
