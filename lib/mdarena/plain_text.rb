# frozen_string_literal: true

module Mdarena
  # Extracts plain-text content from an arena subtree.
  #
  # TEXT / CODE_SPAN contribute their textual content as-is;
  # SOFTBREAK / HARDBREAK become a single space; every other inline
  # structure (EMPHASIS, STRONG, LINK, ...) is transparently recursed
  # into. The starting `node_id` itself is treated as a container — its
  # children are visited, but the node's own type does not appear in
  # the output (callers pass an IMAGE / HEADING / PARAGRAPH and want
  # the assembled inner text).
  #
  # Used by:
  # - Renderer::HTML for an image's alt attribute
  # - Document#first_heading_text for the CLI's --auto-title
  # - LintPass#check_missing_alt
  module PlainText
    module_function

    def from(arena, node_id)
      out = +""
      walk(arena, node_id, out)
      out
    end

    def walk(arena, node_id, out)
      arena.each_child(node_id) do |child_id|
        case arena.type(child_id)
        when NodeType::TEXT
          # TEXT may be span-only or carry a literal (entity / escape
          # decoded). Arena#text handles both.
          out << arena.text(child_id).to_s
        when NodeType::CODE_SPAN
          # CODE_SPAN always has str1 (normalized content), so read it
          # directly to skip Arena#text's nil-check / byteslice branch.
          out << arena.str1(child_id).to_s
        when NodeType::SOFTBREAK, NodeType::HARDBREAK
          out << " "
        else
          walk(arena, child_id, out)
        end
      end
    end
  end
end
