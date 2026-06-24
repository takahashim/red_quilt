# frozen_string_literal: true

module RedQuilt
  module Inline
    # CommonMark emphasis algorithm (spec 6.2). Phase 2 of inline parsing:
    # given the delimiter stack the linear pass collected (provisional TEXT
    # nodes for each `*` / `_` / `~` run), it pairs openers with closers and
    # rebuilds the arena subtree into EMPHASIS / STRONG / STRIKETHROUGH
    # nodes.
    #
    # Kept separate from Builder because it is a closed algorithm with a
    # narrow interface: it only needs the arena, the set of still-provisional
    # nodes (so consumed delimiters can be unmarked), and whether source
    # spans are tracked. Builder owns the linear pass and bracket handling;
    # it hands this resolver a delimiter stack to collapse.
    class EmphasisResolver
      # `count` is the CommonMark delimiter-run length; a Delimiter is
      # never enumerated, so shadowing Struct#count (from Enumerable) is
      # intentional rather than a footgun.
      Delimiter = Struct.new(:node_id, :char, :count, :can_open, :can_close) # rubocop:disable Lint/StructNewOverride

      def initialize(arena, track_source:)
        @arena = arena
        @track_source = track_source
      end

      # Collapses `stack` (an Array of Delimiter) in place, removing
      # consumed entries from `provisional_nodes`. Used both for the
      # document-level stack and for the inner delimiters of a resolved
      # link/image (see Builder#finalize_link).
      def resolve(stack, provisional_nodes)
        # NB: the CommonMark spec describes an `openers_bottom`
        # optimization keyed by closer character / length / flanking
        # flags. Implementing that correctly is subtle (a single
        # per-character bottom blocks valid matches like
        # `*foo**bar**baz*`), so the implementation here just walks
        # back to the start of the stack for every closer. This is
        # O(stack^2) in the worst case but stacks are tiny in practice.
        closer_idx = 0

        while closer_idx < stack.length
          closer = stack[closer_idx]
          unless closer.can_close
            closer_idx += 1
            next
          end

          opener_idx = closer_idx - 1
          found = false
          while opener_idx >= 0
            opener = stack[opener_idx]
            if opener.can_open && opener.char == closer.char
              skip = false
              if (opener.can_close || closer.can_open) &&
                 ((opener.count + closer.count) % 3).zero? &&
                 !((opener.count % 3).zero? && (closer.count % 3).zero?)
                skip = true
              end
              unless skip
                found = true
                break
              end
            end
            opener_idx -= 1
          end

          unless found
            unless closer.can_open
              provisional_nodes.delete(closer.node_id)
              stack.delete_at(closer_idx)
            end
            closer_idx += 1
            next
          end

          opener = stack[opener_idx]
          strength = [opener.count, closer.count].min >= 2 ? 2 : 1
          if closer.char == "~"
            # GFM strikethrough only forms on `~~` runs. A single `~`
            # leaves the delimiter as text; advance the cursor so future
            # `~~` pairs can still match.
            if strength < 2
              closer_idx += 1
              next
            end
            kind = NodeType::STRIKETHROUGH
          else
            kind = strength == 2 ? NodeType::STRONG : NodeType::EMPHASIS
          end

          # CommonMark spec: any delimiters strictly between this opener and
          # closer can't open or close anything in this scope, so drop them
          # from the stack before we rebuild the tree. Their arena nodes
          # stay where they are (they'll be reparented into the new emphasis
          # alongside the surrounding content), but they must no longer be
          # candidates for future iterations. Without this, the next
          # iteration would try to pair stranded delimiters that have
          # already been moved into a different parent, which corrupts the
          # sibling chain (Arena#reparent walks into @parent[-1]).
          if closer_idx > opener_idx + 1
            removed = stack.slice!((opener_idx + 1)...closer_idx)
            removed.each { |e| provisional_nodes.delete(e.node_id) }
            closer_idx = opener_idx + 1
            closer = stack[closer_idx]
          end

          opener_node = opener.node_id
          closer_node = closer.node_id

          if @track_source
            opener_match_start = @arena.source_end(opener_node) - strength
            closer_match_end = @arena.source_start(closer_node) + strength
          else
            opener_match_start = -1
            closer_match_end = 0
          end
          emphasis_id = add_node(kind, opener_match_start, closer_match_end)

          first_inside = @arena.raw_next_sibling_id(opener_node)
          last_inside = @arena.raw_prev_sibling_id(closer_node)
          if first_inside != -1 && last_inside != -1 &&
             first_inside != closer_node && last_inside != opener_node
            @arena.reparent(emphasis_id, first_inside, last_inside)
          end

          parent_id = @arena.raw_parent_id(opener_node)
          @arena.insert_before(parent_id, closer_node, emphasis_id)

          # Consume `strength` characters from the inner end of each
          # delimiter. The opener is trimmed on its right (trailing) end,
          # the closer on its left (leading) end; removing the opener from
          # the stack shifts the closer one slot left.
          closer_idx -= 1 if consume_delimiter(opener, opener_idx, stack, strength, provisional_nodes, from_start: false)
          consume_delimiter(closer, closer_idx, stack, strength, provisional_nodes, from_start: true)
        end

        stack.each { |e| provisional_nodes.delete(e.node_id) }
        stack.clear
      end

      private

      # Mirrors Builder#add_arena_node for the nodes this resolver creates
      # (emphasis wrappers only ever take a type and a span).
      def add_node(type, start_byte, end_byte)
        if @track_source
          @arena.add_node(type, source_start: start_byte, source_len: end_byte - start_byte)
        else
          @arena.add_node(type, source_start: -1, source_len: 0)
        end
      end

      # Removes `strength` characters from one end of a delimiter run. When
      # the whole run is consumed the node is detached and dropped from the
      # stack (returns true); otherwise its count, str1, and — in
      # source-tracking mode — its span are trimmed on the requested side
      # (`from_start` trims the leading end, used for closers; trailing for
      # openers) and it stays on the stack (returns false).
      def consume_delimiter(entry, index, stack, strength, provisional_nodes, from_start:)
        node = entry.node_id
        if entry.count == strength
          provisional_nodes.delete(node)
          @arena.detach(node)
          stack.delete_at(index)
          return true
        end

        entry.count -= strength
        str = @arena.str1(node)
        @arena.update_str1(node, from_start ? str[strength..] : str[0...-strength])
        if @track_source
          start_byte = @arena.source_start(node)
          end_byte = @arena.source_end(node)
          if from_start
            @arena.update_span(node, start_byte + strength, end_byte)
          else
            @arena.update_span(node, start_byte, end_byte - strength)
          end
        end
        false
      end
    end
  end
end
