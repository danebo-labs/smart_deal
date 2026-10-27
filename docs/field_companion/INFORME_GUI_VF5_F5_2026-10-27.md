# Informe GUI VF5 — F5, 27 de octubre de 2026

Dictamen de la corrida web real. No cambia código, modelo, configuración ni sesión. No declara F5 aceptada.

## Veredicto

**No aceptar F5.**

La orientación de T3 y T4, la conservación del caso y el desconocimiento de T5 quedan demostrados en esta muestra. El criterio vigente también exige que «encendido» no se publique como parpadeante ni como LED de Estado, y que «apagado» deje de ser el dato vigente. T2 no cumple esas dos condiciones. Con eso el recorrido no cierra.

La selección explícita del VF5 no acredita selección automática. No se exige estabilidad estadística. El plano Elemont no se abre con este dictamen.

## Precedencia

HEAD local al escribir este informe: `4eca6b32451583c29c5d705946cd40b12ab6e15e`. La sección vigente de `docs/field_companion/PLAN_CORRECCION_VF5_COMPANION.md` sigue siendo «Orientación recuperada — 26 de octubre de 2026, noche». F2, F3 y F4 no se reabren. F5 seguía pendiente de la GUI. El plan padre `docs/PLAN_FIELD_COMPANION_CONVERSACION_2026-10-07.md` deja el orden 3, el plano Elemont, después de esta conversación textual. Fotos y cambio de tema van después. Este informe no los empieza.

El F5 histórico de cuatro `POST /rag/ask` locales no es el criterio de esta muestra. El criterio aplicado es el guion web de cinco mensajes sobre un caso limpio, con el VF5 elegido a mano.

## Ejecución comprobada

| Dato | Valor |
|---|---|
| Cuenta | `danebo-legacy`, id 1 |
| Usuario | `lahiri.sanchez@danebo.ai`, id 3 |
| Sesión | 128, canal web |
| Episodio | `ep_1f3018d3f7f12e8c`, abierto `2026-10-27T11:03:42-03:00` |
| Manual | VF5, documento 212, URI `s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf`, marcado `2026-10-27T11:06:20-03:00` |
| Imagen | `docker.io/lahirisan80/smart-deal:4eca6b32451583c29c5d705946cd40b12ab6e15e` |
| `KAMAL_VERSION` | `4eca6b32451583c29c5d705946cd40b12ab6e15e` en las cinco capturas |
| Intérprete y plan | `global.anthropic.claude-haiku-4-5-20251001-v1:0` |
| Modo | `owner`. Episodio activo. Captura por cuenta `web-danebo-legacy` |
| Exportación | `tmp/pilot_exports/2026-10-27_2026-10-27_danebo-legacy/`, generada `2026-10-27T14:13:52Z` |

Los SHA-256 de `companion_plan_check.rb`, `companion_plan_render.rb`, `companion_plan.rb`, `turn_interpreter.rb`, `bedrock_client.rb`, `work_context_reducer.rb` y `conversation_session.rb` en el contenedor web coinciden con el árbol de `4eca6b3`. No hay diferencia entre esos archivos del contenedor y git.

Antes del primer mensaje el episodio no tiene objetivo, hechos, observaciones, comprobaciones ni pregunta pendiente. El foco ya es el documento 212: Lahiri lo marcó después de la limpieza y antes de escribir. El episodio de los tres HTTP 503 de la noche anterior es otro, `ep_862e5d624dc71923`. No entra en esta muestra.

| Turno | Hora −03 | Request | Correlación |
|---|---|---|---|
| T1 | 11:06:31 | `9b8723be-5e15-4c4a-831a-cbf2e51b8adb` | `query:009ccbb5-6351-471c-8b1e-7510572722fa` |
| T2 | 11:08:05 | `78c6a3df-9cf8-47b5-a962-6d96768d9f70` | `query:2c007d43-8987-41e2-a730-5527383648d9` |
| T3 | 11:08:53 | `29781655-80f9-4c41-b815-6f52927e7e42` | `query:f48523f1-b5d6-42fb-8e20-0d0fd6fbe8de` |
| T4 | 11:09:46 | `1d2710cd-7eba-4984-ac3f-13077a0f0ce4` | `query:8d1ce307-3b11-443e-847e-26d60a28f201` |
| T5 | 11:11:43 | `08a320cb-97ab-4fba-8cf2-9f6438f03f28` | `query:2c8cb7e8-80db-41ec-bdde-f384789c417e` |

