# Cita literal del intérprete — cinco llamadas, conservación y asociación por separado

Esta corrida no cambia el contrato vigente. El prompt del producto sigue siendo `Rag::TurnInterpreter::PROMPT`, SHA-256 `a5de394a7d87687763b0cd4bd03313ed687a29637698e45e34e05b3aed015b3e`, 8178 bytes. El experimento usa una copia.

La hipótesis era que el modelo puede dejar un hecho solo dentro de una asociación incorrecta, y que pedir una cita literal permitiría conservarlo aunque esa asociación no se acepte. El resultado puede refutarla, y en T2 la refuta: la primera frase no salió en ninguna cita ni en ninguna observación.

## Copia ensayada

La copia del prompt sustituye la instrucción de offsets del párrafo que empieza por «When pending.questions lists parts». El resto de los párrafos queda igual. SHA-256 `669df150364315bc9a3ef272d4bad8e8703b3a5ad91bb13b8ce2e56a00949905`, 8262 bytes. La frase insertada es:

```
quote is the shortest literal substring of turn that carries that answer. Copy it exactly. Every item needs quote. When that text appears more than once in turn, extend quote until it appears once. Do not send a paraphrase. A quote that states a fact of the case is also listed in observations.
```

La frase del desconocimiento declarado pasa de «both start and end on that exact slice» a «that same literal quote».

La copia del esquema mantiene `question_id`, `part_id`, `state` y `supersedes`, exige `quote` como string y retira `start` y `end`. Estados, `maxItems` y el resto de los campos siguen los del producto. SHA-256 del JSON de esa copia: `a933cace52fdd861db9afc57d050dea7f53123ef6e5662ae6585d834516849a8`. El esquema del producto no se envió en la llamada directa y no se modificó.

Ruby busca cada `quote` en el turno original, sin normalizar. Una sola coincidencia exacta produce offsets. Varias producen `quote_ambiguous`. Ninguna produce `quote_not_literal` y deja registrada la diferencia. Una cita localizada que pasa las reglas vigentes de síntoma, literalidad y deduplicación entra en `observations` antes de guardar la asociación. El tope de tres se respeta. La respuesta reinyectada lleva esos offsets y el estado que decidió el modelo.

## Peticiones

Mismo cliente, mismos cinco mensajes de `vf5-t2-candidate-20261103T213216Z`, mismos `episode_before`. Modelo `global.anthropic.claude-haiku-4-5-20251001-v1:0`. Temperatura 0. `max_tokens` 512. Un intento por caso. Sin Retrieve, sin planificación y sin tocar la sesión 198.

| Caso | Contexto | Turno |
| --- | --- | --- |
| t2 | petición capturada | Fue solo la primera apertura. Después volvió a abrir y cerrar como antes. |
| led | petición capturada | El LED STATUS está apagado. |
| mixed | petición capturada | El LED STATUS está apagado. Fue solo la primera apertura. |
| ac | episodio de la captura anterior | Esto pasa solo cuando hace mucho calor afuera. De noche enfría bien. |
| code | episodio de la captura anterior | Muestra E4. Solo aparece después de las dos de la tarde. |

La pregunta de `code` sigue siendo «¿Qué código muestra el display y el ventilador interior gira?». La de `ac` sigue siendo «¿Lo que ves coincide con «El compresor arranca y se detiene a los pocos segundos» o con «El compresor no arranca y el ventilador funciona»?». Ninguna petición trae `form`.

## Reserva y costo

El contador estaba en 180 y el tope de llamadas en 180. La autorización `f2f3-joint-after-134` seguía en US$0.750000 desde el intento 134, con exposición posterior US$0.271722. Comprometido US$1.627451, desconocido US$0.102140, retención US$0, techo global US$4. La reserva de las cinco copias sumaba US$0.060744, dentro del tope de esta evaluación, US$0.10. El paso `180 => 185` se anotó al admitir `vf5-t2-quote-20261103`: cinco llamadas, US$0.100000, `after_attempt` 180.

