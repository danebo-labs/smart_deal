# Gate 9R — Current Status

**Updated:** 2026-06-18
**Status:** MERGE_READY
**Purpose:** single checkpoint for continuing work without rereading historical plans.

## Instructions for any AI

Read only:

1. `AGENTS.md` and scoped `AGENTS.md` for files you will touch.
2. This file.
3. Current code/tests directly related to the next action.

Do **not** read every file under `docs/` or the historical master plan unless
this checkpoint lacks a necessary edge case. Do not reopen completed work.

## Branch and merge policy

- Current working branch: `codex/o4b-ingestion-noise-reduction`.
- This branch is temporary and must eventually be merged into `main`.
- Keep Gate 9R work on this branch; do not create another branch.
- Do not switch to `main`, rebase, merge, push or delete the branch without
  explicit human authorization.
- After the offline filter fix and all checks are green, mark the branch
  `MERGE_READY`, show `main...HEAD`, and wait for approval.
- Merge into `main` before the planned application E2E. Keep the temporary
  branch until item 32 is closed and the merged application is verified.

## Current pointer

`Gate 9R → Block C → item 32 → COMPLETE`

- Checkpoint: `MERGE_READY`.
- Branch: `codex/o4b-ingestion-noise-reduction`.
- Retained Batch: `msgbatch_017UYaG9fXBGkovuE6ENmaRv`.
- Artifact: `tmp/gate9_final/4bbf9b13771e3daf9d774cca3784e3047b9b44a4e2278bcf0e4fc430be19f7f8/`.
- Baseline harness commit: `b765428`.

## Item 32 — implementation evidence

**Fix:** Added deterministic safety/action guard to `PageRelevanceFilter`.

- Applied only when Haiku or Haiku Batch returns `keep=false`; structural
  heuristic drops (cover, boilerplate, TOC, blank, repeated artifact) are
  never passed to the guard.
- Guard requires BOTH `SAFETY_ACTION_SIGNAL_PATTERN` (authorized/qualified
  personnel, coordination, lockout/shutdown/de-energization, restart after
  troubleshooting — English + Spanish) AND `SAFETY_DIRECTIVE_PATTERN` (must,
  shall, required, immediately, only after, do not, debe, deberá, obligatorio,
  inmediatamente, solo después, no debe).
- No arbitrary character-minimum; concise safety instructions are eligible.
- Glossary/divider with safety nouns but no directive is NOT rescued.
- Preserved: `source: :haiku` / `source: :haiku_batch`; overrides reason to
  `:safety_action_guard`.
- Shared `extract_page_text` class method used by both per-page and batch paths.
- `toc?` refactored to shared class method; existing behaviour unchanged.
- `force_opus` invariant preserved: non-rescued dropped pages never pass
  through `PageImageDensityAnalyzer`.

**Test counts:**
- `page_relevance_filter_test.rb`: **47 runs, 219 assertions, 0 failures, 0 errors**
  (36 existing + 11 new safety-guard tests).
- Mandatory checks (single_file_chunking, manual_batch_ingestion,
  bulk_cost_v2_request_builder, contractual_limits): **63 runs, 235 assertions,
  0 failures, 0 errors**.
- `bin/rubocop`: 0 offenses.
- `git diff --check`: clean.
- `bin/rails test` full suite: 1 pre-existing error in
  `Gate9FinalManualTest#test_failed_batch_results_survive_Phase_IV` (multiple
  `awaiting_human_review` artifacts in `tmp/gate9_final/`; confirmed pre-existing
  via `git stash` verification, unrelated to this change).

## Next action

Review `main...HEAD` and await explicit merge approval. Do not merge, push,
or run paid E2E without authorization.

## Closed — do not repeat

V1/B.1–B.5.1, O3′, E3a, E3b, O4a, O4b-A, O1′ instrumentation, O5-A and the
final-manual harness implementation.

## Blocked / not active

- O1′ functional and O5-B: wait for n≥50 real production photos.
- O5-manuals: gated; current run had 0 Opus pages.
- O2: not activated; current run had zero final truncations.
- Item 33: pending n≥50 photos and n≥500 real queries; Gate 9R cannot close
  until item 32 is green.

## Next single action

Fix `PageRelevanceFilter` offline with a generic safety/action guard and focused
tests. Preserve the current artifact; do not hardcode the manual, page numbers
or fixture phrases, and do not change the prompt, contract or model. This action
has no paid API cost. Do not resubmit a batch or run the paid E2E without an
explicit cap and human authorization in the same conversation.

## Start a new AI conversation

Paste this:

```text
Work in /Users/lahirisan/smart_deal. Read AGENTS.md and
docs/GATE9R_STATUS.md only. Check git status. Tell me the current item,
blocker, next single action and whether it costs money. Do not read all docs,
reopen closed work, execute paid APIs or resubmit batches without approval.
Confirm that you are on codex/o4b-ingestion-noise-reduction. Do not create or
switch branches, rebase, merge, push or delete the branch. When the checkpoint
says MERGE_READY, show main...HEAD and wait for my explicit merge approval.
When you finish, update docs/GATE9R_STATUS.md in the same commit with only the
new status, evidence and next action.
```
