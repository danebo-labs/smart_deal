# Paso F — medición «antes», previa a la sincronización del Knowledge Base

**Fecha:** 2026-07-29.
**Alcance ejecutado:** corridas en sombra contra producción, **solo lectura**, exigidas por
[RAG_PRECISION_V2_PLAN_2026-07-29.md](RAG_PRECISION_V2_PLAN_2026-07-29.md) §5 Fase 6
(«Producción en sombra») y §5 Fase 0 punto 3.
**No ejecutado, por prohibición explícita:** escritura en S3, sincronización del KB, cambio de
flags en PROD, despliegue. El `ingestion job` **no** se disparó.

## 1. Configuración registrada en cada corrida

| Campo | Valor |
|---|---|
| Commit desplegado | `7c5e9545f4fd1452104ae7ae788b2ac5361577af` (`kamal app details`) |
| Documento | `SEGURIDADES 1.1-1`, `KbDocument id=12`, `account_id=1` |
| Knowledge Base | `Y7RZWMFJSR` · data source `PJ0N58DMHG` |
| Contrato de ingesta | `field_records_v5` en **3 200/3 200** chunks inspeccionados |
| `section_identity` en la metadata del KB | **0/3 200 chunks** |
| Config A (camino vivo) | `RagRetrievalProfile` → `top_k = 3` (5 en `thyssen_e_led`) |
| Config B (descubrimiento Fase 1) | `RagRetrievalProfile::MAX_RESULTS` → `top_k = 20` |
| Filtro | `force_entity_filter: true`, `entity_sources: ["document"]` |

El backfill de Fase 2 está aplicado en S3 (97/97 sidecars) pero es **inerte para la consulta**:
el KB no devuelve `section_identity` en ningún chunk. Es la medición «antes» que el sync debe mover.

## 2. Estabilidad de Retrieve — 5 corridas por pregunta, sin generación

160 llamadas `Retrieve` por configuración (32 preguntas × 5), sin invocar generación.

**Resultado: determinismo total.** En las dos configuraciones, **32/32 casos** devolvieron el mismo
`first_hit` y la misma lista de páginas en las cinco corridas. Varianza cero: la inestabilidad de
recuperación queda descartada como causa de los fallos del gate.

### Recall por cohorte (Config B, `top_k = 20`)

| Cohorte | Casos | recall@3 | recall@10 | recall@20 | MRR medio |
|---|---:|---:|---:|---:|---:|
| v3.2 (`seguridades-v3.2`) | 12 | 10/12 | 12/12 | 12/12 | 0.820 |
| v1.2 (`seguridades-pilot-v1.2`) | 10 | 8/10 | 9/10 | 9/10 | 0.758 |
| v2 (`seguridades-pilot-v2.0`) | 10 | 6/10 | 9/10 | 9/10 | 0.524 |
| **Agregado** | **32** | **24/32** | **30/32** | **30/32** | **0.708** |

**`recall@20` no mejora sobre `recall@10`** — confirma la corrección A2/B1 del plan. Los dos casos
nunca recuperados son `cerrojos_conexion_generica` (v1.2) y `enier_mxl1_leds` (v2).

### Corrección de medición que impone este paso

`recall@10` y `recall@20` **no eran medibles con la configuración viva**: `RagRetrievalProfile`
entrega `top_k = 3`, así que ambas métricas colapsan sobre `recall@3` por construcción. La brecha
entre las dos configuraciones es el hallazgo operativo central:

> **6 de 32 páginas correctas viven en los rangos 4–10 y el camino vivo nunca las ve.**
> `tpr50_spm` (rango 10), `em4000_obstaculo_conectores` (7), `cerrojos_generica` (7),
> `thyssen_serie_e_leds` (6), `ekm66_h40_sin_averia` (4), `edel_k2_led31` (3, al límite).

Es exactamente el problema que el patrón «descubrir amplio, entregar estrecho» de Fase 1 ataca, y
es independiente del backfill.

## 3. Corrida end-to-end — una por caso, las tres cohortes

| Cohorte | `run_id` | Resultado | Score | Invenciones críticas |
|---|---|---|---:|---:|
| v3.2 | `seguridades:2d98be85…` | **12/12 PASS** | 82/88 | **0** |
| v1.2 | `seguridades:128ae1c7…` | **10/10 PASS** | 82/88 | **0** |
| v2 | `seguridades:8122a527…` | **6/10 FAIL** | 70/101 | **0** |

