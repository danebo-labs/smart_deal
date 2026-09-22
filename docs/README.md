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
| Strategy, priorities, runway, and decision gates | [PLAN_GENERAL_2026-09-03.md](PLAN_GENERAL_2026-09-03.md) |

## Business planning (living documents)

These are dated and supersede each other. Always read the newest of each series;
older dated versions are historical evidence, not the current plan.

| Scope | Current document | Status |
|---|---|---|
| Strategy: priorities, runway, Gonzalo track and plan B, discards | [PLAN_GENERAL_2026-09-03.md](PLAN_GENERAL_2026-09-03.md) | **Current.** Title/date 2026-09-03; last body update 2026-09-05 |
| Operations: 7 Aug – 4 Sep 2026 (trip window) | [PLAN_AGOSTO_2026-08-07.md](PLAN_AGOSTO_2026-08-07.md) | **Closed (3-sep).** Corpus Gonzalo+Jesús ingested; handoff to September |
| Operations: the September build month | [PLAN_SEPTIEMBRE_2026.md](PLAN_SEPTIEMBRE_2026.md) | **Current / active.** Certifier module, voice capture, descope ladder; absorbs August open items |
| Market sizing, billing unit, unit economics | [PRICING_Y_MERCADO_2026-08-07.md](PRICING_Y_MERCADO_2026-08-07.md) | **Current.** Reads against [SAAS_COST_MODEL_2026-06-12.md](SAAS_COST_MODEL_2026-06-12.md) as the cost authority |
| Demo and pilot tracking | [MATRIZ_DEMOS_PILOTOS_2026-08-07.md](MATRIZ_DEMOS_PILOTOS_2026-08-07.md) | **Current.** Unifies the two identical August XLSX matrices; the July interview matrix is closed |
| Gonzalo pilot ingestion: scope, budget, corpus findings, console runbook | [INGESTA_PILOTO_GONZALO_2026-08-20.md](INGESTA_PILOTO_GONZALO_2026-08-20.md) | **Closed (24-ago).** Nine batches complete on `danebo-pilot-elevator` (account 3). See also Jesús corpus on legacy below. |
| Jesús manuals ingestion → `danebo-legacy` | [INGESTA_PILOTO_JESUS_2026-08-31.md](INGESTA_PILOTO_JESUS_2026-08-31.md) | **Closed (31-ago).** 16 PDFs / 613 pages (Monarch near-dupe excluded) on account 1; BU 13+14 complete; US$14,11 all-in |

Conventions that hold across all of them: business planning is written in
Spanish, only weekdays are planned, and `SAAS_COST_MODEL_2026-06-12.md` plus
`bedrock_daily_costs` remain the only cost authorities.

## Active product and engineering references

| Area | Document | Status |
|---|---|---|
| Web home and mobile UX | [WEB_HOME.md](WEB_HOME.md) | Active |
| Sessions, pins, and retrieval scope | [SESSION_AND_RETRIEVAL.md](SESSION_AND_RETRIEVAL.md) | Active |
| Query orchestration | [QUERY_ORCHESTRATOR.md](QUERY_ORCHESTRATOR.md) | Active |
| Document ingestion routing | [INGESTION_ROUTING.md](INGESTION_ROUTING.md) | Active; live field-photo diagnosis is a separate non-ingestion path — still never a `KbDocument`/KB source, now with bounded S3 retention for re-ask reuse |
| Web document ingestion | [WEB_CUSTOM_CHUNKING.md](WEB_CUSTOM_CHUNKING.md) | Active for documents; not for live diagnostic photos |
| Metrics and queues | [METRICS.md](METRICS.md) | Active; dashboard routes and home usage footer are disabled by default |
| SaaS cost model | [SAAS_COST_MODEL_2026-06-12.md](SAAS_COST_MODEL_2026-06-12.md) | Current commercial baseline; dated evidence is retained |
| Bedrock configuration | [BEDROCK_SETUP.md](../BEDROCK_SETUP.md) | Active |
| Performance constraints | [PERFORMANCE_CONSTRAINTS.md](PERFORMANCE_CONSTRAINTS.md) | Active |
| Account branding | [ACCOUNT_BRANDING.md](ACCOUNT_BRANDING.md) | Active |
| Image compression | [IMAGE_COMPRESSION.md](IMAGE_COMPRESSION.md) | Active; corrected against code (3.75 MB / 1024px), now also covers field-photo thumbnail persistence |

## Active RAG references

