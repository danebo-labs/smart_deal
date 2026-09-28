# Plan quirúrgico: pin vencido, continuidad y autoridad de evidencia

Fecha: 28-sep-2026. Estado: ver **Execution State**. Las enmiendas de Codex y las finales de Opus del mismo día están incorporadas en las fases de abajo. No hay plan paralelo. Imagen de las pruebas: `bfcd112c4962c8aae9e35524e28646206f2cfc96`.

Evidencia: `tmp/pilot_exports/2026-09-28_2026-09-28_danebo-legacy/` (generado 21:11 UTC). Cuenta `danebo-legacy`, `account_id=1`, `user_id=3`, sesión web. Las baterías de SEGURIDADES (17:27–17:39) y Elemont MH (17:53–18:00) están en ese export. El email `lahiri.sanchez@danebo.ai` no aparece en la traza; el defecto del checkbox se confirma en el código, no en un `user_id`.

No reescribir el RAG. No subir `PINNED_DOCUMENT_RESULTS`. No tocar el tono companion ni `SourceFidelityGuard`.

## 1. Executive summary

Dos defectos independientes.

El checkbox de documentos lee la sesión con `find_by` y **no mira `expires_at`**. La consulta RAG usa `find_or_create_for`, que **borra** la sesión vencida (30 días) y abre una vacía. El técnico ve SEGURIDADES marcado y la búsqueda ya no tiene ese pin. No existe un TTL de pin distinto del de la sesión.

En la batería de las 17:27 el pin **sí estaba vivo**. Las fallas de EM4000, SCI, H4, bornes y temporizadores ocurrieron con el documento fijado. Ahí el fallo es otro: dentro de un PDF con muchas placas parecidas, el retrieve se queda en 3 chunks semánticos; una pregunta con «está» o «este» se trata como seguimiento y arrastra identificadores del episodio; y la hoja 1 del plano MH sigue publicando bornes que la hoja 2 desmiente. Seguridad OUT/IN, el micro de nivel y la llamada de nivel no traen un designador con dígito: ni `structured_mapping_query?` ni `pinned_exact_designator_lookup?` las suben a la ruta, el selector se queda con los primeros chunks, y ni el prompt ni el parche de la hoja 1 hacen entrar la hoja 2.

## 2. Qué hay en el código

Flujo real de una pregunta web con pin:

1. `RagController#ask` → `ConversationSession#record_user_turn!` → `Rag::ActiveEpisodeTurn`.
2. `RagQueryConcern#execute_rag_query` elige `effective_question`: si `FIELD_COMPANION_TURN_ENABLED`, usa `episode_turn.composed`; si no, `FollowupQueryRewriter`.
3. `resolve_retrieval_scope`: pin vacío → corpus abierto (`OPEN_RESULTS` = 8); pin presente → `force_entity_filter=true`, solo esas URI. Auto-scope y herencia de episodio están retirados (`inherit_episode_scope` devuelve vacío).
4. `RagRetrievalProfile#number_of_results`: documento pineado = **3**. Sube a 5 solo si la pregunta matchea `SAFETY_CRITICAL_PATTERNS` (`falla`, `defecto`, `reparar`, …). No hay rama que suba el tope por designador.
5. `Rag::StructuredEvidenceRoute` pide 12 y luego se queda con los chunks que contienen el identificador. **No entra** si la pregunta es safety-critical, si no hay pin, o si `QueryEntities` no ve un identificador. `QueryEntities` solo acepta tokens en mayúsculas (`IDENTIFIER_SHAPE`). «Edel-k2» no cuenta. «H4» cuenta solo si va en mayúsculas y es el único identificador de un lookup.
6. `BedrockRagService#query` junta retrieve y generación en `retrieve_and_generate`. Con `force_entity_filter` no hay segundo retrieve. El Sorry solo se traduce a `rag.pinned_no_results` después de generar. Una ventana incorrecta pero no vacía no entra en esa rama: la respuesta mala ya salió.
7. Síntesis companion sobre esos chunks. `generation.txt` no distingue una fila `borne → función` de un número dibujado en el esquema.

Pin en la UI:

- `HomeController#pinned_uris_for_current_session` hace `ConversationSession.find_by(identifier:, channel:)` **sin `account_id` y sin `expired?`**, y pinta `data-selected` en `app/views/home/_kb_docs_card_rows.html.erb`.
- `PinnedDocumentsController#current_conv_session` y el ask usan `find_or_create_for`, que destruye la fila si `expires_at <= Time.current` (`EXPIRY_DURATION = 30.days`) y crea una sesión sin `active_entities`.
- `pin_kb_document!` no tiene TTL propio. Re-pin de una entidad ya presente no refresca `added_at` si el hash no cambia.

Continuidad:

- `ActiveEpisodeTurn::FOLLOWUP_RE` incluye `esta|este|esto|esa|ese|eso`.
- `self_contained?` exige `!followup_marker?`. «¿Qué me está indicando?» y «este tablero» caen en `continued_elliptical` y `compose_text` antepone el goal y **todos** los `episode.identifiers` con `source=user` (`identity_items`).
- El log `field_companion_turn` escribe el mismo SHA en `original_sha256` y `effective_sha256` (el del texto crudo). No prueba que el retrieve haya visto el texto crudo. Lo que Bedrock recibió está en `[PILOT_AUDIT].question`.

Medición que no hay que revertir: el 26-jul, pasar el pin de 3 a 6 en `em3000_fotocelula_220v` metió páginas de más y la respuesta inventó un conector de 24 V. `RagRetrievalProfile` lo deja escrito. El tope 3 se mantiene.

## 3. Causas confirmadas con la traza

| Caso | Decisión de episodio | Qué recuperó | Causa |
|---|---|---|---|
| EM2000 hidráulico, obstáculo (17:33) | `continued_self_contained`, sin compose | cero chunks; canned `pinned_no_results` | El pin filtró. El Sorry de Bedrock se traduce a «no hay evidencia» sin un segundo retrieve **dentro del pin**. La página hidráulica no entró en la ventana. |
| EM4000 V1, obstáculo (17:34) | self-contained, sin compose | ELECMEGON p.29–30, SISTEL p.90 | Misma familia «obstáculo». EM4000 V1 no está en esos 3 chunks. La respuesta dice que no está documentado. Es ranking, no síntesis. |
| EDEL K2 cerrojos, luego «Edel-k2» (17:35) | `continued_elliptical`, `composed_chars=114` | CTA p.17, ALJO Level 1B p.6 | El seguimiento compone identificadores viejos del episodio (`DL4`, `EM2000`). Esas placas ganan a la hoja EDEL. |
| EDEL K2, dos embarques (17:36) | self-contained | EDEL p.24 y p.26 | Entra EDEL y la respuesta habla de **EDEL-K3** / conector JH2. La hoja K2 de fotocélulas no está en la ventana. |
| «es un EDEL-k2» (17:37) | self-contained, reemplaza goal | EDEL p.23 | El modelo se reemplazó. La página que sí tiene K2 (la del LED 37, 17:34, pp. 24–26) no volvió a entrar. Falso «K2 no documentado». |
| MR08, serie SCI (17:39) | self-contained | cero chunks; mismo canned | «falla» enciende el tope 5 y **apaga** `StructuredEvidenceRoute`. SCI no entra. |
| H4 (17:55) | `continued_elliptical` | solo hoja 4 | «está» en «está indicando» dispara el seguimiento. El retrieve lleva `41 HIDRA TPR60 MH SUBE` del episodio de SEGURIDADES. La hoja 2 (H4 = luz piloto, falla seguridad) no entra. |
| «luz piloto falla de seguridad» (17:56) | self-contained | hoja 2 | La frase de la tabla sí rankea. La respuesta es la correcta. No degradar este camino. |
| Seguridad IN/OUT (17:57) | self-contained | solo `chunk_p1_2` p.1 | Responde borne 12/13 y 22/23. La tabla de la hoja 2 (23 OUT, 24 IN) no entró. |
| Micros de nivel (17:57) | self-contained | hoja 6 | La tabla de la hoja 2 (30 inferior, 31 superior) no entró. Falso negativo. |
| Llamadas 1 y 2 (17:58) | self-contained | hojas 3 y 5 | Igual: la fila 33/34 de la hoja 2 no entró. |
| Presostato (17:58) | self-contained | hoja 2 **y** hoja 1 | La respuesta mezcla 25 OUT / 26 IN con 14 IN / 15 OUT. `chunk_p1_2` no aporta «un número junto al rótulo»: publica filas explícitas `| 14 | PRESOSTATO IN |`, `| 15 | PRESOSTATO OUT |`, `| 24 | PRESOSTATO IN |`, `| 25 | PRESOSTATO OUT |`. Dos filas explícitas incompatibles son conflicto (Fase 4). Quitar las filas falsas es la Fase 5. |
| Temporizadores (17:58) | `continued_elliptical`, `composed_chars` presente | otra vez hojas 1 y 2 del presostato | «este tablero» matchea `FOLLOWUP_RE`. El goal del presostato va delante. La respuesta habla de K3/K4 y no menciona T1 ni T2. |
| SUBE, BAJA, cadena de seguridad, foso, HIDRA TPR60/TPR70, DL4 de Level 1B, LED 37 de EDEL K2 | self-contained, salvo BAJA que es elíptica y acertó K2 | la hoja correcta | Estos hay que conservarlos. BAJA («¿Y para BAJA?») debe seguir siendo seguimiento. |

