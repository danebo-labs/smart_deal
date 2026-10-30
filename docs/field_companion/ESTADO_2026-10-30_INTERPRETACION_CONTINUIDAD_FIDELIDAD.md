# Estado para reanudar — 30 de octubre de 2026

Interpretación, continuidad y fidelidad documental. Este archivo es el punto de reanudación. No reabre F5, no declara `EPISODIO_VALIDADO` y no integra un verificador. No hubo deploy. Las llamadas de este experimento no se repiten.

HEAD `5c7cf7073d3fc5abe0d4eff1d8c6e37d30c01ebb` («Documenta segundo guion VF5 con respaldo literal, expectativas y diagnóstico»). La candidata de interpretación está sin commit encima de ese HEAD. Los crudos del experimento siguen en `tmp/`.

## Veredicto

El experimento de tres configuraciones del verificador de fidelidad, variante B, **no se superó**. Ninguna configuración queda como candidata de producto. La regla de parada ya estaba escrita en `tmp/vf5_verificador_20261030/variante_b/ANALISIS.md`: aprobar M06, M07 o N02; bloquear V06, N01, N03 o N04; aprobar M10 o R04; o emitir una salida inválida. Las tres la incumplen. No se prepara otra variante de prompt ni otra pasada.

La rúbrica y el marcador siguen congelados en `tmp/vf5_verificador_20261030/comparacion_modelos/RUBRICA.md` y `marcador.json`. Las etiquetas históricas no se mueven. Una salida inválida no es una detección, aunque el veredicto crudo coincida con la rúbrica.

## Tres configuraciones

Misma evidencia, mismo prompt B y mismo esquema. Una pasada, sin reintentos. Opus no se llamó.

| | Haiku 4.5 | Haiku 5.5 | Sonnet 5.5 |
|---|---|---|---|
| Proveedor | Bedrock Converse | API de Anthropic, `POST /v1/messages`, versión `2023-06-01` | Igual que Haiku 5.5 |
| Id devuelto | `global.anthropic.claude-haiku-4-5-20251001-v1:0` | `claude-haiku-5-5` | `claude-sonnet-5-5` |
| Temperatura | 0 | Omitida | Omitida |
| `max_tokens` | 650 | 1000 | 1000 |
| Herramienta | `tool_choice` forzado a `semantic_check` | Forzado a `semantic_check` | `auto` |
| Pensamiento | No enviado | No enviado. `thinking_tokens` 0 | `thinking.type` `between_tools`. `thinking_tokens` 0. Hay preámbulo de texto, cobrado como salida |
| Llamadas | 16, reutilizadas. No se repitieron por Anthropic | 16, todas `tool_use` | 16. Catorce con herramienta completa (`tool_use` o `end_turn`). Dos en `max_tokens` |
| Crudos | `tmp/vf5_verificador_20261030/variante_b/results/20261030T145217Z/` | `tmp/vf5_verificador_20261030/comparacion_modelos/results/20261030T210053Z/haiku55_*.json` | El mismo directorio, `sonnet55_*.json` |
| Request id | Esas filas no lo guardan | Cabecera `request-id` y `response_id` en cada fila | Igual |

Haiku 4.5 y los otros dos no salieron por el mismo proveedor. La repetición por Anthropic está escrita en `tmp/vf5_verificador_20261030/comparacion_modelos/run_haiku45_anthropic.rb` y no se ejecutó. No forma parte de este resultado.

Bedrock negó `global.anthropic.claude-haiku-5-5` y `global.anthropic.claude-sonnet-5-5` con `AccessDeniedException` en la primera llamada de cada uno, cero tokens: `results/20261030T205831Z/`. Eso no es una cuarta configuración.

## Unidad del coste

Unidad única: **dólares estadounidenses (US$)**. Estimación de lista sobre el `usage` del proveedor. `inference_geo` global, multiplicador 1. Caché 0. No es factura conciliada y no se suma al intérprete ni a la generación.

La tarifa del libro de producto, `BedrockQuery::BEDROCK_PRICING`, es **US$ por 1 000 tokens**. El coste es `(tokens / 1 000) × coeficiente`. El mismo número, escrito por millón de tokens, es el coeficiente multiplicado por 1 000.

| Modelo | Entrada, US$ / 1 000 tokens | Salida, US$ / 1 000 tokens | Equivale a, por millón |
|---|---:|---:|---|
| Haiku 4.5 global | 0,001 | 0,005 | 1 US$ / 5 US$ |
| Haiku 5.5, prompt corto (≤ 100 000 tokens de entrada) | 0,0001 | 0,0005 | 0,10 US$ / 0,50 US$ |
| Sonnet 5.5 | 0,002 | 0,01 | 2 US$ / 10 US$ |

