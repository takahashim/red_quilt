# frozen_string_literal: true

module RedQuilt
  # Stateless CommonMark indentation / column arithmetic, shared by the
  # block parser and its collaborator parsers (List, Blockquote, Footnote).
  # Tabs expand to the next multiple of 4 columns.
  module Indentation
    module_function

    # Leading-whitespace width of `text` in columns (tabs expanded to the
    # next tab stop of 4).
    def leading_columns(text)
      col = 0
      i = 0
      bytes = text.bytesize
      while i < bytes
        b = text.getbyte(i)
        if b == 0x20
          col += 1
        elsif b == 0x09
          col = ((col / 4) + 1) * 4
        else
          break
        end
        i += 1
      end
      col
    end

    # Strips up to `n` columns of leading whitespace from `text` and
    # returns the rest. Leading whitespace is normalised to spaces in the
    # returned string so subsequent strips compose correctly regardless of
    # where they land relative to the original tab stops.
    def strip_columns(text, n)
      return text if n <= 0

      col = 0
      i = 0
      bytes = text.bytesize
      while i < bytes
        b = text.getbyte(i)
        if b == 0x20
          col += 1
        elsif b == 0x09
          col = ((col / 4) + 1) * 4
        else
          break
        end
        i += 1
      end
      # text[0...i] is all leading whitespace representing `col` cols.
      if n >= col
        i.zero? ? text : text.byteslice(i..)
      else
        # Keep the unstripped portion as a run of spaces.
        (" " * (col - n)) + text.byteslice(i..)
      end
    end

    # Strips up to `max` leading 0x20 (space) bytes from `text`, returning
    # the rest. Unlike #strip_columns this is a plain byte strip (tabs are
    # not expanded); used where the spec counts literal spaces, e.g. a
    # fenced code block stripping its own opening indent. No-alloc return
    # when `text` already starts at a non-space byte.
    def strip_leading_spaces(text, max)
      return text if max <= 0

      bytes = text.bytesize
      i = 0
      while i < max && i < bytes && text.getbyte(i) == 0x20
        i += 1
      end
      return text if i.zero?

      text.byteslice(i..)
    end

    # Strips all leading 0x20 / 0x09 bytes from `text` (spaces and tabs,
    # no column cap). Same no-alloc return as #strip_leading_spaces when
    # `text` already starts at a non-whitespace byte.
    def strip_leading_whitespace(text)
      bytes = text.bytesize
      i = 0
      while i < bytes
        b = text.getbyte(i)
        break unless b == 0x20 || b == 0x09

        i += 1
      end
      return text if i.zero?

      text.byteslice(i..)
    end

    # Bytes of literal leading 0x20 / 0x09 in `text`.
    def leading_ws_bytes(text)
      i = 0
      bytes = text.bytesize
      while i < bytes
        b = text.getbyte(i)
        break unless b == 0x20 || b == 0x09

        i += 1
      end
      i
    end
  end
end
