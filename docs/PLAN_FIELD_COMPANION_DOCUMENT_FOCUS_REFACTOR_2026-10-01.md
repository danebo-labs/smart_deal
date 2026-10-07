# Field Companion — Document Focus refactor (2026-10-01)

**Ejecución vigente (2026-10-07):** [PLAN_FIELD_COMPANION_CONVERSACION_2026-10-07.md](PLAN_FIELD_COMPANION_CONVERSACION_2026-10-07.md). G1–G4 quedan hechos. G5, F9 y F10 no son la cola del companion. El pin de sesión se conserva (FC-D17).

**Estado:** G1 PASS — G2 PASS — G3 PASS — G4 PASS — F6 HECHA — F7 HECHA — F8 HECHA

**Validación:** contrastado con el repositorio. Los hallazgos materiales de esa revisión quedaron incorporados aquí. No hay un segundo documento vivo del focus.

**Implementación:** G1, G2, G3 y G4 PASS en producción (2026-10-01). F6, F7 y F8 cerradas. F8 se fumó en la imagen `afdb1cf`. F8.1 corrige la ventana de retrieve después de ese smoke. G5 no está PASS. El handoff de F8 y F8.1 está en la sección 13.

**Canal:** web autenticado. WhatsApp sigue dormido.

**No reabre:** R1A (`CLOSED — PASS`).

Este texto, después de la consolidación, es el baseline del focus. Cada fase se ejecuta contra el repo, los commits ya hechos y los hallazgos de las fases anteriores. Si el repo contradice una premisa, se actualiza este archivo. No se abre un plan paralelo de focus.

La evolución post-F8 de `SemanticQueryAnalyzer` hacia `TurnInterpreter` vive en [PLAN_TURN_INTERPRETER_2026-10-01.md](PLAN_TURN_INTERPRETER_2026-10-01.md). Este archivo no absorbe esas fases. F9 y F10 siguen siendo el cierre de G5.

---

## Cómo ejecutar este plan

Un chat nuevo tiene que poder implementar F1 y llegar a F10 con este archivo y el repo. No hace falta la conversación que lo consolidó ni un informe de auditoría aparte.

### Invariantes que no se reabren

```text
Work Context  ≠  Document Focus  ≠  Document Discovery
retrieval query  ≠  retrieval scope
```

Se mantienen:

- Document Focus explícito. El badge es el focus. No hay pins ocultos.
- Ni un episodio nuevo, ni una corrección, ni un expiry, ni un estado inválido sueltan o cambian el focus.
- `search_and_clarify` es el comportamiento normal. `best_effort` existe. `clarify_first` es excepcional.
- El acompañamiento es progresivo: se ayuda con lo que hay y se afina con el turno siguiente.
- El catálogo versionado es la autoridad de identidad. No se adivina controlador ni modelo.
- No hay tabla conversacional nueva, ni multi-hilo, ni multi-query, ni reranking universal, ni re-embedding.
- No hay una llamada LLM nueva. Como máximo sigue existiendo la llamada pre-retrieval Haiku que el gate actual ya justifica.
- Primero la lógica determinista. `RetrieveAndGenerate` sigue siendo la generación grounded.

### Dos niveles de validación

Cada fase y cada compuerta separan estas dos cosas.

**Validación automática de ingeniería.** La hace quien implementa, sin pedirla a Lahiri. Puede usar tests, Rails console, scripts, rake, aserciones de base, logs, telemetría, llamadas de API, correlation ids, estado interno, diff y `git diff --check`. El reporte de la fase dice el comando y el resultado.

**Validación humana de producto.** La hace Lahiri como técnico, en la web. Sólo tiene que abrir Danebo, marcar o desmarcar un manual, escribir, mandar una foto si el journey lo pide, leer la respuesta y mirar badge, checks, cards y citas. Puede contestar en el chat. No se le pide mirar la base, la consola, logs, JSON, la red, un correlation id, un episode id, el interior del caso, APIs, flags ni variables de entorno. Si algo sólo se puede ver por dentro, lo verifica la validación automática.

La persona responde `PASS` o `FAIL: hizo X`.

### Handoff de cada fase

F1–F10 son un plan evolutivo. Al terminar cada fase, antes de empezar la siguiente:

1. Correr los tests de esa fase.
2. Revisar lo que el código real mostró.
3. Registrar los gaps o contradicciones encontrados.
4. Anotar la decisión técnica tomada.
5. Explicar por qué esa decisión conserva el contrato de producto.
6. Revisar todas las fases siguientes.
7. Modificar en este archivo las fases futuras que hayan quedado desactualizadas.
8. Modificar también los tests y los smokes futuros afectados.
9. Si ya existe un prompt para la fase siguiente, actualizarlo.
10. Hacer commit de la fase.

La fase siguiente se ejecuta contra el repo actual, los commits ya hechos, los hallazgos anteriores y este plan ya actualizado. No contra los supuestos originales si el repo los desmintió.

Un ajuste local se resuelve y se sigue. Se registra así:

```text
Gap encontrado:
...

Decisión tomada:
...

Razón:
...

Impacto sobre siguientes fases:
...
```

Se puede resolver sin parar cuando el ajuste no cambia el comportamiento visible, no cambia el ownership de Work Context ni de Document Focus, no debilita el aislamiento de tenant, no agrega una llamada LLM, no crea persistencia importante, no cambia el scope de retrieval, no agrega costo o latencia material y no amplía el proyecto.

Hay que parar y pedir una decisión humana sólo si el hallazgo cambia de forma material:

- la UX que el técnico ve;
- Document Focus;
- el ownership de Work Context;
- autorización o aislamiento de tenant;
- el retrieval scope;
- la persistencia fundamental;
- el número de llamadas LLM;
- el costo o la latencia de manera significativa;
- la seguridad;
- una compuerta completa;
- o invalida una fase futura.

No se para por un nombre de método, una clase distinta, un helper que falta, un schema local ajustable, un fixture, un test que hay que mover o un refactor pequeño.

### Reporte al cerrar cada fase

```text
## Fase
F# — nombre

## Commit
SHA

## Qué cambió
máximo 5 puntos

## Tests
comandos + resultado

## Gaps encontrados
los reales, o None.

## Decisiones tomadas
sólo las no triviales

## Impacto sobre fases siguientes
qué se actualizó en este plan

## Estado
PHASE COMPLETE — CONTINUE
```

o `GATE READY FOR HUMAN SMOKE` cuando esa fase cierra la compuerta, o `BLOCKED — MATERIAL PRODUCT DECISION REQUIRED`.

### Compuertas

Hay cinco compuertas. Son el único stop humano rutinario. Las fases de una misma compuerta se implementan y se commitean una por una, sin smoke entre ellas. Al cerrar la compuerta se despliega sólo ese corte y se entrega un único smoke humano.

| Compuerta | Fases | Deploy | Si falla |
|---|---|---|---|
| G1 | F1 | sola | Revertir ese deploy. No se despliega G2 |
| G2 | F2 + F3 + F4 | juntas | Revertir ese deploy. G1 sigue pasando |
| G3 | F5 | propio | Revertir ese deploy. G1 y G2 siguen |
| G4 | F6 + F7 | juntas | Revertir ese deploy |
| G5 | F8 + F9 + F10 | juntas | Revertir ese deploy |

No se agrega una sexta compuerta. No hay feature flag nuevo. Un flag escondido volvería a crear un comportamiento que la pantalla no explica.

Preferencia de cada compuerta:

```text
tests automáticos → deploy pequeño → smoke humano observable → PASS → compuerta siguiente
```

El objetivo es una versión estable para demos y pilotos. Cada decisión prefiere el cambio mínimo, un contrato explícito, un test y un smoke observable. No se toca, en este plan, embeddings, chunking, vector store, tablas conversacionales nuevas, multi-query, retrieval agéntico, reranking universal, llamadas LLM nuevas, multi-hilo ni WhatsApp.

### Cómo volver a un estado desde la pantalla

Para dejar el badge en `0`: abrir Archivos (en el teléfono, la pestaña Archivos; en pantalla ancha, el panel de documentos) y desmarcar todos los documentos. Recargar. El número tiene que decir `0`.

No hay en la UI un botón de trabajo nuevo ni de borrar la conversación. Los smokes no piden eso. Cada paso sigue desde lo que la pantalla muestra después del paso anterior. Un caso que sólo se puede preparar con estado interno va a tests automáticos, no al smoke.

Para repetir un smoke de selección: desmarcar todo, volver a marcar los manuales que el paso nombra, y escribir otra vez la pregunta.

### Smoke humano

Al cerrar G1–G5 se entrega sólo esto, con el título `VALIDACIÓN EN PRODUCCIÓN`. Preparación, qué tocar, qué escribir, qué debería verse, qué es PASS y qué es FAIL. Preguntas de técnico. La pregunta de cada smoke es si esto se siente como un técnico trabajando con Danebo. Los textos están en la sección Production smoke. No se mezclan con correlation ids ni con el estado del episodio.

---

## 1. Diagnóstico

Danebo mezcla en un solo lugar el problema del técnico, los manuales que él ve seleccionados y la continuidad de la conversación. Ese lugar es `conversation_sessions.active_entities`, y el episodio lo escribe.

Eso produjo el incidente de producción. El técnico tenía Elemont y VF5 seleccionados. Dijo que no era Elemont, que era KONE. El episodio pasó a KONE. El pin Elemont se soltó porque el nombre contenía Elemont y no KONE. VF5 no contenía ninguna de las dos palabras y quedó. El retrieve siguió filtrado sólo por VF5. VF5 es Fermator. La respuesta habló de Fermator. El técnico no había pedido soltar Elemont ni quedarse sólo con VF5.

El segundo fallo es de identidad. `config/document_identities.yml` ya tiene el manual Monarch, confirmado, con designators `NICE3000` y `NICE3000new`. El ranker de sugerencias sólo arranca si el texto contiene una marca de `ActiveEpisodeTurn::MANUFACTURERS`. Monarch no está en esa lista. El técnico escribe el controlador que ve y Danebo no lo conecta con el archivo que ya está en la biblioteca.

El tercer fallo es de comprensión. Con badge `0` el corpus puede ser el correcto y la query seguir siendo la frase cruda, o una concatenación que se olvida del síntoma anterior. Scope abierto no es lo mismo que query genérica.

Lo que se conserva:

- El episodio como memoria del trabajo: fabricante, modelo, código, objetivo, foto, conflictos, follow-up.
- `expected_episode_id` como guarda de una operación async. No significa que el episodio sea dueño del focus.
- El piso de historial del episodio.
- R1A: corpus autorizado, `KnowledgeScopePolicy`, un pin que no es un permiso de lectura.
- La sugerencia que no selecciona sola.
- El retrieve con selección no reabre el corpus en silencio cuando no encuentra nada. Cambia quién decide ampliar la selección.

---

## 2. Evidencia del repo que este plan usa

### Quién escribe la selección hoy

| Writer | Dónde | Qué hace |
|---|---|---|
| Click de pin | `PinnedDocumentsController#create` → `ConversationSession#pin_kb_document!` | Alta o refresco de un `user_pin` |
| Click de sugerencia | El mismo `create`, con `document_uid` | Igual |
| Unpin | `destroy` → `unpin_kb_document!` | Borra la entrada de esta sesión |
| Upload indexado | `BedrockIngestionJob` → `pin_kb_document_if_episode_owner!` | Selecciona sólo si `expected_episode_id` sigue siendo el episodio vivo |
| Turno de usuario | `record_user_turn!` mezcla `case_boundary_changes` en el mismo `UPDATE` | Puede vaciar o filtrar pins |
| Foto sin episodio usable | `ensure_case_for_photo_submission!` | Estado inválido vacía pins; expirado recorta por `added_at` |
| Caso nuevo explícito | `start_new_case!` | Vacía pins. No tiene ruta de UI |
| WhatsApp | `SendWhatsappReplyJob` → `EntityExtractorService` | El web no llama a ese servicio |

`case_boundary_changes` en `app/models/conversation_session.rb` vaciaba o filtraba `active_entities` en episodio nuevo, expirado, estado inválido y corrección de fabricante. Elemont caía en la corrección. VF5 no. F1 cortó esos writes. La tabla queda como diagnóstico del incidente.

### Lectores web de `active_entities` que F2 tiene que mover

Además de `SessionContextBuilder`, `HomeController#pinned_uris_for_current_session` y el concern de retrieval:

- `QueryOrchestratorService#entity_sources`
- `RagController#focused_kb_document_ids`
- `Rag::DocumentOverviewResponder`
- `Rag::FocusNotice`
- `FieldPhotoAnalysisService#pinned_manual_available?`

No se migran writers ni readers que sólo usa WhatsApp.

### Carrera con la pregunta

`rag_chat_controller.js#toggleDocSelection` marca el check enseguida y dispara POST o DELETE sin esperar para poder enviar. `sendMessage` no espera ese fetch. `/rag/ask` lee la sesión del servidor. El DOM no viaja en el body. Pinchar y enviar antes de que el POST termine muestra seleccionado en pantalla y busca sin ese manual.

El toggle además escribe el nombre del manual en el textarea. `selection_gate?` trata esa frase como “acabas de seleccionar” y no llama al modelo.

### Scope de retrieval hoy

`resolve_retrieval_scope`: cero URIs → abierto; una o más → filtro forzado por esas URIs. Antes, `resolve_pinned_scope` puede dejar una sola URI si hay un único ganador entre varios pins. Un badge de 2 puede consultar 1.

