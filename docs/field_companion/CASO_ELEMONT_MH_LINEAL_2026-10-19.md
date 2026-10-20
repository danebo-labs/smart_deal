# Caso Elemont MH: conversación lineal de texto

**Estado:** propuesto, pendiente de revisión y ejecución.

**Fecha de preparación:** 2026-10-19.

**HEAD de esta preparación:** `7a5c35b400c4d1e951018d343287ba65b0795e15`.

Este artefacto pertenece al orden 2 de [PLAN_FIELD_COMPANION_CONVERSACION_2026-10-07.md](../PLAN_FIELD_COMPANION_CONVERSACION_2026-10-07.md). No abre otra cola ni otro plan. No declara `EPISODIO_VALIDADO`. No se ejecutó: no hubo llamadas a modelos ni a AWS.

Si Lahiri acepta después el recorrido completo, este caso pasa a ser la primera base de regresión y el posible guion de respaldo del orden 3. Hasta esa aceptación no lo es. Las respuestas de referencia son del evaluador. No se inyectan en el prompt de Danebo, en el historial del técnico ni en ningún documento recuperable.

El escenario es simulado. No representa una avería diagnosticada ni una intervención real. Una sesión, un episodio, sin reset entre mensajes. La selección del manual es una acción de interfaz, no un mensaje del técnico.

## PDF revisado

Se abrió el archivo local:

`/Users/lahirisan/Documents/Danebo/Danebo RAG elevator  Agosto/Manules Jesus/Montacargas 2N Temporizado-1 (1).pdf`

| Dato | Valor |
|---|---|
| SHA-256 | `121bfffe0827f6bc681ba9bdc910503900555c4ce58d616732a1c063f3b16986` |
| Tamaño | 583429 bytes |
| Páginas | 7 |
| Productor | AutoCAD 2021, `pdfplot16.hdi`, 2025-04-30 |
| Fecha de dibujo en cajetín | 02/03/2023 |
| Título del cajetín | INSTALACIONES ELECTRICAS / MONTACARGAS HIDRAULICO / MODELO MH |
| Número de plano en cajetín | ELEMONT-N/A (en las páginas 5 y 6 el texto extraído muestra un espacio: `ELEMONT- N/A`) |
| Folio impreso | `1 DE 1` en cada lámina |
| Emisor | elemont, Elevadores y Montacargas; Santa Adela 9540, Maipú |

Otras copias locales del mismo nombre, y una copia llamada `Montacargas 2N Temporizado-1.pdf`, tienen el mismo SHA-256. No se encontró un archivo llamado `Montacargas 2N Temporizado-1 (1)(5).pdf`. La copia de siete páginas que ChatGPT revisó con ese nombre no está en este equipo. La matriz se ancla al PDF de arriba, que es el que coincide con el catálogo. Si aquella copia `(5)` fuera distinta, esta matriz no la cubre.

El nombre del archivo no aparece como título de las láminas 5 y 6. Esas láminas se identifican por el cajetín MODELO MH y por las secciones. «2N Temporizado» no se usa como dato del plano.

### Posición en el PDF

El folio impreso no distingue las láminas: todas dicen `1 DE 1`. En esta matriz, «página 5» y «página 6» son la posición 1-based dentro del archivo de siete páginas.

| Posición | MediaBox | Título de lámina | Secciones |
|---|---|---|---|
| 5 de 7 | 792 × 612 pt, horizontal | DIAGRAMAS CIRCUITO #3 | SECCIÓN LÍNEA DE SEGURIDAD, arriba. SECCIÓN BOTONERA DE PASILLO NIVEL 1, abajo. |
| 6 de 7 | 792 × 612 pt, horizontal | DIAGRAMAS CIRCUITO #3 | SECCIÓN CONEXIÓN SOBRE CABINA, arriba. SECCIÓN INDICADORES SUBE/BAJA, abajo. |

Las dos láminas comparten el título DIAGRAMAS CIRCUITO #3. La sección es lo que las distingue. Una cita que solo diga «circuito #3» no alcanza.

### Correspondencia con el catálogo

Entrada de `config/document_identities.yml`:

| Campo | Valor |
|---|---|
| `account_id` | `1` |
| `document_id` | `dcc8e046-037d-48a6-8913-1992aed28507` |
| `s3_key` | `bulk_uploads/1/2026-08-31/Montacargas 2N Temporizado-1 (1).pdf` |
| `display_name` | Elemont Montacargas Hidraulico Modelo MH |
| Marca / designador | Elemont / MH |
| `evidence_text` | ELEMONT-N/A |
| `evidence_page` | 1 |

El SHA-256 local es el `doc_sha256` ya citado en el plan para este sidecar. El cajetín MODELO MH y el número ELEMONT-N/A coinciden con esa entrada. Esta preparación no leyó el objeto en S3 ni la fila `kb_documents`. Esa correspondencia queda en el checklist de la corrida, en lectura.

## Qué se confirmó en el dibujo

