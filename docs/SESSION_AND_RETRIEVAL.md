# Session, pins, and KB retrieval (web)

Three layers: global **`kb_documents`** catalog, **`technician_documents`** audit trail, **`active_entities`** pins that scope retrieval.

**Related:** [Web home UI](WEB_HOME.md)

---

### Session-Scoped KB Retrieval & Document Memory Architecture

Three layers describe the **catalog**, an **ingestion audit trail**, and what actually **scopes Bedrock retrieval** on the web home path:

```
kb_documents         → "What exists in S3?"              (global catalog; admin + home list)
technician_documents → "Ingestion / usage audit rows"  (still written from jobs; not preloaded into pins)
active_entities      → "Pinned KB docs for this session" (UI + auto-pin after indexed upload)
```

**`kb_documents`** — Global S3 catalog. One row per uploaded S3 key. Created on upload; enriched with `display_name`, `aliases`, and `size_bytes` as the pipeline processes the file. Powers the tenant dashboard at `/dashboard` (KB document list) and the **home knowledge base list** (with optional `KbDocumentThumbnail` for images). Haiku-derived names/aliases from answers update **`kb_documents` only** via **`KbDocumentEnrichmentService`** (`RagController#ask`); that path does **not** add session pins.

> **MVP scope:** The pool is global (`account_id = nil`). Deduplication is by `canonical_name` (or `source_uri`) across all uploaders. `identifier` and `channel` are preserved for audit but do not drive uniqueness.
> **Stage 1+:** `account_id` will be added; uniqueness becomes `[account_id, canonical_name]`. Stage 2 adds `project_id`.

**`technician_documents`** — Still populated from ingestion (`BedrockIngestionJob` and related paths) for **audit / future ranking** (`interaction_count`, FIFO cap). It is **not** used to seed `active_entities` when a new `ConversationSession` is created (`preload_recent_entities` was removed).

**`conversation_sessions.active_entities`** — JSONB, capped at **`ConversationSession::MAX_ENTITIES`** (default **10**, overridable with `SESSION_MAX_ENTITIES`). **Sources of truth:** (1) user pins from the KB list (`PinnedDocumentsController` → `pin_kb_document!` / `unpin_kb_document!`), and (2) **auto-pin** when a chat upload finishes indexing (`BedrockIngestionJob#register_entity` → `pin_kb_document!`). **`SessionContextBuilder.entity_s3_uris`** turns these entries into Bedrock **`x-amz-bedrock-kb-source-uri`** filters. Session rows use **`EXPIRY_DURATION`** (default **30 days**, sliding `expires_at` on `refresh!`), not the older short TTL.

#### Data flow: upload completes → pin + catalog

```
Upload (web chat; same job shape for other channels)
  └─ S3 + kb_documents.ensure / enrich
  └─ CustomChunkingPipeline → Claude parse → bulk DS chunks (web_v1)
  └─ BedrockIngestionJob (polls until COMPLETE)
       ├─ kb_documents           ← display_name + aliases (web_v1_metadata or chunk pipeline)
       ├─ technician_documents   ← persist_to_technician_documents (audit)
       ├─ active_entities        ← pin_kb_document!(kb_doc) when session present
       └─ KbSyncBroadcaster → Turbo (indexing / retrying / indexed / failed)

Follow-up RAG (web)
  └─ retrieve_and_generate with entity filter when pins exist (force_entity_filter)
       └─ KbDocumentEnrichmentService (doc_refs) → kb_documents aliases only
```

#### Session-scoped retrieval filter logic

1. **No pinned S3 URIs** in the session → Bedrock runs against the **full** knowledge base (no source-uri metadata filter from pins).
2. **At least one pin** → web path sets **`force_entity_filter: true`** so retrieval stays on pinned URIs regardless of question shape. If the filtered call returns nothing, the response is `DATA_NOT_AVAILABLE`; forced pinned queries never retry against the global catalog.
3. **Multiple pins + explicit identity** → `Rag::PinnedEntityScopeResolver`
   narrows the allowed URI set only when there is one confident source match.
   It matches canonical names, filenames, aliases, and literal codes; understands
   negative clauses such as “no uses el esquema”; and keeps all pins for ambiguous
   semantic questions or ties.
4. `QueryOrchestratorService#entity_sources` is calculated from the narrowed URI
   subset so retrieval budgeting and photo-only safety directives describe the
   evidence actually sent to Bedrock.

#### Adaptive retrieval profile

`RagRetrievalProfile` chooses `number_of_results` from the narrowed pin types and
the current question:

| Profile | Results |
|---------|---------|
| Focused document or mixed pins | 3 |
| Stop-work, failure, or repair intent | 5 |
| Photo-only pins | 10 |
| No pins | 8 |
| Exhaustive checklist/test request | 15 |

Exhaustive queries also receive a prompt override that preserves every distinct
retrieved item even when the normal web answer target is under 300 words.
Reranking the 15 candidates to 9 or 12 caused recall regressions in the
2026-06-09 benchmark, so `BEDROCK_RERANKER_ENABLED` remains `false`.

See [RAG_QUALITY_BENCHMARK_2026-06-09.md](RAG_QUALITY_BENCHMARK_2026-06-09.md)
for the test matrix and measured tradeoffs.

| Layer | Scope (MVP) | Scope (Stage 1+) | Eviction / cap | Written by |
|---|---|---|---|---|
| `kb_documents` | Global | Global per account | — | Upload, ingestion, `KbDocumentEnrichmentService` |
| `technician_documents` | Global pool (`account_id = nil`) | Per `[account_id, project_id]` | FIFO max 20 | Ingestion (audit) |
| `active_entities` | Per session (or shared session in pilot) | Per session | `MAX_ENTITIES`; row TTL `EXPIRY_DURATION` | Pins + auto-pin on indexed upload |
