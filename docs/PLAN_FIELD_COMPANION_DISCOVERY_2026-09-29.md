# Plan Field Companion — Assisted Document Discovery (29-sep-2026)

**Estado:** master plan final. F0, F1, F2, F2B, F3, F3B1 y F3B2 están `PASS`. La evidencia visual de F1 quedó extendida a 15 imágenes (`E3`). F2 adoptó la letra B solo para Field Photo: default `claude-sonnet-5-5`, rama de 1,5 MB `claude-opus-5-5`. F2B adoptó `claude-sonnet-5-5` como `BatchChunkingPrompt::MODEL_TEXT` para la ingesta Batch de texto y para el retry Direct. Field Photo no se recableó. F3 es suggest-only: el ranker no escribe un pin. F3B1 es la autoridad de `knowledge_scope`. F3B2 alineó el retrieve abierto con esa autoridad. F4 está `PASS`: el tap escribe `user_pin` solo en la sesión actual. F5 está `READY` y no empezó. El prompt completo de la fase siguiente es el Anexo H.

**Objetivo:** el técnico dice marca y falla, con foto opcional. Danebo muestra `manual_candidate` de su biblioteca privada y de la biblioteca general de Danebo, y el técnico puede fijar ambos cuando el scope lo permite, sobre el mismo documento ya indexado. La foto se recuerda sin volver a pagarla. Una sugerencia no se presenta como dato del manual.

**Este archivo es la única fuente de verdad del ciclo.** Un chat nuevo no hereda memoria. Ejecuta la fase cuyo prompt está completo al final de Execution State. El prompt completo pendiente es el de F5, en el Anexo H. El Anexo A es el prompt de F0 ya ejecutado. El Anexo B es el prompt de F1 ya ejecutado. El Anexo C es el prompt de F2 ya ejecutado; el Resultado F2 corrige el alcance de `MODEL_TEXT`. El Anexo D es el prompt de F2B ya ejecutado. El Anexo E es el prompt de F3 ya ejecutado. El Anexo G es el prompt de F3B2 ya ejecutado. El Anexo F es el prompt de F4 ya ejecutado. La extensión no es una fase nueva y no cambia el `PASS` de F1.

**No reabrir:** [PLAN_PRECISION_WORDING_MULTILOOKUP_2026-09-29.md](PLAN_PRECISION_WORDING_MULTILOOKUP_2026-09-29.md). P4 quedó `PASS`. Los cuatro casos `BLOCKED` de ese plan siguen fuera: micros 30/31, llamadas 33/34, relés K1/K2 juntos, T1/T2 juntos. Los casos individuales que ya pasan no se tocan.

## Decisiones congeladas

1. **FC-D01.** Discovery en este plan es A (sugerir) y después B (foco con tap). El modo C / auto-focus no se implementa. F8 puede cerrar en `KEEP_B` o en `PROPOSE_PLAN_C`. `PROPOSE_PLAN_C` no autoriza código de auto-focus. No existe umbral que dispare auto-focus.
2. **FC-D02.** `RagRetrievalProfile` no se modifica. No se sube ningún top-k. No se agrega filtro Bedrock por fabricante.
3. **FC-D03.** Sin LLM nuevo para discovery ni para procedencia. La visión de una foto de campo sigue siendo una llamada Anthropic Direct. El texto sigue siendo un `retrieve_and_generate` con `BEDROCK_MODEL_ID`.
4. **FC-D04.** F1 compara solo `claude-sonnet-5-5` y `claude-opus-5-5`, con los mismos bytes, MIME, filename, locale, photo intent, system prompt fingerprint y `max_tokens`. `claude-sonnet-5` es el default productivo de HEAD y no es un brazo del benchmark. F0 y F1 no cambian ese default.
5. **FC-D05.** La foto no entra a la KB, no se escribe bajo `bulk_chunks/` y no se vuelve `KbDocument`.
6. **FC-D06.** Este plan cubre web móvil táctil y frases que se pueden leer en voz alta. No entrega TTS, ni STT del chat de mantenimiento, ni la iniciativa de voz del roadmap.
7. **FC-D07.** `DOCUMENT_IDENTITY_SCOPE_ENABLED` no se enciende como sustituto del foco. El único estrechamiento de retrieve es un pin ya existente.
8. **FC-D08.** El aviso fijo de verificación de cada respuesta de texto no se quita en F6 ni en F7.
9. **FC-D09.** Conocimiento documental. Los scopes canónicos son `tenant_private` y `danebo_general`. No se usan las variantes “global docs”, “public docs”, “cross-account docs” ni “common account docs”. `UNCLASSIFIED` se comporta como `tenant_private`. Default deny: otro tenant usa el documento solo si `knowledge_scope == danebo_general`. No se infiere ese scope por `account_id`, filename, fabricante, carpeta, ni por vivir en Legacy o Pilot. Un documento de un cliente o de un tercero no pasa a `danebo_general` sin una decisión explícita de Danebo sobre ese documento. F0 no aprueba documentos. El target de foco: un `manual_candidate` con scope `danebo_general` es visible, recuperable y pineable desde un tenant autorizado, el mismo objeto físico, sin copia y sin reindex. El tap sigue siendo `user_pin`. No existe `assisted_focus`. La telemetría `manual_focus_confirmed` marca el pin que nació de una sugerencia. F4 no usa `unscoped`, no busca privados de otra cuenta, y no apaga la autorización. Si F0 no confirma una ruta con `reindex_required = false` y `duplicate_document_required = false`, F4 queda `BLOCKED`.
10. **FC-D10.** `canonical_component` no confirma `equipment_identity`. Un conflicto de identidad no se resuelve en silencio.
11. **FC-D11.** `FieldPhoto` es la autoridad de `visual_observation`. El episodio solo guarda `active_photo.field_photo_id` y, si ya existe, `sha256`. La observación no es historial de diagnóstico.
12. **FC-D12.** El precio de `claude-sonnet-5-5` no está en `BedrockQuery::BEDROCK_PRICING`. Queda `UNKNOWN` hasta una fuente citada. No se copia la tarifa de `claude-sonnet-5-direct` ni se deja caer en la clave `default`.
13. **FC-D13.** El score de la sección 5 no cambia. El scope filtra elegibilidad y no suma puntos. F3 puede devolver privados de la cuenta del técnico y documentos `GENERAL_APPROVED`. No puede devolver `PRIVATE` ni `UNCLASSIFIED` de otra cuenta.
14. **FC-D14.** La procedencia documental (`danebo_general` / `tenant_private`) no es la procedencia de la respuesta (`MANUAL_FACT` / `VISUAL_OBSERVATION` / `DANEBO_GUIDANCE`). Un `MANUAL_FACT` puede salir de cualquiera de los dos scopes. La etiqueta de biblioteca no afirma compatibilidad de equipo.
15. **FC-D15.** El general se indexa una vez por documento. Eso evita, por tenant, otro upload, otro parse, otro index, otros embeddings y otra copia en storage. F0 no inventa un ahorro en dólares.
16. **FC-D16.** `danebo_general` es elegibilidad y visibilidad del documento. `user_pin` es el foco de la cuenta y de la sesión que lo creó, en `conversation_sessions.active_entities`. Si la cuenta A pinea un `danebo_general`, la cuenta B no cambia de catálogo ni de foco. Cada sesión puede pinear otro general, varios generales, o generales junto con `tenant_private`, y puede cambiar o quitar esos pins. Un pin no es estado global ni una restricción del catálogo general.
17. **FC-D17.** Los pins son editables por el usuario. Puede agregar, quitar, cambiar de manual, pinear varios, combinar `danebo_general` con `tenant_private`, y aceptar una sugerencia de discovery. Eso es una acción del usuario. El sistema no relaja, no quita y no ignora en silencio ese conjunto cuando el retrieve no encuentra evidencia. Con pins X e Y, la búsqueda queda en X e Y. Puede informar que no hubo evidencia en los documentos seleccionados y puede ofrecer ampliar. Ampliar el corpus solo ocurre si el usuario lo confirma o cambia los pins. Un pin editable no autoriza `X + Y` → corpus abierto.
18. **FC-D18.** Que `claude-sonnet-5-5` no esté en constants de producción no bloquea F0 ni F1. El benchmark usa un harness propio, no el routing productivo. Los ids se congelan en el harness: `claude-sonnet-5-5` y `claude-opus-5-5`. El harness no consulta `BatchChunkingPrompt::MODEL_TEXT` para elegir modelo, no usa `FieldPhotoDensityGate`, no cambia constants ni producción, y no hardcodea credenciales. La clave es `ANTHROPIC_API_KEY`, o el mismo fallback que `ClaudeChunkingClient#build_client`. Cada llamada fuerza el modelo y guarda `requested_model_id` y `returned_model_id`. F1 manda los mismos bytes, MIME, filename, locale, photo intent, prompt y `max_tokens` a los dos. F0 hace antes un probe multimodal mínimo de `claude-sonnet-5-5`. F2 puede tocar el constant productivo solo si su letra adopta ese id.

## Roadmap

| Fase | Nombre | Qué cambia | Gate |
|---|---|---|---|
| F0 | Contract freeze / audit | Cero comportamiento de producto. Inventario Legacy/Pilot sin aprobar nada. Probe multimodal del harness, sin tocar constants | PASS solo con los entregables del Anexo A. Si el SHA256 de `resortes.png` no coincide con el congelado, o si el probe de `claude-sonnet-5-5` con imagen no queda registrado, F0 = `BLOCKED` y F1 no arranca. El inventario igual se escribe. La ausencia del id en `MODEL_TEXT` no bloquea |
| F1 | Visual model benchmark | Ningún default. Dos modelos, mismos bytes | PASS con pares completos y evaluador mecánico. `BLOCKED` si F0 no dejó manifest con hashes |
| F2 | Visual decision | Una sola variable, la que F1 autorice | A, B, C, D o E. E = `SKIP` |
| F2B | Ingestion Model Refresh | Comparar `claude-sonnet-5` y `claude-sonnet-5-5` sobre el payload real de Anthropic Batch API. No toca el default de Field Photo | No empieza hasta que F2 esté `PASS`. Sin dataset con hashes, `BLOCKED` y cero llamadas. No inventa gold |
| F3 | Discovery A, suggest-only | Ranker en runtime, sin pin. Elegibilidad por scope, mismo score | Paridad del score con el artefacto F0. Cero candidatos `PRIVATE` o `UNCLASSIFIED` de otra cuenta |
| F3B1 | Authorization Foundation | `kb_documents.knowledge_scope` es la autoridad de lectura. Audit append-only. Pin set atómico. `DENY_RETRIEVAL` no llama a Bedrock | PASS. Al cerrar, el retrieve abierto histórico seguía. F3B2 después lo alineó |
| F3B2 | Retrieval Alignment | Sacar Legacy, Pilot y `manual_corpus=general` como autorización. Revocación global, post-filter, recall, backfill del ledger | PASS. F4 `READY`. El retrieve abierto es la cuenta más `danebo_general`. No hubo deploy |
| F4 | Confirmed Focus | Tap → `user_pin` para privado del tenant y para `danebo_general` | PASS. El técnico confirma. No hay auto-focus. El pin es de la sesión. F5 `READY`. No hubo deploy |
| F5 | Image continuity | Reuso de `visual_observation` | `STOP` antes de migrar si F0 marcó contradicción de retención |
| F6 | Provenance contract | Prompt y contrato servidor | Una sugerencia no puede quedar como `MANUAL_FACT` |
| F7 | Provenance presentation | Solo renderer | No edita el prompt. Funciona con `SHOW_RAG_SOURCES=false` |
| F8 | Field pilot / next decision | Sin feature | `KEEP_B` o `PROPOSE_PLAN_C` |

## Cómo termina una fase

Una fase no termina hasta completar, en este orden:

1. Tests de la fase.
2. Regression gate (comando de abajo).
3. Artefactos con SHA256.
4. Commit.
5. Fila de Execution State.
6. Findings `CONFIRMED` / `REJECTED` / `NEW`.
7. Revisión de todas las fases futuras.
8. Edición de las fases futuras que el hallazgo cambie.
9. Reescritura completa del prompt de la fase siguiente, con paths, hashes, flags y resultados. Prohibido dejar “leé la fase anterior”.

Un hallazgo normal se incorpora solo. `STOP` solo si: contradice una decisión congelada; la ruta de `danebo_general` no cumple FC-D09; pide una migración destructiva; pide gasto fuera del budget de esa fase; falta la evidencia que el gate nombra; o hay que reabrir el plan de precisión. Quitar el brazo de cuentas compartidas del filtro, o dejar de confiar en `manual_corpus=general` como si fuera una aprobación, es trabajo de F3/F4 y solo después de que F0 confirme la ruta. F0 no lo hace.

## Regression gate

Todas las fases corren, además de sus tests:

```
bin/rails test \
  test/services/rag_retrieval_profile_test.rb \
  test/services/rag/structured_evidence_route_test.rb \
  test/services/field_photo_analysis_service_test.rb \
  test/services/field_photo_density_gate_test.rb \
  test/services/image_compression_service_test.rb \
  test/jobs/field_photo_analysis_job_test.rb \
  test/services/pilot_usage_log_test.rb
```

Ese gate no llama Bedrock ni Anthropic. No se relanza el probe vivo del plan de wording.

## Presupuesto

- **F0:** una llamada Anthropic con imagen, `max_tokens` 16, modelo forzado `claude-sonnet-5-5`, fixture `docs/field_companion/multimodal_availability_probe.jpg`. Directo con `Anthropic::Client`, no con `ClaudeChunkingClient`, para no encolar `TrackBedrockQueryJob` ni escribir `bedrock_queries`. Credencial `ANTHROPIC_API_KEY` o el mismo fallback de `ClaudeChunkingClient#build_client`. No se imprime la API key. No se evalúa calidad. Opus no entra en este probe.
- **F1:** como máximo 16 imágenes × 2 modelos = 32 llamadas, una por par, sin reintento, `max_tokens` = `BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS` (8000). Una tercera llamada por imagen, un tercer modelo, o más de 16 imágenes es `STOP`.
- **F2:** el budget depende de la letra. A o B: cero llamadas de imagen; solo el cambio de constante si la letra lo dice. C: una llamada nueva por imagen del manifest, solo `claude-sonnet-5-5`, bytes de lado largo 2048. D: una llamada nueva por imagen, solo `claude-sonnet-5-5`, prompt nuevo, bytes de control de F1. E: cero llamadas. La letra B cerrada no hizo llamadas.
- **F2B:** cero llamadas hasta que exista un dataset de páginas reales con SHA256. La comparación no está autorizada por el cierre de F2. No se ejecuta en el commit de F2.
- **F3–F8:** cero llamadas de modelo nuevas, salvo que un test ya mockee el cliente.

## 1. Producción visual hoy (contexto, no control de F1)

HEAD enruta la foto de chat así:

- Proveedor: Anthropic Direct, `ClaudeChunkingClient`, `ANTHROPIC_API_KEY`.
- [app/services/field_photo_density_gate.rb](../app/services/field_photo_density_gate.rb): binario `>= 1_500_000` bytes → `BatchChunkingPrompt::MODEL_MULTIMODAL` = `claude-opus-5-5`. Si no, `MODEL_TEXT` = `claude-sonnet-5`.
- `white_ratio` se loguea y no elige modelo.
- El generador de texto es Haiku vía `BEDROCK_MODEL_ID`. No recibe bytes de imagen.
- `claude-sonnet-5-5` no aparece en el HEAD de F0 y F1. Esa ausencia no bloquea el benchmark. F0 lo prueba con el harness y el JPEG de 4×3. F0 no asigna `MODEL_TEXT`. Después de F2 el chat usa `FieldPhotoAnalysisService::DEFAULT_MODEL`. `MODEL_TEXT` sigue en `claude-sonnet-5`. El mapa de esta lista es el de antes de F2.

Tarifas ya escritas en [app/models/bedrock_query.rb](../app/models/bedrock_query.rb), dólares por 1.000 tokens, solo como mapa de lo que el repo sí conoce:

- `claude-sonnet-5-direct`: input 0,002 / output 0,01.
- `claude-opus-5-5-direct`: input 0,004 / output 0,02.
- `claude-sonnet-5-5` y `claude-sonnet-5-5-direct`: ausentes de `BEDROCK_PRICING`. `pricing_for` de un id desconocido cae en `default` (input 0,00025 / output 0,00125). Esa caída no se usa para Sonnet 5.5.

F1 citó la fila Claude Sonnet 5.5 de <https://platform.claude.com/docs/en/about-claude/pricing>: input $2 / MTok y output $10 / MTok, esto es 0,002 y 0,01 dólares por 1.000 tokens. El harness usó esa URL como `price_source`. No escribió `BEDROCK_PRICING`. El costo registrado en `f1_visual.json` es solo input y output. Los tokens de `cache_creation` están en el artefacto y quedan fuera de esa cifra. Cache read de esa fila: $0,20 / MTok. Cache write de 5 minutos: $2,50 / MTok. La write de 1 hora ($4 / MTok) no corresponde al `cache_control` ephemeral del system prompt.

## 2. Preprocesado de imagen

No toda imagen llega a 1024 px.

1. **Canvas, camino feliz** — [app/javascript/controllers/rag_chat_controller.js](../app/javascript/controllers/rag_chat_controller.js) `compressImageOnClient`. Si el lado largo pasa de 1024, se escala. Si no, se conserva el tamaño. JPEG calidad 0,82. Tope de entrada 25 MB. Tope de salida 3,75 MB.
2. **Canvas, fallback** — el `catch` del mismo método. Si Canvas falla y el archivo ya cabe en 3,75 MB, se mandan los bytes originales y el MIME original. No hay reescalado.
3. **Servidor** — [app/services/image_compression_service.rb](../app/services/image_compression_service.rb). `should_skip_compression?` es verdadero cuando el binario decodificado es `<= MAX_BINARY_BYTES` (3,75 MB). En ese caso no hay Vips: salen los mismos bytes y el mismo MIME.
4. **Servidor, cuando no salta** — lado máximo 1024, JPEG, calidad estimada, y un segundo pase a calidad 40 si todavía supera 3,75 MB.

Consecuencia: una foto que el Canvas ya dejó bajo 3,75 MB llega a Anthropic en esos bytes, que pueden ser de lado largo 1024 o menores, o los originales si Canvas falló. F1 no vuelve a comprimir por modelo. Hashea el binario que las dos llamadas reciben.

## 3. Matriz real de `RagRetrievalProfile`

`number_of_results` en [app/services/rag_retrieval_profile.rb](../app/services/rag_retrieval_profile.rb), en este orden. La primera rama que aplica gana.

| Orden | Condición | k |
|---|---|---|
| 1 | `exhaustive_query?` | `EXHAUSTIVE_CANDIDATES` = 15. `number_of_reranked_results` = 12, y solo si `BEDROCK_RERANKER_ENABLED` es `true` (`BedrockRagService#reranking_config`) |
| 2 | `entity_sources` vacío y `schematic_block_query?` | `MAX_RESULTS` = 20 |
| 3 | `entity_sources` vacío, resto | `OPEN_RESULTS` = 8 |
| 4 | hay sources y `safety_critical_query?` | `SAFETY_CRITICAL_RESULTS` = 5 |
| 5 | solo `image_upload`, ningún `document` | `PHOTO_RESULTS` = 10 |
| 6 | resto con sources (solo documentos, o foto mezclada con documento) | `PINNED_DOCUMENT_RESULTS` = 3 |

`StructuredEvidenceRoute#initial_result_count` puede pedir `STRUCTURED_MAPPING_RESULTS` = 12 en lugar del k del perfil cuando no es safety ni exhaustive y la pregunta es `structured_mapping_query?` o exact designator lookup. El rescue de ese camino, si corre, pide otra vez k=3 sobre la misma URI. Foto + pregunta no entra a esa ruta: `PhotoQuestionAnswerService` no pasa `conv_session`, `entity_sources` queda `[]`, y `eligible?` exige `"document"`. Si hay pin, las URIs sí viajan y el filtro de pin aplica; el k de esa llamada es el de sources vacíos (8, o 20 si es esquemático), no 3.

El filtro de retrieve es independiente del k. `RagRetrievalProfile` no cambia. Sin URIs, `account_filter` es el `account_id` de la sesión más las URIs canónicas de filas ajenas con `knowledge_scope = danebo_general`, en `original_source_uri` y `x-amz-bedrock-kb-source-uri`. Legacy, Pilot y `manual_corpus=general` no son cláusulas. Con URIs: solo esas URIs (`document_pin_filter`), y el conjunto entero pasa por `Rag::KnowledgeScopePolicy`. F0 registró el OR histórico de cuentas compartidas. Ese OR ya no autoriza. FC-D16: el filtro de pin no escribe nada sobre el documento general. La cuenta B, sin ese pin, sigue viendo el mismo `danebo_general` en su catálogo y puede pinear otro.

## 4. Identidades

Tres objetos distintos.

- **`equipment_identity`:** fabricante y, si está dicho, modelo. Lo dice el técnico, o lo imprime una placa (`manufacturer` / `model` visibles, no `UNKNOWN`). No sale de `canonical_component`.
- **`canonical_component`:** campo visual. Nombra el conjunto. No confirma el equipo.
- **`document_identity`:** una `DocumentIdentityCatalog::Entry`: `brands`, `designators`, `display_name`, `document_id`.

`catalog_confirmed` = `DocumentIdentityCatalog.effectively_confirmed?(entry)`. Eso exige `confirmed == true`, `evidence_page` entero positivo, y `evidence_text` presente. El booleano YAML solo no alcanza.

Reconocimiento de fabricante en el texto: `ActiveEpisodeTurn::MANUFACTURERS`, el más largo primero, sobre `FollowupQueryRewriter.normalize_label`. `KbDocumentResolver::BRANDS` no define discovery; sigue en su uso actual (`specific_token?`).

Matching de candidatos: `Entry#brands`, comparado con el fabricante ya normalizado.

Join: el `document_id` del YAML es `KbDocument.document_uid`. No existe columna `kb_documents.document_id`. El lookup de catálogo ya hace `for_document` por `document_uid` en [app/services/rag/document_identity_catalog.rb](../app/services/rag/document_identity_catalog.rb).

**`identity_conflict`:** `equipment_identity` declarada por el técnico y la identidad impresa en la placa, incompatibles. Incompatibles significa: fabricantes normalizados distintos, o ambos con modelo y los modelos normalizados distintos. Un lado `UNKNOWN` o en blanco no conflicta. No se elige un ganador.

**`pin_conflict`:** `equipment_identity` explícita incompatible, con la misma regla, con la `document_identity` del pin (`Entry#brands` / designadores). No se despinea solo.

## 5. `manual_candidate`

Un `manual_candidate` es un `KbDocument` cuya `document_identity` coincide con una identidad explícita disponible (fabricante reconocido en el turno, y designador solo si el turno lo trae).

No se usa la frase “manual compatible”.

- Coincidencia solo de marca. Texto fijo: `manual de la misma marca; compatibilidad con este equipo no confirmada`.
- Coincidencia exacta de modelo o designador. Texto fijo: `el documento coincide con el modelo/designador indicado`.
- Cero candidatos, o más de un fabricante en el turno. Texto fijo: `No encontré un manual claramente asociado a esa identidad en la biblioteca actual.`

### Función de score (F0 la implementa en el script; F3 la copia tal cual)

Entrada: lista de `Entry` y el texto del turno. Sin red.

1. Normalizar el turno con `FollowupQueryRewriter.normalize_label`.
2. Fabricantes: recorrer `MANUFACTURERS` de mayor longitud a menor. Un fabricante entra si su forma normalizada es una palabra entera del turno normalizado (separadores ya son espacios). Si hay dos distintos, el resultado es `[]` con `reason: multiple_manufacturers`. Si hay cero, `[]` con `reason: no_manufacturer`.
3. `model_tokens`: la captura de `ActiveEpisodeTurn::MODEL_VALUE_RE` si existe y, ya normalizada, no está en `MODEL_DECLARATION_STOPWORDS`; más toda palabra del turno normalizado que contenga un dígito y sea igual, ya normalizada, a algún `entry.designators`. Si no hay ninguna, la lista va vacía.
4. Un entry es candidato solo si algún `entry.brands`, normalizado, es igual al fabricante. Si no, no entra. Eso es lo que hace que `wrong-brand candidate rate` deba dar 0; el artefacto igual lo calcula.
5. Puntos, enteros: `100` por marca. `+80` si algún `model_token` es igual a algún designador normalizado. `+40` si `effectively_confirmed?`. No hay puntos por substring del `display_name`.
6. Etiqueta: `EXACT_DESIGNATOR` si sumó los 80. Si no, `BRAND_ONLY`.
7. Orden: score descendente, `display_name` normalizado ascendente, `document_id` ascendente. Se devuelven como máximo 3.
8. `tie_at_top` es verdadero si dos o más de los devueltos comparten el score máximo. F4, cuando eso pasa, hace una pregunta y no pinea. F0 solo registra el booleano.

Métricas del artefacto, sobre el fixture y otra vez sobre el holdout. El holdout no se usa para cambiar la función.

- `precision_at_3`: gold de una frase = los `document_id` del catálogo cuyo brand normalizado es el fabricante esperado y, si la frase trae designador esperado, cuyo designador normalizado es ese. Si el ranker devuelve vacío y el gold también, precisión 1. Si devuelve vacío y el gold no, precisión 0. Si no, `|top3 ∩ gold| / |top3|`.
- `top1_accuracy`: el primer id está en el gold, o ambos vacíos.
- `wrong_brand_candidate_rate`: candidatos devueltos cuyo brand no es el fabricante, dividido por candidatos devueltos. Denominador 0 → 0.

Frases del fixture, en este orden, texto literal:

1. `Estoy en un Schindler y la puerta no cierra.`
2. `Estoy en un OTIS y tengo este problema.`
3. `Elemont MH, la seguridad no actúa.`
4. `Estoy en un KONE.`
5. `Tengo un problema en la puerta.`
6. `Estoy en un AcmeLifts modelo ZX9.`
7. `Schindler y OTIS en el mismo hueco.`

Holdout, no se edita después de escrito en el artefacto F0:

1. `Estoy con un Schindler.`
2. `El tablero es Elemont.`
3. `KONE modelo MonoSpace, la puerta no abre.`
4. `Mitsubishi, no cierra la puerta.`
5. `Revisando el equipo.`

`MonoSpace` no lleva dígito y no sale de `MODEL_VALUE_RE` si la frase no dice `modelo`. La frase 3 del holdout dice `modelo MonoSpace`: el token entra por `MODEL_VALUE_RE`. El síntoma (“puerta”) no suma puntos y no llama a retrieve.

## 6. Conocimiento general — auditoría de F0

La pregunta de esta sección no es si una cuenta puede pinear documentos de otra. La pregunta es cuál es la representación mínima y la ruta de autorización para que un documento marcado `GENERAL_APPROVED` sea un recurso compartido de Danebo: listable, recuperable y pineable desde un tenant autorizado, sin duplicar y sin reindexar, mientras `PRIVATE` y `UNCLASSIFIED` siguen aislados.

