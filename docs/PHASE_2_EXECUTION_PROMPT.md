# Phase 2 execution prompt

You are implementing Phase 2 only of

```text
docs/REAL_GONZALO_AUDIT_IMPLEMENTATION_MASTER_PLAN_2026-09-26.md
```

That file is the authority. The Opus-refined Phase 2 section (2A–2E) is the contract. Do not write an alternate plan. Do not implement Phase 3.

## Current repo state

Phase 1 is committed. Live field-photo vision is `claude-sonnet-5` (`BatchChunkingPrompt::MODEL_TEXT`, Anthropic direct). Ingestion multimodal is `claude-opus-5-5` (`BatchChunkingPrompt::MODEL_MULTIMODAL`). Both ids come from the pre-plan upgrade `9c34751add7dbf45d27e23256ee733c0467af29b`, which is not a phase. Do not change either model. RAG generation model was not changed in Phase 1 and must stay unchanged in Phase 2.

Frozen, already green, do not reopen:

```text
HYBRID_MINIMAL
HAIKU_QUERY_ANALYSIS_MODE=conditional
semantic ownership: switch / correct only
baseline: 14 flows, 29 turns, 14/14 PASS
unsafe_contamination=0
HTTP 5xx=0
ARCHITECTURE_CHANGE_REQUIRED=NO
ENTITY_PROJECTION_REQUIRED=NO
HUMAN_VALIDATION_REQUIRED=NO
```

Do not introduce a new RAG, a new semantic engine, Entity Projection, a new model class, or an extra model call.

## What Phase 1 actually shipped

Do not reopen any of this.

Semantic visual cache is gone. `FieldPhotoDiagnosisCache` and its test are deleted. Nothing reads or writes a `photo_dx` key. `FieldPhotoPrompt::CONTRACT_VERSION` is gone. `git grep -nE "FieldPhotoDiagnosisCache|FieldPhotoPrompt::CONTRACT_VERSION|photo_dx" -- app lib script test config` must stay empty.

One fresh vision call per photo, including an identical reupload and a `field_photo_id` re-ask. `QueryOrchestratorService#execute` always writes the pending image token and enqueues `WarmBedrockKbJob` when the query is present. `existing_photo_id` remains storage dedupe. S3 original and the `FieldPhoto` row remain.

Intent is deterministic. No intent LLM.

```text
Rag::PhotoIntent.resolve(question:, episode_state:, history:, now:)
  → nil or { "text" => String, "source" => "question"|"history"|"goal" }
Rag::PhotoIntent.visual_target?
```

Precedence: explicit question (no lexicon), else newest visual user message inside the episode window, else a visual goal, else nil. Stems: `resorte fijacion cable terminal amarre polea puerta cabina botonera placa tarjeta contactor freno motor limitador spring rope sheave door board brake`. Meta offers ("si te doy otra imagen…", "puedo enviarte otra foto", "te paso otra imagen") are non-visual. There is no `meta_photo_offer?`. Resolution runs in `FieldPhotoAnalysisJob#perform` before `record_photo_observation!` and `record_assistant_turn!`, on the full `conversation_history`.

The intent is appended only by `FieldPhotoPrompt.user_content(..., photo_intent:)` as one live-photo text block. `SYSTEM_BLOCKS` is byte-identical. Fingerprint `4f62491874c8fea82d78632657e9adc93da80c69e40157eee98b5cfe972715d1`. `FieldPhotoPrompt::INGESTION_CONTRACT_VERSION` is `field_photo_records_v3`. `BatchChunkingPrompt::INGESTION_CONTRACT_VERSION` is `field_records_v8`. Ingestion callers do not pass `photo_intent`. Do not reingest.

`FieldPhotoAnalysisService` copies `target_visible` (`true`/`false` only, else nil), `relevance_to_goal` (`relevant`|`unrelated`|`uncertain`, else nil), and `missing_view_or_detail` (≤ 200) only when an intent was sent. Missing or invalid `target_visible` is nil and `Rag::PhotoIntentRenderer.prose` renders it as uncertain. The renderer runs only for a blank question that had an intent. An explicit question with `target_visible == false` adds `PhotoQuestionAnswerService#hidden_target_line` inside the evidence block. `EVIDENCE_BLOCK_MAX_CHARS` is 1100. `brand_component_mismatch?` is unchanged.

`photo_completed` / `photo_submitted` / `photo_failed` carry no `cache_status`. `PilotMetricsReport` was not edited.

Tests and fixture added in Phase 1:

```text
test/services/rag/photo_intent_test.rb
test/services/rag/photo_intent_renderer_test.rb
test/services/rag/real_gonzalo_photo_continuity_test.rb
test/fixtures/real_gonzalo/photo_81515_episode.json
```

The continuity replay stubs `ClaudeChunkingClient#call`. It proves the spring sentence reaches vision and the meta goal does not. It does not prove vision accuracy.

## Rejected in Phase 1 — do not revive them in Phase 2

```text
semantic visual cache, versioned cache, short TTL
intent vs cached summary, no-overlap → target_visible=false
canonical_name overlap, visible_codes overlap
second vision call, verification pass, semantic photo classifier
intent model, model-based reconciliation
SYSTEM_BLOCKS edit, contract bump, reingestion
```

## Known limits Phase 2 must leave alone

A blank photo of a non-lexicon subject after a non-visual turn can inherit an older visual target. The renderer still appends the standalone reading. An explicit question is not lexicon-checked. Prompt-contract tests prove the text reaches the model, not that the model obeys it. Vision accuracy is observability, not a gate. Leftover `photo_dx` entries expire in 24 h; do not add an invalidation script. `PHOTO_DIAGNOSIS_CACHE_TTL_HOURS` stays for Future Phase 4.

## Phase 2 — implement exactly this

Minimal deterministic LCE reset, one unit-bearing value guard, grounded prompt lines, BL6 citation dedupe, the safe "no encontré" sentence, Field Companion tone, and the mechanical allow/deny line. No new model call. No `Retrieve` in tests. Do not create `EvidenceProvenance` or `RetrievalOutcome`.

### 2A. Scope reset

In `ActiveEpisodeTurn#call`, immediately after:

```ruby
owned = apply_owned_slice(current)
return owned if owned
```

and before the brand rules:

```ruby
return open_episode(:new_episode, current, goal: :always) if disjoint_catalog_equipment?(current)
```

`disjoint_catalog_equipment?` is true only when all hold:

* `FollowupQueryRewriter.explicit_question?(@text)` and `@words.size >= 6`
* not `FOLLOWUP_START_RE` on `@normalized` and not `correction?`
* the episode has equipment identity: a known `model` fact or non-empty user `identifiers`
* some token from `@text.scan(KbDocumentResolver::TOKEN_RE)` passes `KbDocumentResolver.specific_token?` and `catalog_identity_for(token)` returns a non-ambiguous `{"model" => m}`
* `m` (case-insensitive) is not the episode model, not in its identifiers, and not in `episode.goal["text"]`

Do not edit `FOLLOWUP_RE`. The deictic marker does not block the reset. Owned `switch`/`correct` still return first. A failed or `continue` perception does not block the guard. Short turns ("y en el LCE?") keep today's path.

Acceptance: `test/services/rag/lce_scope_replay_test.rb`. Catalog setup follows `test/services/rag/haiku_ownership_slice_test.rb` (~343): `Rag::DocumentIdentityCatalog.with_catalog(...)` with rows copied from `config/document_identities.yml` (LCE, LCB II, CMC-3) plus matching `KbDocument` records. Replay `query:0a790d21` accented and unaccented → `:new_episode`; effective text and the resulting episode identity contain neither `LCB II` nor `CMC-3`. `catalog_identity_for("LCE")` returns `{"model" => "LCE", …}`. "¿dónde está el fusible F1 de la placa?" on the LCB II episode does not reset. "¿Qué reviso primero?" on the spring episode stays `continued_elliptical` and composes `fijación de cables`. "esta polea tractora, ¿cómo se ajusta?" keeps its current result. Do not edit `script/fixtures/production_conversational_baseline_v2.json`. The SSH production replay is post-deploy, not a gate.

### 2B. Unit-bearing unsupported-value guard

`Rag::SourceFidelityGuard.call(answer:, evidence_texts:, allowed_texts:, locale:)` → `{ answer:, removed: Integer }`.

* Pairs from `AnswerSafetyProcessor::EVIDENCE_SENSITIVE_VALUE_PATTERN` units plus `%`, `N·m`, `Nm`, `vueltas`, `turns`. Normalize comma to dot, unit upcased, `N·M` → `NM`, `VDC`/`VAC`/`VCC`/`VCA` → `V`.
* Supported when the pair occurs in `evidence_texts` (chunk bodies for this answer) or `allowed_texts` (raw question, effective question, and the `## Photo Evidence (this turn)` block only).
* Each unsupported pair removes its list item or else its sentence. If `removed > 0`, append `rag.unsupported_value_removed` once and log `source_fidelity_guard`.
* Empty `evidence_texts` → no-op, log `skipped: no_evidence`.
* One call site: `RagQueryConcern#execute_rag_query`, on `result[:answer]` before `sanitize_answer` (today at the assignment just above `RagResult.new`). Do not re-run `AnswerSafetyProcessor`.
* If `BedrockRagService#query` result builders or `StructuredEvidenceRoute` omit chunk bodies from `retrieved_citations`, add the already-retrieved body. No new retrieve.

