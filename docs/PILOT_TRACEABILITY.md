# Pilot traceability

Engineering observability for the field companion. This is the living contract.
Cost authority stays in [METRICS.md](METRICS.md): reconciled spend is
`bedrock_daily_costs`, `BedrockQuery` is call attribution, and `[TURN_EVIDENCE]`
is trace only.

A maintenance case is a different contract. It is specified below and is not
implemented. Nothing in this document turns a Danebo suggestion into a
technician action.

## Two contracts

| Contract | Question it answers | Store |
|---|---|---|
| Engineering traceability | How Danebo decided on this turn | `[PILOT_USAGE]` and `pilot_events` |
| Maintenance case | What happened to the equipment | The live `conversation_sessions.active_episode` JSON, read later by a projection that does not exist yet |

The engineering trace may name a suggestion, a blocked write, or a conflict.
That is not `actions_taken`.

## Write path

`PilotUsageLog.log` keeps only `ALLOWED_FIELDS`, writes one `[PILOT_USAGE]`
line, then `PilotEventRecorder` inserts one `pilot_events` row in the same
cycle. Both rescue `StandardError`. `PILOT_EVENTS_PERSIST=false` skips the
INSERT. The allowlist is the privacy gate. The flag is only a kill switch.

Episode writes stay inside `ConversationSession#with_lock`. The telemetry
INSERT happens after that lock returns. A failed INSERT does not roll back
the episode and does not hold the session row.

No new LLM, Vision, or retrieval call is added for these events.

## Events this contract adds or completes

Names below are the `event` strings. Reasons are the `outcome_reason` strings
the code already produces. A missing event means the key is absent. It does
not mean `false`.

| Event | When | Fields that matter |
|---|---|---|
| `photo_continuity` | `QueryOrchestratorService#execute` after `PhotoObservationContinuity.decide` | `continuity_action`: `fresh_bytes`, `reread`, `reuse`, `missing_photo`, `passthrough`. `field_photo_id`, `active_photo_id` |
| `photo_observation_reused` | Stored observation reused. Vision is not called | Also `field_photo_id`, `relevance_to_goal`, `manufacturer`, `model` |
| `photo_observation_acceptance` | A new or reread reading is accepted | Same observation fields. The event name is the vision call |
| `identity_promotion` | After the episode lock, and only when a promotion payload exists | `result`: `blocked`, `unchanged`, `conflict`, `promoted`. See reasons below |
| `stale_case_write_dropped` | A writer lost the episode-owner check | `writer`, `expected_episode_id`, `current_episode_id`, `episode_id`, `dropped: true` |
| `document_identity_scope` | A scope decision already computed from the identity and the Result in hand | `result` is the status, or the reason when status is absent. `scope_needles`, `identity_after`, `identity_conflict` |
| `open_retrieval` | Already emitted at the end of the Bedrock open path, and on pin deny | Open-path fallthrough adds `outcome_reason=identity_unknown` and `evidence_applicability=identity_unknown_reference`. Pin deny does not |
| `turn_interpreter` | Already emitted outside the lock | Adds `goal_text` (120 chars) and `goal_source_correlation_id` from the durable episode goal |

`identity_promotion` reasons:

- `relevance_blocked` — first write, `relevance_to_goal` is not `relevant`
- `relevant_observation` — first write promoted manufacturer or model
- `snapshot_excluded` — reuse snapshot had no identity to write
- `explicit_reuse` — reuse wrote at least one photo slot
- `already_known` — nothing changed
- `user_photo_conflict` — user and photo disagree. If a slot was still written, `result` is `promoted` and `identity_conflict` is true. If only the conflict was recorded, `result` is `conflict`

`document_identity_scope` does not invent a reason. `no_compatible` with a nil
Result reason stays `result=no_compatible` and omits `outcome_reason`.
Malformed identity uses `malformed_identity`. Scope disabled uses
`scope_disabled`. The structured route, which has no `open_retrieval` event,
records `not_required` when identity is unknown and adds
`evidence_applicability=identity_unknown_reference`. The Bedrock open path does
not also emit `not_required`; it emits `open_retrieval` with
`identity_unknown` and the same applicability value. Known identity does not
emit `evidence_applicability`. A pin does not change either fact.
`generation_context` does not grow an applicability token.

`[DOCUMENT_IDENTITY]` remains a mirror log. The durable event is not parsed
from that line.

A stale writer does not emit `identity_promotion`.

## Goal provenance

