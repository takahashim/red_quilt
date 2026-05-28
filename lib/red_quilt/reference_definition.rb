# frozen_string_literal: true

module RedQuilt
  # CommonMark link reference definitions (`[label]: dest "title"`).
  #
  # Module-level functions are stateless helpers reused by BlockParser
  # (fenced-code info string also calls `unescape_text`) and
  # Inline::Builder (reference lookup uses `normalize_label`).
  # `ReferenceDefinition::Parser` carries the per-call state (`@lines`,
  # `@index`) and walks the lines for one definition attempt.
  module ReferenceDefinition
    # A reference label may contain `\[` / `\]` (backslash-escaped),
    # but never an unescaped `[` or `]`. Newlines inside the label are
    # allowed and collapsed by normalize_label.
    REF_DEF_RE = /\A {0,3}\[((?:[^\\\[\]]|\\.)+)\]:(.*)\z/m

    TITLE_CLOSERS = { '"' => '"', "'" => "'", "(" => ")" }.freeze

    # CommonMark spec: "A link label can have at most 999 characters
    # inside the square brackets." Applies to both reference definitions
    # and reference link uses.
    LABEL_MAX_LENGTH = 999

    # CommonMark 6.3 link-tail whitespace: space/tab only (line endings
    # are handled separately by the caller). Intentionally narrower than
    # Ruby's `strip`/`lstrip`, which also match FF (U+000C) and VT
    # (U+000B). Mirrors Inline::Builder#link_tail_whitespace_byte?.
    LINK_TAIL_WS_RE = /[ \t]/

    module_function

    # True when `text` exceeds the spec's link-label length limit.
    def label_too_long?(text)
      text.to_s.length > LABEL_MAX_LENGTH
    end

    # Narrow lstrip: only space and tab. Used for the spec-defined
    # whitespace around link destinations and titles in reference
    # definitions.
    def link_lstrip(text)
      text.sub(/\A[ \t]+/, "")
    end

    # True when the string is empty or contains only spaces and tabs.
    def link_blank?(text)
      text.match?(/\A[ \t]*\z/)
    end

    # Attempts to consume a reference definition starting at `lines[index]`.
    # Returns `{ reference: { label:, destination:, title: }, consumed: N,
    # source_span: SourceSpan }` or nil. The reference hash is what
    # BlockParser should store in its @references table; the source_span
    # covers the byte range of the consumed lines (useful for
    # duplicate-definition diagnostics).
    def consume(lines, index)
      Parser.new(lines, index).consume
    end

    # Unescape Markdown text: backslash-escapes for ASCII punctuation and
    # HTML entity references. Also used by BlockParser#fenced_code_start
    # for the info string, which shares the same unescape semantics.
    def unescape_text(text)
      out = text.gsub(/\\([!-\/:-@\[-`{-~])/, "\\1")
      out.gsub(Inline::ENTITY_RE) { |m| Inline.decode_entity(m) }
    end

    # Spec-required normalization: full Unicode case fold + whitespace
    # collapse. Inline::Builder uses the same rule when looking up the
    # destination of a reference link.
    def normalize_label(label)
      # CommonMark spec: full Unicode case fold (`downcase(:fold)`), not
      # the default per-codepoint lowercase. This makes labels like `ẞ`
      # (U+1E9E) match a definition of `SS` because the case-fold of `ẞ`
      # is `ss`.
      label.to_s.strip.downcase(:fold).gsub(/[ \t\r\n]+/, " ")
    end

    class Parser
      def initialize(lines, index)
        @lines = lines
        @index = index
      end

      def consume
        text = @lines[@index].content
        return unless text.match?(/\A {0,3}\[/)

        match, consumed = match_label(text)
        return unless match

        label = ReferenceDefinition.normalize_label(match[1])
        return if label.empty?

        remainder = match[2].to_s
        chunks, consumed = collect_destination_chunks(remainder, consumed)
        return unless chunks

        destination, rest = parse_destination(chunks.shift.to_s)
        if destination.nil?
          destination, rest = parse_destination(chunks.first.to_s)
          return unless destination

          chunks.shift
        end

        title, consumed = consume_title(rest, consumed)
        return if title == :invalid

        {
          reference: {
            label: label,
            destination: ReferenceDefinition.unescape_text(strip_angle_brackets(destination)),
            title: title,
          },
          consumed: consumed,
          source_span: SourceSpan.new(@lines[@index].start_byte,
                                      @lines[@index + consumed - 1].end_byte),
        }
      end

      private

      def match_label(text)
        match = REF_DEF_RE.match(text)
        if match
          return [nil, nil] if ReferenceDefinition.label_too_long?(match[1])

          return [match, 1]
        end

        # Multi-line label: accumulate subsequent lines until `]:` is
        # found. Blank lines terminate the attempt.
        accumulated = text
        extra = 0
        loop do
          probe = @index + 1 + extra
          return [nil, nil] if probe >= @lines.length

          next_line = @lines[probe]
          return [nil, nil] if next_line.blank

          accumulated += "\n" + next_line.content
          extra += 1
          m = REF_DEF_RE.match(accumulated)
          next unless m
          return [nil, nil] if ReferenceDefinition.label_too_long?(m[1])

          return [m, 1 + extra]
        end
      end

      def collect_destination_chunks(remainder, consumed)
        chunks = [remainder]
        return [chunks, consumed] unless ReferenceDefinition.link_blank?(remainder)

        return [nil, nil] if @index + consumed >= @lines.length

        next_line = @lines[@index + consumed]
        return [nil, nil] if next_line.blank

        chunks << next_line.content
        [chunks, consumed + 1]
      end

      def consume_title(rest, consumed)
        title_source = rest.to_s
        consumed_before_title = consumed
        title_on_separate_line = false
        if ReferenceDefinition.link_blank?(title_source) && @index + consumed < @lines.length
          next_line = @lines[@index + consumed]
          if next_line && potential_title_start?(next_line.content)
            title_source = next_line.content
            consumed += 1
            title_on_separate_line = true
          end
        end

        while @index + consumed < @lines.length && title_needs_more_lines?(title_source)
          next_line = @lines[@index + consumed]
          break if next_line.blank

          title_source = title_source.empty? ? next_line.content : "#{title_source}\n#{next_line.content}"
          consumed += 1
        end

        title, trailing = parse_title(title_source)
        if trailing && trailing.match?(/\S/)
          if title_on_separate_line
            # The title was pulled from a follow-up line; back off so
            # that line is reparsed as ordinary content and the def is
            # still accepted (sans title).
            return [nil, consumed_before_title]
          else
            # Title was on the destination line itself; the whole def is
            # invalid.
            return [:invalid, consumed]
          end
        end

        [title, consumed]
      end

      def strip_angle_brackets(destination)
        destination.start_with?("<") && destination.end_with?(">") ? destination[1...-1] : destination
      end

      def parse_destination(text)
        source = ReferenceDefinition.link_lstrip(text)
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

        parse_raw_destination(source)
      end

      # Raw destination per CommonMark 6.3: no ASCII control chars or
      # space; parentheses must be balanced or backslash-escaped. Mirrors
      # the inline-link logic in Inline::Builder#parse_raw_destination
      # so a reference definition is not more permissive than an inline
      # link destination.
      RAW_DEST_FORBIDDEN_RE = /[\u0000-\u0020\u007F]/
      ASCII_PUNCT_RE = /[!-\/:-@\[-`{-~]/

      def parse_raw_destination(source)
        depth = 0
        i = 0
        len = source.length
        while i < len
          c = source[i]
          if c == "\\" && i + 1 < len && ASCII_PUNCT_RE.match?(source[i + 1])
            i += 2
            next
          end
          break if RAW_DEST_FORBIDDEN_RE.match?(c)

          if c == "("
            depth += 1
          elsif c == ")"
            break if depth.zero?

            depth -= 1
          end
          i += 1
        end

        return [nil, nil] if i.zero?
        return [nil, nil] unless depth.zero?

        [source[0...i], source[i..].to_s]
      end

      def title_needs_more_lines?(text)
        stripped = ReferenceDefinition.link_lstrip(text)
        return false if stripped.empty?

        quote = stripped[0]
        closer = TITLE_CLOSERS[quote]
        return false unless closer
        return false if stripped.length > 1 && stripped.end_with?(closer)

        true
      end

      def potential_title_start?(text)
        %w[" ' (].include?(ReferenceDefinition.link_lstrip(text)[0])
      end

      def parse_title(text)
        stripped = ReferenceDefinition.link_lstrip(text)
        return [nil, stripped] if stripped.empty?

        opener = stripped[0]
        closer = TITLE_CLOSERS[opener]
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
            return [ReferenceDefinition.unescape_text(body), trailing]
          else
            body << char
            escaped = false
          end
          index += 1
        end

        [nil, stripped]
      end
    end
  end
end
