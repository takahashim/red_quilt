# frozen_string_literal: true

module RedQuilt
  module Renderer
    class HTML
      def initialize(document)
        @document = document
        @arena = document.arena
        @out = +""
      end

      def render
        render_children(@document.root_id)
        @out
      end

      private

      # CommonMark-compliant HTML escape: only `&`, `<`, `>`, `"` are
      # rewritten. Apostrophes are left as-is (escape_html on Ruby
      # 3.0+ rewrites `'` -> `&#39;` which fails CommonMark spec
      # comparisons).
      HTML_ESCAPE_TABLE = { "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", '"' => "&quot;" }.freeze
      HTML_ESCAPE_RE = /[&<>"]/

      def escape_html(str)
        return str unless HTML_ESCAPE_RE.match?(str)

        str.gsub(HTML_ESCAPE_RE, HTML_ESCAPE_TABLE)
      end

      def render_children(node_id)
        child_id = @arena.raw_first_child_id(node_id)
        until child_id == -1
          render_node(child_id)
          child_id = @arena.raw_next_sibling_id(child_id)
        end
      end

      def render_node(node_id)
        case @arena.type(node_id)
        when NodeType::PARAGRAPH
          @out << "<p>"
          render_children(node_id)
          @out << "</p>\n"
        when NodeType::HEADING
          level = @arena.int1(node_id)
          @out << "<h#{level}>"
          render_children(node_id)
          @out << "</h#{level}>\n"
        when NodeType::THEMATIC_BREAK
          @out << "<hr />\n"
        when NodeType::BLOCKQUOTE
          @out << "<blockquote>\n"
          render_children(node_id)
          @out << "</blockquote>\n"
        when NodeType::LIST
          ordered = @arena.int1(node_id) == 1
          tag = ordered ? "ol" : "ul"
          start_number = @arena.int2(node_id)
          attrs = ordered && start_number != 1 ? %( start="#{start_number}") : ""
          @out << "<#{tag}#{attrs}>\n"
          render_children(node_id)
          @out << "</#{tag}>\n"
        when NodeType::LIST_ITEM
          @out << "<li>"
          render_list_item(node_id)
          @out << "</li>\n"
        when NodeType::CODE_BLOCK
          @out << "<pre><code"
          info_word = @arena.str2(node_id).to_s.split.first.to_s
          @out << %( class="language-#{escape_html(info_word)}") unless info_word.empty?
          @out << ">"
          @out << escape_html(@arena.text(node_id).to_s)
          @out << "</code></pre>\n"
        when NodeType::HTML_BLOCK
          render_raw_html(@arena.text(node_id).to_s, block: true)
        when NodeType::TABLE
          @out << "<table>\n"
          render_table(node_id)
          @out << "</table>\n"
        when NodeType::TEXT
          @out << escape_html(@arena.text(node_id).to_s)
        when NodeType::SOFTBREAK
          @out << "\n"
        when NodeType::HARDBREAK
          @out << "<br />\n"
        when NodeType::EMPHASIS
          @out << "<em>"
          render_children(node_id)
          @out << "</em>"
        when NodeType::STRONG
          @out << "<strong>"
          render_children(node_id)
          @out << "</strong>"
        when NodeType::STRIKETHROUGH
          @out << "<del>"
          render_children(node_id)
          @out << "</del>"
        when NodeType::CODE_SPAN
          @out << "<code>#{escape_html(@arena.text(node_id).to_s)}</code>"
        when NodeType::LINK
          dest = escape_html(@arena.str1(node_id).to_s)
          @out << %(<a href="#{dest}")
          append_title_attribute(node_id)
          @out << ">"
          render_children(node_id)
          @out << "</a>"
        when NodeType::IMAGE
          alt = PlainText.from(@arena, node_id)
          dest = escape_html(@arena.str1(node_id).to_s)
          @out << %(<img src="#{dest}" alt="#{escape_html(alt)}")
          append_title_attribute(node_id)
          @out << " />"
        when NodeType::HTML_INLINE
          render_raw_html(@arena.text(node_id).to_s, block: false)
        end
      end

      def render_table(table_id)
        rows = @arena.child_ids(table_id).to_a
        header_rows = rows.select { |row_id| @arena.int1(row_id) == 1 }
        body_rows = rows.reject { |row_id| @arena.int1(row_id) == 1 }

        unless header_rows.empty?
          @out << "<thead>\n"
          header_rows.each { |row_id| render_table_row(row_id) }
          @out << "</thead>\n"
        end
        unless body_rows.empty?
          @out << "<tbody>\n"
          body_rows.each { |row_id| render_table_row(row_id) }
          @out << "</tbody>\n"
        end
      end

      def render_list_item(node_id)
        parent_id = @arena.raw_parent_id(node_id)
        tight = parent_id != -1 && @arena.type(parent_id) == NodeType::LIST && @arena.int3(parent_id) == 1

        first_child_id = @arena.raw_first_child_id(node_id)
        first_is_para = first_child_id != -1 &&
                        @arena.type(first_child_id) == NodeType::PARAGRAPH

        # Empty <li> renders inline; otherwise loose lists and tight
        # items opening with a non-paragraph block get a leading newline.
        if first_child_id != -1 && (!tight || !first_is_para)
          @out << "\n"
        end

        child_id = first_child_id
        prev_type = nil
        until child_id == -1
          type = @arena.type(child_id)
          if tight && type == NodeType::PARAGRAPH
            # Paragraph in a tight list: drop the wrapping <p>. Only
            # insert a separator `\n` when the previous child was also
            # a tight paragraph — every other block already trails its
            # own `\n`, so adding another would double-space the gap.
            @out << "\n" if prev_type == NodeType::PARAGRAPH
            render_children(child_id)
          else
            # Non-paragraph block. Tight list paragraphs were emitted
            # without their tag, so follow them with `\n` to land the
            # next block on a fresh line. Other blocks already end with
            # their own `\n`, so no extra separator is needed.
            @out << "\n" if tight && prev_type == NodeType::PARAGRAPH
            render_node(child_id)
          end
          prev_type = type
          child_id = @arena.raw_next_sibling_id(child_id)
        end
      end

      def render_table_row(row_id)
        @out << "<tr>"
        @arena.each_child(row_id) do |cell_id|
          tag = @arena.int1(cell_id) == 1 ? "th" : "td"
          @out << "<#{tag}>"
          render_children(cell_id)
          @out << "</#{tag}>"
        end
        @out << "</tr>\n"
      end

      # GFM "Disallowed Raw HTML" extension: when allow_html is on but
      # the caller has opted into filtering, the 9 dangerous tag names
      # have their leading `<` rewritten to `&lt;` so the browser sees
      # them as text. Word boundary (\b) prevents over-filtering
      # (e.g. `<scripts>` is left alone).
      DISALLOWED_RAW_TAGS = %w[title textarea style xmp iframe noembed noframes script plaintext].freeze
      DISALLOWED_RAW_TAG_RE = /<(?=\/?(?:#{DISALLOWED_RAW_TAGS.join('|')})\b)/i

      def render_raw_html(text, block:)
        if @document.allow_html?
          out_text = @document.disallow_raw_html? ? filter_disallowed_raw(text) : text
          @out << out_text
          @out << "\n" if block
        else
          escaped = escape_html(text)
          if block
            @out << escaped << "\n"
          else
            @out << escaped
          end
        end
      end

      def filter_disallowed_raw(text)
        text.gsub(DISALLOWED_RAW_TAG_RE, "&lt;")
      end

      def append_title_attribute(node_id)
        title = @arena.str2(node_id).to_s
        return if title.empty?

        @out << %( title="#{escape_html(title)}")
      end
    end
  end
end
