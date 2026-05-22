# Documentation index

**Product:** signed-in **web** RAG for field elevator technicians. **WhatsApp is dormant** — see [WHATSAPP.md](WHATSAPP.md).

**Engineering contract for agents:** [CLAUDE.md](../CLAUDE.md)

## Start here

| If you need… | Read |
|--------------|------|
| Clone, run locally, essential flags | [README.md](../README.md) |
| Bedrock KB, models, env vars | [BEDROCK_SETUP.md](../BEDROCK_SETUP.md) |
| Deploy / Kamal / EC2 / RDS | [PRODUCTION.md](PRODUCTION.md) |

## Ingestion paths

| Path | Doc |
|------|-----|
| Chat file upload (Claude direct, flag) | [WEB_CUSTOM_CHUNKING.md](WEB_CUSTOM_CHUNKING.md) |
| Chat upload — cost v2 (Sonnet+Batch, 2026-05-21) | [INGESTION_COST_V2.md](INGESTION_COST_V2.md) |
| Bulk ZIP (`/bulk_uploads`, Anthropic Batch) | [BULK_INGESTION.md](BULK_INGESTION.md) |
| Legacy FM parse (`BEDROCK_DATA_SOURCE_ID`) | [BEDROCK_SETUP.md](../BEDROCK_SETUP.md) |

## Web UX & retrieval

| Topic | Doc |
|-------|-----|
| Home layout, KB list, lightbox | [WEB_HOME.md](WEB_HOME.md) |
| Pins, `active_entities`, scoped RAG | [SESSION_AND_RETRIEVAL.md](SESSION_AND_RETRIEVAL.md) |
| Intent routing (RAG / SQL / hybrid) | [QUERY_ORCHESTRATOR.md](QUERY_ORCHESTRATOR.md) |

## Operations & other

| Topic | Doc |
|-------|-----|
| Token/cost metrics, Solid Queue lanes | [METRICS.md](METRICS.md) |
| Image compression | [IMAGE_COMPRESSION.md](IMAGE_COMPRESSION.md) |
| Multi-tenant roadmap | [MULTI_TENANT_ARCHITECTURE.md](MULTI_TENANT_ARCHITECTURE.md) |
| Performance constraints | [PERFORMANCE_CONSTRAINTS.md](PERFORMANCE_CONSTRAINTS.md) |
| WhatsApp R3 (dormant) | [WHATSAPP.md](WHATSAPP.md) |
| Legacy full architecture (may be stale) | [ARCHITECTURE.md](../ARCHITECTURE.md) |

## Priorities (current build)

1. Low latency on web hot paths  
2. Operational simplicity (Solid Stack, one worker container in prod)  
3. Maintainability  
4. Token efficiency  
5. Idempotent uploads and jobs  

Not active: WhatsApp-first workflows, Twilio conversational UX as primary channel.
