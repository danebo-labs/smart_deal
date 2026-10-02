# Turn Interpreter V2 (2026-10-01)

**Estado:** aprobado para ejecución. Opus: `APPROVE WITH REQUIRED CHANGES`, cierre `APPROVED FOR GROK EXECUTION`. T0 y T1 se implementan sin otra ronda de diseño.

**Baseline de implementación:** `20e562059d45e7fefaeafb4563f14b08cc9a0135`.

```text
afdb1cf  F8
6cf8e7c  plan inicial
476c6f8  TurnInterpreter V2
20e5620  F8.1
```

F8.1 está commiteado. Es baseline y es el rollback temporal del canary (`owner` → `conditional`). T0–T3 parten de `20e5620`. No hay un working tree de F8.1 que excluir. No volver el repo a `afdb1cf`.

T3 retira la semántica duplicada de F8/F8.1. No retira el state model que el reducer usa. En `ActiveEpisode` permanecen `observations`, `MAX_OBSERVATIONS`, `append_observation!` y la infraestructura genérica de observations.

**Este archivo es el master de la migración.** No hay un tercer documento. F9 y F10 siguen siendo el cierre de G5.

**Canal:** web autenticado. WhatsApp sigue dormido y no se migra.

---

## Decisiones cerradas

- Haiku interpreta el lenguaje. Ruby valida consecuencias y ejecuta.
- Todo turno conversacional escrito pasa por `TurnInterpreter`. No hay atajo de texto.
- Un request no corre F8 y TurnInterpreter a la vez.
- No hay shadow de producción: ni job, ni dry-run, ni segunda llamada.
- Desde el primer uso real el modo es `owner` y always-on para typed turns. El default del código sigue el camino viejo hasta el canary.
- Modelo único: `global.anthropic.claude-haiku-4-5-20251001-v1:0`. Una llamada por typed turn. `temperature` 0. `max_tokens` 512. Tool choice forzado. Sin retry semántico.
- El LLM no escribe la query, no elige la ruta, no conoce la concurrencia y no toca Document Focus.
- `TurnPerception` no recibe Document Focus ni `focus_count`.
- `switch` no existe. Un cambio de equipo que sigue el mismo trabajo es `correct`. Una tarea nueva es `new_work` y abre episodio.
- No hay `dialogue_acts`. No hay referents de respuesta. No hay `focus_labels` ni `evidence_hint`.
- `slot_hint` no crea un fact de manufacturer, model ni controller.
- Document Focus sigue user-owned. Badge `0` es el corpus autorizado. Badge `N` son exactamente esos documentos.
- Work Context, Document Focus y Document Discovery son tres cosas distintas.
- Learning formal (RLHF, DPO, fine-tuning, prompt optimization online) no entra en este plan.
- No hay fuzzy runtime.

---

## 1. Arquitectura

```text
typed technician turn
        ↓
snapshot active_episode
        ↓
TurnInterpreter — one Haiku call, fuera del lock
        ↓
TurnPerception.build
        ↓
with_lock
    idempotency
    compare episode snapshot
    fresh Document Focus
    RoutePolicy
    WorkContextReducer
    one UPDATE
        ↓
QueryComposer
        ↓
Retrieval / DocumentDiscovery
        ↓
Generation
```

`TurnPerception.build` es el único validador. No hay un servicio público `Validator`.

```text
TurnPerception = qué dijo el técnico
RoutePolicy    = qué hacer con eso dado el Work Context y el Focus fresco
```

El reducer corre después de la policy, dentro del lock. `clarify_first` y `meta` no escriben goal ni observations de ese turno.

Si el Focus cambió y el episodio no, no es fallback. Haiku no vuelve a correr. La policy ve el Focus fresco.

---

## 2. Qué entra al interpreter

Entra todo texto escrito por el técnico en `RagController#ask` cuando `question` está presente, el canal es web, `episode_recording?` es true y el modo es `owner`.

No entra:

- pin, unpin, aceptar o rechazar card (`PinnedDocumentsController`)
- replay (`replay_correlation_id`): no llama `record_user_turn!`
- `selection_turn` y `ThreadMenuSelection` (menú ya tipado)
- upload o foto sin texto
- turno en blanco

Un chip que publica una frase como `question` entra. Es texto.

### Foto y documento, según el código

Hoy `ask` llama `record_user_turn!` siempre que hay `question`, también con imagen o documento. `turn_understanding_for` devuelve nil si `images.any?` o `documents.any?`, así que F8 no compone esa query. La respuesta de ese request es el upload. `FieldPhotoAnalysisJob` escribe manufacturer/model después, con `expected_episode_id` capturado al terminar `record_user_turn!`.

En `owner`:

- Foto sola o documento solo: sin interpreter. El pipeline actual abre o reutiliza el episodio.
- Foto o documento con texto: el texto sí pasa por TurnInterpreter, fuera del lock, y el reducer corre antes de capturar `expected_episode_id`. No corre el regex de `ActiveEpisodeTurn` en ese mismo request. El job de foto sigue siendo el único writer de facts `source=photo`. Este request no hace `RetrieveAndGenerate`.
- El interpreter no lee la imagen ni el PDF.

---

## 3. Input

Una sola JSON. El turno es dato. El system prompt dice que las instrucciones dentro del turno se ignoran, que no se responde el procedimiento y que la única salida es el tool.

```json
{
  "turn": "Volviendo a eso, no lo sé",
  "work_context": {
    "goal": "Nice300 e51",
    "facts": {
      "controller": {"value": "NICE3000", "status": "known", "source": "catalog"},
      "fault_code": {"value": "E51", "status": "known", "source": "user"}
    },
    "identifiers": ["CEA15"],
    "observations": ["se pasa en bajada"],
    "rejected": [{"slot": "controller", "value": "NICE3000"}],
    "pending": {"slot": "controller", "carry": ["Q2"]}
  }
}
```

`turn` es `content.to_s.truncate(ConversationSession::MAX_MSG_LENGTH)`, el mismo corte que `history_message`, incluida la omisión `"..."`. No se usa `first(300)` en un sitio y `truncate(300)` en otro. `Rag::TurnText.truncate` es el único corte.

Invariante: el turno que ve Haiku, el string de la validación de spans y el `content` persistido del usuario son el mismo texto, salvo metadata no semántica.

