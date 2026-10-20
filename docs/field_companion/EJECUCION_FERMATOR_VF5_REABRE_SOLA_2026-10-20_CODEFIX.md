# Fermator VF5+: corrección de identidad y designadores, 2026-10-20

No es aceptación textual. No declara `EPISODIO_VALIDADO`. No ejecuta la comparación de modelos.

HEAD al abrir el árbol: `2865031cc9977de1d109fda19c1d24ec17ed9ad9`. El preflight de `start_clean_case` imprime ese SHA porque los cambios todavía no estaban en un commit. El proceso web cargó el árbol de trabajo.

## Defectos reproducidos

1. **Fabricante dentro del span.** `resolve_compound_brand` exigía que el primer token fuera la marca. En la variante densa el intérprete devolvió el span «operador Fermator VF5+». «operador» no es marca, el span no es un designador, `facts` quedó vacío y la publicación retuvo el cuerpo. La ventana contigua de una marca y un designador de la misma entrada confirmada y visible ahora resuelve ese par. Cero pares o más de un par no eligen. El identificador guardado es el texto de la ventana («Fermator VF5+»), porque el tope de 30 caracteres cortaría un span que arrastra la palabra de rol. El hecho de fabricante conserva el span del modelo para la traza. No hay una excepción para Fermator: el catálogo de prueba usa Norte QX7+ y el catálogo real solo entra en un test que crea la fila del uid `126cda62-64ad-4469-8674-a29f12e38d48`.

2. **Designador truncado.** Antes de editar, `revision_designators("VF5+X VF5A ABCD12345 VF5+ VF5 ABCD1234")` devolvía `["VF5+", "VF5", "ABCD1234", "VF5+", "VF5", "ABCD1234"]`. El patrón nuevo `/\b[A-Z]{1,4}-?\d[A-Z\d+\-]*/` conserva el token. `VF5+X` no autoriza el manual VF5+. Un chunk titulado `VF5+X` o `VF5A` no conserva el cuerpo de ese manual. `ABCD12345` no autoriza el designador de catálogo `ABCD1234`. Un chunk titulado `ABCD12345` tampoco: el reconocimiento de identidad explícita usaba el patrón corto, que no ve un token de cinco dígitos, y el pin lo dejaba en `neutral` con el cuerpo. Ese reconocimiento usa ahora el mismo token completo. `VF5+`, `VF5` y el título abreviado `VF5` siguen como estaban.

3. **Observación convertida en certeza.** En la pasada de correspondencia el request del turno 3 ya tenía «no observo», la sección 8.2 y la marca de simulado, y la respuesta publicada descartó la obstrucción. Eso nace en la generación. El turno 4 reinyecta la frase del asistente anterior por Recent Conversation. Esta corrección no quita ese historial. El compositor sí borra del turno actual una negación sin slot. Si esa negación es también una observación guardada, ahora permanece. Una negación que consume el turno y no es observación sigue fuera de la consulta.

4. **Tope del mensaje.** `MAX_MSG_LENGTH` era 300. El mensaje 1 mide 376 caracteres y perdía «reparaciones» y la pregunta. El tope pasa a 600, compartido por historial, intérprete y comprobación de spans. El corte de 300 del log `RAG_QUALITY` y `MAX_GOAL_CHARS` no se movieron.

## Pruebas con dobles

`bin/rails test` sobre `document_identity_scope_test`, `turn_perception_test`, `query_composer_test`, `conversation_session_test` y `conversation_session_turn_interpreter_test`. 324 tests, 2932 aserciones, 0 fallos, semilla 53356. Cero llamadas a AWS.

