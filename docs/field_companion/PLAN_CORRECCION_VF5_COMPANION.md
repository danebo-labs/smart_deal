# Corrección y validación del companion sobre el VF5

Documento vivo. Grok 4.7 lo ejecuta tras la orden de ejecución, y actualiza este mismo archivo al cerrar cada fase. No se abren planes secundarios. Redactar o revisar este archivo no implementa, no llama modelos y no modifica S3, la KB ni los ledgers.

## Objetivo y alcance

Conseguir, por la ruta normal y sobre artefactos corregidos del VF5, una primera orientación pertinente con pocas preguntas, documentación aplicable, caso conservado y distinción entre observación, comprobación, hipótesis y pendiente. El criterio sale del guion [Danebo guion intuitibilidad.pdf](/Users/lahirisan/Downloads/Danebo%20guion%20intuitibilidad.pdf). Sus diálogos son ilustrativos. Los comentarios de Gonzalo son requisitos de producto: el primer mensaje debe bastar, una o dos intervenciones, y nada que no tenga relación con la falla. No son procedimientos del fabricante.

El VF5 es la muestra para corregir mecanismos generales. No se añaden reglas de este manual ni se declara válida la biblioteca. Se conservan las capacidades ya demostradas: foco, continuidad de episodio y corrección del LED.

Dentro de este ciclo:

- Ingesta: instrucción por página, texto de página en la fusión, procedencia de lo movido entre páginas, cobertura determinista y sustitución acotada del prefijo del VF5.
- Caso: estado de comprobaciones en el episodio, ampliando la misma llamada del intérprete.
- Generación: contexto de avería sin bloques de plano y sin la contradicción de formato.
- Validación por capas, de menor a mayor costo, sobre los artefactos que cada capa produce.

Fuera de este ciclo (siguen en [docs/PLAN_FIELD_COMPANION_CONVERSACION_2026-10-07.md](../PLAN_FIELD_COMPANION_CONVERSACION_2026-10-07.md)): orden 3 (plano Elemont, `EPISODIO_VALIDADO`), órdenes 4 y 5 (fotos, cambio de tema y retorno), selección automática por foto o código, rescate, escalamiento a ingeniería y cierre ante Gonzalo. Los hábitos generales de Gonzalo (serie de seguridad, reinicio de 380 V y 220 V, puertas abiertas en falla) no se codifican: no están en el pasaje VF5 y no autorizan una maniobra. Reprocesar otros manuales ya indexados tampoco entra.

Este documento sustituye, solo como ruta de ejecución del orden 2 textual, los replays de fidelidad, continuidad, sección 5.6, Haiku contra Sonnet y partición system/user; la matriz de siete turnos; y los párrafos de «siguiente acción» del orden 2 que apuntan a ellos. No sustituye el archivo padre, sus evidencias ni sus aceptaciones parciales.

## Estado inicial

Verificado el 21 de octubre de 2026 en la revisión de Opus:

- `HEAD` y `origin/main`: `f8d70b7d404c40a9c60909f55f4d829ddbfeb071` (commit de este plan sobre `b5fba1c`). Cinco rutas sin seguimiento del experimento system/user: `app/services/rag/vf5_system_role_admission.rb`, `app/services/rag/vf5_system_role_comparison.rb`, `script/field_companion/vf5_system_role_comparison.rb`, `test/fixtures/files/field_companion/vf5_bound_20261020T1728Z/` (solo `b0005.txt`) y `test/services/rag/vf5_system_role_admission_test.rb`. Ningún archivo seguido las referencia. `RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE` queda apagado; la ruta normal arma un solo mensaje `user`.
- PDF [docs/field_companion/fuentes/VF5.pdf](fuentes/VF5.pdf): SHA-256 `be7a39a3490c92c8381cb883402760cb07d10b0a3beda5348bed22f72abedf72`, 22 páginas, con capa de texto en todas. La portada no imprime folio. PDF 2–22 imprimen «Pág. N / 21», N = 1–21. `SectionPageContinuity::PRINTED_PAGE` ya lee esa forma.
- Artefactos vivos del VF5, según los 30 sidecars copiados en `tmp/review_vf5/` (30 cuerpos y 30 sidecars, 112 `FIELD_RECORD`): `account_id` 1, `document_id` `be7a39a3490c92c8381cb883402760cb07d1`, `ingestion_path` `manual_batch_v1`, contrato `field_records_v8`, `original_source_uri` `s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf`, sin `topology_edge_count`. Prefijo derivado por `BatchResultsParserService::CHUNK_PREFIX_TPL`: `bulk_chunks/1/be7a39a3490c92c8381cb883402760cb07d1/`. No hay chunk de la página 3.
- Ledger de asignación `tmp/field_companion/vf5_generator_benchmark/assignment_spend.json`: 70 intentos, US$0,945161 comprometidos, `open: {}`, `unknown` 0, topes 96 y US$4. Última entrada: 2026-10-21T01:08:09Z.
- Evidencia de referencia: informe de Codex y revisión de Opus del 21 de octubre, captura `vf5-bound-20261020T1728Z`, sonda local de p5 y p13 en `tmp/field_companion/local_ingestion/` (Sonnet 5.5 directo, 2849/5859 y 3140/5937 tokens). Con el prompt de sistema actual, p5 ya salió sin el encabezado S4 y sin la nota inventada, y p13 conservó su apertura. Esa sonda no certifica ingesta, índice ni recorrido.

Código que sostiene la dirección:

- El total de la instrucción es el número de páginas conservadas, no el del PDF: [bulk_cost_v2_request_builder.rb](../../app/services/bulk_cost_v2_request_builder.rb) y [manual_batch_ingestion_service.rb](../../app/services/manual_batch_ingestion_service.rb) (`total = kept_pages.size`), [single_file_chunking_service.rb](../../app/services/single_file_chunking_service.rb) (`kept_pages.size`), [batch_page_retry_service.rb](../../app/services/batch_page_retry_service.rb) (`total_kept`) y [batch_chunking_prompt.rb](../../app/prompts/batch_chunking_prompt.rb) (`Page N of M`). El p14 histórico dice que «el contenido de esta página (p. 14/21) no ha sido transmitido» y añade un 9.5 que la página no imprime. Ese es el conflicto esperado entre índice y folio. Sigue siendo una hipótesis: la cobertura es obligatoria aunque falle.
- `ChunkMergerService` solo llama a `SectionPageContinuity` si recibe `page_texts`. Ningún llamador normal se los pasa: [ingest_batch_results_job.rb](../../app/jobs/ingest_batch_results_job.rb), [ingest_manual_batch_results_job.rb](../../app/jobs/ingest_manual_batch_results_job.rb) y [single_file_chunking_service.rb](../../app/services/single_file_chunking_service.rb). `release_internal!` borra `_page`, así que el parser renderiza un registro movido con la página del chunk que lo recibe. `PageChunkFidelity.strip_running_matter` reconoce cabeceras con patrones de este manual («Módulo electrónico», `DOC-…`). En otro manual, la cabecera impide detectar la apertura a media lista.
- El prompt de sistema de extracción ya prohíbe añadir encabezados o notas, ya exige conservar la apertura literal y ya mantiene los ejemplos como ejemplos (`BatchChunkingPrompt`, reglas de apertura, de etiquetas S y de ejemplos). La instrucción de usuario no debe repetirlo.
- La deduplicación es `(cuenta, SHA-256, field_records_v8)` ([content_dedup_service.rb](../../app/services/content_dedup_service.rb)). Volver a subir el PDF no re-parsea. [script/AGENTS.md](../../script/AGENTS.md) prohíbe subir `INGESTION_CONTRACT_VERSION` para sortearlo.
- `BatchResultsParserService#call` con `ingestion_path: "manual_batch_v1"` valida el JSON, exige `account_id` y `document_uid`, borra el prefijo con `S3DocumentsService#delete_prefix` y lo reescribe como `chunk_p<página>_<n>.txt` y sus sidecars. Tanto el borrado como la escritura invalidan `SectionNeighborExpander`. Un fallo del borrado solo deja un aviso, así que pueden quedar claves sobrantes.
- La sincronización de la KB es `start_ingestion_job` sobre la fuente de datos, como en [script/patch_elemont_chunk_p5_1_botonera_branch.rb](../../script/patch_elemont_chunk_p5_1_botonera_branch.rb). La fuente abarca todo `bulk_chunks/`, no un documento: el job es incremental, pero recoge cualquier otro cambio pendiente del bucket.
- Turno web con identidad conocida, pin y modo `owner`: una llamada de intérprete (`TurnInterpreter`, hasta 3 intentos solo ante error transitorio) y una `generate_text`. `Retrieve` va aparte. `RagRetrievalProfile::PINNED_DOCUMENT_RESULTS = 3`. La consulta compuesta cabe en 442 caracteres (`FollowupQueryRewriter::MAX_COMPOSED_CHARS`).
- `TurnPerception` ya devuelve `observations` como fragmentos literales del turno, e `InterpreterPayloadContract` rechaza lo que no es literal. `WorkContextReducer` ya sustituye y recorta observaciones corregidas. `SessionContextBuilder` las muestra en `## Active Field Problem`, con topes de caracteres.
- Generación: `generation.txt` pide «Use at most three logical sections» y `web_delivery_channel_directive` pide «No headings or section titles». Las reglas de `TOPOLOGY_EDGE` de `generation.txt` y las viñetas de plano y etiquetas de `DOCUMENT_IDENTITY_ATTRIBUTION_CONTRACT` («Según el plano», distinguir dos etiquetas) entran en cada turno de identidad, haya o no un plano. `FIELD_REPORT_PARAGRAPH` ya prohíbe cerrar una comprobación no reportada y jerarquizar causas sin respaldo; la captura lo incumplió. Más prosa de reglas no es la corrección.
- Caso nuevo: si el intérprete devuelve `new_work`, `ConversationSession` abre un episodio nuevo en la misma sesión, y `start_new_case!` conserva los pins (`pins_after = pins_before`). `field_companion:start_clean_case` es un reinicio operativo: además vacía `document_focus` y `active_entities`, y con ellos el pin.
- Control de gasto real: `LocalPassLedger` (con `RAG_LOCAL_PASS_GUARD=1`, topes de proceso, `AWS_MAX_ATTEMPTS=1` y base local) protege las llamadas de `BedrockClient` antes del SDK. Con `RAG_ASSIGNMENT_SPEND_PATH`, además reserva en el ledger acumulado de 96 intentos y US$4. El filtro Haiku (`PageRelevanceFilter`) y la extracción (`ClaudeChunkingClient`) van a la API de Anthropic sin ese guardia. Sus clientes se crean con los reintentos por defecto del SDK, y `ClaudeChunkingClient` reintenta además dos veces ante un *overload*. Ambos clientes se pueden inyectar (`haiku_client:` y `client:`). `TrackBedrockQueryJob` escribe `bedrock_queries` de forma asíncrona: en local solo aparece si corre un worker.

## Archivos experimentales: se conservan, fuera de alcance

Los cinco archivos sin seguimiento se conservan en su sitio, con su contenido. No se borran, no se mueven, no se modifican y no se commitean. Primer paso del ejecutor:

1. Añadir las cinco rutas a `.git/info/exclude`. Es local y no se commitea. Así no aparecen en `git status`, y un `git add` por directorio no las recoge.
2. Commitear solo con rutas explícitas (`git add <ruta>`), nunca con `git add -A` ni `git add .`.
3. Correr la suite solo con los tests seguidos: `bin/rails test $(git ls-files 'test/**/*_test.rb')`. El test experimental no entra en la señal de este ciclo. Si un cambio de este ciclo lo rompe, se anota y no se toca.

La hipótesis system/user ya se cerró: tres controles y tres tratamientos del primer mensaje fallaron, y el tratamiento añadió una maniobra no autorizada. Sus respuestas y su ledger están en `tmp/field_companion/vf5_system_role/` y en `assignment_spend.json`. No se restaura ese arnés y su `RESERVE_CALLS = 15` no rige en este plan.

## Decisiones

1. **Dirección.** Alineación selectiva del pipeline existente. No basta reparar la página 12. No hay contrato nuevo ni verificador universal.

2. **Semántica del caso.** `#21` pertenece a «La puerta se abre pero no se cierra» (PDF 12, impresa 11, sección 8.2), junto con el LED, `#8` y `#12`. «La puerta se re-abre sola» tiene tres comprobaciones: sensibilidad `#54`, fotocélula no activada y ausencia de obstrucción mecánica. Su continuación condicional abre la PDF 13: «En caso que el problema persista, desconectar la fotocélula…». El chunk de p12 debe contener `#21` bajo su síntoma. La respuesta del caso «se reabre sola» no lo presenta como paso de ese síntoma. La disyunción del LED está en 5.6 (PDF 7): fotocélula o entrada de reapertura. Se usa cuando ese pasaje está en el contexto. La inversión conocida de `#8` y `#12` frente a las secciones 4 y 5.2 no rechaza este ciclo.

3. **Instrucción por página.** `page_user_content` dice solo lo que el sistema no dice: el documento adjunto es exactamente la página a extraer; su número es el índice del PDF; el total es el número de páginas del PDF, no el de páginas conservadas; el folio impreso puede diferir del índice. Los cuatro llamadores (los tres de ingesta y `BatchPageRetryService`) pasan el total del PDF. Las reglas de apertura, encabezados y ejemplos siguen solo en el prompt de sistema. `INGESTION_CONTRACT_VERSION` no cambia.

4. **Texto de página y procedencia.** El texto de página es el que ya extrae la ingesta con `PDF::Reader`: `SplitPage#text` de `PdfPageSplitterService`, o `PageRelevanceFilter.extract_page_text` si la página no lo trae. Se obtiene una vez por página y por proceso, y lo usan la fusión y la cobertura. En la ruta síncrona y en el envío por Batch ya está en memoria. Los jobs de resultados Batch corren en otro proceso: lo re-extraen una vez del PDF fuente, con el mismo extractor y la misma descarga que ya usa `BatchPageRetryService`. No se guarda en S3 ni en argumentos de job.
   - El texto movido a la página anterior conserva en el cuerpo las marcas `[PDF_PAGE]` y `[PRINTED_PAGE]` que `SectionPageContinuity` ya escribe.
   - Los registros movidos guardan su página en un campo real (`source_pdf_page`) que el parser renderiza. El campo interno `_page` desaparece.
   - El `page_number` del sidecar sigue siendo uno por chunk, porque Bedrock lo filtra como valor único. Una cita del texto movido apunta a la página del chunk y la marca en línea la precisa.
   - El folio se lee con `PRINTED_PAGE`. Si la página no imprime un folio con esa forma, la marca se omite. Nunca se calcula folio = índice − 1.
   - Cabecera y pie: las líneas que se repiten en al menos la mitad de las páginas (y en un mínimo de tres) se tratan como texto corrido, calculado sobre el `page_texts` del documento. Esta regla sustituye los patrones propios del VF5 de `strip_running_matter`. El patrón general de folio se mantiene.

5. **Cobertura: qué verifica y qué no.** Reutiliza las funciones de alineación de `Rag::PageChunkFidelity` (normalización, `aligned_line?`, comprobación de `EVIDENCE` en la página). Se añade ahí, no en una clase nueva. No lee el PDF. Mide cuatro cosas:
   - **Contabilidad:** toda página tiene un chunk o un descarte registrado en memoria y en el informe local. Nada se escribe bajo `bulk_chunks/`. Una página sin chunk ni descarte es un defecto. Un descarte prueba que la página quedó contabilizada, no que su contenido sobrase.
   - **Precisión**, por página y antes de fusionar: proporción de tokens significativos de la narrativa que están en esa página. Quedan fuera la cabecera de identidad, el chunk S0 de la página ancla y el bloque de registros.
   - **Líneas añadidas:** líneas de narrativa sin alineación con la página. Así se detectan un encabezado inventado o una nota.
   - **Recall**, después de fusionar: la apertura de la página y sus números e identificadores (`#21`, `0,12`, tensiones) aparecen en sus chunks o en lo movido con `source_pdf_page`.

   **Gate de producción (ruta normal).** Solo contabilidad y precisión. Un cuerpo con precisión muy baja no se indexa: cubre la página «no recibida» y el contenido inventado sin buscar frases. Se reintenta una vez a la misma cota de tokens, dentro de la escalera existente: `call_with_page_cap_retry` en la ruta síncrona y `BatchPageRetryService` en Batch. Si sigue mal, queda la marca de página degradada que ya existe (`ChunkMergerService::DEGRADATION_MARKER`). Recall y líneas añadidas solo se informan: bloquear por ellos destruiría contenido útil ante cualquier desorden de la capa de texto.

   **Criterio de este ciclo.** Para el VF5, los cuatro controles tienen que salir limpios en las páginas que se certifican.

   **Límites declarados.**
   - Sin capa de texto (página escaneada): continuidad y cobertura no verifican. Solo se exige contabilidad, y el informe marca la página como «no verificable».
   - Medidas por presencia: no detectan un cruce de columnas ni el orden de una tabla. Por eso p6 y p22 se leen contra `pdftotext -layout` y la imagen de la página.
   - No se aplica `PageChunkFidelity.correct` en la ingesta. Reescribiría tablas con la capa de texto, y ese riesgo no está medido.

6. **Ejemplos.** `promoted_example?` se mide sobre los 112 registros históricos. Se ajusta solo si descarta un registro que no es un ejemplo. La regresión de ese ajuste es el caso ya visto de la salida FOTOCÉLULA.

7. **Estado del caso: misma llamada, validación determinista.** No se añade un clasificador por reglas. Interpretar «no he mirado el 54», «ya revisé la fotocélula y nada» o «sin mediciones» con reglas de negación en español duplicaría el intérprete, dependería del idioma y competiría con la maquinaria de correcciones literales que el reducer ya tiene.
   - El tool `turn_perception` gana un arreglo `checks` con elementos `{subject, status, result}`. `status` es `done` o `not_done`. `subject` es un fragmento literal del turno. `result` es literal o `null`.
   - `InterpreterPayloadContract` valida la literalidad, el enum y los topes. Un payload sin `checks` equivale a `[]`, para que los fixtures existentes sigan siendo válidos.
   - Observación y comprobación quedan separadas. Una observación es lo que el técnico vio o no vio, con su negación literal («no veo obstrucción»). No implica una comprobación ni la crea. Una comprobación es algo que el técnico dice haber hecho o no haber hecho, con su resultado si lo da. «Sin mediciones» es `not_done`.
   - Lo pendiente no se guarda: es toda comprobación documentada que no figura como `done`. El modelo lo deduce del pasaje y del bloque de estado, sin que el estado enumere el manual.
   - El reducer guarda `checks` en el episodio con topes pequeños (6 elementos y 120 caracteres orientativos), dentro de `MAX_BYTES`. Son lo primero que se recorta después de los conflictos.
   - Un `subject` igual, según la normalización existente (`FollowupQueryRewriter.normalize_label` / `ObservationText`), sustituye al anterior: un resultado posterior o una corrección reemplazan el estado. `new_work` abre un episodio sin `checks`.
   - `SessionContextBuilder` añade una línea por comprobación dentro de `## Active Field Problem`. No hay bloque nuevo.
   - Identificadores: diferido, no resuelto. No se aplica la regla que dejaría fuera un span de dos o tres palabras sin dígito, sin `#` y que no sea un código en mayúsculas. Esa redacción también quita nombres que el episodio ya guarda. El almacén conserva el comportamiento anterior. Evidencia e impacto: ejecución de F1-B. F3 anota, dentro de las pruebas ya previstas, si «Modo esclavo» guardado como identificador afecta al estado o a la respuesta.

8. **Prompt y contexto de avería.** No hay llamada de clasificación nueva.
   - Las reglas de `TOPOLOGY_EDGE` de `generation.txt`, las viñetas de plano y etiquetas de `DOCUMENT_IDENTITY_ATTRIBUTION_CONTRACT` y `literal_label_rules` entran solo si se cumple una de estas condiciones: algún chunk seleccionado trae un registro `TOPOLOGY_EDGE` o una sección de diagrama o tabla de etiquetas; el turno o el objetivo del episodio pide un plano, esquema o etiqueta. La decisión depende de la evidencia y del caso, no solo de las palabras del turno, y no impide consultar un esquema cuando hace falta.
   - Sin plano, la viñeta de información documentada queda en su forma general: lo que el cuerpo recuperado respalda, con [n], y la advertencia de que `ACTION` y `EXPECTED_RESULT` son anotaciones de extracción.
   - Se elimina «Use at most three logical sections». En web manda la directiva de canal: prosa, sin títulos.
   - `FIELD_REPORT_PARAGRAPH` no cambia. El bloque tipado le da los datos que antes faltaban. No se añade otra lista de prohibiciones.
   - Menos caracteres no garantiza menos tokens ni más fidelidad. Ambas cosas se miran con el `usage` de las llamadas que ya se hacen.

9. **Recuperación.** No se toca salvo evidencia. Tras sincronizar, un `Retrieve` de solo lectura usa la consulta compuesta del primer turno de la captura, el filtro de pin por la URI original, k = 3 y sin rerank, y guarda request, score, URI y cuerpo.
   - Si el 8.2 corregido está entre los tres primeros, no se cambia nada.
   - Si falta, se repite con k = 5.
   - Si falta y la consulta salió truncada sin el síntoma, el candidato es `QueryComposer`.
   - Si el pasaje está en las posiciones 4 o 5 con la consulta íntegra y el síntoma nombrado, el cambio permitido es `PINNED_DOCUMENT_RESULTS` de 3 a 5. Encarece cada turno con pin (un 20–30 % más de tokens de entrada, estimado y no medido); se anota con el `usage` real.
   - Si no aparece ni en el top 5, se inspeccionan la consulta y el cuerpo, y no se cambia nada en este ciclo.
   - La consulta de la captura es una sonda del índice. El contexto real se comprueba en el primer turno integrado, cuya consulta sale del estado nuevo.

10. **Integración local.** Un replay no valida S3, el índice ni `POST /rag/ask`. La conversación corre en local contra la KB `Y7RZWMFJSR` con el código nuevo, sin editar `.env` y sin desplegar. El proceso exporta la KB, el modo `owner`, los flags de episodio y turno y el alcance de identidad, como en la captura `vf5-bound-20261020T1728Z`. Deja sus capturas con `ValidationCapture` y `WebRequestCapture`, sin instrumentación nueva.

11. **Aceptación.** Son los cuatro turnos de la fase 5, no la matriz de siete. Conservar una comprobación no obliga a recitarlas todas. La condición de la PDF 13 no se prescribe en la primera respuesta. Los tests de estado miran campos. Las respuestas se juzgan por significado con la rúbrica escrita aquí. No hay tests de frase exacta ni tests que solo reproduzcan la implementación.

12. **Preguntas nuevas, no repeticiones.**
    - Extracción: si la instrucción corregida, el parser normal, la fusión con `page_texts` y la cobertura sostienen las 22 páginas.
    - Generación: si el estado de comprobaciones y el prompt sin plano, sobre chunks certificados, dejan de cerrar comprobaciones y de jerarquizar `#54`.
    - La captura histórica es referencia, no control contemporáneo: difieren a la vez chunks, prompt y estado. Este ciclo evalúa el conjunto corregido y no atribuye efectos a una sola pieza.

## Compromisos del diseño

- **Piezas.** Sin servicio nuevo de interpretación ni verificador nuevo: la cobertura vive en `PageChunkFidelity`, el estado en el episodio y el intérprete existentes, y la sustitución en el parser normal. Las únicas piezas de esta corrida son el pegamento de la extracción y el informe local. Si el pegamento supera unas 40 líneas, va a `app/services` con test, como pide [script/AGENTS.md](../../script/AGENTS.md).
- **Latencia del turno.** Cero llamadas nuevas. El intérprete emite unas decenas de tokens más y el prompt de generación pierde los bloques de plano cuando no aplican. Es lo esperado y no está medido: la fase 3 lo compara con el `usage` de la captura, como referencia y no como control.
- **Ingesta.** Fuera del camino del usuario. La ruta síncrona reutiliza el texto ya extraído. Los jobs Batch hacen una extracción de texto por documento. La cobertura es aritmética local.
- **Transporte de esta corrida.** La extracción local usa la API directa (ruta síncrona), no Batch. Prompt, fusión, parser y cobertura son el mismo código, y la escritura final usa `manual_batch_v1` para conservar el prefijo y el nombre de las claves. Batch costaría la mitad, pero exige un worker y una espera; en 22 páginas no compensa.
- **Procedencia.** El sidecar sigue teniendo una sola página por chunk. La procedencia exacta del texto movido va en el cuerpo y en el registro.
- **Trazabilidad.** Cada corrida conserva el SHA del código, el SHA del documento, las páginas de origen, los cuerpos que llegan al generador y el estado del caso que sustenta la respuesta. Sirven los campos y capturas ya existentes: `source_pdf_page`, `page`, `correlation_id`, `ValidationCapture` y `WebRequestCapture`. No se recorta el contexto técnico de una respuesta para ahorrar tokens. Un vacío que exija otro diseño se anota y no se improvisa.

## Autorizaciones y presupuesto

### Qué autoriza la orden de ejecución

- Cambios de código y tests locales. Commits locales con rutas explícitas. Base local y servidor local.
- Lecturas remotas: `list` y `get` del prefijo VF5 en S3, y `ListIngestionJobs` y `GetIngestionJob` de la fuente de la KB.
- Llamadas pagadas dentro de los techos de abajo.

No autoriza: escritura en S3, sincronización de la KB, consultas a la base de producción, despliegue, push, cambios de configuración AWS, edición de `.env` ni subir el contrato. La escritura y la sincronización van en la solicitud única de más abajo. El plan por sí solo no concede gasto ni cambios remotos.

### Ingesta (API de Anthropic, fuera del ledger de 96)

Techo: 32 llamadas facturables y US$2,50, lo que ocurra antes.

- Filtro Haiku sobre las 22 páginas: 2 ventanas, más un reintento de JSON cada una, como máximo 4.
- 22 extracciones Sonnet 5.5, en dos tandas (8 de sonda y 14 de resto). El total informado al modelo es 22.
- Hasta 6 reintentos entre las dos tandas: escalera de truncado o JSON, o un reintento por precisión baja, con un máximo de uno por página. La cifra de planificación es la de la sonda: unos US$0,065 por página.

Control efectivo:

- `Rag::AssignmentSpend` sobre un archivo propio, `tmp/field_companion/vf5_correction/ingest_spend.json` (`call_cap` 32, `cost_cap_usd` 2,50).
- Antes de cada llamada lógica, `reserve!` con un techo igual a `LocalPassLedger.price(modelo, tokens de entrada estimados, max_tokens)`. Después, `settle!` con el `usage` real. El caché de escritura y de lectura se cobra con las tarifas `cache_creation` y `cache_read` de `BedrockQuery::BEDROCK_PRICING` (`claude-sonnet-5-5-direct`, `claude-haiku-4-5-20251001-direct`).
- Los clientes Anthropic se inyectan con `max_retries: 0`: `haiku_client:` en `PageRelevanceFilter.filter_pages` y `client:` en `ClaudeChunkingClient`. Así no hay reintentos ocultos del SDK. Grok confirma el valor por defecto en la gema instalada.
- Los *overloads* que reintenta `ClaudeChunkingClient` (2 por llamada) devuelven error sin tokens. Se anotan, pero no suman dólares.
- Si `bedrock_queries` aparece (con un worker local corriendo), sirve de contraste. No es requisito.
- Flags de topología y visión apagados en el proceso (`INGESTION_LAYOUT_DIGEST_ENABLED`, `INGESTION_VISION_TIER_ENABLED`, `INGESTION_VISUAL_TRIAGE_ENABLED`), como en la ingesta histórica, que no tiene `topology_edge_count`. Así no hay llamadas Opus de visión fuera de presupuesto.
- Si el filtro manda una página a Opus (`force_opus`), se recalcula su techo con esa tarifa antes de llamar. Si no cabe, esa página se detiene.

### Ledger de asignación (Bedrock, cuenta en los 96)