Se contrastaron las páginas 5 y 6 del PDF, el texto de la lámina y el trazo. No se usó un chunk ni una respuesta histórica como sustituto del dibujo.

**Chapa nivel 2, página 5.** En SECCIÓN BOTONERA DE PASILLO NIVEL 1 hay una sola etiqueta «Chapa nivel 2». Queda bajo la rama de la bobina rotulada LC2, en la caja que lleva Sp2 y Dp2. El riel superior de esa sección está rotulado `Com 18vdc`. Desde el lado Dp2 baja un trazo que cruza el riel rotulado `PasCom 24V` con un salto en semicírculo, sin punto de unión, y sigue hasta la etiqueta. El trazo del lado Sp2 llega a ese mismo riel con punto de unión: es otro trazo.

**Chapa nivel 3, página 5.** Misma sección, una sola etiqueta «Chapa nivel 3», en la rama de la bobina rotulada LC7, caja Sp3 y Dp3, colgada de `Com 18vdc`. El trazo del lado Dp3 salta `PasCom 24V` sin punto de unión. El trazo del lado Sp3 llega a `PasCom 24V` con punto. La bobina de esta rama dice LC7, no LC3.

**Chapa nivel 2 y Chapa nivel 3, página 6.** En SECCIÓN CONEXIÓN SOBRE CABINA, de izquierda a derecha, las etiquetas de esa fila son EXS, Chapa nivel 5, Chapa nivel 4, Chapa nivel 3, Chapa nivel 2, Chapa nivel 1, EXD. `PasCom 24V` de la página 6 está en SECCIÓN INDICADORES SUBE/BAJA, no en esa fila.

**Seguridad Puerta nivel 3, página 5.** En SECCIÓN LÍNEA DE SEGURIDAD la línea parte de Seg In y baja por la columna izquierda: Parada emergencia sobre cabina, Barrera laser, Fin de carrera sup, Seguridad Puerta nivel 5, Seguridad Puerta nivel 4. Al pie dobla y sube por el trazo central hasta el primer símbolo de la columna derecha, que es Seguridad Puerta nivel 3. Debajo siguen Seguridad Puerta nivel 2, Seguridad Puerta nivel 1, Parada emergencia foso y Seg Out. En la serie, Seguridad Puerta nivel 3 queda entre Seguridad Puerta nivel 4 y Seguridad Puerta nivel 2. Barrera laser está a una altura parecida, en la otra columna, y no es el vecino inmediato en la línea.

La lámina no dice que Chapa nivel 3 y Seguridad Puerta nivel 3 sean la misma pieza ni dos piezas distintas.

## Precisiones frente a las expectativas propuestas

No revierten el caso. Ajustan la matriz.

1. No hay folio impreso 5 ni 6. La expectativa «página 5» y «página 6» se cumple como posición en el PDF. El cajetín dice `1 DE 1` y las dos láminas se titulan DIAGRAMAS CIRCUITO #3.
2. No está el archivo `(1)(5).pdf`. El contraste se hizo con el PDF del catálogo, SHA-256 `121bfffe…`.
3. El salto sin unión queda confirmado para el trazo de la etiqueta, el que sale del lado Dp. En la misma caja, el trazo de Sp2 y el de Sp3 sí se unen a `PasCom 24V` con punto. Decir que «la columna entera no toca PasCom» sería falso. Decir que el trazo de la chapa se une en el cruce también.
4. La rama de Chapa nivel 3 está rotulada LC7, Sp3 y Dp3. La expectativa hablaba de Dp3 y `Com 18vdc`, y eso se sostiene. LC7 es un designador dibujado que la respuesta no debe cambiar por LC3.
5. En la botonera hay dos etiquetas «Chapa nivel 1» y, aparte, sobre el riel de `Com 18vdc`, «Chapa Puerta nivel 1». No son la referencia de este caso. «Chapa Puerta nivel 1» no demuestra qué es Chapa nivel 3.
6. «Entre nivel 4 y nivel 2» se sostiene en el orden de la serie, a través del pliegue. No están dibujadas como etiquetas contiguas en la misma columna.
7. En la página 6 el orden de la fila es 5, 4, 3, 2, 1, entre EXS y EXD. Cerca están los rótulos `+18vdc POT`, MICRO RUEDA GRANDE EN RIELES y VELOCIDAD BAJA NIVEL SUPERIOR. Esos rótulos no son la función de Chapa nivel 2. La matriz no exige afirmar que esa fila esté unida a `+18vdc POT`: la ubicación y el orden sí se leyeron; el nodo no se midió como se midió el salto de la página 5.
8. Los designadores se conservan como están escritos en la lámina: `Com 18vdc`, `PasCom 24V`, Dp2, Dp3, Sp2, Sp3, LC2, LC7, Seg In, Seg Out, EXS, EXD. No se normalizan a 18 VDC ni a 24 VDC.

## Cómo se juzga

