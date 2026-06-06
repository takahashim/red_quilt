# How to use the Arena class

`RedQuilt::Arena` is the low-level storage class that holds the actual AST of
RedQuilt. This document describes its API and assumptions for people who touch
the Arena directly: block parsers, inline builders, renderers, custom
transformers, and any other code under `lib/red_quilt`.

> If you only need to work with the AST as an external API, the standard path is
> to go through `RedQuilt::Document` and `RedQuilt::NodeRef`. The Arena is a more
> internal layer; it is the very data structure that `NodeRef` is built on.

---

## 0. A quick example

The code below works if you copy and paste it as is. It should give you a feel
for how the Arena "builds a tree from a source string using various IDs".

```ruby
require "red_quilt"

source = "Hello *world*"
arena = RedQuilt::Arena.new(source)

# (a) Create nodes. The return value is a node id (Integer).
para_id  = arena.add_node(RedQuilt::NodeType::PARAGRAPH,
                          source_start: 0, source_len: source.bytesize)
text_id  = arena.add_node(RedQuilt::NodeType::TEXT,
                          source_start: 0, source_len: 6)   # "Hello "
em_id    = arena.add_node(RedQuilt::NodeType::EMPHASIS,
                          source_start: 6, source_len: 7)   # "*world*"
inner_id = arena.add_node(RedQuilt::NodeType::TEXT,
                          source_start: 7, source_len: 5)   # "world"

# (b) Build parent/child relationships
arena.append_child(para_id, text_id)
arena.append_child(para_id, em_id)
arena.append_child(em_id,   inner_id)

# (c) Read content back out
puts "type:    #{arena.type_name(para_id)}"
puts "text:    #{arena.text(text_id).inspect}"
puts "inner:   #{arena.text(inner_id).inspect}"
puts "span:    #{arena.source_span(em_id).inspect}"

# (d) Iterate over children (block form, no Enumerator)
puts "children of paragraph:"
arena.each_child(para_id) do |child_id|
  puts "  #{arena.type_name(child_id)}: #{arena.text(child_id).inspect}"
end
```

The output looks like this:

```
type:    paragraph
text:    "Hello "
inner:   "world"
span:    #<RedQuilt::SourceSpan:0x... @start_byte=6, @end_byte=13>
children of paragraph:
  text: "Hello "
  emphasis: "*world*"
```

The AST that this sample builds looks like this:

```
PARAGRAPH    [0, 13)   "Hello *world*"
├─ TEXT      [0, 6)    "Hello "
└─ EMPHASIS  [6, 13)   "*world*"
   └─ TEXT   [7, 12)   "world"
```

The key points when working with the Arena are:

- `add_node` returns a node ID (Integer). Every later API call uses this ID as
  the key.
- `source_start` / `source_len` specify a range over the original source string
  in bytes, not characters. The Arena does not keep a copy of the string itself.
- `text(id)` returns str1 if it exists; otherwise it byteslices `source`.
- `each_child(id)` is the basic traversal API and is used on the hot path.

Keep these in mind, and the later sections will read as "what does this API
actually guarantee, and how should I use it?".

---

## 1. Design highlights

