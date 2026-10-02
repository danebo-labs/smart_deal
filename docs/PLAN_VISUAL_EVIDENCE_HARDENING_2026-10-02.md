# Visual Evidence Hardening (2026-10-02)

**Estado:** `F1–F3 IMPLEMENTED LOCALLY — PRODUCTION PHOTO RESMOKE PENDING`

Source of truth de este cierre. Reconcilia el plan de Codex revisado sobre `25fcb0ab9abd6ad2b5992054df5ff26a6cf300c0` con la revisión de Opus (`PASS WITH REQUIRED CHANGES`). Donde Opus modifica a Codex, manda Opus. La arquitectura de este documento no se reabre.

Master de Turn Interpreter, sin cambios de alcance: [PLAN_TURN_INTERPRETER_2026-10-01.md](PLAN_TURN_INTERPRETER_2026-10-01.md).

---

## Producción

Desplegado: `0a1b9de8ac525c8a634314b0416395e66efa77e5`.

Commit que documenta el owner rollout: `25fcb0ab9abd6ad2b5992054df5ff26a6cf300c0`.

`HAIKU_QUERY_ANALYSIS_MODE=owner` está LIVE. No cambia.

No hay deploy ni smoke durante la ejecución local de F1–F3. Después del review, F1–F3 tienen un deploy y un resmoke de producción acotado a foto relevante. T3 sigue fuera de scope. No hay rollback en esta ejecución.

El blocker de foto relevante sigue abierto hasta un resmoke posterior a F1–F3. El smoke de texto pasó. La placa de prueba salió `relevant` en Vision y escribió manufacturer/model `source=photo`, pero `FieldPhoto.visual_observation` quedó vacío, `ActivePhotoContext` salió `invalid` y no hubo `Photo Evidence`.

---

## Principio

```text
Photo Event
    ↓
Vision raw result
    ↓
Candidate Visual Observation
    ↓
Accepted Visual Observation
    ↓
technical consequences
```

Una foto tiene una sola Accepted Visual Observation. Es la única fuente de verdad de:

```text
FieldPhoto.visual_observation
episode photo facts
conflicts
pending resolution
persistent [FOTO] history
PhotoQuestionAnswerService
retrieval anchors
Photo Evidence
future ActivePhotoContext
QueryComposer / generation
```

Raw Vision sólo alimenta la lectura visual que ya se pagó (display) y la telemetría de uso/costo de esa llamada. Nunca alimenta comportamiento técnico posterior.

```text
LLM understands broadly.
Code controls reality.

Context is not evidence.

Raw vision is not accepted evidence.

One accepted visual observation is the source of truth.
```

Autoridad, sin cambios de dueño:

- TurnInterpreter: función conversacional del texto. Fuera de este plan.
- Vision: qué está visible y cómo se relaciona con la tarea visual que ya recibe hoy.
- Ruby: normalización, aceptación, persistencia, relevancia ya normalizada y consecuencias.

No hay transacción entre `FieldPhoto` y `ConversationSession`. La observación puede quedar guardada aunque `expected_episode_id` descarte el write tardío. Ese descarte tiene que impedir history, facts y Photo Evidence en el episodio nuevo.

---

## Bug de producción y los dos bypasses

`FieldPhotoAnalysisJob` llama `store_visual_observation` y descarta el retorno. `FieldPhotoObservation.persist!` rechaza con `nil`, no con excepción. El `rescue` del job sólo ve excepciones, así que el rechazo normal es silencioso. El job sigue con `photo_value(result)`, armado desde el JSON crudo (`result[:parsed]` más el compact context crudo).

Ese valor crudo entra hoy en tres consecuencias:

1. `record_photo_observation!` escribe facts `source=photo`, conflictos y el puntero.
2. `record_assistant_turn!` persiste la línea `[FOTO]` armada por `FieldPhotoAnalysisService#build_compact_context` desde el raw. `SessionContextBuilder` la reinyecta en los turnos siguientes (`recent_history_for_prompt` / último mensaje assistant).
3. `Rag::PhotoQuestionAnswerService` arma `anchor_suffix` y el bloque `Photo Evidence` desde ese mismo `photo_value`. `ProvenanceSegmenter` lee la columna `visual_observation`. En una reread inválida, la provenance y la generación saldrían de lecturas distintas.

`ActivePhotoContext` no es el origen. Ya hace lookup por `account_id` + `id` y sólo proyecta `visual_observation` sanitizada. `invalid` fue el síntoma correcto.

