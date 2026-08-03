# Plan de precisión definitiva RAG — Ciclo 3 (2026-08-03)

**Objetivo:** superar el gate de salida a piloto con la seguridad primero. La app da
soporte a mantenimiento de ascensores: un error sobre bypass de seguridades es
intolerable. Este ciclo invierte el orden — primero se diagnostica y repara el fallo
`safety_critical` del v2, después se congela un holdout v3 más exigente en seguridad.

**Entrada obligatoria:** `docs/rag/plan_quirurgico_precision_2026-08-02.md` (ciclos 1-2,
restricciones, método §8.3) y `docs/rag/holdout_v1_resultado_2026-08-03.md`.

**Línea base:** holdout v2 = 70/88 pero `holdout_v2_arca3_bypass_j25_seguridad`
(safety_critical) falló 2/9 → gate NO superado. v1 y v2 están **gastados**: prohibido
reabrirlos, ni con `RAG_SEGURIDADES_CASE_IDS`.

**Decisiones del dueño del producto (2026-08-03) incorporadas:**
1. **#6:** ciclo 3 autorizado, estrategia seguridad-primero. Es el ÚLTIMO ciclo con esta
   estrategia: si el v3 falla, se para y la siguiente decisión humana elige entre
   guardrails operacionales u otro enfoque.
2. **#5:** reparar sólo `ACUÑAIENTO` (chunk 94, perfil limpio idéntico a OSBTACULO).
   Las 4 familias mixtas (CERRRADA, EXTERORES, REVISON, SEGURDAD/SEGURIIDAD) quedan
   documentadas sin tocar — al menos 2 son erratas del original preservadas a propósito.
3. Holdout v3: **14 preguntas, 4 de seguridad**, cubriendo todas las intenciones de
   pregunta del código (incluye stop-work, prueba funcional y comparativa, nunca
   cubiertas por un holdout).
4. **Checkpoint de despliegue obligatorio** antes de todo gate (Fase 4): nunca se abre
   un holdout con cambios sin desplegar.

## Restricciones no negociables (heredadas, sin cambios)

1. Nada de regex nuevo en la aplicación para maquillar respuestas.
2. Cero re-ingesta / re-troceo. Sólo pases de metadatos que *añaden o corrigen*
   información en sidecars existentes, nunca que la quitan.
3. **Sin saldo en la API de Anthropic de la app** (desde 2026-08-02): ningún paso la
   llama — fallaría en silencio con resultados vacíos y $0. El benchmark va por AWS
   Bedrock (`global.anthropic.claude-haiku-4-5`), facturación AWS aparte.
4. Presupuesto agotado: cada fase declara su costo antes de ejecutarse. Presupuesto
   Bedrock del ciclo: **< 30 llamadas dirigidas en total** (≤10 Fase 1, ≤6 Fase 2,
   14 Fase 5). Si un arreglo pide más, no es quirúrgico: parar y reportar.
5. Riesgo operativo nuevo (N5): la cuenta de tooling de IA ha mostrado límites de uso.
   Sesiones cortas, un objetivo por sesión; si un modelo no responde por límite,
   degradar la sesión a Haiku 4.5 y anotarlo en Estado.

## Hallazgos de arranque (sesión de planificación 2026-08-03)

| # | Hallazgo | Evidencia |
|---|---|---|
| N1 | El hecho J25 SÍ está en el KB: chunk_63 (pág. 65) tiene la tabla limpia J12/J24/J25/J26 con estados correctos y `SEARCH_ALIASES: ARCA III BYPASS, …` | copia local `tmp/seguridades_chunks_2026-07-28/chunk_63.txt:14-19` |
| N2 | El sidecar del chunk_63 está contaminado: `canonical_name: "ALJO Control Level 1B Altius"` + 15 aliases todos ALJO, cero ARCA/Orona (bug de enriquecimiento anotado en 0c del plan anterior). La pregunta del gate empieza "En ARCA III…" y la instrucción de *fidelidad al chunk propio del modelo nombrado* añadida al prompt en Fase 3 del ciclo 2 pudo inducir al modelo a descartar el chunk correcto. **Hipótesis principal H-A.** | `tmp/seguridades_chunks_2026-07-28/chunk_63.txt.metadata.json` |
| N3 | El artefacto del gate v2 está incompleto: 12 KB, sólo `evaluation`, sin `results[]` (chunks/respuestas) — imposible clasificar R vs G desde él. El del v1 pesa ~1 MB. | `tmp/rag_seguridades_holdout_v2_run1_2026-08-03.json` |
| N4 | El evaluador NO reconoce `safety_critical` como severity de patrón: `PENALTY_WEIGHTS` = critical 5 / technical_important 3 / secondary 1 / excess 0.5; un patrón `safety_critical` pesa 1 (default). Los patrones `penalized` del v3 deben usar `critical`. | `app/services/rag/benchmark_rubric_evaluator.rb:8-13` |
| N5 | Límite de uso en la cuenta de tooling de IA observado durante la planificación (un subagente murió con "usage limits … 2026-09-01"). | sesión de planificación |

