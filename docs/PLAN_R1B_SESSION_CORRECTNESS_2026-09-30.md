# R1B SESSION CORRECTNESS AUDIT

**Estado:** auditoría y plan de implementación. No autoriza código.

**Veredicto:** `READY_FOR_FINAL_PLAN_REVIEW`

Red-team arquitectónico: `ARCHITECTURE_APPROVED_WITH_REQUIRED_PLAN_EDITS` sobre el plan congelado `f3424ddddf3f82940a23e78dda956dbae039e230`. La arquitectura base no cambia. Este documento incorpora esos edits. Sigue sin autorizar código.

R1A permanece `CLOSED — PASS`. No se reabre. Producción al cierre de R1A: `04513a4f6317a58992a9505c1b196ae85afbc75e`. La sonda `R1A_PROBE` sigue desplegada y no se toca en R1B.

Fuente de recovery: [PLAN_FIELD_COMPANION_RECOVERY_2026-09-30.md](PLAN_FIELD_COMPANION_RECOVERY_2026-09-30.md). Si un documento viejo contradice el código actual, ganan el código y ese recovery.

Esta sesión no implementó, no modificó código ni datos, no limpió la sesión 128 y no desplegó.

## Invariants

R1B cierra sólo si las dos se cumplen.

**Invariant 1 — boundary isolation.** Un Case nuevo no hereda estado del Case anterior. Como mínimo: pins, `active_photo`, pending, facts, identifiers, conflicts, `current_procedure` y el historial de razonamiento anterior al boundary.

**Invariant 2 — late-writer isolation.** Trabajo empezado por un Case anterior no puede modificar el estado de un Case posterior. Incluye la respuesta Bedrock de A que termina cuando B ya existe, la foto de A que termina cuando B ya existe, y el auto-pin de un upload empezado en A que termina cuando B ya existe.

El piso de historial no reemplaza el ownership. Un writer tardío se rechaza antes de entrar a `conversation_history`. Un timestamp nuevo de esa respuesta la haría entrar en el razonamiento del Case B.

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

Elegida, con el criterio de expiry del red-team. El almacenamiento no cambia de columna. La limpieza ocurre en el mismo `UPDATE` que va a sobrescribir `active_episode`, antes de `entity_s3_uris`.

El expiry es propiedad del JSON guardado, no de la decisión del clasificador. Si `ActiveEpisode.parse` del JSON almacenado tiene `reason == expired`, el cleanup corre en ese write aunque el turno sea `:opened`, `:no_episode`, `:skipped`, `:new_episode` u otra decisión que reemplace el episodio. Así, `hola` después del vencimiento no borra el marker viejo dejando el pin Elemont. `record_photo_observation!` aplica el mismo cleanup antes de abrir o escribir el Case nuevo. El cleanup es idempotente: una vez reemplazado el JSON, un segundo write ya no ve ese episodio vencido.

Un pin pertenece al Case vencido si `added_at` no parsea, está ausente, o `added_at <= updated_at del episodio + EPISODE_WINDOW`. Eso es “fue añadido mientras el Case todavía estaba vivo”. Sólo se conserva si `added_at` es posterior a ese instante: el pin se puso cuando el Case anterior ya había expirado. Ejemplo: último `updated_at` a las 10:00, expiry a las 14:00; un pin a las 10:20 se limpia; un pin a las 14:05 se conserva. `added_at` inválido se trata como viejo y se limpia. No queda ambiguo.

- Episodio vivo reemplazado (`:new_episode` y el JSON guardado no está expirado): se vacían los pins.
- JSON guardado expirado: el corte por `added_at` de arriba y `current_procedure = {}`, sea cual sea la decisión.
- Primer `:opened` desde `{}`, sin episodio expirado guardado: no se tocan los pins.

### Opción C — `episode_id` dentro del JSON del pin

No hace falta. La opción B distingue el caso vivo, el expiry y el pin del hueco sin esa clave.

## Recommended MVP

