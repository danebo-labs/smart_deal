# Bulk ZIP ingestion (web)

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
