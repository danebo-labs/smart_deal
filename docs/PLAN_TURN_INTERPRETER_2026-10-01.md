# Turn Interpreter V2 (2026-10-01)

**Estado:** `READY FOR GROK T1.1 IMPLEMENTATION`. T0 y T1 están implementados. La revisión final de Opus fue `APPROVE WITH REQUIRED CHANGES` / `PLAN MUST BE PATCHED FIRST`; esos cambios ya están incorporados como contrato en este master plan. El owner canary sigue bloqueado hasta implementar y volver a evaluar T1.1.

**HEAD revisado para T1.1:** `9784c3d8d6523d5c1f9409e893d2db7a257a2866`.

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
- No hay shadow de producción: ni job, ni dry-run, ni segunda llamada de interpretación.
- Desde el primer uso real el modo es `owner` y always-on para typed turns. El default del código sigue el camino viejo hasta el canary.
- Modelo único del interpreter: `global.anthropic.claude-haiku-4-5-20251001-v1:0`. Una llamada de interpretación por typed turn. `temperature` 0. `max_tokens` 512. Tool choice forzado. Sin retry semántico.
- Se mantiene la separación de dos llamadas cuando hay respuesta documental: una llamada Haiku de `TurnInterpreter` y la llamada RAG/generation existente. No se fusionan y T1.1 no agrega una tercera llamada.
- El LLM no escribe la query, no elige la ruta, no conoce la concurrencia y no toca Document Focus.
- `TurnPerception` no recibe Document Focus ni `focus_count`.
- `switch` no existe. Un cambio de equipo que sigue el mismo trabajo es `correct`. Una tarea nueva es `new_work` y abre episodio.
- No hay `dialogue_acts`. No hay referents de respuesta. No hay `focus_labels` ni `evidence_hint`.
- `clarification_target` no es un referent ni una pregunta generada por el modelo. Es un enum cerrado que permite a Ruby/I18n formular una aclaración conversacional.
- La observación visual de la foto activa se lee desde el `FieldPhoto` autorizado. No se copia dentro de `active_episode`, no se reejecuta vision y no se transforma en `source=user`.
- La foto es evidencia multimodal opcional. Su ausencia conserva el comportamiento textual normal; nunca se espera, exige ni solicita una foto sólo porque no exista, y retrieval no se degrada por no tenerla.
- La mera existencia de una foto activa no autoriza contaminar query o generación. La relevancia sanitizada gobierna cada proyección visual.
- En `owner`, `writer="photo_assistant"` preserva pending por defecto. Sólo `record_photo_observation!` puede cerrarlo cuando acaba de escribir exactamente el mismo slot de fact como `known/source=photo`.
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
- Si ese texto produjo `clarify_first`, el `deliver` posterior no puede borrar ni reemplazar el pending de policy por el solo hecho de publicar prosa de la foto. Se conserva salvo la resolución estructural exacta de manufacturer/model descrita en la sección 8.

En el turno escrito posterior a una foto ya analizada, el interpreter sí puede leer una proyección pequeña de `FieldPhoto.visual_observation`. Lee datos persistidos, nunca bytes de imagen. Sólo cuenta la foto de `active_episode.active_photo`; no hay historial de fotos.

