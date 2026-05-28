# frozen_string_literal: true

require "red_quilt"

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Allocation-regression specs are pinned to a single Ruby version (the
  # object counts they assert differ across Ruby versions), so they're
  # excluded from the normal multi-version suite. CI runs them in a
  # dedicated job, and they can be run locally, via RUN_ALLOCATION_SPECS=1.
  config.filter_run_excluding(:allocations) unless ENV["RUN_ALLOCATION_SPECS"] == "1"
end
