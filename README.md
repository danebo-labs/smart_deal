# Danebo RAG

Platform that enables interaction and communication through RAG (Retrieval-Augmented Generation) across different communication channels, facilitating contextualized access to information based on a knowledge base.

## Features

- **User authentication** with Devise
- **Document processing**
- **AI document analysis – RAG** — AWS Bedrock, Knowledge Base, LLMs, embeddings, and prompt templates
- **Hotwire** for DOM updates (Turbo and Stimulus)
- **RAG chat with Knowledge Base integration** — LLMs, embeddings, prompt templates, and custom model configuration, optimized for inference and better results
- **Hybrid Query Orchestrator (RAG + Text-to-SQL)** — intelligent intent classification routes queries to the Knowledge Base, the client's business database, or both in parallel. Supports three modes: `DATABASE_QUERY`, `KNOWLEDGE_BASE_QUERY`, and `HYBRID_QUERY`
- **WhatsApp integration** via Twilio webhook — all query modes available through WhatsApp

## Setup

### Prerequisites

- Ruby (see `.ruby-version`)
- Rails 8.1.2
- SQLite3
- PostgreSQL (for client business database / Text-to-SQL)
- libvips (for image processing/compression)

### First-time installation

```bash
# 1. Clone the repo
git clone git@github.com:danebo-labs/smart_deal.git && cd smart_deal

# 2. Install libvips for image processing
# macOS:
brew install vips
# Ubuntu/Debian:
# sudo apt-get install libvips-dev

# 3. Get the master key from a team member, then:
echo 'THE_MASTER_KEY' > config/master.key

# 4. Run setup (installs deps, creates .env, prepares DB)
bin/setup --skip-server

# 5. Open .env and fill in your AWS keys and other secrets
#    (see .env.sample comments for guidance)

# 6. Start the server
bin/dev
```