`episode.goal["text"]` and `episode.goal["correlation_id"]` are the durable
goal. `goal_source_correlation_id` is that birth correlation. It is not the
correlation of the turn being logged. A follow-up keeps the opening turn's id.
`goal_text` is clipped to 120 characters in the caller. The allowlist string
cap is 500.

## Vocabulary that stays distinct

| Name | Meaning |
|---|---|
| `photo_continuity` with `continuity_action=reuse` | The orchestrator chose the stored observation |
| `photo_observation_reused` | That observation was delivered without a vision call |
| `photo_reuse` with `result=rehydrated` | Original bytes were read back from storage. Cost boundary, see METRICS.md |
| `photo_cache_hit`, `photo_cache_miss`, `visual_llm_call_avoided` | Not emitted. Historical lines may still parse |

Report labels, not new decision fields:

- visual identity — manufacturer and model on the photo event, `persistence=observation`
- ephemeral identity — `PhotoRetrievalSnapshot` for this question, not persisted as the decision
- episode fact — `identity_promotion.identity_after`
- retrieval identity — manufacturer and model facts on `document_identity_scope`

`identity_after` is compact: `slot:value:source` joined by `|`, or `none`.
`catalog` is not an identity source.

## Turn card

`PilotMetricsReport` hangs `interactions.by_correlation[].field_companion` off
the existing `interaction_completed` row. `report.txt` prints one `TURN`
block per row that has it.

`execution_path` is the event names for that `correlation_id`, ordered by `ts`
and then by original index. It is not a stage machine. Query composer and
equipment-identity stages are not invented. Absence of `open_retrieval` is an
absent key. Chunk text from `[PILOT_AUDIT]` is not copied into the card.

The card can show session, episode, interpreter move, goal text and
`source_correlation_id`, photo continuity, visual identity, every
`identity_promotion` in order, retrieval identity, document identity scope,
open retrieval, kept and rejected chunks, stale writes, the path, citation
count, and generation mode.

One correlation can also carry the causal chain when those events emitted it:

| Signal | Event | Meaning |
|---|---|---|
| `interpreter_assertions` | `turn_interpreter` | `act:kind:slot:applied\|ignored(reason):span`. A cut span ends with `:truncated` |
| `episode_fields_changed`, `state_before_sha256`, `state_after_sha256` | `field_companion_turn` | Real `changed_fields` and canonical episode digests. Not a snapshot |
| `query_components`, `original_sha256`, `effective_sha256` | `field_companion_turn` for a technician turn | `original_sha256` is the raw turn. `effective_sha256` is the retrieval query actually used |
| `results_count`, `contexts_delivered` | `document_identity_scope` | Chunks retrieved before scope, and chunks placed in the generation prompt. `0` is kept |
| `generation_mode`, `generation_context`, `generation_prompt_chars`, `context_truncated` | `interaction_completed` | Mode of the route that ran, and a token manifest of the prompt actually sent |
| `user_id`, `conversation_session_id` | `kb_retrieve` | Passed by the caller. A user-scoped cohort still drops an event that has no `user_id` |
| `evidence_applicability` | `open_retrieval`; `document_identity_scope` only when that event already fires | `identity_unknown_reference` when equipment identity is not confirmed. The reason stays on `outcome_reason` |

`field_companion_turn` with `result=assistant` does not store `original_sha256` or `effective_sha256`. The reply stays `TURN_EVIDENCE.answer_sha256`.

`TURN_EVIDENCE.original_query` is what the technician said on the web, worker, and photo-question lanes. The composed retrieval string stays `effective_query`. With `PILOT_AUDIT_CAPTURE` off, the raw text keys stay absent and the original hash is still the raw turn. The cohort question is not backfilled from the composed query in that case.

`generation_mode` on `interaction_completed` is the route that ran: `generative` for managed RetrieveAndGenerate, `document_identity_scope`, `meta`, `clarify_first`, `structured_evidence_route`, or the mode the photo service returned. Scope status and route distinguish shared strings. `meta_kind` is allowlisted and not emitted. `evidence_applicability` is emitted on the events in the table above. The TURN card still copies `open_retrieval` as `result` and `outcome_reason` only.

`llm_calls` on the same correlation still carry model, tokens, latency, and `token_source`. The card prints them only when the row has them.

`dossier.html` is unchanged by this contract.

## Streams, modes, and artifacts

`bin/pilot_metrics` keeps these markers:

`PILOT_USAGE`, `RAG_QUALITY`, `PILOT_AUDIT`, `TURN_EVIDENCE`,
`DOCUMENT_IDENTITY`, `RAG_REGRESSION`, `R1A_PROBE`.

