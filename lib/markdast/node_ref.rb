# frozen_string_literal: true

module Markdast
  class NodeRef
    include Enumerable

    attr_reader :document, :node_id

    def initialize(document, node_id)
      @document = document
      @arena = document.arena
      @node_id = node_id
    end

    def each(&block)
      walk(&block)
    end

    def type
      @arena.type_name(@node_id)
    end

    def children
      @arena.child_ids(@node_id).map { |child_id| NodeRef.new(@document, child_id) }
    end

    def walk
      return enum_for(:walk) unless block_given?

      yield self
      @arena.child_ids(@node_id).each do |child_id|
        NodeRef.new(@document, child_id).walk { |node| yield node }
      end
    end

    def text
      first_child_id = @arena.first_child(@node_id)
      return @arena.text(@node_id) if first_child_id == -1

      text = +""
      @arena.child_ids(@node_id).each do |child_id|
        child = NodeRef.new(@document, child_id)
        fragment = child.text
        text << fragment.to_s unless fragment.nil?
      end
      text
    end

    def source_span
      @arena.source_span(@node_id)
    end

    def find_all(type)
      walk.select { |node| node.type == type }
    end
  end
end
