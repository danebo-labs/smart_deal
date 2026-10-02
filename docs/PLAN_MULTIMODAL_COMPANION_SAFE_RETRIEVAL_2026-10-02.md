# Multimodal Companion Safe Retrieval (2026-10-02)

**Estado:** `APPROVED ARCHITECTURE — IMPLEMENTATION NOT STARTED`

Source of truth de este bloque. Reconcilia el diagnóstico read-only del flow real Orona PBCM-V3, la surgical review de Codex y la revisión final de Opus (`PASS WITH REQUIRED CHANGES`). Donde Opus modifica o completa a Codex, manda Opus. Baseline de código: `d3909808a3508e83851f5475368fbd52d74c0e2a`.

F1–F3 no se reabren. Su registro histórico es [PLAN_VISUAL_EVIDENCE_HARDENING_2026-10-02.md](PLAN_VISUAL_EVIDENCE_HARDENING_2026-10-02.md). El master de Turn Interpreter no absorbe este plan: [PLAN_TURN_INTERPRETER_2026-10-01.md](PLAN_TURN_INTERPRETER_2026-10-01.md).

---

## Contrato de producto

```text
Danebo is not a manual search box.

The field companion maintains:
active problem
+ technician observations
+ accepted visual evidence
+ compatible manual evidence

and advances the diagnosis progressively.
```

Separación obligatoria de autoridad. Nunca se mezclan:

```text
MANUAL_FACT
VISUAL_OBSERVATION
DANEBO_GUIDANCE
```

`CONTEXT != EVIDENCE`. El contexto que entra a Vision no puede convertirse, por sí mismo, en manufacturer, model ni código visible. La única fuente visual de verdad sigue siendo la Accepted Visual Observation.

---

## Estado ya cerrado

```text
F1–F3 PRODUCTION VERIFIED — CLOSED
```

El resmoke de producción confirmó:

```text
photo_observation_acceptance = stored
FieldPhoto.visual_observation present
ActivePhotoContext loaded
reuse funciona
0 nueva llamada Vision en reuse
raw Vision no vuelve a facts/history/RAG
```

El blocker original (observación visual vacía) está cerrado. Lo que falló en el flow Orona empieza después de Accepted Visual Observation. Esos huecos no son F1–F3.

```text
F4  AS DESIGNED — implementación en este plan, fase N1
F5  DEFERRED
```

---

## Flow que motiva el plan

Caso real, congelado para el harness de N0. Sesión 128, cuenta danebo-legacy (id 1), usuario 3, episodio `ep_0a5037203043dc65`, `field_photo` 41, query `898f95ec-4b22-46d6-b440-e9add30faaee`.

```text
goal: no nivela en planta 3
foto: manufacturer = Orona, model = PBCM-V3
relevance_to_goal = nil
target_visible = nil
acceptance = stored
```

El turno de seguimiento fue `la consulta anterioir , de eso estoy hablando y por eso te comparti la foto`. TurnInterpreter lo clasificó `follow_up` / `ready` con `ActivePhotoContext` loaded. `PhotoObservationContinuity` eligió `:reuse`. No hubo Vision nueva. `PhotoQuestionAnswerService` entró al RAG anidado con `route_taken=photo_question_rag` y `execute_rag_query` sin `conv_session`. El retrieval quedó abierto. Los chunks publicados fueron Fuji Yida (p. 97) y BLT (p. 4). La generación enseñó esos procedimientos para un equipo visualmente identificado como Orona.

La consulta efectiva conservó el problema de nivelación y no incluyó Orona ni PBCM-V3. Photo Evidence sí llegó a la generación; no filtra retrieval. El catálogo autorizado de esa cuenta (`catalog_fingerprint=f7f5db2541ee`, 204 documentos) no tiene entradas Orona ni PBCM-V3. La frase de que no hay manual Orona coincide con ese catálogo. El plan tiene que ser seguro exista o no un manual compatible indexado.

Producto que salió:

```text
foto aislada + buscador documental
```

Producto que este plan fija:

```text
problema activo
+ evidencia visual nueva
+ diagnóstico progresivo
+ retrieval compatible con ese equipo
```

Causas, ya cerradas como diagnóstico. No reinvestigar producción.

