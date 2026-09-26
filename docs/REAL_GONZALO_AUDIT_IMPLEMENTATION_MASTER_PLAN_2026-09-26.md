# Real Gonzalo audit — master implementation plan

Date: 2026-09-26
Status: PLAN ONLY. Single authoritative plan. No implementation, deploy, or commit in the sessions that wrote or reviewed this file.
Source audit: `docs/REAL_GONZALO_PRODUCTION_FLOW_AUDIT_2026-09-25.md`
Trace: `tmp/pilot_exports/2026-09-25_2026-09-25_danebo-pilot-elevator/` (account 3, user 7, session 6). Not committed. Replay fixtures are extracted from it by the phase that needs them.
Review: adversarial review 2026-09-26 (Opus) applied in place. Material changes carry an `OPUS_REFINEMENT_2026-09-26` note.

```text
ARCHITECTURE_CHANGE_REQUIRED=NO
ENTITY_PROJECTION_REQUIRED=NO
NEW_MODEL_CALL_TYPE=NONE
HUMAN_VALIDATION_REQUIRED=NO
OPEN_QUESTIONS=NONE
PLAN_BLOCKERS=NONE
```

Frozen and not reopened:

```text
HYBRID_MINIMAL
HAIKU_QUERY_ANALYSIS_MODE=conditional
semantic ownership = switch/correct only
baseline shape = 14 flows / 29 turns / 14-14 PASS
unsafe_contamination=0
HTTP 5xx=0
```

No second RAG, no second semantic engine, no Entity Projection, no new model id, no new call type. The only call-count change in this plan is described in `MODEL_CALL_POLICY`.

---

## MASTER_BASELINE

Production image in the export manifest: `87014be40c6c6784818ca6aa6da4b3864fcd5dd0`.

Approved conversational closure, unchanged by this plan:

| Invariant | Where it lives |
|---|---|
| One text-RAG path | `RagQueryConcern#execute_rag_query` → `QueryOrchestratorService#execute` |
| Photo is async vision, then RAG only when `question.present?` | `FieldPhotoAnalysisJob#deliver` |
| Semantic Haiku owns only `switch` and `correct` | `ActiveEpisodeTurn#apply_owned_slice` / `HaikuQueryAnalysisFlag.conditional?` |
| `continue` / elliptical composition stays deterministic | `ActiveEpisodeTurn#call` after the owned slice returns nil |
| Generation contract | `app/prompts/bedrock/generation.txt`, filtered by `BedrockRagService.load_generation_prompt_template(grounded_synthesis:)` (`STRICT_ONLY:` / `GROUNDED_SYNTHESIS:` line prefixes) |
| Paid rows | `BedrockQuery` via `TrackBedrockQueryJob` |
| Internal `Retrieve` stays off `bedrock_queries` | `PilotMetricsReport#internal_calls` |
| Field photos never enter the KB | `ACTIVE_ARCHITECTURE.md`: bytes and thumbnail go to S3 (`FieldPhotoStore`, bounded by `FIELD_PHOTO_RETENTION_DAYS`) for zoom and re-ask only |
| Document/diagram image ingestion is a separate path | `FieldPhotoPrompt::SYSTEM_BLOCKS` is shared with `BulkCostV2RequestBuilder` and `SingleFileChunkingService`; `FieldPhotoPrompt.prompt_fingerprint_sha256` is written into ingested chunk metadata by `BatchResultsParserService#contract_metadata` |

Order inside `ActiveEpisodeTurn#call` (verified): `apply_pending_override` → `skip_reason` → `reset_explicit?` → blank-episode open → `apply_owned_slice` → brand rules → `technical_referent` → `elliptical?` → `continued_self_contained`.

Evening flow replayed by this plan (session 6, America/Santiago). All user turns 20:22–20:40 are episode `ep_271dcb5597b17c32`; 40bb opens `ep_f25bcabc94505155`.

| correlation_id | decision | composed_chars | note |
|---|---|---|---|
| `photo:3a46c587-…` (17:36) | — | — | **vision miss** → `Transformador trifásico con bornes`; question "como se ajustan los resortes en la imagen ?" was never sent to vision |
| `photo:6c9f66d9-…` (17:51) | — | — | same bytes (`46de1a09cb75`), cache hit, new question |
| `photo:e9cea10e-…` (20:22) | `continued_self_contained` | nil | same bytes, cache hit, question "Cómo se ajustan los resortes de la fijación de cables"; RAG ran on the 17:36 reading |
| `query:e4d5899b-…` | `continued_elliptical` | 63 | goal + `Fuji Yida` |
| `query:b1020088-…` (20:25:50) | `continued_self_contained` | nil | raw "la poregunat que te hice , Cómo se ajustan los resortes de la fijación de cables" |
| `query:d7d98115-…` (20:35:32) | `continued_self_contained` | nil | goal replaced by "si te doy otra imagen , te ayuidaria a orientarme?" |
| `photo:81515bf6-…` (20:38) | no user-turn row | — | blank question; vision miss; no RAG |
| `query:40bb1a77-…` | `new_episode` | nil | CMC-3 |
| `query:406f82ce-…` | `continued_self_contained` | nil | LCB II; goal + identifiers |
| `query:0a790d21-…` | `continued_elliptical` | **154** | LCB II goal + `CMC-3` + LCE question |

`composed_chars: 154` is `ActiveEpisodeTurn#compose_text` output (goal, identity items not already present, then the turn):

```text
¿Cómo se hace la puesta en servicio de la placa LCB II y qué se verifica antes de energizar?
CMC-3
¿Qué hace la tarjeta LCE y dónde está su configuración?
```

Semantic call count matches the code: `record_user_turn!` runs `observe_ownership` whenever the question is present, including `photo:e9cea…`. The blank photo does not. 15 text turns + 1 photo-with-question = 16 paid Haiku `converse` calls. `SemanticQueryAnalyzer#call` only writes `haiku_query_analysis_shadow`; no `BedrockQuery`. Those lines are absent from `source_events.jsonl` because the exporter keeps `[PILOT_USAGE]`, `[PILOT_AUDIT]`, `[RAG_QUALITY]` only.

```text
semantic:  22896 * 0.001/1000 + 1719 * 0.005/1000 = 0.031491
           (BedrockQuery::BEDROCK_PRICING['global.anthropic.claude-haiku-4-5-20251001-v1:0'], no cache tokens)
vision:    1430/1000 * 0.003 + 360/1000 * 0.015 + 1172/1000 * 0.00375 = 0.014085   (BedrockQuery row, provider prompt-cache write included)
           photo_completed.cost = 0.00969  (input + output only)
```

---

## VISUAL_CACHE_DECISION

OPUS_REFINEMENT_2026-09-26: **REMOVE the semantic visual cache (`FieldPhotoDiagnosisCache`) in Phase 1.** Every live field photo gets exactly one fresh, intent-aware vision call. The previous "keep `photo_dx/v2`, never bump `CONTRACT_VERSION`, deterministic lexical overlap on stale hits" design is withdrawn.

### Evidence that changed the decision

1. The transformer reading is **not** an old development artifact. Account 3 / user 7 / session 6 uploaded the same bytes (`46de1a09cb75`) three times on 2026-09-25: 17:36 **miss** (Sonnet produced "Transformador trifásico con bornes" fresh), 17:51 hit, 20:22 hit. The cache is account-scoped with a 24 h TTL (`PHOTO_DIAGNOSIS_CACHE_TTL_HOURS` default; not overridden in repo config).
2. Each upload carried a **different question** about springs. Vision is question-blind (`FieldPhotoPrompt.user_content` sends image + filename + locale only). The cache then pinned that question-blind misread for 24 h and made every later spring question reuse it.
3. Phase 1 makes vision output depend on an input (photo intent) that a `sha256`-only key cannot represent. Any key without the intent returns a reading produced for another question; any key with the intent has a hit rate near zero.
4. The observed "hit rate" (2 hits / 4 uploads that day) is one technician re-sending one gallery file with new questions — exactly the case where reuse is most wrong.

### Mandatory questions

| # | question | decision |
|---|---|---|
| 1 | Does a persistent semantic visual cache make sense for Field Companion? | No. The reading is an answer to "what does this image show *for what I'm asking now*". It is not a pure function of the bytes. |
| 2 | Expected field hit rate? | Fresh camera captures: ~0 % identical bytes. Gallery re-sends: 0–10 % of uploads, and every one of them arrives with a new question or goal. |
| 3 | Do savings justify complexity/risk? | No. See table: ≤ US$1.41 per 1,000 photos at 10 % duplication. The cost of a stale or question-blind reading is a wrong field answer. |
| 4 | Transformer: structural or bad historical entry? | Structural. Vision misread once (model error, not fixable here). Two structural defects amplified it: question-blind vision and question-blind reuse. Removing the cache and sending the intent fixes both. Whether Sonnet then reads the springs correctly is not asserted by any gate. |
| 5 | Invalidate all existing caches? | No action. After the Phase 1 deploy nothing reads `photo_dx/*`. Entries expire within 24 h (`expires_in`). No script, no migration. |
| 6 | Bump `CONTRACT_VERSION`? | No bump: **delete** `FieldPhotoPrompt::CONTRACT_VERSION`. Its only consumers are the cache key and the cache payload. |
| 7 | Keep v2 as an invariant? | Withdrawn. The invariant is now: `FieldPhotoPrompt::SYSTEM_BLOCKS` and `INGESTION_CONTRACT_VERSION` are unchanged, so `prompt_fingerprint_sha256` and document/diagram ingestion are unchanged. |
| 8 | Cached diagnosis and new intent differ? | The case no longer exists. Every photo turn gets a reading produced with its own intent. |
| 9 | Remove no-overlap → `target_visible=false`? | Removed. No lexical overlap anywhere in Phase 1. A missing or invalid `target_visible` renders as **uncertain**, never false. |
| 10 | Can Phase 1 be simplified by removing the cache? | Yes. It deletes the intent fingerprint (`prompt_fingerprint_sha256` is kept), the optional cache keys, the hit/miss branch matrix, `deliver_cached`, and the deterministic overlap renderer. |

### Options compared

