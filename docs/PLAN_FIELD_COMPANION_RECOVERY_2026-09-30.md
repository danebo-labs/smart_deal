# Plan Field Companion Recovery (30-sep-2026)

**Estado:** fuente de verdad del recovery posterior al Field Companion. El ciclo F0–F8 permanece cerrado en [PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29.md](PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29.md). Este archivo no reabre ese ciclo y no autoriza código.

**Producción al cierre de R1A:** `04513a4f6317a58992a9505c1b196ae85afbc75e`.

Esa imagen incluye R1A `66f0d16ac1330c44c16ccd5dc526a7c7763c5640`, el blocker fix `3d07feb31bd1be0289b2aed92ed79a7f4d2a9545` y la sonda temporal `04513a4f6317a58992a9505c1b196ae85afbc75e`. La producción previa al recovery era `ef2783c041e7949cebc8a075b81e7815c3c331c5`.

## Mapa

| Fase | Estado |
|---|---|
| Field Companion F0–F8 | `CLOSED` (`KEEP_B`) |
| Product smoke original, post Field Companion | `FAILED` |
| R1A — corpus / retrieval correctness | `CLOSED — PASS` |
| R1B — session correctness | `NEXT` |
| R2 — conversational continuity + retrieval targeting | `PENDING` |
| R3 — UX + provenance consistency | `PENDING` |
| Pilot readiness | `NOT YET` |

No hay más fases. R1A no se reabre por pin viejo, por un identificador de documento mal rankeado, por `EMPTY_TEXT` ni por el rótulo de procedencia.

## Product smoke original

Después de cerrar Field Companion en `ef2783c`, el smoke de producto falló en dos regresiones de retrieval:

- Un viewer de la cuenta 1 no recibía el corpus KONE de la cuenta 3. Los chunks llegaban y el post-filtro los rechazaba. Evidence 0. Citations 0. Abstención.
- Un pin Elemont propio devolvía chunks bulk. El post-filtro los rechazaba porque el `document_id` sha36 del chunk no era el `document_uid` UUID de `KbDocument`. Citations 0.

Ese smoke abre este recovery. No es un fallo de R1A.

# R1A — CORPUS / RETRIEVAL CORRECTNESS

Status: `CLOSED — PASS`.

Deployment: `04513a4f6317a58992a9505c1b196ae85afbc75e`.

Product commits:

- `66f0d16ac1330c44c16ccd5dc526a7c7763c5640` — restaura el corpus compartido previo a F3B2 y deja de comparar sha36 con UUID.
- `3d07feb31bd1be0289b2aed92ed79a7f4d2a9545` — metadata ilegible o sin `account_id` falla cerrada. Un upload normal nuevo escribe `manual_corpus=account`. `manual_corpus=general` exige `corpus_scope=general` y cuenta `danebo_controlled`.

Probe: `04513a4f6317a58992a9505c1b196ae85afbc75e`. Sigue desplegada. No se retira en este cierre.

R1A no cambia sesión, login, pins, TTL, follow-up, selection gate, frontend, ciclo de foto, configuración Anthropic ni datos. No hubo migración nueva.

## KONE

Before, cuenta 1 consultando cuenta 3:

- la cuenta 1 no veía la cuenta 3;
- chunks rechazados;
- evidence 0;
- citations 0.

After, smoke de producción del deploy R1A, pregunta de puerta KONE, `query:3e37216b-b56c-4af5-9de1-3c4bba2f6f5f`:

- el open filter incluye cuenta 1, cuenta 3 (`ingestion_path != field_photo_v1` y `manual_corpus != account`) y `manual_corpus=general`;
- 8 raw;
- 8 KEEP;
- 0 DROP;
- citation real de KONE cuenta 3: MonoSpace Special Instalación MX05 MX06 MX10 V3F18, página 375.

## Elemont bulk

Before:

- sha36 distinto de `document_uid`;
- chunks retornados y rechazados por el post-filtro;
- citations 0.

After, pin `Elemont Montacargas Hidraulico Modelo MH`, `KbDocument` 213, `document_uid` `dcc8e046-037d-48a6-8913-1992aed28507`. El chunk sigue siendo sha36 `121bfffe0827f6bc681ba9bdc91050390055`. La decisión de publicación es `KEEP` `owner`. No hay comparación sha36 contra UUID.

- K1, `query:ffcc4df5-154a-4fae-b8a5-ccc0afdab9d1`: 3 chunks KEEP.
- borne 12, `query:b1ea9580-44e4-406c-9842-e56e0342cd7a`: 9 chunks KEEP. Citation Elemont, página 2.

## Baseline

`script/production_conversational_baseline_v2.rb` sobre la cuenta 3, misma imagen:

- 14/14 flows PASS;
- 29/29 turns PASS;
- 0 `DENY_RETRIEVAL`;
- 0 publication DROP inesperados.

El proceso de `rails runner` salió 1 después de imprimir `BASELINE_RESULT pass`, por `SystemExit` del `exit` interno. El veredicto del script es pass. No es un flow fallido.

## Security fixes

Quedan en `3d07feb`:

- `account_id` ausente o metadata ilegible falla cerrada;
- un upload normal nuevo queda `manual_corpus=account`;
- `general` requiere `corpus_scope=general` y cuenta `danebo_controlled`;
- el histórico de las cuentas 1 y 3 sigue disponible como compatibility corpus. Esos chunks no tienen la clave `manual_corpus`. No hubo backfill.

El caso de aislamiento entre dos cuentas ordinarias quedó `NOT_EXECUTED — NO SAFE EXISTING DATA`. La única cuenta ordinaria es `elevadores-climb` y no tiene documentos privados. Los filtros observados no abren esa cuenta. No se crearon datos.

## Smoke manual post-R1A

Hecho por el usuario en la UI, 30-sep-2026, 19:00–19:02 UTC-3.

Cuenta `danebo-legacy`, `account_id=1`, `user_id=3`, `conversation_session_id=128`. La sesión 128 ya tenía estado previo. No se limpió.

### Golden query

`En las instrucciones de instalación del KONE MonoSpace Special para máquinas MX05, MX06 y MX10 con variadores V3F18, ¿cuál es la referencia del documento, la revisión y la fecha?`

Golden source: `KONE MonoSpace Special Instalación MX05 MX06 MX10 V3F18`.

Chunk: `bulk_chunks/3/38a1b716d1f432d3cb088c83c5c14efa8490/chunk_p1_1.txt`.

URI: `s3://multimodal-source-destination/bulk_uploads/3/2026-08-22/kone instalacion maquinas mx05, mx06 y mx10 con v3f18.pdf`.

Esperado, leído del chunk antes del smoke:

- referencia `AM-01.01.046`;
- revisión `(A)`;
- fecha `2009-07-03`;
- total `515 páginas`.

### Intento A

`query:25d20289-7220-420c-ad4a-45bee61e6169`, 19:00:21.

La sesión 128 todavía tenía el pin Elemont. La query KONE salió con filtro URI de `Montacargas 2N Temporizado-1 (1).pdf`. Los chunks fueron Elemont, cuenta 1, `KEEP` `owner`. El turno abstenió: el dato no estaba en esos fragmentos.

Clasificación: `CARRY-OVER R1B — STALE SESSION/PIN`.

No es un fallo de R1A.

### Intento B

`query:366e22f5-00c5-4616-aaaf-349b2fcbda92`, 19:00:44.

Sin filtro Elemont. Open filter R1A correcto. 8 raw, 8 KEEP, cuenta 3, `document_id` `38a1b716d1f432d3cb088c83c5c14efa8490`, 0 DROP. Rank 1 es el golden chunk, página 1. Answer con `AM-01.01.046`, `(A)`, `2009-07-03` y 515 páginas. Citation: ese manual, página 1.

Clasificación: `R1A MANUAL RETRIEVAL PASS`.

### Segundo turno del mismo smoke

`query:c6134655-e59b-4ba9-ae9f-69e493c9a5ac`, 19:01:56.

Pregunta: `¿Cuántas páginas totales tiene el documento AM-01.01.046?`

El open filter R1A fue el correcto. 0 DROP. El único chunk publicado fue `AM-01.01.255`, `KONE N MonoSpace Instalación Sin Andamiaje`, 330 páginas, `document_id` `a487cd899afd548b2fde10b74af3271eefcf`. El modelo no inventó 515. El documento correcto no llegó en el raw result. La semántica marcó el turno `unclear` / `ambiguous` y no reescribió la query.

Clasificación: fixture B. No reabre R1A.

## Regression fixtures

Obligatorios para las fases siguientes. No están implementados.

### FIXTURE A — stale pin contamination

Estado inicial: pin `Elemont Montacargas Hidraulico Modelo MH`.

Query nueva: la golden query KONE de arriba.

Fallo actual: el retrieval queda limitado en silencio al URI Elemont y el turno abstiene.

Owner: `R1B SESSION CORRECTNESS`.

Comportamiento futuro: un caso nuevo no puede quedar condicionado en silencio por un pin viejo.

### FIXTURE B — exact document identifier recall

Query: `¿Cuántas páginas totales tiene el documento AM-01.01.046?`

Golden source: KONE MonoSpace Special, `AM-01.01.046`. Golden answer: `515`.

Resultado actual: retrieval devuelve `AM-01.01.255`, `KONE N MonoSpace Instalación Sin Andamiaje`, 330 páginas.

