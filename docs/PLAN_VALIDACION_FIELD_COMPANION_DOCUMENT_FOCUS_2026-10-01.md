# Validación independiente — Field Companion / Document Focus

**Fecha:** 2026-10-01

**Plan validado:** `docs/PLAN_FIELD_COMPANION_DOCUMENT_FOCUS_REFACTOR_2026-10-01.md`

**Commit validado:** `e9380cc5cce76ede123571a97534d00a6f824886`

**Alcance:** validación contra el repositorio real; no implementación.

## Verdict

`REQUIRES_PLAN_REVISION`

La separación `Work Context != Document Focus != Document Discovery` es compatible con el repositorio y F1–F7 son implementables con cambios locales. F8, como está escrito, no es ejecutable sin descubrir dos contratos ausentes:

1. `DocumentIdentityCatalog` no expresa si un designator canónico es `controller`, `model` u otro componente. Por lo tanto, lógica determinista no puede persistir correctamente `NICE3000` como `controller` sin agregar esa semántica al catálogo o degradarlo a identificador genérico.
2. `Rag::DocumentIdentityScope` está habilitado por defecto en producción y ya transforma evidencia por manufacturer/model después de `Retrieve`. Esto contradice la afirmación absoluta de que sólo autorización/focus son hard constraints y debe resolverse explícitamente antes de F8.

Además, el journey progresivo pierde información técnica antes del cuarto turno, y el retry de F7 necesita semántica explícita de replay para no registrar otra vez el mismo turno. Son ajustes acotados; no requieren otra llamada LLM, otra tabla conversacional ni cambiar la arquitectura RAG.

## Método y evidencia ejecutada

- Se leyó el plan completo en el commit indicado.
- Se inspeccionaron los modelos, servicios, controllers, Stimulus, vistas, configuración de deploy y tests enumerados por el plan.
- Se ejecutaron 13 suites relevantes: `452 runs`, `2605 assertions`, `0 failures`, `0 errors`, `26 skips`.
- Se ejecutó el journey progresivo contra `Rag::ActiveEpisodeTurn` del repo. El cuarto turno compone `Intenta cerrar tres veces y vuelve a abrir\nElemont\nMarca E03`; ya no contiene `puertas no cierran` ni `VF5`.

## Tabla de hallazgos

