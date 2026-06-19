# SaaS Cost Model — Reconciled 2026-06-18 · measurement upgraded 2026-06-19

**Status:** current canonical source for Danebo variable AI COGS and pricing floors.

This document supersedes prior package totals, benchmark extrapolations and
unreconciled harness estimates. Historical run documents remain useful for
quality/audit evidence, but their cost figures are not current pricing inputs.

> **2026-06-19 — cost measurement is now bill-exact.** Authority levels 1–2 below
> are no longer aspirational: Bedrock Model Invocation Logging is enabled and
> `BedrockInvocationLogReconciler` reads the exact billed tokens
> (`inputTokenCount`/`outputTokenCount`/cache) per UTC day straight from S3.
> `ReconcileBedrockCostJob` persists them daily into `bedrock_daily_costs` (and
> on demand via `bedrock:reconcile_persist[date]`). This **replaces the
> ~3.8%-undercounting `BedrockQuery` estimator as the authority for spend**. See
> *Cost measurement upgrade* below for evidence and scope.

## Authority order

Use cost evidence in this order:

1. Provider invoice or provider cost export.
2. Bedrock model-invocation logs / CloudWatch billing telemetry. **Operational:**
   `bin/rails 'bedrock:reconcile_logs[YYYY-MM-DD]'` (read-only report) or the
   persisted `bedrock_daily_costs` rows (`ReconcileBedrockCostJob`, daily 04:00).
3. Provider `usage` token payload persisted with `token_source: provider_usage`.
4. Application token estimates, explicitly labeled provisional (`token_source:
   estimated` — the live `#chat-usage-metrics-container` footer reads these for a
   provisional "today" figure; the exact value lands next day via level 2).

All figures below are USD variable model costs. They exclude fixed Aurora/S3/
compute costs, support, taxes and commercial margin.

## Cost measurement upgrade (2026-06-19)

**What changed.** Bedrock `retrieve_and_generate` returns no `usage` block, so
`BedrockQuery` query rows reconstructed input from cited chunks and undercounted
(~3.8% average; larger on hybrid). Spend authority has moved from that estimator
to the **AWS Model Invocation Logs in S3** — the same token counts AWS bills.

**Mechanism (in-repo).**

- `BedrockInvocationLogReconciler#day(date)` — parses `*.json.gz` invocation logs,
  aggregates exact `inputTokenCount`/`outputTokenCount`/`cacheRead`/`cacheWrite`
  per model for one UTC day, prices via `BedrockQuery::BEDROCK_PRICING`.
- `ReconcileBedrockCostJob` — persists that into `bedrock_daily_costs`
  (idempotent, one row per `[utc_date, model_id]`); scheduled daily 04:00 for the
  prior UTC day; manual via `bedrock:reconcile_persist[YYYY-MM-DD]`.
- `BedrockDailyCost.truth_vs_estimate(date)` — exposes the log-vs-estimate drift.

**Evidence (validated against the logs that feed the AWS bill).** Invocation
logging was enabled **2026-06-18**, so the reconciled window starts there:

| UTC day | Haiku (R&G) inv | input tok | output tok | Titan embeds | **Exact cost** |
|---|---:|---:|---:|---:|---:|
| 2026-06-18 (complete) | 52 | 224,097 | 22,213 | 106 | **$0.33518** |
| 2026-06-19 (in progress) | 14 | 72,570 | 6,732 | 50 | $0.10626 (partial) |

The logs capture **every** Bedrock model invocation that day (RAG generation +
no-results retries + page-filter + alias-extraction + embeddings), i.e. total
billable Bedrock spend — not just user-facing queries.

**Scope / honesty.** The *method* is now exact and bill-accurate at the
daily/aggregate level. It does **not** yet replace the per-1,000-query package
projection below: only ~1.5 days of low-volume dev/test traffic exist since trace
activation. The package figures stay as the **conservative projection**; they are
now anchored to an exact measurement pipeline and will converge to measured truth
as `bedrock_daily_costs` accumulates production volume. Keep the conservative
reserve until a representative production cohort is reconciled.

## Canonical package economics

| Cost line | Expected | Conservative | Evidence |
|---|---:|---:|---|
| 1,000 RAG queries / month | $6.14 | $8.65 | Real query reconciliation; conservative reserve assumes all queries generate |
| 200 field photos / month | ~$3.40 | ~$4.62 | Estimate, 80% Sonnet / 20% Opus; not invoice-validated |
| **Recurring monthly COGS** | **~$9.54** | **~$13.27** | Queries + photos only |
| 200-page manual onboarding | **$5.32 one-time** | **$5.32 measured** | Reconciled Anthropic invoice, 168 kept pages |
| **First month including onboarding** | **~$14.86 (~$15)** | **~$18.59** | Recurring COGS + one-time onboarding |