Sin foto, toda esta rama es un no-op: el turno textual, policy, composer y generación siguen el contrato normal. Una foto puede ser consulta visual, foto + pregunta, evidencia de follow-up o respuesta a un pending sólo cuando el pipeline estructurado realmente escribió ese slot; ninguna de esas funciones es obligatoria por defecto.

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
    "pending": {"slot": "controller", "carry": ["Q2"]},
    "active_photo_context": {
      "source": "photo",
      "relevance_to_goal": "relevant",
      "component": "controlador de ascensor",
      "manufacturer": "NICE",
      "model": "NICE3000",
      "visible_text": ["E51"],
      "condition": "DEGRADED"
    }
  }
}
```

`turn` es `content.to_s.truncate(ConversationSession::MAX_MSG_LENGTH)`, el mismo corte que `history_message`, incluida la omisión `"..."`. No se usa `first(300)` en un sitio y `truncate(300)` en otro. `Rag::TurnText.truncate` es el único corte.

Invariante: el turno que ve Haiku, el string de la validación de spans y el `content` persistido del usuario son el mismo texto, salvo metadata no semántica.

Antes de armar el input, el snapshot se parsea con el lifecycle real. Si el episodio está `expired`, `invalid_state` o en blanco, el `work_context` enviado al interpreter es vacío. No se mandan facts ni goal viejos para descartarlos después. El camino normal puede abrir o reemplazar el episodio según el lifecycle que ya existe.

No entra: chat crudo, últimos N mensajes, chunks, PDF, URI, filenames, bytes o thumbnail de la foto, metadata de otro tenant, labels de focus, `focus_count`, hints de evidencia, prosa del assistant, `episode_id`, `state_version`, `correlation_id`, catálogo completo ni el JSON visual completo.

`pending` es null cuando no hay `pending_fact` ni `pending_question`. Para una pregunta técnica lleva `slot` y, si existe, `carry`. Para una aclaración conversacional lleva `clarification_target`. No se mezclan ambos contratos.

`active_photo_context` es null salvo que `active_photo.field_photo_id` resuelva exactamente un `FieldPhoto` del `viewer_account` y `FieldPhotoObservation.sanitize` acepte su `visual_observation`. La proyección omite `UNKNOWN`, null, fingerprint y model id; limita component/manufacturer/model a 60 caracteres, `visible_text` a 4 valores de 40 caracteres y el JSON total a 640 bytes. Puede incluir `subsystem`, `condition`, `target_visible` y `relevance_to_goal` sólo en sus enums ya sanitizados. Un id inexistente, ajeno o una observación inválida produce contexto vacío, nunca fallback a otra foto.

### Resolución mínima de foto activa

Un PORO read-only, `Rag::ActivePhotoContext`, centraliza la carga, el recorte y tres proyecciones separadas:

```text
episode.active_photo.field_photo_id
→ FieldPhoto.where(account_id: viewer_account.id).find_by(id: ...)
→ FieldPhotoObservation.sanitize(photo.visual_observation)
→ to_prompt / query_terms / generation_block
```

La proyección se resuelve sobre el mismo snapshot que ve Haiku y se transporta durante ese request a `TurnInterpreter`, `QueryComposer` y `SessionContextBuilder`. No consulta S3, no llama a `FieldPhotoAnalysisService`, no encola `FieldPhotoAnalysisJob` y no toca `PhotoQuestionAnswerService`. Si el snapshot cambia durante la llamada, se aplica el fallback de concurrencia ya existente y se descarta la proyección vieja.

`to_prompt` puede exponer siempre la proyección autorizada y sanitizada al `TurnInterpreter`, incluida `relevance_to_goal`. Esto permite interpretar una referencia a la foto activa sin convertir sus valores en afirmaciones del técnico. `query_terms` devuelve términos sólo con `relevance_to_goal=relevant`. `generation_block` devuelve Photo Evidence sólo con `relevance_to_goal=relevant`.

Para T1.1 se elige la regla conservadora: `uncertain`, nil y `unrelated` no se inyectan automáticamente ni en query ni en generación. No se construye un relevance engine. Si una foto marcada `unrelated` respecto del goal anterior es mencionada explícitamente después, el interpreter puede verla y entender la relación conversacional, pero el MVP no dispone de una señal validada adicional para promoverla a evidencia de retrieval/generation. Sin agregar estado o schema nuevo, Ruby no debe adivinar esa promoción; puede continuar el flujo de foto existente o pedir aclaración. Éste es un límite explícito de T1.1.

Persistir un resumen en `active_episode` se rechaza para T1.1. Ahorraría una lectura indexada, pero duplicaría una columna ya durable, competiría con el presupuesto de 4096 bytes, podría quedar obsoleto ante una reparación de `visual_observation` y debilitaría la única fuente de provenance. El código actual además sanitiza deliberadamente `active_photo` a ids/correlation/sha y tiene un test que elimina `visual_observation`; no se revierte ese contrato.

`SessionContextBuilder` recibe la misma proyección acotada. Sólo `generation_block` relevante se marca explícitamente como `Photo Evidence for the active episode`, separada de `technician-stated job state` y de evidencia documental. Conserva el tope global `MAX_CONTEXT_CHARS=2000`; no aumenta el contexto máximo. `uncertain`, nil y `unrelated` no generan bloque automático en T1.1. Los conflicts siguen expresándose como `technician said X; the photo shows Y; do not resolve it`. La observación visual nunca se rotula como dicho por el técnico.

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
  "pending_resolution": null,
  "clarification_target": null
}
```

`move`: `report | follow_up | answer_pending | correct | new_work | meta | unclear`.

`act`: `assert | negate | mention`.

`slot_hint`: `manufacturer | model | controller | fault_code | designator | null`. Es hint de telemetría. El catálogo lo pisa. Solo no crea un fact de identity.

`pending_resolution`: `unknown | absent | value | seek | null`. `value` exige un `assert` cuyo span es el valor. `seek` no marca unknown y no abre otro trabajo.

`clarification_target`: `work_relation | referent | correction_target | null`. Es obligatorio como campo y sólo puede ser no-null cuando `move=unclear`. `photo_referent` no entra: la presencia y el contenido de `active_photo_context` ya distinguen ese caso. Tampoco entra texto libre de pregunta.

No salen `episode_id`, `state_version`, `correlation_id`, `evidence_hint`, `referent_id`, ruta ni query.

### Moves

- `report`: afirma o describe el trabajo en curso.
- `follow_up`: pide el paso siguiente del trabajo ya abierto. No reemplaza un goal que ya existe.
- `answer_pending`: responde el pending actual.
- `correct`: niega un valor activo y puede afirmar el reemplazo. Mismo episodio.
- `new_work`: tarea nueva. Episodio nuevo. No hereda observations, rejected, goal, facts ni carry.
- `meta`: pregunta sobre lo que Danebo necesita. Cero mutación y cero retrieve.
- `unclear`: sólo para ambigüedad conversacional material. Lleva `clarification_target`, no borra identity y no autoriza retrieval. La única escritura permitida es el `pending_question` de control; facts, goal, identifiers, observations, active photo y conflicts quedan iguales.

“No es Elemont, es KONE” es `correct`. “Otra falla: Elemont MH…” es `new_work`. No hay `switch`.

`¿Qué es Q2?` no es `unclear`: la relación con el trabajo se entiende y la insuficiencia es técnica. `No, ese era el otro` puede ser `unclear/work_relation` cuando follow-up, correction y new work sigan siendo plausibles con consecuencias distintas.

### Delta compacto del prompt

Agregar esta regla, sin ejemplos largos ni una taxonomía nueva:

```text
Interpret the current turn in relation to the active technical work and active photo.
If one interpretation is clearly dominant, choose it.
If two plausible interpretations would cause materially different episode, state,
or routing consequences, do not guess. Return unclear with a clarification_target.
Missing technical information alone is not unclear.
```