El publication gate funciona. No hubo DROP. El modelo no alucina 515. El documento equivocado ocurrió en retrieval / targeting.

Owner: `R2 CONVERSATIONAL / RETRIEVAL TARGETING`.

### FIXTURE C — citation + EMPTY_TEXT contradiction

En el intento B, el mismo turno contiene la respuesta respaldada y la citation real al manual KONE, y a la vez:

`No encontré un manual claramente asociado a esa identidad en la biblioteca actual.`

Causa: `ManualCandidateRanker` / `RagController#attach_manual_suggestion` usa una elegibilidad distinta del open retrieval de compatibilidad. `KnowledgeScopePolicy.authorized?` acepta dueño o `danebo_general`. El KONE de la cuenta 3 es `tenant_private`. El retrieve lo publica. La sugerencia no arma tarjeta y muestra `EMPTY_TEXT`. El evento de ese turno tiene `suggestion_document_uids=[]`.

Owner: `R3 UX / SUGGESTION CONSISTENCY`.

Regla de aceptación: si el turno ya publica citations válidas, nunca mostrar el `EMPTY_TEXT` de "no encontré un manual".

No implementar todavía.

## Provenance carry-over

En el answer del intento B, `AM-01.01.046`, `(A)` y `2009-07-03` salen del mismo chunk de la página 1. Esas líneas quedaron bajo la etiqueta `Guía Danebo`.

`Rag::ProvenanceSegmenter` marca `MANUAL_FACT` sólo cuando la oración trae un `[n]` presente en las citations del turno. Esas tres líneas no lo traen. El resto del answer, que sí lleva `[1]`, queda en `Manual`.

Clasificación: `R3 — PROVENANCE PRESENTATION`.

No implementar.

Aceptación futura: información sostenida por la misma evidence no se presenta como orientación propia de Danebo sólo por la segmentación o por dónde cayó el marcador de citation.

## R1B — SESSION CORRECTNESS

Estado: `NEXT`.

Objetivo: un caso anterior no contamina en silencio un caso nuevo.

Alcance a auditar y diseñar, sin implementación definida:

- límite de caso nuevo;
- comportamiento de login;
- `active_episode`;
- pins;
- `active_photo`;
- `current_procedure`;
- follow-up refs;
- pin TTL / `EPISODE_WINDOW`;
- pin siempre visible si está activo.

Fixture principal: A.

La implementación definitiva no se fija aquí. Requiere investigación.

## R2 — CONVERSATIONAL CONTINUITY + RETRIEVAL TARGETING

Estado: `PENDING`.

Objetivo: continuidad natural y targeting exacto.

Incluye:

- un meta-turno no reemplaza el goal;
- `pending_question`;
- follow-up anafórico;
- corrección y cambio de equipo;
- identificadores exactos de documento;
- `AM-01.01.046` devuelve 515;
- episode goal que quedó null después de una corrección KONE en el smoke de deploy (`query:6dd19846-99ef-4b3b-946f-7757e9b869eb`, sesión desechable 129);
- flows históricos del baseline.

Fixture obligatorio: B.

## R3 — UX + PROVENANCE CONSISTENCY

Estado: `PENDING`.

Objetivo: ocultar la mecánica interna del RAG y eliminar mensajes contradictorios.

Incluye:

- citation junto a `EMPTY_TEXT`;
- simplificación de focus / pin;
- chip único y estado visible;
- turno de selección;
- consistencia de la sugerencia;
- bandas Manual / Foto / Guía Danebo;
- retiro de la sonda `04513a4` al cierre del recovery, si ya no hace falta.

Fixture obligatorio: C.

## Deuda técnica no bloqueante

Un filtro técnico custom puede excluir documentos propios nuevos con `manual_corpus=account`, porque ese AND aplica `manual_corpus != account` a todo el filtro. El flujo web no pasa `custom_config`. No es alcanzable hoy.

Corregirlo antes de exponer technical custom filters. No entra en este recovery salvo que ese camino quede reachable.

## Sonda temporal

`04513a4` sigue desplegada. Registra `R1A_PROBE` con filtro, chunks, decisión KEEP/DROP y motivo. No cambia filtros, ranking, respuestas, autorización ni estado de sesión.

Se usa en R1B y R2 si ayuda a separar retrieval de sesión o conversación. No se elimina ahora. El cleanup queda como tarea del cierre del recovery, dentro de R3.

## Qué no reabre R1A

R1A permanece `CLOSED — PASS` porque la traza muestra:

- el corpus compartido 1↔3 funciona;
- el bulk sha36 propio se publica;
- el publication gate funciona;
- el baseline de la cuenta 3 está restaurado.

El pin viejo, el ranking de `AM-01.01.046` y la contradicción de `EMPTY_TEXT` tienen dueño en R1B, R2 y R3.
