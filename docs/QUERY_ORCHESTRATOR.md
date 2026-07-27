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

### KNOWLEDGE_BASE_QUERY decision order

Inside the `KNOWLEDGE_BASE_QUERY` branch, `QueryOrchestratorService#execute`
tries deterministic, zero/low-cost paths before falling through to full RAG
generation, in this order:

1. **`Rag::DocumentOverviewResponder`** — resolves a "name only" question over
   1-4 pinned documents (`MAX_OVERVIEW_DOCUMENTS`) as a deterministic
   table-of-contents summary, one `Documento: %{name}` block per document with
   an overview available, when a `document_manifests/` manifest (or warm
   cache entry) exists. Only entities with `source: "user_pin"` are
   considered. `model_invoked: false`, zero Bedrock calls, `citations: []`.
2. **`Rag::AmbiguousModelResponder`** — deterministic multi-model
   disambiguation when retrieved evidence spans several boards/models.
3. **`Rag::DeterministicRenderer`** — renders structured records (e.g.
   database-backed answers) without a generation call when applicable.
4. **`BedrockRagService`** — the default `RetrieveAndGenerate` lane, used only
   when none of the above resolve the question.

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

### Field-photo reuse (`field_photo_id`)

`QueryOrchestratorService#initialize` accepts an optional `field_photo_id:`
kwarg, forwarded from `RagQueryConcern#execute_rag_query` and
`RagController#ask` (`params[:field_photo_id]`). It is shared code with
WhatsApp's `SendWhatsappReplyJob`, so the kwarg defaults to `nil` and never
changes that caller's behavior.

At the start of `#execute`, before the fresh-upload `@images.any?` branch:
when `field_photo_id` is present, no new image was uploaded in the same
request, and an account is known, the orchestrator resolves the photo via
**`@account.field_photos.find_by(id: field_photo_id)`** — scoping is
mandatory so a photo id from another account is silently ignored (falls
through to the normal text-query flow; the resource's existence is never
leaked). On a match, it enqueues `FieldPhotoAnalysisJob` with
`image_token: nil` and the photo's own `sha256`/`field_photo_id`, and returns
the same acknowledgment shape as a fresh upload (`images_uploaded:`,
`correlation_id:`) so the frontend reuses the existing typing-dots +
`photo_analyzed` machinery unchanged. Zero image bytes leave the device or
touch the request process — `FieldPhotoAnalysisJob` rehydrates from
`field_photos/` in S3 only if needed.