- Vision no recibió el problema activo. Sin stem de `PhotoIntent`, `FieldPhotoAnalysisService` fuerza `relevance_to_goal=nil`. Eso es el objetivo de F4.
- Con relevancia distinta de `relevant`, `record_photo_observation!` no escribe manufacturer/model `source=photo`. F4, si la foto queda `relevant`, sí los promueve. No repara la observación ya guardada: `field_photo` 41 queda `relevance_to_goal=nil`.
- Aunque esos facts existieran, el RAG anidado no transporta el episodio. `DocumentIdentityScope` no corre. Codex tiene razón frente al diagnóstico en este punto: la falta de facts agrava la query y no explica el bypass.
- El guard de marca de `PhotoQuestionAnswerService` sólo aparece si la pregunta nombra una marca distinta de la foto. Esta pregunta no decía Orona.
- Los chunks ajenos estaban autorizados por corpus. Los guards de fidelidad verificaron respaldo documental, no compatibilidad de fabricante.
- F5 no aplica. La foto vigente ya se reutilizó.

---

## Arquitectura target

```text
Typed / photo turn
    ↓
ActiveEpisode
    ↓
VisualTaskContext                    [F4]
    ↓
Vision
    ↓
Candidate Visual Observation
    ↓
Accepted Visual Observation
    ↓
record_photo_observation!
    ↓
PhotoTurnContext                    [post-photo immutable snapshot]
    ├── equipment_identity
    ├── retrieval_question
    ├── session_context_snapshot
    └── entity_s3_uris
    ↓
PhotoQuestionAnswerService
    ↓
execute_rag_query(
  retrieval_question:,
  equipment_identity:
)
    ↓
COMMON equipment compatibility policy
    ↓
DocumentIdentityScope
    ├── :scoped
    ├── :no_compatible
    └── :unavailable
    ↓
generation
```

```text
NO conv_session transport to nested RAG
NO second Vision
NO second TurnInterpreter
NO live episode read after snapshot
```

Pasar `conv_session` al `execute_rag_query` anidado reactiva `FollowupQueryRewriter`, el thread menu, `entity_sources` leídos en vivo y el locale de la sesión. El transporte es un parámetro explícito.

Camino de texto, la misma policy:

```text
episode live → EquipmentIdentity → policy
```

Camino de foto:

```text
PhotoTurnContext snapshot → EquipmentIdentity → same policy
```

Ningún caller se salta la policy por no pasar sesión.

---

## F4 — VisualTaskContext

`F4 AS DESIGNED`. La spec histórica permanece en el plan de visual evidence. Este documento es el source of truth de implementación.

Objetivo:

```text
ActiveEpisode → bounded VisualTaskContext → Vision
```

Vision debe conocer:

```text
goal
equipment context
observations
pending context when relevant
visual task when it exists
previous visual context later if applicable
```

`previous_visual_evidence` sigue sin implementarse en este release. F5 queda deferred.

`Rag::VisualTaskContext` es una proyección determinística, acotada y tenant-safe. No es evidencia. Ruby no copia sus valores dentro de la candidate. Las reglas `context ≠ evidence` van en `user_content`, no en `FieldPhotoPrompt::SYSTEM_BLOCKS`. Esos bloques quedan idénticos byte a byte. El fingerprint registrado en el plan de F1–F3 (`4f62491874c8fea82d78632657e9adc93da80c69e40157eee98b5cfe972715d1`) no se mueve. `user_content` sin contexto queda igual al de hoy. La ingesta comparte esos bloques.

Schema bounded. El JSON cabe en 1600 bytes. Drop order determinístico.

```text
schema_version: 1
mode: standalone | ongoing_episode
goal: máx. 240, desde ActiveEpisode.goal
equipment_context: manufacturer, model, controller, fault_code; 60 cada uno; facts known ya aceptados
observations: últimas 2 × 120, desde ActiveEpisode.observations
pending: sólo type
visual_task: text máx. 240, source question | recent_user_target | goal
previous_visual_evidence: reservado; no se implementa en este release
```

`standalone` cuando el episodio sólo se abrió para recibir la foto y no tiene estado técnico significativo.

No incluir conversación completa, documentos, retrieval, manuales, prosa de Vision anterior, raw del modelo, valores rechazados ni instrucciones libres. No inventar `pending_visual_request`. No hace falta un segundo enum `relation_to_visual_task`.

Prioridad de `visual_task`, la misma de `PhotoIntent` hoy:

```text
pregunta / caption actual
→ último mensaje de usuario con target visual (STEMS, ventana del episodio)
→ goal con target visual
```

Pending no es fuente de `visual_task`. Si lo fuera, `PhotoIntentRenderer` antepondría "acércate" siempre que `target_visible` sea nil. `PhotoIntentRenderer` se queda: es presentación. Se retiran `Rag::PhotoIntent` y su test.

`visual_task` y el ancla de relevancia son cosas distintas. En `FieldPhotoAnalysisService` se parten sólo en F4:

- `visual_task?` gobierna `target_visible`, `missing_view_or_detail`, "Objetivo visible" y el renderer
- `relevance_anchor?` gobierna `relevance_to_goal`

Relevancia, sin campos nuevos ni cambio de versión:

```text
if visual_task exists:
  use visual_task as primary relevance anchor

else if active work exists:
  judge against goal / equipment context / pending

else:
  relevance_to_goal=nil
```

Sin ancla, la foto suelta sigue display-only. La lectura previa nunca es ancla. `target_visible` sólo se evalúa si hay `visual_task`. No confundirlo con relevance.

Caso obligatorio de este flow:

```text
goal = "no nivela en planta 3"
photo = controller plate Orona PBCM-V3
```

puede resultar:

```text
relevance_to_goal = relevant
target_visible = nil
```

aunque `goal` no contenga un visual stem. El renderer no antepone "acércate".

Casos T1.1 que esta semántica tiene que seguir cumpliendo, en el eval antes de cualquier deploy:

- #30 y #31: placa del mismo equipo, sin texto, con pending de model o manufacturer → `relevant`, se escribe el fact, `close_photo_pending!` cierra sólo ese slot
- #32: sin cambio
- resorte con pending de controller: no hay orden visual; Vision describe el resorte; no se escribe slot; el pending queda

Ampliar el ancla al trabajo activo va a producir más `relevant` y más facts `source=photo`. Es intencional. Se mide en el eval. F4 no repara observaciones ya guardadas y no toca el RAG anidado. F4 sola no se despliega.

---

## F5

```text
F5 DEFER
```

`previous_visual_evidence` no entra en el schema implementado. La foto vigente de este flow ya se localizó y reutilizó sin Vision. F5 sólo cambiaría el input de una llamada Vision nueva. La spec histórica sigue en el plan de visual evidence. No implementarla en este release.

---

## PhotoTurnContext — snapshot post-Vision

El snapshot de retrieval se construye después de Accepted Visual Observation, bajo el mismo lock que ya congela `session_context` y `entity_s3_uris` (`ConversationSession#capture_photo_turn_context`, llamado desde `record_photo_assistant_context!`).

Hoy:

```text
PhotoTurnContext = status, session_context, entity_s3_uris
```

Se extiende sólo con dos campos derivados:

```text
equipment_identity
retrieval_question
```

No usar `VisualTaskContext` para retrieval. Se arma antes de Vision y no tiene la identidad que la foto acaba de aceptar.

No guardar:

```text
full ActiveEpisode
full history
raw Vision
pending completo
arbitrary instructions
```

`equipment_identity` es el resultado ya resuelto, no el JSON del episodio. `retrieval_question` es el string acotado ya compuesto. Goal y observaciones sólo sirven para componer. Pending no entra a retrieval.

Después del snapshot no se lee el episodio vivo. Si el episodio cambia durante el worker, se usa el snapshot y el write tardío sigue descartándose por `expected_episode_id`.

---

## EquipmentIdentity

Value object / proyección acotada. Sólo lo que la policy necesita:

```text
manufacturer
needles
provenance/source metadata required by policy
```

La policy actual exige, por fact, `source` y `correlation_id` (`DocumentIdentityScope.match_needles`, `NEEDLE_SOURCES = user | photo`). El snapshot guarda ese resultado.

Identidad conocida cuando existe:

```text
manufacturer
or
model
```

con fuente confiable:

```text
user
photo
```

Para una pregunta ligada a foto también puede usarse la identidad de la Accepted Visual Observation de esa foto:

```text
unless relevance_to_goal == unrelated
```

Eso cubre observaciones legacy con `relevance_to_goal=nil`, como el flow Orona. No se reescribe la observación ni se finge que era `relevant`. Esa identidad es efímera: no se escribe al episodio.

No es identidad suficiente, y no vuelve restrictivo el retrieval:

```text
fault_code
controller alone
catalog-derived guess
generic identifier
```

No agregar heurísticas nuevas. Si manufacturer y model son desconocidos:

```text
OPEN SEARCH remains legitimate
```

`DocumentIdentityScope.applicable?` sigue siendo falso en ese caso. La regla de manual análogo de `AGENTS.md` sigue aplicando sólo ahí, hasta el cambio doctrinal de la fase de implementación.

---

## retrieval_question

Se compone una sola vez, en determinístico, sin LLM adicional y sin history completo.

Inputs mínimos:

```text
literal/current turn
active goal
recent bounded observations
fault_code/controller if useful
accepted equipment identity
```

Dos casos.

Reuse / follow-up. F4 puede hacer que un turno posterior lleve los facts a `QueryComposer`. El snapshot igual tiene que poder componer:

```text
"la consulta anterior... la foto"
+ goal no nivela planta 3
+ Orona PBCM-V3
```

Foto + pregunta en el mismo turno. Con imágenes no corren `TechnicalUnderstanding` ni la composición inicial (`RagQueryConcern`). El job recibe el texto crudo. La identidad aparece después de Vision. El RAG anidado construye:

```text
active problem
+ literal question
+ new accepted photo identity
```

sin asumir que `QueryComposer` ya corrió. No segundo TurnInterpreter. No segunda Vision.

El ancla de catálogo de `anchor_suffix` no es el mecanismo de seguridad. Si PBCM-V3 no está catalogado, no hay manual que encontrar. La seguridad la da el scope. `anchor_suffix` no cambia en este plan.

---

## Una sola compatibility policy

No crear una policy de manufacturer para texto y otra para foto.

```text
ONE equipment/document compatibility policy
MULTIPLE callers
```

`DocumentIdentityScope` es la base. Evoluciona para aceptar `EquipmentIdentity` en lugar de depender exclusivamente del episodio o de la sesión.

Con identidad conocida, la policy entra en modo requerido. En ese modo se saltan las terminales que no aplican la policy (`AmbiguousModelResponder`, `DocumentOverviewResponder`, HYBRID). El camino de texto usa la misma semántica fail-closed. El fallback abierto es un defecto de la policy, no del caller.

---

## DocumentIdentityScope — outcomes

Se elimina `nil = fallback`.

```text
:scoped
:no_compatible
:unavailable
```

### scoped

Existe evidencia compatible. El nombre, archivo o `section_identity` del chunk contiene un needle. Cuerpo completo, label `THIS JOB'S EQUIPMENT`, citable como `MANUAL_FACT`.

Procedural body permitido sólo para chunks compatibles.

### no_compatible

Retrieval terminó correctamente y no existe body compatible. Incluye retrieval vacío y el caso en que todo chunk queda reference-only.

```text
NO open fallback
```

No es fallo técnico.

### unavailable

El camino de scope o de identidad falló:

```text
timeout
AWS error
empty generation caused by failure
scope feature unavailable
snapshot ausente en la foto con identidad conocida
flag apagada con identidad conocida
```

```text
NO open fallback
```

El contrato de seguridad no depende de `DOCUMENT_IDENTITY_SCOPE_ENABLED`. `config/deploy.yml` está gitignored: la flag se verifica antes del deploy, y apagada con identidad conocida es `:unavailable`.

---

## Fail-closed

Con identidad conocida:

```text
equipment = Orona PBCM-V3
```

queda prohibido:

```text
identity path fails → retrieve_and_generate open
```

Eso incluye timeout, error, resultado vacío, ningún chunk compatible y scope flag disabled. No volver a Yida/BLT procedural por fallback.

Hoy el camino abierto sigue vivo en tres sitios de [app/services/bedrock_rag_service.rb](../app/services/bedrock_rag_service.rb), además del `unchanged` de [app/services/rag/document_identity_scope.rb](../app/services/rag/document_identity_scope.rb) cuando todos los labels quedan vacíos:

- retrieval sin labels → `return nil` y cae a `retrieve_and_generate`
- generación vacía → fallback abierto
- timeout / error AWS → fallback abierto

N4 los cierra en modo requerido, en foto y en texto.

---

## Sin manual compatible no es "no puedo ayudar"

Si el equipo es conocido y no hay manual compatible, Danebo continúa con:

```text
Accepted Visual Observation
technician observations
active problem
generic field reasoning
```

