# SaaS Cost Model — Reconciled 2026-06-18

**Status:** current canonical source for Danebo variable AI COGS and pricing floors.

This document supersedes prior package totals, benchmark extrapolations and
unreconciled harness estimates. Historical run documents remain useful for
quality/audit evidence, but their cost figures are not current pricing inputs.

## Authority order

Use cost evidence in this order:

1. Provider invoice or provider cost export.
2. Bedrock model-invocation logs / CloudWatch billing telemetry.
3. Provider `usage` token payload persisted with `token_source: provider_usage`.
4. Application token estimates, explicitly labeled provisional.

All figures below are USD variable model costs. They exclude fixed Aurora/S3/
compute costs, support, taxes and commercial margin.

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

- RAG query estimates average approximately 3.8% below reconciled cost across
  the 20-query validation sample.
- Hybrid compare-with-schematic queries can undercount input much more because
  the estimator sees cited chunks, not every retrieved chunk sent to generation.
- Direct parse and normal batch-job parse use provider usage and reconcile to
  the invoice.
- The standalone retained manual run did not emit normal `BedrockQuery` rows;
  its provider invoice is therefore the authoritative source.
- Photo cost remains the only package line not validated against a sufficiently
  diverse invoice-backed production cohort.

The larger historical query-estimator gap was a V1 cohort result and is no
longer the current average accuracy statement.

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
- Reproducible historical/contractual matrix: `Gate9CostMatrix`
