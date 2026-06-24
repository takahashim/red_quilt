# frozen_string_literal: true

module RedQuilt
  # A single source line as seen by the block parser and its
  # collaborators (Blockquote, List). `content` is the line text with any
  # container prefix already stripped; `start_byte`/`end_byte` locate it
  # in the original source. `blank` marks whitespace-only lines and
  # `lazy_continuation` flags lines folded into an open paragraph.
  #
  # Positional (not keyword_init): one Line is built per source line, so
  # the ~2.5x faster positional constructor matters on large documents.
  # Argument order: content, start_byte, end_byte, blank, lazy_continuation.
  Line = Struct.new(:content, :start_byte, :end_byte, :blank, :lazy_continuation) do
    # Byte length of the line's span in the original source.
    def span_len
      end_byte - start_byte
    end
  end
end