## Asignación de modelo por fase (costo mínimo)

| Fase | Modelo de sesión | Racional |
|---|---|---|
| 1 Diagnóstico J25 | Sonnet 5 ($2/$10 intro hasta 2026-08-31) | Análisis causal fino |
| 2 Intervención mínima | Sonnet 5 | Metadatos + posible prompt + tests |
| 3 Holdout v3 | Sonnet 5 — sesión NUEVA que no tocó la Fase 2 | La redacción de rúbrica exige el rigor que falló en el v1 |
| 4 Checkpoint despliegue | Haiku 4.5 ($1/$5) | Mecánico |
| 5 Gate v3 | Haiku 4.5 | Mecánico: correr script, verificar artefacto |

Opus 5 sólo para consultas acotadas si un hallazgo es ambiguo — nunca sesión completa.
Nunca Fable. El juez del benchmark sigue siendo regex determinístico
(`app/services/rag/benchmark_rubric_evaluator.rb`), $0.

## Fase 1 — Diagnóstico dirigido del fallo safety_critical (Sonnet 5)

**Costo:** ≤ 10 llamadas Bedrock (centavos) + sesión corta.

1. Declarar hipótesis por escrito (§8.3 del diagnóstico):
   - **H-A (principal):** contaminación `canonical_name`/`aliases` del chunk_63 (N2) ×
     instrucción de fidelidad al modelo nombrado → el modelo descarta o nunca prioriza
     el chunk correcto.
   - **H-B:** la pregunta cayó en una ruta equivocada (estructurada/guard/ambigüedad).
   - **H-C:** recuperación pura (chunk_63 no entra al top-k).
2. Correr 2–3 preguntas ad-hoc **NUEVAS** sobre pág. 65 (variantes J24/J26, jamás la
   pregunta literal del v2) **localmente contra el KB de producción** (sobreescribir
   variables de KB en la línea de comandos, patrón de la Fase 3 del ciclo 2), guardando
   **artefacto completo** (chunks + respuesta cruda + `generation_mode`/ruta). Verificar:
   ¿chunk_63 fue recuperado? ¿qué ruta disparó? ¿la respuesta lo usa o lo descarta?
3. Dimensionar la contaminación: comparar `canonical_name`/`aliases` de los 97 sidecars
   (copia local + `aws s3 sync` de los vigentes, sólo lectura) contra la verdad-terreno
   de las 18 páginas divisoras (`docs/rag/gate_a_medicion_topologia.md` §5) — listar
   todos los chunks cuya identidad de equipo no corresponde a su página.
4. **Salida:** tabla hipótesis × evidencia × veredicto en este documento. Caso ambiguo →
   una consulta acotada a Opus 5, no una re-corrida. **No se arregla nada en esta fase.**

## Fase 2 — Intervención mínima según diagnóstico (Sonnet 5)

**Costo:** $0 en Claude (pases de metadatos) + ≤ 6 llamadas Bedrock de verificación.

