# RAG quality and cost benchmark — 2026-06-09

**Status:** Reference benchmark for retrieval, documentary fidelity, field-photo
safety, and query cost.

**Scope:** Development Knowledge Base, signed-in web path, Claude Haiku 4.5 through
Bedrock `retrieve_and_generate`, two pinned test documents.

**Related:** [SESSION_AND_RETRIEVAL.md](SESSION_AND_RETRIEVAL.md) ·
[INGESTION_ROUTING.md](INGESTION_ROUTING.md) ·
[INGESTION_COST_V2.md](INGESTION_COST_V2.md) ·
[METRICS.md](METRICS.md)

---

## 1. Why this benchmark exists

Danebo is a field assistant for safety-sensitive technical work. A cheaper answer
is not an improvement if it:

- mixes evidence from the wrong pinned document;
- invents a function for a visible diagram label;
- turns an inspection finding into a mandatory stop-work condition;
- omits a functional test from a requested complete checklist; or
- silently searches the global catalog after the technician selected specific
  documents.

This benchmark was created before reducing retrieval tokens. The original answer
quality became the reference, and each optimization was evaluated against
documentary fidelity, safety, completeness, source isolation, and cost.

It is a regression benchmark, not a certification that the product is safe for
unsupervised field operation.

---

## 2. Test corpus

The test session pins exactly two sources:

| Source | Purpose |
|--------|---------|
| `uploads/2026-06-09/danebo_fidelity_v2_22_paginas.pdf` | Incomplete 22-page platform lift manual containing operation, inspection, functional-test, stop-work, and repair evidence |
| `uploads/2026-06-09/IMG_20260609_121243.jpg` | Hydraulic/electro-hydraulic schematic photo containing visible identifiers such as `FRRV1`, `P41`, `P42`, `ORF1`, and `BRK`, but no reliable legend for their functions |

The PDF and image exercise the normal field pattern: a manual supplies durable
knowledge, while a photo can be either a query-time observation or a compact
knowledge source when it contains explicit, legible technical evidence.

### Knowledge Base preconditions

- The development data source uses **no Bedrock chunking** for app-generated
  `bulk_chunks/.../chunk_N.txt` objects.
- Chunk sidecars preserve `original_source_uri`, `canonical_name`, aliases,
  document SHA, and ingestion path.
- The clean benchmark indexed only the two sources above to eliminate duplicate
  PDFs and stale chunks as retrieval confounders.
- Historical cost rows were preserved; cleaning the benchmark corpus did not
  delete usage/cost telemetry.

---

## 3. Benchmark matrix

The runner executes **16 real Bedrock queries**:

| Phase | Queries | Purpose |
|-------|---------|---------|
| Isolated | 6 | Manual purpose/components, operation controls, pre-use inspection, worksite inspection, complete functional tests, failure/repair |
| Conversational | 6 | Same knowledge as a connected field conversation, preserving recent turns |
| Source isolation | 3 | Explicitly select manual or schematic while both remain pinned |
| Visual fidelity | 1 | Ask for exact functions of visible labels when no legend documents them |

For isolated and source-isolation queries, conversation history is cleared before
each call. The conversational phase deliberately retains history. The runner
restores the original session pins and history in an `ensure` block.

Versioned runner:

```bash
bin/rails runner script/rag_quality_benchmark.rb
```

Optional configuration:

```bash
RAG_BENCHMARK_SESSION=mvp-shared \
RAG_BENCHMARK_CHANNEL=shared \
RAG_BENCHMARK_MANUAL_KEY=uploads/2026-06-09/danebo_fidelity_v2_22_paginas.pdf \
RAG_BENCHMARK_IMAGE_KEY=uploads/2026-06-09/IMG_20260609_121243.jpg \
RAG_BENCHMARK_OUTPUT=tmp/rag_quality_benchmark.json \
bin/rails runner script/rag_quality_benchmark.rb
```

This command performs paid Bedrock calls. Do not run it concurrently with other
Haiku traffic if CloudWatch totals will be used for exact cost attribution.

---

## 4. Quality rubric

