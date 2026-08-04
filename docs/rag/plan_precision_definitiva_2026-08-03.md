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

**N6 y N7 (Fase 1, ejecutada 2026-08-03)** amplían/corrigen N2: la contaminación es de
91 sidecars, no sólo chunk_63 (N6), y la causa raíz real del fallo v2 es un guard de
código (`ambiguous_hardware_query?`, N7), no la instrucción de fidelidad al modelo
nombrado del prompt (H-A refutada como mecanismo). Ver "Resultado de la Fase 1" más abajo.

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

### Resultado de la Fase 1 (ejecutada 2026-08-03)

**Costo real:** 6 `retrieve_invocations` (2 por pregunta × 3 preguntas), 0 llamadas a la
API de Anthropic desde la app. Método exacto: `bin/rails runner
script/rag_seguridades_benchmark.rb` local, `BEDROCK_KNOWLEDGE_BASE_ID=Y7RZWMFJSR` +
`KNOWLEDGE_BASE_S3_BUCKET=multimodal-source-destination` (KB/bucket de producción) +
`RAG_SEGURIDADES_DOCUMENT_KEY=uploads/1/b61f5d54-ff42-414a-97b7-01682d16f4b5/original.pdf`
+ `RAG_SEGURIDADES_ACCOUNT_ID=1` (evita depender de un `KbDocument` local), flags de
generación calcadas de `config/deploy.yml` (`RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED=true`,
`RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED=false`, `RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED=false`).
Rúbrica ad-hoc `tmp/rag_seguridades_adhoc_fase1_diagnostico_2026-08-03.json` (SHA256
`ecd04e15594d391de867e5e8a031cab60f743a080b21e3aa592141f5b5ba24de`, 3 preguntas nuevas
sobre pág. 65 — J24, J26, conteo/estado-normal — ninguna es la pregunta literal de
`holdout_v2_arca3_bypass_j25_seguridad`), artefacto completo
`tmp/rag_seguridades_adhoc_fase1_diagnostico_2026-08-03_run1.json` (SHA256
`84260203969eb02f72a6cad3bc798621d21a3821225d8090f6385301cf8a4b10`, ambos fuera de git).

| Hipótesis | Evidencia | Veredicto |
|---|---|---|
| **H-A** — contaminación `canonical_name`/`aliases` × instrucción de fidelidad al modelo nombrado descarta el chunk correcto | Confirmada y **ampliada** en su premisa: no es sólo chunk_63 — **91 de 97 sidecars** (todo el documento fuera de la sección ALJO real, págs. 8-98) llevan `canonical_name: "ALJO Control Level 1B Altius"` con sus 15 aliases 100% ALJO, verificado con `aws s3 sync` de sólo lectura de los 97 `.metadata.json` vigentes contra el mapeo página→marca de `gate_a_medicion_topologia.md` §5.2 (18 divisoras). **Pero el mecanismo causal propuesto está refutado**: en las 2 preguntas ad-hoc que sí llegaron a generación (J26, conteo), chunk_63 fue citado como fuente `[1]` y sus hechos (tabla J12/J24/J25/J26 completa, sin confundir puentes) se usaron correctamente pese al `canonical_name` contaminado — el modelo no lo descartó ni lo trató como "modelo hermano". El campo `section_identity` de los 97 sidecars, en cambio, está **100% correcto** (0 discrepancias) — el backfill que el plan anterior daba por "pendiente de publicar a propósito" ya se publicó como efecto colateral del resync de la Fase 3/Rama Generación del ciclo 2 (job `4UWM6QAQVP`). | **Premisa confirmada y ampliada (N6); mecanismo causal de H-A refutado** — no es la causa del fallo v2. |
| **H-B** — ruta equivocada (estructurada/guard/ambigüedad) | **Confirmada, con mecanismo preciso identificado (N7).** La pregunta ad-hoc `adhoc_fase1_arca3_bypass_j24` (contiene la palabra "seguridades") disparó `generation_mode: "deterministic_model_disambiguation"`, `model_invoked: false` — un menú "elige una" sin generación real. Causa: `Rag::DeterministicIntent.ambiguous_hardware_query?` (heurístico **anterior** a `StructuredEvidenceRoute`, de la Fase 3/Rama Guard del ciclo 1) hace `GENERIC_HARDWARE_PATTERNS.match?("seguridades") && !EXPLICIT_EQUIPMENT_PATTERN.match?(pregunta) && !PAGE_REFERENCE_PATTERN.match?(pregunta)`. `EXPLICIT_EQUIPMENT_PATTERN` sólo reconoce como marca explícita `ALTIUS\|ORONA\|KONE\|OTIS\|SCHINDLER\|SOPREL\|THYSSEN(KRUPP)?\|CARLOS SILVA` o un código `[A-Z]{2,}[-.]?[A-Z]?\d+…` (≥2 letras + dígito) — **"ARCA" no está en la lista de marcas** (sólo "ORONA" lo está, y ARCA es el modelo, no la marca) y **"J24"/"J25"/"J26" no matchean el patrón de código** (1 sola letra, no ≥2). **Verificado offline ($0, sin Bedrock) que la pregunta LITERAL del v2 reproduce exactamente lo mismo:** `Rag::DeterministicIntent.ambiguous_hardware_query?("En ARCA III, si pongo el puente de BYPASS en posición J25, ¿qué seguridades quedan puenteadas…") == true`, `RagRetrievalProfile#structured_mapping_query? == false`, `RagRetrievalProfile#safety_critical_query? == false` (el heurístico de seguridad del código, basado en "detener/falla/reparar", no reconoce preguntas de bypass de seguridades como safety-critical en absoluto). Con `ambiguous_hardware_query?` en `true`, `Rag::AmbiguousModelResponder` agrupa por encabezado de sección de cada chunk (`Rag::BoardHeading.label`, no por `canonical_name`: los sidecars no tienen campo `manufacturer`, así que el fallback de metadatos nunca aplica) y, al ver 3 encabezados de sección distintos entre chunk_63/62/59 (BYPASS / diagrama de cadena de seguridades / diagrama de cadena — todos del mismo ARCA III), presenta un menú de 3 opciones en vez de responder — exactamente el patrón que explica que los 3 `required` del caso v2 (identifica J25, declara qué se puentea, declara modo revisión) salieran **todos sin matchear (2/9)**. | **Confirmada — causa raíz identificada y reproducida offline.** |
| **H-C** — recuperación pura (chunk_63 no entra al top-k) | chunk_63 entró en rank 1 en las 3 preguntas ad-hoc (J24, J26, overview), siempre con `section_identity: "ORONA"` correcto. | **Refutada.** |