Cuando `work_context.pending.clarification_target` existe, el prompt pide clasificar la respuesta con el move definitivo. El modelo no genera la pregunta de control. Se incrementan `PROMPT_VERSION` y `SCHEMA_VERSION` en T1.1.

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
| active_photo_context | 640 bytes | proyección read-only; no entra a `active_episode` |
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
- `clarification_target` ausente, fuera del enum o inconsistente con `move` (`unclear` exige target; los demás exigen null)

Rechazo de campo, con `field` + `reason` en telemetría:

- span que no es substring literal del turno truncado
- observation que no es substring, que tiene menos de 13 caracteres, o que es un solo token de 2–4 caracteres
- `answer_pending` sin pending, o resolución cuyo valor no corresponde al slot pendiente: el move baja a `report` si quedan assertions u observations, si no a `follow_up`. No se aplica `pending_resolution`
- `correct` sin un `negate` cuyo valor normalizado está en un fact o identifier activo: baja a `unclear`, cero mutaciones
- `correct` que Ruby baja a `unclear` recibe `correction_target`; no sale a retrieval
- `new_work` sin payload técnico, habiendo Work Context previo y sin `pending_question.type=work_relation`: baja a `follow_up` y no abre episodio. Con ese pending conversacional, `new_work` es válido aunque sea thin para poder cerrar la aclaración sin regex; la policy decide después si recupera o sólo abre el nuevo episodio y pide el primer contexto técnico
- `slot_hint` fuera de enum: se descarta el hint, se conserva el span

`unclear` es válido sólo con `clarification_target`. No muta estado técnico y la policy lo corta antes de retrieval.

### Payload técnico de `new_work`

Ruby considera que un `new_work` trae payload técnico suficiente para retrieval sólo si el perception validado contiene al menos uno de estos elementos:

- una observation válida;
- una brand o designator tipado por catálogo autorizado;
- un `fault_code` aceptado por las reglas anteriores;
- un `assert` literal que el interpreter emitió como contenido técnico del nuevo trabajo.

El prompt exige que una respuesta puramente relacional a `work_relation`, como `Es otro ascensor`, no emita assertions ni observations. No se agrega regex de frase, nuevo move ni clasificador Ruby de lenguaje. Si el `new_work` válido no trae ninguno de los cuatro elementos, es `thin new_work`: abre el nuevo episodio, pero no autoriza retrieval ni discovery independientemente de `focus_count`. `Ahora tengo otro KONE que no nivela` sí trae brand y observation y sigue el camino técnico normal.

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

`conversation_sessions.active_episode`, `v: 1`. T1.1 no sube versión ni agrega el resumen visual al JSON.

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

`PendingQuestion::TYPES` agrega `work_relation`, `referent` y `correction_target`. Ninguno entra en `FACT_TYPES`, ninguno crea `pending_fact`, y ninguno usa `options`. Reutilizar `choice` sería incorrecto: sus opciones pertenecen a selecciones cerradas y `parse_reply` ya contiene semántica específica de otro flujo. No se crea otra máquina de estados.

En el input del turno siguiente:

```json
{"pending": {"clarification_target": "work_relation"}}
```

Haiku clasifica la respuesta con un move definitivo (`new_work`, `follow_up` o `correct`). `answer_pending` sigue reservado a slots técnicos. `PendingQuestion.parse_reply` no gana frases como `es otro ascensor`; no hay regex phrase-specific.

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

Excepción acotada para aclaración conversacional: si un `unclear` reemplaza un pending técnico que tenía carry, el nuevo pending conversacional conserva sólo ese carry bounded; no conserva ni anida el slot técnico anterior y limpia `pending_fact`. Si la respuesta definitiva es `new_work`, el carry se descarta con el episodio viejo. Si la respuesta mantiene el mismo episodio (`follow_up` o `correct`), el carry se promueve una sola vez a `identifiers` mediante el mecanismo existente y luego se limpia el pending conversacional. No hay stack, pending nesting ni carry eterno.

Ejemplo: `¿Qué es Q2?` → pending controller + carry Q2 → `No, ese era el otro` → pending `work_relation` + carry Q2 → `Sí, este mismo` → mismo episodio, Q2 vuelve como identifier para contexto/query. Si la última respuesta abre otro trabajo, Q2 no cruza el boundary.

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
- `new_work`: `ActiveEpisode.open`. El episodio viejo no se fusiona. Goal, facts, observations y carry salen sólo de este turno. `rejected` viejo muere con el episodio viejo. `result.decision` es `:new_episode` para el boundary. Si la policy marcó `thin new_work` como `clarify_first`, primero abre el episodio vacío, limpia `current_procedure`, descarta foto/carry/estado viejos y luego deja goal nil, sin pending técnico nuevo; la respuesta es la pregunta I18n de primer contexto. No compone query.
- `unclear`: la rama `clarify_first` escribe sólo el `pending_question` conversacional y hace `touch!`; no escribe goal, facts, identifiers, observations, rejected, conflicts ni active photo. Puede copiar el carry bounded del pending anterior al pending conversacional, pero no su slot ni `pending_fact`. El historial igual se agrega. En este documento, “0 mutation” para los journeys AMB significa cero mutación de estado técnico; el pending estructurado es la única escritura de control necesaria para interpretar la respuesta siguiente.
- resolución de pending conversacional: `new_work` descarta su carry; `follow_up` o `correct` que conservan episodio promueven ese carry una vez a identifiers antes de limpiar el pending.

### Writes del pipeline de foto en `owner`

`record_photo_observation!` y `record_assistant_turn!(writer="photo_assistant")` tienen un contrato distinto del writer lingüístico:

1. `apply_photo_observation!` informa los slots que realmente escribió en esa llamada. Para T1.1 sólo pueden ser `manufacturer` y `model`; `visible_text` no resuelve pending.
2. Dentro del mismo write protegido, `record_photo_observation!` puede cerrar pending sólo si su subject/type pertenece a `FACT_TYPES`, coincide exactamente con uno de esos slots escritos y el fact final quedó `status=known, source=photo`.
3. `record_assistant_turn!(writer="photo_assistant")` agrega la historia, pero en `owner` no ejecuta el clear/reemplazo genérico de pending. Preserva `pending_fact`, `pending_question`, carry, `work_relation`, `referent` y `correction_target`.
4. Una foto `unrelated`, bloqueada o sin valor estructurado no escribe el fact y por tanto no cierra nada. Resolver model nunca cierra controller. No se convierte la foto en turno textual artificial.
5. `conditional` no cambia.

---

## 9. RoutePolicy

`Rag::RoutePolicy.call(previous:, perception:, focus_count:, focus_document_ids:, focus_uris:)`.

Corre dentro del lock. `focus_count`, los ids y los URIs salen de la lectura fresca de Document Focus hecha en ese lock. El `Decision` se los lleva hasta retrieval. No se vuelve a leer el Focus para armar el filtro.

`previous` es el episodio del snapshot ya comparado. Si el move efectivo es `new_work`, la policy trata `previous` como episodio vacío.

El primero que matchea gana. La precedencia es contractual:

1. `move=meta`. Salida `meta`. Cero retrieve, cero discovery, cero mutación. El pending que ya existe se queda, carry incluido. `model_invoked=false`. Frase corta de i18n. `RagQueryConcern` corta antes del orquestador.
2. `move=unclear` con `clarification_target`. Salida `clarify_first`, independientemente de `focus_count` o de que el episodio sea thin. Cero retrieve, cero discovery, `owns_query=false`, `model_invoked=false`. Ruby/I18n elige una pregunta fija por target y guarda el mismo type en `pending_question`.
3. `thin new_work`: `move=new_work` válido sin payload técnico. Salida `clarify_first` con boundary `:new_episode`, cero retrieve, cero discovery, `owns_query=false` y pregunta I18n `¿Qué equipo o qué falla estás revisando?`. Aplica con focus 0 o mayor que 0. No crea otro pending type, no usa los pins para recuperar el texto relacional y no cambia Document Focus.
4. `clarify_first` técnico cuando `focus_count == 0`, `previous` no tiene identity conocida, fault, observation, goal ni foto relevante, este perception no tiene observation válida, ni assertion resuelta a brand, designator tipado o fault_code aceptado, ni un `assert` literal técnico, y el move no es `answer_pending`, `correct` ni `new_work`. Un `assert` literal técnico cuenta como contexto aunque siga siendo identifier. Un `mention` no. Cero retrieve, cero discovery. El reducer no escribe el goal. Puede escribir pending con carry.
5. `best_effort` cuando `pending_resolution` es `unknown` o `seek`, o el fact ya está `unknown_confirmed` y el move es `answer_pending`. Hay retrieve. No se vuelve a preguntar ese slot. `outside_discovery=true`.
6. `search_and_clarify` cuando hay resolution `:ambiguous` entre entradas visibles, o hay manufacturer conocido (previous o brand de este turno) y faltan model y controller, controller no está `unknown_confirmed`, y hay goal, observation o fault en previous o en este perception. Hay retrieve. `pending_subject=controller`. La pregunta no entra en la query.
7. `search_and_clarify` con `ask_when=:absence` cuando `focus_count > 0` y el único token técnico es un mention de 2–4 caracteres sin designator exacto tipado. Se busca dentro del focus. La pregunta sale sólo si la respuesta se abstiene. Q2 con focus mayor que 0 entra aquí, y sigue siendo mention, no `fault_code`.
8. El resto es `ready`. Incluye NICE3000 con tipo y manufacturer, un `assert` literal técnico no catalogado, un `new_work` con payload técnico y un `follow_up` cuando previous ya tiene identity, fault, goal u observation.

Preguntas controladas por I18n:

- `work_relation`: `¿Esto sigue siendo el mismo equipo o estás hablando de otro?`
- `referent`: `¿A qué equipo o elemento te refieres?`
- `correction_target`: `¿Qué dato del equipo quieres corregir?`

`outside_discovery` es false en `meta`, `clarify_first` y fallback. False en el caso 7 de short mention/focus. True en `best_effort`. True en las demás rutas que recuperan. DocumentDiscovery no escribe focus.

`¿Que es Q2?`, focus 0, sin identity: mention `Q2`, sin observation, previous vacío. No es fault. La regla 4 devuelve `clarify_first` y guarda carry `["Q2"]`. Cero retrieve y cero discovery.

`¿Que es Q2?` con focus mayor que 0 no entra en la regla 4. La perception sigue siendo mention. La regla 7 busca dentro de esos ids.

`El controlador es ABC900` es un assert literal técnico. No entra en la regla 4 y llega a la regla 8; no pregunta de inmediato qué controlador tiene.

`Es otro ascensor` después de pending `work_relation` llega a la regla 3: episodio nuevo vacío, `current_procedure` limpio, foto/goal/facts/observations/rejected/carry viejos fuera, cero retrieval/discovery aun con focus. `Ahora tengo otro KONE que no nivela` trae payload técnico y llega a la regla 8.

La policy no lee prosa del assistant. El pending estructurado que ella escribe es lo que `record_assistant_turn!` persiste. En `owner`, `write_pending!` no escanea los `?` del texto generado.