| option | correctness | debuggability | complexity | realistic hit rate | stale risk | prompt/model evolution | telemetry |
|---|---|---|---|---|---|---|---|
| KEEP CURRENT | question-blind reuse (the audited defect) | hit hides which prompt produced the reading | current | 0–10 % | 24 h | every prompt change needs a bump or serves stale | hit/miss + avoided cost |
| INVALIDATE + KEEP | fixes one entry, the next misread is cached again | same | same | same | same | same | same |
| VERSIONED (intent in key) | correct | fine | key + fingerprint + schema drift | ~0 % | low | bump per change | noisy |
| SHORT TTL ONLY | still question-blind inside the window | same as keep | same | lower | minutes | same | same |
| IDEMPOTENCY/RETRY ONLY | correct | fine | new key by correlation | 0 %: `retry_on … attempts: 1` never retries, each submit gets a new correlation id | none | none | extra |
| **REMOVE** | **correct** | **one `visual_query` row per reading** | **net code deletion** | n/a | **none** | **free** | **simplest** |

Kept on purpose (not semantic reuse):

* `FieldPhoto` durable row + S3 bytes, deduped by `sha256` (zoom and re-ask by `field_photo_id`; `QueryOrchestratorService` → job rehydrates from S3).
* Anthropic prompt caching of the static `SYSTEM_BLOCKS` (`cache_control: ephemeral`). A token discount on the same call, not a reused answer.
* Conversation context: `record_photo_observation!` + compact context in history. A text follow-up about the same photo never needs vision again.

### Savings a cache could have bought (US$0.014085 per avoided call, order of magnitude)

| images \ duplicated | 1 % | 5 % | 10 % | 25 % | 50 % |
|---|---|---|---|---|---|
| 100 | 0.01 | 0.07 | 0.14 | 0.35 | 0.70 |
| 1,000 | 0.14 | 0.70 | 1.41 | 3.52 | 7.04 |
| 10,000 | 1.41 | 7.04 | 14.09 | 35.21 | 70.43 |

Latency trade, accepted: an identical re-upload now waits one vision call (~9–10 s, `original_latency_ms: 9748` in the export) instead of 0 s. New photos are unaffected. `WarmBedrockKbJob` overlaps that wait as it already does on a miss.

### MODEL_CALL_POLICY

```text
new photo (any)                      : 1 vision call        (unchanged)
identical bytes re-uploaded < 24 h   : 1 vision call        (was 0; +1 by design, ≈ US$0.010–0.014)
re-ask by field_photo_id             : 1 vision call        (was 0 inside 24 h; rehydrates from S3)
blank photo                          : 1 vision, 0 semantic, 0 generation  (unchanged)
photo + question                     : 1 vision + existing semantic + existing generation (unchanged)
text turn                            : unchanged
new call types / new models          : none
```

`MODEL_CALL_DELTA=0` in this plan means: no new call type and no extra call on any turn except the two identical-bytes re-reads above (re-upload and re-ask by `field_photo_id`).

---

## ISSUE_MATRIX

| issue | production evidence | root cause in this repo | phase | fix | automatic acceptance |
|---|---|---|---|---|---|
| Question-blind vision + question-blind reuse (first photo) | `photo:3a46…` miss → transformer; `6c9f…`, `e9cea…` hits with new spring questions | `FieldPhotoPrompt.user_content` has no question/intent; `FieldPhotoDiagnosisCache` key is account + sha + locale + `CONTRACT_VERSION` | 1 | Remove the cache. Send the explicit question as photo intent on the same vision call. | job test: same sha twice → vision called twice, second user content includes the new question |
| Blank second photo ignores the spring target | `photo:81515bf6-…`, no `photo_question_answered` | `FieldPhotoAnalysisJob#deliver` calls RAG only when `question.present?`; `FieldPhotoAnalysisService` never receives the episode; `RagController#ask` skips `record_user_turn!` on blank | 1 | Resolve a bounded photo intent from the episode/history; pass it to the same vision call; render its structured verdict | `RealGonzaloPhotoContinuityTest` |
| Stored goal at that photo is the meta sentence | `query:d7d98115-…` `episode_fields_changed: ["goal"]` | `continued_self_contained` replaces the goal; the spring sentence stays in `conversation_history` (`MAX_HISTORY = 20`); `recent_user_turns` keeps 3 (`EPISODE_MAX_USER_MESSAGES`) | 1 | Walk history newest-first inside the episode, take the first visual-target message; goal is the fallback | replay asserts intent text contains `resortes` and not `otra imagen` |
| Photo turn with explicit question must stay on RAG | `photo:e9cea…` | working path | 1 | RAG unchanged; evidence block gains one line only when vision says the asked target is not visible | `photo_question_answer_service_test` |
| First-photo component mismatch (springs asked, other thing read) | `e9cea…` answer trusted the transformer | vision never judged the asked target | 1 | `target_visible` from the same vision call feeds the evidence block. OPUS_REFINEMENT_2026-09-26: replaces the Phase 2E lexical canonical-name overlap line. | same test |
| Standalone photo must stay standalone | no/expired episode | `ActiveEpisode.parse` blanks after `EPISODE_WINDOW = 4.hours` | 1 | nil intent → today's prose and today's user content | job test |
| Shared vision system prompt with KB ingestion | `bulk_cost_v2_request_builder.rb`, `single_file_chunking_service.rb`, `batch_results_parser_service.rb#contract_metadata` | `FieldPhotoPrompt::SYSTEM_BLOCKS` and its fingerprint belong to ingestion too | 1 | OPUS_REFINEMENT_2026-09-26: the intent contract lives only in the live-photo **user content**; `SYSTEM_BLOCKS` byte-identical | fingerprint literal test |
| LCE retrieves LCB II | `query:0a790d21-…`, composed 154 | `FOLLOWUP_RE` has `\besta\b` and runs on accent-folded `@normalized`, so "dónde está" is a follow-up marker → `elliptical?` → `compose_text` pastes goal + `CMC-3`. The episode also keeps CMC-3/LCB II identity, which `DocumentIdentityScope` can use as needles and cut LCE chunks to `REFERENCE ONLY — OTHER EQUIPMENT` | 2A | Deterministic disjoint-catalog-designator reset after the owned slice. OPUS_REFINEMENT_2026-09-26: no accent-preserving change (field typing drops accents: "donde esta" must reset too) | `lce_scope_replay_test` for accented and unaccented spellings |
| Same-equipment follow-ups must still compose | `active_episode_turn_test.rb` ("¿Qué reviso primero?", "esta polea tractora") | — | 2A | reset needs a catalog designator disjoint from the episode | existing tests stay green |
| CMC-3 mixes manual facts and inference | `query:40bb1a77-…` | GS layer rules exist (generation.txt ~124) but no visible voice distinction | 2B | one `GROUNDED_SYNTHESIS:` voice rule | prompt contract test |
| LCB II rewrites 30 V → 24 V | `query:406f82ce-…` | no deterministic value check exists (`EVIDENCE_SENSITIVE_VALUE_PATTERN` only decides whether a citation is needed) | 2B | `Rag::SourceFidelityGuard`: unit-bearing values must occur in retrieved evidence | guard test on the captured answer |
| LCB II self-test placed "before energizing" | same | generation reorder | 2B | one `GROUNDED_SYNTHESIS:` precondition rule. OPUS_REFINEMENT_2026-09-26: no ordering heuristic in code (fragile NLP, false positives) | prompt contract test |
| LG-Sigma filename attribution | `query:a673ccc8-…`; audit: the answer's caution was **correct** | DOCUMENT IDENTITY (generation.txt ~102–106) lets filename resolve document identity; no rule asserts a manufacturer from it | 2B | regression only: one clause that a filename names the file, not the page's manufacturer/model | prompt contract test |
| Fuji 5 % / KONE 3 mm / KONE C=20 mm | `query:242729f2-…`, `query:b1020088-…` | content correct; citation is the internal note, not the original pages; job identity unknown so `DocumentIdentityScope.applicable?` is false | 2B | one GS rule: an internal note that names its source manual/page is cited with that source and a non-transfer sentence when the job's equipment is unconfirmed | prompt contract test; guard keeps 5 %, 3 mm, 20 mm (present in chunks) |
| MPK 708A called main controller from a 708C chunk | `query:4243acf2-…` | sibling-model rule (generation.txt ~82–87) is `STRICT_ONLY:`; grounded answers never see it | 2B | promote the sibling rule to both branches | prompt contract test on both templates |
| Duplicate BL6 citations | `query:628d9abd-…` | `Bedrock::CitationProcessor#build_numbered_references` never dedupes by title+page | 2B | collapse same title+page to the first number and rewrite the later marker | `citation_processor_test` |
| "No encontré" reads as corpus absence | `rag.es.yml` `data_not_available` | one global sentence for every top-k miss | 2C | scope-local sentence; extend `ABSTENTION_PATTERN`. OPUS_REFINEMENT_2026-09-26: no `RetrievalOutcome` class — top-k retrieval can never prove corpus absence, so there is one honest sentence | locale + telemetry tests |
| Companion voice is a document search | answers open "La documentación recuperada…" | grounded template does not forbid it | 2D | one GS tone block | prompt contract test |
| Safe mechanical observation vs invented specs | first photo; generation.txt GS line ~21 forbids invented torque/tool sizes | allow-list not explicit; no value enforcement | 2E | GS allow-list line; `SourceFidelityGuard` enforces values | guard + prompt tests |
| Unrelated manuals after the first photo | `query:72eda72a-…` | downstream of the misread plus open retrieval | 1 + 2B | fresh intent-aware reading (1); layer rules (2B). No ranker, no `top_k` change | no new retrieval stage in the diff |
| 16 semantic calls missing from cost | aggregate USD 0.031491 | `SemanticQueryAnalyzer` calls `converse` directly; `BedrockClient#track_usage` is only on `generate_text` | 3 | one `TrackBedrockQueryJob` per paid `converse`, including `hallucinated_spans`/`invalid_schema`; new source `semantic_analysis` | accounting tests |
| Vision prompt-cache tokens missing from `photo_completed.cost` | 0.014085 vs 0.00969 | `FieldPhotoAnalysisService#usage_payload` drops cache tokens | 3 | carry cache tokens so `photo_completed.cost == BedrockQuery#cost`; never insert a second vision row | job test: 0.014085 |
| Turns missing question/answer/chunks | a891, 2ee, a673, blank photo | `PilotAuditLog.log` only on RAG generation paths | 3 | one `[TURN_EVIDENCE]` line per correlation on every route; costs only from `BedrockQuery` | builder tests |
| Export says 16 audited answers vs 14 `audit` objects | audit limitation | counting mismatch | 3 | `turn_evidence` is the per-turn record; old headline not redefined | builder test |