### Contrato

| Scope | Inventario | Quién lo ve |
|---|---|---|
| `tenant_private` | `PRIVATE`, y también `UNCLASSIFIED` | Solo el tenant dueño del documento |
| `danebo_general` | `GENERAL_APPROVED` | Tenants autorizados. Una sola ingesta. Cada sesión pinea la misma fila si quiere. El pin no es del catálogo |

Textos de UI, procedencia documental, no compatibilidad de equipo:

- `danebo_general`: `Biblioteca general de Danebo`
- `tenant_private`: `Tu biblioteca`

La ubicación física puede seguir en Legacy o Pilot. Eso no es el scope.

`danebo_general` no guarda pins. El foco vive en `active_entities` de la `ConversationSession` de esa cuenta. La cuenta A puede pinear un general, varios generales, o generales más privados suyos. Quitarlo o cambiarlo no borra el documento, no lo saca de la biblioteca de la cuenta B, y no toca los pins de B. F0 no propone una columna de pin en `KbDocument` ni un pin compartido entre cuentas. El usuario puede cambiar esos pins. El sistema no los suelta solo porque el retrieve vino vacío. FC-D17.

### HEAD, que F0 no cambia

Hoy el acceso no es el contrato. F0 lo registra así:

1. Biblioteca: `RecentKbDocumentsQuery` usa `KbDocument.where(account_id: account.id)`.
2. Pin: `PinnedDocumentsController#create` usa `current_account.kb_documents.find`. Otra cuenta da `RecordNotFound`.
3. Retrieve abierto: `BedrockRagService#account_filter` incluye la cuenta de la sesión, las cuentas de `Rag::SharedManualCorpus` (`danebo-legacy`, `danebo-pilot-elevator`, fotos `field_photo_v1` excluidas) y los chunks con `manual_corpus=general`.
4. `Rag::SharedManualCorpus.tag?`: si `corpus_scope` viene omitido y la cuenta es uno de esos slugs, el chunk se marca general. Ese default infiere compartir por cuenta. El contrato lo prohíbe como aprobación.
5. Con pin: `document_pin_filter` deja solo las URIs de esa sesión. No mantiene el OR de cuentas. No modifica el documento ni el catálogo de otra cuenta. FC-D17: si no hay evidencia, HEAD no debe leerse como permiso para soltar el pin. El web path ya manda `force_entity_filter: true`. La rama `retry_without_entity_filter` existe solo cuando el filtro no fue forzado. No es la regla de producto y este plan no la borra en F0.

El mecanismo que F0 observó era CASE B. `manual_corpus=general` participaba en el retrieve abierto y no demostraba una aprobación por documento. F0 respondió `NEED_DOCUMENT_LEVEL_APPROVAL_SOURCE`. F3B1 puso la autoridad en `kb_documents.knowledge_scope`. F3B2 dejó de usar Legacy, Pilot y `manual_corpus` para conceder acceso. El párrafo de arriba es el registro de F0, no el filtro actual.

`RagRetrievalProfile` y `StructuredEvidenceRoute` no se tocan. FC-D02 sigue igual. El corpus autorizado de un tenant, cuando la ruta exista, es sus `tenant_private` más los `danebo_general`. Los privados de otros tenants no entran.

### Matriz

F0 escribe `tmp/field_companion/f0_authorization_matrix.json`. Una fila por `document_uid` del ranking del fixture, más una fila por documento del inventario de Legacy y Pilot. Si la DB local no está, `db_checked: false` y la fila sale de la regla de código y del YAML.

Columnas:

- `document_uid`
- `physical_owner_account_id`
- `current_visibility`
- `current_retrievability`
- `current_pinnability`
- `proposed_knowledge_scope`: `tenant_private` o `danebo_general`
- `current_mechanism`
- `minimum_change`: el diff mínimo de código o de dato, sin implementarlo
- `reindex_required`
- `duplicate_document_required`

Target de la ruta que F0 busca, no un resultado que F0 pueda forzar: `reindex_required = false` y `duplicate_document_required = false` para `danebo_general`. Si la única forma de separar `GENERAL_APPROVED` de un chunk ya marcado general por el default del slug exige un atributo nuevo en el chunk, F0 pone `reindex_required = true` en esa opción, no la elige, y F4 queda `BLOCKED`. F0 puede describir más de una opción. No implementa ninguna.

Input explícito, sin resolverlo en esta enmienda: los chunks de Legacy y Pilot ya pueden llevar `manual_corpus=general` por el default de `tag?`. Ese atributo no distingue una aprobación de Danebo. F0 dice si hace falta otro dato, y si ese dato obliga a reindexar.

### Inventario

F0 escribe `tmp/field_companion/f0_general_inventory.json` con cada `KbDocument` de las cuentas `danebo-legacy` y `danebo-pilot-elevator`.

Clasificación, una sola:

- `GENERAL_APPROVED`: existe una marca explícita de Danebo sobre ese documento, y esa marca no es el slug ni el default de `corpus_scope` omitido. HEAD no tiene esa columna. Si F0 no encuentra una marca así, el conteo de `GENERAL_APPROVED` es cero.
- `PRIVATE`: hay una marca explícita de alcance de cuenta (`corpus_scope: "account"` u otra equivalente ya persistida).
- `UNCLASSIFIED`: todo lo demás, incluidos los manuales ingeridos para Gonzalo o Jesús. Se comporta como `tenant_private`.

F0 no asigna `GENERAL_APPROVED`. No lee el nombre del archivo ni el fabricante para aprobar. Los planes de ingesta históricos no son una aprobación.

### Elegibilidad y score

El score de la sección 5 se calcula igual. Antes de devolver candidatos, se descartan los que el tenant no puede usar: un documento de otra cuenta que no sea `GENERAL_APPROVED`. El artefacto `f0_discovery.json` guarda el ranking técnico completo, sin ese filtro, para que F3 pruebe paridad del score. El artefacto `f0_discovery_eligible.json` guarda la lista después del filtro. Con el inventario en `UNCLASSIFIED`, la lista elegible para un viewer que no es el owner queda vacía de esos documentos. Eso es el resultado correcto de esta enmienda, no un bug del score.

### Costo

FC-D15. F0 puede contar documentos y citar un costo de ingesta ya escrito en un plan histórico. No calcula un ahorro futuro.

### Resultado F0

La DB local se consultó. `danebo-legacy` es la cuenta `4`, con 17 `KbDocument`, todos `UNCLASSIFIED`. No existe una cuenta local `danebo-pilot-elevator`. `GENERAL_APPROVED` = 0 y `PRIVATE` = 0. `kb_documents` no tiene columna `knowledge_scope` ni `corpus_scope`. `confirmed` en `config/document_identities.yml` es evidencia de marca, no una aprobación. Los ids `"1"` y `"3"` de ese YAML son ids de índice, no `accounts.id` local. Una fila de la matriz sin `KbDocument` local lleva `physical_owner_account_id` null y `catalog_index_account_id`.

Respuesta: `NEED_DOCUMENT_LEVEL_APPROVAL_SOURCE`. La opción elegida es `existing_document_id_session_pin`: el retrieve abierto usa el `document_id` ya escrito en el chunk, y el pin es `user_pin` en `active_entities` de la sesión sobre la fila `KbDocument` existente. `reindex_required = false` y `duplicate_document_required = false`. No se elige `new_chunk_attribute` (`reindex_required = true`). F0 no crea el registro de aprobación, no agrega columna y no cambia la autorización.

## 7. Observación visual

Target de F5, no de F0. F0 solo confirma que cabe en el schema y en la retención.

Columna nueva, en F5: `field_photos.visual_observation`, `jsonb`, nullable. Misma fila, mismo `account_id`, mismo borrado que `FieldPhotoRetentionJob` (default 90 días, `FIELD_PHOTO_RETENTION_DAYS`). Una foto citada por `InspectionFinding` no se purga; la observación se va con la fila el día que la fila se vaya. No hay tabla nueva. No es un diagnostic record. El cache de diagnóstico que [docs/PRODUCT_ROADMAP.md](PRODUCT_ROADMAP.md) todavía nombra (TTL 24 h) no está en HEAD: no se restaura.

Allowlist, `schema_version: 1`, tamaño del JSON `<= 2048` bytes:

- `schema_version` (entero)
- `prompt_fingerprint` (64 hex)
- `model_id` (string, máximo 80)
- `canonical_component` (máximo 80)
- `manufacturer` (máximo 80, o `UNKNOWN`)
- `model` (máximo 80, o `UNKNOWN`)
- `subsystem` (el enum del prompt, o `UNKNOWN`)
- `condition` (`GOOD`, `DEGRADED`, `DAMAGED`, `UNKNOWN`)
- `visible_text` (máximo 8 strings, cada uno máximo 80)
- `target_visible` (`true`, `false`, o `null`)
- `relevance_to_goal` (`relevant`, `unrelated`, `uncertain`, o `null`)

Fuera de la allowlist, y por lo tanto no se persisten: `summary`, `aliases`, `documented_functions`, `documented_connections`, `documented_values`, `documented_warnings`, `anti_hallucination_notes`, y la prosa de `build_analysis`.

El episodio no copia ese JSON. Sigue con `active_photo.field_photo_id` y `sha256`.

F0 lee el schema, el job de retención y el párrafo del roadmap. Si la columna en la misma fila no contradice la retención, finding `CONFIRMED` y F5 sigue. Si hiciera falta una tabla que sobreviva al purge, F5 queda `BLOCKED` y hay `STOP` de arquitectura. F0 no migra.

F0 confirmó que `FieldPhotoRetentionJob` ejecuta `photo.destroy!` (default 90 días, `FIELD_PHOTO_RETENTION_DAYS`) y que una fila citada por `InspectionFinding` no se purga. No existe la columna `visual_observation`. Una columna jsonb en la misma fila muere con la fila. F5 no queda `BLOCKED`. `Rag::ActiveEpisode.sanitize_photo` conserva `field_photo_id`, `sha256` y `correlation_id`, y descarta el resto. F5 no copia el JSON de `visual_observation` al episodio y no borra `correlation_id`. `ConversationSession#apply_photo_observation!` ya puede escribir facts `manufacturer` y `model`; F5 no los convierte en ese JSON. El cache de diagnóstico de 24 h sigue ausente en HEAD.

## 8. Continuidad — precedencia que F5 implementa

F0 no asume que `ActiveEpisodeTurn::DEICTIC_RE` cubre los ejemplos. Ese regex es:

```
/\b(esa|ese|eso|esta|este|esto|that|this)\s+(placa|foto|imagen|plate|photo)\b/
```

F0 lo corre, después de `normalize_label`, contra las frases de abajo y guarda el booleano. Los cuatro positivos tienen que salir `false` en HEAD. Si alguno sale `true`, finding `NEW` y el prompt de F5 lo dice; la precedencia de F5 no se afloja. F0 los corrió: los cuatro salieron `false`. No hay finding `NEW` de este regex. La precedencia de F5 no se afloja.

Positivos de referencia visual (F5 reutiliza la observación, cero Anthropic):

- `estos resortes`
- `según la foto`
- `la imagen que te mandé`
- `lo que se ve ahí`

Negativos (F5 no dispara reuso visual):

- `según el manual`
- `el borne 24`
- `fotocélula del embarque`
- `mandame el procedimiento`

Precedencia, la primera que aplica gana:

1. Hay bytes nuevos adjuntos → análisis nuevo.
2. Hay `field_photo_id` y la frase, ya normalizada, cumple `VISUAL_REREAD_RE` → análisis nuevo. La frase de producto es “volvé a mirar” o “revisa otra vez la foto”. El regex, sobre texto ya pasado por `normalize_label`:

```
/\b(?:volve|volver|vuelve|revisa|revisar|mira|mirar|analiza|analizar)\b.{0,40}\b(?:otra vez|de nuevo|nuevamente)\b|\b(?:otra vez|de nuevo)\b.{0,40}\b(?:foto|imagen)\b/
```

3. Hay `field_photo_id` y la pregunta no cumple el regex de releer → se reutiliza `visual_observation`. Cero Anthropic.
4. Texto solo, y la frase cumple `VISUAL_REFERENCE_RE` → se usa únicamente `active_photo` de la sesión. Regex sobre texto normalizado:

```
/\b(?:estos|estas|esos|esas)\s+(?:resortes|cables|bornes|terminales|contactos)\b|\bsegun la foto\b|\bla imagen que te mande\b|\blo que se ve ahi\b|\b(?:la|esa|esta)\s+(?:foto|imagen)\b/
```

5. Referencia visual y no hay `FieldPhoto` de esa cuenta para el `active_photo` → respuesta determinística, cero Anthropic: `No tengo una foto vigente en este caso. Seleccioná la foto anterior o volvé a enviarla.`

La observación inyectada en el paso 3 o 4 es el JSON allowlisted. El retrieve no lo reescribe. Si el manual dice otra cosa, eso lo separa F6.

## 9. Benchmark visual

### Manifest

Path: `tmp/field_companion/visual_manifest.json`. `tmp/` no se commitea. F0 copia bytes sin recomprimir y escribe el manifest. El SHA256 entra al Execution State.

### Fixture real `spring_assembly_misread`

La ruta que se inspeccionó no era una carpeta. El archivo es uno solo y no se modificó:

- path: `/Users/lahirisan/Desktop/resortes.png`
- filename: `resortes.png`
- media type: `image/png`
- width: 956
- height: 866
- bytes: 1430913
- SHA256: `202fbc9bee1f079914dfcb7dc5334ff1e9a776cb44b1c867c12a11ea04156ebd`

F0 copia esos bytes, sin editar y sin recomprimir, a `tmp/field_companion/images/spring_assembly_misread.png`. Si el SHA256 no coincide, F0 = `BLOCKED` y F1 no llama modelos. El resto de la auditoría igual se escribe. `categories: [cable_fixing, springs]`. El filename que ven los dos modelos es `spring_assembly_misread.png`.

### Probe fixture, que no es el benchmark

`docs/field_companion/multimodal_availability_probe.jpg`

- width: 4
- height: 3
- bytes: 803
- media type: `image/jpeg`
- SHA256: `5610cba05ad3f23d2bc8fcdc4c473df0316e2d47982711d7ce6a3f880baeea3c`

Sirve solo para el probe de invocabilidad de F0. No entra al manifest. No se usa como `spring_assembly_misread`. No se evalúa calidad.

### Catálogo de categorías

`console`, `control_board`, `nameplate`, `terminal_strip`, `doors`, `hoistway_component`, `degraded_photo`, `screen_photo`, `partial_label`, `unidentifiable`. F0 las agrega al manifest solo si hay un archivo real y la fila es elegible. No inventa fotos. Una categoría ausente no bloquea F1. No hay estado `pending`.

### Gold

Estados de campo. No existe `pending`.

- `VERIFIED`. Hay ground truth objetivo. El campo trae uno o más valores permitidos exactos. Normalización: minúsculas, sin acentos, espacios colapsados. PASS si el texto normalizado contiene al menos un valor permitido como palabra y no contiene ningún `fail_if`. FAIL si aparece un `fail_if`, o si no aparece ningún valor permitido.
- `MUST_BE_UNKNOWN`. La evidencia no permite identificar ese campo. PASS si el valor normalizado es vacío o `unknown`. Cualquier otro valor es FAIL.
- `NOT_SCORED`. No hay ground truth confiable. El campo no entra en PASS/FAIL.

Una fila es elegible si tiene al menos un campo `VERIFIED` o `MUST_BE_UNKNOWN` y ningún campo se contradice. No hace falta puntuar fabricante, modelo, componente y texto a la vez. Una fila solo con `NOT_SCORED` no entra a F1 y no bloquea F1.

Gold de `spring_assembly_misread`. F0 no lo reinterpreta. Hay una placa visible. Sus caracteres no se transcriben aquí, así que no son `VERIFIED`. Marcar fabricante o modelo como `MUST_BE_UNKNOWN` haría fallar una lectura fiel de esa placa. Esos campos quedan `NOT_SCORED`. El caso puntúa la confusión observada: conjunto de fijación y resortes, no banco de resistencias.

- `manufacturer`: `NOT_SCORED`
- `model`: `NOT_SCORED`
- `component`: `VERIFIED`, `allowed: [resorte, resortes, muelle, muelles]`, `fail_if: [resistenc, bobinad]`
- `visible_text`: `NOT_SCORED`

No hay `gold_overrides.yml`. F0 no pide una transcripción. `NOT_SCORED` no se entrevista.

### Qué corre F1

El harness es independiente del routing productivo. FC-D18. No lee `BatchChunkingPrompt::MODEL_TEXT`. No usa `FieldPhotoDensityGate`. No cambia constants. Fuerza, en código del harness, `claude-sonnet-5-5` y `claude-opus-5-5`. La credencial es `ANTHROPIC_API_KEY` o, si falta, `Rails.application.credentials.dig(:anthropic, :api_key)`, el mismo orden que `ClaudeChunkingClient#build_client`. No se pega una clave en el script.

Para cada fila elegible, una llamada por modelo. Idénticas entre sí salvo el model id:

- bytes exactos del archivo hasheado
- MIME de la fila
- filename de la fila
- locale `es`
- photo intent vacío
- system prompt = `FieldPhotoPrompt::SYSTEM_BLOCKS`
- `max_tokens` = 8000

El harness guarda `requested_model_id`, `returned_model_id` y el SHA256 de los bytes. Aborta la fila si los dos SHA256 difieren. El techo sigue en 16 imágenes por 2 modelos. Con solo la fila de resortes son 2 llamadas, no 32.

El evaluador escribe PASS/FAIL solo en campos `VERIFIED` y `MUST_BE_UNKNOWN`. `NOT_SCORED` se omite. Por modelo: `identity_invention_count` (FAIL de `MUST_BE_UNKNOWN`), `component_fail_count` (FAIL de `component` `VERIFIED`), tokens, latencia y costo. El costo de Sonnet 5.5 es `UNKNOWN` salvo `price_source` con URL. El de Opus 5.5 usa `claude-opus-5-5-direct` solo si el id devuelto empieza por `claude-opus-5-5`. Si el id devuelto es otro, el costo es `UNKNOWN`.

Hipótesis que F1 puede cerrar: si Sonnet 5.5 falla el `component` de `spring_assembly_misread` y Opus 5.5 lo pasa, con los mismos bytes y el mismo prompt, eso apoya una diferencia de capacidad del modelo. Sonnet 5 no se mide.

### Resultado F1

`F1_STATUS=PASS`. Dos llamadas, sin reintento, el 2026-09-29. `request_sha256` de las dos: `3e5e1921756170d6421120227e40060fcc9eb7b9c789b2b4c3c041f1955a6085`. Bytes `202fbc9bee1f079914dfcb7dc5334ff1e9a776cb44b1c867c12a11ea04156ebd`. Fingerprint `4f62491874c8fea82d78632657e9adc93da80c69e40157eee98b5cfe972715d1`. Locale `es`. Photo intent vacío. `max_tokens` 8000.

| Modelo | `returned_model_id` | `component` | Texto normalizado | Input | Output | Cache creation | Latencia | Costo |
|---|---|---|---|---|---|---|---|---|
| `claude-sonnet-5-5` | `claude-sonnet-5-5` | FAIL | `panel de aisladores con cables colgantes` | 1158 | 423 | 1745 | 4302 ms | `0.006546` |
| `claude-opus-5-5` | `claude-opus-5-5` | PASS | `amarre de cables con resortes` | 1158 | 901 | 1745 | 10754 ms | `0.022652` |

El FAIL de Sonnet 5.5 es ausencia de palabra permitida. `fail_if` (`resistenc`, `bobinad`) no aparece en ninguna de las dos salidas. Ninguna salida llama al conjunto banco de resistencias. Fabricante y modelo volvieron `UNKNOWN` en los dos modelos y no entran en PASS/FAIL. `visible_text` no se puntúa. Contadores: `spring_split` = `opus_pass_sonnet_fail`, `opus_only_wins` = 1, `shared_component_fail` = 0, `shared_identity_fail` = 0. `identity_invention_count` = 0 en los dos. `component_fail_count` = 1 en Sonnet 5.5 y 0 en Opus 5.5. F1 no elige letra. El costo de Sonnet 5.5 usa la URL citada. El de Opus usa `claude-opus-5-5-direct` porque el id devuelto empieza por `claude-opus-5-5`. Las dos cifras son input y output solamente: `(input_tokens / 1000) * tarifa_input + (output_tokens / 1000) * tarifa_output`.

## 10. Decisión F2

F2 lee la extensión de 15 imágenes, `tmp/field_companion/f1_extended/aggregate.json`, no solo `f1_visual.json`. Una sola letra. No abre dos experimentos. No instala un router por tipo de imagen. F2 está `PASS`. El Resultado F2 registra la letra y la corrección de alcance.

F0 y F1 no escriben `MODEL_TEXT`. Si Sonnet 5.5 gana o queda en la letra A, F2 puede dejarlo como default. Si Opus 5.5 gana casos puntuales, F2 registra el finding y no instala un routing heurístico. No vuelve la regla `bytes > 1_500_000 => Opus` sin evidencia causal de este benchmark. FC-D18.

Sobre las filas elegibles, solo en campos `VERIFIED` y `MUST_BE_UNKNOWN`:

- `spring_split`: uno PASS y el otro FAIL en el `component` del case de resortes.
- `opus_only_wins`: cantidad de filas elegibles donde Opus pasa todos los campos scored y Sonnet 5.5 falla al menos uno. `NOT_SCORED` no cuenta.
- `shared_component_fail`: ambos fallan el `component`.
- `shared_identity_fail`: ambos fallan un campo `MUST_BE_UNKNOWN`, y el `component` de esa fila no es un `shared_component_fail`. Si la fila no tiene campos `MUST_BE_UNKNOWN`, este contador no suma.

Contadores históricos de la fila única, en `tmp/field_companion/f1_visual.json` SHA256 `9244f1b5dca642ba72e45a938492a4036f548c9600047aafb0d7631a871868c4`. F1 no elige letra. No son el input de la decisión: la extensión los reemplaza como evidencia. El Anexo C trae los contadores de las 15 imágenes.

- `spring_split`: `opus_pass_sonnet_fail`
- `opus_only_wins`: 1
- `shared_component_fail`: 0
- `shared_identity_fail`: 0
- `claude-sonnet-5-5`: `identity_invention_count` 0, `component_fail_count` 1
- `claude-opus-5-5`: `identity_invention_count` 0, `component_fail_count` 0

Letra:

- **A.** `opus_only_wins == 0` y Sonnet 5.5 no tiene `identity_invention` en campos `MUST_BE_UNKNOWN`, y no hay `spring_split` a favor de Opus. F2 reemplaza `BatchChunkingPrompt::MODEL_TEXT` por `claude-sonnet-5-5`. El umbral de 1,5 MB y `MODEL_MULTIMODAL` no se tocan. No se agrega un routing por tamaño. Hay tarifa citada: <https://platform.claude.com/docs/en/about-claude/pricing>, fila Claude Sonnet 5.5. Input 0,002, output 0,01, cache read 0,0002 y cache write de 5 minutos 0,0025 dólares por 1.000 tokens. La write de 1 hora no se usa. Si la letra escribe `MODEL_TEXT`, F2 agrega la clave exacta `claude-sonnet-5-5-direct` con esos cuatro números. No copia la entrada `claude-sonnet-5-direct`. No usa `default`. Un test afirma los cuatro números y que `pricing_for("claude-sonnet-5-5-direct")` no es `BEDROCK_PRICING["default"]`.
- **B.** `spring_split` a favor de Opus, u `opus_only_wins >= 2`, y en esas filas Opus no inventa identidad. F2 hace el mismo cambio de `MODEL_TEXT` que A. No implementa routing selectivo a Opus. Deja el finding `selective_opus_routing: proposed_not_implemented`.
- **C.** Ambos fallan el `component` de resortes (`shared_component_fail` incluye ese case) y no aplica A ni B. El experimento siguiente, dentro de F2, es resolución: mismos prompt y mismo `claude-sonnet-5-5`, bytes de control contra un derivado de lado largo 2048 producido por `ImageCompressionService` con `MAX_DIMENSION` local al script (no se edita la constante de producción). Una variable.
- **D.** No aplica A, B ni C, y `shared_identity_fail` es mayor que `shared_component_fail`. El experimento es un prompt observation-first, mismos bytes de F1, solo Sonnet 5.5. El prompt de producción `FieldPhotoPrompt` no se publica a producción en la misma fase: el script usa una copia. Si el experimento gana el case de resortes y no sube `identity_invention`, F2 igual no pega ese prompt en `FieldPhotoPrompt` sin un test que fije el fingerprint nuevo. Si el experimento no gana, el prompt de producción queda igual y la letra registrada es D con `adopted: false`.
- **E.** Ninguna letra anterior. `SKIP`. Cero cambio de modelo, de prompt y de resolución.

A y B son el cambio de default. C y D son el experimento, no un segundo cambio encima. E no cambia nada.

### Resultado F2

`F2_STATUS=PASS`. Letra B. `adopted: true` para el default de Field Photo. Cero llamadas de imagen. `head_initial` `7f32d4837842e1e7e78ef652778a54860511b5f4`. El árbol no contiene el SHA de este commit.

Evidencia leída, sin regenerar el benchmark. Clase `E3`.

| Modelo | Overall | Component | Safety | p50 | Costo |
|---|---|---|---|---|---|
| `claude-sonnet-5-5` | 46/50 | 11/15 | 0 | 4335 ms | `0.136262` |
| `claude-opus-5-5` | 48/50 | 14/15 | 0 | 9117 ms | `0.351039` |

`spring_split` = `opus_pass_sonnet_fail`. `opus_only_wins` 4. `shared_component_fail` 0. `shared_identity_fail` 0. `identity_invention_count` 0 en los dos. Opus 5.5 identifica mejor el componente. Sonnet 5.5 es más rápido y más barato. No hay señal pre-call validada. Sonnet 5.5 queda como default de Field Photo. Opus 5.5 queda como la capacidad superior conocida, en la rama que ya existía. `selective_opus_routing: proposed_not_implemented`.

Corrección de alcance. El Anexo C ordenaba reemplazar `BatchChunkingPrompt::MODEL_TEXT`. Ese constant también alimenta la ingesta Batch bulk, la ingesta Batch web y el fallback Direct/retry. F2 no migra la ingesta. El default de chat es `FieldPhotoAnalysisService::DEFAULT_MODEL` = `claude-sonnet-5-5`. `MODEL_TEXT` sigue en `claude-sonnet-5`.

| Path | Modelo efectivo |
|---|---|
| Field Photo default | `claude-sonnet-5-5` |
| Field Photo, binario `>= 1_500_000` | `claude-opus-5-5` |
| Ingesta Batch de texto | `claude-sonnet-5` |
| Ingesta Batch multimodal o `force_opus` | `claude-opus-5-5` |
| Direct/retry de ingesta, sin modelo en la página | `claude-sonnet-5` |