`from_analysis` copia cardinalidad, largos y enums sin acotarlos. `sanitize` rechaza el envelope entero. Sin `outcome_reason` no se puede saber qué cláusula falló.

---

## Límite de release

F1–F3 son un release independiente. Cierran el blocker sin cambiar el prompt ni la semántica de relevancia.

```text
F1  Regression tests
F2  Accepted Visual Observation
F3  Semantic write gating

--- REVIEW / DEPLOY / PHOTO-RELEVANT RESMOKE ---

F4  VisualTaskContext
F5  previous_visual_evidence

--- EVAL / REVIEW / DEPLOY / MULTIMODAL SMOKE ---
```

F4 y F5 están especificados abajo y no se implementan con F1–F3. Cambian lo que el modelo ve. No se despliegan sin el eval multimodal.

---

## F1 — Tests rojos

Primero tests que fallen con el código actual y fijen el contrato de después del fix.

### 1. Rechazo de persistencia

Vision result válido como lectura display, candidate rechazada (enum inválido alcanza: `subsystem` o `condition` fuera de la allowlist).

El código actual puede dejar:

```text
visual_observation = nil
source=photo facts escritos
```

Después del fix:

```text
visual_observation = nil
0 photo facts
0 conflicts
0 pending closure
0 persistent [FOTO] history
0 PhotoQuestionAnswerService
0 retrieval anchor
0 Photo Evidence
visual display response still delivered
```

### 2. Raw no entra a PhotoQuestionAnswerService

Candidate inválida y hay pregunta. El servicio no se instancia y no corre. No hay retrieval ni generación a partir del raw.

### 3. Raw no entra al history

Candidate inválida: cero línea persistida `[FOTO]`. La lectura display-only no queda como contexto reusable. Un turno posterior no puede recibir manufacturer/model/códigos de esa lectura vía `SessionContextBuilder`.

### 4. Reread inválida

`visual_observation` almacenada A, válida. La reread produce candidate B, inválida.

```text
A stays persisted
B display-only
0 B facts
0 B history
0 B RAG
```

No presentar A como resultado de B. No generar con el raw de B y atribuir provenance a A.

### 5. `:applied`, `:stale`, `:not_recording`

`record_photo_observation!` no puede seguir devolviendo `nil` para dos causas distintas. Los tests tienen que exigir los tres símbolos. `nil` no es un resultado aceptable.

Además, en la misma fase de tests, dejar cubierto el puntero de una foto nueva inválida: `active_photo` pasa a esa foto, `ActivePhotoContext` queda `invalid`, y la evidencia de la foto anterior no entra al follow-up.

---

## F2 — Accepted Visual Observation

Archivo principal: `app/services/field_photo_observation.rb`.

### `from_analysis`

Pasa a ser la proyección acotada del raw. Sólo claves de `KEYS`. `squish` determinístico en strings.

`canonical_component`, `manufacturer` y `model`: vacío o más de 80 caracteres → `UNKNOWN`. No truncar identificadores.

`visible_text`:

- conservar orden
- quitar blank
- quitar duplicados (primera ocurrencia, comparación exacta después de `squish`)
- descartar el ítem completo si supera 80 caracteres
- máximo 8

Si el envelope sigue por encima de 2048 bytes, sacar ítems de `visible_text` desde el final hasta entrar en presupuesto. Nunca cortar una transcripción a mitad de string. Si al vaciar `visible_text` el envelope sigue fuera de presupuesto, la candidate es inválida (`over_budget`).

No reparar enums. `subsystem` o `condition` fuera de `SUBSYSTEMS` / `CONDITIONS` invalidan la candidate completa. No coercer a `UNKNOWN`.

`target_visible` y `relevance_to_goal` entran desde los valores ya normalizados de `FieldPhotoAnalysisService` (`result[:target_visible]`, `result[:relevance_to_goal]`). `from_analysis` no vuelve a leer esas dos claves del JSON crudo. F1–F3 no cambian cómo el servicio las normaliza: `intent_sent?` sigue gobernando ambas.

`sanitize` permanece estricto y all-or-nothing. La normalización vive en `from_analysis`, no en un `sanitize` permisivo.

`schema_version` sigue en 1. `prompt_fingerprint` sigue siendo `FieldPhotoPrompt.prompt_fingerprint_sha256`. F1–F3 no tocan `SYSTEM_BLOCKS`, así que el fingerprint no se mueve.

