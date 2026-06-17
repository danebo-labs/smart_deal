# Gate 9R — O1′ / O5 phase tracker

**Última actualización:** 2026-06-17  
**Branch de referencia:** `codex/o4b-ingestion-noise-reduction`  
**Plan maestro:** `.cursor/plans/rag_precision_cost_plan_578aea0c.plan.md`

Este documento rastrea las sub-fases **O1′** (compresión + telemetría foto) y **O5** (señal de contenido / routing Opus). No sustituye [INGESTION_COST_V2.md](INGESTION_COST_V2.md) ni [METRICS.md](METRICS.md) — apunta a ellos para ADR y schemas.

---

## Distinción O5-fotos vs O5-manuales

| Track | Superficie | Decisión Opus hoy | Estado |
|-------|------------|-------------------|--------|
| **O5-fotos** | `FieldPhotoDensityGate` → evento `field_photo_gate` | Bytes-only: `≥ 1.5 MB → :opus`, else `:sonnet` | O5-A ✅ · O5-B bloqueado |
| **O5-manuales** | `PageRelevanceFilter#scanned_dense?` → `force_opus` per-page PDF | Heurística escaneado denso: `text_layer_chars < 100` AND `image_ratio > 0.7` | Gated — sin cambios en O5-A |

No mezclar los tracks: O5-A solo instrumenta fotos de campo; el audit `force_opus` de manuales PDF es **O5-manuales** y exige shadow §8b propio.

---

## O1′ — compresión e instrumentación

### O1′ instrumentación — ✅ COMPLETADA (2026-06-16)

- `image_compression`: `resize_applied`, `output_correlation_id`, `filename`/`correlation_id`
- `field_photo_gate`: `model`, `route`, `correlation_id`, bytes/dims/format
- Join chains web/bulk documentados en [METRICS.md — Image telemetry](METRICS.md#image-telemetry-event-schemas-o1)
- **Sin cambio** de `should_skip_compression?`, `MAX_DIMENSION`, quality, umbral gate ni routing Sonnet/Opus

### O1′ auditoría bytes-only — WAIT (2026-06-16)

Ver [INGESTION_COST_V2.md § Gate 9R O1′](INGESTION_COST_V2.md#gate-9r-o1--auditoría-bytes-only-2026-06-16):

- Cohorte n=7: sin señal de tokens que justifique resize bytes+dims
- **Decisión:** no cambiar `should_skip_compression?` hasta n≥50 en producción

### O1′ funcional (bytes + dimensions) — ⏸ BLOQUEADO

Acumular **n≥50** fotos de campo en producción e inspeccionar telemetría (`image_compression`, `field_photo_gate`, join `bedrock_queries`) **antes** de cambiar criterio de compresión.

---

## O5-fotos — FieldPhotoDensityGate

### O5-A — ✅ COMPLETADO (`9f95de3`, 2026-06-17)

**Commit:** `9f95de363cd2db81969f254f73f19b6f1e167868`  
**Mensaje:** `feat(ingestion): instrument field photo content signal`

**Entregables:**

- `field_photo_gate` emite **`white_ratio`** (fracción píxeles luma >240, thumbnail ≤256px, 3 decimales) y **`luma_mean`** (promedio luma 0–255, 1 decimal)
- Proxy **PNG vs JPEG descartado** (correlación débil con diagramas en cohorte O1′)
- **Routing sin cambio:** decisión sigue bytes-only (`LARGE_PHOTO_THRESHOLD = 1_500_000`)
- Falla de señal de contenido → campos ausentes; routing y telemetría base intactos

**Verificación al cierre:**

| Check | Resultado |
|-------|-----------|
| `bin/rails test` | 1309 runs, 3911 assertions, 0 failures, 164 skips esperados |
| `RUBOCOP_CACHE_ROOT=/private/tmp/rubocop_cache bin/rubocop` | 314 files, no offenses |
| `git diff --check` | clean |

**Docs:** [INGESTION_COST_V2.md § O5-A](INGESTION_COST_V2.md), [METRICS.md `field_photo_gate`](METRICS.md#field_photo_gate-event)

### O5-B — ⏸ BLOQUEADO

**Objetivo:** gate híbrido bytes + `white_ratio`/`luma_mean` para corregir fallas simétricas detectadas en O1′:

| Caso | Problema |
|------|----------|
| Tablero fotográfico pesado (≥1.5 MB) | Opus por peso, no por necesidad de fidelidad de líneas |
| Esquema técnico liviano (<1.5 MB) | Sonnet aunque requiere fidelidad de anotaciones finas |

**Precondiciones (ambas obligatorias):**

1. Acumular **n≥50** fotos de campo en producción con telemetría O1′ + O5-A
2. Autorizar **validación shadow §8b** del plan maestro antes de cambiar routing

Hasta entonces: **no tocar** `FieldPhotoDensityGate#heuristic_route` ni `LARGE_PHOTO_THRESHOLD`.

---

## O5-manuales — force_opus / PageRelevanceFilter

**Estado:** ⏸ GATED — pendiente, separado de O5-A/O5-B.

- Superficie: páginas PDF con `scanned_dense?` → Opus en parse per-page (sync y batch)
- Cohorte V1: 2 págs Opus ≈ 41% del coste de parse del manual de referencia
- Hipótesis experimental: Sonnet + max_tokens alto vs Opus de referencia; ahorro estimado −$2–3/manual
- **Gate:** comparación por-página + shadow §8b — misma regla dura que O5-B pero sobre contrato manual, no sobre `field_photo_gate`

---

## Referencias cruzadas

- ADR costo/routing foto: [INGESTION_COST_V2.md](INGESTION_COST_V2.md)
- Schemas + CSV inspección: [METRICS.md](METRICS.md#image-telemetry-event-schemas-o1)
- Routing PDF force_opus: [INGESTION_ROUTING.md](INGESTION_ROUTING.md)
- Shadow obligatorio para cambios de routing/contrato: plan maestro §8b
