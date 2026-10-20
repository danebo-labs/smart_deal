# Ejecución local: Fermator VF5+, la puerta se reabre sola

**Veredicto:** pasada detenida en el preflight. Cero turnos del técnico. Cero respuestas publicadas. No es candidata a aceptación textual. No declara `EPISODIO_VALIDADO`.

**Fecha:** 2026-10-19.

**SHA inicial:** `a3def4ba5def5f065a42b1a87cd7e4ca3aae9a8c`.

**Matriz, sin cambios:** [CASO_FERMATOR_VF5_REABRE_SOLA_2026-10-19.md](CASO_FERMATOR_VF5_REABRE_SOLA_2026-10-19.md).

La matriz sigue siendo la expectativa del evaluador. Este archivo registra lo observado. No hubo navegador, no hubo `APPLY=true` y no hubo generación. La aceptación textual no cierra los fallos históricos del plano Elemont.

**Aclaración posterior.** La detención es el hecho histórico y se conserva. La autorización para consultar `Y7RZWMFJSR` desde la aplicación y las bases locales ya existía cuando esta pasada se detuvo. Este registro la trató como una decisión todavía pendiente y por eso no creó la fila local ni arrancó la web con esa base. Preparar en la base local los metadatos del manual ya existente no era ingerir otro documento. La ingesta, la escritura en producción y el cambio del corpus seguían fuera de autorización. La pasada que usó la lectura ya autorizada está en [EJECUCION_FERMATOR_VF5_REABRE_SOLA_2026-10-20.md](EJECUCION_FERMATOR_VF5_REABRE_SOLA_2026-10-20.md). Este archivo no se reescribe como si aquella web se hubiera recorrido.

## 1. Veredicto provisional

Recorrido detenido antes del primer mensaje.

Cumplido en esta pasada:

- Cuatro conexiones de development en localhost: `smart_deal_development`, `smart_deal_development_cache`, `smart_deal_development_queue`, `smart_deal_development_cable`. Ningún nombre contiene `production`.
- El proceso del dry-run leyó el prefijo acordado: episodio, turno, alcance de episodio y modo `owner` encendidos; sesión compartida apagada. `flags_scope` siguió diciendo que web y workers no estaban inspeccionados, porque esos procesos no se arrancaron.
- El PDF del repositorio y el objeto `s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf` tienen el SHA-256 `be7a39a3490c92c8381cb883402760cb07d10b0a3beda5348bed22f72abedf72` y 1 271 591 bytes.
- La identidad de catálogo en `config/document_identities.yml` conserva el uid `126cda62-64ad-4469-8674-a29f12e38d48`, la clave y el título «Módulo electrónico VF5+».
- `QGVYLPTEGT` y `Y7RZWMFJSR` quedaron leídas como bases distintas.
- La captura de la ruta web y el cupo de esta pasada quedaron cubiertos con pruebas y dobles, sin AWS.

Fallido, y por eso no hay recorrido:

- La tabla local `kb_documents` no tiene esa uid ni esa clave. La tarjeta sale de esa tabla. Sin la fila, la interfaz no puede ofrecer el uid.
- La KB efectiva del proceso local es `QGVYLPTEGT` (`danebo-rag-dev`). Su data source lee `smart-deal-dev-kb`, prefijo `bulk_chunks/`. El objeto VF5 no está en ese bucket. Una lectura de cinco resultados no devolvió `VF5.pdf`.
- `Y7RZWMFJSR` (`danebo-rag-prod`) lee `multimodal-source-destination`, prefijo `bulk_chunks/`. La misma lectura devolvió cinco veces `VF5.pdf`.
- `field_companion:start_clean_case` en dry-run abortó `no_row` para las dos cuentas locales probadas. Ninguna fila web tiene `identifier` igual al id del usuario. No se aplicó el inicio limpio. No hay `episode_id`.

Criterios de la matriz, los siete turnos y el clic: no ejecutados. No se convierten en cumplidos.

## 2. Turnos

| Turno | Mensaje | Resultado | Evidencia |
|---|---|---|---|
| 1 | El mensaje exacto de la matriz, sin enviar | No ejecutado | La pasada se detuvo antes de abrir la web |
| Clic | Tarjeta `126cda62-64ad-4469-8674-a29f12e38d48` | No ejecutado | La fila local que alimenta la tarjeta no existe |
| 2 | Comprobaciones de «la puerta se reabre sola» | No ejecutado | — |
| 3 | LED apagado y obstrucción no observada, dato simulado | No ejecutado | — |
| 4 | Corrección del LED a encendido | No ejecutado | — |
| 5 | Máster y esclavo con el LED encendido | No ejecutado | — |
| 6 | SW4 OFF, modo esclavo, dato simulado | No ejecutado | — |
| 7 | Resumen, corrección, configuración y pendiente | No ejecutado | — |