v2 reproduce el baseline de Fase 0 **exactamente** (6/10, 70/101, mismos cuatro fallos), con la
rúbrica v2.0 horneada en la imagen y con la v2.1 local re-evaluada offline: idéntico.

### Los cuatro fallos de v2 son de recuperación/abstención, nunca de invención

| Caso | Score | `required` no cumplidos |
|---|---:|---|
| `tpr50_spm` | 4/7 | serie correcta |
| `em4000_obstaculo_conectores` | 2/7 | incluye XC4, incluye XC7 |
| `enier_mxl1_leds` | 6/11 | serie 12 correcta, serie 19 correcta |
| `thyssen_serie_e_leds` | 4/17 | identifica L9/L8/L7, serie L9, serie L7 (+ sin cita válida) |

## 4. `expansion_mechanism` — la premisa era falsa en las dos puntas

La premisa a medir era «hoy `adjacent_page_interim`, tras el sync `section_identity`». Medido contra
el chunk **real** de la divisoria ENIER (`chunk_33.txt`, página 35, que **sí** se recupera en rango 3
con `top_k=20`), **ninguna de las dos era cierta**: el selector no llegaba a intentar la expansión.
Causas en §5 (H-A y H-B), ya corregidas.

Con H-A y H-B arreglados, la medición pasa a ser interpretable:

| Escenario | `divider_chunk?` | Resultado | `expansion_mechanism` |
|---|---|---|---|
| **antes** — KB sin `section_identity` | `true` | `insufficient`, 0 contextos | ninguno · rechazo etapa 5 `divider_expansion_failed` |
| **después** — KB con `section_identity` | `true` | **`direct`**, 1 contexto | **`section_identity`** (página 36) |

**Reparto de `expansion_mechanism` en el «antes»: 0 expansiones autorizadas de 1 intento.**

### H-D · `adjacent_page_interim` cubre 2 de 18 divisorias, no el corpus

`SectionNeighborExpander#authorize` solo alcanza el mecanismo interino si el vecino no declara
encabezado, o si su encabezado coincide con el de la divisoria. Ninguna de las 18 divisorias
declara encabezado `## ` (0/18, medido), así que la segunda vía está muerta y solo queda la
primera. Barrido de los 18 pares divisoria–vecino: el interino podría autorizar **solo en
`27→28` y `54→53`**.

Para las **16 divisorias restantes, ENIER incluida, `section_identity` es la única vía**. El sync no
es una mejora incremental sobre el mecanismo interino: es lo que hace funcionar la expansión vecinal
en 16 de 18 secciones.

## 5. Hallazgos — H-A y H-B corregidos en esta tarea, H-C abierto

### H-A · `divider_chunk?` estaba invertido respecto del corpus real — CORREGIDO

`Rag::EvidenceCandidateSelector#divider_chunk?` exige un encabezado `## ` presente. La divisoria
real de ENIER **no tiene** encabezado `## `, contiene `FIELD_RECORD:` y mide 896 caracteres. Falla
**tres** de las cuatro condiciones del predicado.

Contradice de frente la regla que usó el propio backfill de Fase 2
([…FASE2_DECISION…](RAG_SEGURIDADES_METADATA_BACKFILL_FASE2_DECISION_2026-07-29.md) §3.2):
*«Divisoria = página cuyo cuerpo **no** declara encabezado `## ` ni línea `**Section:**`»*.
Verificado por ejecución: `regla_backfill_fase2_dice_divisoria: true` · `divider_chunk?: false`.

Barrido de los 97 chunks: la regla de Fase 2 acierta **18/18 divisorias, cero falsos positivos y
cero falsos negativos**; el predicado anterior satisfacía **0/18**. Longitudes medidas: divisorias
442–1941 caracteres, contenido 4328–16295 — la cota de 400 no describía nada real, y
`FIELD_RECORD:` aparece en 11/18 divisorias y en 79/79 páginas de contenido.

**Corregido** en `evidence_candidate_selector.rb`: `divider_chunk?` pasa a exigir ausencia de
encabezado `## ` y de `**Section:**`, la misma regla que produjo la metadata. `DIVIDER_MAX_LENGTH`
retirada.

### H-B · La expansión vecinal abortaba con `Encoding::CompatibilityError` — CORREGIDO

