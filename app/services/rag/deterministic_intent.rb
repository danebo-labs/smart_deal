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

    EXPLICIT_EQUIPMENT_PATTERN =
      /\b(?:ALTIUS|ORONA|KONE|OTIS|SCHINDLER|SOPREL|THYSSEN(?:KRUPP)?|CARLOS\s+SILVA)\b|(?:\b[A-Z]{2,}[-.]?[A-Z]?\d+[A-Z0-9.-]*\b)/i.freeze

    # Trailing punctuation/whitespace the pin autofill or the technician may add.
    OVERVIEW_TRIM_PATTERN = /[[:space:][:punct:]]+\z/.freeze

    module_function

    def exhaustive_functional_test_query?(question)
      FUNCTIONAL_TEST_PATTERNS.any? { |pattern| question.to_s.match?(pattern) }
    end

    def stop_work_checklist_query?(question)
      STOP_WORK_PATTERNS.any? { |pattern| question.to_s.match?(pattern) }
    end

    def ambiguous_hardware_query?(question)
      text = question.to_s
      GENERIC_HARDWARE_PATTERNS.any? { |pattern| text.match?(pattern) } &&
        !text.match?(EXPLICIT_EQUIPMENT_PATTERN)
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
