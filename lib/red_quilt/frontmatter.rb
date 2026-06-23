# frozen_string_literal: true

require "psych"
require "date"

module RedQuilt
  # Extracts a leading YAML frontmatter block from a Markdown source.
  module Frontmatter
    # Matches a frontmatter block at the very start of the document.
    PATTERN = /\A---\n(.*?)\n(?:---|\.\.\.)[ \t]*(?:\n|\z)/m
    private_constant :PATTERN

    module_function

    # Extracts frontmatter from +source+, returning a two-element array:
    # [data, body]. +data+ is the parsed Hash (or nil when there is no
    # frontmatter), and +body+ is the source with the frontmatter region
    # blanked out.
    #
    # +diagnostics+ is an optional array; on a YAML syntax error a warning
    # Diagnostic is appended and +data+ is returned as nil.
    def extract(source, diagnostics: nil)
      match = PATTERN.match(source)
      return [nil, source] unless match

      data = parse_yaml(match[1], diagnostics: diagnostics)
      body = blank_out(source, match.end(0))
      [data, body]
    end

    # Parses the YAML body with a restricted loader (no arbitrary object
    # instantiation; Date / Time permitted for common frontmatter dates).
    # Returns the parsed value, or nil on a syntax error.
    def parse_yaml(yaml, diagnostics: nil)
      Psych.safe_load(yaml, permitted_classes: [Date, Time], aliases: false)
    rescue Psych::SyntaxError => e
      diagnostics&.push(
        Diagnostic.new(
          severity: :warning,
          rule: :frontmatter,
          message: "invalid YAML frontmatter: #{e.message}",
        ),
      )
      nil
    end

    # Replaces every character before +offset+ with a blank line for each
    # consumed source line, keeping later line numbers intact.
    def blank_out(source, offset)
      consumed = source[0, offset]
      ("\n" * consumed.count("\n")) + source[offset..]
    end
  end
end
