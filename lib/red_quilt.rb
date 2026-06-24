# frozen_string_literal: true

require_relative "red_quilt/version"
require_relative "red_quilt/node_type"
require_relative "red_quilt/source_span"
require_relative "red_quilt/line"
require_relative "red_quilt/indentation"
require_relative "red_quilt/source_map"
require_relative "red_quilt/arena"
require_relative "red_quilt/node_ref"
require_relative "red_quilt/diagnostic"
require_relative "red_quilt/plain_text"
require_relative "red_quilt/slug"
require_relative "red_quilt/theme"
require_relative "red_quilt/document"
require_relative "red_quilt/inline"
require_relative "red_quilt/inline/html_entities"
require_relative "red_quilt/frontmatter"
require_relative "red_quilt/reference_definition"
require_relative "red_quilt/footnote_registry"
require_relative "red_quilt/footnote_anchors"
require_relative "red_quilt/footnote_definition"
require_relative "red_quilt/list"
require_relative "red_quilt/blockquote"
require_relative "red_quilt/html_block"
require_relative "red_quilt/table"
require_relative "red_quilt/code_block"
require_relative "red_quilt/block_parser"
require_relative "red_quilt/inline/token_kind"
require_relative "red_quilt/inline/tokens"
require_relative "red_quilt/inline/flanking"
require_relative "red_quilt/inline/lexer"
require_relative "red_quilt/inline/link_scanner"
require_relative "red_quilt/inline/url_sanitizer"
require_relative "red_quilt/inline/emphasis_resolver"
require_relative "red_quilt/inline/builder"
require_relative "red_quilt/inline_pass"
require_relative "red_quilt/footnote_pass"
require_relative "red_quilt/extended_autolink_pass"
require_relative "red_quilt/lint_pass"
require_relative "red_quilt/renderer/html"
require_relative "red_quilt/renderer/mdast"

module RedQuilt
  class Error < StandardError; end

  class << self
    def parse(source, allow_html: false, disallow_raw_html: false, extended_autolinks: false, footnotes: false, lint: false, frontmatter: false)
      normalized = normalize_input(source)
      frontmatter_diagnostics = []
      if frontmatter
        frontmatter_data, normalized =
          Frontmatter.extract(normalized, diagnostics: frontmatter_diagnostics)
      end
      arena = Arena.new(normalized)
      footnote_registry = FootnoteRegistry.new if footnotes
      block_parser = BlockParser.new(arena, footnotes: footnote_registry)
      root_id = block_parser.parse
      document = Document.new(normalized, arena, root_id,
                              allow_html: allow_html,
                              disallow_raw_html: disallow_raw_html,
                              references: block_parser.references,
                              footnotes: footnote_registry,
                              frontmatter: frontmatter_data)
      document.diagnostics.concat(frontmatter_diagnostics)
      document.diagnostics.concat(block_parser.diagnostics)
      InlinePass.new(document).apply
      FootnotePass.new(document).apply if footnote_registry
      ExtendedAutolinkPass.new(document).apply if extended_autolinks
      LintPass.new(document).apply if lint
      document
    end

    def render_html(source, allow_html: false, disallow_raw_html: false, extended_autolinks: false, footnotes: false, lint: false, frontmatter: false, heading_ids: false, mermaid: false)
      parse(source,
            allow_html: allow_html,
            disallow_raw_html: disallow_raw_html,
            extended_autolinks: extended_autolinks,
            footnotes: footnotes,
            lint: lint,
            frontmatter: frontmatter).to_html(heading_ids: heading_ids, mermaid: mermaid)
    end

    private

    NUL_CHAR = 0.chr
    REPLACEMENT_CHAR = 0xFFFD.chr(Encoding::UTF_8)
    private_constant :NUL_CHAR, :REPLACEMENT_CHAR

    # CommonMark normalization applied before parsing:
    # - line endings: \r\n and lone \r -> \n (spec defines all three as line endings)
    # - NUL (U+0000) -> U+FFFD (spec requires this replacement for security)
    def normalize_input(source)
      # Both substitutions rewrite the whole document, so skip each scan
      # (and its full-string copy) when the trigger byte is absent -- the
      # common case is LF-only text with no NUL.
      source = source.gsub(/\r\n?/, "\n") if source.include?("\r")
      source = source.gsub(NUL_CHAR, REPLACEMENT_CHAR) if source.include?(NUL_CHAR)
      source
    end
  end
end
