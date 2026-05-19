# Web chat upload ingestion (custom chunking)

Feature-flagged path for **file attachments from the home RAG chat**. Default: **off** (`CUSTOM_CHUNKING_WEB_ENABLED` unset or `false`).

**Related:** [Bulk ZIP ingestion](BULK_INGESTION.md) · [Bedrock setup](../BEDROCK_SETUP.md) · [Engineering snapshot](../CLAUDE.md)

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `CUSTOM_CHUNKING_WEB_ENABLED` | off | Enable direct Claude parse + bulk data source |
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
| `FileMultimodalRouter` | Picks **Sonnet 4.6** vs **Opus 4.7** from text density / image ratio per page; promotes rasterized slides (no XObjects but high pixel density) to Opus so LibreOffice-flattened PowerPoint slides don't fall through to text mode |
| `ClaudeChunkingClient` | Sync Anthropic Messages API (`-direct` cost rows in `bedrock_queries`); accepts a `max_tokens` arg and exposes `stop_reason` so the caller can retry truncated calls |
| `PageRelevanceFilter` | Drops boilerplate PDF pages (heuristics + optional Haiku 4.5 gate) before spendy Opus calls; **`call_batch`** classifies all slides of an Office deck in one Haiku call |
| `BatchResultsParserService` | Same parser as bulk ZIP; `ingestion_path: "web_v1"` in sidecar metadata |
| `BulkKbSyncService` | Starts ingestion on **`BEDROCK_BULK_DATA_SOURCE_ID`** (chunking disabled) |
| `LambdaParityAliasFallback` | Deterministic alias fill-in when the model returns empty aliases |
| `BedrockIngestionJob` | Polls ingestion; with `web_v1_metadata`, enriches `KbDocument` **without** a Bedrock retrieve call |

**Supported chat upload formats:** images (PNG/JPEG/GIF/WebP), text (`.txt`, `.md`, `.html`, `.csv`), PDFs, Office docs (`.doc`/`.docx`, `.xls`/`.xlsx`, `.ppt`/`.pptx`, `.odt`/`.ods`/`.odp`).

**PDF / Office handling:** multi-page PDFs are split with **`hexapdf`**; pages with heavy images stay on Opus, text-heavy pages downgrade to Sonnet when `text_chars > 500` and `image_ratio < 0.20`; scanned / rasterized pages (`text_layer < 100`, `image_ratio > 0.7`, or no XObjects but high pixel density — typical of LibreOffice slide flatten) stay on Opus. Up to **`MAX_PARALLEL_PAGES=8`** concurrent page requests per file. Office formats (Word/Excel/**PowerPoint**) convert via **`OfficeToPdfConverter`** (LibreOffice in Docker / local install) with per-job **`UserInstallation`** profile isolation so concurrent jobs don't collide on the global `~/.config/libreoffice` dir.

**Office failure UX:** when LibreOffice or the Claude parse fails for an Office file, the orchestrator surfaces **`rag.office_parse_failed`** (Spanish/English) on the session stream and **does NOT** silently fall back to the legacy `OWRPGSX6XK` data source — the previous fallback would re-upload the raw `.pptx` to Bedrock FM-parsing, which is extremely costly and produces poor chunks for slide decks. PDF / image / text failures still fall back to legacy.

### Claude Message API cost optimizations (web_v1)

The direct Claude path is the dominant ingestion cost on the web flow. Three knobs keep it tight:

1. **Per-page output cap with retry** — `BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS = 4_000` (down from the 32k default) on `pdf_mixed` page calls and `image` calls. `ClaudeChunkingClient` surfaces `stop_reason: "max_tokens"`; `SingleFileChunkingService#call_with_page_cap_retry` retries once at `WEB_PAGE_RETRY_MAX_TOKENS = 16_000`. Single-shot paths (`text`, `pdf_text_only`) keep `MAX_TOKENS = 32_000` because they emit the whole document in one response.
2. **Batch Haiku slide classifier for Office decks** — `PageRelevanceFilter.call_batch` makes **one** Haiku 4.5 call that classifies **all N slides** of a converted PPT/PPTX in a single message (one cover/agenda/diagram JSON for the whole deck), instead of one Haiku call per page. `SingleFileChunkingService` flips `@office_origin = true` in `handle_office` and routes multi-page Office origins through `call_batch` (cost row: `page_filter_batch: <filename> 1..N/N`). Native PDFs keep the per-page heuristic + Haiku gate. For a 30-slide deck this drops Haiku traffic from 30 calls to 1.
3. **Locale-aware summaries on all input types** — `summary` and `companion_offer` are now emitted for every input type (image, PDF, Office, text) and the locale travels through `text_user_content` / `page_user_content` as a `Summary language: <code>` block. `ChunkMergerService` extracts the anchor page's summary so the technician sees a Spanish summary on the first response without a second Claude round-trip.

**Realtime UX:** `KbSyncBroadcaster` emits Turbo Cable events on the session stream; the chat shows typing dots, optional **retrying** copy during Aurora wake-up, then **indexed** / **failed** and refreshes the KB list.

**Cost telemetry:** parse jobs record `TrackBedrockQueryJob` rows with `user_query` like `web_parse: <filename>` or `web_parse: <filename> p<N>/<M>`; the slide-deck batch Haiku call records as `page_filter_batch: <filename> 1..N/N`. Dashboard / footer expose **Haiku**, **Parsing Opus**, and **Parsing Sonnet 4.6** daily totals; the **legacy** Bedrock-FM parse pill (Opus, OWRPGSX6XK) is now labelled "Parsing Opus (legacy)" since the direct-Claude path is the default cost line. See [METRICS.md](METRICS.md) for the `web_v1` vs legacy split inside `TrackIngestionUsageJob`.

**Rollout:** deploy with flag **OFF** → enable in staging → `CUSTOM_CHUNKING_WEB_ENABLED=true` in production. Optional dev flag **`CUSTOM_CHUNKING_NO_FALLBACK=true`** disables legacy fallback (fail-fast for debugging; **do not** use in prod).

**Tests:** `test/integration/web_custom_chunking_flow_test.rb`, service tests under `test/services/*chunk*`, `test/services/lambda_parity_test.rb`, golden fixture `test/fixtures/files/lambda_chunk_golden.json`.

### Web chat upload ingestion vs bulk ZIP

| | **Chat attachment** (`CUSTOM_CHUNKING_WEB_ENABLED`) | **Bulk ZIP** (`/bulk_uploads`) |
|---|-----------------------------------------------------|----------------------------------|
| Trigger | Single file from home chat | ZIP upload form |
| Claude API | Sync **Messages** per file/page | **Message Batches** (queued) |
| Queue lane | `default` (`UploadAndSyncAttachmentsJob`) | `bulk_ingestion` |
| Chunk metadata | `ingestion_path: "web_v1"` | `ingestion_path: "batch_v1"` |
| Identity on ingest | `web_v1_metadata` → `BedrockIngestionJob` | Parser headers + optional bulk DS |
| Fallback | Legacy `OWRPGSX6XK` (unless `CUSTOM_CHUNKING_NO_FALLBACK`) | Per-asset error rows on bulk show page |
