# Holdout SEGURIDADES v1 — resultado y clasificación de fallos (2026-08-03)

**Alcance:** Fase 1 + Fase 2 de `docs/rag/plan_quirurgico_precision_2026-08-02.md`.
Corrida única e irrepetible (diagnóstico §2): `script/fixtures/rag_seguridades_holdout_v1.json`
queda **gastado** a partir de hoy como línea base. No se vuelve a abrir — un
holdout que se corre dos veces deja de ser holdout.

---

## 1. Corrida

**Comando ejecutado** (Kamal, contenedor `web`, `--reuse`, host único, mismo
patrón que la corrida de `pilot_v2` del 2026-07-29):

```bash
bundle exec kamal app exec --reuse -r web -p \
  "sh -c 'RAG_SEGURIDADES_RUBRIC=script/fixtures/rag_seguridades_holdout_v1.json RAG_SEGURIDADES_OUTPUT=tmp/rag_seguridades_holdout_v1_run1_2026-08-03.json bin/rails runner script/rag_seguridades_benchmark.rb'"
```

- **Commit desplegado en PROD:** `7fc8f2ae0225f40d3f4e6411d191a49207d2138d` —
  idéntico al `HEAD` local en el momento de la corrida (confirmado con
  `kamal app details`).
- **Configuración real de producción** (leída de `config/deploy.yml`, no del
  `.env` local que apunta a desarrollo): KB `Y7RZWMFJSR`, data source
  `PJ0N58DMHG`, modelo `global.anthropic.claude-haiku-4-5-20251001-v1:0`.
  Flags: `RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED=true` (el único encendido),
  `RAG_EVIDENCE_SELECTOR_ENABLED/EXPANSION/CARDS=false`,
  `RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED=false`,
  `RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED=false`, `QUERY_ROUTING_ENABLED=false`.
  Nada de T1/T2/triaje visual (sin variable en `deploy.yml` → default off).
  Esto es "la configuración de producción actual, flags apagados" tal como
  pidió el encargo.
- **Documento:** `SEGURIDADES 1.1-1`, `id=12`, `account_id=1` (fila real, no
  fallback).
- **`run_id`:** `seguridades:66b058d4-0e2e-4a70-a2b3-be3973a86bd9`.
- **Artefacto crudo completo** (10 preguntas, chunks recuperados, respuesta
  cruda e interna, citas, `retrieval_trace`): `tmp/rag_seguridades_holdout_v1_run1_2026-08-03.json`
  (fuera de git, bajo `tmp/`, como el resto de artefactos de benchmark).
- **Verificación de Aurora no-fría** (requisito de `[[project_502_coldstart_fix_deployed]]`
  antes de gastar el holdout): las 12 llamadas `kb_retrieve` del log de la corrida
  midieron 455–572 ms, y las 10 preguntas completas tardaron 40.96 s en total —
  muy por debajo de los 56-105 s de un cold-start real de Aurora Serverless, y sin
  ningún marcador `AuroraColdStartRetry` en el log. Aurora ya estaba caliente
  (actividad previa de esta misma sesión vía `kamal app details`/`exec`); el
  resultado no está contaminado por retrieve degradado post-pausa.

## 2. Resultado

**2/10 casos pasados, 47/88 (53%).** Por debajo de `passing_score: 70`, y muy
por debajo de las cohortes sobreajustadas (83/88, 10/10). Confirma la lectura
honesta del diagnóstico §1: los muestreos aleatorios no certificados eran la
señal real, no el ruido.

| Caso | Categoría rúbrica | Resultado | Score |
|---|---|---|---|
| `holdout_nonadjacent_ekm66_codes` | parafrasis_etiqueta_identificador_no_adyacente | FAIL | 7/11 |
| `holdout_sibling_ne300_p36` | placa_hermana_negada | FAIL | 2/7 |
| `holdout_page64_table` | numero_distractor_pagina | FAIL | 2/10 |
| `holdout_sph_two_boards` | mismo_codigo_dos_placas | **PASS** | 9/9 |
| `holdout_otis_es_ambiguous` | fabricante_sin_modelo | FAIL | 3/11 |
| `holdout_unknown_zz9000` | modelo_inexistente | **PASS** | 5/5 |
| `holdout_em4000_v2_absent` | sufijo_version_no_fusionado | FAIL | 5/7 |
| `holdout_arca_p36_torque` | multiobjetivo_parcial | FAIL | 7/9 |
| `holdout_compare_ekm66_pressure` | comparativa | FAIL | 5/8 |
| `holdout_page26_led_count` | etiqueta_sin_identificador | FAIL | 2/11 |

