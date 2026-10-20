# Selección de manual textual para la conversación lineal

**Estado:** manual elegido. El caso recomendado es «La puerta se re-abre sola». La matriz está en [CASO_FERMATOR_VF5_REABRE_SOLA_2026-10-19.md](CASO_FERMATOR_VF5_REABRE_SOLA_2026-10-19.md). No se ejecutó.

**Fecha:** 2026-10-19.

**HEAD de la selección original:** `4c58281e466fd769c198edd85e8c5c7fbc19b6a4`. El PDF del catálogo quedó en el repositorio en `5a40f9a3524bcc8a33471317a36734ac5afb8ceb`. Este corte, sobre ese HEAD, cambia el síntoma recomendado.

Este artefacto ajusta el orden vigente de [PLAN_FIELD_COMPANION_CONVERSACION_2026-10-07.md](../PLAN_FIELD_COMPANION_CONVERSACION_2026-10-07.md). No abre otra cola ni otro plan. No declara `EPISODIO_VALIDADO`. No llama modelos ni consulta AWS.

El recorrido de este manual es el orden 2 y es anterior al caso del plano. No sustituye las fases 0 a 5 del Elemont MH ni convierte en correctas las respuestas históricas de ese plano. El caso del plano sigue en el orden 3, [CASO_ELEMONT_MH_LINEAL_2026-10-19.md](CASO_ELEMONT_MH_LINEAL_2026-10-19.md), pendiente de ejecución. Aceptar después el recorrido textual no cierra esas fases.

Las respuestas de la matriz son del evaluador. No entran al prompt, al historial del técnico ni a los documentos recuperables. El escenario es simulado. Un procedimiento escrito en el manual no demuestra que se haya ejecutado ni que haya resuelto una falla real.

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
| Caso | «La puerta se re-abre sola», tres comprobaciones en 8.2 | Código de falla en una tabla | Código de falla; la columna de solución se mezcla entre filas |
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

Sección que sostiene el caso: 8.2 Funcionamiento normal, «La puerta se re-abre sola», página PDF 12 de 22, con una raya que continúa en la página PDF 13. El pie de la 12 dice `Pág. 11 / 21` y el de la 13 dice `Pág. 12 / 21`. El índice impreso apunta la sección 8 a la página 12. Para juzgar manda la sección, y se anota el índice del PDF. La diferencia máster/esclavo está en la página PDF 5, sección 4, SW4; el pie de esa página dice `Pág. 4 / 21` y el índice apunta la sección 4 a la página 5.

Síntoma del primer recorrido: «La puerta se re-abre sola». El manual escribe tres comprobaciones en la página PDF 12: sensibilidad del potenciómetro de regulación de fuerza de re-apertura `#54`, fotocélula no activada y obstrucción mecánica. La página PDF 13 añade, si el problema persista, desconectar la fotocélula y pulsar TEST. El contraste visual y el texto están en la matriz. Este caso no usa valores de fuerza.

El apartado vecino «La puerta se abre pero no se cierra», en la misma 8.2, queda fuera del primer recorrido. ChatGPT contrastó el documento original: ese apartado llama OPEN a `(#8)` y señal de cerrado a `(#12)`. La sección 4, en el esquema de dos entradas, rotula cerrar en el terminal 8 y abrir en el 12. La sección 5.2 llama al 12 «Señal abrir» y al 8 «Señal cerrar». La inversión queda registrada para una prueba posterior. Detectarla no se penaliza. Esta selección no modifica el PDF ni los chunks para ocultarla. El bosquejo de siete turnos que usaba «abre y no cierra» queda retirado como primer recorrido; el guion vigente es la matriz.

Partes que no sostienen solas la respuesta: la página PDF 4, sección 3 Conexionado, solo tiene encabezado seleccionable. SW3 dice «Observar la imagen» para la posición del patín y del motor; el texto también enumera esas posiciones. El autoajuste del patín remite al manual de montaje, que es otro documento. La sección 5.11 regula la fuerza «de 60 a 150Nm» y la tabla de desempeño dice «60» a «150» N. Esta selección no usa esa cifra. El síntoma «La puerta se vuelve a abrir cuando el patín está cerrando», en la página PDF 13, es otro apartado.

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

Está en español, trata de la puerta, cabe en 22 páginas y concentra «La puerta se re-abre sola» en la sección 8.2, con tres comprobaciones en una sola página del PDF. Hay una sola fila de catálogo con ese designador. El síntoma «abre y no cierra» del mismo apartado queda para después, porque invierte apertura y cierre respecto de las secciones 4 y 5.2. El YS-K01 también es de puerta y tiene códigos claros, en inglés, más largo y duplicado en el catálogo. El capítulo 9 de Monarch es textual y corto, y no es puerta; además la solución de Err02 no queda aislada en la tabla.

## Guion vigente

El bosquejo de «abre y no cierra» no se ejecuta. Los siete turnos, las respuestas de referencia y las causas de rechazo están en [CASO_FERMATOR_VF5_REABRE_SOLA_2026-10-19.md](CASO_FERMATOR_VF5_REABRE_SOLA_2026-10-19.md). Una sesión. El episodio es el que abre `field_companion:start_clean_case`. El clic sobre `126cda62-64ad-4469-8674-a29f12e38d48` no es un turno.

## Gaps y correspondencias pendientes

- Presencia del PDF en la KB que lea la corrida. La evidencia de ingesta apunta a `Y7RZWMFJSR` para la cuenta 1. El `.env` local cita `QGVYLPTEGT`. No se asume que sean la misma base. El preflight tiene que leer el identificador efectivo y, en lectura, el uid `126cda62-64ad-4469-8674-a29f12e38d48` y el SHA de arriba.
- El índice impreso y el pie de página no usan el mismo número. Manda la sección, y se anota el índice del PDF.
- La inversión de `#8` y `#12` queda para una prueba posterior. Detectarla en el recorrido de la reapertura no se penaliza. Sustituir con ella las comprobaciones de «se re-abre sola» sí se rechaza, y el criterio está en la matriz.
- La página de conexionado y la figura de SW3 no aportan el texto de las comprobaciones.
- La unidad de la fuerza, Nm en 5.11 y N en la tabla de desempeño, queda fuera de este recorrido.
- Una copia local `Fermator vf5+.pdf`, SHA-256 `1586bc3f31991c257efcfe8a6eff4d2f1fa2407fb823a424aba05351165249ff`, 16 páginas, no es el archivo del catálogo `VF5.pdf`. No se selecciona.
- La matriz está escrita y no hubo corrida. El paso siguiente es la revisión de Lahiri y ChatGPT, y después una pasada con captura y presupuesto acotado. Todavía no corresponde declarar un recorrido aceptado ni `EPISODIO_VALIDADO`.
