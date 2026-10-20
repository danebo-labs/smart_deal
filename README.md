# Danebo RAG

RAG platform for **field elevator technicians**, delivered today through the **signed-in web app**: chat, knowledge-base documents, uploads, and pins. Optimized for **mobile**, **minimal typing**, and **flaky networks**.

## Product scope

- **Active MVP:** authenticated web home (RAG chat, KB list, pins,
  thumbnails, document uploads, and direct field-photo diagnosis).
- **Shared corpus:** without a pin, retrieval includes the technician's
  own chunks and the historical manuals of `danebo-legacy` and
  `danebo-pilot-elevator`. A new upload is not shared by slug.
  `danebo_general` is the catalog and pin mark. A pin is focus on the
  current session only. Contract:
  [docs/SESSION_AND_RETRIEVAL.md](docs/SESSION_AND_RETRIEVAL.md#shared-corpus-current-contract).
- **Disabled for the pilot:** bulk ZIP and dashboard routes; code is preserved.
- **Dormant:** WhatsApp / Twilio (webhook unmounted; code preserved). See
  [docs/WHATSAPP.md](docs/WHATSAPP.md).
- **Tests:** `WHATSAPP_CHANNEL_DISABLED=true` by default skips `Whatsapp`/`Twilio` test classes.

## Companion

The field Companion is part of the product by default. It is not an optional
capability and it will not keep a switch to turn it off. The target is to
remove the historical activation flags and the obsolete alternatives that
sit beside them. WhatsApp stays disabled. Capture, budget, retry,
authorization, and data-protection controls stay configurable.

That target is not the code at the current SHA. A normal boot still depends
on exported flags. Shared session blocks episode recording. The `.env`
observed in this checkout on 2026-10-20 sets `SHARED_SESSION_ENABLED=true`
and does not set the Companion flags. The deploy template sets Haiku mode
`conditional`; the path exercised by the phase harnesses and the VF5+ textual
pass is `owner`. Known equipment with `DOCUMENT_IDENTITY_SCOPE_ENABLED` unset
abstains before generation retrieval.

Canonical catalog, effects, and the retirement proposal:
**[docs/INVENTARIO_FLAGS_DE_COMPORTAMIENTO.md](docs/INVENTARIO_FLAGS_DE_COMPORTAMIENTO.md)**.

| Kind | What stays configurable |
|---|---|
| Channel | Web is the product session, one per user. WhatsApp stays unmounted. Shared session is incompatible with the Companion |
| Operation | Activity view, usage footer, batch thresholds, retention, dictation provider, local-pass budget |
| Protection | `PILOT_AUDIT_CAPTURE` for raw technician text. `PILOT_EVENTS_PERSIST` for the event insert |

## Capabilities

| Area | Summary |
|------|---------|
| **RAG chat** | Bedrock Knowledge Base, hybrid orchestrator (optional Text-to-SQL) |
| **Field-photo diagnosis** | Direct visual recognition for technician photos; diagnostic output remains separate from indexed organizational knowledge |
| **Retrieval fidelity** | Pins are the current session's evidence scope and the user can change them. A pinned miss does not silently reopen that session's unpinned corpus and does not change another account's catalog. Explicit source narrowing, adaptive retrieval budgets, and literal-label safety for photos stay as they are. Quality/cost baseline: [RAG benchmark 2026-06-09](docs/RAG_QUALITY_BENCHMARK_2026-06-09.md) |
| **Chat uploads** | Field photos use direct diagnosis; documents use Claude chunking via `CustomChunkingPipeline` — text, PDF, **Word, Excel, PowerPoint** (via LibreOffice); see [WEB_CUSTOM_CHUNKING.md](docs/WEB_CUSTOM_CHUNKING.md) |
| **Cost-optimized parse** | Per-page 8k cap with bounded 16k/32k retry, windowed Haiku filtering, Sonnet-default photo routing, automatic Batch for long manuals, and SHA dedup. Reconciled variable COGS: **~$9.54 expected / ~$13.27 conservative monthly** for 1,000 queries + 200 photos; a 200-page manual is **$5.32 one-time onboarding**. **Canonical model:** [SAAS_COST_MODEL_2026-06-12.md](docs/SAAS_COST_MODEL_2026-06-12.md). **Routing:** [INGESTION_ROUTING.md](docs/INGESTION_ROUTING.md) |
| **Bulk ZIP** | Anthropic Message Batches implementation preserved; `/bulk_uploads` routes are disabled for the MVP pilot |
| **KB workspace** | Paginated doc list, pins, image lightbox, indexing status over Turbo |
| **Metrics** | Async token/cost/latency attribution; the chat usage footer is shown only with `SHOW_USAGE_METRICS=true` |
| **Auth** | Devise |
| **Tenant branding** | Per-host logo, favicon, title, footer (`elevadores-climb` on `ascensoresclimb.danebo.ai`) — [docs/ACCOUNT_BRANDING.md](docs/ACCOUNT_BRANDING.md) |

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

Open http://localhost:3000. `bin/dev` runs Rails, Tailwind, and Solid Queue via
Foreman / `Procfile.dev`.

## Documentation map

| Topic | Document |
|-------|----------|
| **Complete documentation index** | [docs/README.md](docs/README.md) |
| **Behavior flags and Companion default** | [docs/INVENTARIO_FLAGS_DE_COMPORTAMIENTO.md](docs/INVENTARIO_FLAGS_DE_COMPORTAMIENTO.md) |
| Product stage and roadmap | [docs/PRODUCT_ROADMAP.md](docs/PRODUCT_ROADMAP.md) |
| Active architecture | [docs/ACTIVE_ARCHITECTURE.md](docs/ACTIVE_ARCHITECTURE.md) |
| Production / Kamal / AWS | [docs/PRODUCTION.md](docs/PRODUCTION.md) |
| Engineering rules | [AGENTS.md](AGENTS.md) and scoped `AGENTS.md` files |

## Stack

| Area | Technology |
|------|------------|
| App | Ruby ([`.ruby-version`](.ruby-version)), Rails 8.1+, PostgreSQL |
| UI | Hotwire (Turbo, Stimulus), Tailwind, Importmap |
| Jobs / cache / cable | Solid Queue, Solid Cache, Solid Cable |
| AI | AWS Bedrock; Anthropic API for bulk ZIP + optional web chunking |
| Deploy | Kamal, Docker, EC2, RDS |

## Setup

### Prerequisites

- Ruby, Rails 8.1+, PostgreSQL, libvips
- **LibreOffice** — only if testing Office uploads (included in production Dockerfile)

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

## Configuration

Behavior switches, their real defaults, and the Companion retirement proposal
live in one place:
**[docs/INVENTARIO_FLAGS_DE_COMPORTAMIENTO.md](docs/INVENTARIO_FLAGS_DE_COMPORTAMIENTO.md)**.
Do not keep a second default table here.

Restart **web and workers** after changing `.env`. `SHARED_SESSION_ENABLED`
and the knowledge-base bucket are read at boot.

Models, buckets, database names, and credentials stay in
[`.env.sample`](.env.sample) and [BEDROCK_SETUP.md](BEDROCK_SETUP.md).
`BEDROCK_BULK_DATA_SOURCE_ID` is the shared no-chunking data source and must
include only `bulk_chunks/`. `INGESTION_REENQUEUE` is documented in
[docs/PRODUCTION.md](docs/PRODUCTION.md).

## Usage

1. Sign in.
2. Take a field photo for direct diagnosis, or upload a document for indexing.
3. Ask questions; **pin** indexed documents to scope retrieval; tap image thumbnails for full-size view.

## New engineer onboarding

1. Local app: [Quick start](#quick-start) above.  
2. Get from team (vault): `config/master.key`, `.env` template, `config/deploy.yml`, `.kamal/secrets`, SSH key.  
3. Production deploy: [docs/PRODUCTION.md](docs/PRODUCTION.md) (Docker, buildx, Kamal, troubleshooting).
4. Power‑cycling production (RDS + EC2 + Kamal in order): [docs/PRODUCTION.md § Cold start / cold stop](docs/PRODUCTION.md#cold-start--cold-stop--full-sequence-cheat-sheet).

## Development

- `bin/setup` installs deps and Git hooks (RuboCop on commit).  
- Useful tasks: `bin/rails kb:config`, `bin/rails kb:sync`, `bin/rails -T metrics:*`, `bin/rails solid_queue:purge_all` (see `lib/tasks/`).  
- Run full stack locally: `bin/dev` + workers so metrics and uploads work.
- Tests: `bin/rails test`. The test DB user defaults to your OS user (Homebrew Postgres superuser) so fixtures with FKs can load. Do not set `DB_USERNAME=app_user` in `.env`.

## Other references

- **Bedrock IAM:** `docs/bedrock-iam-policy.json`
- **Image compression:** [docs/IMAGE_COMPRESSION.md](docs/IMAGE_COMPRESSION.md)  
- **Legacy architecture doc (may be stale):** [ARCHITECTURE.md](ARCHITECTURE.md)
