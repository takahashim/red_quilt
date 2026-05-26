# frozen_string_literal: true

module Markdast
  module Inline
    # Scans a byte range of the document source and emits inline tokens
    # into a caller-owned Tokens storage.
    #
    # The lexer never copies the source string; all positions are absolute
    # byte offsets into @source. The caller is responsible for clearing the
    # Tokens storage between invocations if it is being reused.
    class Lexer
      def initialize(source)
        @source = source
      end

      # Scans @source[start_byte...end_byte] and emits tokens.
      # Returns the tokens object that was passed in.
      def lex_into(tokens, start_byte, end_byte)
        @pos = start_byte
        @end = end_byte
        scan(tokens)
        tokens
      end

      private

      def scan(tokens)
        # TODO(commit 2..4): implement scanning.
        # For now this is a placeholder so that other components can
        # depend on the Lexer interface during scaffolding.
      end
    end
  end
end
