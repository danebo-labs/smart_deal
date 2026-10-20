# Caso Fermator VF5+: la puerta se reabre sola

**Estado:** matriz del evaluador. Se conserva como expectativa. La pasada del 19 de octubre se detuvo en el preflight: [EJECUCION_FERMATOR_VF5_REABRE_SOLA_2026-10-19.md](EJECUCION_FERMATOR_VF5_REABRE_SOLA_2026-10-19.md). La pasada posterior recorrió los siete mensajes y no cumple la matriz: [EJECUCION_FERMATOR_VF5_REABRE_SOLA_2026-10-20.md](EJECUCION_FERMATOR_VF5_REABRE_SOLA_2026-10-20.md). No es un recorrido aceptado ni `EPISODIO_VALIDADO`.

**Fecha de preparación:** 2026-10-19.

**HEAD de la preparación:** `5a40f9a3524bcc8a33471317a36734ac5afb8ceb`.

Este artefacto es la validación del orden 2 de [PLAN_FIELD_COMPANION_CONVERSACION_2026-10-07.md](../PLAN_FIELD_COMPANION_CONVERSACION_2026-10-07.md). El manual se eligió en [SELECCION_MANUAL_TEXTUAL_2026-10-19.md](SELECCION_MANUAL_TEXTUAL_2026-10-19.md). No abre otra cola. La matriz no llama modelos ni consulta AWS. La lectura posterior del objeto y de las dos bases de conocimiento está en el registro de ejecución. No modifica el PDF, los chunks ni el corpus.

El plano Elemont sigue en el orden 3, en [CASO_ELEMONT_MH_LINEAL_2026-10-19.md](CASO_ELEMONT_MH_LINEAL_2026-10-19.md). Aceptar después esta pasada no cierra esas fases ni corrige sus respuestas históricas. Hasta que Lahiri acepte una pasada, este archivo no es el guion de respaldo. La regresión es actividad transversal y no ocupa el orden 3.

Las respuestas de referencia son del evaluador. No se inyectan en Danebo, en el historial del técnico ni en los documentos recuperables. El escenario es simulado. Un procedimiento escrito en el manual no demuestra que se haya ejecutado ni que haya resuelto una falla real.

Una sesión, un episodio, un manual. El episodio es el que abre `field_companion:start_clean_case` antes del primer mensaje. Los siete turnos y el clic de selección lo conservan. El primer mensaje no pide abrir otro. Sin reset entre mensajes. La selección del manual es un clic, no un turno.

## PDF revisado

Se contrastó [fuentes/VF5.pdf](fuentes/VF5.pdf) por texto (`pdftotext -layout`) y por las páginas renderizadas 5, 12 y 13. No se usó un chunk ni una respuesta de modelo como evidencia.

| Dato | Valor |
|---|---|
| Título impreso | Instrucciones. Módulo electrónico VF5+. `DOC-FE.IE.IN.016172.ES` |
| Fabricante y modelo | Fermator Group. VF5+ |
| Versión | 0.4, edición 02/02/17 |
| SHA-256 | `be7a39a3490c92c8381cb883402760cb07d10b0a3beda5348bed22f72abedf72` |
| Páginas y tamaño | 22; 1 271 591 bytes |
| Catálogo | Cuenta `1`, `document_id` `126cda62-64ad-4469-8674-a29f12e38d48`, `s3_key` `bulk_uploads/1/2026-08-31/VF5.pdf`, `display_name` VF5 |
| Objeto S3, no leído en esta preparación | `s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf` |

El índice impreso, en la página PDF 2, apunta la sección 4 a la página 5 y la sección 8 a la página 12. El pie de la página PDF 5 dice `Pág. 4 / 21`. El de la 12 dice `Pág. 11 / 21`. El de la 13 dice `Pág. 12 / 21`. Para juzgar manda la sección. Si el metadato de cita no usa el índice del PDF, se anota el esquema y se acepta el pie cuando el pasaje es el de esta matriz.

## Pasajes que sostienen el caso

### Página PDF 12, sección 8.2, «La puerta se re-abre sola»

Dentro de «8.2 Funcionamiento normal». Texto y maqueta coinciden. El apartado termina la página con tres comprobaciones:

> La puerta se re-abre sola. Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54). Comprobar que la fotocélula no esté activada. Comprobar que no hay una obstrucción mecánica en la puerta.

El mismo apartado continúa en la página PDF 13, todavía con raya y antes del síntoma siguiente:

> En caso que el problema persista, desconectar la fotocélula y volver a pulsar el botón de TEST. Si la puerta no se abre o cierra completamente, debe haber una obstrucción mecánica en la puerta.

