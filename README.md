# RedQuilt

A modern Markdown document processor in pure Ruby, with an arena-style AST.
Passes the full CommonMark spec test suite, and generally faster than kramdown.

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

### Options

`RedQuilt.parse` and `RedQuilt.render_html` accept:

| Option | Default | Effect |
|--------|---------|--------|
| `allow_html:` | `false` | Pass raw HTML through instead of escaping it |
| `disallow_raw_html:` | `false` | With `allow_html`, still neutralize GFM's dangerous tags (`<script>`, `<iframe>`, …) |
| `extended_autolinks:` | `false` | GFM: linkify bare `http(s)://` / `www.` / email addresses |
| `footnotes:` | `false` | GFM footnotes (see below) |
| `lint:` | `false` | Collect lint diagnostics (empty links, missing image alt, heading-level skips) |

### Footnotes (opt-in)

```ruby
RedQuilt.render_html(<<~MD, footnotes: true)
  Here is a reference.[^1]

  [^1]: And the footnote text.
MD
# The reference becomes a superscript link, and a trailing
# <section class="footnotes"> lists the referenced definitions (in
# first-reference order) with backrefs.
```

### Diagnostics

Parsing never raises on malformed input; warnings are collected on the document.

```ruby
doc = RedQuilt.parse("[x](javascript:alert(1))", lint: true)
doc.diagnostics.map(&:rule)   # => [:unsafe_url]
doc.diagnostics.first.severity # => :warning
```

### Heading anchors (opt-in)

`render_html` / `to_html` accept `heading_ids:` to give every heading a
slugified `id` for anchor links. Slugs follow GitHub's scheme but keep Unicode
intact, so Japanese headings stay readable; duplicates get `-1`, `-2` suffixes.

```ruby
RedQuilt.render_html("# Hello World\n\n## はじめに", heading_ids: true)
# => "<h1 id=\"hello-world\">Hello World</h1>\n<h2 id=\"はじめに\">はじめに</h2>\n"
```

### Tilt integration

RedQuilt ships a [Tilt](https://github.com/jeremyevans/tilt) adapter.
NOTE: It is not loaded by default; require it explicitly and add `tilt` to your own bundle:

```ruby
require "red_quilt/tilt"

Tilt.new("page.md").render          # => HTML
Tilt.new("page.md", footnotes: true).render
```

Native options (`allow_html:`, `footnotes:`, …) pass straight through; Tilt's `escape_html:` convention is also honored.

## Documentation

- [API reference](docs/api.md) — `Document` / `NodeRef` / `SourceSpan`, supported syntax, and usage examples
- [Architecture overview](docs/architecture.ja.md) (日本語)
- [Arena usage guide](docs/arena-usage.ja.md) (日本語)
- [CommonMark conformance notes](docs/commonmark-conformance.ja.md) (日本語)

## CommonMark Compatibility

RedQuilt achieves 100% compliance with the CommonMark v0.31.2 specification.
See the [conformance notes](docs/commonmark-conformance.ja.md) for GFM
extensions and intentional deviations.

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

# Enable GFM extended autolinks / footnotes
redquilt --extended-autolinks --footnotes input.md

# Standalone page with the bare template (no embedded CSS)
redquilt --theme none input.md

# Write HTML to a file instead of stdout
redquilt -o output.html input.md

# Render and open the result in the default browser
redquilt --open input.md
```

### Options

```
--format FORMAT          Output format: html (default), ast, json
--allow-html             Pass raw HTML through to the output
--disallow-raw-html      With --allow-html, filter GFM's dangerous tags
--extended-autolinks     Linkify bare URLs and email addresses (GFM)
--footnotes              Enable GFM footnotes
--lint                   Collect lint diagnostics
--[no-]standalone        Wrap HTML in full document (default: on)
--auto-title             Use the first heading's text as <title>
--title TITLE            Explicit <title> text
--lang LANG              html lang attribute (default: "en")
--css URL                Add a stylesheet link
--theme THEME            Embedded stylesheet: default (default) or none
-o, --output FILE        Write HTML to FILE instead of stdout
--open                   Write HTML to a file and open it in the default
                         browser (forces --standalone; uses a file under
                         Dir.tmpdir when -o is not given)
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

Autolinks (`<scheme:...>`) follow CommonMark and allow arbitrary schemes, so they use a denylist instead: only the script-executing schemes `javascript:`, `vbscript:`, and `data:` are blocked.

### Opting into HTML pass-through

```ruby
# Allow raw HTML (use with trusted input only)
RedQuilt.render_html(user_markdown, allow_html: true)

# This passes HTML blocks and inline tags through unchanged
```

## Development

### Running tests

```bash
bundle exec rake spec
```

Runs the full CommonMark 0.31.2 conformance suite (all 652 official examples,
parsed directly from `spec/fixtures/cmark_spec-0.31.2.md`) plus RedQuilt's own
feature tests — 1000 examples in total.

### Benchmark

```bash
ruby spec/bench_inline.rb
ruby spec/bench_block.rb
```

Profiles parse performance on various Markdown patterns.

## Performance (v0.6.1, Ruby 4.0.5)

Comparison against [kramdown](https://kramdown.gettalong.org/) on arm64-darwin (Apple Silicon), measured with `spec/bench_vs_kramdown.rb` (benchmark-ips):

| Fixture | Size | RedQuilt (i/s) | kramdown (i/s) | RedQuilt vs kramdown |
|---------|-----:|---------------:|---------------:|---------------------:|
| short_paragraph | 49 B | 26,531 | 5,416 | 4.90x faster |
| long_paragraph | 1.4 KB | 981 | 926 | within error |
| nested_emphasis | 1.4 KB | 999 | 689 | 1.45x faster |
| many_links | 2.0 KB | 1,131 | 794 | 1.43x faster |
| mixed_markup | 1.8 KB | 1,028 | 729 | 1.41x faster |
| deep_nesting | 800 B | 827 | 349 | 2.37x faster |
| cmark_spec | 205 KB | 39.1 | 30.2 | 1.30x faster |

Reproduce locally:

```bash
bundle exec ruby spec/bench_vs_kramdown.rb
```

## License

MIT