Primitiva única: `ConversationSession#start_new_case!(now:, reason:, correlation_id:)`.

No crea fila. Se ejecuta dentro del `with_lock` de `record_user_turn!` y entra en el mismo `update!` que ya escribe `conversation_history`, `active_episode` y `expires_at`.

Responsabilidad:

- persistir el episodio nuevo que `ActiveEpisodeTurn` ya construyó (`ActiveEpisode.open` no copia foto, goal, facts, identifiers ni pending);
- si el JSON guardado está expirado, aplicar el corte de pins de expiry y vaciar `current_procedure` en ese mismo write, sin mirar la decisión;
- si no está expirado y la decisión es `:new_episode`, `active_entities = {}` y `current_procedure = {}`;
- en `:corrected`, soltar sólo los pins que pasen la prueba de fabricante de la sección anterior. No vaciar `active_entities` entero. No llamar a `start_new_case!`. Un writer tardío del mismo `episode_id` no puede volver a escribir ese pin;
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
| vuelve | +4 h + ε | no, en el primer write que reemplaza el episodio, incluido `hola` o una foto | pin con `added_at <= updated_at + 4 h` fuera; pin posterior a ese instante queda | nuevo o marker viejo ya limpiado | no se reutiliza | sólo el caso nuevo |
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

`travel_to(T0 + EPISODE_WINDOW + 1.second)`. Un pin con `added_at <= updated_at + EPISODE_WINDOW` no puede limitar la query. Un pin con `added_at` posterior a ese instante sí. Un turno `hola` (`:no_episode`) ya tiene que haber hecho ese cleanup.

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

`case_boundary_reason` queda vacío si el episodio no cambió. En el caso A de corrección, `episode_before` y `episode_after` son el mismo id y `pin_release_reason=corrected_manufacturer_mismatch`. `pins_*` son cantidades o los `kb_document_id`, no el cuerpo del manual.

Un writer que no es dueño del Case emite además, o en el mismo evento:

```text
stale_case_write_dropped
conversation_session_id=
writer=
expected_episode_id=
current_episode_id=
correlation_id=
dropped=true
```

Sin texto de la query ni cuerpo del manual. Se retira en R3 junto con `R1A_PROBE`. No se implementa en esta sesión.

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
6. búsqueda en el repo de claims viejos sobre session TTL, episode, pins, `pin_kept`, `pin_extended`, `inherit_episode_scope`, login reset, `pins survive across days`, y `ConversationSession` como thread o case.

Una contradicción en documentación activa se corrige. Una contradicción en un plan cerrado se marca como histórica. No se borra evidencia histórica.

# R1B IMPLEMENTATION PLAN

Tres fases. La fase 2 no empieza si la fase 1 no cumple su gate. La fase 3 no empieza si la fase 2 no cumple el suyo, y no cambia comportamiento. Sin migración. Sin UI. Sin `login => reset`. No hay R1C.

## Phase 1 — Case boundary, expiry, pin lifecycle

### Goal

Invariant 1 para el write que reemplaza el episodio, más el lifecycle del pin: expiry independiente de la decisión, corte temporal correcto, re-pin que renueva `added_at`, y pin/unpin bajo lock. La corrección de fabricante suelta sólo el pin demostrado incompatible, sin abrir otro episodio.

### Files expected to change

- [app/models/conversation_session.rb](../app/models/conversation_session.rb) — cleanup, `pin_kb_document!`, `unpin_kb_document!`, `unpin_kb_document_id!`
- [app/controllers/pinned_documents_controller.rb](../app/controllers/pinned_documents_controller.rb) — `already_focused?` no puede saltarse el modelo
- [test/models/conversation_session_test.rb](../test/models/conversation_session_test.rb)
- tests del controller de pins / suggestion card que cubren `already_focused`

No cambiar [app/services/rag/active_episode_turn.rb](../app/services/rag/active_episode_turn.rb). El comentario del header de `PinnedDocumentsController` (“pins survive across days”) se corrige en la fase 3, no aquí.

### Behavior before

