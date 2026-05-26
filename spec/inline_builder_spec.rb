# frozen_string_literal: true

RSpec.describe Markdast::Inline::Builder do
  let(:source) { "hello" }
  let(:arena) { Markdast::Arena.new(source) }
  let(:references) { {} }
  let(:tokens) { Markdast::Inline::Tokens.new }
  let(:builder) { described_class.new(arena, source, references) }

  describe "#build" do
    it "accepts an empty token stream without raising" do
      paragraph_id = arena.add_node(Markdast::NodeType::PARAGRAPH,
                                    source_start: 0, source_len: source.bytesize)
      expect { builder.build(paragraph_id, tokens) }.not_to raise_error
    end

    # Behavioral specs are added by the upcoming commits as each linear-pass
    # responsibility (TEXT / code spans / brackets / delimiter stack) lands.
  end
end
