# frozen_string_literal: true

require "spec_helper"
require_relative "support/commonmark_spec_loader"

# Every example below is parsed straight from the official CommonMark
# specification shipped at spec/fixtures/cmark_spec-0.31.2.md
# (https://spec.commonmark.org/0.31.2/). Nothing is hand-copied, so the suite
# is, by construction, the complete official conformance suite: if RedQuilt is
# green here, it passes the full CommonMark spec test suite for this version.
RSpec.describe "CommonMark #{CommonMarkSpecLoader::VERSION} conformance" do
  examples = CommonMarkSpecLoader.examples

  # Guard the "full suite" claim itself: prove the loader actually pulled in the
  # entire official example set before we trust the per-example results below.
  describe "coverage of the official spec" do
    it "loads exactly #{CommonMarkSpecLoader::EXPECTED_COUNT} examples" do
      expect(examples.size).to eq(CommonMarkSpecLoader::EXPECTED_COUNT)
    end

    it "covers example numbers 1..#{CommonMarkSpecLoader::EXPECTED_COUNT} with no gaps or duplicates" do
      numbers = examples.map { |example| example[:number] }
      expect(numbers).to eq((1..CommonMarkSpecLoader::EXPECTED_COUNT).to_a)
    end
  end

  examples.each do |example|
    it "matches example #{example[:number]} (#{example[:section]})" do
      doc = RedQuilt.parse(example[:markdown], allow_html: true)
      expect { doc.arena.check_integrity!(doc.root_id) }.not_to raise_error
      expect(doc.to_html).to eq(example[:html])
    end
  end
end