`bin/dev` runs [Foreman](https://github.com/ddollar/foreman) with `Procfile.dev`, which starts:

- **web** — Rails server on port 3000
- **css** — Tailwind CSS watcher (rebuilds styles on change)

Foreman is installed automatically by `bin/dev` if missing.

Open http://localhost:3000 in your browser.

### Secrets management

ENV vars (`.env`) take priority in development. Rails encrypted credentials are the fallback (used in production where `.env` doesn't exist).

| File | Purpose |
|------|---------|
| `.env` | Your local secrets — loaded automatically, never committed |
| `.env.sample` | Template with all available variables and defaults |
| `config/credentials.yml.enc` | Encrypted secrets for production |
| `config/credentials.example.yml` | Template showing the credentials structure |

To edit encrypted credentials:

```bash
EDITOR="cursor --wait" bin/rails credentials:edit
```

> **Note:** `.env` and `config/master.key` are in `.gitignore`. Never commit them.

For detailed Bedrock configuration, see [BEDROCK_SETUP.md](BEDROCK_SETUP.md).

## Model Configuration



**Quick setup:**
1. Copy policy from `docs/bedrock-iam-policy.json`
2. AWS Console → IAM → Roles → `BedrockKnowledgeBaseRole-chat-bot`
3. Add permissions → Create inline policy → Paste JSON
4. Name: `BedrockModelInvokePermissions`
5. Save

See detailed instructions in `docs/AWS_IAM_PERMISSIONS.md`

### Image Compression

Images uploaded via the UI are automatically compressed before sending to Bedrock to meet the 10MB limit for Custom Data Sources:
- Resizes to max 1024x1024 pixels
- Converts to JPEG (80% quality)
- Skips compression for images < 500KB
- Validates final size doesn't exceed limits

See `docs/IMAGE_COMPRESSION.md` for technical details.

### Multi-Tenant Architecture (Roadmap)

The current architecture uses environment variables for configuration. The tenancy model will evolve in stages:

```
Stage 0 — MVP (current)
  Global shared document pool. All documents uploaded (via WhatsApp or web)
  are visible to all sessions. technician_documents scoped globally (account_id = nil).

Stage 1 — Multi-tenant
  Account (tenant) isolation. Each account has its own KB config, document pool,
  and Bedrock settings. technician_documents scoped by account_id.
  Configuration moves to database (bedrock_configs table).
  Per-tenant cost tracking and quotas.

Stage 2 — Multi-project
  A Project belongs to an Account and groups users across channels.
  Documents are scoped by project_id. A WhatsApp user and a web user
  in the same project share the same document pool.
  technician_documents scoped by [account_id, project_id].
```

`identifier` and `channel` remain on `conversation_sessions` for Twilio/web routing,
but they do **not** drive document deduplication — that is handled at the pool scope level.

See `docs/MULTI_TENANT_ARCHITECTURE.md` for design details.

## Usage

1. Sign up or sign in.
2. Upload a PDF document; the AI will analyze it and generate a summary.
3. Use the RAG chat to ask questions about documents indexed in the Knowledge Base.

## WhatsApp Integration (Twilio + Ngrok)

This section describes how to enable and test the integration between the Rails application and WhatsApp using Twilio (WhatsApp Sandbox) and Ngrok from a local environment.

### Overview

The application is integrated with WhatsApp via Twilio. Incoming WhatsApp messages are received by a webhook and trigger the app's RAG (Retrieval-Augmented Generation) flow, so users can query the knowledge base and get contextual answers through WhatsApp.

### Prerequisites

- Ruby on Rails application running locally
- Twilio account with access to the WhatsApp Sandbox
- Ngrok installed
- Rails server listening on port 3000

### Steps to Enable the Integration Locally

1. **Start the Rails application**

   Start the Rails server so it listens on `http://localhost:3000`:

   ```bash
   bin/dev
   ```

   Ensure the app is reachable at `http://localhost:3000` before continuing.

2. **Expose the application with Ngrok**

   In a new terminal tab, run Ngrok to expose your local server:

   ```bash
   ngrok http 3000
   ```

   Ngrok will display a public URL (e.g. `https://xxxxx.ngrok-free.dev`). This URL may change each time you start Ngrok.

3. **Configure the WhatsApp webhook in Twilio**

   - Open the Twilio Console: [https://console.twilio.com/us1/develop/sms/try-it-out/whatsapp-learn](https://console.twilio.com/us1/develop/sms/try-it-out/whatsapp-learn)
   - Go to **Develop → Messaging → Send a WhatsApp message**
   - In the **"When a message comes in"** section:
     - Paste your Ngrok public URL
     - Set the HTTP method to **POST**
     - Append the Rails webhook path so the full URL points to your app (e.g. `https://xxxxx.ngrok-free.dev/twilio/webhook`)

   Example of a complete webhook URL:

   ```
   https://xxxxx.ngrok-free.dev/twilio/webhook
   ```

   Replace `xxxxx` with your actual Ngrok subdomain.

4. **Add participants to the WhatsApp Sandbox**

   To allow users to interact with the app via WhatsApp:

   - Send a WhatsApp message to **+1 415 523 8886**
   - Send the exact text: `join having-week`

   After that, those users can send messages to the sandbox number and receive RAG responses from the application.

### Important Notes

- **Webhook URL updates:** Every time you restart Ngrok, the public URL changes. You must update the "When a message comes in" URL in the Twilio Console with the new Ngrok URL.
- **Development use:** This setup is intended for local development and testing. For production, use a stable public URL and follow Twilio's production WhatsApp requirements.
- **RAG flow:** Incoming WhatsApp messages hit the `/twilio/webhook` endpoint and trigger the application's RAG flow, which queries the knowledge base and replies via WhatsApp.

## Development

Run `bin/setup` to install dependencies, Git hooks, create `.env`, and prepare the database. The pre-commit hook runs RuboCop with autocorrect on staged Ruby files; fixes are staged automatically, and the commit is blocked if unfixable offenses remain (use `git commit --no-verify` to skip).

## Architecture

### Hybrid Query Orchestrator

The application uses an "orchestration first" pattern: a fast, cheap LLM call classifies the user's intent before any expensive operation (RAG retrieval, database query) runs. This avoids unnecessary work and routes to the optimal data source.

```mermaid
sequenceDiagram
    participant User
    participant Concern as RagQueryConcern
    participant Orchestrator as QueryOrchestratorService
    participant LLM as AiProvider/Bedrock
    participant RAG as BedrockRagService
    participant SQL as SqlGenerationService
    participant DB as ClientDatabase

    User->>Concern: question
    Concern->>Orchestrator: execute(question)
    Orchestrator->>LLM: classify intent (fast call)
    LLM-->>Orchestrator: DATABASE_QUERY / KNOWLEDGE_BASE_QUERY / HYBRID_QUERY

    alt DATABASE_QUERY
        Orchestrator->>SQL: execute
        SQL->>LLM: generate SQL from schema
        SQL->>DB: execute SQL (SELECT only)
        SQL->>LLM: synthesize answer
        SQL-->>Orchestrator: {answer, citations, session_id}
    else KNOWLEDGE_BASE_QUERY
        Orchestrator->>RAG: query(question)
        RAG-->>Orchestrator: {answer, citations, session_id}
    else HYBRID_QUERY
        Orchestrator->>SQL: execute (parallel thread)
        Orchestrator->>RAG: query (parallel thread)
        SQL-->>Orchestrator: DB result
        RAG-->>Orchestrator: KB result
        Orchestrator->>LLM: merge both answers
        LLM-->>Orchestrator: unified answer
    end

    Orchestrator-->>Concern: normalized result hash
    Concern-->>User: JSON (web) or TwiML (WhatsApp)
```

| Component | File | Responsibility |
|-----------|------|----------------|
| **QueryOrchestratorService** | `app/services/query_orchestrator_service.rb` | Intent classification and routing |
| **SqlGenerationService** | `app/services/sql_generation_service.rb` | Text-to-SQL generation, execution, and answer synthesis |
| **BedrockRagService** | `app/services/bedrock_rag_service.rb` | Knowledge Base retrieval and generation (RAG) |
| **ClientDatabase** | `app/models/client_database.rb` | Isolated DB connection to the client's business database |
| **RagQueryConcern** | `app/controllers/concerns/rag_query_concern.rb` | Shared query logic for all channels (web API, WhatsApp) |

For additional architecture details and design decisions, see [ARCHITECTURE.md](ARCHITECTURE.md).

### Session-Scoped KB Retrieval & Document Memory Architecture

Three interdependent storage layers track document context at different time horizons:

```
kb_documents         → "What exists in S3?"                       (global catalog, 1 row per file, admin dashboard)
technician_documents → "What has this technician used?"           (durable per-technician memory, survives sessions)
active_entities      → "What is the technician working on now?"   (session working set, 30-min TTL)
```

**`kb_documents`** — Global S3 catalog. One row per uploaded S3 key. Created on upload; enriched with `display_name`, `aliases`, and `size_bytes` as the pipeline processes the file. Powers the admin dashboard at `/dashboard`. Not scoped to any technician or session.

**`technician_documents`** — Durable document memory. Written in two stages: immediately after Bedrock ingestion completes (`BedrockIngestionJob` via `ChunkAliasExtractor`), and again after the first RAG response with enriched Haiku-derived aliases (`EntityExtractorService`). Tracks `interaction_count` for future relevance ranking. This is the source of truth that outlives sessions.

> **MVP scope:** The pool is global (`account_id = nil`). Deduplication is by `canonical_name` (or `source_uri`) across all uploaders — a document uploaded via WhatsApp and later via web is stored once. `identifier` and `channel` are preserved for audit but do not drive uniqueness.
> **Stage 1+:** `account_id` will be added; uniqueness becomes `[account_id, canonical_name]`. Stage 2 adds `project_id`.

**`conversation_sessions.active_entities`** — Session-scoped working set (JSONB, max 5 entities, 30-min TTL). Seeded from `technician_documents` on session creation (`preload_recent_entities`). Drives session-scoped KB retrieval filters so follow-up queries only search documents already active in the conversation.

The relationship is a **cache/source pattern**: `technician_documents` is the durable source; `active_entities` is the ephemeral working copy rebuilt from it on each new session. There is no `expired_at` on `technician_documents` because eviction is by space (FIFO max 20), not by time — a manual may be relevant weeks later when a technician returns to the same building.

#### Data flow: WhatsApp image upload → context

```
WhatsApp upload
  └─ S3 put_object
       └─ kb_documents.ensure_for_s3_key!  (display_name, size_bytes — immediate)
  └─ BedrockIngestionJob (polls until COMPLETE)
       ├─ kb_documents          ← enrich display_name + aliases (ChunkAliasExtractor)
       ├─ technician_documents  ← upsert_from_entity (immediate insert, no RAG query required)
       ├─ active_entities       ← add_entity_with_aliases
       └─ WhatsApp notify       ← canonical name sent back to technician

Technician asks follow-up question
  └─ retrieve_and_generate (session-scoped URI filter)
       └─ EntityExtractorService (doc_refs path)
            ├─ active_entities       ← promote/add entity
            ├─ technician_documents  ← upsert_from_entity (richer Haiku aliases)
            └─ kb_documents          ← merge aliases (up to 15)
```

#### Session-scoped retrieval filter logic

Before each `retrieve_and_generate` call, the system evaluates three conditions in order:

1. No active entities in session → search full KB (no filter).
2. Query ≤ 60 chars → apply URI filter. Short queries are unambiguous follow-ups.
3. Long query contains capitalized words not matching any session document → assume new document, search full KB.
4. Otherwise → apply URI filter.

If the filter returns no results (Bedrock guardrail), the system retries automatically against the full KB.

| Layer | Scope (MVP) | Scope (Stage 1+) | Eviction | Written by |
|---|---|---|---|---|
| `kb_documents` | Global | Global per account | Never | Upload + ingestion + RAG |
| `technician_documents` | Global pool (`account_id = nil`) | Per `[account_id, project_id]` | FIFO max 20 | Ingestion + RAG (EntityExtractor) |
| `active_entities` | Per session | Per session | 30-min TTL, max 5 | Ingestion + RAG, seeded from `technician_documents` |
