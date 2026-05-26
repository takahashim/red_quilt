# Markdown Processor: Arena AST 設計案

## 目的

RubyでMarkdown processorを実装するにあたり、通常のRubyオブジェクトツリーとしてASTを構築すると、ノード数・文字列断片・Tokenオブジェクトが大量に生成され、Markly/cmark系と比べて速度・メモリ使用量で大きく不利になりやすい。

そのため、本設計では以下を目標とする。

- 内部ASTはRubyオブジェクトツリーではなく、数値IDベースのArena構造で保持する
- Textノードは文字列を複製せず、元ソース文字列へのspanとして保持する
- 内部処理ではNodeオブジェクトを作らず、`node_id` の整数だけを取り回す
- 外部APIでは必要に応じて `NodeRef` wrapper を返す
- `parse` と `render_html` の経路を分け、HTML生成だけなら完全AST構築を避けられる余地を残す

## 基本方針

処理系は大きく以下の層に分ける。

```text
Source
  ↓
Line-oriented BlockParser
  ↓
Arena AST with raw inline spans
  ↓
InlinePass
  ↓
Inline::Lexer → Inline::Tokens → Inline::Builder
  ↓
Arena AST with inline nodes
  ↓
Renderer / Formatter / Transformer
```

APIとしては次の2系統を持つ。

```ruby
doc = Mdarena.parse(source)        # Arena ASTを構築する
html = Mdarena.render_html(source) # 速度重視。AST構築を省略できる余地を持つ (現状は内部で parse 経由)
```

## 全体構成

```text
lib/mdarena/
  source_map.rb
  source_span.rb

  arena.rb
  node_ref.rb
  node_type.rb

  block_parser.rb
  inline_pass.rb
  extended_autolink_pass.rb
  inline/
    lexer.rb           # 文字スキャン + token emit (StringScanner ベース)
    tokens.rb          # Inline::Tokens (parallel array storage)
    token_kind.rb      # token kind 定数
    builder.rb         # token 消費 + delimiter stack + arena への node 追加
    flanking.rb        # left/right flanking 判定ヘルパー
    html_entities.rb   # HTML5 named entity 辞書

  renderer/html.rb
  document.rb
  diagnostic.rb

  cli.rb
  version.rb
```

formatter / transformer は今のところ未実装 (拡張枠としてのみ言及)。

インライン処理は **Lexer + Builder の二段構成**。

- `Inline::Lexer`: source の文字スキャンと token emit。Arena を触らない
- `Inline::Tokens`: token stream の軽量ストレージ (parallel array)
- `Inline::Builder`: token stream を消費し、delimiter stack で emphasis を解決して Arena に node を追加
- 二段に分けることで、CommonMark spec の delimiter stack アルゴリズムを素直に実装でき、GFM strikethrough のような拡張も DELIM_RUN の char を 1 つ増やすだけで取り込める

Builder は token stream のインターフェイス (`Inline::Tokens` 互換) にだけ依存し、Lexer の実装を選ばない。

## Arena AST

### コンセプト

通常のASTは次のようにノードごとにRubyオブジェクトを作る。

```ruby
Document.new([
  Heading.new(level: 1, children: [
    Text.new("Hello")
  ]),
  Paragraph.new(children: [
    Text.new("World")
  ])
])
```

本設計では、内部的にはこうしたオブジェクトツリーを作らない。

代わりに、すべてのノードを `node_id` で識別し、ノード情報を複数の配列に分けて保持する。

```text
node_id = 0
type[0] = DOCUMENT
first_child[0] = 1
next_sibling[0] = -1

node_id = 1
type[1] = HEADING
level[1] = 1
first_child[1] = 2
next_sibling[1] = 3

node_id = 2
type[2] = TEXT
source_start[2] = 2
source_len[2] = 5

node_id = 3
type[3] = PARAGRAPH
...
```

### Arenaの基本構造

初期実装ではRubyの配列を使う。

