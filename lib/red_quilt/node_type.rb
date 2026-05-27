# frozen_string_literal: true

module RedQuilt
  module NodeType
    DOCUMENT = 1
    PARAGRAPH = 10
    HEADING = 11
    THEMATIC_BREAK = 12
    BLOCKQUOTE = 13
    LIST = 14
    LIST_ITEM = 15
    CODE_BLOCK = 16
    HTML_BLOCK = 17
    TABLE = 18
    TABLE_ROW = 19
    TABLE_CELL = 20

    TEXT = 100
    SOFTBREAK = 101
    HARDBREAK = 102
    EMPHASIS = 103
    STRONG = 104
    CODE_SPAN = 105
    LINK = 106
    IMAGE = 107
    HTML_INLINE = 109
    STRIKETHROUGH = 111

    TYPE_NAMES = {
      DOCUMENT => :document,
      PARAGRAPH => :paragraph,
      HEADING => :heading,
      THEMATIC_BREAK => :thematic_break,
      BLOCKQUOTE => :blockquote,
      LIST => :list,
      LIST_ITEM => :list_item,
      CODE_BLOCK => :code_block,
      HTML_BLOCK => :html_block,
      TABLE => :table,
      TABLE_ROW => :table_row,
      TABLE_CELL => :table_cell,
      TEXT => :text,
      SOFTBREAK => :softbreak,
      HARDBREAK => :hardbreak,
      EMPHASIS => :emphasis,
      STRONG => :strong,
      CODE_SPAN => :code_span,
      LINK => :link,
      IMAGE => :image,
      HTML_INLINE => :html_inline,
      STRIKETHROUGH => :strikethrough
    }.freeze

    module_function

    def name_for(type)
      TYPE_NAMES.fetch(type)
    end
  end
end