`record_user_turn!` persiste `result.state` y no toca `active_entities`. Un episodio vencido se ve vacío en `parse` y el pin sigue. Un turno `:no_episode` como `hola` puede reemplazar el JSON vencido por `{}` sin limpiar pins. `pin_kb_document!` en un documento ya presente no renueva `added_at`, y si el hash no cambia retorna sin escribir. `already_focused?` ni siquiera llama al modelo. Pin y unpin leen, copian y hacen `update!` sin `with_lock`.

### Behavior after

Dentro del lock, antes de armar el `update!`, se lee el JSON guardado. Si `parse` da `reason == expired`, se aplica el cleanup de expiry en ese mismo write, sea la decisión `:opened`, `:no_episode`, `:skipped`, `:new_episode` u otra que persista `active_episode`. No se espera a `:opened`.

Corte de expiry: se borra el pin si `added_at` falta, no parsea, o `added_at <= updated_at_guardado + EPISODE_WINDOW`. Se conserva sólo si `added_at` es posterior a ese instante. `current_procedure` pasa a `{}`. El cleanup es idempotente.

Si el JSON guardado no está expirado:

- `:new_episode` vacía pins y `current_procedure`;
- `:corrected` con fabricante cambiado quita sólo los pins incompatibles;
- el resto no toca pins.

`pin_kb_document!`, `unpin_kb_document!` y `unpin_kb_document_id!` entran en `with_lock` y construyen el hash desde la fila recargada. Un re-pin explícito escribe `added_at = Time.current` aunque el resto del hash sea igual; el `return true` actual no puede saltarse ese timestamp. El checkbox, la suggestion card y el re-pin sin unpin previo pasan por el modelo. La suggestion card puede seguir respondiendo `already_focused`.

Orden del request de texto, sin un segundo `UPDATE`:

```text
record_user_turn!
→ boundary / expiry cleanup / pin release
→ persist
→ SessionContextBuilder.entity_s3_uris
→ retrieval
```

Ese orden ya está en [app/controllers/rag_controller.rb](../app/controllers/rag_controller.rb) porque `entity_s3_uris` se lee después de que `record_user_turn!` vuelve. No hace falta editar el controller para el path de texto. Si un test muestra una copia en memoria anterior al `UPDATE`, se corrige el lector en la misma fase. No queda afirmado que el controller “no se modifica” como prohibición.

`current_procedure` se limpia en el boundary y no tiene consumer de runtime. No se le diseña nada más. `reset_procedure!` no es el reset de caso.

### Implementation steps

1. Helper de expiry sobre el JSON guardado, usado por `record_user_turn!` y, en la fase 2, por `record_photo_observation!`.
2. Aplicar ese helper antes de persistir el episodio nuevo, sin filtrar por decisión.
3. Renovar `added_at` en todo pin explícito, dentro del lock, incluso si el resto no cambia.
4. Quitar el atajo de `already_focused?` que evita `pin_kb_document!`. La respuesta HTTP puede seguir igual.
5. No tocar `ActiveEpisodeTurn`.
6. Tests con `travel_to`. El test `pin_kb_document! merges new aliases when re-pinning the same document` hoy exige que `added_at` no cambie. Hay que invertirlo: con `travel_to`, el re-pin deja un `added_at` nuevo y conserva aliases, `source_uri` y `kb_document_id`.

### Required tests

Flags de episodio encendidas. Reloj virtual. Sin Bedrock. Sin `sleep`.

