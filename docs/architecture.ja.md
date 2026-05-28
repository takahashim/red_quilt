# RedQuilt Architecture Overview

RedQuiltの構成を概観する。

## パイプライン

```
Source (Markdown String)
   │
   ▼RedQuilt.normalize_input         (lib/red_quilt.rb)
   │
   ▼BlockParser                      (lib/red_quilt/block_parser.rb)
   │dispatch / container parsers / build_lines
   │     (list.rb, blockquote.rb, reference_definition.rb)
   │
   ▼Arena (raw inline spans)
   │paragraph / heading / table cellの本文はbyte spanのみで保持
   │
   ▼InlinePass                       (lib/red_quilt/inline_pass.rb)
   │     ├─Inline::Lexer              (lib/red_quilt/inline/lexer.rb)
   │     │byte scan→Tokens (parallel array)
   │     └─Inline::Builder            (lib/red_quilt/inline/builder.rb)
   │linear pass→process_emphasis (CommonMark§6.2)
   │
   ▼Arena (inline解決済み)
   │
   ▼  (option) FootnotePass             (footnotes: true)
   ▼  (option) ExtendedAutolinkPass    (extended_autolinks: true)
   ▼  (option) LintPass                (lint: true)
   │
   ▼Renderer::HTML                   (lib/red_quilt/renderer/html.rb)
         arenaをwalkしてmutable Stringにappend
```

## 各ステージの責務

### `RedQuilt.normalize_input`
CommonMark§2.3/2.4の最小前処理。`\r\n`/`\r`→`\n`の行末正規化と、NUL→U+FFFDの置換だけを行う。

### BlockParser
- 行分割: sourceを`Line` Struct配列へ。各行はbyte spanで保持する。
- dispatch: 行頭バイトでblock kindを判定(`paragraph_only_line?`が非ブロック行を早期に振り分け)。
- container委譲: list / blockquoteは`List::Parser` / `Blockquote::Parser`へ委譲し、内部で`parse_lines`を再帰。
- 定義の収集と除外: link reference定義(参照テーブル)と、opt-inのfootnote定義(`FootnoteRegistry`)を本文フローから抜き、専用collectorへ集約。
- 桁計算: タブ展開を含むインデント計算は`Indentation`に委譲。
- 出力: inline未解決のblockノードをArenaに構築する。

### InlinePass / Lexer / Builder
- 対象選定: paragraph / heading / table cellの各inline targetを走査して処理。
- Lexer: targetのbyte spanをスキャンしTokens(parallel array)へ。
- Builder①linear pass: code span / link / image / autolink / 簡易inlineを解決。
- Builder②process_emphasis: delimiter stackを畳んでemphasis / strongを確定(CommonMark§6.2)。
- footnote参照: `[^label]`を`FootnoteRegistry`で解決し、初回参照順に採番して`FOOTNOTE_REFERENCE`を生成。

### FootnotePass (`footnotes: true`)
- 並べ替え: `FOOTNOTES_SECTION`(root末尾)配下の定義を初回参照順へ。
- 刈り取り: 未参照の定義をdetach。
- section削除: 参照ゼロならsection自体を除去。

### Renderer::HTML
- walk: arenaを再帰walkし、`+""`で開いたmutable Stringへ直接`<<`。
- raw HTML: `allow_html`で素通し / エスケープを切替、`disallow_raw_html`でGFM Disallowed Raw HTMLをfilter。
- footnote: `FOOTNOTE_REFERENCE`をsupリンクに、末尾`FOOTNOTES_SECTION`を`<section class="footnotes">`＋backrefとして出力。

## 主なサブシステム位置

| 領域 | ファイル |
|---|---|
| エントリ / 入力正規化 | `lib/red_quilt.rb` |
| 公開API | `lib/red_quilt/document.rb`、`node_ref.rb` |
| Arena | `lib/red_quilt/arena.rb` |
| Block解析 | `block_parser.rb`、`list.rb`、`blockquote.rb`、`indentation.rb` |
| Reference definition | `reference_definition.rb` |
| Footnotes (opt-in) | `footnote_definition.rb`、`footnote_registry.rb`、`footnote_pass.rb` |
| Inline解析 | `inline.rb`、`inline/lexer.rb`、`inline/tokens.rb`、`inline/flanking.rb`、`inline/builder.rb`、`inline/link_scanner.rb` |
| Inlineエンティティ | `inline/html_entities.rb` |
| HTML / MDAST出力 | `renderer/html.rb`、`renderer/mdast.rb` |
| 拡張パス | `inline_pass.rb`、`footnote_pass.rb`、`extended_autolink_pass.rb`、`lint_pass.rb` |
| Source位置 | `source_span.rb`、`source_map.rb` |
| Diagnostics | `diagnostic.rb` |
| CLI | `cli.rb`、`exe/redquilt` |
