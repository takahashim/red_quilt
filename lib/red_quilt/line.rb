# frozen_string_literal: true

module RedQuilt
  # A single source line as seen by the block parser and its
  # collaborators (Blockquote, List). `content` is the line text with any
  # container prefix already stripped; `start_byte`/`end_byte` locate it
  # in the original source. `blank` marks whitespace-only lines and
  # `lazy_continuation` flags lines folded into an open paragraph.
  Line = Struct.new(:content, :start_byte, :end_byte, :blank, :lazy_continuation, keyword_init: true)
end
