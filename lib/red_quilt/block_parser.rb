# frozen_string_literal: true

module RedQuilt
  class BlockParser
    Line = Struct.new(:content, :start_byte, :end_byte, :blank, :lazy_continuation, keyword_init: true)

    def initialize(arena)
      @arena = arena
      @lines = build_lines(arena.source)
      @references = {}
      @diagnostics = []
      # Cached collaborator parsers — created once and reused for every
      # block of the corresponding type (including nested ones) so the
      # dispatch path stays allocation-free.
      @list_parser = List::Parser.new(self)
      @blockquote_parser = Blockquote::Parser.new(self)
    end

    attr_reader :references, :arena, :diagnostics

    def parse
      root_id = @arena.add_node(NodeType::DOCUMENT, source_start: 0, source_len: @arena.source.bytesize)
      parse_lines(root_id, @lines, transformed: false)
      root_id
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

        if (fence = fenced_code_start(content))
          index = parse_fenced_code(parent_id, lines, index, fence, transformed)
        elsif (heading = atx_heading(content))
          append_heading(parent_id, line, heading, transformed)
          index += 1
        elsif thematic_break?(content)
          @arena.append_child(parent_id, @arena.add_node(NodeType::THEMATIC_BREAK, source_start: line.start_byte, source_len: span_len(line)))
          index += 1
        elsif (reference = ReferenceDefinition.consume(lines, index))
          store_reference(reference[:reference], reference[:source_span])
          index += reference[:consumed]
        elsif table_start?(lines, index)
          index = parse_table(parent_id, lines, index, transformed)
        elsif html_block_start?(content)
          index = parse_html_block(parent_id, lines, index, transformed)
        elsif Blockquote.match?(content)
          index = @blockquote_parser.parse(parent_id, lines, index)
        elsif List.match(content)
          index = @list_parser.parse(parent_id, lines, index)
        elsif indented_code_line?(content)
          index = parse_indented_code(parent_id, lines, index, transformed)
        else
          index = parse_paragraph(parent_id, lines, index, transformed)
        end
      end
      blank_then_block
    end

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

    def paragraph_eligible_line?(content)
      return false if indented_code_line?(content)
      return false if fenced_code_start(content)
      return false if atx_heading(content)
      return false if thematic_break?(content)
      return false if html_block_start?(content)
      return false if List.match(content)
      return false if Blockquote.match?(content)

      true
    end

    # A line at less-than-N indent breaks lazy continuation when it would
    # itself start a new block (heading, thematic break, fenced/indented
    # code, html block, blockquote, list item, table). Same predicate as
    # paragraph_interrupt? minus the "index > 0" guard.
    def lazy_break?(lines, index)
      line = lines[index]
      return true if atx_heading(line.content)
      return true if thematic_break?(line.content)
      return true if fenced_code_start(line.content)
      # HTML type 7 doesn't break lazy continuation either.
      if (type = html_block_type(line.content)) && type != 7
        return true
      end
      return true if Blockquote.match?(line.content)
      if (li = List.match(line.content)) && List.interrupts_paragraph?(li)
        return true
      end
      return true if table_start?(lines, index)

      false
    end

    def parse_fenced_code(parent_id, lines, index, fence, transformed)
      start_line = lines[index]
      content_lines = []
      index += 1
      while index < lines.length
        break if fenced_code_close?(lines[index].content, fence[:char], fence[:count])

        content_lines << lines[index]
        index += 1
      end
      index += 1 if index < lines.length

      # Each content line is stripped of up to the fence's own leading
      # indent (CommonMark spec: a fence indented by N spaces strips up
      # to N spaces from every content line, but never more). Manual
      # byte scan beats compiling an interpolated regex per block and
      # short-circuits when the fence had no indent (the common case).
      indent_n = fence[:indent] || 0
      code = content_lines.map { |l| strip_leading_spaces(l.content, indent_n) }.join("\n")
      code << "\n" unless content_lines.empty?
      source_start = content_lines.empty? ? start_line.start_byte : content_lines.first.start_byte
      source_end = content_lines.empty? ? start_line.end_byte : content_lines.last.end_byte
      code_id = @arena.add_node(NodeType::CODE_BLOCK,
                                source_start: source_start,
                                source_len: source_end - source_start,
                                str1: code,
                                str2: fence[:info])
      @arena.append_child(parent_id, code_id)
      index
    end

    def parse_indented_code(parent_id, lines, index, transformed)
      start_index = index
      code_lines = []
      while index < lines.length
        line = lines[index]
        break unless line.blank || indented_code_line?(line.content)

        # CommonMark: strip up to 4 columns of leading whitespace
        # (tab-aware) from every line, including blank lines whose
        # content beyond column 4 must be preserved verbatim.
        code_lines << strip_columns(line.content, 4)
        index += 1
      end

      # Trailing blank lines are not part of the code block.
      while !code_lines.empty? && code_lines.last.strip.empty?
        code_lines.pop
        index -= 1
      end

      start_byte = lines[start_index].start_byte
      end_byte = lines[index - 1].end_byte
      code = code_lines.empty? ? "" : code_lines.join("\n") + "\n"

      code_id = @arena.add_node(NodeType::CODE_BLOCK,
                                source_start: start_byte,
                                source_len: end_byte - start_byte,
                                str1: code)
      @arena.append_child(parent_id, code_id)
      index
    end

    HTML_BLOCK_FIXED_TERMINATORS = {
      2 => "-->",
      3 => "?>",
      4 => ">",
      5 => "]]>"
    }.freeze

    def parse_html_block(parent_id, lines, index, transformed)
      start_index = index
      type = html_block_type(lines[index].content)
      end_index = locate_html_block_end(lines, index, type)

      start_byte = lines[start_index].start_byte
      end_byte = lines[end_index].end_byte
      html_lines = (start_index..end_index).map { |i| lines[i].content }
      html_id = @arena.add_node(NodeType::HTML_BLOCK,
                                source_start: start_byte,
                                source_len: end_byte - start_byte,
                                str1: html_lines.join("\n"))
      @arena.append_child(parent_id, html_id)
      end_index + 1
    end

    def locate_html_block_end(lines, index, type)
      terminator = html_block_terminator(type, lines[index].content)

      if terminator
        case_insensitive = (type == 1)
        while index < lines.length
          line = lines[index].content
          haystack = case_insensitive ? line.downcase : line
          return index if haystack.include?(terminator)

          index += 1
        end
        lines.length - 1
      else
        # Types 6 & 7: terminated by blank line (or end of input)
        index += 1 while index < lines.length && !lines[index].blank
        index - 1
      end
    end

    def html_block_terminator(type, first_line)
      case type
      when 1
        "</#{extract_closing_tag_name(first_line)}>"
      when 2..5
        HTML_BLOCK_FIXED_TERMINATORS[type]
      end
    end

    def extract_closing_tag_name(text)
      match = /\A<(script|pre|style|textarea)/i.match(text)
      match ? match[1].downcase : "script"
    end

    def parse_table(parent_id, lines, index, transformed)
      # Caller must have verified table_start?(lines, index), which validates
      # both the delimiter pattern and the header/separator column count match.
      start_index = index
      header_cells = split_table_row(lines[index].content)
      row_lines = [lines[index]]
      index += 2
      while index < lines.length
        break if lines[index].blank
        break unless table_row?(lines[index].content)

        row_lines << lines[index]
        index += 1
      end

      table_id = @arena.add_node(NodeType::TABLE,
                                 source_start: lines[start_index].start_byte,
                                 source_len: row_lines.last.end_byte - lines[start_index].start_byte)
      @arena.append_child(parent_id, table_id)

      append_table_row(table_id, lines[start_index], header_cells, true)
      row_lines.drop(1).each do |row_line|
        append_table_row(table_id, row_line, split_table_row(row_line.content), false)
      end

      index
    end

    def append_table_row(table_id, line, cells, header)
      row_id = @arena.add_node(NodeType::TABLE_ROW,
                               source_start: line.start_byte,
                               source_len: span_len(line),
                               int1: header ? 1 : 0)
      @arena.append_child(table_id, row_id)
      cells.each do |cell_text|
        stripped = cell_text.strip
        cell_id = @arena.add_node(NodeType::TABLE_CELL,
                                  source_start: line.start_byte,
                                  source_len: span_len(line),
                                  int1: header ? 1 : 0,
                                  str1: stripped)
        @arena.append_child(row_id, cell_id)
      end
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
        i.zero? ? strip_leading_spaces(l.content, 3) : strip_leading_whitespace(l.content)
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
      return true if fenced_code_start(line.content)
      # CommonMark: HTML block types 1–6 interrupt paragraphs; type 7
      # (a bare valid tag on its own line) does not.
      if (type = html_block_type(line.content)) && type != 7
        return true
      end
      return true if Blockquote.match?(line.content)
      if (li = List.match(line.content)) && List.interrupts_paragraph?(li)
        return true
      end
      return true if table_start?(lines, index)

      false
    end

    # Bytes of literal leading 0x20 / 0x09 in `text`.
    def leading_ws_bytes(text)
      i = 0
      bytes = text.bytesize
      while i < bytes
        b = text.getbyte(i)
        break unless b == 0x20 || b == 0x09

        i += 1
      end
      i
    end

    # Strips up to `max` leading 0x20 bytes from `text`. Returns the
    # original string when nothing changed, so callers avoid an
    # allocation in the common no-indent case.
    def strip_leading_spaces(text, max)
      return text if max <= 0

      bytes = text.bytesize
      i = 0
      while i < max && i < bytes && text.getbyte(i) == 0x20
        i += 1
      end
      return text if i.zero?

      text.byteslice(i..)
    end

    # Strips all leading 0x20 / 0x09 bytes from `text`. Same no-alloc
    # return as `strip_leading_spaces` when the string already starts
    # at a non-whitespace byte.
    def strip_leading_whitespace(text)
      bytes = text.bytesize
      i = 0
      while i < bytes
        b = text.getbyte(i)
        break unless b == 0x20 || b == 0x09

        i += 1
      end
      return text if i.zero?

      text.byteslice(i..)
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
        lines << Line.new(
          content: raw,
          start_byte: offset,
          end_byte: offset + size,
          blank: !raw.match?(/[^ \t]/)
        )
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

    def atx_heading(text)
      match = ATX_HEADING_RE.match(text)
      return unless match

      content = match[2].to_s
      content_index = content.empty? ? text.length : (text.index(content) || text.bytesize)
      { level: match[1].length, content: content, content_start: content_index }
    end

    # Thematic break per CommonMark: 0-3 spaces of indent, then 3+ of
    # the same character (`*`, `-`, or `_`) optionally separated by
    # whitespace, and nothing else on the line. Lines indented 4+ spaces
    # are indented code, not thematic breaks.
    THEMATIC_BREAK_RE = /\A {0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})\z/

    def thematic_break?(text)
      THEMATIC_BREAK_RE.match?(text)
    end

    def fenced_code_start(text)
      match = /\A( {0,3})(`{3,}|~{3,})[ \t]*(.*?)\s*\z/.match(text)
      return unless match

      info = match[3]
      # CommonMark: a backtick-style fence cannot have backticks in its
      # info string (they'd be ambiguous with the fence itself).
      return if match[2].start_with?("`") && info.include?("`")

      {
        char: match[2][0],
        count: match[2].length,
        info: ReferenceDefinition.unescape_text(info),
        indent: match[1].length
      }
    end

    def fenced_code_close?(text, char, count)
      # Manual byte scan beats compiling a per-(char,count) regex on
      # every line of a fenced block. Pattern: 0-3 spaces, >=count of
      # `char`, optional trailing spaces/tabs, end-of-line.
      bytes = text.bytesize
      i = 0
      # CommonMark spec: at most 3 spaces of indent.
      while i < 3 && i < bytes && text.getbyte(i) == 0x20
        i += 1
      end
      char_byte = char.getbyte(0)
      fence_start = i
      while i < bytes && text.getbyte(i) == char_byte
        i += 1
      end
      return false if i - fence_start < count

      while i < bytes
        b = text.getbyte(i)
        return false unless b == 0x20 || b == 0x09

        i += 1
      end
      true
    end

    def indented_code_line?(text)
      # CommonMark: 4+ columns of leading whitespace, where tabs expand
      # virtually to a tab stop of 4 columns.
      leading_columns(text) >= 4
    end

    # Returns the column count of leading whitespace, treating tabs as
    # advancing to the next multiple-of-4 column.
    def leading_columns(text)
      col = 0
      i = 0
      bytes = text.bytesize
      while i < bytes
        b = text.getbyte(i)
        if b == 0x20
          col += 1
        elsif b == 0x09
          col = (col / 4 + 1) * 4
        else
          break
        end
        i += 1
      end
      col
    end

    # Strips up to `n` columns of leading whitespace from `text` and
    # returns the rest. Leading whitespace is normalised to spaces in
    # the returned string so subsequent strips compose correctly
    # regardless of where they land relative to the original tab stops.
    def strip_columns(text, n)
      return text if n <= 0

      col = 0
      i = 0
      bytes = text.bytesize
      while i < bytes
        b = text.getbyte(i)
        if b == 0x20
          col += 1
        elsif b == 0x09
          col = (col / 4 + 1) * 4
        else
          break
        end
        i += 1
      end
      # text[0...i] is all leading whitespace representing `col` cols.
      if n >= col
        i.zero? ? text : text.byteslice(i..)
      else
        # Keep the unstripped portion as a run of spaces.
        (" " * (col - n)) + text.byteslice(i..)
      end
    end

    def html_block_start?(text)
      # Indented code block takes precedence (4+ spaces)
      return false if text.start_with?("    ")

      !html_block_type(text).nil?
    end

    def html_block_type(text)
      # Fast reject: every HTML block starts with `<`. lstrip strips
      # 0-3 indent spaces (more would already be indented code), so peek
      # the leading non-space byte before doing any allocations.
      i = 0
      # CommonMark: HTML block lines may have 0-3 spaces of indent.
      while i < 3 && i < text.length && text.getbyte(i) == 0x20
        i += 1
      end
      return nil unless i < text.length && text.getbyte(i) == 0x3C

      stripped = i.zero? ? text : text[i..]

      # Type 1: <script|pre|style|textarea (case-insensitive) followed by
      # space/tab/end-of-line or `>`. CommonMark restricts the separator
      # to space, tab, or a line ending (not any whitespace class).
      return 1 if stripped.match?(%r{\A<(script|pre|style|textarea)(?:[ \t]|>|$)}i)

      # Type 2: <!--
      return 2 if stripped.start_with?("<!--")

      # Type 3: <?
      return 3 if stripped.start_with?("<?")

      # Type 4: <! followed by uppercase ASCII letter
      return 4 if stripped.match?(%r{\A<![A-Z]})

      # Type 5: <![CDATA[
      return 5 if stripped.start_with?("<![CDATA[")

      # Type 6: line opens with one of the listed block-level tags.
      return 6 if stripped.match?(HTML_BLOCK_TYPE_6_RE)

      # Type 7: a complete open or closing tag spanning the line.
      return 7 if valid_html_tag?(stripped)

      nil
    end

    HTML_BLOCK_TYPE_6_NAMES = %w[
      address article aside base basefont blockquote body caption center
      col colgroup dd details dialog dir div dl dt fieldset figcaption
      figure footer form frame frameset h1 h2 h3 h4 h5 h6 head header
      hr html iframe legend li link main menu menuitem nav noframes ol
      optgroup option p param search section summary table tbody td
      tfoot th thead title tr track ul
    ].freeze
    HTML_BLOCK_TYPE_6_RE =
      %r{\A</?(?:#{HTML_BLOCK_TYPE_6_NAMES.join('|')})(?:[ \t]|>|/>|\z)}i

    def table_start?(lines, index)
      return false if index + 1 >= lines.length
      return false unless table_row?(lines[index].content)

      header_cells = split_table_row(lines[index].content)
      separators = split_table_row(lines[index + 1].content)
      return false if separators.empty?

      # GFM spec: separator row must have valid delimiters AND match header column count.
      # "The header row must match the delimiter row in the number of cells.
      #  If not, a table will not be recognized."
      return false unless header_cells.length == separators.length

      separators.all? { |cell| cell.strip.match?(/\A:?-+:?\z/) }
    end

    def table_row?(text)
      text.include?("|")
    end

    def split_table_row(text)
      body = text.strip
      body = body[1..] if body.start_with?("|")
      body = body[0...-1] if body.end_with?("|")
      body.split("|", -1)
    end

    # Type 7: a complete open or closing tag on its own line.
    # Closing tags must not have attributes.
    #
    # HTML tag separators per CommonMark 6.6 are space, tab, or up to one
    # line ending -- not the broader \s class (which would include form
    # feed and vertical tab).
    HTML_TYPE_7_OPEN_TAG_RE = %r{
      \A
      <[A-Za-z][A-Za-z0-9-]*
      (?:[ \t\r\n]+[A-Za-z_:][A-Za-z0-9_.:-]*(?:[ \t\r\n]*=[ \t\r\n]*(?:"[^"\n]*"|'[^'\n]*'|[^ \t\r\n"'=<>`]+))?)*
      [ \t\r\n]*/?>
      \z
    }x
    HTML_TYPE_7_CLOSING_TAG_RE = %r{\A</[A-Za-z][A-Za-z0-9-]*[ \t\r\n]*>\z}

    def valid_html_tag?(text)
      # Fast reject: every type-7 tag must begin with `<`.
      return false unless text.start_with?("<")

      HTML_TYPE_7_OPEN_TAG_RE.match?(text) || HTML_TYPE_7_CLOSING_TAG_RE.match?(text)
    end

    def store_reference(reference, source_span)
      if @references.key?(reference[:label])
        @diagnostics << Diagnostic.new(
          severity: :warning,
          rule: :duplicate_reference,
          message: "Duplicate reference definition #{reference[:label].inspect} — keeping the first",
          source_span: source_span
        )
        return
      end
      @references[reference[:label]] = {
        destination: reference[:destination],
        title: reference[:title]
      }
    end

    def span_len(line)
      line.end_byte - line.start_byte
    end
  end
end