Residual, explicitly not a work item:

* Sonnet's first misread. No new model. Phase 1 guarantees a fresh, intent-aware reading and an honest `target_visible` rendering, not a correct identification.
* Live KB retrieve of the five LCE chunks. Acceptance is the effective query and episode state plus `config/document_identities.yml` (`KONE LCE 813131 …`, `designators: [LCE]`). No production `Retrieve`.
* `PilotMetricsReport` photo-cache fields and `METRICS.md` photo-cache section → FUTURE_PHASE_4 (`MIGRATION_COMPATIBILITY`: historical exports still contain hit events).

---

## CROSS_PHASE_INVARIANTS

```text
NEW_MODEL_CALL_TYPE=NONE
MODEL_CALL_POLICY=as in VISUAL_CACHE_DECISION
HYBRID_MINIMAL_UNCHANGED=YES
SEMANTIC_OWNERSHIP_UNCHANGED=YES
ENTITY_PROJECTION=NO
ARCHITECTURE_DRIFT=NO
SEMANTIC_VISUAL_CACHE=REMOVED (after Phase 1)
```

* `HaikuQueryAnalysisFlag` modes stay `off | shadow | conditional | always`. Conditional still returns nil unless `relation` is `switch` or `correct`.
* Any new deterministic rule in `ActiveEpisodeTurn#call` runs after `apply_owned_slice` returns nil.
* `FollowupQueryRewriter` / `compose_text` still own elliptical composition for turns that do not name a disjoint catalog designator. `FOLLOWUP_RE` is unchanged.
* `DocumentIdentityScope` is unchanged. Phase 2 adds no label system and no retrieve.
* `FieldPhotoPrompt::SYSTEM_BLOCKS` and `FieldPhotoPrompt::INGESTION_CONTRACT_VERSION` are unchanged in every phase. `FieldPhotoPrompt.prompt_fingerprint_sha256` equals its pre-Phase-1 value.
* No code path reads or writes `photo_dx/*` after Phase 1. `FieldPhotoDiagnosisCache` and `FieldPhotoPrompt::CONTRACT_VERSION` do not exist.
* Photo intent is technician text only (explicit question, history user message, or episode goal). Never assistant prose, never `[FOTO]` compact context, never a previous vision reading.
* `bedrock_queries.source` gains exactly one value, `semantic_analysis`. `Retrieve`, warm pings, and deterministic routes still insert no row.
* `BedrockQuery` is the only cost authority. No log line is summed as cost.
* No WhatsApp branch. No new ENV flag. `script/fixtures/production_conversational_baseline_v2.json` is never edited.

---

## FILES_EXPECTED_TO_CHANGE_BY_PHASE

### Phase 1

| file | change |
|---|---|
| `app/services/field_photo_diagnosis_cache.rb` | **delete** |
| `test/services/field_photo_diagnosis_cache_test.rb` | **delete** |
| `app/prompts/field_photo_prompt.rb` | delete `CONTRACT_VERSION` and its comment; `user_content(…, photo_intent: nil)` appends the intent text block. `SYSTEM_BLOCKS` untouched. |
| `app/services/rag/photo_intent.rb` | new. `resolve` + `visual_target?` lexicon. |
| `app/services/rag/photo_intent_renderer.rb` | new. Relevance paragraph for blank-question photos. |
| `app/services/field_photo_analysis_service.rb` | `photo_intent:` keyword; pass to `user_content`; parse the three fields only when an intent was sent; compact context gains the visibility segment; `[IMAGE_ANALYSIS]` gains `intent_source`, `intent_sha256`, `target_visible`, `relevance_to_goal` |
| `app/jobs/field_photo_analysis_job.rb` | remove cache read/write, `deliver_cached`, `photo_cache_hit`, `visual_llm_call_avoided`, `photo_cache_miss`, `cache_status` fields; rename `diagnosis_cache_value` → `photo_value` (drop `created_at`, `contract_version`; add the three fields); resolve intent before vision; renderer on blank+intent |
| `app/services/query_orchestrator_service.rb` | remove cache read; always write the pending image token for uploaded bytes; `WarmBedrockKbJob` whenever `@query.present?`; `photo_submitted` without `cache_status` |
| `app/services/rag/photo_question_answer_service.rb` | one evidence-block line when `target_visible == false`; `EVIDENCE_BLOCK_MAX_CHARS` 900 → 1100 |
| `config/locales/rag.es.yml`, `config/locales/rag.en.yml` | `rag.photo_intent.*` |
| `script/grounded_synthesis_battery_2026-09.rb` | use `meta[:photo_value]` (drop the cache read; `photo_source = "preflight_v2"`) |
| `script/photo_question_regression_2026-09-15.rb`, `script/photo_question_regression_v2_2026-09-15.rb` | delete `FORCE_VISION` invalidation lines and their header comments (every call is fresh) |
| `docs/ACTIVE_ARCHITECTURE.md` | photo bullet: re-ask runs a fresh vision read from the retained bytes (no diagnosis cache) |
| `test/services/rag/photo_intent_test.rb` | new |
| `test/services/rag/photo_intent_renderer_test.rb` | new |
| `test/prompts/field_photo_prompt_test.rb` | intent block, no-intent identity, fingerprint literal |
| `test/services/field_photo_analysis_service_test.rb` | fields parsed only with intent |
| `test/jobs/field_photo_analysis_job_test.rb` | replace every cache test (see Tests) |
| `test/services/query_orchestrator_service_test.rb` | replace the two cache tests |
| `test/services/rag/photo_question_answer_service_test.rb` | hidden-target line |
| `test/fixtures/real_gonzalo/photo_81515_episode.json` | new |
| `test/services/rag/real_gonzalo_photo_continuity_test.rb` | new |

Not touched in Phase 1: `ActiveEpisodeTurn`, semantic ownership, `generation.txt`, `rag_chat_controller.js` (`photo_analyzed.summary` is already the broadcast string), `PilotMetricsReport`, ingestion services.

### Phase 2

| file | change |
|---|---|
| `app/services/rag/active_episode_turn.rb` | `disjoint_catalog_equipment?` + reset right after the owned slice |
| `app/services/rag/source_fidelity_guard.rb` | new. Unit-bearing value check. |
| `app/controllers/concerns/rag_query_concern.rb` | call the guard once on `result[:answer]` before `sanitize_answer` |
| `app/services/bedrock_rag_service.rb`, `app/services/rag/structured_evidence_route.rb` | only if a result builder lacks chunk body text in `retrieved_citations` |
| `app/prompts/bedrock/generation.txt` | GS voice, precondition, internal-note source, filename clause, tone block, observation allow-list; sibling rule prefix removed so it is shared |
| `app/services/bedrock/citation_processor.rb` | title+page dedupe in `build_numbered_references` |
| `app/services/rag/evidence_selection_telemetry.rb` | `ABSTENTION_PATTERN` gains the new sentences |
| `config/locales/rag.es.yml`, `config/locales/rag.en.yml` | `data_not_available` rewording; `rag.unsupported_value_removed` |
| tests and fixtures named in PHASE_2 | |

Not created: `EvidenceProvenance`, `RetrievalOutcome`. OPUS_REFINEMENT_2026-09-26: both duplicated existing seams (`DocumentIdentityScope` labels, one abstention sentence) and their tests could only test themselves, not the model.

### Phase 3

| file | change |
|---|---|
| `app/services/rag/semantic_query_analyzer.rb` | enqueue tracking inside `#call` |
| `app/services/rag/active_episode_turn.rb` | pass attribution into `observe_ownership` |
| `app/models/conversation_session.rb` | pass `user_id` / session id into the turn |
| `app/controllers/rag_controller.rb` | attribution into `observe` (shadow); `[TURN_EVIDENCE]` on text completion |
| `app/models/bedrock_query.rb` | enum value `semantic_analysis` |
| `app/services/llm_usage_channel.rb` | `semantic_analysis` → `:bedrock_semantic` |
| `app/services/simple_metrics_service.rb` | channel counted once in the Haiku rollup |
| `app/services/pilot_metrics_report.rb` | `semantic_llm_calls`; `turn_evidence` join by `correlation_id` |
| `app/services/field_photo_analysis_service.rb` | cache tokens in `usage_payload` |
| `app/jobs/field_photo_analysis_job.rb` | cost includes cache tokens; `[TURN_EVIDENCE]` on every photo outcome |
| `app/services/rag/turn_evidence.rb` | new. One hash per correlation, no cost fields. |
| tests named in PHASE_3 | |

No migration in any phase. `bedrock_queries.source` is a string column; the Rails enum is the constraint.

---

## PHASE_1 — multimodal continuity and cache removal

### Closed decisions

```text
CACHE=REMOVED
PHOTO_INTENT_SOURCE / PRECEDENCE / STALENESS
VISION_CONTRACT (user content only)
RENDERING
TESTS / REAL_FLOW_REPLAY
MODEL_CALL_POLICY as in VISUAL_CACHE_DECISION
```

#### CACHE_REMOVAL

* Delete `FieldPhotoDiagnosisCache` and its test.
* `FieldPhotoAnalysisJob#perform`: take the pending image; if nil and `field_photo_id` present, rehydrate from S3 (existing code, `photo_reuse` event kept); if still nil, `broadcast_expired` (existing). Then one vision call.
* `QueryOrchestratorService#execute` (uploaded image branch): always `FieldPhotoPendingImageStore.write`; `WarmBedrockKbJob.perform_later if @query.present?`; `existing_photo_id` lookup kept (storage dedupe).
* Delete `FieldPhotoPrompt::CONTRACT_VERSION`. Keep `INGESTION_CONTRACT_VERSION` and `prompt_fingerprint_sha256`.
* Telemetry: the job no longer emits `photo_cache_hit`, `visual_llm_call_avoided`, `photo_cache_miss`; `photo_submitted`, `photo_completed`, `photo_failed` carry no `cache_status`. `PilotMetricsReport` is untouched and reports 0 hits on new data while still parsing historical events.
* Gate: `git grep -nE "FieldPhotoDiagnosisCache|FieldPhotoPrompt::CONTRACT_VERSION|photo_dx" -- app lib script test config` prints nothing.

#### PHOTO_INTENT_SOURCE

`Rag::PhotoIntent.resolve(question:, episode_state:, history:, now:)` returns nil or `{ "text" => String, "source" => "question" | "history" | "goal" }`. `text` is squished and cut at `ActiveEpisode::MAX_GOAL_CHARS` (300).

