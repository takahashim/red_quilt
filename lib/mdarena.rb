# frozen_string_literal: true

require_relative "mdarena/version"
require_relative "mdarena/node_type"
require_relative "mdarena/source_span"
require_relative "mdarena/source_map"
require_relative "mdarena/arena"
require_relative "mdarena/node_ref"
require_relative "mdarena/diagnostic"
require_relative "mdarena/document"
require_relative "mdarena/inline/html_entities"
require_relative "mdarena/reference_definition"
require_relative "mdarena/list"
require_relative "mdarena/blockquote"
require_relative "mdarena/block_parser"
require_relative "mdarena/inline/token_kind"
require_relative "mdarena/inline/tokens"
require_relative "mdarena/inline/flanking"
require_relative "mdarena/inline/lexer"
require_relative "mdarena/inline/builder"
require_relative "mdarena/inline_pass"
require_relative "mdarena/extended_autolink_pass"
require_relative "mdarena/renderer/html"
require_relative "mdarena/renderer/mdast"

module Mdarena
  class Error < StandardError; end

  class << self
    def parse(source, allow_html: false, extended_autolinks: false)
      normalized = source.to_s.dup.force_encoding(Encoding::UTF_8)
      arena = Arena.new(normalized)
      block_parser = BlockParser.new(arena)
      root_id = block_parser.parse
      document = Document.new(normalized, arena, root_id,
                              allow_html: allow_html,
                              references: block_parser.references)
      InlinePass.new(document).apply
      ExtendedAutolinkPass.new(document).apply if extended_autolinks
      document
    end

    def render_html(source, allow_html: false, extended_autolinks: false)
      parse(source, allow_html: allow_html, extended_autolinks: extended_autolinks).to_html
    end
  end
end
