# frozen_string_literal: true

module Mdarena
  class BlockParser
    Line = Struct.new(:content, :start_byte, :end_byte, :blank, :lazy, keyword_init: true)
    ItemLine = Struct.new(:content, :start_byte, :end_byte, :blank, :continuation, :lazy, keyword_init: true)

    def initialize(arena)
      @arena = arena
      @lines = build_lines(arena.source)
      @references = {}
    end

    attr_reader :references

    def parse
      root_id = @arena.add_node(NodeType::DOCUMENT, source_start: 0, source_len: @arena.source.bytesize)
      parse_lines(root_id, @lines, transformed: false)
      root_id
    end

    private

    def parse_lines(parent_id, lines, transformed:)
      index = 0
      while index < lines.length
        line = lines[index]
        if line.blank
          index += 1
          next
        end

        if (fence = fenced_code_start(line.content))
          index = parse_fenced_code(parent_id, lines, index, fence, transformed)
        elsif (heading = atx_heading(line.content))
          append_heading(parent_id, line, heading, transformed)
          index += 1
        elsif thematic_break?(line.content)
          @arena.append_child(parent_id, @arena.add_node(NodeType::THEMATIC_BREAK, source_start: line.start_byte, source_len: span_len(line)))
          index += 1
        elsif (reference = link_reference_definition(lines, index))
          store_reference(reference[:reference])
          index += reference[:consumed]
        elsif table_start?(lines, index)
          index = parse_table(parent_id, lines, index, transformed)
        elsif html_block_start?(line.content)
          index = parse_html_block(parent_id, lines, index, transformed)
        elsif blockquote_line?(line.content)
          index = parse_blockquote(parent_id, lines, index)
        elsif list_item_start(line.content)
          index = parse_list(parent_id, lines, index)
        elsif indented_code_line?(line.content)
          index = parse_indented_code(parent_id, lines, index, transformed)
        else
          index = parse_paragraph(parent_id, lines, index, transformed)
        end
      end
    end

    def parse_blockquote(parent_id, lines, index)
      block_lines = []
      paragraph_open = false

      while index < lines.length
        line = lines[index]

        if line.blank
          # Blank line outside the blockquote prefix closes it.
          break
        elsif blockquote_line?(line.content)
          stripped = strip_blockquote_prefix(line)
          paragraph_open =
            if stripped.content.strip.empty?
              false # `>` 単独 (or `>` followed by blank) ends any open paragraph
            else
              # Recurse through any inner blockquote prefixes — an
              # innermost open paragraph (e.g. `> > > foo` where `foo`
              # is paragraph-eligible) lets a `>`-less follow-up line
              # lazily continue it even at the outer level.
              paragraph_eligible_through_blockquotes?(stripped.content)
            end
          block_lines << stripped
        elsif paragraph_open && !lazy_break?(lines, index)
          # Lazy continuation: a `>`-less line is absorbed into the
          # currently open paragraph as long as it doesn't itself start
          # a new block. Only allowed while the most recent in-quote
          # line is paragraph-eligible content. The `lazy` flag prevents
          # the paragraph parser from interpreting `===` / `---` on such
          # a line as a setext underline.
          block_lines << Line.new(content: line.content,
                                  start_byte: line.start_byte,
                                  end_byte: line.end_byte,
                                  blank: line.blank,
                                  lazy: true)
        else
          break
        end
        index += 1
      end

      block_id = @arena.add_node(NodeType::BLOCKQUOTE,
                                 source_start: block_lines.first.start_byte,
                                 source_len: block_lines.last.end_byte - block_lines.first.start_byte)
      @arena.append_child(parent_id, block_id)
      parse_lines(block_id, block_lines, transformed: true)
      index
    end

    # Whether this line looks like plain paragraph content (eligible to be
    # extended by a subsequent lazy-continuation line). Anything that
    # would start another block type is rejected.
    # Like paragraph_eligible_line?, but transparently peels any number
    # of leading wrapper prefixes (blockquote `>` and list item markers)
    # to find out whether the innermost block is still paragraph
    # content. Used so `> > > foo\nbar` and `> 1. > foo\nbar` both let
    # the unprefixed line lazily continue the deepest paragraph.
    def paragraph_eligible_through_blockquotes?(content)
      c = content
      loop do
        if blockquote_line?(c)
          m = /\A {0,3}> ?/.match(c)
          break unless m
          c = c[m[0].length..]
          return false if c.strip.empty?
        elsif (li = list_item_start(c))
          c = li[:content]
          return false if c.strip.empty?
        else
          break
        end
      end
      paragraph_eligible_line?(c)
    end

    def paragraph_eligible_line?(content)
      return false if indented_code_line?(content)
      return false if fenced_code_start(content)
      return false if atx_heading(content)
      return false if thematic_break?(content)
      return false if html_block_start?(content)
      return false if list_item_start(content)
      return false if blockquote_line?(content)
      true
    end

    def parse_list(parent_id, lines, index)
      first_match = list_item_start(lines[index].content)
      list_id = @arena.add_node(NodeType::LIST,
                                source_start: lines[index].start_byte,
                                source_len: 0,
                                int1: first_match[:ordered] ? 1 : 0,
                                int2: first_match[:start_number],
                                int3: 1,
                                str1: first_match[:marker])
      @arena.append_child(parent_id, list_id)
      start_byte = lines[index].start_byte
      end_byte = lines[index].end_byte
      loose = false

      while index < lines.length
        # Thematic break beats list-item continuation per CommonMark:
        # a line like `* * *` ends the list and starts an <hr />.
        break if thematic_break?(lines[index].content)
        match = list_item_start(lines[index].content)
        break unless match
        break unless same_list_group?(first_match, match)

        item_lines, index = collect_list_item(lines, index, match)
        end_byte = item_lines.last.end_byte
        # Blank lines inside an item make the list loose, EXCEPT:
        # - the very first line (empty marker, e.g. `-` alone)
        # - blanks inside a fenced code block (they belong to the code)
        loose ||= item_blank_makes_loose?(item_lines)
        item_id = @arena.add_node(NodeType::LIST_ITEM,
                                  source_start: item_lines.first.start_byte,
                                  source_len: item_lines.last.end_byte - item_lines.first.start_byte)
        @arena.append_child(list_id, item_id)
        parse_lines(item_id, item_lines, transformed: true)

        blank_count = 0
        while index < lines.length && lines[index].blank
          blank_count += 1
          index += 1
        end

        if blank_count.positive?
          next_match = index < lines.length ? list_item_start(lines[index].content) : nil
          if next_match && same_list_group?(first_match, next_match)
            loose = true
          else
            break
          end
        end
      end

      @arena.update_span(list_id, start_byte, end_byte)
      @arena.replace_int3(list_id, loose ? 0 : 1)
      index
    end

    def collect_list_item(lines, index, match)
      item_lines = []
      n = match[:content_indent]
      first_line = lines[index]
      item_lines << ItemLine.new(
        content: match[:content],
        start_byte: first_line.start_byte + match[:content_start],
        end_byte: first_line.end_byte,
        blank: match[:content].strip.empty?,
        continuation: false
      )
      index += 1

      # If the marker line itself was empty (`-` followed by EOL) and the
      # very next line is also blank, the item is empty and ends now. This
      # matches CommonMark spec 5.2: an empty list item cannot grow by
      # absorbing arbitrary blank lines.
      if match[:content].strip.empty? && index < lines.length && lines[index].blank
        return [item_lines, index]
      end

      pending_blanks = []

      while index < lines.length
        current = lines[index]

        if current.blank
          pending_blanks << ItemLine.new(
            content: "",
            start_byte: current.start_byte,
            end_byte: current.end_byte,
            blank: true,
            continuation: true
          )
          index += 1
          next
        end

        # CommonMark: continuation requires the line's leading
        # whitespace to span at least `n` columns, with tabs expanding
        # to multiples of 4.
        if leading_columns(current.content) >= n
          item_lines.concat(pending_blanks)
          pending_blanks = []
          stripped_content = strip_columns(current.content, n)
          # When strip_columns synthesizes spaces for a partially-
          # consumed tab, the byte length of leading whitespace can
          # change; compute the new start_byte against the original
          # text rather than assuming `n` bytes were dropped.
          strip_bytes = current.content.bytesize - stripped_content.bytesize
          item_lines << ItemLine.new(
            content: stripped_content,
            start_byte: current.start_byte + strip_bytes,
            end_byte: current.end_byte,
            blank: false,
            continuation: true
          )
          index += 1
          next
        end

        # Less-indented non-blank line: a new list item (any group) ends
        # this item regardless of paragraph state.
        break if list_item_start(current.content)

        # Otherwise it may be lazy paragraph continuation. Requires:
        #   - no pending blanks (blanks always end the paragraph that
        #     could've been continued)
        #   - the previous in-item line is non-blank paragraph content
        #   - the new line is not itself a block-level interrupter
        if pending_blanks.empty? &&
           item_lines.last && !item_lines.last.blank &&
           !lazy_break?(lines, index)
          # Lazy continuation lines are joined into the open paragraph;
          # their leading indentation is dropped (CommonMark spec). The
          # `lazy` flag tells parse_paragraph to absorb the line even
          # when its stripped form would otherwise look like a fresh
          # block start (e.g. `    - e` becoming `- e`).
          stripped = current.content.sub(/\A[ \t]+/, "")
          strip_len = current.content.length - stripped.length
          item_lines << ItemLine.new(
            content: stripped,
            start_byte: current.start_byte + strip_len,
            end_byte: current.end_byte,
            blank: false,
            continuation: true,
            lazy: true
          )
          index += 1
          next
        end

        break
      end

      # If we stopped with held blanks (item ended at a less-indented
      # line), rewind so parse_list can see the blanks and decide
      # loose vs tight.
      index -= pending_blanks.length unless pending_blanks.empty?

      [item_lines, index]
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
      return true if blockquote_line?(line.content)
      if (li = list_item_start(line.content)) && list_item_interrupts_paragraph?(li)
        return true
      end
      return true if table_start?(lines, index)
      false
    end

    def same_list_group?(expected, actual)
      expected[:ordered] == actual[:ordered] && expected[:marker] == actual[:marker]
    end

    def item_blank_makes_loose?(item_lines)
      in_fence = false
      fence_char = nil
      fence_count = 0
      item_lines.each_with_index do |line, idx|
        content = line.content
        if !in_fence && (fence = fenced_code_start(content))
          in_fence = true
          fence_char = fence[:char]
          fence_count = fence[:count]
        elsif in_fence && fenced_code_close?(content, fence_char, fence_count)
          in_fence = false
        elsif line.blank && !in_fence && idx > 0
          return true
        end
      end
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
      start_index = index
      header_cells = split_table_row(lines[index].content)
      separator_cells = split_table_row(lines[index + 1].content)
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

      separator_cells
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
        if paragraph_lines.any? && !line.lazy && (level = setext_underline_level(line.content))
          setext_level = level
          index += 1
          break
        end

        # Lazy continuation lines always extend the open paragraph;
        # they have already been classified as paragraph content by the
        # outer collector, so we must not let `paragraph_interrupt?`
        # split them off into a new block (which would also try to
        # parse them as e.g. a list item start).
        unless line.lazy
          break if index > start_index && paragraph_interrupt?(lines, index)
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
      return true if blockquote_line?(line.content)
      if (li = list_item_start(line.content)) && list_item_interrupts_paragraph?(li)
        return true
      end
      return true if table_start?(lines, index)
      false
    end

    # CommonMark spec: a list item can only interrupt an open paragraph if
    # it has visible content, and (for ordered lists) only if the start
    # number is 1.
    def list_item_interrupts_paragraph?(li_match)
      return false if li_match[:content].empty?
      return false if li_match[:ordered] && li_match[:start_number] != 1
      true
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
      # each_line + chomp incurs per line, and `\S` against the line is
      # cheaper than allocating a stripped copy just to check emptiness.
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
          blank: !raw.match?(/\S/)
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
    ATX_HEADING_RE = /\A {0,3}(\#{1,6})(?:[ \t]+\#+[ \t]*|[ \t]+(.*?)(?:[ \t]+\#+)?[ \t]*|[ \t]*)\z/.freeze

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
    THEMATIC_BREAK_RE = /\A {0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})\z/.freeze

    def thematic_break?(text)
      THEMATIC_BREAK_RE.match?(text)
    end

    def blockquote_line?(text)
      text.match?(/\A {0,3}>/)
    end

    def strip_blockquote_prefix(line)
      content = line.content
      bytes = content.bytesize
      i = 0
      abs_col = 0
      # Up to 3 spaces of indent before `>`.
      while i < 3 && i < bytes && content.getbyte(i) == 0x20
        i += 1
        abs_col += 1
      end
      unless i < bytes && content.getbyte(i) == 0x3E
        return Line.new(content: content,
                        start_byte: line.start_byte,
                        end_byte: line.end_byte,
                        blank: !content.match?(/\S/))
      end
      i += 1
      abs_col += 1  # consume `>`

      # Count column width of leading whitespace after `>` using
      # absolute-column tracking so a tab right after `>` (at col 1)
      # is correctly billed as only 3 columns of indent, not 4.
      ws_start_col = abs_col
      j = i
      while j < bytes
        b = content.getbyte(j)
        if b == 0x20
          abs_col += 1
        elsif b == 0x09
          abs_col = (abs_col / 4 + 1) * 4
        else
          break
        end
        j += 1
      end
      ws_cols = abs_col - ws_start_col

      if ws_cols >= 1
        tail = (" " * (ws_cols - 1)) + content.byteslice(j..)
        offset = j
      else
        tail = content.byteslice(i..)
        offset = i
      end

      Line.new(
        content: tail,
        start_byte: line.start_byte + offset,
        end_byte: line.end_byte,
        blank: !tail.match?(/\S/)
      )
    end

    # Recognises the start of a list item per CommonMark spec section 5.2.
    #
    # Returns nil if `text` is not a list-item start, otherwise a Hash:
    #
    #   ordered:        true (1.  / 1)) or false (- / + / *)
    #   start_number:   Integer (0 for unordered)
    #   marker:         String, the marker character (".", ")", "-", "+", "*")
    #   content:        String, the body of the line as it should appear
    #                   inside the item (may include leading whitespace
    #                   when the marker was followed by 5+ spaces -- that
    #                   is the indented-code form).
    #   content_start:  Integer, byte offset into `text` where `content`
    #                   begins. Always (leading + marker_width + 1) in
    #                   absolute terms, regardless of spec form.
    #   content_indent: Integer, the spec's N -- the indent level all
    #                   subsequent continuation lines must reach to stay
    #                   inside this item.
    #
    # CommonMark form selection:
    #   - W spaces after the marker, where 1 <= W <= 4:
    #       N = leading + marker_width + W
    #       content is the rest of the line as-is
    #   - W >= 5 (indented-code form):
    #       N = leading + marker_width + 1
    #       content keeps (W - 1) leading spaces so it parses as an
    #       indented code block inside the item
    #   - W == 0 (marker followed by EOL or blank content):
    #       N = leading + marker_width + 1
    #       content is "" (empty line)
    def list_item_start(text)
      m = /\A( {0,3})/.match(text)
      leading = m[1].length
      rest = text[leading..]

      if (bm = /\A([*+\-])(?:([ \t]+)(.*)|([ \t]*)\z)/.match(rest))
        marker = bm[1]
        if bm[2]
          # `spaces_after` is column width, not byte length, so a tab
          # after the marker is billed as the number of cols needed to
          # reach the next tab stop (CommonMark Tabs section).
          spaces_after = column_width(bm[2], leading + 1)
          body = bm[3]
        else
          spaces_after = 0
          body = ""
        end
        return build_list_match(leading, 1, marker, spaces_after, body,
                                ordered: false, start_number: 0)
      end

      if (om = /\A(\d{1,9})([.)])(?:([ \t]+)(.*)|([ \t]*)\z)/.match(rest))
        digits = om[1]
        marker = om[2]
        if om[3]
          spaces_after = column_width(om[3], leading + digits.length + 1)
          body = om[4]
        else
          spaces_after = 0
          body = ""
        end
        return build_list_match(leading, digits.length + 1, marker, spaces_after, body,
                                ordered: true, start_number: digits.to_i)
      end

      nil
    end

    # Returns the column width of `whitespace` if it begins at the
    # absolute column `start_col`, expanding tabs to the next tab stop
    # of 4. `whitespace` must contain only 0x20/0x09 bytes.
    def column_width(whitespace, start_col)
      col = start_col
      whitespace.each_byte do |b|
        if b == 0x20
          col += 1
        elsif b == 0x09
          col = (col / 4 + 1) * 4
        end
      end
      col - start_col
    end

    def build_list_match(leading, marker_width, marker, spaces_after, body, ordered:, start_number:)
      if body.empty?
        # Marker followed by EOL: empty item content.
        content_indent = leading + marker_width + 1
        content = ""
      elsif spaces_after >= 5
        # Indented-code form: keep (spaces_after - 1) of the spaces
        # in the content so the body of the item is recognised as an
        # indented code block.
        content_indent = leading + marker_width + 1
        content = (" " * (spaces_after - 1)) + body
      else
        content_indent = leading + marker_width + spaces_after
        content = body
      end

      {
        ordered: ordered,
        start_number: start_number,
        marker: marker,
        content: content,
        content_start: leading + marker_width + 1,
        content_indent: content_indent
      }
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
        info: unescape_reference_text(info),
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

      # Type 1: <script|pre|style|textarea (case-insensitive) followed by whitespace or >
      return 1 if stripped.match?(%r{\A<(script|pre|style|textarea)(?:\s|>|$)}i)

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
      %r{\A</?(?:#{HTML_BLOCK_TYPE_6_NAMES.join("|")})(?:\s|>|/>|\z)}i.freeze

    def table_start?(lines, index)
      return false if index + 1 >= lines.length
      return false unless table_row?(lines[index].content)

      separators = split_table_row(lines[index + 1].content)
      return false if separators.empty?

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
    HTML_TYPE_7_OPEN_TAG_RE = %r{
      \A
      <[A-Za-z][A-Za-z0-9-]*
      (?:\s+[A-Za-z_:][A-Za-z0-9_.:-]*(?:\s*=\s*(?:"[^"\n]*"|'[^'\n]*'|[^\s"'=<>`]+))?)*
      \s*/?>
      \z
    }x.freeze
    HTML_TYPE_7_CLOSING_TAG_RE = %r{\A</[A-Za-z][A-Za-z0-9-]*\s*>\z}.freeze

    def valid_html_tag?(text)
      # Fast reject: every type-7 tag must begin with `<`.
      return false unless text.start_with?("<")
      HTML_TYPE_7_OPEN_TAG_RE.match?(text) || HTML_TYPE_7_CLOSING_TAG_RE.match?(text)
    end

    def link_reference_definition(lines, index)
      text = lines[index].content
      # A reference label may contain `\[` / `\]` (backslash-escaped),
      # but never an unescaped `[` or `]`.
      match = /\A {0,3}\[((?:[^\\\[\]]|\\.)+)\]:(.*)\z/.match(text)
      return unless match

      label = normalize_reference_label(match[1])
      remainder = match[2].to_s
      consumed = 1

      chunks = [remainder]
      if remainder.strip.empty?
        return unless index + consumed < lines.length

        next_line = lines[index + consumed]
        return if next_line.blank

        chunks << next_line.content
        consumed += 1
      end

      destination, rest = parse_reference_destination(chunks.shift.to_s)
      if destination.nil?
        destination, rest = parse_reference_destination(chunks.first.to_s)
        return unless destination

        chunks.shift
      end

      title_source = rest.to_s
      consumed_before_title = consumed
      title_on_separate_line = false
      if title_source.strip.empty? && index + consumed < lines.length
        next_line = lines[index + consumed]
        if next_line && potential_reference_title_start?(next_line.content)
          title_source = next_line.content
          consumed += 1
          title_on_separate_line = true
        end
      end

      while index + consumed < lines.length && title_needs_more_lines?(title_source)
        next_line = lines[index + consumed]
        break if next_line.blank

        title_source = title_source.empty? ? next_line.content : "#{title_source}\n#{next_line.content}"
        consumed += 1
      end

      title, trailing = parse_reference_title(title_source)
      if trailing && trailing.match?(/\S/)
        # Title parse failed with garbage after the closer.
        if title_on_separate_line
          # The title was pulled from a follow-up line; back off so
          # that line is reparsed as ordinary content and the def is
          # still accepted (sans title).
          consumed = consumed_before_title
          title = nil
        else
          # Title was on the destination line itself; the whole def
          # is invalid.
          return
        end
      end

      {
        reference: {
          label: label,
          destination: unescape_reference_text(strip_angle_brackets(destination)),
          title: title
        },
        consumed: consumed
      }
    end

    def normalize_reference_label(label)
      # CommonMark spec: full Unicode case fold (`downcase(:fold)`),
      # not the default per-codepoint lowercase. This makes labels like
      # `ẞ` (U+1E9E) match a definition of `SS` because the case-fold
      # of `ẞ` is `ss`.
      label.to_s.strip.downcase(:fold).gsub(/[ \t\r\n]+/, " ")
    end

    def strip_angle_brackets(destination)
      destination.start_with?("<") && destination.end_with?(">") ? destination[1...-1] : destination
    end

    def parse_reference_destination(text)
      source = text.to_s.lstrip
      return [nil, nil] if source.empty?

      if source.start_with?("<")
        close = source.index(">")
        if close
          tail = source[(close + 1)..].to_s
          if tail.empty? || tail.match?(/\A[ \t\r\n]/)
            return [source[0..close], tail]
          end
        end
        # Raw destinations cannot start with `<`, so once the angle
        # form fails there is no fallback.
        return [nil, nil]
      end

      match = /\A(\S+)(.*)\z/m.match(source)
      return [nil, nil] unless match

      [match[1], match[2].to_s]
    end

    def title_needs_more_lines?(text)
      stripped = text.to_s.lstrip
      return false if stripped.empty?

      quote = stripped[0]
      closer = reference_title_closer(quote)
      return false unless closer
      return false if stripped.length > 1 && stripped.end_with?(closer)

      true
    end

    def potential_reference_title_start?(text)
      %w[" ' (].include?(text.to_s.lstrip[0])
    end

    def parse_reference_title(text)
      stripped = text.to_s.lstrip
      return [nil, stripped] if stripped.empty?

      opener = stripped[0]
      closer = reference_title_closer(opener)
      return [nil, stripped] unless closer

      body = +""
      escaped = false
      index = 1
      while index < stripped.length
        char = stripped[index]
        if char == "\\" && !escaped
          escaped = true
          body << char
        elsif char == closer && !escaped
          trailing = stripped[(index + 1)..].to_s
          return [unescape_reference_text(body), trailing]
        else
          body << char
          escaped = false
        end
        index += 1
      end

      [nil, stripped]
    end

    def reference_title_closer(opener)
      { '"' => '"', "'" => "'", "(" => ")" }[opener]
    end

    def unescape_reference_text(text)
      out = text.gsub(/\\([!-\/:-@\[-`{-~])/, "\\1")
      out.gsub(/&(?:[A-Za-z][A-Za-z0-9]+|#\d+|#[xX][0-9A-Fa-f]+);/) do |m|
        if m.start_with?("&#")
          decoded = CGI.unescapeHTML(m)
          decoded.tr("\u0000", "\uFFFD")
        else
          encoded = Inline::HTML_ENTITIES[m[1..-2]]
          encoded ? encoded.dup.force_encoding(Encoding::UTF_8) : m
        end
      end
    end

    def store_reference(reference)
      @references[reference[:label]] ||= {
        destination: reference[:destination],
        title: reference[:title]
      }
    end

    def span_len(line)
      line.end_byte - line.start_byte
    end
  end
end
