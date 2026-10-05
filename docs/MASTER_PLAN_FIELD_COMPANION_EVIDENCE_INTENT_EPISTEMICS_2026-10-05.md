# Master Plan — Field Companion: applicability, conversational intent and epistemic discipline

Date: 2026-10-05

Status: execution plan, reconciled with the Opus review (`APPROVE WITH CHANGES`). Phase contracts are frozen. Later implementation detail is refined only from verified findings of the previous phase. No implementation has been performed. F0 is not authorized.

Baseline investigated: `104bb55d0f1a6c42c6a1745eae0331ecce83dff0`

Production export: `tmp/pilot_exports/2026-10-03_2026-10-03_danebo-legacy/`

Primary production case: session `128`, episode `ep_000b0eb8f2107483`, 2026-10-03 16:53:02–16:56:33 America/Santiago

## 1. Executive decision

These are **not five independent bugs**. They are five symptoms, plus one query-composition defect, produced by three incomplete contracts:

1. **Evidence applicability**: authorization and retrieval relevance are currently allowed to stand in for applicability to the job. Open retrieval is correct; applying an unidentified foreign manual to the current lift is not.
2. **Conversational intent and active-case projection**: `meta` contains several product intents but has one canned response. The same missing distinction affects evidence offers and case recall. A related turn-semantic defect loses a technician's explicit negative fact before retrieval.
3. **Epistemic response discipline**: technician statements, literal photo reads, vision interpretations, compatible documentation and Danebo hypotheses are available, but their permitted claim strength is not explicit enough at generation time.

Those three contracts share one precondition. It is not a fourth subsystem. It lives in F2 and F4 must preserve it.

**Current-turn precedence.** The composed retrieval string is used as the generation question in the managed lane, the companion lane, and the photo-worker lane.

```text
CURRENT TECHNICIAN TURN
!=
RETRIEVAL QUERY
```

The literal current message is the authoritative question for generation. The composed query exists for retrieval and context search. T4 shows the composed query omitting `No veo ningún código de falla.` T6 shows the companion `Question` carrying retrieval context the technician did not say on that turn, including `TEST OK` and `en planta 3`.

The minimum coherent MVP change is to make those three contracts explicit, with that precedence, while preserving the current episode, photo-promotion, pin, retrieval-authorization and known-identity behavior. It does **not** require new moves, a new database, event sourcing, a workflow engine, a second reasoning model, a second retrieval by default, or a general ontology.

Traceability decision: **small extension**. Reuse `pilot_events` and the existing allowlist. Record accepted interpreter semantics and real state/query deltas. Do not build an observation table, a general ledger, per-event `app_revision`, or `MaintenanceCaseProjection`.

## 2. Authorities and evidence inspected

### 2.1 Repository authority

- HEAD at investigation was exactly `104bb55d0f1a6c42c6a1745eae0331ecce83dff0` (`fix: keep field trace identity events truthful`).
- Relevant preceding commits are present: `d94b070`, `444c910`, `8faf2f8`, `fe95555`, `9f703fe`, `26c246f`.
- Focused baseline suite at investigation: 183 runs, 1,770 assertions, 0 failures, 0 errors, 1 existing skip.

The main code paths inspected were:

- `app/models/conversation_session.rb`
- `app/controllers/concerns/rag_query_concern.rb`
- `app/controllers/rag_controller.rb`
- `app/jobs/field_photo_analysis_job.rb`
- `app/services/rag/turn_interpreter.rb`
- `app/services/rag/turn_perception.rb`
- `app/services/rag/route_policy.rb`
- `app/services/rag/work_context_reducer.rb`
- `app/services/rag/query_composer.rb`
- `app/services/rag/active_photo_context.rb`
- `app/services/session_context_builder.rb`
- `app/services/bedrock_rag_service.rb`
- `app/services/rag/structured_evidence_route.rb`
- `app/services/rag/document_identity_scope.rb`
- `app/services/rag/companion_guidance_context.rb`
- `app/services/rag/photo_question_answer_service.rb`
- `app/services/rag/answer_safety_processor.rb`
- `app/services/rag/source_fidelity_guard.rb`
- `app/services/rag/provenance_segmenter.rb`
- `app/services/rag/turn_evidence.rb`
- `app/services/pilot_usage_log.rb`
- `app/services/pilot_telemetry_reader.rb`
- `app/services/pilot_metrics_report.rb`
- `app/models/pilot_event.rb`
- `app/prompts/bedrock/generation.txt`

### 2.2 Production authority

The complete export is the latest 3-Oct export for `danebo-legacy`. Its `manifest.json` identifies image:

`docker.io/lahirisan80/smart-deal:104bb55d0f1a6c42c6a1745eae0331ecce83dff0`

That image attribution is the manifest plus commit time (commit 16:28, journey 16:53 America/Santiago). Events do not carry an application revision. Per-event `app_revision` stays deferred. The export manifest is enough for this pilot.

Artifacts inspected:

- `report.txt`
- `report.json`
- `source_events.jsonl` (`pilot_events`, probes, `TURN_EVIDENCE`, `RAG_QUALITY`, audit records)
- `interactions.csv`
- `manifest.json`
- `SHA256SUMS`
- `dossier.html`
- `valor.json`

The export has no unreadable containers. It reports 9 user messages, 11 assistant messages, 30 RAG LLM calls, 5 visual LLM calls, 42 completed interactions and no recorded execution failure. Those totals do not imply product correctness; the relevant failures are semantic. The cohort report's `internal_calls.kb_retrieve=0` does not match the 18 `kb_retrieve` events in the export. See F0.

### 2.3 Historical context, not authority

The following plans/docs were located and read for intent and prior decisions:

- `docs/ACTIVE_ARCHITECTURE.md`
- `docs/SESSION_AND_RETRIEVAL.md`
- `docs/PILOT_TRACEABILITY.md`
- `docs/PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29.md`
- `docs/PLAN_FIELD_COMPANION_RECOVERY_2026-09-30.md`
- `docs/PLAN_FIELD_COMPANION_DOCUMENT_FOCUS_REFACTOR_2026-10-01.md`
- `docs/PLAN_TURN_INTERPRETER_2026-10-01.md`
- `docs/PLAN_MULTIMODAL_COMPANION_SAFE_RETRIEVAL_2026-10-02.md`
- `docs/PLAN_VISUAL_EVIDENCE_HARDENING_2026-10-02.md`
- `docs/PLAN_R1B_SESSION_CORRECTNESS_2026-09-30.md`
- September continuity/retrieval plans found by filename/content search.

`docs/PILOT_TRACEABILITY.md` already lists weak photo-offer UX, over-specific open retrieval and over-reading `TEST OK` as deliberate debt. The production trace confirms that debt is now release-relevant behavior.

## 3. Production reconstruction

| Turn | Correlation | Interpreter / route | Evidence and outcome |
|---|---|---|---|
| T1 | `query:c09d42ca-2974-4d43-91ef-2fb4bed94f8a` | `new_work` → `ready` → managed open RAG | Goal persisted as `Está quedando mal nivelado` with this correlation. `open_retrieval.outcome_reason=identity_unknown`. BLT/Estela citations were published and the answer applied switches, insertion depth, V1, auto-adjust and codes to the unidentified lift. |
| T2 | `query:ac28b8a6-d397-4ef4-91ff-22146c1fadd0` | `follow_up` → open RAG | Effective query retained floor/goal. BLT-specific checks and codes were again presented as applicable. |
| T3 | `query:26bfcbd2-d305-484a-920a-2b91c60e826e` | `report` → open RAG | The literal `pasado` was transformed into `por encima`. That wording is the production incident, not the hidden-eval fixture. BLT E14, switch replacement, inspection reset and self-learning were prescribed without identity. |
| T4 | `query:178fdfcf-6137-4579-8eaa-d1d7a0c80bb1` | `report` → open RAG | `TURN_EVIDENCE.original_query` is `No veo ningún código de falla.`; `effective_query` omits it. That composed string is also the generation `Query`. Monarch and BLT evidence produced F4-00/E14/code guidance. |
| T5 | `query:ee4ecd82-364c-475f-a6b9-b3e7dfebf601` | `meta` → canned `rag.meta_continue` | Zero retrieval and zero response generation. The goal and episode remained intact, but the answer was `Puedes seguir con lo que ya me contaste.` |
| Photo | `photo:e30fbcec-9f1c-4a02-bc1b-7b860c9eedef` | fresh bytes → visual analysis → accepted observation | `field_photo_id=41`; observation read Orona, PBCM-V3 and visible strings including `TEST OK`. Identity promotion was truthful: `none` → `manufacturer:Orona:photo\|model:PBCM-V3:photo`, reason `relevant_observation`, same episode. |
| T6 | `query:8f6f1ec5-ab6c-479a-9467-e7252bdb97b0` | photo worker: `FieldPhotoAnalysisJob` → `PhotoQuestionAnswerService` → `DocumentIdentityScope=no_compatible` → `CompanionGuidanceContext` | Heading `## Photo Evidence (this turn)` matched and was parsed. Eight foreign chunks were retrieved, none published as compatible, citations empty. The companion `Question` was the composed retrieval string and contained `TEST OK` and `en planta 3`. Literal reads and vision interpretation arrived together in `Accepted visual observation` and in `safety_evidence`. The answer named Orona/PBCM-V3, turned visible `TEST OK` into a state claim, and excluded general controller logic without evidence. |
| T7a/b | `query:cafdc1a9-e7a7-4d4e-8933-8e6db5e8c5ef`, `query:3694572e-6442-4aac-bde1-26b5dd674d8f` | `meta` → canned `rag.meta_continue` | Both repeated recall requests returned the same canned sentence. No retrieval or generation occurred although goal, observations, photo and identity existed in the episode. |

Trace details:

1. T6 proves `DocumentIdentityScope` did its current functional job: known identity plus no compatible manual did **not** publish foreign evidence. The unsupported conclusion came from the companion-generation contract, not a scope leak. The heading mismatch is not this path.
2. In owner mode, `field_companion_turn` currently hashes the raw turn as both `original_sha256` and `effective_sha256` even when `result.composed` differs. `TURN_EVIDENCE` later exposes the real difference, but the first event is not sufficient to explain T4.
3. Assistant `field_companion_turn` events (`conversation_session.rb` calls that pass assistant `content` into `log_field_companion_turn`) store the response hash under `original_sha256` and `effective_sha256`. That digest is not a query.
4. The active-episode heading mismatch (`ActivePhotoContext` vs `CompanionGuidanceContext`) is a real defect on the **text** lane. The review cites correlation `f8b6c0f7` as that lane. It is latent relative to T6. Its fix stays in F4 and is not deployed alone.
5. `kb_retrieve` is logged with `account_id` and `correlation_id` and without `user_id` or `conversation_session_id`. A user-scoped cohort read drops those rows. The export's 18 retrieves become `internal_calls.kb_retrieve=0`.

## 4. Root-cause analysis

### Transversal defect — current-turn precedence — CONFIRMED

- **Symptom:** T4's generation question does not contain the current sentence. T6's companion `Question` contains `…PBCM-V3 planta 3 … Controlador Orona con pantalla LCD 5124501 TEST OK`.
- **Actual execution path:** `QueryComposer` builds one string. The managed lane puts it in `Query: $query$` (`generation.txt`) and in `input.text`, which also feeds retrieval. Companion guidance prints it as `Question:` (`companion_guidance_context.rb`). The photo worker does the same. The literal turn appears only as the last unlabeled `User:` line of `Recent Conversation`.
- **Root cause:** retrieval query and generation question are the same string. Hardening `QueryComposer` can stop a span from being deleted and still leave the literal turn subordinate to composed history.
- **Affected component:** managed generation, `CompanionGuidanceContext`, photo-worker question assembly, `SessionContextBuilder` recent conversation.
- **Type:** contract defect shared by F2 and F4. Not a new session architecture.
- **Confidence:** high. The three call sites and the T6 question text are direct.

### Issue A — unknown-identity applicability — CONFIRMED, P0

