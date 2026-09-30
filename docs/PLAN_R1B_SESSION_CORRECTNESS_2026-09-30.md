# R1B SESSION CORRECTNESS AUDIT

**Estado:** auditoría y plan de implementación. No autoriza código.

**Veredicto:** `READY_FOR_EXTERNAL_PLAN_REVIEW`

R1A permanece `CLOSED — PASS`. No se reabre. Producción al cierre de R1A: `04513a4f6317a58992a9505c1b196ae85afbc75e`. La sonda `R1A_PROBE` sigue desplegada y no se toca en R1B.

Fuente de recovery: [PLAN_FIELD_COMPANION_RECOVERY_2026-09-30.md](PLAN_FIELD_COMPANION_RECOVERY_2026-09-30.md). Si un documento viejo contradice el código actual, ganan el código y ese recovery.

Esta sesión no implementó, no modificó código ni datos, no limpió la sesión 128 y no desplegó.

## Verified existing architecture

`ConversationSession` es un workspace persistente, no un case ni un thread físico.

Schema en [db/schema.rb](../db/schema.rb), tabla `conversation_sessions`:

- índice único `idx_conversation_sessions_account_id_channel` sobre `(account_id, identifier, channel)`;
- `active_entities` jsonb, default `{}`;
- `active_episode` jsonb, default `{}`;
- `conversation_history` jsonb, default `[]`;
- `current_procedure` jsonb, default `{}`;
- `expires_at`, `session_status` default `"active"`, `user_id`, `identifier`, `channel` default `"web"`.

En web, `RagController#ask` busca con `identifier = current_user.id.to_s` y `channel = "web"`. El MVP no crea una fila nueva por cada caso técnico. La misma fila atraviesa varios casos.

Tres lifecycles conviven en esa fila y no comparten frontera:

1. `active_entities` — pins. Duran lo que dura la fila (TTL deslizante de 30 días).
2. `conversation_history` más la ventana de episodio — hasta 20 mensajes en la fila; el prompt, con `RAG_EPISODE_SCOPE_ENABLED` encendido (default), sólo usa mensajes de las últimas 4 horas.
3. `active_episode` — caso lógico. `Rag::ActiveEpisode.parse` lo considera vencido a las 4 horas y deja de exponerlo. El JSON crudo y los pins no se borran por eso.

## ConversationSession lifecycle

[app/models/conversation_session.rb](../app/models/conversation_session.rb):

- `EXPIRY_DURATION = 30.days`
- `EPISODE_WINDOW = 4.hours`
- `MAX_HISTORY = 20`

`find_or_create_for`:

1. busca por `account_id`, `identifier`, `channel`;
2. si no hay fila, crea una con `expires_at = 30.days.from_now`;
3. si hay fila y no está expirada, devuelve esa misma fila;
4. si `expires_at <= Time.current`, destruye la fila y crea otra.

La renovación física de la fila ocurre por ese expiry, no por login, no por caso nuevo y no por el vencimiento del episodio.

`refresh!` escribe `expires_at = 30.days.from_now`. `record_user_turn!` y `add_to_history_and_refresh` hacen el mismo deslizamiento en el `UPDATE` del turno.

## Login/logout behavior

[app/controllers/users/sessions_controller.rb](../app/controllers/users/sessions_controller.rb) `create`:

- autentica con Devise;
- verifica que `user.account_id` coincida con el host;
- `sign_in`;
- `PilotUsageLog` `user_signed_in`;
- `WarmBedrockKbJob`;
- redirige a `root_path`.

No llama `ConversationSession.find_or_create_for`, no mueve `expires_at`, no limpia `active_entities`, `active_episode` ni `current_procedure`, y no crea fila.

`after_sign_out_path_for` sólo devuelve `new_user_session_path`.

[app/controllers/application_controller.rb](../app/controllers/application_controller.rb) `ensure_user_belongs_to_host_account!` puede hacer `sign_out` si la cuenta no coincide con el host. Tampoco toca `ConversationSession`.

No hay callback de Warden ni otro `after_sign_out` en `app/` que opere sobre la sesión de conversación.

Login no es una `ConversationSession` nueva. Logout no destruye, no expira y no limpia la fila.

## 30-day workspace TTL

`EXPIRY_DURATION` es el ciclo de vida del workspace y del historial guardado, no del caso.

R1B no lo cambia. Un caso correcto tiene que quedar resuelto mucho antes de ese expiry.

`find_or_create_for`, al destruir una fila vencida, no tiene FK desde `field_photos.conversation_session_id` (la columna existe; el schema sólo declara FK de `field_photos` hacia `accounts`). Las fotos quedan con un id colgando. `web_manual_batches.conv_session` es opcional. No es un blocker de R1B y no entra en el cambio.

## 4-hour episode lifecycle

`Rag::ActiveEpisode.parse` ([app/services/rag/active_episode.rb](../app/services/rag/active_episode.rb)):

- payload inválido o sin `v == 1` / `episode_id` → episodio en blanco, `reason = invalid_state`;
- `updated_at` ausente o `updated_at < now - EPISODE_WINDOW` → episodio en blanco, `reason = expired`;
- si sigue vigente, expone `episode_id`, `opened_at`, `updated_at`, `goal`, `facts`, `identifiers`, `pending_fact`, `pending_question`, `active_photo`, `conflicts`.

Ese blanco es lógico. El JSON de `active_episode` sigue en la columna hasta que un turno posterior lo reemplace. `active_entities` no cambia. El pin no cambia. `conversation_history` no se borra.

`ActiveEpisode.open` crea `episode_id = ep_<hex>`, sin copiar el episodio anterior. `active_photo`, goal, facts, identifiers y pending del caso viejo no pasan al objeto nuevo. Eso sólo afecta lo que el turno persiste en `active_episode`. No limpia pins.

Flags, defaults de código:

- `FIELD_COMPANION_EPISODE_ENABLED` escribe el episodio sólo si vale `"true"`. Default off. [app/services/rag/field_companion_episode_flag.rb](../app/services/rag/field_companion_episode_flag.rb).
- `FIELD_COMPANION_TURN_ENABLED` permite que el turno lea el episodio para componer la query. Default off.
- `RAG_EPISODE_SCOPE_ENABLED` recorta el historial del prompt a 4 horas salvo que valga `"false"`. Default on.

El comentario de la flag de episodio dice que nadie lee la columna. Está viejo: `SessionContextBuilder#field_problem_block` la lee para el prompt cuando las dos flags de companion están on. El retrieve no la usa para armar URIs.

`deploy.yml` no está en el repo. El recovery registró que en la sesión 128 el episodio KONE ya había reemplazado al anterior. Eso sólo ocurre si el proceso desplegado tiene la flag de episodio encendida. Los tests de R1B deben encender las dos flags de forma explícita. La validación en producción debe confirmar el env del proceso antes de juzgar una sesión viva. R1B no enciende ni apaga esas flags.

## Pin lifecycle mismatch

`pin_kb_document!` escribe en `active_entities`: `kb_document_id`, `source_uri`, aliases, `source = user_pin`, `added_at`. No escribe `episode_id`, `expires_at` ni `case_id`.

