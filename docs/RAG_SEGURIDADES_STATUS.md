# RAG SEGURIDADES — Current Status

**Updated:** 2026-07-26
**Status:** PILOT_GATE_MET (12/12, rubric v3.2)
**Purpose:** single checkpoint for continuing RAG precision work on
`SEGURIDADES 1.1-1` without rereading the historical plans.
**Plans closed by this checkpoint:**
`/Users/lahirisan/.cursor/plans/precisión_definitiva_rag_seguridades_d017baca.plan.md`
(F8 of `/Users/lahirisan/.cursor/plans/precisión_quirúrgica_rag_citas_55e8379c.plan.md`),
`/Users/lahirisan/.cursor/plans/precisión_final_y_trazabilidad_d077fc82.plan.md`

## Instructions for any AI

Read only:

1. `AGENTS.md` and the scoped `AGENTS.md` for files you will touch.
2. This file.
3. The code/tests directly related to the next action.

Do not re-run a full document re-ingestion, do not reopen completed work, and do
not treat the dated benchmark reports as the current contract.

## Gate result — 2026-07-26 (final)

Artifacts: `tmp/rag_seguridades_benchmark_2026-07-26_v32_final.json` (12 answers),
`tmp/rag_seguridades_evaluation_2026-07-26_final_v32.json` (rubric v3.2 scoring).

| Run | Passed | Score | Canned "Sorry" |
|---|---|---|---|
| Baseline (2026-07-23) | 3/12 | 22/62 | — |
| Surgical F1–F4 (2026-07-23) | 7/12 | 62/88 | 0 |
| Post re-ingestion (2026-07-25) | 7/12 | 57/88 | 2 |
| Gate run (2026-07-26, rubric v3.1) | 11/12 | 80/88 | 0 |
| **Final (2026-07-26, rubric v3.2)** | **12/12** | **83/88** | **0** |

Pilot gate (≥10/12, 0 canned "Sorry", native citations on every generative
answer, no case below its 2026-07-26 score): **exceeded**. All 12 answers carry
native citations; the only movement against the previous run is `thyssen_e_led`
4→5.

Per-case (v3.2): `altius_d8` 7/7, `tpr70_epc_b8` 8/9, `kdt_evo_presostato` 6/7,
`mr08_sci` 8/9, `edel_k2_c2` 6/7, `em3000_fotocelula_220v` 5→7/7,
`em2000_contradiccion` 11/11, `tokibat_dl27` 7/7, `thyssen_e_led` 4→5/5,
`cerrojos_generica` 7/7, `torque_ausente` 4/5, `indice_carlos_silva` 7/7.

The 5 remaining points are optional-claim points on passing cases
(`tpr70_epc_b8`, `kdt_evo_presostato`, `mr08_sci`, `edel_k2_c2`,
`torque_ausente`), not failures.

## What changed

**1. Production fix — the generation prompt must end with the output contract.**
`BedrockRagService::OUTPUT_FORMAT_PLACEHOLDER` (`$output_format_instructions$`)
is now lifted out of the static template and re-emitted last, after every dynamic
directive (language header/footer, delivery channel, safety/completeness/visual
directives). Verified against the production KB: with the delivery-channel and
language-reminder blocks emitted *after* the placeholder, `retrieve_and_generate`
discarded the generated answer and returned
`"Sorry, I am unable to assist you with this request."` even with valid retrieval
(3 and 5 chunks). This was the systematic cause of both canned refusals, not a
stochastic guardrail. A/B evidence: same retrieval config, custom template →
canned; template truncated at the placeholder or placeholder moved last → real
cited answers. Tests: `test/services/bedrock_rag_service_test.rb`
("rendered generation prompt keeps output_format_instructions as the last block",
"…closes with the output contract on the minimal path").

**2. Content patch — `chunk_9.txt` (page 11, HIDRA-TPR70).**
`script/patch_seguridades_chunk9_2026-07-26.rb` (PutObject + one KB ingestion job,
zero Claude calls; job `VR2R7FQHZU`, status COMPLETE). The `field_records_v5`
extraction had asserted a 1:1 terminal→component mapping on B7/B8; the diagram
wires shared series chains and 2-pole devices. Verified visually against
`tmp/seguridades_reingest_2026-07-25/page11_b7_crop.png` /
`page11_b8_crop.png`:

- B7 terminals 1–2: series chain LIMITADOR → FINALES → STOP FOSO → POLEA TENSORA.
- B7 terminal 3: PUERTAS EXTE. (return shares the common wire with terminal 2).
- B7 terminals 4–5: CERROJOS EXTERIORES (EPE), 2-pole device.
- B8 terminals 1–2: series chain ACUÑAMIENTO → AFLOJA CABLES → BOTO. REVISION → STOP REVISION.
- B8 terminals 3–4: PUERTAS CABINA MANUALES — the physical component of the EPC
  (SERIE CERROJOS CABINA) series. The pre-patch chunk claimed terminal 5.
- B8 terminals 5–6: CERROJOS EMBARQUE 1 → CERROJOS EMBARQUE 2 **in series**.
  The prepared correction file had claimed one device per terminal; this was
  corrected during execution after independent inspection of the green wiring.

Rollback: re-upload `tmp/seguridades_reingest_2026-07-25/chunk_9_current.txt`
(sha `f9a93d97…`) to the same key and resync. The bucket has no versioning;
`tmp/seguridades_reingest_2026-07-25/backup_chunks/` holds the pre-25-jul objects.

**3. Ingestion guardrail (future documents only) — `field_records_v6`.**
`BatchChunkingPrompt` now forbids a 1:1 component assignment on a numbered
terminal block: series chains and 2-pole devices must be emitted as a terminal
range with `REQUIRES_FIELD_VERIFICATION` on the exact order. Bumping
`INGESTION_CONTRACT_VERSION` does **not** re-parse the 97 already-indexed chunks
(`ContentDedupService` only reacts to a new upload).

**4. Rubric `seguridades-v3.1`** (`script/fixtures/rag_seguridades_rubric.json`).
Patterns only — no check added or removed, `max_score` still 88. Fixed four
lexical artifacts, each validated against a negative control (the known-bad
phrasing must still fail): `tokibat_dl27` required accepted only
"no define/documenta/incluye" (real answers say "no especifica"/"no declara") and
its penalized check fired on the hypothetical clause "si se enciende cuando…";
`em2000_contradiccion` required did not accept "discrepancia" or
"encabezado … diagrama"; `tpr70_epc_b8` required demanded a specific LED phrasing
and its penalized check flagged any B7/B8 mention (now: EPC's component must be
located at terminal 3–4, and only a disproven terminal is penalized);
`thyssen_e_led` penalized fired on a restatement of the question inside a correct
abstention (now requires an assertive LED-identifier attribution).

**5. Benchmark tooling.** `RAG_SEGURIDADES_CASE_IDS` filters both the runner and
the standalone evaluator (including the rubric handed to
`Rag::BenchmarkRubricEvaluator`, so filtered runs do not report phantom
`missing_result` failures).

**6. Content patch — `chunk_91.txt` (page 93, THYSSEN SERIE E).**
`script/patch_seguridades_thyssen_p93_2026-07-26.rb` (PutObject + one KB ingestion
job, zero Claude calls; job `C6E6UC5RPT`, status COMPLETE). The brand token was
printed only on divider page 92 (`chunk_90.txt`), so no brand-named query could
reach page 93 even though that page carries the L9/L8/L7 → supervised-series
table. Verified visually against the PDF before the write
(`tmp/seguridades_thyssen_2026-07-26/page-92.png`, `page-93.png`,
`p93_led_table.png`): page 92 is the "THYSSEN" divider, page 93 is titled
"SERIE E".

The patch touches only the `[SEARCH_ALIASES: …]` line — the body is byte-identical,
so no technical claim changed. Alias count stays at `CHUNK_ALIAS_LIMIT` (8): the
brand tokens `THYSSEN, THYSSEN-E` replaced `POLEA TENSORA, CERROJOS CABINA`, both
of which already appear verbatim in the body. Result: page 93 now retrieves for
"En Thyssen-E, ¿qué LED…?", and the answer names L9/L8/L7 with their series while
still abstaining on the ON/OFF logic the page genuinely does not document.

