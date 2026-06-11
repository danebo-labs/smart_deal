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

    module_function

    def exhaustive_functional_test_query?(question)
      FUNCTIONAL_TEST_PATTERNS.any? { |pattern| question.to_s.match?(pattern) }
    end

    def stop_work_checklist_query?(question)
      STOP_WORK_PATTERNS.any? { |pattern| question.to_s.match?(pattern) }
    end
  end
end