`KnowledgeScopePolicy` autoriza el conjunto entero. Una URI desconocida, ambigua o no autorizada deniega el conjunto. Un conjunto denegado no cae al corpus abierto y no llama a Bedrock.

### Catálogo

`Rag::DocumentIdentityCatalog::Entry` tiene `brands`, `designators` y `role`. El parser hace `Array(row["designators"]).map(&:to_s)`. Un designator es un string. No hay campo que diga si `NICE3000` es controller, model o family.

`DocumentIdentityCatalog.consensus` devuelve la clave `"model"` para un designator que coincide. Eso no es el tipo semántico. `ActiveEpisodeTurn#catalog_identity_for` llama a `consensus`. Persistir esa clave como modelo sería adivinar.

La fila Monarch en `config/document_identities.yml` está `confirmed: true`, brands `MONARCH`, designators `NICE3000` y `NICE3000new`, `role: component`, `evidence_text: Suzhou MONARCH Control Technology Co., Ltd.` El `role: component` no se usa como tipo. El tipo lo declara F8 en el YAML.

`nice300` no es un prefijo único: es prefijo de `NICE3000` y de `NICE3000new`. `KbDocumentResolver` hace `ILIKE` y después exige límite de palabra, así que hoy `nice300` tampoco matchea `NICE3000`.

### Episodio

`ActiveEpisode::FACT_KEYS` es `manufacturer`, `model`, `fault_code`. No hay `controller`.

`ActiveEpisode::SOURCES` es `user` y `photo`. Otra fuente se descarta al parsear. El episodio sigue en `v: 1`. Una clave o una fuente desconocida se ignora; no invalida el episodio. No se sube `v` en este plan: una imagen anterior tiene que seguir pudiendo leer el JSON.

`composed` lo arma Ruby con goal, manufacturer, model y el turno, con tope `FollowupQueryRewriter::MAX_COMPOSED_CHARS` (442). Un turno posterior reemplaza el goal. Un designator suelto como `VF5` no queda como hecho. Por eso esta conversación, al llegar al cuarto turno, ya no lleva el síntoma inicial ni `VF5` en la query:

```text
Tengo un elevador Elemont, las puertas no cierran.
→ Es VF5.
→ Intenta cerrar y vuelve a abrir.
→ Marca E03.
```

Esa observación es lo que el técnico escribió. No es un procedimiento documentado de VF5 y el plan no la trata como tal.

`SessionContextBuilder` conserva pocos turnos de usuario. La query no puede depender de que el historial de prompt alcance para el cuarto turno.

### Llamada LLM que ya existe

`Rag::SemanticQueryAnalyzer`. Modelo `global.anthropic.claude-haiku-4-5-20251001-v1:0`, temperature 0, `max_tokens` 300. Tool `semantic_perception`. Devuelve relación (`continue`, `answer_pending`, `correct`, `switch`, `new`, `unclear`) y menciones literales. Un span que no está en el turno se descarta. No canoniza marcas y no arma la query.

`config/deploy.yml` fija `HAIKU_QUERY_ANALYSIS_MODE: conditional`. Aun así, `gated?` exige episodio, dato pendiente o foto activa. El primer mensaje de un chat vacío no llama a Haiku. `shadow` observa y no escribe. `off` no llama. F8 tiene que cumplir `NICE3000 E51` con el flag en `off`.

No se agrega otra inferencia antes del retrieve. Si durante la implementación una solución necesita una inferencia nueva, es un cambio material de diseño y se para. No se introduce sola.

### Qué restringe la evidencia hoy

No es cierto que autorización y focus sean los únicos recortes de toda la evidencia.

**Corpus del retrieve.** `KnowledgeScopePolicy` y, cuando hay pins, el filtro de URIs. Eso decide qué documentos pueden entrar al retrieve principal.

**Después del retrieve.** `Rag::DocumentIdentityScope` está prendido en producción: `DOCUMENT_IDENTITY_SCOPE_ENABLED: "true"` en `config/deploy.yml`. Si el episodio tiene manufacturer o model `known`, compara esas palabras con `canonical_name`, `original_filename` y `section_identity` del chunk. El chunk que no coincide pierde el cuerpo procedural y queda como referencia de identidad. No agrega documentos y no cambia el filtro de Bedrock. Sí puede dejar una respuesta sin procedimiento aunque el retrieve haya traído el manual seleccionado. Un focus Elemont con trabajo KONE cae en ese caso si no se acota.

`ContextChunkFilter` existe en una ruta concreta de corpus abierto y descarta chunks según el texto de la pregunta. No es un hard constraint del corpus. Este plan no lo reescribe. Si esa ruta produce evidencia de la respuesta, tiene que haber pedido el mismo conjunto de URIs que el focus.

### Top-k y reranker, sin cambiarlos

`RagRetrievalProfile`:

| Situación | `number_of_results` |
|---|---|
| Abierto, pregunta normal | 8 |
| Documento pineado, pregunta normal | 3 |
| Exhaustiva (candidatos) | 15 |
| Exhaustiva después de rerank, si el reranker corre | 12 |
| Safety-critical con pin | 5 |
| Sólo fotos | 10 |
| Mapping estructurado | 12 |
| Abierto y esquemático (`MAX_RESULTS`) | 20 |

`BedrockRagService` usa 10 cuando no recibe un perfil. El código pide `search_type: HYBRID`. El `rag_config` de la cuenta y `BEDROCK_RAG_SEARCH_TYPE` pueden cambiar el tipo efectivo. Que la cuenta desplegada combine de hecho léxico y vector es `UNVERIFIED`.

El reranker Cohere sólo arma config si `BEDROCK_RERANKER_ENABLED` es `true`, y el perfil exhaustive es el que pide recortar a 12. El default del código, con la variable ausente, no lo prende. `config/deploy.yml` no setea esa variable. El valor efectivo de producción queda `UNVERIFIED` porque no se auditó la config de cuenta ni un entorno fuera de este archivo. Este plan no lo prende y no cambia ningún top-k.

### Deploy real

`config/deploy.yml` tiene un solo host web y un solo worker, los dos en `54.163.248.39`, detrás de kamal-proxy. `bin/docker-entrypoint` corre `./bin/rails db:prepare` cuando arranca el server web, antes de servir.

Un `kamal deploy` normal levanta el contenedor nuevo al lado del viejo, espera salud, cambia el proxy y drena el viejo. Aunque sea un solo host, durante ese rato las dos imágenes pueden escribir. El worker es otro contenedor: un worker viejo puede auto-pinear después de que el web nuevo ya hizo el backfill.

No hay flota multi-host. El corte controlado cabe en una pausa corta de tráfico. No hace falta dual-write.

---

## 3. Contrato de producto

El técnico no tiene que entender sesiones, episodios, scopes ni flags.

**Work Context** es lo que conviene recordar para el próximo turno: fabricante, modelo, controlador, código de falla, objetivo, foto. Un síntoma, una observación y la query de este retrieve no se guardan como lista creciente. Cambian cuando el técnico habla, cuando manda una foto, o cuando el catálogo confirma una identidad a partir de un designator que él dijo. No modifican Document Focus.

**Document Focus** es exactamente los documentos con check. Cero no significa búsqueda sin contexto: el técnico no impuso un manual y el scope es el KB autorizado. Uno: sólo ese. N: sólo esos N. Pin y unpin son clicks. Subir un archivo propio puede dejarlo seleccionado cuando termina de indexarse, porque él lo mandó, y el check tiene que verse antes de la siguiente pregunta.

**Document Discovery** ofrece manuales. Con focus `0`, los hits del retrieve principal son evidencia y después pueden ofrecerse para quedar seleccionados. Con focus `N`, un manual de afuera se ofrece y no se cita hasta que el técnico acepta. Si acepta, el check aparece, el número cambia, y Danebo vuelve a consultar la misma pregunta ya escrita, con el focus nuevo, sin una segunda burbuja del técnico.

**Technical understanding** es de este turno. Separa identidad y problema. Las dos alimentan el trabajo sólo cuando el dato sirve al turno siguiente. Ninguna escribe el focus. No es un formulario. `NICE3000 E51` no pregunta la marca si el catálogo resuelve Monarch. “Tengo un elevador Elemont, las puertas no cierran” ya se busca.

### Decisiones de este turno

Se evalúan en Ruby, después del catálogo. No las decide el modelo. No se persisten.

- **ready.** Hay señal suficiente y otra pregunta no cambiaría de forma material esta respuesta. `NICE3000 E51, ¿qué reviso?` es ready cuando el catálogo cierra esa identidad y el código ya está. Flujo: comprensión, catálogo, retrieve. El scope no cambia.
- **search_and_clarify.** Es el caso normal. La consulta ya se puede buscar y un dato más afinará el turno siguiente. “Elemont, las puertas no cierran”, “No nivela”, “La puerta cierra y vuelve a abrir”, “K1 no entra”, “Me muestra E51” no se bloquean. Flujo: un retrieve, respuesta grounded con citas, y después como máximo un discriminator. Faltar fabricante, modelo o controlador no basta para `clarify_first`.
- **best_effort.** El técnico dijo que no sabe, que no puede verlo, que no aparece, que no tiene acceso, o que busquemos con eso. No se bloquea, no se repite la misma pregunta, no se inventa identidad, la incertidumbre se dice en una frase, y el focus no se abre ni se cierra.
- **clarify_first.** Excepcional. Casi no hay contenido técnico: sin foto, sin episodio, sin componente, sin parámetro, sin manual seleccionado, sin equipo y sin observación. “¿Cómo ajusto esto?”. Se pregunta qué está mirando. No se llama a `RetrieveAndGenerate`. Un designator de catálogo con tipo, un síntoma concreto o un badge mayor que 0 impiden esta decisión. F8 agrega el identificador técnico corto y ambiguo (`Q2`, `K1`, `X3`, `E03`, `CN5`) cuando el badge es 0 y no hay manufacturer, model ni controller confiables de `user` o `photo`: también es `clarify_first`, con cero retrieve y cero generación.

La pregunta de seguimiento, cuando existe, va en prosa. Si el hueco es `manufacturer`, `model`, `controller` o `fault_code`, se guarda en el `pending_question` que ya existe, ampliado con `controller`. No hay formulario de cuatro campos.

“No sé” y las frases equivalentes marcan el slot pendiente. Identidad pendiente → `unknown_confirmed`. Código pendiente y “no aparece” → `absent_confirmed`. La frase no se interpreta en global: “no aparece el ascensor” no es ausencia de código. Una evidencia posterior exacta de usuario, foto o catálogo pasa ese slot a `known`. El focus no cambia.

### Costo y latencia de LLM

Este plan no aumenta el número normal de inferencias LLM pre-retrieval.

Camino caliente:

```text
contexto y catálogo deterministas
→ SemanticQueryAnalyzer sólo cuando su gate actual corresponde
→ un RetrieveAndGenerate
```

No es: entender con un LLM, reescribir con otro, decidir con otro, rerankear con otro y responder con otro.

- `best_effort`: sin LLM adicional.
- Information gain: determinista.
- Normalización de typos: determinista.
- Replay: no repite Haiku.
- Aclaración: determinista.
- Grounding de catálogo: determinista.

---

## 4. Arquitectura objetivo

### Work Context

- Persistencia: `conversation_sessions.active_episode`. Hechos: `manufacturer`, `model`, `controller`, `fault_code`, `goal`, identificadores de este request cuando hace falta mostrarlos en la query, foto y conflictos.
- No se persisten la lista de síntomas, la query de este turno ni la decisión.
- Writers: turno web, observación de foto, turno del asistente, y el compositor cuando el catálogo confirma un hecho persistible.
- Los writes tardíos de foto y de asistente siguen exigiendo `expected_episode_id`.
- No puede modificar `document_focus`, los checks ni el badge.
- `source` de un hecho: `user`, `photo` o `catalog`. Un hecho `catalog` no se presenta como si el técnico lo hubiera dicho.

### Document Focus

- Persistencia: columna jsonb `conversation_sessions.document_focus`, `NOT NULL DEFAULT '[]'`.
- Cada elemento: `{ kb_document_id, source_uri, display_name, added_at }`. URI y nombre salen del `KbDocument` autorizado, no del request.
- No se copian `aliases` ni `entity_type`. `aliases` ya es columna de `KbDocument`. `entity_type` no es columna: el pin actual lo deriva de la extensión del `s3_key` en `pinned_entity_type`. F2 resuelve alias e imagen/documento desde el `KbDocument`, con esa misma regla. Hoy los leen `SessionContextBuilder`, `DocumentOverviewResponder`, `QueryOrchestratorService#entity_sources`, `FieldPhotoAnalysisService`, `selection_turn?` y `PinnedEntityScopeResolver`.
- Tope: `ConversationSession::MAX_ENTITIES` (default 10). Dedupe por `kb_document_id`.
- JSON malformado se lee como focus vacío. No rompe el request.
- Writers: pin, unpin, aceptar card (ampliar o cambiar), auto-pin del upload de este técnico.
- No lo escriben: `record_user_turn!`, `case_boundary_changes`, expiry, corrección, `start_new_case!`, `ensure_case_for_photo_submission!`, `EntityExtractorService`, `SemanticQueryAnalyzer`, el compositor, ni `DocumentIdentityScope`.
- `active_entities` deja de ser el focus del web. La columna queda para el job de WhatsApp dormido. El web no la lee para retrieval ni para pintar checks.