```ruby
module Mdarena
  class Arena
    attr_reader :source

    def initialize(source)
      @source = source

      @type = []

      @parent = []
      @first_child = []
      @last_child = []
      @next_sibling = []
      @prev_sibling = []

      @source_start = []
      @source_len = []

      @int1 = []
      @int2 = []
      @int3 = []

      @str1 = []
      @str2 = []
    end

    def add_node(type, source_start: -1, source_len: 0, int1: 0, int2: 0, int3: 0, str1: nil, str2: nil)
      id = @type.length

      @type[id] = type

      @parent[id] = -1
      @first_child[id] = -1
      @last_child[id] = -1
      @next_sibling[id] = -1
      @prev_sibling[id] = -1

      @source_start[id] = source_start
      @source_len[id] = source_len

      @int1[id] = int1
      @int2[id] = int2
      @int3[id] = int3

      @str1[id] = str1
      @str2[id] = str2

      id
    end

    def append_child(parent_id, child_id)
      @parent[child_id] = parent_id

      if @first_child[parent_id] == NO_NODE
        @first_child[parent_id] = child_id
        @last_child[parent_id] = child_id
      else
        last = @last_child[parent_id]
        @next_sibling[last] = child_id
        @prev_sibling[child_id] = last
        @last_child[parent_id] = child_id
      end

      child_id
    end
  end
end
```

> 子・兄弟へのアクセス API は `raw_first_child_id` / `raw_last_child_id` / `raw_next_sibling_id` / `raw_prev_sibling_id` / `raw_parent_id` のように `raw_..._id` 命名規則を採る。`raw_` は「NO_NODE (-1) 戻り値あり」、`_id` は「node id を返す」ことの明示。詳細は `arena-usage.md`。

### なぜparallel arrayにするか

ノードごとにHashやStructを作ると、ノード数に比例してRubyオブジェクトが増える。

```ruby
{
  type: :text,
  start: 10,
  length: 5,
  children: []
}
```

のような構造は扱いやすいが、Markdownのように細かいTextノードが大量に出る処理では不利になる。

parallel arrayにすると、少なくともノード自体のRubyオブジェクト生成を避けられる。

```text
@type[node_id]
@source_start[node_id]
@source_len[node_id]
@first_child[node_id]
```

というアクセスになるため、内部処理は整数IDだけで完結する。

## ノード種別

ノード種別はSymbolではなくInteger定数にする。

```ruby
module Mdarena
  module NodeType
    DOCUMENT = 1

    PARAGRAPH = 10
    HEADING = 11
    THEMATIC_BREAK = 12
    BLOCKQUOTE = 13
    LIST = 14
    LIST_ITEM = 15
    CODE_BLOCK = 16
    HTML_BLOCK = 17
    TABLE = 18
    TABLE_ROW = 19
    TABLE_CELL = 20

    TEXT = 100
    SOFTBREAK = 101
    HARDBREAK = 102
    EMPHASIS = 103
    STRONG = 104
    CODE_SPAN = 105
    LINK = 106
    IMAGE = 107
    HTML_INLINE = 109
    STRIKETHROUGH = 111
  end
end
```

> `AUTOLINK` / `ENTITY` の専用 NodeType は持たない。`<http://...>` は通常の `LINK` ノード (autolink token を Builder 側で `LINK` に変換)、`&amp;` などの entity は decoded literal を `str1` に持つ `TEXT` として表現する。

外部APIではSymbolに変換して返してもよい。

```ruby
node.type
#=> :paragraph
```

ただし内部処理ではIntegerのまま扱う。

## ノード属性の持ち方

### 共通属性

すべてのノードは以下を持つ。

```text
type
parent
first_child
last_child
next_sibling
prev_sibling
source_start
source_len
```

`source_start` / `source_len` は元ソース文字列におけるbyte offsetである。

line / column は保持せず、必要時に `SourceMap` から計算する。

### 汎用スロット

ノード種別ごとの属性は、まずは汎用スロットで持つ。

