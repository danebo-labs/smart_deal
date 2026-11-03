# Candidata del intérprete — bloqueo de US$0,06 y ejecución de US$0,07

El prompt de esta candidata es `Rag::TurnInterpreter::PROMPT`, SHA-256 `a5de394a7d87687763b0cd4bd03313ed687a29637698e45e34e05b3aed015b3e`, 8178 bytes. Este informe no aprueba el texto para despliegue.

Hay dos momentos distintos. La corrida `vf5-t2-candidate-20261103T211816Z` preparó las cinco peticiones y se detuvo antes de llamar al modelo porque la reserva sumaba US$0.060379 y el tope de aquella evaluación era US$0.06. La corrida `vf5-t2-candidate-20261103T213216Z` usó el mismo prompt, el mismo modelo y las mismas cinco peticiones, con el tope de esta evaluación ampliado a US$0.07, y sí llamó al modelo.

Sustituye dos párrafos del prompt que estaba en `6c518bd` (SHA-256 `ef088eac3b579224a2eb914bb0c5a44235f46b3b6dcfda44f5d696e7197d43a1`). El resto del prompt no cambia. El párrafo ensayado en `vf5-t2-interpreter-20261103T204811Z` no forma parte de esta candidata; su texto y su hash están en [INFORME_INTERPRETE_VF5_T2_20261103T204811Z.md](INFORME_INTERPRETE_VF5_T2_20261103T204811Z.md).

## Párrafos

`documented_context`:

```
When pending.clarification_target is documented_context, the turn may answer a published part, state other facts of the case, or both. A slice answers a part only when it states what that part asks: the value, the yes or no, which published option matches, or that none matches. A fact of the same case that states something else does not answer that part, even when it makes one option more or less likely. That fact is an observation and has no part_reply. complete = the slice states everything the part asks. partial = the part asks for more than one thing and the slice states only some of them. unknown = the technician says they do not know or cannot see what the part asks. contradictory = the turn gives answers to that part that cannot both be true. A fact next to an answer does not change that answer's state. A turn that answers no part has no part_replies. An answer that states what the technician sees is also an observation. A partial answer does not fill the missing part. Example: the part asks "¿El manómetro marca más o menos de 2 bar, y la aguja oscila?". "Marca 1,5." is partial. "Marca 1,5 y no oscila." is complete. "Desde ayer la bomba arranca cada diez minutos." answers no part: it is an observation with no part_reply.
```

El párrafo que comienza por «Every span»:

```
Every span is the shortest literal substring of turn, not the sentence. observations holds up to three facts of the case stated in this turn, one contiguous literal phrase each, or is empty. The reported fault and what the technician sees or does not see are observations, not identifiers and not checks. So are when it happens, how often, under which condition, and how it changed, also when the phrase refers to a fault already in work_context without repeating it. Keep every word between its ends. Do not drop words. Do not paraphrase. Do not invent an observation. Do not describe the photo. A correction of manufacturer, model, controller, or fault code still negates the stored value and asserts the replacement. Keep every other symptom in that same turn as an observation. A correction of an observation keeps the replacement phrase as the observation and does not need a slot negate or an assert span.
```

## Lo que se iba a enviar

El mismo cliente, la petición capturada de T2 y el esquema vigente. Modelo `global.anthropic.claude-haiku-4-5-20251001-v1:0`. Temperatura 0. `max_tokens` 512. El esquema enviado coincide con el del producto. No hay Retrieve ni un sexto caso.

Los tres primeros casos reutilizan el mensaje capturado y solo cambian el turno. Los dos últimos son episodios sintéticos, abiertos con `ActiveEpisode` y sellados con `AnswerContract.stamp!`. Cada uno queda con `qc` 1, pregunta `q1` y parte `p1`.

| Caso | Contexto | Turno | Objetivo sintético |
| --- | --- | --- | --- |
| t2 | petición capturada | Fue solo la primera apertura. Después volvió a abrir y cerrar como antes. | — |
| led | petición capturada | El LED STATUS está apagado. | — |
| mixed | petición capturada | El LED STATUS está apagado. Fue solo la primera apertura. | — |
| ac | sintético, q1.p1 | Esto pasa solo cuando hace mucho calor afuera. De noche enfría bien. | El aire acondicionado no enfría |
| code | sintético, q1.p1 | Muestra E4. Solo aparece después de las dos de la tarde. | El climatizador no mantiene el frío |

