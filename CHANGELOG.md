# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Breaking: source positions now follow the unist Point convention**, which
  cmark sourcepos and mdast both use. Three related changes:
  - `source_location` columns are 1-based (they were 0-based; lines were
    already 1-based). Both are counted in characters, and `end` remains
    exclusive.
  - Block spans cover the block as authored rather than its content alone.
    `# H1` now starts at the `#`, `> quote` at the `>`, a list item at its
    bullet, a fenced code block includes both fences, and a setext heading
    includes its `===` / `---` underline.
  - Leading indent is excluded from block spans, so `  text` starts at
    column 3 rather than column 1. This applies to ATX and setext headings,
    paragraphs, blockquotes, fenced code blocks, lists, list items, and
    thematic breaks.
  - The fenced code block change also fixes a wrong *line* number: the span
    used to start at the first content line, reporting the block one line
    below its opening fence.

  Every expected value was verified against commonmark.js and
  mdast-util-from-markdown; RedQuilt now agrees with mdast on all of them
  except an unclosed fence, where the two references disagree and RedQuilt
  follows cmark. Callers that added 1 to columns, or that relied on a
  heading span excluding `# `, need updating.

  `NodeRef#text` is unaffected: a heading's text remains its content, without
  the marker.

- **Breaking: `NodeRef#info` returns nil for nodes that are not code
  blocks**, where 0.8.0 returned `""`. A code block written without an info
  string still returns `""`, so the two cases are now distinguishable. This
  matches the new attribute accessors, which all use nil for "this node's
  type does not carry the attribute".
- Lowered the minimum supported Ruby from 3.3 to 3.1. The only 3.1
  incompatibility was `String#byteindex` (added in Ruby 3.2), used in two
  inline hot paths; both operate on a binary (`String#b`) view of the source,
  where `String#index` returns the same byte offsets. CI now runs the test
  suite on 3.1 through 4.0.
- `Gemfile.lock` is no longer committed. A lockfile resolved on one Ruby pins
  development gem versions that do not exist for the others (e.g. `rdoc 8.0.0`
  and `rbs 4.0.3` have no Ruby 3.1 release), so a single committed lockfile
  cannot serve the supported range. Each Ruby now resolves its own.

### Fixed

- `source_location` reported wrong line numbers for any source containing a
  multibyte character. The line-start table is indexed by byte offset, but it
  was built with `String#index`, which counts characters, so every line after
  the first multibyte character drifted. Existing multibyte coverage did not
  catch this because it used single-line sources.
- `Renderer::MDAST` emitted positions that violated the unist spec: `column`
  was 0-based where unist requires 1-based, and `offset` was a byte index
  where unist requires a 0-based character index. The latter made every
  offset after a multibyte character wrong.

### Added

- Node attribute accessors on `NodeRef`: `heading_level`, `list_ordered?`,
  `list_start`, `list_tight?`, `list_delimiter`, `link_destination`,
  `link_title`, `footnote_label`, `footnote_number`, and `header?`. Each
  returns nil when the node's type does not carry the attribute, so callers
  can walk a document branching on `#type` and read that type's fields
  directly. Previously the only public route was `#to_h`, which builds a Hash
  for the whole subtree — 5391 objects for a 257-node list where these
  accessors allocate none.

  These wrappers are the safe way to read attributes. The `Arena` accessors
  they delegate to are the raw layer and skip the type check, and several
  attributes share a storage column, so reading one off a mismatched node
  there returns another field's value rather than nil (`Arena#link_destination`
  on a paragraph returns the paragraph's text).

