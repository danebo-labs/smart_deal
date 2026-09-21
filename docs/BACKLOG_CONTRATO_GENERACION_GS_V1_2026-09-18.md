# Backlog: contrato de generación gs-v1

Origen: cierre D18 del plan [PLAN_RAG_RAZONAMIENTO_TECNICO_2026-09-15.md](PLAN_RAG_RAZONAMIENTO_TECNICO_2026-09-15.md). **No es una Fase D de ese plan.** Cada ítem es una mejora del contrato de generación: necesita su propia medición, su propio presupuesto y una decisión de tocar `generation.txt`. Hasta entonces el contrato permanece congelado (`6a8abaed…`, flag on).

Línea base de comparación: `tmp/razonamiento_tecnico/fase_b/bateria_2026-09-17.txt` (`c186b5ff…`), previa a la nota interna. No re-correr esa batería como si el corpus no hubiera cambiado.

| # | Hallazgo | Qué no es |
| --- | --- | --- |
| 1 | El rótulo `Interpretación técnica:` no se emite (0/52). Compactarlo (~25 tokens) o reformularlo para que dispare. Obliga a humo + batería nueva. | Ausencia de razonamiento. B14 r2 gs-v1 interpreta sin el rótulo. |
| 2 | 12 de 16 preguntas gs-v1 piden más de un dato. Puede ser que la regla de «una sola» sea irreal para taller. Decisión de producto. | Defecto a parchear en caliente. |
| 3 | Marcadores `[n]` apilados al final en B01, B02, B05, B13 y B14 gs-v1. Pérdida de trazabilidad por afirmación. Candidato a D9. | Señal de que gs-v1 no sintetiza. |
| 4 | Enumeración de catálogo (22/26 gs-v1, 23/26 estricta). Endémico, anterior a gs-v1. La Fase 4 ya pidió solución determinista en Rails, no otra prohibición en el prompt. | Palanca de este contrato. |
| 5 | B12: la copia `rag.generation_retry` (D14) es genérica y desencaja en preguntas meta. Mejora de copia. | Rollback de gs-v1. |
| 6 | H8 (marcador `[n]` sobre frase interpretativa) no se midió porque el rótulo no existe. Se intenta cuando el ítem 1 exista. | Gate fallido. |

Fuera de este backlog de generación: el hueco del amarre real de cinco cables con varilla es un **límite declarado** del producto (nota rev. 0, B01 lo respeta). No se cierra con una receta inventada. Requiere un técnico con acceso al conjunto real; no es una tarea de ingeniería de este contrato.

## Ingesta web_v1 — identidad por uid, no por sha

Hallazgo D18 (18-sep), cerrado en el índice, **no** en el flujo. Sin Bedrock. No reabre el plan.

**Qué pasó.** La misma fuente (`fd4303e9…`) entró dos veces: `ce1e04be…` (kb 215) y `7cd6d699…` (kb 216). B01 las recuperó las dos. D18 bajó 215; Retrieve 8 hits, keep en rank 1, drop 0.

**No fue la reparación de identidad.** `SingleFileChunkingService` + `BatchResultsParserService` escriben `bulk_chunks/<account_id>/<document_uid>/`. La reparación de C hizo `upload_text` sobre esas mismas keys. El parser, en `web_v1`, ni siquiera borra el prefijo antes de reescribir (`delete_existing_chunks` solo corre en `manual_batch_v1`). Un prepend no acuña uid.

**Sí fue un segundo mint de uid.** El uid se acuña **antes** del parse:

- Chat: `RagQueryConcern` hace `documents.map { SecureRandom.uuid }` y `QueryOrchestratorService#upload_and_sync_attachments` cae a otro `SecureRandom.uuid` si la lista viene vacía.
- `CustomChunkingPipeline#ensure_kb_document_for` busca `(account_id, document_uid)`, nunca el sha del binario. El sha se calcula en el pipeline y se pasa a `SingleFileChunkingService` solo para el sidecar.
- El runner de C (18-sep, un solo uso, no versionado) hacía lo mismo: `document_uid = SecureRandom.uuid` y `KbDocument.create!`.
- `kb_documents` no tiene columna ni índice de sha. Únicos: `(account_id, document_uid)` y `(account_id, s3_key)`. `s3_key` es `uploads/<account_id>/<document_uid>/original.*`, así que incluye el uid: el mismo archivo produce otra key.
- El sha de fuente vive solo en el sidecar (`doc_sha256`). No hay forma de reusar la fila sin escanear S3.
- `ContentDedupService` no entra en este camino: es ledger ZIP (`BulkUploadAsset`). `SingleFileChunkingService` no lo consulta. `FieldPhoto` sí deduplica por `(account_id, sha256)`.

Los dos sidecars de la nota tenían el mismo `doc_sha256` (`fd4303e9…`) y **nombres canónicos Claude distintos** («Nota Técnica Interna Amarre Cables Suspensión» vs «Nota Técnica Amarre Cables Suspensión Rev0»). Eso es dos parses, no una reescritura del mismo prefijo. Secuencia operativa plausible: el primer `perform_now` abortó en STARTING **después** de create + chunks + sync; el runner se volvió a lanzar y acuñó otro uid. kb 215 y 216 son consecutivos.

El chat tiene el mismo hueco el día que vuelva a aceptar `.md` o PDF cortos: re-subir el mismo archivo duplica, y Retrieve no avisa. Esta vez se vio porque B01 citó los dos prefijos.

**Qué no hacer ahora.** No tocar `generation.txt`. No re-ingerir la nota. El arreglo es idempotencia de ingesta: persistir el sha de fuente en `kb_documents` (cuenta + sha único) y reusar `document_uid` en re-upload, reescribiendo el prefijo existente. Medición: re-subir el mismo binario no debe crear un segundo hit de Retrieve con otro uid.

