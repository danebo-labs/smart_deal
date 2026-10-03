# Multimodal Companion Safe Retrieval (2026-10-02)

**Estado:** `N0 COMPLETE — N1 IMPLEMENTED LOCALLY — N2 IMPLEMENTED LOCALLY — N3 IMPLEMENTED LOCALLY — N4 IMPLEMENTED LOCALLY — N5 IMPLEMENTED LOCALLY — N6 IMPLEMENTED LOCALLY — NOT PRODUCTION VERIFIED`

**N0:** `N0 COMPLETE`

**N1:** `N1 IMPLEMENTED LOCALLY — NOT PRODUCTION VERIFIED`

**N2:** `N2 IMPLEMENTED LOCALLY — NOT PRODUCTION VERIFIED`

**N3:** `N3 IMPLEMENTED LOCALLY — NOT PRODUCTION VERIFIED`

**N4:** `N4 IMPLEMENTED LOCALLY — NOT PRODUCTION VERIFIED`

**N5:** `N5 IMPLEMENTED LOCALLY — NOT PRODUCTION VERIFIED`

**N6:** `N6 IMPLEMENTED LOCALLY — NOT PRODUCTION VERIFIED`

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

Promoción al episodio y identidad efímera de una photo-question son dos cosas distintas.

A. Promoción al episodio. Sólo `relevant` puede escribir manufacturer/model `source=photo`.

```text
relevant  → puede promover manufacturer/model source=photo
nil       → no promueve
uncertain → no promueve
unrelated → no promueve
```

B. `EquipmentIdentity` efímera para una pregunta ligada a esa foto. La identidad aceptada de la foto entra a la policy salvo `unrelated`.

```text
relevant  → sí
nil       → sí, si la pregunta está ligada a esa foto
uncertain → sí, si la pregunta está ligada a esa foto
unrelated → no
```

El flow legacy Orona, `relevance_to_goal=nil`, es caso obligatorio de B: aporta identidad efímera y no se reescribe como `relevant`.

```text
Ephemeral EquipmentIdentity is a retrieval-safety input only. It does not rewrite relevance, does not promote facts, and does not mutate the episode.
```

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

`nil` y `uncertain` no promueven facts. Si la pregunta está ligada a esa foto, los dos sí aportan `EquipmentIdentity` efímera y la policy fail-closed corre igual. `unrelated` no aporta esa identidad. Sin manufacturer/model conocido por el usuario, por el episodio o por esa foto ligada, la búsqueda abierta permanece.

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

```text
N0 COMPLETE
```

El harness sigue en la suite. Los contratos futuros viven ahí y quedan en skip salvo `N0_CONTRACTS=1`. El mensaje de skip es `N0 contract — expected to become green in N<fase>`. Cada test skipped contiene los asserts del contrato, no un placeholder. Después de N3, los tres contratos N2 y el de N3 pasan con `N0_CONTRACTS=1`. Los dos de N4 siguen rojos.

Invariantes que quedan verdes en la suite:

- `legacy nil photo reuse keeps the stored relevance and does not call vision`: reuse, 0 Vision, `relevance_to_goal` sigue nil, no hay facts `source=photo`.
- `unrelated accepted photo does not constrain retrieval identity`: la foto no promueve facts y no aporta identidad de retrieval. La búsqueda abierta sigue siendo legítima.
- `same-turn photo question keeps the literal question until after vision`: el enqueue lleva la pregunta literal y 0 TurnInterpreter. La composición no ocurre antes de Vision.
- Siguen verdes los invariantes ya cubiertos: observación aceptada persistida, reuse sin Vision, write stale, scope de tenant, y `unrelated` que no promueve facts.

Contratos N2, verdes con `N0_CONTRACTS=1` después de este snapshot:

- `legacy photo reuse carries accepted equipment identity into retrieval` — identidad efímera Orona/PBCM-V3 y `retrieval_question` con el goal. 0 Vision. `relevance_to_goal` sigue nil. No hay facts nuevos.
- `same-turn photo question composes retrieval after accepted visual identity` — la query anidada lleva la pregunta literal, el goal y Orona/PBCM-V3. 1 Vision. 0 TurnInterpreter extra.
- `uncertain accepted photo may constrain photo-question retrieval without promoting facts` — no promueve facts y sí aporta identidad efímera.

