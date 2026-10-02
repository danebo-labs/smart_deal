# Turn Interpreter V2 (2026-10-01)

**Estado:** spec definitivo para revisión Opus (`APPROVE` / `BLOCKERS`). No implementado.

**Baseline de comportamiento:** F8 en `afdb1cf`, más las reglas F8.1 escritas en [PLAN_FIELD_COMPANION_DOCUMENT_FOCUS_REFACTOR_2026-10-01.md](PLAN_FIELD_COMPANION_DOCUMENT_FOCUS_REFACTOR_2026-10-01.md).

**HEAD verificado:** `6cf8e7ca50f8a73d34a881849f4f908cbcb3ed0e` (`docs: specify the turn interpreter contract`), un commit encima de `afdb1cf`.

**Working tree verificado, no mezclar en ningún commit de este plan:**

- `app/services/rag/active_episode.rb`
- `app/services/rag/active_episode_turn.rb`
- `app/services/rag/conversational_turn_analysis.rb`
- `app/services/rag/semantic_query_analyzer.rb`
- `app/services/rag/technical_understanding.rb`
- `docs/PLAN_FIELD_COMPANION_DOCUMENT_FOCUS_REFACTOR_2026-10-01.md` (notas F8.1 locales, más el ajuste de puntero V2)
- `test/controllers/concerns/rag_query_concern_test.rb`
- `test/fixtures/files/field_companion/cases.yml`
- `test/services/rag/field_journey_test.rb` (untracked)

No volver el repo a `afdb1cf`. No revertir ese diff. No incluirlo en T0–T3. Al empezar cada fase, `git status` y stage explícito.

**Este archivo es el master de la migración.** El plan de focus sólo conserva el puntero. F9 y F10 siguen siendo el cierre de G5. No hay un tercer documento.

**Canal:** web autenticado. WhatsApp sigue dormido y no se migra.

---

## Decisiones cerradas

- Haiku interpreta el lenguaje. Ruby valida consecuencias y ejecuta.
- Todo turno conversacional escrito pasa por `TurnInterpreter`. No hay atajo “esta frase parece simple”.
- Un request no corre F8 y TurnInterpreter a la vez.
- No hay shadow de producción: ni job, ni dry-run, ni segunda llamada de observación.
- Desde el primer uso real el modo es `owner` y always-on para typed turns. El default del código sigue el camino viejo hasta el canary.
- Modelo único: `global.anthropic.claude-haiku-4-5-20251001-v1:0`. Una llamada por typed turn. `temperature` 0. `max_tokens` 512. Tool choice forzado. Sin retry semántico.
- El LLM no escribe la query, no elige la ruta, no conoce la concurrencia y no toca Document Focus.
- `switch` no existe. Un cambio de equipo que sigue el mismo trabajo es `correct`. Una tarea nueva es `new_work` y abre episodio.
- No hay `dialogue_acts`. No hay referents de respuesta. No hay `focus_labels` ni `evidence_hint`.
- `slot_hint` no crea un fact de manufacturer, model ni controller.
- Document Focus sigue user-owned. Badge `0` es el corpus autorizado. Badge `N` son exactamente esos documentos.
- Learning formal (RLHF, DPO, fine-tuning, prompt optimization online) no entra en este plan.

---

## 1. Arquitectura

```text
typed technician turn
        ↓
snapshot active_episode
        ↓
TurnInterpreter — Haiku, fuera del lock
        ↓
TurnPerception.build
        ↓
RoutePolicy(previous_state, perception)
        ↓
with_lock — compare snapshot
        ↓
WorkContextReducer  |  fallback si el snapshot cambió o la perception es inválida
        ↓
QueryComposer
        ↓
Retrieval / DocumentDiscovery
        ↓
Generation
```

`TurnPerception.build` es el único validador. No hay un servicio público `Validator`.