- **Symptom:** BLT, Estela and Monarch procedures, codes, terminals/parameters and recovery sequences were phrased as instructions for an unidentified lift.
- **Actual execution path:** `ConversationSession`/`QueryComposer` → `QueryOrchestratorService` → `BedrockRagService#query` → `document_identity_scope_result` returns `nil` because identity is unknown → managed `RetrieveAndGenerate` over the authorized open corpus → native citations published.
- **Root cause:** unknown identity has a retrieval outcome (`identity_unknown`) but no explicit generation-time applicability state. `generation.txt` already contains an analogous-reference rule. The managed call is not told the actual turn's identity status, and that static rule was violated on T1–T4. Authorization, relevance and native citation availability are therefore allowed to imply applicability.
- **Affected component:** `BedrockRagService` normal web lane. `StructuredEvidenceRoute`, which already owns chunks, has the same conceptual gap when it returns unknown-identity chunks unlabelled. The owner of the fix is `DocumentIdentityScope`, not a second policy object.
- **Type:** generation/evidence-policy defect; retrieval authorization itself is correct.
- **Confidence:** high. T1–T4 trace the open lane, cited sources and final text directly.

### Issue B — photo offer routed as generic meta — CONFIRMED

- **Symptom:** `Tengo una foto, ¿te sirve?` receives a context-free continuation sentence.
- **Actual execution path:** `TurnInterpreter` follows its explicit prompt rule and emits `move=meta`; `RoutePolicy` maps every meta move to one `rag.meta_continue`; `RagQueryConcern#meta_result` returns before retrieval/generation.
- **Root cause:** `meta` is a valid coarse move but lacks a local intent/subtype. A deliberate earlier rule preserved the goal by classifying a pure evidence offer as meta; the route then has no way to distinguish the offer from a greeting or a question about what Danebo needs.
- **Affected component:** interpreter schema/prompt and deterministic route presentation.
- **Type:** conversational intent/routing defect, not retrieval or photo continuity.
- **Confidence:** high. The prompt, event and early return are explicit.

### Issue C — epistemic overreach on T6 — CONFIRMED, cause corrected

- **Symptom:** visible `TEST OK` became a controller-state implication; a floor-specific symptom became an exclusion of general controller logic; condition and component were treated at the same claim strength as OCR text.
- **Actual execution path:** `FieldPhotoAnalysisJob` → `PhotoQuestionAnswerService` → `DocumentIdentityScope=no_compatible` → `CompanionGuidanceContext`. The heading was `## Photo Evidence (this turn)`. That heading was recognized. This turn did not go through the `ActivePhotoContext` heading.
- **Root causes, together:**
  1. The companion `Question` was the composed retrieval query (current-turn precedence).
  2. The visual evidence list was flat and mixed a literal read with vision interpretation.
  3. `safety_evidence` included interpreted Condition and Component (`visual_fields` is joined as a whole).
  4. The companion instruction allows "generic diagnostic reasoning" without stating that the reasoning is non-exclusive.
- **Latent, not the T6 cause:** `ActivePhotoContext#generation_block` renders `Photo Evidence for the active episode`, while `CompanionGuidanceContext` parses only `## Photo Evidence (this turn)`. A later text turn that does not resend the photo misses the active-episode photo contract. Unifying headings without separating literal from interpreted fields would add interpreted fields to that text lane and widen the over-read. The heading fix, the separation, and the `safety_evidence` restriction are one F4 commit.
- **Affected component:** companion context builder, photo evidence serialization, generation contracts. `DocumentIdentityScope` is not the cause.
- **Type:** context serialization + prompt/epistemic contract defect, plus the shared question defect.
- **Confidence:** high for the path, the parsed heading, the flat fields, and the unsupported output.

### Issue D — active-case recall collapsed into generic meta — CONFIRMED

- **Symptom:** the same explicit recall request failed twice despite durable case state.
- **Actual execution path:** `TurnInterpreter=meta` → the same `RoutePolicy` branch as T5 → `meta_result`; no case-state presenter, retrieval or generation.
- **Root cause:** same overloaded-meta abstraction as Issue B. A case recall is a local read of trusted episode state, not a knowledge-base question and not a generic meta turn.
- **Affected component:** interpreter subtype, route policy and a missing deterministic episode projection.
- **Type:** conversational intent/routing defect.
- **Confidence:** high.

### Issue E — directional inference — CONFIRMED AS A SYMPTOM, NOT A SUBSYSTEM

- **Symptom:** `pasado de nivel` became `por encima del nivel correcto`. That pair is the observed incident. It is not the production rule and not a hidden-eval fixture.
- **Actual execution path:** the literal complaint was present in the T3/T4 effective context; open RAG generation added a spatial direction supplied by neither the technician nor a compatible document.
- **Root cause:** claim-strength rules protect technical identifiers and unit values. They do not forbid a spatial or directional relation the technician did not provide. This belongs to the epistemic response contract. The production wording is evidence. It is not the production rule and it is not the hidden-eval fixture.
- **Affected component:** normal generation and companion guidance prompts/evals.
- **Type:** generation/epistemic defect.
- **Confidence:** high.

### Additional defect — T4 negative fact disappears — CONFIRMED MECHANISM

This is not a sixth product front. It belongs to conversational semantics. Current-turn precedence does not replace it: if composition drops the sentence, retrieval still misses it even after generation reads the raw turn.

- `TurnPerception` has `assert`, `negate`, `mention`, but no explicit act for a free-standing absence.
- `pending_resolution=absent` is retained only for `move=answer_pending` with an open `fault_code` pending question.
- A `negate` is assigned a slot only when its span matches an already-known value. With no stored fault code, the slot is `nil`.
- `QueryComposer#current_turn` removes every `kind=negate` span, including an unmatched one.
- `WorkContextReducer` only persists `absent_confirmed` for the pending-answer path and only applies negations with a present slot.

`negate` and `absent` do not overlap. `negate` corrects a known value. `absent` states that a slot has no value. An unmatched `negate` is not converted into `absent`.

A read-only in-memory reproduction against the investigation HEAD, using the production T4 sentence as an unmatched `negate`, produced:

```json
{"move":"report","identity":[{"kind":"negate","slot":null,"span":"No veo ningún código de falla"}],"fault":null,"composed":"Queda unos 2 o 3 centímetros pasado de nivel Pasa solo en planta 3 Está quedando mal nivelado"}
```

That reproduces the production omission. The exact Haiku tool payload cannot be proven because accepted spans were not recorded. F0 records the accepted assertion, including `ignored(no_slot)`. It does not store raw tool output.

## 5. Minimal target design

### 5.1 Contract A: evidence applicability

Keep three decisions separate:

| Question | Authority | Target behavior |
|---|---|---|
| May this tenant retrieve the chunk? | `KnowledgeScopePolicy` / account filter / pin authorization | Unchanged, fail closed. |
| Is the chunk relevant enough to retrieve? | Bedrock retrieval/profile | Unchanged except normal ranking evolution outside this plan. |
| May the answer present this chunk as this lift's procedure? | `DocumentIdentityScope` | Explicitly constrained before generation. |

There is no second policy object. Do not add `Rag::EvidenceApplicabilityContext`. `DocumentIdentityScope` already knows equipment identity, the reference-only distinction, `THIS JOB'S EQUIPMENT`, and `REFERENCE ONLY — OTHER EQUIPMENT`.

#### Unknown identity — mode `identity_unknown_reference`

Do not change `.apply`. Known-identity decisions stay on `.apply` and stay fail closed where they are fail closed today. Unknown identity does not enter `.apply`. The same class gains a mode and a bounded generation block for the case `.apply` currently treats as not required.

```text
unknown identity:
  retrieval allowed
  reference allowed
  current-job procedure applicability forbidden
```

- **May retrieve:** yes, from the currently authorized open corpus and current pin scope. Do not require a manual selection.
- **May show:** a retrieved procedure only as a named, cited, indicative reference for another documented equipment/manual and only when it concerns the same component/function. The response must state that identity is unconfirmed and the reference is not this job's instruction.
- **May present as applicable procedure:** no.
- **Forbidden transfer:** part names, terminals, codes, parameter/menu names, electrical/mechanical values, settings, reset/learning sequences and manufacturer-specific safety requirements from the foreign source.
- **Useful answer when docs are foreign:** begin from explicit technician facts and safe generic field reasoning; offer at least one observational check that does not bridge, short, disconnect, adjust or invent a value; ask at most one discriminating question if it changes the next answer. A refusal or an empty generic paragraph fails the phase.
- **Pin semantics:** selecting/pinning a document establishes focus, not equipment identity. It does not silently promote that document into this job's manual.

F1 keeps managed `RetrieveAndGenerate`. The mode block is injected into that prompt. It states the actual turn's identity status. Native citations and the managed call topology stay. `StructuredEvidenceRoute` renders the same mode around the chunks it already holds. No extra Retrieve and no extra LLM call. Do not fold tenant authorization or ranking into this mode.

The block is placed before `$output_format_instructions$`. That placeholder remains last.

#### F1b — pre-specified stop, not a phase and not a new design

F1's hidden real-model eval is the gate. If that eval still applies a foreign procedure, code, terminal, or value to the current job:

**STOP.** Do not deploy F1. Do not invent another unknown-identity design.

The only fallback, and only after an explicit human yes/no:

```text
retrieve_chunks
→ mark foreign chunks UNCONFIRMED REFERENCE
→ existing direct generation
```

That replaces managed `RetrieveAndGenerate` on the unknown-identity lane. It does not add a retrieval call and it does not add an LLM call: one retrieve, then the direct generation path that already exists. Native citation on that lane is lost. If a human says yes, measure p50/p95 for the topology change. If a human says no, F1 stays unreleased and the executor stops. Grok does not choose a third design.

#### Known identity with no compatible documentation

- Keep `DocumentIdentityScope` behavior and fail-closed boundaries unchanged.
- Continue with explicit technician facts, literal visual observations and generic Danebo diagnostic suggestions.
- Do not expose the body of incompatible manuals; names may explain the documentation gap.
- Do not state a manufacturer procedure, parameter, code meaning or exclusion.
- A suggested cause/check must be phrased as non-exclusive guidance, never as proof that another subsystem is healthy or impossible.

### 5.2 Contract B: conversational intent, active-case projection, and current-turn precedence

#### Current-turn precedence

When `raw_question` exists, companion and photo lanes set `Question` to that literal message. They do not substitute the composed retrieval query.

Managed `RetrieveAndGenerate` keeps composed `input.text` because that string feeds retrieval. Session context gains one bounded block:

```text
Current technician message (verbatim)
```

The block says:

- this is the authoritative current turn;
- the composed query is retrieval context;
- do not attribute historical content to the technician merely because it appears in the retrieval query.

The same turn appears once. It is removed from `Recent Conversation` when the verbatim block or the companion/photo `Question` already carries it. A duplicate `User:` line is a failed implementation of this contract.

F2 owns the contract. F4 must not put the composed query back into `Question` when it rewrites companion context.

#### Meta subtype

Do not create new top-level moves. Extend `TurnPerception` with one nullable `meta_kind` whose closed values are:

- `general`
- `evidence_offer`
- `case_recall`

It is required and non-null only when `move=meta`; it is `null` for every other move. Ruby validates that cross-field rule.

#### Evidence offer

- Route deterministically.
- Confirm that the technician can send the evidence and state, at a semantic level, what a photo can help establish (identity/component/visible text). Exact product copy is not frozen by this plan.
- Do not retrieve, generate, call Vision before bytes exist, open a new episode, replace the goal or write an observation.
- Preserve pending technical state, active photo, pins and episode id.

#### Case recall

Add a small read-only `Rag::CaseRecallPresenter` over the already-loaded `ActiveEpisode` and the tenant-scoped active photo of **that live episode** (`active_photo.field_photo_id`). Photo 41 was reused across episodes by fingerprint. A fingerprint match is not authorization to read another episode's photo.

It returns, in the user's locale:

- the active goal, verbatim;
- technician observations, verbatim and deduplicated;
- known/unknown/absent facts with their source (`user`, `photo`, `catalog`) expressed clearly;
- literal photo identity/text as photo reads, not technician confirmations;
- unresolved identity conflicts;
- no retrieved manual claims, no prior assistant hypotheses and no diagnosis inferred from those facts.

If no live episode exists, return a deterministic no-active-case response. Recall uses no retrieval and no response LLM. The existing interpreter call still classifies the turn. `generation_mode` stays `meta`. `meta_kind=case_recall` distinguishes it. Do not add `response_mode`.

#### Free-standing negative fact

```text
negate = correct or deny a known VALUE
absent = state that a SLOT has no value
```

Add one typed act, `absent`, accepted in this MVP only for `slot=fault_code` and `value=nil`. The slot is the closed enum, not a free hint. Persist `status=absent_confirmed`, `source=user`, with the current correlation, for report and follow-up as well as the existing pending-answer path.

Do not convert an unmatched `negate` into `absent`. `pending_resolution=absent` stays limited to `answer_pending`.

Independently, an unmatched `negate` must never erase the current turn from the composed retrieval query. Remove a `negate` span only when it resolved to a slot and a value the reducer can actually reject. Keeping that unmatched span may add some retrieval noise around "código". That noise is acceptable when the absence line is persisted.

`SessionContextBuilder` continues to render its existing absence line once state is persisted.

### 5.3 Contract C: epistemic response discipline

Use the existing data; classify its permitted claim strength before generation:

| Band | Examples | Allowed claim strength |
|---|---|---|
| Technician fact | goal, verbatim observations, explicit absence of a displayed code | State as what the technician reported. Do not add a spatial or directional relation the technician did not provide. |
| Literal visual read | manufacturer/model read from photo, exact visible text/codes | State only that the text/identity is visible/read in the photo, subject to legibility. |
| Vision interpretation | canonical component, subsystem, condition, relevance, target visibility | State as an image interpretation, not a confirmed equipment state or manufacturer fact. |
| Compatible documented evidence | chunks accepted by `DocumentIdentityScope` for known equipment | Attribute and cite; preserve modality and scope. |
| Unconfirmed documentary reference | open retrieval while identity is unknown | Name/cite as another manual's reference; never this job's procedure. |
| Danebo suggestion | hypotheses, generic checks, discriminating question | Explicitly non-exclusive; cannot rule out a controller/subsystem without evidence. |

Concrete rules:

- A visible display string supports only that the display/photo shows that string. It does not prove controller health, absence of faults, or correct controller logic.
- An interpreted condition is a vision interpretation, not proof of electrical or mechanical condition.
- A floor-specific symptom can prioritize a local observation. It cannot prove that general controller logic is uninvolved.
- Do not introduce a spatial or directional relation that the technician did not provide. This rule is general. It is not a phrase list.
- Absence of a displayed code is a positive technician fact about what was observed, not absence of every stored or internal fault.
- Generic diagnostic reasoning on the no-compatible path is a hypothesis or a field check. It is not an exclusion and not a manufacturer instruction.

F4 serialization, in one commit:

- Define one shared field map: literal photo fields versus vision interpretations.
- Render the active-episode photo block with a stable heading and those explicit groups.
- Make `CompanionGuidanceContext` consume both same-turn and active-episode photo evidence under that contract.
- Restrict companion `safety_evidence` to literal visual values. An interpreted component or condition may guide wording. It may not authorize a technical state or function.
- Do not deploy a headings-only change. Headings without the split and without the `safety_evidence` restriction widen the text-lane over-read.

Prompt budget. `CompanionGuidanceContext` is bounded by `MAX_CHARS` (2400). `to_s` currently keeps the head and drops the tail, which is where `No compatible manufacturer manual was found` and `Do not teach their contents` sit. New epistemic rules must not displace or cut:

- applicability;
- safety;
- no-compatible constraints.

Truncation order: Question, history, and redundant context first. Never the closing critical rules. Emit `context_truncated`. A test at maximum input size proves the tail survives. Separating the raw question from the composed retrieval string shortens `Question`; that saving is an estimate from the review (on the order of a few hundred characters on T6), not a measured budget.

Emit the companion prompt/contract version on the existing `prompt_version` field together with `generation_mode`, so a rollout can be told apart in the trace. Do not add a second semantic judge LLM or a phrase catalogue.

## 6. Invariants for every phase

The executor must keep all of these green:

1. Tenant-private chunks, photo rows and pins never cross account boundaries.
2. `danebo_general` remains explicit shared visibility; it is not applicability.
3. A pin remains case focus and is never silently dropped after an empty retrieve.
4. `new_work`/expiry/invalid-state episode boundaries remain unchanged.
5. Goal text remains symptom-focused and retains the creating `goal_source_correlation_id` (`444c910`).
6. An uncertain photo identity is not automatically promoted; explicit reuse semantics remain (`8faf2f8`).
7. Relevant-photo promotion and user/photo conflict behavior remain unchanged.
8. Late writers cannot mutate a later episode.
9. Known-identity `DocumentIdentityScope` remains fail closed where it is fail closed today.
10. No phase adds an unaccounted LLM or retrieval call.
11. Telemetry remains fail open and cannot alter user behavior.
12. No derived artifact is written under `bulk_chunks/`.
13. Web remains the production channel; no WhatsApp-specific behavior is introduced.

## 7. Execution phases

### Adaptive phase execution protocol

The target architecture and the phase boundaries F0–F5 are frozen. The implementation detail of a later phase is not static.

Each completed phase feeds its verified findings into the next phase before that next phase is executed.

For every phase `Fn`:

1. Execute only the phase a human has authorized. This document does not authorize F0.
2. Produce the section 9 evidence bundle and record the exact commit SHA.
3. Record actual files and code paths, tests and eval results, observed behavior, telemetry, unexpected constraints, regressions, assumptions confirmed or invalidated, cost / latency / call counts, and deferred issues.
4. Append a concise `Execution findings — Fn` section to this same file, after section 15, in phase order. Do not open a second plan.
5. Reconcile `Fn+1` against those findings and against repository HEAD.
6. Update the existing `Fn+1` section only where implementation detail became more precise.
7. Replace the `Fn+1` prompt template with an execution prompt built from the findings.
8. Stop. `Fn+1` may be presented for authorization. It may not be started.

F5 has no next phase. Its findings appendix is the release handoff. The block under F5 is that handoff template, not a prompt for F6. It does not create F6.

There are no execution findings yet.

The blocks titled **Prompt template for the next phase** are templates. They are not frozen execution prompts. F0 has no completed predecessor. Its execution prompt is written only after an explicit `GO F0`, from this plan, the investigation baseline, and repository HEAD at authorization time. The template under F0 is the seed for F1, not the order to execute F0.

After any phase has completed, do not execute the next phase from its original template. Regenerate that prompt from:

```text
Master Plan target contract
+
all verified findings from completed phases
+
current repository HEAD
```

The execution prompt includes, when applicable:

```text
Previous phase SHA:
Previous phase verdict:
Confirmed architecture/contracts:
Actual code paths discovered:
New trace signals available:
Behavioral findings:
Regression findings:
Cost/call-count findings:
Assumptions invalidated:
Deferred items:
Constraints for this phase:
```

The code commit boundary of each phase stays the boundary already written in that phase. The findings appendix and the `Fn+1` reconciliation are a docs-only update to this file after that SHA exists. That update does not authorize the next phase.

A completed phase may refine the next phase without a new architecture cycle only to:

- correct file or method ownership;
- replace an assumption with an observed code fact;
- add or remove a test justified by the previous phase;
- use a trace field the previous phase introduced;
- remove work the previous phase proved unnecessary;
- clarify an invariant without changing it;
- make an existing implementation step more precise.

The purpose is progressive precision, not progressive scope expansion.

STOP before the next phase, and do not absorb the change into that phase, if findings would require:

- a new phase;
- a new database or table;
- a new session architecture;
- a new top-level move;
- a new LLM call;
- a new retrieval call;
- changing a frozen invariant;
- changing known-identity `DocumentIdentityScope` semantics;
- activating F1b;
- broadening product scope;
- redesigning an already approved contract.

F1b remains the pre-specified stop in F1. Findings that the unknown-identity eval failed do not authorize F1b. They wait for a separate human yes or no.

### F0 — Causal trace, truthful, bounded, fail-open

**Goal**

Make one turn reconstructable from existing telemetry. Do not build an observability platform.

```text
input
→ interpretation
→ semantic application
→ episode delta
→ query composition
→ route
→ identity
→ applicability
→ retrieval
→ document scope
→ generation context
→ generation mode/model
→ citations
→ response
```

Applicability mode and `meta_kind` are emitted by F1 and F3. F0 adds their allowlist keys and does not invent values for them.

**Why**

Accepted spans are not recorded. `episode_fields_changed` is always empty. Owner-mode digests collapse raw and composed. Assistant events store the response hash as a query hash. `generation_mode` is null on the cohort card. Worker `original_query` is the composed string. The cohort report drops `kb_retrieve`. The next behavior changes are not diagnosable until those holes are closed. Existing goal, photo, late-writer, and tenant regressions already exist; F0 does not add another copy of them. They must stay green.

**Files expected to change**

- `app/models/conversation_session.rb`
- `app/services/pilot_usage_log.rb` (allowlist only for the five new keys below)
- `app/services/pilot_metrics_report.rb`
- `app/services/pilot_metrics_human_formatter.rb`
- `app/services/bedrock_rag_service.rb` (trace fields on the existing `kb_retrieve` log and on the generation context actually sent; no retrieval or prompt-behavior change)
- `app/controllers/rag_controller.rb` and `app/jobs/field_photo_analysis_job.rb` (raw-turn `original_query` / `question_sha256`, and `generation_mode` on `interaction_completed`)
- `app/services/rag/turn_evidence.rb` only if the hash fields need to follow the raw-vs-composed split without weakening `PILOT_AUDIT_CAPTURE`
- `test/models/conversation_session_turn_interpreter_test.rb`
- `test/services/pilot_usage_log_test.rb`
- `test/services/pilot_metrics_report_test.rb`
- `test/services/pilot_metrics_human_formatter_test.rb`
- `test/services/rag/field_companion_pilot_readiness_test.rb`
- `docs/PILOT_TRACEABILITY.md`

**Allowlist**

Reuse fields already allowlisted. Do not add a field for assertions, discard reasons, state hashes, retrieve counts, generation mode, or prompt length.

Already allowlisted and currently unemitted or unused where this plan needs them:

- `interpreter_assertions`
- `state_before_sha256`
- `state_after_sha256`
- `results_count`
- `contexts_delivered`
- `generation_mode`
- `generation_prompt_chars`
- `prompt_version`
- `episode_fields_changed`
- `original_sha256`
- `effective_sha256`

`mutations_applied` stays allowlisted. Discard reasons do not go there. They go inside each `interpreter_assertions` entry. Do not store raw tool output.

New allowlist keys, and no others:

- `meta_kind` (emitted in F3)
- `evidence_applicability` (emitted in F1)
- `query_components` (emitted in F0)
- `generation_context` (emitted in F0)
- `context_truncated` (emitted in F0 from truncation that already happens; F4 changes what is truncated)

`PilotUsageLog.safe_value` keeps strings at 500 characters and array items at 120, with at most 20 items. A Hash is stringified and cut. `query_components`, `generation_context`, and `interpreter_assertions` are arrays of short tokens. A span that does not fit is marked truncated. It is not presented as the full span.

**Exact behavior**

Interpreter, on `turn_interpreter`, reusing `move`, `status`, `fallback`, `field_rejections`, and `interpreter_assertions`. Each accepted assertion or observation can express:

```text
act
kind
slot
literal span
applied
ignored(reason)
```

Entry shape, one array item:

```text
act:kind:slot:applied|ignored(reason):span
```

The T4 shape is recordable as unmatched negate, slot empty, `ignored(no_slot)`, span `No veo ningún código de falla`. No raw tool payload.

Episode delta, on `field_companion_turn`:

- `episode_fields_changed` is `Rag::ActiveEpisodeTurn.changed_fields(before, after)` for the owner path. Real changes only. Not a full episode snapshot and not a new ledger.
- `state_before_sha256` and `state_after_sha256` are the existing allowlisted hashes. F3's "meta does not mutate" exit uses them.

Query composition, on `field_companion_turn`:

```text
query_components:
  current_turn: full | partial | dropped
  identity: present | absent
  identifiers: present | absent
  observations: <count>
  photo: present | absent
  goal: present | absent
  truncated: true | false
```

- `original_sha256` is the raw technician turn.
- `effective_sha256` is the composed retrieval query actually used.
- Assistant-result `field_companion_turn` events do not store either digest. The response hash remains `TURN_EVIDENCE.answer_sha256`.

`TURN_EVIDENCE.original_query` means what the technician said, on the web lane and on the worker/photo lane. `effective_query` remains the composed retrieval query. Raw text is still gated by `PILOT_AUDIT_CAPTURE`. When capture is off, the raw-turn hash is kept and the composed string is not written into `original_query`, `question_sha256`, or the cohort `question` column.

Route. Emit `generation_mode` on `interaction_completed`. The cohort card currently copies `evidence_route.generation_mode`, which is why the 42 `by_correlation` rows are null. Read the mode from the completed interaction. Do not add `response_mode`.

Closed reading of existing values, plus the subtype or scope status that already distinguishes a shared string:

| Lane | `generation_mode` | How the trace distinguishes it |
|---|---|---|
| Managed RetrieveAndGenerate | `generative` | Existing web fallback. Emit it; do not leave null. |
| Known-identity direct generation with applicable evidence | `document_identity_scope` | Same correlation, scope status `scoped`. |
| No-compatible companion | `document_identity_scope` | Same correlation, scope status `no_compatible`. |
| Deterministic meta, including evidence offer | `meta` | `meta_kind` `general` or `evidence_offer`. |
| Deterministic case recall | `meta` | `meta_kind=case_recall`. Zero retrieval, zero response LLM. |
| Clarify | `clarify_first` | Existing. |
| Photo/vision | the mode `PhotoQuestionAnswerService` already returns | Photo correlation, route `visual_query`. |

Do not invent a parallel enum. `meta_kind` and scope status are how two product lanes that already share a string stay distinguishable.

Identity stays on existing `identity_promotion` and `document_identity_scope` (before, after, source, conflict, needles).

Retrieval attribution. `kb_retrieve` must carry `account_id`, `user_id`, `conversation_session_id`, and `correlation_id`. The cohort drop is `PilotTelemetryReader#cohort_payload?` and `PilotEvent.hot_path_rows`, both of which require `user_id` when the export is user-scoped. `pilot_metrics_report.rb` line 127 filters conversation messages; it is not the retrieve filter. Do not widen those filters to keep null-user events. Attribute the call. A user-scoped export must then be able to compare expected retrieval calls with actual `kb_retrieve` counts. `kb_warm_ping` stays out of that comparison.

Retrieved versus delivered. On `document_identity_scope`, emit allowlisted `results_count` (retrieved) and `contexts_delivered` (sent to generation). The cohort card's `retrieved_chunks` today follows RAG-quality `chunk_count`, which is why T6 can show 0 after eight chunks were retrieved and then not delivered. Reconstruct:

```text
retrieved
→ compatible / applicable
→ delivered to generation
```

No chunk bodies. The managed lane keeps R1A filter trace and `RAG_QUALITY.retrieved_source_uris`. Managed `top_k` telemetry stays deferred.

Generation context manifest, computed from the context actually sent to generation. Not inferred after the fact. Not a full prompt. Counts and flags:

```text
generation_context:
  technician_current_turn   present | absent
  technician_facts_count
  observations_count
  photo_literal             separated | mixed | absent
  photo_interpretation      separated | mixed | absent
  compatible_docs_count
  foreign_reference_docs_count
  danebo_guidance           present | absent
```

Names may follow the code. Before F4, a flat visual list is `mixed`, not a pretended split. `technician_current_turn` is a flag, not a second copy of the raw text. Also emit `generation_prompt_chars` and `context_truncated` when that context was bounded.

Model, tokens, latency, and token source stay on existing `llm_calls`, including `query_direct`. Do not duplicate them. Join them to the turn by `correlation_id` and `generation_mode`.

`evidence_class` (`compatible` / `reference` / `none` / `deterministic`) is derived in the report from `generation_mode`, `evidence_applicability`, and `citations_count`. No new emission.

Per-event `app_revision` is not emitted.

**Invariants**

- Event recording rescues all telemetry failures.
- No extra database table or model.
- No raw image bytes, S3 keys, full prompts, chunk bodies, or raw tool output.
- No route, prompt, state, or response behavior changes.
- Existing goal, photo-promotion/reuse, late-writer, tenant, and episode-boundary tests stay green without new duplicates of those tests.

**Tests**

- An accepted unmatched negate is one `interpreter_assertions` entry: empty slot, `ignored(no_slot)`, literal span. A span cut by `safe_value` is marked truncated.
- `episode_fields_changed` reports real goal, observation, and fact changes and is not a full snapshot.
- `original_sha256` is the raw turn. `effective_sha256` is the composed retrieval query. They differ when composition differs.
- An assistant `field_companion_turn` does not store the response hash under `original_sha256`.
- With `PILOT_AUDIT_CAPTURE=true`, worker `original_query` and the cohort question are the raw technician text. With capture off, those text fields are absent and the original hash is still the raw turn, not the composed query.
- `generation_mode` is present on `interaction_completed` and on the cohort row for a meta turn and for a managed turn.
- A `kb_retrieve` that carries `user_id` is included in a user-scoped cohort count. One without `user_id` is not.
- `results_count` and `contexts_delivered` reconstruct retrieved versus delivered without chunk text.
- `generation_context` matches the context object passed into generation, including `mixed` when bands are not separated.
- Export formatter reads only emitted fields.

**Negative tests**

- A recorder exception does not fail a turn.
- Foreign-account photo data is never serialized.
- No event invents an identity promotion, an applicability result, a `meta_kind`, or an interpreter span.
- Existing `444c910` and `8faf2f8` regression tests remain unchanged and green.

**Observability**

Bounded fields on the existing events listed above. No new event family. No per-event revision.

**Cost / latency**

- New LLM calls: 0
- New retrieval calls: 0
- Expected token impact: 0
- Expected latency impact: local serialization only

**Exit criteria**

- Targeted suite and full Minitest pass.
- A synthetic T4 event shows `ignored(no_slot)` and a composed-query delta whose original hash is the raw sentence.
- A user-scoped report count includes an attributed `kb_retrieve`.
- `git diff --check` passes.
- No production behavior assertion changes.

**Commit boundary**

One commit limited to truthful trace fields, the cohort read of those fields, and the canonical trace doc.

**Prompt template for the next phase**

> F0 is `9e9e79c9773086cc60b91263c199239fee8524e8`. Verdict: the causal trace is in place and product behavior is unchanged. This block is a template. Do not execute it until a human says `GO F1`.
>
> Implement only unknown-identity applicability on `DocumentIdentityScope`, without changing `.apply` and without a new policy class. Do not touch known-identity scope, pins, ranking, goal, or photo promotion. Do not preserve the T4 drop (`current_turn:dropped`, `ignored(no_slot)`). Do not start F1b.
>
> Confirmed paths: the managed prompt is `BedrockRagService#load_generation_prompt_with_locale`, placed by `build_complete_optimized_config` at `generation_configuration.prompt_template.text_prompt_template`. F0 reads that sent string for `generation_context`. `StructuredEvidenceRoute#attach_generation_trace!` already manifests the prompt that route sends. `open_retrieval` already records `outcome_reason=identity_unknown` on the managed lane. Unknown identity returns before a document-identity retrieve, so do not invent `results_count` or `contexts_delivered` there.
>
> Trace to use: `evidence_applicability` is allowlisted and still unemitted. Emit it on `open_retrieval`, and on `document_identity_scope` only when that event already fires. Put the reason on existing `outcome_reason`. Leave `generation_mode=generative` for a successful managed turn. Do not add `meta_kind` or a parallel mode. Prove the query with `query_components`, `original_sha256`, and `effective_sha256`. `generation_context` has no applicability token; do not add one. Photo bands stay `mixed` until F4.
>
> Preserve `kb_retrieve` `user_id` and `conversation_session_id`. Do not call `ActiveEpisode#to_h` a second time on the live episode that owns the persisted payload. `PILOT_AUDIT_CAPTURE` still gates raw `original_query`.
>
> Regressions that must stay green: `work_context_goal_test.rb`, `field_photo_analysis_job_test.rb`, `field_companion_pilot_readiness_test.rb`, `document_identity_catalog_tenant_test.rb`, `document_identity_scope_test.rb`. New production LLM calls: 0. New production retrieval calls: 0. The applicability block is the only expected token change, and only on unknown-identity generated turns.

### F1 — Make unknown-identity applicability explicit

**Goal**

Preserve open retrieval. Stop a retrieved foreign manual from becoming this job's procedure. Keep the answer useful.

**Why**

This is the highest-risk production issue and affects T1–T4. The static analogous-reference rule in `generation.txt` did not carry this turn's identity status, and the model did not follow it. A second applicability class would split a policy `DocumentIdentityScope` already owns.

**Files expected to change**

- `app/services/rag/document_identity_scope.rb`
- `app/services/bedrock_rag_service.rb`
- `app/services/rag/structured_evidence_route.rb`
- `app/prompts/bedrock/generation.txt`
- `app/services/pilot_usage_log.rb` is not expected. F0 already allowlisted `evidence_applicability`. Do not add another key. The reason uses existing `outcome_reason`.
- `test/services/rag/document_identity_scope_test.rb`
- `test/services/rag/structured_evidence_route_test.rb`
- `test/services/rag/field_companion_pilot_readiness_test.rb`
- relevant prompt contract tests

No `app/services/rag/evidence_applicability_context.rb`.

**Exact behavior**

- After equipment identity is resolved, and before generation, unknown identity selects mode `identity_unknown_reference` on `DocumentIdentityScope`.
- `.apply` is unchanged, including its known-identity decisions and its current not-required return when identity is unknown.
- The mode injects the section 5.1 block into the managed generation prompt, before `$output_format_instructions$`.
- `StructuredEvidenceRoute` renders the same mode around its existing chunks. One retrieval result set. No second retrieve.
- Retrieval filters, top-k, pin scope, native citation publication, and the managed call stay as they are.
- A foreign manual may appear only as a named, page-cited indicative reference, never as the current equipment's instruction.
- The answer still offers at least one generic observational check that does not transfer foreign procedure.
- Emit `evidence_applicability` on `open_retrieval` and, only when that event already fires, on `document_identity_scope`. The reason uses existing `outcome_reason`.
- Inject the section 5.1 block inside `BedrockRagService#load_generation_prompt_with_locale`, which is the string `build_complete_optimized_config` places in `text_prompt_template`. F0 traces that sent string. A second template render is not the generation context.
- On the managed unknown-identity lane, `generation_mode` stays `generative`. That lane does not run the document-identity retrieve, so it does not gain `results_count` or `contexts_delivered`.
- `StructuredEvidenceRoute#attach_generation_trace!` already manifests the prompt that route sends. The same mode block has to be inside that prompt.

**Invariants**

- Visibility is not applicability.
- A user pin does not confirm equipment identity.
- No `.apply` semantic change.
- No extra retrieval, generator, or reranker.
- `kb_retrieve` keeps explicit `user_id` and `conversation_session_id` from the caller.
- Do not call `ActiveEpisode#to_h` a second time on the live episode that owns the persisted payload.
- Citation attribution remains native on the managed lane.
- F1b is not started from inside F1.

**Tests**

- The rendered unknown-identity prompt contains `identity_unknown_reference` and the forbidden-transfer contract, and it still asks for a useful generic check.
- The same query with known identity does not use the unknown block and follows existing scope.
- `.apply` fixtures for known identity stay byte-for-byte on their decisions.
- The structured route labels the mode and sends one retrieval result set.
- A generated reference must include foreign manual identity and page and the not-this-job disclaimer.
- Existing account and general-corpus filters remain exact.
- Trace proof uses F0 fields: `query_components`, `original_sha256`, `effective_sha256`, `generation_mode=generative` on managed success, and `evidence_applicability` once this phase emits it. Do not assert `meta_kind`, a separated photo band, or that the T4 sentence survives composition.

