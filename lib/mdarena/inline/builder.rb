# frozen_string_literal: true

module Mdarena
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
      SAFE_SCHEMES = %w[http https mailto ftp tel ssh].freeze

      class Delimiter
        attr_accessor :node_id, :char, :count, :can_open, :can_close

        def initialize(node_id, char, count, can_open, can_close)
          @node_id = node_id
          @char = char
          @count = count
          @can_open = can_open
          @can_close = can_close
        end
      end

      class Bracket
        attr_accessor :token_id, :node_id, :image, :active, :delim_stack_size

        def initialize(token_id, node_id, image, active, delim_stack_size)
          @token_id = token_id
          @node_id = node_id
          @image = image
          @active = active
          @delim_stack_size = delim_stack_size
        end
      end

      # track_source: when true, arena nodes carry the byte ranges supplied
      # by the lexer. When false (used for inputs whose source has been
      # materialized into a separate string, e.g. transformed blockquote
      # lines), source_start/source_len are not recorded; in that mode every
      # text node carries its content in str1 so Arena#text still works.
      def initialize(arena, source, references, track_source: true)
        @arena = arena
        @source = source
        @references = references
        @track_source = track_source
      end

      def build(parent_id, tokens)
        @parent_id = parent_id
        @tokens = tokens
        @delimiter_stack = []
        @bracket_stack = []
        @provisional_nodes = {}
        linear_pass
        process_emphasis(@delimiter_stack)
      end

      private

      # --------------------------- node helpers ---------------------------

      def add_arena_node(type, start_byte, end_byte, str1: nil, str2: nil)
        if @track_source
          @arena.add_node(type,
                          source_start: start_byte,
                          source_len: end_byte - start_byte,
                          str1: str1, str2: str2)
        else
          @arena.add_node(type, source_start: -1, source_len: 0,
                                str1: str1, str2: str2)
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
          @arena.source_start(last_id) + @arena.source_len(last_id) == start_byte
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
          @arena.replace_str1(last_id, existing + incoming)
          update_arena_span(last_id, @arena.source_start(last_id), end_byte)
        else
          @arena.replace_str1(last_id, @arena.str1(last_id) + materialized.to_s)
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
          @arena.replace_str1(last, new_lit)
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
          str1: @tokens.str1(id)
        )
        @arena.append_child(@parent_id, node)
      end

      def append_autolink(id, destination, label)
        link_id = add_arena_node(
          NodeType::LINK,
          @tokens.start_byte(id), @tokens.end_byte(id),
          str1: destination
        )
        @arena.append_child(@parent_id, link_id)
        @arena.append_child(link_id, @arena.add_node(NodeType::TEXT, str1: label))
      end

      # --------------------------- code spans -----------------------------

      # Find the closing backtick run for a code span by scanning the
      # source bytes directly. CommonMark: backslash escapes do not
      # apply inside a code span, so once we're past the opener every
      # backtick run is a real candidate (token-level ESCAPED_CHAR is
      # ignored).
      def resolve_code_span(opener_id)
        run_len = @tokens.int1(opener_id)
        pos = @tokens.end_byte(opener_id)
        while pos < @source.bytesize
          if @source.getbyte(pos) == 0x60
            run_start = pos
            pos += 1 while pos < @source.bytesize && @source.getbyte(pos) == 0x60
            if pos - run_start == run_len
              emit_code_span_bytes(opener_id, run_start, pos)
              return next_token_after(pos, opener_id + 1)
            end
          else
            pos += 1
          end
        end
        nil
      end

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
          str1: text
        )
        @arena.append_child(@parent_id, node_id)
        @provisional_nodes[node_id] = true
        @bracket_stack << Bracket.new(token_id, node_id, image, true, @delimiter_stack.length)
      end

      def resolve_rbracket(rbracket_token_id, search_from_id)
        opener_index = nil
        i = @bracket_stack.length - 1
        while i >= 0
          if @bracket_stack[i].active
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
        next_token_after(match[:end_byte], search_from_id)
      end

      def try_inline_link(start_byte)
        return nil if start_byte >= @source.bytesize
        return nil unless @source.getbyte(start_byte) == 0x28

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
            return nil
          end
          index += 1
        end
        return nil unless depth.zero?

        body = @source.byteslice(body_start, index - body_start).to_s
        destination, title = split_destination_and_title(body)
        return nil if destination.nil?

        { end_byte: index + 1, destination: destination, title: title }
      end

      def try_reference_link(opener, rbracket_token_id, start_byte)
        label_start = @tokens.end_byte(opener.token_id)
        label_end = @tokens.start_byte(rbracket_token_id)
        text_label = @source.byteslice(label_start, label_end - label_start).to_s

        if start_byte < @source.bytesize && @source.getbyte(start_byte) == 0x5B
          ref_label, after_byte = read_reference_label(start_byte)
          return nil unless after_byte
          lookup = ref_label.empty? ? text_label : ref_label
          ref = @references[normalize_reference_label(lookup)]
          return nil unless ref
          return { end_byte: after_byte, destination: ref[:destination], title: ref[:title] }
        end

        ref = @references[normalize_reference_label(text_label)]
        return nil unless ref
        { end_byte: start_byte, destination: ref[:destination], title: ref[:title] }
      end

      def read_reference_label(start_byte)
        return [nil, nil] unless @source.getbyte(start_byte) == 0x5B

        i = start_byte + 1
        while i < @source.bytesize
          b = @source.getbyte(i)
          if b == 0x5D
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
        opener_start = @tokens.start_byte(opener.token_id)
        link_kind = opener.image ? NodeType::IMAGE : NodeType::LINK
        link_id = add_arena_node(
          link_kind, opener_start, match[:end_byte],
          str1: sanitize_destination(match[:destination]),
          str2: match[:title]
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
        process_emphasis(inner_delims)

        @bracket_stack.delete_at(opener_index)

        unless opener.image
          @bracket_stack.each { |b| b.active = false unless b.image }
        end
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
            append_text(byte_offset, e, nil) if @tokens.kind(id) == TokenKind::TEXT
            return id + 1
          end
          id += 1
        end
        last
      end

      def split_destination_and_title(body)
        # Angle-bracketed destination: <...> with optional title.
        # The angle brackets are stripped from the destination value.
        if (m = /\A\s*<([^<>\n]*)>(?:\s+"([^"]*)")?\s*\z/.match(body))
          return [m[1], m[2]]
        end

        # Raw destination + double-quoted title.
        if (m = /\A\s*(\S+)\s+"([^"]*)"\s*\z/.match(body))
          return [m[1], m[2]]
        end

        # Just a destination (possibly empty after trimming).
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

      # --------------------------- delim runs / emphasis ------------------

      def push_delim_run(token_id)
        char_byte = @tokens.int1(token_id)
        count = @tokens.int2(token_id)
        flags = @tokens.int3(token_id)

        text = char_byte.chr * count
        node_id = add_arena_node(
          NodeType::TEXT,
          @tokens.start_byte(token_id), @tokens.end_byte(token_id),
          str1: text
        )
        @arena.append_child(@parent_id, node_id)
        @provisional_nodes[node_id] = true

        @delimiter_stack << Delimiter.new(
          node_id, char_byte.chr, count,
          (flags & 0b10) != 0,
          (flags & 0b01) != 0
        )
      end

      def process_emphasis(stack)
        openers_bottom = { "*" => -1, "_" => -1, "~" => -1 }
        closer_idx = 0

        while closer_idx < stack.length
          closer = stack[closer_idx]
          unless closer.can_close
            closer_idx += 1
            next
          end

          opener_idx = closer_idx - 1
          found = false
          while opener_idx > openers_bottom[closer.char]
            opener = stack[opener_idx]
            if opener.can_open && opener.char == closer.char
              skip = false
              if (opener.can_close || closer.can_open) &&
                 ((opener.count + closer.count) % 3).zero? &&
                 !((opener.count % 3).zero? && (closer.count % 3).zero?)
                skip = true
              end
              unless skip
                found = true
                break
              end
            end
            opener_idx -= 1
          end

          unless found
            openers_bottom[closer.char] = closer_idx - 1
            unless closer.can_open
              @provisional_nodes.delete(closer.node_id)
              stack.delete_at(closer_idx)
            end
            closer_idx += 1
            next
          end

          opener = stack[opener_idx]
          strength = [opener.count, closer.count].min >= 2 ? 2 : 1
          if closer.char == "~"
            # GFM strikethrough only forms on `~~` runs. A single `~`
            # leaves the delimiter as text; advance the cursor so future
            # `~~` pairs can still match.
            if strength < 2
              closer_idx += 1
              next
            end
            kind = NodeType::STRIKETHROUGH
          else
            kind = strength == 2 ? NodeType::STRONG : NodeType::EMPHASIS
          end

          # CommonMark spec: any delimiters strictly between this opener and
          # closer can't open or close anything in this scope, so drop them
          # from the stack before we rebuild the tree. Their arena nodes
          # stay where they are (they'll be reparented into the new emphasis
          # alongside the surrounding content), but they must no longer be
          # candidates for future iterations. Without this, the next
          # iteration would try to pair stranded delimiters that have
          # already been moved into a different parent, which corrupts the
          # sibling chain (Arena#reparent walks into @parent[-1]).
          if closer_idx > opener_idx + 1
            removed = stack.slice!((opener_idx + 1)...closer_idx)
            removed.each { |e| @provisional_nodes.delete(e.node_id) }
            closer_idx = opener_idx + 1
            closer = stack[closer_idx]
          end

          opener_node = opener.node_id
          closer_node = closer.node_id

          if @track_source
            opener_match_start = @arena.source_start(opener_node) +
                                 @arena.source_len(opener_node) - strength
            closer_match_end = @arena.source_start(closer_node) + strength
          else
            opener_match_start = -1
            closer_match_end = 0
          end
          emphasis_id = add_arena_node(kind, opener_match_start, closer_match_end)

          first_inside = @arena.raw_next_sibling_id(opener_node)
          last_inside = @arena.raw_prev_sibling_id(closer_node)
          if first_inside != -1 && last_inside != -1 &&
             first_inside != closer_node && last_inside != opener_node
            @arena.reparent(emphasis_id, first_inside, last_inside)
          end

          parent_id = @arena.raw_parent_id(opener_node)
          @arena.insert_before(parent_id, closer_node, emphasis_id)

          if opener.count == strength
            @provisional_nodes.delete(opener_node)
            @arena.detach(opener_node)
            stack.delete_at(opener_idx)
            closer_idx -= 1
          else
            opener.count -= strength
            str = @arena.str1(opener_node)
            @arena.replace_str1(opener_node, str[0...-strength])
            if @track_source
              new_end = @arena.source_start(opener_node) + @arena.source_len(opener_node) - strength
              @arena.update_span(opener_node, @arena.source_start(opener_node), new_end)
            end
          end

          if closer.count == strength
            @provisional_nodes.delete(closer_node)
            @arena.detach(closer_node)
            stack.delete_at(closer_idx)
          else
            closer.count -= strength
            str = @arena.str1(closer_node)
            @arena.replace_str1(closer_node, str[strength..])
            if @track_source
              new_start = @arena.source_start(closer_node) + strength
              new_end = @arena.source_start(closer_node) + @arena.source_len(closer_node)
              @arena.update_span(closer_node, new_start, new_end)
            end
          end
        end

        stack.each { |e| @provisional_nodes.delete(e.node_id) }
        stack.clear
      end
    end
  end
end
