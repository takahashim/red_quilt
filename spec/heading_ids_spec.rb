# frozen_string_literal: true

require "spec_helper"

RSpec.describe "heading ids" do
  describe RedQuilt::Slug do
    it "slugifies ASCII like GitHub (downcase, strip punctuation, hyphenate)" do
      expect(described_class.slugify("Hello, World!")).to eq("hello-world")
      expect(described_class.slugify("API の概要")).to eq("api-の概要")
    end

    it "keeps Japanese characters verbatim" do
      expect(described_class.slugify("はじめに")).to eq("はじめに")
    end

    it "falls back to 'section' when nothing survives" do
      expect(described_class.slugify("!!!")).to eq("section")
    end

    it "deduplicates collisions with numeric suffixes" do
      counter = described_class::Counter.new
      expect(counter.generate("Intro")).to eq("intro")
      expect(counter.generate("Intro")).to eq("intro-1")
      expect(counter.generate("Intro")).to eq("intro-2")
    end
  end

  describe "RedQuilt.render_html heading_ids:" do
    it "omits ids by default" do
      expect(RedQuilt.render_html("# Title")).to eq("<h1>Title</h1>\n")
    end

    it "adds slugified ids when enabled" do
      html = RedQuilt.render_html("# Hello World\n\n## はじめに", heading_ids: true)
      expect(html).to include(%(<h1 id="hello-world">))
      expect(html).to include(%(<h2 id="はじめに">))
    end

    it "deduplicates repeated headings across the document" do
      html = RedQuilt.render_html("# Intro\n\n# Intro", heading_ids: true)
      expect(html).to include(%(<h1 id="intro">)).and include(%(<h1 id="intro-1">))
    end
  end
end