La hoja 1 del MH ya estaba diagnosticada el 23-sep (`docs/PLAN_PILOTO_ELEMONT_2026-09-24.md`): el parche de T1/T2 se aplicó; **la bornera no se tocó**. Sigue viva. El presostato de hoy cita `chunk_p1_2.txt` para los 14/15.

## 4. Hipótesis descartadas

- «En esta batería el pin estaba vencido.» No. Varios turnos tienen `filter_applied=true` y los demás citan solo páginas de SEGURIDADES o del plano MH. El canned nombra «documentos pineados».
- «Hay que subir el top-k del pin.» No como defecto general. Ya se midió que 6 empeora un caso de fotocélula. El arreglo es preferir el designador, no traer más páginas parecidas.
- «DATA_NOT_AVAILABLE sale antes de buscar.» No. Sale cuando el retrieve pineado devuelve el Sorry. El reintento sin filtro está apagado a propósito con `force_entity_filter` (`retry_without_entity_filter = apply_filter && !force_entity_filter`). No hay que volver a buscar en todo el corpus.
- «El follow-up rewriter de WhatsApp concatena el turno.» En web con el turno companion activo, el texto efectivo lo arma `ActiveEpisodeTurn#compose_text`. El rewriter solo corre si el episodio no es dueño del hilo.
- «H4 falló por síntesis.» No. Con la frase de la tabla, la misma sesión respondió bien en el turno siguiente. El primer turno ni vio la hoja 2.

## 5. Mapa del flujo actual

```
textarea
  → POST /rag/ask
  → find_or_create_for   # borra la sesión si expires_at venció
  → ActiveEpisodeTurn
       FOLLOWUP_RE (esta/este/…) → elliptical → compose_text(goal + todos los identifiers)
       si no → effective = texto crudo, replace_goal
  → resolve_retrieval_scope(pin) → force_entity_filter
  → RagRetrievalProfile: pin documento = 3; "falla" = 5
  → StructuredEvidenceRoute solo si NO es safety-critical y hay identificador en mayúsculas
  → Bedrock retrieve_and_generate, filtro = URI del pin
  → Sorry + pin → pinned_no_results, sin segundo retrieve
  → companion + citas

GET /  (checkbox)
  → find_by(identifier, channel) sin expires_at ni account_id
  → pinta data-selected
```

Esto es el flujo de hoy. El rescate de la Fase 3 no se dibuja aquí: va antes de generar, dentro de `StructuredEvidenceRoute#execute`, no en el Sorry.

## 6. Riesgos de regresión

- Tratar «está/este» como pregunta nueva rompe «¿y este?» y «la misma falla» si el corte es torpe. «¿Y para BAJA cuál es el relé?» tiene que seguir en el episodio y responder K2. Una pregunta explícita de 6 palabras no puede ganar a `FOLLOWUP_START_RE` ni a «la misma / el mismo / lo mismo». `eso` no se relaja. «esta» junto a vocabulario ya cubierto por `safety_critical_query?` tampoco: «¿Cómo soluciono eso si ya cambié la placa?» y «¿Cómo reseteo esta falla si ya cambié el fusible?» siguen siendo seguimiento.
- Un segundo retrieve dentro del pin suma latencia y un `Retrieve` solo cuando la ventana no cubre el designador o la fila de asignación. No puede dispararse en cada turno, ni salir del documento pineado, ni vivir en el Sorry de `BedrockRagService#query`.
- Preferir una fila explícita `borne N → función` no puede tapar un procedimiento que ya está bien citado (cadena de seguridad hoja 5, foso hoja 7, K1/K2 hoja 2) ni resolver en silencio dos asignaciones explícitas incompatibles.
- Parchear `chunk_p1_2` mal deja la bornera peor. Va aparte, con SHA y rollback, después de que el código deje de citar esa hoja como autoridad.
- No ampliar `PINNED_DOCUMENT_RESULTS`.

## 7. Plan por fases

### Fase 1 — El pin vencido no se dibuja

Objetivo único: la UI y el retrieve usan la misma sesión viva.

- `pinned_uris_for_current_session` busca por `account_id + identifier + channel`, igual que `find_or_create_for`.
- Si la fila no existe o `expired?`, el conjunto de URIs es vacío.
- El GET no destruye la fila. La destrucción sigue en `find_or_create_for`, en el ask y en el pin. Así un refresh no borra historial por el mero hecho de abrir la home; el checkbox igual queda apagado.
- No añadir un TTL de pin. El único vencimiento es `ConversationSession::EXPIRY_DURATION`.

Archivos: `app/controllers/home_controller.rb`, `test/controllers/home_controller_test.rb` (crearlo si no cubre el checkbox).

Tests:

- Sesión con `expires_at` en el pasado y `active_entities` de SEGURIDADES → el HTML no trae `data-selected="true"` para ese documento.
- Sesión viva → el checkbox sigue marcado.
- `account_id` distinto con el mismo `identifier` no marca el pin de la otra cuenta.
- La fila vencida sigue en la base después del GET.

Criterio: esos cuatro tests verdes. No hace falta Bedrock.

### Fase 2 — Una pregunta con objetivo propio no hereda el episodio

Objetivo único: un deíctico débil dentro de una pregunta con objetivo propio deja de ser anáfora. La señal fuerte de seguimiento sigue ganando.

Hoy `self_contained?` exige `!followup_marker?`, y `followup_marker?` es `FOLLOWUP_RE` o `FOLLOWUP_START_RE`. `FOLLOWUP_RE` mete en el mismo saco «la misma» y «esta». `normalize_label` ya dobla «está» a `esta` y «¿Y …» a un texto que empieza por `y`, así que `FOLLOWUP_START_RE` sigue viendo el arranque. No añadir otra lista de verbos ni un subsistema de NLP. Cambiar la precedencia dentro de `self_contained?`. `followup_marker?` se queda para los turnos cortos. Las señales que ya existen alcanzan: `FOLLOWUP_START_RE`, la anáfora `la misma` / `el mismo` / `lo mismo`, `explicit_question?`, `names_equipment?`, el conteo de palabras, y `RagRetrievalProfile#safety_critical_query?` (`SAFETY_CRITICAL_PATTERNS`).

1. Señal fuerte, y el turno sigue siendo seguimiento aunque sea pregunta explícita y tenga 6 palabras o un designador: `FOLLOWUP_START_RE`, y la anáfora `la misma` / `el mismo` / `lo mismo`.
2. Descartada esa señal: una pregunta explícita (`FollowupQueryRewriter.explicit_question?`) con objetivo propio — designador (`names_equipment?`) o 6 palabras o más — vence solo a los deícticos débiles del texto ya normalizado: `esta` y `este`. Ahí entran «está», «esta» y «este». `eso` no se relaja. El resto de `FOLLOWUP_RE` (`esa`, `ese`, `esto`, `ahi`, `same`, `that`, `this`, `it`, y `eso`) tampoco.
3. El paso 2 no corre si el turno crudo matchea `safety_critical_query?`. «esta» junto a ese vocabulario (`falla`, `defecto`, `reparar`, …) sigue siendo seguimiento. No se copia la lista de patrones dentro de `ActiveEpisodeTurn`.
4. El turno corto que no cayó en 1, 2 ni 3 conserva `elliptical?` actual.

Siguen siendo seguimiento:

- «¿Cómo soluciono eso si ya cambié la placa?»
- «¿Cómo reseteo esta falla si ya cambié el fusible?»
- «¿Y para BAJA cuál es el relé?»
- «la misma falla»

Siguen siendo self-contained (no componen):

- «Tengo encendida la luz H4. ¿Qué me está indicando?»
- «¿Qué temporizadores tiene este tablero y cómo están configurados?»

