# Field Companion: conversación técnica real

**Ruta vigente: validación progresiva.** La fase 0 quedó cerrada el 2026-10-09 en un proceso con `KNOWLEDGE_BASE_S3_BUCKET=multimodal-source-destination`. La fase 1 se ejecutó una vez, autorizada por Lahiri, y quedó **detenida por evidencia ausente**: el intérprete clasificó la consulta como `meta` y el turno salió sin `Retrieve`. Las fases 2 a 5 siguen bloqueadas. No es `EPISODIO_VALIDADO`. Este texto no autoriza otra corrida, un Retrieve, un worker ni un despliegue. `PASS_CALL_CAP` permanece en 0. El cierre histórico sigue en 188 llamadas y US$0,423114. La reserva de 42 llamadas de la etapa 3 no se usa. El modelo no cambia. `PHASE1_PINNED_TURN_AUTHORIZED` se definió solo en el proceso de esa corrida.

Este documento es el único plan vigente. La historia queda abajo, como referencia, y no es una segunda ruta. Una revisión favorable no sustituye pruebas ni autoriza una corrida.

## Rumbo

**Objetivo original.** Danebo ayuda al técnico a obtener una respuesta útil y sustentada con el menor esfuerzo posible: recuperar evidencia, pedir solo la aclaración que reduce una incertidumbre, interpretar el resultado, mantener lo ya comprobado y reconocer el límite. Conservar contexto o alargar la conversación no es el resultado.

**Implementado y validado.** En local y en `main` están la etapa 1, la corrección de observaciones y de planta, el designador con «+», la composición del guidance, el aislamiento del runner y el cierre presupuestario. La imagen de producción evidenciada sigue siendo `6ca7788`. La pasada aislada del 2026-10-09 demostró efecto en la identidad declarada, el código 18, la planta 2 y el resumen, y quedó `ETAPA_2_BLOQUEADA`. No es `EPISODIO_VALIDADO`. La propuesta de descubrimiento no está implementada.

**Qué falló Journey A.** Los 14 turnos, sin pin, mezclaron ranking abierto, `known?`, aplicabilidad, memoria, generación y el arnés. El Elemont no entró en los 14 retrieves del episodio, aunque una consulta por título lo recupera. Las respuestas atribuyeron funciones al código 18, al LED 7 y al clic, y pidieron mediciones. El arnés añadió «No lo sé» y activó la salida en turnos que traían un dato nuevo. El recorrido fue el runner, no `POST /rag/ask`.

**Por qué cambia la ruta.** Un episodio largo no separa PDF, extracción, chunks, índice, filtro, retrieval y respuesta. La siguiente prueba reduce una sola incertidumbre: con el documento correcto ya pineado, ¿la consulta natural recupera el plano y la respuesta se mantiene dentro de lo que ese pasaje sustenta?

**Próxima acción y gate.** La fase 1 no se repite y no se repara en caliente. Primera divergencia comprobada: `interpreter_raw` devolvió `move: meta` para una pregunta sobre el equipo, `route_decision` quedó en `retrieval: false` y la respuesta publicada fue el texto fijo `meta_continue`. La siguiente decisión es del fundador: aprobar el cambio mínimo propuesto en «Fase 1, hallazgos al cerrar» y un cupo nuevo para repetir la fase 1. Lo que sigue de este párrafo es el gate con el que se ejecutó la corrida. La fase 1 real esperaba un proceso cuyo `KNOWLEDGE_BASE_S3_BUCKET` y `KbDocument::KB_BUCKET` fueran `multimodal-source-destination`, de modo que la URI canónica de la fila 213 coincidiera con `original_source_uri` de la captura, y esperaba `PHASE1_PINNED_TURN_AUTHORIZED=1` más el cupo de tres intentos. La conexión en serie de la página 5 está confirmada por Lahiri; la lectura anterior de dos ramas queda corregida. La página 6 queda «No recuperada en la consulta diagnóstica; causa pendiente». La recuperación por la consulta natural, y el filtro efectivo del pin, se miden en la fase 1: `force_entity_filter` y las URI del documento seleccionado. Antes de cada fase se actualiza este texto con el cierre de la anterior. Si el gate falla, no se avanza, no se repite la corrida y no se repara en caliente: se clasifica la causa, se propone el cambio mínimo y se actualiza el plan.

**Conservado, diferido y reemplazado.**

- Conservado: el fixture y las trazas de Journey A, como prueba histórica de continuidad; las reparaciones locales ya demostradas por test; el pin por botón, con revalidación de id y uid, `pin_only` y sin soltar el foco en silencio; el aislamiento del proceso; Haiku 4.5 global; el cierre de 188 llamadas y US$0,423114.
- Diferido: la propuesta de descubrimiento documental, en la fase 4. No es prerrequisito de la fase 1. Su texto sigue en «Propuesta diferida de descubrimiento».
- Reemplazado, como ruta de ejecución: la luz verde única de las etapas 1, 2 y 3; los 14 turnos como duración o meta; «en esta validación el pin no se setea»; otra pasada sin pin como siguiente paso; `RETRIEVAL_EMPTY` como parada de la próxima corrida; implementar el descubrimiento antes del caso pineado; prohibir la copia `(1)` o la fila 213 por el sufijo del nombre; tratar el `document_id` `121bfffe…`, el UID `dcc8e046-037d-48a6-8913-1992aed28507` o una fila reconstruida como identidad o propiedad en producción; reabrir el cupo, usar la reserva de la etapa 3, cambiar el modelo o desplegar desde este documento. El borrador de cinco pasos sigue retirado.

## Alcance de esta ruta

El alcance inmediato es el caso del plano Elemont, de la fase 0 a la 5, en ese orden. Cada pregunta tiene que reducir una incertidumbre relevante. Journey A no se alarga ni se reescribe para aprobar un caso.

Quedan en el backlog, y no entran en esta autorización: cambio explícito de caso, cambio ambiguo, regreso tras una pausa, journey B, T-F y recuperar un caso anterior. El detalle histórico de esos seis escenarios está en la referencia. Adelantar uno es decisión del fundador.

## Estado real

Separado en tres planos. No se mezclan.

- Implementado en el código de `main`, y no revalidado en la imagen `6ca7788` salvo la etapa 1 y lo que esa imagen ya contenía: corrección de planta, designadores con signo, guidance por unidades, continuidad bajo 2400 caracteres, aislamiento de `smart_deal_stage2_isolated` y `Rag::ValidationCapture`.
- Demostrado en una corrida real: la pasada del 2026-10-09, sesión aislada 3, conservó identidad, código 18, planta 2 y resumen, y no recuperó el Elemont en el episodio. Veredicto de esa pasada: `ETAPA_2_BLOQUEADA`. Las cifras de esa pasada no se reabren.
- Propuesta pendiente: candidatos, botón vigente, correspondencia por slot y guidance sin diagnóstico genérico cuando no hay pasaje. Está escrita y no está implementada.

## Entorno

Rails local contra la Knowledge Base de producción `Y7RZWMFJSR`, región `us-east-1`. RDS de producción no se usa y no se repara. No se leen las bases Rails de producción.

Bases aisladas, en `localhost` o `127.0.0.1`:

- `smart_deal_stage2_isolated`
- `smart_deal_stage2_isolated_cache`
- `smart_deal_stage2_isolated_cable`

Antes de cualquier fase se imprime `current_database` en cada una. La cola permanece en `smart_deal_development_queue`: Solid Queue no se redirige y no se arrancan workers. `TrackBedrockQueryJob` corre en línea. Cualquier otro `perform_later` detiene la prueba antes de escribir esa cola. `RagController#ask` encola `KbDocumentEnrichmentJob` cuando hay `doc_refs`; el wrapper de la fase 1 tiene que negarse a ese encolado, igual que a cualquier otro trabajo inesperado.

La cuenta 1 y las filas locales ya reconstruidas forman parte de este entorno aislado. La lectura local del 2026-10-09, en `localhost`, confirmó la cuenta 1 `danebo-legacy`, la cuenta 3 `danebo-pilot-elevator` y la fila 213. No se crean filas nuevas para forzar el resultado. No se modifican permisos.

El proceso de validación exporta el id de la KB y exige el adaptador `postgresql` y esas tres bases. No edita `.env`, credentials, `database.yml`, `cache.yml`, `cable.yml` ni `deploy.yml`. La configuración es del proceso, y se comprueba contra el código antes de empezar:

| Variable | Valor | Qué hace el código si falta |
|---|---|---|
| `SHARED_SESSION_ENABLED` | `false` | `SharedSession::ENABLED` queda falso salvo la cadena `true`. |
| `HAIKU_QUERY_ANALYSIS_MODE` | `owner` | Otro valor, o la ausencia, no es `owner`. El default es `off`. |
| `FIELD_COMPANION_EPISODE_ENABLED` | `true` | El episodio no se escribe. |
| `FIELD_COMPANION_TURN_ENABLED` | `true` | El turno no lee el episodio. |
| `DOCUMENT_IDENTITY_SCOPE_ENABLED` | `true` | El alcance documental queda apagado. |
| `RAG_GROUNDED_SYNTHESIS_ENABLED` | `true` | La síntesis anclada queda apagada. Una lista `RAG_GROUNDED_SYNTHESIS_ACCOUNT_IDS` no vacía restringiría las cuentas; este proceso no la define. |
| `PILOT_AUDIT_CAPTURE` | `true` | Añade texto a `TurnEvidence` y a `PilotAuditLog`. No abre `ValidationCapture`. |
| `AWS_MAX_ATTEMPTS` | `1` | Tope de reintento del SDK. No es el cupo de la fase. |
| `BEDROCK_KNOWLEDGE_BASE_ID` | `Y7RZWMFJSR` | Sin esta exportación el proceso usa la KB que ya tenga configurada. |
| `AWS_REGION` | `us-east-1` | Región de esa KB. |
| `BEDROCK_MODEL_ID` | `global.anthropic.claude-haiku-4-5-20251001-v1:0` | Es el default de `BedrockClient::QUERY_MODEL_ID` cuando no hay otro id. Haiku 5.5 no entra. |
| `KNOWLEDGE_BASE_S3_BUCKET` | `multimodal-source-destination` | `KbDocument::KB_BUCKET` se congela al arrancar. Con `smart-deal-dev-kb` la URI canónica de una clave relativa sale en el bucket de desarrollo y no coincide con `original_source_uri` de la captura. |

La ejecución futura exige, además, una autorización explícita de ese proceso. La fase 1 no arranca si `PHASE1_PINNED_TURN_AUTHORIZED` no es exactamente `1`. Esa variable no está definida. `STAGE2_JOURNEY_AUTHORIZED` no la sustituye: el runner histórico sigue sujeto a `PASS_CALL_CAP` 0.

La restauración se comprueba en un proceso nuevo, sin esas exportaciones. Las bases habituales de desarrollo son `smart_deal_development`, `smart_deal_development_cache` y `smart_deal_development_cable`, y la cola habitual es `smart_deal_development_queue`. La KB habitual de desarrollo es `QGVYLPTEGT`.

## Presupuesto

El cierre de `Rag::Stage2RunBudget` no se toca: 188 llamadas, US$0,423114, techo de etapa 2 en 188, reserva de etapa 3 en 42, techo global en 230, tope US$2,50, `PASS_CALL_CAP` 0. `Retrieve` y el embedding siguen fuera de `BedrockQuery`. Este complemento no abre cupo. No declara `EPISODIO_VALIDADO` y no desbloquea la etapa 2.

Presupuestos nuevos, escritos y no autorizados. Un defecto de ingesta o de índice no los amplía. Autorizarlos es decisión del fundador.

- Fase 0: 0 llamadas de modelo. La lectura local de la base, de las filas ya existentes y del PDF no gasta ese cupo. Tope propuesto de 4 `Retrieve` de solo lectura, separado, para comprobar presencia en la KB cuando la evidencia local no alcance. No autorizado.
- Fase 1: un turno, en una sesión nueva. Cupo propio, abajo. No usa las 42 de la etapa 3.
- Fases 2 a 5: el cupo se escribe al cerrar la fase anterior. No está abierto.

### Cupo propuesto de la fase 1

Máximo de tres intentos de llamada de modelo en esa corrida. El contador vive en el servicio de la fase, no en `Stage2RunBudget`. Se comprueba inmediatamente antes de cada llamada. Si el contador ya llegó a tres, la llamada no sale, se escribe la parada y se cierra el proceso.

No hay reintento automático de una llamada fallida ni una segunda ejecución de la prueba en la misma corrida. `AWS_MAX_ATTEMPTS=1` limita el reintento del SDK. No reemplaza este contador.

Cada intento queda registrado: éxito, error, si existe fila `BedrockQuery`, tokens y costo cuando la fila existe. Un intento sin fila cuenta como intento y no se le inventa un costo. `Retrieve` y el embedding quedan fuera del cupo.

La hipótesis de planificación, tomada del margen de un turno sin pin en `Stage2RunBudget`, es un análisis del intérprete y hasta dos generaciones. Es un supuesto. La ejecución mide cuántas llamadas hace realmente el turno pineado. Si la siguiente llamada fuera la cuarta, la corrida se detiene en tres y ese exceso queda como hallazgo. No se sube el cupo dentro de la corrida.

Hoy el intérprete entra por `ConversationSession#record_user_turn!` con `interpreter_client`. La generación entra por `BedrockClient#generate_text` y por `converse_message`. `ValidationCapture.record` observa la llamada y no la impide. El contador ya está en `Rag::Phase1ModelBudget`, dentro de `app/services/rag/phase1_pinned_turn.rb`. `defined?(Rag::Phase1ModelBudget)` no carga esa clase: un proceso que no armó el contador sigue el camino anterior. Con el contador armado, la comprobación ocurre antes de `invoke_model`, de `converse` y de `retrieve_and_generate`, y ese último camino omite `AuroraColdStartRetry`. `Retrieve` sigue fuera del cupo.

Escribir este cupo no lo autoriza. La fase 1 real espera la decisión del fundador y `PHASE1_PINNED_TURN_AUTHORIZED=1`.

## Preparación local del turno pineado

`script/field_companion/stage2_journey_a.rb` no es una ejecución de la fase 1. No pinea. Recorre los 14 turnos del fixture. Hace un `Retrieve` de disponibilidad antes del episodio. Depende de `Stage2RunBudget`, que con `PASS_CALL_CAP` 0 no admite otro turno. Exige la cuenta 1 `danebo-legacy`, la cuenta 3 `danebo-pilot-elevator` y una fila cuyo `document_uid` sea `dcc8e046-037d-48a6-8913-1992aed28507` y cuya `s3_key` sea `bulk_uploads/1/2026-08-31/Montacargas 2N Temporizado-1 (1).pdf`. Esas constantes son el contrato del runner. No demuestran que la fila aislada siga siendo ese objeto.

La lógica está en `app/services/rag/phase1_pinned_turn.rb`. `script/field_companion/phase1_pinned_turn.rb` lee el entorno, llama al servicio e imprime. Sin `PHASE1_PINNED_TURN_AUTHORIZED=1` sale con código 2 y no conecta. Esta preparación no definió esa variable.

El servicio:

- Compara el snapshot de las tres bases aisladas, la cola, la KB, la región, `AWS_MAX_ATTEMPTS` y `KbDocument::KB_BUCKET`.
- Usa la cuenta y el usuario ya existentes. No crea filas para forzar el caso.
- Abre una sesión `phase1:pinned:…`. No altera la sesión histórica de Journey A.
- Pinea con `ConversationSession#pin_kb_document!`. La URI sale de la fila. `KnowledgeScopePolicy.authorized?` tiene que aceptarla. Si se exige la captura, `canonical_uri` tiene que ser `s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/Montacargas 2N Temporizado-1 (1).pdf`.
- Ejecuta un turno por `record_user_turn!` y después `execute_rag_query`, con las URI leídas del pin. El filtro de ese pin es `document_pin_filter` sobre esas URI.
- Abre `Rag::ValidationCapture.capture` y escribe `phase1_turn` con la sesión, el episodio cuando existe, y las correlaciones `phase1:<id>` y `phase1:<id>:query`. El turno del asistente recibe esa correlación de consulta.
- Guarda, también si la corrida se detiene o falla, `environment.json`, `message.txt`, `turn.json`, `capture.json`, `result.json` y `ledger.json` bajo `tmp/phase1_pinned_turn/runs/<run_id>/`. El entorno exportado no lleva secretos. Un fallo al escribir esa evidencia deja el estado en `failed` y no en `completed`.
- No hace un `Retrieve` de disponibilidad. `TrackBedrockQueryJob` queda en línea. Otro `perform_later` se niega antes de escribir la cola.
- El contador, máximo tres, se comprueba antes de cada llamada de modelo. Un error queda en el libro y la llamada siguiente no sale. `Stage2RunBudget::PASS_CALL_CAP` sigue en 0.
- Antes de crear la sesión compara el entorno efectivo: host local, adaptador `postgresql`, bases, cola, KB `Y7RZWMFJSR`, región `us-east-1`, bucket declarado y `KbDocument::KB_BUCKET`, flags del Companion, modo `owner`, síntesis, modelos ya cargados del intérprete y de la generación, y `AWS_MAX_ATTEMPTS=1`. Una constante cargada con otro valor rechaza la corrida.

Estados del recorrido, separados de la aceptación documental:

- `refused`: un control previo rechazó la corrida. No hay sesión.
- `stopped` o `failed`: el recorrido se detuvo o la aplicación falló. El motivo queda sanitizado.
- `completed`: la aplicación terminó. Filtro, evidencia y respuesta siguen pendientes de evaluar. `result.json` lleva `documentary_acceptance: pending`.

Las pruebas de esa preparación están en `test/services/rag/phase1_pinned_turn_test.rb`. La fase 1 real no se ejecuta con solo tener el código.

## Cadena documental

Cada caso localiza la primera divergencia comprobada en este orden:

PDF, extracción y chunks, publicación e indexación, autorización y filtro, recuperación y ranking, generación, estado conversacional.

La referencia del evaluador se escribe antes de la corrida. Lleva página, evidencia esperada, interpretación permitida y afirmaciones que el pasaje no sustenta. No entra en la consulta natural, el prompt, el fixture ni una página forzada. La consulta natural tampoco recibe el pasaje ni un dato que el técnico no haya dicho.

Si la consulta natural no recupera esa evidencia, el caso se detiene. Una búsqueda posterior no lo declara superado. La localización se para en la primera capa que explica la ausencia:

1. Confirmar el contenido en el PDF.
2. Inspeccionar extracción y chunks, en especial las relaciones de los diagramas.
3. Comprobar publicación y metadata en la KB.
4. Verificar autorización, URI y filtro del pin.
5. Evaluar retrieval y ranking.
6. Solo después de esas cinco, considerar embeddings.

Un `Retrieve` vacío demuestra que esa búsqueda no recuperó evidencia. No demuestra que la sección no exista ni que el documento esté ausente del índice. Un archivo presente en S3 tampoco demuestra que esté indexado: afirmar presencia o ausencia en la KB exige evidencia propia de la indexación. No se reindexa ni se cambia el sistema durante una corrida.

Cuatro resultados, y no se mezclan:

- Ausente del índice: el PDF o el chunk local la tienen y la evidencia de indexación no.
- Deteriorada por extracción o troceo: la etiqueta existe, pero se perdió la relación del diagrama, se partió el recorrido o el texto quedó por debajo de lo que el plano muestra.
- Excluida por filtro o por autorización: está en la KB y el filtro del pin, de la cuenta o de la compuerta no la deja entrar.
- Existente y no recuperada: pasa el filtro y no aparece en el ranking de la consulta natural.

Las pruebas naturales de aceptación y las consultas diagnósticas van separadas. Una búsqueda por página, URI o texto específico se anota con consulta, filtro, k y resultado. No declara que la consulta natural pasó. La captura `tmp/documentary_retrieve/20261007T212124Z/` ya es de ese tipo.

Cada consulta de prueba lleva, antes de ejecutarse, su referencia tomada del PDF original: página, pasaje o diagrama, y la respuesta que ese material permite sostener. Esa referencia no entra en la consulta. Cuando una lectura de la KB está autorizada, se contrasta con el contenido y la metadata de los chunks: fidelidad frente al PDF, contexto que el pasaje necesita para entenderse, procedencia y correspondencia con el documento seleccionado.

Son dos comprobaciones distintas.

1. Representación en el índice. El chunk y su metadata conservan la página, el pasaje o el diagrama, y apuntan al documento seleccionado.
2. Recuperación. La consulta natural de la fase trae ese chunk.

Si el chunk esperado no llega, se nombra la primera divergencia comprobable de la cadena. Un resultado vacío de esa consulta no atribuye el fallo a embeddings y no concluye que el pasaje esté ausente del índice. No se reindexa y no se hacen llamadas fuera del cupo autorizado.

La referencia de la consulta natural de la fase 1 sale del PDF de SHA-256 `121bfffe0827f6bc681ba9bdc910503900555c4ce58d616732a1c063f3b16986`. El PDF es la fuente de verdad. Esta descripción es una referencia trazable, no una autoridad aparte del documento. Procedencia: revisión visual de ChatGPT. Estado: confirmada por Lahiri. La lectura de la preparación local que describía dos ramas eléctricas queda corregida. `pdftotext` no sustituye el dibujo.

- Página 5, «DIAGRAMAS CIRCUITO #3», «SECCIÓN LÍNEA DE SEGURIDAD». El recorrido es una serie plegada en dos columnas: Seg In, parada de emergencia sobre cabina, barrera láser, fin de carrera superior, seguridad puerta nivel 5, seguridad puerta nivel 4, seguridad puerta nivel 3, seguridad puerta nivel 2, seguridad puerta nivel 1, parada de emergencia del foso, Seg Out.
- La conexión inferior sale del contacto de puerta 4, sube por el tramo central y llega al contacto de puerta 3 en la columna derecha. Las dos columnas no son dos ramas eléctricas alternativas.
- La seguridad de puerta del nivel 2 está entre las de los niveles 3 y 1 en esa cadena.
- La misma página, «SECCIÓN BOTONERA DE PASILLO NIVEL 1», etiqueta las chapas por nivel en otro tramo. La página 6, «SECCIÓN CONEXIÓN SOBRE CABINA», las vuelve a etiquetar. Esas chapas y «Seguridad Puerta» son símbolos distintos en el dibujo.
- El plano no demuestra por sí solo la causa de la falla reportada, que la seguridad de puerta sea la chapa, un procedimiento de medición o reparación, ni el significado de los códigos 8/18, del LED 7 o de una solución de CEA15.

Quien evalúe una respuesta no es el único juez del diagrama. Si la respuesta difiere de esta referencia, la discrepancia se demuestra contra el PDF. Si una conexión, un símbolo o una relación queda ambigua, se marca «pendiente de revisión visual» y se sigue solo con las comprobaciones que no dependen de ese juicio. Una referencia pendiente no aprueba ni rechaza la calidad técnica.

Contraste ya hecho con la captura diagnóstica existente, sin llamada nueva y sin modificar chunks ni el índice. El chunk `chunk_p5_1.txt`, página 5, trae esas etiquetas, la URI `bulk_uploads/1/2026-08-31/Montacargas 2N Temporizado-1 (1).pdf`, `document_id` `121bfffe…` y `account_id` 1. También arma una tabla del nivel 5 al 1. Esa tabla es extracción: su fidelidad frente al dibujo es la comprobación B, distinta de la respuesta. La misma búsqueda, k=8 y sin pin, no trajo la página 6. Queda «No recuperada en la consulta diagnóstica; causa pendiente». Esa causa se clasifica después de ver su representación indexada y de comprobar que pasa autorización y filtros. Hasta entonces no es un fallo de ranking ni una ausencia del índice. No demuestra que la consulta natural de la fase 1 vaya a recuperar la página 5.

No se reingiere, no se cambian embeddings, no se modifica metadata y no se amplía el presupuesto al encontrar el defecto. Si la capa es de ingesta o de indexación, se documentan la evidencia y la reparación propuesta, y el caso no continúa hasta una decisión del fundador.

La misma corrida distingue, además, fallo de estado, de generación y de arnés. La cadena de arriba se recorre antes de atribuir el fallo a la respuesta o a la memoria. No se mezclan en una sola intervención la reparación de indexación, retrieval, generación, memoria y arnés. No se repara durante la corrida.

## Trazabilidad del recorrido

Cada criterio de una fase se contrasta con las trazas de la misma sesión, el mismo episodio y el mismo turno. La respuesta visible no lo da por cumplido. `PILOT_AUDIT_CAPTURE=true` tampoco: ese flag añade texto a `TurnEvidence` y a `PilotAuditLog`, y no abre `ValidationCapture` ni escribe `pilot_events`. Antes de ejecutar una fase se comprueba que `Rag::ValidationCapture.capture` está abierto en ese proceso. Si el bloque no está activo, la corrida no empieza.

Esta revisión leyó las trazas ya guardadas de la sesión 3. No hizo llamadas nuevas. Archivos: `tmp/stage2_journey_a/runs/20261009T114733Z-session-3/` y `tmp/stage2_journey_a/exports/20261009T114941Z/`. Sesión 3, cuenta 1, usuario 1, episodio `ep_60ed345c266abc03`, 14 turnos, sin pin. `filter.json` de esa corrida no trae `PILOT_AUDIT_CAPTURE`, `DOCUMENT_IDENTITY_SCOPE_ENABLED` ni `RAG_GROUNDED_SYNTHESIS_ENABLED`. Esas tres variables no quedan demostradas por estos archivos.

Un turno de esa corrida usa dos correlaciones. `stage2:a:t01` cubre el intérprete y el `field_companion_turn` del técnico. `stage2:a:t01:query` cubre `kb_retrieve`, `document_identity_scope`, `photo_continuity` y la generación. En `ValidationCapture`, `correlation_root` vale `stage2:a:t01` en los dos tramos. Los eventos del intérprete y `route_decision` salen antes de enlazar el episodio: traen sesión y correlación, y el `episode_id` llega en el `retrieve`.

Qué registra cada fuente en ese turno, y qué falta:

- `pilot_events`, 84 filas, todas de la sesión 3. `field_companion_turn` del técnico: SHA del mensaje, SHA de la consulta efectiva, SHA del estado antes y después, episodio y decisión. No trae el texto del mensaje. Los otros 14 `field_companion_turn`, los de la respuesta, comparten el episodio y tienen `correlation_id` vacío: el runner les pasó `result.correlation_id`, y `RagResult` copia solo el id que devuelve el servicio. No se unen al turno por correlación. `turn_interpreter`: movimiento, aserciones, modelo y tokens. El turno 1 coincide en 2150 y 266 tokens con la fila `BedrockQuery` de `semantic_analysis`; el costo está solo en esa fila. Sumar las dos contaría la misma llamada dos veces. `kb_retrieve`: texto de la consulta, `requested_k` 8, `effective_k` 8, `search_type` HYBRID, conteos y una huella de 16 caracteres. `filter_applied` es falso en los 14. En el código ese campo es el filtro de URI del pin, no el filtro de cuenta. El episodio no viene en este evento. No hay cuerpo de chunk ni filtro completo. No hay evento `open_retrieval` en este export.
- `bedrock_queries.json`, 28 filas de la sesión 3: 14 `semantic_analysis` con `attempt` vacío y 14 `query` con intento 1. Traen correlación, ruta, modelo, tokens, costo y `user_query` recortado a 500 caracteres. No traen filtro, chunks ni prompt. Un `Retrieve` no crea fila.
- `trace.json`, bloque `capture` de `ValidationCapture`, 16 eventos en el turno 1. Ahí están la solicitud de `Retrieve` con el filtro completo, la KB `Y7RZWMFJSR`, modalidad HYBRID y k=8; los chunks con URI, página, score, texto, decisión y motivo; el prompt de `generate_text`; la respuesta publicada; el delta del episodio y la percepción. El filtro de ese `retrieve` es cuenta 1, o cuenta 3 sin foto y sin `manual_corpus=account`, o `manual_corpus=general`. El primer chunk aceptado es KONE, página 375, motivo `shared_corpus`. Los 14 turnos tienen respuesta visible y cero filas de citas. El mensaje original completo está en el registro del runner (`original` y `sent`), no como campo propio de `PilotUsage`. `route_decision` no copia las URI del foco. Esta corrida no tiene `document_focus` ni `pin_only`: no sirve para dar por probado el filtro de un pin.
- `TurnEvidence` y `PilotAuditLog` no están en estos archivos. Con el flag apagado, el código guarda SHA. Con el flag encendido, el log añade pregunta, respuesta y texto de chunk hasta 4000 caracteres. Esta exportación no permite ver cuál de los dos ocurrió.

En las ejecuciones futuras el mismo cruce es obligatorio. Sesión, episodio y las dos correlaciones del turno tienen que apuntar al mismo caso. El criterio de alcance se lee del filtro del evento `retrieve` de `ValidationCapture` y de `document_focus`. El de evidencia se lee de los chunks aceptados, con URI, página y texto. El de respuesta se lee del prompt y de la respuesta publicada, contrastados con esos chunks y con la referencia del PDF. Una respuesta visible con citas vacías, como las 14 de la sesión 3, no cumple evidencia. Un dato que no esté en esas trazas se anota como límite de observabilidad. Un request que no quedó capturado no se declara enviado.

El fallo señala el primer punto que se desvía de la referencia, con el evento que lo muestra. Lo posterior es consecuencia. Una medición inventada no es la causa si el filtro del pin nunca se aplicó. Una búsqueda diagnóstica usa otra correlación.

No se añade instrumentación en este corte. Un campo nuevo solo se propone si una fase cerrada no puede señalar el primer desvío. El candidato no autorizado es copiar las URI del foco en `route_decision` cuando no hay evento `retrieve` y la fila de sesión tampoco las tiene. El otro hueco ya visto, y tampoco se repara aquí, es el `correlation_id` vacío en el `field_companion_turn` de la respuesta.

## Fases

Antes de iniciar una fase, este documento se actualiza con los hallazgos de la anterior y se revisan casos, supuestos, instrucciones y presupuesto. Un cambio de modelo, presupuesto, arquitectura o alcance vuelve al fundador. Un criterio se da por cumplido solo cuando las trazas de la misma sesión, el mismo episodio y el mismo turno lo muestran. La respuesta visible y `PILOT_AUDIT_CAPTURE=true` no alcanzan.

### Fase 0. Preparación documental y del entorno

1. Estado: cerrada el 2026-10-09. Un proceso arrancado con `KNOWLEDGE_BASE_S3_BUCKET=multimodal-source-destination`, sin llamadas AWS, conectado a las tres bases aisladas en `localhost`, leyó la fila 213: `canonical_uri` `s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/Montacargas 2N Temporizado-1 (1).pdf`, igual a `original_source_uri` de la captura. `KnowledgeScopePolicy.authorized?` dio verdadero para la cuenta 1. No se crearon filas: 3 sesiones y 2 `KbDocument` antes de la fase 1. Con todas las variables de la tabla de entorno, `environment_refusal` dio nulo y el único rechazo fue `authorization_absent`. Las tres condiciones del gate quedan comprobadas por separado.
2. Prerrequisitos y evidencia heredada. Cierre de 188 llamadas y US$0,423114. RDS de producción fuera de este plan. Captura diagnóstica `tmp/documentary_retrieve/20261007T212124Z/`. El sufijo del nombre no decide el documento.
3. Pregunta. ¿El PDF, el objeto indexado en `Y7RZWMFJSR` y una fila local ya seleccionable son el mismo plano, la extracción conserva la línea de seguridad, y el usuario de la prueba puede pinear esa fila sin crear filas ni cambiar permisos?
4. Acciones y límites. La lectura del PDF y de la captura no se sustituye por un `Retrieve`. No se crean filas, no se cambian permisos, no se reingiere y no se edita metadata. `PASS_CALL_CAP` sigue en 0. El tope propuesto de 4 `Retrieve` no está autorizado. No se arrancan workers. La comprobación de conexión y de `current_database` es local.
5. Entradas y resultados esperados. Entrada: las copias locales ya comparadas, la captura diagnóstica y la fila aislada que ya exista. Resultado del gate de correspondencia, las tres condiciones a la vez:
   1. La URI canónica de la fila local coincide con `original_source_uri` del chunk.
   2. El PDF corresponde al objeto indexado por el contenido de las páginas relevantes o por bytes. El hash local contra `doc_sha256` de la captura ya cubre esos archivos, y la `s3_key` de la fila 213 es la de la captura. Una lectura del objeto en S3 sigue sin hacerse.
   3. La selección está autorizada para el usuario de la prueba, por `KnowledgeScopePolicy.authorized?`.
