# Gate 9R — Current Status

**Updated:** 2026-06-18
**Status:** CLOSED_PROVISIONAL
**Purpose:** single checkpoint for continuing work without rereading historical plans.
**Master plan:** `/Users/lahirisan/.cursor/plans/rag_precision_cost_plan_578aea0c.plan.md`

## Instructions for any AI

Read only:

1. `AGENTS.md` and scoped `AGENTS.md` for files you will touch.
2. This file.
3. Current code/tests directly related to the next action.

Do **not** read every file under `docs/` or the historical master plan unless
this checkpoint lacks a necessary edge case. Do not reopen completed work.

## Branch and merge policy

- Current working branch: `main`.
- `codex/o4b-ingestion-noise-reduction` was merged locally by `f904c6e` and is
  retained for audit. Do not push or delete it without explicit authorization.
- Any future paid application E2E is a separate optional validation. It requires
  an explicit cost cap and human authorization in the same conversation.

## Current pointer

`Gate 9R → CLOSED_PROVISIONAL; retained 200-page artifact verified offline; no further Gate 9R implementation required`

Use stable plan IDs/names rather than bare item numbers: item 32 in the master
plan's executable sequence is the paid 200-page post-optimization run, not the
completed deterministic page-relevance guard.

- Checkpoint: `CLOSED_PROVISIONAL`.
- Branch: `main`; retained source tip: `71f6239`.
- Retained Batch: `msgbatch_017UYaG9fXBGkovuE6ENmaRv`.
- Artifact: `tmp/gate9_final/4bbf9b13771e3daf9d774cca3784e3047b9b44a4e2278bcf0e4fc430be19f7f8/`.
- Baseline harness commit: `b765428`.

## Item 32 — implementation evidence

**Fix:** Added deterministic safety/action guard to `PageRelevanceFilter`.

- Applied only when Haiku or Haiku Batch returns `keep=false`. Per-page
  structural heuristic drops never reach the guard; the batch path explicitly
  rejects TOC-like and bounded boilerplate text before rescue.
- Guard requires BOTH `SAFETY_ACTION_SIGNAL_PATTERN` (authorized/qualified
  personnel, coordination, lockout/shutdown/de-energization, restart after
  troubleshooting — English + Spanish) AND `SAFETY_DIRECTIVE_PATTERN` (must,
  shall, required, immediately, only after, do not, debe, deberá, obligatorio,
  inmediatamente, solo después, no debe).
- No arbitrary character-minimum; concise safety instructions are eligible.
- Obligation nouns (`requirement`/`requirements`) and immediate-action forms
  are covered so authorization/coordination requirements remain eligible.
- Glossary/divider with safety nouns but no directive is NOT rescued.
- Preserved: `source: :haiku` / `source: :haiku_batch`; overrides reason to
  `:safety_action_guard`.
- Shared `extract_page_text` class method used by both per-page and batch paths.
- `toc?` refactored to shared class method; existing behaviour unchanged.
- `force_opus` invariant preserved: non-rescued dropped pages never pass
  through `PageImageDensityAnalyzer`.

**Test counts:**
- `page_relevance_filter_test.rb`: **48 runs, 225 assertions, 0 failures, 0 errors**.
- Mandatory checks (single_file_chunking, manual_batch_ingestion,
  bulk_cost_v2_request_builder, contractual_limits): **63 runs, 235 assertions,
  0 failures, 0 errors**.
- Phase IV failed-batch regression: **1 run, 4 assertions, 0 failures, 0 errors**;
  the test now selects its own temporary artifact without touching the retained
  `awaiting_human_review` artifact.
- Full suite: **1360 runs, 4085 assertions, 0 failures, 0 errors, 164 skips**.
- `bin/rubocop`: 0 offenses.
- `git diff --check`: clean.

## Next action

None for Gate 9R. Do not reopen completed implementation or require synthetic
traffic, 500 real queries or 50 real photos for this provisional closeout.
Future production telemetry may upgrade provisional commercial estimates but is
non-blocking. Any new web/chat application E2E is a separate optional validation
and requires a new cost cap and human authorization. Do not resubmit the retained
PDF.

## Final preflight evidence — 2026-06-18

- Supplied PDF: 200 pages, 8,332,393 bytes, unencrypted, text layer present.
- SHA-256 matches the retained artifact exactly:
  `4bbf9b13771e3daf9d774cca3784e3047b9b44a4e2278bcf0e4fc430be19f7f8`.
- Retained Batch `msgbatch_017UYaG9fXBGkovuE6ENmaRv` ended with 168 kept and
  succeeded pages, 0 failed, 0 degraded and 2 bounded retries.
- Harness-computed observed L2 cost: USD 5.443419. **RECONCILED 2026-06-18**
  against the Anthropic invoice (real full onboarding $5.32; harness +2.3%,
  conservative). See "Anthropic billed-cost reconciliation — 2026-06-18" below.
- The retained pre-fix filter dropped safety pages 197, 198 and 200. Offline
  replay against current `PageRelevanceFilter.safety_action_guard?` rescues all
  three; page 199 remains technical content and does not require rescue.
- `page_relevance_filter_test.rb`: 48 runs, 225 assertions, 0 failures, 0 errors.
- No paid API or network call was executed during this preflight.