La pregunta de `ac` es «¿Lo que ves coincide con «El compresor arranca y se detiene a los pocos segundos» o con «El compresor no arranca y el ventilador funciona»?». La de `code` es «¿Qué código muestra el display y el ventilador interior gira?».

## Reserva

La reserva es la que usaría `BedrockClient#converse`: un token por carácter de los argumentos y el `max_tokens` del pedido, con el precio de Haiku 4.5 global. El contador del archivo estaba en 175 intentos, tope de llamadas 175, costo autorizado US$0.750000 desde el intento 134, exposición posterior US$0.250261, comprometido US$1.605990, desconocido US$0.102140, retención US$0, techo global US$4. No se anotó otro paso de llamadas.

| Caso | Reserva USD |
| --- | --- |
| t2 | 0.012299 |
| led | 0.012253 |
| mixed | 0.012283 |
| ac | 0.011852 |
| code | 0.011692 |
| Suma | 0.060379 |

El tope de esta evaluación es US$0.060000. La suma lo pasa por US$0.000379. Las cuatro primeras reservas suman US$0.048687 y dejan US$0.011313; la quinta pide US$0.011692. No se aumentó el presupuesto ni el tope de llamadas. El archivo sigue en 175. La sesión 198 no se abrió en este preflight.

## Evidencias

No están en el repositorio.

- `tmp/field_companion/vf5_t2_interpreter/vf5-t2-candidate-20261103T211816Z/preflight.json` — preflight completo, estado `blocked`, motivo `ceiling`
- `tmp/field_companion/vf5_t2_interpreter/vf5-t2-candidate-20261103T211639Z/preflight.json` — el mismo bloqueo, sin el desglose; el proceso reemplazó el detalle al salir

## Veredicto del bloqueo

En `211816Z` no hay resultado de interpretación. El modelo no vio estos cinco turnos. El problema de aquella preparación era de cupo: con este prompt, estas cinco peticiones no reservan dentro de US$0.06.

## Ejecución `vf5-t2-candidate-20261103T213216Z`

El contador seguía en 175. El paso existente `175 => 180` se anotó al admitir la ejecución `vf5-t2-candidate-20261103`: cinco llamadas, US$0.070000, `after_attempt` 175. El historial anterior quedó en el archivo. El costo autorizado sigue en US$0.750000 desde el intento 134. El techo global sigue en US$4. El prompt, el modelo, la temperatura, `max_tokens`, los contextos y los criterios no se modificaron para esta corrida.

Un preflight anterior de la misma preparación, `vf5-t2-candidate-20261103T213135Z`, ya tenía la suma US$0.060379 dentro de US$0.07 y salió antes de admitir porque el proceso veía la sesión compartida activa. No reservó ni llamó. La ejecución partió con `SHARED_SESSION_ENABLED=false`, que es la condición con la que el corredor preparado sigue, y entonces admitió e hizo las cinco llamadas. Cada llamada fue el intento 1, `stop_reason` `tool_use`, sin reintento. No hubo evento `retrieve`, `retrieval_results`, `model_call` ni `companion_plan`. La decisión de ruta quedó en `retrieve` con `retrieval` verdadero, igual que la captura de origen. La sesión 198 no cambió su `updated_at`. Los flujos se grabaron en sesiones nuevas, 252 a 256.

`user_transform` fue `none` en los cinco. `turn_transform` quedó vacío. No hubo `field_rejections`. Ningún `part_reply` trajo `start` ni `end`. El contrato toma esa omisión como cita del turno entero, y `AnswerContract.reconstruct` devuelve el mensaje completo cuando la respuesta no tiene `a` ni `b`. Ruby aceptó las cinco estructuras. Esa aceptación no es el veredicto.

