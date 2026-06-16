# Web chat upload ingestion (custom chunking)

Active path for **file attachments from the home RAG chat**. No feature flags — `CustomChunkingPipeline` is the only path.

**Related:** [Bulk ZIP ingestion](BULK_INGESTION.md) · [Ingestion routing (types, filter, LLM matrix)](INGESTION_ROUTING.md) · [Engineering snapshot](../CLAUDE.md)

## Required environment variables

| Variable | Purpose |
|----------|---------|
| `BEDROCK_BULK_DATA_SOURCE_ID` | Shared KB data source with **no Bedrock chunking** and S3 inclusion prefix `bulk_chunks/` |
| `ANTHROPIC_API_KEY` | Required for sync Messages API calls (web uploads) |

**Local Office uploads:** install LibreOffice (see [README — Setup](../README.md#setup)).

The data source must not scan the complete bucket. Original files remain under
`uploads/`; only the app-generated `.txt` chunks and `.metadata.json` sidecars
under `bulk_chunks/` are indexed. See
[Bedrock data source configuration](../BEDROCK_SETUP.md#required-s3-data-source-configuration).

---

### Web chat upload ingestion flow

A file attached in the home RAG chat follows `CustomChunkingPipeline`. Short files use direct Claude parse; long PDFs route automatically to Anthropic Batch.

| Piece | Role |
|-------|------|
| `UploadAndSyncAttachmentsJob` | Fast ACK from the controller; delegates to the orchestrator and preserves the original question for urgent long-manual triage |
| `QueryOrchestratorService#upload_and_sync_attachments` | Instantiates `CustomChunkingPipeline`; `urgent: true` is compatibility only and no longer forces long PDFs onto sync |
| `CustomChunkingPipeline` | Per-file routing, builds ready-now `web_v1_metadata`, enqueues `BedrockIngestionJob` only for chunks that exist now. Long PDFs enqueue `SubmitManualBatchJob`; with a nonblank question they also enqueue urgent page triage |
| `SingleFileChunkingService` | One file end-to-end: optional Office→PDF, PDF page split, relevance filter, Claude calls, S3 chunk writes |
| `FileMultimodalRouter` | Picks **Sonnet 4.6** vs **Opus 4.7** per page. `:image` default is Sonnet; Opus only via `FieldPhotoDensityGate force_opus`. Rasterized slides still promote to Opus. |
| `FieldPhotoDensityGate` | Size-heuristic routing for image uploads → `:sonnet` (< 1.5 MB) or `:opus` (≥ 1.5 MB). Zero LLM calls. |
| `FieldPhotoPrompt` | Specialized photo prompt; `ingestion_path: "field_photo_v1"`, 1 compact chunk with literal labels and optional explicit visible functions/connections/values/warnings |
| `FieldPhotoResultsParser` | `FieldPhotoPrompt` JSON → standard `{document_name, aliases, chunks}` envelope; undocumented label meaning remains `DATA_NOT_AVAILABLE` |
| `ContentDedupService` | SHA-256 dedup before any parse — hit skips Claude call entirely |
| `WebManualBatch` | Durable ledger for web long-manual Batch context (`claude_batch_id`, page map, status, chunk prefix) |
| `ManualBatchIngestionService` | Splits long PDFs into pages, filters relevance, submits Anthropic Batch |
| `SubmitManualBatchJob` | Enqueued automatically for long web/chat PDFs on `bulk_ingestion`; idempotent on existing `claude_batch_id` |
| `IngestManualBatchResultsJob` | Polls web manual Batch, retries truncated/invalid pages through `BatchPageRetryService`, writes `manual_batch_v1` chunks, then starts KB sync |
| `ManualUrgentPageSelector` | Deterministically selects a small number of pages from the PDF using the technician question, text extraction, and technical/safety signals. No manual page picking and no page-selection LLM call |
| `ProcessManualUrgentTriageJob` / `ManualUrgentTriageService` | Parses selected urgent pages direct with the same 8k→16k→32k ladder, writes temporary `manual_batch_v1` chunks, starts a partial KB sync, and marks `processing_scope: urgent_pages` |
| `ClaudeChunkingClient` | Sync Anthropic Messages API (`-direct` cost rows in `bedrock_queries`); accepts a `max_tokens` arg and exposes `stop_reason` so the caller can retry truncated calls |
| `PageRelevanceFilter` | Drops boilerplate PDF pages before Sonnet/Opus parse. **`filter_pages`**: ≥2 pages → Haiku **`call_batch`** in bounded windows; 1 page → heuristics + optional Haiku gate. See [INGESTION_ROUTING.md](INGESTION_ROUTING.md) |
| `BatchResultsParserService` | Same parser as bulk ZIP; web/chat sync writes `ingestion_path: "web_v1"` / `"field_photo_v1"` and renders manual `field_records` as canonical retrieval blocks with deterministic IDs |
| `BulkKbSyncService` | Starts ingestion on **`BEDROCK_BULK_DATA_SOURCE_ID`** (chunking disabled, `bulk_chunks/` inclusion prefix) |
| `LambdaParityAliasFallback` | Deterministic alias fill-in when the model returns empty aliases |
| `BedrockIngestionJob` | Polls ingestion; with `web_v1_metadata`, enriches `KbDocument` **without** a Bedrock retrieve call |

**Supported chat upload formats:** images (PNG/JPEG/GIF/WebP), text (`.txt`, `.md`, `.html`, `.csv`), PDFs, Office docs (`.doc`/`.docx`, `.xls`/`.xlsx`, `.ppt`/`.pptx`, `.odt`/`.ods`/`.odp`).

**PDF routing (per-file in `CustomChunkingPipeline`):**

| Condition | Route |
|-----------|-------|
| Image or Office file | `SingleFileChunkingService` (sync) |
| PDF pages ≤ `WEB_SYNC_PDF_PAGE_THRESHOLD` (default 2), with or without query | `SingleFileChunkingService` (sync cost-v2) |
| PDF pages > `WEB_SYNC_PDF_PAGE_THRESHOLD`, blank query | `SubmitManualBatchJob` → `ManualBatchIngestionService` → `IngestManualBatchResultsJob` (async Batch) |
| PDF pages > `WEB_SYNC_PDF_PAGE_THRESHOLD`, nonblank query | Same full Batch path plus `ProcessManualUrgentTriageJob` for automatically selected urgent pages |

Long manual routing is automatic. The technician uploads the full PDF from web/chat; the app does not require manual page selection on mobile. `CustomChunkingPipeline` returns the filename for ACK, but it does not index the original PDF under `uploads/`. If the upload has no question, the first KB sync waits for Batch results. If the upload includes a question, E3b processes a bounded set of automatically selected urgent pages immediately while the complete manual continues through Batch.

While a long manual is processing, the chat remains usable for questions over already-indexed documents. If a document upload includes a text question, the API returns the normal RAG answer plus `documents_uploaded`, and the web UI keeps a separate persistent indexing notice. A partial `indexed` event with `processing_scope: urgent_pages` shows the selected pages now available but keeps the full-manual notice alive until the final Batch `indexed` / `failed` arrives.

**Office failure UX:** when LibreOffice or Claude parse fails for an Office file, `KbSyncBroadcaster.failed` surfaces `rag.office_parse_failed` on the session stream. No legacy fallback — errors propagate to `UploadAndSyncAttachmentsJob`, which broadcasts failed and lets Solid Queue retry.

### Claude Message API cost optimizations (web_v1)

1. **Per-page output cap with ladder retry (O3′, 2026-06-12)** — `BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS = 8_000` universal initial cap on `pdf_mixed` page calls, `image` calls and the per-page Batch builders (`ManualBatchIngestionService`, `BulkCostV2RequestBuilder`). `ClaudeChunkingClient` surfaces `stop_reason: "max_tokens"`; `SingleFileChunkingService::PAGE_TOKEN_LADDER` escalates 8k → 16k → 32k (sync), and `BatchPageRetryService` (B.1, 2026-06-12) covers the 16k → 32k direct retries for Batch pages that are truncated **or returned invalid JSON** — shared by the bulk ZIP route and the web long-manual Batch chain; the original Batch row is preserved and each retry is tracked once. The largest observed final page output is 5,650 tokens (run4), so 8k eliminates the truncate-then-retry double billing measured at $2.83–3.35 per 200pp manual (`script/gate9_cost_matrix.rb`).
2. **Batch Haiku page classifier (multi-page docs)** — `PageRelevanceFilter.filter_pages` routes **all documents with ≥2 pages** through **`call_batch`**: Haiku 4.5 classifies windows of up to 20 pages and 22 MB raw PDF bytes. Each window gets dynamic output tokens, retries once only when JSON parsing fails, and falls back to keep-all only for that window.
3. **Locale-aware summaries** — `summary` and `companion_offer` emitted for every input type; locale travels through `text_user_content` / `page_user_content`. `ChunkMergerService` extracts the anchor page's summary.
4. **Compact manual evidence** — Sonnet/Opus emit short-key `field_records` only for qualifying evidence and omit absent optional fields. Rails validates, assigns deterministic IDs, and expands canonical labels before S3 upload; no additional LLM call is introduced.

**Realtime UX:** `KbSyncBroadcaster` emits Turbo Cable events; the chat shows typing dots, optional **retrying** copy during Aurora wake-up, partial urgent-page readiness (`processing_scope: urgent_pages`) when applicable, then full **indexed** / **failed** and refreshes the KB list.

**Cost telemetry:** sync web/chat parse jobs record `TrackBedrockQueryJob` rows with `user_query` like `web_parse: <filename>` / `web_parse: <filename> p<N>/<M>`. E3b urgent pages use `web_urgent: <filename> p<N>/<M>`. Long web/manual Batch rows use `web_batch: <filename> p<N>/<M>`. Dashboard exposes **Haiku**, **Parsing Opus**, and **Parsing Sonnet 4.6** daily totals.

**Gate 9R I0 (2026-06-12):** every billable invocation persists one `BedrockQuery` row with `route` (`sync` / `batch` / `bulk_retry` / `page_filter` / `rag_filtered` / `rag_global` / `query_direct`), `attempt`, `max_tokens`, `stop_reason` and `correlation_id` (`ingest:<sha12>[:p<N>]` for uploads, `query:<uuid>` for RAG turns — a filtered no-results attempt and its global fallback leave two correlated rows). Tokens are the billing source of truth; money is derived via versioned pricing (`Gate9CostMatrix::PRICING`). Finite per-unit limits live in `ContractualLimits`; where the app has no lower multimodal input-token control, the matrix uses the provider context window and assumes every manual page may route to Opus until E3a enforces the commercial 15% policy. The reproducible cost matrix runs with `bin/rails runner script/gate9_cost_matrix.rb` (zero external calls).

**Tests:** `test/integration/web_custom_chunking_flow_test.rb`, service tests under `test/services/*chunk*`, `test/services/lambda_parity_test.rb`, golden fixture `test/fixtures/files/lambda_chunk_golden.json`.

---

### Web chat upload vs bulk ZIP

| | **Chat attachment** | **Bulk ZIP** (`/bulk_uploads`) |
|---|---------------------|----------------------------------|
| Trigger | Single file from home chat | ZIP upload form |
| Claude API | Sync **Messages** for short files; **Message Batches** for long PDFs | **Message Batches** (always async) |
| Queue lane | `default` (`UploadAndSyncAttachmentsJob`) + `bulk_ingestion` for long PDFs | `bulk_ingestion` |
| Chunk metadata | `ingestion_path: "web_v1"` / `"field_photo_v1"` / `"manual_batch_v1"` | `ingestion_path: "batch_v1"` / `"field_photo_v1"` / `"manual_batch_v1"` |
| Identity on ingest | `web_v1_metadata` → `BedrockIngestionJob` | Parser headers + bulk DS |
| On error | `KbSyncBroadcaster.failed` → technician retry | Per-asset error rows on bulk show page |