```text
int1
int2
int3
str1
str2
```

例:

```text
HEADING:
  int1 = level

LIST:
  int1 = ordered? 1 : 0
  int2 = start_number
  int3 = tight? 1 : 0

CODE_BLOCK:
  str1 = info
  source_start/source_len = literal body span

LINK:
  str1 = destination
  str2 = title

IMAGE:
  str1 = destination
  str2 = title

TABLE_CELL:
  int1 = alignment
```

初期実装ではこれで十分だが、ノード種別が増えて複雑になった場合は、専用属性テーブルを追加する。

```text
@heading_level[node_id]
@list_ordered[node_id]
@link_destination[node_id]
```

ただし、最初から専用配列を増やしすぎると実装が煩雑になるため、まずは汎用スロットで開始する。

## Source Span

### byte offsetを真の位置とする

内部位置はすべてbyte offsetで持つ。

```text
source_start: byte offset
source_len: byte length
```

RubyのStringはUTF-8文字を含むため、文字数ベースのcolumnは高コストになりやすい。内部処理ではbyte offsetを真の値とし、line/columnは診断表示時にだけ計算する。なお、外部APIに公開する `column` 自体は文字単位とする（後述）。

### 文字インデックスとバイトオフセットの使い分け

mdarenaは内部で文字インデックスとバイトオフセットを意図的に使い分ける。
両者を取り違えるとマルチバイト文字（CJK / Cyrillicなど）でHTMLが壊れる、source spanがずれる、といった事故が発生するため、レイヤーごとに「どちらの単位を使うか」を固定する。

#### レイヤー別の単位

| レイヤー | 単位 | 理由 |
|----------|------|------|
| `Arena#source_start` / `source_len` | byte | `String#byteslice` でO(len)に取り出せる |
| `SourceSpan#start_byte` / `end_byte` | byte | 内部単位をそのまま公開（名前で明示） |
| `Inline::Lexer` 内部位置 (`StringScanner#pos`) | byte | token の `start_byte` / `end_byte` をそのまま Arena に渡せる |
| `Inline::Tokens` 各 token の位置 | byte | document 全体の絶対 byte offset |
| `SourceMap#line_column` 入力 | byte | byte offset から line/column を逆引き |
| `node.source_location` の column | char | 編集系ツール・診断表示はユーザーにとって文字単位の方が自然 |

#### なぜこの分け方になるか

Rubyの`String`には2系統のAPIがある。

- 文字単位: `String#[]`, `String#index(regex)`, `String#match`, `String#length`
- バイト単位: `String#byteslice`, `String#bytesize`, `String#getbyte`

それぞれの性質:

- `byteslice(start, len)` は O(len) で高速。Arena経由のtext取り出しというホットパスはこれが向く
- 一方、文字インデックスでの`String#[]`はマルチバイト文字を含む場合O(n)になりうる
- 一方、`StringScanner` は内部でバイト位置 (`pos`) を保持しつつ Ruby の Regexp anchor を使えるため、byte 単位のままアンカ付き match ができる

このため:

- **ホットパス（Arena保存・renderer出力）はbyte**
- **Inline::Lexer も byte で進める** (`StringScanner#pos` + `String#byteindex` + binary view)
- **ユーザー向け診断（column）は文字単位**

という構造になる。Lexer が char index を経由しないので、char ↔ byte の取り違えが起きうる箇所が消えている。

#### コーディングルール

- 変数・引数の単位を**名前で明示**する
  - byte: `start_byte`, `end_byte`, `byte_offset`, `byte_index`
  - char: `char_offset`, `start_column`
- inline 側で文字単位が必要になるのは、Flanking の前後 1 文字を取り出す `char_before` / `char_at` だけ。ここだけ byte → char を変換する (ASCII fast path + multibyte 時のみ byteslice)
- マルチバイト文字を含む回帰テストをspecに必ず置き、文字とbyteの混在によるバグを早期検出する（例: `_пристаням_стремятся`, `日本語の*強調*テスト`）

