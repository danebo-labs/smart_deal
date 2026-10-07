# Session, pins, and KB retrieval (web)

Three account-scoped layers: **`kb_documents`** catalog,
**`technician_documents`** audit trail, and the session focus that scopes
retrieval. On the web that focus is **`document_focus`**. WhatsApp still
uses **`active_entities`**.

**Related:** [Web home UI](WEB_HOME.md). Catalog and pin vocabulary:
[PRODUCT_ROADMAP.md](PRODUCT_ROADMAP.md#knowledge-model-29-sep-2026).
Unpinned retrieval: [Shared corpus](#shared-corpus-current-contract).

### Knowledge scopes

Two scopes, and no synonyms:

- `tenant_private` — the tenant's own manuals. `UNCLASSIFIED` behaves as this
  scope. Default deny.
- `danebo_general` — a document Danebo has explicitly approved for shared
  use. Shared means eligibility and visibility, not a shared focus. One
  physical `KbDocument`, one index. Authorized tenants can list it and
  retrieve it. A pin is `user_pin` on that session's focus only. On the
  web the column is `document_focus`. WhatsApp still uses `active_entities`.
  Account A pinning it does not change Account B's catalog or pins. Each
  session may pin a different general document, several of them, or mix them
  with its own `tenant_private` documents, and may clear those pins.

Account id, filename, manufacturer, folder, the Legacy or Pilot slug, and
`manual_corpus=general` do not grant `danebo_general`. That scope still
governs catalog listing, suggestions, and whether another account may pin
the row. It is not the unpinned retrieve filter. The home list still shows
`current_account.kb_documents`. A pin of a foreign `danebo_general` row uses
the existing `KbDocument` and does not copy it.

## Shared corpus (current contract)

This section is the contract for unpinned retrieval. Other documents link
here instead of restating the filter.

The founder confirmed the product intent on 2026-10-07: Danebo keeps an
intentional shared corpus that comes from the accounts `danebo-legacy` and
`danebo-pilot-elevator`. Without a pin, a technician searches their
authorized knowledge and that shared corpus. Sharing knowledge does not
share pins and does not confirm that a manual applies to the equipment on
the job.

The last functional change is `3d07feb` (2026-09-30), on top of `66f0d16`.
`66f0d16` restored the pre-F3B2 shared-account filter. `3d07feb` drops a
chunk without a readable `account_id` and stops publishing a new manual
only because the uploader's slug is one of those two. `Rag::SharedManualCorpus`
resolves the accounts by slug. A numeric id is not part of the contract.

Without a pin, `BedrockRagService#account_filter` is an `orAll` of:

- the viewer's `account_id`;
- each other shared-corpus account as `account_id` AND
  `ingestion_path != field_photo_v1` AND `manual_corpus != account`;
- `manual_corpus=general`.

The technician's account always enters that OR. Other ordinary accounts are not added by the shared-corpus rule.
`KnowledgeScopePolicy.open_corpus` is not this filter. Retrieve does not
call it.

The publication gate mirrors the filter. `viewer_account` means the chunk's
`account_id` is the viewer: the viewer may read it. It does not mean the
manual matches the equipment. `shared_corpus` means a historical chunk of
one of those two accounts. A chunk with no readable metadata is dropped. A
photo of the other shared account is dropped. The viewer's own photo is
kept. Chunk `document_id` is not compared with `KbDocument.document_uid`.

What the open filter includes:

- Historical manuals of those two accounts indexed without `manual_corpus`,
  or with a value other than `account`. Bedrock `notEquals` matches a
  missing key.
- Chunks explicitly tagged `manual_corpus=general`.

What living on those accounts does not publish:

- A new manual writes `manual_corpus=account` unless the ingest passes
  `corpus_scope: "general"` and `accounts.danebo_controlled` is true.
  The slug is not that mark and is not `danebo_general`.
- A field photo (`ingestion_path=field_photo_v1`) never receives
  `manual_corpus`. Another account's photos stay out.
- Another tenant's private manuals stay out.

With a pin, the filter is those URIs alone. The whole set must pass
`KnowledgeScopePolicy`, or the call is `DENY_RETRIEVAL` and does not fall
through to the open corpus. On the web the selection is
`conversation_sessions.document_focus`. WhatsApp still uses
`active_entities`. A question that names a manual does not write the focus.
One account's pin does not change another account's catalog or focus. A
case boundary does not clear `document_focus`.

Pending decision, not an approval: the founder describes the shared corpus
as coming from those two accounts. The code does not put every new upload
on those accounts into the open filter. A new manual stays
`manual_corpus=account` until an explicit `corpus_scope: "general"` on an
account with `danebo_controlled`. Whether a future upload on those slugs
should enter the shared corpus without that mark is undecided.

Account correspondence:

- Local development, read on 2026-10-07: `danebo-legacy` is id 4 and
  `danebo_controlled` is false. `danebo-pilot-elevator` is not in that
  database.
- Production ids were not re-read for this alignment. Notes that name
  account 1 or 3 are observations from those dates, not this contract.

---

### Session-Scoped KB Retrieval & Document Memory Architecture

Three layers describe the **catalog**, an **ingestion audit trail**, and what actually **scopes Bedrock retrieval** on the web home path:

```
kb_documents         → "What exists in S3?"              (account catalog; home list)
technician_documents → "Ingestion / usage audit rows"  (still written from jobs; not preloaded into pins)
document_focus       → "Web pins for this session" (workspace row; not the case)
active_entities      → "WhatsApp pins" (workspace row)
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

**`conversation_sessions.document_focus`** — JSONB array, capped at **`ConversationSession::MAX_ENTITIES`** (default **10**, overridable with `SESSION_MAX_ENTITIES`). This is the web pin store. **`active_entities`** remains the WhatsApp store. **Sources of truth:** (1) user pins from the KB list or from a suggestion-card tap (`PinnedDocumentsController` → `pin_kb_document!` / `unpin_kb_document!`), and (2) **auto-pin** when indexing finishes and episode ownership matches. A suggestion does not pin until the technician taps. The tap checks the exact row again and writes `user_pin` only on that workspace row. **`SessionContextBuilder.entity_s3_uris`** turns the session focus into Bedrock **`x-amz-bedrock-kb-source-uri`** filters. On the web it reads `document_focus`. On WhatsApp it reads `active_entities`. It does not read `active_episode`.

### Workspace and case

`ConversationSession` is the persistent workspace. It is not a case and it is not a thread. One row per `(account_id, identifier, channel)`. On the web, `identifier` is the user id. The row uses a sliding TTL of **30 days** (`EXPIRY_DURATION`, refreshed on a turn). Login and logout do not write the row and are not a case boundary.

A **case** is the current `ActiveEpisode`: an `episode_id` whose stored `updated_at` is inside `ConversationSession::EPISODE_WINDOW` (**4 hours**). Several cases follow one another on the same row. `conversation_history` and `FieldPhoto` rows stay on the workspace. Prompt readers (`recent_user_turns`, `episode_user_messages`, `last_assistant_message`, `FollowupQueryRewriter#episode_rows`) use `max(now - 4 hours, episode.opened_at)` once a case is live. That floor does not replace writer ownership.

The request that opens a case, crosses expiry, corrects the manufacturer, or replaces an invalid stored episode persists that case cleanup before `SessionContextBuilder.entity_s3_uris` is read. That cleanup does not remove the web focus. The URIs already in `document_focus` are the ones sent on that request.

### Pins

On the web, the session focus is `document_focus`. WhatsApp still stores pins in `active_entities`. A pin is that session's selected documents. A retrieve miss does not drop it and does not reopen the unpinned corpus for that session. A case boundary clears `current_procedure` and does not clear `document_focus`. Naming a manual in the question does not write the focus. The filter rules are in [Shared corpus](#shared-corpus-current-contract).

Earlier notes that a new case, expiry, or an invalid episode released pins described `active_entities` before the web focus moved to `document_focus` (`8c28284`, `89972d1`). They are not the web retrieve scope.

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
       ├─ document_focus         ← web auto-pin only with a matching episode owner when the episode flag is on; legacy pin when it is off
       ├─ active_entities        ← WhatsApp pin store
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
   only. That filter is the [shared corpus](#shared-corpus-current-contract),
   not a list of `danebo_general` URIs. There is no source-uri filter from
   the focus.
2. **At least one pin** → web path sets **`force_entity_filter: true`** so retrieval stays on that case's pinned URIs regardless of question shape. If the filtered call returns nothing, the response is `DATA_NOT_AVAILABLE`. The miss does not reopen the unpinned corpus for this case, and it does not change `danebo_general` or any other workspace's pins. The user can still add, remove, or replace those pins. The system does not drop them because the retrieve was empty. Widening the corpus inside the case requires an explicit user action. A new case, an expired stored episode, or an invalid stored episode does not release `document_focus`. The filter is still those URIs.
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
| `document_focus` (web) / `active_entities` (WhatsApp) | Session focus on the workspace row. A shared demo session is one workspace row, not a pin stored on the document. A case boundary does not clear `document_focus` | `MAX_ENTITIES`. The workspace row TTL is 30 days | User pin, re-pin, and auto-pin when episode ownership matches |

A pin, including a future pin of a `danebo_general` document, is written only on that session. It is not a column on `kb_documents`. Account A pinning a general document does not change Account B's catalog or Account B's pins. Each session may pin a different general document, several of them, or mix them with its own private documents, and may clear those pins.
