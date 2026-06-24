# frozen_string_literal: true

module RedQuilt
  module Inline
    # URL-scheme security policy for inline link / image / autolink
    # destinations. Kept separate from Builder so the "which schemes are
    # safe and how blocking is reported" concern has a single home and can
    # change without touching the inline construction logic.
    #
    # Stateless (module_function); diagnostics are appended to the caller's
    # array (or skipped when it is nil), so there is no per-call allocation.
    module UrlSanitizer
      module_function

      SAFE_SCHEMES = %w[http https mailto ftp tel ssh].freeze

      # Autolinks (`<scheme:...>`) are not run through the SAFE_SCHEMES
      # allowlist: CommonMark permits arbitrary schemes there (e.g.
      # `<made-up-scheme://x>`), and an allowlist would break that
      # conformance. Only the schemes that execute script when the link
      # is navigated are denied.
      UNSAFE_AUTOLINK_SCHEMES = %w[javascript vbscript data].freeze

      SCHEME_RE = /\A([a-zA-Z][a-zA-Z0-9+\-.]*):/

      # Link / image destinations: allowlist. Relative URLs (starting `/`
      # or `#`) and scheme-less URLs pass; an unknown scheme is blocked
      # (href emptied) and a diagnostic is recorded.
      def sanitize_destination(destination, diagnostics)
        return "" if destination.nil?
        return destination if destination.start_with?("/", "#")

        scheme = destination[SCHEME_RE, 1]
        return destination if scheme.nil?
        return destination if SAFE_SCHEMES.include?(scheme.downcase)

        report_blocked(diagnostics, scheme)
        ""
      end

      # Autolink destinations: denylist. The destination is returned
      # unchanged unless its scheme executes script on navigation, in which
      # case the href is emptied and a diagnostic is recorded.
      def block_unsafe_autolink(destination, diagnostics)
        scheme = destination[SCHEME_RE, 1]
        return destination if scheme.nil?
        return destination unless UNSAFE_AUTOLINK_SCHEMES.include?(scheme.downcase)

        report_blocked(diagnostics, scheme)
        ""
      end

      def report_blocked(diagnostics, scheme)
        return unless diagnostics

        diagnostics << Diagnostic.new(
          severity: :warning,
          rule: :unsafe_url,
          message: "Unsafe URL scheme #{scheme.downcase.inspect} blocked",
        )
      end
    end
  end
end
