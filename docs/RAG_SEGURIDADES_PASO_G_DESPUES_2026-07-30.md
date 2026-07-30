# Paso G — sincronización y medición «después»

**Fecha:** 2026-07-30.
**Resultado:** la metadata `section_identity` quedó sincronizada, pero los gates no
cierran. **Paso H bloqueado: no desplegar, no activar flags.**

## 1. Estado evaluado

| Campo | Valor |
|---|---|
| Código evaluado localmente | `85b7d4233fc553e2afe6b334f9f266b83a1431d6` |
| Commit aún desplegado en PROD | `7c5e9545f4fd1452104ae7ae788b2ac5361577af` |
| Documento | `SEGURIDADES 1.1-1` · `account_id=1` |
| Source URI | `s3://multimodal-source-destination/uploads/1/b61f5d54-ff42-414a-97b7-01682d16f4b5/original.pdf` |
| Knowledge Base | `Y7RZWMFJSR` |
| Data source | `PJ0N58DMHG` |
| Región | `us-east-1` |
| Flags durante el end-to-end | selector, expansión, tarjetas y fuentes: `false` |
| Selector medido en sombra | `evidence_candidate_selector_v1`, con expansión |

No se volvió a ejecutar el backfill, no se subió ni re-chunkeó el PDF y no se
modificaron flags ni aplicaciones en producción.

## 2. Único ingestion job

El primer intento de `StartIngestionJob` fue rechazado antes de crear un job porque
Aurora estaba reanudándose tras auto-pausa. Se verificó que no existía un job nuevo,
Aurora pasó a `available` y se repitió la llamada con el mismo token idempotente.

Job creado: `D3QMVZNBEH`.

| Estadística | Resultado |
|---|---:|
| Estado | `COMPLETE` |
| Documentos escaneados | 1 686 |
| Metadata escaneada | 1 686 |
| Nuevos indexados | 0 |
| Cuerpos modificados | 0 |
| **Metadata modificada** | **97** |
| Eliminados | 0 |
| Fallidos | 1 |

El único fallo se identificó como el mismo chunk sobredimensionado de `account_id=2`
que ya había fallado en los tres jobs anteriores: 11 674 tokens frente al máximo de
8 192. No pertenece a SEGURIDADES, no fue causado por el backfill y, por instrucción
explícita del usuario, no se realizó ninguna otra acción sobre ese u otros PDF.

## 3. `section_identity` disponible en Retrieve

Se ejecutaron consultas filtradas por `original_source_uri` exclusivamente a
SEGURIDADES. Se comprobó metadata indexada en seis secciones:

| Sección | Evidencia recuperada |
|---|---|
| ALJO | páginas 7 y 2 con `section_identity=ALJO` |
| CARLOS SILVA | páginas 8–12 con `section_identity=CARLOS SILVA` |
| ELECMEGON | páginas 27 y 29–32 con `section_identity=ELECMEGON` |
| ENIER | divisoria p. 35 con `section_identity=ENIER`, rango 3 |
| EXCELSIOR | páginas 40 y 37 con `section_identity=EXCELSIOR` |
| THYSSEN | páginas 92–95 con `section_identity=THYSSEN` |

En las 160 corridas de Config B posteriores, todos los conjuntos recuperados
incluyeron `section_identity`; antes era 0/160.

## 4. Retrieve «después»

Procedimiento idéntico al Paso F: 32 preguntas × 5 corridas, primero con
`RagRetrievalProfile` y después con `top_k=20`; 320 llamadas Retrieve, sin
generación. El filtro fue `force_entity_filter=true`,
`entity_sources=["document"]`.

Las listas de páginas fueron **idénticas antes/después en 32/32 casos y cinco
corridas**. La metadata no alteró embeddings, rangos, recall ni MRR.

### Config B — descubrimiento `top_k=20`