| Dimension | Pass condition |
|-----------|----------------|
| Documentary fidelity | Technical claims are supported by retrieved text or explicit visual evidence |
| Source isolation | A query naming one pinned source does not use the other source |
| Pin authority | A forced pinned query never retries against the global catalog |
| Visual safety | Labels without a legend remain literal identifiers; function/value/connection returns `DATA_NOT_AVAILABLE` |
| Stop-work precision | A stop trigger is included only when evidence explicitly pairs the trigger with stop/prohibit/mark/out-of-service action |
| Exhaustive recall | A complete-list query preserves every distinct retrieved test and expected result |
| Repair authority | Failed tests cause mark/stop/prohibit behavior and repair is limited to qualified service technicians when documented |
| Language and delivery | Spanish remains consistent and the web response is readable by a technician |

Quality is evaluated from the answer text plus the pinned-source context and
retrieved document content. Token count alone is never a quality signal.

---

## 5. Cost results

CloudWatch is the authoritative source for Bedrock model tokens. Local
`BedrockQuery` values are useful for per-query diagnostics but undercount the full
`retrieve_and_generate` input payload.

Pricing used for Haiku 4.5:

- Input: **$0.80 / 1M tokens**
- Output: **$4.00 / 1M tokens**

### Baseline vs final

| Metric | Baseline | Final safe profile | Change |
|--------|----------|--------------------|--------|
| Queries | 16 | 16 | — |
| CloudWatch input tokens | 221,749 | 85,436 | **-61.5%** |
| CloudWatch output tokens | 11,641 | 10,880 | **-6.5%** |
| Cost for 16 queries | $0.22396 | $0.11187 | **-50.1%** |
| Projected cost / 1,000 queries | **$14.00** | **$6.99** | **-$7.01** |
| Local median end-to-end latency | 7.29 s | 7.67 s | +0.38 s |
| Local p95 end-to-end latency | 28.39 s | 16.12 s | **-12.27 s** |

Final CloudWatch window:

- Start: `2026-06-10T02:04:15Z`
- End: `2026-06-10T02:07:20Z`
- Model: `us.anthropic.claude-haiku-4-5-20251001-v1:0`
- Invocations: `16`
- Input tokens: `85,436`
- Output tokens: `10,880`
- Bedrock average model latency: `6,131 ms`
- Bedrock maximum model latency: `12,511 ms`

The final query estimate is intentionally based on the complete mixed benchmark,
not on a single short query.

The original `/tmp` JSON outputs were diagnostic artifacts and are not committed.
The versioned runner now makes the benchmark reproducible and writes a fresh
result to `tmp/rag_quality_benchmark.json` by default.

---

## 6. Quality results

### Passed

- **Pinned-source isolation:** manual-only and schematic-only questions stayed on
  the explicitly selected source.
- **No global fallback:** forced pinned queries return `DATA_NOT_AVAILABLE` when
  the selected documents lack evidence.
- **Visual-label fidelity:** `FRRV1`, `P41`, `P42`, `ORF1`, and `BRK` were returned
  as literal identifiers with `DATA_NOT_AVAILABLE` for undocumented functions.
- **Functional-test recall in conversation:** the final answer included ground
  and platform controls, left/right direction, drive/brake, the 20 cm/s limit,
  pit protection, and tilt-sensor tests.
- **Failure and repair behavior:** answers preserved mark/stop/prohibit actions
  and qualified-service-technician repair authority.
- **Language and web format:** responses remained in Spanish and used readable
  short sections/lists.

### Known residual gaps

1. **Exhaustive variability:** one final isolated answer included the left steering
   test but omitted the corresponding right steering test. The conversational
   answer included both.
2. **Stop-work over-promotion:** one conversational answer placed operator
   dizziness and unauthorized-person interference under immediate stop-work
   conditions. The manual presents them as operating/inspection precautions, not
   with the same explicit mark/stop pairing used for machine damage or malfunction.
3. **Model paraphrase risk:** broad component questions can still produce plausible
   functional paraphrases. Safety-critical values, procedures, and stop conditions
   require stricter evidence than general descriptions.

Therefore the benchmark result is:

> **Substantial cost and fidelity improvement, suitable as the current regression
> baseline, with two documented quality gaps still blocking a claim of complete
> safety-grade determinism.**

---

## 7. Reranking experiment