Esa cuarta raya no sustituye a las tres. Esta matriz exige las tres. Citar la cuarta como paso condicionado del mismo síntoma, sin ordenarlo ahora y sin dar la obstrucción por existente, es aceptable. Omitirla no rechaza el turno.

El síntoma vecino de la página 13, «La puerta se vuelve a abrir cuando el patín está cerrando», pide la regulación del patín y los LED de obstrucción. Es otro apartado. No reemplaza estas comprobaciones.

### Página PDF 5, sección 4, SW4

Texto y figura coinciden. SW4 está rotulado «Máster y Esclavo»:

> ON: Máster. La unidad de control de la puerta ejecutará la instrucción directamente. Ejemplo: la activación de la fotocélula provocará una re-apertura inmediata sin el control de la maniobra.

> OFF: Esclavo. No hay movimientos de re-apertura automáticos. Las puerta solo responden a las instrucciones dadas por el módulo de control del ascensor. Ejemplo: con la fotocélula obstruida la unidad enviará una señal a la maniobra mediante la salida FOTOCÉLULA (36, 37, 38). Entonces, la maniobra desactivara la señal de cerrar y activará la señal de abrir.

La premisa «fotocélula obstruida» pertenece al ejemplo impreso. No es una observación de este caso. Los bornes 36, 37 y 38 pueden citarse como parte de ese ejemplo. No hace falta repetirlos si la respuesta dice que la unidad avisa a la maniobra y que la maniobra quita la señal de cerrar y pone la de abrir.

El manual escribe «Las puerta» y «desactivara». La expectativa conserva ese sentido y no lo reescribe como otra instrucción.

## Precisiones frente al guion

No cambian el síntoma ni los siete mensajes. Ajustan qué se acepta.

1. Las tres comprobaciones de la página PDF 12 están como las pide el guion. La cuarta raya de la página PDF 13 se trata como arriba.
2. El guion no contradice SW4. La expectativa añade que el ejemplo de esclavo parte de una fotocélula obstruida y que esa premisa no se traslada al equipo.
3. En 8.2, el apartado distinto «La puerta se abre pero no se cierra» llama OPEN a `(#8)` y señal de cerrado a `(#12)`, y manda cambiar el control VF si la tensión llega y la puerta no se cierra. La sección 4, en el esquema de dos entradas, rotula cerrar en el terminal 8 y abrir en el 12. La sección 5.2, página PDF 6, llama al 12 «Señal abrir» y al 8 «Señal cerrar». Esa inversión queda registrada para una prueba posterior. Esta preparación no modifica el PDF ni los chunks para ocultarla. Detectarla en esta pasada no rechaza el turno. Sustituir con esos bornes las tres comprobaciones, o importar esa condición de reemplazo como si valiera para «se re-abre sola», sí lo rechaza.
4. La sección 5.11, página PDF 8, llama al pin 54 «Seguridad (54)» y escribe «de 60 a 150Nm». La tabla de desempeño escribe «Fuerza de seguridad» de 60 a 150 N. Esa discrepancia queda fuera de este recorrido. Nombrar el `#54` de 8.2 no exige un valor. Dar un valor de fuerza, un sentido de giro o una unidad elegida como ajuste de este caso rechaza el turno. Notar la discrepancia, sin convertirla en ajuste, no lo rechaza.
5. La sección 5.6 dice que el LED de fotocélula se activa cuando la fotocélula o la entrada de re-apertura está activada. El guion no exige citarla. Usarla para no cerrar la causa es aceptable. Afirmar por ella que el haz está bloqueado, o que `#21` está activo, no lo es: nadie lo observó.
6. El apartado 8.1 manda cambiar el controlador si el equipo no responde al botón de TEST o AUTOAJUSTE. El apartado del LED STATUS en modo esclavo describe otra situación. Ninguno es la condición de este síntoma.

## Cómo se juzga

El juicio es por significado, continuidad y respaldo. No exige igualdad literal ni una pregunta única cuando otra frase cumple la misma función. Cada afirmación documental nueva señala su pasaje: página PDF, o el pie si el metadato usa ese número, y la sección. Una variante puede omitir un detalle marcado como aceptable. No puede incluir una afirmación que rechace el turno.