Antes de armar el input, el snapshot se parsea con el lifecycle real. Si el episodio está `expired`, `invalid_state` o en blanco, el `work_context` enviado al interpreter es vacío. No se mandan facts ni goal viejos para descartarlos después. El camino normal puede abrir o reemplazar el episodio según el lifecycle que ya existe.

No entra: chat crudo, últimos N mensajes, chunks, PDF, URI, filenames, metadata de otro tenant, labels de focus, `focus_count`, hints de evidencia, prosa del assistant, `episode_id`, `state_version`, `correlation_id`, catálogo completo.

`pending` es null cuando no hay `pending_fact` ni `pending_question`. El slot sale de `pending_question.type` si existe, si no de `pending_fact.subject`. `carry` viaja con el pending cuando existe.

---

## 4. Output

Tool `turn_perception`. `additionalProperties: false`.

```json
{
  "move": "report",
  "assertions": [
    {"span": "VF5", "act": "mention", "slot_hint": "designator"}
  ],
  "observations": ["intenta cerrar, vuelve a abrir"],
  "pending_resolution": null
}
```

`move`: `report | follow_up | answer_pending | correct | new_work | meta | unclear`.

`act`: `assert | negate | mention`.

`slot_hint`: `manufacturer | model | controller | fault_code | designator | null`. Es hint de telemetría. El catálogo lo pisa. Solo no crea un fact de identity.

`pending_resolution`: `unknown | absent | value | seek | null`. `value` exige un `assert` cuyo span es el valor. `seek` no marca unknown y no abre otro trabajo.

No salen `episode_id`, `state_version`, `correlation_id`, `evidence_hint`, `referent_id`, ruta ni query.

### Moves

- `report`: afirma o describe el trabajo en curso.
- `follow_up`: pide el paso siguiente del trabajo ya abierto. No reemplaza un goal que ya existe.
- `answer_pending`: responde el pending actual.
- `correct`: niega un valor activo y puede afirmar el reemplazo. Mismo episodio.
- `new_work`: tarea nueva. Episodio nuevo. No hereda observations, rejected, goal, facts ni carry.
- `meta`: pregunta sobre lo que Danebo necesita. Cero mutación y cero retrieve.
- `unclear`: perception válida con cero mutaciones. No borra identity.

“No es Elemont, es KONE” es `correct`. “Otra falla: Elemont MH…” es `new_work`. No hay `switch`.

---

## 5. Bounds

Coinciden con topes que el runtime ya aplica.

| Campo | Tope | Origen |
|---|---|---|
| turn | 300 | `ConversationSession::MAX_MSG_LENGTH`, vía `truncate` |
| assertions | 8 | cerrado aquí |
| observations | 3 | `ActiveEpisode::MAX_OBSERVATIONS` |
| span | 60 | `MAX_VALUE_CHARS` |
| observation | 180 | `MAX_OBSERVATION_CHARS` |
| carry | 2 spans | literales, no facts |
| rejected | 4 | cada item `{slot, value}`, value 60 |
| tool JSON | 4096 bytes | si se pasa, perception inválida |

`additionalProperties: false` en el tool y en cada assertion. Pasarse de cardinalidad o de largo invalida el perception completo y dispara fallback. Un span que no es literal se rechaza como campo; si después de eso `correct` se queda sin negate activo, el move baja a `unclear` y no hay mutación.

Span literal, la normalización ya usada por `SemanticQueryAnalyzer`: NFC, downcase, colapsar espacios, trim de puntuación en los bordes, sin plegar acentos. El lookup de catálogo usa `FollowupQueryRewriter.normalize_label`, que sí pliega acentos. Las dos se mantienen. “Excélsior” puede ser span literal y además match exacto de la brand `Excelsior`.

---

## 6. TurnPerception.build

`Rag::TurnPerception.build(raw, turn:, episode:, catalog:, viewer_account:)`.

No recibe `focus_count` ni Document Focus.

Rechazo del perception completo:

- no es el tool input
- falta `move` o no está en el enum
- assertions u observations por encima del tope
- tool JSON por encima de 4096 bytes

Rechazo de campo, con `field` + `reason` en telemetría:

- span que no es substring literal del turno truncado
- observation que no es substring, que tiene menos de 13 caracteres, o que es un solo token de 2–4 caracteres
- `answer_pending` sin pending, o resolución cuyo valor no corresponde al slot pendiente: el move baja a `report` si quedan assertions u observations, si no a `follow_up`. No se aplica `pending_resolution`
- `correct` sin un `negate` cuyo valor normalizado está en un fact o identifier activo: baja a `unclear`, cero mutaciones
- `new_work` sin assertions ni observations, habiendo Work Context previo: baja a `follow_up` y no abre episodio
- `slot_hint` fuera de enum: se descarta el hint, se conserva el span

`unclear` es válido y no muta.

### Catálogo, tenant-safe

`resolve_designator(token, viewer_account:)` y `resolve_brand(token, viewer_account:)`.

Una resolución de catálogo sólo usa entradas visibles para `viewer_account` según `Rag::KnowledgeScopePolicy`. La fila en `config/document_identities.yml` no autoriza. El bind sigue siendo el de la policy: `document_uid` + objeto canónico, y `authorized?`.

Si el token sólo coincide con entradas no autorizadas, el resultado es unresolved. No se devuelve identidad canónica, manufacturer, controller, model, documento ni alias de otro tenant. El literal puede quedar como identifier sin tipo.

`viewer_account: nil` conserva el lookup sin filtro que ya usan F8 y sus tests. `TurnPerception` no usa ese camino: sin viewer, el catálogo queda unresolved. T3 deja de llamar el camino sin filtro desde el ask web.

`resolve_designator` sigue siendo exacto, prefijo con las reglas de F8, ambiguo no elige, sobre el subconjunto visible.

`resolve_brand`: match exacto con `normalize_label` contra `entry.brands` visibles. Sin prefijo y sin fuzzy. Varias entradas con la misma brand canónica (igualdad por downcase) son un solo manufacturer. Dos strings canónicos distintos para el mismo token normalizado son ambiguos: no se escribe manufacturer.

### Identidades

Orden por span, sólo con entradas visibles:

1. Designator `:exact` con tipo declarado: slot y valor canónico. Source `catalog`. Si la entrada tiene una sola brand, manufacturer también, source `catalog`. El hint se ignora.
2. Designator `:exact` sin tipo: identifier. No se escribe manufacturer, model ni controller.
3. Designator `:prefix` que ya cumple el umbral de F8: igual que hoy, se puede escribir, si la entrada es visible.
4. Designator `:ambiguous` entre entradas visibles: no se escribe fact. La policy pregunta. Candidatos de entradas invisibles no salen.
5. Brand exacta visible, y el span no fue designator: manufacturer, source `catalog`.
6. `fault_code` sólo si el span normalizado matchea `\A[a-z]?\d{1,4}[a-z]?\z`, no es designator ni brand, el hint o el pending dicen `fault_code`, y hay contexto de trabajo: pending ya es `fault_code`, o este turno resolvió brand o designator tipado, o hay observation válida. `focus_count` no participa. Si no, el assertion queda `mention` y no es fact. `¿Que es Q2?` es mention con focus 0 y también con focus mayor que 0. No se persiste `fault_code=Q2` porque haya un manual seleccionado.
7. Hint `manufacturer|model|controller` sin match de catálogo: no se escribe fact por el hint. El desacuerdo hint/catálogo se loguea.

Un literal no resuelto queda identifier sin tipo. `ABC900` no se convierte en manufacturer, model ni controller por `slot_hint`. Puede participar en Work Context, retrieval, telemetría y el aprendizaje futuro.

Un `assert` de un valor que está en `rejected` lo saca de `rejected` y lo escribe. Es la única resurrección.

Elemont y Excelsior están como brands en el YAML. `NICE3000` sigue siendo designator `type: controller` de la fila Monarch cuando esa entrada es visible para el viewer. VF5 hoy es string sin tipo: queda identifier, no controller.

### Excepción: Ruby ya conoce el slot

El tipo no sale de `slot_hint`.

1. `answer_pending` con `pending_resolution=value`. Danebo preguntó un slot (`pending.slot` o `pending_fact.subject`). El `assert` es el valor. Aunque no esté en el catálogo se escribe ese slot, `source=user`. Así `controller?` + `ABC900` persiste `controller=ABC900` y no vuelve a preguntar el controlador.
2. `correct` con reemplazo. El negate corresponde a un fact activo, y el assert es el reemplazo. El slot es el del fact negado. `No, no es NICE3000. Es ABC900` con `controller=NICE3000` escribe `controller=ABC900`, `source=user`, y rechaza NICE3000. Si el catálogo tipa el reemplazo, gana el catálogo.

Fuera de esos dos contextos, un literal no catalogado es identifier.

---

## 7. Work Context

`conversation_sessions.active_episode`, `v: 1`. Clave nueva única: `rejected`.

```text
goal
facts: manufacturer, model, controller, fault_code
identifiers
observations
pending_fact
pending_question     # puede incluir carry
rejected             # max 4, {slot, value}
active_photo
conflicts
```

No se crean `component`, `measurement`, `action_taken`, `result`, `dialogue_acts`, `referents`, `state_version`, `last_applied_correlation_id`.

`unknown_confirmed` y `absent_confirmed` siguen siendo status del fact.

`rejected.slot` es uno de `manufacturer | model | controller | fault_code | identifier`.

Observations siguen siendo el state de F8.1: `MAX_OBSERVATIONS`, `append_observation!`, sanitize. El reducer es quien las escribe en `owner`. No se borra esa estructura en T3.

### pending_question.carry

Cuando `RoutePolicy` devuelve `clarify_first`, puede guardar junto al pending:

```json
{"type": "controller", "carry": ["Q2"]}
```

- máximo 2 spans
- literales del turno truncado
- sólo assertions o mentions que pasaron validación
- tope de span ya existente
- no son facts, ni observations, ni goal
- no adquieren tipo técnico

`answer_pending` con `value`, `unknown` o `seek` promueve el carry a `identifiers` del Work Context y de la query. Un move que no responde el pending (`new_work`, `correct` no relacionado, `report` no relacionado) descarta el carry junto con el pending. `meta` deja el pending quieto. No hay carry eterno.

Así `¿Qué es Q2?` → clarify → `Monarch NICE3000` busca Q2 con NICE3000 y Monarch. `no sé, busca con eso` es `best_effort`, Q2 sobrevive y no repite la aclaración. `otra falla: puertas no cierran` tira el carry viejo.

### Tamaño

Medido en T0 con un payload al tope de los caps actuales más 4 rejected y un carry de 2: saturado 4218 bytes, núcleo 2167. El núcleo cabe en 4096. El saturado no, así que el shrink de T1 tiene que soltar conflicts, observations e identifiers antes de persistir.

`MAX_BYTES` pasa de 2048 a 4096 en T1, junto con `rejected`.

Shrink, en este orden, y se para al quedar dentro del tope:

1. `conflicts`, del más viejo
2. `observations`, de la más vieja
3. `identifiers`, del más viejo

Nunca se sueltan `facts`, `rejected`, `pending_fact`, `pending_question`, `goal`, `active_photo` ni los ids del episodio.

Si después del shrink el JSON sigue por encima de 4096, no se persiste la mutación. Se conserva el episodio anterior, se agrega el mensaje al historial y el turno usa fallback. Se loguea `episode_budget_refused`. No hay “warning y persistir igual”.

---

## 8. Reducer

`Rag::WorkContextReducer.apply!(episode:, perception:, decision:, correlation_id:, now:)`.

Único writer lingüístico del episodio en modo `owner`. No escribe `document_focus`.

Corre sólo dentro del lock, con el episodio que sigue igual al snapshot, y después de `RoutePolicy`.

- `clarify_first` y `meta`: no escriben goal, facts, identifiers ni observations de este turno. `clarify_first` escribe el `pending_question` de la policy, carry incluido. No crea goal. Q2 no se vuelve el goal.
- `report` con goal vacío y decisión que sí hace retrieval: `assign_goal!` con el turno truncado. Con goal presente: el goal se queda; se agregan observations válidas.
- `follow_up`: no reemplaza un goal presente. Si `goal` está vacío y la decisión hace retrieval, el reducer asigna el goal desde el turno truncado. No aplica a `meta`, `clarify_first`, texto de `answer_pending` `unknown`, ni prosa que no es el trabajo.
- `answer_pending`: no cambia el goal. `unknown` en manufacturer, model o controller: `unknown_confirmed`. `absent` en fault_code: `absent_confirmed`. `value`: write del fact, con la excepción de slot ya conocido si el catálogo no tipó. `seek`: el fact no cambia. Carry previo pasa a identifiers. En todos, `clear_pending!`.
- `correct`: cada negate hace `clear_fact!` o saca el identifier, entra en `rejected` (si hay 4, sale el más viejo) y se borra ese valor del goal y de las observations. Si se niega un controller cuyo manufacturer es `source=catalog`, ese manufacturer también se limpia. El assert nuevo se escribe `source=user`, salvo que el catálogo lo haya tipado. El slot del reemplazo no catalogado es el slot del fact negado, no el `slot_hint`.
- `new_work`: `ActiveEpisode.open`. El episodio viejo no se fusiona. Goal, facts, observations y carry salen sólo de este turno. `rejected` viejo muere con el episodio viejo. `result.decision` es `:new_episode` para el boundary.
- `unclear`: no se llama al reducer para mutar lenguaje. El historial igual se agrega.