| Caso | Reserva USD | Liquidado USD | Tokens entrada | Tokens salida | stop_reason |
| --- | --- | --- | --- | --- | --- |
| t2 | 0.012372 | 0.004402 | 3432 | 194 | tool_use |
| led | 0.012326 | 0.004428 | 3418 | 202 | tool_use |
| mixed | 0.012356 | 0.004436 | 3426 | 202 | tool_use |
| ac | 0.011925 | 0.004111 | 3276 | 167 | tool_use |
| code | 0.011765 | 0.004144 | 3219 | 185 | tool_use |
| Suma | 0.060744 | 0.021521 | | | |

Las cinco entradas quedaron `settled`. El comprometido pasó a US$1.648972. Los intentos quedaron en 185, el tope de llamadas en 185, el costo autorizado en US$0.750000 y el techo global en US$4. El desconocido sigue en US$0.102140. La sesión 198 no cambió `updated_at`. Los flujos quedaron en las sesiones nuevas 262 a 266.

La llamada directa lleva el prompt experimental. El flujo reinyecta la respuesta ya adaptada y su captura registra el prompt del producto, SHA-256 `a5de394a…`. No hubo evento `retrieve`, `retrieval_results`, `model_call` ni `companion_plan`. La ruta quedó en `retrieve` con `retrieval` verdadero. `user_transform` fue `none`. `turn_transform` quedó vacío. `field_rejections` y `refused` quedaron vacíos.

## Salida cruda

| Caso | move | Observaciones | quote | Estado | Asociación cruda |
| --- | --- | --- | --- | --- | --- |
| t2 | follow_up | «Después volvió a abrir y cerrar como antes» | «Después volvió a abrir y cerrar como antes» | partial | q1.p1 |
| led | answer_pending | «El LED STATUS está apagado» | «El LED STATUS está apagado» | complete | q1.p1; assert de esa frase |
| mixed | answer_pending | «Fue solo la primera apertura» | «El LED STATUS está apagado» | partial | q1.p1; assert de la frase del LED |
| ac | follow_up | «Esto pasa solo cuando hace mucho calor afuera»; «De noche enfría bien» | ninguna | — | `part_replies` vacío |
| code | answer_pending | «Solo aparece después de las dos de la tarde» | «Muestra E4» | partial | q1.p1; assert «E4» con `slot_hint` `fault_code` |

Todas las citas emitidas aparecen una sola vez en el turno original. No hubo `quote_ambiguous` ni `quote_not_literal`. No hay diferencia de Unicode, mayúsculas ni espacios que analizar en esta corrida.

| Caso | Resolución | Offsets | Nota de observación |
| --- | --- | --- | --- |
| t2 | located | 30–72 | duplicate: la cita ya estaba en las observaciones del modelo |
| led | located | 0–26 | duplicate |
| mixed | located | 0–26 | added: la cita del LED entra en observaciones |
| ac | sin citas | — | las dos frases ya venían como observaciones |
| code | located | 0–10 | added: «Muestra E4» entra en observaciones |

`cap_reached`, `not_literal`, `not_symptom` y `over_length` no aparecieron. El estado de cada respuesta se conservó al adaptarla.

## Resultado tras el flujo

La cobertura de frase mide la oración cuyo cuerpo coincide con una observación o una respuesta guardada. Un fragmento interior no cuenta como la oración. En esta corrida las frases conservadas coinciden con el cuerpo entero; la primera oración de T2 queda en 0 de 28 caracteres.

| Caso | Observaciones tras recarga | Texto reconstruido | Offsets guardados | Estado | p1 | Rechazos | Procedencia | Costo USD |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| t2 | la previa del corte; «Después volvió a abrir y cerrar como antes» | Después volvió a abrir y cerrar como antes | 30–72 | partial | abierta | ninguno | cita literal, offsets de Ruby, flujo vigente, sesión 262 | 0.004402 |
| led | la previa del corte; «El LED STATUS está apagado» | El LED STATUS está apagado | 0–26 | complete | cerrada | ninguno; move pasado a `report` por `pending_answer_incomplete` | igual, sesión 263 | 0.004428 |
| mixed | la previa del corte; «Fue solo la primera apertura»; «El LED STATUS está apagado» | El LED STATUS está apagado | 0–26 | partial | abierta | ninguno; el mismo ajuste de move | igual, sesión 264 | 0.004436 |
| ac | «El aire acondicionado no enfría»; las dos frases del turno | sin respuesta | — | sin respuesta | abierta | ninguno | observaciones del modelo, sin cita, sesión 265 | 0.004111 |
| code | «El climatizador no mantiene el frío»; «Solo aparece después de las dos de la tarde»; «Muestra E4» | Muestra E4 | 0–10 | partial | abierta | ninguno; move pasado a `report`; E4 también queda como `fault_code` | cita «Muestra E4» más la observación temporal, sesión 266 | 0.004144 |

