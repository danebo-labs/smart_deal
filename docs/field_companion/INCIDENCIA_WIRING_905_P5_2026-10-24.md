# Incidencia: Wiring 905, página 5, chunk por encima del límite de Titan

**Estado.** Reparación aceptada el 24 de octubre de 2026. Job `WICDOPPTFE`, `COMPLETE`, fallidos 0. F4 del VF5 sigue aceptada en `3d76aac`. F5 no queda bloqueada: este objeto no está en el prefijo del VF5. El control general de tamaño antes de publicar sigue pendiente y no forma parte de esta reparación.

Lectura del 24 de octubre de 2026, con el perfil `default` ya usado en F4. STS devolvió la cuenta `935142957735` y `arn:aws:iam::935142957735:user/Lahiri`. No se imprimieron claves. No hubo `PutObject`, `DeleteObject`, `start_ingestion_job`, Retrieve ni llamada de generación.

## 1. Documento y error exacto

| Campo | Valor |
| --- | --- |
| Job | `PTNRRF0BZJ` |
| Knowledge base | `Y7RZWMFJSR` |
| Datasource | `PJ0N58DMHG` |
| Estado | `COMPLETE`, de `2026-10-24T01:33:34Z` a `2026-10-24T01:34:19Z` |
| Objeto | `bulk_chunks/3/5b1859a0bfe1c5b11e58214555f8c2fe93e6/chunk_p5_1.txt` |
| Bucket | `multimodal-source-destination` |
| Bytes / SHA-256 | 22548 / `c116762136452541d3df1116a810bccc6554178b95590f5817470b84d14e1d82` |
| Sidecar | misma clave más `.metadata.json`, 765 bytes, SHA-256 `7717b593b7da334a18b5480453353fe42bb3aba02f95ac01161906dfaa935eb2` |

`get_ingestion_job` devolvió un solo elemento en `failure_reasons` y `numberOfDocumentsFailed` 1. El texto del elemento es:

`["Encountered error: 400 Bad Request: Too many input tokens. Max input tokens: 8192, request input token count: 9048  (Service: BedrockRuntime, Status Code: 400, Request ID: a13827e9-22b6-4e5c-91ff-d652e0e1010d) (SDK Attempt Count: 1). Issue occurred while processing file: bulk_chunks/3/5b1859a0bfe1c5b11e58214555f8c2fe93e6/chunk_p5_1.txt. Call to Customer Source did not succeed."]`

Estadísticas del mismo job: escaneados 14933, metadatos escaneados 14933, nuevos 17, modificados 28, metadatos modificados 0, borrados 2, fallidos 1. Los 17 nuevos y los 2 borrados explican el salto desde los 14918 de los jobs anteriores. Coinciden con la sustitución del VF5. El fallido no es de ese prefijo.

Procedencia, leída del sidecar y del catálogo:

- Cuenta `3`. `document_id` del chunk: `5b1859a0bfe1c5b11e58214555f8c2fe93e6`, que es `doc_sha256[0,36]`.
- PDF: `Wiring - 905.pdf`, SHA-256 `5b1859a0bfe1c5b11e58214555f8c2fe93e6384564408c3f98fa6e53f4effaa7`.
- URI: `s3://multimodal-source-destination/bulk_uploads/3/2026-08-24/Wiring - 905.pdf`. 3064241 bytes, 88 páginas, subido el `2026-08-24T13:07:19Z`.
- Nombre canónico: `Wiring - 905`. Ruta `manual_batch_v1`. Contrato `field_records_v8`. Fingerprint del prompt en el sidecar: `e5b574784ff78547886919fe388edd51decbc13b0a37cfbd11bc041ff4ac1172`.
- Página del PDF: 5. El catálogo local, en `config/document_identities.yml`, tiene otra clave: `document_id` `9d870331-bc15-449c-9eb0-f496ab76ed82` para el mismo `s3_key`. No es el id del chunk.

El objeto y su sidecar tienen una sola versión en S3, los dos del `2026-08-24T13:57:22Z`. Los otros 188 objetos del mismo prefijo comparten esa hora. No hay delete marker. El versionado del bucket está `Enabled` ahora. No queda una versión anterior de este cuerpo.

## 2. Causa y alcance

La fuente de datos tiene `chunking_strategy` `NONE` y el prefijo de inclusión `bulk_chunks/`. La knowledge base usa `amazon.titan-embed-text-v2:0`, 1024 dimensiones. Con chunking `NONE`, el archivo entero es la entrada del embedding. El 8192 del error es el máximo de entrada de ese modelo. No es el `max_tokens` de generación.