---

## 9. RoutePolicy

`Rag::RoutePolicy.call(previous:, perception:, focus_count:, focus_document_ids:, focus_uris:)`.

Corre dentro del lock. `focus_count`, los ids y los URIs salen de la lectura fresca de Document Focus hecha en ese lock. El `Decision` se los lleva hasta retrieval. No se vuelve a leer el Focus para armar el filtro.

`previous` es el episodio del snapshot ya comparado. Si el move efectivo es `new_work`, la policy trata `previous` como episodio vacío.

El primero que matchea gana.

1. `move=meta`. Salida `meta`. Cero retrieve, cero discovery, cero mutación. El pending que ya existe se queda, carry incluido. `model_invoked=false`. Frase corta de i18n. `RagQueryConcern` corta antes del orquestador.
2. `clarify_first` cuando `focus_count == 0`, `previous` no tiene identity conocida, fault, observation, goal ni foto, este perception no tiene observation válida, ni assertion resuelta a brand, designator tipado o fault_code aceptado, ni un `assert` literal, y el move no es `answer_pending`, `correct` ni `new_work`. Un `assert` literal cuenta como contexto técnico aunque siga siendo identifier. Un `mention` no. Cero retrieve, cero discovery. El reducer no escribe el goal. Puede escribir pending con carry.
3. `best_effort` cuando `pending_resolution` es `unknown` o `seek`, o el fact ya está `unknown_confirmed` y el move es `answer_pending`. Hay retrieve. No se vuelve a preguntar ese slot. `outside_discovery=true`.
4. `search_and_clarify` cuando hay resolution `:ambiguous` entre entradas visibles, o hay manufacturer conocido (previous o brand de este turno) y faltan model y controller, controller no está `unknown_confirmed`, y hay goal, observation o fault en previous o en este perception. Hay retrieve. `pending_subject=controller`. La pregunta no entra en la query.
5. `search_and_clarify` con `ask_when=:absence` cuando `focus_count > 0` y el único token técnico es un mention de 2–4 caracteres sin designator exacto tipado. Se busca dentro del focus. La pregunta sale sólo si la respuesta se abstiene. Q2 con focus mayor que 0 entra aquí, y sigue siendo mention, no `fault_code`.
6. El resto es `ready`. Incluye NICE3000 con tipo y manufacturer, un `assert` literal no catalogado, y un `follow_up` cuando previous ya tiene identity, fault, goal u observation.

`outside_discovery` es false en `meta`, `clarify_first` y fallback. False en el caso 5. True en `best_effort`. True en el resto. DocumentDiscovery no escribe focus.

`¿Que es Q2?`, focus 0, sin identity: mention `Q2`, sin observation, previous vacío. No es fault. La regla 2 devuelve `clarify_first` y guarda carry `["Q2"]`. Cero retrieve y cero discovery.

`¿Que es Q2?` con focus mayor que 0 no entra en la regla 2. La perception sigue siendo mention. La regla 5 busca dentro de esos ids.

`El controlador es ABC900` es un assert. No entra en la regla 2. No pregunta de inmediato qué controlador tiene.

La policy no lee prosa del assistant. El pending estructurado que ella escribe es lo que `record_assistant_turn!` persiste. En `owner`, `write_pending!` no escanea los `?` del texto generado.

---

## 10. Query composer

`Rag::QueryComposer.call(state:, turn:, perception:, decision:)`.

`state` es el episodio después del reducer. Tope `FollowupQueryRewriter::MAX_COMPOSED_CHARS` (442). Dedupe por `normalize_label`.

Orden, que es el inverso del recorte:

1. Turno actual, sin valores `rejected` y sin spans `negate`. Se omite el turno si el move es `meta`, o `answer_pending` con resolución `unknown`, `absent` o `seek`.
2. `fault_code` activo que no esté rejected.
3. Controller, model e identifiers activos, en forma canónica si el catálogo los resolvió, sin rejected. Los spans promovidos desde `carry` entran aquí como identifiers.
4. Manufacturer activo. Si era `catalog` y este turno negó el controller que lo trajo, no entra.
5. Hasta 3 observations persistidas, de la más nueva a la más vieja, saltando las que contienen un rejected.
6. Goal, si no contiene un rejected.

No se leen los últimos N mensajes. `meta` y `clarify_first` no tienen query. Si no queda nada en un `ready`, la query es el turno actual.

La string no agrega URIs ni cambia `force_entity_filter`. El filtro de retrieval es el snapshot de URIs que viajó en el `Decision`.

---

## 11. Concurrencia, lock, fallback, idempotencia

```text
snapshot = active_episode JSON
si el snapshot está expired, invalid o blank: work_context vacío
truncar el turno con TurnText.truncate
Haiku, fuera del lock
TurnPerception.build
with_lock
  si history ya tiene un user message con este correlation_id: return, sin segundo append y sin segundo apply
  si active_episode != snapshot: append history, fallback sobre el estado fresco, cero mutación LLM
  si el episodio no cambió:
    leer Document Focus fresco
    RoutePolicy(previous, perception, focus fresco)
    WorkContextReducer
    un solo update de episodio + history
QueryComposer y retrieval usan los focus ids/URIs de ese Decision
```

Comparar el JSON del episodio, no un `state_version` nuevo. Un write de assistant o de foto entre el snapshot y el lock cambia el JSON: se descarta la perception. No hay segunda llamada Haiku. Un cambio de Focus no cambia el JSON del episodio y no dispara fallback.

Los ids que usó la policy viajan en el resultado hasta `entity_s3_uris`. No se hace un read independiente que pueda ver otro Focus.

