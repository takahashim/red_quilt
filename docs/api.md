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
doc.frontmatter       # Parsed YAML frontmatter Hash, or nil (see below)

# Standalone document with an embedded theme:
doc.to_html(standalone: true, theme: :default, title: "My Doc", lang: "en")
# theme: :default (compact, dark-mode-aware stylesheet) or :none (bare).
# css: "style.css" links an external stylesheet instead.

# Render `mermaid` code blocks as <pre class="mermaid"> diagrams; in
# standalone mode the mermaid.js runtime is loaded from a CDN too.
doc.to_html(standalone: true, mermaid: true)

# Parse a leading YAML frontmatter block (--- ... ---). Off by default; when
# enabled the block is removed from the rendered body and exposed as a Hash.
doc = RedQuilt.parse("---\ntitle: Hi\nlang: ja\n---\n\n# Body", frontmatter: true)
doc.frontmatter       # => {"title" => "Hi", "lang" => "ja"} (nil when absent/disabled)
# In standalone output frontmatter title/lang fill <title>/<html lang> unless
# an explicit argument overrides them. Invalid YAML adds a :frontmatter
# warning diagnostic and leaves doc.frontmatter as nil.
doc.to_html(standalone: true)
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

# Node attributes, by type. Each returns nil when the node's type does not
# carry the attribute, so you can branch on #type and read that type's own
# fields without building a Hash per node.
node.info             # CODE_BLOCK: fence info, e.g. "ruby". "" when the
                      # block was written without one.
node.heading_level    # HEADING: 1..6
node.list_ordered?    # LIST: true for "1.", false for "-"
node.list_start       # LIST: start number of an ordered list
node.list_tight?      # LIST: tight vs loose
node.list_delimiter   # LIST: delimiter as authored, e.g. "-" or "."
node.link_destination # LINK / IMAGE: destination URL
node.link_title       # LINK / IMAGE: title, nil when absent
node.footnote_label   # FOOTNOTE_DEFINITION / FOOTNOTE_REFERENCE: label
node.footnote_number  # FOOTNOTE_DEFINITION / FOOTNOTE_REFERENCE: 1-based
node.header?          # TABLE_ROW / TABLE_CELL: part of the header row?

# Position information (byte offset)
node.source_span      # SourceSpan with start_byte, end_byte

# Position information (line/column)
node.source_location  # { start_line, start_column, end_line, end_column }
                      # line and column are both 1-indexed and counted in
                      # characters, following the unist Point convention that
                      # cmark sourcepos and mdast use. `end` is exclusive: it
                      # is the position just past the node's last character.
                      # Block spans cover the block as authored, including
                      # markers ("# H1" starts at the "#", "```" fences are
                      # part of the code block), but excluding leading indent.

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
