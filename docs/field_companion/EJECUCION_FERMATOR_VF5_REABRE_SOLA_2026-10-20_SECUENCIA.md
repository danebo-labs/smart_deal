# Fermator VF5+: secuencia con el código cargado, 2026-10-20

No es aceptación textual. No declara `EPISODIO_VALIDADO`. No ejecuta la comparación de modelos.

HEAD al abrir: `af2ad33f1b586aff16a59f5a2a110aaf8400cb8a`. El proceso web cargó el árbol de trabajo. `bound_lengths` está en `app/services/rag/turn_perception.rb:248`. El digest de su secuencia de instrucciones, leído en el proceso 32400 durante el pin, es `2d3689b163d1395a6e3f1fedd2d9f75244fbff12647cbe1ce70489d6b20be04d`. El mismo digest lo dio un `rails runner` sobre ese archivo. El servidor arrancó a las 14:28:11 -03, pid 32400, y se detuvo al cerrar la secuencia. Puerto 3000 libre.

## Aislamiento de pruebas

`LiveAwsBlock` se instala en `test/test_helper.rb` y rechaza `converse`, `converse_stream`, `invoke_model`, `invoke_model_with_response_stream`, `retrieve` y `retrieve_and_generate` de los clientes reales. Un doble que sustituye `Client.new` no pasa por ahí. Con `HAIKU_QUERY_ANALYSIS_MODE=owner` y `BEDROCK_KNOWLEDGE_BASE_ID=Y7RZWMFJSR` en el entorno, `bin/rails test` de `live_aws_block_test`, `turn_perception_test`, `turn_interpreter_failure_test`, `audit_capture_test`, `conversation_session_turn_interpreter_test`, `work_context_goal_test` e `interpreter_service_failure_route_test` terminó en 0,93 s: 167 tests, 1666 aserciones, 0 fallos, semilla 54879. Cero llamadas a AWS.

Una observación más larga que 180 caracteres se parte en frases literales que caben en el tope. Si no hay un corte literal, el campo se rechaza y el resto del tool sigue. La identidad corta no se tira con el campo largo. En esta secuencia el intérprete ya devolvió observaciones cortas. El síntoma no dependió de ese corte: el span largo del síntoma se rechazó por los 60 caracteres y la misma frase quedó como observación.

## Proceso antes de los mensajes

Captura `tmp/field_companion/validation_captures/vf5-bound-20261020T1728Z`. El pin `abfd72d4-1e25-43e0-9438-0f6996c71ffd` escribió `process_contract` y `ledger.json` con cero intentos. Ledger armado: tope 20 invocaciones, US$1, `aws_max_attempts` 1, proceso local, sin requisitos faltantes. Intérprete y generación: `global.anthropic.claude-haiku-4-5-20251001-v1:0`. Modo `owner`. KB `Y7RZWMFJSR`. Bucket `multimodal-source-destination`. Episodio, turno, alcance de episodio e identidad documental en `true`. Sesión compartida en `false`.

`start_clean_case` con `APPLY=true`, cuenta `index-account-1`, usuario de la sesión 198. Cuatro bases locales en `localhost`: `smart_deal_development`, `smart_deal_development_cache`, `smart_deal_development_queue`, `smart_deal_development_cable`. Episodio `ep_45f5d00af6918ad0`, abierto 2026-10-20T14:29:35-03:00. El mismo id sigue en los tres turnos y en la fila al cerrar. Historial final: user, assistant, user, assistant, user, assistant. Foco del documento 122, uid `126cda62-64ad-4469-8674-a29f12e38d48`, URI `s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf`. El pin no llamó al modelo.

## Turnos