Writers que siguen con `expected_episode_id`: `record_assistant_turn!`, `record_photo_observation!`, auto-pin de upload. Este plan no les agrega locking nuevo.

`correlation_id` lo genera el server por request. La idempotencia cubre el retry del mismo request: no se aplica dos veces y el replay no duplica la burbuja. No cubre dos HTTP distintos con el mismo texto, porque llevan correlation ids distintos.

Fallback, para timeout, throttle, tool inválido, perception inválida, snapshot de episodio distinto o `episode_budget_refused`:

- cero mutación derivada del LLM
- cero discovery
- cero cambio de focus
- cero episodio nuevo por culpa del LLM
- no corre `TechnicalUnderstanding`, ni el extract de `ActiveEpisodeTurn`, ni `FollowupQueryRewriter.call`, ni un segundo Haiku
- puede usar estado fresco ya validado, el turno persistido, matches exactos de catálogo autorizado, el Focus actual y el pending existente
- si el estado fresco no tiene identity, fault, goal, observation ni foto, y focus es 0: `clarify_first` genérico
- si hay Work Context o focus: query del composer sobre ese estado fresco más el turno actual, menos rejected, decisión `ready`; si ya hay pending, se vuelve a pedir ese pending
- un designator `:exact` con tipo, o una brand exacta, visibles para el viewer, puede entrar a la query de este request. No se persiste

Replay sigue siendo `replay_correlation_id`: no entra a `record_user_turn!`, no duplica la burbuja, no llama a Haiku.

### Case boundary

El camino `owner` no se salta `case_boundary_changes` ni `log_case_boundary!`. Comparte esa primitiva con el camino viejo.

`move=new_work` se comporta como `:new_episode`: limpia `current_procedure` y emite la telemetría de boundary. Expiry e `invalid_state` siguen saliendo del JSON guardado, como hoy. Los pins no se tocan.

---

## 12. Flags

Producción hoy: `FIELD_COMPANION_EPISODE_ENABLED=true`, `FIELD_COMPANION_TURN_ENABLED=true`, `HAIKU_QUERY_ANALYSIS_MODE=conditional` en `config/deploy.yml`.

Precedencia mientras existan los tres:

1. Sin `episode_recording?` (flag de episodio apagado, canal no web, o shared session): no hay episodio y no hay interpreter.
2. `HAIKU_QUERY_ANALYSIS_MODE=owner`: typed turns usan TurnInterpreter. El regex de continuidad, `observe_ownership` y `TechnicalUnderstanding` no corren en ese request.
3. `conditional`: camino F8/F8.1 actual, incluido `observe_ownership`. Es el rollback del canary.
4. `off`: F8 determinista, sin Haiku. Sigue existiendo hasta T3.
5. `shadow`: se deja como está hoy. No se construye nada nuevo encima. T3 lo borra junto con el analyzer.

`FIELD_COMPANION_EPISODE_ENABLED` y `FIELD_COMPANION_TURN_ENABLED` no son el gate del interpreter. Siguen: el primero escribe el episodio, el segundo lo lee en `SessionContextBuilder`. T3 no los borra.

T1 no cambia `deploy.yml`. El flip a `owner` es el paso de canary, después del eval real.

Después de T3 el camino web de typed turns es el interpreter siempre que `episode_recording?`. `HAIKU_QUERY_ANALYSIS_MODE` se quita de `deploy.yml` y el código deja de leerlo. Rollback de ese release: revert, no un modo.

---

## 13. Telemetría y learning

Evento nuevo `turn_interpreter` por `PilotUsageLog` → `PilotEventRecorder`. Hace falta ampliar `ALLOWED_FIELDS`, porque `log` tira las claves que no están en la lista. Strings se cortan a 500. Arrays a 20 items.

Reusar claves que ya existen cuando alcanzan: `account_id`, `user_id`, `conversation_session_id`, `correlation_id`, `model`, `latency_ms`, `input_tokens`, `output_tokens`, `episode_id`, `original_sha256`, `effective_sha256`, `route`, `pending_question_type`.

Agregar sólo:

- `turn_interpreter_status`
- `turn_interpreter_fallback`
- `prompt_version` (`2026-10-02.1`)
- `schema_version` (`turn_perception.2`)
- `catalog_fingerprint` (SHA256 de `config/document_identities.yml`, 12 hex, memoizado por proceso)
- `interpreter_move`
- `interpreter_assertions`
- `catalog_disagreement`
- `field_rejections`
- `mutations_applied`
- `pending_outcome`
- `state_before_sha256`
- `state_after_sha256`

No se guarda el turno crudo. El SHA ya está en `original_sha256`. `PILOT_AUDIT_CAPTURE` sigue siendo el único lugar de texto completo, y no se duplica.

No se duplican `manual_suggestion_shown`, `manual_focus_confirmed`, `manual_suggestion_dismissed`, `interaction_completed` ni `[TURN_EVIDENCE]`. Esos eventos ya ligan la card aceptada al `correlation_id`.

`TrackBedrockQueryJob` sigue con `source: semantic_analysis`. El enum de `bedrock_queries` no se abre.

### Learning que este plan deja cableado

In-session: el turno validado queda en Work Context y la llamada siguiente lo ve. No hay training. No hay RL.

Runtime sólo deja señales: literal no resuelto, resolución de catálogo, desacuerdo de catálogo, rechazo de campo, corrección del usuario, rejected, fallback, outcome del pending, eventos de sugerencia y aceptación que ya existen, fingerprints de prompt, schema y catálogo.

Después del rollout: evidencia acotada al tenant → agregación offline de candidatos → revisión humana → alias de catálogo o alias de tenant. Un alias o identidad privada del tenant A no se usa para interpretar al tenant B. El candidato global exige evidencia pública o de `danebo_general` revisada. Apodos, filenames privados y labels de edificio se quedan en el tenant. Un trigger del estilo 5 confirmaciones, 2 usuarios y 0 conflictos es un default offline y no corre en el request.

No se agregan excepciones Ruby del tipo `if VF5`. No hay fuzzy runtime.

Deícticos no tienen referents en este MVP. No se emite `unresolved_deictic` en T0–T3.

---

## 14. Dataset

CI no llama a Bedrock. Los tests pasan perceptions ya construidas a policy, reducer y composer.

`test/fixtures/files/field_companion/turn_interpreter_eval.yml` copia texto verbatim y marca `origin`.

