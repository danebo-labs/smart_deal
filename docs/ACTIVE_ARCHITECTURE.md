# Active architecture

**Product:** signed-in **web** RAG for field elevator technicians. **WhatsApp is dormant** — see [WHATSAPP.md](WHATSAPP.md).

**Engineering contract for agents:** [AGENTS.md](../AGENTS.md) plus the nearest
scoped `AGENTS.md`.

The complete documentation map, including disabled features and historical
evidence, lives in [README.md](README.md). This file contains only the active
architecture priorities and retrieval contract.

## Canonical references

| If you need… | Read |
|--------------|------|
| **Product stage and roadmap** — MVP boundaries and next-stage triggers | [PRODUCT_ROADMAP.md](PRODUCT_ROADMAP.md) |
| Clone, run locally, essential flags | [README.md](../README.md) |
| Bedrock KB, models, env vars | [BEDROCK_SETUP.md](../BEDROCK_SETUP.md) |
| Deploy / Kamal / EC2 / RDS | [PRODUCTION.md](PRODUCTION.md) |
| Current RAG closure evidence | [GATE9R_STATUS.md](GATE9R_STATUS.md) |

## Priorities (current build)

1. Low latency on web hot paths  
2. Operational simplicity (Solid Stack, one worker container in prod)  
3. Maintainability  
4. Token efficiency  
5. Idempotent uploads and jobs  

Not active: WhatsApp-first workflows, Twilio conversational UX as primary channel.

## Current retrieval contract

- The normal web RAG lane uses Bedrock `RetrieveAndGenerate`. It keeps retrieval,
  generation, native source attribution, and Bedrock session continuity in one
  managed call.
- `citations` is the only contract for claim attribution shown to a technician.
  `retrieved_citations` is a legacy internal field used by document enrichment;
  it may contain metadata from a separate `Retrieve` fallback and must never be
  treated as proof that a generated claim was cited.
- Document identity is deterministic: `doc_refs` comes from native citation
  metadata (`canonical_name`, `aliases`, `original_source_uri`) or, when native
  citations are absent, from a bounded `Retrieve` fallback. On a compendium whose
  pages name different boards, that identity is the uploaded filename — no single
  page name may speak for the file (`document_name_consensus`).
- `RetrieveAndGenerate` declares no `stop_sequences`. `$output_format_instructions$`
  is the whole output contract; cutting generation on a custom marker broke
  Bedrock's citation format.
- That placeholder must be the LAST thing in the rendered prompt. Dynamic
  directives (language header/footer, delivery channel, safety, completeness,
  visual) are appended before it and the placeholder is re-emitted last
  (`BedrockRagService::OUTPUT_FORMAT_PLACEHOLDER`). Text emitted after it makes
  Bedrock discard the generated answer and return its canned "Sorry" refusal even
  when retrieval succeeded (verified against production, 2026-07-26).
- A canned "Sorry" answer returned while evidence WAS retrieved is a generation
  failure, and the technician reads a retryable message — never an absence that
  would imply the manual lacks the datum.
- The safety gate validates identifier, connection, and LED existence against
  native cited chunks or, when citations are absent, against those fallback
  chunks. A sensitive answer fails closed only when neither source is available.
  Fallback chunks do not become technician-visible citations.
- Direct `Retrieve` is also used as the bounded internal fallback above and by
  deterministic renderers that build explicit references from rendered chunks.
- Pins are the technician's explicit evidence scope. A pinned miss returns
  `DATA_NOT_AVAILABLE`; it does not search the global catalog.
- Multiple pins may be narrowed deterministically when the question explicitly
  names one source or excludes another. Ambiguous questions retain all pins.
- Retrieval depth is adaptive: focused document queries use a small context;
  safety-critical and exhaustive questions retrieve more evidence.
- A deterministic document-overview route resolves before
  `Rag::AmbiguousModelResponder`, when the question matches a pinned document
  and a table-of-contents manifest is available: `model_invoked: false`, zero
  Bedrock calls, `citations: []`, and document identity carried entirely by
  `doc_refs`.
- Table-of-contents manifests live under `document_manifests/`, **never**
  under `bulk_chunks/` — that is the only prefix the Bedrock data source
  indexes, so anything else placed there would leak into retrieval.
- Live technician photos are diagnostic inputs only: they still do not create
  a `KbDocument` or enter the Knowledge Base, but the original bytes and a
  thumbnail are now retained durably (bounded by `FIELD_PHOTO_RETENTION_DAYS`)
  so a technician can re-ask after the diagnosis cache expires. Their compact
  result may provide temporary conversation context for a later explicit
  manual question.
- Internal `Retrieve` calls (KB retrieval used only for excerpt/context, and
  Bedrock KB warm pings) are traced through `PilotUsageLog` structured log
  lines, not `bedrock_queries` rows: `bedrock_queries.source` is a closed
  enum, its `input_tokens` must be `> 0`, and every row drives a
  `cost_metrics` upsert plus a broadcast — none of which apply to a bare
  `Retrieve` with no generation.
- Photographic sources that deliberately pass through ingestion are indexed
  evidence and preserve only explicit visible knowledge. Labels without a
  legend remain literal identifiers with unknown function.
- Cohere reranking is implemented behind `BEDROCK_RERANKER_ENABLED`, but remains
  disabled because the 2026-06-09 quality benchmark found recall regressions.