6. Aceptación, fallo y detención. Aceptación: las tres condiciones quedan comprobadas por separado y la referencia del evaluador solo afirma lo que el PDF contiene. Fallo: pinear una fila cuya URI no coincide, o crear una fila para que coincida. Detención: no hay una fila ya existente y autorizada para esa URI. El nombre `(1)`, `(2)` o `(1)(2)` no es causa de aceptación ni de detención.
7. Evidencias que debe guardar. SHA-256 del PDF, URI canónica de la fila, `original_source_uri` y `document_id` del chunk, `document_uid` de la fila, cuenta y usuario, y una marca de que toda búsqueda por título, página o texto es diagnóstica. El filtro del pin se mide en la fase 1.
8. Hallazgos. Siete archivos locales, fuera del repositorio, con y sin el sufijo `(1)`, miden 583429 bytes y comparten el SHA-256 `121bfffe0827f6bc681ba9bdc910503900555c4ce58d616732a1c063f3b16986`. Ese valor es el `doc_sha256` de los chunks Elemont de la captura. La página 5 usa la serie confirmada por Lahiri; la lectura de dos ramas quedó corregida. `pdftotext` no decide el recorrido. El chunk `chunk_p5_1.txt` trae las etiquetas y una tabla del 5 al 1; esa tabla es extracción. La captura hizo un `Retrieve`, cero `retrieve_and_generate`. Consulta diagnóstica: «Elemont Montacargas Hidraulico Modelo MH Seguridad Puerta nivel 1», HYBRID, k=8, sin pin. `request.json` tiene `account_id` 1 y el filtro de `account_filter`: la cuenta 1, o la cuenta 4 sin `field_photo_v1` y sin `manual_corpus=account`, o `manual_corpus=general`. El primer chunk fue aceptado con `reason` `viewer_account`. `SharedManualCorpus`, en la base aislada leída ahora, resuelve las cuentas 1 y 3. El brazo 4 de esa captura es otro registro. Ninguno es RDS de producción. La página 6 no está entre esos ocho: «no recuperada; causa pendiente». Identificadores, con funciones distintas: `document_id` del chunk `121bfffe0827f6bc681ba9bdc91050390055` es sha256[0,36] y `publication_gate` no lo compara con el UID; `document_uid` `dcc8e046-037d-48a6-8913-1992aed28507` es la identidad de la fila; `id` 213 es la fila física que el pin usa como `kb_document_id`. Lectura local, host `localhost`, sin crear filas ni cambiar permisos: `current_database` fue `smart_deal_stage2_isolated`, `smart_deal_stage2_isolated_cache` y `smart_deal_stage2_isolated_cable`. La cola configurada siguió en `smart_deal_development_queue`. Cuenta 1 `danebo-legacy`. Cuenta 3 `danebo-pilot-elevator`. Usuario elegido: `stage2-journey-a@localhost.test`, id 1, cuenta 1. `KnowledgeScopePolicy.authorized?` sobre la fila 213, alcance `tenant_private`, dio verdadero. La `s3_key` es `bulk_uploads/1/2026-08-31/Montacargas 2N Temporizado-1 (1).pdf`. En este proceso `KNOWLEDGE_BASE_S3_BUCKET` y `KB_BUCKET` son `smart-deal-dev-kb`, así que `canonical_uri` salió `s3://smart-deal-dev-kb/bulk_uploads/1/2026-08-31/Montacargas 2N Temporizado-1 (1).pdf`. La captura trae `s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/Montacargas 2N Temporizado-1 (1).pdf`. La clave coincide. El bucket de la URI canónica, en este proceso, no. No se recorrió el turno contra esa fila. La sesión histórica 3 se leyó y no se modificó: `stage2:journey-a:20261009T114733Z`, usuario 1. Un proceso nuevo, sin las exportaciones de validación, volvió a `smart_deal_development`, `smart_deal_development_cache`, `smart_deal_development_cable`, cola `smart_deal_development_queue` y KB `QGVYLPTEGT`. No se editó `.env`.
9. Cambios en la fase siguiente. La fase 1 sigue bloqueada hasta que un proceso arranque con el bucket `multimodal-source-destination` y la URI canónica iguale la captura, y hasta la autorización del cupo. La recuperación de la página 5 por la consulta natural es la comprobación distinta. La página 6 no se clasifica como ranking mientras su causa siga pendiente. `pin_only` no cierra este gate.

### Fase 1. Consulta sencilla con el documento correcto pineado

1. Estado: ejecutada una vez el 2026-10-09, run `20261009T194048Z`, sesión 4. La aplicación devolvió `completed`. Aceptación documental: no. Detenida por evidencia ausente. No se repite.
2. Prerrequisitos. Gate de correspondencia cerrado sobre la misma fila, sin filas nuevas. Servicio de la fase con pruebas de stubs en verde. `ValidationCapture.capture` abierto. `PHASE1_PINNED_TURN_AUTHORIZED=1`. Cupo de tres intentos de modelo, autorizado por el fundador. Sesión nueva.
3. Pregunta. Con ese plano ya seleccionado, ¿la consulta natural recupera dónde aparece la seguridad de la puerta del nivel 2 y cómo se relaciona con las demás seguridades, sin afirmar la causa de la falla?
4. Acciones y límites. Un turno, por la secuencia de `RagController#ask` descrita arriba. El pin se escribe antes de la pregunta. No se inyectan páginas, el pasaje ni la respuesta esperada. No se sube k a mano, no se suelta el pin y no se abre el corpus si el retrieve vuelve vacío. No hay `Retrieve` de disponibilidad. No se reingiere. El contador se comprueba antes de cada llamada de modelo. Sin reintento y sin repetir la prueba.
5. Entradas y resultados. Consulta natural, sin la referencia del evaluador: «Estoy revisando un Elemont MH por un problema de puerta en el nivel 2. Según el plano seleccionado, ¿dónde aparece la seguridad de esa puerta y cómo se relaciona con las demás seguridades?» Referencia confirmada por Lahiri, página 5, circuito 3, sección línea de seguridad: la seguridad de puerta del nivel 2 está en la cadena en serie, entre las de los niveles 3 y 1. La respuesta se evalúa por significado y respaldo, no por coincidencia literal. Puede omitir el resto de la cadena y puede usar «cadena», «circuito en serie» u otra redacción si conserva la ubicación y esa relación. No se marca incorrecta por corregir la lectura anterior de dos ramas. Tres criterios, independientes:
   1. Alcance. `force_entity_filter` verdadero y `entity_s3_uris` exactamente las URI canónicas del documento seleccionado, las que `authorize_retrieval_set` haya dejado pasar. Se registran `reason`, modalidad y k reales. `pin_only` solo dice que había URI pineadas: `resolve_retrieval_scope` lo asigna en cuanto la lista no está vacía. No prueba el filtro enviado. El perfil de un documento pineado usa 3 resultados en la consulta ordinaria, 5 si la clasifica como crítica y otro valor si es exhaustiva. Esta frase no coincide con esos patrones. El k que salga se anota. No se exige 3.
   2. Evidencia. Aparece el pasaje de la página 5 con esas etiquetas, y la procedencia verifica `original_source_uri`, página y el documento seleccionado.
   3. Respuesta. Cuatro planos, separados: A, interpretación del PDF; B, fidelidad del chunk frente al PDF; C, evidencia que llegó al contexto; D, respuesta generada. Para esta consulta, ubicación es página 5, circuito 3, sección línea de seguridad. Relación es la seguridad de puerta del nivel 2 dentro de la cadena en serie. Límite es no atribuir la causa ni igualarla con la chapa sin evidencia. Una respuesta fiel al chunk puede repetir un error de extracción: se documenta el defecto de representación y su efecto, y no se atribuye solo al razonamiento. Una respuesta técnicamente correcta tampoco demuestra grounding si el contexto no trae respaldo. Corrección técnica y respaldo documental se anotan por separado. Ante una discrepancia: citar la afirmación exacta, señalar el pasaje o la conexión visual, explicar la contradicción si existe, y marcar «pendiente de revisión» cuando la evidencia no alcanza para decidir. Eso no es FAIL. Una referencia pendiente de revisión visual no aprueba ni rechaza la calidad técnica.
6. Aceptación, fallo y detención. Aceptación: los tres criterios pasan, cada uno leído en las trazas correlacionadas de ese turno. Un criterio fallido no se compensa con otro. La respuesta visible no sustituye el chunk ni el filtro. `completed` solo dice que la aplicación terminó. El fallo nombra el primer desvío del recorrido, con su evento, y se clasifica en la cadena. Si el chunk de la página 5 no llega, la primera divergencia puede estar en la representación o en la recuperación de esta consulta: son comprobaciones distintas. Detención: documento distinto, filtro que no es el del pin, cita ajena, causa inventada, evidencia ausente o cuarta llamada de modelo. La ausencia se clasifica y no se repara en la corrida. Un retrieve vacío de esta consulta no declara el plano ausente del índice y no se atribuye a embeddings sin haber recorrido la cadena. No hay llamadas fuera del cupo. La referencia no entra en la consulta, el prompt ni el contexto.
7. Evidencias. Bloque `ValidationCapture` de ese turno, fila de sesión con `document_focus`, solicitud de `Retrieve` con filtro, modalidad y k, chunks devueltos y aceptados, eventos de piloto de la misma sesión y episodio, y filas `BedrockQuery` de las dos correlaciones del turno, con intentos, errores y costo. El `field_companion_turn` de la respuesta se anota aparte si vuelve a salir sin `correlation_id`. Las búsquedas diagnósticas, si hacen falta después, van aparte, dentro del cupo que esté autorizado, y no reabren el turno.
8. Hallazgos al cerrar. Evidencia: `tmp/phase1_pinned_turn/runs/20261009T194048Z/`. Autorización de Lahiri en la conversación, cupo de tres intentos. Duración del proceso, 3,9 s.
   - Correlación. Sesión 4, `phase1:pinned:20261009T194048Z`, episodio `ep_339e6efccbe54947`, correlaciones `phase1:4` y `phase1:4:query`. Las nueve entradas de `capture.json`, la fila `BedrockQuery` 83 y los `pilot_events` 287 a 289 apuntan a ese caso. El `field_companion_turn` de la respuesta salió con `phase1:4:query`: el hueco del `correlation_id` vacío no se repitió con el wrapper.
   - Precondiciones del alcance. `document_focus`: una entrada, `kb_document_id` 213, la URI canónica de la captura. `phase1_turn.entity_s3_uris` es exactamente esa URI. El pin y la URI pasaron. Por código, ese pin habría enviado `force_entity_filter` verdadero y sin reintento abierto (`resolve_retrieval_scope`, `retry_open = apply_filter && !force_entity_filter`). El filtro enviado no queda medido porque no hubo `retrieve`.
   - Primera divergencia comprobada. Capa: estado conversacional y ruta, antes de la recuperación. `interpreter_raw`: `move` `meta`, `assertions` vacío, `observations` vacío. `perception_applied`: `valid` verdadero. `route_decision`: `route` `meta`, `retrieval` falso. `pilot_events` 288: `outcome_reason` `meta`, `query_components` empieza por `current_turn:dropped`, y `effective_sha256` es `e3b0c442…b855`, el SHA-256 de la cadena vacía. `route_exit`: `meta`. Respuesta publicada: «Puedes seguir con lo que ya me contaste.», que es `rag.es.meta_continue`, con `model_invoked` falso. El prompt del intérprete define `meta` como «asks what Danebo needs from the technician» y dice «A question about the equipment is not meta». La consulta pregunta por el equipo. La clasificación contradice esa regla. `TurnPerception` la aceptó como válida y ningún control determinista la revisó, aunque había un documento pineado y el turno nombra equipo y nivel.
   - Llamadas. Un intento de modelo: `interpreter`, `ok`. `BedrockQuery` 83, `semantic_analysis`, 2174 tokens de entrada y 106 de salida, US$0,002704 estimado. Cero `Retrieve`, cero `retrieve_and_generate`, cero `generate_text`. El costo exacto se concilia con la facturación; esta cifra es atribución por llamada.
   - Criterio 1, alcance: no evaluable. Precondiciones correctas, sin evento `retrieve`. Criterio 2, evidencia: falla, ausente. Criterio 3, respuesta: falla. No responde la pregunta. No inventa causa, medición ni cita, pero tampoco tiene respaldo. Un criterio no compensa otro.
   - Plano A, interpretación del PDF. Revisión visual propia de la página 5 a 400 ppp, PDF de SHA-256 `121bfffe…6b16986`: coincide con la referencia confirmada por Lahiri. Hay una sola serie plegada. El contacto de puerta 4 baja, cruza por el tramo central y sube al contacto de puerta 3. La seguridad de puerta del nivel 2 queda entre las de los niveles 3 y 1. Pendiente de revisión visual, sin efecto sobre esta consulta: desde el nodo de Seg In sale un tramo horizontal con punto de unión hacia la derecha, sin destino rotulado en la sección. Esta revisión no es autoridad única sobre el dibujo.
   - Plano B, fidelidad del chunk. Fuente: `chunk_p5_1.txt` de la captura diagnóstica, no de esta corrida. Conserva las once etiquetas, el orden de la serie y la frase «se conectan en serie entre los nodos Seg In y Seg Out». Contiene además: «el diagrama presenta ramas paralelas visuales en la representación gráfica. REQUIRES_FIELD_VERIFICATION: disposición serie exacta de cada dispositivo en la cadena», y el registro `FR-096E150644BA5108` dice «orden serie exacto REQUIRES_FIELD_VERIFICATION». El dibujo no muestra ramas paralelas. «En el orden visible de arriba hacia abajo» tampoco describe dos columnas, aunque el orden listado sea correcto. Clasificación: deteriorada por extracción, parcial. La relación está en la tabla y la nota la pone en duda. Efecto esperado: una respuesta fiel al chunk puede condicionar el orden a una verificación en campo o hablar de ramas. Eso se anotaría como defecto de representación, no de razonamiento. Hipótesis no demostrada: esta nota puede explicar la lectura anterior de dos ramas.
   - Plano C, evidencia en el contexto: no existe en esta corrida. La captura diagnóstica, con otra consulta, filtro de cuenta y sin pin, trajo `chunk_p5_1.txt` primero. No demuestra que la consulta natural lo recupere.
   - Plano D, respuesta generada: no hubo generación. Corrección técnica: no aplica. Respaldo documental: ninguno.
   - Arnés. `completed` con `documentary_acceptance: pending` se comportó como se diseñó. Dos límites. El intérprete solo deja su salida en la captura, no el `work_context` enviado; aquí se reconstruye del código, primer turno y episodio previo nulo. Las pruebas de `phase1_pinned_turn_test.rb` que no pasan `evidence_root` escriben en `tmp/phase1_pinned_turn/runs/`: `test-pin`, `export-failed`, `20261009T191917Z` y `20261009T191935Z` son artefactos de prueba, no corridas, y el primero parece una corrida autorizada rechazada por bucket.
   - Cambio mínimo propuesto, no implementado. Una regla determinista en `TurnPerception`: `meta` no es válido cuando el turno contiene un signo de interrogación sobre el equipo y no se limita a ofrecer evidencia. Alternativa más estrecha: invalidar `meta` cuando la sesión tiene `document_focus` y el turno no es un saludo ni una oferta de evidencia. La percepción inválida usa el camino ya existente de `fallback`. Prueba con stub del intérprete devolviendo `meta` para esta consulta. Por separado, y fuera de la fase 1: que las pruebas del harness escriban en `tmp/phase1_pinned_turn_test/`. La nota de ramas paralelas del chunk de la página 5 es un defecto de ingesta. No se reingiere ni se edita sin decisión del fundador.
9. Fase siguiente. La fase 2 no empieza: la fase 1 no recuperó evidencia. Repetir la fase 1 exige el cambio del intérprete aprobado y probado, y un cupo nuevo. El cupo de esta corrida no se reutiliza.

### Fase 2. Guía conversacional con el documento correcto

1. Estado: pendiente y bloqueada por la fase 1.
2. Prerrequisitos. El plano sigue pineado y la fase 1 recuperó un pasaje de ese documento. El cupo se escribe al cerrar la fase 1, con el conteo medido. El caso definitivo se diseña entonces. No se fuerza una aclaración si ese pasaje ya respondió la consulta.
3. Pregunta. Cuando el pasaje deje una incertidumbre que cambie el paso, ¿Danebo formula una sola pregunta útil, usa el dato que el técnico responde y ajusta la orientación?
4. Acciones y límites. El ciclo mínimo es una pregunta de Danebo, la respuesta del técnico y el turno siguiente. No se presenta como caso positivo con solución conocida. No se inyecta la referencia. No se alarga la conversación para imitar Journey A. Si la fase 1 ya cerró la pregunta, esta fase registra ese hecho y elige otra incertidumbre real del pasaje, o se detiene sin fabricar una duda.
5. Entradas y resultados. El caso se escribe al cerrar la fase 1. Un candidato, solo si el pasaje recuperado no iguala los dos nombres: Danebo pregunta si «Seguridad Puerta nivel 2» es la chapa de ese nivel; el técnico responde con lo que ve; la respuesta siguiente usa esa respuesta. El PDF etiqueta las dos cosas en páginas distintas del dibujo y no dice que sean el mismo contacto. La captura diagnóstica tampoco convierte esa distinción en un pase. No se usa este candidato si la fase 1 ya lo resolvió o si el pasaje recuperado no da pie.
6. Aceptación, fallo y detención. Aceptación: una sola pregunta que reduce una incertidumbre relevante, el dato del técnico queda en el estado, y la respuesta siguiente lo usa para ajustar la orientación. Si el pasaje no alcanza, el límite queda dicho. Detención: pregunta de más, ignora el dato aportado, iguala seguridad y chapa sin respaldo, o inventa una reparación. Si falta evidencia documental nueva, se localiza la capa y se para.
7. Evidencias. Correlación de los turnos del ciclo, estado del episodio antes y después, y la referencia ya corregida por el pasaje de la fase 1.
8. Hallazgos al cerrar. Vacío hasta la ejecución.
9. Fase siguiente. La fase 3 solo usa hechos que este ciclo haya dejado vigentes. Si el límite documental cambió la referencia, se reescribe el caso antes de continuar.

### Fase 3. Continuidad y correcciones

1. Estado: pendiente y bloqueada por la fase 2.
2. Prerrequisitos. Hechos vigentes del caso pineado. No se usa el fixture de Journey A como guion de esta fase. Los 14 turnos siguen siendo referencia histórica de continuidad, no la duración de esta fase.
3. Pregunta. ¿Un seguimiento, una corrección y un resumen coherentes con este caso conservan lo comprobado, actualizan lo corregido y respaldan cada afirmación documental nueva?
4. Acciones y límites. Los turnos que hagan falta para esa pregunta. Cada turno lleva su referencia de evaluador, escrita al cerrar la fase 2. Journey A no se edita. Una corrección, una aclaración o un resumen puede resolverse con el estado ya disponible, sin `Retrieve`. Una afirmación documental nueva necesita respaldo recuperado en ese turno o heredado e identificable: documento, página y pasaje ya aceptado.
5. Entradas y resultados. Se definen al cerrar la fase 2, a partir del pasaje real. No se inventan ahora. No se anticipan códigos, LED ni una placa que este PDF no contiene.
6. Aceptación, fallo y detención. Aceptación: el estado y la respuesta usan el valor nuevo y no tratan el viejo como vigente; cada afirmación documental nueva señala su respaldo. Detención: se pierde un hecho que cambia el paso, o una afirmación documental nueva no tiene pasaje recuperado ni heredado. Ahí se para y se separa causa inicial de consecuencia. La ausencia de `Retrieve` en una corrección resuelta con el estado no es, por sí sola, un fallo.
7. Evidencias. Delta del episodio, estado de la sesión, prompt enviado y, cuando hubo búsqueda, la solicitud y los chunks. Dentro de la captura.
8. Hallazgos al cerrar. Vacío hasta la ejecución.
9. Fase siguiente. La fase 4 incorpora lo que estas tres fases hayan mostrado del pin y del pasaje. No se implementa el descubrimiento antes de ese cierre.

### Fase 4. Identificación y selección documental

1. Estado: pendiente, diferida y bloqueada por la fase 3.
2. Prerrequisitos. Hallazgos de las fases 0 a 3. La propuesta de «Ajustes a la propuesta (2026-10-09)» se conserva y no está implementada. No es prerrequisito de la fase 1.
3. Pregunta. Con lo ya visto en el plano pineado, ¿hace falta el flujo de candidatos, confirmación por botón, pin y compatibilidad, y cuál es el cambio mínimo?
4. Acciones y límites. Primero se actualiza esta fase con los hallazgos anteriores. No se implementa desde este texto. Siguen fuera la confirmación por frase, reconfirmar un manual que ya no es candidato y seleccionar por marca o por falla.
5. Entradas y resultados. La propuesta diferida, más el comportamiento real del pin en las fases 1 a 3.
6. Aceptación, fallo y detención. Aceptación de una implementación futura: la que ya está escrita en la propuesta, ajustada por los hallazgos. Detención: empezar a codificarla antes de ese ajuste, o tratar `known?` como compatibilidad.
7. Evidencias. Diff de producto, cuando se autorice, y pruebas con stubs. Sin AWS en ese corte local.
8. Hallazgos al cerrar. Vacío hasta la ejecución.
9. Fase siguiente. La fase 5 usa el foco explícito que esta fase haya dejado disponible. Si esta fase no se autoriza, la fase 5 no inventa otro mecanismo de selección.

### Fase 5. Interpretación documental equivocada

1. Estado: pendiente y bloqueada por la fase 4.
2. Prerrequisitos. Un pasaje real del plano y una conclusión del técnico que ese pasaje no sustenta. La referencia la escribe el evaluador al cerrar la fase anterior.
3. Pregunta. ¿Danebo explica que el diagrama no sustenta esa conclusión, revisa la documentación pertinente y propone cambiar o complementar el foco de forma explícita?
4. Acciones y límites. No se reingiere ni se altera el índice para forzar la explicación. Una búsqueda diagnóstica no aprueba la consulta natural. No se enseña un procedimiento de otro equipo.
5. Entradas y resultados. Se fijan con el pasaje recuperado. La afirmación que el pasaje no sostiene forma parte de la referencia y no se inyecta.
6. Aceptación, fallo y detención. Aceptación: la respuesta nombra el límite y la acción explícita sobre el foco. Fallo: adopta la conclusión del técnico, o suelta el pin en silencio. Detención: el pasaje no está en la consulta natural.
7. Evidencias. Recorrido correlacionado del turno y la referencia del evaluador.
8. Hallazgos al cerrar. Vacío hasta la ejecución.
9. Fase siguiente. No hay una fase 6 en esta ruta. El backlog sigue aparte.

## Registro de revisión

| Hallazgo | Resolución | Estado |
|---|---|---|
| La ruta de las etapas 1 a 3 y los 14 turnos sin pin no separan extracción, retrieval, aplicabilidad, memoria, generación y arnés. | Este corte deja una sola ruta, fases 0 a 5, y pasa el texto anterior a referencia. | Escrito. No autoriza corrida. |
| El sufijo `(1)` y la fila 213 no deciden el documento. El `document_id` del chunk y el `document_uid` de la fila son identificadores distintos. | La fila 213 tiene el UID y la clave de la captura. El usuario 1 está autorizado. En este proceso la URI canónica usa `smart-deal-dev-kb`. | Abierto en el bucket de la URI. |
| El runner de Journey A no ejecuta la fase 1. | Wrapper en servicio, sesión nueva, un turno por la secuencia de `ask`, sin `Retrieve` de disponibilidad. | Código y pruebas con stubs. Corrida real sin hacer. |
| El cupo de la fase 1 no puede ser el de `Stage2RunBudget`. | Tres intentos, contador antes de cada llamada, sin reintento. `PASS_CALL_CAP` sigue en 0. | Implementado e inactivo. Pendiente de autorización del fundador. |
| Alcance, evidencia y respuesta se medían juntos, con k=3 y `pin_only`. | Tres criterios independientes. Se registran reason, modalidad y k reales. | Escrito. |
| La fase 2 no tenía el ciclo de una pregunta útil y la fase 3 exigía `Retrieve` en toda corrección. | El caso de la fase 2 se diseña tras el pasaje real. Una afirmación documental nueva lleva respaldo recuperado o heredado. | Escrito. Sin caso definitivo. |
| Jesús Graterol figuraba como fundador. | Es el técnico. Lahiri Sánchez es el fundador que aportó ese feedback. | Corregido en la propuesta diferida. |
| `PilotUsage` no guarda el recorrido completo. | La corrida exige `ValidationCapture.capture`. El flag de auditoría no lo sustituye. La sesión 3 muestra el hueco: 14 respuestas visibles, cero citas, `filter_applied` falso y el filtro de cuenta solo en la captura. | Escrito. Sin cambio de código. Sin llamadas nuevas. |
| La representación indexada y la recuperación son la misma prueba. | La referencia de la página 5 es la serie confirmada por Lahiri. La lectura de dos ramas queda corregida. La página 6 queda «No recuperada en la consulta diagnóstica; causa pendiente». | Escrito. La consulta natural sigue sin ejecutarse. |
| El harness devolvía `ok` y no guardaba la captura. | `completed` no es aceptación documental. La evidencia se exporta también en parada y en fallo. El entorno se compara con los valores ya cargados. | Corregido en local. Sin corrida real. |
| Gate de URI de la fase 0. | Proceso con el bucket de la captura: URI canónica de la fila 213 igual a `original_source_uri`, usuario 1 autorizado, sin filas nuevas. | Cerrado el 2026-10-09. |
| Fase 1, run `20261009T194048Z`. | El intérprete clasificó la consulta como `meta`; el turno descartó la pregunta y salió sin `Retrieve`. Un intento de modelo, US$0,002704 estimado. | Detenida por evidencia ausente. Cambio mínimo propuesto, no implementado. |
| El chunk de la página 5 pone en duda la serie con «ramas paralelas visuales». | Defecto de representación documentado. Sin reingesta. | Pendiente de decisión del fundador. |
| Las pruebas del harness escriben en el directorio de corridas reales. | Propuesta: `evidence_root` de prueba. | Propuesto, no implementado. |

## Cierre de la preparación local

Actualización del 2026-10-09: la fase 0 está cerrada y la fase 1 quedó detenida. El estado vigente está en esas fases; este cierre conserva la preparación tal como quedó antes de la corrida.

Preparación local: corregida y todavía sin corrida. Fase 0: lectura hecha, gate de URI abierto. Fase 1: sin corrida. La aceptación documental no se decide por `completed`.

Comprobaciones locales. Host `localhost`. `current_database`: `smart_deal_stage2_isolated`, `smart_deal_stage2_isolated_cache`, `smart_deal_stage2_isolated_cable`. Cola `smart_deal_development_queue`. Cuenta 1 `danebo-legacy`. Usuario `stage2-journey-a@localhost.test`, id 1, autorizado sobre la fila 213. `document_uid` `dcc8e046-037d-48a6-8913-1992aed28507`. `id` 213. `s3_key` igual a la de la captura. `document_id` del chunk `121bfffe0827f6bc681ba9bdc91050390055`. SHA-256 del PDF local igual a `doc_sha256`. `canonical_uri` en este proceso: `s3://smart-deal-dev-kb/bulk_uploads/1/2026-08-31/Montacargas 2N Temporizado-1 (1).pdf`. Captura: `s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/Montacargas 2N Temporizado-1 (1).pdf`. Proceso de restauración, sin exportaciones de validación: bases `smart_deal_development`, `smart_deal_development_cache`, `smart_deal_development_cable`, KB `QGVYLPTEGT`, `PASS_CALL_CAP` 0, fase 1 no autorizada.

PDF. La referencia vigente de la página 5 es la cadena en serie plegada en dos columnas, revisada visualmente por ChatGPT y confirmada por Lahiri. La descripción anterior de dos ramas eléctricas queda corregida. Páginas 5 y 6 etiquetan chapas en otros tramos. La página 6 de la búsqueda diagnóstica queda «No recuperada en la consulta diagnóstica; causa pendiente».

Archivos. `app/services/rag/phase1_pinned_turn.rb`, `script/field_companion/phase1_pinned_turn.rb`, `test/services/rag/phase1_pinned_turn_test.rb`. El contador, cuando está armado, entra en `BedrockClient#generate_text`, `BedrockClient#converse_message` y `BedrockRagService#retrieve_and_generate_with_retry`. Corrección posterior del harness: exportación de la captura, estado `completed` distinto de la aceptación, y rechazo de la configuración efectiva. Pruebas de esta corrección: `bin/rails test test/services/rag/phase1_pinned_turn_test.rb`, 13 corridas, 130 aserciones, 0 fallos. Sin llamadas AWS.

Bloqueos. No se ejecuta el turno contra la fila 213 mientras `KB_BUCKET` sea `smart-deal-dev-kb`. No se leyó el objeto en S3. No se inspeccionó el chunk indexado de la página 6. Límites de observabilidad que esta preparación no cierra: `RagResult` sigue copiando solo la correlación que devuelve el servicio; el wrapper pasa la suya al turno del asistente. `filter_applied` sigue siendo el filtro de URI del pin. `PILOT_AUDIT_CAPTURE` no abre `ValidationCapture`.

Siguen pidiendo autorización del fundador: hasta 4 `Retrieve` de solo lectura para la representación indexada, una lectura S3 si hace falta además del hash local, el cupo de tres intentos y `PHASE1_PINNED_TURN_AUTHORIZED=1` en un proceso arrancado con `KNOWLEDGE_BASE_S3_BUCKET=multimodal-source-destination` y la KB `Y7RZWMFJSR`. El siguiente paso es esa autorización. Esta preparación se detiene antes de cualquier llamada real.

## Propuesta diferida de descubrimiento

Sigue sin implementar. No es prerrequisito de la fase 1. El borrador de cinco pasos permanece retirado en la referencia histórica. La frase de confirmación, reconfirmar un manual que ya no es candidato y seleccionar por marca o por falla siguen fuera. El texto de abajo es el que estaba en «Ajustes a la propuesta (2026-10-09)», movido aquí sin cambiar sus decisiones.

### Ajustes a la propuesta (2026-10-09)

Esta es la única propuesta. Reemplaza el borrador de cinco pasos, que queda retirado arriba. Está corregida en su lugar: no hay otra sección de propuesta. Sigue sin implementar, sin llamadas AWS, sin workers, sin despliegue y sin ampliar el presupuesto. `PASS_CALL_CAP` permanece en 0. El cierre de `3ff27f9` queda en 188 llamadas y US$0,423114.

###### Qué cambia respecto del texto anterior de esta misma sección

1. Correspondencia del manual y evidencia de la búsqueda son evaluaciones distintas. Un pasaje de compatibilidad incierta no es lo mismo que una búsqueda sin evidencia.
2. Confirmar que un manual corresponde al equipo no demuestra que cubra la placa, que contenga la respuesta ni que esta búsqueda haya recuperado un pasaje. Reconfirmar no vuelve usable una respuesta sin evidencia. Otro manual seleccionado tampoco vuelve aplicable el primero.
3. En este corte el botón solo acepta una propuesta vigente. Un botón armado antes de corregir equipo, modelo o placa se rechaza si esa fila ya no es candidata. No hay reconfirmación excepcional del mismo documento. Agregar, reemplazar o quitar usan propuestas vigentes o el control de quitar que ya existe.
4. La marca no anula un conflicto de modelo o de placa. La falta de modelo en un pasaje no prueba compatibilidad ni incompatibilidad. Equipo y componente son slots distintos.
5. `DocumentDiscovery::MAX_CARDS` sigue en 2. No se muestra una tarjeta por cada documento cuando hay más de dos, y el orden no se presenta como acierto si no hay con qué ordenar.
6. Los síntomas y las comprobaciones se conservan y se utilizan cuando corresponde. No se exige un resumen completo en cada respuesta.

###### Cómo interactúan los mecanismos ya revisados

`5f69556` conserva el «+» al guardar el designador (`ActiveEpisodeTurn::DESIGNATOR_RE`, `TechnicalReferentResolver`, `DocumentIdentityCatalog.designator_label`). `DocumentDiscovery#exact_entries` compara con `#normalize`, que llama a `FollowupQueryRewriter.normalize_label` y borra el signo. `CEA15` y `CEA15+` quedan en la misma clave. `FocusNotice#normalize` usa el mismo método: si el aviso recibiera los designadores, `CEA15` y `CEA15+` no se verían distintos. `DocumentIdentityCatalog#resolve_designator` y el designador de `#resolve_compound_brand` comparan con `designator_label`, que conserva el «+». `#resolve_brand` normaliza la marca, no el designador. El prefijo del catálogo exige token de largo al menos 6, con dígito y sufijo de hasta 4. `CEA15` tiene largo 5 y `VF5` largo 3, así que esa regla no los convierte en `CEA15+` ni en `VF5+`. Un `:exact` o un `:prefix` con varias entradas del mismo designador devuelve `candidates` vacío y un solo valor; no enumera los documentos. Dos valores de designador distintos vuelven `:ambiguous`. `#resolve_compound_brand` devuelve `nil` si hay más de una entrada.

En `:ambiguous`, `candidates` trae los valores de designador, no los `KbDocument`. La lista de documentos sale de las entradas que coinciden, las mismas que recorre `exact_entries`, y de enlazar cada una. `resolve_brand` en éxito trae el fabricante y `candidates` vacío; en ambigüedad trae cadenas de marca, no documentos.

`EquipmentIdentity#known?` es verdadero con fabricante o modelo de procedencia `user` o `photo`. Abre la ruta `document_identity_scope`. No filtra el índice y no prueba correspondencia documental. En la pasada, los catorce retrieves siguieron en corpus abierto, k=8, y `DocumentIdentityScope` marcó los ocho resultados como ajenos.

`CompanionGuidanceContext` mete en el guidance conocido «Continue helping … generic diagnostic reasoning» y, cuando la salida está apagada, una observación o comprobación siguiente. La frase «Put what the photo shows…» sale en `known_detail_pieces` sin mirar si hay imagen. `INTERVENTION_LIMIT` está solo en el guidance desconocido. `documentation_exit?` del camino conocido recibe la consulta compuesta (`BedrockRagService#document_identity_scope_result`); el camino desconocido recibe el turno crudo. `EXIT_RULE` pide un dato decisivo y a la vez prohíbe otra comprobación de rutina. Esa combinación, más el párrafo de razonamiento genérico, es lo que los turnos 9 y 12 cumplieron al pie de la primera rama y no de la segunda.

Las instrucciones del repositorio empujan en el mismo sentido. `AGENTS.md` dice que, con identidad conocida y sin manual compatible, se continúa el diagnóstico con la observación visual aceptada, el problema activo y razonamiento genérico de campo, sin enseñar un procedimiento ajeno y sin cerrar en un rechazo de búsqueda. `app/services/rag/AGENTS.md` repite esa continuación y dice que el turno no termina en `DATA_NOT_AVAILABLE`. `app/prompts/AGENTS.md` repite la continuación, autoriza a decir lo obvio para ese tipo de componente y, con identidad desconocida, a ofrecer un procedimiento análogo con manual, página y un descargo. El descargo no vuelve aplicable el procedimiento. El guidance en runtime obedece la continuación genérica y deja sin efecto, en la respuesta visible, la prohibición de procedimiento ajeno.

