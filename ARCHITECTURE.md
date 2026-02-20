# Smart Deal — Architecture Document

> Last updated: 2026-02-20

## 1. System Overview

Smart Deal is a **Rails 8.1** application that exposes an intelligent **RAG (Retrieval-Augmented Generation)** system with multimodal support. Users can ask questions through a web chat UI or WhatsApp, and the system routes each query to the appropriate backend — an **AWS Bedrock Knowledge Base**, a **client PostgreSQL database** (Text-to-SQL), or both in parallel — then returns a unified natural-language answer with citations.

```
┌─────────────┐   ┌──────────────┐
│  Web Chat   │   │  WhatsApp    │
│  (Stimulus) │   │  (Twilio)    │
└──────┬──────┘   └──────┬───────┘
       │                 │
       ▼                 ▼
┌──────────────────────────────────┐
│        Rails Application         │
│  ┌────────────┐ ┌──────────────┐ │
│  │RagController│ │TwilioController│
│  └─────┬──────┘ └──────┬───────┘ │
│        │               │         │
│        ▼               ▼         │
│    ┌─────────────────────────┐   │
│    │   RagQueryConcern       │   │
│    └───────────┬─────────────┘   │
│                ▼                 │
│    ┌─────────────────────────┐   │
│    │ QueryOrchestratorService │   │
│    └──┬──────┬──────────┬────┘   │
│       │      │          │        │
│       ▼      ▼          ▼        │
│  ┌────────┐┌─────────┐┌───────┐  │
│  │SQL Gen ││Bedrock  ││Vision │  │
│  │Service ││RAG Svc  ││(Multi)│  │
│  └───┬────┘└────┬────┘└───┬───┘  │
│      │          │         │      │
└──────┼──────────┼─────────┼──────┘
       │          │         │
       ▼          ▼         ▼
  ┌────────┐ ┌────────┐ ┌─────┐
  │Client  │ │Bedrock │ │ S3  │
  │Postgres│ │  KB    │ │     │
  └────────┘ └────────┘ └─────┘
```

---

## 2. Technology Stack

| Layer              | Technology                                     |
| ------------------ | ---------------------------------------------- |
| Framework          | Ruby on Rails 8.1.1 (Ruby ~> 3.4)             |
| Primary DB         | SQLite 3 (app data, cache, queue, cable)       |
| Client DB          | PostgreSQL (external business data)            |
| Frontend           | Hotwire (Turbo + Stimulus), Importmap          |
| Assets             | Propshaft                                      |
| Auth               | Devise                                         |
| Background Jobs    | Solid Queue (runs in-process via Puma)         |
| Cache              | Solid Cache                                    |
| Real-time          | Action Cable + Solid Cable                     |
| AI / LLM           | AWS Bedrock (Claude 3.5 Haiku / Sonnet)        |
| RAG                | AWS Bedrock Knowledge Base (retrieve & generate)|
| Object Storage     | Amazon S3                                      |
| Messaging          | Twilio (WhatsApp)                              |
| Monitoring         | AppSignal                                      |
| Web Server         | Puma                                           |

---

## 3. Directory Layout

