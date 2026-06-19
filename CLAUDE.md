# Danebo RAG — Engineering Guidelines

**Canonical product/build scope:** README.md § *Product scope (current build)* — **live channel is signed-in web** (RAG home, KB list, uploads). **WhatsApp / Twilio is dormant:** inbound webhook **not mounted** (`config/routes.rb`), WA-specific jobs **not enqueued** on the default setup; legacy stack stays in-repo for reactivation (see README). Default implementation work assumes **web** unless explicitly reviving WA.

## Role
Senior Rails 8.1+ engineer. Stack: Hotwire (Turbo/Stimulus) + Importmap,
Tailwind (watcher runs via bin/dev), Solid Queue/Cache/Cable (no Redis),
SQLite (app) + PostgreSQL (client business DB), AWS Bedrock (RAG + Text-to-SQL),
**Twilio/WhatsApp code paths dormant** (see README), Minitest. Ruby 3.3+, Rails 8.1.2.

## Product lens
End user is a field elevator technician on the **web app** (tablet or phone): harsh light,
gloves, flaky connectivity. Judge every change by: clarity, minimal typing,
idempotency, perceived latency. Prefer semantic names/aliases over raw
filenames. Optimize for technician UX, not just technical correctness.
WhatsApp-era UX constraints below apply **when** that channel is re-wired — do not gate web-only changes on WA behavior unless touching shared RAG/session code WA will reuse.

## Response style (token + latency budget)
- Direct, technical shorthand. No filler, no narration of what you're about
  to do, no trailing "summary of changes".
- Ship only changed/new snippets; don't restate unchanged files.
- Assume expert reader; skip idiom explanations.
- No alternative gem/architecture suggestions unless the current one is broken.
- Exploring the repo: prefer targeted Grep/Read over reading large files
  end-to-end; parallelize independent lookups.

## Latency-first principles (primary design lens)
If a change worsens perceived latency, flag it.
- Never call Bedrock / Twilio / external APIs synchronously from a controller.
  ACK fast, offload to a Solid Queue job.
- Twilio/WhatsApp (**when webhook is active again**): reply with empty TwiML immediately; RAG/media runs in a job. While WA is dormant, do not assume `/twilio/webhook` traffic or WA queue isolation in production.
- Minimize round-trips: batch DB, use pluck/select, avoid N+1, keep
  transactions short, add indexes only where queries need them.
- Idempotency over retries — webhooks, job enqueues, S3 uploads must tolerate
  duplicates (cache keys, unique indexes, upserts).
- Preload session context (entities, recent history) once per turn; don't
  re-fetch inside services.
- Assume Aurora cold-start on the KB vector store — retries with backoff live
  in the RAG layer, not in callers.

## Architecture snapshot (follow the code if it has evolved past this)

Layering
- Flat services in app/services/, Bedrock helpers in app/services/bedrock/.
- Thin controllers → Service Objects → Models. AWS SDK out of models.
- Query Objects for non-trivial scopes. Prompts under app/prompts/.

Query orchestration
- QueryOrchestratorService classifies intent (DATABASE_QUERY /
  KNOWLEDGE_BASE_QUERY / HYBRID_QUERY) before any expensive work.
- HYBRID runs SQL + RAG in parallel threads and merges via LLM.
- RagQueryConcern is the shared RAG entry; **web** is the exercised path today. WhatsApp-specific branches are **collapsed / dormant** until the route and workers are restored (README architecture + dormant sections).

RAG query cost optimization (2026-05-22)
- **Canonical reconciled costs (2026-06-18):** `docs/SAAS_COST_MODEL_2026-06-12.md`.
  Recurring variable COGS is ~$9.54 expected / ~$13.27 conservative for 1,000
  queries + 200 photos. A 200-page manual is $5.32 one-time onboarding, never a
  monthly line. Historical benchmark projections are not current pricing inputs.
