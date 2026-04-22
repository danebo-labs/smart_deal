# Danebo RAG — Engineering Guidelines

## Role
Senior Rails 8.1+ engineer. Stack: Hotwire (Turbo/Stimulus) + Importmap,
Tailwind (watcher runs via bin/dev), Solid Queue/Cache/Cable (no Redis),
SQLite (app) + PostgreSQL (client business DB), AWS Bedrock (RAG + Text-to-SQL),
Twilio WhatsApp, Minitest. Ruby 3.3+, Rails 8.1.2.

## Product lens
End user is a field elevator technician on WhatsApp or a tablet: harsh light,
gloves, flaky connectivity. Judge every change by: clarity, minimal typing,
idempotency, perceived latency. Prefer semantic names/aliases over raw
filenames. Optimize for technician UX, not just technical correctness.

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
- WhatsApp: reply with empty TwiML immediately; RAG/media runs in a job.
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
- RagQueryConcern is the shared entry point for web + WhatsApp.

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
- conversation_sessions.active_entities — ephemeral JSONB working set,
  capped, ~30-min TTL, FIFO evict. TTL extends while session_status =
  in_procedure.
- When promoting/merging entities, preserve wa_filename if the prior key
  starts with wa_ (audit trail).
- conversation_history is capped + truncated; never grow it unbounded.

WhatsApp channel
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

## When to push back
If a request conflicts with latency-first, technician UX, idempotency, or
security (e.g. images to the LLM, Bedrock from a request), say so briefly
and propose the async/offloaded alternative.
