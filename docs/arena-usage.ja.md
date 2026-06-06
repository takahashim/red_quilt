# Arenaクラスの使い方

`RedQuilt::Arena`はRedQuiltのAST本体を保持する低レベルストレージクラスです。
本稿はArenaを直接触る人(block parser/ inline builder / renderer /カスタムtransformerなど、`lib/red_quilt`配下のコードを使う人)向けに、そのAPIと前提条件を整理したものです。

>外部APIとしてASTを扱うだけなら`RedQuilt::Document`と`RedQuilt::NodeRef`を経由するのが標準です。Arenaは内部寄りのレイヤーで、`NodeRef`の実装が依存しているデータ構造そのものです。

---

## 0. 簡単な使い方

下のコードはそのままコピー＆ペーストすれば動きます。
Arenaが「source文字列をベースに各種IDでツリーを組み立てる」ものだという雰囲気が伝わるかと思います。

```ruby
require "red_quilt"

source = "Hello *world*"
arena = RedQuilt::Arena.new(source)

# (a)ノードを作る。戻り値はnode id (Integer)
para_id  = arena.add_node(RedQuilt::NodeType::PARAGRAPH,
                          source_start: 0, source_len: source.bytesize)
text_id  = arena.add_node(RedQuilt::NodeType::TEXT,
                          source_start: 0, source_len: 6)   # "Hello "
em_id    = arena.add_node(RedQuilt::NodeType::EMPHASIS,
                          source_start: 6, source_len: 7)   # "*world*"
inner_id = arena.add_node(RedQuilt::NodeType::TEXT,
                          source_start: 7, source_len: 5)   # "world"

# (b)親子関係を組む
arena.append_child(para_id, text_id)
arena.append_child(para_id, em_id)
arena.append_child(em_id,   inner_id)

# (c)内容を取り出す
puts "type:    #{arena.type_name(para_id)}"
puts "text:    #{arena.text(text_id).inspect}"
puts "inner:   #{arena.text(inner_id).inspect}"
puts "span:    #{arena.source_span(em_id).inspect}"

# (d)子を走査する(ブロック形式・Enumeratorなし)
puts "children of paragraph:"
arena.each_child(para_id) do |child_id|
  puts "  #{arena.type_name(child_id)}: #{arena.text(child_id).inspect}"
end
```

出力結果は以下のようになります。

```
type:    paragraph
text:    "Hello "
inner:   "world"
span:    #<RedQuilt::SourceSpan:0x... @start_byte=6, @end_byte=13>
children of paragraph:
  text: "Hello "
  emphasis: "*world*"
```

このサンプルが作るASTは次のようになります。

```
PARAGRAPH    [0, 13)   "Hello *world*"
├─TEXT      [0, 6)    "Hello "
└─EMPHASIS  [6, 13)   "*world*"
└─TEXT   [7, 12)   "world"
```

Arenaの扱いのポイントは以下になります。

- `add_node`はNode ID(Integer)を返す。以降のAPIは全部このIDをキーにする。
- `source_start` / `source_len`は元のsource文字列に対し、文字単位ではなくバイト単位で範囲を指定する。文字列そのもののコピーは持たない。
- `text(id)`はstr1があればそれを返し、なければ`source`をbytesliceする。
- `each_child(id)`を基本の走査APIとしてホットパスで使用する。

これらを頭に入れておくと、後の章は「実際にこのAPIは何を保証しているのか/どう使うべきか」として読めるはずです。

---

## 1. 設計の要点