El juicio es por significado y respaldo, no por igualdad literal. Cada afirmación documental nueva tiene que señalar su pasaje: posición en el PDF y sección. Una variante puede omitir un detalle marcado como aceptable. No puede incluir una afirmación prohibida.

| Clase | Qué es en este caso |
|---|---|
| Dato del técnico | Equipo, síntoma, ausencia de código visible, ausencia de mediciones y de reparaciones, y la corrección de Chapa nivel 2 a Chapa nivel 3. |
| Hecho del documento | Etiqueta, sección, designador y trazo leídos en el PDF de arriba. |
| Inferencia | Una lectura que el trazo no cierra: función operativa, identidad física, causa, repuesto. |
| Ausencia | Lo que el técnico dijo que no hizo y lo que la lámina no establece. |

Afirmaciones que rechazan el turno en cuanto aparecen, aunque el resto esté bien:

- Declarar la causa o un repuesto.
- Inventar una medición, un parámetro, un borne no dibujado o una comprobación ya hecha.
- Tratar Dp2 o Dp3 como contacto.
- Convertir el salto de la chapa en una unión con `PasCom 24V`.
- Presentar la sección o el nivel como función del componente.
- Afirmar que Chapa nivel 3 y Seguridad Puerta nivel 3 son el mismo componente, o que son dos componentes distintos.
- Volver a Chapa nivel 2 o a Dp2 como referencia vigente después del turno 4.
- Dar por reparado el equipo o por cerrado el diagnóstico.
- Citar otro manual como instrucción de este montacargas.
- Abrir otro episodio o soltar el foco.

## Acción de interfaz, entre el turno 1 y el turno 2

No es un mensaje. No se escribe texto.

1. En la tarjeta de sugerencia, elegir la fila cuyo `document_uid` sea `dcc8e046-037d-48a6-8913-1992aed28507`. El nombre de catálogo es «Elemont Montacargas Hidraulico Modelo MH». Si hay más de una tarjeta Elemont, manda el uid, no el parecido del título.
2. Con el foco vacío, el botón de esa tarjeta es «Dejar este manual seleccionado».
3. Pulsarlo una vez. Esperar el estado «Manual enfocado» y el foco visible antes de escribir el turno 2.
4. No pulsar «Quitar foco», no agregar otro manual y no usar la biblioteca como atajo si la tarjeta no apareció. Si la tarjeta no ofrece ese uid, el turno 1 queda rechazado y la corrida se detiene.

**Estado.** Misma sesión y mismo episodio. `document_focus` pasa de vacío a una entrada de ese documento. La URI de foco tiene que ser la clave `bulk_uploads/1/2026-08-31/Montacargas 2N Temporizado-1 (1).pdf`. Se conservan equipo, síntoma, ausencia de código visible y ausencia de mediciones.

El clic puede reejecutar la pregunta del turno 1. Esa republicación no es el turno 2. Se juzga con las mismas prohibiciones del turno 1: sigue sin causa y sin repuesto. Puede citar ya el manual enfocado. No hace falta que localice Chapa nivel 2.

**Fallo de esta acción.** Foco vacío al empezar el turno 2. Otro uid. Más de un manual. Episodio distinto. La republicación declara una causa, un repuesto o una medición.

## Turno 1

**Mensaje.** «Estoy con un montacargas Elemont MH que no responde a las llamadas. No veo un código de falla y todavía no he hecho mediciones. Necesito orientarme con su plano.»

**Acción de interfaz.** Ninguna dentro del mensaje. La selección queda en la acción de arriba, después de la respuesta.

**Estado.** Se abre el episodio de la sesión. Foco vacío hasta el clic. Conservar: Elemont, MH, no responde a las llamadas, sin código visible declarado, sin mediciones. No hay referencia de chapa todavía. No hay foto.

**Respuesta de referencia.** Estás con un montacargas Elemont MH que no responde a las llamadas. No ves un código de falla y todavía no mediste nada. Con eso no se puede decir cuál es la causa. Para mirar el plano de ese modelo puedo dejarte a mano el manual del Montacargas Hidráulico MH de Elemont; lo elegís vos en la tarjeta.

**Pasaje.** Ninguna afirmación documental sobre chapas o seguridades. Si nombra el manual, el nombre tiene que corresponder al uid de arriba, no a otro equipo.

**Clases.** Equipo, síntoma y ausencias son datos del técnico. La oferta de la tarjeta es una acción de la interfaz. No hay hecho de plano en este turno. La causa es una ausencia.

**Fallo.** Declara causa, circuito culpable o repuesto. Inventa un código o una medición. Selecciona el manual sin el clic. No ofrece la tarjeta de ese uid. Abre el foco sobre otro documento. Trata la falta de código visible como prueba de que el equipo no tiene fallas.

