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

## Fase 3 — Parche de datos N8: 96 cuerpos + resync + re-invalidación (Sonnet 5; ≤4 llamadas Bedrock de humo) — **BLOQUEADA 2026-08-04, escalada como Decisión humana #10**

**Resultado: hipótesis de línea única FALSIFICADA (H10). Cero escrituras a S3, cero
llamadas a Bedrock, cero cambios de embeddings.** Ver Anexo H y
`tmp/ciclo5_fase3_2026-08-04/fase3_resumen_2026-08-04.md` para la evidencia completa.
Resumen: el regex del plan sólo coincide EXACTO con 1/96 cuerpos contaminados; la
contaminación real es un bloque de 1-4 líneas en 11 formas + 2 casos fuera de bloque.
Existe un diseño de reemplazo (detección de bloque + 2 casos especiales,
`script/repair_seguridades_n8_body_2026-08-04.rb`) verificado con cero residuo sobre
los 96 cuerpos, pero su alcance (remueve hasta 4 líneas, no "una única línea") excede
lo que la restricción 2 autorizó explícitamente — no es una decisión que le
corresponda a la sesión que lo descubrió. Ver "Decisión humana #10" (sección
dedicada, tras la tabla de Estado) para las dos opciones de alcance y la
recomendación. **Esta fase permanece pendiente**: H4 sigue vigente en producción,
las Fases 4-6 no pueden proceder (dependen del cierre de Fase 3) hasta que el dueño
resuelva la Decisión humana #10 y una sesión nueva ejecute el parche con el alcance
elegido.

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
| Protocolo de validación (decisión del dueño #3) | **Propuesta B recomendada** (holdout v5 + batería de proveniencia, ~38-45 invocaciones, checks determinísticos dirigidos a los 2 bloqueantes) vs. A (5×14 corridas, ~100 invocaciones, mide varianza pero no apunta a los fixes) — ver tabla comparativa en la Fase 4. **Pendiente de veto del dueño antes de ejecutar la Fase 4**; si elige A, se re-declara el presupuesto y se re-planifica la Fase 4. | — |
| 0 Verificación de vigencia | **hecho 2026-08-04** — los 4 hallazgos (a/H1, b/estado-KB, c/H3, d/H4) VIGENTES sin cambios. Fases 1-3 proceden sin cambios; ningún hallazgo contradice restricción/gate, no se escala decisión #10. Ver tabla completa en el Anexo F. Artefacto `tmp/ciclo5_fase0_verificacion_vigencia_2026-08-04.md`, SHA256 `12541d960cdd5234be301ae003bc03314c655697c573397c05202411bc0c46fb`. | Anexo F |
| 1 Fix bug de caché (invalidación dirigida + estructural) | **hecho 2026-08-04** — Hipótesis CONFIRMADA (Anexo G): el valor leído de `section_neighbor_index/v1/243000f4…086` ANTES de borrar traía `canonical_name: "ALJO Control Level 1B Altius"` en páginas 92 y 93 pese a `section_identity: "THYSSEN"` ya correcto — exactamente el estado predicho. Entrega 1 (invalidación dirigida): `Rails.cache.read` + `Rails.cache.delete` vía `kamal app exec --reuse -r web bin/rails runner` sobre el prefijo real `bulk_chunks/1/b61f5d54-ff42-414a-97b7-01682d16f4b5`; valor viejo completo guardado ANTES de borrar. Entrega 2 (estructural): opción **(i) implementada** — `Rag::SectionNeighborExpander.invalidate!(prefix)` (método de clase; `index_cache_key` de instancia delega en el de clase, una sola fuente de verdad para la derivación); opción **(ii) aplicada en adición** — `INDEX_CACHE_TTL` 30d→7d; opción (iii) descartada (sin fingerprint gratis, tal como preanalizó el plan). El script de reparación de canonical_name (H2) invoca `invalidate!(CHUNK_PREFIX)` tras su resync — patrón de referencia para Fase 3. 5 tests Minitest nuevos + suite completa verde (2265 runs, 8068 assertions, 0 failures/errors, sin regresión sobre los 2260 previos). Commit `c05718a` ANTES de `kamal deploy`; `kamal app version` confirmó SHA desplegado `c05718a2` == HEAD. Verificación en vivo: 2 preguntas ad-hoc NUEVAS sobre la página 92 THYSSEN (LED L8 → SERIE PUERTAS EXTERIORES; borne 72 → AFLOJACABLES; hechos distintos de v3/v4) — **ambas citan "THYSSEN — p. 93" con `canonical_name: "THYSSEN"`**, no ALJO. 2 `retrieve_invocations` usados de ≤4 presupuestados. Ningún hallazgo contradice una restricción ni el gate: no se escala decisión #10. | `tmp/ciclo5_fase1_2026-08-04/cache_invalidation_seguridades_2026-08-04.json` SHA256 `b500fd9be75d276040dbec057a91b672e0d845bfd5eb8e17cbee5264b9056ded`; `tmp/ciclo5_fase1_2026-08-04/live_probe_1_thyssen_p92_led_l8_2026-08-04.json` SHA256 `a8264113e6b2fabc30bcd9c3238e0a3d63180ff04c6c3a465c1e841168221cf7`; `tmp/ciclo5_fase1_2026-08-04/live_probe_2_thyssen_p92_borne72_2026-08-04.json` SHA256 `1086d46103af51d48eb4ab40ab4c7f948bd608b072697c096497fbf2168af35a`; commit `c05718a26317361069315c4900e2cdf2e24d98cf`; ver Anexo G |
| 2 Fix prompt N8 | **hecho (código) 2026-08-04 — N8 SIGUE VIGENTE EN PRODUCCIÓN, NO confundir con "N8 resuelto".** En `app/prompts/batch_chunking_prompt.rb`: eliminada la regla "Each section title must appear inside the chunk after the `**Document:**` header" (línea 293 original) y las filas `ORIGINAL_FILE_NAME \| PIPELINE_INJECTED` / `NORMALIZED_FILE_NAME \| PIPELINE_INJECTED` de la tabla `## S0 chunk content` (líneas 309-310 originales) — son los dos campos que el modelo textualizaba junto al hint del `document_name` para producir la línea contaminante. Comentario de cabecera (líneas 13-16) corregido de descriptivo-y-falso ("does NOT need to embed") a imperativo-y-verificable ("MUST NOT instruct the model to embed"), apuntando a la sección que lo cumple. NO se tocó: `document_name`/`document_name_hint` (ONE FILE = ONE IDENTITY intacto), `# IDENTITY INJECTION` (regla defensiva de PIPELINE_INJECTED, ahora inerte pero no dañina — no toca ninguna instrucción activa), `SingleFileChunkingService`, `BatchResultsParserService#identity_header`, `citation_processor.rb` (su filtro defensivo sigue siendo necesario hasta que la Fase 3 cierre). Ningún test preexistente asertaba la línea vieja (verificado por grep dirigido antes de correr la suite) — no hizo falta ajustar tests. Cero llamadas a cualquier API; cero cambios en S3/Bedrock/datos vivos. Suite completa: **2269 runs, 8076 assertions, 0 failures, 0 errors, 189 skips** (2265→2269 runs y 8068→8076 assertions frente al baseline de cierre de la Fase 1 — diferencia atribuible a la carga habitual de la suite completa, no a tests nuevos de esta fase; ningún test se agregó ni se modificó). `prompt_fingerprint_sha256` nuevo: `e5b574784ff78547886919fe388edd51decbc13b0a37cfbd11bc041ff4ac1172`. **Efecto real: sólo previene que una ingesta NUEVA reproduzca N8. Los 96/97 cuerpos ya contaminados en S3/Bedrock no cambiaron una sola línea — el técnico sigue viendo `**Document:** ALJO Control Level 1B Altius \| Page N \| …` en producción HOY. H4 sigue vigente hasta que la Fase 3 (obligatoria, bloqueante para piloto) cierre.** Ningún hallazgo contradice una restricción ni el gate: no se escala decisión #10. Fase 3 no necesita ajuste de su prompt: no depende de números de línea de este archivo, sólo del patrón regex sobre los cuerpos vivos en S3 (H4), que este cambio no toca. | `tmp/ciclo5_fase2_2026-08-04/prompt_diff_n8_fix_2026-08-04.diff`, `tmp/ciclo5_fase2_2026-08-04/fase2_resumen_2026-08-04.md`, `tmp/ciclo5_fase2_2026-08-04/full_suite_run_2026-08-04.log`, SHA256 en `tmp/ciclo5_fase2_2026-08-04/SHA256SUMS.txt` |
| 3 Parche de datos N8 + resync + re-invalidación | **BLOQUEADA 2026-08-04 — hipótesis de línea única FALSIFICADA (H10); escalada como Decisión humana #10 (pendiente).** Sólo 1/96 cuerpos contaminados coincide con el regex exacto del plan; la contaminación real es un bloque de 1-4 líneas en 11 formas + 2 casos fuera de bloque (`chunk_0`, `chunk_36`). Diseño de reemplazo verificado con cero residuo (`script/repair_seguridades_n8_body_2026-08-04.rb`, modo diagnóstico) pero su alcance excede lo autorizado por la restricción 2 sin revisión del dueño. Cero escrituras a S3/Bedrock; cero cambios de embeddings; presupuesto de la fase (≤4 llamadas) intacto. Ver Anexo H. | `tmp/ciclo5_fase3_2026-08-04/n8_fase3_diagnostic_2026-08-04.json`, `n8_removal_safety_check_2026-08-04.json`, `n8_block_diagnostic_2026-08-04.json`, `n8_full_catalog_first9lines_2026-08-04.txt`, `fase3_resumen_2026-08-04.md`, SHA256 en `tmp/ciclo5_fase3_2026-08-04/SHA256SUMS.txt` |
| 4 Holdout v5 + batería congelados | **bloqueada por dependencia** — no puede redactarse "desde los 97 cuerpos POST-parche" (nota de secuencia de la Fase 4) hasta que la Fase 3 cierre; ver Decisión humana #10 | — |
| 5 Checkpoint despliegue | **bloqueada por dependencia** — requiere Fases 1-3 commiteadas y el resync de la Fase 3 `COMPLETE`; Fase 3 no cerró | — |
| 6 Gate v5 → piloto | **bloqueada por dependencia** — requiere Fase 3 cerrada (job id nuevo, N8 limpio) | — |

## Decisión humana #10 — alcance del parche N8, pendiente

**Contexto:** H10 y el Estado de la Fase 3 (arriba). El regex de línea única que la
restricción 2 autorizó como el parche N8 ("sustitución de texto... la línea
contaminante ES exactamente esa única línea") sólo describe 1 de los 96 cuerpos
reales. Cerrar H4 de verdad requiere remover un bloque de 1-4 líneas por chunk (11
formas distintas) más 2 casos fuera de bloque — un alcance más amplio, que el dueño
no revisó en esta forma. **No se ejecuta nada contra producción hasta que esta
decisión se resuelva.**

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

**Pendiente del dueño:** elegir Alcance A o B (o pedir una tercera opción). Una vez
resuelto, una sesión nueva ejecuta `script/repair_seguridades_n8_body_2026-08-04.rb`
en modo real (implementar el `if`/flag de alcance elegido, backup completo + SHA256,
verificación de ETag contra S3 vivo antes de escribir, resync, invalidación de
caché automática vía `S3DocumentsService#upload_text` — mecanismo de la Fase 1 —,
humo ≤4 llamadas) siguiendo exactamente el patrón de seguridad de
`script/repair_seguridades_canonical_identity_and_acunaiento_2026-08-03.rb`.

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

### Fase 3 — Sonnet 5

> ⚠️ CRÍTICO — reescrito 2026-08-04 tras la sesión que ejecutó esta fase y encontró
> su hipótesis de línea única FALSIFICADA (H10, Anexo H). **NO uses el regex del
> borrador original de este prompt** (`\*\*Document:\*\* ALJO Control Level 1B Altius
> \| Page \d+ \| ORIGINAL_FILE_NAME: PIPELINE_INJECTED.*`) como criterio de
> contaminación — sólo coincide con 1/96 cuerpos. `script/repair_seguridades_n8_body_2026-08-04.rb`
> ya existe, en modo SOLO DIAGNÓSTICO: detecta el bloque real de identidad (línea
> `**Document:**` + continuaciones `**Section:**`/`**Page:**`/`ORIGINAL_FILE_NAME:`/
> `NORMALIZED_FILE_NAME:`/`SOURCE_URI:`) más 2 casos especiales (`chunk_0`: filas de
> tabla en `## S0 chunk content`; `chunk_36`: línea suelta en prosa, línea 75) y
> verifica CERO residuo sobre los 96 cuerpos contaminados
> (`tmp/ciclo5_fase3_2026-08-04/n8_fase3_diagnostic_2026-08-04.json`).
>
> **Antes de tocar nada:** confirma en la tabla de Estado que la "Decisión humana
> #10" (sección dedicada, tras la tabla de Estado) está RESUELTA — el dueño eligió
> Alcance A (bloque completo, recomendado) o Alcance B (preservar
> `**Section:**`/`**Page:**` sueltas). Si sigue pendiente: NO ejecutes nada, escala
> de nuevo y detente — no es una decisión de esta sesión.
>
> Una vez resuelta: implementa el modo real en el mismo script (gatea con
> `RAG_CHUNK_PATCH_CONFIRM=1` + una constante `SCOPE = :full_block` o `:preserve_section_page`
> según lo elegido, mismo patrón de flag explícito que
> `script/repair_seguridades_canonical_identity_and_acunaiento_2026-08-03.rb`). Antes
> de escribir: (1) re-verifica ETag de los 97 objetos vivos en S3 contra la copia de
> referencia local — aborta si algo cambió desde el 2026-08-04; (2) backup completo de
> los 97 cuerpos vivos a tmp local + SHA256 por archivo + del tarball; (3) para cada uno
> de los 96 cuerpos contaminados, recomputa el bloque/casos especiales SOBRE EL BYTE
> vivo descargado (no sólo sobre la referencia local) y aborta si el resultado no
> queda con cero residuo de `ALJO Control Level 1B Altius`/`PIPELINE_INJECTED`; (4)
> sube cada `.txt` a su CLAVE ORIGINAL vía `S3DocumentsService#upload_text` (nunca
> `Aws::S3::Client` crudo — así la invalidación de caché de la Fase 1 dispara sola,
> H8); (5) verifica post-escritura (hash del objeto recién subido == hash esperado);
> (6) dispara el resync (`BulkKbSyncService#sync!` / `start-ingestion-job`), espera
> `COMPLETE`, anota el job id NUEVO — reemplaza a `ZGCU99ISK5` — y actualiza los
> prompts de las Fases 5 y 6 en este Anexo. Humo: 1-2 preguntas ad-hoc NUEVAS (≤4
> llamadas): los chunks recuperados ya NO contienen ningún bloque `**Document:**
> ALJO...` en páginas no-ALJO y la respuesta sigue sana. Artefactos + SHA256. Nota:
> este parche cambia los embeddings de 96 chunks — por diseño va ANTES del holdout
> v5; nada de v1-v4 se reabre.

### Fase 4 — Sonnet 5 (sesión NUEVA; si participaste en las Fases 1-3, detente: lo redacta otra sesión)

> Antes de empezar: confirma en la tabla de Estado que el dueño NO vetó la propuesta B
> del protocolo de validación (fila "Protocolo de validación"); si eligió A, detente y
> escala — esta fase se re-planifica. Redacta y congela DOS fixtures sin correrlos:
> (a) `script/fixtures/rag_seguridades_holdout_v5.json` — 14 preguntas nuevas,
> distribución del v4 (3 determinísticas / 2 mapeos / 2 generalización / 1 ambigua / 1
> sin respaldo / 4 seguridad / 1 comparativa), desde la verdad-terreno pagada (Gate A
> §5-§9 + los 97 cuerpos POST-parche — confirma en la fila de Estado de la Fase 3 que el
> parche cerró), sin reutilizar NINGUNA pregunta de v1-v4 (verificación por script,
> intersección vacía). Reglas heredadas del v4 completas: `severity: safety_critical` a
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

> [⚠️ La Fase 3 actualiza este prompt con el ingestion job nuevo.] Checkpoint previo al
> gate: Fases 1-3 commiteadas con suite verde ANTES de tocar nada. `kamal deploy`;
> verifica SHA desplegado == HEAD con `kamal app version`. Confirma que el ingestion job
> vigente es el que anotó la Fase 3 (ya no `ZGCU99ISK5`) y sigue `COMPLETE`. Humo: 1
> llamada, `-r web` SIEMPRE (sin `--role` corre en web+worker y duplica el gasto),
> pregunta nueva fuera de todo holdout que fuerce expansión de vecindad — la cita debe
> traer el fabricante correcto Y el cuerpo recuperado sin línea N8 (ejercita los DOS
> fixes en una llamada). Aurora caliente (`kb_retrieve` < 1s, sin cold-start). Anota en
> Estado: SHA, timestamp, evidencia del humo (tmp local + SHA256). NO abras los fixtures
> de la Fase 4: eso es la Fase 6.

### Fase 6 — Sonnet 5 (NO Haiku)

> [⚠️ La Fase 3 actualiza la referencia del ingestion job; la Fase 5 anota el SHA que
> debes verificar.] Criterio congelado ANTES de abrir, AND estricto, sin ajustes tras ver
> resultados: (1) holdout v5 ≥80% de la suma real; (2) cero `passed: false` en los 4
> `safety_critical`; (3) `source_page_cited` verde en esos 4; (4) batería de
> proveniencia: CERO citas cuyo título/`canonical_name` contradiga la `section_identity`
> de la página citada Y CERO apariciones de la línea N8 en los cuerpos recuperados.
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