La página 5 del PDF no tiene capa de texto: `pdftotext` de esa página devolvió un byte. El render local de la página es una sola hoja A4, plano `811850E00`, issue F, página 2/3, título `СПЕЦИФИКАЦИЯ`, posiciones 82 a 198 en una tabla y el bloque de revisiones en el cajetín. `chunk_p4_1.txt` es la página 1/3 de ese plano. `chunk_p6_1.txt` es la página 3/3. Esta clave es el único objeto de la página 5. No junta esas hojas.

El cuerpo tiene 18699 caracteres y 2127 palabras.

- El preámbulo, con la tabla markdown de 56 filas, mide 4019 bytes y 563 palabras.
- Los registros miden 18529 bytes y 1564 palabras.
- Hay 56 filas y 56 `SCHEMATIC_LABEL`, una por fila, más un `DOCUMENTATION_REQUIREMENT` del bloque de revisión. 57 `RECORD_ID`, todos distintos. Ninguna posición está repetida dentro de la tabla. La descripción impresa de cada fila está dentro de su `ACTION`. La única adición respecto de la celda es `(added Issue F)` en la posición 176.

La lista es una sección larga de una hoja. El tamaño que Titan rechaza sale de escribir esa lista dos veces en el mismo objeto: la tabla y un registro por fila. A la tasa medida de este archivo, la tabla sola queda cerca de 1614 tokens y los registros solos cerca de 7434. Solo la suma pasa de 8192.

El prompt de ingesta, desde `1168092`, pide partir una sección con más de 8 registros y no pasar de unas 1000 palabras. Este cuerpo trae 57 registros. `BatchResultsParserService#write_chunks_to_s3` no mide el cuerpo ni parte los registros: escribe el chunk que devolvió el modelo. El fingerprint vigente del prompt ya no es el del sidecar (`0c544f3c622a02fea6d0e81b6b615b27e656f1db829ac939af7d91cea74936f1`); la regla de los 8 registros sigue en el archivo y no se eliminó. El contrato sigue en `field_records_v8`.

Alcance de los errores guardados, releídos en los cuatro jobs, cada uno con un solo fallido y una sola razón, y esa razón nombra solo esta clave:

| Job | Cierre | Escaneados | Fallidos | Request del 400 | Tokens |
| --- | --- | --- | --- | --- | --- |
| `JUEUYVFGLN` | 2026-09-29T00:22:15Z | 14918 | 1 | `081ae57a-58f7-49df-b780-76039dfcb113` | 9048 |
| `XU1THSZ4ZT` | 2026-10-13T18:44:25Z | 14918 | 1 | `c8d71169-3367-40f4-b5d0-7aed9a54a25c` | 9048 |
| `CJBRIZKPAL` | 2026-10-14T17:17:09Z | 14918 | 1 | `4e520de7-362e-440d-ad01-3f109bf6a682` | 9048 |
| `PTNRRF0BZJ` | 2026-10-24T01:34:19Z | 14933 | 1 | `a13827e9-22b6-4e5c-91ff-d652e0e1010d` | 9048 |

En el prefijo de este documento hay 95 `.txt`. El siguiente por tamaño es `chunk_p12_1.txt`, 11388 bytes. A la tasa de esta página serían unos 4570 tokens. Hace falta casi el doble de densidad para llegar a 8192, y esta página ya es cirílico más el boilerplate de los registros. No se listó el resto del bucket.

El defecto de fondo es reproducible: cualquier cuerpo que el parser deje por encima de 8192 tokens de Titan falla igual, porque la fuente no parte y el parser no mide. En estos cuatro jobs el único caso observado es este archivo.

No se cambia el parser ni el contrato en este paso. El cambio mínimo, cuando se autorice aparte, es partir en `write_chunks_to_s3` un cuerpo que supere un techo conservador, por límites de registro, repitiendo la cabecera de identidad y el encabezado de sección. Sin subir `INGESTION_CONTRACT_VERSION`: el esquema del registro no cambia, y subirlo invalidaría la deduplicación. Sin activar el chunking de Bedrock: reharía el corpus ya partido por la aplicación.

## 3. Índice

Estos bytes no pudieron entrar en esta knowledge base. El modelo de embedding no se cambia en una KB existente, el límite declarado es 8192 y el conteo de este cuerpo es 9048 en los cuatro jobs. La única versión retenida es la de la ingesta del 24 de agosto. No hay un cuerpo anterior que pudiera haber quedado indexado.

`PTNRRF0BZJ` no incorporó esta versión: el embed respondió 400. No se hizo Retrieve. Esa llamada embebe la consulta, y esta revisión no la autorizaba. La ausencia se apoya en el fallo repetido y en la versión única, no en el hecho de que el objeto siga en S3.

Los demás objetos del prefijo no salen en la razón de fallo. Esta lectura no comprueba uno por uno si ya estaban en el índice.

## 4. Corrección local

