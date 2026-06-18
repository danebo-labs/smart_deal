# Gate 9R — Current Status

**Updated:** 2026-06-18
**Status:** MERGED_E2E_DEFERRED
**Purpose:** single checkpoint for continuing work without rereading historical plans.

## Instructions for any AI

Read only:

1. `AGENTS.md` and scoped `AGENTS.md` for files you will touch.
2. This file.
3. Current code/tests directly related to the next action.

Do **not** read every file under `docs/` or the historical master plan unless
this checkpoint lacks a necessary edge case. Do not reopen completed work.

## Branch and merge policy

- Current working branch: `main`.
- `codex/o4b-ingestion-noise-reduction` was merged locally by `f904c6e` after
  explicit human authorization and must remain until item 32 is closed.
- Do not push or delete the temporary branch without explicit authorization.
- Defer the planned paid application E2E until the general plan's remaining
  offline work is complete. It still requires an explicit cost cap and human
  authorization in the same conversation.

## Current pointer

`Gate 9R → Block C → item 32 → merged; E2E deferred to final validation`

- Checkpoint: `MERGED_E2E_DEFERRED`.
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

Continue the next unblocked offline item in the general plan. Keep the web/chat
PDF onboarding E2E as the final validation step; do not run it until the
remaining offline plan work is complete and an explicit cost cap and human
authorization are provided.

## Closed — do not repeat

V1/B.1–B.5.1, O3′, E3a, E3b, O4a, O4b-A, O1′ instrumentation, O5-A and the
final-manual harness implementation.

## Blocked / not active

- O1′ functional and O5-B: wait for n≥50 real production photos.
- O5-manuals: gated; current run had 0 Opus pages.
- O2: not activated; current run had zero final truncations.
- Item 33: pending n≥50 photos and n≥500 real queries; Gate 9R cannot close
  until item 32 is green.

## Start a new AI conversation

Paste this:

```text
Work in /Users/lahirisan/smart_deal. Read AGENTS.md and
docs/GATE9R_STATUS.md only. Check git status. Tell me the current item,
blocker, next single action and whether it costs money. Do not read all docs,
reopen closed work, execute paid APIs or resubmit batches without approval.
Confirm that you are on main and that codex/o4b-ingestion-noise-reduction still
exists. Do not create or switch branches, rebase, merge, push or delete the
temporary branch. Obtain an explicit cost cap and human authorization before
the planned paid E2E, which remains deferred until the general plan's offline
work is complete. When you finish, update docs/GATE9R_STATUS.md in the same
commit with only the new status, evidence and next action.
```
