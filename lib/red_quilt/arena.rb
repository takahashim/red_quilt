# frozen_string_literal: true

module RedQuilt
  # Parallel-array storage for AST nodes.
  #
  # Each node has a single integer id (its position in the columns).
  # All structural and payload fields are stored as columns keyed by id:
  #
  #   structural   parent, first_child, last_child, next_sibling, prev_sibling
  #   source span  source_start (byte offset, -1 = no span), source_len
  #   payload      int1..int3, str1, str2  (per-NodeType conventions)
  #
  # Invariants:
  # - id starts at 0 and grows monotonically with #add_node. Ids are
  #   never reassigned and never reclaimed; a #detach'ed node keeps its
  #   row in the columns and stays addressable (its parent / siblings
  #   are reset to NO_NODE) but is no longer reachable from the tree.
  #   This means the arena's memory is monotone non-decreasing for the
  #   lifetime of a parse — a deliberate trade for allocation simplicity.
  # - NO_NODE (= -1) is the sentinel value used for "no parent",
  #   "no sibling", and as a source_start to mean "this node has no
  #   span; its content is materialized in str1 instead".
  # - @source is the original document string. It is treated as
  #   immutable: callers must not mutate it after constructing the
  #   arena, since byteslice positions stored in source_start/source_len
  #   refer to it directly.
  class Arena
    NO_NODE = -1

    # Raised by #check_integrity! when a structural invariant is violated.
    class IntegrityError < StandardError; end

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

    # Appends a fresh node to the arena and returns its id.
    # The node starts detached (parent = first_child = ... = NO_NODE).
    def add_node(type, source_start: NO_NODE, source_len: 0, int1: 0, int2: 0, int3: 0, str1: nil, str2: nil)
      id = @type.length
      @type[id] = type
      @parent[id] = NO_NODE
      @first_child[id] = NO_NODE
      @last_child[id] = NO_NODE
      @next_sibling[id] = NO_NODE
      @prev_sibling[id] = NO_NODE
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
      if @first_child[parent_id] == NO_NODE
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
      if prev_ref == NO_NODE
        @first_child[parent_id] = new_id
      else
        @next_sibling[prev_ref] = new_id
      end
      new_id
    end

    # Removes child_id from its current parent. The node's row stays in
    # the arena (its payload columns are untouched) but parent / siblings
    # are reset to NO_NODE, so the node is no longer reachable through
    # any tree walk. Detached rows are not reused by subsequent
    # #add_node calls.
    def detach(child_id)
      parent_id = @parent[child_id]
      prev_id = @prev_sibling[child_id]
      next_id = @next_sibling[child_id]

      if prev_id == NO_NODE
        @first_child[parent_id] = next_id
      else
        @next_sibling[prev_id] = next_id
      end

      if next_id == NO_NODE
        @last_child[parent_id] = prev_id
      else
        @prev_sibling[next_id] = prev_id
      end

      @parent[child_id] = NO_NODE
      @prev_sibling[child_id] = NO_NODE
      @next_sibling[child_id] = NO_NODE
      child_id
    end

    # Moves a contiguous sibling range [first_id .. last_id] (both
    # inclusive, walking #next_sibling from first to last) under
    # new_parent_id, replacing any existing children there. The walk
    # assumes the range is well-formed; passing nodes from different
    # parents or a last_id not reachable from first_id is undefined
    # behavior.
    def reparent(new_parent_id, first_id, last_id)
      return if first_id == NO_NODE || last_id == NO_NODE

      original_parent = @parent[first_id]
      prev_of_first = @prev_sibling[first_id]
      next_of_last = @next_sibling[last_id]

      if prev_of_first == NO_NODE
        @first_child[original_parent] = next_of_last
      else
        @next_sibling[prev_of_first] = next_of_last
      end

      if next_of_last == NO_NODE
        @last_child[original_parent] = prev_of_first
      else
        @prev_sibling[next_of_last] = prev_of_first
      end

      @prev_sibling[first_id] = NO_NODE
      @next_sibling[last_id] = NO_NODE

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

    # Structural id accessors. The `raw_` prefix flags that these return
    # raw column values that may be the NO_NODE sentinel, and the
    # `_id` suffix flags that the returned integer is a node id
    # (suitable for feeding back into other Arena methods).
    def raw_parent_id(id)
      @parent[id]
    end

    def raw_first_child_id(id)
      @first_child[id]
    end

    def raw_last_child_id(id)
      @last_child[id]
    end

    def raw_next_sibling_id(id)
      @next_sibling[id]
    end

    def raw_prev_sibling_id(id)
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

    # Returns a SourceSpan for the node, or nil when the node has no
    # span (source_start < 0, meaning the content is held in str1).
    def source_span(id)
      start_byte = @source_start[id]
      return nil if start_byte.nil? || start_byte.negative?

      SourceSpan.new(start_byte, start_byte + @source_len[id])
    end

    # Returns the node's textual content. Prefers str1 (the literal
    # form, e.g. an entity decoded to its character, or a reassembled
    # blockquote line). Falls back to a byteslice of @source when only
    # a span is recorded. Returns nil if neither is available.
    def text(id)
      literal = @str1[id]
      return literal unless literal.nil?

      start_byte = @source_start[id]
      return nil if start_byte.nil? || start_byte.negative?

      @source.byteslice(start_byte, @source_len[id])
    end

    # Yields each child id of `id` in order. Block form is preferred
    # over #child_ids on hot paths (renderer, builder) because it
    # avoids the Enumerator allocation.
    def each_child(id)
      child_id = @first_child[id]
      until child_id == NO_NODE
        yield child_id
        child_id = @next_sibling[child_id]
      end
      self
    end

    # Returns an Enumerator yielding each child id. Kept for the
    # external NodeRef API where Enumerator chaining (map, select, ...)
    # is convenient.
    def child_ids(id)
      Enumerator.new do |yielder|
        child_id = @first_child[id]
        until child_id == NO_NODE
          yielder << child_id
          child_id = @next_sibling[child_id]
        end
      end
    end

    def update_str1(id, value)
      @str1[id] = value
    end

    def update_int3(id, value)
      @int3[id] = value
    end

    def update_span(id, start_byte, end_byte)
      @source_start[id] = start_byte
      @source_len[id] = end_byte - start_byte
    end

    # Verifies the structural invariants of the tree rooted at root_id.
    # Raises IntegrityError on the first violation, including the
    # offending node id(s) and a description of the broken rule.
    #
    # Checked invariants:
    # - root has parent = NO_NODE
    # - for every reachable node `n` and its first_child / last_child
    #   `fc` / `lc`:
    #     * fc and lc are both NO_NODE, or both not NO_NODE
    #     * walking next_sibling from fc reaches lc and only lc
    #     * for each child `c`, @parent[c] == n
    #     * for each child `c`, @prev_sibling[c] equals the previously
    #       visited sibling (or NO_NODE for the first)
    # - no node is reached twice (no shared subtrees, no cycles)
    #
    # Intended for development / debugging. Not called by the production
    # parse / render path.
    def check_integrity!(root_id)
      raise IntegrityError, "root_id #{root_id} has no row" if root_id >= @type.length
      if @parent[root_id] != NO_NODE
        raise IntegrityError, "root #{root_id} has non-NO_NODE parent #{@parent[root_id]}"
      end

      visited = {}
      walk_for_integrity(root_id, NO_NODE, visited)
      self
    end

    private

    def walk_for_integrity(id, expected_parent_id, visited)
      if visited[id]
        raise IntegrityError, "node #{id} reached twice (cycle or shared subtree)"
      end

      visited[id] = true

      actual_parent = @parent[id]
      if actual_parent != expected_parent_id
        raise IntegrityError,
              "node #{id} parent mismatch: expected #{expected_parent_id}, got #{actual_parent}"
      end

      fc = @first_child[id]
      lc = @last_child[id]
      if (fc == NO_NODE) != (lc == NO_NODE)
        raise IntegrityError,
              "node #{id} first_child=#{fc} but last_child=#{lc} (one is NO_NODE, the other isn't)"
      end
      return if fc == NO_NODE

      prev_seen = NO_NODE
      child_id = fc
      tail = NO_NODE
      until child_id == NO_NODE
        if @prev_sibling[child_id] != prev_seen
          raise IntegrityError,
                "node #{child_id} prev_sibling=#{@prev_sibling[child_id]} but previous in chain was #{prev_seen}"
        end
        walk_for_integrity(child_id, id, visited)
        prev_seen = child_id
        tail = child_id
        child_id = @next_sibling[child_id]
      end

      if tail != lc
        raise IntegrityError,
              "node #{id} last_child=#{lc} but sibling chain from first_child=#{fc} ends at #{tail}"
      end
    end
  end
end
