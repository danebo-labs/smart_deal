# Bulk ZIP ingestion (web)

> **Cost v2 (2026-05-22):** With `CUSTOM_CHUNKING_COST_V2_ENABLED=true`, the ZIP bulk path now uses the same cost-v2 routing as the web chat: photos → Sonnet via `FieldPhotoPrompt` + `FieldPhotoDensityGate`, PDFs → per-page filter + Sonnet Batch (`BulkCostV2RequestBuilder`), Office entries → `OfficeToPdfConverter`. Legacy whole-file Opus remains the default (`CUSTOM_CHUNKING_COST_V2_ENABLED=false`). See [INGESTION_COST_V2.md](INGESTION_COST_V2.md) for the full cost matrix.

Signed-in technicians seed many documents at once via **`/bulk_uploads`** (HTML + Turbo Streams, not a JSON API).

**Related:** [Web custom chunking](WEB_CUSTOM_CHUNKING.md) · [Production deploy](PRODUCTION.md)

---

## Routes & flow

| HTTP | Path | Role |
|------|------|------|
| `GET` | `/bulk_uploads/new` | multipart form (ZIP file field `zip_file`) |
| `POST` | `/bulk_uploads` | validates ZIP, **SHA-256 dedupe** (`BulkUpload`), saves to `tmp/bulk_uploads/`, enqueues **`ProcessBulkUploadJob`**, redirects to show |
| `GET` | `/bulk_uploads/:id` | progress UI; **`turbo_stream_from "bulk_upload_<id>"`** drives live updates as assets move through statuses |

**Job chain** (all on **`queue_as :bulk_ingestion`**): `ProcessBulkUploadJob` → `SubmitClaudeBatchJob` → `PollClaudeBatchJob` (re-enqueue poll) → `IngestBatchResultsJob` → `PollBulkBedrockIngestionJob` (re-enqueue poll). Services: `ZipExtractionService`, `BatchIngestionService`, `BatchResultsParserService`, `BulkKbSyncService`, `ClaudeBatchClient`, **`BatchChunkingPrompt`** (`app/prompts/batch_chunking_prompt.rb`).

**Anthropic Message Batches — async vs “live” streaming:** bulk ZIP uses the **Message Batches** API, not synchronous `messages.create` per file. The app **submits** one batch (many `custom_id` requests), Anthropic **queues and processes** it on their side, and Rails **polls** batch status (`PollClaudeBatchJob`) until the batch is terminal. Only then does `IngestBatchResultsJob` pull outcomes. The `anthropic` gem exposes that download as **`messages.batches.results_streaming(batch_id)`**; `ClaudeBatchClient#results_each` iterates it. That “streaming” is **incremental delivery of the batch result JSONL** (one line ≈ one request’s `succeeded` / `errored` / … record). It is **not** token-by-token generation streaming like a live chat completion (`stream: true` on the Messages API). Mentally: **async job + streamed result file**, not **SSE of an in-flight answer**.

**Infra / KB design:** batch-produced chunks usually land on a **Bedrock data source with chunking disabled** (optional **`BEDROCK_BULK_DATA_SOURCE_ID`**); identity markers (**`Document:`**, **`DOCUMENT_ALIASES:`**, **`SOURCE_URI`**) are injected by **`BatchResultsParserService`** because there is no POST_CHUNKING Lambda on that path. **`BedrockRagService`** builds retrieval filters with **`orAll`** across **`x-amz-bedrock-kb-source-uri`** and **`original_source_uri`** so batch-ingested files still honor **pinned-entity** scoping.

**Persistence:** `bulk_uploads` (overall ZIP run + `claude_batch_id` / `bedrock_ingestion_job_id`), `bulk_upload_assets` (per extracted file, S3 key, Claude token estimates, `kb_document_id` when linked).

**Aurora schema discovery:** **`BedrockKbChunk`** (`app/models/bedrock_kb_chunk.rb`) is an **`abstract_class`** documenting AWS KB field mappings (embedding dim, `bedrock_integration.bedrock_knowledge_base`, JSONB metadata keys to confirm out-of-band). It does **not** connect to the app Primary DB or SQLite at boot.

**Operator tooling:** `bin/rails solid_queue:purge_all` clears Solid Queue rows and `tmp/bulk_uploads/*.zip`; optional **`CLEAN_BULK_UPLOADS=1`** destroys `BulkUpload` rows; production requires **`FORCE_PURGE_QUEUE=1`** (see `lib/tasks/solid_queue_purge.rake`).

---

## Local (cost-v2 bulk smoke)

1. **Migrate:** `bin/rails db:migrate` (adds `bulk_upload_assets.batch_custom_ids`, `ingestion_path`).
2. **`.env`:** `ANTHROPIC_API_KEY`, AWS creds, `BEDROCK_KNOWLEDGE_BASE_ID`, `BEDROCK_BULK_DATA_SOURCE_ID`, `KNOWLEDGE_BASE_S3_BUCKET`.
3. **Flag (optional):** `CUSTOM_CHUNKING_COST_V2_ENABLED=true` — Sonnet photos + per-page PDF batch; default **off** = legacy Opus whole-file.
4. **Processes:** `bin/dev` (or `bin/rails server` + `bin/jobs` for Solid Queue `bulk_ingestion`).
5. **LibreOffice** (`soffice`) if the ZIP includes Office files (`.docx`, `.pptx`, …).
6. **UI:** sign in → **`http://localhost:3000/bulk_uploads/new`** → upload ZIP → progress at **`/bulk_uploads/:id`**.

`CUSTOM_CHUNKING_WEB_ENABLED` is **not** required for bulk ZIP.

**Suggested test ZIP:** 2× JPEG + 1× PDF (~10 pages) + optional `.pptx`.

**Verify:** logs `BulkCostV2RequestBuilder filter`, `bulk_batch:` / `bulk_parse:` in `bedrock_queries`; assets reach **Disponible**; `model_id` ends with `-batch` when cost-v2 is on.
