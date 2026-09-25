# Plan — Haiku Semantic Query Analysis (2026-09-24)

```text
PLAN_VERSION: v2
ARCHITECTURE_DECISION_DATE: 2026-09-25
STATUS: plan_v2_corrections_applied
CURRENT_PHASE: plan_v2_pending_commit
LAST_CLOSED_PHASE: none
NEXT_AUTHORIZED_PHASE: PLAN_V2_COMMIT
BASELINE_COMMIT: 55df6a802618fe9fb5305e6d88f363c9efb43ec8
RUNTIME_BEHAVIOR_BASELINE: dce25d080aaba1779898339206d7ec297bdbd3e7
EXPERIMENT_BRANCH: experiment/haiku-semantic-query-analysis
ARCHITECTURE_DECISION: HYBRID_MINIMAL
```

**v2 status:** living plan. Opus corrections are applied in this document. P0 is specified below and is not implemented. Runtime is unchanged by this document.

`BASELINE_COMMIT` is `PENDING_PLAN_V2_COMMIT` because this plan text is not in a commit yet. After the plan-only commit, replace `BASELINE_COMMIT` with that commit hash before P0 starts. The hash cannot be known before that commit. Do not start P0 while the value is still `PENDING_PLAN_V2_COMMIT`. That one-line replacement is not a separate commit: leave it uncommitted, keep it out of Commit A, and include it in Commit B.

**Historical v1** starts at the heading `HISTORICAL V1`. Do not delete it. Assumptions marked `INVALIDATED` in section 2 no longer authorize implementation.

---

## 0. What this revision closes

Architecture is not reopened. Accepted decision: `HYBRID_MINIMAL`.

```text
Open-world semantic relation/coreference → semantic perception model
State authority / persistence / safety / provenance /
validation / query construction → deterministic Ruby
```

The semantic model is not an agent, a planner, a second RAG, the state owner, the retrieval owner, a technical authority, or a source of evidence.

Independent reviews already accepted:

```text
RECOMMENDED_ARCHITECTURE: HYBRID_MINIMAL
CURRENT_V4_ASSESSMENT: GOOD_BASE_NEEDS_SEMANTIC_LAYER
HAIKU_ROLE: CONDITIONAL
REFACTOR_REQUIRED: MODERATE
COST_ASSESSMENT: ACCEPTABLE_FOR_CAPABILITY
LATENCY_ASSESSMENT: NEEDS_OPTIMIZATION
```

v4 stays. `ConversationSession` and `ActiveEpisode` stay. Correlation, provenance, recency, atomic persistence, and safety guards stay. `common_noun?`, `identity_complement?`, `unreaffirmed_name?`, `technical_nps`, and `FollowupQueryRewriter` are retirement candidates, not a third permanent engine beside Haiku.

## 1. Worktree fence

Recorded at plan-authoring time on `experiment/haiku-semantic-query-analysis`, HEAD `04586d5`.

```text
OUT_OF_SCOPE_EXISTING_WORKTREE_CHANGES:
 M docs/PLAN_PILOTO_ELEMONT_2026-09-24.md
?? docs/ARCH_REVIEW_CONVERSATIONAL_VS_HAIKU_2026-09-25.md
?? script/patch_elemont_chunk_p1_2_q123_2026-09-24.rb
?? script/patch_elemont_chunk_p1_2_q4_2026-09-24.rb
?? script/patch_elemont_designator_retrieval_2026-09-24.rb
?? script/patch_elemont_random12_gaps_2026-09-24.rb
```

Do not edit, stage, revert, or include these in any phase commit. The interrupted Codex session left no diff to recover. Its confirmed notes are incorporated below as findings, not as code.

Reported test run from that interrupted session, not re-executed while writing v2: 412 tests, 0 failures. The architectural review on this HEAD reports a separate relevant slice of 394 tests, 0 failures, 22 skips. P0 re-runs the focused v4 slice before any eval code is treated as green.

## 2. Invalidated v1 assumptions

| v1 assumption | Status | Replacement |
|---|---|---|
| P0 requires AWS Batch (`create_model_invocation_job`) | INVALIDATED | P0 is synchronous Converse on a small local corpus. No Batch. |
| Create a new `Rag::QueryAnalysis` Data for the semantic contract | INVALIDATED | Existing `Rag::QueryAnalysis` stays the evidence-identifier object. Semantic perception is `Rag::ConversationalTurnAnalysis`. See section 3. |
| Semantic schema owns `intent`, `query_kind`, equipment facts, and referent type | SUPERSEDED | Minimal perception contract in section 4. Closed grammars and the catalog own the rest. |
| Input 600 / output 120 tokens is the cost model | INVALIDATED as fact | Assumption to measure: 1500–2500 input, 100–200 output. P0 records actual usage. |
| Conditional gate is `identity_complement?` / `common_noun?` / `technical_nps` | INVALIDATED | Structural gate only. Section 6. A Ruby semantic classifier must not decide whether to call Haiku. |
| After migration, analyzer failure falls through to v4 semantic heuristics | INVALIDATED after ownership transfer | Shadow may fall back to v4. After semantic ownership moves, fallback is validated facts + raw turn, or a clarification. Section 7. |
| `generation.txt` shrinkage is P5 | SUPERSEDED | Heuristic retirement is P5. Latency work is P6. Prompt shrinkage is out of this plan unless a later measurement reopens it. |
| Haiku may persist `equipment.model` when the string is in the turn and the extractor agrees | NARROWED | The model proposes a span and a role. Catalog/resolver validation is required before any identity mutation. Section 5. |

v1 sections 4–7, 10 (batch workflow), 11 (regex gate), and 22 (P0 batch script; P1 editing `query_analysis.rb`) are historical. They do not authorize the implementer.

## 3. QUERY_ANALYSIS_CONVERGENCE

```text
DECISION: B
OBJECT: Rag::ConversationalTurnAnalysis
EXISTING: Rag::QueryAnalysis remains, built only by Rag::QueryEntities.analyze
MERGE: never
```

Evidence, inspected on this HEAD:

- `app/services/rag/query_analysis.rb` is `Data.define(:intents, :manufacturer, :model, :board, :identifiers, :requested_relation, :confidence, :question)`. Comment: one constructor, `Rag::QueryEntities.analyze`. `Hypothesis` is explicitly not a fact.
- `QueryEntities.analyze` fills only `identifiers`, `requested_relation`, and `question`. Manufacturer, model, board, intents, and confidence stay nil/empty.
- Consumers of that object include evidence selection, family ambiguity, `StructuredEvidenceRoute`, resolution presentation, and `RagController`. They use identifiers and requested relations for evidence, not discourse.
- `QueryEntities` already drops bare numerics so `24 V` is not an identifier. That closed grammar stays.

Why not A: evolving `QueryAnalysis` would change the evidence-selector contract to carry discourse fields, and would give the semantic model a path onto `manufacturer` / `model` inside the object whose own comment says equipment identity is a hypothesis. P0 must not touch that file.

Why not a third unnamed object: `ConversationalTurnAnalysis` is the single semantic-perception result. `QueryAnalysis` is not a second semantic engine. Routing, rewriting, and intent classification must not add another model call. A future route hint is a deterministic projection of this perception plus closed parsers, not a new classifier.

Convergence path, closed now:

1. P0 defines and evaluates the perception schema only in the offline harness. It does not add the class under `app/`.
2. P1 introduces `app/services/rag/conversational_turn_analysis.rb` as an immutable `Data`. The only production producer is the shadow analyzer after Ruby span/slot validation. `QueryEntities.analyze` remains the only producer of `QueryAnalysis`.
3. Consumers that need discourse receive `ConversationalTurnAnalysis`. Consumers that need identifiers keep calling `QueryEntities`. A caller may receive both. It must not copy semantic spans into `QueryAnalysis` manufacturer/model fields.
4. No adapter merges the two types. "One semantic perception" means one perception object per turn, reused by state, effective-query construction, and any later route projection.

## 4. Semantic contract (minimal)

Ruby keeps anything a closed grammar or the catalog can decide. The model returns only fields that change a discourse decision and that Ruby cannot compute robustly.

```json
{
  "relation": "continue|answer_pending|correct|switch|new|unclear",
  "mentions": [
    { "span": "MonoSpace", "role": "equipment|component|other" }
  ],
  "refers_to": [
    { "span": "el otro", "slot": "obs_2" }
  ],
  "ambiguous": false
}
```

`relation` is the open-world discourse label. These definitions are normative:

```text
continue
= mismo equipo y misma tarea/problema; continúa el estado existente.

answer_pending
= el turno responde directamente a state.pending_question.

correct
= corrige un fact o identidad expresada previamente.
  El fact corregido no se hereda.

switch
= cambia a otro equipo, pero puede conservar el marco/tarea técnica.

new
= nueva tarea/problema.
  No se hereda contexto semántico previo.

unclear
= no existe evidencia suficiente para decidir de forma segura.
  Se comporta fail-closed igual que ambiguous=true.
```

`ambiguous=true` implies fail-closed. `relation=unclear` also implies fail-closed. Ellipsis is represented by `relation`. `refers_to` is used only when a literal anaphoric span points at an addressable slot.

`mentions` are literal spans plus a proposed role, not a persisted identity. `refers_to.slot` must be an id derived from that case's `state`. The analyzer may return only a `refers_to.slot` that exists there.

Out of the semantic schema, permanently for this plan:

- final effective query;
- route hint;
- measurement value, unit, or correctness;
- safety judgment;
- procedure selection;
- technical answer text;
- invented manufacturer, model, or component strings.

Closed contracts that stay deterministic, including when a perception call also runs:

```text
pending type fault_code + "ninguno" → absent
pending type choice(opening, closing) + "al abrir" → opening
"24 V en X7" → value=24, unit=V, location=X7
"modelo es MonoSpace" → candidate token for catalog validation, not a persisted model by itself
```

The model may say which observation or pending question a measurement belongs to, via `refers_to`. It does not decide the value or whether the value is expected.

Span safety contract:

Normalization for comparison:

```text
1. Unicode NFC
2. Unicode lowercase/downcase
3. collapse internal whitespace to one space
4. trim whitespace
5. trim punctuation only at the edges of the candidate span
6. DO NOT fold accents
```

Every `span` must be a literal substring of the turn after that normalization. `"relé" != "rele"` when the model invents the accent. No invented strings. No paraphrases. No canonicalization that leaves the input.

`refers_to.slot` must be one of the slots derived from `state` for that case. There is no second manual slot list.

P0 rejects the whole object using the error map in the P0 section. An invalid output never inherits state. Catalog identity checks are not a P0 rejection path. Later phases still reject a catalog miss before any identity mutation, and they still reject a conflict with an explicit correction.

Addressable slots are derived only from `state`, and only when that field is present:

```text
pending_question    iff state.pending_question is non-null
active_referent     iff state.active_referent is non-null
obs_1, obs_2, ...   iff that observation id is in state.observations
```

Not in this plan unless a later phase finds a current consumer: full procedure state, `active_step`, measurement history, hypothesis graph. `current_procedure` has no active runtime consumer and stays unused.

## 5. Identity

```text
semantic model proposes span + role
→ Ruby checks the span is in the turn
→ KbDocumentResolver / display_name / aliases / existing model extractor validate identity
→ only then may a later phase mutate state
```

Never: the model says Nova is a model, so persist model.

`KbDocumentResolver` (`app/services/kb_document_resolver.rb`) matches query tokens to `KbDocument.display_name` and `aliases` for the account, whole-word, min length 3, brand-only tokens excluded. Reuse it as the catalog check for equipment-role mentions. A span that does not match the tenant catalog is not an equipment identity. It may remain a component-role candidate with no identity write.

P0 does not call `KbDocumentResolver`. In P0 the mention `role` is scored against the human label. Catalog validation enters later, in runtime.

`ActiveEpisodeTurn` `MODEL_VALUE_RE` remains the closed parser for an explicit "modelo es X" frame. The semantic model does not replace that frame.

## 6. Structural gate

No Ruby classifier that tries to decide "component vs equipment" in order to call Haiku.

```text
active_episode present?
OR pending_question / pending_fact present?
OR active_photo present?
OR hands_free mode?
→ semantic analysis candidate
```

Hands-free is expected to be near-always-on. That is a cost/latency measurement, not a reason to add a semantic pre-classifier.

```text
ASSUMPTION: invocation fraction ≈ 15% on typed RAG with the structural gate
MEASUREMENT: TBD from P1 shadow
DECISION: TBD
```

A first turn with no inherited episode is not a P0 runtime change. P0 includes exactly 4 controls tagged `no_inherited_state`, each with `state.equipment` null and `state.goal` null. A future phase may run raw `Retrieve` in parallel with perception only when retrieval meaning is unchanged. Never speculative `RetrieveAndGenerate`. If perception would change equipment, correction, deixis, or scope, discard the raw retrieve. Phase: not before P6, and only after P0 shows the case family is real. See P7 for hands-free; the parallel-retrieve decision stays in P6 exit criteria as a possible later experiment, default off.

## 7. Fallback

During shadow (P1):

```text
analyzer fails → v4 answer and v4 state, analysis=nil
```

After a phase has transferred semantic ownership for a slice (P3+):

```text
analyzer fails → explicit validated facts + current raw turn
if the turn is not self-contained → ask clarification
```

No unsafe inheritance. v4 is not the hidden semantic engine after that transfer.

## 8. Pending-question routes

Common contract, machine-readable, produced beside answer text. Not a new inference by itself.

```json
{ "pending_question": { "type": "fault_code" } }
```

```json
{ "pending_question": { "type": "choice", "options": ["opening", "closing"] } }
```

Allowed `type` values for this plan: `fault_code`, `manufacturer`, `model`, `choice`, `absent`. Anything else is no pending question.

Today `ActiveEpisodeTurn.write_pending!` scans `[^?]+\?` in the assistant prose and maps a single question to `manufacturer`, `model`, or `fault_code` via `BRAND_WORD_RE` / `MODEL_WORD_RE` / `CODE_WORD_RE`. `ConversationSession#record_assistant_turn!` persists that `pending_fact` from the full reply. There is no `choice` type and no structured side channel. `pending_fact.subject` is the current stand-in for `pending_question`.

SDK fact used below: `aws-sdk-bedrockruntime` 1.63.0 (`Gemfile.lock`). `BedrockClient#generate_text` calls `invoke_model` with Anthropic messages JSON and returns `content[0].text`. It does not send `output_config`. Repo grep shows `output_config` only inside this plan, not in the gem usage. v1 already recorded that the gem models `converse` and `tool_config` and does not model `output_config`. This revision did not bump the gem and did not re-fetch AWS docs beyond that recorded finding plus the current call sites. Do not claim `RetrieveAndGenerate` has a side-channel JSON field; the code reads `response` text and `response.citations` only (`BedrockRagService#query`).

| ROUTE | HOW ANSWER IS GENERATED | CAN IT EMIT STRUCTURED PENDING METADATA? | IF YES: HOW / IF NO: WHY | FALLBACK OPTION | PHASE |
|---|---|---|---|---|---|
| RetrieveAndGenerate | `BedrockRagService#query` → `retrieve_and_generate_with_retry`. Answer is output text. Citations come from `response.citations` and `CitationProcessor`. The prompt template owns `$output_format_instructions$`. | NO on this call | The API response used in code is prose plus citations. A JSON object inside the answer breaks citation span alignment. `outputConfig` is a Converse/InvokeModel feature, not a field of this RetrieveAndGenerate call. SDK 1.63.0 is not the blocker here; the API shape is. | Keep `write_pending!` until P2. P2 may extend that same prose scan with a closed grammar for `choice` when the question text matches a known option list. No second model call. No JSON fence inside the cited answer. | P2 |
| explicit Retrieve + generation (`DocumentIdentityScope`) | `document_identity_scope_result` retrieves, then `AiProvider` → `generate_text` (`invoke_model`) with `generation.txt` and citation instructions substituted. On generator failure, falls back to RetrieveAndGenerate. | NO without changing the citation prose contract | Current generator returns one text blob. Structured output would require `output_config` (SDK bump) or `tool_config` on this call and would replace the citation instructions. That is a generation-contract change, not a free side channel. | Same prose `write_pending!`. Do not append a machine block until citation tests prove the parser ignores it. That proof is not assumed. | P2 investigation only; implement only if a Ruby-side question is already known without reading the model |
| StructuredEvidenceRoute | Deterministic route match, explicit Retrieve, then `AiProvider` generation over selected evidence (`execute`). | PARTIAL, without a new call, only for questions the route already knows in Ruby | The model call is free text. The route, not the model, knows when it is asking the technician for a closed fact. Emit `pending_question` from the route object in Ruby. Do not ask the generator to invent it. | Ruby field on the route result, default nil. Prose scan remains for model-authored questions this route does not already classify. | P2 |
| ContextEvidenceRoute | `execute` → `ClosedFactGenerator` via `AiProvider` over retrieved context evidence. | PARTIAL, same as structured | Closed facts are deterministic. A follow-up the route already encodes can be a Ruby `pending_question`. The generator stays prose. | Ruby field, nil when the route does not ask a typed question. | P2 |
| deterministic response route | Orchestrator / episode paths that return text without a generation model. | YES | The same Ruby object that builds the sentence sets `pending_question`. Zero model calls. | n/a | P2, first slice: manufacturer, model, fault_code, and explicit choice prompts the route already asks |

