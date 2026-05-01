# Danebo RAG

Platform that enables interaction and communication through RAG (Retrieval-Augmented Generation), today **primarily via the signed-in web app**, with contextualized access to information from a knowledge base.

**Product context:** the primary user is a **field elevator technician** (machine rooms, hoistways, gloves, uneven light, **phone or tablet** in the field). Flows favor **minimal typing**, **clear labels**, and behavior that stays usable on **slow or flaky networks** (idempotent actions, cached navigation where safe).

## Product scope (current build)

- **Active channel:** signed-in **web** home — responsive layout, RAG chat, KB list, pins, and thumbnails/lightbox (see [Web home: responsive layout, KB card, and lightbox](#web-home-responsive-layout-kb-card-and-lightbox)).
- **WhatsApp / Twilio — decoupled (dormant):** the inbound webhook is **not mounted** (`config/routes.rb` comments out `post '/twilio/webhook'`). **`config/queue.yml`** runs a **single** Solid Queue worker lane (`default` only); `whatsapp_rag` / `whatsapp_media` workers were removed. Shared code paths (`RagQueryConcern`, `BedrockRagService`, `BedrockIngestionJob`, orchestrator) no longer drive a live **`:whatsapp`** RAG branch. **Legacy stack remains in the repo** for a future reactivation: `TwilioController`, `SendWhatsappReplyJob`, `ProcessWhatsappMediaJob`, `TrackWhatsappCacheHitJob`, `app/services/rag/whatsapp_*.rb`, models, locales, and DB tables are **not deleted** — treat them as **deprecated architecture** until re-wired.
- **Tests:** `test/test_helper.rb` sets **`WHATSAPP_CHANNEL_DISABLED`** (default `true` via `ENV.fetch`) and skips test classes whose name matches `Whatsapp` / `Twilio` (case-insensitive). Export **`WHATSAPP_CHANNEL_DISABLED=false`** to run those suites when working on a WA re-launch.

## MVP pilot (dry run / *marcha blanca*)

**Stage 0** is a controlled pilot to validate **minimum viable operation (MVO)** with a **single elevator-project knowledge base** and a **small group of field technicians** on the **web** app. The goal is not full multi-tenant product behavior yet, but to prove end-to-end flows: uploads, RAG answers, session context, and reliable KB-backed answers under real-ish usage.

**Typical MVO setup (web):** enable [**one shared `conversation_sessions` row**](#mvp-configuration-shared-conversation-session) (`SHARED_SESSION_ENABLED=true`) so the whole squad shares **one thread** of history and pinned `active_entities` while testing one KB.

For that pilot you can optionally run **one shared conversation session** for all signed-in **web** users: they resolve to the same `conversation_sessions` row (`identifier` + `channel` = shared). That lets the squad **see one continuous thread**—history, pins, and procedure state—while they stress-test queries against the same KB. See [MVP configuration: shared conversation session](#mvp-configuration-shared-conversation-session) below.

When shared session is **off**, each web user keeps a **separate** session (per `identifier` + `channel`), which is the default path toward later per-tenant / per-project isolation.

> **WhatsApp-era behavior (dormant):** when the Twilio channel was active, a per-number faceted answer cache ([R3](#whatsapp-answer-cache--follow-up-classifier-r3)) complemented `conversation_sessions`. That design is documented below for anyone reviving WA; it is **not** exercised by the default production or test configuration today.

## Features

- **User authentication** with Devise
- **Document processing**
- **AI document analysis – RAG** — AWS Bedrock, Knowledge Base, LLMs, embeddings, and prompt templates
- **RAG chat with Knowledge Base integration** — LLMs, embeddings, prompt templates, and custom model configuration, optimized for inference and better results
- **Hybrid Query Orchestrator (RAG + Text-to-SQL)** — intelligent intent classification routes queries to the Knowledge Base, the client's business database, or both in parallel. Supports three modes: `DATABASE_QUERY`, `KNOWLEDGE_BASE_QUERY`, and `HYBRID_QUERY`
- **Responsive web home** — Tailwind breakpoints (`sm:`, `lg:`): chat input **stacks on narrow viewports** (attach + send row under the textarea), **usage metrics** in the chat footer use `hidden sm:flex` so they stay off small screens, and the **KB area** follows the same mobile/desktop rules as the rest of the grid.
- **Unified KB documents card** — one partial stack for **desktop sidebar** and **mobile** strip (`_kb_docs_card`, `_kb_docs_card_rows`, `_kb_docs_card_sentinel`). Same row chrome (thumbnail slot, title, date, pin affordance) everywhere; legacy sidebar overview cards (“Archivos en la sesión” / recientes) were **removed**. `data-controller="rag-chat"` sits on the **home grid** in `index.html.erb` so sidebar rows share Stimulus with the chat column.
- **KB list pagination & live refresh** — `HomeController::PAGE_SIZE` (20), `GET /home/documents` and `GET /home/documents_page` return Turbo Streams that update **both** `#kb-docs-desktop-items` and `#kb-docs-mobile-items`; `docs_scroll_controller.js` uses an **IntersectionObserver** sentinel for infinite scroll.
- **Indexing UX** — after a file upload from chat, a **three-dot loading** bubble (`addLoadingMessage` in `rag_chat_controller.js`) replaces the old long system string until `KbSyncChannel` reports **indexed** or **failed**, then the doc list refreshes.
- **LLM usage metrics** — async tracking of Bedrock tokens by **source** (`query` vs ingestion parse/embed), optional **WhatsApp cache hit** accounting when that channel is re-enabled, daily rollups in `cost_metrics`, and a **live home footer** updated via Turbo Streams on the **`default`** Solid Queue lane (see [LLM usage metrics & Solid Queue](#llm-usage-metrics--solid-queue))
- **Full-size image lightbox (KB thumbnails)** — tapping the thumbnail on an **image** row (PNG/JPEG/GIF/WebP) opens a **lightbox** with the full object from S3. The browser loads the file via a **presigned GET URL** embedded at render time (`KbDocumentImageUrlService`), so the click does **not** round-trip through Rails. The inline thumbnail is reused as an instant **blur-up** placeholder until the full image loads. Close with ✕, backdrop click, **Escape**, swipe-down on mobile, or the browser **Back** button. Clicking the **rest of the row** still toggles **pin to chat** (RAG context); only the thumbnail opens the lightbox. See [Web home: responsive layout, KB card, and lightbox](#web-home-responsive-layout-kb-card-and-lightbox).
- **Pinned KB documents (web workspace)** — the home KB list rows drive **server-side pins** (`POST`/`DELETE` `/pinned_documents`, Stimulus in `rag_chat_controller.js`). `ConversationSession#active_entities` holds **only** explicit pins and **auto-pins** for files uploaded in the current chat when `BedrockIngestionJob` finishes. Those S3 URIs scope Bedrock retrieval (`force_entity_filter` when any pin exists). Catalog enrichment from Haiku `<DOC_REFS>` is **`KbDocumentEnrichmentService`** only (it does **not** add pins). **`SessionContextBuilder`** adds **Session Focus**, **Recent Conversation**, and **Session Discipline** to the prompt. See [Web workspace: pinned KB documents & Bedrock retrieval](#web-workspace-pinned-kb-documents--bedrock-retrieval).

## Stack

Engineering snapshot of what powers the app (complement to [Setup](#setup) and [Architecture](#architecture)).

| Area | Technologies |
|------|----------------|
| **Runtime** | Ruby (see [`.ruby-version`](.ruby-version)), **Rails 8.1.2** |
| **Web UI** | Server-rendered **ERB**; [**Hotwire**](https://hotwired.dev/) — **Turbo** (including Turbo Streams for live DOM updates) and **Stimulus** for small controllers in `app/javascript/controllers/` |
| **Frontend delivery** | [**Importmap**](https://github.com/rails/importmap-rails) — JavaScript modules pinned in `config/importmap.rb` without a Node bundler on the default path |
| **CSS** | [**Tailwind CSS**](https://tailwindcss.com/) (watcher via `bin/dev` / `Procfile.dev`) |
| **Pattern** | **HTML over the wire**: responses are mostly HTML/Turbo from Rails, not a separate SPA framework (React/Vue) |
| **Jobs** | **Active Job** backed by [**Solid Queue**](https://github.com/rails/solid_queue) (database-backed; no Redis for queues) |
| **Cache** | [**Solid Cache**](https://github.com/rails/solid_cache) (`Rails.cache` — e.g. `kb_thumb:*` thumbnail bridge keys; dormant WA faceted cache keys when Twilio is re-enabled) |
| **Real-time** | [**Solid Cable**](https://github.com/rails/solid_cable) + **Action Cable** for Turbo Stream broadcasts |
| **App database** | **PostgreSQL** — primary schema plus separate DBs for queue, cache, and cable (see `config/database.yml`) |
| **Client / Text-to-SQL DB** | **PostgreSQL** in development and production; **SQLite** file (`storage/client_test.sqlite3`) for the isolated `client_db` connection in **test** only |
| **AI / RAG** | **AWS Bedrock** (Knowledge Bases, retrieve-and-generate, model invocation) — see [BEDROCK_SETUP.md](BEDROCK_SETUP.md) |
| **Messaging** | **Twilio** (`twilio-ruby` still bundled; inbound **WhatsApp webhook not mounted** — see [Product scope](#product-scope-current-build)) |
| **Auth** | **Devise** |
| **Tests** | **Minitest** (Rails default) |

## Setup

### Prerequisites

- Ruby (see `.ruby-version`)
- Rails 8.1.2
- SQLite3 (used only for the isolated **client** Text-to-SQL DB in **test**; see [Stack](#stack))
- PostgreSQL (application DB, Solid DBs, and client business database / Text-to-SQL in dev and production)
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

For detailed Bedrock configuration (models, KB, env vars), see [BEDROCK_SETUP.md](BEDROCK_SETUP.md) and `.env.sample`.

### MVP configuration: shared conversation session

Use these **only for the MVP pilot** when you want a **single shared thread** for all **web** technicians. Values are read at boot from `.env` (see `.env.sample`).

| Variable | Purpose |
|----------|---------|
| `SHARED_SESSION_ENABLED` | Set to `true` to collapse every lookup to one session row. Omit or set to `false` for normal per-user web sessions. |
| `SHARED_SESSION_IDENTIFIER` | Stable DB key for that row (default `mvp-shared`). Change if you need a new shared row without touching data. |
| `SHARED_SESSION_CHANNEL` | Channel value stored on the row (default `shared`). Must stay in sync with app validation (`ConversationSession::CHANNELS`). |
| `SESSION_MAX_ENTITIES` | Optional. Caps how many pinned entries fit in `active_entities` (default **10** in code if unset). |

Example for a pilot box:

```bash
SHARED_SESSION_ENABLED=true
# SHARED_SESSION_IDENTIFIER=mvp-shared
# SHARED_SESSION_CHANNEL=shared
# SESSION_MAX_ENTITIES=10
```

**Web RAG:** When shared mode is on, the web `RAG` controller passes **`user_id: nil`** on that row so the shared session is not “owned” by whichever web user asked last.

#### MVO pilot: how to enable / disable environment flags

Rails loads `.env` when each process **starts**. After changing any flag, restart the **web** process **and** Solid Queue **workers** (e.g. restart `bin/dev`), or the old `ENV` values remain in memory.

| Variable | Default when unset | Turn **ON** | Turn **OFF** |
|----------|-------------------|-------------|---------------|
| `SHARED_SESSION_ENABLED` | off | `SHARED_SESSION_ENABLED=true` in `.env` | `false` or remove the line |
| `SHARED_SESSION_IDENTIFIER` | `mvp-shared` (only when shared is on) | optional override in `.env` | ignored when shared is off |
| `SHARED_SESSION_CHANNEL` | `shared` (only when shared is on) | optional; must stay in `ConversationSession::CHANNELS` | ignored when shared is off |
| `SESSION_MAX_ENTITIES` | **10** in code | set an integer in `.env` | remove to use default |
| `WA_FACETED_OUTPUT_ENABLED` | **on** (ignored while WA dormant) | `true` or omit | `false` → would select `perform_legacy` if Twilio path runs again |
| `WA_PROCESSING_ACK_ENABLED` | **on** (ignored while WA dormant) | `true` or omit | `false` → would suppress processing ack if Twilio path runs again |

Use [`.env.sample`](.env.sample) as the checklist; copy lines into `.env` (never commit `.env`).

### Post-MVP session configuration (per-technician isolation)

When moving past the single-thread pilot:

1. Set `SHARED_SESSION_ENABLED=false` or **remove** it from `.env` (default is off).
2. Leave `SHARED_SESSION_IDENTIFIER` / `SHARED_SESSION_CHANNEL` unset unless you have a special reason; they are ignored when shared mode is off.
3. Tune `SESSION_MAX_ENTITIES` if you want a smaller or larger cap on pinned `active_entities` (still bounded by model / prompt limits).

Each **web** user identity again gets **their own** `conversation_sessions` row (same as pre–shared-session behavior).

### Automated tests and `SharedSession`

In **`Rails.env.test?`**, `SharedSession::ENABLED` is **forced to `false` at load time**, even if your local `.env` sets `SHARED_SESSION_ENABLED=true` (dotenv-rails loads `.env` in test). That keeps the suite **deterministic**: examples assume **isolated** sessions unless they explicitly opt into shared behavior.

Specs that need shared mode **temporarily flip** the constant inside the example (e.g. `stub_shared_enabled(true)` in `conversation_session` and `rag_controller` tests). Do not rely on ENV alone in test for global shared mode. **Twilio / WhatsApp** examples are **skipped by default** — see [Product scope](#product-scope-current-build).

### Bedrock IAM (quick reference)

1. Copy policy from `docs/bedrock-iam-policy.json`
2. AWS Console → IAM → Roles → `BedrockKnowledgeBaseRole-chat-bot`
3. Add permissions → Create inline policy → Paste JSON
4. Name: `BedrockModelInvokePermissions`
5. Save

See `docs/AWS_IAM_PERMISSIONS.md` for full instructions.

### Image compression

Images uploaded via the UI are automatically compressed before sending to Bedrock to meet the 10MB limit for Custom Data Sources:
- Resizes to max 1024x1024 pixels
- Converts to JPEG (80% quality)
- Skips compression for images < 500KB
- Validates final size doesn't exceed limits

See `docs/IMAGE_COMPRESSION.md` for technical details.

### Multi-tenant architecture (roadmap)

The current architecture uses environment variables for configuration. The tenancy model will evolve in stages:

```
Stage 0 — MVP (current)
  Global shared document pool. Documents uploaded via **web** chat (Twilio path dormant)
  are visible to all sessions. technician_documents scoped globally (account_id = nil).
  Optional: SHARED_SESSION_ENABLED — one conversation_sessions row for every web identity
  in the pilot. Default off: one session per web user.

Stage 1 — Multi-tenant
  Account (tenant) isolation. Each account has its own KB config, document pool,
  and Bedrock settings. technician_documents scoped by account_id.
  Configuration moves to database (bedrock_configs table).
  Per-tenant cost tracking and quotas.

Stage 2 — Multi-project
  A Project belongs to an Account and groups users across channels.
  Documents are scoped by project_id. Users across channels in the same project
  share the same document pool (when secondary channels exist again).
  technician_documents scoped by [account_id, project_id].
```

`identifier` and `channel` remain on `conversation_sessions` for routing (today: **web** / **shared**),
but they do **not** drive document deduplication — that is handled at the pool scope level.

See `docs/MULTI_TENANT_ARCHITECTURE.md` for design details.

### WhatsApp (Twilio + Ngrok) — dormant / reactivation

> **Current build:** inbound WhatsApp is **not** wired (`post '/twilio/webhook'` commented in `config/routes.rb`). The steps below are the **historical** procedure to turn the channel back on after restoring the route, queue workers, and collapsed code branches.

This section describes how **Twilio WhatsApp Sandbox + Ngrok** were used to exercise the app before the WA decouple.

#### Overview

When enabled, the app received WhatsApp messages via Twilio; the webhook triggered the RAG flow so technicians could query the knowledge base from their phones.

#### Prerequisites

- Ruby on Rails application running locally
- Twilio account with access to the WhatsApp Sandbox
- Ngrok installed
- Rails server listening on port 3000

#### Steps to enable the integration locally (after re-mounting the webhook)

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

#### Important notes

- **Webhook URL updates:** Every time you restart Ngrok, the public URL changes. You must update the "When a message comes in" URL in the Twilio Console with the new Ngrok URL.
- **Development use:** This setup is intended for local development and testing. For production, use a stable public URL and follow Twilio's production WhatsApp requirements.
- **RAG flow (when enabled):** Incoming WhatsApp messages hit the `/twilio/webhook` endpoint and trigger the application's RAG flow, which queries the knowledge base and replies via WhatsApp.

## Usage

1. Sign up or sign in.
2. Upload documents (PDFs, images, etc.); the pipeline sends them to the Knowledge Base and surfaces them in the home **document list**.
3. Use the RAG chat to ask questions about indexed content. **Pin** documents from the list to steer retrieval; for **images** with a thumbnail, **tap the thumbnail** to view the stored file full-size in the lightbox.

## Web home: responsive layout, KB card, and lightbox

### Layout (mobile-first)

- **Grid:** `home/index.html.erb` uses a responsive grid; **`data-controller="rag-chat"`** wraps the chat column **and** the desktop sidebar so KB rows use the same Stimulus actions as mobile.
- **Breakpoints:** default = phone; **`sm:`** restores single-row chat input and shows footer metrics; **`lg:`** shows the desktop sidebar KB card (mobile uses the in-chat `mobile-docs-panel` strip, `md:hidden`).
- **Chat input:** column layout on small screens (textarea full width, then attach + send); desktop keeps inline clip + textarea + send.

### Unified KB card, pagination, refresh

| Piece | Role |
|-------|------|
| `_kb_docs_card.html.erb` | Shared shell for **`:desktop`** (rounded card + scroll) and **`:mobile`** (strip inside `_chat_box`); renders `_kb_docs_card_rows` + optional sentinel. |
| `_kb_docs_card_rows.html.erb` | Rows only — reused by initial HTML and Turbo Stream fragments. |
| `_kb_docs_card_sentinel.html.erb` | 1px **IntersectionObserver** target; `docs_scroll_controller.js` fetches `/home/documents_page?page=N` as Turbo Stream. |
| `HomeController` | `PAGE_SIZE` **20**; `#documents` replaces both item containers + sentinels after indexing; `#documents_page` **appends** next page to desktop and mobile. |
| `rag_chat_controller.js` | `refreshDocuments()` hits `GET /home/documents` after `KbSyncChannel` events. |

### Thumbnails & full-size lightbox

| Piece | Role |
|-------|------|
| `KbDocumentThumbnail` | 88px JPEG BLOB; inlined as `data:` URL in rows for zero extra round-trip. Created after upload via **`ImageCompressionService`** → Solid Cache key `kb_thumb:*` → **`BedrockIngestionJob`**; backfill: `bin/rake kb:thumbnails:backfill`. |
| `KbDocumentImageUrlService` | Presigned S3 GET for full-size image in the lightbox (`call` / `call_many`). |
| `image_lightbox_controller.js` | Singleton overlay, blur-up from thumb, ESC / backdrop / swipe / back. |
| `application.css` | `.image-lightbox-*` layout (safe areas, 44px close, mobile contain vs desktop natural size). |
| `config/locales/*.yml` | `home.lightbox.*` |

**Environment / IAM:** `KNOWLEDGE_BASE_S3_BUCKET`, region, AWS credentials; app role needs **`s3:GetObject`** for presigned URLs.

**Tests (non-exhaustive):** `test/services/kb_document_image_url_service_test.rb`, `test/controllers/home_controller_test.rb` (pagination, sentinels, dual-stream `documents`, thumbnails).

## Web workspace: pinned KB documents & Bedrock retrieval

| Piece | Role |
|-------|------|
| `ConversationSession` | `EXPIRY_DURATION` (30 days, sliding via `refresh!` on pin/unpin flows). `pin_kb_document!` / `unpin_kb_document!` maintain `active_entities`. No preload from `technician_documents`. |
| `PinnedDocumentsController` | `create` / `destroy`; binds pins to the signed-in user’s web session (`identifier` = `user.id`, `channel: "web"`). |
| `HomeController#pinned_uris_for_current_session` | `Set` of `SessionContextBuilder.entity_s3_uris(session)` for row UI (`data-selected`, checkbox). |
| `rag_chat_controller.js` | Optimistic toggle + `fetch` to `/pinned_documents` with CSRF JSON headers. |
| `RagQueryConcern#execute_rag_query` | Pinned URIs only for the metadata filter; `force_entity_filter` defaults to **true** when any pin exists. `KbDocumentResolver` still contributes **`## Query Resolution`** text to the prompt—it does **not** merge resolver hits into filter URIs. |
| `KbDocumentEnrichmentService` | Post-answer enrichment of **`kb_documents`** from Haiku doc refs + retrieved citations. |
| `BedrockIngestionJob#register_entity` | Auto-`pin_kb_document!` the `KbDocument` for the session that started the upload. |
| `BedrockRagService` | Web delivery directive includes **CITATIONS BEYOND USER SELECTION** when the model cites material outside pinned docs (e.g. after unfiltered retry). |

**Tests (non-exhaustive):** `test/models/conversation_session_test.rb` (TTL, pin/unpin), `test/controllers/pinned_documents_controller_test.rb`, `test/services/kb_document_enrichment_service_test.rb`, `test/services/session_context_builder_test.rb`, ingestion/RAG tests updated for auto-pin and `force_entity_filter`.

## Development

Run `bin/setup` to install dependencies, Git hooks, create `.env`, and prepare the database. The pre-commit hook runs RuboCop with autocorrect on staged Ruby files; fixes are staged automatically, and the commit is blocked if unfixable offenses remain (use `git commit --no-verify` to skip).

## Architecture

The home **responsive layout**, **unified KB card** (pagination, Turbo refresh), **thumbnails**, **S3 presigned image lightbox**, and **pinned-doc retrieval** are documented under [Web home: responsive layout, KB card, and lightbox](#web-home-responsive-layout-kb-card-and-lightbox) and [Web workspace: pinned KB documents & Bedrock retrieval](#web-workspace-pinned-kb-documents--bedrock-retrieval).

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
    Concern-->>User: JSON (web); TwiML only if Twilio webhook is re-enabled
```

| Component | File | Responsibility |
|-----------|------|----------------|
| **QueryOrchestratorService** | `app/services/query_orchestrator_service.rb` | Intent classification and routing |
| **SqlGenerationService** | `app/services/sql_generation_service.rb` | Text-to-SQL generation, execution, and answer synthesis |
| **BedrockRagService** | `app/services/bedrock_rag_service.rb` | Knowledge Base retrieval and generation (RAG) |
| **ClientDatabase** | `app/models/client_database.rb` | Isolated DB connection to the client's business database |
| **RagQueryConcern** | `app/controllers/concerns/rag_query_concern.rb` | Shared RAG orchestration for **web**; WhatsApp-specific branches were **collapsed** off the hot path (Twilio re-launch would reintroduce routing + queues). |

For additional architecture details and design decisions, see [ARCHITECTURE.md](ARCHITECTURE.md).

### LLM usage metrics & Solid Queue

Model usage is recorded **asynchronously** so Bedrock calls never wait on DB writes or dashboard broadcasts. `bedrock_queries` stores each event with a **`source`** so interactive chat and ingestion are accounted for separately:

| `source` | Meaning |
|----------|---------|
| `query` | End-user RAG / orchestrated LLM usage (**web chat** today; Twilio path would use the same `source` if re-enabled) |
| `ingestion_parse` | Estimated parser tokens after a document finishes KB ingestion |
| `ingestion_embed` | Estimated embedding tokens for that upload |

**Jobs & data:**

- **`TrackBedrockQueryJob`** (`queue: default`) — enqueued from `BedrockRagService` / `BedrockClient` after each real invocation. Creates a `BedrockQuery`, runs `SimpleMetricsService.update_database_metrics_only` (upserts `CostMetric` for the current day, including per-source tokens and cost), and **broadcasts** a Turbo Stream on the **`metrics`** channel so the **home** chat footer refreshes without reload.
- **`TrackIngestionUsageJob`** (`default`) — after `BedrockIngestionJob` completes, estimates parse/embed tokens per file and writes the `ingestion_*` rows above.
- **`TrackWhatsappCacheHitJob`** (`default`, **dormant**) — when the WhatsApp faceted path runs again, records cache-hit metrics into the same rollups.

**Solid Queue (`config/queue.yml`):** only the **`default`** worker lane is configured (metrics, ingestion, broadcasts). Dedicated **`whatsapp_rag`** / **`whatsapp_media`** processes were **removed** with the WA decouple; re-add them if you restore the webhook and want isolation again.

| Queue | Example jobs | Role |
|-------|----------------|------|
| **`default`** | `TrackBedrockQueryJob`, `TrackIngestionUsageJob`, `TrackWhatsappCacheHitJob` (inactive), `BedrockIngestionJob`, `DailyMetricsJob`, `SendWhatsappReplyJob` (not enqueued without WA) | Token persistence, footer Turbo updates, ingestion polling, scheduled metric refresh |

**Web metrics:** every async metrics write and Turbo broadcast for the home footer runs on **`default`**. **`DailyMetricsJob`** also refreshes database rollups for the dashboard when scheduled or triggered.

For local development, run **`bin/dev`** (see `Procfile.dev`) so **web**, **CSS**, and **Solid Queue workers** are all up; otherwise enqueued metrics jobs will not run and the footer will look stale.

### Session-Scoped KB Retrieval & Document Memory Architecture

Three layers describe the **catalog**, an **ingestion audit trail**, and what actually **scopes Bedrock retrieval** on the web home path:

```
kb_documents         → "What exists in S3?"              (global catalog; admin + home list)
technician_documents → "Ingestion / usage audit rows"  (still written from jobs; not preloaded into pins)
active_entities      → "Pinned KB docs for this session" (UI + auto-pin after indexed upload)
```

**`kb_documents`** — Global S3 catalog. One row per uploaded S3 key. Created on upload; enriched with `display_name`, `aliases`, and `size_bytes` as the pipeline processes the file. Powers the admin dashboard at `/dashboard` and the **home knowledge base list** (with optional `KbDocumentThumbnail` for images). Haiku-derived names/aliases from answers update **`kb_documents` only** via **`KbDocumentEnrichmentService`** (`RagController#ask`); that path does **not** add session pins.

> **MVP scope:** The pool is global (`account_id = nil`). Deduplication is by `canonical_name` (or `source_uri`) across all uploaders. `identifier` and `channel` are preserved for audit but do not drive uniqueness.
> **Stage 1+:** `account_id` will be added; uniqueness becomes `[account_id, canonical_name]`. Stage 2 adds `project_id`.

**`technician_documents`** — Still populated from ingestion (`BedrockIngestionJob` and related paths) for **audit / future ranking** (`interaction_count`, FIFO cap). It is **not** used to seed `active_entities` when a new `ConversationSession` is created (`preload_recent_entities` was removed).

**`conversation_sessions.active_entities`** — JSONB, capped at **`ConversationSession::MAX_ENTITIES`** (default **10**, overridable with `SESSION_MAX_ENTITIES`). **Sources of truth:** (1) user pins from the KB list (`PinnedDocumentsController` → `pin_kb_document!` / `unpin_kb_document!`), and (2) **auto-pin** when a chat upload finishes indexing (`BedrockIngestionJob#register_entity` → `pin_kb_document!`). **`SessionContextBuilder.entity_s3_uris`** turns these entries into Bedrock **`x-amz-bedrock-kb-source-uri`** filters. Session rows use **`EXPIRY_DURATION`** (default **30 days**, sliding `expires_at` on `refresh!`), not the older short TTL.

#### Data flow: upload completes → pin + catalog

```
Upload (web chat; same job shape for other channels)
  └─ S3 + kb_documents.ensure / enrich
  └─ BedrockIngestionJob (polls until COMPLETE)
       ├─ kb_documents           ← display_name + aliases (chunk pipeline)
       ├─ technician_documents   ← persist_to_technician_documents (audit)
       ├─ active_entities        ← pin_kb_document!(kb_doc) when session present
       └─ notify (e.g. WhatsApp / UI) as configured

Follow-up RAG (web)
  └─ retrieve_and_generate with entity filter when pins exist (force_entity_filter)
       └─ KbDocumentEnrichmentService (doc_refs) → kb_documents aliases only
```

#### Session-scoped retrieval filter logic

1. **No pinned S3 URIs** in the session → Bedrock runs against the **full** knowledge base (no source-uri metadata filter from pins).
2. **At least one pin** → web path sets **`force_entity_filter: true`** so retrieval stays on pinned URIs regardless of question shape; if the filtered call returns nothing, **`BedrockRagService`** retries **without** the filter, and the web prompt directive asks the model to **call out** any grounding outside the pinned set (**CITATIONS BEYOND USER SELECTION**).

| Layer | Scope (MVP) | Scope (Stage 1+) | Eviction / cap | Written by |
|---|---|---|---|---|
| `kb_documents` | Global | Global per account | — | Upload, ingestion, `KbDocumentEnrichmentService` |
| `technician_documents` | Global pool (`account_id = nil`) | Per `[account_id, project_id]` | FIFO max 20 | Ingestion (audit) |
| `active_entities` | Per session (or shared session in pilot) | Per session | `MAX_ENTITIES`; row TTL `EXPIRY_DURATION` | Pins + auto-pin on indexed upload |

### WhatsApp Answer Cache & Follow-up Classifier (R3)

> **Status (dormant):** the **R3** stack below (`Rag::WhatsappAnswerCache`, `SendWhatsappReplyJob`, classifier, faceted renderers) remains **in the codebase** but is **not exercised** while Twilio is decoupled. Read this section when **re-enabling WhatsApp**.

A short-lived **conversational UI cache** was designed to make WhatsApp **navigation** feel lightweight: the first message shows `[RESUMEN]` plus a **numbered menu** (pinned **1 = Riesgos**; `2`..`N-1` = model-chosen section labels such as *Consideraciones* / *Componentes* / *Paso a paso* for an installation; **last slot = Nueva consulta**). Tapping a number or an allowlisted command **expands from the cached full text without re-invoking Bedrock** — the full structured answer (including all section bodies) was already produced in one RAG call and is stored in cache. It **does not replace** `ConversationSession`; both coexist. Multi-document questions are first-class: `[DOCS]` + per-section `## <label> | <sources>` keep attribution correct.

> **Safety policy — closed allowlist.** The cache only serves messages that match an explicit set of **navigation tokens** (digits that appear in the cached `menu` row for this answer, or fixed words for redraw/reset; **not** open-ended “facet keywords”). **Free-text questions are never served from cache** — e.g. `voltaje`, `torque tornillo m8` always run a fresh RAG. Trade-off: lower cache hit rate on free text, higher Bedrock cost. **Safety > token spend**. See `Rag::WhatsappFollowupClassifier` docstring.

```
ConversationSession  →  pins + conversation_history for prompts; sliding row TTL (EXPIRY_DURATION)
Rag::WhatsappAnswerCache  →  last RAG “card” (structured sections + menu) for menu UX, per recipient
```

| Layer | Time horizon | Scope | Backing store |
|---|---|---|---|
| `conversation_sessions` | Row TTL **30 days** sliding by default (`EXPIRY_DURATION`; refreshed on pin flows) | `identifier` + `channel` (one shared row in MVP pilot when enabled) | PostgreSQL `conversation_sessions` |
| `Rag::WhatsappAnswerCache` | Turn-set | **Per WhatsApp `to` number** (not shared across technicians) | `Rails.cache` (Solid Cache) key `rag_wa_faceted/v4/<whatsapp_to>` — TTL **1800s** (30 min). Bumped v3 → v4 when the payload switched from `faceted`+`document_label` to `structured` (no session-derived document label; avoids stale “(fuente)” mix); stale v3 payloads are invalidated as `op=corrupt`. |
| Sticky thread locale | Longer follow-up | Same `to` | `rag_whatsapp_conv/v1/<whatsapp_to>` (written by `RagQueryConcern`; TTL **7 days**) so very short follow-ups can inherit language after the 30 min faceted TTL expires. |

**Why per-number cache even in shared-session MVP?** The pilot may use one `ConversationSession` row for everyone, but two technicians on different phones must not share the same in-progress menu/answer: collision would mix topics and is unsafe. Isolation is by `whatsapp:+…` (cache key), not by shared session.

#### Cache value schema (`Rag::WhatsappAnswerCache`)

`WhatsappAnswerCache` validates a fixed set of keys (`SCHEMA_KEYS` in `app/services/rag/whatsapp_answer_cache.rb`). A typical payload:

```ruby
{
  question:         String,   # last user question that produced this card
  question_hash:    String,   # SHA1 prefix (debug)
  structured: {              # from Rag::FacetedAnswer#to_cache_hash
    intent:   Symbol,        # e.g. :identification, :installation, :emergency
    docs:     [String, ...], # from [DOCS] JSON in the model output
    resumen:  String,
    riesgos:  String,        # pinned block; always slot 1 in [MENU] as __riesgos__
    sections: [ { n:, key: :sec_1, label:, sources: [String, ...], body: String }, ... ],
    menu:     [ { n:, label:, kind: :riesgos | :section | :new_query, section_key: ... }, ... ],
    raw:      String
  },
  citations:         Array,
  doc_refs:          Array,
  locale:            Symbol,  # :es | :en
  entity_signature:  String,  # 12 hex chars: SHA1 of sorted active_entities keys; drift can invalidate
  generated_at:      Integer
}
```

- **EMERGENCY** intent is **never written** to cache (`[WA_CACHE] op=skip_write reason=emergency`); safety answers are always full RAG.
- **Corrupt / schema drift (missing keys)** on read: entry deleted, `nil` returned, log line `[WA_CACHE] op=corrupt …`.
- **Entity drift** (cached signature ≠ live `active_entities`): `invalidate` + miss — **skipped** when `SharedSession::ENABLED` (see `SharedSession` in code), because shared pilots mutate the same entity set for unrelated reasons.

#### Components

| Component | File | Role |
|---|---|---|
| `Rag::FacetedAnswer` | `app/services/rag/faceted_answer.rb` | Parses Bedrock’s structured blocks (`[INTENT]`, `[DOCS]`, `[RESUMEN]`, `[RIESGOS]` pinned, `[SECCIONES]`, `[MENU]`) and renders the first message + per-section detail from cache. `legacy?` = model emitted no structure → plain `format_rag_response_for_whatsapp` + no cache write. |
| `Rag::WhatsappAnswerCache` | `app/services/rag/whatsapp_answer_cache.rb` | Read/write/invalidation + logs: `op=read|write|corrupt|skip_write` and `op=invalidate` when **entity_drift** is detected (non–shared mode). |
| `Rag::WhatsappFollowupClassifier` | `app/services/rag/whatsapp_followup_classifier.rb` | **Strict** closed-allowlist: `inicio`/`start`/`home` → `reset_ack_with_picker` · `nuevo`/`nueva`/`new`/`reset` → `user_reset` (cache only) · digits `1`..`N` resolved against the **cached** `menu` (slots include `__list_recent__` → `:show_doc_list :recent`, `__list_all__` → `:show_doc_list :all`, legacy `__new_query__` → reset) · everything else (including former redraw words like `menu`/`volver`/`mas`) is **`:new_query`** — the menu is rendered as a footer on every message so a redraw shortcut is unnecessary. Emits `[WA_CLASSIFIER] route=… reason=…`. |
| `Rag::WhatsappPostResetState` | `app/services/rag/whatsapp_post_reset_state.rb` | Short-lived (5 min) Rails.cache state after **picker reset** (`:reset_ack_with_picker`): `picking_source` → `picking_from_list` until the user picks a doc or abandons. |
| `Rag::WhatsappDocumentPicker` | `app/services/rag/whatsapp_document_picker.rb` | Builds numbered lists for **recent** vs **all** and seeds `Describe <name>` into the normal `:new_query` RAG path. |
| `SendWhatsappReplyJob` | `app/jobs/send_whatsapp_reply_job.rb` | `perform_faceted` / `perform_legacy`; post-reset picker short-circuits before the classifier when `WhatsappPostResetState` is present. Orchestrates cache, classifier, RAG, `infer_locale` (cache → sticky conv key → history heuristic → body → `I18n.default_locale`). **Does not** prepend a separate “Documentos consultados” header to structured first messages — sources come from `[DOCS]` and section headers. |
| `ProcessWhatsappMediaJob` | `app/jobs/process_whatsapp_media_job.rb` | After a successful `KbSyncService` upload: `invalidate(whatsapp_to)` and `[WA_CACHE] op=invalidate reason=media_upload` so the next user question runs RAG over the updated KB. |

#### Classifier cascade (order in code; first match wins)

The classifier is a **strict closed allowlist** of navigation inputs: a digit that resolves against the cached menu, or one of the explicit reset tokens. Anything else — including former soft-nav words like `menu`, `volver`, `regresar`, or `mas` — is treated as a content question, the cache is invalidated, and a fresh RAG call runs. There is **no** synonym map, no length heuristic, no LLM-based "intent guessing", and no menu-redraw shortcut (the menu is already rendered as a footer on every message).

1. **`:reset_ack_with_picker`** — `inicio`, `start`, `home` → invalidate cache, static ack with **1=recientes / 2=existentes**, arm `WhatsappPostResetState` (**no** RAG on this turn for the RAG part).
2. **`:user_reset`** — `nuevo`, `nueva`, `new`, `reset` **or** the menu digit whose `kind` is `:new_query` (legacy cache compat) → invalidate cache, short ack (no file-picker); **no** RAG.
3. **Empty cache + only digits** that look like a menu pick → `:no_context_help` (`:menu_without_cache` or `:digit_out_of_range`).
4. **Empty cache + free text** — `:new_query` (`:no_cache`).
5. **Digit** — resolve against the **cached** `menu` for this answer:
   - `kind: :riesgos` / `:section` → `:section_hit` if the body is non-empty; empty → `:new_query` (`:empty_section_reconsult`).
   - `kind: :list_recent` / `:list_all` → `:show_doc_list` (renders TechnicianDocument or KbDocument list, arms `WhatsappPostResetState` `PHASE_PICKING_FROM_LIST`; the next digit picks a doc → seeded `:new_query` → cached).
   - `kind: :new_query` (legacy) → same as **`:user_reset`**.
   - Unknown digit → `:no_context_help` (`:digit_out_of_range`).
6. **Default** — `:new_query` (`:content_query`).

Matching is on the **fully normalized token** (NFD → strip accents → lowercase → strip → collapse spaces), not substring presence. Literal words like `riesgos`, `menu`, or `mas` in free text are **not** shortcuts — only the menu digit (or one of the four reset tokens) is recognised as navigation.

If the model omits structured labels (`FacetedAnswer#legacy?`), the job does not populate the WhatsApp answer cache; behavior matches the legacy `perform_legacy` single-message path (citations header/footer as before when applicable).

#### Observability & scripts (WhatsApp path — re-mount webhook to use)

- **`bin/wa_dev_sim "<mensaje>"`** — one-off POST to `/twilio/webhook` (requires route + workers restored); logs a marker in `development.log`.
- **`bin/wa_e2e_monitor`** — highlights `[WA_CLASSIFIER]`, `[WA_CACHE]`, `[WA_FACET_DELIVERY]`, and Bedrock lines in `log/development.log`.
- **`bin/wa_e2e_run`** — E2E markers per case (`E2E_CASE_12`, …) for grepping a single run.
- **`bin/wa_metrics_daily`** — rollups of cache ops and classifiers (see script).
- **`bin/wa_dev_clear <whatsapp:+…>`** — deletes `rag_wa_faceted/v4/...` (or whatever current `WhatsappAnswerCache::VERSION` is), `rag_wa_post_reset/v1/...`, and `rag_whatsapp_conv/v1/...` for a number. When shared session is on, it does **not** destroy the `mvp-shared` row (prints a one-liner to do that manually if needed).

#### R3 WhatsApp flags (detail)

The WhatsApp structured-cache flags appear in the [MVO pilot flags](#mvo-pilot-how-to-enable--disable-environment-flags) table above. Summary:

| Variable | Default | Effect |
|---|---|---|
| `WA_FACETED_OUTPUT_ENABLED` | `true` | `false` → `SendWhatsappReplyJob` uses `perform_legacy` (single message, no read-through cache). |
| `WA_PROCESSING_ACK_ENABLED` | `true` | `false` → suppresses the *"🛠 Consultando la base de conocimiento…"* bubble. Ack is sent before **every** full RAG call: `:new_query` **and** `perform_legacy`. Cache hits, doc-list slots (6/7), and section follow-ups stay silent. Log line: `[WA_ACK] to=<to> reason=new_query_before_rag`. |

> **Removed flag (`WA_NANO_CLASSIFIER_ENABLED`).** The Haiku-nano sub-classifier and the synonym map were removed as part of the safety-policy refactor. Remove it from your `.env` if present.

Typical interaction **when Twilio is active:** **0** Bedrock calls when the technician taps a menu number / allowlisted command; **1** full RAG when they type free text. The full RAG path is optionally preceded by the processing-ack bubble when the flag is on.

#### Section rendering (R3 UX)

- **Vertical text-only menu** — first message lists `N - <label>` for each `[MENU]` row. Emojis from the model are stripped in render. The application appends two file-listing slots after Haiku's dynamic sections: **Archivos recientes consultados** (`__list_recent__`) and **Todos los archivos** (`__list_all__`); the legacy "Nueva consulta" slot was removed (any free-text reply is a new query).
- **Multi-doc banner** — if `[DOCS]` has **≥2** entries, a `rag.wa_docs_banner` line appears *above* `[RESUMEN]`; single-doc answers skip the banner. Section follow-ups use `*<Section> · <sources>*` (or a two-line fallback for very long source lists) — sources come from each `##` header, not from `active_entities` (fixes the old stale-label bug).
- **Riesgos pinned** — always menu slot 1; body comes from the `[RIESGOS]` block (safety).
- **Reset + file picker** — **`inicio` / `start` / `home`** (not the last *Nueva consulta* digit) show the **1 — recientes / 2 — existentes** prompt and arm `WhatsappPostResetState`. Picking a doc seeds `Describe <name>`. **`nuevo` / `nueva` / `new` / `reset`**, or the **Nueva consulta** menu number, only invalidate the faceted cache and show a short ack (no file list).
- **No semantic “keyword → cached facet” routing** — `voltaje`, `riesgos` as free text, etc. are always full RAG (`:content_query`).

For multi-tenant work later, keep treating **session row** and **per-number faceted cache** as separate concerns: a future `account_id` / `project_id` can scope the session and KB, while the WhatsApp cache key should remain tied to the **recipient address** to avoid cross-user menu bleed.
