# RedQuilt CommonMark Conformance

## 1. 本書の位置付け

本稿はRedQuiltとCommonMark / GFM specとの差分について解説する。
spec通りに動く挙動は仕様書(<https://spec.commonmark.org/0.31.2/>、<https://github.github.com/gfm/>)を直接参照する想定で、本書では繰り返さない。

#### 書く対象

- specが許す範囲を実装が 狭めた 箇所(曖昧な箇所の解釈・厳格化)
- specの範囲外の機能(セキュリティ・診断・オプションフラグ)
- 有効化している 拡張(GFM等)とそのオプトイン条件
- 未対応・既知の制限

#### 書かない対象

- specと一致する標準挙動の説明
- 設計の経緯やデータ構造の選択

### 1.1 対象バージョン

- CommonMark: 0.31.2
- GitHub Flavored Markdown: 0.29-gfm

### 1.2 実装上の前提

- 入力はUTF-8文字列。`force_encoding(Encoding::UTF_8)` 等の前処理は呼び出し側の責任。
- spec§2.3 / §2.4が要求する正規化(NUL→U+FFFD、`\r\n` / `\r` → `\n`)と、blank line定義のspace/tab限定はいずれも実装している。
  これはspec通りなので本書では個別項目化しない。

### 1.3 各項目のフォーマット

```
### N.N <タイトル>

**Spec**: 該当節とspecの規定(または曖昧さ)
**RedQuiltの挙動**: 実装がどう振る舞うか / どこを狭めたか・拡張したか
**実装**: ファイル:行 / 主要シンボル
**テスト**: specファイル / example番号
```

## 2. specを厳格化している点

specの文言が複数解釈を許す箇所、あるいは "must" が曖昧なまま放置されている箇所で、実装はより厳しい側を選んでいる。

### 2.1 URI autolinkがU+007F (DEL) を拒否

**Spec**: §6.5—URI autolinkは "ASCII control characters, space, `<`, `>`" を含まない。
"ASCII control characters" の範囲がU+0000–U+001FのみかU+007Fも含むかは明示されていない。

**RedQuiltの挙動**: U+007Fを含めて拒否。

**実装**: `lib/red_quilt/inline/lexer.rb` — `URI_AUTOLINK_RE`

**テスト**: `spec/whitespace_strictness_spec.rb` — "URI autolink (CommonMark 6.5)"

### 2.2 Raw HTML tagのseparatorをspace/tab/CR/LFに限定

**Spec**: §6.6— 属性間や `=` 周りのseparatorを "whitespace" と定義。
"whitespace" の集合はspecの用語定義(§2.1)ではspace / tab / newline / line tabulation (U+000B) / form feed (U+000C) / carriage returnを含む広い集合。

**RedQuiltの挙動**: tag grammarの中では `[ \t\r\n]` のみをseparatorとして許可。
FF (U+000C) / VT (U+000B) は含めない。インラインのraw HTML、HTML blockのtype 1 / 6 / 7すべてに同じ制約を適用。

**実装**:
- インライン: `lib/red_quilt/inline/lexer.rb` — `HTML_OPEN_TAG_RE` / `HTML_CLOSING_TAG_RE`
- ブロック: `lib/red_quilt/block_parser.rb` — `HTML_TYPE_7_OPEN_TAG_RE` /
  `HTML_TYPE_7_CLOSING_TAG_RE` / `HTML_BLOCK_TYPE_6_RE` / type 1 regex

**テスト**: `spec/whitespace_strictness_spec.rb` — "raw HTML tag whitespace (CommonMark 6.6)"

### 2.3 Inline link tail separatorをspace/tab/最大1 LFに限定

**Spec**: §6.3—linkのtail (`(dest "title")` 内部)は "spaces, tabs, and up to one line ending" で区切る。FF / VTへの言及は無い。

**RedQuiltの挙動**: link tail内ではspace / tabのみをseparatorとし、line endingは別途1回までカウント。
FF / VTが現れた場合はlinkとしては成立しない(段落の通常テキストとして扱う)。

**実装**: `lib/red_quilt/inline/link_scanner.rb` — `link_tail_whitespace_byte?`、
`skip_link_whitespace`、`inline_link`、`parse_link_title`

**テスト**: `spec/whitespace_strictness_spec.rb` — "inline link tail whitespace (CommonMark 6.3)"

### 2.4 Reference definitionのraw destination検証をinline linkと同等に

**Spec**: §6.3—link destinationのraw形式は "a nonempty sequence of
characters that does not start with `<`, does not include ASCII control
characters or space character, and includes parentheses only if (a) they are
backslash-escaped or (b) they are part of a balanced pair of unescaped
parentheses".

**RedQuiltの挙動**: reference definitionのraw destinationでも上記すべてを検証する。
具体的にはASCII control (U+0000–U+001F) / U+007F (DEL) / spaceを拒否、unescaped parenのdepthを追跡しアンバランスなら定義無効。

**過去の挙動**: 単純な `/\A(\S+)(.*)\z/` で受けていたため、`[x]: foo(bar` や`[x]: foobar` でもdefinitionとして成立してしまっていた。

**実装**: `lib/red_quilt/reference_definition.rb` — `parse_raw_destination`、`RAW_DEST_FORBIDDEN_RE`

**テスト**: `spec/link_validation_spec.rb` — "reference definition raw destination validation"

### 2.5 Link labelの999文字上限を全経路で適用

**Spec**: §6.3— "A link label can have at most 999 characters inside the square brackets."

**RedQuiltの挙動**: reference definition側とreference link使用側(shortcut / collapsed / fullすべて)で999文字超を拒否。

**実装**:
- 定数: `lib/red_quilt/reference_definition.rb` — `LABEL_MAX_LENGTH = 999`、`label_too_long?` ヘルパ
- 定義側: `match_label`(単一行・複数行のどちらでも判定)
- 使用側: `lib/red_quilt/inline/builder.rb` — `try_reference_link`、
  `lib/red_quilt/inline/link_scanner.rb` — `reference_label`

**テスト**: `spec/link_validation_spec.rb` — "link label length limit (999 characters)"

### 2.6 NCRの桁上限と無効codepointのU+FFFD置換

**Spec**: §6.4—decimal NCRは1–7桁、hex NCRは1–6桁。
decode結果がU+0000、surrogate (U+D800–U+DFFF)、またはUnicode範囲外 (>U+10FFFF) になる場合はU+FFFDに置き換える。

**RedQuiltの挙動**: 上記すべてを実装。

**過去の挙動**: `CGI.unescapeHTML` に委譲していたため、`&#00000065;` のような8桁decimalや `&#xD800;` のようなsurrogateがそれぞれ "A" としてdecodeされたり、`RangeError` を発生させていた。

**実装**: `lib/red_quilt/inline/html_entities.rb` — `Inline.decode_entity`、
`Inline::ENTITY_RE`、`decode_numeric_codepoint`。`SURROGATE_RANGE`、
`MAX_UNICODE_CODEPOINT` 定数。

**テスト**: `spec/numeric_character_reference_spec.rb`

### 2.7 GFM tableのheader / delimiter列数一致要件

**Spec (GFM§4.10)**: "The header row must match the delimiter row in the number of cells. If not, a table will not be recognized."

**RedQuiltの挙動**: headerとdelimiterでcell数が一致しない場合、tableとして認識せずparagraphとして扱う。

**実装**: `lib/red_quilt/block_parser.rb` — `table_start?`

**テスト**: `spec/red_quilt_spec.rb` — "table separator validation (GFM spec)"

### 2.8 GFM extended autolinkのdomain underscore制約

**Spec (GFM§6.9)**: "If the domain name contains an underscore (`_`) in its last two segments, it is invalid."

**RedQuiltの挙動**: extended autolinkを有効化した場合、URL / emailのdomain末尾2セグメントに `_` を含むものはlinkifyしない。

**実装**: `lib/red_quilt/extended_autolink_pass.rb` — `valid_domain?` / `extract_domain`

**テスト**: `spec/extended_autolink_spec.rb` — "domain validation (GFM spec)"

## 3. specの範囲外の機能

specには規定が無いが、RedQuilt側で安全性・利便性のために提供している機能。

### 3.1 unsafe URL schemeのサニタイズ

**RedQuiltの挙動**: link / imageのdestinationのschemeが以下の安全リストに含まれない場合、`href` / `src` を空文字列にして出力する。
同時に `:unsafe_url` のdiagnosticをwarningとして発行する。
CommonMark autolink (`<scheme:...>`) はspec適合のため安全リストではなくdenylistで扱い、script実行につながるschemeのみ空hrefにする。

**安全スキーム**: `http`、`https`、`mailto`、`ftp`、`tel`、`ssh`

**autolinkでブロックされるscheme**: `javascript`、`vbscript`、`data`

**実装**: `lib/red_quilt/inline/builder.rb` — `SAFE_SCHEMES`、`UNSAFE_AUTOLINK_SCHEMES`、`sanitize_destination`、`block_unsafe_autolink`

**テスト**: `spec/red_quilt_spec.rb` — "sanitizes unsafe URL schemes"

### 3.2 Diagnostics

**RedQuiltの挙動**: parse / render中に検出した不審な構文・参照漏れ・潜在的なセキュリティ事象を `RedQuilt::Diagnostic` として `Document#diagnostics` に
蓄積する。
処理は中断しない(常にtreeとHTMLが返る)。

**現状で発行されるrule**:

| Rule | Severity | 内容 |
|---|---|---|
| `:missing_reference` | warning | full reference link `[text][ref]` の定義が無い |
| `:duplicate_reference` | warning | 同じlabelのreference definitionが複数あった(最初の定義を採用) |
| `:duplicate_footnote` | warning | 同じlabelのfootnote definitionが複数あった(最初の定義を採用、`footnotes: true`時のみ) |
| `:unsafe_url` | warning | unsafeなURLを空の`href` / `src`に置換した |
| `:empty_link` | warning | link destinationが空(`lint: true`時のみ) |
| `:missing_alt` | info | imageのalt textが空(`lint: true`時のみ) |
| `:heading_level_skip` | info | 見出しレベルが1段を超えて飛んだ(`lint: true`時のみ) |

**実装**: `lib/red_quilt/diagnostic.rb`(値オブジェクト)、`lib/red_quilt/block_parser.rb`(duplicate reference)、`lib/red_quilt/footnote_definition.rb`(duplicate footnote)、`lib/red_quilt/inline/builder.rb`(missing / unsafe)、`lib/red_quilt/lint_pass.rb`(lint rules)

### 3.3 `allow_html` / `disallow_raw_html` フラグ

**RedQuiltの挙動**:

| Flag | Default | 効果 |
|---|---|---|
| `allow_html` | `false` | 偽の場合、raw HTMLは全エスケープ(`&lt;` 化)で出力。真にするとHTML block / inline raw HTMLが原文のまま出力される |
| `disallow_raw_html` | `false` | `allow_html: true` 下で有効化するGFM "Disallowed Raw HTML" 拡張。指定タグ群の `<` を `&lt;` に書き換える |

GFMが定めるdisallowedタグ群: `title`, `textarea`, `style`, `xmp`, `iframe`, `noembed`, `noframes`, `script`, `plaintext`

**実装**: `lib/red_quilt/document.rb` — `allow_html?` / `disallow_raw_html?`
**実装(filter)**: `lib/red_quilt/renderer/html.rb` — `DISALLOWED_RAW_TAGS` /
`DISALLOWED_RAW_TAG_RE` / `filter_disallowed_raw`

## 4. 有効化している拡張

### 4.1 GFM Table

常時有効。specの仕様に加えて2.7のcolumn count一致要件を適用。

**実装**: `lib/red_quilt/block_parser.rb` — `table_start?` / `parse_table`

### 4.2 GFM Strikethrough

常時有効。`~~text~~` の2連tildeのみ対応(GFMの挙動と一致)。単一tilde`~text~` は通常テキストとして扱う。

**実装**: `lib/red_quilt/inline/lexer.rb`(`SPECIAL_BYTES` と `scan_delim_run` の `~` 取扱)、`lib/red_quilt/inline/builder.rb`(`process_emphasis` で `STRIKETHROUGH` を生成)

### 4.3 GFM Disallowed Raw HTML

オプトイン。`allow_html: true, disallow_raw_html: true` を併用したときのみ動作する(`allow_html: false` 下では全HTMLがエスケープされるため意味がない)。
詳細は3.3参照。

### 4.4 GFM Extended Autolink

オプトイン。`extended_autolinks: true` を指定すると `ExtendedAutolinkPass` がパスとして走り、`<...>` で囲まれていない裸のURL / email / `www.` 始まり等をリンク化する。

**追加制約**: 2.8のdomain underscoreチェックを実装。

**実装**: `lib/red_quilt/extended_autolink_pass.rb`

### 4.5 GFM Footnotes

オプトイン。`footnotes: true` を指定すると `[^label]: ...` の定義を本文フローから除外し、`[^label]` 参照をsupリンクに変換する。
参照された定義だけを初回参照順に並べ、root末尾の`FOOTNOTES_SECTION`として出力する。未参照の定義は出力しない。

**実装**: `lib/red_quilt/footnote_definition.rb`、`lib/red_quilt/footnote_registry.rb`、`lib/red_quilt/footnote_pass.rb`

## 5. 未対応 / 既知の制限

- GFM Task List Items (`- [ ]` / `- [x]`) は未対応。通常のlist itemとしてパースされる。

## 6. テストとの対応関係

差分項目を検証するspecファイルを集約する。

| 観点 | specファイル |
|---|---|
| 公式CommonMark exampleの通過 | `spec/commonmark_compat_spec.rb` |
| 入力正規化(行終端 / NUL / blank line) | `spec/input_normalization_spec.rb` |
| Whitespace厳格化(autolink / raw HTML / link tail) | `spec/whitespace_strictness_spec.rb` |
| Link / reference検証(label cap / raw dest) | `spec/link_validation_spec.rb` |
| NCR桁上限と無効codepoint | `spec/numeric_character_reference_spec.rb` |
| GFM tableのcolumn count一致 | `spec/red_quilt_spec.rb` — "table separator validation" |
| GFM extended autolinkのdomain検証 | `spec/extended_autolink_spec.rb` |
| GFM footnotes | `spec/footnotes_spec.rb` |
| URL schemeサニタイズ | `spec/red_quilt_spec.rb` — "sanitizes unsafe URL schemes" |
| Diagnostics / lint diagnostics | `spec/diagnostic_spec.rb` |
| Disallowed Raw HTML | `spec/red_quilt_spec.rb` —disallow_raw_html系 |