P0 does not implement this contract. It freezes the JSON shape and uses it as fixture input when a case's label says a pending question is already known.

## 9. Inference inventory

| Inference | Current owner | Future owner | Status |
|---|---|---|---|
| semantic perception | `TechnicalReferentResolver` heuristics, `ActiveEpisodeTurn` first-match, `FollowupQueryRewriter` on the no-episode path | one `ConversationalTurnAnalysis` per gated turn | FUTURE (P0 measures, P1 shadows, P3 owns one slice) |
| RAG generation | `BedrockRagService#query` RetrieveAndGenerate | same | KEEP |
| query router KB/SQL/hybrid | `QueryOrchestratorService#classify_query_intent`, default off | deterministic projection of perception + closed parsers, if routing is ever enabled | DO_NOT_ENABLE as a second model |
| hybrid synthesis | `synthesize_hybrid_answer`, only if router returns hybrid | KEEP only when both sources are required; not a semantic analyzer | KEEP |
| reranker | Cohere path, flag off | unchanged until a recall study | DO_NOT_ENABLE in this plan |
| vision analysis | `FieldPhotoAnalysisService`, async | same; reconcile through episode provenance | KEEP |
| document identity generation | Retrieve + `generate_text`, fallback RetrieveAndGenerate | same | KEEP |
| structured/context generation | route-local `AiProvider` over retrieved evidence | same generation; pending question from Ruby when the route already knows it | KEEP |
| identifier / requested-relation extraction | `QueryEntities` → `QueryAnalysis` | same | KEEP |
| assistant pending subject | `write_pending!` prose scan | `pending_question` contract per section 8 | MERGE into the contract in P2; REMOVE_LATER the prose-only path when every route that asks a typed question emits the contract |

Steady state is one semantic perception result reused by consumers. It is not a semantic analyzer plus an intent classifier plus a routing classifier plus a query-rewriter LLM.

## 10. Target flow (provisional)

```text
USER TURN
   ↓
closed deterministic parsers
   ↓
semantic perception when structurally required
   ↓
Ruby validation / catalog resolution
   ↓
ActiveEpisode mutation
   ↓
deterministic effective query construction
   ↓
Retrieve / RAG generation
   ↓
assistant answer + pending_question contract
```

P0 stops before mutation, effective query, and generation changes. It runs perception offline against fixtures.

## 11. Cost and latency assumptions

`BedrockQuery::BEDROCK_PRICING` for `global.anthropic.claude-haiku-4-5-20251001-v1:0` is USD 0.001 input and USD 0.005 output per 1,000 tokens, which is USD 1 / MTok input and USD 5 / MTok output. The P0 harness carries those two numbers as its own constants and does not load `BedrockQuery`. A Rails test asserts `pricing[:input] * 1000 == 1` and `pricing[:output] * 1000 == 5` for that model id. The script must not read `ENV` or credentials to pick a price.

```text
ASSUMPTION:
input 1500–2500 tokens
output 100–200 tokens
MEASUREMENT: TBD from P0 usage
DECISION: TBD
```

Illustrative only, using the high end (2500 in, 200 out) = USD 0.0035 per analysis. Not a gate.

| queries/day/user | conditional, f unknown | hands-free near-always-on |
|---|---|---|
| 20 | 20 * f * measured_unit * 30 | 20 * measured_unit * 30 |
| 50 | 50 * f * measured_unit * 30 | 50 * measured_unit * 30 |
| 100 | 100 * f * measured_unit * 30 | 100 * measured_unit * 30 |

P0 fills `measured_unit` and does not invent `f`. Cost is not the primary gate. Latency is recorded even though P0 is offline: `semantic_analysis_ms` per case. Later phases add `state_ms`, `retrieve_ms`, `generation_ms`/`rag_ms`, `total_ms`, and report p50/p95/p99 per route. Do not add percentiles across phases.

## 12. Safety invariants

The semantic analyzer must not:

```text
write DB
invent manufacturer/model
invent component names
decide technical correctness
decide procedure
bypass catalog
bypass provenance
overwrite explicit correction
preserve stale equipment against explicit switch
generate technical answer
```

Ruby is authority.

Operable P0 metrics, and no other primary list:

```text
unsafe_contamination
projection_accuracy_haiku_open_world
projection_accuracy_v4_open_world
relation_accuracy
slot_accuracy
ambiguous_surfaced
closed_relation_agreement
invalid_schema
hallucinated_spans
transport_error
input_tokens
output_tokens
cost_usd
semantic_analysis_ms
```

Mention match, no partial credit:

```text
normalized output span ∈
{ expected.span } ∪ expected.acceptable_spans

AND role matches exactly
```

`unsafe_contamination` uses only the formula in the P0 section. The harness recommendation requires `unsafe_contamination == 0`. That recommendation does not authorize P1. When P0 ends, `Decision` stays `PENDING_HUMAN`.

## 13. Phases

The next action is the plan-only commit. P0 Commit A starts only after `BASELINE_COMMIT` is that hash. Later phases stay specified so their boundaries stay closed, and their execution prompts say they are not authorized until a human records that decision in this file.

---

## P0 — contract + offline evaluation

### Hypothesis

A minimal Haiku perception schema, validated by literal spans and existing slot ids, separates open-world relation/coreference from closed-contract turns well enough that unsafe contamination on the labeled corpus is zero, and open-world cases beat v4 heuristics without a runtime change.

### Why this phase exists

Reviews accepted HYBRID_MINIMAL but not a production call. P0 buys evidence before any request path, state write, or query change.

### Preconditions

- Branch `experiment/haiku-semantic-query-analysis`.
- The plan-only commit exists and `BASELINE_COMMIT` in this file has been replaced with that hash. P0 does not start while it is `PENDING_PLAN_V2_COMMIT`.
- Foreign worktree files in section 1 untouched.
- AWS credentials available to the eval script's process for the single Converse run. The Rails request path is not invoked.
- No Gemfile change. SDK stays `aws-sdk-bedrockruntime` 1.63.0.

### Exact scope

Offline harness only:

- JSONL corpus. Families stay `CLOSED_CONTRACT` and `OPEN_WORLD`.
- The harness calls Haiku for every case, including `CLOSED_CONTRACT`.
- One synchronous Converse call per case, temperature 0, zero retries.
- Structured output via `tool_config` with `tool_choice` forced to a single tool, because 1.63.0 models `tool_config` and does not model `output_config`. Do not bump the SDK in P0. Do not parse free prose as the primary path.
- Ruby validation of spans and derived slots before scoring.
- `v4_expectation` is handwritten on each fixture. A Minitest recomputes it with `Rag::ActiveEpisodeTurn.call` and fails on a discrepancy. The network script does not call `ConversationSession#record_user_turn!`.
- Report the operable metrics in section 12.

`script/AGENTS.md` asks for about 40 lines under `script/`. This offline eval harness may exceed that because it is a self-contained experimental artifact, following `script/rag_quality_benchmark.rb`. Do not move P0 logic into `app/`. Do not edit `script/AGENTS.md`. Guard the script with `HAIKU_SEMANTIC_P0_LIBRARY_ONLY=1` so tests can require it without a network call. The network path runs only when that variable is unset.

### Files to CREATE

- `script/fixtures/haiku_semantic_perception_p0.jsonl`
- `script/haiku_semantic_perception_p0.rb`
- `test/scripts/haiku_semantic_perception_p0_test.rb`

### Files to MODIFY

- `docs/PLAN_HAIKU_SEMANTIC_QUERY_ANALYSIS_2026-09-24.md` (Commit B only, after the run)

### Files READ_ONLY

- `app/services/rag/query_analysis.rb`
- `app/services/rag/query_entities.rb`
- `app/services/rag/active_episode.rb`
- `app/services/rag/active_episode_turn.rb`
- `app/services/rag/technical_referent_resolver.rb`
- `app/services/rag/followup_query_rewriter.rb`
- `app/services/kb_document_resolver.rb`
- `app/services/bedrock_client.rb`
- `app/models/conversation_session.rb`
- `app/models/bedrock_query.rb` (Rails test reads `BEDROCK_PRICING` only)
- `Gemfile.lock`

### Files OUT_OF_SCOPE

Everything under `app/`, `config/`, `db/`, prompts, and the foreign worktree list in section 1. No `Gemfile` / `Gemfile.lock`. No `bulk_chunks/`. No S3 batch job. No edit to `script/AGENTS.md`.

### Fixture

Each JSONL line has `state`, `expected`, `safety`, and `v4_expectation`. The illustrative object below shows the shape. It is not the gold label for that utterance when the rules assign a different label.

```json
{
  "id": "open-001",
  "family": "OPEN_WORLD",
  "tags": ["safety_critical"],
  "turn": "¿y en el Nova?",
  "state": {
    "equipment": { "manufacturer": null, "model": "MonoSpace" },
    "goal": "cómo se ajustan los resortes de la fijación de cables",
    "active_referent": null,
    "pending_question": null,
    "observations": [
      { "id": "obs_1", "summary": "el operador hace ruido al abrir" }
    ]
  },
  "expected": {
    "relation": "switch",
    "mentions": [
      { "span": "Nova", "role": "equipment", "acceptable_spans": ["el Nova"] }
    ],
    "refers_to": [],
    "ambiguous": false,
    "closed_parse": null
  },
  "safety": {
    "equipment_inheritance": "forbidden",
    "forbidden_slots": []
  },
  "v4_expectation": {
    "inherits_equipment": true,
    "slots": []
  }
}
```

`equipment_inheritance` is `allowed`, `forbidden`, or `n/a`. Do not use a free-text `unsafe_if` field.

There is no manual `slots` array in the JSONL. Authorized slots are derived only from `state`:

```text
pending_question   iff state.pending_question is non-null
active_referent    iff state.active_referent is non-null
<observation id>   iff that id is in state.observations
```

The analyzer may return a `refers_to.slot` only when that id is in this derived list.

The user message sent to the model is exactly:

```json
{ "turn": "...", "state": {}, "slots": [] }
```

`slots` in that message is the derived projection. It is not stored as a second list in the JSONL.

### Corpus composition

```text
CLOSED:
5 seeds × 2 states = 10

OPEN phrases:
8 seeds × 2 minimal contrasting states = 16

LEXICAL PROBES:
11 terms × 2 contexts = 22

VARIATION AXES:
6 axes × 3 representative cases = 18
(no Cartesian product)

NO_INHERITED_STATE:
4 controls
```

Target 60–90 cases. Hard cap 90. At least 25 cases are safety-critical: `safety.equipment_inheritance` is `forbidden` or `safety.forbidden_slots` is non-empty. Do not cross every term with every dialect, typo, or language.

Closed seeds, family `CLOSED_CONTRACT`: `modelo es MonoSpace`; `código 8`; `ninguno` with `pending_question.type=fault_code`; `al abrir` with `choice` options `opening`/`closing`; `24 V en X7`. Each seed has 2 states.

Open phrase seeds, family `OPEN_WORLD`: `el otro`, `ese de arriba`, `el de la izquierda`, `no, esa foto es del otro ascensor`, `ya lo cambié y sigue`, `¿y en el Nova?`, `mira este`, `es el anterior`. Each seed has 2 minimal contrasting states.

Lexical probes, family `OPEN_WORLD`: `freno`, `relé`, `polea`, `eje`, `tubo`, `regulador`, `MaxPro`, `Nova`, `Delta`, `Mono`, `MiniSpace`. Each term has 2 contexts.

Variation axes, applied only to representative cases: `typo`, `ASR-like`, `Chilean Spanish`, `Venezuelan Spanish`, `technical English`, `mixed-language`. Six axes, three cases each.

Tag `no_inherited_state` on exactly 4 controls where `state.equipment` is null and `state.goal` is null.

Human labels (`expected`, `safety`, `v4_expectation`) are written before any network call.

### CLOSED_CONTRACT

`needs_model=false` means the deterministic parser is sufficient for that case. It does not mean the harness skips the call. For P0 the harness calls Haiku on every case, so the future structural gate is measured.

On `CLOSED_CONTRACT`:

- `closed_parse` is produced only by the deterministic parser.
- Haiku receives no capability credit for these cases.
- Haiku output is scored only for `unsafe_contamination`, `closed_relation_agreement`, schema/errors, and latency/cost.

The harness parser copies these from current code, or calls them:

```text
Rag::ActiveEpisodeTurn::MODEL_VALUE_RE
Rag::ActiveEpisodeTurn::KNOWN_CODE_RE
Rag::ActiveEpisodeTurn::ABSENT_CODE_RE
Rag::FollowupQueryRewriter.normalize_label
```

`MODEL_VALUE_RE` runs on the raw turn, as v4 does. `KNOWN_CODE_RE` and `ABSENT_CODE_RE` run on `normalize_label`, as v4 does. `normalize_label` folds accents. Span comparison does not. Do not unify the two normalizations.

A Rails test fails if those four copies diverge from v4. Limit the seed-only parsers (`ninguno` plus pending `fault_code`, `al abrir` plus choice, `24 V en X7`) to the P0 seeds. Do not build a new general parser. `ABSENT_CODE_RE` does not match bare `ninguno`; that seed stays a pending-question parse, not a change to the v4 regex.

### Normalization

Span comparison uses only the rule in section 4:

```text
Normalization for comparison:
1. Unicode NFC
2. Unicode lowercase/downcase
3. collapse internal whitespace to one space
4. trim whitespace
5. trim punctuation only at the edges of the candidate span
6. DO NOT fold accents
```

The span must remain a literal substring of the normalized turn. `"relé" != "rele"` when the model invents the accent.

### Error map

```text
span no literal
→ hallucinated_spans

unknown slot
→ invalid_schema

unknown enum
→ invalid_schema

missing required key
→ invalid_schema

no semantic_perception tool_use block
→ invalid_schema

timeout
→ transport_error

5xx
→ transport_error

throttle
→ transport_error

network failure
→ transport_error
```

An invalid output never inherits state.

Parse the first content block whose `tool_use.name` is `semantic_perception`. `tool_use.input` must be a Hash. Also record `stop_reason`, AWS `metrics.latency_ms`, and local monotonic elapsed time. `semantic_analysis_ms` is the local monotonic elapsed time.

### Projection and contamination

```text
projection(output):

invalid output / transport error
→ inherits_equipment = false
→ slots = []

ambiguous=true
→ inherits_equipment = false
→ slots = []

relation=unclear
→ inherits_equipment = false
→ slots = []

relation ∈ {continue, answer_pending}
→ inherits_equipment = true

relation ∈ {correct, switch, new}
→ inherits_equipment = false

slots
→ validated refers_to slots
```

```text
unsafe_contamination =
(
  safety.equipment_inheritance == forbidden
  AND projection.inherits_equipment == true
)
OR
(
  projection.slots intersects safety.forbidden_slots
)
```

No other interpretation. `ambiguous=true` is fail-closed. `unclear` is fail-closed.

### Metrics

Use the section 12 list. Definitions:

```text
gold = projection of expected
      (expected rows are valid; they are not transport errors)

projection_accuracy_haiku_open_world
= OPEN_WORLD cases whose projection(model output)
  equals gold {inherits_equipment, slots}
  / OPEN_WORLD case count

projection_accuracy_v4_open_world
= OPEN_WORLD cases whose v4_expectation
  {inherits_equipment, slots} equals that same gold
  / OPEN_WORLD case count

relation_accuracy
= OPEN_WORLD cases with exact relation match
  / OPEN_WORLD case count
  invalid or transport = miss

slot_accuracy
= OPEN_WORLD cases whose validated refers_to slot set
  equals the expected refers_to slot set
  / OPEN_WORLD case count
  invalid or transport = miss

ambiguous_surfaced
= cases with expected.ambiguous=true and output.ambiguous=true
  / cases with expected.ambiguous=true
  invalid output does not count as surfaced

closed_relation_agreement
= CLOSED_CONTRACT cases whose output.relation
  equals expected.relation
  / CLOSED_CONTRACT case count
  this is agreement, not capability credit

invalid_schema, hallucinated_spans, transport_error
= counts, plus transport_error as a fraction of cases

input_tokens, output_tokens, cost_usd, semantic_analysis_ms
= per case, from the Converse response and the local clock
```

Mention match, no partial credit:

```text
normalized output span ∈
{ expected.span } ∪ expected.acceptable_spans
AND role matches exactly
```

### v4 baseline

`ActiveEpisodeTurn.call` is pure. The class comment states that nothing there is persisted. P0 may call it. P0 must not call `ConversationSession#record_user_turn!`.