`LARGE_PHOTO_THRESHOLD` permanece en `1_500_000`. Es una heurística legacy. La extensión de 15 imágenes no validó el tamaño en bytes como predictor de dificultad. F2 no agregó otro umbral ni otro router. `:sonnet` es un símbolo. El chat lo resuelve con `DEFAULT_MODEL`. La ingesta lo resuelve con `MODEL_TEXT`. El log `field_photo_gate` sigue nombrando `MODEL_TEXT` en la rama chica, porque la ingesta bulk emite el mismo evento. El id real del chat queda en el resultado del servicio.

Pricing de Field Photo, Anthropic Direct. Clave exacta `claude-sonnet-5-5-direct`, dólares por 1.000 tokens: input `0.002`, output `0.01`, cache read `0.0002`, cache creation `0.0025`. Fuente: fila Claude Sonnet 5.5 de <https://platform.claude.com/docs/en/about-claude/pricing>, leída el 2026-09-29. $2 / $10 / $0,20 por MTok. Cache write de 5 minutos $2,50 / MTok. No es un alias de `claude-sonnet-5-direct`. No cae en `default`. `claude-sonnet-5-5-batch` no se escribe en F2. F2B la cita antes de cualquier llamada Batch con ese id.

No cambió `FieldPhotoPrompt`, el fingerprint `4f62491874c8fea82d78632657e9adc93da80c69e40157eee98b5cfe972715d1`, el resize, `max_tokens`, el prompt de ingesta, `INGESTION_CONTRACT_VERSION`, RAG, embeddings, discovery, provenance, conocimiento compartido, top-k ni pins. `ContractualLimits::PHOTO[:allowed_models]` lista `DEFAULT_MODEL` y `MODEL_MULTIMODAL`. Es el techo declarativo de la foto.

Los hashes del benchmark visual se reconfirmaron y no se reescribieron. Siguiente fase después de F2: F2B, ya cerrada. F3 no arranca hasta el Anexo E.

### Resultado F2B

`F2B_STATUS=PASS`. Gate `I1`. `adopted: true` para la ingesta de texto. El contrato completo está en Execution State. Desde este cierre, la tabla de F2 queda histórica y el modelo efectivo es:

- Ingesta Batch de texto, bulk y web: `claude-sonnet-5-5` vía `MODEL_TEXT`.
- Direct/retry de ingesta sin modelo en la página: `claude-sonnet-5-5` vía `MODEL_TEXT`.
- Field Photo default: `claude-sonnet-5-5` vía `DEFAULT_MODEL`. No lee `MODEL_TEXT`.
- Field Photo de 1,5 MB y `MODEL_MULTIMODAL`: `claude-opus-5-5`.

`claude-sonnet-5-5-batch` está en `BEDROCK_PRICING` con input `0.001`, output `0.005`, cache read `0.0001`, cache creation `0.00125`. No es `default` y no es el mismo objeto que `claude-sonnet-5-batch`. `claude-sonnet-5-5-direct` no se reescribió. `INGESTION_CONTRACT_VERSION` sigue `field_records_v8`. El fingerprint de ingesta sigue `e5b574784ff78547886919fe388edd51decbc13b0a37cfbd11bc041ff4ac1172`.

## 11. Discovery en runtime (F3 y F4)

F3 mueve la función de la sección 5 a `app/services/rag/manual_candidate_ranker.rb` sin alterar puntos, desempate ni textos. Un test carga `tmp/field_companion/f0_discovery.json` y exige la misma lista ordenada de `document_id` por frase, antes del filtro de scope. Otro test carga `f0_discovery_eligible.json` y exige la lista después del filtro. Si falta alguno de los dos archivos, o si F0 no dejó la ruta de `danebo_general` confirmada, F3 igual puede sugerir solo los `tenant_private` de la cuenta. No sugiere `UNCLASSIFIED` ni `PRIVATE` ajenos. Si el archivo de score no está, F3 = `BLOCKED`.

F3 no escribe `active_entities`. No llama a Bedrock para rankear. Muestra como máximo 3 tarjetas. Cada tarjeta lleva la etiqueta `BRAND_ONLY` o `EXACT_DESIGNATOR`, el texto fijo de la sección 5, y la procedencia documental: `Biblioteca general de Danebo` o `Tu biblioteca`. `tie_at_top` no elige una. El síntoma no dispara retrieve. El scope no cambia el score.

Tests de elegibilidad, con fixtures, sin red:

- Un `PRIVATE` de otra cuenta no entra.
- Un `UNCLASSIFIED` de Legacy o Pilot no entra para otro tenant.
- Un `GENERAL_APPROVED` entra, con el mismo orden que le habría dado el score, y con el texto de biblioteca general.
- Adjuntar scope no cambia los puntos de la sección 5.

### Resultado F3

`F3_STATUS=PASS`. `Rag::ManualCandidateRanker` copia el score de la sección 5. El filtro de scope corre después del top 3 y no rellena. `tie_at_top` muestra hasta 3 tarjetas y `selected_document_uid` queda nil. La sugerencia no escribe `active_entities`. El síntoma sin fabricante no arma tarjetas y no llama a retrieve. La telemetría nueva es `manual_suggestion_shown` con `suggestion_document_uids` y `suggestion_scopes`. No se aprobó ningún documento. Los hashes de `f0_discovery.json` y `f0_discovery_eligible.json` no se reescribieron.

F4: el técnico toca una tarjeta. Esto corre solo si F0 confirmó una ruta con `reindex_required = false` y `duplicate_document_required = false`. Si no, F4 = `BLOCKED` y no hay código de pin nuevo. F0 confirmó `existing_document_id_session_pin`. F4 no queda `BLOCKED`. El registro de aprobación sigue sin crear y vive fuera del chunk. F3, cuando corra, reescribe el prompt de F4 con los hashes reales.

- Documento `tenant_private` de la cuenta del técnico: `pin_kb_document!`, `source: "user_pin"`. Evento `manual_focus_confirmed`.
- Documento `danebo_general`: el mismo `user_pin` sobre la fila existente, escrito solo en la sesión actual. No se crea otro `KbDocument`, no se copia S3, no se reindexa, no hay `assisted_focus`, y no hay un flag de pin en el documento.
- `PRIVATE` o `UNCLASSIFIED` de otra cuenta: no hay tap. El ranker no debió mostrarlos.
- `tie_at_top`: una pregunta, máximo 3 chips, cero pins hasta el tap.
- `pin_conflict`: se muestra y el pin anterior sigue.
- `identity_conflict`: se muestran las dos identidades y no se sobreescribe el hecho del técnico.

Prohibido en F4: `unscoped`, `find_by` de un privado ajeno, desactivar autorización, copiar la fila, duplicar el objeto S3, reindexar por tenant, y guardar el pin como estado del `KbDocument` o de cualquier estructura visible para otras cuentas.

Tests de foco, sin red:

- La cuenta A pinea un `danebo_general`. `active_entities` de la cuenta B no cambia. El documento sigue elegible para B.
- La cuenta B pinea otro general, o dos generales, o un general y un privado suyo. Los pins de A siguen iguales.
- A quita su pin. El documento sigue en el catálogo general y en los pins de B.

### Resultado F4

`F4_STATUS=PASS`. `F5` queda `READY` y no se ejecutó. El técnico elige el manual. Ningún score escribe un pin.

El tap es `POST /pinned_documents` con `kb_document_id`, `document_uid` y, si ya existe, `correlation_id`. El servidor carga `KbDocument.find_by(id:)`. No hay `find_by(document_uid:)`. El uid solo confirma esa fila. Después corre `Rag::KnowledgeScopePolicy.authorized?`. Recién entonces `ConversationSession#pin_kb_document!` con `source: "user_pin"`. El browser no decide `knowledge_scope`, `tenant_private`, `danebo_general` ni `authorized`.

Una fila ausente, revocada o privada de otra cuenta responde `Este manual ya no está disponible.` y no crea la sesión. Un uid que no es el de esa fila responde `No pude seleccionar este manual.` Un pin anterior queda. Un segundo tap de la misma fila responde `Este manual ya está enfocado.` y no repite `manual_focus_confirmed`.

El Anexo F pide reautorizar en el tap, no un token de sugerencia. La biblioteca ya podía pinear una fila autorizada por id, sin `document_uid`, y sigue devolviendo 204 sin ese evento. La tarjeta exige el uid. `manual_focus_confirmed` sale solo cuando el uid coincidió y el pin es nuevo. El scope del evento lo escribe `KnowledgeScopePolicy.scope_for`.

La sesión web es una fila por `account_id`, `identifier` igual al id del usuario, y `channel=web`. El pin vive en `active_entities` de esa fila. Otra sesión de la misma cuenta no lo hereda. Otra cuenta tampoco. Sumar un pin no borra los demás. Quitar foco es `unpin_kb_document_id!`: no exige que la fila siga existiendo ni que siga autorizada, y no concede lectura.

Con un foco válido, la pregunta siguiente manda `force_entity_filter` y solo las URIs canónicas de ese conjunto. No hay caída silenciosa al corpus abierto. X+Y manda las dos. Un miembro inválido sigue en `DENY_RETRIEVAL`: cero generate, cero retrieve, los pins quedan.

La tarjeta muestra `Usar este manual`. Después del tap, ese botón pasa a `Quitar foco`. `data-selected` sigue `none`. `focused: true` en una tarjeta posterior solo refleja un pin ya escrito. `tie_at_top` no elige. La procedencia sigue siendo `Tu biblioteca` o `Biblioteca general de Danebo`.

`pin_conflict` se muestra y el pin queda. `equipment_switch_prompted` usa `manufacturer` y `outcome_reason=pin_conflict`. No hizo falta `previous_manufacturer`. `identity_conflict` lee el conflicto que `apply_photo_observation!` ya guardó en el episodio y no pisa el hecho del técnico.

Un `danebo_general` de la cuenta A se pinea en la sesión de B sobre la misma fila. No hay `KbDocument` nuevo, no hay copia S3, no hay `BedrockIngestionJob`. `DocumentOverviewWarmJob` se encola igual que en el pin de biblioteca. Busca la fila en `kb_documents` del viewer, así que no copia el general ajeno.

No se tocó el retrieve abierto, el score, el top 3, el no-refill ni el writer de `knowledge_scope`. No hubo deploy.

## 12. Procedencia de la respuesta

Tres bandas, no cinco. Esto no es la procedencia documental de FC-D14.

- `MANUAL_FACT`
- `VISUAL_OBSERVATION`
- `DANEBO_GUIDANCE`

Invariante de seguridad: una frase clasificada `DANEBO_GUIDANCE` no puede ir marcada como `MANUAL_FACT` ni llevar el prefijo `Según el manual`.

`SHOW_RAG_SOURCES` solo es verdadero cuando el ENV es `"true"` (`Rag::SourcesVisibility`). Con falso, `RagController#ask` y `PhotoQuestionAnswerService` pasan la respuesta por `CitationProcessor#strip_resolved_markers` y el cliente puede recibir `citations: []`. F7 no puede depender de que `[n]` llegue al browser.

F6, solo servidor y prompt. Antes del strip, arma:

```
provenance_segments: [ { "band": "MANUAL_FACT" | "VISUAL_OBSERVATION" | "DANEBO_GUIDANCE", "text": "..." } ]
```

Regla mecánica: frase con un `[n]` que existe en las citas del servidor → `MANUAL_FACT`. Frase tomada del JSON de observación (componente, fabricante, modelo, `visible_text`) → `VISUAL_OBSERVATION`. El resto → `DANEBO_GUIDANCE`. Prefijos de prompt, una sola vez cada uno en `generation.txt`: `Según el manual:`, `En la foto:`, `Para revisar:`. F6 no edita `answer_presenter.js`.

F7 solo lee `provenance_segments`. Si la clave falta, el renderer de hoy se queda, footer incluido. F7 no edita `generation.txt`. Tests con el flag en `true` y en `false`.

## 13. Telemetría

`PilotUsageLog::ALLOWED_FIELDS` hace `slice` antes de loguear y antes de `PilotEventRecorder`. Una clave nueva no se persiste. El nombre del evento sí es libre.

F3 agrega a la allowlist, y solo esto: `suggestion_document_uids` y `suggestion_scopes`. El segundo es un array de `tenant_private` o `danebo_general`, en el mismo orden que los uids. El test de campos desconocidos se extiende: una clave fuera de la lista no aparece en la línea `[PILOT_USAGE]`. Evento `manual_suggestion_shown`. También `manual_suggestion_dismissed` en F4, reusando claves ya permitidas (`document_id`, `outcome`).

F3B2 agrega a la allowlist, y solo esto: `rejected_result_count`, `authorized_general_count` y `retrieval_denied_reason`. El evento es `open_retrieval`. Los mismos tres campos viajan en `kb_retrieve`. `knowledge_scope` sigue fuera de la allowlist.

F4: `manual_focus_confirmed` con `document_id`, `source_uri`, `correlation_id` y `knowledge_scope` (`tenant_private` o `danebo_general`). `knowledge_scope` se agrega a la allowlist en F4, con el mismo test de clave ajena. `equipment_switch_prompted` con `manufacturer` y `outcome_reason`. Si hace falta un segundo fabricante, F4 agrega `previous_manufacturer` a la allowlist y lo testa. No se agregan claves “por si acaso”. F4 no saca las tres claves de F3B2.

Resultado F4: `knowledge_scope` está en la allowlist. El valor lo escribe el servidor. No se agregó `previous_manufacturer`. `manual_focus_denied` reusa `outcome_reason` (`unavailable` o `invalid`). `manual_suggestion_dismissed` reusa `document_id` y `outcome` (`unpinned`).

F5: `photo_observation_reused` y `photo_observation_reread`. Les alcanza `cache_status` (`reused` o `reread`), `image_digest_prefix`, `correlation_id`. Cero claves nuevas. Cero broadcast nuevo.

## 14. Voz, producto y roadmap

Danebo no es solo un chat sobre los manuales del cliente. Es un Field Companion con una base técnica general curada por Danebo y la documentación privada de cada cliente. La base general acorta el arranque de un cliente nuevo. La biblioteca privada sigue siendo específica de ese cliente. Esa frase está en [docs/PRODUCT_ROADMAP.md](PRODUCT_ROADMAP.md). Este plan no la implementa en F0.

El roadmap también dice que la voz es la interfaz de campo y que el cache de diagnóstico de 24 h existe. HEAD no tiene ese cache. Este plan no lo revive y no construye la voz. Las tres bandas de la respuesta se distinguen por la frase inicial, que es lo que una lectura en voz alta puede decir. El contrato de transcripción visible antes de enviar sigue igual. No hay `speechSynthesis` que implementar.

`visual_observation` no es el diagnostic record de la etapa siguiente del roadmap. Muere con la fila `field_photos`.

## 15. Qué no construir

Auto-focus. Umbral que lo dispare. Filtro Bedrock por fabricante. Subir top-k. Reabrir los cuatro `BLOCKED` del plan de wording. Ensemble de visión. Medir `claude-sonnet-5` dentro de F1. Elegir los modelos del benchmark con `BatchChunkingPrompt::MODEL_TEXT` o con `FieldPhotoDensityGate`. Volver a `bytes > 1_500_000 => Opus` sin evidencia de este benchmark. Tratar la ausencia de `claude-sonnet-5-5` en constants como blocker de F0. Usar el JPEG 4×3 como caso visual. TTS o STT de mantenimiento. Galería. Tabla de historial de diagnóstico. Ingesta de la foto a `bulk_chunks/`. `SemanticQueryAnalyzer` para elegir el manual. Restaurar el cache de diagnóstico. Mover la visión a Bedrock. Aprobar `danebo_general` por slug, por filename o por el autor de la ingesta. Copiar un `KbDocument` o su objeto S3 para poder pinearlo. Reindexar por tenant. `unscoped` o un `find` de privados ajenos. Un pin global sobre `danebo_general`, o un pin que saque ese documento del catálogo de otra cuenta. Relajar, quitar o ignorar pins en silencio cuando no hay evidencia. Quitar el aviso fijo de verificación. Routing selectivo a Opus dentro de este plan (B solo lo deja anotado).

## 16. Documentación canónica

Quedó alineada con FC-D09, FC-D16, FC-D17 y FC-D18 en este mismo cambio, sin tocar planes históricos:

- [docs/PRODUCT_ROADMAP.md](PRODUCT_ROADMAP.md)
- [docs/SESSION_AND_RETRIEVAL.md](SESSION_AND_RETRIEVAL.md)
- [docs/ACTIVE_ARCHITECTURE.md](ACTIVE_ARCHITECTURE.md)
- [docs/MULTI_TENANT_ARCHITECTURE.md](MULTI_TENANT_ARCHITECTURE.md)
- [docs/WEB_HOME.md](WEB_HOME.md)
- [docs/QUERY_ORCHESTRATOR.md](QUERY_ORCHESTRATOR.md)
- [docs/README.md](README.md)
- [README.md](../README.md)
- [AGENTS.md](../AGENTS.md)
- [app/services/rag/AGENTS.md](../app/services/rag/AGENTS.md)
- [docs/field_companion/multimodal_availability_probe.jpg](field_companion/multimodal_availability_probe.jpg) — solo el probe de F0. No es el benchmark.

Esos archivos describen el contrato (`tenant_private` + `danebo_general` explícito). F3B2 alineó el retrieve abierto con ese contrato. Legacy, Pilot y `manual_corpus=general` siguen pudiendo estar en metadata. No autorizan.

## Execution State

Una fase no queda `COMPLETED` hasta registrar los campos que le aplican. Las fases no ejecutadas no se rellenan. F0, F1, F2, F2B, F3, F3B1, F3B2 y F4 están `PASS`. F5 está `READY` y no se ejecutó.

Contrato de cada fase, cuando corra:

- `phase`
- `status`
- `head_initial`
- `head_final`
- `commit`
- `files_changed`
- `commands_executed`
- `command_results`
- `tests`
- `test_results`
- `artifacts`
- `artifact_sha256`
- `findings`, numerados, cada uno `CONFIRMED`, `REJECTED` o `NEW`
- `derived_decisions`
- `future_phases_changed`, con el `reason` de cada modificación
- `next_phase_prompt_path`

Checkpoint previo a F0, satisfecho al abrir:

- `status`: documentación commiteada. El working tree estaba limpio.
- `subject`: `Record Field Companion pre-F0 documentation gates.`
- `preparatory_head`: `9c4f57c7514b7b7ccfdff5c7d3ddbdeb6456d739`
- `git merge-base --is-ancestor 9c4f57c7514b7b7ccfdff5c7d3ddbdeb6456d739 HEAD` salió 0.
- `git diff 9c4f57c7514b7b7ccfdff5c7d3ddbdeb6456d739 -- app config db` salió vacío.

### F0

- `phase`: F0
- `status`: `PASS`
- `head_initial`: `8385329ac1adfa552dbcf9101fab48709bc148fe`
- `head_final`: el commit de F0. El árbol no puede contener su propio SHA. Después del commit, `git rev-parse HEAD` es `head_final` y `git rev-parse HEAD^` es `head_initial`.
- `commit`: el único commit cuyo padre es `head_initial` y cuyo asunto es `Freeze Field Companion contracts for visual benchmark and discovery.`
- `files_changed`:
  - `script/field_companion/discovery_score.rb`
  - `script/field_companion/f0_audit.rb`
  - `test/script/field_companion_discovery_score_test.rb`
  - `docs/PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29.md`
  - `docs/README.md`
- `commands_executed`:
  - checkpoint de ancestro y diff vacío de `app/`, `config/` y `db/`
  - SHA256 de `/Users/lahirisan/Desktop/resortes.png` y de `docs/field_companion/multimodal_availability_probe.jpg`
  - `env -u BUNDLE_PATH bin/rails runner script/field_companion/f0_audit.rb` (una llamada Anthropic; un re-run no repite un probe con `attempted: true`)
  - `env -u BUNDLE_PATH bin/rails test` con el regression gate más `test/script/field_companion_discovery_score_test.rb`
  - `env -u BUNDLE_PATH bin/rubocop --cache false` sobre los tres archivos Ruby de F0
- `command_results`:
  - ancestro verdadero; diff de `app/`, `config/` y `db/` vacío
  - `resortes.png` `202fbc9bee1f079914dfcb7dc5334ff1e9a776cb44b1c867c12a11ea04156ebd`, 1430913 bytes, 956×866
  - probe JPEG `5610cba05ad3f23d2bc8fcdc4c473df0316e2d47982711d7ce6a3f880baeea3c`, 803 bytes, 4×3
  - auditoría `F0_STATUS=PASS`, `probe_success=true`, `k_matrix_match=true`, `db_checked=true`, `general_approved_count=0`, `f4_route_confirmed=true`
  - tests: 210 runs, 1287 assertions, 0 failures, 0 errors, 1 skip
  - RuboCop: 3 files, no offenses
- `tests`: regression gate de este plan, más `test/script/field_companion_discovery_score_test.rb` en la misma invocación
- `test_results`: 210 runs, 1287 assertions, 0 failures, 0 errors, 1 skip. El skip es el test previo `Manual integration test: Upload a large JPEG (>500KB) via UI to verify compression` en `test/services/image_compression_service_test.rb`. No es de F0. El score: 10 runs dentro de ese total, 0 failures.
- `artifacts`:
  - `tmp/field_companion/f0_contract_audit.json`
  - `tmp/field_companion/f0_probe.json`
  - `tmp/field_companion/f0_general_inventory.json`
  - `tmp/field_companion/f0_authorization_matrix.json`
  - `tmp/field_companion/f0_discovery.json`
  - `tmp/field_companion/f0_discovery_eligible.json`
  - `tmp/field_companion/visual_manifest.json`
  - `tmp/field_companion/images/spring_assembly_misread.png`
- `artifact_sha256`:
  - `f0_contract_audit.json` `53df02c4a5ff192e7bc1d32e62c778e7f84fbe9a4fd58f829924dd750d896322`
  - `f0_probe.json` `4f70e4acc3543b1e6a88b575e930e141963e86268b172e8e92e3351dad37335d`
  - `f0_general_inventory.json` `3935839a8bf734118ebc13b813265ba2a6ac788efc931d2f2741949a4228a247`
  - `f0_authorization_matrix.json` `2c4a69f5df885833c5e686d3c4afd87ad14dcca3f3a9b4a0c3980e3fc127d904`
  - `f0_discovery.json` `0119f27bd05a86efe5371008bd1886f9791bf5d427eea1364682adad9b9e5ee0`
  - `f0_discovery_eligible.json` `47efb001265ee5985fd33cee156054acd81b9fad8736e111ac4291914cbeff36`
  - `visual_manifest.json` `7a17aad222d0be44bf961b7119226fef54632a3789aa11e4cd985b95431a05f1`
  - `spring_assembly_misread.png` `202fbc9bee1f079914dfcb7dc5334ff1e9a776cb44b1c867c12a11ea04156ebd`
- `findings`:
  1. `CONFIRMED`. El pipeline visual de HEAD coincide con la sección 1. `MODEL_TEXT` = `claude-sonnet-5`. `MODEL_MULTIMODAL` = `claude-opus-5-5`. Umbral `1_500_000`. Provider Anthropic Direct. `max_tokens` 8000. `white_ratio` no elige modelo. Fingerprint `FieldPhotoPrompt.prompt_fingerprint_sha256` = `4f62491874c8fea82d78632657e9adc93da80c69e40157eee98b5cfe972715d1`. `claude-sonnet-5-5` no está en esas constants. Eso no bloquea. FC-D18.
  2. `CONFIRMED`. Probe multimodal success. `requested_model_id` = `claude-sonnet-5-5`. `returned_model_id` = `claude-sonnet-5-5`. Timestamp `2026-09-29T21:20:16Z`. Cliente `Anthropic::Client`, `messages.create`, `max_tokens` 16, sin system prompt, imagen solo el JPEG de 803 bytes. No encoló `TrackBedrockQueryJob`. No se evaluó calidad.
  3. `CONFIRMED`. Las cuatro ramas de preprocesado de la sección 2 están en el código citado. No toda foto queda en 1024.
  4. `CONFIRMED`. `field_photos` no tiene `visual_observation`. El episodio, después de `sanitize_photo`, no guarda el JSON de visión. El historial trunca a `ConversationSession::MAX_MSG_LENGTH` = 300. Una columna jsonb en la misma fila muere con `photo.destroy!`. F5 no queda `BLOCKED`. No hay `STOP`.
  5. `NEW`. `sanitize_photo` también conserva `correlation_id`. `apply_photo_observation!` puede escribir facts `manufacturer` y `model`. F5 no copia `visual_observation` al episodio y no borra `correlation_id`.
  6. `CONFIRMED`. La matriz de k de la sección 3 coincide con `RagRetrievalProfile`. La tabla no se corrigió. El código del perfil no se tocó.
  7. `CONFIRMED`. `effectively_confirmed?` exige `confirmed`, `evidence_page` entero positivo y `evidence_text`. Un YAML `confirmed: true` sin `evidence_text` no es `catalog_confirmed` y no suma 40. En el catálogo vivo, 110 entradas con `confirmed: true` también están effectively confirmed. `document_id` del YAML es `document_uid`. El fabricante sale de `MANUFACTURERS`, comparado con `Entry#brands` ya normalizado.
  8. `CONFIRMED`. No existe fuente por documento para `GENERAL_APPROVED`. Conteos: `GENERAL_APPROVED` 0, `PRIVATE` 0, `UNCLASSIFIED` 17. CASE B no es esa aprobación. La opción elegida `existing_document_id_session_pin` tiene `reindex_required = false` y `duplicate_document_required = false`. `new_chunk_attribute` queda sin elegir, con `reindex_required = true`. F4 no queda `BLOCKED`.
  9. `NEW`. La DB local no tiene la cuenta `danebo-pilot-elevator`. El inventario son 17 filas de `danebo-legacy` (account id `4`). 25 filas de matriz: esas 17 más los `document_uid` del ranking del fixture que no están en la DB local. Esas filas tienen `physical_owner_account_id` null y `catalog_index_account_id` `"1"` o `"3"`. No se aprobó ningún documento.
  10. `CONFIRMED`. `DEICTIC_RE`, después de `normalize_label`, es false para `estos resortes`, `según la foto`, `la imagen que te mandé` y `lo que se ve ahí`. La precedencia de F5 no se afloja.
  11. `CONFIRMED`. `spring_assembly_misread` es elegible. SHA256, bytes, dimensiones y MIME coinciden con el congelado. `component` es `VERIFIED`. Fabricante, modelo y `visible_text` son `NOT_SCORED`. No hay `pending`.
  12. `CONFIRMED`. El viewer no owner es la cuenta `5` (`elevadores-climb`). `f0_discovery_eligible.json` no le entrega ningún documento del ranking. `f0_discovery.json` conserva el ranking técnico. Fixture y holdout: `precision_at_3` 1, `top1_accuracy` 1, `wrong_brand_candidate_rate` 0. El scope no entra en los puntos.
  13. `CONFIRMED`. El roadmap nombra el cache de diagnóstico de 24 h. HEAD no tiene esa clase bajo `app/`. F0 no lo restaura.
  14. `REJECTED`. Tratar `manual_corpus=general`, el slug Legacy/Pilot, el filename o `confirmed` del catálogo de identidad como `GENERAL_APPROVED`.
