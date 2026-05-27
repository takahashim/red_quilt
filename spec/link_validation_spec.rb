# frozen_string_literal: true

# CommonMark spec compliance for two link-related constraints:
#   - Link label length cap: "A link label can have at most 999 characters
#     inside the square brackets." (spec 6.3)
#   - Reference definition raw destination: "a nonempty sequence of
#     characters that does not start with <, does not include ASCII
#     control characters or space character, and includes parentheses
#     only if (a) they are backslash-escaped or (b) they are part of a
#     balanced pair of unescaped parentheses." (spec 6.3)

RSpec.describe "link validation" do
  def render(src)
    RedQuilt.render_html(src)
  end

  describe "link label length limit (999 characters)" do
    it "accepts a 999-character reference definition label" do
      label = "a" * 999
      out = render("[#{label}]: http://a\n\n[#{label}]\n")
      expect(out).to include(%(<a href="http://a">))
    end

    it "rejects a 1000-character reference definition label" do
      label = "a" * 1000
      out = render("[#{label}]: http://a\n\n[#{label}]\n")
      expect(out).not_to include("<a href=")
    end

    it "accepts a 999-character shortcut reference link use" do
      label = "a" * 999
      out = render("[#{label}]: http://a\n\n[#{label}]\n")
      expect(out).to include(%(<a href="http://a">))
    end

    it "rejects a 1000-character shortcut reference link use even when defined" do
      # Build def with shorter alias for the same destination so the
      # 1000-char USE side is the only thing under test.
      defn = "[" + ("a" * 999) + "]: http://a"
      use = "[" + ("a" * 1000) + "]"
      out = render("#{defn}\n\n#{use}\n")
      expect(out).not_to include("<a href=")
    end

    it "rejects a 1000-character full reference link label" do
      defn = "[ref]: http://a"
      use = "[text][" + ("a" * 1000) + "]"
      out = render("#{defn}\n\n#{use}\n")
      expect(out).not_to include("<a href=")
    end

    it "accepts a 999-character full reference link label" do
      label_999 = "a" * 999
      defn = "[#{label_999}]: http://a"
      use = "[text][#{label_999}]"
      out = render("#{defn}\n\n#{use}\n")
      expect(out).to include(%(<a href="http://a">))
    end
  end

  describe "reference definition raw destination validation" do
    # The inline link parser already enforces these. These specs ensure
    # the reference definition parser is not more permissive.

    it "rejects a raw destination with an unbalanced opening paren" do
      out = render("[x]: foo(bar\n\n[x]\n")
      expect(out).not_to include("<a href=")
    end

    it "rejects a raw destination with an unbalanced closing paren" do
      out = render("[x]: foo)bar\n\n[x]\n")
      expect(out).not_to include("<a href=")
    end

    it "accepts a raw destination with balanced parens" do
      out = render("[x]: foo(bar)baz\n\n[x]\n")
      expect(out).to include(%(<a href="foo(bar)baz">))
    end

    it "accepts a raw destination with backslash-escaped paren" do
      out = render("[x]: foo\\(bar\n\n[x]\n")
      expect(out).to include("<a href=")
      # The backslash escape is unescaped in the final URI.
      expect(out).to include("foo(bar")
    end

    it "rejects a raw destination containing ASCII control char U+001F" do
      out = render("[x]: foo\u001Fbar\n\n[x]\n")
      expect(out).not_to include("<a href=")
    end

    it "rejects a raw destination containing DEL (U+007F)" do
      out = render("[x]: foo\u007Fbar\n\n[x]\n")
      expect(out).not_to include("<a href=")
    end

    it "still accepts an angle-bracket destination (separate rule)" do
      out = render("[x]: <http://a>\n\n[x]\n")
      expect(out).to include(%(<a href="http://a">))
    end
  end
end