Haiku 5.5 no tiene fila en `BEDROCK_PRICING`. Estas 16 llamadas se tasan con la lista corta de arriba. Revalorarlas con la fila de Haiku 4.5 daría 0,090468 US$, diez veces la lista. Revalorarlas con `default` (0,00025 / 0,00125 por 1 000 tokens) daría otra cifra. Ninguna de las dos es el coste de esta pasada.

El coeficiente 0,001 es US$ por 1 000 tokens de entrada de Haiku 4.5. Multiplicar los 43 526 tokens por 0,001, sin dividir por 1 000, produce 43,526 US$ de entrada y un total de 70,631 US$. El coste de esas 16 llamadas es 0,070631 US$.

| Modelo | Llamadas | Entrada | Salida | US$ de las 16 | US$ por llamada |
|---|---:|---:|---:|---:|---:|
| Haiku 4.5 | 16 | 43 526 | 5 421 | 0,070631 | 0,004414 |
| Haiku 5.5 | 16 | 50 753 | 7 943 | 0,009047 | 0,000565 |
| Sonnet 5.5 | 16 | 48 705 | 12 455 | 0,221960 | 0,013873 |

Comprobación Haiku 4.5: `(43 526 / 1 000) × 0,001 + (5 421 / 1 000) × 0,005 = 0,070631`. Haiku 5.5: `(50 753 / 1 000) × 0,0001 + (7 943 / 1 000) × 0,0005 = 0,009047`. Sonnet 5.5: `(48 705 / 1 000) × 0,002 + (12 455 / 1 000) × 0,01 = 0,221960`.

Las 32 llamadas nuevas suman **0,231007 US$** (`spent.json` de `20261030T210053Z`). La reserva previa, con un recargo `us` de 1,1 que el `usage` no aplicó, era 0,325574 US$. El tope del experimento era 1 US$.

La fila de Sonnet en el libro de producto deja la lectura de caché en 0,0002 US$ por 1 000 tokens (0,20 US$ por millón). La lista usada en la reserva de esta pasada es 0,0001 US$ por 1 000 tokens. Esta pasada tuvo caché 0, así que el total no cambia.

Latencia, en milisegundos: Haiku 4.5 p50 2 651, máximo 8 871. Haiku 5.5 p50 2 747, máximo 3 838. Sonnet 5.5 p50 6 517, máximo 14 323.

El recorrido actual no llama a este verificador. Añadirlo, con una llamada por turno, suma la columna «US$ por llamada» encima del intérprete y de la generación.

El informe contemporáneo `results/20261030T210053Z/INFORME.md` usa los mismos totales. Su prosa de «diezmilésimas» y «centavos» queda sustituida por esta tabla. Los JSON crudos no se reescriben.

## Fallos separados

Marcador principal: 5 que deben rechazarse (M06, M07, N02, M10, R04) y 4 que deben aprobarse (V06, N01, N03, N04). El mismo denominador para las tres. Una casilla inválida no entra en el acierto.

### Semánticos

Salida válida y veredicto distinto de la rúbrica. Cuentan.

Errores aprobados:

| Caso | Haiku 4.5 | Haiku 5.5 | Sonnet 5.5 |
|---|---|---|---|
| M06 | aprobado | rechazado | rechazado |
| M07 | aprobado | aprobado | rechazado |

N02 lo rechazan los tres. M10 y R04 no están en esta tabla: M10 cae en esquema para los dos Haiku, y R04 cae en truncamiento para Sonnet.

Falso bloqueo: Haiku 4.5 rechaza N04. Haiku 5.5 y Sonnet 5.5 aprueban V06, N01, N03 y N04.

Fuera del marcador, con salida válida, sin puntuar:

| Caso | Haiku 4.5 | Haiku 5.5 | Sonnet 5.5 |
|---|---|---|---|
| V09 | rechazado | rechazado | truncada |
| R01P2 | rechazado | rechazado | aprobado |
| R02P1 | aprobado | esquema | rechazado |
| I01 | insuficiente | insuficiente | insuficiente |
| I02 | rechazado | esquema | rechazado |
| I03 | esquema | esquema | insuficiente |
| N05 | insuficiente | insuficiente | esquema |

### Esquema

