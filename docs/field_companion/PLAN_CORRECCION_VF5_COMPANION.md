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
- **Fase 5:** 4 turnos por 2 llamadas, más 3 de reserva para un fallo transitorio del intérprete, con un tope de 11 y US$0,30 en el proceso del servidor local.

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

El costo remoto es el de los embeddings de unos 30 objetos. El parseo no se vuelve a pagar.

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

Arnés experimental, fuera de alcance y sin bloqueo de F2. `test/services/rag/vf5_system_role_admission_test.rb` no entra en la suite seguida; Rails sí lo ejecuta si se le pasa el archivo. `.git/info/exclude` no lo evita. La corrida vio tres fallos: la admisión del ensamblado actual devuelve `control`; la reserva histórica esperaba `plan_refused` y obtuvo `admission_refused`; las seis muestras esperaban `completed` y obtuvieron `admission_refused`. `admit` devuelve `control` solo cuando el SHA del prompt de control renderizado no es `6702ca30a2bca73688a81e5c8f9de1d585d4108d9e4db3cdf80ecdc254761500`. `Vf5SystemRoleComparison` convierte esa negativa en `admission_refused` antes de la reserva y antes de cualquier muestra. El cambio de prompt de F1-B mueve ese render. No se modifica el arnés ni sus expectativas.

Siguiente: F2, con el ledger de ingesta y sin escritura en S3. La escritura en S3 espera la autorización de F4.

### F2. Sonda, 21 de octubre de 2026

Sin escritura en S3. Filtro Haiku de las 22 páginas y extracción síncrona. El ancla real es la página 1, así que se extrajo antes de la sonda y no se vuelve a pagar. Flags de layout, visión y triaje apagados. El SDK de Anthropic trae `max_retries` 2; los clientes se inyectaron con 0. Código de la sonda: `ca545d6`. Evidencia: `tmp/field_companion/vf5_correction/ingest/` y ledger `tmp/field_companion/vf5_correction/ingest_spend.json`.

Gasto de la sonda, 10 llamadas, US$0,526390. El reintento de la página 22 suma la llamada 11: US$0,583192 comprometidos, 0 en abierto, techo 32 y US$2,50. No se reextrayeron las páginas sanas.

Paginación: confirmada. El folio impreso es el índice del PDF menos uno (la 12 imprime 11/21, la 13 imprime 12/21, la 22 imprime 21/21). La extracción separa índice y folio. La página 14 no inventa un 9.5 ni dice que la página no llegó.

- p3: descarte registrado. La página es el objetivo del documento y el registro de modificaciones.
- p5: sin encabezado S4 ni nota de seguridad. Los ejemplos de SW4 siguen marcados como ejemplos.
- p6: no cruza columnas. En el texto y en la imagen, 12 es abrir, 11 es 0 V, 10 es común, 9 es 12 V y 8 es cerrar. La figura 3 imprime N—7, un símbolo en 6 y L—5, hacia 230 V. El cuerpo lo dice así.
- p12: contiene 8.1 y los síntomas de 8.2. `#21` queda bajo «se abre pero no se cierra», junto con el LED, `#8` y `#12`.
- p13: la frase «En caso que el problema persista, desconectar la fotocélula…» queda unida a 8.2 «se re-abre sola», con `[PDF_PAGE: 13]`, `[PRINTED_PAGE: 12/21]` y `source_pdf_page` 13.
- p14: contiene 9.1 a 9.4, sin 9.5 inventado y sin decir que la página no llegó.
- p19: contiene las cifras de 11.1 y 11.2, entre ellas 29,46, 31,61 y 0,12 en la fila EW 60. La cobertura marca ausentes los rótulos 11.1 y 11.2; las cifras no. `layout_order_verified` sigue en falso.
- p22: no cumple. En el ejemplo 2 la página imprime 36,61 x (−0,17) = −6,13 Kg solo en «Diferencia por apertura» y «Son iguales» en «número de paneles». 0,12 = 4,39 Kg está en «tipo de panel». La primera extracción metió −6,13 en una celda combinada de esas dos columnas. El cuerpo de esa llamada no se conservó al reintentar; queda el usage de la llamada 10.

Ajuste único de instrucción, commit `b15078c`: la tabla compacta no funde dos celdas impresas ni mueve un valor a la columna vecina. Test del prompt, 29 corridas, 0 fallos. Reextracción solo de la página 22, llamada 11, US$0,056802. Sigue cruzando: dice que la celda impresa abarca las dos primeras columnas y en «número de paneles» escribe «ver celda anterior».

No hay tanda 2. No hay segunda sonda. F2 no se acepta. F3 no arranca: la página 7 no está certificada. La solicitud remota no se envía.