`Wiring905Page5ChunkSplit` parte el cuerpo aceptado, SHA-256 `c1167621…`, en tres fragmentos de la misma página. Cada uno conserva la cabecera de documento, la URI, el encabezado S7, el párrafo de identidad del plano, el bloque de revisiones, la nota de issue y las filas de un tramo junto con el registro de cada fila. El registro de revisión queda una vez, en el primer fragmento. La frase que decía que la lista siguiente era toda la página pasa a decir que esas filas son las de este fragmento.

| Fragmento | Posiciones | Bytes | Palabras | SHA-256 | Estimación Titan |
| --- | --- | --- | --- | --- | --- |
| `chunk_p5_1.txt` | 82 a 106 | 9502 | 935 | `3f432d6b11ca696181d99a5adc277b751e27f8d997b924e6f92fd424909c702f` | 3813 |
| `chunk_p5_2.txt` | 112 a 141:S1 | 8971 | 879 | `a852b9fd17355c4a5198579755fdcca85c4a4f591ae11079c1caa5c262049ab6` | 3600 |
| `chunk_p5_3.txt` | 147 a 198 | 6452 | 664 | `d7aeaabf03a7bc576652b85ad17513a74ccd9e37fbee7ffcaeab755dd7daa47f` | 2589 |

Los tres sidecars son los bytes del sidecar actual, SHA-256 `7717b593…`. Misma cuenta, mismo documento, misma página 5, mismo contrato. No se añadieron claves de metadatos.

La estimación es lineal en bytes UTF-8, calibrada para que este cuerpo de 22548 bytes dé 9048. Es exacta en el original. No es el tokenizador de Titan. `AnthropicTokenCounter::LocalTokenizer` (caracteres / 3,5) da 5343 en el original, un 41 % por debajo del conteo de Bedrock: no sirve de techo. El fragmento mayor estima 3813. Para alcanzar 8192 tendría que tokenizar al menos 2,15 veces más denso que este mismo archivo. El texto repetido de más es inglés de cabecera, menos denso que el cirílico de los registros, así que la estimación de los fragmentos queda del lado alto. El servicio rechaza un fragmento cuya estimación pase de 6000.

Los 56 pares fila-registro se conservan, sin repetir una posición. Las posiciones 121 y 127, y el alias `LCEFCS LCEFOV`, quedan en el fragmento que las contiene.

Prueba: `bin/rails test test/services/wiring_905_page5_chunk_split_test.rb`. La candidata se reescribe en local con `bin/rails runner script/prepare_wiring_905_page5_split.rb`, bajo `tmp/field_companion/oversized_chunk_review/candidate/`. Ese directorio no se publica. La publicación de estos bytes está en la sección 7.

## 5. Operación remota

Una sola concesión, sin tocar el prefijo del VF5:

1. Sustituir `chunk_p5_1.txt` por el fragmento de SHA-256 `3f432d6b…`. El sidecar de esa clave ya es el SHA-256 `7717b593…`; no hace falta reescribirlo.
2. Crear `chunk_p5_2.txt` (`a852b9fd…`) y `chunk_p5_3.txt` (`d7aeaabf…`), cada uno con una copia de ese sidecar.
3. No borrar el resto del prefijo `bulk_chunks/3/5b1859a0bfe1c5b11e58214555f8c2fe93e6/`.
4. Un `start_ingestion_job` sobre `Y7RZWMFJSR` y `PJ0N58DMHG`. El datasource vuelve a ver todo `bulk_chunks/`. Si el job nombra otro cambio pendiente, se anota y no se revierte.
5. Parar si la razón de fallo vuelve a nombrar una de estas tres claves.

Esa operación quedó ejecutada. El resultado está en la sección 7.

## 6. Lo que no se modificó

El prefijo del VF5, `bulk_chunks/1/be7a39a3490c92c8381cb883402760cb07d1/`, no se leyó para escribir y no se restauró. La knowledge base, el datasource y su chunking siguen como estaban. No hubo despliegue. F5 sigue dependiendo del pin del VF5 y de los cuatro `POST /rag/ask`, no de este archivo.

## 7. Publicación

Lectura y escritura del 24 de octubre de 2026, con el mismo perfil `default`. STS devolvió `arn:aws:iam::935142957735:user/Lahiri`. No se imprimieron claves. No hubo reextracción, Retrieve ni generación.

### Respaldo

Antes de escribir se leyeron los dos objetos que existían. El respaldo local, fuera de git, está en `tmp/field_companion/wiring_905_page5_publish/20261024T153932Z/restore/`. Los bytes releídos coinciden con el remoto de ese momento.