### Document Discovery

- No se persiste como selección. El payload de la respuesta trae como máximo 2 cards.
- Aceptar entra por Document Focus.
- Con focus `N`, el candidato no entra a citas ni al contexto de generación.
- `clarify_first` no corre discovery.

### Replay

Replay es volver a consultar una pregunta ya registrada, después de una mutación confirmada de Document Focus.

Hoy `RagController#create` llama `record_user_turn!` antes de buscar, y un `sendMessage` agrega burbuja y manda un POST nuevo con un `correlation_id` nuevo (`query:<uuid>`). Aceptar una card no puede hacer eso: duplicaría el mensaje del técnico, el historial y el procesamiento del episodio, y podría abrir o corregir un caso.

Contrato:

- El cliente referencia el `correlation_id` que la respuesta de esa pregunta ya devolvió. El mecanismo se llama `replay_correlation_id` en el POST de `/rag/ask`. No hace falta otra tabla.
- El servidor carga ese turno de usuario de esta sesión. Si no está, responde un error legible y no busca.
- No llama `record_user_turn!`.
- No agrega otra burbuja del técnico.
- No vuelve a interpretar new, correct ni switch.
- No llama `SemanticQueryAnalyzer`. No apareció lenguaje nuevo del técnico.
- No vuelve a ejecutar `record_user_turn!` sobre el episodio ya modificado. No llama a Haiku.
- La query del replay quedó cerrada en F7: se guarda la effective retrieval query del turno y el replay la reutiliza. El detalle está en el handoff de F7.
- Ejecuta retrieval y generación otra vez.
- Agrega una respuesta del asistente. La pregunta del técnico sigue apareciendo una sola vez.
- Idempotente: la misma pareja `correlation_id` original + ids de `document_focus`, comparados ordenados, no llama otra vez a Bedrock ni a Haiku. F7 guarda `focus_ids` en el mensaje del asistente. Sin tabla nueva.
- Si la mutación de focus no quedó confirmada, no hay replay. El servidor rechaza un replay cuyos ids no coinciden con el focus persistido.

### Upload y ownership temporal

`expected_episode_id` se conserva en el auto-pin del upload. No significa que el episodio sea dueño del focus. Significa que esta operación async, empezada dentro de un trabajo, no puede modificar un workspace posterior. El job captura el id al encolar. `pin_kb_document_if_episode_owner!` sólo escribe si ese id sigue siendo el episodio vivo. Un upload tardío de un trabajo anterior no cambia el focus del trabajo actual.

Mientras un upload de este técnico, que debe quedar seleccionado, sigue pendiente:

- La siguiente pregunta no sale como si ese documento ya estuviera en el focus.
- Antes de preguntar, checks y badge coinciden con lo que el servidor ya guardó.
- Si el upload falla, se suelta la espera y la pantalla muestra el fallo. El archivo no queda marcado.
- La guarda de episodio sigue aplicando en el servidor aunque la UI también espere.

### Technical understanding

No es un cuarto almacén. Es el compositor determinista, más la llamada Haiku que ya existe cuando su gate la deja pasar.

Value object de este request. Los nombres pueden variar; el contenido no:

```text
identity:        manufacturer, model, controller, designators, aliases
                 cada valor trae source: user | photo | catalog | episode
problem:         fault_code, symptoms, component, procedure
goal:            texto corto del trabajo
retrieval_query: string que el pipeline manda en retrieval_query.text
missing:         como mucho un discriminator, o ninguno
decision:        ready | search_and_clarify | best_effort | clarify_first
```

`composed` pasa a ser esa `retrieval_query`. `FollowupQueryRewriter` sólo corre si el compositor no produjo query. La string no agrega URIs ni cambia `force_entity_filter`.

### Catálogo versionado: tipo del designator

Forma mínima, compatible con las filas actuales. Un ítem de `designators` puede seguir siendo un string. También puede ser un mapping:

```yaml
designators:
  - value: NICE3000
    type: controller
  - value: NICE3000new
    type: controller
```

Parser:

- String → valor canónico, tipo vacío.
- Mapping → `value` obligatorio. `type` sólo si es `controller`, `model` o `family`. Otro texto, tipo vacío o ausente, se lee como sin tipo.
- `Entry#designators` sigue exponiendo los valores string, para no romper el match por span.
- Un lector nuevo expone el tipo. La persistencia usa ese lector. No usa la clave `"model"` de `consensus` como slot.

Reglas:

- Tipo declarado y una sola identidad confirmada → se puede persistir en ese slot, con `source=catalog`. Si la entrada tiene una sola brand, esa brand puede persistirse como `manufacturer`, también `source=catalog`.
- Sin tipo, o ambiguo → sólo identificador de este request. No se escribe `controller`, `model` ni `manufacturer`.
- Nunca se adivina el tipo. Nunca lo decide un LLM. No hay un mapa en Ruby.
- `role: component` no es un tipo.

Para este journey, F8 declara `NICE3000` y `NICE3000new` como `type: controller` en esa fila Monarch ya confirmada. La evidencia de la fila es el manual Monarch y el texto “Suzhou MONARCH Control Technology Co., Ltd.”. El tipo queda escrito en el YAML; el runtime no lo infiere. El resto de designators del archivo siguen como strings hasta que alguien les ponga tipo con la misma evidencia. F8 no tipea el catálogo entero.

`NICE3000` exacto, con ese tipo, escribe `controller=NICE3000` y `manufacturer=MONARCH`, los dos `source=catalog`, y no escribe `document_focus`.

### Normalización, sin fuzzy

Orden, sobre el catálogo cargado, después de plegar mayúsculas y acentos como ya hace `FollowupQueryRewriter.normalize_label`:

1. Canónico exacto.
2. Alias exacto.
3. Prefijo sólo contra valores canónicos, no contra cantidad de documentos.
4. Longitud normalizada mínima 6.
5. Un designator, para expandirse por prefijo, tiene que incluir al menos un dígito.
6. Una sola coincidencia canónica.
7. El canónico puede ser como máximo 4 caracteres más largo que el token.
8. Cualquier colisión → aclaración. No se elige. No se escribe fabricante ni slot. La query puede llevar el token crudo.

El exacto gana aunque el token también sea prefijo de un canónico más largo. `NICE3000` es exacto de `NICE3000` y también prefijo de `NICE3000new`: gana el exacto.

Tests:

```text
NICE3000   → exacto, controller
nice300    → ambiguo (NICE3000 y NICE3000new) → aclaración
NICE3000n  → puede completar a NICE3000new si es el único y cumple el umbral
ni / nic / vf → nunca se expanden por prefijo
```

No hay motor fuzzy ni mapa hardcodeado.

### Corrección borra la identidad vieja

Caso: Danebo tomó `NICE3000` y el técnico dice “No, era NICE1000.”

La query siguiente contiene `NICE1000` y no contiene `NICE3000`. El focus no cambia.

La corrección limpia el valor viejo de los facts, del pending, de la ventana técnica, del goal si quedó contaminado, y de la query compuesta. El valor nuevo queda como lo dijo el técnico (`source=user`) en el slot que se estaba corrigiendo. No se re-adivina el tipo. Si `NICE1000` no está en el catálogo, no se inventa marca ni se borra el focus.

### Ventana técnica acotada

Request-local. No se persiste. No hay tabla. No hay LLM. Se arma en cada request a partir de:

- el turno actual;
- los facts activos que no fueron negados;
- el goal vigente, si no arrastra un valor corregido;
- como máximo 6 turnos de usuario anteriores;
- designators;
- códigos de falla;
- como máximo 3 observaciones técnicas recientes.

Tope de la string: 442 caracteres, el mismo `MAX_COMPOSED_CHARS`. No se sube.

Precedencia, de lo que se conserva primero a lo que se suelta primero si no entra:

1. Turno actual, ya sin el valor que este mismo turno niega.
2. `fault_code` conocido no negado.
3. Controller, model o designator conocido no negado, en forma canónica si el catálogo lo resolvió.
4. Manufacturer conocido no negado.
5. Hasta 3 observaciones de turnos anteriores, de la más nueva a la más vieja, saltando lo que ya está dicho arriba.
6. Goal, sólo si no contiene un valor negado o corregido.

Dedupe por texto normalizado: si una línea ya está contenida en otra de más precedencia, se omite. Una negación (“no es X”, “no era X”) saca X de facts, pending, goal, ventana y query.

Si hay que recortar: primero el goal, después la observación más vieja, después el manufacturer, después el model. No se recorta primero el código de falla ni el designator del turno actual.

La query de “Marca E03”, después de los cuatro turnos de arriba, tiene que contener `E03`, `VF5`, el problema de puertas que no cierran, la observación de que vuelve a abrir, y `Elemont`. El test afirma esa string en `effective_question` / `retrieval_query`, no sólo la decisión. La frase “tres intentos” no forma parte del fixture y no se trata como comportamiento de VF5.

### `clarify_first` corta antes del retrieve

El corte ocurre antes de instanciar `QueryOrchestratorService`, antes de `Retrieve`, de discovery, del evidence selector y de la sugerencia de manual. La respuesta es una aclaración determinista, con `pending_question`, y telemetría `model_invoked=false`. No se crea `BedrockQuery` ni una métrica de RAG vacía.

Lo que el técnico ve: una pregunta corta, sin fuentes y sin card. El badge no se mueve.

### `search_and_clarify` separa respuesta y pregunta

La respuesta grounded y sus citas son una cosa. La pregunta posterior es otra, determinista.

- No hay una segunda inferencia.
- La pregunta no altera las citas.
- La pregunta no entra en `retrieval_query`.
- Se muestra como parte natural del mismo mensaje, después de la respuesta.
- El historial del asistente la registra una sola vez, junto con el `pending_question` estructurado.

### DocumentIdentityScope

Sigue siendo una transformación posterior al retrieve. No se apaga el flag y no se reescribe el motor.

No puede:

- cambiar Document Focus;
- agregar documentos;
- abrir el corpus;
- reemplazar la selección del técnico.

Comportamiento:

| Situación | Qué hace |
|---|---|
| Focus `0` y hay manufacturer o model `known` con `source=user` o `source=photo` | Se conserva el safeguard actual: un chunk cuya metadata no coincide pierde el cuerpo procedural y queda como referencia de otro equipo |
| Focus `N` | Los chunks cuya URI está en el focus no se vacían. El manual que el técnico seleccionó sigue pudiendo sostener un paso. Un chunk fuera de ese conjunto no se promueve a cita |
| Fact `source=catalog` | No es aguja. Una inferencia de catálogo no destruye recall. Entra en la query y en el trabajo, no en este recorte |
| Fact explícito del técnico | Sí puede ser aguja, y sólo con focus `0` |
| Fact de foto | Igual que el del técnico, sólo con focus `0`. No se agrega un campo nuevo al análisis de foto |
| Corrección | El valor viejo ya no está en el fact, así que no es aguja. El valor nuevo, si es `user` o `photo` y el focus es `0`, sí lo es |
| Controller | No se agrega como aguja. Sigue siendo señal de la query |

El caso de test “manual Elemont en focus, trabajo KONE” mantiene el cuerpo procedural de los chunks de Elemont. El caso de identidad corregida no deja la marca vieja como aguja. Con focus `0`, la marca nueva sí puede seguir recortando chunks de otro equipo.

`ContextChunkFilter` no gana URIs. F5 le pasa el mismo conjunto exacto si esa ruta produce evidencia. No se rediseña su `keep?`.

### Retrieval: corpus duro y señales blandas

Hard constraints de qué documentos entran al retrieve principal:

- autorización / `KnowledgeScopePolicy`;
- Document Focus.

Con badge `0`: el filtro de cuenta actual. Con badge `N`: exactamente esas N URIs, todas autorizadas, `force_entity_filter: true`. Si cualquiera no se puede autorizar: denegación, cero llamadas Bedrock, sin caer al corpus abierto.

Fabricante, modelo, controlador, código, síntoma, alias, typo y foto no se convierten en filtros `andAll` de metadata. Esas señales entran en la string. No se sube el top-k y no se prende el reranker para compensar.

Todo path que produzca evidencia de esa respuesta usa ese mismo conjunto. Incluye el `RetrieveAndGenerate` principal y los retrieves directos de:

- `DocumentOverviewResponder`
- `StructuredEvidenceRoute`
- `AmbiguousModelResponder`
- `ContextEvidenceRoute`
- fallback retrieve
- document-identity retrieve
- evidence selector

La ruta de bornes puede seguir haciendo su segundo `Retrieve` de rescate. Ese segundo retrieve no abre URIs fuera del focus. No se generaliza a multi-query.

Discovery queda aparte. Sus chunks no entran a citas ni a generación hasta que el técnico acepta.

Si el repo permite afirmar el conjunto en un solo lugar sin un refactor grande, F5 centraliza esa aserción y los routes la reciben. No se reescribe el motor.

---

## 5. Matriz de ownership

| State | Source of truth | Writer | Visible |
|---|---|---|---|
| manufacturer, model | `active_episode.facts` | Técnico, foto, o catálogo si el tipo y la brand están declarados | Sólo en la conversación |
| controller | `active_episode.facts.controller` | Catálogo cuando el designator tiene `type: controller`, o el técnico al corregir ese slot | Igual |
| fault_code, goal | episodio | Turno del técnico | La conversación |
| active_photo | episodio | Foto con `expected_episode_id` | La foto |
| Document Focus | `document_focus` | Pin, unpin, aceptar card, auto-pin de upload propio | Checks y badge |
| suggested documents | Payload de esa respuesta | Ranker / discovery | Cards |
| selected count | `document_focus.length` | El mismo writer | El número, siempre, incluido 0 |
| retrieval query | Resultado del turno | Compositor | No |
| decisión | Resultado del turno | Compositor | La pregunta corta, cuando existe |
| unknown al técnico | status del fact | Turno que responde “no sé” o “busca con eso” | Se nota porque Danebo no insiste |
| ventana técnica | Nada. Muere con el request | Compositor | No |

