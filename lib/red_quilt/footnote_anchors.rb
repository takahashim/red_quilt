# frozen_string_literal: true

module RedQuilt
  # Single source of truth for the HTML element ids used to wire footnote
  # references to their definitions and back. Both the reference (`<sup>`),
  # the definition (`<li>`), and the back-reference links must agree on
  # these strings, so they live in one place rather than being rebuilt at
  # each call site.
  module FootnoteAnchors
    module_function

    # Id of the definition `<li>` and the target of a reference link.
    def definition_id(number)
      "fn-#{number}"
    end

    # Id of a reference `<sup>` and the target of a back-reference link.
    # A repeated reference (occurrence > 1) gets a `-N` suffix so every
    # back-reference has a unique anchor.
    def reference_id(number, occurrence)
      occurrence > 1 ? "fnref-#{number}-#{occurrence}" : "fnref-#{number}"
    end
  end
end