`SessionContextBuilder.entity_s3_uris` lee `active_entities` y devuelve `source_uri`. No pregunta si `active_episode` sigue vigente.

En el path web, URIs presentes implican `resolve_retrieval_scope` → `reason: pin_only`, `force_entity_filter: true`. Un miss no reabre el corpus y no borra el pin. Eso sigue siendo el contrato dentro de un caso vivo. Lo dice [docs/SESSION_AND_RETRIEVAL.md](SESSION_AND_RETRIEVAL.md) y [docs/ACTIVE_ARCHITECTURE.md](ACTIVE_ARCHITECTURE.md). R1B no lo cambia.

Por eso hoy:

```text
Episodio T0 con pin Elemont
pasan más de 4 h
ActiveEpisode.parse → episodio vacío
active_entities → Elemont sigue
siguiente pregunta → retrieve limitado a Elemont
```

Y también, sin esperar 4 horas: un turno que ya abre otro episodio reemplaza `active_episode` y deja el pin.

## Fixture A root cause

Sesión `conversation_session_id = 128`. Pin `Elemont Montacargas Hidraulico Modelo MH`.

Query:

`En las instrucciones de instalación del KONE MonoSpace Special para máquinas MX05, MX06 y MX10 con variadores V3F18, ¿cuál es la referencia del documento, la revisión y la fecha?`

Observado:

```text
misma ConversationSession 128
active_entities todavía contiene Elemont
entity_s3_uris devuelve la URI Elemont
retrieve limitado a Elemont
chunks Elemont
abstención
```

La misma pregunta sin ese scope recuperó KONE de la cuenta 3, golden chunk en rank 1, `AM-01.01.046`, citation correcta. R1A funciona. El fallo es estado de caso viejo.

### Orden real del request

`RagController#ask`:

1. `ConversationSession.find_or_create_for`
2. `observe_semantic_shadow` — no cambia la query efectiva
3. `record_user_turn!` → `Rag::ActiveEpisodeTurn` si la flag de episodio está on
4. `SessionContextBuilder.build` y `entity_s3_uris`
5. `execute_rag_query` → resolver de catálogo, `resolve_pinned_scope` sólo si hay más de un pin, `resolve_retrieval_scope`, Bedrock

```text
incoming request
→ find_or_create_for
→ shadow semántico
→ record_user_turn / ActiveEpisodeTurn
→ entity_s3_uris(active_entities)
→ pin_only + force_entity_filter si hay URIs
→ Bedrock
```

`KbDocumentResolver` corre después de elegir las URIs. Con un solo pin no hay narrowing. El resolver no compara la pregunta con el pin para soltarlo.

### ¿Puede detectar KONE != Elemont antes del filtro?

Sí para el episodio. No para el pin.

`ActiveEpisodeTurn` corre dentro de `record_user_turn!`, antes de `entity_s3_uris`. Puede devolver `:new_episode` por:

- frase explícita (`RESET_RE`: otra falla, otro equipo, otro ascensor, etc.);
- `disjoint_catalog_equipment?` (pregunta explícita, 6+ palabras, el episodio ya tiene modelo o identificador, y un token específico del catálogo no coincide);
- forma de sujeto sobre otra marca, 6+ palabras (`SUBJECT_RE` cerca de la marca: “Ahora estoy revisando un KONE…”).

Esa decisión sólo sustituye el hash `active_episode`. No escribe `active_entities`.

La golden query, con un episodio Elemont vivo y sin modelo ni identificador de usuario, no entra en esos tres caminos. `find_brands` ve `kone`, `subject_brand?` es falso (no hay “estoy revisando” / “equipo” / “ascensor”), y cae en:

```text
:continued_mention
reason brand_mention_ignored
```

El pin no participa de esa clasificación. Aunque el turno abriera episodio nuevo, el paso 4 seguiría leyendo Elemont.

La sesión 128 ya tenía el episodio reemplazado por KONE y el pin Elemont intacto. El retrieve de la golden query usó el pin. La causa no es el corpus de R1A. Es que el pin no pertenece al lifecycle del episodio.

## Definition of Case

No confundir la fila con el caso:

```text
ConversationSession 128
  ├── Case / Episode A
  ├── Case / Episode B
  └── Case / Episode C
```

**Case = el `ActiveEpisode` vigente.** Mismo `episode_id` mientras `updated_at >= now - EPISODE_WINDOW`. No hay tabla `cases`. No hay fila nueva.

`ActiveEpisode` ya tiene `episode_id`, `opened_at`, `updated_at`, goal, facts, identifiers, pending, `active_photo` y la ventana de 4 horas. El hueco es el pin, que vive en `active_entities`, y `current_procedure`, que no tiene consumidor.

Alinear el pin con esa frontera resuelve el MVP sin migración. Guardar `episode_id` dentro del JSON del pin no hace falta.

## State ownership

| State | ConversationSession (30 días) | Case / Episode (4 h) | Turn |
|---|---:|---:|---:|
| fila `conversation_sessions` | sí | no | no |
| `expires_at` | sí | no | el turno lo desliza |
| `conversation_history` (DB, máx. 20) | sí | no | se le agrega un mensaje |
| historial usado por prompt / rewrite | no | sí, piso `opened_at` y tope 4 h | el turno actual entra |
| `active_episode` / `episode_id` | se guarda en la fila | sí | el turno lo actualiza |
| goal, facts, identifiers | no | sí | el turno los escribe |
| `pending_question` / `pending_fact` | no | sí | el assistant los escribe |
| conflicts | no | sí | el turno los escribe |
| `active_photo` | no | sí | la observación de foto lo escribe |
| `active_entities` / user pin | hoy, mal: vive aquí 30 días | debe vivir aquí | un pin explícito lo escribe |
| `current_procedure` | hoy, columna muerta en la fila | debe limpiarse con el caso | nadie lo lee |
| filas `FieldPhoto` | sobreviven a la fila si se destruye a los 30 días | no son el caso | no |
| DOM del chat | no se reconstruye desde `conversation_history` | no | el browser appende el turno |

Hoy están en el lugar equivocado: el pin y `current_procedure`. El historial de razonamiento está a medias: corta a 4 horas, no al `opened_at` de un caso nuevo abierto dentro de esa ventana.

## Time simulation strategy

Ningún test espera tiempo real. No hay `sleep`.

Usar `ActiveSupport::Testing::TimeHelpers` (`travel_to` / `travel`) y el argumento `now:` que ya aceptan `record_user_turn!`, `ActiveEpisode.parse` y `ActiveEpisodeTurn.call`.

```text
T0
  episodio + pin

travel_to(T0 + 1.hour)
  mismo caso

travel_to(T0 + 4.hours + 1.second)
  caso vencido
```

El TTL de 30 días no se prueba con espera real y no es parte del gate de R1B. No mezclarlo con el boundary del caso.

## Identity switch semantics

Tres opciones evaluadas para “Elemont pineado, la pregunta nombra KONE”:

1. Caso nuevo automático ante cualquier otra marca.
2. Detectar conflicto y soltar sólo el pin.
3. Preguntarle al técnico.

No se elige un detector nuevo ni una lista nueva de fabricantes. `ActiveEpisodeTurn::MANUFACTURERS` ya existe y R1B no la amplía ni la usa para decidir el pin. Las decisiones `:corrected`, `:continued_mention` y `:new_episode` no se modifican.

Lo que ya es caso nuevo se respeta:

- `:new_episode` (reset explícito, modelo de catálogo disjunto, sujeto “estoy revisando un KONE…”, switch del slice de ownership cuando aplica);
- `:opened` porque el episodio anterior expiró.

Lo que no es caso nuevo se respeta:

- `:corrected`. El episodio y el `episode_id` siguen. El pin sólo se suelta si la prueba de la sección siguiente da positivo;
- `:continued_mention`, incluido “¿es igual que en el KONE?” y la golden query dicha encima de un episodio Elemont todavía vivo;
- follow-up corto `K1`.

La golden query con episodio Elemont vivo queda como residual de R2 (“corrección y cambio de equipo”). R1B no la reclasifica. Fixture A de aceptación usa un boundary ya definido (episodio nuevo o expiry) y después la query KONE, para probar que el pin viejo ya no acota.

No se limpia la sesión 128 a mano.

## Corrected identity vs stale pin

Conclusión: **opción X, acotada.** No es `:corrected => borrar todos los pins`. La decisión del episodio y la compatibilidad del pin son pasos distintos. El segundo sólo corre si el primero ya devolvió `:corrected`, y sólo borra un pin cuando la incompatibilidad está demostrada con datos que el turno ya escribió.

`correct!` ([app/services/rag/active_episode_turn.rb](../app/services/rag/active_episode_turn.rb)) mantiene el mismo episodio, escribe el fabricante nuevo y borra el modelo. Eso ya es `:corrected` para “No, no es Elemont. Es KONE” cuando el episodio tenía fabricante Elemont. R1B no cambia esa clasificación.

Prueba única, sin resolver de catálogo y sin lista nueva:

1. La decisión es `:corrected`.
2. El fact `manufacturer` anterior y el nuevo están presentes y, normalizados con `FollowupQueryRewriter.normalize_label`, son distintos.
3. Un pin se suelta sólo si alguna de sus etiquetas (clave, `canonical_name`, `aliases`) contiene el fabricante anterior como palabra entera y ninguna contiene el fabricante nuevo como palabra entera.

Si el fabricante no cambió, no se toca ningún pin. Si un pin no nombra al fabricante anterior, se conserva. Si nombra a los dos, se conserva. El `episode_id`, la foto, el goal y `current_procedure` no cambian por esta prueba. El mismo `UPDATE` del turno aplica el corte antes de `entity_s3_uris`.

### Por qué no alcanzan las otras primitives

- `KbDocumentResolver` sobre “No, no es Elemont. Es KONE” matchea los dos nombres, porque los dos están en la frase. La URI Elemont queda entre los matches. Soltar el pin por “no está en los matches” no dispara. Soltarlo por “hay otro match” también soltaría un manual genérico.
- `PinnedEntityScopeResolver` sólo corre con más de un pin. Su cláusula negativa es “no uses / sin usar”, no “no es”. “Elemont” en esa frase puntúa a favor del pin.
- `DocumentIdentityCatalog` distingue MonoSpace de MiniSpace en documentos distintos, pero no está en el path de retrieve. Usarlo para decidir que “otro designador ⇒ pin incompatible” es semántica de R2 y falla el caso C.
- Un miss de retrieve no es prueba de incompatibilidad. Ese contrato no cambia.

### Casos

**A. Pin Elemont. Turno `No, no es Elemont. Es KONE`.** El fabricante del fact pasa de Elemont a KONE. El nombre del pin contiene Elemont y no contiene KONE. El pin se suelta antes del retrieve. El episodio sigue en `:corrected` con el mismo `episode_id`. El scope de ese turno queda `open`. Esta es la contaminación medida: contexto KONE con pin Elemont y retrieve `pin_only`.

**B. Pin de un manual KONE MonoSpace. Turno `No, es MiniSpace`.** No se puede demostrar incompatibilidad. `correct!` sólo corre si `other_brand` encuentra una entrada de `MANUFACTURERS`. MiniSpace no está ahí. `write_known_model` sólo acepta el marco “modelo/model es X”; esta frase no lo tiene y no escribe un fact de modelo. La decisión determinista no es `:corrected`. El catálogo sí tiene documentos MonoSpace y MiniSpace distintos, pero “el resolver devolvió otra URI” también soltaría el caso C. El pin se conserva. Fixture residual de R2. Pilot readiness sigue `NOT YET`.

**C. Pin de un manual genérico KONE, sin el fabricante reemplazado ni un designador que esta prueba pueda contradecir. Turno `No, es MiniSpace`.** Se conserva. La ausencia de “MiniSpace” en el nombre no demuestra que el manual sea el documento equivocado.

**D. Pin Elemont. Turno `K1`.** No es `:corrected`. El pin se mantiene y el retrieve sigue en `pin_only`.

## Case-boundary options

### Opción A — `added_at` contra `opened_at`

El pin sigue en `active_entities`. Se ignora si `added_at` es anterior al `opened_at` del episodio actual.

Falla el flujo normal: el técnico pinea y después pregunta. `added_at` queda unos milisegundos antes de `opened_at`, y el primer turno perdería el pin.

### Opción B — limpiar pins de caso al abrir episodio nuevo

Elegida. El almacenamiento no cambia de columna. La limpieza ocurre en el boundary, dentro del mismo `UPDATE` del turno, antes de `entity_s3_uris`.

- Episodio vivo reemplazado (`:new_episode`): se vacían los pins.
- Episodio expirado y el turno abre uno (`:opened` + `reason == expired`): se borran pins con `added_at` vacío o `added_at <= updated_at` del episodio vencido. Un pin puesto después de ese `updated_at` (el hueco, incluido después de las 4 horas) se conserva: es foco explícito del caso que empieza.
- Primer `:opened` desde `{}`: no se tocan los pins.

### Opción C — `episode_id` dentro del JSON del pin

No hace falta. La opción B distingue el caso vivo, el expiry y el pin del hueco sin esa clave.

## Recommended MVP

Primitiva única: `ConversationSession#start_new_case!(now:, reason:, correlation_id:)`.

No crea fila. Se ejecuta dentro del `with_lock` de `record_user_turn!` y entra en el mismo `update!` que ya escribe `conversation_history`, `active_episode` y `expires_at`.

Responsabilidad:

- persistir el episodio nuevo que `ActiveEpisodeTurn` ya construyó (`ActiveEpisode.open` no copia foto, goal, facts, identifiers ni pending);
- en `:new_episode`, `active_entities = {}` y `current_procedure = {}`;
- en `:opened` tras expiry, el corte por `added_at` de arriba y `current_procedure = {}`;
- en `:corrected`, soltar sólo los pins que pasen la prueba de fabricante de la sección anterior. No vaciar `active_entities` entero. No llamar a `start_new_case!`;
- no tocar `conversation_history`;
- no destruir `FieldPhoto`;
- no usar `reset_procedure!` (eso sólo limpia procedimiento y pone `session_status = active`).

