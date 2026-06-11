# Web chat upload ingestion (custom chunking)

Active path for **file attachments from the home RAG chat**. No feature flags — `CustomChunkingPipeline` is the only path.

**Related:** [Bulk ZIP ingestion](BULK_INGESTION.md) · [Ingestion routing (types, filter, LLM matrix)](INGESTION_ROUTING.md) · [Engineering snapshot](../CLAUDE.md)

## Required environment variables

| Variable | Purpose |
|----------|---------|
| `BEDROCK_BULK_DATA_SOURCE_ID` | KB data source with **no Bedrock chunking** for web and bulk upload chunks |
| `ANTHROPIC_API_KEY` | Required for sync Messages API calls (web uploads) |

**Local Office uploads:** install LibreOffice (see [README — Setup](../README.md#setup)).

---

### Web chat upload ingestion flow

A file attached in the home RAG chat follows a **direct Claude parse** path via `CustomChunkingPipeline`.

| Piece | Role |
|-------|------|
| `UploadAndSyncAttachmentsJob` | Fast ACK from the controller; delegates to the orchestrator |
| `QueryOrchestratorService#upload_and_sync_attachments` | Instantiates `CustomChunkingPipeline` with `urgent: true`; web/chat uploads always use sync Messages API |
| `CustomChunkingPipeline` | Per-file routing, builds `web_v1_metadata` (canonical name + aliases), enqueues `BedrockIngestionJob`. Errors propagate to the job (no legacy fallback) |
| `SingleFileChunkingService` | One file end-to-end: optional Office→PDF, PDF page split, relevance filter, Claude calls, S3 chunk writes |
| `FileMultimodalRouter` | Picks **Sonnet 4.6** vs **Opus 4.7** per page. `:image` default is Sonnet; Opus only via `FieldPhotoDensityGate force_opus`. Rasterized slides still promote to Opus. |
| `FieldPhotoDensityGate` | Size-heuristic routing for image uploads → `:sonnet` (< 1.5 MB) or `:opus` (≥ 1.5 MB). Zero LLM calls. |
| `FieldPhotoPrompt` | Specialized photo prompt; `ingestion_path: "field_photo_v1"`, 1 compact chunk with literal labels and optional explicit visible functions/connections/values/warnings |
| `FieldPhotoResultsParser` | `FieldPhotoPrompt` JSON → standard `{document_name, aliases, chunks}` envelope; undocumented label meaning remains `DATA_NOT_AVAILABLE` |
| `ContentDedupService` | SHA-256 dedup before any parse — hit skips Claude call entirely |
| `ManualBatchIngestionService` | Dormant for chat; retained for the old long-manual batch branch |
| `SubmitManualBatchJob` | Dormant for chat; not enqueued by the web/chat orchestrator |
| `IngestManualBatchResultsJob` | Dormant for chat; polls manual batch results when that branch is invoked manually |
| `ClaudeChunkingClient` | Sync Anthropic Messages API (`-direct` cost rows in `bedrock_queries`); accepts a `max_tokens` arg and exposes `stop_reason` so the caller can retry truncated calls |
| `PageRelevanceFilter` | Drops boilerplate PDF pages before Sonnet/Opus parse. **`filter_pages`**: ≥2 pages → Haiku **`call_batch`** in bounded windows; 1 page → heuristics + optional Haiku gate. See [INGESTION_ROUTING.md](INGESTION_ROUTING.md) |
| `BatchResultsParserService` | Same parser as bulk ZIP; web/chat sync writes `ingestion_path: "web_v1"` / `"field_photo_v1"` and renders manual `field_records` as canonical retrieval blocks with deterministic IDs |
| `BulkKbSyncService` | Starts ingestion on **`BEDROCK_BULK_DATA_SOURCE_ID`** (chunking disabled) |
| `LambdaParityAliasFallback` | Deterministic alias fill-in when the model returns empty aliases |
| `BedrockIngestionJob` | Polls ingestion; with `web_v1_metadata`, enriches `KbDocument` **without** a Bedrock retrieve call |

**Supported chat upload formats:** images (PNG/JPEG/GIF/WebP), text (`.txt`, `.md`, `.html`, `.csv`), PDFs, Office docs (`.doc`/`.docx`, `.xls`/`.xlsx`, `.ppt`/`.pptx`, `.odt`/`.ods`/`.odp`).

**PDF routing (per-file in `CustomChunkingPipeline`):**

| Condition | Route |
|-----------|-------|
| Image or Office file | `SingleFileChunkingService` (sync) |
| PDF, any page count, with or without query | `SingleFileChunkingService` (sync cost-v2) |

**Office failure UX:** when LibreOffice or Claude parse fails for an Office file, `KbSyncBroadcaster.failed` surfaces `rag.office_parse_failed` on the session stream. No legacy fallback — errors propagate to `UploadAndSyncAttachmentsJob`, which broadcasts failed and lets Solid Queue retry.

### Claude Message API cost optimizations (web_v1)

1. **Per-page output cap with retry** — `BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS = 4_000` on `pdf_mixed` page calls and `image` calls. `ClaudeChunkingClient` surfaces `stop_reason: "max_tokens"`; `SingleFileChunkingService#call_with_page_cap_retry` retries once at `WEB_PAGE_RETRY_MAX_TOKENS = 16_000`.
2. **Batch Haiku page classifier (multi-page docs)** — `PageRelevanceFilter.filter_pages` routes **all documents with ≥2 pages** through **`call_batch`**: Haiku 4.5 classifies windows of up to 20 pages and 22 MB raw PDF bytes. Each window gets dynamic output tokens, retries once only when JSON parsing fails, and falls back to keep-all only for that window.
3. **Locale-aware summaries** — `summary` and `companion_offer` emitted for every input type; locale travels through `text_user_content` / `page_user_content`. `ChunkMergerService` extracts the anchor page's summary.
4. **Compact manual evidence** — Sonnet/Opus emit short-key `field_records` only for qualifying evidence and omit absent optional fields. Rails validates, assigns deterministic IDs, and expands canonical labels before S3 upload; no additional LLM call is introduced.

**Realtime UX:** `KbSyncBroadcaster` emits Turbo Cable events; the chat shows typing dots, optional **retrying** copy during Aurora wake-up, then **indexed** / **failed** and refreshes the KB list.

**Cost telemetry:** web/chat parse jobs record `TrackBedrockQueryJob` rows with `user_query` like `web_parse: <filename>` / `web_parse: <filename> p<N>/<M>`. Dashboard exposes **Haiku**, **Parsing Opus**, and **Parsing Sonnet 4.6** daily totals.

**Tests:** `test/integration/web_custom_chunking_flow_test.rb`, service tests under `test/services/*chunk*`, `test/services/lambda_parity_test.rb`, golden fixture `test/fixtures/files/lambda_chunk_golden.json`.

---

### Web chat upload vs bulk ZIP

| | **Chat attachment** | **Bulk ZIP** (`/bulk_uploads`) |
|---|---------------------|----------------------------------|
| Trigger | Single file from home chat | ZIP upload form |
| Claude API | Sync **Messages** per file/page | **Message Batches** (always async) |
| Queue lane | `default` (`UploadAndSyncAttachmentsJob`) | `bulk_ingestion` |
| Chunk metadata | `ingestion_path: "web_v1"` / `"field_photo_v1"` | `ingestion_path: "batch_v1"` / `"field_photo_v1"` / `"manual_batch_v1"` |
| Identity on ingest | `web_v1_metadata` → `BedrockIngestionJob` | Parser headers + bulk DS |
| On error | `KbSyncBroadcaster.failed` → technician retry | Per-asset error rows on bulk show page |
