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

Danebo (`danebo-legacy`) and the elevator pilot (`danebo-pilot-elevator`) are general knowledge for every account's retrieve. Their `account_id` is already on the indexed chunks, so this does not need a reindex. Photos of those accounts stay out of other accounts' retrieval.

A new document chooses scope at parse time, on `BatchResultsParserService#call`:

* `corpus_scope: "general"` writes `manual_corpus=general`. Every account retrieves it.
* `corpus_scope: "account"` omits the attribute. Only that `account_id` matches.
* omitted: manuals of the two slugs above default to general; any other account defaults to account-only.

Photos never receive `manual_corpus`, even when `corpus_scope` is `"general"`.

A question does not pin a manual or a page, and a previous turn does not either. A field technician does not remember a page number among the manuals, so a mentioned page never narrows retrieval. Auto-scope and episode document inheritance were the WhatsApp stand-in for a pin control. A catalog token stays in Query Resolution.

Without a pin, retrieval is the shared document base: the session account, Danebo, the pilot, and `manual_corpus=general`. Danebo and the pilot share that base. Photos of the other account stay out.

A document the technician pinned is the whole scope of that retrieve. The filter is those URIs alone. It does not stay open over the rest of the shared base.

A retrieve filter must stay inside Bedrock's one embedded logical operator and five clauses per group. Do not wrap `account_filter` (its shared-account arm is already an `andAll`) in another `andAll`.

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