No hubo republicación del primer mensaje.

## 3. Respuestas para revisión

No hay respuesta publicada. No hay citas, consulta efectiva, filtro, chunks de una generación, ni delta de episodio. Esas piezas están ausentes porque el request del navegador no se hizo.

Las respuestas de referencia siguen solo en la matriz.

## 4. Primer bloqueo y causa demostrada

El bloqueo es de correspondencia, anterior a la interpretación y a la generación. No es un fallo semántico del modelo.

1. **Catálogo que pinta la tarjeta.** `Rag::DocumentDiscovery` ofrece la tarjeta solo si `Rag::KnowledgeScopePolicy.bind_catalog_candidate` encuentra una fila de `kb_documents` con la misma clave canónica, el mismo `document_uid` y la cuenta resoluble. En `smart_deal_development` hay 25 documentos. La consulta por uid `126cda62-64ad-4469-8674-a29f12e38d48`, por `VF5` en el nombre y por la clave devolvió cero filas. `bulk_upload_assets` tampoco tiene ese nombre, esa clave ni ese SHA. La identidad YAML sí tiene la fila, con cuenta de catálogo `1`. Esta ejecución trató crear la fila local como fuera de autorización y no la escribió. Esa lectura mezclaba la fila de metadatos con una ingesta. La ingesta sí seguía fuera de autorización. La fila local se preparó en la pasada posterior, sin ingesta.

2. **Documento recuperable.** El objeto de `multimodal-source-destination` coincide con el PDF del repositorio. En `smart-deal-dev-kb` la misma clave responde `NotFound`. `GetKnowledgeBase` devolvió `QGVYLPTEGT` = `danebo-rag-dev`, data source `1ICX1LL7A5`, bucket `smart-deal-dev-kb`, prefijo `bulk_chunks/`. `Y7RZWMFJSR` = `danebo-rag-prod`, data source `PJ0N58DMHG`, bucket `multimodal-source-destination`, prefijo `bulk_chunks/`. Un `Retrieve` sin filtro, consulta «Módulo electrónico VF5+ Fermator la puerta se reabre sola», cinco resultados: en `QGVYLPTEGT` los archivos fueron `original.pdf` y `manual_plataforma_tijera_24_paginas.pdf`; en `Y7RZWMFJSR` los cinco fueron `VF5.pdf`. Un filtro `equals` sobre `original_source_uri` devolvió `ValidationException` en las dos bases y no se repitió con otra clave. Esa lectura sin filtro no demuestra que `QGVYLPTEGT` carezca de cualquier chunk homónimo; demuestra que esa consulta no lo trajo y que el objeto no está en el bucket de su data source.

3. **Fila de trabajo.** El dry-run con el prefijo acordado, sin `APPLY`, abortó `no_row` para `danebo-legacy` / `lahiri.sanchez@gmail.com` (cuenta 4, usuario 1) y para `index-account-1` / `stage2-journey-a@localhost.test` (cuenta 1, usuario 27). Hay 54 filas `channel=web`: 20 de la cuenta 1 y 34 con `account_id=3`, cuenta que ya no existe. Cero filas tienen `identifier` igual al id del usuario. La tarea no crea la fila. No se creó una sesión para poder aplicar el inicio.

La web y el worker no se arrancaron. Con la tarjeta imposible y sin fila seleccionable, abrirlos no habría recorrido el caso. El navegador no quedó bloqueado: no se llegó a usarlo.

## 5. Instrumentación y pruebas

La captura existente sigue siendo `Rag::ValidationCapture`, por hilo. `PILOT_AUDIT_CAPTURE` no la abre. La ruta que responde al navegador no la abría. Se añadió el mínimo para esta corrida local:

- `Rag::WebRequestCapture` abre la captura en el request, separa el archivo por `RAG_VALIDATION_CAPTURE_RUN` y por request, exporta antes de volver —también si la acción falla— y otro hilo no hereda el cubo. El worker de Solid Queue no recibe ese hilo.
- `WebValidationCapture` envuelve `RagController#ask` y `PinnedDocumentsController#create` / `#destroy`. No reescribe la respuesta. Si el cupo dispara `Rag::LocalPassLedger::Stop`, el request responde 503 `local_pass_budget`.
- `Rag::LocalPassLedger` cuenta y frena las llamadas del proceso. `Stage2RunBudget::PASS_CALL_CAP` sigue en 0. El cupo de esta pasada es otro: `RAG_LOCAL_PASS_GUARD`, `RAG_LOCAL_PASS_CALL_CAP` y `RAG_LOCAL_PASS_COST_CAP_USD`, y solo arma si `AWS_MAX_ATTEMPTS=1` y las bases del proceso son locales. El precio sale de `BedrockQuery`; un uso devuelto por el proveedor reemplaza el techo. `.env` no se modificó.
- `lib/tasks/field_companion.rake` carga el entorno si `ApplicationRecord` todavía no existe y hereda `::ApplicationRecord`. Sin eso, `bin/rake` y `bin/rails test` sin ruta abortaban al cargar la tarea, y el dry-run no podía correr.