**Negative tests**

- Unknown identity plus a BLT chunk cannot yield imperative BLT steps, codes, terminals, values, or reset/learning sequences as current-job guidance.
- The same case cannot end as a bare refusal or an empty generic paragraph.
- A pinned foreign manual cannot become confirmed identity.
- Known Orona plus no compatible docs cannot reopen the corpus as applicable.
- Missing or malformed identity transport cannot bypass current fail-closed behavior where identity is required.
- Prompt placeholder ordering cannot regress.

**Observability**

`evidence_applicability=identity_unknown_reference` on `open_retrieval`, and on `document_identity_scope` only when that event already fires. The reason stays on allowlisted `outcome_reason`. Managed success stays `generation_mode=generative`. `generation_context` does not grow an applicability token. Citation and source lists stay. `evidence_class` is derived in the report when the emitted fields suffice. F0 does not emit `evidence_class`.

**Cost / latency**

- New LLM calls: 0
- New retrieval calls: 0
- Expected token impact: one bounded prompt block on unknown-identity generated turns. The review's estimate, not a measurement, is about 150–300 input tokens on that lane.
- Expected latency impact: minimal. Managed topology stays.

**Exit criteria**

- Deterministic tests pass.
- `turn_interpreter` eval and holdout remain at zero mismatch, fallback, and rejection.
- A bounded real-model hidden eval has zero current-job foreign procedures, codes, terminals, or values across unknown-identity cases, and at least one useful generic check in each of those cases.
- If any foreign procedure is applied, F1 is not complete, must not deploy, and must not be redesigned. Stop for the human yes/no on F1b.
- Known-identity and no-compatible regressions stay green.

**F1b stop**

Only if that hidden eval fails, and only after a human answers yes:

```text
retrieve_chunks
→ mark foreign chunks UNCONFIRMED REFERENCE
→ existing direct generation
```

Zero new LLM calls. Zero added retrieval calls. Native citations on that lane are dropped. Measure p50/p95. A human no leaves F1 unreleased. No third design.

**Commit boundary**

One commit for the unknown-identity mode on `DocumentIdentityScope`, prompt injection, the trace field, and tests. F1b is not part of that commit unless the gate has failed and the human has said yes, in which case F1b is its own later commit.

**Prompt template for the next phase**

> Implement explicit free-standing fault-code absence, unmatched-negation preservation, and current-turn precedence. Do not change applicability, `.apply`, route enums, or recall behavior. Do not start F1b from F2.

### F2 — Preserve the current turn and explicit negative facts

**Goal**

The literal technician turn is the generation question. `No veo ningún código de falla` survives retrieval composition and becomes durable case state even when Danebo did not ask for a code first. An unmatched negate neither erases that turn nor becomes `absent`.

**Why**

T4 shows the current turn can disappear from the composed query, which is also the generation question. T6 shows a composed `Question` attributing photo and history text to the technician. Composer hardening alone does not fix the second failure.

**Files expected to change**

- `app/services/rag/turn_interpreter.rb`
- `app/services/rag/turn_perception.rb`
- `app/services/rag/work_context_reducer.rb`
- `app/services/rag/query_composer.rb`
- `app/services/session_context_builder.rb`
- `app/services/rag/companion_guidance_context.rb`
- `app/services/rag/photo_question_answer_service.rb`
- `app/services/bedrock_rag_service.rb` only to attach the verbatim session block on the managed lane
- `test/services/rag/turn_perception_test.rb`
- `test/services/rag/work_context_reducer_test.rb` if that file exists, otherwise the nearest reducer tests
- `test/services/rag/query_composer_test.rb`
- `test/services/rag/companion_guidance_context_test.rb`
- `test/models/conversation_session_turn_interpreter_test.rb`
- `test/fixtures/files/field_companion/turn_interpreter_eval.yml`
- `test/fixtures/files/field_companion/turn_interpreter_holdout.yml`

**Exact behavior**

- Current-turn precedence from section 5.2, on all three lanes, with one appearance of the current turn.
- Add closed act `absent` with `slot=fault_code` and `value=nil`.
- Persist `fault_code={status: absent_confirmed, source: user, correlation_id: current}` for report and follow-up as well as the existing pending-answer case.
- Do not convert `negate` without a resolved value into `absent`.
- Remove a `negate` span only when it resolved to a slot and a value the reducer can reject.
- An unmatched negate stays in the composed retrieval query.
- Keep correction semantics for known manufacturer, model, controller, and identifier values.
- `SessionContextBuilder` continues to render its existing absence line once state is persisted.
- Both facts survive in `No veo código, pero ahora hace ruido al frenar`: the new symptom stays, and the absence is persisted.

**Invariants**

- No regex reactivation of the legacy owner path.
- No general negative-fact ontology.
- No invented code value.
- Repeated absence is idempotent.
- The active goal remains unchanged.
- Managed `input.text` stays the composed retrieval query. The verbatim block does not replace it.
- `$output_format_instructions$` stays last. The added block must fit Bedrock's prompt limits together with the F1 applicability block. F4's epistemic rules are not added in this commit.

**Tests**

- The production T4 sentence, plus natural variants in Spanish and English, stores `absent_confirmed` and remains in the retrieval query.
- Generation input for that sentence: the managed verbatim block contains the raw turn, and the companion `Question` is the raw turn. The composed query is separate and is not `Question`.
- `No veo código, pero ahora hace ruido al frenar` preserves the new symptom and persists absence.
- Absence after an open pending question still works.
- Recall-ready state contains the source correlation.
- Correction `no es NICE3000, es NICE1000` still removes the old value and does not leak it into the query.
- The current turn is absent from `Recent Conversation` when the verbatim block or `Question` contains it.
- Real interpreter eval scores the new act and query inclusion.

**Negative tests**

- `No sé qué código es` is unknown, not absent.
- `No es E51, es E52` is a correction, not absence. It must not be stored as `absent`.
- `No veo la placa` does not clear or write fault code.
- Unmatched negation cannot blank the current turn and cannot be rewritten as `absent`.
- No new episode is opened and no photo state changes.

**Observability**

The accepted span logs as `absent` or as `negate` with `ignored(no_slot)` when the slot is empty. `episode_fields_changed` includes `fault_code` when absence is new. `query_components.current_turn` is `full` for the T4 sentence. Original and effective hashes prove the raw turn and the composed query are different strings.

**Cost / latency**

- New LLM calls: 0
- New retrieval calls: 0
- Expected token impact: a small interpreter schema and prompt delta, a short absence line, and one verbatim block. The review's unmeasured estimate is about 60–120 interpreter input tokens for `meta_kind` plus `absent` together, and about 100–200 input tokens on managed turns once epistemic rules land in F4. Companion `Question` should get shorter, not longer.
- Expected latency impact: minimal

**Exit criteria**

- The T4 reproduction yields `absent_confirmed`, a composed retrieval query that contains the sentence, and a generation question that is the raw sentence.
- Eval and holdout have zero mismatches, fallbacks, and field rejections.
- Existing correction and focused-goal suites remain green.

**Commit boundary**

One commit for absence semantics, composition defense, current-turn precedence, and tests.

**Prompt template for the next phase**

> Add a meta subtype, a deterministic photo-offer response, and deterministic active-case recall. Reuse episode and photo state. Add no retrieval or response generation. Do not undo current-turn precedence.

### F3 — Split local conversational intents without adding moves

**Goal**

Make evidence offers and case recall useful while keeping `meta` non-retrieving and non-mutating.

**Why**

T5 and T7 are the same routing defect. Separate patches or new top-level moves would duplicate policy. A response LLM is not justified for a read of the live episode.

**Files expected to change**

- `app/services/rag/turn_interpreter.rb`
- `app/services/rag/turn_perception.rb`
- `app/services/rag/route_policy.rb`
- `app/services/rag/case_recall_presenter.rb` (small new PORO)
- `app/models/conversation_session.rb` (pass the already-resolved active photo context; telemetry only otherwise)
- `config/locales/rag.es.yml`
- `config/locales/rag.en.yml`
- `test/services/rag/turn_perception_test.rb`
- `test/services/rag/route_policy_test.rb`
- `test/services/rag/case_recall_presenter_test.rb`
- `test/models/conversation_session_turn_interpreter_test.rb`
- `test/services/rag/field_companion_pilot_readiness_test.rb`
- interpreter eval and holdout fixtures

**Exact behavior**

- Add validated nullable `meta_kind` with `general`, `evidence_offer`, `case_recall`.
- Preserve `move=meta` and `generation_mode=meta`. The subtype only selects deterministic presentation.
- `evidence_offer` returns localized contextual guidance, performs zero retrieval, generation, and Vision, and writes no case fact or observation.
- `case_recall` calls `CaseRecallPresenter` with the live episode and the account-scoped active photo of that episode. Zero retrieval and zero response LLM.
- The presenter follows section 5.2 and preserves literal wording, including a free-standing absence. It does not sharpen a spatial complaint into a direction.
- General greetings and questions keep current general-meta behavior unless a product copy change is separately approved.
- `Recuérdame qué tenemos; además ahora no abre la puerta` is not pure meta. The new symptom stays on the technical path.

**Invariants**

- No new move and no new route-decision enum. No `response_mode`.
- Meta turns never replace the goal, clear pending state, mutate photo identity, or open an episode.
- The presenter does not read assistant history, pilot events, or retrieved chunks.
- Photo lookup remains tenant scoped, uses the live episode's `active_photo.field_photo_id`, and is the already-existing single indexed lookup.
- The `fe95555` contract stays: an evidence offer that also carries a technical fact is not collapsed into pure meta.

**Tests**

- Exact T5 and natural evidence-offer variants select `evidence_offer`, preserve episode and goal, and make zero external calls.
- Exact T7 and paraphrases select `case_recall` and return goal, observations, absent code, photo-read identity and text, and conflicts, with sources.
- Empty or expired episode returns the no-active-case response.
- Repeating recall is idempotent and stable.
- Controller and model factual questions remain technical follow-ups, not case recall.
- `Recuérdame qué tenemos; además ahora no abre la puerta` is not `meta_kind` pure recall and retains the new door fact.

**Negative tests**

- `Tengo una foto y aparece E51` is technical, retains code and symptom, and is not reduced to a pure offer.
- Recall excludes prior assistant causes, BLT/Monarch suggestions, and foreign procedures.
- A photo id from another episode or another account exposes nothing, including when the fingerprint matches photo 41's reuse pattern.
- A greeting remains `general` and never renders a fake case.
- `new_work`, `report`, `follow_up`, and `correct` behavior remains unchanged.

**Observability**

Emit `meta_kind` on `turn_interpreter`. `generation_mode=meta` plus that subtype is the turn card. Do not log the rendered recall as a second case ledger. `state_before_sha256` and `state_after_sha256` show that the episode payload did not change.

**Cost / latency**

- New LLM calls: 0 (the existing TurnInterpreter call remains)
- New retrieval calls: 0
- Expected token impact: the interpreter schema delta shared with F2
- Expected latency impact: minimal; the response path is local

**Exit criteria**

- T5 and T7 product tests pass with explicit zero-call spies.
- Eval and holdout classify natural variants with zero mismatch, fallback, and field rejection.
- State hashes before and after meta turns are equal except ordinary timestamps or history the current contract already writes.

**Commit boundary**

One commit for the meta subtype, the local presenter, locales, and tests.

**Prompt template for the next phase**

> Tighten the epistemic contract and unify active and same-turn photo field classification in one commit. Preserve current-turn precedence. Do not change identity promotion, photo relevance, or `DocumentIdentityScope`.

### F4 — Enforce photo and source claim strength, in one commit

**Goal**

One commit does all three:

1. consistent photo headings and field contract;
2. literal visual read separated from vision interpretation;
3. `safety_evidence` restricted to literal evidence.

