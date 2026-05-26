# Markdown Processor: Arena AST 設計案

## 目的

RubyでMarkdown processorを実装するにあたり、通常のRubyオブジェクトツリーとしてASTを構築すると、ノード数・文字列断片・Tokenオブジェクトが大量に生成され、Markly/cmark系と比べて速度・メモリ使用量で大きく不利になりやすい。

そのため、本設計では以下を目標とする。

- 内部ASTはRubyオブジェクトツリーではなく、数値IDベースのArena構造で保持する
- Textノードは文字列を複製せず、元ソース文字列へのspanとして保持する
- 内部処理ではNodeオブジェクトを作らず、`node_id` の整数だけを取り回す
- 外部APIでは必要に応じて `NodeRef` wrapper を返す
- `parse` と `render_html` の経路を分け、HTML生成だけなら完全AST構築を避けられる余地を残す
- 将来的にLexerKit backendやnative storageへ差し替え可能にする

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
InlineLexer / InlineParser
  ↓
Arena AST with inline nodes
  ↓
Renderer / Formatter / Transformer
```

ただし、HTML生成だけを高速に行う場合は、将来的に以下の経路も用意する。

```text
Source
  ↓
BlockParser events
  ↓
InlineParser events
  ↓
HTMLRenderer
```

つまり、APIとしては次の2系統を持つ。

```ruby
doc = Markdown.parse(source)        # Arena ASTを構築する
html = Markdown.render_html(source) # 速度重視。AST構築を省略できる余地を持つ
```

## 全体構成

```text
lib/markdown/
  source.rb
  source_map.rb

  arena.rb
  node_ref.rb
  node_type.rb

  block_parser.rb
  inline_pass.rb
  inline/
    lexer.rb        # 文字スキャン + token emit
    tokens.rb       # InlineTokens (parallel array storage)
    token_kind.rb   # token kind 定数
    builder.rb      # token 消費 + delimiter stack + arena への node 追加
    flanking.rb     # left/right flanking 判定ヘルパー

  renderer/html.rb
  formatter.rb
  transformer.rb

  config.rb
```

インライン処理は **Lexer + Builder の二段構成** にする (詳細は `inline-redesign.md`)。

- `InlineLexer`: source の文字スキャンと token emit。Arena を触らない
- `InlineTokens`: token stream の軽量ストレージ (parallel array)
- `InlineBuilder`: token stream を消費し、delimiter stack で emphasis を解決して Arena に node を追加
- 二段に分けることで、CommonMark spec の delimiter stack アルゴリズムを素直に実装でき、Phase 9-B (full delimiter-run emphasis) を自然に統合できる

将来的にLexerKitを使う場合は、Lexer を差し替える。

```text
lib/markdown/inline/lexer/ruby.rb
lib/markdown/inline/lexer/lexer_kit.rb
```

Builder は token stream のインターフェイスにだけ依存し、Lexer の実装を選ばない。

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
module Markdown
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

      if @first_child[parent_id] == -1
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
module Markdown
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
    AUTOLINK = 108
    HTML_INLINE = 109
    ENTITY = 110
    STRIKETHROUGH = 111
  end
end
```

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

markdastは内部で文字インデックスとバイトオフセットを意図的に使い分ける。
両者を取り違えるとマルチバイト文字（CJK / Cyrillicなど）でHTMLが壊れる、source spanがずれる、といった事故が発生するため、レイヤーごとに「どちらの単位を使うか」を固定する。

#### レイヤー別の単位

| レイヤー | 単位 | 理由 |
|----------|------|------|
| `Arena#source_start` / `source_len` | byte | `String#byteslice` でO(len)に取り出せる |
| `SourceSpan#start_byte` / `end_byte` | byte | 内部単位をそのまま公開（名前で明示） |
| `InlineScanner#index` | char | regex match / `String#[]` / scan_text で使う |
| `InlineScanner#byte_index` | byte | Arena の `source_start` 計算に使う |
| `SourceMap#line_column` 入力 | byte | byte offset から line/column を逆引き |
| `node.source_location` の column | char | 編集系ツール・診断表示はユーザーにとって文字単位の方が自然 |

#### なぜこの分け方になるか

Rubyの`String`には2系統のAPIがある。

- 文字単位: `String#[]`, `String#index(regex)`, `String#match`, `String#length`
- バイト単位: `String#byteslice`, `String#bytesize`, `String#getbyte`

それぞれの性質:

- `byteslice(start, len)` は O(len) で高速。Arena経由のtext取り出しというホットパスはこれが向く
- 一方、文字インデックスでの`String#[]`はマルチバイト文字を含む場合O(n)になりうる
- scanner側はregexで `\G`-anchored match を行うため、文字インデックスで進めたい

このため:

- **ホットパス（Arena保存・renderer出力）はbyte**
- **scannerは文字インデックスで進め、Arena保存時にbyte offsetへ変換**
- **ユーザー向け診断（column）は文字単位**

という三層になる。

#### コーディングルール

- 変数・引数の単位を**名前で明示**する
  - byte: `start_byte`, `end_byte`, `byte_offset`, `byte_index`
  - char: `start_index`, `char_offset`, `index`
- 単位の変換はscanner経由でしか行わない（`@scanner.byte_index` / `@scanner.index`）
- マルチバイト文字を含む回帰テストをspecに必ず置き、文字とbyteの混在によるバグを早期検出する（例: `_пристаням_стремятся`, `日本語の*強調*テスト`）

### SourceMap

`SourceMap` は改行位置の配列を持つ。

```ruby
module Markdown
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
module Markdown
  class NodeRef
    def initialize(document, node_id)
      @document = document
      @arena = document.arena
      @node_id = node_id
    end

    attr_reader :node_id

    def type
      @arena.type_name(@node_id)
    end

    def children
      Enumerator.new do |y|
        id = @arena.first_child(@node_id)
        until id == -1
          y << NodeRef.new(@document, id)
          id = @arena.next_sibling(id)
        end
      end
    end

    def text
      @arena.text(@node_id)
    end

    def source_span
      @arena.source_span(@node_id)
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

`Document` はArenaとSourceMapを保持する。

```ruby
module Markdown
  class Document
    attr_reader :arena

    def initialize(source, arena, root_id)
      @source = source
      @arena = arena
      @root_id = root_id
      @source_map = nil
    end

    def root
      NodeRef.new(self, @root_id)
    end

    def source_map
      @source_map ||= SourceMap.new(@source)
    end

    def to_html
      Renderer::HTML.new(self).render
    end
  end
end
```

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
module Markdown
  class InlinePass
    INLINE_TARGETS = [NodeType::PARAGRAPH, NodeType::HEADING, NodeType::TABLE_CELL].freeze

    def initialize(document)
      @document = document
      @arena = document.arena
      @lexer = Inline::Lexer.new(@document.source)
    end

    def apply
      visit(@document.root_id)
    end

    private

    def visit(id)
      if INLINE_TARGETS.include?(@arena.type(id))
        start_byte = @arena.source_start(id)
        end_byte = start_byte + @arena.source_len(id)
        tokens = @lexer.lex(start_byte, end_byte)
        Inline::Builder.new(@arena, @document.source, @document.references).build(id, tokens)
        return
      end

      child = @arena.first_child(id)
      until child == -1
        visit(child)
        child = @arena.next_sibling(child)
      end
    end
  end
end
```

二段構成の詳細仕様は `inline-redesign.md` を参照。本ドキュメントでは設計方針のみ示す。

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

### LexerKit backend

将来的に LexerKit backend を追加する。Lexer の実装は差し替え可能だが、`InlineTokens` 互換 (または同等の token iterator) を返すインターフェイスに合わせる。

```text
Markdast::Inline::Lexer       # pure Ruby
Markdast::Inline::Lexer::LexerKit  # native, optional
```

Builder は `InlineTokens` の API にだけ依存し、Lexer の実装を選ばない。

### Token object は作らない

`InlineTokens` は parallel array で、token は `token_id` (Integer) で参照する。Token struct を作らないことで、長い paragraph でも軽量に保つ。

診断や debug 用途で必要な場合のみ、Token Struct を生成する別 API を提供する。

## Inline Builder

### 責務

- `InlineTokens` を消費し、Arena に inline node を追加する
- delimiter stack で emphasis / strong を解決 (CommonMark spec 6.2)
- `[label](destination)` / `[label][ref]` の bracket matching
- code span のマッチング (同じ run length の `CODE_DELIMITER` でクローズ)

### 処理段階

1. **linear pass**: token を頭から処理し、code span / link / image / autolink / HTML を解決。emphasis 系の delimiter run は暫定 TEXT ノードとして Arena に追加しつつ、delimiter stack に積む
2. **process_emphasis**: delimiter stack を後方走査して opener / closer をペアリング、EMPHASIS / STRONG ノードを構築

### CommonMark 互換

旧設計では「完全 CommonMark 互換は目指さない」「曖昧な delimiter run は text 扱い」と書いていたが、新設計では **delimiter stack アルゴリズム (spec 6.2) を素直に実装する**ことで、ヒューリスティックなく多くの edge case をカバーする。

