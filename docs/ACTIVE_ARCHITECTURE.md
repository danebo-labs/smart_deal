# Active architecture

**Product:** signed-in **web** RAG for field elevator technicians. **WhatsApp is dormant** — see [WHATSAPP.md](WHATSAPP.md).

**Engineering contract for agents:** [AGENTS.md](../AGENTS.md) plus the nearest
scoped `AGENTS.md`.

The complete documentation map, including disabled features and historical
evidence, lives in [README.md](README.md). This file contains only the active
architecture priorities and retrieval contract.

## Canonical references

| If you need… | Read |
|--------------|------|
| **Product stage and roadmap** — MVP boundaries and next-stage triggers | [PRODUCT_ROADMAP.md](PRODUCT_ROADMAP.md) |
| Clone, run locally, essential flags | [README.md](../README.md) |
| Bedrock KB, models, env vars | [BEDROCK_SETUP.md](../BEDROCK_SETUP.md) |
| Deploy / Kamal / EC2 / RDS | [PRODUCTION.md](PRODUCTION.md) |
| Current RAG closure evidence | [GATE9R_STATUS.md](GATE9R_STATUS.md) |

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
- Live technician photos are diagnostic inputs only: they do not create a
  `KbDocument` or enter the Knowledge Base. Their compact result may provide
  temporary conversation context for a later explicit manual question.
- Photographic sources that deliberately pass through ingestion are indexed
  evidence and preserve only explicit visible knowledge. Labels without a
  legend remain literal identifiers with unknown function.
- Cohere reranking is implemented behind `BEDROCK_RERANKER_ENABLED`, but remains
  disabled because the 2026-06-09 quality benchmark found recall regressions.
