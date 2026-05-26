# frozen_string_literal: true

module Mdarena
  module Inline
    module TokenKind
      TEXT           = 1
      ENTITY         = 2
      ESCAPED_CHAR   = 3
      LINE_ENDING    = 4
      CODE_DELIMITER = 5
      DELIM_RUN      = 6
      LBRACKET       = 7
      BANG_LBRACKET  = 8
      RBRACKET       = 9
      AUTOLINK_URI   = 10
      AUTOLINK_EMAIL = 11
      HTML_INLINE    = 12

      NAMES = {
        TEXT => :text,
        ENTITY => :entity,
        ESCAPED_CHAR => :escaped_char,
        LINE_ENDING => :line_ending,
        CODE_DELIMITER => :code_delimiter,
        DELIM_RUN => :delim_run,
        LBRACKET => :lbracket,
        BANG_LBRACKET => :bang_lbracket,
        RBRACKET => :rbracket,
        AUTOLINK_URI => :autolink_uri,
        AUTOLINK_EMAIL => :autolink_email,
        HTML_INLINE => :html_inline
      }.freeze

      def self.name(kind)
        NAMES[kind]
      end
    end
  end
end
