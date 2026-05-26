# frozen_string_literal: true

require "stringio"
require "tempfile"
require "mdarena/cli"

RSpec.describe Mdarena::CLI do
  def run(argv, input: "")
    stdin = StringIO.new(input)
    stdout = StringIO.new
    stderr = StringIO.new
    code = described_class.run(argv.dup, stdin: stdin, stdout: stdout, stderr: stderr)
    [code, stdout.string, stderr.string]
  end

  describe "default invocation (HTML output via stdin)" do
    it "renders Markdown from stdin to HTML on stdout" do
      code, out, err = run([], input: "# Hello\n")
      expect(code).to eq(0)
      expect(out).to eq("<h1>Hello</h1>\n")
      expect(err).to eq("")
    end
  end

  describe "file input" do
    it "reads the source from FILE when one is given" do
      Tempfile.open(["cli", ".md"]) do |f|
        f.write("**bold**\n")
        f.flush
        code, out, _ = run([f.path])
        expect(code).to eq(0)
        expect(out).to eq("<p><strong>bold</strong></p>\n")
      end
    end

    it "exits with 1 when FILE doesn't exist" do
      code, _, err = run(["/no/such/path"])
      expect(code).to eq(1)
      expect(err).to include("no such file")
    end

    it "exits with 1 when too many arguments are supplied" do
      code, _, err = run(["a.md", "b.md"])
      expect(code).to eq(1)
      expect(err).to include("too many arguments")
    end
  end

  describe "--format" do
    it "prints AST when --format ast is given" do
      code, out, _ = run(["--format", "ast"], input: "# H\n")
      expect(code).to eq(0)
      expect(out).to include(":document")
      expect(out).to include(":heading")
    end

    it "rejects unknown format values" do
      code, _, err = run(["--format", "json"], input: "")
      expect(code).to eq(1)
      expect(err).to match(/invalid argument/i)
    end
  end

  describe "--allow-html" do
    it "passes raw HTML through when --allow-html is set" do
      code, out, _ = run(["--allow-html"], input: "<span>x</span>\n")
      expect(code).to eq(0)
      expect(out).to include("<span>x</span>")
    end

    it "escapes raw HTML by default" do
      code, out, _ = run([], input: "<span>x</span>\n")
      expect(code).to eq(0)
      expect(out).to include("&lt;span&gt;")
    end
  end

  describe "--diagnostics" do
    it "writes diagnostics to stderr while still rendering HTML" do
      code, out, err = run(["--diagnostics"], input: "[a](javascript:1)\n")
      expect(code).to eq(0)
      expect(out).to include("<a href=\"\">a</a>")
      expect(err).to include("unsafe_url")
    end

    it "reports 'no diagnostics' when none were collected" do
      code, _, err = run(["--diagnostics"], input: "plain text\n")
      expect(code).to eq(0)
      expect(err).to include("no diagnostics")
    end
  end

  describe "--diagnostics-only" do
    it "suppresses the rendered output and prints diagnostics only" do
      code, out, err = run(["--diagnostics-only"], input: "[x](javascript:1)\n")
      expect(code).to eq(0)
      expect(out).to eq("")
      expect(err).to include("unsafe_url")
    end
  end

  describe "--help / --version" do
    it "prints help and exits 0 when --help is given" do
      code, _, err = run(["--help"])
      expect(code).to eq(0)
      expect(err).to include("Usage:")
    end

    it "prints the version with --version" do
      code, _, err = run(["--version"])
      expect(code).to eq(0)
      expect(err).to include(Mdarena::VERSION)
    end
  end
end
