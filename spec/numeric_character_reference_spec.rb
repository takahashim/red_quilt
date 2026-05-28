# frozen_string_literal: true

require "spec_helper"

# CommonMark spec 6.4 (Entity and numeric character references).
#
# Numeric references have a fixed digit width:
#   - Decimal: &#N; where N is 1-7 decimal digits.
#   - Hex: &#xH; where H is 1-6 hex digits.
# References outside those widths are NOT numeric character references and
# must be rendered as literal text.
#
# Numeric references that decode to U+0000, a surrogate (U+D800..U+DFFF),
# or a codepoint above U+10FFFF are replaced with U+FFFD.

RSpec.describe "numeric character references" do
  let(:repl) { 0xFFFD.chr(Encoding::UTF_8) }

  def render(src)
    RedQuilt.render_html(src)
  end

  describe "decimal NCR digit count" do
    it "decodes a 1-digit reference" do
      expect(render("&#65;")).to eq("<p>A</p>\n")
    end

    it "decodes a 7-digit reference (zero-padded)" do
      expect(render("&#0000065;")).to eq("<p>A</p>\n")
    end

    it "does NOT decode an 8-digit reference (treats as literal)" do
      expect(render("&#00000065;")).to eq("<p>&amp;#00000065;</p>\n")
    end

    it "decodes the maximum Unicode codepoint via decimal" do
      expect(render("&#1114111;")).to eq("<p>\u{10FFFF}</p>\n")
    end
  end

  describe "hex NCR digit count" do
    it "decodes a 1-digit hex reference" do
      expect(render("&#x41;")).to eq("<p>A</p>\n")
    end

    it "decodes a 6-digit hex reference (zero-padded)" do
      expect(render("&#x000041;")).to eq("<p>A</p>\n")
    end

    it "does NOT decode a 7-digit hex reference (treats as literal)" do
      expect(render("&#x0000041;")).to eq("<p>&amp;#x0000041;</p>\n")
    end

    it "decodes the maximum Unicode codepoint via hex" do
      expect(render("&#x10FFFF;")).to eq("<p>\u{10FFFF}</p>\n")
    end
  end

  describe "invalid codepoint replacement" do
    it "maps NUL (decimal 0) to U+FFFD" do
      expect(render("&#0;")).to eq("<p>#{repl}</p>\n")
    end

    it "maps a high surrogate (U+D800 decimal) to U+FFFD" do
      expect(render("&#55296;")).to eq("<p>#{repl}</p>\n")
    end

    it "maps a high surrogate (U+D800 hex) to U+FFFD without raising" do
      expect(render("&#xD800;")).to eq("<p>#{repl}</p>\n")
    end

    it "maps a low surrogate (U+DFFF hex) to U+FFFD" do
      expect(render("&#xDFFF;")).to eq("<p>#{repl}</p>\n")
    end

    it "maps a codepoint above U+10FFFF (decimal) to U+FFFD" do
      expect(render("&#1114112;")).to eq("<p>#{repl}</p>\n")
    end

    it "maps a codepoint above U+10FFFF (hex) to U+FFFD" do
      expect(render("&#x110000;")).to eq("<p>#{repl}</p>\n")
    end
  end

  describe "named entity references (unchanged)" do
    it "decodes a basic named entity" do
      expect(render("&amp;")).to eq("<p>&amp;</p>\n")
    end

    it "decodes a non-special named entity to its UTF-8 form" do
      expect(render("&copy;")).to eq("<p>©</p>\n")
    end
  end

  describe "context: link destinations also enforce caps" do
    it "rejects 8-digit decimal NCR inside a link destination" do
      out = render("[x](http://e?a=&#00000065;)")
      # The literal `&` is preserved (escaped) -- not decoded to 'A'.
      expect(out).to include("&amp;#00000065;")
    end

    it "decodes a valid NCR inside a link destination" do
      out = render("[x](http://e?a=&#65;)")
      expect(out).to include("a=A")
    end
  end
end
