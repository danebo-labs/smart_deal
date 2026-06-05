# Danebo AI

## Mission

Danebo is an AI-powered technical field assistant that helps technicians access, understand, and apply operational knowledge from manuals, procedures, field photos, and enterprise data.

Primary goal:

* Reduce time-to-resolution
* Improve operational consistency
* Minimize safety risks
* Deliver actionable answers with evidence

---

## Product Scope (Current)

Active channel:

* Authenticated Web Application

Dormant channel:

* WhatsApp / Twilio integration

When implementing new features:

* Assume Web is the primary production channel.
* Do not introduce WhatsApp-specific behavior unless explicitly requested.

---

## Technology Stack

Backend:

* Ruby 3.4+
* Rails 8.1+
* PostgreSQL
* Solid Queue
* Solid Cache
* Hotwire
* Tailwind

AI Platform:

* AWS Bedrock
* Claude models
* Titan Text Embeddings V2
* Knowledge Bases
* Hybrid Retrieval

Infrastructure:

* AWS
* S3
* Aurora PostgreSQL
* pgvector

---

## Engineering Principles

### Safety First

Danebo operates in technical and potentially safety-critical environments.

Never:

* Invent technical procedures
* Assume undocumented values
* Infer missing safety information

Always:

* Prefer retrieved evidence
* Preserve traceability
* Surface uncertainty

---

### Latency First

External services must never block user interactions.

Prefer:

* Background jobs
* Async processing
* Batch operations

Avoid:

* Long-running controller actions
* Repeated retrieval calls
* N+1 queries

---

### Retrieval First

RAG is the source of truth.

Always prefer:

1. Retrieved knowledge
2. Structured business data
3. Explicit user input

Never rely on model assumptions when evidence is available.

---

### Multi-Tenant Ready

Current MVP may contain shared resources.

New implementations must:

* Avoid global assumptions
* Leave clear seams for account_id scoping
* Remain compatible with future tenant isolation

---

## Coding Standards

* Thin Controllers
* Service Objects
* Query Objects
* AWS SDK usage outside models
* Minitest only
* Idempotent jobs
* Explicit error handling

---

## Performance Rules

Prefer:

* pluck
* select
* preload
* batch operations

Avoid:

* unnecessary callbacks
* loading full records
* repeated external API calls

---

## Testing

Framework:

* Minitest

Requirements:

* Test all business logic
* Test failure scenarios
* Preserve existing behavior
* Maintain idempotency guarantees

---

## Architecture References

Consult project documentation before making architectural changes:

* README.md
* docs/ARCHITECTURE.md
* docs/INGESTION_COST_V2.md
* docs/INGESTION_ROUTING.md
* docs/RAG.md
* docs/TENANCY.md

---

## Agent Behavior

Before implementing:

1. Understand the existing architecture.
2. Reuse existing patterns.
3. Prefer consistency over introducing new abstractions.
4. Minimize complexity.
5. Explain architectural tradeoffs when proposing major changes.

When uncertain:

* Ask for clarification rather than making assumptions.

The goal is not to generate code quickly.

The goal is to generate maintainable production code aligned with Danebo architecture.