```
smart_deal/
├── app/
│   ├── controllers/
│   │   ├── concerns/
│   │   │   ├── authentication_concern.rb
│   │   │   ├── metrics_helper.rb
│   │   │   └── rag_query_concern.rb        # Shared RAG execution logic
│   │   ├── dashboard_controller.rb
│   │   ├── documents_controller.rb
│   │   ├── home_controller.rb
│   │   ├── rag_controller.rb               # POST /rag/ask
│   │   └── twilio_controller.rb            # POST /twilio/webhook
│   ├── javascript/
│   │   ├── controllers/
│   │   │   ├── rag_chat_controller.js      # Chat UI (Stimulus)
│   │   │   ├── document_upload_controller.js
│   │   │   ├── ai_summary_controller.js
│   │   │   └── particles_controller.js
│   │   └── rag/
│   │       ├── citation_formatter.js
│   │       └── references_renderer.js
│   ├── jobs/
│   │   └── daily_metrics_job.rb
│   ├── models/
│   │   ├── bedrock_query.rb                # Query tracking (tokens, cost, latency)
│   │   ├── client_database.rb              # Abstract model → client PostgreSQL
│   │   ├── cost_metric.rb                  # Daily cost/usage metrics
│   │   └── user.rb                         # Devise authentication
│   ├── prompts/bedrock/
│   │   ├── generation.txt                  # Answer generation template
│   │   └── orchestration.txt               # Query optimization template
│   ├── services/
│   │   ├── concerns/
│   │   │   └── aws_client_initializer.rb   # Shared AWS credential resolution
│   │   ├── bedrock/
│   │   │   └── citation_processor.rb       # Citation extraction & formatting
│   │   ├── ai_provider.rb                  # Provider abstraction (Bedrock only)
│   │   ├── bedrock_client.rb               # Bedrock Runtime invoke_model wrapper
│   │   ├── bedrock_rag_service.rb          # Knowledge Base retrieve_and_generate
│   │   ├── kb_sync_service.rb              # Triggers KB data-source re-ingestion
│   │   ├── query_orchestrator_service.rb   # Intent classification + routing
│   │   ├── s3_documents_service.rb         # S3 listing, upload
│   │   ├── simple_metrics_service.rb       # CloudWatch / S3 / RDS metrics
│   │   └── sql_generation_service.rb       # Text-to-SQL pipeline
│   └── views/
│       ├── home/                           # Chat box, upload, summary, metrics
│       └── dashboard/                      # Metrics dashboard
├── config/
│   ├── initializers/
│   │   └── bedrock.rb                      # AWS global config + BedrockProfiles
│   ├── database.yml                        # SQLite (primary) + PostgreSQL (client_db)
│   ├── routes.rb
│   └── recurring.yml                       # Solid Queue recurring jobs
├── db/
│   ├── schema.rb                           # users, bedrock_queries, cost_metrics
│   ├── cache_schema.rb
│   ├── queue_schema.rb
│   └── cable_schema.rb
├── lib/tasks/
│   └── kb.rake                             # kb:sync, kb:status, kb:create_multimodal_source
└── test/                                   # Minitest + Capybara + Selenium
```

---

## 4. Data Architecture

### 4.1 Primary Database (SQLite)

Stores application-level data. Three tables:

| Table             | Purpose                                       |
| ----------------- | --------------------------------------------- |
| `users`           | Devise auth (email, encrypted password, etc.) |
| `bedrock_queries` | Per-query telemetry: model, tokens, latency   |
| `cost_metrics`    | Daily aggregates: tokens, cost, Aurora ACU, S3|

Production also provisions separate SQLite databases for **Solid Cache**, **Solid Queue**, and **Action Cable**.

### 4.2 Client Database (PostgreSQL)

An external PostgreSQL database containing the client's operational/business data. Connected via the `ClientDatabase` abstract model and the `client_db` entry in `database.yml`. Used exclusively by `SqlGenerationService` for read-only Text-to-SQL queries.

### 4.3 AWS Knowledge Base (Vector Store)

Documents are uploaded to **S3**, ingested by the **Bedrock Knowledge Base**, and indexed for hybrid (semantic + keyword) retrieval. `BedrockRagService` queries this store via the `retrieve_and_generate` API.

---

## 5. Core Architecture: Query Pipeline

### 5.1 Entry Points

| Channel   | Controller           | Endpoint             | Auth                 |
| --------- | -------------------- | -------------------- | -------------------- |
| Web Chat  | `RagController`      | `POST /rag/ask`      | Devise (session)     |
| WhatsApp  | `TwilioController`   | `POST /twilio/webhook` | CSRF skipped (Twilio) |

Both controllers include `RagQueryConcern`, which delegates to `QueryOrchestratorService`.

### 5.2 Query Orchestrator

`QueryOrchestratorService` is the central router. It receives a query (and optional images) and follows one of two flows:

**Text-only flow:**

1. **Classify intent** — A cheap, fast LLM call returns one of: `DATABASE_QUERY`, `KNOWLEDGE_BASE_QUERY`, `HYBRID_QUERY`.
2. **Route** — Delegates to the appropriate service(s).
3. **Merge** (hybrid only) — Runs both services in parallel threads, then synthesizes a unified answer via a second LLM call.

