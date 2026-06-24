# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `NodeRef#info`: returns the fence info string of a code block (e.g. `ruby`
  in ` ```ruby `, or `vtt audio="x.mp3"`); `""` for code blocks without one
  and for every other node type. The raw code content remains available via
  `NodeRef#text`.
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