---

## 10. Query composer

`Rag::QueryComposer.call(state:, turn:, perception:, decision:, active_photo_context: nil)`.

`state` es el episodio después del reducer. Tope `FollowupQueryRewriter::MAX_COMPOSED_CHARS` (442). Dedupe por `normalize_label`.

Orden, que es el inverso del recorte:

1. Turno actual, sin valores `rejected` y sin spans `negate`. Se omite el turno si el move es `meta`, o `answer_pending` con resolución `unknown`, `absent` o `seek`.
2. `fault_code` activo que no esté rejected.
3. Controller, model e identifiers activos, en forma canónica si el catálogo los resolvió, sin rejected. Los spans promovidos desde `carry` entran aquí como identifiers.
4. Manufacturer activo. Si era `catalog` y este turno negó el controller que lo trajo, no entra.
5. Hasta 3 observations persistidas, de la más nueva a la más vieja, saltando las que contienen un rejected.
6. `active_photo_context.query_terms`: términos visuales compactos (`component`, manufacturer, model y `visible_text`) sólo si el contexto sigue apuntando al `state.active_photo.field_photo_id`, la decisión hace retrieval y `relevance_to_goal=relevant`.
7. Goal, si no contiene un rejected.

No se leen los últimos N mensajes. `meta` y `clarify_first` no tienen query. Si no queda nada en un `ready`, la query es el turno actual.

Los términos visuales son read-only y no se escriben como assertions, facts u observations. `uncertain`, nil y `unrelated` devuelven cero `query_terms`. `new_work` crea un state sin `active_photo`, por lo que la foto anterior no puede entrar a la query. El contexto visual que ya no coincide con el state se descarta.

La string no agrega URIs ni cambia `force_entity_filter`. El filtro de retrieval es el snapshot de URIs que viajó en el `Decision`.

---

## 11. Concurrencia, lock, fallback, idempotencia

```text
snapshot = active_episode JSON
si el snapshot está expired, invalid o blank: work_context vacío
resolver active_photo_context autorizado para ese snapshot
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
QueryComposer y SessionContextBuilder reciben la misma proyección visual read-only
```

Comparar el JSON del episodio, no un `state_version` nuevo. Un write de assistant o de foto entre el snapshot y el lock cambia el JSON: se descartan la perception y el active photo context. No hay segunda llamada Haiku. Un cambio de Focus no cambia el JSON del episodio y no dispara fallback.

Los ids que usó la policy viajan en el resultado hasta `entity_s3_uris`. No se hace un read independiente que pueda ver otro Focus.

Writers que siguen con `expected_episode_id`: `record_assistant_turn!`, `record_photo_observation!`, auto-pin de upload. Este plan no les agrega locking nuevo. Sí agrega la guarda de pending por `writer` y el cierre exacto de pending dentro del write de `record_photo_observation!`; ambos reutilizan el lock existente.

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

`move=new_work` se comporta como `:new_episode`: limpia `current_procedure` y emite la telemetría de boundary. En `thin new_work` sucede igual aunque la route sea `clarify_first`; no hay query ni discovery. Expiry e `invalid_state` siguen saliendo del JSON guardado, como hoy. Los pins no se tocan ni se usan para recuperar una respuesta relacional sin payload técnico.

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

T1 y T1.1 no cambian `deploy.yml`. El flip a `owner` es el paso de canary, después del eval real ampliado.

Después de T3 el camino web de typed turns es el interpreter siempre que `episode_recording?`. `HAIKU_QUERY_ANALYSIS_MODE` se quita de `deploy.yml` y el código deja de leerlo. Rollback de ese release: revert, no un modo.

---

## 13. Telemetría y learning

Evento nuevo `turn_interpreter` por `PilotUsageLog` → `PilotEventRecorder`. Hace falta ampliar `ALLOWED_FIELDS`, porque `log` tira las claves que no están en la lista. Strings se cortan a 500. Arrays a 20 items.

Reusar claves que ya existen cuando alcanzan: `account_id`, `user_id`, `conversation_session_id`, `correlation_id`, `model`, `latency_ms`, `input_tokens`, `output_tokens`, `episode_id`, `original_sha256`, `effective_sha256`, `route`, `pending_question_type`.

Agregar sólo:

- `turn_interpreter_status`
- `turn_interpreter_fallback`
- `prompt_version` (`2026-10-02.2` desde T1.1)
- `schema_version` (`turn_perception.3` desde T1.1)
- `catalog_fingerprint` (SHA256 de `config/document_identities.yml`, 12 hex, memoizado por proceso)
- `interpreter_move`
- `interpreter_assertions`
- `catalog_disagreement`
- `field_rejections`
- `mutations_applied`
- `pending_outcome`
- `clarification_target`
- `active_photo_context_status` (`absent | loaded | unavailable | invalid | stale`). `unavailable` agrupa id inexistente o no autorizado; no se hace un lookup sin scope para distinguirlos.
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

No se agregan `referent_id`, listas de episodios previos ni resolución libre de deícticos. T1.1 sólo permite usar la foto activa cuando es un referente dominante; si no, `unclear/referent` produce una pregunta I18n. No se emite `unresolved_deictic`.

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
- VIS-1/2/3/4 y AMB-1/2/2b/3 de T1.1, con observación visual sintetizada y marcada `reconstructed`

No hay transcripción de Hangcha, Crown FC4000/4500, SEGURIDADES 1.1-1, ni de un journey focus 0 → manual A → manual B. No se inventa. El replay de card sigue cubierto por el test de F7.

