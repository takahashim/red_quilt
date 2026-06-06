# frozen_string_literal: true

# Parses the official CommonMark specification document into its example set.
#
# The fixture (spec/fixtures/cmark_spec-<version>.md) is the verbatim spec
# distributed at https://spec.commonmark.org/. Examples are delimited exactly
# as the reference test runner (test/spec_tests.py) expects them:
#
#   ```...``` example   <- 32 backticks + " example" starts the markdown
#   <markdown>
#   .                   <- a lone "." separates markdown from expected HTML
#   <html>
#   ```...```           <- 32 backticks close the example
#
# A literal tab is written as U+2192 (→) in the document and substituted back
# here, matching the reference runner. Section names come from the most recent
# ATX heading. Because every example is derived from this file rather than
# hand-copied, the resulting suite is, by construction, the complete official
# conformance suite for the pinned version.
module CommonMarkSpecLoader
  VERSION = "0.31.2"
  EXPECTED_COUNT = 652
  FIXTURE = File.expand_path("../fixtures/cmark_spec-#{VERSION}.md", __dir__)

  FENCE = ("`" * 32).freeze
  EXAMPLE_OPEN = "#{FENCE} example"
  TAB_GLYPH = "→"

  module_function

  def examples(path = FIXTURE)
    result = []
    section = ""
    state = :text
    markdown = []
    html = []
    number = 0

    File.foreach(path, encoding: "UTF-8") do |line|
      stripped = line.strip

      if stripped == EXAMPLE_OPEN
        state = :markdown
      elsif state == :html && stripped == FENCE
        number += 1
        result << {
          number: number,
          section: section,
          markdown: markdown.join.gsub(TAB_GLYPH, "\t"),
          html: html.join.gsub(TAB_GLYPH, "\t"),
        }
        markdown = []
        html = []
        state = :text
      elsif stripped == "."
        state = :html
      elsif state == :markdown
        markdown << line
      elsif state == :html
        html << line
      elsif state == :text && line =~ /\A#+ /
        section = line.sub(/\A#+ /, "").strip
      end
    end

    result
  end
end
