# frozen_string_literal: true

module RedQuilt
  # Home of the inline-parsing namespace. Sub-components (Lexer, Builder,
  # Tokens, Flanking, ...) live under lib/red_quilt/inline/. Module-level
  # shared primitives that several of them need live here.
  module Inline
    # CommonMark ASCII punctuation: the four byte ranges 0x21-0x2F,
    # 0x3A-0x40, 0x5B-0x60, 0x7B-0x7E. Used for backslash-escape
    # recognition (lexer, builder) and flanking-run boundary detection
    # (flanking). A frozen 256-entry lookup table keeps the hot-path
    # check to a single array index.
    ASCII_PUNCT = begin
      a = Array.new(256, false)
      (0x21..0x2F).each { |b| a[b] = true }
      (0x3A..0x40).each { |b| a[b] = true }
      (0x5B..0x60).each { |b| a[b] = true }
      (0x7B..0x7E).each { |b| a[b] = true }
      a.freeze
    end

    module_function

    def ascii_punct_byte?(byte)
      ASCII_PUNCT[byte]
    end
  end
end
