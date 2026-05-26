# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/mdarena"

# Baseline fixtures for inline parser performance
FIXTURES = {
  short_paragraph: "Hello *world* with **emphasis** and [link](/url).",

  long_paragraph: "Lorem " + ("*ipsum* dolor " * 100) + "sit amet.",

  nested_emphasis: "*foo **bar *baz* bim** bop*" * 50,

  many_links: "[link](/url \"title\")" * 100,

  mixed_markup: "# Heading\n\nParagraph with *em*, **strong**, `code`, [link](/url), and ![image](/img.png).\n\n" * 20,

  deep_nesting: "*_**___em___**_*" * 50
}

Benchmark.ips do |x|
  FIXTURES.each do |name, markdown|
    x.report(name.to_s) { Mdarena.parse(markdown) }
  end

  x.compare!
end
