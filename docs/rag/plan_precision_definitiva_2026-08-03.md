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
| Sesiones de IA: 3× Sonnet 5 cortas + 2× Haiku 4.5 | mínimo; sin Opus/Fable |
| API de Anthropic desde la app | **$0** (ninguna llamada) |

## Estado

| Fase | Estado | Artefacto / hash |
|---|---|---|
| 1 Diagnóstico J25 | **hecho 2026-08-03** — H-B (guard `ambiguous_hardware_query?` mal calibrado, N7) confirmada como causa raíz y reproducida offline ($0) con la pregunta literal del v2; H-A refutada en su mecanismo causal (premisa de contaminación confirmada y ampliada a 91/97 sidecars, N6, pero el modelo usa chunk_63 correctamente pese a ello); H-C refutada (chunk_63 rank 1 siempre). 6 `retrieve_invocations` de 3 preguntas ad-hoc nuevas (J24/J26/overview, ninguna literal del v2), dentro del presupuesto de ≤10. | `tmp/rag_seguridades_adhoc_fase1_diagnostico_2026-08-03.json` (rúbrica, SHA256 `ecd04e15594d391de867e5e8a031cab60f743a080b21e3aa592141f5b5ba24de`) + `_run1.json` (artefacto completo, SHA256 `84260203969eb02f72a6cad3bc798621d21a3821225d8090f6385301cf8a4b10`), ambos fuera de git; `tmp/seguridades_sidecars_2026-08-03/` (97 sidecars vigentes, sólo lectura, fuera de git) |
| 2 Intervención mínima | **hecho 2026-08-03** — 2d (guard), 2a (91 sidecars) y 2c (chunk_94) aplicados y verificados; 2b sigue descartado (no tocado). **⚠️ Presupuesto Bedrock excedido: 12 llamadas, no ≤6** (ver "Resultado de la Fase 2" y decisión humana #7). Pendiente de desplegar (Fase 4). | Código: `app/services/rag/deterministic_intent.rb`, `test/services/rag/deterministic_intent_test.rb` (+4 tests). Script: `script/repair_seguridades_canonical_identity_and_acunaiento_2026-08-03.rb`. KB sync job `ZGCU99ISK5`, `COMPLETE`. Artefactos fuera de git: `tmp/rag_seguridades_adhoc_fase2_verificacion_2026-08-03_run1.json` (SHA256 `2c928bd108edfc54ea92c69f507baf340f26d75f71e17daff4b17121f8aac24a`, antes del resync 2a/2c), `tmp/rag_seguridades_adhoc_fase2_postresync_2026-08-03_run1.json` (SHA256 `bbc9f9ffa0877c2ba57f0ca855d1727a039f1974decbb87187682c89fc1f2162`, después). |
| 3 Holdout v3 congelado | pendiente (sesión distinta a Fase 2) — **leer la nota ⚠️ del prompt de Fase 3 antes de redactar el caso de bypass** | — |
| 4 Checkpoint despliegue | pendiente (tras Fase 2, antes de Fase 5) — **el commit a desplegar debe incluir el fix del guard (2d) y no hay cambio de prompt que desplegar** | — |
| 5 Gate v3 → piloto | pendiente — **⚠️ ver decisión humana #7: presupuesto del ciclo ajustado, confirmar antes de abrir** | — |

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

> ⚠️ CRÍTICO: verifica que la decisión humana #7 (presupuesto Bedrock del ciclo
> excedido en Fase 2) está resuelta antes de abrir el holdout — tus 14 llamadas
> son las que probablemente crucen el techo de 30 del ciclo. Si no está resuelta,
> detente y pregunta; no abras el holdout asumiendo "ya se gastó de más, da igual".
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
