# Arena クラスの使い方

`Markdast::Arena` は markdast の AST 本体を保持する低レベルストレージです。本書は **Arena を直接触る人** (block parser / inline builder / renderer / カスタム transformer など、`lib/markdast` 配下のコード) 向けに、その API と前提条件を整理したものです。

> 外部 API として AST を扱うだけなら `Markdast::Document` と `Markdast::NodeRef` を経由するのが標準です。Arena は内部寄りのレイヤーで、`NodeRef` の実装が依存しているデータ構造そのものです。

---

## 1. 設計の要点

Arena は AST を **オブジェクトツリーではなく parallel array** として表現します。

- ノードは整数 ID で識別される (`node_id`)
- 各 ID に対応する属性 (parent / source span / payload) は別々の Array に列として保持される
- ノード追加では Ruby オブジェクトを 1 個も作らない (Array への push のみ)

得られる性質:

- ホットパスでは ID という Integer だけを取り回せる
- メモリ局所性が良く、GC 圧が小さい
- ノードを「軽い」値として扱えるので Renderer / Builder を inline 化しやすい

### 列 (column) 一覧

| 列名 | 用途 |
|------|------|
| `@type` | NodeType (Integer 定数) |
| `@parent` / `@first_child` / `@last_child` / `@next_sibling` / `@prev_sibling` | 親・子・兄弟リンク。値は node id (`NO_NODE` で「なし」) |
| `@source_start` / `@source_len` | document source 内のバイト範囲。`source_start < 0` は「span なし、内容は str1 に持つ」を意味する |
| `@int1` / `@int2` / `@int3` | NodeType ごとに用途が決まる整数スロット (default `0`) |
| `@str1` / `@str2` | NodeType ごとに用途が決まる文字列スロット (default `nil`) |

---

## 2. 不変条件

Arena を扱う上で常に成り立つ前提です。

1. **node id は単調増加**
   `add_node` で払い出される ID は `@type.length` から始まり、追加するたびに 1 ずつ増えます。ID が再利用されることはありません。
2. **detach されたノードも列に残る**
   `detach` は親・兄弟リンクを `NO_NODE` にリセットするだけで、列のレコード自体は arena 内に残り続けます。後続の `add_node` がそのスロットを再利用することもありません。これは allocation を単純化するための意図的な選択です。
3. **`@source` は immutable として扱う**
   Arena 構築後に source を書き換えてはいけません。`source_start` / `source_len` は直接バイト範囲を指しているため、source が変わると `text` / `source_span` の戻り値が壊れます。
4. **`NO_NODE` = -1**
   親や兄弟が存在しないことを示す sentinel です。`Arena::NO_NODE` 定数で参照できます。
5. **`source_start < 0` は「span なし」**
   この場合、ノードの内容は `@str1` に literal として持たれていることが期待されます (例: blockquote を解除した paragraph、entity デコード後の TEXT)。

---

## 3. API のレイヤー

Arena の公開メソッドは以下の 3 レイヤーに分けて読むと意図が掴みやすくなります。

### 3.1 構造の操作 (mutators)

ツリーを組み立て・編集するための API です。`valid な id` を渡す前提で、安全性チェックは最小限です。

| メソッド | 概要 |
|----------|------|
| `add_node(type, **fields)` | 新規ノードを末尾に追加。ID を返す。初期状態は detached |
| `append_child(parent_id, child_id)` | 親の子リスト末尾に追加 |
| `insert_before(parent_id, ref_id, new_id)` | `ref_id` の直前に挿入 |
| `detach(child_id)` | 親から切り離す。ノード自体は残る |
| `reparent(new_parent_id, first_id, last_id)` | `first_id..last_id` の兄弟範囲を新しい親へ移動 |
| `update_span(id, start_byte, end_byte)` | source span を再設定 |
| `replace_str1(id, value)` / `replace_int3(id, value)` | 個別 slot の書き換え |

### 3.2 構造の参照 (raw id accessors)

`NO_NODE` を返しうる、生の column 値を取り出します。命名規則 `raw_X_id` は「戻り値が node id で、-1 (`NO_NODE`) になる可能性がある」ことを示します。

| メソッド | 戻り値 |
|----------|--------|
| `raw_parent_id(id)` | 親 id か `NO_NODE` |
| `raw_first_child_id(id)` / `raw_last_child_id(id)` | 子 id か `NO_NODE` |
| `raw_next_sibling_id(id)` / `raw_prev_sibling_id(id)` | 兄弟 id か `NO_NODE` |

