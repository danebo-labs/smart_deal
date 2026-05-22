# Performance Constraints

Production priorities:

* Low end-user latency
* Minimal Bedrock round trips
* Minimal DB queries
* Minimal orchestration complexity

Preferred patterns:

* Direct execution paths
* Single-pass retrieval/generation
* Metadata filtering before semantic search
* Async only for long-running operations

Avoid:

* Excessive orchestration
* Multi-step retrieval chains
* Callback-heavy flows
* Polling-heavy architectures
* Excessive Turbo broadcasts

### Ingestion cost v2 notes (2026-05-21)

* **Batch manual** = genuinely long-running work (Anthropic Batch up to hours) → async OK, technician is not blocked.
* **Sync fallback manual** = only when technician attaches document AND asks a question simultaneously (they need the answer now). Costs ~2× more than batch but acceptable for urgent paths.
* **SHA dedup** (`ContentDedupService`) short-circuits all Claude parse for re-uploads of identical binaries — single DB query, no Anthropic call.
* Do **not** poll Anthropic Batch more frequently than every 1 minute (`IngestManualBatchResultsJob` default: 1h between attempts, max 24). Shorter intervals don't speed up Anthropic processing and waste queue capacity.