El índice de la exportación marca esas cinco capturas con episodio, intérprete, percepción, plan, motivos del checker y texto publicado. El directorio local del paquete guarda el índice y no guarda los `capture.json` ni los `bodies/`: el exportador los descarga a un temporal, construye el índice y borra el temporal al salir. Los cinco `capture.json` y sus seis `bodies/` cada uno se leyeron del contenedor web, en las rutas que nombra el índice. No se usó `capture_probe`.

T5 tuvo un intento de intérprete con HTTP 503, request AWS `9807952f-1a6e-41c0-acac-13eb926b8b96`, y el segundo intento respondió. No hubo reenvío del usuario. El plan de T5 sí se ejecutó.

## Tabla por turno

| Turno | Esperado | Observado | Estado | Evaluación |
|---|---|---|---|---|
| T1 | Reconocer Fermator VF5+, conservar síntoma y pendientes, usar el apartado de reapertura. «No veo obstrucción» no cierra la comprobación mecánica. | Mensaje íntegro. Percepción `report`. Fermator y Fermator VF5+. Objetivo «La puerta se reabre sola durante el cierre». #54 y mediciones `not_done`. Publica los pasos de «La puerta se re-abre sola» y dice que el LED STATUS apagado no se aplica. | El enlace del LED apagado a STATUS sale `case_incompatible`. La pregunta propuesta se rechaza por `modality:continuamente`. No queda pendiente. | Cumple. Hay orientación documentada. La obstrucción no queda como comprobación hecha. |
| T2 | Encendido sustituye a apagado. No publicar parpadeo ni asignar el indicador. Si hace falta distinguirlo, preguntar cuál. | El texto recibido es «orrijo un dato: el LED está encendido, no apagado.» Percepción `correct`, observación «el LED está encendido, no apagado». El checker conserva el enlace O4→S2.14. | «El LED está apagado» sigue en las observaciones. Se añade la frase nueva. Se publica la lectura que junta encendido con «LED parpadeante». Se instala la pregunta de fotocélula o #21. | No cumple. El typo no explica el fallo. |
| T3 | Guardar la fotocélula aparte de #21, conservar pendientes y publicar orientación. | «Revisé la fotocélula y no está activada.» El crudo dice `answer_pending`; la percepción queda `report` por `pending_answer_incomplete`. Comprobación hecha de la fotocélula. Publica #54 pendiente, la fotocélula ya informada y la obstrucción como observación. Pregunta solo por #21. | El pendiente guardado sigue siendo la pregunta compuesta de T2. #54 y mediciones siguen `not_done`. | Cumple la orientación. La pregunta de #21 todavía no estaba contestada. |
| T4 | Seguir el caso. No abstenerse por «durante el cierre» ni repetir una pregunta para tapar un vacío. | «¿Qué sigue?», movimiento `follow_up`. Publica de nuevo el apartado, #54 pendiente, la obstrucción como observación y el reporte de fotocélula. Vuelve a preguntar #21. | El episodio no cambia de campos. El síntoma largo sigue siendo el objetivo. | Cumple. Repetir #21 aquí no es un fallo: el técnico no lo había contestado. |
| T5 | Guardar el desconocimiento de #21 y del contacto #21–#23. No volver a pedirlo ni inventar cómo comprobarlo. | Mensaje íntegro. Observación con las dos limitaciones, `answers.r = unknown`, ligada a la pregunta publicada en T2. La pregunta «¿Hay un contacto cerrado entre #21 y #23, o está abierto?» se rechaza por `declared_unknown`. | El pendiente se limpia. No reaparece #21 ni el contacto. La respuesta reconoce el límite y cita prioridad de re-apertura y la definición del indicador de fotocélula. | La memoria cumple. La utilidad es estrecha y no bloquea por sí sola. |

## Qué quedó acreditado

- El síntoma largo «durante el cierre» no apaga la orientación. T3 y T4 citan los pasos de «La puerta se re-abre sola», página 12.
- Fermator y Fermator VF5+ se conservan. El pin es el documento 212 durante los cinco turnos.
- «No veo obstrucción» se publica en T3 y T4 como observación, con la frase de que la comprobación no consta como hecha.
- La fotocélula queda en una comprobación distinta de #21.
- #54 y las mediciones siguen `not_done`.
- T5 guarda el desconocimiento completo y no vuelve a pedir #21 ni el contacto #21–#23.
- El perfil usado es el global. El código desplegado es `4eca6b3`, sin parche distinto en los archivos comparados.

## Fallo de T2

El mensaje que llegó es exactamente «orrijo un dato: el LED está encendido, no apagado.» `transform` es `none`. El intérprete igual clasificó `correct` y extrajo el span «el LED está encendido». El typo no desvió la percepción.

