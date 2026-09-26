# REAL_GONZALO_PRODUCTION_FLOW_AUDIT

Date audited: 2026-09-25 (America/Santiago)  
Status: COMPLETE — review only; no implementation or deployment

## Scope and evidence

This audit is deliberately limited to the real Gonzalo production flow and the
chunks retrieved by those requests. It does not review the full manual corpus.

- Primary trace export:
  `tmp/pilot_exports/2026-09-25_2026-09-25_danebo-pilot-elevator/`
  (generated 2026-09-25 21:45:44 -03:00; account 3, user 7, session 6).
- Corroboration: production session state, `BedrockQuery` rows, structured logs,
  photo cache records, upload/KB records, and the current stored chunks.
- Visual evidence: the two actual production images were downloaded by their
  stored SHA/S3 identity and inspected at original resolution.
- Original-manual inspection was restricted to the exact pages needed to verify
  MPK 708A, BL6, Fuji Yida 5%, KONE 3 mm, and KONE 20 mm.
- No production model was called. No replacement RAG was built. Current KB reads
  were used only to establish whether an indexed document exists.

Evidence limitations:

- The export reports 47 interactions, 44 attributed LLM calls, 14 complete
  answer audits, and 20 captured retrieved chunks. Three of the 17 relevant
  turns have incomplete answer/chunk payloads, so their review uses the
  production session/log record and is marked accordingly.
- The report headline says 16 audited answers, while only 14 entries contain an
  `audit` object. This is a trace-export consistency defect.
- Four `abstained` records from the earlier 15:16–15:18 batch contain no question
  or answer in the export; three also have zero LLM calls. They cannot be
  interpreted as four additional human knowledge gaps.
- Bedrock cost reconciliation was still pending for both overlapping UTC dates.
  Cost numbers below are operational/provider estimates, not the billing ledger.

## Turn ledger

