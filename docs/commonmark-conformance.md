# RedQuilt CommonMark Conformance

## 1. Scope of this document

This document describes how RedQuilt differs from the CommonMark / GFM spec.
For behavior that follows the spec, refer directly to the spec documents
(<https://spec.commonmark.org/0.31.2/>, <https://github.github.com/gfm/>); this
document does not repeat them.

#### What this document covers

- Places where the implementation **narrows** what the spec allows (interpreting
  or tightening ambiguous areas).
- Features outside the spec (security, diagnostics, option flags).
- The extensions that are **enabled** (GFM, etc.) and their opt-in conditions.
- Unsupported features and known limitations.

#### What this document does not cover

- Descriptions of standard behavior that matches the spec.
- Design background or data structure choices.

### 1.1 Target versions

- CommonMark: 0.31.2
- GitHub Flavored Markdown: 0.29-gfm

### 1.2 Implementation assumptions

- Input is a UTF-8 string. Preprocessing such as `force_encoding(Encoding::UTF_8)`
  is the caller's responsibility.
- The normalization required by spec §2.3 / §2.4 (NUL -> U+FFFD,
  `\r\n` / `\r` -> `\n`) and limiting the blank-line definition to space/tab are
  all implemented. These follow the spec, so this document does not list them
  individually.

### 1.3 Format of each item

```
### N.N <Title>

**Spec**: the relevant section and the spec rule (or ambiguity)
**RedQuilt behavior**: how the implementation behaves / where it narrows or extends
**Implementation**: file:line / main symbols
**Test**: spec file / example number
```

## 2. Points where the spec is tightened

Where the spec wording allows more than one interpretation, or where a "must" is
left ambiguous, the implementation chooses the stricter side.

### 2.1 URI autolink rejects U+007F (DEL)

**Spec**: §6.5 — a URI autolink does not contain "ASCII control characters,
space, `<`, `>`". Whether the range of "ASCII control characters" is only
U+0000–U+001F or also includes U+007F is not stated.

**RedQuilt behavior**: also rejects U+007F.

**Implementation**: `lib/red_quilt/inline/lexer.rb` — `URI_AUTOLINK_RE`

**Test**: `spec/whitespace_strictness_spec.rb` — "URI autolink (CommonMark 6.5)"

### 2.2 Raw HTML tag separators limited to space/tab/CR/LF

**Spec**: §6.6 — defines the separators between attributes and around `=` as
"whitespace". In the spec's terminology (§2.1), the "whitespace" set is broad and
includes space / tab / newline / line tabulation (U+000B) / form feed (U+000C) /
carriage return.

**RedQuilt behavior**: within the tag grammar, only `[ \t\r\n]` is allowed as a
separator. FF (U+000C) / VT (U+000B) are not included. The same constraint
applies to inline raw HTML and to HTML block types 1 / 6 / 7.

**Implementation**:
- Inline: `lib/red_quilt/inline/lexer.rb` — `HTML_OPEN_TAG_RE` /
  `HTML_CLOSING_TAG_RE`
- Block: `lib/red_quilt/block_parser.rb` — `HTML_TYPE_7_OPEN_TAG_RE` /
  `HTML_TYPE_7_CLOSING_TAG_RE` / `HTML_BLOCK_TYPE_6_RE` / type 1 regex

**Test**: `spec/whitespace_strictness_spec.rb` — "raw HTML tag whitespace
(CommonMark 6.6)"

### 2.3 Inline link tail separators limited to space/tab/at most 1 LF

**Spec**: §6.3 — the link tail (inside `(dest "title")`) is separated by "spaces,
tabs, and up to one line ending". FF / VT are not mentioned.

**RedQuilt behavior**: within the link tail, only space / tab are separators, and
a line ending is counted separately, up to one. If FF / VT appears, it does not
form a link (it is treated as normal paragraph text).

**Implementation**: `lib/red_quilt/inline/link_scanner.rb` —
`link_tail_whitespace_byte?`, `skip_link_whitespace`, `inline_link`,
`parse_link_title`

**Test**: `spec/whitespace_strictness_spec.rb` — "inline link tail whitespace
(CommonMark 6.3)"

### 2.4 Reference definition raw destination validated the same as inline links

**Spec**: §6.3 — the raw form of a link destination is "a nonempty sequence of
characters that does not start with `<`, does not include ASCII control
characters or space character, and includes parentheses only if (a) they are
backslash-escaped or (b) they are part of a balanced pair of unescaped
parentheses".

**RedQuilt behavior**: validates all of the above for the raw destination of a
reference definition too. Specifically, it rejects ASCII control
(U+0000–U+001F) / U+007F (DEL) / space, and tracks the depth of unescaped
parens, invalidating the definition if they are unbalanced.

**Past behavior**: it accepted destinations with a simple `/\A(\S+)(.*)\z/`, so
`[x]: foo(bar` or `[x]: foo\bbar` were also accepted as definitions.

**Implementation**: `lib/red_quilt/reference_definition.rb` —
`parse_raw_destination`, `RAW_DEST_FORBIDDEN_RE`

**Test**: `spec/link_validation_spec.rb` — "reference definition raw destination
validation"

### 2.5 Apply the 999-character link label limit on all paths

**Spec**: §6.3 — "A link label can have at most 999 characters inside the square
brackets."

**RedQuilt behavior**: rejects more than 999 characters on both the reference
definition side and the reference link usage side (shortcut / collapsed / full,
all of them).

**Implementation**:
- Constant: `lib/red_quilt/reference_definition.rb` —
  `LABEL_MAX_LENGTH = 999`, the `label_too_long?` helper
- Definition side: `match_label` (decides for both single-line and multi-line)
- Usage side: `lib/red_quilt/inline/builder.rb` — `try_reference_link`,
  `lib/red_quilt/inline/link_scanner.rb` — `reference_label`

**Test**: `spec/link_validation_spec.rb` — "link label length limit (999
characters)"

