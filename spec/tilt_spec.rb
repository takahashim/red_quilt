# frozen_string_literal: true

require "spec_helper"
require "red_quilt/tilt"

RSpec.describe RedQuilt::TiltTemplate do
  it "registers for common markdown extensions" do
    %w[md markdown mkd mkdn mdown].each do |ext|
      expect(Tilt["example.#{ext}"]).to eq(described_class)
    end
  end

  it "advertises text/html as its default MIME type" do
    expect(described_class.default_mime_type).to eq("text/html")
  end

  it "renders markdown to HTML" do
    template = described_class.new { "# Title\n\n**bold**" }
    expect(template.render).to eq("<h1>Title</h1>\n<p><strong>bold</strong></p>\n")
  end

  it "escapes raw HTML by default (safe-by-default)" do
    template = described_class.new { "Hi <em>x</em>" }
    expect(template.render).to eq("<p>Hi &lt;em&gt;x&lt;/em&gt;</p>\n")
  end

  it "passes raw HTML through with escape_html: false" do
    template = described_class.new(escape_html: false) { "Hi <em>x</em>" }
    expect(template.render).to eq("<p>Hi <em>x</em></p>\n")
  end

  it "forwards RedQuilt native options" do
    src = "Ref.[^1]\n\n[^1]: note\n"
    expect(described_class.new(footnotes: true) { src }.render).to include('class="footnotes"')
    expect(described_class.new { src }.render).not_to include('class="footnotes"')
  end

  it "memoizes output across repeated renders" do
    template = described_class.new { "# Title" }
    expect(template.render).to eq(template.render)
  end
end