Rollback: re-upload `tmp/seguridades_thyssen_2026-07-26/chunk_91_live_backup.txt`
(sha `695b8695…`) to the same key and resync. The script is idempotent and aborts
if the live SHA no longer matches.

**7. Rubric `seguridades-v3.2`** (`script/fixtures/rag_seguridades_rubric.json`).
Patterns only — no check added or removed, `max_score` still 88. Three lexical
artifacts, each paired with a negative control now locked as a test in
`test/services/rag/seguridades_rubric_calibration_test.rb` (offline, zero Bedrock):

- `em3000_fotocelula_220v` required accepted only the feminine "ambas/las dos/cada
  una"; the answer covers both diagrams as "ambos diagramas". Negative control:
  single-diagram coverage still fails. (User-authorized recalibration.)
- `thyssen_e_led` optional accepted only "LED9"/"DL27"; the post-patch answer names
  the documented identifiers as "L9 / L8 / L7". It now shares the identifier
  lexicon of its own penalized check. Negative control: an answer naming no LED
  does not score, and the penalized check still fires on an unsupported
  normal/fault attribution.
- `tokibat_dl27` penalized used the fixed-width lookbehind `(?<!si )`, so a correct
  abstention phrased "el documento no declara **si el LED** se enciende cuando …
  fallo" was scored as an invention. It now fires only on a sentence carrying no
  negation or hypothesis marker. Negative control: a real assertion
  ("DL27 se enciende cuando … fallo") is still penalized.

**8. Ingestion guardrail (future documents only) — `field_records_v7`.**
Section identity now propagates structurally, closing the failure class the page-93
patch fixed by hand:

- `BatchChunkingPrompt` emits top-level `section_identity` only when a page visibly
  opens a new brand/controller-family section, copied verbatim from visible text —
  never inferred, and never allowed to change `document_name`.
- `ChunkMergerService` carries the last declared identity forward, in page order,
  into every following page's chunk aliases until another page declares a new one.
  It leads the alias list so it survives `CHUNK_ALIAS_LIMIT`, is not duplicated on
  pages that already name the brand, and a prose-length value is dropped instead of
  propagated.
- `BatchResultsParserService` writes it into the `[SEARCH_ALIASES: …]` line and as a
  `section_identity` sidecar attribute.

Bumping `INGESTION_CONTRACT_VERSION` does **not** re-parse the 97 already-indexed
chunks (`ContentDedupService` only reacts to a new upload). This does not fix
SEGURIDADES retroactively — item 6 did that.

**9. `KbDocument` backfill.** `script/backfill_seguridades_kb_document_2026-07-26.rb`
is idempotent, database-only, and verifies the row through
`RecentKbDocumentsQuery`. It has NOT run yet: the local development database has
accounts `[4, 5]`, no account 1, so the script correctly aborts. See the "Open"
list — the account scoping has to be settled first.

Verification: full Minitest suite **1562 runs, 4775 assertions, 0 failures,
0 errors, 188 skips**; `bin/rubocop` clean on the touched files.

## Production identifiers

- KB `Y7RZWMFJSR` (`danebo-rag-prod`) / data source `PJ0N58DMHG`, region `us-east-1`.
- Bucket `multimodal-source-destination`, `account_id: 1`,
  `document_uid: b61f5d54-ff42-414a-97b7-01682d16f4b5`.
- Chunk prefix `bulk_chunks/1/b61f5d54-ff42-414a-97b7-01682d16f4b5/` (97 objects).
- `.env` points at the **dev** KB; every benchmark/patch command must override
  `KNOWLEDGE_BASE_S3_BUCKET`, `BEDROCK_KNOWLEDGE_BASE_ID`,
  `BEDROCK_BULK_DATA_SOURCE_ID`, `BEDROCK_DATA_SOURCE_ID`.

## Closed — do not repeat