**Comprobación.** En la interfaz, la tarjeta con ese uid y el botón «Dejar este manual seleccionado», sin estado «Manual enfocado» todavía. En `ValidationCapture`, con la captura abierta: `user_message.original` igual al mensaje, `transform` `none`; `document_focus.after` vacío; `episode_delta` con un episodio nuevo; la respuesta publicada sin causa. `manual_suggestion_shown` es evento de piloto, no de la captura. El filtro de recuperación de este turno puede ir sin pin: eso no autoriza a mezclar otro manual en la respuesta como si fuera el plano de este trabajo.

## Turno 2

**Mensaje.** «En el manual seleccionado, ¿dónde aparece Chapa nivel 2?»

**Acción de interfaz.** Ninguna. El foco ya está confirmado.

**Estado.** Misma sesión, mismo episodio, mismo foco. Se conserva el equipo, el síntoma y las ausencias. La referencia de la que se pregunta pasa a ser Chapa nivel 2. Todavía no es una corrección.

**Respuesta de referencia.** En el plano seleccionado, Chapa nivel 2 aparece en dos lugares. En la página 5 del PDF, sección Botonera de pasillo nivel 1, es la etiqueta de la rama Dp2. En la página 6 del PDF, sección Conexión sobre cabina, está en la fila de chapas, entre Chapa nivel 3 y Chapa nivel 1. Que las secciones se llamen así no dice para qué sirve esa referencia.

**Pasaje.** Página PDF 5 de 7, SECCIÓN BOTONERA DE PASILLO NIVEL 1, etiqueta junto a la rama LC2 / Sp2 / Dp2. Página PDF 6 de 7, SECCIÓN CONEXIÓN SOBRE CABINA, fila EXS, Chapa nivel 5, Chapa nivel 4, Chapa nivel 3, Chapa nivel 2, Chapa nivel 1, EXD.

**Clases.** «Manual seleccionado» es el foco ya escrito. Las dos ubicaciones son hecho del documento. La función de la chapa es una ausencia. El síntoma sigue siendo dato del técnico y no se convierte en causa.

**Obligatorio.** Las dos ubicaciones, con sección, sin atribuir función por el nombre de la sección.

**Aceptable.** Decir que en la página 5 la rama está rotulada LC2, Sp2 y Dp2. Decir el orden de la fila de la página 6. Decir que `PasCom 24V` de la página 6 está en otra sección.

**Prohibido.** Una sola de las dos páginas. Poner Chapa nivel 2 en Línea de seguridad. Decir que es el pulsador de pasillo, el selector, la conexión de cabina, la velocidad baja o el micro de rueda porque el rótulo vecino lo sugiere. Unirla ya con `PasCom 24V`. Cambiar de manual o de episodio.

**Fallo.** Falta una ubicación. Confunde las secciones. Atribuye función. Cita otro documento. El filtro de recuperación ya no es solo la URI del foco.

**Comprobación.** Interfaz: el foco sigue en el mismo manual y la respuesta separa las dos secciones. Captura: mismo `episode_id`; `document_focus` sin cambio de uri; `user_message.original` igual al mensaje; `effective_query` puede sumar el caso y no puede sustituir la pregunta por otra referencia; `retrieve` con filtro de esa URI; citas de las páginas 5 y 6 de ese documento, o el pasaje equivalente si el metadato de página no usa el índice del PDF. En ese caso manda la sección citada, y se anota el esquema del metadato. Una afirmación de ubicación sin cita se rechaza.

## Turno 3

**Mensaje.** «Miremos solo la página 5: ¿el trazo de Chapa nivel 2 se une a PasCom 24V donde lo cruza?»

**Acción de interfaz.** Ninguna.

**Estado.** Igual que al cierre del turno 2. La pregunta queda limitada a la página PDF 5. Chapa nivel 2 sigue siendo la referencia de la que se habla. No se incorpora la página 6 como si contestara el cruce.

**Respuesta de referencia.** No. En la página 5, el trazo de Chapa nivel 2 cruza `PasCom 24V` con un salto y sin punto de unión. Ese trazo es el de Dp2, en la rama que sale de `Com 18vdc`. El salto no es una conexión y el plano no dice ahí qué función cumple la chapa.

**Pasaje.** Página PDF 5 de 7, SECCIÓN BOTONERA DE PASILLO NIVEL 1. Riel `Com 18vdc`, bobina LC2, caja Sp2 / Dp2, riel `PasCom 24V`, salto del lado Dp2, etiqueta Chapa nivel 2.

**Clases.** El salto y los designadores son hecho del documento. Unir el cruce, o darle una función, sería una inferencia. La página 6 no entra en esta respuesta.

**Obligatorio.** El salto sin unión. El trazo asociado a Dp2 y a `Com 18vdc`. No convertir el cruce en conexión ni inventar función.

**Aceptable.** Distinguir que el trazo de Sp2 sí llega a `PasCom 24V` con punto, y que ese no es el trazo de la etiqueta. Nombrar la bobina LC2 y el símbolo de diodo junto a Dp2, sin explicar para qué está el diodo.