---

## 6. Journeys

El número de cada paso es el badge.

### A — 0 seleccionados, respuesta, ofrecer focus

1. Sin checks. Badge `0`.
2. “¿Qué reviso si no nivela?”
3. Danebo busca en el KB autorizado y responde con fuentes. Badge `0`.
4. Si un manual es claramente el más útil para seguir, ofrece dejarlo seleccionado por su nombre. No queda checkeado.
5. Si el técnico acepta, el check aparece, el badge pasa a `1`, y Danebo vuelve a consultar la misma pregunta sin que el técnico la reescriba.

### B — N seleccionados y un manual extra

1. Badge `2`.
2. “¿Cómo ajusto estos resortes?”
3. La respuesta y las fuentes salen de esos dos.
4. Si afuera hay algo útil, lo ofrece. No es fuente de esa respuesta. El badge sigue `2` hasta el click.

### C — No alcanza, discovery, agregar, replay

1. Badge `1`. El manual seleccionado no trae el dato.
2. Danebo dice que no lo encontró ahí y ofrece otro manual.
3. No rellena el hueco con ese manual en la misma respuesta.
4. Si el técnico acepta: check, badge `2`, y la misma pregunta se consulta de nuevo. La respuesta nueva puede citar el manual agregado. No aparece una segunda burbuja del técnico.

### D — “No es Elemont, es KONE”

1. Badge `2`: Elemont y VF5.
2. “No, no es Elemont. Es KONE.”
3. El trabajo pasa a KONE. Los dos checks siguen. Badge `2`.
4. Puede ofrecer documentación KONE para cambiar o ampliar la selección.
5. Si no toca nada, la siguiente pregunta sigue usando Elemont y VF5.
6. “Cambiar” deja sólo lo que aceptó. “Ampliar” lo suma. El badge cambia cuando el click terminó, y la pregunta se vuelve a consultar.

### E — Monarch / NICE3000 con Elemont seleccionado

1. Badge `1`: Elemont.
2. “Es Monarch / NICE3000.”
3. Elemont sigue. Badge `1`.
4. Danebo reconoce esa identidad por el catálogo, no porque Monarch esté en `MANUFACTURERS`.
5. Ofrece el manual por su nombre visible. Hasta el click, la respuesta no se apoya en ese manual.

### F — Pin y pregunta inmediata

1. Badge `0`.
2. Toca un manual. El check aparece. El textarea no recibe el nombre.
3. El envío no sale hasta que el pin quedó guardado.
4. “¿Dónde está este parámetro?” Badge `1` antes de la respuesta. La respuesta usa ese manual. No aparece el aviso de “seleccionaste ese documento”.

### G — Unpin y pregunta inmediata

1. Badge `1`. Toca el mismo manual. El check se va.
2. El envío espera a que el unpin quede guardado.
3. La pregunta siguiente va con badge `0` y no filtra por ese manual.

### H — Mobile

El mismo pin y unpin en la pestaña Archivos. El número del teléfono y el de desktop son el mismo para la misma sesión, también después de recargar.

### I — Identidad fuerte

1. Badge `0`.
2. “NICE3000 E51, ¿qué reviso?”
3. No pregunta la marca. La query lleva el controlador, el código y el verbo. El scope sigue siendo el KB autorizado.
4. Responde con fuentes o dice que no está. Badge `0`.
5. Si ofrece un manual, es el de NICE3000 / Monarch, sin check hasta el click.

### J — Poca identidad, evidencia útil

1. Badge `0`. “No nivela al llegar al piso.”
2. No inventa un equipo. Busca. Responde con lo que encontró.
3. Puede cerrar con una sola pregunta útil. Esa pregunta no reemplaza la respuesta.

### K — Casi vacío

1. Badge `0`, sin foto, sin equipo y sin parámetro.
2. “¿Cómo ajusto este parámetro?”
3. Danebo pregunta qué parámetro y en qué equipo. No llama al retrieve generativo. No ofrece un manual adivinado. Badge `0`.

### L — La foto ya dio la identidad

1. La foto quedó leída como KONE / LCE. Eso está en el trabajo, no en los checks. Badge `0`.
2. “¿Qué reviso ahora?”
3. No vuelve a pedir marca ni modelo. La query usa lo que la foto ya mostró. El scope sigue global si el badge es `0`.
4. Si Elemont está checkeado, el scope sigue siendo Elemont. Los checks no se mueven. El cuerpo de ese manual no se vacía por el hecho de que el trabajo diga KONE.

### S — Ayuda progresiva

1. Badge `0`.
2. “Tengo un elevador Elemont, las puertas no cierran.”
3. Busca enseguida. La decisión es `search_and_clarify`. No abre con “¿cuál es el modelo y el controlador?”. No inventa controlador. Si la evidencia es general, la respuesta puede ser general.
4. Puede pedir un solo dato después.
5. El técnico sigue: “Es VF5.”, “Intenta cerrar y vuelve a abrir.”, “Marca E03.”
6. La búsqueda del último turno todavía lleva el problema de las puertas, VF5, la observación y E03. La primera respuesta general no es un fallo. Fallo es no haber buscado, inventar el equipo, olvidar el problema, o dar un procedimiento específico sin fuente.

### T — “No sé”

1. Danebo preguntó si ve el controlador.
2. “No sé.”
3. No vuelve a preguntar el controlador en este trabajo.
4. Puede pedir otra cosa de más valor, o seguir con lo que ya hay.

### U — Seguir con lo que hay

1. “No sé el modelo. Busca con eso a ver qué encuentras.”
2. Hay retrieve. No se inventa modelo ni controlador. La incertidumbre cabe en una frase. Badge y checks no cambian. No hay otro “¿y el modelo?” en ese turno.
3. Un dato posterior que el técnico o la foto sí aportan, y que el catálogo puede tipar, pasa ese slot a conocido. El focus no cambia.

### V — Typo y corrección

1. Badge `0`. “monar nice300 e51”.
2. `nice300` es ambiguo entre `NICE3000` y `NICE3000new`. Danebo pregunta cuál es. No dice “estoy tomando NICE300 como NICE3000”. No escribe fabricante. Badge `0`.
3. “NICE3000 E51” sí es exacto y puede decir que está usando NICE3000 / Monarch.
4. Si después el técnico dice “No, era NICE1000.”, la búsqueda siguiente usa NICE1000 y no sigue arrastrando NICE3000. El focus no se toca.

---

## 7. Elección de almacenamiento

Opción A, seguir en `active_entities` y sólo quitar los writes del caso, deja el bug a un `merge!` de distancia.

Opción B, columna `document_focus`, es la elegida. F1 igual se despliega sola sobre el hash actual, para juzgar el incidente antes de la migración. Si G1 falla, no se construye la columna.

Backfill: entradas `source=user_pin` con `kb_document_id` resoluble, dentro de la migración, dedupe, tope 10, URI y nombre tomados del `KbDocument` autorizado. Un pin sin id no se inventa. El smoke de G2 lo ve como no seleccionado.

La fila de sesión sigue siendo de la cuenta. Destruir la sesión a los 30 días se lleva el focus. Al volver, badge `0`. Eso es fin de workspace, visible.

---

## 8. G2: corte controlado, sin dual-write

Estrategia elegida: **corte controlado**. El deploy real es un solo web y un solo worker en el mismo host. Una pausa corta de tráfico evita que la imagen vieja (`active_entities`) y la imagen nueva (`document_focus`) escriban a la vez. No se introduce dual-write.

Lo hace quien despliega, no Lahiri.

1. Ventana en la que nadie está pinchando manuales ni subiendo archivos. No hay un upload a medio indexar.
2. No usar el handoff rolling normal de `kamal deploy` para G2.
3. Parar el tráfico web y parar el worker, para que ni el web viejo ni el worker viejo puedan pin, unpin o auto-pin.
4. Arrancar sólo el web nuevo. `bin/docker-entrypoint` corre `./bin/rails db:prepare` antes de servir. Eso crea `document_focus` y hace el backfill.
5. Confirmar que la migración terminó. Recién entonces arrancar el worker nuevo con esa misma imagen.
6. No levantar el web nuevo y el worker nuevo a la vez antes de que la migración haya terminado.
7. Parar del todo los contenedores viejos.
8. Recién ahí volver a abrir el proxy.
9. Recién ahí el smoke humano de G2.

La columna es aditiva. La imagen de F1 la ignora. Por eso la migración puede existir antes del corte; lo que no puede coexistir son los writers.

Si el día del deploy esa pausa no se puede hacer, se para. Es una decisión material de deploy. No se improvisa dual-write.

### Rollback

1. Volver primero al código anterior, con la misma pausa de tráfico para que no queden las dos imágenes escribiendo.
2. No correr `down` en ese momento.
3. Dejar `document_focus` durante la estabilización.
4. El rollback se ve en los dos sentidos. No es motivo para dual-write.
   - Un pin creado sólo después de G2 vive en `document_focus`. La imagen vieja no lo lee y desaparece de la pantalla. Si se vuelve a desplegar G2, sigue ahí, porque la columna no se borró.
   - Un pin que el técnico quitó después de G2 puede reaparecer. La imagen nueva ya no escribe `active_entities`, así que el estado viejo sigue en esa columna y la imagen vieja lo vuelve a leer.
5. `down` / drop es un cleanup posterior, sólo si de verdad se quiere, y sólo cuando ninguna imagen en ejecución lee o escribe la columna.

G1 no tiene migración. G3, G4 y G5 se revierten por código. G5 no borra APIs que la imagen de G4 o WhatsApp todavía necesiten. Agregar claves al JSON del episodio es compatible porque el parser viejo ignora lo que no conoce; `source=catalog` en una imagen vieja se descarta, no rompe el episodio.

---

## 9. Mapa de archivos

| Archivo | Acción |
|---|---|
| `ConversationSession` | F1 deja de asignar `active_entities` en los boundaries. F2 lee y escribe `document_focus` en el web |
| `ActiveEpisode` / `ActiveEpisodeTurn` | F1 no toca el focus. F8 agrega `controller`, `source=catalog`, la ventana y las cuatro decisiones. `composed` pasa a ser la retrieval query |
| `SessionContextBuilder` | F2 lee el focus. F8 no presenta un hecho de catálogo como dicho por el técnico |
| `RagQueryConcern` | F3 quita el gate del textarea. F5 aplica el conjunto exacto. F8 no llama Bedrock en `clarify_first` |
| `RagController` | F2 mueve `focused_kb_document_ids`. F6 arma cards fuera del focus. F7 implementa el replay. F8 corta `clarify_first` antes de orquestador, discovery y selector |
| `PinnedDocumentsController` | F2 escribe la columna. F7 ampliar/cambiar en una escritura autorizada |
| `QueryOrchestratorService` | F2: `entity_sources` lee el focus. F8: `clarify_first` no lo instancia |
| `DocumentOverviewResponder`, `FocusNotice`, `FieldPhotoAnalysisService` | F2 leen el focus |
| `rag_chat_controller.js` | F3 cola y espera de upload. F4 badge. F7 replay sin segunda burbuja |
| Vistas home | F4 el número en mobile y desktop, incluido 0 |
| `BedrockIngestionJob` | F2 auto-pin a `document_focus`, conservando `expected_episode_id` |
| `SemanticQueryAnalyzer` | F8 puede marcar un síntoma que sea substring. Misma llamada, mismo tope. No es obligatoria |
| `ManualCandidateRanker` | F6 usa el catálogo, no la lista `MANUFACTURERS` |
| `DocumentIdentityCatalog` y `config/document_identities.yml` | F8 tipo por designator, compatible con strings |
| `DocumentIdentityScope` | F5 aplica el contrato de focus N / focus 0. F8 excluye facts `catalog` de las agujas |
| Routes de evidencia listados arriba | F5 reciben el mismo conjunto de URIs |
| `EntityExtractorService`, `SendWhatsappReplyJob` | Intactos |
| `FollowupQueryRewriter` | Sigue para el follow-up corto. No pisa una query ya compuesta |
| `QueryEntities` | Sigue en la sombra. No es el contrato de understanding |

`current_procedure` se sigue limpiando con el boundary. No es focus.

---

## 10. Qué se quita y qué se queda

| Pieza | Decisión |
|---|---|
| Soltar pins en episodio nuevo, corrección, expiry o estado inválido | Quitar en F1 |
| `start_new_case!` vaciando pins | Dejar de vaciar focus en F1. El método puede seguir abriendo episodio. No tiene UI |
| Nombre del manual en el textarea, y el prompt de “seleccionaste ese documento” | Quitar en F3 |
| Estrechamiento N→1 | Quitar en F5 |
| `active_entities` como focus web | Dejar de usarlo en el web en F2. Columna y WhatsApp se quedan |
| `MANUFACTURERS` como puerta del ranker | Dejar de usarla para sugerir en F6 |
| `MANUFACTURERS` como detector del episodio | En F8 queda de respaldo. Las brands del catálogo también cuentan. La constante no crece y no se borra |
| Auto-pin de upload | Migrar a `document_focus`, con la guarda temporal |
| Métodos de release que queden sin caller | Borrar en F9, después de ver que nadie los llama |
| Docs que dicen que el pin es estado del caso | Corregir en F9 |

