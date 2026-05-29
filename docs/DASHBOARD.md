# Dashboard — tenant usage view

**Audience:** tenant administrators (B2B customers).  
**Route:** `GET /dashboard`  
**Related:** [METRICS.md](METRICS.md) · [MULTI_TENANT_ARCHITECTURE.md](MULTI_TENANT_ARCHITECTURE.md)

---

## Product decision (2026-05-28)

The app targets **multi-tenant SaaS**. The dashboard answers one question for a tenant admin:

> **How much LLM consumption does my organization use, and where does it go?**

It does **not** answer platform/infra questions (Aurora ACU, shared S3 bucket, EC2, network). Those belong to **internal ops** (AWS Cost Explorer, CloudWatch, a future `/internal/ops` panel).

### Removed from tenant dashboard

| Removed | Reason |
|---------|--------|
| Vector Store (Aurora ACU) | Shared infra; often 0 when paused; requires CloudWatch; not tenant-billable |
| S3 document card (bucket count/MB) | Stale `CostMetric` snapshot; duplicated live S3 poll; infra-level |
| Tokens (today + month) | Low actionability; cost + channel breakdown is enough |
| **Actualizar Métricas** button | Triggered `DailyMetricsJob` → AWS CloudWatch + S3; platform concern |
| S3 URI column in document table | Infra detail; tenant cares about document name, not `s3://…` |
| `POST /dashboard/refresh` | Same as above |

`DailyMetricsJob` and Aurora/S3 collection in `SimpleMetricsService` **remain in code** for platform/backfill (`lib/tasks/metrics.rake`, scheduled jobs). They are no longer exposed in the tenant UI.

### Kept / improved

| Section | Source | Notes |
|---------|--------|-------|
| Costo hoy / mes | `CostMetric` ← `BedrockQuery` | Estimated USD; ±10% vs AWS |
| Consultas chat | `daily_queries` (`source: query` only) | Renamed from “Queries” |
| Gráfico por canal LLM | `DashboardCostChartService` | Calendar month; lines with cost > 0 |
| Desglose hoy | `UsageMetricsHelper` / `LlmUsageChannel` | Same as home chat footer |
| Documentos en KB | `KbDocument` (DB) | No live S3 list on page load |
| Rendimiento | `BedrockQuery.query` today | Chat latency only (excludes ingestion) |

---

## Layout (current)

```
Uso y consumo
├── 3 cards: Costo hoy | Costo del mes | Consultas chat hoy
├── Resumen del mes + gráfico líneas (por canal LLM)
├── Desglose de costos (hoy)
├── Documentos en KB (tabla)
└── Rendimiento consultas chat (hoy, si hay datos)
```

---

## Multi-tenant projection (Stage 1+)

**Today (MVP):** all metrics and `KbDocument` rows are **global** — suitable for a single pilot tenant only.

**Before exposing `/dashboard` to multiple paying tenants:**

### 1. Data scoping

| Model / table | Change |
|---------------|--------|
| `bedrock_queries` | Add `account_id` (nullable → backfill → NOT NULL) |
| `cost_metrics` | Scope rollups by `[date, metric_type, account_id]` **or** compute tenant totals from scoped `BedrockQuery` (prefer explicit rollups at scale) |
| `kb_documents` | Add `account_id`; filter list and ingestion paths |
| Jobs | Pass `account_id` from controller/session into `TrackBedrockQueryJob`, upload jobs, RAG |

### 2. Authorization

- Only **tenant admin** role sees `/dashboard` and cost figures.
- Field technicians (`/`, chat) keep the lightweight footer metrics scoped to their org when multi-tenant lands.
- Platform super-admin: separate internal surface (not this dashboard).

### 3. Services to update

- `MetricsHelper#current_metrics` / `#monthly_totals` — filter by `Current.account_id`
- `DashboardCostChartService` — same date range, scoped `CostMetric` or `BedrockQuery`
- `DashboardController#index` — `@kb_documents = KbDocument.where(account_id: …)`
- `SimpleMetricsService.update_database_metrics_only` — per-account upserts (or one job per account)

### 4. What stays global (platform)

- Aurora ACU, S3 bucket totals, CloudWatch — **never** on tenant dashboard
- `DailyMetricsJob` — internal/platform scheduling only

### 5. Billing seam (future)

Tenant dashboard cost columns are **consumption estimates** for transparency and quotas. Invoice-grade numbers may come from a billing pipeline (Stripe + usage records). Document the delta vs AWS Cost Explorer in tenant-facing copy (already noted in UI).

---

## JSON API

`GET /dashboard/metrics` returns:

```json
{
  "current": { … CostMetric.daily_snapshot … },
  "monthly": { "total_cost", "total_queries" },
  "chart": { "title", "labels", "datasets" },
  "updated_at": "…"
}
```

Removed from JSON: `last_month`, infra fields. Add tenant-scoped fields when `account_id` exists.

---

## Implementation map

| File | Role |
|------|------|
| `app/controllers/dashboard_controller.rb` | Tenant dashboard actions |
| `app/controllers/concerns/metrics_helper.rb` | Today + month rollups |
| `app/services/dashboard_cost_chart_service.rb` | Chart payload |
| `app/helpers/usage_metrics_helper.rb` | Channel labels + metric type mapping |
| `app/views/dashboard/index.html.erb` | UI |
| `app/javascript/controllers/cost_chart_controller.js` | Chart.js (UMD in `public/vendor/`) |