### 3.3 ペイロードの参照 (column accessors)

各 column を生のまま返します。「sentinel が返り得る」ことは戻り値の型から読み取ってください。

| メソッド | 戻り値 |
|----------|--------|
| `type(id)` | NodeType 定数 (Integer) |
| `type_name(id)` | Symbol (例: `:paragraph`) |
| `source_start(id)` / `source_len(id)` | byte offset / byte 長。`source_start < 0` は span なし |
| `int1(id)` / `int2(id)` / `int3(id)` | Integer (default 0) |
| `str1(id)` / `str2(id)` | String or `nil` |

### 3.4 セマンティック accessor

低レベル列を解釈して「使いやすい値」を返します。`nil` を返しうるのは明示的に「無い」ことを表現するため。

| メソッド | 戻り値 |
|----------|--------|
| `source_span(id)` | `SourceSpan` か `nil` (span なしの場合) |
| `text(id)` | `str1` があればそれ、なければ `source.byteslice(...)`。どちらもなければ `nil` |

### 3.5 走査

| メソッド | 用途 |
|----------|------|
| `each_child(id) { |child_id| ... }` | ブロック形式。ホットパス推奨 (Enumerator 不要) |
| `child_ids(id)` | `Enumerator` を返す。`map` / `select` などのチェイン用 |

---

## 4. NodeType ごとの slot 用法

各 NodeType がどの int / str スロットを使うかは慣習で決まっています。以下が現在の規約です。

### Block ノード

| NodeType | int1 | int2 | int3 | str1 | str2 |
|----------|------|------|------|------|------|
| `DOCUMENT` | - | - | - | - | - |
| `PARAGRAPH` | - | - | - | (transformed 時のみ) 結合済み literal | - |
| `HEADING` | level (1-6) | - | - | (transformed 時のみ) inline literal | - |
| `THEMATIC_BREAK` | - | - | - | - | - |
| `BLOCKQUOTE` | - | - | - | - | - |
| `LIST` | ordered? (0/1) | start_number | tight? (1=tight) | marker (`-`/`*`/`+`/`.`/`)`) | - |
| `LIST_ITEM` | - | - | - | - | - |
| `CODE_BLOCK` | - | - | - | code 内容 (literal) | info string (fenced のみ) |
| `HTML_BLOCK` | - | - | - | HTML 内容 (literal) | - |
| `TABLE` | - | - | - | - | - |
| `TABLE_ROW` | header? (1/0) | - | - | - | - |
| `TABLE_CELL` | header? (1/0) | - | - | stripped セル text | - |

### Inline ノード

| NodeType | int1 | int2 | int3 | str1 | str2 |
|----------|------|------|------|------|------|
| `TEXT` | - | - | - | literal (entity decode 後など) または `nil` (span ベース) | - |
| `SOFTBREAK` / `HARDBREAK` | - | - | - | `"\n"` | - |
| `EMPHASIS` / `STRONG` / `STRIKETHROUGH` | - | - | - | - | - |
| `CODE_SPAN` | - | - | - | normalized content (literal) | - |
| `LINK` | - | - | - | sanitized destination | title (or `nil`) |
| `IMAGE` | - | - | - | sanitized destination | title (or `nil`) |
| `HTML_INLINE` | - | - | - | matched HTML literal | - |

> `-` は「使わない」を意味します (default 値 `0` / `nil` のまま)。

### Source span の慣習

- `source_start` / `source_len`: 元 document の bytes (絶対 byte offset)
- `source_start < 0`: span なし。内容は `str1` に literal として持たれる (transformed paragraph や Lexer の literal モードで生じる)
- block ノードは「自分の text 範囲」を span として持つ (`#` や `>` の prefix を除いた、内側のみ)

---

## 5. 典型的な使い方

### 5.1 Arena を作って小さな AST を組み立てる