1. `question.present?` → the question, source `question`. No lexicon check.
2. Else parse `ActiveEpisode.parse(episode_state, now:)`. Blank → nil.
3. Window start = later of `now - ConversationSession::EPISODE_WINDOW` and `episode.opened_at` (unparseable `opened_at` → window start only).
4. Walk `history` (`session.conversation_history`, full array, not `recent_user_turns`) newest-first; only `role == "user"` with a parseable `ts` inside the window; first message with `visual_target?` wins, source `history`.
5. Else `episode.goal["text"]` when `visual_target?`, source `goal`.
6. Else nil.

`visual_target?` = any stem after `I18n.transliterate(...).downcase` of a closed lexicon: `resorte, fijacion, cable, terminal, amarre, polea, puerta, cabina, botonera, placa, tarjeta, contactor, freno, motor, limitador, spring, rope, sheave, door, board, brake`. Not a brand list.

The walk skips non-visual turns (3998 "medidas de seguridad", d7d meta offer, 603c compatibility) and stops at the episode boundary, so a new episode never inherits an old target. OPUS_REFINEMENT_2026-09-26: the separate `meta_photo_offer?` predicate is removed — a meta offer is simply non-visual and is skipped by rule 4.

Resolution happens in the job **before** `record_photo_observation!` and `record_assistant_turn!`.

#### PHOTO_INTENT_PRECEDENCE

| question | intent sent to vision | RAG | broadcast |
|---|---|---|---|
| present | the question | `PhotoQuestionAnswerService`, as today | `photo_question_answered` |
| blank | resolved from episode/history | no | `photo_analyzed`, summary = `PhotoIntentRenderer.prose` |
| blank | nil | no | `photo_analyzed`, summary = today's `analysis` |

The intent is never concatenated onto the RAG query and never becomes a second question.

#### PHOTO_INTENT_STALENESS

* Blank or expired episode → nil (blank question) → standalone.
* History rows outside the window or before `episode.opened_at` are ignored.
* A newer visual-target message beats an older one.
* No second TTL, no new `PendingQuestion` type, no episode JSON shape change.

Accepted residual: inside one episode, a blank photo of a new non-lexicon component after a non-visual turn gets the older target. The renderer always appends the full standalone reading, so the technician still sees what the photo shows.

#### VISION_CONTRACT

`FieldPhotoPrompt.user_content(binary:, content_type:, filename:, locale: nil, photo_intent: nil)`. With nil it returns exactly `BatchChunkingPrompt.user_content(...)`. With an intent it appends one text block:

```text
Photo intent (the technician's own words, not evidence and not a manual):
<text>
Add three keys to the same JSON object:
"target_visible": true | false | null   — does this image show the part/assembly the technician is asking about?
"relevance_to_goal": "relevant" | "unrelated" | "uncertain"
"missing_view_or_detail": "<one short sentence in the summary language naming the view or detail still needed; empty string when the target is fully visible>"
Never take a manufacturer, model, code, or value from the intent. Do not answer the question, give a procedure, or state torque, turns, tension, or settings.
```

`SYSTEM_BLOCKS` is byte-identical. Ingestion callers never pass `photo_intent`.

`FieldPhotoAnalysisService.new(…, photo_intent: nil)`: when an intent was sent, copies `target_visible` (only `true`/`false`, anything else → nil), `relevance_to_goal` (only the three enum values, else nil), `missing_view_or_detail` (string, squished, ≤ 200 chars) onto the result. With no intent, all three are nil even if the model emits them. `build_analysis` stays the standalone reading. `build_compact_context` appends ` | Objetivo visible: sí|no|sin confirmar` only when an intent was sent. The service logs `intent_source`, `intent_sha256`, `target_visible`, `relevance_to_goal` in `[IMAGE_ANALYSIS]` (never the intent text).

#### RENDERING

`Rag::PhotoIntentRenderer.prose(reading:, locale:)`, used only for blank question + intent. Branches on `target_visible` only:

| `target_visible` | first paragraph |
|---|---|
| `false` | `rag.photo_intent.target_hidden` with `%{missing}`, or `rag.photo_intent.target_hidden_default` (close-up of that assembly + nameplate) when missing is blank |
| `true` | `rag.photo_intent.target_visible`, then `missing` as its own sentence when present |
| nil / invalid | `rag.photo_intent.target_uncertain`, then `missing` or the default close-up request |

Then `"\n\n"` and the unchanged `reading[:analysis]`. Must not start with "La documentación recuperada" or "No encontré". No citations. `relevance_to_goal` is logged and not rendered.

Explicit question: `PhotoQuestionAnswerService#photo_evidence_block` adds, after the header, only when `target_visible == false`:

```text
- Vision judged that this photo does not show what the question asks about (<missing_view_or_detail>). Say that first, then answer; do not treat the photographed component as the asked one.
```

`EVIDENCE_BLOCK_MAX_CHARS` becomes 1100 so the mismatch line, this line, and the Condition line all survive. `brand_component_mismatch?` is unchanged.

### Tests

| test | assertion |
|---|---|
| intent: question present | source `question`, text = question |
| intent: d7d meta goal, b102 in history | source `history`; text contains `resortes`; not `otra imagen` |
| intent: only 3 newest messages passed | nil (documents why the job passes full history) |
| intent: expired / blank episode, blank question | nil |
| intent: message before `episode.opened_at` | ignored |
| intent: newer visual target | newer wins |
| intent: no history match, visual goal | source `goal` |
| renderer: false + missing | hidden sentence + missing + standalone analysis; no `No encontré` |
| renderer: false + blank missing | default close-up sentence |
| renderer: nil / "maybe" | uncertain sentence; never the hidden sentence |
| prompt: no intent | equals `BatchChunkingPrompt.user_content` output; no `Photo intent` |
| prompt: intent | last text block contains the intent and the three keys |
| prompt: fingerprint | `FieldPhotoPrompt.prompt_fingerprint_sha256` equals the literal captured with `bin/rails runner 'puts FieldPhotoPrompt.prompt_fingerprint_sha256'` on the pre-Phase-1 commit |
| prompt: constant gone | `FieldPhotoPrompt.const_defined?(:CONTRACT_VERSION)` is false |
| service: fields | parsed with intent; nil without intent even if JSON has them; invalid enum → nil |
| service: compact context | visibility segment only with intent |
| job: same sha twice | vision `call` twice; no `photo_cache_hit` event |
| job: blank + intent | one call; user content has the intent; `photo_analyzed` summary starts with the renderer paragraph; `PhotoQuestionAnswerService` not called |
| job: blank + nil / expired | today's summary; no intent block |
| job: question present | one call; user content contains the question as intent; `photo_question_answered` |
| job: `field_photo_id` re-ask, no pending token | bytes rehydrated from S3 (stub); one call |
| orchestrator: uploaded image | pending token always written; `WarmBedrockKbJob` enqueued when query present; `photo_submitted` has no `cache_status` |
| photo question: hidden target | evidence block has the line; Condition line present |

### REAL_FLOW_REPLAY

Fixture `test/fixtures/real_gonzalo/photo_81515_episode.json`, built from the export, never from a new model call:

* user history messages of `ep_271dcb5597b17c32` from 20:22 through `query:d7d98115-…` with their `ts`. Raw text for elliptical turns is the last line of the composed audit question. Turns whose text is absent from the export (`a8919734`, `2ee7b500`) are stored with `content: ""`.
* every non-empty `content` has `SHA256 == original_sha256` of that turn's `field_companion_turn` event. The test asserts this, so the fixture cannot drift from production.
* `active_episode`: `episode_id` `ep_271dcb5597b17c32`, `goal.text` = d7d text, `opened_at` ≤ 20:22:49, `updated_at` = 20:35:32; photo `now` = `2026-09-25T20:38:39-03:00`.
* image bytes: a 1×1 fixture; sha only as identifier. No S3.

`RealGonzaloPhotoContinuityTest` stubs `ClaudeChunkingClient#call`, records `user_content`, returns:

```json
{
  "canonical_component": "conjunto de cabina y puerta",
  "summary": "Se ve un conjunto de cabina y puerta.",
  "target_visible": false,
  "relevance_to_goal": "unrelated",
  "missing_view_or_detail": "primer plano de las fijaciones de cables con sus resortes y de la placa"
}
```

Assertions:

* `call` count 1; recorded user content includes `resortes` and `fijación`, not `transformador`, not `otra imagen`
* broadcast `summary` starts with the hidden-target sentence and includes `primer plano`
* `Rag::PhotoQuestionAnswerService` not instantiated
* second example (`e9cea` shape): same sha as the 17:36 photo, question "Cómo se ajustan los resortes de la fijación de cables" → vision called (no reuse), user content contains that question, photo-question service called (stubbed)

### Phase 1 validation command

```text
bin/rails test \
  test/services/rag/photo_intent_test.rb \
  test/services/rag/photo_intent_renderer_test.rb \
  test/prompts/field_photo_prompt_test.rb \
  test/services/field_photo_analysis_service_test.rb \
  test/jobs/field_photo_analysis_job_test.rb \
  test/services/query_orchestrator_service_test.rb \
  test/services/rag/photo_question_answer_service_test.rb \
  test/services/rag/real_gonzalo_photo_continuity_test.rb \
  test/services/batch_results_parser_service_test.rb \
  test/services/pilot_metrics_report_test.rb
bin/rails test
git grep -nE "FieldPhotoDiagnosisCache|FieldPhotoPrompt::CONTRACT_VERSION|photo_dx" -- app lib script test config   # must print nothing
bin/rubocop <changed .rb files>
```

### Phase 1 non-goals

* Do not fix Sonnet's misread with another model or call.
* Do not change `ActiveEpisodeTurn` (Phase 2A).
* Do not write semantic `BedrockQuery` rows or change `photo_completed.cost` (Phase 3).
* Do not edit `SYSTEM_BLOCKS`, `PilotMetricsReport`, or ingestion.

## PHASE_1_VALIDATION_RESULT

```text
STATUS=PASS
PLAN_RECONCILIATION=MINOR_RECONCILIATION
```

The implementation matches the refined Phase 1 contract. The only reconciliation: this plan says the handoff lives only in this file, and the execution brief also required `docs/PHASE_2_EXECUTION_PROMPT.md`. Both were written. The prompt text is the same.

Commands (exit 0 except the grep, which exits 1 because it prints nothing):

