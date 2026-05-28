# frozen_string_literal: true

require "optparse"

module RedQuilt
  # Entry point for the `redquilt` executable. Defined as a module-level
  # function so tests can drive it without shelling out.
  #
  # CLI.run takes an argv-style array and an optional set of IO objects
  # (stdin / stdout / stderr) for testability. It returns an Integer
  # exit code: 0 on success, 1 on usage errors.
  module CLI
    USAGE = <<~USAGE
      Usage: redquilt [options] [file]

      Reads Markdown from FILE (or stdin if FILE is omitted) and writes the
      result to stdout.

      Options:
    USAGE

    DEFAULTS = {
      format: :html,
      allow_html: false,
      disallow_raw_html: false,
      extended_autolinks: false,
      lint: false,
      diagnostics: false,
      diagnostics_only: false,
      standalone: true,
      auto_title: false,
      title: nil,
      lang: "en",
      css: nil,
      theme: :default,
    }.freeze

    THEMES = %i[none default].freeze

    FORMATS = %i[html ast json].freeze

    def self.run(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr)
      options = parse_options(argv, stderr: stderr)
      return options if options.is_a?(Integer)

      source = read_source(argv, stdin: stdin, stderr: stderr)
      return 1 unless source

      doc = RedQuilt.parse(source,
                           allow_html: options[:allow_html],
                           disallow_raw_html: options[:disallow_raw_html],
                           extended_autolinks: options[:extended_autolinks],
                           lint: options[:lint])

      unless options[:diagnostics_only]
        case options[:format]
        when :html
          stdout.write(render_html(doc, options))
        when :ast
          require "pp"
          PP.pp(doc.to_ast, stdout)
        when :json
          stdout.puts doc.to_json
        end
      end

      if options[:diagnostics] || options[:diagnostics_only]
        write_diagnostics(doc.diagnostics, stderr)
      end

      doc.diagnostics.any? { |d| d.severity == :error } ? 1 : 0
    end

    def self.parse_options(argv, stderr:)
      options = DEFAULTS.dup
      parser = OptionParser.new do |opts|
        opts.banner = USAGE
        opts.on("--format FORMAT", FORMATS, "Output format: html (default), ast, json") do |f|
          options[:format] = f
        end
        opts.on("--allow-html", "Pass raw HTML through to the output") do
          options[:allow_html] = true
        end
        opts.on("--disallow-raw-html",
                "Filter dangerous tags (script, iframe, ...) even with --allow-html (GFM)") do
          options[:disallow_raw_html] = true
        end
        opts.on("--extended-autolinks",
                "Linkify bare URLs and email addresses (GFM)") do
          options[:extended_autolinks] = true
        end
        opts.on("--lint",
                "Emit lint-style diagnostics (empty_link, missing_alt, heading_level_skip)") do
          options[:lint] = true
        end
        opts.on("--[no-]standalone",
                "Wrap (or not) the rendered HTML in a full document (default: on)") do |v|
          options[:standalone] = v
        end
        opts.on("--auto-title",
                "Use the first heading's text as <title> (standalone only)") do
          options[:auto_title] = true
        end
        opts.on("--title TITLE", "Explicit <title> text (standalone only)") do |t|
          options[:title] = t
        end
        opts.on("--lang LANG", "html lang attribute (standalone only; default \"en\")") do |l|
          options[:lang] = l
        end
        opts.on("--css URL", "Add a stylesheet link (standalone only)") do |u|
          options[:css] = u
        end
        opts.on("--theme THEME", THEMES,
                "Embedded stylesheet: default (the default) or none (bare HTML)") do |t|
          options[:theme] = t
        end
        opts.on("--diagnostics", "Also print diagnostics to stderr") do
          options[:diagnostics] = true
        end
        opts.on("--diagnostics-only", "Print diagnostics only (suppress normal output)") do
          options[:diagnostics_only] = true
        end
        opts.on("-h", "--help", "Show this help") do
          stderr.puts opts
          return 0
        end
        opts.on("-v", "--version", "Show version") do
          stderr.puts "redquilt #{RedQuilt::VERSION}"
          return 0
        end
      end

      begin
        parser.parse!(argv)
      rescue OptionParser::ParseError => e
        stderr.puts "redquilt: #{e.message}"
        stderr.puts parser
        return 1
      end

      options
    end

    def self.read_source(argv, stdin:, stderr:)
      if argv.empty?
        stdin.read
      elsif argv.size == 1
        path = argv.first
        unless File.file?(path)
          stderr.puts "redquilt: no such file: #{path}"
          return nil
        end
        File.read(path)
      else
        stderr.puts "redquilt: too many arguments: #{argv.inspect}"
        nil
      end
    end

    def self.render_html(doc, options)
      title = options[:title]
      title = doc.first_heading_text.to_s if title.nil? && options[:auto_title]
      doc.to_html(
        standalone: options[:standalone],
        title: title,
        lang: options[:lang],
        css: options[:css],
        theme: options[:theme],
      )
    end

    def self.write_diagnostics(diagnostics, stderr)
      if diagnostics.empty?
        stderr.puts "redquilt: no diagnostics"
        return
      end
      diagnostics.each do |d|
        stderr.puts "[#{d.severity}] #{d.rule}: #{d.message}"
      end
    end
  end
end