The manual is not a monthly recurring cost. It is charged once during
onboarding, or amortized explicitly as a commercial choice.

### Photo-routing sensitivity

The canonical photo estimate uses 80% Sonnet / 20% Opus. If production settles
at 90% Sonnet / 10% Opus with the same token profile, the linear sensitivity is:

- 200 photos: approximately $3.20.
- Recurring expected COGS: approximately $9.34.
- First month including onboarding: approximately $14.66.

This is sensitivity analysis, not reconciled billing truth. Keep the $13.27
monthly reserve until at least 50 diverse production photos are invoice-checked.

## Manual onboarding reconciliation

Retained batch: `msgbatch_017UYaG9fXBGkovuE6ENmaRv`.

| Component | Billed cost |
|---|---:|
| Sonnet 4.6 Batch: input | $0.50 |
| Sonnet 4.6 Batch: cache write | $1.50 |
| Sonnet 4.6 Batch: output | $2.51 |
| Haiku page filter + 2 bounded Sonnet-direct retries | $0.81 |
| **Full onboarding** | **$5.32** |

Run facts: 200 source pages, 168 kept/succeeded, 0 failed, 0 degraded, 0 Opus
pages and 2 bounded retries. The harness calculated $5.4434, 2.3% above the
invoice; retain that value only as a conservative diagnostic, not as billed cost.

## Production tracking accuracy

- **Authoritative spend is now log-exact.** `bedrock_daily_costs` /
  `bedrock:reconcile_logs` carry the exact billed tokens per UTC day from the AWS
  invocation logs. This is the number to trust for COGS.
- The `BedrockQuery` `token_source: estimated` rows remain **operational only**
  (live footer, latency/route telemetry, retrieval-regression analysis). Their
  historical ~3.8% average undercount — larger on hybrid compare-with-schematic
  queries, where the estimator sees cited chunks, not every retrieved chunk sent
  to generation — no longer affects any reported cost, because spend authority
  moved to the logs.
- Direct parse and normal batch-job parse use `provider_usage` and reconcile to
  the invoice; they are exact independently of the log pipeline.
- The standalone retained manual run did not emit normal `BedrockQuery` rows;
  its provider invoice is therefore the authoritative source.
- Photo cost remains the only package line not validated against a sufficiently
  diverse invoice-backed production cohort. Note: field photos bill via the
  **Anthropic Direct API** (`-direct` rows, `provider_usage` exact) — they do
  **not** appear in the Bedrock invocation logs and must be validated against the
  Anthropic invoice, not `bedrock_daily_costs`.

The larger historical query-estimator gap was a V1 cohort result and is no
longer the current average accuracy statement; it is also now moot for pricing.

## Pricing floor

Use conservative recurring COGS ($13.27), not first-month onboarding cost, to
set the monthly subscription floor.

| Target gross margin | Minimum monthly price |
|---|---:|
| 50% | $26.54 |
| 60% | $33.18 |
| 70% | $44.23 |

Bill onboarding separately with its own margin, or disclose any amortization.

## Technical contractual ceilings

`Gate9CostMatrix#contractual_max` derives finite worst cases from current
technical limits. These are risk bounds, not forecasts, package COGS or customer
prices.

| Unit | Technical ceiling |
|---|---:|
| 1,000 queries | $424.00 |
| 200 photos | $3,224.00 |
| 200-page manual | $2,712.18 |
| Combined | $6,360.18 |

The photo ceiling is intentionally pathological (every photo on the most
expensive route with the full bounded ladder). It shows that commercial quotas
and per-photo limits must remain explicit; it must never be presented as likely
spend.

## Retired calculation methods

Do not use prior monthly totals that included onboarding, 24-page manual
extrapolations, harness output as invoice truth, historical benchmark averages
as current query COGS, or fixed per-photo/per-page token assumptions. Only the
conservative all-generative query reserve remains intentionally carried forward.

## Source references

- Current checkpoint and reconciliation: [GATE9R_STATUS.md](GATE9R_STATUS.md)
- Manual execution evidence: [GATE9_FINAL_MANUAL_AUDIT_2026-06-17.md](GATE9_FINAL_MANUAL_AUDIT_2026-06-17.md)
- Active ingestion architecture: [INGESTION_COST_V2.md](INGESTION_COST_V2.md)
- Usage tracking semantics: [METRICS.md](METRICS.md)
- Exact spend reconciliation: `app/services/bedrock_invocation_log_reconciler.rb`,
  `app/jobs/reconcile_bedrock_cost_job.rb`, `BedrockDailyCost`,
  `lib/tasks/bedrock_reconcile.rake` (`bedrock:reconcile_logs`,
  `bedrock:reconcile_persist`)
- Reproducible historical/contractual matrix: `Gate9CostMatrix`
