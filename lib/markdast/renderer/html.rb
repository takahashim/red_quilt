# frozen_string_literal: true

require "cgi"

module Markdast
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

      def render_children(node_id)
        child_id = @arena.first_child(node_id)
        until child_id == -1
          render_node(child_id)
          child_id = @arena.next_sibling(child_id)
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
          tag = @arena.int1(node_id) == 1 ? "ol" : "ul"
          attrs = @arena.int1(node_id) == 1 && @arena.int2(node_id) > 1 ? %( start="#{@arena.int2(node_id)}") : ""
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
          @out << %( class="language-#{CGI.escapeHTML(info_word)}") unless info_word.empty?
          @out << ">"
          @out << CGI.escapeHTML(@arena.text(node_id).to_s)
          @out << "</code></pre>\n"
        when NodeType::HTML_BLOCK
          render_raw_html(@arena.text(node_id).to_s, block: true)
        when NodeType::TABLE
          @out << "<table>\n"
          render_table(node_id)
          @out << "</table>\n"
        when NodeType::TEXT
          @out << CGI.escapeHTML(@arena.text(node_id).to_s)
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
          @out << "<code>#{CGI.escapeHTML(@arena.text(node_id).to_s)}</code>"
        when NodeType::LINK
          dest = CGI.escapeHTML(@arena.str1(node_id).to_s)
          @out << %(<a href="#{dest}")
          append_title_attribute(node_id)
          @out << ">"
          render_children(node_id)
          @out << "</a>"
        when NodeType::IMAGE
          alt = collect_plain_text(node_id)
          dest = CGI.escapeHTML(@arena.str1(node_id).to_s)
          @out << %(<img src="#{dest}" alt="#{CGI.escapeHTML(alt)}")
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
        parent_id = @arena.parent(node_id)
        tight = parent_id != -1 && @arena.type(parent_id) == NodeType::LIST && @arena.int3(parent_id) == 1
        @out << "\n" unless tight

        child_id = @arena.first_child(node_id)
        until child_id == -1
          if tight && @arena.type(child_id) == NodeType::PARAGRAPH
            render_children(child_id)
          else
            render_node(child_id)
          end
          child_id = @arena.next_sibling(child_id)
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

      def render_raw_html(text, block:)
        if @document.allow_html?
          @out << text
          @out << "\n" if block
        else
          escaped = CGI.escapeHTML(text)
          if block
            @out << escaped << "\n"
          else
            @out << escaped
          end
        end
      end

      def collect_plain_text(node_id)
        text = +""
        @arena.each_child(node_id) do |child_id|
          case @arena.type(child_id)
          when NodeType::TEXT, NodeType::CODE_SPAN
            text << @arena.text(child_id).to_s
          when NodeType::SOFTBREAK, NodeType::HARDBREAK
            text << " "
          else
            text << collect_plain_text(child_id)
          end
        end
        text
      end

      def append_title_attribute(node_id)
        title = @arena.str2(node_id).to_s
        return if title.empty?

        @out << %( title="#{CGI.escapeHTML(title)}")
      end
    end
  end
end
