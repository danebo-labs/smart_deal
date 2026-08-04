# Plan ciclo 4 — Ajuste final de precisión RAG (2026-08-03)

**Objetivo:** superar el gate de salida a piloto atacando las dos causas raíz medidas del
fallo v3 — N10 (colisión de retrieval entre secciones con contenido casi idéntico) y N11
(cobertura multi-placa insuficiente en generación) — con una estrategia DISTINTA a la de
los ciclos 1-3 (retrieval, no guard/generación), más una capa operacional de seguridad
para el piloto. Un error sobre bypass de seguridades es intolerable: el criterio de
seguridad del gate se endurece, no se relaja.

**Entrada obligatoria:** `docs/rag/plan_precision_definitiva_2026-08-03.md` (ciclo 3
completo: hallazgos N1-N11, decisiones #5-#8, método §8.3 heredado de
`docs/rag/plan_quirurgico_precision_2026-08-02.md`).

**Línea base:** gate v3 = 119/133 (89.5%, cumple el umbral numérico) pero
`holdout_v3_fain_jumper_falta_fase_seguridad` (safety_critical) falló 8/10 por N10 →
gate NO superado. v1, v2 y v3 están **gastados**: prohibido reabrirlos, ni con
`RAG_SEGURIDADES_CASE_IDS`.

