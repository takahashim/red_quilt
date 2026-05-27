# frozen_string_literal: true

module RedQuilt
  # GFM Extended autolinks: rewrites bare URLs (`https://...`,
  # `http://...`, `ftp://...`, `www....`) and email addresses inside
  # TEXT nodes into LINK nodes. Runs as an optional pass after the
  # ordinary inline pipeline, so by then all CommonMark inline structure
  # (real `<...>` autolinks, code spans, links, ...) is already in place
  # and protected from rewriting.
  class ExtendedAutolinkPass
    URL_RE = %r{
      (?<![A-Za-z0-9_])
      (?:https?://|ftp://|www\.)
      [^\s<>]+
    }x

    EMAIL_RE = /
      (?<![A-Za-z0-9._+-])
      [A-Za-z0-9._+-]+
      @
      [A-Za-z0-9](?:[A-Za-z0-9\-_]{0,61}[A-Za-z0-9])?
      (?:\.[A-Za-z0-9](?:[A-Za-z0-9\-_]{0,61}[A-Za-z0-9])?)+
    /x

    TRAILING_PUNCT_RE = /[?!.,:*_~]+\z/
    TRAILING_ENTITY_RE = /&[A-Za-z0-9]+;\z/

    # AST contexts whose TEXT descendants must not be auto-linkified.
    SKIP_TYPES = [
      NodeType::LINK,
      NodeType::IMAGE,
      NodeType::CODE_SPAN,
      NodeType::HTML_INLINE,
      NodeType::CODE_BLOCK,
      NodeType::HTML_BLOCK
    ].freeze

    def initialize(document)
      @document = document
      @arena = document.arena
    end

    def apply
      walk(@document.root_id)
    end

    private

    def walk(node_id)
      return if node_id == -1

      type = @arena.type(node_id)
      return if SKIP_TYPES.include?(type)

      if type == NodeType::TEXT
        process_text(node_id)
        return
      end

      child = @arena.raw_first_child_id(node_id)
      while child != -1
        nxt = @arena.raw_next_sibling_id(child)
        walk(child)
        child = nxt
      end
    end

    Match = Struct.new(:start, :finish, :label, :dest)

    def process_text(node_id)
      text = @arena.text(node_id).to_s
      return if text.empty?

      matches = scan_text(text)
      return if matches.empty?

      parent = @arena.raw_parent_id(node_id)
      prev_end = 0
      matches.each do |m|
        if m.start > prev_end
          @arena.insert_before(parent, node_id,
                               @arena.add_node(NodeType::TEXT, str1: text[prev_end...m.start]))
        end
        link_id = @arena.add_node(NodeType::LINK, str1: m.dest)
        @arena.append_child(link_id,
                            @arena.add_node(NodeType::TEXT, str1: m.label))
        @arena.insert_before(parent, node_id, link_id)
        prev_end = m.finish
      end
      if prev_end < text.length
        @arena.insert_before(parent, node_id,
                             @arena.add_node(NodeType::TEXT, str1: text[prev_end..]))
      end
      @arena.detach(node_id)
    end

    def scan_text(text)
      matches = []
      pos = 0
      while pos < text.length
        url_m = URL_RE.match(text, pos)
        email_m = EMAIL_RE.match(text, pos)
        m = first_match(url_m, email_m)
        break unless m

        candidate = m[0]
        is_email = (m == email_m)
        trimmed = trim_trailing(candidate, email: is_email)
        if trimmed.empty? || !valid_domain?(trimmed, email: is_email)
          pos = m.begin(0) + 1
          next
        end

        start = m.begin(0)
        finish = start + trimmed.length
        dest = build_destination(trimmed, email: is_email)
        matches << Match.new(start, finish, trimmed, dest)
        pos = finish
      end
      matches
    end

    # GFM spec: "If the domain name contains an underscore (_) in its last two
    # segments, it is invalid." Applies to both URLs and email domains.
    def valid_domain?(candidate, email:)
      domain = extract_domain(candidate, email: email)
      return false if domain.nil? || domain.empty?

      segments = domain.split(".")
      return false if segments.length < 2

      last_two = segments.last(2)
      last_two.none? { |seg| seg.include?("_") }
    end

    def extract_domain(candidate, email:)
      if email
        candidate.split("@", 2)[1]
      elsif candidate.start_with?("www.")
        host = candidate[4..]
        host.split("/", 2).first
      else
        # https://, http://, ftp://
        after_scheme = candidate.sub(%r{\A[a-z]+://}, "")
        after_scheme.split("/", 2).first
      end
    end

    def first_match(a, b)
      return b unless a
      return a unless b

      a.begin(0) <= b.begin(0) ? a : b
    end

    def trim_trailing(candidate, email:)
      loop do
        before = candidate.length
        candidate = candidate.sub(TRAILING_PUNCT_RE, "")
        candidate = strip_excess_close_paren(candidate) unless email
        if candidate.end_with?(";") && (em = TRAILING_ENTITY_RE.match(candidate))
          candidate = candidate[0...em.begin(0)]
        end
        break candidate if candidate.length == before
      end
    end

    def strip_excess_close_paren(s)
      opens = s.count("(")
      closes = s.count(")")
      while closes > opens && s.end_with?(")")
        s = s[0..-2]
        closes -= 1
      end
      s
    end

    def build_destination(label, email:)
      return "mailto:#{label}" if email
      return "http://#{label}" if label.start_with?("www.")

      label
    end
  end
end