| # | Production turn | Context / evidence | Claim result | Pipeline result |
|---|---|---|---|---|
| 1 | `photo:e9cea...` — spring/cable-fixing photo | Reused photo cache; image actually shows five suspension-rope terminations, threaded rods and coil springs. Vision called it a three-phase transformer. | Component identity `CONTRADICTED`; corrosion `REASONABLE_INFERENCE`; invented visible codes `UNSUPPORTED`. | `ANSWER_GENERATION_ERROR` caused by vision misidentification; downstream `RANKING_PROBLEM`. |
| 2 | `query:e4d...` — “Fuji Yida” | Active goal was spring adjustment. Retrieval returned only a redacted reference-only note identity. | “No encontré” is not a corpus-level absence. | `PARTIAL_INFORMATION_AVAILABLE`; `RETRIEVAL_MISS`/reference-body suppression. |
| 3 | `query:72eda...` — brand/model unknown | Correctly states identity is unknown, but retrieved unrelated Fuji door-edge, KOYO and Monarch material. | Uncertainty `SUPPORTED_EXPLICITLY` by user/image; useful component interpretation was missed. | `RANKING_PROBLEM`. |
| 4 | `query:a891...` — probable Fuji Yida | Continuation of same image/goal; no new visual evidence for manufacturer. | Treating Fuji as confirmed would be `UNSUPPORTED`; it must remain a user hypothesis. | Incomplete trace payload; scope retained. |
| 5 | `query:b102...` — repeated spring question | KONE N MonoSpace p.250 gives `Y = X-A-B-C`, with spring compression `C = 20 mm`. | 20 mm `SUPPORTED_EXPLICITLY` for that KONE positioning calculation, not a generic spring-adjustment value. | `CHUNK_CORRECT`. |
| 6 | `query:242729...` — ask for similar procedure | Technical note points to Fuji pp.45–46 and KONE lubrication pp.9–10. Exact original pages were checked. | Fuji equalization/5% and KONE 3 mm are `SUPPORTED_EXPLICITLY` in their respective manuals, but `CROSS_MANUFACTURER_ONLY` for the unidentified photo. | Content correct; `CITATION_MISMATCH`/weak provenance because the rendered citation points to the derived note, not each original page. |
| 7 | `query:603c...` — KONE/Fuji compatibility | Retrieved KONE documents only; there is no part-number/interface evidence establishing compatibility. | Any compatibility conclusion beyond “do not assume” is `UNSUPPORTED`. | `CHUNK_MISSING_CONTEXT`; semantic parse logged `hallucinated_spans` but the paid call still occurred. |
| 8 | `query:2ee...` — assume KONE, first action | Existing KONE procedure can be a reference only because the image/model remains unconfirmed. | KONE-specific steps are `CROSS_MANUFACTURER_ONLY`; isolate energy and inspect equivalence are `REASONABLE_INFERENCE`. | Scope caution required; full trace payload unavailable. |
| 9 | `query:3998...` — safety measures | Retrieved KONE installation and safety material. | Isolation/fall/energy-control guidance is supported at the general level; it must not imply the pictured unit is KONE. | `CHUNK_CORRECT`, with cross-manufacturer scope caveat. |
| 10 | `query:d7d...` — would another image help? | Conversational goal remained identification/adjustment of spring terminations. | Asking for a close-up/nameplate/termination view is a useful next step. | The pending visual objective was not persisted as an executable photo question. |
| 11 | `photo:81515...` — second image, no text | Image shows a lift car/door assembly inside a yellow frame; it does not show the spring terminations. Vision’s “car” is plausible; “motor/drive on top” is uncertain. | Car `REASONABLE_INFERENCE`; motor/drive `UNSUPPORTED`; relevance to prior spring goal was not answered. | Multimodal continuity failure; no RAG/generation path ran because `question.blank?`. |
| 12 | `query:4243...` — MPK 708A | Retrieved MPK/MPK708A p.1 and an MPK708C manual chunk. | “Stores up to 50 events” `SUPPORTED_EXPLICITLY` for MPK 708A. Calling 708A the main controller borrows from the 708C chunk and is `UNSUPPORTED` for 708A. | `CHUNK_CORRECT`; minor cross-model answer conflation. |
| 13 | `query:628d...` — BL6 error code | Retrieved BL6 pages 1, 3, 4, 5, 7 and 8. Original pages 1, 4 and 8 were visually checked. | Listed examples Er29–Er35, Er62, Er98 and Er99 are `SUPPORTED_EXPLICITLY`. “Er2 to Er99” is only a range shorthand; the table is not continuous. | `CHUNK_CORRECT`; duplicated citations are rendering/generation noise. |
| 14 | `query:a673...` — OTIS/LG-Sigma TCD | Stored chunks identify “DI E/L TCD LIST”, applicable model DI 60~240, revision 0, pages 4–13/13. The chunk itself says LG-Sigma/OTIS is only a filename hint and is not printed on the page. | TCD definitions `SUPPORTED_EXPLICITLY` for DI 60~240; definitive LG-Sigma attribution `UNSUPPORTED`. | Metadata/provenance limitation; answer’s caution was correct. |
| 15 | `query:40bb...` — CMC-3 no response to call | Retrieved CMC-3/VF-01 door and call-wiring chunks. | Named components/wiring rules `SUPPORTED_EXPLICITLY`; field continuity/contact checks `REASONABLE_INFERENCE`; saying all VF-01 elements are part of the call circuit `UNSUPPORTED`. | `ANSWER_GENERATION_ERROR`: manual and diagnostic inference were mixed in one evidentiary voice. |
| 16 | `query:406f...` — LCB II commissioning | Retrieved LCB II p.16 calibration, p.44 self-test, and p.4 F1. | Calibration sequence/values and M125 self-test `SUPPORTED_EXPLICITLY`; placing self-test “before energizing” is `CONTRADICTED` by its powered procedure; changing source wording from no 30 V to no 24 V is `UNSUPPORTED`. | `ANSWER_GENERATION_ERROR`; source chunks themselves are usable. |
| 17 | `query:0a790...` — LCE | Effective query was contaminated with the prior LCB II question plus “CMC-3”; answer stayed on LCB II. A complete indexed LCE document exists (asset 120, KB document 124, five chunks). | A global “LCE not found” conclusion is `CONTRADICTED`; the narrower statement “not in the retrieved LCB II manuals” is true but does not answer the user. | `WRONG_SCOPE` leading to `RETRIEVAL_MISS`. |

## Source fidelity and chunk pipeline

### Verified manual → page → chunk → answer chains