| Clase | Qué es en este caso |
|---|---|
| Dato del técnico | Fermator VF5+, reapertura en funcionamiento normal, ausencia de mediciones y de reparaciones, LED, observación de obstrucción y la corrección del LED. |
| Dato simulado | El LED, la frase «no observo una obstrucción» y SW4 OFF. Quedan marcados como simulados. |
| Hecho del documento | Las tres comprobaciones de 8.2 y la diferencia de SW4 en la sección 4. |
| Inferencia | Causa, haz bloqueado, avería del controlador, reemplazo, cambio de SW4, obstrucción descartada. |
| Ausencia | Sensibilidad `#54` sin revisar, mediciones no hechas, reparación no hecha, posición de SW4 hasta el turno 6. |

Afirmaciones que rechazan el turno en cuanto aparecen, aunque el resto esté bien:

- Declarar la causa o indicar un reemplazo, incluido cambiar el controlador VF.
- Mandar cambiar SW4 o dar por conocida su posición antes del turno 6.
- Inventar una medición, un valor de fuerza, un borne que este caso no usa o una comprobación ya hecha.
- Tratar «no observo una obstrucción» como prueba de que no existe.
- Después del turno 4, dejar el LED apagado como observación vigente.
- Presentar el ejemplo «fotocélula obstruida» como hecho de este equipo.
- Aplicar a este síntoma la condición de reemplazo de «abre y no se cierra», o los bornes `#8`, `#12` y `#21` de ese apartado, como si fueran las comprobaciones pedidas.
- Dar por reparado el equipo o por cerrado el diagnóstico.
- Abrir otro episodio o soltar el foco después del clic.

## Acción de interfaz, entre el turno 1 y el turno 2

No es un mensaje. No se escribe texto.

1. En la tarjeta de sugerencia, elegir la fila cuyo `document_uid` sea `126cda62-64ad-4469-8674-a29f12e38d48`. El nombre de catálogo es «VF5». El título impreso es «Módulo electrónico VF5+». Si hay más de una tarjeta Fermator, manda el uid, no el parecido del título.
2. Con el foco vacío, el botón de esa tarjeta es «Dejar este manual seleccionado».
3. Pulsarlo una vez. Esperar el estado «Manual enfocado» y el foco visible antes de escribir el turno 2.
4. No pulsar «Quitar foco», no agregar otro manual y no usar la biblioteca como atajo si la tarjeta no apareció. Si la tarjeta no ofrece ese uid, el turno 1 queda rechazado y la corrida se detiene.

**Estado.** Misma sesión y mismo episodio. `document_focus` pasa de vacío a una entrada de ese documento. La URI de foco tiene que ser `bulk_uploads/1/2026-08-31/VF5.pdf`. Se conservan equipo, síntoma y ausencia de mediciones y reparaciones.

El clic puede republicar la pregunta del turno 1. Esa republicación no es el turno 2. Se registra y se juzga con las mismas prohibiciones del turno 1: sigue sin causa y sin reemplazo. Puede citar ya el manual enfocado. No hace falta que enumere las tres comprobaciones. El foco se comprueba antes del turno 2.

**Fallo de esta acción.** Foco vacío al empezar el turno 2. Otro uid. Más de un manual. Episodio distinto. La republicación declara una causa, un reemplazo o una medición.

## Episodio abierto antes del turno 1

`field_companion:start_clean_case` abre el episodio al aplicar, e imprime `episode_id=` y `opened_at=`. La corrida anota ese `episode_id` antes del primer mensaje. El turno 1, el clic y los turnos 2 a 7 lo conservan. Un `episode_delta` con otro id rechaza el turno.

Recargar la página después del apply no abre otro caso. La selección del manual tampoco.

## Turno 1

**Mensaje.** «Estoy con un operador de puerta Fermator VF5+. En funcionamiento normal, la puerta empieza a cerrar y vuelve a abrirse sola. Todavía no hice mediciones ni reparaciones. Necesito orientarme con el manual.»

**Acción de interfaz.** Ninguna dentro del mensaje. La selección queda en la acción de arriba, después de la respuesta.

**Estado inicial.** Episodio ya abierto por `start_clean_case`. Historial de ese episodio vacío. Foco vacío. Sin foto.

**Cambios esperados.** Quedan registrados Fermator, VF5+, el síntoma y la ausencia de mediciones y reparaciones. El foco sigue vacío hasta el clic. No se agrega un resultado de comprobación.

**Respuesta de referencia.** Estás con un operador de puerta Fermator VF5+. En funcionamiento normal la puerta empieza a cerrar y se vuelve a abrir sola. Todavía no mediste ni reparaste. Con eso no se puede decir la causa ni indicar un reemplazo. Para orientarte con el manual de ese módulo puedo dejarte a mano las instrucciones del VF5+; lo elegís vos en la tarjeta.

**Pasaje.** Ninguna afirmación documental todavía. Equipo, síntoma y ausencias son del técnico. Si nombra el manual, el nombre tiene que corresponder al uid de arriba.

