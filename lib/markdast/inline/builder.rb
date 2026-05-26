# frozen_string_literal: true

module Markdast
  module Inline
    # Consumes a token stream produced by Lexer and adds inline nodes
    # to the arena under parent_id.
    #
    # Processing happens in two phases:
    #   1. linear_pass — code spans, brackets (link/image), autolinks,
    #      HTML, simple inlines. Emphasis delimiter runs are added as
    #      provisional TEXT nodes and pushed onto a delimiter stack.
    #   2. process_emphasis — CommonMark spec 6.2 algorithm pairs up
    #      delimiter stack entries into EMPHASIS / STRONG nodes.
    class Builder
      def initialize(arena, source, references)
        @arena = arena
        @source = source
        @references = references
      end

      SAFE_SCHEMES = %w[http https mailto ftp tel ssh].freeze

      def build(parent_id, tokens)
        @parent_id = parent_id
        @tokens = tokens
        @delimiter_stack = []
        @bracket_stack = []
        linear_pass
        process_emphasis
      end

      private

      def linear_pass
        id = 0
        last = @tokens.length
        while id < last
          kind = @tokens.kind(id)
          case kind
          when TokenKind::TEXT
            append_text(@tokens.start_byte(id), @tokens.end_byte(id), nil)
          when TokenKind::ENTITY, TokenKind::ESCAPED_CHAR
            append_text(@tokens.start_byte(id), @tokens.end_byte(id), @tokens.str1(id))
          when TokenKind::LINE_ENDING
            append_line_ending(id)
          when TokenKind::HTML_INLINE
            append_html_inline(id)
          when TokenKind::AUTOLINK_URI
            append_autolink(id, @tokens.str1(id), @tokens.str1(id))
          when TokenKind::AUTOLINK_EMAIL
            email = @tokens.str1(id)
            append_autolink(id, "mailto:#{email}", email)
          when TokenKind::CODE_DELIMITER
            next_id = resolve_code_span(id)
            if next_id
              id = next_id
              next
            end
            # No matching closer: the backtick run is plain text.
            append_text(@tokens.start_byte(id), @tokens.end_byte(id), nil)
          when TokenKind::LBRACKET
            push_bracket(id, image: false)
          when TokenKind::BANG_LBRACKET
            push_bracket(id, image: true)
          when TokenKind::RBRACKET
            next_id = resolve_rbracket(id)
            if next_id
              id = next_id
              next
            end
          else
            # DELIM_RUN is handled in commit 8.
          end
          id += 1
        end
      end

      def push_bracket(token_id, image:)
        start_byte = @tokens.start_byte(token_id)
        end_byte = @tokens.end_byte(token_id)
        text = image ? "![" : "["
        node_id = @arena.add_node(
          NodeType::TEXT,
          source_start: start_byte,
          source_len: end_byte - start_byte,
          str1: text
        )
        @arena.append_child(@parent_id, node_id)
        @bracket_stack << {
          token_id: token_id,
          node_id: node_id,
          image: image,
          active: true
        }
      end

      # Returns the next token id to resume at, or nil to let the caller
      # advance by one (treating `]` as plain text).
      def resolve_rbracket(rbracket_token_id)
        opener_index = nil
        i = @bracket_stack.length - 1
        while i >= 0
          if @bracket_stack[i][:active]
            opener_index = i
            break
          end
          i -= 1
        end

        unless opener_index
          append_text(@tokens.start_byte(rbracket_token_id),
                      @tokens.end_byte(rbracket_token_id), "]")
          return nil
        end

        opener = @bracket_stack[opener_index]
        rbracket_end = @tokens.end_byte(rbracket_token_id)

        match = try_inline_link(rbracket_end) ||
                try_reference_link(opener, rbracket_token_id, rbracket_end)
        unless match
          @bracket_stack.delete_at(opener_index)
          append_text(@tokens.start_byte(rbracket_token_id),
                      @tokens.end_byte(rbracket_token_id), "]")
          return nil
        end

        finalize_link(opener, opener_index, rbracket_token_id, match)
        next_token_after(match[:end_byte])
      end

      # Looks at @source starting just after the `]`. If it begins with `(`,
      # parses `(destination[ "title"])` and returns
      #   { end_byte:, destination:, title: }
      # otherwise nil.
      def try_inline_link(start_byte)
        return nil if start_byte >= @source.bytesize
        return nil unless @source.getbyte(start_byte) == 0x28 # (

        body_start = start_byte + 1
        depth = 1
        index = body_start
        while index < @source.bytesize
          b = @source.getbyte(index)
          if b == 0x28
            depth += 1
          elsif b == 0x29
            depth -= 1
            break if depth.zero?
          elsif b == 0x0A
            # Inline destinations can't span paragraph breaks; rather than
            # try to be clever, treat this as no-match.
            return nil
          end
          index += 1
        end
        return nil unless depth.zero?

        body = @source.byteslice(body_start, index - body_start).to_s
        destination, title = split_destination_and_title(body)
        return nil if destination.nil? || destination.empty?

        {
          end_byte: index + 1,
          destination: destination,
          title: title
        }
      end

      # Reference forms (full / collapsed / shortcut) starting just after `]`.
      def try_reference_link(opener, rbracket_token_id, start_byte)
        label_start = @tokens.end_byte(opener[:token_id])
        label_end = @tokens.start_byte(rbracket_token_id)
        text_label = @source.byteslice(label_start, label_end - label_start).to_s

        if start_byte < @source.bytesize && @source.getbyte(start_byte) == 0x5B # [
          ref_label, after_byte = read_reference_label(start_byte)
          return nil unless after_byte
          lookup = ref_label.empty? ? text_label : ref_label
          ref = @references[normalize_reference_label(lookup)]
          return nil unless ref
          return { end_byte: after_byte, destination: ref[:destination], title: ref[:title] }
        end

        # Shortcut form: just `[label]`
        ref = @references[normalize_reference_label(text_label)]
        return nil unless ref
        { end_byte: start_byte, destination: ref[:destination], title: ref[:title] }
      end

      # Reads a `[label]` starting at start_byte. Returns [label, end_byte]
      # where end_byte is one past the closing `]`, or [nil, nil].
      def read_reference_label(start_byte)
        return [nil, nil] unless @source.getbyte(start_byte) == 0x5B

        i = start_byte + 1
        while i < @source.bytesize
          b = @source.getbyte(i)
          if b == 0x5D # ]
            return [@source.byteslice(start_byte + 1, i - start_byte - 1).to_s, i + 1]
          elsif b == 0x5C && i + 1 < @source.bytesize
            i += 2
            next
          end
          i += 1
        end
        [nil, nil]
      end

      def finalize_link(opener, opener_index, rbracket_token_id, match)
        opener_start_byte = @tokens.start_byte(opener[:token_id])
        link_kind = opener[:image] ? NodeType::IMAGE : NodeType::LINK
        link_id = @arena.add_node(
          link_kind,
          source_start: opener_start_byte,
          source_len: match[:end_byte] - opener_start_byte,
          str1: sanitize_destination(match[:destination]),
          str2: match[:title]
        )

        # Insert the new node right before the opener's provisional TEXT so
        # that any content between opener and the new node's eventual end
        # stays in document order.
        @arena.insert_before(@parent_id, opener[:node_id], link_id)

        # All content between opener[:node_id] and the parent's last_child
        # (exclusive of opener[:node_id] itself) belongs inside the link.
        first_inside = @arena.next_sibling(opener[:node_id])
        last_inside = @arena.last_child(@parent_id)
        if first_inside != -1 && last_inside != -1 && first_inside != link_id
          @arena.reparent(link_id, first_inside, last_inside)
        end

        # Drop the opener's provisional TEXT node.
        @arena.detach(opener[:node_id])

        @bracket_stack.delete_at(opener_index)

        # Per spec: once a link is formed, any earlier `[` brackets become
        # inactive so they can't open a nested link. Image brackets are
        # unaffected.
        unless opener[:image]
          @bracket_stack.each { |b| b[:active] = false unless b[:image] }
        end
      end

      def next_token_after(byte_offset)
        # Find the first token whose start_byte >= byte_offset.
        id = 0
        last = @tokens.length
        while id < last
          return id if @tokens.start_byte(id) >= byte_offset
          id += 1
        end
        last
      end

      def split_destination_and_title(body)
        match = /\A(\S+)\s+"([^"]*)"\z/.match(body)
        return [match[1], match[2]] if match
        [body.strip, nil]
      end

      def sanitize_destination(destination)
        return "" if destination.nil?
        return destination if destination.start_with?("/", "#")

        scheme = destination[%r{\A([a-zA-Z][a-zA-Z0-9+\-.]*):}, 1]
        return destination if scheme.nil?
        return destination if SAFE_SCHEMES.include?(scheme.downcase)

        ""
      end

      def normalize_reference_label(label)
        label.to_s.strip.downcase.gsub(/[ \t\r\n]+/, " ")
      end

      # Try to close the CODE_DELIMITER token at opener_id with a later
      # CODE_DELIMITER of the same run length. On success emits a CODE_SPAN
      # node and returns the token index immediately after the closer.
      # On failure returns nil so the caller can treat the opener as TEXT.
      def resolve_code_span(opener_id)
        run_len = @tokens.int1(opener_id)
        search_id = opener_id + 1
        total = @tokens.length
        while search_id < total
          if @tokens.kind(search_id) == TokenKind::CODE_DELIMITER &&
             @tokens.int1(search_id) == run_len
            emit_code_span(opener_id, search_id)
            return search_id + 1
          end
          search_id += 1
        end
        nil
      end

      def emit_code_span(opener_id, closer_id)
        body_start = @tokens.end_byte(opener_id)
        body_end = @tokens.start_byte(closer_id)
        span_start = @tokens.start_byte(opener_id)
        span_end = @tokens.end_byte(closer_id)
        raw = @source.byteslice(body_start, body_end - body_start).to_s
        node = @arena.add_node(
          NodeType::CODE_SPAN,
          source_start: span_start,
          source_len: span_end - span_start,
          str1: normalize_code_span(raw)
        )
        @arena.append_child(@parent_id, node)
      end

      # CommonMark code span normalization: newlines become spaces; if the
      # resulting string has both a leading and trailing space and at least
      # one non-space character, one of each is removed.
      def normalize_code_span(text)
        text = text.tr("\n", " ")
        if text.length >= 2 && text.start_with?(" ") && text.end_with?(" ") && text.match?(/[^ ]/)
          text = text[1..-2]
        end
        text
      end

      def process_emphasis
        # TODO(commit 8): delimiter stack resolution.
      end

      def append_text(start_byte, end_byte, literal)
        last = @arena.last_child(@parent_id)
        if last != -1 && @arena.type(last) == NodeType::TEXT &&
           adjacent?(last, start_byte) && !bracket_node?(last)
          merge_text(last, literal, start_byte, end_byte)
          return
        end

        node = @arena.add_node(
          NodeType::TEXT,
          source_start: start_byte,
          source_len: end_byte - start_byte,
          str1: literal
        )
        @arena.append_child(@parent_id, node)
      end

      # Provisional `[` / `![` TEXT nodes still living on the bracket stack
      # must not be merged with neighboring text, otherwise the link label
      # would be absorbed into the opener and lost when finalize_link
      # detaches the opener node.
      def bracket_node?(node_id)
        @bracket_stack.any? { |b| b[:node_id] == node_id }
      end

      # Two TEXT nodes can be merged when the previous one is adjacent in
      # the source (its source end == start_byte). Span-based and literal-
      # based TEXT can be combined by materializing the span side via
      # byteslice; the resulting node carries a literal str1 that covers
      # the union span.
      def adjacent?(last_id, start_byte)
        @arena.source_start(last_id) + @arena.source_len(last_id) == start_byte
      end

      def merge_text(last_id, literal, start_byte, end_byte)
        last_lit = @arena.str1(last_id)
        if literal.nil? && last_lit.nil?
          # Pure span-based merge: just extend the span.
          @arena.update_span(last_id, @arena.source_start(last_id), end_byte)
          return
        end

        materialized_last = last_lit || @arena.text(last_id).to_s
        materialized_incoming = literal || @source.byteslice(start_byte, end_byte - start_byte).to_s
        @arena.replace_str1(last_id, materialized_last + materialized_incoming)
        @arena.update_span(last_id, @arena.source_start(last_id), end_byte)
      end

      def append_line_ending(id)
        start_byte = @tokens.start_byte(id)
        end_byte = @tokens.end_byte(id)
        trailing_spaces = @tokens.int1(id)
        backslash_form = @tokens.int2(id) == 1

        if trailing_spaces >= 2 || backslash_form
          strip_trailing_spaces(trailing_spaces) if trailing_spaces.positive?
          kind = NodeType::HARDBREAK
        else
          kind = NodeType::SOFTBREAK
        end

        node = @arena.add_node(
          kind,
          source_start: start_byte,
          source_len: end_byte - start_byte,
          str1: "\n"
        )
        @arena.append_child(@parent_id, node)
      end

      # Hardbreak rule: the trailing >= 2 spaces preceding the newline are
      # not part of the rendered text, so trim them from the previous
      # TEXT node (literal or span).
      def strip_trailing_spaces(count)
        last = @arena.last_child(@parent_id)
        return if last == -1 || @arena.type(last) != NodeType::TEXT

        lit = @arena.str1(last)
        if lit
          new_lit = lit.sub(/ {#{count},}\z/, "")
          @arena.replace_str1(last, new_lit)
        end

        new_len = @arena.source_len(last) - count
        new_len = 0 if new_len.negative?
        @arena.update_span(last, @arena.source_start(last), @arena.source_start(last) + new_len)
      end

      def append_html_inline(id)
        node = @arena.add_node(
          NodeType::HTML_INLINE,
          source_start: @tokens.start_byte(id),
          source_len: @tokens.end_byte(id) - @tokens.start_byte(id),
          str1: @tokens.str1(id)
        )
        @arena.append_child(@parent_id, node)
      end

      def append_autolink(id, destination, label)
        link_id = @arena.add_node(
          NodeType::LINK,
          source_start: @tokens.start_byte(id),
          source_len: @tokens.end_byte(id) - @tokens.start_byte(id),
          str1: destination
        )
        @arena.append_child(@parent_id, link_id)
        @arena.append_child(link_id, @arena.add_node(NodeType::TEXT, str1: label))
      end
    end
  end
end
