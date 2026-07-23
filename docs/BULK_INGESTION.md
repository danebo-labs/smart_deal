# Bulk ZIP ingestion (web)

> **MVP status:** implementation preserved, routes disabled for the pilot in
> `config/routes.rb`. The paths and smoke instructions below apply only after an
> explicit product decision to re-enable this backoffice capability.

> **Bulk ZIP path:** photos → Sonnet via `FieldPhotoPrompt` + `FieldPhotoDensityGate` (size heuristic only); PDFs → `PageRelevanceFilter.filter_pages` + Sonnet Batch (`BulkCostV2RequestBuilder`); Office entries → `OfficeToPdfConverter` before batch build. See [INGESTION_COST_V2.md](INGESTION_COST_V2.md) for the full cost matrix. **Routing detail:** [INGESTION_ROUTING.md](INGESTION_ROUTING.md).

When enabled, signed-in operators can seed many documents at once via
**`/bulk_uploads`** (HTML + Turbo Streams, not a JSON API).

**Related:** [Web custom chunking](WEB_CUSTOM_CHUNKING.md) · [Production deploy](PRODUCTION.md) · [Ingestion routing](INGESTION_ROUTING.md)

---

## File routing

After ZIP extract and S3 upload, `SubmitClaudeBatchJob` calls `BatchIngestionService#submit!` → `BulkCostV2RequestBuilder`:

| Asset type | Routing |
|------------|---------|
| **Image** (JPEG/PNG/…) | `FieldPhotoDensityGate` (size heuristic) → Sonnet or Opus; `FieldPhotoPrompt` when Sonnet |
| **PDF** | Split pages → `PageRelevanceFilter.filter_pages` → **Sonnet batch per kept page** (Opus if `force_opus` on scanned pages) |
| **Office** (`.docx`, `.pptx`, …) | Converted to PDF in extract phase → same as PDF row |
| **SHA dedup hit** | Asset marked `complete` — no batch row |

Boilerplate pages (portada, índice, copyright, dedicatoria, agenda) are dropped by the page filter **before** Sonnet/Opus parse — see [INGESTION_ROUTING.md § Page relevance filter](INGESTION_ROUTING.md#step-2--page-relevance-filter).

---

## Routes & flow

| HTTP | Path | Role |
|------|------|------|
| `GET` | `/bulk_uploads/new` | multipart form (ZIP file field `zip_file`) |
| `POST` | `/bulk_uploads` | validates ZIP, **SHA-256 dedupe** (`BulkUpload`), stages the archive under `bulk_upload_archives/` in S3, enqueues **`ProcessBulkUploadJob`**, redirects to show |
| `GET` | `/bulk_uploads/:id` | progress UI; **`turbo_stream_from "bulk_upload_<id>"`** drives live updates as assets move through statuses |

**Job chain** (all on **`queue_as :bulk_ingestion`**): `ProcessBulkUploadJob` → `SubmitClaudeBatchJob` → `PollClaudeBatchJob` (re-enqueue poll) → `IngestBatchResultsJob` → `PollBulkBedrockIngestionJob` (re-enqueue poll). Services: `ZipExtractionService`, `BatchIngestionService`, `BatchResultsParserService`, `BulkKbSyncService`, `ClaudeBatchClient`, **`BatchChunkingPrompt`** (`app/prompts/batch_chunking_prompt.rb`).

**Anthropic Message Batches — async vs “live” streaming:** bulk ZIP uses the **Message Batches** API, not synchronous `messages.create` per file. The app **submits** one batch (many `custom_id` requests), Anthropic **queues and processes** it on their side, and Rails **polls** batch status (`PollClaudeBatchJob`) until the batch is terminal. Only then does `IngestBatchResultsJob` pull outcomes. The `anthropic` gem exposes that download as **`messages.batches.results_streaming(batch_id)`**; `ClaudeBatchClient#results_each` iterates it. That “streaming” is **incremental delivery of the batch result JSONL** (one line ≈ one request’s `succeeded` / `errored` / … record). It is **not** token-by-token generation streaming like a live chat completion (`stream: true` on the Messages API). Mentally: **async job + streamed result file**, not **SSE of an in-flight answer**.

**Infra / KB design:** batch-produced chunks land on the shared
**`BEDROCK_BULK_DATA_SOURCE_ID`**, configured with chunking disabled and S3
inclusion prefix **`bulk_chunks/`**. Originals under `bulk_uploads/` remain in
S3 but are not indexed directly. Identity markers (**`Document:`**,
**`DOCUMENT_ALIASES:`**, **`SOURCE_URI`**) are injected by
**`BatchResultsParserService`** because there is no POST_CHUNKING Lambda on that
path. **`BedrockRagService`** builds retrieval filters with **`orAll`** across
**`x-amz-bedrock-kb-source-uri`** and **`original_source_uri`** so batch-ingested
files still honor **pinned-entity** scoping. See
[Bedrock data source configuration](../BEDROCK_SETUP.md#required-s3-data-source-configuration).

**Persistence:** `bulk_uploads` (overall ZIP run + `claude_batch_id` / `bedrock_ingestion_job_id`), `bulk_upload_assets` (per extracted file, S3 key, Claude token estimates, `kb_document_id` when linked).

**Aurora schema discovery:** **`BedrockKbChunk`** (`app/models/bedrock_kb_chunk.rb`) is an **`abstract_class`** documenting AWS KB field mappings (embedding dim, `bedrock_integration.bedrock_knowledge_base`, JSONB metadata keys to confirm out-of-band). It does **not** connect to the app Primary DB or SQLite at boot.

Temporary ZIP archives are removed from S3 after `ProcessBulkUploadJob` downloads and processes them. **Operator tooling:** `bin/rails solid_queue:purge_all` clears Solid Queue rows and legacy `tmp/bulk_uploads/*.zip`; optional **`CLEAN_BULK_UPLOADS=1`** destroys `BulkUpload` rows; production requires **`FORCE_PURGE_QUEUE=1`** (see `lib/tasks/solid_queue_purge.rake`).

---

## Local (cost-v2 bulk smoke)

1. **Migrate:** `bin/rails db:migrate` (adds `bulk_upload_assets.batch_custom_ids`, `ingestion_path`).
2. **`.env`:** `ANTHROPIC_API_KEY`, AWS creds, `BEDROCK_KNOWLEDGE_BASE_ID`, `BEDROCK_BULK_DATA_SOURCE_ID`, `KNOWLEDGE_BASE_S3_BUCKET`.
3. **Processes:** `bin/dev` (or `bin/rails server` + `bin/jobs` for Solid Queue `bulk_ingestion`).
4. **LibreOffice** (`soffice`) if the ZIP includes Office files (`.docx`, `.pptx`, …).
5. **UI:** sign in → **`http://localhost:3000/bulk_uploads/new`** → upload ZIP → progress at **`/bulk_uploads/:id`**.

**Suggested test ZIP:** 2× JPEG + 1× PDF (~10 pages) + optional `.pptx`.

**Verify:** logs `BulkCostV2RequestBuilder filter`, `bulk_batch:` / `bulk_parse:` in `bedrock_queries`; assets reach **Disponible**; `model_id` ends with `-batch` when cost-v2 is on.