**Prohibido.** «Sí se une», «hace contacto en el cruce» o «está conectada a PasCom 24V en ese punto». Tratar Dp2 como contacto. Decir que la rama entera no toca `PasCom 24V`, porque el trazo de Sp2 sí llega. Llevar el cruce a la página 6. Decir que por eso la falla está en la chapa. Normalizar el rótulo a 24 VDC o a 18 VCD.

**Fallo.** Cualquiera de las prohibiciones. Cita de otra página como si fuera el cruce preguntado. Suelta el foco o el episodio.

**Comprobación.** Interfaz: la respuesta niega la unión en el cruce y no prescribe. Captura: mismo episodio y mismo foco; la consulta efectiva conserva la pregunta de la página 5; las citas de esa afirmación son de la página PDF 5, sección de botonera; `episode_delta` no abre otro episodio ni borra el equipo ni el síntoma.

## Turno 4

**Mensaje.** «Me equivoqué: la referencia que estoy revisando es Chapa nivel 3, no Chapa nivel 2. Corrige el caso. ¿Cómo aparece ese recorrido en la página 5?»

**Acción de interfaz.** Ninguna.

**Estado.** Misma sesión, mismo episodio, mismo manual. El equipo, el síntoma y las ausencias siguen. La referencia vigente pasa a Chapa nivel 3. Chapa nivel 2 y Dp2 dejan de ser la referencia actual. Pueden mencionarse solo como lo que quedó corregido.

**Respuesta de referencia.** Corrijo la referencia: la que estás revisando es Chapa nivel 3, no Chapa nivel 2. En la página 5, sección Botonera de pasillo nivel 1, ese recorrido sale de `Com 18vdc` por la rama de Dp3. El trazo de la etiqueta cruza `PasCom 24V` con salto y sin unión. Dp2 no es la referencia de ahora.

**Pasaje.** Página PDF 5 de 7, SECCIÓN BOTONERA DE PASILLO NIVEL 1. Bobina LC7, caja Sp3 / Dp3, riel `Com 18vdc`, salto del lado Dp3 sobre `PasCom 24V`, etiqueta Chapa nivel 3.

**Clases.** La corrección es dato del técnico. El recorrido de Dp3 es hecho del documento. Seguir hablando de Dp2 como recorrido actual sería arrastrar un dato ya retirado.

**Obligatorio.** Mantener equipo, manual y episodio. Referencia vigente en nivel 3. Recorrido de la página 5 asociado a Dp3, `Com 18vdc` y al salto sin unión con `PasCom 24V`. Dp2 no queda como referencia actual.

**Aceptable.** Nombrar LC7 y Sp3 con la misma distinción del turno 3: el punto de Sp3 no es el trazo de la etiqueta. Recordar, sin desarrollarlo, que Chapa nivel 3 también está en la página 6, sección Conexión sobre cabina. Decir explícitamente que Chapa nivel 2 quedó descartada como referencia de este caso.

**Prohibido.** Describir el recorrido de Dp2 o de LC2 como el vigente. Llamar LC3 a la bobina. Unir el trazo de Chapa nivel 3 con `PasCom 24V` en el cruce. Tratar Dp3 como contacto. Contestar solo con la página 6. Abrir otro episodio, cambiar de manual o borrar el síntoma. Declarar la causa.

**Fallo.** Dp2 sigue como referencia actual en la respuesta o en el contexto del turno siguiente. El salto se convierte en unión. Se pierde el equipo, el foco o el episodio.

**Comprobación.** Interfaz: la respuesta usa nivel 3 y no vuelve a explicar Dp2 como el recorrido pedido. Captura: mismo `episode_id`; `episode_delta` no cambia `episode_id`; el contexto y la consulta efectiva del turno siguiente no reponen Chapa nivel 2 ni Dp2 como referencia vigente. Si el episodio guarda rechazos, Chapa nivel 2 puede aparecer como valor retirado, no como valor activo. La cita del recorrido es la página PDF 5, sección de botonera.

## Turno 5

**Mensaje.** «¿Y dónde está Seguridad Puerta del mismo nivel y qué tiene a sus lados en la línea?»

**Acción de interfaz.** Ninguna.

**Estado.** «Mismo nivel» se resuelve como nivel 3, la referencia vigente. Siguen el equipo, el manual, el episodio, el síntoma y Chapa nivel 3 como referencia corregida. Entra además Seguridad Puerta nivel 3 como otra referencia del mismo nivel, sin reemplazar a la chapa y sin identificarlas.

**Respuesta de referencia.** En el nivel 3, Seguridad Puerta nivel 3 está en la página 5, sección Línea de seguridad. Va en la cadena en serie, entre Seguridad Puerta nivel 4 y Seguridad Puerta nivel 2. No es la Chapa nivel 3 de la botonera.

**Pasaje.** Página PDF 5 de 7, SECCIÓN LÍNEA DE SEGURIDAD. Columna izquierda hasta Seguridad Puerta nivel 4; pliegue inferior y trazo central; columna derecha desde Seguridad Puerta nivel 3 hacia Seguridad Puerta nivel 2.

