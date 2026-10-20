# Fermator VF5+: recuperación del intérprete y secuencia real, 2026-10-20

No es aceptación textual. No declara `EPISODIO_VALIDADO`. No ejecuta la comparación de modelos.

HEAD al abrir: `c2600347e518ff6a8e999a6e6c43313b1d531aeb`. El proceso web de la secuencia cargó el árbol de trabajo con la recuperación del intérprete y sin el recorte por campo de `over_length`. Ese recorte se escribió después de leer el resultado. El servidor se detuvo al cerrar el cupo. Puerto 3000 libre.

## Causa del ServiceUnavailable

Captura `tmp/field_companion/validation_captures/vf5-codefix-20261020T1644Z`. Episodio `ep_57237a8a10576674`, sesión 198, cuenta 1, usuario 27. Tres eventos `interpreter_failure`, un intento cada uno, `aws_max_attempts` `1`, etapa `converse`.

| Request | Correlación | Hora | Latencia |
|---|---|---|---|
| `637e47c6-e250-46c3-b662-a021d529b3bf` | `query:604d805f-e934-4d7e-983b-a2307f6fcaa7` | 2026-10-20T13:45:39-03:00 | 3059 ms |
| `c183d77a-c39e-48ae-8c0d-8728e266ece5` | `query:a96491d1-468c-487a-9ed9-cab7c038efc8` | 2026-10-20T13:46:07-03:00 | 2422 ms |
| `40e3db1a-3705-4e64-b6ed-29fdb80d0840` | `query:498fdfdb-05d0-4635-af3e-64a15c29b5ad` | 2026-10-20T13:46:16-03:00 | 2969 ms |

Clase: `Aws::BedrockRuntime::Errors::ServiceUnavailableException`. Mensaje sanitizado, igual en los tres: `Bedrock is unable to process your request.` Modelo del request: `global.anthropic.claude-haiku-4-5-20251001-v1:0`. Tokens de esos tres intentos: 0 / 0. El pin `651d5534-40ab-4bf7-b035-ff12656d6927` no llamó al modelo.

La respuesta volvió en 2,4–3,1 s. El timeout de lectura del cliente del intérprete es 8 s y no llegó a dispararse. Entre el primer fallo y el segundo pasaron unos 28 s; entre el segundo y el tercero, unos 9 s. No hay una suspensión de cinco minutos en esa secuencia. `config.timeout_in` de Devise está comentado; el ejemplo del archivo es 30 minutos y no está activo. El idle HTTP compartido, `AWS_HTTP_IDLE_TIMEOUT` o su respaldo, es 5 segundos. El cliente de percepción lo hereda y sustituye solo apertura (2 s), lectura (8 s), `retry_limit` 0 y `max_attempts` 1.

La captura y el log no traen estado HTTP, request ID ni región de esas tres excepciones. El fallo es del servicio: la clase y el mensaje lo dicen, volvió antes del timeout de lectura, y no es un `AccessDenied` ni un error local de preparación. Esos tres campos que faltan quedan sin observación histórica. La secuencia posterior de este encargo no repitió `ServiceUnavailableException`, así que tampoco los llenó. Un fallo nuevo de `converse` guarda estado HTTP y request ID cuando el SDK los expone en `context.http_response`, y la región y los timeouts del cliente en el mismo evento.

## Recuperación

`TurnInterpreter` reintenta solo un `converse` transitorio: timeout, throttling, `ServiceUnavailable` / `InternalServer` / HTTP 500, 502, 503 o 504, y error de clase `Networking`. Tope: tres intentos físicos. Esperas 0,4 s y 1,2 s. No reintenta acceso, validación, un error local de preparación ni un `StandardError` de `converse` que no entre en esas clases. El SDK sigue en `max_attempts` 1 y `retry_limit` 0. Cada `converse` pasa por `LocalPassLedger.protect!`; el intérprete no admite la misma llamada otra vez. `LocalPassLedger::Stop` no es `StandardError` y sale del bucle. El timeout de lectura sigue en 8 s: alargarlo no habría cambiado los tres fallos de las 13:45.

Si los tres intentos se agotan, el turno queda `service_failure`. No llama a `QueryOrchestratorService` ni publica un diagnóstico. La respuesta es la de `rag.interpreter_service_failure`. En español: «No pude interpretar este mensaje. El servicio de interpretación no respondió. No hay un diagnóstico de este turno.» Un timeout que no es transitorio según esa lista, o un error de transporte no clasificado, conserva el fallback anterior.

`bin/rails test` de `turn_interpreter_failure_test`, `audit_capture_test`, `conversation_session_turn_interpreter_test`, `work_context_goal_test`, `interpreter_service_failure_route_test` y `turn_perception_test`, con el modo owner y la KB de la corrida fuera del entorno. 163 tests, 1642 aserciones, 0 fallos, semilla 24501, 1,0 s. Cero llamadas a AWS en esa pasada. Cubren la recuperación al tercer intento, el agotamiento con un solo mensaje de servicio, y una escritura de historial y de episodio.

## Tope de un campo

La secuencia de las 14:06 devolvió herramienta y el turno 1 quedó `over_length`. `TurnPerception.build` invalidaba el tool entero si un span pasaba de 60 caracteres o una observación de 180. Un campo largo tiraba también la identidad corta del mismo payload. Ahora se descarta solo el campo que se pasa. Un span largo se conserva si el catálogo resuelve una sola ventana de marca y designador, el texto de esa ventana cabe en 60 y sigue siendo literal en el turno. `over_length?` de la clase no cambia: el experimento sigue rechazando el payload crudo. No hay una excepción para Fermator. Las pruebas usan MONARCH NICE3000.