como `DANEBO_GUIDANCE`.

No puede inventar:

```text
parameters
terminal functions
fault-code semantics
manufacturer-specific steps
```

Guion que la arquitectura tiene que poder publicar, sin inventar hechos:

- el problema activo sale del snapshot ("no nivela en planta 3")
- "la foto identificó un Orona PBCM-V3" es `VISUAL_OBSERVATION`
- "no tengo manual compatible; no voy a aplicarte Yida/BLT" es `:no_compatible`: nombra el documento ajeno sin usar su cuerpo
- "primero comprobaría… si me muestras X seguimos" es `DANEBO_GUIDANCE`, sin valores inventados

---

## Contrato de generación

Los tres bandos ya existen en `ProvenanceSegmenter`. No se diseña un segmenter nuevo.

### MANUAL_FACT

Puede contener steps, parameters, values, terminal functions y fault-code meanings sólo si está respaldado por un chunk compatible citable. En el futuro, `GENERAL REFERENCE` se atribuye a ese documento, nunca como instrucción del fabricante. No puede venir de un chunk reference-only.

### VISUAL_OBSERVATION

Sólo component, manufacturer, model, visible text y visible condition, desde la Accepted Visual Observation de ese turno. No inferir función de entradas, estados ni conexiones no visibles.

### DANEBO_GUIDANCE

Puede contener diagnostic sequencing, what to inspect next, what observation to obtain, what photo to request, y generic reasoning based on symptoms. Se presenta como criterio de Danebo. No se atribuye al fabricante. No mete valores específicos sin evidencia.

### FOREIGN MANUFACTURER PROCEDURE

Puede decir:

```text
"hay documentación Yida/BLT, pero no aplica a este Orona"
```

No puede dar steps, parameters, codes ni values, ni usar imperativo de procedimiento ("según Yida, haz X"), ni citas `[n]`.

`brand_component_mismatch` en `PhotoQuestionAnswerService` deja de ser la defensa de seguridad. La defensa es la policy.

---

## Reference-only no es citable

Obligatorio. Hoy un chunk reference-only todavía puede citarse: `document_identity_citation_records` incluye todos los chunks. Si generation pone un `[n]` hacia Yida, `ProvenanceSegmenter` lo clasifica como `MANUAL_FACT`.

Con identity scope activo:

```text
incompatible chunk
→ identity/reference-only
→ not citable
→ cannot produce MANUAL_FACT
```

No basta con ocultar el body y dejar el citation record. El pipeline de citas lo excluye.

---

## Documentos genéricos y multimarca

MVP estricto. No inferir:

```text
document has no manufacturer → generic
```

Un documento sin marca explícita puede ser el manual de otro equipo. "Placa S1000_A" no nombra fabricante y no es referencia genérica.

```text
if chunk/document matches equipment needle:
  compatible
otherwise:
  reference-only
```

Excepción futura, deferred: `generic: true` ya existe en `config/document_identities.yml` (dos documentos). Consumirla puede diferirse: el catálogo no se consulta en el camino de query. Si más adelante se habilita, el label es `GENERAL REFERENCE`, soporta seguridad e inspección genérica, se cita como ese documento y nunca como instrucción del fabricante.

Un documento multimarca que realmente contiene el needle puede contar compatible. Riesgo residual aceptado para MVP.

---

## Document Focus

No cambiar ownership de Focus.

```text
tenant authorization
>
equipment compatibility
>
Document Focus
>
explicit comparison intent (deferred)
```

Document Focus decide dónde se busca. Equipment identity decide si el contenido recuperado aplica a este equipo.

```text
equipment = Orona
pinned = Fuji manual
```

Si la identidad del pin contiene una marca de `KbDocumentResolver::BRANDS` distinta del manufacturer conocido, el chunk es reference-only. El pin permanece seleccionado. No auto-unpin. No ampliar la búsqueda fuera del Focus.

Si el documento fijado coincide con el needle, es `THIS JOB'S EQUIPMENT`.

Pin neutral: se mantiene el comportamiento existente (`THIS JOB`), mientras no haya evidencia clara de conflicto. No romper la regresión equivalente a `d9050ba`, donde el pin compensa huecos del match por nombre.

La autorización de tenant sigue en `KnowledgeScopePolicy`. Este plan no la amplía ni la relaja.

---

## Comparación explícita

```text
DEFER
```