El reducer corre después de la policy. `clarify_first` y `meta` no escriben goal ni observations de ese turno. Ese orden es el arreglo de Q2.

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
- Foto o documento con texto: el texto sí pasa por TurnInterpreter, fuera del lock, y el reducer corre antes de capturar `expected_episode_id`. No corre el regex de `ActiveEpisodeTurn` en ese mismo request. El job de foto sigue siendo el único writer de facts `source=photo`. Este request no hace `RetrieveAndGenerate`; lo sigue cortando el camino de upload.
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
    "pending": {"slot": "controller"}
  }
}
```

`turn` es el texto ya truncado a `ConversationSession::MAX_MSG_LENGTH` (300), el mismo corte con el que se guarda el historial. Un turno más largo se trunca antes de Haiku, para que el span literal coincida con lo persistido.

No entra: chat crudo, últimos N mensajes, chunks, PDF, URI, filenames, metadata de otro tenant, labels de focus, hints de evidencia, prosa del assistant, `episode_id`, `state_version`, `correlation_id`, catálogo completo.

`pending` es null cuando no hay `pending_fact` ni `pending_question`. El slot sale de `pending_question.type` si existe, si no de `pending_fact.subject`.

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
- `follow_up`: pide el paso siguiente del trabajo ya abierto. No reemplaza el goal.
- `answer_pending`: responde el pending actual.
- `correct`: niega un valor activo y puede afirmar el reemplazo. Mismo episodio.
- `new_work`: tarea nueva. Episodio nuevo. No hereda observations, rejected, goal ni facts.
- `meta`: pregunta sobre lo que Danebo necesita. Cero mutación y cero retrieve.
- `unclear`: perception válida con cero mutaciones. No borra identity.

“No es Elemont, es KONE” es `correct`. “Otra falla: Elemont MH…” es `new_work`. No hay `switch`.

---

## 5. Bounds

Coinciden con topes que el runtime ya aplica.

| Campo | Tope | Origen |
|---|---|---|
| turn | 300 | `ConversationSession::MAX_MSG_LENGTH` |
| assertions | 8 | cerrado aquí |
| observations | 3 | `ActiveEpisode::MAX_OBSERVATIONS` |
| span | 60 | `MAX_VALUE_CHARS` |
| observation | 180 | `MAX_OBSERVATION_CHARS` |
| rejected | 4 | cada item `{slot, value}`, value 60 |
| tool JSON | 4096 bytes | si se pasa, perception inválida |

`additionalProperties: false` en el tool y en cada assertion. Pasarse de cardinalidad o de largo invalida el perception completo y dispara fallback. Un span que no es literal se rechaza como campo; si después de eso `correct` se queda sin negate activo, el move baja a `unclear` y no hay mutación.

Span literal, la normalización ya usada por `SemanticQueryAnalyzer`: NFC, downcase, colapsar espacios, trim de puntuación en los bordes, sin plegar acentos. El lookup de catálogo usa `FollowupQueryRewriter.normalize_label`, que sí pliega acentos. Las dos se mantienen. “Excélsior” puede ser span literal y además match exacto de la brand `Excelsior`.

---

## 6. TurnPerception.build

`Rag::TurnPerception.build(raw, turn:, episode:, catalog:)`.

Rechazo del perception completo:

- no es el tool input
- falta `move` o no está en el enum
- assertions u observations por encima del tope
- tool JSON por encima de 4096 bytes

Rechazo de campo, con `field` + `reason` en telemetría:

- span que no es substring literal del turno de 300
- observation que no es substring, que tiene menos de 13 caracteres, o que es un solo token de 2–4 caracteres
- `answer_pending` sin pending, o resolución cuyo valor no corresponde al slot pendiente: el move baja a `report` si quedan assertions u observations, si no a `follow_up`. No se aplica `pending_resolution`
- `correct` sin un `negate` cuyo valor normalizado está en un fact o identifier activo: baja a `unclear`, cero mutaciones
- `new_work` sin assertions ni observations, habiendo Work Context previo: baja a `follow_up` y no abre episodio
- `slot_hint` fuera de enum: se descarta el hint, se conserva el span

`unclear` es válido y no muta.

### Catálogo

`DocumentIdentityCatalog#resolve_designator` sigue como está (exacto, prefijo con las reglas de F8, ambiguo no elige).

Se agrega `resolve_brand(token)`: match exacto con `normalize_label` contra `entry.brands`. Sin prefijo y sin fuzzy. Varias entradas con la misma brand canónica son un solo manufacturer. Dos strings canónicos distintos para el mismo token normalizado son ambiguos: no se escribe manufacturer.

Orden por span:

1. Designator `:exact` con tipo declarado: slot y valor canónico del catálogo. Source `catalog`. Si la entrada tiene una sola brand, manufacturer también, source `catalog`. El hint se ignora.
2. Designator `:exact` sin tipo: identifier. No se escribe manufacturer, model ni controller.
3. Designator `:prefix` que ya cumple el umbral de F8: igual que hoy, se puede escribir.
4. Designator `:ambiguous`: no se escribe fact. La policy pregunta.
5. Brand exacta, y el span no fue designator: manufacturer, source `catalog`.
6. `fault_code` sólo si el span normalizado matchea `\A[a-z]?\d{1,4}[a-z]?\z`, no es designator ni brand, el hint o el pending dicen `fault_code`, y además hay contexto: pending ya es `fault_code`, o este turno resolvió brand o designator tipado, o hay observation válida, o `focus_count > 0`. Si no, el assertion queda `mention` y no es fact. Así `¿Que es Q2?` con focus 0 y sin contexto no persiste `fault_code=Q2`, y `Nice300 E51` sí persiste `E51` porque el designator tipado es contexto del mismo turno.
7. Hint `manufacturer|model|controller` sin match de catálogo: no se escribe fact. El desacuerdo hint/catálogo se loguea.

Un `assert` de un valor que está en `rejected` lo saca de `rejected` y lo escribe. Es la única resurrección.

Elemont y Excelsior están como brands en `config/document_identities.yml`. `resolve_brand` las toma. `NICE3000` sigue siendo designator `type: controller` de la fila Monarch. VF5 hoy es string sin tipo: queda identifier, no controller.

---

## 7. Work Context

`conversation_sessions.active_episode`, `v: 1`. Clave nueva única: `rejected`.

```text
goal
facts: manufacturer, model, controller, fault_code
identifiers
observations
pending_fact
pending_question
rejected          # max 4, {slot, value}
active_photo
conflicts
```

No se crean `component`, `measurement`, `action_taken`, `result`, `dialogue_acts`, `referents`, `state_version`, `last_applied_correlation_id`.

`unknown_confirmed` y `absent_confirmed` siguen siendo status del fact.

`rejected.slot` es uno de `manufacturer | model | controller | fault_code | identifier`.

### Tamaño

Medido con un payload al tope de los caps actuales más 4 rejected: 4268 bytes. El núcleo que no se puede tirar (facts, goal 300, pending, photo, rejected, ids) mide 2228. Un journey realista (Excelsior + VF5 + una observation + un rejected) mide alrededor de 1500.

`MAX_BYTES` pasa de 2048 a 4096.

Shrink, en este orden, y se para al quedar dentro del tope:

1. `conflicts`, del más viejo
2. `observations`, de la más vieja
3. `identifiers`, del más viejo

Nunca se sueltan `facts`, `rejected`, `pending_fact`, `pending_question`, `goal`, `active_photo` ni los ids del episodio.

Si después del shrink el JSON sigue por encima de 4096, no se persiste la mutación. Se conserva el episodio anterior, se agrega el mensaje al historial y el turno usa fallback. Se loguea `episode_budget_refused`. No hay “warning y persistir igual”.

---

## 8. Reducer

`Rag::WorkContextReducer.apply!(episode:, perception:, decision:, resolutions:, correlation_id:, now:)`.

Único writer lingüístico del episodio en modo `owner`. No escribe `document_focus`.

Corre sólo si la policy ya decidió y el snapshot sigue igual.

- `clarify_first` y `meta`: no escriben goal, facts, identifiers ni observations. `clarify_first` puede escribir el `pending_question` que decidió la policy.
- `report` con goal vacío: `assign_goal!` con el turno, tope 300. Con goal presente: el goal se queda; se agregan observations válidas.
- `follow_up` y `answer_pending`: no cambian el goal.
- `correct`: cada negate hace `clear_fact!` o saca el identifier, entra en `rejected` (si hay 4, sale el más viejo) y se borra ese valor del goal y de las observations. Si se niega un controller cuyo manufacturer es `source=catalog`, ese manufacturer también se limpia. El assert nuevo se escribe `source=user`, salvo que el catálogo lo haya tipado.
- `answer_pending` + `unknown` en manufacturer, model o controller: `unknown_confirmed`. + `absent` en fault_code: `absent_confirmed`. + `value`: write del fact. + `seek`: el fact no cambia. En todos, `clear_pending!`.
- `new_work`: `ActiveEpisode.open`. El episodio viejo no se fusiona. Goal, facts e observations salen sólo de este turno. `rejected` viejo muere con el episodio viejo.
- `unclear`: no se llama al reducer.

---

## 9. Q2 y RoutePolicy

`Rag::RoutePolicy.call(previous:, perception:, focus_count:, resolutions:)`.

