# frozen_string_literal: true

module Mdarena
  class BlockParser
    Line = Struct.new(:content, :start_byte, :end_byte, :blank, keyword_init: true)
    ItemLine = Struct.new(:content, :start_byte, :end_byte, :blank, :continuation, keyword_init: true)

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
      while index < lines.length
        line = lines[index]
        break if !line.blank && !blockquote_line?(line.content)

        block_lines << strip_blockquote_prefix(line)
        index += 1
      end

      block_id = @arena.add_node(NodeType::BLOCKQUOTE,
                                 source_start: block_lines.first.start_byte,
                                 source_len: block_lines.last.end_byte - block_lines.first.start_byte)
      @arena.append_child(parent_id, block_id)
      parse_lines(block_id, block_lines, transformed: true)
      index
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
        match = list_item_start(lines[index].content)
        break unless match
        break unless same_list_group?(first_match, match)

        item_lines, index = collect_list_item(lines, index, match)
        end_byte = item_lines.last.end_byte
        loose ||= item_lines.any?(&:blank)
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
      line = lines[index]
      item_lines << ItemLine.new(
        content: match[:content],
        start_byte: line.start_byte + match[:content_start],
        end_byte: line.end_byte,
        blank: match[:content].strip.empty?,
        continuation: false
      )
      index += 1

      while index < lines.length
        current = lines[index]
        if current.blank
          next_line = lines[index + 1]
          break unless next_line && blank_line_continues_item?(next_line.content)

          item_lines << ItemLine.new(
            content: "",
            start_byte: current.start_byte,
            end_byte: current.end_byte,
            blank: true,
            continuation: true
          )
          index += 1
          next
        end
        break if list_item_start(current.content)
        break unless continuation_line?(current.content, match[:padding])

        continuation = current.content.sub(/\A {0,#{match[:padding]}}\s?/, "")
        current_start = current.start_byte + [current.content.index(continuation) || 0, current.content.length].min
        item_lines << ItemLine.new(
          content: continuation,
          start_byte: current_start,
          end_byte: current.end_byte,
          blank: continuation.strip.empty?,
          continuation: true
        )
        index += 1
      end

      [item_lines, index]
    end

    def continuation_line?(text, padding)
      text.match?(/\A {1,#{[padding, 4].max}}/)
    end

    def blank_line_continues_item?(text)
      spaces = text[/\A */].length
      spaces.positive? && spaces < 4
    end

    def same_list_group?(expected, actual)
      expected[:ordered] == actual[:ordered] && expected[:marker] == actual[:marker]
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

      code = content_lines.map(&:content).join("\n")
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
      code_lines = []
      while index < lines.length
        line = lines[index]
        break unless line.blank || indented_code_line?(line.content)

        code_lines << (line.blank ? "" : line.content.sub(/\A {4}/, ""))
        index += 1
      end

      start_byte = lines[index - code_lines.length].start_byte
      end_byte = lines[index - 1].end_byte
      code = code_lines.join("\n")
      code << "\n" unless code_lines.empty? || lines[index - 1].blank

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
      while index < lines.length
        line = lines[index]
        break if line.blank
        break if index > start_index && paragraph_interrupt?(lines, index)
        # NOTE: Per CommonMark, a `[label]: ...` line cannot start a
        # link reference definition inside an open paragraph — it's
        # absorbed as paragraph continuation. The dispatch in
        # parse_lines catches definitions that appear after a blank
        # line, so we don't need another scan here.
        paragraph_lines << line
        index += 1
      end

      text = paragraph_lines.map(&:content).join("\n")
      start_byte = paragraph_lines.first.start_byte
      end_byte = paragraph_lines.last.end_byte
      paragraph_id = @arena.add_node(NodeType::PARAGRAPH,
                                     source_start: start_byte,
                                     source_len: end_byte - start_byte,
                                     str1: transformed ? text : nil)
      @arena.append_child(parent_id, paragraph_id)
      index
    end

    def paragraph_interrupt?(lines, index)
      line = lines[index]
      index > 0 && (
        atx_heading(line.content) ||
        thematic_break?(line.content) ||
        fenced_code_start(line.content) ||
        html_block_start?(line.content) ||
        blockquote_line?(line.content) ||
        list_item_start(line.content) ||
        table_start?(lines, index)
      )
    end

    def build_lines(source)
      lines = []
      offset = 0
      source.each_line do |line|
        raw = line.end_with?("\n") ? line[0...-1] : line
        lines << Line.new(
          content: raw,
          start_byte: offset,
          end_byte: offset + raw.bytesize,
          blank: raw.strip.empty?
        )
        offset += line.bytesize
      end
      lines
    end

    def atx_heading(text)
      match = /\A {0,3}(#{Regexp.escape('#')}{1,6})[ \t]+(.*?)[ \t]*#*[ \t]*\z/.match(text)
      return unless match

      content_index = text.index(match[2]) || text.bytesize
      { level: match[1].length, content: match[2], content_start: content_index }
    end

    def thematic_break?(text)
      stripped = text.strip
      stripped.match?(/\A(?:\*\s*){3,}\z|\A(?:-\s*){3,}\z|\A(?:_\s*){3,}\z/)
    end

    def blockquote_line?(text)
      text.match?(/\A {0,3}>/)
    end

    def strip_blockquote_prefix(line)
      match = /\A( {0,3}> ?)(.*)\z/.match(line.content)
      content = match ? match[2] : line.content
      prefix_len = match ? match[1].bytesize : 0
      Line.new(
        content: content,
        start_byte: line.start_byte + prefix_len,
        end_byte: line.end_byte,
        blank: content.strip.empty?
      )
    end

    def list_item_start(text)
      match = /\A( {0,3})([*+-])\s+(.*)\z/.match(text)
      if match
        return {
          ordered: false,
          start_number: 0,
          marker: match[2],
          content: match[3],
          content_start: match[1].bytesize + 2,
          padding: match[1].bytesize + 2
        }
      end

      match = /\A( {0,3})(\d+)([.)])\s+(.*)\z/.match(text)
      return unless match

      {
        ordered: true,
        start_number: match[2].to_i,
        marker: match[3],
        content: match[4],
        content_start: match[1].bytesize + match[2].bytesize + match[3].bytesize + 1,
        padding: match[1].bytesize + match[2].bytesize + match[3].bytesize + 1
      }
    end

    def fenced_code_start(text)
      match = /\A {0,3}(`{3,}|~{3,})[ \t]*(.*?)\s*\z/.match(text)
      return unless match

      { char: match[1][0], count: match[1].length, info: match[2] }
    end

    def fenced_code_close?(text, char, count)
      text.match?(/\A {0,3}#{Regexp.escape(char * count)}#{Regexp.escape(char)}*[ \t]*\z/)
    end

    def indented_code_line?(text)
      text.start_with?("    ")
    end

    def html_block_start?(text)
      # Indented code block takes precedence (4+ spaces)
      return false if text.start_with?("    ")
      !html_block_type(text).nil?
    end

    def html_block_type(text)
      stripped = text.lstrip
      return nil if stripped.empty?

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

      # Type 6 & 7: Valid HTML tags
      return 7 if valid_html_tag?(stripped)

      nil
    end

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

    def valid_html_tag?(text)
      text.match?(%r{\A</?[A-Za-z][A-Za-z0-9-]*(?:\s+[A-Za-z_:][A-Za-z0-9_.:-]*(?:\s*=\s*(?:"[^"\n]*"|'[^'\n]*'|[^\s"'=<>`]+))?)*\s*/?>\z}) ||
        text.match?(%r{\A<[A-Za-z][A-Za-z0-9-]*(?:\s+[A-Za-z_:][A-Za-z0-9_.:-]*(?:\s*=\s*(?:"[^"\n]*"|'[^'\n]*'|[^\s"'=<>`]+))?)*>.*</[A-Za-z][A-Za-z0-9-]*>\z})
    end

    def link_reference_definition(lines, index)
      text = lines[index].content
      match = /\A {0,3}\[([^\]]+)\]:(.*)\z/.match(text)
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
      if title_source.strip.empty? && index + consumed < lines.length
        next_line = lines[index + consumed]
        if next_line && potential_reference_title_start?(next_line.content)
          title_source = next_line.content
          consumed += 1
        end
      end

      while index + consumed < lines.length && title_needs_more_lines?(title_source)
        next_line = lines[index + consumed]
        break if next_line.blank

        title_source = title_source.empty? ? next_line.content : "#{title_source}\n#{next_line.content}"
        consumed += 1
      end

      title, trailing = parse_reference_title(title_source)
      return if trailing && trailing.match?(/\S/)

      {
        reference: {
          label: label,
          destination: strip_angle_brackets(destination),
          title: title
        },
        consumed: consumed
      }
    end

    def normalize_reference_label(label)
      label.to_s.strip.downcase.gsub(/[ \t\r\n]+/, " ")
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
          # CommonMark: when the closing `>` is followed by whitespace or
          # EOL, this is a clean angle-bracketed destination. Otherwise
          # (e.g. `<bar>(baz)`) the spec wants the whole token to fall
          # through to a raw-destination interpretation that also strips
          # any internal angle brackets — currently unsupported, see
          # KNOWN_GAPS #182.
          if tail.empty? || tail.match?(/\A[ \t\r\n]/)
            return [source[0..close], tail]
          end
        end
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
      text.gsub(/\\(.)/, "\\1")
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
