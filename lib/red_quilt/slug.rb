# frozen_string_literal: true

module RedQuilt
  # Heading-anchor slugs, following GitHub's github-slugger approach:
  # downcase, strip punctuation, spaces to hyphens -- but keep Unicode
  # letters/marks/numbers verbatim, so Japanese (and other non-ASCII)
  # headings survive instead of collapsing to empty ids.
  module Slug
    # Drop anything that is not a letter, mark, number, underscore, space,
    # or hyphen. Browsers percent-encode non-ASCII fragment ids on the wire
    # but resolve and display them fine, matching GitHub.
    STRIP_RE = /[^\p{L}\p{M}\p{N}_ -]+/u
    SPACE_RE = / +/

    module_function

    def slugify(text)
      base = text.downcase.gsub(STRIP_RE, "").strip.gsub(SPACE_RE, "-")
      base.empty? ? "section" : base
    end

    # Deduplicates slugs within a single document: the first occurrence of a
    # base keeps it, later collisions get `-1`, `-2`, ... suffixes (matching
    # GitHub's anchor numbering).
    class Counter
      def initialize
        @seen = Hash.new(0)
      end

      def generate(text)
        base = Slug.slugify(text)
        count = @seen[base]
        @seen[base] += 1
        count.zero? ? base : "#{base}-#{count}"
      end
    end
  end
end
