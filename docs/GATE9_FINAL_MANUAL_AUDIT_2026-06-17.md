# Gate 9R Final Manual Run — FASE I Audit

## Post-audit remediation status

The surgical review findings were fixed before any real PDF/API execution:

- paid execution now requires a positive budget, an explicit dedicated-workspace
  `ANTHROPIC_API_KEY`, and an explicit isolated-input S3 bucket;
- preflight rejects unreadable PDFs and manuals over the 200-page L2 limit;
- failed results, degraded pages, raw stop reasons, filter usage, and retry causes
  survive resume and Phase IV;
- retry anchor/total use the complete kept-page set;
- evidence-contract structure is validated instead of hardcoded;
- observed/no-cache cost gates include embeddings and the correct filter repricing;
- Phase IV only accepts `awaiting_human_review` and can locate the sole pending
  artifact without requiring the PDF environment variable;
- waiting batches remain resumable and are not reported as complete.

**Execution route:** the canonical Gate 9R run is operator-only through
`script/gate9_final_manual.rb`. It is **not** uploaded through `/bulk_uploads`
or web/chat because both production paths proceed to KB indexing. Application
upload is validated only after this isolated gate is closed.

**Branch:** `codex/o4b-ingestion-noise-reduction`
**Date:** 2026-06-17
**Auditor target:** external AI code review before FASE II/III execution

---

## 1. Original Plan Document

The Gate 9R Final Manual Run Specification (canonical v3) was provided as a **direct conversation prompt** — it is not committed to the repository.

Related repo documents that form the evidence base and cost baseline:

| File | Purpose |
|------|---------|
| `docs/GATE9_V1_2026-06-12.md` | Historical Gate 9R V1 run record (B.1 fail 2026-06-12, B.5.1 pass 2026-06-16, batch `msgbatch_01Eg3ipW6tqLPxeszNfuDTQ2`, cost $0.829595) |
| `docs/SAAS_COST_MODEL_2026-06-12.md` | Measured cost baseline for 200pp manual batch path ($9.0547 expected from 24-page v3 cohort) |
| `docs/INGESTION_COST_V2.md` | Full ADR + cost matrix for web ingestion pipeline |
| `docs/INGESTION_ROUTING.md` | Routing reference for `CustomChunkingPipeline` |
| `docs/project_o1_gate_phase.md` | O1 and O5 gate phase tracking |

---

## 2. What "Canonical v3" Is

The spec label "Gate 9R Final Manual Run Specification, canonical v3" refers to the **third revision** of the Gate 9R run specification. Each version layered on the prior:

- **v1** — original Gate 9R spec for the V1 run (B.1, 2026-06-12). Quality gate failed: missing platform-control emergency-stop procedure. Run record in `docs/GATE9_V1_2026-06-12.md`.
- **v2** — post-B.5.1 spec revision after the B.2–B.5.1 quality chain resolved safety-coverage regressions.
- **v3 (canonical)** — incorporates all closed gate work into a single definitive run specification:

| Gate | Commit | Change |
|------|--------|--------|
| O3′ | (O3-prime series) | Universal 8k initial token cap (`WEB_PAGE_MAX_TOKENS=8000`); eliminates truncate-then-retry double billing at 4k |
| O4b-A | `4561640` | Deterministic cleanup (CERRADO) |
| O4b-B | `9f95de3` | Field photo content signal + image compression telemetry |
| O5-A | `44c9e9a` | Anchor content page roles (CERRADO) |

Additional v3 inclusions:
- `field_records_v4` as the ingestion contract version
- `manual_batch_v1` as the ingestion path for this run
- Full cost optimization stack from CLAUDE.md: inference profile `global.anthropic.claude-haiku-4-5-20251001-v1:0`, `RagRetrievalProfile`, `stop_sequences: ["</DOC_REFS>"]`, language injection reduction, RULE 8 compaction, `SessionContextBuilder::MAX_CONTEXT_CHARS=2000`

The "v3" is the **spec version**. The ingestion contract is separately versioned as `field_records_v4`. The ingestion path for this run is `manual_batch_v1` (distinct from `web_v1` used by normal chat uploads).

---

## 3. FASE I — What Was Implemented

FASE I delivers the $0 harness (zero real API calls, zero KB writes). Three files created:

### `app/services/gate9_final_manual.rb`
~1 300-line PORO harness. Phases:

| Method | Phase | Cost |
|--------|-------|------|
| `run_preflight!` | II — 7-check preflight | $0 |
| `do_submit!` | III — submit Batch API job | paid |
| `do_poll!` | III — poll batch status | $0 |
| `do_stream!` | III — stream results to `results.jsonl` | $0 |
| `do_retry!` | III — direct-API retry for `max_tokens`/invalid-JSON pages | paid |
| `do_merge_parse!` | III — merge chunks + parse to MemoryS3 | $0 (no S3/KB writes) |
| `do_measure!` | III — compute cost ledger, quality metrics | $0 |
| `run_verdict!` | IV — record human review verdict | $0 |

Key invariants enforced by the harness:
- **Never resubmit** — resumes by batch_id from `state.json`
- **Zero KB sync** — `MemoryS3` in-memory stub; no `BulkKbSyncService`, no `BedrockIngestionJob`, no `S3DocumentsService`
- **Atomic state** — writes via `File.write(tmp) + File.rename(tmp, state_path)` (crash-safe)
- **Budget gate** — `GateFailure` if `l2_no_cache > GATE9_FINAL_BUDGET_USD`
- **Cost gate** — verdict `"failed"` if `l2_observed > 10.0` OR `l2_no_cache > 12.0`
- **L2 not publishable** while `human_review_verdict` is nil
- **Anti-loop** — if gate fails: diagnose offline on retained artifact; never re-execute the same inference

Important constants:
```ruby
VERSION            = "gate9-final-3"
contractual_max    = Gate9CostMatrix.new.report.dig(:contractual_max, :manual_200pp)
PRICING            = Gate9CostMatrix::PRICING.freeze
```

Bug fixed during FASE I: `run_verdict!` now calls `load_metrics_from_output!` at the end so `build_output_json` does not overwrite the verdict with nil `@quality`.

### `script/gate9_final_manual.rb`
Runner for `bin/rails runner`. Dispatches to `Gate9FinalManual.new.run!` inside an explicit `begin/rescue/end` block with typed error handling (`PreflightError`, `GateFailure`, `AbortError`).

Environment variables:
```
GATE9_FINAL_MANUAL=<abs-path-to-pdf>         # required for II/III
GATE9_FINAL_EXECUTE=true                     # activates paid path (III)
GATE9_FINAL_BUDGET_USD=<max>                 # e.g. 12.0
GATE9_FINAL_MAX_RETRY_PAGES=1                # retry ceiling
ANTHROPIC_API_KEY=<workspace-key>            # required for paid path
BEDROCK_RERANKER_ENABLED=false               # required
QUERY_ROUTING_ENABLED=false                  # required
GATE9_FINAL_VERDICT=pass|fail                # Phase IV only
```

### `test/services/gate9_final_manual_test.rb`
39 tests ($0, no real API calls), including all canonical cases plus the
post-audit paid-guard, page-limit, resume-integrity, Phase-IV, and evidence-contract regressions.
Core spec cases covered:

| # | Test | Phase |
|---|------|-------|
| 1 | Preflight: git dirty → PreflightError | II |
| 2 | Preflight: reranker enabled → PreflightError | II |
| 3 | Preflight: query routing enabled → PreflightError | II |
| 4 | Preflight: WEB_PAGE_MAX_TOKENS ≠ 8000 → PreflightError | II |
| 5 | Resume: in-progress batch → exits at "waiting" without resubmit | III |
| 6 | Dedup hit → PreflightError | II |
| 7 | Scanned fraction ≥ threshold → PreflightError | II |
| 8 | Full clean run: status="awaiting_human_review" | III |
| 9 | Retry triggered: max_tokens page → retried, retry_cost > 0 | III |
| 10 | Budget exceeded → GateFailure | III |
| 11 | KB sync NOT called: MemoryS3 used, no BulkKbSyncService/BedrockIngestionJob/S3DocumentsService | III |
| 12 | Atomic state: state.json readable mid-run | III |
| 13 | `submitting` without batch_id → AbortError (no resubmit) | III |
| 14 | Cost gate: l2_observed > 10 → verdict "failed" | III |
| 15 | Cost gate: l2_no_cache > 12 → verdict "failed" | III |
| 16 | Timeout → status="waiting" (not "failed"), clean exit | III |
| 17 | Phase IV: GATE9_FINAL_VERDICT=pass → output.json updated | IV |
| 18 | Phase IV: invalid verdict → PreflightError | IV |
| 19 | (sub) Retry ceiling exceeded → GateFailure | III |
| 20 | (sub) state_consistency check: sha mismatch → AbortError | III |

Key test infrastructure:
- `FakeBatchClient` — fake `ClaudeBatchClient` with configurable results and poll status
- `FakeS3Client` — no-op S3
- `build_fake_pdf_binary(page_count)` — HexaPDF-backed valid PDF for tests
- `with_clean_run_stubs` — nests: `stub_git_clean`, `stub_dedup_miss`, `stub_scanned_zero`, `stub_filter_keep_all`, `stub_track_job`
- All stubs use `define_singleton_method` save+restore pattern; no Mocha

