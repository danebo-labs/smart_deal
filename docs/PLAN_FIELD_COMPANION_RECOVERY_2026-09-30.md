# Plan Field Companion Recovery (30-sep-2026)

**Ejecución vigente (2026-10-07):** [PLAN_FIELD_COMPANION_CONVERSACION_2026-10-07.md](PLAN_FIELD_COMPANION_CONVERSACION_2026-10-07.md). Este archivo conserva el registro de R1A y R1B. R1A sigue `CLOSED — PASS`. El smoke de producción de R1B queda pospuesto y no bloquea la etapa 1. R2 está absorbido por ese plan y no es la fase siguiente. R3 queda pospuesto.

El ciclo F0–F8 permanece cerrado en [PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29.md](PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29.md). Este documento no reabre ese ciclo y no autoriza código.

Etiquetas usadas abajo:

| Etiqueta | Significado |
|---|---|
| `VERIFIED` | Comprobado en producción o en la suite citada. |
| `DECIDED` | Decisión cerrada. No se rediseña en R1B, R2 ni R3. |
| `PENDING` | Fase siguiente, sin implementación. |
| `CARRY-OVER` | Hallazgo real que no pertenece a R1A y tiene dueño en una fase posterior. |
| `IMPLEMENTED — AWAITING PRODUCTION SMOKE` | El código y la suite citada pasan. No hubo smoke de producción. No es `CLOSED — PASS`. |

## Mapa operativo

| Fase | Estado |
|---|---|
| Field Companion F0–F8 | `CLOSED` (`KEEP_B`) |
| Product smoke original, post Field Companion | `FAILED` |
| R1A — corpus / retrieval correctness | `CLOSED — PASS` |
| R1B — session correctness | `IMPLEMENTED — PRODUCTION SMOKE POSTPONED` |
| R2 — conversational continuity + retrieval targeting | `ABSORBED` por el plan del 7 de octubre. No es la fase siguiente |
| R3 — UX + provenance consistency | `POSTPONED` |
| Pilot readiness | `NOT YET` |

No hay más fases. R1A no se reabre por sesión, targeting ni UI.

Producción al cierre de R1A: `04513a4f6317a58992a9505c1b196ae85afbc75e`.

Esa imagen incluye R1A `66f0d16ac1330c44c16ccd5dc526a7c7763c5640`, el blocker fix `3d07feb31bd1be0289b2aed92ed79a7f4d2a9545` y la sonda temporal `04513a4`. La producción previa al recovery era `ef2783c041e7949cebc8a075b81e7815c3c331c5`. F3B2 es `900041984e3ddb7472afbd1e9c21685436d8202e`.

## Evolución del corte de fases

`DECIDED`. La evidencia posterior parte el R1 que Opus propuso. No se vuelve a unir.

Opus, después del smoke de producto fallido, propuso:

- R1: corpus + session;
- R2: conversational regression + photo;
- R3: simplified UX + prod smoke.

Lo que quedó ejecutado:

- R1A fue sólo corpus y retrieval. Sesión, follow-up, UX de pin y photo lifecycle quedaron fuera a propósito.
- El prod smoke de corpus se ejecutó como compuerta del deploy de R1A y pasó. No cierra la UX.
- Sesión pasó a R1B.
- Continuidad conversacional y el fallo de targeting medido después del deploy pasan a R2.
- UX, sugerencia, procedencia y el cleanup de la sonda pasan a R3.

El hallazgo de Opus sobre photo lifecycle y el fallo de billing separado de `FieldPhoto` no fue contradicho. R1A no lo tocó. Queda `CARRY-OVER` dentro de R2, que es donde Opus lo había puesto, y no es un fixture nuevo.

## Fuente 1 — Auditoría adversarial de Opus

Hipótesis que abrieron el recovery. La verificación de producción las confirmó en los dos puntos de retrieval.

`VERIFIED` después, no en el momento de la auditoría:

- F3B2 rompió el acceso histórico al corpus compartido de las cuentas 1 y 3.
- El post-filter comparaba `chunk.document_id` con `KbDocument.document_uid` y rechazaba chunks bulk legítimos.

`DECIDED` por Opus y mantenido:

- Full rollback: no.
- Partial rollback del enforcement de F3B2: sí.
- Se mantienen el upgrade del modelo visual, `visual_observation`, provenance, `knowledge_scope` como dato, la autorización de pins y suggest-only.

