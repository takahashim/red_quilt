# frozen_string_literal: true

module RedQuilt
  class NodeRef
    include Enumerable

    attr_reader :document, :node_id

    def initialize(document, node_id)
      @document = document
      @arena = document.arena
      @node_id = node_id
    end

    def each(&)
      walk(&)
    end

    def type
      @arena.type_name(@node_id)
    end

    def children
      @arena.child_ids(@node_id).map { |child_id| NodeRef.new(@document, child_id) }
    end

    def walk(&block)
      return enum_for(:walk) unless block_given?

      yield self
      @arena.child_ids(@node_id).each do |child_id|
        NodeRef.new(@document, child_id).walk(&block)
      end
    end

    def text
      first_child_id = @arena.raw_first_child_id(@node_id)
      return @arena.text(@node_id) if first_child_id == -1

      text = +""
      @arena.child_ids(@node_id).each do |child_id|
        child = NodeRef.new(@document, child_id)
        fragment = child.text
        text << fragment.to_s unless fragment.nil?
      end
      text
    end

    # Node attributes, by NodeType.
    #
    # Each returns nil when the node does not carry the attribute, so callers
    # can walk the tree branching on #type and read the type's own fields
    # without a Hash allocation per node. The Arena's accessors are the raw
    # layer and deliberately skip that check: several attributes share a
    # storage column, so reading one off a mismatched node yields another
    # field's value rather than nil (e.g. Arena#link_destination on a
    # paragraph returns the paragraph's text). These wrappers are the safe
    # way to read attributes.

    # CODE_BLOCK: the fence info string, e.g. "ruby" or 'vtt audio="x.mp3"'.
    # A code block written without one has an empty info string, so "" means
    # "no info given" while nil means "not a code block".
    def info
      return nil unless type?(NodeType::CODE_BLOCK)

      @arena.code_block_info(@node_id).to_s
    end

    # HEADING: nesting level (1..6).
    def heading_level
      @arena.heading_level(@node_id) if type?(NodeType::HEADING)
    end

    # LIST: ordered (`1.`) vs bullet (`-`).
    def list_ordered?
      @arena.list_ordered?(@node_id) if type?(NodeType::LIST)
    end

    # LIST: start number of an ordered list.
    def list_start
      @arena.list_start(@node_id) if type?(NodeType::LIST)
    end

    # LIST: tight (no blank lines between items) vs loose.
    def list_tight?
      @arena.list_tight?(@node_id) if type?(NodeType::LIST)
    end

    # LIST: the item delimiter as authored, e.g. "-" or "1.".
    def list_delimiter
      @arena.list_delimiter(@node_id) if type?(NodeType::LIST)
    end

    # LINK / IMAGE: the destination URL.
    def link_destination
      @arena.link_destination(@node_id) if link_like?
    end

    # LINK / IMAGE: the optional title, nil when absent.
    def link_title
      @arena.link_title(@node_id) if link_like?
    end

    # FOOTNOTE_DEFINITION / FOOTNOTE_REFERENCE: the label as authored.
    def footnote_label
      @arena.footnote_label(@node_id) if footnote_like?
    end

    # FOOTNOTE_DEFINITION / FOOTNOTE_REFERENCE: the resolved 1-based number.
    def footnote_number
      @arena.footnote_number(@node_id) if footnote_like?
    end

    # TABLE_ROW / TABLE_CELL: whether this belongs to the header row.
    #
    # nil rather than false outside a table, matching the other attribute
    # accessors: a paragraph is not a non-header row, it has no header-ness
    # at all. Both answers are falsy, so `if node.header?` reads the same.
    def header?
      return @arena.table_row_header?(@node_id) if type?(NodeType::TABLE_ROW)
      return @arena.table_cell_header?(@node_id) if type?(NodeType::TABLE_CELL)

      nil # rubocop:disable Style/ReturnNilInPredicateMethodDefinition
    end

    def source_span
      @arena.source_span(@node_id)
    end

    def find_all(type)
      walk.select { |node| node.type == type }
    end

    def source_location
      span = source_span
      return nil unless span

      start_loc = @document.source_map.line_column(span.start_byte)
      end_loc = @document.source_map.line_column(span.end_byte)

      {
        start_line: start_loc[:line],
        start_column: start_loc[:column],
        end_line: end_loc[:line],
        end_column: end_loc[:column],
      }
    end

    def to_h
      ast = {
        type: type,
        source_span: source_span,
        children: children.map(&:to_h),
      }

      attributes = ast_attributes
      ast[:attributes] = attributes unless attributes.empty?
      ast
    end

    private

    def type?(node_type)
      @arena.type(@node_id) == node_type
    end

    # Kept allocation-free (no splat) because these accessors are meant for
    # per-node use while walking a whole document.
    def link_like?
      node_type = @arena.type(@node_id)
      node_type == NodeType::LINK || node_type == NodeType::IMAGE
    end

    def footnote_like?
      node_type = @arena.type(@node_id)
      node_type == NodeType::FOOTNOTE_DEFINITION || node_type == NodeType::FOOTNOTE_REFERENCE
    end

    def ast_attributes
      case @arena.type(@node_id)
      when NodeType::HEADING
        { level: @arena.heading_level(@node_id), text: text }
      when NodeType::LIST
        {
          ordered: @arena.list_ordered?(@node_id),
          start_number: @arena.list_start(@node_id),
          tight: @arena.list_tight?(@node_id),
          delimiter: @arena.list_delimiter(@node_id),
        }
      when NodeType::TABLE_ROW
        { header: @arena.table_row_header?(@node_id), text: text }
      when NodeType::TABLE_CELL
        { header: @arena.table_cell_header?(@node_id), text: text }
      when NodeType::TEXT, NodeType::CODE_SPAN, NodeType::HTML_BLOCK, NodeType::HTML_INLINE, NodeType::PARAGRAPH
        { text: text }
      when NodeType::CODE_BLOCK
        { text: @arena.text(@node_id), info: @arena.code_block_info(@node_id) }
      when NodeType::LINK, NodeType::IMAGE
        { destination: @arena.link_destination(@node_id), title: @arena.link_title(@node_id), text: text }
      when NodeType::FOOTNOTE_REFERENCE
        { label: @arena.footnote_label(@node_id), number: @arena.footnote_number(@node_id) }
      when NodeType::FOOTNOTE_DEFINITION
        { label: @arena.footnote_label(@node_id) }
      else
        {}
      end
    end
  end
end
