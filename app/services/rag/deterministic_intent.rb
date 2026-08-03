# frozen_string_literal: true

module Rag
  # Narrow intent classifiers for the deterministic answer paths (benchmark
  # plan Fase 7). Deliberately MUCH narrower than RagRetrievalProfile's
  # exhaustive/safety-critical patterns: only a question that asks for the
  # complete functional-test list WITH expected results, or for a pre-operation
  # checklist WITH stop-work conditions, qualifies. Failure/repair questions
  # ("si una prueba falla, ¿quién repara?") stay on the generative path.
  module DeterministicIntent
    FUNCTIONAL_TEST_PATTERNS = [
      /\bpruebas\s+(?:funcionales|de\s+funcionamiento)\b.*\bresultados?\b/im,
      /\bfunctional\s+tests?\b.*\b(?:expected\s+)?results?\b/im
    ].freeze

    STOP_WORK_PATTERNS = [
      /\b(?:comprobaciones|verificaciones)\b.*\bdetener\s+el\s+trabajo\b/im,
      /\bchecks\b.*\bstop\s+work(?:ing)?\b/im
    ].freeze

    GENERIC_HARDWARE_PATTERNS = [
      /\b(?:leds?|cerrojos?|enclavamientos?|contactos?|seguridades?)\b/i,
      /\b(?:locks?|interlocks?|safety\s+contacts?)\b/i
    ].freeze

    # `ARCA`/`ARCA II`/`ARCA III`/`ARCA BASICO` are model names with no digit
    # glued to a letter, so the alphanumeric-code branch below never matches
    # them (ciclo 3 Fase 1, N7). `J\d{1,2}` escapes the bypass-jumper
    # designators (J1-J50) shared across the ALTIUS/ZEUS/ARCA board family
    # (chunks 5, 46, 60, 61, 62, 63 — grep of the 97 bodies, ciclo 3 Fase 2).
    # Deliberately scoped to the letter "J": other single letters (e.g. "K" in
    # "EDEL K2"/"EDEL K3") label unrelated things and must stay unrecognized —
    # widening this to any single letter + digit is the larger P4 migration in
    # regex_characterization_test.rb (huecos 4-5), not this fix.
    EXPLICIT_EQUIPMENT_PATTERN =
      /\b(?:ALTIUS|ARCA(?:\s+(?:BASICO|II|III))?|ORONA|KONE|OTIS|SCHINDLER|SOPREL|THYSSEN(?:KRUPP)?|CARLOS\s+SILVA)\b|\bJ\d{1,2}\b|(?:\b[A-Z]{2,}[-.]?[A-Z]?\d+[A-Z0-9.-]*\b)/i.freeze

    # A technician who already names a page number has disambiguated by
    # location, whatever the label on that page looks like — no manufacturer
    # or model code needs to appear in the question at all.
    PAGE_REFERENCE_PATTERN = /\bp[áa]gina\s+\d+\b|\bp[áa]g\.?\s*\d+\b|\bpage\s+\d+\b/i.freeze

    # Trailing punctuation/whitespace the pin autofill or the technician may add.
    OVERVIEW_TRIM_PATTERN = /[[:space:][:punct:]]+\z/.freeze

    module_function

    def exhaustive_functional_test_query?(question)
      FUNCTIONAL_TEST_PATTERNS.any? { |pattern| question.to_s.match?(pattern) }
    end

    def stop_work_checklist_query?(question)
      STOP_WORK_PATTERNS.any? { |pattern| question.to_s.match?(pattern) }
    end

    # True when the text already carries the quick-reply marker the responder
    # appends (`rag.model_selection_query`). Checked in every locale because the
    # reply is echoed back verbatim and I18n.locale here is not guaranteed to
    # match the one that rendered it. Computed lazily — building this at class
    # load would freeze the translations at boot.
    def model_selection_reply?(text)
      I18n.available_locales.any? do |locale|
        marker = I18n.t("rag.model_selection_query", locale: locale, model: "", default: "").strip
        marker.present? && text.include?(marker)
      end
    end

    def ambiguous_hardware_query?(question)
      text = question.to_s
      # Already disambiguated once — never ask again, whatever the label looks
      # like. Labels without a digit glued to letters ("NE 300 – LB II",
      # "LIMITADOR-CABINA") do not satisfy EXPLICIT_EQUIPMENT_PATTERN and used
      # to loop forever.
      return false if model_selection_reply?(text)

      GENERIC_HARDWARE_PATTERNS.any? { |pattern| text.match?(pattern) } &&
        !text.match?(EXPLICIT_EQUIPMENT_PATTERN) &&
        !text.match?(PAGE_REFERENCE_PATTERN)
    end

    # True when the technician pinned exactly one document and did not write a
    # real question: the textarea is empty or holds only the autofilled document
    # name (rag_chat_controller#_updateTextareaWithDocName).
    # @param question [String, nil]
    # @param pinned_names [Array<String>] canonical_name + aliases of the single pin
    # @return [Boolean]
    def document_overview_query?(question, pinned_names)
      names = Array(pinned_names).map { |n| normalize_overview_text(n) }.compact_blank
      return false if names.empty?

      text = normalize_overview_text(question)
      return true if text.blank?
      return true if names.include?(text)

      remainder = names.sort_by { |name| -name.length }.reduce(text) { |acc, name| acc.sub(name, "") }
      remainder = remainder.gsub(/[[:punct:]]/, " ").squish

      remainder.blank?
    end

    def normalize_overview_text(value)
      I18n.transliterate(value.to_s).downcase.squish.sub(OVERVIEW_TRIM_PATTERN, "")
    end
  end
end