1. **MPK 708A** — `Listado Fallas MPK 708A.pdf`, p.1 → MPK 708A
   chunk → retrieved by `query:4243...` → answer says “hasta 50 eventos”.
   Result: `CHUNK_CORRECT`, claim explicitly supported.
2. **BL6** — `codigos error BL6.pdf`, especially pp.1, 4 and 8 → BL6
   chunks → retrieved by `query:628d...` → example-code answer. Result:
   `CHUNK_CORRECT`.
3. **Fuji Yida** — `manual en castellano yida.pdf`, pp.45–46 → source
   material represented through the suspension technical note → retrieved by
   `query:242729...` → equalization and maximum 5%. Result: factually correct,
   but the citation chain is indirect.
4. **KONE tension** — `lubricacion cables.pdf`, pp.9–10 → technical note →
   retrieved by `query:242729...` → maximum 3 mm difference between longest and
   shortest terminal-spring lengths. Result: supported, indirect citation.
5. **KONE geometry** — `SPT AM-01 01 255 en A CHINO.pdf`, PDF p.250
   (printed p.249) → KONE N MonoSpace chunk → retrieved by `query:b102...` →
   `C = 20 mm`. Result: `CHUNK_CORRECT`; this is a positioning formula, not a
   universal adjustment specification.
6. **LCE** — indexed asset `KONE V3F18 MX05 MX06 MX10 - parametros LCE
   p515.pdf` → five stored chunks identifying LCE 813131 and its configuration
   groups/parameters → not retrieved for `query:0a790...` because the composed
   query remained dominated by LCB II/CMC-3. Result: `RETRIEVAL_MISS` caused by
   `WRONG_SCOPE`, not missing knowledge.
7. **LG-Sigma/TCD** — `Enviando OTIS+(Codigos+LG-SIGMA)-2.pdf` → 20 indexed
   chunks → TCD table for DI 60~240. Result: code table is usable, but the page
   evidence does not establish the LG-Sigma manufacturer/product mapping.

### Pipeline diagnoses

- `CHUNK_CORRECT`: MPK 708A event count, BL6 codes, KONE 20 mm, Fuji 5%,
  KONE 3 mm, LCB II calibration/self-test text, CMC-3 component descriptions.
- `CHUNK_MISSING_CONTEXT`: compatibility request and LG-Sigma identity mapping.
- `WRONG_METADATA`: not proven for the numeric/code content; LG-Sigma is a
  filename-derived alias and must not be promoted to page evidence.
- `RETRIEVAL_MISS`: Fuji-specific spring request and LCE.
- `RANKING_PROBLEM`: the first image flow retrieved Fuji door-edge and unrelated
  controller material after the component was misidentified.
- `CITATION_MISMATCH`: Fuji/KONE facts cite an internal derived note instead of
  the original manuals/pages; BL6 citation numbers are duplicated.
- `ANSWER_GENERATION_ERROR`: first-photo identity/usefulness, CMC-3 provenance
  mixing, LCB II sequencing/source rewrite, and the LCE non-answer.

## “No encontré” audit

Within the requested real flow:

| Turn | Classification | Reason |
|---|---|---|
| Initial spring-photo request (`photo:3a46...`) | `PARTIAL_INFORMATION_AVAILABLE` | The corpus contained relevant Fuji/KONE analogous evidence, but no chunks were retrieved and the exact unit was unidentified. |
| Fuji Yida continuation (`query:e4d...`) | `PARTIAL_INFORMATION_AVAILABLE` + `RETRIEVAL_MISS` | A technical note existed and later exposed the 5%/3 mm evidence; only its redacted reference identity reached generation. |
| CMC-3 diagnostic (`query:40bb...`) | `PARTIAL_INFORMATION_AVAILABLE` | The answer explicitly had component/wiring evidence but no manufacturer-authored diagnostic sequence. Marking the whole turn abstained hides that partial support. |
| LCE response | `WRONG_SCOPE` + `RETRIEVAL_MISS` | It was not rendered as the canned “no encontré”, but functionally claimed absence from the retrieved scope despite an indexed LCE document. |

There is no demonstrated `TRUE_NOT_FOUND` among these relevant turns. Four
earlier export records classified as abstentions lack the question/answer
payload required for a defensible semantic classification and are outside the
user-narrowed consultation scope.