El pin de la tarjeta no usa el control de episodio que ya existe. `ConversationSession#pin_kb_document_if_episode_owner!` compara `expected_episode_id` con `live_episode_id` dentro de `with_lock` y no escribe si difieren. El POST de la tarjeta llama a `pin_kb_document!`, que también toma el lock y no compara el episodio. El id de episodio tampoco basta: una corrección de modelo ocurre dentro del mismo episodio. `WorkContextReducer#clear_pending_unless_meta` borra `pending_question` en cada turno que no es meta ni `clarify_first`. Guardar ahí la propuesta la perdería en el turno siguiente y competiría con `ActiveEpisode::MAX_BYTES` (4096). La propuesta no se persiste. La tarjeta ya lleva `kb_document_id`, `document_uid` y `focus_mode`.

`DocumentIdentityScope.chunk_applicability` devuelve `:compatible` en cuanto un needle coincide con un campo de identidad, antes de mirar si otro designador del mismo campo está en conflicto. `contains_word?` usa `normalize_label`, así que también borra el «+». Con los datos actuales, una coincidencia de marca puede marcar compatible un pasaje cuyo modelo documental es otro, y `MH` puede coincidir con `MH+`. El comentario del método dice que un título sin designador, como «Elemont montacargas», queda `:neutral` cuando el documento está seleccionado. El catálogo guarda `role` (`equipment` o `component`) y no guarda en qué equipos se instala un componente. `DocumentIdentityScope` no lee `role`. `resolve_needles` mezcla fabricante, modelo e identificadores en una sola bolsa. Esa bolsa no distingue el slot del equipo del slot de la placa.

###### Candidatos

La resolución reutiliza el catálogo y el enlace ya existentes, en el turno, sin Retrieve, sin otra llamada de modelo y sin tabla. Cada designador se clasifica con `resolve_designator` o, si el span trae marca y designador, con `resolve_compound_brand`. Esa clasificación no es la lista de documentos. Las tarjetas salen de las entradas cuyo `designator_label` coincide, enlazadas con `KnowledgeScopePolicy.bind_catalog_candidate`. La marca sola usa `resolve_brand` y las entradas de equipo de esa marca. Una fila se ofrece si el enlace devuelve un documento que el visor puede usar. La comparación conserva el signo.

`DocumentDiscovery::MAX_CARDS` vale 2 y este corte no lo sube. «Una tarjeta por documento» vale cuando hay una o dos. Cuando hay más, se muestran dos y se dice que hay más. No se agrega otra pantalla ni otro control para recorrer el resto.

El orden, antes de cortar en dos, usa el slot y no un retrieve extra:

1. Designador exacto del slot de la pregunta: modelo del equipo, o placa o controlador.
2. Designador exacto de otro slot ya declarado.
3. Una entrada de equipo de la marca, cuando el modelo no se conoce.

Un `:prefix` del catálogo, con el largo mínimo de 6 que ya existe, va después de los exactos y se muestra como parecido, con el designador real a la vista. No se baja ese umbral para alcanzar `CEA15` o `VF5`. Si en el mismo nivel quedan más de dos y ni el catálogo ni los datos ya declarados los distinguen, esos dos no son un ranking. El texto dice que son parte de la lista y que ninguno queda elegido, y pide la marca impresa que los distinguiría. No se presenta el primero como el correcto.

- Sin coincidencia exacta. Se dice que no hay un manual con ese designador. Los síntomas y las comprobaciones se conservan y se utilizan cuando corresponde. Se pide el dato que distinguiría un manual. `CEA15` no ofrece el manual de `CEA15+`.
- Varios candidatos. No hay elección por defecto. Un «sí» no elige. Con más de dos se muestran dos, en el orden de arriba.
- El técnico no conoce el modelo. Si la marca tiene una sola entrada de equipo enlazada, esa se propone. Si tiene varias, se muestran hasta dos y se pregunta el modelo. No se bloquea la conversación por faltar el resto de la placa.
- Equipo y placa. Cada slot produce su propia propuesta. Elegir el manual del equipo no cubre la placa, y al revés. Si la placa no tiene fila exacta, se dice eso y no se le asigna el manual del equipo ni el designador vecino.
- Entrada de catálogo sin documento local. Se puede nombrar y no tiene botón. En esta base aislada, 202 entradas están así porque las filas no están cargadas: es límite del entorno. El límite de producto es una entrada que, para ese visor, no enlaza un documento. Cargar las 202 filas no es requisito de este diseño.

###### Confirmación de una propuesta vigente

El botón solo acepta una propuesta vigente. La propuesta lleva `kb_document_id`, `document_uid`, el span, el slot del que salió y el `episode_id` con el que se armó. El POST entra al `with_lock` de la sesión. Antes de escribir se comprueban la autorización, que el id tenga ese uid, que el episodio sea el vivo, y que al recalcular los slots declarados esa fila siga siendo candidata. Un turno que solo agrega síntoma, planta o código no cambia el slot y el botón sigue vigente. Dos toques del mismo documento siguen siendo idempotentes. Elegir una tarjeta no elige la otra.

El botón obsoleto es el que se armó antes de corregir equipo, modelo o placa, cuando ese span ya no resuelve la misma fila. El POST no escribe. La propuesta nueva es otra tarjeta, calculada después de la corrección, y solo aparece si la identidad corregida todavía tiene esa fila como candidata. Su POST puede agregar o reemplazar porque la correspondencia que se revalida es la de ahora.

Las dos reglas conviven porque no actúan sobre el mismo objeto. El POST viejo se rechaza. La tarjeta nueva se acepta solo mientras la fila siga siendo candidata. No hay un tercer paso en el que el botón rechazado escriba después la misma fila.

Si la corrección deja esa fila fuera de los candidatos, no aparece un botón para ella. En este corte se puede agregar o reemplazar con una propuesta que sí esté vigente, o quitar el manual con el control que ya existe. Reconfirmar un manual que ya no es candidato sería un dato nuevo de correspondencia. El botón actual no puede expresarlo, porque solo acepta candidatura vigente. Esa reconfirmación queda fuera de este corte.

Confirmar el equipo escribe el hecho en el episodio. Confirmar el manual lo deja seleccionado. Ninguna de las dos prueba que el manual cubra la placa, que contenga la respuesta o que esta búsqueda haya traído un pasaje. Nombrar el manual no lo selecciona. Un «sí» suelto, el «sí» a una medición o el «sí» con dos tarjetas no escriben la selección. La confirmación por frase queda fuera de este corte.

###### Correspondencia del manual y pasaje de la búsqueda

Se evalúan por separado, y cada manual por su cuenta. Otro manual seleccionado no cambia el resultado del primero.

Los slots no se mezclan. El del equipo es la marca y el modelo declarados. El del componente es la placa o el controlador declarados. Un designador se compara solo con su slot. El modelo del equipo no tiene que figurar en el manual de la placa. El designador de la placa no tiene que figurar en el manual del equipo.

Precedencia:

1. Identidad declarada vigente, por slot.
2. Identidad de catálogo de ese documento: `role`, marcas y designadores. `role` ya está guardado. El alcance hoy no lo lee. Este corte lo usa para elegir el slot, no para crear otro almacén.
3. Campos de identidad del pasaje, solo para ese pasaje.
4. Selección explícita. Mantiene el manual seleccionado y visible. No borra una contradicción explícita de los puntos 2 o 3 y no crea un pasaje.

Una coincidencia de marca no anula un conflicto explícito de modelo o de placa en el slot de ese documento. Un pasaje sin modelo no prueba compatibilidad ni incompatibilidad. La comparación de designadores usa `designator_label`. Hoy `identity_matches?` y `contains_word?` no lo hacen: una marca basta para `:compatible` y el «+» se pierde. Ese es el comportamiento que este corte cambia.

Un manual de componente puede servir a más de un equipo solo cuando esa relación está respaldada. Con los datos que hay, la relación respaldada es la coincidencia exacta del designador en el slot del componente, con `role` de componente. El catálogo no registra en qué equipos se instala esa placa. Que la marca del manual sea distinta de la del ascensor no es, por sí solo, un conflicto de ese manual de placa. Si la placa no está declarada, la correspondencia de ese manual con este ascensor queda sin decidir: se dice y se pide la inscripción de la placa. No se infiere por la marca del ascensor.

Ejemplos, que también son pruebas:

- Marca coincidente y modelo en conflicto. Lo declarado es Elemont y MH+. El catálogo y el pasaje dicen Elemont y MH. La marca coincide y el slot del modelo no. El pasaje no es el procedimiento de este trabajo. Si el manual ya estaba seleccionado, sigue seleccionado. El botón viejo no escribe.
- Pasaje sin modelo, con la correspondencia ya caída. El título es «Elemont montacargas» y no trae modelo, después de corregir el modelo fuera del designador del catálogo. El pasaje no restablece la correspondencia y no se enseña como procedimiento del modelo nuevo.
- Manual de componente con relación respaldada. La placa declarada es CEA15+ y la entrada tiene `role` de componente, designador CEA15+ y marca Controles S.A., con equipo Elemont MH. El slot de la placa coincide. Es candidato de la placa. No prueba que cubra todo el MH ni que contenga la falla. CEA15 declarado no coincide con CEA15+.
- Dos manuales seleccionados. Uno sigue coincidiendo con MH y tiene un pasaje que responde la pregunta. El otro es CEA15+ y la placa declarada es CEA15. Se usa solo el pasaje del primero. El segundo sigue seleccionado y su procedimiento no se usa. El resultado del primero no lo absuelve.
- La selección no borra una contradicción explícita. El técnico eligió el manual de MH y después dice que el modelo es otro. El manual sigue seleccionado. El conflicto de modelo permanece. Ese manual deja de ser candidato y no se le arma un botón.

###### Manual seleccionado en conflicto, y búsqueda sin evidencia

El manual no se quita y el corpus no se abre.

Correspondencia en conflicto: el slot del documento contradice el slot declarado. El manual sigue seleccionado. No se enseña su procedimiento, tampoco el de un pasaje suyo que no trae modelo. El texto nombra las dos referencias: «El manual seleccionado es del modelo MH. Indicaste otro modelo. Sigue seleccionado y no uso su procedimiento.» En este corte se puede agregar una propuesta vigente, reemplazar por una propuesta vigente, o quitar. No se ofrece confirmar ese mismo manual.

Búsqueda sin evidencia: la correspondencia de ese manual puede seguir vigente y, aun así, esta búsqueda no trajo un pasaje que responda. El texto es «No encontré evidencia suficiente en esta búsqueda.» El manual sigue seleccionado. Eso no prueba que el manual no tenga la sección. Volver a elegirlo no crea el pasaje. El pasaje de otro manual seleccionado tampoco cuenta como evidencia de este.

Pasaje que no decide: la búsqueda sí trajo un pasaje, y sus campos no dicen el slot. Si la correspondencia del documento sigue vigente, la respuesta puede decir solo lo que ese pasaje dice, sin convertir la falta de modelo en una coincidencia. Si la correspondencia está en conflicto o sin decidir, ese pasaje no la repara.

Una afirmación del fabricante sale solo de un pasaje que pertenece a un documento con correspondencia vigente, cuyos campos no traen un conflicto explícito, y que contiene ese dato.

Hoy `RagController` arma el aviso con `model_tokens` vacío y `DocumentDiscovery` hace lo mismo en la rama de contradicción. Un cambio de modelo sin marca nueva no muestra la diferencia, y el guidance conocido sigue encargando diagnóstico genérico.

###### Búsqueda, refuerzo y consulta directa

Mostrar candidatos, confirmar que un manual corresponde y dejarlo seleccionado son tres acciones distintas. La evidencia de campo no las funde.

Jesús Graterol, técnico, el 28/09/2026. Lahiri Sánchez, fundador, aportó este feedback:

«Sí respondió correctamente, es decir asoció la falla con los elementos relacionados con ese punto, lo que sí no hizo fue asociar la marca del ascensor a los manuales que están ahí. Entonces me tocó seleccionarlos».

«Como recomendación, sería bueno que al colocar la marca del equipo y la falla, ella inmediatamente me mostrara los manuales donde podrían buscar más información relacionada con las soluciones que me brinda a manera de refuerzo».

Es evidencia aportada por el fundador a partir de lo que dijo el técnico. No autoriza a seleccionar un manual por la marca o por la falla. No prueba que aquella respuesta tuviera respaldo documental. Describe que la respuesta le sirvió a Jesús para asociar la falla con elementos, que los manuales no quedaron ligados a la marca, y que la selección la hizo él.

Caminos:

- Marca o equipo, y falla. Se usan los antecedentes ya guardados para proponer manuales candidatos y se pregunta solo el dato que falta para distinguirlos. Mostrarlos no los selecciona y no confirma la correspondencia. Un manual presentado como refuerzo tiene que contener un pasaje que respalde lo que se afirma. En este corte eso ocurre después de la selección y de la búsqueda dentro de ese manual. No se arma una solución y después se le acerca un documento por parecido.
- Manual ya seleccionado, con la correspondencia todavía vigente para el slot de la pregunta. Se busca ahí directamente. No se reinicia la identificación.
- Pregunta explícita por un manual. Se usa el nombre para reconocer de qué documento se habla. Nombrarlo no lo selecciona y no obliga a rehacer la identificación. Si ya hay otro manual seleccionado, la búsqueda actual no sale de los manuales seleccionados. La alternativa mínima es ofrecerlo como candidato para agregar. No se abre el corpus y no se agrega solo. Ese es el límite del foco actual. Si no hay manual seleccionado, la búsqueda abierta que ya existe puede correr; el nombre sigue sin seleccionar.
- Pregunta por un componente o un código. Se resuelve ese slot. No se exige la identidad completa del ascensor. Si lo que distinguiría el manual es la inscripción de la placa, se pide eso.
- Candidatos sin correspondencia clara. Se muestra la incertidumbre y se pide el dato que distingue. No se presenta el primero como el correcto.

La foto entra en el guidance solo cuando ese turno tiene una observación visual aceptada. `documentation_exit?` del camino conocido evalúa el mensaje original del técnico, no la consulta compuesta. El modo conocido recibe `INTERVENTION_LIMIT` cuando no hay un pasaje que respalde. El guidance deja de encargar diagnóstico genérico y una comprobación siguiente tanto si la correspondencia está en conflicto como si esta búsqueda no tiene evidencia suficiente. Esas correcciones no desbloquean la etapa: los turnos 9 y 12 ya tenían `EXIT_RULE` y pidieron mediciones. El resumen de salida queda para ese turno de salida, no para cada respuesta de identificación. Los síntomas y las comprobaciones se conservan y se utilizan cuando corresponde.

###### Estados y transiciones

No hay estado nuevo persistido. Cada turno deriva, por manual, la correspondencia, y por separado el resultado de esta búsqueda.

| Relación | Qué la sostiene |
| --- | --- |
| Declarada | Identificadores del episodio, separados por slot. |
| Candidatos | Hasta dos tarjetas vigentes. Ninguna deja el manual seleccionado. |
| Manual seleccionado, correspondencia vigente | El técnico eligió esa fila y el slot del catálogo sigue coincidiendo. |
| Manual seleccionado, correspondencia en conflicto | Sigue seleccionado y el slot del documento contradice el declarado. |
| Manual seleccionado, correspondencia no decidida | Sigue seleccionado y falta el slot o una relación respaldada. |
| Pasaje que respalda | Esta búsqueda trajo un pasaje de un documento con correspondencia vigente, sin conflicto explícito en sus campos, y el pasaje contiene el dato. |
| Pasaje que no decide | Esta búsqueda trajo un pasaje sin modelo o sin slot. No prueba compatibilidad ni incompatibilidad. |
| Sin evidencia en esta búsqueda | Esta búsqueda no trajo un pasaje que responda. Es independiente de la correspondencia. |

Transiciones:

- Declarada → candidatos, cuando hay filas para mostrar, como máximo dos.
- Candidato vigente → manual seleccionado, solo con el botón, el lock, id, uid, autorización, episodio y correspondencia vigente de ese slot.
- Botón obsoleto → no escribe. Si la identidad corregida produce otra tarjeta, esa tarjeta es otra propuesta. Si no la produce, no hay botón para el documento que dejó de ser candidato.
- Manual con correspondencia vigente → pasaje que respalda, o pasaje que no decide, o sin evidencia, según esta búsqueda. Son tres llegadas distintas.
- Sin evidencia no pasa a pasaje que respalda por volver a elegir el manual, ni porque otro manual seleccionado sí tenga un pasaje.
- Un pasaje que no decide no pasa a pasaje que respalda por la selección ni por el otro manual.
- La correspondencia en conflicto permanece así mientras el slot declarado contradiga el del documento. No hay botón que la vuelva vigente. Si un turno posterior cambia el slot y el documento vuelve a ser candidato, esa tarjeta es una propuesta nueva: elegirlo deja el manual seleccionado para la identidad que ahora coincide. Esa elección no crea un pasaje y no convierte en evidencia una búsqueda que no lo tuvo.
- Agregar y reemplazar escriben solo una propuesta vigente. Quitar usa el control existente. Cada manual conserva su evaluación.

Comportamiento visible, en lenguaje del técnico:

- Un candidato: «Entiendo que se trata del equipo Elemont MH. Encontré el manual Elemont Montacargas Hidraulico Modelo MH. ¿Ese manual corresponde a tu equipo?» Botón para dejarlo seleccionado. No dice que cubra la placa ni que contenga la falla.
- Más de dos: «Encontré varios manuales. Te muestro dos. Ninguno queda elegido. Si en la placa figura el modelo, con eso los distingo.»
- Sin fila: «No encontré un manual con el designador CEA15. CEA15+ es otro.»
- Tras elegirlo: «Manual seleccionado.» El texto de estado de hoy dice «Manual enfocado»; el cambio de frase es de este corte, cuando se autorice, no de esta revisión.
- Conflicto: «El manual seleccionado es del modelo MH. Indicaste otro modelo. Sigue seleccionado y no uso su procedimiento. Podés agregar otro, reemplazarlo o quitarlo.»
- Sin evidencia: «No encontré evidencia suficiente en esta búsqueda. El manual sigue seleccionado.»
- Pasaje que no decide: «Este pasaje no indica el modelo. No alcanza para decir que corresponda al que indicaste.»
- Los síntomas y las comprobaciones se conservan y se utilizan cuando corresponde. No se exige un resumen completo en cada respuesta.

###### Archivos, cuando se autorice

- `app/services/rag/document_discovery.rb`: igualdad con `designator_label`. Candidatos por slot. `MAX_CARDS` permanece en 2. Si quedan más, el texto dice que la lista es más larga y que el orden no elige.
- `app/services/rag/document_identity_catalog.rb`: el prefijo mantiene el largo mínimo de 6. `role` se lee para elegir el slot del equipo o del componente.
- `app/controllers/rag_controller.rb` y la vista de la tarjeta: la tarjeta vigente lleva span, slot y `episode_id`.
- `app/controllers/pinned_documents_controller.rb` y `ConversationSession#pin_kb_document!`: revalidación bajo el lock de id, uid, autorización, episodio y candidatura vigente. El POST obsoleto no escribe. No se agrega un camino de reconfirmación excepcional.
- `app/services/rag/focus_notice.rb`: slots del episodio y `designator_label`, no `model_tokens` vacío. El aviso no ofrece confirmar un manual que ya no es candidato.
- `app/services/rag/document_identity_scope.rb`: un designador se compara con `designator_label` y solo con su slot. Una marca no deja en compatible un modelo o una placa en conflicto. Un pasaje sin modelo queda sin decidir. La selección no borra esa contradicción ni abre el corpus.
- `app/services/rag/companion_guidance_context.rb` y `app/services/bedrock_rag_service.rb`: foto condicionada, salida sobre el mensaje original, límite de instrumento cuando no hay pasaje que respalde, y sin diagnóstico genérico si la correspondencia está en conflicto o si esta búsqueda no tiene evidencia. Sin resumen completo en cada turno.
- `app/javascript/controllers/rag_chat_controller.js`: solo si el POST debe enviar span, slot y `episode_id`. El endpoint sigue siendo el de la selección.
- `config/locales/rag.es.yml`: «Manual seleccionado», «No encontré evidencia suficiente en esta búsqueda», y la diferencia concreta entre las dos referencias. Esas frases no nombran autorización ni normalización.
- Instrucciones, en el mismo corte que el guidance: `AGENTS.md`, `app/services/rag/AGENTS.md`, `app/prompts/AGENTS.md`.
- Pruebas nuevas, abajo. El fixture de Journey A no se edita.

No entran otra tabla, otra caché, una búsqueda en segundo plano ni una llamada de modelo. El catálogo, la tarjeta, el lock y el alcance por pasaje alcanzan para este corte. La búsqueda con manual seleccionado sigue limitada a esos manuales. Subir la cantidad de resultados no forma parte de esta propuesta.

Queda fuera de este corte: la confirmación por frase; reconfirmar un manual que ya no es candidato; subir `MAX_CARDS`; una navegación nueva para ver más tarjetas; abrir el corpus cuando la búsqueda del manual seleccionado no trae evidencia; seleccionar al nombrar una marca, una falla o un manual; presentar un manual como refuerzo de una solución que ese manual no respalda con un pasaje.

###### Secuencia y criterios de aceptación

1. Pruebas locales con stubs, en rojo, antes de cambiar la conducta.
2. Comparación de designador que conserva el signo, y candidatos por slot sin escribir la selección.
3. Texto y botones de un candidato, de dos, y de más de dos sin presentar el primero como el correcto.
4. Revalidación del POST bajo el lock, y rechazo del botón obsoleto.
5. Correspondencia en conflicto, pasaje que no decide y búsqueda sin evidencia, como tres resultados distintos. Cada manual se evalúa solo.
6. Guidance y las tres instrucciones del repositorio, en el mismo corte.
7. La suite con stubs, incluidos los caminos de consulta directa. Journey A no se corre y sus 14 turnos no se modifican.

Aceptación:

- Descubrimiento: `CEA15` no ofrece `CEA15+` y `VF5` no ofrece `VF5+`. La prueba cubre la tarjeta, no solo el guardado del designador.
- Un candidato Elemont MH enlazado a la fila 213 se nombra y no queda seleccionado hasta el botón.
- Dos candidatos muestran dos tarjetas y un «sí» no selecciona. Con tres o más se muestran dos, el texto dice que hay más y ninguno queda elegido, y `MAX_CARDS` sigue en 2.
- Sin coincidencia no se inventa un manual. Síntoma y comprobaciones siguen guardados y no se recitan enteros en la respuesta.
- Marca conocida sin modelo: una sola fila de equipo se propone; varias se listan hasta dos.
- Entrada sin documento local no tiene botón. La prueba separa ese límite de producto de las 202 filas ausentes en la base aislada.
- El botón deja el manual seleccionado, en modo agregar, solo si id, uid, episodio y candidatura vigente coinciden, y la autorización sigue vigente.
- Después de corregir modelo o placa, el POST de la tarjeta vieja no escribe. Una tarjeta calculada después escribe solo si esa fila sigue siendo candidata. No existe un botón que reconfirma la fila que dejó de serlo.
- Un «sí» ambiguo no escribe la selección. Nombrar el manual tampoco.
- Marca coincidente y modelo documental en conflicto: el procedimiento de ese manual no se publica. La selección, si existía, sigue visible.
- Pasaje sin modelo de un documento cuya correspondencia ya no está confirmada: no se enseña como procedimiento del modelo corregido.
- Manual de componente con designador de placa coincidente: es candidato de la placa aunque la marca del manual no sea la del ascensor. No cubre el equipo entero ni afirma la falla. `CEA15` no toma el manual de `CEA15+`.
- Dos manuales seleccionados, uno con pasaje que respalda y otro en conflicto de placa: se usa solo el primero. El segundo sigue seleccionado y no queda absuelto por el primero. El corpus no se amplía.
- La selección del técnico no elimina un conflicto explícito de modelo.
- Manual con correspondencia vigente y búsqueda sin evidencia: sigue seleccionado y la respuesta dice «No encontré evidencia suficiente en esta búsqueda». No dice que el manual no contenga la respuesta. Volver a elegirlo no produce un pasaje.
- Marca y falla: se proponen manuales y no se seleccionan. No se los presenta como fuente de una solución que no está en un pasaje.
- Manual ya seleccionado y todavía pertinente: la pregunta se busca ahí y no se reinicia la identificación.
- Pregunta por un manual no seleccionado, habiendo otro seleccionado: no se selecciona por el nombre y la búsqueda no sale de los manuales ya elegidos. Se ofrece como candidato.
- Pregunta por una placa o un código, sin la identidad completa del ascensor: no se exige el resto de la placa. Se pide solo el dato que distinguiría el manual.
- Sin imagen, el prompt no trae la frase de la foto ni «La foto muestra».
- Sin pasaje que respalde, o con correspondencia en conflicto, el prompt no encarga medición, función de LED, código o terminal, ni diagnóstico genérico. La presencia de `EXIT_RULE` no basta para dar esta prueba por cumplida.
- Journey A permanece como comparación histórica.

###### Instrucciones que deben alinearse

No se editan en esta tarea. El corte que cambie el guidance cambia estos tres textos a la vez:

- `AGENTS.md`, el párrafo que empieza en «When equipment identity is known and no compatible manufacturer manual was found». La continuación pasa a ser: conservar el caso, decir «No encontré evidencia suficiente en esta búsqueda» cuando no hay pasaje, y pedir un dato que distinguiría un manual o escalar con lo ya verificado. No se asignan funciones de código, LED o terminal ni se recomienda una medición. No se enseña un procedimiento ajeno. No se cierra en un rechazo seco. Un descargo no vuelve aplicable ese procedimiento. Confirmar el manual no crea el pasaje. `known?` no es correspondencia documental.
- `app/services/rag/AGENTS.md`, el punto «Known equipment with no compatible manual continues as Danebo guidance». La misma conducta. El turno puede no imprimir `DATA_NOT_AVAILABLE` al técnico y tampoco sustituirlo por un diagnóstico inventado.
- `app/prompts/AGENTS.md`. «State what is obvious for that kind of component» queda limitado a la seguridad de la acción que el técnico ya está haciendo, no a una función que el pasaje no trae. El procedimiento análogo, con identidad desconocida, puede nombrarse con manual, página y descargo, y ese descargo no autoriza a ejecutar sus pasos en este trabajo. «When no compatible manufacturer manual was found, continue as Danebo guidance» queda alineado con el párrafo de la raíz. Si el manual está seleccionado y esta búsqueda no trajo evidencia, falta el pasaje. Eso no prueba que el manual no tenga la sección.

###### Prueba de identificación, separada de Journey A

Journey A entrega observaciones prefijadas y responde «No lo sé» a la medición. Sirve para memoria y correcciones. No pide ni confirma un manual. No se le agrega un turno para fabricar una aprobación.

La prueba futura, con stubs y sin AWS, recorre en una sesión distinta los caminos de arriba: propone el manual del equipo y no el de una placa sin fila; el botón vigente lo deja seleccionado; la falla se busca en ese manual; una búsqueda sin evidencia conserva la selección y no afirma que el manual no tenga la respuesta; una corrección de modelo deja ese manual seleccionado, fuera de uso, y el botón viejo no escribe; un segundo manual entra solo si una propuesta nueva lo ofrece y el técnico lo agrega. El resultado esperado no se declara cumplido por este documento.

Veredicto de estos ajustes: `ETAPA_2_BLOQUEADA`. No es `EPISODIO_VALIDADO`. No autoriza implementación, otra pasada ni la etapa 3.


## Referencia histórica

Esta parte no es ruta de ejecución. Conserva hechos, cifras y cierres. No se reescriben.

Quedan sin efecto, como instrucciones de la próxima corrida: la luz verde única de las etapas 1, 2 y 3; los 14 turnos de Journey A como duración o meta; el journey sin pin como gate vigente; `RETRIEVAL_EMPTY` como parada de la siguiente corrida; el veredicto de producción de la etapa 3 como paso siguiente. Journey A sigue siendo la prueba histórica de continuidad. El veredicto de su última pasada, `ETAPA_2_BLOQUEADA`, no se convierte en `EPISODIO_VALIDADO`.

### Encabezado anterior, conservado

**Estado: ETAPA 2 BLOQUEADA.** No es `EPISODIO_VALIDADO`. La última evidencia de producción registrada en este plan es la imagen `6ca7788`: web y worker, `https://elevator.danebo.ai/up` en 200, y un POST real. Esa imagen contiene la etapa 1 (`78df58a`), el código de la corrección de planta que llega hasta ella desde `66dd9e0`, la regla de hipótesis y el contrato N4 (`71b83a4`). La corrección de planta no está revalidada. La expansión del nombre canónico quedó fuera de esa imagen. Un turno real no trajo el plano Elemont y no reabre la etapa. `47c43e2` es la base de la reparación de designadores; `700d9d0` la contiene, está en `main` y no forma parte de la imagen evidenciada. La composición por unidades del guidance quedó en `085969c`, en `main`, y tampoco está en esa imagen. La continuidad bajo presión quedó en `8274192`, en `main`, y no está en esa imagen. Al juntar la pregunta larga, la búsqueda vacía y la corrección de 217 caracteres, esa reparación conservaba la corrección y expulsaba el objetivo. Esa pérdida queda reparada en local: no está desplegada y no está revalidada. La pasada local aislada del journey A, sesión 1, sigue `BLOQUEADA`. Los defectos de planta, objetivo residual, identificador «clic», resumen técnico y captura del fallo del intérprete quedan reparados en local y no están revalidados. La clase de la excepción del turno 1 no está en la captura. El cumplimiento del modelo y la búsqueda documental del Elemont siguen pendientes. No es `EPISODIO_VALIDADO`. Faltan 202 filas del catálogo. La validación de producción sigue pendiente. La etapa 3 no empieza. La revisión Opus del 2026-10-07 sobre `7076f05` sigue incorporada. Esta revisión no habilita un piloto.

**Lectura vigente (2026-10-09).** La pasada aislada de ese día terminó los 14 turnos y queda `ETAPA_2_BLOQUEADA`. No es `EPISODIO_VALIDADO`. La auditoría está en «Auditoría de la pasada aislada (2026-10-09)». La única propuesta para revisar es «Ajustes a la propuesta (2026-10-09)», corregida en su lugar. El borrador de cinco pasos queda retirado. Esta revisión no implementa, no llama a AWS y no autoriza otra corrida.

Este documento es el único plan vigente del companion. Una revisión documental no autoriza a empezar. La etapa 1 está en la imagen evidenciada `6ca7788`. Este documento no llama a Bedrock y no despliega.

