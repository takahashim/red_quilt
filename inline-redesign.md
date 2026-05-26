# Inline Processing Redesign (Lexer + Builder)

## 目的

現状のインライン処理を、CommonMark spec 準拠の **二段構成 (Lexer + Builder)** に再構成する。

### 達成したいこと

- substring 連鎖の排除 (Arena は document 全体の絶対 byte offset で動く)
- `base_offset` 計算の消滅 (Phase 9-A の Unicode バグの再発防止)
- Phase 9-B (full delimiter-run emphasis) の自然な統合
- `ast-spec.md` が想定する LexerKit backend 差し替えの土台
- Lexer / Builder それぞれの単体テスト可能性

### 非目標

- CommonMark spec 100% 互換 (これまで通り「pragmatic な精度」で十分)
- 段階的な並列実装 (中途半端な状態を避け、一気に書き換える)

## 現状の問題 (再整理)

| 問題 | 現状 | 影響 |
|------|------|------|
| substring 連鎖 | InlinePass で paragraph 全体を切り出し、emphasis/link 内でさらに切り出す | allocation が depth に比例 |
| `base_offset` 計算 | `@base_offset + start_byte + delimiter.bytesize` が散在 | Unicode バグの主因 (Phase 9-A の歴史) |
| char/byte の二重管理 | scanner が `@index` と `@byte_index` を両方持つ | 取り違えのリスク |
| 再帰 Parser 生成 | `parse_emphasis` 等で `self.class.new(...).parse` | InlineParser/InlineScanner instance を depth 分 allocate |
| eager parsing 限定 | `find_emphasis_closing` などの heuristic | spec 準拠が困難、Phase 9-B 試行が頓挫した直接の原因 |

## アーキテクチャ

### データフロー

```
Document.source (String, document全体)
  ↓
InlinePass: paragraph/heading/table_cell を見つけ、(start_byte, end_byte) を取得
  ↓
InlineLexer.lex(source, start_byte, end_byte)
  ↓
InlineTokens (parallel arrays)
  [TEXT(s,e), DELIM_RUN(s,e,'*',n=2,co,cc), TEXT(s,e), DELIM_RUN(s,e,'*',n=2,...), ...]
  ↓
InlineBuilder.build(tokens, parent_id)
  ├─ linear pass: code span resolution, link/image bracket matching, provisional emphasis tokens
  └─ process_emphasis: delimiter stack を回して EMPHASIS / STRONG を確定
  ↓
Arena に inline node が追加される
```

### レイヤー責務

| レイヤー | 責務 | 触らないもの |
|----------|------|--------------|
| InlinePass | 対象ノードの探索、Lexer + Builder の起動 | source の解釈 |
| InlineLexer | 文字スキャン、token emit、flanking 判定 | Arena |
| InlineTokens | token stream の保持 (軽量 storage) | (データ構造のみ) |
| InlineBuilder | token 消費、delimiter stack、bracket matching、Arena への node 追加 | source の再スキャン |

### ファイル構成案

```
lib/mdarena/inline/
  lexer.rb           # InlineLexer
  tokens.rb          # InlineTokens (parallel arrays storage)
  token_kind.rb      # Token kind 定数
  builder.rb         # InlineBuilder
  flanking.rb        # left/right flanking 判定ヘルパー (Lexer内で利用)
lib/mdarena/inline_pass.rb  # 既存ファイルを修正
```

`lib/mdarena/inline_parser.rb` と `lib/mdarena/inline_scanner.rb` は **削除** する。

## Token Kind 一覧

CommonMark spec が要求する inline 構造を構築するために必要な最小セット。