- **No full re-ingestion of `SEGURIDADES 1.1-1`** without explicit user
  authorization. It ran twice (23-jul, 25-jul, ~98 Claude calls each) and the
  second run *lowered* precision (62/88 → 57/88). Any future correction is a
  single-chunk patch.
- The shared/chained-terminal guardrail is already in the ingestion prompt (v6);
  do not re-derive it.
- Section/brand propagation already lives in the ingestion contract (v7):
  prompt marker → `ChunkMergerService` carry-forward → alias line + sidecar. Do
  not re-derive it, and do not add a Rails heuristic that guesses a brand from a
  board code.
- **Do not widen the pinned-document `top_k` for comparative wording.** Measured
  against the production KB on 2026-07-26 and rejected: `PINNED_COMPARISON_RESULTS
  = 6` on "Compara las dos fotocélulas…" took `em3000_fotocelula_220v` from 5/7 to
  **0/7**. At top-k 3 the retriever already returned both target pages (29 and 30),
  so recall was never the bottleneck; top-k 6 added four off-topic pages and the
  answer volunteered an unrelated 24 V obstacle connector, tripping a critical
  penalized check. The real gap was the rubric lexicon, fixed in v3.2. The
  regression guard lives in `test/services/rag_retrieval_profile_test.rb`.
- Do not add a retry for `canned_with_retrieval`. The refusal was systematic
  (prompt assembly order), and the root cause is fixed; a retry would have paid
  for a second identical failure.
- Do not add text after `$output_format_instructions$` in any generation prompt
  path. That is the third time this contract broke generation (first the
  `</DOC_REFS>` stop sequence, then the `<DOC_REFS>` block, now trailing blocks).

## Open — blocks the technician UI, not the pilot gate

**The document is invisible in the UI, and the fix is an account decision, not a
missing row.** Every indexed chunk sidecar carries `account_id: "1"`, and
`BedrockRagService#account_filter` hard-filters retrieval on `@account.id`. So only
a session whose account **is** id 1 can retrieve this document. The local database
has accounts `[4, 5]`; no account 1 exists, which is why no `KbDocument` row was
ever found and the benchmark had to resolve the document through its
`external_document` path (`document.id` recorded as `null`).

`account_id = 1` was a hardcoded literal in
`script/reingest_seguridades_2026-07-25.rb`, not a real tenant. Two ways out, both
needing a decision:

1. The pilot database has (or gets) account 1 → run
   `script/backfill_seguridades_kb_document_2026-07-26.rb` there and the row, the
   home listing, pinning, and the benchmark's `document.id` all resolve.
2. The pilot account is 4 or 5 → the chunk sidecars' `account_id` must be rewritten
   to that id and the KB resynced (a metadata-only pass over 97 sidecars, zero
   Claude calls). Do NOT instead create the catalog row under another account: the
   PDF would list in the UI and then retrieve nothing.

The backfill script refuses to run when account 1 is absent and prints exactly
this reasoning.

## Next action

Decide which account owns SEGURIDADES 1.1-1 in the pilot database (options above),
then run the backfill in that environment. No further precision work is required
for the gate; if it resumes, verify single cases with `RAG_SEGURIDADES_CASE_IDS`
instead of spending a full 12-case run.

## Start a new AI conversation

Paste this:

```text
Work in /Users/lahirisan/smart_deal. Read AGENTS.md and
docs/RAG_SEGURIDADES_STATUS.md only. Check git status. The SEGURIDADES pilot
gate is MET (12/12, 83/88, 0 canned "Sorry", native citations everywhere) with
rubric seguridades-v3.2. Do NOT re-ingest SEGURIDADES 1.1-1, do not add text
after $output_format_instructions$ in the generation prompt, do not add a retry
for canned_with_retrieval, and do not widen the pinned-document top_k for
comparative questions (measured regression). Benchmark/patch commands must
override the production KB env vars (.env points at dev). Verify single cases
with RAG_SEGURIDADES_CASE_IDS before spending a full 12-case run. The open item
is which account owns the document (chunks are scoped to account_id=1).
```