[`S3DocumentsService#download`](../app/services/s3_documents_service.rb#L176) fuerza
`Encoding::BINARY`. `Rag::SectionNeighborExpander#neighbor_chunk` construye el chunk vecino con ese
cuerpo, y al reevaluarlo `Rag::QueryEntities.strip_diacritics` llama `unicode_normalize` sobre
ASCII-8BIT y **lanza**. Reproducido:

```
Encoding::CompatibilityError: Unicode Normalization not appropriate for ASCII-8BIT
  query_entities.rb:162 → evidence_candidate_selector.rb:186 → :165 → :106 → :64
```

Con `force_encoding("UTF-8")` el mismo cuerpo pasa sin error.

**Brecha de fidelidad de test, cerrada:** ningún test emparejaba el expander real con el contrato
de `S3DocumentsService` — el `FakeS3` devolvía literales UTF-8. Ahora devuelve ASCII-8BIT como el
servicio real, y un test nuevo verifica que el cuerpo del vecino llega en UTF-8 utilizable y que
`Rag::QueryEntities` no lanza sobre él. Comprobado por mutación: revertir el arreglo hace fallar
ese test.

**Corregido** en `section_neighbor_expander.rb`: los cuerpos y sidecars que lee pasan por
`force_encoding(UTF-8).scrub` en un único punto (`text_body`). No se tocó `S3DocumentsService`:
forzar `BINARY` es correcto para su contrato, que también sirve PDFs e imágenes.

### H-C · El camino solo-metadata no tiene precedente en este KB

Los tres jobs recientes (`WBIPOXFNNL` 07-25, `VR2R7FQHZU` 07-26, `YKONVYAVWU` 07-28) reportan
`numberOfMetadataDocumentsModified: 0`; los `numberOfModifiedDocumentsIndexed: 1` de 07-26 y 07-28
fueron cambios de **cuerpo**. El backfill cambió *solo* metadata: no hay evidencia en el historial
de este KB de que Bedrock re-indexe los 97 por un cambio así.

Además, los tres jobs reportan `numberOfDocumentsFailed: 1` de forma consistente.

## 6. Gates de §6 evaluados por cohorte

| Gate | v3.2 | v1.2 | v2 |
|---|---|---|---|
| Respuestas correctas (1 corrida; el gate pide 5) | 12/12 ✅ | 10/10 ✅ | 6/10 ❌ |
| **0 invenciones críticas** | ✅ | ✅ | ✅ |
| Casos directos con evidencia en top 3 | 10/12 ❌ | 8/10 ❌ | 6/10 ❌ |
| Cita válida en todo caso que la exige | ✅ | ✅ | ❌ (`thyssen_serie_e_leds`) |
| Ninguna ausencia cuando el dato existe en un candidato | ❌ | ❌ | ❌ |
| Estabilidad de recuperación | ✅ 12/12 | ✅ 10/10 | ✅ 10/10 |
| Payload `resolution_mode`, flag, telemetría de evidencia | — no evaluable: Fase 3 sin implementar | — | — |

**Ningún gate de liberación cierra.** El único que cierra limpiamente en las tres cohortes es
«0 invenciones críticas»: el sistema se abstiene en lugar de inventar, incluso cuando falla.

## 7. Artefactos

Bajo `tmp/`, fuera de git:

- `pasoF_antes_retrieve_2026-07-29.json` — estabilidad, Config A (`top_k` de producción).
- `pasoF_antes_retrieve_topk20_2026-07-29.json` — estabilidad, Config B (`top_k = 20`).
- `pasoF_antes_V32_2026-07-29.json`, `pasoF_antes_V12_2026-07-29.json`, `pasoF_antes_V2_2026-07-29.json` — end-to-end crudo por cohorte.
- `pasoF_antes_V2_eval_v21_2026-07-29.json` — re-evaluación offline de v2 con la rúbrica v2.1.

## 8. Estado

| Paso | Estado |
|---|---|
| F.1 · commit/documento/KB/contrato registrados | hecho |
| F.2 · 5 corridas de Retrieve por pregunta, sin generación | hecho, dos configuraciones |
| F.3 · 1 corrida end-to-end por caso × 3 cohortes | hecho |
| F.4 · reparto de `expansion_mechanism` | hecho — 0 expansiones; premisa corregida |
| Sincronización del Knowledge Base | **no autorizada, no ejecutada** |
