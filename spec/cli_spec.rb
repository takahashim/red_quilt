# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "stringio"
require "tempfile"
require "red_quilt/cli"

RSpec.describe RedQuilt::CLI do
  def run(argv, input: "")
    stdin = StringIO.new(input)
    stdout = StringIO.new
    stderr = StringIO.new
    code = described_class.run(argv.dup, stdin: stdin, stdout: stdout, stderr: stderr)
    [code, stdout.string, stderr.string]
  end

  describe "default invocation (HTML output via stdin)" do
    it "renders a full standalone HTML document with the default theme" do
      code, out, err = run([], input: "# Hello\n")
      expect(code).to eq(0)
      expect(out).to start_with("<!DOCTYPE html>\n")
      expect(out).to include("<title></title>")
      expect(out).to include("<style>")
      expect(out).to include("<h1>Hello</h1>")
      expect(out).to end_with("</html>\n")
      expect(err).to eq("")
    end

    it "emits only the body fragment with --no-standalone" do
      code, out, _ = run(["--no-standalone"], input: "# Hello\n")
      expect(code).to eq(0)
      expect(out).to eq("<h1>Hello</h1>\n")
    end
  end

  describe "standalone options" do
    it "uses --title for the document title" do
      code, out, _ = run(["--title", "My Doc"], input: "hi\n")
      expect(code).to eq(0)
      expect(out).to include("<title>My Doc</title>")
    end

    it "derives the title from the first heading with --auto-title" do
      code, out, _ = run(["--auto-title"], input: "# Hello world\n\ntext\n")
      expect(code).to eq(0)
      expect(out).to include("<title>Hello world</title>")
    end

    it "sets the html lang attribute via --lang" do
      code, out, _ = run(["--lang", "ja"], input: "hi\n")
      expect(code).to eq(0)
      expect(out).to include(%(<html lang="ja">))
    end

    it "links a stylesheet via --css" do
      code, out, _ = run(["--css", "/s.css"], input: "hi\n")
      expect(code).to eq(0)
      expect(out).to include(%(<link rel="stylesheet" href="/s.css">))
    end

    it "embeds the bundled stylesheet by default and via --theme default" do
      expect(run([], input: "hi\n")[1]).to include("<style>")
      expect(run(["--theme", "default"], input: "hi\n")[1]).to include("<style>")
    end

    it "emits bare HTML (no embedded stylesheet) with --theme none" do
      code, out, _ = run(["--theme", "none"], input: "hi\n")
      expect(code).to eq(0)
      expect(out).not_to include("<style>")
    end

    it "rejects an unknown theme" do
      code, _, err = run(["--theme", "bogus"], input: "hi\n")
      expect(code).not_to eq(0)
      expect(err).not_to be_empty
    end
  end

  describe "file input" do
    it "reads the source from FILE when one is given" do
      Tempfile.open(["cli", ".md"]) do |f|
        f.write("**bold**\n")
        f.flush
        code, out, _ = run(["--no-standalone", f.path])
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

    it "prints JSON AST when --format json is given" do
      code, out, _ = run(["--format", "json"], input: "# H\n")
      expect(code).to eq(0)
      require "json"
      ast = JSON.parse(out)
      expect(ast).to be_a(Hash)
      expect(ast["type"]).to eq("root")
      expect(ast["children"].first["type"]).to eq("heading")
      expect(ast["children"].first["depth"]).to eq(1)
      expect(ast["children"].first["position"]).to include("start", "end")
      expect(ast["children"].first["position"]["start"]).to include("line", "column", "offset")
    end

    it "rejects unknown format values" do
      code, _, err = run(["--format", "xml"], input: "")
      expect(code).to eq(1)
      expect(err).to match(/invalid argument/i)
    end
  end

  describe "--allow-html" do
    it "passes raw HTML through when --allow-html is set" do
      code, out, _ = run(["--no-standalone", "--allow-html"], input: "<span>x</span>\n")
      expect(code).to eq(0)
      expect(out).to include("<span>x</span>")
    end

    it "escapes raw HTML by default" do
      code, out, _ = run(["--no-standalone"], input: "<span>x</span>\n")
      expect(code).to eq(0)
      expect(out).to include("&lt;span&gt;")
    end
  end

  describe "--lint" do
    it "emits lint diagnostics when --lint is given" do
      code, _, err = run(["--lint", "--diagnostics-only"], input: "# a\n\n### c\n")
      expect(code).to eq(0)
      expect(err).to include("heading_level_skip")
    end

    it "does not emit lint diagnostics without --lint" do
      code, _, err = run(["--diagnostics"], input: "# a\n\n### c\n")
      expect(code).to eq(0)
      expect(err).not_to include("heading_level_skip")
    end
  end

  describe "--disallow-raw-html" do
    it "filters dangerous tags when combined with --allow-html" do
      code, out, _ = run(["--no-standalone", "--allow-html", "--disallow-raw-html"],
                         input: "<script>x</script>\n")
      expect(code).to eq(0)
      expect(out).to include("&lt;script>x&lt;/script>")
    end

    it "leaves safe tags alone when --disallow-raw-html is set" do
      code, out, _ = run(["--no-standalone", "--allow-html", "--disallow-raw-html"],
                         input: "Hi <em>tag</em>\n")
      expect(code).to eq(0)
      expect(out).to include("<em>tag</em>")
    end
  end

  describe "--mermaid" do
    it "renders mermaid blocks as <pre class=\"mermaid\"> and loads the runtime" do
      code, out, _ = run(["--mermaid"], input: "```mermaid\ngraph LR\n  A --> B\n```\n")
      expect(code).to eq(0)
      expect(out).to include('<pre class="mermaid">')
      expect(out).to include("cdn.jsdelivr.net/npm/mermaid")
    end

    it "leaves mermaid blocks as plain code blocks without the flag" do
      code, out, _ = run([], input: "```mermaid\ngraph LR\n```\n")
      expect(code).to eq(0)
      expect(out).to include('<pre><code class="language-mermaid">')
      expect(out).not_to include("cdn.jsdelivr.net")
    end
  end

  describe "--diagnostics" do
    it "writes diagnostics to stderr while still rendering HTML" do
      code, out, err = run(["--no-standalone", "--diagnostics"], input: "[a](javascript:1)\n")
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

  describe "--output / -o" do
    it "writes HTML to FILE instead of stdout" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "out.html")
        code, out, _ = run(["--no-standalone", "-o", path], input: "# Hello\n")
        expect(code).to eq(0)
        expect(out).to eq("")
        expect(File.read(path)).to eq("<h1>Hello</h1>\n")
      end
    end
  end

  describe "--open" do
    it "writes HTML to a tmpdir file and launches the browser" do
      launcher = instance_double(RedQuilt::BrowserLauncher, launch: nil)
      allow(RedQuilt::BrowserLauncher).to receive(:new).and_return(launcher)

      code, out, err = run(["--open"], input: "# Hi\n")
      expect(code).to eq(0)
      expect(out).to eq("")
      expect(err).to eq("")
      expected = File.join(Dir.tmpdir, "redquilt-stdin.html")
      expect(launcher).to have_received(:launch).with(expected)
      expect(File.read(expected)).to start_with("<!DOCTYPE html>\n")
      expect(File.read(expected)).to include("<h1>Hi</h1>")
    ensure
      FileUtils.rm_f(expected) if expected
    end

    it "forces standalone even with --no-standalone" do
      launcher = instance_double(RedQuilt::BrowserLauncher, launch: nil)
      allow(RedQuilt::BrowserLauncher).to receive(:new).and_return(launcher)

      code, _, _ = run(["--open", "--no-standalone"], input: "# Hi\n")
      expect(code).to eq(0)
      path = File.join(Dir.tmpdir, "redquilt-stdin.html")
      expect(File.read(path)).to start_with("<!DOCTYPE html>\n")
    ensure
      FileUtils.rm_f(path) if path
    end

    it "derives the tmpdir filename from the input file basename" do
      launcher = instance_double(RedQuilt::BrowserLauncher, launch: nil)
      allow(RedQuilt::BrowserLauncher).to receive(:new).and_return(launcher)

      Tempfile.open(["sample", ".md"]) do |f|
        f.write("# X\n")
        f.flush
        run(["--open", f.path])
        expected = File.join(Dir.tmpdir, "redquilt-#{File.basename(f.path, '.*')}.html")
        expect(launcher).to have_received(:launch).with(expected)
        FileUtils.rm_f(expected)
      end
    end

    it "combines with -o to open the user-specified file" do
      launcher = instance_double(RedQuilt::BrowserLauncher, launch: nil)
      allow(RedQuilt::BrowserLauncher).to receive(:new).and_return(launcher)

      Dir.mktmpdir do |dir|
        path = File.join(dir, "out.html")
        code, _, _ = run(["--open", "-o", path], input: "# Hi\n")
        expect(code).to eq(0)
        expect(launcher).to have_received(:launch).with(path)
        expect(File.read(path)).to start_with("<!DOCTYPE html>\n")
      end
    end

    it "rejects --open combined with non-HTML formats" do
      code, _, err = run(["--open", "--format", "json"], input: "# Hi\n")
      expect(code).to eq(1)
      expect(err).to include("--open requires --format html")
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
      expect(err).to include(RedQuilt::VERSION)
    end
  end
end