Ese arreglo no estaba cargado en el proceso de las 14:06. La secuencia real de abajo no lo ejerce.

## Secuencia real

Haiku 4.5 en los dos roles. Caso limpio `ep_50abb9e5ee609920`, abierto 2026-10-20T14:06:35-03:00, sesión 198, cuenta 1, usuario 27. Foco HTTP 200, documento 122, uid `126cda62-64ad-4469-8674-a29f12e38d48`, URI `s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf`. KB de la recuperación: `Y7RZWMFJSR`. El directorio de captura `vf5-retry-20261020T1706Z` no se creó y el log de esa ventana no tiene línea de admisión del ledger. Las siete filas de `bedrock_queries` sí están.

El intérprete respondió en los tres turnos. No hubo `ServiceUnavailableException` ni reintento. El turno 1 salió `over_length` con fallback. Los turnos 2 y 3 salieron `ok` (`correct` y `follow_up`) y la identidad siguió ausente porque el turno 1 no la guardó. La ruta de los tres fue `identity_unknown_reference`.

| Turno | Correlación | Intérprete | Prompt de generación | Hechos | Observaciones | Documentos compatibles |
|---|---|---|---|---|---|---|
| 1 | `query:9c1d1ef9-1072-400c-81dc-04dcb05a4793` | 2959 ms, 2237/363, `over_length` | 2386 caracteres | 0 | 0 | 0 |
| 2 | `query:3288b739-a417-4113-8fae-ab3ba033ecea` | 2196 ms, 2328/127, `ok` | 2266 caracteres | 0 | 1 | 0 |
| 3 | `query:99b2e3ee-4d77-4f56-84a7-b2ff09831661` | 1696 ms, 2266/106, `ok` | 2270 caracteres | 0 | 1 | 0 |

`generation_context` de los tres: turno del técnico presente, guía Danebo presente, foto ausente, documentos ajenos 0. El objetivo guardado en el log del turno 1 corta en «vuelve a abr». El de los turnos 2 y 3 corta en «no he revisa». El filtro de Retrieve sí apuntó a la URI del VF5 y devolvió tres chunks de ese PDF. El prompt publicado no admite el cuerpo de 8.2 ni el de SW4: cuando esos cuerpos entran, el mismo evento ha medido unos 28 000 caracteres. Aquí quedó en unos 2 300, con `compatible_docs_count` 0. Fermator VF5+ no está en los hechos. La condición de simulación, el LED apagado, la sensibilidad pendiente y la obstrucción no llegaron como identidad confirmada ni como pasaje admitido. El turno 2 dejó una observación; el contexto de generación no la convirtió en hecho de fabricante. `technician_facts_count` siguió en 0 después de las tres respuestas del asistente: la plantilla publicada no se copió a un hecho del técnico. Esa comprobación no vio una conclusión de diagnóstico contradicha, porque la generación no recibió el caso.

Respuestas publicadas, las tres de 404 caracteres en el navegador:

1. «La identidad de este equipo no está confirmada. Referencia no aplicada a este trabajo: VF5, p. 12.0; VF5, p. 13.0; VF5, p. 5.0.» Pide la placa.
2. La misma plantilla, con VF5 pp. 5, 12 y 13.
3. La misma plantilla, con VF5 pp. 13, 12 y 7.

El episodio `ep_50abb9e5ee609920` queda sucio. No se reutiliza.

## Presupuesto de este encargo

Cupo adicional, separado del sobre histórico de 48 invocaciones y US$2: 16 invocaciones físicas y US$1. No se reinició el saldo anterior.

Secuencia de las 14:06, filas de `bedrock_queries`, `BedrockQuery#cost`:

| Hora | Fuente | Tokens | USD |
|---|---|---|---|
| 14:06:49 | semantic_analysis | 2237 / 363 | 0,004052 |
| 14:07:22 | query | 625 / 261 | 0,001930 |
| 14:07:24 | semantic_analysis | 2328 / 127 | 0,002963 |
| 14:07:29 | query | 585 / 294 | 0,002055 |
| 14:07:32 | semantic_analysis | 2266 / 106 | 0,002796 |
| 14:07:37 | query | 7671 / 218 | 0,008761 |
| 14:07:41 | query | 575 / 356 | 0,002355 |

Siete invocaciones, US$0,024912. El turno 3 escribió dos filas `query`.

Después, el shell que había arrancado el servidor conservaba `HAIKU_QUERY_ANALYSIS_MODE=owner` y `BEDROCK_KNOWLEDGE_BASE_ID=Y7RZWMFJSR`. Dos `bin/rails test` de `document_identity_scope_test` llamaron al intérprete real desde `recorded_kone_orona_conflict`. Doce `turn_interpreter` en `log/test.log`, de 14:11:17 a 14:12:06. Seis de 2129/106 (US$0,002659) y seis de 2112/124 (US$0,002732). US$0,032346. La transacción de prueba revirtió las filas: no están en `bedrock_queries`. Son invocaciones físicas y entran en este cupo. La pasada de pruebas posterior se lanzó con esas variables fuera del entorno: 163 tests en 1,0 s y cero llamadas.

Total de este encargo: 19 invocaciones y US$0,057258. El tope de 16 invocaciones quedó pasado. El de US$1 no. No hay otra secuencia. El servidor local se detuvo.

## Veredicto

Bloqueado para comparar modelos. Las tres respuestas miden la plantilla de identidad no confirmada. El request de generación no llevó Fermator VF5+, ni el cuerpo de 8.2, ni el de SW4, ni los antecedentes como hechos. El recorte por campo está en el código y en las pruebas con dobles. No hay una secuencia real que lo haya cargado, y este cupo no autoriza otra.