**Multimodal flow** (images present):

1. **Image analysis** — `AiProvider` (→ `BedrockClient` with Claude 3.5 Sonnet) analyzes the image.
2. **KB lookup** — `BedrockRagService` searches the Knowledge Base in parallel.
3. **S3 upload + KB sync** — Fire-and-forget thread uploads the image for future indexing.
4. **Merge** — Synthesizes image analysis + KB results into a unified answer.

```
                    ┌──────────────────────┐
                    │ QueryOrchestratorSvc  │
                    └──────────┬───────────┘
                               │
                    ┌──────────▼───────────┐
             ┌──────┤  classify_query_intent├──────┐
             │      └──────────────────────┘      │
             │                 │                   │
    ┌────────▼──────┐  ┌──────▼───────┐  ┌───────▼────────┐
    │ DATABASE_QUERY│  │KNOWLEDGE_BASE│  │ HYBRID_QUERY   │
    └───────┬───────┘  └──────┬───────┘  └───┬────────┬───┘
            │                 │              │        │
            ▼                 ▼              ▼        ▼
    ┌───────────────┐ ┌──────────────┐ ┌─────────┐┌──────┐
    │SqlGeneration  │ │BedrockRag    │ │SQL Gen  ││KB RAG│
    │Service        │ │Service       │ │(thread) ││(thrd)│
    └───────────────┘ └──────────────┘ └────┬────┘└──┬───┘
                                            │        │
                                            ▼        ▼
                                     ┌──────────────────┐
                                     │  LLM Synthesis   │
                                     │  (merge answers) │
                                     └──────────────────┘
```

### 5.3 Service Layer

| Service                    | Responsibility                                                  |
| -------------------------- | --------------------------------------------------------------- |
| `AiProvider`               | Facade — delegates to `BedrockClient`                           |
| `BedrockClient`            | Wraps `Aws::BedrockRuntime` `invoke_model`. Handles text + vision (auto-switches to Sonnet for images). |
| `BedrockRagService`        | Wraps `Aws::BedrockAgentRuntime` `retrieve_and_generate`. Configures hybrid search, Cohere reranking, query decomposition, custom prompt templates, and citation processing. |
| `SqlGenerationService`     | Text-to-SQL: reads schema → LLM generates SQL → executes read-only → LLM synthesizes answer. |
| `Bedrock::CitationProcessor` | Extracts citations from RAG response, maps to S3 document indices, formats numbered references. |
| `S3DocumentsService`       | Lists and uploads documents to the S3 bucket backing the Knowledge Base. |
| `KbSyncService`            | Triggers Bedrock Knowledge Base data-source re-ingestion.       |
| `SimpleMetricsService`     | Collects CloudWatch (Aurora ACU), S3 stats, and Bedrock token/cost aggregates. |

### 5.4 AWS Credential Resolution

All AWS services share the `AwsClientInitializer` concern, which resolves credentials in priority order:

1. **Environment variables** (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, or `AWS_BEARER_TOKEN_BEDROCK`)
2. **Rails encrypted credentials** (`credentials.dig(:aws, :access_key_id)`, etc.)
3. **Defaults** — region falls back to `us-east-1`

Bearer token auth (via `Aws::StaticTokenProvider`) is supported alongside IAM access-key auth.

---

## 6. RAG Pipeline Detail

### 6.1 Retrieval Configuration

| Parameter          | Value                   | Notes                               |
| ------------------ | ----------------------- | ----------------------------------- |
| Search type        | `HYBRID`                | Semantic + keyword fusion           |
| Number of results  | 20                      | Top-K chunks from vector store      |
| Reranking model    | Cohere `rerank-v3-5:0`  | Applied over the 20 retrieved chunks|
| Query transform    | `QUERY_DECOMPOSITION`   | Breaks complex queries into sub-queries |

### 6.2 Generation Configuration

| Parameter     | Value  |
| ------------- | ------ |
| Temperature   | 0.3    |
| Top-p         | 0.9    |
| Max tokens    | 3000   |
| Prompt        | `app/prompts/bedrock/generation.txt` (custom template) |

