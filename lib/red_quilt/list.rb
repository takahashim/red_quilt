# frozen_string_literal: true

module RedQuilt
  # CommonMark spec 5.2 lists.
  #
  # Module-level functions are stateless predicates used by BlockParser's
  # dispatch and paragraph-interruption logic. `List::Parser` holds a
  # cached reference to its owning BlockParser (for parse_lines recursion
  # and shared helpers) but no per-list state — a single Parser instance
  # is reused for every list in the document, including nested ones, and
  # the per-call state lives in method locals so reentrant calls are
  # safe.
  module List
    module_function

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
    def match(text)
      # Fast reject before touching the regex engine: a list item is at
      # most 3 leading spaces followed by a bullet (`* + -`) or a digit.
      # This runs on every line, so bailing here avoids a MatchData (plus
      # a `rest` substring and two marker-regex attempts) for the common
      # non-list line.
      i = 0
      i += 1 while i < 3 && text.getbyte(i) == 0x20
      c = text.getbyte(i)
      return nil if c.nil?
      return nil unless c == 0x2A || c == 0x2B || c == 0x2D || (c >= 0x30 && c <= 0x39)

      m = /\A( {0,3})/.match(text)
      leading = m[1].length
      rest = text[leading..]

      if (bm = /\A([*+-])(?:([ \t]+)(.*)|([ \t]*)\z)/.match(rest))
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
        return build_match(leading, 1, marker, spaces_after, body,
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
        return build_match(leading, digits.length + 1, marker, spaces_after, body,
                           ordered: true, start_number: digits.to_i)
      end

      nil
    end

    def same_group?(expected, actual)
      expected[:ordered] == actual[:ordered] && expected[:marker] == actual[:marker]
    end

    # CommonMark spec: a list item can only interrupt an open paragraph
    # if it has visible content, and (for ordered lists) only if the
    # start number is 1.
    def interrupts_paragraph?(li_match)
      return false if li_match[:content].empty?
      return false if li_match[:ordered] && li_match[:start_number] != 1

      true
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
          col = ((col / 4) + 1) * 4
        end
      end
      col - start_col
    end

    def build_match(leading, marker_width, marker, spaces_after, body, ordered:, start_number:)
      if body.empty?
        # Marker followed by EOL: empty item content.
        content_indent = leading + marker_width + 1
        content = ""
      elsif spaces_after >= 5
        # Indented-code form: keep (spaces_after - 1) of the spaces in
        # the content so the body of the item is recognised as an
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
        content_indent: content_indent,
      }
    end

    # Cached collaborator for BlockParser. A single instance is created
    # in BlockParser#initialize and reused for every list (including
    # nested ones) — the per-call state lives in method locals so
    # reentrant `#parse` calls are safe.
    class Parser
      def initialize(block_parser)
        @block_parser = block_parser
        @arena = block_parser.arena
      end

      def parse(parent_id, lines, index)
        first_match = List.match(lines[index].content)
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
          break if @block_parser.thematic_break?(lines[index].content)

          match = List.match(lines[index].content)
          break unless match
          break unless List.same_group?(first_match, match)

          item_lines, index = collect_item(lines, index, match)
          end_byte = item_lines.last.end_byte
          item_id = @arena.add_node(NodeType::LIST_ITEM,
                                    source_start: item_lines.first.start_byte,
                                    source_len: item_lines.last.end_byte - item_lines.first.start_byte)
          @arena.append_child(list_id, item_id)
          # CommonMark: an item is loose when "two block-level elements
          # with a blank line between them" appear at its top level.
          # parse_lines reports that directly — a blank line followed by
          # ANY block-level construct it processed at this scope. That
          # captures cases the arena walk would miss (a ref-def after a
          # blank line consumes a line but emits no arena child).
          #
          # NB: must NOT collapse into `loose ||= parse_lines(...)` — if
          # `loose` is already true from a previous iteration, `||=`
          # would skip the call and the item would never receive its
          # children.
          item_blank_between_blocks = @block_parser.parse_lines(item_id, item_lines, transformed: true)
          loose = true if item_blank_between_blocks

          blank_count = 0
          while index < lines.length && lines[index].blank
            blank_count += 1
            index += 1
          end

          next unless blank_count.positive?

          next_match = index < lines.length ? List.match(lines[index].content) : nil
          if next_match && List.same_group?(first_match, next_match)
            loose = true
          else
            # Rewind so the caller's parse_lines sees the blank line.
            # When this parse was itself processing an item's
            # continuation lines, the caller needs the blank to detect
            # "blank between block-level elements" → loose-makes-item.
            index -= blank_count
            break
          end
        end

        @arena.update_span(list_id, start_byte, end_byte)
        @arena.update_int3(list_id, loose ? 0 : 1)
        index
      end

      private

      def collect_item(lines, index, match)
        item_lines = []
        n = match[:content_indent]
        first_line = lines[index]
        item_lines << Line.new(
          match[:content],
          first_line.start_byte + match[:content_start],
          first_line.end_byte,
          match[:content].strip.empty?,
        )
        index += 1

        # If the marker line itself was empty (`-` followed by EOL) and
        # the very next line is also blank, the item is empty and ends
        # now. This matches CommonMark spec 5.2: an empty list item
        # cannot grow by absorbing arbitrary blank lines.
        if match[:content].strip.empty? && index < lines.length && lines[index].blank
          return [item_lines, index]
        end

        pending_blanks = []

        while index < lines.length
          current = lines[index]

          if current.blank
            pending_blanks << Line.new("", current.start_byte, current.end_byte, true)
            index += 1
            next
          end

          # CommonMark: continuation requires the line's leading
          # whitespace to span at least `n` columns, with tabs expanding
          # to multiples of 4.
          if Indentation.leading_columns(current.content) >= n
            item_lines.concat(pending_blanks)
            pending_blanks = []
            stripped_content = Indentation.strip_columns(current.content, n)
            # When strip_columns synthesises spaces for a partially-
            # consumed tab, the result can be longer than the original
            # bytes — pretending we "consumed bytes" then yields a bogus
            # negative offset. Keep start_byte at the original line
            # start so downstream source-range arithmetic stays
            # monotonic.
            ws_bytes = Indentation.leading_ws_bytes(current.content)
            start_advance = [ws_bytes, current.content.bytesize - stripped_content.bytesize].min
            start_advance = 0 if start_advance.negative?
            item_lines << Line.new(
              stripped_content,
              current.start_byte + start_advance,
              current.end_byte,
              false,
            )
            index += 1
            next
          end

          # Less-indented non-blank line: a new list item (any group)
          # ends this item regardless of paragraph state.
          break if List.match(current.content)

          # Otherwise it may be lazy paragraph continuation. Requires:
          #   - no pending blanks (blanks always end the paragraph that
          #     could've been continued)
          #   - the previous in-item line is non-blank paragraph content
          #   - the new line is not itself a block-level interrupter
          if pending_blanks.empty? &&
             item_lines.last && !item_lines.last.blank &&
             !@block_parser.lazy_break?(lines, index)
            # Lazy continuation lines are joined into the open paragraph;
            # their leading indentation is dropped (CommonMark spec).
            # The `lazy` flag tells parse_paragraph to absorb the line
            # even when its stripped form would otherwise look like a
            # fresh block start (e.g. `    - e` becoming `- e`).
            stripped = current.content.sub(/\A[ \t]+/, "")
            strip_len = current.content.length - stripped.length
            item_lines << Line.new(
              stripped,
              current.start_byte + strip_len,
              current.end_byte,
              false,
              true,
            )
            index += 1
            next
          end

          break
        end

        # If we stopped with held blanks (item ended at a less-indented
        # line), rewind so #parse sees the blanks and decides loose vs
        # tight.
        index -= pending_blanks.length unless pending_blanks.empty?

        [item_lines, index]
      end
    end
  end
end