- **2a. Limpiar la contaminación de identidad** (si H-A confirmada o el grep de Fase 1
  lista chunks provablemente mal etiquetados): corregir `canonical_name` y `aliases` de
  los sidecars afectados desde la verdad-terreno de §5 — pase de metadatos patrón
  `section_identity` (permitido por restricción #2) + **UN solo resync** del KB
  (`BulkKbSyncService`). ⚠️ El resync también publica el backfill `section_identity`
  que quedó pendiente a propósito (Fase 2 SEGURIDADES v2): verificar antes que ese
  contenido es correcto para publicar y anotarlo aquí.
- **2b. Ajuste del prompt SÓLO si** la Fase 1 muestra que la regla de fidelidad al
  modelo nombrado descarta chunks por cabecera contaminada: precisar la regla en
  `app/prompts/bedrock/generation.txt` (la identidad de equipo se juzga por
  aliases/section_identity del chunk, no sólo por la línea `**Document:**`), dentro de
  lo permitido por §5 (antes de `$output_format_instructions$`), con
  `test/prompts/bedrock_generation_prompt_test.rb` actualizado (SHA256 del template).
- **2c. Reparar `ACUÑAIENTO`** (decisión #5): chunk_94, patrón exacto de
  `script/patch_seguridades_field_record_osbtaculo_2026-08-03.rb` (verificación ETag +
  backup S3/local + SHA256 post-escritura), dentro del mismo resync de 2a.
- **Verificación:** re-correr las MISMAS preguntas ad-hoc de la Fase 1 (before/after,
  lectura de la respuesta cruda — las rúbricas ad-hoc no se congelan ni se reusan) +
  tests unitarios. Cada intervención declara hipótesis y resultado esperado si es falsa
  (§8.3).

## Fase 3 — Congelar holdout v3 (Sonnet 5, sesión que NO tocó la Fase 2)

`script/fixtures/rag_seguridades_holdout_v3.json` — **14 preguntas**, formato del v2
(`stratum`, `category`, `severity`, `question`, `source_pages`, `required`/`optional`/
`penalized`, `citation_required` global). Redactadas desde la verdad-terreno pagada
(Gate A §5-§9 + extracción del PDF), sin reutilizar ninguna pregunta del v1/v2; página
repetida sólo si el hecho evaluado es distinto.

| Estrato | # | Notas |
|---|---|---|
| Determinísticas | 3 | dato exacto (tablas LED, §6 de Gate A) |
| Mapeos estructurados | 2 | tabla/etiqueta → identificador |
| Generalización | 2 | síntesis multi-chunk |
| Ambigua | 1 | debe desambiguar o preguntar bien |
| Sin respaldo | 1 | debe declararlo, no inventar |
| **Seguridad** | **4** | 1 bypass/puentes (pág. 65 permitida sólo con hecho DISTINTO al J25 del v2 — p.ej. J24 o J26); 1 checklist detener-trabajo (intención `stop_work_checklist_query?`); 1 prueba funcional con resultado esperado (`exhaustive_functional_test_query?`); 1 límites+fuentes ("¿es seguro anular X?") |
| Comparativa | 1 | `COMPARATIVE_PATTERN` de `RagRetrievalProfile` — intención nunca cubierta |

**Reglas de QA (lecciones v1 + v2 + N4):**
1. Los 4 casos de seguridad: `severity: safety_critical` **a nivel de caso** (criterio
   del gate) y patrones `penalized` con `severity: critical` (peso real 5 — N4).
2. Test unitario obligatorio estilo
   `test/services/rag/benchmark_rubric_evaluator_holdout_v2_qa_test.rb`: distribución
   exacta por `tally`; suma real recalculada con la fórmula del evaluador
   (`required×2 + optional + citación 2` — `max_score`/`passing_score` del JSON son
   documentales); cobertura de ids; y por caso, una respuesta correcta conocida contra
   `Rag::BenchmarkRubricEvaluator` real ($0): todos los required matchean, ningún
   penalized matchea, `citation_passed`, `passed`.
3. Prohibido: ventanas `.{0,N}` que crucen ítems de lista (usar el estilo
   `(?:(?!\bX\b).){0,40}`); lookaheads de negación que no cubran el "no" pospuesto;
   `required` con la forma corregida cuando el documento imprime una errata (usar los
   verbatims de Gate A §9: `CERRRADA`, `EXTERORES`, etc.).
4. `passing_score` documental = ceil(80% de la suma real); anotar ambos aquí al congelar.
5. **No se corre contra Bedrock**: se abre una sola vez en la Fase 5.

## Fase 4 — Checkpoint de despliegue (Haiku 4.5) — cuándo desplegar

**Momento exacto:** después de que la Fase 2 esté commiteada con tests verdes y el
resync del KB esté `COMPLETE`, y **ANTES** de abrir el holdout v3. Regla permanente:
nunca se abre un holdout con cambios sin desplegar.

1. `kamal deploy` (o confirmar que el contenedor ya sirve el commit).
2. Verificar que el SHA desplegado incluye el último commit que tocó `app/prompts/`,
   `app/services/rag/` o `config/`.
3. Verificar KB: job de sync `COMPLETE`; 1 `retrieve` de humo confirmando que un chunk
   reparado sirve contenido nuevo (p.ej. aliases ARCA en chunk_63). La pregunta de humo
   no puede ser de ningún holdout.
4. Aurora caliente: latencias `kb_retrieve` < 1s, sin `AuroraColdStartRetry` en el log.
5. Anotar en Estado: SHA desplegado, id del job de sync, timestamp.

## Fase 5 — Gate v3, UNA corrida (Haiku 4.5)

1. **Criterio congelado antes de abrir:** ≥ 80% de la suma real **Y** cero fallos
   (`passed: false`) en los 4 casos `safety_critical`.
2. Patrón Kamal exacto del v1/v2: `kamal app exec --reuse`, variables de KB de
   producción (`config/deploy.yml`, no el `.env` local), `RAG_SEGURIDADES_RUBRIC` →
   fixture v3, `RAG_SEGURIDADES_OUTPUT` → `tmp/`.
3. Verificar ANTES que la Fase 4 anotó SHA y sync; si no, detenerse — no se abre.
4. **Artefacto completo obligatorio (lección N3):** antes de cerrar la sesión, verificar
   que el JSON contiene `results[]` con `chunks` y `answer`/`raw_answer` no vacíos por
   caso (~1 MB de referencia; 12 KB = corrida inválida para diagnóstico). Copiarlo del
   contenedor antes de que muera si hace falta. La corrida NO se repite. Hash SHA256
   anotado en Estado.
5. **Pasa** → liberar a piloto (0c ya resuelto en el ciclo 2).
   **No pasa** → clasificar los fallos (método Fase 2 del plan anterior — ahora posible
   porque el artefacto es completo), el v3 queda gastado, y **PARAR**: no hay ciclo 4
   con esta estrategia; se escala como decisión humana (guardrails operacionales u otro
   enfoque).

## Protocolo de plan vivo v2 (cláusula reforzada por el dueño, 2026-08-03)

Toda sesión que ejecuta una fase, ANTES de cerrar y en el MISMO commit:
1. Actualiza su fila de la tabla de Estado (hecho/bloqueado + artefacto/hash).
2. Corrige las fases posteriores afectadas por sus hallazgos (con fecha y evidencia).
3. **Actualiza el prompt de la fase siguiente en el Anexo A** con lo que el siguiente
   modelo necesita saber; si el hallazgo es crítico para su implementación, lo marca con
   `⚠️ CRÍTICO:` al inicio del prompt.
4. Actualiza la memoria persistente del proyecto (entrada del ciclo 3) con el estado
   real, para que la siguiente sesión no arranque con el plan desactualizado.
5. `git commit` de TODO (código + este documento + fixtures/tests). Nada queda sin
   commitear al cerrar.
6. Si un hallazgo contradice una restricción no negociable o el criterio del gate: no se
   ejecuta — se documenta y se escala como decisión humana numerada (siguiente: #7).

## Presupuesto del ciclo 3

| Concepto | Estimado |
|---|---|
| Bedrock (Fases 1+2+5): ≤10 + ≤6 + 14 llamadas `retrieve_and_generate` Haiku | **< $2** |
| Sesiones de IA: 3× Sonnet 5 cortas + 2× Haiku 4.5 | mínimo; sin Opus/Fable |
| API de Anthropic desde la app | **$0** (ninguna llamada) |

## Estado

| Fase | Estado | Artefacto / hash |
|---|---|---|
| 1 Diagnóstico J25 | pendiente | — |
| 2 Intervención mínima | pendiente (depende de Fase 1) | — |
| 3 Holdout v3 congelado | pendiente (sesión distinta a Fase 2) | — |
| 4 Checkpoint despliegue | pendiente (tras Fase 2, antes de Fase 5) | — |
| 5 Gate v3 → piloto | pendiente | — |

## Anexo A — Prompt de arranque por fase

**Pie común (añadir al final de cada prompt):**

> Lee primero `docs/rag/plan_precision_definitiva_2026-08-03.md` completo (incluida la
> tabla de Estado y los hallazgos N1–N5) y la fila de Estado de la fase anterior.
> Respeta las restricciones no negociables y la advertencia de saldo (nada llama a la
> API de Anthropic desde la app). Los holdouts v1 y v2 están gastados: no los reabras
> ni con `RAG_SEGURIDADES_CASE_IDS`. Antes de cerrar aplica el Protocolo de plan vivo
> v2: actualiza tu fila de Estado, corrige las fases posteriores afectadas, actualiza
> el prompt de la fase siguiente en este Anexo (márcalo `⚠️ CRÍTICO:` si cambia su
> implementación), actualiza la memoria del proyecto, y commitea todo en el mismo
> commit.

### Fase 1 — Sonnet 5

> Diagnostica el fallo safety_critical del gate v2
> (`holdout_v2_arca3_bypass_j25_seguridad`, 2/9). Hipótesis principal H-A: el sidecar
> del chunk_63 (pág. 65, ARCA III BYPASS) tiene `canonical_name: "ALJO Control Level 1B
> Altius"` y aliases 100% ALJO (bug de enriquecimiento, 0c del plan anterior), y la
> instrucción de fidelidad al modelo nombrado de `app/prompts/bedrock/generation.txt`
> pudo hacer que el modelo descartara el chunk correcto. H-B: ruta equivocada
> (estructurada/guard). H-C: recuperación pura. Método: 2–3 preguntas ad-hoc NUEVAS
> sobre pág. 65 (variantes J24/J26, jamás la pregunta literal del v2) corridas
> localmente contra el KB de producción con artefacto COMPLETO (chunks + respuesta
> cruda + generation_mode); verifica si chunk_63 entra al top-k y si la respuesta lo
> usa o lo descarta. Después dimensiona la contaminación: compara
> `canonical_name`/`aliases` de los 97 sidecars contra la verdad-terreno de páginas
> divisoras (`docs/rag/gate_a_medicion_topologia.md` §5) y lista los chunks mal
> etiquetados. Salida: tabla hipótesis × evidencia × veredicto en el plan vivo.
> ≤ 10 llamadas Bedrock. NO arregles nada en esta fase.

### Fase 2 — Sonnet 5

> Ejecuta la intervención mínima que el diagnóstico de la Fase 1 justifique (lee su
> veredicto en el plan vivo): (2a) si H-A está confirmada o hay chunks provablemente
> mal etiquetados, corrige `canonical_name`/`aliases` de los sidecars afectados desde
> la verdad-terreno de §5, patrón `section_identity`, y UN solo resync del KB
> (`BulkKbSyncService`) — ⚠️ ese resync también publica el backfill `section_identity`
> pendiente a propósito: verifica antes que sea correcto publicarlo y anótalo; (2b)
> SÓLO si la Fase 1 muestra que la regla de fidelidad al modelo nombrado descarta
> chunks por cabecera contaminada, precisa esa regla en
> `app/prompts/bedrock/generation.txt` (identidad por aliases/section_identity, no
> sólo por la línea `**Document:**`), dentro de §5, actualizando
> `test/prompts/bedrock_generation_prompt_test.rb` (SHA256); (2c) repara `ACUÑAIENTO`
> en chunk_94 con el patrón exacto de
> `script/patch_seguridades_field_record_osbtaculo_2026-08-03.rb` (ETag + backup +
> SHA256 post-escritura), dentro del mismo resync de 2a. Verifica con las MISMAS
> preguntas ad-hoc de la Fase 1 (before/after, lectura de respuesta cruda) + tests
> unitarios. Declara hipótesis y resultado esperado si es falsa (§8.3) por cada
> intervención. ≤ 6 llamadas Bedrock.

### Fase 3 — Sonnet 5 (sesión nueva; si participaste en la Fase 2, detente: lo redacta otra sesión)

> Redacta y congela `script/fixtures/rag_seguridades_holdout_v3.json`: 14 preguntas
> desde la verdad-terreno pagada (Gate A §5-§9 + extracción del PDF), distribución: 3
> determinísticas / 2 mapeos estructurados / 2 generalización / 1 ambigua / 1 sin
> respaldo / 4 seguridad (1 bypass-puentes con hecho DISTINTO al J25 del v2, p.ej. J24
> o J26; 1 checklist detener-trabajo; 1 prueba funcional con resultado esperado; 1
> límites+fuentes "¿es seguro anular X?") / 1 comparativa. Formato del v2
> (stratum/category/severity/source_pages/required/optional/penalized). Los 4 casos de
> seguridad llevan `severity: safety_critical` a nivel de caso y sus patrones
> `penalized` llevan `severity: critical` — el evaluador NO reconoce `safety_critical`
> como peso de patrón (hallazgo N4, `benchmark_rubric_evaluator.rb:8-13`). QA
> obligatorio: test unitario estilo
> `benchmark_rubric_evaluator_holdout_v2_qa_test.rb` (distribución por tally, suma
> real con la fórmula del evaluador, cobertura de ids, respuesta correcta conocida por
> caso contra `Rag::BenchmarkRubricEvaluator` real). Prohibido: ventanas `.{0,N}` que
> crucen ítems de lista; lookaheads que no cubran el "no" pospuesto; required con
> forma corregida donde el documento imprime errata (usa los verbatims de §9);
> reutilizar preguntas del v1/v2. `passing_score` documental = ceil(80% de la suma
> real); anota ambos valores en el plan vivo. NO lo corras contra Bedrock: se abre una
> sola vez en la Fase 5.

### Fase 4 — Haiku 4.5

> Checkpoint de despliegue previo al gate: confirma que la Fase 2 está commiteada con
> tests verdes y el resync del KB `COMPLETE`. Haz `kamal deploy` (o verifica que el
> contenedor ya sirve el commit): el SHA desplegado debe incluir el último commit que
> tocó `app/prompts/`, `app/services/rag/` o `config/`. Humo: 1 `retrieve` confirmando
> que un chunk reparado sirve el contenido nuevo (p.ej. aliases ARCA en chunk_63) — la
> pregunta de humo no puede ser de ningún holdout. Aurora caliente (`kb_retrieve` <
> 1s, sin `AuroraColdStartRetry`). Anota en la tabla de Estado: SHA desplegado, id del
> job de sync, timestamp. NO abras el holdout v3: eso es la Fase 5.

### Fase 5 — Haiku 4.5

> Corre el holdout v3 UNA sola vez contra el KB de producción con el patrón Kamal del
> v1/v2 (`kamal app exec --reuse`, variables de producción, `RAG_SEGURIDADES_RUBRIC`
> al fixture v3, `RAG_SEGURIDADES_OUTPUT` a tmp/). Verifica ANTES que la Fase 4 anotó
> SHA desplegado y sync COMPLETE (si no, detente: no se abre un holdout con cambios
> sin desplegar). Criterio congelado: ≥ 80% de la suma real Y cero fallos en los 4
> casos safety_critical. ANTES de cerrar: verifica que el artefacto contiene
> `results[]` con `chunks` y respuestas no vacíos por caso (el del v2 salió sin ellos
> y bloqueó el diagnóstico — 12 KB vs ~1 MB del v1); cópialo del contenedor si hace
> falta y anota su SHA256. Pasa → preparar piloto. No pasa → clasifica los fallos
> (ahora sí posible con artefacto completo), el v3 queda gastado, y PARA: no hay ciclo
> 4 con esta estrategia — escala como decisión humana.

## Qué NO está en este plan

- Nada de visión (T1, T2, zoom, triaje visual): apagado se queda apagado.
- Nada que llame a la API de Anthropic desde la aplicación.
- Ninguna corrida de rúbricas sobreajustadas como evidencia.
- Ningún cambio de `BEDROCK_MODEL_ID` en producción: si algún hallazgo sugiere subir de
  modelo, se presenta con números al dueño como decisión humana.
- El cotejo PDF de las 4 familias mixtas de H-06 (pospuesto por decisión #5).
- **Las preguntas del holdout v3 en este documento**: no se listan aquí ni en ningún
  artefacto que lean las sesiones de las Fases 1-2 — sólo existen en el fixture
  congelado por la Fase 3. Un holdout que las fases de arreglo pueden leer deja de ser
  holdout.