En un seguimiento que sí compone, `identity_items` no vuelca los identifiers históricos del episodio. Fabricante, modelo y código de falla se quedan. Un identifier `source=user` no se añade si no está ya en el goal vigente; `DL4` y `EM2000` no entran en una confirmación de EDEL K2.

Archivos: `app/services/rag/active_episode_turn.rb`, `test/services/rag/active_episode_turn_test.rb` (o el test de episodio que ya cubra `continued_elliptical`).

Tests de regresión, sin Bedrock:

- «Tengo encendida la luz H4. ¿Qué me está indicando?» después de un episodio HIDRA → `continued_self_contained` o episodio nuevo, `composed` nil. El texto efectivo no contiene `HIDRA` ni `TPR60`.
- «¿Qué temporizadores tiene este tablero y cómo están configurados?» después de presostato → no compone el goal del presostato.
- «¿Y para BAJA cuál es el relé?» después de SUBE → sigue `continued_elliptical` y el texto efectivo conserva el MH. El arranque `y` gana a las 6 palabras.
- «Edel-k2» después de «EDEL K2 cerrojos exteriores» → conserva K2 y cerrojos, y no añade `EM2000` ni `DL4`.
- «la misma falla» sigue componiendo.
- «¿Cómo soluciono eso si ya cambié la placa?» después de un episodio con goal propio → sigue seguimiento y compone. `eso` no queda self-contained por tener 6 palabras.
- «¿Cómo reseteo esta falla si ya cambié el fusible?» después de un episodio con goal propio → sigue seguimiento y compone. `esta` no gana porque `falla` ya es `safety_critical_query?`.

Criterio: esos tests verdes y la suite de `active_episode_turn` / `rag_query_concern` de episodios sin fallos nuevos.

### Fase 3 — Rescate dentro del pin, antes de generar

Objetivo único: con un solo documento pineado, como máximo un `retrieve_chunks` adicional, dentro de esas mismas URI, antes de generar. Dos caminos de la misma clase. Ningún `if` por Seguridad, Micro, Llamada, H4 ni por número de hoja.

No subir `PINNED_DOCUMENT_RESULTS`. No reintentar en el corpus abierto. No enganchar el rescate al Sorry de `BedrockRagService#query`: `retrieve_and_generate` ya generó, y una ventana incorrecta pero no vacía nunca pasa por `localized_pinned_no_results`.

Dueño: `Rag::StructuredEvidenceRoute#execute`, que ya separa `retrieve_chunks` de `@generator.query`. `QueryOrchestratorService` no gana una rama nueva: sigue entrando por `StructuredEvidenceRoute.build`. Ampliar `eligible?` es lo que saca estas preguntas de `BedrockRagService#query`. El segundo `retrieve_chunks` ocurre en `execute`, sobre el resultado del primero, y el conjunto fusionado entra a `complete_from_retrieval`. Ese método sigue sin recuperar: lo usan `AmbiguousModelResponder` y `ContextEvidenceRoute`, que ya gastaron su retrieve. Si el flag `RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED` está apagado, no hay rescate; en `config/deploy.yml` ya está `"true"`. No añadir otro flag.

Flujo:

```
pregunta
  → retrieve inicial, mismas URI, force_entity_filter
  → ¿el designador está en la ventana, o ya hay una fila explícita que coincide?
  → si no, como máximo un retrieve más, mismas URI
  → merge por chunk_sha256 (el mismo uniq que expand_dividers)
  → select_generation_chunks
  → generación
```

Un miss del segundo retrieve no dispara un tercero ni cae a `BedrockRagService#query`. Si el merge viene vacío, vale la abstención que la ruta ya tiene. Si viene con chunks que no cubren, se genera sobre ese merge; no se fabrica otro Sorry.

Presupuesto:

- Pregunta que ya era elegible hoy: el primer retrieve sigue en `STRUCTURED_MAPPING_RESULTS` (12).
- Pregunta elegible solo por este rescate: el primer retrieve usa `RagRetrievalProfile#number_of_results` (3, o 5 si es safety-critical). No 12.
- El retrieve adicional, en los dos caminos, pide `PINNED_DOCUMENT_RESULTS` (3), las mismas `entity_s3_uris` y `force_entity_filter: true`.

El pin tiene que ser uno (`entity_s3_uris` únicas == 1), el mismo conteo que ya usa `pinned_exact_designator_lookup?`. Cero pines o dos pines: sin rescate.

#### QueryEntities, case-insensitive estrecho

`identifier_candidate?` hoy exige `IDENTIFIER_SHAPE` sobre el token crudo, y esa forma exige mayúsculas.

- Un token mixto o en minúsculas entra solo si, además, tiene un dígito o un separador de los que la forma ya admite (`-`, `.`, `_`). `Edel-k2` → `EDELK2`, `em4000` → `EM4000`, `t1` → `T1`, `h4` → `H4`. `shape_of` y `canonical_of` se calculan sobre el fold en mayúsculas; el raw no se reescribe para mostrarlo.
- Ese fold no convierte unidades ni ordinales en identifiers. Rechaza `24v`, `220v`, `10a`, `1er`, `2do`. La forma, ya en mayúsculas, es dígitos seguidos de un sufijo corto de unidad u ordinal (`V`, `A`, `ER`, `DO`). No hace falta un diccionario de palabras. `t1` y `h4` siguen entrando: la letra va delante del dígito. `em4000` y `Edel-k2` también.
- Un token solo alfabético conserva la regla actual: el crudo ya tiene que cumplir `IDENTIFIER_SHAPE`. `SCI` y `OUT` en mayúsculas siguen contando. `sci`, `out`, `seguridad`, `falla`, `tabla` no. Una palabra normal no se vuelve identifier por pasar a mayúsculas.
- Un número suelto sigue fuera salvo el contexto etiquetado que ya existe (`shape == :numeric && position == :bare` se descarta). El dígito que autoriza el fold no salta esa regla. `24` y `41` solos no son identifiers; `borne 24` sí.

Un alfabético puro no es designador de rescate. El designador del camino (a) es el criterio que ya está en `RagRetrievalProfile#designator?`: shape distinto de `:numeric` y canonical con dígito. `OUT`, `IN` y `SCI` no abren ese camino y no lo bloquean. `MR08` sí lo abre, y con él entra el oráculo SCI.

#### Camino (a) — designador exacto

Entra si la pregunta tiene al menos un designador con dígito, aunque sea safety-critical. Esa es la única excepción a `eligible?`'s `!safety_critical_query?`. `pinned_exact_designator_lookup?` no se reescribe: otros llamadores siguen viéndolo en false cuando hay `falla`. Sin designador con dígito, el tope 5 actual se queda y este camino no corre.

Después del primer retrieve, si ningún chunk cumple `QueryEntities.identifier_present?` para ese designador, un solo `retrieve_chunks` más. El texto de ese retrieve es el turno crudo del técnico más los designadores con dígito (si hay varios, unidos por espacio, añadidos cuando el turno crudo no los trae ya). Tiene que conservar la intención de este turno: «EDEL K2 cerrojos exteriores», «MR08 serie SCI», «EM4000 V1 obstáculo». No usa solo el designador. No usa el texto compuesto del episodio, ni el goal, ni identifiers históricos que el turno crudo no dice. Hoy `StructuredEvidenceRoute` recibe `@query`, que puede ser ya el `effective_question` compuesto. Si ese string no es el turno crudo, el turno crudo entra como argumento. Eso no abre una rama nueva en `QueryOrchestratorService`. Si el primero ya contiene el designador, no hay segundo retrieve.

La generación recibe la primera ventana completa más los chunks rescatados, únicos por `chunk_sha256` (el mismo uniq que `expand_dividers`). No se recorta esa evidencia a los chunks que contienen el designador. El cover greedy de `select_generation_chunks` no es, en este rescate, el filtro que tira el resto de la primera ventana. `MAX_GENERATION_CHUNKS` (5) no autoriza a dejar fuera esa ventana: se conserva entera y se le agregan los rescatados que no estaban. Un miss del segundo retrieve no dispara un tercero.

#### Camino (b) — mapping sin designador

Entra solo si el camino (a) no entró, el pin es un documento, y la pregunta pide conexión, localización o asignación con una señal explícita de lookup que ya existe. No se añade una clave a `RELATION_TRIGGERS`. `requested_relation` solo no alcanza, ni en `:location`, ni en `:connection`, ni en `:attribution`.

Hace falta las dos cosas:

- `requested_relation` corta `:connection`, `:location` o `:attribution`, y
- además matchea `BORNE_TERMINAL_PATTERN`, `label_terms?` o `EXACT_LOOKUP_PATTERN`.