```ruby
Rag::ActiveEpisodeTurn.call(
  state: episode_hash,
  text: turn,
  enabled: true,
  shared: false,
  now: FIXED_TIME
)
```

`FIXED_TIME` is `Time.utc(2026, 9, 25, 15, 0, 0)`. The test adapter builds a v1 episode hash with `episode_id` `ep_p0`, `updated_at` and `opened_at` at `FIXED_TIME`, `facts.manufacturer` / `facts.model` from non-null `state.equipment` values (`status` `known`), `goal.text` from `state.goal` when present, and `pending_fact.subject` only when `state.pending_question.type` is `manufacturer`, `model`, or `fault_code`. Observations and `active_referent` are not written. v4 does not address observation slots.

Recomputed expectation:

```text
slots = []
inherits_equipment = true iff at least one of manufacturer or model
  was non-null on the input and every such non-null value is still
  that same known value on result.state
```

The Minitest fails if the handwritten `v4_expectation` disagrees on `inherits_equipment` or `slots`. The network script scores Haiku against the handwritten label. The test is what keeps that label equal to real v4, so the comparison does not favor Haiku by a hand-tuned baseline.

### Prompt

The prompt is a constant inside the harness. Freeze it before any network call. It must contain, literally:

- the `relation` definitions from section 4;
- the span normalization rule;
- the rule that the model must not invent strings;
- the ambiguity fail-closed rule, including `unclear`;
- the output schema.

Do not put few-shot examples taken from the corpus in the prompt.

### Catalog

P0 does not call `KbDocumentResolver`. Score `role` against the human label. Catalog validation is later runtime.

### Model and client

P0 uses this model id literally:

```text
global.anthropic.claude-haiku-4-5-20251001-v1:0
```

No `ENV` fallback. No credentials fallback. Do not change the model during the run.

Create the client with:

```ruby
retry_limit: 0,
max_attempts: 1,
http_open_timeout: 2,
http_read_timeout: 8
```

Zero retries must be real. Temperature 0. `maxTokens` 300. Tool name `semantic_perception`. `tool_choice` forced to that tool.

Harness price constants:

```text
input_usd_per_mtoken = 1
output_usd_per_mtoken = 5
cost_usd = (input_tokens / 1_000_000.0) * 1 + (output_tokens / 1_000_000.0) * 5
```

The plain Ruby script must not load `BedrockQuery`. The Rails test asserts equality against `BedrockQuery::BEDROCK_PRICING` for that model id: `pricing[:input] * 1000 == 1` and `pricing[:output] * 1000 == 5`.

### Recommendation rule

Pre-registered rule:

```text
PROCEED_RECOMMENDED
iff
unsafe_contamination == 0
AND
projection_accuracy_haiku_open_world >
projection_accuracy_v4_open_world
AND
transport_error <= 5%
```

Otherwise `STOP_RECOMMENDED`. This is a harness recommendation. It does not authorize P1. When P0 ends:

```text
Decision = PENDING_HUMAN
Recommendation = PROCEED_RECOMMENDED | STOP_RECOMMENDED
```

A human authorizes the next phase.

### Commits

P0 is not one commit.

Plan v2 commit, before P0, this file only. After that commit, replace `BASELINE_COMMIT` with its hash before P0 starts. Do not commit that replacement by itself.

Commit A, only these paths:

```text
script/fixtures/haiku_semantic_perception_p0.jsonl
script/haiku_semantic_perception_p0.rb
test/scripts/haiku_semantic_perception_p0_test.rb
```

Then STOP. Before any network call, a human reviews `expected`, `safety`, `v4_expectation`, and the prompt. Record in this file:

```text
P0_CORPUS_SHA256:
8b793b497c22b7ea6751ff9ba056e20886a9241d0c80fcf11944f37bf768140c

P0_PROMPT_SHA256:
516c09cc841b25e4cd24edeb95cee98891ede6b24a4e9a01d33c821ea39882a0

P0_LABEL_REVIEW:
APPROVED_BY_HUMAN
```

Fill the two hashes from the committed corpus bytes and the frozen prompt constant, and set `P0_LABEL_REVIEW` to `APPROVED_BY_HUMAN`, only after that review. Only then run the network pass. One network run.

After the first network call, do not modify the corpus, the prompt, `expected`, or safety labels. If a label is wrong, write it under Unexpected findings and stop or reclassify the experiment. Do not correct it silently.

Commit B, after the run, modifies only this document, with:

```text
Results
Metrics
Unexpected findings
Recommendation
PHASE_COMMIT = Commit A
PHASE_TEST_RESULT
PHASE_METRICS
Decision = PENDING_HUMAN
```

Do not try to make a commit contain its own hash. `PHASE_COMMIT` is Commit A's hash, written by Commit B.

### Git safety

Never use:

```text
git add -A
git add .
git commit -a
git checkout
git restore
git stash
git clean
```

Stage only exact paths. Before each commit, `git diff --cached --name-only` must match the authorized paths exactly. If it does not, STOP.

### Exact implementation steps

1. Confirm the plan-only commit is done and `BASELINE_COMMIT` is that hash.
2. Confirm `git status --short` is the section 1 foreign files, the uncommitted `BASELINE_COMMIT` line in this document, and the new harness files only.
3. Write the JSONL with the fixture shape, corpus composition, and derived slots above.
4. Put the frozen prompt constant and the Converse client in the harness.
5. Implement validation, the error map, projection, and the metrics.
6. Copy the four closed-parser constants. Keep seed-only parsers on the five closed seeds.
7. Add the Minitest that recomputes `v4_expectation`.
8. Commit A. STOP for human label and prompt review. Record the SHA256 fields and `P0_LABEL_REVIEW`.
9. Run the single network command. Write `tmp/haiku_semantic_perception_p0_report.json` (gitignored tmp). Do not write under `bulk_chunks/`.
10. Commit B updates this document from that report. Do not start P1.

### Contract after this phase

The JSON schema in section 4 is the perception contract. `ConversationalTurnAnalysis` still does not exist under `app/`. No session row changes. No query text changes.

### Tests to add/change

`test/scripts/haiku_semantic_perception_p0_test.rb`, no network (`HAIKU_SEMANTIC_P0_LIBRARY_ONLY=1`):

- JSONL line has `state`, `expected`, `safety`, `v4_expectation`, and no manual `slots` key.
- Derived slots match `state` and reject an unknown slot as `invalid_schema`.
- A non-literal span is `hallucinated_spans`. `"relé"` does not match `"rele"`.
- Unknown enum and missing required key are `invalid_schema`.
- Missing `semantic_perception` tool_use block is `invalid_schema`.
- Invalid output projects to `inherits_equipment=false` and `slots=[]`.
- `unsafe_contamination` matches only the formula in this section.
- Closed parser: `modelo es MonoSpace` via `MODEL_VALUE_RE`; `código 8` via `KNOWN_CODE_RE`; `ninguno` plus `fault_code` → absent; `al abrir` plus choice → opening; `24 V en X7` → 24 / V / X7.
- Copied `MODEL_VALUE_RE`, `KNOWN_CODE_RE`, `ABSENT_CODE_RE`, and `normalize_label` match v4.
- Handwritten `v4_expectation` matches `ActiveEpisodeTurn.call` on `inherits_equipment` and `slots=[]`.
- Prompt constant contains the relation definitions, span rule, no-invented-strings rule, fail-closed rule, and schema, and contains no corpus few-shot.
- Model id constant is the literal global Haiku id.
- Client options are `retry_limit: 0`, `max_attempts: 1`, `http_open_timeout: 2`, `http_read_timeout: 8`.
- Price constants equal `BEDROCK_PRICING` after the ×1000 unit conversion. The script source does not reference `BedrockQuery`.
- Script does not reference `bulk_chunks` or `KbDocumentResolver`.
- `tool_config` payload forces a single tool.

Existing v4 tests are not modified. Run them as a regression check.

### Commands to run

```bash
git status --short
env -u BUNDLE_PATH bin/rails test test/scripts/haiku_semantic_perception_p0_test.rb
env -u BUNDLE_PATH bin/rails test \
  test/services/rag/active_episode_turn_test.rb \
  test/models/conversation_session_test.rb \
  test/controllers/concerns/rag_query_concern_test.rb
```

Network run, only after Commit A, human review, and the SHA256 / `P0_LABEL_REVIEW` record:

```bash
env -u BUNDLE_PATH bundle exec ruby script/haiku_semantic_perception_p0.rb
```

That command is the only network step. If credentials are missing, stop and record that. Do not stub a fake success into Results.

### Telemetry

Per case: `semantic_analysis_ms` (local monotonic), AWS `metrics.latency_ms`, `stop_reason`, `input_tokens`, `output_tokens`, `cost_usd` from the harness constants, plus the error classes. Aggregate p50/p95 of `semantic_analysis_ms` on this sample only. No `retrieve_ms`. No DB log row.

### Expected artifacts

- Commit A: corpus, harness, tests.
- Local report under `tmp/`, not committed if `tmp/` is ignored.
- Commit B: metric summary, recommendation, and `Decision=PENDING_HUMAN` in this document.

### Exit criteria

- Harness tests green before the network run.
- Focused v4 slice green before the network run.
- One network run after the label freeze.
- Results, metrics, unexpected findings, and recommendation written into this document.
- `Decision` remains `PENDING_HUMAN`.

### Rollback

Delete the three Commit A files and revert the Commit B edit to this document. No runtime rollback exists because runtime did not change.

### Stop conditions

On the first call, STOP if any of these occur:

```text
ValidationException
AccessDenied
missing credentials
tool_config/tool_choice rejection
model/profile unavailable
```

No pivot. No model change. No SDK change. No Batch.

During the run, `transport_error > 5%` means STOP and report an infrastructure failure, not a quality result.

Also stop when:

- `unsafe_contamination > 0` (recommendation becomes `STOP_RECOMMENDED`; decision stays `PENDING_HUMAN`).
- Any write to `app/`, prompts, Gemfile, `script/AGENTS.md`, or the foreign worktree files.
- A case requires an architectural choice not written in this document.
- A label looks wrong after the first network call. Record it under Unexpected findings. Do not edit the label.

### Risks

Tool-call wrapping inflates output tokens versus native `output_config`. That is accepted for P0 measurement. The corpus is small and hand-labeled; it can overfit the prompt. Record that limit in Results.

### Must NOT do

- No state mutation, no controller edit, no orchestrator edit, no prompt edit under `app/prompts`.
- No AWS Batch, no S3 invocation job.
- No second semantic object besides the harness-local schema.
- No edit to `query_analysis.rb`.
- No `KbDocumentResolver` call.
- No speculative RetrieveAndGenerate.
- No commit of foreign worktree files.
- No silent label edit after the first network call.
- No `git add -A`, `git add .`, `git commit -a`, `git checkout`, `git restore`, `git stash`, or `git clean`.

### Results
One network run, 70/70 cases scored, status `complete`. Model `global.anthropic.claude-haiku-4-5-20251001-v1:0`. Report: `tmp/haiku_semantic_perception_p0_report.json` (not committed). Corpus and prompt SHA256 match the frozen values below. `unsafe_contamination` is 0. Open-world projection accuracy is 48/60 for Haiku and 24/60 for v4. Transport errors are 0. The pre-registered rule yields `PROCEED_RECOMMENDED`. That recommendation does not authorize P1.

The corpus is a 70-case hand label. Tool-call wrapping is the measured output path. `relation_accuracy` is 31/60, below projection accuracy, because several projection matches still disagree on `relation`.

### Unexpected findings
No frozen label was edited after the run. No label is reclassified here.

Haiku attached `pending_question` on closed answer cases whose gold `refers_to` is empty (`closed-model-1`, `closed-code-1`, `closed-choice-1`, `closed-choice-2`). On `closed-measure-2` it attached `obs_1`; the approved gold keeps `refers_to` empty and does not score that binding as capability. `invalid_schema` is 4 and `hallucinated_spans` is 7. Those outputs project to no inheritance and no slots. `ambiguous_surfaced` is 7/8.

### Recommendation
PROCEED_RECOMMENDED

### Decision
PENDING_HUMAN

### Impact on next phase
P1 is not authorized and was not started.

### PHASE_COMMIT
41fbb98c6e50f0860a50e477dc2d898ac9bcac40

### PHASE_TEST_RESULT
`env -u BUNDLE_PATH bin/rails test test/scripts/haiku_semantic_perception_p0_test.rb` before the network run: 10 runs, 1769 assertions, 0 failures, 0 errors, 0 skips.

### PHASE_METRICS
```text
unsafe_contamination: 0
projection_accuracy_haiku_open_world: 0.8 (48/60)
projection_accuracy_v4_open_world: 0.4 (24/60)
relation_accuracy: 0.5166666666666667 (31/60)
slot_accuracy: 0.8 (48/60)
ambiguous_surfaced: 0.875 (7/8)
closed_relation_agreement: 0.5 (5/10)
invalid_schema: 4
hallucinated_spans: 7
transport_error: 0
transport_error_rate: 0.0
input_tokens: 90814
output_tokens: 7322
cost_usd: 0.127424
semantic_analysis_ms_p50: 1426
semantic_analysis_ms_p95: 1737.45
cases_scored: 70
```

```text
P0_CORPUS_SHA256:
8b793b497c22b7ea6751ff9ba056e20886a9241d0c80fcf11944f37bf768140c

P0_PROMPT_SHA256:
516c09cc841b25e4cd24edeb95cee98891ede6b24a4e9a01d33c821ea39882a0

P0_LABEL_REVIEW:
APPROVED_BY_HUMAN
```

### EXECUTION PROMPT — PHASE P0

```text
Read sections 1, 4, 12 and the complete P0 section before coding.
If summaries conflict, P0 is authoritative.
Historical v1 is not implementation authority.

You are implementing P0 of docs/PLAN_HAIKU_SEMANTIC_QUERY_ANALYSIS_2026-09-24.md only.

Branch: experiment/haiku-semantic-query-analysis
Plan baseline: BASELINE_COMMIT in that document, after the plan-only commit has replaced PENDING_PLAN_V2_COMMIT.
Do not start if BASELINE_COMMIT is still PENDING_PLAN_V2_COMMIT.
Architecture: HYBRID_MINIMAL (closed; do not revisit)
Query analysis: DECISION B. Do not edit app/services/rag/query_analysis.rb.
Do not create Rag::ConversationalTurnAnalysis under app/ in this phase.

Commit A, before any network call, only:
- script/fixtures/haiku_semantic_perception_p0.jsonl
- script/haiku_semantic_perception_p0.rb
- test/scripts/haiku_semantic_perception_p0_test.rb

Then STOP. A human reviews expected, safety, v4_expectation, and the prompt.
Record P0_CORPUS_SHA256, P0_PROMPT_SHA256, and P0_LABEL_REVIEW=APPROVED_BY_HUMAN.
Only then run the single network command.

Commit B, after the run, only:
- docs/PLAN_HAIKU_SEMANTIC_QUERY_ANALYSIS_2026-09-24.md
with Results, Metrics, Unexpected findings, Recommendation,
PHASE_COMMIT = Commit A, PHASE_TEST_RESULT, PHASE_METRICS,
Decision = PENDING_HUMAN.

The recommendation does not authorize P1.

Forbidden:
- app/**, config/**, db/**, Gemfile, Gemfile.lock, prompts, script/AGENTS.md
- docs/PLAN_PILOTO_ELEMONT_2026-09-24.md
- docs/ARCH_REVIEW_CONVERSATIONAL_VS_HAIKU_2026-09-25.md
- script/patch_elemont_*.rb
- bulk_chunks/, AWS Batch, RetrieveAndGenerate, state mutation, KbDocumentResolver
- git add -A, git add ., git commit -a, git checkout, git restore, git stash, git clean

Before each commit, git diff --cached --name-only must match the authorized paths exactly. If it does not, STOP.

Contract:
- model id literal: global.anthropic.claude-haiku-4-5-20251001-v1:0
- no ENV fallback, no credentials fallback
- client: retry_limit 0, max_attempts 1, http_open_timeout 2, http_read_timeout 8
- temperature 0, maxTokens 300, zero retries, tool semantic_perception forced
- prompt constant frozen before the network call; no corpus few-shot
- user message: {"turn","state","slots"} with slots derived from state
- schema: relation, mentions[{span,role}], refers_to[{span,slot}], ambiguous
- span normalization in section 4; do not fold accents
- error map, projection, and unsafe_contamination formula in the P0 section
- call Haiku for every case; needs_model=false does not skip the call
- closed_parse only from the deterministic parser; no Haiku capability credit on CLOSED_CONTRACT
- copy MODEL_VALUE_RE, KNOWN_CODE_RE, ABSENT_CODE_RE, normalize_label
- v4_expectation recomputed by ActiveEpisodeTurn.call; do not call record_user_turn!
- price constants 1 and 5 USD per MTok; Rails test checks BEDROCK_PRICING; script does not load BedrockQuery

Rails tests use: env -u BUNDLE_PATH bin/rails test ...
Network, once: env -u BUNDLE_PATH bundle exec ruby script/haiku_semantic_perception_p0.rb

PROCEED_RECOMMENDED only when unsafe_contamination==0
and projection_accuracy_haiku_open_world > projection_accuracy_v4_open_world
and transport_error<=5%.
Otherwise STOP_RECOMMENDED.
Decision stays PENDING_HUMAN.
On the first call, stop on ValidationException, AccessDenied, missing credentials,
tool_config/tool_choice rejection, or model/profile unavailable.
Do not pivot model, SDK, or Batch.
If transport_error>5% during the run, stop and report infrastructure failure.
```

