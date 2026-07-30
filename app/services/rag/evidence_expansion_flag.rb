# frozen_string_literal: true

module Rag
  # Separate rollout switch for S3 neighbor expansion. Keeping it independent
  # lets production compare selector-only and selector+expansion cohorts.
  module EvidenceExpansionFlag
    module_function

    def enabled?
      ENV["RAG_EVIDENCE_EXPANSION_ENABLED"] == "true"
    end
  end
end
