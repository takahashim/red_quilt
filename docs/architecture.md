# RedQuilt Architecture Overview

This document gives a high-level view of how RedQuilt is structured.

## Pipeline

```
Source (Markdown String)
   │
   ▼ RedQuilt.normalize_input        (lib/red_quilt.rb)
   │
   ▼ BlockParser                     (lib/red_quilt/block_parser.rb)
   │ dispatch / container parsers / build_lines
   │     (list.rb, blockquote.rb, reference_definition.rb)
   │
   ▼ Arena (raw inline spans)
   │ The body of each paragraph / heading / table cell is kept
   │ as a byte span or a str1 literal.
   │
   ▼ InlinePass                      (lib/red_quilt/inline_pass.rb)
   │     ├─ Inline::Lexer            (lib/red_quilt/inline/lexer.rb)
   │     │  byte scan -> Tokens (parallel array)
   │     └─ Inline::Builder          (lib/red_quilt/inline/builder.rb)
   │        linear pass -> process_emphasis (CommonMark §6.2)
   │
   ▼ Arena (inline resolved)
   │
   ▼  (option) FootnotePass           (footnotes: true)
   ▼  (option) ExtendedAutolinkPass   (extended_autolinks: true)
   ▼  (option) LintPass               (lint: true)
   │
   ▼ Renderer::HTML                  (lib/red_quilt/renderer/html.rb)
         walk the arena and append to a mutable String
```

## Responsibility of each stage

### `RedQuilt.normalize_input`
- Minimal preprocessing required by CommonMark §2.3 / §2.4. It only normalizes
  line endings (`\r\n` / `\r` -> `\n`) and replaces NUL with U+FFFD.

### BlockParser
- Line splitting: turn the source into an array of `Line` structs. Each line is
  kept as a byte span.
- Dispatch: decide the block kind from the first byte of the line
  (`paragraph_only_line?` quickly routes non-block lines).
- Container delegation: lists and blockquotes are delegated to `List::Parser`
  and `Blockquote::Parser`, which call `parse_lines` recursively.
- Collecting and excluding definitions: link reference definitions (the
  reference table) and opt-in footnote definitions (`FootnoteRegistry`) are
  pulled out of the body flow and gathered in dedicated collectors.
- Column calculation: indentation that includes tab expansion is delegated to
  `Indentation`.
- Output: build block nodes in the Arena, with inline content still unresolved.

### InlinePass / Inline::Lexer / Inline::Builder
- Target selection: scan and process each inline target (paragraph / heading /
  table cell).
- Lexer: scan the target's byte span, or the range of a str1 literal, into
  Tokens (a parallel array).
- Builder, step 1 (linear_pass): resolve code spans, links, images, autolinks,
  and simple inlines.
- Builder, step 2 (process_emphasis): collapse the delimiter stack to finalize
  emphasis / strong / strikethrough (CommonMark §6.2; strikethrough is a GFM
  extension).
- Footnote references: resolve `[^label]` through `FootnoteRegistry`, number
  them in first-reference order, and create a `FOOTNOTE_REFERENCE`.

### FootnotePass (`footnotes: true`)
- Reordering: sort the definitions under `FOOTNOTES_SECTION` (at the end of the
  root) into first-reference order.
- Pruning: detach unreferenced definitions.
- Section removal: if there are no references at all, remove the section itself.

### Renderer::HTML
- Walk: walk the arena recursively and append directly with `<<` to a mutable
  String opened with `+""`.
- Raw HTML: `allow_html` switches between passing HTML through and escaping it;
  `disallow_raw_html` filters HTML using GFM "Disallowed Raw HTML".
- Footnotes: render `FOOTNOTE_REFERENCE` as a sup link, and the trailing
  `FOOTNOTES_SECTION` as `<section class="footnotes">` with backrefs.

## Where the main subsystems live

| Area | Files |
|---|---|
| Entry point / input normalization | `lib/red_quilt.rb` |
| Public API | `lib/red_quilt/document.rb`, `node_ref.rb` |
| Arena | `lib/red_quilt/arena.rb` |
| Block parsing | `block_parser.rb`, `list.rb`, `blockquote.rb`, `indentation.rb` |
| Reference definitions | `reference_definition.rb` |
| Footnotes (opt-in) | `footnote_definition.rb`, `footnote_registry.rb`, `footnote_pass.rb` |
| Inline parsing | `inline.rb`, `inline/lexer.rb`, `inline/tokens.rb`, `inline/flanking.rb`, `inline/builder.rb`, `inline/link_scanner.rb` |
| Inline entities | `inline/html_entities.rb` |
| HTML / MDAST output | `renderer/html.rb`, `renderer/mdast.rb` |
| Extension passes | `inline_pass.rb`, `footnote_pass.rb`, `extended_autolink_pass.rb`, `lint_pass.rb` |
| Source positions | `source_span.rb`, `source_map.rb` |
| Diagnostics | `diagnostic.rb` |
| CLI | `cli.rb`, `exe/redquilt` |