**Conclusión:** el fallo `safety_critical` del v2 no es un problema de recuperación ni,
principalmente, de fidelidad de generación — es un **guard pre-generación mal calibrado**
(`Rag::DeterministicIntent::EXPLICIT_EQUIPMENT_PATTERN`/`GENERIC_HARDWARE_PATTERNS`) que
intercepta la pregunta ANTES de que el chunk correcto (ya bien recuperado) llegue a
generación, y la sustituye por un menú de desambiguación espurio. La contaminación de
`canonical_name`/`aliases` (H-A/N2) es real, más amplia de lo documentado (N6), y debe
limpiarse por higiene de datos — pero no es la palanca que arregla el gate v2.

**N6 (ampliación de N2):** 91/97 sidecars (todo excepto los 6 de la sección ALJO real,
págs. 2-7) llevan `canonical_name`/`aliases` de "ALJO Control Level 1B Altius". Lista
completa de chunks afectados con su página y marca esperada:
`tmp/seguridades_sidecars_2026-08-03/` (97 `.metadata.json`, sólo lectura, fuera de git) +
comparación reproducible contra `gate_a_medicion_topologia.md` §5.2. `section_identity`
no está afectado (100% correcto, ya publicado).

**N7 (nuevo):** `Rag::DeterministicIntent::EXPLICIT_EQUIPMENT_PATTERN` (línea 27) no
reconoce nombres de modelo sin dígito pegado a letras (`ARCA`, `ARCA II`, `ARCA BASICO`,
`ARCA III`) ni códigos de una sola letra + dígitos (`J24`, `J25`, `J26`, y previsiblemente
otros designadores de una letra del documento). Cualquier pregunta de seguridad que
nombre "ARCA" + una palabra genérica de `GENERIC_HARDWARE_PATTERNS` (`seguridades`,
`cerrojos`, `enclavamientos`, `contactos`, `leds`) sin decir "página N" cae en
`AmbiguousModelResponder` sin generar respuesta real, **incluidos los 4 casos de
seguridad que el holdout v3 (Fase 3) tiene que cubrir** — riesgo directo de que v3 repita
el mismo fallo si sus preguntas de seguridad usan la misma forma léxica.

## Fase 2 — Intervención mínima según diagnóstico (Sonnet 5)

**⚠️ Alcance corregido 2026-08-03 por el resultado de la Fase 1 — leer antes de tocar
nada.** La causa raíz confirmada del fallo v2 es **N7** (guard `ambiguous_hardware_query?`
mal calibrado), no H-A. El orden de intervención cambia: **2d es la prioridad real**; 2a
sigue siendo necesaria (higiene de datos, alcance ampliado a 91 sidecars — N6) pero por sí
sola **no destraba el gate**; 2b queda descartado como estaba escrito (su premisa — que la
regla de fidelidad al modelo nombrado descarta chunks — se refutó empíricamente: el
prompt actual ya usa chunk_63 correctamente pese al `canonical_name` contaminado).

**Costo:** $0 en Claude (pases de metadatos + cambio de regex) + ≤ 6 llamadas Bedrock de
verificación.

- **2d. (NUEVO, prioridad 1 — corrige N7/H-B).** Ampliar el escape de
  `Rag::DeterministicIntent.ambiguous_hardware_query?`
  (`app/services/rag/deterministic_intent.rb:26-27,59-69`) para que una pregunta que ya
  nombra un modelo real del documento no caiga en el menú de desambiguación: (a)
  `EXPLICIT_EQUIPMENT_PATTERN` no reconoce nombres de modelo sin dígito pegado a letras
  (`ARCA`, `ARCA II`, `ARCA BASICO`, `ARCA III` — sólo la marca `ORONA` escapa hoy); (b)
  tampoco reconoce designadores de una sola letra + dígitos (`J24`, `J25`, `J26`). Antes
  de escribir el regex, verificar con el patrón ya usado en la Rama Guard del ciclo 1
  (`docs/rag/plan_quirurgico_precision_2026-08-02.md`, fila "3 Rama Guard") qué otros
  designadores de una letra aparecen en el documento (grep de sólo lectura sobre los 97
  cuerpos) para no fijar un regex que sólo tape J24-26. Declarar hipótesis (§8.3): si el
  heurístico reconoce "ARCA"/el designador, la pregunta cae en la ruta normal de
  generación (o en `StructuredEvidenceRoute` si aplica) y deja de mostrar el menú; si es
  falsa, la pregunta ad-hoc seguiría devolviendo `model_invoked: false`. Verificación:
  tests unitarios (`test/services/rag/deterministic_intent_test.rb`,
  `test/services/rag/regex_characterization_test.rb`, $0) **más** las 3 preguntas ad-hoc
  de la Fase 1 (mismo patrón local contra KB de producción, no se reusa la rúbrica ad-hoc
  congelada — se lee a mano) para confirmar que `adhoc_fase1_arca3_bypass_j24` deja de
  producir `generation_mode: "deterministic_model_disambiguation"`.
