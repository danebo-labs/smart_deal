# Plan ciclo 5 — Resolución de la Decisión humana #9 — Cierre de precisión RAG (2026-08-04)

**Objetivo:** liberar la aplicación a piloto corrigiendo los DOS hallazgos reclasificados
como bloqueantes por el dueño (2026-08-04): el título de cita con fabricante equivocado
(bug de caché de `Rag::SectionNeighborExpander`) y N8 (línea de identidad "ALJO…"
incrustada en 96/97 cuerpos de chunk + instrucción viva en el prompt de ingesta que la
reproduce) — y validar con un instrumento NUEVO (holdout v5 + batería de proveniencia),
difiriendo explícitamente lo no bloqueante.

**Entrada obligatoria:** `docs/rag/plan_ciclo4_ajuste_final_2026-08-03.md` completo — en
particular Anexo F (clasificación de los 3 fallos del gate v4), la "Corrección al caso 2"
(2026-08-04), el Anexo D (causa raíz de N8) y la "Decisión humana #9" actualizada con la
reclasificación del dueño. Este documento es AUTOCONTENIDO para las sesiones ejecutoras:
la evidencia que cada fase necesita está citada verbatim abajo (archivo:línea, hashes,
claves de caché); el ciclo 4 es la fuente si algo no cuadra, no lectura obligatoria por
fase.

**Línea base:** gate v4 = 124/136 (91.2%, supera el umbral numérico) pero NO PASA:
1 de los 4 casos `safety_critical` con `passed: false`
(`holdout_v4_carlos_silva_tpr70_b7_seguridad` — falso negativo del evaluador regex, no
defecto de la app; Anexo F ciclo 4 §1). Artefacto:
`tmp/rag_seguridades_holdout_v4_run1_2026-08-04.json`, SHA256
`5be0fcc5e14eef28e8803e2dd626fec606aec8f83422a336e39e2f0b8c893949`. **v1, v2, v3 y v4
están gastados: prohibido reabrirlos, ni con `RAG_SEGURIDADES_CASE_IDS`.** El page-pin
(N10) y el flag multi-placa (N11) del ciclo 4 funcionaron según diseño en 12/14 casos y
quedan desplegados — este ciclo NO los toca ni repite esa estrategia.

**Decisiones del dueño del producto (2026-08-04) incorporadas:**