Razones de boundary a registrar: `new_episode`, `episode_expired`, y en el futuro `explicit_new_case`. R1B no agrega botón ni ruta UI. La primitiva queda llamable para ese botón.

No se llama desde login, logout ni refresh.

Dentro del mismo caso, un retrieve vacío sigue sin soltar el pin.

## Scenario matrix

| Scenario | Time | Same case? | Pin | Episode | Photo | History context |
|---|---:|---|---|---|---|---|
| refresh browser | +5 min | sí | queda | queda | queda | queda el del caso |
| logout/login | +5 min | sí | queda | queda | queda | queda el del caso |
| vuelve | +1 h | sí | queda | queda | queda | queda el del caso |
| vuelve | +4 h + ε | no, al primer turno sustantivo | pin viejo fuera; pin del hueco queda | nuevo | no se reutiliza | sólo el caso nuevo |
| vuelve | +1 día | no, igual que +4 h | igual | nuevo | no se reutiliza | sólo el caso nuevo |
| Elemont pin → `K1` | inmediato | sí | queda | queda | queda | queda |
| Elemont pin → “No, no es Elemont. Es KONE” | inmediato | sí (`:corrected`) | se suelta el pin cuya etiqueta tiene Elemont y no KONE | mismo `episode_id` | queda | queda el del caso |
| Elemont pin → “Ahora estoy revisando un KONE…” | inmediato | no (`:new_episode` ya existente) | se limpia antes del retrieve | nuevo | no se copia | piso `opened_at` |
| Elemont pin → golden query KONE, episodio Elemont vivo | inmediato | sí (`:continued_mention`) | queda | queda | queda | queda |
| pin KONE MonoSpace → “No, es MiniSpace” | inmediato | sí, y no es `:corrected` | queda. Residual R2 | mismo | queda | queda |
| pin genérico KONE → “No, es MiniSpace” | inmediato | sí | queda | queda | queda | queda |
| photo → follow-up | inmediato | sí | queda | queda | se reutiliza | queda |
| photo → next day | +1 día | no | pin viejo fuera | nuevo | no se reutiliza | sólo el caso nuevo |
| futuro “Nuevo caso” | inmediato | nuevo | se limpia | nuevo | se limpia | DB intacta; razonamiento sólo del caso nuevo |

Los tiempos se prueban con reloj virtual.

## Acceptance tests

Deterministas, sin Bedrock, sin `sleep`. Las dos flags de episodio se encienden en el test.

### A — Fixture stale pin

T0: fila existente, episodio A, pin Elemont.

Boundary elegido: decisión `:new_episode`, o `travel_to(T0 + EPISODE_WINDOW + 1.second)` y un turno que abre.

Query KONE posterior (o el mismo turno, si el boundary es ese turno).

Expected: `entity_s3_uris` no contiene Elemont; `resolve_retrieval_scope` es `open`; el estado del caso viejo no entra al prompt. El orchestrator se stubbea.

### B — Same-case pin

Pin Elemont. Pregunta `K1`. Sin boundary y sin `:corrected`.

Expected: el pin sigue; `force_entity_filter` true; la URI es la de Elemont.

### I — Corrección de fabricante incompatible

Episodio con `manufacturer = Elemont`. Pin cuyo `canonical_name` es `Elemont Montacargas Hidraulico Modelo MH`. Turno `No, no es Elemont. Es KONE`.

Expected: la decisión sigue siendo `:corrected`; el `episode_id` no cambia; ese pin ya no está en `active_entities` ni en `entity_s3_uris`; el scope es `open`. No se llama a `start_new_case!`.

### J — Corrección que no demuestra incompatibilidad

Pin de manual KONE MonoSpace y turno `No, es MiniSpace`: el pin sigue. Pin genérico KONE y el mismo turno: el pin sigue. Pin que no contiene el fabricante anterior, o que contiene el anterior y el nuevo: el pin sigue. La decisión del episodio es la que el clasificador ya devuelve; el test no le exige `:corrected` a “No, es MiniSpace”.

### C — +1 hour

`travel_to(T0 + 1.hour)`. Mismo caso. El pin sigue.

### D — >4 hours

`travel_to(T0 + EPISODE_WINDOW + 1.second)`. El pin anterior al `updated_at` del episodio vencido no puede limitar la query. Un pin con `added_at` posterior a ese `updated_at` sí.

### E — refresh

Ningún GET de home ni un reload cambia episodio, pins ni `expires_at`. `HomeController#pinned_uris_for_current_session` sólo lee.

### F — logout/login

`sign_out` + `sign_in` no modifican `active_entities`, `active_episode`, `current_procedure` ni `expires_at`.

### G — history

Tras el boundary, `conversation_history` conserva los mensajes anteriores. `episode_user_messages`, `last_assistant_message`, `recent_user_turns` y `FollowupQueryRewriter#episode_rows` excluyen `ts < episode.opened_at`.

### H — photo

Follow-up inmediato dentro del episodio vigente reutiliza `active_photo`. Después del boundary, `Rag::PhotoObservationContinuity` no la reutiliza. No se afirma nada sobre billing ni retry.

## Baseline protections

No convertir cada turno en caso nuevo. Estas decisiones de `ActiveEpisodeTurn` no se modifican:

- follow-up corto y elíptico;
- corrección (“No, no es Elemont. Es KONE…”) sigue en `:corrected` y en el mismo `episode_id`. El pin Elemont se suelta por la prueba de fabricante; un pin que no nombra a Elemont no se suelta por ese turno;
- “No, es MiniSpace” no se reclasifica y no pierde el pin MonoSpace ni el pin genérico KONE;
- “¿es igual que en el KONE?” sigue en `:continued_mention`;
- “y en el KONE el LED 7?” no abre episodio;
- pin Elemont y varias preguntas del mismo caso, incluido `K1`, conservan el filtro;
- foto y follow-up inmediato conservan `active_photo`;
- un miss con pin vigente sigue en `pin_only` y no reabre el corpus;
- el baseline histórico 14/14 no se edita ni se vuelve a correr como parte de R1B.

## Probe requirements

Hace falta una sonda de transición, porque `R1A_PROBE` ve el filtro y los chunks, no el cambio de caso.

Sólo cuando esta request cambia pins o abre un boundary. Sin texto de la pregunta. Log estructurado:

```text
R1B_CASE_PROBE
conversation_session_id=
episode_before=
episode_after=
case_boundary_reason=
pin_release_reason=
pins_before=
pins_after=
active_photo_before=
active_photo_after=
```

`case_boundary_reason` queda vacío si el episodio no cambió. En el caso A de corrección, `episode_before` y `episode_after` son el mismo id y `pin_release_reason=corrected_manufacturer_mismatch`. `pins_*` son cantidades o los `kb_document_id`, no el cuerpo del manual. Se retira en R3 junto con `R1A_PROBE`. No se implementa en esta sesión.

## Non-goals