`previous` es el episodio del snapshot, antes del reducer. Si el move efectivo es `new_work`, la policy trata `previous` como episodio vacío: la tarea nueva no hereda el goal viejo para esquivar `clarify_first`, ni para arrastrar su identidad.

El primero que matchea gana.

1. `move=meta`. Salida `meta`. Cero retrieve, cero discovery, cero mutación. El pending que ya existe se queda. `model_invoked=false`. Frase corta de i18n: puede seguir con lo que ya dijo. `RagQueryConcern` corta antes del orquestador.
2. `clarify_first` cuando `focus_count == 0`, `previous` no tiene identity conocida, fault, observation, goal ni foto, y este perception no tiene observation válida ni assertion resuelta a brand, designator tipado o fault_code aceptado por la regla de la sección 6, y el move no es `answer_pending`, `correct` ni `new_work`. Cero retrieve, cero discovery. El reducer no escribe el goal de este turno.
3. `best_effort` cuando `pending_resolution` es `unknown` o `seek`, o el fact ya está `unknown_confirmed` y el move es `answer_pending`. Hay retrieve. No se vuelve a preguntar ese slot. `outside_discovery=true`.
4. `search_and_clarify` cuando hay resolution `:ambiguous`, o hay manufacturer conocido (previous o brand de este turno) y faltan model y controller, controller no está `unknown_confirmed`, y hay goal, observation o fault en previous o en este perception. Hay retrieve. `pending_subject=controller`. La pregunta no entra en la query.
5. `search_and_clarify` con `ask_when=:absence` cuando `focus_count > 0` y el único token técnico es un mention de 2–4 caracteres sin designator exacto tipado. Se busca dentro del focus. La pregunta sale sólo si la respuesta se abstiene.
6. El resto es `ready`. Incluye NICE3000 con tipo y manufacturer, y un `follow_up` cuando previous ya tiene identity, fault, goal u observation.

`outside_discovery` es false en `meta`, `clarify_first` y fallback. False en el caso 5. True en `best_effort`. True en el resto. DocumentDiscovery no escribe focus.

`¿Que es Q2?`, focus 0, sin identity: mention `Q2`, sin observation, previous vacío. La regla 6 de fault no lo promueve. La regla 2 devuelve `clarify_first`. El reducer no crea goal. Cero retrieve y cero discovery.

`¿Que es Q2?` con manufacturer y controller ya conocidos, o con focus mayor que 0, no entra en la regla 2.

La policy no lee prosa del assistant. El pending estructurado que ella escribe es lo que `record_assistant_turn!` persiste. En `owner`, `write_pending!` no escanea los `?` del texto generado.

---

## 10. Query composer

`Rag::QueryComposer.call(state:, turn:, perception:, decision:)`.

`state` es el episodio después del reducer. Tope `FollowupQueryRewriter::MAX_COMPOSED_CHARS` (442). Dedupe por `normalize_label`.

Orden, que es el inverso del recorte:

1. Turno actual, sin valores `rejected` y sin spans `negate`. Se omite el turno si el move es `meta`, o `answer_pending` con resolución `unknown`, `absent` o `seek`.
2. `fault_code` activo que no esté rejected.
3. Controller, model e identifiers activos, en forma canónica si el catálogo los resolvió, sin rejected.
4. Manufacturer activo. Si era `catalog` y este turno negó el controller que lo trajo, no entra.
5. Hasta 3 observations persistidas, de la más nueva a la más vieja, saltando las que contienen un rejected.
6. Goal, si no contiene un rejected.

No se leen los últimos N mensajes. `meta` y `clarify_first` no tienen query. Si no queda nada en un `ready`, la query es el turno actual.

La string no agrega URIs ni cambia `force_entity_filter`.

---

## 11. Concurrencia, lock, fallback, idempotencia

`record_user_turn!` hoy llama `ActiveEpisodeTurn` dentro de `with_lock`, y en `conditional` eso llama a Haiku. En `owner` la llamada sale del lock.

```text
read snapshot = active_episode JSON
Haiku, fuera del lock
TurnPerception.build + RoutePolicy
with_lock
  si history ya tiene un user message con este correlation_id: return, sin segundo append y sin segundo apply
  si active_episode != snapshot: append history, fallback sobre el estado fresco, cero mutación LLM
  si igual: reducer + append history, un solo update!
```

Comparar el JSON persistido, no un `state_version` nuevo. Un write de assistant o de foto entre el snapshot y el lock cambia el JSON: se descarta la perception. No hay segunda llamada Haiku.