Una pregunta normal de manual que solo dispara «dónde» o «conector» no abre el segundo retrieve. No entra si `safety_critical_query?`, `exhaustive_query?` o `COMPARATIVE_PATTERN`. «¿A qué borne corresponde Seguridad OUT?» entra: `borne` es `BORNE_TERMINAL_PATTERN` y `corresponde` corta `:attribution`. «Micro nivel inferior» a secas, sin borne / label / lookup, no entra: no hay regla para la palabra Micro.

Después del primer retrieve, si ningún chunk trae una fila explícita con solape léxico con la pregunta, un solo `retrieve_chunks` más. El texto de ese retrieve es la pregunta más una orientación fija de tabla, la misma para todas: las palabras `tabla` y `designacion`, que `material_key` ya trata como lenguaje de tabla. No es un mapa de etiquetas. La frase de la pregunta viaja entera, para que `OUT`, `IN` y `nivel 1` no se pierdan en `lexical_tokens` (ahí un token de menos de 4 letras se tira).

Si el primer retrieve ya trae esa fila, no hay segundo.

Selección, cuando no hay identifier que cubrir: hoy `select_generation_chunks` devuelve `chunks.first(PINNED_DOCUMENT_RESULTS)` en cuanto `covering` está vacío (la línea que sale si `labelled` e `identifiers` vienen vacíos). En este camino eso no alcanza. Se prefiere el chunk con una fila explícita — las formas que `assignment_line?` ya reconoce, o una fila de tabla — y solape léxico con la pregunta. Un token de 2 o 3 letras entra en ese solape solo si va en mayúsculas o tiene dígito, para que `OUT` no empate con `IN` por la sola palabra «seguridad». Un número junto a un rótulo, sin fila, no gana por eso. Si ninguna fila explícita solapa, se conserva el fallback de los primeros 3.

#### chunk_p1_2 real

Fuente local: `tmp/elemont_patch_2026-09-23/chunk_p1_2_current.txt`. No es un esquema con números sueltos junto al rótulo. La bornera está en filas explícitas, y los `FIELD_RECORD` las repiten. Extracto fiel:

```
| 12 | SEGURIDAD IN |
| 13 | SEGURIDAD OUT |
| 14 | PRESOSTATO IN |
| 15 | PRESOSTATO OUT |
| 22 | SEGURIDAD OUT (señal de salida) |
| 23 | SEGURIDAD IN (señal de entrada) |
| 24 | PRESOSTATO IN |
| 25 | PRESOSTATO OUT |
| 26 | LIMITE INFERIOR |
| 27 | LIMITE SUPERIOR |
| 31 | LLAMADA NIVEL 1 |
| 32 | LLAMADA NIVEL 2 |
```

El mismo objeto dice `H4` como lámpara vinculada a K5 y K7, y `T1` / `T2` como transformadores (220VAC/18VCD y 220VAC/24VAC), no como temporizadores. Un rescate que se salta el segundo retrieve en cuanto el token ya está en la primera ventana deja esa lectura como si cubriera el hecho. El probe de la sección 10 es el que lo dice. No se añade un `if` por H4, T1 ni T2.

#### Tests

No alcanza pasar un chunk bueno a `select_generation_chunks` y afirmar el hecho. El test arma la ruta con la pregunta textual y un fake de `retrieve_chunks`.

Preguntas canónicas. La intención sale de `borne` y `corresponde`, que ya están en `RELATION_TRIGGERS`. Los nombres van en la pregunta del test, no en código:

- «¿A qué borne corresponde Seguridad OUT?»
- «¿A qué borne corresponde Seguridad IN?»
- «¿A qué borne corresponde el micro de nivel inferior?»
- «¿A qué borne corresponde el micro de nivel superior?»
- «¿A qué borne corresponde la llamada de nivel 1?»
- «¿A qué borne corresponde la llamada de nivel 2?»

Seguridad OUT, Seguridad IN y presostato usan como primer retorno ese extracto real, o un fixture que lo copie. El chunk ya trae fila explícita con solape (`SEGURIDAD OUT`, `SEGURIDAD IN`, `PRESOSTATO`). Si con ese contenido el rescate de mapping no dispara, el test afirma una sola llamada y la fila que el chunk sí publica. No se cambia el primer retorno por «un número junto a un rótulo» para forzar el segundo retrieve ni para afirmar 23, 24, 25 o 26. Esos casos dependen de la Fase 5. Dos filas explícitas incompatibles no se descartan aquí; eso es la Fase 4.

Micros y llamadas: el mismo archivo ya tiene `| 26 | LIMITE INFERIOR |`, `| 27 | LIMITE SUPERIOR |`, `| 31 | LLAMADA NIVEL 1 |`, `| 32 | LLAMADA NIVEL 2 |`. Si el primer retorno es ese chunk y el solape léxico ya cuenta, no se fuerza un segundo retrieve y se documenta la misma dependencia de la Fase 5. Si «micro» no solapa con `LIMITE`, el camino (b) sí puede pedir el segundo retrieve; el segundo retorno puede traer la tabla de la hoja 2. El primer retorno no se sustituye por un fake de proximidad.

Donde el primer retorno no trae fila explícita con solape, afirmar:

1. `build` devuelve ruta con el flag en true y un solo pin; con el flag en false, o con cero o dos pines, devuelve nil.
2. `retrieve_chunks` se llama dos veces, nunca tres.
3. El segundo texto es la pregunta más `tabla` y `designacion`, y contiene la frase propia (`nivel inferior`, `nivel superior`, `nivel 1`, `nivel 2` cuando esas preguntas sí reintentan). No es una lista fija de etiquetas.
4. Las dos llamadas llevan las mismas `entity_s3_uris` del pin y `force_entity_filter: true`. `number_of_results` del segundo es 3.
5. Si los dos retornos comparten un `chunk_sha256`, el merge lo deja una vez.
6. Los chunks finales son la primera ventana completa más los rescatados.
7. El hecho de la hoja 2 se afirma solo si el segundo retorno lo trajo. No se afirma 23/24/25/26 contra el extracto real de `chunk_p1_2`.

Además:

- Pregunta normal de manual que solo corta `:location` o `:connection`, sin `BORNE_TERMINAL_PATTERN`, `label_terms?` ni `EXACT_LOOKUP_PATTERN`: una llamada. «¿Qué elementos aparecen en esa línea?» sigue en una llamada.
- Cadena de seguridad, redactada sin `borne` / label / lookup: una llamada.
- Foso, igual: una llamada.
- Designador presente en la primera ventana (`¿Qué es H4?` y un chunk con `H4`): una llamada. El segundo texto, cuando sí corre, contiene el turno crudo y el designador, no solo el designador y no el goal del episodio.
- Designador ausente (`EM4000 V1 obstáculo`, `EDEL K2 cerrojos exteriores`, `MR08 serie SCI`): dos llamadas como máximo. El segundo texto conserva «obstáculo», «cerrojos exteriores» o «SCI». Si el segundo tampoco trae el designador, siguen siendo dos. La generación ve la primera ventana completa y los chunks rescatados.
- Mapping sin identifier: como máximo un reintento, y solo con la señal explícita de lookup. Si el segundo tampoco trae fila explícita, siguen siendo dos y no hay caída a `BedrockRagService#query`.
- `PINNED_DOCUMENT_RESULTS` sigue en 3. El test de `RagRetrievalProfile` que lo fija no se toca.
- `QueryEntities`: acepta `Edel-k2`, `em4000`, `t1`, `h4`. Rechaza `24v`, `220v`, `10a`, `1er`, `2do`, `seguridad`, `falla`, `tabla`, `out` en minúsculas, y `24` suelto. `SCI` y `OUT` en mayúsculas siguen el criterio alfabético actual. `borne 24` sigue siendo identifier etiquetado.

Los oráculos 1–6, 13 y 14 de la sección 9 usan el doble fake cuando el designador no está en el primer retorno: el chunk final contiene el hecho y también el resto de la primera ventana. No se llama a Bedrock. El assert no es «el modelo redactó esta frase». Si el primer retorno ya contiene el token (`H4`, `T1`, `T2` dentro de `chunk_p1_2`) y por eso no hay segundo retrieve, el test no inventa un primer retorno vacío para hacer pasar el hecho. El probe read-only decide si la Fase 3 queda `BLOCKED`.

