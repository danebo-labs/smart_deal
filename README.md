# Danebo RAG

RAG platform for **field elevator technicians**, delivered today through the **signed-in web app**: chat, knowledge-base documents, uploads, and pins. Optimized for **mobile**, **minimal typing**, and **flaky networks**.

## Product scope

- **Active:** web home (RAG chat, KB list, pins, thumbnails, chat uploads, bulk ZIP at `/bulk_uploads`).
- **Dormant:** WhatsApp / Twilio (webhook unmounted; code preserved). See [docs/WHATSAPP.md](docs/WHATSAPP.md).
- **Tests:** `WHATSAPP_CHANNEL_DISABLED=true` by default skips `Whatsapp`/`Twilio` test classes.

## Capabilities

| Area | Summary |
|------|---------|
| **RAG chat** | Bedrock Knowledge Base, hybrid orchestrator (optional Text-to-SQL) |
| **Chat uploads** | Legacy Bedrock FM parse, or **custom Claude chunking** when `CUSTOM_CHUNKING_WEB_ENABLED=true` — supports images, text, PDF, **Word, Excel, PowerPoint** (via LibreOffice) |
| **Cost-optimized parse** | Per-page 4 k cap + 16 k retry, **single Haiku call** to classify multi-page PDFs (covers, index, dedications dropped before parse), locale-aware summaries — see [WEB_CUSTOM_CHUNKING.md](docs/WEB_CUSTOM_CHUNKING.md). **Routing matrix:** [INGESTION_ROUTING.md](docs/INGESTION_ROUTING.md). **Cost v2 (2026-05-21 benchmark):** Sonnet default for images (↓5×), Anthropic Batch per-page for manuals (~50% off), SHA dedup — target ~$7-10/técnico/mes vs ~$60 legacy. `CUSTOM_CHUNKING_COST_V2_ENABLED=true`. Full ADR: [docs/INGESTION_COST_V2.md](docs/INGESTION_COST_V2.md) |
| **Bulk ZIP** | `/bulk_uploads` — Anthropic Message Batches, Turbo progress UI |
| **KB workspace** | Paginated doc list, pins, image lightbox, indexing status over Turbo |
| **Metrics** | Async token/cost rollups (Haiku + parse Opus/Sonnet, web_v1 vs legacy split), live chat footer |
| **Auth** | Devise |

Detail: [docs/ACTIVE_ARCHITECTURE.md](docs/ACTIVE_ARCHITECTURE.md).

## Quick start

```bash
git clone git@github.com:danebo-labs/smart_deal.git && cd smart_deal
brew install vips   # macOS; see Setup for Linux
echo 'THE_MASTER_KEY' > config/master.key
bin/setup --skip-server
# Fill .env from .env.sample
bin/dev
```

Open http://localhost:3000. `bin/dev` runs Rails + Tailwind (Foreman / `Procfile.dev`). Run **`bin/jobs start`** or include jobs in your dev process so Solid Queue handles uploads and metrics.

## Documentation map