| Document | Status |
|---|---|
| [rag/plan_conocimiento_visual.md](rag/plan_conocimiento_visual.md) | Canonical handoff for phased visual-knowledge ingestion work. Phases 0-6 closed, Gate A-bis passed, **Gate B run: vision relations failed the bar and are switched off; vision keeps component identity** — Phase 7 now waits on human decision #6 |
| [rag/gate_a_medicion_topologia.md](rag/gate_a_medicion_topologia.md) | Gate A measurement of the T1 topology deriver over all 98 SEGURIDADES pages, every edge vision-reviewed. Also the Phase 8 ground truth. **§2 and §3.1 predate phases 2b/3b** and are rewritten by Gate A-bis |
| [rag/gate_b_calibracion_vision.md](rag/gate_b_calibracion_vision.md) | Gate B: 102 vision relations judged one by one against the rendered page. Precision 88.2 % (95 % lower bound 81.6 %) against an 85 % bar — 100 % on plain numbered terminal strips, 81.5 % on dense stacked-label ones. Component identity 38/38. Why `INGESTION_VISION_TIER_RELATIONS_ENABLED` ships off |
| [rag/triaje_visual_medicion.md](rag/triaje_visual_medicion.md) | Phase 1 deliverable: per-page visual-complexity tiering of the 98 pages and Opus escalation cost projection |
| [rag/hallazgos_gate_piloto.md](rag/hallazgos_gate_piloto.md) | Open findings ledger for the SEGURIDADES pilot gate |
| [RAG_SEGURIDADES_STATUS.md](RAG_SEGURIDADES_STATUS.md) | Current SEGURIDADES production identity and gate status |
| [PLAN_RAG_RAZONAMIENTO_TECNICO_2026-09-15.md](PLAN_RAG_RAZONAMIENTO_TECNICO_2026-09-15.md) | **Closed (D18).** gs-v1 live. Case-3 hitch recipe is a declared product limit, not a named person. Generation-contract items 1–6 moved to the backlog below. |
| [BACKLOG_CONTRATO_GENERACION_GS_V1_2026-09-18.md](BACKLOG_CONTRATO_GENERACION_GS_V1_2026-09-18.md) | Backlog for gs-v1 generation-contract items 1–6, plus web_v1 ingest identity (same source sha mints a second uid). Not a Fase D of the plan above. |
| [PLAN_CONTINUIDAD_SESION_FOLLOWUP_2026-09-21.md](PLAN_CONTINUIDAD_SESION_FOLLOWUP_2026-09-21.md) | F0 y F1 cerradas. F1: rama A determinista, sin generation.txt. F2 no corrida. CS-D02: respuesta de copiloto e hipótesis desde chunks existentes; lever de generación en otra sesión distinta de F1, con actualización de PRODUCT_ROADMAP/AGENTS al implementarlo. Sin lever de ingesta. D18 cerrado. |
| [PLAN_HILO_CONSULTA_2026-09-21.md](PLAN_HILO_CONSULTA_2026-09-21.md) | **F0 cerrada y F1 implementada 21-sep noche, sin desplegar.** Unión determinista cuando queda un tramo; el menú (máx. 4 chips) es el fallback. Episodio real: se une, 114 caracteres. Flag `RAG_THREAD_MENU_ENABLED`. Holdout, Fase G y Fase S no corridas. |
| [PLAN_ASISTENTE_TECNICO_MVP_2026-09-21.md](PLAN_ASISTENTE_TECNICO_MVP_2026-09-21.md) | **Decisión de producto CS-P01, CS-P02 y CS-P03, sin validar.** El MVP se potencia como asistente de técnico: el conocimiento de arranque sale de los manuales ya ingeridos. Si el manual de este trabajo no trae el procedimiento, se infiere por analogía técnica como hipótesis, con descargo. CS-P03 nombra, y no construye, el diagnóstico revisado que pasa a conocimiento de la organización. Ordena el holdout del hilo y el lever de §9.2 / Fase G. No autoriza código ni Bedrock. |
| [PLAN_COPILOTO_GENERACION_2026-09-22.md](PLAN_COPILOTO_GENERACION_2026-09-22.md) | **A, G, mediciones 2–8 y D cerradas 22-sep.** Medición 8: proyección corta, 4 envíos, US$0,0226. Útil y safety pasan. El camino local no está desplegado. CG-D16 pendiente. |

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
- [PLAN_AGOSTO_2026-08-06.md](PLAN_AGOSTO_2026-08-06.md) — superseded by the 08-07 August plan
- [PLAN_QUIRURGICO_JESUS_GRATEROL_2026-09-16.md](PLAN_QUIRURGICO_JESUS_GRATEROL_2026-09-16.md) — 16-sep incident (Elemont pin vs CEA15); P0/P1 shipped, do not reopen

## Engineering instructions

- [AGENTS.md](../AGENTS.md) is the canonical repository-wide engineering
  contract.
- Scoped `AGENTS.md` files under `app/` and `test/` add directory-specific
  rules.
- [CLAUDE.md](../CLAUDE.md) is only a compatibility pointer to those canonical
  instructions.
- [ARCHITECTURE.md](../ARCHITECTURE.md) is a legacy WhatsApp-centric snapshot;
  do not use it as current architecture.
- `.cursor/rules/rag-precision-methodology.mdc` is the installed, agent-requestable
  RAG precision-closure methodology (design/execute a retrieval+generation accuracy
  plan). [RAG_PRECISION_METHODOLOGY_TEMPLATE_2026-08-04.mdc](RAG_PRECISION_METHODOLOGY_TEMPLATE_2026-08-04.mdc)
  is the portable copy for other SaaS client repos; no process in this repo loads it.

