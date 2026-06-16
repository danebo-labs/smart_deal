# LLM usage metrics & Solid Queue lanes

Async token/cost tracking — Bedrock calls never wait on DB writes.

**Related:** [Production](PRODUCTION.md) · [Ingestion routing](INGESTION_ROUTING.md) · [README — Configuration flags](../README.md#configuration-flags)

---

### LLM usage metrics & Solid Queue

Model usage is recorded **asynchronously** so Bedrock calls never wait on DB writes or dashboard broadcasts. `bedrock_queries` stores each event with a **`source`** plus **`input_tokens`**, **`output_tokens`**, **`latency_ms`**, and **Anthropic prompt-cache usage** (**`cache_read_tokens`**, **`cache_creation_tokens`**) when the invoke response includes them; **`TrackBedrockQueryJob`** persists those fields and **`SimpleMetricsService`** folds cache-adjusted cost into **`CostMetric`** rollups (Batch-priced rows exist on `BedrockQuery` for Anthropic Batch–style estimates).

**Dashboard (tenant admin):** `/dashboard` shows **LLM consumption only** — cost today/month, chat query count, channel breakdown, calendar-month chart, KB documents, chat latency. **No** Aurora ACU, S3 infra, or AWS refresh in the UI. Scope and multi-tenant roadmap: [DASHBOARD.md](DASHBOARD.md).

**Home footer (web):** daily rollups are split by **billing channel** via `LlmUsageChannel` (app/services/llm_usage_channel.rb). The classifier maps each `bedrock_queries` row to one of the channels below using `source` + `model_id` suffix (`-direct`, `-batch`, Bedrock profile prefix). Legacy `daily_tokens_haiku` / `daily_tokens_parse_opus` / `daily_tokens_parse_sonnet` columns are still written (set to the same values as before cost_v2) for backward compatibility with any cached dashboard queries until those views are fully migrated.

#### LlmUsageChannel mapping

| Channel | `source` | `model_id` pattern | `CostMetric` enum |
|---------|----------|-------------------|-------------------|
| `bedrock_rag` | `query` | any | `daily_tokens_query` / `daily_cost_query` (existing) |
| `anthropic_haiku_direct` | `ingestion_parse` | `*haiku*-direct` | 20/21 |
| `anthropic_sonnet_direct` | `ingestion_parse` | `*sonnet*-direct` | 22/23 |
| `anthropic_opus_direct` | `ingestion_parse` | `*opus*-direct` | 24/25 |
| `anthropic_sonnet_batch` | `ingestion_parse` | `*sonnet*-batch` | 26/27 |
| `anthropic_opus_batch` | `ingestion_parse` | `*opus*-batch` | 28/29 |
| `bedrock_legacy_parse` | `ingestion_parse` | no suffix (TrackIngestionUsageJob estimate) | 30/31 |
| `bedrock_embed` | `ingestion_embed` | any | `daily_tokens_embed` / `daily_cost_embed` (existing) |

`model_id` suffixes written by each path:
- `ClaudeChunkingClient` (sync) → `-direct` (e.g. `claude-sonnet-4-6-direct`)
- `ManualBatchIngestionService` → `-batch` (e.g. `claude-sonnet-4-6-batch`)
- Bedrock invoke (RAG) → inference profile prefix (`us.anthropic.…` / `global.anthropic.…`)
- `TrackIngestionUsageJob` legacy estimate → raw model id, no suffix

| `source` | Meaning |
|----------|---------|
| `query` | End-user RAG / orchestrated LLM usage (**web chat** today; Twilio path would use the same `source` if re-enabled) |
| `ingestion_parse` | Parser tokens recorded after a document finishes KB ingestion. **Legacy path** writes an estimate (Opus); **`web_v1`** path skips the estimate (real `web_parse: …` rows already persisted by `ClaudeChunkingClient`). **cost_v2 paths:** `field_photo_v1` rows have `-direct` suffix; `manual_batch_v1` rows use batch pricing (no `-direct`; `user_query: "bulk_batch: <filename> p<N>/<M>"` for bulk PDFs, or `web_batch: …` for long PDFs uploaded through web/chat). |
| `ingestion_embed` | Estimated embedding tokens for chunk text indexed by the KB (Titan Text v2). Written after chat or bulk Bedrock sync completes. |

**Jobs & data:**

- **`TrackBedrockQueryJob`** (`queue: default`) — enqueued from `BedrockRagService` / `BedrockClient` after each real invocation, and from `ClaudeChunkingClient` / `PageRelevanceFilter` for direct Anthropic parse + slide-deck batch classification. Creates a `BedrockQuery` (including cache token columns when present), runs `SimpleMetricsService.update_database_metrics_only` (upserts `CostMetric` for the current day, including per-source tokens and cost), and **broadcasts** a Turbo Stream on the **`metrics`** channel so the **home** chat footer refreshes without reload.
- **`TrackIngestionUsageJob`** (`default`) — after `BedrockIngestionJob` (chat) or `PollBulkBedrockIngestionJob` (bulk) completes, estimates **Titan Text v2** embed tokens from chunk `.txt` files on S3 (`chunks_s3_prefix`). Legacy FM uploads also get an Opus parse estimate; `web_v1` / bulk custom chunking get **embed only** (parse already in `bedrock_queries`). Idempotency window covers both `[parse]` and `[embed]` user-query labels so retries don't double-write.
- **`TrackWhatsappCacheHitJob`** (`default`, **dormant**) — when the WhatsApp faceted path runs again, records cache-hit metrics into the same rollups.

**Solid Queue (`config/queue.yml`):** three worker **lanes** — **`default`** (short jobs), **`ingestion`** (`BedrockIngestionJob` poll loop), **`bulk_ingestion`** (ZIP → Claude Batch → KB sync polls). Isolating long polls keeps **`TrackBedrockQueryJob`** (home footer) responsive. In **Kamal production**, all lanes run in **one** `worker` container (see [Kamal production (AWS)](PRODUCTION.md)). Dedicated **`whatsapp_rag`** / **`whatsapp_media`** queues exist in code but are **not exercised** while the Twilio webhook stays unmounted; re-add dedicated processes if you restore the webhook and want isolation again.

| Queue | Example jobs | Role |
|-------|----------------|------|
| **`default`** | `TrackBedrockQueryJob`, `TrackIngestionUsageJob`, `TrackWhatsappCacheHitJob` (inactive), `KbDocumentEnrichmentJob`, `UploadAndSyncAttachmentsJob`, `DailyMetricsJob`, `SendWhatsappReplyJob` (not enqueued without WA) | Token persistence, footer Turbo updates, async enrichment, scheduled metric refresh |
| **`ingestion`** | `BedrockIngestionJob` | Long poll on Bedrock KB ingestion (≤ 15 min); legacy mode blocks one worker thread, `INGESTION_REENQUEUE=true` re-enqueues every 5s |
| **`bulk_ingestion`** | `ProcessBulkUploadJob`, `SubmitClaudeBatchJob`, `PollClaudeBatchJob`, `IngestBatchResultsJob`, `SubmitManualBatchJob`, `IngestManualBatchResultsJob`, `PollBulkBedrockIngestionJob` | Bulk ZIP extraction, web long-manual Batch lifecycle, Anthropic batch lifecycle, chunk ingest + Bedrock sync polls (2 threads in template config) |

**Production sizing (floors):** `RAILS_MAX_THREADS=5`, AR `pool=RAILS_MAX_THREADS+2` (auto), `AWS_HTTP_READ_TIMEOUT=90` (covers Aurora Serverless cold-start ≤ 60s). See `.env.sample` for the full block.

#### Pre-deploy runtime checklist (public web)

Verify each before flipping the public DNS:

1. `QUERY_ROUTING_ENABLED` **absent or `false`** — keeps every web request on the KB lane (no extra `invoke_model` for routing). Code default in `QueryOrchestratorService.query_routing_enabled?`.
2. `BEDROCK_RERANKER_ENABLED` **absent or `false`** — Cohere Rerank is disabled by default. The [2026-06-09 RAG benchmark](RAG_QUALITY_BENCHMARK_2026-06-09.md) found recall regressions at 15→9 and 15→12; rerun that quality gate before enabling it.
3. `SHARED_SESSION_ENABLED` set explicitly (`true` for the pilot single-thread, `false` for per-user). The default-when-unset is `false` in `Rails.env.production`.
4. **`ANTHROPIC_API_KEY`** (or **`credentials.dig(:anthropic, :api_key)`**) — **required** for **`/bulk_uploads`** (Anthropic Message Batches via `ClaudeBatchClient`). Separately, omitting it falls back to `LocalTokenizer` for **`AnthropicTokenCounter`** on chat metrics (chars/3.5, ±5%); counting runs inside **`TrackBedrockQueryJob`**, so a slow Anthropic endpoint never blocks **`POST /rag/ask`**.
5. `INGESTION_REENQUEUE` ⇒ activate **after draining the Solid Queue** (legacy serialized jobs keep blocking until terminal otherwise).
6. `MissionControl::Jobs` (`/jobs`) credentials live in **`config/credentials.yml.enc`**, **not** in `.env` for the production process.
7. `/dashboard` — tenant usage view (LLM cost only); confirm Devise admin guard before public launch. See [DASHBOARD.md](DASHBOARD.md). Infra metrics (Aurora/S3) are platform-internal, not shown to tenants.
8. **`ANTHROPIC_API_KEY`** (required for web uploads) and **`BEDROCK_BULK_DATA_SOURCE_ID`** (no-chunking DS) — confirm both are set in Kamal before going live with uploads. Smoke-test one web upload (photo + PDF + Office) and one bulk ZIP before launch.

---

## Image telemetry event schemas (O1′)

`image_compression` is emitted for every uploaded image; `field_photo_gate` only for images that proceed to parse after dedup/routing. Both are structured JSON lines to `Rails.logger.info`; neither creates a DB row. Together on the parse path, they carry the signals needed to cross-reference the KB-indexed parse cost in `bedrock_queries`.

### `image_compression` event

Emitted by `ImageCompressionService#log_compression_event` on **both** the skip path and the compress path. The `output_blob` used to derive `output_correlation_id` is `decoded_blob` on skip and `compressed_blob` on compress — so the key always refers to the binary that the caller will upload to S3 or forward to the gate.

| Field | Type | Notes |
|-------|------|-------|
| `event` | `"image_compression"` | constant |
| `skipped` | boolean | `true` when `decoded.bytesize <= MAX_BINARY_BYTES` (3.75 MB) — no Vips resize ran |
| `skip_reason` | String \| null | `"bytes<=3932160"` when skipped, else null |
| `media_type` | String | original MIME type |
| `bytes_before` | Integer | decoded binary size |
| `bytes_after` | Integer | output binary size (equals `bytes_before` when skipped) |
| `width_before` | Integer \| null | header-only; null on unrecognised format |
| `height_before` | Integer \| null | |
| `width_after` | Integer \| null | equals `width_before` when skipped |
| `height_after` | Integer \| null | |
| `max_dimension` | Integer | `ImageCompressionService::MAX_DIMENSION` (1024) |
| `max_binary_bytes` | Integer | `ImageCompressionService::MAX_BINARY_BYTES` (3 932 160) |
| `resize_applied` | boolean | `true` only on compress path AND Vips reduced at least one dimension |
| `output_correlation_id` | String | `"ingest:<sha12>"` — SHA-256 of `output_blob`[0,12]; **always present on both paths** |
| `filename` | String | optional; present when caller supplies it |
| `correlation_id` | String | optional; `"ingest:<sha12>"` of the source file; **bulk path only** |

### `field_photo_gate` event

Emitted by `FieldPhotoDensityGate#log_gate_decision` after the Sonnet/Opus routing decision.

| Field | Type | Notes |
|-------|------|-------|
| `event` | `"field_photo_gate"` | constant |
| `filename` | String | passed by caller |
| `route` | `"sonnet"` \| `"opus"` | the routing decision |
| `model` | String | `BatchChunkingPrompt::MODEL_TEXT` (sonnet) or `MODEL_MULTIMODAL` (opus) |
| `bytes` | Integer | binary size entering the gate |
| `threshold` | Integer | `LARGE_PHOTO_THRESHOLD` (1 500 000) |
| `width` | Integer \| null | header-only |
| `height` | Integer \| null | |
| `format` | String \| null | Vips loader string or content_type fallback |
| `content_type` | String | |
| `correlation_id` | String | optional; present when caller supplies it (see join chains below) |

### Join chains

The two events plus `bedrock_queries` can be joined per-photo depending on the ingestion path:

**Web path** (`RagController` → `SingleFileChunkingService`):

```
image_compression.output_correlation_id
  == field_photo_gate.correlation_id          ← SingleFileChunkingService#correlation_id = "ingest:#{@sha256[0,12]}"
  == bedrock_queries.correlation_id
```

`image_compression.correlation_id` is **absent** on the web path (no source sha exists pre-S3).

**Bulk path** (`BatchIngestionService` → `BulkCostV2RequestBuilder`):

```
image_compression.correlation_id
  == field_photo_gate.correlation_id          ← "ingest:#{asset.sha256[0,12]}"
  == bedrock_queries.correlation_id           ← IngestBatchResultsJob uses asset.sha256
```

`image_compression.output_correlation_id` is still present (SHA of compressed binary) but is **not** the reliable join key on the bulk path — use `correlation_id` instead.

`filename` is **auxiliary only** — not a reliable join key across ingestion runs.

### Offline inspection recipe

```bash
# image_compression events (CSV: correlation_id, output_correlation_id, filename, resize_applied, bytes_before, bytes_after)
grep '"event":"image_compression"' log/development.log | \
  jq -r '[.correlation_id, .output_correlation_id, .filename, .resize_applied, .bytes_before, .bytes_after] | @csv'

# field_photo_gate events (CSV: correlation_id, model, route, bytes)
grep '"event":"field_photo_gate"' log/development.log | \
  jq -r '[.correlation_id, .model, .route, .bytes] | @csv'

# join to DB cost (Rails console)
# BedrockQuery.where("correlation_id LIKE 'ingest:%'").pluck(:correlation_id, :model_id, :cost_usd)
```

To join image telemetry to parse cost, match `output_correlation_id` (web) or `correlation_id` (bulk) against `bedrock_queries.correlation_id`.

---

##### p95 latency alarm (raw SQL, no extra service required)

```sql
SELECT percentile_cont(0.95) WITHIN GROUP (ORDER BY latency_ms)
FROM bedrock_queries
WHERE created_at >= NOW() - INTERVAL '1 hour'
  AND source = 'query';
```

Suggested alert threshold: **> 8 000 ms** sustained for 15 min (cron job → Slack/PagerDuty).

**Web metrics:** every async metrics write and Turbo broadcast for the home footer runs on **`default`**. **`DailyMetricsJob`** still collects Aurora/S3 rollups for **platform ops** (rake tasks, scheduled jobs) — not exposed on the tenant dashboard.

For local development, run **`bin/dev`** (see `Procfile.dev`) so **web**, **CSS**, and **Solid Queue workers** are all up; otherwise enqueued metrics jobs will not run and the footer will look stale.