| Finding | Severity | Evidence | Affected phase | Required action |
|---|---|---|---|---|
| V-01. El catálogo no codifica el tipo semántico de cada designator | BLOCKER | `Rag::DocumentIdentityCatalog::Entry` sólo tiene `brands`, `designators` y `role`; `config/document_identity_catalog.yml` agrupa `NICE3000` y `NICE3000new`, pero no dice `controller` vs `model` | F8, F10 | Agregar al catálogo versionado una clasificación explícita por designator, o especificar que sólo se persiste `identifier` cuando el tipo no está catalogado. `NICE3000` debe quedar declarado como `controller` para cumplir el journey, sin hardcode Ruby ni LLM nuevo. |
| V-02. Ya existe un hard post-filter técnico en producción | MATERIAL GAP | `BedrockRagService#document_identity_scope_result` invoca `Rag::DocumentIdentityScope`; el servicio reemplaza cuerpo procedural cuando metadata no coincide con manufacturer/model. `DOCUMENT_IDENTITY_SCOPE_ENABLED` está en `true` en `config/deploy.yml` | F5, F8, F10 | El plan debe decidir explícitamente si se conserva como transformación de seguridad o se omite para facts de catálogo/focus. Ajustar el enunciado “sólo authorization/focus son hard constraints” y agregar tests con focus forzado + fact técnico corregido. |
| V-03. El journey progresivo pierde síntoma inicial y `VF5` | MATERIAL GAP | `ActiveEpisodeTurn#composed_question` usa goal + identidad + turno; bare `VF5` no se persiste y un turno self-contained reemplaza goal. `SessionContextBuilder` sólo conserva tres turnos de usuario | F8, F10 | Exigir en F8 una ventana técnica request-local, acotada, tomada de `prior_user_turns`, que llegue al `retrieval_query` sin persistir todos los síntomas. El test debe afirmar el string efectivo, no sólo la decisión. |
| V-04. Retry de card no puede ser un submit normal | MATERIAL GAP | `RagController#create` llama `record_user_turn!` antes del query; `rag_chat_controller#sendMessage` agrega burbuja y hace un POST nuevo. Repetir el texto duplicaría historial y puede reclasificar el episodio | F7, F10 | Añadir flag/correlation de replay. El servidor debe consultar con la última pregunta ya registrada y el focus persistido, sin volver a registrar el turno ni crear intención falsa. |
| V-05. F2 omite lectores web de `active_entities` | LOCAL ADJUSTMENT | Además de los listados: `QueryOrchestratorService#entity_sources`, `RagController#focused_kb_document_ids`, `Rag::DocumentOverviewResponder`, `Rag::FocusNotice`, `FieldPhotoAnalysisService#pinned_manual_available?` | F2, F5, F9 | Incorporarlos al inventario de migración. Mantener fuera los readers/writers exclusivos de WhatsApp. |
| V-06. La procedencia `catalog` no sobrevive la serialización actual | LOCAL ADJUSTMENT | `Rag::ActiveEpisode::SOURCES` admite sólo `user` y `photo`; el parser descarta otra fuente | F8 | Agregar `catalog` al schema/versionado del episodio y enseñar esa procedencia a `SessionContextBuilder` y consumidores. No marcar como dicho por el técnico lo inferido del catálogo. |
| V-07. `clarify_first` todavía atravesaría discovery y resolución | LOCAL ADJUSTMENT | `RagQueryConcern` puede evitar el orquestador, pero `RagController#create` continúa con resolución, suggestion y response assembly | F8 | Incluir `RagController` en F8: salida determinista con `model_invoked=false`, sin `Retrieve`, discovery ni evidence selector. |
| V-08. `search_and_clarify` necesita separar respuesta citada y pregunta determinista | LOCAL ADJUSTMENT | La respuesta JSON y las citas se arman en `RagController`; `pending_question` existe como metadata, pero el texto visible del follow-up debe quedar en el historial | F8 | Añadir la pregunta después del answer como campo/presentación separada, conservar las citas ligadas al answer, y registrar el mensaje visible combinado una sola vez. No usar una segunda inferencia. |
| V-09. El unique prefix propuesto es ambiguo para `nice300` | MATERIAL GAP | El YAML contiene `NICE3000` y `NICE3000new`; `KbDocumentResolver` no hace prefix porque valida límite de palabra | F8, F10 | Resolver prefijo sobre valores canónicos, no sobre documento. Exigir unicidad del valor canónico, mínimo conservador y token con dígitos. `nice300` debe aclarar, no asumir `NICE3000`. |
| V-10. Corrección puede dejar el designator viejo en la query | MATERIAL GAP | La limpieza actual de `ActiveEpisodeTurn` elimina manufacturers de la lista estática, no designators de catálogo ni controller/model anteriores | F8, F10 | La corrección debe invalidar el fact viejo y el compositor debe excluirlo. Test exacto: contiene `NICE1000`, no contiene `NICE3000`, y focus no cambia. |
| V-11. Auto-pin tardío necesita conservar ownership temporal | MATERIAL GAP | `BedrockIngestionJob#auto_pin_document` usa `expected_episode_id`; el enqueue captura el episodio. Quitar ese guard permite que un upload viejo altere el focus de otro trabajo. La UI vuelve a habilitar send mientras indexa | F2, F3, F10 | Mantener `expected_episode_id` como guard del upload que originó la operación, aunque episode/correction no puedan modificar focus. Bloquear/reconciliar send mientras el upload propio espera indexación y refrescar badge/checks antes del siguiente ask. |
| V-12. G2 puede tener dos fuentes de verdad durante rolling deploy/rollback | MATERIAL GAP | F2 propone que nuevo código escriba sólo `document_focus`; imagen F1 escribe/lee `active_entities`. Kamal puede solapar instancias y el plan no prueba un corte atómico | F2–F4, G2 | Elegir y documentar una de dos medidas: deploy sin overlap, o dual-write temporal sólo para pin/unpin/upload durante G2, manteniendo `document_focus` como read source del código nuevo. No ejecutar `down` durante coexistencia. |
| V-13. El exact-scope debe cubrir todos los routes directos, no sólo R&G principal | LOCAL ADJUSTMENT | `DocumentOverviewResponder`, `StructuredEvidenceRoute`, `AmbiguousModelResponder`, `ContextEvidenceRoute`, `BedrockRagService#fallback_retrieve`, document-identity retrieve y evidence selector pueden recuperar fuera del método principal; la mayoría reutiliza URIs, pero el evidence selector no fuerza scope | F5, F6 | Centralizar la aserción `badge N => exactly N authorized URIs` y pasar `force_entity_filter: true` en cualquier retrieve que produzca evidencia para un turno con focus. Discovery debe quedar explícitamente separado y nunca citarse. |
| V-14. La matriz de top-k del plan es incompleta; el estado productivo del reranker no es demostrable | LOCAL ADJUSTMENT | `RagRetrievalProfile`: open 8, pinned 3, exhaustive 15, pero también safety 5, photo 10, structured 12 y schematic-open 20. `BedrockRagService` base 10. El reranker depende de env/account config | F5, F8 | Corregir la evidencia factual y marcar el valor productivo efectivo como `UNVERIFIED`; no cambiar top-k ni habilitar reranker en este plan. |
| V-15. F10 deja sin automatizar regresiones peligrosas | MATERIAL GAP | El plan delega pin race y retry principalmente al smoke; no exige assertions del effective query progresivo, replay, mixed unauthorized set ni upload tardío | F3, F5, F7, F8, F10 | Agregar sólo los tests materiales enumerados en “Tests requeridos” abajo. |