Contrato N3, verde con `N0_CONTRACTS=1` después de esta policy:

- `foreign manufacturer chunks are reference-only for known equipment` — la identidad Orona/PBCM-V3 llega a `DocumentIdentityScope`. Yida/BLT quedan reference-only y pierden el cuerpo en el prompt de scope. No cierra el fallback abierto ni la respuesta final.

Contratos que siguen rojos. Ninguno pasó por accidente:

- `known equipment photo retrieval does not fall open onto a foreign procedure` — N4. Con identidad conocida, el camino sigue en `retrieve_and_generate` abierto (`open_calls` 1).
- `foreign manufacturer chunks cannot create manual fact` — N4. Aunque el scope ya quite el cuerpo, el chunk Yida/BLT sigue siendo citable y puede producir `MANUAL_FACT`.

### N1 — F4 VisualTaskContext

```text
N1 IMPLEMENTED LOCALLY — NOT PRODUCTION VERIFIED
```

F4 quedó implementado en local sobre `c5eea86`. No es verificación de producción y no se despliega solo.

- `Rag::VisualTaskContext` reemplaza `Rag::PhotoIntent`. Es determinístico: sin LLM, sin writes y sin retrieval. `previous_visual_evidence` no se emite.
- Tope serializado: 1600 bytes. `goal` 240. `equipment_context` manufacturer/model/controller/fault_code, 60 cada uno, sólo facts `known`. Observaciones: las últimas 2, 120 cada una. `pending` es sólo `type` de un fact técnico. `visual_task.text` 240. Orden de recorte: observaciones (la más vieja primero), luego `fault_code`, `controller`, `model`, `manufacturer`, luego `pending`, luego `goal`, luego el texto de `visual_task`. `schema_version` y `mode` no se recortan. El modo se decide antes del recorte y no se recalcula.
- `standalone` cuando el episodio no tiene goal, facts conocidos, observaciones ni pending técnico. Un `visual_task` solo no vuelve el episodio ongoing. `ongoing_episode` cuando hay alguno de esos cuatro.
- Precedencia de `visual_task`: pregunta o caption actual, sin filtro de léxico; si no, el mensaje de usuario más nuevo dentro de la ventana del episodio que tenga un stem visual (`recent_user_target`); si no, el goal si tiene stem (`goal`). `pending` no crea `visual_task`.
- `visual_task?` controla `target_visible`, `missing_view_or_detail`, "Objetivo visible" y `PhotoIntentRenderer`. `relevance_anchor?` (`visual_task?` o `ongoing_episode?`) controla `relevance_to_goal`. Sin visual task y con trabajo activo, la foto puede ser `relevant`, `uncertain` o `unrelated`, y `target_visible` queda nil. Sin trabajo activo, `relevance_to_goal` queda nil.
- El bloque de `user_content` para trabajo activo dice que una pieza, placa, display o conjunto de ese trabajo es `relevant` aunque la falla no esté en cuadro. `CONTEXT != EVIDENCE`: Ruby no copia manufacturer, model, código, condición ni texto visible desde el contexto.
- `PhotoIntentRenderer` permanece. No quedan referencias de producción a `Rag::PhotoIntent`. Se retiraron `app/services/rag/photo_intent.rb` y `test/services/rag/photo_intent_test.rb`.
- `FieldPhotoPrompt::SYSTEM_BLOCKS` no cambió. Fingerprint `4f62491874c8fea82d78632657e9adc93da80c69e40157eee98b5cfe972715d1`. El contexto entra sólo en `user_content`. `user_content` sin ancla sigue igual que la ingesta.
- TurnInterpreter, TurnPerception, RoutePolicy, WorkContextReducer y QueryComposer no se tocaron. No hizo falta adaptar firmas: el job ya tenía la pregunta, el episodio y el historial. DocumentIdentityScope, EquipmentIdentity, PhotoQuestionAnswerService y el retrieval de foto no se tocaron.

