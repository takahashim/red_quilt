# frozen_string_literal: true

require "cgi"

module Markdast
  class InlineParser
    SAFE_SCHEMES = %w[http https mailto].freeze

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

        start_index = @scanner.index
        if @scanner.peek == "\n"
          parse_line_break(parent_id, start_index)
        elsif @scanner.peek == "\\" && @scanner.peek(2) == "\\\n"
          @scanner.advance(2)
          @arena.append_child(parent_id, @arena.add_node(NodeType::HARDBREAK, **source_attributes(start_index, @scanner.index), str1: "\n"))
        elsif triple_delimiter_open?
          parse_triple_emphasis(parent_id, @scanner.advance(3), start_index)
        elsif @scanner.peek == "`"
          parse_code_span(parent_id, start_index)
        elsif @scanner.peek(2) == "**" || @scanner.peek(2) == "__"
          parse_emphasis(parent_id, @scanner.advance(2), NodeType::STRONG, start_index)
        elsif @scanner.peek == "*" || emphasis_underscore_open?
          parse_emphasis(parent_id, @scanner.advance(1), NodeType::EMPHASIS, start_index)
        elsif @scanner.peek == "!" && @scanner.peek(2) == "!["
          parse_image(parent_id, start_index)
        elsif @scanner.peek == "["
          parse_link(parent_id, start_index)
        elsif @scanner.peek == "<"
          parse_html_inline(parent_id, start_index)
        elsif @scanner.peek == "&"
          parse_entity(parent_id, start_index)
        else
          text = @scanner.scan_text
          text = @scanner.advance(1) if text.empty?
          append_text(parent_id, text, start_index: start_index, end_index: @scanner.index, literal: false)
        end
      end
      @scanner.advance(terminator.length) if terminator && @scanner.peek(terminator.length) == terminator
    end

    def parse_line_break(parent_id, start_index)
      @scanner.advance(1)
      break_type = trim_trailing_spaces_for_hardbreak(parent_id) ? NodeType::HARDBREAK : NodeType::SOFTBREAK
      @arena.append_child(parent_id, @arena.add_node(break_type, **source_attributes(start_index, @scanner.index), str1: "\n"))
    end

    def parse_code_span(parent_id, start_index)
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
              @arena.add_node(NodeType::CODE_SPAN, **source_attributes(start_index, @scanner.index), str1: normalize_code_span(raw_content))
            )
            return
          end
        else
          @scanner.advance(1)
        end
      end

      append_text(parent_id, delimiter, start_index: start_index, end_index: start_index + delimiter.length, literal: true)
    end

    def parse_emphasis(parent_id, delimiter, type, start_index)
      closing = @scanner.remaining.index(delimiter)
      return append_text(parent_id, delimiter, start_index: start_index, end_index: @scanner.index, literal: true) unless closing

      content = @scanner.advance(closing)
      @scanner.advance(delimiter.length)
      node_id = @arena.add_node(type, **source_attributes(start_index, @scanner.index))
      @arena.append_child(parent_id, node_id)
      child_offset = @base_offset ? @base_offset + start_index + delimiter.length : nil
      self.class.new(@arena, parent_id: node_id, source_text: content, base_offset: child_offset, references: @references).parse
    end

    def parse_triple_emphasis(parent_id, delimiter, start_index)
      closing = @scanner.remaining.index(delimiter)
      return append_text(parent_id, delimiter, start_index: start_index, end_index: @scanner.index, literal: true) unless closing

      content = @scanner.advance(closing)
      @scanner.advance(delimiter.length)

      emphasis_id = @arena.add_node(NodeType::EMPHASIS, **source_attributes(start_index, @scanner.index))
      @arena.append_child(parent_id, emphasis_id)

      strong_id = @arena.add_node(NodeType::STRONG)
      @arena.append_child(emphasis_id, strong_id)

      child_offset = @base_offset ? @base_offset + start_index + delimiter.length : nil
      self.class.new(@arena, parent_id: strong_id, source_text: content, base_offset: child_offset, references: @references).parse
    end

    def parse_link(parent_id, start_index)
      parts = extract_link_like(@scanner.remaining, image: false)
      parts ||= extract_reference_like(@scanner.remaining, image: false)
      return append_text(parent_id, @scanner.advance(1), start_index: start_index, end_index: @scanner.index, literal: true) unless parts

      @scanner.advance(parts[:raw].length)
      node_id = @arena.add_node(NodeType::LINK, **source_attributes(start_index, @scanner.index), str1: sanitize_destination(parts[:destination]), str2: parts[:title])
      @arena.append_child(parent_id, node_id)
      child_offset = @base_offset ? @base_offset + start_index + (parts[:raw].start_with?("![") ? 2 : 1) : nil
      self.class.new(@arena, parent_id: node_id, source_text: parts[:label], base_offset: child_offset, references: @references).parse
    end

    def parse_image(parent_id, start_index)
      parts = extract_link_like(@scanner.remaining, image: true)
      parts ||= extract_reference_like(@scanner.remaining, image: true)
      return append_text(parent_id, @scanner.advance(1), start_index: start_index, end_index: @scanner.index, literal: true) unless parts

      @scanner.advance(parts[:raw].length)
      node_id = @arena.add_node(NodeType::IMAGE, **source_attributes(start_index, @scanner.index), str1: sanitize_destination(parts[:destination]), str2: parts[:title])
      @arena.append_child(parent_id, node_id)
      child_offset = @base_offset ? @base_offset + start_index + 2 : nil
      self.class.new(@arena, parent_id: node_id, source_text: parts[:label], base_offset: child_offset, references: @references).parse
    end

    def parse_html_inline(parent_id, start_index)
      source = @scanner.remaining
      match = /\A<[^>\n]+>/.match(source)
      return append_text(parent_id, @scanner.advance(1), start_index: start_index, end_index: @scanner.index, literal: true) unless match

      @scanner.advance(match[0].length)
      @arena.append_child(parent_id, @arena.add_node(NodeType::HTML_INLINE, **source_attributes(start_index, @scanner.index), str1: match[0]))
    end

    def parse_entity(parent_id, start_index)
      source = @scanner.remaining
      match = /\A&(?:[A-Za-z][A-Za-z0-9]+|#\d+|#x[0-9A-Fa-f]+);/.match(source)
      return append_text(parent_id, @scanner.advance(1), start_index: start_index, end_index: @scanner.index, literal: true) unless match

      @scanner.advance(match[0].length)
      append_text(parent_id, CGI.unescapeHTML(match[0]), start_index: start_index, end_index: @scanner.index, literal: true)
    end

    def append_text(parent_id, text, start_index:, end_index:, literal:)
      return if text.nil? || text.empty?

      last_child = @arena.last_child(parent_id)
      if mergeable_text?(last_child, literal)
        merged = @arena.str1(last_child) + text
        @arena.replace_str1(last_child, merged)
        @arena.update_span(last_child, @arena.source_start(last_child), source_end(end_index)) if @base_offset
      else
        node = if literal || @base_offset.nil?
                 @arena.add_node(NodeType::TEXT, **source_attributes(start_index, end_index), str1: text)
               else
                 @arena.add_node(NodeType::TEXT, **source_attributes(start_index, end_index))
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

      prev_char = @scanner.index.zero? ? nil : @scanner.instance_eval { @text[@index - 1] }
      next_char = @scanner.instance_eval { @text[@index + 1] }
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

    def source_attributes(start_index, end_index)
      return { source_start: -1, source_len: 0 } if @base_offset.nil?

      { source_start: @base_offset + start_index, source_len: end_index - start_index }
    end

    def source_end(end_index)
      @base_offset + end_index
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