## Corrección de afirmaciones factuales del plan

### Confirmadas

- `ConversationSession` mezcla actualmente episodio y pins dentro de `active_entities`; new episode, correction, expiry, invalid state y `start_new_case!` pueden reescribir o vaciar ese hash.
- `ActiveEpisode` persiste manufacturer/model/fault_code y statuses `known`, `unknown_confirmed`, `absent_confirmed`; no existe `controller`.
- `ActiveEpisodeTurn` arma `composed` y `RagQueryConcern` lo toma como `effective_question` antes del orquestador.
- `RagQueryConcern#resolve_pinned_scope` puede estrechar N documentos a uno antes de `resolve_retrieval_scope`.
- `PinnedDocumentsController` autoriza owner o `danebo_general`; `KnowledgeScopePolicy` deniega el conjunto completo si una URI no es autorizable. Un set denegado no cae a corpus abierto.
- `BedrockRagService` usa una sola string en `retrieval_query.text`; con focus forzado construye filtros exactos por URI y los combina con account authorization.
- `FollowupQueryRewriter` sólo cubre un shape corto y no debe reescribir una query ya compuesta.
- La UI actual hace pin/unpin optimista, muta el textarea, no serializa pending requests y oculta el badge cuando es cero.
- `ManualCandidateRanker` depende hoy de `ActiveEpisodeTurn::MANUFACTURERS`; Monarch no cruza esa puerta.
- `KbDocumentResolver` hace candidate `ILIKE` pero luego exige word boundary; `nice300` no resuelve `NICE3000`.
- El route especial de bornes puede hacer un segundo `Retrieve`; no hay multi-query fusion global.

### Corregidas o no verificables

- El plan dice que no se conoce el valor productivo de `HAIKU_QUERY_ANALYSIS_MODE`; `config/deploy.yml` sí fija `conditional`. Aun así, el gate exige episode/pending/photo y el primer turno vacío no llama Haiku.
- `SemanticQueryAnalyzer` usa Haiku 4.5 global, `max_tokens=300`, valida literal spans por substring normalizado y no canoniza. Su schema actual no contiene roles técnicos suficientes para suplir el catálogo.
- El default de `BedrockRagService` es HYBRID con `number_of_results=10`; los valores 8/3/15 vienen de perfiles, no del default único.
- Que HYBRID combine efectivamente lexical + vector en la cuenta desplegada es `UNVERIFIED` desde el repo: el código solicita `HYBRID`, pero el comportamiento administrado y account-level `rag_config` no se pueden probar aquí.
- El reranker de código está off por defecto y `.env` lo deja false, pero el valor productivo efectivo es `UNVERIFIED` porque puede venir de entorno/config de cuenta. No hay evidencia para afirmar que está activo.
- Sí existe un path que filtra evidencia por entidad técnica: `Rag::DocumentIdentityScope`. No es metadata AND en el request de Bedrock, pero sí un hard post-filter de chunks antes de generación.

## F1–F10

### F1

**VERDICT: executable**

**Evidence:**

- `ConversationSession#record_user_turn!`, `#case_boundary_changes`, `#ensure_case_for_photo_submission!`, `#start_new_case!`, `#pins_after_expiry`, `#corrected_case_active_entities`.
- Los writers indirectos web encontrados son pin/unpin y auto-pin de upload. `EntityExtractorService` pertenece al job de WhatsApp.

**Material gap:** ninguno.

**Required plan adjustment:** ninguno. Al retirar `active_entities` de los cambios de boundary se conserva la transición del episodio, `current_procedure` y los facts. Los tests deben afirmar por separado cambio de episodio y estabilidad de focus.

### F2

**VERDICT: executable_with_adjustment**

**Evidence:**

- `ConversationSession::MAX_ENTITIES=10`, `PinnedDocumentsController`, `SessionContextBuilder`, `HomeController#pinned_uris_for_current_session`, `BedrockIngestionJob#auto_pin_document`.
- Lectores adicionales: `QueryOrchestratorService#entity_sources`, `RagController#focused_kb_document_ids`, `Rag::DocumentOverviewResponder`, `Rag::FocusNotice`, `FieldPhotoAnalysisService#pinned_manual_available?`.

**Material gap:** V-11 y V-12.

**Required plan adjustment:** definir parser/normalizador de `document_focus` con schema canónico, máximo 10, dedupe por `kb_document_id`, y tolerancia a legacy/malformed JSON. Backfill sólo de `source=user_pin` con id válido, dentro de la migración transaccional. Migrar todos los readers web anteriores. Mantener el guard `expected_episode_id` del upload. Definir compatibilidad de rolling deploy.