### 6.3 Orchestration Configuration

| Parameter     | Value  |
| ------------- | ------ |
| Temperature   | 0.1    |
| Top-p         | 0.8    |
| Max tokens    | 2048   |
| Prompt        | `app/prompts/bedrock/orchestration.txt` (custom template) |

### 6.4 Models Used

| Use Case              | Model                                           | Notes                |
| --------------------- | ----------------------------------------------- | -------------------- |
| Intent classification | Claude 3.5 Haiku (`us.anthropic.claude-3-5-haiku`) | Fast, cheap          |
| RAG generation        | Claude 3.5 Haiku (default, configurable)         | 12x cheaper than Sonnet |
| Text-to-SQL           | Claude 3.5 Haiku (via `AiProvider`)              | SQL gen + synthesis  |
| Vision / multimodal   | Claude 3.5 Sonnet (`us.anthropic.claude-3-5-sonnet`) | Auto-switched when images present |

### 6.5 Citation Flow

1. `BedrockRagService` receives citations from `retrieve_and_generate`.
2. `Bedrock::CitationProcessor` extracts citation metadata (URI, title, content).
3. Citations are mapped to S3 document indices via `S3DocumentsService`.
4. Numbered references `[1]`, `[2]`, … are injected into the answer text.
5. Frontend (`citation_formatter.js`, `references_renderer.js`) renders tooltips and reference lists.

---

## 7. Text-to-SQL Pipeline

`SqlGenerationService` implements a four-step pipeline:

```
┌──────────────┐    ┌──────────────┐    ┌─────────────┐    ┌────────────────┐
│ 1. Read      │ →  │ 2. Generate  │ →  │ 3. Execute  │ →  │ 4. Synthesize  │
│    Schema    │    │    SQL (LLM) │    │    (read-only)│   │    Answer (LLM)│
└──────────────┘    └──────────────┘    └─────────────┘    └────────────────┘
```

- **Schema discovery** — Dynamically reads all tables/columns from the client PostgreSQL connection.
- **SQL generation** — LLM produces dialect-aware SQL (PostgreSQL/MySQL/SQLite).
- **Safety** — Only `SELECT` statements are executed. Non-SELECT is rejected before execution.
- **Result cap** — First 50 rows are passed to synthesis to prevent token overflow.

---

## 8. Multi-Channel Communication

### 8.1 Web Chat (Stimulus)

- `rag_chat_controller.js` manages the chat UI.
- Sends `POST /rag/ask` with `{ question, image[] }`.
- Supports image attachments (base64-encoded).
- Response rendered with citation tooltips and reference sections.

### 8.2 WhatsApp (Twilio)

- `TwilioController` receives webhooks at `POST /twilio/webhook`.
- Extracts text (`Body`) and media attachments (`MediaUrl0..N`).
- Downloads images from Twilio with HTTP basic auth, converts to base64.
- Returns TwiML `<Message>` response.
- Supported image types: PNG, JPEG, GIF, WebP.

---

## 9. Metrics & Observability

### 9.1 Query Tracking

Every RAG query is persisted to `bedrock_queries` with:
- `model_id`, `input_tokens`, `output_tokens`, `latency_ms`, `user_query`

### 9.2 Daily Metrics

`CostMetric` aggregates daily values (enum `metric_type`):
- Token usage (input/output)
- Estimated cost
- Query count
- Aurora ACU hours (via CloudWatch)
- S3 document stats

### 9.3 Dashboard

`DashboardController` serves a metrics UI with:
- Metric cards, comparisons, and trends.
- `POST /dashboard/refresh` triggers on-demand metric recalculation.

### 9.4 External Monitoring

- **AppSignal** — Application performance monitoring.

---

## 10. Authentication & Security

| Aspect              | Implementation                                |
| ------------------- | --------------------------------------------- |
| User auth           | Devise (email/password, session-based)        |
| Web endpoints       | Protected via `AuthenticationConcern`          |
| Twilio webhook      | CSRF skipped (`skip_before_action :verify_authenticity_token`) |
| AWS credentials     | ENV vars (dev) / Rails encrypted credentials (prod) — no hardcoded keys |
| SQL injection guard | Only SELECT allowed; `exec_query` (parameterized) |
| Static analysis     | Brakeman (security), Bundler Audit            |
| Code quality        | RuboCop (Rails Omakase)                       |