`CARRY-OVER` que Opus dejó para después, y que este mapa ya asigna:

- session correctness → R1B;
- follow-up continuity → R2;
- UX de pin y manual, y el selection flow → R3;
- photo lifecycle → R2, sin fixture de aceptación todavía.

Hechos de sesión que Opus registró. El código de R1B ya los cierra; el smoke de producción no corrió:

- una sesión podía conservar pins durante días;
- login no escribía la sesión;
- la ventana de episodio es 4 h;
- los pins no expiraban con el episodio.

Siguen abiertos, fuera de R1B:

- un turno meta como “sí, consulta anterior” podía reemplazar el goal → R2;
- el selection flow mezcla biblioteca, pin, mensaje y turno → R3;
- un fallo de foto por billing debe separarse del lifecycle de `FieldPhoto` → R2.

## Fuente 2 — Verificación read-only

`VERIFIED` en producción sobre `ef2783c`, antes de escribir R1A. Esto autorizó proceder.

1. El corpus compartido 1/3 estaba roto.
2. `document_id` sha36 contra `document_uid` UUID rompía chunks bulk propios.
3. 200 assets bulk estaban afectados.
4. KONE estaba en la cuenta 3 y era invisible desde la cuenta 1.
5. La sesión 128 mantenía Elemont pineado aunque el episodio KONE había sido reemplazado.

`DECIDED`: proceder con R1A como partial recovery del enforcement. No revertir el commit F3B2 entero, porque pins y sugerencias dependen de `KnowledgeScopePolicy`. No limpiar la sesión 128 para recuperar retrieval.

## Fuente 3 — Primera revisión de Codex

Sobre `66f0d16`. Veredicto: `BLOCK_DEPLOY`.

`DECIDED` por Codex. R1A no se desplegó en ese SHA.

### Blocker A — fail-open

`publishable_retrieved_chunk?` trataba `account_id.blank?` como publicable. Metadata ausente o malformada podía publicarse. `retrieval_chunk_metadata` convertía metadata inválida en `{}`.

### Blocker B — publicación global por slug

Un upload autenticado de Legacy o Pilot seguía este camino:

authenticated upload → slug Legacy/Pilot → `SharedManualCorpus.tag?` → `manual_corpus=general`.

Un usuario normal podía meter contenido en el corpus compartido sin aprobación explícita. El open retrieval además compartía los manuales no-foto de esas cuentas por `account_id`.

Codex dejó pin authorization, caller filters y la estructura general como aceptables. Confirmó que las fotos propias ya eran visibles antes de F3B2, así que R1A no debía cambiar esa semántica. Las fotos de la otra cuenta compartida siguen excluidas.

## Fuente 4 — Fix de los blockers

`DECIDED`. Commit `3d07feb31bd1be0289b2aed92ed79a7f4d2a9545`, padre `66f0d16`. Sin migración y sin backfill. Veredicto local: `READY_FOR_EXTERNAL_REVIEW_3`.

### Metadata fail closed

- metadata `nil` → DROP;
- metadata malformada → DROP;
- `account_id` en blanco → DROP;
- `manual_corpus=general` sin `account_id` → DROP;
- bulk legítimo con `account_id` y `document_id` sha36 → KEEP.

No se reintrodujo `chunk.document_id == kb_document.document_uid`.

### Publication boundary

Un upload normal nuevo escribe `manual_corpus=account`.

`manual_corpus=general` sólo si `corpus_scope="general"` y `account.danebo_controlled=true`.

Pertenecer a Legacy o Pilot ya no basta. El corpus histórico 1/3 sigue legible porque esos chunks no tienen la clave, o ya traen `general`, y el brazo compartido usa `notEquals` sobre `manual_corpus=account`. El brazo del viewer sigue siendo `account_id` pelado, así que el dueño sigue viendo su manual nuevo y su foto.

Evolución respecto de R1A original: el primer alcance decía no implementar todavía la frontera con `danebo_controlled`. Codex bloqueó el deploy y exigió esa frontera para contenido nuevo. La decisión cerrada usa `danebo_controlled` sólo como permiso para marcar `general` en uploads nuevos. No es la biblioteca Danebo independiente, y no reescribe el histórico.

## Fuente 5 — Code review 3 de Codex

`DECIDED`. Veredicto: `APPROVE_FOR_DEPLOY`.