La columna aditiva `jsonb NOT NULL DEFAULT []` es compatible con la imagen F1. La sesión sigue siendo account-scoped y la destrucción de la fila a 30 días termina el workspace completo, como declara el plan. No se debe confiar en URI/display name aportado por cliente; controller y backfill deben derivarlos de `KbDocument` autorizado.

### F3

**VERDICT: executable_with_adjustment**

**Evidence:**

- `rag_chat_controller.js#toggleDocSelection` hace optimistic update y fetch sin cola; `#sendMessage` no espera pin/unpin; `_updateTextareaWithDocName` contamina la pregunta.
- `PinnedDocumentsController` ya usa lock en el modelo para mutations, pero no existe un protocolo de orden en el browser.

**Material gap:** la cola puede quedar en estado rechazado o enviar después de rollback si no se define su contrato; el upload background también puede cambiar focus mientras send está habilitado.

**Required plan adjustment:** una cola serial por mutations, disabled state por card, recuperación de errores mediante refresh autoritativo, y `sendMessage` esperando cola + upload pendiente antes de agregar la burbuja o limpiar el textarea. Agregar test JS/system si existe harness; si no, al menos una prueba unitaria extraíble del coordinador de cola. El smoke manual no es suficiente para la regresión central.

### F4

**VERDICT: executable**

**Evidence:**

- El único `sourcesBadge` está en `home/_chat_box.html.erb` y se oculta en cero.
- El layout desktop renderiza `_documents_summary_box`, que no muestra contador.
- Las filas ya derivan check desde la misma colección `pinned_uris`.

**Material gap:** ninguno.

**Required plan adjustment:** ninguno. Renderizar `0` permanentemente en mobile y desktop desde el mismo focus y reconciliar tras respuestas de mutation/refresh.

### F5

**VERDICT: executable_with_adjustment**

**Evidence:**

- `RagQueryConcern#resolve_pinned_scope` es el N→1 actual.
- `BedrockRagService#authorization_result`, `#entity_s3_uris`, `#combined_filter`, `#document_pin_filter` y `KnowledgeScopePolicy#authorize_uri_set` soportan exactamente N URIs autorizadas.
- Routes alternativos listados en V-13.

**Material gap:** V-02. Aun quitando N→1, `DocumentIdentityScope` puede volver a descartar cuerpo procedural dentro de esos N por manufacturer/model.

**Required plan adjustment:** retirar N→1 y hacer que todos los routes que producen evidencia hereden el mismo set exacto. Definir explícitamente el contrato de `DocumentIdentityScope`. Mantener R1A: si cualquier URI del focus no está autorizada, devolver deny y nunca fallback abierto.

Resultado comprobable requerido:

- badge 0: account filter actual (`tenant_private` propio + shared/general permitido);
- badge N: exactamente N URIs de `document_focus`, todas autorizadas;
- set mixto con una URI no autorizada: deny, cero llamada Bedrock;
- discovery: datos auxiliares/card, nunca evidencia/citation hasta aceptar.

### F6

**VERDICT: executable_with_adjustment**

**Evidence:**

- `ManualCandidateRanker` ya autoriza candidatos con `KnowledgeScopePolicy`, pero usa `MAX_CARDS=3` y una puerta de manufacturer estática.
- `RagController#attach_manual_suggestion` puede adjuntar card sin convertirla en cita.
- `BedrockRagService#retrieve_chunks` permite direct Retrieve con account scope, sujeto a authorization.

**Material gap:** ninguno si discovery se mantiene fuera del payload de evidencia.

**Required plan adjustment:** máximo 2; con badge 0 usar sólo documentos efectivamente citados/autorizados por la respuesta principal. Con badge N y abstention, direct Retrieve por corpus autorizado, excluir focus, autorizar/deduplicar hits, y usar sólo identidad/metadata para card. No pasar chunks de discovery a generation/citations. Corregir `ManualCandidateRanker` para usar catálogo, no ampliar la constante.

### F7

**VERDICT: executable_with_adjustment**

**Evidence:**

- `PinnedDocumentsController` sólo implementa add/remove; `rag_chat_controller#confirmManualSuggestion` no refresca checks/badge y no tiene replay.
- `RagController#create` registra el turno antes de consultar.

**Material gap:** V-04.

**Required plan adjustment:** `mode=expand|replace` debe autorizar primero y mutar en una sola transacción/lock. Después del success, refrescar documentos y badge antes del retry. Implementar retry como replay explícito sin duplicar user history, sin episode boundary y usando el focus ya persistido. Si la mutation falla, no hacer retry.

### F8

**VERDICT: blocked**

**Evidence:**

