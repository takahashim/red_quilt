# frozen_string_literal: true

module RedQuilt
  module Inline
    # Consumes a token stream produced by Lexer and adds inline nodes
    # to the arena under parent_id.
    #
    # Processing happens in two phases:
    #   1. linear_pass — code spans, brackets (link/image), autolinks,
    #      HTML, simple inlines. Emphasis delimiter runs are added as
    #      provisional TEXT nodes and pushed onto a delimiter stack.
    #   2. EmphasisResolver#resolve — CommonMark spec 6.2 algorithm pairs
    #      up delimiter stack entries into EMPHASIS / STRONG nodes
    #      (delegated to Inline::EmphasisResolver).
    class Builder
      Bracket = Struct.new(:token_id, :node_id, :image, :active, :delim_stack_size)

      # track_source: when true, arena nodes carry the byte ranges supplied
      # by the lexer. When false (used for inputs whose source has been
      # materialized into a separate string, e.g. transformed blockquote
      # lines), source_start/source_len are not recorded; in that mode every
      # text node carries its content in str1 so Arena#text still works.
      #
      # diagnostics: an optional Array the builder appends warnings to
      # (unsafe URL schemes, missing references, ...). The caller — usually
      # InlinePass — is expected to forward Document#diagnostics here.
      def initialize(arena, source, references, track_source: true, diagnostics: nil, footnotes: nil)
        @arena = arena
        @source = source
        # Binary view of the source for String#byteindex hot paths:
        # byteindex on a UTF-8 string raises when the byte offset falls
        # inside a multibyte sequence; the binary view treats every byte
        # as its own character.
        @source_b = source.b
        @references = references
        @track_source = track_source
        @diagnostics = diagnostics
        @footnotes = footnotes
        @link_scanner = LinkScanner.new(source)
        @emphasis = EmphasisResolver.new(arena, track_source: track_source)
      end

      def build(parent_id, tokens)
        @parent_id = parent_id
        @tokens = tokens
        @delimiter_stack = []
        @bracket_stack = []
        @provisional_nodes = {}
        linear_pass
        @emphasis.resolve(@delimiter_stack, @provisional_nodes)
      end

      private

      # --------------------------- node helpers ---------------------------

      def add_arena_node(type, start_byte, end_byte, str1: nil, str2: nil, int1: 0, int2: 0)
        if @track_source
          @arena.add_node(type,
                          source_start: start_byte,
                          source_len: end_byte - start_byte,
                          str1: str1, str2: str2, int1: int1, int2: int2)
        else
          @arena.add_node(type, source_start: -1, source_len: 0,
                                str1: str1, str2: str2, int1: int1, int2: int2)
        end
      end

      def update_arena_span(node_id, start_byte, end_byte)
        return unless @track_source

        @arena.update_span(node_id, start_byte, end_byte)
      end

      # --------------------------- linear pass ----------------------------

      def linear_pass
        id = 0
        last = @tokens.length
        while id < last
          case @tokens.kind(id)
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
            append_text(@tokens.start_byte(id), @tokens.end_byte(id), nil)
          when TokenKind::LBRACKET
            push_bracket(id, image: false)
          when TokenKind::BANG_LBRACKET
            push_bracket(id, image: true)
          when TokenKind::RBRACKET
            next_id = resolve_rbracket(id, id + 1)
            if next_id
              id = next_id
              next
            end
          when TokenKind::DELIM_RUN
            push_delim_run(id)
          end
          id += 1
        end
      end

      # ---------------------------- text ----------------------------------

      def append_text(start_byte, end_byte, literal)
        materialized = if literal
                         literal
                       elsif !@track_source
                         @source.byteslice(start_byte, end_byte - start_byte).to_s
                       end

        last = @arena.raw_last_child_id(@parent_id)
        if last != -1 && @arena.type(last) == NodeType::TEXT &&
           !@provisional_nodes[last] && can_coalesce?(last, start_byte)
          coalesce_text(last, materialized, start_byte, end_byte)
          return
        end

        node = add_arena_node(NodeType::TEXT, start_byte, end_byte, str1: materialized)
        @arena.append_child(@parent_id, node)
      end

      def can_coalesce?(last_id, start_byte)
        if @track_source
          @arena.source_end(last_id) == start_byte
        else
          !@arena.str1(last_id).nil?
        end
      end

      def coalesce_text(last_id, materialized, start_byte, end_byte)
        if @track_source
          last_lit = @arena.str1(last_id)
          if materialized.nil? && last_lit.nil?
            update_arena_span(last_id, @arena.source_start(last_id), end_byte)
            return
          end
          existing = last_lit || @arena.text(last_id).to_s
          incoming = materialized || @source.byteslice(start_byte, end_byte - start_byte).to_s
          @arena.update_str1(last_id, existing + incoming)
          update_arena_span(last_id, @arena.source_start(last_id), end_byte)
        else
          @arena.update_str1(last_id, @arena.str1(last_id) + materialized.to_s)
        end
      end

      # --------------------------- line endings ---------------------------

      def append_line_ending(id)
        start_byte = @tokens.start_byte(id)
        end_byte = @tokens.end_byte(id)
        trailing_spaces = @tokens.int1(id)
        backslash_form = @tokens.int2(id) == 1

        if trailing_spaces >= 2 || backslash_form
          strip_trailing_spaces(trailing_spaces) if trailing_spaces.positive?
          kind = NodeType::HARDBREAK
        else
          # Soft line break: spec also strips trailing spaces from the
          # previous line so a single trailing space doesn't survive into
          # the output.
          strip_trailing_spaces(trailing_spaces) if trailing_spaces.positive?
          kind = NodeType::SOFTBREAK
        end

        @arena.append_child(@parent_id,
                            add_arena_node(kind, start_byte, end_byte, str1: "\n"))
      end

      def strip_trailing_spaces(count)
        last = @arena.raw_last_child_id(@parent_id)
        return if last == -1 || @arena.type(last) != NodeType::TEXT

        lit = @arena.str1(last)
        if lit
          new_lit = lit.sub(/ {#{count},}\z/, "")
          @arena.update_str1(last, new_lit)
        end

        return unless @track_source

        new_len = @arena.source_len(last) - count
        new_len = 0 if new_len.negative?
        @arena.update_span(last,
                           @arena.source_start(last),
                           @arena.source_start(last) + new_len)
      end

      # --------------------------- HTML / autolink ------------------------

      def append_html_inline(id)
        node = add_arena_node(
          NodeType::HTML_INLINE,
          @tokens.start_byte(id), @tokens.end_byte(id),
          str1: @tokens.str1(id),
        )
        @arena.append_child(@parent_id, node)
      end

      def append_autolink(id, destination, label)
        link_id = add_arena_node(
          NodeType::LINK,
          @tokens.start_byte(id), @tokens.end_byte(id),
          str1: UrlSanitizer.block_unsafe_autolink(@link_scanner.normalize_uri(destination), @diagnostics),
        )
        @arena.append_child(@parent_id, link_id)
        @arena.append_child(link_id, @arena.add_node(NodeType::TEXT, str1: label))
      end

      # --------------------------- code spans -----------------------------

      # Find the closing backtick run for a code span by scanning the
      # source bytes directly. CommonMark: backslash escapes do not
      # apply inside a code span, so once we're past the opener every
      # backtick run is a real candidate (token-level ESCAPED_CHAR is
      # ignored). byteindex jumps over non-backtick byte stretches at
      # C speed.
      def resolve_code_span(opener_id)
        run_len = @tokens.int1(opener_id)
        pos = @tokens.end_byte(opener_id)
        bytesize = @source_b.bytesize
        while pos < bytesize
          run_start = @source_b.byteindex(BACKTICK_BYTE, pos)
          break if run_start.nil?

          pos = run_start + 1
          pos += 1 while pos < bytesize && @source_b.getbyte(pos) == 0x60
          if pos - run_start == run_len
            emit_code_span_bytes(opener_id, run_start, pos)
            return next_token_after(pos, opener_id + 1)
          end
        end
        nil
      end

      BACKTICK_BYTE = "`".b.freeze

      def emit_code_span_bytes(opener_id, closer_start_byte, closer_end_byte)
        body_start = @tokens.end_byte(opener_id)
        body_end = closer_start_byte
        span_start = @tokens.start_byte(opener_id)
        span_end = closer_end_byte
        raw = @source.byteslice(body_start, body_end - body_start).to_s
        node = add_arena_node(NodeType::CODE_SPAN, span_start, span_end,
                              str1: normalize_code_span(raw))
        @arena.append_child(@parent_id, node)
      end

      def normalize_code_span(text)
        text = text.tr("\n", " ")
        if text.length >= 2 && text.start_with?(" ") && text.end_with?(" ") && text.match?(/[^ ]/)
          text = text[1..-2]
        end
        text
      end

      # --------------------------- brackets -------------------------------

      def push_bracket(token_id, image:)
        text = image ? "![" : "["
        node_id = add_arena_node(
          NodeType::TEXT,
          @tokens.start_byte(token_id), @tokens.end_byte(token_id),
          str1: text,
        )
        @arena.append_child(@parent_id, node_id)
        @provisional_nodes[node_id] = true
        @bracket_stack << Bracket.new(token_id, node_id, image, true, @delimiter_stack.length)
      end

      def resolve_rbracket(rbracket_token_id, search_from_id)
        # CommonMark spec algorithm: peek the TOP of the bracket stack
        # (don't search past inactive brackets). If the top opener is
        # inactive, pop it and turn `]` into text — an inactive `[`
        # earlier in the input must not be jumped over to reach an
        # outer `[` or `![`, otherwise nested-image precedence (spec
        # example 520) resolves the wrong way.
        if @bracket_stack.empty?
          append_text(@tokens.start_byte(rbracket_token_id),
                      @tokens.end_byte(rbracket_token_id), "]")
          return nil
        end

        opener_index = @bracket_stack.length - 1
        unless @bracket_stack[opener_index].active
          @bracket_stack.pop
          append_text(@tokens.start_byte(rbracket_token_id),
                      @tokens.end_byte(rbracket_token_id), "]")
          return nil
        end

        opener = @bracket_stack[opener_index]
        rbracket_end = @tokens.end_byte(rbracket_token_id)

        # Footnote references (`[^label]`) take precedence over link forms.
        if @footnotes && !opener.image && (footnote = try_footnote_reference(opener, rbracket_token_id))
          finalize_footnote(opener, opener_index, footnote, rbracket_end)
          return next_token_after(rbracket_end, search_from_id)
        end

        match = @link_scanner.inline_link(rbracket_end) ||
                try_reference_link(opener, rbracket_token_id, rbracket_end)
        unless match
          @bracket_stack.delete_at(opener_index)
          append_text(@tokens.start_byte(rbracket_token_id),
                      @tokens.end_byte(rbracket_token_id), "]")
          return nil
        end

        finalize_link(opener, opener_index, match)
        next_token_after(match[:end_byte], search_from_id)
      end

      def try_reference_link(opener, rbracket_token_id, start_byte)
        label_start = @tokens.end_byte(opener.token_id)
        label_end = @tokens.start_byte(rbracket_token_id)
        text_label = @source.byteslice(label_start, label_end - label_start).to_s
        return nil if ReferenceDefinition.label_too_long?(text_label)

        if start_byte < @source.bytesize && @source.getbyte(start_byte) == 0x5B
          ref_label, after_byte = @link_scanner.reference_label(start_byte)
          return nil unless after_byte

          lookup = ref_label.empty? ? text_label : ref_label
          normalized = ReferenceDefinition.normalize_label(lookup)
          ref = @references[normalized]
          unless ref
            # Full reference `[text][ref]` with a missing definition is
            # usually a typo worth surfacing.
            report_diagnostic(
              severity: :warning,
              rule: :missing_reference,
              message: "Reference #{normalized.inspect} is not defined",
            )
            return nil
          end
          return {
            end_byte: after_byte,
            destination: @link_scanner.normalize_uri(ref[:destination].to_s),
            title: ref[:title],
          }
        end

        ref = @references[ReferenceDefinition.normalize_label(text_label)]
        return nil unless ref

        {
          end_byte: start_byte,
          destination: @link_scanner.normalize_uri(ref[:destination].to_s),
          title: ref[:title],
        }
      end

      def finalize_link(opener, opener_index, match)
        opener_start = @tokens.start_byte(opener.token_id)
        link_kind = opener.image ? NodeType::IMAGE : NodeType::LINK
        link_id = add_arena_node(
          link_kind, opener_start, match[:end_byte],
          str1: UrlSanitizer.sanitize_destination(match[:destination], @diagnostics),
          str2: match[:title],
        )

        @arena.insert_before(@parent_id, opener.node_id, link_id)

        first_inside = @arena.raw_next_sibling_id(opener.node_id)
        last_inside = @arena.raw_last_child_id(@parent_id)
        if first_inside != -1 && last_inside != -1 && first_inside != link_id
          @arena.reparent(link_id, first_inside, last_inside)
        end

        @provisional_nodes.delete(opener.node_id)
        @arena.detach(opener.node_id)

        inner_delims = @delimiter_stack.slice!(opener.delim_stack_size..) || []
        @emphasis.resolve(inner_delims, @provisional_nodes)

        @bracket_stack.delete_at(opener_index)

        unless opener.image
          @bracket_stack.each { |b| b.active = false unless b.image }
        end
      end

      # A footnote reference is a non-image bracket whose inner text is
      # `^label` (label non-empty, no whitespace or `]`). Returns
      # { label:, number:, occurrence: } when the label has a registered
      # definition, else nil (so the bracket falls back to link logic).
      FOOTNOTE_REF_RE = /\A\^([^\]\s]+)\z/

      def try_footnote_reference(opener, rbracket_token_id)
        inner_start = @tokens.end_byte(opener.token_id)
        inner_end = @tokens.start_byte(rbracket_token_id)
        match = FOOTNOTE_REF_RE.match(@source.byteslice(inner_start, inner_end - inner_start).to_s)
        return nil unless match

        label = ReferenceDefinition.normalize_label(match[1])
        number, occurrence = @footnotes.reference(label)
        return nil unless number

        { label: label, number: number, occurrence: occurrence }
      end

      def finalize_footnote(opener, opener_index, footnote, rbracket_end)
        opener_start = @tokens.start_byte(opener.token_id)
        fn_id = add_arena_node(
          NodeType::FOOTNOTE_REFERENCE, opener_start, rbracket_end,
          str1: footnote[:label], int1: footnote[:number], int2: footnote[:occurrence],
        )
        @arena.insert_before(@parent_id, opener.node_id, fn_id)

        # Drop the provisional `[` node and the inner `^label` text node(s);
        # the footnote reference replaces them entirely.
        cursor = opener.node_id
        while cursor != -1
          nxt = @arena.raw_next_sibling_id(cursor)
          @provisional_nodes.delete(cursor)
          @arena.detach(cursor)
          cursor = nxt
        end

        # Discard any delimiters opened inside the (literal) label.
        @delimiter_stack.slice!(opener.delim_stack_size..)
        @bracket_stack.delete_at(opener_index)
      end

      def next_token_after(byte_offset, from_id)
        id = from_id
        last = @tokens.length
        while id < last
          s = @tokens.start_byte(id)
          e = @tokens.end_byte(id)
          if s >= byte_offset
            return id
          elsif e > byte_offset
            # A multi-byte token (HTML inline, autolink, ...) overlaps
            # the boundary of an earlier-resolved code span / link. The
            # part inside the resolved span is already consumed; surface
            # the tail bytes as plain text so they aren't silently lost.
            append_text(byte_offset, e, nil)
            return id + 1
          end

          id += 1
        end
        last
      end

      def report_diagnostic(severity:, rule:, message:, source_span: nil)
        return unless @diagnostics

        @diagnostics << Diagnostic.new(
          severity: severity, rule: rule, message: message, source_span: source_span,
        )
      end

      # --------------------------- delim runs / emphasis ------------------

      def push_delim_run(token_id)
        char_byte = @tokens.int1(token_id)
        count = @tokens.int2(token_id)
        flags = @tokens.int3(token_id)

        char = Inline::BYTE_CHR[char_byte]
        text = char * count
        node_id = add_arena_node(
          NodeType::TEXT,
          @tokens.start_byte(token_id), @tokens.end_byte(token_id),
          str1: text,
        )
        @arena.append_child(@parent_id, node_id)
        @provisional_nodes[node_id] = true

        @delimiter_stack << EmphasisResolver::Delimiter.new(
          node_id, char, count,
          (flags & 0b10) != 0,
          (flags & 0b01) != 0,
        )
      end
    end
  end
end