| Topic | Document |
|-------|----------|
| **Index (start here for depth)** | [docs/ACTIVE_ARCHITECTURE.md](docs/ACTIVE_ARCHITECTURE.md) |
| **Ingestion routing** (file type, page filter, LLM matrix) | [docs/INGESTION_ROUTING.md](docs/INGESTION_ROUTING.md) |
| Web custom chunking (flags, pipeline) | [docs/WEB_CUSTOM_CHUNKING.md](docs/WEB_CUSTOM_CHUNKING.md) |
| Ingestion cost v2 ADR | [docs/INGESTION_COST_V2.md](docs/INGESTION_COST_V2.md) |
| Bulk ZIP ingestion | [docs/BULK_INGESTION.md](docs/BULK_INGESTION.md) |
| Production / Kamal / AWS | [docs/PRODUCTION.md](docs/PRODUCTION.md) (cold start/stop cheat sheet: [§ Cold start / cold stop](docs/PRODUCTION.md#cold-start--cold-stop--full-sequence-cheat-sheet)) |
| Bedrock KB & env | [BEDROCK_SETUP.md](BEDROCK_SETUP.md) |
| Pins & session retrieval | [docs/SESSION_AND_RETRIEVAL.md](docs/SESSION_AND_RETRIEVAL.md) |
| Home UI (KB card, lightbox) | [docs/WEB_HOME.md](docs/WEB_HOME.md) |
| Query orchestrator | [docs/QUERY_ORCHESTRATOR.md](docs/QUERY_ORCHESTRATOR.md) |
| Metrics & queues | [docs/METRICS.md](docs/METRICS.md) |
| WhatsApp (dormant) | [docs/WHATSAPP.md](docs/WHATSAPP.md) |
| Cursor / agent engineering rules | [CLAUDE.md](CLAUDE.md) |
| Multi-tenant roadmap | [docs/MULTI_TENANT_ARCHITECTURE.md](docs/MULTI_TENANT_ARCHITECTURE.md) |

## Stack

| Area | Technology |
|------|------------|
| App | Ruby ([`.ruby-version`](.ruby-version)), Rails 8.1.2, PostgreSQL |
| UI | Hotwire (Turbo, Stimulus), Tailwind, Importmap |
| Jobs / cache / cable | Solid Queue, Solid Cache, Solid Cable |
| AI | AWS Bedrock; Anthropic API for bulk ZIP + optional web chunking |
| Deploy | Kamal, Docker, EC2, RDS |

## Setup

### Prerequisites

- Ruby, Rails 8.1.2, PostgreSQL, libvips  
- **LibreOffice** — only if testing Office uploads with `CUSTOM_CHUNKING_WEB_ENABLED=true` (included in production Dockerfile)

### Secrets

| File | Purpose |
|------|---------|
| `.env` | Local secrets (from [`.env.sample`](.env.sample)) — never commit |
| `config/master.key` | Decrypt credentials — never commit |
| `config/deploy.yml` | Kamal (gitignored); copy from [`config/deploy.yml.example`](config/deploy.yml.example) |
| `.kamal/secrets` | Deploy secrets (gitignored) |

```bash
EDITOR="cursor --wait" bin/rails credentials:edit
```

Bedrock IDs and RAG knobs: [BEDROCK_SETUP.md](BEDROCK_SETUP.md). Pilot snapshot: `bin/rails kb:config`.

## Configuration flags

Restart **web and workers** after changing `.env`.

| Variable | Default | Notes |
|----------|---------|-------|
| `SHARED_SESSION_ENABLED` | off | MVP: one shared chat thread for all web users |
| `CUSTOM_CHUNKING_WEB_ENABLED` | off | Direct Claude parse for chat uploads — [doc](docs/WEB_CUSTOM_CHUNKING.md) |
| `CUSTOM_CHUNKING_COST_V2_ENABLED` | off | Sonnet photos + batch manuals + unified page filter — [routing](docs/INGESTION_ROUTING.md) · [ADR](docs/INGESTION_COST_V2.md) |
| `MANUAL_FORCE_SYNC` | off | Force sync parse for manual PDFs/Office (ops) |
| `FIELD_PHOTO_HAIKU_GATE_ENABLED` | off | Optional Haiku pre-gate on large/borderline field photos |
| `CUSTOM_CHUNKING_NO_FALLBACK` | off | Dev only: disable legacy fallback |
| `BEDROCK_BULK_DATA_SOURCE_ID` | optional | No-chunking data source for bulk ZIP + custom chunking |
| `ANTHROPIC_API_KEY` | — | Required for bulk ZIP and custom chunking |
| `INGESTION_REENQUEUE` | — | See [docs/PRODUCTION.md](docs/PRODUCTION.md) |

Full list including dormant WhatsApp flags: [`.env.sample`](.env.sample).

### MVP shared session

```bash
SHARED_SESSION_ENABLED=true
# SHARED_SESSION_IDENTIFIER=mvp-shared
# SHARED_SESSION_CHANNEL=shared
```

Per-user sessions: omit `SHARED_SESSION_ENABLED` or set `false`. In **test**, shared mode is forced off unless a spec stubs it.

## Usage

1. Sign in.
2. Upload from chat or use **`/bulk_uploads`** for a ZIP.
3. Ask questions; **pin** documents to scope retrieval; tap image thumbnails for full-size view.

## New engineer onboarding

1. Local app: [Quick start](#quick-start) above.  
2. Get from team (vault): `config/master.key`, `.env` template, `config/deploy.yml`, `.kamal/secrets`, SSH key.  
3. Production deploy: [docs/PRODUCTION.md](docs/PRODUCTION.md) (Docker, buildx, Kamal, troubleshooting).
4. Power‑cycling production (RDS + EC2 + Kamal in order): [docs/PRODUCTION.md § Cold start / cold stop](docs/PRODUCTION.md#cold-start--cold-stop--full-sequence-cheat-sheet).

## Development

- `bin/setup` installs deps and Git hooks (RuboCop on commit).  
- Useful tasks: `bin/rails kb:config`, `bin/rails kb:sync`, `bin/rails -T metrics:*`, `bin/rails solid_queue:purge_all` (see `lib/tasks/`).  
- Run full stack locally: `bin/dev` + workers so metrics and uploads work.

## Other references

- **Bedrock IAM:** `docs/bedrock-iam-policy.json`, `docs/AWS_IAM_PERMISSIONS.md`  
- **Image compression:** [docs/IMAGE_COMPRESSION.md](docs/IMAGE_COMPRESSION.md)  
- **Legacy architecture doc (may be stale):** [ARCHITECTURE.md](ARCHITECTURE.md)
