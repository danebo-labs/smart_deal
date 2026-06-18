# Documentation index

**Product:** signed-in **web** RAG for field elevator technicians. **WhatsApp is dormant** — see [WHATSAPP.md](WHATSAPP.md).

**Engineering contract for agents:** [CLAUDE.md](../CLAUDE.md)

## Start here

| If you need… | Read |
|--------------|------|
| **Current Gate 9R work** — exact phase, blocker, next action | [GATE9R_STATUS.md](GATE9R_STATUS.md) |
| Clone, run locally, essential flags | [README.md](../README.md) |
| Bedrock KB, models, env vars | [BEDROCK_SETUP.md](../BEDROCK_SETUP.md) |
| Deploy / Kamal / EC2 / RDS | [PRODUCTION.md](PRODUCTION.md) |

For Gate 9R, read `GATE9R_STATUS.md` first and do not load every dated report.

## Ingestion paths

| Path | Doc |
|------|-----|
| **Ingestion routing** — file type, page filter (portada/índice/dedicatoria), LLM matrix | [INGESTION_ROUTING.md](INGESTION_ROUTING.md) |
| Web/chat file upload (`CustomChunkingPipeline`, sync Messages API) | [WEB_CUSTOM_CHUNKING.md](WEB_CUSTOM_CHUNKING.md) |
| Ingestion cost model & routing ADR (Sonnet/Batch, 2026-05-21) | [INGESTION_COST_V2.md](INGESTION_COST_V2.md) |
| Bulk ZIP (`/bulk_uploads`, Anthropic Batch) | [BULK_INGESTION.md](BULK_INGESTION.md) |
| Bedrock data source contract (`bulk_chunks/`, no chunking) | [BEDROCK_SETUP.md](../BEDROCK_SETUP.md#required-s3-data-source-configuration) |
| Legacy FM parse (`BEDROCK_DATA_SOURCE_ID`) | [BEDROCK_SETUP.md](../BEDROCK_SETUP.md) |

## Web UX & retrieval

| Topic | Doc |
|-------|-----|
| Home layout, KB list, lightbox | [WEB_HOME.md](WEB_HOME.md) |
| Pins, `active_entities`, scoped RAG | [SESSION_AND_RETRIEVAL.md](SESSION_AND_RETRIEVAL.md) |
| RAG quality/cost benchmark, regression gate, known gaps | [RAG_QUALITY_BENCHMARK_2026-06-09.md](RAG_QUALITY_BENCHMARK_2026-06-09.md) |
| Intent routing (RAG / SQL / hybrid) | [QUERY_ORCHESTRATOR.md](QUERY_ORCHESTRATOR.md) |

## Operations & other

| Topic | Doc |
|-------|-----|
| Token/cost metrics, Solid Queue lanes | [METRICS.md](METRICS.md) |
| Canonical reconciled SaaS COGS and pricing floors | [SAAS_COST_MODEL_2026-06-12.md](SAAS_COST_MODEL_2026-06-12.md) |
| Image compression | [IMAGE_COMPRESSION.md](IMAGE_COMPRESSION.md) |
| Multi-tenant roadmap | [MULTI_TENANT_ARCHITECTURE.md](MULTI_TENANT_ARCHITECTURE.md) |
| Performance constraints | [PERFORMANCE_CONSTRAINTS.md](PERFORMANCE_CONSTRAINTS.md) |
| WhatsApp R3 (dormant) | [WHATSAPP.md](WHATSAPP.md) |
| Legacy full architecture (may be stale) | [ARCHITECTURE.md](../ARCHITECTURE.md) |

## Historical evidence — do not read by default

These files remain committed for auditability. They are not startup context and
should only be opened when investigating the specific historical run:

- `GATE9_FINAL_MANUAL_AUDIT_2026-06-17.md`
- `GATE9_V1_2026-06-12.md`
- `project_o1_gate_phase.md`
- `RAG_100_PERCENT_FIDELITY_PLAN_2026-06-10.md`
- `RAG_CERTIFICATION_2026-06-11.md`
- `RAG_QUALITY_BENCHMARK_EVIDENCE_2026-06-10.md`
- `RESUMEN_CAMBIOS_COMPRESION.md`

Current sources are `GATE9R_STATUS.md`, `SAAS_COST_MODEL_2026-06-12.md`,
`INGESTION_COST_V2.md`, `INGESTION_ROUTING.md`, `METRICS.md` and the
code/tests themselves.

## Priorities (current build)

1. Low latency on web hot paths  
2. Operational simplicity (Solid Stack, one worker container in prod)  
3. Maintainability  
4. Token efficiency  
5. Idempotent uploads and jobs  

Not active: WhatsApp-first workflows, Twilio conversational UX as primary channel.

## Current retrieval contract

- Pins are the technician's explicit evidence scope. A pinned miss returns
  `DATA_NOT_AVAILABLE`; it does not search the global catalog.
- Multiple pins may be narrowed deterministically when the question explicitly
  names one source or excludes another. Ambiguous questions retain all pins.
- Retrieval depth is adaptive: focused document queries use a small context;
  safety-critical and exhaustive questions retrieve more evidence.
- Field photos preserve only explicit visible knowledge. Labels without a legend
  remain literal identifiers with unknown function.
- Cohere reranking is implemented behind `BEDROCK_RERANKER_ENABLED`, but remains
  disabled because the 2026-06-09 quality benchmark found recall regressions.
