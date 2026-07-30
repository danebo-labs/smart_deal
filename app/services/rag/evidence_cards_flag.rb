# frozen_string_literal: true

module Rag
  # Server-side reader for the evidence-card rollout. The browser receives only
  # the resolved boolean and never reads ENV directly.
  module EvidenceCardsFlag
    module_function

    def enabled?
      ENV["RAG_EVIDENCE_CARDS_ENABLED"] == "true"
    end
  end
end
