# Candidata del intérprete — reserva por encima de US$0,06

Corrida `vf5-t2-candidate-20261103T211816Z`. El prompt de esta candidata es `Rag::TurnInterpreter::PROMPT`, SHA-256 `a5de394a7d87687763b0cd4bd03313ed687a29637698e45e34e05b3aed015b3e`, 8178 bytes. No se llamó al modelo. Este informe no aprueba el texto para despliegue.

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

## Veredicto

No hay resultado de interpretación. El modelo no vio estos cinco turnos, así que no se puede decir si las dos frases de T2 quedan sueltas, si el directo y el mixto coinciden, si el fragmento mixto corta una palabra, ni si el partial del código sobrevive. El problema pendiente es de cupo: con este prompt, estas cinco peticiones no reservan dentro de US$0.06.