- **Exact spend authority (2026-06-19):** native Bedrock COGS comes from
  `bedrock_daily_costs` — `BedrockInvocationLogReconciler` reads exact billed
  tokens from S3 Model Invocation Logs; `ReconcileBedrockCostJob` persists per
  UTC day (daily 04:00; manual `bedrock:reconcile_logs[date]` /
  `bedrock:reconcile_persist[date]`). The `token_source: estimated` `BedrockQuery`
  rows are operational telemetry, NOT cost authority.
- **Inference profile:** `global.anthropic.claude-haiku-4-5-20251001-v1:0` — ~10% cheaper than `us.`, same model, higher throughput. Set via `BEDROCK_MODEL_ID`.
- **`RagRetrievalProfile`** (app/services/rag_retrieval_profile.rb): adaptive `number_of_results` from pin signal and intent. Photos-only→10, docs/mixed focused→3, stop/failure/repair→5, no-pin→8, exhaustive checklist→15 candidates (optionally reranked to 12). Derived from the URI-aligned pinned entity subset in `QueryOrchestratorService` with zero extra DB queries.
- **`stop_sequences: ["</DOC_REFS>"]`** in `textInferenceConfig`: cuts tail noise after the DOC_REFS block (~10–40 output tokens/query). `normalize_doc_refs_tag` re-appends the closing tag before `extract_doc_refs` so the regex always matches.
- **`fallback_retrieve`** (PR3): fixed entity filter bug — now scopes to `filtered_uris` when available, N=3 (was N=10). Only used for source_uri resolution, not generation context.
- **Language injection 3→2:** removed middle LANGUAGE & TONE bullet injection; kept TOP header + TAIL footer (~30–40 tokens/query saved).
- **RULE 8 compacted** in generation.txt: removed duplicate NEVER clauses + verbose CRITICAL block (~200 tokens/query saved).
- **`SessionContextBuilder::MAX_CONTEXT_CHARS = 2000`**: hard budget cap preventing runaway entity lists from blowing input cost.

Web upload ingestion (single path — no feature flags)
- `UploadAndSyncAttachmentsJob` → `QueryOrchestratorService#upload_and_sync_attachments` →
  `CustomChunkingPipeline` (the only path; no legacy OWRPGSX6XK fallback).
- `QueryOrchestratorService` passes `urgent: true` for every web/chat upload.
  Chat attachments always parse through sync cost-v2 Messages API; Anthropic
  Batch is reserved for `/bulk_uploads` backoffice/manual seeding.
- **Per-file routing in `CustomChunkingPipeline`:**
  - **Images:** `SingleFileChunkingService` sync → `FieldPhotoDensityGate` (size ≥1.5 MB → Opus, else Sonnet;
    zero LLM calls) → `FieldPhotoPrompt` compact explicit-evidence schema → `FieldPhotoResultsParser` →
    ingestion_path="field_photo_v1". Sonnet preserves visible labels, functions, connections, values, and
    warnings only when the photo explicitly documents them.
  - **Office (.docx/.pptx/…):** always sync → `SingleFileChunkingService#handle_office` (LibreOffice converts to PDF).
  - **PDFs:** sync via `SingleFileChunkingService` regardless of page count or query text.
    Long non-urgent PDF batch jobs remain in-repo as a dormant/manual path, not
    the active web/chat route.
  - **SHA dedup:** `ContentDedupService.find_completed(sha256:)` skips parse when binary already indexed.