- `:new_episode` sobre episodio vivo → pins vacíos, otro `episode_id`, historial conservado, `current_procedure` `{}`.
- `No, no es Elemont. Es KONE` → `:corrected`, mismo `episode_id`, sólo el pin Elemont fuera. Un segundo pin sin esa incompatibilidad queda.
- `No, es MiniSpace` → pin MonoSpace y pin genérico KONE quedan. No se exige `:corrected`.
- `:continued_mention` y `K1` → pin queda.
- `travel_to(T0 + 1.hour)` → mismo caso, pin queda.
- Test 4: episodio expirado, turno `hola` con decisión `:no_episode`. El pin Elemont ya no está. Una query KONE posterior ve `entity_s3_uris` vacío.
- Test 6: `updated_at` en T0, pin a T0 + 20 s, luego expiry. El pin se limpia. Control: pin con `added_at` posterior a `T0 + EPISODE_WINDOW` se conserva. Pin sin `added_at` se limpia.
- Test 7: el mismo documento, ya pineado, se vuelve a pinear después del expiry sin unpin. `added_at` se renueva y el pin sobrevive. Cubrir modelo, suggestion card y más de un pin.
- Test 8: dos instancias de la misma fila. Una aplica el cleanup. La otra, que había leído los pins viejos, llama `pin_kb_document!`. El lock recarga. No reescribe el conjunto viejo.
- Primer turno desde `{}` conserva un pin recién puesto.
- `expires_at` no se acorta.

### Regression protection

Siguen iguales: dedup por `source_uri`, fallback por `kb_document_id`, aliases, varios pins, identidad física, `reset_procedure!`, y las decisiones de `active_episode_turn_test`. El re-pin idempotente de identidad no se rompe; sólo cambia el contrato del timestamp.

### PASS/FAIL gate

PASS: los tests de esta fase pasan y ningún test de decisión de episodio cambia de símbolo. FAIL: `hola` post-expiry deja el pin, un pin a T0+20 s sobrevive al expiry, el re-pin no mueve `added_at`, o un pin concurrente resurrecta el conjunto anterior al cleanup.

### Explicit non-goals

Ownership de writers tardíos, foto, auto-pin, piso de historial, sonda y documentación. Van en las fases 2 y 3. No hay login-reset, ni LLM, ni lista nueva de fabricantes.

## Phase 2 — Episode ownership, same-request isolation, async writers

### Goal

Invariant 2, el piso de historial, y que el mismo request que abre un Case, cruza el expiry o corrige el fabricante no mande la URI vieja a Bedrock.

### Files expected to change

- [app/models/conversation_session.rb](../app/models/conversation_session.rb) — `record_assistant_turn!`, `record_photo_observation!`, piso en `episode_user_messages`, `last_assistant_message`, `recent_user_turns`
- [app/controllers/rag_controller.rb](../app/controllers/rag_controller.rb) — pasar `expected_episode_id` al `record_assistant_turn!` síncrono. El orden `record_user_turn!` luego `entity_s3_uris` ya existe; no se reordena salvo que un test muestre una copia vieja
- [app/services/query_orchestrator_service.rb](../app/services/query_orchestrator_service.rb) — los dos `FieldPhotoAnalysisJob.perform_later` (foto nueva y reuse/reread) reciben `expected_episode_id` y `anchor_at`
- [app/jobs/field_photo_analysis_job.rb](../app/jobs/field_photo_analysis_job.rb) — `deliver` pasa ese ownership a `record_photo_observation!` y a los dos `record_assistant_turn!`
- [app/jobs/bedrock_ingestion_job.rb](../app/jobs/bedrock_ingestion_job.rb) — `register_entity` no auto-pinea si no prueba ownership
- [app/services/rag/followup_query_rewriter.rb](../app/services/rag/followup_query_rewriter.rb) — mismo piso en `episode_rows`
- tests de esos paths, de [test/controllers/concerns/rag_query_concern_test.rb](../test/controllers/concerns/rag_query_concern_test.rb), de login/logout, y de continuidad de foto del mismo caso

No modificar `resolve_retrieval_scope`. Con pins vacíos ya devuelve `open`. No modificar WhatsApp. `recent_history_for_prompt(turns: 3)` sigue siendo el fallback con `RAG_EPISODE_SCOPE_ENABLED=false`.

### Behavior before