- `derived_decisions`:
  - F1 puede llamar modelos. El probe fue success y el manifest tiene un solo `case_id` elegible, así que son 2 llamadas, bajo el techo de 32.
  - F4 no está `BLOCKED`. El registro de aprobación no se crea en F0 y no va al chunk.
  - F5 no está `BLOCKED`. Conserva `correlation_id`. No copia el JSON de observación al episodio.
  - Ninguna constant productiva cambia.
- `future_phases_changed`:
  - F1. `reason`: el Anexo B reemplaza el placeholder con el probe success, el fingerprint, los hashes y el formato de `f1_visual.json`.
  - F2. `reason`: revisada, sin edición. Sigue leyendo `f1_visual.json` para elegir A, B, C, D o E.
  - F3. `reason`: revisada, sin edición. La lista elegible vacía para un no owner coincide con la sección 6. La paridad del score usa `f0_discovery.json`.
  - F4. `reason`: F0 confirmó `existing_document_id_session_pin`. El gate de la tabla y la sección 11 dejan de tratar F4 como `BLOCKED`. El prompt de F4 lo reescribe F3.
  - F5. `reason`: la retención de la misma fila quedó confirmada. F5 conserva `correlation_id` y no copia `visual_observation` al episodio.
  - F6. `reason`: revisada, sin edición.
  - F7. `reason`: revisada, sin edición.
  - F8. `reason`: revisada, sin edición.
- `next_phase_prompt_path`: `docs/PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29.md` (Anexo B)

### F1

- `phase`: F1
- `status`: `PASS`
- `head_initial`: `83b128ce430acc0a67909d924b5ccf9efd79c2a4`
- `head_final`: `efd138d5287727e24258293102e69c355dee3bf8`
- `extension_commit`: `7f32d4837842e1e7e78ef652778a54860511b5f4`. La extensión no es una fase. Su padre es `head_final`. F2 abre sobre la extensión.
- `commit`: el único commit cuyo padre es `head_initial` y cuyo asunto es `Record the Sonnet 5.5 versus Opus 5.5 field-photo benchmark.`
- `files_changed`:
  - `script/field_companion/visual_benchmark.rb`
  - `test/script/field_companion_visual_benchmark_test.rb`
  - `docs/PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29.md`
  - `docs/README.md`
- `commands_executed`:
  - `env -u BUNDLE_PATH bin/rubocop --cache false script/field_companion/visual_benchmark.rb test/script/field_companion_visual_benchmark_test.rb`
  - `env -u BUNDLE_PATH bin/rails runner script/field_companion/visual_benchmark.rb` (dos llamadas Anthropic, una por modelo, sin reintento)
  - `env -u BUNDLE_PATH bin/rails test` con el regression gate más `test/script/field_companion_visual_benchmark_test.rb` y `test/script/field_companion_discovery_score_test.rb`
  - `git diff HEAD -- app config db` vacío
- `command_results`:
  - RuboCop: 2 files, no offenses
  - benchmark `F1_STATUS=PASS`, `calls=2`, `spring_split=opus_pass_sonnet_fail`, `opus_only_wins=1`, `shared_component_fail=0`, `shared_identity_fail=0`
  - Sonnet 5.5: `component` FAIL, texto `panel de aisladores con cables colgantes`, `returned_model_id=claude-sonnet-5-5`, input 1158, output 423, cache read 0, cache creation 1745, latencia 4302 ms, costo `0.006546`, timestamp `2026-09-29T21:37:16Z`
  - Opus 5.5: `component` PASS, texto `amarre de cables con resortes`, `returned_model_id=claude-opus-5-5`, input 1158, output 901, cache read 0, cache creation 1745, latencia 10754 ms, costo `0.022652`, timestamp `2026-09-29T21:37:26Z`
  - `request_sha256` idéntico `3e5e1921756170d6421120227e40060fcc9eb7b9c789b2b4c3c041f1955a6085`
  - tests: 232 runs, 1382 assertions, 0 failures, 0 errors, 1 skip
  - diff de `app/`, `config/` y `db/` vacío
- `tests`: regression gate de este plan, más `test/script/field_companion_visual_benchmark_test.rb` y `test/script/field_companion_discovery_score_test.rb`, en la misma invocación
- `test_results`: 232 runs, 1382 assertions, 0 failures, 0 errors, 1 skip. El skip es el test previo `Manual integration test: Upload a large JPEG (>500KB) via UI to verify compression` en `test/services/image_compression_service_test.rb`. No es de F1.
- `artifacts`:
  - `tmp/field_companion/f1_visual.json`
  - `tmp/field_companion/outputs/spring_assembly_misread.claude-sonnet-5-5.txt`
  - `tmp/field_companion/outputs/spring_assembly_misread.claude-opus-5-5.txt`
- `artifact_sha256`:
  - `f1_visual.json` `9244f1b5dca642ba72e45a938492a4036f548c9600047aafb0d7631a871868c4`
  - `spring_assembly_misread.claude-sonnet-5-5.txt` `0806d1c5f6ad98c50b74a4bb409ef1d5aa57ebf161ff72700bd8482fa422066b`
  - `spring_assembly_misread.claude-opus-5-5.txt` `f53745565e39091c5f622315e18d3e98d54c44cc4a64931a84d1211bdd452e3a`
  - manifest de entrada, sin reescritura, `7a17aad222d0be44bf961b7119226fef54632a3789aa11e4cd985b95431a05f1`
  - PNG de entrada, sin recomprimir, `202fbc9bee1f079914dfcb7dc5334ff1e9a776cb44b1c867c12a11ea04156ebd`
  - extensión `tmp/field_companion/f1_extended/aggregate.json` `fe283538ceceaf8d90a3b9a4444868abf0886e1745584eb09cb67d35c6e3fa84`
  - extensión `tmp/field_companion/f1_extended/cost_report.json` `72e13f1c32b7f9172301a206970df2a13707b0770dd4d14cb500a44affbdcc5b`
  - extensión `tmp/field_companion/f1_extended/gold_manifest.json` `2329d9d8d4cedc4309a6f608e82a398ff6c5e0cd942e376e0b9b9a1098411fbc`
  - extensión `tmp/field_companion/f1_extended/manifest.json` `62a639b54e17ae211d61407bdbb716844ce0d4e8480986dcaac12cfe2df0e477`
  - extensión `tmp/field_companion/f1_extended/SHA256SUMS.txt` `c5987e91750648649ba743cf94f4a598d5920ba7f088e6b79ca6821aedf5a4b9`
- `findings`:
  1. `CONFIRMED`. Las dos llamadas recibieron los mismos bytes, el mismo MIME, el mismo filename, locale `es`, photo intent vacío, el mismo system prompt y `max_tokens` 8000. `request_sha256` coincide. `bytes_sha256` coincide con el PNG congelado. `returned_model_id` es el id pedido en los dos. No se llamó a `claude-sonnet-5`. El harness no lee `MODEL_TEXT` ni usa `FieldPhotoDensityGate`.
  2. `CONFIRMED`. La hipótesis de capacidad, con los mismos bytes y el mismo prompt: Sonnet 5.5 falla el `component` y Opus 5.5 lo pasa. `spring_split` = `opus_pass_sonnet_fail`. `opus_only_wins` = 1.
  3. `NEW`. El FAIL no es el camino `fail_if`. Ninguna salida contiene `resistenc` ni `bobinad`. Sonnet 5.5 nombró `Panel de aisladores con cables colgantes` y por eso no aparece una palabra permitida. Opus 5.5 nombró `Amarre de cables con resortes`.
  4. `CONFIRMED`. `identity_invention_count` = 0 en los dos. La fila no tiene campos `MUST_BE_UNKNOWN`. Fabricante y modelo volvieron `UNKNOWN` y quedan `NOT_SCORED`. `shared_identity_fail` = 0. `shared_component_fail` = 0.
  5. `NEW`. La página de precios de Anthropic lista Claude Sonnet 5.5 a $2 / MTok de input y $10 / MTok de output. El harness cita esa URL. `BEDROCK_PRICING` no ganó una clave. El costo guardado es input y output; los 1745 tokens de `cache_creation` de cada llamada están en el artefacto y fuera de la cifra.
  6. `CONFIRMED`. Ninguna constant productiva cambió. `MODEL_TEXT` sigue en `claude-sonnet-5`. El fingerprint del prompt sigue en `4f62491874c8fea82d78632657e9adc93da80c69e40157eee98b5cfe972715d1`.
  7. `REJECTED`. Usar `BEDROCK_PRICING["default"]` o la entrada `claude-sonnet-5-direct` como fuente del costo de Sonnet 5.5. Opus usa la tarifa escrita de `claude-opus-5-5-direct` porque el id devuelto empieza por `claude-opus-5-5`.
  8. `NEW`. Extensión de evidencia, 2026-09-29, sin cambiar el `PASS`. Quince imágenes, 30 llamadas, `F1_EXTENDED_STATUS=COMPLETE`. Mismos bytes, MIME, filename, locale `es`, photo intent vacío, fingerprint y `max_tokens` 8000 en cada par. `request_sha256` coincide dentro de cada par. El de resortes sigue en `3e5e1921756170d6421120227e40060fcc9eb7b9c789b2b4c3c041f1955a6085`. No hubo retry. El harness no lee `MODEL_TEXT` ni usa `FieldPhotoDensityGate`.
  9. `NEW`. Clase de evidencia `E3`. Pass rate Sonnet 5.5 `0.920000` (46/50) y Opus 5.5 `0.960000` (48/50). `opus_only_wins` 4, `sonnet_only_wins` 2, `shared_passes` 9, `shared_fails` 0, `shared_safety_fails` 0. `safety_fail_count` 0 en los dos. `MUST_BE_UNKNOWN` 21/21 en los dos. El gap de pass rate es 0,04, debajo del umbral 0,10 de `E2`, y `opus_only_wins` es 4, así que no es `E1`. No es `E4`: las dos tasas están sobre 0,5 y no hay fallos compartidos.
  10. `NEW`. El caso de resortes se repite en la misma dirección. Sonnet 5.5 `FAIL`, texto `conjunto de aisladores con cables colgantes`. Opus 5.5 `PASS`, texto `amarre de cables con resortes`. `fail_if` no aparece. No es una medición de varianza: una llamada por modelo.
  11. `NEW`. Costo con cache separado, tarifa citada en la página de Anthropic para las dos filas. Sonnet 5.5 `0.136262` (input+output `0.127014`, cache read `0.004886`, cache write 5 minutos `0.004362`). Opus 5.5 `0.351039` (input+output `0.337428`, cache read `0.004886`, cache write 5 minutos `0.008725`). Acumulado `0.487301`. Cap `1.000000`. Remanente `0.512699`. Los tokens de 1 hora fueron 0. Input idéntico, 18837 en los dos.
  12. `CONFIRMED`. Ninguna constant productiva cambió en la extensión. `MODEL_TEXT` sigue en `claude-sonnet-5`. El fingerprint sigue en `4f62491874c8fea82d78632657e9adc93da80c69e40157eee98b5cfe972715d1`.
- `derived_decisions`:
  - F1 no elige A, B, C, D ni E. La extensión tampoco.
  - El resultado no reinstala `bytes > 1_500_000 => Opus`. Las dos llamadas usaron el mismo binario.
  - Si la letra que F2 seleccione escribe `MODEL_TEXT`, también escribe `claude-sonnet-5-5-direct` con la tarifa citada y no usa `default`.
  - F3–F8 no cambian de contrato por este benchmark.
- `future_phases_changed`:
  - F2. `reason`: el Anexo C deja de decidir con la fila única. Lee `aggregate.json` de la extensión, la clase `E3` y los contadores de 15 imágenes. No instala un router. La extensión no asigna la letra.
  - F3. `reason`: revisada, sin edición. El benchmark visual no cambia el score ni la elegibilidad.
  - F4. `reason`: revisada, sin edición. Sigue sin `BLOCKED` por la ruta de F0.
  - F5. `reason`: revisada, sin edición. La precedencia y `correlation_id` no cambian. El `model_id` de la observación será el que deje F2.
  - F6. `reason`: revisada, sin edición.
  - F7. `reason`: revisada, sin edición.
  - F8. `reason`: revisada, sin edición.
- `next_phase_prompt_path`: `docs/PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29.md` (Anexo C)

### F2

- `phase`: F2
- `status`: `PASS`
- `letter`: B
- `adopted`: `true` para el default de Field Photo. La ingesta de documentos no se adopta.
- `head_initial`: `7f32d4837842e1e7e78ef652778a54860511b5f4`
- `head_final`: el commit de F2. El árbol no puede contener su propio SHA. Después del commit, `git rev-parse HEAD` es `head_final` y `git rev-parse HEAD^` es `head_initial`.
- `commit`: el único commit cuyo padre es `head_initial` y cuyo asunto nombra la letra B y dice que no se agregó routing por tamaño.
- `files_changed`:
  - `app/models/bedrock_query.rb`
  - `app/prompts/batch_chunking_prompt.rb`
  - `app/services/contractual_limits.rb`
  - `app/services/field_photo_analysis_service.rb`
  - `app/services/field_photo_density_gate.rb`
  - `test/jobs/field_photo_analysis_job_test.rb`
  - `test/services/bulk_cost_v2_request_builder_test.rb`
  - `test/services/contractual_limits_test.rb`
  - `test/services/field_companion_f2_letter_b_test.rb`
  - `test/services/field_photo_analysis_service_test.rb`
  - `test/services/manual_batch_ingestion_service_test.rb`
  - `docs/PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29.md`
  - `docs/README.md`
- `commands_executed`:
  - `env -u BUNDLE_PATH bin/rubocop --cache false` sobre los Ruby de F2
  - `env -u BUNDLE_PATH bin/rails test` con el regression gate, el test de la letra, el techo contractual, la ingesta Batch web, el builder Batch bulk y el fingerprint de `FieldPhotoPrompt`, en la misma invocación
  - `shasum -a 256` de los artefactos visuales ya existentes. Cero llamadas de imagen
- `command_results`:
  - RuboCop: 9 files, no offenses
  - tests: 250 runs, 1526 assertions, 0 failures, 0 errors, 1 skip
  - hashes de F1 y de la extensión, sin reescritura, los de `artifact_sha256`
- `tests`: regression gate de este plan, más `test/services/field_companion_f2_letter_b_test.rb`, `test/services/contractual_limits_test.rb`, `test/services/manual_batch_ingestion_service_test.rb`, `test/services/bulk_cost_v2_request_builder_test.rb` y `test/prompts/field_photo_prompt_test.rb`, en la misma invocación
- `test_results`: 250 runs, 1526 assertions, 0 failures, 0 errors, 1 skip. El skip es el test previo `Manual integration test: Upload a large JPEG (>500KB) via UI to verify compression` en `test/services/image_compression_service_test.rb`. No es de F2.
- `artifacts`: ninguno nuevo. Se releyeron, sin reescribir:
  - `tmp/field_companion/f1_extended/aggregate.json`
  - `tmp/field_companion/f1_extended/cost_report.json`
  - `tmp/field_companion/f1_extended/gold_manifest.json`
  - `tmp/field_companion/f1_extended/manifest.json`
  - `tmp/field_companion/f1_extended/SHA256SUMS.txt`
  - `tmp/field_companion/f1_visual.json`
  - `tmp/field_companion/outputs/spring_assembly_misread.claude-sonnet-5-5.txt`
  - `tmp/field_companion/outputs/spring_assembly_misread.claude-opus-5-5.txt`
  - `tmp/field_companion/visual_manifest.json`
  - `tmp/field_companion/images/spring_assembly_misread.png`
- `artifact_sha256`:
  - `aggregate.json` `fe283538ceceaf8d90a3b9a4444868abf0886e1745584eb09cb67d35c6e3fa84`
  - `cost_report.json` `72e13f1c32b7f9172301a206970df2a13707b0770dd4d14cb500a44affbdcc5b`
  - `gold_manifest.json` `2329d9d8d4cedc4309a6f608e82a398ff6c5e0cd942e376e0b9b9a1098411fbc`
  - `manifest.json` `62a639b54e17ae211d61407bdbb716844ce0d4e8480986dcaac12cfe2df0e477`
  - `SHA256SUMS.txt` `c5987e91750648649ba743cf94f4a598d5920ba7f088e6b79ca6821aedf5a4b9`
  - `f1_visual.json` `9244f1b5dca642ba72e45a938492a4036f548c9600047aafb0d7631a871868c4`
  - `spring_assembly_misread.claude-sonnet-5-5.txt` `0806d1c5f6ad98c50b74a4bb409ef1d5aa57ebf161ff72700bd8482fa422066b`
  - `spring_assembly_misread.claude-opus-5-5.txt` `f53745565e39091c5f622315e18d3e98d54c44cc4a64931a84d1211bdd452e3a`
  - `visual_manifest.json` `7a17aad222d0be44bf961b7119226fef54632a3789aa11e4cd985b95431a05f1`
  - `spring_assembly_misread.png` `202fbc9bee1f079914dfcb7dc5334ff1e9a776cb44b1c867c12a11ea04156ebd`
- `findings`:
  1. `CONFIRMED`. Letra B. `spring_split` = `opus_pass_sonnet_fail`. `opus_only_wins` 4. Opus no inventa identidad. Clase `E3`. No hay señal pre-call para un router.
  2. `CONFIRMED`. El default de Field Photo es `FieldPhotoAnalysisService::DEFAULT_MODEL` = `claude-sonnet-5-5`. La rama `>= 1_500_000` sigue en `claude-opus-5-5`.
  3. `CONFIRMED`. `BatchChunkingPrompt::MODEL_TEXT` sigue en `claude-sonnet-5`. La ingesta Batch de texto, bulk y web, sigue en Sonnet 5. El fallback Direct/retry sin modelo de página sigue en Sonnet 5. `force_opus` y la rama multimodal siguen en `claude-opus-5-5`.
  4. `NEW`. El Anexo C pedía escribir `MODEL_TEXT`. Ese constant es compartido con la ingesta. F2 no lo cambia. La separación es la constante de Field Photo.
  5. `CONFIRMED`. `claude-sonnet-5-5-direct` está en `BEDROCK_PRICING` con input `0.002`, output `0.01`, cache read `0.0002`, cache creation `0.0025`. No es la misma entrada que `claude-sonnet-5-direct`. No es `default`. `claude-sonnet-5-5-batch` no está.
  6. `CONFIRMED`. El umbral de 1,5 MB permanece y no se validó como predictor de dificultad. F2 no agregó otro corte.
  7. `CONFIRMED`. Fingerprint `4f62491874c8fea82d78632657e9adc93da80c69e40157eee98b5cfe972715d1`. Los hashes de arriba no se reescribieron.
  8. `REJECTED`. Migrar la ingesta documental a Sonnet 5.5 dentro de F2. Eso es F2B.
- `derived_decisions`:
  - Sonnet 5.5 es el default de Field Photo. Opus 5.5 es la capacidad superior conocida y no gana un router nuevo.
  - La ingesta Batch de texto permanece en `claude-sonnet-5` hasta F2B.
  - `INGESTION_CONTRACT_VERSION` no se toca.
- `future_phases_changed`:
  - F2B. `reason`: fase nueva, entre F2 y F3. Compara Sonnet 5 y Sonnet 5.5 sobre el payload real de Anthropic Batch API. No está ejecutada. El Anexo D es su prompt.
  - F3. `reason`: revisada, sin edición de contrato. No arranca. El benchmark visual y el default de la foto no cambian el score ni la elegibilidad.
  - F4. `reason`: revisada, sin edición.
  - F5. `reason`: revisada, sin edición. El `model_id` de una observación nueva de chat puede ser `claude-sonnet-5-5-direct` o `claude-opus-5-5-direct`.
  - F6. `reason`: revisada, sin edición.
  - F7. `reason`: revisada, sin edición.
  - F8. `reason`: revisada, sin edición.
- `next_phase_prompt_path`: `docs/PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29.md` (Anexo D)

### F2B

- `phase`: F2B
- `status`: `PASS`
- `gate`: `I1`
- `adopted`: `true` para `BatchChunkingPrompt::MODEL_TEXT` y para el retry Direct que cae en esa constante. Field Photo no se adopta por esta fase: ya tenía su propia constante.
- `head_initial`: `c4f5f2deea7357741dfff463896747178dde5d24`
- `head_final`: el commit de F2B. El árbol no puede contener su propio SHA. Después del commit, `git rev-parse HEAD` es `head_final` y `git rev-parse HEAD^` es `head_initial`.
- `commit`: el único commit cuyo padre es `head_initial` y cuyo asunto dice que la ingesta de texto pasa a Sonnet 5.5.
- `files_changed`:
  - `app/models/bedrock_query.rb`
  - `app/prompts/batch_chunking_prompt.rb`
  - `app/services/field_photo_analysis_service.rb`
  - `script/field_companion/ingestion_model_refresh.rb`
  - `test/jobs/ingest_batch_results_job_test.rb`
  - `test/models/bedrock_query_test.rb`
  - `test/script/field_companion_ingestion_model_refresh_test.rb`
  - `test/services/bulk_cost_v2_request_builder_test.rb`
  - `test/services/contractual_limits_test.rb`
  - `test/services/field_companion_f2_letter_b_test.rb`
  - `test/services/manual_batch_ingestion_service_test.rb`
  - `docs/PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29.md`
- `commands_executed`:
  - `env -u BUNDLE_PATH F2B_MODE=control_only bin/rails runner script/field_companion/ingestion_model_refresh.rb`
  - `env -u BUNDLE_PATH bin/rubocop --cache false` sobre los Ruby de F2B
  - `env -u BUNDLE_PATH bin/rails test` con el regression gate, la letra B, el techo contractual, la ingesta Batch web, el builder Batch bulk, el fingerprint de `FieldPhotoPrompt`, el harness de F2B, el pricing y el parser de resultados Batch, en la misma invocación
- `command_results`:
  - Control Sonnet 5: `msgbatch_01DUg2djyq7RUkoUz9wY4oHD`, creado `2026-09-30T01:00:20Z`, cerrado `2026-09-30T05:16:02Z`, 5 succeeded. El reloj de Batch no es latencia Direct.
  - Sonnet 5.5 reutilizado: `msgbatch_012f2XnkwfTma8UpS1FTShyS`, cerrado `2026-09-30T00:10:15Z`, 5 succeeded. No se reenvió.
  - Batch cancelado y no usado como resultado: `msgbatch_018dHEzmkEqpD8dgQJQpqUBu`, 5 canceled, 0 succeeded.
  - RuboCop: 11 files, no offenses
  - tests: 289 runs, 1644 assertions, 0 failures, 0 errors, 1 skip
- `tests`: regression gate de este plan, más `test/services/field_companion_f2_letter_b_test.rb`, `test/services/contractual_limits_test.rb`, `test/services/manual_batch_ingestion_service_test.rb`, `test/services/bulk_cost_v2_request_builder_test.rb`, `test/prompts/field_photo_prompt_test.rb`, `test/script/field_companion_ingestion_model_refresh_test.rb`, `test/models/bedrock_query_test.rb` y `test/jobs/ingest_batch_results_job_test.rb`, en la misma invocación
- `test_results`: 289 runs, 1644 assertions, 0 failures, 0 errors, 1 skip. El skip es el test previo `Manual integration test: Upload a large JPEG (>500KB) via UI to verify compression` en `test/services/image_compression_service_test.rb`. No es de F2B.
- `artifacts`: no se commitean. Viven en `tmp/field_companion/ingestion_model_refresh/`.
  - `aggregate.json`
  - `cost_report.json`
  - `dataset_manifest.json`
  - `gold_manifest.json`
  - `preflight.json`
  - `SHA256SUMS.txt`
- `artifact_sha256`:
  - `aggregate.json` `e9241dcc5032dc33796ea4306800dec3b4b41e80d7862b4a064730000df3b0ef`
  - `cost_report.json` `45587e6470a1bb2b8842c44fa4440830aa4a0848000f77874b3c4076c57bc4d0`
  - `dataset_manifest.json` `2087858483d37ddd43c9a7df51e197dd5ec47bf371c9240644e8178ef4868d20`
  - `gold_manifest.json` `0c847bfffb973e1bfb48a49acb8a11cf01d6a387f6e3fa29c2e5d5c874636e67`
  - `preflight.json` `dbbdbc78d7945dfb4763252ac4002c526824f16ff169958c5aa11d5b193203ed`
  - `SHA256SUMS.txt` `8f93c9d0637e8800f988b7bfa6b26447a9e7b7bc055f7846f8c72cb6003fb7e4`
- `comparison`: cinco unidades scored, mismos bytes y mismo payload salvo `model`. `tijera_p01`, `tijera_p18`, `tijera_p09`, `cert_p01` empatan en los campos votados. `tijera_p08` trunca en Sonnet 5 (`stop_reason=max_tokens`, JSON no parseable, `would_retry=true`) y Sonnet 5.5 cierra `end_turn` con JSON parseable. No hay `SAFETY_FAIL` nuevo. El costo Batch medido con usage de Anthropic es USD `0.211086` para Sonnet 5 y USD `0.159355` para Sonnet 5.5. Direct USD `0`. No se reintentó `tijera_p08` por Direct.
- `not_scored`: `tijera_p16` enruta a `MODEL_MULTIMODAL`. El compendio Gonzalo queda `NOT_AVAILABLE` porque la página muestreada es `scanned_dense`. `orona_p01`, `orona_p06` y `montacargas_p01` se prepararon y no se enviaron. No votan.
- `findings`:
  1. `CONFIRMED`. I1. En las cinco unidades scored, Sonnet 5.5 no agrega un `FAIL` donde Sonnet 5 tenía `PASS`, no agrega `SAFETY_FAIL` y no falla el contrato estructural.
  2. `CONFIRMED`. `MODEL_TEXT` es `claude-sonnet-5-5`. El builder bulk y el batch web de texto lo usan. El retry Direct sin modelo de página también.
  3. `CONFIRMED`. Field Photo sigue eligiendo `DEFAULT_MODEL` o `MODEL_MULTIMODAL`. La línea de modelo del servicio no lee `MODEL_TEXT`.
  4. `CONFIRMED`. `claude-sonnet-5-5-batch` tiene input `0.001`, output `0.005`, cache read `0.0001`, cache creation `0.00125`. `pricing_for` no cae en `default`. `claude-sonnet-5-5-direct` sigue en `0.002` / `0.01` / `0.0002` / `0.0025` y tampoco cae en `default`.
  5. `CONFIRMED`. `INGESTION_CONTRACT_VERSION` sigue `field_records_v8`. El fingerprint de `BatchChunkingPrompt` sigue `e5b574784ff78547886919fe388edd51decbc13b0a37cfbd11bc041ff4ac1172`. El de Field Photo sigue `4f62491874c8fea82d78632657e9adc93da80c69e40157eee98b5cfe972715d1`.
  6. `CONFIRMED`. El primer batch de Sonnet 5, `msgbatch_018dHEzmkEqpD8dgQJQpqUBu`, quedó cancelado con 0 succeeded y no entra en el score. El control válido es `msgbatch_01DUg2djyq7RUkoUz9wY4oHD`.
  7. `NEW`. Sonnet 5 y Sonnet 5.5 devolvieron un bloque `thinking` delante del texto. El parser de ingesta se queda con el primer bloque `text`. Un test lo fija. No se cambió el prompt para apagar thinking.
  8. `REJECTED`. Correr un segundo benchmark Direct sobre `tijera_p08`. El retry no se pagó. La compatibilidad del fallback queda en el test que captura `MODEL_TEXT`.