## Image audit and multimodal continuity

### First image

The actual image clearly shows five elevator suspension-rope terminations with
wedge/socket bodies, long threaded rods, nuts and coil springs behind mesh. The
cached vision record called it a three-phase transformer and produced garbled
codes from an upside-down/obscured label. This is a material vision error, not a
reasonable alternative identification. The RAG answer then trusted that error
and rejected the spring-adjustment intent.

Safe observations Danebo could have made without a manufacturer procedure:

- compare spring lengths and nut/thread positions across equivalent assemblies;
- flag visible asymmetry, corrosion, deformation, loose/missing hardware;
- state that stored mechanical energy and suspension work require isolation and
  the applicable field safety controls;
- ask for the nameplate, model and a closer termination view;
- avoid torque, turns, target tension, exact height or transfer of Fuji/KONE
  values until identity is confirmed.

### Second image

The image plausibly shows a lift car/door assembly in a yellow frame. It does
not show the spring/cable terminations. The useful answer was therefore: this
image does not expose the target assembly; provide a close-up of the five
terminations/nameplate. Instead, Danebo emitted a standalone generic photo
description.

Root cause trace:

1. The active episode/goal was still about the spring/cable fixing.
2. The upload carried an empty text question.
3. `QueryOrchestratorService` passed that empty question to
   `FieldPhotoAnalysisJob`.
4. Vision received the image but no active goal/history/pending question.
5. The job records the photo observation, but invokes
   `Rag::PhotoQuestionAnswerService` only when `question.present?`.
6. With a blank question, it broadcast `photo_analyzed` and never executed RAG
   or a goal-aware renderer.

Classification: **context not passed / prompt-orchestration contract**. The
episode goal was not deleted; it was simply not consumed. RAG and renderer did
not get an opportunity to preserve continuity.

## Cost and token accounting

Daily export totals currently shown:

- 42 Haiku generation calls + 2 Sonnet visual calls = 44 attributed calls.
- 378,549 input tokens; 16,752 output tokens.
- USD 0.483961 attributed (`0.328207` provider usage + `0.155754` estimated).
- One photo-cache hit avoided an estimated USD 0.009603 visual call.
- Bedrock billing reconciliation: pending; therefore these totals are not the
  cost authority.

The semantic analyzer is a separate paid Haiku `converse` call. It logs
`haiku_query_analysis_shadow`, including tokens/latency/cost, but does not create
a `BedrockQuery`/cost row. For the 16 traced requests in the 20:22–20:43 flow,
these omitted calls add:

- 16 paid Haiku calls;
- 22,896 input tokens and 1,719 output tokens;
- 22,859 ms aggregate service latency;
- USD 0.031491.

This is a confirmed dashboard omission. It is not double counting: the 44
reported rows correspond to answer-generation/vision calls; the semantic calls
are absent. `hallucinated_spans` semantic outcomes are still paid and must be
counted. The second visual row correctly includes cache-creation tokens in its
`BedrockQuery` cost; the legacy `photo_completed.original_cost` does not.

Representative real-request totals:

| Request | Paid calls | Tokens | Service latency | Cost |
|---|---|---|---|---|
| Normal text: MPK 708A (`query:4243...`) | semantic Haiku + Haiku answer | 9,554 in / 362 out | 7,013 ms | USD 0.011364 |
| Switch/correct: CMC-3 (`query:40bb...`) | semantic Haiku + Haiku answer | 6,733 in / 462 out | 9,148 ms | USD 0.009043 |
| Image with question/cache hit (`photo:e9cea...`) | cached vision USD 0 + semantic Haiku + Haiku answer | 10,412 in / 529 out for paid calls | 8,132 ms | USD 0.013057 |
| Second image alone (`photo:81515...`) | Sonnet vision | 1,430 in / 360 out + 1,172 cache-creation tokens | 9,291 ms | USD 0.014085 |

No additional paid model call was found for the blank second-photo upload.

## Field-companion quality

Strengths:

- MPK, BL6 and the qualified Fuji/KONE reference answer preserve useful source
  values and generally avoid inventing torque/setpoints.
- The system often states when an exact procedure is unavailable.
- The KONE 20 mm answer correctly distinguishes a positioning calculation from
  a general adjustment procedure.