### 2.6 NCR digit limits and U+FFFD replacement of invalid codepoints

**Spec**: §6.4 — a decimal NCR is 1–7 digits, a hex NCR is 1–6 digits. If the
decode result is U+0000, a surrogate (U+D800–U+DFFF), or out of the Unicode range
(> U+10FFFF), it is replaced with U+FFFD.

**RedQuilt behavior**: implements all of the above.

**Past behavior**: it delegated to `CGI.unescapeHTML`, so an 8-digit decimal like
`&#00000065;` or a surrogate like `&#xD800;` would each decode to "A" or raise a
`RangeError`.

**Implementation**: `lib/red_quilt/inline/html_entities.rb` —
`Inline.decode_entity`, `Inline::ENTITY_RE`, `decode_numeric_codepoint`. The
`SURROGATE_RANGE` and `MAX_UNICODE_CODEPOINT` constants.

**Test**: `spec/numeric_character_reference_spec.rb`

### 2.7 GFM table header / delimiter cell-count match requirement

**Spec (GFM §4.10)**: "The header row must match the delimiter row in the number
of cells. If not, a table will not be recognized."

**RedQuilt behavior**: if the cell count of the header and the delimiter do not
match, it is not recognized as a table and is treated as a paragraph.

**Implementation**: `lib/red_quilt/block_parser.rb` — `table_start?`

**Test**: `spec/red_quilt_spec.rb` — "table separator validation (GFM spec)"

### 2.8 GFM extended autolink domain underscore constraint

**Spec (GFM §6.9)**: "If the domain name contains an underscore (`_`) in its last
two segments, it is invalid."

**RedQuilt behavior**: when extended autolinks are enabled, a URL / email whose
domain has `_` in its last two segments is not linkified.

**Implementation**: `lib/red_quilt/extended_autolink_pass.rb` — `valid_domain?` /
`extract_domain`

**Test**: `spec/extended_autolink_spec.rb` — "domain validation (GFM spec)"

## 3. Features outside the spec

Features not defined in the spec that RedQuilt provides for safety and
convenience.

### 3.1 Sanitizing unsafe URL schemes

**RedQuilt behavior**: if the scheme of a link / image destination is not in the
safe list below, it outputs `href` / `src` as an empty string. At the same time
it emits an `:unsafe_url` diagnostic as a warning. For CommonMark autolinks
(`<scheme:...>`), to stay spec-conformant, a denylist is used instead of a safe
list, and only schemes that could lead to script execution get an empty href.

**Safe schemes**: `http`, `https`, `mailto`, `ftp`, `tel`, `ssh`

**Schemes blocked in autolinks**: `javascript`, `vbscript`, `data`

**Implementation**: `lib/red_quilt/inline/builder.rb` — `SAFE_SCHEMES`,
`UNSAFE_AUTOLINK_SCHEMES`, `sanitize_destination`, `block_unsafe_autolink`

**Test**: `spec/red_quilt_spec.rb` — "sanitizes unsafe URL schemes"

### 3.2 Diagnostics

**RedQuilt behavior**: suspicious syntax, missing references, and potential
security events detected during parse / render are accumulated in
`Document#diagnostics` as `RedQuilt::Diagnostic` objects. Processing is never
interrupted (a tree and HTML are always returned).

**Rules currently emitted**:

| Rule | Severity | Description |
|---|---|---|
| `:missing_reference` | warning | A full reference link `[text][ref]` has no definition. |
| `:duplicate_reference` | warning | There were multiple reference definitions with the same label (the first one is used). |
| `:duplicate_footnote` | warning | There were multiple footnote definitions with the same label (the first one is used; only when `footnotes: true`). |
| `:unsafe_url` | warning | An unsafe URL was replaced with an empty `href` / `src`. |
| `:empty_link` | warning | The link destination is empty (only when `lint: true`). |
| `:missing_alt` | info | An image's alt text is empty (only when `lint: true`). |
| `:heading_level_skip` | info | A heading level jumped by more than one (only when `lint: true`). |

