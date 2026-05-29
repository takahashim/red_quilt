# frozen_string_literal: true

require "tilt"
require "red_quilt"

module RedQuilt
  # Tilt template adapter. Require this file explicitly to register RedQuilt
  # with Tilt -- `tilt` is an optional dependency, so a missing gem surfaces
  # as a LoadError here rather than silently disabling the integration:
  #
  #   require "red_quilt/tilt"
  #   Tilt.new("page.md").render
  class TiltTemplate < Tilt::Template
    self.default_mime_type = "text/html"

    NATIVE_OPTIONS = %i[allow_html disallow_raw_html extended_autolinks footnotes lint heading_ids].freeze

    def prepare; end

    def evaluate(_scope, _locals)
      @output ||= RedQuilt.render_html(data, **render_options)
    end

    # RedQuilt escapes raw HTML and never emits embedded scripting, so the
    # output is a finished, script-free fragment.
    def allows_script?
      false
    end

    private

    def render_options
      opts = options.slice(*NATIVE_OPTIONS)
      # Tilt's cross-engine markdown convention is :escape_html; RedQuilt's
      # native switch is its inverse (allow_html), so map it when present.
      opts[:allow_html] = !options[:escape_html] if options.key?(:escape_html)
      opts
    end
  end

  Tilt.register(TiltTemplate, "md", "markdown", "mkd", "mkdn", "mdown")
end