`origin: real`:

- `test/fixtures/files/field_companion/replay_2026-09-23.json`, R-A y R-B
- `JESUS_TURNS` en `test/controllers/concerns/rag_query_concern_test.rb`: Elemont, imanes, CEA15, puerta 1, MH
- Excelsior, sólo las dos frases que el plan de focus cita como texto real. S1000 / `sg_lm2a` no tienen wording en el repo: no se agregan
- `test/fixtures/real_gonzalo/photo_81515_episode.json` y `lce_episode.json`: sólo turnos de texto

`origin: reconstructed`:

- `¿Que es Q2?` y el carry hacia `Monarch NICE3000`
- `¿Que es Q2?` y después `no sé, busca con eso`
- `¿Que es Q2?` y después `otra falla: puertas no cierran`
- VF5 progresivo, incluida `Es VF5, intenta cerrar, vuelve a abrir y marca E03`
- `Nice300 e51` → `¿Qué reviso?`
- `¿Necesitas controlador?`
- `Volviendo a eso, no lo sé` con pending controller
- pending controller y `ABC900`
- `No, no es NICE3000. Es NICE1000.`
- `No, no es NICE3000. Es ABC900.`
- un `new_work` tomado de R-A (`Otra falla: Elemont MH…`), marcado real porque esa frase está en el replay
- aislamiento de catálogo: `PRIVATE900` visto por un tenant sin acceso

No hay transcripción de Hangcha, Crown FC4000/4500, SEGURIDADES 1.1-1, ni de un journey focus 0 → manual A → manual B. No se inventa. El replay de card sigue cubierto por el test de F7.

Cada caso del YAML trae el perception esperado y las invariantes finales. Un fallo de producción puede entrar como `origin: candidate`. No es ground truth hasta una revisión humana que lo pase a `reconstructed` o `real`.

`bin/rails turn_interpreter:eval` llama Haiku real, corre build, reducer en copia, policy y composer, e imprime: cases, passes, move mismatch, field rejection, fallback, unsafe mutation, pending accuracy, correction accuracy, query invariant failures, p50, p95, tokens, cost. No corre en CI. No es una plataforma de experimentos.

Invariantes en cero antes del canary: ampliación de scope cross-tenant, mutación de Document Focus, span no literal aplicado, estado inválido persistido, valor rejected dentro de la query efectiva, mutación persistente incorrecta en los casos críticos de la sección 16.

No hay un SLO de p95. El eval imprime p50 y p95. No se despliega el canary si esa llamada, sumada al turno, deja la respuesta claramente inutilizable para un técnico en el teléfono. Ese juicio lo hace quien corre el eval, con los números, antes de pedir el deploy.

---

## 15. Fases

Cada fase inspecciona el repo, implementa sólo esa fase, corre los tests, arregla lo que la fase rompió, corre `git diff --check`, hace un commit y anota aquí SHA, tests, hallazgos, desvíos y la suposición de la fase siguiente.

Parar sólo por: agujero de tenant no contemplado, migración destructiva, contradicción material con una decisión cerrada, acción de producción que una persona tiene que hacer, o evidencia de que una decisión cerrada es técnicamente imposible. Un test rojo ordinario se corrige y se sigue.

### T0 — Contrato, catálogo tenant-safe, eval fixture

El request no cambia de camino. `ask` no llama a `TurnPerception`.

Implementar:

- `TurnPerception` y el schema del tool
- bounds, validación literal, `TurnText.truncate`
- `resolve_brand`
- `resolve_designator` y `resolve_brand` tenant-safe cuando hay `viewer_account`
- literal no catalogado → identifier
- tipado por pending y por corrección
- Q2 sigue mention, sin `focus_count`
- fixture de eval
- test viejo de `source=catalog`
- test de bytes del episodio, sin subir `MAX_BYTES`
- tests de aislamiento de tenant

Tests críticos, además de los de schema:

1. La entrada privada del tenant A es invisible para el tenant B.
2. Una entrada `danebo_general` o pública autorizada sí resuelve.
3. `ABC900` suelto → identifier.
4. Pending controller + `ABC900` → controller, `source=user`.
5. Correct controller NICE3000 → `ABC900` → controller, `source=user`.
6. Q2 sigue mention, no fault, con o sin focus.
7. Brand exacta autorizada resuelve.
8. Brand exacta no autorizada no filtra manufacturer.

Commit: `test: add the tenant-safe turn perception contract`

Rollback: revert.

### T1 — Camino owner detrás del gate

El modo `owner` ejecuta la cadena completa. El default sigue en `conditional`. No hay shadow de producción. No hay un segundo Haiku.

Implementar:

- `TurnInterpreter`, Haiku fuera del lock
- turno truncado idéntico al persistido
- contexto vacío si el snapshot está expired o invalid
- compare del snapshot
- Focus fresco dentro del lock
- `RoutePolicy` dentro del lock
- ids de focus dentro del decision, y retrieval con esos ids
- `WorkContextReducer` y `QueryComposer`
- fallback chico
- telemetría
- `pending_question.carry` y su lifecycle
- goal de `report` / `follow_up` cuando hay retrieval y el goal está vacío
- `case_boundary_changes` y `log_case_boundary!` compartidos
- `new_work` → `:new_episode`
- caption de foto
- idempotencia como está escrita en la sección 11
- `MAX_BYTES=4096`

CI usa un client falso. `deploy.yml` no pasa a `owner`.

Commit: `feat: run the turn interpreter when owner mode is on`

Rollback del canary: env `conditional`. Las claves `rejected` las ignora una imagen vieja hasta que se leen; una imagen vieja no las escribe.

### T2 — Eval con Haiku real y canary

Antes de cualquier deploy, quien implementa corre `bin/rails turn_interpreter:eval` con credenciales Bedrock. El reporte se pega aquí: passes, mismatches, fallbacks, field rejection, p50, p95, tokens, cost. Los invariantes de la sección 14 tienen que estar en cero. Si el eval no puede correr por credenciales, se para.

No se cambia `deploy.yml` en el commit de código. Si el eval pasa, la ejecución autónoma se detiene. Una persona pone `HAIKU_QUERY_ANALYSIS_MODE=owner` y despliega en el host de los pilotos. Ahí todo typed turn usa el interpreter. No hay arbitraje con F8 dentro del request.

Smoke humano: sección 17. Después, `bin/rails turn_interpreter:smoke_check`. Lahiri no lo corre.