---

## 11. Discovery

- Badge `0` y la respuesta citó documentos: ofrecer dejar seleccionado el dominante, como máximo 2, sin un segundo `Retrieve`. Si los hits se reparten sin uno dominante, no se ofrece nada.
- Badge `0` y el catálogo reconoce un designator: se puede ofrecer ese manual con el mismo tope.
- Badge `N` y hubo evidencia dentro del focus: card sólo si el candidato no está seleccionado y el match es un designator exacto, o el trabajo contradice los manuales seleccionados. Esas cards no entran a citas.
- Badge `N` y la respuesta se abstiene: un `Retrieve` directo, no `RetrieveAndGenerate`, `top_k` 3, filtro de cuenta, excluyendo las URIs del focus. Los hits se muestran como cards. Sus chunks no entran al prompt ni a las citas.
- `clarify_first`: sin discovery.
- Dedup por `kb_document_id`. Lo ya seleccionado no se ofrece. Nada que no pase `KnowledgeScopePolicy`.
- Cambiar y ampliar son botones distintos. Ninguno corre solo. Cambiar reemplaza el focus en una sola escritura. Ampliar agrega.

El `Retrieve` extra existe sólo en la abstención con focus no vacío.

---

## 12. Aceptación

Cada regla tiene test o un paso del smoke.

1. Badge `0`: el retrieve principal no manda filtro de `source_uri`.
2. Badge `N`: todo path que produzca evidencia de esa respuesta usa exactamente esas N URIs autorizadas.
3. Un conjunto con una URI no autorizada se deniega. Cero llamadas Bedrock.
4. Pin y enviar enseguida incluye el manual nuevo. Unpin y enviar enseguida no lo incluye.
5. Si el pin o el unpin fallan, la pregunta no sale y la pantalla vuelve a coincidir con el servidor.
6. El episodio no escribe `document_focus`.
7. “No, no es Elemont. Es KONE.” no quita ni agrega pins.
8. Un candidato de discovery no está en las citas ni en el contexto de generación cuando el focus es `N`.
9. Aceptar una card actualiza check y badge, y vuelve a consultar la pregunta ya registrada. No hay una segunda burbuja del técnico. No hay otra llamada Haiku.
10. Si aceptar falla, no hay replay.
11. El mismo replay con el mismo focus no llama otra vez a Bedrock.
12. Desktop y mobile muestran `document_focus.length`, incluido 0, también después de reload.
13. `NICE3000` ofrece el manual Monarch sin editar `MANUFACTURERS` ni `BRANDS`.
14. Con varios pins, nombrar uno en la pregunta no reduce el filtro a ese uno.
15. El textarea no cambia al pin ni al unpin.
16. Episodio expirado, inválido o nuevo no cambia el focus.
17. Subir un archivo y esperar el indexado lo deja checkeado antes de la siguiente pregunta. Si falla, se ve el fallo y no queda seleccionado.
18. Un upload terminado de un trabajo anterior no selecciona un documento en el trabajo actual.
19. Un pin de otro tenant `tenant_private` sigue rechazado. `danebo_general` pineado por la cuenta A no aparece seleccionado en la cuenta B.
20. WhatsApp no se cablea al focus web.
21. `NICE3000 E51` busca sin pedir fabricante cuando el catálogo declara ese designator como controller. El badge no cambia. El hecho de catálogo no se dice como si el técnico hubiera nombrado Monarch.
22. La identidad de catálogo no escribe `document_focus` y no es aguja de `DocumentIdentityScope`.
23. Un código de falla entra en la query aunque este turno no lo persista como hecho.
24. “¿Cómo ajusto este parámetro?” en frío es `clarify_first`: hay pregunta y no hay retrieve, discovery ni card. Con un manual seleccionado, esa frase sí busca en ese manual.
25. “No nivela al llegar al piso.” busca y, si falta un dato, hace una sola pregunta después.
26. “Elemont, las puertas no cierran” busca antes de pedir modelo o controlador.
27. “No sé” no repite el mismo slot. “Busca con eso” busca y no inventa el dato. Un dato posterior conocido reemplaza el `unknown_confirmed`.
28. Armar la query no agrega URIs.
29. Con badge `0`, la query puede nombrar Monarch y NICE3000 y el scope sigue sin filtro de documento.
30. Con badge `N`, la query puede nombrar otro equipo y el scope sigue siendo esos N. El manual seleccionado no pierde el cuerpo procedural porque el trabajo diga otra marca.
31. `nice300` pregunta. No se normaliza a `NICE3000`.
32. “No, era NICE1000.” deja la query siguiente con `NICE1000` y sin `NICE3000`. El focus no cambia.
33. Al llegar “Marca E03” en el journey progresivo, la query efectiva todavía lleva el problema de las puertas, VF5, la observación y E03.
34. No hay una segunda llamada Haiku. El replay no la repite. Con el flag en `off`, el compositor cubre el designator de catálogo.
35. Las señales técnicas no se vuelven filtros `andAll`. Un chunk puede ser evidencia aunque no repita todos los hechos.
36. El top-k no cambia. El reranker no se prende.

---

## 13. Fases

Cada fase: tests, `git diff --check`, un commit. Al cerrar la compuerta, deploy del corte y smoke humano. Dentro de la compuerta no hay smoke entre fases.

### F1 — El caso ya no toca los pines

**Compuerta:** G1. Se despliega sola.

**Objetivo.** Corregir el equipo, abrir otro episodio, expirar o invalidar el episodio no cambia los manuales seleccionados.

**Archivos.** `app/models/conversation_session.rb`. Tests de boundary, ownership y los de foto que esperen pins vaciados.

**Cambios.** `case_boundary_changes` puede seguir limpiando `current_procedure`. Deja de asignar `active_entities`. `ensure_case_for_photo_submission!` y `start_new_case!` igual. El episodio nuevo se sigue escribiendo. `expected_episode_id` no se toca.

**Tests.** Corrección Elemont→KONE conserva Elemont y VF5. Episodio nuevo, expiry y estado inválido conservan los pins. El episodio sí cambia cuando el test de episodio lo exige. Foto no suelta la selección.

**Ingeniería.** Esos tests y `git diff --check`. No incluye badge nuevo.

**Humano.** Smoke G1, después del deploy.

**Commit.** `fix: keep document pins when the field case changes`

**Handoff F1.** Hecho. Los boundaries de episodio, la foto y `start_new_case!` siguen escribiendo el episodio y pueden limpiar `current_procedure`. Ya no asignan `active_entities`. Pin, unpin y el auto-pin de upload no se movieron. WhatsApp no se tocó.

```text
Gap encontrado:
La corrección de fabricante ya no tiene boundary. El único motivo del CaseBoundary
en :corrected era soltar pines, así que ese turno ya no emite R1B_CASE_PROBE.
El effective retrieval query no está en conversation_history: el mensaje guarda
el texto crudo y correlation_id. aliases es columna de KbDocument; entity_type
no lo es y hoy sale de la extensión del s3_key.

Decisión tomada:
Se dejaron los helpers de release sin caller para que F9 los borre después de
ver el repo. No se eligió la query del replay ni el lookup de idempotencia.

Razón:
F1 sólo quita el ownership automático de los pines. Esas dos decisiones de F7
cambian el contrato del replay y se cierran cuando exista el código del replay.

Impacto sobre siguientes fases:
F2 no copia aliases ni entity_type. F7 escribe la elección de query y el lookup.
F9 borra los seis helpers y no documenta corrected_manufacturer_mismatch como
vigente. G2 despliega el web, confirma la migración y después levanta el worker.
El rollback de G2 puede ocultar pines nuevos y reaparecer pines quitados.
```

### F2 — Columna `document_focus` y lectores web

**Compuerta:** G2, junto con F3 y F4. No se despliega al cerrar F2.

**Objetivo.** El focus web vive en la columna nueva. El episodio no la escribe. El upload sigue atado a la guarda temporal.

**Archivos.** Migración, `ConversationSession`, `PinnedDocumentsController`, `HomeController`, `SessionContextBuilder`, `BedrockIngestionJob`, lectores de URIs del concern, `QueryOrchestratorService#entity_sources`, `RagController#focused_kb_document_ids`, `Rag::DocumentOverviewResponder`, `Rag::FocusNotice`, `FieldPhotoAnalysisService#pinned_manual_available?`.

**Cambios.** jsonb `document_focus`, default `[]`, null false. Backfill como en la sección 7. Pin, unpin y upload escriben sólo esa columna en el web. Los lectores de arriba leen esa columna y resuelven `aliases` e imagen/documento desde `KbDocument`, como dice la sección 4. El elemento no guarda `aliases` ni `entity_type`. `active_entities` queda para WhatsApp. `expected_episode_id` sigue condicionando el auto-pin. Parser tolerante a JSON malformado.

**Tests.** Backfill, incluidos pins sin id que se omiten. Pin no cambia `active_episode`. La corrección de F1 no cambia la columna. Upload con el episodio vivo escribe `document_focus`. Upload con otro `expected_episode_id` no lo escribe. Cada lector web listado deja de leer `active_entities` para el focus. Un elemento guardado tiene sólo `kb_document_id`, `source_uri`, `display_name` y `added_at`. Un lector que necesita alias o tipo de archivo lo saca del `KbDocument`.

**Ingeniería.** Tests de F2. Confirmar que los readers de WhatsApp no se movieron. No desplegar.

**Commit.** `feat: store document focus apart from the field episode`

**Handoff F2.** G1 PASS. Work Context pasó de Elemont a KONE, los dos manuales siguieron seleccionados, el retrieve usó ambos y el reload conservó la selección.

Gap de G1, no bloquea G2. El focus real era VF5 + Elemont y el retrieve pidió ambos, pero una respuesta visible dijo que VF5 no estaba seleccionado. Es coherencia de Document Focus con el contexto de generación. Se revisa en F5/F8. Si esas fases lo cierran, agregan la regresión. No se adelanta a G2.

Nombres visibles. `WebManualBatch.filename` y `BulkUploadAsset.filename` ya guardan el archivo original. `KbDocument.display_name` sigue siendo la identidad técnica. Mostrar los dos en la lista no entra en G2: haría falta un join de presentación en varios partials y no cambia el contrato del focus. La UI de G2 sigue con `display_name`. El filename original no se borra. Follow-up post-estabilización.

Decisiones. `channel != "whatsapp"` lee y escribe `document_focus`. WhatsApp sigue en `active_entities`, incluido el auto-pin de su job. El backfill es `ConversationSession.document_focus_from_legacy` y la migración lo ejecuta sólo para filas que no son WhatsApp. Copia URI y nombre desde el `KbDocument` autorizado. Omite pins sin id, deduplica por id y se queda con los 10 más nuevos. Aliases y tipo de archivo se resuelven al leer. `expected_episode_id` sigue siendo sólo la guarda del auto-pin. El gate del textarea sigue hasta F3, pero ya compara contra el focus.

F3 y F4 no cambian de contrato. F5 recibe el focus separado del episodio. El estrechamiento N→1 sigue en el camino principal, alimentado por `document_focus_scope_index`, y F5 lo quita.

### F3 — Pin, unpin y upload antes de la pregunta

**Compuerta:** G2.

**Objetivo.** La pregunta sale cuando la selección en pantalla ya coincide con el servidor. El nombre del manual no entra al textarea. Un upload propio pendiente no se adelanta ni se ignora.

**Archivos.** `app/javascript/controllers/rag_chat_controller.js`. `RagQueryConcern` para quitar `selection_gate?`.

**Cambios.** Una cola serial de pin y unpin. `sendMessage` espera esa cola y también el upload propio que debe quedar seleccionado, antes de agregar la burbuja o vaciar el textarea. Si la mutación falla, no se envía la pregunta, el check vuelve al estado del servidor y la cola no queda envenenada. Se borra la escritura del nombre en el textarea y el gate que respondía con el prompt de selección. Si el upload falla, se suelta la espera y se muestra el fallo.

El repo ya tiene system tests con Chrome headless en `test/system`. F3 agrega uno corto: pin y después preguntar usa ese manual; pin fallido no envía. No se arma un stack de browser nuevo. Si ese test no se puede estabilizar por algo ajeno al cambio, el handoff mueve la aserción al contrato de servidor y lo deja escrito. No se borra la aserción.

**Tests.** El concern: una pregunta que es sólo el nombre de un manual seleccionado llama al orquestador. System test corto de la cola, o el sustituto que el handoff justifique. Upload tardío de otro episodio no cambia el focus: eso ya queda cubierto en F2 y se vuelve a correr aquí si F3 toca el cliente del upload.

**Commit.** `fix: apply document pin before the next question`

**Handoff F3.** La cola serial vive en el controlador de chat. Una mutación que falla no corta la siguiente. La pregunta espera sólo las mutaciones que todavía están en curso: un fallo ya terminado no bloquea la pregunta de después. Si el pin falla, el check vuelve al estado anterior y la lista se refresca desde el servidor. El textarea no recibe el nombre del manual, ni en el éxito ni en el fallo, y `params[:question]` tampoco.