### Resultado de aceptación

Dejar de usar `persist! → nil` como único gate del job. `persist!` puede seguir devolviendo el hash guardado o `nil` para los callers que ya persisten un payload conocido y válido. El job no gatea con ese `nil`.

Método mínimo, en la misma clase, que el job sí usa:

```text
status:       stored | invalid | unavailable
observation:  hash persistido, o nil
reason:       nil cuando stored; si no, un reason allowlisted
```

Reasons:

```text
invalid_enum
invalid_shape
over_budget
persistence_failure
```

Orden de clasificación: `invalid_enum`, después `over_budget`, después `invalid_shape`. Un solo reason.

Semántica:

- `stored`: `sanitize` aceptó y `update!` escribió. `observation` es exactamente el hash persistido.
- `invalid`: candidate rechazada. No hay `update!`. Una observación previa en esa fila permanece.
- `unavailable`: la foto no existe en el `account_id`, o `update!` falló (`persistence_failure`). Display-only. Cero consecuencias técnicas.

### Telemetría

Evento `photo_observation_acceptance`. Sólo:

```text
result
outcome_reason
field_photo_id
account_id
correlation_id
```

Sin payload visual. `[IMAGE_ANALYSIS]` y `usage_fields` pueden seguir registrando manufacturer/model/codes crudos: describen la llamada Vision, no evidencia de comportamiento. No copiar ese raw a `TurnEvidence` ni a la telemetría del interpreter.

### `evidence_value`

Sólo después de `stored`:

```ruby
evidence_value = FieldPhotoObservation.reading_value(accepted_observation)
```

Ese hash es la única representación técnica downstream. No reconstruir manufacturer, model, `visible_codes`, condition ni `compact_context` desde `result[:parsed]` ni desde `photo_value(raw)`.

`reading_value` ya exige `sanitize` y ya arma `compact_context`. La línea persistida sale de `evidence_value[:compact_context]`. No rearmar la línea cruda de `build_compact_context` (esa incluye "Objetivo visible" tomado del raw).

### Job

`app/jobs/field_photo_analysis_job.rb` separa dos valores.

`display_value` sale del raw (`result[:analysis]` y el renderer actual). Sólo se publica al técnico. Existe aunque la candidate sea inválida: la lectura ya está pagada.

`evidence_value` existe sólo con status `stored`. Sólo él alimenta:

```text
record_photo_observation!
record_assistant_turn! de la línea [FOTO]
PhotoQuestionAnswerService
retrieval / generation de esa foto
```

Candidate no aceptada, foto nueva o reread inválida:

- publicar `published_analysis` como display-only
- no ejecutar `PhotoQuestionAnswerService`
- no persistir `[FOTO]`
- no escribir facts ni cerrar pending

### PhotoQuestionAnswerService

Hoy el servicio recibe el `photo_value` crudo y con eso arma `anchor_suffix` (retrieval) y `photo_evidence_block` (generación). Después del fix sólo recibe `evidence_value`.

Sin Accepted Visual Observation no se llama.

No rediseñar la semántica de relevancia en F1–F3. `intent_sent?` no se parte. El gate ya aprobado del camino foto+pregunta, que el servicio hoy no aplica, queda así: si `relevance_to_goal == "unrelated"`, `anchor_suffix` es vacío. El resto de ese camino no cambia. La pregunta explícita sigue siendo la tarea. El bloque Photo Evidence de ese turno, cuando el servicio sí corre, se arma desde `evidence_value`.

### History

`[FOTO]` persistido sólo desde `evidence_value[:compact_context]`. Candidate inválida: cero `[FOTO]`. El broadcast display-only sí puede mostrarse.

### Provenance

Retrieval, generación y provenance salen de la misma Accepted Visual Observation. Prohibido: generar con el raw de B y segmentar con la columna de A. La reread inválida no llama al servicio, así que no hay respuesta RAG que mezclar.

### Reuse y reread

Reuse, sin cambio de semántica: cero llamada Anthropic, `sanitize` de lo guardado, `reading_value`, consecuencias desde ahí. Si `sanitize` falla, se mantiene el camino actual de observación ausente.

Reread válida: la candidate nueva se acepta, reemplaza la observación, y todo lo downstream sale de esa observación nueva.

Reread inválida: la observación anterior queda en la fila. La lectura nueva es display-only. Cero facts, history y RAG nuevos. No pasar la observación anterior al writer ni al servicio como si la reread hubiera tenido éxito.