```text
BUNDLE_PATH=vendor/bundle bin/rails test <Phase 1 validation command list>
188 runs, 980 assertions, 0 failures, 0 errors, 2 skips
(skips are the pre-existing marker tests in batch_results_parser_service_test.rb)

BUNDLE_PATH=vendor/bundle bin/rails test
3417 runs, 16680 assertions, 0 failures, 0 errors, 186 skips

git grep -nE "FieldPhotoDiagnosisCache|FieldPhotoPrompt::CONTRACT_VERSION|photo_dx" -- app lib script test config
(no output)

BUNDLE_PATH=vendor/bundle bin/rubocop --cache false <18 changed .rb files>
18 files inspected, no offenses
```

Pre-plan upgrade `9c34751add7dbf45d27e23256ee733c0467af29b` was not reopened. Live vision stays `claude-sonnet-5` (`BatchChunkingPrompt::MODEL_TEXT`). Ingestion multimodal stays `claude-opus-5-5`. RAG generation was not touched.

Files changed:

```text
deleted  app/services/field_photo_diagnosis_cache.rb
deleted  test/services/field_photo_diagnosis_cache_test.rb
added    app/services/rag/photo_intent.rb
added    app/services/rag/photo_intent_renderer.rb
added    test/services/rag/photo_intent_test.rb
added    test/services/rag/photo_intent_renderer_test.rb
added    test/services/rag/real_gonzalo_photo_continuity_test.rb
added    test/fixtures/real_gonzalo/photo_81515_episode.json
modified app/jobs/field_photo_analysis_job.rb
modified app/prompts/field_photo_prompt.rb
modified app/services/field_photo_analysis_service.rb
modified app/services/query_orchestrator_service.rb
modified app/services/rag/photo_question_answer_service.rb
modified config/locales/rag.es.yml
modified config/locales/rag.en.yml
modified docs/ACTIVE_ARCHITECTURE.md
modified script/grounded_synthesis_battery_2026-09.rb
modified script/photo_question_regression_2026-09-15.rb
modified script/photo_question_regression_v2_2026-09-15.rb
modified test/jobs/field_photo_analysis_job_test.rb
modified test/prompts/field_photo_prompt_test.rb
modified test/services/field_photo_analysis_service_test.rb
modified test/services/query_orchestrator_service_test.rb
modified test/services/rag/photo_question_answer_service_test.rb
```

Methods:

```text
Rag::PhotoIntent.resolve / visual_target?
Rag::PhotoIntentRenderer.prose
FieldPhotoPrompt.user_content(photo_intent:) / intent_block
FieldPhotoAnalysisService#call (photo_intent keyword; three normalized fields)
FieldPhotoAnalysisJob#perform (resolve intent before vision; no cache)
FieldPhotoAnalysisJob#published_analysis / #photo_value
QueryOrchestratorService#execute (always pending token; warm KB when query present)
Rag::PhotoQuestionAnswerService#photo_evidence_block / #hidden_target_line
```

Confirmed invariants:

```text
SYSTEM_BLOCKS_UNCHANGED=YES
prompt_fingerprint_sha256=4f62491874c8fea82d78632657e9adc93da80c69e40157eee98b5cfe972715d1
INGESTION_CONTRACT_VERSION=field_photo_records_v3
BatchChunkingPrompt::INGESTION_CONTRACT_VERSION=field_records_v8
SEMANTIC_VISUAL_CACHE=REMOVED
VISION_CALLS_PER_PHOTO=1
TARGET_VISIBLE missing/invalid stored as nil and rendered uncertain
NEW_MODEL_CALL_TYPES=0
ARCHITECTURE_DRIFT=NO
HUMAN_VALIDATION_REQUIRED=NO
ActiveEpisodeTurn, generation.txt, semantic ownership, HYBRID_MINIMAL untouched
```

Discarded: semantic visual cache, intent-keyed cache, lexical no-overlap → `target_visible=false`, a second vision/classifier/reconciliation call, bumping a photo contract version, reingestion, editing `SYSTEM_BLOCKS`, a separate `meta_photo_offer?` predicate.

Known limitations: vision accuracy is not a gate; an identical reupload calls vision again; a blank photo of a non-lexicon subject after a non-visual turn can inherit an older visual target, and the renderer still appends the standalone reading; an explicit question is not lexicon-checked; prompt tests prove the rules reach the model; the Gonzalo image sha in the fixture is the 12-char prefix `46de1a09cb75`; leftover `photo_dx` entries expire in 24 h and nothing reads them; `PilotMetricsReport` still parses historical cache-hit events.

---

## PHASE_2 — scope, source fidelity, Field Companion

Definitive prompt is regenerated after Phase 1 PASS from PHASE_2_PROMPT_SEED plus what Phase 1 shipped. Do not start Phase 2 from this section alone.

OPUS_REFINEMENT_2026-09-26: Phase 2 is one deterministic scope reset, one deterministic value guard, one citation dedupe, one locale/telemetry change, and grounded prompt lines. Model-behavior items (voice, ordering, tone, cross-manual wording) are prompt contracts because no automated gate can prove model behavior without a model call; the value guard is the deterministic safety net.

### 2A. Scope contamination

Confirmed root cause (export + code): accent-folded `@normalized` makes "está" match `FOLLOWUP_RE` → `elliptical?` → `compose_text` = LCB II goal + `CMC-3` + LCE question (154 chars). Even without composition, the episode keeps CMC-3/LCB II identity, and `DocumentIdentityScope` would cut non-matching LCE chunks to `REFERENCE ONLY — OTHER EQUIPMENT`.

Fix, in `ActiveEpisodeTurn#call`, immediately after `owned = apply_owned_slice(current); return owned if owned` and before the brand rules:

```ruby
return open_episode(:new_episode, current, goal: :always) if disjoint_catalog_equipment?(current)
```

`disjoint_catalog_equipment?(episode)` is true only when all hold:

* `FollowupQueryRewriter.explicit_question?(@text)` and `@words.size >= 6`
* not `FOLLOWUP_START_RE` on `@normalized` and not `correction?`
* the episode has equipment identity: a known `model` fact or non-empty user `identifiers`
* some token from `@text.scan(KbDocumentResolver::TOKEN_RE)` passes `KbDocumentResolver.specific_token?` and `catalog_identity_for(token)` (existing method) returns a non-ambiguous `{"model" => m}`
* `m` (case-insensitive) is not the episode model, not in its identifiers, and not in `episode.goal["text"]`

The deictic marker does **not** block the reset: "¿Qué hace la tarjeta LCE y donde esta su configuracion?" typed without accents must reset. `FOLLOWUP_RE` is not edited.

Owned `switch`/`correct` still return first. A failed or `continue` perception does not block the guard. This is deterministic, not a new semantic owner. Short turns ("y en el LCE?") keep today's path.

Acceptance `test/services/rag/lce_scope_replay_test.rb` (no `Retrieve`). Catalog setup follows `test/services/rag/haiku_ownership_slice_test.rb` (~343): `Rag::DocumentIdentityCatalog.with_catalog(Rag::DocumentIdentityCatalog.new({ "documents" => rows }))` with rows copied verbatim from `config/document_identities.yml` (LCE ~1406–1418, LCB II ~974, the CMC-3 entries) plus the matching `KbDocument` records for the test account, so `catalog_identity_for` runs its real `resolve_scoped` → `consensus` path:

* episode as of `query:406f82ce-…`: goal = LCB II question, identifiers include `CMC-3` and `LCB II`, manufacturer as 40bb wrote it; fixture texts SHA-checked against `original_sha256`
* exact LCE question, accented and unaccented: decision `:new_episode`; `result.composed` nil or equal to the turn; effective retrieval text contains neither `LCB II` nor `CMC-3`; resulting episode model/identifiers contain neither
* `catalog_identity_for("LCE")` returns `{"model" => "LCE", …}` (proves the catalog path; if the catalog made it ambiguous this test fails first and names the cause)
* "¿dónde está el fusible F1 de la placa?" on the LCB II episode does not reset
* "¿Qué reviso primero?" on the spring episode stays `continued_elliptical` and composes `fijación de cables`
* "esta polea tractora, ¿cómo se ajusta?" keeps its current result

Baseline: `test/scripts/production_conversational_baseline_v2_test.rb` and `…_verdict_test.rb` green; fixture file unchanged. The SSH production replay is post-deploy engineering, not a gate.

### 2B. Source fidelity

`Rag::SourceFidelityGuard.call(answer:, evidence_texts:, allowed_texts:, locale:)` → `{ answer:, removed: Integer }`.

* Extract `(number, unit)` pairs with one regex built from `AnswerSafetyProcessor::EVIDENCE_SENSITIVE_VALUE_PATTERN` units plus `%`, `N·m`, `Nm`, `vueltas`, `turns`. Normalize: comma → dot, unit upcased, `N·M` → `NM`, `VDC`/`VAC`/`VCC`/`VCA` → `V`.
* Supported = the pair occurs in any `evidence_texts` (retrieved chunk bodies used for this answer) or `allowed_texts` (raw question, effective question, and the `## Photo Evidence (this turn)` block when present — never the rest of session context, so a previous invented value cannot launder itself).
* Each unsupported pair removes its list item (line) or else its sentence. If `removed > 0`, append `rag.unsupported_value_removed` once and log `source_fidelity_guard` (`correlation_id`, `removed`).
* `evidence_texts` empty (deterministic routes, `model_invoked: false`, `retrieved_citations: []`) → no-op, logged `skipped: no_evidence`.
* One call site: `RagQueryConcern#execute_rag_query`, on `result[:answer]` before `sanitize_answer`, using `result[:retrieved_citations]` content. This covers text and photo-question turns once. `AnswerSafetyProcessor` is not re-run.
* Every model-invoking route must deliver chunk bodies in `retrieved_citations`: `BedrockRagService#query` (both result builders, ~472 and ~738) and `StructuredEvidenceRoute` (~282). If a route's entries lack body text, Phase 2 adds the already-retrieved body to those entries (no new retrieve). `rag_query_concern_test` builds each route's real result shape and asserts bodies are extracted, so the guard cannot be a silent no-op on a generation route.