Un `record_assistant_turn!` tardío escribe pending e historial en el episodio que haya ahora. `FieldPhotoAnalysisJob#deliver` llama `record_photo_observation!` y dos veces `record_assistant_turn!` sin `episode_id`. `record_photo_observation!` abre un episodio si el parse está en blanco, sin limpiar pins del JSON expirado. `BedrockIngestionJob#register_entity` llama `pin_kb_document!` al terminar, sin mirar qué Case originó el upload. El historial de razonamiento corta a 4 horas, no a `opened_at`.

### Behavior after

#### Texto

Al terminar `record_user_turn!`, el request captura el `episode_id` vivo. `record_assistant_turn!(..., expected_episode_id:)` compara, dentro del lock y tras reload, el episodio actual con ese id.

Si coinciden, escribe como hoy. Si no coinciden, no modifica `active_episode`, pending, facts, identifiers, conflicts, `active_photo`, `current_procedure` ni `active_entities`, y no agrega la respuesta a `conversation_history`. Siguen `PilotUsageLog`, `TurnEvidence` y `correlation_id`. Log `stale_case_write_dropped` con `conversation_session_id`, `writer=assistant`, `expected_episode_id`, `current_episode_id`, `correlation_id`. Sin texto de la query ni cuerpo del manual.

#### Foto

En el enqueue, después del turno de ese request:

```text
parsed = ActiveEpisode.parse(session.active_episode, now: now)
expected_episode_id = nil si parsed.blank?, si no parsed.episode_id
anchor_at = now
```

Esos dos valores viajan como argumentos del job. No hay columna nueva.

`photo_write_owned?`, dentro del lock, después del cleanup de expiry si el JSON guardado está vencido:

1. `expected_episode_id` presente y `current_episode_id == expected_episode_id`; o
2. `expected_episode_id` nil y no hay episodio vivo: este write puede abrir el Case, ya con los pins viejos limpiados; o
3. `expected_episode_id` nil, hay episodio vivo, `opened_at >= anchor_at` y `opened_at <= anchor_at + EPISODE_WINDOW`.

Si no es owned: no mutar `active_episode`, `active_photo`, manufacturer, model, facts, conflicts, pending, pins ni `current_procedure`, y no agregar historial assistant. El broadcast de UI sigue. Orden y display de un resultado tardío quedan en R3. Log `stale_case_write_dropped` con `writer=photo_observation` o `writer=photo_assistant`.

La regla 3 cubre la foto enviada sin Case cuyo análisis termina después de que un texto abrió el episodio X a los pocos segundos. No cubre un episodio abierto más de 4 horas después de `anchor_at`.

#### Auto-pin

Con `FIELD_COMPANION_EPISODE_ENABLED` distinto de `"true"`, `register_entity` sigue pineando como hoy.

Con la flag en `"true"`, auto-pinea sólo si hay episodio vivo y `kb_document.created_at >= opened_at` de ese episodio. Si no puede probarlo, no llama a `pin_kb_document!`. El documento queda indexado y se puede pinear a mano. Un upload que crea la fila antes de que exista episodio no auto-pinea: es el fail-open aceptado, y evita pinear el manual de A dentro de B.

#### Historial

```text
cutoff = [now - EPISODE_WINDOW, episode.opened_at].max
```

en `recent_user_turns`, `episode_user_messages`, `last_assistant_message` y `FollowupQueryRewriter#episode_rows`, cuando el episodio parsea vigente. El piso no sustituye el ownership: el writer tardío no entra a `conversation_history`.

#### Mismo request

El cleanup y el release de pin quedan persistidos antes de `entity_s3_uris`. En el request que abre Case, cruza expiry o corrige fabricante, la URI vieja no llega a Bedrock.

### Implementation steps