El recorrido de producto con doble está en `test_the_detailed_Fermator_turn_keeps_identity,_passages,_and_the_corrected_LED_through_generation`. El intérprete es un doble con el `tool_input` capturado. `Retrieve` y la generación son dobles: devuelven los pasajes de las páginas 12 y 5 y no llaman a Bedrock. El mensaje completo queda en el historial (`transform` equivalente a ninguno). El episodio guarda fabricante Fermator, fuente `user`, e identificador `Fermator VF5+`. La consulta incluye la simulación, la obstrucción observada, la sensibilidad sin revisar, SW4 y la pregunta. El request de generación admite los dos pasajes con `THIS JOB'S EQUIPMENT: VF5`. El problema de campo no copia «fotocélula obstruida» ni los bornes 36, 37 y 38; el pasaje de SW4 sí los trae como texto del manual. El segundo mensaje sustituye el LED encendido por apagado y conserva obstrucción, síntoma, fabricante e identificador. El tercero mantiene ese estado y el historial de los tres mensajes.

## Secuencia real

Una sola secuencia, después de las pruebas locales. Haiku 4.5 en los dos roles: `global.anthropic.claude-haiku-4-5-20251001-v1:0`. KB `Y7RZWMFJSR`. Caso `ep_57237a8a10576674`, sesión 198, cuenta 1, usuario 27. Foco por `POST /pinned_documents` del documento 122, URI `s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf`, antes de los mensajes. Captura `tmp/field_companion/validation_captures/vf5-codefix-20261020T1644Z`. El foco no llamó al modelo.

| Turno | Request | Correlación | Intérprete | Respuesta publicada |
|---|---|---|---|---|
| 1 | `637e47c6-e250-46c3-b662-a021d529b3bf` | `query:604d805f-e934-4d7e-983b-a2307f6fcaa7` | `ServiceUnavailableException` | Identidad no confirmada. Cita VF5 pp. 12, 13 y 5 como referencia no aplicada y pide la placa. |
| 2 | `c183d77a-c39e-48ae-8c0d-8728e266ece5` | `query:a96491d1-468c-487a-9ed9-cab7c038efc8` | `ServiceUnavailableException` | La misma plantilla, con VF5 pp. 7 y 5. |
| 3 | `40e3db1a-3705-4e64-b6ed-29fdb80d0840` | `query:498fdfdb-05d0-4635-af3e-64a15c29b5ad` | `ServiceUnavailableException` | «El material recuperado no está confirmado para este equipo» y pregunta por la placa. |

En los tres, `user_message.transform` es `none` y `limit` es 600. El mensaje 1 enviado al intérprete es el texto completo de 376 caracteres. El filtro de Retrieve es la URI del VF5. El turno 1 recupera páginas 12, 13 y 5. El prompt de generación (`bodies/b0005.txt` de ese request) lleva la pregunta completa, dice que la identidad no está confirmada y que el contenido de los manuales recuperados no está en el prompt. No contiene el cuerpo de 8.2 ni el de SW4. El episodio terminó sin fabricante y sin identificadores. El fallback guardó cada turno crudo como observación, con tope 180, y el primero también como objetivo, con tope 300: el objetivo corta en «No hice medicione». El historial sí conserva los 376 caracteres.

Esa secuencia no ejerció el arreglo del span: el intérprete no devolvió `tool_input`. La generación publicó la plantilla de identidad no confirmada. No es una muestra de respuesta con contexto correcto.

## Presupuesto

Sobre compartido de este encargo: 48 invocaciones y US$2. No se reinició. El ledger de la pasada de correspondencia, el que seguía abierto, había usado 19 invocaciones y US$0,111153. El tope de este proceso fue 29 y US$1,888847. `LocalPassLedger.reset!` no se llamó.

Esta secuencia: 6 invocaciones admitidas, 3 con precio, comprometido US$0,014753, retenido US$0,025709. El retenido es el techo no liquidado de los tres intérpretes que fallaron. Las pasadas 1 y 2 fueron cupos cerrados de 24 y US$1 (7 / US$0,021354 y 15 / US$0,043059) y no se vuelven a restar aquí.

Saldo para el benchmark, restando correspondencia y esta secuencia: 23 invocaciones y US$1,874094 comprometidos. Si las pasadas 1 y 2 también contaran dentro de las 48, el saldo de invocaciones quedaría en 1. El proceso nuevo del benchmark no hereda el retenido de este proceso.
