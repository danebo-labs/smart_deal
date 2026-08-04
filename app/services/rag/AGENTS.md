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
* A script that mutates `bulk_chunks/` objects any other way (raw
  `Aws::S3::Client` calls, bypassing `S3DocumentsService`) MUST call
  `invalidate!(prefix)` explicitly, with a comment stating which hallazgo/
  cycle this satisfies and why the write bypasses the automatic hook.
* Never invalidate by recomputing the cache key by hand
  (`"section_neighbor_index/..." + Digest::SHA256...`) — always go through
  `invalidate!`/`index_cache_key`, the single source of truth for that
  derivation.