Cada caso del YAML trae el perception esperado y las invariantes finales. Un fallo de producción puede entrar como `origin: candidate`. No es ground truth hasta una revisión humana que lo pase a `reconstructed` o `real`.

`bin/rails turn_interpreter:eval` llama Haiku real, corre build, reducer en copia, policy y composer, e imprime: cases, passes, move mismatch, field rejection, fallback, unsafe mutation, pending accuracy, correction accuracy, photo-context accuracy, clarification-target accuracy, query invariant failures, p50, p95, tokens, cost. No corre en CI. No es una plataforma de experimentos.

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

### T1.1 — Active photo context + conversational clarification

Fase obligatoria antes del owner canary. No cambia el número de llamadas LLM: una llamada Haiku para interpretar y la etapa RAG/generation existente. No fusiona ambas.

Implementar:

- `Rag::ActivePhotoContext` autorizado por `account_id`, sanitizado y bounded; sólo la foto activa; responsabilidades separadas `to_prompt`, `query_terms` y `generation_block`
- transporte read-only de `to_prompt` al interpreter para toda relevancia sanitizada; `query_terms` y `generation_block` automáticos sólo para `relevant`, sin persistir contexto visual en el episode
- corte automático del contexto al abrir `new_work` o si el photo id ya no coincide
- guarda de `photo_assistant` en `owner`: la prosa nunca limpia/reemplaza pending; sólo el write estructurado exacto de manufacturer/model puede cerrar su mismo pending fact
- prompt compacto de ambigüedad material versus insuficiencia técnica
- `clarification_target` cerrado: `work_relation | referent | correction_target | null`
- `PendingQuestion` estructural para esos tres targets; sin `choice`, sin options y sin regex de respuestas
- carry bounded preservado al reemplazar un pending técnico por uno conversacional; se recupera sólo si continúa el episodio y se descarta en `new_work`
- `RoutePolicy`: `meta`, luego `unclear`, luego `thin new_work`, antes de las ramas técnicas que recuperan
- `thin new_work` después de pending `work_relation`: nuevo episodio y procedure limpio, pero 0 retrieval/discovery y pregunta I18n de primer contexto, aun con Focus
- `new_work` con payload técnico: nuevo episodio y `ready`
- bloque de generación con provenance visual explícita y sin aumentar `MAX_CONTEXT_CHARS`
- telemetría: `clarification_target`, presence/absence de active photo context y motivo de descarte; nunca valores visuales crudos
- los ocho journeys VIS/AMB y los tests unitarios de tenant, bounds, no-vision, relevance, no-contamination, photo pending y conversational carry lifecycle

Commit esperado: `feat: carry active photo context through turn interpretation`

Rollback antes del canary: revert de T1.1; el env permanece `conditional` durante toda la fase.

### T2 — Re-eval con Haiku real y canary

Después de T1.1 y antes de cualquier deploy, quien implementa vuelve a correr `bin/rails turn_interpreter:eval` con credenciales Bedrock sobre los 13 casos existentes más VIS-1/2/3/4 y AMB-1/2/2b/3: 21 journeys. El reporte se pega aquí: passes, mismatches, fallbacks, field rejection, clarification-target accuracy, photo-context accuracy, p50, p95, tokens y cost. Los invariantes de la sección 14 tienen que estar en cero. Si el eval no puede correr por credenciales, se para.

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
18. VIS-1: foto activa autorizada con NICE3000 + E51; `¿Qué reviso ahora?` → `follow_up`, `ready`, query con NICE3000/E51, contexto visual en generación y cero llamadas vision.
19. VIS-2: foto activa con un único código visual saliente; `¿Y eso qué significa?` → usa el referente visual y nunca abre `new_work`. El fixture fija `follow_up`; un test contrastivo con dos referentes materiales acepta sólo `unclear/referent` y 0 retrieval.
20. VIS-3: foto del episodio A y un turno explícito de `new_work` → episodio B sin active photo, sin términos visuales A en query o generación.
21. VIS-4: Work Context NICE3000/E51 + foto activa de otro modelo con `relevance=unrelated` + `¿Qué reviso ahora?` → el interpreter puede ver la foto, pero query y generación no contienen ni presentan sus términos como evidencia del trabajo.
22. `ActivePhotoContext`, `QueryComposer` y `SessionContextBuilder` cubren `relevant`, `uncertain` y `unrelated`: sólo `relevant` produce query terms y generation block; las tres relevancias sanitizadas pueden llegar a `to_prompt`.
23. AMB-1: con Work Context activo, `No, ese era el otro` → `unclear/work_relation`, `clarify_first`, 0 retrieval, 0 discovery y cero mutación técnica; sólo pending estructurado.
24. AMB-2: después de AMB-1, `Es otro ascensor` → `new_work` thin sin regex phrase-specific; episodio nuevo con goal nil, procedure/foto/facts/observations/rejected/carry viejos fuera, 0 retrieve, 0 discovery y pregunta I18n de primer contexto. Repetir con `focus_count > 0`; Focus queda seleccionado pero no se usa para recuperar esa frase.
25. AMB-2b: `Ahora tengo otro KONE que no nivela` → `new_work`, episodio nuevo, `ready` y query técnica con el nuevo contenido.
26. AMB-3: con foto activa, `Me refería al de la foto` → relación visual entendida, conserva active photo y clasifica definitivamente; sólo `unclear/referent` si el contexto visual deja dos referentes materialmente distintos. Una foto `unrelated` no se promueve automáticamente a evidencia en este flujo MVP.
27. Una foto ajena por `field_photo_id` no entra al prompt, query, generación ni telemetría; no se busca otra foto como fallback.
28. `VF5 / E03 / puerta intenta cerrar y vuelve a abrir` sigue en `ready` y recupera: la falta de más datos técnicos no dispara aclaración conversacional.
29. Pending `work_relation` + foto → pending intacto después de `deliver`.
30. Pending controller + carry Q2 + foto con model → model `known/source=photo`; controller y carry intactos.
31. Pending manufacturer + foto relevante con manufacturer → fact `known/source=photo` y ese pending cerrado.
32. El mismo pending manufacturer + foto `unrelated` → sin fact y pending intacto.
33. Foto + texto en `owner` cuyo texto produjo `clarify_first` → el pending de policy sobrevive a `deliver`, salvo la excepción exacta del slot estructural recién escrito.
34. Pending controller + carry Q2 → `unclear/work_relation` conserva sólo carry en pending conversacional; resolución al mismo episodio promueve Q2 una vez, mientras `new_work` lo descarta.
35. Sin foto → comportamiento textual normal, sin petición de foto ni cambios de routing/retrieval.

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
8. Envía una foto que muestre NICE3000 y E51; luego escribe `¿Qué reviso ahora?`. PASS si continúa con esa foto sin volver a analizarla ni pedir que la adjunte otra vez.
9. Con un trabajo activo escribe `No, ese era el otro`; responde a la aclaración `Es otro ascensor`. PASS si el primer turno no recupera manuales y el segundo abre el trabajo nuevo, limpia la procedure y pide qué equipo o falla revisa sin recuperar esa frase, aunque haya Focus.