1. Argumento `expected_episode_id:` en `record_assistant_turn!`. Mismatch: return sin `update!` de estado ni de historial, con el log.
2. `record_photo_observation!` aplica el cleanup de expiry de la fase 1 antes de abrir, y exige `photo_write_owned?`.
3. Encolar la foto con `expected_episode_id` y `anchor_at` en los dos `perform_later`.
4. `register_entity` aplica el predicado de `created_at` contra `opened_at`.
5. Piso `opened_at` en los cuatro lectores. `prior_user_turns` del turno en curso se calcula antes de abrir el episodio nuevo.
6. Probe: además de `R1B_CASE_PROBE` (`conversation_session_id`, `episode_before`, `episode_after`, `case_boundary_reason`, `pin_release_reason`, `pins_before`, `pins_after`, `active_photo_before`, `active_photo_after`), el drop emite `stale_case_write_dropped` con writer, expected, current y `dropped=true`. Sin contenido sensible.

### Required tests

Flags encendidas. Reloj virtual. Orchestrator stubbeado. Sin Bedrock real. Sin `sleep`.

1. Late text writer. Episodio A. Otro request abre B. `record_assistant_turn!(expected_episode_id: A)` deja B intacto, no mete pending de A ni la respuesta en `conversation_history`. La telemetría puede emitirse.
2. Late photo writer. Foto con expected A y B ya abierto. B no recibe `active_photo`, manufacturer ni model de A. Los assistant writes de esa foto no entran al state ni al historial.
3. Foto sin Case. `expected_episode_id` nil, `anchor_at = T0`. Durante el análisis un texto abre X con `opened_at` dentro de la ventana. Al terminar, la foto puede escribir en X. Si X abre después de `anchor_at + EPISODE_WINDOW`, no escribe.
4. Expiry + `hola` queda cubierto en la fase 1. Aquí la query KONE siguiente no ve la URI Elemont.
5. Expiry + foto como primera acción. Los pins del Case viejo se limpian antes de escribir el estado de la foto nueva.
6. Pin a T0+20 s se limpia en el expiry. Pin posterior a `T0 + EPISODE_WINDOW` se conserva. Cubierto en la fase 1 y reafirmado en el scope.
7. Re-pin explícito post-expiry renueva `added_at`. Fase 1.
8. Carrera de pin. Fase 1.
9. Auto-pin. Upload de A, B ya vigente al terminar: no hay pin. A sigue vigente: sí hay pin. Flag de episodio apagada: el comportamiento legacy se conserva.
10. Corrección Elemont → KONE y un `record_assistant_turn!` del mismo `episode_id` que termina después. El pin incompatible no reaparece. El writer no escribe `active_entities`.
11. Siguen pasando: `K1`, follow-up corto, foto del mismo Case, assistant del mismo Case, miss con pin que no abre el corpus, corrección sólo de modelo que conserva el pin, `:continued_mention`, y varias preguntas sobre el mismo manual pineado.

También: login/logout no escriben la fila. Tras un boundary dentro de las 4 horas, el mensaje anterior sigue en `conversation_history` y no entra a `## Recent Conversation` ni a `episode_rows`.

### Regression protection

Pins vigentes siguen en `force_entity_filter`. Las decisiones de `active_episode_turn_test` no cambian. El piso no quita turnos del mismo `opened_at`. No se edita el baseline 14/14. No se borra `FieldPhoto` ni se cambia billing o retry. La UI de la foto tardía puede seguir emitiéndose.

### PASS/FAIL gate

PASS: los tests 1–3, 5, 9, 10 y 11 pasan, y A/B/I/J del scope siguen en `open` o `pin_only` según el caso. FAIL: una respuesta o una foto de A muta B, un auto-pin de A aparece en B, `hola` o la primera foto post-expiry dejan Elemont en `entity_s3_uris`, o el piso se usa como único rechazo de un writer tardío.

### Explicit non-goals

Orden o versión dentro del mismo Case, compatibilidad de pin en corrección sólo de modelo, follow-up general, meta-turno, targeting exacto: R2. Display de resultados tardíos, chip stale, sugerencia, provenance y `EMPTY_TEXT`: R3. No retirar `R1A_PROBE`. No tocar WhatsApp. La documentación es la fase 3.

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
- el header de [app/controllers/pinned_documents_controller.rb](../app/controllers/pinned_documents_controller.rb) que dice que los pins sobreviven días
- otros comentarios inline sólo si dicen que los pins sobreviven de un caso a otro o niegan un lector real del episodio