## Anthropic billed-cost reconciliation — 2026-06-18 (COMPLETE)

Source: Anthropic Console cost export
`claude_api_cost_2026_06_01_to_2026_06_18.csv` (workspace `Default`, key
`danebo-claude-key`), cross-checked against newly enabled Bedrock
model-invocation logging.

**Manual (batch `msgbatch_017UYaG9fXBGkovuE6ENmaRv`, 168 pages, billed 2026-06-18):**
- Real Anthropic batch (Sonnet 4.6): input $0.50 + cache-write $1.50 +
  output $2.51 = **$4.51**.
- Page-filter (Haiku, sync) $0.44 + 2 Sonnet-direct $0.37 = $0.81.
- **Real full onboarding cost: $5.32.** Harness-observed L2 was $5.4434 →
  **+2.3%, conservative**. The harness slightly over-estimates; the figure is safe.
- The batch was launched by a standalone improvement script, outside
  `IngestManualBatchResultsJob`, so it emitted NO `BedrockQuery` /
  `TrackBedrockQueryJob` rows. This is expected for one-off script runs and is
  NOT a production tracking defect — its cost is visible only on the Anthropic
  invoice, which is why prior in-app totals did not include it.

**Production cost-tracking accuracy (validated against ground truth):**
- Bedrock model-invocation logging ENABLED → `s3://multimodal-logs/bedrock-invocation-logs/`.
  `Converse` records are now the query ground truth (textDataDeliveryEnabled).
- RAG query estimator (`token_source: "estimated"`): measured **−3.8% on cost**
  across 20 real queries (output exact ±1 token = `stop_sequence`; input −1–3%).
  The larger historical V1 gap is not the current average. Outlier: hybrid
  "compare-with-schematic" queries can undercount input ~58% because the
  estimator counts only cited chunks, not all retrieved chunks fed to
  `$search_results$`.
- Sync/`-direct` parse and batch-via-jobs parse: **exact** (`token_source:
  "provider_usage"`, straight from Anthropic `usage`). Daily reconciliation
  06-15/16/17 matched the invoice to the cent.

**SaaS COGS implication:**
- Manual ingestion is **one-time onboarding** ($5.32), NOT a monthly recurring
  cost. The earlier package figure that folded it into monthly overstated
  steady-state COGS.
- Measured recurring per client/month: 1,000 Haiku queries **$6.14** (real) +
  200 field photos (80% Sonnet / 20% Opus) **~$3.40 est.** = **~$9.54 expected /
  ~$13.27 conservative**. First month incl. manual onboarding: **~$15**.
- Still unvalidated against invoice: field-photo parse (estimate only); blocked
  on n≥50 real production photos (see O1′ / O5-B below).

Canonical package calculations and pricing floors live only in
`docs/SAAS_COST_MODEL_2026-06-12.md`.

## Documentation consolidation — 2026-06-18

- `SAAS_COST_MODEL_2026-06-12.md` is the only canonical financial model:
  $9.54 expected / $13.27 conservative recurring COGS and $5.32 one-time
  manual onboarding.
- Removed superseded monthly totals that incorrectly included onboarding,
  unreconciled manual projections and fixed per-call token assumptions from
  living docs.
- `INGESTION_COST_V2.md` now documents routing plus current package boundaries;
  `METRICS.md` records billing authority and the current ~3.8% average query
  estimator gap.
- Historical benchmarks remain for audit, carry an explicit historical banner
  and are not current pricing sources.
- `Gate9CostMatrix` remains reproducible for historical cohorts and technical
  ceilings, but its script labels those outputs as non-current COGS.

## Closed — do not repeat

V1/B.1–B.5.1, O3′, E3a, E3b, O4a, O4b-A, O1′ instrumentation, O5-A and the
final-manual harness implementation. Gate 9R is closed provisionally with the
limitations recorded below.

## Blocked / not active

- O1′ functional and O5-B: wait for n≥50 real production photos.
- O5-manuals: gated; current run had 0 Opus pages.
- O2: not activated; current run had zero final truncations.
- E1 prompt compaction and E2 context reduction: explicitly deferred and
  non-blocking; combined estimated saving is only USD 0.25–0.60 per 1,000
  queries, before validation cost.
- Master-plan item 32: satisfied provisionally with the retained completed
  200-page artifact and current-guard offline replay; no resubmission authorized.
- Item 33 real-production thresholds remain unmet. Synthetic queries/photos may
  support offline quality validation but do not satisfy the statistical
  production-evidence requirement. This limitation is accepted for the
  provisional closeout and does not keep Gate 9R open.

## Start a new AI conversation

Paste this:

```text
Work in /Users/lahirisan/smart_deal. Read AGENTS.md and
docs/GATE9R_STATUS.md only. Check git status. Gate 9R is CLOSED_PROVISIONAL;
do not reopen it, require synthetic traffic or resubmit the retained PDF.
Canonical costs are in docs/SAAS_COST_MODEL_2026-06-12.md: recurring COGS
$9.54 expected / $13.27 conservative; manual onboarding $5.32 one-time.
Do not execute paid APIs, push, switch branches or delete the retained branch
without explicit authorization. Update the checkpoint only for genuinely new
evidence or a user-authorized state change.
```