### SourceMap

`SourceMap` は改行位置の配列を持つ。

```ruby
module Mdarena
  class SourceMap
    def initialize(source)
      @source = source
      @line_starts = build_line_starts(source)
    end

    def line_column(byte_offset)
      # @line_startsを二分探索して line / column を返す
    end

    private

    def build_line_starts(source)
      starts = [0]
      pos = 0

      while (idx = source.index("\n", pos))
        starts << idx + 1
        pos = idx + 1
      end

      starts
    end
  end
end
```

### NodeRefでの位置取得

外部APIでは以下のようにする。

```ruby
node.source_span
#=> #<SourceSpan start_byte=10 end_byte=20>
#   start_byte / end_byte は byte offset

node.source_location
#=> { start_line: 3, start_column: 5, end_line: 3, end_column: 15 }
#   line は 1-indexed, column は 0-indexed の **文字単位** (char)
```

`source_location` は毎回計算するとコストが高い可能性があるため、必要時のみ計算する（SourceMapは`Document`側でメモ化される）。

## Textノード

### Textは文字列を持たない

Textノードは文字列を直接持たない。

```text
TEXT:
  source_start = 123
  source_len = 5
```

外部APIで `node.text` が呼ばれたときだけ切り出す。

```ruby
def text(node_id)
  @source.byteslice(@source_start[node_id], @source_len[node_id])
end
```

これにより、parse時に小さいStringを大量生成することを避ける。

### HTML rendererでの扱い

HTML rendererでは、Textノードの文字列を一度Ruby Stringとして切り出すのではなく、可能ならspanを直接escapeして出力する。

```ruby
def render_text(id, out)
  start = @arena.source_start(id)
  len = @arena.source_len(id)
  escape_html_span(@arena.source, start, len, out)
end
```

初期実装では `byteslice` してもよいが、性能が問題になったらspan直接処理にする。

## NodeRef

### 役割

外部APIでは、利用者に整数IDを直接触らせない。

```ruby
doc.root.children.each do |node|
  puts node.type
end
```

ただし、この `node` は実体ではなく、`arena` と `node_id` を持つ軽量wrapperである。

```ruby
module Mdarena
  class NodeRef
    include Enumerable

    attr_reader :document, :node_id

    def initialize(document, node_id)
      @document = document
      @arena = document.arena
      @node_id = node_id
    end

    def type
      @arena.type_name(@node_id)
    end

    def children
      @arena.child_ids(@node_id).map { |id| NodeRef.new(@document, id) }
    end

    def walk(&block)
      return enum_for(:walk) unless block_given?
      yield self
      @arena.child_ids(@node_id).each do |id|
        NodeRef.new(@document, id).walk(&block)
      end
    end
    alias each walk

    def text
      # 子があれば concat, なければ自分の text
    end

    def source_span
      @arena.source_span(@node_id)
    end

    def source_location
      # source_span を SourceMap で line/column へ変換
    end

    def find_all(type)
      walk.select { |n| n.type == type }
    end

    def to_h
      # AST を Hash として export
    end
  end
end
```

### 内部処理では使わない

Renderer、Formatter、InlinePassなど内部のホットパスでは `NodeRef` を作らない。

```ruby
def render_node(id, out)
  case @arena.type(id)
  when NodeType::TEXT
    render_text(id, out)
  when NodeType::PARAGRAPH
    render_paragraph(id, out)
  end
end
```

`NodeRef` は外部API用と割り切る。

## Document

`Document` はArenaとSourceMapを保持し、AST export 系メソッド (`to_h` / `to_mdast` / `to_json`) も提供する。

