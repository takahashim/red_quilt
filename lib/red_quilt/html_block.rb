# frozen_string_literal: true

module RedQuilt
  # CommonMark HTML-block classification (spec 4.6). Pure functions over a
  # line's text: given the raw line they decide whether it opens an HTML
  # block and of which of the seven types. No arena or parser state is
  # involved, so this lives apart from BlockParser's node construction.
  module HtmlBlock
    module_function

    # True when `text` opens an HTML block (any of the 7 types). Indented
    # code (4+ leading spaces) takes precedence and is never an HTML block.
    def start?(text)
      return false if text.start_with?("    ")

      !type(text).nil?
    end

    # The HTML block type (1..7) opened by `text`, or nil if it opens none.
    def type(text)
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

      # Type 1: <script|pre|style|textarea (case-insensitive) followed by
      # space/tab/end-of-line or `>`. CommonMark restricts the separator
      # to space, tab, or a line ending (not any whitespace class).
      return 1 if stripped.match?(%r{\A<(script|pre|style|textarea)(?:[ \t]|>|$)}i)

      # Type 2: <!--
      return 2 if stripped.start_with?("<!--")

      # Type 3: <?
      return 3 if stripped.start_with?("<?")

      # Type 4: <! followed by uppercase ASCII letter
      return 4 if stripped.match?(%r{\A<![A-Z]})

      # Type 5: <![CDATA[
      return 5 if stripped.start_with?("<![CDATA[")

      # Type 6: line opens with one of the listed block-level tags.
      return 6 if stripped.match?(TYPE_6_RE)

      # Type 7: a complete open or closing tag spanning the line.
      return 7 if valid_tag?(stripped)

      nil
    end

    TYPE_6_NAMES = %w[
      address article aside base basefont blockquote body caption center
      col colgroup dd details dialog dir div dl dt fieldset figcaption
      figure footer form frame frameset h1 h2 h3 h4 h5 h6 head header
      hr html iframe legend li link main menu menuitem nav noframes ol
      optgroup option p param search section summary table tbody td
      tfoot th thead title tr track ul
    ].freeze
    TYPE_6_RE = %r{\A</?(?:#{TYPE_6_NAMES.join('|')})(?:[ \t]|>|/>|\z)}i
    private_constant :TYPE_6_NAMES, :TYPE_6_RE

    # Type 7: a complete open or closing tag on its own line.
    # Closing tags must not have attributes.
    #
    # HTML tag separators per CommonMark 6.6 are space, tab, or up to one
    # line ending -- not the broader \s class (which would include form
    # feed and vertical tab).
    TYPE_7_OPEN_TAG_RE = %r{
      \A
      <[A-Za-z][A-Za-z0-9-]*
      (?:[ \t\r\n]+[A-Za-z_:][A-Za-z0-9_.:-]*(?:[ \t\r\n]*=[ \t\r\n]*(?:"[^"\n]*"|'[^'\n]*'|[^ \t\r\n"'=<>`]+))?)*
      [ \t\r\n]*/?>
      \z
    }x
    TYPE_7_CLOSING_TAG_RE = %r{\A</[A-Za-z][A-Za-z0-9-]*[ \t\r\n]*>\z}
    private_constant :TYPE_7_OPEN_TAG_RE, :TYPE_7_CLOSING_TAG_RE

    def valid_tag?(text)
      # Fast reject: every type-7 tag must begin with `<`.
      return false unless text.start_with?("<")

      TYPE_7_OPEN_TAG_RE.match?(text) || TYPE_7_CLOSING_TAG_RE.match?(text)
    end

    # Closing-condition strings for HTML block types 2-5 (types 1, 6, 7 use
    # dynamic / blank-line termination).
    FIXED_TERMINATORS = { 2 => "-->", 3 => "?>", 4 => ">", 5 => "]]>" }.freeze
    private_constant :FIXED_TERMINATORS

    # Cached collaborator for BlockParser. A single instance is created in
    # BlockParser#initialize and reused; per-call state lives in method
    # locals so reentrant calls are safe.
    class Parser
      def initialize(block_parser)
        @arena = block_parser.arena
      end

      # Parses the HTML block starting at lines[index] (its type already
      # confirmed by HtmlBlock.start?). Returns the index past the block.
      def parse(parent_id, lines, index)
        start_index = index
        type = HtmlBlock.type(lines[index].content)
        end_index = locate_end(lines, index, type)

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

      private

      def locate_end(lines, index, type)
        terminator = terminator_for(type, lines[index].content)

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

      def terminator_for(type, first_line)
        case type
        when 1
          "</#{closing_tag_name(first_line)}>"
        when 2..5
          FIXED_TERMINATORS[type]
        end
      end

      def closing_tag_name(text)
        match = /\A<(script|pre|style|textarea)/i.match(text)
        match ? match[1].downcase : "script"
      end
    end
  end
end