Eval real, modelo `claude-sonnet-5-5`, servicio sin sesión (0 writes). La pasada que valida el rubric de `user_content` fueron 4 llamadas, costo aproximado USD 0.041. Una pasada anterior, antes de ese rubric, también fueron 4 llamadas (~USD 0.040) y devolvió `uncertain` en Orona; no es el resultado que cuenta.

| caso | visual_task | relevance | target_visible | manufacturer | model |
| --- | --- | --- | --- | --- | --- |
| goal `no nivela en planta 3`, placa Orona | nil | relevant | nil | Orona | PBCM-V3 |
| #30 pending controller, misma placa | nil | relevant | nil | Orona | PBCM-V3 |
| #31 pending manufacturer, misma placa | nil | relevant | nil | Orona | PBCM-V3 |
| #32 resorte, pending manufacturer | nil | uncertain | nil | UNKNOWN | UNKNOWN |

La promoción al episodio no corrió en ese eval. Con `relevant` y facts distintos de `UNKNOWN`, el camino F3 existente los escribiría `source=photo`; el test del job lo cubre. #32 `uncertain` no escribe facts y no cierra el pending. El test stubbeado de #32 sigue exigiendo `unrelated` y pending intacto.

`N0_CONTRACTS=1` después de N1: 6 runs, 6 failures, 0 errors. Siguen rojos por las razones de N2/N3/N4 (identidad efímera ausente, query anidada literal, `DocumentIdentityScope` sin identidad, `retrieve_and_generate` abierto, chunk Yida citable). No se adelantó ese comportamiento.

### N2 — Post-photo retrieval snapshot

```text
N2 IMPLEMENTED LOCALLY — NOT PRODUCTION VERIFIED
```

`PhotoTurnContext` sigue siendo el snapshot del turno. Campos previos: `status`, `session_context`, `entity_s3_uris`. Campos nuevos: `equipment_identity`, `retrieval_question`. No guarda episodio, historial, Vision crudo, pending, `FieldPhoto`, chunks ni focus objects. Document Focus sigue congelado en el mismo lock, dentro de `session_context` y `entity_s3_uris`.

La captura ocurre en `record_photo_assistant_context!`, después de `record_photo_observation!`, bajo `with_lock`, cuando el `expected_episode_id` coincide. Un episodio stale devuelve los cinco campos de retrieval en nil y no escribe `[FOTO]`. Después del unlock el job no relee el episodio para estos dos campos. No se pasa `conv_session` al RAG anidado.

`Rag::EquipmentIdentity` es el valor transportable: `manufacturer`, `needles`, `facts` con `source` y `correlation_id`. No es policy. `DocumentIdentityScope` no lo consume.

Identidad:

- facts del episodio `known` con source `user` o `photo`, slots `manufacturer` y `model`, salvo rechazados
- observación aceptada de esta foto, sólo si la pregunta va con esa foto: `relevant`, nil y `uncertain` sí; `unrelated` no
- un fact de episodio de otra fuente sigue aunque la foto sea `unrelated`
- nil y `uncertain` no reescriben relevancia ni promueven facts. El snapshot no muta el episodio

`retrieval_question` se compone una vez, sin LLM. Orden estable: pregunta literal, goal, `fault_code`, `controller`, observaciones ya acotadas del episodio, identidad aceptada. Tope `FollowupQueryRewriter::MAX_COMPOSED_CHARS` (442). Si no cabe, caen primero las observaciones, luego `controller` y `fault_code`, luego se acorta la pregunta literal. Goal e identidad se conservan hasta ese corte. El suffix de catálogo de `anchor_suffix` sigue igual y se agrega después, en `PhotoQuestionAnswerService`; no recomponer el episodio encima.

Antes de Vision la pregunta encolada sigue literal. La composición es posterior a la observación aceptada. Reuse de `relevance=nil` no llama Vision.

`N0_CONTRACTS=1` después de N2: los tres contratos N2 pasan. Siguen rojos N3 (`DocumentIdentityScope` no recibe la identidad) y N4 (`retrieve_and_generate` abierto actual 1; el chunk Yida sigue citable). No hubo llamadas reales a Vision. N2 no está verificado en producción.