La revisión de `26a88ab` (2026-10-08) confirma el conteo de intentos y deja incompleto el contrato de corrección. El episodio de la pasada aislada corrió entero en modo de identidad desconocida aunque el técnico nombró Elemont MH. El enfoque que sigue está en «Revisión de 26a88ab y enfoque siguiente». No está implementado en ese commit. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`.

Pregunta rectora: ¿Danebo sostiene un solo episodio técnico completo hasta una conclusión útil?

Ancestro de trabajo: `738b4c6`. Los planes anteriores conservan su historia. Sus encabezados apuntan aquí. Section O del [plan del 6 de octubre](PLAN_FIELD_COMPANION_MVP_CONTINUITY_RECOVERY_2026-10-06.md) queda como regresión secundaria del instrumento A‴. O-P2 a O-P5, F3b y F4 no se reanudan.

La luz verde de este texto autoriza las etapas 1, 2 y 3, en ese orden, dentro del alcance y del presupuesto de abajo. No autoriza el backlog. El backlog se prioriza y se autoriza después, como incremento aparte.

## Alcance inmediato

Un episodio es la consulta técnica en curso, con su equipo, su problema y lo que ya se comprobó. Puede contener incertidumbre, correcciones y comprobaciones que descartan hipótesis. No es un formulario ni un guion rígido.

Dentro de ese episodio Danebo:

- Comprende la consulta natural.
- Reutiliza e identifica lo necesario para buscar. Identificar el equipo temprano puede ser necesario. En una consulta de puertas, identificar el operador puede servir más que completar la identidad del ascensor. Si la sesión, el texto, la foto o la documentación ya traen el dato, se reutiliza. No se exige completar campos antes de buscar.
- Encuentra y utiliza documentación pertinente cuando existe. Un manual recuperado no demuestra por sí solo que aplique a este equipo. Buscar puede ayudar a identificar el equipo.
- Pide únicamente aclaraciones o comprobaciones que permitan avanzar: elegir qué manual consultar, establecer si un manual recuperado aplica, distinguir entre causas posibles, interpretar un resultado o decidir el siguiente paso. Identificar el equipo entra en esa misma regla. No se pide por rutina. No hay una pregunta obligatoria en cada turno.
- Incorpora resultados y correcciones. No repite una pregunta ni una comprobación ya hecha si no cambia el paso.
- Conserva los hechos críticos después del recorte del historial.
- Llega a una respuesta sustentada, una siguiente acción verificable o un escalamiento fundamentado.

No se garantiza que la falla física quede reparada.

Si el primer mensaje ya nombra el equipo y ese equipo coincide con un manual que contiene la respuesta, se busca en ese turno. Sin manual compatible, la respuesta no trae un procedimiento del fabricante. Puede traer orientación general de campo y la seguridad que esa secuencia exige. El dato del manual entra cuando el manual coincide con el equipo y contiene la respuesta. La orientación y las hipótesis de Danebo pueden aparecer, identificadas como tales. No se inventan valores, terminales, códigos ni instrucciones específicas del fabricante.

Un pin de sesión orienta la búsqueda y no prueba aplicabilidad. El sistema no lo suelta en silencio (FC-D17). En el journey de esta validación el pin no se setea.

Quedan fuera de esta ejecución, y no se cierran por quedar fuera: el cambio explícito de caso, el cambio ambiguo, el regreso tras una pausa, el journey B, T-F y la recuperación de un caso anterior. Están en el backlog.

## Referencias industriales

Las páginas siguientes son evidencia publicada, citada por el fundador. Este cambio no las vuelve a descargar. Lo que sigue es el patrón que esas páginas describen, no una auditoría de su implementación. La conclusión de Danebo es una decisión propuesta, no algo que esas páginas ordenen.

- ABB My Measurement Assistant+ / Genix Copilot: [página de servicio](https://new.abb.com/products/measurement-products/service/advanced-services/remote-support-services/my-measurement-assistant). Publica identificación por placa, AutoID y QR, documentación del dispositivo, interpretación de errores, asistencia específica y acceso a expertos. Patrón publicado: identidad accesible, conocimiento pertinente, asistencia fundamentada.
- Siemens Maintenance Copilot / Asset Essentials: [documentación](https://help.assetmanagement.siemens.com/help/Content/Documentation/Maintenance/Asset%20Essentials/EnterpriseFeatures/AI-Driven%20Capabilities/Maintenance%20Copilot.htm). Trabaja sobre una orden asociada a un activo. Usa manuales e historial para diagnóstico, causas posibles y reparaciones, con documento y página. Patrón publicado: activo, problema, antecedentes y documentación.
- Siemens Senseye: [nota de prensa](https://press.siemens.com/global/en/pressrelease/generative-artificial-intelligence-takes-siemens-predictive-maintenance-solution-next). Describe conversación de mantenimiento y contextualización con casos anteriores y sus soluciones.
- Wittur ElevatorSense: [página del producto](https://www.wittur.com/elevatorsenseinfo/). Combina hardware y aplicación para pruebas, análisis de puertas y recomendaciones a partir de resultados. La fuente no demuestra que sea un chatbot RAG. Este plan no lo trata como uno.
- Microsoft Dynamics 365 Contact Center: [Ask a question](https://learn.microsoft.com/en-us/dynamics365/contact-center/use/use-ask-a-question). Describe preguntas libres, seguimientos y cambio de contexto al seleccionar un caso. No demuestra detección automática de episodios dentro de una conversación libre. El cambio de caso que esa página describe no se valida en esta ejecución.

Decisión propuesta para Danebo: esos productos reciben el activo por una orden, un QR o una conexión. Danebo tiene que adquirir o reutilizar ese contexto con lenguaje natural y evidencia. No se copia su arquitectura. IoT, órdenes de trabajo y módulos nuevos no son requisitos del MVP.

## Puertas, como patrón publicado

El troubleshooting del operador LD-16 está publicado por TKE en el [manual de operador](https://shop-us.tkelevator.com/media/download_files/component_manuals/ld_16_door_operator_manual.pdf) y en [esta versión](https://shop-us.tkelevator.com/media/download_files/component_manuals/ld_16_udo.pdf). Documenta, para ese operador: puerta sin movimiento, no abre o no cierra, apertura o cierre parcial, no reabre, fallos por LED, rendimiento reducido y problemas de comunicación entre operador y controlador. Las ramas consideran alimentación, órdenes, fricción, motor o encoder, reapertura, aprendizaje, temperatura, referencia y comunicación.

Eso es el mapa documentado de ese operador. No es un ranking universal de frecuencia ni un procedimiento para cualquier ascensor. No hay un corpus representativo de conversaciones reales. Las frases del journey son ejemplos de aceptación, no transcripciones.

`config/document_identities.yml` no contiene el LD-16. Sí contiene el Elemont MH (`Montacargas 2N Temporizado`) y otros documentos de puerta (E-Shine YS-K01, variador Thyssen MCP7, puertas KES). Esos otros documentos no se enseñan como procedimiento del Elemont. La validación reutiliza el journey A de puertas del Elemont, turnos 1 a 14, sin L3. No se agregan turnos, no se inyectan cuerpos de chunk y no se inventan códigos. Antes de la etapa 2 se comprueba el acceso a la Knowledge Base de producción y que el retrieve devuelve el manual del Elemont MH. Una búsqueda vacía no demuestra que el manual no exista. Si el retrieve no lo devuelve, esa ejecución se detiene en `RETRIEVAL_EMPTY` y no se sustituye por el LD-16.

## Hallazgos confirmados en el código

Ruta de producción, con `HAIKU_QUERY_ANALYSIS_MODE=owner` y los flags de episodio y turno: `RagController#ask` → `ConversationSession#record_owner_turn!` → `Rag::TurnInterpreter` → `Rag::RoutePolicy` → `Rag::WorkContextReducer` → `Rag::QueryComposer` → `SessionContextBuilder` → `RagQueryConcern#execute_rag_query` → `QueryOrchestratorService` → `BedrockRagService`.

El intérprete usa `BedrockClient#converse`. `converse_message` es otro cliente. El harness longitudinal (`script/field_companion/longitudinal_journeys.rb`) niega `converse_message` y no niega `#converse`. `Runner#run` no es una sonda: ejecuta los journeys con percepción escrita en el fixture, KB `mvp-journey-stub` y un chunk congelado. Un PASS de ese harness demuestra que el estado se actualiza cuando la percepción ya viene escrita. No demuestra que Haiku comprenda la frase.

Límites de sesión, en `ConversationSession`: `MAX_HISTORY = 20` mensajes de usuario y asistente; `EPISODE_MAX_USER_MESSAGES = 3`; `EPISODE_WINDOW = 4.hours`. No son un máximo de consultas. Cada append guarda `last(MAX_HISTORY - 1)` más el mensaje nuevo, así que el historial almacenado no pasa de 20. El mensaje 21 empieza a descartar los anteriores. Con respuesta del asistente en cada turno, eso ocurre en el turno 11 del journey A. El episodio vive en `active_episode` y no se borra por ese recorte. `EPISODE_MAX_USER_MESSAGES` limita cuántos mensajes de usuario del historial leen algunos lectores. No es el almacén del episodio. El último mensaje del asistente que entra al prompt se corta a 200 caracteres.

Observaciones:

- `QueryComposer#observations` las mete en la cadena de retrieval.
- `SessionContextBuilder#render_field_problem` no las recorre. Arma hechos, identificadores, foto, conflictos y objetivo.
- `MAX_PROBLEM_CHARS = 400`. El encabezado mide 79 caracteres y el pie 188. Con los dos saltos de línea ocupan 269. `fit_problem` acorta primero el objetivo y después descarta líneas. Encabezado y pie se conservan.
- El guidance de identidad conocida (`CompanionGuidanceContext#turn_block`) lee objetivo, identidad y las dos últimas líneas `User:` (`TURN_CHARS = 160`, `MAX_TURNS = 2`). No lee el resto del bloque de problema.
- El guidance de identidad desconocida lee `problem_projection_lines`. Con cero chunks, después del segundo retrieve que ya hace `retry_open`, `BedrockRagService#open_reference_no_results` responde el texto fijo «No se encontró información…» (o el aviso de pin vacío) y no arma guidance ni llama a generación. El técnico recibe una negativa documental sin aclaración ni orientación, lo que contradice la regla de AGENTS.md de no detenerse en una negativa de búsqueda. Reparar solo el builder no alcanza si el guidance no usa esas líneas, ni si la ruta de cero chunks no tiene prompt.

Pregunta de controlador:

- `RoutePolicy#ask_controller?` arma `search_and_clarify` cuando hay fabricante, no hay modelo ni controlador, y hay síntoma.
- `ask_when: :always`. `RagQueryConcern#append_turn_clarification` agrega «¿Qué controlador o modelo estás revisando?» aunque la búsqueda ya pueda hacerse.
- `clarify_first?` no busca y no escribe observaciones. Devuelve falso si la percepción ya trae observaciones, hechos o un identificador afirmado. El síntoma se pierde por `unclear`, por fallback o porque el intérprete no extrajo observaciones.
- El fallback de un episodio vacío y sin foco también pregunta el controlador antes de buscar.
- En el catálogo, `MH` es designador del Elemont y `CEA15+` es el designador del manual CEA15, no el token `CEA15`. Un designador que no queda como hecho `model` o `controller` no cancela `ask_controller?`.

Guidance:

- `ADVANCE_FAULT` dice «Equipment identity is not the current objective» cuando el turno no pide identificar el equipo.
- Si ese objetivo está activo y no hay estado reportado, `TASK_LEAD` pide una comprobación pasiva de una lista fija: ocupación, posición de cabina, estado de puertas, display o sonido.
- `RESOLVE_IDENTITY` pide leer la placa. `nameplate_rule` en el otro caso dice que la identidad desconocida limita las afirmaciones del fabricante y no debe ser la pregunta principal.
- `RESOLVE_IDENTITY` solo se activa con una petición explícita del técnico (`explicit_identification_request` o `explicit_identity_confirmation_request`). No hay otra base para que la identidad sea el objetivo del turno, aunque la documentación la necesite.
- Esas frases pueden sesgar el turno hacia una pregunta que la consulta no necesita, o impedir la que sí necesita. La reparación no consiste en preguntar siempre la identidad. Depende de la consulta, del contexto y de si la documentación ya se distingue.

Correcciones, en dos capas distintas:

- Identidad o código: el prompt del intérprete dice «A correction has empty observations» y exige un span negado y uno afirmado para fabricante, modelo o controlador. `TurnPerception#adjust_move` convierte `correct` sin negación de slot en `unclear`, vacía identidades y vacía observaciones. El reducer adopta un código de reemplazo solo cuando el movimiento ya es `correct` y el slot negado es `fault_code`.
- Observación («planta 1», «por arriba», «ya revisé eso»): no es un slot. Si el modelo emite `correct` sin negación de slot, `adjust_move` borra la observación antes de que el reducer escriba. El prompt empuja al modelo a dejar esas observaciones vacías. La capa responsable de esa pérdida es el intérprete y `adjust_move`, no el reducer. `QueryComposer#current_turn` solo recorta spans negados; el turno literal puede conservar «no de planta 1». Una línea `User:` anterior puede conservar un valor ya descartado. Eso es un hallazgo aparte: falla si la respuesta publicada lo trata como vigente.

Continuidad, ya en código y no reabierta por este plan:

- `new_work` evalúa la política sobre un `ActiveEpisode` vacío y abre otro con `ActiveEpisode.open`. El episodio nuevo no hereda identidad, síntomas, foto ni resultados del anterior.
- `case_boundary_changes` limpia `current_procedure` y deja `pin_release_reason` en nil. El pin de sesión permanece. Persistirlo no prueba que aplique al caso nuevo.
- El escritor tardío se rechaza con `expected_episode_id`.
- No hay almacén de episodios anteriores ni una operación de la ruta owner que reabra un caso cerrado. `voice_dictation` reabre otra cosa y no cuenta como recuperación de episodio. Recuperar un caso anterior no está implementado.

Esos cuatro puntos se conservan. Esta validación no los amplía y no los prueba con una llamada de pago. Las pruebas locales de separación siguen obligatorias en la etapa 1. Su comprobación de conversación real está en el backlog.

Retrieval vacío no demuestra que el manual no exista. Una respuesta útil sin documentación compatible no es éxito documental. A‴ no recorre esta ruta: en Section N quedó useful 28/68, S3 4/44 y unsafe humano confirmado 0. Esos números se conservan. No son la puerta de esta validación.

## Recomendaciones que no se copian

- Conservar solo la observación más reciente. Borraría «ya revisé eso y está bien». La reparación mínima conserva comprobaciones y correcciones que cambian el paso siguiente, dentro del presupuesto del bloque de problema.
- Una sonda completa sin retrieval ni generación, y repetirla, como requisito general. Un defecto visible en el código se reproduce con un test local. No se paga una llamada para confirmar que existe. Esta validación no añade una fase previa de medición pagada.
- Preguntar la identidad en todos los turnos para corregir el sesgo contrario. La identidad se pide cuando la consulta, la evidencia documental o el diagnóstico lo necesitan.
- Tratar el LD-16 como corpus de prueba o como chatbot de referencia. No está en el catálogo local y la página de Wittur no demuestra un RAG.
- Declarar implementada la recuperación de un caso anterior.
- Cerrar O-P1 porque no hay archivos en git, o cerrarlo porque el fundador informó que terminó. Las dos afirmaciones conviven hasta que haya un artefacto.
- Reanudar O-P2 a O-P5, agregar scorer, benchmark grande, ramas por fixture o una llamada de producto extra.
- Una tabla, varios episodios activos, un archivo de casos o una llamada LLM nueva para dejar preparado el backlog.
- Meter L3, el journey B, T-F, el cambio ambiguo o la pausa dentro del gate o del presupuesto de este plan.
- Alargar el journey A para cumplir un número de mensajes.
- Declarar habilitado un piloto de consultas libres al cerrar un solo episodio.
- Reutilizar el techo anterior de 360 llamadas y US$5, calculado para tres escenarios.

## Inventario

Los pendientes históricos siguen en esta tabla. No son los seis escenarios del backlog y no se cierran porque esta validación no los ejecute.

| Gap | Decisión |
|---|---|
| Discovery F0–F8, visual F1–F3, R1A, harness scripted scope.1 | Resuelto con evidencia en sus planes. |
| Observaciones fuera del prompt de generación y presupuesto de 400 que prioriza encabezado y pie | Necesario. Etapa 1. |
| Cero chunks con identidad desconocida: texto fijo, sin guidance ni aclaración | Necesario. Etapa 1, con tests locales. El journey A no recorre esa ruta si la identidad Elemont queda conocida. |
| `ask_controller?` con `ask_when: :always` y fallback que pregunta antes de buscar | Necesario. Etapa 1. |
| `TASK_LEAD` y el objetivo de identidad como sesgo de pregunta; identidad como objetivo solo por petición explícita | Necesario, acotado. Etapa 1 cambia la instrucción; no invierte el sesgo. |
| Corrección de observación destruida por el prompt y `adjust_move` | Necesario. Etapa 1. La calidad del intérprete real, para la planta del journey A, se ve en la etapa 2. |
| Corrección de identidad o código (8→18, Fuji Yida→KONE) | Parcial. El reducer ya adopta el código cuando el movimiento es `correct`. La etapa 2 comprueba 8→18 con el intérprete real. Fuji Yida→KONE es T-F y queda en el backlog. Las pruebas locales de las dos se conservan. |
| Hechos del episodio que sobreviven al recorte de 20 mensajes | Parcial. El JSON del episodio sobrevive; el prompt no. La etapa 1 proyecta lo necesario. La etapa 2 cruza el recorte en el journey A, sin L3. |
| Episodio nuevo sin heredar el caso anterior; pin de sesión que no prueba aplicabilidad | Parcial, ya en código. Las pruebas locales de separación se conservan. La comprobación pagada con L3 sale de este gate y queda en el backlog. No se cierra. |
| Recuperar un caso anterior dentro de la sesión | No implementado. Backlog, para evaluar necesidad y solución mínima. No se declara implementado. |
| R2 del 30 de septiembre (consulta KONE sobre un episodio Elemont vivo, pin MonoSpace, código 515) | Absorbido como mapa. Sigue pospuesto. No es un ítem del backlog de escenarios y no se cierra. |
| Hilo de consulta en la ruta web owner | Sustituido por `QueryComposer`. |
| F9, soltar el pin | Retirado de esta cola. Contradice FC-D17. |
| T3, R3, CG-D19, CS-P01 a CS-P03 | Retirados de esta validación. CG-D19 solo vuelve si la etapa 2 o la 3 muestra una respuesta inutilizable por el formato. |
| Smoke de producción R1B, verificación de producción N1–N6, G5 de foco, presentación | Pospuestos. No se cierran por quedar fuera. El smoke de la etapa 3 es el del episodio de puertas, no esos pendientes. |
| O-P1 | Incierto. Ver abajo. |
| Si Haiku extrae movimiento, observaciones y la corrección de código del journey A; si el índice devuelve el Elemont MH; si cero chunks es índice frío o manual ausente | Incierto hasta la etapa 2, y solo para ese journey. Journey B, T-F y el cambio de caso no quedan resueltos ahí. No se confirma con una sonda previa. |

## O-P1

El fundador informó que O-P1 terminó. En el repositorio, incluido el árbol de trabajo, no están `architecture_faithful_s3.yml`, `architecture_faithful_s3.rb` ni `architecture_faithful_score.rb`. La ausencia en un commit no descarta una ejecución local fuera de este árbol. El informe tampoco deja un artefacto visible aquí. O-P1 queda incierto. No se reanuda y no se da por cerrado. O-P2 a O-P5 no se reanudan.

De Section O se conserva, como regresión secundaria y sin volver a ejecutarla: A‴ no recorre el ciclo de vida; el pin no prueba aplicabilidad; `clarify_first` no busca ni guarda observaciones; no se inventan cuerpos de manual; los SHA y conteos históricos permanecen.

## Arquitectura que se conserva

Se mantienen, sin ampliarlos para el backlog:

- `episode_id` del episodio vigente.
- El estado del episodio en `active_episode`, separado del historial que se recorta.
- `new_work`, que abre otro episodio sin heredar identidad, síntomas, foto ni resultados.
- La aclaración de relación entre casos cuando el cambio no es claro.
- El rechazo del escritor tardío con `expected_episode_id`.

No se agregan tablas, varios episodios activos, un archivo de casos ni una llamada LLM para dejar eso preparado. Abrir un caso nuevo ya está soportado. Recuperar uno anterior no lo está.

## Continuidad dentro del episodio

Después del recorte tienen que seguir disponibles para la respuesta: equipo vigente, problema, observaciones que cambian el paso, comprobaciones y resultados, correcciones, desconocimientos confirmados y pregunta pendiente.

En el journey A eso es, como mínimo: Elemont, MH, CEA15, la puerta 1 que no termina de cerrar, el imán que no magnetiza, el código 18 y no el 8, la planta 2 y no la planta 1, la guía de la puerta sin obstrucción, el LED 7 apagado, el clic al pedir cierre y que no había personas dentro. El historial ya no tiene por qué conservar los primeros mensajes. El episodio y el prompt de la conclusión sí.

## Tres etapas

Ninguna etapa empieza con este documento. Hace falta la luz verde final del fundador sobre este texto. Esa luz verde autoriza ejecutar las etapas 1, 2 y 3 en orden, sin una frase nueva por etapa, dentro del alcance y del presupuesto escritos aquí. Incluye desplegar los commits de las etapas 1 y 2 con el procedimiento vigente antes de la etapa 3. Una etapa empieza solo si la anterior cumplió su resultado. El backlog no entra en esa autorización.

La ejecución se detiene y vuelve al fundador ante cualquiera de estas condiciones: una condición de parada de la etapa en curso; la aceptación de la etapa 2 no se cumple después de las repeticiones permitidas; se alcanza el presupuesto global; el despliegue falla o pide migración, variable de entorno nueva o cambio de infraestructura; una respuesta inventa un valor, terminal, código o procedimiento de fabricante.

No se promete éxito después de un número fijo de reparaciones. Cada etapa se detiene cuando se cumple su resultado o su condición de parada.

### Presupuesto

El techo anterior de 360 llamadas y US$5 cubría journey A con L3, journey B y T-F. No se reutiliza.

Este presupuesto es el journey A local y una verificación de ese mismo episodio en producción. La etapa 1 no lo consume.

Precio en `BedrockQuery::BEDROCK_PRICING` para `global.anthropic.claude-haiku-4-5-20251001-v1:0`: US$0,001 por 1K tokens de entrada y US$0,005 por 1K de salida. Supuesto por llamada, heredado del texto anterior y no reestimado con una sonda: intérprete, 3K de entrada y 0,3K de salida, US$0,0045; generación, publicación o guidance, 8K de entrada y 0,7K de salida, US$0,0115.

Llamadas de modelo por turno, en el peor caso de este escenario:

- Una del intérprete (`BedrockClient#converse`).
- Una de generación si la identidad queda conocida: un `Retrieve` y después `document_identity_generator.query`.
- Hasta dos de publicación o guidance si el turno cae en identidad desconocida. `UnknownIdentityPublication` cuenta, y si no acepta también cuenta el guidance del mismo intento.
- El segundo intento del bucle `retry_open` no entra: exige un pin, y este journey no lo setea.
- `AuroraColdStartRetry` puede repetir el `Retrieve` hasta tres veces, con esperas de 15, 30 y 45 segundos, si el error es el auto-pause de Aurora. Esas repeticiones no crean fila `BedrockQuery` y no suman al techo de llamadas.

El journey A tiene 14 turnos. Una pasada, en ese peor caso: 14 intérpretes y 28 llamadas de generación, publicación o guidance. Total: 42 llamadas de modelo. Costo estimado de la pasada: 14 × 0,0045 + 28 × 0,0115 = US$0,385.

La etapa 2 admite como máximo dos repeticiones. Cada una repite solo los turnos de la falla observada. El techo reserva dos pasadas completas por si la falla es el episodio entero: 126 llamadas. La etapa 3 es una pasada, sin reparación en caliente: 42 llamadas.

Techo global de las etapas 2 y 3, reintentos de publicación y guidance incluidos: 168 llamadas de modelo. Costo estimado de ese techo: US$1,54. Tope de costo: US$2,50.

Supuestos del margen. No se conocen los tokens reales con el prompt reparado. Si `MAX_PROBLEM_CHARS` sube a 600, son unos 50 tokens más por generación: alrededor de US$0,006 en las 112 generaciones del techo. El costo de `Retrieve` y del embedding de la consulta no está en `bedrock_queries`. El tope cubre ese desconocido y no es una factura. Referencia histórica: US$0,0073 por consulta respondida, medido el 6 de agosto con otros prompts. Cuatro pasadas de 14 consultas a esa tarifa serían unos US$0,41. No sustituye el peor caso de dos generaciones por turno.

El conteo y el costo se leen de las filas `BedrockQuery` del periodo de ejecución. El cierre los reconcilia con `bedrock_daily_costs` cuando esa rollup esté disponible.

### 1. Reparar los gaps confirmados del episodio

Reproducciones locales y tests Minitest. Sin Bedrock. Sin fase previa de medición pagada.

- Proyectar en el prompt final, de las dos rutas de guidance, el problema, las observaciones, las correcciones y las comprobaciones que cambian el paso. Un test lee `turn_block` y el bloque de identidad desconocida, no solo `SessionContextBuilder`.
- Contexto compacto. Primero compactar encabezado, pie y redacción de líneas. Si con eso no caben, en el estado del journey A al turno 14, el equipo, el problema, la corrección vigente y las comprobaciones que cambian el paso, se permite subir `MAX_PROBLEM_CHARS` hasta 600, con un test que mida el bloque. Doscientos caracteres más son unos 50 tokens por llamada. No se sacrifica una comprobación o una corrección para cumplir el número. No quedarse solo con la observación más reciente.
- Continuidad útil con retrieval vacío. Cero chunks con identidad desconocida: en lugar del texto fijo, usar el mismo guidance de identidad desconocida que ya existe para la ruta con chunks, con cero manuales y las líneas del problema. La respuesta dice que la búsqueda no devolvió documentación (no que el manual no exista) y ofrece una aclaración que permita una búsqueda mejor o una orientación general de Danebo identificada como tal, sin procedimiento, valores ni terminales de fabricante. Con pin, conserva el aviso de que el foco no devolvió evidencia y no suelta el pin (FC-D17). Es una generación en una ruta que hoy no genera. La ruta de cero chunks reutiliza el resultado de los intentos de retrieval existentes, sin agregar búsquedas adicionales. Si la generación falla, se conserva el mensaje actual de reintento. Un test cubre la ruta con y sin pin.
- Preguntas rutinarias. No agregar la pregunta de controlador cuando el turno ya trae síntoma y un token de equipo (fabricante, modelo, controlador o identificador) y la búsqueda puede seguir. Conservar la aclaración cuando distingue documentos o permite avanzar. El fallback de un episodio vacío no pregunta el controlador antes de poder buscar el síntoma.
- Sesgos del guidance. Quitar el menú fijo de ocupación, posición, puertas, display y sonido cuando la consulta ya trae síntoma o una pregunta que se puede buscar. La comprobación que se pida debe distinguir causas, interpretar un resultado o decidir el siguiente paso de esta consulta. No sustituir el menú por «pregunta siempre la identidad». Identidad como objetivo del turno: además de la petición explícita, cuando una señal determinista ya presente en el turno muestra que la identidad decide la documentación o la aplicabilidad. Ejemplos: manuales recuperados o retenidos de equipos distintos, un manual cuya aplicabilidad depende del modelo, o un código cuyo significado depende del equipo. `ADVANCE_FAULT` deja de afirmar que la identidad no es el objetivo; dice que no se pregunta por rutina. Sin llamada nueva.
- Correcciones de observaciones. Distinguir en el prompt y en `adjust_move` la corrección de identidad o código de la corrección de una observación. La segunda no se convierte en `unclear` ni se vacía.

Siguen siendo parte de esta etapa, y tienen que pasar, las pruebas locales ya existentes de corrección de identidad, de corrección de código y de separación de episodio (`new_work`, `expected_episode_id`). Acotar la aceptación no autoriza borrarlas, saltarlas ni debilitarlas. No se vuelven a pagar contra Bedrock.

Resultado: los tests de las reparaciones y esas pruebas locales pasan. No hay llamada de modelo.

Parada: si la reparación exige una llamada adicional en un turno que ya genera, una tabla nueva o subir `MAX_PROBLEM_CHARS` por encima de 600, se detiene y vuelve al plan. La generación de la ruta de cero chunks, que hoy no genera, es la excepción ya escrita arriba.

#### Cierre local (2026-10-07)

Base `78df58a`, rama `main`, árbol limpio al empezar. Sin llamadas a Bedrock, sin journeys reales y sin despliegue. Veredicto de esta etapa: `ETAPA_1_COMPLETADA`. No declara `EPISODIO_VALIDADO`.

El bloque del estado del journey A en el turno 14 mide 585 caracteres, por encima de 400 y dentro de 600. Con el pie anterior el mismo estado quedaba en 603 y `fit_problem` recortaba el final del problema. El pie quedó en «Ignore for other equipment.» y el objetivo completo cabe, junto con Elemont, MH, CEA15, el código 18, la corrección del código 8 y las comprobaciones que cambian el paso. El código 8 y la planta 1 no salen como hechos vigentes. La puerta y el imán siguen en la línea de objetivo; no se duplican en observaciones.

Las seis reparaciones quedaron en las rutas que ya existían:

- `SessionContextBuilder` proyecta observaciones y correcciones. Las dos rutas de guidance leen ese bloque en el prompt final.
- `MAX_PROBLEM_CHARS` pasó a 600. El encabezado, el pie y la línea de identificadores se acortaron antes.
- Cero chunks e identidad desconocida generan una vez con el guidance existente, sin otro `Retrieve`. La respuesta antepone el aviso de búsqueda vacía. Con pin forzado, un solo retrieve conserva el aviso de foco vacío. Si la generación sale vacía o es el rechazo de Bedrock, queda el texto de reintento.
- `RoutePolicy` ya no pregunta el controlador por rutina cuando hay síntoma y un token de equipo. El designador ambiguo y la mención dentro del foco siguen aclarando. El fallback de un episodio vacío busca el síntoma; un saludo sigue aclarando.
- El menú fijo salió de `TASK_LEAD`. `ADVANCE_FAULT` dice que la identidad no se pregunta por rutina. Pasa a objetivo con una duda explícita de aplicabilidad o con un código cuyo significado se pregunta. Dos títulos no se leen como equipos distintos. Un procedimiento, un reset o un valor siguen en `advance_fault`.
- Una corrección de observación permanece `correct` y conserva la frase de reemplazo. Una corrección de fabricante, modelo, controlador o código sin la negación ranurada sigue yéndose a `unclear`.

Evidencia local, con dependencias externas stubbeadas: `session_context_builder_test`, `companion_guidance_context_test`, `route_policy_test`, `turn_perception_test` y `work_context_reducer_test`, 106 pruebas, 943 aserciones. `bedrock_rag_service_test` y `document_identity_scope_test`, 177 pruebas, 1399 aserciones, 6 skips previos. `conversation_session_turn_interpreter_test` junto con `turn_perception_test`, incluidas las de `new_work`, `expected_episode_id`, NICE3000 a NICE1000 y el código 8 a 18. Cero fallos en esas corridas.

Corrección de revisión, sobre `e62a4ab`. `stale_observation?` ya no descarta una observación por compartir el número rechazado. «El display muestra código 8» deja de salir como vigente cuando el código pasa a 18. «El LED 8 está apagado», «la puerta 8 no cierra» y «detenida en planta 8» se conservan. Un identificador numérico tampoco arrastra esas frases. `distinct_retrieved_manuals?` salió: dos manuales del mismo equipo, o dos títulos sin datos de equipo, no piden la placa. Siguen la duda explícita de aplicabilidad y el código cuyo significado depende del equipo. Evidencia de esta corrección: `session_context_builder_test`, `companion_guidance_context_test`, `turn_perception_test`, `work_context_reducer_test` y `conversation_session_turn_interpreter_test`, 136 pruebas, 1199 aserciones, cero fallos y cero skips. Incluyen el journey A, la corrección de código, `new_work` y `expected_episode_id`. Sin Bedrock y sin despliegue. El veredicto de la etapa sigue siendo local: no es `EPISODIO_VALIDADO`.

Pendiente para la etapa 2: el journey A con el intérprete real, ejecutado como se describe abajo. Esta etapa no demuestra que el retrieve devuelva el manual del Elemont ni que la conclusión use un chunk compatible. `TechnicalUnderstanding` no es la ruta owner y no se tocó. La planta 1 no es un slot rechazado: el reducer la saca de las observaciones cuando el turno dice «no de», y el prompt muestra la observación de reemplazo. La preparación y la ejecución real de la etapa 2 siguen pendientes en este cierre de la etapa 1. El resultado está en el cierre de la etapa 2.

Condición para iniciar la etapa 2: revisión de este diff. El presupuesto y las paradas de la etapa 2 no cambian. No se empieza la etapa 2 ni la 3 desde este cierre.

### 2. Validar un episodio real

La etapa 2 ejecuta el código de Rails local contra la Knowledge Base real de producción mediante Bedrock. Requiere configurar credenciales AWS autorizadas, región y Knowledge Base, y disponer en la base Rails local de registros documentales y de cuenta coherentes con el corpus remoto para aplicar las políticas existentes. Sesiones, mensajes y trazas se guardan localmente. No requiere desplegar ni escribir en la base Rails de producción.

AWS CLI Retrieve puede comprobar acceso y retrieval, pero no sustituye Journey A. Una búsqueda vacía no demuestra que el manual no exista. Se distinguen la falta de acceso o de configuración, los registros locales ausentes o incompatibles, y una búsqueda sin resultados. No se copian secretos al repositorio ni se muestran en la entrega. El cierre de esta etapa está más abajo.

Journey A de puertas, turnos 1 a 14, sin L3. Intérprete, sesión, retrieval y generación, con el código Rails local y la Knowledge Base de producción. No se crea otro corpus.

El manual del Elemont MH tiene que devolverse en el retrieve antes de empezar. Si la búsqueda, con acceso y registros locales coherentes, no lo devuelve, parada en `RETRIEVAL_EMPTY`. No se sustituye por el LD-16 y no se aprueba el episodio con orientación general.

Los textos del técnico son los del fixture. Los hechos de cada turno son fijos: código 8 y después 18, planta 1 y después 2, la guía sin obstrucción, el LED 7 apagado y el clic al pedir cierre. La redacción se adapta a la respuesta real anterior cuando el texto presupone algo que Danebo no dijo. A3 responde a una pregunta sobre ocupación o posición. A11 dice «esa revisión». Si Danebo no lo preguntó o no lo mostró, el turno entrega el mismo hecho como dato espontáneo, o se refiere a la comprobación que Danebo sí mostró. Si Danebo pregunta algo que el caso responde, el técnico responde con el hecho del fixture. Si el caso no lo sabe, responde «no lo sé». La traza guarda el texto original y el enviado. Un turno adaptado no es un turno nuevo ni otro escenario.

Catorce intercambios con respuesta del asistente son 28 mensajes. El recorte empieza en el turno 11. La corrección de planta (turno 13) y la conclusión (turno 14) quedan después. No se agregan turnos para llegar a 20. El turno 12, «Sigue igual», ya está entre el recorte y la corrección de planta y se mantiene. Si en una corrida Danebo ya cerró y los turnos que faltan no traen un hecho nuevo, no se redactan turnos adicionales. En este fixture la corrección de código, la comprobación de la guía y la corrección de planta son hechos nuevos y se entregan antes de cerrar. Si una corrida se cerrara antes del turno 11 sin esos hechos, no habría demostrado el recorte: se anota y no se alarga.

Límite del fixture, y ajuste mínimo ya hecho en este texto: `longitudinal_journeys.yml` no define el significado del código 18, del LED 7, de las plantas, de la guía ni del clic, y no trae un diagnóstico esperado del fabricante. No se inventa ese diagnóstico ni se abre otro corpus. El punto de conclusión es el turno 14, «¿Y ahora?», con los hechos vigentes después del recorte. La utilidad se juzga por las tres salidas, no por coincidir con una causa guionada.

Cada turno anota la decisión, si buscó, si el chunk es compatible con el equipo, si la respuesta usa ese chunk o se declara orientación de Danebo, y si conserva o descarta lo ya comprobado. `RETRIEVAL_EMPTY` no se anota como «el manual no existe». Una respuesta general sin documento compatible no se anota como éxito documental.

Se repara solo la falla observada y se repite solo lo necesario. Como máximo dos repeticiones, siempre dentro del presupuesto de la etapa. Una repetición no es un pretexto para completar un cupo ni para agregar turnos.

Parada: error de transporte en el primer turno; el retrieve, con acceso y registros locales coherentes, no devuelve el manual del Elemont; la misma falla vuelve después de una reparación; la reparación pide una tabla, un segundo modelo, L3 u otro escenario; se agota el presupuesto de la etapa.

Aceptación:

- En el primer turno se busca sin pedir fabricante, modelo ni controlador.
- Utilidad y avance, en el turno 14: una respuesta sustentada, una siguiente acción verificable o un escalamiento fundamentado. La respuesta usa lo ya comprobado. No repite una comprobación descartada ni trata como vigente el código 8 o la planta 1. No se exige que la puerta quede reparada.
- Memoria: después del recorte siguen el equipo, el problema, las correcciones y las comprobaciones relevantes nombradas arriba.
- Documentación: si el retrieve devuelve un chunk compatible, la conclusión lo usa y cita documento y página. Si no lo devuelve, la respuesta no inventa valores, terminales, códigos ni un procedimiento de fabricante. Eso no es éxito documental. Con el manual recuperable en la Knowledge Base de producción, un episodio que nunca usa documentación compatible no llega a `EPISODIO_VALIDADO`.
- Una pregunta repetida, un valor ya corregido tratado como vigente o una pregunta de identidad sin función documental ni diagnóstica es fallo. Timeout, throttle o error de transporte es inconcluso, no un fallback de producto.