---

## 11. Background Jobs & Recurring Tasks

| Job / Task                       | Trigger                   | Purpose                            |
| -------------------------------- | ------------------------- | ---------------------------------- |
| `DailyMetricsJob`               | Solid Queue (recurring)   | Collects daily cost/usage metrics  |
| `kb:sync`                        | Rake task (manual/CI)     | Triggers KB re-ingestion           |
| `kb:status`                      | Rake task                 | Lists KB data sources and status   |
| `kb:create_multimodal_source`    | Rake task (one-time)      | Creates multimodal data source     |

---

## 12. Database Configuration

```
┌──────────────────────────────────────────────────┐
│               SQLite (Primary)                   │
│                                                  │
│  development.sqlite3  ←  dev                     │
│  test.sqlite3         ←  test                    │
│  production.sqlite3   ←  prod (app data)         │
│  production_cache.sqlite3  ←  Solid Cache        │
│  production_queue.sqlite3  ←  Solid Queue        │
│  production_cable.sqlite3  ←  Action Cable       │
└──────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────┐
│            PostgreSQL (Client DB)                 │
│                                                  │
│  Connected via ClientDatabase abstract model     │
│  Used exclusively by SqlGenerationService        │
│  Read-only access (SELECT only)                  │
└──────────────────────────────────────────────────┘
```

---

## 13. Deployment Topology

- **Web Server**: Puma
- **Background Jobs**: Solid Queue runs in-process (`SOLID_QUEUE_IN_PUMA`)
- **Health Check**: `GET /up` → `rails/health#show`
- **Storage**: Local disk (Active Storage), S3 (Knowledge Base documents)
- **Recurring Jobs**: Configured in `config/recurring.yml`

---

## 14. Key Design Decisions

| Decision | Rationale |
| -------- | --------- |
| SQLite as primary DB | Rails 8 default; sufficient for app metadata and metrics at current scale. Production cache/queue/cable in separate SQLite DBs. |
| Separate PostgreSQL for client data | Isolation via abstract model prevents cross-contamination. Enables future multi-tenant per-tenant configuration. |
| Haiku as default model | 12x cheaper than Sonnet. Sufficient for classification, SQL gen, and RAG generation. Sonnet reserved for vision only. |
| Hybrid search + Cohere reranking | Combines semantic and keyword retrieval for better recall, then reranks for precision. |
| Query decomposition | Breaks complex questions into sub-queries for more thorough retrieval. |
| Thread-based parallelism | Hybrid and multimodal flows use `Thread.new` to run services concurrently, paying `max(t1, t2)` instead of `t1 + t2`. |
| Fire-and-forget S3 upload | Multimodal images are uploaded + KB synced asynchronously to avoid blocking the response. |
| Custom prompt templates as files | `app/prompts/bedrock/*.txt` — version-controlled, easy to iterate without code changes. |
| Single `AiProvider` facade | Decouples consumers from the Bedrock SDK; adding a new provider requires no changes to callers. |

---

## 15. Routes Summary

```
GET  /                    → home#index           (main page + chat)
GET  /home/metrics        → home#metrics         (inline metrics)
GET  /dashboard           → dashboard#index      (metrics dashboard)
GET  /dashboard/metrics   → dashboard#metrics    (metrics JSON)
POST /dashboard/refresh   → dashboard#refresh    (recalculate metrics)
POST /documents/process   → documents#create     (PDF upload)
POST /rag/ask             → rag#ask              (RAG query — web)
POST /twilio/webhook      → twilio#webhook       (RAG query — WhatsApp)
GET  /up                  → rails/health#show    (health check)

Devise: /users/sign_in, /users/sign_up, /users/password, etc.
```

---

## 16. Testing

- **Framework**: Minitest (Rails default)
- **System tests**: Capybara + Selenium WebDriver
- **Coverage**: Controllers, services, models, jobs, concerns
- **Fixtures**: `test/fixtures/` (users, cost_metrics, bedrock_queries)
