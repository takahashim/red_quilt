# Markdast Roadmap

## Current Status

`markdast` は v1 コア実装を完了しています。現在は CommonMark 互換性の底上げと、AST/renderer の厳密化フェーズに入っています。

完了済み:

- Arena AST と `NodeRef` ベースの公開 API
- `Markdast.parse` / `Markdast.render_html`
- `Document#root` / `#to_html` / `#to_ast`
- block parser
  - paragraph
  - ATX heading
  - thematic break
  - blockquote
  - ordered / unordered list
  - fenced / indented code block
  - table
  - raw HTML block
  - link reference definition
- inline parser
  - text
  - softbreak / hardbreak
  - emphasis / strong
  - code span
  - inline link / image
  - reference link / image
  - URI autolink
  - raw HTML inline
- safe-by-default HTML renderer
- RBS
- RSpec の基本 spec と CommonMark 互換 spec

進行中:

- CommonMark 互換の厳密化
- emphasis / container rules / HTML rule の仕様追従

未着手:

- formatter
- transformer
- diagnostics
- CLI

## Roadmap

## Phase 1: CommonMark Inline Completion

目的:
inline 構文でまだ heuristic に寄っている部分を削り、互換 spec を増やしても壊れにくい基盤にする。

タスク:

- emphasis / strong を full delimiter-run ベースへ置き換える
- `*` / `_` の opener / closer 判定を CommonMark 仕様に寄せる
- intraword underscore の境界条件を詰める
- email autolink を追加する
- autolink の URL / mailto 判定を整理する
- raw HTML inline のタグ・属性・終端規則を厳密化する

完了条件:

- inline 周りの heuristic 分岐を大幅に減らす
- CommonMark inline 系 example を追加して green を維持する

## Phase 2: CommonMark Block Completion

目的:
container block と list 継続規則のズレを減らし、複雑な Markdown 文書でも AST が安定するようにする。

タスク:

- list continuation のインデント規則を厳密化する
- blank line をまたぐ list item 継続を見直す
- tight / loose list 判定を CommonMark 準拠へ寄せる
- blockquote と list の相互ネスト規則を整理する
- raw HTML block の 7 類型を実装する
- HTML block の blank line / interruption rule を詰める

完了条件:

- list / blockquote / HTML block の互換 example を増やして green にする
- block parser の継続条件を spec ベースで説明できる状態にする

## Phase 3: Reference And Label Semantics

目的:
reference link/image の解決ルールを CommonMark に近づけ、ラベル正規化の曖昧さをなくす。

タスク:

- reference label normalization を明文化して実装する
- whitespace / case folding の扱いを spec に合わせる
- duplicate definition の優先規則を確認して固定する
- container 内 definition と後方参照ケースを追加検証する

完了条件:

- reference link / image の edge case spec を追加して green にする

## Phase 4: AST Surface Refinement

目的:
Arena を内部表現のまま維持しつつ、外部 API を安定化する。

タスク:

- `Document#to_ast` / `NodeRef#to_h` の出力 schema を README に固定する
- node attributes の公開方針を整理する
- `SourceSpan` の line / column 変換を追加するか判断する
- AST export の安定性を保証する spec を増やす
- traversal helper の追加要否を判断する

完了条件:

- AST export がドキュメント化される
- public API と internal slot の責務が分離される

## Phase 5: Renderer Hardening

目的:
HTML renderer を安全性と拡張性の両面で固める。

タスク:

- URL sanitization の対象 scheme を見直す
- HTML pass-through の許可条件を整理する
- table / code block / image の render 細部を確認する
- renderer spec を AST ベース入力観点でも追加する

完了条件:

- safe-by-default の仕様が README と spec で明確になる
- renderer の回帰テストが増える

## Phase 6: Documentation And Compatibility Matrix

目的:
今の実装がどこまで対応しているかを利用者が判断できる状態にする。

タスク:

- README に現在対応している Markdown 機能一覧を追加する
- CommonMark 互換範囲と未対応項目を明記する
- `Document#to_ast` / `NodeRef` の利用例を追加する
- `ast-spec.md` との差分と今後の方針を整理する

完了条件:

- 利用者が README だけで現状の守備範囲を把握できる

## Phase 7: Post-v1 Extensions

目的:
v1 の外に置いた機能を、必要性の高い順に拡張する。

候補:

- formatter
- transformer
- diagnostics
- CLI
- fast path renderer
- event-based parse/render path
- native backend / LexerKit backend の検討

## Suggested Execution Order

1. Phase 1: CommonMark Inline Completion
2. Phase 2: CommonMark Block Completion
3. Phase 3: Reference And Label Semantics
4. Phase 5: Renderer Hardening
5. Phase 4: AST Surface Refinement
6. Phase 6: Documentation And Compatibility Matrix
7. Phase 7: Post-v1 Extensions

## Immediate Next Tasks

直近で着手するなら優先度はこの順です。

1. emphasis / strong の full delimiter-run 実装
2. email autolink の追加
3. raw HTML block 7 類型の実装
4. list continuation / tight-loose 判定の再整理
5. CommonMark spec 追加による回帰可視化