| Caso | Observaciones del modelo | Asociación | Estado | Offsets | Texto reconstruido | Transformación | Persistencia | Costo USD |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| t2 | «Después volvió a abrir y cerrar como antes» | q1.p1 | partial | ausentes | Fue solo la primera apertura. Después volvió a abrir y cerrar como antes. | move `follow_up`; sin ajustes | r1 guardada y recargada; p1 sigue abierta | 0.004322 |
| led | «El LED STATUS está apagado» | q1.p1; assert «El LED STATUS está apagado» | complete | ausentes | El LED STATUS está apagado. | move `answer_pending` pasado a `report` por `pending_answer_incomplete`; el assert queda como identificador | r1 guardada y recargada; p1 queda cerrada | 0.004373 |
| mixed | «Fue solo la primera apertura» | q1.p1; assert «El LED STATUS está apagado» | partial | ausentes | El LED STATUS está apagado. Fue solo la primera apertura. | igual que led: `answer_pending` a `report`, assert como identificador | r1 guardada y recargada; p1 sigue abierta | 0.004366 |
| ac | «Esto pasa solo cuando hace mucho calor afuera»; «De noche enfría bien» | q1.p1 | unknown | ausentes | Esto pasa solo cuando hace mucho calor afuera. De noche enfría bien. | move `follow_up`; sin ajustes | r1 guardada y recargada; `unknown` cierra p1 | 0.004211 |
| code | «Solo aparece después de las dos de la tarde» | q1.p1; assert «E4» con `slot_hint` `fault_code` | partial | ausentes | Muestra E4. Solo aparece después de las dos de la tarde. | `answer_pending` a `report` por `pending_answer_incomplete`; E4 queda como hecho `fault_code` | r1 guardada y recargada; p1 sigue abierta | 0.004189 |

Reservado US$0.060379. Liquidado US$0.021461. El comprometido del archivo pasó de US$1.605990 a US$1.627451. Los intentos quedaron en 180, el tope de llamadas en 180 y el techo global en US$4. Las cinco entradas están `settled`.

### Cortes de palabras

Ningún `part_reply` trae un rango, así que no hay corte dentro de una palabra medible por offsets. El texto reconstruido de cada respuesta es el turno completo.

Las observaciones conservan las palabras de la frase que el modelo eligió y omiten el punto final:

- t2: la segunda frase, sin el punto. La primera frase, «Fue solo la primera apertura.», no está en `observations`.
- led: «El LED STATUS está apagado», sin el punto.
- mixed: «Fue solo la primera apertura», sin el punto. «El LED STATUS está apagado» está en el assert, no en `observations`, y también sin el punto.
- ac: las dos frases, cada una sin su punto.
- code: «Solo aparece después de las dos de la tarde», sin el punto. «E4» está en el assert.

### Lectura de los criterios

t2 no cumple. Falta la primera frase como observación y hay un `part_reply` partial sobre el turno entero. p1 permanece abierta.

led cumple la lectura semántica: p1 queda `complete` y la frase del LED es una observación. El punto final no está en esa cadena. El cambio de move a `report` queda registrado arriba.

mixed no cumple. p1 queda `partial`, no `complete`, y solo la segunda frase entra en `observations`.

ac cumple las dos observaciones literales. El `part_reply` `unknown` no está pedido: asocia el turno a q1.p1 y, al ser un estado asentado, cierra la parte.

code conserva el partial, deja la frase temporal como observación y afirma E4. p1 sigue abierta. La omisión de offsets hace que el texto almacenado sea el turno entero, incluida la frase temporal. Ese desvío de fragmento queda separado del hecho de que el partial sí sobrevivió.

Que Ruby haya guardado las cinco respuestas no aprueba ningún caso. El acierto de led no se extiende a t2, mixed ni ac. El partial de code no se perdió. La candidata, con estas cinco llamadas, no separa las dos frases de T2 ni deja el mixto en el mismo estado que el directo.

## Evidencias de la ejecución

Tampoco están en el repositorio.

- `tmp/field_companion/vf5_t2_interpreter/vf5-t2-candidate-20261103T213135Z/preflight.json` — techo dentro de US$0.07, salida por sesión compartida, sin admisión
- `tmp/field_companion/vf5_t2_interpreter/vf5-t2-candidate-20261103T213216Z/summary.json` — cinco llamadas, costo y estado recargado
- `tmp/field_companion/validation_captures/vf5-t2-candidate-20261103T213216Z/` — `t2`, `led`, `mixed`, `ac`, `code` y cada flujo `*-flow`
- `tmp/field_companion/vf5_generator_benchmark/assignment_spend.json` — archivo local; intentos 180, techo US$4, ejecución `vf5-t2-candidate-20261103`
