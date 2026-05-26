# frozen_string_literal: true

module Markdast
  module Inline
    # Consumes a token stream produced by Lexer and adds inline nodes
    # to the arena under parent_id.
    #
    # Processing happens in two phases:
    #   1. linear_pass — code spans, brackets (link/image), autolinks,
    #      HTML, simple inlines. Emphasis delimiter runs are added as
    #      provisional TEXT nodes and pushed onto a delimiter stack.
    #   2. process_emphasis — CommonMark spec 6.2 algorithm pairs up
    #      delimiter stack entries into EMPHASIS / STRONG nodes.
    class Builder
      def initialize(arena, source, references)
        @arena = arena
        @source = source
        @references = references
      end

      def build(parent_id, tokens)
        @parent_id = parent_id
        @tokens = tokens
        @delimiter_stack = []
        linear_pass
        process_emphasis
      end

      private

      def linear_pass
        # TODO(commit 5..7): consume tokens and populate the arena.
      end

      def process_emphasis
        # TODO(commit 8): delimiter stack resolution.
      end
    end
  end
end
