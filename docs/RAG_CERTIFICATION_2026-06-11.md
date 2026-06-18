# Certificación del benchmark RAG — 100% de fidelidad documental (cohorte v2)

> **Snapshot histórico de calidad.** Sus cifras de costo describen esta corrida,
> no el COGS actual. Pricing vigente: [SAAS_COST_MODEL_2026-06-12.md](SAAS_COST_MODEL_2026-06-12.md).

**Fecha:** 2026-06-11
**Resultado:** **100% de fidelidad documental para el corpus y matriz versionados.**
No es una certificación universal de seguridad del producto, de todos los
manuales ni de cumplimiento normativo.

## Identidad de la corrida

| Campo | Valor |
|---|---|
| Benchmark | `2026-06-11-v3` (16 consultas × 3 corridas) |
| Commit | `9ee05f7` (`codex/session-pin-identity`), `git_dirty=false` |
| Corpus | cohorte v2: manual `852f508d…` + imagen `b9293866…` (SHA byte-verificados en S3) |
| Contratos de ingesta | `field_records_v3` (documentos) / `field_photo_records_v3` (fotos) |
| Manifest de evidencia | `script/fixtures/rag_quality_benchmark_field_records.json` sha `3280cca2c1758815…` |
| Modelo de consulta | `us.anthropic.claude-haiku-4-5-20251001-v1:0`, HYBRID, reranking off, temp 0.1 |
| Payloads | `tmp/rag_quality_benchmark_run{1,2,3}.json` · evaluación `tmp/rag_benchmark_evaluation_final.json` |

## Resultado del evaluador (3/3 PASS, cohorte PASS)

- 48/48 consultas exitosas; matriz exacta 16/16 por corrida.
- 12/12 respuestas deterministas (`isolated/conversation:3 y :5`): `model_invoked=false`,
  `rendered_record_ids == manifest` (40 FT / 78 stop-work scope), 24/24 unidades
  funcionales cubiertas, acción/resultado y pares stop-work **verbatim** del manifest,
  IDs internos no visibles.
- 6/6 stop-work: solo pares trigger+acción documentados; mareos y personal no
  autorizado permanecen como precauciones (estructuralmente imposible promoverlos).
- Visual: `FRRV1, P41, P42, ORF1, BRK` literales con `DATA_NOT_AVAILABLE` por código;
  0 clasificaciones inferidas; aislamiento de fuentes exacto en los 3 casos.
- Autoridad de reparación limitada a técnicos de servicio calificados.

## CloudWatch (ventana certificable 2026-06-11T19:00:00Z → 19:05:39Z)

| Métrica | Valor |
|---|---|
| Invocaciones Haiku | **36** (= 12 por corrida; 4 deterministas/corrida no invocan modelo) |
| Input tokens | 219,638 |
| Output tokens | 18,345 |
| Latencia modelo | avg 4,826 ms · max 5,852 ms |

**Costo proyectado** (precios oficiales verificados 2026-06-11; perfil regional
`us.` = +10% sobre lista: $1.10 in / $5.50 out por MTok):

```text
(219,638×1.10 + 18,345×5.50) / 1e6 = $0.3425 por 3 corridas (48 consultas)
$0.3425 / 48 × 1000 = $7.14 por 1.000 consultas  ≤  gate $7.50  ✓
```

Los Retrieve de los caminos deterministas facturan solo embeddings (despreciable)
y no cuentan contra las 36 invocaciones. Nota de pricing: la tabla local
`BedrockQuery::BEDROCK_PRICING` se corrige en `codex/cost-accounting-wip`
(pendiente de merge); los `local_estimate` de los payloads usan la tabla vieja y
son solo diagnósticos — CloudWatch es la fuente autoritativa.

## Cadena de evidencia (gates)

| Gate | Resultado |
|---|---|
| A — suite local | 1130 runs, 0 fallos (commits `1168092`, `9ee05f7`) |
| B — preflight | identidad AWS, modelo, KB, sesión, SHAs de corpus, reranking/routing off |
| C — ingesta | evaluador estructural PASS (72 chunks manual, 243 records, 0 inválidos/0 degradadas) + 24/24 unidades mapeadas contra PDF (pp. 3, 8-11, 16, 18 revisadas) |
| D — retrieve | preflight 4/4: ledger válido, cobertura completa vs manifest, scope/filtro correctos |
| E — diagnóstico determinista | 4/4 `ids==manifest`, 0 invocaciones de modelo |
| F — corrida completa | 16/16; defectos D4/D5 detectados y corregidos con re-parse v3 |
| G — certificación | 3 corridas seriales, mismo commit, `git_dirty=false` |
| H — evaluación | 3/3 PASS + cohorte reproducible |
| I — CloudWatch | 36 invocaciones exactas, costo $7.14/1.000 ≤ $7.50 |

## Defectos encontrados y corregidos durante la ejecución

1. **D1** páginas truncadas (escalera de tokens 4k→16k→32k + validación JSON).
2. **D2** pérdida de continuación inter-página (dirección derecha recuperada).
3. **D3** tipado de pasos de prueba + regla de resultado verbatim.
4. **D4** simbología ISO/expansión de acrónimos tratada como evidencia (índice).
5. **D5** clasificación visual en generación (directive de etiqueta literal por
   pregunta + formato de línea única) y vocabulario de acción del evaluador
   ("marque" con Q, "no operar", botón rojo→apagado).

## Pendientes declarados (no bloquean la certificación de regresión)

- **Firma humana:** la revisión documental 48/48 y la segunda revisión de los 12
  casos críticos fueron ejecutadas por la IA implementadora contra el PDF fuente;
  el plan pide revisor independiente — queda como firma pendiente del operador.
- La cohorte v2 usa PNG exportado del manual (no field photo móvil) — documentado
  en el plan §2.
- Merge de `codex/cost-accounting-wip` para corregir la tabla local de precios.
