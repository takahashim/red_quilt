# frozen_string_literal: true

module Markdast
  class InlineScanner
    SPECIAL = ["*", "_", "`", "[", "]", "(", ")", "!", "<", "&", "\\", "\n"].freeze

    def initialize(text)
      @text = text
      @index = 0
    end

    attr_reader :index

    def eof?
      @index >= @text.length
    end

    def peek(length = 1)
      @text[@index, length]
    end

    def advance(count = 1)
      chunk = @text[@index, count]
      @index += count
      chunk
    end

    def scan_text
      start = @index
      @index += 1 while @index < @text.length && !SPECIAL.include?(@text[@index])
      @text[start...@index]
    end

    def remaining
      @text[@index..] || ""
    end

    def text_slice(start_index, end_index)
      @text[start_index...end_index]
    end
  end
end
