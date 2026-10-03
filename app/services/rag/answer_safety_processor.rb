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
    INTERNAL_MARKER_PARAGRAPH_PATTERN =
      /\A\s*(?:\*\*|__)?(?:DATA_NOT_AVAILABLE|REQUIRES?_FIELD_VERIFICATION)\b/.freeze

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
    # Corpus-agnostic wired-pair guard. IDENTIFIER_PATTERN only recognises
    # endpoints shaped like X…, CN-<n>, B<n>, C<n>, [DLT]<n> or LED-<n>, so a
    # claim between two plain printed labels ("LIMITADOR -> CONECTOR AI") never
    # reaches the identifier check below and a chain fabricated from two real
    # edges (A -> X plus B -> X, therefore A -> B) goes through untouched. This
    # guard reads both endpoints off the answer line itself and requires a
    # single `ACTION:` line of the evidence — the shape a traced edge is
    # rendered with — to name the pair. Reading the endpoints off the line needs
    # no equipment vocabulary, which is why IDENTIFIER_PATTERN stays frozen
    # (test/architecture/no_hardcoded_equipment_test.rb).
    #
    # Only verb forms and the arrow state a relation: "conector"/"conectores"
    # are nouns and naming one is not a claim about what it is wired to.
    WIRED_PAIR_RELATION_PATTERN = /
      -> | → |
      \bconect(?:a|an|ada|adas|ado|ados|ar|arse)\b |
      \bcablead(?:a|as|o|os)\b |
      \bconnect(?:s|ed|ing)?\b |
      \bwired\b
    /xi.freeze
    # An endpoint is a printed all-caps label, possibly multi-word: the layout
    # extractor keeps a label's internal spaces ("CONECTOR AI", plan I-08).
    ENDPOINT_LABEL_PATTERN =
      %r{[[:upper:]][[:upper:][:digit:]._+/-]{2,}(?:[ ]+[[:upper:][:digit:]._+/-]+)*}.freeze
    ACTION_LINE_PATTERN = /^[^\S\n]*ACTION:[^\S\n]*(\S[^\n]*)$/.freeze
    DERIVATION_LINE_PATTERN = /^[^\S\n]*DERIVATION:[^\S\n]*(\S[^\n]*)$/.freeze
    # Scoped per FIELD_RECORD block (not a bare ACTION_LINE_PATTERN scan) so the
    # DERIVATION read for a pair is the one from ITS OWN record, never a
    # neighbouring record's. Fase 6b: a RECORD_TYPE: TOPOLOGY_EDGE traced by
    # vision is not yet ground truth the way a leader-line trace is, so the
    # generation contract requires the answer to carry its own read-from-image
    # confirmation qualifier alongside a vision-derived pair.
    RECORD_BLOCK_PATTERN = /^[^\S\n]*FIELD_RECORD:[^\S\n]*\n(.*?)^[^\S\n]*END_FIELD_RECORD[^\S\n]*$/m.freeze
    VISION_SOURCE_PATTERN = /\b(?:imagen|image|foto|photo)\b/i.freeze
    VISION_CONFIRMATION_PATTERN = /
      \b(?:confirm\w*|verific\w*)\b .{0,120}? \b(?:diagrama|esquema|diagram|schematic)\b |
      \b(?:diagrama|esquema|diagram|schematic)\b .{0,120}? \b(?:confirm\w*|verific\w*)\b
    /xi.freeze
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
    CODE_MEANING_PATTERN = /\b(?:indica|signific\w*|means|corresponde)\b/i
    FAULT_CODE_PATTERN = /\b[A-Z]{1,3}\d{2,4}\b/
    # Same-sentence attribution of a function to a visible identifier.
    # Observational mention and "does it change?" do not match.
    COMPANION_FUNCTION_ATTRIBUTION_PATTERN = /
      \bes\s+(?:el|la)\b |
      \bsirve\s+para\b |
      \bcontrola(?:n)?\b |
      \bcontrols\b |
      \bactiva(?:n)?\b |
      \bactivates?\b |
      \bentrada\s+de\b |
      \bsalida\s+de\b |
      \bfunci[oó]n\s+de\b |
      \binput\s+for\b |
      \boutput\s+for\b |
      \bcorresponds?\s+to\b
    /ix.freeze

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

    def call(answer, evidence:, require_cited_evidence: false, companion_guidance: false)
      return "" if answer.blank?

      source = evidence_text(evidence)
      if companion_guidance
        return render_internal_markers(filter_companion_fragments(answer.to_s, source))
      end
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

    # Companion answers may name an identifier present in the accepted
    # visual observation. That presence does not authorize a fault-code
    # meaning or a terminal function. Those sentences are removed. The
    # remaining guidance stays.
    def filter_companion_fragments(answer, evidence)
      fragments = self.class.fragments(answer)
      kept = []
      rejected_claim = false
      fragments.each do |fragment|
        next if fragment.match?(INTERNAL_MARKER_PATTERN)
        if companion_claim_rejected?(fragment, evidence)
          rejected_claim = true
          next
        end

        kept << fragment
      end
      return answer if kept.size == fragments.size
      return I18n.t("rag.unsupported_identifier", locale: @locale) if kept.empty? && rejected_claim
      return "" if kept.empty?

      kept.join("\n")
    end

    def companion_claim_rejected?(fragment, evidence)
      unsupported_identifiers?(fragment, evidence) ||
        unsupported_measured_value?(fragment, evidence) ||
        unsupported_code_meaning?(fragment, evidence) ||
        unsupported_visual_function?(fragment) ||
        unsupported_connection?(fragment, evidence) ||
        unsupported_led?(fragment, evidence) ||
        unsupported_device_function?(fragment, evidence)
    end

    def unsupported_identifiers?(fragment, evidence)
      ids = identifiers_in(fragment)
      return false if ids.empty?

      evidence_ids = identifiers_in(evidence).map { |identifier| canonical(identifier) }.to_set
      ids.any? { |identifier| evidence_ids.exclude?(canonical(identifier)) }
    end

    def unsupported_measured_value?(fragment, evidence)
      compact = evidence.to_s.upcase.gsub(/[[:space:]]/, "")
      fragment.to_enum(:scan, EVIDENCE_SENSITIVE_VALUE_PATTERN).any? do
        token = Regexp.last_match(0).upcase.gsub(/[[:space:]]/, "")
        compact.exclude?(token)
      end
    end

    # A code printed on the photo is visible. It is not a definition.
    def unsupported_code_meaning?(fragment, _evidence)
      return false unless fragment.match?(CODE_MEANING_PATTERN)

      fragment.match?(FAULT_CODE_PATTERN)
    end

    def unsupported_visual_function?(fragment)
      return false unless fragment.match?(COMPANION_FUNCTION_ATTRIBUTION_PATTERN)

      identifiers_in(fragment).any? || fragment.match?(FAULT_CODE_PATTERN)
    end

    def unsupported_connection?(fragment, evidence)
      return false unless fragment.match?(CONNECTION_CLAIM_PATTERN)

      identifier_pair_supported?(fragment, evidence) == false
    end

    def unsupported_led?(fragment, evidence)
      led_ids = identifiers_in(fragment).select { |identifier| led_identifier?(identifier) }
      return false if led_ids.empty? || !led_state_claim?(fragment)

      led_ids.any? do |identifier|
        evidence_fragments(evidence).none? do |piece|
          piece.match?(/\b#{Regexp.escape(identifier)}\b/i) && led_state_claim?(piece)
        end
      end
    end

    def unsupported_device_function?(fragment, evidence)
      return false unless fragment.match?(DEVICE_FUNCTION_CLAIM_PATTERN)

      evidence_fragments(evidence).none? { |piece| piece.match?(DEVICE_FUNCTION_CLAIM_PATTERN) }
    end

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

    # Two checks, in order of specificity. The identifier check owns every line
    # whose endpoints it can read, so its contract (any relationship fragment
    # naming both) is unchanged. The traced-pair check only runs where the
    # identifier check returns no verdict — the blind spot where a claim between
    # two digit-less labels used to pass unexamined.
    def reject_unsupported_connection_claims(answer, evidence)
      transform_claim_lines(answer) do |line|
        next unless line.match?(CONNECTION_CLAIM_PATTERN)

        supported = identifier_pair_supported?(line, evidence)
        supported = traced_pair_supported?(line, evidence) if supported.nil?
        next if supported.nil? || supported

        I18n.t("rag.unsupported_connection", locale: @locale)
      end
    end

    # nil when the line names no connector/component pair this check can judge.
    def identifier_pair_supported?(line, evidence)
      connectors = identifiers_in(line).reject { |identifier| led_identifier?(identifier) }
      return nil if connectors.empty?

      component_source = line.gsub(SERIES_LABEL_PATTERN, " ")
      components = component_source.scan(COMPONENT_CODE_PATTERN).reject do |code|
        COMPONENT_CODE_STOPWORDS.include?(code) ||
          board_model_name?(code) ||
          connectors.any? { |connector| canonical(connector) == canonical(code) }
      end
      return nil if components.empty?

      connectors.all? do |connector|
        components.any? do |component|
          evidence_fragments(evidence).any? do |fragment|
            relationship_fragment?(fragment) &&
              fragment.match?(/\b#{Regexp.escape(connector)}\b/i) &&
              fragment.match?(/\b#{Regexp.escape(component)}\b/i)
          end
        end
      end
    end

    # nil when the line states no readable endpoint pair — prose this check
    # cannot parse is left to the identifier check and the generation contract
    # instead of being degraded on suspicion.
    def traced_pair_supported?(line, evidence)
      pairs = wired_pairs_in(line)
      return nil if pairs.empty?

      records = traced_records(evidence)
      pairs.all? { |left, right, ordered| traced_pair?(records, left, right, ordered, line) }
    end

    # Both endpoints must be substrings of the SAME record's action line: two
    # lines each naming one of them is exactly the chain this guard exists to
    # block. An arrow claim must also keep the action line's own order, so a
    # traced edge cannot be reported inverted. A record traced by vision is a
    # weaker source than a leader-line trace, so it additionally requires the
    # answer line itself to carry the generation contract's confirmation
    # qualifier — without it the claim is indistinguishable from an unverified
    # vision read reported as settled fact.
    def traced_pair?(records, left, right, ordered, line)
      records.any? do |record|
        action = record[:action]
        left_at = action.index(left)
        right_at = action.index(right)
        next false if left_at.nil? || right_at.nil?
        next false if ordered && left_at >= right_at

        record[:derivation] != "vision" || vision_edge_qualified?(line)
      end
    end

    def vision_edge_qualified?(line)
      line.match?(VISION_SOURCE_PATTERN) && line.match?(VISION_CONFIRMATION_PATTERN)
    end

    # The endpoints of a relation are the label closest to it on each side. A
    # line may state several ("A -> B, C -> D"); each one is checked.
    def wired_pairs_in(line)
      text = line.to_s.gsub(SERIES_LABEL_PATTERN, " ").gsub(/\[\d+\]/, " ")
      pairs = []
      position = 0

      while (relation = WIRED_PAIR_RELATION_PATTERN.match(text, position))
        left = endpoint_labels(text[0...relation.begin(0)]).last
        position = relation.end(0)
        right = endpoint_labels(text[position..]).first
        next if left.nil? || right.nil? || left == right

        pairs << [ left, right, relation[0].match?(/->|→/) ]
      end

      pairs.uniq
    end

    def endpoint_labels(text)
      text.to_s.scan(ENDPOINT_LABEL_PATTERN).filter_map { |raw| endpoint_label(raw) }
    end

    # Folded to lowercase with single spaces so the substring test against an
    # action line is insensitive to case and to trailing punctuation.
    def endpoint_label(raw)
      tokens = raw.split(/\s+/).filter_map do |token|
        stripped = token.sub(/[[:punct:]]+\z/, "")
        stripped unless stripped.empty? || COMPONENT_CODE_STOPWORDS.include?(stripped)
      end
      label = tokens.join(" ").downcase
      label if label.length >= 3
    end

    def traced_records(evidence)
      cache_evidence(evidence)
      @traced_records ||= evidence.to_s.scan(RECORD_BLOCK_PATTERN).filter_map do |(block)|
        action = block[ACTION_LINE_PATTERN, 1]
        next unless action

        derivation = block[DERIVATION_LINE_PATTERN, 1]
        {
          action: action.downcase.gsub(/\s+/, " ").strip,
          derivation: derivation&.strip&.downcase
        }
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
          lines[next_index].match?(INTERNAL_MARKER_PARAGRAPH_PATTERN)
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

    public

    def render_internal_markers(answer)
      answer
        .gsub(/\bDATA_NOT_AVAILABLE\b/, I18n.t("rag.data_not_available", locale: @locale))
        .gsub(
          /\bREQUIRES?_FIELD_VERIFICATION\b/,
          I18n.t("rag.requires_field_verification", locale: @locale)
        )
    end

    private

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
      cache_evidence(evidence)
      @evidence_fragments ||= self.class.fragments(evidence)
    end

    def cache_evidence(evidence)
      return if defined?(@last_evidence) && @last_evidence == evidence

      @last_evidence = evidence
      @evidence_fragments = nil
      @traced_records = nil
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
