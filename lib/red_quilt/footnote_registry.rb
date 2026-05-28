# frozen_string_literal: true

module RedQuilt
  # Shared state for the footnotes extension, created once per parse when
  # `footnotes: true` and threaded (by reference) through the block parser,
  # the inline builders, the FootnotePass, and the renderer. A single shared
  # object is required because the inline pass builds a fresh Builder per
  # materialized target, so the first-reference numbering counter cannot live
  # on a Builder instance.
  #
  # `nil` is used in place of a registry when footnotes are disabled, so the
  # collectors/resolvers can cheaply opt out.
  class FootnoteRegistry
    def initialize
      @definitions = {}            # normalized label => FOOTNOTE_DEFINITION node id
      @numbers = {}                # normalized label => footnote number
      @occurrences = Hash.new(0)   # normalized label => reference count
      @order = []                  # normalized labels in first-reference order
    end

    # Records a definition node for a label during block parsing. Returns
    # false when the label is already defined (duplicate), true otherwise.
    def define(label, node_id)
      return false if @definitions.key?(label)

      @definitions[label] = node_id
      true
    end

    def defined?(label)
      @definitions.key?(label)
    end

    def definition_node(label)
      @definitions[label]
    end

    # Records an inline reference to a label. Returns [number, occurrence]
    # (assigning the number on first reference, in encounter order), or nil
    # when the label has no definition.
    def reference(label)
      return nil unless @definitions.key?(label)

      unless @numbers.key?(label)
        @order << label
        @numbers[label] = @order.length
      end
      [@numbers[label], @occurrences[label] += 1]
    end

    def number(label)
      @numbers[label]
    end

    def occurrences(label)
      @occurrences[label]
    end

    # Referenced labels in first-reference order (the render order).
    def referenced_labels
      @order
    end

    def any_referenced?
      !@order.empty?
    end
  end
end
