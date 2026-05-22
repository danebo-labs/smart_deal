# LLM usage metrics & Solid Queue lanes

Async token/cost tracking — Bedrock calls never wait on DB writes.

**Related:** [Production](PRODUCTION.md) · [README — Configuration flags](../README.md#configuration-flags)

---

### LLM usage metrics & Solid Queue

Model usage is recorded **asynchronously** so Bedrock calls never wait on DB writes or dashboard broadcasts. `bedrock_queries` stores each event with a **`source`** plus **`input_tokens`**, **`output_tokens`**, **`latency_ms`**, and **Anthropic prompt-cache usage** (**`cache_read_tokens`**, **`cache_creation_tokens`**) when the invoke response includes them; **`TrackBedrockQueryJob`** persists those fields and **`SimpleMetricsService`** folds cache-adjusted cost into **`CostMetric`** rollups (Batch-priced rows exist on `BedrockQuery` for Anthropic Batch–style estimates).

**Dashboard / home footer (web):** daily rollups split **Haiku** (RAG query lane) from **Parsing Opus (legacy)** and **Parsing Sonnet 4.6** (direct Anthropic parse on the custom chunking path). The "Opus (legacy)" pill is the **estimate** written by `TrackIngestionUsageJob` only on the legacy `OWRPGSX6XK` Bedrock-FM-parse data source; the custom chunking (`web_v1`) path records its parse tokens in real time as `claude-*-direct` rows from `ClaudeChunkingClient` and is **not** double-counted by the ingestion estimator. Legacy `daily_tokens_query` / `daily_cost_query` remain for backward compatibility; the home footer pills prefer the Haiku-specific columns when present.

| `source` | Meaning |
|----------|---------|
| `query` | End-user RAG / orchestrated LLM usage (**web chat** today; Twilio path would use the same `source` if re-enabled) |
| `ingestion_parse` | Parser tokens recorded after a document finishes KB ingestion. **Legacy path** writes an estimate (Opus); **`web_v1`** path skips the estimate (real `web_parse: …` rows already persisted by `ClaudeChunkingClient`). **cost_v2 paths:** `field_photo_v1` rows have `-direct` suffix; `manual_batch_v1` rows use batch pricing (no `-direct`; `user_query: "web_batch: <filename> p<N>/<M>"`). |
| `ingestion_embed` | Estimated embedding tokens for that upload (Nova multimodal). Always written for both paths. |

**Jobs & data:**

- **`TrackBedrockQueryJob`** (`queue: default`) — enqueued from `BedrockRagService` / `BedrockClient` after each real invocation, and from `ClaudeChunkingClient` / `PageRelevanceFilter` for direct Anthropic parse + slide-deck batch classification. Creates a `BedrockQuery` (including cache token columns when present), runs `SimpleMetricsService.update_database_metrics_only` (upserts `CostMetric` for the current day, including per-source tokens and cost), and **broadcasts** a Turbo Stream on the **`metrics`** channel so the **home** chat footer refreshes without reload.
- **`TrackIngestionUsageJob`** (`default`) — after `BedrockIngestionJob` completes, branches on the `web_v1_metadata` payload: legacy uploads get both an Opus parse estimate **and** a Nova embed estimate; `web_v1` uploads get **only** the Nova embed estimate (parse is already in `bedrock_queries` from the direct Claude path). Idempotency window covers both `[parse]` and `[embed]` user-query labels so retries don't double-write.
- **`TrackWhatsappCacheHitJob`** (`default`, **dormant**) — when the WhatsApp faceted path runs again, records cache-hit metrics into the same rollups.

**Solid Queue (`config/queue.yml`):** three worker **lanes** — **`default`** (short jobs), **`ingestion`** (`BedrockIngestionJob` poll loop), **`bulk_ingestion`** (ZIP → Claude Batch → KB sync polls). Isolating long polls keeps **`TrackBedrockQueryJob`** (home footer) responsive. In **Kamal production**, all lanes run in **one** `worker` container (see [Kamal production (AWS)](PRODUCTION.md)). Dedicated **`whatsapp_rag`** / **`whatsapp_media`** queues exist in code but are **not exercised** while the Twilio webhook stays unmounted; re-add dedicated processes if you restore the webhook and want isolation again.

| Queue | Example jobs | Role |
|-------|----------------|------|
| **`default`** | `TrackBedrockQueryJob`, `TrackIngestionUsageJob`, `TrackWhatsappCacheHitJob` (inactive), `KbDocumentEnrichmentJob`, `UploadAndSyncAttachmentsJob`, `DailyMetricsJob`, `SendWhatsappReplyJob` (not enqueued without WA) | Token persistence, footer Turbo updates, async enrichment, scheduled metric refresh |
| **`ingestion`** | `BedrockIngestionJob` | Long poll on Bedrock KB ingestion (≤ 15 min); legacy mode blocks one worker thread, `INGESTION_REENQUEUE=true` re-enqueues every 5s |
| **`bulk_ingestion`** | `ProcessBulkUploadJob`, `SubmitClaudeBatchJob`, `PollClaudeBatchJob`, `IngestBatchResultsJob`, `PollBulkBedrockIngestionJob` | Bulk ZIP extraction, Anthropic batch lifecycle, chunk ingest + Bedrock sync polls (2 threads in template config) |

**Production sizing (floors):** `RAILS_MAX_THREADS=5`, AR `pool=RAILS_MAX_THREADS+2` (auto), `AWS_HTTP_READ_TIMEOUT=90` (covers Aurora Serverless cold-start ≤ 60s). See `.env.sample` for the full block.

#### Pre-deploy runtime checklist (public web)

Verify each before flipping the public DNS:

1. `QUERY_ROUTING_ENABLED` **absent or `false`** — keeps every web request on the KB lane (no extra `invoke_model` for routing). Code default in `QueryOrchestratorService.query_routing_enabled?`.
2. `BEDROCK_RERANKER_ENABLED` **absent or `false`** — Cohere Rerank is disabled by default; toggle ON only after measuring impact in staging.
3. `SHARED_SESSION_ENABLED` set explicitly (`true` for the pilot single-thread, `false` for per-user). The default-when-unset is `false` in `Rails.env.production`.
4. **`ANTHROPIC_API_KEY`** (or **`credentials.dig(:anthropic, :api_key)`**) — **required** for **`/bulk_uploads`** (Anthropic Message Batches via `ClaudeBatchClient`). Separately, omitting it falls back to `LocalTokenizer` for **`AnthropicTokenCounter`** on chat metrics (chars/3.5, ±5%); counting runs inside **`TrackBedrockQueryJob`**, so a slow Anthropic endpoint never blocks **`POST /rag/ask`**.
5. `INGESTION_REENQUEUE` ⇒ activate **after draining the Solid Queue** (legacy serialized jobs keep blocking until terminal otherwise).
6. `MissionControl::Jobs` (`/jobs`) credentials live in **`config/credentials.yml.enc`**, **not** in `.env` for the production process.
7. `/dashboard` — confirm Devise role/admin guard before the public route flips, or accept that anonymous users see CostMetric rollups.
8. **`CUSTOM_CHUNKING_WEB_ENABLED`** — leave **off** until `BEDROCK_BULK_DATA_SOURCE_ID` (or equivalent no-chunking DS) and **`ANTHROPIC_API_KEY`** are set in Kamal; enable only after staging upload smoke tests.

##### p95 latency alarm (raw SQL, no extra service required)

```sql
SELECT percentile_cont(0.95) WITHIN GROUP (ORDER BY latency_ms)
FROM bedrock_queries
WHERE created_at >= NOW() - INTERVAL '1 hour'
  AND source = 'query';
```

Suggested alert threshold: **> 8 000 ms** sustained for 15 min (cron job → Slack/PagerDuty).

**Web metrics:** every async metrics write and Turbo broadcast for the home footer runs on **`default`**. **`DailyMetricsJob`** also refreshes database rollups for the dashboard when scheduled or triggered.

For local development, run **`bin/dev`** (see `Procfile.dev`) so **web**, **CSS**, and **Solid Queue workers** are all up; otherwise enqueued metrics jobs will not run and the footer will look stale.
