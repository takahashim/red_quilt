# frozen_string_literal: true

module Mdarena
  # A single warning / error raised while parsing or rendering a
  # document. Diagnostics are collected on the Document and never
  # interrupt processing — every parse / render call still produces a
  # tree and HTML, even if it emitted diagnostics along the way.
  #
  # severity: :info / :warning / :error
  # rule:     a short Symbol identifying the rule (e.g. :unsafe_url,
  #           :missing_reference) so callers can filter / silence
  # message:  human-readable explanation
  # source_span: optional SourceSpan, points at the offending byte range
  class Diagnostic
    SEVERITIES = %i[info warning error].freeze

    attr_reader :severity, :rule, :message, :source_span

    def initialize(severity:, rule:, message:, source_span: nil)
      unless SEVERITIES.include?(severity)
        raise ArgumentError, "unknown severity: #{severity.inspect}"
      end

      @severity = severity
      @rule = rule
      @message = message
      @source_span = source_span
    end

    def to_h
      {
        severity: severity,
        rule: rule,
        message: message,
        source_span: source_span && { start_byte: source_span.start_byte, end_byte: source_span.end_byte }
      }
    end

    def ==(other)
      other.is_a?(Diagnostic) &&
        other.severity == severity &&
        other.rule == rule &&
        other.message == message &&
        other.source_span == source_span
    end
  end
end
