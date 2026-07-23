# Danebo documentation

This is the canonical map for the repository documentation. Start here instead
of reading every Markdown file: several documents are retained as historical
evidence and are not descriptions of the active product.

## Start here

| Need | Canonical document |
|---|---|
| Product stage, MVP boundaries, and next stage | [PRODUCT_ROADMAP.md](PRODUCT_ROADMAP.md) |
| Active architecture and engineering priorities | [ACTIVE_ARCHITECTURE.md](ACTIVE_ARCHITECTURE.md) |
| Local setup and configuration | [README.md](../README.md) |
| Production deployment and AWS operations | [PRODUCTION.md](PRODUCTION.md) |
| Current RAG closure checkpoint | [GATE9R_STATUS.md](GATE9R_STATUS.md) |

## Active product and engineering references

| Area | Document | Status |
|---|---|---|
| Web home and mobile UX | [WEB_HOME.md](WEB_HOME.md) | Active |
| Sessions, pins, and retrieval scope | [SESSION_AND_RETRIEVAL.md](SESSION_AND_RETRIEVAL.md) | Active |
| Query orchestration | [QUERY_ORCHESTRATOR.md](QUERY_ORCHESTRATOR.md) | Active |
| Document ingestion routing | [INGESTION_ROUTING.md](INGESTION_ROUTING.md) | Active; live field-photo diagnosis is a separate non-ingestion path |
| Web document ingestion | [WEB_CUSTOM_CHUNKING.md](WEB_CUSTOM_CHUNKING.md) | Active for documents; not for live diagnostic photos |
| Metrics and queues | [METRICS.md](METRICS.md) | Active; dashboard routes and home usage footer are disabled by default |
| SaaS cost model | [SAAS_COST_MODEL_2026-06-12.md](SAAS_COST_MODEL_2026-06-12.md) | Current commercial baseline; dated evidence is retained |
| Bedrock configuration | [BEDROCK_SETUP.md](../BEDROCK_SETUP.md) | Active |
| Performance constraints | [PERFORMANCE_CONSTRAINTS.md](PERFORMANCE_CONSTRAINTS.md) | Active |
| Account branding | [ACCOUNT_BRANDING.md](ACCOUNT_BRANDING.md) | Active |
| Image compression | [IMAGE_COMPRESSION.md](IMAGE_COMPRESSION.md) | Active |

## Preserved capabilities that are disabled in the MVP pilot

These documents describe code that remains in the repository. Their routes or
channels are not part of the active pilot surface.

| Capability | Document | Current state |
|---|---|---|
| Bulk ZIP ingestion | [BULK_INGESTION.md](BULK_INGESTION.md) | Routes commented out in `config/routes.rb` |
| Tenant dashboard | [DASHBOARD.md](DASHBOARD.md) | Routes commented out in `config/routes.rb` |
| WhatsApp / Twilio | [WHATSAPP.md](WHATSAPP.md) | Dormant; webhook unmounted |

## Target architecture

| Area | Document | Current state |
|---|---|---|
| Tenant isolation | [MULTI_TENANT_ARCHITECTURE.md](MULTI_TENANT_ARCHITECTURE.md) | Account-aware Rails model delivered; full Bedrock/S3 isolation remains a rollout gate |

Target documents describe intended invariants, not necessarily delivered code.
Verify the status section and current implementation before changing the app.

## Historical evidence

The following files are audit artifacts or completed plans. Read them only when
investigating the corresponding dated run:

- [GATE9_FINAL_MANUAL_AUDIT_2026-06-17.md](GATE9_FINAL_MANUAL_AUDIT_2026-06-17.md)
- [GATE9_V1_2026-06-12.md](GATE9_V1_2026-06-12.md)
- [project_o1_gate_phase.md](project_o1_gate_phase.md)
- [RAG_100_PERCENT_FIDELITY_PLAN_2026-06-10.md](RAG_100_PERCENT_FIDELITY_PLAN_2026-06-10.md)
- [RAG_CERTIFICATION_2026-06-11.md](RAG_CERTIFICATION_2026-06-11.md)
- [RAG_QUALITY_BENCHMARK_2026-06-09.md](RAG_QUALITY_BENCHMARK_2026-06-09.md)
- [RAG_QUALITY_BENCHMARK_EVIDENCE_2026-06-10.md](RAG_QUALITY_BENCHMARK_EVIDENCE_2026-06-10.md)
- [RESUMEN_CAMBIOS_COMPRESION.md](RESUMEN_CAMBIOS_COMPRESION.md)
- [INGESTION_COST_V2.md](INGESTION_COST_V2.md) — retained ADR; current routing wins when behavior differs

## Engineering instructions

- [AGENTS.md](../AGENTS.md) is the canonical repository-wide engineering
  contract.
- Scoped `AGENTS.md` files under `app/` and `test/` add directory-specific
  rules.
- [CLAUDE.md](../CLAUDE.md) is only a compatibility pointer to those canonical
  instructions.
- [ARCHITECTURE.md](../ARCHITECTURE.md) is a legacy WhatsApp-centric snapshot;
  do not use it as current architecture.