### Behavior before

`SESSION_AND_RETRIEVAL.md` todavía mezcla el contrato de pin de 30 días con un párrafo de corpus superado por R1A. `ACTIVE_ARCHITECTURE.md` no distingue workspace de caso. El plan del 21-sep describe `pin_kept`, `pin_extended`, `pin_overridden` e `inherit_episode_scope` sin aviso de que no son el retrieve vigente. El recovery tiene R1B en `NEXT`. El comentario de `FieldCompanionEpisodeFlag` dice que nadie lee la columna.

### Behavior after

Las tres fuentes activas describen el contrato de este plan: fila de 30 días, caso igual al `ActiveEpisode` de 4 horas, pins del caso, expiry como propiedad del JSON guardado, re-pin que renueva `added_at`, ownership de writers tardíos, release por corrección de fabricante, login y logout neutros, miss que no suelta el pin dentro del caso, y corpus R1A. Ningún documento activo dice que los pins sobreviven de un día a otro como si fueran del workspace. El plan del 21-sep sigue siendo evidencia de ese ciclo y avisa que no es el contrato. El recovery marca R1B `CLOSED — PASS` y R2 `NEXT`, con la evidencia del cierre. No aparece un documento nuevo de arquitectura.

### Implementation steps

1. Cerrar fases 1 y 2, tests y smoke antes de editar docs de contrato.
2. Actualizar `SESSION_AND_RETRIEVAL.md` y `ACTIVE_ARCHITECTURE.md` contra el código ya mergeado, no contra este plan si el código divergió.
3. Poner la nota histórica al inicio del plan del 21-sep y ajustar las dos filas necesarias de `docs/README.md`.
4. Corregir el comentario de `FieldCompanionEpisodeFlag` y cualquier otro comentario del mismo tipo dentro del scope.
5. Buscar en el repo `pin_kept`, `pin_extended`, `inherit_episode_scope`, login reset, `pins survive across days`, y “ConversationSession” tratado como case o thread. Corregir docs activas y comentarios del lifecycle. Marcar históricas. No borrar evidencia.
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

- `ActiveEpisodeTurn` devuelve `:new_episode` con el JSON guardado todavía vivo (reset explícito, modelo de catálogo disjunto, sujeto de equipo nuevo, switch de ownership ya existente).
- Un write reemplaza un JSON guardado expirado y el turno abre episodio (`:opened`, o `:new_episode` si la frase de reset cae sobre un parse en blanco).
- Una llamada futura a `start_new_case!(reason: "explicit_new_case")`. R1B no la conecta a la UI.

`hola` después del expiry puede ser `:no_episode`. No abre Case. Igual limpia los pins del Case vencido antes de borrar el marker.

### What does NOT start a new Case?

Login, logout, refresh del browser, volver a la hora, la pregunta `K1`, una corrección (`:corrected` no abre episodio, incluido “No, no es Elemont. Es KONE” y “No, es MiniSpace”), una mención que hoy es `:continued_mention` (incluida la golden query KONE sobre un episodio Elemont vivo), un miss de retrieve, y el primer `:opened` desde un `active_episode` vacío.

### What state belongs to a Case?

`episode_id` y el resto del episodio vigente (goal, facts, identifiers, pending, conflicts, `active_photo`), los pins de ese caso, y `current_procedure`.

### What survives a Case boundary?

La fila, `conversation_history`, el deslizamiento normal de `expires_at`, las filas `FieldPhoto`, y un pin cuyo `added_at` es posterior a `updated_at + EPISODE_WINDOW` del episodio que acaba de expirar. En un `:new_episode` de un caso todavía vivo no sobrevive ningún pin. Un pin con `added_at` ausente o inválido no sobrevive al expiry.

### What happens to pins?