| Cohorte | recall@3 | recall@10 | recall@20 | MRR | Estabilidad |
|---|---:|---:|---:|---:|---|
| v3.2 | 10/12 | 12/12 | 12/12 | 0,820 | 12/12 |
| v1.2 | 8/10 | 9/10 | 9/10 | 0,758 | 10/10 |
| v2.1 | 6/10 | 9/10 | 9/10 | 0,524 | 10/10 |

### Latencia Retrieve

La medición no cierra el gate de p95 ≤ +15 %. Incluso en Config A, comparable sin
tiempo del selector, los p95 subieron:

| Cohorte | p95 antes | p95 después | Cambio |
|---|---:|---:|---:|
| v3.2 | 534 ms | 688 ms | +28,8 % |
| v1.2 | 538 ms | 719 ms | +33,6 % |
| v2.1 | 569 ms | 679 ms | +19,3 % |

Son corridas en momentos distintos y no demuestran por sí solas una regresión causal
de metadata; sí demuestran que el gate no puede declararse cerrado con esta muestra.

## 5. ENIER y `expansion_mechanism`

La parte estructural funciona:

1. Retrieve sigue sin devolver la página 36 dentro del top 20.
2. La divisoria ENIER de página 35 aparece en rango 3.
3. `SectionNeighborExpander` autoriza página 36 mediante
   **`section_identity`**, no `adjacent_page_interim`.
4. La página 36 aporta `12 | SERIE STOP Y SEGURIDADES HUECO`.
5. El resultado es idéntico en 5/5 corridas.

Pero el resultado final del selector es incorrecto: `mode=ambiguous`, con cinco
contextos visibles inicialmente:

- SCHINDLER p. 81, por el pin 12 de un conector;
- **ENIER p. 36**, evidencia correcta;
- FAIN p. 42, por una enumeración de bornes que contiene 12;
- OTIS p. 69, por un conector de 12 pines;
- RECOBA p. 71, por una lista que contiene 12 y 19.

Por tanto, el cambio de mecanismo **sí ocurre**, pero no convierte el caso en
`direct`: el gate ENIER falla.

## 6. Diagnóstico del selector

Modos observados, estables en 5/5 corridas:

| Cohorte | Direct | Ambiguous | Insufficient |
|---|---:|---:|---:|
| v3.2 | 1 | 9 | 2 |
| v1.2 | 1 | 9 | 0 |
| v2.1 | 2 | 8 | 0 |

En v2.1 solo `altius_d8_d11` y `tokibat_dl27_v2` quedan directos. Casos que
nombran explícitamente TPR50, SR8P, EM2000, EM4000 V1, EDEL-K3, ENIER MXL1 y
Thyssen Serie E se vuelven ambiguos.

Causa concreta:

1. La etapa de scope se considera resuelta upstream, pero el selector no recibe un
   alcance estructural ya resuelto.
2. El filtro de familia solo excluye con confianza de metadata ≥ 0,7; una identidad
   escrita por el usuario no llega a ese umbral.
3. Para identificadores numéricos, cualquier fragmento que contenga el número puede
   sobrevivir, incluido un conteo de pines o una lista de bornes.
4. `responds_to_relation?` solo exige tres palabras; aliases y encabezados pasan sin
   demostrar la relación solicitada.
5. Dos grupos supervivientes fuerzan `ambiguous` y los primeros cinco contextos se
   conservan por rango, de modo que falsos positivos desplazan evidencia correcta.

Ejemplos:

- `tpr50_spm`: ofrece CARLOS SILVA y SISTEL aunque la pregunta nombra TPR50.
- `cta_sr8p_sph`: mezcla SR8P, CR8PH2, M8PC y ALJO.
- `em4000_obstaculo_conectores`: los cinco primeros contextos no contienen la
  evidencia objetivo de página 33.
- `elecmegon_obstaculo_ambiguo`: solo 2/5 tarjetas iniciales pertenecen a páginas
  Elecmegon; también aparecen OTIS y RECOBA.

## 7. End-to-end «después»

