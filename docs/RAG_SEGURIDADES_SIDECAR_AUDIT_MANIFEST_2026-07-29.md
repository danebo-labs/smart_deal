# SEGURIDADES sidecar audit manifest (Fase 2, punto 1 — solo lectura)

**Fecha:** 2026-07-29.
**Alcance:** fila Sonnet de la revisión (`~/.claude/plans/valida-este-plan-y-memoized-biscuit.md`,
A10) — "Manifiesto de auditoría de sidecars (solo lectura)", que implementa Fase 2 punto 1 de
`docs/RAG_PRECISION_V2_PLAN_2026-07-29.md`: *"Generar un manifiesto de auditoría, sin escribir, que
compare cada chunk con: encabezado visible; página; fabricante/modelo/placa; sección padre; página
anterior/siguiente de la misma sección."*
**Lo que este trabajo NO hace:** no escribe en S3/KB, no llama a Bedrock ni a producción, no hace
backfill de metadata (eso es Fase 2, puntos 2–3, con diff revisable y autorización humana aparte), y
no toca código productivo. Solo lee y compara.

## 1. Fuente de datos

El script (`script/audit_seguridades_sidecar_manifest_2026-07-29.rb`) lee los 97 pares
`chunk_N.txt` / `chunk_N.txt.metadata.json` ya descargados de producción el 2026-07-29 y guardados en
`tmp/pdfs/seguridades_audit/production_chunks/` (ver "Artefactos locales de auditoría" en
`docs/RAG_PRODUCTION_TRACE_2026-07-29.md`). No se repitió la lectura contra S3/KB: reutilizar la
copia ya auditada evita una llamada de producción adicional para un trabajo que es, por diseño,
mecánico y offline. El script acepta un directorio y una ruta de salida por parámetro si se quisiera
correr contra otra copia.

Ejecución:

```bash
ruby script/audit_seguridades_sidecar_manifest_2026-07-29.rb
# lee tmp/pdfs/seguridades_audit/production_chunks/
# escribe tmp/rag_seguridades_sidecar_manifest_2026-07-29.json
```

No requiere Rails, base de datos ni credenciales AWS — es Ruby puro sobre archivos locales.

## 2. Qué compara y por qué no hay campo `fabricante/modelo/placa`

`docs/RAG_EVIDENCE_SELECTOR_FASE1_DESIGN_2026-07-29.md` §F1 ya confirmó que ningún camino de
ingesta escribe `manufacturer`, `controller_model` ni `board_model` — esas claves no existen en el
contrato. Por tanto el manifiesto no inventa una comparación contra un campo inexistente: compara,
por chunk, lo que **sí** existe:

| Campo del manifiesto | Origen | Qué reemplaza en la regla del plan |
|---|---|---|
| `visible_heading` | Primera línea `## …` del cuerpo, o `**Document:** …` si no hay | "encabezado visible" |
| `page_number` | `metadataAttributes.page_number` | "página" |
| `canonical_name` | `metadataAttributes.canonical_name` | único candidato existente a "fabricante/modelo/placa" |
| `search_aliases` (primeros 5) | Línea `[SEARCH_ALIASES: …]` del cuerpo | señal de identidad real, más específica que `canonical_name` |
| `section_identity` | `metadataAttributes.section_identity` | "sección padre" |
| `section_line` | Línea `**Section:** …` del cuerpo, si existe | señal interina de sección, no promovida a metadata |
| `prev/next_page_number`, `prev/next_visible_heading` | Chunk vecino tras ordenar por página | "página anterior/siguiente de la misma sección" |

El script no incorpora ninguna lista de fabricantes o modelos: toda la comparación es
extracción de texto ya impreso en el propio chunk contra su propio sidecar.

## 3. Resultado agregado (97/97 chunks)

```json
{
  "total_chunks": 97,
  "distinct_canonical_name_count": 1,
  "distinct_canonical_names": ["ALJO Control Level 1B Altius"],
  "distinct_section_identity_values": [null],
  "distinct_visible_heading_count": 76,
  "chunks_with_section_identity": 0,
  "chunks_with_section_line": 35,
  "chunks_with_body_page_number": 49,
  "chunks_with_body_page_mismatch": 0,
  "chunks_where_canonical_name_not_visible_in_body": 1,
  "heading_changes_vs_prev": 94
}
```

Lectura de cada número:

1. **`distinct_canonical_name_count: 1` sobre 97 chunks, con `distinct_visible_heading_count: 76`.**
   Confirma numéricamente, no solo narrativamente, el hallazgo de §1.3 del plan: un único
   `canonical_name` ("ALJO Control Level 1B Altius" — el título de la página 2) cubre las 76
   identidades visibles distintas del documento (ALTIUS, HIDRA-TPR50/60/70, CTA SR8P/M8PC/CR8PH2,
   EM2000/3000/4000, EDEL-K2/K3, TOKIBAT, ENIER MXL1, Thyssen Serie E, y el resto de fabricantes de
   la tabla `keep/consolidate/retire`).
2. **`chunks_with_section_identity: 0`.** Confirma que el contrato `field_records_v5` de este
   documento no trae `section_identity` en ningún chunk — el campo que Fase 2 debe rellenar en el
   backfill.