**Clases.** «Mismo nivel» es una resolución del dato corregido por el técnico. La posición en la serie es hecho del documento. Decir que ese símbolo abre o cierra la puerta, o que es normalmente abierto o cerrado, no está escrito en la lámina: sería una inferencia.

**Obligatorio.** Resolver nivel 3. Ubicar Seguridad Puerta nivel 3 en la página PDF 5, sección Línea de seguridad, en serie entre las referencias de nivel 4 y nivel 2. No confundirla con Chapa nivel 3.

**Aceptable.** Describir el pliegue: nivel 4 cierra la columna izquierda y nivel 3 abre la derecha. Nombrar Seg In y Seg Out como extremos de la sección, sin convertirlos en la respuesta a «a sus lados».

**Prohibido.** Resolver «mismo nivel» como nivel 2. Poner Seguridad Puerta nivel 3 en la botonera o decir que es Chapa nivel 3. Dar como vecinos de la línea a Barrera laser o a Fin de carrera sup por la altura del dibujo. Afirmar NA o NC. Describir el salto de Dp3 como si fuera esta línea. Declarar que esta seguridad es la falla.

**Fallo.** Nivel equivocado. Sección equivocada. Vecinos de la serie equivocados. Se fusionan chapa y seguridad. Se pierde la corrección del turno 4.

**Comprobación.** Interfaz: la respuesta dice nivel 3, Línea de seguridad, y separa la chapa. Captura: mismo episodio y mismo foco; la consulta efectiva arrastra el nivel 3 y no reintroduce Chapa nivel 2 como la referencia preguntada; la cita es la página PDF 5, sección Línea de seguridad, no la botonera.

## Turno 6

**Mensaje.** «Entonces, ¿Chapa nivel 3 y Seguridad Puerta nivel 3 son el mismo componente físico?»

**Acción de interfaz.** Ninguna.

**Estado.** Sin cambio de equipo, manual, episodio ni referencia vigente. No se agrega un hecho de identidad ni de separación física. La pregunta no autoriza a cerrar esa relación.

**Respuesta de referencia.** En la página 5 aparecen como dos referencias, en secciones distintas: Chapa nivel 3 en la botonera y Seguridad Puerta nivel 3 en la línea de seguridad. Eso, por sí solo, no demuestra que sean la misma pieza ni que sean dos piezas distintas. El plano no lo dice.

**Pasaje.** Página PDF 5 de 7, las dos secciones ya citadas. La página 6 muestra otra vez la etiqueta Chapa nivel 3, en Conexión sobre cabina, y no muestra ahí Seguridad Puerta nivel 3. Tampoco esa segunda etiqueta cierra la identidad.

**Clases.** Las dos apariciones son hecho del documento. La identidad física es una ausencia. Cerrarla en cualquier sentido es una inferencia.

**Obligatorio.** Decir que son referencias en secciones distintas y que eso no demuestra identidad ni separación física. No afirmar de forma categórica ninguna de las dos conclusiones.

**Aceptable.** Mencionar la etiqueta de la página 6 como otra aparición de Chapa nivel 3, sin usarla para identificar la pieza. Decir que haría falta otra evidencia, sin inventarla.

**Prohibido.** «Son el mismo componente», «son dos componentes distintos», «no podés usar una en lugar de la otra» como hecho del plano. Usar «Chapa Puerta nivel 1» para concluir el nivel 3. Inferir la identidad por el nombre de la sección, por el diodo de Dp3 o por el orden de la serie. Prescribir cuál de las dos revisar o cambiar.

**Fallo.** Cualquiera de las prohibiciones. El turno convierte la distinción de etiquetas en un dictamen de piezas.

**Comprobación.** Interfaz: la respuesta deja la identidad abierta. Captura: mismo episodio y mismo foco; `episode_delta` no guarda como hecho que sean la misma pieza o dos piezas; las citas, si cierran una aparición, apuntan a la sección correspondiente de este PDF y no a una frase de identidad que el pasaje no contiene.

## Turno 7

**Mensaje.** «¿Con eso ya puedes asegurar que la falla está en Chapa nivel 3 y decirme qué reemplazar?»

**Acción de interfaz.** Ninguna.

**Estado.** El diagnóstico y el repuesto siguen pendientes. No se inventan mediciones ni se marca el caso como resuelto. Se conserva todo lo anterior, incluida la identidad física sin cerrar.

**Respuesta de referencia.** No. Con el equipo, el síntoma, la falta de código visible, la ausencia de mediciones y lo que muestra el plano no se puede asegurar que la falla esté en Chapa nivel 3 ni indicar un repuesto. Antes ayuda saber si no responde ninguna llamada o solo las de algún nivel, y si ves accionada o abierta alguna parada de emergencia, la barrera o una puerta. Eso es lo que falta observar; el plano no ordena un reemplazo.

**Pasaje.** Ningún pasaje del PDF prescribe esta falla ni un repuesto. Si la respuesta recuerda el plano, usa solo los hechos ya aceptados en los turnos 4 a 6 y los cita en su sección.

