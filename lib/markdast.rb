# frozen_string_literal: true

require_relative "markdast/version"
require_relative "markdast/node_type"
require_relative "markdast/source_span"
require_relative "markdast/arena"
require_relative "markdast/node_ref"
require_relative "markdast/document"
require_relative "markdast/block_parser"
require_relative "markdast/inline_scanner"
require_relative "markdast/inline_parser"
require_relative "markdast/inline_pass"
require_relative "markdast/renderer/html"

module Markdast
  class Error < StandardError; end

  class << self
    def parse(source, allow_html: false)
      normalized = source.to_s.dup.force_encoding(Encoding::UTF_8)
      arena = Arena.new(normalized)
      block_parser = BlockParser.new(arena)
      root_id = block_parser.parse
      document = Document.new(normalized, arena, root_id, allow_html: allow_html, references: block_parser.references)
      InlinePass.new(document).apply
      document
    end

    def render_html(source, allow_html: false)
      parse(source, allow_html: allow_html).to_html
    end
  end
end