Also keep generic guidance non-exclusive, keep the prompt tail, and do not add a direction the technician did not state.

**Why**

T6's causes are the contaminated question, the flat visual list, `safety_evidence` containing Condition and Component, and non-exclusive reasoning that was not required. The heading mismatch is the latent text-lane defect. A headings-only deploy would copy interpreted fields into that lane. The companion cap would then drop the no-compatible tail without a signal.

**Files expected to change**

- `app/services/rag/active_photo_context.rb`
- `app/services/session_context_builder.rb`
- `app/services/rag/companion_guidance_context.rb`
- `app/services/rag/photo_question_answer_service.rb`
- `app/prompts/field_photo_prompt.rb`
- `app/prompts/bedrock/generation.txt`
- `app/services/rag/provenance_segmenter.rb` only if presentation-band tests prove a required adjustment
- `test/services/rag/active_photo_context_test.rb`
- `test/services/session_context_builder_test.rb`
- `test/services/rag/companion_guidance_context_test.rb`
- `test/services/rag/photo_question_answer_service_test.rb`
- `test/services/rag/answer_safety_processor_test.rb`
- `test/services/rag/provenance_segmenter_test.rb`
- `test/services/rag/field_companion_pilot_readiness_test.rb`

**Exact behavior**

- Shared bounded map: literal photo fields are the manufacturer read, the model read, and exact visible text. Interpreted fields are canonical component, subsystem, condition, relevance, and target visibility.
- Stable active-episode photo heading and explicit literal and interpreted groups.
- Companion context reads same-turn and active-episode photo evidence through that contract.
- `safety_evidence` is literal fields only.
- Companion `Question` remains the raw turn from F2.
- Generic diagnostic reasoning is explicitly non-exclusive.
- Section 5.3 rules go into normal generation, companion guidance, and photo-answer prompts, once each.
- Directional rule, general: do not introduce a spatial or directional relation the technician did not provide. No production phrase list.
- Truncation drops Question, history, and redundant context first. It never drops applicability, safety, or the no-compatible closing lines.
- Emit `context_truncated` and the companion contract on existing `prompt_version`.
- Keep output mobile and concise. Conceptual source bands do not require four mandatory headings.
- Do not turn `AnswerSafetyProcessor` into a natural-language inference engine. Keep its current deterministic identifier, value, and connection guards. Semantic over-read is the prompt plus the real-model eval.

**Invariants**

- Stored `visual_observation` schema and photo fingerprint semantics stay compatible.
- Relevance, explicit reuse, and identity promotion are unchanged.
- A visible manufacturer or model remains usable for current identity promotion under existing rules.
- No foreign manual body enters known or no-compatible generation.
- No new model call.
- Current-turn precedence from F2 stays intact.
- This commit is atomic. Do not ship headings without the split and the `safety_evidence` restriction.

**Tests**

- The active photo block is parsed by companion context. That closes the heading mismatch on a text follow-up.
- A maximum-size companion context keeps the no-compatible and applicability tail. `context_truncated` is true when Question or history was cut, and false when nothing was cut.
- Visible display text may be repeated only as visible text.
- A floor-specific symptom may yield a local-check hypothesis and cannot exclude controller or general logic.
- The section 4 production sentence (`pasado de nivel` → `por encima del nivel correcto`) remains a deterministic incident regression: generation input does not add an above/below relation. It is not a hidden-eval case.
- Compatible documented claims remain citeable and distinct from Danebo suggestions.
- The initial photo response labels condition and component as interpretation, not literal fact.
- `generation_context` reports `photo_literal=separated` and `photo_interpretation=separated` from the context actually sent.

**Negative tests**

- An interpreted condition cannot authorize "the controller is good" or any equivalent health claim.
- A visible status string cannot authorize "no faults".
- The no-compatible route cannot cite or teach foreign bodies.
- An exact visible code cannot gain a meaning or function merely because it is visible.
- Photo interpretation cannot overwrite a technician fact or resolve a conflict.
- `safety_evidence` does not contain interpreted Condition or Component.

**Observability**

Keep current photo, identity, and scope events. Emit `prompt_version` for the companion contract next to `generation_mode`. Emit `context_truncated` and `generation_prompt_chars`. Do not log a second copy of the photo payload.

**Cost / latency**

- New LLM calls: 0
- New retrieval calls: 0
- Expected token impact: small bounded contract changes, one occurrence of each rule, inside `MAX_CHARS` on the companion path. The review's unmeasured estimate for epistemic rules plus the verbatim turn on the managed lane is about 100–200 input tokens, on top of F1's unknown-identity block.
- Expected latency impact: minimal

**Exit criteria**

- The T6 fixture yields the correct identity, zero citations, the display string as visible text only, and no controller-health or exclusion claim. `Question` is the raw turn.
- A max-size fixture does not truncate the safety or applicability tail.
- The real-model hidden eval has zero source-band violations and zero directional additions, using the unseen spatial wordings in section 8 rather than the production sentence.
- Photo promotion, reuse, late-writer, and known-scope tests remain green.

**Commit boundary**

One commit for photo field classification, the prompt budget, the epistemic rules, and tests. Not a headings-only commit.

**Prompt template for the next phase**

> Run orthogonal hidden-state journeys and update only canonical docs. Deterministic tests check generation input. The real-model eval checks semantic output. Any failing behavior returns to its owning phase. Do not patch examples in the certification phase.

### F5 — Hidden-state certification and canonical documentation

**Goal**

Prove the three contracts, and current-turn precedence, across realistic orthogonal journeys. Document the architecture that was actually built.

**Why**

Example-specific tests would allow another bug-to-patch cycle. Deterministic journeys that only assert on a fake answer do not prove the semantic contract. A production deploy is not this phase.

**Two checks**

Deterministic tests verify the **input** to generation and the route:

- raw current turn present;
- retrieval query separate from that turn;
- evidence bands separated;
- applicability block present when identity is unknown;
- no foreign body on the no-compatible path;
- safety and applicability tail not truncated;
- zero-call routes make zero retrieval and zero response LLM calls.

The real-model eval verifies **semantic output**:

- no cross-brand applicability;
- no unsupported exclusion;
- no directional sharpening;
- useful generic help when identity is unknown or no compatible manual exists.

Hidden truth stays in expectations. The application receives it only through the technician turn or the submitted photo at that step. The hidden spatial set is the four unseen wordings in section 8, not the production leveling sentence.

**Canary**

The canary is a pre-release run with real Bedrock, on a human-chosen local or staging target, against the candidate image SHA. It uses the existing pilot export. It is not a production deploy and it does not authorize one. A post-deploy canary is outside this plan unless a later human release decision asks for it.

This planning document still does not deploy. Executing F5 later still does not deploy.

**Files expected to change**

- `test/services/rag/field_companion_hidden_journeys_test.rb` (or a clearly separated section of the current readiness test)
- `test/fixtures/files/field_companion/field_companion_hidden_journeys.yml`
- `test/fixtures/files/field_companion/turn_interpreter_eval.yml`
- `test/fixtures/files/field_companion/turn_interpreter_holdout.yml`
- `lib/tasks/turn_interpreter.rake` only to score new fields such as `meta_kind` and absence
- `docs/ACTIVE_ARCHITECTURE.md`
- `docs/SESSION_AND_RETRIEVAL.md`
- `docs/PILOT_TRACEABILITY.md`
- this master plan, to append `Execution findings — F5` only. F5 does not create a next phase and does not change target contracts. Earlier phases append their own findings and may precise the next phase under the adaptive protocol.

**Exact behavior**

- Deterministic CI journeys use fake retrieval, generation, and Vision at the boundaries, and real session, reducer, composer, policy, scope, and response guards.
- Paid eval and holdout use the existing bounded TurnInterpreter tasks. No CI network calls.
- The response semantic eval is the separate real-model run, not a CI test.
- The canary export is checked against section 9 before any human release decision.
- Update canonical docs. Do not create a second architecture or trace guide.

**Invariants**

- Certification does not introduce production conditionals or phrase-specific patches.
- Failures are fixed in the owning phase, then the whole gate is rerun.
- No credentials or tenant data are placed in fixtures.
- Call accounting uses attributed `kb_retrieve`. An unattributed retrieve fails the gate. Expected retrieval calls and actual retrieval calls must match.

**Tests**

All journeys in section 8, the deterministic input contract, and the full relevant regression matrix. The real-model semantic checks are the eval, not the CI assertions on fake answers.

**Negative tests**

Cross-tenant photo or manual access, stale photo writer, uncertain-photo promotion, goal contamination, pin release, foreign procedure applicability, assistant-hypothesis recall, directional sharpening, truncated safety tail, and a pure-meta classification of a recall that also reports a new fault.

**Observability**

The export must reconstruct the F0 chain, including `meta_kind`, applicability mode, `query_components`, raw versus effective query, attributed `kb_retrieve`, `results_count` versus `contexts_delivered`, `generation_context`, `generation_mode`, and the final response.

**Cost / latency**

- New production LLM calls: 0
- New production retrieval calls: 0
- Expected production token impact: 0 beyond F1–F4
- Expected production latency impact: 0 beyond F1–F4
- Validation-only calls: existing TurnInterpreter eval and holdout, the bounded semantic eval, and one pre-release canary. Record tokens, cost, p50, and p95. If F1b was activated, those latency figures are part of the canary.

**Exit criteria**

- Targeted tests, full Minitest, security and architecture tests, and `git diff --check` pass.
- Eval and holdout: zero mismatches, fallbacks, and field rejections.
- Every hidden journey passes the deterministic input rubric.
- The real-model semantic eval has zero applicability, exclusion, and directional violations, and it still gives useful generic help.
- The canary export is complete, names the candidate image SHA in its manifest, contains no applicability or epistemic violation, and its `kb_retrieve` count matches the expected retrieves.
- Canonical docs match the code.
- No production deploy was performed.

**Commit boundary**

One commit for certification fixtures, the harness, and canonical docs. No production behavior patch belongs here.

**Prompt template for the release handoff**

> Stop. Append `Execution findings — F5`. Present the phase evidence, costs, latency, remaining risks, and exact SHAs for architectural review. Do not deploy, do not open F6, and do not start a new feature without the human release decision.

## 8. Orthogonal hidden-state journeys

The fixture may know expected truth. The system may not receive it until the technician supplies it. Deterministic runs assert on generation input and routing. Semantic output is the real-model eval.

### J1 — unknown identity, door symptom, no photo yet

1. `Estoy en otro equipo. La puerta cierra y vuelve a abrir en el piso 7.`
2. If Danebo asks identity: `Todavía no veo la placa.`
3. `Pasa solo bajando.`
4. `No aparece ningún código.`

Corpus distractors: BLT leveling, Monarch controller, and another manufacturer's door manual. Expected input: open retrieval allowed, `identity_unknown_reference` present, raw turns separate from the composed query, absence persisted. Expected semantic output: no foreign code, terminal, value, or procedure applied; one useful generic observation or question; floor and direction are not treated as proof.

### J2 — evidence offer, then photo reveals a different manufacturer

Continue J1:

1. `Tengo una foto del tablero, ¿te sirve?`
2. Only after the local response, submit a tenant-owned photo fixture that visibly reads `KONE`, a different model token, and `READY`.
3. `¿Qué alcanzas a leer?`

Expected: the offer preserves the case and costs zero external calls. Photo identity follows existing promotion rules. `READY` stays literal text. The generation question on the last turn is that literal question, not a composed retrieval string.

### J3 — known identity, no compatible docs, unrelated symptom

1. New case: `En este Schindler la alarma de inspección suena intermitente en piso 5.`
2. The technician supplies the model when asked.
3. The retrieval fixture contains only foreign BLT/Fuji procedures.

Expected: known and no-compatible path; no foreign body or citation; `safety_evidence` literal only if a photo is in context; a useful generic suggestion, explicitly non-exclusive; no invented parameter or terminal.

Use a synthetic model token in fixtures that cannot accidentally match the repository catalog. The test must not rely on a real manufacturer's procedure.

