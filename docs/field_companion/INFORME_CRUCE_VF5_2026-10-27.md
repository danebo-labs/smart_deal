# Cruce VF5 — mismas capturas en `4eca6b3` y `a829713`

Investigación. No cambia el companion, no declara F5 aceptada y no abre Elemont.

## Veredicto

La única diferencia de código entre las dos versiones, sobre estas capturas, está en T2 cuando la observación es «el LED está encendido, no apagado».

`4eca6b3` deja «apagado» y publica «parpadeante». `a829713` guarda «el LED está encendido», saca «apagado», rechaza ese enlace por `led_context` y añade la pregunta de cuál indicador. La pregunta aceptada sigue siendo la de #21.

T3, T4 y T5 del mediodía no son una regresión de ese arreglo. Las dos versiones, con el intérprete, los chunks y el plan congelados, producen el mismo estado y el mismo texto. El fallo aparece porque el modelo del mediodía no devolvió las mismas herramientas que el de la mañana.

## Qué se cruzó

Dos muestras del 27 de octubre, cuenta `danebo-legacy`, sesión 128, VF5 documento 212.

| Muestra | Episodio | Código que la produjo | Capturas |
|---|---|---|---|
| Mañana | `ep_1f3018d3f7f12e8c` | `4eca6b3` | `/tmp/vf5_f5_20261027` |
| Mediodía | `ep_d294657afb4bf7c9` | `a829713` | `/tmp/vf5_a829713` |

Cada turno se reejecutó en las dos revisiones. El intérprete es el `tool_input` capturado. El plan es el `tool_input` capturado. Los cuerpos recuperados son los de la captura. No hay llamada a Bedrock ni a S3. La revisión nueva del replay es `0b75ad6`: el producto es `a829713` y el commit de más es solo el informe del mediodía.

Dos modos:

- **Turno congelado.** El episodio de entrada es el `episode_before` de esa captura. Mide el código de ese turno, sin arrastrar el turno anterior.
- **Recorrido.** El estado sale del turno anterior de la misma revisión, y el plan sigue siendo el de la captura. Si el reducer cambia los ids, un enlace del plan puede quedar `unknown_fact`. Eso no es lo que el modelo habría planificado de nuevo.

El diff de producto entre `4eca6b3` y `a829713` son cinco archivos: `observation_correction.rb`, `turn_perception.rb`, `companion_case_facts.rb`, `companion_plan_check.rb`, `companion_plan_render.rb`.

## Calibración

En el mediodía, las dos revisiones reproducen los cinco turnos. El reducer coincide con la captura, la consulta efectiva coincide y el texto publicado coincide. T4 queda `invalid_schema` y T5 queda `meta_incompatible`, igual que en la GUI.

En la mañana, el reducer coincide en T1 y en T3–T5 en las dos revisiones. El reducer de T2 coincide solo en `4eca6b3`. El texto de T1 coincide en las dos. El texto de T2 coincide solo en `4eca6b3`. El texto de T3–T5 de la mañana no coincide con la captura en ninguna de las dos revisiones, y las dos revisiones coinciden entre sí. Esa diferencia contra la captura es del arnés, no del arreglo.

El arnés lee las definiciones de un espejo local. Una frase difiere de la que vio el modelo: la captura dice «Esta valor es regulable de 60 a 150Nm» y el espejo dice «Este valor es regulable de 60 a 150 Nm». En el mediodía el texto publicado igual se reproduce. En T3–T5 de la mañana el texto no se reproduce. Los ids de algún apartado de definición no caen en el mismo número. Como las dos revisiones se desvían igual, la comparación entre ellas sigue en pie. La comparación de ese texto contra la GUI de la mañana no.

`updated_at` del episodio se reescribe a la hora del replay para que la ventana de cuatro horas no lo venza. La comparación no usa esas marcas.

## Hecho: el código solo mueve T2

Turno congelado de la mañana, misma observación «el LED está encendido, no apagado»:

| | `4eca6b3` | `a829713` |
|---|---|---|
| Observaciones | Sigue «El LED está apagado» y se añade la frase completa | Queda «el LED está encendido». No queda «apagado» |
| Enlace del parpadeo | Sigue | `led_context` |
| Texto | Contiene «parpadeante» y la pregunta de #21 | No contiene «parpadeante». Contiene #21 y «¿Cuál LED está encendido, el de Fotocélula o el de Estado?» |
| Consulta efectiva | Igual a la captura. Incluye «El LED está apagado» | Ya no incluye «El LED está apagado» |

T1 y T3–T5, en las dos muestras, tienen el mismo estado de reducer en las dos revisiones. El checker del mediodía es el mismo en las dos, incluido T2: la observación capturada ahí es «el LED está encendido», sin la cola «no apagado». Esa frase ya coincidía con el patrón viejo. Por eso el mediodía pasa T2 también en `4eca6b3`.

El recorrido con los planes congelados dice lo mismo. En la mañana, lo único que cambia de una revisión a la otra son las observaciones del LED y «parpadeante» en T2. #21 sigue siendo la pregunta pendiente en T2–T4, y T5 ata `unknown` a «¿Está activada la fotocélula o la entrada de re-apertura (#21)?». En el mediodía el recorrido es idéntico en las dos revisiones, del T1 al T5.

En el recorrido de la mañana sobre `a829713`, el enlace de parpadeo cae por `unknown_fact`, no por `led_context`: el plan viejo nombra un id que el reducer nuevo ya no tiene. El rechazo `led_context` queda demostrado en el turno congelado, donde los ids son los de la captura.

