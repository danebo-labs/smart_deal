# Web chat upload ingestion (custom chunking)

Feature-flagged path for **file attachments from the home RAG chat**. Default: **off** (`CUSTOM_CHUNKING_WEB_ENABLED` unset or `false`).

**Related:** [Bulk ZIP ingestion](BULK_INGESTION.md) · [Ingestion routing (types, filter, LLM matrix)](INGESTION_ROUTING.md) · [Bedrock setup](../BEDROCK_SETUP.md) · [Engineering snapshot](../CLAUDE.md)

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `CUSTOM_CHUNKING_WEB_ENABLED` | off | Enable direct Claude parse + bulk data source |
| `CUSTOM_CHUNKING_COST_V2_ENABLED` | off | Enable cost-v2 routing: Sonnet default + Batch manual + SHA dedup (see [INGESTION_COST_V2.md](INGESTION_COST_V2.md)) |
| `MANUAL_FORCE_SYNC` | off | Force sync parse for all manual PDFs (ops override for cost_v2) |
| `FIELD_PHOTO_HAIKU_GATE_ENABLED` | off | Activate optional Haiku pre-gate for dense scanned images (cost_v2) |
| `CUSTOM_CHUNKING_NO_FALLBACK` | off | **Dev/staging only** — fail fast, no legacy `OWRPGSX6XK` fallback |
| `BEDROCK_BULK_DATA_SOURCE_ID` | falls back to `BEDROCK_DATA_SOURCE_ID` | KB data source with **no Bedrock chunking** |
| `ANTHROPIC_API_KEY` | — | Required when flag is on (sync Messages API) |

Restart **web + workers** after changing flags.