| | Turno 1 | Turno 2 | Turno 3 |
|---|---|---|---|
| Request | `354da85f-c20c-4d36-bb88-45a0c059bc2e` | `8205d72d-d67f-4dcb-b9d6-532fb3373768` | `76c894c8-7042-4798-90e2-c7ccd284daaf` |
| Correlación | `query:0688864e-134f-4f9b-92d7-ead86845c6a6` | `query:c87d50e8-dc2b-402d-afed-532f21c2f58d` | `query:352be35d-1341-4a60-91a5-34d8b714af70` |
| Intérprete | `report`, válido. Rechazo `assertions[1].span` / `over_length` | `correct`, válido. Sin rechazos | `follow_up`, válido. Sin rechazos |
| Identidad vigente | Fermator, fuente `user`. Identificador `Fermator VF5+` | La misma | La misma |
| Antecedentes vigentes | Objetivo y observaciones: reapertura sola, LED encendido, no observo obstrucción. La consulta efectiva es el mensaje completo: simulación, sensibilidad sin revisar, SW4 OFF, modo esclavo, sin mediciones ni reparaciones | Observaciones: reapertura sola, no observo obstrucción, SW4 sigue en OFF, LED apagado. El objetivo guardado queda en «empieza a cerrar» y la observación conserva «vuelve a abrirse sola» | Igual que el turno 2. El mensaje añade que no hubo reparación |
| Pasajes en el prompt | `bodies/b0005.txt`. `THIS JOB'S EQUIPMENT: VF5`. 8.2, página 12: potenciómetro #54, fotocélula no activada, obstrucción mecánica. SW4, página 5: `OFF: Esclavo` y el ejemplo de los bornes 36, 37 y 38 | `bodies/b0005.txt`. 8.2, página 12. El cuerpo de SW4 no volvió en este Retrieve | `bodies/b0006.txt`. 8.2, página 12, y página 13. El cuerpo de SW4 no volvió en este Retrieve |
| Citas publicadas | VF5 p. 12 y p. 5 | VF5 p. 12 | VF5 p. 13 y p. 12 |
| Llamadas | 2237/363 y 8129/456 | 2348/144 y 7775/277 | 2320/106 y 9704/521 |
| Criterio de datos | Cumple: identidad, 8.2, SW4, simulación, síntoma, LED, obstrucción observada, sensibilidad pendiente y SW4 OFF están en el prompt | Cumple la corrección del LED y la continuidad del síntoma y de la obstrucción. El cuerpo de SW4 no está en este prompt; el dato SW4 OFF sí | Cumple identidad, LED apagado, obstrucción observada, síntoma, simulación previa en el historial y la frase de no reparación. El cuerpo de SW4 no está en este prompt |
| Respuesta | Trata «no observo una obstrucción» como comprobación descartada y usa el ejemplo de los bornes 36, 37 y 38 como mecanismo de este caso | Repite que la obstrucción ya está descartada. Dice que el LED apagado no cambia la orientación. La sensibilidad del #54 sigue pendiente | Separa reporte y manual. Vuelve a dar la obstrucción por descartada. Añade el patín de la página 13. No afirma una reparación |

El prompt del turno 1, en `# CONTEXT`, lleva el mensaje completo. `Active Field Problem` lleva `Manufacturer: Fermator (technician)` e `Identifiers: Fermator VF5+, modo esclavo`. El objetivo de ese turno incluye el LED encendido y «no observo una obstrucción mecánica». No contiene «obstrucción descartada».

En el turno 2 el problema activo lista `el LED está apagado` y conserva «no observo una obstrucción mecánica» y «vuelve a abrirse sola». «LED de fotocélula está encendido» queda una vez, dentro de `Recent Conversation`, con la etiqueta `User` del primer mensaje. «Ya has descartado» queda en ese historial con la etiqueta `Assistant`. El problema activo no copia esa frase a un hecho. El turno 2 la vuelve a publicar.

## Presupuesto

Cupo de este encargo: 20 invocaciones y US$1. No se reinició el sobre histórico de 48 invocaciones y US$2 ni el cupo cerrado de la recuperación.

Seis invocaciones, todas con precio, US$0,041848 por `BedrockQuery#cost`:

| Hora | Fuente | Tokens | USD |
|---|---|---|---|
| 14:30:09 | semantic_analysis | 2237 / 363 | 0,004052 |
| 14:30:28 | query | 8129 / 456 | 0,010409 |
| 14:31:32 | semantic_analysis | 2348 / 144 | 0,003068 |
| 14:31:38 | query | 7775 / 277 | 0,009160 |
| 14:31:40 | semantic_analysis | 2320 / 106 | 0,002850 |
| 14:31:48 | query | 9704 / 521 | 0,012309 |

El ledger del último request coincide: 6 intentos, comprometido US$0,041848, tope 20 y US$1. Los pins no sumaron intentos. Las pruebas no llamaron al modelo.

## Veredicto

Ruta de datos verificada; preparada para comparar modelos. Las tres respuestas no son satisfactorias: convierten la observación «no observo una obstrucción mecánica» en una comprobación ya descartada. El turno 1, además, presenta el ejemplo documental de los bornes 36, 37 y 38 como el mecanismo de este trabajo. Esos prompts son la muestra. No se ejecutó el benchmark.