---

## F3 — Semantic write gating

`ConversationSession#record_photo_observation!` devuelve exactamente uno de:

```text
:applied
:stale
:not_recording
```

No devuelve `nil`. No cambia las reglas T1.1 de facts y pending.

### `:applied`

`expected_episode_id` sigue siendo el episodio vivo. La evidencia aceptada puede seguir a facts, conflicts, cierre de pending, history y RAG de foto+pregunta, con los gates actuales.

### `:stale`

`expected_episode_id` ya no coincide con el episodio vivo. Es el único estado que suprime el resto.

Permitido:

```text
Accepted Visual Observation queda en FieldPhoto
display de la lectura ya pagada
```

Prohibido:

```text
mutar el episodio nuevo
facts
cambios de pending
history
PhotoQuestionAnswerService
retrieval
generation contra el episodio nuevo
```

### `:not_recording`

No es stale. Ocurre cuando `episode_recording?` es false: flag apagada, sesión compartida, canal distinto de web.

Conserva el flujo actual de foto. No bloquear display ni el camino foto+pregunta sólo porque el episodio no se persiste. Si hay evidencia aceptada, history y `PhotoQuestionAnswerService` siguen. Si no hay evidencia aceptada, manda el gate de F2: display-only, sin `[FOTO]` y sin el servicio.

### Candidate inválida y puntero

Una foto nueva con candidate inválida igual llama al writer, con observación vacía, no con el raw y no con la observación de otra foto.

Si el write es `:applied`:

```text
active_photo apunta a la foto nueva
0 facts
0 pending closure
ActivePhotoContext(foto nueva) = invalid
```

Preferible no tener evidencia que dejar activa la foto anterior para un follow-up de la foto nueva.

Si el write es `:stale`, el writer no muta el episodio nuevo. El puntero no se mueve ahí.

Una reread inválida de la misma foto no sustituye la observación guardada y no reaplica los facts de esa observación como resultado de la lectura nueva.

### Pending T1.1

Se conserva tal cual:

```text
sólo manufacturer/model relevant, source=photo, cierran el slot exacto
controller pending queda abierto
conversational pending queda abierto
unrelated, uncertain y nil no promueven facts
expected_episode_id protege al writer tardío
```

`PHOTO_PENDING_SLOTS` sigue siendo `manufacturer` y `model`. `photo_identity_blocked?` sigue exigiendo `relevance_to_goal == "relevant"`. No rediseñar pending.

---

## Fuera de F1–F3

No tocar:

```text
Rag::VisualTaskContext
Rag::PhotoIntent
previous_visual_evidence
FieldPhotoPrompt
FieldPhotoPrompt::SYSTEM_BLOCKS
prompt fingerprint
FieldPhotoAnalysisService más allá de leer sus valores ya normalizados
TurnInterpreter
Document Focus
T3
tablas nuevas
migrations
llamadas LLM nuevas
ingesta / KB
PhotoIntentRenderer
PhotoObservationContinuity
ActivePhotoContext (sólo tests de regresión)
SessionContextBuilder (el gate está en no escribir [FOTO])
QueryComposer (sólo tests de regresión)
```

`SYSTEM_BLOCKS` permanece byte-identical. El fingerprint no puede moverse en este release.

---

## Archivos de F1–F3

```text
CHANGE
app/services/field_photo_observation.rb
app/jobs/field_photo_analysis_job.rb
app/models/conversation_session.rb
app/services/rag/photo_question_answer_service.rb

TESTS
test/services/field_photo_observation_test.rb
test/jobs/field_photo_analysis_job_test.rb
test/models/conversation_session_test.rb
test/services/rag/photo_question_answer_service_test.rb
test/services/rag/active_photo_context_test.rb
test/services/session_context_builder_test.rb
test/services/rag/query_composer_test.rb
test/models/conversation_session_turn_interpreter_test.rb
```

Otro archivo sólo si hace falta para cerrar un bypass de raw que estos cuatro no cubran, y el commit tiene que decir cuál. No ampliar arquitectura.

`SessionContextBuilder` y `QueryComposer` no cambian de comportamiento: dejan de ver la línea cruda porque el job ya no la persiste, y el follow-up sólo ve `ActivePhotoContext` cuando la columna sanitiza.

---

## Verificación de esta ejecución

Tests focalizados y la suite que comparten, después:

```text
bin/rails turn_interpreter:eval
bin/rails turn_interpreter:holdout
git diff --check
```

