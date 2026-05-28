# frozen_string_literal: true

module RedQuilt
  # Post-inline pass for the footnotes extension. After the inline pass has
  # resolved `[^label]` references (assigning numbers in first-reference
  # order on the shared FootnoteRegistry), this reorders the definition
  # nodes under the document-level footnotes section into that order, drops
  # definitions that were never referenced, and removes the whole section
  # when nothing referenced it.
  class FootnotePass
    def initialize(document)
      @document = document
      @arena = document.arena
      @registry = document.footnotes
    end

    def apply
      return if @registry.nil?

      # BlockParser moves the footnotes section to be root's last child, so
      # that's where it is (if any definitions were collected at all).
      section_id = @arena.raw_last_child_id(@document.root_id)
      return if section_id == -1 || @arena.type(section_id) != NodeType::FOOTNOTES_SECTION

      unless @registry.any_referenced?
        @arena.detach(section_id)
        return
      end

      # Re-append referenced definitions in first-reference order; detaching
      # all current children first means unreferenced definitions are left
      # orphaned (and so never rendered).
      @arena.child_ids(section_id).to_a.each { |child| @arena.detach(child) }
      @registry.referenced_labels.each do |label|
        @arena.append_child(section_id, @registry.definition_node(label))
      end
    end
  end
end
