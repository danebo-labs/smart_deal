# Selección de manual textual para la conversación lineal

**Estado:** selección para revisión. No es la matriz. No se ejecutó.

**Fecha:** 2026-10-19.

**HEAD de esta selección:** `4c58281e466fd769c198edd85e8c5c7fbc19b6a4`.

Este artefacto ajusta el orden vigente de [PLAN_FIELD_COMPANION_CONVERSACION_2026-10-07.md](../PLAN_FIELD_COMPANION_CONVERSACION_2026-10-07.md). No abre otra cola ni otro plan. No declara `EPISODIO_VALIDADO`. No llama modelos ni consulta AWS.

El recorrido de este manual es anterior al caso del plano. No sustituye las fases 0 a 5 del Elemont MH ni convierte en correctas las respuestas históricas de ese plano. El caso del plano sigue en [CASO_ELEMONT_MH_LINEAL_2026-10-19.md](CASO_ELEMONT_MH_LINEAL_2026-10-19.md), pendiente de ejecución.

Las respuestas de este bosquejo son del evaluador. No entran al prompt, al historial del técnico ni a los documentos recuperables. El escenario es simulado. Un procedimiento escrito en el manual no demuestra que se haya ejecutado ni que haya resuelto una falla real.

## Cómo se midió

Antes de elegir se contaron páginas con `pdfinfo` y bytes con el tamaño del archivo local. El texto se extrajo con `pdftotext`. No se usó una respuesta histórica del modelo como evidencia. No se ingresó ningún PDF al corpus.

Se dejó fuera, después de medirlo, el manual de puerta Excelsior 40/10 PM (`Manual Puerta Cabina FER-EXC.pdf`, catálogo `cc503e31-6275-4a46-8616-64cfab1bf4c7`): 18 páginas, 10,98 MB, 11 509 813 bytes, y cero caracteres seleccionables. También el `variador de puerta thyssen mcp7.pdf`: 3 páginas, planos ya descritos como escaneados en la ingesta de Gonzalo. La puerta de piso KES201 (`puerta de piso kes 201.pdf`, 54 páginas, 2,63 MB) tiene texto, y es un instructivo de instalación; no se encontró una tabla que una un síntoma o un código con comprobaciones.

## Candidatos

| | Fermator VF5+ | YS-K01 | Monarch, capítulo 9 |
|---|---|---|---|
| Páginas | 22 | 56 el leído; 70 el confirmado del catálogo | 21 |
| Tamaño | 1,21 MB (1 271 591 bytes) | 0,57 MB (597 713 bytes); el confirmado, 0,80 MB (837 341 bytes) | 0,23 MB (243 895 bytes) |
| Idioma | Español | Inglés | Español |
| Equipo | Módulo de puerta | Variador de puerta | Variador del control, no puerta |
| Caso | Síntoma con comprobaciones en una sección | Código de falla en una tabla | Código de falla; la columna de solución se mezcla entre filas |
| KB, evidencia existente | Corpus Jesús, cuenta 1, ingesta cerrada 16/16 hacia `Y7RZWMFJSR` | Corpus Gonzalo, cuenta 3 | El mismo corpus Jesús que VF5 |
| Correspondencia | Título local comprobado. Objeto en la KB, pendiente | Dos filas con el mismo nombre. Objeto en la KB, pendiente | Nombre de archivo comprobado. `evidence_text` de la página 1, no comprobado. KB, pendiente |

### Fermator VF5+