---

## P1 — local shadow analyzer

### Hypothesis

The same contract can run on the live request path without changing `composed`, `active_episode`, or the RAG query, and every analyzer failure leaves v4 behavior intact.

### Why this phase exists

P0 does not measure request-path wiring, timeout behavior, or log shape. Shadow does, without transferring ownership.

### Preconditions

- A human has authorized P1 in this file after P0 `Decision=PENDING_HUMAN` was reviewed. The harness recommendation does not authorize P1.
- This prompt's "not authorized" line has been removed in the same edit that records that human authorization.
- P0 recorded `unsafe_contamination=0` and real token numbers.

### Exact scope

Shadow flag default off. When `HAIKU_QUERY_ANALYSIS_MODE=shadow`, call the analyzer before `record_user_turn!` on text turns that pass the structural gate. Pass the object through. `ActiveEpisodeTurn` ignores it. Effective query stays v4. Log one structured event. No retrieval change.

### Files to CREATE

- `app/services/rag/conversational_turn_analysis.rb`
- `app/services/rag/semantic_query_analyzer.rb`
- `app/services/rag/haiku_query_analysis_flag.rb`
- matching tests under `test/services/rag/`

### Files to MODIFY

- `app/controllers/rag_controller.rb` (call site only)
- `app/controllers/concerns/rag_query_concern.rb` (accept and ignore the object)
- `app/services/bedrock_client.rb` (add `converse` JSON/tool method; do not change `generate_text` defaults)
- this document

### Files READ_ONLY

- `app/services/rag/query_analysis.rb`
- `app/services/rag/query_entities.rb`
- `app/services/rag/active_episode_turn.rb` except a test seam if required to ignore the object without changing decisions
- generation prompts

### Files OUT_OF_SCOPE

Foreign worktree list. `technical_referent_resolver.rb` behavior. `generation.txt`. Gemfile unless P0 Results explicitly say `tool_config` cannot encode the schema and a recorded decision authorizes an SDK bump. Orchestrator routing. Batch.

### Exact implementation steps

1. Flag enum `off|shadow|conditional|always`. Unknown string = `off`. P1 runtime only honors `off` and `shadow`. `conditional` and `always` are accepted by the parser and behave as `off`.
2. Analyzer builds `ConversationalTurnAnalysis` only after span and slot validation. Invalid, timeout, 5xx, throttle → nil. Zero retries.
3. Controller calls it only for the structural gate. Shadow does not change `record_user_turn!` arguments that affect state.
4. Concern keeps `episode_turn.composed || raw`.
5. Log: correlation_id, analyzer_status, relation, ambiguous, semantic_analysis_ms, input_tokens, output_tokens, cost_usd. No transcript body, no photos, no prompt text.

### Contract after this phase

Request-scoped `ConversationalTurnAnalysis` exists. State and query match v4 for the same turn. `QueryAnalysis` unchanged.

### Tests to add/change

Flag default off. Garbage flag off. Shadow with a hostile analysis does not change `composed` or episode facts versus v4. Timeout and invalid span yield nil and v4. No network in tests.

### Commands to run

```bash
bin/rails test test/services/rag/semantic_query_analyzer_test.rb \
  test/services/rag/haiku_query_analysis_flag_test.rb \
  test/services/rag/active_episode_turn_test.rb \
  test/models/conversation_session_test.rb \
  test/controllers/concerns/rag_query_concern_test.rb
```

### Telemetry

`semantic_analysis_ms` on the shadow log event. `state_ms` not split yet. No percentile store. Do not add a table.

### Expected artifacts

Shadow classes, tests, one commit, Results filled.

### Exit criteria

v4 slice green. 100% of injected analyzer failures stay on v4 in tests. Shadow mode does not change composed query in tests. P0 gate still the last measured contamination number; P1 does not claim a new contamination rate without a labeled sample.

### Rollback

Flag default `off`. Revert the commit. No data migration.

### Stop conditions

Any test shows composed query or episode facts changed in shadow. Any write to foreign files. Temptation to honor `conditional` early.

### Risks

Synchronous shadow adds latency on gated turns even though the answer is v4. Timeout must be the P0 p95 plus margin recorded in P0 Results, else 8s is too slow for a user-facing shadow and the phase stops to record a lower timeout before enabling the flag anywhere but local.

### Must NOT do

No episode mutation from the analysis. No retrieval change. No heuristic deletion. No `conditional` behavior.

### Results
Local shadow is implemented and default `off`. `HAIKU_QUERY_ANALYSIS_MODE=shadow` calls Haiku on a text turn that already has an episode, pending fact, or active photo, before `record_user_turn!`. The object is logged and ignored. `conditional` and `always` parse and do not call. Timeout, invalid schema, hallucinated span, 5xx, and throttle return nil. `composed`, episode facts, and the effective query stay on v4. No network call was made in tests. P1 does not claim a new contamination rate; the last labeled figure remains P0 `unsafe_contamination=0`.

Human authorization recorded in this edit: `AUTHORIZE_P1_LOCAL_SHADOW`.

### Unexpected findings
P0 p95 was 1737.45 ms and the shadow client keeps the P0 read timeout of 8s with zero retries. That is too slow to enable outside local. No retrieval parallelization and no shorter timeout were introduced. There is no request-path latency sample in this phase because tests do not call Bedrock.

### Decision
PENDING_HUMAN

```text
P1_HUMAN_DECISION:
AUTHORIZE_P2

RATIONALE:
P1 proved that shadow analysis is behaviorally inert and analyzer failures
preserve v4 behavior. No semantic ownership or retrieval behavior changed.
The absence of a new live request-path latency sample is recorded but does
not block P2 because P2 is a deterministic pending_question contract and
adds no semantic inference call.

AUTHORIZED:
P2 pending_question contract only

NOT_AUTHORIZED:
P3 semantic ownership
conditional mode
pilot rollout
heuristic retirement
retrieval optimization
```

### Impact on next phase
P2 is authorized as the deterministic pending_question contract only. P3 is not authorized.

### PHASE_COMMIT
The P1 commit that contains this Results block. Its hash is not written inside itself.

### PHASE_TEST_RESULT
`bin/rails test` on the P1 analyzer, flag, active episode, conversation session, and rag query concern files: 308 runs, 1517 assertions, 0 failures, 0 errors, 22 skips.

### PHASE_METRICS
No live shadow sample. `semantic_analysis_ms`, `analyzer_status`, `relation`, token counts, and `cost_usd` are on the log event only. No percentile store and no table. P0 remains the last measured latency: p50 1426 ms, p95 1737.45 ms, cost_usd 0.127424.

### EXECUTION PROMPT — PHASE P1

```text
AUTHORIZED: AUTHORIZE_P1_LOCAL_SHADOW. Local shadow only. Do not start P2.

When authorized: implement P1 local shadow only, on experiment/haiku-semantic-query-analysis, from the P0 PHASE_COMMIT.
Create ConversationalTurnAnalysis, SemanticQueryAnalyzer, HaikuQueryAnalysisFlag.
Wire RagController and RagQueryConcern so shadow logs and ignores the object.
Do not edit query_analysis.rb, query_entities.rb, generation prompts, or the foreign worktree files.
Do not change composed queries or active_episode.
conditional and always parse but behave as off.
Zero retries. Failures yield nil and v4.
Commit one logical commit. Fill P1 result blocks. Do not start P2.
```

---

## P2 — pending-question contract

### Hypothesis

Typed pending questions can be emitted by Ruby on routes that already know the question, without a new model call and without breaking RetrieveAndGenerate citations.

### Why this phase exists

`write_pending!` recovers only manufacturer, model, and fault_code by scanning prose. Choice answers and explicit absence need a machine-readable question. Section 8 is the route map.

### Preconditions

P1 exit criteria recorded. Perception still does not own state.

### Exact scope

Add `pending_question` on the assistant-turn write path for deterministic routes and for Structured/Context routes only when the route already knows the question type in Ruby. RetrieveAndGenerate and document-identity generation keep the prose scan. No JSON inside cited answers.

### Files to CREATE

- `app/services/rag/pending_question.rb` (value object + closed parsers for `ninguno` and choice)
- tests

### Files to MODIFY

- `app/services/rag/active_episode.rb` (sanitize an optional `pending_question` beside `pending_fact`, within the 2048-byte budget)
- `app/services/rag/active_episode_turn.rb` (`write_pending!` stores the object when the caller passes one; prose scan remains the fallback)
- `app/models/conversation_session.rb` (pass through the object on assistant record)
- deterministic / structured / context route files that already ask a typed question
- this document

### Files READ_ONLY

- `app/services/bedrock_rag_service.rb` RetrieveAndGenerate citation path
- `generation.txt`
- `query_analysis.rb`

### Files OUT_OF_SCOPE

Foreign worktree. Semantic ownership. Heuristic deletion. SDK bump. Speculative retrieve.

### Exact implementation steps

1. Implement the value object with types `fault_code`, `manufacturer`, `model`, `choice`, `absent`.
2. Thread it from route result to `record_assistant_turn!` when the route set it.
3. Leave RetrieveAndGenerate citations untouched.
4. Closed parsers: fault_code + `ninguno` → absent; choice + option text → that option. These parsers do not call a model.
5. Measure episode bytes. If `shrink_to_budget!` drops identifiers in existing tests, stop and drop the persisted field rather than evicting identifiers.

### Contract after this phase

Assistant turns from covered routes persist `pending_question`. Perception may read it in a later phase. It does not write it.

### Tests to add/change

Parser cases. Budget test. RetrieveAndGenerate response text unchanged when a pending question exists. Prose scan still sets manufacturer/model/fault_code when no structured object was passed.

### Commands to run

Focused episode, session, route, and prompt tests that already cover citations.

### Telemetry

Log `pending_question_type` on the episode turn log. No new table.

### Expected artifacts

One commit. Results note which routes emit the object and which still use prose.

### Exit criteria

No citation test regression. No new model call. Byte budget holds on existing episode fixtures.

### Rollback

Revert the commit. `pending_fact` prose path is still there.

### Stop conditions

Citation spans shift. Episode eviction of identifiers. A proposal to put JSON in the RetrieveAndGenerate answer.

### Risks

Two pending representations (`pending_fact` and `pending_question`) during the overlap. The prose path remains fallback only, and the structured object wins when both exist.

### Must NOT do

No second LLM call to classify the assistant question. No edit to citation instructions.

### Results
Deterministic `pending_question` is persisted beside `pending_fact`. Types: `fault_code`, `manufacturer`, `model`, `choice`, `absent`. A structured object wins over the prose scan. The prose scan still sets `pending_fact` when no object is passed. `ninguno` on a fault-code question confirms absence. `al abrir` on choice `opening`/`closing` selects `opening`. No new model call. RetrieveAndGenerate citation code was not edited.

Routes that emit the object: `AmbiguousModelResponder`, as `choice` with the board labels Ruby already asks about. StructuredEvidenceRoute, ContextEvidenceRoute, DocumentIdentityScope generation, and RetrieveAndGenerate still use the prose scan. They do not already know a single typed question in Ruby.

P0 semantic p95 remains 1737.45 ms. P1 recorded no new live request-path latency sample. P2 does not change that timeout.

### Unexpected findings
None that change the contract. The choice answer is not a fact slot; the parser clears the question and does not invent a stored value.

### Decision
PENDING_HUMAN

```text
P2_HUMAN_DECISION:
AUTHORIZE_P3_NARROW_SEMANTIC_OWNERSHIP

AUTHORIZED_SCOPE:
explicit switch/correct ownership only

NOT_AUTHORIZED:
general continue ownership
answer_pending ownership
heuristic retirement
always mode
pilot rollout
retrieval changes
latency optimization
P4+
```

### Impact on next phase
P3 is authorized only for explicit switch/correct ownership. P4 is not authorized.

### PHASE_COMMIT
The P2 commit that contains this Results block. Its hash is not written inside itself.

### PHASE_TEST_RESULT
Pending-question, episode, session, ambiguous-model, and citation tests: 241 runs, 870 assertions, 0 failures, 0 errors, 0 skips. Prompt, structured-evidence, and context-evidence tests: 97 runs, 581 assertions, 0 failures, 0 errors, 0 skips.

### PHASE_METRICS
No new model call. No latency change. Episode budget stays 2048 bytes. The budget test keeps existing identifiers and facts after storing `pending_question`.

### EXECUTION PROMPT — PHASE P2

```text
AUTHORIZED: AUTHORIZE_P2. Pending-question contract only. Do not start P3.

Implement only the pending_question contract from section 8.
Ruby emits it where the route already knows the question.
Do not add a model call. Do not modify RetrieveAndGenerate citation text.
Do not transfer semantic ownership. Do not delete heuristics.
One commit. Fill P2 blocks. Do not start P3.
```

---

## P3 — first semantic ownership slice

### Hypothesis

For one open-world family only, validated perception can decide relation (`switch` / `correct` / `unclear`) without unsafe inheritance, while v4 still decides every other turn.

### Why this phase exists

Shadow does not prove the state machine can consume perception. A single family limits blast radius.

### Preconditions

P0 contamination 0. P1 shadow failure-to-v4 proven. P2 pending contract recorded. Family from P0 and this authorization: explicit equipment switch / correction (`switch`, `correct`), not deixis.

### Exact scope

When the flag is `conditional` and the structural gate is on and the validated relation is `switch` or `correct` or `ambiguous=true`, Ruby applies only the policies already in v4 for explicit correction and context break. `ambiguous=true` clears inheritance for that turn and does not copy a referent. No other relation changes state. Catalog validation required before any model mention becomes manufacturer or model.

### Files to CREATE

Tests for the slice only.

### Files to MODIFY

- `app/services/rag/active_episode_turn.rb`
- `app/services/rag/haiku_query_analysis_flag.rb` (honor `conditional` for this slice only)
- this document

### Files READ_ONLY

- `query_analysis.rb`, prompts, retrieval profile, foreign worktree, `technical_referent_resolver.rb` except reading its existing break/correction results

### Files OUT_OF_SCOPE

Deixis persistence, component slot, `FollowupQueryRewriter` deletion, retrieval parallelism, hands-free.

### Exact implementation steps

1. Write the chosen family into this section from P0 Results before coding.
2. On `conditional`, apply the slice. All other relations: ignore perception and use v4.
3. Catalog/extractor veto beats the model.
4. Hostile tests: model says continue when the turn is an explicit correction; model says a model name not in the turn; model says ambiguous. v4 invariants in historical section 19 still hold.

### Contract after this phase

One slice of state listens to validated perception. Fallback for analyzer failure on that slice is validated facts + raw turn, or clarification if the turn is not self-contained. Not v4 semantic inheritance.

### Tests to add/change

Hostile analyzer stubs for every historical section 19 invariant that the slice could touch. Catalog miss does not persist identity.

### Commands to run

Episode turn tests plus the new slice tests.

### Telemetry

Log `ownership_slice=switch_correct` and whether perception was applied or ignored.

### Expected artifacts

One commit. Family name recorded.

### Exit criteria

`unsafe_contamination=0` on the P0 corpus replay for this slice (offline replay, not a new live gate) and v4 tests green. Any new contamination stops the phase.

### Rollback

Flag back to `shadow` or `off`. Revert the commit.

### Stop conditions

Slice needs a new state field. Slice needs a retrieval change. Contamination non-zero.

### Risks

The default family might be too small to show value. That is an acceptable stop, recorded as Decision, not a reason to widen the slice in the same commit.

### Must NOT do

No heuristic deletion. No deixis. No effective-query change.

### Results
Conditional mode owns only validated `switch` and `correct`. `continue`, `answer_pending`, `new`, shadow, and `always` stay on v4. A switch opens a fresh episode and does not compose the prior goal. A model value is written only when the equipment span is literal and the tenant catalog returns exactly one document whose name is also in the turn. A catalog miss writes nothing. `correct` clears the prior model and manufacturer, then the existing extractor writes only an explicit current-turn fact. `ambiguous` and `unclear` clear those facts and do not compose. Analyzer failure on an explicit equipment shift uses the same fresh episode and does not restore v4 inheritance. P0 switch rows with `equipment_inheritance=forbidden` do not keep MonoSpace. No P0 label or corpus edit.

