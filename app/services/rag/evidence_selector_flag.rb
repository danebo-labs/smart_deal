# frozen_string_literal: true

module Rag
  # Single reader for the "selector de evidencia" feature flag
  # (docs/RAG_PRECISION_V2_PLAN_2026-07-29.md §7). Off by default — shadow-mode
  # only (RagController runs Rag::EvidenceCandidateSelector alongside the live
  # path without letting it change the response) until Fase 3 switches
  # `resolution.mode` on per route.
  class EvidenceSelectorFlag
    def self.enabled?
      ENV["RAG_EVIDENCE_SELECTOR_ENABLED"] == "true"
    end
  end
end