#### Cierre (2026-10-07)

Base `322ea00`, rama `main`. Rails local, base `smart_deal_development` en localhost, Knowledge Base `Y7RZWMFJSR`, región `us-east-1`. El `.env` apunta al índice de desarrollo; el proceso exportó el id de producción y dejó la sesión compartida apagada. Las credentials cifradas no tienen access key y su id de índice no es el de producción. Las access keys del `.env` sí llamaron a `Y7RZWMFJSR`. No se escribió la base Rails de producción y no se desplegó.

La cuenta local `danebo-legacy` es el id 4. Los chunks del índice están en `account_id` 1. Con el filtro de la cuenta 4 el retrieve devolvió cero. Se creó en local la cuenta id 1 (`index-account-1`), un usuario local y la fila `KbDocument` del Elemont (`dcc8e046-037d-48a6-8913-1992aed28507`, clave del PDF `Montacargas 2N`). La base local no tenía la columna `document_focus` que el código ya espera; se aplicó solo ahí la migración `20261001160000`. Con la cuenta 1, una búsqueda sin generación devolvió el manual Elemont MH, páginas 1 y 7, junto con un manual Crown. El manual es recuperable. Una búsqueda del síntoma no lo devuelve: el ranking trae `manual-cea15p`, VF5 y Monarch.

Tres pasadas del journey A, turnos 1 a 14, sin pin y sin L3. Intérprete, retrieve y generación reales. Sesiones locales 193, 194 y 195. Trazas en `tmp/stage2_journey_a/`, fuera del repositorio.

| Pasada | Llamadas | Costo `BedrockQuery` | Qué mostró |
|---|---:|---:|---|
| 1 | 25 | US$0,052129 | Buscó en el turno 1. El código 18 y la planta 2 se preguntaron como dato a corregir y no se guardaron. El turno 12 trató el código 8 y la planta 1 como vigentes. Los síntomas ocuparon los cinco identificadores y Elemont salió del prompt. |
| 2 | 27 | US$0,054390 | El estado guardó el código 18, rechazó el 8, reemplazó la planta y conservó Elemont, MH y CEA15 después del recorte. La conclusión dijo que el código había pasado de 18 a 8. La línea `Corrected: fault code 8` se leía como el valor nuevo. |
| 3 | 28 | US$0,055043 | La conclusión ya no invierte el código ni declara la planta 1. Sigue pidiendo de dónde sale el clic. El bloque del turno 14, al pasar de 600 caracteres, soltó el objetivo, el código 18 y los identificadores, y conservó las observaciones. |

Total de llamadas de modelo: 80, de las 126 de esta etapa. Costo atribuido en `BedrockQuery`: US$0,161562. 42 filas son el intérprete (`semantic_analysis`) y 38 son generación (`query`). `Retrieve` y el embedding de la consulta no están en esa tabla. El tope de US$2,50 no se acercó. No hay rollup de `bedrock_daily_costs` de esta corrida. La etapa 3 no se ejecutó.

Aceptación de la pasada 3:

- Primer turno: buscó, sin pedir fabricante, modelo ni controlador. Dijo que la identidad no está confirmada y pidió mirar el imán.
- Memoria: el episodio conserva Elemont, MH, CEA15, el código 18, la planta 2, la guía sin obstrucción, el LED 7, el clic y que no había personas. El prompt de la conclusión no: `fit_problem` suelta primero identificadores y hechos, y la lista de observaciones ya no cabía con ellos.
- Código 8: queda rechazado. La respuesta del turno 14 no lo trata como vigente. El turno 7 vuelve a pedir la placa aunque el turno 1 ya dijo Elemont MH y CEA15.
- Planta 1: sale de las observaciones en el turno 13. El turno 10, anterior a esa corrección, todavía la nombra.
- Conclusión: no cita el manual del Elemont. Pide otra vez de dónde viene el clic, comprobación ya entregada. No declara la puerta reparada y no inventa un terminal ni un valor de fabricante. Tampoco es una respuesta sustentada en documentación compatible.
- Documentación: ninguna de las 14 búsquedas del episodio devolvió el Elemont MH. Devolvieron CEA15P, VF5 y Monarch. Eso no se anotó como éxito documental ni como ausencia del manual.

Reparaciones, con test local antes de repetir. No se hizo una tercera. La misma comprobación del clic volvió después de la segunda.

- Una corrección que ya nombra el código viejo y el nuevo, o una observación con «corrijo» y «no de», deja de convertirse en `correction_target`.
- Una frase de síntoma no ocupa un cupo de identificador. Un código rechazado sale también de esa lista.
- La línea del valor rechazado dice `Not current:`, no `Corrected:`.

Veredicto de la etapa: `BLOQUEADA`. No es `EPISODIO_VALIDADO`. La etapa 3 no empieza.

#### Reparaciones locales posteriores (2026-10-07)

Sobre `9dbc655`. Sin Bedrock, sin Retrieve, sin otra pasada y sin despliegue. La etapa 2 sigue `BLOQUEADA`. Estas reparaciones no reinician el presupuesto ni autorizan otra corrida. Veredicto de este diff: `REPARACIONES_LOCALES_COMPLETADAS`. No es `EPISODIO_VALIDADO`.

La medición de 601 caracteres del turno 12 y del 14 era el bloque de 599 más los dos saltos de línea que lo separan de `## Recent Conversation`. Esos dos caracteres no entran en `MAX_PROBLEM_CHARS`. El límite sigue en 600.

Con el estado guardado de la sesión 195, turnos 12 y 14, el bloque reserva el objetivo, Elemont MH, CEA15, el código 18 y `Not current: fault code 8`. Una observación cubierta por el objetivo sale del bloque solo si ese objetivo se imprime. Los ecos exactos y «Sigue igual» no ocupan cupo. El mismo bloque entra en `text_prompt_template` de `build_complete_optimized_config`, que es el prompt de la ruta `rag_global`. No se subió el límite y no se escribieron Elemont, CEA15 ni los hechos del fixture en las reglas de producto.

Una corrección de código ya no vacía el resto del turno. La instrucción del intérprete deja de pedir observaciones vacías y `recover_stated_correction` combina. «Era código 18, no 8. La guía no tiene obstrucción» guarda 18, rechaza 8 y conserva la guía. El rechazo es por slot: LED 8, puerta 8 y planta 8 siguen. El mensaje del técnico no se reescribe. La consulta no deja «no .» ni vuelve a poner el código 8 como vigente. La redundancia entre el turno, el objetivo y las observaciones se quita sin soltar la identidad ni el código cuando la lista llena el tope.

`append_observation!` no guarda una copia normalizada ni un eco de continuidad. No une dos frases por compartir tokens: «no cierra» y «cierra», o el clic con «pero», siguen siendo comprobaciones distintas. Un «Sigue igual» no borra el objetivo ni las comprobaciones. Al llegar al tope de 12, la observación contenida en el objetivo no es la que sale.

El armado de mensajes del journey A ya no antepone un hecho de otro turno. Si la pregunta pide el origen del clic, el significado de un código o de un LED, o un terminal, y el fixture no lo trae, la respuesta añadida es «No lo sé.». No se inventa ese origen. Una comprobación ya dicha no se vuelve a pegar como si faltara.

`pending_question` sigue vacío. No se proyecta como pregunta pendiente algo inferido del texto de la respuesta: no hay un mecanismo que guarde la pregunta que Danebo acaba de hacer. Propuesta aparte, no implementada: al cerrar el turno, si la respuesta termina en una comprobación, guardarla como pregunta abierta y no repetirla cuando el técnico ya dijo que no la sabe. Eso queda fuera de este diff.

La próxima corrida, solo si se autoriza, usa `script/field_companion/stage2_journey_a.rb` con `STAGE2_JOURNEY_AUTHORIZED=1`. El runner local `tmp/stage2_journey_a.rb` carga ese archivo. Esta sección no la autoriza. El presupuesto de esa corrida está en el ajuste siguiente: no se reabre contando solo filas posteriores al baseline.

Sigue sin demostrarse, y este diff no lo cambia: el ranking que no devolvió el Elemont en las consultas del episodio, el cuerpo del filtro de la cuenta 1 de esas pasadas, si algún chunk del Elemont habla de la puerta o del imán, y si `manual-cea15p` aplica a la placa CEA15. No se tocó el pin ni el filtro de aplicabilidad.

Condición para otra validación: revisión de este diff y una autorización explícita. El techo sigue en 126 llamadas de esta etapa, 168 globales y US$2,50. Lo ya gastado, 80 llamadas y US$0,161562, no se borra. La etapa 3 no empieza.

#### Ajuste sobre 0ec8ba6 (2026-10-07)

Sin Bedrock, sin Retrieve, sin otra pasada y sin despliegue. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. Este ajuste no autoriza la pasada que deja preparada.

El runner suma siempre las 80 llamadas y US$0,161562 ya gastados. Un baseline nuevo, o una base sin esas filas, no devuelve el techo a 126. La pasada futura, si se autoriza, puede añadir como máximo 42 llamadas nuevas, reintentos de publicación y guidance incluidos. Antes de cada turno tiene que quedar margen para 3 llamadas de modelo: el intérprete y hasta dos de publicación o guidance. El segundo intento `retry_open` no entra, porque este journey no usa pin. Con eso, la etapa 2 sigue dentro de 126 y la etapa 3 conserva sus 42 dentro del techo global de 168. El costo histórico también entra en el tope de US$2,50; el margen de costo de un turno es el supuesto ya escrito, US$0,0045 más dos veces US$0,0115.

Cada ejecución escribe en `tmp/stage2_journey_a/runs/<corrida>-session-<id>/`. No reescribe `trace.json` ni las pasadas anteriores. El manifiesto guarda el SHA y el consumo histórico. No reconstruye los requests que no se guardaron.

La captura, solo dentro del bloque, registra también el prompt que sale por generación directa: `BedrockClient#generate_text` (guidance y generación con identidad conocida) y `converse_message` (contrato de publicación). `max_tokens` se conserva. Las credenciales se quitan por nombre exacto (`access_key_id`, `session_token`, `secret_access_key`); una clave no se borra por contener la palabra token. No hay llamada extra.

`merge_phrase` ya no descarta una frase porque otra esté contenida en ella. «La guía no tiene obstrucción, pero el rodillo está trabado» conserva la guía y el rodillo trabado, y no guarda al lado la frase corta. Dos comprobaciones que no se contienen siguen las dos.

#### Pasada autorizada sobre da8d32b (2026-10-07)

SHA `da8d32b38b8f9333fcdbb81936c07f2a21f6fad4`. Una sola pasada de los turnos 1 a 14. Sesión local 196. Trazas en `tmp/stage2_journey_a/runs/20261007T193541Z-session-196/`. Las trazas anteriores, en `tmp/stage2_journey_a/`, no se reescribieron. Sin pin, sin L3, sin despliegue y sin escritura en la base Rails de producción. No hubo segunda pasada ni reparación en caliente. Esta autorización no abre la etapa 3.

Rails local, `smart_deal_development` en localhost, Knowledge Base `Y7RZWMFJSR`, región `us-east-1`. El proceso exportó el índice de producción y apagó la sesión compartida. Cuenta 1 y documento Elemont `dcc8e046-037d-48a6-8913-1992aed28507`. La disponibilidad prevista en el runner devolvió el Elemont MH, páginas 1 y 7, junto con un manual Crown. El filtro capturado es el mismo en esa disponibilidad y en los turnos del episodio: cuenta 1, o la cuenta 4 sin foto y sin `manual_corpus=account`, o `manual_corpus=general`. Híbrido. Disponibilidad con k=5; el episodio con k=8. Ningún retrieve del episodio devolvió el Elemont. Devolvieron `manual-cea15p`, `manual-cea51fb-das`, VF5, Monarch e IME01. El parecido del nombre no hace compatible a `manual-cea15p` con la placa CEA15. La diferencia observada es la consulta, no otro filtro. No se hicieron búsquedas adicionales.

Presupuesto de esta pasada, leído de `BedrockQuery`: 26 llamadas nuevas y US$0,053276. 14 son el intérprete (`semantic_analysis`) y 12 son generación (`query`, ruta `rag_global`). Los turnos 10 y 13 no generaron. Con las 80 llamadas y US$0,161562 ya gastados: 106 llamadas y US$0,214838. Cabe en 42 nuevas, en 126 de la etapa y en 168 globales. `Retrieve` y el embedding de la consulta no están en esa cifra. No hay rollup de `bedrock_daily_costs`.

El bloque del turno 14 mide 563 caracteres y no se recortó. El prompt enviado a generación lleva el objetivo, Elemont MH, CEA15, el código 18, `Not current: fault code 8`, el LED 7, la guía sin obstrucción y el clic. El turno 1 buscó sin pedir fabricante, modelo ni controlador. El turno 5 guardó el código 18, rechazó el 8, sacó «El display muestra código 8» y conservó la puerta, el imán, la planta, la ocupación y la reapertura. La consulta quedó en «era código 18», sin «no .». «Sigue igual» no reemplazó el estado.

El turno 13 no aplicó la corrección. El técnico dijo planta 2, no planta 1. La salida cruda del intérprete fue `correct`, con la aserción «cerca de planta 2» y observaciones vacías. La respuesta fue «¿Qué dato del equipo quieres corregir?». La planta 1 siguió en el episodio y en el prompt del turno 14. Un `correct` sin negación ranurada se vacía si queda un assert de identificador, y la frase «la cabina está detenida cerca de planta 2» no se guardó.

No se envió «No lo sé». El turno 11 pasó de «Hice esa revisión» a «Sigue el clic y la puerta no termina de cerrar» porque la respuesta anterior no nombraba esa revisión. El turno 7 tenía Elemont MH, CEA15 y el código 18 en el prompt, y la respuesta volvió a pedir la placa. Es orientación con identidad no confirmada, no éxito documental. El turno 10, sin retrieve, respondió «Puedes seguir con lo que ya me contaste.»

Respuesta completa del turno 14: «Escucha el sonido del imán cuando la puerta llega al marco y dime si oyes un chasquido o un zumbido que se sostiene, o si el sonido se detiene apenas la puerta toca el marco.» No cita el Elemont. No declara la puerta reparada. No inventa un terminal ni un valor de fabricante. Esa pregunta distingue chasquido, zumbido sostenido y si el sonido se detiene al tocar el marco. «Se oye un clic» no la responde: es una precisión nueva, no una escucha ya contestada. La pasada queda bloqueada porque la corrección de planta no se aplicó y no hubo éxito documental. Deja la planta 1 como vigente. No es una respuesta sustentada, ni una siguiente acción que use la corrección, ni un escalamiento fundamentado.

Veredicto de esta pasada: `BLOQUEADA`. No es `EPISODIO_VALIDADO`. La etapa 3 no empieza. Este cierre no autoriza otra pasada.

#### Reparación local sobre 66dd9e0 (2026-10-07)

Sin Bedrock, sin Retrieve, sin otra pasada y sin despliegue. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. Esta reparación no autoriza una pasada.

La salida cruda del turno 13 era `correct`, con la aserción «cerca de planta 2» y observaciones vacías. La recuperación armaba «la cabina está detenida cerca de planta 2» y conservaba el fragmento como identificador. `observation_correction?` lo rechazaba y el turno volvía a preguntar qué dato corregir. Un fragmento contenido en la observación recuperada ya no bloquea esa corrección ni se guarda como identidad del equipo. Otro identificador del mismo turno se conserva. Una negación con slot o un par negar/afirmar siguen exigiendo el valor vigente y su reemplazo.

El consumo histórico pasa a 106 llamadas y US$0,214838 registrados en `BedrockQuery`. Quedan 20 llamadas dentro de 126. La etapa 3 conserva 42 dentro del techo global de 168 y el tope sigue en US$2,50. El saldo no abre otra pasada: el tope de la pasada siguiente queda en 0. `Retrieve` y el embedding siguen fuera de esa cifra. No hay rollup de `bedrock_daily_costs`.

Los cuerpos de los chunks no se guardaron. `availability.json` y `trace.json` guardan la consulta, el filtro, k y las citas: nombre, página, cuenta, marca `elemont` y URI truncada. No hay texto de página. Lo capturado del Elemont es la disponibilidad: «Elemont Montacargas Hidraulico Modelo MH», páginas 1 y 7, cuenta 1, `chunk_p1_1.txt` y `chunk_p7_2.txt`, más Crown en las páginas 99 y 383. El texto de esa consulta de disponibilidad es el título del manual. Ninguna cita del episodio tiene `elemont: true`. Esa metadata no dice si el manual habla de la puerta o del imán. Falta el texto de esas páginas para saber si puede responder al caso. No se atribuye el fallo al ranking y `manual-cea15p` no queda como compatible con la placa CEA15.

Pendiente: otra pasada solo con autorización explícita. La corrección de planta está demostrada en local y no está revalidada contra el índice. El éxito documental del Elemont sigue abierto porque el cuerpo de las páginas 1 y 7 no está en la traza.

#### Ajuste sobre 2faa7d0 (2026-10-07)

Sin Bedrock, sin Retrieve, sin otra pasada y sin despliegue. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. Este ajuste no autoriza una pasada.

Una corrección de observación ya no borra los `fact` del turno cuando el intérprete dejó las observaciones vacías. Se elimina solo el identificador que es la frase recuperada o un fragmento de ella. Un controlador que el catálogo reconoce, aunque su nombre aparezca dentro de esa frase, sigue vigente junto con la planta nueva. La planta anterior deja de estarlo. La consulta y el bloque de contexto conservan los dos. Un reemplazo de identidad o de código incompleto sigue pidiendo el dato: hace falta la negación con slot, o el par negar y afirmar.

Con `PASS_CALL_CAP` en 0, `stage2_journey_a_main` consulta `Stage2RunBudget` y vuelve antes de crear la sesión de validación, de `Retrieve` y de la generación, aunque `STAGE2_JOURNEY_AUTHORIZED=1`. El control anterior a cada turno sigue en el recorrido. El histórico permanece en 106 llamadas y US$0,214838. Los techos siguen en 126, 42 reservadas para la etapa 3, 168 y US$2,50.

#### Instrumentación local

`Rag::ValidationCapture` queda como capacidad permanente del flujo. No pertenece a un journey ni a una sesión. La captura detallada sigue apagada: solo existe dentro de un bloque `capture` abierto a propósito. Cualquier validación o diagnóstico futuro reutiliza la misma implementación y puede etiquetar el bloque con los identificadores que ya tiene (`sha`, sesión, episodio, cuenta, usuario, `correlation_root`). El producto no ramifica por el texto de un fixture.

Con la captura abierta, el flujo anota la percepción aplicada y la regla que cambió un dato, el delta del episodio, la ruta y la condición que la eligió, las salidas tempranas y el reintento de Aurora, la consulta efectiva con filtro, modalidad y k, cada chunk recibido con documento, página, id, URI y score —o `unavailable` si la API no lo trae—, la decisión de la compuerta y de la política de identidad, el prompt realmente enviado y si todavía es una plantilla, y la respuesta con sus citas. El texto de chunk y los prompts quedan solo en ese bloque local. `PilotUsageLog` no sube sus límites y no guarda cuerpos. No se reconstruyen solicitudes viejas que no se guardaron.

Limitaciones: un score ausente queda `unavailable`; `RetrieveAndGenerate` no expone el top-k completo ni el score de la cita; un prompt con `$search_results$` o `$output_format_instructions$` se marca como plantilla, no como contexto resuelto. La membresía de las páginas 5 y 6 el 2026-10-07 no se volvió a consultar.

Esa última frase es el estado de la instrumentación. La comprobación documental posterior está en la sección siguiente. No reabre esta pieza.

Veredicto de esta pieza: `INSTRUMENTACION_LOCAL_COMPLETADA`. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. No autoriza otra pasada. El presupuesto no cambia: 106 llamadas, US$0,214838, techos 126, 42, 168 y US$2,50, `PASS_CALL_CAP` en 0.

Cada turno abre un contexto en `ValidationCapture` y, al salir, restaura la correlación y el intento anteriores, también si el bloque falla. Así la solicitud del intérprete, la salida cruda, la percepción y los eventos siguientes de ese turno comparten su correlación. `correlation_root` y el resto de identificadores se mantienen. Un retrieve o `RetrieveAndGenerate` que falla de forma terminal, incluidos los reintentos de Aurora ya agotados, deja operación, correlación, intento de producto, intento de transporte, clase y motivo sanitizado, y vuelve a lanzar la excepción original. La captura detallada sigue apagada por defecto.

Veredicto de estas dos correcciones: `CORRECCIONES_INSTRUMENTACION_COMPLETADAS`. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. No autoriza otra pasada ni una comprobación documental. El presupuesto no cambia.

#### Comprobación documental (2026-10-07)

Autorizada después, sobre `bb672e7`, como una sola Retrieve y sin generación. No es una pasada del journey A. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. El presupuesto de modelos no cambia: 106 llamadas y US$0,214838. `PASS_CALL_CAP` sigue en 0. Estas dos Retrieve no entran en `BedrockQuery`.

La sesión 196 y esta comprobación fueron sin pin. Escribir «Elemont» en la consulta no pinea. El foco web vive en `document_focus`. El corpus compartido explica que el filtro abierto también devuelva manuales de otras marcas. No demuestra la causa del fallo de retrieval de la sesión 196. `viewer_account` es autorización de acceso del chunk, no compatibilidad técnica con el equipo.

Consulta: `Elemont Montacargas Hidraulico Modelo MH Seguridad Puerta nivel 1`. Knowledge Base `Y7RZWMFJSR`, HYBRID, k=8, cuenta local 1, con el filtro capturado en la sesión 196. Hubo dos invocaciones. La primera, `tmp/documentary_retrieve/20261007T212004Z/`, falló porque Aurora se estaba reanudando tras la pausa. La segunda, `tmp/documentary_retrieve/20261007T212124Z/`, devolvió ocho resultados y ninguno fue rechazado.

`chunk_p5_1.txt` del Elemont MH salió primero, página 5, aceptado por `viewer_account`. El texto es el diagrama de circuito 3: la línea de seguridad incluye la etiqueta «Seguridad Puerta nivel 1», y también está la botonera de pasillo del nivel 1. No menciona el código 18, el LED 7 ni el imán. `chunk_p6_1.txt` no entró en los ocho. Esta consulta no lo devolvió. Eso no dice que falte en el índice.