3. **`chunks_with_section_line: 35` / `chunks_with_body_page_number: 49`.** Hallazgo nuevo, no
   anticipado por el plan: ni siquiera el formato **dentro del cuerpo** del chunk es consistente.
   Solo 35/97 chunks imprimen una línea `**Section:**` y solo 49/97 imprimen `**Page:**`; el resto
   solo tiene el encabezado `## …` o el `**Document:**` genérico. Cualquier extractor que dependa de
   esas líneas debe tratarlas como opcionales, no como parte estable del contrato v5.
4. **`chunks_with_body_page_mismatch: 0`.** Donde existe una línea `**Page:**`, siempre coincide con
   `metadataAttributes.page_number` (49/49). La metadata de página, a diferencia de la de identidad,
   es confiable.
5. **`chunks_where_canonical_name_not_visible_in_body: 1`.** Matiz importante para no sobre-leer el
   hallazgo 1: en 96/97 chunks el texto `canonical_name` **sí** aparece literalmente en el cuerpo,
   porque la línea `**Document:** ALJO Control Level 1B Altius` se repite como boilerplate en casi
   todos los chunks (ver tabla §4). El defecto no es que la identidad esté ausente del texto — es que
   la identidad impresa es **la misma cadena incorrecta en casi todas partes**, mientras la identidad
   real y específica vive en el encabezado `## …` y en `[SEARCH_ALIASES: …]`, que la metadata no
   captura. La única excepción (`chunk_90.txt`, página 92) es la divisoria "PIPELINE_INJECTED" de la
   sección Thyssen — cuerpo casi vacío, sin ni siquiera el boilerplate.
6. **`heading_changes_vs_prev: 94` sobre 96 pares consecutivos.** El encabezado visible cambia entre
   casi cualquier página y la siguiente — la granularidad real del documento es prácticamente
   página-por-página, muy por debajo de la única "sección" que hoy expone `canonical_name`.

## 4. Filas representativas (verdad-terreno del plan §2)

| Página | Encabezado visible | `canonical_name` | `section_identity` | Alias reales (primeros 3) |
|---:|---|---|---|---|
| 7 | ALTIUS — Diagrama de Cadena de Seguridades… | ALJO Control Level 1B Altius | `null` | ALTIUS, J3, J5 |
| 9 | HIDRA – TPR50 Safety Chain & Terminal Wiring… | ALJO Control Level 1B Altius | `null` | HIDRA TPR50, TPR50 V2-X1, 600200500 |
| 17 | CTA – SR8P (ELÉCTRICO Y HIDRÁULICO) — BORNAS CARRIL | ALJO Control Level 1B Altius | `null` | CTA SR8P eléctrico hidráulico, bornas carril, SR8P |
| 18 | Placa principal — Identificación de conectores visibles | ALJO Control Level 1B Altius | `null` | CTA SR8P premontada, CU15P, SR8P electrico hidraulico |
| 26 | EDEL-K3 Wiring Overview — Safety & Door Circuit… | ALJO Control Level 1B Altius | `null` | EDEL-K3, JH1, JH2 |
| 29 | EM3000 - ELECTRICO | ALJO Control Level 1B Altius | `null` | EM3000 Electrico, SEG, SPE |
| 31 | EM 2000 - ELÉCTRICO — Diagrama de Seguridades… | ALJO Control Level 1B Altius | `null` | EM 2000 ELECTRICO, EM2000, SEG |
| 33 | Placa EM 4000 V1 — Cadena de Seguridades… | ALJO Control Level 1B Altius | `null` | EM 4000 V1, XP13, XP14 |
| 36 | Placa MXL1 (Cadena de Seguridades) | ALJO Control Level 1B Altius | `null` | MXL1, enier, placa maniobra |
| 40 | TOKIBAT – 2.007 — LEDs de diagnóstico… | ALJO Control Level 1B Altius | `null` | TOKIBAT 2.007, RELES_HF V8, DL24 PTC |
| 93 | SERIE E — Cadena de Seguridades Principales | ALJO Control Level 1B Altius | `null` | THYSSEN, THYSSEN-E, SERIE E |

Cada fila confirma la misma forma de defecto: la columna `canonical_name`/`section_identity` no varía
nunca, mientras `visible_heading`/`search_aliases` sí llevan la identidad correcta y específica de
cada página — exactamente lo que Fase 2 debe trasladar a `section_identity` en el backfill.

## 5. Insumo directo para Fase 2 (no ejecutado aquí)

Este manifiesto es el "sin escribir" que precede al backfill de Fase 2 puntos 2–3. El backfill en sí
— decidir el `section_identity` por chunk, generar el diff revisable, aplicarlo con copia/hash previo
de los sidecars — es una tarea de Opus + autorización humana explícita según la tabla de asignación
de modelos (§12 de `docs/RAG_PRECISION_V2_PLAN_2026-07-29.md`) y queda fuera del alcance de esta
fila. Este documento y `tmp/rag_seguridades_sidecar_manifest_2026-07-29.json` son su insumo de
partida: 97 filas con encabezado real, página, alias reales y el `canonical_name`/`section_identity`
actuales, listas para que esa fase decida el valor correcto de `section_identity` por chunk contra el
PDF.

## 6. Artefactos

- `script/audit_seguridades_sidecar_manifest_2026-07-29.rb` — script de comparación, solo lectura,
  sin dependencia de Rails/AWS.
- `tmp/rag_seguridades_sidecar_manifest_2026-07-29.json` — manifiesto completo (97 filas + resumen),
  fuera de git como el resto de artefactos de benchmark bajo `tmp/`.
