# frozen_string_literal: true

module Mdarena
  class SourceSpan
    attr_reader :start_byte, :end_byte

    def initialize(start_byte, end_byte)
      @start_byte = start_byte
      @end_byte = end_byte
    end

    def length
      @end_byte - @start_byte
    end

    def ==(other)
      other.is_a?(SourceSpan) &&
        other.start_byte == @start_byte &&
        other.end_byte == @end_byte
    end
  end
end