Writers que siguen con `expected_episode_id`: `record_assistant_turn!`, `record_photo_observation!`, auto-pin de upload. Este plan no les agrega locking nuevo.

Fallback, para timeout, throttle, tool inválido, perception inválida, snapshot distinto o `episode_budget_refused`:

- cero mutación derivada del LLM
- cero discovery
- cero cambio de focus
- cero episodio nuevo
- no corre `TechnicalUnderstanding`, ni el extract de `ActiveEpisodeTurn`, ni `FollowupQueryRewriter.call`
- si el estado fresco no tiene identity, fault, goal, observation ni foto, y focus es 0: `clarify_first` genérico
- si hay Work Context o focus: query del composer sobre ese estado fresco más el turno actual, menos rejected, decisión `ready`; si ya hay pending, se vuelve a pedir ese pending
- un designator `:exact` con tipo, o una brand exacta, en un token del turno puede entrar a la query de este request. No se persiste

Replay sigue siendo `replay_correlation_id`: no entra a `record_user_turn!`, no duplica la burbuja, no llama a Haiku. La idempotencia del turno normal es el `correlation_id` que ya guarda `history_message`. No se agrega una clave al episodio.

---

## 12. Flags

Producción hoy: `FIELD_COMPANION_EPISODE_ENABLED=true`, `FIELD_COMPANION_TURN_ENABLED=true`, `HAIKU_QUERY_ANALYSIS_MODE=conditional` en `config/deploy.yml`.

Precedencia mientras existan los tres:

1. Sin `episode_recording?` (flag de episodio apagado, canal no web, o shared session): no hay episodio y no hay interpreter.
2. `HAIKU_QUERY_ANALYSIS_MODE=owner`: typed turns usan TurnInterpreter. El regex de continuidad, `observe_ownership` y `TechnicalUnderstanding` no corren en ese request.
3. `conditional`: camino F8 actual, incluido `observe_ownership`. Es el rollback del canary.
4. `off`: F8 determinista, sin Haiku. Sigue existiendo hasta T3.
5. `shadow`: se deja como está hoy (observe que no escribe). No se construye nada nuevo encima. T3 lo borra junto con el analyzer.

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
- `prompt_version` (`2026-10-01.2`)
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

In-session: el turno validado queda en Work Context y la llamada siguiente lo ve. No hay training.

Señales para una minería posterior, ya en el evento: spans rechazados, desacuerdo hint/catálogo, `correct` en `mutations_applied`, fallback, pending que no resolvió. La aceptación de manual sigue en `manual_focus_confirmed`.

No se implementa ahora el reporte de alias, ni la promoción, ni una tabla nueva, ni fuzzy runtime. El flujo, cuando exista un rollout posterior, es: span literal desconocido → evento de este tenant → sugerencia, aceptación o corrección ya registradas → agregación offline → candidato → revisión humana → alias en catálogo o alias de tenant. Una aceptación de manual es un label débil. Una corrección posterior lo invalida. El candidato global exige evidencia pública o de `danebo_general` revisada. Apodos, filenames privados y labels de edificio se quedan en el tenant. Un trigger de revisión del estilo 5 confirmaciones, 2 usuarios y 0 conflictos es un default offline, configurable, y no corre en el request.

No se agregan excepciones Ruby del tipo `if VF5`.

RLHF, DPO, fine-tuning y optimización automática de prompt quedan diferidos hasta tener un dataset revisado y errores que schema, catálogo y prompt no resuelvan.

Deícticos (`ese borne`, `el segundo paso`, `esa placa`) no tienen referents en este MVP. Si hace falta medirlos después, un conteo `unresolved_deictic` puede salir de `follow_up` sin token de catálogo y sin fault code. No se emite en T0–T3.

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

- `¿Que es Q2?`
- VF5 progresivo, incluida `Es VF5, intenta cerrar, vuelve a abrir y marca E03`
- `Nice300 e51` → `¿Qué reviso?`
- `¿Necesitas controlador?`
- `Volviendo a eso, no lo sé` con pending controller
- `No, no es NICE3000. Es NICE1000.`
- un `new_work` tomado de R-A (`Otra falla: Elemont MH…`), marcado real porque esa frase está en el replay

No hay transcripción de Hangcha, Crown FC4000/4500, SEGURIDADES 1.1-1, ni de un journey focus 0 → manual A → manual B. No se inventa. El replay de card sigue cubierto por el test de F7.