`stop_reason` `tool_use`. La herramienta llega y el enum o un campo obligatorio no valida. El veredicto crudo no cuenta.

| Caso | Configuración | Qué falla | Veredicto crudo, no contado |
|---|---|---|---|
| I03 | Haiku 4.5 | `fallos` contiene `distorsionada`, valor de `soporte` | rechazado |
| M10 | Haiku 4.5 | `fallos` contiene `distorsionada` | rechazado |
| R02P1 | Haiku 5.5 | `fallos` contiene `distorsion_o_presuposicion` | rechazado |
| I02 | Haiku 5.5 | `fallos` contiene `distorsionada` | rechazado |
| I03 | Haiku 5.5 | `fallos` contiene `distorsionada` | rechazado |
| M10 | Haiku 5.5 | `fallos` contiene `distorsion_de_finalidad` | rechazado |
| N05 | Sonnet 5.5 | falta `fallos` | insuficiente |

### Truncamiento

`stop_reason` `max_tokens`, 1 000 tokens de salida, P1 sin cerrar, veredicto ausente. Sonnet 5.5 en V09 y en R04. No son detecciones. No se sube el tope ni se repite la llamada para cerrarlas.

Sonnet en M07 e I01 terminó en `end_turn` con la herramienta completa. Esas dos sí cuentan, y están en la tabla semántica.

## Candidata local frente a HEAD

Sigue en el árbol de trabajo. No se revierte para dejar `main` limpio y no se commitea desde este estado.

Modificados:

- `app/prompts/bedrock/companion_plan.txt`
- `app/services/rag/active_episode.rb`
- `app/services/rag/companion_plan.rb`
- `app/services/rag/companion_plan_check.rb`
- `app/services/rag/pending_question.rb`
- `app/services/rag/work_context_reducer.rb`
- `test/services/rag/companion_f3_disambiguation_test.rb`
- `test/services/rag/companion_plan_test.rb`
- `test/services/rag/compound_partial_answer_test.rb`

Sin seguimiento:

- `test/services/rag/companion_plan_interpretation_test.rb`
- `test/fixtures/vf5_apertura_lenta_20261030/`

Qué hace la candidata, en el checker y en el prompt: una paráfrasis de la afirmación enlazada puede publicarse. Sigue bloqueada una operación, una prescripción, una exclusión, un valor, una unidad o un designador que no están en el enunciado citado ni en el hecho enlazado. Una pregunta rechazada por valor, unidad o designador no se sustituye por otra avería. Un enunciado de tipo `text` guarda la frase del fabricante, recortada a 160 caracteres, y no el título de la sección como síntoma padre. Un apartado largo deja de aportar sus números impresos como dato extra que la respuesta tenga que cubrir.

Los planes capturados de la apertura lenta están en `proposals/r1_t1.json`, `r1_t2.json`, `r2_t1.json` y `r2_t2.json`. Los cuatro cuerpos y sus SHA están fijados en el test nuevo. `chunk_p8_1.txt` contiene la frase de §5.8: «Las puertas se abrirán lentamente en la primera operación después de un fallo de alimentación para verificar el paso libre.» T3 de ese guion no está capturado.

En esta sesión, sin llamadas a modelo, la candidata pasa `companion_plan_interpretation_test`, `companion_plan_test`, `compound_partial_answer_test`, `pending_question_test`, `companion_f3_disambiguation_test`, `vf5_gui_replay_test` y `vf5_section56_admission_test`. Esas mismas pruebas de continuidad y de la regresión web F5 que abajo fallan, pasan en HEAD `5c7cf70`.

## Regresiones pendientes de la candidata

El checker ya no descarta una pregunta por palabras ajenas al enunciado. En HEAD esa pregunta se rechazaba y permanecía la formulación documental. Con la candidata se publica el texto capturado del plan.