Pruebas, sin AWS ni modelos: `test/services/rag/web_request_capture_test.rb`, `test/services/rag/local_pass_ledger_test.rb`, `test/controllers/web_validation_capture_test.rb`, `test/services/rag/validation_capture_test.rb` y `test/tasks/field_companion_reset_test.rb`. Una corrida, 45 tests, 521 aserciones, 0 fallos, semilla 47620. RuboCop sobre los once archivos Ruby de este cambio: 0 ofensas.

`bin/rails test` sin ruta, antes del arreglo de la tarea, moría en `test:prepare` con `FieldCompanionCleanStart::ApplicationRecord`. Después del arreglo, `bin/rake -T field_companion` lista las dos tareas. La suite completa, con el entorno de la pasada ya retirado del proceso, terminó en 4820 tests, 33910 aserciones, 0 fallos, 186 omisiones, semilla 1936.

## 6. Entorno efectivo

No se arrancó `bin/dev`. El proceso inspeccionado es el del dry-run, con el prefijo en el entorno del comando y `-e` no aplica a rake. `.env` se cargó y las variables ya exportadas no se pisaron. `.env` permanece con la sesión compartida encendida y sin los flags de episodio; no es la configuración de esta pasada.

| Dato | Valor observado |
|---|---|
| Rails | `development` |
| Modelo configurado | `global.anthropic.claude-haiku-4-5-20251001-v1:0` |
| KB del proceso | `QGVYLPTEGT`, nombre `danebo-rag-dev`, estado `ACTIVE` |
| KB de producción, solo lectura | `Y7RZWMFJSR`, nombre `danebo-rag-prod`, estado `ACTIVE` |
| Flags del dry-run | episodio true, turno true, alcance true, menú de hilo true, análisis `owner`, sesión compartida false |
| `AWS_MAX_ATTEMPTS` | `1` en ese proceso |
| Captura y cupo | no se exportaron: no hubo request web |
| Cuenta y usuario | no quedó una fila seleccionable; ver el bloqueo 3 |
| Sesión y episodio | ausentes |
| Manual enfocado | ausente |
| Web y worker | no arrancados; sus flags no se inspeccionaron |

## 7. Llamadas, tokens y costo

Generaciones, interpretaciones, análisis, republicaciones y reintentos de modelo: 0. Cupo autorizado: 24 llamadas y US$1. Consumo estimado por `bedrock_queries`: 0 filas nuevas y US$0. El ledger de la pasada no llegó a armarse en un request.

Lecturas de KB, fuera de ese cupo de generación y sin fila en `bedrock_queries`: dos `Retrieve` con resultado y dos intentos de `Retrieve` filtrado que devolvieron `ValidationException`. El precio de esas lecturas no está en la telemetría existente y no se inventa. `GetKnowledgeBase`, `GetDataSource` y la lectura S3 no son generaciones.

No se cambió el modelo, el prompt ni un parámetro para forzar un aprobado.

## 8. Archivos y árbol

SHA inicial: `a3def4ba5def5f065a42b1a87cd7e4ca3aae9a8c`. El SHA final es el commit que añade este archivo.

Código de la captura, del cupo local y del arranque de la tarea. Documentación: este registro, la matriz, la nota de selección, el plan operativo y `docs/README.md`. No hay captura voluminosa en disco: no se abrió `RAG_VALIDATION_CAPTURE_RUN`. No se suben secretos. No hay push ni deploy.

## 9. Siguiente acción mínima

Esta pasada no se repite desde aquí. La autorización para leer `Y7RZWMFJSR` ya existía; este cierre la dejó como si todavía hubiera que decidirla. La pasada posterior creó la fila local del uid ya existente, abrió la sesión web y ejecutó los siete mensajes. Su resultado no es una aceptación: [EJECUCION_FERMATOR_VF5_REABRE_SOLA_2026-10-20.md](EJECUCION_FERMATOR_VF5_REABRE_SOLA_2026-10-20.md).
