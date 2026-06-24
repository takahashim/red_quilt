# frozen_string_literal: true

module RedQuilt
  class BlockParser
    def initialize(arena, footnotes: nil)
      @arena = arena
      @lines = build_lines(arena.source)
      @references = {}
      @footnotes = footnotes
      @diagnostics = []
      # Cached collaborator parsers — created once and reused for every
      # block of the corresponding type (including nested ones) so the
      # dispatch path stays allocation-free.
      @list_parser = List::Parser.new(self)
      @blockquote_parser = Blockquote::Parser.new(self)
      @footnote_parser = FootnoteDefinition::Parser.new(self)
      @code_block_parser = CodeBlock::Parser.new(self)
      @html_block_parser = HtmlBlock::Parser.new(self)
      @table_parser = Table::Parser.new(self)
    end

    attr_reader :references, :arena, :diagnostics

    def parse
      @root_id = @arena.add_node(NodeType::DOCUMENT, source_start: 0, source_len: @arena.source.bytesize)
      parse_lines(@root_id, @lines, transformed: false)
      @footnote_parser.move_section_to_end(@root_id) if @footnotes
      @root_id
    end

    # parse_lines returns true if it encountered a blank line BETWEEN
    # two block-level constructs at this scope. parse_list uses that to
    # decide an item's looseness — the spec says an item is loose when
    # it "directly contains two block-level elements with a blank line
    # between them", and ref-defs / fence openers that don't emit an
    # arena child still count as block-level elements.
    #
    # `seen_block` guards against treating the empty marker line of a
    # list item (e.g. `-` alone) as a blank "between" anything: the
    # blank only counts after at least one real block has been emitted.
    def parse_lines(parent_id, lines, transformed:)
      saw_blank = false
      seen_block = false
      blank_then_block = false
      index = 0
      while index < lines.length
        line = lines[index]
        if line.blank
          saw_blank = true if seen_block
          index += 1
          next
        end

        blank_then_block = true if saw_blank
        saw_blank = false
        seen_block = true

        content = line.content
        if paragraph_only_line?(content)
          # Fast path: nothing in this line can possibly start a
          # different block, so skip the eight predicate checks below.
          index = parse_paragraph(parent_id, lines, index, transformed)
          next
        end

        if (fence = CodeBlock.fenced_start(content))
          index = @code_block_parser.parse_fenced(parent_id, lines, index, fence)
        elsif (heading = atx_heading(content))
          append_heading(parent_id, line, heading, transformed)
          index += 1
        elsif thematic_break?(content)
          @arena.append_child(parent_id, @arena.add_node(NodeType::THEMATIC_BREAK, source_start: line.start_byte, source_len: line.span_len))
          index += 1
        elsif @footnotes && (footnote = FootnoteDefinition.match(content))
          index = @footnote_parser.parse(lines, index, footnote, @footnotes, @root_id)
        elsif (reference = ReferenceDefinition.consume(lines, index))
          store_reference(reference[:reference], reference[:source_span])
          index += reference[:consumed]
        elsif Table.start?(lines, index)
          index = @table_parser.parse(parent_id, lines, index)
        elsif HtmlBlock.start?(content)
          index = @html_block_parser.parse(parent_id, lines, index)
        elsif Blockquote.match?(content)
          index = @blockquote_parser.parse(parent_id, lines, index)
        elsif List.match(content)
          index = @list_parser.parse(parent_id, lines, index)
        elsif CodeBlock.indented_line?(content)
          index = @code_block_parser.parse_indented(parent_id, lines, index)
        else
          index = parse_paragraph(parent_id, lines, index, transformed)
        end
      end
      blank_then_block
    end

    # Methods the collaborator parsers (List::Parser, Blockquote::Parser,
    # FootnoteDefinition::Parser) call back into.

    # A line at less-than-N indent breaks lazy continuation when it would
    # itself start a new block (heading, thematic break, fenced/indented
    # code, html block, blockquote, list item, table). Same predicate as
    # paragraph_interrupt? minus the "index > 0" guard.
    def lazy_break?(lines, index)
      line = lines[index]
      return true if atx_heading(line.content)
      return true if thematic_break?(line.content)
      return true if CodeBlock.fenced_start(line.content)
      # HTML type 7 doesn't break lazy continuation either.
      if (type = HtmlBlock.type(line.content)) && type != 7
        return true
      end
      return true if Blockquote.match?(line.content)
      if (li = List.match(line.content)) && List.interrupts_paragraph?(li)
        return true
      end
      return true if Table.start?(lines, index)

      false
    end

    # Thematic break per CommonMark: 0-3 spaces of indent, then 3+ of
    # the same character (`*`, `-`, or `_`) optionally separated by
    # whitespace, and nothing else on the line. Lines indented 4+ spaces
    # are indented code, not thematic breaks.
    THEMATIC_BREAK_RE = /\A {0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})\z/

    private_constant :THEMATIC_BREAK_RE

    def thematic_break?(text)
      THEMATIC_BREAK_RE.match?(text)
    end

    def paragraph_eligible_line?(content)
      return false if CodeBlock.indented_line?(content)
      return false if CodeBlock.fenced_start(content)
      return false if atx_heading(content)
      return false if thematic_break?(content)
      return false if HtmlBlock.start?(content)
      return false if List.match(content)
      return false if Blockquote.match?(content)

      true
    end

    private

    # Byte values that can begin a non-paragraph block (after 0-3
    # leading spaces). Lines whose first non-space byte is NOT in this
    # set go straight to parse_paragraph, skipping all eight specific
    # block-start predicates.
    #
    # Members: `#` (ATX), ``` ` ```/`~` (fences), `*`/`-`/`+`/`_` (thematic
    # & list markers), `0`-`9` (ordered list), `[` (ref def), `>` (blockquote),
    # `<` (HTML block), `\t` (indented code, when a tab provides indent).
    BLOCK_START_BYTES = begin
      a = Array.new(256, false)
      [0x23, 0x60, 0x7E, 0x2A, 0x2D, 0x2B, 0x5F, 0x5B, 0x3E, 0x3C, 0x09].each { |b| a[b] = true }
      (0x30..0x39).each { |b| a[b] = true }
      a.freeze
    end

    private_constant :BLOCK_START_BYTES

    # Returns true when `content` cannot start any non-paragraph block,
    # so the slow predicate fan-out in parse_lines can be skipped. The
    # check is intentionally conservative: anything ambiguous returns
    # false and falls through to the full dispatch.
    def paragraph_only_line?(content)
      bytes = content.bytesize
      i = 0
      # Up to 3 leading spaces are still part of the block prefix; 4+
      # means indented code, which IS a block start.
      while i < 3 && i < bytes && content.getbyte(i) == 0x20
        i += 1
      end
      return false if i >= bytes

      first = content.getbyte(i)
      # 4+ leading spaces? Treat as indented code candidate.
      return false if i == 3 && first == 0x20
      # The first non-space byte gates every block start we recognise.
      return false if BLOCK_START_BYTES[first]
      # Table rows always contain `|`; quick C-level scan covers them.
      return false if content.include?("|")

      true
    end

    def append_heading(parent_id, line, heading, transformed)
      content = heading[:content].to_s.rstrip
      source_start = line.start_byte + heading[:content_start]
      node_id = @arena.add_node(NodeType::HEADING,
                                source_start: source_start,
                                source_len: content.bytesize,
                                int1: heading[:level],
                                str1: transformed ? content : nil)
      @arena.append_child(parent_id, node_id)
    end

    def parse_paragraph(parent_id, lines, index, transformed)
      paragraph_lines = []
      start_index = index
      setext_level = nil
      while index < lines.length
        line = lines[index]
        break if line.blank

        # Setext heading underline: only valid when there is already at
        # least one paragraph line above it. Checked before
        # paragraph_interrupt? so that "---" / "===" turns the open
        # paragraph into a heading instead of being treated as a
        # thematic break.
        if paragraph_lines.any? && !line.lazy_continuation && (level = setext_underline_level(line.content))
          setext_level = level
          index += 1
          break
        end

        # Lazy continuation lines always extend the open paragraph;
        # they have already been classified as paragraph content by the
        # outer collector, so we must not let `paragraph_interrupt?`
        # split them off into a new block (which would also try to
        # parse them as e.g. a list item start).
        if !line.lazy_continuation && index > start_index && paragraph_interrupt?(lines, index)
          break
        end

        # NOTE: Per CommonMark, a `[label]: ...` line cannot start a
        # link reference definition inside an open paragraph — it's
        # absorbed as paragraph continuation. The dispatch in
        # parse_lines catches definitions that appear after a blank
        # line, so we don't need another scan here.
        paragraph_lines << line
        index += 1
      end

      # CommonMark: the first paragraph line may carry 0-3 spaces of
      # leading indent (4+ would be an indented code block, so it never
      # reaches this branch). Continuation lines have no fixed indent
      # cap — all leading whitespace is stripped before joining.
      stripped = paragraph_lines.map.with_index do |l, i|
        i.zero? ? Indentation.strip_leading_spaces(l.content, 3) : Indentation.strip_leading_whitespace(l.content)
      end
      # Trailing whitespace on the last line is dropped (no hard-break
      # without a following content line).
      stripped[-1] = stripped[-1].sub(/[ \t]+\z/, "") if stripped.any?
      indent_was_stripped = stripped.zip(paragraph_lines).any? { |s, l| s.length != l.content.length }
      text = stripped.join("\n")
      start_byte = paragraph_lines.first.start_byte
      end_byte = paragraph_lines.last.end_byte

      if setext_level
        heading_id = @arena.add_node(NodeType::HEADING,
                                     source_start: start_byte,
                                     source_len: end_byte - start_byte,
                                     int1: setext_level,
                                     str1: text.strip)
        @arena.append_child(parent_id, heading_id)
        return index
      end

      # Paragraphs carry a literal when the inline content cannot be
      # recovered from a contiguous source slice — that is, when block
      # transformation has already happened (blockquote / list item
      # interior, `transformed: true`) or when we stripped leading
      # paragraph indent above. Otherwise leave str1 nil so the inline
      # pass and NodeRef#source_span / source_location use the real
      # source bytes.
      needs_literal = transformed || indent_was_stripped
      paragraph_id = @arena.add_node(NodeType::PARAGRAPH,
                                     source_start: start_byte,
                                     source_len: end_byte - start_byte,
                                     str1: needs_literal ? text : nil)
      @arena.append_child(parent_id, paragraph_id)
      index
    end

    # Returns 1 for `===...` (h1), 2 for `---...` (h2), nil otherwise.
    # Leading up to 3 spaces of indent and any amount of trailing
    # whitespace are allowed.
    def setext_underline_level(text)
      match = /\A {0,3}(=+|-+)[ \t]*\z/.match(text)
      return nil unless match

      match[1].start_with?("=") ? 1 : 2
    end

    def paragraph_interrupt?(lines, index)
      line = lines[index]
      return false unless index > 0
      return true if atx_heading(line.content)
      return true if thematic_break?(line.content)
      return true if CodeBlock.fenced_start(line.content)
      # CommonMark: HTML block types 1–6 interrupt paragraphs; type 7
      # (a bare valid tag on its own line) does not.
      if (type = HtmlBlock.type(line.content)) && type != 7
        return true
      end
      return true if Blockquote.match?(line.content)
      if (li = List.match(line.content)) && List.interrupts_paragraph?(li)
        return true
      end
      return true if Table.start?(lines, index)

      false
    end

    def build_lines(source)
      # split("\n", -1) avoids the extra slice/allocation that
      # each_line + chomp incurs per line. The blank-line check uses
      # /[^ \t]/ (not /\S/) because CommonMark defines a blank line as
      # "empty, or containing only spaces (U+0020) or tabs (U+0009)" --
      # other whitespace (e.g. form feed U+000C) does NOT make a line
      # blank and must continue an enclosing paragraph.
      parts = source.split("\n", -1)
      parts.pop if source.end_with?("\n")
      lines = []
      offset = 0
      parts.each do |raw|
        size = raw.bytesize
        lines << Line.new(raw, offset, offset + size, !raw.match?(/[^ \t]/))
        offset += size + 1
      end
      lines
    end

    # ATX headings per CommonMark spec:
    # - 0-3 spaces of indent, then 1-6 `#`s
    # - either end-of-line (empty heading) or at least one space/tab
    #   followed by the content
    # - optional trailing `#`s are only stripped when separated from the
    #   content by whitespace (so `# foo#` keeps the `#`)
    ATX_HEADING_RE = /\A {0,3}(\#{1,6})(?:[ \t]+\#+[ \t]*|[ \t]+(.*?)(?:[ \t]+\#+)?[ \t]*|[ \t]*)\z/

    private_constant :ATX_HEADING_RE

    def atx_heading(text)
      match = ATX_HEADING_RE.match(text)
      return unless match

      content = match[2].to_s
      content_index = content.empty? ? text.length : (text.index(content) || text.bytesize)
      { level: match[1].length, content: content, content_start: content_index }
    end

    def store_reference(reference, source_span)
      if @references.key?(reference[:label])
        @diagnostics << Diagnostic.new(
          severity: :warning,
          rule: :duplicate_reference,
          message: "Duplicate reference definition #{reference[:label].inspect} — keeping the first",
          source_span: source_span,
        )
        return
      end
      @references[reference[:label]] = {
        destination: reference[:destination],
        title: reference[:title],
      }
    end
  end
end