### J4 — neutral spatial complaint and case recall

1. New case: `Al llegar al piso 2 no queda a ras.`
2. `Son como 8 milímetros, siempre igual.`
3. `No veo fallas en pantalla.`
4. `Recuérdame el problema y qué está confirmado.`

The hidden spatial set, of which this journey uses the first wording, is:

- `no queda a ras`
- `queda con escalón`
- `se pasa un poco`
- `queda desfasado`

Expected: no above, below, left, or right relation is introduced; recall contains the literal goal, observations, and absence with source; recall excludes retrieved causes and assistant hypotheses; zero retrieval and zero generation on recall. The production leveling sentence is not this fixture.

### J5 — mixed evidence offer must remain technical

1. New case: `La cabina vibra al arrancar y tengo una foto donde se ve E27, ¿te sirve?`

Expected: not pure `meta`; symptom and literal code are retained according to catalog and fault-context rules; offer text does not become the goal; no scenario identity is pre-seeded.

### J6 — episode boundary and late writer

1. Start a case with a photo job in flight.
2. The technician opens another lift with a brake-noise symptom at another floor.
3. Complete the old photo job.
4. Ask for active-case recall.

Expected: stale writer dropped; no old photo, identity, or goal in the new case; recall shows only the new case; pins follow existing case rules.

### J7 — tenant isolation

Seed identical photo and document identifiers in two accounts. Resolve and retrieve from account A while account B owns the tempting matching artifacts.

Expected: unavailable or denied foreign data; no title, OCR text, URI, identity, or chunk body leaks into the prompt, the trace, or the response.

### J8 — active photo, later text turn, known identity, no compatible docs

This is the only new journey. It covers the latent text lane.

1. Promote a tenant-owned photo on a known-identity episode. The photo has a literal visible string and an interpreted condition and component.
2. The next turn is text. It does not mention the photo. Example shape: `Sigue igual en el piso 4.`
3. Retrieval returns only foreign manuals, so the path is no-compatible companion guidance.

Expected generation input:

- literal and interpreted groups are both present, from the active-episode photo block;
- `safety_evidence` contains the literal string only;
- `Question` is the raw text turn;
- no foreign body is in the prompt;
- the safety and applicability tail is present.

Expected semantic output on the real-model eval: the visible string is not a health claim, and the interpreted condition does not exclude a subsystem.

### Additional cases, not new journeys

- `No veo código, pero ahora hace ruido al frenar` preserves both facts. Owned by F2.
- `Recuérdame qué tenemos; además ahora no abre la puerta` is not pure meta. Owned by F3.
- T4 generation-input contract: raw current turn present, retrieval query separate. Owned by F2 and rechecked in F5.
- Maximum companion context: safety and applicability tail never truncated. Owned by F4.
- Cohort report: an attributed `kb_retrieve` appears in the counts. Owned by F0 and rechecked in F5.

## 9. Automatic validation protocol

For every phase, Grok produces a machine-readable evidence bundle under `tmp/` (never committed) with commands, exit codes, test counts, and cost and latency outputs.

1. **Preflight**
   - Assert HEAD is the preceding phase SHA and worktree changes are understood.
   - Run `git diff --check`.
   - Record relevant flags without changing production.

2. **Phase tests**
   - Run the exact changed service and model tests.
   - Run `test/services/rag/field_companion_pilot_readiness_test.rb`.
   - Run the existing tenant, photo late-writer, goal, and document-scope suites. Do not add duplicate copies of those suites in F0.
   - Run full Minitest before closing the phase.

3. **External-call accounting**
   - Spy on interpreter, retrieval, response model, and Vision boundaries.
   - Assert expected counts per journey.
   - Compare those expected retrieval calls with attributed `kb_retrieve` counts. An unattributed retrieve, or a count mismatch, fails the phase.
   - Any unexplained increment fails the phase.

4. **Interpreter gate**
   - `bin/rails turn_interpreter:eval`
   - `bin/rails turn_interpreter:holdout`
   - Require zero mismatches, fallbacks, and field rejections. Record p50, p95, input and output tokens, and estimated cost.

5. **Deterministic input rubric**
   - Raw turn present and separate from the retrieval query.
   - Unknown identity: applicability block present; foreign body is reference-shaped in the input, not an imperative current-job procedure.
   - Known and no-compatible: no foreign procedural body in the generation input; tail lines present.
   - Photo: literal and interpreted groups separated; `safety_evidence` literal only.
   - Recall and evidence offer: zero RAG calls.

6. **Real-model semantic rubric**
   - Unknown identity: no current-job foreign brand, model, code, terminal, value, or procedure. Any analogous reference names source and page and says it is not the job instruction. At least one useful generic check.
   - Known and no-compatible: zero foreign procedural body or citation. The suggestion stays non-exclusive and useful.
   - Photo: visible text stays literal. Interpretations are labelled. No health, function, or exclusion leap.
   - Direction: no above, below, left, or right relation without technician evidence, judged on the unseen spatial set.
   - Recall: only active episode state and scoped photo literal reads.

7. **Trace gate**
   - Export the bounded pre-release canary with the existing pilot export, from local or staging, not from a production deploy.
   - Verify the candidate image SHA, no unreadable containers, and expected correlation coverage.
   - For each turn, reconcile `report.txt`, `report.json`, `pilot_events`, `TURN_EVIDENCE`, `RAG_QUALITY`, photo events, `generation_mode`, and attributed `kb_retrieve` counts.
   - Confirm `original_query` is the raw turn wherever raw capture is enabled.

8. **Stop conditions**
   - Any tenant leak, stale write, goal contamination, false identity promotion, known-scope reopening, foreign procedure applicability, unexplained call increase, unattributed `kb_retrieve`, or trace-dependent behavior stops execution.
   - A failed unknown-identity semantic eval stops for the F1b human yes/no. It does not open a new design and it does not authorize F1b.
   - Fix other failures in the owning phase and rerun from that phase. Do not add a phrase-specific patch in F5.

9. **Close the phase**
   - Append `Execution findings — Fn` to this file from the evidence bundle and the commit SHA.
   - Reconcile the next phase under the adaptive protocol in section 7.
   - Stop before executing it. The prewritten prompt template is not the execution prompt once a previous phase has completed.

## 10. Traceability decision: small extension

The pilot needs to explain T3, T4, T6, and the routing decisions. Existing episode state already preserves literal observation text and correlation. A new ledger would duplicate data and widen privacy and retention. Bounded accepted semantics close the debugging gap at zero inference cost.

### Minimum chain

```text
input            TURN_EVIDENCE.original_query (raw, every lane, under PILOT_AUDIT_CAPTURE)
                 + original hash always + correlation_id
interpretation   turn_interpreter: move, meta_kind, status, fallback, field_rejections
semantic appl.   interpreter_assertions
                 act:kind:slot:applied|ignored(reason):span
episode delta    field_companion_turn: episode_decision, episode_fields_changed,
                 state_before_sha256, state_after_sha256,
                 goal_text, goal_source_correlation_id
query compos.    query_components, original_sha256, effective_sha256
                 assistant events do not carry those digests
route            interaction_completed.generation_mode
                 meta_kind and scope status where the mode string is shared
identity         identity_promotion + retrieval identity
applicability    evidence_applicability + reason
                 on open_retrieval and document_identity_scope
retrieval        kb_retrieve attributed to account, user, session, correlation
                 results_count, search_type, filter_fingerprint
                 managed lane: R1A filter + RAG_QUALITY.retrieved_source_uris
document scope   document_identity_scope result, reason, needles,
                 results_count, contexts_delivered
gen. context     generation_context, generation_prompt_chars, context_truncated
model / mode     existing llm_calls (model, tokens, token_source, latency)
                 joined by correlation_id and generation_mode
                 prompt_version when F4 emits it
citations        citations_count, citation_titles
                 evidence_class derived in the report
response         TURN_EVIDENCE.answer / answer_sha256
```

### Do now

| Signal | Where | Phase |
|---|---|---|
| `move`, `status`, `fallback`, `field_rejections` | existing `turn_interpreter` | already present |
| `interpreter_assertions` with applied or `ignored(reason)` | existing allowlist | F0 |
| real `episode_fields_changed` | `field_companion_turn` | F0 |
| `state_before_sha256`, `state_after_sha256` | existing allowlist | F0 |
| `query_components` | new allowlist key | F0 |
| truthful `original_sha256` / `effective_sha256`; no assistant query digests | `field_companion_turn` | F0 |
| raw `original_query` on every lane | `TURN_EVIDENCE`, same capture policy | F0 |
| `generation_mode` on `interaction_completed` | existing field | F0 |
| attributed `kb_retrieve` | existing event plus user and session | F0 |
| `results_count`, `contexts_delivered` | `document_identity_scope` | F0 |
| `generation_context`, `generation_prompt_chars`, `context_truncated` | `interaction_completed` | F0, truncation policy in F4 |
| `evidence_applicability` + reason | `open_retrieval`, `document_identity_scope` | F1 |
| `meta_kind` | `turn_interpreter` | F3 |
| companion `prompt_version` | existing field | F4 |

### Defer post-pilot

- Per-event `app_revision`. The export manifest is enough for this pilot.
- Full before/after state summaries. Field diffs plus hashes are enough.
- Managed `top_k` telemetry. R1A and `RAG_QUALITY` URIs already describe that lane. `top_k` is configuration.
- Historical case memory.
- `MaintenanceCase` and `MaintenanceCaseProjection`.
- A general provenance database, including token-level interpreter offsets.
- A citation-UI chip that would label "reference for other equipment". The response contract carries that disclaimer. The chip is not this plan.
- Event sourcing.

### Reject

- Raw tool output.
- Full prompt persistence.
- Chunk bodies in normal mode.
- Image bytes.
- A separate `response_mode`.
- A second policy class for applicability.
- New top-level moves, a new database, a response-judge LLM, and a second retrieval by default.

### Regression risks the owning phase must keep

1. Headings without the literal/interpreted split widen text-lane over-reading. F4 is one commit.
2. Companion rules can push the no-compatible tail past `MAX_CHARS`. F4 truncates from the head and tests the tail.
3. `meta_kind` and `absent` can move classification. The exposed contract is `fe95555`: a technical fact inside an evidence offer stays technical.
4. Unknown-identity applicability can collapse into a refusal. F1 requires a useful generic check.
5. The interpreter can confuse `absent` with `negate`. F2's negative tests cover `No es E51` and `No veo la placa`.
6. Applicability, epistemic rules, and the verbatim turn share the managed template. F1 and F2 keep `$output_format_instructions$` last and inside Bedrock's limits.
7. The verbatim block must not also appear as the current `User:` line in `Recent Conversation`.
8. Case recall must use the live episode's `active_photo.field_photo_id`, not a cross-episode fingerprint match.
9. An unmatched negate kept in the retrieval query may add "código" noise. That is accepted only together with a persisted absence line.
10. `safe_value` cuts array items at 120 characters. F0 marks that truncation.

## 11. Canonical documentation updates

Update, do not duplicate:

- `docs/ACTIVE_ARCHITECTURE.md`: `DocumentIdentityScope` owns unknown-identity mode `identity_unknown_reference`; `.apply` stays the known-identity policy. Document current-turn precedence, deterministic local meta intents, and photo claim bands. The managed RAG lane remains managed unless F1b was separately approved.
- `docs/SESSION_AND_RETRIEVAL.md`: open retrieval and pins are scope, not applicability. The composed query is retrieval. The literal turn is the generation question. Document deterministic active-case recall and free-standing absence.
- `docs/PILOT_TRACEABILITY.md`: record the small-extension fields, `kb_retrieve` attribution, and the removed deliberate-debt entries that this work closes. Keep the maintenance-case deferral. Do not add per-event `app_revision`.

No new general RAG architecture document is needed. Historical plans remain historical.

## 12. What must not change