### Unexpected findings
The turn now reads `ConversationalTurnAnalysis`. The P1 source lock that forbade that string in `active_episode_turn.rb` was updated. `record_user_turn!` still rejects the object as a keyword; conditional fetches perception through `observe_ownership`, which is the same one Converse call, not a second model. Catalog needs the session account, so `record_user_turn!` passes `account:`. P0 semantic p95 1737.45 ms stays a known risk. No latency change.

### Decision
PENDING_HUMAN

### Impact on next phase
P4 is not authorized.

### PHASE_COMMIT
The P3 commit that contains this Results block. Its hash is not written inside itself.

### PHASE_TEST_RESULT
Ownership, flag, analyzer, episode, pending-question, session, and query-concern tests: 340 runs, 1629 assertions, 0 failures, 0 errors, 22 skips.

### PHASE_METRICS
Owned relations: switch, correct. New model calls: 0 beyond the existing one perception call. No retrieval change. No heuristic deletion. Semantic p95 remains 1737.45 ms.

### EXECUTION PROMPT — PHASE P3

```text
AUTHORIZED: AUTHORIZE_P3_NARROW_SEMANTIC_OWNERSHIP. Explicit switch/correct only.

Implement only that family under HAIKU_QUERY_ANALYSIS_MODE=conditional.
Ruby and catalog remain authority. Analyzer failure does not inherit v4 semantics for this slice.
Do not change retrieval, prompts, QueryAnalysis, or foreign files.
One commit. Do not start P4.
```

---

## P4 — minimal state evolution

### Hypothesis

`active_referent` plus the existing `pending_question` and observation ids are sufficient for `refers_to` to address "el otro" / "ese" / "la anterior" without a procedure ontology.

### Why this phase exists

P0 can score pointers against slots derived from fixture state. Production cannot point at a slot that is not stored. This phase adds only slots a demonstrated consumer reads.

### Preconditions

P3 exit recorded. P0 report shows `refers_to` cases with zero hallucinated slots. A consumer is named in Results before coding (effective query or clarification). If no consumer is demonstrated, skip the phase and record Decision=skip.

### Exact scope

Persist `active_referent` as `{head, correlation_id}` only if a consumer in this phase reads it. Reuse observation ids that photo recording already stores. Do not add procedure, step, or measurement history.

### Files to CREATE

Tests only.

### Files to MODIFY

- `app/services/rag/active_episode.rb`
- the single consumer named in the precondition
- this document

### Files READ_ONLY

Retrieval services, prompts, QueryAnalysis, foreign worktree.

### Files OUT_OF_SCOPE

`current_procedure`, measurement history, hypothesis graph, hands-free ASR.

### Exact implementation steps

1. Name the consumer in this section.
2. Add the smallest hash that consumer reads.
3. Re-check 2048-byte shrink behavior.
4. Semantic model still cannot write the slot. Ruby writes it from a validated mention.

### Contract after this phase

Addressable slots in production match the minimum list in section 4, or the phase is skipped.

### Tests to add/change

Budget, unknown slot rejected, explicit switch clears `active_referent`.

### Commands to run

Episode tests and the consumer's tests.

### Telemetry

`active_referent_present` boolean on the turn log. No raw span text if it duplicates history.

### Expected artifacts

One commit or an explicit skip decision.

### Exit criteria

Consumer test proves the slot is read. Budget holds. Contamination replay still 0.

### Rollback

Revert. Empty referent means previous behavior.

### Stop conditions

Budget eviction. No consumer. Proposal to store a procedure graph.

### Risks

Slot unused and still eating bytes. Prefer skip over an unread field.

### Must NOT do

No ontology. No unread JSON.

### Results
No demonstrated production consumer for `active_referent`. Effective query construction (`ActiveEpisodeTurn#compose_text`, consumed by `RagQueryConcern#execute_rag_query`) reads goal, manufacturer, model, identifiers, and fault code. Clarification (`EpisodeThreadResolver`, `AmbiguousModelResponder`, the selection gate) does not read a discourse referent. `ConversationalTurnAnalysis#refers_to` is validated and then ignored by the P3 ownership slice. `SemanticQueryAnalyzer#perception_state` always sends `active_referent: null`. `TechnicalReferentResolver` reads the goal for `ajust*` and is a later heuristic, not this consumer. Logging is not a consumer. P5–P7 are not consumers. `active_referent` was not persisted.

### Unexpected findings
Photo recording stores `active_photo` (`field_photo_id`, `sha256`, `correlation_id`). It does not store observation ids. That does not create a referent consumer.

### Decision
skip

```text
P4_DECISION:
skip

CONSUMER_FOUND:
NO

PRODUCTION_CODE_CHANGED:
NO

P4_HUMAN_DECISION:
accepted skip. AUTHORIZE_P5_FAMILY_1

AUTHORIZED_SCOPE:
common_noun? and identity_complement? only

NOT_AUTHORIZED:
other P5 families
P6
```

### Impact on next phase
P5 family 1 was authorized. It stopped before deletion. P6 is not authorized.

### PHASE_COMMIT
N/A

### PHASE_TEST_RESULT
No production change. No new tests. Inspection only: no reader of `active_referent` under `app/`.

### PHASE_METRICS
Consumer found: no. Production code changed: no. New model calls: 0. State bytes added: 0.

### EXECUTION PROMPT — PHASE P4

```text
NOT AUTHORIZED until this section names one consumer or records Decision=skip.

If skip: do not code. If not skip: persist only active_referent as specified, for that consumer.
Do not add procedure state. One commit. Do not start P5.
```

---

## P5 — retire duplicate semantic heuristics

### Hypothesis

One heuristic family can be deleted when perception plus Ruby policy covers its tests, without a second semantic engine left behind.

### Why this phase exists

Haiku plus `common_noun?` plus `FollowupQueryRewriter` must not remain the steady state.

### Preconditions

P3 ownership slice stable. The family to remove is the first row below, unless P3 Results name a different first family.

Order, one family per commit, each its own future execution after the previous Results:

1. `common_noun?` and `identity_complement?`
2. `unreaffirmed_name?`
3. `technical_nps` limited to `ajust*`
4. duplicated continuity cues
5. `FollowupQueryRewriter` as a semantic composer, only when episode and no-episode paths share one composer

### Exact scope

The first family only, in the first authorized P5 commit.

### Files to CREATE

None unless a test file move is required.

### Files to MODIFY

- `app/services/rag/technical_referent_resolver.rb`
- its tests
- this document

### Files READ_ONLY

QueryAnalysis, prompts, retrieval, foreign worktree.

### Files OUT_OF_SCOPE

Families 2–5 in the same commit. Latency work. Hands-free.

### Exact implementation steps

1. Confirm coverage exists for the family in episode tests and the P0 corpus.
2. Delete only that family.
3. Keep provenance, recency, atomic persist, coordination limits, and the 442-character cap.

### Contract after this phase

That family is gone. Perception plus Ruby policy covers it. Other heuristics remain until their own commit.

### Tests to add/change

Existing hostile tests updated to the new owner. No loss of contamination cases.

### Commands to run

Resolver and episode turn tests.

### Telemetry

Log `heuristic_family_retired=common_noun` once in the commit message and the plan, not per request.

### Expected artifacts

One commit per family.

### Exit criteria

Tests green. No path still calls the deleted method. Contamination replay 0.

### Rollback

Revert that commit only.

### Stop conditions

A case only the regex resolved, with no perception coverage. Stop and record it. Do not reintroduce the regex in the same commit as a silent fallback.

### Risks

Hidden caller of `common_noun?`. Grep before delete.

### Must NOT do

Do not delete all families at once. Do not keep the method as an automatic fallback.

### Results
BLOCKED. `common_noun?` and `identity_complement?` were not deleted.

Callers are only inside `TechnicalReferentResolver`: `contaminated?` and `expand`. No other runtime caller.

The methods are still the only guard for a lowercase one-word equipment complement copied onto a new explicit model. `unreaffirmed_name?` covers mixed case and all caps. `specific_token?` covers tokens with a digit. Neither covers `minispace`, `maxpro`, or `evo`.

Production cases, already asserted in `active_episode_turn_test.rb`:

- `a bare de complement is not copied onto a new model` — goal `Cómo se ajustan los resortes de minispace?`, turn `el modelo es MonoSpace, como se ajustan los resortes?`
- `determined equipment names are not copied onto a new model` — `de minispace`, `del minispace`, `de la minispace` in lowercase
- `a short unknown equipment name is not copied onto a new model` — `maxpro`, `evo`

Those turns are not `switch` or `correct`. Covering them with perception would make `continue` Haiku-owned. P3 was not widened. The methods stay in place. They are not a silent fallback.

### Unexpected findings
`en minispace` inside a longer complement is already blocked by `pure_complement?`, not by this family. The unique residue is a single `de`/`del` complement whose token is lowercase and has no digit.

### Decision
DEFER_FAMILY_1

```text
P5_HUMAN_DECISION:
DEFER_FAMILY_1

FAMILY:
common_noun? + identity_complement?

REASON:
Still required for lowercase one-word equipment complements on continue +
explicit-model turns not owned by P3.

DO_NOT_WIDEN_P3:
YES

P5_FAMILY_1_RETIRED:
NO

P6_AUTHORIZED:
YES

P5_DECISION:
DEFER_FAMILY_1

P3_WIDENING:
NOT_AUTHORIZED
```

### Impact on next phase
P5 family 1 stays. That deferral authorizes P6 measurement only. Families 2–5 and P7 are not authorized.

### PHASE_COMMIT
The commit that records this stop. Its hash is not written inside itself. No production code changed.

### PHASE_TEST_RESULT
No behavior change, so the resolver and episode suites were not re-run as a retirement proof. Contamination replay was not used to justify a deletion.

### PHASE_METRICS
heuristic_family_retired=none. Callers remaining: `TechnicalReferentResolver#contaminated?`, `TechnicalReferentResolver#expand`. unsafe_contamination not reopened.

### EXECUTION PROMPT — PHASE P5

```text
AUTHORIZED: AUTHORIZE_P5_FAMILY_1. Stopped. Family not deleted.

The lowercase complement cases above are still resolved only by common_noun? and identity_complement?.
Do not delete them until a human names a deterministic owner that is not continue-ownership.
Do not start family 2. Do not start P6.
```

---

## P6 — retrieval latency optimization

### Hypothesis

After correctness, a gated turn can overlap perception with an explicit Retrieve of the raw turn only when a structural fingerprint says retrieval meaning did not change.

### Why this phase exists

Serial perception adds latency on top of RetrieveAndGenerate. Overlap is only safe for explicit Retrieve, never for speculative RetrieveAndGenerate.

### Preconditions

P5 first family retired or explicitly deferred with a reason. Contamination still 0. Latency numbers from P1 shadow exist.

### Exact scope

Measure `semantic_analysis_ms`, `state_ms`, `retrieve_ms`, `generation_ms`/`rag_ms`, `total_ms`. Optional experiment: parallel explicit Retrieve when there is no inherited state and the fingerprint matches. Default remains serial. Do not change `top_k`, filters, or reranker.

### Files to CREATE

A benchmark script sibling of `script/rag_quality_benchmark.rb` only if measurement cannot be done with existing logs.

### Files to MODIFY

Telemetry call sites already logging latency, and this document.

### Files READ_ONLY

Reranker, generation prompt, QueryAnalysis, foreign worktree.

### Files OUT_OF_SCOPE

Speculative RetrieveAndGenerate. Reranker enablement. Embedding changes.

### Exact implementation steps

1. Add phase timings where the route already has a clock. For RetrieveAndGenerate record `rag_ms`, not a fake split.
2. Report p50/p95/p99 per route. Do not sum percentiles.
3. Parallel explicit Retrieve stays behind a default-off flag and only when fingerprint fields match: equipment, component span, fault, constraints. Deixis, correction, switch, ambiguity, photo scope change: discard.

### Contract after this phase

Timings exist. Retrieval architecture unchanged unless the fingerprint experiment's Decision says otherwise, in a later prompt.

### Tests to add/change

Fingerprint mismatch discards raw retrieve. No test calls RetrieveAndGenerate speculatively.

### Commands to run

Route tests plus the benchmark script if created.

### Telemetry

The five clocks above, plus `speculative_retrieve=reused|discarded|off`.

### Expected artifacts

Metrics in this document. Code commit only if timings or the flag landed.

### Exit criteria

p50/p95/p99 recorded per route on a stated sample. No correctness regression on the v4 slice.

### Rollback

Flag off. Revert timing-only commit if it changes behavior.

### Stop conditions

Any proposal to speculative-RetrieveAndGenerate. Fingerprint undefined for a field that changes meaning.

### Risks

Parallel retrieve wasted spend when meaning changes. Discard default keeps that off until measured.

### Must NOT do

No correctness work disguised as latency work. No reranker.

### Results
MEASURE_ONLY. `interaction_completed` now records `semantic_analysis_ms`, `state_ms`, `retrieve_ms`, `generation_ms`, `rag_ms`, and `total_ms` from clocks that already exist. RetrieveAndGenerate logs `rag_ms` only. The structured route logs `retrieve_ms` and `generation_ms`. Missing clocks are omitted, not invented.

No live request-path sample was taken in this phase. The only trustworthy semantic sample remains P0: p50 1426 ms, p95 1737.45 ms. P0 did not record p99. `total_ms` p50/p95/p99 are not reported.

Parallel explicit Retrieve was not wired. `ExplicitRetrieveOverlap` defaults off and performs no retrieval. A fingerprint mismatch, switch, correct, ambiguity, deixis, or photo scope change discards only when the flag is on.

### Unexpected findings
P1 still has no live request-path timing. Instrumenting the log does not create that sample. A Bedrock load run was not started.

### Decision
MEASURE_ONLY

### Impact on next phase
P7 is not authorized. Parallel Retrieve stays off until a human records Decision=allow_parallel_explicit_retrieve after a live sample.

### PHASE_COMMIT
The P6 commit that contains this Results block. Its hash is not written inside itself.

### PHASE_TEST_RESULT
Overlap and P3 ownership tests: 19 runs, 48 assertions, 0 failures. Controller phase-timing test passed. Answers unchanged. `common_noun?` and `identity_complement?` still present.

### PHASE_METRICS
semantic_analysis_ms p50 1426, p95 1737.45, from the frozen P0 sample only. total_ms not measured live. speculative_retrieve=off. No top_k, filter, reranker, or prompt change.

### EXECUTION PROMPT — PHASE P6

```text
AUTHORIZED: P6 measurement. Decision=MEASURE_ONLY.

Phase clocks are on interaction_completed. Parallel explicit Retrieve stays default off and unwired.
Do not speculative-call RetrieveAndGenerate. Do not start P7.
```

---

## P7 — hands-free expansion

### Hypothesis

Hands-free can reuse the same perception object and pending-question contract, with ASR metadata and photo correlation as additional inputs, without a new semantic model.

### Why this phase exists

The structural gate is near-always-on in hands-free. That mode needs transcript uncertainty and multimodal correlation that typed chat does not.

### Preconditions

P3 ownership and P2 pending contract are live. P6 timings show whether always-on perception fits a voice budget. This phase is not authorized by P0 alone.

### Exact scope

Document and, only when a hands-free channel exists in the request, pass ASR confidence and photo correlation id into the analyzer context. Do not persist low-confidence identity. Clarification UX for equipment/procedure/measurement-point ambiguity. No new model.

### Files to CREATE

TBD when a hands-free controller exists. If none exists, this phase is design-only and must not invent the channel.

### Files to MODIFY

TBD by the channel's actual files. This document.

### Files READ_ONLY

QueryAnalysis, retrieval architecture, foreign worktree.

### Files OUT_OF_SCOPE

A second analyzer. Procedure ontology. WhatsApp.

### Exact implementation steps

1. Find the real hands-free entry point. If it does not exist, stop with Decision=no_channel.
2. Extend the structural gate's hands-free arm to that entry point.
3. Pass ASR alternatives as text the span validator can see. Spans must still be literal in the chosen transcript.
4. Reuse P2 pending questions and P4 slots. Do not add measurement correctness judgments.

### Contract after this phase

Same perception schema. Additional optional context: ASR confidence, photo correlation. Identity still catalog-gated.

### Tests to add/change

Low ASR confidence does not persist manufacturer/model. Photo correlation uses the existing photo observation id.

### Commands to run

The channel's tests plus episode tests.

### Telemetry

`hands_free=true`, `asr_confidence` bucket, `semantic_analysis_ms`.

### Expected artifacts

One commit or a no-channel decision.

### Exit criteria

No new contamination. No second model. Channel either wired or explicitly absent.

### Rollback

Gate arm off for hands-free.

### Stop conditions

No channel. Pressure to add a procedure graph. Pressure to call a second model for ASR.

### Risks

Near-always-on cost. Use P0 unit cost times observed hands-free volume. Cost still does not override contamination.

### Must NOT do

Do not build the voice product in this plan. Do not enable WhatsApp.

### Results
TBD

### Unexpected findings
TBD

### Decision
TBD