1. `Rag::Vf5ContinuityReplayTest#test_morning_keeps_the_led_correction_and_the_unknown_on_the_named_datum`. El pendiente que debe seguir es «¿Está activada la fotocélula o la entrada de re-apertura (#21)?», el plan de T2. Pasa a «¿Está activada la entrada de re-apertura (#21)?», que es el plan capturado de T3 y de T4 en `test/fixtures/vf5_continuity_20261027/morning/`. Se cae la alternativa de la fotocélula.

2. `Rag::Vf5ContinuityReplayTest#test_a_generated_photocell_name_does_not_identify_the_generic_led`, línea de `already_answered`. El plan forjado pregunta «¿El LED encendido es el de fotocélula?» sobre S1.9. HEAD lo rechaza con `already_answered` y no publica pregunta. La candidata no deja ese rechazo y la pregunta sigue.

3. `Vf5F5WebRegressionTest#test_a_later_run_that_publishes_only_the_clarification_keeps_it_beside_the_open_question`. `shown` debe seguir siendo «¿El LED encendido es el de Fotocélula o el de Estado?». Queda «¿El LED encendido es el de Fotocélula o el de Estado del módulo?», la pregunta capturada en `test/fixtures/vf5_f5_regression_20261028/t4.json`.

4. `Vf5F5WebRegressionTest#test_an_unknown_about_the_designated_part_of_a_compound_question_binds_to_that_part_only`. El pendiente debe seguir siendo «¿Está activada la fotocélula o hay una señal de re-apertura (#21) activa continuamente?». Queda «¿Está activada la señal de re-apertura (#21) continuamente, o solo la fotocélula está inactiva?», la pregunta capturada en `test/fixtures/vf5_f5_regression_20261029/t3.json`.

Esas cuatro se corrigen en la candidata, con las pruebas que ya existen. No se relajan las expectativas para que el texto capturado pase, y no se usa el verificador de este experimento para decidirlas.

Queda abierto dentro de la propia candidata, y el test nuevo lo deja así a propósito:

- Quitar una negación que el enunciado sí tiene no se detecta. «Las bombas arrancan solas» se publica cuando el enunciado dice que no arrancarán.
- Una alternativa omitida con otras palabras, sin tallos en común, no se detecta. «El dato queda guardado en memoria» pasa el heurístico de «o».
- Un sustantivo de componente no entra en la atribución. «La fotocélula explica la primera apertura lenta» se publica sobre la frase del paso libre.
- «Fallo de la placa base» no es valor, unidad ni designador, y no se bloquea.
- El pasado «se abrieron lentamente» se publica; la cita documental sigue en futuro.

Esos huecos son de fidelidad del checker. No se cierran con otra llamada a Haiku 5.5 ni a Sonnet 5.5.

## Cómo retomar cada hilo

**Interpretación.** Seguir en la candidata sin commit. El replay determinista de T1 y T2 de la apertura lenta ya conserva la paráfrasis, la pregunta y el descarte del otro síntoma. El arreglo siguiente es que una pregunta capturada no sustituya el pendiente documental cuando estrecha la alternativa o añade un límite que el caso no tiene. Las cuatro pruebas de arriba son la barra.

**Continuidad.** El pendiente de la mañana y el de F5 tienen que seguir nombrando la fotocélula y la entrada #21 juntas, y el desconocimiento de #21 sigue atado a esa pregunta. La aclaración del LED sigue al lado, sin convertirse en el dato #21. El apartado largo no mete la tensión de alimentación como dato pedido: eso ya lo cubre `companion_plan_interpretation_test` y pasó. El guion de reapertura aceptado no se reabre; estas cuatro pruebas son la regresión de esa aceptación.

**Fidelidad documental.** El verificador de las tres configuraciones queda cerrado como experimento no superado. Evidencia que se conserva y no se regenera:

- Variante B: `tmp/vf5_verificador_20261030/variante_b/` (`prompt.txt`, `schema.json`, `dataset.json`, `frozen.json`, resultados `20261030T145217Z`).
- Comparación: `tmp/vf5_verificador_20261030/comparacion_modelos/` (`RUBRICA.md`, `marcador.json`, `PROVEEDOR.md`, `payloads_anthropic/`, resultados `20261030T210053Z` y el intento Bedrock `20261030T205831Z`).
- Línea base anterior a la variante B: `tmp/vf5_verificador_20261030/results/20261030T143757Z/`.
- Candidata de la apertura lenta: `test/fixtures/vf5_apertura_lenta_20261030/`.

El segundo guion VF5, primera apertura lenta tras un corte, sigue sin ejecución GUI. T1–T3, la selección explícita del VF5 y el diagnóstico contra el PDF están en la sección «Segundo guion VF5» del plan de conversación. `chunk_p8_1.txt` del fixture local ya trae la frase de §5.8; eso no sustituye la recuperación en vivo ni la respuesta publicada. Si el recorrido GUI se hace, se compara el texto publicado con el PDF y con esta candidata. No se vuelven a llamar los tres verificadores para ese diagnóstico.

Después de ese guion, la cola sigue igual: plano Elemont MH, fotos, cambio de tema y retorno.