- Do not reopen the focused-goal or explicit-photo-reuse fixes without a failing regression tied to this plan.
- Do not change `DocumentIdentityScope` known-identity semantics.
- Do not require manual selection before technical help.
- Do not change tenant/general-corpus authorization, pin lifecycle or retrieval ranking.
- Do not make photo identity promotion more permissive.
- Do not add a response-judge LLM, second retrieval, multi-agent workflow, database, event store or generic policy framework.
- Do not encode Orona/PBCM-V3/BLT/plant-3 phrases as production rules.
- Do not deploy from this planning stage.

## 13. Open questions

None block F0. Product copy for the evidence-offer and no-active-case messages can be reviewed during F3 without changing the architectural contract or the call budget.

F1b is not an open design question. The fallback is fixed in section 5.1. It runs only after the F1 semantic eval fails and a human answers yes.

## 14. Final acceptance statement

The work is complete only when Danebo can begin with unknown equipment, retrieve broadly, remain useful, and still keep these boundaries visible in both response and trace:

`what the technician just said` ≠ `the composed retrieval query` ≠ `what the photo literally shows` ≠ `what vision interpreted` ≠ `what a compatible manual documents` ≠ `what another manual does` ≠ `what Danebo suggests next`.

That is the smallest common correction for the observed class of failures.

This reconciliation does not authorize F0. The next step is a human review and an explicit `GO F0`. Each later phase needs its own authorization after the previous phase's findings have been written into this file.

## 15. Opus reconciliation

Review verdict incorporated here: `APPROVE WITH CHANGES`.

Checked against the code at the investigation baseline. One citation in the review does not match the file: the cohort does not drop `kb_retrieve` at `pilot_metrics_report.rb:127`. That line filters conversation messages. The drop is `PilotTelemetryReader#cohort_payload?` and `PilotEvent.hot_path_rows`, because `kb_retrieve` is logged without `user_id`. The required fix is unchanged: attribute the event. The rest of C1–C10 matches the code or the plan text, including `MAX_CHARS` tail truncation, the assistant digest, the `(this turn)` heading on the photo worker, and `generation_mode` being read from `evidence_route` rather than from `interaction_completed`.

| Opus correction | Incorporated section |
|---|---|
| C1 current-turn precedence | §1, §3, §4 transversal defect, §5.2, F2; F4 must preserve it |
| C2 T6 cause and atomic photo commit | §3 T6, §4 Issue C, §5.3, F4, J8 |
| C3 companion prompt budget | §5.3, F4 tests, `context_truncated` in F0 and §10 |
| C4 reuse assertion and state fields; drop assistant digests | F0, §10 |
| C5 attribute `kb_retrieve`; `results_count` / `contexts_delivered` | §3 trace detail 5, F0, §9, §10. Mechanism corrected as above |
| C6 emit `generation_mode`; no `response_mode` | F0 lane table, F3, §10 |
| C7 raw `original_query` on the worker | F0, §10 |
| C8 `DocumentIdentityScope` owns the mode; F1b pre-specified; useful generic check | §5.1, F1 |
| C9 deterministic input vs real-model output; canary is not a deploy | F5, §8, §9 |
| C10 generic directional rule; unseen spatial set | §4 Issue E, §5.3, F4, J4 |

```text
new DB: NO
new session architecture: NO
new top-level moves: NO
new production LLM calls: 0
new production retrieval calls: 0
MaintenanceCase: DEFER POST-PILOT
historical memory: DEFER POST-PILOT
```

F1b, if a human later says yes, still adds no LLM call and no retrieval call. It replaces managed `RetrieveAndGenerate` with one existing retrieve plus existing direct generation.

## Execution findings — F0

```text
F0 commit SHA:
9e9e79c9773086cc60b91263c199239fee8524e8

Actual files changed:
app/services/rag/causal_trace.rb
app/models/conversation_session.rb
app/services/rag/query_composer.rb
app/services/session_context_builder.rb
app/services/rag/companion_guidance_context.rb
app/services/bedrock_rag_service.rb
app/services/rag/document_identity_scope_event.rb
app/services/rag/structured_evidence_route.rb
app/services/rag/context_evidence_route.rb
app/services/rag/ambiguous_model_responder.rb
app/controllers/rag_controller.rb
app/controllers/concerns/rag_query_concern.rb
app/services/query_orchestrator_service.rb
app/services/rag/photo_question_answer_service.rb
app/jobs/field_photo_analysis_job.rb
app/services/pilot_usage_log.rb
app/services/pilot_metrics_report.rb
app/services/pilot_metrics_human_formatter.rb
app/services/pilot_export_trace.rb
docs/PILOT_TRACEABILITY.md
plus the tests named in the evidence bundle

Actual code paths discovered:
Turn tokens: ConversationSession#log_turn_interpreter → Rag::CausalTrace.assertion_tokens
Episode delta: apply_owner_perception! forks before the reducer, then ActiveEpisodeTurn.changed_fields; digests go through episode_digest on a fork or a parsed copy
Query parts: QueryComposer.explain; call still returns the query string
Raw photo turn: FieldPhotoAnalysisJob raw_question keyword, telemetry only; functional question is unchanged
Managed manifest: the prompt already stored at generation_configuration.prompt_template.text_prompt_template
Scope counts: document_identity_scope_result after retrieve; structured scope_identity after its existing retrieve
kb_retrieve ids: explicit user_id and conversation_session_id from the caller
Cohort card: interaction_completed.generation_mode, then evidence_route
Cohort question: TURN_EVIDENCE.original_query when capture is on; capture off deletes a composed backfill

Tests/evals:
targeted trace + readiness + goal + tenant: 244 runs, 1861 assertions, exit 0
photo, document scope, bedrock, structured, session: 447 runs, 3193 assertions, 12 skips, exit 0
full Minitest: 4183 runs, 22971 assertions, 0 failures, 192 skips, exit 0
RuboCop on touched Ruby files: 0 offenses
git diff --check: exit 0
interpreter eval, holdout, real-model rubric, and canary export: not run; F0 does not change those paths and those commands bill model calls

Trace signals now available:
turn_interpreter.interpreter_assertions as act:kind:slot:applied|ignored(reason):span
field_companion_turn episode_fields_changed, state_before_sha256, state_after_sha256
query_components; original_sha256 = raw turn; effective_sha256 = retrieval query actually used
assistant field_companion_turn omits those query digests
interaction_completed.generation_mode
kb_retrieve account_id, user_id, conversation_session_id, correlation_id when the caller has them
document_identity_scope results_count and contexts_delivered after a retrieve
generation_context, generation_prompt_chars, context_truncated from the prompt actually sent
llm_calls still carry model, tokens, latency, token_source on the same correlation_id
meta_kind and evidence_applicability are allowlisted and unemitted

Behavior findings:
T4 "No veo ningún código de falla" is still ignored(no_slot). The span is not persisted as absent. current_turn is dropped when the composer strips it. Seeded goal and observations keep the effective hash different from the raw hash. episode_fields_changed stays empty. state hashes differ when touch! moves updated_at.
"Tengo una foto, ¿te sirve?" stays move=meta, composed nil, episode fields unchanged, state hashes equal on a seeded episode. generation_mode=meta is traceable. No meta_kind.
Known-identity foreign chunk: results_count 1, contexts_delivered 0, danebo guidance present, photo bands absent on that prompt.
Photo blocks that exist are mixed. F4 has not split them.
Capture off does not copy the composed query into original_query or the cohort question.

Regression findings:
444c910 goal tests and 8faf2f8 photo reuse / late-writer tests stayed green without new copies.
Tenant catalog, document identity scope, and pilot readiness stayed green.
No production behavior assertion was rewritten to accept a new answer, route, or episode write.

Unexpected constraints:
safe_value cuts an array item to 120 characters and does not add a truncation marker. CausalTrace.bounded puts :truncated inside the token so the marker survives that cut.
ActiveEpisode#to_h shares the observations and identifiers arrays. A second to_h on the live episode can shrink the payload that will be persisted. The digest now uses a fork or a parsed copy.
DeterministicRenderer has an account and no user id. Its kb_retrieve stays without an invented user_id, so a user-scoped cohort still omits it.
fallback_retrieve does not emit kb_retrieve. F0 did not add that event.
An early document-identity return before retrieve omits counts rather than emitting a fake 0.
Photo-only turns do not get a generative fallback when generation_mode is nil.

Assumptions confirmed:
Cohort loss of kb_retrieve is the user_id filter in PilotTelemetryReader#cohort_payload? and PilotEvent.hot_path_rows, not pilot_metrics_report.rb message filtering.
changed_fields does not include updated_at.
QueryComposer.call remains the retrieval string. explain is observational and fail-open around the component tokens.
PILOT_AUDIT_CAPTURE still gates raw text. TurnEvidence was not weakened.
Logging stays after the ConversationSession lock. A trace exception does not roll back the turn.
0 is kept for contexts_delivered. nil is omitted.

Assumptions invalidated:
The plan text said safe_value marks a cut span. It only cuts. The marker has to be written into the token first.
A second load_generation_prompt_with_locale call is not the context that was sent. The trace uses the template already on the request. custom_config can replace that template.
"Episode unchanged" for an ignored negate is empty episode_fields_changed, not necessarily equal state hashes. touch! rewrites updated_at.

Actual call-count impact:
new production LLM calls: 0
new production retrieval calls: 0

Actual latency/cost impact:
local hashes, token arrays, and one read of the prompt string already built for the request
token impact: 0
no production flag change

Deferred items:
F1 evidence_applicability values
F1b
F2 act=absent and preserving the dropped T4 turn
F3 meta_kind
F4 truncation policy and separated photo bands
managed top_k telemetry
per-event app_revision
MaintenanceCase and historical memory
interpreter eval, holdout, real-model rubric, canary export
product debt left in PILOT_TRACEABILITY: photo-offer UX, open-retrieval specificity, over-reading weak visual evidence

Corrective follow-up:
The first F0 commit 9e9e79c9773086cc60b91263c199239fee8524e8 removed raw_question: @raw_question from QueryOrchestratorService#execute_knowledge_base_query when it builds StructuredEvidenceRoute. That argument existed at 5f9fbe4e9c03aafedc9c3e573d8c5dc02d748356. It is not telemetry. StructuredEvidenceRoute sets @raw_question = raw_question.presence || @question, and rescue_mode / rescue_base_text use that value. Without the forward, an elliptical turn such as "Edel-k2" was replaced by the composed query, so a rescue could keep historical identifiers (EM2000, DL4, CTA, ALJO) and the current goal handling changed. The earlier F0 suite did not catch it: structured_evidence_route_test.rb builds the route directly, and no orchestrator test checked the boundary. The claim that functional behavior, routing, and retrieval were unchanged was therefore not demonstrated for this path.
Corrective commit af983f04de325aa6e823f56b2cef6d8ce8f2881b restores that single forward. StructuredEvidenceRoute itself is unchanged. New regression: QueryOrchestratorServiceTest "an elliptical raw turn reaches structured rescue without the composed history". It failed on 9e9e79c with raw_question nil, and passes after the forward: the route receives Edel-k2, rescue_base_text keeps the current goal, and the historical tokens stay out. Re-run after the fix: orchestrator + structured route + F0 targeted + readiness + goal + photo late-writer + tenant catalog + document identity scope, 496 runs, 3991 assertions, 6 skips, exit 0. Full Minitest 4184 runs, 22986 assertions, 0 failures, 192 skips, exit 0. RuboCop on the two Ruby files: 0 offenses. git diff --check: exit 0. New production LLM calls: 0. New production retrieval calls: 0.
Wiring review of the F0 boundaries found no second case where a functional argument stopped being passed. Pre-F0, raw_question had one production caller: this orchestrator forward. The photo lane's new raw_question stays telemetry; PhotoQuestionAnswerService does not pass conv_session, so the structured route is not eligible there. The structured generation manifest still passes raw_turn: nil and reads @question. That manifest was added by F0 and does not change rescue or retrieval.
After this correction, the pre-F0 structured rescue contract is preserved. F1 is still not authorized.
```

F1 above is reconciled to these findings only: the allowlist edit is unnecessary, the injection point is the sent template, managed `generation_mode` stays `generative`, and unknown identity does not invent scope counts. F1 is not authorized.
