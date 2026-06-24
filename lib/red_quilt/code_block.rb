# frozen_string_literal: true

module RedQuilt
  # Fenced and indented code blocks (CommonMark 4.4 / 4.5). The module
  # functions detect a code-block start; the nested Parser builds the arena
  # node, mirroring the List / Blockquote split (detection used by the
  # block dispatch, construction by a cached collaborator).
  module CodeBlock
    module_function

    # Detects a fenced code opener. Returns a Hash describing the fence
    # ({ char:, count:, info:, indent: }) or nil.
    def fenced_start(text)
      match = /\A( {0,3})(`{3,}|~{3,})[ \t]*(.*?)\s*\z/.match(text)
      return unless match

      info = match[3]
      # CommonMark: a backtick-style fence cannot have backticks in its
      # info string (they'd be ambiguous with the fence itself).
      return if match[2].start_with?("`") && info.include?("`")

      {
        char: match[2][0],
        count: match[2].length,
        info: ReferenceDefinition.unescape_text(info),
        indent: match[1].length,
      }
    end

    # True when `text` is an indented code line: 4+ columns of leading
    # whitespace (tabs expand to a 4-column tab stop).
    def indented_line?(text)
      Indentation.leading_columns(text) >= 4
    end

    # Cached collaborator for BlockParser. A single instance is created in
    # BlockParser#initialize and reused; per-call state lives in method
    # locals so reentrant calls are safe.
    class Parser
      def initialize(block_parser)
        @arena = block_parser.arena
      end

      # Parses a fenced block. `fence` is CodeBlock.fenced_start's result
      # for lines[index]. Returns the index past the block.
      def parse_fenced(parent_id, lines, index, fence)
        start_line = lines[index]
        content_lines = []
        index += 1
        while index < lines.length
          break if fence_close?(lines[index].content, fence[:char], fence[:count])

          content_lines << lines[index]
          index += 1
        end
        index += 1 if index < lines.length

        # Each content line is stripped of up to the fence's own leading
        # indent (CommonMark spec: a fence indented by N spaces strips up
        # to N spaces from every content line, but never more). Manual
        # byte scan beats compiling an interpolated regex per block and
        # short-circuits when the fence had no indent (the common case).
        indent_n = fence[:indent] || 0
        code = content_lines.map { |l| Indentation.strip_leading_spaces(l.content, indent_n) }.join("\n")
        code << "\n" unless content_lines.empty?
        source_start = content_lines.empty? ? start_line.start_byte : content_lines.first.start_byte
        source_end = content_lines.empty? ? start_line.end_byte : content_lines.last.end_byte
        code_id = @arena.add_node(NodeType::CODE_BLOCK,
                                  source_start: source_start,
                                  source_len: source_end - source_start,
                                  str1: code,
                                  str2: fence[:info])
        @arena.append_child(parent_id, code_id)
        index
      end

      # Parses an indented code block. Returns the index past the block.
      def parse_indented(parent_id, lines, index)
        start_index = index
        code_lines = []
        while index < lines.length
          line = lines[index]
          break unless line.blank || CodeBlock.indented_line?(line.content)

          # CommonMark: strip up to 4 columns of leading whitespace
          # (tab-aware) from every line, including blank lines whose
          # content beyond column 4 must be preserved verbatim.
          code_lines << Indentation.strip_columns(line.content, 4)
          index += 1
        end

        # Trailing blank lines are not part of the code block.
        while !code_lines.empty? && code_lines.last.strip.empty?
          code_lines.pop
          index -= 1
        end

        start_byte = lines[start_index].start_byte
        end_byte = lines[index - 1].end_byte
        code = code_lines.empty? ? "" : code_lines.join("\n") + "\n"

        code_id = @arena.add_node(NodeType::CODE_BLOCK,
                                  source_start: start_byte,
                                  source_len: end_byte - start_byte,
                                  str1: code)
        @arena.append_child(parent_id, code_id)
        index
      end

      private

      def fence_close?(text, char, count)
        # Manual byte scan beats compiling a per-(char,count) regex on
        # every line of a fenced block. Pattern: 0-3 spaces, >=count of
        # `char`, optional trailing spaces/tabs, end-of-line.
        bytes = text.bytesize
        i = 0
        # CommonMark spec: at most 3 spaces of indent.
        while i < 3 && i < bytes && text.getbyte(i) == 0x20
          i += 1
        end
        char_byte = char.getbyte(0)
        fence_start = i
        while i < bytes && text.getbyte(i) == char_byte
          i += 1
        end
        return false if i - fence_start < count

        while i < bytes
          b = text.getbyte(i)
          return false unless b == 0x20 || b == 0x09

          i += 1
        end
        true
      end
    end
  end
end