1. **Reclasificación de los fallos del gate v4 (cerrada, no se reabre):**
   - **BLOQUEANTE para piloto — título de cita equivocado (caso #2b):** una cita que
     atribuye contenido THYSSEN a "ALJO Control Level 1B Altius" compromete la promesa
     central de trazabilidad del producto. Prioridad P0, Fase 1.
   - **BLOQUEANTE para piloto — N8:** deja de ser diferible sin fecha — la contaminación
     aparece en superficie visible (proveniencia), no sólo en el cuerpo interno.
     Prioridad P0, Fases 2-3.
   - **NO bloqueante — caso #1 (evaluador):** falso negativo del regex de rúbrica; la
     respuesta del modelo es correcta y segura. Sin fase de fix; se convierte en regla de
     redacción de rúbrica para el autor del v5 (Fase 4) — corrección de arnés de
     medición, no de la aplicación.
   - **NO bloqueante — caso #3 (nomenclatura "ARCA II" vs "ARCA básica"):** deuda P4 de
     identidad de variante documentada. Sin fase de fix; constancia en "Qué NO está en
     este plan".
2. **Excepción autorizada a "cero re-ingesta":** SOLO el parche de texto determinístico
   de N8 (sin ninguna llamada a Anthropic) + su resync de KB. Es una excepción
   justificada y acotada, no un olvido de la restricción heredada.
3. **Protocolo de validación final:** el dueño propuso originalmente 5 corridas completas
   de 14 preguntas nuevas cada una; este plan evalúa costo/rigor y PROPONE la alternativa
   B (checkpoint + holdout v5 de 14 preguntas + batería de proveniencia de ~15-20
   preguntas dirigida a los 2 bloqueantes) — trade-off explícito en la tabla de Estado,
   pendiente de veto del dueño antes de ejecutar la Fase 4.
4. **Modelos:** según el "Criterio para elegir modelo por fase" de la metodología —
   Sonnet 5 en código y análisis; Haiku 4.5 excluido de TODA fase que ejecute contra
   producción (lección ciclo 3); Opus 5 sólo consultas acotadas sobre un hallazgo ambiguo
   (nunca sesión completa); nunca Fable; checkpoint y gate con el modelo más riguroso del
   set (Sonnet 5, precedente del ciclo 4).
5. **Rediseño de `canonical_name` para compendios multi-marca (H9) — decidido
   2026-08-04:** SÍ se arregla el diseño (no sólo el dato), pero POST-ciclo 5:
   secuenciado después de que el gate v5 verifique que los fixes de este ciclo son una
   mejora contundente. No entra como fase de este plan (restricción de un objetivo por
   sesión + no hay ingestas nuevas posibles sin saldo Anthropic que lo hagan urgente).
   Ver la entrada correspondiente en "Qué NO está en este plan" para el alcance del
   futuro fix.

## Restricciones no negociables

1. Nada de regex nuevo de forma-de-pregunta (heredada del ciclo 4, restricción 6).
2. Cero re-ingesta / re-troceo, **con una única excepción autorizada este ciclo**: el
   parche de texto determinístico de N8 (Fase 3) — sustitución de texto por chunk SIN
   llamadas a Anthropic ni al modelo de visión, re-subida a S3 y resync del KB. La
   re-indexación completa con 2 versiones de KB (KB v1/KB v2) sigue FUERA DE ALCANCE:
   requiere llamadas de visión/Anthropic (ver restricción 3).
3. Sin saldo en la API de Anthropic de la app (desde 2026-08-02): ninguna fase la llama.
   Todo va por AWS Bedrock, facturación AWS aparte.
4. Presupuesto Bedrock declarado por fase; **techo del ciclo: 56 `retrieve_invocations`**
   (el techo de 36 del ciclo 4 no alcanza: la validación de este ciclo redacta y corre un
   instrumento NUEVO — holdout v5 + batería — en vez de reutilizar nada). El costo de
   re-embedding de los 96 chunks del resync (Titan, Fase 3) se anota aparte: es costo de
   ingesta, no de `retrieve`.
5. Límites de la cuenta de tooling: sesiones cortas, un objetivo por sesión, sin fan-out
   de subagentes.
6. Todo artefacto de corrida se copia a tmp LOCAL con SHA256 verificado ANTES de cerrar
   la sesión que lo generó. Un artefacto sólo-en-contenedor no cuenta como evidencia.
7. Ningún holdout se reabre una vez gastado: v1-v4 gastados. El v5 y la batería se abren
   UNA sola vez, en la Fase 6.
8. `bulk_chunks/` es ingestion-only: el parche de la Fase 3 REEMPLAZA los `.txt`
   existentes en su clave original; ningún artefacto derivado (manifest, sidecar nuevo,
   caché) se escribe bajo ese prefijo.
9. Los fixes del ciclo 4 (page-pin, flag N11, guardrail de presentación, evaluador v2) no
   se tocan: siguen desplegados tal cual.

## Hallazgos de arranque (sesión de planificación 2026-08-04)

El diagnóstico grande YA ESTÁ CERRADO con evidencia primaria (código, git, S3, Bedrock)
en el ciclo 4 — esta tabla lo fija como insumo; la Fase 0 sólo verifica su VIGENCIA al
día de ejecución, no lo re-deriva.

| # | Hallazgo | Evidencia |
|---|---|---|
| H1 | **Bug de caché (BLOQUEANTE, Fase 1):** `Rag::SectionNeighborExpander#page_index` cachea el índice página→{key, metadata} en `Rails.cache` con `INDEX_CACHE_TTL = 30.days` (`app/services/rag/section_neighbor_expander.rb:19`), clave `section_neighbor_index/v1/#{Digest::SHA256.hexdigest(prefix)}` (líneas 18, 142-144), SIN ningún gancho de invalidación en el repo. Ni el script de reparación de canonical_name del 2026-08-03, ni un resync de KB, ni `kamal deploy` la invalidan. El `canonical_name` correcto ("THYSSEN") ya está parcheado y verificado en S3 y en el índice vivo de Bedrock — sólo la caché de aplicación sirve "ALJO Control Level 1B Altius". `Bedrock::CitationProcessor#build_numbered_references` lee `metadata['canonical_name']` tal cual (línea 82); para citas vía expansión de vecindad ese metadata es `entry[:metadata]` congelado en la caché (`section_neighbor_expander.rb:53`). | código + "Corrección al caso 2" ciclo 4 (verificación directa S3/Bedrock post-gate) |
| H2 | **El script de reparación no invalida la caché:** `script/repair_seguridades_canonical_identity_and_acunaiento_2026-08-03.rb` corrigió `canonical_name`/`aliases` de 91 sidecars en S3 pero no contiene ninguna referencia a `Rails.cache` ni a `section_neighbor_index` (verificado por grep 2026-08-04). Cualquier reparación futura de metadata repetiría la trampa de 30 días. | grep sobre el script |
| H3 | **N8 vivo en el prompt — RESUELTO por la Fase 2 (2026-08-04):** `app/prompts/batch_chunking_prompt.rb` ya NO instruye emitir `**Document:**` en el cuerpo (regla de la línea 293 y las filas `ORIGINAL_FILE_NAME`/`NORMALIZED_FILE_NAME` de la tabla S0 eliminadas); comentario de cabecera corregido a imperativo. La contradicción activa desde `cc453f1` (2026-05-17) queda cerrada. **Esto NO resuelve H4** (96/97 cuerpos ya contaminados en S3/Bedrock, ver H4) — sólo previene que una ingesta futura reproduzca el defecto. | código + Anexo D ciclo 4 (atribución git: `844692f`, `cc453f1`, `25ebf66`) + Fase 2 de este ciclo |
| H4 | **N8 sigue vivo en los datos (BLOQUEANTE, Fase 3):** 96/97 cuerpos de chunk del prefijo SEGURIDADES llevan la línea `**Document:** ALJO Control Level 1B Altius \| Page N \| ORIGINAL_FILE_NAME: PIPELINE_INJECTED \| …` (único chunk limpio: `chunk_90`, página 92, divisor THYSSEN de 695 bytes). Forma regular y greppeable; el mapeo página→marca está verificado 100% contra Gate A §5.2. Fix determinístico sin LLM viable (Anexo D). Costo recurrente: ~42 tokens/línea × 10-12 chunks/pregunta ≈ 400-500 tokens de input extra por respuesta, para siempre, hasta corregirse. Ningún código de runtime depende de la línea (`citation_processor.rb:130-159` ya la filtra defensivamente). | Anexo D ciclo 4 + backup local `tmp/seguridades_chunks_2026-07-28/` |
| H5 | **Caso #1 del gate v4 = falso negativo del evaluador (NO bloqueante):** la respuesta real declara *"el orden exacto… no está documentado… **Verificar en campo**"* — exactamente lo que el `required` pide — pero el patrón exige *"requiere verificación (en) (el) campo"* (sustantivo) y *"esa secuencia/el orden"* literal. Fixture y evaluador NO se tocan (v4 gastado, medición ciega intacta); la lección va como regla de rúbrica obligatoria al autor del v5 (Fase 4). | Anexo F ciclo 4 §1 (verbatim de la respuesta) |
| H6 | **Límite de diseño aceptado, NO bloqueante en sí:** el filtro de página da 0 resultados en la página 92 (divisor casi vacío) y el expansor rellena con la vecina 93 — límite conocido y documentado desde la Fase 1 del ciclo 4. Lo bloqueante era el título mentiroso que esa expansión adjuntaba (H1), no la expansión misma. La batería de proveniencia (Fase 4) lo cubre como caso de prueba: expandir está bien; atribuir mal, no. | Anexo F ciclo 4 §2 + "Corrección al caso 2" |
| H7 | **Caso #3 del gate v4 = deuda P4 de identidad de variante (NO bloqueante):** el chunk etiqueta la placa "ARCA II", el fixture asumió "ARCA básica"; la cobertura multi-placa (N11) funcionó. Sin fase de fix — ver "Qué NO está en este plan". | Anexo F ciclo 4 §3 |
| H8 | **La caché del expansor también congela CUERPOS:** `cache_neighbor_body` (`section_neighbor_expander.rb:137-140`) re-escribe la entrada cacheada añadiendo `entry[:content]` (el cuerpo del vecino descargado de S3). Tras el parche de datos de la Fase 3, una caché no invalidada serviría cuerpos VIEJOS (con la línea N8) aunque S3 y Bedrock ya estén limpios — la re-invalidación post-resync de la Fase 3 no es opcional. | código |
| H10 | **La contaminación N8 NO es una línea única — falsifica la hipótesis de la Fase 3 (verificado 2026-08-04):** el regex `\*\*Document:\*\* ALJO Control Level 1B Altius \| Page \d+ \| ORIGINAL_FILE_NAME: PIPELINE_INJECTED.*` que el plan asumía "regular y greppeable" en 96/97 cuerpos sólo coincide EXACTO con **1 de 96** (`chunk_43`). El modelo de visión nunca siguió un template fijo al obedecer la instrucción retirada en la Fase 2 — produjo un bloque de identidad de 1-4 líneas en 11 formas distintas (`**Document:** ALJO...` + combinaciones de `**Section:**`/`**Page:**`/`ORIGINAL_FILE_NAME:`/`NORMALIZED_FILE_NAME:`/`SOURCE_URI:`), más 2 casos de contaminación FUERA de ese bloque: `chunk_0` (S0/ancla, p.2, ALJO real — 2 filas de tabla `\| ORIGINAL_FILE_NAME \| PIPELINE_INJECTED \|` en la sección `## S0 chunk content`) y `chunk_36` (línea suelta en prosa, p.38 EXCELSIOR, línea 75: *"Sistema general: ALJO Control Level 1B Altius"* — inmediatamente DESPUÉS de la marca correcta, la forma más dañina). Un diseño de detección de bloque + 2 casos especiales sí cubre los 96 cuerpos con **cero residuo verificado** (ni `ALJO Control Level 1B Altius` ni `PIPELINE_INJECTED` sobreviven, cero cambios colaterales línea por línea), pero remover hasta 4 líneas (incluye `**Page:**`/`**Section:**`, que sí llevan info real de página) excede el alcance de "sustituir una única línea" que la restricción 2 autorizó. Cero escrituras a S3/Bedrock en esta sesión. | `script/repair_seguridades_n8_body_2026-08-04.rb` (modo diagnóstico) + `tmp/ciclo5_fase3_2026-08-04/` (JSON completo por chunk, catálogo de 97 cuerpos, SHA256) |
| H9 | **El diseño per-file de `canonical_name` es VIGENTE, no herencia Lambda (verificado con git, 2026-08-04):** `chunk_merger_service.rb#canonical_name` (líneas 236-242) toma el nombre de la página ancla y `batch_results_parser_service.rb#document_identity` lo copia a los 97 sidecars — regla "ONE FILE = ONE IDENTITY", introducida en `cc453f1` (2026-05-17, el commit del "direct Claude parse path", MISMO commit que crea `chunk_merger_service`); `batch_results_parser_service` nace en `844692f` (2026-05-08, ya ruta Claude Batch). Se descartó con `git log` la hipótesis de que fuera herencia de la era Bedrock-nativo+Lambda (`OWRPGSX6XK`): esa era explica la línea del CUERPO (N8, Anexo D ciclo 4), no la metadata. Correcto para archivos mono-marca; incorrecto sólo para compendios multi-marca como SEGURIDADES (18 marcas en 1 PDF). El script de reparación del 2026-08-03 fue un one-off para este documento: **una ingesta futura de otro compendio multi-marca reproduciría el problema de metadata**. NO bloqueante para este ciclo (SEGURIDADES ya reparado en S3/Bedrock; sin saldo Anthropic no hay ingestas nuevas posibles) — deuda de diseño familia P4, ver "Qué NO está en este plan". **Corroboración de H1:** `chunk_91` estaba DENTRO de los 91 sidecars parcheados (verificado contra el respaldo que generó el propio script, que además aborta si el hash post-escritura no coincide) y aun así la corrida del 2026-08-04 citó "ALJO" — elimina la explicación alternativa "el script se saltó ese chunk": la única capa que puede servir el valor viejo es `Rails.cache`. | git log + código + respaldo del script de reparación |
| H11 | **La copia de referencia local tiene metadata OBSOLETA para `canonical_name` (verificado 2026-08-04, Fase 4, NO bloqueante):** `tmp/seguridades_chunks_2026-07-28/chunk_*.txt.metadata.json` lleva `ingestion_contract_version: "field_records_v5"` y `metadataAttributes.canonical_name` = `"ALJO Control Level 1B Altius"` IDÉNTICO en los 97 archivos (verificado por grep de `canonical_name` en los 97 JSON — cero variación). Esto es más viejo que el `field_records_v7`/`v8` que ya escriben `chunk_merger_service.rb`/`batch_results_parser_service.rb` en el código actual, y contradice DIRECTAMENTE la medición en vivo de la Fase 1 de este mismo ciclo (2 llamadas reales a `retrieve`: la cita de la página 93 trae `canonical_name: "THYSSEN"`, no ALJO). La copia local sigue siendo válida como fuente de CONTENIDO SUSTANTIVO (Fase 0 verificó bytes idénticos de cuerpo para una muestra de 5, y esta fase verificó 1:1 contra el cuerpo real los 14 hechos técnicos del holdout v5) — **NO es válida como fuente de verdad para metadata de citación** (`canonical_name`/`section_identity` por página). La verdad-terreno correcta para `expected_section_identity` de la batería de proveniencia es `docs/rag/gate_a_medicion_topologia.md` §5.2 (Apéndice E), no la copia local — así se construyó el fixture de esta fase. Prompt de la Fase 6 ya actualizado con esta nota. | grep directo sobre los 97 `*.metadata.json` + Anexo G (Fase 1, este ciclo) |
| H10 | **El diseño original de T1+T2 era complementario, NO de reemplazo (verificado 2026-08-04):** `docs/rag/plan_conocimiento_visual.md` tabla "Arquitectura objetivo" contempló explícitamente que T1 (geométrico, determinístico, $0) y T2 (visión, Opus 4.8) trabajaran juntos con procedencia distinguible (`method: :leader_line` vs `method: :vision` en cada arista `TOPOLOGY_EDGE`), no que uno reemplazara al otro. Diseño: "T1 ancla, T2 reconoce; T1 gana en conflicto" — ambos se concatenan en el mismo `page_result[:topology_edges]` y T2 aporta además `components: [{ label, canonical_component, evidence }]` para identidad de componente (metadata enriquecida). La "degradación permanente" de T2 en el Gate B (88.49%, LI 84.14% < umbral 85%; tipos A y B empeoraron; relaciones apagadas) fue **decisión técnica forzada por performance insuficiente**, pero esa medición se corrió sobre chunks contaminados con N8 (~400-500 tokens de ruido de input por respuesta con 10-12 chunks recuperados). Hipótesis no medida: la línea `**Document:** ALJO Control Level 1B Altius...` en 96/97 páginas pudo haber confundido la interpretación visual del contexto en T2, especialmente en páginas multi-marca donde contradecía el contenido visual real. El approach complementario T1+T2 sigue siendo el diseño correcto para metadata enriquecida — queda pendiente verificar si N8 fue factor en el fracaso de T2 (ver entrada en "Qué NO está en este plan"). | plan de conocimiento visual + estado del Gate B + timing de commits N8 vs T1/T2 (todos mayo-agosto 2026) |

## Asignación de modelo por fase

| Fase | Modelo | Racional (tabla de la metodología) |
|---|---|---|
| 0 Verificación de vigencia | Sonnet 5 | lectura de código/S3/Bedrock contra producción — Haiku prohibido fuera de trabajo no-productivo |
| 1 Fix bug de caché | Sonnet 5; consulta acotada a Opus 5 SÓLO si el costo/beneficio de la opción estructural queda genuinamente ambiguo | código + tests + verificación en vivo |
| 2 Fix prompt N8 | Sonnet 5 | código puro, $0 |
| 3 Parche de datos N8 + resync | Sonnet 5 | script contra S3/Bedrock de producción — NO Haiku |
| 4 Holdout v5 + batería | Sonnet 5 — sesión NUEVA que no tocó Fases 1-3 | principio 6 de la metodología |
| 5 Checkpoint despliegue | **Sonnet 5 — NO Haiku** | el modelo más riguroso contra producción (lección ciclo 3: registro erróneo + corrida duplicada) |
| 6 Gate v5 | **Sonnet 5 — NO Haiku** | ídem; además clasifica fallos si no pasa |

Nunca Fable en ninguna fase. El juez sigue siendo `Rag::BenchmarkRubricEvaluator` (regex
determinístico, $0) para el holdout; la batería de proveniencia usa checks determinísticos
puros (comparación `canonical_name` vs `section_identity`, ausencia de la línea N8) — $0
de juez también. `BEDROCK_MODEL_ID` de producción no se toca.

## Fase 0 — Verificación de vigencia del diagnóstico (Sonnet 5; $0 Bedrock)

Fase 0 liviana a propósito: el diagnóstico profundo ya lo hizo el ciclo 4 con evidencia
primaria. Esta fase verifica que los 4 hallazgos accionables (H1, H3, H4 + el supuesto de
que nada se movió en el KB) siguen vigentes contra el estado ACTUAL de código/S3/Bedrock
antes de tocar nada — por si algo cambió desde el 2026-08-04. **No se arregla nada en
esta fase.** Lectura pura: no toca la caché, no toca código, no llama a `retrieve` (las
lecturas de S3 y `bedrock-agent` son de control-plane, fuera del presupuesto de
`retrieve_invocations`).

Salida: tabla hallazgo × vigente sí/no × evidencia, en un anexo de este documento.
Verifica:

- **(a) H1:** `app/services/rag/section_neighbor_expander.rb` sigue con
  `INDEX_CACHE_TTL = 30.days` (línea 19), clave
  `section_neighbor_index/v1/<sha256(prefix)>` (líneas 18, 142-144) y cero ganchos de
  invalidación en el repo (`grep -rn section_neighbor_index` fuera de la propia clase y
  sus tests).
- **(b) estado del KB:** el sidecar de la página 93 (`chunk_91.txt.metadata.json`) en S3
  sigue con `canonical_name: "THYSSEN"`; el ingestion job más reciente del data source
  sigue siendo `ZGCU99ISK5` (`COMPLETE`). Si hay un job posterior: anotarlo — cambia el
  supuesto de la Fase 3 y hay que revisar si tocó el prefijo SEGURIDADES.
- **(c) H3:** `batch_chunking_prompt.rb` sigue instruyendo la línea `**Document:**` en el
  cuerpo (líneas ~293-315) y el comentario de cabecera sigue contradiciéndolo.
- **(d) H4:** muestreo de ≥5 chunks no-ALJO del prefijo vivo en S3: la línea
  `**Document:** ALJO Control Level 1B Altius | Page N | …PIPELINE_INJECTED…` sigue
  presente, y coincide con el backup local `tmp/seguridades_chunks_2026-07-28/`
  (`chunk_90` sigue siendo el único limpio).

Si los 4 siguen vigentes: anotar "Fases 1-3 proceden sin cambios" y cerrar. Si alguno
cambió: corregir la(s) fase(s) afectada(s) y su(s) prompt(s) en el Anexo A ANTES de
cerrar (protocolo de plan vivo).

## Fase 1 — Fix del bug de caché del expansor (Sonnet 5; ≤4 llamadas Bedrock) — **CERRADA 2026-08-04**

**Resultado: hipótesis CONFIRMADA, fase cerrada sin escalar. Ver Anexo G para
la evidencia completa (hashes, comandos, respuesta citada).** Resumen: la
entrada cacheada leída antes del borrado traía `canonical_name: "ALJO
Control Level 1B Altius"` en páginas 92/93 con `section_identity: "THYSSEN"`
ya correcto; tras la invalidación dirigida + el fix estructural
(`Rag::SectionNeighborExpander.invalidate!`, opción i, más TTL 7 días como
opción ii) y el despliegue (`c05718a`), dos preguntas nuevas sobre la
página 92 THYSSEN citan "THYSSEN — p. 93" con `canonical_name: "THYSSEN"`.

**Fase 0 (2026-08-04) confirmó sin cambios la premisa de esta fase** (Anexo
F): código de `section_neighbor_expander.rb` intacto (línea 19, 142-144),
cero ganchos de invalidación en el repo; `chunk_91` (página 93) sigue con
sidecar `canonical_name: THYSSEN` pero CUERPO vivo en S3 con la línea
`**Document:** ALJO Control Level 1B Altius…` — la discrepancia
cuerpo-vs-metadata sigue intacta y es la evidencia directa de que sólo la
caché de aplicación puede estar sirviendo el `canonical_name` viejo en la
cita. Procede sin cambios de implementación.

**Hipótesis:** la entrada `section_neighbor_index/v1/<sha256(prefix)>` del prefijo de
SEGURIDADES quedó construida ANTES del parche de canonical_name del 2026-08-03 (la Fase 1
del ciclo 4 ya ejercitó la expansión de vecindad ese mismo día, antes del parche), y por
eso `SectionNeighborExpander` adjunta `canonical_name: "ALJO Control Level 1B Altius"` a
citas de contenido THYSSEN. Si se borra esa entrada, la próxima expansión reconstruye el
índice desde los sidecars ya parcheados de S3 y la cita sale "THYSSEN". **Resultado si es
falsa:** la cita seguiría diciendo "ALJO" tras el borrado — en ese caso PARAR y escalar
(habría otra capa desactualizada no diagnosticada, y este plan no la conoce).

Refuerzo de la hipótesis (H9, 2026-08-04): `chunk_91` estaba dentro de los 91 sidecars
que el script de reparación parcheó con verificación estricta post-escritura (aborta si
el hash no coincide) — la explicación alternativa "el script se saltó ese chunk" queda
eliminada; entre S3 (correcto desde el 2026-08-03), el índice de Bedrock (verificado
correcto post-gate) y la cita del 2026-08-04 (incorrecta), la única capa que puede servir
el valor viejo es la caché de aplicación.

Dos entregas, un objetivo:

1. **Invalidación dirigida inmediata (destraba el bloqueante YA):** `bin/rails runner`
   vía `kamal app exec --reuse -r web` que compute la clave con el prefijo real de
   SEGURIDADES y ejecute `Rails.cache.delete`. ANTES de borrar: leer y guardar el valor
   cacheado viejo como artefacto (evidencia del estado contaminado — el
   `canonical_name` "ALJO…" congelado) a tmp local + SHA256.
2. **Fix estructural (que ningún parche futuro de metadata quede atrapado 30 días).**
   Opciones a evaluar en la fase, con costo/beneficio explícito — la decisión es de la
   fase, con la recomendación pre-cargada de este plan:
   - **(i) Método público `Rag::SectionNeighborExpander.invalidate!(prefix)`** (borra la
     clave derivada del prefijo), invocado por el script de reparación de metadata (H2) y
     por cualquier flujo de resync de KB. **Recomendada:** determinística, $0 por
     request, deja la invalidación al lado de la escritura que la exige.
   - **(ii) Bajar `INDEX_CACHE_TTL`** (p.ej. a 7 días o menos): defensa secundaria
     aceptable EN ADICIÓN a (i), insuficiente sola — deja una ventana con el mismo bug,
     sólo más corta.
   - **(iii) Versionar la clave con un hash del contenido fuente:** pre-analizada CARA —
     exigiría listar/leer los sidecars de S3 en cada request para computar el
     fingerprint, anulando el propósito de la caché. Descartarla salvo que la fase
     encuentre un fingerprint gratis (p.ej. un ETag agregado ya disponible sin listado).
   
   Implementar la elegida + tests Minitest: `invalidate!` borra exactamente la clave del
   prefijo; el script de reparación la invoca; TTL nuevo si aplica. Sin tocar la
   semántica de `page_index`/`authorize` (los fixes del ciclo 4 no se tocan —
   restricción 9).

**Addendum (mismo día, mismo objetivo — endurecimiento pedido por el dueño):**
el dueño pidió que la invocación de `invalidate!` no dependa de que un script
de reparación "se acuerde" de llamarla. Mecanismo final implementado:
`S3DocumentsService#upload_text`/`#upload_binary` llaman a
`Rag::SectionNeighborExpander.invalidate!` automáticamente para CUALQUIER key
bajo `bulk_chunks/` (deriva el prefijo con `key.rpartition("/").first`),
scoped a ese prefix para no afectar otros callers de `#upload_binary`
(`field_photos/`, `document_manifests/`). El script de reparación de
canonical_name (H2) ya escribe todo por `s3.upload_text`/`s3.upload_binary`
— no necesita ninguna llamada explícita; su comentario final documenta por
qué. Regla codificada como mandatoria en `app/services/rag/AGENTS.md`
("Chunk Repair Cache Invalidation") y en `docs/ACTIVE_ARCHITECTURE.md`: todo
script que en el futuro escriba a `bulk_chunks/` sin pasar por
`S3DocumentsService` (SDK crudo) DEBE llamar `invalidate!(prefix)` él mismo,
con comentario. Tests: `S3DocumentsServiceTest` cubre invalidación en
`upload_text`/`upload_binary` bajo `bulk_chunks/`, no-invalidación fuera de
ese prefijo, y no-invalidación si el `put_object` falla.

**Verificación en vivo** (tras `kamal deploy` de esta fase, commitear ANTES de desplegar
— lección ciclo 4 Fase 2): 1-2 preguntas ad-hoc NUEVAS que fuercen expansión de vecindad
sobre la página 92 de THYSSEN, con hechos distintos a v3/v4 (no se reutiliza ningún
holdout). Éxito = la cita renderiza "THYSSEN". ≤4 llamadas; artefacto completo a tmp
local + SHA256.

**Al cerrar:** reescribir el prompt de la Fase 3 en el Anexo A con el mecanismo REAL de
invalidación implementado (la Fase 3 debe ejecutarlo tras su resync — H8).

## Fase 2 — Fix del prompt de ingesta N8 (Sonnet 5; $0 Bedrock)

**Decisión explícita de secuencia:** esta fase va ANTES del parche de datos vivos (Fase
3) y no espera a nada — es código puro, sin riesgo de datos, y previene que N8 se
reproduzca en cualquier ingesta nueva mientras tanto. No altera datos vivos ni
embeddings: no invalida ninguna medición previa ni condiciona a la Fase 3.

- En `app/prompts/batch_chunking_prompt.rb`: eliminar la instrucción de emitir la línea
  `**Document:** {hint} | Page N | ORIGINAL_FILE_NAME: PIPELINE_INJECTED | …` dentro del
  CUERPO de cada chunk (líneas ~293-315, incluida la regla "Each section title must
  appear inside the chunk after the `**Document:**` header" de la línea 293) y corregir
  el comentario de cabecera (líneas 13-16) para que deje de contradecir al código.
- **NO tocar:** el campo JSON `document_name` ni el `document_name_hint` de la página
  ancla (regla "ONE FILE = ONE IDENTITY" — correcto, se queda);
  `SingleFileChunkingService`; `BatchResultsParserService#identity_header` (la identidad
  sigue siendo 100% Rails-injected).
- Ajustar los tests del prompt que esperen la línea vieja; correr la suite completa.
- Cero llamadas a cualquier API.

**Lo que esta fase NO hace (y no es un olvido):** no limpia los 96 cuerpos ya
contaminados que hoy están vivos en S3/Bedrock. Este fix es sólo profiláctico — evita que
el defecto se reproduzca en ingestas futuras. La contaminación existente, que es la que
el técnico ve HOY en producción y la que paga ~400-500 tokens de input por respuesta, se
elimina en la **Fase 3**, que es obligatoria y bloqueante para piloto. Cerrar la Fase 2
NO resuelve N8 en producción: el hallazgo H4 sigue vigente hasta que la Fase 3 cierre.

## Fase 3 — Parche de datos N8: 96 cuerpos + resync + re-invalidación (Sonnet 5; ≤4 llamadas Bedrock de humo) — **✅ CERRADA 2026-08-04, Decisión humana #10 resuelta y ejecutada**

**Resultado final: H4 CERRADO.** El dueño resolvió la Decisión humana #10 autorizando
explícitamente "eliminar toda contaminación de N8" — **Alcance A (bloque completo)**,
la opción recomendada por este plan. Ejecución real en la misma sesión que cerró el
diagnóstico:

- **96/97 cuerpos parcheados** (Alcance A: bloque `**Document:**` + continuaciones
  contiguas + los 2 casos especiales `chunk_0`/`chunk_36`); `chunk_90` intacto (el
  único ya limpio, sin tocar).
- **Backup completo de los 97 cuerpos vivos** ANTES de escribir, a S3
  (`s3://multimodal-source-destination/chunk_body_backups/1/b61f5d54-ff42-414a-97b7-01682d16f4b5/20260804T144351Z_ciclo5_fase3`)
  y a tmp local (`tmp/ciclo5_fase3_2026-08-04/prod_backup_20260804T144351Z/`), más el
  versioning nativo de S3 (confirmado habilitado en PROD por el dueño — respaldo
  adicional).
- **Fix de robustez sobre el diseño original:** el primer intento de modo real
  pre-verificaba ETag de los 97 objetos contra la copia de referencia local
  `tmp/seguridades_chunks_2026-07-28/` (2026-07-28) y abortó en `chunk_23.txt` —
  drift real entre esa copia y el objeto vivo (la Fase 0 de este ciclo sólo muestreó 5
  chunks distintos, no ése). Corregido: el modo real ya NO depende del contenido de la
  referencia local para decidir qué escribir — descarga cada cuerpo EN VIVO desde S3 y
  corre la misma detección de bloque sobre ese byte fresco; la referencia local sólo
  sirve al modo diagnóstico (sin red) y como snapshot de los 97 nombres de archivo
  esperados. Ver Anexo I para el detalle.
- **Post-escritura verificado:** 96/96 SHA256 coinciden con el resultado esperado.
- **Resync del KB disparado y completado:** `BulkKbSyncService#sync!` →
  `job_id: "CCCDNEDFYL"`, `status: "COMPLETE"` — **reemplaza a `ZGCU99ISK5`** como
  referencia vigente en los prompts de las Fases 5 y 6 (actualizado en el Anexo A).
- **Invalidación de caché:** automática, disparada por cada `S3DocumentsService#upload_text`
  (mecanismo de la Fase 1) — no hizo falta ningún paso explícito adicional.
- **Humo post-resync (2/4 llamadas del presupuesto de la fase):** 2 preguntas ad-hoc
  NUEVAS contra `BedrockRagService#query` (la ruta de producción real) sobre páginas
  NO-ALJO recién parcheadas — página 38 (EXCELSIOR, `chunk_36`) y página 45
  (FAIN/EKM66, `chunk_43`). Ambas citan el fabricante correcto
  (`canonical_name: "EXCELSIOR"` / `"FAIN"`, no ALJO), CERO apariciones de
  `ALJO Control Level 1B Altius`/`PIPELINE_INJECTED` en el `content` citado por Bedrock
  (prueba directa de que el KB ya sirve el índice reindexado, no sólo que el job dijo
  `COMPLETE`) ni en la respuesta generada, y ambas respuestas son técnicamente sanas
  (identifican correctamente conectores/bloques de bornes, citan la página, señalan
  honestamente dónde el diagrama no es legible con precisión). Ver Anexo I.

**Causa raíz:** ya identificada y removida por la Fase 2 (commit `3873294`,
`app/prompts/batch_chunking_prompt.rb`) — re-verificado en esta sesión que no queda
ninguna instrucción residual que reproduzca N8 en una ingesta futura. Este parche sólo
limpió el dato ya escrito con el prompt viejo.

**Hipótesis original (falsificada, se deja registrada para trazabilidad):**
sustituir la línea contaminante en los 96 cuerpos (dejando el resto del
chunk byte a byte idéntico), re-subir a S3 y resincronizar el KB elimina la contaminación
de identidad que lee el modelo de generación y el impuesto de ~400-500 tokens de input
por respuesta, sin ninguna llamada a Anthropic. **Resultado si es falsa:** chunks
recuperados post-resync seguirían mostrando la línea, o el diff por chunk no sería
exactamente la línea esperada (el script aborta — ver diseño). **Ocurrió lo segundo:**
el script (modo diagnóstico) confirma que 95/96 cuerpos no producen un diff de una
única línea — por diseño, no escribe nada.

Diseño (calcado del patrón de seguridad de
`script/repair_seguridades_canonical_identity_and_acunaiento_2026-08-03.rb`):

- Script `script/repair_seguridades_n8_body_2026-08-04.rb`, dry-run POR DEFECTO, que:
  greppea la línea con el patrón regular
  `\*\*Document:\*\* ALJO Control Level 1B Altius \| Page \d+ \| ORIGINAL_FILE_NAME: PIPELINE_INJECTED.*`;
  ABORTA si el diff de un chunk no es exactamente esa única línea; NO toca `chunk_90`
  (p.92, el único limpio) ni ningún sidecar `.metadata.json` (ya corregidos el
  2026-08-03); reemplaza cada `.txt` EN SU CLAVE ORIGINAL (restricción 8: nada nuevo bajo
  `bulk_chunks/`; el manifest de claves tocadas va a tmp local).
- ANTES de subir nada: backup completo de los 97 cuerpos vivos a tmp local + SHA256 por
  archivo + SHA256 del tarball.
- Ejecutar en real, subir, y disparar el resync del KB (`start-ingestion-job`); esperar
  `COMPLETE`; **anotar el ingestion job id nuevo** — reemplaza a `ZGCU99ISK5` como
  referencia vigente: actualizar los prompts de las Fases 5 y 6 en el Anexo A.
- **Invalidación de caché: automática, sin paso explícito** — mecanismo REAL
  implementado por la Fase 1 (2026-08-04, endurecido el mismo día): si el patch de los
  96 cuerpos escribe por `S3DocumentsService#upload_text`/`#upload_binary` (el mismo
  patrón que `script/repair_seguridades_canonical_identity_and_acunaiento_2026-08-03.rb`),
  cada escritura bajo `bulk_chunks/` ya invoca
  `Rag::SectionNeighborExpander.invalidate!` por sí sola — no hace falta ninguna llamada
  adicional al final del script. **Verificar, no asumir:** el script de la Fase 3 NO debe
  escribir por `Aws::S3::Client` crudo para los 96 `.txt` — si por alguna razón lo hiciera,
  DEBE llamar `Rag::SectionNeighborExpander.invalidate!(CHUNK_PREFIX)` explícitamente
  (regla mandatoria, `app/services/rag/AGENTS.md` §"Chunk Repair Cache Invalidation").
  `CHUNK_PREFIX = "bulk_chunks/1/b61f5d54-ff42-414a-97b7-01682d16f4b5"`. H8: la caché
  también congela CUERPOS de vecinos (`cache_neighbor_body`) — sin invalidación (automática
  o explícita), la expansión de vecindad seguiría sirviendo texto con la línea N8 aunque S3
  y Bedrock ya estén limpios. Confirmar en el humo de la Fase 3 que una expansión de
  vecindad post-resync ya no trae la línea N8 (evidencia directa de que la caché se
  refrescó, más allá de confiar en el mecanismo).
- Humo: 1-2 preguntas ad-hoc NUEVAS (≤4 llamadas) verificando que (a) los chunks
  recuperados ya NO contienen la línea en páginas no-ALJO, (b) la respuesta sigue sana
  (el parche no rompió nada). Artefacto + SHA256.

Nota de secuencia: este parche cambia los embeddings de 96 chunks — por eso va ANTES de
redactar el holdout v5 (Fase 4) y del gate (Fase 6), y por eso nada medido en v1-v4 se
reabre (esos holdouts ya están gastados; la comparación válida es contra el criterio del
gate v5, no contra rankings viejos).

## Fase 4 — Holdout v5 + batería de proveniencia (Sonnet 5, sesión NUEVA que no tocó las Fases 1-3; $0 Bedrock)

**Protocolo de validación — propuesta con trade-off explícito (decisión del dueño #3):**

| Opción | Contenido | Costo estimado | Rigor |
|---|---|---|---|
| A (propuesta original del dueño) | 5 corridas completas × 14 preguntas nuevas cada una (70 preguntas) | ~100 `retrieve_invocations` (patrón v4: ~20/corrida) + 5× el costo de redacción y QA de rúbrica | Mide varianza inter-corrida, pero repite 5 veces el MISMO tipo de instrumento; ninguna corrida apunta específicamente a los 2 fixes bloqueantes |
| **B (recomendada por este plan)** | Checkpoint + 1 holdout v5 de 14 preguntas nuevas + batería de proveniencia de 15-20 preguntas dirigida a los 2 bloqueantes | ~38-45 `retrieve_invocations` en total + 1× redacción/QA | Dirige el poder de la medición a donde estuvo el fallo: proveniencia de cita bajo expansión de vecindad y ausencia de N8, con checks determinísticos ($0 de juez) que no dependen de regex de rúbrica (la causa del falso negativo del v4) |

La fila "Protocolo de validación" de la tabla de Estado registra la propuesta B como
recomendada y queda pendiente del veto del dueño ANTES de ejecutar esta fase. Si el dueño
elige A, el presupuesto del ciclo se re-declara (el techo de 56 no alcanza) y esta fase
se re-planifica — no se ejecuta A "por las dudas".

Contenido de la fase (bajo propuesta B) — redactar y congelar DOS fixtures sin correrlos:

1. **`script/fixtures/rag_seguridades_holdout_v5.json`** — 14 preguntas nuevas, misma
   distribución del v4 (3 determinísticas / 2 mapeos estructurados / 2 generalización /
   1 ambigua / 1 sin respaldo / 4 seguridad / 1 comparativa), redactadas desde la
   verdad-terreno pagada (Gate A §5-§9 + los 97 cuerpos POST-parche), sin reutilizar
   ninguna pregunta de v1-v4 (verificación por script, intersección vacía). Reglas
   heredadas del v4 completas: `severity: safety_critical` a nivel de caso + `penalized`
   con `severity: critical`; `source_page_required` consciente por caso (menú de
   desambiguación → `false`); verificación offline
   `Rag::DeterministicIntent.ambiguous_hardware_query? == false` en los 14; QA test
   clonado del v4 (tally, suma real con la fórmula del evaluador,
   `passing_score = ceil(80%)`, cobertura de ids, respuesta correcta conocida contra el
   evaluador real, ningún `penalized` dispara sobre respuesta correcta).
2. **`script/fixtures/rag_seguridades_provenance_battery_v1.json`** — 15-20 preguntas
   dirigidas específicamente a los 2 hallazgos bloqueantes: (a) casos que fuercen
   expansión de vecindad en páginas divisoras (la cita DEBE atribuir el contenido al
   fabricante correcto de la página servida — check determinístico: `canonical_name` de
   cada cita == `section_identity` del sidecar de la página citada); (b) casos cuyo check
   es la AUSENCIA de la línea N8 en los cuerpos recuperados (`**Document:** ALJO…` no
   aparece en ningún chunk de página no-ALJO). Los checks son determinísticos, no de
   rúbrica regex — inmunes por construcción a la familia de fallo del caso #1 del v4.

⚠️ **Regla de rúbrica obligatoria (lección H5, corrección de arnés):** todo `required` de
abstención en el v5 debe aceptar paráfrasis — forma sustantiva E imperativa ("requiere
verificación" Y "verificar en campo"), y sin objeto literal único ("esa secuencia" debe
alternar con "la secuencia( textual)?", "el orden"). Probar cada patrón contra ≥2 fraseos
correctos distintos en el QA test. Prohibiciones heredadas intactas: ventanas `.{0,N}`
que crucen ítems de lista; lookaheads sin el "no" pospuesto; corregir erratas del
documento en los `required`.

Nota post-parche: N8 ya estará corregido cuando esto corra — la regla vieja del v3/v4
("no exigir marca correcta fuera de ALJO págs. 2-7 y divisoras limpias") queda DEROGADA;
confirmar contra la fila de Estado de la Fase 3 antes de redactar. **No se corre nada
contra Bedrock en esta fase**: ambos fixtures se abren UNA sola vez, en la Fase 6.

## Fase 5 — Checkpoint de despliegue (Sonnet 5 — NO Haiku)

**Momento exacto:** después de que las Fases 1-3 estén commiteadas con suite verde y el
resync de la Fase 3 `COMPLETE`, y ANTES de abrir el holdout v5. Regla permanente: nunca
se abre un holdout con cambios sin desplegar.

1. `kamal deploy`; verificar SHA desplegado == HEAD con `kamal app version`.
2. Confirmar que el ingestion job vigente es el que anotó la Fase 3 (ya no `ZGCU99ISK5`)
   y sigue `COMPLETE`.
3. Humo: **1 llamada, `-r web` SIEMPRE** (sin `--role` corre en web+worker y duplica el
   gasto). Pregunta nueva fuera de todo holdout que fuerce expansión de vecindad — la
   cita debe traer el fabricante correcto Y el cuerpo recuperado sin línea N8 (ejercita
   los DOS fixes en una sola llamada).
4. Aurora caliente: `kb_retrieve` < 1s, sin cold-start en el log.
5. Anotar en Estado: SHA, timestamp, evidencia del humo (tmp local + SHA256).

## Fase 6 — Gate v5, UNA corrida (Sonnet 5 — NO Haiku)

**Criterio congelado ANTES de abrir (AND estricto de las 4 condiciones, sin ajustes
post-hoc):**

1. Holdout v5: ≥80% de la suma real de la rúbrica (el `passing_score` que congeló la
   Fase 4).
2. Cero `passed: false` en los 4 casos `safety_critical` del v5.
3. `source_page_cited` verde en esos 4 casos.
4. Batería de proveniencia: CERO citas cuyo título/`canonical_name` contradiga la
   `section_identity` de la página citada Y CERO apariciones de la línea N8 en los
   cuerpos recuperados.

Ejecución:

1. Verificar ANTES que la Fase 5 anotó SHA y humo verde, y que `git rev-parse HEAD`
   coincide con el SHA desplegado (si hay commits nuevos que toquen
   `app/`/`config/`/`script/`: repetir la Fase 5 primero; commits sólo-documento no
   obligan a re-desplegar — precedente del gate v4).
2. Correr holdout v5 y batería UNA sola vez cada uno, patrón Kamal del ciclo 4
   (`bundle exec kamal app exec --reuse -r web -p "sh -c '…'"`), presupuesto ~38-45
   `retrieve_invocations` entre ambos.
3. Artefactos completos (cada caso con `chunks` y `answer` no vacíos) copiados del
   contenedor a tmp LOCAL + SHA256 EN ESTA MISMA SESIÓN (restricción 6). Las corridas NO
   se repiten.
4. **Pasa** → liberar a piloto con el guardrail de presentación del ciclo 4 activo.
   **No pasa** → clasificar cada fallo (defecto real vs. arnés de medición, con la página
   y la proveniencia que el evaluador v2 y los checks determinísticos ya exponen), v5 y
   batería quedan gastados, y PARAR: escalar como decisión humana #10.

## Presupuesto del ciclo 5

| Concepto | Estimado |
|---|---|
| Fase 0: 0 (control-plane; sin `retrieve`) | 0 |
| Fase 1: ≤4 (verificación en vivo del fix de caché) | ≤4 |
| Fase 2: 0 | 0 |
| Fase 3: ≤4 (humo post-resync) — el re-embedding de 96 chunks (Titan) se factura como ingesta, aparte | ≤4 |
| Fase 4: 0 | 0 |
| Fase 5: 1 (humo del checkpoint) | 1 |
| Fase 6: holdout v5 ~20 + batería ~18-25 | ~38-45 |
| **Techo del ciclo** | **56** |
| API de Anthropic desde la app | **$0** (ninguna llamada; el parche N8 es sustitución de texto determinística) |
| Sesiones de IA | 7 sesiones Sonnet 5 cortas (una por fase); Opus 5 sólo consulta acotada en Fase 1 si aplica; nunca Fable; Haiku excluido de toda fase contra producción |

## Estado

| Fase | Estado | Artefacto / hash |
|---|---|---|
| Protocolo de validación (decisión del dueño #3) | **RESUELTA 2026-08-04 — Propuesta B confirmada/no vetada por el dueño.** Ejecutada en la Fase 4 (fila abajo): holdout v5 + batería de proveniencia, checks determinísticos dirigidos a los 2 bloqueantes. | — |
| 0 Verificación de vigencia | **hecho 2026-08-04** — los 4 hallazgos (a/H1, b/estado-KB, c/H3, d/H4) VIGENTES sin cambios. Fases 1-3 proceden sin cambios; ningún hallazgo contradice restricción/gate, no se escala decisión #10. Ver tabla completa en el Anexo F. Artefacto `tmp/ciclo5_fase0_verificacion_vigencia_2026-08-04.md`, SHA256 `12541d960cdd5234be301ae003bc03314c655697c573397c05202411bc0c46fb`. | Anexo F |
| 1 Fix bug de caché (invalidación dirigida + estructural) | **hecho 2026-08-04** — Hipótesis CONFIRMADA (Anexo G): el valor leído de `section_neighbor_index/v1/243000f4…086` ANTES de borrar traía `canonical_name: "ALJO Control Level 1B Altius"` en páginas 92 y 93 pese a `section_identity: "THYSSEN"` ya correcto — exactamente el estado predicho. Entrega 1 (invalidación dirigida): `Rails.cache.read` + `Rails.cache.delete` vía `kamal app exec --reuse -r web bin/rails runner` sobre el prefijo real `bulk_chunks/1/b61f5d54-ff42-414a-97b7-01682d16f4b5`; valor viejo completo guardado ANTES de borrar. Entrega 2 (estructural): opción **(i) implementada** — `Rag::SectionNeighborExpander.invalidate!(prefix)` (método de clase; `index_cache_key` de instancia delega en el de clase, una sola fuente de verdad para la derivación); opción **(ii) aplicada en adición** — `INDEX_CACHE_TTL` 30d→7d; opción (iii) descartada (sin fingerprint gratis, tal como preanalizó el plan). El script de reparación de canonical_name (H2) invoca `invalidate!(CHUNK_PREFIX)` tras su resync — patrón de referencia para Fase 3. 5 tests Minitest nuevos + suite completa verde (2265 runs, 8068 assertions, 0 failures/errors, sin regresión sobre los 2260 previos). Commit `c05718a` ANTES de `kamal deploy`; `kamal app version` confirmó SHA desplegado `c05718a2` == HEAD. Verificación en vivo: 2 preguntas ad-hoc NUEVAS sobre la página 92 THYSSEN (LED L8 → SERIE PUERTAS EXTERIORES; borne 72 → AFLOJACABLES; hechos distintos de v3/v4) — **ambas citan "THYSSEN — p. 93" con `canonical_name: "THYSSEN"`**, no ALJO. 2 `retrieve_invocations` usados de ≤4 presupuestados. Ningún hallazgo contradice una restricción ni el gate: no se escala decisión #10. | `tmp/ciclo5_fase1_2026-08-04/cache_invalidation_seguridades_2026-08-04.json` SHA256 `b500fd9be75d276040dbec057a91b672e0d845bfd5eb8e17cbee5264b9056ded`; `tmp/ciclo5_fase1_2026-08-04/live_probe_1_thyssen_p92_led_l8_2026-08-04.json` SHA256 `a8264113e6b2fabc30bcd9c3238e0a3d63180ff04c6c3a465c1e841168221cf7`; `tmp/ciclo5_fase1_2026-08-04/live_probe_2_thyssen_p92_borne72_2026-08-04.json` SHA256 `1086d46103af51d48eb4ab40ab4c7f948bd608b072697c096497fbf2168af35a`; commit `c05718a26317361069315c4900e2cdf2e24d98cf`; ver Anexo G |
| 2 Fix prompt N8 | **hecho (código) 2026-08-04 — N8 SIGUE VIGENTE EN PRODUCCIÓN, NO confundir con "N8 resuelto".** En `app/prompts/batch_chunking_prompt.rb`: eliminada la regla "Each section title must appear inside the chunk after the `**Document:**` header" (línea 293 original) y las filas `ORIGINAL_FILE_NAME \| PIPELINE_INJECTED` / `NORMALIZED_FILE_NAME \| PIPELINE_INJECTED` de la tabla `## S0 chunk content` (líneas 309-310 originales) — son los dos campos que el modelo textualizaba junto al hint del `document_name` para producir la línea contaminante. Comentario de cabecera (líneas 13-16) corregido de descriptivo-y-falso ("does NOT need to embed") a imperativo-y-verificable ("MUST NOT instruct the model to embed"), apuntando a la sección que lo cumple. NO se tocó: `document_name`/`document_name_hint` (ONE FILE = ONE IDENTITY intacto), `# IDENTITY INJECTION` (regla defensiva de PIPELINE_INJECTED, ahora inerte pero no dañina — no toca ninguna instrucción activa), `SingleFileChunkingService`, `BatchResultsParserService#identity_header`, `citation_processor.rb` (su filtro defensivo sigue siendo necesario hasta que la Fase 3 cierre). Ningún test preexistente asertaba la línea vieja (verificado por grep dirigido antes de correr la suite) — no hizo falta ajustar tests. Cero llamadas a cualquier API; cero cambios en S3/Bedrock/datos vivos. Suite completa: **2269 runs, 8076 assertions, 0 failures, 0 errors, 189 skips** (2265→2269 runs y 8068→8076 assertions frente al baseline de cierre de la Fase 1 — diferencia atribuible a la carga habitual de la suite completa, no a tests nuevos de esta fase; ningún test se agregó ni se modificó). `prompt_fingerprint_sha256` nuevo: `e5b574784ff78547886919fe388edd51decbc13b0a37cfbd11bc041ff4ac1172`. **Efecto real: sólo previene que una ingesta NUEVA reproduzca N8. Los 96/97 cuerpos ya contaminados en S3/Bedrock no cambiaron una sola línea — el técnico sigue viendo `**Document:** ALJO Control Level 1B Altius \| Page N \| …` en producción HOY. H4 sigue vigente hasta que la Fase 3 (obligatoria, bloqueante para piloto) cierre.** Ningún hallazgo contradice una restricción ni el gate: no se escala decisión #10. Fase 3 no necesita ajuste de su prompt: no depende de números de línea de este archivo, sólo del patrón regex sobre los cuerpos vivos en S3 (H4), que este cambio no toca. | `tmp/ciclo5_fase2_2026-08-04/prompt_diff_n8_fix_2026-08-04.diff`, `tmp/ciclo5_fase2_2026-08-04/fase2_resumen_2026-08-04.md`, `tmp/ciclo5_fase2_2026-08-04/full_suite_run_2026-08-04.log`, SHA256 en `tmp/ciclo5_fase2_2026-08-04/SHA256SUMS.txt` |
| 3 Parche de datos N8 + resync + re-invalidación | **hecho 2026-08-04 — H4 CERRADO.** Decisión humana #10 resuelta por el dueño: Alcance A (bloque completo) autorizado explícitamente ("eliminar toda contaminación de N8… identificar la causa raíz y removerla"). 96/97 cuerpos parcheados vía detección de bloque + 2 casos especiales, cero residuo verificado; `chunk_90` intacto. Backup completo de los 97 cuerpos vivos a S3 (`chunk_body_backups/1/b61f5d54-ff42-414a-97b7-01682d16f4b5/20260804T144351Z_ciclo5_fase3`) + tmp local ANTES de escribir (además del versioning nativo de S3, confirmado habilitado en PROD). Fix de robustez sobre el diseño original: el modo real descarga cada cuerpo EN VIVO de S3 en vez de confiar en la copia de referencia local de 2026-07-28 (que había derivado en `chunk_23`, detectado por el propio chequeo de ETag del primer intento — abortó sin escribir nada, como debía). 96/96 verificados post-escritura. Resync disparado y completado: **`job_id: "CCCDNEDFYL"`, `status: "COMPLETE"`** — reemplaza a `ZGCU99ISK5`, prompts de las Fases 5 y 6 actualizados en el Anexo A. Invalidación de caché automática (mecanismo de la Fase 1, sin paso adicional). Humo: 2/4 llamadas presupuestadas — 2 preguntas ad-hoc NUEVAS vía `BedrockRagService#query` (páginas 38 EXCELSIOR y 45 FAIN/EKM66) citan el fabricante correcto, CERO contaminación N8 en el `content` citado por Bedrock (prueba directa de reindexado, no sólo status del job) ni en la respuesta, ambas respuestas técnicamente sanas. Causa raíz (prompt de ingesta) ya removida por la Fase 2; re-verificado sin instrucción residual. Ningún hallazgo contradice una restricción ni el gate. Ver Anexo I. | `tmp/ciclo5_fase3_2026-08-04/n8_fase3_real_run_result_2026-08-04.json`, `n8_fase3_smoke_2026-08-04.json`, `n8_fase3_diagnostic_2026-08-04.json`, `prod_backup_20260804T144351Z/HASHES.json`, SHA256 en `tmp/ciclo5_fase3_2026-08-04/SHA256SUMS_fase3_real_run_2026-08-04.txt` |
| 4 Holdout v5 + batería congelados | **hecho 2026-08-04** — dueño confirmó/no vetó Propuesta B (fila de arriba actualizada). (a) `script/fixtures/rag_seguridades_holdout_v5.json`: 14 casos nuevos, distribución idéntica al v4 (3 determinísticas/2 mapeos/2 generalización/1 ambigua/1 sin_respaldo/4 seguridad/1 comparativa), redactados y verificados 1:1 contra el contenido real de `tmp/seguridades_chunks_2026-07-28/chunk_{22,24,27,46,49,57,69,71}.txt` (páginas 24, 26, 29, 48, 51, 59, 71, 73 — ninguna reutilizada de v1-v4, intersección vacía verificada por test); `max_score` real 129, `passing_score` 104 (`ceil(80%)`); los 14 verifican offline `Rag::DeterministicIntent.ambiguous_hardware_query? == false` (las 14 preguntas nombran "página N"); lección H5 aplicada en los 2 `required` de abstención de "orden de cadena no documentado" (casos `..._orden_cadena_seguridad` y `..._orden_terminales_seguridad`), cada uno probado contra 2 fraseos distintos (sustantivo/imperativo) en el QA test. QA test clonado del v4: `test/services/rag/benchmark_rubric_evaluator_holdout_v5_qa_test.rb`, 9 tests / 135 assertions, verde. (b) `script/fixtures/rag_seguridades_provenance_battery_v1.json`: 18 casos (10 `neighbor_expansion_divisor_identity` sobre las divisoras THYSSEN p92/RECOBA p70/FAIN p41/KONE p51/ORONA p60/SCHINDLER p80/CTA p15/CARLOS SILVA p8/MP p54/EDEL p23, cada `expected_section_identity` contrastado 1:1 contra `docs/rag/gate_a_medicion_topologia.md` §5.2 Apéndice E; + 8 `absence_of_n8_contamination` sobre páginas p2/p24/p38/p45/p48/p55/p71/p97, checks determinísticos por campo estructurado, NO rúbrica regex); QA estructural offline (sin Bedrock, $0): `test/services/rag/provenance_battery_v1_qa_test.rb`, 6 tests / 131 assertions, verde. ⚠️ Hallazgo propio de esta fase (no bloqueante, no contradice restricción/gate, no se escala decisión #10 — sólo corrige la fuente de verdad-terreno de la Fase 6, prompt de esa fase ya reescrito con el detalle completo): la copia de referencia local `tmp/seguridades_chunks_2026-07-28/` tiene metadata OBSOLETA (`ingestion_contract_version: field_records_v5`) donde `canonical_name` es un valor constante ("ALJO Control Level 1B Altius") igual en los 97 chunks — NO es la verdad-terreno para `expected_section_identity` de la batería (que viene de Gate A §5.2); la verdad-terreno de metadata en vivo es la que la Fase 1 de este ciclo ya midió con `retrieve` real (`canonical_name: "THYSSEN"` en la página 93). Ambos fixtures + ambos tests + SHA256 en el mismo commit que esta fila; ninguna llamada a Bedrock/Anthropic en esta fase ($0). | `script/fixtures/rag_seguridades_holdout_v5.json`, `script/fixtures/rag_seguridades_provenance_battery_v1.json`, `test/services/rag/benchmark_rubric_evaluator_holdout_v5_qa_test.rb`, `test/services/rag/provenance_battery_v1_qa_test.rb`; SHA256 en `tmp/ciclo5_fase4_2026-08-04/SHA256SUMS.txt` |
| 5 Checkpoint despliegue | **hecho 2026-08-04.** Pre-chequeo: Fases 1-4 ya commiteadas (working tree clean, `git log` confirma hasta `8b062f1`), suite completa verde ANTES de tocar nada (`bin/rails test`: **2292 runs, 8409 assertions, 0 failures, 0 errors, 189 skips**). Dos `kamal deploy` en esta sesión (mismo patrón que ciclo 4 Fase 6: el script de humo debe existir en la imagen para poder correr vía `kamal app exec`): (1) deploy inicial sobre HEAD `8b062f1` (Fase 4, ya commiteado) — `kamal app version` confirmó `8b062f197eefcd7fb8bea625e1dcfdedec6d6540` == HEAD; (2) se creó y commiteó `script/rag_fase5_checkpoint_smoke_2026-08-04.rb` (commit `0fad454`, sólo el script, sin tocar Fases 1-4) y se re-desplegó — `kamal app version` confirmó `0fad454cceddea702f2f99c6efe82e419b5a6ba6` == HEAD tras el segundo deploy. **SHA final desplegado (el que debe verificar la Fase 6): `0fad454cceddea702f2f99c6efe82e419b5a6ba6`.** Ingestion job re-confirmado en ambos checkpoints (antes y después del 2º deploy): `CCCDNEDFYL` sigue `COMPLETE`, sin job posterior (`aws bedrock-agent list-ingestion-jobs`, control-plane, $0 del presupuesto). Humo (**1/1 `retrieve_invocations` del presupuesto de la fase**): 1 pregunta NUEVA, fuera de v1-v4 y de los fixtures de la Fase 4 (no leídos), vía `Rag::StructuredEvidenceRoute` sobre la página divisora casi vacía 51 (portada KONE MONOSPACE) — "¿a qué conector está conectado el terminal 270 (INTERRUPTOR REVISION)?" — forzó expansión de vecindad hacia la página 52 real. **Ambos fixes bloqueantes verificados en la misma llamada:** (a) H1 — cita atribuye `canonical_name: "KONE"` (no "ALJO Control Level 1B Altius"), página citada 52 (no la 51 nombrada, confirma expansión real); log estructurado `[PILOT_USAGE] evidence_route_context` con `"expansion_mechanism":"section_identity","section_identity":"KONE"` como evidencia cruda independiente del script. (b) H4 — cero apariciones de la línea/bloque N8 en el **cuerpo completo** del chunk recuperado (`result[:diagnostics][:retrieved_chunks]`, no el `tooltip_excerpt` truncado a 150 caracteres) ni en la respuesta generada. Respuesta técnicamente sana (identifica XLH5, señala honestamente que la asignación pin-a-pin no es legible con precisión). ⚠️ Hallazgo propio de esta fase (no bloqueante, no contradice restricción/gate, no se escala decisión #10): el booleano `neighbor_expansion_occurred`/`both_fixes_verified` del JSON del script desechable marca `false` por un bug cosmético — compara el string `"section_identity"` contra `Rag::SectionNeighborExpander::MECHANISM_SECTION_IDENTITY`, que es un **símbolo** Ruby (`:section_identity`); `JSON.generate` serializa el símbolo como string en la salida impresa, ocultando la discrepancia de tipo en el JSON pero no en el objeto Ruby real (`Symbol#==String` siempre `false`). El campo subyacente (`retrieval_trace.structured_route.expansion_mechanisms`, visible tal cual en el JSON) y el log `PILOT_USAGE` ya confirman el mecanismo real sin ambigüedad — no se re-ejecutó una segunda llamada para "corregir" el booleano cosmético (habría excedido el presupuesto de 1 llamada de la fase); si la Fase 6 escribe su propio runner y compara `expansion_mechanisms` contra un string literal, debe usar `.to_s` o comparar contra el símbolo. Aurora: la primera llamada del humo golpeó un **cold-start real** (`[Aurora] cold start (attempt 1)…`, `kb_retrieve latency_ms: 20272`) — esperado por diseño (`WarmBedrockKbJob`: "Aurora goes to standby after ~5 min idle"; los dos `kamal deploy` + verificaciones de esta sesión dejaron pasar >5 min sin tráfico Bedrock); `Bedrock::AuroraColdStartRetry` lo absorbió automáticamente (reintento único, éxito) — NO es un defecto de código, no consumió una segunda llamada del presupuesto (el reintento ocurre dentro de la misma invocación SDK). Verificación de Aurora caliente POST cold-start: `WarmBedrockKbJob.perform_now` (ping puro de `Retrieve`, `number_of_results: 1`, registrado como `kb_warm_ping` — evento estructurado FUERA de `bedrock_queries` por diseño, AGENTS.md "Internal Retrieve calls stay off bedrock_queries", no consume el presupuesto de la fase) → `[KB_WARM] ok ms=657`, sin línea `[Aurora] cold start` — **Aurora caliente confirmado, 657ms < 1000ms**; el dueño confirmó independientemente la misma condición probando la app real vía la UI de chat web en producción. `git rev-parse HEAD` == `0fad454cceddea702f2f99c6efe82e419b5a6ba6` == SHA desplegado, sin commits nuevos entre el 2º deploy y el cierre de esta fase. Ningún hallazgo contradice una restricción ni el gate: no se escala decisión #10. | `tmp/ciclo5_fase5_2026-08-04/checkpoint_smoke_2026-08-04.json` SHA256 `cb20de842a2619b2e29ef46d353c528ca005c8efde9de301139a0d42f45a0a34`; `tmp/ciclo5_fase5_2026-08-04/checkpoint_raw_log_2026-08-04.txt` SHA256 `8d9cf758c9bc2fa6db13f3d54423717d2d9cd9250c847cd1a8ec4de945133fdc`; `script/rag_fase5_checkpoint_smoke_2026-08-04.rb`; commit `0fad454cceddea702f2f99c6efe82e419b5a6ba6` |
| 6 Gate v5 → piloto | **desbloqueada (Fase 5 cerró 2026-08-04: SHA `0fad454` desplegado, job `CCCDNEDFYL` `COMPLETE`, humo verde con ambos fixes bloqueantes confirmados, Aurora caliente 657ms)** — ver prompt actualizado en el Anexo A. | — |

## Decisión humana #10 — alcance del parche N8 — **RESUELTA 2026-08-04**

**Resolución del dueño:** "te autorizo a eliminar toda contaminación de N8, y además
identificar la causa raíz y removerla. No podemos dejar chunks que confundan al
retrieve y a la generación de la respuesta, porque invalida la medición de precisión."
— **Alcance A (bloque completo)**, la opción recomendada por este plan. Ejecutado en
la misma sesión (ver fila 3 de Estado y Anexo I); causa raíz confirmada ya removida
por la Fase 2 (Fase 2 no necesitó cambios adicionales).

**Contexto original (para trazabilidad):** H10 y el Estado de la Fase 3 (arriba). El
regex de línea única que la restricción 2 autorizó como el parche N8 ("sustitución de
texto... la línea contaminante ES exactamente esa única línea") sólo describe 1 de los
96 cuerpos reales. Cerrar H4 de verdad requería remover un bloque de 1-4 líneas por
chunk (11 formas distintas) más 2 casos fuera de bloque — un alcance más amplio, que
el dueño no había revisado en esta forma.

**Opciones (script ya escrito y verificado con cero residuo para ambas; sólo cambia
qué líneas se remueven):**

1. **Alcance A — bloque completo (recomendado):** remover el bloque de identidad
   entero (`**Document:**` + toda continuación contigua de
   `**Section:**`/`**Page:**`/`ORIGINAL_FILE_NAME:`/`NORMALIZED_FILE_NAME:`/`SOURCE_URI:`)
   más los 2 casos especiales (`chunk_0`, `chunk_36`). Deja el cuerpo exactamente como
   lo produciría el prompt YA corregido en la Fase 2 (que no emite ningún header de
   identidad) — paridad profiláctica completa. Justificación adicional:
   `Bedrock::CitationProcessor::METADATA_LINE_PATTERN`
   (`app/services/bedrock/citation_processor.rb:143-144`) YA descarta líneas
   `**Section:**`/`**Page:**` al construir el excerpt de citación — el runtime ya
   trata esas líneas como ruido a filtrar, no como señal útil para el usuario final.
   Un solo invariante de remoción, verificable de forma uniforme en las 11 formas.
2. **Alcance B — preservar `**Section:**`/`**Page:**` sueltas:** remover sólo la
   línea/porción `**Document:** ALJO Control Level 1B Altius...` (con su
   `PIPELINE_INJECTED`/`ORIGINAL_FILE_NAME:`/etc. asociado) y dejar intactas las
   líneas `**Section:**`/`**Page:**` cuando aparecen como línea propia — conserva el
   número de página/sección tal como el modelo lo transcribió (redundante con
   `page_number`/`section_identity` del sidecar, pero potencialmente útil como
   contexto adicional para el modelo de generación). Riesgo: `chunk_75` combina
   `**Document:** ALJO Control Level 1B Altius \| **Page:** 77` en una sola línea —
   preservar selectivamente ahí exige lógica de sub-línea (partir la línea, no sólo
   removerla), inconsistente con el resto de las 10 formas y con más superficie de
   error en un patch de datos de producción safety-critical.

**Recomendación de este plan: Alcance A.** Más simple, un solo invariante de
seguridad, consistente con cómo el runtime ya trata esas líneas (filtro de
citación) y con la intención profiláctica ya declarada de la Fase 2.

**Elegido y ejecutado: Alcance A.** El dueño confirmó Alcance A (ver "Resolución del
dueño" arriba) y una sesión ejecutó `script/repair_seguridades_n8_body_2026-08-04.rb`
en modo real el mismo 2026-08-04 (backup completo + SHA256, verificación de ETag
reemplazada por descarga en vivo — ver Anexo I —, resync `COMPLETE`, invalidación de
caché automática, humo verde). Ver fila 3 de la tabla de Estado y Anexo I para el
detalle completo de ejecución.

## Protocolo de plan vivo

Toda sesión que ejecuta una fase, ANTES de cerrar y en el MISMO commit:

1. Actualiza su fila de la tabla de Estado (hecho/bloqueado + artefacto/SHA256; los
   artefactos en tmp LOCAL — restricción 6).
2. Corrige las fases posteriores afectadas por sus hallazgos (con fecha y evidencia).
3. Reescribe el prompt de la fase SIGUIENTE en el Anexo A incorporando sus hallazgos; si
   el hallazgo cambia la implementación de esa fase, lo marca con `⚠️ CRÍTICO:` al
   inicio. Dependencias ya previstas: Fase 1 → prompt de Fase 3 (mecanismo real de
   invalidación); Fase 3 → prompts de Fases 5 y 6 (ingestion job nuevo); Fase 0 → puede
   degradar cualquier fase si un hallazgo dejó de ser vigente.
4. `git commit` de TODO (código + este documento + fixtures/tests). Nada queda sin
   commitear al cerrar.
5. Si un hallazgo contradice una restricción no negociable o el criterio del gate: NO se
   ejecuta — se documenta y se escala como decisión humana numerada (siguiente: #10).

## Anexo A — Prompt de arranque por fase

**Pie común (añadir al final de cada prompt):**

> Lee primero `docs/rag/plan_ciclo5_resolucion_decision9_2026-08-04.md` COMPLETO (tabla
> de Estado, hallazgos H1-H8, restricciones) y la fila de Estado de la fase anterior. NO
> necesitas releer el ciclo 4 entero: la evidencia que te aplica está citada verbatim en
> este documento; si algo no cuadra, la fuente es
> `docs/rag/plan_ciclo4_ajuste_final_2026-08-03.md` (Anexos D y F). Restricciones: sin
> regex nuevo de forma-de-pregunta; cero re-ingesta SALVO el parche N8 autorizado en este
> ciclo (Fase 3, sin llamadas a Anthropic); ninguna llamada a la API de Anthropic desde
> la app; presupuesto Bedrock de tu fase declarado en el plan, no lo excedas; artefactos
> a tmp LOCAL + SHA256 ANTES de cerrar la sesión; sesión corta, un objetivo, sin fan-out
> de subagentes; los holdouts v1-v4 están gastados — no los reabras ni con
> `RAG_SEGURIDADES_CASE_IDS`; `bulk_chunks/` es ingestion-only (nada derivado ahí); los
> fixes del ciclo 4 (page-pin, flag N11, guardrail, evaluador v2) no se tocan. Antes de
> cerrar aplica el Protocolo de plan vivo: (1) actualiza tu fila de Estado, (2) corrige
> las fases posteriores afectadas, (3) reescribe el prompt de la fase SIGUIENTE en este
> Anexo con tus hallazgos — márcalo `⚠️ CRÍTICO:` si cambia su implementación, (4) si un
> hallazgo contradice una restricción o el gate: no lo ejecutes, escálalo como decisión
> humana #10, (5) `git commit` de todo (código + este documento) en el mismo commit.

### Fase 0 — Sonnet 5 (listo para ejecutar)

> El diagnóstico grande ya está cerrado (ciclo 4: Anexo F, "Corrección al caso 2", Anexo
> D) — NO lo re-derives. Tu único objetivo: verificar que los hallazgos H1, H3 y H4 de
> este plan siguen vigentes HOY contra código/S3/Bedrock, por si algo cambió desde el
> 2026-08-04. Verifica y entrega una tabla (hallazgo × vigente sí/no × evidencia) como
> anexo de este documento: (a) `app/services/rag/section_neighbor_expander.rb` —
> `INDEX_CACHE_TTL = 30.days` (línea 19), clave
> `section_neighbor_index/v1/<sha256(prefix)>` (líneas 18, 142-144), y cero ganchos de
> invalidación en el repo (`grep -rn section_neighbor_index` fuera de la clase y sus
> tests); (b) el sidecar `chunk_91.txt.metadata.json` (página 93) en S3 sigue con
> `canonical_name: "THYSSEN"`, y el ingestion job más reciente del data source sigue
> siendo `ZGCU99ISK5` `COMPLETE` (`aws bedrock-agent list-ingestion-jobs` descendente) —
> si hay un job posterior, anótalo: cambia el supuesto de la Fase 3; (c)
> `app/prompts/batch_chunking_prompt.rb` líneas ~293-315 siguen instruyendo emitir
> `**Document:**` dentro del cuerpo, con el comentario de cabecera (13-16)
> contradiciéndolo; (d) muestrea ≥5 chunks no-ALJO del prefijo SEGURIDADES vivo en S3 y
> confirma la línea `**Document:** ALJO Control Level 1B Altius | Page N |
> …PIPELINE_INJECTED…` contra el backup local `tmp/seguridades_chunks_2026-07-28/`
> (`chunk_90` sigue siendo el único limpio). NO toques la caché, NO toques código, NO
> llames a `retrieve` (S3/bedrock-agent son control-plane, $0 del presupuesto). Si los 4
> siguen vigentes: anota "Fases 1-3 proceden sin cambios". Si alguno cambió: corrige
> la(s) fase(s) afectada(s) y su(s) prompt(s) ANTES de cerrar. NO arregles nada en esta
> fase.

### Fase 1 — Sonnet 5 (consulta acotada a Opus 5 SÓLO si la opción estructural queda genuinamente ambigua tras tu análisis)

> Hipótesis (decláralala antes de tocar nada): la entrada
> `section_neighbor_index/v1/<sha256(prefix)>` del prefijo SEGURIDADES quedó construida
> ANTES del parche de canonical_name del 2026-08-03 y por eso
> `Rag::SectionNeighborExpander` adjunta `canonical_name: "ALJO Control Level 1B
> Altius"` a citas de contenido THYSSEN (la cadena: `page_index` línea 91-95 cachea
> `entry[:metadata]` desde los `.metadata.json` de S3 del momento de construcción;
> `neighbor_chunk` línea 53 lo adjunta a la cita;
> `Bedrock::CitationProcessor#build_numbered_references` línea 82 lo lee tal cual). Si
> borras esa entrada, la próxima expansión reconstruye el índice desde los sidecars ya
> parcheados y la cita sale "THYSSEN". Resultado si es falsa: la cita seguiría diciendo
> "ALJO" tras el borrado — PARA y escala como decisión #10 (habría otra capa
> desactualizada que este plan no conoce). Entrega en DOS partes: (1) invalidación
> dirigida AHORA: `bin/rails runner` vía `kamal app exec --reuse -r web` que compute la
> clave con el prefijo real y haga `Rails.cache.delete`; ANTES de borrar, lee y guarda el
> valor viejo como artefacto (evidencia del estado contaminado) a tmp local + SHA256.
> (2) fix estructural: evalúa con costo/beneficio las 3 opciones del plan (Fase 1 del
> documento) — (i) `Rag::SectionNeighborExpander.invalidate!(prefix)` invocado por el
> script de reparación de metadata y por el flujo de resync [recomendada], (ii) bajar
> `INDEX_CACHE_TTL` [sólo como defensa secundaria adicional], (iii) versionar la clave
> con hash del contenido fuente [descártala salvo fingerprint gratis — leer sidecars por
> request anula la caché]. Implementa la elegida + tests Minitest (borra exactamente la
> clave del prefijo; el script de reparación la llama; TTL nuevo si aplica). No toques la
> semántica de `page_index`/`authorize`. Verificación en vivo tras deploy (committea el
> código ANTES de `kamal deploy` — lección ciclo 4): 1-2 preguntas ad-hoc NUEVAS que
> fuercen expansión de vecindad sobre la página 92 THYSSEN (hechos distintos a v3/v4) —
> la cita debe decir "THYSSEN"; ≤4 llamadas, artefacto + SHA256. ⚠️ Al cerrar: reescribe
> el prompt de la Fase 3 con el mecanismo EXACTO de invalidación que implementaste — la
> Fase 3 debe ejecutarlo tras su resync (hallazgo H8: la caché también congela CUERPOS de
> vecinos vía `cache_neighbor_body`, líneas 137-140).

### Fase 2 — Sonnet 5

> Va ANTES del parche de datos a propósito: es código puro sin riesgo de datos y evita
> que cualquier ingesta nueva reproduzca N8 mientras tanto. En
> `app/prompts/batch_chunking_prompt.rb`: elimina la instrucción de emitir la línea
> `**Document:** {hint} | Page N | ORIGINAL_FILE_NAME: PIPELINE_INJECTED | …` dentro del
> CUERPO de cada chunk (líneas ~293-315, incluida la regla "Each section title must
> appear inside the chunk after the `**Document:**` header" de la línea 293) y corrige el
> comentario de cabecera (líneas 13-16) para que deje de contradecir al código — la
> identidad es 100% Rails-injected por `BatchResultsParserService#identity_header`; el
> cuerpo no debe llevar marcadores. NO toques: el campo JSON `document_name`, el
> `document_name_hint` de la página ancla (regla "ONE FILE = ONE IDENTITY" — correcto, se
> queda), `SingleFileChunkingService`, ni `BatchResultsParserService`. Ajusta los tests
> del prompt que esperen la línea vieja; corre la suite completa. Cero llamadas a
> cualquier API. Este cambio NO altera datos vivos ni embeddings — no invalida ninguna
> medición ni condiciona a la Fase 3. ⚠️ NO limpies los 96 cuerpos vivos en S3 en esta
> fase (eso es la Fase 3, con su backup, su script dry-run-por-defecto y su resync): tu
> fix es profiláctico y N8 sigue vigente en producción cuando cierres. Al anotar tu fila
> de Estado, dilo explícitamente para que nadie lea "Fase 2 hecha" como "N8 resuelto".

### Fase 3 — ✅ CERRADA 2026-08-04 (prompt histórico, no re-ejecutar)

> **Esta fase ya se ejecutó y cerró.** El dueño resolvió la Decisión humana #10
> (Alcance A, bloque completo) y una sesión ejecutó
> `script/repair_seguridades_n8_body_2026-08-04.rb` en modo real
> (`RAG_CHUNK_PATCH_CONFIRM=1`): 96/97 cuerpos parcheados, backup completo
> (S3 + tmp local), resync `job_id: "CCCDNEDFYL"` `COMPLETE`, humo verde (2/4
> llamadas). Ver fila 3 de la tabla de Estado y Anexo I para el detalle completo. **No
> hay nada pendiente de esta fase** — si una sesión futura llega aquí buscando qué
> hacer, es un error de secuencia: la fase siguiente a ejecutar es la 4, 5 o 6 según lo
> que diga su fila de Estado. El prompt original (línea única, luego bloque completo)
> queda abajo sólo por trazabilidad histórica, NO como instrucción vigente:
>
> ~~⚠️ CRÍTICO — reescrito 2026-08-04 tras la sesión que ejecutó esta fase y encontró
> su hipótesis de línea única FALSIFICADA (H10, Anexo H). NO uses el regex del
> borrador original de este prompt
> (`\*\*Document:\*\* ALJO Control Level 1B Altius \| Page \d+ \| ORIGINAL_FILE_NAME: PIPELINE_INJECTED.*`)
> como criterio de contaminación — sólo coincide con 1/96 cuerpos. Detecta el bloque
> real de identidad (línea `**Document:**` + continuaciones
> `**Section:**`/`**Page:**`/`ORIGINAL_FILE_NAME:`/`NORMALIZED_FILE_NAME:`/`SOURCE_URI:`)
> más 2 casos especiales (`chunk_0`, `chunk_36`); implementa el modo real gateado por
> `RAG_CHUNK_PATCH_CONFIRM=1`; backup completo + SHA256 antes de escribir; sube por
> `S3DocumentsService#upload_text` (nunca `Aws::S3::Client` crudo); resync, espera
> `COMPLETE`, anota el job id NUEVO; humo ≤4 llamadas.~~

### Fase 4 — Sonnet 5 (sesión NUEVA; si participaste en las Fases 1-3, detente: lo redacta otra sesión)

> [Nota de la Fase 3, 2026-08-04, sin cambio de implementación aquí: la fila de Estado
> de la Fase 3 ya confirma "hecho" — 96/97 cuerpos parcheados (Alcance A), resync
> `job_id: "CCCDNEDFYL"` `COMPLETE`. Los 97 cuerpos POST-parche ya son la fuente de
> verdad vigente en S3/Bedrock; redacta contra ellos sin condición pendiente.] Antes de
> empezar: confirma en la tabla de Estado que el dueño NO vetó la propuesta B del
> protocolo de validación (fila "Protocolo de validación"); si eligió A, detente y
> escala — esta fase se re-planifica (esta es la única condición aún abierta para esta
> fase; no depende de N8). Redacta y congela DOS fixtures sin correrlos:
> (a) `script/fixtures/rag_seguridades_holdout_v5.json` — 14 preguntas nuevas,
> distribución del v4 (3 determinísticas / 2 mapeos / 2 generalización / 1 ambigua / 1
> sin respaldo / 4 seguridad / 1 comparativa), desde la verdad-terreno pagada (Gate A
> §5-§9 + los 97 cuerpos POST-parche), sin reutilizar NINGUNA pregunta de v1-v4
> (verificación por script, intersección vacía). Reglas heredadas del v4 completas: `severity: safety_critical` a
> nivel de caso + `penalized` con `severity: critical`; `source_page_required` consciente
> por caso (menú de desambiguación → `false`); verificación offline
> `Rag::DeterministicIntent.ambiguous_hardware_query? == false` en los 14; QA test
> clonado del v4 (tally, suma real, `passing_score = ceil(80%)`, cobertura de ids,
> respuesta correcta conocida contra el evaluador real, ningún penalized dispara,
> no-reutilización contra v1+v2+v3+v4). (b)
> `script/fixtures/rag_seguridades_provenance_battery_v1.json` — 15-20 preguntas
> dirigidas a los 2 fixes bloqueantes: casos que fuercen expansión de vecindad en
> divisoras (check determinístico: `canonical_name` de cada cita == `section_identity`
> del sidecar de la página citada) y casos cuyo check es la AUSENCIA de la línea
> `**Document:** ALJO…` en los cuerpos recuperados de páginas no-ALJO — checks
> determinísticos, NO rúbrica regex. ⚠️ Lección obligatoria del falso negativo del gate
> v4 (H5): todo `required` de abstención debe aceptar paráfrasis — sustantivo E
> imperativo ("requiere verificación" Y "verificar en campo"), sin objeto literal único
> ("esa secuencia" alterna con "la secuencia( textual)?", "el orden"); prueba cada patrón
> contra ≥2 fraseos correctos distintos en el QA test. Prohibiciones heredadas: ventanas
> `.{0,N}` que crucen ítems; lookaheads sin el "no" pospuesto; corregir erratas del
> documento en los required. N8 ya está parcheado: la regla vieja "no exigir marca fuera
> de ALJO 2-7 y divisoras limpias" queda derogada — puedes exigir marca correcta donde el
> contenido la respalde. NO corras nada contra Bedrock: ambos fixtures se abren UNA vez
> en la Fase 6.

### Fase 5 — Sonnet 5 (NO Haiku)

> [La Fase 3 (2026-08-04) ya actualizó este prompt con el ingestion job nuevo:
> `job_id: "CCCDNEDFYL"` — reemplaza a `ZGCU99ISK5`.] Checkpoint previo al gate: Fases
> 1-3 commiteadas con suite verde ANTES de tocar nada. `kamal deploy`; verifica SHA
> desplegado == HEAD con `kamal app version`. Confirma con
> `aws bedrock-agent list-ingestion-jobs --knowledge-base-id Y7RZWMFJSR --data-source-id PJ0N58DMHG`
> (orden descendente) que el job vigente sigue siendo `CCCDNEDFYL` en `COMPLETE` — si
> hay uno posterior, anótalo y verifica que no tocó el prefijo SEGURIDADES de forma
> inesperada. Humo: 1
> llamada, `-r web` SIEMPRE (sin `--role` corre en web+worker y duplica el gasto),
> pregunta nueva fuera de todo holdout que fuerce expansión de vecindad — la cita debe
> traer el fabricante correcto Y el cuerpo recuperado sin línea N8 (ejercita los DOS
> fixes en una llamada). Aurora caliente (`kb_retrieve` < 1s, sin cold-start). Anota en
> Estado: SHA, timestamp, evidencia del humo (tmp local + SHA256). NO abras los fixtures
> de la Fase 4: eso es la Fase 6.

### Fase 6 — Sonnet 5 (NO Haiku)

> [La Fase 3 (2026-08-04) ya fijó la referencia del ingestion job vigente
> (`job_id: "CCCDNEDFYL"`, `COMPLETE`); la Fase 5 (2026-08-04) corrió el checkpoint y
> desplegó `git rev-parse HEAD == 0fad454cceddea702f2f99c6efe82e419b5a6ba6` — ese es el
> SHA que `kamal app version` debe reportar antes de abrir el gate. Si esta sesión ve un
> `HEAD` distinto de `0fad454...` por commits nuevos que tocan `app/`/`config/`/`script/`
> desde el cierre de la Fase 5: repite la Fase 5 primero (precedente del gate v4); un
> commit sólo-documento (p.ej. esta misma fila de Estado) no obliga a re-desplegar.]
> ⚠️ CRÍTICO — hallazgo de la Fase 5 (2026-08-04), no cambia el criterio del gate pero SÍ
> tu expectativa operativa al abrir la corrida: la primera llamada del checkpoint golpeó
> un cold-start real de Aurora (`kb_retrieve latency_ms: 20272`, `[Aurora] cold start
> (attempt 1)…`) — comportamiento ESPERADO por diseño (`WarmBedrockKbJob`: Aurora
> Serverless se auto-pausa a los ~5 min de inactividad Bedrock) tras los dos `kamal
> deploy` de esa sesión sin tráfico intermedio; `Bedrock::AuroraColdStartRetry` lo
> absorbió automáticamente (reintento único, éxito), SIN consumir una segunda llamada del
> presupuesto (el reintento vive dentro de la misma invocación SDK). Si tu PRIMERA llamada
> del gate (de las ~38-45 presupuestadas) también golpea un cold-start: es esperado, NO es
> un defecto ni motivo para parar — deja que `AuroraColdStartRetry` reintente (hasta 3
> veces, 15/30/45s) y continúa; si prefieres evitar que la primera pregunta REAL del gate
> pague ese costo de latencia, corre `WarmBedrockKbJob.perform_now` vía `kamal app exec
> --reuse -r web "bin/rails runner 'WarmBedrockKbJob.perform_now'"` ANTES de la corrida —
> es un ping puro de `Retrieve` (`kb_warm_ping`, fuera de `bedrock_queries` por diseño,
> AGENTS.md "Internal Retrieve calls stay off bedrock_queries") que NO consume el
> presupuesto de `retrieve_invocations` del gate. Nota de sintaxis: `bin/rails runner`
> usa `-e` para `--environment`, NO para eval inline como `ruby -e` — pasa el código Ruby
> como argumento posicional entre comillas simples, sin `-e`.
> ⚠️ CRÍTICO — hallazgo de la Fase 4 (2026-08-04) que SÍ cambia cómo evalúas el check
> (4) de este párrafo: la copia de referencia local `tmp/seguridades_chunks_2026-07-28/`
> tiene un esquema de metadata OBSOLETO (`ingestion_contract_version: "field_records_v5"`,
> más viejo que el `field_records_v7`/`v8` que ya escriben `chunk_merger_service.rb` y
> `batch_results_parser_service.rb`) — en esa copia, `metadataAttributes.canonical_name`
> es UN VALOR CONSTANTE ("ALJO Control Level 1B Altius") igual en los 97 chunks
> (verificado por grep directo, ver commit de esta fase), NO el nombre por-página que la
> Fase 1 de este mismo ciclo ya confirmó EN VIVO (2 llamadas reales a Bedrock: la cita de
> la página 93 trae `canonical_name: "THYSSEN"`, no ALJO). **NO uses la copia local para
> derivar el `expected_section_identity` de ningún caso de la batería de proveniencia ni
> para decidir si el check (4) pasa** — la única verdad-terreno válida es (a)
> `docs/rag/gate_a_medicion_topologia.md` §5.2 (Apéndice E, las 18 divisoras) para el
> `expected_section_identity` de cada caso `neighbor_expansion_divisor_identity` (ya
> incrustado en el fixture, cada valor contrastado 1:1 contra esa tabla en esta fase) y
> (b) la respuesta REAL de Bedrock en esta misma Fase 6 para el veredicto. El campo a
> comparar en el runner es `citation[:metadata]["canonical_name"]` (el metadata crudo de
> la cita, expuesto por `Bedrock::CitationProcessor#extract_citations`), NO el `title`
> ya renderizado (`Bedrock::CitationProcessor#build_numbered_references` le concatena
> `" — p. N"`) — compáralo tal cual contra `expected_section_identity` del caso, sin
> parsear el sufijo de página. Ningún hallazgo de esta fase contradice una restricción ni
> el gate: no se escala decisión #10, sólo se corrige la fuente de verdad-terreno de la
> Fase 6.
> Criterio congelado ANTES de abrir, AND estricto, sin ajustes tras ver
> resultados: (1) holdout v5 ≥80% de la suma real (129 pts, `passing_score` 104); (2) cero
> `passed: false` en los 4 `safety_critical`; (3) `source_page_cited` verde en esos 4; (4) batería de
> proveniencia (18 casos: 10 `neighbor_expansion_divisor_identity` + 8
> `absence_of_n8_contamination`, `script/fixtures/rag_seguridades_provenance_battery_v1.json`):
> CERO citas cuyo `canonical_name` (metadata crudo, ver nota crítica arriba) contradiga la
> `expected_section_identity` del caso Y CERO apariciones de los `forbidden_patterns` del
> caso en los `content` recuperados.
> Verifica ANTES que la Fase 5 anotó SHA y humo verde y que `git rev-parse HEAD` coincide
> con el SHA desplegado (commits que toquen `app/`/`config/`/`script/` → repite la Fase 5
> primero; commits sólo-documento no obligan — precedente del gate v4). Corre holdout v5
> y batería UNA sola vez cada uno (patrón Kamal: `bundle exec kamal app exec --reuse -r
> web -p "sh -c '…'"`); presupuesto ~38-45 `retrieve_invocations` entre ambos. Antes de
> cerrar (restricción 6): verifica que cada caso trae `chunks` y `answer` no vacíos,
> copia los artefactos del contenedor a tmp LOCAL y anota SHA256 en Estado — las corridas
> NO se repiten. Pasa → liberar a piloto con el guardrail de presentación del ciclo 4
> activo. No pasa → clasifica cada fallo (defecto real vs. arnés, con la página y la
> proveniencia que el evaluador v2 y los checks determinísticos exponen), v5 y batería
> quedan gastados, PARA y escala como decisión humana #10.

## Anexo F — Fase 0: verificación de vigencia (2026-08-04, Sonnet 5)

Lectura pura: cero escrituras a caché/código/KB, cero llamadas a `retrieve`.
Evidencia completa (excerpts de código, comandos AWS, diffs y SHA256 por
chunk muestreado) en `tmp/ciclo5_fase0_verificacion_vigencia_2026-08-04.md`,
SHA256 `12541d960cdd5234be301ae003bc03314c655697c573397c05202411bc0c46fb`.

| Hallazgo | Vigente | Evidencia (resumen) |
|---|---|---|
| (a) H1 — `INDEX_CACHE_TTL = 30.days` (línea 19), clave `section_neighbor_index/v1/<sha256(prefix)>` (líneas 18, 142-144), cero ganchos de invalidación | **Sí** | Código leído tal cual en HEAD; `grep -rn section_neighbor_index` fuera de la propia clase → 0 resultados de código; ningún caller (`rag_controller.rb:175`, `structured_evidence_route.rb:83,351`) invoca invalidación. Dato colateral fuera de alcance: `Rag::DocumentOverviewCache` (clase hermana, TTL igual, commit distinto `98baff3` vs. `2d1e141` de `SectionNeighborExpander`) sí expone `.invalidate` público pero tampoco tiene caller productivo — mismo patrón, otra caché; anotado para que la Fase 1 lo use como precedente de diseño, sin tocarlo. |
| (b) Estado del KB — sidecar página 93 `canonical_name: THYSSEN`; job más reciente `ZGCU99ISK5` `COMPLETE` | **Sí** | `aws s3api get-object` sobre `chunk_91.txt.metadata.json` (bucket `multimodal-source-destination`, prefix `bulk_chunks/1/b61f5d54-ff42-414a-97b7-01682d16f4b5/`) → `canonical_name":"THYSSEN"`. `aws bedrock-agent list-ingestion-jobs --knowledge-base-id Y7RZWMFJSR --data-source-id PJ0N58DMHG` orden descendente → primer resultado `ZGCU99ISK5`, `COMPLETE`, `startedAt 2026-08-03T21:39:54Z`; sin job posterior. Supuesto de la Fase 3 intacto. |
| (c) H3 — `batch_chunking_prompt.rb` línea 293 exige `**Document:**` en el cuerpo; cabecera (13-16) lo contradice | **Sí** | Ambos bloques leídos tal cual en HEAD, sin cambios desde la cita del plan. |
| (d) H4 — cuerpos vivos en S3 siguen con la línea `**Document:** ALJO Control Level 1B Altius…`; `chunk_90` sigue el único limpio | **Sí** | 5 chunks no-ALJO muestreados (`chunk_66` OTIS 2.000, `chunk_27` EM3000, `chunk_61` ARCA II, `chunk_20` MR08, `chunk_86` TWISTER) descargados de S3 vivo: los 5 tienen la línea contaminante y son **byte-idénticos** (SHA256 igual) al backup local `tmp/seguridades_chunks_2026-07-28/`. `chunk_90.txt` (695 bytes) sigue limpio e idéntico al backup. `chunk_91.txt` (página 93) sigue con la línea `ALJO…` en el cuerpo pese a que su sidecar ya dice `THYSSEN` — la discrepancia cuerpo-vs-metadata que sostiene H1/H9. |

**Conclusión de la Fase 0: los 4 hallazgos están vigentes. Fases 1-3 proceden
sin cambios** — no se reescribe ningún prompt del Anexo A porque ninguna
premisa cambió. Ningún hallazgo contradice una restricción ni el criterio
del gate: no se escala decisión humana #10.

## Anexo H — Fase 3: falsificación de la hipótesis de línea única (2026-08-04, Sonnet 5)

Sesión bloqueada, sin escrituras a S3/Bedrock. Resumen completo, catálogo de las 97
formas por chunk, y verificación de cero residuo en
`tmp/ciclo5_fase3_2026-08-04/fase3_resumen_2026-08-04.md` (SHA256 en
`tmp/ciclo5_fase3_2026-08-04/SHA256SUMS.txt`, junto con el JSON detallado por
chunk).

**Método:** `script/repair_seguridades_n8_body_2026-08-04.rb` (modo diagnóstico,
sin red) leyó los 97 cuerpos de `tmp/seguridades_chunks_2026-07-28/` — verificados
byte-idénticos a S3 vivo para una muestra de 5 por la Fase 0 el mismo día — y
comparó cada uno contra (a) el regex literal del borrador de esta fase y (b) un
detector de bloque de identidad contiguo.

**Resultado (a):** el regex literal
(`\*\*Document:\*\* ALJO Control Level 1B Altius \| Page \d+ \| ORIGINAL_FILE_NAME: PIPELINE_INJECTED.*`)
coincide EXACTO con **1 de 96** cuerpos contaminados (`chunk_43`). Los otros 95
llevan la misma contaminación de fondo (identidad ALJO incrustada) pero en una
forma distinta — el modelo de visión, al obedecer la instrucción retirada en la
Fase 2 ("Each section title must appear inside the chunk after the
`**Document:**` header"), nunca siguió un template fijo de campos/orden/separadores.

**Resultado (b):** el detector de bloque (línea `**Document:**` + continuaciones
`**Section:**`/`**Page:**`/`ORIGINAL_FILE_NAME:`/`NORMALIZED_FILE_NAME:`/`SOURCE_URI:`)
cubre 95/96 correctamente, más 2 casos especiales verificados manualmente y
codificados en el script: `chunk_0` (S0/ancla p.2, ALJO real — 2 filas de tabla
`PIPELINE_INJECTED` en `## S0 chunk content`, retiradas del prompt en la Fase 2 pero
no reparadas en el dato) y `chunk_36` (línea suelta en prosa, p.38 EXCELSIOR, línea
75: *"Sistema general: ALJO Control Level 1B Altius"* — inmediatamente DESPUÉS de
*"Fabricante del sistema: EXCELSIOR"*, contradiciendo la marca ya correctamente
identificada un renglón antes). Con ambos casos especiales, la remoción propuesta
deja **cero residuo** de `ALJO Control Level 1B Altius` o `PIPELINE_INJECTED` en los
96 cuerpos, y **cero cambios colaterales** (verificado línea por línea, no sólo por
hash, que ninguna línea NO removida cambió de contenido u orden).

**Por qué se detiene aquí, sin ejecutar:** el bloque removido mide 1-4 líneas según
el chunk (32 casos de 1 línea, 27 de 2, 35 de 3, 2 de 4) — más ancho que la "única
línea" que la restricción 2 autorizó explícitamente, y en el caso de `chunk_75`
(`**Document:** ALJO Control Level 1B Altius \| **Page:** 77`, ambos campos en la
misma línea) no existe una forma limpia de preservar sólo `**Page:** 77` sin lógica
de sub-línea. Ver "Decisión humana #10" para las dos opciones de alcance y la
recomendación. Ningún hallazgo de esta sesión contradice una restricción del plan
per se (la restricción 2 sigue íntegra; lo que cambia es el ALCANCE del parche que
antes se asumía cabía dentro de ella) — se escala igual, dado que ejecutar contra
datos de producción safety-critical con un alcance no revisado por el dueño no es
una decisión que le corresponda a la sesión que descubrió la discrepancia.

## Anexo I — Fase 3: ejecución real del parche (Alcance A) y humo (2026-08-04, Sonnet 5)

Decisión humana #10 resuelta por el dueño en el mismo día que se escaló (ver sección
dedicada): autorización explícita a "eliminar toda contaminación de N8" + identificar
y remover la causa raíz (ya removida por la Fase 2, re-verificado sin instrucción
residual). Ejecución en modo real de `script/repair_seguridades_n8_body_2026-08-04.rb`
(`RAG_CHUNK_PATCH_CONFIRM=1`), Alcance A (bloque completo, ver Anexo H para el diseño
de detección).

**Fix de robustez descubierto durante la ejecución:** el diseño original de la Fase 3
(y el primer intento de modo real de esta sesión) pre-verificaba el ETag de los 97
objetos vivos en S3 contra la copia de referencia local
`tmp/seguridades_chunks_2026-07-28/` (2026-07-28) ANTES de escribir — abortó
correctamente en `chunk_23.txt`: el objeto vivo ya no coincidía con esa copia
(drift real; la Fase 0 de este ciclo, el mismo 2026-08-04, sólo había muestreado 5
chunks distintos — no ése — así que no lo detectó). El chequeo de ETag hizo
exactamente lo que debía: abortar sin escribir nada ante un supuesto violado, en vez
de sobreescribir a ciegas. Corrección aplicada: el modo real ya NO usa el contenido de
la referencia local como fuente de verdad para decidir qué escribir — descarga cada
uno de los 97 cuerpos EN VIVO desde S3 y corre la misma detección de bloque + casos
especiales sobre ese byte fresco; aborta si algún caso especial esperado no aparece
verbatim o si la remoción propuesta dejaría residuo. La referencia local
(`tmp/seguridades_chunks_2026-07-28/`) queda limitada a (a) el modo diagnóstico (sin
red, para iterar rápido) y (b) el snapshot de los 97 nombres de archivo esperados. S3
tiene versioning habilitado en PROD (confirmado por el dueño) — respaldo adicional más
allá del backup explícito que el script igual hace antes de escribir.

**Ejecución real (segundo intento, exitoso):**

1. Descarga en vivo de los 97 cuerpos; re-análisis de bloque + casos especiales sobre
   cada uno — 96 contaminados, cero residuo verificado, `chunk_90` sin tocar (mismo
   resultado que el diagnóstico sobre la copia local, confirmando que no hubo más
   drift que el ya detectado en `chunk_23`).
2. Backup completo de los 97 cuerpos vivos (tal como se descargaron) a
   `s3://multimodal-source-destination/chunk_body_backups/1/b61f5d54-ff42-414a-97b7-01682d16f4b5/20260804T144351Z_ciclo5_fase3`
   y a `tmp/ciclo5_fase3_2026-08-04/prod_backup_20260804T144351Z/` (manifest
   `HASHES.json` con SHA256 antes/después por objeto) — ANTES de escribir nada.
3. Escritura de los 96 cuerpos parcheados vía `S3DocumentsService#upload_text` (nunca
   `Aws::S3::Client` crudo) a sus claves originales — dispara la invalidación de caché
   de la Fase 1 automáticamente (H8).
4. Verificación post-escritura: 96/96 SHA256 coinciden con el resultado esperado.
5. Resync: `BulkKbSyncService#sync!` → `job_id: "CCCDNEDFYL"`, `kb_id: "Y7RZWMFJSR"`,
   `data_source_id: "PJ0N58DMHG"`. Polling: `IN_PROGRESS IN_PROGRESS COMPLETE`
   (~2.5 min total) — **`COMPLETE`**, sin reintentos ni errores.

**Humo (2 de las ≤4 llamadas presupuestadas para la fase):** 2 preguntas ad-hoc NUEVAS
(no reutilizadas de v1-v4) vía `BedrockRagService#query` (la ruta de producción real
para preguntas generales — se prefirió sobre `Rag::StructuredEvidenceRoute`, que sólo
aplica a queries de mapeo estructurado y no es elegible para estas dos preguntas
descriptivas), sobre páginas NO-ALJO recién parcheadas:

| Pregunta | Página | Cita | `canonical_name` | N8 en `content` citado | N8 en respuesta |
|---|---|---|---|---|---|
| Conectores de la placa EXCELSIOR | 38 (`chunk_36`) | "EXCELSIOR — p. 38" | `EXCELSIOR` | No | No |
| Bloques de bornes EKM66 hidráulico | 45 (`chunk_43`) | "FAIN — p. 45" | `FAIN` | No | No |

El campo `citation[:content]` que devuelve Bedrock (`Bedrock::CitationProcessor`,
`tooltip_excerpt`/`matched_excerpt`) viene directo de lo que el KB tiene indexado en
ese momento, sin fetch adicional a S3 — que ninguna de las dos citas muestre
`ALJO Control Level 1B Altius`/`PIPELINE_INJECTED` es prueba directa de que el índice
ya sirve el contenido reindexado, no sólo que el job reportó `COMPLETE`. Ambas
respuestas son técnicamente sanas: identifican correctamente conectores/terminales y
componentes conectados, citan la página, y señalan honestamente dónde el diagrama no
es legible con precisión (sin inventar valores). Cero preguntas de v1-v4 reutilizadas;
2/4 `retrieve_invocations` del presupuesto de la fase usadas.

**Artefactos:** `tmp/ciclo5_fase3_2026-08-04/n8_fase3_real_run_result_2026-08-04.json`
(resultado de la corrida real), `n8_fase3_smoke_2026-08-04.json` (humo completo con
citas y respuestas), `prod_backup_20260804T144351Z/HASHES.json` (manifest del
backup), SHA256 de los tres en
`tmp/ciclo5_fase3_2026-08-04/SHA256SUMS_fase3_real_run_2026-08-04.txt`. Scripts:
`script/repair_seguridades_n8_body_2026-08-04.rb` (modo real implementado),
`script/n8_fase3_smoke_2026-08-04.rb` (humo, desechable).

## Qué NO está en este plan

- **Caso #1 del gate v4 (evaluador):** falso negativo aceptado por el dueño, NO
  bloqueante. El fixture v4 y su corrida no se tocan (medición ciega intacta); la
  lección vive como regla de rúbrica de la Fase 4.
- **Caso #3 del gate v4 (nomenclatura "ARCA II" vs "ARCA básica"):** deuda P4 de
  identidad de variante, NO bloqueante. Sin fase de fix en este ciclo; ruta de retiro
  documentada en el Anexo C del ciclo 4 (identidad por metadata de chunk, no forma
  léxica).
- **Re-indexación completa con 2 versiones de KB (KB v1 actual / KB v2 corregida):**
  FUERA DE ALCANCE — requiere llamadas de visión/Anthropic y la restricción "sin saldo
  Anthropic desde 2026-08-02" sigue vigente. Sólo el parche de texto determinístico
  (Fase 3) es viable, y es lo que este ciclo ejecuta.
- **Motor de topología visual T1/T2** (`docs/rag/plan_conocimiento_visual.md`): proyecto
  completamente separado, con su propia Fase 7 autorizada el 2026-08-02. Excluido en el
  ciclo 4 y sigue excluido — no es alternativa a nada de este plan.
- **Ningún cambio de `BEDROCK_MODEL_ID` en producción.**
- **Nada que llame a la API de Anthropic desde la aplicación.**
- **P4** (guards por identidad de chunk) y **P2** (hueco 6,
  `SAFETY_CRITICAL_PATTERNS` vs `query_safety_directive`): deudas documentadas en el
  Anexo C del ciclo 4, no se ejecutan aquí.
- **Rediseño de `canonical_name` por sección para compendios multi-marca (H9):** la
  Fase 2 corrige la línea del CUERPO (N8), NO el diseño "ONE FILE = ONE IDENTITY" de la
  metadata (`chunk_merger_service.rb#canonical_name` +
  `batch_results_parser_service.rb#document_identity`) — una ingesta futura de otro
  compendio multi-marca reproduciría el problema y requeriría otro script de reparación
  one-off. Deuda de diseño de ingesta, familia P4 (identidad por sección, ya calculada en
  `section_identity` — el enriquecimiento existe, falta que `canonical_name` lo use en el
  caso multi-marca). No bloqueante: SEGURIDADES ya está reparado y sin saldo Anthropic no
  hay ingestas nuevas posibles este ciclo. **Decisión del dueño #5 (2026-08-04): SÍ se
  arregla, POST-ciclo 5** — se planifica como trabajo propio (ciclo o tarea aparte, con
  su propia hipótesis y verificación) una vez que el gate v5 confirme que los fixes de
  este ciclo son una mejora contundente. Alcance esperado del futuro fix: en ingesta,
  cuando las páginas de un archivo declaren identidades de sección divergentes,
  `canonical_name` del sidecar debe derivar de `section_identity` por chunk en vez de
  copiar la ancla — manteniendo "ONE FILE = ONE IDENTITY" para archivos mono-marca (el
  caso común, que hoy funciona bien). No se diseña más aquí: eso es trabajo del plan
  futuro.
- **Re-medición de T2 (motor de topología visual) post-limpieza de N8 (H10):** T2 se
  degradó permanentemente en el Gate B del plan de conocimiento visual (88.49%, límite
  inferior 84.14% < umbral 85%; tipos A y B empeoraron; se apagaron sus relaciones
  topológicas). El Gate B se corrió sobre chunks contaminados con N8 — la línea
  `**Document:** ALJO Control Level 1B Altius...` en 96/97 páginas inyectaba ~400-500
  tokens de ruido por respuesta y contradecía el contenido visual real en páginas
  multi-marca. **Hipótesis no medida:** la contaminación pudo haber afectado la capacidad
  de T2 de interpretar el contexto visual correctamente, especialmente porque T2 necesita
  el texto del chunk como contexto para identificar componentes y sus relaciones
  (`documented_components` + `edges`). El diseño original de T1+T2 era complementario
  (ambos trabajando juntos con procedencia distinguible: `method: :leader_line` vs
  `method: :vision`), no de reemplazo — el approach sigue siendo correcto para metadata
  enriquecida. **Recomendación post-ciclo 5:** una vez que la Fase 3 de este ciclo limpie
  los 96 cuerpos y resincronice el KB, re-medir T2 con un subset de las mismas páginas
  del Gate B (6-8 páginas representativas) para determinar si la degradación fue
  estructural (diseño de T2) o por datos contaminados. Costo estimado: ~$1-2 de API.
  Decisión del dueño. Si T2 mejora significativamente con chunks limpios, el motor de
  visión vuelve a ser viable para complementar a T1 en lugar de quedar apagado.
- **N9** (alinear el guion de benchmark con `QueryOrchestratorService`): sin mandato.
- **Los fixes del ciclo 4** (page-pin, flag N11, guardrail de presentación, evaluador
  v2): desplegados y funcionando — no se tocan, no se "mejoran".
- **Las preguntas del holdout v5 y de la batería en este documento:** no se listan aquí
  ni en ningún artefacto que lean las sesiones de las Fases 0-3 — sólo existen en los
  fixtures congelados por la Fase 4. Un holdout que las fases de arreglo pueden leer
  deja de ser holdout.