Archivos fuera del trío principal, y por qué: `app/services/rag/equipment_identity.rb` y `app/services/rag/photo_retrieval_snapshot.rb` son el value object y la composición determinística. El modelo sólo los llama dentro del lock. No se tocó `rag_query_concern.rb`, `query_orchestrator_service.rb`, `document_identity_scope.rb` ni `bedrock_rag_service.rb`. `retrieval_question:` ya existía en el concern. `equipment_identity` se queda en `PhotoQuestionAnswerService` y no se reenvía.

### N3 — Common EquipmentIdentity policy

```text
N3 IMPLEMENTED LOCALLY — NOT PRODUCTION VERIFIED
```

Una sola policy: `Rag::DocumentIdentityScope`. No hay scope de foto ni de texto aparte. El caller de texto deriva `Rag::EquipmentIdentity.from_episode` del episodio vivo. El de foto reenvía el snapshot de N2. `execute_rag_query(..., equipment_identity:)` y `QueryOrchestratorService` sólo transportan. Si el keyword viene explícito, gana el snapshot, aunque el episodio vivo ya sea otro. `nil` explícito no relee el episodio. El RAG anidado no recibe `conv_session`.

Identidad conocida para la policy: un fact `manufacturer` o `model` con source `user` o `photo`. No alcanzan `controller`, `fault_code`, un fact de catálogo ni un identifier suelto. En ese caso la búsqueda sigue abierta.

Outcomes de `DocumentIdentityScope::Result`:

- `:scoped` — hay al menos un body aplicable (`compatible` o pin neutral).
- `:no_compatible` — la policy corrió y ningún body aplica. Incluye retrieval vacío y el caso en que todo chunk queda reference-only.
- `:unavailable` — la policy no pudo correr. En N3: flag apagada con identidad conocida, o identidad requerida mal formada.

`status` nil y `reason: :not_required` significan que la policy no era requerida (identidad desconocida). No es `:unavailable`.

Compatible: `canonical_name`, `original_filename` o `section_identity` contiene un needle vigente. El body queda y el label es `THIS JOB'S EQUIPMENT`.

Reference-only: el chunk no contiene un needle, o está fuera del Focus, o el documento seleccionado nombra una marca de `KbDocumentResolver::BRANDS` distinta del manufacturer vigente. El body de procedimiento sale del contexto de generación. Queda la identificación del manual. `identity_applicability: "reference_only"` marca el chunk para N4. Las citas todavía lo incluyen.

Pin neutral: el documento seleccionado no nombra una marca de `BRANDS`. Sigue `THIS JOB` (`applicability: "neutral"`). Elemont con trabajo KONE se mantiene. Fermator sí es marca y queda reference-only. No hay auto-unpin ni se amplía la búsqueda fuera del Focus. Un chunk Orona fuera de un pin Fuji no se promueve.

Precedencia, la misma de `match_needles`:

- Un model de otro `correlation_id` deja fuera al manufacturer heredado. Fuji heredado + `PBCM-V3` de la foto actual no usa Fuji como needle.
- Facts del mismo `correlation_id` viajan juntos. Orona + PBCM-V3 de la misma foto son los dos needles.
- KONE heredado (`query:prior`) + foto actual Orona/PBCM-V3 no es una unión. KONE no aplica. Orona y PBCM-V3 sí.
- KONE y Orona los dos con el `correlation_id` del turno actual son conflicto. `reason: :conflicting_current_identity`. Ninguno de los dos labels vuelve aplicable un body. El model no conflictivo (PBCM-V3) puede seguir siendo needle. No hay llamada a un modelo para resolverlo.
- Un conflicto explícito de F3 no es un manufacturer heredado. Si el técnico dijo KONE (`query:123`) y una foto posterior dice Orona / PBCM-V3 (`photo:456`), el episodio conserva KONE y graba `conflicts` user=KONE / photo=Orona. `EquipmentIdentity` copia esa fila, en el snapshot y en `from_episode`. La policy no elige Orona porque el model es posterior, y PBCM-V3 de esa foto no vuelve aplicable el manual Orona. Los dos bodies quedan reference-only. `status: :no_compatible`, `reason: :conflicting_current_identity`. Sin esa fila, la precedencia por correlación sigue igual.
- Ese conflicto explícito también gana al pin neutral. Un documento seleccionado que sólo nombra el model (`Manual PBCM-V3`) y no nombra KONE ni Orona queda reference-only mientras el conflicto siga sin resolver. El Focus no se toca. Sin conflicto, el pin neutral sigue `THIS JOB` (Elemont con trabajo KONE).

