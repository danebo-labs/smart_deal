# Prompt Rules

## Answer Behavior

* RAG evidence is the source of truth.
* Do not invent technical procedures, values, causes, or safety instructions.
* Preserve traceability to retrieved documents.
* Surface uncertainty clearly.
* Use concise language optimized for field technicians.

## Cost And Latency

* Keep prompts compact.
* Avoid duplicate instructions.
* Avoid adding new LLM calls when deterministic Rails logic can solve the task.
* Prefer smaller, high-relevance context windows.

## Failure Semantics

* Missing data must surface as `DATA_NOT_AVAILABLE`.
* Ambiguous data must surface as `REQUIRE_FIELD_VERIFICATION`.