## 3. Clasificación de los 8 fallos

Encargo original: recuperación (R) / generación (G), más una tercera
categoría, **guard**, para las respuestas cortadas por un componente
determinístico antes o después del modelo. Nota importante para la Fase 3 del
plan: la categoría **P — post-proceso** que el plan anticipaba estaba
acotada a `rag/answer_safety_processor.rb`. Ninguno de los 8 fallos pasa por
ese componente. El guard real que domina esta corrida es **otro**:
`Rag::DeterministicIntent.ambiguous_hardware_query?` /
`Rag::AmbiguousModelResponder`, no contemplado en la Fase 3 del plan tal como
está escrita hoy.

| Caso | Categoría | Evidencia leída del artefacto |
|---|---|---|
| `holdout_page64_table` | **Guard** | `generation_mode: "deterministic_model_disambiguation"`, `model_invoked: false`. La pregunta menciona "LED" (dispara `GENERIC_HARDWARE_PATTERNS`) y no nombra fabricante/código alfanumérico (no satisface `EXPLICIT_EQUIPMENT_PATTERN`), así que `ambiguous_hardware_query?` la marca ambigua y `AmbiguousModelResponder` responde "elige una" **sin retrieval real por página**. El técnico ya había desambiguado por número de página; el heurístico no reconoce esa vía. |
| `holdout_page26_led_count` | **Guard** | Mismo mecanismo exacto que el caso anterior — mismo `generation_mode`, mismo `model_invoked: false`, misma respuesta canónica "elige una". Un solo bug de código explica los dos fallos. |
| `holdout_sibling_ne300_p36` | **Generación** | El chunk correcto (`section_identity: "OTIS"`, alias `"NE 300 LB II, P1, P3, P4, ES serie seguridades..."`, página 67) fue recuperado y fue el **mejor puntuado** de los 12 (`score: 0.5`). También estaban en contexto los chunks de "ARCA II" (pág. 63) y "ARCA III" (pág. 64), ambos con su propio LED P36. El modelo ignoró el chunk mejor puntuado y respondió citando "ARCA II" — confundió la placa hermana en vez de declarar que P36 no está documentado para NE 300 - LB II. Es exactamente el modo de fallo que el caso pretendía probar. |
| `holdout_otis_es_ambiguous` | **Generación** (con nota de recuperación parcial) | El chunk de "NE 300 – LB II" (pág. 67) con la tabla `ES → SERIE SEGURIDADES` estaba presente en los 12 chunks recuperados, íntegro y correctamente citado en su propio texto. La respuesta afirmó "el LED ES no aparece identificado" y en su lugar citó una lista de LEDs (D1, D2, D7...) de un chunk distinto (ALJO/Altius) — ignoró el hecho presente. Nota separada: ningún chunk de LCB II / GEN II (la otra mitad de la respuesta esperada) apareció entre los 12 recuperados — esa mitad sí es un hueco de recuperación, pero no es la causa principal del fallo porque el modelo tampoco usó la mitad que sí tenía. |
| `holdout_em4000_v2_absent` | **Generación** | Los 12 chunks recuperados sólo contienen "EM 4000 **V1**" (verificado por texto completo — ningún chunk de EM4000 V2 existe en el contexto, consistente con que V2 genuinamente no está documentado en el PDF). La recuperación hizo lo correcto: no hay nada más que traer. Pero la respuesta nunca menciona "V2" ni declara el desajuste de versión — sustituye V1 en silencio como si respondiera lo pedido, en vez de decir "sólo tengo V1 documentado, V2 no aparece". |
| `holdout_arca_p36_torque` | **Generación** | El chunk de ARCA III (pág. 64) trae la tabla correcta `P36 → SERIE OBSTÁCULO` (con tilde, bien escrita) **y**, más abajo en el mismo chunk, un bloque `FIELD_RECORD` de ingesta duplicado con la etiqueta corrupta `EVIDENCE: P36 SERIE OSBTACULO` (transposición de letras, sin tilde — aparece 3 veces en ese bloque). El modelo citó literalmente la copia corrupta del `FIELD_RECORD` en vez de la tabla correcta que tenía dos párrafos antes en el mismo contexto. Falla de generación con una causa raíz de calidad de datos de ingesta (anotación duplicada y con typo, no ausencia de dato). |
| `holdout_nonadjacent_ekm66_codes` | **Falso positivo de rúbrica** (no es un fallo del sistema) | Los 4 `required` pasan — la respuesta reproduce literalmente las tres series de SK0/SK1/SK2. El `penalized` "cambia seguridad principal por otra serie" dispara porque su patrón (`\bSK0\b.{0,70}(?:PUERTAS\|CERROJOS\|OBST[AÁ]CULO)`) no distingue una lista correcta ("SK0: SERIE SEGURIDAD PRINCIPAL / SK1: SERIE PUERTAS...") de una atribución cruzada real — el término "PUERTAS" de la línea de SK1 cae dentro de la ventana de 70 caracteres de SK0. La respuesta es correcta; el patrón de la rúbrica es demasiado amplio para listas de tres ítems. |
| `holdout_compare_ekm66_pressure` | **Falso positivo de rúbrica** (no es un fallo del sistema) | Los 3 `required` pasan (identifica hidráulico, presostato, excluye eléctrico). El `penalized` "atribuye el presostato a la variante eléctrica" dispara con el patrón `EL[EÉ]CTRIC(?:(?!\bno\b)).{0,100}PRESOSTATO` sobre la frase correcta "En la versión EKM66 ELÉCTRICO, el PRESOSTATO no aparece documentado" — el `(?!\bno\b)` sólo mira el hueco *antes* de "PRESOSTATO", y en esta frase el "no" está *después*, así que el patrón no lo ve y dispara igual. La respuesta distingue correctamente ambas variantes; el patrón de la rúbrica tiene un defecto de dirección en el lookahead. |