R1B no arregla:

- targeting de `AM-01.01.046` ni la respuesta `515`;
- follow-up anafórico general;
- el meta-turno que reemplaza el goal;
- reclasificar la golden query sobre un episodio Elemont vivo (`:continued_mention`);
- demostrar que un manual MonoSpace quedó incompatible con `No, es MiniSpace`, y soltar ese pin. Es fixture de R2. Pilot readiness sigue `NOT YET` hasta cerrarlo, junto con la golden query en `:continued_mention`;
- `:corrected =>` vaciar todos los pins;
- `EMPTY_TEXT` de sugerencia;
- provenance / `Guía Danebo`;
- billing de foto ni retry de análisis;
- el chip y el selection flow;
- retrieval, publication gate y corpus de R1A;
- apagar o retirar `R1A_PROBE`;
- el historial crudo que `FieldPhotoAnalysisJob` sigue recibiendo;
- el TTL de 30 días y el reemplazo físico de la fila.

## Documentation contradictions

- [SESSION_AND_RETRIEVAL.md](SESSION_AND_RETRIEVAL.md): el lifecycle del pin, el TTL de 30 días y “un miss no suelta el pin” siguen vigentes. El párrafo de corpus abierto (sólo `tenant_private` + `danebo_general`) quedó atrás. El filtro vigente es el de [ACTIVE_ARCHITECTURE.md](ACTIVE_ARCHITECTURE.md): cuenta del viewer, la otra cuenta de `SharedManualCorpus`, y `manual_corpus=general`, con el gate de R1A.
- [PLAN_CONTINUIDAD_SESION_FOLLOWUP_2026-09-21.md](PLAN_CONTINUIDAD_SESION_FOLLOWUP_2026-09-21.md) describe `pin_kept`, `pin_extended`, `pin_overridden` e `inherit_episode_scope` como caminos de retrieve. El código actual de `resolve_retrieval_scope` sólo devuelve `open` o `pin_only`. `inherit_episode_scope` devuelve vacío.
- El comentario de `FieldCompanionEpisodeFlag` (“nadie lee la columna”) es falso para el prompt. Sigue siendo cierto para las URIs de retrieve.

# Documentation Alignment

R1B define el contrato de lifecycle de `ConversationSession`, `ActiveEpisode`, el boundary de caso, los pins en `active_entities`, la ventana de razonamiento del historial, login/logout, el TTL de workspace de 30 días y la vida del caso de 4 horas.

Alinear la documentación activa con ese comportamiento es parte del Definition of Done. R1B no cierra sólo porque los tests pasan. No se crea documentación paralela. No se abre R1C ni otra fase de recovery.

## Documentos a revisar

### `docs/SESSION_AND_RETRIEVAL.md`

Queda como fuente vigente de `ConversationSession`, pins, `active_entities`, lifecycle de case/episode y el scope de retrieve que producen los pins.

Tiene que distinguir la fila del caso, decir que `Case = ActiveEpisode`, separar el TTL de 30 días de las 4 horas, decir cuándo un pin pertenece al caso y cuándo se elimina, qué pasa después del expiry, que login y logout no abren caso, y el release de pin por corrección de fabricante si esa prueba sigue aprobada. Se corrige el texto que contradiga ese contrato.

No se reintroduce el corpus previo a R1A. La visibilidad de retrieve se alinea con [PLAN_FIELD_COMPANION_RECOVERY_2026-09-30.md](PLAN_FIELD_COMPANION_RECOVERY_2026-09-30.md) y con el código R1A vigente: cuenta del viewer, la otra cuenta de `SharedManualCorpus` y `manual_corpus=general`, con el publication gate. Un miss dentro del caso vivo sigue sin soltar el pin.

### `docs/ACTIVE_ARCHITECTURE.md`

Se actualizan session lifecycle, pin scope, active episode, case boundaries y el retrieve con pins. Se quitan las afirmaciones que contradigan R1B. El documento sigue siendo arquitectura vigente, no un historial.

### `docs/PLAN_CONTINUIDAD_SESION_FOLLOWUP_2026-09-21.md`

Documento histórico del ciclo del 21-sep. No se reescribe su historia ni sus decisiones. Si puede leerse como arquitectura vigente, se agrega una nota visible al inicio: el ciclo es el del 21-sep, algunos paths quedaron superados, y la arquitectura vigente de sesiones y pins está en `SESSION_AND_RETRIEVAL.md`, `ACTIVE_ARCHITECTURE.md` y `PLAN_FIELD_COMPANION_RECOVERY_2026-09-30.md`. No se convierte en documentación viva.

### `docs/PLAN_FIELD_COMPANION_RECOVERY_2026-09-30.md`

Al cerrar R1B, esa fila pasa a `CLOSED — PASS`, con evidencia, commits, tests, smoke, decisiones finales y los carry-over que siguen en R2 o R3. R2 queda `NEXT`. No se abren fases nuevas.

### Comentarios inline

Sólo los que describen comportamiento viejo dentro del código que R1B toca o que ya se sabe falso. El comentario de [app/services/rag/field_companion_episode_flag.rb](../app/services/rag/field_companion_episode_flag.rb) dice que nadie lee `active_episode`. `SessionContextBuilder#field_problem_block` sí lo lee cuando las dos flags de companion están on. Se corrige ese comentario. No hay cleanup general del repo.

### `docs/README.md`

Sólo si una fila apunta a documentación que ya no es la arquitectura vigente. Hoy la fila de sesiones apunta a `SESSION_AND_RETRIEVAL.md` y la de arquitectura a `ACTIVE_ARCHITECTURE.md`; eso se mantiene. La fila de [PLAN_CONTINUIDAD_SESION_FOLLOWUP_2026-09-21.md](PLAN_CONTINUIDAD_SESION_FOLLOWUP_2026-09-21.md) hay que marcarla como historia del 21-sep y apuntar a las tres fuentes de abajo, sin copiar el contrato. Al cerrar R1B, la fila del recovery dice R1B `CLOSED — PASS` y R2 `NEXT`. No se duplica el contenido técnico.

## Documentation source hierarchy after R1B

| Rol | Documento |
|---|---|
| Recovery status y decisiones de fase | [PLAN_FIELD_COMPANION_RECOVERY_2026-09-30.md](PLAN_FIELD_COMPANION_RECOVERY_2026-09-30.md) |
| Arquitectura vigente de sesiones y pins | [SESSION_AND_RETRIEVAL.md](SESSION_AND_RETRIEVAL.md) |
| Arquitectura general vigente | [ACTIVE_ARCHITECTURE.md](ACTIVE_ARCHITECTURE.md) |
| Historia del ciclo 21-sep | [PLAN_CONTINUIDAD_SESION_FOLLOWUP_2026-09-21.md](PLAN_CONTINUIDAD_SESION_FOLLOWUP_2026-09-21.md) |

El documento del 21-sep no es contrato vigente cuando contradice el código o los tres documentos activos.

## Documentation gate

Antes de marcar R1B `CLOSED — PASS`:

1. implementación PASS;
2. tests PASS;
3. smoke PASS;
4. documentación alineada;
5. `git diff --check` PASS;
6. búsqueda en el repo de claims viejos sobre session TTL, episode, pins, `pin_kept`, `pin_extended`, `inherit_episode_scope`, login reset, y `ConversationSession` como thread o case.

Una contradicción en documentación activa se corrige. Una contradicción en un plan cerrado se marca como histórica. No se borra evidencia histórica.

# R1B IMPLEMENTATION PLAN

Tres fases. La fase 2 no empieza si la fase 1 no cumple su gate. La fase 3 no empieza si la fase 2 no cumple el suyo, y no cambia comportamiento. Sin migración. Sin UI. Sin `login => reset`. No hay R1C.

## Phase 1 — Case boundary

### Goal

Un episodio nuevo no hereda el pin ni `current_procedure` del caso anterior. La foto de episodio, el goal, los facts, los identifiers y el pending tampoco, porque el episodio nuevo ya nace vacío. La fila y `conversation_history` quedan. Además, un `:corrected` que cambia el fabricante suelta sólo el pin demostrado incompatible, sin abrir otro episodio.

### Files expected to change

- [app/models/conversation_session.rb](../app/models/conversation_session.rb)
- [test/models/conversation_session_test.rb](../test/models/conversation_session_test.rb)

No cambiar [app/services/rag/active_episode_turn.rb](../app/services/rag/active_episode_turn.rb).

### Behavior before

`record_user_turn!` persiste `result.state` en `active_episode` y no modifica `active_entities`. Un episodio vencido se ve vacío en `parse` y el pin sigue. `:new_episode` reemplaza el episodio y el pin sigue.

### Behavior after

Antes de `ActiveEpisodeTurn.call`, el lock recuerda `Rag::ActiveEpisode.parse(active_episode, now: now).reason` y el `updated_at` crudo del JSON (string, no el del objeto en blanco).

Después del `call`, el mismo `update!`:

- `decision == :new_episode`: `active_entities` pasa a `{}`, `current_procedure` pasa a `{}`, `active_episode` es `result.state`. Reason de sonda: `new_episode`.
- `decision == :opened` y el reason previo es `"expired"`: se eliminan entradas de `active_entities` cuya `added_at` no parsea o es `<=` ese `updated_at`; el resto se conserva; `current_procedure` pasa a `{}`. Reason: `episode_expired`.
- `decision == :opened` y el estado previo estaba vacío o era inválido sin ser expiry: `active_entities` no cambia.
- `decision == :corrected` y el fact `manufacturer` cambió: se borran sólo los pins cuya etiqueta contiene el fabricante anterior como palabra entera y no contiene el nuevo. Reason de sonda: `pin_release_reason=corrected_manufacturer_mismatch`, `case_boundary_reason` vacío, mismo `episode_id`. No se toca `current_procedure`.
- cualquier otra decisión, incluida `:corrected` sin cambio de fabricante: `active_entities` y `current_procedure` no cambian.

`session_status` no se fuerza. `expires_at` sólo se desliza como ya lo hace este método.

`start_new_case!(now:, reason:, correlation_id:)` existe para el botón futuro. Con `reason: "explicit_new_case"` abre un episodio con `ActiveEpisode.open`, vacía pins y `current_procedure`, y no borra historial. R1B no lo conecta a una ruta.

### Implementation steps

1. Leer el reason y el `updated_at` crudo dentro del lock, antes del turn.
2. Añadir el corte de pins y de `current_procedure` a los atributos del `update!` existente. No hacer un segundo `UPDATE`.
3. Dejar `ActiveEpisodeTurn` intacto, incluidos `MANUFACTURERS` y el orden de reglas.
4. Tests de modelo con `now:` y `travel_to`.

### Tests

Preservar los tests actuales de `pin_kb_document!`, `reset_procedure!`, `episode_user_messages` y `record_user_turn!`.

Nuevos, en el test de modelo, con las flags de episodio encendidas:

- episodio vivo + pin, turno que el clasificador ya marca `:new_episode` → pin ausente, `episode_id` distinto, historial conservado, `current_procedure` `{}`;
- episodio con fabricante Elemont y pin etiquetado Elemont, turno `No, no es Elemont. Es KONE` → decisión `:corrected`, mismo `episode_id`, ese pin ausente;
- el mismo turno con un segundo pin que no contiene “Elemont”, o que contiene “Elemont” y “KONE” → ese segundo pin presente;
- turno `No, es MiniSpace` con pin MonoSpace o con pin genérico KONE → esos pins presentes, sin exigir `:corrected`;
- episodio vivo + pin, turno `:continued_mention` → pin presente;
- `travel_to(T0 + 1.hour)` y un follow-up que continúa → pin presente;
- `travel_to(T0 + EPISODE_WINDOW + 1.second)`, pin con `added_at` en T0, turno sustantivo → pin ausente, episodio nuevo;
- mismo expiry, pin con `added_at` posterior al `updated_at` viejo → ese pin presente;
- `active_episode` `{}` y un pin recién puesto, primer turno → pin presente;
- `expires_at` no se acorta; el deslizamiento de 30 días del turno se mantiene.

Sin `sleep`.

### Regression protection

Re-pin idempotente, dedup por `source_uri`, y `reset_procedure!` siguen con su contrato actual. Ningún test de [test/services/rag/active_episode_turn_test.rb](../test/services/rag/active_episode_turn_test.rb) puede cambiar de `:new_episode` / `:corrected` / `:continued_mention`.

### Acceptance gate

Los tests nuevos de esta fase pasan, y la suite existente de `ConversationSession` y de `ActiveEpisodeTurn` no pierde assertions. Si una decisión de episodio cambia, la fase no cierra.

### Explicit non-goals

Retrieve, prompt, sonda, login, golden query como detector, R2 y R3. Ver la lista global.

## Phase 2 — Same-request retrieval, history floor, probe

### Goal

El turno que cruza el boundary no envía la URI vieja a Bedrock. El prompt y el rewriter no usan turnos con `ts` anterior al `opened_at` del episodio vigente.

### Files expected to change

- [app/models/conversation_session.rb](../app/models/conversation_session.rb) — piso en `episode_user_messages`, `last_assistant_message`, `recent_user_turns`
- [app/services/rag/followup_query_rewriter.rb](../app/services/rag/followup_query_rewriter.rb) — el mismo piso en `episode_rows`
- log `R1B_CASE_PROBE` en el boundary (en el modelo, junto al `update!`, o un método privado llamado desde ahí)
- [test/controllers/concerns/rag_query_concern_test.rb](../test/controllers/concerns/rag_query_concern_test.rb)
- [test/services/session_context_builder_test.rb](../test/services/session_context_builder_test.rb)
- test de follow-up que cubra `episode_rows`
- test de [app/controllers/users/sessions_controller.rb](../app/controllers/users/sessions_controller.rb) que congele login/logout
- test de [app/services/rag/photo_observation_continuity.rb](../app/services/rag/photo_observation_continuity.rb) sólo si no existe ya cobertura de episodio vencido; no cambiar el servicio si `parse` ya alcanza