- `derived_decisions`:
  - La ingesta Batch de texto y el retry Direct sin modelo de página usan `claude-sonnet-5-5`.
  - Field Photo no se recablea a `MODEL_TEXT`.
  - `INGESTION_CONTRACT_VERSION` no se sube. El id del modelo no invalida la deduplicación.
  - El precio Batch publicado es el mismo. En estas cinco páginas Sonnet 5.5 costó menos por menos tokens de salida. Eso no es el gate.
- `future_phases_changed`:
  - F3. `reason`: revisada, sin edición de contrato. No arranca. El modelo de ingesta no cambia el score ni la elegibilidad. El prompt completo es el Anexo E.
  - F4. `reason`: revisada, sin edición. Sigue sin `BLOCKED`. El prompt de F4 lo reescribe F3, no F2B.
  - F5. `reason`: revisada, sin edición. Una observación nueva de chat sigue pudiendo persistir `claude-sonnet-5-5-direct` o `claude-opus-5-5-direct`.
  - F6. `reason`: revisada, sin edición.
  - F7. `reason`: revisada, sin edición.
  - F8. `reason`: revisada, sin edición.
- `next_phase_prompt_path`: `docs/PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29.md` (Anexo E)

### F3

- `phase`: F3
- `status`: `PASS`
- `head_initial`: `fa219c578743ccf538a425f569f2f81175048196`
- `head_final`: el commit de F3. El árbol no puede contener su propio SHA. Después del commit, `git rev-parse HEAD` es `head_final` y `git rev-parse HEAD^` es `head_initial`.
- `commit`: el único commit cuyo padre es `head_initial` y cuyo asunto dice que la sugerencia no escribe un pin.
- `files_changed`:
  - `app/controllers/rag_controller.rb`
  - `app/javascript/controllers/rag_chat_controller.js`
  - `app/services/pilot_usage_log.rb`
  - `app/services/rag/AGENTS.md`
  - `app/services/rag/manual_candidate_ranker.rb`
  - `script/field_companion/discovery_score.rb`
  - `test/controllers/rag_controller_manual_suggestion_test.rb`
  - `test/services/pilot_usage_log_test.rb`
  - `test/services/rag/manual_candidate_ranker_test.rb`
  - `test/system/rag_chat_manual_suggestion_test.rb`
  - `docs/PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29.md`
- `commands_executed`:
  - precheck `git rev-parse HEAD`, `git rev-parse HEAD^`, `git status --porcelain`, SHA256 de los dos artefactos F0
  - `env -u BUNDLE_PATH bin/rubocop --cache false` sobre los Ruby de F3
  - `env -u BUNDLE_PATH bin/rails test` con el regression gate, el ranker, la sugerencia del controller, el controller de Field Companion y el score de F0, en la misma invocación
  - `env -u BUNDLE_PATH bin/rails test test/system/rag_chat_manual_suggestion_test.rb`
- `command_results`:
  - HEAD `fa219c578743ccf538a425f569f2f81175048196`. HEAD^ `c4f5f2deea7357741dfff463896747178dde5d24`. Working tree limpio al abrir.
  - `f0_discovery.json` `0119f27bd05a86efe5371008bd1886f9791bf5d427eea1364682adad9b9e5ee0`
  - `f0_discovery_eligible.json` `47efb001265ee5985fd33cee156054acd81b9fad8736e111ac4291914cbeff36`
  - RuboCop: los Ruby de F3, no offenses
  - tests: 229 runs, 1745 assertions, 0 failures, 0 errors, 1 skip
  - system: 2 runs, 51 assertions, 0 failures, 0 errors, 0 skips. Desktop 1400×1400 y mobile 390×844.
- `tests`: regression gate de este plan, más `test/services/rag/manual_candidate_ranker_test.rb`, `test/controllers/rag_controller_manual_suggestion_test.rb`, `test/controllers/rag_controller_field_companion_test.rb` y `test/script/field_companion_discovery_score_test.rb`, en la misma invocación. El system test de las tarjetas corrió aparte.
- `test_results`: 229 runs, 1745 assertions, 0 failures, 0 errors, 1 skip. El skip es el test previo `Manual integration test: Upload a large JPEG (>500KB) via UI to verify compression` en `test/services/image_compression_service_test.rb`. No es de F3. El system test: 2 runs, 51 assertions, 0 failures, 0 errors, 0 skips.
- `artifacts`: ninguno nuevo. Se releyeron, sin reescribir:
  - `tmp/field_companion/f0_discovery.json`
  - `tmp/field_companion/f0_discovery_eligible.json`
- `artifact_sha256`:
  - `f0_discovery.json` `0119f27bd05a86efe5371008bd1886f9791bf5d427eea1364682adad9b9e5ee0`
  - `f0_discovery_eligible.json` `47efb001265ee5985fd33cee156054acd81b9fad8736e111ac4291914cbeff36`
- `findings`:
  1. `CONFIRMED`. El ranking previo al filtro de scope coincide con `f0_discovery.json` en fixture y holdout: `document_ids`, etiquetas, puntos, `tie_at_top`, `reason`, fabricante y `model_tokens`. El hash no cambió. `precision_at_3`, `top1_accuracy` y `wrong_brand_candidate_rate` no se recalcularon para cambiar la función.
  2. `CONFIRMED`. El viewer no owner es la cuenta `5`, slug `elevadores-climb`. `general_approved_count` 0. `f0_discovery_eligible.json` no le entrega documentos del ranking técnico. El hash no cambió.
  3. `CONFIRMED`. El scope no cambia los puntos. `UNCLASSIFIED` es `tenant_private` del dueño. Un `PRIVATE` o un `UNCLASSIFIED` de otra cuenta, de Legacy o de Pilot, no entra. Un `GENERAL_APPROVED` entra en el orden del score, con `Biblioteca general de Danebo`. El filtro no rellena por detrás del top 3.
  4. `CONFIRMED`. `tie_at_top` muestra hasta 3 tarjetas y `selected_document_uid` es nil. La sugerencia no llama `pin_kb_document!` y no escribe `active_entities`.
  5. `CONFIRMED`. El síntoma sin fabricante reconocido devuelve cero tarjetas, no busca dueños y no llama a retrieve. Más de un fabricante usa el texto fijo de cero candidatos y tampoco elige.
  6. `CONFIRMED`. La allowlist ganó solo `suggestion_document_uids` y `suggestion_scopes`, en el mismo orden. El evento es `manual_suggestion_shown`. `knowledge_scope` no está en la allowlist.
  7. `CONFIRMED`. No se aprobó ningún documento como `danebo_general`. No se copió un `KbDocument`, no se duplicó S3 y no se reindexó. `manual_corpus=general`, el `account_id` de índice del catálogo, el slug, el filename y un `knowledge_scope` suelto no son esa aprobación.
  8. `REJECTED`. Escribir un pin desde la sugerencia, o meter el texto de la tarjeta dentro de `answer`.
  9. `NEW`. El test de paridad carga los JSON de `tmp/field_companion/`. `tmp/` no se commitea. Si el archivo no está, el test hace skip. En esta corrida los dos archivos estaban y el skip no se tomó. El único skip del gate es el JPEG manual previo.
- `derived_decisions`:
  - La sugerencia no escribe un pin.
  - F4 no está `BLOCKED`. El tap sigue sin implementar.
  - No hay marca `GENERAL_APPROVED` nueva. El conteo sigue en 0.
  - `INGESTION_CONTRACT_VERSION`, `MODEL_TEXT`, `MODEL_MULTIMODAL`, `DEFAULT_MODEL`, `FieldPhotoPrompt`, `RagRetrievalProfile`, autorización, `generation.txt` y el renderer de procedencia no se tocaron.
- `future_phases_changed`:
  - F4. `reason`: el Anexo F es el prompt completo, con los hashes reales. F3 no implementa el tap. F4 sigue sin `BLOCKED`.
  - F5. `reason`: revisada, sin edición. F3 no toca fotos, retención ni `correlation_id`.
  - F6. `reason`: revisada, sin edición. La sugerencia no entra en `answer`, así que esas tarjetas no son una frase para marcar como `MANUAL_FACT`.
  - F7. `reason`: revisada, sin edición.
  - F8. `reason`: revisada, sin edición.
- `next_phase_prompt_path`: `docs/PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29.md` (Anexo F)

### F3B1

- `phase`: F3B1 — Authorization Foundation
- `status`: `PASS`
- `head_initial`: `c54513decddea7ef71be2e2462dd079efe9299c8`
- `head_final`: el commit de F3B1. El árbol no puede contener su propio SHA.
- `commit`: el único commit cuyo padre es `head_initial`. El asunto dice que la autorización de retrieval sale de `knowledge_scope` y que un pin denegado no abre el corpus.
- `files_changed`:
  - `app/controllers/pinned_documents_controller.rb`
  - `app/controllers/rag_controller.rb`
  - `app/models/account.rb`
  - `app/models/conversation_session.rb`
  - `app/models/kb_document.rb`
  - `app/models/knowledge_scope_change.rb`
  - `app/services/bedrock_rag_service.rb`
  - `app/services/knowledge_scope_eligibility.rb`
  - `app/services/query_orchestrator_service.rb`
  - `app/services/rag/AGENTS.md`
  - `app/services/rag/knowledge_scope_policy.rb`
  - `app/services/rag/manual_candidate_ranker.rb`
  - `config/locales/rag.en.yml`
  - `config/locales/rag.es.yml`
  - `db/migrate/20260930150000_add_knowledge_scope_to_kb_documents.rb`
  - `db/schema.rb`
  - `docs/ACTIVE_ARCHITECTURE.md`
  - `docs/MULTI_TENANT_ARCHITECTURE.md`
  - `docs/PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29.md`
  - `lib/tasks/knowledge_scope.rake`
  - `test/controllers/pinned_documents_controller_test.rb`
  - `test/controllers/rag_controller_manual_suggestion_test.rb`
  - `test/models/knowledge_scope_change_test.rb`
  - `test/services/bedrock_rag_service_knowledge_scope_test.rb`
  - `test/services/bedrock_rag_service_test.rb`
  - `test/services/knowledge_scope_eligibility_test.rb`
  - `test/services/query_orchestrator_service_test.rb`
  - `test/services/rag/knowledge_scope_policy_test.rb`
  - `test/services/rag/manual_candidate_ranker_test.rb`
  - `test/services/rag/shared_manual_corpus_test.rb`
  - `test/test_helper.rb`
- `commands_executed`:
  - `env -u BUNDLE_PATH bin/rails db:migrate` en development y test. El `SELECT` de backfill devolvió 0 filas fuera de `tenant_private`.
  - `DROP TRIGGER` / `DROP FUNCTION` de `knowledge_scope_changes_append_only` en development y test, después de sacar el trigger de la migración y de `schema.rb`
  - `env -u BUNDLE_PATH bundle exec rubocop` sobre los 21 Ruby de F3B1
  - `env -u BUNDLE_PATH bin/rails test` con los tests de scope, el ranker, pins, la sugerencia, el corpus compartido, `BedrockRagService`, el orquestador y el regression gate, en la misma invocación
- `command_results`:
  - padre `c54513decddea7ef71be2e2462dd079efe9299c8`
  - backfill: 0 filas con `knowledge_scope` distinto de `tenant_private`
  - RuboCop: 21 files, no offenses
  - tests: 397 runs, 2322 assertions, 0 failures, 0 errors, 6 skips
- `tests`: `test/models/knowledge_scope_change_test.rb`, `test/services/knowledge_scope_eligibility_test.rb`, `test/services/rag/knowledge_scope_policy_test.rb`, `test/services/bedrock_rag_service_knowledge_scope_test.rb`, `test/services/rag/manual_candidate_ranker_test.rb`, `test/controllers/pinned_documents_controller_test.rb`, `test/controllers/rag_controller_manual_suggestion_test.rb`, `test/services/rag/shared_manual_corpus_test.rb`, `test/services/bedrock_rag_service_test.rb`, `test/services/query_orchestrator_service_test.rb`, más el regression gate (`rag_retrieval_profile`, `structured_evidence_route`, `field_photo_analysis_service`, `field_photo_density_gate`, `image_compression_service`, `field_photo_analysis_job`, `pilot_usage_log`)
- `test_results`: 397 runs, 2322 assertions, 0 failures, 0 errors, 6 skips. Los skips son cinco tests de `DELIVERY_CHANNEL` de WhatsApp, canal dormido, y `ImageCompressionServiceTest#test_integration:_compresses_a_real_large_JPEG`. Ninguno es de F3B1. No hay skip nuevo de F3B1.
- `artifacts`: ninguno
- `artifact_sha256`: ninguno
- `findings`:
  1. `CONFIRMED`. No había un flag de cuenta interna. `accounts.danebo_controlled` nace en false. Slug, branded, Legacy y Pilot no lo encienden.
  2. `CONFIRMED`. `document_uid` y `s3_key` siguen siendo únicos por cuenta, no globales. La tarjeta ata la entrada del catálogo a la fila física por identidad canónica (`bucket` + object key) y `document_uid`. Si esa identidad no es una sola fila autorizada, el candidato se niega.
  3. `CONFIRMED`. El backfill dejó 0 filas fuera de `tenant_private`. No se sembró ningún `danebo_general`.
  4. `CONFIRMED`. El retrieve abierto, cuando no hay URI pedida, sigue siendo la cuenta de la sesión, Legacy, Pilot y `manual_corpus=general`. F3B2 no corrió.
  5. `CONFIRMED`. `GENERAL_APPROVED` ya no autoriza la sugerencia. La tarjeta sale de `Rag::KnowledgeScopePolicy` sobre la fila física.
  6. `CONFIRMED`. Una URI pedida que no está autorizada es `DENY_RETRIEVAL`. No hay llamada a Bedrock, no hay retry abierto y no hay caída a `account_filter`. No se usa una URI sentinela.
  7. `CONFIRMED`. El conjunto de pins se reautoriza entero. Si uno falla, no se consulta el resto. La sesión no borra el pin. El usuario puede quitarlo aunque ya no tenga lectura.
  8. `CONFIRMED`. Promover a `danebo_general` exige un ledger de ingesta completo, no foto, con `chunks_s3_prefix`. Un `KbDocument` sin ledger no está indexado.
  9. `CONFIRMED`. El audit log es append-only en la aplicación. `apply!` inserta. `update!`, `destroy!` y `update_columns` del modelo se rechazan. No hay trigger ni `structure.sql`.
  10. `NEW`. Los manuales históricos sin ledger no se pueden promover hasta que operación o F3B2 les adjunte esa evidencia. F3B1 no debilita el guard.
  11. `NEW`. `WarmBedrockKbJob` hace `Retrieve` directo, sin filtro de cuenta. Queda para F3B2. El canal WhatsApp sigue dormido; si se reabre, usa el mismo `query`.
  12. `REJECTED`. URI sentinela. Tratar “sin ledger” como indexado. Inferir generales desde slug, filename, manufacturer, catálogo, `confirmed` o path S3. Tratar el `actor` del rake como autenticación. Colapsar dos filas por `document_uid`.
- `derived_decisions`:
  - La autoridad de lectura es `kb_documents.knowledge_scope`. El audit log no se consulta para autorizar.
  - `KnowledgeScopeChange.apply!` es el único writer. Si el audit falla, el scope no cambia. Si el update falla, el audit no queda.
  - La identidad de autorización es la URI canónica de la fila. El string que manda el caller no se devuelve como scope.
  - Un conjunto de pins autorizado manda a Bedrock solo esas URIs. Un conjunto parcial inválido no hace retrieve.
  - El retry no forzado que abre el corpus histórico sigue solo cuando todas las URIs pedidas estaban autorizadas y Bedrock no devolvió evidencia.
- `future_phases_changed`:
  - F3B2. `reason`: no ejecutada. El Anexo G es el prompt completo. El filtro abierto histórico queda.
  - F4. `reason`: no ejecutada. Sigue en el Anexo F. No hay tap de sugerencia, no hay `manual_focus_confirmed` y `knowledge_scope` no entró en la allowlist de telemetría.
  - F5. `reason`: revisada, sin edición. Las fotos no pueden pasar a `danebo_general`.
  - F6. `reason`: revisada, sin edición.
  - F7. `reason`: revisada, sin edición.
  - F8. `reason`: revisada, sin edición.
- `next_phase_prompt_path`: `docs/PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29.md` (Anexo G)

### F3B2

- `phase`: F3B2 — Retrieval Alignment
- `status`: `PASS`
- `head_initial`: `1d5958f068ceea1aacf6639e2dca332cdf4aad8e`
- `head_final`: el commit de F3B2. El árbol no puede contener su propio SHA.
- `commit`: el único commit cuyo padre es `head_initial`. El asunto dice que el retrieve abierto se alinea con `knowledge_scope` y que Legacy, Pilot y `manual_corpus` dejan de conceder acceso.
- `files_changed`:
  - `app/jobs/warm_bedrock_kb_job.rb`
  - `app/services/bedrock_rag_service.rb`
  - `app/services/pilot_usage_log.rb`
  - `app/services/rag/AGENTS.md`
  - `app/services/rag/knowledge_scope_policy.rb`
  - `app/services/rag/open_retrieval_recall.rb`
  - `app/services/rag/shared_manual_corpus.rb`
  - `docs/ACTIVE_ARCHITECTURE.md`
  - `docs/MULTI_TENANT_ARCHITECTURE.md`
  - `docs/PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29.md`
  - `docs/PRODUCT_ROADMAP.md`
  - `docs/SESSION_AND_RETRIEVAL.md`
  - `lib/tasks/knowledge_scope.rake`
  - `script/field_companion/f3b2_recall.rb`
  - `test/services/bedrock_rag_service_attribution_guard_test.rb`
  - `test/services/bedrock_rag_service_knowledge_scope_test.rb`
  - `test/services/bedrock_rag_service_test.rb`
  - `test/services/rag/knowledge_scope_policy_test.rb`
  - `test/services/rag/open_retrieval_recall_test.rb`
  - `test/services/rag/shared_manual_corpus_test.rb`
- `commands_executed`:
  - `env -u BUNDLE_PATH bin/rails test` con policy, recall, `BedrockRagService` (incluido knowledge scope, attribution, grounded synthesis, audit y absence), corpus compartido, ranker, orquestador, pins, sugerencia, `knowledge_scope_change`, eligibility y el regression gate, en la misma invocación
  - `env -u BUNDLE_PATH bundle exec rubocop` sobre los 14 Ruby de F3B2
  - `env -u BUNDLE_PATH bin/rails runner script/field_companion/f3b2_recall.rb`
- `command_results`:
  - padre `1d5958f068ceea1aacf6639e2dca332cdf4aad8e`, working tree limpio al abrir
  - tests: 447 runs, 2735 assertions, 0 failures, 0 errors, 6 skips
  - RuboCop: 14 files, no offenses
  - recall: `tmp/field_companion/f3b2_recall.json`, SHA256 `74b467c0b72e7bcfd12118da6adee48038ee3ee3b7de11c590dc438c9f9bc887`. `tmp/` no se commitea
- `tests`: `test/services/rag/knowledge_scope_policy_test.rb`, `test/services/rag/open_retrieval_recall_test.rb`, `test/services/bedrock_rag_service_knowledge_scope_test.rb`, `test/services/bedrock_rag_service_test.rb`, `test/services/bedrock_rag_service_attribution_guard_test.rb`, `test/services/bedrock_rag_service_grounded_synthesis_test.rb`, `test/services/bedrock_rag_service_audit_test.rb`, `test/services/bedrock_rag_service_absence_contract_test.rb`, `test/services/rag/shared_manual_corpus_test.rb`, `test/services/rag/manual_candidate_ranker_test.rb`, `test/services/query_orchestrator_service_test.rb`, `test/controllers/pinned_documents_controller_test.rb`, `test/controllers/rag_controller_manual_suggestion_test.rb`, `test/models/knowledge_scope_change_test.rb`, `test/services/knowledge_scope_eligibility_test.rb`, más el regression gate (`rag_retrieval_profile`, `structured_evidence_route`, `field_photo_analysis_service`, `field_photo_density_gate`, `image_compression_service`, `field_photo_analysis_job`, `pilot_usage_log`)
- `test_results`: 447 runs, 2735 assertions, 0 failures, 0 errors, 6 skips. Los skips son cinco tests de `DELIVERY_CHANNEL` de WhatsApp, canal dormido, y `ImageCompressionServiceTest#test_integration:_compresses_a_real_large_JPEG`. Ninguno es de F3B2. No hay skip nuevo de F3B2.
- `artifacts`: `tmp/field_companion/f3b2_recall.json`
- `artifact_sha256`: `74b467c0b72e7bcfd12118da6adee48038ee3ee3b7de11c590dc438c9f9bc887`
- `findings`:
  1. `CONFIRMED`. El retrieve abierto anterior era un `orAll` de `account_id` de la sesión, los `account_id` de `Rag::SharedManualCorpus` (`danebo-legacy`, `danebo-pilot-elevator`, fotos fuera por `ingestion_path`) y `manual_corpus=general`.
  2. `CONFIRMED`. El retrieve abierto actual es `account_id` del viewer. Si hay filas ajenas `danebo_general` con una sola URI canónica, se suma `equals` de esa URI en `original_source_uri` y en `x-amz-bedrock-kb-source-uri`. Si hay varias, `in`. Las filas propias no se repiten en esa lista. Cero generales es un `equals` de `account_id`, porque `orAll` necesita al menos dos cláusulas.
  3. `CONFIRMED`. Legacy, Pilot, slug, filename, fabricante y `manual_corpus=general` ya no autorizan. `Rag::SharedManualCorpus.tag?` sigue escribiendo `manual_corpus` en el sidecar. `knowledge_scope:audit` solo imprime blockers. El único writer sigue siendo `knowledge_scope:apply`, dry-run salvo `APPLY=true`. No se promovió ningún documento. F3B1 dejó 0 `danebo_general`.
  4. `CONFIRMED`. `partition_evidence` corre antes de publicar citas y antes de un prompt local de generación (`retrieve_chunks`, `fallback_retrieve`, la ruta estructurada). Estados: `authorized`, `denied`, `ambiguous`, `unmapped`. Si todas las citas de `retrieve_and_generate` fallan, el texto generado se reemplaza por el no-results localizado y no hay fallback.
  5. `CONFIRMED`. `retrieve_and_generate` genera dentro de Bedrock. El filtro del request es lo que deja metadata fuera de ese prompt. El post-filter no puede deshacer una respuesta mixta sin una segunda llamada al modelo. Esta fase no agrega esa llamada. Si queda al menos una cita autorizada, se publican solo esas citas y el texto puede quedar.
  6. `CONFIRMED`. Un `custom_config` que contiene el `account_id` actual no es seguro por eso. Otro `account_id`, `account_id` dentro de `orAll`, `notEquals` / `notIn` / `in` sobre `account_id`, o `manual_corpus`, es `caller_filter_widens_scope`: `DENY_RETRIEVAL` y cero llamadas. Un predicado técnico se hace `andAll` con el corpus abierto si la forma cabe. Si no, `caller_filter_shape`. Un filtro de URI sigue siendo el camino de pin: el conjunto entero o `DENY_RETRIEVAL`.
  7. `CONFIRMED`. Contradicción con el Anexo G, punto 4: ese anexo pedía deny salvo que el filtro resultante fuera exactamente el corpus autorizado. El prompt de ejecución, posterior, permite restringir. Decisión: ampliar niega; un filtro técnico se intersecta. Sin filtro del caller, el filtro es el corpus abierto. No hay una tercera semántica.
  8. `CONFIRMED`. El Anexo G prohibía envolver `account_filter` en otro `andAll` porque el filtro viejo ya anidaba `andAll`. El filtro nuevo es plano. Un AND técnico queda en profundidad 2, que es el límite de Bedrock. No se agregó un operador.
  9. `CONFIRMED`. El retry no forzado de un pin suelta la URI y vuelve a preguntar sobre el corpus abierto nuevo. No restaura Legacy, Pilot ni `manual_corpus`. Un pin forzado no reintenta abierto. Un pin denegado no llama a Bedrock.
  10. `CONFIRMED`. Revocar `danebo_general` a `tenant_private` saca esa URI del siguiente retrieve de otra cuenta. El dueño sigue por `account_id`. Los pins de otras sesiones no se borran. Un pin de la fila revocada es `DENY_RETRIEVAL`.
  11. `CONFIRMED`. Recall sin Bedrock ni Anthropic, sobre `config/document_identities.yml`: 204 documentos, 19 con índice `1`, 185 con índice `3`, cero `knowledge_scope`. El viewer `3` retiene 185 y tiene 19 `backfill_gap`, incluido SEGURIDADES `b61f5d54-ff42-414a-97b7-01682d16f4b5`. El viewer `1` retiene 19 y tiene 185 de gap. El viewer `5` retiene 0. `added_by_approval` es 0. El holdout de SEGURIDADES no se reejecutó en vivo. El dueño de ese manual lo conserva. Para el piloto, los manuales propios quedan. El catálogo histórico compartido es gap de backfill, no una razón para devolver el OR. Alcanza para el MVP de aislamiento.
  12. `CONFIRMED`. Presupuesto de aplicación: `OPEN_RETRIEVAL_MAX_GENERAL_URIS` 100 y `OPEN_RETRIEVAL_MAX_URI_BYTES` 24000. Si se pasa, el brazo general sale vacío, no truncado, y el motivo es `general_uris_over_limit`. El `account_id` del dueño sigue. No se niega la consulta entera. Bedrock publica un operador lógico embebido, cinco cláusulas y profundidad 2. El operador `in` no publica un máximo. Con 0 generales el filtro es un `equals`. Con generales son tres cláusulas.
  13. `CONFIRMED`. `WarmBedrockKbJob` sigue siendo un `Retrieve` sin filtro. Descarta la respuesta. No la devuelve a un tenant y no la pasa a generación. No se refactorizó. No es un camino de autorización.
  14. `CONFIRMED`. WhatsApp sigue dormido. Quien llame `BedrockRagService#query` hereda el filtro y `DENY_RETRIEVAL`. Los cinco skips de `DELIVERY_CHANNEL` siguen.
  15. `CONFIRMED`. El score de F3, el top 3 y el no-refill no cambiaron. `RagRetrievalProfile` no cambió. El conjunto de pins sigue atómico.
  16. `CONFIRMED`. Un manual histórico sin ledger completo, no foto, con `chunks_s3_prefix`, sigue `tenant_private`. Filename, slug, `manual_corpus` y la sola fila no lo hacen elegible.
  17. `REJECTED`. Un feature flag que vuelva a Legacy, Pilot o `manual_corpus`. Eso reabriría acceso no autorizado. El rollback es revertir este commit. No hubo deploy.
  18. `REJECTED`. Promoción masiva, copia de `KbDocument`, copia S3, reindex por tenant, una KB por tenant, y una segunda llamada al modelo para reescribir la respuesta de `retrieve_and_generate`. `document_uid` no es clave de lookup.
  19. `NEW`. Un chunk cuya única URI es el objeto del chunk, sin `original_source_uri` y sin fila canónica, queda `unmapped` y se descarta aunque el `account_id` hubiera coincidido. Los sidecars escriben `original_source_uri`. El descarte es fail closed.
  20. `NEW`. El Anexo G pedía fail closed si el corpus no cabe. El prompt de ejecución también pide que el dueño conserve sus documentos. Decisión: el brazo general que no cabe no se envía, ni en parte. El dueño sigue por `account_id`. No se construyó una plataforma para 100k generales.
