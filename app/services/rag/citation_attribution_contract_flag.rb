# frozen_string_literal: true

module Rag
  # Single rollback switch for both halves of the citation attribution contract:
  # Rag::CitationMarkerNormalizer (single-context [n] numbering) and
  # Rag::CitationAttributionGuard (family/model attribution of cited segments).
  # They ship together so rollback is one flip back to dd0a421 behavior.
  module CitationAttributionContractFlag
    module_function

    def enabled?
      ENV["RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED"] == "true"
    end
  end
end
