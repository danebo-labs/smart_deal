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

Product contract: a tenant may use its own `tenant_private` documents and
documents whose `kb_documents.knowledge_scope` is `danebo_general`.
`KbDocument::KNOWLEDGE_SCOPE_*` is the vocabulary. `Rag::KnowledgeScopePolicy`
is the read authority. `KnowledgeScopeChange.apply!` is the only writer of
that column, and it appends `knowledge_scope_changes`. The audit rows do not
grant access. `accounts.danebo_controlled` is the explicit source-account
mark required before a row can become `danebo_general`. Slug, branded,
filename, manufacturer, `manual_corpus=general`, and Legacy/Pilot membership
do not set that mark. Every existing row defaults to `tenant_private`.

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

Open retrieval reads `knowledge_scope`. Without a pin, `BedrockRagService#account_filter` is the viewer's `account_id` plus the canonical URIs of foreign `danebo_general` rows (`original_source_uri` and `x-amz-bedrock-kb-source-uri`). Own rows are not repeated in that URI list. Legacy, Pilot, slug, filename, and `manual_corpus=general` do not add a clause. `BatchResultsParserService#sidecar_metadata` still writes `manual_corpus` through `Rag::SharedManualCorpus.tag?`. That writer is ingestion metadata, not the read authority.

A `danebo_general` row whose canonical URI is missing, ambiguous, or over the application URI budget is omitted from the filter. The budget is `Rag::KnowledgeScopePolicy::OPEN_RETRIEVAL_MAX_GENERAL_URIS` (100) and `OPEN_RETRIEVAL_MAX_URI_BYTES` (24000). Over budget, the general arm is empty and the reason is `general_uris_over_limit`. Own `account_id` still matches. The list is not truncated. Bedrock's published limits stay one embedded logical operator, five clauses, and depth 2. The `in` operator has no published maximum in the RetrievalFilter API.

Results that come back are partitioned by `KnowledgeScopePolicy.partition_evidence` before they are published or passed to a local generation prompt. A chunk must bind exactly one physical row. `document_id` and chunk `account_id` confirm that row. They are not a lookup. Unmapped, ambiguous, and unauthorized chunks are dropped. If every citation from `retrieve_and_generate` fails, the generated text is not published. `retrieve_and_generate` still generates inside Bedrock; the request filter is what keeps unauthorized metadata out of that prompt. There is no second model call.

A caller filter may narrow the open corpus. `account_id` of another tenant, `account_id` inside `orAll`, and `manual_corpus` deny the request (`caller_filter_widens_scope`). A technical predicate is ANDed with the open corpus when the shape stays inside the Bedrock limits. A URI filter is still the pin path: the whole set is authorized, or the call is `DENY_RETRIEVAL`.

An unforced pin retry that drops the URI filter stays on this open corpus. It does not restore Legacy, Pilot, or `manual_corpus`. Revoking `danebo_general` removes the URI on the next retrieve. The owner still matches `account_id`. Other sessions' pins are not deleted; a pin of the revoked row is `DENY_RETRIEVAL`.

`WarmBedrockKbJob` is an Aurora ping. It calls `Retrieve` directly, discards the response, and does not serve a tenant. WhatsApp is dormant. A dormant caller of `BedrockRagService#query` uses this same filter and the same `DENY_RETRIEVAL`.

A question does not pin a manual or a page. A mentioned page never narrows retrieval. A document the technician pinned is the whole scope of that session's retrieve. The filter is those URIs alone. The technician can change the pins. An empty result does not silently drop them.

Do not wrap a nested `andAll` in another `andAll`. The open filter is flat so a technical AND stays at depth 2.

## Safety

* Never invent procedures, measurements, tolerances, or safety instructions.
* Surface uncertainty explicitly.
* Missing data must return `DATA_NOT_AVAILABLE`.
* Ambiguous data must return `REQUIRE_FIELD_VERIFICATION`.

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