Preparación de un paso con badge 0: Archivos, desmarcar todo, recargar, el número dice 0.

Después del PASS, el implementador corre `turn_interpreter:smoke_check`. Si el rake falla, el canary no cierra.

---

## 18. Ejecución autónoma

Plan parcheado y listo para ejecutar T1.1. T0 y T1 ya están completos. El flip humano sigue bloqueado.

1. Plan: required changes incorporados en este único master.
2. T0: completo y anotado.
3. T1: completo y anotado.
4. Único delta pre-canary: T1.1 implementa los contratos de foto/pending, relevancia, aclaración conversacional y `thin new_work`; corre tests y se anota aquí.
5. T2 vuelve a correr el eval real ampliado. Si pasa, se anotan los números y se para: el deploy y el flip a `owner` los hace una persona.
6. Después del PASS humano y del rake, T3 se implementa y se commitea.
7. No se abre otro documento ni T4–T8.

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
- `FieldPhotoAnalysisJob` persiste `visual_observation` antes de `deliver`; después `record_photo_observation!` guarda en el episode sólo `field_photo_id`, sha y correlation, y aplica únicamente manufacturer/model como facts `source=photo`.
- `FieldPhotoAnalysisJob#deliver` llama primero `record_photo_observation!` y después `record_assistant_turn!(writer="photo_assistant")`; hoy el segundo camino llega a `ActiveEpisodeTurn.write_pending!`, cuyo primer paso es `clear_pending!`. Sin la guarda de writer puede borrar un pending que la foto no resolvió.
- `ActiveEpisode.sanitize_photo` elimina deliberadamente `visual_observation`, summary, manufacturer y model embebidos. El test existente fija ese contrato.
- `TurnInterpreter#work_context` envía goal, facts, identifiers, observations, rejected y pending, pero no resuelve `active_photo.field_photo_id` ni lee `FieldPhoto.visual_observation`.
- `SessionContextBuilder` sólo reconstruye manufacturer/model de facts `source=photo` y conflicts. No expone component, visible text/codes, subsystem o condition de la observación durable.
- `PhotoQuestionAnswerService` ya demuestra el borde correcto para la foto del mismo turno: lookup por `account_id`, observación sanitizada y bloque visual separado. No cubre el typed turn posterior.
- El prompt actual define `unclear` como ausencia de nombre/código/síntoma. No modela ambigüedad de relación con el episodio y puede confundirla con insuficiencia técnica.
- `RoutePolicy` no tiene rama para `move=unclear`. Con un episodio no-thin, `clarify_first?` devuelve false y el final es `ready`; por eso hoy puede haber retrieval arbitrario.
- `WorkContextReducer` ya preserva el estado para `unclear`, pero su rama previa de `clarify_first` permite guardar exactamente un pending estructurado sin mutar facts/goal/observations.
- `PendingQuestion` sólo conoce slots técnicos, `choice` y `absent`; `choice` exige options y su parser tiene respuestas cerradas específicas. No es reutilizable para relación de trabajo.
- `TurnPerception` hoy degrada `new_work` sin assertions/observations a `follow_up`. La excepción condicionada por pending `work_relation` debe conservar el move para cerrar AMB-2, pero `RoutePolicy` debe cortar el `thin new_work` antes de cualquier retrieval.
- El carry actual vive en un solo `pending_question`; copiar únicamente ese array bounded al pending conversacional permite preservarlo sin stack ni otra state machine.

No queda un blocker de diseño para T1.1. Sí queda un blocker de rollout: no hacer el flip hasta implementar el delta y repetir el eval real.

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

### T2 — eval real inicial, sin deploy

Commit del ajuste que el eval pidió: `d2bc021f962ddb914feb73443f8325be23bd2cfb`.

`bin/rails turn_interpreter:eval` contra Haiku, 2026-10-02:

```text
passes=13 mismatches=0 fallbacks=0 field_rejections=0
p50_ms=1457 p95_ms=1762
input_tokens=21775 output_tokens=2047 estimated_usd=0.032010
```