- `derived_decisions`:
  - La autoridad de scope sigue siendo `kb_documents.knowledge_scope`. El filtro de Bedrock es una traducción de filas autorizadas a URI canónica. No es una segunda autoridad.
  - Ampliar el corpus niega. Restringirlo con un predicado técnico se intersecta.
  - La revocación es global en el siguiente retrieve. No borra pins ajenos.
  - No hay flag de rollback hacia el OR histórico.
- `future_phases_changed`:
  - F4. `reason`: `READY`. El Anexo F es el prompt completo. El tap sigue sin implementar. F4 no cambia el filtro ni el score. No aprueba documentos.
  - F5. `reason`: revisada, sin edición. Las fotos siguen fuera de `danebo_general`.
  - F6. `reason`: revisada, sin edición. El post-filter no cambia el contrato de procedencia.
  - F7. `reason`: revisada, sin edición.
  - F8. `reason`: revisada, sin edición.
- `next_phase_prompt_path`: `docs/PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29.md` (Anexo F)

### F4

- `phase`: F4 — Confirmed Focus
- `status`: `PASS`
- `head_initial`: `900041984e3ddb7472afbd1e9c21685436d8202e`
- `head_final`: el commit de F4. El árbol no puede contener su propio SHA.
- `commit`: el único commit cuyo padre es `head_initial`. El asunto dice que el tap escribe `user_pin` solo en la sesión actual.
- `files_changed`:
  - `app/controllers/pinned_documents_controller.rb`
  - `app/controllers/rag_controller.rb`
  - `app/javascript/controllers/rag_chat_controller.js`
  - `app/models/conversation_session.rb`
  - `app/services/pilot_usage_log.rb`
  - `app/services/rag/AGENTS.md`
  - `app/services/rag/focus_notice.rb`
  - `app/services/rag/manual_candidate_ranker.rb`
  - `config/locales/rag.en.yml`
  - `config/locales/rag.es.yml`
  - `docs/PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29.md`
  - `docs/SESSION_AND_RETRIEVAL.md`
  - `docs/WEB_HOME.md`
  - `test/controllers/manual_focus_confirmation_test.rb`
  - `test/controllers/rag_controller_manual_suggestion_test.rb`
  - `test/services/pilot_usage_log_test.rb`
  - `test/services/rag/focus_notice_test.rb`
  - `test/services/rag/manual_candidate_ranker_test.rb`
  - `test/system/rag_chat_manual_suggestion_test.rb`
- `commands_executed`:
  - `env -u BUNDLE_PATH bin/rails test` con policy, recall, `BedrockRagService` (knowledge scope, attribution, grounded synthesis, audit, absence y el servicio), corpus compartido, ranker, orquestador, pins, sugerencia, foco, `FocusNotice`, `knowledge_scope_change`, eligibility y el regression gate, en la misma invocación
  - `env -u BUNDLE_PATH bin/rails test test/system/rag_chat_manual_suggestion_test.rb`
  - `env -u BUNDLE_PATH bundle exec rubocop` sobre los 12 Ruby de F4
- `command_results`:
  - padre `900041984e3ddb7472afbd1e9c21685436d8202e`, working tree limpio al abrir
  - tests: 471 runs, 2901 assertions, 0 failures, 0 errors, 6 skips
  - system: 3 runs, 85 assertions, 0 failures, 0 errors, 0 skips
  - RuboCop: 12 files, no offenses
- `tests`: `test/controllers/manual_focus_confirmation_test.rb`, `test/services/rag/focus_notice_test.rb`, `test/system/rag_chat_manual_suggestion_test.rb`, `test/controllers/pinned_documents_controller_test.rb`, `test/controllers/rag_controller_manual_suggestion_test.rb`, `test/services/rag/manual_candidate_ranker_test.rb`, `test/services/rag/knowledge_scope_policy_test.rb`, `test/services/bedrock_rag_service_knowledge_scope_test.rb`, `test/services/bedrock_rag_service_test.rb`, `test/services/bedrock_rag_service_attribution_guard_test.rb`, `test/services/bedrock_rag_service_grounded_synthesis_test.rb`, `test/services/bedrock_rag_service_audit_test.rb`, `test/services/bedrock_rag_service_absence_contract_test.rb`, `test/services/rag/open_retrieval_recall_test.rb`, `test/services/rag/shared_manual_corpus_test.rb`, `test/services/query_orchestrator_service_test.rb`, `test/models/knowledge_scope_change_test.rb`, `test/services/knowledge_scope_eligibility_test.rb`, `test/services/pilot_usage_log_test.rb`, más el regression gate (`rag_retrieval_profile`, `structured_evidence_route`, `field_photo_analysis_service`, `field_photo_density_gate`, `image_compression_service`, `field_photo_analysis_job`)
- `test_results`: 471 runs, 2901 assertions, 0 failures, 0 errors, 6 skips. Los skips son cinco tests de `DELIVERY_CHANNEL` de WhatsApp, canal dormido, y `ImageCompressionServiceTest#test_integration:_compresses_a_real_large_JPEG`. Ninguno es de F4. El system test suma 3 runs y 85 assertions, 0 skips. No hay skip nuevo de F4.
- `artifacts`: ninguno
- `artifact_sha256`: ninguno
- `findings`:
  1. `CONFIRMED`. La tarjeta de F3 no era un botón. El tap nuevo manda `kb_document_id` y `document_uid`. El id es la fila. El uid confirma esa fila. No hay lookup global por uid.
  2. `CONFIRMED`. La autorización se evalúa en el tap con `Rag::KnowledgeScopePolicy`. Una fila revocada, ausente o privada de otra cuenta no se pinea y no expone contenido. Un pin previo no se borra.
  3. `CONFIRMED`. Un `danebo_general` de otra cuenta se pinea sobre la misma fila. No hay `KbDocument` nuevo, no hay copia S3 y no hay `BedrockIngestionJob`.
  4. `CONFIRMED`. El pin vive en `active_entities` de la `ConversationSession` web de ese usuario y esa cuenta. Otra sesión de la misma cuenta no lo hereda. Otra cuenta tampoco. Sumar un foco no borra los demás.
  5. `CONFIRMED`. Con foco válido, la pregunta siguiente usa `force_entity_filter` y solo esas URIs canónicas. No hay fallback al corpus abierto. X+Y manda las dos. Un miembro inválido sigue en `DENY_RETRIEVAL`.
  6. `CONFIRMED`. Quitar foco funciona con la fila autorizada, revocada o ya borrada. No concede lectura.
  7. `CONFIRMED`. `tie_at_top` sigue con `data-selected=none` y cero pins hasta el tap. Cada botón pinea solo su fila. No hay auto-focus ni Mode C.
  8. `CONFIRMED`. `pin_conflict` se muestra y el pin queda. `identity_conflict` muestra las dos identidades y no pisa el hecho del técnico. Ese conflicto ya lo escribía `apply_photo_observation!` cuando el episodio está activo.
  9. `CONFIRMED`. `knowledge_scope` entró en `PilotUsageLog::ALLOWED_FIELDS`. `manual_focus_confirmed` solo sale en un pin nuevo de tarjeta. El scope del evento es `scope_for` del servidor. No se agregó `previous_manufacturer`. Las tres claves de F3B2 siguen.
  10. `CONFIRMED`. El score de F3, el top 3 y el no-refill no cambiaron. El retrieve abierto no cambió. `RagRetrievalProfile` no cambió.
  11. `NEW`. El Anexo F pide reautorizar, no un token que ate el tap a la tarjeta renderizada. La biblioteca ya pinea por id. La tarjeta suma la confirmación de uid. No se construyó un token de propósito.
  12. `NEW`. `DocumentOverviewWarmJob` se encola también en el primer pin de tarjeta, igual que en la biblioteca. Para un general ajeno el job busca la fila en la cuenta del viewer y no la copia.
  13. `NEW`. La sesión web no es por pestaña. Es una fila por usuario, cuenta y canal `web`. El aislamiento testeado es otra fila de sesión, no otro tab del mismo usuario.
  14. `REJECTED`. Auto-focus, umbral, Mode C, token firmado obligatorio, `previous_manufacturer` sin un segundo fabricante, y un pin de cuenta. Copiar la fila, copiar S3 o reindexar para poder enfocar un general.
- `derived_decisions`:
  - La identidad física es `kb_documents.id`. `document_uid` no es clave de lookup.
  - El tap reautoriza. No confía en el JSON de la tarjeta.
  - `manual_focus_confirmed` distingue el pin que nació de una tarjeta. El pin de biblioteca no emite ese evento.
  - Un foco explícito válido no cae al corpus abierto. Un conjunto parcial inválido no se recorta.
- `future_phases_changed`:
  - F5. `reason`: `READY`. El Anexo H es el prompt completo. F4 no migró `visual_observation`. El episodio sigue sin copiar ese JSON. `correlation_id` sigue en `sanitize_photo`. No se ejecutó.
  - F6. `reason`: revisada, sin edición. El pin no cambia las tres bandas de procedencia.
  - F7. `reason`: revisada, sin edición.
  - F8. `reason`: revisada, sin edición.
- `next_phase_prompt_path`: `docs/PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29.md` (Anexo H)

## Anexo G — prompt de F3B2

Ejecutá solo F3B2 — Retrieval Alignment de `docs/PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29.md`. No ejecutes F4. No hagas deploy. No rediseñes `knowledge_scope`. No reabras A/B/C/D. No vuelvas a comparar opciones de autoridad. F3B1 está `PASS`. El padre es el commit de F3B1. `git rev-parse HEAD^` tiene que ser `c54513decddea7ef71be2e2462dd079efe9299c8` solo si F3B1 es ese único commit; si hay commits posteriores, el padre del trabajo es el `HEAD` que Execution State de F3B1 llama `head_final` después del commit. Anotá `git rev-parse HEAD` como `head_initial` de F3B2. Si el working tree está dirty en algo que no sea F3B2, `STOP`.

F3B1 dejó la autoridad de lectura en `kb_documents.knowledge_scope` y `Rag::KnowledgeScopePolicy`. Un conjunto de URIs pedido se autoriza entero. Si una falla, el resultado es `DENY_RETRIEVAL`: cero llamadas a Bedrock, cero retry, cero `account_filter`. El pin de la sesión no se borra solo. Promover a `danebo_general` exige ledger completo con `chunks_s3_prefix`. El audit es append-only en la aplicación.

Lo que F3B1 no cerró, y esta fase cierra:

1. **Retrieve abierto histórico.** Sin pin, `BedrockRagService#account_filter` sigue siendo un `orAll` de la cuenta de la sesión, los `account_id` de `Rag::SharedManualCorpus::SLUGS` (`danebo-legacy`, `danebo-pilot-elevator`) y `manual_corpus=general`, con las fotos fuera por `ingestion_path`. Ese OR no es una aprobación. F3B2 lo saca como autorización. El corpus de una pregunta sin pin pasa a ser los `tenant_private` de la cuenta más los `danebo_general` vigentes. No copies documentos. No reindexes por tenant.

2. **Legacy, Pilot y `manual_corpus` dejan de autorizar.** Slug, `manual_corpus=general`, `GENERAL_APPROVED` sintético, filename y el catálogo de identidades no conceden lectura. Un chunk de Legacy o Pilot se recupera para otra cuenta solo si la fila física está en `danebo_general`. El default histórico que tagea esos slugs como general en la ingesta no se trata como esa marca. Documentá el writer que todavía escribe `manual_corpus` y dejalo de usar como filtro de autorización.

3. **Revocación global.** `tenant_private` después de `danebo_general` tiene que dejar de ser recuperable para quien no es el dueño, también en el retrieve que antes era abierto. El dueño sigue autorizado sobre su fila. Un pin de otra cuenta sobre ese documento queda en `DENY_RETRIEVAL` hasta que el usuario lo quite. No borres pins de otras sesiones en silencio: el deny ya impide el retrieve. Si hace falta un barrido de sesión, que sea explícito y testeado, no un efecto colateral del update de scope.

4. **OR de `account_filter` y `custom_config`.** El merge que hoy puede conservar un OR de cuentas cuando el caller manda un filtro sin URI tiene que quedar fail-closed. Un filtro inyectado no puede ampliar la cuenta, ni unir Legacy, ni unir Pilot, ni unir `manual_corpus=general`. Si el filtro resultante no es exactamente el corpus autorizado de esta fase, deny. No reintroduzcas una URI sentinela.

5. **Post-filter.** Las citas y los `DOC_REFS` que vuelvan de un retrieve abierto tienen que resolverse a una fila autorizada por la policy. Una cita cuya URI canónica no ata una fila autorizada se descarta. No alcanza con confiar en el filtro de Bedrock. El post-filter no llama otra vez al modelo.

6. **Recall.** Antes de cambiar el filtro productivo, medí en fixtures qué documentos hoy salen por el OR histórico y cuáles siguen saliendo cuando el filtro es `tenant_private` de la cuenta más `danebo_general`. El artefacto va a `tmp/field_companion/` con SHA256. `tmp/` no se commitea. Si el recall de un manual que Danebo quiere general cae porque no está promovido, el resultado es un gap de backfill, no una razón para dejar el OR.

7. **Rollout y backfill del ledger.** F3B1 niega la promoción si no hay un `WebManualBatch` o `BulkUploadAsset` completo, no foto, con `chunks_s3_prefix`. Los manuales históricos sin ese ledger siguen `tenant_private`. F3B2 puede reconciliar esa evidencia de forma explícita y durable. No inventes “indexado” por filename, slug o por la sola fila `KbDocument`. Si no podés demostrar el ledger, el documento no se promueve. El rake `knowledge_scope:apply` sigue siendo dry-run salvo `APPLY=true`. El actor sigue siendo una etiqueta, no autenticación.

8. **Callers que F3B1 dejó documentados.** `WarmBedrockKbJob` hace `Retrieve` directo, sin filtro de cuenta. Esta fase lo deja fuera del corpus ajeno o lo documenta como ping interno que no devuelve contenido a un tenant. El canal WhatsApp está dormido. Si un path dormido llama `BedrockRagService#query`, hereda `DENY_RETRIEVAL`. No reactives WhatsApp. No cambies `RagRetrievalProfile`. No subas `top_k`.

Bedrock: un filtro tiene un operador lógico embebido y como máximo cinco cláusulas. No envuelvas `account_filter` en otro `andAll`. Si el corpus nuevo no cabe, fail closed y dejá el diseño escrito. No llames a Bedrock ni a Anthropic en los tests.

Tests mínimos, Minitest, sin skip nuevo:

- sin pin, la cuenta A no recibe un privado de B, ni un manual de Legacy o Pilot que siga `tenant_private`, ni un chunk solo por `manual_corpus=general`;
- sin pin, A recibe su privado y un `danebo_general` vigente;
- revocar ese general saca a A del siguiente retrieve y deja al dueño autorizado;
- `custom_config` no puede OR-ear otra cuenta ni `manual_corpus`;
- una cita cuya URI no ata una fila autorizada no se publica;
- el conjunto de pins de F3B1 sigue atómico: un pin revocado no abre el corpus ni recorta el set;
- paridad de score del ranker sin cambios;
- el regression gate de este plan, sin red.

Al cerrar: tests, regression gate, RuboCop, `git diff`, Execution State de F3B2. Un solo commit. No escribas `head_final` dentro del árbol. No ejecutes F4. El Anexo F espera a que F3B2 esté `PASS`.

## Anexo A — prompt de F0

Ejecutá solo F0 de `docs/PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29.md`. No implementes F1. No cambies `BatchChunkingPrompt::MODEL_TEXT`, `MODEL_MULTIMODAL`, `FieldPhotoPrompt`, `ImageCompressionService::MAX_DIMENSION`, `RagRetrievalProfile`, pins, autorización, `generation.txt` ni el renderer. No agregues una columna de `knowledge_scope`. No reindexes. No copies `KbDocument` ni S3. No marques ningún documento como `danebo_general`.

HEAD de partida: el checkpoint de Execution State. `preparatory_head` tiene que ser `9c4f57c7514b7b7ccfdff5c7d3ddbdeb6456d739` y tiene que ser un ancestro del HEAD en el que abrís. Ese HEAD no puede diferir de `preparatory_head` en `app/`, `config/` ni `db/`. Anotá `git rev-parse HEAD` como `head_initial`. Si `preparatory_head` no es ese SHA, `STOP`.

Entregables, todos, o F0 no es `PASS`:

1. HEAD y resultado del regression gate.
2. Mapa del pipeline visual: model ids de HEAD (`claude-sonnet-5`, `claude-opus-5-5`), umbral 1_500_000, provider Anthropic Direct, `max_tokens` 8000, fingerprint `FieldPhotoPrompt.prompt_fingerprint_sha256`. Que `claude-sonnet-5-5` no esté en esas constants no es un blocker. FC-D18.
3. Probe multimodal, una sola llamada, sin evaluar calidad. Cliente `Anthropic::Client` directo, no `ClaudeChunkingClient` y no `TrackBedrockQueryJob`. Credencial: `ENV["ANTHROPIC_API_KEY"]` y, si falta, `Rails.application.credentials.dig(:anthropic, :api_key)`. No escribas la clave. Modelo forzado `claude-sonnet-5-5`. Imagen únicamente `docs/field_companion/multimodal_availability_probe.jpg` (4×3, 803 bytes, SHA256 `5610cba05ad3f23d2bc8fcdc4c473df0316e2d47982711d7ce6a3f880baeea3c`). No uses `resortes.png`. No uses `FieldPhotoPrompt`. `max_tokens` 16. `messages.create` con un bloque `image` base64 `image/jpeg` y un bloque `text` `ping`. Sin system prompt. Registrá `requested_model_id`, `returned_model_id` si la respuesta lo trae, `success` o la clase de error, y timestamp UTC ISO-8601. Si la llamada no es success, F1 queda `BLOCKED` en el prompt que reescribas. No cambies producción.
4. El fingerprint del punto 2, en el artefacto.
5. Mapa de preprocesado con las cuatro ramas de la sección 2, citando archivo y método. No afirmes que toda foto queda en 1024.
6. Mapa de persistencia: qué columnas de `field_photos` existen hoy, qué guarda el episodio (`active_photo`), el tope de 300 caracteres del historial, y que el JSON de visión no tiene columna. Confirmá si una columna jsonb en la misma fila muere con `FieldPhotoRetentionJob`. Si no puede, `STOP` y F5 = `BLOCKED`.
7. La matriz de k de la sección 3, verificada contra el código. Si el código no coincide con la tabla, corregí la tabla del plan en el mismo commit y dejalá el finding. No cambies el código del perfil.
8. Semántica de identidad: `effectively_confirmed?`, `MANUFACTURERS`, `Entry#brands`, `document_id` == `document_uid`. Un test del script demuestra que un YAML `confirmed: true` sin `evidence_text` no es `catalog_confirmed`.
9. `tmp/field_companion/f0_authorization_matrix.json` con las columnas de la sección 6: `document_uid`, `physical_owner_account_id`, `current_visibility`, `current_retrievability`, `current_pinnability`, `proposed_knowledge_scope`, `current_mechanism`, `minimum_change`, `reindex_required`, `duplicate_document_required`. La pregunta es la fuente mínima por documento para `GENERAL_APPROVED` sin copia y sin reindex. El mecanismo vigente es CASE B: `manual_corpus=general` no es esa aprobación. No propongas columna, reindex ni copia como elección. Si la única opción exige un atributo nuevo en el chunk, `reindex_required` queda `true` en esa opción y F4 hereda `BLOCKED`. No la elijas. El pin que describas vive en la sesión. FC-D16 y FC-D17. No cambies autorización.
10. Score de discovery implementado como función pura en `script/field_companion/discovery_score.rb`, idéntica a la sección 5. El scope no entra en los puntos. Test en `test/script/field_companion_discovery_score_test.rb` con entries sintéticos: marca correcta gana, otra marca no entra, designador exacto suma 80, `tie_at_top` con dos scores iguales ordena por `display_name`, cero fabricantes devuelve vacío, dos fabricantes devuelven `multiple_manufacturers`. Un caso más: el mismo entry con `knowledge_scope` distinto obtiene el mismo score. Sin red.
11. Fixture y holdout corridos contra `config/document_identities.yml`. Artefacto `tmp/field_companion/f0_discovery.json` con por frase: `document_id` ordenados, etiquetas, `tie_at_top`, `reason`, `precision_at_3`, `top1_accuracy`, `wrong_brand_candidate_rate`. El holdout no modifica la función.
12. `tmp/field_companion/visual_manifest.json`. Copiá `/Users/lahirisan/Desktop/resortes.png` byte a byte a `tmp/field_companion/images/spring_assembly_misread.png`. SHA256 exigido: `202fbc9bee1f079914dfcb7dc5334ff1e9a776cb44b1c867c12a11ea04156ebd`. 956×866, 1430913 bytes, `image/png`. Si no coincide, F0 = `BLOCKED`. Gold de la sección 9: `component` `VERIFIED`, fabricante, modelo y `visible_text` `NOT_SCORED`. No uses el JPEG de 803 bytes. No dejes estados `pending`. Una categoría sin archivo no se inventa y no bloquea F1.
13. Execution State de este archivo, fila F0 con el contrato completo de esta sección. Status `NOT STARTED` solo se reemplaza cuando los campos aplicables están llenos.
14. SHA256 de cada JSON de `tmp/field_companion/` escrito en la fila.
15. El Anexo B de este archivo, reemplazado entero por el prompt de F1. Tiene que incluir: resultado del probe (`requested_model_id`, `returned_model_id`, success o error, timestamp); que el harness fuerza `claude-sonnet-5-5` y `claude-opus-5-5` sin leer `MODEL_TEXT` ni el density gate; fingerprint; SHA256 del manifest; `case_id` elegibles; SHA256 de `spring_assembly_misread`; bytes, MIME, filename, locale `es`, photo intent vacío, el mismo system prompt y `max_tokens` 8000 en las dos llamadas; que `claude-sonnet-5` no se llama; que `NOT_SCORED` no entra en PASS/FAIL; el evaluador; el budget de como máximo 32 llamadas; y el formato de `tmp/field_companion/f1_visual.json`. Si el probe no fue success o el SHA de resortes no coincide, el prompt dice que no se llama a ningún modelo.
16. `tmp/field_companion/f0_general_inventory.json`. Cada `KbDocument` de `danebo-legacy` y `danebo-pilot-elevator`. Clasificación `GENERAL_APPROVED`, `PRIVATE` o `UNCLASSIFIED`, con la regla de la sección 6. `GENERAL_APPROVED` solo si hay una marca explícita de Danebo que no sea el slug ni el default de `corpus_scope` omitido. Si no hay esa marca, el conteo es cero. No apruebes manuales de Gonzalo, de Jesús ni de ningún tercero. `UNCLASSIFIED` queda anotado como `tenant_private`.
17. `tmp/field_companion/f0_discovery_eligible.json`. Misma función de score, después del filtro de elegibilidad. Con el inventario sin `GENERAL_APPROVED`, un viewer que no es owner no recibe esos documentos. `f0_discovery.json` sigue siendo el ranking técnico sin ese filtro.

Comandos: el regression gate, más `bin/rails test test/script/field_companion_discovery_score_test.rb`. El script de auditoría puede ser `ruby script/field_companion/f0_audit.rb` y no entra en CI si toca la API. El test del score sí entra, y no toca la red.

Al cerrar, revisá F1–F8 y registrá `future_phases_changed` con el reason. F4 queda `BLOCKED` en findings si ninguna opción de la matriz tiene `reindex_required = false` y `duplicate_document_required = false` a la vez. No cambies FC-D09 para forzar un sí. No reescribas el prompt de F4 en este chat: F3, cuando corra, reescribe el de F4 con los hashes reales. Si un hallazgo contradice la sección 6, editá la sección 6. `STOP` si la corrección pediría copiar documentos, reindexar por tenant, o tratar Legacy/Pilot como shared.

Commit, un solo commit de F0, mensaje:

```
Freeze Field Companion contracts for visual benchmark and discovery.

F0 records the visual pipeline, retrieval k matrix, and the
general-knowledge inventory without changing production behavior.
```

No hagas deploy. No ejecutes F1 en este mismo chat. No marques ningún documento como `danebo_general`.

## Anexo B — prompt de F1

Ejecutá solo F1 de `docs/PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29.md`. No ejecutes F2. No cambies `BatchChunkingPrompt::MODEL_TEXT`, `MODEL_MULTIMODAL`, `FieldPhotoPrompt`, `ImageCompressionService::MAX_DIMENSION`, `RagRetrievalProfile`, pins, autorización, `generation.txt` ni el renderer. No agregues `claude-sonnet-5-5` a las constants. No hagas deploy. No reabras el plan de precisión ni las decisiones FC-D01 a FC-D18. No pidas una decisión a Lahiri.

F0 está `PASS`. `head_initial` de F0 es `8385329ac1adfa552dbcf9101fab48709bc148fe`. El commit de F0 es el padre del trabajo de F1: asunto `Freeze Field Companion contracts for visual benchmark and discovery.` Si el working tree está dirty en algo que no sea F1, `STOP`.

### Probe que habilita las llamadas

El probe de F0 fue success. Podés llamar modelos.

- `requested_model_id`: `claude-sonnet-5-5`
- `returned_model_id`: `claude-sonnet-5-5`
- `success`: true
- `timestamp`: `2026-09-29T21:20:16Z`
- Cliente: `Anthropic::Client` directo. No uses `ClaudeChunkingClient`. No encoles `TrackBedrockQueryJob`. No escribas `bedrock_queries`.
- Credencial: `ENV["ANTHROPIC_API_KEY"]` y, si falta, `Rails.application.credentials.dig(:anthropic, :api_key)`. No imprimas la clave.
- No repitas el probe. No uses `docs/field_companion/multimodal_availability_probe.jpg` como caso. Su SHA256 es `5610cba05ad3f23d2bc8fcdc4c473df0316e2d47982711d7ce6a3f880baeea3c` y no entra al manifest.

### Harness

El harness es independiente del routing productivo. Fuerza, en el código del harness, estos dos ids y ningún otro:

- `claude-sonnet-5-5`
- `claude-opus-5-5`