- V-01, V-02, V-03, V-06–V-10.
- `SemanticQueryAnalyzer` es una llamada condicional pre-retrieval; no corre en first turn vacío y sólo devuelve relation/mentions/refers/ambiguous.
- `ActiveEpisode` no tiene `controller` ni source `catalog`; `PendingQuestion` no tiene ese type.
- `ActiveEpisodeTurn` reconoce un conjunto angosto de “no sé” y no conserva bare designators como `VF5`.

**Material gap:** F8 no puede asignar identidad canónica al slot correcto con el catálogo actual; tampoco preserva el journey progresivo ni declara la interacción con el post-filter técnico existente.

**Required plan adjustment:** revisar F8 antes de empezar F1, con cambios mínimos:

1. Enriquecer el YAML/API del catálogo con tipo por designator. Sin tipo confirmado, persistir sólo identificador request-local, no inventar `controller` o `model`.
2. Extender `ActiveEpisode::FACT_KEYS`, `PENDING_SUBJECTS`, statuses y sources con `controller`/`catalog`. Incluir `ActiveEpisode` y `RagController` en la lista de archivos de F8.
3. Hacer normalización exacta primero; prefix sólo si un único valor canónico coincide, con longitud mínima conservadora y presencia de dígitos para designators. `nice300` es ambiguous por `NICE3000`/`NICE3000new`.
4. Componer determinísticamente una ventana técnica acotada desde prior turns para preservar problema inicial, `VF5`, observación y `E03` en la query relevante, sin persistir todos los síntomas.
5. Definir el comportamiento de `DocumentIdentityScope` frente a facts de catálogo, corrections y focus.
6. Implementar las cuatro decisiones sin nueva inferencia y con control flow del controller descrito abajo.

### F9

**VERDICT: executable_with_adjustment**

**Evidence:**

- Los métodos de release quedan muertos tras F1/F2; `active_entities` sigue siendo necesario para el canal WhatsApp dormido.
- Los docs de arquitectura aún declaran ownership de pins por case.

**Material gap:** depende de cerrar la revisión F8 y del inventario completo de readers de F2.

**Required plan adjustment:** no borrar columna ni API de `active_entities`; limitar cleanup al web y actualizar docs sólo después de verificar que no quedan readers web. Documentar `DocumentIdentityScope` con su contrato real.

### F10

**VERDICT: executable_with_adjustment**

**Evidence:**

- Existen suites maduras para episode, controller concern, orchestrator, Bedrock scope, policy, ranker, catalog-adjacent behavior, ingestion y system notices.
- Los journeys propuestos cubren producto, pero varias assertions actuales son sólo de decisión.

**Material gap:** V-15.

**Required plan adjustment:** agregar los tests materiales listados abajo. No se requiere cobertura exhaustiva ni browser suite completa.

## Document Focus: writers, backfill y lifecycle

### F1: independencia del episodio

Es posible impedir que new episode, correction, expiry, invalid state, photo y `start_new_case!` modifiquen focus sin romper continuidad. Esos paths calculan hoy un nuevo `active_entities` dentro del mismo update; eliminar sólo ese atributo deja intactos episode id, facts, goal, current procedure y decisiones.

Los únicos writers legítimos del futuro `document_focus` deben ser:

- pin/unpin explícito;
- accept expand/change;
- auto-pin de upload propio, todavía ligado al `expected_episode_id` que originó el upload.

Una foto puede cambiar Work Context cuando aporta nueva evidencia, pero no focus.

### F2: columna y backfill

La migración es factible y transaccional en PostgreSQL. Debe:

- crear `document_focus jsonb NOT NULL DEFAULT '[]'`;
- backfill por lotes lógicos dentro de la migración desde pins `source=user_pin` con `kb_document_id` válido;
- limitar/deduplicar a `MAX_ENTITIES`;
- derivar URI/display name del `KbDocument` autorizado, no del request;
- omitir legacy sin id resoluble y contar/registrar el total omitido;
- tratar arrays/hashes malformed como focus vacío, no explotar en request;
- conservar el scope account/session existente.

No hay razón para migrar los facts del episodio ni los readers del WhatsApp dormido.

## Retrieval scope y tenant isolation

El repositorio sí soporta el contrato principal:

- `KnowledgeScopePolicy` resuelve cada URI dentro de owner/shared/general y deniega el set completo ante unknown, ambiguous o unauthorized.
- `BedrockRagService` vuelve a autorizar antes de R&G y antes de direct Retrieve.
- `combined_filter` hace `AND(account_filter, document_pin_filter)`; `document_pin_filter` usa equals/in sobre las URIs exactas.
- Un set forzado denegado no abre fallback.

R1A puede permanecer intacto. Lo que debe evitar F5 es que routes posteriores vuelvan a decidir scope. La aserción no debe ser sólo sobre `RagQueryConcern`: debe verificar el filtro final enviado por cada route productivo.