`selection_gate?` ya no existe. Una pregunta que es sólo el nombre de un manual seleccionado llama al orquestador con ese texto, sin reescribirla como la consulta anterior. `selection_turn?` sigue para clasificar el turno y para la instrucción `Selection Turn`. No hay una llamada LLM nueva: el resumen determinista de un nombre suelto, si aplica, sigue dentro del orquestador.

El upload de un documento propio abre la espera del ask. Se suelta cuando el cable dice `indexed` o `failed`, y también cuando aparece el aviso de stall que ya existía. Una foto no abre esa espera. No hay un test de browser del cable; el contrato del pin sí está en `test/system/rag_chat_document_focus_test.rb`.

F4 no cambia de contrato: el badge sigue oculto en 0 hasta esa fase. F5 sigue quitando el estrechamiento N→1. El gap de G1 (la respuesta dijo que VF5 no estaba seleccionado) sigue en F5/F8.

### F4 — Badge único

**Compuerta:** G2. Este deploy es el de G2, con el corte controlado de la sección 8.

**Objetivo.** Desktop y mobile muestran siempre el entero, incluido 0, desde el mismo focus.

**Archivos.** `home/_chat_box.html.erb`, el panel desktop, `updateSourcesBadge`, el partial de filas si hace falta un conteo server-rendered.

**Cambios.** El 0 no se oculta. Un solo camino actualiza los dos nodos. Después de un refresh o de una mutación, se recalcula.

**Tests.** HTML de home con 0 pins contiene `0` en mobile y en desktop. Con 2 pins, ambos nodos dicen `2`.

**Ingeniería.** Tests. Después, el corte de G2. No el rolling normal.

**Humano.** Smoke G2.

**Commit.** `feat: show the selected document count on desktop and mobile`

**Handoff F4.** Mobile y desktop muestran el mismo entero, incluido 0. El HTML lo pinta desde `pinned_uris` de la sesión. El JS parte de `data-focus-ids` y sólo corrige los ids que están pintados en la página, así un pin fuera de las primeras 20 filas sigue en el conteo. No oculta el cero. El conteo del system test lee `textContent` porque el tab mobile está oculto en desktop y Selenium no devuelve su texto visible.

Hallazgo al probar el composer. `addMessage` y el indicador de espera usaban `Date.now()` en el mismo milisegundo. `removeMessage` borraba la burbuja del técnico y dejaba los puntos. El id ahora lleva una secuencia. No cambia F5.

F5 sigue quitando el estrechamiento N→1. El gap de G1 sigue en F5/F8. Los dos nombres del documento siguen post-G2.

### F5 — Scope exacto y contrato de DocumentIdentityScope

**Compuerta:** G3. Deploy propio.

**Objetivo.** Cero URIs: abierto. N URIs: esas N, en todo path que produzca evidencia. Sin recorte silencioso N→1. La query no es un filtro. El safeguard posterior no vacía el manual que el técnico eligió.

**Archivos.** `RagQueryConcern`, el resolver que hoy estrecha N→1 (deja de ser llamado por el camino principal), `BedrockRagService` en el punto donde aplica `DocumentIdentityScope`, y los routes de evidencia de la sección 4. Tests de esos routes.

**Cambios.** `resolve_retrieval_scope` lee `document_focus` y no el texto de la pregunta. Se quita el estrechamiento anterior. Cada retrieve que alimenta la respuesta recibe ese conjunto y `force_entity_filter: true` cuando N es mayor que 0. Discovery no usa ese camino para citar. `DocumentIdentityScope` aplica la tabla de la sección 4 para focus `0`, focus `N`, facts de usuario, facts de foto y corrección. Los facts `catalog` todavía no existen: el hueco se cierra en F8, y F5 deja el punto de extensión para que una fuente que no sea `user` ni `photo` no se convierta en aguja. No se cambia el top-k. No se prende el reranker.

**Tests.** 0 pins → abierto, aunque la pregunta diga `NICE3000`. 2 pins y una pregunta que nombra sólo uno → las dos URIs. 1 pin Elemont y una pregunta que dice KONE → la URI de Elemont. Conjunto mixto no autorizado → denegación y cero Bedrock. Focus Elemont y manufacturer KONE de usuario → los chunks de Elemont conservan el cuerpo procedural. Corrección de marca → la marca vieja no es aguja. Los routes directos de evidencia reciben el mismo conjunto. Regresión del gap de G1 si esta fase lo cierra: focus VF5 + Elemont y trabajo KONE no puede afirmar que VF5 no está seleccionado.

**Ingeniería.** Esos tests. G3 se despliega al cerrarlos.

**Humano.** Smoke G3. El técnico juzga fuentes y badge. Que el filtro interno tenga N URIs lo afirma el test, no el smoke.

**Commit.** `fix: retrieve only the documents selected on screen`

**Handoff F5.** El ask ya no llama a `PinnedEntityScopeResolver`. Cero URIs siguen abiertas. N URIs van todas al orquestador con `force_entity_filter: true`, aunque la pregunta nombre una sola o diga otra marca. Un conjunto con una URI no autorizada niega el retrieve y no llama a Bedrock.

`DocumentIdentityScope` no vacía un chunk cuya URI está en el focus. Un chunk con otra URI no se promueve a cita. Una aguja sale sólo de `source=user` o `source=photo` en manufacturer, model o identifiers. `catalog` y `controller` no son agujas. Con focus VF5 + Elemont y trabajo KONE, los dos cuerpos quedan y el contexto no los marca como otro equipo. Eso cierra el recorte que en G1 podía dejar a VF5 sin procedimiento. No cambia el texto que el modelo elige escribir si la evidencia no alcanza.

No se reparte el top-k por documento. Fuentes sigue siendo lo citado, no el badge.

Observación para F8, sin tocar Document Focus: en el smoke de G2 la query efectiva todavía llevaba `KONE` del Work Context mientras el focus era Elemont + Monarch. F5 no compone la query y no borra esa palabra. F8 la trata al armar la string de retrieve.

F6 no cambia de contrato. Sigue sugiriendo fuera del focus y sin citar ese manual mientras no esté seleccionado.

### F6 — Discovery fuera del focus

**Compuerta:** G4, junto con F7. No se despliega sola.

**Objetivo.** Sugerir manuales que no están seleccionados. Con badge `0`, la sugerencia sale de lo que el retrieve principal ya citó. Con badge `N`, un manual de afuera no se cita. Monarch / NICE3000 sale del YAML. Esta fase no cambia la query ni llama a Haiku.

**Archivos.** `ManualCandidateRanker`, `RagController#attach_manual_suggestion`, `FocusNotice`, locales `rag.es.yml` / `rag.en.yml`, un servicio chico si el `Retrieve` de abstención no cabe en el controller.

**Cambios.** El ranker matchea brands y designators del catálogo. Tope 2. Con badge `0`, sin segundo `Retrieve`, ofrece el documento citado dominante. Con badge `N`, la card no se agrega a citas. Abstención con focus: `Retrieve` acotado, chunks fuera del prompt. Copy de ampliar, y de cambiar cuando el trabajo contradice los checks.

**Tests.** “Monarch NICE3000” produce la card de ese documento sin modificar `MANUFACTURERS`. Badge `0` y una cita ofrecen la card y no dejan el documento seleccionado. Una card de afuera no aparece en las citas cuando el focus tiene otro id. Elemont seleccionado y texto KONE no vacían el focus.

**Commit.** `feat: suggest manuals outside the selected set`

**Handoff F6.** `DocumentDiscovery` arma como máximo 2 cards y no escribe `document_focus`. Badge 0: un designador exacto del catálogo, o el único documento citado que supera al resto. Un empate de citas no ofrece nada. Badge N: la card sale sólo si el candidato no está seleccionado. Un designador exacto, o una marca que contradice los checks, se ofrece; la contradicción pide “Usar sólo este manual” y el resto pide “Agregar este manual” o “Dejar este manual seleccionado”. La card no entra en citas ni en el prompt. Abstención con focus: un `Retrieve` directo, `top_k` 3, filtro de cuenta, y se descartan las URIs ya seleccionadas. Esos chunks no vuelven a la respuesta. `ManualCandidateRanker.score` no cambió: el tope 3 del artefacto F0 sigue ahí, y el tope 2 es de discovery.

No se implementa `clarify_first` para `Q2`. Eso es F8.

### F7 — Aceptar y replay

**Compuerta:** G4. Deploy de F6+F7.

**Objetivo.** Aceptar actualiza check y badge, y vuelve a consultar la pregunta ya registrada.

**Archivos.** `rag_chat_controller.js`, `PinnedDocumentsController`, `RagController#ask`.

**Cambios.** “Ampliar” agrega. “Cambiar” reemplaza en una sola escritura, con lock, autorizando antes. Si la autorización o la escritura fallan, no hay replay y el badge no cambia. Si salen bien, el cliente refresca checks y badge y manda `replay_correlation_id`. El servidor sigue el contrato de Replay de la sección 4. El system test existente puede cubrir que no aparece una segunda burbuja del técnico; el test de controller cubre que no hay segundo `record_user_turn!` ni segunda llamada al analyzer.

F7 cierra las dos decisiones que F1 dejó abiertas.

**Query del replay.** Opción A. Al terminar una consulta normal, el mensaje de usuario de ese `correlation_id` guarda `retrieval_query`: la effective retrieval query de ese turno. El replay lee esa string y la pasa como `retrieval_question`. `RagQueryConcern` la usa tal cual y no vuelve a componer el episodio ni a pasar por `FollowupQueryRewriter`. Si esa clave no está, el replay usa el texto crudo del turno, también sin componer y sin `record_user_turn!`. No se reinterpreta el episodio. No se llama a Haiku.

**Idempotencia.** Sin tabla nueva. La respuesta del asistente guarda `focus_ids`, enteros ordenados, en el mismo mensaje de `conversation_history`, con el `correlation_id` original. La clave es ese id más los ids del focus persistido, comparados ordenados: el orden visual no genera otro replay. Focus vacío es `[]`. Si la pareja ya tiene respuesta, se devuelve esa respuesta y no hay Bedrock ni Haiku. El cliente no manda los ids. El servidor usa el focus ya escrito. Un focus distinto es un replay nuevo.

**Fallo.** Si la mutación no queda escrita, el JSON no pide replay y el cliente no consulta. Un documento no autorizado no cambia el focus y no hay replay. Si el replay falla después de mutar, la selección queda. El botón pasa a reintentar. Un éxito previo de la misma pareja no se vuelve a generar.

**Ampliar y cambiar.** `focus_mode=add` conserva los manuales ya seleccionados y agrega el candidato. `focus_mode=replace` deja sólo ese manual. La card trae una sola de las dos acciones. “Agregar este manual” no reemplaza. “Usar sólo este manual” no agrega.

**Tests.** Ampliar agrega un id. Cambiar deja sólo ese id. Un documento de otra cuenta no muta el focus y no pide replay. El replay usa la query guardada, no crea turno de usuario, no abre episodio y no llama a Haiku ni a `record_user_turn!`. La misma pareja no llama otra vez a Bedrock. Los mismos ids al revés son la misma pareja. Un focus distinto sí busca. `retrieval_query` y `focus_ids` siguen después de recargar.

**Humano.** Smoke G4. El botón de una card exitosa queda deshabilitado. Si el replay falló, Reintentar no duplica la pregunta del técnico.

**Commit.** `feat: retry the question after the technician adds a manual`

### F8 — Identidad, ventana y cuatro decisiones

**Compuerta:** G5, junto con F9 y F10. No es una segunda llamada Haiku.

**Objetivo.** El turno ayuda con lo que hay. Arma una string de retrieve, no un filtro AND. El catálogo pone el tipo. El focus no se toca. Funciona con Haiku en `off`. Al empezar, releer lo que F5 y F6 hayan mostrado. No implementar contra un párrafo de este archivo si el repo ya lo contradijo.

**Archivos.** `SemanticQueryAnalyzer` (mismo tool, síntoma literal opcional), `ActiveEpisode`, `ActiveEpisodeTurn`, `PendingQuestion`, `RagController`, `RagQueryConcern`, `SessionContextBuilder`, `DocumentIdentityCatalog`, `config/document_identities.yml`, `DocumentIdentityScope` (excluir `source=catalog` de las agujas), `test/architecture/no_hardcoded_equipment_test.rb`.

**Cambios.**

- Parser de designators compatible con string y mapping. `NICE3000` y `NICE3000new` quedan `type: controller`. El resto sigue sin tipo.
- `FACT_KEYS`, `PENDING_SUBJECTS` y los status de desconocido incluyen `controller`. `SOURCES` incluye `catalog`. El episodio sigue en `v: 1`.
- Un designator con tipo se persiste en su slot. Uno sin tipo queda sólo en la query de este request.
- Hecho `catalog` visible en el prompt como identidad reconocida, no como frase del técnico.
- Ventana técnica con los topes de la sección 4.
- Las cuatro decisiones, con el corte de `clarify_first` y la separación de `search_and_clarify`.
- Prefijo con las reglas de la sección 4. `nice300` aclara.
- Corrección que borra el canónico viejo de facts, pending, goal, ventana y query.
- `DocumentIdentityScope` no usa facts `catalog` como agujas.
- `FollowupQueryRewriter` no pisa la query compuesta.
- Cero inferencias nuevas. El analyzer existente sólo cuando su gate ya lo llama.