No leas `BatchChunkingPrompt::MODEL_TEXT` ni `MODEL_MULTIMODAL` para elegir el modelo. No uses `FieldPhotoDensityGate`. No llames a `claude-sonnet-5`. No agregues un tercer modelo. No reintentes una llamada fallida.

System prompt = `FieldPhotoPrompt::SYSTEM_BLOCKS`. Antes de llamar, calculá `FieldPhotoPrompt.prompt_fingerprint_sha256`. Tiene que ser `4f62491874c8fea82d78632657e9adc93da80c69e40157eee98b5cfe972715d1`. Si no coincide, `STOP`: el prompt de producción cambió y este benchmark ya no es el de F0. No edites `FieldPhotoPrompt`.

`max_tokens` = 8000, que es `BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS`. Locale `es`. Photo intent vacío. Sin filename hint distinto del filename de la fila.

### Manifest

Path: `tmp/field_companion/visual_manifest.json`.

SHA256 del JSON: `7a17aad222d0be44bf961b7119226fef54632a3789aa11e4cd985b95431a05f1`.

Si el archivo no está, no lo reescribas a mano. Volvé a copiar los bytes solo si hace falta, sin recomprimir:

- origen: `/Users/lahirisan/Desktop/resortes.png`
- destino: `tmp/field_companion/images/spring_assembly_misread.png`
- SHA256 exigido: `202fbc9bee1f079914dfcb7dc5334ff1e9a776cb44b1c867c12a11ea04156ebd`
- bytes: 1430913
- dimensiones: 956×866
- MIME: `image/png`
- filename que ven los dos modelos: `spring_assembly_misread.png`

Si ese SHA256 no coincide, no llames a ningún modelo. F1 = `BLOCKED`.

`case_id` elegible, y el único: `spring_assembly_misread`. `categories`: `cable_fixing`, `springs`. Una categoría ausente no se inventa.

Gold, sin reinterpretar:

- `manufacturer`: `NOT_SCORED`
- `model`: `NOT_SCORED`
- `component`: `VERIFIED`, `allowed`: `resorte`, `resortes`, `muelle`, `muelles`, `fail_if`: `resistenc`, `bobinad`
- `visible_text`: `NOT_SCORED`

No hay `gold_overrides.yml`. No transcribas la placa. `NOT_SCORED` no se entrevista y no entra en PASS/FAIL.

### Llamadas

Como máximo 16 imágenes × 2 modelos = 32 llamadas. Con esta fila son 2, una por modelo, sin reintento. Una tercera llamada, un tercer modelo, o más de 16 imágenes es `STOP`.

Para la fila elegible, las dos llamadas son idénticas salvo el model id:

- los mismos bytes del PNG hasheado
- MIME `image/png`
- filename `spring_assembly_misread.png`
- locale `es`
- photo intent vacío
- el mismo system prompt
- `max_tokens` 8000

Guardá `requested_model_id`, `returned_model_id` y el SHA256 de los bytes que esa llamada envió. Si los dos SHA256 difieren, abortá la fila y no hagas otra llamada para corregirlo. No evalúes la foto del probe.

### Evaluador

Normalización: minúsculas, sin acentos, espacios colapsados.

- `VERIFIED`: PASS si el texto normalizado contiene al menos un valor `allowed` como palabra entera y no contiene ningún `fail_if`. FAIL si aparece un `fail_if`, o si no aparece ningún valor permitido. `fail_if` se busca como substring (`resistenc`, `bobinad`), no como palabra entera.
- `MUST_BE_UNKNOWN`: PASS si el valor normalizado es vacío o `unknown`. Cualquier otro valor es FAIL. Esta fila no tiene campos `MUST_BE_UNKNOWN`.
- `NOT_SCORED`: se omite. No suma PASS ni FAIL.

Por modelo:

- `identity_invention_count`: cantidad de FAIL en campos `MUST_BE_UNKNOWN`. En esta fila es 0.
- `component_fail_count`: 1 si `component` `VERIFIED` es FAIL, si no 0.
- tokens de input y output, latencia en ms, y costo.

Costo de `claude-sonnet-5-5`: `UNKNOWN`, salvo que cites `price_source` con URL. No copies la tarifa de `claude-sonnet-5-direct` ni uses la clave `default` de `BedrockQuery::BEDROCK_PRICING`. Costo de Opus: usá la tarifa ya escrita de `claude-opus-5-5-direct` (input 0,004 / output 0,02 dólares por 1.000 tokens) solo si `returned_model_id` empieza por `claude-opus-5-5`. Si el id devuelto es otro, el costo es `UNKNOWN`.

Contadores que F2 va a leer, calculados por el evaluador, sin elegir letra:

- `spring_split`: `opus_pass_sonnet_fail` si Opus pasa el `component` y Sonnet 5.5 lo falla; `sonnet_pass_opus_fail` si es al revés; `null` si ambos pasan o ambos fallan.
- `opus_only_wins`: filas elegibles donde Opus pasa todos los campos scored y Sonnet 5.5 falla al menos uno. `NOT_SCORED` no cuenta. Con una sola fila, 0 o 1.
- `shared_component_fail`: 1 si ambos fallan el `component`, si no 0.
- `shared_identity_fail`: 0 en esta fila, porque no tiene campos `MUST_BE_UNKNOWN`.

No elijas A, B, C, D ni E. Eso es F2. No preguntes cuál letra seguir.

### Artefacto

Escribí `tmp/field_companion/f1_visual.json` con esta forma. `tmp/` no se commitea. El SHA256 del archivo entra al Execution State.

```json
{
  "phase": "F1",
  "manifest_path": "tmp/field_companion/visual_manifest.json",
  "manifest_sha256": "7a17aad222d0be44bf961b7119226fef54632a3789aa11e4cd985b95431a05f1",
  "system_prompt_fingerprint_sha256": "4f62491874c8fea82d78632657e9adc93da80c69e40157eee98b5cfe972715d1",
  "locale": "es",
  "photo_intent": "",
  "max_tokens": 8000,
  "reads_model_text": false,
  "uses_density_gate": false,
  "calls": 2,
  "call_ceiling": 32,
  "cases": [
    {
      "case_id": "spring_assembly_misread",
      "filename": "spring_assembly_misread.png",
      "media_type": "image/png",
      "bytes": 1430913,
      "sha256": "202fbc9bee1f079914dfcb7dc5334ff1e9a776cb44b1c867c12a11ea04156ebd",
      "models": {
        "claude-sonnet-5-5": {
          "requested_model_id": "claude-sonnet-5-5",
          "returned_model_id": "",
          "bytes_sha256": "",
          "success": true,
          "error_class": null,
          "fields": {
            "component": { "status": "VERIFIED", "result": "PASS", "normalized_text": "" },
            "manufacturer": { "status": "NOT_SCORED" },
            "model": { "status": "NOT_SCORED" },
            "visible_text": { "status": "NOT_SCORED" }
          },
          "input_tokens": 0,
          "output_tokens": 0,
          "latency_ms": 0,
          "cost": "UNKNOWN",
          "price_source": null
        },
        "claude-opus-5-5": {}
      }
    }
  ],
  "by_model": {
    "claude-sonnet-5-5": { "identity_invention_count": 0, "component_fail_count": 0 },
    "claude-opus-5-5": { "identity_invention_count": 0, "component_fail_count": 0 }
  },
  "counters": {
    "spring_split": null,
    "opus_only_wins": 0,
    "shared_component_fail": 0,
    "shared_identity_fail": 0
  }
}
```

Los números de arriba son la forma, no los resultados. Rellená `result`, tokens, latencia, costo y contadores con la corrida. `NOT_SCORED` no lleva `result`. El objeto de Opus tiene las mismas claves que el de Sonnet 5.5.

### Cierre de F1

En este orden: el artefacto con SHA256; el regression gate de este plan (no llama Bedrock ni Anthropic); Execution State de F1; findings; revisión de F2–F8; reescritura completa del prompt de F2 en un anexo nuevo, con los contadores reales, para que F2 elija una sola letra de la sección 10 sin preguntar. No ejecutes F2 en el mismo chat. No cambies el modelo productivo.

## Anexo C — prompt de F2

Anexo C ya se ejecutó. La letra aplicada es B. El vehículo no es el reemplazo global de `MODEL_TEXT` que el texto de abajo ordena: ese constant también alimenta la ingesta Batch. F2 escribió `FieldPhotoAnalysisService::DEFAULT_MODEL`. `MODEL_TEXT` sigue en `claude-sonnet-5`. El padre efectivo es `7f32d4837842e1e7e78ef652778a54860511b5f4`. La precondición `HEAD^` = `efd138d5287727e24258293102e69c355dee3bf8` quedó obsoleta: ese SHA es el commit original de F1, y la extensión es el padre de F2. El cierre reescribió el prompt de F2B, Anexo D, y no el de F3. El texto que sigue es el prompt que se recibió.

Ejecutá solo F2 de `docs/PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29.md`. No ejecutes F3. No hagas deploy. No reabras el plan de precisión ni las decisiones FC-D01 a FC-D18. No pidas una decisión a Lahiri. No vuelvas a llamar a los dos modelos. No elijas los modelos con `BatchChunkingPrompt::MODEL_TEXT` ni con `FieldPhotoDensityGate`. No agregues un router por tipo de imagen, por tamaño ni por densidad.

La extensión de evidencia ya corrió. F2 no está empezada. El padre del trabajo de F2 es el commit de esa extensión. `git rev-parse HEAD^` tiene que ser `efd138d5287727e24258293102e69c355dee3bf8`. Si el working tree está dirty en algo que no sea F2, `STOP`. Anotá `git rev-parse HEAD` como `head_initial` de F2. El árbol de este anexo no contiene el SHA de su propio commit.

### Producción al abrir F2

No la des por cambiada hasta que la letra lo diga:

- `BatchChunkingPrompt::MODEL_TEXT` = `claude-sonnet-5` en `app/prompts/batch_chunking_prompt.rb`
- `BatchChunkingPrompt::MODEL_MULTIMODAL` = `claude-opus-5-5`
- `FieldPhotoDensityGate::LARGE_PHOTO_THRESHOLD` = `1_500_000`
- `FieldPhotoPrompt.prompt_fingerprint_sha256` = `4f62491874c8fea82d78632657e9adc93da80c69e40157eee98b5cfe972715d1`
- `BEDROCK_PRICING` no tiene `claude-sonnet-5-5` ni `claude-sonnet-5-5-direct`

### Evidencia que F2 lee

La decisión usa la extensión, no la fila única.

- `tmp/field_companion/f1_extended/aggregate.json` SHA256 `fe283538ceceaf8d90a3b9a4444868abf0886e1745584eb09cb67d35c6e3fa84`
- `tmp/field_companion/f1_extended/cost_report.json` SHA256 `72e13f1c32b7f9172301a206970df2a13707b0770dd4d14cb500a44affbdcc5b`
- `tmp/field_companion/f1_extended/gold_manifest.json` SHA256 `2329d9d8d4cedc4309a6f608e82a398ff6c5e0cd942e376e0b9b9a1098411fbc`
- `tmp/field_companion/f1_extended/manifest.json` SHA256 `62a639b54e17ae211d61407bdbb716844ce0d4e8480986dcaac12cfe2df0e477`
- `tmp/field_companion/f1_extended/SHA256SUMS.txt` SHA256 `c5987e91750648649ba743cf94f4a598d5920ba7f088e6b79ca6821aedf5a4b9`

Si `aggregate.json` está y el SHA256 no coincide, `STOP`. No regeneres el benchmark. Si el archivo no está, usá los contadores de este anexo y no hagas llamadas para recrearlo.

`f1_visual.json` histórico sigue en SHA256 `9244f1b5dca642ba72e45a938492a4036f548c9600047aafb0d7631a871868c4`. No es el input de la letra. No lo reescribas.

Dataset: `tmp/field_companion/images/f1_extended`. 15 imágenes. No había `SHA256SUMS.txt` en esa carpeta. El PNG de resortes conserva `202fbc9bee1f079914dfcb7dc5334ff1e9a776cb44b1c867c12a11ea04156ebd`. No se editó ni se recomprimió ninguna imagen.

Contrato de las 30 llamadas: `claude-sonnet-5-5` y `claude-opus-5-5` forzados. Mismos bytes, MIME, filename, locale `es`, photo intent vacío, system prompt, fingerprint y `max_tokens` 8000. Una llamada por par. `client_max_retries` 0. `retry_count` 0 en las 30. `returned_model_id` igual al pedido. `reads_model_text` false. `uses_density_gate` false. Status `COMPLETE`. `calls` 30. Pares completos 15.

### Costo

Tarifa citada, fila Claude Sonnet 5.5 y fila Claude Opus 5.5 de <https://platform.claude.com/docs/en/about-claude/pricing>, leída el 2026-09-29. Por 1.000 tokens:

- Sonnet 5.5: input `0.002`, output `0.01`, cache read `0.0002`, cache write de 5 minutos `0.0025`, cache write de 1 hora `0.004`
- Opus 5.5: input `0.004`, output `0.02`, cache read `0.0002`, cache write de 5 minutos `0.005`, cache write de 1 hora `0.008`

El `cache_control` del system prompt es `ephemeral` de 5 minutos. Los tokens de 1 hora fueron 0. El costo de cache no está metido en input ni en output.

| | Input+output | Cache read | Cache write 5 min | Total |
|---|---|---|---|---|
| `claude-sonnet-5-5` | `0.127014` | `0.004886` | `0.004362` | `0.136262` |
| `claude-opus-5-5` | `0.337428` | `0.004886` | `0.008725` | `0.351039` |
| Acumulado | | | | `0.487301` |

Cap `1.000000`. Remanente estimado `0.512699`. Input 18837 en los dos. Output Sonnet 8934, Opus 13104. Cache creation 1745 y cache read 24430 en los dos. Latencia total Sonnet 74963 ms, p50 4335, p95 7906. Opus 149148 ms, p50 9117, p95 16012.

### Clase de evidencia

`E3`. No es una decisión de producción.

Umbrales del harness, congelados antes de la corrida: `E4` si las dos tasas son menores que 0,5 y los fallos compartidos dominan las victorias exclusivas. `E2` si Opus gana en exclusivo al menos 2 filas, gana más que Sonnet, el gap de pass rate es de al menos 0,10 y Opus no tiene más `safety_fail`. `E1` si Sonnet queda a 0,05 o mejor y Opus gana en exclusivo menos de 2. El resto es `E3`.

Pass rate Sonnet `0.920000` (46/50). Opus `0.960000` (48/50). Gap 0,04. `opus_only_wins` 4. `sonnet_only_wins` 2. `shared_passes` 9. `shared_fails` 0. `shared_safety_fails` 0. `safety_fail_count` 0 en los dos. `MUST_BE_UNKNOWN` 21/21 en los dos.

| Campo | Sonnet 5.5 | Opus 5.5 |
|---|---|---|
| `component` | 11/15 | 14/15 |
| `manufacturer` | 2/2 | 2/2 |
| `model` | 2/2 | 1/2 |
| `visible_text` | 10/10 | 10/10 |
| `MUST_BE_UNKNOWN` | 21/21 | 21/21 |
| `SAFETY_FAIL` | 0 | 0 |

No hay safety failures. Nadie inventó fabricante o modelo en un campo `MUST_BE_UNKNOWN`. Nadie leyó texto en la foto de hueco, que no tiene texto. El esquema hidráulico fue leído como documento por los dos. No hubo función inventada en las fotos sin leyenda escrita.

Victorias exclusivas. No son invenciones de identidad:

- `spring_assembly_misread`: Sonnet `FAIL` `conjunto de aisladores con cables colgantes`. Opus `PASS` `amarre de cables con resortes`. `spring_split` = `opus_pass_sonnet_fail`.
- `field_dense_control_panel`: Sonnet nombra `tarjeta de control orona pbcm-v3` y no entra en `placa` / `controlador` / `tablero`. Fabricante y modelo `PASS` en los dos.
- `field_degraded_error_display`: Sonnet nombra `pantalla de codigo de error en tarjeta`. Opus pasa `display`.
- `field_kone_controller`: Sonnet nombra `panel de control de ascensor kone`. Opus pasa el componente. El fabricante quedó `NOT_SCORED` porque el logo KONE es una capa encima de la foto.
- `field_cabin_panel_with_diagram`: Opus devuelve `model` `UNKNOWN` y falla el `3020` impreso. Sonnet pasa.
- `field_branded_indicator`: Opus nombra `botonera de llamada de piso` y no entra en `indicador` / `display`. Sonnet pasa. El logo de esquina no se puntúa como fabricante.

`shared_component_fail` 0. `shared_identity_fail` 0. `identity_invention_count` 0 en los dos.

### Una sola letra

Aplicá estas reglas a los contadores de la extensión. Sale una sola letra. Implementá solo esa. No preguntes cuál seguir. No abras un segundo experimento. No uses los contadores de la fila única.

- **A.** `opus_only_wins == 0` y Sonnet 5.5 no tiene `identity_invention` en campos `MUST_BE_UNKNOWN`, y no hay `spring_split` a favor de Opus. Reemplazá `BatchChunkingPrompt::MODEL_TEXT` por `claude-sonnet-5-5`. El umbral de 1,5 MB y `MODEL_MULTIMODAL` no se tocan. No agregues un routing por tamaño. Cero llamadas de imagen.
- **B.** `spring_split` a favor de Opus, u `opus_only_wins >= 2`, y en esas filas Opus no inventa identidad. Hacé el mismo cambio de `MODEL_TEXT` que A. No implementes routing selectivo a Opus. Dejá el finding `selective_opus_routing: proposed_not_implemented`. Cero llamadas de imagen. `opus_pass_sonnet_fail` es el split a favor de Opus. La clase `E3` confirma que no hay señal para rutear antes de ejecutar el modelo.
- **C.** Ambos fallan el `component` de resortes (`shared_component_fail` incluye ese case) y no aplica A ni B. El experimento, dentro de F2, es resolución: mismo prompt y mismo `claude-sonnet-5-5`, bytes de control contra un derivado de lado largo 2048. El derivado lo produce `ImageCompressionService` con `MAX_DIMENSION` local al script. No edites `ImageCompressionService::MAX_DIMENSION`. Una sola variable. Una llamada nueva por imagen elegible. El techo es esa llamada, no una segunda.
- **D.** No aplica A, B ni C, y `shared_identity_fail` es mayor que `shared_component_fail`. El experimento es un prompt observation-first, mismos bytes, solo Sonnet 5.5. El script usa una copia del prompt. No publiques esa copia en `FieldPhotoPrompt` en la misma fase salvo que el experimento gane el case de resortes, no suba `identity_invention`, y un test fije el fingerprint nuevo. Si el experimento no gana, el prompt de producción queda igual y la letra registrada es D con `adopted: false`.
- **E.** Ninguna letra anterior. `SKIP`. Cero cambio de modelo, de prompt y de resolución. Cero llamadas.

Con los contadores de este anexo, A no aplica. C no aplica. D no aplica. E no aplica si B aplica. Opus no inventa identidad en las filas que gana. La letra que dejan las reglas es B. La extensión no la implementó.

A y B son el cambio de default. C y D son el experimento, no un segundo cambio encima. E no cambia nada. El resultado no autoriza volver a `bytes > 1_500_000 => Opus`. `E3` no autoriza un router.

### Si la letra escribe `MODEL_TEXT`

Agregá en `app/models/bedrock_query.rb`, dentro de `BEDROCK_PRICING`, la clave exacta `claude-sonnet-5-5-direct`:

- input `0.002`
- output `0.01`
- cache_read `0.0002`
- cache_creation `0.0025`

Esos números son la fila Claude Sonnet 5.5 de <https://platform.claude.com/docs/en/about-claude/pricing>: $2 / $10 / $0,20 por MTok, y cache write de 5 minutos $2,50 / MTok. La write de 1 hora ($4 / MTok) no se escribe. No copies la entrada `claude-sonnet-5-direct` como alias. No uses `default`. `ClaudeChunkingClient` persiste el id con sufijo `-direct`, así que el test cubre `pricing_for("claude-sonnet-5-5-direct")`. El test afirma los cuatro números y que ese resultado no es `BEDROCK_PRICING["default"]`. `#cost` de una fila con ese `model_id` usa esa clave.

`MODEL_MULTIMODAL` sigue `claude-opus-5-5`. `LARGE_PHOTO_THRESHOLD` sigue `1_500_000`. `FieldPhotoPrompt` no se edita en A ni en B. El fingerprint `4f62491874c8fea82d78632657e9adc93da80c69e40157eee98b5cfe972715d1` tiene que seguir igual si la letra no es D con adopción.

### Cierre de F2

En este orden: tests de la letra; el regression gate de este plan (no llama Bedrock ni Anthropic); artefacto de la letra si C o D llamaron al modelo, con SHA256; commit; Execution State de F2 con la letra y `adopted` cuando aplique; findings; revisión de F3–F8; reescritura completa del prompt de F3. No ejecutes F3. No hagas deploy.

El regression gate es:

```
bin/rails test \
  test/services/rag_retrieval_profile_test.rb \
  test/services/rag/structured_evidence_route_test.rb \
  test/services/field_photo_analysis_service_test.rb \
  test/services/field_photo_density_gate_test.rb \
  test/services/image_compression_service_test.rb \
  test/jobs/field_photo_analysis_job_test.rb \
  test/services/pilot_usage_log_test.rb
```

Más el test nuevo de la letra, en la misma invocación o en una seguida. Un solo commit de F2. El mensaje nombra la letra y dice que no se agregó routing por tamaño. `head_final` no puede estar escrito dentro del árbol: después del commit, `git rev-parse HEAD` es `head_final` y `git rev-parse HEAD^` es el `head_initial` que anotaste.

## Anexo D — prompt de F2B

Anexo D ya se ejecutó. La decisión fue I1. `MODEL_TEXT` pasó a `claude-sonnet-5-5`. El padre efectivo es `c4f5f2deea7357741dfff463896747178dde5d24`. El texto que sigue es el prompt que se recibió.

Ejecutá solo F2B de `docs/PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29.md`. F2B es Ingestion Model Refresh. El objetivo es comparar `claude-sonnet-5` y `claude-sonnet-5-5` sobre el payload real de Anthropic Batch API. No ejecutes F3. No hagas deploy. No reabras F2. No cambies Field Photo. No pidas una decisión a Lahiri.

`git rev-parse HEAD^` tiene que ser `7f32d4837842e1e7e78ef652778a54860511b5f4`. Si no lo es, `STOP`. Anotá `git rev-parse HEAD` como `head_initial` de F2B. Ese HEAD es el commit de F2. El árbol de este anexo no contiene el SHA de F2B.

### Qué no cambia

- `FieldPhotoAnalysisService::DEFAULT_MODEL` sigue `claude-sonnet-5-5`.
- `BatchChunkingPrompt::MODEL_MULTIMODAL` sigue `claude-opus-5-5`.
- `FieldPhotoDensityGate::LARGE_PHOTO_THRESHOLD` sigue `1_500_000`. No agregues otro corte ni un router.
- `FieldPhotoPrompt` y su fingerprint no se editan.
- El prompt de ingesta no se edita. `INGESTION_CONTRACT_VERSION` no se sube. La deduplicación no usa el id del modelo.
- RAG, embeddings, discovery, provenance, conocimiento compartido, top-k y pins no se tocan.
- No uses el harness visual de F1. No mide ingesta.

### Ruta que se mide

La ingesta principal es Anthropic Batch API:

- Bulk: `BulkCostV2RequestBuilder` arma el request. `BatchIngestionService` lo manda. `ClaudeBatchClient#submit_batch` llama `messages.batches.create`.
- Web, PDF largo: `ManualBatchIngestionService` arma el request y usa el mismo cliente. `CustomChunkingPipeline` manda a batch cuando `page_count` supera el umbral de páginas sync. Si no es un PDF largo, el pipeline de web levanta `PerimeterError`. No mide ese camino como si fuera `SingleFileChunkingService`.
- El modelo de una página de texto sale de `SplitPage`, que arranca en `BatchChunkingPrompt::MODEL_TEXT`. `force_opus` pone `MODEL_MULTIMODAL`. Esas páginas Opus no son un brazo de la comparación Sonnet.
- El resultado Batch se persiste con sufijo `-batch` y `latency_ms` 0.

`ClaudeChunkingClient` no es la medición principal. `BatchPageRetryService` reintenta una página por Direct cuando el batch cortó por `max_tokens` o el JSON no parsea. Si no hay modelo en el resultado, cae en `MODEL_TEXT`. Ese costo se anota aparte. No se mezcla con el costo Batch. `SingleFileChunkingService` y los scripts `script/reparse_benchmark_corpus.rb` y `script/ingest_benchmark_corpus.rb` tampoco son la medición.

### Dataset

8 a 12 unidades reales de ingesta, con SHA256 del binario de cada página. Categorías a cubrir si el archivo existe: tabla, página densa, esquema eléctrico, continuación, varias marcas, códigos, valores numéricos, `UNKNOWN`, un caso problemático de `field_records`, y una unidad que se pueda puntuar como ancla y como contenido.

No inventes gold. Si el archivo no está, la categoría queda `NOT_AVAILABLE`. `~/Desktop/corpus_v2_subir` no estaba al cerrar F2. `script/fixtures/rag_quality_benchmark_corpus.json` nombra un PDF de 24 páginas y un PNG hidráulico; el gold de field records que hay es `field_records_v3`, no `field_records_v8`. No los trates como casos scored de v8. Si no queda ninguna unidad con hash y con gold scored, F2B = `BLOCKED`. Cero llamadas. `MODEL_TEXT` no se toca.

Cada unidad scored declara campos `PASS`, `FAIL` o `NOT_SCORED` antes de la llamada. `NOT_SCORED` no vota.

### Pricing antes de llamar

F2 no escribió `claude-sonnet-5-5-batch`. Antes de cualquier llamada Batch con `claude-sonnet-5-5`, leé de nuevo <https://platform.claude.com/docs/en/about-claude/pricing> y agregá la clave exacta. La lectura del 2026-09-29 daba batch $1 / $5 por MTok. La convención ya escrita para `claude-sonnet-5-batch` es cache read 0,1× y cache creation 1,25× de la tarifa de input batch. Volvé a leerla. Si la página no muestra esa fila, `STOP`. No inventes el número. No uses un alias de `claude-sonnet-5-batch`. No uses `default`. `pricing_for("claude-sonnet-5-5")` y `pricing_for("claude-sonnet-5-5-batch")` no pueden caer en `default` si vas a llamar ese id. La clave `claude-sonnet-5-5-direct` ya está y no se reescribe.

### Comparación

Mismos bytes, mismo `BatchChunkingPrompt::SYSTEM_BLOCKS`, mismo `page_user_content`, mismo `max_tokens` (`WEB_PAGE_MAX_TOKENS`). Dos modelos: `claude-sonnet-5` y `claude-sonnet-5-5`. El request tiene la forma que ya produce el builder: `params.model`, system y user content. Una llamada Batch por página y por modelo. Sin reintento dentro de la comparación. El retry Direct, si ocurre, se cuenta en otra línea.

