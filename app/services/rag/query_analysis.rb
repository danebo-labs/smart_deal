# frozen_string_literal: true

module Rag
  # Value object built by Rag::QueryEntities (docs/RAG_EVIDENCE_SELECTOR_FASE1_DESIGN_2026-07-29.md
  # §2 and the Fase 0.5 audit §5.1). One value object, one constructor
  # (Rag::QueryEntities.analyze) — nothing else builds or mutates this.
  #
  # requested_relation is a Set<Symbol>, not a scalar (design §1 F4): some questions
  # request two relations at once (e.g. attribution + state) and the PDF documents
  # only one, so each relation must be answered or abstained independently.
  # `question` is a correction to the Fase 1 design (docs/RAG_EVIDENCE_SELECTOR_
  # FASE1_DESIGN_2026-07-29.md §6): Rag::EvidenceCandidateSelector receives only
  # `analysis:`, but etapa 3's inverse-mode gate needs the raw question text to
  # find the "función" the technician described (e.g. "puertas cabina/exterior
  # cerradas") — a signal no other QueryAnalysis field carries. Kept alongside
  # the parsed fields rather than threaded as a second selector argument, so the
  # closed §6 API (`analysis:, chunks:, expander:`) stays unchanged.
  QueryAnalysis = Data.define(
    :intents,
    :manufacturer,
    :model,
    :board,
    :identifiers,
    :requested_relation,
    :confidence,
    :question
  )

  # raw       "SPM" | "37" | "CN-112.SC"
  # canonical "SPM" | "37" | "CN112SC"   (upcase, separators removed)
  # shape     :alpha | :numeric | :alnum | :connector
  # position  :labelled | :bare — :labelled means preceded by a label term
  #           (LED/serie/borne/terminal/conector/placa/pin) or inside an enumeration
  #           headed by one. A bare numeric token never counts as an identifier.
  QueryAnalysis::Identifier = Data.define(:raw, :canonical, :shape, :position)

  # Equipment identity is a hypothesis, never a fact (design §5.2 Regla 1).
  QueryAnalysis::Hypothesis = Data.define(:value, :source, :confidence)
end
