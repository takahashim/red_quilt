# Mdarena

A pragmatic Markdown document processor for Ruby, with an arena-style AST, source spans, safe-by-default HTML rendering, and optional performance optimizations.

## Installation

Add this line to your application's Gemfile:

```ruby
gem "mdarena"
```

## Quick Start

### Parsing and rendering

```ruby
require "mdarena"

# Parse Markdown to a document
doc = Mdarena.parse("# Hello\n\nThis is **bold**.")
html = doc.to_html
# => "<h1>Hello</h1>\n<p>This is <strong>bold</strong>.</p>\n"

# Or render directly (without building AST)
html = Mdarena.render_html("# Hello\n\n**bold**")
```

### HTML is safe by default

```ruby
Mdarena.render_html("Hi <em>tag</em>")
# => "<p>Hi &lt;em&gt;tag&lt;/em&gt;</p>\n"

Mdarena.render_html("Hi <em>tag</em>", allow_html: true)
# => "<p>Hi <em>tag</em></p>\n"
```

## API Reference

### Document

```ruby
doc = Mdarena.parse("# Title\n\nBody")

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

### SourceMap

```ruby
map = doc.source_map
loc = map.line_column(byte_offset)
# => { line: 3, column: 5 }
```

## Supported Syntax

### Block elements (✅ full support)

- **Paragraphs**: Plain text blocks
- **Headings**: ATX headings (`# Title`)
- **Thematic breaks**: `---`, `***`, `___`
- **Code blocks**: Indented and fenced (with info string)
- **Block quotes**: `> quote text`
- **Lists**: Ordered (`1.`) and unordered (`-`, `*`, `+`)
- **List items**: Nested blocks, tight/loose detection
- **Tables**: GFM syntax with header/body rows
- **Raw HTML blocks**: 7 types (script, comment, etc.)
- **Link reference definitions**: `[foo]: /url "title"`

### Inline elements (✅ mostly supported)

- **Text**: Plain strings
- **Emphasis/Strong**: `*em*`, `**strong**`, `_em_`, `__strong__`
- **Code spans**: `` `code` ``
- **Links**: `[text](/url)`, `[text](/url "title")`, reference links
- **Images**: `![alt](/url)`, `![alt](/url "title")`, reference images
- **Soft/Hard line breaks**: Implicit (soft) and explicit `\` or two spaces
- **Raw HTML inline**: `<a href="#">link</a>`
- **Autolinks**: `<http://example.com>`, `<user@example.com>`
- **Character references**: `&amp;`, `&#x27;`, etc.

## CommonMark Compatibility

Mdarena achieves 100% compliance with the CommonMark v0.31.2 specification.

### Fully supported features

| Feature | Status | Notes |
|---------|--------|-------|
| Tabs | ✅ | |
| ATX headings | ✅ | |
| Thematic breaks | ✅ | |
| Indented code blocks | ✅ | |
| Fenced code blocks | ✅ | Info string: first word becomes `language-xxx` class |
| HTML blocks (types 1-7) | ✅ | All CommonMark types with correct termination |
| Block quotes | ✅ | |
| Lists (ordered/unordered) | ✅ | Tight/loose detection |
| List items | ✅ | Nested content, continuation rules |
| Link reference definitions | ✅ | Case/whitespace normalization |
| Emphasis/Strong | ✅ | Full delimiter-run stack (CommonMark spec 6.2) |
| Code spans | ✅ | |
| Links | ✅ | Inline and reference forms |
| Images | ✅ | Inline and reference forms |
| Autolinks | ✅ | URI (`<http://...>`) and email (`<user@...>`) |
| Extended Autolinks | ✅ | GFM: bare URLs and email (enable with `extended_autolinks: true`) |
| Raw HTML inline | ✅ | Escaped by default, passable with `allow_html: true` |
| Hard/soft line breaks | ✅ | Two spaces or backslash for hard break |
| Backslash escapes | ✅ | All punctuation escapes supported |
| Character references | ✅ | Full HTML5 entity support |

All CommonMark v0.31.2 specification test cases pass without exception.

## Command-line Tool

Mdarena ships with a `mdarena` CLI for converting Markdown files to HTML or inspecting the AST.

### Basic usage

```bash
# Convert Markdown file to HTML
mdarena input.md > output.html

# Convert from stdin
echo "# Hello" | mdarena

# Output as AST (for debugging)
mdarena --format ast input.md

# Output as MDAST-compatible JSON (for external tools)
mdarena --format json input.md

# Standalone HTML document with title
mdarena --standalone --title "My Document" input.md

# Enable GFM extended autolinks
mdarena --extended-autolinks input.md
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

Mdarena prioritizes **security by default**:

```ruby
# Default: All HTML is escaped, dangerous URLs blocked
Mdarena.render_html("<script>alert('xss')</script>")
# => "<p>&lt;script&gt;alert('xss')&lt;/script&gt;</p>"

Mdarena.render_html("[click](javascript:alert(1))")
# => "<p><a href=\"\">click</a></p>"
```

### Allowed URL schemes

In link/image destinations, only these schemes are permitted:

- **Absolute**: `http://`, `https://`, `ftp://`, `tel:`, `ssh://`
- **Relative**: `/path`, `#anchor`, `path/to/file`
- **Special**: `mailto:` (autolinks only)

All other schemes (`javascript:`, `data:`, `vbscript:`, etc.) are blocked by replacing the URL with an empty string.

### Opting into HTML pass-through

```ruby
# Allow raw HTML (use with trusted input only)
Mdarena.render_html(user_markdown, allow_html: true)

# This passes HTML blocks and inline tags through unchanged
```

## Usage Examples

### Extract all headings

```ruby
doc = Mdarena.parse(source)
headings = doc.root.find_all(:heading)

headings.each do |node|
  level = node.to_h[:attributes][:level]
  text = node.text
  puts "#{'#' * level} #{text}"
end
```

### Walk the AST with line numbers

```ruby
doc = Mdarena.parse(source)

doc.root.walk do |node|
  loc = node.source_location
  if loc
    puts "#{node.type} at line #{loc[:start_line]}"
  end
end
```

### Export and transform

```ruby
doc = Mdarena.parse("# Title\n\nBody with [link](/url)")
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
```

Profiles parse performance on various Markdown patterns.

## Performance (v1.2.0, Ruby 4.0.5)

Mdarena achieves **kramdown parity** with the CommonMark compliance to spare.

**v1.2.0 results** (inline pipeline redesign):

| Fixture | i/s | Improvement (v1.0 → v1.2) |
|---------|-----|--------------------------|
| Short paragraph | ~25,200 | **3.8x** |
| Long paragraph | ~1,130 | **30.5x** ✨ |
| Nested emphasis | ~905 | **10.2x** |
| Mixed markup | ~885 | **6.6x** |
| Deep nesting | ~690 | **10.0x** |
| Many links | ~1,320 | **2.6x** |

## License

MIT

## Contributing

Issues and pull requests welcome. See [ast-spec.md](ast-spec.md) for design notes on the Arena AST architecture.