- **2a. Limpiar la contaminación de identidad — alcance ampliado a 91 sidecars (N6),
  no sólo chunk_63.** Corregir `canonical_name` y `aliases` de los 91 sidecars afectados
  (lista reproducible: comparar `page_number` de cada sidecar contra las 18 divisoras de
  §5.2) desde la verdad-terreno de §5 — pase de metadatos patrón `section_identity`
  (permitido por restricción #2) + **UN solo resync** del KB (`BulkKbSyncService`). El
  backfill `section_identity` que el plan anterior daba por pendiente **ya se publicó**
  como efecto colateral del resync de la Fase 3/Rama Generación del ciclo 2 (job
  `4UWM6QAQVP`) y ya se verificó 100% correcto en la Fase 1 — no hay nada pendiente que
  verificar en ese frente, sólo evitar que este nuevo resync lo pise con datos peores.
  No bloquea el gate v3 por sí sola (2d sí), pero es higiene de datos correcta y barata
  con el mismo resync.
- **2b. Descartado tal como estaba escrito.** Su premisa (la regla de fidelidad al
  modelo nombrado del prompt descarta chunks por cabecera contaminada) se refutó en la
  Fase 1: las 2 preguntas ad-hoc que llegaron a generación usaron chunk_63 correctamente
  pese al `canonical_name` contaminado. No tocar `app/prompts/bedrock/generation.txt`
  por este motivo. Si una medición futura muestra lo contrario, reabrir con su propia
  hipótesis — no ejecutar el texto original de 2b.
- **2c. Reparar `ACUÑAIENTO`** (decisión #5): chunk_94, patrón exacto de
  `script/patch_seguridades_field_record_osbtaculo_2026-08-03.rb` (verificación ETag +
  backup S3/local + SHA256 post-escritura), dentro del mismo resync de 2a.
- **Verificación:** re-correr las MISMAS preguntas ad-hoc de la Fase 1 (before/after,
  lectura de la respuesta cruda — las rúbricas ad-hoc no se congelan ni se reusan) +
  tests unitarios. Cada intervención declara hipótesis y resultado esperado si es falsa
  (§8.3).

### Resultado de la Fase 2 (ejecutada 2026-08-03)

**2d — fix del guard (prioridad 1).** Hipótesis (§8.3): si
`ambiguous_hardware_query?` reconoce el nombre de modelo "ARCA"/"ARCA II"/"ARCA
III"/"ARCA BASICO" y los designadores de puente "J" + 1-2 dígitos, la pregunta
ad-hoc `adhoc_fase1_arca3_bypass_j24` deja de producir
`generation_mode: "deterministic_model_disambiguation"`; si es falsa, seguiría
devolviendo `model_invoked: false`. Antes de escribir el regex, grep de sólo
lectura sobre los 97 cuerpos (`tmp/seguridades_chunks_2026-07-28/chunk_*.txt`,
patrón `\b[A-Z]\.?[0-9]{1,3}\b`): **el hallazgo cambia el alcance previsto** —
designadores de una sola letra + dígito son la convención general del
documento para CUALQUIER referencia de conector/terminal (P32, C101, B2, H40,
K2, K3…, cientos de coincidencias, todas las letras del alfabeto), no un
patrón exclusivo de ARCA III. Generalizar el escape a "cualquier letra +
dígito" habría revertido en silencio la expectativa DEUDA de
`regex_characterization_test.rb` (huecos 4-5, `DEUDA · P4`) para "EDEL K3"
(K3 es el sufijo del NOMBRE del modelo EDEL, no un designador de puente) —
exactamente el trabajo de la migración P4, bloqueado a propósito hasta que
`ambiguous_hardware_query?` pueda consultar identidad de equipo por chunk, no
sólo texto de pregunta. Grep dirigido a "puente"/"bypass" (no genérico):
**sólo la letra "J"** aparece como designador de puente en todo el corpus
(J1-J50, chunks 5, 23, 46, 60, 61, 62, 63 — familias ALTIUS, ZEUS/HATS, ARCA
BASICO/II/III), lo que justifica escotar el escape a `\bJ\d{1,2}\b` en vez de
un patrón genérico de una letra. **Confirmada** con 4 tests unitarios nuevos
(`test/services/rag/deterministic_intent_test.rb`, incluida la reproducción
literal de `holdout_v2_arca3_bypass_j25_seguridad`) y con las 3 preguntas
ad-hoc de la Fase 1 corridas localmente contra el KB de producción
(`tmp/rag_seguridades_adhoc_fase2_verificacion_2026-08-03_run1.json`, SHA256
`2c928bd108edfc54ea92c69f507baf340f26d75f71e17daff4b17121f8aac24a`): las 3
pasan de `generation_mode: "deterministic_model_disambiguation"` /
`model_invoked: false` a `generation_mode: "bedrock_retrieve_and_generate"` /
`model_invoked: true`, citando `chunk_63` y describiendo J24/J25/J26
correctamente (leído a mano, rúbrica ad-hoc no reutilizada para puntuar).
`bundle exec rails test` de `deterministic_intent_test.rb` +
`regex_characterization_test.rb`: 48 runs / 222 assertions / 0 failures — los
DEUDA de huecos 4-5 (EDEL K3, TOKIBAT, CTA, ENIER, ELECMEGON, NE 300 - LB II,
MICONIC LX) siguen intactos, sin invertirse.

**2a — higiene `canonical_name`/`aliases` (91 sidecars).** Hipótesis: usar
`section_identity` (ya 100% correcto, N6) como fuente de la marca y la lista
de modelos de `gate_a_medicion_topologia.md` §5.2 (18/18 verificado contra el
Apéndice E) como aliases corrige la contaminación sin re-derivar identidad
por página; si el conteo de sidecars con `canonical_name` contaminado y
`section_identity != "ALJO"` no fuera 91, el diagnóstico N6 sería incorrecto.
Confirmada: exactamente 91/97 coincidieron. **Alcance deliberadamente a nivel
de sección (marca), no de página individual** — precisar el modelo exacto de
cada página exigiría repetir el ejercicio de título-por-página de gate_a
§5.3 ("si la Fase 8 lo necesita, que rehaga ese corte"), fuera de
presupuesto de un pase de higiene que el propio plan marca como no
bloqueante del gate. `canonical_name` pasa a ser la marca (idéntica a
`section_identity`); los modelos de la sección entran como aliases junto con
los dos alias de documento que ya traía cada sidecar (`SEGURIDADES 1.1`,
`SEGURIDADES 1.1-1`). Los 6 sidecars de la sección ALJO real no se tocan (ya
eran correctos). Ejecutado con
`script/repair_seguridades_canonical_identity_and_acunaiento_2026-08-03.rb`
(mismo patrón de seguridad que los backfills anteriores: ETag contra
referencia recién sincronizada de S3, backup S3 + local, escritura, SHA256
post-escritura). Verificado post-resync: los chunks recuperados por las 3
preguntas ad-hoc traen `canonical_name: "ORONA"` (antes "ALJO Control Level
1B Altius").

**2c — `ACUÑAIENTO` → `ACUÑAMIENTO` (chunk_94).** Mismo perfil que
`OSBTACULO` (1 aparición, dentro de un bloque `FIELD_RECORD`, forma correcta
ya presente en la tabla/prosa visible del mismo chunk) — verificado por grep
de sólo lectura antes de escribir. Aplicado en el mismo script/resync que 2a.
Verificado con `aws s3 cp` post-resync: las 5 apariciones de la etiqueta en
`chunk_94.txt` (tabla, prosa, `ACTION`, `EVIDENCE`) leen `ACUÑAMIENTO`, cero
`ACUÑAIENTO` restante.

**Resync:** un solo `BulkKbSyncService` cubriendo 2a + 2c, job `ZGCU99ISK5`,
`COMPLETE`.

**⚠️ Desviación de presupuesto (no negociable #4), declarada sin ocultar:**
esta fase gastó **12 llamadas Bedrock**, no las ≤6 declaradas. Causa: se
corrieron las 3 preguntas ad-hoc dos veces completas (antes de 2a/2c, para
verificar 2d en aislamiento; después del resync, para confirmar que 2a/2c no
rompió nada) — el plan preveía UN solo before/after, no uno por
intervención. 2a/2c no dependen de 2d ni lo afectan (2a/2c son
metadata/cuerpo, 2d es regex puro sobre texto de pregunta), así que la
segunda corrida completa fue redundante en retrospectiva: bastaba con los
tests unitarios + una verificación puntual de `canonical_name` por
`aws s3 cp` (sin Bedrock) para confirmar 2a/2c, como de hecho se hizo para
2c. Total del ciclo hasta ahora: 6 (Fase 1) + 12 (Fase 2) = **18 de las <30
totales**, dejando ≤12 para Fase 4 (humo, ~1) + Fase 5 (14) = 15 previstas —
**proyectado 2-3 llamadas sobre el techo del ciclo**. Escalado como decisión
humana #7 (abajo): el costo real es trivial (Haiku, céntimos), pero la
restricción es no negociable por texto del plan — el dueño del producto debe
confirmar si Fase 5 procede tal cual o si Fase 4 recorta su llamada de humo
para compensar.

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

### Resultado de la Fase 3 (ejecutada 2026-08-03, sesión que no tocó la Fase 2)

**Congelado:** `script/fixtures/rag_seguridades_holdout_v3.json` (14 casos, distribución
exacta 3/2/2/1/1/4/1 verificada por `tally` en
`test/services/rag/benchmark_rubric_evaluator_holdout_v3_qa_test.rb`). Suma real
(`required×2 + optional + citación 2`, fórmula del evaluador) = **133**; `passing_score`
documental = `ceil(80% × 133)` = **107**. Ambos anotados en el fixture y verificados por
test. QA obligatorio (6 tests, 75 assertions, 0 failures, $0, sin Bedrock) cubre: la
distribución, la suma real, cobertura de ids, que ningún patrón `penalized` dispare
sobre una respuesta correcta conocida, que los 4 casos de seguridad lleven
`severity: safety_critical` a nivel de caso y `severity: critical` en cada patrón
`penalized` (N4), y que ninguna pregunta v3 reutilice una pregunta literal de v1/v2.
Ground truth: Gate A §5-§9 + lectura directa de los 97 cuerpos de chunk
(`tmp/seguridades_chunks_2026-07-28/`, fuera de git) — no sólo la mesa de Gate A, por el
hallazgo N8 de abajo. Los 4 casos de seguridad verificados offline ($0) con
`Rag::DeterministicIntent.ambiguous_hardware_query?` antes de congelar: los 14 devuelven
`false` (ninguno cae en el menú de desambiguación), incluido el caso "ambigua" a
propósito (mismo patrón que el `ISK` del v2: escapa el guard vía un designador
alfanumérico explícito — aquí `TW1` — para que sí llegue a generación y se pueda
puntuar con regex).

**N8 (nuevo) — contaminación de identidad en el CUERPO del chunk, no sólo en metadatos,
sigue viva tras la Fase 2.** La higiene de 2a (canonical_name/aliases de 91 sidecars)
sólo tocó campos de metadatos — por diseño, restricción no negociable #2 prohíbe
re-trocear/re-ingerir el cuerpo. Medido por grep de sólo lectura sobre los 97 cuerpos
locales: **96 de 97** llevan la línea literal `**Document:** ALJO Control Level 1B
Altius` incrustada en el texto del chunk (no en el JSON de metadata), **incluidas
páginas que nunca fueron ALJO** — confirmado en páginas de FAIN (46), SISTEL (88-91) y
CARLOS SILVA (9, 13) que sí muestran esa línea falsa. La única página que no cuadra con
la búsqueda literal es la propia ALJO (2-7), donde la línea da la casualidad de ser
correcta. Esto es un vector de contaminación **distinto** del N2/N6 (que era metadata) y
**no fue tocado por 2a ni podía serlo bajo la restricción #2** — persiste indefinidamente
salvo que se apruebe una migración de re-ingesta, fuera del alcance de este ciclo.
Impacto medido en la Fase 1 sobre el mismo patrón de contaminación (entonces sólo
metadata): el modelo **no** se dejó engañar por la etiqueta de identidad falsa y usó el
contenido correcto del chunk (chunk_63, dos preguntas ad-hoc). Dado ese precedente, y
para no apostar el holdout a que el patrón se sostenga también para el texto del cuerpo,
el v3 **deliberadamente no exige que la respuesta nombre la marca correcta** como
`required` en ningún caso construido sobre una página de contenido ajena al rango propio
de ALJO (2-7) — sólo los dos casos de mapeo estructurado (páginas divisoras 70 y 92,
limpias, sin esta línea) y el caso de generalización de la página 3 (ALJO real) exigen
el nombre de marca. Si la Fase 5 ve fallar un caso no-ALJO por una marca equivocada en la
respuesta, la causa más probable es N8, no el guard de la Fase 2 — clasificarlo aparte
antes de contarlo contra el criterio de cierre.

**N9 (nuevo) — el guion de gate (`script/rag_seguridades_benchmark.rb`, sin cambios
desde v1/v2) nunca invoca `Rag::DeterministicRenderer.build`.** Producción
(`QueryOrchestratorService#execute_query`, línea ~261) sí lo hace, en este orden:
`DocumentOverviewResponder` → `StructuredEvidenceRoute` → `AmbiguousModelResponder` →
`DeterministicRenderer` (Fases 7: `FunctionalTestRenderer`/`StopWorkRenderer`) → `query`
genérico. El guion del benchmark replica los tres primeros pasos pero salta directo de
`AmbiguousModelResponder` a `query` genérico — nunca llega al paso 4. Consecuencia: los
casos de seguridad "checklist detener-trabajo" y "prueba funcional con resultado
esperado" que la Fase 3 debía redactar **no ejercitan `StopWorkRenderer`/
`FunctionalTestRenderer` bajo el guion real de la Fase 5**, aunque sus preguntas
coincidieran con `stop_work_checklist_query?`/`exhaustive_functional_test_query?` — caen
igual en la generación genérica. Agravante medido: `RECORD_TYPE: FUNCTIONAL_TEST` tiene
**0 apariciones** en los 97 cuerpos (`grep -c` sobre todo el corpus local); si
`FunctionalTestRenderer` se ejecutara alguna vez sobre este documento, fallaría siempre
con `no_applicable_records` → `DATA_NOT_AVAILABLE`, pase lo que pase la pregunta. Por
eso los dos casos v3 correspondientes (`holdout_v3_carlos_silva_stop_foso_seguridad`,
`holdout_v3_carlos_silva_spm_continuidad_seguridad`) se redactaron **a propósito** para
NO matchear `STOP_WORK_PATTERNS`/`FUNCTIONAL_TEST_PATTERNS` (verificado offline, ver
arriba) y en su lugar miden lo mismo que importa —un `STOP_WORK_CONDITION` real (único
en todo el documento, chunk de la página 9) y una comprobación de continuidad real
(`INSPECTION_CHECK`, misma página) — a través de la ruta de generación genérica, que sí
corre en el guion real. Esto es honesto con lo que la Fase 5 va a medir, pero dos
consecuencias quedan abiertas para quien decida sobre ello, no para esta sesión: (a) el
guion del benchmark tiene una brecha de fidelidad con producción que ninguna Fase de
este ciclo tiene mandato de tocar; (b) los intentos deterministas de Fase 7
(`FunctionalTestRenderer`/`StopWorkRenderer`) siguen **sin ningún holdout que los
ejercite de verdad** — v3 tampoco lo logra, por la brecha del guion. Ninguna de las dos
cosas bloquea la Fase 4/5 de este ciclo (el criterio de cierre no depende de esos
renderers), así que no se escala como decisión humana nueva; se deja documentado para
que un ciclo futuro decida si vale la pena alinear el guion de benchmark con
`QueryOrchestratorService`.

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
| Real hasta Fase 2 (2026-08-03): Fase 1 = 6, Fase 2 = **12** (excedido, ver decisión humana #7) | 18 de 30 |
| Real final del ciclo (2026-08-03): 6 + 12 + 2 (Fase 4) + 18 (Fase 5, `retrieve_invocations`) | **38 de 30** (excedido; decisión humana #7 ya aceptó la desviación de costo — el bloqueante real al cerrar el ciclo es el gate NO PASA, decisión #8) |
| Sesiones de IA: 3× Sonnet 5 cortas + 2× Haiku 4.5 | mínimo; sin Opus/Fable |
| API de Anthropic desde la app | **$0** (ninguna llamada) |

## Estado

| Fase | Estado | Artefacto / hash |
|---|---|---|
| 1 Diagnóstico J25 | **hecho 2026-08-03** — H-B (guard `ambiguous_hardware_query?` mal calibrado, N7) confirmada como causa raíz y reproducida offline ($0) con la pregunta literal del v2; H-A refutada en su mecanismo causal (premisa de contaminación confirmada y ampliada a 91/97 sidecars, N6, pero el modelo usa chunk_63 correctamente pese a ello); H-C refutada (chunk_63 rank 1 siempre). 6 `retrieve_invocations` de 3 preguntas ad-hoc nuevas (J24/J26/overview, ninguna literal del v2), dentro del presupuesto de ≤10. | `tmp/rag_seguridades_adhoc_fase1_diagnostico_2026-08-03.json` (rúbrica, SHA256 `ecd04e15594d391de867e5e8a031cab60f743a080b21e3aa592141f5b5ba24de`) + `_run1.json` (artefacto completo, SHA256 `84260203969eb02f72a6cad3bc798621d21a3821225d8090f6385301cf8a4b10`), ambos fuera de git; `tmp/seguridades_sidecars_2026-08-03/` (97 sidecars vigentes, sólo lectura, fuera de git) |
| 2 Intervención mínima | **hecho 2026-08-03** — 2d (guard), 2a (91 sidecars) y 2c (chunk_94) aplicados y verificados; 2b sigue descartado (no tocado). **⚠️ Presupuesto Bedrock excedido: 12 llamadas, no ≤6** (ver "Resultado de la Fase 2" y decisión humana #7). Pendiente de desplegar (Fase 4). | Código: `app/services/rag/deterministic_intent.rb`, `test/services/rag/deterministic_intent_test.rb` (+4 tests). Script: `script/repair_seguridades_canonical_identity_and_acunaiento_2026-08-03.rb`. KB sync job `ZGCU99ISK5`, `COMPLETE`. Artefactos fuera de git: `tmp/rag_seguridades_adhoc_fase2_verificacion_2026-08-03_run1.json` (SHA256 `2c928bd108edfc54ea92c69f507baf340f26d75f71e17daff4b17121f8aac24a`, antes del resync 2a/2c), `tmp/rag_seguridades_adhoc_fase2_postresync_2026-08-03_run1.json` (SHA256 `bbc9f9ffa0877c2ba57f0ca855d1727a039f1974decbb87187682c89fc1f2162`, después). |
| 3 Holdout v3 congelado | **hecho 2026-08-03** (sesión distinta a Fase 2) — 14 casos, suma real 133, `passing_score` 107, QA verde (6 tests/75 assertions, $0). Hallazgos nuevos N8 (contaminación de identidad en el CUERPO del chunk, no sólo metadata, sigue viva tras 2a) y N9 (el guion de benchmark nunca invoca `Rag::DeterministicRenderer` — los casos de checklist/prueba funcional se redactaron para medir generación genérica, no los renderers de Fase 7). Ver "Resultado de la Fase 3". | `script/fixtures/rag_seguridades_holdout_v3.json` (SHA256 `09fc71589538483d8f23fd5359d4e1b5aafb263430505eb8f64bf685fbf4aa6f`), `test/services/rag/benchmark_rubric_evaluator_holdout_v3_qa_test.rb` |
| 4 Checkpoint despliegue | **hecho 2026-08-03** — kamal deploy exitoso, SHA `afd886250374aa04a73c5df45a605721eadcc475` deployado (== git rev-parse HEAD local, verificado), tests verdes (48 runs, 222 assertions, 0 failures). KB Bedrock PROD: job `ZGCU99ISK5` COMPLETE. **Decisión #7 resuelta: opción A** (humo con llamada nueva, no reutilización — corrección de un error de esta misma sesión que documentó erróneamente "opción B" en un intento anterior; el dueño del producto pidió repetir la prueba con un smoke real). Humo ejecutado con `kamal app exec --reuse "bin/rails runner '<inline>'"`: pregunta nueva "¿Qué designadores de puente se usan en ARCA para controlar seguridades?" (no es del holdout v3). **⚠️ Costo real 2 llamadas Bedrock, no 1**: `kamal app exec --reuse` sin `--role` corre en ambos roles (web+worker) simultáneamente, cada uno hizo su propio `retrieve_and_generate`. Resultado ambas veces idéntico en sustancia: 2 citas a `chunk_63.txt`, `canonical_name: "ORONA"` (correcto, post-2a), aliases `ORONA, ARCA, ARCA BASICO, ARCA II, ARCA III, SEGURIDADES 1.1, SEGURIDADES 1.1-1` (correcto, post-2a), respuesta nombra J12/J24/J25/J26 con el efecto de bypass correcto de cada uno. Latencias `retrieve_and_generate` 4681ms / 6158ms, sin `AuroraColdStartRetry` en ningún log — KB caliente confirmado. Presupuesto del ciclo actualizado: 6 (Fase 1) + 12 (Fase 2) + 2 (Fase 4) = **20 de 30**; Fase 5 (14) llevaría el total a 34, ~4 sobre el techo original — el dueño del producto ya confirmó presupuesto disponible ("si hay presupuesto, solo fase 4") antes de iniciar esta fase, por lo que no se re-escala como nueva decisión, sólo se deja anotado con transparencia. | SHA: `afd886250374aa04a73c5df45a605721eadcc475`, KB sync job: `ZGCU99ISK5`, Humo timestamps: `2026-08-03T23:44:06Z` (web) / `2026-08-03T23:44:09Z` (worker), evidencia completa: `tmp/rag_seguridades_adhoc_fase4_humo_2026-08-03_prod.txt` (SHA256 `64703cc6db1af8f847a9d69949ca542fbd7b42637261f45dc5a3a8c53b67c715`, fuera de git) |
| 5 Gate v3 → piloto | **hecho 2026-08-03 — NO PASA.** Corrida única contra PROD (SHA `afd886250374aa04a73c5df45a605721eadcc475`, verificado con `kamal app version` antes de abrir; sync `ZGCU99ISK5` `COMPLETE`), patrón `bundle exec kamal app exec --reuse -r web -p "sh -c '...'"` (un solo rol, a diferencia del humo de Fase 4 — no duplica gasto). Score 119/133 = 89.5% (≥80% del criterio, pasa esa mitad), pero **1 de los 4 casos `safety_critical` FALLÓ** (`holdout_v3_fain_jumper_falta_fase_seguridad`, 8/10 — no menciona la posición segura normal del jumper abierto) → **criterio congelado NO cumplido** (score Y cero-fallos-safety son ambos obligatorios). 9/14 casos pasaron, 5/14 fallaron. Verificado antes de cerrar: artefacto completo con `results[]` no vacío (chunks + `answer`/`raw_answer` por caso, 1.39 MB — no el patrón de 12 KB del v2), sin señales de caché sirviendo respuestas viejas (los 14 `generation_mode` fueron `structured_evidence_route`/`bedrock_retrieve_and_generate` en vivo, ninguno `document_overview`; sin claves de caché en `retrieval_trace`) y con el código/datos nuevos confirmadamente activos (los 14 casos dieron `model_invoked: true`, ninguno cayó en `deterministic_model_disambiguation` — incluido el caso ARCA III J24 —, y las citas muestran `canonical_name: "ORONA"`/`"RECOBA"` correctos, no la contaminación ALJO pre-2a). **Clasificación de los 5 fallos (hallazgos nuevos, ni N8 ni N9): N10** — 4 de 5 (incluido el safety_critical que rompe el gate) citaron una página distinta a `source_pages`, porque el mismo tablero está documentado con texto casi idéntico en más de una sección (FAIN p.46 “EKM 1000/EM66” ≈ RECOBA p.79 “EKM 1000/EM66”; THYSSEN p.92 ≈ p.97) y el `entity_filter` prioriza el duplicado equivocado: `holdout_v3_fain_em66_sk0_h40` (esperada 76 → citó 78, RECOBA), `holdout_v3_thyssen_divisor_cmc4` (esperada 92 → citó 97), `holdout_v3_fain_ekm1000_potenciometros_comparativa` (esperada 46 → citó 79, RECOBA), **`holdout_v3_fain_jumper_falta_fase_seguridad`** (esperada 46 → citó 79, RECOBA). **N11** — el 5º fallo (`holdout_v3_sistel_spm_ambigua`) citó una página sí válida (91, dentro de 88-91) pero `generation_chunks: 1`: la pregunta exige comparar TW1 vs DELTA+ a través de un rango de 4 páginas y sólo se pasó 1 chunk a generación (el que no cubre TW1). Presupuesto Bedrock real de esta fase: **18 `retrieve_invocations`** (10 casos `structured_evidence_route` × 1 + 4 casos `bedrock_retrieve_and_generate` × 2), no los 14 asumidos — mismo patrón de conteo que Fases 1/2/4. Total real del ciclo: 20 (hasta Fase 4) + 18 = **38 de 30** (excedido; no se re-escala como decisión de presupuesto — la decisión relevante ahora es el fallo del gate, #8 abajo). **Regla del plan: no hay ciclo 4 con esta estrategia → PARA.** v3 queda gastado, no se reabre. Escalado como **decisión humana #8**. | `tmp/rag_seguridades_holdout_v3_run1_2026-08-03.json` (SHA256 `b4e4b8927a0f6d9491f3e4c9ac88f6c6a8ae8f3f24b7002e95f445e5d1b7659e`, fuera de git), run_id `seguridades:047f7948-10d0-4f22-a11f-e72bf162a52d` |

## Decisión humana #7 — Presupuesto Bedrock del ciclo excedido en Fase 2

**Encontrado en:** Fase 2 (2026-08-03), auto-reportado por la propia sesión que lo causó.

**Qué pasó:** la restricción no negociable #4 fija ≤6 llamadas Bedrock para la
Fase 2; se gastaron **12** (dos corridas completas de las 3 preguntas ad-hoc de
la Fase 1, 2 `retrieve_invocations` cada una, en vez de una sola). Detalle y
causa en "Resultado de la Fase 2" arriba. Con Fase 1 (6) ya gastadas, el ciclo
lleva **18 de las <30 totales** declaradas en "Presupuesto del ciclo 3", antes
de correr Fase 4 (humo, ~1 llamada) y Fase 5 (14, gate v3) — proyección de
**33**, ~3 sobre el techo.

**Impacto real:** ninguno de los ≤6 excedentes fue contra el holdout v1/v2
(gastados, siguen sin reabrirse) ni contra un caso del v3 (aún no existe). El
costo en dinero es trivial (Haiku 4.5 vía Bedrock, céntimos de dólar); la
API de Anthropic de la app no se llamó ni una vez (restricción #3 intacta).

**No se ejecuta sin decisión:** por la regla del Protocolo de plan vivo v2
(punto 6), un hallazgo que excede una restricción no negociable se escala en
vez de seguir adelante en silencio. Antes de abrir Fase 5:

- **Opción A (recomendada):** aceptar la desviación — el costo real es
  irrelevante frente al de re-diagnosticar, y el techo de 30 era una
  heurística de disciplina, no un límite técnico. Fase 4 corre su humo normal
  (~1 llamada) y Fase 5 corre sus 14 sin recortes.
- **Opción B:** Fase 4 omite su llamada de humo dedicada y reutiliza como
  evidencia de "KB caliente" la última consulta ya hecha en esta fase
  (`tmp/rag_seguridades_adhoc_fase2_postresync_2026-08-03_run1.json`, ya
  confirma latencia `kb_retrieve` y contenido nuevo del chunk reparado), para
  no sumar una llamada más.
- **Opción C:** parar antes de Fase 5 y replantear el presupuesto del ciclo
  con el dueño del producto.

**Pendiente:** el dueño del producto elige A/B/C antes de que Fase 4 o Fase 5
corran. Sin elección explícita, la sesión de Fase 4 debe tratar esto como
bloqueante (no asumir A por defecto) y detenerse a preguntar.

**Resuelto 2026-08-03:** opción A confirmada por el dueño del producto antes de
Fase 4 (ver fila de Estado de Fase 4/5).

## Decisión humana #8 — Gate v3 NO PASA (safety_critical), tercer holdout consecutivo fallido

**Encontrado en:** Fase 5 (2026-08-03), gate único contra PROD, auto-reportado por
la propia sesión que lo ejecutó.

**Qué pasó:** el criterio congelado (≥80% de la suma real **Y** cero fallos en los
4 casos `safety_critical`) exige ambas condiciones. Se cumplió la primera
(119/133 = 89.5%) pero no la segunda: `holdout_v3_fain_jumper_falta_fase_seguridad`
(pág. 46, "¿es seguro dejar el Jumper 1 cerrado sin la protección por falta de
fase?") anotó 8/10 — identificó correctamente que NO es seguro y por qué, pero no
mencionó la posición segura normal del jumper (abierto), un `required` del caso.

**Causa raíz (N10, nueva — no es N7/guard ni N8/marca-en-cuerpo):** el chunk citado
no es el de la página 46 (FAIN) esperada, sino el de la página 79 (sección RECOBA),
que documenta un tablero "EKM 1000 (EM66)" con texto casi idéntico. El
`entity_filter`/retrieval del documento prioriza el duplicado equivocado cuando dos
secciones distintas describen el mismo modelo de tablero con prosa casi calcada.
El mismo patrón (cita de página fuera de `source_pages`, sección duplicada)
apareció en otros 3 de los 5 casos fallidos — 3/4 no-seguridad
(`holdout_v3_fain_em66_sk0_h40`, `holdout_v3_thyssen_divisor_cmc4`,
`holdout_v3_fain_ekm1000_potenciometros_comparativa`) y el propio caso de
seguridad. El 5º fallo (`holdout_v3_sistel_spm_ambigua`) es un hallazgo distinto
(N11: expansión de chunks insuficiente en `structured_evidence_route` para
preguntas que exigen comparar contenido a través de un rango de varias páginas).
Detalle completo en la fila de Estado de la Fase 5.

**Impacto real:** este es el **tercer holdout consecutivo que no pasa** (v1: 47/88;
v2: 70/88 pero safety_critical falló 2/9 por N7; v3: 119/133 pero safety_critical
falló 8/10 por N10) y el **segundo consecutivo que falla específicamente en la
garantía de seguridad**, aunque por una causa raíz distinta cada vez (guard mal
calibrado en v2, colisión de retrieval entre secciones duplicadas en v3). Ningún
caso de seguridad de v1/v2/v3 ha llegado limpio dos veces seguidas por el mismo
mecanismo — el patrón sugiere una fragilidad estructural del enfoque (parchear
causa raíz por causa raíz, un ciclo a la vez) más que un bug aislado.

**No se ejecuta sin decisión:** por la regla del Protocolo de plan vivo v2 (punto 6)
y por la regla explícita de la Fase 5 del plan ("no hay ciclo 4 con esta
estrategia"), esta sesión **no intenta ningún arreglo** (ni de N10 ni de N11). El
holdout v3 queda gastado — no se reabre, ni completo ni con
`RAG_SEGURIDADES_CASE_IDS`. Opciones para el dueño del producto:

- **Opción A — Guardrails operacionales:** no perseguir más precisión automática
  vía RAG puro para preguntas de seguridad; añadir una capa determinista (p.ej.
  `DeterministicRenderer`/verificación humana obligatoria) específicamente para
  respuestas de categoría `safety_critical` antes de mostrarlas al técnico, en vez
  de confiar en que el retrieval elija siempre la página correcta.
- **Opción B — Atacar N10 en su raíz:** un ciclo 4 con estrategia DISTINTA
  (permitido — la regla prohíbe repetir "esta estrategia", no un ciclo nuevo)
  enfocado en desambiguar retrieval entre secciones con contenido casi idéntico
  (p.ej. forzar coincidencia de página exacta cuando la pregunta la nombra
  explícitamente, no sólo nombre de sección/modelo).
- **Opción C — Pausar pilotaje de seguridades** hasta que el dueño del producto
  y un ciclo futuro resuelvan N10, dado que el fallo afecta directamente un caso
  de seguridad real (bypass de protección eléctrica).

**Pendiente:** el dueño del producto elige A/B/C. Esta sesión se detiene aquí — no
hay Fase 6 en este plan; el siguiente paso depende de la decisión.

## Anexo A — Prompt de arranque por fase

**Pie común (añadir al final de cada prompt):**

> Lee primero `docs/rag/plan_precision_definitiva_2026-08-03.md` completo (incluida la
> tabla de Estado y los hallazgos N1–N7) y la fila de Estado de la fase anterior.
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

> ⚠️ CRÍTICO: el diagnóstico de la Fase 1 (2026-08-03) cambió qué hay que arreglar.
> La causa raíz confirmada y reproducida offline ($0) del fallo v2 es **N7**: el guard
> `Rag::DeterministicIntent.ambiguous_hardware_query?`
> (`app/services/rag/deterministic_intent.rb:26-27,59-69`) intercepta la pregunta ANTES
> de generación y la sustituye por un menú de desambiguación (`model_invoked: false`)
> porque `EXPLICIT_EQUIPMENT_PATTERN` no reconoce "ARCA"/"ARCA II"/"ARCA III"/"ARCA
> BASICO" (sólo la marca "ORONA" escapa) ni designadores de una sola letra + dígitos
> ("J24", "J25", "J26"). **H-A (contaminación `canonical_name`/`aliases` vía la
> instrucción de fidelidad al modelo nombrado) se refutó como mecanismo causal**: el
> prompt actual ya usa chunk_63 correctamente pese al `canonical_name` contaminado (2 de
> 3 preguntas ad-hoc de la Fase 1 llegaron a generación y citaron el chunk bien). No
> ejecutes el punto "2b" tal como estaba redactado — está descartado. Orden real:
> (2d, PRIORIDAD 1 — nuevo) amplía el escape de `ambiguous_hardware_query?` para
> reconocer nombres de modelo sin dígito (ARCA y variantes) y designadores de una letra
> (J24/J25/J26 y los que el grep de sólo lectura sobre los 97 cuerpos confirme); declara
> hipótesis (§8.3) y verifica con tests unitarios
> (`test/services/rag/deterministic_intent_test.rb`,
> `test/services/rag/regex_characterization_test.rb`) MÁS las 3 preguntas ad-hoc de la
> Fase 1 (mismo patrón local contra KB de producción, rúbrica ad-hoc no se reusa, se lee
> a mano) confirmando que `adhoc_fase1_arca3_bypass_j24` deja de dar
> `generation_mode: "deterministic_model_disambiguation"`; (2a, higiene de datos, no
> bloquea el gate por sí sola) corrige `canonical_name`/`aliases` de los **91** sidecars
> afectados (no sólo chunk_63 — lista en la Fase 1) desde la verdad-terreno de §5, patrón
> `section_identity`, y UN solo resync del KB (`BulkKbSyncService`) — el backfill
> `section_identity` que el plan anterior daba por pendiente **ya se publicó y ya se
> verificó 100% correcto** en la Fase 1, no hay nada que verificar ahí, sólo no
> pisarlo con datos peores; (2c) repara `ACUÑAIENTO` en chunk_94 con el patrón exacto de
> `script/patch_seguridades_field_record_osbtaculo_2026-08-03.rb` (ETag + backup +
> SHA256 post-escritura), dentro del mismo resync de 2a/2d. Declara hipótesis y
> resultado esperado si es falsa (§8.3) por cada intervención. ≤ 6 llamadas Bedrock.

### Fase 3 — Sonnet 5 (sesión nueva; si participaste en la Fase 2, detente: lo redacta otra sesión)

> ⚠️ CRÍTICO: la Fase 2 (2026-08-03) arregló el guard `ambiguous_hardware_query?`
> pero con alcance ESTRECHO, no genérico — importa para redactar el caso de
> seguridad "bypass-puentes". El escape ahora reconoce (a) el nombre de modelo
> "ARCA"/"ARCA II"/"ARCA III"/"ARCA BASICO" sin dígito pegado, y (b)
> designadores de puente de la forma `J` + 1-2 dígitos (J1-J50, confirmado por
> grep de sólo lectura sobre los 97 cuerpos: es la única letra usada como
> designador de puente/bypass en todo el documento). Si tu caso de bypass usa
> ese vocabulario (p.ej. "En ARCA III, ¿qué implica el puente J24/J26?"), el
> guard YA NO lo intercepta — puedes escribirlo con confianza. **No asumas que
> cualquier otro designador de una sola letra escapa igual**: "K2"/"K3" (por
> ejemplo, si tu holdout tocara la sección EDEL) siguen sin reconocerse a
> propósito, porque ahí la letra es parte del NOMBRE del modelo, no un puente,
> y generalizar el escape rompería una expectativa congelada de
> `regex_characterization_test.rb` (huecos 4-5, `DEUDA · P4`, migración más
> grande y todavía bloqueada). Si tu pregunta de bypass usa un designador o
> marca que no sea "ARCA"/variantes o "J"+dígitos, verifica primero con
> `Rag::DeterministicIntent.ambiguous_hardware_query?("tu pregunta")` en una
> consola local ($0, sin Bedrock) antes de congelarla — si devuelve `true`,
> el caso caerá en el menú de desambiguación y no medirá lo que crees.
> También quedó pendiente una decisión humana (#7, presupuesto Bedrock del
> ciclo) que puede afectar si Fase 5 corre completa — confirma que está
> resuelta antes de dar por bueno el criterio de cierre de tu holdout.
>
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

> ⚠️ CRÍTICO: antes de tu llamada de humo, lee la decisión humana #7 (presupuesto
> Bedrock del ciclo excedido en Fase 2 — 18/30 gastadas antes de Fase 4). Si el
> dueño del producto no la resolvió todavía, detente y pregunta en vez de asumir
> que puedes gastar tu llamada de humo — es bloqueante, no cosmético. Si eligió
> la opción B (reusar `tmp/rag_seguridades_adhoc_fase2_postresync_2026-08-03_run1.json`
> como evidencia de KB caliente en vez de una llamada nueva), no repitas el
> `retrieve` de humo.
>
> Checkpoint de despliegue previo al gate: confirma que la Fase 2 está commiteada con
> tests verdes y el resync del KB `COMPLETE`. Haz `kamal deploy` (o verifica que el
> contenedor ya sirve el commit): el SHA desplegado debe incluir el último commit que
> tocó `app/prompts/`, `app/services/rag/` o `config/`. Humo: 1 `retrieve` confirmando
> que un chunk reparado sirve el contenido nuevo (p.ej. aliases ARCA en chunk_63) — la
> pregunta de humo no puede ser de ningún holdout. Aurora caliente (`kb_retrieve` <
> 1s, sin `AuroraColdStartRetry`). Anota en la tabla de Estado: SHA desplegado, id del
> job de sync, timestamp. NO abras el holdout v3: eso es la Fase 5.

### Fase 5 — Haiku 4.5

> ⚠️ CRÍTICO: decisión humana #7 **RESUELTA** — el dueño del producto confirmó
> presupuesto disponible antes de iniciar Fase 4. Fase 4 corrió su humo con
> **opción A** (llamada nueva, no reutilización), pero por un detalle operativo
> (`kamal app exec --reuse` sin `--role` corre en web+worker a la vez) costó
> **2 llamadas Bedrock, no 1**. Presupuesto real del ciclo antes de Fase 5:
> 6 (Fase 1) + 12 (Fase 2) + 2 (Fase 4) = **20 de 30**. Tus 14 llamadas de
> Fase 5 llevan el total a **34, ~4 sobre el techo original de <30** — el
> dueño del producto ya está al tanto y no lo consideró bloqueante; no vuelvas
> a escalarlo como decisión nueva, sólo anota el total real en tu fila de
> Estado. Si tú también usas `kamal app exec --reuse`, decide con criterio si
> quieres limitarlo a un solo rol (`--role web`) para no duplicar el gasto de
> las 14 llamadas del holdout — el patrón Kamal del v1/v2 referenciado abajo
> no lo especifica, así que queda a tu criterio documentarlo si lo cambias.
>
> Nota (no cambia tus pasos, sólo cómo diagnosticas un fallo): la Fase 3 dejó dos
> hallazgos nuevos que conviene tener presentes al leer `results[]`. **N8:** 96 de
> 97 cuerpos de chunk (no sólo metadatos — eso ya lo arregló 2a) siguen llevando la
> línea incrustada `**Document:** ALJO Control Level 1B Altius`, incluso en páginas
> que nunca fueron ALJO (FAIN, SISTEL, CARLOS SILVA); por eso el v3 no exige nombrar
> la marca correcta salvo en los dos casos de página divisora y el de la página 3
> (ALJO real) — si un caso no-ALJO falla por marca equivocada, es N8, no el guard de
> la Fase 2, y se clasifica aparte. **N9:** este guion (`rag_seguridades_benchmark.rb`)
> nunca invoca `Rag::DeterministicRenderer` (a diferencia de producción), así que los
> dos casos de "checklist detener-trabajo" y "prueba funcional" miden generación
> genérica sobre un `STOP_WORK_CONDITION`/`INSPECTION_CHECK` real de la página 9, no
> los renderers deterministas de la Fase 7 del plan quirúrgico — están redactados a
> propósito para no disparar esos intents (`RECORD_TYPE: FUNCTIONAL_TEST` tiene 0
> apariciones en el documento; si el renderer se llegara a invocar, fallaría siempre).
> Ninguno de los dos hallazgos bloquea el criterio de cierre de este ciclo.
>
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
>
> **Resultado (ejecutado 2026-08-03): NO PASA.** Score 119/133 (89.5%, cumple el
> umbral) pero 1/4 `safety_critical` falló (`holdout_v3_fain_jumper_falta_fase_seguridad`,
> N10 — colisión de retrieval entre secciones con tablero casi idéntico, FAIN p.46 vs
> RECOBA p.79; ver fila de Estado de la Fase 5 y decisión humana #8). Plan cerrado en
> este punto: no hay Fase 6 en este documento — el siguiente paso depende de la
> decisión #8 del dueño del producto.

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
