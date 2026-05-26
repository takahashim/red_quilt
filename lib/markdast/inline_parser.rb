# frozen_string_literal: true

require "cgi"

module Markdast
  class InlineParser
    SAFE_SCHEMES = %w[http https mailto ftp tel ssh].freeze

    def initialize(arena, parent_id:, source_text:, base_offset: nil, references: {})
      @arena = arena
      @parent_id = parent_id
      @scanner = InlineScanner.new(source_text)
      @base_offset = base_offset
      @references = references
    end

    def parse
      parse_into(@parent_id, terminator: nil)
    end

    private

    def parse_into(parent_id, terminator:)
      until @scanner.eof?
        break if terminator && @scanner.peek(terminator.length) == terminator

        start_byte = @scanner.byte_index
        if @scanner.peek == "\n"
          parse_line_break(parent_id, start_byte)
        elsif @scanner.peek == "\\" && @scanner.peek(2) == "\\\n"
          @scanner.advance(2)
          @arena.append_child(parent_id, add_inline_node(NodeType::HARDBREAK, start_byte, str1: "\n"))
        elsif triple_delimiter_open?
          parse_triple_emphasis(parent_id, @scanner.advance(3), start_byte)
        elsif @scanner.peek == "`"
          parse_code_span(parent_id, start_byte)
        elsif @scanner.peek(2) == "**" || @scanner.peek(2) == "__"
          parse_emphasis(parent_id, @scanner.advance(2), NodeType::STRONG, start_byte)
        elsif @scanner.peek == "*" || emphasis_underscore_open?
          parse_emphasis(parent_id, @scanner.advance(1), NodeType::EMPHASIS, start_byte)
        elsif @scanner.peek == "!" && @scanner.peek(2) == "!["
          parse_image(parent_id, start_byte)
        elsif @scanner.peek == "["
          parse_link(parent_id, start_byte)
        elsif @scanner.peek == "<"
          parse_html_inline(parent_id, start_byte)
        elsif @scanner.peek == "&"
          parse_entity(parent_id, start_byte)
        else
          text = @scanner.scan_text
          text = @scanner.advance(1) if text.empty?
          append_text(parent_id, text, start_byte: start_byte, end_byte: @scanner.byte_index, literal: false)
        end
      end
      @scanner.advance(terminator.length) if terminator && @scanner.peek(terminator.length) == terminator
    end

    def parse_line_break(parent_id, start_byte)
      @scanner.advance(1)
      break_type = trim_trailing_spaces_for_hardbreak(parent_id) ? NodeType::HARDBREAK : NodeType::SOFTBREAK
      @arena.append_child(parent_id, add_inline_node(break_type, start_byte, str1: "\n"))
    end

    def parse_code_span(parent_id, start_byte)
      delimiter = consume_backtick_run
      content_start = @scanner.index

      until @scanner.eof?
        if @scanner.peek == "`"
          run_start = @scanner.index
          run = consume_backtick_run
          if run == delimiter
            raw_content = @scanner.text_slice(content_start, run_start)
            @arena.append_child(
              parent_id,
              add_inline_node(NodeType::CODE_SPAN, start_byte, str1: normalize_code_span(raw_content))
            )
            return
          end
        else
          @scanner.advance(1)
        end
      end

      append_text(parent_id, delimiter, start_byte: start_byte, end_byte: start_byte + delimiter.bytesize, literal: true)
    end

    def parse_emphasis(parent_id, delimiter, type, start_byte)
      closing = find_emphasis_closing(delimiter, type)
      return append_text(parent_id, delimiter, start_byte: start_byte, end_byte: @scanner.byte_index, literal: true) unless closing

      content = @scanner.advance(closing)
      @scanner.advance(delimiter.length)
      node_id = add_inline_node(type, start_byte)
      @arena.append_child(parent_id, node_id)
      parse_child(node_id, content, child_base_offset(start_byte, delimiter.bytesize))
    end

    def parse_triple_emphasis(parent_id, delimiter, start_byte)
      closing = @scanner.rindex_from(delimiter)
      return append_text(parent_id, delimiter, start_byte: start_byte, end_byte: @scanner.byte_index, literal: true) unless closing

      content = @scanner.advance(closing)
      @scanner.advance(delimiter.length)

      emphasis_id = add_inline_node(NodeType::EMPHASIS, start_byte)
      @arena.append_child(parent_id, emphasis_id)

      strong_id = @arena.add_node(NodeType::STRONG)
      @arena.append_child(emphasis_id, strong_id)

      parse_child(strong_id, content, child_base_offset(start_byte, delimiter.bytesize))
    end

    def parse_link(parent_id, start_byte)
      parts = extract_link_like(@scanner.remaining, image: false)
      parts ||= extract_reference_like(@scanner.remaining, image: false)
      return append_text(parent_id, @scanner.advance(1), start_byte: start_byte, end_byte: @scanner.byte_index, literal: true) unless parts

      @scanner.advance(parts[:raw].length)
      node_id = add_inline_node(NodeType::LINK, start_byte, str1: sanitize_destination(parts[:destination]), str2: parts[:title])
      @arena.append_child(parent_id, node_id)
      parse_child(node_id, parts[:label], child_base_offset(start_byte, parts[:raw].start_with?("![") ? 2 : 1))
    end

    def parse_image(parent_id, start_byte)
      parts = extract_link_like(@scanner.remaining, image: true)
      parts ||= extract_reference_like(@scanner.remaining, image: true)
      return append_text(parent_id, @scanner.advance(1), start_byte: start_byte, end_byte: @scanner.byte_index, literal: true) unless parts

      @scanner.advance(parts[:raw].length)
      node_id = add_inline_node(NodeType::IMAGE, start_byte, str1: sanitize_destination(parts[:destination]), str2: parts[:title])
      @arena.append_child(parent_id, node_id)
      parse_child(node_id, parts[:label], child_base_offset(start_byte, 2))
    end

    def parse_html_inline(parent_id, start_byte)
      if (autolink = uri_autolink)
        @scanner.advance(autolink[:raw].length)
        node_id = add_inline_node(NodeType::LINK, start_byte, str1: autolink[:destination])
        @arena.append_child(parent_id, node_id)
        @arena.append_child(node_id, @arena.add_node(NodeType::TEXT, str1: autolink[:label]))
        return
      end

      if (autolink = email_autolink)
        @scanner.advance(autolink[:raw].length)
        node_id = add_inline_node(NodeType::LINK, start_byte, str1: "mailto:#{autolink[:email]}")
        @arena.append_child(parent_id, node_id)
        @arena.append_child(node_id, @arena.add_node(NodeType::TEXT, str1: autolink[:email]))
        return
      end

      match = html_tag_match
      return append_text(parent_id, @scanner.advance(1), start_byte: start_byte, end_byte: @scanner.byte_index, literal: true) unless match

      @scanner.advance(match[0].length)
      @arena.append_child(parent_id, add_inline_node(NodeType::HTML_INLINE, start_byte, str1: match[0]))
    end

    ENTITY_RE = /\G&(?:[A-Za-z][A-Za-z0-9]+|#\d+|#x[0-9A-Fa-f]+);/.freeze

    def parse_entity(parent_id, start_byte)
      match = @scanner.match_at(ENTITY_RE)
      return append_text(parent_id, @scanner.advance(1), start_byte: start_byte, end_byte: @scanner.byte_index, literal: true) unless match

      @scanner.advance(match[0].length)
      append_text(parent_id, CGI.unescapeHTML(match[0]), start_byte: start_byte, end_byte: @scanner.byte_index, literal: true)
    end

    def append_text(parent_id, text, start_byte:, end_byte:, literal:)
      return if text.nil? || text.empty?

      last_child = @arena.last_child(parent_id)
      if mergeable_text?(last_child, literal)
        merged = @arena.str1(last_child) + text
        @arena.replace_str1(last_child, merged)
        @arena.update_span(last_child, @arena.source_start(last_child), source_end(end_byte)) if @base_offset
      else
        node = if literal || @base_offset.nil?
                 add_inline_node(NodeType::TEXT, start_byte, end_byte, str1: text)
               else
                 add_inline_node(NodeType::TEXT, start_byte, end_byte)
               end
        @arena.append_child(parent_id, node)
      end
    end

    def sanitize_destination(destination)
      return "" if destination.nil?
      return destination if destination.start_with?("/", "#")

      scheme = destination[%r{\A([a-zA-Z][a-zA-Z0-9+\-.]*):}, 1]
      return destination if scheme.nil?
      return destination if SAFE_SCHEMES.include?(scheme.downcase)

      ""
    end

    def extract_link_like(source, image:)
      prefix = image ? "![" : "["
      return unless source.start_with?(prefix)

      label_start = prefix.length
      label_end = source.index("](", label_start)
      return unless label_end

      label = source[label_start...label_end]
      body_start = label_end + 2
      depth = 1
      index = body_start

      while index < source.length
        char = source[index]
        if char == "("
          depth += 1
        elsif char == ")"
          depth -= 1
          break if depth.zero?
        end
        index += 1
      end

      return unless depth.zero?

      body = source[body_start...index]
      raw = source[0..index]
      destination, title = split_destination_and_title(body)
      return if destination.nil? || destination.empty?

      { raw: raw, label: label, destination: destination, title: title }
    end

    def extract_reference_like(source, image:)
      prefix = image ? "![" : "["
      return unless source.start_with?(prefix)

      label_start = prefix.length
      label_end = source.index("]", label_start)
      return unless label_end

      label = source[label_start...label_end]
      remainder = source[(label_end + 1)..] || ""

      if remainder.start_with?("[")
        ref_end = remainder.index("]")
        return unless ref_end
        ref_label = remainder[1...ref_end]
        reference = lookup_reference(ref_label.empty? ? label : ref_label)
        return unless reference

        return {
          raw: source[0...(label_end + 2 + ref_end)],
          label: label,
          destination: reference[:destination],
          title: reference[:title]
        }
      end

      reference = lookup_reference(label)
      return unless reference

      {
        raw: source[0..label_end],
        label: label,
        destination: reference[:destination],
        title: reference[:title]
      }
    end

    def split_destination_and_title(body)
      match = /\A(\S+)\s+"([^"]*)"\z/.match(body)
      return [match[1], match[2]] if match

      [body.strip, nil]
    end

    def emphasis_underscore_open?
      return false unless @scanner.peek == "_"

      prev_char = @scanner.char_before
      next_char = @scanner.char_at(1)
      !(word_char?(prev_char) && word_char?(next_char))
    end

    def word_char?(char)
      char&.match?(/[[:alnum:]]/)
    end

    def lookup_reference(label)
      @references[normalize_reference_label(label)]
    end

    def normalize_reference_label(label)
      label.to_s.strip.downcase.gsub(/[ \t\r\n]+/, " ")
    end

    URI_AUTOLINK_RE = /\G<([A-Za-z][A-Za-z0-9+.-]{1,31}:[^<>\u0000-\u0020]*)>/.freeze

    def uri_autolink
      match = @scanner.match_at(URI_AUTOLINK_RE)
      return unless match
      { raw: match[0], destination: match[1], label: match[1] }
    end

    EMAIL_AUTOLINK_RE = /\G<([a-zA-Z0-9.!#$%&'*+\/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*)>/.freeze
    HTML_TAG_RE = %r{\G</?[A-Za-z][A-Za-z0-9-]*(?:\s+[A-Za-z_:][A-Za-z0-9_.:-]*(?:\s*=\s*(?:"[^"\n]*"|'[^'\n]*'|[^\s"'=<>`]+))?)*\s*/?>}.freeze

    def email_autolink
      match = @scanner.match_at(EMAIL_AUTOLINK_RE)
      return unless match
      { raw: match[0], email: match[1] }
    end

    def html_tag_match
      @scanner.match_at(HTML_TAG_RE)
    end

    def find_emphasis_closing(delimiter, type)
      unless type == NodeType::EMPHASIS && delimiter.length == 1
        return @scanner.rindex_from(delimiter)
      end

      d = delimiter
      text = @scanner.text
      len = text.length
      base = @scanner.index
      i = base
      single_count = 0
      double_count = 0
      last_valid = nil

      while i < len
        if text[i] == d
          prev_same = i > base && text[i - 1] == d
          next_same = i + 1 < len && text[i + 1] == d
          if !prev_same && next_same
            pair_next2 = i + 2 < len && text[i + 2] == d
            unless pair_next2
              double_count += 1
              i += 2
              next
            end
          elsif !prev_same && !next_same
            if single_count.even? && double_count.even?
              return i - base
            end
            single_count += 1
            last_valid = i - base
          end
        end
        i += 1
      end

      last_valid
    end

    def triple_delimiter_open?
      @scanner.peek(3) == "***" || @scanner.peek(3) == "___"
    end

    def consume_backtick_run
      start_index = @scanner.index
      @scanner.advance(1) while @scanner.peek == "`"
      @scanner.text_slice(start_index, @scanner.index)
    end

    def normalize_code_span(text)
      normalized = text.gsub(/\r\n?|\n/, " ")
      return normalized if normalized.match?(/\A +\z/)
      return normalized[1...-1] if normalized.start_with?(" ") && normalized.end_with?(" ")

      normalized
    end

    def src_start(start_byte)
      @base_offset ? @base_offset + start_byte : -1
    end

    def src_len(start_byte, end_byte)
      @base_offset ? end_byte - start_byte : 0
    end

    def source_end(end_byte)
      @base_offset + end_byte
    end

    def add_inline_node(type, start_byte, end_byte = nil, str1: nil, str2: nil)
      end_byte ||= @scanner.byte_index
      @arena.add_node(type,
                      source_start: src_start(start_byte),
                      source_len: src_len(start_byte, end_byte),
                      str1: str1,
                      str2: str2)
    end

    def child_base_offset(start_byte, prefix_bytesize)
      @base_offset ? @base_offset + start_byte + prefix_bytesize : nil
    end

    def parse_child(parent_id, source_text, child_offset)
      self.class.new(@arena, parent_id: parent_id, source_text: source_text, base_offset: child_offset, references: @references).parse
    end

    def mergeable_text?(last_child, literal)
      return false if last_child == -1
      return false unless @arena.type(last_child) == NodeType::TEXT
      return false unless !@arena.str1(last_child).nil?

      literal || @arena.source_span(last_child).nil?
    end

    def trim_trailing_spaces_for_hardbreak(parent_id)
      last_child = @arena.last_child(parent_id)
      return false if last_child == -1
      return false unless @arena.type(last_child) == NodeType::TEXT

      text = @arena.text(last_child).to_s
      trimmed = text.sub(/ {2,}\z/, "")
      return false if trimmed == text

      removed = text.length - trimmed.length
      if @arena.str1(last_child).nil?
        @arena.replace_text(last_child, trimmed, source_start: @arena.source_start(last_child), source_len: @arena.source_len(last_child) - removed)
      else
        @arena.replace_text(last_child, trimmed)
      end
      true
    end
  end
end
