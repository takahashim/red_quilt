# frozen_string_literal: true

require "json"

RSpec.describe RedQuilt::Arena do
  describe "#check_integrity!" do
    let(:source) { "Hello *world*" }
    let(:arena) { described_class.new(source) }

    def build_minimum_tree
      root = arena.add_node(RedQuilt::NodeType::DOCUMENT,
                            source_start: 0, source_len: source.bytesize)
      para = arena.add_node(RedQuilt::NodeType::PARAGRAPH,
                            source_start: 0, source_len: source.bytesize)
      arena.append_child(root, para)
      [root, para]
    end

    it "passes on a fresh arena with a single node" do
      root = arena.add_node(RedQuilt::NodeType::DOCUMENT,
                            source_start: 0, source_len: source.bytesize)
      expect { arena.check_integrity!(root) }.not_to raise_error
    end

    it "passes on a small tree built normally" do
      root, _para = build_minimum_tree
      expect { arena.check_integrity!(root) }.not_to raise_error
    end

    it "passes on every parsed CommonMark example we already cover" do
      # Inline a few diverse samples instead of pulling the spec file.
      [
        "# Heading\n",
        "Hello *world*",
        "- item 1\n- item 2\n",
        "> quote with [link](/url) and **strong**",
        "```ruby\nputs 'hi'\n```\n",
        "| A | B |\n| - | - |\n| 1 | 2 |\n",
        "[ref]: /url\n\n[ref]",
        "~~struck~~ and `code`",
        "***deeply*** _nested_ emphasis",
      ].each do |md|
        doc = RedQuilt.parse(md)
        expect { doc.arena.check_integrity!(doc.root_id) }.not_to raise_error,
                                                                  "integrity violation on #{md.inspect}"
      end
    end

    context "structural violations" do
      it "detects a parent / child mismatch" do
        root, para = build_minimum_tree
        # Tamper: claim node `para` lives under root, but rewrite
        # @parent[para] to something else.
        arena.instance_variable_get(:@parent)[para] = 999
        expect { arena.check_integrity!(root) }
          .to raise_error(RedQuilt::Arena::IntegrityError, /parent mismatch/)
      end

      it "detects a broken prev_sibling chain" do
        root = arena.add_node(RedQuilt::NodeType::DOCUMENT, source_start: 0, source_len: 0)
        a = arena.add_node(RedQuilt::NodeType::PARAGRAPH, source_start: 0, source_len: 0)
        b = arena.add_node(RedQuilt::NodeType::PARAGRAPH, source_start: 0, source_len: 0)
        arena.append_child(root, a)
        arena.append_child(root, b)
        # Tamper: rewrite b's prev_sibling to bogus value
        arena.instance_variable_get(:@prev_sibling)[b] = 999
        expect { arena.check_integrity!(root) }
          .to raise_error(RedQuilt::Arena::IntegrityError, /prev_sibling/)
      end

      it "detects first_child / last_child inconsistency" do
        root = arena.add_node(RedQuilt::NodeType::DOCUMENT, source_start: 0, source_len: 0)
        # Tamper: set first_child without last_child
        arena.instance_variable_get(:@first_child)[root] = 99
        expect { arena.check_integrity!(root) }
          .to raise_error(RedQuilt::Arena::IntegrityError, /first_child=99 but last_child=-1/)
      end

      it "detects a shared subtree (same node reached twice)" do
        root = arena.add_node(RedQuilt::NodeType::DOCUMENT, source_start: 0, source_len: 0)
        a = arena.add_node(RedQuilt::NodeType::PARAGRAPH, source_start: 0, source_len: 0)
        b = arena.add_node(RedQuilt::NodeType::PARAGRAPH, source_start: 0, source_len: 0)
        arena.append_child(root, a)
        arena.append_child(root, b)
        # Tamper: make b's only child be a. a is now claimed by root *and*
        # by b. Both lookups stay otherwise consistent enough that the
        # cycle check is the one that fires.
        arena.instance_variable_get(:@first_child)[b] = a
        arena.instance_variable_get(:@last_child)[b] = a
        expect { arena.check_integrity!(root) }
          .to raise_error(RedQuilt::Arena::IntegrityError, /reached twice/)
      end

      it "rejects a non-existent root id" do
        expect { arena.check_integrity!(42) }
          .to raise_error(RedQuilt::Arena::IntegrityError, /has no row/)
      end

      it "rejects a root whose parent is not NO_NODE" do
        root = arena.add_node(RedQuilt::NodeType::DOCUMENT, source_start: 0, source_len: 0)
        arena.instance_variable_get(:@parent)[root] = 0
        expect { arena.check_integrity!(root) }
          .to raise_error(RedQuilt::Arena::IntegrityError, /non-NO_NODE parent/)
      end
    end
  end
end
