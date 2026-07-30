# frozen_string_literal: true

module Rag
  # Single server-side reader for the SHOW_RAG_SOURCES flag
  # (docs/RAG_RESOLUTION_MODE_CONTRACT_FASE3_2026-07-29.md §3.1).
  # RagController gates transport (citations, card.page, card.evidence_url) and
  # app/views/home/index.html.erb gates render off this same value — a single
  # expression instead of two copies that can drift.
  class SourcesVisibility
    def self.enabled?
      ENV["SHOW_RAG_SOURCES"] == "true"
    end
  end
end
