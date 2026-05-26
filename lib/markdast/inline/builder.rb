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

      def build(parent_id, tokens)
        @parent_id = parent_id
        @tokens = tokens
        @delimiter_stack = []
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
          else
            # DELIM_RUN / brackets are handled in commits 7-8.
          end
          id += 1
        end
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
           adjacent?(last, start_byte)
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
