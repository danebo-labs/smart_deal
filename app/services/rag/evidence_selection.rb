# frozen_string_literal: true

module Rag
  # Return value of Rag::EvidenceCandidateSelector#select
  # (docs/RAG_EVIDENCE_SELECTOR_FASE1_DESIGN_2026-07-29.md §6, exact API).
  EvidenceSelection = Data.define(
    :mode,                # :direct | :ambiguous | :insufficient (= resolution_mode of Fase 3)
    :contexts,             # Array<EvidenceContext>, ordered by best rank, capped at MAX_CONTEXTS
    :answered_relations,   # Set<Symbol> — subset of analysis.requested_relation with evidence
    :abstained_relations,  # Set<Symbol> — requested and NOT documented (F4)
    :rejections,           # Array<Rejection> — audit trail, feeds Fase 3 telemetry
    :expansions,           # Array<Expansion> — what got expanded and which mechanism authorized it
    :selector_version      # String — versioned per Fase 3 point 3
  )

  # `breadcrumb` is derived specific -> general: [board label, section_key, canonical_name].
  EvidenceSelection::EvidenceContext = Data.define(
    :section_key, :board_key, :label, :breadcrumb,
    :document_id, :source_uri, :page_number,
    :evidence_excerpt,   # phrase from the BODY that answers the relation
    :identifiers,        # Array<Rag::QueryAnalysis::Identifier> present in the evidence
    :relations_covered,  # Set<Symbol>
    :chunk_sha256, :rank, :match_reason
  )

  EvidenceSelection::Rejection = Data.define(:chunk_sha256, :stage, :reason)

  # Not part of §6's closed Data.define list (only EvidenceContext/Rejection are
  # specified there) — shape chosen locally to satisfy §7 etapa 5's requirement
  # that every expansion record which mechanism authorized it, for telemetry.
  EvidenceSelection::Expansion = Data.define(
    :chunk_sha256, :neighbor_chunk_sha256, :mechanism, :page_number
  )
end