**Tests.** Los de la sección 14 que corresponden a identidad, decisiones, “no sé”, corrección, ventana, prefijo y agujas de catálogo. “NICE3000 E51” con flag `off`: query con `NICE3000` y `E51`, manufacturer Monarch con source catalog, controller NICE3000, focus intacto, sin URIs si el badge es 0. El techo de literales de equipo en código no sube. El gap de G1 quedó cerrado en el safeguard: un chunk del focus no se vacía ni se etiqueta como otro equipo. Si una respuesta futura igual dice que un manual seleccionado no lo está, esta fase agrega esa regresión sobre el texto generado. La query efectiva del smoke de G2 llevó `KONE` del Work Context con focus Elemont + Monarch. Esta fase arma esa string. No se corrige moviendo el focus.

**Regresión obligatoria, del smoke de G3.** Badge 0, Work Context sin manufacturer, model ni controller confiables de `user` o `photo`, pregunta `¿Qué es Q2?`. Decisión `clarify_first`. Cero retrieve. Cero generación RAG. Una sola pregunta: equipo, marca, controlador o modelo, con la foto como alternativa. La respuesta no puede adoptar un significado Thyssen, Elemont, Monarch ni de otro manual. El turno siguiente `Es Monarch NICE3000` sigue el mismo trabajo, recién ahí hay retrieve, la query lleva ese contexto y no repite la misma aclaración. `No sé, busca con eso` es `best_effort`: búsqueda global, el hallazgo se dice como candidato de un manual concreto, y no como definición universal. No se vuelve a preguntar de inmediato el mismo dato. No se diseña un retrieve para traer un Q2 de cada manual.

Con manufacturer y controller ya confiables, `¿Qué es Q2?` busca y no repregunta lo que ya está. Con Document Focus mayor que 0, esta regla no corre: se busca dentro del focus y, si ese manual no define el identificador, se abstiene o se pide el discriminador que corresponda.

**Commit.** `feat: build the retrieval query from catalog-grounded technical understanding`

**Handoff F8.** `Rag::TechnicalUnderstanding` arma la query y elige `ready`, `search_and_clarify`, `best_effort` o `clarify_first`. No llama a un modelo y no escribe `document_focus`. El analyzer existente sigue en su gate. `clarify_first` vuelve antes del orquestador, con `model_invoked=false` y sin Document Discovery. Un identificador corto (`Q2`, `ROS`, `K2`, `E03`, `CN5`) sin focus y sin identidad confiable es ese caso. Con un manual seleccionado se busca dentro de ese manual; si la respuesta se abstiene, se pide un discriminador y no se hace el retrieve global del token crudo.

Cuando la decisión sí autoriza discovery externo, `DocumentDiscovery` recibe la query técnica (`discovery_query`) y no necesariamente la pregunta cruda. `allow_outside: false` no borra la card de un designator exacto: VF5 con Elemont marcado sigue ofreciéndose. `source=catalog` no es aguja de `DocumentIdentityScope`. Sólo `user` y `photo` lo son.

`NICE3000` y `NICE3000new` quedaron `type: controller` en la fila Monarch ya confirmada. Un string sin tipo, como `VF5+`, no persiste controller ni model. `nice300` lista los dos candidatos y no elige. Una corrección saca el controller viejo y, si el manufacturer vino del catálogo con ese controller, también lo saca. El focus no se mueve.

Gaps que no cambian el contrato:

```text
Gap encontrado:
El identificador ambiguo se acotó a 2–4 caracteres. MPK418 y una marca ya
conocida por el episodio (Fuji) siguen buscando. "ok" no abre un episodio.

Decisión tomada:
clarify_first no cubre todo token con dígito. Cubre el identificador corto
que no es marca conocida ni designator de catálogo con tipo.

Razón:
Si no, el happy path de "MPK418" y "Fuji" dejaba de retrievear.

Impacto sobre siguientes fases:
F9 y F10 no reabren el umbral. G5 paso 2 sigue siendo el control de que un
síntoma con marca busca antes de preguntar.
```

**F8.1.** El smoke de F8 (`afdb1cf`, cuenta legacy, 2026-10-01 21:08–21:25) mostró que la ventana pegaba los últimos mensajes crudos. `¿Qué reviso?` perdió Nice300 y E51. `¿Necesitas controlador?` se buscó como síntoma. `Volviendo a la pregunta del controlador, no lo sé` abrió una búsqueda de la palabra controlador.

La ventana pasa a ser el turno actual, el código, el controller/model/designator, el fabricante, las observaciones técnicas recientes y el goal vigente. Una frase meta no se guarda como observación. Un follow-up corto conserva el trabajo. `No lo sé` con el controller pendiente queda `unknown_confirmed` y la query sigue el mismo trabajo. No hay una llamada LLM nueva: `SemanticQueryAnalyzer` puede devolver facts y observations, y Ruby persiste sólo el span literal. Si el gate no corre, la misma decisión sale de Ruby.

El journey real no es Excelsior con imanes. Jesús, usuario 6, el 2026-09-28 15:55–15:57 escribió la falla de un Excelsior de 10 niveles que se pasa en alta velocidad en el piso inferior a 1.5 m/s, después nombró el plano S1000 y `sg_lm2a`, y cerró con `Se pasa en bajada en alta velocidad`. Los imanes y CEA15 son el trabajo del 16 de septiembre, otro equipo. No hay transcripción de 6 a 10 turnos de una sola llamada. El journey de test usa esos tres turnos textuales y marca como reconstrucción la frase meta y el `no lo sé`.

La presentación de la respuesta (encabezados, footer, botones) no se tocó. Quedó en la sección 17 como Post-G5.

### F9 — Limpieza después del estado real

**Compuerta:** G5.

**Objetivo.** Borrar sólo lo que ya no tiene caller en el web. Alinear los docs con el contrato que el código quedó teniendo, no con el supuesto de este archivo si el handoff lo cambió.

**Archivos.** Métodos muertos de release en `ConversationSession`. `docs/ACTIVE_ARCHITECTURE.md`, `docs/SESSION_AND_RETRIEVAL.md`, una nota al frente de `docs/PLAN_FIELD_COMPANION_RECOVERY_2026-09-30.md` y de `docs/PLAN_R1B_SESSION_CORRECTNESS_2026-09-30.md`, `docs/README.md`.

**Cambios.** No borrar `active_entities`. No borrar la API que WhatsApp usa. No correr `down` de `document_focus`. Documentar `DocumentIdentityScope` con el contrato real, incluido lo que F5 y F8 dejaron. La nota de R1B dice que la parte de soltar pines quedó superada por este plan; el resto de R1B sigue. No se reescribe la historia.

Desde F1 no tienen caller, y F9 los borra: `pins_after_expiry`, `expiry_pin_cutoff`, `pins_after_manufacturer_correction`, `manufacturer_fact_value`, `incompatible_manufacturer_pin?`, `label_contains_word?`. La corrección de fabricante ya no emite `R1B_CASE_PROBE`. Los boundaries que siguen registran `pins_before` igual a `pins_after` y `pin_release_reason` vacío. Los docs no describen `corrected_manufacturer_mismatch` como comportamiento vigente.

**Tests.** El test de arquitectura de “el episodio no escribe el focus” sigue verde. La suite de sesión no referencia métodos borrados. Un grep de lectores web de pins sobre `active_entities` queda vacío.

**Commit.** `docs: record document focus as independent of the field case`

### F10 — Regresiones materiales

**Compuerta:** G5. Deploy de F8+F9+F10.

**Objetivo.** Dejar verde, sin duplicar de más, la lista de regresiones de abajo. Al empezar, releer el handoff de F5, F6 y F8.

**Archivos.** Tests nuevos sólo donde la fase dueña no haya dejado ya la aserción. Sin fixtures enormes. Dobles de Bedrock donde el proyecto ya los use.

**Tests.** La lista de la sección 14. No se exige una suite de browser completa.

**Humano.** Smoke G5.

**Commit.** `test: cover field companion document focus journeys`

---

## 14. Tests materiales

Estos tienen que existir y estar verdes antes de desplegar G5. Varios nacen en la fase que introduce el comportamiento. F10 confirma el conjunto, no lo reescribe entero.

1. **Writer ownership.** Boundary, corrección, expiry, estado inválido, foto y start-new-case no escriben `document_focus`. Pin, unpin, aceptar y upload sí.
2. **Pin y unpin antes de preguntar.** Orden pin→pregunta y unpin→pregunta. Fallo HTTP revierte el check y no envía. La cola no queda envenenada.
3. **Scope exacto.** N URIs llegan como exactamente N al retrieve principal y a los routes directos que producen evidencia.
4. **Conjunto mixto no autorizado.** Denegación. Cero Bedrock.
5. **No sé.** Controller pendiente, “No puedo verlo. Busca con eso.”, hay retrieve, el slot queda `unknown_confirmed`, no se re-pregunta. Un turno posterior con un designator tipado lo pasa a `known`. El focus no cambia.
6. **Cuatro decisiones.** `search_and_clarify` hace un retrieve y una pregunta posterior que no entra en la query. `clarify_first` hace cero retrieve y cero discovery, con `model_invoked=false`. `best_effort` no se persiste. `ready` no pregunta la marca en `NICE3000 E51`.
7. **Corrección.** La query efectiva contiene `NICE1000` y no contiene `NICE3000`. El focus es el mismo.
8. **Progresivo.** En el cuarto turno, `effective_question` contiene `E03`, `VF5`, el problema de las puertas y la observación de que vuelve a abrir. No basta `decision == ready`.
9. **Replay.** Focus persistido, la pregunta se consulta de nuevo, cero turno de usuario duplicado, cero boundary de episodio, cero llamada al analyzer. Repetir el mismo replay no llama otra vez a Bedrock.
10. **Upload tardío.** El job del episodio anterior no agrega focus. El upload vigente no deja salir la pregunta antes de que check y badge coincidan. El fallo de upload suelta la espera.
11. **Designator tipado.** `NICE3000` persiste como controller. Un designator string, sin tipo, no persiste como model ni como controller.
12. **Prefijo.** `NICE3000` exacto. `nice300` ambiguo. `NICE3000n` sólo completa si el umbral se cumple. `ni`, `nic` y `vf` no se expanden.
13. **DocumentIdentityScope.** Focus Elemont y trabajo KONE conservan el cuerpo de Elemont. Un fact `catalog` no vacía chunks. Una corrección no deja la marca vieja como aguja.

Comando de cierre de compuerta, más los archivos que cada fase haya agregado:

```text
bin/rails test test/models/conversation_session_case_boundary_test.rb test/models/conversation_session_case_ownership_test.rb test/controllers/pinned_documents_controller_test.rb test/controllers/concerns/rag_query_concern_test.rb test/controllers/rag_controller_test.rb test/services/rag/manual_candidate_ranker_test.rb test/services/rag/document_identity_scope_test.rb test/services/bedrock_rag_service_test.rb test/services/session_context_builder_test.rb test/architecture/no_hardcoded_equipment_test.rb
git diff --check
```

Esa suite incluye, además de la lista anterior, los tests relevantes de `DocumentIdentityScope`, `BedrockRagService` y el controller de `/rag/ask`. El test de replay que agregue F7 entra en el mismo comando antes de cerrar G5.

---

## 15. Production smoke

Host: la web de producción que ya usa el piloto. Misma cuenta antes y después del deploy. Si un paso falla, la compuerta es `FAIL`. No se sigue con la siguiente.

Para repetir cualquiera: abrir Archivos, desmarcar todo, volver a marcar sólo lo que el paso pide, y escribir de nuevo.

### G1 — después de desplegar F1

Preparación: en Archivos, dejar marcados dos manuales. Uno cuyo nombre visible contiene Elemont. Otro que no sea KONE ni Elemont (VF5 / Fermator si está en la lista). Anotar los dos nombres. El badge puede seguir oculto cuando no hay nada marcado. Eso no es un fallo de G1.

1. Escribe: `No, no es Elemont. Es KONE.`
2. PASS si los dos checks siguen. FAIL si Elemont se fue o si sólo queda el otro.
3. Escribe: `¿Qué reviso si no nivela?`
4. PASS si la respuesta se apoya en lo que sigue marcado, o dice que ahí no está. FAIL si habla de un solo manual como si el otro se hubiera soltado solo.
5. Recarga la página.
6. PASS si los mismos dos siguen marcados.

### G2 — PASS el 2026-10-01

En producción: badge, checks y persistencia. La traza de la pregunta con Elemont y Monarch marcados fue `pinned=2`, `retrieval=2`. Que Fuentes mostrara sólo Monarch es correcto: los tres chunks de mayor score eran de ese manual. Document Focus define los documentos elegibles. No obliga a que cada uno aporte un chunk o una cita. No se implementa diversidad forzada por documento.

Ajuste de UX, no bloquea G3 ni G5: el rótulo “Fuentes” puede aclararse después como “Fuentes citadas/usadas en la respuesta”, para separarlo del badge de documentos seleccionados. No se cambia en F5.

### G2 — después del corte de F2+F3+F4

Hacerlo en el teléfono y, si hay pantalla ancha, mirar también el número de desktop.

