# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