Eval: `passes=21 mismatches=0 fallbacks=0 field_rejections=0`.

Holdout: `passes=10 mismatches=0 fallbacks=0 field_rejections=0`.

`git diff --check` PASS. `FieldPhotoPrompt::SYSTEM_BLOCKS` no se tocó. Fingerprint sigue `4f62491874c8fea82d78632657e9adc93da80c69e40157eee98b5cfe972715d1`.

Esta ejecución local no incluye `kamal deploy`, cambio de owner, smoke de producción ni rollback. T3 sigue fuera. F4 y F5 siguen `NOT STARTED`. Después del review, F1–F3 tienen un deploy y un resmoke de producción acotado a foto relevante.

```text
F1–F3 IMPLEMENTED LOCALLY — PRODUCTION PHOTO RESMOKE PENDING
F4 NOT STARTED
F5 NOT STARTED
```

Commit: `fix: gate photo consequences on accepted visual evidence`.

Archivos de producto: `FieldPhotoObservation` (`from_analysis` acotado, `accept!` con `stored` / `invalid` / `unavailable`), `FieldPhotoAnalysisJob` (`display_value` vs `evidence_value`), `ConversationSession#record_photo_observation!` (`:applied` / `:stale` / `:not_recording`), `PhotoQuestionAnswerService` (sólo `evidence_value`; ancla vacía si `unrelated`), `PilotUsageLog` (`field_photo_id` en el allowlist del evento `photo_observation_acceptance`). Los scripts de batería sólo cambian el keyword del servicio. `SessionContextBuilder`, `QueryComposer` y `FieldPhotoPrompt` no cambian.

Hallazgo de tests: dos tests del job stubbeaban `BedrockRagService#query` y no llegaban a ese stub (`Que es esto?` es `clarify_first`; una respuesta sin citas se reescribe a `rag.data_not_available`). Esos tests ahora stubbean `PhotoQuestionAnswerService#call` y afirman el contrato del job (historial `[FOTO]` aceptado y outcome sobre la respuesta del servicio, no sobre el texto de Vision).

Tests de esta ejecución, 0 failures:

```text
field_photo_observation_test: 16 runs, 98 assertions
field_photo_analysis_job_test: 43 runs, 406 assertions
conversation_session_test: 89 runs, 291 assertions
photo_question_answer_service_test: 26 runs, 102 assertions
active_photo_context_test: 7 runs, 69 assertions
session_context_builder_test: 44 runs, 214 assertions
query_composer_test: 4 runs, 40 assertions
conversation_session_turn_interpreter_test: 38 runs, 238 assertions
provenance_segmenter_test: 26 runs, 76 assertions
photo_observation_continuity_test: 15 runs, 159 assertions
field_photo_analysis_service_test: 9 runs, 91 assertions
field_photo_prompt_test: 10 runs, 59 assertions
real_gonzalo_photo_continuity_test: 2 runs, 43 assertions
conversation_session_case_ownership_test: 10 runs, 82 assertions
rag_controller foto observada: 2 runs, 8 assertions
```

---

## F4 — VisualTaskContext reemplaza a PhotoIntent

Documentado. No implementar ahora.

`Rag::VisualTaskContext` es una proyección determinística, acotada y tenant-safe. No es evidencia. Ruby no copia sus valores dentro de la candidate.

PhotoIntent es una frase heurística. Su prioridad sí se conserva, y después se retira la clase y su test. `PhotoIntentRenderer` se queda: es presentación.

Prioridad de `visual_task`, la misma de PhotoIntent hoy:

```text
pregunta / caption actual
→ último mensaje de usuario con target visual (STEMS, ventana del episodio)
→ goal con target visual
```

Pending no es fuente de `visual_task`. Si lo fuera, `PhotoIntentRenderer` antepondría "no estoy seguro… acércate" siempre que `target_visible` sea nil, casi en cada foto de un episodio.

Pending sí entra como contexto visible para Vision y como ancla de relevancia ("trabajo activo").

`visual_task` y el ancla de relevancia son cosas distintas. En `FieldPhotoAnalysisService`, `intent_sent?` se parte sólo en F4:

- `visual_task?` gobierna `target_visible`, `missing_view_or_detail`, "Objetivo visible" y el renderer
- `relevance_anchor?` gobierna `relevance_to_goal`

Relevancia, opción A, sin campos nuevos ni cambio de versión. `relevance_to_goal` dice si esta foto pertenece al trabajo técnico actual:

- si hay `visual_task`, se juzga contra esa tarea
- si no hay `visual_task`, se juzga contra el trabajo activo: goal, `equipment_context` o pending
- sin ninguna de esas anclas, Vision no la evalúa y Ruby la deja en nil (foto suelta sigue display-only)
- la lectura previa nunca es ancla
- `target_visible` sólo se evalúa si hay `visual_task`

Casos T1.1 que esta semántica tiene que seguir cumpliendo, medidos en el eval antes de desplegar F4:

- #30 y #31: placa del mismo equipo, sin texto, con pending de model o manufacturer → `relevant`, se escribe el fact, `close_photo_pending!` cierra sólo ese slot
- #32: sin cambio
- resorte con pending de controller: no hay orden visual; Vision describe el resorte; no se escribe slot; el pending queda

Schema mínimo. El JSON completo cabe en 1600 bytes. Drop order determinístico.

```text
schema_version: 1
mode: standalone | ongoing_episode
goal: máx. 240, desde ActiveEpisode.goal
equipment_context: manufacturer, model, controller, fault_code; 60 cada uno; facts known ya aceptados
observations: últimas 2 × 120, desde ActiveEpisode.observations
pending: sólo type
visual_task: text máx. 240, source question | recent_user_target | goal
```

`standalone` cuando el episodio sólo se abrió para recibir la foto y no tiene estado técnico significativo.

No incluir conversación completa, documentos, retrieval, manuales, prosa de Vision anterior, raw del modelo, valores rechazados ni instrucciones libres. No inventar `pending_visual_request`: no hay fuente durable. No hace falta un segundo enum `relation_to_visual_task`. `adds_new_evidence`, si algún día existe, se calcula en Ruby.

Prompt, sólo en F4. `FieldPhotoPrompt::SYSTEM_BLOCKS` queda idéntico byte a byte. La ingesta comparte esos bloques y `user_content` (`bulk_cost_v2_request_builder`, `single_file_chunking_service`). El fingerprint entra en la metadata de contrato y en cada `visual_observation`. Tocarlo modifica la ingesta.

`user_content(..., visual_task_context: nil)` reemplaza el bloque de intent únicamente cuando el contexto está presente, y sólo en el camino en vivo. Las reglas "context ≠ evidence" van en ese bloque de usuario, no en el system prompt. Test de F4: el fingerprint no cambia, y `user_content` sin contexto es igual al de hoy.

Ampliar el ancla al trabajo activo va a producir más `relevant` y más facts `source=photo` que hoy. Es intencional. Se mide en el eval antes del deploy de F4. No es parte de F1–F3.

---

## F5 — `previous_visual_evidence`

Documentado. No implementar ahora. No entra en el schema de F4 hasta esta fase.

Fuente única: `ActivePhotoContext.resolve(episode:, viewer_account:)`, sin loader nuevo. Sólo si el estado es `loaded`. La proyección ya está acotada a 640 bytes. Sigue sujeta al cap de 1600 del contexto completo.

Se excluye si:

- `field_photo_id` es el de la foto actual (reread)
- la relevancia es `unrelated`

Se incluye con `relevant`, `uncertain` o nil, etiquetada como lectura de una foto anterior: es contexto, no es visible en esta imagen.

Uso permitido: sólo contexto de entrada para Vision.

Uso prohibido:

```text
ancla de relevancia
fusionarla con la candidate
facts
query terms
Photo Evidence
```

Toda consecuencia de la foto 2 sale sólo de la Accepted Visual Observation de la foto 2.

---

## Diferido, fuera de F4 y F5

- pending visual request durable
- historial de varias fotos o visual sessions
- `adds_new_evidence`
- persistir en forma durable una lectura display-only rechazada
- cambio de schema o de versión si la telemetría después lo pide

Cuando el write está stale, la observación aceptada queda con la relevancia calculada contra el episodio anterior. `PhotoObservationContinuity` sólo reutiliza la `active_photo` del episodio vivo. No hace falta tratarlo en F1–F3.

---

## Handoff

```text
F1–F3 IMPLEMENTED LOCALLY — PRODUCTION PHOTO RESMOKE PENDING
F4 NOT STARTED
F5 NOT STARTED
```

F1–F3 se pueden desplegar solos, después de review, para cerrar el blocker. F4 y F5 no.

Siguiente paso: review y resmoke de producción acotado a foto relevante. Parar antes de F4.