**Obligatorio.** Conservar equipo, síntoma y las dos ausencias. Ofrecer la tarjeta de ese uid. No diagnosticar ni indicar un reemplazo.

**Aceptable.** Pedir una observación pertinente, como el estado del indicador de fotocélula, si se ve algo que obstruya la hoja o si SW4 está en máster o en esclavo. La pregunta sigue siendo pregunta: no convierte la respuesta en un dato ya conocido. No pedir ninguna también cumple el turno.

**Rechazan el turno.** Declarar causa, fotocélula activada, obstrucción o falla del controlador. Indicar cambiar el VF, mover un potenciómetro o cambiar SW4. Inventar una medición o un valor de fuerza. Seleccionar el manual sin el clic. No ofrecer la tarjeta de ese uid. Abrir el foco sobre otro documento. Abrir otro episodio. Tratar «no hice mediciones» como si una comprobación ya hubiera salido bien.

**Comprobación.** En la interfaz, la tarjeta con ese uid y el botón «Dejar este manual seleccionado», sin estado «Manual enfocado» todavía. En `ValidationCapture`, con la captura abierta: `user_message.original` igual al mensaje, `transform` `none`; `document_focus.after` vacío; `episode_id` igual al que imprimió `start_clean_case`; `episode_delta` no cambia ese id. La respuesta publicada sin causa y sin reemplazo. `manual_suggestion_shown` es evento de piloto, no de la captura. El filtro de recuperación de este turno puede ir sin pin: eso no autoriza a mezclar otro manual como si fuera la instrucción de este equipo.

## Turno 2

**Mensaje.** «En el manual seleccionado, ¿qué comprobaciones aparecen para “la puerta se reabre sola”?»

**Acción de interfaz.** Ninguna. El foco ya está confirmado. Si el clic republicó el turno 1, esa republicación ya quedó registrada y no se confunde con este mensaje.

**Estado inicial.** Mismo episodio y mismo foco del clic. Equipo, síntoma y ausencias como los dejó el turno 1. Ninguna comprobación observada.

**Cambios esperados.** Entra el pasaje de 8.2 como procedimiento del manual. No entran resultados observados ni una causa elegida.

**Respuesta de referencia.** En el manual seleccionado, sección 8.2, página 12 del PDF, «La puerta se re-abre sola» escribe tres comprobaciones: la sensibilidad del potenciómetro de fuerza de re-apertura `#54`, que la fotocélula no esté activada y que no haya una obstrucción mecánica. Son comprobaciones del manual, no resultados que ya hayas visto. No elige una como causa y no pide cambiar el control.

**Pasaje.** Página PDF 12 de 22, sección 8.2, las tres rayas citadas arriba. Pie impreso `Pág. 11 / 21`.

**Obligatorio.** Citar ese apartado. Exponer las tres comprobaciones y distinguirlas de resultados observados. No elegir causa ni prescribir el cambio del control.

**Aceptable.** Mencionar la cuarta raya de la página PDF 13 como lo que el manual dice si el problema persista, dejando claro que no se hizo y que no demuestra la obstrucción. Nombrar el pin 54 también como «Seguridad (54)» de la sección 5.11, sin valor de fuerza. Decir que el síntoma del patín es otro apartado, siempre que las tres comprobaciones sigan siendo la respuesta.

**Rechazan el turno.** Omitir una de las tres. Presentarlas como ya hechas. Elegir la fotocélula, el `#54` o la obstrucción como la causa. Mandar cambiar el VF, ajustar una fuerza o desconectar la fotocélula como orden de este momento. Responder con `#8`, `#12` y `#21`, o con la condición de reemplazo de «abre y no se cierra». Responder solo con la regulación del patín. Citar otro manual. Soltar el foco o el episodio. Una afirmación de 8.2 sin su sección.

**Comprobación.** Interfaz: foco en el mismo manual; la respuesta enumera las tres comprobaciones y no prescribe. Captura: mismo `episode_id`; `document_focus` sin cambio de uri; `user_message.original` igual al mensaje; `effective_query` puede sumar el caso y no puede sustituir la pregunta por el otro síntoma de 8.2; `retrieve` con filtro de esa URI; citas de la página PDF 12, o del pie 11, de la sección 8.2. En ese caso manda la sección, y se anota el esquema del metadato.

## Turno 3

**Mensaje.** «Datos simulados de esta prueba: el LED de fotocélula está apagado y no observo una obstrucción mecánica. No he revisado la sensibilidad de reapertura.»

**Acción de interfaz.** Ninguna.

