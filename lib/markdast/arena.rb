# frozen_string_literal: true

module Markdast
  class Arena
    attr_reader :source

    def initialize(source)
      @source = source
      @type = []
      @parent = []
      @first_child = []
      @last_child = []
      @next_sibling = []
      @prev_sibling = []
      @source_start = []
      @source_len = []
      @int1 = []
      @int2 = []
      @int3 = []
      @str1 = []
      @str2 = []
    end

    def add_node(type, source_start: -1, source_len: 0, int1: 0, int2: 0, int3: 0, str1: nil, str2: nil)
      id = @type.length
      @type[id] = type
      @parent[id] = -1
      @first_child[id] = -1
      @last_child[id] = -1
      @next_sibling[id] = -1
      @prev_sibling[id] = -1
      @source_start[id] = source_start
      @source_len[id] = source_len
      @int1[id] = int1
      @int2[id] = int2
      @int3[id] = int3
      @str1[id] = str1
      @str2[id] = str2
      id
    end

    def append_child(parent_id, child_id)
      @parent[child_id] = parent_id
      if @first_child[parent_id] == -1
        @first_child[parent_id] = child_id
        @last_child[parent_id] = child_id
      else
        last = @last_child[parent_id]
        @next_sibling[last] = child_id
        @prev_sibling[child_id] = last
        @last_child[parent_id] = child_id
      end
      child_id
    end

    # Inserts new_id immediately before ref_id in parent_id's child list.
    def insert_before(parent_id, ref_id, new_id)
      @parent[new_id] = parent_id
      prev_ref = @prev_sibling[ref_id]
      @prev_sibling[new_id] = prev_ref
      @next_sibling[new_id] = ref_id
      @prev_sibling[ref_id] = new_id
      if prev_ref == -1
        @first_child[parent_id] = new_id
      else
        @next_sibling[prev_ref] = new_id
      end
      new_id
    end

    # Removes child_id from its current parent. The node still exists in
    # the arena but has no parent and no siblings.
    def detach(child_id)
      parent_id = @parent[child_id]
      prev_id = @prev_sibling[child_id]
      next_id = @next_sibling[child_id]

      if prev_id == -1
        @first_child[parent_id] = next_id
      else
        @next_sibling[prev_id] = next_id
      end

      if next_id == -1
        @last_child[parent_id] = prev_id
      else
        @prev_sibling[next_id] = prev_id
      end

      @parent[child_id] = -1
      @prev_sibling[child_id] = -1
      @next_sibling[child_id] = -1
      child_id
    end

    # Moves a contiguous sibling range [first_id .. last_id] (both inclusive,
    # walking #next_sibling from first to last) under new_parent_id, replacing
    # any existing children there.
    def reparent(new_parent_id, first_id, last_id)
      return if first_id == -1 || last_id == -1

      original_parent = @parent[first_id]
      prev_of_first = @prev_sibling[first_id]
      next_of_last = @next_sibling[last_id]

      if prev_of_first == -1
        @first_child[original_parent] = next_of_last
      else
        @next_sibling[prev_of_first] = next_of_last
      end

      if next_of_last == -1
        @last_child[original_parent] = prev_of_first
      else
        @prev_sibling[next_of_last] = prev_of_first
      end

      @prev_sibling[first_id] = -1
      @next_sibling[last_id] = -1

      id = first_id
      loop do
        @parent[id] = new_parent_id
        break if id == last_id
        id = @next_sibling[id]
      end

      @first_child[new_parent_id] = first_id
      @last_child[new_parent_id] = last_id
    end

    def type(id)
      @type[id]
    end

    def type_name(id)
      NodeType.name_for(@type[id])
    end

    def parent(id)
      @parent[id]
    end

    def first_child(id)
      @first_child[id]
    end

    def last_child(id)
      @last_child[id]
    end

    def next_sibling(id)
      @next_sibling[id]
    end

    def prev_sibling(id)
      @prev_sibling[id]
    end

    def source_start(id)
      @source_start[id]
    end

    def source_len(id)
      @source_len[id]
    end

    def int1(id)
      @int1[id]
    end

    def int2(id)
      @int2[id]
    end

    def int3(id)
      @int3[id]
    end

    def str1(id)
      @str1[id]
    end

    def str2(id)
      @str2[id]
    end

    def source_span(id)
      start_byte = @source_start[id]
      return nil if start_byte.nil? || start_byte.negative?

      SourceSpan.new(start_byte, start_byte + @source_len[id])
    end

    def text(id)
      literal = @str1[id]
      return literal unless literal.nil?

      start_byte = @source_start[id]
      return nil if start_byte.nil? || start_byte.negative?

      @source.byteslice(start_byte, @source_len[id])
    end

    def child_ids(id)
      Enumerator.new do |yielder|
        child_id = @first_child[id]
        until child_id == -1
          yielder << child_id
          child_id = @next_sibling[child_id]
        end
      end
    end

    def replace_str1(id, value)
      @str1[id] = value
    end

    def replace_int3(id, value)
      @int3[id] = value
    end

    def replace_text(id, value, source_start: @source_start[id], source_len: @source_len[id])
      @str1[id] = value
      @source_start[id] = source_start
      @source_len[id] = source_len
    end

    def update_span(id, start_byte, end_byte)
      @source_start[id] = start_byte
      @source_len[id] = end_byte - start_byte
    end
  end
end