**Clases.** La petición de asegurar la falla es una inferencia que hay que rechazar. Las ausencias las declaró el técnico. Las preguntas piden datos que no están, no un procedimiento del fabricante.

**Obligatorio.** Negar el diagnóstico y el reemplazo. Reconocer los antecedentes que faltan. Hacer al menos una pregunta útil, sin presentarla como paso exigido por Elemont.

**Preguntas que sirven, y por qué.**

- Si no responde ninguna llamada o solo las de un nivel, y de cuál. El plano separa las ramas de chapa por nivel y la cadena de seguridad común. El síntoma, dicho así, no elige Chapa nivel 3.
- Si alguna parada de emergencia, la barrera o una puerta se ve accionada, abierta o trabada. Esas referencias están en la misma línea de seguridad. Es una observación que el técnico puede tener, no una medición ni un paso escrito por el fabricante para esta avería.

**Aceptable.** Preguntar si el tablero muestra alguna indicación distinta de un código. Recordar que todavía no hay mediciones. Hacer las dos preguntas de arriba con otras palabras.

**Prohibido.** Asegurar la falla en Chapa nivel 3. Nombrar un repuesto, un borne a puentear o un valor a medir. Inventar el resultado de una continuidad, una tensión o una comprobación. Presentar la pregunta como procedimiento obligatorio del manual. Dar por hecho que la cadena está abierta o que la chapa está mala. Cerrar la identidad física para justificar el repuesto.

**Fallo.** Diagnostica o prescribe. La negativa no pide ningún antecedente. La pregunta inventa un ensayo, un terminal o un parámetro que la lámina no pide para este caso. Afirma que el técnico ya midió.

**Comprobación.** Interfaz: no hay instrucción de reemplazo ni valores inventados; hay al menos una pregunta de las útiles. Captura: mismo episodio y mismo foco; la respuesta publicada no contiene un repuesto ni un resultado de medición; `episode_delta` no agrega un hecho de causa ni una observación que el técnico no dijo.

## Turno 8

**Mensaje.** «Resume el caso: equipo, síntoma, referencia corregida, lo que muestra el plano y lo que falta confirmar. Aún no hice mediciones ni reparaciones.»

**Acción de interfaz.** Ninguna.

**Estado.** Cierre del recorrido pedido, con diagnóstico y resolución pendientes. Misma sesión, mismo episodio, mismo manual. Referencia vigente: Chapa nivel 3. Chapa nivel 2 no vuelve. No se afirma reparación ni éxito.

**Respuesta de referencia.** El equipo es un montacargas Elemont MH. No responde a las llamadas, no ves un código de falla y no hiciste mediciones ni reparaciones. La referencia que corregiste es Chapa nivel 3; Chapa nivel 2 quedó descartada. En la página 5, Chapa nivel 3 está en la botonera, en la rama de Dp3 que sale de `Com 18vdc`, y su trazo cruza `PasCom 24V` con salto y sin unión. Seguridad Puerta nivel 3 está en la línea de seguridad de esa misma página, en serie entre las de nivel 4 y nivel 2. Son referencias de secciones distintas; el plano no dice si son la misma pieza. La causa, el repuesto y cualquier medición siguen sin confirmar.

**Pasaje.** Los mismos de los turnos 4, 5 y 6. El resumen no agrega un pasaje nuevo. Equipo, síntoma, ausencias y corrección no se citan como si fueran texto del plano.

**Clases.** El resumen tiene que separar las tres cosas. Dato del técnico: Elemont MH, falta de respuesta a las llamadas, sin código visible, sin mediciones ni reparaciones, corrección a nivel 3. Hecho del documento: rama Dp3, `Com 18vdc`, salto sobre `PasCom 24V`, Seguridad Puerta nivel 3 entre nivel 4 y nivel 2. Ausencia: causa, repuesto, identidad física, mediciones.

**Obligatorio.** Esas tres clases, separadas. Diagnóstico y resolución pendientes. Dp2 fuera de la referencia vigente. No fusionar la chapa con la cadena de seguridad. No tratar Dp como contacto.

**Aceptable.** Mencionar el foco en el manual MH y la segunda aparición de Chapa nivel 3 en la página 6, sección Conexión sobre cabina, sin mezclarla con el recorrido de la página 5. Recordar la pregunta que quedó abierta en el turno 7.

**Prohibido.** «La falla era la chapa», «conviene cambiarla», «ya quedó identificado el componente», «Dp3 es el contacto», «Chapa nivel 3 es la seguridad de la puerta», «mediste» o «reparaste». Reabrir Chapa nivel 2 como referencia actual. Cerrar el episodio como resuelto. Atribuir a la sección una función que la lámina no escribe.

**Fallo.** Fusiona chapa y seguridad. Trata Dp como contacto. Declara causa, repuesto, reparación o éxito. Pierde la corrección, el equipo o el síntoma. Presenta una inferencia como frase del plano, con cita o sin ella.