Cada caso del YAML trae el perception esperado y las invariantes finales (decisión, hechos, tokens que la query debe contener y tokens que no debe contener). Un fallo de producción puede entrar como `origin: candidate`. No es ground truth hasta una revisión humana que lo pase a `reconstructed` o `real`.

`bin/rails turn_interpreter:eval` llama Haiku real, corre build, reducer en copia, policy y composer, e imprime: cases, passes, move mismatch, field rejection, fallback, unsafe mutation, pending accuracy, correction accuracy, query invariant failures, p50, p95, tokens, cost. No corre en CI. No es una plataforma de experimentos.

Invariantes que tienen que estar en cero en el dataset revisado antes del canary: ampliación de scope cross-tenant, mutación de Document Focus, span no literal aplicado, estado inválido persistido, valor rejected dentro de la query efectiva, mutación persistente incorrecta en los casos críticos de la sección 16.

No hay un SLO de p95. El eval imprime p50 y p95. No se despliega el canary si esa llamada, sumada al turno, deja la respuesta claramente inutilizable para un técnico en el teléfono. Ese juicio lo hace quien corre el eval, con los números, antes de pedir el deploy.

---

## 15. Fases

Cada fase inspecciona el repo, implementa, corre los tests de la fase, arregla lo que la fase rompió, corre `git diff --check`, hace un commit, y anota en este archivo commit, tests, hallazgos y desvíos. No stagea el working tree de F8.1.

Parar sólo por: blocker de arquitectura, migración destructiva, agujero de tenant, contradicción con una decisión de este documento, o una acción de producción que una persona tiene que hacer. Un test rojo se corrige y se sigue.

### T0 — Contrato, baseline, eval fixture

Objetivo: baseline verde, schema y tests puros. El request no cambia.

Archivos: este documento si un hallazgo lo corrige, `app/services/rag/turn_perception.rb`, `app/services/rag/document_identity_catalog.rb` (`resolve_brand`), `test/services/rag/turn_perception_test.rb`, `test/services/rag/active_episode_test.rb`, `test/fixtures/files/field_companion/turn_interpreter_eval.yml`, un test de bytes del episodio que todavía no sube `MAX_BYTES` (sólo fija el número: saturado 4268, núcleo 2228). `MAX_BYTES` se sube en T1, junto con `rejected`.

Baseline: el test `"source is user or photo, and photo only on manufacturer and model"` espera tirar `source=catalog`. `ActiveEpisode::SOURCES` ya incluye `catalog` desde F8. El test está viejo. Se actualiza: `catalog` se conserva; `photo` en `fault_code` se sigue tirando. Si al correr la suite aparece otro rojo anterior a esta fase, se anota aquí y se corrige sólo si es el mismo tipo de expectativa vencida. No se “arregla” cambiando `SOURCES`.

Tests: span alucinado, tool con clave extra, Q2 mention no se vuelve fault_code ni observation, brand exacta Elemont escribe manufacturer y el hint contrario queda en disagreement, designator NICE3000 pisa el hint, correct sin negate activo baja a unclear, turn de 301 caracteres se trunca a 300 antes de validar spans.

Invariante: `ask` no llama a `TurnPerception`. `deploy.yml` no cambia.

Commit: `test: add the turn perception contract`

Rollback: revert.

### T1 — Camino owner detrás del gate

Objetivo: el modo `owner` ejecuta la cadena completa. El default sigue en `conditional`.

Archivos nuevos: `app/services/rag/turn_interpreter.rb`, `app/services/rag/work_context_reducer.rb`, `app/services/rag/route_policy.rb`, `app/services/rag/query_composer.rb`, `lib/tasks/turn_interpreter.rake` (el task `eval` puede quedar esqueleto hasta T2 si la llamada real no está).

Archivos que se modifican: `app/models/conversation_session.rb` (snapshot, Haiku fuera del lock, compare, idempotencia por correlation del history), `app/controllers/rag_controller.rb`, `app/controllers/concerns/rag_query_concern.rb`, `app/services/rag/active_episode.rb` (`rejected`, `MAX_BYTES=4096`, shrink que rechaza), `app/services/rag/active_episode_turn.rb` (en `owner` no corre el regex ni `observe_ownership`; `write_pending!` no escanea prosa), `app/services/rag/haiku_query_analysis_flag.rb` (`owner?`), `app/services/pilot_usage_log.rb`.