Pasan a ser del caso, sin columna nueva y sin `episode_id` en el JSON. Al reemplazar un caso vivo se vacía `active_entities`. Si el JSON guardado está expirado, se borran los pins con `added_at` ausente, inválido o `<= updated_at + EPISODE_WINDOW`, en el write que reemplaza ese JSON, sin depender de `:opened`. En `:corrected`, se suelta sólo el pin cuya etiqueta contiene el fabricante anterior y no el nuevo. Un miss no los borra. “No, es MiniSpace” no los suelta. Ese residual es de R2. Un re-pin explícito renueva `added_at` aunque el documento ya estuviera en la fila.

### What happens after 4 hours?

`ActiveEpisode.parse` deja de exponer el episodio. El primer write que reemplaza ese JSON —texto, `hola` o foto— aplica el corte de pins antes de persistir. No hace falta que la decisión sea `:opened`. La fila de 30 días sigue. El prompt no usa turnos anteriores a `opened_at` del Case nuevo.

### What happens on login/logout?

Nada sobre `ConversationSession`. Volver a entrar a los 5 minutos conserva el caso.

### What owns an async/synchronous write?

El `episode_id` capturado cuando el trabajo empieza, después de `record_user_turn!` si ese request escribió episodio. La foto también lleva `anchor_at` del enqueue. No hay versión de estado nueva ni columna nueva. El writer compara ese id con el episodio vivo dentro del lock.

### What happens when expected_episode_id != current_episode_id?

No se modifica el Case actual: ni episodio, ni pending, ni facts, ni identifiers, ni conflicts, ni foto, ni procedimiento, ni pins. Se emite `stale_case_write_dropped`. La telemetría y el `correlation_id` siguen. La UI de la foto puede mostrar el resultado; el orden en el browser es de R3.

Excepción de la foto: `expected_episode_id` nil y el Case vivo cumple `opened_at >= anchor_at` y `opened_at <= anchor_at + EPISODE_WINDOW`, o no hay Case vivo y este write es el que lo abre después del cleanup de expiry. Eso es owned.

### What happens to conversation_history for a stale writer?

No se agrega el mensaje. Un timestamp nuevo lo metería en el razonamiento del Case B. El piso `opened_at` no reemplaza este rechazo.

### How is expiry detected?

`ActiveEpisode.parse` del JSON guardado, antes de sobrescribirlo, con `reason == expired`. Es propiedad de ese JSON, no de `:opened` ni de otra decisión.

### Which pins survive expiry?

Sólo los que tienen `added_at` parseable y posterior a `updated_at + EPISODE_WINDOW`. El resto, incluidos los de timestamp ausente o inválido, se limpian.

### What does an explicit re-pin mean?

El usuario volvió a elegir ese documento. `pin_kb_document!` escribe `added_at = Time.current` aunque ya estuviera en `active_entities`. Checkbox, suggestion card y re-pin sin unpin pasan por el modelo. La respuesta puede seguir diciendo `already_focused`.

### How does auto-pin prove ownership?

Con la flag de episodio apagada, no tiene que probarlo: sigue el comportamiento actual. Con la flag encendida, sólo pinea si hay episodio vivo y `KbDocument.created_at >= opened_at`. Si no, el manual queda indexado y sin pin automático.

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

`READY_FOR_FINAL_PLAN_REVIEW`

La arquitectura base del red-team se mantiene. Los cinco required edits están en este documento: ownership de texto, ownership de foto con `anchor_at`, expiry independiente de `:opened`, corte `added_at <= updated_at + EPISODE_WINDOW`, y re-pin que renueva `added_at` bajo lock. El auto-pin es el late writer de ingestión. No hay R1C. Este documento no autoriza código.

## Residuals

R2: orden dentro del mismo Case, pin en corrección sólo de modelo (`MonoSpace` → `MiniSpace`), follow-up general, meta-turno, targeting exacto.

R3: display de resultados tardíos, chip o checkbox stale hasta el rerender, UX de sugerencia, provenance y `EMPTY_TEXT`.

R1B garantiza el estado. Pilot readiness sigue `NOT YET`.