The Arena represents the AST not as a "tree of objects" but as a
[parallel array](https://en.wikipedia.org/wiki/Parallel_array).

- Nodes are identified by an integer ID (`node_id`).
- The attributes for each ID (parent / source span / payload) are kept as
  columns in separate Arrays.
- Adding a node is just an append to the end of each Array; no new Ruby object is
  created at all.

As a result, the Arena has the following properties:

- On the hot path you only pass around Integers (IDs).
- Memory locality is good and GC pressure is low.
- Nodes can be treated as "lightweight" values, which makes it easy to inline the
  Renderer and Builder.

#### List of columns

| Column | Purpose |
|------|------|
| `@type` | NodeType (an Integer constant) |
| `@parent` / `@first_child` / `@last_child` / `@next_sibling` / `@prev_sibling` | Parent / child / sibling links. The value is a node id (`NO_NODE` means "none"). |
| `@source_start` / `@source_len` | Byte range within the document source. `source_start < 0` means "no span". |
| `@int1` / `@int2` / `@int3` | Integer slots whose meaning depends on the NodeType (default `0`). |
| `@str1` / `@str2` | String slots whose meaning depends on the NodeType (default `nil`). |

---

## 2. Invariants

These assumptions always hold when you work with the Arena.

1. Node IDs increase monotonically.
   The ID handed out by `add_node` starts at `@type.length` and increases by 1
   each time you add a node. IDs are never reused.
2. Detached nodes stay in the columns.
   `detach` only resets the parent and sibling links to `NO_NODE`; the column
   record itself stays in the arena. A later `add_node` never reuses that slot.
   This is a deliberate choice that keeps allocation simple.
3. Treat `@source` as immutable.
   You must not rewrite the source after the Arena is built. `source_start` /
   `source_len` point directly at byte ranges, so if the source changes, the
   return values of `text` / `source_span` break.
4. `NO_NODE` = -1.
   This is the sentinel meaning "no parent or sibling exists". You can reference
   it as the `Arena::NO_NODE` constant.
5. `source_start < 0` means "no span".
   In this case the content of a leaf node is often held as a literal in `@str1`
   (for example, a paragraph after a blockquote is removed, or a TEXT node after
   entity decoding). However, some NodeTypes, like container inlines, have no
   span and also do not use `str1`; they build their content from child nodes.

---

## 3. API layers

The public methods of the Arena are easier to understand if you read them in
these three layers.

### 3.1 Structure mutation (mutators)

APIs for building and editing the tree. They assume you pass a valid id and do
minimal safety checking.

| Method | Summary |
|----------|------|
| `add_node(type, **fields)` | Append a new node at the end and return its ID. It starts detached. |
| `append_child(parent_id, child_id)` | Append to the end of the parent's child list. |
| `insert_before(parent_id, ref_id, new_id)` | Insert immediately before `ref_id`. |
| `detach(child_id)` | Detach from the parent. The node itself remains. |
| `reparent(new_parent_id, first_id, last_id)` | Move the sibling range `first_id..last_id` to a new parent. |
| `update_span(id, start_byte, end_byte)` | Reset the source span. |
| `update_str1(id, value)` / `update_int3(id, value)` | Overwrite an individual slot. |

### 3.2 Structure access (raw id accessors)

These return the raw column value, which may be `NO_NODE`. The naming convention
`raw_X_id` means "the return value is a node id and may be -1 (`NO_NODE`)".

| Method | Return value |
|----------|--------|
| `raw_parent_id(id)` | Parent id, or `NO_NODE`. |
| `raw_first_child_id(id)` / `raw_last_child_id(id)` | Child id, or `NO_NODE`. |
| `raw_next_sibling_id(id)` / `raw_prev_sibling_id(id)` | Sibling id, or `NO_NODE`. |

### 3.3 Payload access (column accessors)

These return each column as raw data. You should read from the return type
whether a sentinel can come back.

| Method | Return value |
|----------|--------|
| `type(id)` | NodeType constant (Integer). |
| `type_name(id)` | Symbol (for example, `:paragraph`). |
| `source_start(id)` / `source_len(id)` | Byte offset / byte length. `source_start < 0` means no span. |
| `int1(id)` / `int2(id)` / `int3(id)` | Integer (default 0). |
| `str1(id)` / `str2(id)` | String or `nil`. |

### 3.4 Semantic accessors

These interpret the low-level columns and return an "easy to use" value. They can
return `nil` to explicitly express "none".

| Method | Return value |
|----------|--------|
| `source_span(id)` | `SourceSpan`, or `nil` if there is no span. |
| `text(id)` | str1 if present; otherwise `source.byteslice(...)`. `nil` if neither exists. |

### 3.5 Traversal

| Method | Purpose |
|----------|------|
| `each_child(id) { |child_id| ... }` | Block form. Recommended on the hot path (no Enumerator). |
| `child_ids(id)` | Returns an `Enumerator`, for chaining `map` / `select`, etc. |

---

## 4. Slot usage per NodeType

Which int / str slots each NodeType uses is fixed by convention. The current
conventions are below.

#### Block nodes

| NodeType | int1 | int2 | int3 | str1 | str2 |
|----------|------|------|------|------|------|
| `DOCUMENT` | - | - | - | - | - |
| `PARAGRAPH` | - | - | - | A joined literal when needed (when transformed, or when leading indent is removed, etc.) | - |
| `HEADING` | level (1-6) | - | - | An inline literal when needed (when transformed, setext heading, etc.) | - |
| `THEMATIC_BREAK` | - | - | - | - | - |
| `BLOCKQUOTE` | - | - | - | - | - |
| `LIST` | ordered? (0/1) | start_number | tight? (1=tight) | marker (`-`/`*`/`+`/`.`/`)`) | - |
| `LIST_ITEM` | - | - | - | - | - |
| `CODE_BLOCK` | - | - | - | code content (literal) | info string (fenced only) |
| `HTML_BLOCK` | - | - | - | HTML content (literal) | - |
| `TABLE` | - | - | - | - | - |
| `TABLE_ROW` | header? (1/0) | - | - | - | - |
| `TABLE_CELL` | header? (1/0) | - | - | stripped cell text | - |
| `FOOTNOTE_DEFINITION` | - | - | - | normalized label | - |
| `FOOTNOTES_SECTION` | - | - | - | - | - |

#### Inline nodes

| NodeType | int1 | int2 | int3 | str1 | str2 |
|----------|------|------|------|------|------|
| `TEXT` | - | - | - | literal (after entity decode, etc.) or `nil` (span-based) | - |
| `SOFTBREAK` / `HARDBREAK` | - | - | - | `"\n"` | - |
| `EMPHASIS` / `STRONG` / `STRIKETHROUGH` | - | - | - | - | - |
| `CODE_SPAN` | - | - | - | normalized content (literal) | - |
| `LINK` | - | - | - | sanitized destination | title (or `nil`) |
| `IMAGE` | - | - | - | sanitized destination | title (or `nil`) |
| `HTML_INLINE` | - | - | - | matched HTML literal | - |
| `FOOTNOTE_REFERENCE` | footnote number | occurrence count (the Nth one for the same label) | - | normalized label | - |

> `-` means "not used" (left at the default `0` / `nil`).

> Footnotes are only generated when `footnotes: true`. `FOOTNOTES_SECTION` is
> placed as the last child directly under the root (span-less,
> `source_start: -1`), and holds the referenced `FOOTNOTE_DEFINITION`s in
> first-reference order. The number of backrefs is computed at render time from
> the footnote number and label.

#### Source span conventions

- `source_start` / `source_len`: bytes of the original document (absolute byte
  offset).
- `source_start < 0`: no span. A leaf node often holds its content as a literal
  in `str1`, but a container inline may have only child nodes.
- The span of a block node serves two different purposes depending on use.
    - For inline targets (paragraph / heading / table cell), the span is also the
      byte range that the InlinePass tokenizes, so it points at the inline body
      with `#` or other prefixes removed.
    - For everything else (list / blockquote / table / code / html block, etc.)
      the span is not used for tokenizing and only carries
      structural / line-level position information.

---

## 5. Typical usage

### 5.1 Create an Arena and build a small AST

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

### 5.2 Loop over siblings (hot path)

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

If you want to chain over an `Enumerator` (for example in NodeRef), do this:

```ruby
arena.child_ids(para_id).map { |id| arena.type_name(id) }
# => [:text, :emphasis]
```

### 5.3 Move a node to a different parent

`reparent` is an API that replaces the children of the destination node, so the
destination should normally be a newly created empty node.

```ruby
# Move the children of `em_id` under a new strong_id
strong_id = arena.add_node(RedQuilt::NodeType::STRONG,
                           source_start: arena.source_start(em_id),
                           source_len: arena.source_len(em_id))
arena.insert_before(arena.raw_parent_id(em_id), em_id, strong_id)

first = arena.raw_first_child_id(em_id)
last  = arena.raw_last_child_id(em_id)
arena.reparent(strong_id, first, last) if first != RedQuilt::Arena::NO_NODE

# Detach em_id while it is empty. strong_id stays where em_id was.
arena.detach(em_id)
```

### 5.4 Replace a node

```ruby
# Replace em_id with strong_id (keep the contents)
strong_id = arena.add_node(RedQuilt::NodeType::STRONG,
                            source_start: arena.source_start(em_id),
                            source_len: arena.source_len(em_id))
arena.insert_before(arena.raw_parent_id(em_id), em_id, strong_id)

first = arena.raw_first_child_id(em_id)
last  = arena.raw_last_child_id(em_id)
arena.reparent(strong_id, first, last) if first != RedQuilt::Arena::NO_NODE

arena.detach(em_id)
```

### 5.5 Update column values directly

```ruby
# A heading's level is in int1, but there is no dedicated setter for it,
# so add one if needed. Currently only str1 / int3 / span have public setters:
arena.update_str1(text_id, "Hello, world!")
arena.update_int3(list_id, 1) # make it tight
arena.update_span(text_id, 0, 12)
```

Note that there are currently no setters for int1 / int2 / str2. The plan is to
add `update_int1` and similar when the need arises.

---

## 6. Performance notes

#### Use `each_child` on the hot path

Yielding directly to a block avoids Enumerator allocation. `child_ids` is for the
external API.

#### `text(id)` prefers str1

To avoid an extra `byteslice`, content that can be reconstructed from the source
should leave `str1` as `nil`. However, use `str1` in cases where a literal is
required for correctness: TEXT after entity decode, code/html literals, table
cells, transformed/literal inline targets, and so on.

#### `source_span(id)` allocates a `SourceSpan` every time

If you use it on the hot path, it is better to read `source_start` /
`source_len` directly.

#### Detached nodes cannot be reclaimed

Repeatedly detaching many nodes keeps growing the arena's columns. The scale is
fine within parsing a single document, but it is not suited to a long-lived
arena.

---

## 7. Pitfalls

#### When you use a `raw_*_id` return value directly as a foreign key

Do not forget the `NO_NODE` (-1) check. Using it with `Array#[-1]` reads the last
element of the array and corrupts the tree.

#### Preconditions of `reparent`

You must be able to reach `last_id` by following `next_sibling` from `first_id`.
Passing nodes with a different parent, or a `last_id` that is unreachable behind
`first_id`, can cause an infinite loop (the builder actually hit this in the
past).

#### The meaning of `source_start < 0`

It is "literal mode, with position information discarded". The user-facing APIs
(`SourceMap`, `node.source_location`, etc.) treat it as having no span. Do not
forget this and get confused in the debugger by "there is no position
information".

#### Do not change `@source` afterward

If you do, the return values of `text` / `source_span` break silently.