Tests use stored strings. LCB II: `24 V` removed, `30 V` and `F1 4 A` kept. Fuji/KONE: `5 %`, `3 mm`, `C = 20 mm` kept. Photo nameplate `380 V` kept. `24 V` only in prior assistant history removed. Deterministic route unchanged. "los resortes se ven de largo distinto" kept; "apriete a 30 N·m" without a chunk removed. `rag_query_concern_test` asserts the guard runs once, before `sanitize_answer`, and that generation routes expose chunk bodies.

### 2C–2E. Grounded prompt, citations, "no encontré", tone, mechanical line

`app/prompts/bedrock/generation.txt`, grounded lines under `GROUNDED_SYNTHESIS:` (strict lines stay as they are):

* voice: a manual sentence says so ("Según el manual …"); a field check that is inference says so ("Como verificación de campo …")
* precondition: keep the source's power state; a powered step is never placed before energizing; copy numbers exactly
* internal note: cite the named manual and page; when the job's equipment is not confirmed, say the value is from another manufacturer and does not transfer
* filename: names the file; it is not evidence of the page's manufacturer or model
* sibling rule (~82–87): remove the `STRICT_ONLY:` prefix so both templates carry it
* tone: open with what the technician can check or do next; then what the manual states, what is inference, what is unconfirmed; at most one next measurement or photo; never open with "La documentación recuperada" or "No encontré"; prose for a phone, no mandatory headings
* mechanical allow-list, as observation, never as a manual step: asimetría, posición relativa, roscas, tuercas, resortes, holgura visible, corrosión, deformación, hardware faltante o suelto, comparación visual, herramienta obvia por la forma del elemento. Still forbidden unless the chunks contain it: torque, número de vueltas, tensión objetivo, tolerancias, setpoints, bypasses, any value with a unit, undocumented critical procedures

`Bedrock::CitationProcessor#build_numbered_references`: drop a later number whose `title` equals an earlier one and rewrite its `[n]` markers to the earlier number. BL6 same title+page → one entry.

`rag.data_not_available` es: "Ese dato no aparece en los fragmentos de manual recuperados para esta consulta." en: "That information is not in the manual excerpts retrieved for this question." `DATA_NOT_AVAILABLE` stays the internal marker. `EvidenceSelectionTelemetry::ABSTENTION_PATTERN` adds `no\ aparece\ en\ los\ fragmentos` and `not\ in\ the\ manual\ excerpts`; keep the old alternatives. Update tests that assert the old sentence in the same commit.

## Leave for Phase 3

Semantic `BedrockQuery` accounting, `photo_completed` cache-token cost, and `TurnEvidence`. Do not enqueue `TrackBedrockQueryJob` from `SemanticQueryAnalyzer`. Do not add a `semantic_analysis` enum value.

## Validation

```text
bin/rails test \
  test/services/rag/active_episode_turn_test.rb \
  test/services/rag/lce_scope_replay_test.rb \
  test/services/rag/source_fidelity_guard_test.rb \
  test/controllers/concerns/rag_query_concern_test.rb \
  test/prompts/bedrock_generation_prompt_test.rb \
  test/services/bedrock/citation_processor_test.rb \
  test/services/rag/evidence_selection_telemetry_test.rb \
  test/services/rag/answer_safety_processor_test.rb \
  test/scripts/production_conversational_baseline_v2_test.rb \
  test/scripts/production_conversational_baseline_v2_verdict_test.rb
bin/rails test
git diff --exit-code -- script/fixtures/production_conversational_baseline_v2.json
bin/rubocop <changed .rb files>
```

Use `BUNDLE_PATH=vendor/bundle` if the shell's `BUNDLE_PATH` points at an empty sandbox cache.

Allowed statuses: `PASS`, `FAIL`, `PLAN_BLOCKER`. On FAIL, fix inside Phase 2 and rerun. No commit while FAIL. No Phase 3.

On PASS: append `## PHASE_2_VALIDATION_RESULT` to the master plan, replace `PHASE_3_PROMPT_SEED` with `PHASE_3_EXECUTION_PROMPT` from the real Phase 2 result, and commit exactly once:

```text
Keep equipment scope and source values faithful.
```

Do not deploy.