IAM and application support for `bedrock:Rerank` were verified with Cohere Rerank
v3.5. Reranking is conditional and applies only to exhaustive queries when enabled.

Experiments:

| Candidates → generated context | Result |
|--------------------------------|--------|
| 15 → 9 | Omitted mandatory functional-test blocks |
| 15 → 12 | Still omitted a direction test in observed runs |
| 15 without reranking | Best recall; selected as current safe configuration |

Decision:

```bash
BEDROCK_RERANKER_ENABLED=false
```

Reranking remains implemented behind a flag for future experiments, but it must
not be enabled in production until it passes the same 16-query quality gate across
multiple repeated runs. Lower token count is not sufficient evidence.

AWS IAM note: the Bedrock service authorization model does not expose a
resource-level ARN for the `Rerank` action. Its policy statement requires
`"Resource": "*"`.

---

## 8. Implemented design changes

### 8.1 Pins are authoritative

- Web queries with pins use `force_entity_filter: true`.
- A forced pinned miss returns localized `DATA_NOT_AVAILABLE`.
- The service never expands silently to the global catalog.
- When multiple sources are pinned and the question explicitly names one,
  `Rag::PinnedEntityScopeResolver` narrows the URI set deterministically.
- Ambiguous or semantic questions keep all pins.
- Negative clauses such as “no uses el esquema” exclude that explicit source.

### 8.2 Adaptive retrieval budget

`RagRetrievalProfile` selects retrieval depth from pin type and intent:

| Query/pin profile | Results |
|-------------------|---------|
| Focused document or mixed pins | 3 |
| Stop/failure/repair intent | 5 |
| Photo-only pins | 10 |
| No pins | 8 |
| Exhaustive checklist | 15 |

The larger exhaustive budget protects recall. Focused manual questions avoid
paying for seven or ten large chunks.

### 8.3 Query-specific prompt protections

- Stop-work questions receive an evidence-pairing override.
- Exhaustive questions ignore the normal 300-word target and must preserve every
  distinct retrieved item.
- Photo-only questions receive a literal-label safety override.
- Web delivery is concise by default without removing documented warnings.
- Session context aliases are capped to reduce repeated prompt tokens.

### 8.4 Field photos can preserve explicit knowledge

The field-photo path remains compact, but it no longer assumes every photo is only
an identity record. It can store:

- verbatim visible text;
- explicitly documented functions;
- unambiguous connections;
- printed values and units;
- visible warnings.

Conventional symbols, acronym expansions, and apparent line positions are not
treated as evidence. Ordinary photos with no explicit technical evidence remain
small identity chunks.

### 8.5 Chunk-specific aliases

- The ingestion prompt now produces aliases per chunk.
- Each `SEARCH_ALIASES` header uses only aliases relevant to that chunk.
- Document aliases are capped at 15.
- Chunk aliases are capped at 8 and sanitized.
- Generation emits at most 3 aliases in hidden document references.

This reduces metadata/prompt noise and improves exact-key hybrid retrieval for
codes such as `P41` without contaminating unrelated chunks.

---

## 9. Automated verification

Final suite after the changes:

```text
1065 runs
2772 assertions
0 failures
0 errors
164 skips
```

The skips are existing environment/channel-dependent tests and are not new
failures.

Key focused coverage:

- pinned-source narrowing and negative clauses;
- forced-pin no-global-fallback behavior;
- retrieval profiles for focused, safety-critical, photo, open, and exhaustive queries;
- conditional reranking configuration;
- field-photo explicit evidence and malformed evidence handling;
- chunk-specific alias propagation and caps;
- exhaustive prompt override;
- stop-work and photo-label safety directives.

---

## 10. Regression gate for future changes

Any change to prompts, chunk sizes, retrieval count, reranking, aliases, model,
search type, or session context must:

1. Run the full automated suite.
2. Run the 16-query benchmark at least once in isolation.
3. Repeat the exhaustive and stop-work cases at least three times because model
   output is stochastic.
4. Compare CloudWatch tokens, not only local estimates.
5. Reject the change if it introduces a new unsupported safety claim or source leak.
6. Do not accept cost savings that omit a documented test, value, warning, or
   expected result requested by the technician.

The two residual gaps above are mandatory targets for the next fidelity iteration.