La observación guardada es la frase completa, «el LED está encendido, no apagado». `ObservationCorrection.led_state` solo reconoce una frase que termina en «encendido» o «apagado». La coma y «no apagado» hacen que no haya estado LED para esa frase. Por eso ocurren las dos cosas:

1. «El LED está apagado» no se retira. Sigue como observación en T2, T3, T4 y T5, junto con la frase nueva.
2. `led_context_reason` exige un reporte LED genérico. Como `led_state` devuelve nil, no rechaza el enlace. El checker conserva O4→S2.14.

S2.13 es el apartado «Estado.» S2.14 es el texto «LED parpadeante indicando condiciones apropiadas de trabajo.» El modelo propuso la lectura «El LED está encendido; el LED parpadeante indica condiciones apropiadas de trabajo.» Esa lectura está anclada al texto del apartado y a la frase del técnico, así que `reading_reason` no la tira. `question_role` queda nil. No se pregunta cuál indicador es.

Lo publicado no es solo una cita separada. Después de citar la frase del manual, la lectura de Danebo afirma las dos cosas en una sola oración: el LED del técnico está encendido y el LED parpadeante indica condiciones de trabajo. Para el técnico, su LED fijo queda leído como el indicador de Estado en condiciones apropiadas.

La prueba local no vio este caso. El fixture de `vf5_gui_replay_test.rb` usa la observación «el LED está encendido», que sí coincide con el patrón, y comprueba que esa frase no publique «parpadeante». Esta corrida guardó otra frase. El código de `4eca6b3` sí está desplegado; el patrón no cubre la observación que produjo este modelo.

## T5, memoria y utilidad

`answers.q` es «¿Está activada la fotocélula o la entrada de re-apertura (#21)?». `answers.r` es `unknown`. El texto de la observación nombra identificar #21 y el contacto cerrado entre #21 y #23. El destino guardado es el ítem «Fotocélula.», página 7, `chunk_p7_3.txt`. El límite publicado dice que la indicación de fotocélula depende de ese dato. No inventa un procedimiento de comprobación.

La respuesta sigue con dos lecturas: la prioridad de la señal de re-apertura sobre cerrar, y la definición del indicador de fotocélula. No dice qué puede mirar el técnico sin identificar #21. Eso es una utilidad estrecha, no un fallo que impida el criterio de memoria. No alcanza para aceptar el turno solo por la frase «Indicaste que no puedes distinguirlo»; el rechazo `declared_unknown` y el episodio sí sostienen la memoria.

## Citas

T1 cita el apartado 8.2, página 12, y separa el LED STATUS apagado como condición que no aplica. La tarjeta de ese apartado corresponde a los pasos publicados.

T2 cita la frase de parpadeo de la sección 5.6 y la presenta, en la lectura, como el significado del LED que el técnico acaba de corregir. Esa unión es el problema de fidelidad. La pregunta posterior distingue fotocélula y entrada #21, y esa parte sí está en el manual.

T3 y T4 citan el mismo apartado de reapertura. La fotocélula informada no se mezcla con #21. La pregunta de #21 se apoya en «La señal de re-apertura tiene prioridad sobre la señal cerrar».

T5 vuelve a citar esa prioridad y la definición del indicador de fotocélula. La lectura une «la fotocélula no está activada» con «el LED de fotocélula se activa cuando…». Es la definición del manual pegada al reporte, no una medición nueva. No bloquea F5 por sí sola.

Las etiquetas «Manual / Guía Danebo» no se evalúan aquí.

## Evidencia que no está en el paquete local

El índice y los logs sí están en `tmp/pilot_exports/2026-10-27_2026-10-27_danebo-legacy/`. Los `capture.json` y `bodies/` no. Se leyeron del contenedor. El índice `partial` se debe a las capturas incompletas de la noche y a dos capturas vacías del mismo día, no a que faltaran las cinco de esta mañana.

No hay copia del comando `APPLIED` dentro de este paquete. El episodio vacío y el id nuevo son la evidencia del caso limpio. El foco ya estaba puesto al llegar el primer mensaje.

## Siguiente paso mínimo

Corregir en local el reconocimiento de un LED genérico cuando la observación es «el LED está encendido, no apagado»: tiene que quedar el estado encendido, salir «apagado» y rechazarse el enlace a «LED parpadeante» / Estado. La comprobación puede reutilizar esta captura, sin otra conversación y sin otra llamada al modelo. Hasta eso, F5 sigue abierta. El orden 3 del plan padre, el plano Elemont, no arranca con este dictamen.