La cita del LED no incluye el punto final. El cuerpo de la oración, sin ese punto, es la cadena guardada. En T2 y en el código la cita tampoco incluye el punto, y el cuerpo de la oración queda cubierto por esa cadena.

## Criterios

Conservación:

- T2 no. Tras la recarga está la segunda frase y falta «Fue solo la primera apertura».
- Mixto sí. Están el LED y «Fue solo la primera apertura».
- Aire acondicionado sí. Están las dos frases.
- Código sí. Están «Muestra E4» y «Solo aparece después de las dos de la tarde».

Asociación y estado:

- T2 no. Hay una respuesta `partial` de q1.p1 sobre la segunda frase.
- Aire acondicionado sí. No hay respuesta asociada a la pregunta pendiente.
- Directo y mixto no quedan en la misma respuesta `complete`. El directo cierra p1 en `complete` con «El LED STATUS está apagado». El mixto guarda esa misma cadena en `partial` y deja p1 abierta.
- Código sí. La respuesta es `partial`, el texto reconstruido es «Muestra E4» y la frase temporal queda fuera de esa respuesta.

La lectura automática deja `conservation` en falso, `association` en falso, `partial` en falso y `quote_supported` en falso. `approves_interpreter` y `approves_script_2` quedan en falso. La mejora de conservación en el mixto, el aire y el código, con T2 todavía incompleto y con el mixto en `partial`, es una mejora parcial. No aprueba el intérprete ni el guion 2.

## Qué dice la hipótesis

La cita sirvió cuando el modelo escribió el hecho en algún campo. En el mixto, «El LED STATUS está apagado» salió solo como `quote` de una asociación `partial`; Ruby la copió a observaciones y sobrevivió a la recarga. En el código, «Muestra E4» salió como cita de la respuesta y también quedó como observación, separada de la frase temporal. En el aire, el modelo ya había puesto las dos frases en observaciones y no envió asociación.

En T2 el modelo no emitió la primera frase. No había una cita incorrecta de la que rescatarla. Pedir `quote` no crea el hecho ausente. Las cinco citas que sí envió eran literales y únicas, así que esta corrida no ejercitó `quote_ambiguous` ni `quote_not_literal`. Esas dos salidas están cubiertas por las pruebas deterministas, no por el modelo.

## Verificación

`test/services/rag/quote_reply_experiment_test.rb` cubre cita única, cita repetida, cita solapada, cita ausente, diferencia de mayúsculas, espacios y normalización Unicode, conservación con el estado `partial` intacto, tope de tres y una lectura en la que la conservación puede cumplirse con la asociación todavía falsa. La suite completa terminó en 5276 pruebas, 0 fallos y 0 errores. RuboCop pasó en los archivos de la autorización y del experimento.

## Evidencias

No están en el repositorio.

- `tmp/field_companion/vf5_t2_interpreter/vf5-t2-quote-20261103T225253Z/summary.json` — cinco llamadas, lectura y costo
- `tmp/field_companion/validation_captures/vf5-t2-quote-20261103T225253Z/` — cada caso y su flujo
- `tmp/field_companion/vf5_generator_benchmark/assignment_spend.json` — archivo local; intentos 185, techo US$4, ejecución `vf5-t2-quote-20261103`

## Recomendación

No adoptar `quote` como contrato del producto con este resultado. El cálculo de offsets y la copia de una cita válida a observaciones funcionan, y conviene conservar ese mecanismo cuando se decida el contrato, porque separó «Muestra E4» de la condición horaria y guardó el LED del turno mixto aunque el estado haya quedado en `partial`.

El problema pendiente es la asociación. T2 sigue respondiendo la pregunta del LED con una sola frase y omite la otra. El turno mixto sigue marcando el mismo LED como `partial` en lugar del `complete` del turno directo. Otra corrida de la misma copia no está justificada: las cinco llamadas ya muestran que la cita no recupera un hecho que el modelo no escribe.