Archivos: `app/services/rag/query_entities.rb`, `app/services/rag/structured_evidence_route.rb`, `test/services/rag/query_entities_test.rb`, `test/services/rag/structured_evidence_route_test.rb`. `app/services/query_orchestrator_service.rb` solo si algún test con el flag en true espera `build` nil para una pregunta de un solo pin que ahora es elegible; el caso flag false sigue en nil. No tocar el Sorry de `app/services/bedrock_rag_service.rb`.

### Fase 4 — La fila explícita pesa más que el número del dibujo, y dos filas explícitas siguen en conflicto

Objetivo único: integrar la excepción en la regla de conflicto que `generation.txt` ya tiene. No añadir otra que diga que la tabla gana siempre.

La regla viva está en el bloque que empieza por «When two retrieved fragments conflict»: hay que citar las dos lecturas, nombrar la página si está, y no elegir en silencio. El punto siguiente dice lo mismo cuando el conflicto está dentro de un fragmento. Ahí se integra, en ese bloque, sin un segundo policy:

- Un número suelto, o un número junto a un rótulo en el esquema, no es por sí solo una asignación explícita.
- Una fila explícita `borne N → función X` (o la celda equivalente) tiene más autoridad que esa proximidad gráfica cuando la pregunta pide la asignación.
- Si hay dos asignaciones explícitas incompatibles — `borne 23 → Seguridad OUT` frente a `borne 24 → Seguridad OUT`, o el mismo borne con dos funciones — sigue siendo conflicto. Se citan las dos, con su página, y no se elige.

Una fila explícita correcta pesa más que un número visual junto a un rótulo. Dos filas explícitas incompatibles no se resuelven eligiendo una. El presostato se prueba con el contenido real de `chunk_p1_2`, no con 14/15 dibujados al lado de un rótulo. Ese chunk publica a la vez `| 14 | PRESOSTATO IN |`, `| 15 | PRESOSTATO OUT |`, `| 24 | PRESOSTATO IN |` y `| 25 | PRESOSTATO OUT |`. Eso ya es conflicto dentro del fragmento. Si otra página trae otra fila explícita distinta, también se cita. La Fase 5 es la que deja de publicar la fila falsa; hasta entonces el conflicto se muestra.

No hace falta un parser nuevo de `FIELD_RECORD`. Un post-procesador que borre bornes no está justificado.

Test, sin modelo: el prompt renderizado contiene la excepción y conserva «leave the conflict unresolved» / «Never choose one silently». No contiene una instrucción de elegir siempre la tabla. El fixture del presostato es el extracto real de la Fase 3; el prompt no lo describe como resuelto ni trata 14/15 como proximidad gráfica. Una fila explícita sí pesa más que un número suelto junto a un rótulo cuando el otro chunk no tiene fila. Medir tokens: si el bloque pasa de 1,05× el prompt actual, se compacta dentro de la regla existente, no se añade otro. No ampliar `SourceFidelityGuard` en esta fase.

### Fase 5 — Corregir la bornera de la hoja 1 del MH

Objetivo único: `chunk_p1_2.txt` deja de afirmar bornes que la hoja 2 desmiente.

Separada del código. El 23-sep se parchearon T1/T2 y se dejó la bornera. El objeto local sigue publicando filas explícitas falsas, no solo 12/13 y 14/15: también 22/23 de seguridad, 24/25 de presostato, y los `FIELD_RECORD` que las repiten. Llamadas 31/32 y límites 26/27 están en el mismo extracto; se reescriben solo si contradicen la hoja 2. La hoja 2 se lee antes de escribir. El reemplazo es la remisión a esa hoja, no una bornera nueva inventada.

- Script al estilo `script/patch_elemont_chunk_p1_2_2026-09-23.rb`.
- Solo se reescriben las filas explícitas de `chunk_p1_2` que contradicen la tabla de la hoja 2. El reemplazo es la remisión a la hoja 2, no una bornera nueva inventada.
- Comprobar el SHA vivo antes de subir. Rollback = re-subir el objeto anterior.
- Escribir por `S3DocumentsService` para que `SectionNeighborExpander.invalidate!` corra (`app/services/rag/AGENTS.md`).
- No se hace en el mismo cambio que las fases 1–4. No se despliega si el SHA vivo no coincide con el esperado.

## 8. Archivos por fase

| Fase | Tocar | No tocar |
|---|---|---|
| 1 | `home_controller.rb`, test del home | `find_or_create_for`, TTL, JS del checkbox |
| 2 | `active_episode_turn.rb`, su test | `FollowupQueryRewriter`, `generation.txt` |
| 3 | `query_entities.rb`, `structured_evidence_route.rb` (`eligible?`, `execute`, selección sin identifier), tests de esas clases | `PINNED_DOCUMENT_RESULTS`, el Sorry de `bedrock_rag_service.rb`, `account_filter`, `complete_from_retrieval` como segundo retrieve |
| 4 | el bloque de conflicto ya existente en `generation.txt`, un test del prompt y de la selección | `SourceFidelityGuard`, renderer determinista, una regla nueva de «la tabla gana siempre» |
| 5 | script de parche del chunk, backup del objeto | código de retrieve |

`query_orchestrator_service.rb` no gana una ruta paralela. Solo se toca si un test con el flag en true deja de ser cierto.

## 9. Tests concretos (oráculos)

Los de continuidad y los de designador son fixtures de texto. Los oráculos 7–12 no se satisfacen entregando el chunk bueno al selector: pasan por la ruta, con la pregunta textual y un fake de `retrieve_chunks`, como dice la Fase 3. El assert de todos es «el chunk final contiene el hecho», no «el modelo redactó esta frase».

SEGURIDADES, camino (a), designador con dígito:

1. EM2000 hidráulico + obstáculo → el chunk contiene CN7 y CN8.
2. EM4000 V1 + obstáculo → el chunk contiene XC4 y XC7.
3. EDEL K2 + cerrojos exteriores → el chunk contiene serie 40 (LED/serie 40 = cerrojos exteriores).
4. EDEL K2 + dos embarques → el chunk contiene F1 fotocélula embarque 1 y F2 embarque 2.
5. MR08 + SCI → el chunk contiene SCI, CN-112 y CN-109. El designador que abre el rescate es MR08. SCI en mayúsculas no lo abre solo.

Elemont MH. 6, 13 y 14 son camino (a). 7–12 son camino (b). Seguridad OUT, Seguridad IN y presostato no se afirman con un doble fake de proximidad: el primer retorno es el extracto real de `chunk_p1_2`. Si ese chunk ya solapa, no hay segundo retrieve y el hecho de la hoja 2 queda para la Fase 5.

6. H4 → luz piloto, falla seguridad, solo si el primer retorno no contiene ya el token. `chunk_p1_2` sí contiene `H4` como lámpara de K5/K7. El probe dice si eso deja la Fase 3 en `BLOCKED`. El test no vacía el primer retorno para hacer pasar el hecho.
7. Seguridad OUT → con el extracto real, una llamada y las filas 13 y 22. No se afirma 23 como hecho de esta fase.
8. Seguridad IN → con el extracto real, una llamada y las filas 12 y 23. No se afirma 24 como hecho de esta fase.
9. Micro nivel inferior → 30 solo si el primer retorno no trae ya una fila explícita con solape. Si el extracto real (`LIMITE INFERIOR` en 26) ya cuenta, una llamada y dependencia de la Fase 5.
10. Micro nivel superior → igual, con 31 frente a `LIMITE SUPERIOR` en 27.
11. Llamada nivel 1 → 33 solo si el primer retorno no trae ya `| 31 | LLAMADA NIVEL 1 |`. Si lo trae, una llamada y dependencia de la Fase 5.
12. Llamada nivel 2 → igual, 34 frente a `| 32 | LLAMADA NIVEL 2 |`.
13. T1 → modo E, t < 3 min, solo si el primer retorno no contiene ya `T1`. El extracto real lo contiene como transformador. Misma regla que H4: el probe decide, no se maquilla.
14. T2 → modo Wu, t < 1 s. Igual que T1.
15. Presostato OUT/IN → el fixture es el extracto real (14 IN, 15 OUT, 24 IN, 25 OUT). Son filas explícitas incompatibles entre sí. La Fase 4 no elige una. No se modela 14/15 como proximidad. 25/26 de otra página, si entran, se citan junto a estas filas; no las borran.

Continuidad:

16. Presostato y, en el turno siguiente, temporizadores → el segundo `effective_question` no contiene «presostato» y el selector entrega T1/T2.
17. «EDEL K2 cerrojos exteriores» y luego «Edel-k2» → el texto efectivo conserva K2 y cerrojos, sin EM2000, CTA ni ALJO.

Clase, además de los 17:

- Un identificador exacto del turno gana a un chunk vecino que solo comparte «obstáculo» o «cerrojo».
- Una fila explícita con solape léxico entra delante de un número suelto del esquema.
- Dos filas explícitas incompatibles siguen descritas en el prompt como conflicto sin resolver.
- El designador del turno gana a los identifiers heredados.
- Si el segundo retrieve trajo el designador, no se emite `pinned_no_results` y no hay tercera llamada.
- Sin designador con dígito y sin intención de mapping: una sola llamada. Cadena de seguridad y foso, redactados sin `borne` / `dónde` / `corresponde`, también.
- Designador presente en la primera ventana: una llamada. Ausente: como máximo una más.
- Mapping sin identifier: como máximo una más, y las dos dentro del pin.
- `¿Y para BAJA?` sigue elíptica. «la misma falla» sigue componiendo. Una pregunta de 6 palabras no le gana a `¿Y …`. «¿Cómo soluciono eso si ya cambié la placa?» y «¿Cómo reseteo esta falla si ya cambié el fusible?» siguen componiendo.

Conservar, con el mismo fixture de una sola llamada, los chunks que ya ganaron hoy: K1 SUBE, K2 BAJA, circuito 6 del foso (bornes 10 y 11, 3×20 W), cadena de seguridad de la hoja 5, cuatro series de HIDRA TPR60.

## 10. Criterios de aceptación

- Fases 1–4: la suite minitest de los archivos tocados en verde, y la suite de `rag_query_concern` + `active_episode_turn` + `structured_evidence_route` + `query_entities` + `rag_retrieval_profile` sin fallos nuevos.
- `PINNED_DOCUMENT_RESULTS` permanece 3. El test de perfil que lo fija sigue pasando.
- Ningún turno de los casos buenos de la sección 9 pasa de una llamada a `retrieve_chunks` en el fixture.
- El segundo retrieve aparece solo en camino (a) cuando el primero no contiene el designador, y en camino (b) cuando el primero no trae fila explícita con solape. Cero en una pregunta normal, en la cadena de seguridad y en el foso. Nunca tres. Nunca otra URI.
- El segundo retrieve del camino (a) usa el turno crudo más el designador, dentro del mismo pin. La generación recibe la primera ventana completa y los chunks rescatados.
- Fase 3 no se marca `COMPLETED` sin el probe read-only de abajo en verde. Si un caso esperado no recupera evidencia suficiente, el estado es `BLOCKED`.
- El prompt de la Fase 4 conserva la política de conflicto y no dice que la tabla gana siempre. El presostato se juzga con las filas explícitas reales de `chunk_p1_2`.

- Fase 5, aparte: SHA previo anotado, sync `COMPLETE`, una lectura del objeto ya no puede citar 12 como Seguridad IN ni 14 como Presostato IN desde `chunk_p1_2`.

No hay gate que exija a Gonzalo ni una revisión manual entre commits. El probe de la Fase 3 sí es gate de esa fase: sin él en verde, el estado queda `BLOCKED`.

### Probe read-only, obligatorio antes de marcar la Fase 3 COMPLETED

Cuando la Fase 3 está implementada, un script en `script/` — al estilo de `script/rag_seguridades_recall_probe.rb`, que solo llama `retrieve_chunks` — corre el retrieval real de estos 14 casos, con el mismo pin y la misma decisión de rescate que usaría la ruta. No es un paso opcional y no se sustituye por los fakes de minitest.

1. EM2000 hidráulico
2. EM4000 V1
3. EDEL K2 cerrojos exteriores
4. EDEL K2 dos embarques
5. MR08 SCI
6. H4
7. Seguridad OUT
8. Seguridad IN
9. Micro nivel inferior
10. Micro nivel superior
11. Llamada nivel 1
12. Llamada nivel 2
13. T1
14. T2

- Read-only. Sin generación, sin escritura, sin deploy. No escribe S3, no ingesta, no toca producción, no llama a `BedrockRagService#query` ni a `@generator.query`.
- Cada caso tiene que recuperar evidencia suficiente del hecho de la sección 9. Ver las filas explícitas de `chunk_p1_2` no cuenta como evidencia suficiente de la hoja 2.
- Sale 0 solo si los 14 recuperaron esa evidencia. Sale 1 si falta alguno. No pide interpretación y no se maquilla un caso faltante.
- No entra en CI. Sí bloquea marcar la Fase 3 como `COMPLETED`. Con el probe en rojo el estado es `BLOCKED`. No se deploya la fase como cerrada.

## 11. Rollout

1. Fase 1, deploy. El checkbox vencido se apaga en el próximo page load. No migra datos.
2. Fase 2, deploy. Solo cambia cuándo se compone el texto.
3. Fase 3, deploy solo después del probe read-only en verde. Si el probe no recupera evidencia suficiente, la fase queda `BLOCKED` y no se marca `COMPLETED`. El retrieve extra es condicional, anterior a la generación, dentro del pin.
4. Fase 4, deploy del prompt. Mide tokens una vez; si pasa de 1,05× el prompt actual, se compacta dentro del bloque de conflicto, no se añade otro.
5. Fase 5 solo con el SHA vivo confirmado y backup del objeto.

Flags nuevas: no. El rollback de 1–4 es revertir el commit. El de 5 es re-subir el chunk anterior.

## 12. Qué no cambiar

- `PINNED_DOCUMENT_RESULTS`, `OPEN_RESULTS`, `SAFETY_CRITICAL_RESULTS`, `STRUCTURED_MAPPING_RESULTS` como presupuesto de las preguntas que ya eran elegibles.
- El filtro de cuenta y `manual_corpus`.
- `force_entity_filter` cuando hay pin, y la prohibición de reintentar en el corpus global.
- El Sorry de `BedrockRagService#query` y `localized_pinned_no_results`. El rescate no se cuelga ahí.
- `complete_from_retrieval`: sigue sin hacer retrieve.
- Auto-scope y herencia de manual por episodio (siguen retirados).
- El tono de `generation.txt` fuera del bloque de conflicto.
- Foto, `SourceFidelityGuard`, costos, `bedrock_daily_costs`.
- No escribir `if pregunta incluye H4`, ni `if modelo == EDEL K2`, ni una lista Seguridad / Micro / Llamada.
- No añadir una clave a `RELATION_TRIGGERS`.
- No decir en el prompt que la tabla gana siempre cuando hay dos filas explícitas incompatibles.

## 13. Riesgos y rollback

| Fase | Riesgo | Rollback |
|---|---|---|
| 1 | Un pin vivo deja de verse si la búsqueda de sesión usa mal el `account_id` | Revertir el commit. El test de sesión viva lo cubre antes. |
| 2 | Un «este» corto, un «¿Y …», `eso`, o «esta» con `safety_critical_query?`, deja de heredar | Los tests de «la misma falla», BAJA, «¿Cómo soluciono eso…?» y «esta falla» tienen que estar rojos si pasa. Revertir. |
| 3 | El segundo retrieve en una pregunta que ya estaba bien, o fuera del pin | Los tests de una sola llamada y el assert de `entity_s3_uris` lo impiden. Revertir. |
| 4 | El prompt se alarga, o una fila explícita tapa a otra fila explícita | Revertir las líneas del bloque de conflicto. No hay flag. |
| 5 | Bornera mal reescrita | Re-subir el objeto guardado. |

## 14. Prompt para ejecutar la Fase 1

La Fase 1 está `COMPLETED` en `763db1d975ee53791762e0fd963c666c9662c927`. Un chat nuevo no la vuelve a implementar: lee Execution State y el prompt de la Fase 2.

```
Repo: /Users/lahirisan/smart_deal. Implementa solo la Fase 1 de
docs/PLAN_FIX_RETRIEVAL_PIN_Y_CONTINUIDAD_2026-09-28.md.

HomeController#pinned_uris_for_current_session debe resolver la sesión
con account_id, identifier y channel, igual que ConversationSession.find_or_create_for.
Si no hay fila o expired? es true, las URI pineadas son un conjunto vacío.
El GET no llama a destroy ni a find_or_create_for. No añadas TTL de pin.
No toques el JS del checkbox ni EXPIRY_DURATION.

Tests minitest: sesión vencida con un pin no renderiza data-selected="true";
sesión viva sí; otra account_id no hereda el pin; el GET no borra la fila vencida.
Corre esos tests y la suite del home controller. No deploy. No empieces la Fase 2.
```

## 15. Prompts de las fases siguientes

El prompt vigente de la siguiente fase es el de Execution State. Esta sección dice lo mismo para que un chat nuevo no dependa de un mensaje viejo.

Fase 2:

```
Repo: /Users/lahirisan/smart_deal

Commit de la Fase 1: 763db1d975ee53791762e0fd963c666c9662c927
Mensaje: Hide pins from an expired session on the home checkbox.
Ese commit ya cerró el checkbox. No lo reabras. No implementes la Fase 1 otra vez.

El chat no es la memoria. Antes de codear:
1. Lee docs/PLAN_FIX_RETRIEVAL_PIN_Y_CONTINUIDAD_2026-09-28.md, incluida Execution State.
2. git status
3. git log -1 y el commit de la Fase 1 anotado en Execution State
4. Lee este prompt. Si un mensaje viejo contradice el repo o el plan, ganan repo y plan.

Implementa SOLO la Fase 2. No implementes la Fase 3.

Objetivo: una pregunta con objetivo propio no hereda el episodio. La señal fuerte de seguimiento sigue ganando. No crees un subsistema de NLP. Usa señales que ya existen: FOLLOWUP_START_RE, "la misma" / "el mismo" / "lo mismo", FollowupQueryRewriter.explicit_question?, names_equipment?, el conteo de palabras, y RagRetrievalProfile#safety_critical_query? (SAFETY_CRITICAL_PATTERNS). No copies esa lista dentro de ActiveEpisodeTurn. normalize_label ya dobló "está" a "esta" y "¿Y" a un texto que empieza por "y".

Precedencia dentro de self_contained?:
1) FOLLOWUP_START_RE y "la misma" / "el mismo" / "lo mismo" siguen siendo seguimiento, aunque la pregunta sea explícita y tenga 6 palabras o un designador.
2) Sin esa señal fuerte, una pregunta explícita con designador o con 6+ palabras vence solo a los deícticos débiles "esta" y "este".
3) El paso 2 no corre si el turno crudo matchea safety_critical_query?.
4) El turno corto restante conserva elliptical? actual.

No relajes "eso". No relajes esa/ese/esto/ahi/same/that/this/it.

Deben seguir siendo follow-up:
- "¿Cómo soluciono eso si ya cambié la placa?"
- "¿Cómo reseteo esta falla si ya cambié el fusible?"
- "¿Y para BAJA cuál es el relé?"
- "la misma falla"

Deben seguir siendo self-contained, sin componer:
- "Tengo encendida la luz H4. ¿Qué me está indicando?"
- "¿Qué temporizadores tiene este tablero y cómo están configurados?"

identity_items, cuando compone, no añade identifiers históricos que no estén en el goal vigente. Fabricante, modelo y código de falla se quedan.

Archivos: app/services/rag/active_episode_turn.rb y su test. No toques FollowupQueryRewriter, retrieval ni generation.txt.

Tests minitest, sin Bedrock:
- H4 con "está indicando" después de HIDRA no arrastra HIDRA ni TPR60; composed nil.
- Temporizadores con "este tablero" después de presostato no componen ese goal.
- "¿Y para BAJA cuál es el relé?" después de SUBE sigue continued_elliptical y conserva el MH.
- "Edel-k2" tras "EDEL K2 cerrojos exteriores" conserva K2 y cerrojos, sin EM2000 ni DL4.
- "la misma falla" sigue componiendo.
- "¿Cómo soluciono eso si ya cambié la placa?" sigue componiendo.
- "¿Cómo reseteo esta falla si ya cambié el fusible?" sigue componiendo.

Corre esos tests y la suite de active_episode_turn y de episodios en rag_query_concern. No deploy.

Si pasan: commit, marca Fase 2 COMPLETED en Execution State, registra findings materiales, reescribe el prompt de Fase 3 para un chat nuevo. DETENTE. No implementes la Fase 3.
```

Fase 3:

```
Implementa solo la Fase 3 de docs/PLAN_FIX_RETRIEVAL_PIN_Y_CONTINUIDAD_2026-09-28.md.
Antes de codear: lee el plan, Execution State, git status, el commit de la Fase 2 y este prompt.

El rescate vive en Rag::StructuredEvidenceRoute#execute, antes de
complete_from_retrieval. No lo pongas en el Sorry de BedrockRagService#query.
No añadas una rama nueva en QueryOrchestratorService: amplía eligible?.
Si @query ya es el texto compuesto, pasa el turno crudo como argumento.
Eso no es una rama nueva. complete_from_retrieval sigue sin hacer retrieve.
Un solo documento pineado. Como máximo un retrieve_chunks adicional,
las mismas entity_s3_uris, force_entity_filter true, number_of_results 3.
Siempre dentro del mismo pin.
PINNED_DOCUMENT_RESULTS permanece 3. No reintentes fuera del pin. Nunca un tercero.
No caigas a BedrockRagService#query si el segundo retrieve tampoco cubre.

Camino (a): designador con el criterio de RagRetrievalProfile#designator?
(shape no numeric y canonical con dígito). Si el primer retrieve no lo contiene
(QueryEntities.identifier_present?), el segundo retrieve usa el turno crudo
más el o los designadores. No uses solo el designador. No uses el composed
histórico del episodio. Conserva la intención actual:
"EDEL K2 cerrojos exteriores", "MR08 serie SCI", "EM4000 V1 obstáculo".
La generación recibe la primera ventana completa más los chunks rescatados,
únicos por chunk_sha256. No recortes la evidencia a los chunks que contienen
el designador. MAX_GENERATION_CHUNKS no autoriza a tirar la primera ventana.
Una pregunta safety-critical con ese designador sí entra. Sin dígito, no.
Un alfabético puro (OUT, IN, SCI) no abre este camino y no lo bloquea.

Camino (b): sin designador con dígito. requested_relation :location,
:connection o :attribution no alcanza solo. Hace falta además
BORNE_TERMINAL_PATTERN, label_terms? o EXACT_LOOKUP_PATTERN.
Eso vale también para :attribution. No entra si es safety-critical,
exhaustive o comparativa. No añadas claves a RELATION_TRIGGERS.
No escribas reglas para Seguridad, Micro, Llamada ni H4.
El segundo texto es la pregunta más las palabras "tabla" y "designacion".
La selección, si no hay identifier que cubrir, prefiere una fila explícita
con solape léxico. Un número junto a un rótulo, sin fila, no gana por eso.
Si el primero ya trae esa fila, no hay segundo retrieve.

QueryEntities: mixto o minúsculas solo con dígito o separador - . _
(Edel-k2, em4000, t1, h4). Rechaza unidades y ordinales: 24v, 220v, 10a,
1er, 2do. No conviertas palabras normales en identifiers.
Lo puramente alfabético conserva la regla en mayúsculas.
Un número suelto sigue sin ser identifier salvo el contexto etiquetado actual.

Tests con fake de retrieve_chunks, no con un chunk bueno inyectado al selector.
Seguridad OUT, Seguridad IN y presostato: el primer retorno es el extracto
real de tmp/elemont_patch_2026-09-23/chunk_p1_2_current.txt (filas explícitas
12/13, 22/23, 14/15, 24/25). Si el rescate no dispara, afirma una llamada
y documenta que el hecho de la hoja 2 depende de la Fase 5.
No uses un fake de "número junto a rótulo" para hacer pasar 23, 24, 25 o 26.
Micros y llamadas: el mismo chunk tiene LIMITE 26/27 y LLAMADA 31/32.
Si ese solape ya cuenta, no fuerces el segundo retrieve.
Donde el primero no trae fila con solape, afirma dos llamadas, el texto,
el pin, el merge, la primera ventana completa más los rescatados, y el hecho
solo si el segundo retorno lo trajo.
Además: pregunta normal sin señal de lookup, cadena de seguridad y foso,
una llamada; designador presente, una llamada; designador ausente, como
máximo una más, con el turno crudo en el segundo texto.
No llames a Bedrock. No empieces la Fase 4.
No marques la Fase 3 COMPLETED sin el probe read-only obligatorio de la
sección 10 (14 casos, sin generación, sin escritura, sin deploy).
Si un caso esperado no recupera evidencia suficiente, el estado es BLOCKED.
No maquilles el probe.
```

Fase 4:

```
Implementa solo la Fase 4 de docs/PLAN_FIX_RETRIEVAL_PIN_Y_CONTINUIDAD_2026-09-28.md.
Antes de codear: lee el plan, Execution State, git status, el commit de la Fase 3 y este prompt.
Integra la excepción en el bloque de generation.txt que ya dice
"When two retrieved fragments conflict" y "Never choose one silently".
No añadas una regla que diga que la tabla gana siempre.
Un número suelto o junto a un rótulo no es una asignación explícita.
Una fila explícita borne N → función X pesa más que esa proximidad.
Dos filas explícitas incompatibles son conflicto real: se citan las dos
y no se elige en silencio.
El presostato usa el contenido REAL de chunk_p1_2:
| 14 | PRESOSTATO IN |, | 15 | PRESOSTATO OUT |,
| 24 | PRESOSTATO IN |, | 25 | PRESOSTATO OUT |.
No los trates como número visual junto al rótulo.
No añadas un post-procesador. No reescribas el resto del prompt.
Test sin modelo: el prompt contiene la excepción y conserva el conflicto sin
resolver; el fixture real no queda descrito como resuelto. Si el bloque pasa
de 1,05× el prompt actual, compacta dentro de la regla existente.
No parchees chunks. No empieces la Fase 5.
```

Fase 5:

```
Solo si las fases 1–4 están en main y la Fase 3 no está BLOCKED.
Sigue la Fase 5 de docs/PLAN_FIX_RETRIEVAL_PIN_Y_CONTINUIDAD_2026-09-28.md.
Antes de codear: lee el plan, Execution State, git status y el commit anterior.
Parchea chunk_p1_2 del plano Elemont MH. La fuente local
tmp/elemont_patch_2026-09-23/chunk_p1_2_current.txt tiene filas explícitas,
no números junto a rótulos: 12/13 y 22/23 de seguridad, 14/15 y 24/25 de
presostato, más los FIELD_RECORD que las repiten. Llamadas 31/32 y límites
26/27 se reescriben solo si contradicen la hoja 2. Lee la hoja 2 antes de
escribir. Esas filas remiten a la hoja 2. No inventes otros bornes.
Verifica el SHA vivo antes de subir, guarda el objeto anterior, escribe por
S3DocumentsService. No lo hagas si el SHA no coincide.
No cambies código de retrieve.
```

## Execution State

La memoria durable de la ejecución. Un chat nuevo lee esto antes de la fase que va a correr. El prompt de la fase siguiente, aquí, gana a un mensaje viejo.

### Phase 1
Status: COMPLETED
Commit: 763db1d975ee53791762e0fd963c666c9662c927
Tests: PASS
Material findings:
- `pinned_uris_for_current_session` hace `find_by(account_id:, identifier:, channel:)` y devuelve vacío si la fila no existe o `expired?`. El GET no llama a `destroy` ni a `find_or_create_for`. El test de la fila vencida lo deja en la misma id, vencida, con `active_entities`.
- Con `SharedSession::ENABLED` el identifier y el channel siguen siendo los compartidos, y la fila se busca igual por `current_account.id`.
- En test, `find_or_create_for` sin `account_id` cae en `Account.minimum(:id)`. El checkbox lee `current_account` (`www.example.com` → `accounts(:legacy)`). Los tests del pin pasan esa cuenta de forma explícita.
- Suite: `BUNDLE_PATH=vendor/bundle bin/rails test test/controllers/home_controller_test.rb` — 30 runs, 161 assertions, 0 failures. Sin Bedrock.
- `chunk_p1_2_current.txt` publica filas explícitas de bornera, no números junto a un rótulo. Eso ya está escrito en las Fases 3, 4 y 5. No cambió el código de esta fase.
Next phase impact:
- La Fase 2 no toca el pin ni el retrieve. El prompt de abajo es el que se pega en un chat nuevo.
Next phase prompt:
```text
Repo: /Users/lahirisan/smart_deal

Commit de la Fase 1: 763db1d975ee53791762e0fd963c666c9662c927
Mensaje: Hide pins from an expired session on the home checkbox.
Ese commit ya cerró el checkbox. No lo reabras. No implementes la Fase 1 otra vez.

El chat no es la memoria. Antes de codear:
1. Lee docs/PLAN_FIX_RETRIEVAL_PIN_Y_CONTINUIDAD_2026-09-28.md, incluida Execution State.
2. git status
3. git log -1 y el commit de la Fase 1 anotado en Execution State
4. Lee este prompt. Si un mensaje viejo contradice el repo o el plan, ganan repo y plan.

Implementa SOLO la Fase 2. No implementes la Fase 3.

Objetivo: una pregunta con objetivo propio no hereda el episodio. La señal fuerte de seguimiento sigue ganando. No crees un subsistema de NLP. Usa señales que ya existen: FOLLOWUP_START_RE, "la misma" / "el mismo" / "lo mismo", FollowupQueryRewriter.explicit_question?, names_equipment?, el conteo de palabras, y RagRetrievalProfile#safety_critical_query? (SAFETY_CRITICAL_PATTERNS). No copies esa lista dentro de ActiveEpisodeTurn. normalize_label ya dobló "está" a "esta" y "¿Y" a un texto que empieza por "y".

Precedencia dentro de self_contained?:
1) FOLLOWUP_START_RE y "la misma" / "el mismo" / "lo mismo" siguen siendo seguimiento, aunque la pregunta sea explícita y tenga 6 palabras o un designador.
2) Sin esa señal fuerte, una pregunta explícita con designador o con 6+ palabras vence solo a los deícticos débiles "esta" y "este".
3) El paso 2 no corre si el turno crudo matchea safety_critical_query?.
4) El turno corto restante conserva elliptical? actual.

No relajes "eso". No relajes esa/ese/esto/ahi/same/that/this/it.

Deben seguir siendo follow-up:
- "¿Cómo soluciono eso si ya cambié la placa?"
- "¿Cómo reseteo esta falla si ya cambié el fusible?"
- "¿Y para BAJA cuál es el relé?"
- "la misma falla"

Deben seguir siendo self-contained, sin componer:
- "Tengo encendida la luz H4. ¿Qué me está indicando?"
- "¿Qué temporizadores tiene este tablero y cómo están configurados?"

identity_items, cuando compone, no añade identifiers históricos que no estén en el goal vigente. Fabricante, modelo y código de falla se quedan.

Archivos: app/services/rag/active_episode_turn.rb y su test. No toques FollowupQueryRewriter, retrieval ni generation.txt.

Tests minitest, sin Bedrock:
- H4 con "está indicando" después de HIDRA no arrastra HIDRA ni TPR60; composed nil.
- Temporizadores con "este tablero" después de presostato no componen ese goal.
- "¿Y para BAJA cuál es el relé?" después de SUBE sigue continued_elliptical y conserva el MH.
- "Edel-k2" tras "EDEL K2 cerrojos exteriores" conserva K2 y cerrojos, sin EM2000 ni DL4.
- "la misma falla" sigue componiendo.
- "¿Cómo soluciono eso si ya cambié la placa?" sigue componiendo.
- "¿Cómo reseteo esta falla si ya cambié el fusible?" sigue componiendo.

Corre esos tests y la suite de active_episode_turn y de episodios en rag_query_concern. No deploy.

Si pasan: commit, marca Fase 2 COMPLETED en Execution State, registra findings materiales, reescribe el prompt de Fase 3 para un chat nuevo. DETENTE. No implementes la Fase 3.
```

### Phase 2
Status: PENDING
Commit: none
Tests: pending
Material findings:
- none yet
Next phase impact:
- La Fase 3 asume que un turno self-contained ya no llega compuesto. El segundo retrieve igual tiene que usar el turno crudo, no el composed histórico.
Next phase prompt:
```text
Ver el prompt de Fase 3 en la sección 15. Se reescribe al cerrar la Fase 2.
```

### Phase 3
Status: PENDING
Commit: none
Tests: pending
Material findings:
- `tmp/elemont_patch_2026-09-23/chunk_p1_2_current.txt` trae filas explícitas de bornera. Seguridad OUT/IN y presostato no se prueban con un fake de proximidad. Si el rescate no dispara, dependen de la Fase 5.
- El probe read-only de 14 casos es obligatorio antes de COMPLETED. Evidencia insuficiente deja la fase BLOCKED.
Next phase impact:
- La Fase 4 juzga el presostato con esas filas explícitas, no con 14/15 como número de dibujo.
Next phase prompt:
```text
Ver el prompt de Fase 4 en la sección 15. Se reescribe al cerrar la Fase 3.
```

### Phase 4
Status: PENDING
Commit: none
Tests: pending
Material findings:
- none yet
Next phase impact:
- La Fase 5 reescribe las filas explícitas que contradicen la hoja 2, incluidas 22/23 y 24/25, no solo 12–15.
Next phase prompt:
```text
Ver el prompt de Fase 5 en la sección 15. Se reescribe al cerrar la Fase 4.
```

### Phase 5
Status: PENDING
Commit: none
Tests: pending
Material findings:
- none yet
Next phase impact:
- none
Next phase prompt:
```text
none
```

