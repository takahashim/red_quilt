# frozen_string_literal: true

# Speed comparison: mdarena vs kramdown.
#
# Run: bundle exec ruby spec/bench_vs_kramdown.rb

require "benchmark/ips"
require "kramdown"
require_relative "../lib/mdarena"

FIXTURES = {
  short_paragraph: "Hello *world* with **emphasis** and [link](/url).",

  long_paragraph: "Lorem " + ("*ipsum* dolor " * 100) + "sit amet.",

  cmark_spec: File.read(File.expand_path("fixtures/cmark_spec-0.31.2.md", __dir__)),

  nested_emphasis: "*foo **bar *baz* bim** bop*" * 50,

  many_links: "[link](/url \"title\")" * 100,

  mixed_markup: "# Heading\n\nParagraph with *em*, **strong**, `code`, " \
                "[link](/url), and ![image](/img.png).\n\n" * 20,

  deep_nesting: "*_**___em___**_*" * 50
}

# Sanity: each engine must produce some HTML for each fixture.
FIXTURES.each do |name, source|
  raise "mdarena empty on #{name}" if Mdarena.render_html(source).empty?
  raise "kramdown empty on #{name}" if Kramdown::Document.new(source).to_html.empty?
end

FIXTURES.each do |name, source|
  puts
  puts "== #{name} (#{source.bytesize} bytes) =="
  Benchmark.ips do |x|
    x.report("mdarena")  { Mdarena.render_html(source) }
    x.report("kramdown") { Kramdown::Document.new(source).to_html }
    x.compare!
  end
end