**Decisiones del dueño del producto (2026-08-03) incorporadas:**
1. **#8 resuelta: opción B+A.** Ciclo 4 con estrategia de retrieval (N10/N11) — permitido
   por la regla del ciclo 3, que prohibía repetir "esta estrategia", no un ciclo nuevo —
   MÁS guardrail operacional en el piloto (Fase 3). Si el v4 falla, se PARA: no hay ciclo
   5 con esta estrategia; la siguiente decisión humana (#9) elige otro camino.
2. **Evaluador endurecido:** el gate v4 verifica que la página citada ∈ `source_pages`
   (el evaluador del v3 sólo verificaba PRESENCIA de citas — así se escondió N10 en 3
   casos que "puntuaron bien").
3. **Preocupación por exceso de regex (del dueño):** este ciclo no añade ningún patrón
   nuevo de forma-de-pregunta (restricción 6) y entrega un inventario documental de los
   existentes (Fase 0c) con ruta de retiro.
4. **Modelos:** Sonnet 5 en todas las fases; **Haiku 4.5 excluido de toda fase que ejecute
   contra producción** — en el ciclo 3 registró erróneamente la decisión #7 y duplicó el
   humo por `kamal app exec` sin `--role` (commit de corrección 39aa193).

## Restricciones no negociables

1. Nada de regex nuevo en la aplicación para maquillar respuestas (heredada).
2. Cero re-ingesta / re-troceo (heredada). **N8** (la línea `**Document:** ALJO Control
   Level 1B Altius` incrustada en 96/97 CUERPOS de chunk) sigue fuera de alcance; el v4
   hereda la regla del v3: no exigir marca correcta como `required` fuera de las págs.
   2-7 (ALJO real) y las divisoras limpias.
3. Sin saldo en la API de Anthropic de la app (desde 2026-08-02): ninguna fase la llama.
   El benchmark va por AWS Bedrock, facturación AWS aparte.
4. Presupuesto Bedrock declarado por fase; techo del ciclo: **36 llamadas** (el techo de
   30 del ciclo 3 quedó corto 3 veces — 38 reales; se declara uno realista en vez de
   excederlo "con transparencia"). Conteo en `retrieve_invocations` reales, patrón medido
   en v3: ruta estructurada ×1, ruta genérica ×2 por pregunta.
5. Límites de la cuenta de tooling (N5, reconfirmado 2026-08-03: un subagente de la
   sesión de planificación murió con "Credit balance is too low"): sesiones cortas, un
   objetivo por sesión, sin fan-out de subagentes.
6. **(nueva, del dueño)** Ningún patrón nuevo de forma-de-pregunta en este ciclo. Los
   fixes son: filtro de metadata que reutiliza `PAGE_REFERENCE_PATTERN` (existente) + un
   flag existente. Extraer el número de página del texto ya matcheado por ese patrón
   (`match[0][/\d+/]`) no cuenta como patrón nuevo; añadir un patrón que decida una RUTA
   nueva sí contaría — si un arreglo lo pide, se para y se escala.
7. **(nueva, lección E3)** Todo artefacto de corrida se copia a tmp LOCAL con SHA256
   verificado ANTES de cerrar la sesión que lo generó. Un artefacto sólo-en-contenedor
   no cuenta como evidencia (el del gate v3 quedó atrapado en el contenedor).

## Hallazgos de arranque (sesión de planificación 2026-08-03)

| # | Hallazgo | Evidencia |
|---|---|---|
| E1 | El fix de N11 ya existe y está APAGADO: `Rag::FamilyAmbiguityDetector` + `add_named_board_coverage` (`app/services/rag/structured_evidence_route.rb:363-457`) se escribieron exactamente para el caso "LED SPM en TW1 y DELTA+" (el comentario de la línea 365 lo cita literal), pero `RAG_FAMILY_AMBIGUITY_GUARD_ENABLED` no está en `config/deploy.yml` → apagado en prod. Con el flag apagado, `detect_family_ambiguity` devuelve nil y `add_named_board_coverage` retorna sin hacer nada (líneas 368 y 434). | código + deploy.yml |
| E2 | Los 4 fallos N10 nombran la página explícitamente ("página 76", "página 46"×2, "página divisoria de THYSSEN") y el retrieval no la usa. El filtro de Bedrock ya soporta `equals` sobre metadata (`app/services/bedrock_rag_service.rb:111-136`) y `page_number` es **entero** en los sidecars (verificado en `tmp/seguridades_sidecars_2026-08-03/chunk_63.txt.metadata.json`). `PAGE_REFERENCE_PATTERN` ya existe (`app/services/rag/deterministic_intent.rb:41`). | fixture v3 + código + sidecar |
| E3 | El artefacto completo del gate v3 (1.39 MB, SHA256 `b4e4b892…`) NO está en tmp local — quedó sólo en el contenedor de prod. Perecedero: se pierde si el contenedor reinicia. Rescate = Fase 0a, inmediata. | `ls tmp/` local |
| E4 | `build_vector_search_configuration` es compartido por `query()` (retrieve_and_generate, línea 67) y `retrieve_chunks()` (línea 474) — un filtro de página ahí cubre las DOS rutas que usó el gate v3 (10 casos `structured_evidence_route` + 4 `bedrock_retrieve_and_generate`). | `bedrock_rag_service.rb` |
| E5 | Intuición del dueño sobre exceso de regex: parcialmente validada — el fallo v2 fue un guard regex (N7) y existen ~8 familias de patrones de forma-de-pregunta. El fallo v3 NO fue regex (retrieval). Inventario en Fase 0c. | exploración |
| E6 | Las citas de `Bedrock::CitationProcessor#build_numbered_references` ya llevan un campo estructurado `page` (entero) además del `title` "… — p. N" (`app/services/bedrock/citation_processor.rb:84-91`) → el check de página del evaluador lee `citations[i]["page"]` del artefacto, sin parsear strings. | código |
| E7 | El canal web renderiza la respuesta desde JSON (`RagController#ask` → `render json`) en `app/javascript/rag/answer_presenter.js` + `app/javascript/controllers/rag_chat_controller.js` → el guardrail (Fase 3) vive en la capa de presentación, nunca dentro del string `answer` — el gate no se contamina. | código |

Además, corrección a la redacción de N9 (medida en código): el guion de benchmark salta
DOS pasos de producción, no uno — nunca invoca `DocumentOverviewResponder` (paso 1 de
`QueryOrchestratorService`) ni `Rag::DeterministicRenderer` (paso 4). Sin mandato en este
ciclo; importa para redactar el v4 (Fase 5, regla e).

## Asignación de modelo por fase

| Fase | Modelo | Racional |
|---|---|---|
| 0 Rescate + diagnóstico offline + inventario regex | Sonnet 5 | análisis, $0 Bedrock |
| 1 Fix N10 (page-pin) | Sonnet 5 | código + tests + verificación dirigida |
| 2 Fix N11 (flag) | Sonnet 5 | cambio mínimo + verificación |
| 3 Guardrail piloto (UI) | Sonnet 5 | frontend + i18n + test |
| 4 Evaluador v2 (página) | Sonnet 5 | infra de evaluación, $0 |
| 5 Holdout v4 | Sonnet 5 — sesión NUEVA que no tocó Fases 1-4 | el rigor de rúbrica que falló en v1 |
| 6 Checkpoint despliegue | **Sonnet 5 — NO Haiku** | lección ciclo 3 (decisión #4 del dueño) |
| 7 Gate v4 | **Sonnet 5 — NO Haiku** | ídem; además clasifica fallos si no pasa |

Opus 5 sólo para consultas acotadas sobre un hallazgo ambiguo — nunca sesión completa.
Nunca Fable. El juez sigue siendo `Rag::BenchmarkRubricEvaluator` (regex determinístico,
$0). `BEDROCK_MODEL_ID` de producción no se toca.

## Fase 0 — Rescate, diagnóstico offline e inventario regex (Sonnet 5; $0 Bedrock salvo degradación)

- **0a (inmediata, la ejecuta la sesión de planificación):**
  `bundle exec kamal app exec --reuse -r web "cat tmp/rag_seguridades_holdout_v3_run1_2026-08-03.json" > tmp/rag_seguridades_holdout_v3_run1_2026-08-03.json`
  + verificar SHA256 `b4e4b8927a0f6d9491f3e4c9ac88f6c6a8ae8f3f24b7002e95f445e5d1b7659e`.
  Si el contenedor ya lo perdió: anotar la pérdida en Estado; 0b degrada a ≤6 sondas
  `retrieve` nuevas, declaradas antes de correrlas.
- **0b (decide el mecanismo de la Fase 1):** con el artefacto, por cada caso N10
  (`holdout_v3_fain_em66_sk0_h40` 76→78, `holdout_v3_thyssen_divisor_cmc4` 92→97,
  `holdout_v3_fain_ekm1000_potenciometros_comparativa` 46→79,
  `holdout_v3_fain_jumper_falta_fase_seguridad` 46→79): ¿el chunk de la página esperada
  ENTRÓ en `retrieved_chunks` y perdió contra el duplicado (→ bastaría re-rank local), o
  nunca entró al top-k (→ hace falta el filtro Bedrock)? Salida: tabla caso × página
  esperada × ¿en top-k? × rank del duplicado. Para `holdout_v3_sistel_spm_ambigua` (N11):
  ¿el retrieval traía chunks de TW1? (si sí, E1/flag basta; si no, N11 tiene además
  componente de recall — escalar antes de tocar nada). **Default si no hay artefacto y
  las sondas no son concluyentes: filtro Bedrock** (funciona en ambos escenarios; el
  re-rank local sólo funciona si el chunk ya entró).
- **0c (inventario regex, decisión del dueño):** anexo de este documento con la tabla de
  TODOS los patrones de forma-de-pregunta: dónde vive, qué decide, fallos que ya causó,
  riesgo, ruta de retiro. Semilla mínima verificada: `Rag::DeterministicIntent`
  (`GENERIC_HARDWARE_PATTERNS`, `EXPLICIT_EQUIPMENT_PATTERN`, `PAGE_REFERENCE_PATTERN`,
  `FUNCTIONAL_TEST_PATTERNS`, `STOP_WORK_PATTERNS` — N7 nació aquí),
  `RagRetrievalProfile` (`EXHAUSTIVE_PATTERNS`, `SAFETY_CRITICAL_PATTERNS` — no reconoce
  preguntas de bypass, medido en ciclo 3 Fase 1 —, `COMPARATIVE_PATTERN`,
  `SCHEMATIC_DESIGNATOR_PATTERN`/`SCHEMATIC_KEYWORD_PATTERN`),
  `Rag::EvidenceCandidateSelector` (`STATE_PATTERN`, `CONNECTION_PATTERN`,
  `FUNCTION_STOPWORDS`), `BedrockRagService` (`query_names_different_document?`,
  `bedrock_no_results?`). Ruta de retiro de referencia: la migración P4
  (`test/services/rag/regex_characterization_test.rb`, huecos 4-5, `DEUDA · P4`) —
  guards que consulten identidad de equipo por chunk, no forma léxica de la pregunta.
  Sólo lectura; no se toca código. **No se arregla nada en esta fase.**

## Fase 1 — Fix N10: anclar retrieval a la página nombrada (Sonnet 5)

**Hipótesis (§8.3):** si la pregunta nombra "página N"
(`Rag::DeterministicIntent::PAGE_REFERENCE_PATTERN`, existente), añadir a
`vector_config[:filter]` en `build_vector_search_configuration`
(`app/services/bedrock_rag_service.rb:111-136`) un
`{ equals: { key: "page_number", value: N } }` (N entero — E2) en AND con el filtro de
cuenta+documento hace que el chunk de la página nombrada gane a su duplicado casi calcado
(FAIN p.46 vs RECOBA p.79; THYSSEN p.92 vs p.97). Si es falsa, las sondas ad-hoc
seguirían citando el duplicado.

Diseño:
- **Detrás de flag** (`Rag::PagePinFlag` / `RAG_PAGE_PIN_ENABLED: "true"` en deploy.yml,
  patrón exacto de `app/services/rag/structured_evidence_route_flag.rb`) para rollback
  limpio.
- Sólo cuando la pregunta nombra UNA página (una única coincidencia del patrón). Rango o
  varias páginas → sin filtro (límite conocido, se anota).
- Extracción del número: del propio match del patrón existente (restricción 6).
- Cubre ambas rutas por E4. Degradación honesta: si el filtro de página da 0 resultados,
  `query()` ya reintenta sin filtro (`bedrock_rag_service.rb:232` — cuesta 1 llamada
  extra, se documenta); la ruta estructurada abstiene con `DATA_NOT_AVAILABLE`
  (correcto: la página nombrada no tiene ese contenido).
- `Rag::SectionNeighborExpander` no se ve afectado (expande vía S3 local, no Bedrock):
  si la página nombrada es una divisora, la expansión a vecinos sigue funcionando porque
  no pasa por el filtro.
- El guion de benchmark usa `retrieve_chunks` + `StructuredEvidenceRoute`, ambos pasan
  por `build_vector_search_configuration` → el gate v4 SÍ ejercita el fix.

Verificación: tests unitarios del builder de filtro ($0 — estructura `and_all`/`equals`
generada con y sin página, flag on/off, valor entero) **+ ≤8 llamadas Bedrock**: 3-4
preguntas ad-hoc NUEVAS nombrando páginas de los clusters duplicados (46/76/79, 92/97)
con hechos distintos a los del v3, before/after UNA sola vez (lección de la desviación
#7 del ciclo 3: no duplicar corridas por intervención). Artefacto completo a tmp local +
SHA256. Declarar hipótesis y resultado esperado si es falsa por cada intervención.

## Fase 2 — Fix N11: encender la cobertura multi-placa (Sonnet 5)

- Añadir `RAG_FAMILY_AMBIGUITY_GUARD_ENABLED: "true"` a `config/deploy.yml` (E1). Cero
  código nuevo.
- Antes de encender: confirmar que ningún test congelado espera el flag apagado (el
  comentario de `structured_evidence_route.rb:430-432` menciona fidelidad de replay del
  D5 archivado — verificar que es sólo histórico).
- Correr las suites existentes de `family_ambiguity_detector` y
  `structured_evidence_route` ($0).
- Verificación dirigida: 1-2 preguntas ad-hoc multi-placa NUEVAS (≤4 llamadas): esperar
  `generation_chunks ≥ 2` (una por familia) y respuesta que enumera por placa y pregunta
  cuál placa tiene el técnico (la `multi_family_directive` ya existe,
  `structured_evidence_route.rb:605`). Artefacto a local + SHA256.

## Fase 3 — Guardrail operacional del piloto (opción A del dueño; Sonnet 5, $0 Bedrock)

- Aviso estático de verificación en TODAS las respuestas del chat web: elemento de
  presentación en `app/javascript/rag/answer_presenter.js` (o el host del mensaje del
  asistente en `rag_chat_controller.js`) + copy i18n es/en tipo: "Asistencia de consulta
  al manual — verifica cualquier acción sobre seguridades contra el manual antes de
  ejecutarla".
- **Deliberadamente sin clasificador por pregunta:** un clasificador sería regex nuevo de
  forma-de-pregunta (restricción 6), y el heurístico existente `safety_critical_query?`
  ya demostró NO reconocer preguntas de bypass (ciclo 3, Fase 1). Aplicar a todo es
  honesto para un MVP.
- El aviso NUNCA se concatena al string `answer` del JSON (E7) — el gate v4 y los
  artefactos no se contaminan. Test que verifica ambas cosas (el aviso aparece con cada
  respuesta; `answer` no lo contiene).

## Fase 4 — Evaluador v2: fidelidad de página (Sonnet 5, $0)

- Extender `Rag::BenchmarkRubricEvaluator` (`app/services/rag/benchmark_rubric_evaluator.rb`):
  nuevo check por caso **`source_page_cited`** — pasa si
  `(páginas de las citas del resultado) ∩ source_pages ≠ ∅`, leyendo
  `citations[i]["page"]` (campo estructurado ya presente — E6; fallback: parsear
  " — p. N" del `title` si `page` es nil).
- Activación por caso: campo nuevo del fixture `"source_page_required": true|false`.
  Default: `true` si el caso trae `source_pages` no vacío; el autor del v4 lo apaga
  explícitamente donde no aplique (p.ej. `sin_respaldo`, donde la respuesta correcta
  declara ausencia). Documentar el default en el evaluador.
- Semántica: como `citation_passed` — afecta `passed` del caso, **NO** la fórmula de
  score (`required×2 + optional + citación 2` — la parte numérica sigue comparable con
  v3).
- Tests unitarios con payloads sintéticos: página correcta / página del duplicado /
  `page` nil con title parseable / sin citas / `source_page_required: false`.
- Esta fase va ANTES de congelar el v4, para que el QA del holdout ejercite el check.

## Fase 5 — Congelar holdout v4 (Sonnet 5, sesión NUEVA que no tocó Fases 1-4)

`script/fixtures/rag_seguridades_holdout_v4.json` — **14 preguntas**, formato del v3
(`stratum`, `category`, `severity`, `question`, `source_pages`, `required`/`optional`/
`penalized`, `citation_required` global, y nuevo `source_page_required` por caso).
Distribución idéntica al v3: 3 determinísticas / 2 mapeos estructurados / 2
generalización / 1 ambigua / 1 sin respaldo / 4 seguridad / 1 comparativa. Redactadas
desde la verdad-terreno pagada (Gate A §5-§9 + lectura de los 97 cuerpos), sin reutilizar
ninguna pregunta de v1/v2/v3.

Reglas de diseño específicas del v4 (además de las QA del v3, heredadas completas):
1. **Cobertura deliberada de los clusters duplicados** — el gate debe PROBAR el fix N10,
   no esquivarlo: ≥4 casos sobre FAIN/RECOBA (págs. 46, 76-79) y THYSSEN (92/97),
   nombrando "página N", con hechos DISTINTOS a los del v3.
2. **1 caso multi-placa estilo SPM** (mide N11 con el flag encendido), hecho distinto al
   SPM/TW1-DELTA+ del v3.
3. 4 seguridad: `severity: safety_critical` a nivel de caso + patrones `penalized` con
   `severity: critical` (N4 — el evaluador no reconoce `safety_critical` como peso de
   patrón); ≥1 sobre el cluster p.46 con hecho distinto al Jumper 1 del v3; bypass J de
   pág. 65 sólo con hecho distinto a J24 (v3) y J25 (v2) — quedan J12/J26.
4. `source_page_required` puesto conscientemente por caso; en los 4 de seguridad: `true`
   obligatorio.
5. Los 14 verificados offline ($0) con
   `Rag::DeterministicIntent.ambiguous_hardware_query? == false`; respetar N8 (no exigir
   marca fuera de ALJO 2-7 y divisoras limpias) y N9 corregido (el guion no invoca
   `DeterministicRenderer` NI `DocumentOverviewResponder` — checklist/prueba funcional
   se redactan para la ruta genérica, como hizo el v3).
6. QA test clonado de `test/services/rag/benchmark_rubric_evaluator_holdout_v3_qa_test.rb`:
   distribución por tally; suma real con la fórmula del evaluador; `passing_score =
   ceil(80% de la suma real)` (ambos en fixture y test); cobertura de ids; respuesta
   correcta conocida por caso contra el evaluador real (con cita sintética que incluye
   `page` correcto); ningún `penalized` dispara sobre respuesta correcta;
   no-reutilización contra v1+v2+v3; assertions nuevas del check de página.
7. Prohibiciones heredadas de rúbrica: ventanas `.{0,N}` que crucen ítems de lista (usar
   `(?:(?!\bX\b).){0,40}`); lookaheads que no cubran el "no" pospuesto; `required` con
   forma corregida donde el documento imprime errata (verbatims de Gate A §9).
8. **No se corre contra Bedrock**: se abre una sola vez en la Fase 7.

## Fase 6 — Checkpoint de despliegue (Sonnet 5 — NO Haiku)

**Momento exacto:** después de que las Fases 1-4 estén commiteadas con tests verdes, y
ANTES de abrir el holdout v4. Regla permanente: nunca se abre un holdout con cambios sin
desplegar.

1. `kamal deploy`; verificar SHA desplegado == HEAD con `kamal app version`.
2. **No hay resync de KB en este ciclo** (no se tocan sidecars): confirmar que el job
   vigente sigue siendo `ZGCU99ISK5` (`COMPLETE`).
3. Humo: **1 llamada, `--role web`** (sin `--role` corre en web+worker y duplica el
   gasto — lección ciclo 3 Fase 4). Pregunta nueva fuera de todo holdout QUE NOMBRE UNA
   PÁGINA, para ejercitar el page-pin: la cita debe ser de esa página.
4. Aurora caliente: `kb_retrieve` < 1s, sin `AuroraColdStartRetry` en el log.
5. Anotar en Estado: SHA, timestamp, evidencia del humo (a tmp local + SHA256).

## Fase 7 — Gate v4, UNA corrida (Sonnet 5 — NO Haiku)

1. **Criterio congelado antes de abrir:** ≥ 80% de la suma real **Y** cero
   `passed: false` en los 4 casos `safety_critical` **Y** `source_page_cited` verde en
   los 4 casos `safety_critical` (evaluador v2).
2. Patrón Kamal del v3 (un solo rol):
   `bundle exec kamal app exec --reuse -r web -p "sh -c 'RAG_SEGURIDADES_RUBRIC=script/fixtures/rag_seguridades_holdout_v4.json RAG_SEGURIDADES_OUTPUT=tmp/rag_seguridades_holdout_v4_run1_<fecha>.json bin/rails runner script/rag_seguridades_benchmark.rb'"`.
3. Verificar ANTES que la Fase 6 anotó SHA y humo; si no, detenerse — no se abre.
4. **Artefacto completo obligatorio + copia local en la misma sesión (restricción 7):**
   `results[]` con `chunks` y `answer`/`raw_answer` no vacíos por caso (~1 MB de
   referencia), copiado del contenedor a tmp local, SHA256 anotado en Estado. La corrida
   NO se repite.
5. **Pasa** → liberar a piloto con el guardrail de la Fase 3 activo.
   **No pasa** → clasificar los fallos (el evaluador v2 ya expone la página citada — la
   colisión N10 no puede esconderse), el v4 queda gastado, y **PARAR**: no hay ciclo 5
   con esta estrategia — escalar como decisión humana #9.

## Presupuesto del ciclo 4

| Concepto | Estimado |
|---|---|
| Fase 0: 0 (o ≤6 si el artefacto v3 se perdió) | 0–6 |
| Fase 1: ≤8 · Fase 2: ≤4 · Fases 3-5: 0 · Fase 6: 1 · Fase 7: ~18 `retrieve_invocations` | ≤31 |
| **Techo del ciclo** | **36** |
| **Real ejecutado** (Fase1: 8 + Fase2: 1 + Fase6: 1 + Fase7: 20) | **30/36** — dentro del techo |
| API de Anthropic desde la app | **$0** (ninguna llamada) |
| Sesiones de IA: 7-8 Sonnet 5 cortas; Opus sólo consultas acotadas; nunca Fable; Haiku excluido de fases contra prod | mínimo |

## Estado

| Fase | Estado | Artefacto / hash |
|---|---|---|
| 0a Rescate artefacto v3 | **hecho 2026-08-03** — el artefacto seguía en el contenedor (no se perdió); primer intento de `sha256sum` remoto dentro de la sesión SSH de `kamal app exec` dio un hash distinto (ruido: el pipe combinado `test -f && sha256sum` mezcló líneas de log de Kamal con stdout y corrompió el cómputo remoto). Se descargó con `cat` a un archivo crudo, se recortaron las 7 líneas de log de Kamal (`INFO […]`, `App Host: …`) que preceden al `{` inicial, y el SHA256 local coincide EXACTO con el esperado. **No hubo degradación**: 0b corrió sobre el artefacto completo, 0 llamadas Bedrock. | `tmp/rag_seguridades_holdout_v3_run1_2026-08-03.json` — SHA256 `b4e4b8927a0f6d9491f3e4c9ac88f6c6a8ae8f3f24b7002e95f445e5d1b7659e` (coincide) |
| 0b Diagnóstico offline N10/N11 | **hecho 2026-08-03**, $0 Bedrock — ver Anexo B para la tabla completa y el detalle por caso | — (análisis offline sobre el artefacto de 0a, sin generar artefacto nuevo) |
| 0c Inventario regex | **hecho 2026-08-03**, sólo lectura, nada tocado — ver Anexo C | — |
| 1 Fix N10 page-pin | **hecho 2026-08-03** — filtro `equals: page_number` (entero) implementado en `build_vector_search_configuration`, detrás de `Rag::PagePinFlag`/`RAG_PAGE_PIN_ENABLED`; activado en `config/deploy.yml` local (recuerda: ese archivo está gitignored, ver nota ⚠️ en el prompt de la Fase 2). Tests unitarios ($0) verdes. Desplegado a PROD (`kamal deploy`, SHA `0051b5ba13e8500a3127778a335a780ec926dff1` == HEAD, verificado con `kamal app version`). Verificación empírica con 4 preguntas ad-hoc NUEVAS (8 llamadas `Retrieve`, dentro del techo ≤8) — hipótesis CONFIRMADA, ver Anexo E: los 4 casos pasan de fallar/no-entrar-al-top-k a rank 1/12 exacto tras encender el flag. | before: `tmp/rag_page_pin_probe_before_2026-08-03.json` SHA256 `936dec845406b80b7fc9edb375aaafb18215c74e0790b0331768a402dfa339a9`; after: `tmp/rag_page_pin_probe_after_2026-08-03.json` SHA256 `62f3ecf08a07ee9b00cd733adbe33c89a630aaa51a557ffe99487d8f9626f9c2`; commit `0051b5b` |
| 2 Fix N11 flag multi-placa | **hecho 2026-08-03** — `RAG_FAMILY_AMBIGUITY_GUARD_ENABLED: "true"` añadido a `config/deploy.yml` local, al lado de `RAG_PAGE_PIN_ENABLED` (E1; ambos confirmados presentes en el checkout de esta sesión antes de tocar nada). Comentario D5 de `structured_evidence_route.rb:430-432` confirmado histórico: el replay de fidelidad depende de `ENV` del proceso de test local, no de `config/deploy.yml` de producción — no afectado por este cambio. Suites `family_ambiguity_detector_test.rb` + `family_ambiguity_guard_flag_test.rb` + `structured_evidence_route_test.rb` + `d5_attribution_replay_test.rb` verdes (52/52, 0 skips — el replay D5 corrió real, artefactos locales presentes). Desplegado a PROD dos veces: el primer `kamal deploy` se hizo con el script de verificación sin commitear — Kamal tagea la imagen con el SHA de HEAD, que no había cambiado, así que el contenedor quedó con el flag activo (inyectado en runtime vía `docker run --env`, independiente del build) pero SIN el script nuevo en la imagen (`COPY . .` con un working tree sucio no es lo mismo que el commit que le da nombre a la imagen — lección para toda fase futura: comitear el código/script de verificación ANTES de `kamal deploy`, no después). Corregido: se comiteó el script (`41f9060`) y se re-desplegó; `kamal app version` == HEAD `41f9060` confirmado. Verificación dirigida (1 pregunta ad-hoc NUEVA, 1 llamada Bedrock, dentro del techo ≤4): "¿Qué serie indica el LED DL2 en el manual de seguridades?" — identificador y par de placas (ALJO p.3 vs KDT 11/CARLOS SILVA p.13) verificados primero contra `test/services/rag/family_ambiguity_detector_test.rb` (fixture `dl2_chunks`, caso real ya validado en código), **distinto** al SPM/TW1-DELTA+ del v3. Resultado: `route_eligible: true`, `outcome_status: answered`, `generation_chunks: 4` (≥2 — pasa), boards representados = variantes de heading de ALJO ("LEVEL CONTROL 1B...") + CARLOS SILVA ("KDT 11" vía su heading, `section_identity` de fallback), respuesta que **enumera las dos placas por separado y termina preguntando explícitamente "¿Cuál es su placa de control?"** — hipótesis confirmada, comportamiento esperado de `add_named_board_coverage`/`multi_family_directive`. | `tmp/rag_family_ambiguity_probe_after_2026-08-03.json` SHA256 `a4cb03ae673a65e5b755d97f3de4b6e230ffee57a2eb489a4cf9dc2cea5d23b2`; script `script/rag_family_ambiguity_probe.rb`; commits `41f9060` (script) + redeploy sobre el mismo HEAD |
| 3 Guardrail piloto | **hecho 2026-08-03** — aviso estático exportado como `renderVerificationNotice(lang)` en `app/javascript/rag/answer_presenter.js` (copy es/en, tono "verifica cualquier acción sobre seguridades contra el manual antes de ejecutarla" / "verify any action on safety devices against the manual before performing it"); llamado desde `renderAssistantAnswer` en `app/javascript/controllers/rag_chat_controller.js` y concatenado al HTML del HOST del mensaje (`answerHtml + resolutionHtml + sourcesHtml + noticeHtml`), nunca al string `answer` — `formatAnswerForWeb(data.answer, citations)` sigue siendo la única función que toca `data.answer` y no conoce el aviso (E7 respetado, verificado por test). Sin clasificador por pregunta: se aplica igual a toda respuesta de `renderAssistantAnswer` (texto y adjuntos con pregunta), tal como manda la Fase 3 — no se tocó `safety_critical_query?` ni ningún regex de forma-de-pregunta (restricción 6 intacta). CSS nuevo `.answer-verification-notice` en `app/assets/stylesheets/application.css` (separador sutil, no interfiere con `.answer-p`/`.answer-hr`/`.citation`). $0 Bedrock (sin llamadas). Tests: 4 casos en `test/system/rag_chat_verification_notice_test.rb` (Minitest + Capybara/Selenium, mismo patrón de import directo de módulo JS que `rag_evidence_cards_test.rb`) — verifican (a) el aviso aparece en la burbuja real producida por `renderAssistantAnswer` en 2 respuestas distintas consecutivas, (b) cambia a inglés con `document.documentElement.lang = "en"`, (c) `formatAnswerForWeb` (la única función que deriva HTML de `data.answer`) NUNCA contiene la clase/copy del aviso, aislado del controlador. 28 assertions, 0 failures. No requiere Bedrock/red — no hubo verificación dirigida en vivo porque no hay lógica de retrieval/generación que ejercitar (es presentación pura). | commit de esta sesión — sin artefacto tmp (no hay corrida contra Bedrock que producir; la evidencia es el test suite, ver salida en el commit) |
| 4 Evaluador v2 | **hecho 2026-08-03** — nuevo check `source_page_cited` en `Rag::BenchmarkRubricEvaluator` (`app/services/rag/benchmark_rubric_evaluator.rb`): pasa si alguna cita del resultado tiene página ∈ `source_pages` del caso. Orden de resolución de página por cita: `citation["page"]` (E6, entero ya presente en el artefacto real) → `citation["metadata"]["page_number"]` (fallback añadido, no estaba en el mandato original — ver hallazgo abajo) → parseo de `" p. N"` en `citation["title"]`. Activación: `source_page_required` del fixture, default `true` si `source_pages` no vacío (si no se especifica), apagable por caso. Semántica: nuevo campo `source_page_cited`/`source_page_required` en el resultado por caso, entra a `passed` igual que `citation_passed`; `score`/`max_score`/`PENALTY_WEIGHTS` **sin tocar** (comparabilidad numérica con v3 intacta, N4 no afectado). Tests: 6 casos nuevos en `test/services/rag/benchmark_rubric_evaluator_test.rb` (página correcta, página del duplicado, `page` nil con título parseable, sin citas, `source_page_required: false`, más el default) — 18/18 verdes. $0 Bedrock. | commit de esta sesión — sin artefacto tmp (regex puro sobre payloads sintéticos, sin corrida contra Bedrock) |
| 5 Holdout v4 congelado | **hecho 2026-08-03** — `script/fixtures/rag_seguridades_holdout_v4.json`, 14 casos, misma distribución del v3 (3/2/2/1/1/4/1). 7 de 14 casos (D1 THYSSEN p.97, M1 THYSSEN p.92, M2 FAIN/RECOBA p.78, G2 FAIN/RECOBA p.77, SC1 FAIN/RECOBA p.79, SC4 THYSSEN p.97, C1 THYSSEN p.97) nombran "página N" sobre los clusters duplicados FAIN/RECOBA y THYSSEN exigidos por (a), con hechos verificados uno por uno contra el cuerpo real de cada chunk en `tmp/seguridades_chunks_2026-07-28/` y confirmados DISTINTOS de los del v3 (p.ej. STOP FOSO→C101 en p.78 vs. el SK0/H40 de p.76 en v3; PRESOSTATO(NC)→C304 en p.77; Jumper 1 en posición ABIERTA en p.79 vs. CERRADO en v3). El caso `ambigua` (ORONA ARCA P32, source_pages [61,64]) es multi-placa y cumple (b): P32 significa SERIE CERROJOS CABINA-EXTERIORES en ARCA base y SERIE SEGURIDADES PRINCIPALES en ARCA III (verificado contra el cuerpo real de ambas páginas), hecho distinto al SPM TW1/DELTA+ del v3. `source_page_required` (c) puesto deliberadamente en `true` en los 14 casos (no sólo los 4 de seguridad): cada respuesta correcta ancla a una página/par de páginas concretas dentro de `source_pages` — ninguno de los 14 tiene la forma de menú-de-desambiguación-con-páginas-de-ejemplo-no-relacionadas que sí justificó `false` en los 2 casos de fixtures anteriores documentados en el hallazgo de la Fase 4. N8 (d) respetado: el único `required` que exige identidad de marca vive en el caso divisor de THYSSEN p.92 (divisora limpia, permitido) y en el caso ALJO p.3 (ALJO real, permitido); ningún otro required exige marca. N9 (e): los 2 casos `stop_work_checklist`/`limites_fuentes_anular_proteccion` (CARLOS SILVA TPR70 p.11, THYSSEN CN26 p.97) están redactados para la ruta genérica del guion de benchmark. Bypass J de p.65 (g): J26 (J24 gastado en v3, J25 en v2). Verificación offline (f): `Rag::DeterministicIntent.ambiguous_hardware_query?` corrido contra los 14 vía `bin/rails runner` → `false` en los 14, $0 Bedrock. No-reutilización verificada por script contra v1+v2+v3 (intersección vacía). QA: `test/services/rag/benchmark_rubric_evaluator_holdout_v4_qa_test.rb` (9 tests, 126 assertions, clonado de la v3 QA con 3 tests nuevos: cobertura de clusters N10 ≥4, multi-placa N11 exactamente 1, verificación offline de `ambiguous_hardware_query?`), suma real de la rúbrica recalculada por el propio test = 136, `passing_score = ceil(0.8·136) = 109` (ambos campos también en el fixture). Los 4 casos de seguridad llevan `severity: safety_critical` a nivel de caso y `severity: critical` en cada `penalized` (N4). Suite completa verde tras el cambio: `bin/rails test`, 2260 runs (2251 + 9 nuevos), 0 failures/errors, 189 skips (mismo conteo de skips que antes de este cambio). **No se corrió nada contra Bedrock** (restricción de la Fase 5); no hay artefacto de corrida que copiar a tmp/SHA256 bajo la restricción 7 — el propio fixture congelado (versionado en git) es la entrega de esta fase. Memoria persistente del proyecto: este repo no tiene un almacén de memoria externo al plan vivo (`docs/rag/plan_ciclo4_ajuste_final_2026-08-03.md`); esta fila de Estado + el prompt actualizado de la Fase 7 (Anexo A) cumplen ese rol para el ciclo 4. | `script/fixtures/rag_seguridades_holdout_v4.json` (versionado en git, sin SHA256 de corrida — no aplica, no se llamó a Bedrock); `test/services/rag/benchmark_rubric_evaluator_holdout_v4_qa_test.rb` |
| 6 Checkpoint despliegue | **hecho 2026-08-04** — Fases 1-4 confirmadas commiteadas con tests verdes ANTES de tocar nada (`bin/rails test`: 2260 runs, 8052 assertions, 0 failures, 0 errors, 189 skips — mismo conteo que el cierre de la Fase 4, sin regresión). `config/deploy.yml` local confirmado con las dos líneas de flag (`RAG_PAGE_PIN_ENABLED: "true"`, `RAG_FAMILY_AMBIGUITY_GUARD_ENABLED: "true"`) antes del deploy. Dos `kamal deploy` en esta sesión (patrón de la Fase 1/2: script de verificación se commitea ANTES de desplegar): (1) `kamal deploy` inicial sobre HEAD `4fe5275` (Fase 5, ya commiteado por la sesión anterior) — `kamal app version` confirmó `4fe5275e642f9dd42d1ef4a3c799ef48c7529411` == HEAD; (2) se creó y commiteó `script/rag_page_pin_smoke.rb` (commit `270c638`, sólo el script, sin tocar Fases 1-5) y se re-desplegó — `kamal app version` confirmó `270c6387dbfa66c3d1ad477a154ef309126ae8bd` == HEAD tras el segundo deploy. **SHA final desplegado (el que debe verificar la Fase 7): `270c6387dbfa66c3d1ad477a154ef309126ae8bd`.** KB sin resync: `aws bedrock-agent get-ingestion-job` confirma que `ZGCU99ISK5` sigue `COMPLETE` y `list-ingestion-jobs` (orden descendente por `startedAt`) lo muestra como el job más reciente del data source — ningún resync nuevo ocurrió en este ciclo. Humo (**1 llamada Retrieve**, `bundle exec kamal app exec --reuse -r web -p "sh -c '... bin/rails runner script/rag_page_pin_smoke.rb'"` — `-r web` explícito, sin duplicar en worker): pregunta nueva fuera de v1/v2/v3/v4 ("¿Qué serie indica el LED DL27 SSH en la página 40 del manual de seguridades?", página 40 = TOKIBAT 2.007, hecho verificado contra `tmp/seguridades_chunks_2026-07-28/chunk_38.txt` antes de correr, página no usada por ningún holdout — se auditaron los `source_pages` de los 4 fixtures completos para confirmarlo) — `route_taken: structured_evidence_route`, filtro `equals: page_number → 40` (entero) presente en `vector_search_configuration` (page-pin activo), `cited_pages: [40]`, `page_pin_exact_match: true`, respuesta correcta ("SERIE SEGURIDAD HUECO CERRADA"). Aurora caliente: `kb_retrieve latency_ms: 549` (< 1s) vía el log `[PILOT_USAGE]`; cero líneas `[Aurora]` (cold-start) en toda la sesión del exec. Timestamp del humo: `2026-08-04T04:11:04Z` (medido en el propio artefacto, UTC). | `tmp/rag_page_pin_smoke_fase6_checkpoint_2026-08-04.json` (copiado del contenedor, cabecera de log de Kamal recortada igual que en la Fase 0a) — SHA256 `abca133dbb3242a688bb054ec1f82936fd8e9674ff6dfbd4fe328ce111acb000`; script `script/rag_page_pin_smoke.rb` (commit `270c638`); deploy final commit/SHA `270c6387dbfa66c3d1ad477a154ef309126ae8bd` |
| 7 Gate v4 → piloto | **NO PASA — hecho 2026-08-04.** Pre-chequeo: `git rev-parse HEAD` en esta sesión = `1248592aa4d80fabf04e9d01e1035d33aaf9a9ef`, **no** `270c638` como anotó la Fase 6 — diff inspeccionado (`git diff 270c638 1248592 --stat`): el único commit de más es la propia fila de Estado de la Fase 6 (`docs/rag/plan_ciclo4_ajuste_final_2026-08-03.md`, 0 archivos de `app/`/`config/`/`script/`) → el checkpoint de despliegue SÍ cubre el código corriendo en prod (`270c638`), no hizo falta repetir la Fase 6. Corrida única vía el patrón Kamal del v3 (`-r web`, un solo rol): **20 `retrieve_invocations`** (dentro del techo del ciclo: 8 Fase1 + 1 Fase2 + 1 Fase6 + 20 Fase7 = 30/36). Artefacto copiado del contenedor a tmp local (mismo patrón de recorte de 7 líneas de log Kamal que Fase 0a/Fase 6); verificado con Python que los 14 `results[]` tienen `chunks` y `answer` no vacíos (restricción 7 cumplida) — tamaño final 309 KB (menor a la referencia de ~1 MB del v3, consistente con que el page-pin fuerza casi siempre 1 chunk relevante en vez de competir por 10-12, ver conteo `retrieve_invocations`/case). **Resultado bruto:** 14 casos, 11 `passed`, 3 `failed`, score 124/136 (91.2%) — **supera** el umbral numérico (`passing_score = ceil(0.8·136) = 109`, 124 ≥ 109). **Pero 1 de los 4 casos `safety_critical` tiene `passed: false`** (`holdout_v4_carlos_silva_tpr70_b7_seguridad`) → **el criterio congelado ("cero fallos en los 4 `safety_critical`") NO se cumple**, aunque `source_page_cited` sale verde en los 4 (incluido el que falla). Por AND estricto de las tres condiciones, **el gate v4 NO PASA**. Clasificación de los 3 fallos en Anexo F (regex del evaluador vs. defecto real distinguidos caso por caso). **v4 queda gastado** (no se repite la corrida, restricción de la Fase 7). **PARADO**: no hay ciclo 5 con esta estrategia — ver "Decisión humana #9" al final de este documento. NO se libera a piloto. | `tmp/rag_seguridades_holdout_v4_run1_2026-08-04.json` — SHA256 `5be0fcc5e14eef28e8803e2dd626fec606aec8f83422a336e39e2f0b8c893949` |

**Hallazgo de la Fase 4 (2026-08-03, no estaba en el mandato original — encontrado corriendo
la suite completa antes de cerrar):** `Rag::BenchmarkRubricEvaluator` es compartido por más
consumidores que los holdouts v1/v2/v3 — también lo usan `script/evaluate_rag_seguridades_benchmark.rb`
y el contrato de replay D5 (`script/replay_d5_attribution_contract.rb`,
`test/services/rag/d5_attribution_replay_test.rb`,
`test/services/rag/citation_attribution_contract_characterization_test.rb`) sobre fixtures MÁS
ANTIGUAS que los holdouts (`script/fixtures/rag_seguridades_rubric.json` y
`rag_seguridades_pilot_10q.json` — no son v1/v2/v3, no están gastados, no se tocó la restricción
de holdouts). Con el default `source_page_required: true`, 2 casos categoría `"ambiguas"`
(`cerrojos_generica`, `cerrojos_conexion_generica`) empezaron a fallar `regressions=2` en el gate
del replay D5: la respuesta CORRECTA archivada para ambos es un **menú de desambiguación** que
cita 3 páginas de ejemplo de modelos NO relacionados (p.ej. 48/67/97 cuando `source_pages: [11,
14, 22]`) — comportamiento esperado (pedir que el técnico elija placa), no una colisión N10. Fix:
se añadió `"source_page_required": false` a esos 2 casos en sus fixtures (mismo mecanismo que ya
preveía el diseño para `sin_respaldo`; aquí aplica también a menús de desambiguación categoría
`ambiguas`, no sólo a "sin respaldo"). Un tercer caso `ambiguas` (`elecmegon_obstaculo_ambiguo`,
`rag_seguridades_pilot_10q_v2.json`) NO se tocó porque su cita archivada ya coincidía con
`source_pages` — se deja con el default `true` a propósito (más rigor donde no rompe nada real).
Suite completa verde después del fix (`bin/rails test`, 2251 runs, 0 failures/errors). **Impacto
en la Fase 5 (ver prompt actualizado abajo, marcado ⚠️ CRÍTICO):** un caso `ambigua` que produce
un menú de desambiguación (no una respuesta anclada a una página) es candidato natural a
`source_page_required: false`, igual que `sin_respaldo` — no sólo cuando la respuesta correcta
declara ausencia de dato.

## Protocolo de plan vivo v2 (cláusula reforzada, heredada + restricción 7)

Toda sesión que ejecuta una fase, ANTES de cerrar y en el MISMO commit:
1. Actualiza su fila de la tabla de Estado (hecho/bloqueado + artefacto/SHA256; los
   artefactos en tmp LOCAL — restricción 7).
2. Corrige las fases posteriores afectadas por sus hallazgos (con fecha y evidencia).
3. Actualiza el prompt de la fase siguiente en el Anexo A; si el hallazgo es crítico
   para su implementación, lo marca con `⚠️ CRÍTICO:` al inicio.
4. Actualiza la memoria persistente del proyecto (entrada del ciclo 4).
5. `git commit` de TODO (código + este documento + fixtures/tests). Nada queda sin
   commitear al cerrar.
6. Si un hallazgo contradice una restricción no negociable o el criterio del gate: no se
   ejecuta — se documenta y se escala como decisión humana numerada (siguiente: #9).

## Anexo B — Fase 0b: diagnóstico offline N10/N11 (2026-08-03)

Análisis sobre el artefacto rescatado en 0a (`chunks[].metadata.page_number` +
`citations[].page` por caso; sin llamadas Bedrock).

### N10 — ¿el chunk de la página esperada entró al top-k?

| Caso | Página esperada | Página citada (duplicado) | ¿Esperada en top-k? | Rank esperada | Rank citada | Ruta / top_k |
|---|---|---|---|---|---|---|
| `holdout_v3_fain_em66_sk0_h40` | 76 | 78 | **Sí** | 10/12 | 6/12 | `structured_evidence_route`, 12 |
| `holdout_v3_thyssen_divisor_cmc4` | 92 | 97 | **No** — nunca entró | — | 2/12 | `structured_evidence_route`, 12 |
| `holdout_v3_fain_ekm1000_potenciometros_comparativa` | 46 | 79 | **No** — nunca entró | — | 1/3 | `bedrock_retrieve_and_generate`, sólo 3 |
| `holdout_v3_fain_jumper_falta_fase_seguridad` (safety_critical) | 46 | 79 | **Sí** | 2/12 | 1/12 | `structured_evidence_route`, 12 |

**Veredicto (decide el mecanismo de la Fase 1): filtro Bedrock, no re-rank local.**
En 2 de los 4 casos (THYSSEN 92, FAIN 46-comparativa) el chunk de la página nombrada
**nunca llega** al conjunto recuperado — ningún re-rank posterior a la recuperación puede
arreglarlos porque el candidato correcto no existe en la lista a reordenar. El filtro de
metadata (`equals: page_number`) es el único mecanismo de los dos que cubre los 4 casos
(fuerza a Bedrock a devolver la página nombrada en vez de competir por score contra su
casi-duplicado). Nota adicional no pedida por el plan pero relevante para la Fase 1: el
caso de sólo 3 resultados usó la ruta genérica (`bedrock_retrieve_and_generate`,
`number_of_results: 3`) — un presupuesto de top_k tan chico agrava la pérdida de recall
independientemente del fix de página; el filtro por página lo compensa porque no depende
de ganar por score dentro de ese presupuesto reducido.

### N11 — `holdout_v3_sistel_spm_ambigua` (LED SPM en TW1 y DELTA+)

`source_pages: [88, 89, 90, 91]`, ruta `structured_evidence_route`, 12 chunks recuperados.
Se verificó el **cuerpo** de cada chunk (no sólo `metadata.aliases`) buscando "TW1" y
"SPM" literales:

| Rank | Página | ¿"TW1" en cuerpo? | ¿"SPM" en cuerpo? |
|---|---|---|---|
| 1 | 88 | Sí | Sí |
| 2 | 89 | Sí | Sí |
| 3 | 88 | Sí | Sí |
| 4 | 91 | No | Sí |
| 5 | 90 | Sí | Sí |
| 6-12 | otras placas | No | No |

El chunk de rank 2 (página 89, "TWISTER TW – ELECTRICO - EMBARBA") contiene literalmente
la tabla `SPM (rojo) | SERIE DE PUERTAS` para TW1 — el dato que la respuesta necesitaba.
Sin embargo la respuesta generada dice: *"En TW1: La documentación recuperada no
contiene información sobre un LED SPM en un componente denominado TW1"* — un dato que
SÍ estaba en el contexto entregado al modelo.

**Veredicto: N11 NO tiene componente de recall.** El retrieval trae los chunks de TW1
(con el dato exacto) al top-k; el fallo es 100% de cobertura en generación — exactamente
el síntoma que `Rag::FamilyAmbiguityDetector` + `add_named_board_coverage` fueron
escritos para corregir (E1). La Fase 2 puede proceder con el flag sin escalar: no hace
falta ningún cambio de retrieval para este caso.

### Hallazgo adicional (no pedido explícitamente por 0b, surgido de una pregunta del
dueño durante la sesión): barrido exhaustivo de citación vs. `source_pages` en los 14
casos del v3, no sólo en los 4 nombrados como N10

El evaluador viejo del v3 sólo comprueba PRESENCIA de cita, no que la página citada
∈ `source_pages` (motivo de la Fase 4 de este ciclo). Cruzando `citations[].page` contra
`source_pages` en los 14 casos completos del artefacto de 0a aparecen **2 casos
adicionales** con la misma colisión N10 que **pasaron como `passed: true`** bajo el
evaluador viejo — el evaluador v2 (Fase 4) los volteará a `false`:

| Caso nuevo | Severidad | `source_pages` | Página citada | ¿Página esperada en top-k? | Mecanismo |
|---|---|---|---|---|---|
| `holdout_v3_sistel_tw1_sseg_spa` | technical_important | [89] | 88 (duplicado casi calcado, misma placa TW1) | Sí, rank 2/12 (rank 1 = el duplicado, página 88) | Igual a N10: page-pin de la Fase 1 lo resuelve (mismo mecanismo, ninguna extensión de diseño) |
| `holdout_v3_carlos_silva_stop_foso_seguridad` | **safety_critical** | [9] | 8, 50, 43, 8 (ninguna es la página 9) | **No** — top-k de sólo 5 (`bedrock_retrieve_and_generate`) ni siquiera acercó la página 9; la respuesta termina abstiniendo ("no dispone de la página 9") pero cita 4 páginas ajenas y aun así el evaluador viejo la marcó `passed: true` | Igual a N10: la pregunta nombra "página 9" explícitamente — el filtro de la Fase 1 la cubre sin cambios. Verificado con sidecar: `chunk_7.txt.metadata.json` = `page_number: 9, section_identity: "CARLOS SILVA"` — el chunk SÍ existe en el KB, sólo no entró al top-5 |

Con estos 2 sumados a los 4 ya nombrados en el plan, **6 de los 14 casos del holdout v3
(43%) tenían una colisión de página que el evaluador viejo no detectaba** — confirma
literalmente la motivación de la Fase 4 ("así se escondió N10 en 3+ casos que puntuaron
bien", E2/#2 de las decisiones del dueño). Los 8 casos restantes tienen coincidencia
exacta entre cita y `source_pages`.

**Impacto en el diseño, no en el mandato de esta fase:** los 2 casos nuevos no cambian el
mecanismo de la Fase 1 — ambos nombran "página N" en la pregunta, así que el mismo filtro
`equals: page_number` (ya diseñado, sin extensión) los cubre. No hace falta ningún cambio
de código adicional; el hallazgo es evidencia de que el radio de impacto de N10 es MAYOR
al documentado originalmente (6/14, no 4/14), lo cual **refuerza** la prioridad de la
Fase 1 pero no cambia su diseño. Éste NO es "lo único que falta para precisión óptima":
sigue habiendo un componente de generación (N11, Fase 2) y deuda de contaminación de
identidad (N8, fuera de alcance) que la página-pin no toca. Se anota para que la Fase 5
(holdout v4) tenga presente que el patrón "pregunta nombra página, top-k trae un
duplicado o ni siquiera acerca la página" no está limitado a los clusters FAIN/RECOBA y
THYSSEN — también apareció en SISTEL (TW1) y CARLOS SILVA — sin que esto obligue a
ampliar la regla de diseño ya fijada en la Fase 5 (⚠️ ver prompt actualizado de la Fase 5
más abajo).

## Anexo C — Fase 0c: inventario de regex de forma-de-pregunta (2026-08-03, sólo lectura)

| Constante / método | Ubicación | Qué matchea | Qué decide (ruta consumidora) | Fallo ya causado | Riesgo | Ruta de retiro |
|---|---|---|---|---|---|---|
| `FUNCTIONAL_TEST_PATTERNS` | `app/services/rag/deterministic_intent.rb:11-14` | "pruebas funcionales…resultados" / "functional tests…results" | `exhaustive_functional_test_query?` (48-50) → activa el renderer determinístico (no top_k) | Ninguno registrado | Bajo — patrón angosto a propósito (commit `1168092`) | No es prioritario (no es lista de fabricantes) |
| `STOP_WORK_PATTERNS` | `deterministic_intent.rb:16-19` | "comprobaciones…detener el trabajo" / "checks…stop work(ing)" | `stop_work_checklist_query?` (52-54) → renderer determinístico | Ninguno registrado | Bajo | ídem |
| `GENERIC_HARDWARE_PATTERNS` | `deterministic_intent.rb:21-24` | sustantivos genéricos de hardware (leds/cerrojos/enclavamientos/contactos/seguridades) | `ambiguous_hardware_query?` (68-79) → ruta a menú de desambiguación (`AmbiguousModelResponder`) vs. ruta generativa | Ninguno directo (ver `EXPLICIT_EQUIPMENT_PATTERN`/`PAGE_REFERENCE_PATTERN` como escapes) | Medio — es el disparador de la ambigüedad que los otros dos patrones deben apagar | P4 (huecos 4-5): decidir ambigüedad por evidencia divergente entre chunks, no por vocabulario |
| `EXPLICIT_EQUIPMENT_PATTERN` | `deterministic_intent.rb:35-36` | lista de fabricantes/modelo (ALTIUS, ARCA±BASICO/II/III, ORONA, KONE, OTIS, SCHINDLER, SOPREL, THYSSEN(KRUPP), CARLOS SILVA) O `J\d{1,2}` O código alfanumérico genérico | escape de `ambiguous_hardware_query?` — pregunta ya "nombra equipo", no va a desambiguación | **N7** (commit `fb28983`): preguntas safety_critical de bypass ARCA III (J24/J25/J26) se interceptaban por el menú porque ARCA no tiene dígito pegado a letra y los códigos de jumper de una sola letra no matcheaban; fix acotado a la letra "J" (no generalizado — "K" de EDEL K2/K3 debe seguir sin matchear) | **Alto** — lista cerrada de fabricantes; 4 de 6 fabricantes de SEGURIDADES fuera de la lista (hueco 4) | **P4** (bloqueado por Fase 2 de sidecars, ya completa según memoria — reabre la puerta a migrar esto) — identidad de equipo por chunk vía `section_identity`/`canonical_name`, no lista léxica |
| `PAGE_REFERENCE_PATTERN` | `deterministic_intent.rb:41` | "página/pág./page N" | segundo escape de `ambiguous_hardware_query?`; también es la base de extracción de N para el page-pin de la Fase 1 (restricción 6: reutilizar, no duplicar) | Commit `52e75d9`: preguntas tipo "¿cuántos LED hay en la página 26?" caían al menú de desambiguación pese a estar desambiguadas por página (`holdout_page64_table`, `holdout_page26_led_count`) | Bajo ahora (ya corregido); se vuelve un componente activo de retrieval en la Fase 1 | No aplica — se reutiliza, no se retira |
| `EXHAUSTIVE_PATTERNS` | `app/services/rag_retrieval_profile.rb:56-65` | vocabulario de exhaustividad | `exhaustive_query?` → sube `number_of_results` y activa reranking (`bedrock_rag_service.rb:840`) | Ninguno registrado tras `1168092` | Medio — vocabulario cerrado | Fuera de alcance de P4 (no es identidad de equipo) |
| `SAFETY_CRITICAL_PATTERNS` | `rag_retrieval_profile.rb:67-71` | vocabulario de seguridad crítica | `safety_critical_query?` → sube top_k para preguntas de seguridad | **Hueco 6 (DEUDA·P2)**: usa `fuera\s+de\s+servicio` (tolera espacios/saltos) mientras `BedrockRagService#query_safety_directive` (línea 1018) exige el literal `"fuera de servicio"` — con espaciado atípico el top_k sube pero el directive de STOP-WORK no se dispara; test `regex_characterization_test.rb:218-265` está `skip`eado pendiente de P2 | **Alto** — es el mismo patrón que en ciclo 3 Fase 1 no reconoció preguntas de *bypass* (razón de la Fase 3 de este ciclo: guardrail estático en vez de clasificador) | P2 (deuda separada, no P4) — unificar el regex de detección con el literal del directive |
| `COMPARATIVE_PATTERN` | `rag_retrieval_profile.rb:73` | "compara/comparar/diferencias/ambas/las dos/versus" | apaga `structured_mapping_query?` (120) | Ninguno registrado | Bajo | No aplica |
| `SCHEMATIC_DESIGNATOR_PATTERN` / `SCHEMATIC_KEYWORD_PATTERN` | `rag_retrieval_profile.rb:137-138` | designador tipo `-XX999` + vocabulario de esquema (conector/borne/etiqueta/plano/mazo/cable) | `schematic_block_query?` (141-142) → ruta de bloque esquemático | Ninguno registrado (commit `9c47822`) | Bajo | No aplica |
| `Rag::EvidenceCandidateSelector::STATE_PATTERN` / `CONNECTION_PATTERN` | `app/services/rag/evidence_candidate_selector.rb:45-46` | vocabulario de estado/conexión | `relations_covered_for` (357-362) → contrato de relaciones respondidas/abstenidas | Ninguno registrado tras `2d1e141` (que ya documentó 2 defectos "paso F") | Medio | Fuera de alcance P4 (no es identidad de equipo, es cobertura de relación) |
| `FUNCTION_STOPWORDS` | `evidence_candidate_selector.rb:54-58` | stopwords de función | filtra `function_keywords` (237-248) usados en matching inverso de evidencia | Ninguno registrado | Bajo | No aplica |
| `BedrockRagService#query_names_different_document?` | `bedrock_rag_service.rb:1345-1365` (+ `SHORT_QUERY_MAX_CHARS = 60` línea 1344) | nombre propio tipo `[A-Z][a-zA-Z0-9]{3,}…` o longitud de pregunta | si aplica el filtro de `entity_s3_uris` pineado de la sesión en `query()` (191) y `retrieve_chunks()` (472) | Ninguno registrado; comentario 166-168 documenta que el chequeo de nombre explícito corre ANTES que el de longitud a propósito ("Que es el Esquema SOPREL?" no debe filtrarse mal) | Medio | Fuera de alcance P4 |
| `BedrockRagService#bedrock_no_results?` (`BEDROCK_NO_RESULTS_PATTERN`, línea 20) | `bedrock_rag_service.rb:889-891` | texto canned de rechazo de Bedrock ("I'm sorry…", "sorry, unable to assist/help") | decide retry sin filtro (232) y distingue `canned_with_retrieval` (322-331) | Ninguno registrado | Bajo — matchea texto de Bedrock, no forma de la pregunta del usuario | No aplica (no es regex de forma-de-pregunta del lado usuario) |

**Huecos 4-5 de `regex_characterization_test.rb` (deuda `P4`, verbatim):**
- Hueco 4 (líneas 122-190), comentario 146-147: *"DEUDA · P4 (bloqueado por Fase 2) — la
  ambiguedad debe decidirse por evidencia divergente, no por vocabulario faltante."* Cubre:
  8 reformulaciones que nombran el equipo pero igual se rutean a desambiguación; el modelo
  "TOKIBAT 2007" no satisface `EXPLICIT_EQUIPMENT_PATTERN` por sí mismo; 4 de 6 fabricantes
  de SEGURIDADES no están en la lista del patrón.
- Hueco 5 (líneas 192-212), comentario 201-202: *"DEUDA · P4 — la etiqueta de una opcion
  no puede depender de la forma lexica del texto; debe venir de metadata de seccion."*
  Cubre puntos ciegos de `Rag::AmbiguousModelResponder::MODEL_PATTERN` (ALTIUS, ENIER,
  ELECMEGON, CTA, Thyssen Serie E, NE 300 - LB II, MICONIC LX, SMART 001, TOKIBAT 2007) y
  pérdida de sufijo de versión ("EM4000 V1" → "EM4000").
- Docstring de la clase (líneas 10-21): *"Los bloques marcados DEUDA documentan un
  defecto medido. NO se 'arreglan' aquí… P4 → identidad de equipo desde metadata
  (bloqueado por Fase 2)."* Fase 2 de sidecars (`section_identity`/`canonical_name`) ya
  está completa según [[project_seguridades_v2_fase2_backfill]] (confirmado
  2026-08-03) — **P4 queda desbloqueada para un futuro ciclo**, no éste (fuera de mandato:
  ver "Qué NO está en este plan").

**Conclusión de la intuición del dueño (E5, reconfirmada):** el riesgo real de regex está
concentrado en `EXPLICIT_EQUIPMENT_PATTERN` (lista cerrada de fabricantes, causó N7) y en
el desalineamiento `SAFETY_CRITICAL_PATTERNS`/`query_safety_directive` (hueco 6, P2) — no
en la mayoría de los otros patrones, que son angostos y no han causado fallos medidos.
Ninguno de los dos requiere tocarse en este ciclo (restricción 6); quedan documentados
como deuda con ruta de retiro (P4 y P2 respectivamente) para el dueño.

## Anexo A — Prompt de arranque por fase

**Pie común (añadir al final de cada prompt):**

> Lee primero `docs/rag/plan_ciclo4_ajuste_final_2026-08-03.md` completo (tabla de
> Estado, hallazgos E1-E7 y los N8-N11 heredados del ciclo 3) y la fila de Estado de la
> fase anterior. Restricciones: sin regex nuevo de forma-de-pregunta (restricción 6);
> cero re-ingesta; nada llama a la API de Anthropic desde la app; artefactos a tmp LOCAL
> + SHA256 antes de cerrar (restricción 7); sesión corta, un objetivo, sin fan-out de
> subagentes. Los holdouts v1, v2 y v3 están gastados: no los reabras ni con
> `RAG_SEGURIDADES_CASE_IDS`. Antes de cerrar aplica el Protocolo de plan vivo v2:
> actualiza tu fila de Estado, corrige las fases posteriores afectadas, actualiza el
> prompt de la fase siguiente en este Anexo (márcalo `⚠️ CRÍTICO:` si cambia su
> implementación), actualiza la memoria del proyecto, y commitea todo en el mismo commit.

### Fase 0 — Sonnet 5

> Ejecuta 0a/0b/0c del plan. 0a: rescata
> `tmp/rag_seguridades_holdout_v3_run1_2026-08-03.json` del contenedor
> (`bundle exec kamal app exec --reuse -r web "cat …"` a local), verifica SHA256
> `b4e4b8927a0f6d9491f3e4c9ac88f6c6a8ae8f3f24b7002e95f445e5d1b7659e`; si se perdió,
> anótalo en Estado y 0b degrada a ≤6 sondas retrieve declaradas antes de correrlas.
> 0b: por cada caso N10 (`holdout_v3_fain_em66_sk0_h40` esperada 76→citó 78;
> `holdout_v3_thyssen_divisor_cmc4` 92→97; `holdout_v3_fain_ekm1000_potenciometros_comparativa`
> 46→79; `holdout_v3_fain_jumper_falta_fase_seguridad` 46→79) responde con el artefacto:
> ¿el chunk de la página esperada entró al top-k y perdió, o nunca entró? Salida: tabla
> que decide el mecanismo de la Fase 1 (re-rank local vs filtro Bedrock; default:
> filtro). Para `holdout_v3_sistel_spm_ambigua`: ¿había chunks de TW1 en
> `retrieved_chunks`? Si no, N11 tiene componente de recall — escálalo antes de que la
> Fase 2 asuma que el flag basta. 0c: inventario documental de regex de forma-de-pregunta
> (tabla como anexo de este documento; semilla en la Fase 0 del plan). $0 Bedrock salvo
> degradación declarada. NO arregles nada en esta fase.

### Fase 1 — Sonnet 5

> ⚠️ CRÍTICO: `page_number` es ENTERO en los sidecars — el `equals` del filtro debe usar
> valor numérico, no string (E2). El filtro vive en `build_vector_search_configuration`
> (`app/services/bedrock_rag_service.rb:111-136`) y cubre `query()` y `retrieve_chunks()`
> a la vez (E4) — no lo dupliques por ruta. Reutiliza
> `Rag::DeterministicIntent::PAGE_REFERENCE_PATTERN` para detectar "página N" y extrae N
> del propio match — no escribas un patrón nuevo (restricción 6). Ponlo detrás de flag
> (`RAG_PAGE_PIN_ENABLED`, patrón de `structured_evidence_route_flag.rb`) y actívalo sólo
> con UNA página nombrada (rango/varias → sin filtro, anota el límite). ⚠️ CRÍTICO —
> veredicto YA CERRADO de la Fase 0b (Anexo B, 2026-08-03): **filtro Bedrock, NO re-rank
> local** — en 2 de los 4 casos N10 nombrados (THYSSEN p.92, FAIN p.46-comparativa) Y en 1
> de 2 casos adicionales hallados en un barrido completo de los 14 casos del v3 (CARLOS
> SILVA p.9, safety_critical) la página esperada NUNCA entró al conjunto recuperado por
> Bedrock — ningún re-rank posterior puede arreglar un candidato que no existe en la lista
> a reordenar. No evalúes re-rank como alternativa: implementa el filtro directamente.
> Declara hipótesis (§8.3) y resultado
> esperado si es falsa. Verificación: tests unitarios del builder ($0: estructura del
> filtro con/sin página, flag on/off, valor entero) MÁS 3-4 preguntas ad-hoc NUEVAS sobre
> los clusters duplicados (páginas 46/76/79 y 92/97, hechos distintos a v3), before/after
> UNA sola vez, ≤8 llamadas Bedrock en total, artefacto completo a tmp local + SHA256.
> Documenta la degradación (0 resultados → retry sin filtro en `query()`, abstención en
> la ruta estructurada).

### Fase 2 — Sonnet 5

> ⚠️ CRÍTICO (hallazgo de la Fase 1, 2026-08-03): `config/deploy.yml` está
> **gitignored** (commit `8c7e376`, "keep deploy config and DB secrets out of
> version control") — vive sólo en el checkout local de la máquina, NO viaja
> con `git commit`/`git clone`. La Fase 1 encendió `RAG_PAGE_PIN_ENABLED:
> "true"` ahí y ya desplegó a PROD (`kamal deploy`, SHA
> `0051b5ba13e8500a3127778a335a780ec926dff1`, ver Estado y Anexo E). **Antes
> de tu propio `kamal deploy`** (lo vas a necesitar para probar tu flag en
> vivo con las ≤4 llamadas de verificación dirigida): confirma con `grep
> RAG_PAGE_PIN_ENABLED config/deploy.yml` que la línea sigue presente en TU
> checkout — si trabajas desde un checkout distinto al de esta sesión (otra
> máquina, clon nuevo), esa línea NO estará y tu deploy apagaría el page-pin
> sin que ningún test lo detecte (no hay test que lea el `config/deploy.yml`
> real, sólo los de `Rag::PagePinFlag` sobre `ENV`). Añade tu propia línea
> `RAG_FAMILY_AMBIGUITY_GUARD_ENABLED: "true"` AL LADO de la de page-pin, sin
> tocarla. El patrón de esta Fase 1 (deploy interino de la propia fase para
> su propia verificación en vivo, sin esperar al checkpoint consolidado de
> la Fase 6) es el que se espera que repitas.
>
> ⚠️ CRÍTICO: el código de N11 ya existe — NO lo reescribas ni lo "mejores".
> `Rag::FamilyAmbiguityDetector` + `add_named_board_coverage`
> (`app/services/rag/structured_evidence_route.rb:363-457`) se escribieron para el caso
> multi-placa y están apagados porque `RAG_FAMILY_AMBIGUITY_GUARD_ENABLED` no está en
> `config/deploy.yml` (E1). Tu cambio es UNA línea en deploy.yml. Antes de encender:
> verifica que ningún test congelado espera el flag apagado (comentario D5 en
> `structured_evidence_route.rb:430-432` — confirmar que es sólo histórico). Corre las
> suites de `family_ambiguity_detector` y `structured_evidence_route` ($0). Verificación
> dirigida: 1-2 preguntas ad-hoc multi-placa NUEVAS (≤4 llamadas): espera
> `generation_chunks ≥ 2` y respuesta que enumera por familia y pregunta cuál placa es
> (la `multi_family_directive` ya existe). Artefacto a local + SHA256. ⚠️ CRÍTICO —
> veredicto YA CERRADO de la Fase 0b (Anexo B, 2026-08-03): `holdout_v3_sistel_spm_ambigua`
> NO tiene componente de recall — se verificó el CUERPO (no sólo aliases) de los 12 chunks
> recuperados y el chunk de rank 2 (página 89, TW1) ya contenía literalmente la tabla con
> el LED SPM que la respuesta necesitaba; el modelo lo tuvo en contexto y aun así declaró
> que no existía. El fallo es 100% de cobertura de generación — procede con el flag sin
> escalar, no hace falta ninguna verificación de recall adicional antes de encender.

### Fase 3 — Sonnet 5

> Guardrail del piloto (decisión #8, componente A): aviso estático de verificación en
> TODAS las respuestas del chat web, en la capa de presentación
> (`app/javascript/rag/answer_presenter.js` / host del mensaje del asistente en
> `rag_chat_controller.js`) + copy i18n es/en (tono: "verifica cualquier acción sobre
> seguridades contra el manual antes de ejecutarla"). PROHIBIDO: (a) clasificador por
> pregunta — sería regex nuevo de forma-de-pregunta (restricción 6) y
> `safety_critical_query?` ya demostró no reconocer bypass (ciclo 3 Fase 1); (b)
> concatenar el aviso al string `answer` del JSON — contaminaría el gate y los artefactos
> (E7). Test que verifica ambas cosas: el aviso aparece con cada respuesta; `answer` no
> lo contiene. $0 Bedrock.

### Fase 4 — Sonnet 5

> Nota (Fase 3, 2026-08-03, no cambia tu implementación): el guardrail de la Fase 3
> es presentación pura (`app/javascript/rag/answer_presenter.js` +
> `rag_chat_controller.js`), no toca `Rag::BenchmarkRubricEvaluator` ni el JSON que
> consume el evaluador — `data.answer`/`citations[].page` que tú vas a leer llegan
> exactamente igual que antes (verificado con test: `formatAnswerForWeb`, la única
> función que deriva HTML de `answer`, nunca contiene el aviso). Sin impacto en tu
> mandato.
>
> Evaluador v2: añade el check `source_page_cited` a `Rag::BenchmarkRubricEvaluator`
> (`app/services/rag/benchmark_rubric_evaluator.rb`) — pasa si alguna cita del resultado
> tiene `page` ∈ `source_pages` del caso. Las citas del artefacto ya llevan `page` entero
> (E6, `citation_processor.rb:84-91`); fallback: parsear " — p. N" del `title` si `page`
> es nil. Activación: campo de fixture `source_page_required`, default `true` si el caso
> trae `source_pages` no vacío, apagable por caso. Semántica: afecta `passed` como
> `citation_passed`; NO cambies la fórmula de score (comparabilidad numérica con v3, N4
> intacto: `PENALTY_WEIGHTS` no se toca). Tests con payloads sintéticos: página correcta
> / página del duplicado / `page` nil con title parseable / sin citas /
> `source_page_required: false`. $0 Bedrock. Esta fase va ANTES de congelar el v4 — el QA
> del holdout ejercitará tu check.

### Fase 5 — Sonnet 5 (sesión nueva; si participaste en las Fases 1-4, detente: lo redacta otra sesión)

> ⚠️ CRÍTICO: (a) el fix N10 ancla el retrieval a la página nombrada — tus casos DEBEN
> nombrar "página N" para medirlo, y ≥4 casos van sobre los clusters duplicados
> FAIN/RECOBA (págs. 46, 76-79) y THYSSEN (92/97) con hechos DISTINTOS a los del v3;
> (b) el flag N11 está encendido — incluye 1 caso multi-placa (hecho distinto a SPM
> TW1/DELTA+ del v3); (c) el evaluador ahora verifica página citada — pon
> `source_page_required` conscientemente por caso (true obligatorio en los 4 de
> seguridad; false donde no aplique, p.ej. sin_respaldo **o tu caso `ambigua` si la
> respuesta correcta es un menú de desambiguación que cita páginas de ejemplo NO
> relacionadas con `source_pages` — ver hallazgo Fase 4 en Estado: 2 casos reales de
> fixtures anteriores a v3 con esa forma de respuesta necesitaron `false` porque el
> evaluador v2 los marcaba como falsa colisión N10 cuando en realidad es el
> comportamiento correcto de "pide que el técnico elija placa"; si tu caso `ambigua`
> SÍ ancla a una placa/página concreta en su respuesta correcta, deja el default
> `true`**); (d) N8 sigue vivo (96/97 cuerpos dicen "ALJO") — no exijas marca correcta
> fuera de ALJO págs. 2-7 y divisoras limpias; (e) N9 corregido: el guion de benchmark
> no invoca `DeterministicRenderer` NI `DocumentOverviewResponder` — checklist/prueba
> funcional van por la ruta genérica; (f) verifica los 14 offline ($0) con
> `Rag::DeterministicIntent.ambiguous_hardware_query? == false` antes de congelar;
> (g) bypass J de pág. 65 sólo J12 o J26 (J24 gastado en v3, J25 en v2). (h) El campo
> `page` de una cita, cuando está presente, ya es el más confiable (E6); el evaluador
> también acepta `citation["metadata"]["page_number"]` y el parseo de `" p. N"` del
> `title` como fallbacks — no necesitas construir citas sintéticas con una forma
> particular en tu QA test, cualquiera de los tres funciona.
>
> Nota informativa de la Fase 0b (Anexo B, no cambia (a)-(g)): un barrido de los 14 casos
> completos del v3 (no sólo los 4 nombrados como N10) encontró 2 colisiones de página
> adicionales que el evaluador viejo no detectó — una en SISTEL (TW1, p.88/89) y una
> **safety_critical** en CARLOS SILVA (p.9, stop_work_checklist, top-k de sólo 5 nunca
> acercó la página). El mecanismo sigue siendo el mismo filtro de página de la Fase 1 —
> esto no amplía la regla (a): sólo evidencia que el patrón "pregunta nombra página, top-k
> no la trae" no está limitado a FAIN/RECOBA/THYSSEN. No hace falta que tus casos cubran
> SISTEL/CARLOS SILVA explícitamente, pero si te resulta natural, un caso de seguridad
> sobre un cluster distinto a los ya exigidos añade señal.
>
> Redacta y congela `script/fixtures/rag_seguridades_holdout_v4.json`: 14 preguntas desde
> la verdad-terreno pagada (Gate A §5-§9 + los 97 cuerpos), distribución 3 determinísticas
> / 2 mapeos estructurados / 2 generalización / 1 ambigua / 1 sin respaldo / 4 seguridad
> / 1 comparativa, formato del v3 + campo `source_page_required`. Los 4 de seguridad:
> `severity: safety_critical` a nivel de caso y patrones `penalized` con
> `severity: critical` (N4). QA obligatorio: test clonado de
> `benchmark_rubric_evaluator_holdout_v3_qa_test.rb` (tally, suma real con la fórmula del
> evaluador, `passing_score = ceil(80%)`, cobertura de ids, respuesta correcta conocida
> por caso con cita sintética de página correcta, ningún penalized dispara,
> no-reutilización contra v1+v2+v3, assertions del check de página). Prohibido: ventanas
> `.{0,N}` que crucen ítems; lookaheads sin el "no" pospuesto; corregir erratas del
> documento en los required (verbatims de Gate A §9). NO lo corras contra Bedrock: se
> abre una sola vez en la Fase 7.

### Fase 6 — Sonnet 5 (NO Haiku)

> Nota (Fase 5, 2026-08-03, no cambia tu implementación): el holdout v4 quedó congelado en
> `script/fixtures/rag_seguridades_holdout_v4.json` (14 casos, ver fila de Estado de la
> Fase 5 para el detalle de cobertura N10/N11). No lo abras en esta fase — sigue siendo
> exclusivo de la Fase 7. Tu checkpoint de despliegue es independiente del contenido del
> fixture.
>
> ⚠️ CRÍTICO: usa SIEMPRE `--role web` (o `-r web`) en `kamal app exec` — sin él corre en
> web+worker y duplica el gasto (lección ciclo 3 Fase 4, donde el humo costó 2 llamadas).
> Checkpoint previo al gate: Fases 1-4 commiteadas con tests verdes; `kamal deploy`; SHA
> desplegado == HEAD verificado con `kamal app version`; NO hay resync de KB en este
> ciclo (confirma que el job vigente sigue siendo `ZGCU99ISK5`, `COMPLETE`). Humo: 1
> llamada, pregunta nueva fuera de todo holdout QUE NOMBRE UNA PÁGINA, para ejercitar el
> page-pin — la cita debe ser de esa página exacta. Aurora caliente (`kb_retrieve` < 1s,
> sin `AuroraColdStartRetry`). Anota en Estado: SHA, timestamp, evidencia del humo (a tmp
> local + SHA256). NO abras el holdout v4: eso es la Fase 7.

### Fase 7 — Sonnet 5 (NO Haiku)

> Nota (Fase 6, 2026-08-04, no cambia tu criterio de gate ni tu implementación): el
> checkpoint de despliegue quedó verificado — ver fila de Estado de la Fase 6 para el
> detalle completo. Resumen para no tener que re-verificar: SHA desplegado y HEAD
> coinciden en `270c6387dbfa66c3d1ad477a154ef309126ae8bd` (verificado con `kamal app
> version`); Fases 1-4 commiteadas con `bin/rails test` verde (2260/0/0/189, sin
> regresión); KB sin resync (`ZGCU99ISK5` sigue `COMPLETE` y es el job más reciente);
> humo de 1 llamada con page-pin confirmado activo (`cited_pages: [40]`,
> `page_pin_exact_match: true`) y Aurora caliente (`kb_retrieve latency_ms: 549`, sin
> `[Aurora]` cold-start). Antes de correr el gate, confirma con `git rev-parse HEAD`
> que sigue siendo `270c638` en tu checkout — si hay commits nuevos entre esta sesión
> y la tuya (p.ej. otra corrección de plan vivo), el checkpoint de despliegue no cubre
> ese código nuevo y habría que repetir la Fase 6 antes de abrir el holdout v4 (regla
> permanente de la Fase 6: nunca se abre un holdout con cambios sin desplegar).
>
> Nota (Fase 5, 2026-08-03, no cambia tu criterio de gate ni tu implementación): el
> fixture congelado tiene `source_page_required: true` en los 14 casos, no sólo en los 4
> `safety_critical` — fue deliberado (ver fila de Estado de la Fase 5): cada respuesta
> correcta ancla a una página concreta de `source_pages`, ninguno de los 14 es un menú de
> desambiguación. Esto significa que el artefacto de salida traerá `source_page_cited` para
> los 14 casos, no sólo los 4 que gatean el criterio congelado — útil como señal de
> diagnóstico adicional si el gate no pasa (clasificación de fallos), pero **no cambia el
> criterio de aprobación ya fijado** (≥80% de la suma real Y cero fallos en los 4
> `safety_critical` Y `source_page_cited` verde en esos 4). 7 de los 14 casos nombran
> "página N" para ejercitar el page-pin de la Fase 1 sobre los clusters duplicados exigidos
> por el mandato de la Fase 5; 1 caso es multi-placa para ejercitar el flag de la Fase 2 —
> el detalle de qué casos y qué hechos es deliberadamente sólo del fixture congelado, no de
> este documento.
>
> Corre el holdout v4 UNA sola vez contra el KB de producción:
> `bundle exec kamal app exec --reuse -r web -p "sh -c 'RAG_SEGURIDADES_RUBRIC=script/fixtures/rag_seguridades_holdout_v4.json RAG_SEGURIDADES_OUTPUT=tmp/rag_seguridades_holdout_v4_run1_<fecha>.json bin/rails runner script/rag_seguridades_benchmark.rb'"`.
> Verifica ANTES que la Fase 6 anotó SHA desplegado y humo verde (si no, detente: no se
> abre un holdout con cambios sin desplegar). Criterio congelado: ≥80% de la suma real Y
> cero fallos en los 4 casos safety_critical Y `source_page_cited` verde en los 4. ANTES
> de cerrar (restricción 7): verifica que el artefacto contiene `results[]` con `chunks`
> y respuestas no vacíos por caso (~1 MB de referencia; 12 KB = corrida inválida), cópialo
> del contenedor a tmp LOCAL y anota su SHA256 en Estado — el del v3 se quedó en el
> contenedor y hubo que rescatarlo (E3). La corrida NO se repite. Pasa → preparar piloto
> con el guardrail de la Fase 3 activo. No pasa → clasifica los fallos (el evaluador v2
> ya expone la página citada), el v4 queda gastado, y PARA: no hay ciclo 5 con esta
> estrategia — escala como decisión humana #9.

## Anexo D — N8: causa raíz confirmada (tarea futura, NO ejecutada en este ciclo)

Investigación de sólo lectura hecha a pedido del dueño durante la sesión de Fase 0 (fuera
del mandato original de 0c, que sólo pedía inventariar regex). **No se tocó código ni se
llamó a ninguna API.** Se documenta aquí como tarea pendiente, no como trabajo de este
ciclo — la restricción 2 ("cero re-ingesta") sigue vigente y N8 sigue fuera de mandato.

**Mecanismo confirmado:** no es un string hardcodeado en Ruby. Es un artefacto del propio
modelo de visión bajo el prompt viejo (contrato `field_records_v5`):
`SingleFileChunkingService` llama primero a la página ancla (p.2, ALJO real) y captura su
`document_name` (`single_file_chunking_service.rb:242`); ese valor se reutiliza a
propósito para las ~96 páginas restantes vía `document_name_hint` (línea 252 →
`BatchChunkingPrompt.page_user_content`, líneas 503/510-521: *"emit the same document_name
across all pages of this document"*). Esto es CORRECTO para el campo JSON de identidad de
ARCHIVO (un compendio multi-marca es "un solo archivo", regla "ONE FILE = ONE IDENTITY").
El bug es que el prompt v5 ADEMÁS le pedía al modelo textualizar ese mismo hint dentro del
CUERPO de cada página como una línea `**Document:** {hint} | Page N | ORIGINAL_FILE_NAME:
PIPELINE_INJECTED | NORMALIZED_FILE_NAME: PIPELINE_INJECTED | SOURCE_URI:
PIPELINE_INJECTED` — así "ALJO Control Level 1B Altius" quedó incrustado en el texto que
el LLM de generación lee, en chunks que no son de ALJO. El prompt actual en el repo (v8)
sigue siendo internamente contradictorio en este punto: su comentario de cabecera dice que
esta marca en el cuerpo es "legacy" reemplazada por la identidad inyectada por Rails, pero
las líneas 293-294 y 305-315 todavía instruyen al modelo a emitirla — **una ingesta nueva
con el prompt actual podría reproducir el mismo defecto** si no se corrige el prompt antes.

**Hallazgo clave — el fix NO requiere re-ingesta ni llamadas a Anthropic:** cada chunk ya
tiene en su sidecar (`page_number`, `section_identity`, `original_filename`,
`original_source_uri`) todo lo necesario para reescribir esa línea con una sustitución de
texto determinística por chunk (la forma de la línea mala es regular y greppeable:
`\*\*Document:\*\* ALJO Control Level 1B Altius \| Page \d+ \| ORIGINAL_FILE_NAME:
PIPELINE_INJECTED.*`). Verificado empíricamente: `chunk_43` tiene
`section_identity: "FAIN"` correcto en su metadata mientras su cuerpo sigue diciendo
"ALJO". El mapeo página→marca ya existe y está verificado 100% contra
`docs/rag/gate_a_medicion_topologia.md` §5.2 (18 páginas divisoras) — no hace falta
recalcularlo. Esto **cambia el costo/riesgo asumido en la restricción 2**: el texto de esa
restricción asume que arreglar N8 exige re-ingesta (bloqueada por el saldo agotado de
Anthropic desde 2026-08-02); esta investigación muestra que un parche dirigido
(sustitución de texto en los 96 cuerpos + re-subida de esos archivos a S3 + resync de KB,
sin volver a llamar al modelo de visión) sí sería viable con el saldo actual.

**Alternativa de mayor alcance (propuesta por el dueño en el chat, no evaluada en
profundidad aquí):** una re-indexación completa manejando 2 versiones (KB v1 = actual,
KB v2 = corregida) permitiría además corregir el prompt v8 contradictorio antes de generar
contenido nuevo, no sólo parchear lo existente — pero esa ruta sí requiere las llamadas de
visión que hoy están bloqueadas por saldo, y coexistir 2 versiones de KB añade complejidad
operacional (routing, comparación, corte). Queda sin decidir.

**No se ejecuta nada de esto en el ciclo 4** (restricción 2 y restricción 5: un objetivo
por sesión). Se anota como tarea para una decisión futura del dueño: parche de texto
dirigido (barato, sin saldo Anthropic) vs. re-indexación completa con 2 versiones (más
caro, corrige también el prompt, requiere saldo).

**Verificación adicional de seguridad del parche (2026-08-03, sólo lectura):** se
confirmó que ningún código de runtime depende de esa línea para funcionar —
`app/services/bedrock/citation_processor.rb:130-159` YA filtra defensivamente estas
líneas (`METADATA_LINE_PATTERN`, `INLINE_METADATA_HEADER_PATTERNS`, literal
`PIPELINE_INJECTED`) antes de construir el excerpt del tooltip de citación, con un
comentario explícito que las llama "Legacy chunk bodies (OWRPGSX6XK Lambda path)". El
usuario confirmó en el chat el origen histórico: la línea era necesaria cuando la
ingesta corría directo contra el data source nativo de Bedrock (con una Lambda de
post-chunking, `OWRPGSX6XK`/`VBB72VKABV`) donde no era viable inyectar metadata
dinámicamente en el prompt; esa estrategia de data source quedó deprecada al migrar a
ingesta vía API de Anthropic directa + inyección de identidad en Rails
(`BatchResultsParserService#identity_header`). Es decir: borrar la línea es seguro para
el código actual — el riesgo real de N8 es sólo el ruido que ve el MODELO DE GENERACIÓN
al leer el cuerpo crudo del chunk, no algo que la app parsee o dependa de mantener.

**Decisión del dueño (2026-08-03, en el chat de la sesión de Fase 0):** diferir la
ejecución de N8. Prioridad recomendada: **media, secuenciada DESPUÉS del cierre del
ciclo 4** (después de la Fase 7 / resultado del gate v4), no en paralelo. Motivos: (1) no
bloquea el criterio del gate v4 actual; (2) el downstream visible al técnico ya está
defendido (citation_processor); (3) parchearlo a mitad de ciclo invalida los rankings
medidos en el Anexo B (cambiar el texto de 96 chunks cambia sus embeddings) justo cuando
la Fase 1 necesita esos números estables.

**Hipótesis de rebote a N10 — probada y DESCARTADA (2026-08-03):** se especuló que el
ruido semántico compartido de "ALJO Control Level 1B Altius" en 96/97 cuerpos pudiera
contribuir a que páginas casi-duplicadas compitan por score en el retrieval. Se verificó
contra el único chunk que NO tiene la contaminación: `chunk_90.txt` (página 92, divisor
THYSSEN) — es precisamente el chunk que falló en `holdout_v3_thyssen_divisor_cmc4` (nunca
entró al top-k). Su cuerpo real (695 bytes, verbatim en `tmp/seguridades_chunks_2026-07-28/chunk_90.txt`)
es casi vacío: una lista de series de equipo y la nota "esta página… no contiene
procedimientos, valores técnicos, esquemas ni resultados de prueba" — la causa de su
fallo es sparsity de contenido (página divisoria pobre en texto), NO N8. Además, en los
casos donde la página esperada SÍ entró al top-k pero perdió contra un duplicado (FAIN
p.76 vs p.78), AMBOS chunks en competencia comparten la MISMA línea "ALJO…" —una señal
idéntica en ambos candidatos no puede ser lo que hace que uno gane sobre el otro. **N8 no
tiene efecto medible sobre el retrieval**; su riesgo real sigue siendo únicamente el
ruido que lee el modelo de generación (razón original de N8, sin cambios). Esto BAJA la
urgencia de N8 (ya no hay un beneficio esperado de rebote a N10) sin cambiar su
prioridad de fondo (media, post-ciclo). **Recomendación de secuencia:** ejecutar el
parche de texto dirigido como primer ítem post-piloto (si la Fase 7 pasa) o junto con la
decisión humana #9 (si la Fase 7 no pasa) — nunca antes de cerrar este ciclo.

**Hallazgo colateral, no accionado (divisor thinness):** las páginas divisorias con poco
texto (como la p.92 THYSSEN) pueden perder por embedding débil frente a preguntas
técnicas específicas, independientemente de N8 y de N10. El page-pin de la Fase 1 ya lo
resuelve para el caso medido (fuerza la recuperación de la página nombrada sin depender
de score), así que no requiere trabajo adicional en este ciclo — se anota por si
reaparece en páginas divisorias no cubiertas por el filtro de página.

**Actualización 2026-08-04 (corroboración independiente, sesión externa a Fase 1/2, sólo
lectura — no se tocó código ni se ejecutó nada de N8):** un segundo diagnóstico llegó a
la misma causa raíz por su cuenta y añade dos precisiones que no estaban en este Anexo:

1. **Atribución de commits más precisa.** `844692f` (2026-05-08, creación de
   `batch_chunking_prompt.rb`) ya incluye desde el primer commit la instrucción de emitir
   la línea `**Document:**` dentro de cada chunk (línea ~293 hoy). `cc453f1` (2026-05-17)
   agrega el comentario de cabecera que llama a esto "legacy"/reemplazado por la
   inyección de Rails — pero nunca borra la instrucción. El comentario quedó
   desincronizado del código desde el día en que se escribió. SEGURIDADES se ingesta
   `2026-07-26` (`25ebf66`), más de dos meses después, por la ruta moderna
   (`ingestion_path: "web_v1"`) — confirma lo que este Anexo ya decía (líneas 656-660):
   **no es deuda dormida de la Lambda `OWRPGSX6XK`, es un bug activo en el prompt que usa
   TODA ingesta nueva hoy**, se reproducirá en cualquier documento futuro mientras no se
   corrija `batch_chunking_prompt.rb`, independientemente de si se toca SEGURIDADES.
2. **Costo recurrente cuantificado, no sólo de precisión.** La línea (~42 tokens) va al
   modelo de GENERACIÓN en cada consulta que recupere un chunk contaminado, no es un
   costo de ingesta única. Con `structured_evidence_route` trayendo típicamente 10-12
   chunks por pregunta (casi todos contaminados en este documento), son ~400-500 tokens
   extra de input por respuesta, para siempre, hasta corregirse — un impuesto permanente
   en vez de un costo hundido.

**Barrido de corroboración (mismo diagnóstico, verificado):** conteo de frecuencia de
líneas repetidas en los 97 cuerpos reales (backup local coincide byte a byte con el
contenido vivo del 3 de agosto). Los bloques `FIELD_RECORD:`/`RECORD_TYPE:`/`EVIDENCE:`/
`EXPECTED_RESULT:`/`END_FIELD_RECORD` que más se repiten NO son ruido — cada bloque tiene
un `RECORD_ID` único y valores específicos de esa página/componente (contenido
estructurado legítimo, citable). La única instancia real de "boilerplate universal sin
valor" en todo el corpus sigue siendo la línea de N8 — **defecto aislado, no una familia
de bugs**; no se buscan más candidatos de este tipo.

**No cambia la decisión de secuencia ya tomada** (parche de texto dirigido a los 96
cuerpos vivos espera al cierre del ciclo — no se toca a mitad de la Fase 1/2 para no
invalidar los rankings del Anexo B). **Sí abre una pregunta nueva, sin decidir, para el
dueño:** dado que el costo de tokens es recurrente (no sólo precisión) y el fix del
prompt (`batch_chunking_prompt.rb`, borrar la instrucción de la línea ~293-315) es
código puro sin riesgo de datos ni re-ingesta, ¿tiene sentido desacoplarlo del parche de
los 96 chunks vivos y aplicarlo ANTES del cierre del ciclo 4 (previene que se reproduzca
en cualquier ingesta nueva mientras tanto), aunque el parche de datos siga esperando? No
ejecutado en esta sesión (restricción 5: un objetivo por sesión — el objetivo de esta
sesión fue la Fase 2/N11).

### Síntesis: ¿dónde están los puntos de pérdida de precisión?

| Hallazgo | Etapa del pipeline | Mecanismo | Estado |
|---|---|---|---|
| N7 (ARCA/J bypass mal enrutado) | Clasificación de intención (regex de forma-de-pregunta) | `EXPLICIT_EQUIPMENT_PATTERN` no reconocía ARCA ni jumpers de 1 letra | **Corregido** ciclo 3 Fase 2 (`fb28983`) |
| N8 (identidad ALJO en 96/97 cuerpos) | **Ingesta / cuerpo del chunk** (no metadata, no retrieval, no generación) | Hint de `document_name` de la página ancla textualizado por el modelo de visión en cada página, bajo prompt v5 | **Diagnosticado** (Anexo D), NO ejecutado — deuda con dueño, decisión pendiente |
| N9 (guion de benchmark salta 2 pasos de producción) | Arnés de benchmark, no producción | El script no invoca `DocumentOverviewResponder` ni `Rag::DeterministicRenderer` | Documentado y corregido en redacción; sin mandato de código este ciclo |
| N10 (colisión de página con duplicado casi calcado) | **Retrieval** (ranking/filtro de Bedrock) | Página nombrada explícitamente no gana por score contra su casi-duplicado, o ni siquiera entra al top-k | Mecanismo confirmado (Anexo B) — fix en Fase 1 de este ciclo (page-pin) |
| N11 (cobertura multi-placa, LED SPM SISTEL) | **Generación** (no retrieval — confirmado en Anexo B) | El chunk correcto está en el top-k pero el prompt de generación no fuerza cobertura de ambas familias nombradas | Fix ya escrito, apagado por flag — Fase 2 de este ciclo lo enciende |
| Hueco 6 (`SAFETY_CRITICAL_PATTERNS` vs. `query_safety_directive`) | Clasificación de intención (regex) | Un patrón tolera espacios/saltos de línea, el otro exige el literal exacto — con espaciado atípico el top_k sube pero el directive de STOP-WORK no se dispara | Documentado (Anexo C, deuda P2), no ejecutado este ciclo |

Cuatro de los seis puntos de pérdida ya tienen mecanismo confirmado y ruta de fix (N7 ya
resuelto; N10/N11 resueltos en las Fases 1-2 de este ciclo). Los dos que quedan sin
ejecutar (N8, Hueco 6/P2) no requieren re-ingesta con saldo Anthropic tan urgentemente
como se asumía — pero siguen fuera del mandato de ciclo 4 por la restricción de "un
objetivo por sesión" (restricción 5), no porque sean técnicamente imposibles con el saldo
actual.

## Anexo E — Fase 1: verificación empírica del page-pin (2026-08-03)

Hipótesis (§8.3, declarada en la Fase 1): un `equals: page_number` (entero)
en AND con el filtro de cuenta/documento hace que Bedrock devuelva la página
nombrada explícitamente en la pregunta en vez de dejarla competir por score
contra su casi-duplicado. Resultado esperado si es falsa: las sondas ad-hoc
seguirían citando el duplicado o sin encontrar la página en absoluto.

**Método:** 4 preguntas ad-hoc NUEVAS (no reutilizadas de v1/v2/v3),
2 por cluster duplicado (FAIN/RECOBA 46/76/79, THYSSEN 92/97), vía
`script/rag_page_pin_probe.rb` (calcado de `rag_seguridades_recall_probe.rb`,
sólo `retrieve_chunks` — sin generación, mide ranking, no calidad de
respuesta). `top_k=12` (mismo top_k que la ruta estructurada del v3).
"Before" corrió contra el código desplegado ANTES de esta fase (commit
`afd8862`, ciclo 3 Fase 3 — sin page-pin, mecanismo inexistente); "after"
corrió después de `kamal deploy` de esta fase (commit `0051b5b`). 8 llamadas
`Retrieve` en total (4+4), dentro del techo declarado de ≤8. `retrieve` (no
`retrieve_and_generate`) — no genera tokens de modelo, coste marginal.

| Caso | Página nombrada | Rank antes (top1 antes) | Rank después (top1 después) |
|---|---|---|---|
| `fain_pagina_76_terminal` | 76 | 11/12 (top1 = 94) | **1/12** (top1 = 76) |
| `fain_pagina_46_procedimiento` | 46 | **no entró al top-12** (top1 = 60) | **1/12** (top1 = 46) |
| `thyssen_pagina_92_indicador` | 92 | 11/12 (top1 = 7) | **1/12** (top1 = 92) |
| `thyssen_pagina_97_tabla` | 97 | 1/12 (ya ganaba sin fix) | 1/12 (sin cambio, esperado) |

**Veredicto: hipótesis CONFIRMADA, no falsada.** Los 3 casos que fallaban
antes (76, 46, 92 — exactamente el patrón N10: página nombrada enterrada o
ausente del top-k) pasan a rank 1/12 exacto con el flag encendido, incluido
el caso más severo (`página 46`, que ni siquiera entraba al top-12 antes —
el escenario donde Anexo B ya había descartado el re-rank local como
mecanismo viable). El cuarto caso (97, el lado "ganador" del duplicado
92/97) no necesitaba el fix y no cambió — comportamiento esperado, no una
regresión. Ningún caso degradó a 0 resultados (la rama de retry-sin-filtro
en `query()` y la abstención `DATA_NOT_AVAILABLE` de la ruta estructurada
quedan sin ejercitar por esta verificación — no hubo 0-resultados que las
disparara; se harán ejercitar naturalmente si algún caso del holdout v4
nombra una página sin contenido, como `holdout_v3_carlos_silva_stop_foso_seguridad`
del Anexo B).

Artefactos completos (antes/después, con `vector_search_configuration` por
caso) en `tmp/rag_page_pin_probe_before_2026-08-03.json` (SHA256
`936dec845406b80b7fc9edb375aaafb18215c74e0790b0331768a402dfa339a9`) y
`tmp/rag_page_pin_probe_after_2026-08-03.json` (SHA256
`62f3ecf08a07ee9b00cd733adbe33c89a630aaa51a557ffe99487d8f9626f9c2`).

## Anexo F — Fase 7: clasificación de los 3 fallos del gate v4 (2026-08-04)

Los 3 casos con `passed: false` en `tmp/rag_seguridades_holdout_v4_run1_2026-08-04.json`
(SHA256 `5be0fcc5e14eef28e8803e2dd626fec606aec8f83422a336e39e2f0b8c893949`), con causa
distinguida entre defecto real de retrieval/generación vs. falso negativo del evaluador
regex (el evaluador v2 de la Fase 4 expone `citations[].page` por caso, tal como preveía
la nota de la Fase 6 en el prompt de esta fase):

### 1. `holdout_v4_carlos_silva_tpr70_b7_seguridad` (safety_critical) — el que rompe el gate

**Score 11/13, `source_page_cited: true` (p.11 correcta), pero `passed: false`** por el
único `required` que no matcheó: *"declara que el orden de la cadena no está documentado /
requiere verificación"*, patrón `REQUIRES_FIELD_VERIFICATION|no (?:imprime|documenta|
especifica) (?:esa secuencia|el orden)|requiere verificaci[oó]n (?:en )?(?:el )?campo`.

Respuesta real del modelo (verbatim, citación `CARLOS SILVA — p. 11`, `chunk_9.txt`):
*"Sin embargo, **el orden exacto de esta cadena en serie no está documentado de forma
legible en el diagrama**. El documento indica que estos cuatro componentes pasan por un
mismo hilo en serie en los terminales 1–2, pero **no imprime la secuencia textual** ni
especifica cuál es el punto de inicio y cuál es el de retorno. Por lo tanto, **Verificar
en campo o en el esquema completo** — debe verificarse directamente en el diagrama físico
o en el equipo antes de desconectar cualquier cable."*

**Veredicto: falso negativo del evaluador regex, NO un defecto de retrieval/generación.**
La respuesta declara exactamente lo que el `required` pide — abstención correcta sobre el
orden de la cadena y remisión a verificación en campo antes de desconectar un cable, el
comportamiento más seguro posible para este caso `stop_work_checklist` — pero con
fraseo que el patrón no cubre: dice *"no imprime **la secuencia textual**"* (el patrón
exige *"esa secuencia"* o *"el orden"* literal después de "no imprime/documenta/
especifica") y *"**Verificar** en campo"* en imperativo (el patrón exige *"requiere
**verificación** (en) (el) campo"*, sustantivo). Ningún `penalized` disparó (correcto: el
modelo no afirmó falsamente que el orden SÍ está documentado). El page-pin (Fase 1) y el
contenido citado son correctos; el defecto vive en la especificidad del regex de rúbrica
de este caso puntual, congelado en la Fase 5 antes de conocer las respuestas reales (tal
como manda el diseño del holdout). **No se toca el fixture ni el evaluador ahora** — la
corrida ya está gastada (restricción de la Fase 7) y hacerlo post-hoc invalidaría el gate
como medición ciega. Se documenta como hallazgo para la decisión humana #9.

### 2. `holdout_v4_thyssen_divisor_series_ebf` (technical_important, no gatea) — colisión de página residual

**Score 3/10, `source_page_cited: false`.** Pregunta nombra "página 92" (divisor THYSSEN,
mismo caso que `holdout_v3_thyssen_divisor_cmc4` del ciclo 3, ahora con hechos nuevos:
pide qué series aparecen además de las CMC). Cita real: `page: 93`,
`section_identity: THYSSEN`, `canonical_name: "ALJO Control Level 1B Altius"` (contaminación
N8 en el cuerpo, fuera de alcance — Anexo D). El propio texto de la respuesta admite el
problema: *"La documentación recuperada no contiene información sobre la página 92... El
documento disponible es... página 93"*. `retrieve_invocations: 1` (un solo intento, sin
retry visible).

**Veredicto: el filtro `equals: page_number=92` (Fase 1) muy probablemente devolvió CERO
resultados** — página 92 es la misma página divisoria "casi vacía" (695 bytes) que en el
Anexo B (Fase 0b) nunca entró al top-k ni siquiera sin filtro, y que el Anexo D confirmó
como caso de *"divisor thinness"*, no de contaminación N8. Con 0 resultados del filtro, la
ruta estructurada activó `Rag::SectionNeighborExpander`
(`expansion_mechanism: "section_identity"`, visible en el log `[PILOT_USAGE] evidence_route`
de esta corrida) — mecanismo que el propio diseño de la Fase 1 documentó como **NO cubierto
por el filtro de página** ("expande vía S3 local, no Bedrock... si la página nombrada es
una divisora, la expansión a vecinos sigue funcionando porque no pasa por el filtro"). La
expansión trajo la página vecina 93 (contenido parcial: sólo SERIE E, no B ni F) en vez de
la 92 nombrada. **Esto es exactamente el límite conocido y ya anotado en el diseño de la
Fase 1** ("Rango o varias páginas → sin filtro... límite conocido, se anota"), materializado
por primera vez con un caso real: cuando la página nombrada está vacía Y es divisoria, el
filtro no puede "fallar seguro" hacia la página correcta — el expansor de vecindad (que
existe para otro propósito, cubrir contexto alrededor de secciones) rellena con la página
adyacente sin saber que no es la nombrada. No es un caso `safety_critical`, no bloquea el
criterio congelado, pero es la misma familia de riesgo (N10/divisor thinness) que ya estaba
anotada como no resuelta en el Anexo D. No se propone fix en esta sesión (fuera de mandato:
la corrida ya cerró y no hay ciclo 5).

### 3. `holdout_v4_orona_arca_p32_ambigua` (technical_important, N11, no gatea) — etiqueta de variante no reconocida

**Score 10/12.** El flag de N11 (Fase 2) funcionó correctamente en su objetivo central: la
respuesta cubre AMBAS placas nombradas con `generation_chunks`/citas de 3 chunks distintos
(ORONA p.60/63/64), declara explícitamente que **no es la misma serie en ambas placas** (el
`required` más importante del caso, el que replica el patrón N11 del ciclo 3) — con valores
correctos: ARCA "II" → SERIE CERROJOS EXTERIORES-CABINA, ARCA III → SERIE SEGURIDADES
PRINCIPALES. El único `required` que falló es *"serie de P32 en ARCA básica"*: el modelo
etiquetó la placa como **"ARCA II"**, no "ARCA básica"/"ARCA" (el término del fixture,
verificado contra el cuerpo real del chunk en la Fase 5), y además declaró explícitamente
*"la documentación disponible no contiene información sobre la placa ARCA básica (sin
sufijo II o III)"* — no reconoció "ARCA II" como la forma en que el documento nombra la
variante que el fixture llama "básica". **Veredicto: no es un fallo de N10 (retrieval) ni
de N11 (cobertura multi-placa, que funcionó) — es un desajuste de nomenclatura entre la
etiqueta que usa el `FIELD_RECORD`/heading del chunk ("ARCA II") y la que asume el fixture
("ARCA básica"/"ARCA")**, la misma familia de deuda que el hueco 4/P4 del inventario de
regex (Anexo C) ya documentaba para `EXPLICIT_EQUIPMENT_PATTERN`/identidad de variante —
pero aquí ocurre en generación, no en enrutamiento. No bloquea el criterio congelado (no es
`safety_critical`); no se propone fix.

### Síntesis para la decisión humana #9

Los 3 fallos son de naturaleza distinta y NINGUNO reabre N10 como estaba en el v3 (colisión
de página ganada por un duplicado casi calcado): el fallo que gatea (#1) es un defecto del
evaluador, no de la aplicación; el fallo #2 es un límite ya conocido y documentado del
diseño de la Fase 1 (divisor vacío + expansión de vecindad sin filtro) que no tuvo caso de
prueba hasta ahora; el fallo #3 es nomenclatura de variante en generación, no cobertura. El
page-pin (Fase 1) y el flag de N11 (Fase 2) — las dos correcciones centrales del ciclo —
funcionaron según lo diseñado en 12 de los 14 casos, incluidos los 6 casos que explotan los
clusters duplicados FAIN/RECOBA y THYSSEN con hechos nuevos y el caso multi-placa. Pese a
esto, el criterio congelado se aplica tal como se fijó, sin excepciones post-hoc: el gate
NO pasa.

## Decisión humana #9 (escalada 2026-08-04, ciclo 4 PARADO)

Por mandato de la Fase 7 y la decisión del dueño #8 ("si el v4 falla, se PARA: no hay ciclo
5 con esta estrategia"): el gate v4 no pasa (Anexo F). El holdout v4 queda gastado (no se
reabre, ni con `RAG_SEGURIDADES_CASE_IDS`, igual que v1/v2/v3). No se libera a piloto. No se
modifica código, fixture ni evaluador en esta sesión — el criterio se aplicó tal como se
congeló, sin ajustes tras ver los resultados. Opciones no evaluadas en profundidad aquí,
para que el dueño decida el siguiente camino:

1. **Aceptar el resultado de la Fase 4/evaluador como suficientemente bueno para el caso
   #1** (la respuesta real es segura y correcta; el defecto es del regex de rúbrica) y
   definir un mecanismo de re-juicio o revisión humana puntual del caso, sin abrir un v5
   completo — requiere decidir si esto cuenta como "ciclo 5 con esta estrategia" (prohibido)
   o como corrección de arnés de medición (posiblemente permitido, a criterio del dueño).
2. **Fix acotado del expansor de vecindad (#2)**: hacer que
   `Rag::SectionNeighborExpander` respete el filtro de página cuando el page-pin está activo
   (en vez de expandir a cualquier vecino), o que la ruta estructurada abstenga con
   `DATA_NOT_AVAILABLE` en vez de expandir cuando el filtro de página da 0 resultados — esto
   SÍ sería código nuevo de retrieval, la misma estrategia que ya "falló" según la regla del
   dueño, o una estrategia distinta (a decidir).
3. **N8** (Anexo D, diferido): ejecutar el parche de texto dirigido ahora que el ciclo 4
   cerró (secuencia ya recomendada en el Anexo D, independiente del resultado del gate).
4. **Otra estrategia completamente distinta** para N10/N11 residual, o aceptar el estado
   actual (page-pin + flag N11 desplegados, guardrail de piloto activo) sin gate v4 aprobado
   y decidir el piloto por otra vía (p.ej. supervisión humana reforzada en vez de gate
   automatizado).

No ejecutado nada de lo anterior en esta sesión (restricción 5: un objetivo por sesión — el
objetivo de esta sesión fue correr y clasificar el gate v4).

## Qué NO está en este plan

- Nada de visión (T1, T2, zoom, triaje visual): apagado se queda apagado.
- Nada que llame a la API de Anthropic desde la aplicación.
- Ningún cambio de `BEDROCK_MODEL_ID` en producción.
- N8 (contaminación de identidad en el CUERPO de 96/97 chunks): **causa raíz confirmada,
  Anexo D** — un parche de texto dirigido (sin re-ingesta ni llamadas a Anthropic) es
  viable, pero no se ejecuta este ciclo por la restricción 5 (un objetivo por sesión);
  queda como decisión pendiente del dueño entre parche dirigido vs. re-indexación
  completa con 2 versiones de KB.
- N9 (alinear el guion de benchmark con `QueryOrchestratorService`): documentado y
  corregido en su redacción, sin mandato en este ciclo.
- La migración P4 (guards por identidad de chunk en vez de forma léxica): ruta de retiro
  documentada en 0c, no se ejecuta.
- **Las preguntas del holdout v4 en este documento**: no se listan aquí ni en ningún
  artefacto que lean las sesiones de las Fases 0-4 — sólo existen en el fixture congelado
  por la Fase 5. Un holdout que las fases de arreglo pueden leer deja de ser holdout.