Regla congelada antes de mirar salidas. `MODEL_TEXT` pasa a `claude-sonnet-5-5` solo si hay al menos una unidad scored y, en todas las unidades scored, Sonnet 5.5 no tiene más `FAIL` que Sonnet 5 y no agrega una invención en un campo que el gold marca como desconocido. Una categoría `NOT_AVAILABLE` no vota y no alcanza para adoptar. Si la regla no se cumple, `adopted: false` y `MODEL_TEXT` sigue en `claude-sonnet-5`. La adopción, si corresponde, va en un commit posterior al artefacto de la medición. No se mezcla con F3.

### Cierre de F2B

En este orden: tests; el regression gate de este plan; artefacto con SHA256, modelos, tokens, latencia de batch si el proveedor la da, costo Batch y costo Direct por separado; Execution State; findings; revisión de F3–F8; reescritura completa del prompt de la fase siguiente. Si F2B queda `BLOCKED` por dataset, el prompt siguiente no llama modelos y no cambia `MODEL_TEXT`. No ejecutes F3 en el mismo chat. `head_final` no se escribe dentro del árbol.

## Anexo E — prompt de F3

Anexo E ya se ejecutó. F3 quedó `PASS`. La sugerencia no escribe un pin. El padre efectivo es `fa219c578743ccf538a425f569f2f81175048196`. El texto que sigue es el prompt que se recibió.

Ejecutá solo F3 de `docs/PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29.md`. F3 es Discovery A, suggest-only. No ejecutes F4. No hagas deploy. No reabras F2 ni F2B. No cambies `BatchChunkingPrompt::MODEL_TEXT`, `MODEL_MULTIMODAL`, `FieldPhotoAnalysisService::DEFAULT_MODEL`, `FieldPhotoPrompt`, `INGESTION_CONTRACT_VERSION`, `RagRetrievalProfile`, pins, autorización, `generation.txt` ni el renderer de procedencia. No llames a un modelo. No pidas una decisión a Lahiri.

F2B está `PASS` con gate `I1`. `MODEL_TEXT` ya es `claude-sonnet-5-5`. El padre del commit de F2B es `c4f5f2deea7357741dfff463896747178dde5d24`. `git rev-parse HEAD^` tiene que ser ese SHA. Si no lo es, `STOP`. Anotá `git rev-parse HEAD` como `head_initial` de F3. Ese HEAD es el commit de F2B. El árbol de este anexo no contiene el SHA de F3 ni el de F2B.

### Qué no cambia

- El score de la sección 5 no gana ni pierde puntos por `knowledge_scope`.
- `tie_at_top` no elige un manual y no escribe un pin.
- El síntoma no dispara retrieve.
- F3 no escribe `active_entities`.
- F3 no llama a Bedrock ni a Anthropic para rankear.
- Como máximo 3 tarjetas.
- Un `PRIVATE` o `UNCLASSIFIED` de otra cuenta no se muestra.
- No se aprueba ningún documento como `danebo_general`.
- No se copia un `KbDocument`, no se copia S3 y no se reindexa.

### Score

Copiá `FieldCompanion::DiscoveryScore` a `app/services/rag/manual_candidate_ranker.rb` sin alterar puntos, desempate ni textos fijos de la sección 5. La función de F0 en `script/field_companion/discovery_score.rb` sigue siendo el original. El servicio de runtime no puede divergir.

Textos fijos, una sola vez:

- Solo marca: `manual de la misma marca; compatibilidad con este equipo no confirmada`. Etiqueta `BRAND_ONLY`.
- Designador exacto: `el documento coincide con el modelo/designador indicado`. Etiqueta `EXACT_DESIGNATOR`.
- Cero candidatos, o más de un fabricante: `No encontré un manual claramente asociado a esa identidad en la biblioteca actual.`

Procedencia documental de la tarjeta, que no es la procedencia de la respuesta:

- `danebo_general`: `Biblioteca general de Danebo`
- `tenant_private` de la cuenta del técnico: `Tu biblioteca`

### Paridad

Estos dos archivos tienen que existir y coincidir byte a byte. Si falta el de score, F3 = `BLOCKED` y no hay tarjetas.

- `tmp/field_companion/f0_discovery.json` SHA256 `0119f27bd05a86efe5371008bd1886f9791bf5d427eea1364682adad9b9e5ee0`
- `tmp/field_companion/f0_discovery_eligible.json` SHA256 `47efb001265ee5985fd33cee156054acd81b9fad8736e111ac4291914cbeff36`

Un test carga `f0_discovery.json` y exige, por cada frase de `fixture` y de `holdout`, la misma lista ordenada de `document_ids` que devuelve el ranker antes del filtro de scope. Otro test carga `f0_discovery_eligible.json`. El viewer no owner es la cuenta `5`, slug `elevadores-climb`. Con `general_approved_count` 0, esa lista no le entrega documentos del ranking técnico. `precision_at_3`, `top1_accuracy` y `wrong_brand_candidate_rate` del artefacto de F0 no se recalculan para cambiar la función.

F0 confirmó `existing_document_id_session_pin` con `reindex_required = false` y `duplicate_document_required = false`. F4 no queda `BLOCKED` por eso. F3 igual no implementa el tap.

### Elegibilidad

Antes de devolver candidatos, descartá los que el tenant no puede usar. El orden que sobrevive es el orden del score.

Tests con fixtures, sin red:

- Un `PRIVATE` de otra cuenta no entra.
- Un `UNCLASSIFIED` de Legacy o Pilot no entra para otro tenant.
- Un `GENERAL_APPROVED` entra, con el mismo orden que le habría dado el score, y con el texto de biblioteca general.
- Adjuntar scope no cambia los puntos de la sección 5.
- `tie_at_top` muestra hasta 3 tarjetas y no elige una.
- El síntoma, sin fabricante reconocido, no arma tarjetas y no llama a retrieve.

Si el archivo de elegibilidad falta pero el de score está, F3 puede sugerir solo los `tenant_private` de la cuenta del técnico. No sugiere `UNCLASSIFIED` ni `PRIVATE` ajenos. No inventes un `GENERAL_APPROVED`.

### Superficie

La sugerencia vive en el chat web autenticado, en la misma respuesta donde el técnico nombró marca o designador. No es un pin. No es un mensaje de manual. No uses `SemanticQueryAnalyzer` para elegir el manual. No subas top-k. No filtres Bedrock por fabricante.

### Telemetría

Agregá a `PilotUsageLog::ALLOWED_FIELDS`, y solo esto: `suggestion_document_uids` y `suggestion_scopes`. El segundo es un array de `tenant_private` o `danebo_general`, en el mismo orden que los uids. Extendé el test de campos desconocidos: una clave fuera de la lista no aparece en la línea `[PILOT_USAGE]`. Evento `manual_suggestion_shown`. No agregues `manual_suggestion_dismissed` ni `knowledge_scope`: eso es F4.

### Cierre de F3

En este orden: tests del ranker y de la elegibilidad; el regression gate de este plan; Execution State; findings; revisión de F4–F8; reescritura completa del prompt de F4 con los hashes reales de `f0_discovery.json` y `f0_discovery_eligible.json`. No ejecutes F4. No hagas deploy. `head_final` no se escribe dentro del árbol.

Commit, un solo commit de F3. El mensaje dice que la sugerencia no escribe un pin.

## Anexo F — prompt de F4

Ejecutá solo F4 de `docs/PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29.md`. F4 es Discovery B, confirmed focus. El técnico toca una tarjeta y eso escribe `user_pin` en la sesión actual. No ejecutes F5. No hagas deploy. No reabras F3 ni F3B2. No cambies el filtro abierto, el post-filter, el score ni `RagRetrievalProfile`. No llames a un modelo. No apruebes documentos. No pidas una decisión a Lahiri.

F3B2 está `PASS`. F4 está `READY`. El padre del trabajo es el commit de F3B2. `git log -1 --format='%s'` tiene que decir que el retrieve abierto se alinea con `knowledge_scope` y que Legacy, Pilot y `manual_corpus` dejan de conceder acceso. `git status` tiene que estar limpio. Si el asunto no es ese, o el árbol está dirty en algo que no sea F4, `STOP`. Anotá `git rev-parse HEAD` como `head_initial` de F4. Este anexo no contiene el SHA de F3B2 ni el de F4.

### Qué dejó F3B2, y F4 no toca

- Sin pin, el corpus es `account_id` del viewer más las URIs canónicas de filas ajenas `danebo_general` (`original_source_uri` y `x-amz-bedrock-kb-source-uri`). Cero generales es solo `account_id`. Legacy, Pilot y `manual_corpus=general` no son cláusulas.
- `partition_evidence` descarta `denied`, `ambiguous` y `unmapped` antes de publicar y antes de un prompt local. Si todas las citas de `retrieve_and_generate` fallan, el texto no se publica. No agregues una segunda llamada al modelo para reescribir esa respuesta.
- Un filtro del caller que amplía niega. Un predicado técnico se intersecta. Un conjunto de URIs se autoriza entero o es `DENY_RETRIEVAL`, sin llamada a Bedrock y sin retry abierto.
- Revocar `danebo_general` saca la fila del siguiente retrieve ajeno. El dueño la conserva. Los pins de otras sesiones no se borran.
- `WarmBedrockKbJob` sigue siendo un ping de Aurora. No lo filtres y no lo conviertas en retrieve de usuario.
- WhatsApp sigue dormido. No lo reactives.
- Recall medido, sin Bedrock: 204 documentos de catálogo, 19 en el índice `1` y 185 en el índice `3`. El viewer `3` retiene 185. Los 19 del índice `1`, incluido SEGURIDADES `b61f5d54-ff42-414a-97b7-01682d16f4b5`, son `backfill_gap`. Artefacto `tmp/field_companion/f3b2_recall.json`, SHA256 `74b467c0b72e7bcfd12118da6adee48038ee3ee3b7de11c590dc438c9f9bc887`. F4 no promueve ese gap. La promoción sigue siendo `knowledge_scope:apply` con `APPLY=true`, un documento, después de `knowledge_scope:audit`.
- Telemetría ya allowlisted por F3B2, y no la saques: `rejected_result_count`, `authorized_general_count`, `retrieval_denied_reason`. `knowledge_scope` todavía no está en la allowlist.

### Qué no cambia

- `BatchChunkingPrompt::MODEL_TEXT` sigue `claude-sonnet-5-5`.
- `BatchChunkingPrompt::MODEL_MULTIMODAL` sigue `claude-opus-5-5`.
- `FieldPhotoAnalysisService::DEFAULT_MODEL` sigue `claude-sonnet-5-5`.
- `FieldPhotoPrompt` no se edita.
- `BatchChunkingPrompt::INGESTION_CONTRACT_VERSION` sigue `field_records_v8`.
- `RagRetrievalProfile` no se toca. No subas top-k. No filtres Bedrock por fabricante.
- `generation.txt` y el renderer de procedencia no se editan.
- El score de `Rag::ManualCandidateRanker` no gana ni pierde puntos por scope. El filtro sigue después del top 3 y no rellena.
- `UNCLASSIFIED` sigue siendo `tenant_private` del dueño. No apruebes ningún documento como `danebo_general`. No agregues una columna. No copies un `KbDocument`. No dupliques S3. No reindexes.
- No uses como aprobación: `manual_corpus=general`, el `account_id` de índice del catálogo, el slug, Legacy, Pilot, el filename ni el fabricante. `GENERAL_APPROVED` sintético tampoco.
- No uses `SemanticQueryAnalyzer` para elegir el manual.
- No hay auto-focus. `tie_at_top` no pinea solo.
- No hay feature flag que restaure el OR histórico.

### Evidencia que F4 lee

Estos dos archivos tienen que existir y coincidir byte a byte. No los reescribas. No recalcules `precision_at_3`, `top1_accuracy` ni `wrong_brand_candidate_rate` para cambiar el score.

- `tmp/field_companion/f0_discovery.json` SHA256 `0119f27bd05a86efe5371008bd1886f9791bf5d427eea1364682adad9b9e5ee0`
- `tmp/field_companion/f0_discovery_eligible.json` SHA256 `47efb001265ee5985fd33cee156054acd81b9fad8736e111ac4291914cbeff36`

El viewer no owner de ese artefacto es la cuenta `5`, slug `elevadores-climb`. En el recall de F3B2 ese viewer retiene 0 de 204. `general_approved_count` de F0 es 0 y F3B2 no sembró `danebo_general`. Esa lista no le entrega documentos del ranking técnico. F0 confirmó `existing_document_id_session_pin` con `reindex_required = false` y `duplicate_document_required = false`. F4 no está `BLOCKED`. La opción `new_chunk_attribute` no se elige. El registro de aprobación es `kb_documents.knowledge_scope`. F4 no lo escribe y no lo manda al chunk.

### Lo que F3 dejó

`Rag::ManualCandidateRanker` rankea sin red. `RagController#ask` adjunta `manual_suggestion` en la misma respuesta JSON cuando hay fabricante reconocido. No está dentro de `answer`. Las tarjetas de `renderManualSuggestion` no son botones y no tienen `data-action`. `selected_document_uid` es nil. `data-selected` es `none`.

Payload:

- `cards`: como máximo 3. Cada una tiene `document_uid`, `display_name`, `label` (`BRAND_ONLY` o `EXACT_DESIGNATOR`), `text` fijo, `knowledge_scope` (`tenant_private` o `danebo_general`) y `provenance`.
- Texto solo marca: `manual de la misma marca; compatibilidad con este equipo no confirmada`.
- Texto designador exacto: `el documento coincide con el modelo/designador indicado`.
- Cero candidatos con fabricante, o más de un fabricante: `No encontré un manual claramente asociado a esa identidad en la biblioteca actual.`
- Procedencia: `Biblioteca general de Danebo` o `Tu biblioteca`.
- `tie_at_top` true cuando dos o más tarjetas devueltas comparten el score máximo. No elige una.
- Síntoma sin fabricante: no hay `manual_suggestion` y no hay retrieve extra.

Telemetría ya allowlisted por F3: `suggestion_document_uids` y `suggestion_scopes`. Evento `manual_suggestion_shown`. F3B2 sumó `rejected_result_count`, `authorized_general_count` y `retrieval_denied_reason`. `knowledge_scope` todavía no está en la allowlist.

### Tap

El técnico toca una tarjeta. El servidor vuelve a correr la elegibilidad. No confíes en el JSON del browser.

- Documento `tenant_private` de la cuenta del técnico: `pin_kb_document!`, `source: "user_pin"`, solo en `active_entities` de la sesión actual. Evento `manual_focus_confirmed`.
- Documento `danebo_general`: el mismo `user_pin` sobre la fila `KbDocument` existente, escrito solo en la sesión actual. No se crea otro `KbDocument`, no se copia S3, no se reindexa, no hay `assisted_focus` y no hay un flag de pin en el documento. La carga permitida es la fila que `Rag::KnowledgeScopePolicy` autoriza para ese viewer, atada por URI canónica y `document_uid` a una sola fila. En producción el conteo de `danebo_general` sigue en 0: el test crea una fila con `knowledge_scope` `danebo_general`. No persistas una marca `GENERAL_APPROVED`.
- `PRIVATE` o `UNCLASSIFIED` de otra cuenta: no hay tap. El ranker no debió mostrarlos. Si el request igual trae ese uid, no pines y no lo busques con `unscoped`.
- `tie_at_top`: una pregunta, máximo 3 chips, cero pins hasta el tap.
- `pin_conflict`: se muestra y el pin anterior sigue.
- `identity_conflict`: se muestran las dos identidades y no se sobreescribe el hecho del técnico.

Prohibido: `unscoped`, `find_by` de un privado ajeno, desactivar autorización, copiar la fila, duplicar el objeto S3, reindexar por tenant, y guardar el pin como estado del `KbDocument` o de cualquier estructura visible para otras cuentas.

### Tests de foco, sin red

- La cuenta A pinea un `danebo_general`. `active_entities` de la cuenta B no cambia. El documento sigue elegible para B.
- La cuenta B pinea otro general, o dos generales, o un general y un privado suyo. Los pins de A siguen iguales.
- A quita su pin. El documento sigue en el catálogo general y en los pins de B.
- Un `PRIVATE` o `UNCLASSIFIED` de otra cuenta no se puede pinear por esta vía.
- `tie_at_top` no escribe un pin hasta el tap.
- `pin_conflict` deja el pin anterior.
- `identity_conflict` no pisa el hecho del técnico.

### Telemetría

`manual_focus_confirmed` con `document_id`, `source_uri`, `correlation_id` y `knowledge_scope` (`tenant_private` o `danebo_general`). `knowledge_scope` se agrega a `PilotUsageLog::ALLOWED_FIELDS` en F4, con el mismo test de clave ajena: una clave fuera de la lista no aparece en la línea `[PILOT_USAGE]`.

`manual_suggestion_dismissed` reusa `document_id` y `outcome`. No agregues esas claves de nuevo.

`equipment_switch_prompted` con `manufacturer` y `outcome_reason`. Si hace falta un segundo fabricante, agregá `previous_manufacturer` a la allowlist y testalo. No agregues claves por si acaso.

### Cierre de F4

En este orden: tests de foco; el regression gate de este plan (no llama Bedrock ni Anthropic); Execution State; findings; revisión de F5–F8; reescritura completa del prompt de F5. No ejecutes F5. No hagas deploy. `head_final` no se escribe dentro del árbol.

El regression gate es:

```
bin/rails test \
  test/services/rag_retrieval_profile_test.rb \
  test/services/rag/structured_evidence_route_test.rb \
  test/services/field_photo_analysis_service_test.rb \
  test/services/field_photo_density_gate_test.rb \
  test/services/image_compression_service_test.rb \
  test/jobs/field_photo_analysis_job_test.rb \
  test/services/pilot_usage_log_test.rb
```

Un solo commit de F4. El mensaje dice que el tap escribe `user_pin` solo en la sesión actual.

## Anexo H — prompt de F5

Ejecutá solo F5 de `docs/PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29.md`. F5 es continuidad de imagen: persistir `visual_observation` en la misma fila `field_photos` y reutilizarla con cero Anthropic cuando la precedencia lo dice. No ejecutes F6. No hagas deploy. No reabras F4. No cambies el tap, `user_pin`, el retrieve abierto, el score, `knowledge_scope` ni `RagRetrievalProfile`. No apruebes documentos. No pidas una decisión a Lahiri.

F4 está `PASS`. F5 está `READY`. El padre del trabajo es el commit de F4. `git log -1 --format='%s'` tiene que decir que el tap escribe `user_pin` solo en la sesión actual. `git status` tiene que estar limpio. Si el asunto no es ese, o el árbol está dirty en algo que no sea F5, `STOP`. Anotá `git rev-parse HEAD` como `head_initial` de F5. Este anexo no contiene el SHA de F4.

### Qué dejó F4, y F5 no toca

- Una tarjeta confirmada escribe `user_pin` solo en la `ConversationSession` web de ese usuario y esa cuenta. El id es la fila. `document_uid` confirma. La policy corre en el tap.
- Con foco válido no hay fallback al corpus abierto. Un miembro inválido sigue en `DENY_RETRIEVAL`.
- `pin_conflict` se muestra y el pin queda. `identity_conflict` muestra las dos identidades. Ese conflicto lo escribe `ConversationSession#apply_photo_fact!` cuando el hecho `manufacturer` o `model` ya es `known` con `source: "user"` y la foto dice otra cosa. F5 no pisa ese hecho y no borra el conflicto.
- `Rag::ActiveEpisode.sanitize_photo` conserva `field_photo_id`, `sha256` y `correlation_id`, y descarta el resto. F5 no copia el JSON de `visual_observation` al episodio y no borra `correlation_id`.
- `apply_photo_observation!` ya puede escribir facts `manufacturer` y `model`. F5 no convierte esos facts en el JSON de la columna.
- `FIELD_COMPANION_EPISODE_ENABLED` sigue apagado por default. F5 no lo enciende.
- El cache de diagnóstico de 24 h sigue ausente. No lo restaures.
- Las fotos no pueden pasar a `danebo_general`.
- `DEICTIC_RE` es `/\b(esa|ese|eso|esta|este|esto|that|this)\s+(placa|foto|imagen|plate|photo)\b/`. F0 lo corrió después de `normalize_label` y estos cuatro salieron `false`: `estos resortes`, `según la foto`, `la imagen que te mandé`, `lo que se ve ahí`. No hay finding `NEW` de ese regex. La precedencia de F5 no se afloja para que `DEICTIC_RE` los cubra.

### Qué no cambia

- `BatchChunkingPrompt::MODEL_TEXT` sigue `claude-sonnet-5-5`.
- `BatchChunkingPrompt::MODEL_MULTIMODAL` sigue `claude-opus-5-5`.
- `FieldPhotoAnalysisService::DEFAULT_MODEL` sigue `claude-sonnet-5-5`.
- `FieldPhotoPrompt` no se edita.
- `BatchChunkingPrompt::INGESTION_CONTRACT_VERSION` sigue `field_records_v8`.
- `RagRetrievalProfile` no se toca. No subas top-k.
- `generation.txt` y el renderer de procedencia no se editan. Eso es F6 y F7.
- No hay voz, galería, tabla de historial de diagnóstico, ni ingesta de la foto a `bulk_chunks/`.
- No hay auto-focus. No hay Mode C.

### Columna

Una migración. `field_photos.visual_observation`, `jsonb`, nullable. Misma fila, mismo `account_id`, mismo borrado que `FieldPhotoRetentionJob` (`photo.destroy!`, default 90 días, `FIELD_PHOTO_RETENTION_DAYS`). Una foto citada por `InspectionFinding` no se purga; la observación se va con la fila el día que la fila se vaya. No hay tabla nueva. No es un diagnostic record.

Allowlist, `schema_version: 1`, JSON `<= 2048` bytes. Fuera de la lista no se persiste:

- `schema_version` (entero)
- `prompt_fingerprint` (64 hex)
- `model_id` (string, máximo 80)
- `canonical_component` (máximo 80)
- `manufacturer` (máximo 80, o `UNKNOWN`)
- `model` (máximo 80, o `UNKNOWN`)
- `subsystem` (el enum del prompt, o `UNKNOWN`)
- `condition` (`GOOD`, `DEGRADED`, `DAMAGED`, `UNKNOWN`)
- `visible_text` (máximo 8 strings, cada uno máximo 80)
- `target_visible` (`true`, `false`, o `null`)
- `relevance_to_goal` (`relevant`, `unrelated`, `uncertain`, o `null`)

Fuera, y por lo tanto no se persisten: `summary`, `aliases`, `documented_functions`, `documented_connections`, `documented_values`, `documented_warnings`, `anti_hallucination_notes`, y la prosa de `build_analysis`.

### Precedencia

La primera que aplica gana. No la aflojes para que `DEICTIC_RE` cubra los positivos.

1. Hay bytes nuevos adjuntos → análisis nuevo.
2. Hay `field_photo_id` y la frase, ya normalizada, cumple `VISUAL_REREAD_RE` → análisis nuevo. La frase de producto es “volvé a mirar” o “revisa otra vez la foto”. El regex, sobre texto ya pasado por `normalize_label`:

```
/\b(?:volve|volver|vuelve|revisa|revisar|mira|mirar|analiza|analizar)\b.{0,40}\b(?:otra vez|de nuevo|nuevamente)\b|\b(?:otra vez|de nuevo)\b.{0,40}\b(?:foto|imagen)\b/
```

3. Hay `field_photo_id` y la pregunta no cumple el regex de releer → se reutiliza `visual_observation`. Cero Anthropic.
4. Texto solo, y la frase cumple `VISUAL_REFERENCE_RE` → se usa únicamente `active_photo` de la sesión. Regex sobre texto normalizado:

```
/\b(?:estos|estas|esos|esas)\s+(?:resortes|cables|bornes|terminales|contactos)\b|\bsegun la foto\b|\bla imagen que te mande\b|\blo que se ve ahi\b|\b(?:la|esa|esta)\s+(?:foto|imagen)\b/
```

5. Referencia visual y no hay `FieldPhoto` de esa cuenta para el `active_photo` → respuesta determinística, cero Anthropic: `No tengo una foto vigente en este caso. Seleccioná la foto anterior o volvé a enviarla.`

Positivos de referencia visual, que el paso 4 tiene que reconocer y que `DEICTIC_RE` no reconoce: `estos resortes`, `según la foto`, `la imagen que te mandé`, `lo que se ve ahí`.

Negativos, que no disparan reuso visual: `según el manual`, `el borne 24`, `fotocélula del embarque`, `mandame el procedimiento`.

La observación inyectada en el paso 3 o 4 es el JSON allowlisted. El retrieve no lo reescribe. Si el manual dice otra cosa, eso lo separa F6. F5 no edita `generation.txt`.

### Telemetría

`photo_observation_reused` y `photo_observation_reread`. Les alcanza `cache_status` (`reused` o `reread`), `image_digest_prefix` y `correlation_id`. Esas claves ya están permitidas o F5 demuestra que ya lo están antes de agregar alguna. Cero claves nuevas si ya alcanzan. Cero broadcast nuevo. No agregues `knowledge_scope` de nuevo: F4 ya lo puso en la allowlist.

### Tests, sin red de modelo

- La columna nace nullable. `photo.destroy!` se lleva la observación. No hace falta una tabla que sobreviva al purge.
- Un JSON fuera de la allowlist, o de más de 2048 bytes, no se persiste.
- `sanitize_photo` sigue guardando `field_photo_id`, `sha256` y `correlation_id`, y sigue sin copiar `visual_observation`.
- Bytes nuevos disparan análisis. No reusan la columna.
- Una frase de releer dispara análisis y `photo_observation_reread`.
- Sin bytes nuevos y sin releer, se reutiliza la columna y `photo_observation_reused`. Cero llamada a Anthropic.
- Texto solo con referencia visual usa `active_photo`. Sin foto de esa cuenta, el mensaje determinístico, cero Anthropic.
- Los cuatro positivos no pasan a `true` en `DEICTIC_RE`. Los cuatro negativos no reusan la observación.
- Reusar la observación no pisa un hecho `manufacturer` que el técnico ya dijo. El conflicto de F4 sigue mostrando las dos identidades.
- Una foto no puede quedar `danebo_general` por esta fase.
- El regression gate de este plan, sin Bedrock ni Anthropic.

### Cierre de F5

En este orden: tests de continuidad; el regression gate; Execution State; findings; revisión de F6–F8; reescritura completa del prompt de F6. No ejecutes F6. No hagas deploy. `head_final` no se escribe dentro del árbol.

El regression gate es:

```
bin/rails test \
  test/services/rag_retrieval_profile_test.rb \
  test/services/rag/structured_evidence_route_test.rb \
  test/services/field_photo_analysis_service_test.rb \
  test/services/field_photo_density_gate_test.rb \
  test/services/image_compression_service_test.rb \
  test/jobs/field_photo_analysis_job_test.rb \
  test/services/pilot_usage_log_test.rb
```

Un solo commit de F5. El mensaje dice que la observación visual vive en la fila de la foto y no se copia al episodio.
