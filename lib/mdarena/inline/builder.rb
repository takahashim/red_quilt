# frozen_string_literal: true

require "cgi"

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
      NIL_PAIR = [nil, nil].freeze
      URL_SAFE_BYTE = begin
        a = Array.new(256, false)
        "-._~:/?#@!$&'()*+,;=".each_byte { |b| a[b] = true }
        a.freeze
      end
      TRAILING_SPACE_RE = (1..8).map { |n| / {#{n},}\z/.freeze }.freeze

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
      #
      # diagnostics: an optional Array the builder appends warnings to
      # (unsafe URL schemes, missing references, ...). The caller — usually
      # InlinePass — is expected to forward Document#diagnostics here.
      def initialize(arena, source, references, track_source: true, diagnostics: nil)
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
          str1: normalize_link_uri(destination)
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
          str1: text
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

      # Parses an inline link body `(dest "title")` starting at the byte
      # right after the link's closing `]`. Returns a hash with
      # `:end_byte`, `:destination`, `:title` on success, or nil if the
      # bytes don't form a valid inline link tail.
      def try_inline_link(start_byte)
        return nil unless byte_at(start_byte) == 0x28

        pos = start_byte + 1
        pos = skip_link_whitespace(pos)
        return nil if pos.nil?

        raw_dest = nil
        next_byte = byte_at(pos)
        if next_byte && next_byte != 0x29 && !ascii_whitespace_byte?(next_byte) && next_byte != 0x0A
          dest_result = parse_link_destination(pos)
          return nil unless dest_result
          raw_dest, pos = dest_result
        end

        ws_end = skip_link_whitespace(pos)
        return nil if ws_end.nil?

        raw_title = nil
        if ws_end > pos
          opener_byte = byte_at(ws_end)
          if opener_byte && (opener_byte == 0x22 || opener_byte == 0x27 || opener_byte == 0x28)
            title_result = parse_link_title(ws_end)
            return nil unless title_result
            raw_title, pos = title_result
            pos = skip_link_whitespace(pos)
            return nil if pos.nil?
          else
            pos = ws_end
          end
        else
          pos = ws_end
        end

        return nil unless byte_at(pos) == 0x29

        destination = raw_dest ? normalize_link_uri(raw_dest) : ""
        title = raw_title ? decode_link_entities(raw_title) : nil
        { end_byte: pos + 1, destination: destination, title: title }
      end

      # Consume ASCII whitespace starting at start_byte. Returns the
      # position of the first non-whitespace byte, or nil if a blank line
      # was crossed (link inner whitespace may span at most one newline).
      def skip_link_whitespace(start_byte)
        pos = start_byte
        newlines = 0
        while pos < @source.bytesize
          b = @source.getbyte(pos)
          if b == 0x0A
            newlines += 1
            return nil if newlines > 1
          elsif !ascii_whitespace_byte?(b)
            break
          end
          pos += 1
        end
        pos
      end

      def parse_link_destination(start_byte)
        if byte_at(start_byte) == 0x3C
          parse_angle_bracket_destination(start_byte)
        else
          parse_raw_destination(start_byte)
        end
      end

      # `<...>` form. Returns [string_with_backslash_escapes_applied, end_pos]
      # or nil. Inside angles, `\` followed by ASCII punctuation escapes that
      # punctuation; unescaped `<`, `>` or newlines bail the parse.
      def parse_angle_bracket_destination(start_byte)
        pos = start_byte + 1
        result = String.new
        while pos < @source.bytesize
          b = @source.getbyte(pos)
          case b
          when 0x3E
            return [result, pos + 1]
          when 0x3C, 0x0A
            return nil
          when 0x5C
            nb = @source.getbyte(pos + 1)
            if nb && ascii_punct_byte?(nb)
              result << nb
              pos += 2
              next
            end
            result << b
          else
            result << b
          end
          pos += 1
        end
        nil
      end

      # Raw destination: characters until ASCII whitespace, an ASCII
      # control char, or an unbalanced `)`. Parens are allowed if balanced
      # or backslash-escaped.
      def parse_raw_destination(start_byte)
        pos = start_byte
        depth = 0
        result = String.new
        while pos < @source.bytesize
          b = @source.getbyte(pos)
          if b == 0x5C
            nb = @source.getbyte(pos + 1)
            if nb && ascii_punct_byte?(nb)
              result << nb
              pos += 2
              next
            end
            result << b
            pos += 1
            next
          end

          break if ascii_whitespace_byte?(b) || b < 0x20 || b == 0x7F

          if b == 0x28
            depth += 1
          elsif b == 0x29
            break if depth.zero?
            depth -= 1
          end

          result << b
          pos += 1
        end

        return nil if pos == start_byte
        return nil if depth != 0
        [result, pos]
      end

      # Parses a title delimited by `"`, `'`, or `(...)`. Returns
      # [unescaped_string, end_pos] or nil. Backslash escapes apply for
      # ASCII punctuation; a blank line inside a title voids the match.
      def parse_link_title(start_byte)
        opener = @source.getbyte(start_byte)
        closer = case opener
                 when 0x22 then 0x22
                 when 0x27 then 0x27
                 when 0x28 then 0x29
                 else return nil
                 end
        balanced = opener == 0x28

        pos = start_byte + 1
        result = String.new
        while pos < @source.bytesize
          b = @source.getbyte(pos)
          if b == 0x5C
            nb = @source.getbyte(pos + 1)
            if nb && ascii_punct_byte?(nb)
              result << nb
              pos += 2
              next
            end
            result << b
            pos += 1
            next
          end

          if b == 0x0A
            # Blank line (newline followed by only whitespace + newline) is forbidden.
            look = pos + 1
            while look < @source.bytesize && (@source.getbyte(look) == 0x20 || @source.getbyte(look) == 0x09)
              look += 1
            end
            return nil if look < @source.bytesize && @source.getbyte(look) == 0x0A
            result << b
            pos += 1
            next
          end

          # Inside `(...)` titles, an unescaped opening `(` invalidates the match.
          return nil if balanced && b == 0x28

          if b == closer
            return [result, pos + 1]
          end

          result << b
          pos += 1
        end
        nil
      end

      # Percent-encodes bytes not in the URL-safe set, decodes HTML
      # entities first, and preserves (uppercasing) existing `%XX`.
      def normalize_link_uri(raw)
        decoded = decode_link_entities(raw)
        bytes = decoded.b
        result = +""
        i = 0
        size = bytes.bytesize
        while i < size
          b = bytes.getbyte(i)
          if b == 0x25 && i + 2 < size &&
             hex_byte?(bytes.getbyte(i + 1)) && hex_byte?(bytes.getbyte(i + 2))
            result << "%"
            result << bytes.getbyte(i + 1).chr.upcase
            result << bytes.getbyte(i + 2).chr.upcase
            i += 3
          elsif url_safe_byte?(b)
            result << b.chr
            i += 1
          else
            result << format("%%%02X", b)
            i += 1
          end
        end
        result
      end

def decode_link_entities(raw)
  raw.gsub(/&(?:[A-Za-z][A-Za-z0-9]+|#\d+|#[xX][0-9A-Fa-f]+);/) do |m|
    if m.start_with?("&#")
      decoded = CGI.unescapeHTML(m)
      decoded.tr("\u0000", "\uFFFD")
    else
      encoded = HTML_ENTITIES[m[1..-2]]
      encoded ? encoded.dup.force_encoding(Encoding::UTF_8) : m
    end
  end
end

      def byte_at(pos)
        return nil if pos < 0 || pos >= @source.bytesize
        @source.getbyte(pos)
      end

      def ascii_whitespace_byte?(b)
        b == 0x20 || b == 0x09 || b == 0x0D || b == 0x0C || b == 0x0B
      end

      # ASCII punctuation per CommonMark (used for backslash escape).
      def ascii_punct_byte?(b)
        (b >= 0x21 && b <= 0x2F) ||
          (b >= 0x3A && b <= 0x40) ||
          (b >= 0x5B && b <= 0x60) ||
          (b >= 0x7B && b <= 0x7E)
      end

      def hex_byte?(b)
        (b >= 0x30 && b <= 0x39) ||
          (b >= 0x41 && b <= 0x46) ||
          (b >= 0x61 && b <= 0x66)
      end

      def url_safe_byte?(b)
        return true if b >= 0x30 && b <= 0x39
        return true if b >= 0x41 && b <= 0x5A
        return true if b >= 0x61 && b <= 0x7A
        URL_SAFE_BYTE[b]
      end

      def try_reference_link(opener, rbracket_token_id, start_byte)
        label_start = @tokens.end_byte(opener.token_id)
        label_end = @tokens.start_byte(rbracket_token_id)
        text_label = @source.byteslice(label_start, label_end - label_start).to_s

        if start_byte < @source.bytesize && @source.getbyte(start_byte) == 0x5B
          ref_label, after_byte = read_reference_label(start_byte)
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
            destination: normalize_link_uri(ref[:destination].to_s),
            title: ref[:title]
          }
        end

        ref = @references[ReferenceDefinition.normalize_label(text_label)]
        return nil unless ref
        {
          end_byte: start_byte,
          destination: normalize_link_uri(ref[:destination].to_s),
          title: ref[:title]
        }
      end

      def read_reference_label(start_byte)
        return NIL_PAIR unless @source.getbyte(start_byte) == 0x5B

        i = start_byte + 1
        while i < @source.bytesize
          b = @source.getbyte(i)
          if b == 0x5D
            return [@source.byteslice(start_byte + 1, i - start_byte - 1).to_s, i + 1]
          elsif b == 0x5B
            # An unescaped `[` inside a reference label voids the form.
            return NIL_PAIR
          elsif b == 0x5C && i + 1 < @source.bytesize
            i += 2
            next
          end
          i += 1
        end
        NIL_PAIR
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

      def sanitize_destination(destination)
        return "" if destination.nil?
        return destination if destination.start_with?("/", "#")

        scheme = destination[%r{\A([a-zA-Z][a-zA-Z0-9+\-.]*):}, 1]
        return destination if scheme.nil?
        return destination if SAFE_SCHEMES.include?(scheme.downcase)

        report_diagnostic(
          severity: :warning,
          rule: :unsafe_url,
          message: "Unsafe URL scheme #{scheme.downcase.inspect} blocked",
        )
        ""
      end

      def report_diagnostic(severity:, rule:, message:, source_span: nil)
        return unless @diagnostics
        @diagnostics << Diagnostic.new(
          severity: severity, rule: rule, message: message, source_span: source_span
        )
      end

      # --------------------------- delim runs / emphasis ------------------

      def push_delim_run(token_id)
        char_byte = @tokens.int1(token_id)
        count = @tokens.int2(token_id)
        flags = @tokens.int3(token_id)

        char = char_byte.chr
        text = char * count
        node_id = add_arena_node(
          NodeType::TEXT,
          @tokens.start_byte(token_id), @tokens.end_byte(token_id),
          str1: text
        )
        @arena.append_child(@parent_id, node_id)
        @provisional_nodes[node_id] = true

        @delimiter_stack << Delimiter.new(
          node_id, char, count,
          (flags & 0b10) != 0,
          (flags & 0b01) != 0
        )
      end

      def process_emphasis(stack)
        # NB: the CommonMark spec describes an `openers_bottom`
        # optimization keyed by closer character / length / flanking
        # flags. Implementing that correctly is subtle (a single
        # per-character bottom blocks valid matches like
        # `*foo**bar**baz*`), so the implementation here just walks
        # back to the start of the stack for every closer. This is
        # O(stack^2) in the worst case but stacks are tiny in practice.
        closer_idx = 0

        while closer_idx < stack.length
          closer = stack[closer_idx]
          unless closer.can_close
            closer_idx += 1
            next
          end

          opener_idx = closer_idx - 1
          found = false
          while opener_idx >= 0
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