```ruby
module Mdarena
  class Document
    attr_reader :source, :arena, :root_id

    def initialize(source, arena, root_id, allow_html: false, references: {})
      @source = source
      @arena = arena
      @root_id = root_id
      @allow_html = allow_html
      @references = references
    end

    def root
      NodeRef.new(self, @root_id)
    end

    def walk(&block)
      root.walk(&block)
    end

    def source_map
      @source_map ||= SourceMap.new(@source)
    end

    def diagnostics
      @diagnostics ||= []
    end

    def to_html(standalone: false, title: nil, lang: "en", css: nil)
      # ...
    end

    def to_ast
      root.to_h
    end

    def to_mdast
      # MDAST-compatible Hash
    end

    def to_json(*)
      JSON.pretty_generate(to_mdast)
    end
  end
end
```

外部から扱いやすい AST が必要な場合は `to_h` / `to_mdast` / `to_json` を使う。MDAST 形式は `unifiedjs/mdast` 互換で、エディタ系・lint 系ツールにそのまま渡せる。

## Block Parser

### 方針

Block parserは行指向で実装する。

担当するのは以下である。

- blank line
- paragraph
- ATX heading
- thematic break
- blockquote
- unordered list
- ordered list
- list item
- fenced code block
- indented code block
- table
- front matter
- raw HTML block

Inline構文はここでは処理しない。

### Paragraphの扱い

paragraphは複数行をまとめて、raw inline spanとして保持する。

```markdown
This is *emphasis
continued here*.
```

この段階では `*emphasis...*` は解釈しない。

```text
PARAGRAPH:
  source_start = paragraph_content_start
  source_len = paragraph_content_len
  children = empty
```

後続のInlinePassでchildrenを作る。

### Headingの扱い

```markdown
## Hello *world*
```

Block parserは見出しレベルとinline部分のspanだけを記録する。

```text
HEADING:
  int1 = 2
  source_start = inline_start
  source_len = inline_len
```

### Code blockの扱い

fenced code blockはinline parseしない。

````markdown
```ruby
puts "*not emphasis*"
```
````

Arenaには以下のように保存する。

```text
CODE_BLOCK:
  str1 = "ruby"
  source_start = code_body_start
  source_len = code_body_len
```

### Container stack

blockquoteやlistはネストするため、block parserはcontainer stackを持つ。

```text
open_containers:
  DOCUMENT
  BLOCKQUOTE
  LIST
  LIST_ITEM
```

各行について、

```text
1. 既存containerに継続できるか判定
2. 継続できないcontainerを閉じる
3. 新しいblock開始を判定
4. 現在のleaf blockに行内容を追加
```

という流れで処理する。

## Inline Pass

### 方針

Block parserが作ったArena ASTを走査し、inline対象ノードに対してInlineParserを実行する。

対象ノード:

- PARAGRAPH
- HEADING
- TABLE_CELL
- LINK内のlabel相当部分
- IMAGE内のalt相当部分

対象外ノード:

- CODE_BLOCK
- HTML_BLOCK
- THEMATIC_BREAK
- FRONT_MATTER
- raw block系拡張

### 処理例

```ruby
module Mdarena
  class InlinePass
    INLINE_TARGETS = [NodeType::PARAGRAPH, NodeType::HEADING, NodeType::TABLE_CELL].freeze

    def initialize(document)
      @document = document
      @arena = document.arena
      @lexer = Inline::Lexer.new(@document.source)
      @tokens = Inline::Tokens.new
      @builder = Inline::Builder.new(@arena, @document.source, @document.references,
                                     diagnostics: @document.diagnostics)
    end

    def apply
      visit(@document.root_id)
    end

    private

    def visit(id)
      if INLINE_TARGETS.include?(@arena.type(id))
        @tokens.clear
        start_byte = @arena.source_start(id)
        end_byte = start_byte + @arena.source_len(id)
        @lexer.lex_into(@tokens, start_byte, end_byte)
        @builder.build(id, @tokens)
        return
      end

      child = @arena.raw_first_child_id(id)
      until child == -1
        visit(child)
        child = @arena.raw_next_sibling_id(child)
      end
    end
  end
end
```

