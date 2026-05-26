# frozen_string_literal: true

module Markdast
  module Inline
    # Parallel-array storage for the inline token stream.
    #
    # InlineTokens is intended to be allocated once per document and reused
    # across paragraphs by calling #clear between inline targets. Array#clear
    # resets length to 0 while preserving internal capacity, so subsequent
    # paragraphs avoid reallocating the underlying buffers.
    class Tokens
      def initialize
        @kind = []
        @start_byte = []
        @end_byte = []
        @int1 = []
        @int2 = []
        @int3 = []
        @str1 = []
      end

      def emit(kind, start_byte:, end_byte:, int1: 0, int2: 0, int3: 0, str1: nil)
        id = @kind.length
        @kind[id] = kind
        @start_byte[id] = start_byte
        @end_byte[id] = end_byte
        @int1[id] = int1
        @int2[id] = int2
        @int3[id] = int3
        @str1[id] = str1
        id
      end

      def clear
        @kind.clear
        @start_byte.clear
        @end_byte.clear
        @int1.clear
        @int2.clear
        @int3.clear
        @str1.clear
        self
      end

      def length
        @kind.length
      end

      def empty?
        @kind.empty?
      end

      def kind(id);       @kind[id];       end
      def start_byte(id); @start_byte[id]; end
      def end_byte(id);   @end_byte[id];   end
      def int1(id);       @int1[id];       end
      def int2(id);       @int2[id];       end
      def int3(id);       @int3[id];       end
      def str1(id);       @str1[id];       end

      def each_id
        return enum_for(:each_id) unless block_given?

        id = 0
        last = @kind.length
        while id < last
          yield id
          id += 1
        end
      end
    end
  end
end