N3 no cierra el fallback. `:no_compatible` y `:unavailable` siguen cayendo en `retrieve_and_generate` abierto. Las citas reference-only siguen pudiendo producir `MANUAL_FACT`. Eso es N4.

`N0_CONTRACTS=1` después de N3: 4 PASS / 2 FAIL.

- N2 legacy reuse PASS
- N2 same-turn PASS
- N2 uncertain PASS
- N3 identity scope PASS
- N4 open fallback FAIL (`open_calls` 1)
- N4 citations FAIL (el chunk Yida sigue siendo citable)

No hubo llamadas reales a Vision ni a Bedrock. N3 no está verificado en producción. N4–N6 no empezaron. `AGENTS.md` no se tocó: el cambio doctrinal queda con N4/N5.

### N4 — Fail-closed retrieval + citation safety

```text
N4 IMPLEMENTED LOCALLY — NOT PRODUCTION VERIFIED
```

Con identidad conocida la policy es obligatoria. No hay fallback abierto. Identidad desconocida sigue el retrieve_and_generate de hoy.

- `:scoped` — generación documental con evidencia aplicable. Un chunk `reference_only` puede quedar en el contexto como identidad del manual. No entra a citas, `doc_refs`, `CitationAttributionGuard`, `AnswerSafetyProcessor` ni `require_cited_evidence`.
- `:no_compatible` — el retrieval terminó y ningún body aplica, incluido retrieval vacío y conflicto explícito de fabricante. No se llama `retrieve_and_generate`. Si hay identidad de manual ajeno, la generación de ese camino sigue; sus citas salen vacías. N5 escribe el tono.
- `:unavailable` — la policy no pudo correr: flag apagada, identidad mal formada, timeout, error de retrieval o generación vacía/rota. No se llama `retrieve_and_generate`. En foto, `PhotoQuestionAnswerService` devuelve `failed: true` con el texto ya existente de `rag.photo_question_unavailable`, así la lectura visual pagada sigue en el camino `rag_answer[:failed]`.
- Un `equipment_identity` explícito que no es un `EquipmentIdentity` queda `:malformed` y `:unavailable`. No se normaliza a `nil` y el episodio vivo no lo repara.
- Una foto aceptada con manufacturer o model conocido, salvo `unrelated`, exige el `EquipmentIdentity` congelado. Si ese snapshot llega `nil`, el lookup es `:unavailable` (`missing_identity_snapshot`) antes de `retrieve_and_generate`. Identidad realmente desconocida, y una foto `unrelated` sin otra identidad, siguen abiertas.

`identity_applicability == "reference_only"` se anula en `DocumentIdentityScope.citable_evidence` antes de los procesadores de cita. Un `[n]` hacia ese slot no es cita final y no produce `MANUAL_FACT`.

En modo requerido el orchestrator no entra a `DocumentOverviewResponder`, `AmbiguousModelResponder`, `DeterministicRenderer` ni a la síntesis HYBRID. `StructuredEvidenceRoute` y `ContextEvidenceRoute` siguen la misma policy: `:no_compatible` y `:unavailable` abstienen sin publicar un procedimiento.

`N0_CONTRACTS=1` después de N4: 6 PASS / 0 FAIL.

- N2 legacy reuse PASS
- N2 same-turn PASS
- N2 uncertain PASS
- N3 identity scope PASS
- N4 open fallback PASS (`open_calls` 0; el cuerpo Yida/BLT no está en la respuesta)
- N4 citations PASS (Yida/BLT fuera de citas; 0 `MANUAL_FACT`)

No hubo llamadas reales a Vision ni a Bedrock. N4 no está verificado en producción. En este cierre N5 todavía no había empezado. `AGENTS.md` distingue identidad conocida (el manual ajeno se puede nombrar; su procedimiento no se usa) de identidad desconocida (la analogía con disclaimer sigue). `FieldPhotoPrompt::SYSTEM_BLOCKS` no cambió.

### N5 — Companion no-compatible generation