No implementar detección de "compárame Orona con Fuji". Un pin en conflicto queda reference-only y la respuesta lo dice. Cuando llegue, TurnInterpreter emite la intención. No regex. El cuerpo entraría con un label descriptivo, nunca como `THIS JOB`.

---

## Mismo turno: foto + pregunta

Caso explícito:

```text
active problem exists
technician sends photo + question
```

Antes de Vision: `VisualTaskContext`.

Después de Vision:

```text
Accepted Visual Observation
+ post-photo EquipmentIdentity
+ active problem
→ retrieval_question
```

El RAG anidado usa esos snapshots. Una llamada Vision. Cero TurnInterpreter extra. No asumir el `QueryComposer` inicial.

---

## Reuse legacy

El flow real tiene `relevance_to_goal=nil` porque se analizó antes de F4. El reuse no vuelve a juzgar la foto.

Si la pregunta está ligada a esa foto, la identidad aceptada de la foto activa entra a la policy:

```text
unless unrelated
```

sin reescribir la observación. Obligatorio en tests: el mismo resultado de seguridad que el flow con `relevant`.

Foto `uncertain` o `unrelated`: no promueve identidad al episodio y no cierra el corpus por esa foto. `unrelated` no aporta identidad efímera. Sin identidad conocida por otra fuente, la búsqueda abierta permanece.

---

## Contrato de fallo

### No compatible docs

```text
:no_compatible
```

Una generación con la evidencia visual aceptada y el snapshot de contexto:

```text
visual identity
+ active problem
+ Danebo guidance
+ "No tengo manual compatible"
```

Sin citas manufacturer-specific. Sin procedimiento extranjero.

### Identity gate timeout / error

```text
:unavailable
```

Nunca `retrieve_and_generate` abierto.

Foto: se reutiliza el camino `rag_answer[:failed]`. Se publica la lectura visual ya pagada más "no pude consultar documentación ahora", sin procedimiento.

Texto: la abstención técnica existente.

### Retrieval empty

```text
:no_compatible
```

No es fallo técnico. No hay fallback abierto. En la matriz de tests, "empty" de timeout/error/generación vacía es `:unavailable`. El retrieval que termina sin chunks compatibles es `:no_compatible`.

### Scope disabled o no disponible, con identidad conocida

```text
:unavailable
```

Incluye la flag apagada y el snapshot ausente en la foto.

---

## Answer safety

`:no_compatible` tiene que permitir `VISUAL_OBSERVATION` y `DANEBO_GUIDANCE` sin que `require_cited_evidence` convierta toda la respuesta en `uncited_technical_answer`.

Valores, terminales y códigos que no estén en la Accepted Visual Observation ni en evidencia de manual compatible se eliminan. Usar los patrones existentes de `AnswerSafetyProcessor`, con la observación como evidencia. No diseñar un safety subsystem nuevo. `ProvenanceSegmenter` no cambia de dueño.

---

## Cambio doctrinal

Requisito de la implementación, no de este commit.

[AGENTS.md](../AGENTS.md) (principio Safety First, procedimiento análogo con disclaimer) permite hoy usar un procedimiento de otro manual como referencia de campo. Cuando la identidad de equipo es conocida, esa doctrina cambia:

```text
known equipment:
  foreign manual may be named
  but its procedure cannot be taught as applicable

unknown equipment:
  open analogous/manual-assisted search may continue
  with existing disclaimers
```

No editar `AGENTS.md` en el commit documental. Cambia junto con la implementación, para que el siguiente agente no reabra la regla vieja con identidad conocida.

---

## Fases

Un solo release. No hay código funcional antes del harness.

### N0 — Production-flow regression harness

Congelar el flow Orona PBCM-V3, goal "no nivela en planta 3", reuse, legacy `relevance_to_goal=nil`, y el caso same-turn foto+pregunta. Los tests nacen rojos contra el código de `d390980`. No código funcional primero.

### N1 — F4 VisualTaskContext

Implementar F4 as-designed. Eval obligatorio: goal sin stem visual + placa Orona → `relevant`, más #30, #31 y #32. Fingerprint unchanged. Agregar `app/services/rag/visual_task_context.rb`. Retirar `app/services/rag/photo_intent.rb` y `test/services/rag/photo_intent_test.rb`. `PhotoIntentRenderer` permanece.

### N2 — Post-photo retrieval snapshot