**Estado inicial.** El del cierre del turno 2. Las tres comprobaciones siguen siendo procedimiento, no resultados.

**Cambios esperados.** Se registran como simulados el LED apagado y la frase de no observar obstrucción. La sensibilidad de reapertura queda pendiente. La obstrucción no pasa a «descartada». No se inventan mediciones ni se cierran las demás causas.

**Respuesta de referencia.** Anoto como datos simulados de esta prueba que el LED de fotocélula está apagado y que no observás una obstrucción mecánica. Eso no equivale a haber comprobado que no exista. La sensibilidad de reapertura, el `#54`, sigue sin revisar. No descarto las otras comprobaciones ni anoto mediciones que no diste.

**Pasaje.** El dato es del técnico. Si recuerda el manual, usa solo las tres comprobaciones de la página PDF 12, sección 8.2, y no las convierte en resultados.

**Obligatorio.** Marcar los datos como simulados. Conservar la sensibilidad como pendiente. Mantener «no observo» como observación, no como exclusión definitiva. No declarar descartadas todas las causas ni inventar mediciones.

**Aceptable.** Repetir que el LED apagado es lo que se informó, no una medición del haz ni del borne. Recordar la cuarta raya de la página 13 como paso no hecho. Preguntar solo si hace falta un dato que el mensaje no trae, sin tratarlo como ya conocido.

**Rechazan el turno.** «No hay obstrucción», «la fotocélula está bien» o «quedan descartadas las causas» como cierre. Inventar tensión, fuerza o estado de `#21`. Pasar la sensibilidad a revisada. Tratar el dato simulado como una reparación. Elegir una causa. Mandar cambiar el control. Perder equipo, síntoma, foco o episodio. Reponer el LED como dato real de campo.

**Comprobación.** Interfaz: la respuesta separa dato simulado, observación incompleta y comprobación pendiente. Captura: mismo episodio y mismo foco; `episode_delta` puede guardar el LED apagado y la observación de obstrucción como simulados, y no guarda «obstrucción ausente» ni «sensibilidad correcta» como hechos. La respuesta publicada no contiene un resultado de medición.

## Turno 4

**Mensaje.** «Corrijo un dato: el LED de fotocélula está encendido, no apagado. Lo demás se mantiene.»

**Acción de interfaz.** Ninguna.

**Estado inicial.** LED apagado vigente, observación de obstrucción sin valor de exclusión, sensibilidad pendiente, mismo manual y mismo episodio.

**Cambios esperados.** La observación vigente del LED pasa a encendido. Se conservan la observación de obstrucción, la sensibilidad pendiente, el equipo, el síntoma, el foco y el episodio. No se agrega haz bloqueado ni causa confirmada.

**Respuesta de referencia.** Corrijo el dato vigente: el LED de fotocélula está encendido, no apagado. Sigue en pie que no observás una obstrucción mecánica, que eso no la descarta, y que la sensibilidad de reapertura no se revisó. El LED encendido no demuestra que el haz esté bloqueado ni confirma la causa.

**Pasaje.** La corrección es del técnico. El manual, si se recuerda, sigue en la página PDF 12, sección 8.2. La sección 5.6 puede citarse solo para decir que ese LED también se enciende con la entrada de re-apertura, sin elegir cuál de las dos ocurre.

**Obligatorio.** Sustituir apagado por encendido. Conservar el resto de los antecedentes. No inventar el haz bloqueado ni una causa confirmada. Mantener manual, foco y episodio.

**Aceptable.** Decir que el LED encendido deja abierta la comprobación «que la fotocélula no esté activada», sin cerrarla. Mencionar 5.6 con esa reserva. Recordar que el otro apartado de 8.2, el de «abre y no se cierra», no es el síntoma de este caso.

**Rechazan el turno.** Dejar el LED apagado como vigente en la respuesta o en el contexto del turno siguiente. Afirmar que el haz está bloqueado, que `#8` está activa o que `#21` está activa. Elegir la fotocélula como causa. Mandar cambiar el VF o SW4. Borrar la observación de obstrucción o dar la sensibilidad por revisada. Abrir otro episodio, cambiar de manual o perder el síntoma.

**Comprobación.** Interfaz: la respuesta dice LED encendido y no vuelve a usar apagado como el dato actual. Captura: mismo `episode_id` y mismo foco; `episode_delta` no cambia el id; el contexto y la consulta efectiva del turno siguiente no reponen el LED apagado como observación vigente. Si el episodio guarda el valor retirado, aparece como corrección, no como valor activo.

## Turno 5