[app/controllers/rag_controller.rb](../app/controllers/rag_controller.rb) no se modifica: `record_user_turn!` ya corre antes de `entity_s3_uris`. Si un test demuestra que las URIs se leen de una copia anterior al `UPDATE`, se corrige el orden en el controller y se documenta en el mismo commit de la fase. No se anticipa ese cambio.

No modificar `resolve_retrieval_scope`. Con pins vacíos ya devuelve `open`.

### Behavior before

Con pin Elemont, el scope es `pin_only` aunque el episodio ya sea otro. Mensajes de las últimas 4 horas entran a `## Recent Conversation` y al rewriter aunque `opened_at` del episodio actual sea posterior.

`recent_history_for_prompt(turns: 3)` sólo se usa si `RAG_EPISODE_SCOPE_ENABLED=false`. No se cambia ese fallback. WhatsApp usa `recent_history_for_prompt(turns: 6)` en [app/jobs/send_whatsapp_reply_job.rb](../app/jobs/send_whatsapp_reply_job.rb). Canal dormido. No se toca.

### Behavior after

Si `ActiveEpisode.parse` devuelve un episodio con `opened_at` parseable, el corte de razonamiento es:

```text
cutoff = [now - EPISODE_WINDOW, opened_at].max
```

Mensajes sin `ts` parseable siguen fuera. El tope de 3 mensajes de usuario se mantiene. `conversation_history` no se filtra al escribir.

`SessionContextBuilder` no necesita otra rama si llama a esos métodos.

Fixture A, mismo request o request siguiente según el boundary:

- Elemont no está en `entity_s3_uris`;
- `force_entity_filter` es false;
- `reason` del scope es `open`.

Control: `K1` sin boundary sigue con `force_entity_filter` true y la URI Elemont.

Login y logout no escriben la fila.

`R1B_CASE_PROBE` se emite si esta request aplicó un boundary o soltó un pin por `corrected_manufacturer_mismatch`. En ese segundo caso el `episode_id` no cambia.

Foto: sin cambio de código si el episodio nuevo no trae `active_photo` y el expiry ya hace `parse` en blanco. El test lo fija.

### Implementation steps

1. Aplicar el piso `opened_at` en los tres lectores de historial del modelo y en `episode_rows`. Usar el mismo parse. Si el episodio está en blanco, el corte sigue siendo sólo `now - EPISODE_WINDOW`.
2. No pasar ese piso a la clasificación del turno en curso: `prior_user_turns` se calcula antes de abrir el episodio nuevo, con el episodio viejo. El piso nuevo vale para el prompt de este turno (el episodio ya quedó persistido) y para el turno siguiente.
3. Añadir el log del probe en el camino que sí limpia estado.
4. Tests de concern con orchestrator stubbeado. Cero llamadas Bedrock.
5. Test de controller de sesión: después de sign out y sign in, la fila de conversación es la misma y los JSON de pin y episodio no cambiaron.

### Tests

Obligatorios, reloj virtual:

- A: episodio A, pin Elemont, boundary, query KONE → scope `open`, URI Elemont ausente;
- I: fabricante Elemont, pin Elemont, `No, no es Elemont. Es KONE` → mismo `episode_id`, decisión `:corrected`, URI Elemont ausente, scope `open`;
- J: `No, es MiniSpace` con pin MonoSpace y con pin genérico KONE → ambas URIs siguen, `force_entity_filter` true;
- B: pin Elemont, `K1`, sin boundary → URI presente, `force_entity_filter` true;
- C: `travel_to(T0 + 1.hour)` → pin presente;
- D: `travel_to(T0 + EPISODE_WINDOW + 1.second)` → pin viejo ausente del scope;
- E: un reload / `pinned_uris_for_current_session` no escribe;
- F: login y logout no escriben la fila;
- G: tras boundary dentro de la ventana de 4 horas, el mensaje anterior sigue en `conversation_history` y no aparece en el bloque `## Recent Conversation` ni en `episode_rows`;
- H: follow-up de foto con episodio vigente reutiliza `field_photo_id`; episodio nuevo o vencido no.

No añadir un test de `T0 + 30.days`.

### Regression protection

- tests de pin en `rag_query_concern_test` que esperan `force_entity_filter` true con pins vigentes;
- corrección y mención KONE en `active_episode_turn_test`;
- follow-up corto dentro del mismo `opened_at`;
- selection gate / selection turn;
- “miss no suelta el pin” mientras el episodio sigue siendo el mismo;
- no editar el baseline 14/14.

El piso de `opened_at` no debe quitar, dentro del mismo episodio, los turnos que hoy entran por la ventana de 4 horas.

### Acceptance gate

A, B, I y J pasan en el mismo archivo de test. C, D, F, G y H pasan. Un caso vivo no pierde un pin compatible. El pin Elemont sí sale en I. La fase no cierra si el controller tuvo que reordenarse y el test de orden no está.

### Explicit non-goals

Igual que la lista global. Además: no retirar `R1A_PROBE`, no cambiar `FieldPhotoAnalysisJob`, no cambiar el fallback de 3 turnos con la flag de episodio apagada, no cambiar WhatsApp. La alineación de documentación es la fase 3, no esta.

## Phase 3 — Documentation alignment + closure

### Goal

Dejar la documentación activa igual al comportamiento ya validado. Esta fase no cambia runtime, tests de producto ni retrieve.

### Files expected to change

- [docs/SESSION_AND_RETRIEVAL.md](SESSION_AND_RETRIEVAL.md)
- [docs/ACTIVE_ARCHITECTURE.md](ACTIVE_ARCHITECTURE.md)
- [docs/PLAN_FIELD_COMPANION_RECOVERY_2026-09-30.md](PLAN_FIELD_COMPANION_RECOVERY_2026-09-30.md)
- nota al inicio de [docs/PLAN_CONTINUIDAD_SESION_FOLLOWUP_2026-09-21.md](PLAN_CONTINUIDAD_SESION_FOLLOWUP_2026-09-21.md), sin reescribir el ciclo
- [docs/README.md](README.md) sólo en la fila del plan del 21-sep y, al cerrar, en la fila del recovery
- [app/services/rag/field_companion_episode_flag.rb](../app/services/rag/field_companion_episode_flag.rb), el comentario que niega lectores de `active_episode`
- otros comentarios inline sólo si describen el lifecycle viejo en código que R1B ya tocó

### Behavior before

`SESSION_AND_RETRIEVAL.md` todavía mezcla el contrato de pin de 30 días con un párrafo de corpus superado por R1A. `ACTIVE_ARCHITECTURE.md` no distingue workspace de caso. El plan del 21-sep describe `pin_kept`, `pin_extended`, `pin_overridden` e `inherit_episode_scope` sin aviso de que no son el retrieve vigente. El recovery tiene R1B en `NEXT`. El comentario de `FieldCompanionEpisodeFlag` dice que nadie lee la columna.

### Behavior after