- PDF pages filtered by `PageRelevanceFilter.filter_pages` — Haiku `call_batch` for multi-page PDFs (native or Office) splits into bounded windows (`BATCH_WINDOW_SIZE=20`, `MAX_WINDOW_BYTES=22MB`), per-page heuristic for single-page.
- Batch filter windows use dynamic `max_tokens`, retry once only on JSON parse/truncation failure, and keep-all only for the failed window on fallback.
- Per-page model: **Sonnet default**; Opus only for scanned/rasterized pages (`text_layer_chars<100` AND `image_ratio>0.7`). Same threshold as `PageRelevanceFilter#scanned_dense?`.
- Parallel page calls capped at `MAX_PARALLEL_PAGES=8` (wave processing, sync path).
- On error: propagates to job → `KbSyncBroadcaster.failed`; Solid Queue retries. No OWRPGSX6XK gasto.
- Cost tracking: web/chat parse rows use `TrackBedrockQueryJob` with `model_id`
  suffix `-direct` and `user_query: "web_parse: <filename>"` for files/pages.
  Bulk ZIP batch rows use the `-batch` pricing suffix.
- Office: `OfficeToPdfConverter` (LibreOffice headless). Alias fallback: `LambdaParityAliasFallback`.
- No new DB columns: ChunkAsset is a plain Struct (not AR). `ingestion_path="web_v1"` in sidecar metadata.
- **Full ADR + cost matrix:** `docs/INGESTION_COST_V2.md`. **Routing reference:** `docs/INGESTION_ROUTING.md`.
- TODO multi-tenant Stage 1: pass tenant from job.arguments into SingleFileChunkingService.

Bedrock / RAG
- retrieve_and_generate (HYBRID search) for answers; retrieve (vector only)
  for alias extraction.
- NEVER send raw image bytes to the LLM. Flow is S3 → KB ingestion.
- DOC_REFS protocol is the source of truth for document identity in answers;
  parse, don't infer.
- KB chunks carry **Document:** / **DOCUMENT_ALIASES:** headers (injected at
  parse + post-chunk). Preserve them.
- Config resolution: ENV → encrypted credentials → defaults.

Session / memory (3 layers)
- kb_documents — global S3 catalog (not user-scoped).
- technician_documents — durable per-technician memory, FIFO max 20,
  survives sessions.
- conversation_sessions.active_entities — JSONB working set (pins + auto-pins),
  capped (`MAX_ENTITIES`), FIFO eviction when over cap; session row TTL
  `EXPIRY_DURATION` (30 days, sliding via `refresh!`).
- When promoting/merging entities, preserve wa_filename if the prior key
  starts with wa_ (audit trail).
- conversation_history is capped + truncated; never grow it unbounded.

WhatsApp channel (dormant — preserve for re-launch; see README *WhatsApp / Twilio — decoupled*, *R3*, Ngrok/Twilio reactivation)
- **Status:** webhook **unmounted**, `whatsapp_rag` / `whatsapp_media` queues unused in practice; Twilio/`SendWhatsappReplyJob`/R3 cache stack remains in code, not the default architecture for new features.
- Idempotency via Solid Cache key twilio_msg:<MessageSid> (~24h).
- Reply chunks default ~1550 chars with a small gap between Twilio sends.
- Plain text + ① ② ③ / emojis. No Markdown tables (WhatsApp renders poorly).
- Media pipeline: ProcessWhatsappMediaJob → ruby-vips compress → S3
  (wa_YYYYMMDD_HHMMSS_N.ext) → KbSyncService → BedrockIngestionJob.
- conv_session_id flows through the entire job chain.
- Locale is sticky per-thread (Solid Cache, ~7d); short follow-ups inherit
  prior locale.
- Bedrock session_id is intentionally NOT forwarded for WhatsApp (stateless
  retrieval).

Jobs
- ActiveJob + Solid Queue (DB-backed). Assume retries; handlers must be
  idempotent.

Frontend
- Prefer Turbo Streams / frames over full redirects. Tailwind watcher is
  already running under bin/dev — don't re-run builds.

## Testing
- Minitest, not RSpec. No Mocha: stub with define_singleton_method
  (save + restore) or fake inner classes (FakeBedrockAgentClient,
  FakeS3Client, …).