ArenaはASTを「オブジェクトのツリー」ではなく[parallel array](https://en.wikipedia.org/wiki/Parallel_array)として表現します。

- ノードは整数ID(`node_id`)で識別されます
- 各IDに対応する属性(parent / source span / payload)はそれぞれ異なるArrayに列として保持します
- ノードの追加は各Arrayの末尾への代入操作だけで完結し、新しいRubyオブジェクトは一切生成しません

結果として、Arenaは以下のような性質を持ちます。

- ホットパスではIDというIntegerだけを取り回せる
- メモリ局所性が良く、GC圧が小さい
- ノードを「軽い」値として扱えるのでRenderer / Builderをinline化しやすい

#### 列(column)一覧

|列名|用途|
|------|------|
| `@type` | NodeType (Integer定数) |
| `@parent` / `@first_child` / `@last_child` / `@next_sibling` / `@prev_sibling` |親・子・兄弟リンク。値はnode id (`NO_NODE`で「なし」) |
| `@source_start` / `@source_len` | document source内のバイト範囲。`source_start < 0`は「spanなし」を意味する|
| `@int1` / `@int2` / `@int3` | NodeTypeごとに用途が決まる整数スロット(default `0`) |
| `@str1` / `@str2` | NodeTypeごとに用途が決まる文字列スロット(default `nil`) |

---

## 2. 不変条件

Arenaを扱う上で常に成り立つ前提です。

1. Node IDは単調増加する
   `add_node`で払い出されるIDは`@type.length`から始まり、追加するたびに1ずつ増えます。IDが再利用されることはありません。
2. detachされたノードも列に残る
   `detach`は親・兄弟リンクを`NO_NODE`にリセットするだけで、列のレコード自体はarena内に残り続けます。後続の`add_node`がそのスロットを再利用することもありません。これはallocationを単純化するための意図的な選択です。
3. `@source`はimmutableとして扱う
   Arena構築後にsourceを書き換えてはいけません。`source_start` / `source_len`は直接バイト範囲を指しているため、sourceが変わると`text` / `source_span`の戻り値が壊れます。
4. `NO_NODE` = -1
親や兄弟が存在しないことを示すsentinelです。`Arena::NO_NODE`定数で参照できます。
5. `source_start < 0`は「spanなし」
この場合、leafノードの内容は`@str1`にliteralとして持つことが多いです(例: blockquoteを解除したparagraph、entityデコード後のTEXT)。ただしcontainer inlineのように、spanなしでも`str1`を使わず子ノードから内容を構成するNodeTypeもあります。

---

## 3. APIのレイヤー

Arenaの公開メソッドは以下の3レイヤーに分けて読むと意図が掴みやすくなります。

### 3.1 構造の操作(mutators)

ツリーを組み立て・編集するためのAPIです。`validなid`を渡す前提で、安全性チェックは最小限です。

|メソッド|概要|
|----------|------|
| `add_node(type, **fields)` |新規ノードを末尾に追加。IDを返す。初期状態はdetached |
| `append_child(parent_id, child_id)` |親の子リスト末尾に追加|
| `insert_before(parent_id, ref_id, new_id)` | `ref_id`の直前に挿入|
| `detach(child_id)` |親から切り離す。ノード自体は残る|
| `reparent(new_parent_id, first_id, last_id)` | `first_id..last_id`の兄弟範囲を新しい親へ移動|
| `update_span(id, start_byte, end_byte)` | source spanを再設定|
| `update_str1(id, value)` / `update_int3(id, value)` |個別slotの書き換え|

### 3.2 構造の参照(raw id accessors)

`NO_NODE`を返しうる、生のcolumn値を取り出します。命名規則`raw_X_id`は「戻り値がnode idで、-1 (`NO_NODE`)になる可能性がある」ことを示します。

|メソッド|戻り値|
|----------|--------|
| `raw_parent_id(id)` |親idか`NO_NODE` |
| `raw_first_child_id(id)` / `raw_last_child_id(id)` |子idか`NO_NODE` |
| `raw_next_sibling_id(id)` / `raw_prev_sibling_id(id)` |兄弟idか`NO_NODE` |

### 3.3 ペイロードの参照(column accessors)

各columnを生のまま返します。「sentinelが返り得る」ことは戻り値の型から読み取ってください。

|メソッド|戻り値|
|----------|--------|
| `type(id)` | NodeType定数(Integer) |
| `type_name(id)` | Symbol (例: `:paragraph`) |
| `source_start(id)` / `source_len(id)` | byte offset / byte長。`source_start < 0`はspanなし|
| `int1(id)` / `int2(id)` / `int3(id)` | Integer (default 0) |
| `str1(id)` / `str2(id)` | String or `nil` |

### 3.4 セマンティックaccessor

低レベル列を解釈して「使いやすい値」を返します。`nil`を返しうるのは明示的に「無い」ことを表現するためです。

|メソッド|戻り値|
|----------|--------|
| `source_span(id)` | `SourceSpan`か`nil` (spanなしの場合) |
| `text(id)` | `str1`があればそれ、なければ`source.byteslice(...)`。どちらもなければ`nil` |

### 3.5 走査

|メソッド|用途|
|----------|------|
| `each_child(id) { |child_id| ... }` |ブロック形式。ホットパス推奨(Enumerator不要) |
| `child_ids(id)` | `Enumerator`を返す。`map` / `select`などのチェイン用|

---

## 4. NodeTypeごとのslot用法

各NodeTypeがどのint / strスロットを使うかは規約で決まっています。以下が現在の規約です。

#### Blockノード

| NodeType | int1 | int2 | int3 | str1 | str2 |
|----------|------|------|------|------|------|
| `DOCUMENT` | - | - | - | - | - |
| `PARAGRAPH` | - | - | - | 必要時の結合済みliteral(transformed時、leading indent除去時など) | - |
| `HEADING` | level (1-6) | - | - | 必要時のinline literal(transformed時、setext headingなど) | - |
| `THEMATIC_BREAK` | - | - | - | - | - |
| `BLOCKQUOTE` | - | - | - | - | - |
| `LIST` | ordered? (0/1) | start_number | tight? (1=tight) | marker (`-`/`*`/`+`/`.`/`)`) | - |
| `LIST_ITEM` | - | - | - | - | - |
| `CODE_BLOCK` | - | - | - | code内容(literal) | info string (fencedのみ) |
| `HTML_BLOCK` | - | - | - | HTML内容(literal) | - |
| `TABLE` | - | - | - | - | - |
| `TABLE_ROW` | header? (1/0) | - | - | - | - |
| `TABLE_CELL` | header? (1/0) | - | - | strippedセルtext | - |
| `FOOTNOTE_DEFINITION` | - | - | - | 正規化済みlabel | - |
| `FOOTNOTES_SECTION` | - | - | - | - | - |

#### Inlineノード

| NodeType | int1 | int2 | int3 | str1 | str2 |
|----------|------|------|------|------|------|
| `TEXT` | - | - | - | literal (entity decode後など)または`nil` (spanベース) | - |
| `SOFTBREAK` / `HARDBREAK` | - | - | - | `"\n"` | - |
| `EMPHASIS` / `STRONG` / `STRIKETHROUGH` | - | - | - | - | - |
| `CODE_SPAN` | - | - | - | normalized content (literal) | - |
| `LINK` | - | - | - | sanitized destination | title (or `nil`) |
| `IMAGE` | - | - | - | sanitized destination | title (or `nil`) |
| `HTML_INLINE` | - | - | - | matched HTML literal | - |
| `FOOTNOTE_REFERENCE` | footnote番号 | 出現回数(同一labelのN個目) | - | 正規化済みlabel | - |

> `-`は「使わない」を意味します(default値`0` / `nil`のまま)。

> footnoteは`footnotes: true`時のみ生成されます。`FOOTNOTES_SECTION`はroot直下の最後の子として置かれ(span-less、`source_start: -1`)、参照された`FOOTNOTE_DEFINITION`を初回参照順に保持します。backrefの個数はfootnote番号とlabelからrender時に算出します。

#### Source spanの慣習

- `source_start` / `source_len`: 元documentのbytes (絶対byte offset)
- `source_start < 0`: spanなし。leafノードでは内容を`str1`にliteralとして持つことが多いが、container inlineは子ノードだけを持つ場合がある。
- blockノードのspanは用途で2系統に分かれる。
    - inline対象(paragraph / heading / table cell)のspanは、InlinePassがそのまま字句解析するbyte範囲を兼ねるため、`#`やprefixを除いたinline本文を指す。
    - それ以外(list / blockquote / table / code / html block等)は字句解析に使われず、構造/行寄りの位置情報のみを持つ。

---

## 5. 典型的な使い方

### 5.1 Arenaを作って小さなASTを組み立てる

```ruby
source = "Hello *world*"
arena = RedQuilt::Arena.new(source)

doc_id = arena.add_node(RedQuilt::NodeType::DOCUMENT,
                        source_start: 0, source_len: source.bytesize)

para_id = arena.add_node(RedQuilt::NodeType::PARAGRAPH,
                         source_start: 0, source_len: source.bytesize)
arena.append_child(doc_id, para_id)

text_id = arena.add_node(RedQuilt::NodeType::TEXT,
                         source_start: 0, source_len: 6) # "Hello "
arena.append_child(para_id, text_id)

em_id = arena.add_node(RedQuilt::NodeType::EMPHASIS,
                       source_start: 6, source_len: 7) # "*world*"
arena.append_child(para_id, em_id)

inner_id = arena.add_node(RedQuilt::NodeType::TEXT,
                          source_start: 7, source_len: 5) # "world"
arena.append_child(em_id, inner_id)

arena.text(text_id)        # => "Hello "
arena.text(inner_id)       # => "world"
arena.source_span(em_id)   # => #<SourceSpan @start_byte=6 @end_byte=13>
```

### 5.2 兄弟をループする(ホットパス)

```ruby
arena.each_child(para_id) do |child_id|
  case arena.type(child_id)
  when RedQuilt::NodeType::TEXT
    output << arena.text(child_id)
  when RedQuilt::NodeType::EMPHASIS
    output << "<em>"
    render_children(child_id)
    output << "</em>"
  end
end
```

`Enumerator`チェインしたい場合(NodeRefなど)は以下のようにします。

```ruby
arena.child_ids(para_id).map { |id| arena.type_name(id) }
# => [:text, :emphasis]
```

### 5.3 ノードを別の親に移動する

`reparent`は移動先ノードのchildrenを置き換えるAPIなので、移動先は新規作成した空ノードにするのが基本です。

```ruby
# `em_id`の子を新しいstrong_id直下に移す
strong_id = arena.add_node(RedQuilt::NodeType::STRONG,
                           source_start: arena.source_start(em_id),
                           source_len: arena.source_len(em_id))
arena.insert_before(arena.raw_parent_id(em_id), em_id, strong_id)

first = arena.raw_first_child_id(em_id)
last  = arena.raw_last_child_id(em_id)
arena.reparent(strong_id, first, last) if first != RedQuilt::Arena::NO_NODE

# em_idを空のまま切り離す。strong_idはem_idの位置に残る。
arena.detach(em_id)
```

### 5.4 ノードを差し替える

```ruby
# em_idをstrong_idに置換(中身はそのまま)
strong_id = arena.add_node(RedQuilt::NodeType::STRONG,
                            source_start: arena.source_start(em_id),
                            source_len: arena.source_len(em_id))
arena.insert_before(arena.raw_parent_id(em_id), em_id, strong_id)

first = arena.raw_first_child_id(em_id)
last  = arena.raw_last_child_id(em_id)
arena.reparent(strong_id, first, last) if first != RedQuilt::Arena::NO_NODE

arena.detach(em_id)
```

### 5.5 列の値を直接更新する

```ruby
# headingのレベルはint1に入っているが、書き換え専用setterは無いので
#必要なら追加する。現在はstr1 / int3 / spanのみpublic setterあり:
arena.update_str1(text_id, "Hello, world!")
arena.update_int3(list_id, 1) # tightに
arena.update_span(text_id, 0, 12)
```

なおint1 / int2 / str2のsetterは現状ありません。必要が出た時点で`update_int1`などを追加する想定です。

---

## 6. パフォーマンス上の注意

#### ホットパスでは`each_child`を使う

ブロック直yieldでEnumerator allocationを避ける。`child_ids`は外部API用

#### `text(id)`はstr1を優先する

余計な`byteslice`を起こさないため、sourceから復元できる内容は`str1`を`nil`のままにするのが基本。ただしentity decode後のTEXT、code/html literal、table cell、transformed/literal inline targetなど、正しさのためにliteralが必要なケースでは`str1`を使う

#### `source_span(id)`は`SourceSpan`を毎回allocateする

ホットパスで使うなら`source_start` / `source_len`を直接読む方が良い

#### `detach`したnodeは捨て切れない

大量にdetachする処理を繰り返すとarenaの列が膨らみ続ける。1つのdocumentのparse内では問題ない規模だが、長寿命のarenaには向かない

---

## 7.落とし穴

#### `raw_*_id`の戻り値を生でforeign key参照する場合

`NO_NODE` (-1)チェックを忘れない。Array#[-1]にすると配列末尾を読んでしまい、treeが壊れる

#### `reparent`の前提

`first_id`から`next_sibling`を辿って`last_id`に到達する必要がある。違う親のノードや、`first_id`の後ろにある到達不能な`last_id`を渡すと無限ループする可能性がある(実際builderで過去にハマった)

#### `source_start < 0`の意味

「位置情報を捨てたliteralモード」。ユーザーAPI (`SourceMap`, `node.source_location`等)はspanなし扱いになる。これを忘れてdebuggerで「位置情報がない」と困惑しないこと

#### `@source`を後から変えない

仮にやると`text` / `source_span`の戻り値が静かに壊れる