**Implementation**: `lib/red_quilt/diagnostic.rb` (value object),
`lib/red_quilt/block_parser.rb` (duplicate reference),
`lib/red_quilt/footnote_definition.rb` (duplicate footnote),
`lib/red_quilt/inline/builder.rb` (missing / unsafe),
`lib/red_quilt/lint_pass.rb` (lint rules)

### 3.3 `allow_html` / `disallow_raw_html` flags

**RedQuilt behavior**:

| Flag | Default | Effect |
|---|---|---|
| `allow_html` | `false` | When false, raw HTML is fully escaped (turned into `&lt;`). When true, HTML blocks and inline raw HTML are output as-is. |
| `disallow_raw_html` | `false` | The GFM "Disallowed Raw HTML" extension, enabled under `allow_html: true`. It rewrites `<` to `&lt;` for the specified tags. |

The disallowed tag set defined by GFM: `title`, `textarea`, `style`, `xmp`,
`iframe`, `noembed`, `noframes`, `script`, `plaintext`

**Implementation**: `lib/red_quilt/document.rb` — `allow_html?` /
`disallow_raw_html?`
**Implementation (filter)**: `lib/red_quilt/renderer/html.rb` —
`DISALLOWED_RAW_TAGS` / `DISALLOWED_RAW_TAG_RE` / `filter_disallowed_raw`

## 4. Enabled extensions

### 4.1 GFM Table

Always enabled. In addition to the spec, the column-count match requirement from
2.7 is applied.

**Implementation**: `lib/red_quilt/block_parser.rb` — `table_start?` /
`parse_table`

### 4.2 GFM Strikethrough

Always enabled. Only the double tilde `~~text~~` is supported (matching GFM
behavior). A single tilde `~text~` is treated as normal text.

**Implementation**: `lib/red_quilt/inline/lexer.rb` (handling of `~` in
`SPECIAL_BYTES` and `scan_delim_run`), `lib/red_quilt/inline/builder.rb`
(generating `STRIKETHROUGH` in `process_emphasis`)

### 4.3 GFM Disallowed Raw HTML

Opt-in. It only works when `allow_html: true, disallow_raw_html: true` are used
together (under `allow_html: false` all HTML is escaped, so it has no effect).
See 3.3 for details.

### 4.4 GFM Extended Autolink

Opt-in. Specifying `extended_autolinks: true` runs `ExtendedAutolinkPass` as a
pass that linkifies bare URLs / emails / `www.`-prefixed strings that are not
wrapped in `<...>`.

**Additional constraint**: implements the domain underscore check from 2.8.

**Implementation**: `lib/red_quilt/extended_autolink_pass.rb`

### 4.5 GFM Footnotes

Opt-in. Specifying `footnotes: true` removes `[^label]: ...` definitions from the
body flow and converts `[^label]` references into sup links. Only the referenced
definitions are kept, ordered by first reference, and output as a
`FOOTNOTES_SECTION` at the end of the root. Unreferenced definitions are not
output.

**Implementation**: `lib/red_quilt/footnote_definition.rb`,
`lib/red_quilt/footnote_registry.rb`, `lib/red_quilt/footnote_pass.rb`

## 5. Unsupported / known limitations

- GFM Task List Items (`- [ ]` / `- [x]`) are not supported. They are parsed as
  normal list items.

## 6. Correspondence with tests

This section collects the spec files that verify the difference items.

| Aspect | Spec file |
|---|---|
| Passing the official CommonMark examples | `spec/commonmark_compat_spec.rb` |
| Input normalization (line endings / NUL / blank line) | `spec/input_normalization_spec.rb` |
| Whitespace strictness (autolink / raw HTML / link tail) | `spec/whitespace_strictness_spec.rb` |
| Link / reference validation (label cap / raw dest) | `spec/link_validation_spec.rb` |
| NCR digit limits and invalid codepoints | `spec/numeric_character_reference_spec.rb` |
| GFM table column-count match | `spec/red_quilt_spec.rb` — "table separator validation" |
| GFM extended autolink domain validation | `spec/extended_autolink_spec.rb` |
| GFM footnotes | `spec/footnotes_spec.rb` |
| URL scheme sanitization | `spec/red_quilt_spec.rb` — "sanitizes unsafe URL schemes" |
| Diagnostics / lint diagnostics | `spec/diagnostic_spec.rb` |
| Disallowed Raw HTML | `spec/red_quilt_spec.rb` — disallow_raw_html cases |