1. Recarga sin pinchar nada. PASS si los checks de antes del deploy siguen y el número es ese, en el teléfono y en desktop. FAIL si el deploy soltó manuales.
2. Desmarca todo y recarga. PASS si se ve `0`.
3. Marca un manual. El cuadro de escritura no gana el nombre del archivo. El número pasa a `1`. Escribe `¿Dónde está este parámetro?` y envía enseguida. PASS si las fuentes son de ese manual. FAIL si responde como si no hubiera ninguno, o si pide seguir con una consulta anterior o un resumen.
4. Desmarca ese manual. El número pasa a `0`. Envía enseguida `¿Qué significa K1?`. PASS si la respuesta no queda limitada al manual que acabas de quitar.
5. Vuelve a marcar los dos manuales de G1 y escribe otra vez `No, no es Elemont. Es KONE.` PASS si los dos checks siguen.
6. Si subís un archivo propio, esperá a que aparezca marcado antes de preguntar. PASS si no podés enviar la pregunta mientras sigue procesándose, y si al terminar el check y el número coinciden. FAIL si la pregunta sale con el archivo marcado en pantalla pero la respuesta lo ignora, o si un fallo de la subida lo deja marcado. Un archivo que hayas subido en un intento anterior no tiene que marcarse solo en este momento.

### G3 — PASS el 2026-10-01

Imagen `0f2f2c9`. Dos pasadas de `¿Qué es Q2?`. Badge 0 buscó en el corpus abierto. Un manual seleccionado dejó el filtro en esa URI y no citó otro. Dos manuales quedaron los dos en el filtro aunque la pregunta nombrara a uno. Una marca del Work Context no movió el focus. No hay diversidad forzada. Fuentes sigue siendo lo citado.

Hallazgo para F8, sin reabrir F5: con badge 0 y sin equipo confiable, el tope fue el esquema Thyssen CMC-3 página 29, donde `Q2 / Q3` es un terminal real. El grounding era correcto. Adoptar ese significado como si fuera el del trabajo es el caso de `clarify_first` que F8 tiene que cerrar.

### G3 — después de desplegar F5

1. Deja `0` manuales. Pregunta algo que sepas que está en un manual concreto de la biblioteca. PASS si puede citar ese manual. El número sigue `0`.
2. Marca un manual distinto, que no sea ese. Número `1`. Haz la misma pregunta. PASS si dice que en el manual marcado no está, y no cita el otro. FAIL si la respuesta trae como fuente el manual que no marcaste.
3. Marca un segundo manual. Número `2`. Pregunta usando el nombre de uno solo. PASS si el número sigue `2` y los dos checks siguen. FAIL si uno se apaga solo o si entra un tercero como fuente.

### G4 — PASS el 2026-10-01

Imagen `4e359f53165a6b7639d948da4e3622e5c94d0afc`. Con Elemont marcado, `¿Cómo uso el módulo electrónico VF5?` respondió sólo con ese manual, ofreció el VF5 de Fermator, el técnico lo aceptó, el focus pasó a Elemont + VF5, la misma pregunta se ejecutó de nuevo y la segunda respuesta usó VF5. No apareció otra burbuja del técnico.

Hallazgo para F8, sin reabrir F6 ni F7: `Q2` y `ROS` con un manual que no los define no pedían contexto, y una abstención hacía discovery con la pregunta cruda. El primer hit (Crown, Thyssen) no es el equipo del técnico. F8 corta ese retrieve cuando falta identidad y, cuando el discovery sí corre, usa la query técnica.

### G4 — después de desplegar F6+F7

1. Deja sólo Elemont marcado. Número `1`. Escribe: `Es Monarch / NICE3000.`
2. PASS si Elemont sigue marcado y aparece una card con el manual Monarch NICE3000, con el nombre que se ve en la lista. FAIL si no hay card, o si esa respuesta ya cita ese manual.
3. Elige ampliar. PASS si el número pasa a `2`, los dos checks están, y Danebo contesta de nuevo la misma pregunta sin que vos la vuelvas a escribir. Tu mensaje no tiene que aparecer dos veces. La respuesta nueva puede citar el manual Monarch.
4. Si la pantalla ofrece cambiar, probalo en otra pasada: desmarca todo, deja sólo Elemont, escribe otra vez `Es Monarch / NICE3000.`, y elegí cambiar. PASS si el número queda en `1` y Elemont se va porque tocaste Cambiar.
5. Vuelve a `0`. Escribe: `Falla 37, cierra puerta y vuelve a abrir.` PASS si la respuesta puede citar un manual y, si ofrece dejar uno seleccionado, el número sigue `0` hasta que lo toques. FAIL si el número cambia solo. Si no ofrece ninguno, también es PASS.

### G5 — después de desplegar F8+F9+F10

1. Deja `0` manuales.
2. Escribe: `Tengo un elevador Elemont, las puertas no cierran.`
3. PASS si Danebo responde con fuentes, o dice que no hay un procedimiento único, antes de exigirte modelo o controlador. El número sigue `0`. Puede pedirte un solo dato al final. FAIL si sólo pregunta, si inventa un controlador, o si da un procedimiento fino sin fuente.
4. Escribe: `Es VF5.`
5. Escribe: `Intenta cerrar y vuelve a abrir.`
6. Escribe: `Marca E03.`
7. PASS si la última respuesta sigue tratando el problema de las puertas y el E03, con fuentes o con una ausencia explícita. FAIL si parece un chat nuevo que olvidó las puertas, si inventa una cantidad de intentos que no escribiste, o si el número deja de ser `0` solo.
8. Si en algún momento te preguntó el controlador o el modelo, escribe: `No sé. Busca con eso.` PASS si sigue ayudando y no repite esa misma pregunta. Si no te preguntó nada, este paso no hace falta: anotá PASS y seguí.
9. Escribe: `nice300 e51`. PASS si no da por cerrado que es NICE3000 y el número sigue `0`. Puede preguntarte cuál es. FAIL si afirma que es NICE3000 sin decir que hay más de una posibilidad, o si el número cambia solo.
10. Escribe: `NICE3000 E51, ¿qué reviso?` PASS si no te bloquea pidiendo la marca, responde con fuentes o dice que no está, y el número sigue `0`. Si ofrece un manual, el nombre es el de NICE3000 / Monarch. FAIL si el número pasa a `1` solo.
11. Escribe: `No, era NICE1000.` PASS si a partir de ahí habla de NICE1000 y no sigue el procedimiento como si el equipo siguiera siendo NICE3000. El número no cambia solo.
12. Marca un manual. El número pasa a `1` antes de la siguiente pregunta. Escribe: `¿Dónde está este parámetro?` Desmarcalo. El número vuelve a `0`. Escribe: `¿Qué significa K1?` PASS si la segunda respuesta no queda atada al manual que ya desmarcaste.
13. Marca Elemont y otro manual que no sea KONE. Número `2`. Escribe: `No, no es Elemont. Es KONE.` PASS si el número sigue `2` y los mismos checks siguen.
14. Si aparece una card para ampliar o cambiar, tocá una. PASS si el número y los checks coinciden con lo que tocaste, y Danebo vuelve a contestar sin que reescribas la pregunta. Recarga. PASS si siguen así.

En el teléfono, el número de los pasos 12 y 13 tiene que coincidir con desktop después de recargar.

---

## 16. Riesgos

- **G1 no reproduce el incidente** si el manual elegido no tiene Elemont en el nombre visible. Elegir a propósito ese manual.
- **Backfill incompleto.** El primer paso de G2 es recargar antes de pinchar. Lo que no tenía id no aparece marcado.
- **Pins sólo en `document_focus` después de G2.** Un rollback a la imagen vieja no los muestra hasta que se vuelva a desplegar G2. Por eso el smoke de G2 es inmediato y no se acumulan días antes de decidir. La columna no se dropea en el rollback.
- **El retrieve de abstención** agrega latencia sólo cuando lo seleccionado no alcanza. Si se dispara de más, se baja a catálogo-only en un commit de corrección de G4, sin tocar G3.
- **Catálogo incompleto.** Una marca que no está en el YAML ni en el nombre no se adivina.
- **`clarify_first` de más.** El paso 2 de G5 lo ve. Si “las puertas no cierran” no busca, es FAIL y se corrige el umbral en F8, sin nueva compuerta.
- **Haiku apagado o gate cerrado.** `NICE3000 E51` tiene que pasar igual. Prender el flag o dejar que el modelo escriba Monarch sin el YAML rompe el contrato.
- **Upload.** Sigue pudiendo seleccionar un archivo que el técnico ya no quiere, pero el check se ve, y un upload de un trabajo anterior no lo hace.

---

## 17. Fuera de este plan

- Rehacer el pipeline RAG, los embeddings, Aurora o el modelo de Bedrock.
- Rediseñar la UI más allá del número y de las dos acciones de la card.
- Multi-hilo, un botón de trabajo nuevo, o migrar WhatsApp.
- Borrar `active_entities` o `MANUFACTURERS`.
- Agregar fabricantes al código para pasar un caso.
- Una segunda llamada LLM, un JSON de episodio con síntomas persistidos, o un formulario de marca, modelo, controlador y falla.
- Varias queries fusionadas, reranker siempre activo, filtros de metadata por campo técnico, o un mapa de typos.
- Medir en producción la calidad de la string HYBRID. Eso es un follow-up, después de cerrar los journeys.
- Auditar si `DocumentIdentityScope` sigue haciendo falta cuando los facts de catálogo ya no son agujas. No se apaga en este plan.
- Mostrar el filename original junto a `KbDocument.display_name` en la lista de Archivos. El dato ya está en `WebManualBatch.filename` y `BulkUploadAsset.filename`. No entra en G2.
- Renombrar “Fuentes” a “Fuentes citadas/usadas en la respuesta”. Quedó anotado en el PASS de G2. No bloquea G3.
- **Post-G5 — Conversational Presentation Cleanup.** Las respuestas siguen viéndose como reporte: “Guía Danebo”, otra “Guía”, “Manual”, footer repetido y varios bloques o botones. Después de cerrar G5, evaluar quitar encabezados redundantes, dejar las fuentes visualmente secundarias, reducir botones y revisar el footer, sin soltar el grounding ni la seguridad. Una acción se conserva sólo cuando el técnico tiene que decidir algo. No bloquea F8, F9, F10 ni G5. F8 no lo mezcló, salvo el texto de `clarify_first`.
- Obligar a que cada documento seleccionado aporte al menos un chunk. El top-k puede llenarse con un solo manual del focus.
- TurnInterpreter V2 (T0–T3). La interpretación lingüística posterior a F8 está en [PLAN_TURN_INTERPRETER_2026-10-01.md](PLAN_TURN_INTERPRETER_2026-10-01.md). F9 y F10 no la absorben. No hay shadow de producción.

---

## 18. Definition of done

1. G1–G5 están en `PASS`, con fecha y con lo que se vio en pantalla.
2. Las reglas de la sección 12 tienen test o paso de smoke.
3. `ACTIVE_ARCHITECTURE.md`, `SESSION_AND_RETRIEVAL.md` y `docs/README.md` describen `document_focus` como la selección visible, y dicen que el episodio no la escribe. `DocumentIdentityScope` queda descrito como transformación posterior, no como selección.
4. R1B y el recovery siguen como historia. Su nota al frente apunta aquí.
5. Ningún path web escribe el focus salvo pin, unpin, aceptar card y auto-pin de upload.
6. `NICE3000 E51` con badge `0` busca sin pedir la marca. El badge sigue `0` hasta un click.
7. “Elemont, las puertas no cierran” recibe ayuda antes de cualquier formulario. El turno de E03 todavía busca con el problema, VF5 y la observación. “No sé” no entra en bucle. `nice300` no se da por `NICE3000`. Una corrección a NICE1000 no arrastra NICE3000. El focus no se mueve solo.

Hasta que G1 exista en producción, el contrato vigente de pins sigue siendo el de R1B. Este archivo no cambia producción por el hecho de estar en el repo.

## Estado de los documentos

| Documento | Rol |
|---|---|
| Este archivo | Única fuente viva del focus. El estado de cada compuerta se anota al hacer el smoke |
| `PLAN_TURN_INTERPRETER_2026-10-01.md` | Interpreter post-F8. No forma parte de G5 |
| `ACTIVE_ARCHITECTURE.md`, `SESSION_AND_RETRIEVAL.md`, `docs/README.md` | Siguen vigentes hasta F9. F9 reemplaza los párrafos que dicen que el pin pertenece al caso |
| `PLAN_R1B_SESSION_CORRECTNESS_2026-09-30.md` | Histórico en lo que dice de soltar pines. Sigue vigente en episodio, `expected_episode_id`, piso de historial, foto y observabilidad. Nota al frente en F9 |
| `PLAN_FIELD_COMPANION_RECOVERY_2026-09-30.md` | Sigue siendo el mapa del recovery. La premisa de pins de R1B queda apuntando aquí en F9 |
| `PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29.md` | Cerrado. Histórico |
| R1A y docs de corpus | Vigentes |

## Implementation

| Fase | Estado |
|---|---|
| F1 | Hecha. G1 PASS |
| F2 | Hecha. G2 PASS |
| F3 | Hecha. G2 PASS |
| F4 | Hecha. G2 PASS el 2026-10-01 |
| F5 | Hecha. G3 PASS el 2026-10-01 |
| F6 | Hecha. Sugerencias fuera del focus. G4 PASS |
| F7 | Hecha. Replay con la query guardada. G4 PASS el 2026-10-01 |
| F8 | Hecha. Query técnica, cuatro decisiones, discovery con esa query. Sin deploy |
| F9 | No empezada. Borrar helpers de release sin caller y alinear docs |
| F10 | No empezada. Confirmar la sección 14. G5 despliega F8+F9+F10 juntas |
| TurnInterpreter | Fuera de G5. Ver `PLAN_TURN_INTERPRETER_2026-10-01.md`. F9 y F10 siguen |