Una corrida controlada por caso y cohorte, igual que Paso F:

| Cohorte | Run ID | Casos | Score | Invenciones críticas |
|---|---|---:|---:|---:|
| v3.2 | `seguridades:37d6f55b…` | **12/12** | 82/88 | 0 |
| v1.2 | `seguridades:b8f286dc…` | **10/10** | 82/88 | 0 |
| v2.1 | `seguridades:86e90caf…` | **6/10** | 70/101 | 0 |

v2.1 reproduce exactamente el baseline anterior: mismos cuatro fallos y mismo
score.

| Caso | Score | Evidencia del fallo |
|---|---:|---|
| `tpr50_spm` | 4/7 | declara ausencia de SPM aunque existe en p. 9 |
| `em4000_obstaculo_conectores` | 2/7 | declara ausencia de EM4000; no entrega XC4/XC7 |
| `enier_mxl1_leds` | 6/11 | declara ausencia de 12/19 aunque la expansión encontró p. 36 |
| `thyssen_serie_e_leds` | 4/17 | no entrega L9/L8/L7 completos y queda sin cita |

El camino end-to-end no mejora porque el selector está implementado como sombra en el
controlador: no sustituye la respuesta técnica. Con los flags apagados, el benchmark
directo continúa usando el camino vivo anterior.

## 8. Gates por cohorte

| Gate | v3.2 | v1.2 | v2.1 |
|---|---|---|---|
| 10/10 o cohorte completa, 5 corridas | 12/12 en 1 corrida; faltan 4 | 10/10 en 1; faltan 4 | **6/10 FAIL** |
| 0 invenciones críticas | ✅ | ✅ | ✅ |
| Directos con evidencia objetivo top 3, tras selector | 6/11 ❌ | 8/9 ❌ | **7/9 ❌** |
| Opciones ambiguas con extracto relevante | sobre-ambigüedad ❌ | sobre-ambigüedad ❌ | 2/5 en Elecmegon ❌ |
| Cita válida cuando se exige | ✅ | ✅ | Thyssen ❌ |
| Ninguna ausencia falsa | ✅ en esta corrida | ✅ en esta corrida | cuatro ausencias falsas ❌ |
| Estabilidad de recuperación | ✅ | ✅ | ✅ |
| `section_identity` disponible | ✅ | ✅ | ✅ |
| ENIER usa `section_identity` | n/a | n/a | ✅ mecanismo; ❌ modo final |
| Latencia p95 ≤ +15 % | ❌ muestra no cierra | ❌ | ❌ |
| Sin segunda llamada LLM directa | no se observó segunda LLM | no se observó | no se observó |
| Payload/telemetría/flag en PROD | no desplegado | no desplegado | no desplegado |
| Aprobación humana de diez respuestas | pendiente | pendiente | no procede con 6/10 |

El gate de cinco corridas end-to-end no se continuó: al fallar la primera corrida v2.1,
cuatro corridas adicionales no podían producir cinco éxitos consecutivos desde este
estado y solo habrían agregado costo.

## 9. Decisión

**NO-GO para Paso H.**

- No desplegar `85b7d42`.
- No activar selector, expansión ni tarjetas.
- Mantener `SHOW_RAG_SOURCES=false`.
- No iniciar otro ingestion job: la metadata necesaria ya está sincronizada.
- Corregir primero el scope técnico y el gate de relación del selector; después
  repetir la misma medición contra el KB ya sincronizado.

## 10. Artefactos locales

- `tmp/pasoG_section_identity_retrieve_2026-07-30.json`
- `tmp/pasoG_despues_retrieve_2026-07-30.json`
- `tmp/pasoG_despues_retrieve_topk20_2026-07-30.json`
- `tmp/pasoG_despues_V32_2026-07-30.json`
- `tmp/pasoG_despues_V12_2026-07-30.json`
- `tmp/pasoG_despues_V2_2026-07-30.json`