```text
N5 IMPLEMENTED LOCALLY — NOT PRODUCTION VERIFIED
```

`:no_compatible` deja de cerrar en ausencia. Una sola generación, la que ya corre en `document_identity_scope`, recibe `Rag::CompanionGuidanceContext`: pregunta, problema activo, identidad conocida, observación visual aceptada (campos presentes del bloque de foto), observaciones recientes del técnico y el hecho de que no hay manual compatible. Los manuales reference-only entran sólo por nombre. El cuerpo de procedimiento no entra. `:scoped` sigue con el prompt documental. `:unavailable` no entra a este prompt.

La respuesta puede decir que no hay un procedimiento de fabricante y seguir con guía. `AnswerSafetyProcessor` en modo companion no la convierte en `uncited_technical_answer`. Una frase con terminal, valor o significado de código ausente de la observación visual aceptada se elimina. Un identificador que sí está en esa observación se puede nombrar como observado, sin cita de manual. Esa presencia no autoriza su función ni su significado: "En la foto se ve X17" se conserva; "X17 es la entrada de nivelación" y "E18 significa fallo de encoder" se eliminan. Una pregunta sobre si ese identificador cambia de estado se conserva. El camino `:scoped` no usa este filtro. `ProvenanceSegmenter` no cambia de dueño: observación visual y guía Danebo salen de las frases, sin fabricar `MANUAL_FACT`.

Una pregunta principal. El modelo decide cuál. No hay un segundo LLM ni un selector de preguntas. Un follow-up se marca si el contexto ya tiene un turno del asistente; no hay otra máquina de estado para el saludo.

Conflicto explícito de fabricante: el prompt nombra las dos lecturas y pide resolverlas antes de un paso de fabricante. No elige KONE ni Orona. Identidad desconocida sigue en retrieve abierto. Una generación vacía o que sólo emite `DATA_NOT_AVAILABLE` queda `:unavailable`, no se reetiqueta como companion.

`N0_CONTRACTS=1` después de N5: 6 PASS / 0 FAIL.

- N2 legacy reuse PASS
- N2 same-turn PASS
- N2 uncertain PASS
- N3 identity scope PASS
- N4 open fallback PASS
- N4 citations PASS

No hubo llamadas reales a Vision ni a Bedrock. N5 no está verificado en producción. En ese cierre N6 no había empezado. `AGENTS.md` añade que, sin manual compatible, se sigue como guía Danebo. `FieldPhotoPrompt::SYSTEM_BLOCKS` no cambió.

### N6 — Functional pilot-readiness certification

```text
N6 IMPLEMENTED LOCALLY — NOT PRODUCTION VERIFIED
```

Certifica la composición real: TurnInterpreter → Work Context → continuidad de foto → EquipmentIdentity → DocumentIdentityScope → Document Focus → retrieval safety → generación companion. Objetos y servicios reales, providers stub. La suite determinista no llama AWS, Bedrock, Vision ni navegador.

`TurnInterpreter` clasifica el move. `TurnPerception` valida el payload y las consecuencias: `correct` sin negate válido, `answer_pending` inválido, `new_work` sin payload técnico, writer tardío, identidad conocida fail-closed. No hay un clasificador Ruby por frases para `meta`, ofertas de foto o saludos. Una oferta de foto o un saludo queda `meta` porque el modelo lo entiende. El prompt `2026-10-02.6` lo dice en una regla corta. No reemplaza el goal activo.

El release gate de Field Companion es la suite funcional determinista, los service tests, `turn_interpreter:eval` / holdout, los contratos N0, y security/lint. Los system tests de navegador son legacy y no forman parte de ese gate. No se modificó GitHub Actions para ocultarlos.

Evidencia funcional en `test/services/rag/field_companion_pilot_readiness_test.rb`:

- F1 replay Orona. El goal conserva "no nivela en planta 3". La foto aceptada deja Orona/PBCM-V3. Una Vision; cero en el reuse. Yida y BLT quedan reference-only. Cero fallback abierto. La respuesta es guía Danebo, con el problema y una pregunta de diagnóstico. El terminal y el significado de código inventados no salen.
- F2 mismo turno, foto y pregunta. La identidad llega al retrieval. El goal se conserva. El job de foto no llama TurnInterpreter. Sin manual compatible sigue la guía. Con manual Orona el resultado es `:scoped`.
- F3 "¿te sirve si te mando otra foto?" queda `meta` y no reemplaza el goal.
- F4 manual compatible: `:scoped`, cuerpo retenido, cita presente, `MANUAL_FACT` presente. El prompt companion no se usa.
- F5 identidad desconocida: retrieve abierto. No `:unavailable`. No `:no_compatible` falso. `fallback_retrieve` está stubbeado. Cero llamadas AWS.
- F6 el técnico dijo KONE y la foto aceptada dice Orona. El conflicto queda. Ningún body es `THIS JOB`. Cero fallback. No hay procedimiento KONE ni Orona. El prompt pide evidencia para resolver la identidad.
- F7 Focus 0 deja el corpus autorizado como alcance primario. Focus N usa sólo los documentos elegidos. El manual compatible elegido es citable. El manual extranjero elegido sigue elegido, reference-only, no citable y no puede ser `MANUAL_FACT`. Discovery no escribe Focus. La precedencia es tenant, luego compatibilidad, luego Focus.
- F8 un caso nuevo no hereda manufacturer, model, goal, foto ni procedimiento. Un writer tardío del caso anterior no muta el nuevo. `hola` no es un identificador de campo. Un saludo sobre un episodio vencido no abre trabajo técnico. Focus sigue siendo del técnico.
- F9 el tenant A no recupera, no cita y no puede enfocar un `tenant_private` de B. `danebo_general` sigue autorizado.

`turn_interpreter:eval` 29/29, 0 mismatches, 0 fallbacks, 0 field rejections. Incluye `meta_photo_offer`, `meta_greeting`, las ofertas de foto, `report_door` y `new_work_drive`. Holdout 10/10. Esa eval usa Haiku y queda separada de la suite determinista. Costo estimado 0.090338 USD + 0.026299 USD. Los tests de placa relevante e irrelevante siguen verdes.

`N0_CONTRACTS=1`: 6 PASS / 0 FAIL. N2 legacy reuse, N2 same-turn, N2 uncertain, N3 identity scope, N4 open fallback, N4 citations.

Harness: `test/fixtures/files/elemont/chunk_p1_2_current.txt` reemplaza el tmp no versionado. `DocumentIdentityScopeTest` construye el servicio con `knowledge_base_id: "test-kb"`.

`bin/rails test`: 4133 corridas, 22439 aserciones, 0 fallos, 0 errores, 192 skips, sin credenciales AWS. Brakeman 0 warnings. bundler-audit limpio. `git diff --check` limpio.

No verificado en producción. No desplegado.

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

El "empty" del ítem 6 es generación vacía o fallo del camino de identidad. El retrieval que termina sin chunks compatibles es el ítem 5. `uncertain` no promueve facts al episodio; si la pregunta está ligada a esa foto, sí entra como `EquipmentIdentity` efímera. `unrelated` no. Reuse del ítem 1 sigue en 0 llamadas Vision. `turn_interpreter:eval` y holdout entran en N6 y no pueden regresionar.

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
N0 COMPLETE
N1 IMPLEMENTED LOCALLY — NOT PRODUCTION VERIFIED
N2 IMPLEMENTED LOCALLY — NOT PRODUCTION VERIFIED
N3 IMPLEMENTED LOCALLY — NOT PRODUCTION VERIFIED
N4 IMPLEMENTED LOCALLY — NOT PRODUCTION VERIFIED
N5 IMPLEMENTED LOCALLY — NOT PRODUCTION VERIFIED
N6 IMPLEMENTED LOCALLY — NOT PRODUCTION VERIFIED
```

F1–F3 están cerrados en el plan anterior. F4 quedó en local dentro de N1. F5 no entra. N1–N6 no están verificados en producción.

Los cinco errores de hermeticidad que quedaban en CI (tmp de Elemont y Knowledge Base real en dos tests de identidad) se cerraron en N6 sin cambiar el comportamiento de producción. La suite local queda en 0 fallos y 0 errores.

Siguiente paso: review del microfix. No deploy. El gate de Field Companion no usa los system tests de navegador.