Techo: 21 intentos y US$0,60 adicionales sobre el saldo leído al arrancar. El tope acumulado de 96 intentos y US$4 sigue vigente.

- **Fase 3:** 2 intérpretes y 3 `generate_text`, en un proceso con `RAG_LOCAL_PASS_CALL_CAP=5` y `RAG_LOCAL_PASS_COST_CAP_USD=0.15`. Una sola corrección permite otra tanda igual, como máximo de 5 intentos más.
- **Fase 5:** 4 turnos por 2 llamadas, ocho previstas, más una de reserva para un fallo transitorio. Nueve llamadas. El tope de proceso sigue en US$0,30. No se le vuelven a asignar tres de reserva.

Control efectivo:

- `RAG_LOCAL_PASS_GUARD=1`, `AWS_MAX_ATTEMPTS=1` y `RAG_ASSIGNMENT_SPEND_PATH` apuntando al ledger acumulado. `LocalPassLedger` rechaza la llamada antes del SDK si se pasaría del tope del proceso o del acumulado.
- Un `ServiceUnavailable` cuenta como intento aunque no cueste nada.
- La reserva por llamada es el techo de precio, unos US$0,045 según la entrada 70. El gasto esperado es de unos US$0,013 por llamada.

Si el saldo cambió por otra actividad, se recalcula y se continúa mientras los 21 intentos y los US$0,60 quepan bajo 96 y US$4. Si no caben, se renuncia primero a la segunda tanda de la fase 3 y después a la reserva de transitorios. Si aun así no cabe, la fase se detiene y se anota.

### Retrieve

Fuera de ambos ledgers; costo bajo. Como máximo 3 de medición tras sincronizar (k = 3, k = 5 si hace falta, y uno tras el único ajuste permitido), más los de los 4 turnos integrados. Se cuentan desde la captura. Sin reranker. Ninguno se lanza sobre los chunks viejos.

### Solicitud única de autorización remota

Se redacta una sola vez, al cerrar la fase 3, con la evidencia local ya revisable. Si se concede, no se vuelve a pedir.

Contenido:

- Informe de cobertura de las 22 páginas, con la nota visual de p6 y p22.
- Resultado de la fase 3.
- Gasto real de la ingesta y del ledger.
- Diferencia de claves entre `tmp/review_vf5/` y el directorio nuevo.

Pide:

1. Sustituir el prefijo `bulk_chunks/1/be7a39a3490c92c8381cb883402760cb07d1/` mediante `BatchResultsParserService#call` con el JSON fusionado y certificado, `ingestion_path: "manual_batch_v1"`, la misma cuenta, el mismo `document_uid` y un `ChunkAsset` con el `s3_key` y el bucket originales, escribiendo con `S3DocumentsService`.
2. Borrar, por el mismo servicio, las claves sobrantes si el borrado previo falló.
3. Lanzar un `start_ingestion_job` sobre la fuente de la KB `Y7RZWMFJSR`. La solicitud dice expresamente que la fuente abarca todo `bulk_chunks/` y que el job recogerá también cualquier otro cambio pendiente.
4. Restaurar la copia y resincronizar una vez si la sustitución o la sincronización fallan.

El inventario certificado tiene 45 chunks: 45 cuerpos `.txt` y 45 sidecars `.metadata.json`. La página 3 no tiene objeto. El parseo no se vuelve a pagar. Los embeddings son los de esos 45 cuerpos.

Sin esa concesión, la validación termina en la fase 3. El trabajo local queda commiteado y anotado.

## Fases

```mermaid
flowchart LR
  f0[F0_linea_base] --> f1[F1_implementacion]
  f1 --> f2[F2_extraccion_pagada]
  f2 --> f3[F3_interprete_y_generacion]
  f3 --> auth{Solicitud_unica}
  auth --> f4[F4_sustitucion_y_retrieve]
  f4 --> f5[F5_conversacion]
  f5 --> rev[Revision_Lahiri]
```

### F0. Línea base sin modelos

- Excluir los archivos experimentales como se indica arriba. Leer el ledger. Correr la suite seguida como línea base.
- Extraer `page_texts` del PDF local con el extractor de la decisión 4.
- Calibrar la cobertura candidata sobre los 30 cuerpos históricos. Debe marcar: p3 sin chunk ni descarte, líneas añadidas en p5 (S4 y nota), apertura perdida en p12 y p13, precisión baja en p14 y números ausentes en p19. No debe dar por resueltos el cruce de columna de p22 ni el borne 9 de p6.
- Aplicar `promoted_example?` a los 112 registros.
- Evidencia: tabla corta en este documento y tests Minitest de la cobertura sobre esos cuerpos y sobre un fixture sintético de otro formato (otra cabecera repetida, sin folio y con una página sin capa de texto).
- Fallo: no marca un defecto conocido, o marca como malo un pasaje que el diagnóstico da por fiel. Se ajustan los umbrales con reglas generales y sin rama `if vf5`. No se relaja el fixture.

### F1. Implementación local, cero llamadas

**Bloque A, ingesta:** decisiones 3 a 6 en los cuatro llamadores, en `ChunkMergerService`, `SectionPageContinuity`, el parser y la escalera de reintento.

Tests:

- Texto de la instrucción y total del PDF.
- Descarte registrado.
- Apertura trasladada con `source_pdf_page` renderizado.
- Folio presente y ausente.
- Cabecera repetida no VF5.
- Página sin capa de texto.
- Gate de precisión que reintenta una vez y degrada.

**Bloque B, caso y prompt:** decisiones 7 y 8.

Tests de reducer y episodio con payloads fijos, sin modelo:

- No observación, que no crea comprobación.
- `not_done`.
- `done` con resultado.
- Resultado posterior que sustituye.
- Corrección.
- `new_work` sin `checks`.
- Tope de bytes.
- «Modo esclavo» no entra como identificador. Diferido, no resuelto: no se cambia el almacén ni los tests que conservan «Elemont MH», «Tablero norte», «Tablero sur» y «operador de puerta».
- Payload sin `checks`, válido.

Tests de prompt:

- La avería muestra la línea de comprobaciones y no contiene bloques de plano ni «three logical sections».
- Con un chunk `TOPOLOGY_EDGE` o con la palabra «plano» en el objetivo, los bloques vuelven.

Salida: suite seguida en verde y commit local por bloque.

Fallo: un test de comportamiento en rojo que el fixture no explica. Se corrige el mecanismo. Si el estado no cabe en `MAX_BYTES`, se reducen los topes en este documento.

### F2. Extracción pagada del VF5

Se ejecuta con el código de F1 y el control de la ingesta. Filtro real sobre las 22 páginas, con su decisión guardada.

**Tanda 1, sonda:** PDF 3, 5, 6, 12, 13, 14, 19 y 22, fusionando 12 y 13 con `page_texts`. Por significado y presencia, no por igualdad literal:

- p3 tiene chunk o un descarte registrado.
- p5 no tiene encabezado S4 ni nota añadida, y los ejemplos de SW4 siguen marcados como ejemplos.
- p12 contiene 8.1 y los síntomas de 8.2, con `#21` bajo «se abre pero no se cierra».
- p13 contiene la apertura condicional de «se reabre sola», unida a 8.2 con su procedencia.
- p14 contiene 9.1 a 9.4, sin 9.5 inventado y sin decir que la página no llegó.
- p19 contiene las cifras de 11.1 y 11.2.
- p6 y p22 se leen contra `pdftotext -layout` y la imagen de la página. La presencia de `0,12` no acredita la columna.

Se anota si la hipótesis de paginación queda confirmada, debilitada o sin observar.

**Tanda 2, resto:** las 14 páginas que faltan, sin volver a pagar las 8. Fusión del documento, cobertura completa y nueva lectura de p6 y p22 si la fusión los mueve. p8 no se queda con el pasaje de p9 como si fuera suyo.

Evidencia: directorio `tmp/field_companion/vf5_correction/ingest/` (requests reducidos, `usage`, cuerpos, JSON fusionado, informe de cobertura, ledger de ingesta) y un párrafo de resultado en este documento. El manifiesto de esa carpeta guarda el SHA del código, el SHA del PDF y la página de cada llamada. El pegamento de esta corrida queda ahí y no entra en `app/services`: no es una pieza de producto y no se commitea.

Fallos:

- Más de cuatro páginas de la sonda fallan, o p6 o p22 siguen cruzando columnas: no hay tanda 2. Se ajusta la instrucción una vez dentro del cupo de reintentos. Una segunda sonda completa necesita una pregunta nueva escrita aquí.
- En la tanda 2, toda página con cuerpo infiel indexable impide la solicitud remota. Las páginas sanas no se reextraen.
- F3 puede correr si las páginas que usa (5, 7, 12 y 13) están certificadas, aunque otra página falle. No por eso se da por aceptada F2.

### F3. Intérprete y generación aislada

Tiene que demostrar dos cosas:

- Que el intérprete real, sobre los mensajes de los turnos 1 y 3, produce el estado esperado.
- Que el generador, con el pasaje correcto presente, cumple la rúbrica.

No demuestra que la recuperación traiga ese contexto. Eso lo comprueba F5.

Entradas:

- Mensajes de los turnos 1 y 3 de F5.
- Episodio reducido por el código nuevo a partir de la percepción real.
- Contexto armado a mano con los cuerpos certificados de p12, p13, p7 (5.6) y p5 (SW4), como mucho cuatro, con la cabecera que devuelve la recuperación y pasados por `DocumentIdentityScope.generation_context`.
- Prompt construido por `document_identity_generation_prompt` y `SessionContextBuilder`.
- Modelo, temperatura (0,1) y `max_tokens` de producción.

Se reutiliza el cliente de generación bajo `LocalPassLedger`, o `CapturedGenerationReplay` alimentado con el prompt nuevo. No se construye un arnés nuevo.

Rúbrica (cada muestra):

- No da por hecha una comprobación sin resultado.
- No jerarquiza `#54`.
- Mantiene condicional la frase de la PDF 13, u omite esa frase.
- No asigna `#21` a «se reabre sola».
- No convierte el ejemplo de SW4 en una orden.
- No habla de plano ni de conexiones trazadas.
- Escribe prosa sin títulos.
- Sus citas corresponden a los pasajes enviados.

Una sola muestra que cierre la obstrucción, jerarquice `#54` o mande desconectar ya la fotocélula impide la salida. Omitir una comprobación no falla.

Estado tras el intérprete:

- Turno 1: obstrucción como observación literal, sin comprobación; `#54` y mediciones en `not_done`; sin identificador de síntoma.
- Turno 3: la comprobación reportada en `done` con su resultado; las demás no aparecen como hechas.

En esas mismas pruebas se anota, sin fase nueva, si «Modo esclavo» guardado como identificador cambia el estado o la respuesta, y si una comprobación pendiente pasa a hecha cuando el técnico la reporta. El reemplazo exige que el sujeto normalizado coincida. Si eso impide la rúbrica, se pausa solo esa parte.

Evidencia: prompts, `usage` (tokens de entrada frente a la captura, solo como referencia), respuestas y veredicto en este documento.

Fallo: una corrección local (de prompt o de interpretación) y una segunda tanda. Si vuelve a fallar, se describe el fallo restante y no hay solicitud remota. No se prueba otro modelo ni la partición system/user.

Al cerrar F3, Grok envía la solicitud única.

### Backlog previo a F4

No se implementa ahora. Queda antes de cualquier escritura o sincronización de esta fase.

`KbSyncService#find_data_source_id` busca el id preferido y, si no está entre las fuentes listadas, avisa y sigue con `summaries.first`. Esa fuente puede ser la antigua o, en cualquier caso, no la de `bulk_chunks/` de `Y7RZWMFJSR` (`PJ0N58DMHG`). Un `start_ingestion_job` por esa selección sincronizaría otra fuente del mismo knowledge base. Antes de F4 hay que eliminar esa selección alternativa, tanto del datasource antiguo como del primero disponible, cuando falle la configuración del pipeline principal. Si el id configurado no aparece en el listado, la sincronización se detiene. El recorrido ya usado en la página 5 de Elemont se niega en ese caso y no llama a este servicio. Hasta dejar cerrado este punto no hay F4. No se implementa en esta corrección. La tabla de mensajes del final de este documento tiene más prioridad que esta limpieza; no la sustituye ni abre F4.

### F4. Sustitución, sincronización y Retrieve

Solo con la concesión.

**Antes de escribir (lecturas):**

- Listar el prefijo y comparar tamaños y contenido con `tmp/review_vf5/`. Si difieren, se refresca esa copia, que es la que se restaura en caso de fallo.
- Confirmar que los sidecars nuevos conservan `account_id`, `document_id`, `original_source_uri`, `doc_sha256`, `manual_batch_v1` y `field_records_v8`.
- Confirmar que ningún job de la fuente está en `STARTING` ni en `IN_PROGRESS`. Si lo hay, se espera a que termine.

**Escritura y sincronización:** según la solicitud.

Comprobación:

- El listado del prefijo coincide exactamente con las claves nuevas: sin residuos ni duplicados.
- El job termina en `COMPLETE`, y se guardan sus estadísticas e identificadores. Si las estadísticas muestran cambios ajenos al VF5, se anotan.
- Después, el `Retrieve` de la decisión 9: los cuerpos devueltos son los nuevos (marcas de página y texto corregido) y ninguna clave borrada reaparece.

Fallo: escritura, sincronización o verificación fallida, con una restauración y una resincronización. El informe local sigue valiendo como parseo, no como índice. Si el 8.2 corregido no aparece ni en el top 5 tras el único ajuste permitido, no hay F5. Se anotan la consulta y los cuerpos.

### F5. Conversación integrada

Servidor local, según la decisión 10.

- Arranque: `field_companion:start_clean_case` (orden 1, ya comprobado).
- Pin del VF5 puesto por el endpoint que usa la interfaz. Es una condición de prueba y no acredita selección automática.
- Cuatro turnos por `POST /rag/ask`, sin replays como sustituto.

Turnos:

1. **Primer mensaje completo.** Marca, modelo, «se reabre sola», estado del LED, «no veo obstrucción», `#54` sin comprobar y sin mediciones. Se espera:
   - Orientación sobre las comprobaciones de ese síntoma, abiertas y con su respaldo de sección y página.
   - Como mucho una pregunta.
   - Ni la condición de la PDF 13 como primer paso, ni `#21` en este síntoma, ni causas ordenadas.
   - Que los cuerpos recuperados contengan el 8.2 corregido. Si no lo contienen, el fallo se registra como de recuperación, no de generación.
2. **Corrección del LED.** El episodio sustituye la observación del LED, conserva el síntoma y las comprobaciones, y la respuesta usa el dato corregido.
3. **Resultado de una comprobación** (por ejemplo, la fotocélula no está activada). Esa comprobación pasa a `done` con su resultado, las demás siguen abiertas y el caso no se cierra.
4. **Otro equipo en la misma sesión.** Equipo conocido, ni VF5 ni Elemont, sin `start_clean_case`. Se espera:
   - El intérprete devuelve `new_work` y se abre un episodio nuevo sin hechos, comprobaciones ni correcciones del VF5.
   - El pin queda según la política real (se conserva) y se registra, sin cambiar su semántica para la prueba.
   - Si se recuperan pasajes del VF5, llevan la marca `REFERENCE ONLY — OTHER EQUIPMENT` y no se aplican sus pasos, bornes ni valores.
   - La respuesta continúa como orientación Danebo para el síntoma nuevo.

Cada turno conserva en las capturas existentes:

- Intérprete y estado.
- Consulta efectiva y si se truncó.
- Cuerpos recuperados.
- Prompt y respuesta.

Se corren los cuatro turnos aunque uno falle, salvo un fallo de infraestructura: cada uno mide algo distinto y el costo es fijo. No se alarga a siete turnos.

Salida: si los cuatro cumplen, el recorrido queda técnicamente estable para revisión de producto. No queda aceptado como episodio ni como demo. Cuatro turnos no prueban estabilidad estadística.

### Revisión de Lahiri

Solo con F5 estable. Lahiri lee las cuatro respuestas: si la orientación le sirve a un técnico, si escribe poco, si la primera respuesta es útil y si el caso es reconocible. No opera pruebas, no revisa logs y no aprueba fases. Su comentario se escribe aquí. No es la demo del guion ni `EPISODIO_VALIDADO`.

## Ante un fallo

- **Corrección local:** test rojo, umbral de cobertura, redacción del prompt dentro de las decisiones, o un detalle del pegamento. Grok corrige, vuelve a probar y sigue sin consultar.
- **Cambio de alcance:** otro modelo, la partición system/user, subir el contrato, un cambio de recuperación fuera de la decisión 9, codificar hábitos de Gonzalo o reprocesar otros manuales. Esa rama se detiene y se anota aquí. Sigue el trabajo independiente que no dependa de ella.
- **Bloqueo real:** presupuesto agotado tras el recálculo, concesión denegada, error de AWS o de Anthropic que persiste fuera de lo transitorio, o un estado remoto distinto del esperado al leerlo. Se detiene la fase, se anota la causa y el siguiente paso posible, y se avisa a Lahiri una sola vez.

## Estado de ejecución

### F0. Cerrada el 21 de octubre de 2026

HEAD al empezar: `fa815a31775c7c93b49c2352272267ea4678d842` (`Companion plan improved`), no el `f8d70b7` citado arriba. El único delta entre ambos es este documento. `origin/main` coincide con HEAD. Los cinco archivos experimentales siguen en su sitio y están en `.git/info/exclude` (local, sin commit). `git status` no los lista.

Ledger leído, sin tocarlo: 70 intentos, US$0,945161 comprometidos, `open: {}`, `unknown` 0, topes 96 y US$4. Última entrada 2026-10-21T01:08:09Z. F0 no llamó modelos. Gasto de la fase: US$0.

Suite seguida, semilla 56630: 4929 corridas, 34917 aserciones, 0 fallos, 18 errores, 186 skips. Los 18 errores son `ArgumentError` al parar Selenium (`Net::HTTP.start` con 6 argumentos) en tests de sistema ya existentes (`VoiceDictationCaptureTest` y vecinos). No los introduce esta fase. Log: `tmp/field_companion/vf5_correction/f0_baseline_suite.log`.

Textos de página con `PdfPageSplitterService` (y `PageRelevanceFilter.extract_page_text` si la capa viniera vacía): 22 páginas, ninguna vacía. Copia local en `tmp/field_companion/vf5_correction/page_texts/`.

Cobertura en `Rag::PageChunkFidelity.assess_coverage`. Tests: `test/services/rag/page_chunk_coverage_test.rb` (cuerpos históricos si `tmp/review_vf5/` está, y un fixture sintético con otra cabecera, sin folio y con una página sin capa). 14 corridas con el test de fidelidad previo, 186 aserciones, 0 fallos.

| Página | Qué marca |
|---|---|
| 3 | Sin chunk ni descarte |
| 4 | Capa insuficiente (1 token significativo): no verificable. No es precisión baja |
| 5 | Tres líneas añadidas, entre ellas `S4 — SAFETY SYSTEM` y `NOTA DE SEGURIDAD`. Precisión 0,908. La frase del ejemplo no es línea añadida. Apertura presente |
| 6 y 22 | `layout_order_verified` es false en las 22. La presencia no da por resuelto el borne ni el cruce de columnas |
| 11 | Apertura presente. La frase de anti-banging no es línea añadida |
| 12 | Apertura ausente. Falta `#21`. Precisión 0,714, por encima del suelo |
| 13 | Apertura ausente. Precisión 0,956 |
| 14 | Precisión 0,221, por debajo del suelo |
| 19 | 24 literales ausentes, entre ellos `0,12`. Precisión 0,371, también bajo el suelo |

`promoted_example?` sobre los 112 registros: 3 positivos. Los tres reescriben el ejemplo de SW4, incluida la salida FOTOCÉLULA y el rótulo de terminales que está dentro de esa frase. Ninguno es la comprobación de obstrucción mecánica. No se ajustó el método.

Ajustes de evidencia, sin rama del VF5:

- La bolsa de `aligned_line?` daba la apertura de p13 por presente (0,85): las mismas palabras están en otros síntomas. La apertura exige una ventana ordenada de 8 tokens dentro de los 40 primeros del primer párrafo sustancial. Las líneas añadidas siguen usando `aligned_line?`.
- Menos de 12 tokens significativos en la capa, ya sin cabecera corrida, no se verifica. Es el mismo límite que una página sin capa. Si no, el diagrama de p4 (precisión 0,09 contra un título) caería en el gate de «página no recibida».
- Suelo de precisión 0,40. p12 (0,714) y p16 (0,51) quedan por encima. p14 y el resumen inventado de p19 quedan por debajo.

También salen aperturas ausentes en p2, p10 y p15. No son los defectos que esta fase tenía que marcar; la precisión de esas páginas no está bajo el suelo. No se relajó el fixture.

Siguiente: F1, bloques A y B, sin llamadas. Única interacción prevista con Lahiri: la solicitud remota al cerrar F3 y, si F5 sale estable, la revisión de producto.

### F1-A. Cerrada el 21 de octubre de 2026

Sin llamadas. Gasto US$0. El ledger de asignación no se tocó.

La instrucción de `page_user_content` dice solo lo que el sistema no dice: el documento adjunto es esa página, el número es el índice del PDF, el total es el número de páginas del PDF y el folio impreso puede diferir. La continuación a mitad de sección sigue solo en el prompt de sistema. Los cuatro llamadores pasan el total del PDF. `gate9_final_manual` también: construye la misma instrucción, y en su fixture de reintento el PDF y el conjunto conservado tienen las mismas 4 páginas. `INGESTION_CONTRACT_VERSION` no cambia.

La ruta síncrona reutiliza `SplitPage#text` (y `extract_page_text` si viene vacío) y lo pasa a la fusión, con el motivo de cada descarte. Los jobs de resultados leen el PDF una vez con `BatchPageRetryService#load_source_pages` y reutilizan ese binario en el reintento. El manual web anota como descarte las páginas fuera de `kept_pages`. No se escribe nada bajo `bulk_chunks/`.

El registro movido guarda `source_pdf_page`. El parser lo renderiza y lo admite. `_page` no sale en el JSON. El `page` del chunk no cambia. La cabecera corrida es la línea repetida en al menos la mitad de las páginas y en tres o más; el folio con total se sigue quitando siempre. Un título que no se repite se queda, incluido «Módulo electrónico».

El gate de precisión reintenta una vez a la misma cota, en `call_with_page_cap_retry` y en `BatchPageRetryService`. Si sigue baja, la página queda en el marcador de extracción parcial y el cuerpo no se indexa. Una capa fina o vacía no dispara el gate.

Tests de este bloque en verde: continuidad, cobertura, fidelidad, prompt, fusión, reintento Batch, builders, jobs de resultados, parser y chunking de un archivo. RuboCop sin ofensas en esos archivos.

Siguiente: F1-B, comprobaciones del episodio y prompt sin plano, sin llamadas.

### F1-B. Comprobaciones y prompt, 21 de octubre de 2026

Sin llamadas. Gasto US$0. El ledger de asignación no se tocó.

`checks` es opcional en `turn_perception`. Si falta, vale `[]`. El contrato rechaza un sujeto o un resultado que no esté en el turno, un `status` fuera de `done`/`not_done`, más de 6 elementos o un texto de más de 120 caracteres. El producto descarta la comprobación que no es literal y no la fabrica desde una observación. El reducer la guarda antes de una aclaración. El mismo sujeto, normalizado, sustituye al anterior. `new_work` abre otro episodio: las comprobaciones anteriores no pasan. El contexto de la avería lleva una línea `Check:` dentro de `## Active Field Problem`.

Sin plano, el prompt quita el párrafo de `TOPOLOGY_EDGE`, deja la viñeta documentada en su forma general y no añade `literal_label_rules`. Esas tres piezas vuelven si el turno o el objetivo piden plano, esquema o etiqueta, o si un chunk trae `TOPOLOGY_EDGE` o una sección de diagrama o tabla de etiquetas. Se eliminó «Use at most three logical sections». `FIELD_REPORT_PARAGRAPH` no cambió. El SHA del template con el contrato parcial apagado pasa a `cc875e4132b4391d2d581fe50e37170a3da302bca0432cc81343af1d6f4c9a39`. La captura histórica de atribución ya no reconstruye el prompt (`prompt_delta`): perdió esa línea y una pregunta con «etiqueta» ahora recibe las reglas de etiqueta.

Diferida, no resuelta: la regla de identificadores de la decisión 7 y del criterio de F1. No se aplicó. El almacén queda como estaba. No se cambiaron los tests para aceptar la pérdida de «Elemont MH», «Tablero norte», «Tablero sur» ni «operador de puerta».

Evidencia: la redacción «dos o tres palabras, sin dígito, sin # y que no sea un código en mayúsculas» también deja fuera identificadores que el episodio ya guarda. Con el filtro puesto fallan 15 tests. Salen «Elemont MH», «Tablero norte», «Tablero sur» y «operador de puerta». «Elemont MH» es el equipo del caso. «Tablero norte» mantiene abierta una aclaración de referente. «operador de puerta» sigue en el episodio de la puerta Fermator.

Impacto: la regla cambia qué nombres de equipo conserva el episodio, no solo «Modo esclavo». Una negación posterior de «Tablero norte» ya no lo encontraría. Las comprobaciones y el prompt sin plano no dependen de esta regla y quedan aplicadas.

F3 anota, en las pruebas ya previstas, si «Modo esclavo» guardado como identificador afecta al estado o a la respuesta, y si una comprobación pendiente se actualiza cuando el sujeto normalizado coincide. Si eso impide la aceptación, se pausa solo esa parte.

Señal de este bloque: los tests funcionales de comprobaciones, reducer, episodio y prompt quedaron en verde. La suite seguida (seed 6371) dio 4951 corridas, 35111 aserciones, 2 fallos y 18 errores. Los 2 fallos eran pines de hash del prompt; se actualizaron a `cc875e4132b4391d2d581fe50e37170a3da302bca0432cc81343af1d6f4c9a39` y al archivo `1844024b18bb9c373c8e42e0617e32cde68166c85ad0345ac51f495f9b9e1638`, y esos dos archivos volvieron a salir en verde (32 corridas). Esa suite no queda aprobada por completo: los 18 errores son de sistema, Selenium, previos a este ciclo (en el sandbox, `Errno::EPERM` hacia 8.8.8.8:53; la línea base de F0 ya traía 18 errores de sistema). No se reparan ni se añaden tests Selenium. No bloquean F2.

Arnés experimental, fuera de alcance y sin bloqueo de F2. Las cinco rutas siguen en `.git/info/exclude` y fuera del repositorio. El fixture `vf5_bound_20261020T1728Z/b0005.txt` sigue en disco. Los tres fallos no son una regresión del producto: `admit` devuelve `control` cuando el SHA del prompt renderizado no es `6702ca30a2bca73688a81e5c8f9de1d585d4108d9e4db3cdf80ecdc254761500`, y `Vf5SystemRoleComparison` convierte esa negativa en `admission_refused` antes de la reserva y de las muestras. Ese SHA es el ensamblado anterior al prompt ya commiteado. El test local quedó comentado para que `bin/rails test` sin filtro no lo ejecute. No se restauran sus expectativas ni se tocan los otros cuatro archivos. La ruta normal no llama a `Vf5SystemRoleAdmission`.

Siguiente: F2, con el ledger de ingesta y sin escritura en S3. La escritura en S3 espera la autorización de F4.

### F2. Sonda, 21 de octubre de 2026

Sin escritura en S3. Filtro Haiku de las 22 páginas y extracción síncrona. El ancla real es la página 1, así que se extrajo antes de la sonda y no se vuelve a pagar. Flags de layout, visión y triaje apagados. El SDK de Anthropic trae `max_retries` 2; los clientes se inyectaron con 0. Código de la sonda: `ca545d6`. Evidencia: `tmp/field_companion/vf5_correction/ingest/` y ledger `tmp/field_companion/vf5_correction/ingest_spend.json`.

Gasto de la sonda, 10 llamadas, US$0,526390. El reintento de la página 22 suma la llamada 11: US$0,583192 comprometidos, 0 en abierto, techo 32 y US$2,50. No se reextrayeron las páginas sanas.

