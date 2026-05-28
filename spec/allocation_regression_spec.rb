# frozen_string_literal: true

# Guards against allocation regressions. Unlike wall-clock benchmarks,
# the object count a fixed input allocates is deterministic (no run-to-run
# noise), so it makes a reliable CI gate.
#
# IMPORTANT: the absolute counts differ markedly between Ruby versions
# (e.g. the cmark spec render allocates ~104k objects on 3.3/3.4 but
# ~85k on 4.0), so this gate is PINNED to one Ruby version. It is tagged
# `:allocations` and excluded from the default suite (spec_helper); CI
# runs it only on the pinned version via RUN_ALLOCATION_SPECS=1. Run it
# locally the same way:
#
#   RUN_ALLOCATION_SPECS=1 bundle exec rspec spec/allocation_regression_spec.rb
#
# The ceilings below are baselined on Ruby 4.0. If an intentional change
# moves the numbers, re-measure and update them (keep ~6% headroom):
#
#   ruby -Ilib -rred_quilt -e 'd=File.read("spec/fixtures/cmark_spec-0.31.2.md"); \
#     RedQuilt.render_html(d); b=GC.stat(:total_allocated_objects); \
#     RedQuilt.render_html(d); puts GC.stat(:total_allocated_objects)-b'
RSpec.describe "allocation regression", :allocations do
  def allocations_for(source)
    # Warm once so constant init / regex compilation / autoloads don't
    # count toward the measured render. total_allocated_objects is a
    # monotonic process counter, so an intervening GC can't skew the delta.
    RedQuilt.render_html(source)
    before = GC.stat(:total_allocated_objects)
    RedQuilt.render_html(source)
    GC.stat(:total_allocated_objects) - before
  end

  it "stays within budget rendering the full CommonMark spec document" do
    doc = File.read(File.expand_path("fixtures/cmark_spec-0.31.2.md", __dir__))

    # Measured baseline (Ruby 4.0): ~84.7k objects. Ceiling has ~6% headroom.
    expect(allocations_for(doc)).to be <= 90_000
  end

  it "stays within budget rendering a short inline paragraph" do
    # Measured baseline: ~99 objects.
    expect(allocations_for("Hello *world* with **emphasis** and [link](/url).\n")).to be <= 150
  end
end
