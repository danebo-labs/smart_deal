# Hybrid query orchestrator

Query and attachment routing for the authenticated web app.

`QUERY_ROUTING_ENABLED` is disabled by default in the MVP, so normal text
questions take the direct Knowledge Base lane without paying for an intent
classification call. The Text-to-SQL/hybrid implementation remains available
behind that flag.

---

## Architecture

The home **responsive layout**, **unified KB card** (pagination, Turbo refresh), **thumbnails**, **S3 presigned image lightbox**, and **pinned-doc retrieval** are documented under [Web home: responsive layout, KB card, and lightbox](WEB_HOME.md) and [Web workspace: pinned KB documents & Bedrock retrieval](SESSION_AND_RETRIEVAL.md).

### Hybrid Query Orchestrator

When `QUERY_ROUTING_ENABLED=true`, a fast LLM call classifies intent before RAG
or Text-to-SQL work. This is not the default MVP production path.

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

### Attachment split

- Live JPEG/PNG technician photos enqueue `FieldPhotoAnalysisJob`. They produce
  a direct diagnostic response and never create `KbDocument` rows.
- The queue payload contains only a short-lived image token, SHA-256 and
  attribution metadata. Raw image bytes stay in account-scoped Solid Cache and
  are deleted by the job.
- `FieldPhotoDiagnosisCache` reuses a diagnosis only for the same
  `account_id + normalized_sha256 + locale + FieldPhotoPrompt::CONTRACT_VERSION`.
  A cache hit still emits a new correlated response for the requesting user,
  but creates no visual `BedrockQuery` row and has zero real LLM cost.
- Documents continue through `UploadAndSyncAttachmentsJob` and the indexed
  ingestion pipeline.
- MVP-required behavior: after `photo_analyzed`, the visual result is final and
  manual correlation is a later, explicit user query. The removed
  `pendingImageQuery` path must not be reintroduced.
