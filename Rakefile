# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

task default: :spec

desc "Report CommonMark spec conformance, broken down by section"
task :conformance do
  require_relative "lib/red_quilt"
  require_relative "spec/support/commonmark_spec_loader"

  examples = CommonMarkSpecLoader.examples
  sections = examples.each_with_object({}) do |example, acc|
    stats = acc[example[:section]] ||= { pass: 0, total: 0 }
    stats[:total] += 1
    actual = RedQuilt.parse(example[:markdown], allow_html: true).to_html
    stats[:pass] += 1 if actual == example[:html]
  end

  total = { pass: sections.values.sum { |s| s[:pass] }, total: examples.size }
  width = sections.keys.map(&:length).max
  divider = "  #{'-' * width}  ----------  -------"

  puts "CommonMark #{CommonMarkSpecLoader::VERSION} conformance", ""
  puts format("  %-#{width}s  %-10s  %s", "Section", "Pass/Total", "Rate")
  puts divider
  sections.each do |name, stats|
    rate = stats[:pass].fdiv(stats[:total]) * 100
    puts format("  %-#{width}s  %4d / %4d  %5.1f%%", name, stats[:pass], stats[:total], rate)
  end
  puts divider
  rate = total[:pass].fdiv(total[:total]) * 100
  puts format("  %-#{width}s  %4d / %4d  %5.1f%%", "TOTAL", total[:pass], total[:total], rate)

  abort("\nConformance is below 100%.") unless total[:pass] == total[:total]
end