Los 13 journeys del fixture pasan. Cero fallback. Cero field rejection. `tenant_private_designator` no tipa ni filtra fabricante. `config/deploy.yml` no se tocó: sigue `conditional`. Este reporte queda como baseline pre-T1.1 y no habilita el canary ampliado.

El catálogo real de esta base no ata `NICE3000` a un `KbDocument` que la cuenta pueda leer, así que el follow-up conserva el literal `Nice300 e51`. El tipado de catálogo autorizado queda cubierto por los tests de T0/T1, no por este eval.

Parado aquí. Antes del flip se implementa T1.1 y se repite T2 con los 21 journeys. El flip a `owner` y el deploy siguen siendo humanos. Después del smoke de UI, el implementador corre `bin/rails turn_interpreter:smoke_check`. Rollback antes de T3: `owner` → `conditional`. T3 no empieza hasta ese PASS.

### T1.1 — pendiente pre-canary

Revisión final de Opus sobre HEAD `9784c3d8d6523d5c1f9409e893d2db7a257a2866`. Veredicto recibido: `APPROVE WITH REQUIRED CHANGES` y `PLAN MUST BE PATCHED FIRST`. Este master incorpora los required changes; esta entrada documenta diseño solamente y no implementa T1.1.

---

## 22. Impacto y handoff de T1.1

### Latencia y tokens

- Cero llamadas vision nuevas, cero reenvío de imagen y cero llamadas LLM adicionales.
- Una lectura PostgreSQL indexada por `(account_id, id)` sólo cuando el snapshot tiene `active_photo.field_photo_id`. Seleccionar únicamente `visual_observation`; no instanciar blobs ni tocar S3.
- El prompt compacto agrega aproximadamente 45–65 input tokens a todo typed turn. `clarification_target` agrega un campo pequeño de output; `max_tokens=512` no cambia.
- Sólo los turnos con foto activa agregan la proyección visual, con hard cap de 640 bytes (aproximadamente 80–180 tokens según valores). Los turnos sin foto no cargan ese costo.
- `QueryComposer` conserva el máximo de 442 caracteres y `SessionContextBuilder` conserva 2000. El contexto visual desplaza contenido de menor prioridad si alcanza el cap; no lo expande.
- Un `unclear` material evita por completo retrieval/generation en ese turno, de modo que esa ruta reduce costo y latencia respecto del comportamiento `ready` actual.
- El baseline de 13 casos (`p50=1457 ms`, `p95=1762 ms`, 21775 input, 2047 output, USD 0.032010) no se extrapola como resultado final. T2 debe volver a medir los 21 journeys.

### Handoff para implementación Grok

Orden de cambio, sin rediseñar la cadena:

1. Fijar primero los tests de pending del pipeline de foto. En `owner`, hacer que `apply_photo_observation!` reporte sólo manufacturer/model realmente escritos, cerrar únicamente el pending fact del mismo slot y hacer que `photo_assistant` preserve cualquier otro pending. No cambiar `conditional`.
2. Crear `Rag::ActivePhotoContext` con lookup tenant-safe, sanitize, bounds, match estricto contra el photo id y las tres salidas: `to_prompt`, `query_terms`, `generation_block`. Sólo `relevant` alimenta las dos últimas.
3. En `ConversationSession#record_owner_turn!`, resolver el contexto visual desde el snapshot antes de Haiku; pasarlo como keyword opcional a `TurnInterpreter`, `QueryComposer` y `SessionContextBuilder`. En snapshot mismatch/fallback, nunca reutilizarlo.
4. Extender input/prompt/schema/result con `clarification_target`; extender `PendingQuestion::TYPES` con los tres targets conversacionales, no `FACT_TYPES`. No agregar frases a `parse_reply` ni convertir valores de foto en spans del turno.
5. Implementar el carry conversacional acotado: al escribir el pending de `unclear`, copiar sólo carry y limpiar el slot técnico; promoverlo una vez si continúa el episodio y descartarlo si la resolución es `new_work`.
6. Ordenar `RoutePolicy`: `meta` → `unclear` → `thin new_work` → clarify técnico → best effort/search → ready. El thin case abre episodio y procedure, responde con I18n, y hace 0 retrieve/discovery con cualquier Focus. El `new_work` con payload técnico sigue `ready`.
7. Ajustar reducer/boundary para que `thin new_work + clarify_first` cree efectivamente el episodio vacío con goal nil y sin estado viejo, sin crear otro pending type. Mantener Document Focus intacto.
8. Conectar `query_terms` relevantes al composer y `generation_block` relevante a `SessionContextBuilder`; probar que `uncertain` y `unrelated` quedan fuera de ambos, aunque `to_prompt` pueda llegar al interpreter.
9. Agregar los tests de la sección 16 en `active_photo_context_test`, `turn_interpreter_test`, `turn_perception_test`, `route_policy_test`, `query_composer_test`, `session_context_builder_test`, `conversation_session_turn_interpreter_test`, `conversation_session_test` y `field_photo_analysis_job_test`. Espiar servicios/jobs para probar cero vision y cero LLM adicional.
10. Añadir VIS-1/2/3/4 y AMB-1/2/2b/3 al YAML/eval, mantener los 13 casos anteriores verdes y ejecutar los 21 journeys reales. No tocar `config/deploy.yml`, no hacer deploy y no iniciar T3–T8.

Condición de salida: tests verdes, `git diff --check`, eval real ampliado sin mismatches/fallbacks/field rejections y métricas anotadas aquí. Recién entonces se entrega el flip humano a `owner`.