- `NodeRef#info`: returns the fence info string of a code block (e.g. `ruby`
  in ` ```ruby `, or `vtt audio="x.mp3"`); `""` for code blocks written
  without one. The raw code content remains available via `NodeRef#text`.
- `Renderer::HTML#render_fragment(nodes)`: renders an Array of `NodeRef` in
  order and returns the HTML fragment without affecting the main render
  output. Renderer state shared across nodes (e.g. the heading-id slugger) is
  preserved between calls. Lets callers that partition a document render the
  pieces separately without reaching into renderer internals.
- `Arena` semantic payload accessors (`heading_level`, `list_ordered?`,
  `code_block_info`, `link_destination`, `footnote_number`, …) for callers
  that walk `Document#arena`, replacing direct use of the raw `int1`/`str2`
  columns.

## [0.7.2] - 2026-06-23

### Added

- Opt-in YAML frontmatter support via the `frontmatter:` option on `parse` /
  `render_html` and the `--frontmatter` CLI flag (off by default). A leading
  `---` … `---` block is removed from the rendered body and exposed as
  `Document#frontmatter`; in standalone output its `title` / `lang` keys fill
  in `<title>` / `<html lang>`.
- Opt-in Mermaid diagram support via the `mermaid:` option on `render_html` /
  `Document#to_html` and the `--mermaid` CLI flag (off by default). Fenced
  ` ```mermaid ` code blocks render as `<pre class="mermaid">` containers; in
  standalone output the mermaid.js runtime is loaded from a CDN and each
  diagram is made interactive (wheel zoom, drag pan, +/-/reset controls) with
  svg-pan-zoom.

## [0.7.1] - 2026-06-06

### Added

- `--open` CLI flag: render the Markdown to a standalone HTML file and open it
  in the default browser (forces `--standalone`; writes under `Dir.tmpdir`
  when `-o` is not given).

## [0.7.0] - 2026-05-29

### Added

- Optional Tilt template adapter, registered for the common markdown
  extensions (`.md`, `.markdown`, …).
- Opt-in heading anchor ids via the `heading_ids:` option on `render_html` /
  `Document#to_html`. Slugs follow GitHub's scheme but preserve Unicode, so
  non-ASCII (e.g. Japanese) headings stay readable; duplicates within a
  document get `-1`, `-2`, … suffixes.

### Fixed

- `require "red_quilt/cli"` on its own now works (cli.rb requires red_quilt).

### Internal

- Add LICENSE and gemspec metadata; move the API reference to `docs/api.md`.

## [0.6.1] - 2026-05-29

### Added

- Opt-in GitHub-style footnotes (`footnotes: true`, off by default):
  `[^label]` references and `[^label]: …` definitions (multi-paragraph and
  lazy continuation), numbered in first-reference order, rendered as a GFM
  `<section class="footnotes">` with backrefs; also emitted to mdast.
- Bundled standalone HTML theme via `Document#to_html(theme:)` / the
  `--theme` CLI flag: `default` (a compact, dark-mode-aware stylesheet
  embedded inline) or `none` (bare). CLI defaults to `default`, the library
  API to `none`.

### Security

- Block script-executing schemes (`javascript:`/`vbscript:`/`data:`) in
  autolinks, which previously rendered as links.

### Fixed

- Numeric character references: enforce digit caps; map NUL, surrogate, and
  out-of-range code points to U+FFFD.
- Enforce the 999-char link-label cap and tighten reference-definition
  destination validation.
- Restrict whitespace in autolinks, raw HTML tags, link tails, and reference
  definitions to spaces/tabs (plus one line ending); reject form feed and
  vertical tab.
- Normalize input: CRLF/CR → LF, NUL → U+FFFD.
- GFM tables: require a row's column count to match the header; reject
  autolinks with underscored domains.

### Performance

- Cut inline allocations ~43% (shared byte→char table; skip no-op string
  scans) and redundant per-line / whole-document scans in block parsing.
- Make the per-line record a positional Struct.

### Changed

- Rename `Arena#replace_str1` / `replace_int3` to `update_str1` / `update_int3`.

### Internal

- Extract `Inline::LinkScanner` and `RedQuilt::Indentation`; add
  `Arena#source_end`; consolidate ASCII-punctuation tables; make
  `Delimiter` / `Bracket` / `Line` Structs.
- Drop `__send__` between block-parser collaborators via a public
  collaborator interface on `BlockParser`.
- Add an allocation-regression CI gate and RSpec / RuboCop workflows;
  support Ruby >= 3.3.