Codex confirmó que los dos blockers estaban corregidos.

Deuda no bloqueante, también `DECIDED` como fuera del recovery inmediato:

un filtro técnico custom puede excluir un documento propio nuevo con `manual_corpus=account`. Ese path no es reachable desde el flujo web actual. Corregirlo antes de exponer technical custom filters. No bloquea R1B, R2 ni R3 salvo que el path quede reachable.

Suite citada para ese SHA: 3792 runs, 19508 assertions, 0 failures, 0 errors.

## Fuente 6 — Deploy y traza en vivo

`VERIFIED`. Imagen `04513a4`.

### KONE

Cuenta 1 consultando el corpus de la cuenta 3:

- el open filter incluye las cuentas 1 y 3 más `manual_corpus=general`;
- 8 raw chunks;
- 8 KEEP;
- 0 DROP;
- citation real de un manual KONE de la cuenta 3.

Before, en el incidente: la cuenta 1 no veía la cuenta 3, los chunks se rechazaban, evidence 0, citations 0.

### Elemont bulk

- `KbDocument` UUID: `dcc8e046-037d-48a6-8913-1992aed28507`;
- chunk sha36: `121bfffe0827f6bc681ba9bdc91050390055`;
- el sha36 sigue siendo distinto del UUID;
- decisión de publicación: `KEEP` `owner`;
- K1: 3 KEEP;
- borne 12: 9 KEEP;
- citation real de Elemont.

Before: los chunks volvían y el post-filter los rechazaba. Citations 0.

### Baseline

- 14/14 flows PASS;
- 29/29 turns PASS;
- 0 `DENY_RETRIEVAL`;
- 0 publication DROP inesperados.

`DECIDED`: `R1A = CLOSED — PASS`.

## Fuente 7 — Smoke manual

Hecho por el usuario en la UI, 30-sep-2026, aproximadamente 19:00–19:02 UTC-3. Cuenta `danebo-legacy`, sesión 128.

Golden query:

`En las instrucciones de instalación del KONE MonoSpace Special para máquinas MX05, MX06 y MX10 con variadores V3F18, ¿cuál es la referencia del documento, la revisión y la fecha?`

Golden, del manual KONE MonoSpace Special:

- referencia `AM-01.01.046`;
- revisión `(A)`;
- fecha `2009-07-03`;
- 515 páginas.

Chunk de esa portada: `bulk_chunks/3/38a1b716d1f432d3cb088c83c5c14efa8490/chunk_p1_1.txt`.

### Hallazgo A — stale pin

`CARRY-OVER`. Primer intento. La sesión 128 todavía tenía Elemont pineado.

KONE query → filtro URI de Elemont → chunks Elemont → abstención.

No reabre R1A. Dueño: `R1B — SESSION CORRECTNESS`.

### Hallazgo B — retrieval correcto

`VERIFIED`. Segundo intento, sin el filtro Elemont.

- open filter R1A correcto;
- 8 raw;
- 8 KEEP;
- el golden chunk de la página 1 quedó en rank 1;
- answer con la referencia, la revisión y la fecha;
- citation de ese manual, página 1.

Confirma otra vez R1A. Clasificación: `R1A MANUAL RETRIEVAL PASS`.

### Hallazgo C — exact document identifier recall

`CARRY-OVER`. Segundo turno:

`¿Cuántas páginas totales tiene el documento AM-01.01.046?`

Golden: `515`.

Actual: el retrieval trajo `AM-01.01.255`, `KONE N MonoSpace Instalación Sin Andamiaje`, y la respuesta dijo `330 páginas` porque eso es lo que ese chunk dice. No alucinó 515. El publication gate hizo KEEP. No hubo DROP. El fallo es targeting, recall o semántica.

Dueño: `R2 — CONVERSATIONAL CONTINUITY + RETRIEVAL TARGETING`.

### Hallazgo D — contradicción de UI

`CARRY-OVER`. En el turno del hallazgo B convivieron la respuesta correcta con citation al manual KONE y este texto:

`No encontré un manual claramente asociado a esa identidad en la biblioteca actual.`

Causa: `ManualCandidateRanker` / `attach_manual_suggestion` autoriza la sugerencia con una regla distinta de la visibilidad de compatibilidad del open retrieval. El retrieve publica el manual de la cuenta 3. La sugerencia no arma tarjeta y muestra `EMPTY_TEXT`.