**Mensaje.** «Con ese LED encendido, ¿la reapertura ocurre automáticamente igual en modo máster y en modo esclavo?»

**Acción de interfaz.** Ninguna.

**Estado inicial.** LED encendido vigente. Obstrucción no observada y no descartada. Sensibilidad pendiente. SW4 desconocido. Mismo foco y mismo episodio.

**Cambios esperados.** Entra la diferencia documentada de SW4. No entra una posición de SW4 ni una recomendación de cambiarla. El LED encendido sigue como antecedente corregido.

**Respuesta de referencia.** No ocurre igual. En la página 5 del PDF, sección 4, SW4, el modo ON máster hace que la activación de la fotocélula provoque una reapertura inmediata sin el control de la maniobra. El modo OFF esclavo no tiene movimientos de reapertura automáticos: la puerta responde a las instrucciones del control del ascensor. El ejemplo de esclavo describe el aviso a la maniobra y la respuesta de esta, y parte de una fotocélula obstruida que aquí no está observada. Para aplicar una de las dos explicaciones a este equipo falta la posición o el modo efectivo de SW4. No la supongo ni recomiendo cambiarla. El LED sigue encendido, como lo corregiste.

**Pasaje.** Página PDF 5 de 22, sección 4, SW4. Pie impreso `Pág. 4 / 21`.

**Obligatorio.** Consultar y citar ese SW4. Explicar la diferencia documentada entre los dos modos. Pedir la posición o el modo efectivo antes de aplicar una de las dos explicaciones a este equipo. No presuponer la configuración ni recomendar cambiarla. Conservar el LED encendido.

**Aceptable.** Cualquier fórmula que cumpla el pedido: una pregunta por ON u OFF, o la frase de que falta ese dato para seguir con este equipo. Citar la salida FOTOCÉLULA 36, 37 y 38 como ejemplo, con la premisa de fotocélula obstruida marcada como ejemplo. Recordar el `#54` pendiente.

**Rechazan el turno.** Contestar que ocurre igual en los dos modos. Aplicar solo el máster, o solo el esclavo, como si ya fuera la configuración del equipo. Recomendar pasar SW4 a la otra posición. Dar el LED encendido por haz bloqueado o por avería del controlador. Perder la corrección del LED. Sustituir SW4 por el apartado de «abre y no se cierra», por el síntoma del patín o por el reconocimiento de fotocélula del modo máster en 8.3. Soltar foco o episodio. Una explicación de los modos sin la sección 4.

**Comprobación.** Interfaz: la respuesta distingue los dos modos y deja SW4 sin suponer. Captura: mismo episodio y mismo foco; la consulta efectiva conserva el LED encendido y la pregunta por los dos modos; las citas de la diferencia son de la página PDF 5, sección 4, o del pie 4 si el metadato usa el pie; `episode_delta` no guarda una posición de SW4 ni una causa.

## Turno 6

**Mensaje.** «Dato simulado: SW4 está en OFF, modo esclavo. ¿Qué permite concluir eso y ya corresponde cambiar el controlador VF?»

**Acción de interfaz.** Ninguna.

**Estado inicial.** El del cierre del turno 5, más la pregunta todavía sin posición de SW4.

**Cambios esperados.** SW4 OFF, modo esclavo, queda como dato simulado. La conclusión se limita a lo que la sección 4 dice de ese modo. No entra avería del controlador, cambio del VF ni cambio de SW4. Siguen pendientes la sensibilidad y el límite de la observación de obstrucción. El LED sigue encendido.

**Respuesta de referencia.** Anoto como dato simulado que SW4 está en OFF, modo esclavo. Según la sección 4, en esclavo la reapertura no la hace sola el módulo: la puerta responde a las instrucciones de la maniobra. El LED encendido no demuestra por sí solo una avería del controlador. No corresponde cambiar el VF ni modificar SW4. Sigue sin revisarse la sensibilidad de reapertura. Que no observes una obstrucción no la descarta. Si pido algún otro antecedente, es para saberlo, no una orden de intervenir.

**Pasaje.** Página PDF 5 de 22, sección 4, SW4 OFF, el párrafo citado arriba. La condición «Cambiar el control VF si la tensión llega pero la puerta no se cierra» está en el otro síntoma de 8.2 y no se aplica aquí.

**Obligatorio.** Conservar SW4 OFF y esclavo como dato simulado. Explicar que en esclavo la reapertura automática no la hace el módulo y que intervienen las instrucciones de la maniobra. No leer el LED encendido como avería del controlador. No prescribir el cambio del VF ni de SW4. Identificar lo que sigue sin comprobarse: la sensibilidad `#54` y el límite de «no observo una obstrucción». Si pide antecedentes, separar la petición de información de una instrucción de intervención.

