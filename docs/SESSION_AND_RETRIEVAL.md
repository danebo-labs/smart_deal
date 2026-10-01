# Session, pins, and KB retrieval (web)

Three account-scoped layers: **`kb_documents`** catalog,
**`technician_documents`** audit trail, and **`active_entities`** pins that scope
retrieval.

**Related:** [Web home UI](WEB_HOME.md). Knowledge model:
[PRODUCT_ROADMAP.md](PRODUCT_ROADMAP.md#knowledge-model-29-sep-2026).

### Knowledge scopes

Two scopes, and no synonyms:

- `tenant_private` — the tenant's own manuals. `UNCLASSIFIED` behaves as this
  scope. Default deny.
- `danebo_general` — a document Danebo has explicitly approved for shared
  use. Shared means eligibility and visibility, not a shared focus. One
  physical `KbDocument`, one index. Authorized tenants can list it and
  retrieve it. A pin is `user_pin` on that session's `active_entities` only.
  Account A pinning it does not change Account B's catalog or pins. Each
  session may pin a different general document, several of them, or mix them
  with its own `tenant_private` documents, and may clear those pins.

Account id, filename, manufacturer, folder, the Legacy or Pilot slug, and
`manual_corpus=general` do not grant `danebo_general`. Open retrieval is the
viewer's own documents plus rows whose `knowledge_scope` is `danebo_general`.
`BedrockRagService#account_filter` builds that set from the database. The
home list still shows `current_account.kb_documents`. A pin of a foreign
`danebo_general` row uses the existing `KbDocument` and does not copy it.

---

### Session-Scoped KB Retrieval & Document Memory Architecture

Three layers describe the **catalog**, an **ingestion audit trail**, and what actually **scopes Bedrock retrieval** on the web home path:

```
kb_documents         → "What exists in S3?"              (account catalog; home list)
technician_documents → "Ingestion / usage audit rows"  (still written from jobs; not preloaded into pins)
active_entities      → "Pins for the current case" (stored on the workspace row)
```

**`kb_documents`** — Account-scoped S3 catalog. One row per account and S3
key. Created on upload; enriched with `display_name`, `aliases`, and `size_bytes`
as the pipeline processes the file. It powers the home knowledge-base list
(with optional `KbDocumentThumbnail` for images). Haiku-derived names/aliases
from answers update **`kb_documents` only** via
**`KbDocumentEnrichmentService`** (`RagController#ask`); that path does **not**
add session pins.

> **MVP scope:** `account_id` is mandatory on `KbDocument`,
> `TechnicianDocument`, and `ConversationSession`. Per-project or per-asset
> organization is not part of the current product.

**`technician_documents`** — Still populated from ingestion (`BedrockIngestionJob` and related paths) for **audit / future ranking** (`interaction_count`, FIFO cap). It is **not** used to seed `active_entities` when a new `ConversationSession` is created (`preload_recent_entities` was removed).

**`conversation_sessions.active_entities`** — JSONB, capped at **`ConversationSession::MAX_ENTITIES`** (default **10**, overridable with `SESSION_MAX_ENTITIES`). The hash is where pins are stored. The pin contract is the current case, described below. **Sources of truth:** (1) user pins from the KB list or from a suggestion-card tap (`PinnedDocumentsController` → `pin_kb_document!` / `unpin_kb_document!`), and (2) **auto-pin** when indexing finishes and episode ownership matches. A suggestion does not pin until the technician taps. The tap checks the exact row again and writes `user_pin` only on that workspace row. **`SessionContextBuilder.entity_s3_uris`** turns these entries into Bedrock **`x-amz-bedrock-kb-source-uri`** filters. It reads `active_entities`. It does not read `active_episode`.

### Workspace and case

`ConversationSession` is the persistent workspace. It is not a case and it is not a thread. One row per `(account_id, identifier, channel)`. On the web, `identifier` is the user id. The row uses a sliding TTL of **30 days** (`EXPIRY_DURATION`, refreshed on a turn). Login and logout do not write the row and are not a case boundary.

A **case** is the current `ActiveEpisode`: an `episode_id` whose stored `updated_at` is inside `ConversationSession::EPISODE_WINDOW` (**4 hours**). Several cases follow one another on the same row. `conversation_history` and `FieldPhoto` rows stay on the workspace. Prompt readers (`recent_user_turns`, `episode_user_messages`, `last_assistant_message`, `FollowupQueryRewriter#episode_rows`) use `max(now - 4 hours, episode.opened_at)` once a case is live. That floor does not replace writer ownership.

The request that opens a case, crosses expiry, corrects the manufacturer, or replaces an invalid stored episode persists that cleanup before `SessionContextBuilder.entity_s3_uris` is read. The old URI is not sent on that request.

### Pins

Pins are case state. They remain physically in `active_entities`. There is no `episode_id` on the pin and no extra column.

- Same case: the pin stays, including across a retrieve miss. A miss does not reopen the unpinned corpus and does not drop the pin.
- `:new_episode` while the stored case is still live: pins from the previous case are cleared.
- Expiry (`ActiveEpisode.parse` reason `expired` on the stored JSON): pins that belong to the expired case are cleared. A pin is cleared when `added_at` is missing, unparseable, or `added_at <= updated_at + EPISODE_WINDOW`. A pin strictly after that cutoff stays. This does not depend on the turn decision being `:opened`.
- Invalid stored episode (`reason == "invalid_state"`): every case-scoped pin is cleared. There is no time cutoff. A normal blank episode (`active_episode == {}`) does not clear an explicit pin.
- Explicit re-pin, including a suggestion card that still answers `already_focused`, renews `added_at`.
- Manufacturer correction stays on the same `episode_id` and removes only a pin whose labels contain the old manufacturer as a whole word and contain none of the new. Pins that name neither, or both, stay. A model-only correction does not use this release.

`current_procedure` is cleared on a case boundary, on expiry, and on `invalid_state`. It stays on a blank episode's first turn.

### Late writers

`expected_episode_id` is the ownership guard when episode recording is on: `FIELD_COMPANION_EPISODE_ENABLED=true`, channel `web`, and not a shared session. It is captured when the work starts. A photo with no live case opens and persists its case before the analysis job is enqueued, and that id is the owner. Inside the session lock, a later assistant reply, photo observation, or auto-pin writes only when that id is still the live case. For an assistant reply, a blank expected id matches a blank live id. A photo observation requires a present id. A mismatch does not change episode state, pending, facts, identifiers, conflicts, `active_photo`, `current_procedure`, pins, or `conversation_history`. Telemetry and `correlation_id` continue. The drop is `stale_case_write_dropped`. With the episode flag off, the assistant path writes history without that check, and the photo case opener does not run.

### Auto-pin

With `FIELD_COMPANION_EPISODE_ENABLED` off, indexing still pins as before.

With the flag on, auto-pin runs only when the submission captured an `expected_episode_id` and that id still matches the live case under the lock. A long manual rehydrated from `WebManualBatch` has no durable episode owner, so it does not auto-pin. The document stays indexed, visible, and available for a manual pin. Ownership is not inferred from `KbDocument.created_at`, `WebManualBatch.created_at`, `submitted_at`, or other late timestamps.

#### Data flow: upload completes → pin + catalog

```
Upload (web chat; same job shape for other channels)
  └─ S3 + kb_documents.ensure / enrich
  └─ CustomChunkingPipeline → Claude parse → bulk DS chunks (web_v1)
  └─ BedrockIngestionJob (polls until COMPLETE)
       ├─ kb_documents           ← display_name + aliases (web_v1_metadata or chunk pipeline)
       ├─ technician_documents   ← persist_to_technician_documents (audit)
       ├─ active_entities        ← auto-pin only with a matching episode owner when the episode flag is on; legacy pin when it is off
       └─ KbSyncBroadcaster → Turbo (indexing / retrying / indexed / failed)

Follow-up RAG (web)
  └─ retrieve_and_generate with entity filter when pins exist (force_entity_filter)
       └─ KbDocumentEnrichmentService (doc_refs) → kb_documents aliases only
```

Live technician-photo diagnosis is intentionally outside this ingestion flow.
It does not create a `KbDocument`, does not auto-pin, and does not become a
Knowledge Base source. Its compact `[FOTO]` result may remain in conversation
history so a technician can make a later, explicit query against indexed
manuals. Persistent conversations and diagnostic records belong to the next
product stage; see [PRODUCT_ROADMAP.md](PRODUCT_ROADMAP.md).

#### Session-scoped retrieval filter logic

1. **No pinned S3 URIs** in the session → Bedrock runs with `account_filter`
   only: the session account, plus canonical URIs of foreign `danebo_general`
   rows. There is no source-uri filter from pins. Legacy, Pilot, and
   `manual_corpus=general` are not clauses.
2. **At least one pin** → web path sets **`force_entity_filter: true`** so retrieval stays on that case's pinned URIs regardless of question shape. If the filtered call returns nothing, the response is `DATA_NOT_AVAILABLE`. The miss does not reopen the unpinned corpus for this case, and it does not change `danebo_general` or any other workspace's pins. The user can still add, remove, or replace those pins. The system does not drop them because the retrieve was empty. Widening the corpus inside the case requires an explicit user action. A new case, an expired stored episode, or an invalid stored episode releases pins by the case rules above, before this filter is built.
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

#### Pin-triggered document overview warm-up

Pinning a document (`PinnedDocumentsController#create`) now also enqueues
**`DocumentOverviewWarmJob`**, which precomputes and caches the document's
table-of-contents summary via `Rag::DocumentOverviewBuilder` so the first
real question does not pay a cold S3/manifest lookup. This is a single
`perform_later` call — no extra synchronous work on the pin request.

When a session has 1-4 `source: "user_pin"` entities (`MAX_OVERVIEW_DOCUMENTS`,
most recent kept) and the question is blank, the auto-completed
model-selection query, or otherwise resolves as a document overview request
per `Rag::DeterministicIntent.document_overview_query?` (a single name or a
concatenation of the pinned names/aliases), `QueryOrchestratorService`
resolves it as a deterministic table-of-contents summary — one
`Documento: %{name}` block per pinned document with an available overview
(see [QUERY_ORCHESTRATOR.md](QUERY_ORCHESTRATOR.md)) — instead of falling
through to `Rag::AmbiguousModelResponder`'s multi-model disambiguation.
Entities auto-extracted from citations (not checkbox-pinned) are never
included, even if their name matches the question.

| Layer | Current scope | Eviction / cap | Written by |
|---|---|---|---|
| `kb_documents` | Per account | — | Upload, ingestion, `KbDocumentEnrichmentService` |
| `technician_documents` | Per account | FIFO max 20 | Ingestion (audit) |
| `active_entities` | Case state on the workspace row. A shared demo session is one workspace row, not a pin stored on the document | `MAX_ENTITIES`. The workspace row TTL is 30 days. Pins follow the case, not that TTL | User pin, re-pin, and auto-pin when episode ownership matches |

A pin, including a future pin of a `danebo_general` document, is written only on that session. It is not a column on `kb_documents`. Account A pinning a general document does not change Account B's catalog or Account B's pins. Each session may pin a different general document, several of them, or mix them with its own private documents, and may clear those pins.