### Impact on next phase
TBD

### PHASE_COMMIT
TBD

### PHASE_TEST_RESULT
TBD

### PHASE_METRICS
TBD

### EXECUTION PROMPT — PHASE P7

```text
NOT AUTHORIZED until P6 Results are recorded and a hands-free entry point is identified in the repo.

If no entry point exists, write Decision=no_channel and stop.
Otherwise reuse ConversationalTurnAnalysis and pending_question. Do not add a model.
One commit.
```

---

## 14. Adaptive measurements still open

```text
ASSUMPTION: Haiku invocation fraction ≈ 15% on typed structural gate
MEASUREMENT: TBD from P1 shadow
DECISION: TBD

ASSUMPTION: input 1500–2500, output 100–200
MEASUREMENT: TBD from P0
DECISION: TBD

ASSUMPTION: tool_config on SDK 1.63.0 Converse accepts the perception schema for Haiku 4.5 global
MEASUREMENT: TBD from the first P0 call
DECISION: TBD
```

These are not architectural questions. If the tool_config assumption fails, P0 stops. It does not pick a new architecture.

## 15. Final readiness

```text
ARCHITECTURE_DECISION:
HYBRID_MINIMAL

SEMANTIC_MODEL_SCOPE:
relation, mentions[{span, role}], refers_to[{span, slot}], ambiguous.
No effective query, route, measurement value, safety judgment, procedure, or answer.

DETERMINISTIC_SCOPE:
State, persistence, provenance, recency, catalog identity, closed parsers
(fault_code absence, choice options, measurement value/unit/location, explicit model frame),
effective query construction, retrieval authorization, pending_question emission.

QUERY_ANALYSIS_CONVERGENCE:
B. Rag::ConversationalTurnAnalysis is the only semantic-perception object.
Rag::QueryAnalysis stays the QueryEntities evidence-identifier object.
They never merge. P0 does not add the class under app/.

PENDING_QUESTION_STRATEGY:
One Ruby contract (fault_code, manufacturer, model, choice, absent).
Deterministic and structured/context routes emit it when they already know the question.
RetrieveAndGenerate and document-identity generation do not gain a JSON side channel;
they keep the prose scan until a route can set the object without a new model call.

CONDITIONAL_GATE:
active_episode OR pending_question/pending_fact OR active_photo OR hands_free.
No semantic pre-classifier.

FALLBACK_AFTER_MIGRATION:
Shadow: v4.
After ownership transfer: validated facts + raw turn, or clarification.
No unsafe inheritance.

NEXT_AUTHORIZED_PHASE:
PLAN_V2_COMMIT

P0_IMPLEMENTATION_READY:
YES

P0_REQUIRES_ARCHITECT_DECISION:
NO

OPEN_ARCHITECTURE_QUESTIONS:
NONE

FILES_P0:
script/fixtures/haiku_semantic_perception_p0.jsonl
script/haiku_semantic_perception_p0.rb
test/scripts/haiku_semantic_perception_p0_test.rb
docs/PLAN_HAIKU_SEMANTIC_QUERY_ANALYSIS_2026-09-24.md

P0_EXIT_CRITERIA:
Commit A tests green before any network call; human label review recorded;
one network run; Results, metrics, unexpected findings, and recommendation written;
Decision remains PENDING_HUMAN.
PROCEED_RECOMMENDED only when unsafe_contamination=0
and projection_accuracy_haiku_open_world > projection_accuracy_v4_open_world
and transport_error<=5%.
That recommendation does not authorize P1.
CLOSED_CONTRACT cases give Haiku no capability credit.

PLAN_READY_FOR_FINAL_OPUS_REVIEW:
NO_LONGER_REQUIRED
```

---

# HISTORICAL V1

**Objetivo:** decidir, con evidencia, si un análisis semántico síncrono de Claude Haiku 4.5 puede reemplazar la frontera `common_noun?` sin reabrir contaminación conversacional, y a qué costo de latencia y tokens.

**Estado de este documento:** plan solamente. No hay implementación de `SemanticQueryAnalyzer` en este branch más allá de este archivo. Supuestos de este bloque que la sección 2 de v2 marca INVALIDATED no autorizan implementación.

**Entrada:** baseline conversacional v4 en `dce25d080aaba1779898339206d7ec297bdbd3e7`. Código leído el 24-sep-2026 en `experiment/haiku-semantic-query-analysis`.

## 1. Baseline y branch

| Dato | Valor |
|---|---|
| Branch del baseline | `main` (al momento del commit, ahead de `origin/main` por 1) |
| Commit | `dce25d080aaba1779898339206d7ec297bdbd3e7` |
| Mensaje | `Fail closed when copying a technical referent from the active episode.` |
| Convención del repo | Frase imperativa, sin prefijo `feat(rag):`. El mensaje pedido se ajustó a esa convención. |
| Branch experimental | `experiment/haiku-semantic-query-analysis` |
| Convención de branches | Mixta (`rag/`, `docs/`, `pilot/`, `codex/`). No hay prefijo `experiment/`. Se usó el nombre pedido. |

Tests del baseline, antes del commit, con `env -u BUNDLE_PATH`:

```text
bin/rails test \
  test/services/rag/active_episode_turn_test.rb \
  test/models/conversation_session_test.rb \
  test/controllers/concerns/rag_query_concern_test.rb
```

Resultado: 294 runs, 1476 assertions, 0 failures, 0 errors, 22 skips.

Archivos del commit (7, +1211/−9):

- `app/models/conversation_session.rb`
- `app/services/rag/active_episode.rb`
- `app/services/rag/active_episode_turn.rb`
- `app/services/rag/technical_referent_resolver.rb` (nuevo)
- `test/controllers/concerns/rag_query_concern_test.rb`
- `test/models/conversation_session_test.rb`
- `test/services/rag/active_episode_turn_test.rb`

Fuera del commit, ajenos al fix conversacional, siguen sin stagear en el working tree:

- `docs/PLAN_PILOTO_ELEMONT_2026-09-24.md`
- `script/patch_elemont_chunk_p1_2_q123_2026-09-24.rb`
- `script/patch_elemont_chunk_p1_2_q4_2026-09-24.rb`
- `script/patch_elemont_designator_retrieval_2026-09-24.rb`
- `script/patch_elemont_random12_gaps_2026-09-24.rb`

## 2. Hallazgos de arranque

