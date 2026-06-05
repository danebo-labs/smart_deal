# Bedrock Rules

## RAG And Generation

* Prefer single-pass retrieval/generation flows.
* Minimize Bedrock round trips.
* Minimize retrieval payload size.
* Reuse existing retrieval context whenever possible.
* Prefer smaller, high-relevance context windows.
* Prefer metadata filtering before semantic expansion.
* Avoid unnecessary reranking.
* Avoid chained LLM calls unless accuracy materially improves.
* Avoid unnecessary orchestration stages.

## Safety

* Never fabricate technical data.
* Missing data must surface as `DATA_NOT_AVAILABLE`.
* Ambiguous data must surface as `REQUIRE_FIELD_VERIFICATION`.
* Preserve answer traceability through retrieved evidence.
* Do not send raw image bytes to the LLM; use S3 and KB ingestion flows.

## Infrastructure

* Keep AWS SDK clients and Bedrock-specific logic outside models.
* Make retry behavior explicit and bounded.
* Keep handlers idempotent; Solid Queue may retry jobs.

