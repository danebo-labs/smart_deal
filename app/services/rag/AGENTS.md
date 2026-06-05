# RAG Service Rules

## Retrieval First

* Retrieved knowledge is the source of truth.
* Prefer retrieved evidence over model assumptions.
* Prefer structured business data when it directly answers the question.
* Preserve document identity and evidence references.
* Parse document reference protocols; do not infer document identity.

## Cost And Latency

* Prefer simple retrieval paths.
* Minimize retrieval payload size.
* Use metadata filtering before semantic expansion.
* Avoid unnecessary reranking or multi-stage orchestration.
* Avoid repeated retrieval calls within the same user turn.
* Reuse existing session context when available.

## Safety

* Never invent procedures, measurements, tolerances, or safety instructions.
* Surface uncertainty explicitly.
* Missing data must return `DATA_NOT_AVAILABLE`.
* Ambiguous data must return `REQUIRE_FIELD_VERIFICATION`.