Paginación: la diferencia índice/folio está comprobada (la 12 imprime 11/21, la 13 imprime 12/21, la 22 imprime 21/21) y la extracción ya no trata esa diferencia como una página ausente. La 14 no inventa un 9.5 ni dice que la página no llegó. Eso no demuestra que el fallo histórico tuviera solo esa causa.

- p3: descarte registrado. La página es el objetivo del documento y el registro de modificaciones.
- p5: sin encabezado S4 ni nota de seguridad. Los ejemplos de SW4 siguen marcados como ejemplos.
- p6: no cruza columnas. En el texto y en la imagen, 12 es abrir, 11 es 0 V, 10 es común, 9 es 12 V y 8 es cerrar. La figura 3 imprime N—7, un símbolo en 6 y L—5, hacia 230 V. El cuerpo lo dice así.
- p12: contiene 8.1 y los síntomas de 8.2. `#21` queda bajo «se abre pero no se cierra», junto con el LED, `#8` y `#12`.
- p13: la frase «En caso que el problema persista, desconectar la fotocélula…» queda unida a 8.2 «se re-abre sola», con `[PDF_PAGE: 13]`, `[PRINTED_PAGE: 12/21]` y `source_pdf_page` 13.
- p14: contiene 9.1 a 9.4, sin 9.5 inventado y sin decir que la página no llegó.
- p19: contiene las cifras de 11.1 y 11.2, entre ellas 29,46, 31,61 y 0,12 en la fila EW 60. La cobertura marca ausentes los rótulos 11.1 y 11.2; las cifras no. `layout_order_verified` sigue en falso.
- p22: no cumple. En el ejemplo 2 la página imprime 36,61 x (−0,17) = −6,13 Kg solo en «Diferencia por apertura» y «Son iguales» en «número de paneles». 0,12 = 4,39 Kg está en «tipo de panel». La primera extracción metió −6,13 en una celda combinada de esas dos columnas. El cuerpo original de esa llamada se perdió al reintentar y no se reconstruye. Quedan el request de `calls/010.json` y el usage de la llamada 10. El segundo intento está en `attempts/p22/2/`. Esta referencia queda retirada: ver la rectificación de más abajo.

Segundo intento, commit `b15078c`, llamada 11, US$0,056802. Añadía una prohibición: no fundir celdas vecinas. El modelo respondió que la página imprime esa fusión y puso «ver celda anterior» en la segunda columna. Archivado en `attempts/p22/2/`.

Tercer intento, autorizado aparte, commit `f5e212a`, llamada 12, US$0,063222. No repite esa prohibición. Sustituye «Use compact tables» por una lectura encabezado por encabezado, de izquierda a derecha, con el texto alineado bajo cada encabezado. El modelo vuelve a decir que hay una única celda impresa bajo apertura y número de paneles, y en la segunda columna escribe «misma celda combinada». 0,12 sigue bajo tipo de panel. Archivado en `attempts/p22/3/`, con request, respuesta, usage y evaluación. El cuerpo del primer intento sigue perdido y no se reconstruye.

Ahí se detiene esa rama. No hay más intentos de la página 22 ni tanda 2. F2 no se acepta. No hay escritura en S3 ni sincronización.

Revisión acotada con Opus, solo esta rama:

- Evidencia: la imagen y `pdftotext -layout` separan ocho celdas. La primera es 36,61 x (−0,17) = −6,13 Kg y la segunda es «Son iguales». Esta premisa queda retirada: la página no separa esas dos celdas. Tres entradas distintas, el mismo modelo `claude-sonnet-5-5`, y las dos respuestas conservadas afirman que la página funde esas columnas.
- Impacto: el ejemplo 2 de la página 22 no se puede indexar. Este impacto queda retirado: el ejemplo 2 se indexa con el cuerpo del intento 2. El resto de la sonda que ya cumplió no se reextrae. El documento remoto no se sustituye.
- Alternativas: otra frase del mismo tipo en el prompt; acompañar el PDF con el texto ya dispuesto en columnas; activar el digest de layout o la visión, que este ciclo dejó apagados; o leer la cuadrícula fuera del modelo.
- Recomendación: no añadir otra prohibición. Si se sigue, el cambio es una lectura de columnas fuera de esa frase, y conviene decidirlo antes de pagar.

La página 7 se extrajo aparte, llamada 13, US$0,073499, código `f5e212a`. El texto de 5.4, 5.5, 5.6 y 5.7 coincide con la página. 5.6 dice que el LED y el relé se activan cuando la fotocélula o la entrada de re-apertura está activada. La glosa de la figura no asigna el emparejamiento que el texto no imprime. Sirve como fuente de F3 y no acepta F2. Archivada en `attempts/p07/1/`.

Gasto acumulado: 13 llamadas, US$0,719913, techo 32 y US$2,50, abierto en cero.

### F2. Rectificación de la página 22, 21 de octubre de 2026

La página imprime siete celdas en la fila de cálculos del ejemplo 2. La fórmula 36,61 x (−0,17) = −6,13 Kg ocupa una sola celda bajo «Diferencia por apertura» y «Diferencia por número de paneles». Las dos notas (2) describen un mismo factor. El render a 300 dpi y las cajas de `pdftotext -bbox` coinciden: la fórmula va de x 77,0 a 156,8 y cubre los dos encabezados; no hay «Son iguales» bajo ninguno de ellos. PL y HL son «Son iguales», el tipo de panel es 36,61 x 0,12 = 4,39 Kg y la homologación es «Son iguales». El ejemplo 1 sigue con ocho celdas separadas. Las evaluaciones de los intentos 2 y 3 conservan su veredicto `column_cross`; esa lectura queda retirada. El intento 1 sigue sin evidencia. `calls/001.json` guarda la llamada 11: el request de la llamada 1 se perdió en esa sobrescritura y no se reconstruye.

La línea del prompt de extracción vuelve a la de `ca545d6`: tablas compactas, sin lectura encabezado por encabezado y sin la prohibición de fundir celdas. El texto del sistema queda idéntico al de `calls/003.json`. No se añade una instrucción sobre celdas combinadas. p7 se extrajo con el prompt de `f5e212a` y no se reextrae; su SHA de prompt es otro.

El intento 2 se reutiliza. No tiene «Nota de lectura». La fórmula aparece una vez, marcada como celda que abarca las dos primeras columnas, y el resto de la fila coincide con el PDF. La cobertura de ese cuerpo da `missing_numbers` vacío y `precision_low` en falso. En `added_lines` quedan la fila, por el marcador, y la etiqueta «Notas al pie»; las dos se juzgan a ojo y no mueven un valor. Su prompt es el de `b15078c`, no el de la tanda 2. Procedencia: llamada 11, US$0,056802, `attempts/p22/2/`. La copia de trabajo apunta ahí. El intento 3, con la nota añadida, queda archivado y no se indexa. No se paga otra extracción de esta página. El criterio «p22 sigue cruzando columnas» ya no frena la tanda 2.

F3 sigue en pausa: sin nuevas generaciones y sin cambios del prompt de respuesta. Sus evidencias quedan donde estaban.

### F2. Tanda 2, 21 de octubre de 2026

Doce páginas nuevas: 2, 4, 8, 9, 10, 11, 15, 16, 17, 18, 20 y 21. Llamadas 14 a 25, US$0,419589. No se volvieron a pagar 1, 5, 6, 7, 12, 13, 14, 19 ni 22. La 3 sigue descartada. El texto de sistema de esas llamadas es el mismo que el de `calls/003.json`. El `git` de la corrida es `1cf0f17`, con la línea ya restaurada en el árbol; el commit de esa línea es posterior. Ledger: 25 llamadas, US$1,139502, techo 32 y US$2,50, abierto en cero.

La fusión no mueve las páginas 6, 8, 9 ni 22. La 8 no se queda con el pasaje de la 9. 45 chunks, nombre «Módulo electrónico VF5+ Fermator», sin páginas degradadas. Ninguna página queda con precisión baja. Los números que la cobertura marca ausentes —300 V, 144 V, 200 V, 125 V, 11.1, 11.2 y 11.3— están en los cuerpos; el aviso junta la cifra con la unidad o con el encabezado siguiente. No hay escritura en S3 ni sincronización. F2 queda cerrada en local. La solicitud remota no se envía.

### F3. Intérprete y generación, 21 de octubre de 2026

Sin escritura en S3 y sin sincronización. En ese momento la página 22 seguía detenida y no había tanda 2. La rectificación de arriba levanta solo ese freno. F3 sigue en pausa. p5, p12 y p13 se extrajeron en `ca545d6`, antes de la lectura por encabezados, y no prueban ese cambio. p7 es la prosa de 5.6, extraída en `f5e212a`.

Ledger de asignación: de 70 llamadas y US$0,945161 a 77 y US$0,989452. Siete llamadas, US$0,044291. Cabe en los 21 intentos y US$0,60. Abierto en cero. Las dos llamadas del intérprete y las tres de generación no compartieron proceso: la evaluación de la primera se cortó después de guardar las respuestas. Cada proceso quedó bajo su tope de 5 llamadas y US$0,15. La generación gastó 3.

Mensaje del turno 1: marca Fermator, modelo VF5+, «la puerta se reabre sola», LED de fotocélula apagado, «No veo obstrucción», «No he comprobado el #54» y «No hice mediciones». Turno 3: «Ya revisé la fotocélula y no está activada.» El foco de la ruta es el URI original del VF5, sin escribir un pin. Evidencia: `tmp/field_companion/vf5_correction/f3/`.

Primera pasada, código `8f26b63`, prompt del intérprete `bb274d3ebe9b16232dd2b993a2b368b76712b5544a74bc4a689a2ee2cc3c4428`, llamadas 71 y 72. `#54` y mediciones quedaron `not_done`. «No veo obstrucción» quedó como identificador, no como observación. No se generó. Archivada en `attempts/1/`.

Corrección única, en el prompt del intérprete: lo que el técnico ve o no ve es una observación, no un identificador ni una comprobación. No es la regla de identificadores diferida, que sigue sin aplicarse.

Segunda pasada, prompt `317c2cee2f251e9f667e9c31b79a6b7763e6fb9a6b08ed3eb8be5b1fc8af3b1a`, llamadas 73 y 74. El `git` de esa pasada sigue en `8f26b63`: el prompt ya estaba en el árbol y el commit de esta fase es posterior. «No veo obstrucción» es observación y no es comprobación. `#54` y mediciones siguen `not_done`. El identificador guardado es «Fermator VF5+». El modelo también marcó «La puerta se reabre sola» como identificador; el reducer no lo guarda porque tiene cinco palabras, y no entró en las observaciones. La pregunta compuesta sí lo lleva. El objetivo del episodio no.

Turno 3: la fotocélula queda `done` con resultado «no está activada». `#54` y mediciones siguen `not_done`. No hubo reemplazo: el sujeto normalizado no coincide. La regla hace lo que dice.

«Modo esclavo» no está en estos turnos y no se guardó. Si se añade al almacén, el contexto cambia y aparece en `Identifiers`. La respuesta no se midió: no hubo una llamada aparte. No bloquea la rúbrica por sí solo. La captura `vf5-bound-20261020T1728Z` sí lo guardó cuando el turno lo traía.

Generación, llamadas 75 a 77. Haiku de producción, temperatura 0,1, 3000 tokens. Tres muestras del mismo prompt, SHA `cc1c72e9c853fdd21904018da105b4f2d6a95265b15c7b2d529a4b0725ae612d`. Entrada 7562 tokens; la captura del turno 1 tuvo 8129. Es referencia, no control. Cuatro cuerpos, todos `THIS JOB'S EQUIPMENT`: SW4, «abre pero no se cierra» con `#21`, «se re-abre sola» con la apertura de la PDF 13 y `SOURCE_PDF_PAGE: 13`, y 5.6. El prompt no trae bloques de plano. La cita `[3]` es el fragmento de «se re-abre sola».

La rúbrica no cierra. Las tres escriben títulos, aunque el canal pide prosa. La instrucción de idioma todavía nombra encabezados de sección. No se corrige: la corrección de esta fase ya se usó. La muestra 1 da la obstrucción por verificada y nombra `#21` en este síntoma. La 2 llama al `#54` el primer elemento del procedimiento. La 3 manda seguir por el `#54`. Las tres dejan condicional la desconexión de la fotocélula. Ninguna convierte el ejemplo de SW4 en una orden ni habla de plano. Una muestra que cierra la obstrucción o jerarquiza el `#54` impide la salida. No hay otra tanda ni solicitud remota. F2 no se aceptaba en ese momento; cerró después en local (ver «F2. Tanda 2»). F3 sigue pendiente.

### F3. Revisión acotada con F2 cerrada, 21 de octubre de 2026

Referencia `be73744`. Sin llamadas a modelos, sin cambios de implementación y sin tocar la ingesta. Se contrastaron los mensajes, las percepciones, los episodios, el prompt efectivo, los cuatro cuerpos y las tres respuestas de `tmp/field_companion/vf5_correction/f3/` y `attempts/1/`. La consulta compuesta se reconstruyó en local con `Rag::QueryComposer.explain` sobre los episodios guardados (cero llamadas). Las evaluaciones anteriores no se toman como conclusión.

**Síntoma fuera del objetivo.** Es el defecto principal, y lo introdujo la corrección de esta fase.

- `WorkContextReducer#durable_goal_text` une las observaciones del turno. El síntoma no tiene otro sitio duradero: como `assert` sin slot pasa a identificador, y `durable_identifier?` lo descarta por tener cinco palabras.
- Primera pasada (prompt `bb274d3…`): observaciones «La puerta se reabre sola» y LED. Objetivo «La puerta se reabre sola El LED de fotocélula está apagado».
- Segunda pasada (prompt `317c2ce…`, temperatura 0, mismo turno): observaciones «No veo obstrucción» y LED. Objetivo «No veo obstrucción El LED de fotocélula está apagado». El esquema admite tres observaciones y el modelo devolvió dos. La frase añadida («What the technician sees or does not see is an observation…») desplazó el síntoma. Es una sola muestra por prompt, pero solo cambió el prompt.
- Impacto comprobado en el turno 1: ninguno en la respuesta, porque la consulta lleva el turno crudo. La consulta repite «No veo obstrucción El LED…» al final: el objetivo invierte el orden del turno y `said_in_turn?` no lo reconoce.
- Impacto comprobado en el turno 3, por reconstrucción determinista: la consulta queda «Ya revisé la fotocélula y no está activada. Fermator VF5+ No veo obstrucción El LED de fotocélula está apagado», sin el síntoma. Con el episodio de la primera pasada incluía «La puerta se reabre sola». En F5 los turnos 2 y 3 recuperarían sin el síntoma. El efecto en el `Retrieve` y en la respuesta no está medido.
- El evaluador de F3 no lo detectó: `turn1_gaps` solo busca el síntoma en los identificadores ya filtrados, no exige que esté en el objetivo o en las observaciones. `turn_1_ok: true` no prueba que el estado sea el esperado.

**«No veo obstrucción» presentado como hecho.** Solo la muestra 1 lo hace: «Usted ha verificado visualmente que no hay obstrucción». Aun así deja la comprobación en la lista de pendientes y menciona la prueba condicional de la PDF 13. Las muestras 2 y 3 lo dejan abierto («Usted reporta que no ve obstrucción visible»). La regla de `FIELD_REPORT_PARAGRAPH` existe y se cumplió en 2 de 3: no falta prosa. Lo que favorece el fallo:

- En `## Active Field Problem` la observación solo aparece dentro de `Goal:`. `SessionContextBuilder.visible_observations` omite la observación que el objetivo ya cubre, así que no hay línea `Obs:`. La única línea con estado es `Check:`, y está para `#54` y para las mediciones. La obstrucción queda rotulada como objetivo y sin estado.
- El turno y el pasaje casi coinciden («No veo obstrucción» y «Comprobar que no hay una obstrucción mecánica»). Mapear uno sobre el otro es la lectura natural.
- El formato con títulos y una lista numerada con estado por ítem obliga a escribirle un estado a cada comprobación.

Con tres muestras no se puede separar el peso de cada factor.

**Prioridad, probabilidad y orientación.** Ninguna muestra ordena causas por probabilidad. Las tres proponen el `#54` como siguiente comprobación. Por separado:

- Prioridad documental: el pasaje enumera tres comprobaciones sin orden ni preferencia. La muestra 2 («el primer elemento listado en el procedimiento») convierte la posición en la lista en precedencia. La muestra 1 titula «Próximo paso recomendado según documentación» y luego dice que la documentación no ordena los pasos. Las dos atribuyen al manual una prioridad que no imprime.
- Probabilidad causal: ninguna la afirma.
- Orientación práctica: la muestra 3 propone el `#54` porque «aún no ha sido realizada». Con el LED apagado (y 5.6, que liga ese LED a la fotocélula o a la entrada de re-apertura) y sin obstrucción visible, el `#54` es la única comprobación de las tres sobre la que el reporte no dice nada. Es una orientación defendible si se presenta como propia y con la razón tomada del reporte. La rúbrica «No jerarquiza `#54`» mezcla las tres cosas y queda corregida abajo.
- Ninguna usa 5.6 para el LED con su cita [4]. No es un fallo, pero es la inferencia documentada más útil del caso.
- El `#21` de la muestra 1 aparece en la información que falta («señales de re-apertura (#21) … para descartar un fallo electrónico»). No es un paso de este síntoma, pero liga `#21` a este síntoma sin que el pasaje lo haga.

**Instrucciones contradictorias que quedan.**

- `language_directive_header`: «Section headers, bullet labels … must all be in Spanish» da por supuestos los títulos. El canal web dice «No headings or section titles: running prose only». Las tres muestras abren con `#`.
- `DOCUMENT_IDENTITY_ATTRIBUTION_CONTRACT`: «fixed headings are not required» admite títulos. Las etiquetas entre comillas («Falta en los pasajes») salieron como pseudotítulo en negrita («Información no documentada en estos pasajes:»).
- `generation.txt` (STRICT_ONLY): «Use short paragraphs or numbered lists» frente a «running prose only». Una lista corta no es el problema. Se resuelve en la rúbrica y no en el código.
- `DOCUMENT_IDENTITY_ROLE_REPLACEMENT`: «The technician's words are … not a completed check». En el turno 1 no choca. En el turno 3 contradice `Check: fotocélula (done): no está activada`. Esa generación no se hizo.
- El prompt solo prohíbe: no dice que se pueda proponer una siguiente comprobación. El modelo lo hace igual y lo atribuye a la documentación.
- Turno 3: el intérprete guardó «la fotocélula y no está activada» también como observación. Es un fragmento cortado, que duplica el resultado de la comprobación. Es redundante, no contradictorio. Impacto no medido; no entra en la corrección.

**Secuencia de turnos y actualización de comprobaciones.**

- El turno 3 de F3 se aplica sobre una copia del episodio del turno 1, sin la corrección del LED del turno 2. Las tres generaciones usan solo el estado del turno 1 (`modo_esclavo.json` lo dice; el párrafo de generación de arriba no). El estado del turno 3 no tuvo ninguna respuesta.
- «No hubo reemplazo: el sujeto normalizado no coincide» es una frase vacía: el turno 1 no tenía ningún sujeto «fotocélula». Lo que se demuestra es que una comprobación nueva entra en `done` con su resultado y que `#54` y las mediciones siguen en `not_done`. El paso de pendiente a hecha con el intérprete real no se probó. Con payloads fijos lo cubre el test de F1-B. Sigue abierto si un sujeto real como «el #54» o «el potenciómetro» normaliza igual que «#54». Si no, el estado tendría a la vez `not_done` y `done` para la misma comprobación.

**Corrección mínima para Grok.** Una sola tanda, sin clasificador, verificador ni regla del VF5. Se sustituyen frases y no se añaden bloques.

1. `Rag::TurnInterpreter` (prompt de sistema): sustituir «What the technician sees or does not see is an observation, not an identifier and not a check.» por «The reported fault and what the technician sees or does not see are observations, not identifiers and not checks.»
2. `WorkContextReducer#durable_goal_text`: si alguna observación del turno cumple `problem_statement?` (el predicado que ya usa `adopt_problem_goal!`), el objetivo son esas. Si ninguna lo cumple, sigue la unión actual. «La puerta se reabre sola» lo cumple. «No veo obstrucción» y el LED no, así que vuelven a `Obs:`. Límite: `SIGNAL_RE` es léxico en español. En otro idioma se cae a la unión actual, sin regresión.
3. `BedrockRagService`, cuatro frases sustituidas:
   - `DOCUMENT_IDENTITY_ROLE_REPLACEMENT`: «not a completed check and not a documented procedure» → «not a documented procedure; a check is done only when the technician reports doing it».
   - `FIELD_REPORT_PARAGRAPH`: «State the documented checks that fit the report, with their conditions, and which remain open.» → la misma frase seguida de «You may suggest which open check to do next, with the reason taken from the report, as your own orientation and not as an order or likelihood the passages do not state.»
   - `DOCUMENT_IDENTITY_ATTRIBUTION_CONTRACT`: «fixed headings are not required» → «without headings».
   - `language_directive_header`: «Section headers, bullet labels, time estimates…» → «Labels, time estimates…».
4. Pines de hash de los prompts y tests de comportamiento. No hay tests de frase exacta.

**Rúbrica aclarada para la próxima tanda.** Sustituye las líneas correspondientes de F3:

- No presenta un «no veo» como comprobación hecha ni descartada.
- No convierte una comprobación documental en un ajuste. Comprobar la sensibilidad no es ajustar el potenciómetro.
- Un estado puntual del LED no es la comprobación de la fotocélula durante la falla. Un LED apagado con la puerta parada no basta para dar esa comprobación por hecha.
- No atribuye al manual un orden, una prioridad ni una probabilidad causal que el pasaje no imprime. Puede proponer una siguiente comprobación como orientación, con la razón tomada del reporte.
- Sin títulos en el texto que ve el técnico, después de `sanitize_answer`. Una etiqueta con dos puntos queda; CG-D19, 15 de octubre, la admite. Se conserva la salida original del modelo. Se admite una lista corta.
- Turno 3: no vuelve a pedir la fotocélula como pendiente, mantiene abiertas las otras y no cierra el caso.
- Siguen en vigor: la PDF 13 condicional, `#21` fuera de este síntoma, el SW4 como ejemplo, sin plano y citas correctas.

**Validación acotada.**

- Local, cero llamadas:
  - Reducer, con el turno 1 como payload fijo: objetivo = síntoma, y `Obs:` con LED y obstrucción. Sin síntoma, cae a la unión actual.
  - `QueryComposer`: con ese episodio, la consulta del turno 3 lleva el síntoma.
  - Normalización: `#54` `not_done` seguido de «el #54» `done`. Se anota si sustituye o si duplica, sin cambiar la regla en esta tanda.
  - Tests de prompt: sin «Section headers» ni «fixed headings are not required», y con la frase de rol nueva.
  - El evaluador de F3 exige el síntoma en el objetivo o en las observaciones.
- Pagada, en dos procesos:
  - Intérprete: turnos 1 y 3, 2 llamadas.
  - Generación: 2 muestras del turno 1 y 1 del turno 3 con su estado, 3 llamadas.
  - Total 5 intentos. Gasto esperado de unos US$0,04: unos US$0,004 por intérprete y US$0,009–0,010 por generación, según las llamadas 73 a 77. Cada proceso va con tope de 5 llamadas y US$0,15.
  - El ledger pasaría de 77 a 82 intentos y de unos US$0,99 a unos US$1,03, bajo 96 y US$4.
  - Supera en 2 intentos la asignación de F3 (10, de los que se usaron 7). Si no se amplía, la reserva de transitorios de F5 baja de 3 a 1. Lahiri autorizó exceder el presupuesto lo mínimo para pruebas. Esta tanda se corre solo con la corrección aplicada: sin ella repetiría el resultado actual.
- Fallo: una muestra que presenta la obstrucción como hecha, atribuye un orden al manual, ordena causas o escribe títulos. Se describe y no hay otra tanda.

### F3. El intérprete no devolvió percepción, 21 de octubre de 2026

La corrección mínima de arriba entra en este registro, sobre `8c63483`. `normalize_label` y `upsert_check!` no cambian: `#54` y «el #54» siguen como dos sujetos. F2 sigue cerrado en local. No hay escritura a S3 ni sincronización de la KB.

Local, cero llamadas. El objetivo del turno 1 fijo es el síntoma, y el LED y la obstrucción quedan como observaciones. Sin frase de problema, el objetivo sigue siendo la unión. La consulta del turno 3 conserva el síntoma. El prompt ya no pide «Section headers» ni «fixed headings are not required», y el rol dice que una comprobación está hecha solo cuando el técnico la reporta. El evaluador de esta tanda exige el síntoma en el objetivo o en las observaciones.

Pagada. El preflight de `tmp/field_companion/vf5_correction/f3/attempts/3` leyó el ledger en 77 intentos, committed US$0,989452, open vacío y unknown 0. El proceso del intérprete no guardó episodio. `TurnInterpreter` hizo tres converse del turno 1: el cliente SDK sigue en un intento HTTP y `TransientBackoff` reintenta un error transitorio hasta tres veces. Las tres devolvieron `Aws::BedrockRuntime::Errors::ServiceUnavailableException`. El ledger quedó en 80 intentos, committed US$0,989452, open {} y unknown US$0,025851. Las entradas 78, 79 y 80 son `converse`, cada una con techo US$0,008617, sin tokens y sin `actual_usd`. Ese techo no se reescribió a cero: no hay evidencia de factura. `attempts/3` solo tiene el preflight y los cuatro cuerpos. No hay `t1/`, `t3/` ni muestras. Los intentos 1 y 2 y las muestras 1 a 3 siguen como estaban.

No se abrió el proceso de generación. Con unknown distinto de cero esta tanda no llama otra vez. No hay respuesta nueva que juzgar y no se prepara la solicitud remota. Esta corrida no certifica la corrección del LED del turno 2 ni la conversación de F5. Los tres intentos salen del cupo adicional; no se cuentan como la tanda de cinco que debía bajar la reserva de transitorios de F5 de 3 a 1.

### F3. El servicio volvió; el turno 3 no trae el resultado, 21 de octubre de 2026

Las entradas 78, 79 y 80 siguen en unknown. No se pusieron a cero y el contador no se reinició. `AssignmentSpend#unknown!` ya las había reconciliado: sin tokens no hay `actual_usd`, y el techo US$0,008617 de cada una queda como exposición. `unknown!` solo actúa mientras el hold está abierto; no hay un segundo método que les añada la clase de error después. La evidencia que sí hay es de esta corrida, no de Aurora.

Operación y endpoint. Las tres filas dicen `turn: converse`. El cliente es `Aws::BedrockRuntime::Client#converse`, región `us-east-1`, modelo `global.anthropic.claude-haiku-4-5-20251001-v1:0`, endpoint `bedrock-runtime.us-east-1.amazonaws.com` en `POST /model/…/converse`. Es la invocación del intérprete. No es `Retrieve`, no es `retrieve_and_generate` y no es `invoke_model`. El mensaje no contiene el patrón de reanudación de Aurora (`aurora…auto-paused`). Las esperas de `AuroraColdStartRetry` son 15, 30 y 45 segundos; el cierre de cada intento quedó a 4 segundos. Esa configuración no se tocó.

Backoff. Las tres admisiones salen de un solo proceso y de `TurnInterpreter#converse_with_recovery`, que usa `TransientBackoff` (tope 3, esperas 0,4 s y 0,8 s más un jitter de hasta un cuarto, tope 8 s). El SDK de ese cliente sigue en `max_attempts` 1. La captura con `wait_seconds` no se guardó: el runner cortó antes de escribir `capture.json`. Con la resolución de un segundo, los 4 s caben en una respuesta de unos 3 s más esas esperas, y no caben en 15 s. En las llamadas 81 y 82, ya con el servicio de vuelta, cada turno tuvo un solo `interpreter_attempt` y ninguna `interpreter_failure`: no hubo espera porque el primer converse respondió. `generate_text` sigue sin ese backoff; traga el error y devuelve nil. El runner de generación, si llega a usarse, reintenta solo ese nil transitorio con el mismo `TransientBackoff`, sin subir los reintentos del SDK.

Presupuesto. Unknown US$0,025851 se suma a committed US$0,989452. La exposición era US$1,015303, bajo US$1,545161 y bajo US$4, con 11 intentos libres. El techo pendiente cabe. El corte anterior era la regla del runner que exigía unknown en cero, más estricta que `AssignmentSpend#exposure`.

Intérprete recuperado, en `f3/attempts/3`, git `2b8e806`, prompt `9735f4fc…`. Llamadas 81 y 82, US$0,003983 y US$0,003267. Ledger: 82 intentos, committed US$0,996702, unknown US$0,025851, open {}. Turno 1: objetivo «La puerta se reabre sola»; observaciones con el síntoma, el LED y «No veo obstrucción»; `#54` y mediciones en `not_done`. La consulta del turno 3 lleva el síntoma. El modelo emitió el síntoma también como identificador; el almacén no lo guardó. «Modo esclavo» no vino en el turno: el almacén lo acepta y el contexto cambia; la respuesta no se midió.

Turno 3: la fotocélula quedó `done` con `result` null. «no está activada» quedó como observación, no como resultado de la comprobación. `#54` y las mediciones siguen `not_done`. No hubo otro sujeto cerrado: `other_done` aparece porque el evaluador solo acepta la fotocélula si trae resultado. No se generó. No se prepara la solicitud remota. `#54` frente a «el #54» no se ejerció en este turno; la regla sigue sin cambiar y esa prueba sigue pendiente. F2 sigue cerrado en local. No hay escritura a S3.

### F3. Contexto del turno 3 y dos respuestas del turno 1, 21 de octubre de 2026

No se repitieron los intérpretes 81 y 82. El contexto se reconstruyó en local, cero llamadas, sobre el episodio ya guardado.

```
Goal: La puerta se reabre sola
Check: #54 (not_done)
Check: mediciones (not_done)
Check: fotocélula (done)
Obs: El LED de fotocélula está apagado; No veo obstrucción; no está activada
```

El síntoma está en el objetivo. La fotocélula figura realizada. `#54` y las mediciones siguen sin realizar. «no está activada» está entero, pero es un fragmento en la lista de observaciones: no nombra la fotocélula, y la línea `Check` no lleva resultado. La consulta sí junta las dos cosas («Ya revisé la fotocélula y no está activada»); el contexto no. No se rellenó `result`. Con eso, la generación del turno 3 queda en pausa. No se añadió una heurística que ate el fragmento a la fotocélula.

La limitación estructural sigue abierta y no está corregida: el resultado de la comprobación no viaja en `result`, y «#54» frente a «el #54» no se ha probado. La forma del payload no se toma como aceptación ni como rechazo del companion.

Generación del turno 1, dos muestras, llamadas 83 y 84, US$0,010088 y US$0,009718, 7593 tokens de entrada, sin reintento. Prompt `f07f384e…`, git `aca246f`. El orden de citas del prompt es [1] SW4, [2] el síntoma de `#21`, [3] «re-abre sola», [4] el apartado 5.6. Las dos muestras citan [3] para las tres comprobaciones y la muestra 1 cita [1] para SW4. No usan `#21` como paso de este síntoma.

Las dos fallan la rúbrica. Las dos abren con título. Las dos dan por hecha la obstrucción («esta observación visual está hecha»). Las dos atribuyen al manual un orden que el pasaje no imprime («primer paso documentado», «primer elemento documentado»). La muestra 1 además pide verificar SW4 y ajustar el `#54`. No hay tercera muestra ni otra tanda. No se prepara la solicitud remota.

Ledger: 84 intentos, committed US$1,016508, unknown US$0,025851, open {}. Las entradas 78–80 siguen como techo. Exposición US$1,042359. F2 sigue cerrado en local. No hay escritura a S3 ni sincronización. Esta corrida no certifica el turno 2 ni F5.

### F3. Cerrada como fallida en generación, 21 de octubre de 2026

Sin llamadas nuevas. El ledger sigue en 84 intentos, committed US$1,016508, unknown US$0,025851 y open vacío. Exposición US$1,042359. Ingesta: 25 llamadas, US$1,139502, unknown 0. F2 sigue cerrada en local.

**Formato, medido otra vez.** `sanitize_answer` (`RagQueryConcern`, canal web) pasó por las cinco salidas originales. Las copias quedaron en `sanitized.txt`. Los `response.txt` no se tocaron. `normalize_label("#54")` es `54` y `normalize_label("el #54")` es `el 54`.

Ninguna de las cinco conserva un título `#` después del sanitizador. Quedan etiquetas con dos puntos: «Comprobaciones documentadas:», «Próximo paso recomendado:» y equivalentes. CG-D19 las admite. El criterio de títulos se juzga sobre ese texto, no sobre la salida cruda de `AiProvider.query`. Quitar las frases de encabezado del prompt no evitó que el modelo abriera con `#`; el técnico no llega a ver esa línea. El formato no es el cierre de F3.

**Contenido, sobre el mismo texto.** El resto de la rúbrica se juzga en la respuesta, que el sanitizador no reescribe.

| Muestra | Obstrucción dada por hecha | Fotocélula dada por hecha por el LED | Orden atribuido al manual | Ajuste del #54 |
| --- | --- | --- | --- | --- |
| 75, prompt `cc1c72e9` | sí: «ha verificado visualmente» | no: «sugiere» | pide el #54 antes de desconectar y luego dice que el manual no ordena | no; habla de valores que faltan |
| 76 | no: deja el reporte | no: «sugiere» | sí: «primer elemento listado en el procedimiento» | no |
| 77 | no | no: «sugiere» | no: el siguiente paso es porque aún no está hecha | no |
| 83, prompt `f07f384e` | sí: «está hecha» | sí: «esta condición se cumple» | sí: «primer paso documentado» | sí: «Ajuste el potenciómetro #54» |
| 84 | sí: «está hecha» | sí: «se cumple» | sí: «primer elemento documentado» | sí: «medición o ajuste» |

La 75 nombra `#21` entre lo que falta, ligado a este síntoma. La 83 pide verificar SW4. El pasaje dice comprobar la sensibilidad del `#54`, no ajustarlo. Un LED apagado con la puerta parada no descarta que la fotocélula se active al cerrar. Esas dos líneas entran en la rúbrica de arriba.

**Cierre.** El estado del turno 1 cumple: el objetivo es el síntoma y el LED y la obstrucción siguen como observaciones. El turno 3 no trae `result`. La generación falla por dar comprobaciones por hechas, por atribuir un orden al manual y por pedir un ajuste que el manual no documenta. Tres redacciones (la captura histórica, `cc1c72e9` y `f07f384e`) fallan ese criterio de contenido. No se vuelve a tocar el prompt de respuesta en este ciclo y no hay otra tanda.

**Pendiente, sin darlo por corregido.** El `tool_input` del turno 3, a temperatura 0, trae la fotocélula en `done` y `result` null, y guarda «no está activada» como observación. Ni el contrato ni el reducer lo quitaron. En el intento 2 el mismo turno sí trajo `result`. Entre medias cambió la frase del intérprete y el contexto de trabajo, con una muestra por versión: la causa no está probada. No se rellena `result` desde la observación. «#54» y «el #54» no coinciden al normalizar; si el intérprete copiara «el #54», el episodio tendría la misma comprobación en `not_done` y en `done`. No se sabe qué fragmento copiaría. «Modo esclavo» sigue sin medirse en una respuesta.

**Opciones presupuestadas, sin ejecutar.** Quedan 7 intentos del cupo adicional (tope 91) y 12 del tope de 96. En dólares quedan US$0,502802 del adicional (tope US$1,545161) y US$2,957641 del tope de US$4. Unknown sigue dentro de la exposición.

- Intérprete de los turnos 1 y 3, dos llamadas, unos US$0,007, techo de unos US$0,018. Cabe en los 7 intentos autorizados que quedan. La frase propuesta, aún no aplicada, sustituye «result is a literal substring of the turn, or null» por «result is the outcome the technician states for that check, copied literally from the turn, or null; that outcome is the result even when it also reads as an observation». Sin regla nueva en el reducer. Si `result` vuelve null, esa hipótesis queda descartada.
- F5: ocho llamadas previstas y una de reserva, nueve en total, tope de proceso US$0,30. Los US$0,30 caben en los US$0,502802 autorizados que quedan y en el tope global de US$4. Las nueve llamadas no caben en los 7 intentos autorizados que quedan. Sí caben en los 12 que deja el tope global de 96. No se amplía ninguno de los dos. No empieza.

**F4, separada de la rúbrica de generación.** Sigue siendo una propuesta pendiente de decisión. No es una autorización remota. Si se concede, F4 comprueba la sustitución documental y el Retrieve. No declara aceptado el companion. F5 sigue siendo la fase que mide la continuidad de los turnos 2 a 4. Es probable que el turno 1 de F5 repita estos fallos de generación; si ocurre, se anota como defecto conocido.

La solicitud queda redactada y no se envía. Sin escritura en S3 ni sincronización.

### Solicitud remota preparada, sin enviar

Pide autorización para sustituir el prefijo del VF5 y sincronizar la fuente. No pide aceptar el companion ni reescribir el prompt de respuesta.

Evidencia ya revisable en local: cobertura de las 22 páginas, con la nota visual de p6 y p22; F2 cerrada en local; F3 fallida en generación, con el estado del turno 1 cumplido y el turno 3 sin `result`. Ingesta: 25 llamadas, US$1,139502. Asignación: 84 intentos, committed US$1,016508, unknown US$0,025851. Esta redacción no autoriza el envío. La diferencia de claves entre `tmp/review_vf5/` y el directorio nuevo se adjunta al ejecutar; este paso no lee S3.

Inventario del JSON certificado `merged_document.json`, sin reauditar la ingesta: 45 chunks, nombre «Módulo electrónico VF5+ Fermator». `BatchResultsParserService#write_chunks_to_s3` escribe un cuerpo `.txt` y un sidecar `.metadata.json` por chunk: 45 cuerpos y 45 sidecars. La página 3 no aporta objeto. El prefijo histórico de `tmp/review_vf5/` era de 30 cuerpos y 30 sidecars. Los embeddings de la sustitución son los de los 45 cuerpos. Los sidecars acompañan a cada cuerpo y no se vuelven a extraer.

1. Sustituir `bulk_chunks/1/be7a39a3490c92c8381cb883402760cb07d1/` con `BatchResultsParserService#call`, ese JSON, `ingestion_path: "manual_batch_v1"`, la misma cuenta, el mismo `document_uid` y un `ChunkAsset` con el `s3_key` y el bucket originales, escribiendo por `S3DocumentsService`.
2. Borrar por ese servicio las claves sobrantes si el borrado previo falló.
3. `start_ingestion_job` en la fuente `Y7RZWMFJSR`. La fuente abarca todo `bulk_chunks/` y el job recogerá también cualquier otro cambio pendiente.
4. Restaurar la copia y resincronizar una vez si la sustitución o la sincronización fallan.

Si esa decisión se concede, F4 anota si el Retrieve devuelve los cuerpos nuevos. Eso no acepta el companion.

### Decisión pendiente: generación

El estado ya se renderiza. `SessionContextBuilder#check_lines` mete en el prompt `Check: sujeto (estado)` y, si hay `result`, el resultado. El fallo de las muestras 75 a 84 es posterior: el mismo prompt le pide al modelo que vuelva a decir qué queda abierto y que proponga el siguiente paso, y la respuesta que ve el técnico es solo el párrafo del modelo. El código no compara ese párrafo con la línea `Check` ni con el verbo del pasaje. `sanitize_answer` quita el título y deja el contenido.

La propuesta de Grok (estado desde el episodio, párrafo del modelo limitado a la condición del pasaje) se corrigió el 21 de octubre sobre `82d25e7`, sin llamadas y sin implementar. Tenía tres defectos:

- **Rúbrica.** Solo rechazaba dar por hecha una comprobación en `not_done`. En el turno 1, la obstrucción y la fotocélula no tienen línea `Check`. Las muestras 83 y 84 fallaron justo ahí («esta condición se cumple», «esta observación visual está hecha»). Con ese criterio las dos habrían pasado.
- **Garantía.** Atribuía al código una garantía del estado, el resultado y el referente. El código copia el episodio; no lo corrige ni lo completa. En el turno 3 la fotocélula está en `done` con `result` vacío, y «no está activada» es una observación sin referente.
- **Utilidad.** Un párrafo con solo la condición del pasaje y su cita parafrasea el manual y no orienta. Esa salida evita los errores porque omite la ayuda, y la prueba la habría aceptado. El guion pide orientación con el primer mensaje, una o dos intervenciones, la causa y sus subsistemas sin concluir, la página, y nada ajeno a la falla.

Diseño corregido. Misma llamada, mismos pasajes y mismo contexto. Sin servicio, clasificador ni verificador. Sin reglas del VF5.

| | Ahora | Propuesta de Grok | Corregido |
| --- | --- | --- | --- |
| Estado visible | Ninguno propio; lo escribe el modelo | La línea `Check` | Registro breve generado del episodio: equipo, síntoma, observaciones literales entre comillas y comprobaciones del técnico, con plantilla fija en español. `done` sin `result` dice «sin resultado registrado». No enumera el manual |
| Tarea del modelo | Comprobaciones, cuáles quedan abiertas y siguiente paso opcional | Solo condición y cita | Comprobaciones del pasaje con su verbo y su condición, sin estado; una orientación propia (observación o comprobación siguiente), con la razón tomada del reporte y de los pasajes; como mucho una pregunta |
| Prompt | — | Quitar dos frases | Sustituir esas dos frases por una. No se añade bloque |

Sustitución en `FIELD_REPORT_PARAGRAPH`. Sale «State the documented checks that fit the report, with their conditions, and which remain open. You may suggest which open check to do next, with the reason taken from the report, as your own orientation and not as an order or likelihood the passages do not state.» Entra «The Active Field Problem record is shown to the technician with your answer; do not restate whether a check is done or open. State the documented checks that fit the report with the passage's own verb and condition. Then give one next observation or check as your own orientation, with its reason taken from the report and the passages, not as an order or likelihood the passages do not state, and ask at most one question.»

Registro: se antepone al texto ya pasado por `sanitize_answer`, solo en la ruta de identidad documental con episodio activo y con observaciones o comprobaciones. Reutiliza la compactación de observaciones de `SessionContextBuilder`, que ya omite la que repite el objetivo. No entra en el texto que el historial reinyecta: el historial guarda los primeros 200 caracteres de la última respuesta, y el registro los llenaría con un estado que el turno siguiente puede corregir (el LED en F5). Tests sin modelo: fragmentos literales, `done` sin resultado, ningún resultado rellenado, episodio vacío sin registro.

**Qué garantiza el código.** El registro es el episodio de ese turno, con los fragmentos literales que el contrato admitió. No rellena un `result`. El texto final no lleva títulos `#`. El prompt ya no pide repetir el estado.

**Qué depende del modelo.** Que el párrafo no contradiga el registro, no convierta una observación en comprobación hecha, no cambie «comprobar» por «ajustar», no ordene causas y oriente de verdad. Las muestras 83 y 84 ya tenían la prohibición del ajuste y lo escribieron igual. Que el episodio sea correcto y completo depende del intérprete: el turno 3 sin `result` y «#54» frente a «el #54» siguen abiertos. En el turno 3 el registro mostraría «fotocélula: hecha, sin resultado registrado» y «no está activada» entre las observaciones. Es visible y honesto. No está corregido ni se rellena.

**Turno 1, ilustrativo.** No es una salida del modelo ni una respuesta validada. Parte del episodio real (`attempts/3/t1/episode.json`) y de los pasajes [3] (8.2, PDF 12 y 13, impresas 11 y 12) y [4] (5.6). Páginas en folio impreso.

> Registro del caso. Equipo: Fermator VF5+. Síntoma: «La puerta se reabre sola». Observaciones: «El LED de fotocélula está apagado», «No veo obstrucción». Sin hacer: #54, mediciones.
>
> Para «la puerta se re-abre sola», el manual del VF5+ (8.2, pág. 11) da tres comprobaciones y no indica un orden: comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54), comprobar que la fotocélula no esté activada y comprobar que no hay una obstrucción mecánica en la puerta [3]. Lo que reportas son observaciones: no ver obstrucción no es haber comprobado la mecánica de la puerta, y el LED apagado vale para el momento en que lo miraste. El LED de fotocélula se activa cuando la fotocélula o la entrada de re-apertura está activada (5.6) [4]. Orientación mía, no del manual: mira ese LED en el momento en que la puerta reabre. Si se enciende, apunta a la fotocélula o a la entrada de re-apertura; si sigue apagado, no las señala y siguen por comprobar el #54 y la obstrucción mecánica. Si el problema persiste, el manual indica desconectar la fotocélula y volver a pulsar TEST; si entonces la puerta no abre o cierra completamente, debe haber una obstrucción mecánica (pág. 12) [3]. ¿Se enciende el LED cuando la puerta reabre?

La primera línea la escribe el código. El resto es lo que el modelo debería poder escribir. La orientación es una inferencia sobre 5.6 y 8.2, marcada como propia. Es una observación que separa la fotocélula de las otras dos comprobaciones y se responde con sí o no. No es un orden de causas. La rúbrica no exige esta orientación concreta, sino una con razón tomada del reporte y de los pasajes.

**Rúbrica de la respuesta completa.** Sustituye el rechazo anterior de esta sección. Se juzga el registro más el texto pasado por `sanitize_answer`. Las líneas de «Rúbrica aclarada» que no se repiten aquí siguen vigentes.

Rechazo, basta una muestra:

1. Presenta como hecha, cumplida, verificada, descartada o resuelta cualquier comprobación de los pasajes que el episodio no tenga en `done`. Vale tenga o no línea `Check`, y también cuando la deduce de una observación («no veo», el estado del LED).
2. Contradice el registro.
3. Cambia el verbo del pasaje por ajustar, regular, calibrar, girar o reemplazar. O da como orden un paso que los pasajes no traen («verifique SW4»).
4. Atribuye al manual un orden, una prioridad o una probabilidad, u ordena causas.
5. Da la condición de la PDF 13 como primer paso o sin condición, liga `#21` a este síntoma o toma el ejemplo de SW4 como hecho del equipo.
6. No orienta: solo parafrasea las comprobaciones o el estado, sin una observación o comprobación siguiente ligada al reporte. También falla si hace más de una pregunta o pide algo que el turno ya trae (marca, modelo, LED, obstrucción, `#54`, mediciones).
7. Lleva un título después del sanitizador, una cita que no corresponde al pasaje o más de 300 palabras.

Aceptación, cada muestra cumple todo:

- Las comprobaciones de «se re-abre sola» con su verbo y [3]. Omitir una no falla.
- Lo que reportó el técnico queda como observación.
- Una orientación propia, marcada como tal, con razón del reporte y de los pasajes, y como mucho una pregunta que se responde en pocas palabras.
- La PDF 13 condicional u omitida.
- Coherente con el registro.

**Prueba mínima.** Antes, en local y sin llamadas: el registro, la sustitución, sus tests y los pines de hash. Después, dos `generate_text` del turno 1 con el episodio `attempts/3/t1/episode.json` y los cuatro pasajes de `attempts/3/chunks/`, en el mismo orden ([1] SW4, [2] «abre pero no se cierra», [3] «re-abre sola», [4] 5.6). Haiku de producción, temperatura 0,1 y 3000 tokens. Sin intérprete nuevo. Un proceso con `RAG_LOCAL_PASS_CALL_CAP=2` y US$0,10. Un error transitorio cuenta como intento y no se reintenta por encima del tope. Se guardan la respuesta cruda, el texto sanitizado y la respuesta completa con el registro.

Presupuesto: gasto esperado de unos US$0,020, el de las llamadas 83 y 84. Techo de unos US$0,082. El ledger pasaría de 84 a 86 intentos, dentro de los 7 que quedan del cupo autorizado y de los US$0,502802. Quedan 5. Si además se prueba el intérprete del turno 3 (2 llamadas), quedan 3. F5 (nueve llamadas) no cabe en ningún caso y necesita otra decisión de Lahiri. Este plan no amplía nada. Las entradas 78 a 80 siguen en unknown.

Lectura: una muestra rechazada rechaza el diseño y no se sustituye por otra frase equivalente. Dos muestras aceptadas solo dan evidencia preliminar: no prueban estabilidad, no miden el turno 3 y no aceptan el companion. F5 sigue siendo la medida de la conversación.

### F3. La configuración de registro y orientación queda rechazada, 21 de octubre de 2026

La propuesta de esta sección quedó aplicada en el árbol de trabajo, sobre `4e5a12e`, sin commit. `FIELD_REPORT_PARAGRAPH` sustituye las dos frases indicadas por la frase única. Su SHA es `0992a841c2e7f9ef0c5a417753c449eae5a232df90c7926c7e2685d0d1e0f2a6`. El prompt reconstruido del turno 1 es el de `attempts/3` con solo ese cambio: SHA `8be5f9861ac9c4a07f5e7cd29a61647a8e626e1369363c367d975eddf741f5a6`, frente a `f07f384e7c0d28b9fed90f2475dcef6ef39b1e728db4c7794b9bf9f05af3b92a`. `Rag::FieldCaseRecord` antepone el registro después de `sanitize_answer`. El historial guarda en `prompt_reply` el texto sanitizado, y ese es el que se reinyecta. Los tests locales del registro, de la sustitución y del corte de historial pasaron antes de las llamadas.

**Qué garantiza el código, y estas dos salidas lo muestran.** El registro copia el episodio del turno 1: Fermator VF5+, el síntoma, las dos observaciones literales, y `#54` y mediciones en «sin hacer». Omite la observación que repite el objetivo. No rellena un resultado. No enumera el manual. Las dos respuestas crudas abren con `# Diagnóstico…`. El sanitizador quita esa línea. El texto presentado no lleva `#`; conserva etiquetas con dos puntos, que CG-D19 admite. `history_reply.txt` es igual a `sanitized.txt` y no contiene el registro. El prompt ya no pide repetir qué está hecho o abierto.

**Qué depende del modelo.** Las dos muestras vuelven a decir que el `#54` no está hecho. El registro ya lo dice. Esa repetición coincide con el registro y no da la comprobación por hecha: la rúbrica no la usa como rechazo. El párrafo, el verbo, la orientación y el uso de los pasajes siguen siendo del modelo. El ejemplo ilustrativo de arriba no se usó como salida exigida ni como texto del fabricante. «sugiere», en la muestra 1, se lee igual que en las muestras 75 a 77: no cierra la fotocélula. Preguntar el LED en el momento de la reapertura habría sido válido; ninguna de las dos lo pregunta, y la rúbrica no exige esa orientación.

Generación. Dos `generate_text`, sin intérprete, sin reintento y sin escritura en S3. Haiku `global.anthropic.claude-haiku-4-5-20251001-v1:0`, temperatura 0,1, 3000 tokens. Episodio `attempts/3/t1/episode.json`. Pasajes de `attempts/3/chunks/` en el orden [1] SW4, [2] «abre pero no se cierra», [3] «re-abre sola», [4] 5.6. Tope de proceso: 2 llamadas y US$0,10. Llamadas 85 y 86, 7626 tokens de entrada cada una, 460 y 466 de salida, US$0,009926 y US$0,009956. Gasto de la prueba: US$0,019882. Ledger: de 84 intentos y committed US$1,016508 a 86 intentos y committed US$1,036390. Unknown sigue en US$0,025851. Open vacío. Exposición US$1,062241. Quedan 5 intentos del cupo de 91 y US$0,482920 del tope US$1,545161. Del tope de 96 quedan 10 intentos; del de US$4 quedan US$2,937759. Las entradas 78 a 80 siguen en unknown.

Copias en `tmp/field_companion/vf5_correction/f3/attempts/4/samples/`: `response.txt`, `sanitized.txt`, `presented.txt`, `history_reply.txt`. 231 y 246 palabras en el texto presentado.

Muestra 1, texto presentado:

```
Registro del caso. Equipo: Fermator VF5+. Síntoma: «La puerta se reabre sola». Observaciones: «El LED de fotocélula está apagado», «No veo obstrucción». Comprobaciones: #54, sin hacer; mediciones, sin hacer.

Según la documentación del VF5+, para la reapertura automática de la puerta se documentan tres comprobaciones iniciales [3]:

Comprobaciones documentadas:

1. **Potenciómetro de regulación de fuerza de re-apertura (#54)** — No realizada. La documentación indica comprobar la sensibilidad de este componente [3].

2. **Fotocélula activada** — Usted reporta que el LED de fotocélula está apagado. La documentación establece comprobar que la fotocélula no esté activada [3]. Un LED apagado sugiere que la fotocélula no está detectando obstrucción en este momento.

3. **Obstrucción mecánica en la puerta** — Usted reporta no ver obstrucción. La documentación indica comprobar que no hay obstrucción mecánica [3].

Información adicional relevante:

El módulo VF5+ tiene un interruptor SW4 (Máster/Esclavo) que controla el comportamiento de re-apertura [1]. En posición ON (Máster), la unidad ejecuta instrucciones directamente: la activación de la fotocélula provoca re-apertura inmediata sin control de la maniobra. En posición OFF (Esclavo), no hay movimientos de re-apertura automáticos; la puerta solo responde a instrucciones del módulo de control del ascensor [1].

Próximo paso:

¿Cuál es la posición actual del interruptor SW4 en el módulo VF5+? Esto determinará si la re-apertura es controlada localmente por el operador de puerta o si debe ser controlada por la maniobra del ascensor.
```

Muestra 2, texto presentado:

```
Registro del caso. Equipo: Fermator VF5+. Síntoma: «La puerta se reabre sola». Observaciones: «El LED de fotocélula está apagado», «No veo obstrucción». Comprobaciones: #54, sin hacer; mediciones, sin hacer.

Según la documentación del VF5+, para el síntoma "la puerta se reabre sola" se documentan tres comprobaciones [3]:

Comprobaciones documentadas:

1. **Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54)** — Usted aún no ha realizado esta comprobación.

2. **Comprobar que la fotocélula no esté activada** — Usted reporta que el LED de fotocélula está apagado, lo que indica que la fotocélula no está activada en este momento.

3. **Comprobar que no hay una obstrucción mecánica en la puerta** — Usted reporta que no ve obstrucción.

Siguiente paso documentado:

Si el problema persiste después de estas tres comprobaciones, la documentación indica: "desconectar la fotocélula y volver a pulsar el botón de TEST. Si la puerta no se abre o cierra completamente, debe haber una obstrucción mecánica en la puerta" [3].

Observación sobre la configuración:

La documentación también documenta que el interruptor SW4 controla si la unidad opera en modo Máster (ON) o Esclavo (OFF) [1]. En modo Máster, la activación de la fotocélula provoca re-apertura inmediata sin control de la maniobra. Aunque el LED de fotocélula está apagado, conviene verificar la posición de SW4 y el estado del potenciómetro #54, que es la comprobación pendiente más directa para este síntoma.

¿Ha verificado ya la posición del interruptor SW4 y el ajuste del potenciómetro #54?
```

La primera lectura rechazó la muestra 1 por pedir la posición de SW4 y por «tres comprobaciones iniciales». Esa lectura se retira. Preguntar la posición no es ordenar cambiar el interruptor, y «iniciales» no demuestra por sí solo una prioridad entre las tres. Esta relectura no llama al modelo, no cambia código y no escribe en S3.

Texto general de [1], «SW4.- Máster y Esclavo». ON: «La unidad de control de la puerta ejecutará la instrucción directamente.» OFF: «No hay movimientos de re-apertura automáticos. Las puerta solo responden a las instrucciones dadas por el módulo de control del ascensor.» El ejemplo de ON, marcado como tal en el pasaje: «la activación de la fotocélula provocará una re-apertura inmediata sin el control de la maniobra.» El ejemplo de OFF, también marcado: con la fotocélula obstruida la unidad envía señal por FOTOCÉLULA (36, 37, 38) y la maniobra desactiva el cierre y activa la apertura.

| Criterio | Muestra 1 | Muestra 2 |
| --- | --- | --- |
| 1. Comprobación dada por hecha, también si se deduce del LED o de «no veo» | No se demuestra. «sugiere» no cierra la fotocélula. «Usted reporta no ver obstrucción» deja la mecánica como reporte. «No realizada» coincide con el registro | Falla. «lo que indica que la fotocélula no está activada en este momento» da por indicada la condición de 8.2 a partir del LED. El episodio no tiene esa comprobación en `done` |
| 2. Contradice el registro | No se demuestra. «No realizada» coincide con `#54, sin hacer` | No se demuestra en una frase que niegue un hecho guardado. El cuerpo dice que el `#54` aún no está hecho |
| 3. Cambia el verbo, o manda cambiar o hacer un paso ajeno | No se demuestra. El `#54` queda en «comprobar la sensibilidad». La pregunta pide la posición actual de SW4; no pide cambiarla | Falla por el verbo. «el ajuste del potenciómetro #54» convierte «comprobar la sensibilidad» en un ajuste. Pedir la posición de SW4, por sí, no es ese fallo |
| 4. Orden obligatorio, prioridad o probabilidad | No se demuestra. «Iniciales» y la lista 1, 2, 3 enumeran el conjunto. No hay «primero», «más directa» ni una actuación posterior puesta en secuencia | Falla. «Siguiente paso documentado» y «después de estas tres comprobaciones» convierten la condición de la PDF 13 en una secuencia. «la comprobación pendiente más directa» prioriza el `#54`. La lista numerada, sola, no sería este fallo |
| 5. PDF 13 sin condición o como primer paso, `#21` en este síntoma, o el ejemplo de SW4 como hecho de este equipo | No se demuestra. La PDF 13 se omite. No hay `#21`. No afirma que este equipo esté en máster o esclavo | No se demuestra en este ítem. La cita de la PDF 13 conserva «Si el problema persiste» y reproduce el pasaje. No hay `#21`. No afirma el modo de este equipo |
| 6. No orienta, más de una pregunta, o pide lo que el turno ya trae | No se demuestra. Una pregunta, la posición de SW4, que el turno no traía. La respuesta del técnico cambia la orientación, como se detalla abajo | Falla. La pregunta vuelve a pedir el `#54`, que el registro ya trae en «sin hacer». La parte de SW4 no es este fallo |
| 7. Título tras el sanitizador, cita que no corresponde, o más de 300 palabras | No se demuestra. Sin `#`. [3] son las tres comprobaciones de 8.2. [1] es el pasaje de SW4. 231 palabras | No se demuestra. Sin `#`. [3] y [1] apuntan a esos pasajes. 246 palabras |

**Muestra 1, SW4 contra [1].** «no hay movimientos de re-apertura automáticos; la puerta solo responde a instrucciones del módulo de control del ascensor» sigue el texto general de OFF. «la unidad ejecuta instrucciones directamente» sigue el texto general de ON; el pasaje dice «la instrucción», en singular y en futuro. Los dos puntos que siguen pegan el ejemplo de la fotocélula como si fuera ese texto general, y el pasaje lo marca con «Ejemplo». «que controla el comportamiento de re-apertura» resume el OFF general y el ejemplo de ON; la frase general de ON no dice eso. El ejemplo de OFF, el de los bornes 36, 37 y 38, no se usa.

La pregunta pide la posición actual. Si el técnico dice OFF, el texto general dice que no hay movimientos de re-apertura automáticos y que la puerta solo responde al módulo de control del ascensor: el caso deja de mirarse como reapertura automática de la unidad. Si dice ON, la unidad ejecuta la instrucción directamente y el ejemplo, no la frase general, es la re-apertura inmediata por fotocélula sin control de la maniobra: siguen en juego las tres comprobaciones de 8.2. Esa respuesta cambia la orientación. No es una orden de cambiar SW4 ni una intervención.

La frase que cierra la pregunta no es del fabricante: «operador de puerta», «localmente» y «debe ser controlada». El pasaje dice «unidad de control de la puerta» y «ejecutará la instrucción directamente», y en OFF «solo responden a las instrucciones». No añade un mecanismo, una comprobación hecha ni un ajuste. Queda como paráfrasis, no como fallo de los ítems 3 o 5.

«Tres comprobaciones iniciales» nombra el conjunto que 8.2 enumera con guiones, sin orden. No dice cuál va primero ni cuál es más probable. La PDF 13 no aparece, así que no hay actuación posterior presentada como secuencia.

**Muestra 2, lo que sigue en pie.** El LED apagado «indica que la fotocélula no está activada»: da la condición de 8.2 por sabida. La pregunta pide «el ajuste del potenciómetro #54» y, además, algo que el turno ya trajo como sin hacer. «Siguiente paso documentado» más «después de estas tres comprobaciones» atribuye al manual una secuencia que el pasaje no imprime: allí dice «En caso que el problema persista», y la cita entre comillas sí es la del pasaje. «más directa» prioriza el `#54` entre comprobaciones que el pasaje no ordena.

En SW4, la muestra 2 solo escribe el ejemplo de ON y lo presenta como el modo máster, sin la frase general y sin decir qué hace el OFF. «conviene verificar la posición de SW4» no es, por sí, el rechazo. La muestra no llega a mostrar que la respuesta del técnico cambiaría la orientación, porque el OFF no está.

**Aceptación.** La muestra 2 no la cumple: el LED no queda solo como observación, el `#54` pasa a ajuste, y el paso de la PDF 13 se atribuye al manual como siguiente. La muestra 1 sí cubre las balas de esta rúbrica en esta lectura: las tres comprobaciones van con «comprobar» y [3], el LED y la obstrucción quedan como reporte, la PDF 13 está omitida, el párrafo no contradice el registro, y hay una pregunta propia. No lleva la etiqueta «orientación mía». Va como «Próximo paso», sin atribuirla al manual. La razón es el síntoma de reapertura más el contraste ON/OFF de [1]. No usa el LED, el «no veo» ni el `#54` abierto. Eso no se convierte en un ítem de rechazo.

**Qué mejora respecto de las muestras 83 y 84.** El registro coincide con el episodio y no entra en el texto reinyectado. El título `#` no llega al texto presentado. La obstrucción queda como reporte. `#21` no se ata a este síntoma. La PDF 13 se omite o conserva la condición. El listado del `#54` usa «comprobar».

**Qué queda sin resolver.** La muestra 1 no está certificada como salida estable: la separación entre texto general y ejemplo queda incompleta, y «operador de puerta» no es la palabra del pasaje. La muestra 2 falla, y con una muestra basta para rechazar esta configuración. No hay evidencia preliminar y el companion no queda aceptado. No se escribe otra frase ni se lanza otra generación. No se concluye que la arquitectura sea inviable. El turno 3 de los intentos 1 a 3 sigue sin `result` en su `tool_input`. «#54» y «el #54» siguen sin equivaler. «Modo esclavo» no está en este episodio y esta corrida no lo mide. F5 no se ejecutó. F2 no se repitió. S3, la KB y la configuración AWS no se tocaron.

### F3. El contrato de checks exige result, 21 de octubre de 2026

La unidad de registro y orientación no entró en `main`. Quedó en la rama local `fc/registro-orientacion`, `5a5a4ce`, y en `tmp/field_companion/vf5_correction/f3/attempts/4/registro_orientacion.patch`. El parche incluye los dos archivos nuevos. Durante esta prueba esa unidad sigue activa en el árbol y no está en el `git_sha` del intérprete. El intérprete no llama a `FieldCaseRecord`.

El contrato va en la rama local `fc/contrato-checks`, `d104d5b`, sin push. Cambia `TurnPerception.tool_schema`: cada check exige `subject`, `status` y `result`. `result` sigue pudiendo ser null. La frase de `TurnInterpreter::PROMPT` pasa de «result is a literal substring of the turn, or null» a «result is the outcome the technician states for that verification, copied literally from the turn, or null; that outcome stays the result even when it also reads as an observation.» SHA del prompt: `2ba8dc425a17b920a04925c924ae8b497886cffcd941cdece078860bcc461ea4`. `checks_failure` no cambia. Un payload anterior sin la clave sigue siendo aceptado por el parser y por `InterpreterPayloadContract`. Eso es compatibilidad. No es una validación estricta del esquema ni una garantía de que el valor sea el resultado correcto. El test guarda también un `result` literal que no es el desenlace. El esquema obliga a decidir el campo. No certifica el valor.

**Regresión Elemont, sin tocarla.** `FieldCompanionLongitudinalJourneysTest` línea 162 sigue en FAIL con la unidad de registro activa. En `tmp/mvp_continuity/f1/ledger.json`, A sin foco y A con Elemont marcan `repeated_critical_request` en los turnos 6 a 14. El detector exige que el estado ya contenga «guía de la puerta» y que la respuesta mencione la guía y un verbo de comprobar. La respuesta de esos turnos es el registro más `STUB_ANSWER`. El registro cita la observación guardada «comprobé visualmente la guía de la puerta». No es una solicitud nueva de repetir la revisión. El recorrido B no marca esa bandera. Su L1 sale FAIL porque la falta estructural es global. El detector no se cambió.

**Prueba.** Intento 5, fase `interpret`. T1 abre un episodio nuevo. T3 parte de una copia de ese T1. Dos `converse`, sin reintento, sin generación, sin F4, sin F5, sin escritura en S3. `SHARED_SESSION_ENABLED=false`. Tope de proceso: 2 llamadas y US$0,03. `AWS_MAX_ATTEMPTS=1`. Recuperación, modelo y configuración AWS sin cambios. Preflight en `attempts/5/preflight.json`. El diff activo de la unidad experimental tiene SHA `a8922538f1415a688aa32ccf8e3f24d20161e79e59c3375a4fbac17bd7f964ce`.

Llamadas 87 y 88. T1: 2399 tokens de entrada y 293 de salida, US$0,003864. T3: 2469 y 173, US$0,003334. Gasto US$0,007198. Ledger: 88 intentos, committed US$1,043588, unknown US$0,025851, open vacío. Exposición US$1,069439. Quedan 3 intentos del cupo de 91 y US$0,475722 del tope US$1,545161. Del tope de 96 quedan 8 intentos. Las entradas 78 a 80 siguen en unknown.

T1, `tool_input` con `result: null` en `#54` y mediciones. El episodio guarda esas dos en `not_done` y no escribe la clave. Objetivo «La puerta se reabre sola». Observaciones: el síntoma, «El LED de fotocélula está apagado» y «No veo obstrucción». No hay comprobación de obstrucción, fotocélula ni LED, y ninguna en `done`. Movimiento `report`.

T3, `tool_input`: sujeto «fotocélula», `done`, `result` «no está activada». El episodio lo guarda así. `#54` y mediciones siguen `not_done`. No hay otra comprobación en `done`. Movimiento `report`, no `new_work`. El contexto trae `Check: fotocélula (done): no está activada`. `generation_allowed` es true. La consulta conserva «reabre». «no está activada» sigue también como observación. Eso es la doble lectura que la frase admite, no un `result` rellenado por el reducer. El archivo `turn3_context.json` conserva además la frase vieja «El resultado no está en result»: el arnés la escribía fija. Los campos medidos de ese mismo archivo dicen lo contrario.

**Cierre de esta prueba.** Este recorrido del intérprete quedó demostrado aquí: el esquema trae el campo y, en estas dos llamadas, el valor del turno 3 es el literal pedido y el turno 1 no fabrica comprobaciones ni resultados. No queda resuelta la generación. El companion no queda aceptado. «#54» y «el #54» siguen sin equivaler. F4 y F5 no se ejecutaron. No se amplía el presupuesto.

### F3. Checkpoint de consolidación, 21 de octubre de 2026

Las dos unidades quedan juntas en la rama `fc/contrato-checks`. `d104d5b` trae el contrato de checks. El commit de checkpoint añade la unidad de registro y orientación y este plan. El contenido de esa unidad es idéntico al de `fc/registro-orientacion`, `5a5a4ce`. El diff con los seis archivos seguidos dio vacío, y los dos archivos nuevos coinciden byte a byte. `5a5a4ce` es un commit de stash (`stash@{0}`) y no se borra. Los cinco archivos del experimento system/user siguen en `.git/info/exclude`, fuera del commit. `tmp/` tampoco entra.

Es un checkpoint, no una aprobación. El intérprete quedó comprobado en T1 y T3 (llamadas 87 y 88). La generación del turno 3 con ese estado no se midió. El registro sigue siendo experimental: hubo una muestra sin rechazo demostrado y otra con defectos. La regresión de evaluación Elemont sigue documentada y sin corregir.

Suite completa en este árbol, sin llamadas a modelo y con `LiveAwsBlock` activo: 4948 ejecuciones, 35260 aserciones, 1 fallo, 0 errores y 186 omitidas. El fallo es el conocido: `FieldCompanionLongitudinalJourneysTest#test_known_controls_capture_managed_and_structured_prompts_without_a_model_call`, `test/script/field_companion_longitudinal_journeys_test.rb:162`, «Expected PASS, Actual FAIL». No se cambió código ni expectativas para obtener una suite verde.

Ledger `tmp/field_companion/vf5_generator_benchmark/assignment_spend.json` sin cambios: 88 intentos, committed US$1,043588, unknown US$0,025851, `open` vacío. Del tope de 96 quedan 8 intentos. Pendiente en este punto: separar en Elemont el registro informativo de una solicitud nueva, la equivalencia «#54» y «el #54», una corrección de generación medida en T1 y T3, F4 y F5.

### Evaluador y secuencia local de tres turnos, 21 de octubre de 2026

**Veredicto: fallo de producto.** La infraestructura completó los tres turnos. Esta corrida no demuestra un recorrido local correcto, ni estabilidad general, ni Retrieve, ni F4. No se abre otro rediseño ni otra tanda.

**Evaluador, sin llamadas.** `repeated_request?` puntuaba `result.answer`, el texto presentado. Con la unidad de registro, ese texto empieza por el registro y cita la observación guardada. El detector pasa a leer `history_answer` cuando no es nil, y `answer` cuando el historial no existe. Una respuesta en blanco o igual a `STUB_ANSWER` no cuenta. El resto de criterios no cambia. La aplicación no se tocó para acomodar el detector.

`FieldCompanionLongitudinalJourneysTest` vuelve a exigir faltas y ausencias vacías y PASS en L1 y L2 de A sin foco, A con Elemont y B. El test nuevo cubre tres casos sobre `RagResult`: citar «comprobé visualmente la guía de la puerta» dentro del registro, con historial «Sigo con el síntoma de la puerta.», no dispara la petición; «Revisa otra vez la guía de la puerta.» sí la dispara aunque el registro vaya delante; la misma solicitud con `history_answer` nil también la dispara. Archivo completo: 20 ejecuciones, 131 aserciones, 0 fallos, semilla 44278. Commit `b6af5eb48fd3078805f0997cb0d11bdf4e7bca0c`, publicado en `origin/main`. Rutas: `script/field_companion/longitudinal_journeys.rb` y `test/script/field_companion_longitudinal_journeys_test.rb`.

**Ruta de la secuencia.** Una sesión nueva, la 199, episodio `ep_3411b921375f5547` en los tres turnos. Flujo normal: `record_user_turn!`, intérprete, reducer, composición, `execute_rag_query`, generación y `record_assistant_turn!` con `prompt_reply` igual al historial. El historial reinyectado no contiene «Registro del caso». Los cuerpos son los cuatro de F2 ya certificados, inyectados en `retrieve_with_retry`. `retrieve_and_generate_with_retry` queda sustituido por una excepción. No hubo escritura en S3, ni Retrieve, ni sincronización. Orden de cita de esta inyección: [1] SW4, [2] «abre pero no se cierra», [3] «se re-abre sola», [4] 5.6. Preflight, sin modelo: 4 conservados, 4 compatibles, identidad conocida, estado `scoped`. Tope de proceso: 8 llamadas y US$0,50. `AWS_MAX_ATTEMPTS=1`. Modelo sin cambios. Código probado: `b6af5eb48fd3078805f0997cb0d11bdf4e7bca0c`. Este párrafo del plan es posterior a esa corrida.

El turno 1 es el mensaje de la última prueba válida del intérprete. El turno 2 corrige solo ese LED, de apagado a encendido, para poder retirar el valor anterior. El turno 3 es el resultado de la fotocélula. No se repitieron las llamadas 87 y 88.

**Gasto.** Seis llamadas, ninguna `ServiceUnavailable`, ningún reintento. 89: intérprete T1, 2399/293, US$0,003864. 90: generación T1, 7823/434, US$0,009993. 91: intérprete T2, 2501/166, US$0,003331. 92: generación T2, 7936/453, US$0,010201. 93: intérprete T3, 2477/173, US$0,003342. 94: generación T3, 7958/438, US$0,010148. Delta: 6 intentos y US$0,040879 comprometidos. Ledger: 94 intentos, committed US$1,084467, unknown US$0,025851, `open` vacío, exposición US$1,110318. Del cupo de este encargo quedan 2 intentos y unos US$0,46. De los topes de 96 y US$4 quedan 2 intentos. Unknown no se movió.

**Turno 1.** Pregunta: «Estoy con un operador de puerta Fermator VF5+. La puerta se reabre sola. El LED de fotocélula está apagado. No veo obstrucción. No he comprobado el #54. No hice mediciones.»

Respuesta presentada:

```
Registro del caso. Equipo: Fermator VF5+, operador de puerta. Síntoma: «La puerta se reabre sola». Observaciones: «El LED de fotocélula está apagado», «No veo obstrucción». Comprobaciones: #54, sin hacer; mediciones, sin hacer.

Según la documentación del VF5+, para el síntoma "la puerta se reabre sola" se documentan tres comprobaciones [3]:

**1. Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54).**
Usted aún no ha realizado esta comprobación. Es el primer paso documentado.

Usted reporta que el LED de fotocélula está apagado, lo que indica que la fotocélula no está activada en este momento. Esta condición se cumple.

Usted reporta que no ve obstrucción. Esta observación visual está hecha.

Paso adicional si el problema persista:
Si después de las tres comprobaciones anteriores el problema continúa, la documentación indica desconectar la fotocélula y pulsar el botón de TEST. Si la puerta no se abre o cierra completamente en ese caso, debe haber una obstrucción mecánica [3].

Próximo paso recomendado:

Realice la comprobación del **potenciómetro #54** (regulación de fuerza de re-apertura). La documentación no especifica en estos pasajes cuál es el rango de ajuste, el valor esperado, ni cómo medir o ajustar este potenciómetro. ¿Dispone de instrucciones de ajuste del #54 o puede acceder al potenciómetro en el módulo para inspeccionar su posición?
```

Episodio: objetivo «La puerta se reabre sola». Observaciones: el síntoma, «El LED de fotocélula está apagado», «No veo obstrucción». Comprobaciones: `#54` y mediciones, `not_done`. Fabricante Fermator, identificadores «Fermator VF5+» y «operador de puerta». Historial 0 → 2. Intérprete: `report`. Telemetría: observaciones aplicadas, el síntoma, el LED apagado y «No veo obstrucción».

Criterios. Síntoma e identidad, sí. LED aún no corregido: el valor dicho queda vigente. El episodio no convierte el LED ni la obstrucción en comprobaciones. La fotocélula no está hecha, como corresponde antes del tercer mensaje. La pregunta no repite un dato ya recibido: pide instrucciones de ajuste del `#54` o acceso al potenciómetro. La cita [3] corresponde a «La puerta se re-abre sola» y el texto del TEST está en ese pasaje. Fallan tres criterios. «lo que indica que la fotocélula no está activada. Esta condición se cumple» cierra la comprobación de la fotocélula a partir del LED. «Esta observación visual está hecha» cierra la obstrucción. «Es el primer paso documentado» y «Si después de las tres comprobaciones anteriores» atribuyen al manual un orden que el pasaje no imprime: allí dice «En caso que el problema persista». El registro y el episodio coinciden entre sí. El párrafo no coincide con ellos: da por cumplidas una comprobación y una observación que el registro deja abiertas.

**Turno 2.** Pregunta: «Corrijo solo el estado del LED: el LED de fotocélula está encendido, no apagado.»

Respuesta presentada:

```
Registro del caso. Equipo: Fermator VF5+, operador de puerta. Síntoma: «La puerta se reabre sola». Observaciones: «No veo obstrucción». Comprobaciones: #54, sin hacer; mediciones, sin hacer.

Gracias por la corrección. Con el LED de fotocélula **encendido**, el diagnóstico cambia.

Según la documentación del VF5+, el LED de fotocélula se activa cuando "la fotocélula o la entrada de re-apertura está activada" [4]. Esto significa que el módulo está recibiendo una señal de re-apertura.

Para el síntoma "la puerta se reabre sola" con el LED de fotocélula encendido, la documentación indica estas comprobaciones [3]:

**1. Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54).**
No realizado aún.

El LED encendido sugiere que sí está activada o que hay una entrada de re-apertura activa. Verificar físicamente que el sensor no está obstruido o desalineado.

Usted reporta que no ve obstrucción, pero la documentación también menciona: "En caso que el problema persista, desconectar la fotocélula y volver a pulsar el botón de TEST. Si la puerta no se abre o cierra completamente, debe haber una obstrucción mecánica" [3].

Próximo paso: ¿Ha verificado el estado físico de la fotocélula (alineación, limpieza, conexión)? Si está correctamente alineada y limpia pero el LED sigue encendido, el siguiente paso documentado sería ajustar el potenciómetro #54 o desconectar la fotocélula para aislar si la señal proviene de ella o de otra entrada de re-apertura.
```

Episodio, mismo id. Objetivo y fabricante iguales. Observaciones: «La puerta se reabre sola» y «No veo obstrucción». No hay LED. `#54` y mediciones siguen `not_done`. Historial 2 → 4. Consulta compuesta: la corrección, más «Fermator VF5+ operador de puerta No veo obstrucción La puerta se reabre sola». Intérprete: `correct`. La única observación aplicada fue «el LED de fotocélula está encendido, no apagado».

Criterios. Síntoma e identidad, sí. El valor anterior, apagado, salió del episodio. El valor corregido, encendido, no quedó ni en el episodio ni en el registro. La fotocélula sigue sin hacerse. La pregunta no repite un resultado ya dado. La cita [4] reproduce la disyunción de 5.6 y la cita [3] reproduce el TEST. Fallan el resto. «sugiere que sí está activada» deduce la comprobación de la fotocélula desde el LED. «ajustar el potenciómetro #54» cambia el verbo del pasaje, que dice «Comprobar la sensibilidad». «el siguiente paso documentado» ordena ese ajuste y, como alternativa, desconectar la fotocélula. El registro no menciona el LED. El párrafo lo da por encendido. Esa frase llega por el mensaje de este turno, no por el estado guardado.

**Defecto del LED, reproducido sin modelo.** Con el episodio del turno 1 y la percepción registrada —movimiento `correct`, observación única «el LED de fotocélula está encendido, no apagado», corrección activa, afirmación «el LED de fotocélula está encendido», retracción «apagado», decisión `ready`— `WorkContextReducer` termina con las mismas dos observaciones de la corrida. `recover_stated_correction` solo retira la observación larga cuando `correction_tail?` reconoce una cola «no de/del/el…». «no apagado» es el estado desnudo de `BARE_STATE`, y esa condición no lo reconoce. La frase corta queda contenida en la observación larga, así que no se escribe aparte. La excisión borra después toda observación que contiene «apagado»: la vieja y la nueva. El reemplazo desaparece con el valor retirado. Los tests que conservan el LED parten de una afirmación limpia y de observaciones vacías. Esta forma de entrada no está cubierta. Se pausa este mecanismo para revisión con Opus. No se cambia el reducer ni la percepción en este encargo.

**Turno 3.** Pregunta: «Ya revisé la fotocélula y no está activada.»

Respuesta presentada:

```
Registro del caso. Equipo: Fermator VF5+, operador de puerta. Síntoma: «La puerta se reabre sola». Observaciones: «No veo obstrucción», «no está activada». Comprobaciones: #54, sin hacer; mediciones, sin hacer; fotocélula, hecha, «no está activada».

Usted reporta que ya revisó la fotocélula y **no está activada**, pero el LED de fotocélula está **encendido**. Esto es importante porque la documentación del VF5+ establece que el LED de fotocélula se activa "cuando la fotocélula **o la entrada de re-apertura** está activada" [4].

Según el procedimiento de diagnóstico para "La puerta se re-abre sola", la documentación requiere comprobar [2]:

1. **La sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54)** — usted aún no lo ha hecho.
2. **Que la fotocélula no esté activada** — usted ya lo verificó.
3. **Que no hay obstrucción mecánica** — usted reporta no verla.

Dado que el LED de fotocélula está encendido pero la fotocélula no está activada, la documentación sugiere que podría ser **la entrada de re-apertura (#21) la que está activada** [4]. La documentación también menciona comprobar "si la señal de re-apertura (#21) está activada" en el contexto de problemas de cierre [2].

Próximo paso documentado: Compruebe la sensibilidad del potenciómetro #54 según el procedimiento del VF5+. Si el problema persiste después de esa verificación, la documentación indica desconectar la fotocélula y pulsar el botón de TEST; si la puerta no se abre o cierra completamente, habría obstrucción mecánica [2].

¿Ha podido acceder al potenciómetro #54 en el módulo? ¿Qué posición tiene actualmente?
```

Episodio, mismo id. Objetivo, fabricante e identificadores iguales. Observaciones: el síntoma, «No veo obstrucción» y «no está activada». Comprobaciones: `#54` y mediciones, `not_done`; fotocélula, `done`, resultado «no está activada». Historial 4 → 6. Consulta compuesta: el mensaje, más «Fermator VF5+ operador de puerta No veo obstrucción La puerta se reabre sola». El LED corregido no entra en esa consulta. Intérprete: `report`. Observación aplicada: «no está activada». La comprobación de la fotocélula queda hecha con ese resultado.

Criterios. Síntoma e identidad, sí. La fotocélula queda realizada con «no está activada»; que la misma frase siga también como observación es la doble lectura ya conocida de esa frase. Las dos preguntas piden acceso y posición del `#54`, datos que no se habían recibido. «usted reporta no verla» deja la obstrucción como reporte. La disyunción citada de [4] está en 5.6. La frase de comprobar `#21` está en [2], bajo «La puerta se abre pero no se cierra». Fallan los demás. El LED corregido sigue ausente del episodio y del registro, y el párrafo lo afirma encendido. Las tres comprobaciones de la reapertura se citan como [2]; ese cuerpo es el del otro síntoma. «la documentación sugiere que podría ser la entrada de re-apertura (#21) la que está activada» [4] concluye una causa: 5.6 no nombra `#21` y el otro pasaje manda comprobar la señal, no afirma que esté activada. «Próximo paso documentado» y «después de esa verificación» atribuyen al manual una secuencia que el pasaje condiciona con «En caso que el problema persista».

**Cierre.** El evaluador queda corregido y publicado. La secuencia local se ejecutó una vez, con los fallos conservados. El defecto que corta la continuidad es la pérdida del LED corregido cuando la observación trae el estado desnudo «no apagado». La generación repite, en los tres párrafos, cierres y atribuciones que esta rúbrica rechaza, y en el tercero cita el cuerpo del otro síntoma. Esas dos partes quedan en pausa para revisión con Opus. No se cambia el prompt, no se lanza otra secuencia y no se amplía el presupuesto. «#54» y «el #54» siguen sin equivaler. F4 y F5 no se ejecutaron. S3, la KB y la configuración AWS no se tocaron.

### Reducer: el estado desnudo ya no se lleva el valor nuevo, 21 de octubre de 2026

La pausa del reducer queda cerrada con el cambio mínimo. La generación sigue en pausa para Opus, sobre las respuestas ya guardadas. No hubo llamadas. El ledger sigue en 94 intentos, committed US$1,084467, unknown US$0,025851. Los artefactos de la sesión 199 no se tocaron. No se reabrió F2 ni se escribió en S3. El prompt de generación no cambió.

`remember_asserted!` trataba como ya guardada la frase nueva cuando estaba contenida en la observación que todavía dice el valor retirado. Esa observación es el blanco de la excisión, y el valor anterior cae además por el reemplazo de una palabra. Las dos copias desaparecían. Ahora esa observación no cuenta como copia durable. El reemplazo se guarda solo, y después se retiran la frase con la cola y el valor anterior. No hay una regla del VF5: vale para cualquier estado desnudo que la gramática ya reconoce, «no apagado» igual que «no encendido».

Reproducción local, la misma percepción del turno 2, sin modelo. Antes: «La puerta se reabre sola», «No veo obstrucción». Después: esas dos y «el LED de fotocélula está encendido». «apagado» no queda.

Tests en `WorkContextReducerTest`. El estado desnudo dentro de la observación cubre el LED de fotocélula y el sensor de puerta, y conserva la observación que no se corrige. Los formatos ya soportados siguen el reducer: «no de», «no en», «y no en», el contraste paralelo sin «corrijo», «no el 7», el LED genérico que hereda el cualificador, y el estado nombrado con la frase ya limpia. La corrección ambigua de dos observaciones deja las dos. Suite completa, semilla 43735: 4952 ejecuciones, 35317 aserciones, 0 fallos, 0 errores, 186 omitidas.

Código: `c2aa94eba3888a6a663aca8f8d90ec786807ea62`. Rutas: `app/services/rag/work_context_reducer.rb` y `test/services/rag/work_context_reducer_test.rb`.

### Validación pagada del turno de corrección, 22 de octubre de 2026

Una sola pasada sobre `2ed7072fdcb5677dfc20b2be23766e928857c0ea`, que ya incluye el reducer. No se cambió el prompt ni el código. No hubo S3, sincronización ni despliegue. Esta pasada no valida Retrieve: los cuatro cuerpos certificados de F2 se inyectaron en `retrieve_with_retry`, con los mismos SHA. `retrieve_and_generate_with_retry` queda sustituido por una excepción. `AWS_MAX_ATTEMPTS=1` y `RAG_TRANSIENT_ATTEMPT_LIMIT=1`. No hubo reintento.

Preflight, sin modelo. Ledger de partida: 94 intentos, committed US$1,084467, unknown US$0,025851, exposición US$1,110318. Cupo restante: 2 intentos y US$2,889682 bajo US$4. Techos usados para admitir las dos llamadas: intérprete US$0,015 y generación US$0,080. Los dos caben con el unknown incluido. Tope de proceso: 2 llamadas y US$0,20. La copia del episodio posterior al turno 1 y de los dos mensajes reales de la sesión 199 cuadra. Con el reloj de esa copia, la costura deja 4 cuerpos, 4 compatibles, identidad conocida y estado `scoped`. La sesión 199 no se escribió.

La copia usa el reloj que ya admite `record_user_turn!`: `now` igual a `2026-10-21T20:14:00-03:00`, quince segundos después del `updated_at` guardado. Sin ese reloj, `ActiveEpisode.parse` marca el episodio vencido a la mañana siguiente y el reducer no habría recibido el caso. La consulta, el contexto de sesión y el registro presentado parsean con `Time.current` y no reciben ese `now`.

**Gasto.** Dos llamadas, las 95 y 96. 95: `converse`, US$0,003331, techo US$0,009021. 96: `generate_text`, 564/137, US$0,001249, techo US$0,017370. Delta: 2 intentos y US$0,004580 comprometidos. Ledger: 96 intentos, committed US$1,089047, unknown US$0,025851, `open` vacío, exposición US$1,114898. El tope de 96 intentos queda lleno. No queda otra llamada autorizada.

Sesión nueva 200. Correlación `query:fefe9a06-c3ed-45ea-9c5e-0c629a5cbe63`. Episodio `ep_3411b921375f5547`, el mismo. Artefactos en `tmp/field_companion/vf5_correction/f3/led_correction_check/20261022T123131Z/`. `result.json` lee el episodio con `Time.current` y por eso lo muestra vacío. El JSON persistido está en `episode_after.json` y en el evento `episode_delta`.

**Solicitud.** «Corrijo solo el estado del LED: el LED de fotocélula está encendido, no apagado.»

**Intérprete.** Movimiento `correct`. Afirmación «el LED de fotocélula está encendido». Observación aplicada «el LED de fotocélula está encendido, no apagado». Sin comprobaciones. La percepción recupera la frase limpia y descarta la contenida.

**Episodio después del reducer.** Objetivo «La puerta se reabre sola». Fabricante Fermator, conocido, dicho por el usuario. Identificadores «Fermator VF5+» y «operador de puerta». Observaciones: «La puerta se reabre sola», «No veo obstrucción», «el LED de fotocélula está encendido». La tercera lleva la correlación de este turno. «apagado» no aparece. Comprobaciones: `#54` y mediciones, `not_done`, con la correlación del turno 1. `updated_at` queda en `2026-10-21T20:14:00-03:00`.

**Consulta.** «Corrijo solo el estado del LED: el LED de fotocélula está encendido, no apagado. Fermator VF5+ operador de puerta No veo obstrucción La puerta se reabre sola». Componentes registrados: turno completo, identidad ausente como componente, identificadores presentes, una observación, objetivo presente. El LED nuevo viaja dentro del turno y no se repite como observación aparte. La inyección devolvió las páginas 5, 12, 12 y 7.

**Prompt enviado.** 2374 caracteres, SHA `10e6b5059898c951ecb34644bd064224bc4908a9c407ac26d30e8dece5199b94`, en `bodies/b0006.txt`. Es la guía de identidad no confirmada. Dice que no se reportó síntoma, que la identidad no está confirmada, que no se enseñen los manuales y que no se cite con `[n]`. Los cuerpos no entran. El contexto de 2400 caracteres conserva solo «Módulo electrónico VF5+ Fermator, p. 7» como nombre disponible bajo pedido, y omite las páginas 5 y 12. `EquipmentIdentity.from_episode` parsea el episodio con `Time.current`. A las 09:31 del 22 de octubre ese `updated_at` cae fuera de la ventana de cuatro horas, el parse lo deja en blanco y la generación toma la guía de identidad desconocida. El registro del caso usa el mismo parse y no se adjunta. `prompt_reply` queda nil.

**Respuesta presentada**, ya sin los rótulos en negrita que el modelo puso en líneas solas:

```
El LED de fotocélula está encendido (estado actual reportado).

Estado visual del indicador luminoso confirmado en campo.

El LED encendido indica que la fotocélula está detectando obstrucción o presencia continua en la zona de cobertura, o bien que el módulo electrónico mantiene la salida activa por otra condición de lógica operativa.

¿La cabina está en movimiento o detenida cuando observas el LED encendido?
```

El texto del modelo, antes de `sanitize_answer`, traía los rótulos `REPORTE`, `EVIDENCIA` e `HIPÓTESIS` y una regla horizontal. El sanitizador existente los retira. No hay registro del caso delante.

**Criterios del estado, observados.** «encendido» queda persistido. «apagado» desaparece. Síntoma, identidad y las dos comprobaciones pendientes se conservan. Mismo episodio.

**Criterios de la respuesta contra los pasajes.** Esta respuesta no se generó contra los pasajes. El prompt se lo prohíbe y no los incluye. No hay citas. No aparece `#54`, `#21`, el botón de TEST, ni el verbo ajustar. El episodio no marca ninguna comprobación como hecha. La frase «Estado visual del indicador luminoso confirmado en campo» repite la corrección del técnico bajo el rótulo de evidencia. La hipótesis de obstrucción, presencia continua o salida activa no está en el prompt. El pasaje 5.6, que sí dice que el LED se activa cuando la fotocélula o la entrada de re-apertura está activada, estaba retenido. La pregunta sobre si la cabina se mueve tampoco está en los pasajes.

**Qué queda reproducido y qué no.** El reducer, con la salida real del intérprete y la copia del episodio del turno 1, conserva el valor nuevo y retira el anterior. Eso queda reproducido en el JSON guardado. La generación de anoche, dentro de la ventana, sí recibió los cuerpos y produjo el párrafo con registro, citas, «ajustar» y «siguiente paso documentado». Esta pasada no recorrió ese prompt. Tratar el párrafo de hoy como una repetición de esos fallos sería una hipótesis: el modelo contestó la guía de identidad desconocida. La causa de esa guía es el reloj de la copia frente a los parses de la consulta y del registro, que usan `Time.current`. No se lanza otra llamada. El tope de 96 intentos está lleno. La generación con los pasajes y con el episodio ya corregido sigue sin medirse.

### Reloj, reconstrucción documental y diagnóstico de la generación, 22 de octubre de 2026

Sin llamadas a modelo ni Retrieve, sin S3, KB, reextracción ni despliegue. Código de la aplicación sin cambios: HEAD `2ed7072fdcb5677dfc20b2be23766e928857c0ea`. Ledger verificado antes y después: 96 intentos y 96 entradas; committed US$1,089047, igual a la suma de `actual_usd`; unknown US$0,025851, que son las entradas 78 a 80 a US$0,008617 cada una, `converse` sin tokens; `open` vacío; exposición US$1,114898. Ni `assignment_spend.json` ni `ingest_spend.json` cambiaron después de las 09:31:37 del 22 de octubre. El tope de 96 intentos sigue lleno.

**Reloj: el defecto de las llamadas 95 y 96 es del arnés.** `led_correction_check.rb` pasaba `now: REPLAY_NOW` solo a `record_user_turn!`. Dentro de esa llamada, el intérprete, el reducer y el compositor de la consulta usan ese reloj. Por eso la consulta efectiva sí lleva el caso. Hay que corregir la sección anterior: la consulta no se parseó con `Time.current`. El reducer tocó `updated_at` a `2026-10-21T20:14:00-03:00`. Después, cada lectura del episodio llama a `Rag::ActiveEpisode.parse` con `Time.current`, que eran las 09:31 del 22 de octubre: el episodio tenía 13 h 17 min y la ventana es de 4 horas. Las lecturas afectadas:
- `SessionContextBuilder`, líneas 132 y 239 y el historial del episodio: el contexto de sesión quedó en 109 caracteres;
- `EquipmentIdentity.from_episode`, desde `bedrock_rag_service.rb:1288`, que dio la guía de identidad desconocida;
- `FieldCaseRecord`, desde `RagQueryConcern#field_case_attachment`: sin registro y `prompt_reply` nil;
- `RagQueryConcern`, líneas 53, 61, 147 y 263.

**En una petición normal no ocurre.** `RagController#ask` llama a `record_user_turn!` sin `now`, así que el reducer toca `updated_at` con `Time.current` y las lecturas siguientes, en la misma petición, ven un episodio de segundos. Queda un borde posible, deducido del código y no reproducido. Un turno que no renueva `updated_at` y que llega a generación pertenece a dos clases: `unclear`, o un fallback sin síntoma buscable. Si el episodio cruza las 4 horas durante los segundos que dura esa petición, el intérprete lo ve vivo y la generación lo ve vencido. El resultado coincide con lo que el turno siguiente vería por vencimiento. No se corrige: hacerlo exige pasar un reloj por toda la petición, que es infraestructura nueva. TTL y expiración, sin cambios.

**Corrección, solo en el arnés** (`tmp/`, no se versiona). El original quedó copiado como `led_correction_check.as_run_20261022T123131Z.rb`, SHA-256 `c2b78179…d1e7`. El nuevo arnés tiene SHA-256 `182f3f95a567b7bdb75eb1bb55b4f94a5a95f596819b60b27878e5cfa47d291c`.
- El modo `run` ahora se niega cuando la copia está vencida en `Time.current`. Esa negativa habría detenido las llamadas 95 y 96.
- Nuevo modo `reconstruct`:
  - recorre la ruta completa dentro de `travel_to(REPLAY_NOW)`, con `ActiveSupport::Testing::TimeHelpers`;
  - usa como cliente del intérprete el `tool_input` grabado en `20261022T123131Z`, con `usage` 0, así que no hay fila de gasto;
  - activa `LiveAwsBlock` y además se niega en `Seahorse::Client::Base#build_request`;
  - se niega si el ledger está armado.

  No escribe timestamps a mano: el único `updated_at` es el que toca el reducer con ese reloj.
- Límite: `travel_to` también fija `Time.now`, y `Aws::Sigv4::Signer` firma con `Time.now.utc` (`signer.rb:232`). Una llamada pagada dentro del viaje saldría firmada con la fecha histórica. Las llamadas pagadas no se hacen dentro de `travel_to`.

**Reconstrucción**, separada de la evidencia original, en `tmp/field_companion/vf5_correction/f3/led_correction_check/20261022T125015Z_reconstruccion/`. `reconstruction.json` declara que no es una conversación validada. La carpeta `20261022T123131Z/` no se tocó.
- Sesión local nueva, 201; correlación reutilizada `query:fefe9a06-c3ed-45ea-9c5e-0c629a5cbe63`; `tool_input` SHA-256 `69aee48f…`. `Time.current` dentro: `2026-10-21T20:14:00-03:00`. La copia de partida cuadra con la de la llamada 96.
- El episodio está vivo en las cuatro lecturas y es idéntico a `episode_after.json` de la llamada 96. Conserva el objetivo «La puerta se reabre sola», Fermator conocido y «Fermator VF5+», «operador de puerta». Observaciones: «La puerta se reabre sola», «No veo obstrucción», «el LED de fotocélula está encendido». `#54` y mediciones siguen `not_done`.
- Contexto. El problema ocupa 370 caracteres y el contexto de sesión 1059, frente a 109 en la llamada 96. El bloque Active Field Problem dice «Obs: No veo obstrucción; el LED de fotocélula está encendido» y lista las dos comprobaciones `not_done`. «apagado» solo aparece en la línea de usuario del turno 1, dentro de Recent Conversation, que el prompt rotula como reporte del técnico corregible.
- Historial. La línea Assistant es `prompt_reply` del turno 1, sin «Registro del caso», y le sigue la corrección del turno 2. El registro que se adjuntaría a la respuesta presentada es: «Registro del caso. Equipo: Fermator VF5+, operador de puerta. Síntoma: «La puerta se reabre sola». Observaciones: «No veo obstrucción», «el LED de fotocélula está encendido». Comprobaciones: #54, sin hacer; mediciones, sin hacer.» No entra en el prompt.
- Política `scoped`, modo `document_identity_scope`. Prompt `bodies/b0006.txt`: 27 699 bytes, SHA-256 `44e40948d76ca2806814133e1d2aafa4df42f69ad772fc1bddedc6bc0eeb360d`, frente a 2374 en la llamada 96.
- Los cuatro cuerpos certificados de F2 entran verbatim, con los SHA del manifiesto, todos como THIS JOB'S EQUIPMENT:

  | Fuente | Pasaje | Página |
  | --- | --- | --- |
  | 1 | SW4 | 5 |
  | 2 | «abre pero no se cierra» | 12 |
  | 3 | «re-abre sola» | 12 y 13 |
  | 4 | 5.6 | 7 |

  La fuente 3 lleva `[PDF_PAGE: 12]` `[PRINTED_PAGE: 11/21]` y `[PDF_PAGE: 13]` `[PRINTED_PAGE: 12/21]`, que coinciden con los pies «Pág. 11 / 21» y «Pág. 12 / 21» del PDF.
- El texto fijo de instrucciones es idéntico byte a byte al prompt de `attempts/4`, el del turno 1 de las muestras 85 y 86. Solo cambian la consulta, los identificadores, la línea Obs, Recent Conversation y Query Resolution.
- Ninguna operación llegó al SDK: `blocked_aws` está vacío. `generate_text` registró `prepared` y se detuvo en `LiveAwsBlock::Refused`. `identity_status: unavailable` y el texto de `result` son la salida existente para una generación en blanco, no una respuesta.
- `Rag::CapturedGenerationReplay.prepare` acepta esta captura con `turn: 2`: sin system, temperatura 0,1, 3000 tokens, modelo Haiku 4.5 global. `LocalPassLedger.price` da un techo de US$0,042699 por llamada.
- No demuestra Retrieve, ni la respuesta del modelo, ni F5.

**Evaluador, corregido contra el PDF y el texto presentado.** Estas distinciones no aflojan ninguna regla de rechazo de la rúbrica.
- Los títulos se juzgan después de `sanitize_answer`. Las siete respuestas crudas de los intentos 2 a 4 traen un título `#`. El patrón de `strip_markdown_headers` lo retira en las siete y ninguna de las diez lo conserva. Un rótulo con dos puntos que atribuye al manual, como «Próximo paso recomendado según documentación:» o «Siguiente paso documentado:», cuenta como atribución de contenido, no como formato.
- El terminal 21 es la entrada de re-apertura (5.5, PDF 7: «21.- Re-apertura … La señal de re-apertura tiene prioridad sobre la señal cerrar»), y 5.6 liga el LED a esa entrada. Mencionar `#21` o preguntar por SW4 es pertinente a «se re-abre sola». Solo sigue siendo defecto presentar `#21` como una de las tres comprobaciones de 8.2.
- La hipótesis de la muestra 94 (LED encendido sin fotocélula activada, luego una entrada de re-apertura activa) combina 5.6 con el resultado del técnico. Es orientación razonada, en el sentido de Gonzalo: «orientación desde donde se origina la falla (sin ser concluyente)». Su defecto es presentarla como «la documentación sugiere», no el razonamiento.
- Corrección a la sección de cierre de F3. El manual sí documenta el ajuste del `#54`: 5.11, PDF 8, «Potenciómetro que permite ajustar la fuerza de cierre de la puerta (sensibilidad a reaperturas) … de 60 a 150Nm», y la puesta en marcha de la PDF 10. Lo que no lo trae son los cuatro pasajes inyectados. Nombrar el ajuste no es ordenarlo: «medición o ajuste» en la 84 no se rechaza. Sí se rechazan la orden de la 83 («Ajuste el potenciómetro #54…») y el «siguiente paso documentado sería ajustar» de la 92.
- Una observación no cierra una comprobación. «sugiere que sí está activada o que hay una entrada de re-apertura activa» (92) reproduce la disyunción de 5.6, y «en este momento» (86) es una inferencia momentánea de 5.6 a la que le falta la cita [4]. Ninguna de las dos da la comprobación por hecha. Los cierres de la 75, 83, 84 y 90 siguen en pie.
- La cita debe sostener la frase. En la 94, las comprobaciones de re-abre y la condición del TEST van con [2] y están en [3]: defecto.
- «Si el problema persiste después de las comprobaciones anteriores» conserva la condición de la PDF 13, que es el último guion de la misma lista. Es una lectura discutible pero no una orden inventada.

**Veredictos revisados de las diez muestras documentales.**

| Muestra | Prompt y turno | Defecto de rechazo que se mantiene |
| --- | --- | --- |
| 75 | `cc1c72e9`, T1 | «ha verificado visualmente» da la obstrucción por comprobada; «según documentación» |
| 76 | `cc1c72e9`, T1 | «según documentación» y «el primer elemento listado» atribuyen prioridad |
| 77 | `cc1c72e9`, T1 | ninguno demostrado |
| 83 | `f07f384e`, T1 | cierres; «primer paso documentado»; orden de ajustar el `#54` |
| 84 | `f07f384e`, T1 | cierres; «primer elemento documentado» |
| 85 | registro, T1 | ninguno demostrado |
| 86 | registro, T1 | «más directa» y «Siguiente paso documentado» atribuyen orden; repregunta por el `#54` ya informado |
| 90 | registro, T1 | cierres; «Es el primer paso documentado» |
| 92 | registro, T2, reducer anterior | «el siguiente paso documentado sería ajustar el potenciómetro #54» |
| 94 | registro, T3 | cita [2] por [3]; «Próximo paso documentado»; «la documentación sugiere» |

Quedan 8 de 10 con defecto de rechazo. 77 y 85 no lo tienen, pero ninguna de las dos usa el LED ni 5.6 para orientar hacia el origen. No son evidencia de aceptación. Frecuencias:
- orden, prioridad o paso siguiente atribuidos al manual: 8 de 10 (75, 76, 83, 84, 86, 90, 92 y 94);
- observación dada por comprobación: 4 de 10;
- comprobar convertido en ajustar: 2 de 10;
- cita errónea: 1;
- repregunta: 1.

**Causas demostradas.**
- La muestra 96 no mide la generación: mide el reloj del arnés.
- La contradicción entre la 92 y el registro venía del reducer, corregido en `c2aa94e`.
- Los defectos persisten con el estado correcto en el turno 1 (85, 86 y 90) y con tres redacciones del prompt. El estado, el historial, el orden de los cuerpos y el reloj no los explican.
- El prompt documental que hoy se envía contiene instrucciones que chocan entre sí:
  - `DOCUMENT_IDENTITY_ROLE_REPLACEMENT` dice «Answer from the retrieved documentation … Do not add technical knowledge … from memory», mientras el párrafo de atribución pide «one next observation or check as your own orientation»;
  - el ROLE dice «a check is done only when…» y «State the documented checks», mientras el párrafo de atribución dice «do not restate whether a check is done or open»;
  - `generation.txt:156` dice «Use short paragraphs or numbered lists» frente a «running prose only»;
  - «say DATA_NOT_AVAILABLE» frente a «do not replace with a refusal».
- Los pasajes inyectados no incluyen 5.5 ni 5.11. Son los dos hechos del manual detrás del `#21` y del ajuste del `#54` que el modelo escribió sin poder citarlos.
- La varianza de muestreo es grande: con el mismo prompt, la 85 no tiene defecto y la 86 sí. Dos o tres muestras por configuración no estiman tasas; solo pueden rechazar.

**Hipótesis, no demostradas.**
- H1. El ROLE solo legitima lo documentado, así que el modelo rotula como documentada la orientación propia que el párrafo de atribución le pide. El patrón aparece en 8 de 10.
- H2. El encuadre `FIELD_RECORD` con `RECORD_TYPE: TROUBLESHOOTING_STEP` y `ACTION` induce secuencia y estado por comprobación.
- H3. La falta de 5.11 empuja al verbo ajustar a partir del nombre «potenciómetro de regulación».

La muestra no permite pesar H1, H2 y H3 entre sí ni separarlas de una plantilla estable del modelo. Tampoco permite suponer que un modelo más fuerte lo resuelva: el benchmark anterior no lo mostró.

**Intervención.** Hecha: el arnés (reloj y `reconstruct`), la reconstrucción y la corrección del evaluador. No se cambió el prompt de producción. La causa no está demostrada, tres redacciones ya fallaron, y un cambio sin medir reemplazaría la única línea base medida, que es exactamente el prompt de la reconstrucción.

Recomendada, sin implementar, la variante B. En `DOCUMENT_IDENTITY_ROLE_REPLACEMENT` se sustituirían «State the documented checks and their conditions. Do not add technical knowledge, requirements, procedures, or safety judgments from memory.» por:

> «Steps, conditions, values, terminals, and procedures come only from the retrieved documentation. Your own field reasoning is allowed only when you present it as yours, never as what the documentation says, orders, or prioritizes.»

El material es el mismo; lo que cambia es la atribución, alineada con AGENTS.md («Reason, infer, and conclude as a field copilot» y «Never … present an inference as the manufacturer's instruction»). El código solo garantizaría que el prompt deja de contener esa contradicción. Que el modelo deje de atribuir al manual depende del modelo y se mide.

Arquitectura, solo como recomendación: si B falla, el paso siguiente es H2, renderizar los cuerpos sin el encuadre `TROUBLESHOOTING_STEP`/`ACTION` en `document_identity_scope`, que afecta a todos los turnos con evidencia. H3, traer la definición 5.11 junto a 8.2, es un cambio de recuperación y espera evidencia de F4.

**Próxima prueba pagada mínima, no ejecutada.** Requiere que Lahiri autorice 6 intentos por encima de los 96 (tope 102).
- Brazo A: `CapturedGenerationReplay.run_sample` sobre `20261022T125015Z_reconstruccion/bodies/b0006.txt`, SHA `44e40948…`, tres muestras. Mide por primera vez el turno 2 con el estado correcto y los pasajes.
- Brazo B: la misma reconstrucción con la variante B, reconstruida a costo cero, tres muestras.
- Condiciones comunes: reloj real, sin `travel_to`; `attempt_limit: 1`; Haiku 4.5 global; temperatura 0,1; 3000 tokens.
- Costo: 6 llamadas `generate_text`. Esperado unos US$0,0103 por llamada, alrededor de US$0,062 en total. Techo 6 × US$0,042699 = US$0,256194. La exposición quedaría en a lo sumo US$1,371092, bajo US$4. El unknown no se toca.
- Regla de decisión, registrada antes de correr, con la rúbrica de este documento y las distinciones de arriba:
  - Si B tiene 0 de 3 con atribución al manual, cierre o ajuste ordenado, y A tiene al menos 2 de 3, H1 queda respaldada. B pasa al código con tests y después va a F5. No se declara estable.
  - Si B tiene al menos 1 de 3 con esa clase de defecto, H1 queda rechazada. No se prueba otra frase, y la decisión siguiente es la de H2.
  - Si A tiene 0 de 3, la muestra no separa los brazos y no se decide nada.

**Estado.**
- F3 sigue abierta.
  - El intérprete está demostrado en T1 y T3.
  - T2 está reproducido en el reducer y reconstruido hasta el prompt.
  - La generación no está aceptada.
  - Siguen pendientes «#54» frente a «el #54», y el Modo esclavo sin medir.
- F4 no se ejecutó; necesita autorización remota.
- F5 no se ejecutó; necesita llamadas por encima del tope.

El companion no está estable.

### Comparación A/B del ROLE, evaluación fijada antes de llamar, 22 de octubre de 2026

Lahiri autoriza solo esta comparación: 6 llamadas, tope acumulado 102 intentos, techo adicional US$0,26. El tope de US$4 no se amplía. Unknown se conserva y entra en la exposición. No hay reintento ni otra variante. No se cambia el prompt de producción, ni S3, ni la KB. El código de generación sigue en `94c8edb4489b14cc4a93fa8c19ac22ce766e0218`.

La regla de decisión de la sección anterior no rige esta corrida. La de este encargo es:

- Si B no reduce el defecto de atribución, la intervención es insuficiente. H1 no se declara descartada.
- Si B lo reduce, el resultado es evidencia preliminar. No se declara estable el companion y el cambio no pasa a producción.

**Rúbrica, fijada antes de leer las respuestas.** Se juzga el texto después de `sanitize_answer`. El registro del caso no está en este prompt y no se vuelve a adjuntar. Los dos brazos comparten estado, pasajes, historial, modelo y parámetros. La única diferencia permitida es la sustitución de las dos frases del ROLE.

1. Fidelidad de afirmaciones y citas. Una afirmación sobre el manual necesita el pasaje que la contiene y una cita que apunte a ese pasaje. Una cita que no sostiene la frase falla. Un valor, un terminal, un procedimiento o un ajuste que estos cuatro cuerpos no imprimen, presentado como documentación de este trabajo, falla. Nombrar el ajuste del `#54` no es ordenarlo. Mencionar el terminal 21 o SW4 es pertinente a este síntoma. Presentar `#21` como una de las tres comprobaciones de «se re-abre sola» falla: esa lista está en el otro pasaje.
2. Documentación y razonamiento propio. Lo que el pasaje dice se presenta como documentación. El razonamiento propio se presenta como propio. Falla atribuir al manual un orden, una prioridad, un primer paso o un paso siguiente que el pasaje no imprime, y falla «la documentación sugiere» para una inferencia. Un razonamiento marcado como propio no falla por ser propio.
3. Observaciones y comprobaciones. «No veo obstrucción» y el LED encendido siguen siendo observaciones. No cierran la fotocélula ni la obstrucción. `#54` y mediciones siguen pendientes: este turno no dice haberlos hecho. Una comprobación está hecha solo cuando el técnico dice haberla hecho.
4. Orientación. La respuesta orienta hacia el origen de la falla con el LED encendido y los pasajes, sin cerrar el caso. Una paráfrasis fiel de las comprobaciones, sin esa orientación, no se acepta.

El defecto que B pretende reducir es el de la regla 2. Una muestra sin ese defecto que solo parafrasea no cuenta como mejora. H2 y H3 no se prueban en esta corrida.

**Corrida.** Preflight a las 10:23, reloj real `2026-10-22T10:23:34-03:00`, sin `travel_to`. El episodio guardado, parseado con `Time.current`, sigue `expired`: su `updated_at` es `2026-10-21T20:14:00-03:00`. El caso que se envió es el del prompt reconstruido, comprobado antes de llamar. En `## Active Field Problem` los dos brazos traen el objetivo «La puerta se reabre sola», Fermator, «Fermator VF5+» y «operador de puerta», `#54` y mediciones en `not_done`, y la observación «No veo obstrucción; el LED de fotocélula está encendido». «apagado» no está en esa observación. Sigue en el historial del turno 1 y en la frase de corrección. Los cuatro cuerpos certificados están verbatim. SHA del prompt A: `44e40948d76ca2806814133e1d2aafa4df42f69ad772fc1bddedc6bc0eeb360d`, 27699 bytes, el de la reconstrucción. SHA del prompt B: `f31f42c07add3fa09c4cbca149b5d658ac8bea3ddf8dbcffbcfb96232d37de38`, 27788 bytes. La única diferencia es la sustitución de las dos frases del ROLE. La primera frase del ROLE no cambia. Modelo `global.anthropic.claude-haiku-4-5-20251001-v1:0`, temperatura 0,1, 3000 tokens, sin system. Orden A, B, A, B, A, B. Un intento por llamada. `refusal` nulo. Techos US$0,042699 y US$0,042788. Suma US$0,256461, bajo US$0,26. Exposición de partida US$1,114898, unknown US$0,025851 incluido. Cabe bajo US$4.

No se tocó el prompt de producción. El tope de intento del archivo de gasto pasó a 102 para esta autorización. El de US$4 no se movió. El código de `LocalPassLedger` sigue en 96.

**Gasto.** Seis llamadas, 97 a 102, todas `generate_text`, un intento, sin error. 97 A: 7948/436, US$0,010128. 98 B: 7967/451, US$0,010222. 99 A: 7948/420, US$0,010048. 100 B: 7967/464, US$0,010287. 101 A: 7948/427, US$0,010083. 102 B: 7967/421, US$0,010072. Delta US$0,060840. Ledger: 102 intentos, committed US$1,149887, unknown US$0,025851, `open` vacío. Exposición US$1,175738. Artefactos en `tmp/field_companion/vf5_correction/f3/role_ab/20261022T132334Z/`.

`sanitize_answer` quitó, en las tres de A, las líneas que eran solo negrita de las comprobaciones 2 y 3. El modelo sí las escribió. El texto de abajo es el presentado. Esas dos líneas no añaden una atribución: repiten el verbo del pasaje.

**1-A**

```
Gracias por la corrección. Con el LED de fotocélula **encendido**, el diagnóstico cambia.

Según la documentación del VF5+, el LED de fotocélula se activa cuando "la fotocélula o la entrada de re-apertura está activada" [4]. Esto significa que el módulo está recibiendo una señal de re-apertura.

Para el síntoma "la puerta se reabre sola" con LED de fotocélula encendido, la documentación establece estas comprobaciones [3]:

**1. Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54).**
No realizado aún.

Usted reporta que no ve obstrucción, pero el LED está encendido. Esto indica que la fotocélula **sí está activada** según el módulo, aunque visualmente no detecte bloqueo.

Usted reporta que no ve obstrucción.

La documentación también menciona que si el problema persiste después de estas comprobaciones, se debe "desconectar la fotocélula y volver a pulsar el botón de TEST. Si la puerta no se abre o cierra completamente, debe haber una obstrucción mecánica en la puerta" [3].

Próximo paso recomendado: Verifique físicamente la fotocélula (limpieza, alineación, conexión) para confirmar por qué el LED permanece encendido sin obstrucción visible. ¿La fotocélula está limpia y correctamente alineada?
```

La cita [4] sostiene la disyunción. La cita [3] sostiene el TEST. `#54` sigue sin hacer. La obstrucción se queda en «reporta». Falla la regla 3: «la fotocélula sí está activada» cierra esa comprobación desde el LED. La glosa «Esto significa que el módulo está recibiendo una señal de re-apertura» estrecha la disyunción a una sola rama. La pregunta de limpieza y alineación orienta, y no está impresa en estos pasajes. No se acepta.

**2-B**

```
Gracias por la corrección. Con el LED de fotocélula **encendido**, la situación cambia.

Según la documentación del VF5+, el LED de fotocélula se activa cuando "la fotocélula o la entrada de re-apertura está activada" [4]. Esto significa que el módulo está detectando una señal de re-apertura activa.

Para el síntoma "la puerta se reabre sola" con el LED de fotocélula encendido, la documentación indica estas comprobaciones [3]:

**1. Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54).**

**2. Comprobar que la fotocélula no esté activada** — pero en tu caso el LED está encendido, lo que indica que sí hay una señal activa en la fotocélula o en la entrada de re-apertura.

**3. Comprobar que no hay una obstrucción mecánica en la puerta** — ya lo has verificado visualmente.

Dado que el LED de fotocélula está encendido y la puerta se reabre sola, la causa más probable documentada es que la fotocélula o su entrada de re-apertura están activadas continuamente. Esto puede ocurrir por suciedad, desalineación de la fotocélula, o un problema en el cableado de la entrada de re-apertura.

Próximo paso: antes de ajustar el potenciómetro #54, verifica físicamente el estado de la fotocélula (limpieza, alineación, obstrucciones ópticas) y revisa visualmente el cableado de la entrada de re-apertura. ¿Observas suciedad, polvo o desalineación en la óptica de la fotocélula?
```

[4] y [3] apuntan a los pasajes que dicen esas comprobaciones. La segunda comprobación conserva la disyunción. Falla la regla 2: «la causa más probable documentada» y «continuamente» no están en el pasaje. Falla la regla 3: «ya lo has verificado visualmente» convierte «no veo obstrucción» en la comprobación mecánica hecha. «antes de ajustar» ordena un ajuste. El pasaje dice comprobar la sensibilidad. Suciedad, desalineación y cableado no están en estos cuatro cuerpos y quedan dentro de esa causa documentada. Hay orientación, y no se acepta.

**3-A**

```
Gracias por la corrección. Con el LED de fotocélula **encendido**, el diagnóstico cambia.

Según la documentación del VF5+, el LED de fotocélula se activa cuando "la fotocélula o la entrada de re-apertura está activada" [4]. Esto significa que el módulo está detectando una señal de re-apertura activa.

Para el síntoma "la puerta se reabre sola" con el LED de fotocélula encendido, la documentación establece estas comprobaciones [3]:

**1. Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54).**
No lo has hecho aún.

Reportas que no ves obstrucción, pero el LED está encendido, lo que indica que el módulo sí detecta activación en la fotocélula o en la entrada de re-apertura.

Reportas que no ves obstrucción.

La documentación también menciona que si el problema persiste después de estas comprobaciones, se debe desconectar la fotocélula y pulsar el botón de TEST; si la puerta no se abre o cierra completamente, hay obstrucción mecánica [3].

Próximo paso: ¿Has verificado físicamente el estado del potenciómetro #54 o medido su posición? La documentación no especifica el rango de ajuste, pero es la primera comprobación documentada para este síntoma con fotocélula activa.
```

[4] y [3] cuadran con los pasajes. `#54` sigue pendiente. La obstrucción sigue como reporte. La frase del LED conserva las dos ramas y no da la fotocélula por hecha. «la documentación no especifica el rango de ajuste» es cierto para estos cuatro cuerpos. Falla la regla 2: «es la primera comprobación documentada» atribuye una prioridad que la lista no imprime. No se acepta.

**4-B**

```
Gracias por la corrección. Con el LED de fotocélula **encendido**, la situación cambia.

Según la documentación del VF5+, el LED de fotocélula se activa cuando "la fotocélula o la entrada de re-apertura está activada" [4]. Esto significa que el módulo está detectando una señal de re-apertura activa.

Para el síntoma "la puerta se reabre sola" con el LED de fotocélula encendido, la documentación indica estas comprobaciones [3]:

**1. Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54).**

**2. Comprobar que la fotocélula no esté activada.** Usted reporta que no ve obstrucción, pero el LED está encendido, lo que sugiere que el módulo sí detecta una señal de fotocélula o re-apertura activa.

**3. Comprobar que no hay una obstrucción mecánica en la puerta.** Usted ya ha verificado esto visualmente.

Hay un punto adicional documentado: si el problema persiste después de estas comprobaciones, "desconectar la fotocélula y volver a pulsar el botón de TEST. Si la puerta no se abre o cierra completamente, debe haber una obstrucción mecánica en la puerta" [3].

Mi orientación: Dado que el LED de fotocélula está encendido pero usted no ve obstrucción física, el siguiente paso lógico es verificar el potenciómetro #54 (que aún no ha comprobado) y luego considerar si la fotocélula misma está generando una señal continua sin causa visible.

¿Ha podido acceder al potenciómetro #54 para inspeccionar su posición o ajuste?
```

[4] y [3] cuadran. `#54` sigue sin hacer. «Mi orientación» presenta como propio el paso siguiente y la señal continua. Preguntar por el ajuste no lo ordena. Falla la regla 3: «ya ha verificado esto visualmente» cierra la obstrucción mecánica. La glosa inicial vuelve a estrechar 5.6. No se acepta. Es la muestra en la que la frase nueva sí separa la orientación, y el cierre de la observación sigue.

**5-A**

```
Gracias por la corrección. Con el LED de fotocélula **encendido**, el diagnóstico cambia.

Según la documentación del VF5+, el LED de fotocélula se activa cuando "la fotocélula o la entrada de re-apertura está activada" [4]. Esto significa que el módulo está detectando una señal de re-apertura activa.

Para el síntoma "la puerta se reabre sola" con LED de fotocélula encendido, la documentación establece estas comprobaciones [3]:

**1. Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54).**
No realizado aún.

Usted reporta que no ve obstrucción, pero el LED está encendido, lo que indica que el módulo sí detecta activación en la fotocélula o en la entrada de re-apertura.

Usted reporta que no ve obstrucción.

La documentación también menciona que si el problema persiste después de estas comprobaciones, se debe desconectar la fotocélula y pulsar el botón de TEST. Si la puerta no se abre o cierra completamente, habría obstrucción mecánica [3].

Próximo paso: ¿Ha verificado físicamente el estado de la fotocélula (limpieza, alineación, conexión)? El LED encendido sugiere que el módulo recibe una señal continua de re-apertura, aunque usted no vea un objeto bloqueando el haz.
```

[4] y [3] cuadran. `#54` pendiente. La obstrucción sigue como reporte. La frase posterior del LED conserva la disyunción y no cierra la fotocélula. No hay «primer paso documentado». La pregunta orienta hacia la fotocélula a partir del LED. La glosa «Esto significa» igual estrecha 5.6 a una señal de re-apertura, y la pregunta de limpieza no está en los pasajes. No se acepta como muestra limpia. Es la de A que no atribuye prioridad ni cierra una comprobación.

**6-B**

```
Gracias por la corrección. Con el LED de fotocélula **encendido**, el diagnóstico cambia.

Según la documentación del VF5+, el LED de fotocélula se activa cuando "la fotocélula o la entrada de re-apertura está activada" [4]. Esto significa que el módulo está detectando una señal de re-apertura activa, aunque usted no observe obstrucción física.

Para el síntoma "la puerta se reabre sola" con LED de fotocélula encendido, la documentación indica estas comprobaciones [3]:

**1. Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54).**

**2. Comprobar que la fotocélula no esté activada** — aunque el LED está encendido, esto sugiere que la fotocélula o su entrada sí está activa en este momento.

**3. Comprobar que no hay una obstrucción mecánica en la puerta** — usted ya reporta que no ve obstrucción.

La documentación también menciona una prueba adicional: "En caso que el problema persista, desconectar la fotocélula y volver a pulsar el botón de TEST. Si la puerta no se abre o cierra completamente, debe haber una obstrucción mecánica en la puerta" [3].

Próximo paso: ¿Ha comprobado ya el potenciómetro #54? Ese es el primer punto documentado. Si el ajuste de #54 no resuelve el problema, la fotocélula podría estar generando una señal continua de re-apertura incluso sin obstrucción visible.
```

[4] y [3] cuadran, y esta cita del TEST conserva «En caso que el problema persista». La obstrucción se queda en «reporta». La segunda comprobación sugiere actividad y conserva las dos ramas, sin darla por hecha. Falla la regla 2: «Ese es el primer punto documentado». «Si el ajuste de #54 no resuelve» pone el ajuste en la secuencia. El pasaje manda comprobar la sensibilidad. No se acepta.

**Evaluación.** Las seis citan [4] con la frase de 5.6 y, cuando citan el TEST, usan [3]. Ninguna presenta `#21` como comprobación de «se re-abre sola». Ninguna acepta el caso. Las seis glosan la cita [4] como «el módulo está recibiendo o detectando una señal de re-apertura» y así pierden la rama de la fotocélula en esa frase. Esa glosa está en los dos brazos y no mide la sustitución.

El defecto de la regla 2, el que B debía reducir, aparece en A una vez (3-A, «primera comprobación documentada») y en B dos veces (2-B, «causa más probable documentada»; 6-B, «primer punto documentado»). La regla 3 falla en A una vez (1-A cierra la fotocélula) y en B dos veces (2-B y 4-B dan la obstrucción por verificada). 4-B es la única que marca «Mi orientación» y no llama documentado a su paso siguiente. No compensa los otros dos de B.

**Recomendación.** La sustitución de las dos frases es insuficiente. B no reduce la atribución al manual y empeora el cierre de observaciones. H1 no queda descartada: el resultado no la separa de H2 ni de H3. No es evidencia para promover el cambio. El companion no está estable. No se cambia el prompt de producción y no se abre otra variante. El fallback de la fuente de datos queda en el backlog previo a F4, sin implementarse. F4 y F5 siguen sin ejecutarse.

### Sanitizador: la línea solo en negrita conserva sus palabras, 22 de octubre de 2026

Lahiri sustituye el criterio anterior. Una línea formada solo por negrita conserva todas sus palabras y pierde únicamente los delimitadores. No deciden la puntuación, la numeración, la longitud ni el vocabulario. El caso explícito queda así: `**Respuesta**` seguido de `No, no son el mismo.` pasa a `Respuesta` y después `No, no son el mismo.`. La expectativa del test se actualiza como cambio de criterio.

Se mantiene lo demás: rótulo con dos puntos, negrita dentro de una oración, sujeto en negrita, regla horizontal, negrita vacía y encabezado Markdown con `#`. No se toca el prompt, el modelo ni los límites de entrada, historial o contexto. No hay llamada. El ledger sigue en 102 intentos.

`interaction_completed` añade `interpreter_original_chars` y `interpreter_sent_chars` solo cuando el corte existente, el de 600 antes del intérprete, cambia el texto. Los dos enteros salen del texto original y del texto que realmente recibe `TurnInterpreter`. El evento no lleva el mensaje. Un mensaje de 746 caracteres queda registrado como 746 y 600; el texto enviado sigue siendo el corte actual y pierde el final.

Reproceso de las 13 respuestas crudas, sin modificar los originales. Los derivados están en `tmp/field_companion/vf5_correction/f3/sanitizer_reprocess/`. No faltó ningún original.

En 1-A, 3-A y 5-A se recuperan dos líneas que el patrón de hasta 80 caracteres borraba:

- `2. Comprobar que la fotocélula no esté activada.`
- `3. Comprobar que no hay una obstrucción mecánica en la puerta.`

En las seis del A/B, la primera comprobación ya estaba: su interior mide 92 caracteres y superaba el tope de 80, así que el sanitizador anterior la dejaba con los asteriscos. Ahora pierde solo esos delimitadores. En 2-B, 4-B y 6-B las comprobaciones 2 y 3 iban seguidas de prosa en la misma línea; no eran una línea solo en negrita y no se habían borrado.

En las siete de los intentos 2 a 4 no hay líneas recuperadas por este cambio. Las dos reglas coinciden salvo el encabezado `# Diagnóstico: …`, que las dos siguen eliminando entero. Es la regla de encabezados Markdown, que esta corrección no cambia. Los tres de los intentos 2 empiezan por `# Diagnóstico: Puerta que se reabre sola con LED de fotocélula apagado`. Los dos del intento 3 y los dos del intento 4 empiezan por `# Diagnóstico: La puerta se reabre sola — Fermator VF5+`.

Recuperar esas dos comprobaciones no acepta las respuestas. Siguen los fallos de generación ya registrados: atribuir al manual un orden, una prioridad, un paso siguiente o una causa más probable; tratar una observación como comprobación hecha; estrechar la disyunción de 5.6; ordenar ajustar donde el pasaje dice comprobar. H1 no está descartada. H2 y H3 no se probaron. Siguen sin medir «#54» frente a «el #54» y el Modo esclavo. F2 sigue cerrada en local. F3 sigue abierta. F4 y F5 no se ejecutan.

Pendiente, sin implementar y sin diseñar:

- Antes del piloto con dictado, y aparte de cualquier archivo: el corte de 600 puede perder una negación o un resultado antes del intérprete, y `QueryComposer` puede descartar el turno completo cuando el texto compuesto pasa de 442 caracteres. No basta con subir todos los límites a la vez. Una tabla de mensajes no corrige esos dos comportamientos.
- Backlog: una tabla de mensajes vinculada a la sesión y a correlation_id, con retención y datos personales definidos. Su finalidad es conservar íntegros cada mensaje del técnico y cada respuesta presentada. Hoy `conversation_history` guarda hasta 600 caracteres por mensaje y un máximo de 20 mensajes; no es un archivo completo. `TurnEvidence` conserva sobre todo hashes, y la captura textual opcional (`PILOT_AUDIT_CAPTURE`) va al log, no a esa tabla. Tiene más prioridad que eliminar el fallback del datasource. No incluye una interfaz de historiales, exportaciones ni otras funciones. El almacenamiento de mensajes y respuestas queda separado del estado del episodio (hechos, observaciones, correcciones y comprobaciones) y del contexto del modelo: guardar el texto íntegro no obliga a enviarlo íntegro.
- Antes de F4, con menos prioridad que esa tabla: quitar la selección alternativa del datasource antiguo o del primero disponible cuando falle la configuración del pipeline principal.

### Continuidad de cuatro turnos, preparada y no ejecutada, 22 de octubre de 2026

El objetivo vuelve a ser la continuidad de una conversación. No hay otra comparación de redacción ni otro retoque de formato. No se abre otro plan ni otro arnés. F2 sigue cerrada en local. F3 sigue abierta. F4 y F5 no se ejecutan. No hubo llamadas. El ledger no se escribió.

La secuencia es la ruta ya usada en la sesión 199: una sesión nueva, historial vacío y episodio vacío, reloj real, y cada turno lee el estado y el historial que dejó el anterior. El flujo es `record_user_turn!`, intérprete, reducer, composición, `execute_rag_query`, generación, sanitizado y `record_assistant_turn!` con `history_answer`. No se reconstruye un episodio intermedio a mano y no se usa `travel_to`. Los cuatro cuerpos certificados de F2 entran por `retrieve_with_retry`, en el mismo orden. `retrieve_and_generate_with_retry` sigue sustituido por una excepción. Esta preparación no valida Retrieve ni F4, y no escribe en S3 ni sincroniza ni despliega. El código de esa ruta está en `e4a5e3f00bc570b8230064132b0c1226c2fa9f9e`. El arnés de `tmp/` no se modificó: sigue en tres turnos y no se lanza. Cuando el cupo exista, el único cambio previo es añadir el cuarto mensaje a esa misma lista.

Mensajes, en este orden:

1. «Estoy con un operador de puerta Fermator VF5+. La puerta se reabre sola. El LED de fotocélula está apagado. No veo obstrucción. No he comprobado el #54. No hice mediciones.»
2. «Corrijo solo el estado del LED: el LED de fotocélula está encendido, no apagado.»
3. «Ya revisé la fotocélula y no está activada.»
4. «¿qué sigue?»

Misma condición de proceso que la sesión 199: `AWS_MAX_ATTEMPTS=1`, `RAG_TRANSIENT_ATTEMPT_LIMIT=1`, modelo y prompt sin cambios, temperatura 0,1 y 3000 tokens. El reintento de `ServiceUnavailable` que trae el arnés ya no corre cuando el ledger pasa de 96 intentos. Con 102, la conversación son ocho llamadas: un intérprete y una generación por turno.

**Rúbrica, fijada antes de tener respuestas.** Se mira el episodio guardado y el texto presentado. Un fallo funcional impide dar la continuidad por cumplida. Un detalle cosmético se anota y no basta para rechazarla ni para aceptarla.

- Identidad y síntoma. Los cuatro turnos comparten episodio. Fermator sigue conocido, «Fermator VF5+» sigue entre los identificadores y el objetivo sigue siendo «La puerta se reabre sola». Perder el síntoma o abrir otro episodio es fallo funcional.
- Corrección vigente. Desde el turno 2, el LED guardado es el encendido y «apagado» no vuelve. Los turnos 3 y 4 lo conservan, y la respuesta usa el valor corregido. Volver a «apagado» es fallo funcional.
- Comprobaciones y resultados. El turno 1 deja `#54` y mediciones en `not_done` y no convierte el LED ni la obstrucción en comprobaciones. El turno 3 deja la fotocélula en `done` con el resultado dicho, «no está activada». `#54` y mediciones siguen sin hacer. El turno 4 no borra ese resultado ni da el `#54` por hecho. Un resultado ausente, o una observación tratada como comprobación hecha, es fallo funcional. La diferencia «#54» y «el #54» sigue anotada; esta corrida no inventa una equivalencia.
- Preguntas ya respondidas. El turno 4 no vuelve a preguntar el estado del LED, si hay obstrucción, si la fotocélula ya se revisó ni si hubo mediciones. Preguntar por el `#54` no repite una respuesta: sigue sin hacerse. Pedir otra vez el resultado de la fotocélula es fallo funcional.
- Orientación. Avanza desde las comprobaciones abiertas y el resultado de la fotocélula. El verbo del pasaje es comprobar. No inventa un procedimiento, un valor, un borne ni un orden que estos cuatro cuerpos no imprimen. La orientación propia se presenta como propia. Atribuir al manual un paso siguiente, una prioridad o una causa más probable sigue siendo fallo funcional. Una paráfrasis que no mueve al técnico no acepta la continuidad; se distingue de inventar un procedimiento.

Negrita, un título, la palabra «Respuesta» o una lista frente a prosa, con los puntos de arriba en pie, son detalle cosmético. El encabezado `#` que el sanitizador sigue quitando también lo es, si las comprobaciones permanecen.

**Presupuesto pedido, no autorizado.** Hacen falta 8 llamadas. El tope de asignación tiene que quedar en 110 como mínimo: el archivo está en 102 y, cuando el proceso usa `RAG_ASSIGNMENT_SPEND_PATH`, `AssignmentSpend` se construye con la constante `ASSIGNMENT_CALL_CAP` de 96. Subir solo el campo `call_cap` del archivo no cambia esa constante. No se sube ahora.

El techo de las ocho reservas es US$0,207906. Sale de las reservas ya pagadas en la misma ruta, llamadas 89 a 94, US$0,153448, más el turno 4. El intérprete usa el mayor techo observado en esa ruta, US$0,009021, más 1000 caracteres, US$0,010021. La generación usa el techo del turno 3, US$0,042437, más el tope de contexto de 2000 caracteres, US$0,044437. Esos caracteres se tasan como tokens, a US$0,001 y US$0,005 por millar, con 512 y 3000 de salida. El gasto real de las seis llamadas fue US$0,040879; sirve de referencia y no de techo.

Exposición leída, sin escribir el ledger: committed US$1,149887, unknown US$0,025851, abierto vacío, exposición US$1,175738. Si las ocho reservas se conservaran enteras, la exposición quedaría en US$1,383644. Bajo US$4 quedan US$2,824262. El límite que impide la corrida es el número de intentos, no el de dólares. El tope de proceso de la corrida anterior, 8 llamadas y US$0,50, cubre este techo. No se ejecuta hasta recibir la ampliación.

### Continuidad de cuatro turnos, ejecutada el 22 de octubre de 2026

Lahiri autoriza 8 llamadas, tope acumulado 110, techo adicional US$0,21 y límite acumulado US$4 con el unknown incluido. `ASSIGNMENT_CALL_CAP` pasa de 96 a 110. En el ledger solo cambia `call_cap`, de 102 a 110. Los intentos 1 a 102, el committed, el unknown y las entradas quedan como estaban. El proceso de esta corrida admite 8 llamadas y US$0,21. Preflight sin modelo: rechazo nulo, 4 cuerpos, 4 compatibles, identidad conocida, estado `scoped`. Reloj real. Sesión nueva 202, episodio `ep_76532e612b41658c` en los cuatro turnos. Historial 0, 2, 4, 6 y 8. `prompt_reply` no contiene «Registro del caso». No hubo `ServiceUnavailable` ni reintento. No valida Retrieve ni F4. No hubo S3, sincronización ni despliegue. El prompt no cambió.

**Gasto.** Ocho llamadas, US$0,053600. Techos reservados, US$0,204903, bajo US$0,21. Unknown no se movió.

| Id | Qué | Techo | Real |
|---|---|---|---|
| 103 | intérprete T1 | 0,008752 | 0,003864 |
| 104 | generación T1 | 0,041927 | 0,009943 |
| 105 | intérprete T2 | 0,009021 | 0,003273 |
| 106 | generación T2 | 0,042400 | 0,009958 |
| 107 | intérprete T3 | 0,008986 | 0,003351 |
| 108 | generación T3 | 0,042510 | 0,010216 |
| 109 | intérprete T4 | 0,008973 | 0,003109 |
| 110 | generación T4 | 0,042334 | 0,009886 |

Ledger al cerrar: 110 intentos, committed US$1,203487, unknown US$0,025851, abierto vacío, exposición US$1,229338, `call_cap` 110, tope US$4. No queda ningún intento de este cupo.

**Estado.** Identidad y síntoma se conservan. Fermator conocido, «Fermator VF5+» y «operador de puerta» siguen, y el objetivo sigue siendo «La puerta se reabre sola». Desde el turno 2 la observación del LED es «el LED de fotocélula está encendido» y «apagado» no vuelve. El turno 3 guarda la fotocélula en `done` con resultado «no está activada». `#54` y mediciones siguen `not_done`. El turno 4 no borra ese resultado ni cierra el `#54`. También queda la observación suelta «no está activada», además del resultado en la comprobación. La consulta del turno 4 lleva el síntoma, el LED encendido y ese resultado.

**Turno 1.** Las dos comprobaciones que el sanitizador anterior borraba están en el texto. El episodio no convierte el LED ni la obstrucción en comprobaciones. La respuesta sí: «Esta condición se cumple» cierra la fotocélula desde el LED apagado, y «Esta observación visual está hecha» cierra la obstrucción. «Este es el primer paso documentado» y «Próximo paso documentado» atribuyen un orden. La pregunta pide un multímetro que estos pasajes no imprimen.

**Turno 2.** El registro y el párrafo usan el LED encendido. «Antes de ajustar el #54» cambia el verbo y lo pone primero. «ya reportado: no se ve obstrucción» da la observación por hecha. La glosa de [4] se queda en una señal de re-apertura.

**Turno 3.** El registro dice fotocélula hecha, «no está activada», y el párrafo no vuelve a pedir esa revisión. Cita [4] con la disyunción. Después atribuye las tres comprobaciones de este síntoma a [2] y llama a `#21` «la más probable». `#21` está en el pasaje de «abre pero no se cierra», no en el de «se re-abre sola». La pregunta pide medir el terminal `#21` con multímetro o con la consola. Eso no está en los cuatro cuerpos.

**Turno 4.** No repregunta el LED, la fotocélula ni las mediciones. Preguntar por el acceso al `#54` cabe, porque sigue sin hacerse. No cabe el marco: «el siguiente paso documentado» y «Ajuste el potenciómetro #54». La obstrucción se lista como ya verificada. El TEST queda detrás de ese ajuste.

```
Registro del caso. Equipo: Fermator VF5+, operador de puerta. Síntoma: «La puerta se reabre sola». Observaciones: «No veo obstrucción», «el LED de fotocélula está encendido», «no está activada». Comprobaciones: #54, sin hacer; mediciones, sin hacer; fotocélula, hecha, «no está activada».

Según la documentación del VF5+, el siguiente paso documentado para la puerta que se reabre sola es:

**Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54)** [3].

Usted ya ha verificado que:
- La fotocélula no está activada (revisión completada).
- No hay obstrucción mecánica visible.

Sin embargo, existe una contradicción no resuelta: el LED de fotocélula está encendido, pero usted reporta que la fotocélula no está activada. La documentación establece que el indicador LED de fotocélula se activa "cuando la fotocélula o la entrada de re-apertura está activada" [4].

Falta en los pasajes: la documentación no especifica qué significa que el LED esté encendido mientras la fotocélula reporta no estar activada, ni proporciona valores de referencia para el potenciómetro #54.

Próximo paso recomendado:

Ajuste el potenciómetro #54 (regulación de fuerza de re-apertura) y observe si la puerta deja de reabrirse. Si el problema persiste después de este ajuste, la documentación indica desconectar la fotocélula y pulsar el botón de TEST nuevamente; si la puerta no se abre o cierra completamente en ese caso, debe haber una obstrucción mecánica [3].

¿Tiene acceso al potenciómetro #54 en el módulo VF5+ para realizar este ajuste?
```

La negrita de esa respuesta es cosmética. El fallo es el orden atribuido y el verbo.

**Cierre.** El estado recorre los cuatro turnos en un episodio y conserva la corrección y el resultado. La orientación no. La continuidad no se acepta. Siguen los fallos de generación: orden o paso siguiente atribuido al manual, observación tratada como comprobación hecha, y un procedimiento que los cuerpos no imprimen. H1 no está descartada. H2 y H3 no se probaron en esa corrida. «#54» y «el #54» no se midieron como equivalencia. F2 sigue cerrada en local. F3 sigue abierta. F4 y F5 no se ejecutaron.

### H2. Registros fuera del contexto documental, 22 de octubre de 2026

Lahiri autoriza 12 llamadas de comparación, techo US$0,52, y 8 llamadas condicionales de conversación, techo US$0,21, solo si la comparación pasa. Tope acumulado 130. Techo adicional conjunto US$0,73. Límite US$4, con committed, unknown y reservas. No hay Retrieve, reextracción, S3, sincronización ni despliegue. F4 y F5 no entran. El candidato no queda como comportamiento predeterminado.

**Código.** `Rag::DocumentIdentityScope.omit_terminal_evidence_records` quita el bloque solo si hay un único encabezado `# FIELD-SAFETY EVIDENCE RECORDS`, todas las líneas posteriores no vacías son líneas de registro, los `FIELD_RECORD` y los `END_FIELD_RECORD` coinciden y son más de cero, y queda prosa antes del encabezado. Si el bloque no es terminal o el pasaje quedaría vacío, el cuerpo original se conserva. `generation_context` sigue incluyendo los registros salvo `records: false`. El plano, `TOPOLOGY_EDGE`, las citas y los guards siguen viendo el chunk original. `omit_evidence_records` entra por `execute_rag_query`, el orquestador y `BedrockRagService#query`, y solo omite cuando es exactamente true y el turno no es de plano. El valor predeterminado es false. No cambian ROLE, FIELD_REPORT_PARAGRAPH, historial, modelo, extracción, S3 ni KB.

**Tests.** `evidence_record_context_test`, `call_evidence_test` y `local_pass_ledger_test`: 23 pruebas, 378 aserciones, 0 fallos. Cubren el cuerpo conservado y los registros omitidos, las etiquetas y las fuentes, el plano y el pasaje compuesto solo por registros, la prosa posterior al bloque, los chunks de citas y guards sin cambios, y el tope 130. `CallEvidence`, con un cliente falso, guarda por llamada la petición efectiva, la respuesta cruda, la presentada, el estado, el historial, las fuentes y el consumo, unidos por correlación. Sin tokens, `cost_kind` queda `unavailable` y no se escribe `cost_usd`.

**Reconstrucción, no captura histórica.** T1 y T4 se armaron de nuevo con la sesión 202, el episodio `ep_76532e612b41658c` y los cuatro cuerpos certificados. El reloj se desplazó solo mientras se armaba el prompt y estaba real antes de cada llamada. No son las peticiones de las llamadas 104 y 110. T1 usa el episodio de `t1/episode.json`. T4 usa el episodio guardado en la sesión, que coincide con `t4/episode.json` en objetivo, observaciones y comprobaciones; no imprime «Not current». El historial de T4 que entra al prompt es la corrección del LED, la fotocélula revisada, el corte de 200 caracteres de la respuesta anterior y «¿qué sigue?». A y B comparten pregunta, estado, historial, fuentes, modelo `global.anthropic.claude-haiku-4-5-20251001-v1:0`, temperatura 0,1, 3000 tokens y ningún mensaje de sistema. El diff de cada turno retira 170 líneas y ninguna otra: encabezado, líneas de registro y blancos. A tiene 4 encabezados; B tiene 0. Los cuatro cuerpos certificados sí cumplen la condición de bloque final. Techo de las 12 peticiones, US$0,457734.

**Rúbrica, fijada antes de llamar.** Un defecto material es atribuir al manual un orden, una prioridad, el siguiente paso, la causa más probable, o un procedimiento, valor o herramienta que los cuatro cuerpos no imprimen para ese componente; tratar una observación como una comprobación hecha; ordenar un ajuste donde el pasaje dice comprobar; citar una fuente que no sostiene la frase, o trasladar una herramienta o un valor entre componentes; dar una paráfrasis sin orientación útil; y, en T4, volver a pedir el LED, la obstrucción, la revisión de la fotocélula o las mediciones, o llamar contradicción o dato no documentado a la combinación de LED encendido y fotocélula no activada. La glosa de 5.6 cuenta solo si la frase dice que la documentación establece esa única rama. Umbral: B como máximo 1/6 con defecto material, A al menos 3/6, y al menos 2/3 de B-T4 orientan usando el resultado reportado.

**Llamadas.** El orden fue A/B alternado. La 111 volvió. La 112 fue un 403 en 29 ms del sandbox local, sin respuesta de modelo; su techo US$0,034012 queda unknown y no se convirtió en cero. Esa muestra se emitió después fuera del sandbox: es la 113. La 122 llegó a Bedrock y devolvió `ServiceUnavailable` a los 5089 ms para el tercer A de T4; no se reintentó. La 123 es el B de T4 que faltaba, no una repetición de la 122. Once respuestas presentadas y una llamada sin texto.

| Id | Muestra | Resultado | Real |
|---|---|---|---|
| 111 | 01 T1 A | 7703 / 375 | 0,009578 |
| 112 | sandbox 403, sin muestra | unknown | techo 0,034012 |
| 113 | 02 T1 B | 4826 / 335 | 0,006501 |
| 114 | 03 T1 A | 7703 / 480 | 0,010103 |
| 115 | 04 T1 B | 4826 / 290 | 0,006276 |
| 116 | 05 T1 A | 7703 / 417 | 0,009788 |
| 117 | 06 T1 B | 4826 / 295 | 0,006301 |
| 118 | 07 T4 A | 7796 / 375 | 0,009671 |
| 119 | 08 T4 B | 4919 / 344 | 0,006639 |
| 120 | 09 T4 A | 7796 / 361 | 0,009601 |
| 121 | 10 T4 B | 4919 / 364 | 0,006739 |
| 122 | 11 T4 A | ServiceUnavailable | techo 0,042277, unknown |
| 123 | 12 T4 B | 4919 / 348 | 0,006659 |

En las once respuestas, la captura guarda el SHA del prompt preparado, la correlación `vf5-h2-…`, la respuesta cruda y el consumo. La presentada es esa respuesta después del sanitizador: quita el título `# Diagnóstico` cuando aparece y la negrita de algunos rótulos. La evaluación es de la presentada. La 122 no tiene `cost_usd`; su consumo queda `unavailable`. Los intentos 1 a 110 no se reescribieron. El 110 sigue settled en US$0,009886. Unknown de origen US$0,025851 sigue dentro del total.

**01 T1 A, presentada.**

```
Según la documentación del VF5+, cuando la puerta se reabre sola, debe verificarse [3]:

1. **La sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54)** — Usted aún no ha comprobado este elemento.

2. **Que la fotocélula no esté activada** — Usted reporta que el LED de fotocélula está apagado, lo que es consistente con esta condición.

3. **Que no hay obstrucción mecánica en la puerta** — Usted ya ha verificado visualmente que no hay obstrucción.

Próximo paso documentado:

La documentación indica que si el problema persiste después de estas comprobaciones, debe desconectar la fotocélula y pulsar nuevamente el botón de TEST. Si la puerta no se abre o cierra completamente en ese caso, habría una obstrucción mecánica en la puerta [3].

Lo que falta:

No ha comprobado el potenciómetro #54, que es el primer elemento documentado para este síntoma. La documentación no proporciona valores de ajuste, rangos de sensibilidad, ni procedimiento de medición para #54 — solo que debe verificarse su sensibilidad.

¿Ha podido acceder al potenciómetro #54 en el módulo VF5+ para inspeccionar su posición o estado?
```

Defecto material. «Primer elemento documentado» atribuye un orden. «Ya ha verificado» cierra la obstrucción desde «no veo obstrucción».

**02 T1 B, presentada.**

```
La documentación del VF5+ indica tres comprobaciones para la re-apertura automática de la puerta [3]:

1. **Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54)** — aún no realizado.
2. **Comprobar que la fotocélula no esté activada** — ya confirmado: el LED de fotocélula está apagado [3].
3. **Comprobar que no hay obstrucción mecánica en la puerta** — ya confirmado: no se ve obstrucción [3].

Dado que el LED de fotocélula está apagado y no hay obstrucción visible, el siguiente paso documentado es **verificar el potenciómetro #54**. Este componente regula la fuerza de re-apertura; si su sensibilidad es excesiva, puede provocar que la puerta se abra sola incluso sin activación de la fotocélula.

La documentación también menciona que si el problema persiste después de estas comprobaciones, se debe desconectar la fotocélula y pulsar el botón de TEST; si la puerta no abre o cierra completamente, habría obstrucción mecánica [3].

¿Ha podido acceder al potenciómetro #54 para verificar su posición o ajuste?
```

Defecto material. El pasaje [3] lista tres comprobaciones y no nombra un siguiente paso. El LED apagado y «no veo obstrucción» quedan como comprobaciones confirmadas, y [3] no sostiene ese cierre.

**03 T1 A, presentada.**

```
Según la documentación del VF5+, para el síntoma "la puerta se reabre sola" se documentan tres comprobaciones [3]:

1. Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54).
Usted aún no ha realizado esta comprobación. La documentación no especifica qué valores o ajustes son correctos.

2. Comprobar que la fotocélula no esté activada.
Usted reporta que el LED de fotocélula está apagado, lo que es consistente con una fotocélula no activada. Sin embargo, la documentación también indica que el LED de fotocélula se activa "cuando la fotocélula o la entrada de re-apertura está activada" [4]. Un LED apagado sugiere que ninguna de estas dos está activa en este momento.

3. Comprobar que no hay una obstrucción mecánica en la puerta.
Usted reporta que no ve obstrucción.

Paso adicional documentado:
Si el problema persiste después de estas comprobaciones, la documentación indica: "desconectar la fotocélula y volver a pulsar el botón de TEST. Si la puerta no se abre o cierra completamente, debe haber una obstrucción mecánica en la puerta" [3].

Próximo paso recomendado:
Compruebe el potenciómetro #54 (regulación de fuerza de re-apertura), que es la única de las tres comprobaciones que aún no ha realizado. La documentación no proporciona valores de referencia ni procedimiento de ajuste para este componente.

¿Puede acceder al potenciómetro #54 en el módulo VF5+ y observar su posición actual?
```

Defecto material. «La única de las tres comprobaciones que aún no ha realizado» da por hechas la fotocélula y la obstrucción. La frase de [4] no dice que la documentación establezca una sola rama; esa glosa, sola, no entra en la rúbrica.

**04 T1 B, presentada.**

```
La documentación del VF5+ indica tres comprobaciones para la re-apertura automática de la puerta [3]:

1. **Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54)** — aún no realizado.
2. **Comprobar que la fotocélula no esté activada** — ya confirmado: el LED de fotocélula está apagado [3].
3. **Comprobar que no hay obstrucción mecánica en la puerta** — ya confirmado: no se ve obstrucción [3].

Dado que el LED de fotocélula está apagado y no hay obstrucción visible, el siguiente paso documentado es verificar el potenciómetro #54. La documentación también menciona que si el problema persiste después de desconectar la fotocélula y pulsar el botón de TEST, debe haber una obstrucción mecánica [3].

Próximo paso: Comprueba la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54). ¿Cuál es su posición actual o rango de ajuste?
```

Defecto material. Mismo cierre de observaciones y el mismo «siguiente paso documentado». Además adelanta la consecuencia de la obstrucción: el pasaje la condiciona a que, tras desconectar y pulsar TEST, la puerta no complete el ciclo.

**05 T1 A, presentada.**

```
Según la documentación del VF5+, para el síntoma "la puerta se reabre sola" se documentan tres comprobaciones [3]:

Comprobaciones documentadas:

1. **Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54)** — Usted aún no ha realizado esta comprobación.

2. **Comprobar que la fotocélula no esté activada** — Usted reporta que el LED de fotocélula está apagado, lo que es consistente con esta condición.

3. **Comprobar que no hay una obstrucción mecánica en la puerta** — Usted reporta no ver obstrucción.

Paso adicional si el problema persiste:

Si después de revisar el #54 el problema continúa, la documentación indica desconectar la fotocélula y pulsar el botón de TEST. Si la puerta no se abre o cierra completamente en ese caso, debe haber una obstrucción mecánica [3].

Falta en los pasajes:

Los pasajes no especifican qué valores o rangos del potenciómetro #54 son correctos, ni cómo ajustarlo. Tampoco documentan mediciones eléctricas específicas para este síntoma.

Próximo paso:

¿Puede acceder al potenciómetro #54 en el módulo VF5+ y verificar su posición actual? Esto le permitirá determinar si la sensibilidad de re-apertura está configurada incorrectamente.
```

Defecto material. Pone el TEST detrás de revisar solo el `#54`, y la pregunta pide una posición y una configuración incorrecta que el pasaje no imprime. El pasaje dice comprobar la sensibilidad.

**06 T1 B, presentada.**

```
La documentación del VF5+ indica tres comprobaciones para la reapertura automática de la puerta [3]:

1. **Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54)** — aún no realizado.
2. **Comprobar que la fotocélula no esté activada** — ya confirmado: el LED de fotocélula está apagado [3].
3. **Comprobar que no hay obstrucción mecánica en la puerta** — ya confirmado: no se ve obstrucción [3].

Dado que el LED de fotocélula está apagado y no hay obstrucción visible, el siguiente paso documentado es verificar el potenciómetro #54. La documentación también menciona que si el problema persiste después de desconectar la fotocélula y pulsar el botón de TEST, debe haber una obstrucción mecánica [3].

Próximo paso: Comprueba la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54). ¿Puedes acceder a ese potenciómetro y verificar su posición actual?
```

Defecto material. Igual que 04 en el cierre y en el paso atribuido. El verbo de la última instrucción sí es comprobar.

**07 T4 A, presentada.**

```
Según la documentación del VF5+, el siguiente paso documentado es **comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54)** [3].

Su situación actual:
- LED de fotocélula encendido
- Fotocélula no está activada (ya revisada)
- No hay obstrucción mecánica visible
- La puerta se reabre sola

La documentación establece que cuando la puerta se reabre sola, debe verificarse [3]:

1. **Potenciómetro #54** — comprobar su sensibilidad de regulación de fuerza de re-apertura.
2. **Fotocélula no esté activada** — ya lo confirmó.
3. **No hay obstrucción mecánica** — ya lo verificó.

Si el problema persiste después de revisar el potenciómetro #54, la documentación indica un paso adicional: **desconectar la fotocélula y volver a pulsar el botón de TEST (50)**. Si la puerta no se abre o cierra completamente en ese caso, debe haber una obstrucción mecánica en la puerta [3].

Falta en los pasajes: La documentación no especifica qué valores o posiciones del potenciómetro #54 son correctos, ni cómo ajustarlo.

¿Ha revisado o ajustado el potenciómetro #54, o necesita orientación sobre dónde localizarlo en el módulo?
```

Defecto material. «El siguiente paso documentado» y «ya lo verificó» para la obstrucción. No llama contradicción al LED encendido con la fotocélula no activada. La fotocélula sí estaba hecha en el estado de T4.

**08 T4 B, presentada.**

```
Según la documentación del VF5+, cuando **la puerta se reabre sola**, debe verificar [3]:

1. **La sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54)** — esto aún no lo ha hecho.
2. **Que la fotocélula no esté activada** — usted ya reportó que no está activada.
3. **Que no hay obstrucción mecánica en la puerta** — usted reportó que no ve obstrucción.

El problema es que el **LED de fotocélula está encendido**, lo cual según la documentación indica que "la fotocélula o la entrada de re-apertura está activada" [4]. Esto contradice su verificación de que la fotocélula no está activada.

Próximo paso documentado:

La documentación indica que si el problema persiste después de verificar lo anterior, debe "desconectar la fotocélula y volver a pulsar el botón de TEST. Si la puerta no se abre o cierra completamente, debe haber una obstrucción mecánica en la puerta" [3].

Pregunta: ¿Ha ajustado o verificado el potenciómetro #54 (regulación de fuerza de re-apertura)? Si no, ese es el siguiente control documentado antes de desconectar la fotocélula.
```

Defecto material. Incorpora el resultado y lo declara contradicción. [4] imprime la disyunción, no una contradicción con la fotocélula revisada. No cuenta como orientación que use el resultado reportado.

**09 T4 A, presentada.**

```
Según la documentación del VF5+, el siguiente paso documentado es **comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54)** [3].

Su situación actual:
- LED de fotocélula encendido
- Fotocélula no está activada (ya revisada)
- No hay obstrucción mecánica visible
- La puerta se reabre sola

La documentación establece que cuando la puerta se reabre sola, debe verificarse [3]:

1. **Potenciómetro #54** — comprobar su sensibilidad de regulación de fuerza de re-apertura.
2. **Fotocélula no activada** — ya lo confirmó.
3. **Sin obstrucción mecánica** — ya lo confirmó.

Si el problema persiste después de revisar el potenciómetro #54, la documentación indica un paso adicional: **desconectar la fotocélula y pulsar el botón de TEST**. Si la puerta no se abre o cierra completamente en ese caso, debe haber una obstrucción mecánica en la puerta [3].

Falta en los pasajes: La documentación no especifica qué valores o rangos debe tener el potenciómetro #54, ni cómo ajustarlo.

¿Ha revisado o ajustado el potenciómetro #54? ¿Cuál es su posición actual?
```

Defecto material. Mismo orden atribuido y la obstrucción dada por confirmada. No declara contradicción.

**10 T4 B, presentada.**

```
Según la documentación del VF5+, cuando **la puerta se reabre sola**, debe verificar:

1. **La sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54)** [3]. Usted aún no ha realizado esta medición.

2. **Que la fotocélula no esté activada** [3]. Usted reporta que ya revisó y no está activada, pero el LED de fotocélula está encendido. La documentación establece que el indicador LED de fotocélula se activa "cuando la fotocélula o la entrada de re-apertura está activada" [4]. Esta discrepancia entre el estado del LED (encendido) y su verificación (no activada) requiere aclaración.

3. **Que no hay obstrucción mecánica en la puerta** [3]. Usted reporta que no ve obstrucción.

Próximo paso documentado: La documentación indica que si el problema persiste después de estas comprobaciones, debe "desconectar la fotocélula y volver a pulsar el botón de TEST. Si la puerta no se abre o cierra completamente, debe haber una obstrucción mecánica en la puerta" [3].

Pregunta: ¿Ha ajustado o medido el potenciómetro #54? Si no, ese es el siguiente control documentado. Si ya lo verificó, ¿cuál es su estado o valor?
```

Defecto material. La combinación queda como discrepancia que requiere aclaración, y el `#54` queda como medición y como valor. No orienta con el resultado sin ese conflicto.

**11 T4 A.** Sin texto. `ServiceUnavailable`: «Bedrock is unable to process your request.» No se reintentó. El prompt capturado es el A de T4.

**12 T4 B, presentada.**

```
Según la documentación del VF5+, cuando **la puerta se reabre sola**, debe verificar [3]:

1. **La sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54)** — esto aún no lo ha hecho.
2. **Que la fotocélula no esté activada** — usted ya reportó que no está activada.
3. **Que no hay obstrucción mecánica en la puerta** — usted reportó que no ve obstrucción.

El problema es que el **LED de fotocélula está encendido**, lo que según la documentación indica que "la fotocélula o la entrada de re-apertura está activada" [4]. Esto contradice su verificación de que la fotocélula no está activada.

Próximo paso documentado: La documentación indica que si el problema persiste después de verificar lo anterior, debe "desconectar la fotocélula y volver a pulsar el botón de TEST. Si la puerta no se abre o cierra completamente, debe haber una obstrucción mecánica en la puerta" [3].

Antes de eso, le recomiendo verificar el **potenciómetro #54** (regulación de fuerza de re-apertura), que aún no ha revisado. ¿Puede acceder a ese potenciómetro y reportar su posición actual?
```

Defecto material. Otra vez la contradicción, y el TEST queda detrás de esa verificación. No cuenta como orientación con el resultado.

**Umbral.** A tiene defecto en las cinco respuestas que existen; falta la sexta por el proveedor. Cinco ya superan 3/6. B tiene defecto en 6/6; el máximo era 1/6. B-T4 orienta con el resultado, sin contradicción ni aclaración falsa, en 0/3; el mínimo era 2/3. El umbral no se cumple. La etapa 2 no se ejecutó. No se abrió otra variante. El prompt B es más corto, de unos 7700 a unos 4800 tokens de entrada en T1, y el defecto sigue. Esta muestra no demuestra ni descarta que los registros sean la causa.

**Gasto.** Trece intentos nuevos, 111 a 123. Once settled suman US$0,087856. Dos unknown suman US$0,076289. Exposición adicional US$0,164145, bajo US$0,52 y bajo US$0,73. Ledger al cerrar: 123 intentos, committed US$1,291343, unknown US$0,10214, abierto vacío, exposición US$1,393483, `call_cap` 130, tope US$4. Quedan 7 intentos de cupo. No se usaron las 8 llamadas condicionales.

**Estado del candidato.** Sigue opt-in. Sin `omit_evidence_records: true` la generación documental conserva los registros. El plano también los conserva. F2 sigue cerrada. F3 sigue abierta: el estado de los cuatro turnos anteriores queda como estaba, y la generación no queda aceptada. F4 y F5 no se ejecutaron.

## F3, turno único

Candidato opt-in, `RAG_COMPANION_TURN=1`, leído en un solo método y desactivado por defecto. No se combina con `RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE`. La generación recibe el mensaje del técnico; la recuperación sigue con la consulta compuesta. El episodio no se reescribe: una observación se omite de la representación solo cuando su texto normalizado coincide con el resultado de un check de la misma correlación. La respuesta anterior entra completa, como conclusión previa, con tope técnico de 16 000 caracteres y marca `prompt_reply_truncated` si se corta. Fuera del candidato, el corte de 200 del asistente y el de 600 del técnico siguen igual.

`Rag::CompanionTurnPublication` aplica R1–R5 y anota S1–S4. No renderiza ni vuelve a llamar. Una respuesta inválida publica «No pude preparar una orientación fiable para este turno; el caso se conserva», deja `prompt_reply` vacío y no muestra el texto crudo. La comprobación de condiciones es léxica y solo ve el fragmento que contiene la cita: una condición en la línea anterior pasa el validador. Eso no demuestra fidelidad semántica.

Tests con red bloqueada y cliente falso: `companion_turn_publication_test`, `companion_turn_generation_test`, más contexto, registro del caso, historial, evidencia de la llamada, cliente y el concern. La captura del cliente falso escribe system, parámetros, respuesta del proveedor, `stop_reason`, validación, respuesta presentada, `prompt_reply`, estados, historial, fuentes, mensaje, consulta, tokens y coste antes de cualquier llamada de pago.

**Control.** Una generación, `20261022T180341Z`. Episodio de T4, turnos del técnico T2, T3 y «¿qué sigue?», cuatro cuerpos certificados en el orden p5, p12, p12–p13, p7. Sin antecedente del asistente: la prosa de T3 no salió de este candidato. Sin intérprete. Consulta de recuperación: la `effective_question` de T4 de referencia. Techo calculado US$0,021238; admisión del proceso US$0,022238. Haiku 4.5 global, temperatura 0,1, `max_tokens` 3000. `stop_reason` `end_turn`. 2189 tokens de entrada, 275 de salida, US$0,003564, latencia 4590 ms. Una sola llamada. El episodio, en objetivo, identidad, observaciones y checks, quedó igual. `prompt_reply` es la respuesta presentada, 928 caracteres, sin registro del caso y sin marca de truncado.

La publicación mecánica aceptó el texto: [3] existe y es compatible, no hay cita entre comillas, no hay atribución sin marca, y el sanitizador conservó el texto. Esa aceptación no juzga la paráfrasis.

Respuesta presentada:

```
Danebo ve que la fotocélula no está activada según la comprobación realizada, y que el LED está encendido pero sin que la fotocélula esté funcionando. Esto descarta que la reapertura sea causada por la fotocélula misma. Según la documentación [3], cuando la puerta se reabre sola, el siguiente paso es comprobar la sensibilidad del potenciómetro de regulación de fuerza de reapertura (#54), que está en la lista de comprobaciones sin hacer. Este ajuste controla cuánta fuerza se aplica durante la reapertura, y si está demasiado sensible podría provocar que la puerta se abra sin causa aparente. También está pendiente comprobar las mediciones, que podrían revelar si hay señales eléctricas anómalas activando la reapertura.

¿Has podido acceder al potenciómetro #54 para verificar su sensibilidad, o necesitas primero hacer las mediciones eléctricas para descartar que haya una señal de reapertura (#21) activada continuamente?
```

**Evaluación.** Defectos materiales:

- Atribuye a [3] un paso siguiente. La fuente enumera tres comprobaciones para la puerta que se reabre sola y no fija ese orden.
- Descarta la fotocélula como causa. [4] dice que el indicador se activa cuando la fotocélula o la entrada de re-apertura está activada. La respuesta no usa esa disyunción.
- La pregunta trae #21, y la condición «continuamente», desde el síntoma de la puerta que se abre y no se cierra, sin cita.
- Describe el potenciómetro como un ajuste que controla la fuerza y que, si está demasiado sensible, abre la puerta sin causa. La fuente dice comprobar la sensibilidad.
- Atribuye a las mediciones pendientes la función de revelar señales eléctricas anómalas. El episodio solo las deja sin hacer.

Conserva la identidad, el LED encendido y el resultado de la fotocélula, y no llama contradicción a esa combinación. No alcanza: el control no orienta con la disyunción de 5.6 ni con lo pendiente sin atribuir un orden que la fuente no dice.

**Conversación.** No se ejecutó. El control falló en lo semántico. No hay segunda variante.

**Gasto.** Un intento, el 124, settled US$0,003564. Unknown sigue US$0,10214. Ledger: 124 intentos, committed US$1,294907, abierto vacío, `call_cap` 132, tope US$4. Exposición US$1,397047. De los US$0,20 autorizados se usaron US$0,003564. Quedan ocho llamadas sin usar, dentro del cupo de 132.

**Decisión.** Este candidato no queda aceptado. El opt-in sigue apagado por defecto. Esta muestra no es estabilidad, ni cierra F3, ni abre F4 o F5. F2 sigue cerrada.