El contrato del filtro, resuelto por slug y no por estos ids locales, está en [SESSION_AND_RETRIEVAL.md](SESSION_AND_RETRIEVAL.md#shared-corpus-current-contract).

#### Comprobación web y reparación local (2026-10-07)

La imagen web de producción seguía en `d5660d72a1e676ef9f054dd49ccc7e65511b9f2c`. Una sola solicitud autenticada en `https://elevator.danebo.ai`, con un usuario aislado de `danebo-legacy`. No usó la sesión 5. La pregunta fue la del turno 1 de la sesión 196, sin pin y sin agregar a mano el nombre del catálogo. Correlación `query:126c8fa5-5ccb-49e6-b92b-37534c8853e2`. HTTP 200. Ruta `identity_unknown_reference`, HYBRID, k=8. La cadena de retrieval fue el texto del técnico. Ocho chunks, ninguno del Elemont MH. Citas publicadas vacías. La respuesta dijo que la identidad no está confirmada y pidió observar si el imán de la puerta 1 está alineado con el sensor de cierre en la jamba. Ese sensor y esa jamba no estaban en la pregunta ni en una cita. La frase la escribió el modelo.

Dos filas de `BedrockQuery`: análisis semántico US$0,00348 y generación `rag_global` US$0,000868. Total US$0,004348. Esas dos llamadas quedan aparte del histórico de la etapa 2, que sigue en 106 llamadas y US$0,214838. `Retrieve` y el embedding de la consulta no están en esa tabla. `PASS_CALL_CAP` sigue en 0. Los techos siguen en 126, 42, 168 y US$2,50.

Límites de esa evidencia. La solicitud corrió en `rails runner` dentro del contenedor web, no en Puma, así que el log del rol web no tiene sus marcadores. La base guardó el turno y las dos filas de costo. El paquete está en `tmp/pilot_exports/trace-once/2026-10-07_2026-10-07_danebo-legacy/`. El reporte marca el rol web como ausente por esa razón. La sesión 5 no cambió. El usuario de la comprobación se borró al terminar. No hubo despliegue. Recuperar el dibujo no resuelve la falla: la página 5 no explica el código 18, el LED 7 ni el imán.

`BedrockIngestionJob#persist_to_technician_documents` omite `account_id`. Queda registrado aparte. Esta reparación no lo toca y no es la causa de la consulta corta.

Reparación local, sobre la misma base, sin llamadas a AWS y sin despliegue. Un span que es la marca y el designador exactos de una sola entrada confirmada y autorizada agrega el `display_name` a los identificadores del episodio, con origen `catalog`. `QueryComposer` ya compone esos identificadores y mantiene el tope de 442 caracteres. El span del técnico sigue con origen `user`. No se escribe un hecho de fabricante ni de modelo, así que la expansión sola no vuelve `EquipmentIdentity#known?` verdadero ni confirma aplicabilidad. No escribe pin ni cambia el filtro. Varios candidatos, una fila no autorizada o una vinculación ambigua no eligen uno. `CEA15` no selecciona `CEA15+`. Una corrección que niega ese span retira también el nombre canónico y no lo deja rechazado de forma global. El identificador de catálogo admite 120 caracteres; el del técnico sigue en 30.

En un caso genérico, la consulta pasa de `Acme ZX no arranca` a esa frase más `Acme Freight Controller ZX Field Manual`. En el caso investigado, la consulta pasa del texto del técnico a ese mismo texto más `Elemont Montacargas Hidraulico Modelo MH`. Esos nombres son datos del catálogo de prueba y del manual ya publicado. No hay una rama de producto para ellos.

El prompt de orientación, con identidad conocida y con identidad desconocida, separa el reporte, la evidencia y la hipótesis. Un componente o un lugar que no quedó establecido es condicional: no se trata como si ya estuviera. No se agregó un cuestionario ni una pregunta de identidad por rutina. El test comprueba que esa instrucción está en el prompt. No demuestra que el modelo la cumpla.

Pendiente: el efecto de la consulta expandida sobre el retrieval y sobre la respuesta real. Esta reparación no lo ejecuta. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. `PASS_CALL_CAP` sigue en 0.

Veredicto de este diff: `REPARACION_LOCAL_COMPLETADA`.

#### Correcciones del review (2026-10-07)

Sobre `77b3de6`. Sin llamadas a AWS, sin Retrieve, sin journeys, sin despliegue y sin cambios en datos de producción. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. `PASS_CALL_CAP` sigue en 0. Los techos y el histórico de 106 llamadas y US$0,214838 no cambian. Las dos llamadas de la comprobación web siguen aparte.

Una expansión de catálogo ya no ocupa una plaza que expulse un identificador del técnico o de una foto. El tope sigue en 5. Entre identificadores originales se conserva el FIFO. Si no queda una plaza libre, la expansión no se escribe. La misma prioridad vale al guardar y al releer. Si el JSON pasa el tope de bytes, también sale primero una expansión de catálogo.

El nombre canónico se guarda, se compara y se retira con el mismo literal, incluido el corte a 120 caracteres. Negar el span después de persistir y releer saca esa expansión de la consulta y del contexto. No se rechaza el nombre canónico de forma global y no se borra un identificador independiente.

La consulta compuesta puede ser igual al texto del técnico cuando ese texto ya trae lo necesario. Un identificador del episodio que el texto no trae sí cambia la consulta. El hash se calcula sobre esos textos. La ruta, la correlación, el Retrieve, la generación directa y la separación entre la consulta de recuperación y el prompt de generación siguen cubiertos. No se cambió el producto para forzar hashes distintos.

La regla de hipótesis del guidance se conserva. Para que el prompt de identidad desconocida del turno 14 siguiera mostrando el código rechazado, se acortaron dos frases de esa instrucción. El tope de este diff sigue en 2400. La reparación del recorte, más abajo, lo sube a 2472. La reparación de continuidad lo devuelve a 2400.

Pendiente: el efecto de la consulta expandida sobre el retrieval y sobre la respuesta real. Esta corrección no lo ejecuta.

Veredicto de este diff: `CORRECCIONES_LOCALES_COMPLETADAS`.

#### Contrato N4 de citas ajenas (2026-10-07)

Sobre `12af56c`. El test `foreign manufacturer chunks cannot create manual fact` seguía omitido por `n0_contract!("N4")`. Con `N0_CONTRACTS=1` se ejecutó de verdad: 1 corrida, 3 aserciones, 0 fallos, 0 skips. `retrieve_chunks` y el generador están stubbeados. No hubo llamada a AWS, Retrieve ni modelo.

El contrato ya se cumple: un chunk de otro fabricante no queda citable y la respuesta no forma un `MANUAL_FACT`. Se retiró solo ese `n0_contract!("N4")`. Las aserciones siguen. El helper global y los demás contratos N0 no se tocaron. No hubo cambio de producto.

La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. `PASS_CALL_CAP` sigue en 0. Los techos y el histórico no cambian.

Veredicto de este diff: `VALIDACION_LOCAL_COMPLETADA`.

#### Comparación de retrieval (2026-10-07)

Autorizada sobre `71b83a467dad8f94a820c85d6c2054b0b65df578`. Mide si la expansión de catálogo cambia el top 8. No valida el episodio ni la respuesta del modelo. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. `PASS_CALL_CAP` sigue en 0. El histórico sigue en 106 llamadas y US$0,214838. Los techos siguen en 126, 42, 168 y US$2,50. Las dos llamadas de la comprobación web, US$0,004348, siguen aparte. Esta comparación no creó filas de `BedrockQuery`. El costo de `Retrieve` y del embedding de la consulta no está en esa tabla y queda sin cifra.

La consulta expandida salió del código local, reusando la percepción ya capturada del turno 1 de la sesión 196 (`stage2:a:t01`). No hubo una llamada nueva al intérprete. El span `Elemont MH` quedó con origen `user`. El nombre `Elemont Montacargas Hidraulico Modelo MH` entró con origen `catalog`. `CEA15` siguió con origen `user` y sin expansión a `CEA15+`. Los hechos quedaron vacíos, así que `known?` sigue falso. No hubo pin. La consulta tiene 138 caracteres, dentro del tope de 442. El visor de esa composición fue la cuenta local dueña de la fila del Elemont. El slug `danebo-legacy` de la base local es otra cuenta y no se usó para armar el filtro.

El servicio que recuperó es la imagen web `d5660d72a1e676ef9f054dd49ccc7e65511b9f2c`. Ese SHA no contiene la expansión. `BedrockRagService` no cambió entre esa imagen y `71b83a4`. Las dos llamadas fueron `retrieve_chunks` dentro del contenedor web, con la cuenta `danebo-legacy` de producción, sin URIs de foco. El filtro, la Knowledge Base `Y7RZWMFJSR`, la región `us-east-1`, HYBRID y k=8 son los de ese servicio. El filtro de las dos operaciones es el mismo. No se afirma que el compositor nuevo esté desplegado.

Hubo dos recuperaciones lógicas. La original reintentó una vez el transporte por la pausa de Aurora, espera de 15 segundos, y después respondió. La expandida no reintentó. No hubo repetición manual ni cambio de la configuración de reintentos. Ocho resultados en cada una, todos aceptados, ninguno rechazado. Duración 20542 ms y 548 ms. `PILOT_EVENTS_PERSIST=false` solo en ese proceso, para no insertar `pilot_events`. No se modificaron cuentas, documentos, sesiones ni configuración.

Elemont no aparece en ningún documento, URI ni texto de los dieciséis chunks. El rank 1 sigue siendo KONE MonoSpace, página 375, score 0,5, en las dos consultas. La expandida sube `manual-cea15p` página 84 del puesto 4 al 2, reordena páginas KONE, KOYO y VF5, saca KONE página 374 y mete el manual de ayuda técnica página 55. Esas páginas hablan de puertas de otros equipos. El único imán del texto es de zona de puertas KONE, página 444, presente en las dos consultas. No hay código 18 ni LED 7. La cifra 18 que aparece está dentro de un identificador de registro del chunk CEA15+, no es un código de falla. Un score no dice que el chunk aplique ni que un plano resuelva la falla. Este par no se generaliza a otros equipos ni a la estabilidad del ranking.

Evidencia: `tmp/documentary_retrieve/20261007T233903Z/`.

Veredicto de esta comparación: `SIN_MEJORA_OBSERVADA`.

#### Candidato a desplegar (2026-10-07)

La comparación anterior mezcló el compositor local con el servicio de `d5660d72`. No valida el companion con el código nuevo desplegado. El diff `d5660d72..2b7cbc4` tiene cuatro commits de producto y de plan. La revisión separa tres piezas:

- La expansión del nombre canónico. Queda fuera de este despliegue. En la comparación no metió el Elemont en el top 8 y cambió el orden de manuales de otros equipos. No se declara como reparación de ese fallo.
- La regla de hipótesis del guidance y el acortamiento que la mantiene dentro de 2400 caracteres. Entra. Está cubierta por test. No demuestra que el modelo la cumpla. La siguiente prueba del flujo real es la que puede observarlo.
- El contrato N4, ya sin el skip, y el test que acepta hashes iguales cuando la consulta no cambia. Entran. No cambian la consulta ni el filtro.

Salen con la expansión el tope de 120 caracteres, la plaza de identificador `catalog` y los tests de esa expansión. Nada más escribe ese origen. 156 corridas de guidance, episodio, alcance, percepción y reducer: 1693 aserciones, 0 fallos. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. `PASS_CALL_CAP` sigue en 0.

El candidato quedó en `6ca7788dd3694b90c8e6cd5d4f04d68be08f0407` y es la imagen que ejecutan el web y el worker. `https://elevator.danebo.ai/up` respondió 200. Justo después del despliegue, el contenedor web anterior `d5660d72` seguía presente, detenido. Volver a esa imagen es `kamal rollback d5660d72a1e676ef9f054dd49ccc7e65511b9f2c`. Los trabajos de ingesta sin terminar estaban fallidos desde agosto y no había ninguno en ejecución.

#### Turno real sobre la imagen nueva (2026-10-07)

Un solo `POST /rag/ask` dentro del contenedor web, por el mismo controlador que usa el formulario. Host `elevator.danebo.ai`, cuenta `danebo-legacy`, usuario aislado creado para esta prueba y borrado al terminar. La sesión de ese usuario quedó en cero. No pasó por el socket público de Puma: el cliente fue el proceso de Rails, así que el log de acceso del proxy no tiene esta petición. La pregunta fue la del turno 1, sin pin y sin el nombre canónico agregado a mano. Correlación `query:9ff9190d-225c-4439-bef3-f5db8f0a22e6`. HTTP 200.

La consulta efectiva es el texto del técnico, 97 caracteres, el mismo SHA que la consulta original de la comparación anterior. HYBRID, k=8, el mismo filtro, ocho chunks aceptados. No hay Elemont. El orden coincide con la columna original de esa comparación: KONE 375, KONE 446, KOYO 131, CEA15+ 84, VF5 13, KONE 444, KONE 374, KONE 442. Aurora reintentó una vez el transporte, 15 segundos. No hubo repetición manual.

La respuesta no cita el Elemont ni nombra un sensor de jamba. Dice que la puerta no cierra y el imán no magnetiza, y luego presenta desalineación, obstrucción o falla de alimentación del circuito del imán de retención. Esas tres causas no están en la pregunta ni en una cita del Elemont. Una respuesta no demuestra que la regla de hipótesis se cumpla. El turno ofreció dos manuales privados, `manual-cea15p` y el plano Elemont, como sugerencia. La sugerencia no es un chunk recuperado y no dice que el plano resuelva la falla.

Dos filas de `BedrockQuery`: intérprete US$0,00348 y generación `rag_global` US$0,001403. Total US$0,004883. Quedan aparte del histórico de 106 llamadas y US$0,214838, y aparte de los US$0,004348 de la comprobación web anterior. `Retrieve` y el embedding no están en esa tabla. `PASS_CALL_CAP` sigue en 0. Los techos no cambian.

Evidencia: `tmp/documentary_retrieve/20261008T002051Z/evidence.json`.

La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`.

#### Reparación de designadores con signo (2026-10-07)

Sobre `47c43e24bd8dd561f696fe095feae14fa46ec487`. Sin AWS, sin Retrieve, sin modelos, sin embeddings, sin journeys, sin despliegue y sin cambios de infraestructura. `PASS_CALL_CAP` sigue en 0. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. Esta reparación no autoriza una pasada ni revalida el episodio.

La última evidencia de imagen es `6ca7788`. Esa imagen no contiene la resolución de marca compuesta ni esta reparación. `47c43e2` es la base. La comparación que conserva el signo quedó en `700d9d0`, en `main`, y no es la imagen evidenciada.

Antes de corregir, cinco pruebas nuevas fallaban. El control positivo no fallaba: «Elemont MH+» ya resolvía la entrada Elemont / MH+.

- `resolve_compound_brand` comparaba el designador con `normalize_label`, que elimina «+». La entrada confirmada y visible Elemont / MH+ resolvía el span «Elemont MH» y escribía el fabricante.
- Con Elemont / MH y Controles S.A. / CEA15+, ambos confirmados, vinculados a `KbDocument` y autorizados para el mismo visor, el turno «Elemont MH con placa CEA15; la puerta 1 no termina de cerrar y el imán no magnetiza. ¿Qué reviso?» resolvía CEA15 como CEA15+. El reducer sustituía el fabricante del equipo por Controles S.A. El intérprete de sesión hacía lo mismo.
- El span explícito CEA15+ sí resolvía el controlador, y su fabricante sustituía al Elemont ya establecido.

`FollowupQueryRewriter.normalize_label` no cambió. La comparación de designadores conserva «+». No hay coincidencia difusa. MH no selecciona MH+. CEA15 no selecciona CEA15+. MH+ y CEA15+ siguen resolviendo su entrada. El prefijo que ya existía, como NICE3000n, sigue. VF5 deja de seleccionar VF5+ por la misma comparación; VF5+ sigue siendo exacto. Un designador sin tipo, MH, sigue sin escribir controlador ni modelo.

La marca del controlador llena el fabricante del equipo solo cuando ese hecho está vacío. No sustituye uno ya guardado. NICE3000 sigue pudiendo escribir MONARCH cuando no hay fabricante. No se tocó `EquipmentIdentity#known?`, `NEEDLE_SOURCES` ni el origen `catalog`. No hay pin ni expansión del nombre canónico. Siguen los controles de ambigüedad, de otro tenant, de entradas duplicadas, de negación y de conservación de otro fabricante. No se modificó el fixture del journey A.

Evidencia local, con `PASS_CALL_CAP=0`: `turn_perception_test`, `conversation_session_turn_interpreter_test`, `technical_understanding_test`, `document_identity_catalog_tenant_test`, `route_policy_test`, `companion_guidance_context_test` y `work_context_reducer_test`. 154 corridas, 1322 aserciones, 0 fallos, 0 errores y 0 skips.

Pendiente, y este diff no lo ejecuta: el efecto sobre el retrieval y sobre la respuesta real. El ranking que no devolvió el Elemont sigue abierto. La etapa 3 no empieza.

Veredicto de este diff: `REPARACION_LOCAL_COMPLETADA`.

#### Reparación del recorte de guidance (2026-10-08)

Sobre `700d9d0`. Sin AWS, sin Retrieve, sin modelos, sin embeddings, sin journeys, sin despliegue y sin cambios de infraestructura. `PASS_CALL_CAP` sigue en 0. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. Esta reparación no autoriza una pasada y no revalida el episodio.

`CompanionGuidanceContext#to_s` terminaba en `text[0, MAX_CHARS]`. En `tmp/stage2_journey_a/runs/20261007T193541Z-session-196/` hay 12 prompts de `generate_text`. Diez miden 2400 caracteres. El turno 14 termina en «Corrijo al». La frase completa está en `history.user_texts`: «Corrijo algo de antes: la cabina está detenida cerca de planta 2, no de planta 1.» Ese corte también se lleva el Follow-up y la lista de manuales. El turno 2 mide 2380 y sí cierra con `manual-cea15p` p. 84.0, `manual-cea51fb-das` p. 82.0, `manual-cea15p` p. 65.0 y `Follow-up: yes.` Los turnos 10 y 13 no tienen prompt de generación. Esos prompts son del código de `da8d32b`. La reproducción usa el compositor actual y los textos capturados. No reconstruye el cuerpo que el corte ya había eliminado.

Ese recorte es distinto de la planta. El episodio capturado del turno 14 sigue con la observación «cerca de planta 1», porque el turno 13 no aplicó la corrección. El código que después la aplica está en la imagen evidenciada `6ca7788` y no fue revalidado. Esta reparación no reescribe esa observación.

Antes del cambio, la prueba con el bloque capturado del turno 14 y los tres manuales del turno 2 falló: el prompt medía 2400 y no contenía la corrección completa. El visible terminaba en «Corrijo al».

Con la instrucción actual, el resto obligatorio mide 2472 caracteres después de sacar enteros los manuales candidatos y el turno «Sigue igual.»: la instrucción, «¿Y ahora?», el objetivo, el código 18, los identificadores, las observaciones, `Not current: fault code 8`, la corrección y el Follow-up. 2400 no lo contiene. El tope pasa a 2472, que es ese resto. No hay margen añadido para que la prueba pase.

Bajo esa presión se conserva la instrucción, incluida la regla de hipótesis, la prohibición de enseñar manuales recuperados y la de inventar valores, terminales y significados de código. Se conserva la pregunta, el problema vigente, la corrección completa y el Follow-up. Se descartan las tres líneas de manual y su encabezado, y el turno anterior «Sigue igual.». Un objetivo que no cabe, como ochocientas repeticiones de «detalle», sale entero. La línea de objetivo de la instrucción permanece.

Si el bloque de problema ya trae planta 2 en lugar de planta 1, la línea `Obs:` conserva planta 2 y no contiene planta 1. El código 18 sigue vigente. El código 8 aparece solo en `Not current: fault code 8`. La frase de corrección puede nombrar planta 1 como el valor que se dejó atrás. Identidad conocida, con la instrucción más corta, cabe con los manuales de referencia y los dos turnos. Español e inglés comparten la composición; «English» y «Spanish» ocupan los mismos caracteres. Un contexto corto no omite unidades.

Una pregunta que ya usa casi el tope de entrada de 400 caracteres deja el episodio fuera: se omiten enteros el objetivo, la foto, el historial y los manuales, y se conservan la pregunta y el Follow-up. La frase de búsqueda vacía, sumada a este episodio, tampoco deja sitio a las observaciones: salen enteras. Quedan la corrección, el código 18, el Follow-up y la pregunta. Conservar además esas observaciones mediría 2706. No se sube el tope hasta ahí.

La captura `context_fit` anota cada unidad omitida con su rol y su texto. Ya no guarda un sufijo cortado a 2400.

No cambió la percepción, el reducer, `EquipmentIdentity#known?`, el retrieval, los pins, la aceptación del journey A ni su fixture. No hay `pending_question` conversacional ni respuesta meta. No hay otro agente ni otra llamada.

Evidencia, con `PASS_CALL_CAP=0`: `companion_guidance_context_test`, `validation_capture_test` y `session_context_builder_test`. 92 corridas, 1126 aserciones, 0 fallos, 0 errores y 0 skips. Dos pruebas de guidance con búsqueda vacía en `document_identity_scope_test`: 2 corridas, 29 aserciones, 0 fallos.

Esas pérdidas bajo pregunta larga y búsqueda vacía, y el tope 2472 calculado sobre el turno 14, quedan cerradas por la reparación de continuidad. Esta sección describe el commit de unidades, no el compositor vigente.

Pendiente de ese commit: el efecto sobre una pasada real y sobre la respuesta del modelo. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. La etapa 3 no empieza. Ese commit quedó en `main` para revisión y no se desplegó. No hay una comprobación nueva de la imagen en ejecución.

#### Continuidad del episodio bajo presión (2026-10-08)

Sobre `085969c`. Sin AWS, sin Retrieve, sin modelos, sin embeddings, sin journeys, sin despliegue y sin cambios de infraestructura. `PASS_CALL_CAP` sigue en 0. Los techos y el histórico de 106 llamadas y US$0,214838 no cambian. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. Esta reparación no autoriza una pasada y no revalida el episodio.

La composición por unidades se conserva. No vuelve el corte ciego del prompt final. El tope vuelve a 2400: la compactación cabe y 2472 era el resto exacto del turno 14, no un presupuesto general. No se sube el tope.

La instrucción se parte en reglas que no salen antes que el episodio y en frases de estilo que sí pueden salir enteras. Se conservan el objetivo del turno, la separación entre reporte, evidencia e hipótesis, el límite de procedimientos sin evidencia, el componente no confirmado como condicional, la búsqueda vacía que no significa que el manual no exista, el idioma y la continuidad. No se borró una restricción del compositor para hacer caber un fixture. La frase media de la búsqueda vacía se acortó; siguen «Do not say the manual does not exist.» y, con foco fijado, «Do not release the pin.»

El orden de descarte es: manuales candidatos sin contenido aplicable, historial redundante o duplicado de forma comprobable, turnos viejos, el indicador Follow-up y después las frases de estilo. El Follow-up no sustituye al caso. Una observación no se funde con otra por compartir tokens: solo sale si es un eco de continuidad o si la frase completa ya está en el objetivo o en una observación anterior. Si aún no cabe, salen unidades enteras. Una corrección no se parte en 160 caracteres. Una pregunta de más de 400, o un turno que no es corrección y pasa de 160, se corta en el último espacio útil y el resto queda como recorte previo.

`context_fit` distingue la unidad omitida del recorte previo. El recorte lleva `prior_cut`. No se anota como intacto el texto que ya se cortó.

Antes de cambiar las expectativas, la pregunta larga, la búsqueda vacía, el foco fijado, la corrección de más de 160 caracteres y el caso genérico perdían el episodio o partían la corrección. Con el tope en 2400:

- Turno 14 de la sesión 196: 2359 caracteres. Conserva la pregunta, el objetivo, el código 18, los identificadores, las observaciones y sus comprobaciones, el código 8 solo como no vigente y la corrección completa. Salen los manuales candidatos, «Sigue igual.» y el Follow-up.
- La misma sesión con la planta ya corregida conserva planta 2 en `Obs:` y planta 1 solo en la corrección.
- Pregunta natural cercana al máximo, sobre ese episodio: 2359 caracteres. Conserva objetivo, identidad, código, corrección y comprobaciones. El Follow-up sale.
- Búsqueda vacía sobre ese episodio: 2341 caracteres. Conserva el episodio y la regla de búsqueda vacía.
- Búsqueda vacía con foco fijado: 2219 caracteres. Conserva el episodio y la regla del pin.
- Corrección relevante por encima de 160 caracteres: queda entera.
- Caso genérico, distinto de Elemont, con pregunta larga y búsqueda vacía: 2393 caracteres. Conserva el objetivo, Nortec, el código 41, el código 7 solo como no vigente, la planta 4 vigente, la corrección que deja atrás la planta 3 y la comprobación del indicador. En ese caso, ya sin manuales en el prompt, también sale la frase de no enseñar manuales recuperados. Las reglas de procedimiento, hipótesis, invención y búsqueda vacía siguen.
- Un contexto corto no omite unidades. Identidad conocida y desconocida, en español y en inglés, usan el mismo presupuesto. La instrucción conocida, más corta, sigue pudiendo incluir manuales de referencia, historial y Follow-up.

No hay rama por sesión, fixture, fabricante ni texto del journey. No hay otra llamada de modelo, tabla, agente ni sistema de memoria. No cambió la percepción, el reducer, `EquipmentIdentity#known?`, el retrieval, los pins ni el fixture del journey A.

Evidencia local, con dependencias externas stubbeadas y `PASS_CALL_CAP=0`: `companion_guidance_context_test`, `validation_capture_test` y `session_context_builder_test`, 98 corridas, 1243 aserciones, 0 fallos, 0 errores y 0 skips. Rutas de guidance con búsqueda vacía, pin vacío, identidad conocida sin manual y conflicto de fabricante, en `document_identity_scope_test` y `field_companion_pilot_readiness_test`: 8 corridas, 179 aserciones, 0 fallos, 0 errores y 0 skips. RuboCop sobre el compositor y esas pruebas no reportó ofensas. `git diff --check` quedó limpio.

Implementado: la continuidad local del compositor. Desplegado: no. La imagen evidenciada sigue siendo `6ca7788`. Revalidado: no. Pendiente de ese commit: el efecto sobre una pasada real y sobre la respuesta del modelo. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. La etapa 3 no empieza. Ese commit quedó en `main` y no se desplegó. El caso combinado que todavía expulsaba el objetivo queda en la sección siguiente.

#### El objetivo no compite por longitud (2026-10-08)

Sobre `8274192`. Sin AWS, sin Retrieve, sin modelos, sin embeddings, sin journeys, sin despliegue y sin cambios de infraestructura. `PASS_CALL_CAP` sigue en 0. Los techos y el histórico de 106 llamadas y US$0,214838 no cambian. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. Esta reparación no autoriza una pasada y no revalida el episodio.

Antes de cambiar el producto, el test de Rails juntó el episodio genérico de Nortec, la pregunta larga, `empty_retrieval: true` y la corrección de 217 caracteres. El prompt midió 2368 caracteres. Conservó la pregunta, el fabricante, los identificadores, el código 41, el código 7 como no vigente, las comprobaciones y la corrección completa. Omitió `Goal: la puerta del montacargas no termina de cerrar`. La unidad omitida era el hecho de rol `problem`, rango 4 y `seq` 52, igual a su longitud. La corrección, también rango 4, tenía `seq` 1 por su posición. `fit_guidance` comparaba esos números y sacaba el objetivo antes que la corrección. El caso genérico anterior, con la corrección corta, seguía en 2393 y sí conservaba el objetivo.

`MAX_CHARS` sigue en 2400. El objetivo y el resto de los hechos dejan de usar la longitud como `seq`. El objetivo queda en 0. Identidad, códigos, conflicto y la observación visual quedan en 1. Las observaciones siguen ordenadas por posición. La composición por unidades no cambia y no vuelve el corte final.

Para que ese cambio no desplace la pérdida a la identidad, el código, la corrección o una comprobación, se acortó la instrucción que ya estaba en el prompt. Sale «then ask that one check», porque la regla breve lo cubre. La intervención física y la operativa quedan en una frase. La búsqueda vacía conserva «The search returned no documentation. Do not say the manual does not exist.» y suelta la oferta intermedia, que ninguna prueba exigía y que las reglas de procedimiento e invención ya cubren. Entra en el núcleo «One useful question when needed. Not a questionnaire.» Siguen la hipótesis, el componente no establecido como condicional, los límites de procedimiento, valor e intervención, el uso de lo ya comprobado, el idioma y la continuidad.

Con la corrección de 217 caracteres el prompt mide 2361. Con el foco fijado vacío mide 2394. Los dos conservan la pregunta, el objetivo, Nortec, el identificador, el código 41, el código 7 solo como no vigente, la corrección completa, las cinco comprobaciones, la regla de búsqueda vacía y la pregunta útil. El segundo también conserva la regla del pin. Salen los manuales candidatos, «Sigue igual.», el Follow-up y las frases de estilo. En el caso con pin también sale «Do not cite manuals with [n].». Esas omisiones siguen anotadas en `context_fit`.

Evidencia local, con dependencias externas stubbeadas y `PASS_CALL_CAP=0`: `companion_guidance_context_test` y `validation_capture_test`, 53 corridas, 905 aserciones, 0 fallos, 0 errores y 0 skips. `session_context_builder_test`, 47 corridas, 412 aserciones, 0 fallos y 0 skips. Rutas de guidance con búsqueda vacía, pin vacío, identidad conocida sin manual, conflicto de fabricante y la proyección del journey A: 10 corridas, 301 aserciones, 0 fallos y 0 skips. RuboCop no reportó ofensas. `git diff --check` quedó limpio.

Implementado: esta reparación local. Desplegado: no. La imagen evidenciada sigue siendo `6ca7788`. Revalidado: no. Pendiente: el efecto sobre una pasada real y sobre la respuesta del modelo. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. La etapa 3 no empieza. Este diff queda en `main` para revisión y no se despliega.

#### Aislamiento del Journey A de texto (2026-10-08)

Sobre `c6c80ad`. Sin AWS, sin Retrieve, sin intérprete, sin generación, sin journey y sin despliegue. No cambia código de producto, filtros, presupuesto ni la configuración habitual. `PASS_CALL_CAP` sigue en 0. El histórico sigue en 106 llamadas y US$0,214838. Los techos siguen en 126, 42 reservadas para la etapa 3, 168 y US$2,50. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. Este ajuste no autoriza la pasada.

El runner de `c6c80ad` exigía `smart_deal_development` en localhost. El proceso que carga `script/field_companion/stage2_journey_a.rb` ahora exige el adaptador `postgresql`, el entorno de desarrollo, el host `localhost` o `127.0.0.1` y la base `smart_deal_stage2_isolated`. Solid Cache y Solid Cable se conectan en ese mismo proceso a `smart_deal_stage2_isolated_cache` y `smart_deal_stage2_isolated_cable`. Cambiar `ActiveRecord::Base` no mueve esas dos conexiones: cada clase se conecta sola y la conexión efectiva tiene que coincidir con el nombre. Solid Queue no se redirige y no se crea otra base de cola. `TrackBedrockQueryJob` se ejecuta en línea. Cualquier otro `perform_later` aborta antes de escribir `smart_deal_development_queue`. No se arrancan workers ni se ejecutan trabajos pendientes.

Esos cambios viven en el proceso de validación. No editan `.env`, credentials, `database.yml`, `cache.yml`, `cable.yml` ni `deploy.yml`. Un proceso que no carga el runner sigue en `smart_deal_development`, `smart_deal_development_cache`, `smart_deal_development_cable` y `smart_deal_development_queue`, y arma el filtro local de las cuentas 1 y 4.

La base aislada conserva las dos cuentas y los dos documentos ya reconstruidos desde evidencia. No había un usuario en esa evidencia, así que usuarios, sesiones, fotos, documentos de técnico, ingestas y la auditoría de esta prueba empiezan vacíos. El control de presupuesto no lee esas filas: `Stage2RunBudget` suma las 106 llamadas y US$0,214838 aunque `BedrockQuery` esté en cero. `stage2_journey_a_main` consulta ese control y vuelve antes de crear la sesión, de `Retrieve` y de la generación, aunque `STAGE2_JOURNEY_AUTHORIZED=1`.

El catálogo tiene 204 entradas. En esa base se enlazan 2. Faltan 202 filas. La preparación no demuestra equivalencia completa con producción. No se borraron datos de desarrollo ni capturas anteriores para lograr el aislamiento.

Evidencia local, con dependencias externas stubbeadas y `PASS_CALL_CAP=0`: `stage2_journey_a_runner_test`, `stage2_run_budget_test` y `validation_capture_test`. 30 corridas, 271 aserciones, 0 fallos, 0 errores y 0 skips. `ruby -c` del runner quedó correcto. RuboCop no reportó ofensas. `git diff --check` quedó limpio.

Veredicto de este diff: `AISLAMIENTO_LOCAL_PUBLICADO`. Implementado: el aislamiento del proceso de validación. Desplegado: no. La imagen evidenciada sigue siendo `6ca7788`. Revalidado: no. Pendiente: la revisión de este diff. La pasada no empieza desde aquí. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. La etapa 3 no empieza.

#### Pasada local aislada (2026-10-08)

Sobre `10dda24`, con el cupo de esta única corrida todavía abierto: `PASS_CALL_CAP` 42, techo de etapa 2 en 148, reserva de etapa 3 en 42 y techo global en 190. El histórico de entrada siguió en 106 llamadas y US$0,214838. `AWS_MAX_ATTEMPTS=1` en ese proceso limita los reintentos. No prueba que un error haya ocurrido antes de enviar la solicitud. Una fila `BedrockQuery` demuestra una llamada registrada; no demuestra por sí sola un intento remoto que falló antes de crear esa fila. Sin despliegue y sin escribir producción. La etapa 3 no empieza.

Rails local. Bases `smart_deal_stage2_isolated`, `smart_deal_stage2_isolated_cache` y `smart_deal_stage2_isolated_cable`, host local. La cola siguió en `smart_deal_development_queue` y no recibió trabajos: el tracker corrió en línea. El filtro, armado con el código de producto antes de la primera llamada, fue el de la captura: cuenta 1, o la cuenta 3 sin foto de campo y sin `manual_corpus=account`, o `manual_corpus=general`. Knowledge Base `Y7RZWMFJSR`, región `us-east-1`, modelo `global.anthropic.claude-haiku-4-5-20251001-v1:0`. Sin pin. Una sesión, episodio `ep_dfae85c99c49b0a7` desde el turno 2. SHA de git `10dda240cb71533518ace53a1ef24b58ede06be2`; el cupo abierto estaba en el árbol de trabajo y este cierre lo deja en 0.

La disponibilidad devolvió el Elemont MH, páginas 1 y 7, y también Thyssen CMC-3. Aurora reanudó una vez, 15 segundos. Esa repetición no creó fila `BedrockQuery`. Ninguna búsqueda del episodio devolvió el Elemont. Devolvieron, entre otros, KONE MonoSpace, CEA15+, CEA51FB, VF5 y CMC4. Todas las filas registradas quedaron aceptadas: 199 por corpus compartido y 45 por la cuenta del visor. Ninguna fue rechazada. Recuperar esos manuales no los hace aplicables al Elemont. Desde el turno 7 la captura muestra dos `Retrieve` híbridos de la misma consulta, k=20 y k=8, con el mismo filtro. El costo de `Retrieve` y del embedding no está en las 26 filas.

El turno 1 buscó sin pedir fabricante, modelo ni controlador. El intérprete devolvió `transport_error` y no escribió percepción: la traza no guardó la clase de la excepción. El episodio no conservó Elemont MH ni CEA15. No los convirtió en `CEA15+`. El objetivo pasó a ser «El display muestra código 8» y, tras la corrección, quedó en «El display muestra».

La corrección 8 → 18 sí se aplicó en el turno 5. El código 18 quedó como hecho y el 8 como no vigente. La planta 1, la reapertura, la guía sin obstrucción, el LED 7 y el clic siguieron en las observaciones. «Sigue igual» y «¿Y ahora?» permanecieron en el mismo episodio. El historial se recortó a 20 mensajes desde el turno 10 y esos hechos siguieron.

La corrección de planta no reemplazó la observación anterior. El turno 13 emitió `correct`, la percepción recuperó «la cabina está detenida cerca de planta 2» y el delta solo agregó esa frase: `removed` quedó vacío. El prompt del turno 14, 2376 caracteres en el guidance, lleva las dos plantas en `Obs:` y solo saca el código 8 en `Not current`. La respuesta dijo planta 2. El estado y la consulta siguieron tratando la planta 1 como vigente.

El turno 5 dijo que el código 18 típicamente indica una falla de cierre, sin una cita del Elemont. El turno 1 pidió mirar terminales del imán. Esas frases no salen del reporte ni de un chunk compatible. El turno 14 nombra solenoide, motor o trinquete como el mecanismo del clic, resume lo comprobado y pide observar desgaste o desalineación en el marco. No cita el Elemont, no declara la puerta reparada y no es éxito documental. La disponibilidad ya había mostrado que el manual es recuperable.

Consumo de modelo en `BedrockQuery`: 13 análisis y 13 generaciones `rag_global`, 26 llamadas, US$0,060975. Acumulado con el histórico: 132 llamadas y US$0,275813. Quedan 16 dentro de 148. `PASS_CALL_CAP` vuelve a 0 y no abre otra pasada. La etapa 3 conserva 42 dentro de 190. Tope US$2,50. No hay rollup de `bedrock_daily_costs` de esta corrida.

Evidencia: `tmp/stage2_journey_a/runs/20261008T214541Z-session-1/` y la exportación `tmp/stage2_journey_a/exports/20261008T215032Z/`. 101 `pilot_events`. Un proceso que no carga el runner sigue en las bases de desarrollo: 4 cuentas, 25 documentos, 8 usuarios, 57 sesiones, 2649 consultas y 5173 eventos.

Faltan 202 filas del catálogo. El recorrido es el runner, no `POST /rag/ask`. Esta corrida no demuestra equivalencia completa con producción.

Veredicto: `BLOQUEADO`. No es `EPISODIO_VALIDADO`. La falla demostrada es la planta 1 vigente después de la corrección, más significados y terminales que no están en la evidencia. La búsqueda del episodio sin el Elemont, con el manual recuperable en la disponibilidad, impide por sí sola el éxito documental. No se repara ni se repite desde este cierre. La reparación local posterior está en la sección siguiente y no reabre esta pasada. La etapa 3 no empieza.

#### Reparaciones locales sobre la evidencia de la pasada (2026-10-08)

Sobre `aac7ff789e5d42a918ed12c64d2fe43a98cefa0c`. Sin AWS, sin Retrieve, sin intérprete real, sin generación real, sin journey y sin despliegue. `PASS_CALL_CAP` sigue en 0. El histórico sigue en 132 llamadas y US$0,275813. No se asigna costo al intento que no creó fila. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. La etapa 3 no empieza.

Reparado y probado en local, con la percepción y el estado capturados:

- Planta. El primer punto es `WorkContextReducer#retracted_phrases`. La etiqueta normalizada perdía el punto y capturaba «planta 1 no», así que el turno 13 no retiraba la observación. La retracción se corta en la puntuación de la oración. `excise_retracted_phrase` quita solo la cláusula que contiene la frase y conserva el resto unido por « y ». Planta 2 queda vigente. Planta 1 deja de estarlo. «No hay personas dentro», la puerta, la reapertura, la guía, el LED, el clic y el código 18 se conservan. El estado, la consulta y el prompt coinciden después de guardar y releer.
- Objetivo residual. El primer punto es `SlotRejection.excise_text` al negar el código 8 sobre «El display muestra código 8». El resto no es un problema. `adopt_problem_goal!` toma una observación que sí lo es. Informar o corregir un código no convierte ese resto en el objetivo. Un seguimiento o una comprobación no lo sustituye. Un `new_work` explícito sigue abriendo el objetivo nuevo. No se escribe una frase fija del fixture.
- Identificador «clic». El primer punto es `WorkContextReducer#durable_identifier?`. Un identificador mencionado dentro de una observación no se guarda si la etiqueta no tiene dígito. «clic» queda como observación. Elemont MH y CEA15, cuando una percepción válida los trae y no están dentro del síntoma, siguen. Una extracción fallida no escribe fabricante ni modelo.
- Resumen técnico. El primer punto es `TurnPerception#adjust_move`. El modelo marcó el turno 10 como `meta` y `RoutePolicy` respondió «Puedes seguir con lo que ya me contaste.» antes de generar. Un pedido de resumen del problema, o de la observación siguiente, pasa a `follow_up`. Un saludo, un pedido de lo que Danebo necesita y una oferta de foto siguen en `meta`. El episodio se conserva. El generador recibe el problema, las comprobaciones y las correcciones vigentes. El pedido mixto mantiene las dos intenciones.
- Fallo del intérprete. La captura del turno 1 tiene `route_exit` `fallback` / `transport_error` y no tiene `interpreter_raw` ni la clase de la excepción. Esa causa no se recupera. El rescate ahora registra `interpreter_failure` con clase, motivo sanitizado, etapa `converse`, correlación e intento. Los reintentos no cambian. Si el reporte es un síntoma buscable, el fallback conserva el texto literal como objetivo y observación, con la correlación, y no escribe hechos ni identificadores. El turno siguiente ve ese antecedente. No confirma identidad.

Causa aún desconocida: la excepción del turno 1. El límite de reintentos no prueba que la solicitud haya salido del proceso.

Comportamiento del modelo aún no revalidado. Los prompts guardados de los turnos 5, 8 y 12 ya traían la regla de no inventar, la separación del reporte y la regla de hipótesis. «El código 18 típicamente indica…», «el clic indica que el comando de cierre se recibe…» y «clic repetido» están en las respuestas, no en los hechos del episodio. El prompt del turno 14 repite «clic repetido» porque la respuesta anterior entra en el historial como asistente. Un test del prompt no declara corregida esa conducta. No se añadieron filtros de esas frases.

Retrieval documental aún pendiente. La disponibilidad recuperó el Elemont MH y el episodio no lo usó. Faltan 202 filas del catálogo. El recorrido fue el runner, no `POST /rag/ask`.

Evidencia local, con dependencias externas stubbeadas y `PASS_CALL_CAP=0`: `work_context_reducer_test`, `turn_perception_test`, `conversation_session_turn_interpreter_test`, `route_policy_test`, `validation_capture_test`, `query_composer_test`, `session_context_builder_test`, `stage2_run_budget_test`, `stage2_journey_a_runner_test`, `work_context_goal_test` y `companion_guidance_context_test`. 252 corridas, 2512 aserciones, 0 fallos, 0 errores y 0 skips. RuboCop no reportó ofensas en los archivos tocados. `git diff --check` quedó limpio.

Veredicto de este diff: `REPARACIONES_LOCALES_COMPLETADAS`. Implementado: las correcciones locales de arriba. Desplegado: no. La imagen evidenciada sigue siendo `6ca7788`. Revalidado: no. Pendiente: la causa del `transport_error` del turno 1, el cumplimiento del modelo en una pasada real y la búsqueda documental del Elemont. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. La etapa 3 no empieza. Este diff queda en `main` para revisión y no se despliega.

#### Correcciones de la revisión local (2026-10-08)

Sobre `337ea91e843b46983c36c0e5bcf9265c8ec14e48`. Sin AWS, sin Retrieve, sin intérprete real, sin generación real, sin journey y sin despliegue. `PASS_CALL_CAP` sigue en 0. El histórico sigue en 132 llamadas y US$0,275813. No se abre otra pasada. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. La etapa 3 no empieza.

Dos puntos de la reparación anterior quedaron mal cerrados. No cambian filtros, modelos ni presupuesto.

- Observaciones numéricas. `WorkContextReducer#durable_identifier?` guardaba como identificador una frase de la observación si contenía un dígito. «planta 2» y «LED 7 apagado», devueltos a la vez como observación y como assert sin slot, ocupaban plazas de identidad. Un dígito separado no es un designador. La frase sigue en las observaciones. Se conserva el identificador cuando el catálogo o un slot de fabricante, modelo o controlador ya lo registró, o cuando el token es un designador (`CEA15`, `NICE3000`, `Elemont MH`), también si la observación nombra ese equipo. No se escribe fabricante ni modelo si el catálogo no lo confirmó. `known?` no cambia. La ambigüedad y la autorización del catálogo no cambian. `CEA15` no pasa a `CEA15+`. Al guardar y releer, planta, LED y clic no entran en los identificadores.
- Etapa del intérprete. `interpret_turn` rescataba también lo que ocurre después de `converse`, y `interpreter_failure` y `PilotUsageLog` decían siempre etapa `converse` y fallo de transporte. La etapa queda en `prepare`, `converse`, `extract` o `perception`. Solo `converse` clasifica transporte (`timeout`, `throttle`, `transport_error`). Un error local posterior usa `local_error`. El contrato de una herramienta inválida sigue en `invalid_schema`, sin `interpreter_failure`. El motivo se sanitiza igual. La correlación y el intento se conservan. Los reintentos no cambian. Si ya había usage válido, `TrackBedrockQueryJob` se encola una vez y el fallo queda en otro evento. Sin usage no se inventan tokens ni costo.

Evidencia local, con dependencias externas stubbeadas y `PASS_CALL_CAP=0`: `work_context_reducer_test`, `turn_perception_test`, `turn_interpreter_failure_test` y `conversation_session_turn_interpreter_test`. 117 corridas, 1017 aserciones, 0 fallos, 0 errores y 0 skips. RuboCop no reportó ofensas en los archivos tocados. `git diff --check` quedó limpio.

Veredicto de este diff: `CORRECCIONES_LOCALES_COMPLETADAS`. Implementado: las dos correcciones de arriba. Desplegado: no. La imagen evidenciada sigue siendo `6ca7788`. Revalidado: no. Pendiente: la causa del `transport_error` del turno 1, el cumplimiento del modelo en una pasada real y la búsqueda documental del Elemont. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. La etapa 3 no empieza. Este diff queda en `main` para revisión y no se despliega.

#### Pasada local aislada sobre 1570d7d (2026-10-08)

Sobre `1570d7d1be0afb813cf94705649017d90f329177`. Una sola pasada de los turnos 1 a 14. Sesión aislada 2, episodio `ep_4e26498ea955c600` desde el turno 1. Trazas en `tmp/stage2_journey_a/runs/20261008T234453Z-session-2/`. Exportación de esta sesión: `tmp/stage2_journey_a/exports/20261008T234658Z/`. La pasada anterior, `tmp/stage2_journey_a/runs/20261008T214541Z-session-1/`, no se reescribió. Sin pin, sin L3, sin fotos, sin journey B, sin cambio de caso y sin recuperación de casos. Sin segunda pasada y sin reparación durante la corrida. Sin despliegue y sin escritura en las bases Rails de producción. La etapa 3 no empieza.

El cupo de esta corrida estuvo abierto en el árbol de trabajo: `PASS_CALL_CAP` 42, techo de etapa 2 en 174, reserva de etapa 3 en 42 y techo global en 216. El histórico de entrada siguió en 132 llamadas y US$0,275813. El tope de costo siguió en US$2,50. `AWS_MAX_ATTEMPTS=1`. Este cierre deja `PASS_CALL_CAP` en 0. El control del runner ahora suma los intentos de modelo que la captura muestra y que no crearon fila. Una fila sigue siendo una llamada registrada con usage. Un intento sin fila consume cupo y no inventa costo. `Retrieve` sigue fuera de ese cupo. En esta pasada los intentos y las filas coincidieron: 28 y 28. No hubo intento de modelo sin costo determinado.

Rails local. El proceso de la corrida usó `smart_deal_stage2_isolated`, `smart_deal_stage2_isolated_cache` y `smart_deal_stage2_isolated_cable`. La cola siguió en `smart_deal_development_queue` y no recibió trabajos: el tracker corrió en línea. Antes de la primera llamada, el filtro armado con las cuentas 1 y 3 fue cuenta 1, o la cuenta 3 sin foto de campo y sin `manual_corpus=account`, o `manual_corpus=general`. Knowledge Base `Y7RZWMFJSR`, región `us-east-1`, modelo `global.anthropic.claude-haiku-4-5-20251001-v1:0`. Esos valores iban en el proceso. `.env`, credentials, `database.yml`, `cache.yml`, `cable.yml` y las políticas de acceso no se editaron. Un proceso nuevo, sin el runner, vuelve a `smart_deal_development`, `smart_deal_development_cache`, `smart_deal_development_cable` y `smart_deal_development_queue`. Su filtro es cuenta 1, o la cuenta 4 sin foto de campo y sin `manual_corpus=account`, o `manual_corpus=general`. La Knowledge Base habitual de ese proceso es `QGVYLPTEGT`. Conteos: 4 cuentas, 25 documentos, 8 usuarios, 57 sesiones, 2649 consultas y 5173 eventos. `PASS_CALL_CAP` en ese proceso quedó en 0.

La disponibilidad, separada de las búsquedas del episodio, recuperó el Elemont MH, páginas 1 y 7, cuenta 1, y Thyssen CMC-3. Aurora reanudó una vez, 15 segundos. Esa repetición no creó fila `BedrockQuery`. Cada turno del episodio hizo un `Retrieve` híbrido, k=8, con el mismo filtro. La compuerta aceptó los 8 resultados: corpus compartido o cuenta del visor. El conjunto citado de la publicación quedó vacío. Ningún resultado del episodio fue el Elemont. Aparecieron, entre otros, KONE MonoSpace, `manual-cea15p`, VF5, BL6, CMC4 y Fuji Yida. Aceptar esos manuales, ver un score o autorizar el acceso no los hace aplicables al Elemont MH. El prompt de guidance declara la identidad sin confirmar, retira el contenido de los manuales recuperados y prohíbe inventar el significado de un código. El costo de `Retrieve` y del embedding no está en las 28 filas.

El turno 1 interpretó y buscó. El objetivo quedó «la puerta 1 no termina de cerrar el imán no magnetiza». Elemont MH y CEA15 quedaron como identificadores de procedencia `user`. El fabricante Elemont quedó como hecho de catálogo. El prompt dice que la identidad no está confirmada. CEA15 no pasó a CEA15+. El código 8 pasó a 18 en el turno 5: el 18 es el hecho vigente y el 8 queda en `Not current`. El objetivo no se degradó. La guía quedó en la observación «no veo una obstrucción». El LED 7 apagado, el clic y la reapertura siguieron. Ubicación, LED y clic no ocuparon plazas de identidad.

«Sigue igual» y «¿Y ahora?» permanecieron en el mismo episodio, también con el historial recortado a 20 mensajes. El turno 10 recibió el resumen del problema y una observación siguiente: el intérprete había marcado `meta` y la regla lo pasó a `follow_up`. El turno 14 añadió «No lo sé» porque la respuesta anterior pedía el estado de un conector que el fixture no trae. No se inventó esa comprobación.

La planta 1 salió de las observaciones y se conservó «no hay personas dentro». Planta 2 no quedó en el episodio. La percepción del turno 13 traía «La cabina está detenida cerca de planta 2, no de planta 1» y `drop_contained_phrases` soltó el fragmento de planta 2. El delta agregó solo «no hay personas dentro» y quitó la frase de planta 1. El `Obs` del prompt del turno 14 no tiene planta. La frase de la corrección sigue en el historial reciente, y por eso la respuesta nombra planta 2. La consulta del turno 14 ya no la lleva.

El turno 8 dijo que el código 18 en esta placa típicamente relaciona falta de retención. Los turnos 6, 11, 13 y 14 también atribuyen al código 18 o al LED 7 una falla de cierre, de señal o de alimentación. El turno 12 convirtió el clic en «clic repetido». El turno 13 pide mirar corrosión, soltura o quemadura en el conector del imán. Esas frases están en las respuestas. El prompt guardado les prohíbe inventar ese significado y mandar a un terminal desconocido. El turno 9 nombró KONE MonoSpace como referencia no aplicada a este trabajo y no enseñó su procedimiento. El turno 14 resume parte de lo comprobado y pide otra luz en otros LED. No cita el Elemont, no declara la puerta reparada y no dice qué documentación falta. No es una respuesta documental útil ni un escalamiento fundamentado.

Consumo registrado en `BedrockQuery` de esta sesión: 14 análisis y 14 generaciones `rag_global`, 28 llamadas, 41096 tokens de entrada, 5373 de salida, US$0,067961. Intentos de modelo sin fila: 0. Acumulado con el histórico: 160 llamadas y US$0,343774. Quedan 14 dentro de 174. `PASS_CALL_CAP` vuelve a 0. La etapa 3 conserva 42 dentro de 216. Tope US$2,50. No hay rollup de `bedrock_daily_costs` de esta corrida.

Comparado con `20261008T214541Z-session-1`: el turno 1 ya interpreta y conserva el problema, Elemont MH y CEA15; el objetivo ya no se vuelve el código; el 8 pasa a 18; el turno 10 ya resume; la planta 1 ya no queda vigente. Sigue el ranking del episodio sin el Elemont, con el manual recuperable en la disponibilidad. Siguen los significados de código y de LED sin documentación aplicable, y aparece «clic repetido». La planta 2, que aquella pasada agregaba al lado de la planta 1, en esta no queda guardada.

Faltan 202 filas del catálogo. El recorrido es el runner, no `POST /rag/ask`. Esta corrida no demuestra equivalencia completa con producción.

Veredicto: `BLOQUEADO`. No es `EPISODIO_VALIDADO`. La falla demostrada es la planta 2 fuera del episodio después de la corrección, más significados, un terminal y un clic repetido que no están en la evidencia. La búsqueda del episodio sin el Elemont, con el manual recuperable en la disponibilidad, impide el éxito documental. No se repara ni se repite desde este cierre. La etapa 3 no empieza.

#### Diagnóstico consolidado y reparación local posterior (2026-10-08)

**Base y límite.** Inicio `0cfd7297597d38d6d3dc31d627a927e6545168dc`, árbol limpio; `1570d7d1be0afb813cf94705649017d90f329177` fue la base de la última corrida. El único cambio posterior al primero es el cierre del runner y el presupuesto en `0cfd729`. Evidencia: `tmp/stage2_journey_a/runs/20261008T234453Z-session-2/{manifest.json,trace.json,availability.json,filter.json}` y `tmp/stage2_journey_a/exports/20261008T234658Z/`. La corrida anterior sirve solo de contraste. Esta revisión no ejecuta otro journey, AWS, intérprete, Retrieve ni generación; `PASS_CALL_CAP=0`. El histórico queda en 160 llamadas registradas y US$0,343774, sin consumo atribuible a estas pruebas.

**Matriz del episodio.** Los catorce turnos quedaron en `ep_4e26498ea955c600`. En cada turno la captura muestra un `Retrieve` híbrido, k=8, con el mismo filtro de cuentas 1/3 y corpus general, seguido de `generate_text` directo. No hubo `RetrieveAndGenerate`; los ocho chunks recuperados por turno pasaron la compuerta de acceso, ninguno fue Elemont, y no se publicaron citas. El runner no ejecuta `RagController#attach_manual_suggestion`, por lo que la traza no contiene tarjetas candidatas. `DocumentDiscovery` puede ofrecer la entrada Elemont MH por designador sin escribir identidad ni pin, como comprueba una prueba local independiente. La tabla resume la entrada literal y la salida cruda; el detalle completo de percepciones, consultas, prompts y chunks está en `trace.json`.

| Turno | Entrada del técnico | Percepción / estado tras relectura | Consulta, documentación y respuesta |
| --- | --- | --- | --- |
| 1 | «Elemont MH con placa CEA15; la puerta 1 no termina de cerrar y el imán no magnetiza. ¿Qué reviso?» | `report`; objetivo de cierre e imán, fabricante Elemont de catálogo, identificadores de usuario Elemont MH y CEA15. | Busca la entrada literal; recupera KONE, KOYO, CEA15+ y VF5; guidance sin cuerpos; propone hipótesis condicionales y pregunta por posición del imán. |
| 2 | «El display muestra código 8.» | `report`; añade observación del display; todavía no hay código tipado como hecho. | Consulta con objetivo e identificadores; CEA15+ y manuales ajenos; respuesta atribuye al 8 una posible falta de energía o señal sin manual aplicable. |
| 3 | «La cabina está detenida cerca de planta 1 y no hay personas dentro.» | `report`; guarda ubicación y ocupación juntas. | Consulta incluye ambas; documentación ajena; respuesta conserva el reporte pero vuelve a inferir significado del 8. |
| 4 | «La puerta llega al marco, pero vuelve a abrir.» | `report`; añade reapertura. | Consulta conserva el problema; documentación ajena; respuesta propone retención o bloqueo sin fuente compatible. |
| 5 | «No, leí mal: era código 18, no 8.» | `correct`; código 18 vigente, 8 rechazado, objetivo intacto. | Consulta retira 8 y mantiene síntoma; CEA15+ y manuales ajenos; respuesta reconoce la corrección. |
| 6 | «Ya comprobé visualmente la guía de la puerta; no veo una obstrucción.» | `report`; conserva «no veo una obstrucción». | Consulta incluye código 18 y comprobación; manuales ajenos; respuesta vuelve a atribuirle un significado al código. |
| 7 | «El LED 7 está apagado. ¿Qué indica para esta placa?» | `follow_up`; LED como observación, no identidad. | Consulta contiene LED 7; manuales ajenos; ninguna fuente aplicable define su significado. |
| 8 | «Al pedir cierre se oye un clic, pero no termina de cerrar.» | `report`; guarda un clic, no repetición. | Consulta incluye clic, LED y código; manuales ajenos; respuesta lo atribuye a relé/solenoide y vuelve a interpretar el 18. |
| 9 | «Sigue igual. ¿Y ahora?» | `follow_up`; mismo episodio, sin nueva observación. | Consulta recompone el estado; manuales ajenos; nombra KONE como referencia no aplicada. |
| 10 | «Resúmeme lo que llevamos y dime qué observación segura sigue.» | `meta` crudo, normalizado a `follow_up`; objetivo, código y observaciones persisten. | Consulta técnica recompuesta; resumen útil de lo reportado, seguido de inferencia sobre el clic sin sustento. |
| 11 | «Hice esa revisión: sigue el clic y la puerta no termina de cerrar.» | `follow_up`; añade persistencia del clic y cierre incompleto. | Consulta conserva continuidad; documentación ajena; respuesta afirma comportamiento de circuito sin fuente aplicable. |
| 12 | «Sigue igual.» | `follow_up`; sin hecho nuevo. | Consulta recompone el episodio; respuesta transforma el clic reportado en «clic repetido». |
| 13 | «Corrijo algo de antes: la cabina está detenida cerca de planta 2, no de planta 1.» | `correct`; el intérprete entregó la frase completa. `drop_contained_phrases` descartó la sustitución corta; el reductor retiró planta 1 y dejó solo «no hay personas dentro». | La consulta aún contiene planta 2 por el texto actual; el prompt de estado ya no la contiene. La respuesta la menciona por el turno reciente y añade LED/conector con funciones no documentadas. |
| 14 | «¿Y ahora? No lo sé.» | `answer_pending` crudo, normalizado a `follow_up`; planta 2 sigue ausente del episodio persistido. | Consulta sin planta 2; el prompt la recibe solo desde historial reciente. Respuesta la repite, pero no informa la carencia documental ni prepara escalamiento. |

**Decisión por línea.**

| Línea | Clasificación y evidencia | Decisión |
| --- | --- | --- |
| Continuidad | Defecto determinista solo para la corrección de ubicación: turno 13 pierde planta 2 en `episode_delta`, y la consulta del 14 la omite. Objetivo, Elemont MH, CEA15, código 18 y rechazo de 8 sí persisten. | Reparar la sustitución de observaciones; verificar persistencia, consulta y prompt con la salida cruda capturada. |
| Correcciones | Defecto determinista: el fragmento vigente estaba contenido en la frase cruda con cola retractiva, y la deduplicación eligió esa frase. El reductor quitó correctamente el valor anterior y conservó ocupación. | Eliminar la cola retractiva de esa observación antes de deduplicar; conservar las demás observaciones y la procedencia. Cubrir «no de» y «no del» como formas gramaticales, no como vocabulario del caso. |
| Recuperación | Evidencia insuficiente para un defecto de ranking: disponibilidad devuelve Elemont p. 1/7; catorce búsquedas del episodio no lo incluyen. Acceso autorizado no implica aplicabilidad. El runner no captura sugerencias del controlador. | No cambiar ranking, filtro ni permisos. Proponer captura de candidatos/resolución y una única validación real autorizada. Un candidato no confirma la identidad ni aplica su contenido. |
| Respuestas sin sustento | Incumplimiento del modelo: código 18, LED 7, «clic repetido» y componentes se afirmaron o insinuaron sin chunk aplicable. Los prompts de guidance retiraron cuerpos ajenos y prohibieron significados de códigos y terminales; no hay evidencia de que una respuesta anterior del asistente entrara como hecho en esos prompts. | Mantener bloqueada la etapa. La instrucción del prompt no demuestra cumplimiento; pedir en la validación real una respuesta que diga qué falta y llegue a una observación decisiva o un escalamiento fundado. No derivar una causa física del plano Elemont. |
| Intentos | Defecto determinista de telemetría: `stage2_unbilled_attempts` veía un fallo del intérprete, pero no una respuesta correcta cuya escritura de `BedrockQuery` falló. | Capturar `interpreter_attempt` justo antes de `converse`; reconciliar por correlación contra filas, contando una vez el intento con o sin fila, sin estimar costo. |

**Cambios locales y comprobaciones.** Ese cierre quedó en `26a88abfdf2d727a952de3cf48d1c2e80b25ba87`. `TurnPerception` conserva la frase sustituta cuando el intérprete entrega también la retractación; `WorkContextReducer` reconoce «no del»; `TurnInterpreter` captura el intento antes de invocar al cliente; el runner lo contabiliza aunque el registro de usage falle. La sección siguiente revisa ese cierre y no lo da por suficiente. `test/fixtures/files/field_companion/journey_a_interpreter_raw_20261008.json` contiene solo las 14 entradas y salidas crudas del intérprete capturadas; su replay stubbeado comprueba un único episodio hasta el turno 14, relectura, objetivo, identidad, código vigente/rechazado, planta 2, ocupación, LED, clic, consulta y bloque de prompt. Otras pruebas cubren variantes gramaticales, descubrimiento sin pin y conteo con/sin fila. `Rag::DocumentDiscovery` no requiere identidad persistida para ofrecer un designador; la prueba comprueba que la tarjeta no escribe identidad ni pin. Suites focalizadas tras el replay: 137 corridas, 1.189 aserciones, sin fallos. Suite completa anterior al replay, con credenciales AWS ficticias y salida HTTP cerrada: 4.440 corridas, 26.165 aserciones, 3 fallos, 0 errores, 191 skips. Los tres fallos se repitieron aisladamente en una copia sin cambios de `0cfd729`: dos expectativas de cero generaciones en `BedrockRagServiceKnowledgeScopeTest` (líneas 63 y 293) y `owns_query=false` para VF5 en `Rag::FieldJourneyTest` (línea 94). Son preexistentes a esta intervención; no se modificaron sus rutas. RuboCop y `git diff --check` se vuelven a comprobar en el cierre. Ninguna prueba local establece que el modelo acate el prompt o que el Elemont aparezca en el retrieval real. La siguiente pregunta de validación, **sin ejecutar ahora**, es: «¿El episodio completo conserva las correcciones y llega a un siguiente paso sustentado o un escalamiento útil, con el retrieval y el modelo reales?». Será una sola ejecución longitudinal autorizada de Journey A con capturas de estado, recuperación y generación. Hasta entonces: **ETAPA 2 BLOQUEADA; no `EPISODIO_VALIDADO`**.

#### Revisión de 26a88ab y enfoque siguiente (2026-10-08)

**Límite de esta revisión.** Revisado sobre `26a88abfdf2d727a952de3cf48d1c2e80b25ba87`, entonces un commit por delante de `origin/main` y con el árbol limpio. Base de la última corrida real: `1570d7d1be0afb813cf94705649017d90f329177`. Evidencia: `tmp/stage2_journey_a/runs/20261008T234453Z-session-2/` y `tmp/stage2_journey_a/exports/20261008T234658Z/`. No hubo otra pasada, AWS, Retrieve, intérprete ni generación. `PASS_CALL_CAP` sigue en 0. El histórico sigue en 160 llamadas registradas y US$0,343774. Esta sección no cambia modelos, filtros, permisos ni presupuesto. No implementa el enfoque: lo deja decidido para la siguiente intervención de código.

**Qué queda de 26a88ab.** Las 137 pruebas focalizadas de ese cierre vuelven a pasar (1.189 aserciones, 0 fallos). RuboCop sobre los cuatro archivos de lógica y runner no reporta ofensas. `git diff --check` entre `0cfd729` y `26a88ab` está limpio. El conteo de intentos queda cerrado: `interpreter_attempt` se escribe antes de `converse`, y el runner cuenta una invocación por correlación exista o no la fila `BedrockQuery`, sin inventar costo. Esa pieza no se reabre.

| Fallo | Turnos | Causa comprobada | Decisión |
| --- | --- | --- | --- |
| Conteo de intentos | Telemetría del runner | El intérprete podía responder bien y quedar sin fila si fallaba el registro de consumo. | Cerrado en `26a88ab`. No se toca. |
| Planta 1→2 en la frase del fixture | 13 y 14 | La frase larga con cola «, no de planta 1» ganaba a la sustitución corta. El reductor quitaba planta 1 y no guardaba planta 2. | La frase capturada ya se conserva. El contrato de corrección sigue roto en otras formas gramaticales. |
| Identidad desconocida con Elemont dicho | 1 a 14 | El técnico asertó «Elemont MH». El catálogo solo normalizó la marca, y el hecho se guardó `source: catalog`. `known?` exige `user` o `photo`. | Defecto de procedencia. Decisión: `user` cuando el técnico aserta el span y el catálogo solo normaliza. |
| Respuesta sin sustento | 8, 12, 13 y 14 | El prompt de generación prohíbe inventar el código y a la vez manda interpretar, hipotetizar y pedir otra comprobación en cada turno. No hay salida de escalamiento. | Diseño más incumplimiento del modelo. El modelo sigue por validar; el prompt contradictorio se repara. |
| Elemont ausente del top 8 | 1 a 14 | La disponibilidad por título recupera las páginas 1 y 7. Esas páginas son un plano de tablero y no nombran puerta, imán, código 18 ni LED. El filtro no rechazó el documento. | Evidencia insuficiente para un defecto de ranking. No se cambia la consulta, el filtro ni los permisos. |

**Contrato de corrección, no la oración del fixture.** Un sondeo local, con el código de `26a88ab` y sin escribir pruebas en el repositorio, recorrió el mismo reductor con variantes. La frase del fixture ya guarda «la cabina está detenida cerca de planta 2» y conserva «no hay personas dentro» y el LED. Estas otras no:

- «En realidad la cabina está cerca de planta 2, no de planta 1.» El reductor retira planta 1 porque ve «no de», y la percepción no conserva el reemplazo porque exige «corrijo». Planta 2 no queda.
- «Me equivoqué: … no en planta 1.» y «Corrijo: … y no en planta 1.» No coinciden con «no de». Quedan planta 1 y planta 2 a la vez.
- «Corrijo: el LED que está apagado es el 5, no el 7.» La percepción lo pasa a `unclear` y el LED 7 sigue vigente.

Tres lectores deciden por su cuenta qué es una corrección: `TurnPerception#explicit_observation_replacement`, `WorkContextReducer#retracted_phrases` y `CompanionGuidanceContext::CORRECTION_CUE`. El reductor puede borrar el valor anterior sin que la percepción haya guardado el nuevo.

Reparación: un solo objeto, `Rag::ObservationCorrection`, que dado el turno y las observaciones o aserciones del intérprete devuelve lo asertado y lo retractado. Una gramática, la misma pista que ya usa el guidance (`corrijo`, `me equivoqué`, `en realidad`, `leí mal`, `no es`, `no era`, `no de`) y una cola retractiva hasta el punto: `no`, seguido o no de `de`, `del`, `en`, `el` o `la`. Si el intérprete ya trae el span asertado, ese span es el ancla. `TurnPerception` lo usa en `recover_stated_correction` y publica las retracciones. `WorkContextReducer` consume esas retracciones y deja de volver a leer el turno. Invariante: no se quita una frase retractada si la frase asertada no quedó guardada; si falta, se añade. Se conservan la ocupación, los calificadores y la corrección de código 8→18, que ya funciona. No se agregan listas de palabras del caso.

**Procedencia de la identidad declarada.** Decisión tomada: si el técnico asertó el span y el catálogo solo normaliza la etiqueta del mismo slot, la fuente es `user`, con una nota `catalog_normalized`. La fuente `catalog` queda para el hecho que el catálogo añade y el técnico no dijo, por ejemplo un designador `CEA15+` que arrastra un fabricante. `CEA15` no pasa a `CEA15+` ni a `CEA15P`. No hay pin silencioso ni ampliación de permisos. El bloqueo que ya impide adoptar un controlador cuando el fabricante vino solo del catálogo se mantiene. El bloque de problema etiqueta `(technician)` cuando la fuente es `user`.

Efecto esperado, todavía no implementado: `EquipmentIdentity#known?` pasa a verdadero en el turno 1 de este episodio. La ruta entra en `document_identity_scope_result`. Sin chunk compatible, el guidance usa el modo conocido: no hay procedimiento de fabricante aplicable y se sigue con el problema y el razonamiento de campo. Hoy el prompt del turno 14 dice a la vez `Manufacturer: Elemont (catalog)` y `The equipment identity is not confirmed`, y cada turno recibe la orden de pedir una comprobación y de no detenerse porque falte el manual. Esa tensión es la presión que produjo «el código 18 en esta placa típicamente…» y «clic repetido». Las pruebas que hoy tratan todo `catalog` como identidad no conocida se ajustan para distinguir normalización de hecho añadido. Los criterios de aceptación de este plan no cambian.

**Salida útil sin documentación compatible.** Decisión tomada: estado y prompt, sin otra llamada de modelo. Un contador determinista de estancamiento sube en un `follow_up` sin observación nueva y cuando la resolución es `unknown` (turnos 9, 12 y 14) y vuelve a cero cuando entra un hecho o una observación. `CompanionGuidanceContext`, en los dos modos y dentro de `MAX_CHARS`, dice que este turno no recuperó documentación aplicable para los identificadores del episodio. Si el catálogo tiene una entrada, la nombra como candidata no recuperada y no confirmada: se puede ofrecer, no se aplica. Esa lectura es `DocumentDiscovery` solo por catálogo, sin `retriever`, sin Bedrock, sin pin y sin escribir identidad. A partir del segundo turno estancado, o ante `unknown`, la instrucción es resumir lo comprobado, decir qué documentación falta y pedir el dato decisivo o escalar con ese resumen. En esa condición se omiten la orden de pedir otra comprobación por rutina y la de no detenerse porque falte el manual. «You may observe, interpret, and hypothesize» pasa a exigir una hipótesis condicional y marcada como tal. La prohibición de inventar significados de código y de terminal ya está en `UNKNOWN_INVENT` y `KNOWN_INVENT`; no se duplica.

El historial del asistente no entra al prompt de generación. `raw_user_turns` solo toma líneas `User:`. Una respuesta anterior no se convierte en hecho por ese camino. El incumplimiento del modelo en los turnos 8 y 12 a 14 sigue siendo incumplimiento: una prueba del texto del prompt no acredita que el modelo lo obedezca.

**Recuperación.** No se restaura la expansión del nombre canónico. No se cambia `top_k`, el filtro ni el ranking. Los chunks de disponibilidad, páginas 1 y 7, identifican el plano del tablero Elemont MH y no contienen el significado del código 18, del LED 7 ni una causa del imán. Recuperar ese plano no cierra el episodio. El runner no llama a `DocumentDiscovery`, así que la traza no puede mostrar si la tarjeta habría aparecido. La reparación de instrumentación es registrar `discovery_cards` después de cada turno, solo por catálogo. Esa llamada no es un intento de modelo y no entra en el cupo.

**Haiku 5.5, aparte y apagado.** El modelo existe en Bedrock desde el 7 de octubre de 2026. El identificador global es `global.anthropic.claude-haiku-5-5`. El pensamiento adaptativo viene activado. El intérprete de Danebo fuerza `tool_choice` y `temperature: 0`, y hoy tiene el identificador de Haiku 4.5 escrito en `TurnInterpreter::MODEL_ID`. `BedrockQuery` no tiene fila de precio para 5.5; usarlo sin esa fila contaría costo cero.

La preparación, sin cambiar el comportamiento por defecto: `TURN_INTERPRETER_MODEL_ID` con Haiku 4.5 como valor ausente; al pedir 5.5, desactivar el pensamiento para que el `tool_choice` forzado siga valiendo; fila de precio antes de cualquier llamada. No se activa en la validación de las reparaciones deterministas. Las catorce salidas crudas ya traen la corrección completa y el span asertado: la pérdida de planta 2 fue del pipeline, no del modelo. Primero una pasada real con 4.5 para medir estas reparaciones. Después, si se autoriza, una pasada del intérprete con 5.5 y su propio presupuesto.

**Validación local de la implementación, cuando se haga.** Primero se reproducen los fallos: las variantes de corrección de arriba, el fabricante declarado que hoy no cuenta como conocido, y la ausencia de salida útil en el turno 14. Después, el replay de `test/fixtures/files/field_companion/journey_a_interpreter_raw_20261008.json` comprueba un episodio, el objetivo, Elemont MH y CEA15, fabricante con fuente `user`, identidad conocida, código 18 vigente y 8 rechazado, planta 2 con ocupación, LED y clic fuera de las plazas de identidad, consulta y prompt coherentes, guidance en modo conocido, y el bloque de salida en los turnos 9, 12 y 14, dentro de `MAX_CHARS`. Suites de percepción, reductor, alcance de identidad, ruta, guidance, replay, runner, fallo del intérprete y precio. RuboCop y `git diff --check`. Sin AWS. El conteo de intentos no se vuelve a abrir.

**Qué no demuestra esa validación local.** Que el modelo deje de atribuir un significado al código 18 o al LED 7. Que el ranking real incluya el plano Elemont. La próxima pregunta, sin ejecutarla ahora, es una sola pasada longitudinal de Journey A con retrieval y generación reales sobre Haiku 4.5: con la identidad declarada reconocida y sin manual compatible, ¿el episodio conserva las correcciones y termina en un paso sustentado o en un escalamiento útil? Hasta esa pasada: **ETAPA 2 BLOQUEADA; no `EPISODIO_VALIDADO`**.

#### Reparación local ajustada (2026-10-08)

Sobre el enfoque de `26a88ab`, sin pasada nueva, sin AWS, sin Retrieve, sin intérprete real y sin generación. `PASS_CALL_CAP` sigue en 0. El histórico sigue en 160 llamadas y US$0,343774. Haiku 5.5 no entra: ni variable de modelo, ni fila de precio. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. La etapa 3 no empieza.

El enfoque anterior se ajustó antes de implementarlo:

- La procedencia `user` exige que la cláusula del técnico declare ese fabricante, modelo o controlador. El `slot_hint` no decide. Una pregunta o una forma dudosa sigue en `catalog` y la identidad no queda conocida. Normalizar la etiqueta dicha no es inferir un hecho: `CEA15` no pasa a `CEA15+`, y el fabricante que el catálogo añade queda en `catalog`. Un fabricante ya declarado no se pisa con esa inferencia.
- Cambiar a modo conocido es un cambio de ruta y de aplicabilidad. No se toma como la causa demostrada de las respuestas inventadas. Las pruebas cubren las dos rutas.
- No hay `stalled_turns`. La comprobación deja de ser obligatoria en cada turno. El resumen de lo comprobado y de la documentación que falta es una respuesta completa. Cuando el turno dice que no sabe, o solo dice `sigue igual` o `¿y ahora?`, la instrucción es resumir, decir qué falta y pedir el dato decisivo o escalar, sin otra comprobación de rutina. Un pedido de resumen no dispara esa salida forzada.
- El prompt no nombra una entrada de catálogo que no se recuperó.
- Las páginas 1 y 7 no alcanzan para decir que el Elemont no tiene contenido de puerta. La comprobación documental ya recuperó la página 5, con «Seguridad Puerta nivel 1». Eso no explica el código 18 ni el LED 7. El ranking no se cambia.
- Las tarjetas del runner son diagnóstico de catálogo, con `uses_current_retrieval: false`. No explican el ranking del turno ni forman parte del guidance.

Implementado en local: `Rag::ObservationCorrection` es la gramática que comparten la percepción y el reductor. No se quita el valor anterior si el reemplazo no quedó guardado. El replay de las 14 salidas crudas conserva el episodio, la planta 2, el código 18 y Elemont como declaración del técnico.

Eso no demuestra que el modelo deje de inventar el significado del código 18 o del LED 7, ni que el ranking real incluya el Elemont. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. La etapa 3 no empieza.

Revisión de `632e5c5`: la cola retractiva aceptaba «no la/los/es» sin separador. Así, «abre la puerta pero no la termina de cerrar» o «no los veo sucios» pasaban a `correct` y retiraban el síntoma. Ahora la cola exige coma, punto y coma, dos puntos o «y», y un núcleo paralelo a la cláusula asertada: la misma palabra principal, o un número frente a otro. Sin paralelo, hace falta una pista explícita. `TechnicalUnderstanding::TOKEN_RE` conserva el «+», así que `CEA15+` escrito vuelve a resolver. Esa pérdida venía de `700d9d0`. Las otras tres fallas preexistentes eran expectativas desactualizadas, no defectos. Las dos de `KnowledgeScope`, desde `e62a4ab`: cero chunks autorizados generan guidance sin cuerpos, y la prueba ahora verifica que el prompt no lleva el cuerpo ajeno. La de `ValidationCapture`, desde `26a88ab`: cada invocación real del intérprete registra `attempt=1`. Suite completa de ese cierre: 4.453 corridas, 0 fallos, 191 skips.

#### Comprobación local de VF5 y de los skips (2026-10-08)

Sobre `01a0fd8`, sin pasada nueva, sin AWS, sin Retrieve, sin intérprete real y sin generación. `PASS_CALL_CAP` sigue en 0. El histórico sigue en 160 llamadas y US$0,343774. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. La etapa 3 no empieza.

**VF5 y VF5+.** El catálogo no se tocó. `VF5` resuelve `:none`. `VF5+` resuelve `:exact` con valor `VF5+` y sin tipo, así que no escribe controlador, modelo ni fabricante. `CEA15` y `CEA15+` repiten esa distinción. La pregunta completa queda en la consulta y «necesitas» no entra. `VF5` no se reescribe a `VF5+`. Con seis palabras y sin resolución de catálogo, la política vigente hace que `VF5` arrastre el objetivo del episodio (`owns_query` verdadero). `VF5+`, por la resolución exacta, no toma esa consulta (`owns_query` falso). No se forzó la misma resolución.

El defecto era el identificador guardado. `ActiveEpisodeTurn::DESIGNATOR_RE` cortaba el «+», y «¿Cómo uso el módulo electrónico VF5+?» persistía `VF5`. El token escrito ahora conserva el «+», y `VF5` no coincide con `VF5+`.

**Skips.** `bin/rails test` dio 4.455 corridas, 0 fallos y 191 skips. El inventario, una fila por test, salió de `Minitest::StatisticsReporter#record`. Esos 191 se parten así:

- 161 de WhatsApp o Twilio, canal dormido del MVP. No se habilitan.
- 21 de carga masiva o del perímetro Climb (ruta T-31 y tipos que no son PDF). Fuera de este recorrido.
- 2 de marcadores de ingesta que Rails ya inyecta. Fuera de este recorrido.
- 1 de compresión JPEG que pide una subida manual por la interfaz. No se puede stubbear sin cambiar el contrato.
- 1 de P2: el espacio irregular de «fuera de servicio» no activa a la vez el perfil de seguridad y la directiva. El cierre está descrito en `regex_characterization_test.rb` y no es el episodio de puertas. No se abre esa migración aquí.
- 5 de foto, fases N2 a N4, en `FieldPhotoAnalysisJobTest`. Identidad aceptada, composición de la consulta y procedimiento ajeno como referencia. Con `N0_CONTRACTS=1` y sin servicios reales: 5 corridas, 107 aserciones, 0 fallos. El gate ya no los ocultaba por una falla: pasan con los stubs locales, y quedan en la suite normal. Sin el flag: esas cinco, más VF5 y CEA15, 8 corridas, 167 aserciones, 0 skips.

Los skips que dependen de un archivo local (Elemont, D5, benchmark visual, artefacto F0) no entraron en los 191: el archivo estaba y el test corrió dentro de las 4.455. El teardown de `BulkUploadsControllerTest` intenta restaurar un método que el skip no llegó a guardar; queda dentro del skip y la suite no lo cuenta como error. Es la ruta de carga desactivada, no este episodio. La suite completa no se repitió después de habilitar las cinco pruebas de foto. Ningún skip que quede impide leer el contrato de texto de Journey A. Sigue sin demostrarse que el modelo no invente el código 18 o el LED 7, ni que el ranking real incluya el Elemont.

#### Auditoría de la pasada aislada (2026-10-09)

**Límite.** Revisión sobre las capturas, el código de `5f69556d614926cf0272539028f4144ef3d3a0da` y el árbol de trabajo. No hubo otra pasada, Retrieve, intérprete, generación, worker, despliegue ni cambio de producto. `PASS_CALL_CAP` del árbol de trabajo queda en 0. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. La etapa 3 no empieza. Esta sección deja una propuesta para revisión. No la autoriza.

**SHA y árbol.** `HEAD` es `5f69556`, «Keep a written plus-sign designator from being stored without it.» Ese commit conserva el «+» al guardar un designador y habilita las pruebas locales de foto que ya pasaban. No contiene el cierre presupuestario de esta pasada. El manifiesto de la corrida registra ese SHA y, en el árbol con el que corrió, un cupo abierto de 28. El diff sin commit posterior cierra ese cupo. Las constantes comprometidas siguen en 160 llamadas, US$0,343774, techo de etapa 2 en 174, techo global en 216 y `PASS_CALL_CAP` 0. No se atribuye el árbol entero al SHA.

**Entorno de la pasada.** Rails local. Bases `smart_deal_stage2_isolated`, `smart_deal_stage2_isolated_cache` y `smart_deal_stage2_isolated_cable`. La cola siguió en `smart_deal_development_queue` y no recibió trabajos. Cuentas 1 `danebo-legacy` y 3 `danebo-pilot-elevator`. Documentos locales 213 Elemont MH (`dcc8e046-037d-48a6-8913-1992aed28507`) y 207 `manual-cea15p` (`9a4fa817-b9e8-4a9e-ae83-526c0731e603`), ambos `tenant_private`. Catálogo: 204 entradas, 2 enlazadas, 202 ausentes. Knowledge Base `Y7RZWMFJSR`, región `us-east-1`, modelo `global.anthropic.claude-haiku-4-5-20251001-v1:0`. Sin pin. Filtro: cuenta 1, o la cuenta 3 sin foto de campo y sin `manual_corpus=account`, o `manual_corpus=general`. Este entorno no es producción. Esta auditoría no supone el estado de RDS ni lo repara.

**Consumo.** Sesión aislada 3, episodio desde el turno 1. Trazas: `tmp/stage2_journey_a/preflight/20261009T114629Z/natural.json`, `tmp/stage2_journey_a/runs/20261009T114733Z-session-3/` y `tmp/stage2_journey_a/exports/20261009T114941Z/`. 14 análisis y 14 generaciones `query_direct`: 28 llamadas, 41010 tokens de entrada, 7666 de salida, US$0,079340. Intentos sin fila: 0. Acumulado: 188 llamadas y US$0,423114. `Retrieve` y el embedding no están en esa cifra. No se reconcilió `bedrock_daily_costs`. El árbol de trabajo deja el histórico en esas 188 llamadas y US$0,423114, el techo de etapa 2 en 188, la reserva de etapa 3 en 42 y el techo global en 230. `PASS_CALL_CAP` 0. El tope de costo sigue en US$2,50. Ese cierre no abre otra pasada.

**Contraste con la sesión 2** (`20261008T234453Z-session-2`). Allí el fabricante Elemont quedó `source: catalog`, la generación no entró en `document_identity_scope` y la planta 2 no quedó en el episodio. En la sesión 3 el fabricante quedó `source: user` con la nota `catalog_normalized`, la ruta fue `document_identity_scope` en los 14 turnos, el código 18 quedó vigente, el 8 quedó rechazado, la planta 2 quedó vigente, la planta 1 salió y «no hay personas dentro» se conservó. El objetivo, Elemont MH, CEA15 y las comprobaciones siguieron después de que el historial se recortara a 20 mensajes, desde el turno 11. El turno 10 resumió lo reportado. Esas reparaciones muestran efecto y se mantienen.

**Lo que la sesión 3 no cerró.** Cero apariciones de Elemont en los 14 retrieves del episodio. Los ocho resultados de cada turno pasaron la compuerta de acceso y la política los marcó `reference_only` / `other_equipment`, con el cuerpo reemplazado. Citas publicadas: vacías. Las respuestas atribuyen funciones al código 18, al LED 7 y al clic, y piden mediciones en terminales. Varias adaptaciones «No lo sé» no detuvieron esa petición.

##### A. Identidad y selección documental

`EquipmentIdentity#known?` es verdadero cuando un hecho de fabricante o de modelo tiene valor y su fuente está en `DocumentIdentityScope::NEEDLE_SOURCES` (`user` o `photo`). Un controlador, un código, un identificador suelto o una fuente `catalog` no alcanzan. En esta pasada el técnico asertó «Elemont MH». `TurnPerception#declared_source` dejó el fabricante en `user` con `catalog_normalized` porque el catálogo solo normalizó la etiqueta dicha. `known?` quedó verdadero desde el turno 1. CEA15 quedó como identificador `user`, sin hecho de modelo ni de controlador, y sin pasar a `CEA15+`.

Ese `known?` cambia la ruta y la generación. `document_identity_scope_result` solo entra si la identidad es conocida. El retrieve de esa ruta usa el filtro abierto de la cuenta, HYBRID y k=8. No recibe URIs de documento. Después, `DocumentIdentityScope.apply` compara agujas (`Elemont`, `Elemont MH`, `CEA15`) con `canonical_name`, `original_filename` y `section_identity`. Sin pin, `focus_membership` es nil. Un chunk que no contiene una aguja como palabra entera queda `reference_only`. Los 112 resultados de la sesión cayeron ahí. `known?` no acota el índice antes de buscar y no demuestra que un manual aplique. El estado `known` de un hecho tampoco: significa que el slot tiene un valor.

El vínculo real es el de `KnowledgeScopePolicy.bind_catalog_candidate`: el `document_uid` del catálogo y la clave canónica del objeto tienen que coincidir en una sola fila autorizada para el visor. En esta base eso puede ocurrir con las filas 213 y 207. Las otras 202 entradas no tienen fila física aquí. Su ausencia no dice que falten en el índice de producción; dice que esta base no puede resolverlas a un `KbDocument`. El chunk del Elemont recuperado por título vive bajo el prefijo `121bfffe…` y el PDF `Montacargas 2N Temporizado-1 (1).pdf`. La compuerta de retrieve no compara ese id de chunk con `document_uid`.

`DocumentDiscovery#exact_entries` no usa la comparación que conserva el «+». Usa `FollowupQueryRewriter.normalize_label`, que lo elimina. «CEA15+» queda `cea15` y la frase del turno 1 lo incluye. Por eso la tarjeta diagnóstica del turno 1 ofrece `manual-cea15p` con etiqueta `EXACT_DESIGNATOR` junto con «Elemont Montacargas Hidraulico Modelo MH». El designador de catálogo de esa fila es `CEA15+`, marca Controles S.A. `CEA15`, `CEA15+` y `CEA15P` siguen siendo distintos en `DocumentIdentityCatalog#designator_label` y en el guardado de `5f69556`. El descubrimiento de tarjeta no heredó esa distinción. Las tarjetas de los turnos 2 a 14 salieron vacías: el runner llama a `DocumentDiscovery` con el texto enviado de ese turno, sin sesión y sin retriever. Esos textos ya no traen `MH` ni `CEA15`. La tarjeta no escribe pin ni identidad.

Lo que estas dos filas permiten afirmar: el visor de la cuenta 1 puede enlazar el designador `MH` de Elemont con el documento 213, y el designador `CEA15+` con el documento 207, si la comparación conserva el signo. No permiten afirmar una relación entre la placa dicha `CEA15` y el manual `CEA15+`, ni resolver el resto del catálogo.

##### B. Retrieval

| Consulta | Texto | k | Filtro | Elemont |
| --- | --- | --- | --- | --- |
| Natural, preflight | La frase del turno 1, 97 caracteres | 8, HYBRID | El de la sesión | No. Ocho chunks. El archivo marca `RETRIEVAL_EMPTY` porque `elemont` es falso, no porque el retrieve viniera vacío. |
| Disponibilidad | `Elemont Montacargas Hidraulico Modelo MH` | 5, HYBRID | El mismo | Sí. Página 1, score 0,9919; página 7, score 0,5. También Thyssen CMC-3. |
| Turno 1 del episodio | La misma frase natural | 8, HYBRID | El mismo | No. Mismo orden que el preflight: KONE 375, KONE 446, KOYO 131, `manual-cea15p` 84, VF5 13 y tres KONE más. |
| Turnos 2 a 14 | `QueryComposer`: turno, código, identificadores, fabricante, observaciones y objetivo. 99 a 391 caracteres, bajo el tope de 442. | 8, HYBRID | El mismo | No. 17 documentos distintos, entre ellos KONE, `manual-cea15p`, VF5, BL6, CMC4 y Fuji Yida. |

La diferencia verificada entre la disponibilidad y el episodio es el texto y el k. El filtro, la modalidad, la Knowledge Base, la cuenta y la ausencia de pin coinciden. Elemont ocupa los puestos 1 y 2 de la consulta por título, así que el k=5 no lo esconde. El k=8 del episodio tampoco lo trae.

La página 1 capturada es la identificación del documento: «Elemont — Montacargas Hidráulico Modelo MH». La página 7 es el diagrama del circuito 6, iluminación de foso, con terminales 10 y 11 de esa lámina. En esas dos páginas no aparecen puerta, imán, código ni LED. Eso describe esos chunks. No afirma que el manual carezca de otra sección. La página 5 de la comprobación del 2026-10-07 salió con otra consulta y tampoco define el código 18 ni el LED 7.

El chunk KONE de puesto 1 trae alias de búsqueda de puerta que no abre, puerta que no cierra, reapertura y LED de ese operador. La hipótesis de que el síntoma adelanta esos documentos y deja fuera al Elemont antes de la compuerta de compatibilidad encaja con lo observable: la compatibilidad solo corre sobre los ocho, y el Elemont no está entre ellos. No queda demostrada la posición ni el score del Elemont por debajo del octavo. Tampoco hay, en esta captura, una consulta sola «Elemont MH» sin el título canónico y sin el síntoma. La expansión que añadía el título canónico a la consulta del síntoma ya se midió el 2026-10-07 y no metió el Elemont en el top 8. No se reinstala.

##### C. Generación con `no_compatible`

Los 14 prompts son los de `CompanionGuidanceContext` en modo conocido. El encabezado dice que no hay procedimiento de fabricante compatible, que no se tomen prestados los manuales de referencia y que no se inventen significados de código ni funciones de terminal. En el mismo prompt permanecen «Continue helping … and generic diagnostic reasoning» y, cuando la salida no está activa, «One high-value next observation is optional». La frase de la foto está en `known_detail_pieces` sin mirar si hay una observación visual. `INTERVENTION_LIMIT`, la prohibición de medir con un instrumento sin evidencia aplicable, solo se arma en el modo de identidad desconocida.

`documentation_exit?` lee `@question`. En esta ruta `BedrockRagService#document_identity_scope_result` le pasa la consulta compuesta. La ruta de identidad desconocida le pasa el turno crudo. El turno 14 del técnico es «¿Y ahora?». La consulta compuesta empieza así y sigue con código, identificadores y observaciones, de 361 caracteres. No cumple el ancla de «solo sigue igual / y ahora / no lo sé» y no contiene «no lo sé». La regla de salida no entró. Quedó «One high-value next observation is optional». La respuesta pidió tensión en los terminales del imán, con multímetro, y atribuyó el clic a una señal recibida por el motor o el solenoide.

En los turnos 9 y 12 la regla de salida sí está: el texto enviado contiene «No lo sé» y la consulta compuesta lo arrastra. El prompt también conserva el razonamiento genérico y, en el 9 y el 12, «Put what the photo shows». No hubo imagen ni bloque de evidencia visual. El turno 9 abre con «La foto muestra» y resume hechos ya dichos. Los dos turnos vuelven a pedir alimentación o continuidad en los terminales. La regla de salida incluye «ask the one decisive datum», así que pedir un dato sigue escrito al lado de «Do not propose another check by routine».

Separación: hay contradicción en el prompt (foto sin imagen; salida junto con razonamiento genérico, comprobación de campo y dato decisivo; la prohibición de medir no está en el modo conocido). Hay política insuficiente: `no_compatible` retira los cuerpos y aun así encarga seguir el diagnóstico. Hay conducta del modelo encima de eso: con la prohibición de inventar significados y con la salida ya visible, los turnos 9 y 12 igual asignan funciones al LED, al clic y al código, y piden una medición. Corregir solo la foto y el disparador de la salida no mete al Elemont en el retrieve ni cita un pasaje aplicable. Los turnos que ya tenían la salida siguieron pidiendo mediciones.

La frase de la foto se omitió por presupuesto en los turnos 10, 11, 13 y 14. En el 9 estaba y la respuesta la usó. En el 12 estaba y la respuesta no escribió «La foto muestra»; igual pidió continuidad. La frase explica una oración. No explica el bloqueo.

##### D. Harness

`JourneyAMessages` añade «No lo sé.» cuando la última pregunta de la respuesta anterior pide procedencia, significado, tensión, voltaje, terminal o borne, y el turno todavía no lo dice. No adelanta un hecho de otro turno. El fixture no trae ese dato.

| Turno | Texto original | Texto enviado | Pregunta previa | Motivo |
| --- | --- | --- | --- | --- |
| 3 | «La cabina está detenida cerca de planta 1 y no hay personas dentro.» | El mismo texto más «No lo sé.» | Medir voltaje en los terminales del imán durante el cierre. | `unknown` |
| 6 | «Ya comprobé visualmente la guía de la puerta; no veo una obstrucción.» | El mismo texto más «No lo sé.» | Si hay tensión en el imán cuando la puerta llega al marco. | `unknown` |
| 9 | «Sigue igual. ¿Y ahora?» | El mismo texto más «No lo sé.» | Alimentación en los terminales del imán al solicitar cierre. | `unknown` |
| 11 | «Hice esa revisión: sigue el clic y la puerta no termina de cerrar.» | El mismo texto más «No lo sé.» | Voltaje en el imán con la puerta en posición cerrada. | `unknown`. No se reescribió el clic: la respuesta anterior sí hablaba de una revisión. |
| 12 | «Sigue igual.» | «Sigue igual. No lo sé.» | Continuidad en los terminales de la bobina al solicitar cierre. | `unknown` |
| 13 | «Corrijo algo de antes: la cabina está detenida cerca de planta 2, no de planta 1.» | El mismo texto más «No lo sé.» | Continuidad en los terminales del imán con la puerta cerrada. | `unknown` |

El hecho del fixture queda en la misma frase. La planta, la guía, el clic y la corrección se entregaron. El «No lo sé» contesta la medición que el caso no trae. También mete esa cola en la consulta compuesta, y por eso la salida se activó en los turnos 3, 6, 9, 11, 12 y 13 aunque el original de varios de ellos traía un dato nuevo. El turno 14 no recibió la cola: la respuesta anterior no dejó una pregunta que el adaptador reconociera, y el original «¿Y ahora?» se diluyó al componer.

Journey A comprueba memoria, correcciones y continuidad frente a observaciones ya escritas. La identidad llega en el turno 1; nadie la pide y nadie la confirma después. No evalúa una identificación conversacional ni la confirmación de un manual. No se modifica el fixture para fabricar una aprobación.

##### Contrato de identificación y documentación

Se distinguen cinco planos. El identificador declarado es lo que el técnico aserta, con procedencia `user` e incertidumbre si la cláusula es dudosa. La normalización de catálogo conserva el signo y no crea otro designador: `CEA15` no es `CEA15+` ni `CEA15P`. El documento candidato es una entrada confirmada, autorizada y enlazada a una sola fila. La compatibilidad queda respaldada cuando el técnico confirma ese documento, o cuando un pasaje de un documento ya seleccionado responde con evidencia de este equipo. La evidencia que responde es un chunk aplicable a la consulta, con documento y página. `known?` pertenece al primer plano y al cambio de ruta. No es compatibilidad documental.

Puede haber más de un documento aplicable —equipo, placa, otro componente— cuando cada relación está respaldada. Confirmar el equipo no confirma un manual. Una coincidencia de catálogo tampoco. Nombrar un manual en la pregunta no lo selecciona.

Si el documento identificado no aporta un pasaje que responda: no se afirma que el manual carezca de esa respuesta; se puede proponer otro documento con su propia confirmación; la orientación general queda separada de la instrucción específica; un disclaimer no vuelve aplicable un procedimiento de otro equipo.

##### Pin actual, frente al flujo propuesto

El flujo a evaluar es: identificar el equipo con lo disponible; explicar la correspondencia y preguntar si ese manual corresponde; si el técnico confirma ese manual, dejarlo seleccionado con el pin existente, explicar la acción y permitir quitarlo.

Lo que el pin ya hace, en la ruta web y fuera de este runner:

- La selección desde el chat existe y no exige abrir la biblioteca. `RagController#attach_manual_suggestion` adjunta tarjetas. El botón «Usar este manual» envía `kb_document_id`, `document_uid` y `focus_mode` a `PinnedDocumentsController`. El servidor vuelve a autorizar la fila y exige que el uid coincida. `pin_kb_document!` escribe `document_focus` con id, URI, nombre y fecha copiados de la fila. El botón pasa a «Quitar foco». El badge cuenta los seleccionados. El texto de estado es «Manual enfocado». Quitar llama a `unpin_kb_document_id!` y dice que la consulta ya no usa ese manual.
- Varios manuales caben. `write_document_focus!` agrega hasta `MAX_ENTITIES` (10). `focus_mode=replace` sustituye el conjunto por un solo documento. El descubrimiento pide reemplazo cuando la marca dicha contradice un pin ya puesto. Con el foco vacío, las tarjetas del turno 1 piden agregar.
- Con al menos un pin, `resolve_retrieval_scope` devuelve `pin_only`: `force_entity_filter` verdadero y solo esas URIs. Un retrieve vacío no reabre el corpus ni suelta el pin. El aviso es «El foco de esta sesión no devolvió evidencia y se mantiene.» `RagRetrievalProfile` baja k a 3 dentro del foco. Si hay varios pines y la pregunta nombra uno con confianza, `PinnedEntityScopeResolver` estrecha esa consulta a ese URI. Los demás pines siguen guardados.
- Una corrección de fabricante o de modelo no borra `document_focus`. `pins_after_manufacturer_correction` no tiene llamador. `FocusNotice.pin_conflict` muestra que el manual enfocado es de otra marca y sigue enfocado. Un caso nuevo limpia `current_procedure` y tampoco limpia el foco. El pin es de la sesión, no del episodio.

Lo que ese mecanismo no hace:

- Confirmar la identidad del equipo no escribe el pin. Una coincidencia de catálogo tampoco. La frase que nombra un manual tampoco. Un «sí» en el compositor es otro `ask`: `PendingQuestion` no tiene un tipo de confirmación de manual, y sus respuestas cerradas son «ninguno» y «al abrir».
- La confirmación inequívoca que sí existe es el botón, porque revalida id y uid. El texto actual de la coincidencia exacta dice «el documento coincide con el modelo/designador indicado». Con la normalización que borra el «+», esa tarjeta ofrece `manual-cea15p` para la frase que dijo `CEA15`. Aceptarla seleccionaría otro designador.
- El runner no llama a `attach_manual_suggestion`. Sus tarjetas son diagnóstico de catálogo, `uses_current_retrieval: false`, sin botón y sin efecto sobre el retrieve. Esta pasada no ejercitó el pin.
- `pin_only` impide buscar documentación complementaria fuera de lo seleccionado. Eso cumple el contrato de no soltar el foco. La forma de incorporar la placa u otro componente es otra confirmación explícita con `focus_mode=add`, que suma esa URI. No se reabre el corpus por detrás. Si el designador de la placa no tiene fila propia, no se sustituye por `CEA15+`. Si el retrieve dentro del manual seleccionado no trae un pasaje útil, se dice ese límite y se mantiene la selección. Subir k seguiría dentro de las URIs ya elegidas; no forma parte de esta propuesta y no se mide aquí.

El botón revalida id y uid, y esa es la confirmación que el mecanismo ya sabe hacer. La frase «¿Corresponde a tu equipo?» no selecciona por sí sola. Un «sí» suelto, o el nombre del manual dentro de la consulta, no selecciona. La comparación del «+» en `DocumentDiscovery` tiene que corregirse antes de ofrecer `CEA15`: si no, la tarjeta sería de otro designador. No hace falta otra tabla ni otro pin. El foco sigue siendo de sesión y permanece hasta que el técnico lo quite, también si abre otro caso. La confirmación por frase queda fuera de la propuesta.

##### Propuesta mínima

Queda retirada. No es propuesta y no se implementa. La única propuesta es «Ajustes a la propuesta (2026-10-09)». Los cinco pasos que estaban aquí admitían un «sí» cerrado en el mismo corte, dejaban la coincidencia exacta como camino principal y trataban el aviso de conflicto como si bastara para seguir usando el manual. Esos pasos no quedan como instrucciones.

##### Enfoques descartados y parches que se mantienen

Descartados, con motivo:

- Volver a expandir la consulta del síntoma con el título canónico. La comparación del 2026-10-07 no metió el Elemont en el top 8.
- Tratar `known?`, la marca normalizada o la tarjeta `EXACT_DESIGNATOR` como compatibilidad o como pin.
- Igualar `CEA15`, `CEA15+` y `CEA15P`.
- Pinear porque el técnico nombró el manual, porque el catálogo coincidió o porque dijo que el equipo es Elemont.
- Reabrir el corpus cuando `pin_only` vuelve vacío, o quitar el pin al corregir la marca. El foco se mantiene y el conflicto se muestra.
- Reconfirmar con el botón viejo un manual que ya no es candidato, o tratar esa reconfirmación como prueba de que hay un pasaje.
- Pinear al nombrar una marca o una falla. El comentario de Jesús Graterol del 28/09/2026 pide mostrar manuales, no seleccionarlos solo.
- Una tabla nueva, una caché, una búsqueda en segundo plano o una llamada de modelo adicional.
- Cambiar el fixture de Journey A para obtener una aprobación.
- Declarar el episodio validado porque mejoraron identidad, código, planta y resumen.

Se mantienen, porque esta pasada o el código ya muestran efecto:

- Procedencia `user` con `catalog_normalized` cuando el técnico aserta el span.
- `ObservationCorrection` y la planta 2 vigente, con la ocupación conservada.
- Código 18 vigente y código 8 rechazado, sin degradar el objetivo.
- «clic» como observación, no como identificador.
- El pedido de resumen pasado a `follow_up`.
- El guardado del designador con «+» de `5f69556`. El descubrimiento de tarjetas todavía no usa esa comparación; se corrige aparte, sin revertir el guardado.
- La composición del guidance, la regla de hipótesis, el contrato N4 y la continuidad bajo el tope de 2400.
- El pin opcional, la autorización por fila y uid, `pin_only` y la conservación del foco.
- El cierre presupuestario de `3ff27f9`: 188 llamadas, US$0,423114, techos 188, 42 y 230, `PASS_CALL_CAP` 0. Esta revisión no lo abre.

Veredicto de esta auditoría: `ETAPA_2_BLOQUEADA`. No es `EPISODIO_VALIDADO`. No autoriza implementación, otra pasada ni la etapa 3.

El texto de «Ajustes a la propuesta (2026-10-09)» está en «Propuesta diferida de descubrimiento», arriba de esta referencia. No es la ruta de ejecución.

### 3. Verificar ese alcance en producción

Primera consulta y continuidad del mismo episodio, sobre el journey A ya aceptado en local. Una pasada. Sin sonda previa. Sin L3, sin journey B y sin T-F. Las reparaciones de las etapas 1 y 2 entran por el procedimiento de despliegue vigente.

Resultado: la misma aceptación de la etapa 2 contra el índice de producción, más una reconciliación del costo. Los inciertos que esta pasada no toque siguen inciertos. Los pendientes históricos siguen abiertos.

Parada: la misma de la etapa 2, con el presupuesto de 42 llamadas. Un fallo de producción no se repara en caliente dentro de esta etapa.

Veredicto, sobre la evidencia de las etapas 2 y 3 juntas. El smoke solo no decide. El veredicto no declara habilitado un piloto de consultas libres. Eso queda para después de validar la separación mínima entre casos.

- `EPISODIO_VALIDADO`: la aceptación de la etapa 2 se cumplió en local y en producción para este episodio; la conclusión usó documentación compatible cuando el retrieve la devolvió; ninguna respuesta inventó un valor, terminal, código o procedimiento de fabricante; el gasto quedó dentro del presupuesto. El veredicto nombra lo que sigue abierto: el backlog, la recuperación de un caso anterior, O-P1, el smoke R1B y N1–N6.
- `PENDIENTE`: alguna aceptación quedó inconclusa por transporte, falta de acceso o configuración, registros locales ausentes o incompatibles, búsqueda sin resultados, o presupuesto agotado, sin una falla de producto confirmada. También si el manual es recuperable en la Knowledge Base de producción y el episodio no llegó a usar documentación compatible.
- `BLOQUEADO`: una falla de producto confirmada y no reparada (valor corregido tratado como vigente, pregunta repetida, pérdida de lo comprobado, o documentación compatible ignorada) o una respuesta insegura.

## Backlog posterior

Empieza después del cierre de este alcance. No se ejecuta con la luz verde de este plan. El orden de abajo es la prioridad propuesta. Cada ítem se autoriza como incremento. Adelantar uno es una decisión del fundador. Aquí no se diseña la implementación.

### 1. Cambio explícito de caso dentro de la misma sesión

Objetivo: abrir otro episodio ante un cambio claro, sin contaminación del caso anterior y sin una escritura tardía sobre el episodio que ya cerró.

Reutiliza los dos textos L3 de `test/fixtures/files/field_companion/longitudinal_journeys.yml`, `new_work` y `expected_episode_id`. El caso previo puede ser el episodio de puertas ya corrido. No se abre otro corpus.

Inicio: este alcance está cerrado y el incremento está autorizado.

Aceptación: `new_work` directo, o una aclaración mínima que el técnico responde y que termina en un episodio nuevo. El seguimiento queda en el episodio nuevo y su respuesta no usa la falla de puerta, el código 18, la planta 2 ni la identidad Elemont. Una escritura con el `episode_id` anterior se rechaza.

### 2. Cambio ambiguo

Objetivo: distinguir seguimiento, otro problema del mismo equipo y otro equipo. Aclarar y procesar la consulta original sin exigir que el técnico la repita.

Reutiliza la aclaración de relación entre casos ya presente en la ruta owner. No hay un fixture dedicado. Al autorizarse, las frases salen del mismo equipo de puertas o de L3. No se abre otro corpus en este plan.

Inicio: el ítem 1 está cerrado, o el fundador adelanta este, y el incremento está autorizado.

Aceptación: ante ambigüedad real hay una aclaración mínima. La respuesta del técnico separa o continúa. La consulta original se procesa sin pedirle que la repita. Una aclaración que no produce esa separación o esa continuación no pasa.

### 3. Regreso tras una pausa

Objetivo: dentro de las cuatro horas, comprobar continuidad del mismo episodio y un cambio de caso. Comprobar también qué ocurre al vencer el episodio.

Reutiliza `ConversationSession::EPISODE_WINDOW` (4 horas), el episodio de puertas y el texto L3. El fixture longitudinal trae un reloj fijo. Mover ese reloj se decide al autorizar el incremento, no ahora.

Inicio: los ítems 1 y 2 están cerrados, o el fundador lo adelanta, y el incremento está autorizado.

Aceptación: antes de las cuatro horas el mismo caso conserva los hechos, y un cambio claro abre otro episodio sin contaminación. Al vencer la ventana, ese episodio no sigue tratándose como abierto.

### 4. Journey B completo

Objetivo: adquirir una identidad que al principio se desconoce, buscar con el síntoma antes de completarla e incorporarla cuando llega.

Reutiliza el journey B, turnos 1 a 10, del mismo fixture longitudinal, incluido el payload de foto ya escrito. Esa foto no valida Vision.

Inicio: este alcance está cerrado y el incremento está autorizado. No depende de haber ejecutado el cambio de caso, salvo que el fundador ate las prioridades.

Aceptación: la primera búsqueda puede usar el síntoma. Orona y PBCM-V3 quedan en el episodio cuando el texto los confirma. «Por arriba», corregido a «por debajo», no vuelve como vigente. Una respuesta sin manual compatible no es éxito documental. El payload de foto no se anota como validación de Vision.

### 5. T-F completo

Objetivo: corregir el fabricante y seguir el mismo caso con el intérprete real.

Reutiliza los cuatro textos del técnico en T-F (`test/fixtures/files/field_companion/cases.yml`): la consulta de los resortes, «Fuji Yida», «el modelo no lo sé» y «No, no es Fuji Yida. Es KONE». No se inyectan las preguntas del asistente que trae el fixture. La misma regla de adaptación del journey A sirve cuando un texto presupone una pregunta que Danebo no hizo.

Inicio: este alcance está cerrado y el incremento está autorizado.

Aceptación: el fabricante vigente pasa a ser KONE, el episodio sigue siendo el mismo, el objetivo no cambia y Fuji Yida no vuelve como marca vigente. La traza usa el intérprete real.

### 6. Recuperación de un caso anterior

Objetivo: evaluar si hace falta recuperar un caso ya cerrado dentro de la sesión y, si hace falta, cuál es la solución mínima.

Hoy no hay almacén de episodios anteriores ni una operación de la ruta owner que reabra un caso cerrado. `voice_dictation` no cuenta. No está implementado y este ítem no lo declara implementado. No se diseña aquí una tabla ni un archivo.

Inicio: este alcance está cerrado y el fundador pide esa evaluación. No la dispara el cierre del episodio de puertas.

Aceptación: un juicio de necesidad y, si hace falta, de la solución mínima. Si esa solución pidiera una tabla, varios episodios activos o un archivo, vuelve al fundador antes de construirse. Declarar la recuperación como ya hecha no es un resultado válido.

## Pendientes históricos

Siguen en el inventario y en O-P1. No son los seis escenarios de arriba. Quedar fuera de esta ejecución no los cierra: O-P1, el mapa R2, el smoke de producción R1B, la verificación de producción N1–N6, G5, la presentación, T3, R3, CG-D19, CS-P01 a CS-P03 y F9. A‴ permanece como regresión secundaria, con sus conteos.

## Límites explícitos

- El journey A no trae la causa que el manual debería nombrar. `EPISODIO_VALIDADO` no significa que la puerta quedó reparada ni que la respuesta coincidió con un dictamen guionado.
- La ruta de cero chunks con identidad desconocida se repara en la etapa 1 y se cubre con tests locales. Si el intérprete deja Elemont como identidad conocida, la etapa 2 no recorre esa ruta. No se agrega el journey B para cubrirla.
- Las pruebas locales de separación no sustituyen a L3 con el intérprete real. `EPISODIO_VALIDADO` no habilita un piloto de consultas libres.
- R2 sigue pospuesto y no es el escenario del cambio de caso. Ese escenario, cuando se autorice, reutiliza L3.
- El tope de US$2,50 no mide `Retrieve` ni el embedding. Es un margen sobre US$1,54 de llamadas de modelo.

## Revisión Opus (2026-10-07)

Incorporado entonces, y todavía vigente dentro de este alcance: la identidad puede ser objetivo cuando decide la documentación, la aplicabilidad o el diagnóstico; las aclaraciones sirven también para distinguir causas, interpretar resultados y decidir el paso; la ruta de cero chunks recibe guidance en la etapa 1; el límite de 400 admite un ajuste acotado hasta 600; los textos del técnico se adaptan a la respuesta real y conservan sus hechos; presupuesto con supuestos explícitos; ejecución autónoma tras la luz verde final.

Esta revisión de alcance deja atrás, para el gate y el presupuesto: la aritmética 16 + 10 + 4, las tres pasadas de los tres escenarios, el techo de 360 llamadas y US$5, la comprobación pagada de L3 dentro de la etapa 2, y el veredicto `RECOMENDAR_PILOTO_CONTROLADO`. La separación de casos y la recuperación de un caso anterior siguen sin declararse hechas. La discrepancia de O-P1 sigue sin un lado elegido. Las páginas industriales no se re-descargaron.
