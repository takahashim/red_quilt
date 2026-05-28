# frozen_string_literal: true

module RedQuilt
  # GitHub-style footnote definitions: `[^label]: content`. `match` handles
  # the opener line; `Parser` (a cached BlockParser collaborator, like
  # List::Parser) collects the optionally-indented, multi-paragraph
  # continuation and parses it into a FOOTNOTE_DEFINITION node. Label
  # normalization is shared with link reference definitions.
  #
  # NOTE: ReferenceDefinition's REF_DEF_RE also matches `[^label]:` (treating
  # `^label` as an ordinary label), so the block dispatch must try this
  # matcher BEFORE the reference-definition branch when footnotes are on.
  module FootnoteDefinition
    # Up to 3 spaces of indent, then `[^label]:`. The label is non-empty and
    # contains no whitespace or `]` (GFM rule).
    RE = /\A {0,3}\[\^([^\]\s]+)\]:(.*)\z/m

    module_function

    # Returns { label:, content_start:, content: } for a footnote-definition
    # opener, or nil. `content_start` is the byte offset (within `text`)
    # where the content begins, after `]:` and an optional single separating
    # space/tab; `content` is that text (possibly empty).
    def match(text)
      m = RE.match(text)
      return nil unless m

      rest = m[2]
      lead = rest.match?(/\A[ \t]/) ? 1 : 0
      {
        label: m[1],
        content_start: text.bytesize - rest.bytesize + lead,
        content: lead.zero? ? rest : rest[lead..],
      }
    end

    # Cached collaborator for BlockParser (created once per document and
    # reused for every definition). Footnote definitions are document-global:
    # the parser lazily creates a single FOOTNOTES_SECTION under the root and
    # memoizes it; per-call state otherwise lives in locals so the recursive
    # parse_lines call is safe.
    class Parser
      # GFM footnote continuation indent (columns). Lines indented at least
      # this much (plus blank lines between them) belong to the definition.
      CONTENT_INDENT = 4

      def initialize(block_parser)
        @block_parser = block_parser
        @arena = block_parser.arena
        @section_id = nil
      end

      # Consumes the definition opening at `lines[index]` (its `match`
      # already parsed), registers it in `registry`, and returns the next
      # unconsumed line index.
      def parse(lines, index, match, registry, root_id)
        first = lines[index]
        content_lines = [content_line(match[:content], first.start_byte + match[:content_start], first.end_byte)]
        consumed_index = collect_continuation(lines, index + 1, content_lines)

        label = ReferenceDefinition.normalize_label(match[:label])
        span = SourceSpan.new(first.start_byte, lines[consumed_index - 1].end_byte)
        if registry.defined?(label)
          @block_parser.diagnostics << Diagnostic.new(
            severity: :warning, rule: :duplicate_footnote,
            message: "Duplicate footnote definition #{label.inspect} — keeping the first",
            source_span: span,
          )
          return consumed_index
        end

        def_id = @arena.add_node(NodeType::FOOTNOTE_DEFINITION,
                                 source_start: span.start_byte, source_len: span.length,
                                 str1: label)
        @arena.append_child(section_id(root_id), def_id)
        registry.define(label, def_id)
        @block_parser.parse_lines(def_id, content_lines, transformed: true)
        consumed_index
      end

      # Make the footnotes section root's last child so it renders last and
      # the inline pass numbers body references before any nested references
      # inside the definitions. No-op when no definition was found.
      def move_section_to_end(root_id)
        return if @section_id.nil?

        @arena.detach(@section_id)
        @arena.append_child(root_id, @section_id)
      end

      private

      def content_line(content, start_byte, end_byte)
        Line.new(content, start_byte, end_byte, !content.match?(/[^ \t]/))
      end

      # Appends continuation lines to `content_lines` and returns the first
      # line index NOT consumed (trailing blank lines are left for the
      # surrounding flow). A line continues the definition when it is blank,
      # indented >= CONTENT_INDENT columns (a fresh/continued paragraph), or
      # — GFM treats footnote definitions like list items — a lazy
      # continuation: an unindented non-blank line directly following open
      # paragraph content that doesn't itself start a block or a new footnote
      # definition.
      def collect_continuation(lines, index, content_lines)
        pending_blanks = []
        while index < lines.length
          current = lines[index]
          if current.blank
            pending_blanks << current
            index += 1
            next
          end

          if Indentation.leading_columns(current.content) >= CONTENT_INDENT
            pending_blanks.each { |b| content_lines << Line.new("", b.start_byte, b.end_byte, true) }
            pending_blanks = []
            stripped = Indentation.strip_columns(current.content, CONTENT_INDENT)
            advance = [Indentation.leading_ws_bytes(current.content), current.content.bytesize - stripped.bytesize].min
            advance = 0 if advance.negative?
            content_lines << Line.new(stripped, current.start_byte + advance, current.end_byte, false)
            index += 1
            next
          end

          break unless pending_blanks.empty?
          break if content_lines.last.nil? || content_lines.last.blank
          break if @block_parser.lazy_break?(lines, index) || FootnoteDefinition.match(current.content)

          stripped = current.content.sub(/\A[ \t]+/, "")
          strip_len = current.content.length - stripped.length
          content_lines << Line.new(stripped, current.start_byte + strip_len, current.end_byte, false, true)
          index += 1
        end
        index - pending_blanks.length
      end

      def section_id(root_id)
        @section_id ||= begin
          id = @arena.add_node(NodeType::FOOTNOTES_SECTION, source_start: -1, source_len: 0)
          @arena.append_child(root_id, id)
          id
        end
      end
    end
  end
end
