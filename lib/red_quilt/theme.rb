# frozen_string_literal: true

module RedQuilt
  # Optional bundled stylesheets for standalone HTML output. `:none` (the
  # default) embeds no CSS and leaves the bare document untouched; named
  # themes load a stylesheet shipped under lib/red_quilt/themes/.
  module Theme
    DIR = File.expand_path("themes", __dir__)
    private_constant :DIR

    # Theme names that embed a bundled stylesheet (excludes :none).
    NAMES = %i[default].freeze

    module_function

    # Returns the CSS for `name`, or nil for :none / nil (no embedded CSS).
    # Raises ArgumentError for an unknown name.
    def css(name)
      name = (name || :none).to_sym
      return nil if name == :none
      unless NAMES.include?(name)
        raise ArgumentError, "unknown theme #{name.inspect} (available: none, #{NAMES.join(', ')})"
      end

      (@cache ||= {})[name] ||= File.read(File.join(DIR, "#{name}.css")).freeze
    end
  end
end
