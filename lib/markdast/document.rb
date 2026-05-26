# frozen_string_literal: true

module Markdast
  class Document
    attr_reader :source, :arena, :root_id

    def initialize(source, arena, root_id, allow_html: false, references: {})
      @source = source
      @arena = arena
      @root_id = root_id
      @allow_html = allow_html
      @references = references
    end

    def allow_html?
      @allow_html
    end

    def references
      @references
    end

    def root
      NodeRef.new(self, @root_id)
    end

    def to_html
      Renderer::HTML.new(self).render
    end

    def to_ast
      root.to_h
    end
  end
end
