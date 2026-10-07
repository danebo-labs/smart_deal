# RAG Service Rules

## Retrieval First

* Retrieved knowledge is the source of truth.
* Prefer retrieved evidence over model assumptions.
* Prefer structured business data when it directly answers the question.
* Preserve document identity and evidence references.
* Parse document reference protocols; do not infer document identity.

## Cost And Latency

* Prefer simple retrieval paths.
* Minimize retrieval payload size.
* Use metadata filtering before semantic expansion.
* Avoid unnecessary reranking or multi-stage orchestration.
* Avoid repeated retrieval calls within the same user turn.
* Reuse existing session context when available.

## Manual corpus scope

Narrative contract:
[docs/SESSION_AND_RETRIEVAL.md](../../../docs/SESSION_AND_RETRIEVAL.md#shared-corpus-current-contract).
The rules below are the implementation.

Product contract: a tenant may use its own `tenant_private` documents and
documents whose `kb_documents.knowledge_scope` is `danebo_general`.
`KbDocument::KNOWLEDGE_SCOPE_*` is the vocabulary. `Rag::KnowledgeScopePolicy`
is the read authority. `KnowledgeScopeChange.apply!` is the only writer of
that column, and it appends `knowledge_scope_changes`. The audit rows do not
grant access. `accounts.danebo_controlled` is the explicit source-account
mark required before a row can become `danebo_general`. Slug, branded,
filename, manufacturer, `manual_corpus=general`, and Legacy/Pilot membership
do not set that mark and do not authorize a pin. Every existing row defaults
to `tenant_private`. Open retrieval is the compatibility filter in the next
section: it is not this pin rule.

F3 suggestion eligibility and a pin URI both go through the policy before
they become a card or a retrieval filter. A caller-supplied URI is not
authorization. The requested set is authorized together: one denied or
ambiguous URI is `DENY_RETRIEVAL`. That result does not call Bedrock, does
not retry the open corpus, and does not fall through to `account_filter`.
The session pins stay until the technician removes them. `document_uid` and
`s3_key` are unique per account, not globally. A catalog entry binds to the
physical row only when canonical bucket plus object key and `document_uid`
agree on exactly one authorized row. Two rows with the same canonical
identity deny. A different bucket is a different object.
Do not copy a document or reindex it per tenant to make a pin work. A pin
is session focus, not a property of the shared document. Account A pinning
a `danebo_general` document does not change Account B's catalog or Account
B's pins. Promotion requires a completed non-photo ingestion ledger with
`chunks_s3_prefix`. A `KbDocument` with no ledger is not indexed. Photos
are rejected by `KnowledgeScopeEligibility`. `knowledge_scope_changes` is
append-only in the application: `apply!` inserts, and update or delete
through the model is rejected. Direct SQL is outside this phase.

Open retrieval is the pre-F3B2 compatibility filter, not the `danebo_general` URI list. Without a pin, `BedrockRagService#account_filter` is an `orAll` of the viewer's `account_id`, each other `Rag::SharedManualCorpus` account as `account_id` AND `ingestion_path != field_photo_v1` AND `manual_corpus != account`, and `manual_corpus=general`. The technician's account always enters that OR. Other ordinary accounts are not added by the shared-corpus rule. `knowledge_scope` does not add or remove a clause. `BatchResultsParserService#sidecar_metadata` writes `manual_corpus` through `Rag::SharedManualCorpus.chunk_attribute`.

`KnowledgeScopePolicy.open_corpus` and its 100-URI budget remain on the policy. Open retrieval does not call them. Bedrock's published limits stay one embedded logical operator, five clauses, and depth 2.

Chunks that come back are kept when `account_id` is present and is the viewer, when `account_id` is a shared-corpus account and the chunk is not a photo and is not `manual_corpus=account`, or when `manual_corpus=general` and `account_id` is present. Missing, blank, or unreadable metadata is dropped. A photo of the other shared account is dropped. The viewer's own photo is kept. `document_id` is not compared with `KbDocument.document_uid`. `partition_evidence` is not on this path. If every citation from `retrieve_and_generate` fails that check, the generated text is not published. There is no second model call.

`R1A_PROBE` (`Rag::R1aRetrievalProbe`) is a temporary diagnostic log. It records the filter and each chunk decision already computed by the gate. It does not change retrieval. Remove it after the R1A production smoke. That temporary mode is documented in [docs/PILOT_TRACEABILITY.md](../../../docs/PILOT_TRACEABILITY.md).

A new manual writes `manual_corpus=account`. The shared-account arm excludes that value. Chunks already indexed without the key still match, because Bedrock `notEquals` matches a missing key. `corpus_scope: "general"` writes `manual_corpus=general` only when `accounts.danebo_controlled` is true. The Legacy/Pilot slug is not that mark.

A caller filter may narrow the open corpus. `account_id` of another tenant, `account_id` inside `orAll`, and a caller-supplied `manual_corpus` deny the request (`caller_filter_widens_scope`). A technical predicate is ANDed with the flat `account_scope_clause`, photo exclusion, and `manual_corpus != account`, not with `account_filter`, so the nested shared-account `andAll` stays at depth 2. That `notEquals` also hides the viewer's own `manual_corpus=account` chunks on the technical path. The open filter does not: the viewer's arm is plain `account_id`. A URI filter is still the pin path: the whole set is authorized by `KnowledgeScopePolicy`, or the call is `DENY_RETRIEVAL`.

An unforced pin retry that drops the URI filter returns to this open corpus, including Legacy, Pilot, and `manual_corpus`. Revoking `danebo_general` does not remove the shared-account clause. A pin of a foreign `tenant_private` row stays `DENY_RETRIEVAL`. Other sessions' pins are not deleted.

`WarmBedrockKbJob` is an Aurora ping. It calls `Retrieve` directly, discards the response, and does not serve a tenant. WhatsApp is dormant. A dormant caller of `BedrockRagService#query` uses this same filter and the same `DENY_RETRIEVAL`.

A question does not pin a manual or a page, and neither does a suggestion card. The technician's tap on that card reauthorizes the exact `KbDocument` row (`kb_document_id`, confirmed by `document_uid`) and writes `user_pin` on the current session only. The browser does not send `knowledge_scope`. A pin conflict or an identity conflict is shown and does not remove the pin or replace the technician's fact. A mentioned page never narrows retrieval. A document the technician pinned is the whole scope of that session's retrieve. The filter is those URIs alone. The technician can change the pins. An empty result does not silently drop them.

Do not wrap `account_filter` in another `andAll`. Its shared-account arm is already an `andAll`. A technical caller filter uses `account_scope_clause` instead.

## Safety

* Never invent procedures, measurements, tolerances, or safety instructions.
* Surface uncertainty explicitly.
* Missing data must return `DATA_NOT_AVAILABLE`.
* Ambiguous data must return `REQUIRE_FIELD_VERIFICATION`.
* Known equipment with no compatible manual continues as Danebo guidance
  from the accepted visual observation and the active problem. That turn
  does not teach a foreign procedure and does not end as `DATA_NOT_AVAILABLE`.

## Chunk Repair Cache Invalidation (mandatory)

Any script or code path that patches a chunk body or `.metadata.json`
sidecar directly in S3 under `bulk_chunks/<prefix>/...` — not through the
normal ingestion pipeline — MUST result in a call to
`Rag::SectionNeighborExpander.invalidate!(prefix)` for that document's
prefix. Without it, a correction already live in S3/Bedrock can still be
served stale by `Rag::SectionNeighborExpander`'s page-index cache for up to
`INDEX_CACHE_TTL` (ciclo 5 H1/H2, 2026-08-04 — a `canonical_name` fix sat
behind exactly this gap for a full day).

* `S3DocumentsService#upload_text` / `#upload_binary` already call
  `invalidate!` automatically for every key under `bulk_chunks/` — a repair
  script that writes through them needs no extra step.
* `S3DocumentsService#delete_prefix` does the same for a directory prefix
  under `bulk_chunks/` after a successful list/delete loop. Deleting the
  objects without that hook leaves the expander index pointing at a prefix
  that no longer exists.
* A script that mutates `bulk_chunks/` objects any other way (raw
  `Aws::S3::Client` calls, bypassing `S3DocumentsService`) MUST call
  `invalidate!(prefix)` explicitly, with a comment stating which hallazgo/
  cycle this satisfies and why the write bypasses the automatic hook.
* Never invalidate by recomputing the cache key by hand
  (`"section_neighbor_index/..." + Digest::SHA256...`) — always go through
  `invalidate!`/`index_cache_key`, the single source of truth for that
  derivation.