```ruby
source = "Hello *world*"
arena = Markdast::Arena.new(source)

doc_id = arena.add_node(Markdast::NodeType::DOCUMENT,
                        source_start: 0, source_len: source.bytesize)

para_id = arena.add_node(Markdast::NodeType::PARAGRAPH,
                         source_start: 0, source_len: source.bytesize)
arena.append_child(doc_id, para_id)

text_id = arena.add_node(Markdast::NodeType::TEXT,
                         source_start: 0, source_len: 6) # "Hello "
arena.append_child(para_id, text_id)

em_id = arena.add_node(Markdast::NodeType::EMPHASIS,
                       source_start: 6, source_len: 7) # "*world*"
arena.append_child(para_id, em_id)

inner_id = arena.add_node(Markdast::NodeType::TEXT,
                          source_start: 7, source_len: 5) # "world"
arena.append_child(em_id, inner_id)

arena.text(text_id)        # => "Hello "
arena.text(inner_id)       # => "world"
arena.source_span(em_id)   # => #<SourceSpan @start_byte=6 @end_byte=13>
```

### 5.2 兄弟をループする (ホットパス)

```ruby
arena.each_child(para_id) do |child_id|
  case arena.type(child_id)
  when Markdast::NodeType::TEXT
    output << arena.text(child_id)
  when Markdast::NodeType::EMPHASIS
    output << "<em>"
    render_children(child_id)
    output << "</em>"
  end
end
```

`Enumerator` チェインしたい場合 (NodeRef など):

```ruby
arena.child_ids(para_id).map { |id| arena.type_name(id) }
# => [:text, :emphasis]
```

### 5.3 ノードを別の親に移動する

```ruby
# `em_id` の子を全部 `para_id` 直下に移す
first = arena.raw_first_child_id(em_id)
last  = arena.raw_last_child_id(em_id)
arena.reparent(para_id, first, last) if first != Markdast::Arena::NO_NODE

# em_id を空のまま切り離す
arena.detach(em_id)
```

### 5.4 ノードを差し替える

```ruby
# em_id を strong_id に置換 (中身はそのまま)
strong_id = arena.add_node(Markdast::NodeType::STRONG,
                            source_start: arena.source_start(em_id),
                            source_len: arena.source_len(em_id))
arena.insert_before(arena.raw_parent_id(em_id), em_id, strong_id)

first = arena.raw_first_child_id(em_id)
last  = arena.raw_last_child_id(em_id)
arena.reparent(strong_id, first, last) if first != Markdast::Arena::NO_NODE

arena.detach(em_id)
```

### 5.5 列の値を直接更新する

```ruby
# heading のレベルは int1 に入っているが、書き換え専用 setter は無いので
# 必要なら追加する。現在は str1 / int3 / span のみ public setter あり:
arena.replace_str1(text_id, "Hello, world!")
arena.replace_int3(list_id, 1) # tight に
arena.update_span(text_id, 0, 12)
```

> int1 / int2 / str2 の setter は現状ありません。必要が出た時点で `replace_int1` などを追加する想定です。

---

## 6. パフォーマンス上の注意

- **ホットパスでは `each_child` を使う**: ブロック直 yield で Enumerator allocation を避ける。`child_ids` は外部 API 用
- **`text(id)` は str1 を優先する**: 余計な `byteslice` を起こさないため、可能な限り `str1` に literal を持たせない (`nil` のまま) のが基本
- **`source_span(id)` は `SourceSpan` を毎回 allocate する**: ホットパスで使うなら `source_start` / `source_len` を直接読む方が良い
- **`detach` した node は捨て切れない**: 大量に detach する処理を繰り返すと arena の列が膨らみ続ける。1 つの document の parse 内では問題ない規模だが、長寿命の arena には向かない

---

## 7. 落とし穴

- **`raw_*_id` の戻り値を生で foreign key 参照する場合**: `NO_NODE` (-1) チェックを忘れない。Array#[-1] にすると配列末尾を読んでしまい、tree が壊れる
- **`reparent` の前提**: `first_id` から `next_sibling` を辿って `last_id` に到達する必要がある。違う親のノードや、`first_id` の後ろにある到達不能な `last_id` を渡すと無限ループする可能性がある (実際 builder で過去にハマった)
- **`source_start < 0` の意味**: 「位置情報を捨てた literal モード」。ユーザー API (`SourceMap`, `node.source_location` 等) は span なし扱いになる。これを忘れて debugger で「位置情報がない」と困惑しないこと
- **`@source` を後から変えない**: 仮にやると `text` / `source_span` の戻り値が静かに壊れる

---

## 8. 関連ドキュメント

- `ast-spec.md` — Markdast 全体の AST 設計方針。Arena が「parallel array で持つ」とした背景はこちらに記載
- `inline-redesign.md` — Inline pipeline (Lexer + Builder) の設計。Arena に対する操作パターンの具体例として参考になる