| # | Hallazgo | Evidencia |
|---|---|---|
| H1 | El turno de texto persiste el episodio antes de cualquier modelo. | `RagController#ask` llama `record_user_turn!` y después `execute_rag_query`. |
| H2 | Con el flag de episodio, la query efectiva es `episode_turn.composed` o el texto crudo. `FollowupQueryRewriter` no corre en ese camino. | `RagQueryConcern#execute_rag_query`, rama `episode_turn_owns_thread?`. |
| H3 | `QUERY_ROUTING_ENABLED` default `"false"`. `classify_query_intent` no corre en el camino de producción. | `QueryOrchestratorService.skip_routing?`, `config/deploy.yml.example`. |
| H4 | La generación de manuales es `retrieve_and_generate` con `BedrockClient::QUERY_MODEL_ID`. No hay un análisis estructurado previo al Retrieve. | `BedrockRagService#query`, `model_arn: @model_ref`. |
| H5 | `aws-sdk-bedrockruntime` 1.63.0 expone `converse` y `tool_config`. No expone `output_config`. | Grep del gem instalado: cero `output_config`. |
| H6 | Structured outputs de Bedrock para Haiku 4.5 existen en la API (GA 2026-02-04, `outputConfig.textFormat`). El SDK bloqueado es anterior a ese parámetro. | [Claude structured outputs](https://docs.aws.amazon.com/bedrock/latest/userguide/claude-messages-structured-outputs.html). |
| H7 | `Aws::Bedrock::Client#create_model_invocation_job` existe en `aws-sdk-bedrock` 1.65.0. Batch Converse está anunciado desde 2026-02-27. | Gem + [what's new](https://aws.amazon.com/about-aws/whats-new/2026/02/amazon-bedrock-batch-inference-supports-converse-api-format/). |
| H8 | El estado cabe en 2048 bytes. Un slot nuevo compite con `identifiers`. | `ActiveEpisode::MAX_BYTES`, `shrink_to_budget!`. |
| H9 | `common_noun?` es la única frontera componente/identidad para un complemento de una palabra junto a un modelo nuevo. | `TechnicalReferentResolver#identity_complement?` / `#common_noun?`. |
| H10 | `generation.txt` casi no guarda estado conversacional. Achicarlo no paga el Haiku previo. | Lectura de `app/prompts/bedrock/generation.txt` (152 líneas). Las reglas de episodio viven en Ruby. |
| H11 | La telemetría de interacción guarda un solo `latency_ms` total. No hay p50/p95 persistidos ni fases. | `RagController#emit_interaction_completed` → `PilotUsageLog`. |
| H12 | No hay k6, vegeta ni wrk en el repo. Sí hay runners de benchmark RAG. | `script/rag_quality_benchmark.rb`, `script/rag_seguridades_benchmark.rb`. |

## 3. Auditoría de uso actual de Haiku

Modelo de query configurado:

```text
BedrockClient::QUERY_MODEL_ID
  ENV BEDROCK_MODEL_ID
  || credentials :bedrock, :model_id
  || global.anthropic.claude-haiku-4-5-20251001-v1:0
```

Región de cliente: `AWS_REGION` || credentials || `us-east-1` (`config/initializers/bedrock.rb`). Deploy de ejemplo: `us-east-1` y el mismo model id global.

Precios ya codificados en `BedrockQuery::BEDROCK_PRICING`, por 1 000 tokens:

| model id | input | output |
|---|---|---|
| `global.anthropic.claude-haiku-4-5-20251001-v1:0` | 0.001 USD | 0.005 USD |
| `us.anthropic.claude-haiku-4-5-20251001-v1:0` | 0.0011 USD | 0.0055 USD |
| `claude-haiku-4-5-20251001-direct` (API Anthropic, ingesta) | 0.001 USD | 0.005 USD |

Esos números son $1 / $5 por millón en el perfil global, y el perfil `us.` lleva el +10% ya documentado en el repo. El experimento debe leer `pricing_for(QUERY_MODEL_ID)` en runtime. No hardcodear otro precio.

### Camino de la pregunta técnica (web)

| file | method | model | input | output | cuándo | vs Retrieve | sync |
|---|---|---|---|---|---|---|---|
| `app/controllers/rag_controller.rb` | `ask` | ninguno | texto del técnico | `episode_turn` persistido | siempre que hay pregunta | antes | sync, Ruby |
| `app/services/rag/active_episode_turn.rb` | `call` | ninguno | turno + episodio | decisión + `composed` | flag de episodio on | antes | sync |
| `app/services/query_orchestrator_service.rb` | `classify_query_intent` | Haiku vía `AiProvider` → `BedrockClient#generate_text` → `invoke_model` | prompt de tool name | `DATABASE_QUERY` / `KNOWLEDGE_BASE_QUERY` / `HYBRID_QUERY` | solo si `QUERY_ROUTING_ENABLED=true` y la cuenta tiene `data_sources` con `"db"` | antes de Retrieve | sync |
| `app/services/query_orchestrator_service.rb` | `synthesize_hybrid_answer` | mismo Haiku | dos respuestas ya generadas | prosa unificada | solo `HYBRID_QUERY` | después | sync, segunda inferencia |
| `app/services/bedrock_rag_service.rb` | `query` | mismo Haiku, `retrieve_and_generate` | pregunta + prompt + chunks | respuesta citada | camino generativo de manual | el Retrieve va dentro de la misma API | sync |
| `app/services/bedrock_rag_service.rb` | `document_identity_scope_result` | Retrieve, y si hay labels un `invoke_model` del mismo Haiku | chunks etiquetados + `generation.txt` | respuesta | flag `DOCUMENT_IDENTITY_SCOPE_ENABLED` y episodio con manufacturer o model conocido, y el scope etiquetó chunks | Retrieve primero; si el InvokeModel falla, cae a `retrieve_and_generate` | sync |
| `app/services/rag/structured_evidence_route.rb` | `execute` | Haiku vía `AiProvider` en el tramo generativo | evidencia ya recuperada | respuesta cerrada | intent determinístico que matchea | después de Retrieve | sync |
| `app/services/rag/context_evidence_route.rb` | `execute` | igual | evidencia | respuesta | preguntas de contexto de procedimiento | después de Retrieve | sync |

`classify_query_intent` no se puede reutilizar. Está apagado en deploy, clasifica herramienta (KB vs SQL), corre después de que el episodio ya se persistió, y su salida no es un referente. Encenderlo para este experimento cambiaría routing de cuentas con base de datos.

`retrieve_and_generate` no se puede reutilizar. Es la generación. Ve chunks y `generation.txt`. Pedirle además el JSON de la query mezcla el contrato de citas con el análisis y no evita el Retrieve.

### Fuera del camino de la pregunta

| file | method | model | cuándo | nota |
|---|---|---|---|---|
| `app/services/page_relevance_filter.rb` | filtro de página | `claude-haiku-4-5-20251001` vía API Anthropic directa | ingesta, página ambigua | no es Bedrock; no está en el request del técnico |
| `app/services/claude_chunking_client.rb` | parseo | Sonnet/Opus directos | ingesta | |
| `app/services/claude_batch_client.rb` | Message Batches de Anthropic | Sonnet/Opus | ingesta masiva | no es Bedrock Batch Inference |
| `app/services/field_photo_analysis_service.rb` | visión | modelo de foto, async | foto | otro request |
| `app/services/sql_generation_service.rb` | SQL | Haiku vía `AiProvider` | solo si el router eligió DB | apagado por default |

**Conclusión:** `SemanticQueryAnalyzer` agrega una inferencia nueva en el camino crítico. No hay una llamada previa al Retrieve que ya entienda referente, quiebre semántico o ambigüedad.

## 4. Opciones de arquitectura

### Candidata principal

```text
User turn
   |
   v
SemanticQueryAnalyzer (Haiku, Converse)
   |
   v
QueryAnalysis          # request-scoped, inmutable
   |
   +-------------------------+
   |                         |
   v                         v
ActiveEpisodeTurn      QueryOrchestrator
valida y persiste      en el experimento NO cambia retrieval
   |
   v
effective query (composed v4, o el texto crudo)
   |
   v
RAG existente
```

Haiku propone. Ruby decide. El orquestador recibe el mismo objeto para un uso posterior de routing. En P0–P4 ese objeto no altera `top_k`, filtros ni rerank.

### Opciones de secuencia

| | Secuencia | Consistencia | Latencia | Una clasificación | Fallo |
|---|---|---|---|---|---|
| A | analizar → `record_user_turn!(analysis:)` → orquestador | un UPDATE, el estado ya vio el análisis | el Haiku está en el camino, antes del Retrieve | sí, el objeto viaja al orquestador | timeout: el turno sigue con v4 y `analysis=nil` |
| B | persistir v4 → analizar → segundo UPDATE | dos writes; un retry puede pisar el episodio | igual de bloqueante, más queries | el orquestador puede no ver el análisis si lee antes del segundo write | el segundo write es otro punto de fallo |
| C | analizar en job después de responder | el usuario no espera | no mide el camino crítico | el orquestador de ese request no lo ve | útil solo para shadow de calidad, no para latencia |

**Recomendación: A para las variantes que pueden cambiar estado (conditional y always-on).** Un solo objeto `QueryAnalysis` por turno, creado antes de `record_user_turn!`, pasado a `ActiveEpisodeTurn` y al orquestador. Sin segundo UPDATE. Sin segunda clasificación.

Shadow (P1–P2) usa el mismo call site y el mismo timeout, y `ActiveEpisodeTurn` ignora el objeto. Así la latencia medida es la del camino real y la respuesta sigue siendo v4. Si el timeout vence, se loguea `analyzer_status=timeout` y el turno continúa. El analyzer no es punto único de falla.

No usar C como diseño de producción. Sí se puede usar un job solo si P1 muestra que el timeout propuesto no alcanza para no degradar al técnico; en ese caso shadow pasa a async y la latencia de camino se mide aparte, en el load test de P3.

## 5. Arquitectura experimental recomendada

1. PORO `Rag::SemanticQueryAnalyzer` junto a `BedrockClient`, no dentro del modelo.
2. Cliente: `Aws::BedrockRuntime::Client#converse` sobre `BedrockClient::QUERY_MODEL_ID`. Misma región que el resto (`us-east-1` en el deploy de ejemplo).
3. Contrato de salida: JSON schema chico. Ver sección 12 sobre el SDK.
4. `Rag::QueryAnalysis` es un `Data` inmutable. No escribe la base.
5. `ActiveEpisodeTurn` sigue siendo el único escritor de `active_episode`.
6. `TechnicalReferentResolver` y `common_noun?` siguen en el primer incremento. El analyzer corre al lado.
7. El orquestador acepta `query_analysis:` y no lo lee para routing hasta una fase explícita posterior a este plan.
8. Timeout duro en el cliente. Cero reintentos en el request. Un reintento duplica la latencia del técnico.
9. Temperature `0`. `maxTokens` 200. Sin chain-of-thought. Sin texto libre fuera del schema.

## 6. Contrato QueryAnalysis

Schema mínimo. Sin ontología. Sin confidence numérico.

```json
{
  "intent": "adjust_procedure",
  "query_kind": "procedural",
  "equipment": {
    "manufacturer": null,
    "model": null,
    "evidence": "unknown"
  },
  "referent": {
    "surface": null,
    "head": null,
    "modifier": null,
    "type": "unknown",
    "evidence": "unknown"
  },
  "semantic_break": false,
  "ambiguity": false
}
```

Enums cerrados:

```text
intent:      adjust_procedure | identity_fact | fault | other
query_kind:  procedural | identity | fault | other
type:        technical_component | equipment_identity | unknown
evidence:    explicit | semantic | unknown
```

`explicit` = el turno actual contiene el string. `semantic` = Haiku lo infiere del goal o de un fact guardado y el string no está en el turno. `unknown` = no afirma.

Campos que no entran: score, explicación, lista de candidatos, spans, embeddings, historial.

`intent` existe para no reanalizar la query en un routing futuro. En este experimento no cambia `RagRetrievalProfile`. Si P0 muestra que `intent` no discrimina nada que `query_kind` no discrimine, se elimina antes de P3.

Ruby descarta el objeto entero si falta una clave, si un enum es ajeno, o si `surface` / `head` / `modifier` / `model` / `manufacturer` no son substrings normalizados del turno actual o del goal guardado. Un nombre que no está en ese texto no se persiste. Eso impide que Haiku invente `MiniSpace` o `relé`.

## 7. Ownership de estado

Invariante: Haiku propone; `ActiveEpisodeTurn` dispone.

| Propuesta | Qué hace Ruby |
|---|---|
| `equipment.model` o `manufacturer` con `evidence=explicit` y el string está en el turno | Pasa por el extractor actual (`MODEL_VALUE_RE`, `MANUFACTURERS`). Si el extractor no lo acepta, no se persiste. Haiku no abre un segundo escritor de facts. |
| `equipment.evidence=semantic` | No se persiste. Un modelo heredado solo entra por el puente de identidad que v4 ya tiene. |
| `referent.type=technical_component`, `evidence=explicit`, head presente en el turno, sin modifier heredado | En shadow: solo log. En conditional/always, candidato a slot. No copia un complemento del goal por sí solo. |
| `referent.type=equipment_identity` | No se copia como objeto técnico. Si el turno además declara modelo, sigue el `context_break` actual cuando el resolver v4 ya lo marca. |
| `semantic_break=true` y el turno nombra un componente distinto del goal | `context_break` solo si v4 ya lo haría, o si en una fase posterior el golden set lo exige y el string del componente nuevo está en el turno. |
| `semantic_break=true` sin componente nuevo en el turno | Se ignora. Un quiebre sin evidencia en el texto no borra el goal. |
| `ambiguity=true` | No persiste referente. Mantiene el fallo cerrado de v4 (`rejected` o `context_break` según el resolver). |
| `type=unknown` o `evidence=unknown` | No persiste. El referente anterior, si existiera, no se renueva. |
| JSON inválido, timeout, 5xx, throttle | `analysis=nil`. Camino v4 completo. |

Prohibido:

```text
JSON de Haiku → update!(active_episode:)
```

### Slot de referente

`active_episode` hoy tiene facts `manufacturer`, `model`, `fault_code`. No tiene slot de componente. `goal.text` mezcla tarea, objeto y pregunta (`MAX_GOAL_CHARS = 300`). El historial sigue siendo transcript (`conversation_history`), con `correlation_id` y `ts`.

| Opción | Qué se guarda | Cuándo merece |
|---|---|---|
| 1. Referente completo (`surface`, `head`, `modifier`, `type`, `evidence`, `correlation_id`, `at`) | ~250–400 bytes encima de un episodio que ya recorta identifiers a 2048 | Solo si P0 muestra que el modifier heredado es estable y el budget aguanta |
| 2. `QueryAnalysis` solo en el request | Cero bytes de episodio | P0, P1, P2, y la variante shadow |
| 3. Subset mínimo | `head`, `type`, `evidence`, `correlation_id` | Primera persistencia, si P3 se aprueba |

**Recomendación para el experimento: opción 2 hasta cerrar P2. Opción 3 si P3 escribe estado.** `surface` se reconstruye del turno. `modifier` no se hereda desde Haiku: copiarlo es exactamente la contaminación que v4 cerró. `at` ya está en el fact pattern y puede esperar. Medir `JSON.generate(episode).bytesize` con el subset antes de subirlo; si `shrink_to_budget!` empieza a soltar identifiers, el slot no entra.

El resolver determinístico sigue decidiendo `resolved` / `rejected` / `context_break` / `not_applicable`. El slot no sustituye esa máquina en el primer incremento que persista.

## 8. `common_noun?` y heurísticas a jubilar

No se borran en el primer incremento.

Candidatas a retiro, solo si el desacuerdo medido lo justifica:

| Heurística | Función única | Archivo |
|---|---|---|
| `common_noun?` | una palabra de complemento, con modelo nuevo en el turno, ¿es pieza o nombre de equipo? | `technical_referent_resolver.rb` |
| `unreaffirmed_name?` | token con mayúscula no repetido en el turno = identidad | el mismo |
| `identity_complement?` | une el modelo nuevo con `common_noun?` | el mismo |

Se quedan, porque no clasifican componente vs equipo:

- ventana 4 h y últimos 3 turnos (`ConversationSession::EPISODE_WINDOW`, `EPISODE_MAX_USER_MESSAGES`);
- correlación única y provenance texto-goal == texto del antecedente;
- `identity_bridge?` (marca, código, designator, medición, “no lo sé”);
- coordinación (`y` / `o` de dos palabras de contenido);
- tope 442 caracteres (`FollowupQueryRewriter::MAX_COMPOSED_CHARS`);
- `pure_complement?` (solo cadena `de`/`del`; `en minispace` no se copia);
- acuerdo de número verbo/objeto.

Shadow compara, por correlation_id:

```text
ruby_status:     resolved | rejected | context_break | not_applicable
haiku_type:      technical_component | equipment_identity | unknown
disagreement:    none | ruby_resolved_haiku_identity | ruby_rejected_haiku_component |
                 ruby_break_haiku_same | schema_invalid | analyzer_failed
```

`ruby_resolved_haiku_identity` es el desacuerdo que más importa: v4 copió y Haiku dice que el complemento es identidad de equipo.

## 9. Shadow mode

Flag `shadow`. Haiku corre. `ActiveEpisodeTurn` no lee el resultado. La query efectiva es la de v4.

Log estructurado, un evento, sin el transcript completo y sin chunks:

```text
event=haiku_query_analysis_shadow
correlation_id
analyzer_status          ok | timeout | http_5xx | throttle | invalid_schema
ruby_status
ruby_composed_sha256     solo si composed cambió el texto; no el texto completo si supera 200 chars
goal_correlation_id
haiku_referent_type
haiku_evidence
haiku_semantic_break
haiku_ambiguity
disagreement
semantic_analysis_ms
haiku_input_tokens
haiku_output_tokens
haiku_cost_usd           pricing_for(QUERY_MODEL_ID)
```

El texto crudo del turno no va al log de aplicación si ya está en `conversation_history` bajo el mismo `correlation_id`. El evaluador offline une por ese id. No loguear fotos, tokens de sesión, ni el prompt completo.

## 10. Evaluación offline y batch

### Corpus

Armar un JSONL etiquetado a mano, chico, antes de cualquier batch:

| Fuente | Qué aporta |
|---|---|
| `test/services/rag/active_episode_turn_test.rb` | invariantes v4 ya congelados (anexo B, flows A/B, 442/443, coordinación, quiebre persistente, nombres de equipo) |
| probes nuevos, no como código de producción | `freno`, `relé`, `polea`, `eje`, `tubo`, `regulador`, `maxpro`, `nova`, `delta`, `mono`, `MiniSpace` |
| `script/fixtures/rag_quality_benchmark_corpus.json` y batteries de `test/services/rag/*qa_test.rb` | preguntas reales de manual, casi todas autocontenidas |
| logs de piloto | solo filas `interaction_completed` con `question_sha256`; el texto hay que reconstruirlo de sesiones autorizadas, no de un volcado ciego |

Clases de etiqueta, una por caso:

```text
SAFE_RESOLUTION     copiar el referente localizado es seguro
SAFE_REJECTION      no copiar es lo correcto
SEMANTIC_BREAK      el turno corta continuidad
IDENTITY_BRIDGE     marca, código, designator o medición mantiene el goal
UNKNOWN             fail-closed aceptable
CONTAMINATION       copiar sería inseguro
```

Métrica primaria: **tasa de contaminación semántica insegura**. Un caso `CONTAMINATION` que el sistema trata como `resolved` cuenta 1. Accuracy general no desempata.

Orden de lectura del reporte:

1. false-positive de arrastre semántico;
2. `semantic_break` incorrecto (borró un goal vigente, o no borró uno roto);
3. contaminación de identidad (modelo/marca heredados);
4. false-negative de referente (dejó de copiar un complemento seguro);
5. accuracy.

Fail-closed sigue ganando: un `SAFE_RESOLUTION` caído a `rejected` es peor que v4 en utilidad y mejor que una contaminación.

### Batch Bedrock (solo offline)

No usar batch en el request del técnico. El batch existente del repo es Anthropic Message Batches de ingesta (`ClaudeBatchClient`), otro producto.

Workflow:

```text
dataset JSONL local
  → JSONL Converse en S3
  → Aws::Bedrock::Client#create_model_invocation_job
  → S3 output
  → reporte local (no bulk_chunks/)
```

Input de cada línea (formato Converse, el que batch acepta desde 2026-02-27):

```json
{
  "recordId": "case-0042",
  "modelInput": {
    "system": [{ "text": "<analyzer system, el mismo de runtime>" }],
    "messages": [{ "role": "user", "content": [{ "text": "<turno + facts + goal, sin chunks>" }] }],
    "inferenceConfig": { "maxTokens": 200, "temperature": 0 }
  }
}
```

`recordId` es la correlación. El output de batch trae `recordId` + `modelOutput` o `error`. El reporte une por ese id. Líneas con error se reintentan en un segundo JSONL; no se reescribe el job entero.

Paths propuestos, fuera de `bulk_chunks/`:

```text
s3://<bucket-de-eval>/haiku-query-analysis/<fecha>/input/requests.jsonl
s3://<bucket-de-eval>/haiku-query-analysis/<fecha>/output/
```

El bucket de knowledge base no sirve: un objeto bajo el prefijo de ingesta puede indexarse. Usar un prefijo de evaluación o el bucket que ya usan los artefactos de Gate 9, y confirmar que no es data source de la KB.

IAM mínimo del job role:

```text
bedrock:CreateModelInvocationJob
bedrock:GetModelInvocationJob
bedrock:InvokeModel          sobre el inference profile y el foundation model
s3:PutObject                 en el prefijo input
s3:GetObject, s3:ListBucket  en input y output
```

`modelId`: el mismo `QUERY_MODEL_ID` global. Verificar en P0 que batch en `us-east-1` acepta el perfil `global.`. Si el job rechaza el perfil, parar y escalar; no cambiar el modelo de producción.

Costo: Bedrock batch suele ser 50% del on-demand en modelos soportados. **Eso hay que confirmarlo en la página de precios vigente para Haiku 4.5 global antes de lanzar el job.** Hasta confirmarlo, presupuestar on-demand.

Reanudación: `client_request_token` estable por hash del JSONL. Si el job está `InProgress` o `Submitted`, no crear otro. Guardar `job_arn` en un archivo local al lado del reporte.

Presupuesto de P0, propuesta a validar: un solo job, corpus ≤ 300 casos, tope de gasto 2 USD on-demand. Si el corpus crece, se para y se pide otro tope.

## 11. Variantes online

| | Qué corre | Qué cambia la respuesta |
|---|---|---|
| A baseline | v4. Cero Haiku previo. | nada; es `dce25d0` |
| B always-on | analyzer en todo turno de texto con pregunta, antes de `record_user_turn!` | en P4, solo si el exit de P3 se cumplió; hasta entonces el objeto se loguea y v4 responde |
| C conditional | analyzer solo si el gate determinístico marca ambigüedad | igual: no cambia respuesta hasta el exit de la fase anterior |

Gate condicional, candidatos leídos del resolver, **no reglas finales**. Se congelan después de ver los desacuerdos de P0:

- `identity_complement?` es true o está a un `common_noun?` de serlo (modelo nuevo + un solo token de complemento);
- `pure_complement?` es false y el goal sí tiene complemento `de`/`del`;
- `technical_nps` devuelve más de un sintagma;
- `expand` rechaza porque el sintagma actual ya trae modifier.

No llamar a Haiku en `not_applicable` (el turno no es `ajust*`) dentro de la variante C. Esos turnos siguen el compose legado y son la mayoría del tráfico de manual.

La variante B existe para medir el sobrecosto de llamar siempre. No es el default de rollout.

## 12. Structured output y el SDK

API disponible para Haiku 4.5: `outputConfig.textFormat.type = json_schema` en `converse` y en `invoke_model`. Documentación AWS, GA 2026-02-04. El perfil global está en la lista pública de perfiles que lo soportan.

SDK del repo: `aws-sdk-bedrockruntime` **1.63.0**. Tiene `converse` y `tool_config`. No tiene `output_config`. Un hash desconocido lo rechaza el cliente antes de llegar a AWS.

Prerrequisito de implementación, fase propia, antes de P1:

1. Subir `aws-sdk-bedrockruntime` a una versión que modele `output_config`.
2. Test de contrato: el client acepta el parámetro. Sin llamada de red en la suite.
3. Si el bump arrastra `aws-sdk-core` y rompe otros clientes, parar. Fallback de implementación: `tool_config` con `tool_choice` forzado al tool `query_analysis`, que 1.63.0 ya modela. Es peor (un tool-call envuelve el JSON y suma tokens) y solo se usa si el bump no es viable.
4. No parsear JSON “a mano” desde prosa como camino principal. Si el schema falla, es `invalid_schema` y cae a v4.

Temperature 0. `maxTokens` 200. Target de salida **< 150 tokens**. Medir en P0; si la mediana pasa de 150, achicar el schema antes de seguir.

## 13. Prompt del analyzer

System, fijo, cacheable si más adelante se mide que vale la pena. User, por turno:

```text
current_turn
goal.text            solo si hay goal no truncado, mismo correlation guardado
goal_correlation_id
facts                manufacturer, model, fault_code: status + value, sin historial
referent_slot        solo si la opción 3 ya existe; si no, omitir
```

No enviar: transcript, últimos mensajes que no sean el goal, chunks, `generation.txt`, corpus, fotos, session_id de Bedrock.

El system dice: devolver solo el schema; no inventar un string que no esté en `current_turn` o en `goal.text`; `equipment_identity` incluye nombres de modelo o producto aunque parezcan sustantivos; `technical_component` es una pieza o función (freno, relé, polea, eje) aunque el manual no la liste; si hay duda, `unknown` y `ambiguity=true`.

Esos ejemplos del system son ilustración para el modelo. No se copian a una lista Ruby.

Tope de input, propuesta a medir: 800 tokens. Si P0 pasa de eso, cortar `goal.text` al mismo `MAX_GOAL_CHARS` (300) que ya persiste el episodio.

## 14. Reducción del prompt de generación (P5, no ahora)

`generation.txt` no es el guardián del estado conversacional. Clasificación:

| Bloque | Líneas aprox. | Si QueryAnalysis funciona |
|---|---|---|
| Rol, idioma, tono | 1–14 | se queda; es formato para el técnico |
| Evidence contract, STRICT/GROUNDED, topología, LED, glosario NO/NC | 16–100 | **se queda**. Seguridad técnica y evidencia |
| Document identity, sibling model, versión | 82–106 | **se queda**. Es contaminación de evidencia, no de diálogo |
| Response selection, stop-work, no match, format | 108–151 | **se queda** en P5 salvo medición que muestre un párrafo redundante con el estado |

Lo que sí podría achicarse, en otra fase y con números, es el `session_context` que `SessionContextBuilder` inyecta, no el archivo de prompt. P5 compara:

```text
prompt actual + session_context actual
vs
prompt actual + session_context recortado a facts + referent validado
```

Medir tokens de input de `retrieve_and_generate` antes y después, con el mismo set de preguntas. Si el ahorro no cubre el costo del analyzer (sección 16), P5 no se hace. No editar `generation.txt` en este experimento.

## 15. Fallos

| Fallo | Comportamiento |
|---|---|
| timeout del cliente | `analysis=nil`, v4, log `timeout`. Sin retry. |
| 5xx, `ServiceUnavailable`, red | igual |
| throttling | igual. No hacer backoff dentro del request. |
| JSON que no cumple el schema o enums | igual, `invalid_schema` |
| Haiku propone un string ausente del turno y del goal | Ruby tira el objeto, log `rejected_span`. Cuenta como fallo de analyzer, no como estado. |
| Bedrock caído del todo | el turno de RAG ya falla hoy en `BedrockRagService`. El analyzer no agrega un modo degradado distinto: la pregunta sigue y falla donde ya falla. |

Excepción: no hay. Ni siquiera un `semantic_break` de Haiku se aplica si el objeto es inválido.

Timeout propuesto, a calibrar en P1 con p95 real: **800 ms**. Si el p95 de Haiku en P0 batch no predice la cola online, el load test de P3 fija el número antes de pilot shadow. Hasta medirlo, 800 ms es una propuesta, no un SLO.

## 16. Costo

Por request experimental, en el log de la sección 9 más los campos que `BedrockQuery` ya guarda para la generación:

```text
haiku_input_tokens
haiku_output_tokens
haiku_cost                 pricing_for(QUERY_MODEL_ID)
generation_input_tokens    fila bedrock_queries de ese correlation_id
generation_output_tokens
generation_cost
total_llm_cost
```

`retrieve_and_generate` hoy a menudo estima tokens (`token_source=estimated`). El reporte debe separar estimado vs contado y no presentar el estimado como factura. El analyzer, al ser `converse`/`invoke_model`, sí devuelve `usage`. Ese número es contado.

### Modelo de costo (hipótesis, no medición)

Precios del perfil global ya en el repo. Hipótesis de tamaño, a reemplazar por la mediana de P0:

```text
input  600 tokens × 0.001 / 1000 = 0.00060 USD
output 120 tokens × 0.005 / 1000 = 0.00060 USD
por análisis always-on             = 0.00120 USD
```

| tráfico | always-on / día | always-on / mes (30 d) |
|---|---|---|
| 100 queries | 0.12 USD | 3.60 USD |
| 1 000 | 1.20 USD | 36 USD |
| 10 000 | 12 USD | 360 USD |

Conditional = always-on × fracción de turnos que disparan el gate. Esa fracción no se inventa: P0 la cuenta sobre el corpus; P2 la cuenta sobre el piloto. Si la fracción es 10%, los números de arriba bajan un orden.

Batch, si el 50% se confirma: la evaluación de 300 casos sale ~0.18 USD con la hipótesis de arriba. El tope de 2 USD deja margen.

Estos cuadros se rehacen con tokens reales al cerrar P0. No son umbral de salida.

## 17. Latencia e instrumentación

Hoy:

```text
RagController started_at → interaction_completed.latency_ms   (total)
BedrockRagService log "retrieve_and_generate Nms"            (string, no percentil)
StructuredEvidenceRoute retrieval_ms + generation_ms         (solo esa ruta)
```

Agregar al mismo `PilotUsageLog` de `interaction_completed`, sin tabla nueva:

```text
semantic_analysis_ms   0 en baseline
episode_ms             record_user_turn!
orchestrator_ms        hasta el return del orquestador, menos retrieval y generation si se pueden separar
retrieval_ms           solo donde la ruta ya lo mide (structured, context, document identity)
generation_ms          bedrock_latency_ms del retrieve_and_generate, o el invoke_model de identidad
total_ms               el latency_ms actual
```

En `retrieve_and_generate` retrieval y generation son una sola API. No inventar un `retrieval_ms` ahí. Reportar `rag_ms` para esa ruta y reservar el split para las rutas que ya llaman `retrieve` aparte.

Reportar p50, p95, p99 y, donde la API sea stream, TTFT. `retrieve_and_generate` en el código actual no es stream (`retrieve_and_generate_with_retry` espera el body). TTFT de esa ruta es el mismo número que `rag_ms` hasta que exista stream. Medir TTFT solo del `converse` del analyzer si se usa `converse_stream`; con `converse` bloqueante, `semantic_analysis_ms` es el número.

Comparar A/B/C sobre el mismo set, no con promedios sueltos de días distintos.

Presupuesto de overhead, **propuesta**: p95 de `semantic_analysis_ms` ≤ 800 ms y p95 de `total_ms` ≤ p95 baseline + 800 ms en la variante que se quiera encender. Se confirma o se baja después del load test. No es un SLO de producto todavía.

## 18. Load test

No hay herramienta de carga en el repo. No agregar k6 como dependencia para este experimento.

Runner mínimo, hermano de `script/rag_quality_benchmark.rb`: N workers, cada uno llama el mismo entrypoint que el benchmark (orquestador o el concern, con Bedrock real), mezcla fija, concurrencia 1, 5, 10, 20.

Mezcla por oleada de 20:

```text
8  autocontenidas (not_applicable para el resolver)
4  elipsis segura ya cubierta por tests (resortes de la fijación)
2  puente de identidad (Fuji Yida, código, “no lo sé”)
4  complemento ambiguo (modelo nuevo + una palabra: freno, maxpro, nova, MiniSpace)
2  quiebre (componente explícito distinto)
```

Medir: tasa de error, throttling (`ThrottlingException` / 429), p95 de `semantic_analysis_ms`, p95 de `total_ms`.

Parar la oleada si throttling > 1% o si aparecen 5xx. El piloto no necesita 20 concurrentes para decidir; 20 es el techo del experimento, no un objetivo de capacidad.

Correr contra una cuenta de eval, no contra la KB de producción si el entorno de benchmark ya tiene una separación. Si no la tiene, el runner usa la misma KB que `rag_quality_benchmark.rb` y se declara así en el reporte.

## 19. Evaluación de calidad

La suite v4 permanece verde en todas las fases. Haiku no puede reabrir:

- modelo heredado después de una declaración explícita;
- coordinación pegada como un solo objeto;
- override de componente explícito;
- antecedente sin provenance (texto distinto al goal);
- ventana de últimos 3 y de 4 h;
- correlación ausente, duplicada o nula;
- expansión de 442 caracteres aceptada y de 443 rechazada sin truncar;
- corrección de marca con precedencia sobre la expansión;
- quiebre persistente (el goal viejo no vuelve en el turno siguiente).

Esos casos ya están en `active_episode_turn_test.rb`. La fase que conecte Haiku al estado agrega un test por cada uno con el analyzer stubbeado en el sentido que tentaría a romper el invariante (por ejemplo `semantic_break=false` cuando el turno es un componente nuevo). El stub no puede ganar.

Probes de golden, etiquetados en el JSONL, no hardcodeados en el resolver:

```text
freno relé polea eje tubo regulador
maxpro nova delta mono MiniSpace
```

Cada probe va en dos contextos mínimos: (1) turno con modelo nuevo explícito y complemento de una palabra; (2) elipsis `cómo se ajustan` sin modelo nuevo. La etiqueta humana dice `CONTAMINATION` o `SAFE_RESOLUTION` antes de ver la salida de Haiku.

Gate de seguridad del experimento, independiente del accuracy:

```text
unsafe_contamination = 0
```

sobre el golden etiquetado. Un solo caso `CONTAMINATION` resuelto como copia falla la fase.

## 20. Feature flags

Un solo enum. Combinaciones de tres booleanos (`ENABLED` + `SHADOW` + `CONDITIONAL`) permiten estados inválidos.

```text
HAIKU_QUERY_ANALYSIS_MODE=off|shadow|conditional|always
```

Default: `off`. Cualquier otro string es `off` y se loguea una vez.

| modo | llama Haiku | escribe estado distinto de v4 | cambia la query al RAG |
|---|---|---|---|
| off | no | no | no |
| shadow | sí, todo turno de texto | no | no |
| conditional | sí, solo gate | solo a partir de P3, y solo lo que la sección 7 permite | no en este plan |
| always | sí, todo turno de texto | igual que conditional | no en este plan |

`FIELD_COMPANION_EPISODE_ENABLED` sigue siendo el interruptor del episodio. Con el episodio apagado, el modo Haiku también queda en `off`: no hay estado que analizar contra un goal.

Patrón de código: un PORO `Rag::HaikuQueryAnalysisFlag` como `FieldCompanionEpisodeFlag`, testeado, sin leer el ENV en el medio del turno más de una vez.

## 21. Rollout y criterios de salida

No hay avance automático. Cada fase actualiza la tabla de estado de este archivo.

| Fase | Qué | Exit para abrir la siguiente |
|---|---|---|
| P0 | Corpus etiquetado + un job batch. Cero cambio de runtime. | `unsafe_contamination=0` en los casos que v4 ya resuelve bien. En el subset ambiguo (complemento de una palabra junto a modelo nuevo), Haiku acierta más casos `SAFE_RESOLUTION`+`CONTAMINATION` que `common_noun?`, sin ningún `CONTAMINATION` nuevo. Tokens medidos reemplazan la hipótesis de la sección 16. |
| P1 | Modo `shadow` en local, timeout puesto, v4 intacto. | Suite v4 verde. 100% de los fallos de analyzer caen a v4 en test (timeout, schema, string inventado). p95 local anotado. |
| P2 | `shadow` en el piloto, flag por entorno. | ≥ 200 turnos de texto o 14 días, lo que pase último. Contaminación insegura observada en el log = 0. Fracción de `disagreement` publicada. Costo/día real ≤ el cuadro rehecho en P0 para ese tráfico, con margen 2×. |
| P3 | `conditional` en piloto, todavía sin cambiar retrieval. El estado solo se aparta de v4 en el subset ambiguo, con la política de la sección 7. | Golden v4 sigue en 0 contaminaciones. p95 `total_ms` dentro del presupuesto de la sección 17 ya calibrado por el load test. Throttling de la oleada 10 concurrentes ≤ 1%. Fallback probado con el cliente stubbeado en producción vía un caso de test, no vía apagar AWS. |
| P4 | `always` solo como A/B de costo, misma política de estado que P3. | El costo incremental vs conditional no compra una baja medible de false-negatives en el subset ambiguo. Si no la compra, se vuelve a conditional y always queda descartado. |
| P5 | Recorte de `session_context`, no de `generation.txt`, solo si P3 o P4 quedó encendido. | Input tokens de generación bajan lo suficiente para cubrir ≥ el 50% del costo del analyzer en el mismo set. Si no, se revierte el recorte. |

Umbrales marcados como propuesta hasta tener la medición de P0/P3:

- timeout 800 ms;
- p95 agregado ≤ baseline + 800 ms;
- tope P0 de 2 USD;
- margen 2× sobre el costo/día modelado;
- 200 turnos o 14 días en P2.

`unsafe_contamination=0` no es propuesta. Es el gate.

## 22. Fases de implementación (cuando se autorice)

Ninguna de estas fases se ejecuta con este documento.

### P0 — sin runtime

| Archivo | Cambio |
|---|---|
| `script/fixtures/haiku_query_analysis_corpus.jsonl` | casos etiquetados, incluidos los probes |
| `script/haiku_query_analysis_batch.rb` | arma el JSONL Converse, sube a S3, crea el job, baja el output, escribe el reporte |
| `test/scripts/haiku_query_analysis_batch_test.rb` | formato de línea, `recordId`, resume por token, no toca `bulk_chunks/` |
| este documento | fila P0 de la tabla de estado, con job arn y hash del corpus |

### Prerrequisito SDK — antes de P1

| Archivo | Cambio |
|---|---|
| `Gemfile.lock` | bump de `aws-sdk-bedrockruntime` con `output_config` |
| `test/services/rag/semantic_query_analyzer_test.rb` | el client fake recibe `output_config` o, si el bump fracasa, `tool_config` |

### P1 — shadow local

| Archivo | Cambio |
|---|---|
| `app/services/rag/haiku_query_analysis_flag.rb` | enum `off/shadow/conditional/always` |
| `app/services/rag/query_analysis.rb` | `Data` + validación de spans y enums |
| `app/services/rag/semantic_query_analyzer.rb` | `converse`, timeout, sin retry, costo vía `pricing_for` |
| `app/services/bedrock_client.rb` | método `converse_json` o cliente dedicado; no reutilizar `generate_text` (temperature 0.7, max 2000, prosa) |
| `app/controllers/rag_controller.rb` | en `shadow`/`always`, llamar analyzer antes de `record_user_turn!` y pasar el objeto; el turno lo ignora |
| `app/controllers/concerns/rag_query_concern.rb` | aceptar `query_analysis:` y no usarlo para la query efectiva |
| tests de flag, schema inválido, timeout, string inventado, y un test de que `composed` no cambia en `shadow` |

### P3 — conditional, estado

| Archivo | Cambio |
|---|---|
| `app/services/rag/technical_referent_resolver.rb` | exponer el gate de ambigüedad sin borrar `common_noun?` |
| `app/services/rag/active_episode_turn.rb` | aplicar la tabla de la sección 7 solo en `conditional`/`always` |
| `app/services/rag/active_episode.rb` | slot mínimo de la opción 3, con sanitize y budget |
| tests v4 existentes | siguen igual con el flag `off` |
| tests nuevos | cada invariante de la sección 19 con analyzer hostil stubbeado |

`QueryOrchestratorService` no cambia de ruta en este plan. Recibe el objeto y lo ignora, para no analizar dos veces cuando una fase futura lo use.

## 23. Test plan (de la implementación futura)

- Flag: `off` default; string basura = `off`; episodio apagado fuerza `off`.
- Analyzer: schema válido; enum ajeno; span que no está en el turno ni en el goal; timeout; 5xx; throttle; usage → costo con el precio global del repo.
- Shadow: `record_user_turn!` produce el mismo `composed` y el mismo `active_episode` que v4, con analyzer devolviendo `equipment_identity` sobre un caso que v4 resuelve.
- Conditional apagado en `not_applicable`.
- 442 se acepta, 443 se rechaza, con analyzer pidiendo copiar igual.
- Corrección de marca gana a un `semantic_break=false`.
- Quiebre persistente: el turno siguiente no recupera el goal viejo aunque Haiku diga `semantic_break=false`.
- Suite actual de los tres archivos del baseline, más la suite de prompt (`test/prompts/bedrock_generation_prompt_test.rb`) para probar que P0–P4 no tocan `generation.txt`.
- Cero llamadas de red en tests. Client inyectado.

## 24. Riesgos

| Riesgo | Por qué importa | Mitigación en el plan |
|---|---|---|
| El analyzer agrega latencia fija a cada pregunta | el camino ya espera `retrieve_and_generate` | conditional; timeout; P4 solo si compra calidad |
| Haiku “resuelve” dudas copiando | es la contaminación que v4 cerró | Ruby exige el string en el turno o en el goal; gate de 0 contaminaciones |
| SDK sin `output_config` | la primera implementación puede parecer lista y no serializar el parámetro | bump explícito antes de P1 |
| Batch rechaza el inference profile `global.` | el corpus no se evalúa barato | parar P0; no cambiar `BEDROCK_MODEL_ID` |
| 2048 bytes | el slot empuja identifiers fuera | opción 2 hasta medir; opción 3 mínima |
| Ahorro de prompt inexistente | `generation.txt` no guarda el diálogo | P5 mira `session_context` y se cancela si no paga |
| Shadow síncrono degrada el piloto | aunque no cambie la respuesta, el timeout largo sí | 800 ms propuesto; si no entra, shadow pasa a job y la latencia se mide en el load test |
| Dos clasificaciones | costo doble | un objeto por turno, pasado al orquestador, no releído por un segundo Haiku |

## 25. Fuera de alcance

- LangGraph, agents, graph memory, memoria vectorial de diálogo, framework externo de estados.
- Ontología de componentes.
- Cambiar embeddings, `top_k`, reranker, `ContextProjection`, `DocumentIdentityScope`, modelo de generación.
- Borrar `common_noun?` en el primer incremento.
- Encender `QUERY_ROUTING_ENABLED` para reutilizar `classify_query_intent`.
- Batch en el request interactivo.
- Editar `generation.txt` en P0–P4.
- Tabla nueva.
- Commit de los scripts `patch_elemont_*` o del plan de piloto dentro de este trabajo.

## Estado

| Fase | Estado | Artefacto |
|---|---|---|
| Baseline v4 | cerrado | `dce25d080aaba1779898339206d7ec297bdbd3e7` en `main` |
| Branch experimental | abierto, sin código de analyzer | `experiment/haiku-semantic-query-analysis` |
| P0 batch | no empezado | — |
| P1 shadow local | no empezado | — |
| P2 pilot shadow | no empezado | — |
| P3 conditional | no empezado | — |
| P4 always-on A/B | no empezado | — |
| P5 prompt/context reduction | no empezado | — |

## Protocolo

1. Actualizar la fila de Estado al cerrar una fase.
2. Corregir el exit de la fase siguiente si la medición contradice un número marcado como propuesta.
3. `unsafe_contamination=0` no se relaja por accuracy ni por costo.
4. Si un hallazgo pide LangGraph, una tabla nueva, o un rewriter general, no se implementa: se anota y se escala.