`generation.txt` (grounded lines use `GROUNDED_SYNTHESIS:`; strict lines keep today's text):

* voice: a sentence from the manual says so ("Según el manual …"); a field check that is inference says so ("Como verificación de campo …"). (CMC-3)
* precondition: keep the source's power state for each step; a step the manual performs powered is never placed before energizing. Copy numbers exactly. (LCB II)
* internal note: when an internal technical note names its source manual and page, cite that manual and page through the note; when the job's equipment is not confirmed, add that the value is from another manufacturer and does not transfer. (Fuji / KONE)
* DOCUMENT IDENTITY: the filename names the file; it is not evidence of the page's manufacturer or model. (LG-Sigma, regression)
* sibling rule (~82–87): remove the `STRICT_ONLY:` prefix so both templates carry it. (MPK 708A/708C)

Citation dedupe in `Bedrock::CitationProcessor#build_numbered_references`: a later number whose `title` (already `"… — p. N"`) equals an earlier one is dropped from the list and its `[n]` markers in the answer are rewritten to the earlier number.

Tests (stored strings, no Bedrock):

| test | fixture turns | assertion |
|---|---|---|
| `source_fidelity_guard_test` LCB II | `query:406f82ce-…` chunks + a captured-shape answer with `24 V` | `24 V` sentence removed; `30 V` and `F1 4 A` from chunks kept; notice appended once |
| guard Fuji/KONE | `query:242729f2-…`, `query:b1020088-…` | `5 %`, `3 mm`, `C = 20 mm` kept |
| guard photo nameplate | photo evidence block with `380 V` | kept |
| guard laundering | `24 V` only in prior assistant history | removed |
| guard no evidence | deterministic route | answer unchanged |
| guard mechanical | "los resortes se ven de largo distinto" kept; "apriete a 30 N·m" without chunk removed | |
| `rag_query_concern_test` | stub orchestrator result | guard called once, before `sanitize_answer` |
| `bedrock_generation_prompt_test` | — | each new GS line present in grounded, absent in strict; sibling rule present in both |
| `citation_processor_test` | two BL6 refs same title+page | one entry; markers rewritten |

### 2C. "No encontré"

* `rag.data_not_available` es: "Ese dato no aparece en los fragmentos de manual recuperados para esta consulta." en: "That information is not in the manual excerpts retrieved for this question." `DATA_NOT_AVAILABLE` stays the internal marker (`render_internal_markers` unchanged).
* `EvidenceSelectionTelemetry::ABSTENTION_PATTERN` adds `no\ aparece\ en\ los\ fragmentos` and `not\ in\ the\ manual\ excerpts`; old alternatives stay for historical logs. Otherwise abstention metrics silently drop.
* The LCE non-answer is fixed by 2A, not by wording.

Tests: `evidence_selection_telemetry_test` matches both new sentences; `answer_safety_processor_test` renders the new sentence; any test asserting the old sentence is updated in the same commit.

### 2D. Field Companion tone

One `GROUNDED_SYNTHESIS:` block: open with what the technician can check or do next; then what the manual states, what is inference, what is unconfirmed; at most one next measurement or photo. Never open with "La documentación recuperada" or "No encontré". Prose for a phone, no mandatory headings. Contract test only.

### 2E. General mechanical reasoning

`GROUNDED_SYNTHESIS:` allow-list, stated as observation, never as a manual step: asimetría, posición relativa, roscas, tuercas, resortes, holgura visible, corrosión, deformación, hardware faltante o suelto, comparación visual, herramienta obvia por la forma del elemento. Still forbidden unless the retrieved chunks contain it: torque, número de vueltas, tensión objetivo, tolerancias, setpoints, bypasses, any value with a unit, undocumented critical procedures. `SourceFidelityGuard` enforces the values; the rest is the existing GS rule (~21) plus this line.

### Phase 2 validation command

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

---

## PHASE_2_VALIDATION_RESULT

```text
STATUS=PASS
PLAN_RECONCILIATION=MINOR_RECONCILIATION
```

The implementation matches the refined Phase 2 contract. Two reconciliations, both resolved from the chunks and the algorithm, not left open:

1. The LCB II acceptance example says `24 V` is removed. The stored `query:406f82ce` chunk states both `24 Vcc` (the supply F1 protects) and `30 Vcc` (the voltage absent when F1 opens). After `VCC` → `V`, the pair `(24, V)` is supported. The guard keeps `24 V`, `30 V`, and `F1 4 A`, and removes an unsupported `12 V`. A `24 V` that exists only outside the chunk, the question, and this turn's photo block is still removed. Pair occurrence is the algorithm; a contradiction detector was not added.
2. Sharing the sibling-model rule and adding the grounded lines put the grounded template at 3194 tokens, above the old cap of strict × 1.08 (2768). The cap is now strict × 1.30. The filtered strict template SHA is unchanged (`9182ccf3ac853409bd66cbc58ba808d28d5ce192ce90a44593f6d51a33d74ff8`).

`rag.unsupported_value_removed` was not specified. The notice is one sentence: es "Quité un valor con unidad que no aparece en los fragmentos recuperados ni en tu consulta." en "I removed a unit value that is not in the retrieved excerpts or in your question."

Commands (all exit 0):

```text
BUNDLE_PATH=vendor/bundle bin/rails test <Phase 2 validation command list>
348 runs, 1819 assertions, 0 failures, 0 errors, 22 skips

BUNDLE_PATH=vendor/bundle bin/rails test
3440 runs, 16838 assertions, 0 failures, 0 errors, 186 skips

git diff --exit-code -- script/fixtures/production_conversational_baseline_v2.json

BUNDLE_PATH=vendor/bundle bin/rubocop --cache false <15 changed .rb files>
15 files inspected, no offenses
```

Phase 1 commit `732331ef0bfb5d8a833956273de93dca1c56fe27` and the model upgrade `9c34751add7dbf45d27e23256ee733c0467af29b` were not reopened. Live vision stays `claude-sonnet-5`. Ingestion multimodal stays `claude-opus-5-5`. RAG generation model was not changed.

Files changed:

```text
added    app/services/rag/source_fidelity_guard.rb
added    test/services/rag/lce_scope_replay_test.rb
added    test/services/rag/source_fidelity_guard_test.rb
added    test/fixtures/real_gonzalo/lce_episode.json
added    test/fixtures/real_gonzalo/chunks/lcbii.json
added    test/fixtures/real_gonzalo/chunks/fuji_kone.json
added    test/fixtures/real_gonzalo/chunks/bl6_citations.json
modified app/services/rag/active_episode_turn.rb
modified app/services/bedrock/citation_processor.rb
modified app/controllers/concerns/rag_query_concern.rb
modified app/services/rag/evidence_selection_telemetry.rb
modified app/prompts/bedrock/generation.txt
modified config/locales/rag.es.yml
modified config/locales/rag.en.yml
modified script/fixtures/rag_seguridades_rubric.json
modified script/fixtures/rag_seguridades_pilot_10q.json
modified script/fixtures/rag_seguridades_pilot_10q_v2.json
modified test/controllers/concerns/rag_query_concern_test.rb
modified test/prompts/bedrock_generation_prompt_test.rb
modified test/services/bedrock/citation_processor_test.rb
modified test/services/bedrock_rag_service_grounded_synthesis_test.rb
modified test/services/rag/answer_safety_processor_test.rb
modified test/services/rag/evidence_selection_telemetry_test.rb
modified test/services/rag/followup_query_rewriter_test.rb
modified test/services/rag/citation_attribution_contract_characterization_test.rb
```

Methods:

```text
ActiveEpisodeTurn#disjoint_catalog_equipment?
ActiveEpisodeTurn#equipment_identity?
ActiveEpisodeTurn#disjoint_catalog_model
Rag::SourceFidelityGuard.call / evidence_texts / allowed_texts
Bedrock::CitationProcessor#build_numbered_references (duplicate title dropped; [n] rewritten)
RagQueryConcern#execute_rag_query (guard once, before sanitize_answer)
```

Six rubric checks matched the partial-absence rendering only through the old sentence. Each of those patterns now also accepts `no aparece en los fragmentos`. The old alternatives stay. `rag_seguridades_holdout_v1.json` SHA stays `34682fb13ca5acf0e635d42ad285be039749b4d07f090a728ef43371d4325309`. Raw `generation.txt` SHA is `1097664a990784ef6254a351754f427beb2fc13310171e8d50177a9e604eddf1`.

Confirmed invariants:

```text
SYSTEM_BLOCKS_UNCHANGED=YES
INGESTION_FINGERPRINT_UNCHANGED=YES
INGESTION_CONTRACT_UNCHANGED=YES
FOLLOWUP_RE_UNCHANGED=YES
BASELINE_FIXTURE_UNCHANGED=YES
STRICT_TEMPLATE_SHA_UNCHANGED=YES
NEW_MODEL_CALL_TYPES=0
ARCHITECTURE_DRIFT=NO
HUMAN_VALIDATION_REQUIRED=NO
HYBRID_MINIMAL unchanged
semantic ownership remains switch / correct only
EvidenceProvenance not created
RetrievalOutcome not created
semantic_analysis enum not added
TrackBedrockQueryJob not enqueued from SemanticQueryAnalyzer
```

Discarded: editing `FOLLOWUP_RE`, a second Retrieve, re-running `AnswerSafetyProcessor`, a context-sensitive voltage contradiction detector, deleting a supported `24 V` because the plan's example said so, putting the sibling rule back behind `STRICT_ONLY:`.

The Phase 3 prompt is `## PHASE_3_EXECUTION_PROMPT` in this file. No separate document: this brief and the handoff agree.

---

## PHASE_3 — telemetry and cost

The executable prompt is `## PHASE_3_EXECUTION_PROMPT` below. Do not start Phase 3 from this section alone.

### Accounting

`SemanticQueryAnalyzer#call`, after `log_shadow`, when `input_tokens > 0`: `TrackBedrockQueryJob.perform_later` with `source: "semantic_analysis"`, `route: "semantic_analysis"`, `model_id: MODEL_ID`, `token_source: "provider_usage"`, `input_tokens`, `output_tokens`, `cache_read_tokens`/`cache_creation_tokens` from `usage.cache_read_input_tokens`/`usage.cache_write_input_tokens` when present, `latency_ms`, `correlation_id`, `user_query: @turn`, and `account_id`/`user_id`/`conversation_session_id` from a new `attribution:` argument.

* Callers pass attribution: `ActiveEpisodeTurn#owned_perception` (`observe_ownership`, production) and `RagController#observe_semantic_shadow` (`observe`, shadow).
* `hallucinated_spans` and `invalid_schema` are paid → one row each, `analysis` stays nil.
* Transport error / timeout (`input_tokens == 0`) → no row.
* The enqueue is wrapped in `rescue StandardError` + warn log: tracking never fails a turn. It runs inside `record_user_turn!`'s `with_lock`; `perform_later` only enqueues.
* `haiku_query_analysis_shadow` stays diagnostic; it is never summed.

`BedrockQuery` enum adds `semantic_analysis`. `LlmUsageChannel` maps it to `:bedrock_semantic`. `SimpleMetricsService` includes that channel once in the Haiku token/cost rollup and keeps `query_count = source == query` (RAG query count does not jump). `total_cost` already sums every row once.

`PilotMetricsReport`: `semantic_llm_calls` = rows with `source == semantic_analysis`; `rag_llm_calls` and `visual_row?` unchanged; token/cost totals already sum all rows.

Vision: `FieldPhotoAnalysisService#usage_payload` carries `cache_read_tokens`/`cache_creation_tokens`; the job prices `photo_completed.cost` with them so it equals the client's `BedrockQuery#cost` (0.014085 for 1430/360/1172). Still exactly one vision row per call (`ClaudeChunkingClient#track_usage`). With the cache removed there is no hit row case; identical bytes twice = two real rows.

### Turn evidence

`Rag::TurnEvidence.build` → one hash per correlation, logged as `[TURN_EVIDENCE]`:

```text
correlation_id, route, outcome
original_query_sha256, effective_query_sha256
semantic: { status, relation, ambiguous } | nil
photo: { intent_source, target_visible } | nil
chunk_ids, sources (title + page)
answer_sha256
original_query, effective_query, answer   # only when PILOT_AUDIT_CAPTURE == "true"
```

OPUS_REFINEMENT_2026-09-26: no token or cost fields. Cost per turn = `BedrockQuery` rows joined by `correlation_id` (semantic + generation + vision). One authority, so double counting is impossible by construction. Text is gated by the existing `PILOT_AUDIT_CAPTURE` flag so the privacy posture does not change; pilots already run with capture on.

Emit from: `RagController#emit_interaction_completed` (text; success and failure) and `FieldPhotoAnalysisJob#emit_interaction_completed` plus the `retry_on` failure block (photo; blank, question, expired, failed).

Reconstruction: `[TURN_EVIDENCE]` (turn, effective query, chunks, answer) + `kb_retrieve` event (retrieval) + `BedrockQuery` by `correlation_id` (semantic / generation / vision tokens and cost).

### Fixtures and audited numbers

`source_events.jsonl` has `semantic_analysis_ms` but no per-call token vector. Committed `test/fixtures/real_gonzalo/semantic_accounting_2026-09-25.json`: the 16 correlation ids (15 text turns + `photo:e9cea10e-…`) and the aggregate `calls: 16, input_tokens: 22896, output_tokens: 1719, cost_usd: 0.031491`. No hand-partitioned per-call split.

| test | assertion |
|---|---|
| semantic success | one row `source: semantic_analysis`, stub tokens, `correlation_id`, attribution |
| `hallucinated_spans` / `invalid_schema` | one row each, cost > 0 |
| transport error | zero rows |
| enqueue raises | turn completes; warn logged |
| generation + semantic, one turn | two rows, different `source`; sum = both usages once |
| vision miss | one `visual_query` row with cache tokens; `photo_completed.cost` = 0.014085 |
| identical bytes twice | two `visual_query` rows |
| blank photo | vision row only, no semantic row |
| turn evidence | one record for `photo:81515bf6-…` (empty original query hash, `target_visible`), one for `query:4243acf2-…`; text fields absent when capture off, present when on; no cost keys |
| report join | `PilotMetricsReport` sums the rows for a correlation once |
| aggregate fixture | `BedrockQuery.new(model_id: haiku global, input_tokens: 22896, output_tokens: 1719).cost` = 0.031491 |
| `SimpleMetricsService` | semantic rows in the Haiku rollup once; `query_count` unchanged |

### Phase 3 validation command

```text
bin/rails test \
  test/services/rag/semantic_query_analyzer_test.rb \
  test/models/bedrock_query_test.rb \
  test/jobs/track_bedrock_query_job_test.rb \
  test/services/llm_usage_channel_test.rb \
  test/services/simple_metrics_service_test.rb \
  test/services/pilot_metrics_report_test.rb \
  test/jobs/field_photo_analysis_job_test.rb \
  test/services/rag/turn_evidence_test.rb \
  test/services/rag/real_gonzalo_semantic_accounting_test.rb
bin/rails test
bin/rubocop <changed .rb files>
```

---

## AUTOMATED_VALIDATION_STRATEGY

Each phase ends only as `PASS`, `FAIL`, or `PLAN_BLOCKER`.

* PASS = every command in that phase's validation block exits 0 (named files, full `bin/rails test`, grep/diff gates, rubocop).
* FAIL = anything else. Fix inside the phase; no commit.
* PLAN_BLOCKER = only a contradiction that the repo, the export, fixtures, and tests cannot resolve. None is known.

No step requires a person to read an answer, open the UI, interpret logs, approve a diff, or replay as Gonzalo. Image bytes, `converse`, `Retrieve`, and S3 are stubbed. Catalog proof is `config/document_identities.yml`. Real-flow fixtures are SHA-checked against the export.

Known limit, not a blocker: prompt-contract tests prove the rules reach the model, not that the model follows them; vision correctness is not asserted. Deterministic code (intent resolution, rendering, scope reset, value guard, citation dedupe, accounting) is fully asserted. The 14-flow SSH replay (`script/production_conversational_baseline_v2.rb`) is a post-deploy engineering check, not a phase gate.

---

## REAL_FLOW_FIXTURES_AND_REPLAYS

Under `test/fixtures/real_gonzalo/`, created by the phase that first needs them, copied from the export or `config/document_identities.yml`; raw user texts SHA-checked against `original_sha256`:

| fixture | phase | proves |
|---|---|---|
| `photo_81515_episode.json` | 1 | blank photo, meta goal, spring sentence still in history |
| `lce_episode.json` | 2 | goal LCB II, identifiers CMC-3 / LCB II, LCE question |
| `chunks/lcbii.json`, `fuji_kone.json`, `bl6_citations.json` | 2 | captured chunk bodies, captured-shape answers, duplicate refs |
| `semantic_accounting_2026-09-25.json` | 3 | 16 correlation ids + aggregate |

Do not commit `tmp/pilot_exports/`.

---

## COMMIT_STRATEGY

One commit per phase, only on PASS:

```text
phase 1: Read each field photo fresh with the technician's intent.
phase 2: Keep equipment scope and source values faithful.
phase 3: Account every paid model call per turn.
```

* The Phase 1 commit also adds this plan and `docs/REAL_GONZALO_PRODUCTION_FLOW_AUDIT_2026-09-25.md` (currently untracked).
* Each phase commit includes its own edit to this file (validation result + next prompt). Nothing else is mixed.
* The implementing session commits without a further approval step. Planning/review sessions never commit.
* Deploy is outside this plan. Per the Fase 2 lesson, commit before any `kamal deploy`.

---

## PHASE_HANDOFF_STRATEGY

```text
IMPLEMENT → AUTOMATED VALIDATION → PASS → WRITE VALIDATION RESULT → UPDATE NEXT PHASE PROMPT → COMMIT
```

All in this file, no other documents:

* append `## PHASE_N_VALIDATION_RESULT`: commands, exit status, test names added, files actually changed.
* replace `PHASE_N+1_PROMPT_SEED` with `PHASE_N+1_EXECUTION_PROMPT` containing: actual files/methods changed, new tests/fixtures, confirmed invariants, discarded hypotheses, new constraints, and what the next phase must not reopen.

On FAIL: no commit, no prompt update.

---

## ROLLBACK_BOUNDARIES

| phase | revert | what stays safe |
|---|---|---|
| 1 | `git revert` the Phase 1 commit | the cache returns and refills; entries written before Phase 1 can be served again until their 24 h expiry; ingestion untouched throughout; episode JSON shape unchanged |
| 2 | revert the Phase 2 commit | ownership untouched; baseline fixture untouched; `DATA_NOT_AVAILABLE` marker unchanged |
| 3 | revert the Phase 3 commit | existing `query`/`ingestion_*` rows unchanged; `semantic_analysis` rows remain as inert history (string column) |

No shared feature flag. Phases revert independently in reverse order; Phase 3's photo cost edit only depends on the Phase 1 `photo_value` builder.

---

## FINAL_DEFINITION_OF_DONE

```text
SEMANTIC_VISUAL_CACHE_REMOVED=PASS
INGESTION_PROMPT_UNCHANGED=PASS
MULTIMODAL_CONTINUITY=PASS
EXPLICIT_QUESTION_INTENT_TO_VISION=PASS
SELF_CONTAINED_EQUIPMENT_SCOPE=PASS
LCE_REAL_REPLAY=PASS            (accented and unaccented)
SOURCE_VALUE_FIDELITY=PASS      (LCB II 24 V removed, 30 V kept)
CROSS_MANUFACTURER_VALUES_KEPT=PASS
PROMPT_CONTRACTS=PASS           (voice, precondition, internal note, filename, sibling, tone, allow-list)
CITATION_DEDUPE=PASS
NOT_FOUND_WORDING_AND_TELEMETRY=PASS
SEMANTIC_CALL_ACCOUNTING=PASS   (aggregate 0.031491; per-outcome rows)
VISION_COST_WITH_CACHE_TOKENS=PASS (0.014085)
NO_DOUBLE_COUNTING=PASS         (BedrockQuery sole cost authority)
TURN_EVIDENCE_EXPORT=PASS
NEW_MODEL_CALL_TYPE=NONE
HYBRID_MINIMAL_UNCHANGED=YES
SEMANTIC_OWNERSHIP_UNCHANGED=YES
ENTITY_PROJECTION=NO
ARCHITECTURE_DRIFT=NO
HUMAN_VALIDATION_REQUIRED=NO
```

---

## PHASE_2_EXECUTION_PROMPT

The seed is retired. The executable prompt, written from the Phase 1 result, is `docs/PHASE_2_EXECUTION_PROMPT.md`. It records the shipped paths (`PhotoIntent`, `PhotoIntentRenderer`, the live-photo user-content block, the renderer, the removed cache), the fingerprint and ingestion-contract invariants, the rejected cache/overlap hypotheses, the residual inherited-intent limit, and the Opus-refined 2A–2E contract. Do not start Phase 2 from the Phase 2 section alone.

## PHASE_3_EXECUTION_PROMPT

The seed is retired. Execute this section. The `## PHASE_3` section above is the contract. Do not write an alternate plan. Do not implement Future Phase 4.

### Current repo state

Phase 1 commit `732331ef0bfb5d8a833956273de93dca1c56fe27`. Model upgrade `9c34751add7dbf45d27e23256ee733c0467af29b` (Sonnet 4.6 → Sonnet 5, Opus 4.8 → Opus 5.5). Phase 2 is the commit that contains `## PHASE_2_VALIDATION_RESULT`. Do not reopen any of them unless a regression is caused by that commit.

```text
PHASE2_STATUS=PASS
HUMAN_VALIDATION_REQUIRED=NO
```

Live field-photo vision stays `claude-sonnet-5` (`BatchChunkingPrompt::MODEL_TEXT`). Ingestion multimodal stays `claude-opus-5-5` (`BatchChunkingPrompt::MODEL_MULTIMODAL`). RAG generation model stays unchanged. `SYSTEM_BLOCKS` fingerprint `4f62491874c8fea82d78632657e9adc93da80c69e40157eee98b5cfe972715d1`. `FieldPhotoPrompt::INGESTION_CONTRACT_VERSION` is `field_photo_records_v3`. `BatchChunkingPrompt::INGESTION_CONTRACT_VERSION` is `field_records_v8`. Do not reingest.

Frozen:

```text
HYBRID_MINIMAL
HAIKU_QUERY_ANALYSIS_MODE=conditional
semantic ownership: switch / correct only
baseline: 14 flows, 29 turns, 14/14 PASS
unsafe_contamination=0
HTTP 5xx=0
ARCHITECTURE_CHANGE_REQUIRED=NO
ENTITY_PROJECTION_REQUIRED=NO
FOLLOWUP_RE unchanged
production_conversational_baseline_v2.json unchanged
filtered strict generation template SHA 9182ccf3ac853409bd66cbc58ba808d28d5ce192ce90a44593f6d51a33d74ff8
holdout v1 SHA 34682fb13ca5acf0e635d42ad285be039749b4d07f090a728ef43371d4325309
```

### Do not reopen

Phase 1: `Rag::PhotoIntent`, `Rag::PhotoIntentRenderer`, one vision call per photo, no `FieldPhotoDiagnosisCache`, no `photo_dx` reads or writes, no intent LLM, `target_visible` missing stored as nil and rendered uncertain.

Phase 2:

* `ActiveEpisodeTurn#disjoint_catalog_equipment?` after the owned slice returns and before the brand rules. Owned switch/correct still return first. Do not edit `FOLLOWUP_RE`.
* `Rag::SourceFidelityGuard` once in `RagQueryConcern#execute_rag_query`, before `sanitize_answer`. Empty evidence is a no-op. Pair occurrence keeps `24 V` when the chunk contains `24 Vcc`. Do not add a contradiction detector and do not delete that supported `24 V`.
* Grounded lines in `generation.txt` (voice, power state, internal note, filename, tone, mechanical allow-list) and the sibling rule without a `STRICT_ONLY:` prefix. The grounded-template budget test allows strict × 1.30. Do not revert it to 8%.
* `Bedrock::CitationProcessor#build_numbered_references` drops a later duplicate title and rewrites `[n]`.
* `rag.data_not_available` is the new sentence in both locales. `DATA_NOT_AVAILABLE` stays the internal marker. `ABSTENTION_PATTERN` keeps the old alternatives plus `no aparece en los fragmentos` and `not in the manual excerpts`.

Known limits that stay: a blank photo of a non-lexicon subject after a non-visual turn can inherit an older visual target; the renderer still appends the standalone reading; an explicit question is not lexicon-checked; prompt tests prove the text reaches the model; vision accuracy is not a gate; leftover `photo_dx` entries expire in 24 h; `PHOTO_DIAGNOSIS_CACHE_TTL_HOURS` stays for Future Phase 4.

### Phase 3 — implement exactly the PHASE_3 section

Semantic `BedrockQuery` accounting, `photo_completed` cache-token cost, and `Rag::TurnEvidence`. No new RAG, semantic engine, Entity Projection, or extra model call. The semantic converse already exists; this phase only records it.

Accounting, in `SemanticQueryAnalyzer#call` after `log_shadow`, when `input_tokens > 0`:

```text
TrackBedrockQueryJob.perform_later
  source: "semantic_analysis"
  route: "semantic_analysis"
  model_id: MODEL_ID
  token_source: "provider_usage"
  input_tokens, output_tokens
  cache_read_tokens / cache_creation_tokens from
    usage.cache_read_input_tokens / usage.cache_write_input_tokens when present
  latency_ms, correlation_id
  user_query: @turn
  account_id / user_id / conversation_session_id from a new attribution: argument
```

* Callers pass `attribution:`: `ActiveEpisodeTurn#owned_perception` (production, `observe_ownership`) and `RagController#observe_semantic_shadow` (shadow, `observe`).
* `hallucinated_spans` and `invalid_schema` are paid: one row each, `analysis` stays nil.
* Transport error / timeout (`input_tokens == 0`) inserts nothing.
* Wrap the enqueue in `rescue StandardError` and a warn log. Tracking never fails a turn. It runs inside `record_user_turn!`'s `with_lock`; `perform_later` only enqueues.
* `haiku_query_analysis_shadow` stays diagnostic and is never summed.

`BedrockQuery` enum adds `semantic_analysis`. Today the enum is `query`, `ingestion_parse`, `ingestion_embed`. `LlmUsageChannel` maps `semantic_analysis` to `:bedrock_semantic` (the model id is `global.anthropic.claude-haiku-4-5-20251001-v1:0`, so it must not fall through `classify_direct_model`). `SimpleMetricsService` includes that channel once in the Haiku token/cost rollup. `query_count` stays `source == "query"`. `total_cost` already sums every row once.

`PilotMetricsReport`: `semantic_llm_calls` = rows with `source == semantic_analysis`. `rag_llm_calls` and `visual_row?` stay as they are. Token and cost totals already sum all rows.

Vision: `FieldPhotoAnalysisService#usage_payload` carries `cache_read_tokens` and `cache_creation_tokens`. `FieldPhotoAnalysisJob#photo_value` prices `photo_completed.cost` with those tokens so it equals `BedrockQuery#cost` for the same inputs (0.014085 for 1430/360/1172). Still exactly one vision row per call (`ClaudeChunkingClient#track_usage`). The cache is gone, so there is no hit-row case. Identical bytes twice means two real rows.

`Rag::TurnEvidence.build` → one hash per correlation, logged as `[TURN_EVIDENCE]`:

```text
correlation_id, route, outcome
original_query_sha256, effective_query_sha256
semantic: { status, relation, ambiguous } | nil
photo: { intent_source, target_visible } | nil
chunk_ids, sources (title + page)
answer_sha256
original_query, effective_query, answer   # only when ENV["PILOT_AUDIT_CAPTURE"] == "true"
```

No token or cost fields. Cost per turn is `BedrockQuery` rows joined by `correlation_id`. Emit from `RagController#emit_interaction_completed` (text, success and failure) and `FieldPhotoAnalysisJob#emit_interaction_completed` plus the `retry_on` failure block (photo: blank, question, expired, failed).

Fixture `test/fixtures/real_gonzalo/semantic_accounting_2026-09-25.json`: the 16 correlation ids (15 text turns + `photo:e9cea10e-…`) and the aggregate `calls: 16, input_tokens: 22896, output_tokens: 1719, cost_usd: 0.031491`. No hand-partitioned per-call split. Do not commit `tmp/pilot_exports/`.

Tests named in the PHASE_3 section table. Gate:

```text
bin/rails test \
  test/services/rag/semantic_query_analyzer_test.rb \
  test/models/bedrock_query_test.rb \
  test/jobs/track_bedrock_query_job_test.rb \
  test/services/llm_usage_channel_test.rb \
  test/services/simple_metrics_service_test.rb \
  test/services/pilot_metrics_report_test.rb \
  test/jobs/field_photo_analysis_job_test.rb \
  test/services/rag/turn_evidence_test.rb \
  test/services/rag/real_gonzalo_semantic_accounting_test.rb
bin/rails test
bin/rubocop <changed .rb files>
```

Use `BUNDLE_PATH=vendor/bundle` if the shell's `BUNDLE_PATH` points at an empty sandbox cache.

Allowed statuses: `PASS`, `FAIL`, `PLAN_BLOCKER`. On FAIL, fix inside Phase 3 and rerun. No commit while FAIL. No Future Phase 4.

On PASS: append `## PHASE_3_VALIDATION_RESULT` to this file. There is no Phase 4 seed to replace. Commit exactly once:

```text
Account every paid model call per turn.
```

Do not deploy. `HUMAN_VALIDATION_REQUIRED=NO`.

---

## FUTURE_PHASE_4 — LEGACY PATH RETIREMENT

Not scheduled, not part of Phases 1–3, not detailed to implementation level. Starts only after Phase 3 PASS, in its own commits.

Goal: audit pre-Field-Companion execution paths, prove reachability or non-reachability, and remove only code proven obsolete.

Method:

1. Inventory prompts, services, renderers, flags, scripts, and tests that predate Field Companion (for example `FollowupQueryRewriter` branches used when `episode_turn_owns_thread?` is false, `Rag::EpisodeThreadResolver`, `STRICT_ONLY:` branches, shadow-mode paths, dated `script/*_2026-*.rb` runners, `PilotMetricsReport` photo-cache fields, `docs/METRICS.md` photo-cache section, `ClaudeChunkingClient` header comment stating `source: "ingestion_parse"`, `PHOTO_DIAGNOSIS_CACHE_TTL_HOURS` in deploy config).
2. For each item prove reachability from production entry points (routes, jobs, flags as deployed) with static call graph + flag values + production log evidence.
3. Classify:

```text
DEAD_CODE               unreachable in every deployed flag combination → remove
ACTIVE_FALLBACK         reachable when a live flag is off or a route fails → keep
SHARED_DEPENDENCY       used by ingestion, WhatsApp, or scripts still run → keep
MIGRATION_COMPATIBILITY needed to read historical rows/logs/exports → keep until a dated cutoff
UNKNOWN                 not proven either way → keep, add telemetry, re-evaluate
```

4. Remove only `DEAD_CODE`, one reviewed commit per area, with the full suite and the conversational baseline green. Never mixed with functional fixes.