| Clave | Bytes | SHA-256 | Content-Type | Metadatos de objeto |
| --- | --- | --- | --- | --- |
| `chunk_p5_1.txt` | 22548 | `c116762136452541d3df1116a810bccc6554178b95590f5817470b84d14e1d82` | `text/plain; charset=utf-8` | ninguno |
| `chunk_p5_1.txt.metadata.json` | 765 | `7717b593b7da334a18b5480453353fe42bb3aba02f95ac01161906dfaa935eb2` | `text/plain; charset=utf-8` | ninguno |

Estaban ausentes, y así quedó registrado:

- `chunk_p5_2.txt`
- `chunk_p5_2.txt.metadata.json`
- `chunk_p5_3.txt`
- `chunk_p5_3.txt.metadata.json`

El prefijo tenía 190 objetos. No había un job `STARTING`, `IN_PROGRESS` ni `STOPPING` sobre `Y7RZWMFJSR` / `PJ0N58DMHG`. El datasource seguía en el bucket `multimodal-source-destination`, con inclusión `bulk_chunks/`, `chunking_strategy` `NONE`. El modelo de embeddings seguía siendo `amazon.titan-embed-text-v2:0`. Esas dos lecturas no modificaron la configuración.

### Metadatos

El sidecar tiene once campos: `account_id`, `document_id`, `original_source_uri`, `original_filename`, `canonical_name`, `doc_sha256`, `ingestion_path`, `ingestion_contract_version`, `prompt_fingerprint_sha256`, `aliases` y `page_number`. Identifican el documento y la página 5. No hay un campo de fragmento. La clave de S3 distingue `chunk_p5_1.txt`, `chunk_p5_2.txt` y `chunk_p5_3.txt`.

Los tres sidecars son los mismos bytes, SHA-256 `7717b593b7da334a18b5480453353fe42bb3aba02f95ac01161906dfaa935eb2`. El sidecar de `chunk_p5_1.txt` no se reescribió. No se añadió ningún campo.

### Objetos publicados

| Clave | SHA-256 |
| --- | --- |
| `chunk_p5_1.txt` | `3f432d6b11ca696181d99a5adc277b751e27f8d997b924e6f92fd424909c702f` |
| `chunk_p5_2.txt` | `a852b9fd17355c4a5198579755fdcca85c4a4f591ae11079c1caa5c262049ab6` |
| `chunk_p5_3.txt` | `d7aeaabf03a7bc576652b85ad17513a74ccd9e37fbee7ffcaeab755dd7daa47f` |

Tras la sincronización, el prefijo sigue en 194 objetos y una relectura de las seis claves devuelve esos hashes. Al publicar, las otras 189 claves del prefijo conservaron etag, tamaño y fecha. El prefijo del VF5 no se escribió.

Las estimaciones locales siguen siendo 3813, 3600 y 2589 tokens. Son una escala lineal del conteo 9048 de este cuerpo, no una medición de Titan.

### Job

El primer `start_ingestion_job` no creó un job. Aurora `db-X44TTVPZA4IRPMMQUHXIBEAL64` estaba reanudándose tras una pausa automática (`ValidationException`, request `27eeacce-84c4-4153-a59c-27fcfb367753`). La lista de jobs activos no mostró uno nuevo. Los objetos quedaron como se habían publicado.

El job autorizado es el siguiente, ya con la base disponible:

| Campo | Valor |
| --- | --- |
| Job | `WICDOPPTFE` |
| Estado | `COMPLETE` |
| Escaneados | 14935 |
| Metadatos escaneados | 14935 |
| Nuevos | 2 |
| Modificados | 1 |
| Metadatos modificados | 0 |
| Borrados | 0 |
| Fallidos | 0 |
| Razones de fallo | ninguna |

El escaneado sube 2 desde los 14933 de `PTNRRF0BZJ`. Los contadores son dos documentos nuevos y uno modificado. El job no nombra la clave modificada. No hay razón de fallo con 9048 tokens ni con ninguna de las tres claves.

La admisión queda comprobada por ese job. No se hizo Retrieve ni una generación, así que esta aceptación no valida el ranking ni la lectura conversacional del plano.

### Caché

`upload_binary` invalidó en este proceso el índice de vecinos y el de definiciones del prefijo. La tienda era `SolidCache::Store` y las dos claves quedaron ausentes. Esa tienda es la de este proceso.

En el contenedor web de producción la tienda también es `SolidCache::Store`. El índice de vecinos de este prefijo no estaba cargado. `Rag::SectionNeighborExpander.invalidate!` se ejecutó ahí y una sonda escrita para comprobarlo quedó ausente. `Rag::CompanionDefinitionSource` no está en la imagen desplegada, así que ese índice no existe en ese proceso. Un objeto que ya tuviera el índice en memoria no se vacía con esta llamada.

### Veredicto

Reparación aceptada. No hizo falta restaurar.

El parser sigue sin medir el cuerpo antes de escribirlo. Ese control general queda pendiente. No se implementó aquí y no bloquea F5.