Las tres fuentes activas describen el contrato de este plan: fila de 30 días, caso igual al `ActiveEpisode` de 4 horas, pins del caso, release por corrección de fabricante, login y logout neutros, miss que no suelta el pin dentro del caso, y corpus R1A. El plan del 21-sep sigue siendo evidencia de ese ciclo y avisa que no es el contrato. El recovery marca R1B `CLOSED — PASS` y R2 `NEXT`, con la evidencia del cierre. No aparece un documento nuevo de arquitectura.

### Implementation steps

1. Cerrar fases 1 y 2, tests y smoke antes de editar docs de contrato.
2. Actualizar `SESSION_AND_RETRIEVAL.md` y `ACTIVE_ARCHITECTURE.md` contra el código ya mergeado, no contra este plan si el código divergió.
3. Poner la nota histórica al inicio del plan del 21-sep y ajustar las dos filas necesarias de `docs/README.md`.
4. Corregir el comentario de `FieldCompanionEpisodeFlag` y cualquier otro comentario del mismo tipo dentro del scope.
5. Buscar en el repo `pin_kept`, `pin_extended`, `inherit_episode_scope`, login reset y “ConversationSession” tratado como case. Corregir docs activas. Marcar históricas. No borrar evidencia.
6. Escribir en el recovery el cierre: commits, tests, smoke, decisiones y carry-over a R2/R3.
7. `git diff --check`.

### Tests

No hay tests de comportamiento nuevos. La fase no altera aserciones. Si un comentario tocado vive junto a un test que cita el texto viejo, se actualiza esa cita y nada más.

### Regression protection

No cambiar filtros, pins, episodios ni prompts en esta fase. Un diff de `app/` que no sea un comentario se rechaza.

### Acceptance gate

Tests de las fases 1 y 2 siguen PASS. Smoke PASS. `git diff --check` PASS. La búsqueda del punto 5 no deja una doc activa contradiciendo el código. R1B queda escrito como contrato vigente en `SESSION_AND_RETRIEVAL.md` y en el recovery. R2 puede arrancar desde esos documentos, sin el chat de esta sesión.

### Explicit non-goals

No crear R1C. No reabrir R1A. No implementar el residual MiniSpace ni la golden query en `:continued_mention`. No retirar `R1A_PROBE`. No reescribir el plan del 21-sep. No duplicar el contrato en un archivo nuevo. No hacer cleanup de comentarios fuera del lifecycle de sesión.

# R1B IMPLEMENTATION CONTRACT

### What is a ConversationSession?

El workspace persistente de un usuario web en una cuenta. Una fila por `(account_id, identifier, channel)`, con `identifier` igual al id del usuario. Vive hasta 30 días deslizantes desde el último turno. No es un caso.

### What is a Case?

El `ActiveEpisode` vigente: un `episode_id` cuyo `updated_at` está dentro de `ConversationSession::EPISODE_WINDOW` (4 horas). Varios casos se suceden en la misma fila.

### What starts a new Case?

- `ActiveEpisodeTurn` devuelve `:new_episode` (reset explícito, modelo de catálogo disjunto, sujeto de equipo nuevo, switch de ownership ya existente).
- `ActiveEpisodeTurn` devuelve `:opened` y el parse del episodio anterior tenía `reason == expired`.
- Una llamada futura a `start_new_case!(reason: "explicit_new_case")`. R1B no la conecta a la UI.

### What does NOT start a new Case?

Login, logout, refresh del browser, volver a la hora, la pregunta `K1`, una corrección (`:corrected` no abre episodio, incluido “No, no es Elemont. Es KONE” y “No, es MiniSpace”), una mención que hoy es `:continued_mention` (incluida la golden query KONE sobre un episodio Elemont vivo), un miss de retrieve, y el primer `:opened` desde un `active_episode` vacío.

### What state belongs to a Case?

`episode_id` y el resto del episodio vigente (goal, facts, identifiers, pending, conflicts, `active_photo`), los pins de ese caso, y `current_procedure`.

### What survives a Case boundary?

La fila, `conversation_history`, el deslizamiento normal de `expires_at`, las filas `FieldPhoto`, y un pin cuyo `added_at` es posterior al `updated_at` del episodio que acaba de expirar. En un `:new_episode` de un caso todavía vivo no sobrevive ningún pin.

### What happens to pins?

Pasan a ser del caso, sin columna nueva y sin `episode_id` en el JSON. Al reemplazar un caso vivo se vacía `active_entities`. Al abrir después del expiry se borran los pins del caso vencido y se conserva el pin puesto en el hueco. En `:corrected`, se suelta sólo el pin cuya etiqueta contiene el fabricante anterior y no el nuevo. Un miss no los borra. “No, es MiniSpace” no los suelta: no hay fact de fabricante cambiado ni una prueba segura contra un manual MonoSpace o uno genérico KONE. Ese residual es de R2.

### What happens after 4 hours?

`ActiveEpisode.parse` deja de exponer el episodio. El JSON y el pin siguen hasta el próximo turno. Ese turno, si es sustantivo y la flag de episodio está on, abre un episodio nuevo, aplica el corte de pins del expiry, no reutiliza `active_photo` ni pending, y el prompt no usa turnos anteriores a `opened_at`. La fila de 30 días sigue.

### What happens on login/logout?

Nada sobre `ConversationSession`. Volver a entrar a los 5 minutos conserva el caso.

### Is a migration required?

NO.

### Is UI work required in R1B?

NO. No hay botón “Nuevo caso” ni rediseño del chip. El chip puede mostrar un pin que el servidor ya limpió hasta el próximo render de la home. Ese desfase es de R3.

### Production validation strategy

No limpiar la sesión 128. No usarla como fixture mutable.

Confirmar en el proceso desplegado que `FIELD_COMPANION_EPISODE_ENABLED` y `FIELD_COMPANION_TURN_ENABLED` están en `true`. Si no lo están, el boundary de episodio no corre y R1B no se valida en vivo.

En una sesión nueva, no en la 128:

1. Pin Elemont, episodio con fabricante Elemont, turno `No, no es Elemont. Es KONE`. `R1B_CASE_PROBE`: mismo `episode_id`, `pin_release_reason=corrected_manufacturer_mismatch`, pin Elemont ausente. `R1A_PROBE`: filtro abierto, no la URI Elemont.
2. Otra sesión: pin Elemont y la frase que ya es `:new_episode` (“Ahora estoy revisando un KONE que no nivela en planta 3”), después la golden query KONE. Probe con `case_boundary_reason=new_episode` y filtro abierto.
3. Control: pregunta `K1` con el pin Elemont. El filtro sigue siendo esa URI.
4. No usar “No, es MiniSpace” como prueba de que R1B soltó un pin. Si el pin MonoSpace sigue, el resultado es el esperado y el caso queda para R2.

Pilot readiness sigue `NOT YET`. R1B no cierra la golden query en `:continued_mention` ni la corrección MonoSpace → MiniSpace.

# FINAL RECOMMENDATION

`READY_FOR_EXTERNAL_PLAN_REVIEW`

La implementación espera revisión externa. Este documento no es autorización para codear.

`CORRECTED/PIN GAP RESOLVED — READY_FOR_EXTERNAL_PLAN_REVIEW`