CI usa un client falso. No llama a Haiku.

Tests de regresión, con perceptions fixture y también uno de punta a punta con el client falso:

- Q2, focus 0, previous vacío → `clarify_first`, goal nil, cero retrieve, cero discovery
- Q2 con focus > 0 → busca
- VF5 + observación de puertas + E03 → la query contiene VF5, E03 y la observation; no exige controller para arrancar
- Nice300/E51 persistidos + `follow_up` → la query contiene ambos
- pending controller + `unknown` → `unknown_confirmed`, query sin la palabra controlador, `best_effort`
- meta → esa frase no es observation ni está en la query siguiente
- correct NICE3000/NICE1000 → rejected, query con NICE1000 y sin NICE3000
- `new_work` abre episodio y no hereda observations ni rejected
- snapshot distinto → fallback, cero mutación, un solo Haiku
- mismo `correlation_id` en history → no duplica burbuja ni fact
- foto con caption → interpreter corre, el request sigue sin `RetrieveAndGenerate`, el job de foto sigue escribiendo `source=photo`
- foto sin texto → no llama al interpreter
- replay → no llama al interpreter
- episodio saturado cabe en 4096 después del shrink; un payload que no entra se rechaza y no se persiste
- el episodio no escribe `document_focus`

`conditional` sigue verde en `test/services/rag/technical_understanding_test.rb` y `test/controllers/rag_controller_technical_understanding_test.rb`.

`deploy.yml` no pasa a `owner`.

Commit: `feat: run the turn interpreter when owner mode is on`

Rollback: dejar el env en `conditional`. Las claves `rejected` las ignora una imagen vieja.

### T2 — Eval con Haiku real y canary

Objetivo: números del modelo real, después canary `owner` en el host de los pilotos.

Antes de cualquier deploy, quien implementa corre `bin/rails turn_interpreter:eval` con credenciales Bedrock. El reporte se pega en este archivo: passes, mismatches, fallback, unsafe mutations, p50, p95, tokens, cost. Los invariantes de la sección 14 tienen que estar en cero. Si el eval no puede correr por credenciales, se para: es una acción que la persona tiene que habilitar.

No se cambia `deploy.yml` en el commit de código. El canary es cambiar `HAIKU_QUERY_ANALYSIS_MODE` a `owner` y desplegar esa config. Eso lo hace una persona. Ahí se para la ejecución autónoma.

En ese host, todo typed turn usa el interpreter. No hay arbitraje con F8 dentro del request. Rollback del canary: volver el env a `conditional`, sin revertir el código.

Smoke humano: sección 17. Después, `bin/rails turn_interpreter:smoke_check` lee `pilot_events` de la sesión más reciente y afirma decisión, tokens de query, `fallback=false` y focus intacto. Lahiri no lo corre.

Commit de esta fase, sólo si el eval obliga a un ajuste de prompt, schema o rake: `test: record the turn interpreter model eval`. Si no hubo ajuste de código, no hay commit vacío; el reporte queda en este archivo y entra en el commit de T3 o en un commit de docs si el reporte existe antes del canary.

### T3 — Retiro de F8 y regresión final

Sólo después del PASS humano del canary.

Objetivo: el camino web no conserva un segundo intérprete. Rollback de este release: revert.

Se borra del camino web, y se borra el código si no queda caller de producción:

- `SemanticQueryAnalyzer`, `observe`, `observe_ownership`, `ConversationalTurnAnalysis`
- regex de continuidad y `extract!` en `ActiveEpisodeTurn`; se conservan skip reasons, foto, `selection_turn`, `apply_assistant` estructurado
- `pending_subject` sobre la prosa del assistant
- `TechnicalUnderstanding` como clasificador (`choose`, diálogo por regex, `filtered_prior_turns`, `apply!`). Si `RoutePolicy` y `QueryComposer` ya cubren el Decision, la clase se borra y los tests se mudan
- `FollowupQueryRewriter.call` en el ask web. `normalize_label` y `MAX_COMPOSED_CHARS` se quedan mientras el catálogo y el composer los usen
- `TechnicalReferentResolver` en el ask web
- modos `conditional`, `shadow` y `off` de `HaikuQueryAnalysisFlag`, y la clave en `deploy.yml`

WhatsApp no se toca. Si un caller dormido todavía referencia `FollowupQueryRewriter.call`, la clase se queda y el ask web no la llama. El grep de producción web tiene que quedar vacío de `observe_ownership`, `filtered_prior_turns`, `TechnicalUnderstanding.call` y `pending_subject` sobre prosa.

