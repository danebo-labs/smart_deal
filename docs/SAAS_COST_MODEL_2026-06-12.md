# SaaS Cost Model - 2026-06-12

> **Status: provisional baseline.** The manual projection comes from one
> 24-page cohort and the photo estimate from four parses, including repeated
> content. These figures support prioritization and experiments, but they are
> not contractual maxima or customer pricing. Contractual maxima must be
> regenerated from finite technical limits with the Gate 9R cost matrix.

## Scope

Variable COGS for one usage package:

- 1,000 application queries
- 200 web/chat image uploads
- one 200-page manual
- multipage parsing and `PageRelevanceFilter`
- embeddings, including re-ingestion
- Sonnet/Opus ingestion routing
- optional Cohere reranking

This model excludes shared infrastructure, payment fees, support, storage growth,
taxes, and commercial margin.

## Assumptions

- "200 web/chat files" means 200 field-photo/image uploads. PDFs and office
  documents have a different page distribution and must be priced separately.
- Query generation uses the current global Claude Haiku 4.5 endpoint.
- The recommended manual path is Bedrock batch ingestion. Direct web/chat
  ingestion is shown as the more expensive alternative.
- The measured 24-page v3 manual cohort retained 23 pages, routed 21 pages to
  Sonnet and 2 pages to Opus, and retried 3 truncated pages directly.
- Embeddings use Titan Text Embeddings V2 at USD 0.00002 per 1,000 input tokens.
- Batch inference applies the documented 50% model-token discount. Direct
  retries remain charged at direct inference prices.

## Unit Prices

| Service | Input / MTok | Output / MTok |
|---|---:|---:|
| Claude Haiku 4.5 global | $1.00 | $5.00 |
| Claude Sonnet 4.6 direct | $3.00 | $15.00 |
| Claude Sonnet 4.6 batch | $1.50 | $7.50 |
| Claude Opus 4.8 direct | $5.00 | $25.00 |
| Claude Opus 4.8 batch | $2.50 | $12.50 |

Cohere Rerank 3.5 costs USD 2.00 per 1,000 rerank requests, with up to 100
document chunks per request.

Official references:

- https://aws.amazon.com/bedrock/pricing/
- https://platform.claude.com/docs/en/about-claude/pricing

## Measured Costs

### 1,000 queries

The certified Gate 9 benchmark generated 48 application queries but only 36
model calls because 12 answers followed deterministic paths. CloudWatch recorded
219,638 input tokens and 18,345 output tokens.

| Query scenario | Cost / 1,000 |
|---|---:|
| Certified mix, including 25% deterministic answers | $6.4867 |
| Conservative reserve, all 1,000 queries invoke Haiku | $8.6490 |
| Recent production sample, 3 global-endpoint calls | $7.1267 |

The SaaS reserve should use **$8.65**, not the benchmark average, until a larger
production cohort confirms the deterministic-answer rate.

### 200 web/chat images

Four current v3 parse samples cost USD 0.025242, 0.026127, 0.020883, and
0.020178. Their mean is USD 0.0231075 per image.

| Component | Cost |
|---|---:|
| Sonnet parsing, measured mean | $4.6215 |
| Titan embeddings | $0.0022 |
| Total expected | **$4.6237** |
| Sample high-water budget | **$5.2276** |

The old USD 0.009/photo estimate is no longer representative of the current v3
structured output.

### 200-page manual

The projection scales the complete 24-page v3 cohort to 200 pages.

| Component | Batch path | Direct web/chat path |
|---|---:|---:|
| Sonnet parse and direct retries | $4.8589 | $9.0888 |
| Opus parse and direct retries | $3.7558 | $4.9989 |
| `PageRelevanceFilter` | $0.4316 | $0.4316 |
| Titan embeddings / re-ingestion | $0.0083 | $0.0083 |
| Total manual | **$9.0547** | **$14.5276** |

The batch estimate preserves direct pricing for truncated-page retries. It does
not apply a blanket 50% discount to those retries.

## Package Totals

### Recommended: manual through batch ingestion

| Scenario | No rerank | Typical rerank | All queries reranked |
|---|---:|---:|---:|
| Certified query mix | $20.1651 | $20.4151 | $22.1651 |
| Conservative SaaS reserve | **$22.3274** | **$22.5774** | **$24.3274** |

"Typical rerank" assumes the benchmark exhaustive-query rate of 12.5%, adding
USD 0.25 per 1,000 application queries. Reranking is currently disabled in
production.

### Alternative: manual through direct web/chat ingestion

| Scenario | No rerank | Typical rerank | All queries reranked |
|---|---:|---:|---:|
| Certified query mix | $25.6381 | $25.8881 | $27.6381 |
| Conservative SaaS reserve | **$27.8003** | **$28.0503** | **$29.8003** |

## Gate 9 Verdict

The original variable-cost target of USD 10 for the complete package is not met.
With current v3 output sizes, the recommended batch path is approximately:

- **USD 20.17 expected**
- **USD 22.33 conservative reserve**
- **USD 24.33 conservative reserve with every query reranked**

Queries plus 200 images alone already cost approximately USD 11.11 using the
certified mix, before processing the manual.

## Tracking Audit

- `metrics:rebuild_cost_rollups` reconciles `CostMetric` with the persisted
  `BedrockQuery` rows in development and production.
- Recent production query rows reported USD 0.014246 locally, while CloudWatch
  token metrics imply USD 0.021380 for the same three calls. The local query
  estimate undercounts billed prompt context and must not be treated as invoice
  truth.
- Detailed Bedrock model invocation logging is not enabled; only aggregate
  CloudWatch token metrics are currently available.
- A batch retry tracking defect duplicated direct retry rows and replaced the
  original batch usage with retry usage. The 2026-06-12 fix keeps batch usage,
  records each direct retry once, and accumulates both costs on the asset.

Use CloudWatch/AWS billing data as the financial source of truth. Use local
`BedrockQuery` and `CostMetric` data for attribution and operational diagnosis.

## AWS Bill Context

AWS Cost Explorer for June 1-12 showed:

- USD 12.3862 before tax
- USD 14.7262 including tax
- USD 4.5114 attributed to Claude Haiku 4.5
- USD 0.0100 for 5 Cohere rerank requests, confirming USD 2.00 / 1,000

This is a partial-month, account-wide total that mixes development, benchmarks,
and production. Direct Anthropic Sonnet/Opus ingestion must be reconciled from
Anthropic usage and the application token ledger. These values are operational
context, not a per-customer cost allocation.

## SaaS Pricing Floor

Using the conservative batch COGS of USD 22.33 before shared infrastructure:

| Target gross margin | Minimum price |
|---|---:|
| 50% | $44.65 |
| 60% | $55.82 |
| 70% | $74.42 |

Actual plan pricing must also allocate shared monthly infrastructure:

`COGS per customer = variable usage + shared infrastructure / active customers`

Current AWS Cost Explorer data mixes development, benchmark, and production
workloads, so it cannot yet provide a defensible per-customer fixed-cost
allocation.