| Kind | 説明 | 追加情報 (int1/int2/int3/str1) |
|------|------|-------------------------------|
| `TEXT` | プレーンテキスト span | なし (source span で十分) |
| `ENTITY` | HTML entity (decoded literal を持つ) | str1 = decoded text |
| `ESCAPED_CHAR` | backslash escape (`\*` 等) | str1 = original char (1文字) |
| `LINE_ENDING` | 改行 (softbreak / hardbreak は builder が判定) | int1 = preceding hardbreak space count |
| `CODE_DELIMITER` | `` ` `` run | int1 = run length |
| `DELIM_RUN` | `*` または `_` run | int1 = char code, int2 = count, int3 = (can_open<<1)|can_close |
| `LBRACKET` | `[` | — |
| `BANG_LBRACKET` | `![` | — |
| `RBRACKET` | `]` | — |
| `AUTOLINK_URI` | `<scheme:...>` | str1 = destination |
| `AUTOLINK_EMAIL` | `<addr@host>` | str1 = email |
| `HTML_INLINE` | `<tag ...>` 等 | str1 = matched text |

### なぜこの粒度か

- emphasis 関連は `DELIM_RUN` 一種類で済む。`*` か `_` か、count、flanking の情報を全部 token に持たせる
- link/image 用に括弧系 3 種 (`LBRACKET` / `BANG_LBRACKET` / `RBRACKET`) を独立 token に
- 括弧の内側は token stream の上で linear に matching する
- code span は同じ長さの `CODE_DELIMITER` 同士でクローズ判定するため独立 token
- autolink と generic HTML inline は builder で異なる Arena node にするので分ける
- **`(` / `)` を token 化しない**: inline link destination `(url "title")` のパースは builder で `@source.byteslice` を直接読む方が速い。token allocation を増やさない

### Token 表現 (parallel array)

```ruby
class InlineTokens
  def initialize
    @kind = []
    @start_byte = []
    @end_byte = []
    @int1 = []
    @int2 = []
    @int3 = []
    @str1 = []
  end

  def emit(kind, start_byte:, end_byte:, int1: 0, int2: 0, int3: 0, str1: nil)
    @kind << kind
    @start_byte << start_byte
    @end_byte << end_byte
    @int1 << int1
    @int2 << int2
    @int3 << int3
    @str1 << str1
    @kind.length - 1   # token_id
  end

  # paragraph 単位で内容だけ捨てる。capacity は保持される。
  def clear
    @kind.clear
    @start_byte.clear
    @end_byte.clear
    @int1.clear
    @int2.clear
    @int3.clear
    @str1.clear
  end

  def length; @kind.length; end
  def kind(i); @kind[i]; end
  def start_byte(i); @start_byte[i]; end
  def end_byte(i); @end_byte[i]; end
  def int1(i); @int1[i]; end
  def int2(i); @int2[i]; end
  def int3(i); @int3[i]; end
  def str1(i); @str1[i]; end
end
```

Arena と同じ思想 (parallel array, integer id) で持つ。token も `token_id` で参照され、builder の delimiter stack は token_id を積む。

**生存範囲**: `InlineTokens` インスタンスは document 単位で **1 個**だけ作り、各 paragraph/heading を処理する前に `clear` で内容を捨てる。Array#clear は length を 0 にするだけで内部 capacity を保持するため、次の paragraph で同サイズ以下なら再 allocation が起きない。これによって paragraph 数 × 7 配列の allocation を avoid する。

## InlineLexer

### API

```ruby
class InlineLexer
  def initialize(source)
    @source = source
  end

  # tokens は呼び出し側 (InlinePass) が保持する InlineTokens を渡す。
  # Lexer は使い回された tokens に直接 emit する。
  def lex_into(tokens, start_byte, end_byte)
    @pos = start_byte
    @end = end_byte
    scan(tokens)
  end

  private

  def scan(tokens); end
end
```

- `@source` は document 全体の String (参照のみ、コピーしない)
- `@pos` は byte 単位の現在位置
- `@end` は走査する範囲の終端 (排他)
- token storage は引数で受け取る (`InlinePass` が `clear` してから渡す)

### char index の扱い

- Lexer 内では基本 byte index で動く
- regex match (autolink / HTML / entity) は **byte 位置を起点とした `\G` 付き regex を `@source.match(re, @pos)` で実行**する。char index は不要
- flanking 判定 (`*` / `_` の前後文字を見る) は byte 位置から `@source[byte_pos]` で取り出すが、これは ASCII (`*`, `_`, space, punctuation) を中心に判定するため char/byte の差が問題にならない。Unicode punctuation 判定は `String#byteslice` で前後の char を取り出してから `match?(/[[:punct:]]/)` で行う

つまり、**char index は Lexer の主要状態ではない**。byte_index 一本で動く。

### 主要なスキャンルール

入力位置 `@pos` の byte を見て分岐:

| 先頭 byte | 処理 |
|-----------|------|
| `\n` | LINE_ENDING を emit (直前の TEXT が空白2個以上で終わっていれば hardbreak 用のヒントを int1 にセット) |
| `\\` (backslash) | 次の char を見て ASCII punct なら ESCAPED_CHAR、`\\\n` なら LINE_ENDING (hardbreak), それ以外なら TEXT 扱い |
| `` ` `` | CODE_DELIMITER を emit (run 長を int1) |
| `*` | DELIM_RUN を emit (`*`, count = run長, flanking 判定) |
| `_` | DELIM_RUN を emit (`_`, count = run長, flanking + 単語境界判定) |
| `[` | LBRACKET を emit |
| `]` | RBRACKET を emit |
| `!` で次が `[` | BANG_LBRACKET を emit (2 byte 消費) |
| `<` | autolink (URI/email) → AUTOLINK_*; それ以外で HTML inline タグなら HTML_INLINE; いずれでもなければ TEXT 扱い |
| `&` | entity match → ENTITY; なければ TEXT 扱い |
| その他 | 次の特殊文字までを TEXT として emit |

TEXT は **連続するプレーン区間を 1 token にまとめる**。バッククォートや `*` 等の特殊文字に当たるまで進める。`String#index(SPECIAL_RE, @pos)` で次の特殊位置を探し、その手前までを TEXT として emit する (現状の `scan_text` と同じ発想)。

### DELIM_RUN の int3 encoding

flanking は token に焼き込む:

```
int3 = (can_open ? 2 : 0) | (can_close ? 1 : 0)
```

builder 側で `can_open?(token_id)` / `can_close?(token_id)` ヘルパーで取り出す。

### Flanking 判定

CommonMark spec 6.2 の left/right flanking delimiter run 判定。`flanking.rb` にまとめる:

```ruby
module Flanking
  def self.flanking_pair(source, run_start_byte, run_end_byte)
    prev_char = char_before(source, run_start_byte)
    next_char = char_at(source, run_end_byte)
    left = left_flanking?(prev_char, next_char)
    right = right_flanking?(prev_char, next_char)
    [left, right]
  end

  # ... left_flanking?, right_flanking?, char_before, char_at ...
end
```

`*` と `_` で can_open/can_close の追加条件 (word_char に挟まれた `_` は emphasis を開けない/閉じれない) もここで処理する。

## InlineBuilder

### API

```ruby
class InlineBuilder
  def initialize(arena, source, references)
    @arena = arena
    @source = source
    @references = references
  end

  def build(parent_id, tokens)
    @parent_id = parent_id
    @tokens = tokens
    @delimiter_stack = []   # token_id の配列 (DELIM_RUN / LBRACKET / BANG_LBRACKET)
    @text_node_for_token = {}  # token_id -> arena node_id
    linear_pass
    process_emphasis
  end
end
```

### linear pass

token を頭から処理:

| Token kind | 処理 |
|------------|------|
| TEXT | Arena に TEXT ノード追加 (source span そのまま、str1 は nil) |
| ENTITY / ESCAPED_CHAR | Arena に TEXT ノード追加 (str1 = decoded literal, source span は元の `&...;` や `\X` を保持) |
| LINE_ENDING | 直前 TEXT の末尾を見て trailing spaces 2+ なら HARDBREAK、それ以外は SOFTBREAK |
| CODE_DELIMITER | 同じ run length の CODE_DELIMITER を後方探索、見つかったら間を CODE_SPAN ノード化、消費した token をまとめてスキップ。見つからなければ TEXT 化 |
| DELIM_RUN | Arena に **暫定 TEXT ノード** (delimiter 文字そのまま) を追加し、token_id とノード id を `@delimiter_stack` に push |
| LBRACKET / BANG_LBRACKET | Arena に **暫定 TEXT ノード** (`[` / `![`) を追加し、`@delimiter_stack` に push (open bracket marker として) |
| RBRACKET | `@delimiter_stack` を逆順に走査して直近の LBRACKET/BANG_LBRACKET を探し、リンク/画像にできるか試す (`(url)` か `[ref]` が後続するか) |
| AUTOLINK_URI / AUTOLINK_EMAIL | Arena に LINK ノード追加 (内側に TEXT) |
| HTML_INLINE | Arena に HTML_INLINE ノード追加 |

### code span の決まり方

linear pass で `CODE_DELIMITER` に当たったら、その先の token を順に見て同じ length の `CODE_DELIMITER` を探す。見つかったら:

- 間にある全 token を **物理的に skip** (linear pass のループ位置を進める)
- 間のソース範囲を `byteslice` して CODE_SPAN の str1 にする (CommonMark の whitespace 正規化を適用)
- 間の token が delimiter stack に積まれることもない

これにより「code span の中の `*` は emphasis として解釈されない」が自然に保証される (Phase 9-B 失敗時のカテゴリ6を構造的に解消)。

### link / image bracket matching

`RBRACKET` を見つけたら:

1. `@delimiter_stack` を後ろから走査して最初の `LBRACKET` / `BANG_LBRACKET` を探す。なければ RBRACKET を単なる `]` テキスト扱い
2. RBRACKET の **直後の byte 位置を `@source` から直接見る** (token kind は使わない):
   - `(` で始まる → inline link/image: 直後の source を byteslice + handwritten parser で `(url "title")` を解析 (現状の `extract_link_like` のロジックをそのまま流用)
   - `[` で始まる → reference link: 同様に source から label を読み取り、`@references` に照会
   - どちらでもない → shortcut reference: LBRACKET と RBRACKET の間のテキストを label として照会
3. マッチ成功:
   - LBRACKET と RBRACKET の暫定 TEXT ノードを Arena から detach
   - 間に積まれた他の DELIM_RUN を `@delimiter_stack` から削除
   - 新たに LINK / IMAGE ノードを Arena に作り、中身の TEXT/inline を子として再アタッチ
   - destination は `sanitize_destination` で URL スキームを検査 (既存ロジック流用)
   - **image の中の link は CommonMark spec 通り抑制する** (image 内に LBRACKET があったら image 化を阻害させる)
4. マッチ失敗: bracket を text 扱いに戻す

#### `(` / `)` を token 化しない理由

token kind を増やすと:

- Lexer での emit 回数が増える (短い paragraph で目立つオーバーヘッド)
- 全ての `(` `)` が token になるので、リンクでない括弧 (例: `(foo)`) でも token allocation
- builder で結局 source を読み直すケースが多い (title の quote 内など)

source 直読み (byteslice + handwritten parser) であれば:

- token は付与されないので allocation ゼロ
- destination 解析は連続バイト走査で O(len) で済む
- 既存の `extract_link_like` / `extract_reference_like` がそのまま流用できる

なお lexer は `[` `]` `![` を token として emit する。これは「閉じ括弧で初めてリンク判定が始まる」「閉じ括弧の存在を delimiter stack 走査の起点として token_id で参照したい」ためで、`(` `)` とは性質が異なる。

### process_emphasis (CommonMark spec 6.2)

linear pass が終わった時点で `@delimiter_stack` には DELIM_RUN token_id (および bracket 残骸) が積まれている。bracket は linear pass 終了時点で全て解決済みなので、残るのは DELIM_RUN のみのはず。

擬似コード:

```
openers_bottom = { '*' => -1, '_' => -1 }
closer_idx = 0

while closer_idx < delimiter_stack.length
  closer = delimiter_stack[closer_idx]
  unless can_close?(closer)
    closer_idx += 1; next
  end

  # 同じ char で、closer_idx より前、かつ openers_bottom[char] より後ろの opener を探す
  opener_idx = closer_idx - 1
  found = nil
  while opener_idx > openers_bottom[char_of(closer)]
    opener = delimiter_stack[opener_idx]
    if char_of(opener) == char_of(closer) && can_open?(opener)
      # sum-of-3 rule
      if (can_close?(opener) || can_open?(closer)) &&
         (count_of(opener) + count_of(closer)) % 3 == 0 &&
         !(count_of(opener) % 3 == 0 && count_of(closer) % 3 == 0)
        opener_idx -= 1; next
      end
      found = opener; break
    end
    opener_idx -= 1
  end

  unless found
    openers_bottom[char_of(closer)] = closer_idx - 1
    delimiter_stack.delete_at(closer_idx) unless can_open?(closer)
    closer_idx += 1
    next
  end

  strength = [count_of(found), count_of(closer)].min >= 2 ? 2 : 1
  node_type = strength == 2 ? STRONG : EMPHASIS

  # found と closer の間の暫定 TEXT を新しい EMPHASIS/STRONG の中に reparent
  # found / closer の暫定 TEXT は count を strength 分減らし、ゼロになったら detach + stack から削除
end
```

(前回 Phase 9-B 試行で `closer_idx` のインクリメント漏れと、reparent 時の `first_between_id == closer_node_id` ケース未処理でハマった。これらは linear pass で bracket を先に潰しておけば実質発生しないが、念のためコメント残す。)

### Text coalescing

linear pass で連続 TEXT token を merge して Arena ノード数を減らす。

```
last_child が TEXT で str1 が nil で source span が連続しているなら、
新 TEXT を作らずに last_child の source_len を伸ばす
```

ENTITY / ESCAPED_CHAR で str1 を持つ TEXT は、後続 TEXT との merge 時に str1 を文字列連結する必要がある (現状の `append_text` と同じ)。

## 既存 parse_* との対応マップ

| 現状の API | 新構造 |
|-----------|--------|
| `InlineParser` (class) | 削除 |
| `InlineScanner` (class) | 削除 (InlineLexer がほぼ等価) |
| `parse_into` | InlineLexer.scan + InlineBuilder.build |
| `parse_emphasis` | DELIM_RUN token + process_emphasis |
| `parse_triple_emphasis` | 同上 (count = 3 で自然に扱われる) |
| `parse_link` / `parse_image` | LBRACKET/BANG_LBRACKET/RBRACKET + builder の bracket matching |
| `parse_code_span` | CODE_DELIMITER + builder の code span matching |
| `parse_html_inline` | HTML_INLINE / AUTOLINK_* token |
| `parse_entity` | ENTITY token |
| `parse_line_break` | LINE_ENDING + builder の hardbreak/softbreak 判定 |
| `find_emphasis_closing` | 削除 (delimiter stack で解決) |
| `emphasis_underscore_open?` | flanking 判定に統合 |
| `triple_delimiter_open?` | 削除 (DELIM_RUN の count で自然に扱える) |
| `extract_link_like` / `extract_reference_like` | builder の bracket matching |
| `sanitize_destination` | builder で LINK/IMAGE ノード作成時 (現状ロジックそのまま) |
| `child_base_offset`, `parse_child`, `add_inline_node`, `src_start`, `src_len`, `source_end` | 削除 (base_offset 自体が消える) |

## InlinePass の変更

```ruby
class InlinePass
  INLINE_TARGETS = [NodeType::PARAGRAPH, NodeType::HEADING, NodeType::TABLE_CELL].freeze

  def initialize(document)
    @document = document
    @arena = document.arena
    @lexer = InlineLexer.new(@document.source)
    @tokens = InlineTokens.new   # document 単位で 1 個だけ作る
    @builder = InlineBuilder.new(@arena, @document.source, @document.references)
  end

  def apply
    visit(@document.root_id)
  end

  private

  def visit(node_id)
    if INLINE_TARGETS.include?(@arena.type(node_id))
      @tokens.clear              # 内容だけ捨てる (capacity は保持される)
      if (literal = @arena.str1(node_id))
        # literal 化された source (setext heading で escape 系が含まれた稀なケース)
        InlineLexer.new(literal).lex_into(@tokens, 0, literal.bytesize)
      else
        start_byte = @arena.source_start(node_id)
        end_byte = start_byte + @arena.source_len(node_id)
        @lexer.lex_into(@tokens, start_byte, end_byte)
      end
      @builder.build(node_id, @tokens)
      return
    end

    child_id = @arena.first_child(node_id)
    until child_id == -1
      visit(child_id)
      child_id = @arena.next_sibling(child_id)
    end
  end
end
```

`base_offset` の引数が消える。token は document の絶対 byte offset を保持しているので、そのまま Arena に保存できる。

メモリ的な要点:

- `@lexer` / `@tokens` / `@builder` は document 単位で **1 個ずつ**
- 各 inline target を処理するたびに `@tokens.clear` で内容だけ捨てる
- token storage の内部配列は最大サイズを覚えていて、以降の paragraph で再 allocate されない
- literal が乗ったレアケース (setext heading の escape 等) だけ新規 Lexer を作る (頻度が低いので許容)

## テスト戦略

### 単体テスト (新規追加)

**`spec/inline_lexer_spec.rb`**

- 各 token kind が正しく emit されるか (TEXT / DELIM_RUN / CODE_DELIMITER / LBRACKET / ...)
- delimiter run の count / can_open / can_close が CommonMark spec 通りか (flanking テーブル網羅)
- source span (start_byte / end_byte) が正しく document の絶対位置になっているか
- マルチバイト文字を含む input でも byte offset が正しいか
- escape (`\*`) / entity (`&amp;`) が正しく ESCAPED_CHAR / ENTITY になるか

**`spec/inline_builder_spec.rb`**

- 手で組み立てた token stream から、想定通りの Arena ツリーが構築されるか
- delimiter stack の edge case (空 stack で RBRACKET / nested emphasis / sum-of-3 ルール)
- code span が emphasis より優先されるか
- bracket matching で image 内 link が抑制されるか

**`spec/inline_flanking_spec.rb`**

- left/right flanking のテーブル網羅 (前後文字が space/punct/word/EOL の組み合わせ)

### 統合テスト (既存維持)

- `spec/commonmark_compat_spec.rb`: 既存 44 examples すべて維持
- `spec/mdarena_spec.rb`: 既存 34 examples すべて維持 (multibyte / source_location 含む)

### 新規追加 (Phase 9-B 兼ねる)

`spec/commonmark_compat_spec.rb` に CommonMark emphasis examples を追加:
- 350-365: basic `*` / `_`
- 366-380: closing conditions / underscore word_char
- 381-395: `**` / `__`
- 396-415: nested
- 419-430: delimiter in code / HTML / link

Phase 9-B が「設計の一部」として自然に通る状態を目標にする。

### Benchmark

`spec/bench_inline.rb` を再実行して、現行 (878 i/s on long_paragraph 等) との比較を取る。期待:

- substring 廃止で long_paragraph / nested_emphasis / deep_nesting が改善
- token stream 生成のオーバーヘッドはあるが、再帰 Parser 生成を消す方が効くはず
- 短いケース (short_paragraph) は token stream 生成で多少遅くなる可能性。許容範囲を見極める

## 移行手順

「一気に書き換える」方針:

1. **設計合意** (このドキュメント): 完了後にコーディングへ
2. **新規ファイル作成**: `lib/mdarena/inline/` 配下に lexer / tokens / builder / flanking
3. **`InlinePass` を新構造に差し替え**: 既存 `InlineParser`/`InlineScanner` を import している箇所を新クラスに置き換え
4. **既存テスト走らせて穴を埋める**: commonmark_compat / mdarena_spec を全 green に
5. **新規単体テスト追加**: lexer / builder / flanking
6. **CommonMark emphasis examples 追加**: Phase 9-B 分のテスト
7. **古いコード削除**: `lib/mdarena/inline_parser.rb`, `lib/mdarena/inline_scanner.rb`
8. **memory の roadmap 更新**: Phase 8 Step 2/3 と Phase 9-B が同時に達成された旨を記録

## 想定 commit 列

| # | コミット | 内容 |
|---|---------|------|
| 1 | `inline: add Lexer/Tokens/Builder scaffolding` | 空殻クラスとテストファイル |
| 2 | `inline lexer: emit TEXT / LINE_ENDING / ESCAPED_CHAR` | 基本 token |
| 3 | `inline lexer: emit CODE_DELIMITER / DELIM_RUN with flanking` | delimiter 系 |
| 4 | `inline lexer: emit brackets / AUTOLINK / HTML_INLINE / ENTITY` | 残り token |
| 5 | `inline builder: linear pass for TEXT / ENTITY / LINE_ENDING / HTML / AUTOLINK` | 簡単な node 化 |
| 6 | `inline builder: code span resolution` | CODE_SPAN |
| 7 | `inline builder: bracket matching for link/image` | LINK/IMAGE |
| 8 | `inline builder: delimiter stack with process_emphasis` | EMPHASIS/STRONG |
| 9 | `inline pass: switch to Lexer + Builder, drop old InlineParser` | 切り替え + 旧コード削除 |
| 10 | `spec: add CommonMark emphasis examples (Phase 9-B coverage)` | 新規 example 追加 |

各 commit でテストが green を保つように分割する。

## Performance 考察

### Allocation 比較 (概算)

長い paragraph (1500 chars, 100 emphasis) を想定:

| 項目 | 現状 | 新構造 |
|------|------|--------|
| InlineParser instance | ~100 (再帰深さ依存) | 0 (使わない) |
| InlineScanner instance | ~100 | 1 (`InlinePass` で使い回し) |
| substring String | ~100+ | 0 (byteslice しない) |
| Token storage | 0 | 1 (InlineTokens, parallel array) |
| delimiter_stack Array | ~100 (各 Parser で1個) | 1 |
| 暫定 TEXT ノード | (eager で確定なので存在せず) | DELIM_RUN ごとに 1個 |

**懸念**: 暫定 TEXT ノードが増える (delimiter run ごと)。ただしこれは Arena 内の id 払い出しで、Ruby object allocation ではない (parallel arrays の末尾追加)。

### 最終的な期待

- nested_emphasis / deep_nesting で大幅改善 (現状 654 / 390 i/s → 期待 1000 i/s 超)
- long_paragraph も substring 廃止で改善 (現状 878 i/s)
- short_paragraph は token stream のオーバーヘッドで微減の可能性、許容

## ast-spec.md との関係

ast-spec.md は **本案と矛盾しない**。むしろ Lexer + Builder 構成を想定して書かれている節がある:

- L699-768 "Inline Scanner / Inline Lexer" — token interface を fix する方針を明示
- L770-779 "Token objectは作らない" — `token_id / start / len` の 3 値で処理する方針。本案の parallel array storage はこれに合致 (struct を作らない)
- L1175-1186 "Phase 4 / 5: Inline scanner最適化 / LexerKit backend" — 本案でこの基盤が整う

修正点は以下を追記:

1. ファイル構成 (L57-83) に `inline/` ディレクトリと `lexer.rb` / `tokens.rb` / `builder.rb` / `flanking.rb` を追記
2. "Inline Parser" 節 (L783-847) を "Inline Builder" に改題し、二段構成を明示
3. 削除予定の `InlineParser` / `InlineScanner` への言及を整理

これらは設計合意後にまとめて修正する。

## 設計判断 (確定済み)

実装着手前に確定した方針:

1. **inline link destination の parsing**: → **source 直読み** (token 化しない)
   - `(url "title")` / `[ref]` の解析は builder で `@source.byteslice` から handwritten parser で処理
   - `LPAREN` / `RPAREN` token は導入しない (allocation 削減のため)
   - 既存の `extract_link_like` / `extract_reference_like` のロジックをそのまま流用

2. **token storage の生存範囲**: → **document 単位で 1 個を使い回す**
   - `InlinePass` が `@tokens = InlineTokens.new` を 1 度だけ作り、各 paragraph 処理前に `@tokens.clear` で内容だけ捨てる
   - Array#clear は length を 0 にするだけで内部 capacity は保持されるため、以降の paragraph で再 allocate されない
   - paragraph 数 × 7 配列 (kind, start_byte, end_byte, int1-3, str1) の allocation を avoid

3. **LexerKit backend interface**: → **Phase 5 で対応** (本リファクタでは扱わない)
   - 本リファクタでは parallel array storage (`InlineTokens`) 一本でよい
   - Phase 5 で `InlineTokens` 互換の iterator interface を別途設計し、LexerKit backend を追加

4. **GFM (strikethrough / table cell inline 等)**: → **本リファクタ完了後**
   - リファクタ自体のリスクを抑えるため、まず純 CommonMark で安定化させる
   - strikethrough は新たな DELIM_RUN char ('~') を増やすだけで自然に拡張できる構造になっている
   - table cell inline は既に `INLINE_TARGETS` に入っているので、リファクタで自動的に対応される
