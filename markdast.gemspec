# frozen_string_literal: true

require_relative "lib/markdast/version"

Gem::Specification.new do |spec|
  spec.name = "markdast"
  spec.version = Markdast::VERSION
  spec.authors = ["takahashim"]
  spec.email = ["takahashimm@gmail.com"]

  spec.summary = "Arena AST based Markdown processor for Ruby"
  spec.description = "markdast parses Markdown into a low-allocation arena AST and renders safe HTML."
  spec.homepage = "https://github.com/takahashim/markdast"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |file|
      (file == gemspec) || file.start_with?(*%w[bin/ test/ spec/ features/ .git appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |file| File.basename(file) }
  spec.require_paths = ["lib"]
end