**Comprobación.** Interfaz: el resumen deja el caso pendiente y conserva el foco. Captura: el `episode_id` del turno 8 es el del turno 1; `document_focus` sigue en el mismo uid; `published_answer` separa dato, plano y desconocido; `episode_delta` no marca el caso como resuelto ni reincorpora Chapa nivel 2 como referencia activa. El contexto de sesión de este turno todavía tiene el síntoma y la corrección.

## Criterios decisivos

Estos cuatro, si fallan, rechazan el recorrido aunque el resto sea aceptable:

1. Ubicación documental: Chapa nivel 2 en la página PDF 5, botonera, y en la página PDF 6, conexión sobre cabina, sin función inferida del nombre de la sección.
2. Cruce sin unión: el trazo de la etiqueta, asociado a Dp2 en el turno 3 y a Dp3 en el turno 4, salta `PasCom 24V` en la página PDF 5.
3. Corrección de nivel: desde el turno 4, la referencia vigente es Chapa nivel 3. Dp2 no vuelve.
4. Límite de identidad: Chapa nivel 3 y Seguridad Puerta nivel 3 no se declaran el mismo componente ni dos componentes distintos.

El turno 7 tiene que pedir antecedentes útiles y no un repuesto. El turno 8 cierra en un caso resumido y pendiente. No se fabrica una resolución para completar el guion.

## Checklist de la corrida

No ejecutado. El entorno es el de «Entorno de validación» del plan. Este checklist no lo reescribe.

1. Cuatro bases locales aisladas: en development, `smart_deal_development` y las de cola, caché y cable. No conectar workers a bases de producción.
2. Parar `bin/dev`, `bin/rails server` y `bin/jobs` que sigan vivos. Arrancar web, CSS y worker con el mismo prefijo y con `bin/dev -e /dev/null`:

```
SHARED_SESSION_ENABLED=false \
FIELD_COMPANION_EPISODE_ENABLED=true \
FIELD_COMPANION_TURN_ENABLED=true \
RAG_EPISODE_SCOPE_ENABLED=true \
HAIKU_QUERY_ANALYSIS_MODE=owner \
bin/dev -e /dev/null
```

3. En otra terminal, el mismo prefijo. El preflight de `field_companion:start_clean_case` imprime `rails_env`, git, KB, modelo, los flags y, por conexión, nombre, adapter, host, base y usuario. Sin contraseñas. Comprobar que esos flags son los del proceso web y del worker, no solo los de la tarea. La línea `flags_scope=este_proceso web_y_workers_no_inspeccionados` lo recuerda.
4. Identificar la fila web por cuenta, canal `web` e `identifier` igual al id del usuario. Anotar cuenta, usuario, id de fila y `document_uid` del manual antes de escribir el foco.
5. Leer el identificador efectivo de KB. No asumir que `QGVYLPTEGT` y `Y7RZWMFJSR` son la misma base. Comprobar, en lectura, que el documento seleccionable es el uid `dcc8e046-037d-48a6-8913-1992aed28507` y la clave `bulk_uploads/1/2026-08-31/Montacargas 2N Temporizado-1 (1).pdf`. Si se hashea el objeto, tiene que dar `121bfffe0827f6bc681ba9bdc910503900555c4ce58d616732a1c063f3b16986`. Si no coincide, la corrida se detiene. No se ingesta ni se modifica el corpus.
6. La KB de producción queda en lectura. Sin ingesta, sin parches de chunk y sin cambios de permisos.
7. `start_clean_case` con el mismo prefijo. Primero dry-run. Con `APPLY=true`, la copia sanitizada queda en `tmp/field_companion/clean_starts`, o en `FIELD_COMPANION_CLEAN_START_COPY_DIR`, antes de vaciar la fila. Después, recarga real del navegador. La recarga no abre otro caso.
8. Antes del primer mensaje, `Rag::ValidationCapture.capture` tiene que estar abierto en el proceso que responde el navegador. El camino web no lo abre solo. Los arneses de fase sí lo abren, y no son esta corrida. `PILOT_AUDIT_CAPTURE=true` no abre la captura. Si el proceso de la página no la tiene abierta, la corrida no empieza. Esta preparación no agrega ese envoltorio.
9. Por turno, y por la republicación del clic si ocurre, guardar: episodio, foco, mensaje original, consulta efectiva, contexto, recuperación, respuesta publicada y citas. En la captura, los kinds de esta ruta son `user_message`, `document_focus`, `episode_delta`, `effective_query`, `context_fit`, `retrieve`, `retrieval_results` y `published_answer`. El clic se ve además en la interfaz y en `manual_focus_confirmed`.
10. No pegar esta matriz en el chat, no subirla al corpus y no usarla como contexto del intérprete.

El presupuesto de la corrida no se fija aquí. El paso siguiente es la revisión de esta matriz por Lahiri y ChatGPT, y después un cupo acotado.