Extender `PhotoTurnContext` con `equipment_identity` y `retrieval_question`, capturados bajo el lock después de la observación aceptada. No episodio completo.

### N3 — Common EquipmentIdentity policy

`DocumentIdentityScope` acepta `EquipmentIdentity`, devuelve `:scoped` / `:no_compatible` / `:unavailable`, y es la misma policy para texto y foto. El caller de texto la deriva del episodio vivo. El de foto la toma del snapshot.

### N4 — Fail-closed retrieval + citation safety

Cerrar fallback de resultado vacío, timeout, error, generación vacía y scope disabled. Excluir chunks reference-only de las citas. En modo requerido, no entran las terminales que no aplican la policy.

### N5 — Companion no-compatible generation

Soportar Visual Observation + Danebo Guidance + "no tengo manual compatible", sin procedimiento extranjero y sin convertir la respuesta en `uncited_technical_answer`. Bloque de usuario; no tocar `SYSTEM_BLOCKS`.

### N6 — Integrated regression / eval

Flow real, same-turn, identidad desconocida, manual compatible, pins, episodio stale, tenant scoping, `turn_interpreter:eval` y holdout.

---

## Release boundary

```text
N0 N1 N2 N3 N4 N5 N6
```

son un solo release boundary. No desplegar sólo F4.

```text
REVIEW → DEPLOY → PROD MULTIMODAL SMOKE
```

---

## Matriz de tests

Bloquean el deploy.

1. Replay del flow de producción: Orona PBCM-V3, "no nivela en planta 3", reuse. Needles Orona/PBCM-V3. Yida/BLT reference-only. 0 `MANUAL_FACT` extranjero. 0 llamadas Vision. Bandos `VISUAL_OBSERVATION` y `DANEBO_GUIDANCE` presentes.
2. El mismo caso con observación legacy `relevance_to_goal=nil` da el mismo resultado de seguridad, sin reescribir la observación.
3. Mismo turno, foto + pregunta, con goal activo. `retrieval_question` anidada contiene goal + identidad aceptada. 1 Vision. 0 TurnInterpreter extra.
4. Manual Orona compatible stubbeado: cuerpo retenido, citas permitidas, `MANUAL_FACT` desde ese documento.
5. Identidad conocida y ningún manual compatible, incluido retrieval que termina vacío: `:no_compatible`. 0 llamadas a `retrieve_and_generate`.
6. Timeout, error AWS o generación vacía causada por fallo del identity path: `:unavailable`. 0 fallback abierto. En foto, camino `failed` con la lectura visual ya pagada y sin procedimiento. El mismo cierre en texto.
7. Un `[n]` a un chunk reference-only no aparece en las citas y no produce `MANUAL_FACT`.
8. En `:no_compatible`, una línea con valor o terminal ausente de la observación visual se elimina.
9. Identidad desconocida: retrieval abierto, sin cambios.
10. Foto `unrelated`: esa foto no aporta identidad a la policy.
11. Pin Fuji con Orona conocido: Fuji reference-only. Focus no cambia. No auto-unpin. No se amplía la búsqueda.
12. Pin neutral: comportamiento existente, `THIS JOB`. Regresión equivalente a `d9050ba`.
13. El episodio cambia durante el worker: se usa el snapshot y el write tardío se descarta.
14. Autorización de tenant sin cambios. El scoping no se amplía.
15. Eval F4: #30, #31, #32 y el flow Orona (goal sin stem + placa) → `relevant`. Fingerprint sin cambios.

El "empty" del ítem 6 es generación vacía o fallo del camino de identidad. El retrieval que termina sin chunks compatibles es el ítem 5. `uncertain` no promueve identidad al episodio; si no hay otra identidad conocida, la búsqueda abierta permanece. Reuse del ítem 1 sigue en 0 llamadas Vision. `turn_interpreter:eval` y holdout entran en N6 y no pueden regresionar.

---

## Límites de archivos

Este commit no los toca. Son el CHANGE esperado de la implementación.

```text
app/models/conversation_session.rb
app/jobs/field_photo_analysis_job.rb
app/services/rag/photo_question_answer_service.rb
app/controllers/concerns/rag_query_concern.rb
app/services/query_orchestrator_service.rb
app/services/rag/document_identity_scope.rb
app/services/bedrock_rag_service.rb
app/services/rag/structured_evidence_route.rb
app/services/rag/context_evidence_route.rb
generation user-context block
AGENTS.md
tests
```