---

## 4. Cost Estimates for the Actual Run

From `docs/SAAS_COST_MODEL_2026-06-12.md` (measured 24-page v3 cohort):

| Scenario | Pages | Est. Cost |
|----------|-------|-----------|
| **Observed L2 batch run (2026-06-18)** | 168 kept | **$5.4434** |
| Full 200pp batch (projection) | 200 | $9.0547 |
| Proportional 136pp (projection) | 136 | ~$6.16 |
| Contractual max (200pp full-Opus no-cache) | 200 | $2712.18 |

The observed run (retained batch `msgbatch_017UYaG9fXBGkovuE6ENmaRv`, 168 kept
pages, 0 failed, 0 Opus pages) is harness-computed and **not yet reconciled**
against the Anthropic invoice — see `docs/GATE9R_STATUS.md`. The $9.0547 figure
is the conservative scaling projection from the 24-page cohort.

Cost components for the 200pp projection: Sonnet parse $4.8589 + Opus parse $3.7558 + PageRelevanceFilter $0.4316 + embeddings $0.0083.

**Cost gate thresholds:** observed ≤ $10, no-cache ≤ $12.

---

## 5. Files NOT Modified

The following production services are read-only from the harness:

- `app/services/single_file_chunking_service.rb` — no changes
- `app/services/batch_chunking_prompt.rb` — no changes (constants consumed: `WEB_PAGE_MAX_TOKENS`, `MODEL_TEXT`, `MODEL_MULTIMODAL`, `INGESTION_CONTRACT_VERSION`, `prompt_fingerprint_sha256`)
- `app/services/page_relevance_filter.rb` — no changes
- `app/services/pdf_page_splitter_service.rb` — no changes
- `app/services/chunk_merger_service.rb` — no changes
- `app/services/batch_results_parser_service.rb` — no changes
- `app/services/content_dedup_service.rb` — no changes
- `app/services/gate9_cost_matrix.rb` — no changes
- All prompts under `app/prompts/` — no changes
- All controllers, routes, jobs (UploadAndSyncAttachmentsJob etc.) — no changes

---

## 6. Operational Constraints (verbatim from spec)

- NO modificar prompts, routing, contratos ni servicios de producción.
- Nunca resubmit; siempre resume por batch_id.
- Cero KB sync / S3 output; output a MemoryS3.
- BUDGET único == spend limit del workspace.
- L2 NO publicable mientras human_review_verdict sea null.
- FAIL → diagnóstico offline, sin re-ejecutar. Cierra solo L2 observado, no Gate 9R.
- CERRADO — NO REABRIR: V1, O3′, E3a, E3b, O4a, O4b-A, O5-A (9f95de3).
- BLOQUEADO — NO TOCAR: O1′ funcional (señales offline pendientes), O5-B (n≥50 fotos + shadow).
- NO buscar ni fabricar cohortes de imágenes (esta corrida es manual_only).
- REGLA ANTI-LOOP (§5.6): si la corrida sale roja, diagnosticar OFFLINE sobre el artefacto retenido; NUNCA re-ejecutar la misma inferencia buscando un resultado favorable.

---

## 7. Next Steps

| Step | Command | Gate |
|------|---------|------|
| Commit FASE I | `git add app/services/gate9_final_manual.rb script/gate9_final_manual.rb test/services/gate9_final_manual_test.rb && git commit` | HALT-1 |
| FASE II preflight | `GATE9_FINAL_MANUAL=/abs/manual-real-200pp.pdf BEDROCK_RERANKER_ENABLED=false QUERY_ROUTING_ENABLED=false bin/rails runner script/gate9_final_manual.rb` | $0 |
| FASE III paid run | `GATE9_FINAL_EXECUTE=true GATE9_FINAL_MANUAL=/abs/manual-real-200pp.pdf GATE9_FINAL_BUDGET_USD=<MAX_AUTORIZADO> GATE9_FINAL_MAX_RETRY_PAGES=1 ANTHROPIC_API_KEY=<ws_key> KNOWLEDGE_BASE_S3_BUCKET=<isolated-input-bucket> BEDROCK_RERANKER_ENABLED=false QUERY_ROUTING_ENABLED=false bin/rails runner script/gate9_final_manual.rb` | paid |
| FASE IV verdict | `GATE9_FINAL_VERDICT=pass bin/rails runner script/gate9_final_manual.rb` | $0 |