`R1B_CASE_PROBE` is a JSON log without a marker. It is not in that grep.
Leave it there. Do not add it to the export.

| Mode | What it is |
|---|---|
| Normal | `[PILOT_USAGE]` plus `pilot_events`. No raw prompt, no image, no full history. `kb_retrieve` carries the caller's `user_id` and `conversation_session_id` when that caller has them |
| Forensic | `PILOT_AUDIT_CAPTURE=true` writes `[PILOT_AUDIT]` and the raw question on `[TURN_EVIDENCE]`. Not copied into `pilot_events` |
| Temporary | `R1A_PROBE` records filter and chunk decisions the gate already computed. It does not change retrieval |

Package directory: `tmp/pilot_exports/<from>_<to>_<slug>/`.

| Artifact | Role |
|---|---|
| `report.json` | Technical report, including `field_companion` |
| `report.txt` | Human rendering and the turn cards |
| `valor.json` | Value report derived from `report.json` |
| `dossier.html` | Existing dossier. Not the turn card |
| `interactions.csv` | One row per `correlation_id` |
| `source_events.jsonl` | Grepped markers above |
| `manifest.json` | Execution metadata, image tag, strict validation |
| `SHA256SUMS` | Package checksums |

`PilotTelemetryReader` merges the log and `pilot_events` and reports
`data_quality.usage_log_source` as `db`, `log`, or `db+log`. It does not
fabricate events. `[PILOT_AUDIT]` stays in the log extract only.

The export command, flags, and cohort filter stay in
[METRICS.md](METRICS.md). Session capture steps stay in
[PILOT_CAPTURE_TEMPLATE.md](PILOT_CAPTURE_TEMPLATE.md).

## Extra inserts

Compared with the previous log-only stale line and the previous open-retrieval
row:

- one `photo_continuity` insert per orchestrator execute that applies continuity
- one `identity_promotion` insert per promotion payload, after the lock
- one `stale_case_write_dropped` insert per dropped writer, after the lock
- one `document_identity_scope` insert per scope decision already in hand
- `open_retrieval` and `turn_interpreter` stay one row each; this contract adds fields

None of those inserts run inside `ConversationSession#with_lock`.

## Debugging “citó otra marca”

Read one `correlation_id` in this order:

1. `goal.text` and `goal.source_correlation_id` — which case was active, and which turn opened it
2. `visual_identity` — what the photo reading said, still only an observation
3. `identity_promotions` in order — whether that reading became an episode fact, stayed blocked, or conflicted
4. `retrieval_identity` and `document_identity_scope` — which identity constrained the manual, and whether the status was `scoped` or `no_compatible`
5. `open_retrieval` — present only when retrieval was not identity-scoped. `identity_unknown` means the Bedrock path had no known identity, and that row also carries `evidence_applicability=identity_unknown_reference`. A pin deny keeps `retrieval_denied_reason` and does not use `identity_unknown` or `evidence_applicability`
6. `execution_path` — what actually ran

A foreign manual on a `no_compatible` scope is reference context. It is not
this job's procedure.

## Checklist for a new telemetry field

1. Add the key to `PilotUsageLog::ALLOWED_FIELDS` only if it is persisted.
2. Clip strings in the caller when 500 characters is too much. Do not persist prompts, history, image bytes, secrets, or extra PII.
3. Emit through `PilotUsageLog.log` after any episode lock.
4. Rescue stays inside the log and the recorder. Do not add a job, a broadcast, or a new table.
5. Teach `field_companion` and the `TURN` card only from that event. Do not infer a missing event.
6. Cover the branch with a Minitest that does not call Bedrock or Vision.
7. Update this document. Do not add a second catalog in METRICS.md.

## Maintenance case (not implemented)

`MaintenanceCaseProjection` is specified and not built. When it exists it is a
read-only PORO over the live episode: episode id, account id, user id, facts,
identifiers, goal, observations, conflicts, active photo, document focus,
`opened_at`, `updated_at`, and status `active` or `expired`.

It does not read `pilot_events`, probes, or KEEP/DROP. It does not infer
`actions_taken` from a suggestion or from a sentence such as “revisé el
sensor”. Location, hypotheses, structured checks, resolution, `closed_at`, and
prior episodes are not on the episode today. Only one live episode is stored.

## Deliberate debt

These product behaviors are out of this contract. Prompts and ranking stay as
they are:

1. “tengo una foto, ¿te sirve?” is weakly contextual
2. Open retrieval can be too specific when identity is unknown
3. Generation can over-read weak visual evidence such as `TEST OK`
