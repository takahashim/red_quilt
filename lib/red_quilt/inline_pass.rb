# frozen_string_literal: true

module RedQuilt
  class InlinePass
    INLINE_TARGETS = [NodeType::PARAGRAPH, NodeType::HEADING, NodeType::TABLE_CELL].freeze

    def initialize(document)
      @document = document
      @arena = document.arena
      @lexer = Inline::Lexer.new(@document.source)
      @tokens = Inline::Tokens.new
      @builder = Inline::Builder.new(@arena, @document.source, @document.references,
                                     diagnostics: @document.diagnostics)
    end

    def apply
      visit(@document.root_id)
    end

    private

    def visit(node_id)
      if INLINE_TARGETS.include?(@arena.type(node_id))
        @tokens.clear
        if (literal = @arena.str1(node_id))
          # Heading / paragraph with a materialized literal source (e.g.
          # block-quote / list lines stripped of their continuation prefix).
          # In that case the byte ranges produced by the lexer are relative
          # to `literal`, not the document source, so we build with a
          # dedicated builder that suppresses span tracking.
          Inline::Lexer.new(literal).lex_into(@tokens, 0, literal.bytesize)
          Inline::Builder.new(@arena, literal, @document.references,
                              track_source: false,
                              diagnostics: @document.diagnostics).build(node_id, @tokens)
        else
          start_byte = @arena.source_start(node_id)
          end_byte = start_byte + @arena.source_len(node_id)
          @lexer.lex_into(@tokens, start_byte, end_byte)
          @builder.build(node_id, @tokens)
        end
        return
      end

      child_id = @arena.raw_first_child_id(node_id)
      until child_id == -1
        visit(child_id)
        child_id = @arena.raw_next_sibling_id(child_id)
      end
    end
  end
end
