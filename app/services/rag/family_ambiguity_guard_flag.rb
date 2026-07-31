# frozen_string_literal: true

module Rag
  # Rollback switch for the evidence-level cross-family ambiguity guard:
  # Rag::FamilyAmbiguityDetector plus the per-board generation window and the
  # multi-family directive it enables in Rag::StructuredEvidenceRoute. Off means
  # the structured route selects and prompts exactly as it did before the guard.
  module FamilyAmbiguityGuardFlag
    module_function

    def enabled?
      ENV["RAG_FAMILY_AMBIGUITY_GUARD_ENABLED"] == "true"
    end
  end
end