## Hecho: las dos muestras no le dieron al código la misma herramienta

El texto del técnico es el mismo en T1, T3, T4 y T5. En T2 no.

| | Mañana | Mediodía |
|---|---|---|
| T2 recibido | «orrijo un dato: el LED está encendido, no apagado.» | «Corrijo un dato: el LED está encendido, no apagado.» |
| T2 observación del intérprete | «el LED está encendido, no apagado» | «el LED está encendido» |

El resto es variación del modelo con el mismo texto de entrada, o consecuencia de que el turno anterior ya era otro.

T1. El intérprete coincide. El plan no. La mañana pregunta «¿Está activado el LED de la fotocélula o hay alguna señal de re-apertura (#21) conectada continuamente?» y esa pregunta no queda pendiente. El mediodía pregunta «¿Está activada la fotocélula o la entrada de re-apertura (#21)?» y sí queda. El mediodía además guarda el identificador «operador de puerta». Las dos revisiones reproducen cada uno de esos resultados. El código no elige entre ellos.

T3. Los dos intérpretes vienen como `answer_pending` y la percepción los deja en `report`. El sujeto de la fotocélula no es el mismo: «la fotocélula» y «fotocélula». El plan de la mañana pregunta solo por #21. El plan del mediodía pregunta «¿El LED encendido es el de Fotocélula o el de Estado?». Las dos revisiones aceptan esa pregunta y la guardan como pendiente. #21 deja de serlo. No hace falta el arreglo de `a829713` para ese reemplazo: `4eca6b3` hace lo mismo con ese plan.

T4. La mañana clasifica `follow_up` y el esquema es válido. El mediodía manda `checks: null`. La percepción es inválida. Las dos revisiones guardan el texto «¿Qué sigue?» como observación y siguen con el plan capturado. Ese plan vuelve a preguntar cuál LED. El destino publicado hacia el síntoma STATUS de la página 13 está en la captura; el replay no vuelve a recuperar, así que no reasigna ese destino por su cuenta.

T5. La mañana manda `answer_pending`, con la observación del desconocimiento, y la percepción queda `report`. El mediodía manda `meta` y `checks: null`. Las dos revisiones lo rechazan por `meta_incompatible`, guardan la frase y marcan `unknown` sobre la pregunta que ya estaba pendiente. En la mañana esa pregunta es la de #21. En el mediodía es la del LED. El texto del mediodía cita el síntoma STATUS. Las dos revisiones lo hacen.

## Interacción

Hay tres causas, y no se sustituyen.

1. **Código.** Cierra el T2 de la mañana, el de la frase completa. No cambia el manejo de T3–T5.
2. **Modelo, antes de ese arreglo.** T1 ya toma otra pregunta y otro identificador. T2 del mediodía ya trae la observación corta, que el código viejo también sabe guardar.
3. **Modelo, después del estado.** T3 del mediodía pide el LED en vez de #21. T4 trae un esquema inválido. T5 trae `meta`. Esas tres herramientas, pasadas por el código viejo, dan el mismo fallo que la GUI del mediodía.

La consulta de T2 en la mañana sí cambia con el código nuevo: deja de nombrar «El LED está apagado». El replay no vuelve a recuperar. Una corrida viva podría traer otros chunks. Eso no está medido.

## Lo que esto no demuestra

No demuestra que el modelo, si T2 hubiera seguido con «apagado», habría preguntado #21 en T3. El plan del mediodía se generó con «encendido» ya guardado. No se volvió a muestrear.

No demuestra que T4 y T5 fallen por el arreglo del LED. Fallan con las dos revisiones en cuanto el modelo manda `checks: null` o `meta`.

No reabre F2–F4. No acredita el pin automático. No abre Elemont.

## Preguntas abiertas

1. El siguiente defecto reproducible, separado del LED, es el par T4–T5: un `follow_up` con `checks` nulo no debe guardarse como observación, y un `meta` que nombra #21 y el contacto #21–#23 no debe quedar atado a la pregunta que haya quedado pendiente. ¿Ese par se trata con el episodio del mediodía, sin otra conversación?
2. T3 reemplaza #21 porque el plan trae la pregunta del LED y el checker la acepta. ¿Hace falta una regla para no sustituir #21 cuando el turno no la contesta, o primero hay que ver si un modelo nuevo, con el T2 ya corregido, sigue pidiendo el LED?
3. La consulta de T2 ya no incluye «apagado». ¿Hay que medir si eso cambia los chunks, o el texto congelado de esta captura alcanza para el criterio?

## Reproducción

```bash
# revisión nueva, desde la raíz del repo
BUNDLE_PATH=vendor/bundle RAILS_ENV=test bin/rails runner /tmp/vf5_cross_replay.rb

# revisión de la mañana
git worktree add --detach /tmp/danebo-4eca6b3 4eca6b3
cd /tmp/danebo-4eca6b3
BUNDLE_PATH=/Users/lahirisan/smart_deal/vendor/bundle RAILS_ENV=test bin/rails runner /tmp/vf5_cross_replay.rb
```

Salidas: `/tmp/vf5_replay_out/0b75ad6cf6570e70ddc3b2d60016470f76f8df93.json` y `/tmp/vf5_replay_out/4eca6b32451583c29c5d705946cd40b12ab6e15e.json`. El arnés es `/tmp/vf5_cross_replay.rb`. El espejo de chunks es `/Users/lahirisan/Documents/Codex/2026-10-21/new-chat/work/vf5_s3`. Nada de eso está en git.