**Local Office uploads:** install LibreOffice (see [README — Setup](../README.md#setup)).

---

### Web chat upload ingestion (custom chunking)

When **`CUSTOM_CHUNKING_WEB_ENABLED=true`**, a file attached in the home RAG chat follows a **direct Claude parse** path instead of Bedrock Foundation Model parsing on the default data source (`OWRPGSX6XK`). Default in all environments is **off** until you smoke-test and enable via Kamal env.

| Piece | Role |
|-------|------|
| `UploadAndSyncAttachmentsJob` | Fast ACK from the controller; uploads bytes to S3, then delegates to the orchestrator |
| `QueryOrchestratorService#upload_and_sync_attachments` | Routes to `CustomChunkingPipeline` when the flag is on, else legacy `KbSyncService` |
| `CustomChunkingPipeline` | Per-file orchestration, builds `web_v1_metadata` (canonical name + aliases), enqueues `BedrockIngestionJob`, **fallback** to legacy on error |
| `SingleFileChunkingService` | One file end-to-end: optional Office→PDF, PDF page split, relevance filter, Claude calls, S3 chunk writes |
| `FileMultimodalRouter` | Picks **Sonnet 4.6** vs **Opus 4.7** per page. **cost_v2:** `:image` default is Sonnet (not Opus); Opus only via `FieldPhotoDensityGate force_opus`. Rasterized slides still promote to Opus. |
| `FieldPhotoDensityGate` | *(cost_v2)* Heuristic + optional Haiku gate for image uploads → `:sonnet` or `:opus` |
| `FieldPhotoPrompt` | *(cost_v2)* Specialized photo system prompt; `ingestion_path: "field_photo_v1"`, 1 lightweight chunk |
| `FieldPhotoResultsParser` | *(cost_v2)* `FieldPhotoPrompt` JSON → standard `{document_name, aliases, chunks}` envelope |
| `ContentDedupService` | *(cost_v2)* SHA-256 dedup before any parse — `BulkUploadAsset.complete` hit skips Claude call |
| `ManualBatchIngestionService` | *(cost_v2)* Splits PDF + `PageRelevanceFilter` + Anthropic Batch per kept page (Sonnet; Opus on `force_opus`) |
| `SubmitManualBatchJob` | *(cost_v2)* Submits batch; stores context in Solid Cache; schedules `IngestManualBatchResultsJob` |
| `IngestManualBatchResultsJob` | *(cost_v2)* Polls batch, merges via `ChunkMergerService`, `ingestion_path: "manual_batch_v1"` |
| `ClaudeChunkingClient` | Sync Anthropic Messages API (`-direct` cost rows in `bedrock_queries`); accepts a `max_tokens` arg and exposes `stop_reason` so the caller can retry truncated calls |
| `PageRelevanceFilter` | Drops boilerplate PDF pages before Sonnet/Opus parse. **`filter_pages`**: ≥2 pages → one Haiku **`call_batch`**; 1 page → heuristics + optional Haiku gate. See [INGESTION_ROUTING.md](INGESTION_ROUTING.md) |
| `BatchResultsParserService` | Same parser as bulk ZIP; `ingestion_path: "web_v1"` (sync) / `"field_photo_v1"` / `"manual_batch_v1"` (cost_v2) |
| `BulkKbSyncService` | Starts ingestion on **`BEDROCK_BULK_DATA_SOURCE_ID`** (chunking disabled) |
| `LambdaParityAliasFallback` | Deterministic alias fill-in when the model returns empty aliases |
| `BedrockIngestionJob` | Polls ingestion; with `web_v1_metadata`, enriches `KbDocument` **without** a Bedrock retrieve call |

**Supported chat upload formats:** images (PNG/JPEG/GIF/WebP), text (`.txt`, `.md`, `.html`, `.csv`), PDFs, Office docs (`.doc`/`.docx`, `.xls`/`.xlsx`, `.ppt`/`.pptx`, `.odt`/`.ods`/`.odp`).

**PDF / Office handling:** multi-page PDFs are split with **`hexapdf`**; pages with heavy images stay on Opus, text-heavy pages downgrade to Sonnet when `text_chars > 500` and `image_ratio < 0.20`; scanned / rasterized pages (`text_layer < 100`, `image_ratio > 0.7`, or no XObjects but high pixel density — typical of LibreOffice slide flatten) stay on Opus. Up to **`MAX_PARALLEL_PAGES=8`** concurrent page requests per file. Office formats (Word/Excel/**PowerPoint**) convert via **`OfficeToPdfConverter`** (LibreOffice in Docker / local install) with per-job **`UserInstallation`** profile isolation so concurrent jobs don't collide on the global `~/.config/libreoffice` dir.

**Office failure UX:** when LibreOffice or the Claude parse fails for an Office file, the orchestrator surfaces **`rag.office_parse_failed`** (Spanish/English) on the session stream and **does NOT** silently fall back to the legacy `OWRPGSX6XK` data source — the previous fallback would re-upload the raw `.pptx` to Bedrock FM-parsing, which is extremely costly and produces poor chunks for slide decks. PDF / image / text failures still fall back to legacy.

### Claude Message API cost optimizations (web_v1)

The direct Claude path is the dominant ingestion cost on the web flow. Three knobs keep it tight:

1. **Per-page output cap with retry** — `BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS = 4_000` (down from the 32k default) on `pdf_mixed` page calls and `image` calls. `ClaudeChunkingClient` surfaces `stop_reason: "max_tokens"`; `SingleFileChunkingService#call_with_page_cap_retry` retries once at `WEB_PAGE_RETRY_MAX_TOKENS = 16_000`. Single-shot paths (`text`, `pdf_text_only`) keep `MAX_TOKENS = 32_000` because they emit the whole document in one response.
2. **Batch Haiku page classifier (multi-page docs)** — `PageRelevanceFilter.filter_pages` routes **all documents with ≥2 pages** (native PDFs and Office/PPT after LibreOffice convert) through **`call_batch`**: one Haiku 4.5 call classifies every page in a single message (cost row: `page_filter_batch: <filename> 1..N/N`). Single-page PDFs use the per-page heuristic cascade + optional Haiku gate (`page_filter: …`). For a 30-page manual this drops filter traffic from 30 calls to 1. Full rules: [INGESTION_ROUTING.md § Page relevance filter](INGESTION_ROUTING.md#step-2--page-relevance-filter).
3. **Locale-aware summaries on all input types** — `summary` and `companion_offer` are now emitted for every input type (image, PDF, Office, text) and the locale travels through `text_user_content` / `page_user_content` as a `Summary language: <code>` block. `ChunkMergerService` extracts the anchor page's summary so the technician sees a Spanish summary on the first response without a second Claude round-trip.

**Realtime UX:** `KbSyncBroadcaster` emits Turbo Cable events on the session stream; the chat shows typing dots, optional **retrying** copy during Aurora wake-up, then **indexed** / **failed** and refreshes the KB list.

**Cost telemetry:** parse jobs record `TrackBedrockQueryJob` rows with `user_query` like `web_parse: <filename>` or `web_parse: <filename> p<N>/<M>`; the slide-deck batch Haiku call records as `page_filter_batch: <filename> 1..N/N`. Dashboard / footer expose **Haiku**, **Parsing Opus**, and **Parsing Sonnet 4.6** daily totals; the **legacy** Bedrock-FM parse pill (Opus, OWRPGSX6XK) is now labelled "Parsing Opus (legacy)" since the direct-Claude path is the default cost line. See [METRICS.md](METRICS.md) for the `web_v1` vs legacy split inside `TrackIngestionUsageJob`.

**Rollout:** deploy with flag **OFF** → enable in staging → `CUSTOM_CHUNKING_WEB_ENABLED=true` in production. Optional dev flag **`CUSTOM_CHUNKING_NO_FALLBACK=true`** disables legacy fallback (fail-fast for debugging; **do not** use in prod).

**Tests:** `test/integration/web_custom_chunking_flow_test.rb`, service tests under `test/services/*chunk*`, `test/services/lambda_parity_test.rb`, golden fixture `test/fixtures/files/lambda_chunk_golden.json`.

### Cost v2 — photo + manual batch routing (2026-05-21)

When **`CUSTOM_CHUNKING_COST_V2_ENABLED=true`** (requires `CUSTOM_CHUNKING_WEB_ENABLED=true`):

| File type | Default path | Sync fallback trigger |
|-----------|-------------|----------------------|
| Images (JPEG/PNG/…) | `SingleFileChunkingService` → Sonnet + `FieldPhotoPrompt` (sync direct) | — (always sync) |
| PDF / Office | `SubmitManualBatchJob` → `ManualBatchIngestionService` → Batch API async | `force_sync: true` OR `MANUAL_FORCE_SYNC=true` OR query present in request |

**Foto path:** `FieldPhotoDensityGate` checks image size (heuristic) + optional Haiku 1-call → `:sonnet` or `:opus`. Sonnet result → `FieldPhotoResultsParser` → 1 lightweight chunk (`ingestion_path: "field_photo_v1"`). Opus result → monolithic `BatchChunkingPrompt` (fallback).

**Manual path:** `ManualBatchIngestionService` splits PDF per page → `PageRelevanceFilter.filter_pages` (batch Haiku for ≥2 pages) → 1 Anthropic Batch request per **kept** page (Sonnet; Opus for `force_opus` scanned pages). Results arrive in `IngestManualBatchResultsJob` → `ChunkMergerService` → `BatchResultsParserService` (`ingestion_path: "manual_batch_v1"`) → `BulkKbSyncService`.

**SHA dedup:** `ContentDedupService.find_completed(sha256:)` fires before any parse. Hit → skip parse entirely, reuse canonical_name/aliases from `BulkUploadAsset.complete`.

**Cost tracking:** `web_batch: <filename> p<N>/<M>` rows in `bedrock_queries` (no `-direct` suffix — Batch API pricing). `field_photo_v1` rows with `-direct` suffix.

**Full ADR + cost matrix:** [INGESTION_COST_V2.md](INGESTION_COST_V2.md)

---

### Web chat upload ingestion vs bulk ZIP

| | **Chat attachment** (`CUSTOM_CHUNKING_WEB_ENABLED`) | **Bulk ZIP** (`/bulk_uploads`) |
|---|-----------------------------------------------------|----------------------------------|
| Trigger | Single file from home chat | ZIP upload form |
| Claude API | Sync **Messages** per file/page | **Message Batches** (queued) |
| Queue lane | `default` (`UploadAndSyncAttachmentsJob`) | `bulk_ingestion` |
| Chunk metadata | `ingestion_path: "web_v1"` | `ingestion_path: "batch_v1"` |
| Identity on ingest | `web_v1_metadata` → `BedrockIngestionJob` | Parser headers + optional bulk DS |
| Fallback | Legacy `OWRPGSX6XK` (unless `CUSTOM_CHUNKING_NO_FALLBACK`) | Per-asset error rows on bulk show page |