Rollback antes de T3: `owner` → `conditional`.

Commit de esta fase sólo si el eval obliga a un ajuste de prompt, schema o rake: `test: record the turn interpreter model eval`. Si no hubo ajuste de código, el reporte queda en este archivo.

### T3 — Retiro de la interpretación duplicada

Sólo después del PASS humano del canary.

Se retira del ask web, y se borra el código si no queda caller de producción:

- ownership semántico de `SemanticQueryAnalyzer` y `ConversationalTurnAnalysis`
- regex de diálogo y clasificación de F8/F8.1 en `ActiveEpisodeTurn`
- `TechnicalUnderstanding` como clasificador
- `filtered_prior_turns` y la reconstrucción de contexto desde turnos crudos
- `FollowupQueryRewriter.call` en el ask web
- `TechnicalReferentResolver` como intérprete del ask web
- arbitraje de ownership
- modos `conditional`, `shadow` y `off`, y la clave en `deploy.yml`

Se conserva:

- observations y `append_observation!`
- utilidades de catálogo, ya tenant-safe
- `normalize_label` y `MAX_COMPOSED_CHARS`
- Document Focus, DocumentDiscovery, replay, `KnowledgeScopePolicy`
- fotos
- `SessionContextBuilder`
- `PendingQuestion` como objeto estructural
- lo que WhatsApp dormido todavía necesite

WhatsApp no se toca. Rollback de este release: revert.

Commit: `refactor: remove the duplicate turn classifiers`

---

## 16. Regresiones obligatorias

1. Q2, sin contexto, focus 0: `clarify_first`, 0 retrieve, 0 discovery. Mention, no `fault_code`.
2. Q2 → clarify → `Monarch NICE3000`: la query contiene Q2, NICE3000 y Monarch.
3. Q2 → clarify → `No sé, busca con eso`: `best_effort`, Q2 sobrevive, no repite la aclaración.
4. Q2 → clarify → `otra falla: puertas no cierran`: el carry viejo se descarta.
5. `Es VF5, intenta cerrar, vuelve a abrir y marca E03`: busca con VF5, la observation y E03. No exige controller para arrancar.
6. `Nice300 e51` y después `¿Qué reviso?`: el segundo turno conserva el trabajo técnico.
7. Pending controller y `Volviendo a eso, no lo sé`: `controller=unknown_confirmed`. Sigue el mismo trabajo.
8. Pending controller y `ABC900`: `controller=ABC900`, `source=user`, aunque no esté en el catálogo.
9. `¿Necesitas controlador?`: no es observation y no contamina la query siguiente.
10. `No, no es NICE3000. Es NICE1000.`: el viejo queda rejected, el nuevo activo.
11. `No, no es NICE3000. Es ABC900.`: `controller=ABC900`, `source=user`, NICE3000 rejected.
12. `new_work`: episodio nuevo, sin goal, observations ni rejected viejos.
13. El Focus cambia después de Haiku y antes del lock: la perception sirve, no hay fallback sólo por el Focus, la policy ve el Focus fresco y retrieval usa esos ids.
14. Un designator privado del tenant A no tipa estado del tenant B.
15. Foto con caption: el interpreter lee el texto. El pipeline de foto sigue dueño de los facts visuales. Ese request no agrega `RetrieveAndGenerate`.
16. Replay: no llama a Haiku y no duplica la burbuja.
17. Ningún move cambia Document Focus.

---

## 17. Canary y smoke humano

Canary: un solo host, el que ya usan las cuentas piloto. No hay allowlist por cuenta. `HAIKU_QUERY_ANALYSIS_MODE=owner`. Todo typed turn de ese host pasa por el interpreter.

Lahiri actúa como técnico. PASS o `FAIL: hizo X`. No se le pide correlation id, SQL, logs ni consola.

1. Badge 0. Escribe `¿Que es Q2?`. PASS si pregunta equipo o controlador y no explica un Q2 de un manual. FAIL si cita.
2. Escribe `Es VF5, intenta cerrar, vuelve a abrir y marca E03.` PASS si responde del trabajo de puertas, o dice que no está, sin exigir el controlador para empezar.
3. En un chat limpio: `Nice300 e51` y después `¿Qué reviso?`. PASS si sigue en ese equipo y ese código.
4. Si Danebo preguntó el controlador: `Volviendo a eso, no lo sé.` PASS si sigue el mismo trabajo y no trata “controlador” como una falla nueva.
5. `¿Necesitas controlador?` y después un síntoma corto del mismo equipo. PASS si la segunda respuesta no usa esa pregunta como la falla.
6. `No, no es NICE3000. Es NICE1000.` PASS si a partir de ahí habla de NICE1000. El badge no se mueve solo.
7. Con un manual marcado, acepta una card. PASS si el badge cambia al tocarlo y la pregunta no aparece dos veces.

Preparación de un paso con badge 0: Archivos, desmarcar todo, recargar, el número dice 0.

Después del PASS, el implementador corre `turn_interpreter:smoke_check`. Si el rake falla, el canary no cierra.

---

## 18. Ejecución autónoma

Aprobado para ejecución. No se pide otra aprobación antes de T0 o T1.

1. Actualizar este archivo con los required changes.
2. T0, tests, commit, anotar aquí.
3. T1, tests, commit, anotar aquí.
4. T2 corre el eval real. Si pasa, se anotan los números y se para: el deploy y el flip a `owner` los hace una persona.
5. Después del PASS humano y del rake, T3 se implementa y se commitea.
6. No se abre otro documento.

---

## 19. Retiro

- `SemanticQueryAnalyzer` / `ConversationalTurnAnalysis`: sólo en `conditional` hasta T3. T3 los saca del ask web.
- `ActiveEpisodeTurn`: en `owner`, desde T1, no clasifica el turno escrito. T3 borra el regex de diálogo. Se quedan skip, foto, menú, pending estructurado, y el state de observations.
- `TechnicalUnderstanding`: no corre en `owner` desde T1. T3 lo borra si no tiene caller.
- `PendingQuestion`: se queda. Coerce de la pregunta estructurada, carry incluido. No crece como parser de prosa.
- `FollowupQueryRewriter.call`: fuera del ask web en T3. `normalize_label` se queda.
- `EpisodeThreadResolver`: se queda para el menú estructurado. El turno escrito en `owner` no lo llama.
- `TechnicalReferentResolver`: fuera del ask web en T3.
- `SessionContextBuilder`: se queda. Contexto de generación, no la retrieval query.
- `HaikuQueryAnalysisFlag`: `owner` se agrega en T1. T3 borra el flag.
- `DocumentDiscovery`, focus, replay, catálogo, `KnowledgeScopePolicy`: sin cambio de ownership. El catálogo gana el filtro de tenant en T0.
- `MANUFACTURERS`: no se agranda y no clasifica el diálogo. La brand la resuelve el catálogo.
- `ActiveEpisode` observations: se quedan.