- **`WHATSAPP_CHANNEL_DISABLED`** (test helper default `true`): classes whose name matches `Whatsapp` / `Twilio` are **skipped** unless `WHATSAPP_CHANNEL_DISABLED=false` — see README *Product scope*. Run WA suites only when touching a Twilio/WA relaunch.
- ActiveSupport::TestCase (services/models), ActiveJob::TestCase (jobs),
  ActionDispatch::IntegrationTest (controllers).
- parallelize(workers: 1) when tests touch global singletons, AWS clients,
  or Rails.cache.
- ConversationSessions: create! programmatically with unique identifier,
  never fixtures.
- ENV stubs: save in setup, restore in teardown/ensure.
- Verify with bin/rails test on the touched paths; full suite when touching
  shared services.

## Tenancy roadmap (heads-up)
MVP is a global shared pool (account_id = nil). Stage 1 adds account scoping
([account_id, canonical_name]); Stage 2 adds project scoping. When adding new
scoped behavior, leave a seam that maps cleanly to account_id / project_id
later — don't hard-code globals.

## Context-Specific Rules (apply when editing relevant paths)

### Rails Stack & Architecture (`app/**/*.rb`)
**Always apply to Ruby files:**
- Thin controllers → Service Objects → Models
- Prefer Rails-native patterns before external gems (Hotwire > SPA, Solid Stack > Redis)
- Prefer PORO services and Query Objects for retrieval/filtering
- Keep models free from infrastructure SDK logic
- Prefer explicit code over metaprogramming
- Service Objects flat in app/services/; Bedrock helpers in app/services/bedrock/
- Avoid unnecessary abstractions — premature enterprise architecture conflicts with MVP stage

### Frontend Rules (`app/views/**/*.erb` and `app/javascript/**/*.js`)
**Apply when editing templates or frontend code:**
- Optimize for mobile-first responsive UX for field technicians (harsh light, gloves, small screens)
- Prioritize fast perceived responsiveness
- Minimize frontend complexity; avoid SPA-like patterns
- Prefer Turbo Streams / frames over full redirects
- Prefer Turbo/Stimulus over custom JS
- Avoid unnecessary frontend state
- **UX priorities:** minimal typing, high clarity, low interaction friction, large tap targets, concise UI
- Tailwind watcher runs via bin/dev — don't re-run builds

### Bedrock & RAG Rules (`app/services/bedrock/**`, `app/services/rag/**`, `QueryOrchestratorService`, prompts)
**Apply when editing RAG/LLM integration code:**
- Prefer single-pass retrieval/generation flows
- Minimize retrieval payload size
- Prefer metadata filtering before semantic expansion
- Avoid unnecessary reranking
- Avoid chained LLM calls unless accuracy materially improves
- Minimize Bedrock round trips; reuse existing retrieval context whenever possible
- Prefer smaller high-relevance context windows over exhaustive expansion
- Optimize for production latency and token efficiency
- **Safety critical:** Never fabricate technical data; use DATA_NOT_AVAILABLE or REQUIRE_FIELD_VERIFICATION for missing/ambiguous data

### Performance Rules (applies to all code: `app/**/*.rb`, `app/**/*.js`)
**Latency-first optimization across the board:**
- Minimize Bedrock/API calls — no synchronous external API calls from controllers
- Minimize DB queries — use pluck/select/exists?, avoid N+1, avoid unnecessary ActiveRecord instantiation
- Avoid unnecessary orchestration, async jobs, fan-out architectures, polling, Turbo broadcasts, callbacks
- Prefer direct execution paths over complex routing
- Prefer deterministic Rails logic over additional LLM calls
- Keep database transactions short; add indexes only where queries need them
- Use jobs only for genuinely long-running work; keep user-facing request cycles minimal
- Hot request paths must be optimized; measure perceived latency first

## When to push back
If a request conflicts with latency-first, technician UX, idempotency, or
security (e.g. images to the LLM, Bedrock from a request), say so briefly
and propose the async/offloaded alternative.