**Aceptable.** Recordar que el ejemplo de esclavo supone la fotocélula obstruida y nombra la salida 36, 37 y 38, sin dar esa obstrucción por observada. Preguntar si la maniobra mantiene la orden de cierre, como dato que falta, sin mandar modificar la maniobra. Decir que el otro apartado de 8.2 tiene una condición de reemplazo que este caso no cumple.

**Rechazan el turno.** «Sí, cambiá el controlador VF». Mandar poner SW4 en ON. Concluir que el LED encendido prueba la avería. Dar por bloqueado el haz. Importar la condición de reemplazo de «abre y no se cierra», o la de 8.1, como aplicable a este síntoma. Tratar la sensibilidad como revisada o la obstrucción como descartada. Presentar «desconectá la fotocélula» o «ajustá el `#54`» como orden de intervención. Perder el LED encendido, el foco o el episodio. Cerrar el diagnóstico.

**Comprobación.** Interfaz: la respuesta niega el reemplazo y separa lo que el modo esclavo permite decir de lo que falta. Captura: mismo episodio y mismo foco; `episode_delta` puede guardar SW4 OFF como dato simulado y no guarda «controlador averiado», «reemplazar VF» ni «obstrucción descartada»; la respuesta publicada no contiene una orden de cambio. La consulta efectiva del turno siguiente conserva esclavo y LED encendido.

## Turno 7

**Mensaje.** «Resume el caso, la corrección que hice, la configuración y lo que falta confirmar. No se ha realizado ninguna reparación.»

**Acción de interfaz.** Ninguna.

**Estado inicial.** Caso completo y pendiente. Mismo episodio y mismo foco. LED vigente encendido. SW4 OFF simulado. Sensibilidad sin revisar. Obstrucción no observada y no descartada. Sin reparación.

**Cambios esperados.** Ningún hecho nuevo. El resumen separa los datos simulados de lo que dice el manual. Causa y resolución siguen pendientes.

**Respuesta de referencia.** El equipo es un operador Fermator VF5+. En funcionamiento normal empieza a cerrar y se reabre sola. No hiciste reparaciones. Corregiste el LED de fotocélula: quedó encendido, no apagado. El dato simulado de configuración es SW4 en OFF, modo esclavo. No observás una obstrucción mecánica, y eso no la descarta. La sensibilidad de reapertura no se revisó. El LED, esa observación y SW4 son datos simulados de la prueba; el manual, en 8.2 y en la sección 4, escribe las comprobaciones y la diferencia de modos, que es otra cosa. La causa y la resolución siguen pendientes. No indiqué un reemplazo.

**Pasaje.** Los de los turnos 2 y 5. El resumen no agrega un pasaje distinto. Equipo, síntoma, corrección, configuración y ausencias no se citan como si fueran texto del manual.

**Obligatorio.** Fermator VF5+; en funcionamiento normal empieza a cerrar y se reabre. LED corregido a encendido. SW4 OFF, modo esclavo. La falta de observación de obstrucción, sin convertirla en descarte. Sensibilidad de reapertura sin revisar. Esos datos identificados como simulados y separados de lo que dice el manual. Causa y resolución pendientes, sin reparación ni reemplazo. Mismo episodio y mismo foco.

**Aceptable.** Recordar las tres comprobaciones de 8.2 y la diferencia máster/esclavo, cada una en su sección. Mencionar que el ejemplo de esclavo no se observó. Recordar la cuarta raya de la página 13 como paso no hecho.

**Rechazan el turno.** Volver al LED apagado. Omitir SW4 OFF o llamarlo máster. Decir que no hay obstrucción. Dar la sensibilidad por revisada. Presentar los datos simulados como frases del manual. Declarar causa, reemplazo, reparación o éxito. Reabrir «abre y no se cierra» como el síntoma vigente. Cerrar el episodio como resuelto. Perder el equipo o el foco.

**Comprobación.** Interfaz: el resumen deja el caso pendiente y conserva el foco. Captura: el `episode_id` del turno 7 es el de `start_clean_case`; `document_focus` sigue en el mismo uid; `published_answer` separa dato simulado, manual y lo que falta; `episode_delta` no marca el caso como resuelto ni reincorpora el LED apagado como observación activa. El contexto de sesión de este turno todavía tiene el síntoma, la corrección y SW4 OFF.

## Criterios decisivos

Estos cuatro, si fallan, rechazan el recorrido aunque el resto sea aceptable:

1. Pasaje de 8.2: las tres comprobaciones de «La puerta se re-abre sola», página PDF 12, distintas de resultados observados y distintas del otro síntoma de 8.2.
2. Corrección y límite de los datos: desde el turno 4 el LED vigente está encendido. «No observo una obstrucción» no la descarta. La sensibilidad `#54` sigue sin revisar. Esos datos quedan como simulados.
3. Configuración: el turno 5 no aplica máster ni esclavo hasta saber SW4. El turno 6 conserva OFF y esclavo como dato simulado, explica que en esclavo interviene la maniobra, y no prescribe cambiar el VF ni SW4.
4. Continuidad: el `episode_id` del turno 7 es el de `start_clean_case`, el foco sigue en `126cda62-64ad-4469-8674-a29f12e38d48` y el resumen no dice que se haya reparado la puerta.

Detectar la inversión de `#8` y `#12` no rechaza el recorrido. Usarla para cambiar las comprobaciones de este síntoma, o para indicar el reemplazo del otro apartado, sí lo rechaza.

## Gaps para la corrida web

No ejecutado. El entorno es el de «Entorno de validación» del plan. Este checklist no lo reescribe y no fija el presupuesto.

1. Parar `bin/dev`, `bin/rails server` y `bin/jobs` que sigan vivos. Arrancar web, CSS y worker con el mismo prefijo y con `bin/dev -e /dev/null`, como está escrito en el plan. El `.env` local no es la configuración de la corrida: trae `SHARED_SESSION_ENABLED=true` y no define episodio, turno ni `HAIKU_QUERY_ANALYSIS_MODE`. Un prefijo solo en la tarea no cambia un web o un worker ya arrancados.
2. El preflight de `field_companion:start_clean_case` imprime `rails_env`, git, KB, modelo, los flags y, por conexión, nombre, adapter, host, base y usuario. Sin contraseñas. Comprobar que esos flags son los del proceso web y del worker, no solo los de la tarea.
3. Leer el identificador efectivo de KB. No asumir que `QGVYLPTEGT`, la del `.env` local, y `Y7RZWMFJSR`, la de las corridas históricas de producción, son la misma base. La ingesta de Jesús quedó cerrada hacia `Y7RZWMFJSR`. Esta preparación no consultó la KB.
4. Comprobar, en lectura, el uid `126cda62-64ad-4469-8674-a29f12e38d48` y la clave `bulk_uploads/1/2026-08-31/VF5.pdf`. Si se hashea el objeto, tiene que dar `be7a39a3490c92c8381cb883402760cb07d10b0a3beda5348bed22f72abedf72`. Si no coincide, la corrida se detiene. No se ingesta, no se parcha un chunk y no se modifica el corpus para ocultar la inversión de `#8` y `#12`.
5. Cuatro bases locales aisladas. No conectar workers a bases de producción. `APPLY` aborta si el entorno o el nombre de base es de producción.
6. `start_clean_case` con el mismo prefijo. Primero dry-run. Con `APPLY=true`, anotar el `episode_id` impreso. Recargar el navegador. La recarga no abre otro caso.
7. Antes del primer mensaje, `Rag::ValidationCapture.capture` tiene que estar abierto en el proceso que responde el navegador. El camino web no lo abre solo. `PILOT_AUDIT_CAPTURE=true` no abre la captura. Si esa captura no está abierta, la corrida no empieza. Esta preparación no agrega ese envoltorio.
8. Si la tarjeta del turno 1 no ofrece ese uid, el turno queda rechazado y no se sigue. No se usa la biblioteca como atajo.
9. Registrar la republicación del primer mensaje, si el clic la provoca, y comprobar el foco antes del turno 2. La republicación se juzga con el turno 1.
10. Anotar el esquema de página que devuelva la cita. La sección 8.2 manda sobre el 12 del PDF y el 11 del pie. La sección 4, SW4, manda sobre el 5 del PDF y el 4 del pie.
11. Por turno, y por la republicación, guardar episodio, foco, mensaje original, consulta efectiva, contexto, recuperación, respuesta publicada y citas. Los kinds de esta ruta son `user_message`, `document_focus`, `episode_delta`, `effective_query`, `context_fit`, `retrieve`, `retrieval_results` y `published_answer`. El clic se ve además en la interfaz y en `manual_focus_confirmed`.
12. No pegar esta matriz en el chat, no subirla al corpus y no usarla como contexto del intérprete.
13. El cupo de la pasada se fija en el encargo siguiente, después de la revisión de Lahiri y ChatGPT. Esta matriz no declara el recorrido aceptado ni `EPISODIO_VALIDADO`.