Dueño: `R3 — UX / SUGGESTION CONSISTENCY`.

Aceptación futura, no implementada: si el turno ya publica citations válidas, no mostrar el `EMPTY_TEXT` de “no encontré un manual”.

### Hallazgo E — provenance

`CARRY-OVER`. `AM-01.01.046`, `(A)` y `2009-07-03` salen del mismo chunk citado. Esas líneas se mostraron bajo `Guía Danebo`.

`ProvenanceSegmenter` marca `MANUAL_FACT` sólo si la oración contiene un `[n]` de las citations de ese turno. Esas tres líneas no lo contienen.

Dueño: `R3 — PROVENANCE PRESENTATION`.

Aceptación futura, no implementada: un dato sostenido por la misma evidence no se presenta como orientación propia de Danebo sólo por la segmentación o por dónde quedó el marcador.

## Fixtures obligatorios

No están implementados. Cada fase siguiente los hereda.

### FIXTURE A — stale pin

Estado inicial: pin `Elemont Montacargas Hidraulico Modelo MH`.

Query nueva: la golden query KONE.

Código de R1B: un caso nuevo, un JSON expirado o un episodio inválido suelta el pin viejo antes del retrieve. Smoke de producción pendiente. La sesión 128 no se limpió y no es fixture mutable.

Owner: R1B, `IMPLEMENTED — AWAITING PRODUCTION SMOKE`.

Comportamiento esperado en el smoke: un caso nuevo no queda condicionado en silencio por un pin viejo.

### FIXTURE B — identificador exacto

Query: `¿Cuántas páginas totales tiene el documento AM-01.01.046?`

Golden: KONE MonoSpace Special, `AM-01.01.046`, respuesta `515`.

Fallo actual: retrieval de `AM-01.01.255` y 330 páginas, con el gate en KEEP y sin alucinación.

Owner: R2.

### FIXTURE C — citation y EMPTY_TEXT

El mismo turno cita el manual y muestra `EMPTY_TEXT`.

Owner: R3.

Regla: si hay citations válidas, ese aviso no se muestra.

## R1B — Session correctness

`IMPLEMENTED — AWAITING PRODUCTION SMOKE`.

R1A usó `CLOSED — PASS` después del deploy y de la traza en vivo. R1B no tuvo ese smoke. Esta etiqueta no lo sustituye.

Objetivo: un caso anterior nunca contamina en silencio un caso nuevo.

Fixture principal: A. La sesión 128 sigue siendo evidencia. No se limpió.

Plan: `e477611d33f9cef6c07c3c298cae699b75f4ae26`.

Commits de código:

- Phase 1, boundary de pins: `597874890e69c60908dcb61f3d4ea25e9da8adfe`
- Phase 2, ownership de writers: `e3aca3897a604c03e655cf6f1a492549e563debf`
- `invalid_state` suelta los pins: `343f5795a423d6dc4c208cf56e7d3c772a74966f`

Contrato que el código ya sostiene, en suite local, sin Bedrock real y sin `sleep`:

- Invariante 1: un Case nuevo no hereda pins, `current_procedure`, foto, pending ni facts del Case anterior.
- Invariante 2: un assistant, una foto o un auto-pin con `expected_episode_id` de un Case anterior no escribe el Case posterior. El drop es `stale_case_write_dropped`. Telemetría y `correlation_id` siguen.
- `ConversationSession` es el workspace: una fila por `(account_id, identifier, channel)`, TTL deslizante de 30 días. `Case = ActiveEpisode`, ventana de 4 horas.
- Login y logout no escriben la fila.
- Expiry es `reason == expired` del JSON guardado. Limpia los pins de ese Case, también en `:no_episode`, `:skipped` y foto. Un pin posterior a `updated_at + EPISODE_WINDOW` se conserva. `added_at` ausente o ilegible no se conserva.
- `invalid_state` limpia todos los pins y `current_procedure`, sin corte temporal. `{}` conserva un pin explícito.
- `:new_episode` sobre un Case vivo limpia los pins. Una corrección de fabricante se queda en el mismo `episode_id` y suelta sólo el pin cuya etiqueta contiene el fabricante anterior como palabra completa y no contiene el nuevo.
- El re-pin explícito, incluida la suggestion card que responde `already_focused`, renueva `added_at`.
- Una foto sin Case abre y persiste el owner antes del enqueue. Los paths normal, reuse y reread conservan ese id.
- Auto-pin con la flag de episodio apagada sigue el camino anterior. Con la flag encendida sólo pinea si el `expected_episode_id` de la submission sigue vigente. El long-manual que rehidrata desde `WebManualBatch` no tiene owner durable y no auto-pinea. El documento queda indexado y se puede pinear a mano. No se infiere ownership desde timestamps tardíos.
- El mismo request que abre Case, cruza expiry, corrige fabricante o reemplaza un episodio inválido persiste esa limpieza antes de `entity_s3_uris`.
- Un miss dentro del Case no suelta el pin. El corpus abierto sigue siendo el de R1A.