**Nota sobre los dos falsos positivos:** no se tocó `script/fixtures/rag_seguridades_holdout_v1.json`
—esta observación es informativa (para quien redacte el holdout v2 en la Fase
0b) y no cambia el score oficial de la corrida (47/88 es el número que cuenta,
tal como se congeló antes de abrirlo).

## 4. Lectura de la Fase 2: cuál es la rama dominante

De los 8 fallos, 6 son fallos reales del sistema (2 son ruido de rúbrica):

- **Guard: 2/6** — un solo bug (`DeterministicIntent.ambiguous_hardware_query?`
  no reconoce "página N" como desambiguación válida).
- **Generación: 4/6** — cuatro causas raíz distintas (confusión de placa
  hermana, sustitución silenciosa de versión, evidencia presente ignorada,
  cita de una anotación de ingesta duplicada y corrupta).
- **Recuperación: 0/6 fallos puros.** El único hueco de recuperación real
  (LCB II/GEN II ausente en `holdout_otis_es_ambiguous`) es secundario a un
  fallo de generación que ya bastaba para reprobar el caso.

**Esto invierte la hipótesis del plan visual** (que asumía recuperación) y
también obliga a corregir el alcance de la Fase 3 del plan quirúrgico: la
"Rama Guard" que hay que intervenir no es `answer_safety_processor.rb`
(Rama P original) sino `app/services/rag/deterministic_intent.rb` — un
componente distinto, no mencionado en el plan tal como está redactado hoy.

## 5. Restricción para la Fase 3

El holdout v1 queda gastado — **no se puede usar `RAG_SEGURIDADES_CASE_IDS`
sobre él para verificar ningún arreglo**, ni siquiera acotado a 1-2 casos: eso
sería una segunda apertura del mismo holdout. Cualquier corrección sobre
`DeterministicIntent.ambiguous_hardware_query?` debe verificarse con un test
unitario sobre el heurístico (regex puro, $0, sin Bedrock) — no con una
corrida de benchmark — hasta que el holdout v2 (Fase 0b, aún sin congelar)
esté listo para servir de gate.

## 6. Artefactos

- `tmp/rag_seguridades_holdout_v1_run1_2026-08-03.json` — corrida cruda completa
  (10 respuestas, chunks, citas, evaluación horneada).