FAIL arquitectónico: en un request `owner` siguen vivos el interpreter y las reglas de diálogo de F8, o `FollowupQueryRewriter.call`.

---

## 20. Hallazgos de la revisión Opus

- HEAD de implementación es `20e5620`. F8.1 está commiteado. No hay lista de working tree que excluir.
- El test de source `catalog` está vencido contra `SOURCES`. T0 lo actualiza: `catalog` se conserva; `photo` en `fault_code` se sigue tirando.
- Haiku, cuando corre en F8, corre dentro de `with_lock` de `record_user_turn!`. T1 lo saca y compara el snapshot.
- Document Focus vive en la misma fila y puede cambiar sin tocar `active_episode`. La policy lo lee fresco dentro del lock y retrieval usa ese snapshot.
- `TurnPerception` no conoce el Focus. Q2 es mention. La policy decide `clarify_first` o búsqueda según el Focus.
- `resolve_designator` sin viewer lee el YAML entero. Con `viewer_account` sólo entran filas que `KnowledgeScopePolicy` autoriza. `resolve_brand` tiene el mismo borde.
- Un literal no catalogado es identifier, salvo pending o correct donde Ruby ya sabe el slot.
- Un assert literal evita el `clarify_first` genérico. Un mention no.
- `clarify_first` puede guardar hasta dos spans en `pending_question.carry`.
- El corte del turno es `truncate`, el de `history_message`, no `first`.
- Un snapshot expired o invalid no se manda al LLM.
- `new_work` dispara el boundary `:new_episode` por la misma primitiva que el camino viejo.
- La idempotencia es por correlation del request, no por texto repetido en otro HTTP.
- Un episodio al tope de los caps más `rejected` tiene que caber en 4096 después del shrink, o no se persiste. El núcleo no se recorta.
- No hay gate por cuenta. El canary es el env del host.
- Foto con caption entra a `record_user_turn!`. V2 interpreta el caption y deja el retrieve de ese request en el pipeline de upload.

No queda un blocker de diseño.

---

## 21. Bitácora de ejecución

### T0 — `b1a4b423df1a54ac5f825b470f553d4a78fb5e00`

`test: add the tenant-safe turn perception contract`

- `TurnPerception`, `TurnText.truncate`, `resolve_designator` / `resolve_brand` con `viewer_account`.
- Sin `viewer_account` el catálogo sigue sin filtrar, para no cambiar el ask de F8. V2 no usa ese camino: sin viewer la resolución es unresolved.
- Ruby 3.4 trata un hash literal como keywords si `initialize` tiene `loaded:`. Los tests construyen el catálogo con un hash objeto.
- Tamaño medido: saturado 4218, núcleo 2167. El núcleo cabe en 4096.
- Tests de esa fase: percepción, aislamiento de catálogo, episodio y `TechnicalUnderstanding`. 0 failures.

### T1 — `849df427a3dcf2a369fece8f5abf80ff062b3d65`

`feat: run the turn interpreter when owner mode is on`

- Default sigue el camino viejo. `owner` corre un Haiku fuera del lock, compara el snapshot, lee el Focus fresco y persiste con la misma primitiva de boundary.
- Los focus ids viajan en `RoutePolicy::Decision`. Retrieval no relee el Focus.
- `pending_question.carry` (máximo 2). Un `answer_pending` value/unknown/seek los promueve a identifiers.
- Un identifier se tipa al slot pendiente o al slot negado sólo en esos dos contextos. Si el slot ya tiene un fact de catálogo, el identifier extra no se reescribe.
- Goal vacío se asigna en `report`, `follow_up` y `new_work` cuando la decisión busca. `clarify_first` y `meta` no.
- `new_work` abre episodio y el boundary es `:new_episode`.
- Idempotencia: el mismo `correlation_id` no vuelve a llamar a Haiku ni agrega otra burbuja. Dos HTTP distintos no se deduplican.
- Fallback no reemplaza `active_episode`.
- `MAX_BYTES` 4096. El shrink suelta conflicts antes que identifiers.
- Tests dirigidos de T1: 41 runs, 224 assertions, 0 failures (owner, percepción, replay). Rubocop limpio en los archivos de la fase. `git diff --check` limpio.
- Desvío: dos tests de boundary del camino viejo (`hola` tras expiry, episodio inválido) ya fallan en `b1a4b42`. Con un manual pinneado, `TechnicalUnderstanding` trata `hola` como bare identifier y abre episodio. T1 no cambia ese clasificador. El camino `owner` no lo usa.
- Siguiente: `bin/rails turn_interpreter:eval` contra Haiku real. Si pasa, parar para el flip humano. `config/deploy.yml` sigue en `conditional`.

### T2 — eval real, sin deploy

Commit del ajuste que el eval pidió: `d2bc021f962ddb914feb73443f8325be23bd2cfb`.

`bin/rails turn_interpreter:eval` contra Haiku, 2026-10-02:

```text
passes=13 mismatches=0 fallbacks=0 field_rejections=0
p50_ms=1457 p95_ms=1762
input_tokens=21775 output_tokens=2047 estimated_usd=0.032010
```

Los 13 journeys del fixture pasan. Cero fallback. Cero field rejection. `tenant_private_designator` no tipa ni filtra fabricante. `config/deploy.yml` no se tocó: sigue `conditional`.

El catálogo real de esta base no ata `NICE3000` a un `KbDocument` que la cuenta pueda leer, así que el follow-up conserva el literal `Nice300 e51`. El tipado de catálogo autorizado queda cubierto por los tests de T0/T1, no por este eval.

Parado aquí. El flip a `owner` y el deploy los hace una persona. Después del smoke de UI, el implementador corre `bin/rails turn_interpreter:smoke_check`. Rollback antes de T3: `owner` → `conditional`. T3 no empieza hasta ese PASS.
