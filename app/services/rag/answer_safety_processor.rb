# frozen_string_literal: true

require "set"

module Rag
  # Deterministic final guardrail for answers delivered to technicians.
  #
  # The generation prompt still uses machine-readable absence markers because
  # they are useful for evaluation and telemetry. This processor converts those
  # markers to user-facing language and rejects connector/terminal/LED labels
  # that are not present in the evidence returned with the answer.
  class AnswerSafetyProcessor
    INTERNAL_MARKER_PATTERN =
      /\b(?:DATA_NOT_AVAILABLE|REQUIRES?_FIELD_VERIFICATION)\b/.freeze

    IDENTIFIER_PATTERN = /
      (?<![[:alnum:]_])
      (?:
        X[A-Z0-9](?:[A-Z0-9._-]*[A-Z0-9])? |
        CN-?\d+(?:\.[A-Z0-9]+)* |
        B\d+[A-Z0-9_-]* |
        C\d+[A-Z0-9_-]* |
        [DLT]\d+[A-Z0-9_-]* |
        DL-?\d+[A-Z0-9_-]* |
        LED-?\d+[A-Z0-9_-]*
      )
      (?![[:alnum:]_])
    /x.freeze
    EVIDENCE_SENSITIVE_VALUE_PATTERN =
      /\b\d+(?:[.,]\d+)?\s*(?:V(?:AC|DC)?|A|HZ|NM|BAR|MM|CM|°C)\b/i.freeze
    EVIDENCE_SENSITIVE_STATE_PATTERN =
      /\b(?:LED|encendid[oa]|apagad[oa]|normal|fallo|fault|on|off)\b/i.freeze

    CONNECTION_CLAIM_PATTERN =
      /(?:conect|borna|terminal|cablead|wired|→|->)/i.freeze
    # "indica"/"señala" alone name a documented series/label attribution (e.g. "D10
    # indica la SERIE SEGURIDAD CABINA"), not ON/OFF logic — they only count as a
    # state claim when paired with an actual state term in the same line/fragment.
    LED_STATE_VERB_PATTERN =
      /(?:se\s+(?:enciende|apaga)|est[aá]\s+(?:encendido|apagado)|lights?|turns?\s+(?:on|off)|is\s+(?:on|off))/i.freeze
    LED_ATTRIBUTION_VERB_PATTERN = /(?:indica|señala)/i.freeze
    LED_STATE_TERM_PATTERN = /(?:encendid|apagad|fallo|aver[ií]a|normal|\bon\b|\boff\b)/i.freeze
    DEVICE_FUNCTION_CLAIM_PATTERN =
      /(?:limitador|limiter).{0,60}(?:sobrecarga|overload)|(?:sobrecarga|overload).{0,60}(?:limitador|limiter)/i.freeze
    COMPONENT_CODE_PATTERN = /\b[A-Z][A-Z0-9_-]{2,}\b/.freeze
    COMPONENT_CODE_STOPWORDS = %w[
      DATA NOT AVAILABLE REQUIRE REQUIRES FIELD VERIFICATION LED
      DATA_NOT_AVAILABLE REQUIRE_FIELD_VERIFICATION REQUIRES_FIELD_VERIFICATION
    ].freeze
    # A "(SERIE ...)" parenthetical names the documented LED/series category a
    # code belongs to (e.g. "41 (SERIE CERROJOS CABINA)") — it is a label, not a
    # wired component, so it must not be scanned for connector-claim components.
    SERIES_LABEL_PATTERN = /\(\s*SERIE\b[^)]*\)/i.freeze

    def initialize(locale: nil)
      @locale = normalize_locale(locale)
    end

    # Split on real sentence boundaries only. A period between alphanumerics is
    # part of an identifier (CN-112.SC, CN-109.CC) and must not break the fragment,
    # otherwise a documented connector is split apart and falsely rejected (MR08).
    # Public so other evidence-fragment consumers (Rag::EvidenceCandidateSelector)
    # reuse this exact split instead of reimplementing it.
    FRAGMENT_SPLIT_PATTERN = /[\n!?]+|\.(?=\s|\z)/.freeze

    def self.fragments(text)
      text.to_s.split(FRAGMENT_SPLIT_PATTERN).map(&:strip).reject(&:empty?)
    end

    def self.requires_evidence?(answer)
      text = answer.to_s
      text.match?(IDENTIFIER_PATTERN) ||
        text.match?(EVIDENCE_SENSITIVE_VALUE_PATTERN) ||
        text.match?(EVIDENCE_SENSITIVE_STATE_PATTERN)
    end

    # Fail-closed applies only to answers that carry evidence-sensitive claims
    # (identifiers, values, states). Abstentions and plain summaries are NOT
    # destroyed for lacking a native citation — they are delivered as-is.
    def self.requires_citation?(answer)
      requires_evidence?(answer)
    end

    def call(answer, evidence:, require_cited_evidence: false)
      return "" if answer.blank?

      source = evidence_text(evidence)
      if require_cited_evidence && source.blank? && self.class.requires_citation?(answer)
        return I18n.t("rag.uncited_technical_answer", locale: @locale)
      end

      validated = reject_unsupported_connection_claims(answer.to_s, source)
      validated = reject_unsupported_led_logic(validated, source)
      validated = reject_unsupported_device_functions(validated, source)
      validated = reject_unsupported_identifiers(validated, source)
      validated = prune_orphan_headers(validated)
      render_internal_markers(validated)
    end

    private

    def reject_unsupported_identifiers(answer, evidence)
      answer_ids = identifiers_in(answer)
      return answer if answer_ids.empty?

      evidence_ids = identifiers_in(evidence).map { |identifier| canonical(identifier) }.to_set
      unsupported = answer_ids.reject { |identifier| evidence_ids.include?(canonical(identifier)) }
      return answer if unsupported.empty?

      unsupported_keys = unsupported.map { |identifier| canonical(identifier) }.to_set
      replacement = I18n.t("rag.unsupported_identifier", locale: @locale)

      replacement_emitted = false
      answer.lines.filter_map do |line|
        line_ids = identifiers_in(line)
        if line_ids.any? { |identifier| unsupported_keys.include?(canonical(identifier)) }
          next if replacement_emitted

          replacement_emitted = true
          next "#{replacement}#{citation_suffix(line)}\n"
        end

        line
      end.join
    end

    def reject_unsupported_connection_claims(answer, evidence)
      transform_claim_lines(answer) do |line|
        next unless line.match?(CONNECTION_CLAIM_PATTERN)

        connectors = identifiers_in(line).reject { |identifier| led_identifier?(identifier) }
        next if connectors.empty?

        component_source = line.gsub(SERIES_LABEL_PATTERN, " ")
        components = component_source.scan(COMPONENT_CODE_PATTERN).reject do |code|
          COMPONENT_CODE_STOPWORDS.include?(code) ||
            board_model_name?(code) ||
            connectors.any? { |connector| canonical(connector) == canonical(code) }
        end
        next if components.empty?

        supported = connectors.all? do |connector|
          components.any? do |component|
            evidence_fragments(evidence).any? do |fragment|
              relationship_fragment?(fragment) &&
                fragment.match?(/\b#{Regexp.escape(connector)}\b/i) &&
                fragment.match?(/\b#{Regexp.escape(component)}\b/i)
            end
          end
        end
        I18n.t("rag.unsupported_connection", locale: @locale) unless supported
      end
    end

    def reject_unsupported_led_logic(answer, evidence)
      transform_claim_lines(answer) do |line|
        led_ids = identifiers_in(line).select { |identifier| led_identifier?(identifier) }
        next if led_ids.empty? || !led_state_claim?(line)

        supported = led_ids.all? do |identifier|
          evidence_fragments(evidence).any? do |fragment|
            fragment.match?(/\b#{Regexp.escape(identifier)}\b/i) &&
              led_state_claim?(fragment)
          end
        end
        unless supported
          I18n.t(
            "rag.undocumented_led_logic",
            locale: @locale,
            identifier: led_ids.join(", ")
          )
        end
      end
    end

    def reject_unsupported_device_functions(answer, evidence)
      transform_claim_lines(answer) do |line|
        next unless line.match?(DEVICE_FUNCTION_CLAIM_PATTERN)
        next if evidence_fragments(evidence).any? { |fragment| fragment.match?(DEVICE_FUNCTION_CLAIM_PATTERN) }

        I18n.t("rag.unsupported_device_function", locale: @locale)
      end
    end

    def transform_claim_lines(answer)
      answer.lines.map do |line|
        replacement = yield(line)
        replacement ? "#{replacement}#{citation_suffix(line)}\n" : line
      end.join
    end

    # Removes a heading/label line left without a body after a claim underneath it
    # was dropped or degraded (TOKIBAT: `**Cuándo se enciende:**` with nothing
    # below it). A header is orphaned when the next non-blank line is another
    # header or the answer ends.
    def prune_orphan_headers(answer)
      lines = answer.lines
      keep = Array.new(lines.length, true)

      lines.each_with_index do |line, index|
        next unless header_line?(line)

        next_index = index + 1
        next_index += 1 while next_index < lines.length && lines[next_index].strip.empty?

        keep[index] = false if next_index >= lines.length ||
          header_line?(lines[next_index]) ||
          lines[next_index].match?(INTERNAL_MARKER_PATTERN)
      end

      lines.each_index.select { |index| keep[index] }.map { |index| lines[index] }.join
    end

    HEADER_LINE_PATTERN = /
      \A\s*
      (?:
        \#{1,6}\s+\S.* |          # markdown heading
        \*\*[^*\n]+\*\*:? |       # bold label, optional trailing colon
        [^:\n]{1,60}:             # short label ending in a colon
      )
      \s*\z
    /x.freeze

    def header_line?(line)
      line.to_s.match?(HEADER_LINE_PATTERN)
    end

    def render_internal_markers(answer)
      answer
        .gsub(/\bDATA_NOT_AVAILABLE\b/, I18n.t("rag.data_not_available", locale: @locale))
        .gsub(
          /\bREQUIRES?_FIELD_VERIFICATION\b/,
          I18n.t("rag.requires_field_verification", locale: @locale)
        )
    end

    def evidence_text(evidence)
      Array(evidence).filter_map do |item|
        if item.is_a?(Hash)
          item[:content] || item["content"]
        elsif item.respond_to?(:content)
          item.content
        end
      end.join("\n")
    end

    def evidence_fragments(evidence)
      @evidence_fragments = nil unless defined?(@last_evidence) && @last_evidence == evidence
      @last_evidence = evidence
      @evidence_fragments ||= self.class.fragments(evidence)
    end

    def relationship_fragment?(fragment)
      fragment.match?(CONNECTION_CLAIM_PATTERN) ||
        fragment.include?("|") ||
        fragment.match?(/\b(?:ACTION|DETAILS|EXPECTED_RESULT):/i)
    end

    def identifiers_in(text)
      text.to_s.scan(IDENTIFIER_PATTERN).uniq
    end

    def canonical(identifier)
      identifier.to_s.upcase.gsub(/[^A-Z0-9]/, "")
    end

    def led_identifier?(identifier)
      identifier.to_s.match?(/\A(?:DL|LED|D|L|T)-?\d/i)
    end

    # A hyphenated model designation (EDEL-K2, ALTIUS-D9) is the board's own
    # name, not a wired component — it must never need a separate connector
    # pairing. A bare digit is not enough: pin/terminal labels enumerated
    # alongside a connector (PC3, C1, C2) also contain a digit but ARE real
    # components whose support the evidence documents (MR08 mr08_sci).
    def board_model_name?(code)
      code.match?(/\A[A-Z]+-[A-Z]?\d/i)
    end

    # A bare state verb ("se enciende", "está apagado") always counts. A pure
    # attribution verb ("indica", "señala") only counts when it co-occurs with a
    # state term — otherwise it is naming a documented series/label, not ON/OFF
    # logic, and must not be treated as an unsupported claim.
    def led_state_claim?(text)
      text.match?(LED_STATE_VERB_PATTERN) ||
        (text.match?(LED_ATTRIBUTION_VERB_PATTERN) && text.match?(LED_STATE_TERM_PATTERN))
    end

    def citation_suffix(line)
      markers = line.to_s.scan(/\[\d+\]/).uniq
      markers.empty? ? "" : markers.join
    end

    def normalize_locale(locale)
      candidate = locale.presence&.to_sym
      I18n.available_locales.include?(candidate) ? candidate : I18n.locale
    rescue StandardError
      :es
    end
  end
end
