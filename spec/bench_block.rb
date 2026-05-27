# frozen_string_literal: true

# Block-parser focused benchmark.
#
# Companion to spec/bench_inline.rb. These fixtures stress the block
# dispatch path (lists, blockquotes, reference definitions, HTML blocks,
# thematic breaks) so changes localised to BlockParser show up clearly,
# without being drowned out by inline pipeline work.
#
# Usage:
#   ruby spec/bench_block.rb
#
# benchmark-ips reports ±% on each line; for low-noise comparison runs,
# take the median of 3 invocations.

require "benchmark/ips"
require_relative "../lib/red_quilt"

FIXTURES = {
  nested_blockquote:  "> level 1\n> > level 2\n> > > level 3\n" * 50,
  long_list:          (1..200).map { |i| "- item #{i}" }.join("\n"),
  nested_list:        (1..50).map { |i| "- top #{i}\n  - sub #{i}\n    - sub sub #{i}" }.join("\n"),
  ref_defs:           (1..100).map { |i| "[ref#{i}]: /url/#{i} \"title #{i}\"" }.join("\n"),
  html_blocks:        "<div>\nhello\n</div>\n\n" * 50,
  thematic_breaks:    "---\n\nparagraph\n\n" * 100,
  mixed_block:        "# heading\n\nparagraph\n\n> quote\n> more quote\n\n- list item 1\n- list item 2\n  - nested\n\n```\ncode\n```\n\n" * 20
}.freeze

Benchmark.ips do |x|
  x.warmup = 5
  x.time = 5
  FIXTURES.each do |name, markdown|
    x.report(name.to_s) { RedQuilt.parse(markdown) }
  end
end
