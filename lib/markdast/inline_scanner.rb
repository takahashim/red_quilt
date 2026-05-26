# frozen_string_literal: true

module Markdast
  class InlineScanner
    SPECIAL_RE = /[*_`\[\]()!<&\\\n]/.freeze

    def initialize(text)
      @text = text
      @index = 0
      @byte_index = 0
    end

    attr_reader :index, :text, :byte_index

    def eof?
      @index >= @text.length
    end

    def peek(length = 1)
      @text[@index, length]
    end

    def advance(count = 1)
      chunk = @text[@index, count]
      @index += count
      @byte_index += chunk.bytesize
      chunk
    end

    def scan_text
      rest = @text.index(SPECIAL_RE, @index) || @text.length
      chunk = @text[@index...rest]
      @index = rest
      @byte_index += chunk.bytesize
      chunk
    end

    def char_before
      @index.positive? ? @text[@index - 1] : nil
    end

    def char_at(offset)
      @text[@index + offset]
    end

    def match_at(regex)
      @text.match(regex, @index)
    end

    def rindex_from(delimiter)
      dlen = delimiter.length
      last = nil
      i = @index
      while i <= @text.length - dlen
        last = i - @index if @text[i, dlen] == delimiter
        i += 1
      end
      last
    end

    def remaining
      @text[@index..] || ""
    end

    def text_slice(start_index, end_index)
      @text[start_index...end_index]
    end
  end
end