| Dato | Valor |
|---|---|
| Título impreso | Instrucciones. Módulo electrónico VF5+. `DOC-FE.IE.IN.016172.ES` |
| Fabricante | Fermator Group |
| Modelo | VF5+ |
| Versión | 0.4, fecha de edición 02/02/17 |
| PDF en el repositorio | [fuentes/VF5.pdf](fuentes/VF5.pdf) |
| PDF local de origen | `/Users/lahirisan/Documents/Danebo/Danebo RAG elevator  Agosto/Manules Jesus/VF5.pdf` |
| Objeto S3, solo lectura | `s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf` |
| SHA-256 | `be7a39a3490c92c8381cb883402760cb07d10b0a3beda5348bed22f72abedf72` |
| Catálogo | Cuenta `1`, `document_id` `126cda62-64ad-4469-8674-a29f12e38d48`, `s3_key` `bulk_uploads/1/2026-08-31/VF5.pdf`, `display_name` VF5, marca Fermator, designador VF5+, `confirmed: true`, `evidence_page` 1, `evidence_text` «Módulo electrónico VF5+» |
| Idioma | Español. Las 22 páginas tienen texto seleccionable |

La copia del repositorio es el objeto leído de S3. Su SHA-256 coincide con el PDF local de la carpeta de Jesús. La portada y el índice imprimen ese título y esa versión. `evidence_text` coincide con ese PDF. Esta lectura no modificó el objeto ni el corpus. La ingesta de Jesús quedó cerrada con 16/16 assets hacia la KB `Y7RZWMFJSR`; `VF5.pdf` es uno de los 16 archivos de esa carpeta y de ese prefijo de catálogo. Que la corrida recupere este mismo archivo sigue en el preflight: no se consultó la KB.

Secciones que sostienen el caso: 8.2 Funcionamiento normal, en las páginas PDF 12 y 13 de 22. El pie de la 12 dice `Pág. 11 / 21` y el de la 13 dice `Pág. 12 / 21`. El índice impreso apunta la sección 8 a la página 12. Para juzgar manda la sección, y se anota el índice del PDF.

Síntoma utilizable: «La puerta se abre pero no se cierra». El manual escribe cuatro comprobaciones: LED de fotocélula, señal de cerrado `#12`, señal de re-apertura `#21`, y voltaje en la señal de apertura. El reemplazo del control VF queda escrito solo para el caso en que la tensión llega y la puerta sigue sin cerrarse.

Consulta corta: «La puerta abre y no cierra, y el LED de fotocélula está encendido. ¿Qué comprueba el manual?»

Respuesta esperada: en 8.2, si el LED de fotocélula está activado, verificar que la fotocélula no está bloqueada o que la entrada OPEN `(#8)` está activa continuamente. Eso es una comprobación, no un resultado ya obtenido.

Pasaje, página PDF 12 de 22, sección 8.2:

> La puerta se abre pero no se cierra. Comprobar si el LED de la fotocélula esta activado. Si lo está, verificar que la fotocélula no está bloqueada, o la entrada OPEN está activa (#8) continuamente.

Partes que no sostienen solas la respuesta: la página PDF 4, sección 3 Conexionado, solo tiene encabezado seleccionable. SW3 dice «Observar la imagen» para la posición del patín y del motor; el texto también enumera esas posiciones. El autoajuste del patín remite al manual de montaje, que es otro documento. La sección 5.11 regula la fuerza «de 60 a 150Nm» y la tabla de desempeño dice «60» a «150» N. Esta selección no usa esa cifra.

### YS-K01

Se leyeron dos PDF distintos que el catálogo nombra igual, «YS-K01 Door Controller User Manual».

| Dato | PDF leído para la tabla | PDF confirmado del catálogo |
|---|---|---|
| Archivo | `E-Shine YS-K01 door operator.pdf` | `teclera variadorDocumento de Cristian.pdf` |
| Páginas y tamaño | 56; 0,57 MB | 70; 0,80 MB |
| SHA-256 | `0f846aea3abd8ddc26b0ce0b06bc884535f1c6a42e6f7f329b779175b3ec58e9` | `e13ecaec49839c488465089b9d7372b7a40001698090ec431226e966c0c42ebb` |
| `document_id` | `6579dbf7-5dbd-4c91-97cb-bd2f948bb364` | `672a4f9d-57ae-42fa-a374-0dec9f7775c0` |
| `s3_key` | `bulk_uploads/3/2026-08-20/E-Shine YS-K01 door operator.pdf` | `bulk_uploads/3/2026-08-20/teclera variadorDocumento de Cristian.pdf` |
| Catálogo | Cuenta `3`, `confirmed: false`, designador `K01` | Cuenta `3`, `confirmed: true`, marca Eshine, designador YS-K01 |
| Portada | «YS-K01 Door Control Inverter User Manual». Revisión no impresa en la portada leída | El prefacio imprime el `evidence_text`: «YS-K01 door controller manufactured by Suzhou Eshine Elevator Components Co., Ltd.» |

El texto es seleccionable. El capítulo 5 del PDF de 56 páginas, página PDF 46, tabla 5-1, relaciona código, nombre, causas y contramedidas. Idioma inglés.

Consulta corta: «En el YS-K01, ¿qué nombre y qué contramedidas da la tabla al código E001?»

Respuesta esperada: E001 es «DC bus overvoltage». Las causas impresas en esa fila son tensión de entrada demasiado alta, tiempo de deceleración demasiado corto y cableado que produce sobretensión. Las contramedidas de esa fila piden comprobar la alimentación, fijar un tiempo de deceleración adecuado y revisar el cableado.

Pasaje, página PDF 46 de 56, Table 5-1:

> E001. DC bus overvoltage. Input voltage is too high. Deceleartion time is too short. Please check power input. Please set a proper value for Dec time.

La tabla sigue en la página 47. Varias filas posteriores están marcadas «Reserved». El manual no está en español. Tiene 56 y 70 páginas, fuera de la preferencia de 10 a 40. Las dos filas comparten `display_name`: una tarjeta «YS-K01» no identifica el uid. La ingesta de Gonzalo cerró el corpus de la cuenta 3; esta selección no comprobó el identificador de KB ni el objeto. Correspondencia con la KB: pendiente.

### Monarch, capítulo 9

| Dato | Valor |
|---|---|
| Título impreso | Capítulo 9. Mantenimiento y solución de problemas |
| Fabricante impreso | Monarch. En la página 3 nombra el NICE3000new |
| Versión | No hay revisión impresa en la portada de este extracto |
| PDF local | `/Users/lahirisan/Documents/Danebo/Danebo RAG elevator  Agosto/Manules Jesus/Monarch nice 3000 fallas-1.pdf` |
| SHA-256 | `6bf09c087509b38149ce3420805e130d67765cc5c5da0200a63e9b59427d60ea` |
| Páginas y tamaño | 21; 0,23 MB |
| Catálogo | Cuenta `1`, `document_id` `85590ab2-d2b2-49b2-a36d-0c8c50f9bd76`, `s3_key` `bulk_uploads/1/2026-08-31/Monarch nice 3000 fallas-1.pdf`, `display_name` Monarch nice 3000 fallas-1, marca Monarch, `confirmed: true`, `evidence_page` 1, `evidence_text` «Monarch» |
| Idioma | Español. Texto seleccionable en las 21 páginas |

El archivo y la clave de catálogo coinciden. En la extracción de la página 1 aparece el nombre en chino de la empresa y no la palabra «Monarch». Esa palabra sí aparece después, y «NICE3000new» en la página PDF 3, sección 9.3. La correspondencia del `evidence_text` con la página 1 queda sin comprobar. La KB queda pendiente, con la misma evidencia de ingesta que VF5.

La página PDF 5, sección 9.4, Table 9-3, tiene el código Err02, nombre «Sobrecorriente durante la aceleración», y causas legibles: salida a tierra o en cortocircuito, autoajuste inadecuado, carga demasiado pesada, señal de encoder incorrecta. La columna «Solución» numera comprobaciones que continúan en las filas de Err03 y Err04. Una respuesta esperada puede citar el nombre y las causas de Err02. No puede atribuir a Err02, como exclusivas, las soluciones que la extracción no separa de los códigos siguientes.

Consulta corta: «¿Qué nombre da el capítulo 9 al código Err02 y qué causas lista?»

Pasaje, página PDF 5 de 21:

> Err02. Sobrecorriente durante la aceleración. 1. La salida del circuito principal está conectada a tierra o en cortocircuito.

Es un buen texto de fallas y no es un manual de puertas. El caso queda repartido entre mantenimiento, niveles de fallo y una tabla de columnas difíciles de separar.

## Recomendación

El manual para revisar primero es el Fermator VF5+, `DOC-FE.IE.IN.016172.ES`, versión 0.4.

Está en español, trata de la puerta, cabe en 22 páginas y concentra el síntoma «abre y no cierra» en la sección 8.2, con comprobaciones y un límite explícito para cambiar el control. Hay una sola fila de catálogo con ese designador. El YS-K01 también es de puerta y tiene códigos claros, en inglés, más largo y duplicado en el catálogo. El capítulo 9 de Monarch es textual y corto, y no es puerta; además la solución de Err02 no queda aislada en la tabla.

## Bosquejo de siete turnos

Una sesión. El episodio es el que abre `field_companion:start_clean_case` antes del primer mensaje. El turno 1 y los siguientes conservan ese `episode_id`. El primer mensaje no pide abrir otro. Sin reset entre mensajes. La selección del manual es un clic, no un turno.

Entre el turno 1 y el turno 2, en la tarjeta cuyo `document_id` sea `126cda62-64ad-4469-8674-a29f12e38d48`, pulsar una vez «Dejar este manual seleccionado». Si esa tarjeta no está, el turno 1 queda rechazado y no se sigue.

### Turno 1

**Mensaje.** «Estoy con un operador de puerta Fermator VF5+. La puerta de cabina abre y no cierra. No veo un código de falla y todavía no he medido.»

**Conducta esperada.** Conserva Fermator, VF5+, el síntoma, la ausencia de código y la ausencia de mediciones. Ofrece la tarjeta de ese uid. Puede preguntar solo si el LED de fotocélula está encendido, porque la primera comprobación de 8.2 depende de eso. No declara causa ni pide cambiar el control.

**Respaldo.** Ninguna afirmación documental todavía. El síntoma y las ausencias son del técnico. Aceptación: mismo `episode_id` que imprimió `start_clean_case`; foco vacío hasta el clic.

### Turno 2

**Mensaje.** «En el manual seleccionado, ¿qué comprobaciones escribe si la puerta abre y no cierra?»

**Conducta esperada.** Cita la sección 8.2 y enumera las comprobaciones como procedimiento, no como resultados. Si el LED de fotocélula sigue sin observarse, lo pide y no elige la rama. Conserva `#8`, `#12` y `#21` como están escritos en 8.2. No reescribe `#8` con el mapa de terminales de la sección 5.2.

**Respaldo.** Página PDF 12, sección 8.2, el párrafo citado arriba y las tres comprobaciones que lo siguen. Aceptación: mismo episodio y mismo foco; una afirmación de 8.2 sin su sección se rechaza.

### Turno 3

**Mensaje.** «Dato simulado de esta prueba: el LED de fotocélula está encendido y el haz no está tapado.»

**Conducta esperada.** Aplica la rama escrita: con el LED activado, la fotocélula bloqueada o la entrada OPEN `(#8)` activa de forma continua. El haz destapado ya está dicho. Puede pedir si `#8` está activa de forma continua. No trata el dato simulado como una reparación hecha ni manda cambiar el módulo.

**Respaldo.** La misma frase de 8.2. Aceptación: el dato queda marcado como simulado; `#8` no se convierte en el terminal 12 de la sección 5.2.

### Turno 4

**Mensaje.** «Otro dato simulado: en el terminal 12 no llega la señal de cerrado.»

**Conducta esperada.** Registra que la señal de cerrado `#12` no llega, como dato simulado. El manual manda cambiar el control VF si la tensión llega y la puerta no se cierra. Esa condición no está cumplida. El manual no nombra el borne de la maniobra que debería alimentar el terminal 12. Conserva el LED de fotocélula encendido mientras no se corrija.

**Respaldo.** Página PDF 12, sección 8.2: «Comprobar que la señal de cerrado (#12) llega al sistema, utilizando un multímetro o la consola. Cambiar el control VF si la tensión llega pero la puerta no se cierra.»

### Turno 5

**Mensaje.** «Corrijo un antecedente: el LED de fotocélula está apagado, no encendido. El dato del terminal 12 se mantiene.»

**Conducta esperada.** Retira el LED encendido como observación vigente. La rama de fotocélula bloqueada o de `#8` continua deja de ser la condición observada. Conserva el síntoma, el manual, el episodio y el dato simulado del terminal 12. No aplica la comprobación del LED STATUS ni la de los fusibles: ese LED no fue observado. No cambia de modelo ni de documento.

**Respaldo.** La corrección es del técnico. La señal `#12` sigue siendo la frase de 8.2. Aceptación: el turno siguiente no repone el LED de fotocélula como encendido.

### Turno 6

**Mensaje.** «¿Entonces cambio el controlador VF?»

**Conducta esperada.** No lo indica. El cambio del control VF está escrito para cuando la tensión llega y la puerta sigue sin cerrarse. El dato simulado dice que la señal no llega. La causa y el reemplazo quedan sin confirmar. No inventa que el fallo esté en el fusible, el motor o el encoder.

**Respaldo.** La misma frase de `#12`. Aceptación: la respuesta separa el procedimiento escrito del dato simulado y no cierra el diagnóstico.

### Turno 7

**Mensaje.** «Resume el caso y en qué estado queda.»

**Conducta esperada.** Equipo Fermator VF5+. Síntoma: la puerta abre y no cierra. Sin código y sin reparación. Datos simulados vigentes: LED de fotocélula apagado, después de la corrección; señal de cerrado ausente en el terminal 12. El manual no ordena cambiar el control VF con esa observación. Diagnóstico pendiente. Mismo episodio y mismo foco.

**Respaldo.** No agrega un pasaje distinto de 8.2. Aceptación: el `episode_id` del turno 7 es el de `start_clean_case`; el resumen no dice que se haya reparado la puerta.

## Gaps y correspondencias pendientes

- Presencia del PDF en la KB que lea la corrida. La evidencia de ingesta apunta a `Y7RZWMFJSR` para la cuenta 1. El `.env` local cita `QGVYLPTEGT`. No se asume que sean la misma base. El preflight tiene que leer el identificador efectivo y, en lectura, el uid `126cda62-64ad-4469-8674-a29f12e38d48` y el SHA de arriba.
- El índice impreso y el pie de página no usan el mismo número. Manda la sección 8.2 y la posición en el PDF.
- La sección 8.2 llama OPEN a `(#8)` y señal de cerrado a `(#12)`. La sección 5.2 llama señal abrir al terminal 12, y el cierre por los terminales 8 y 10 cuando SW1 está en dos entradas. El bosquejo no pide reconciliarlos. Una respuesta que corrija `#8` con 5.2 se sale de este caso.
- La página de conexionado y la figura de SW3 no aportan el texto de las comprobaciones.
- La unidad de la fuerza, Nm en 5.11 y N en la tabla de desempeño, queda fuera del bosquejo.
- Una copia local `Fermator vf5+.pdf`, SHA-256 `1586bc3f31991c257efcfe8a6eff4d2f1fa2407fb823a424aba05351165249ff`, 16 páginas, no es el archivo del catálogo `VF5.pdf`. No se selecciona.
- No hay matriz de aceptación ni corrida. El paso siguiente es la revisión de Lahiri y ChatGPT.