Detalle que Opus fijó y Codex no tenía completo:

- `conversation_session.rb`: `PhotoTurnContext` gana `equipment_identity` y `retrieval_question` dentro de `capture_photo_turn_context`.
- `field_photo_analysis_job.rb`: el texto crudo del turno entra a la composición post-foto; no recomponer encima de un string ya compuesto. `:unavailable` va al camino `failed`.
- `photo_question_answer_service.rb`: reenvía el snapshot. `brand_component_mismatch` deja de ser la defensa.
- `rag_query_concern.rb`: acepta y reenvía `equipment_identity:`. `retrieval_question:` ya existe.
- `query_orchestrator_service.rb`: identidad por parámetro o desde el episodio vivo. En modo requerido se saltan las terminales que no aplican la policy.
- `document_identity_scope.rb`: input `EquipmentIdentity`, outcome explícito, conflicto de marca en el pin, flag de no citable.
- `bedrock_rag_service.rb`: quitar los fallbacks abiertos en modo requerido, agregar `:no_compatible`, excluir reference-only de las citas.
- `structured_evidence_route.rb` y `context_evidence_route.rb`: cambia la firma; consumen `EquipmentIdentity`.
- Prompt de generación: bloque de usuario "no compatible manual". `SYSTEM_BLOCKS` intacto.
- `AGENTS.md`: la regla de analogía, en el commit de implementación.

ADD durante N1:

```text
app/services/rag/visual_task_context.rb
```

REMOVE durante N1:

```text
app/services/rag/photo_intent.rb
test/services/rag/photo_intent_test.rb
```

`PhotoIntentRenderer` y su test se quedan.

NO CHANGE:

```text
FieldPhotoPrompt / SYSTEM_BLOCKS
FieldPhotoObservation
ActivePhotoContext
PhotoObservationContinuity
TurnInterpreter
KnowledgeScopePolicy
config/document_identities.yml
Document Focus model
ProvenanceSegmenter
anchor_suffix
KB ingestion
```

---

## No tocar

No crear:

```text
DB tables
migrations
visual session table
LLM calls
Vision model
TurnInterpreter architecture
Document Focus model
KnowledgeScopePolicy
KB ingestion
second Vision pass
second TurnInterpreter
previous_visual_evidence
```

No modificar `FieldPhotoPrompt::SYSTEM_BLOCKS`. F5 permanece deferred.

---

## Costo y complejidad

Sigue siendo MVP / piloto. No convertirlo en taxonomía, ontología de fabricantes, workflow engine ni memoria multi-foto.

Preferir:

```text
bounded value objects
explicit outcomes
reuse existing policy
deterministic gates
```

Cero llamadas Vision nuevas en reuse. Cero TurnInterpreter extra en el RAG de foto. Cero LLM para componer `retrieval_question`.

---

## Dónde Opus completa a Codex

Queda registrado para no reabrir la versión anterior de la propuesta.

- Extender `PhotoTurnContext` bajo lock: confirmado, con sólo los dos campos derivados.
- Transportar el snapshot: parámetro explícito, nunca `conv_session`.
- Reutilizar `DocumentIdentityScope`: confirmado, con input `EquipmentIdentity` y outcome explícito, también en texto.
- Fail-closed: confirmado, y además el fallback de retrieval vacío, la exclusión de citas reference-only y el salto de terminales que no aplican la policy.
- Identidad de la pregunta ligada a foto: la observación aceptada cuenta salvo `unrelated`, incluida `relevance_to_goal=nil`. No se escribe al episodio. En el mismo turno hoy no hay composición inicial.
- Pin extranjero: reference-only sólo ante conflicto de marca. Pin neutral se mantiene.
- Flag apagada con identidad conocida: `:unavailable`.
- El RAG anidado ignora la identidad aunque el episodio ya tenga facts. Confirmado.
- F4 as-designed. F5 deferred. F4 no se despliega sola.
- `AGENTS.md` cambia con la implementación, no en este commit.

---

## Handoff

```text
APPROVED ARCHITECTURE — IMPLEMENTATION NOT STARTED
```

F1–F3 están cerrados en el plan anterior. F4 se implementa aquí, dentro de N0–N6. F5 no entra.

Siguiente paso: review de este plan y, recién entonces, implementación. No deploy parcial.