`tenant_private`, owner y `danebo_general` siguen expresados en `KnowledgeScopePolicy` y `BedrockRagService#account_filter`. El corpus abierto legacy admite documentos propios y compartidos/general según metadata; no debe reinterpretarse en F5.

Discovery es una consulta auxiliar fuera del focus. Su resultado puede producir hasta dos cards autorizadas, pero no puede entrar a answer/citations ni a SessionContext hasta que el usuario acepte.

## Technical Understanding y las cuatro decisiones

No se necesita otra llamada LLM. La llamada Haiku existente puede enriquecer cuando pasa el gate; exact catalog, prefix seguro, pending/status, composition y decisión pueden ser deterministas.

### `ready`

Continúa al retrieve con el `retrieval_query` compuesto. No persiste la decisión.

### `search_and_clarify`

Continúa al retrieve una vez, genera respuesta grounded, conserva citas sólo para esa respuesta y añade como máximo una pregunta determinista después. La pregunta no entra en el retrieve actual.

Implementación compatible con el flujo actual:

- `RagQueryConcern` entrega `effective_question` al orquestador;
- `RagController` recibe `answer`, `citations` y una estructura separada de follow-up;
- la UI renderiza answer/citations y luego follow-up;
- `record_assistant_result!` conserva el texto visible una sola vez más `pending_question` estructurado.

### `best_effort`

Cuando la respuesta al dato pendiente es “no sé”, “no puedo verlo”, “no aparece”, “no tengo acceso” o “busca con eso”, se marca el slot pendiente y el mismo turno continúa al retrieve. La decisión no se persiste.

La interpretación debe depender del slot:

- identity/controller/model/manufacturer pendiente: `unknown_confirmed`;
- fault_code pendiente y “no aparece”: `absent_confirmed`;
- una evidencia posterior exacta de usuario/foto/catálogo reemplaza el status por `known`.

No debe aplicarse el parser globalmente fuera de un pending slot, para no confundir “no aparece el ascensor” con ausencia de código.

### `clarify_first`

Debe terminar antes de instanciar/callar `QueryOrchestratorService` y antes de `attach_manual_suggestion`, evidence selector o discovery. Devuelve respuesta determinista, pending estructurado y telemetría `model_invoked=false`. No crea `BedrockQuery` ni métricas falsas de R&G.

## “No sé” y anti-loop

El mecanismo actual es localmente extensible, pero la afirmación del plan es más amplia que el parser real:

- `PendingQuestion` sólo parsea formas muy específicas.
- `ActiveEpisodeTurn` reconoce principalmente `no sé/no sabemos/no tengo` y algunos patrones de placa.
- `unknown_confirmed` ya puede ser reemplazado por un fact `known`; el path de foto tiene una excepción explícita para reemplazar unknown manufacturer/model.

F8 debe extender la misma regla a controller y a evidencia posterior de catálogo/foto. El anti-loop se logra consultando status + pending subject, no persistiendo `best_effort`. El test obligatorio es:

1. pending controller;
2. técnico: “No puedo verlo. Busca con eso.”;
3. retrieve ejecutado, controller `unknown_confirmed`, no se vuelve a preguntar;
4. turno posterior con foto/texto catalogable;
5. controller pasa a `known`, sin cambiar focus.

## Progressive troubleshooting

El journey solicitado no está soportado completamente por el estado actual:

```text
Elemont, puertas no cierran
→ Es VF5
→ Intenta cerrar tres veces y vuelve a abrir
→ Marca E03
```

Cómo funciona hoy:

- primer turno: goal “puertas no cierran”, manufacturer Elemont;
- `Es VF5`: puede entrar en `composed`, pero bare `VF5` no cumple la regla que persiste identifiers;
- observación self-contained: reemplaza goal por “Intenta cerrar tres veces…”;
- `Marca E03`: compone goal nuevo + Elemont + turno; el problema inicial y VF5 ya no están;
- el history context sólo guarda tres user turns, por lo que el primero también cae en el cuarto turno.

Esto es un gap material. El cambio mínimo compatible es seleccionar determinísticamente, para la request actual, una ventana acotada de observaciones/designators previos literales y combinarla con facts/status/goal. No se propone persistir todos los síntomas ni crear otra tabla. Debe haber límites de bytes/tokens y exclusión de valores corregidos/negados.

## String exacta de retrieval

El camino actual es:

```text
params[:question]
→ ActiveEpisodeTurn#composed (si presente)
→ FollowupQueryRewriter (sólo si no hubo composed)
→ RagQueryConcern @query
→ QueryOrchestratorService @query
→ BedrockRagService#query question
→ retrieval_query.text
```

Después de F8 debe quedar:

```text
raw user turn
→ deterministic technical composer
   (literal facts + catalog canonical identity + bounded prior observation)
→ effective_question/retrieval_query
→ orchestrator sin segunda reescritura
→ retrieval_query.text exacto
```

Guardas necesarias:

- `FollowupQueryRewriter` sólo si el compositor no produjo query;
- excluir pending question/follow-up de la query del mismo turno;
- dedupe de tokens/lines;
- corrección elimina el valor viejo y negado;
- fault codes se preservan literalmente;
- límite explícito, sin truncar primero los fault codes/designators;
- goal no puede reinyectar identidad corregida.

## Hybrid retrieval y soft signals

Estado comprobado desde el repo:

- código solicita `HYBRID` por defecto;
- base `number_of_results=10`;
- perfiles relevantes incluyen open 8, pinned 3, exhaustive 15, safety 5, photo 10, structured 12 y schematic open 20;
- Cohere reranker sólo corre si flag + perfil `exhaustive`; default de código es false;
- existen direct Retrieve en structured route, context route, ambiguous model, document identity scope, fallback y evidence selector;
- bornes puede hacer rescue Retrieve adicional;
- filters admiten account + exact URI set.

Estado `UNVERIFIED`:

- valor efectivo productivo de account `rag_config`;
- flag efectivo productivo del reranker;
- comportamiento interno administrado lexical/vector más allá de que la API reciba `HYBRID`.

Manufacturer/model/controller/code/symptom no deben convertirse en metadata AND en F8. Sin embargo, el repo ya usa manufacturer/model como hard post-filter en `DocumentIdentityScope` y `ContextChunkFilter` filtra chunks en un route específico de corpus abierto. El plan debe reconocer esos paths y decidirlos, no declarar que no existen.

## Typo normalization

La propuesta es viable sólo con estas guardas mínimas:

1. normalización Unicode/case/punctuation consistente con catálogo;
2. exact canonical/alias primero;
3. prefix sobre valores canónicos, no sobre cantidad de documentos;
4. mínimo conservador; para designators, token con dígitos y longitud normalizada suficiente;
5. cualquier colisión de valores => clarify.

Casos obligatorios:

- `NICE3000` exacto => canonical;
- `nice300` => ambiguous entre `NICE3000` y `NICE3000new`, por tanto clarify;
- `NICE3000n` sólo puede completar si el único valor canónico coincidente y el umbral se cumplen;
- token corto (`ni`, `nic`, `vf`) nunca se expande por prefijo.

No se necesita fuzzy engine ni mapa Ruby.

## Correction after assumption

La relation `correct` existe y puede reemplazar facts. El riesgo está en la composición: la limpieza actual conoce manufacturers estáticos, no designators del catálogo. F8 debe:

- sobrescribir controller/model/identifier anterior con el canonical nuevo;
- limpiar pending del slot corregido;
- no conservar `NICE3000` en goal, bounded prior observation ni composed;
- conservar `document_focus` intacto.

Test requerido: “tomando NICE300 como NICE3000” → “No, era NICE1000”; la query efectiva contiene sólo `NICE1000` entre esos valores.

## Discovery y retry

F6/F7 son compatibles con el repo con una separación estricta:

- badge 0: las cards salen de documentos citados/autorizados del answer principal;
- badge N y abstention: direct Retrieve autorizado fuera del focus, hasta dos cards, cero citations;
- accept expand/change: mutation atómica, luego UI refresh;
- retry: replay explícito del último turno ya persistido.

El replay necesita un marcador porque un submit normal duplica historial y puede abrir/corregir episodio. Debe ser idempotente, referenciar el turno original y rechazar replay si la mutation de focus no quedó confirmada. No debe copiar conversation history dos veces ni crear un mensaje de usuario duplicado en UI.

## Upload auto-pin

El upload pertenece inequívocamente a account/session y el enqueue captura `expected_episode_id`. Ese id no significa que el episodio sea dueño del focus; funciona como ownership temporal de una operación async iniciada dentro de un trabajo. Debe conservarse.

Riesgos actuales:

- un job tardío sin guard podría seleccionar un documento en otro trabajo;
- el broadcast `indexed` refresca documentos, pero el técnico puede enviar texto mientras el upload sigue procesándose;
- el server puede haber agregado focus antes de que badge/checks se hayan reconciliado.

Por eso F2/F3 deben conservar el guard y coordinar pending upload con send. Si el upload falla, liberar el bloqueo y mostrar el error; no dejar una promesa colgada.

## G1–G5 y rollback

### G1

Deploy reversible y observable. F1 no cambia schema. El smoke de checks + corrección prueba el incidente real.

### G2

La columna aditiva permite que la imagen F1 conviva con schema nuevo. Lo no resuelto es la convivencia de writers/readers durante rolling deploy. Antes de G2 el plan debe definir deploy sin overlap o dual-write temporal de mutations.

