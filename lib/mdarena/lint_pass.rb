# frozen_string_literal: true

module Mdarena
  # Optional second-pass linter. Runs AFTER InlinePass when callers pass
  # `lint: true` to Mdarena.parse / .render_html. Walks the assembled
  # tree once and appends warnings / info diagnostics to
  # Document#diagnostics for lint-style issues that the parser cannot
  # reasonably detect inline (heading-level skips, empty link
  # destinations, images without alt text, ...).
  #
  # Each rule is keyed by a Symbol on Diagnostic#rule so callers can
  # filter or silence individually.
  class LintPass
    def initialize(document)
      @document = document
      @arena = document.arena
      @diagnostics = document.diagnostics
    end

    def apply
      last_heading_level = 0
      walk(@document.root_id) do |id|
        case @arena.type(id)
        when NodeType::HEADING
          level = @arena.int1(id)
          if last_heading_level.positive? && level > last_heading_level + 1
            push(:info, :heading_level_skip,
                 "Heading jumps from h#{last_heading_level} to h#{level}",
                 @arena.source_span(id))
          end
          last_heading_level = level
        when NodeType::LINK
          check_empty_link(id)
        when NodeType::IMAGE
          check_missing_alt(id)
        end
      end
    end

    private

    def walk(node_id, &block)
      yield node_id
      @arena.each_child(node_id) { |child_id| walk(child_id, &block) }
    end

    def check_empty_link(node_id)
      return unless @arena.str1(node_id).to_s.empty?

      push(:warning, :empty_link,
           "Link has no destination",
           @arena.source_span(node_id))
    end

    def check_missing_alt(node_id)
      # IMAGE's str1 holds the destination URL, so NodeRef#text would
      # report the URL as "alt text" for a childless image. PlainText
      # walks descendants only, so a childless image yields "".
      return unless PlainText.from(@arena, node_id).strip.empty?

      push(:info, :missing_alt,
           "Image has no alt text",
           @arena.source_span(node_id))
    end

    def push(severity, rule, message, source_span)
      @diagnostics << Diagnostic.new(severity: severity, rule: rule,
                                     message: message, source_span: source_span)
    end
  end
end
