# LLM usage metrics & Solid Queue lanes

Async token/cost tracking — Bedrock calls never wait on DB writes.

**Related:** [Production](PRODUCTION.md) · [Ingestion routing](INGESTION_ROUTING.md) · [README — Configuration flags](../README.md#configuration-flags)

---

### LLM usage metrics & Solid Queue

Model usage is recorded **asynchronously** so Bedrock calls never wait on DB writes or dashboard broadcasts. `bedrock_queries` stores each event with a **`source`** plus **`input_tokens`**, **`output_tokens`**, **`latency_ms`**, and **Anthropic prompt-cache usage** (**`cache_read_tokens`**, **`cache_creation_tokens`**) when the invoke response includes them; **`TrackBedrockQueryJob`** persists those fields and **`SimpleMetricsService`** folds cache-adjusted cost into **`CostMetric`** rollups (Batch-priced rows exist on `BedrockQuery` for Anthropic Batch–style estimates).

#### Billing accuracy and authority

- `token_source: provider_usage` is exact for direct and normal batch-job parse.
- `token_source: estimated` is **operational attribution, not invoice truth**
  (live footer, latency/route telemetry, retrieval-regression). The historical
  reconciliation measured ~3.8% query-cost undercount across 20 real queries;
  hybrid compare-with-schematic queries can be larger outliers.
- **Authoritative Bedrock spend (since 2026-06-19) is log-exact:**
  `BedrockInvocationLogReconciler` reads the exact billed tokens from the S3
  Model Invocation Logs and `ReconcileBedrockCostJob` persists them per UTC day
  into `bedrock_daily_costs` (daily 04:00; manual `bedrock:reconcile_persist`).
  Use that table — not the estimated `BedrockQuery` rows — for COGS. The
  estimator's undercount no longer affects any reported cost.
- Provider invoice/cost export and Bedrock invocation logs override local rows.
- The reconciled package model is [SAAS_COST_MODEL_2026-06-12.md](SAAS_COST_MODEL_2026-06-12.md):
  ~$9.54 expected / ~$13.27 conservative recurring COGS and $5.32 one-time
  manual onboarding.

**Dashboard (tenant admin):** the implementation shows **LLM consumption only**
— cost today/month, chat query count, channel breakdown, calendar-month chart,
KB documents, and chat latency. The routes are disabled for the MVP pilot. See
[DASHBOARD.md](DASHBOARD.md).

**Home footer (web):** hidden by default and rendered only when
`SHOW_USAGE_METRICS=true`. When enabled, daily rollups are split by **billing
channel** via `LlmUsageChannel` (`app/services/llm_usage_channel.rb`). The
classifier maps each `bedrock_queries` row using `source` + `model_id` suffix
(`-direct`, `-batch`, Bedrock profile prefix). Legacy
`daily_tokens_haiku` / `daily_tokens_parse_opus` /
`daily_tokens_parse_sonnet` columns remain for backward compatibility.

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
| `query` | End-user RAG usage and direct live field-photo diagnosis (`route: visual_query`). Twilio would use the same source if re-enabled. |
| `ingestion_parse` | Parser tokens for content that becomes indexed knowledge. `web_v1` writes real `web_parse: …` rows; `manual_batch_v1` uses batch pricing. Preserved bulk image ingestion may still emit `field_photo_v1`, but live diagnostic photos do not. |
| `ingestion_embed` | Estimated embedding tokens for chunk text indexed by the KB (Titan Text v2). Written after chat or bulk Bedrock sync completes. |

**Jobs & data:**

- **`TrackBedrockQueryJob`** (`queue: default`) — enqueued from
  `BedrockRagService` / `BedrockClient`, direct field-photo analysis, and
  ingestion parse/filter clients. It creates a `BedrockQuery`, updates daily
  rollups, and broadcasts the optional metrics footer channel.
- **`TrackIngestionUsageJob`** (`default`) — after `BedrockIngestionJob` (chat) or `PollBulkBedrockIngestionJob` (bulk) completes, estimates **Titan Text v2** embed tokens from chunk `.txt` files on S3 (`chunks_s3_prefix`). Legacy FM uploads also get an Opus parse estimate; `web_v1` / bulk custom chunking get **embed only** (parse already in `bedrock_queries`). Idempotency window covers both `[parse]` and `[embed]` user-query labels so retries don't double-write.
- **`TrackWhatsappCacheHitJob`** (`default`, **dormant**) — when the WhatsApp faceted path runs again, records cache-hit metrics into the same rollups.

**Solid Queue (`config/queue.yml`):** three worker **lanes** — **`default`** (short jobs), **`ingestion`** (`BedrockIngestionJob` poll loop), **`bulk_ingestion`** (ZIP → Claude Batch → KB sync polls). Isolating long polls keeps **`TrackBedrockQueryJob`** (home footer) responsive. In **Kamal production**, all lanes run in **one** `worker` container (see [Kamal production (AWS)](PRODUCTION.md)). Dedicated **`whatsapp_rag`** / **`whatsapp_media`** queues exist in code but are **not exercised** while the Twilio webhook stays unmounted; re-add dedicated processes if you restore the webhook and want isolation again.

| Queue | Example jobs | Role |
|-------|----------------|------|
| **`default`** | `FieldPhotoAnalysisJob`, `TrackBedrockQueryJob`, `TrackIngestionUsageJob`, `KbDocumentEnrichmentJob`, `UploadAndSyncAttachmentsJob`, `DailyMetricsJob`, dormant WhatsApp jobs | Live photo diagnosis, token persistence, optional footer updates, enrichment, scheduled metrics |
| **`ingestion`** | `BedrockIngestionJob` | Long poll on Bedrock KB ingestion (≤ 15 min); legacy mode blocks one worker thread, `INGESTION_REENQUEUE=true` re-enqueues every 5s |
| **`bulk_ingestion`** | `ProcessBulkUploadJob`, `SubmitClaudeBatchJob`, `PollClaudeBatchJob`, `IngestBatchResultsJob`, `SubmitManualBatchJob`, `IngestManualBatchResultsJob`, `PollBulkBedrockIngestionJob` | Bulk ZIP extraction, web long-manual Batch lifecycle, Anthropic batch lifecycle, chunk ingest + Bedrock sync polls (2 threads in template config) |

**Production sizing (floors):** `RAILS_MAX_THREADS=5`, AR `pool=RAILS_MAX_THREADS+2` (auto), `AWS_HTTP_READ_TIMEOUT=90` (covers Aurora Serverless cold-start ≤ 60s). See `.env.sample` for the full block.

#### Pre-deploy runtime checklist (public web)

Verify each before flipping the public DNS:

1. `QUERY_ROUTING_ENABLED` **absent or `false`** — keeps every web request on the KB lane (no extra `invoke_model` for routing). Code default in `QueryOrchestratorService.query_routing_enabled?`.
2. `BEDROCK_RERANKER_ENABLED` **absent or `false`** — Cohere Rerank is disabled by default. The [2026-06-09 RAG benchmark](RAG_QUALITY_BENCHMARK_2026-06-09.md) found recall regressions at 15→9 and 15→12; rerun that quality gate before enabling it.
3. `SHARED_SESSION_ENABLED` set explicitly (`true` for the pilot single-thread, `false` for per-user). The default-when-unset is `false` in `Rails.env.production`.
4. **`ANTHROPIC_API_KEY`** (or
   **`credentials.dig(:anthropic, :api_key)`**) — required for live photo
   diagnosis and web document parsing. The bulk route is disabled in the MVP.
5. `INGESTION_REENQUEUE` ⇒ activate **after draining the Solid Queue** (legacy serialized jobs keep blocking until terminal otherwise).
6. `MissionControl::Jobs` (`/jobs`) credentials live in **`config/credentials.yml.enc`**, **not** in `.env` for the production process.
7. Keep `/dashboard` routes disabled for the MVP unless a separate authorization
   and tenant-scoping review explicitly re-enables them. See
   [DASHBOARD.md](DASHBOARD.md).
8. Confirm **`ANTHROPIC_API_KEY`** and **`BEDROCK_BULK_DATA_SOURCE_ID`** in Kamal.
   Smoke-test one live photo diagnosis and one indexed document upload. Bulk ZIP
   is not part of this preflight while its routes remain disabled.

---

## Image telemetry event schemas (O1′)

`image_compression` is emitted for uploaded images; `field_photo_gate` is emitted
for images that reach visual model routing, including live diagnostic photos.
Both are structured JSON log lines and do not create DB rows. Live diagnostic
cost is recorded separately in `bedrock_queries` with `source: query`,
`route: visual_query`, and a `photo:<uuid>` correlation ID.

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
| `white_ratio` | Float \| absent | Gate 9R O5-A: fraction of pixels with luma >240 on a ≤256px thumbnail (0.0–1.0, 3 decimals). High on line-art schematics; low on continuous-tone field photos. Absent when header/content signal fails. **Does not affect routing.** |
| `luma_mean` | Float \| absent | Gate 9R O5-A: mean luma on the same thumbnail (0–255, 1 decimal). Absent when header/content signal fails. **Does not affect routing.** |
| `correlation_id` | String | optional; present when caller supplies it (see join chains below) |

### Join chains

The two events plus `bedrock_queries` can be joined per-photo depending on the ingestion path:

**Indexed-image web path (legacy/preserved)** (`RagController` →
`SingleFileChunkingService`):

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

# field_photo_gate events (CSV: correlation_id, model, route, bytes, white_ratio, luma_mean)
grep '"event":"field_photo_gate"' log/development.log | \
  jq -r '[.correlation_id, .model, .route, .bytes, .white_ratio, .luma_mean] | @csv'

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

**Web metrics:** async metrics writes and the optional footer broadcast run on
`default`. The footer is absent unless `SHOW_USAGE_METRICS=true`.
`DailyMetricsJob` still collects Aurora/S3 rollups for platform operations.

For local development, run **`bin/dev`** (see `Procfile.dev`) so **web**, **CSS**, and **Solid Queue workers** are all up; otherwise enqueued metrics jobs will not run and the footer will look stale.

---

## Pilot interaction export and photo-cache telemetry

`BedrockQuery` remains the source of truth for every real LLM invocation. Live
photo rows use `source: query`, `route: visual_query` and carry account, user,
conversation and `photo:<uuid>` correlation attribution. A cache hit cannot be
stored there because its real tokens and cost are zero, so photo lifecycle
events use a safe structured line:

```text
[PILOT_USAGE] {"event":"photo_cache_hit","ts":"...","account_id":1,"user_id":2,...}
```

Emitted events are `photo_submitted`, `photo_cache_miss`, `photo_cache_hit`,
`visual_llm_call_avoided`, `photo_completed` and `photo_failed`. They contain no
raw image, Base64, temporary token, prompt or credentials. The only image join
field is the first 12 characters of the normalized SHA-256.

Run the daily export with a same-day log extract so zero-cost reuse is included:

```bash
kamal app logs --lines 20000 | grep -E 'PILOT_USAGE|RAG_QUALITY' > tmp/pilot.log
PILOT_USAGE_LOG=tmp/pilot.log bin/rails runner script/pilot_metrics_export.rb 2026-07-22
```

For an exact named pilot cohort, pass comma-separated IDs; account totals are
then computed only from those users and are not contaminated by internal smoke
activity on the same day:

```bash
PILOT_USER_IDS=21,22,23 PILOT_USAGE_LOG=tmp/pilot.log \
  bin/rails runner script/pilot_metrics_export.rb 2026-07-22
```

The report separates:

- `technical_and_cost`: real RAG/visual calls, tokens, model cost, latency,
  cache hit rate and estimated avoided cost by user and account;
- `adoption_signals`: active users/accounts, sessions and photo/query volume;
- `evidence_quality`: citations and evidence-present RAG results from
  timestamped `[RAG_QUALITY]` lines;
- `knowledge_gap_signals`: `DATA_NOT_AVAILABLE`,
  `REQUIRE_FIELD_VERIFICATION` and fast reformulations, filtered by each
  message timestamp;
- `commercial_outcomes`: explicitly `REQUIRES_MANUAL_SURVEY`, because
  time-to-resolution, avoided visits/escalations and technician confidence must
  be observed in the field rather than inferred from LLM usage.

Without a readable `PILOT_USAGE_LOG`, cache counts and avoided cost are `null`,
not fabricated. Messages with missing or invalid timestamps are excluded from
the day and reported under `data_quality`.