Rollback seguro:

1. volver primero a una imagen que sólo lea `active_entities`;
2. dejar la columna sobrante durante estabilización;
3. ejecutar `down` sólo como cleanup posterior, nunca mientras pueda vivir código que lea/escriba `document_focus`.

El texto actual mezcla revert funcional con drop de columna. El drop no es necesario para volver a G1 y pierde pins nuevos.

### G3

Reversible por código. El smoke debe verificar filtro final/telemetría de URI count, no sólo calidad visual de respuesta.

### G4

Reversible si discovery y retry no persisten estado adicional fuera de focus. El replay marker debe ser backward-compatible/ignorable.

### G5

Reversible una vez que F8 tenga schema de episodio backward-compatible. Agregar keys JSON es compatible si parsers viejos ignoran unknown keys; pero source `catalog` debe probarse explícitamente. F9 no debe borrar APIs requeridas por la imagen G4 o WhatsApp.

Todos los smokes son observables sin logs, pero G3 necesita además una señal en la respuesta/telemetría existente que permita comprobar el número de URIs efectivas. Ver checks/badge no prueba por sí solo el filtro enviado a Bedrock.

## Tests requeridos antes de ejecutar G5

Faltantes materialmente peligrosos, no cobertura exhaustiva:

1. **Writer ownership:** episode boundary, correction, expiry, invalid state, photo y start-new-case nunca escriben `document_focus`; pin/unpin/accept/upload sí.
2. **Pin race:** orden pin→ask, unpin→ask, fallo HTTP con rollback/reconcile y cola no envenenada.
3. **Exact N scope:** N URIs visibles llegan como exactamente N a R&G y direct routes; un set mixto no autorizado hace deny sin llamada Bedrock.
4. **No-sé anti-loop:** controller unknown, best-effort retrieve, no repregunta, evidencia posterior reemplaza unknown.
5. **Four decisions:** search-and-clarify hace un retrieve y pregunta posterior; clarify-first hace cero retrieve/discovery; best-effort no se persiste.
6. **Correction:** query efectiva incluye canonical nuevo y excluye el viejo; focus idéntico.
7. **Progressive turn:** al llegar E03 la query efectiva conserva el problema/designator/observación relevante dentro del cap.
8. **Retry after card:** focus persistido, pregunta consultada una vez adicional, cero user turn duplicado, cero episode boundary.
9. **Upload tardío:** job del episodio anterior no agrega focus al nuevo; upload vigente bloquea/reconcilia el siguiente ask.
10. **Catalog prefix/type:** exact, unique-safe prefix, collision NICE3000/NICE3000new y slot controller explícito.
11. **DocumentIdentityScope:** comportamiento acordado con focus forzado, fact de catálogo y correction.

## Gaps materiales que deben resolverse antes de ejecutar

1. Definir tipo semántico de designators en `DocumentIdentityCatalog` y procedencia `catalog` en episodio.
2. Decidir/documentar `DocumentIdentityScope` frente al principio “technical info is soft signal”.
3. Especificar la ventana técnica acotada que preserva el journey progresivo.
4. Definir replay idempotente de F7 sin duplicar turno/historial/episodio.
5. Conservar ownership temporal del upload y coordinar upload pendiente con send.
6. Definir compatibilidad de G2 durante rolling deploy y rollback sin drop inmediato.
7. Añadir las regresiones materiales de F10 enumeradas arriba.

## Local adjustments absorbibles en phase handoff

- Completar inventario de readers web de `active_entities`.
- Incluir `ActiveEpisode` y `RagController` en F8.
- Separar answer citado de follow-up determinista.
- Gatear `clarify_first` antes de discovery/resolution.
- Hacer prefix conservador y ambiguo para `nice300`.
- Forzar exact scope en evidence selector/direct routes.
- Corregir la matriz factual de top-k y marcar runtime values como `UNVERIFIED`.
- Reducir cards a dos y refrescar checks/badge antes de replay.
- Mantener `expected_episode_id` para ownership del upload, no como ownership permanente del focus.

## Follow-ups fuera del plan actual

- Medir en producción calidad/latencia de la única string HYBRID una vez cerrados los journeys.
- Auditar si `DocumentIdentityScope` sigue aportando valor después de disponer de facts catalogados y corrections deterministas.
- Agregar un harness browser más amplio si el coordinador JS no puede probarse de forma aislada.

No son requisitos de este plan: multi-query retrieval, reranking universal, re-embedding, re-chunking, agentic retrieval, vector DB nuevo, graph RAG, diagnóstico bayesiano, nuevas tablas conversacionales ni otra llamada LLM.

## Final execution instruction

`Update plan before F1.`

La revisión puede ser acotada a los siete gaps materiales anteriores. Una vez incorporados al plan y a sus phase handoffs, Grok puede empezar F1 hoy.