Material weaknesses:

- It sometimes behaves like a document search result instead of first answering
  the technician’s immediate observation/next-step need.
- It over-trusts visual identification and underuses conservative mechanical
  reasoning available directly from the image.
- It mixes manufacturer text and field inference without explicit labels
  (CMC-3) and promotes a valid procedure into an invalid sequence claim (LCB II).
- “No encontré” is emitted after a top-k/reference filtering miss, even when
  partial or analogous evidence exists.
- Conversational scope can accumulate prior equipment identifiers, producing a
  wrong-equipment retrieval query (LCE).

The guardrails are too restrictive around low-risk observational reasoning and
not strict enough around provenance boundaries. The intended hierarchy should
be rendered explicitly:

1. `MANUFACTURER_DOCUMENTATION`
2. `CROSS_MANUAL_EVIDENCE` (named source + page + non-transfer disclaimer)
3. `GENERAL_MECHANICAL_REASONING` (observation/check, no invented values)
4. `UNKNOWN` (specific question that would resolve it)

## Recommended plan

### PHASE_1 — Preserve photo intent with the existing visual call

- **Goal:** a photo uploaded after “would another image help?” must answer whether
  it helps with the active spring/cable goal.
- **Root cause:** blank photo text bypasses the goal-aware RAG path, and the
  existing vision prompt receives no bounded active goal/pending question.
- **Smallest change:** pass a bounded `photo_intent` derived from the active
  episode goal/most recent pending image request into the existing vision call;
  require structured `relevance_to_goal`, `target_visible`, and
  `missing_view_or_detail`. On blank photo text, render those fields instead of
  an unrelated standalone description. Do not add a model call.
- **Tests:** job/service tests for blank-question + active photo intent, no active
  intent, stale intent, cache hit, and explicit new photo question.
- **Real-flow replay:** replay the stored episode state plus the two actual photo
  fixtures; assert the second response says the spring terminations are not
  visible and requests the correct close-up. Assert one visual call only.
- **Complexity:** small/medium; existing job/prompt/episode seams are sufficient.

### PHASE_2 — Separate scope and provenance in retrieval/answers

- **Goal:** prevent old equipment names from contaminating a new named-equipment
  question and distinguish manual facts, analogous manuals, mechanical
  reasoning and unknowns.
- **Root cause:** elliptical composition treats the self-contained LCE question
  as a continuation; generation has no enforced per-claim provenance boundary.
- **Smallest change:** deterministic self-contained-equipment reset before query
  composition; keep current model/retrieval calls. Add output contract labels for
  manufacturer evidence vs inference and make “no encontré” reflect
  request-scope/partial evidence, not top-k absence.
- **Tests:** exact replays for LCE, CMC-3, LCB II and Fuji/KONE; assert LCE chunks
  are retrieved, CMC inference is labeled, and powered self-test is not placed
  before energization.
- **Real-flow replay:** use captured production questions/chunks/answers; no new
  synthetic production calls.
- **Complexity:** medium.

### PHASE_3 — Make paid-call and evidence telemetry complete

- **Goal:** every paid call and every final answer has one correlation-linked
  accounting/evidence record.
- **Root cause:** `SemanticQueryAnalyzer` calls Bedrock `converse` directly and
  only logs a shadow event; some turns lack exported question/answer/chunks.
- **Smallest change:** record semantic calls through the existing cost/query
  tracking seam (or a dedicated paid-call record), including provider tokens,
  cache tokens, latency and estimated/reconciled cost. Export a stable turn ID,
  effective query, retrieved chunk IDs and final answer for every route.
- **Tests:** totals include semantic success and `hallucinated_spans`, do not
  double-count generation/vision/cache hits, and reconcile exact captured flow
  fixtures.
- **Real-flow replay:** expected incremental 16 calls, 22,896 input, 1,719 output
  and USD 0.031491 for the audited 20:22–20:43 semantic events.
- **Complexity:** medium.

## Final disposition

- `ARCHITECTURE_CHANGE_REQUIRED`: **NO**
- `NEW_MODEL_CALL_REQUIRED`: **NO**
- `ENTITY_PROJECTION_REQUIRED`: **NO**
- `NEXT_ACTION`: **IMPLEMENT_PHASE_1**