Suite local citada después de `343f579`: los archivos de boundary, ownership, sesión, same-request, foto, ingestión, episodio, follow-up, orquestador, controllers de RAG y pin, y login. 494 runs, 2502 assertions, 0 failures, 4 skips preexistentes. No es smoke de producción.

`R1A_PROBE` sigue. El retiro de sondas es de R3.

## R2 — Conversational continuity + retrieval targeting

`ABSORBED` el 2026-10-07 por [PLAN_FIELD_COMPANION_CONVERSACION_2026-10-07.md](PLAN_FIELD_COMPANION_CONVERSACION_2026-10-07.md). El texto siguiente es el alcance histórico. No se ejecuta como fase.

Objetivo: continuidad natural y targeting exacto.

Fixture obligatorio: B.

Incluye los hallazgos que ya están medidos o que Opus dejó en este grupo:

- la golden query KONE sobre un episodio Elemont vivo sigue en `:continued_mention`;
- MonoSpace → MiniSpace no suelta el pin;
- orden dentro del mismo Case;
- follow-up y semántica de continuación;
- un meta-turno no reemplaza el goal;
- `pending_question`;
- follow-up anafórico;
- corrección y cambio de equipo que R1B no clasifica como frontera;
- identificadores exactos de documento;
- `AM-01.01.046` devuelve 515;
- un episode goal que quedó null después de una corrección;
- los flows históricos del baseline;
- `CARRY-OVER` de photo lifecycle: separar un fallo de billing del lifecycle de `FieldPhoto`. R1A no lo tocó. R1B tampoco. No es el fixture de aceptación de R2.

## R3 — UX + provenance consistency

`PENDING`. El scope no se movió.

Objetivo: ocultar la mecánica interna del RAG y eliminar mensajes contradictorios.

Fixture obligatorio: C. El hallazgo E entra en la misma fase.

Incluye:

- orden y display de un resultado tardío;
- chip o checkbox stale hasta el próximo render;
- citation junto a `EMPTY_TEXT`;
- clasificación Manual / Foto / Guía Danebo;
- simplificación de focus y pin;
- UX de sugerencia;
- el selection flow, que hoy mezcla biblioteca, pin, mensaje y turno;
- chip único y estado visible del pin;
- consistencia de la sugerencia con lo que el turno ya citó;
- retiro de `R1A_PROBE` y de `R1B_CASE_PROBE` al cierre del recovery, si ya no hacen falta. La sonda `04513a4` entra en ese retiro.

## Qué no reabre R1A

`DECIDED`. R1A permanece `CLOSED — PASS` porque la traza muestra:

- el corpus compartido 1↔3 funciona;
- el bulk sha36 propio se publica;
- el publication gate funciona, incluido el fail-closed de metadata;
- el histórico sigue compartido y el upload nuevo no se marca `general` por slug;
- el baseline de la cuenta 3 quedó restaurado.

El pin viejo tiene código en R1B y espera smoke. El ranking de `AM-01.01.046` sigue en R2. El `EMPTY_TEXT` y el rótulo `Guía Danebo` siguen en R3.

## Sonda

`04513a4` sigue desplegada. Es observacional: registra filtro, chunks y KEEP/DROP. No cambia filtros, ranking, respuestas, autorización ni sesión.

Se mantiene durante R1B y R2 si ayuda a separar retrieval de sesión o de conversación. Se retira al cierre del recovery, como tarea de R3.

## Deuda no bloqueante

Technical custom filters pueden excluir un documento propio nuevo con `manual_corpus=account`. No es reachable desde la web. Corregir antes de exponer ese path. Fuera del recovery salvo que quede reachable.
