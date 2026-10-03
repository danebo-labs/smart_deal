# Prompt Rules

## Answer Behavior

* RAG evidence is the source of truth. Reason, infer, and conclude from it.
* State what is obvious for that kind of component, including the safety that sequence needs and whether a retrieved procedure is compatible.
* Do not invent a brand, model, part name, terminal, or printed value.
* When equipment identity is unknown, a documented analogous procedure may be
  offered as a reference with its source manual, page, and a disclaimer that
  it is not this job's instruction.
* When equipment identity is known, a foreign manual may be named as
  unavailable or reference-only. Its procedural content must not be used.
* When no compatible manufacturer manual was found, continue as Danebo
  guidance from the accepted visual observation and the active problem.
  That turn is not `DATA_NOT_AVAILABLE` and it does not teach a foreign
  procedure.
* Do not copy a foreign procedure's part names, terminals, or values onto
  this job, and do not apply one fixed sequence to every question.
* Preserve traceability to retrieved documents.
* Surface uncertainty clearly.
* Use concise language optimized for field technicians.

## Cost And Latency

* Keep prompts compact.
* Avoid duplicate instructions.
* Avoid adding new LLM calls when deterministic Rails logic can solve the task.
* Prefer smaller, high-relevance context windows.

## Failure Semantics

* Missing data must surface as `DATA_NOT_AVAILABLE`. That marker is the
  internal contract of the model and of telemetry (`internal_answer_text`).
  The technician receives it translated by `render_internal_markers`.
* Ambiguous data must surface as `REQUIRE_FIELD_VERIFICATION`.