それでも以下は引き続き「pragmatic」な扱いで OK:

- 極端に深いネスト
- 仕様の細部に依存するレアケース
- HTML inline / autolink の細かい URL 形式

処理できない構文はエラーではなく text に戻す方針は変えない。

### Text coalescing

連続する TEXT は Arena 上で 1 つのノードにまとめる。

- 直前の子が TEXT で、source span が連続しているなら、新ノードを追加せず source_len を伸ばす
- ENTITY / ESCAPED_CHAR は str1 を持つため、merge 時に文字列連結が必要 (現状の `append_text` と同じ思想)

ノード種別は TEXT 1 種類で十分。「source span ベース」と「str1 (literal) ベース」の TEXT は、`str1` が nil かどうかで区別する。

## Renderer

### HTML Renderer

Rendererは内部的に `node_id` で動く。

```ruby
module Markdown
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
        child = @arena.first_child(id)
        until child == -1
          render_node(child)
          child = @arena.next_sibling(child)
        end
      end
    end
  end
end
```

### Safe HTML by default

raw HTMLはデフォルトで無効にする。

```ruby
Markdown.render_html(source, allow_html: false)
```

`allow_html: false` の場合:

- HTML blockはescapeする
- HTML inlineもescapeする
- link destinationは危険なschemeを抑止する

### HTML fast path

将来的には、完全なArena ASTを作らずにHTMLを出すfast pathを追加する。

```ruby
Markdown.render_html(source)
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

## Formatter

FormatterはArena ASTをMarkdownへ戻す。

用途:

- 曖昧なMarkdownを正規化する
- processorが扱いやすいMarkdownへ整形する
- CommonMark完全互換を目指さない代わりに、安定した出力形式を提供する

例:

```ruby
Markdown.format(source)
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

診断はsource spanを持つ。

```ruby
Diagnostic = Data.define(
  :severity,
  :message,
  :start_byte,
  :end_byte,
  :rule
)
```

表示時にSourceMapでline/columnへ変換する。

```ruby
diagnostic.location
#=> line/column
```

### 用途

- heading level skip
- empty link destination
- missing image alt
- unsafe HTML
- unsafe URL scheme
- unmatched emphasis marker
- unsupported syntax
- deprecated extension

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
- optional LexerKit backend

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
- 自作LexerKit backend

測定対象:

- parse only
- render html
- allocated objects
- memory usage
- GC time

## API案

### Parse

```ruby
doc = Markdown.parse(source)
```

### Render

```ruby
html = Markdown.render_html(source)
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

### Format

```ruby
formatted = Markdown.format(source)
```

## 実装フェーズ

### Phase 1: 素直なプロトタイプ

- 行指向block parser
- 最小inline parser
- 普通のRubyオブジェクトASTでもよい
- ノード種別とAST形状を固める

目的は仕様確認であり、速度はまだ追わない。

### Phase 2: Arena AST化

- ノードを `node_id` ベースにする
- parallel arraysへ移行
- Textをsource span化
- NodeRef外部APIを追加

### Phase 3: Renderer最適化

- HTML rendererを `node_id` ベースにする
- Text spanを直接escapeする
- allocationを測定して削減する

### Phase 4: Inline Lexer / Builder への再構成

- `InlineParser` / `InlineScanner` を廃止し、`Inline::Lexer` + `Inline::Builder` の二段構成に置き換える
- substring 連鎖と base_offset 計算を排除し、Lexer は document 全体の絶対 byte offset で動く
- Builder は delimiter stack (CommonMark spec 6.2) で emphasis を解決
- 詳細は `inline-redesign.md` を参照
- inline-heavy benchmark で旧構造との比較を取る

### Phase 5: LexerKit backend

- `InlineTokens` 互換のインターフェイスを Lexer 側で固定
- LexerKit stream backend を追加
- pure Ruby backend と比較する
- optional dependency にするか標準依存にするか判断する

### Phase 6: HTML fast path

- AST構築なしでHTMLを出すevent rendererを検討
- `Markdown.render_html` の高速化を狙う
- `Markdown.parse` はArena ASTを返す

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
- LexerKit backendによるinline lexing高速化
- 将来的なnative fast pathの追加
- AST/diagnostics/formatter/transformerを備えたMarkdown document processor

最終的な位置づけは以下である。

```text
A pragmatic Markdown document processor for Ruby,
with a low-allocation arena AST, source spans,
safe HTML rendering, and optional LexerKit acceleration.
```