Tests: la suite de T1 más la lista de la sección 14 del plan de focus que sigue aplicando a focus y replay. `git diff --check`.

Commit: `refactor: remove the duplicate turn classifiers`

Smoke humano corto después del retiro: Q2, el follow-up de Nice300/E51, y aceptar una card. El rake `smoke_check` otra vez.

---

## 16. Regresiones obligatorias

- Q2, sin contexto, focus 0: `clarify_first`, 0 retrieve, 0 discovery.
- `Es VF5, intenta cerrar, vuelve a abrir y marca E03`: busca con VF5, la observation y E03. No bloquea pidiendo controller.
- `Nice300 e51` y después `¿Qué reviso?`: el segundo turno conserva Nice300, E51 y el goal.
- Pending controller y `Volviendo a eso, no lo sé`: `controller=unknown_confirmed`, mismo trabajo, la query no busca la palabra controlador.
- `¿Necesitas controlador?`: no es observation y no contamina la query siguiente.
- `No, no es NICE3000. Es NICE1000.`: NICE3000 fuera de la query efectiva, NICE1000 en el contexto activo, focus quieto.
- `new_work`: episodio nuevo, sin observations ni rejected del episodio anterior.
- Ningún move cambia Document Focus.
- Aceptar una card actualiza el focus, hace replay y no duplica la burbuja.

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

Después de `APPROVE` sin blocker material:

1. T0 y T1 se implementan y se commitean sin pedir aprobación entre ellas.
2. T2 corre el eval real. Si pasa, se actualiza este archivo con los números y se para: el deploy y el flip a `owner` los hace una persona.
3. Después del PASS humano y del rake, T3 se implementa y se commitea.
4. Cada fase actualiza este archivo con commit, tests, hallazgos y el ajuste de la fase siguiente.
5. No se abre otro documento.

Local test failures se corrigen. No son un motivo para parar.

---

## 19. Retiro

- `SemanticQueryAnalyzer` / `ConversationalTurnAnalysis`: se usan sólo en `conditional` hasta T3. T3 los borra.
- `ActiveEpisodeTurn`: en `owner`, desde T1, no clasifica. T3 borra el regex. Se quedan el skip, la foto, el menú y el pending estructurado.
- `TechnicalUnderstanding`: no corre en `owner` desde T1. T3 lo borra si no tiene caller.
- `PendingQuestion`: se queda. Coerce de la pregunta estructurada. No crece como parser.
- `FollowupQueryRewriter.call`: fuera del ask web en T3. `normalize_label` se queda.
- `EpisodeThreadResolver`: se queda para el menú estructurado. El turno escrito en `owner` no lo llama.
- `TechnicalReferentResolver`: fuera del ask web en T3.
- `SessionContextBuilder`: se queda. Contexto de generación, no la retrieval query.
- `HaikuQueryAnalysisFlag`: `owner` se agrega en T1. T3 borra el flag.
- `DocumentDiscovery`, focus, replay, catálogo, `DocumentIdentityScope`: sin cambio de ownership.
- `MANUFACTURERS`: no se agranda y no clasifica el diálogo. La brand la resuelve el catálogo.

FAIL arquitectónico: en un request `owner` siguen vivos el interpreter y las reglas de diálogo de F8, o `FollowupQueryRewriter.call`.

---

## 20. Hallazgos de esta revisión

- HEAD es `6cf8e7c`. F8.1 sigue sin commit en el working tree listado arriba.
- El test de source `catalog` está vencido contra `SOURCES`.
- Haiku, cuando corre, corre dentro de `with_lock` de `record_user_turn!`. T1 lo saca.
- `resolve_designator` no resuelve brands. `resolve_brand` es exacto, sin fuzzy. Elemont y Excelsior ya están en el YAML.
- Un episodio al tope de los caps más `rejected` mide 4268 bytes. 4096 alcanza porque el shrink suelta conflicts, observations e identifiers. El núcleo mide 2228. Persistirlo por encima del tope está prohibido.
- No hay gate por cuenta. El canary es el env del host.
- Foto con caption hoy igual entra a `record_user_turn!`, y el understanding de F8 no corre. V2 interpreta el caption y deja el retrieve de ese request en el pipeline de upload.

No queda un blocker de diseño.

READY FOR OPUS FINAL REVIEW
