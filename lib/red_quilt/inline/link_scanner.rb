# frozen_string_literal: true

module RedQuilt
  module Inline
    # Pure byte-level scanner for link / image tails: inline link bodies
    # `(dest "title")`, bracketed reference labels `[label]`, and link
    # destination URI normalization. Operates only on the document source
    # string -- no arena, token stream, or parser state -- so it can be
    # exercised in isolation. Inline::Builder owns one instance and feeds
    # it absolute byte offsets.
    class LinkScanner
      NIL_PAIR = [nil, nil].freeze
      # Bytes left verbatim by normalize_uri: ASCII alphanumerics plus the
      # URL sub-delims / reserved chars that the spec keeps unencoded.
      # Everything else is percent-encoded.
      URL_SAFE_BYTE = begin
        a = Array.new(256, false)
        (0x30..0x39).each { |b| a[b] = true } # 0-9
        (0x41..0x5A).each { |b| a[b] = true } # A-Z
        (0x61..0x7A).each { |b| a[b] = true } # a-z
        "-._~:/?#@!$&'()*+,;=".each_byte { |b| a[b] = true }
        a.freeze
      end

      def initialize(source)
        @source = source
      end

      # Parses an inline link body `(dest "title")` starting at the byte
      # right after the link's closing `]`. Returns a hash with
      # `:end_byte`, `:destination`, `:title` on success, or nil if the
      # bytes don't form a valid inline link tail.
      def inline_link(start_byte)
        return nil unless byte_at(start_byte) == 0x28

        pos = start_byte + 1
        pos = skip_link_whitespace(pos)
        return nil if pos.nil?

        raw_dest = nil
        next_byte = byte_at(pos)
        if next_byte && next_byte != 0x29 && !link_tail_whitespace_byte?(next_byte) && next_byte != 0x0A
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

        destination = raw_dest ? normalize_uri(raw_dest) : ""
        title = raw_title ? decode_link_entities(raw_title) : nil
        { end_byte: pos + 1, destination: destination, title: title }
      end

      # Reads a bracketed reference label `[label]` starting at start_byte
      # (which must point at the `[`). Returns [label, after_byte] or
      # NIL_PAIR when the label is malformed or over-long.
      def reference_label(start_byte)
        return NIL_PAIR unless @source.getbyte(start_byte) == 0x5B

        i = start_byte + 1
        while i < @source.bytesize
          b = @source.getbyte(i)
          if b == 0x5D
            label = @source.byteslice(start_byte + 1, i - start_byte - 1).to_s
            return NIL_PAIR if ReferenceDefinition.label_too_long?(label)

            return [label, i + 1]
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

      # Percent-encodes bytes not in the URL-safe set, decodes HTML
      # entities first, and preserves (uppercasing) existing `%XX`.
      def normalize_uri(raw)
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
          elsif URL_SAFE_BYTE[b]
            result << b.chr
            i += 1
          else
            result << format("%%%02X", b)
            i += 1
          end
        end
        result
      end

      private

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
          elsif !link_tail_whitespace_byte?(b)
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
            if nb && Inline.ascii_punct_byte?(nb)
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
            if nb && Inline.ascii_punct_byte?(nb)
              result << nb
              pos += 2
              next
            end
            result << b
            pos += 1
            next
          end

          break if link_tail_whitespace_byte?(b) || b < 0x20 || b == 0x7F

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
            if nb && Inline.ascii_punct_byte?(nb)
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

      def decode_link_entities(raw)
        raw.gsub(Inline::ENTITY_RE) { |m| Inline.decode_entity(m) }
      end

      def byte_at(pos)
        return nil if pos < 0 || pos >= @source.bytesize

        @source.getbyte(pos)
      end

      # Whitespace allowed as a link-tail separator per CommonMark 6.3:
      # "spaces, tabs, and up to one line ending". Line endings are
      # counted by the caller, so this predicate intentionally matches
      # only space and tab -- it must NOT match form feed (U+000C) or
      # vertical tab (U+000B) the way the generic \s class does.
      def link_tail_whitespace_byte?(b)
        b == 0x20 || b == 0x09
      end

      def hex_byte?(b)
        (b >= 0x30 && b <= 0x39) ||
          (b >= 0x41 && b <= 0x46) ||
          (b >= 0x61 && b <= 0x66)
      end
    end
  end
end