`@tokens` / `@lexer` / `@builder` は document 単位で 1 つだけ作り、`@tokens.clear` で内容だけ捨てて使い回す。実装では blockquote / list 継続 prefix を取り除いた literal を持つノードのケースで一時 Lexer / Builder を作る分岐があるが、頻度が低いので省略。本ドキュメントでは設計方針のみ示す。実装詳細はソースを参照。

## Inline Lexer

### 責務

- `@source` (document 全体) の `[start_byte, end_byte)` をスキャンし、token を emit する
- Arena は触らない
- `*` / `_` の delimiter run には flanking 判定 (can_open / can_close) を焼き込んで emit する
- 内部状態は byte offset 1 本。char index は必要時だけ `byteslice` から導く

### Token kind (最小セット)

```text
TEXT             プレーンテキスト span
ENTITY           HTML entity (str1 = decoded literal)
ESCAPED_CHAR     backslash escape (str1 = original char)
LINE_ENDING      改行 (builder で softbreak / hardbreak を判定)
CODE_DELIMITER   ` run (int1 = run length)
DELIM_RUN        * or _ run (char, count, can_open, can_close)
LBRACKET         [
BANG_LBRACKET    ![
RBRACKET         ]
AUTOLINK_URI     <scheme:...>
AUTOLINK_EMAIL   <addr@host>
HTML_INLINE      <tag ...>
```

token は struct を作らず parallel array (`InlineTokens`) に格納する。各 token は `(kind, start_byte, end_byte, int1, int2, int3, str1)` を持つ。

### Token object は作らない

`InlineTokens` は parallel array で、token は `token_id` (Integer) で参照する。Token struct を作らないことで、長い paragraph でも軽量に保つ。

診断や debug 用途で必要な場合のみ、Token Struct を生成する別 API を提供する。

## Inline Builder

### 責務

- `Inline::Tokens` を消費し、Arena に inline node を追加する
- delimiter stack で EMPHASIS / STRONG / STRIKETHROUGH を解決 (CommonMark spec 6.2 + GFM)
- `[label](destination)` / `[label][ref]` / `[label]` の bracket matching
- code span のマッチング (同じ run length の `CODE_DELIMITER` でクローズ)

### コンストラクタ

```ruby
Inline::Builder.new(arena, source, references,
                    track_source: true,
                    diagnostics: nil)
```

- `track_source: false` は blockquote / list 継続 prefix を取り除いた literal を入力にする場合 (`source` が document 全体ではなく再構築済み文字列のとき) に使う。この場合 Arena には source span を記録せず、TEXT は str1 に literal を持つ
- `diagnostics` は `Document#diagnostics` を受け取り、unsafe URL や missing reference を append する

### 処理段階

1. **linear_pass**: token を頭から処理し、code span / link / image / autolink / HTML を解決。emphasis 系の delimiter run は暫定 TEXT ノードとして Arena に追加しつつ、`@delimiter_stack` に push。`[` / `![` / `]` は別途 `@bracket_stack` で管理する
2. **process_emphasis**: `@delimiter_stack` を後方走査して opener / closer をペアリング、EMPHASIS / STRONG / STRIKETHROUGH ノードを構築。リンク内側の delimiter は `finalize_link` 時点で `slice!` して個別に処理する

### CommonMark 互換

旧設計では「完全 CommonMark 互換は目指さない」「曖昧な delimiter run は text 扱い」と書いていたが、現行実装は **delimiter stack アルゴリズム (spec 6.2) を素直に実装**しており、CommonMark v0.31.2 全 example が pass する。

それでも以下は引き続き「pragmatic」な扱い:

- 極端に深いネストは Ruby のスタック / メモリで制限される
- HTML inline / autolink の URL 形式は spec の正規表現に従う

処理できない構文はエラーではなく text に戻す方針は変えない。

### Text coalescing

連続する TEXT は Arena 上で 1 つのノードにまとめる。

- 直前の子が TEXT で、source span が連続しているなら、新ノードを追加せず source_len を伸ばす
- ENTITY / ESCAPED_CHAR は str1 を持つため、merge 時に文字列連結が必要 (現状の `append_text` と同じ思想)

ノード種別は TEXT 1 種類で十分。「source span ベース」と「str1 (literal) ベース」の TEXT は、`str1` が nil かどうかで区別する。

## Renderer

### HTML Renderer

Rendererは内部的に `node_id` で動く。`each_child` (ブロック直 yield) でホットパスから `NodeRef` 生成と Enumerator allocation を避ける。

```ruby
module Mdarena
  module Renderer
    class HTML
      def initialize(document)
        @document = document
        @arena = document.arena
        @out = +""
      end

      def render
        render_children(@document.root_id)
        @out
      end

      private

      def render_node(id)
        case @arena.type(id)
        when NodeType::PARAGRAPH
          @out << "<p>"
          render_children(id)
          @out << "</p>\n"
        when NodeType::HEADING
          level = @arena.int1(id)
          @out << "<h#{level}>"
          render_children(id)
          @out << "</h#{level}>\n"
        when NodeType::TEXT
          render_text(id)
        when NodeType::CODE_BLOCK
          render_code_block(id)
        end
      end

      def render_children(id)
        @arena.each_child(id) { |child_id| render_node(child_id) }
      end
    end
  end
end
```

### Safe HTML by default

raw HTMLはデフォルトで無効にする。

```ruby
Mdarena.render_html(source, allow_html: false)
```

`allow_html: false` の場合:

- HTML blockはescapeする
- HTML inlineもescapeする
- link destinationは危険なschemeを抑止する

### HTML fast path

将来的には、完全なArena ASTを作らずにHTMLを出すfast pathを追加する。

```ruby
Mdarena.render_html(source)
```

内部では、

```text
BlockParser event
  -> InlineParser event
    -> HTMLRenderer
```

にする。

ただし、初期実装ではArena AST経由でよい。

## Transformer

### 初期はread-only AST

Arenaはmutation可能だが、最初から自由なmutable AST APIを公開しない。

初期API:

```ruby
doc.root.walk
doc.root.children
node.type
node.text
node.source_span
```

### transformは新しいDocumentを作る

in-place mutationは難しいため、最初はbuilder方式にする。

```ruby
new_doc = doc.transform do |builder, node|
  case node.type
  when :heading
    builder.heading(node.level + 1) do
      builder.copy_children(node)
    end
  else
    builder.copy(node)
  end
end
```

この方式ならArena ASTと相性がよい。

### in-place mutationは後回し

以下は後で追加する。

```ruby
node.append_child(...)
node.insert_before(...)
node.replace_with(...)
node.delete
```

実装する場合は、以下のリンクを正しく更新する必要がある。

```text
parent
first_child
last_child
next_sibling
prev_sibling
```

## Formatter (未実装)

FormatterはArena ASTをMarkdownへ戻す。現状は未実装。

用途 (構想):

- 曖昧なMarkdownを正規化する
- processorが扱いやすいMarkdownへ整形する
- CommonMark完全互換を目指さない代わりに、安定した出力形式を提供する

例:

```ruby
Mdarena.format(source)  # 構想
```

方針:

- headingはATX headingへ統一
- fenced code blockを使う
- list indentationを統一
- tableを整形する
- emphasisは `*em*`、strongは `**strong**` に統一
- raw HTMLは設定に応じて保持またはescapeする

## Diagnostics

### Diagnostic object

```ruby
class Diagnostic
  attr_reader :severity, :rule, :message, :source_span
end
```

`Document#diagnostics` が `Diagnostic` の Array を返す。表示時に `source_span` を `SourceMap` 経由で line/column へ変換できる。

### 現状で報告される rule

- `unsafe_url` — `javascript:` などの危険スキームをブロックしたとき
- `missing_reference` — `[text][ref]` で参照先 reference definition が未定義のとき

### 用途 (構想)

- heading level skip
- empty link destination
- missing image alt
- unsafe HTML

## Performance方針

### 避けること

- Token objectを全トークン分作らない
- Text nodeごとにStringを切り出さない
- nodeごとにHashを作らない
- 内部走査でNodeRefを作らない
- Regexpを細かく何度も呼ばない
- rendererで `out += ...` を使わない

### 使うもの

- byte offset
- `String#getbyte`
- `String#byteslice` は必要時のみ
- `String#<<` によるappend
- node_idによる内部処理
- parallel arrays

### ベンチ対象

```text
bench/fixtures/
  readme.md
  article.md
  long_doc.md
  inline_heavy.md
  table_heavy.md
  code_heavy.md
```

比較対象:

- Markly
- commonmarker
- kramdown
- 自作pure Ruby backend

測定対象:

- parse only
- render html
- allocated objects
- memory usage
- GC time

## API案

### Parse

```ruby
doc = Mdarena.parse(source)
```

### Render

```ruby
html = Mdarena.render_html(source)
```

### AST traversal

```ruby
doc.root.children.each do |node|
  puts node.type
  puts node.source_span
end
```

### Walk

```ruby
doc.root.walk do |node|
  puts "#{node.type}: #{node.source_span}"
end
```

### Find

```ruby
headings = doc.root.find_all(:heading)
```

### Diagnostics

```ruby
doc.diagnostics.each do |diagnostic|
  puts diagnostic.message
end
```

### Format (構想)

```ruby
formatted = Mdarena.format(source)  # 未実装
```

## 実装フェーズ

### Phase 1: 素直なプロトタイプ — 完了

- 行指向block parser
- 最小inline parser
- ノード種別とAST形状を固定

### Phase 2: Arena AST化 — 完了

- ノードを `node_id` ベースにする
- parallel arraysへ移行
- Textをsource span化
- NodeRef外部APIを追加

### Phase 3: Renderer最適化 — 完了

- HTML rendererを `node_id` ベースにする
- Text spanを直接escapeする
- safe-by-default の HTML escape / URL scheme チェックを実装

### Phase 4: Inline Lexer / Builder への再構成 — 完了

- `InlineParser` / `InlineScanner` を削除し、`Inline::Lexer` + `Inline::Builder` の二段構成へ移行済み
- substring 連鎖と base_offset 計算を排除し、Lexer は document 全体の絶対 byte offset で動く (`StringScanner#pos` + `String#byteindex` on binary view)
- Builder は delimiter stack (CommonMark spec 6.2) で emphasis を解決
- GFM strikethrough (`~~`) も DELIM_RUN の char に `~` を追加するだけで対応
- inline-heavy benchmark で最大 30x の速度改善

### Phase 5: HTML fast path — 未着手

- AST構築なしでHTMLを出すevent rendererを検討
- `Mdarena.render_html` の高速化を狙う (現状は AST 経由)
- `Mdarena.parse` はArena ASTを返す

## まとめ

本設計では、Markdown ASTをRubyオブジェクトツリーとして表現せず、内部的にはArenaに格納された数値IDの集合として扱う。

```text
内部:
  node_id
  parallel arrays
  source span
  no Token object
  no Node object on hot path

外部:
  Document
  NodeRef
  Enumerator
  source_span
  diagnostics
```

これにより、RubyらしいAST APIを提供しつつ、parse/render時のallocationを抑える。

Markly/cmarkと完全に同等の速度をpure Rubyだけで達成するのは難しいが、この設計なら少なくとも以下を狙える。

- kramdown的なpure Ruby processorより現代的な低allocation設計
- 通常文書で体感上遜色ない速度
- 将来的なnative fast pathの追加
- AST/diagnostics/formatter/transformerを備えたMarkdown document processor

最終的な位置づけは以下である。

```text
A pragmatic Markdown document processor for Ruby,
with a low-allocation arena AST, source spans,
and safe HTML rendering.
```
