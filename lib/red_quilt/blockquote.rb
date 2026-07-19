# frozen_string_literal: true

module RedQuilt
  # CommonMark spec 5.1 blockquotes.
  #
  # Module-level functions are stateless helpers used by BlockParser's
  # predicate dispatch. `Blockquote::Parser` is a cached collaborator
  # created once in BlockParser#initialize and reused for every
  # blockquote (including nested ones) — per-call state lives in method
  # locals so reentrant `#parse` calls are safe.
  module Blockquote
    BLOCKQUOTE_PREFIX_RE = /\A {0,3}>/

    module_function

    def match?(text)
      text.match?(BLOCKQUOTE_PREFIX_RE)
    end

    # Byte offset of the `>` within the line, or nil when there is no prefix.
    # Only spaces may precede it (at most 3), so the character index returned
    # by the match doubles as a byte offset.
    def marker_offset(text)
      match = BLOCKQUOTE_PREFIX_RE.match(text)
      match && (match.end(0) - 1)
    end

    # Strip the leading `>` (and at most one column of whitespace after
    # it) from a blockquote line. Returns a new Line whose
    # content is the inner text. If the line has no `>` prefix, the
    # original line is returned unchanged (wrapped in a fresh Line so
    # the caller treats it uniformly).
    def strip_prefix(line)
      content = line.content
      bytes = content.bytesize
      i = 0
      abs_col = 0
      # Up to 3 spaces of indent before `>`.
      while i < 3 && i < bytes && content.getbyte(i) == 0x20
        i += 1
        abs_col += 1
      end
      unless i < bytes && content.getbyte(i) == 0x3E
        return Line.new(content, line.start_byte, line.end_byte, !content.match?(/\S/))
      end

      i += 1
      abs_col += 1 # consume `>`

      # Count column width of leading whitespace after `>` using
      # absolute-column tracking so a tab right after `>` (at col 1) is
      # correctly billed as only 3 columns of indent, not 4.
      ws_start_col = abs_col
      j = i
      while j < bytes
        b = content.getbyte(j)
        if b == 0x20
          abs_col += 1
        elsif b == 0x09
          abs_col = ((abs_col / 4) + 1) * 4
        else
          break
        end
        j += 1
      end
      ws_cols = abs_col - ws_start_col

      if ws_cols >= 1
        tail = (" " * (ws_cols - 1)) + content.byteslice(j..)
        offset = j
      else
        tail = content.byteslice(i..)
        offset = i
      end

      Line.new(tail, line.start_byte + offset, line.end_byte, !tail.match?(/\S/))
    end

    class Parser
      def initialize(block_parser)
        @block_parser = block_parser
        @arena = block_parser.arena
      end

      def parse(parent_id, lines, index)
        # Captured before the loop: block_lines holds prefix-stripped lines,
        # whose start_byte sits after the `>`. The span must start at the
        # marker itself (excluding indent), as cmark and mdast both report.
        first_line = lines[index]
        source_start = first_line.start_byte + (Blockquote.marker_offset(first_line.content) || 0)
        block_lines = []
        paragraph_open = false

        while index < lines.length
          line = lines[index]

          if line.blank
            # Blank line outside the blockquote prefix closes it.
            break
          elsif Blockquote.match?(line.content)
            stripped = Blockquote.strip_prefix(line)
            paragraph_open =
              if stripped.content.strip.empty?
                false # `>` 単独 (or `>` followed by blank) ends any open paragraph
              else
                # Recurse through any inner blockquote prefixes — an
                # innermost open paragraph (e.g. `> > > foo` where
                # `foo` is paragraph-eligible) lets a `>`-less follow-
                # up line lazily continue it even at the outer level.
                paragraph_eligible_through_blockquotes?(stripped.content)
              end
            block_lines << stripped
          elsif paragraph_open && !@block_parser.lazy_break?(lines, index)
            # Lazy continuation: a `>`-less line is absorbed into the
            # currently open paragraph as long as it doesn't itself
            # start a new block. Only allowed while the most recent
            # in-quote line is paragraph-eligible content. The `lazy`
            # flag prevents the paragraph parser from interpreting
            # `===` / `---` on such a line as a setext underline.
            block_lines << Line.new(line.content, line.start_byte, line.end_byte, line.blank, true)
          else
            break
          end

          index += 1
        end

        block_id = @arena.add_node(NodeType::BLOCKQUOTE,
                                   source_start: source_start,
                                   source_len: block_lines.last.end_byte - source_start)
        @arena.append_child(parent_id, block_id)
        @block_parser.parse_lines(block_id, block_lines, transformed: true)
        index
      end

      private

      # Like BlockParser#paragraph_eligible_line?, but transparently
      # peels any number of leading wrapper prefixes (blockquote `>`
      # and list item markers) to find out whether the innermost block
      # is still paragraph content. Used so `> > > foo\nbar` and
      # `> 1. > foo\nbar` both let the unprefixed line lazily continue
      # the deepest paragraph.
      def paragraph_eligible_through_blockquotes?(content)
        c = content
        loop do
          if Blockquote.match?(c)
            m = /\A {0,3}> ?/.match(c)
            break unless m

            c = c[m[0].length..]
            return false if c.strip.empty?
          elsif (li = List.match(c))
            c = li[:content]
            return false if c.strip.empty?
          else
            break
          end
        end
        @block_parser.paragraph_eligible_line?(c)
      end
    end
  end
end
