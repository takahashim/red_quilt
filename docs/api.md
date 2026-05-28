# RedQuilt API Reference

Detailed API, supported syntax, and usage examples. For installation and a
quick start, see the [README](../README.md).

## Document

```ruby
doc = RedQuilt.parse("# Title\n\nBody")

doc.root              # Root node (NodeRef)
doc.walk              # Traverse all nodes (block: { |node| ... } or Enumerator)
doc.to_html           # Render as HTML (see options below)
doc.to_ast            # Export complete AST as Hash
doc.to_json           # Export as MDAST-compatible JSON
doc.to_mdast          # Export as MDAST Hash
doc.source_map        # Line/column lookup (lazy memoized)
doc.diagnostics       # Array of RedQuilt::Diagnostic collected while parsing
doc.allow_html?       # Check HTML pass-through setting
doc.disallow_raw_html? # Check GFM disallowed-raw-HTML filtering setting

# Standalone document with an embedded theme:
doc.to_html(standalone: true, theme: :default, title: "My Doc", lang: "en")
# theme: :default (compact, dark-mode-aware stylesheet) or :none (bare).
# css: "style.css" links an external stylesheet instead.
```

## NodeRef (AST node wrapper)

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

## SourceSpan

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
- Footnote definitions: `[^label]: …` (GFM, opt-in via `footnotes: true`)

### Inline elements

- Text: Plain strings
- Emphasis/Strong: `*em*`, `**strong**`, `_em_`, `__strong__`
- Strikethrough: `~~text~~` (GFM)
- Code spans: `` `code` ``
- Links: `[text](/url)`, `[text](/url "title")`, reference links
- Images: `![alt](/url)`, `![alt](/url "title")`, reference images
- Soft/Hard line breaks: Implicit (soft) and explicit `\` or two spaces
- Raw HTML inline: `<a href="#">link</a>`
- Autolinks: `<http://example.com>`, `<user@example.com>`
- Footnote references: `[^label]` (GFM, opt-in via `footnotes: true`)
- Character references: `&amp;`, `&#x27;`, etc.

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
