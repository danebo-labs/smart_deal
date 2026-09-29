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

Después del primer retrieve, si ningún chunk cumple `QueryEntities.identifier_present?` para ese designador, un solo `retrieve_chunks` más. El primer retrieve sigue usando la pregunta vigente. El segundo no la repite: la misma cadena devuelve el mismo top-3.

- Turno self-contained: el segundo texto es el tramo de designadores, desde el primer identifier alfabético o con dígito hasta el último designador con dígito. «EDEL K2 dos embarques» reintenta «EDEL K2». «Tengo encendida la luz H4…» reintenta «H4». «Falla la serie SCI del MR08» reintenta «SCI del MR08». El probe midió que «EDEL K2» y «H4» entran en el top-3 de la página que el turno completo no alcanza.
- Follow-up elíptico válido: el segundo texto es el goal vigente más el turno crudo. «Edel-k2» después de «EDEL K2 cerrojos exteriores» conserva «cerrojos exteriores». No se añaden identifiers históricos del episodio que no estén ya en ese goal. No se usa el `composed` como fuente directa. El goal se lee de `episode.goal`. El turno crudo entra como argumento cuando `@query` ya es el effective compuesto. Eso no abre una rama nueva en `QueryOrchestratorService`.

Si el primero ya contiene el designador, no hay segundo retrieve.

La generación recibe la primera ventana completa más los chunks rescatados, únicos por `chunk_sha256` (el mismo uniq que `expand_dividers`). No se recorta esa evidencia a los chunks que contienen el designador. El cover greedy de `select_generation_chunks` no es, en este rescate, el filtro que tira el resto de la primera ventana. `MAX_GENERATION_CHUNKS` (5) no autoriza a dejar fuera esa ventana: se conserva entera y se le agregan los rescatados que no estaban. Un miss del segundo retrieve no dispara un tercero.

#### Camino (b) — mapping sin designador

Entra solo si el camino (a) no entró, el pin es un documento, y la pregunta pide conexión, localización o asignación con una señal explícita de lookup que ya existe. No se añade una clave a `RELATION_TRIGGERS`. `requested_relation` solo no alcanza, ni en `:location`, ni en `:connection`, ni en `:attribution`.

Hace falta las dos cosas:

- `requested_relation` corta `:connection`, `:location` o `:attribution`, y
- además matchea `BORNE_TERMINAL_PATTERN`, `label_terms?` o `EXACT_LOOKUP_PATTERN`.

Una pregunta normal de manual que solo dispara «dónde» o «conector» no abre el segundo retrieve. No entra si `safety_critical_query?`, `exhaustive_query?` o `COMPARATIVE_PATTERN`. «¿A qué borne corresponde Seguridad OUT?» entra: `borne` es `BORNE_TERMINAL_PATTERN` y `corresponde` corta `:attribution`. «Micro nivel inferior» a secas, sin borne / label / lookup, no entra: no hay regla para la palabra Micro.

Después del primer retrieve, si ningún chunk trae una fila de tabla con solape real, un solo `retrieve_chunks` más. Una fila es `| celda | celda |` o `TOKEN | resto`. No cuenta `SOURCE_SECTION`, un margen ni una nota. El solape exige el ancla de la pregunta (`inferior`, `superior`, `llamada`, `seguridad`, `presostato`) y, si hay un token corto en mayúsculas (`OUT`, `IN`), ese token. Si la pregunta pide un borne, la fila tiene que traer un número. «nivel» o «seguridad» solos no tapan el rescate: `OUT` no empata con `IN`, una fila de «Chapa nivel» no tapa «llamada de nivel 1», y «MICRO RUEDA NIVEL SUPERIOR» sin número no tapa el borne 31.

El segundo texto es la frase pedida, sin el marco «¿A qué borne corresponde…». El probe midió que concatenar `tabla designacion` a «llamada nivel 1» saca la hoja 2 del top-3, y que «micro de nivel inferior», «llamada de nivel 1» y «Seguridad OUT» sí la traen. `OUT`, `IN` y `nivel 1` siguen en esa frase.

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
- Designador presente en la primera ventana (`¿Qué es H4?` y un chunk con `H4`): una llamada. En un self-contained cuyo primer retrieve no trae el designador, el segundo texto es el tramo de designadores (`EDEL K2`, `H4`, `SCI del MR08`), no la repetición del turno. En un elíptico válido contiene el goal vigente y el turno crudo, no el composed ni identifiers históricos fuera de ese goal.
- Designador ausente (`EM4000 V1 obstáculo`, `EDEL K2 cerrojos exteriores`, `EDEL K2 dos embarques`, `MR08 serie SCI`): dos llamadas como máximo. El segundo texto del self-contained es `EM4000 V1`, `EDEL K2` o `SCI del MR08`. Un follow-up elíptico «Edel-k2» conserva el goal vigente «cerrojos exteriores». Si el segundo tampoco trae el designador, siguen siendo dos. La generación ve la primera ventana completa y los chunks rescatados.
- Mapping sin identifier: como máximo un reintento, y solo con la señal explícita de lookup. Si el segundo tampoco trae fila explícita, siguen siendo dos y no hay caída a `BedrockRagService#query`.
- `PINNED_DOCUMENT_RESULTS` sigue en 3. El test de `RagRetrievalProfile` que lo fija no se toca.
- `QueryEntities`: acepta `Edel-k2`, `em4000`, `t1`, `h4`. Rechaza `24v`, `220v`, `10a`, `1er`, `2do`, `seguridad`, `falla`, `tabla`, `out` en minúsculas, y `24` suelto. `SCI` y `OUT` en mayúsculas siguen el criterio alfabético actual. `borne 24` sigue siendo identifier etiquetado.

Los oráculos 1–6, 13 y 14 de la sección 9 usan el doble fake cuando el designador no está en el primer retorno: el chunk final contiene el hecho y también el resto de la primera ventana. No se llama a Bedrock. El assert no es «el modelo redactó esta frase». Si el primer retorno ya contiene el token (`H4`, `T1`, `T2` dentro de `chunk_p1_2`) y por eso no hay segundo retrieve, el test no inventa un primer retorno vacío para hacer pasar el hecho. El probe read-only decide si la Fase 3 queda `BLOCKED`.

Archivos: `app/services/rag/query_entities.rb`, `app/services/rag/structured_evidence_route.rb`, `test/services/rag/query_entities_test.rb`, `test/services/rag/structured_evidence_route_test.rb`. `app/services/query_orchestrator_service.rb` solo si algún test con el flag en true espera `build` nil para una pregunta de un solo pin que ahora es elegible; el caso flag false sigue en nil. No tocar el Sorry de `app/services/bedrock_rag_service.rb`.

#### Aclaraciones fijadas antes de la Fase 4

La Fase 3 queda como está. Estas cuatro lecturas cierran ambigüedades del plan. No cambian su código.

**Rescate self-contained.** Donde este plan dice «turno crudo + designador», el segundo retrieve self-contained puede usar el tramo de designadores derivado del turno crudo. Ese segundo query es solo un query auxiliar de recall. La intención técnica completa permanece en la pregunta original, en la primera ventana conservada y en la generación final. No se reescribe la Fase 3 para mandar el turno crudo completo. En un follow-up elíptico válido se mantiene la regla ya implementada: goal o intención vigente más el turno crudo actual, sin identifiers históricos fuera del goal vigente y sin usar el composed contaminado como fuente directa.

**Mapping y fila explícita.** Una fila explícita con suficiente solape puede dar la primera ventana por cubierta y evitar el rescate aunque después esa fila resulte falsa o contradictoria. Eso no se corrige en la Fase 3. Si dos filas explícitas incompatibles llegan a generación, la Fase 4 las trata como conflicto no resuelto y no elige una en silencio. La Fase 5 corrige o remueve las filas falsas del chunk de origen.

**Ventana de rescate.** Cuando hay rescate se preserva deliberadamente la primera ventana completa más los chunks rescatados. En ese camino no se aplica `MAX_GENERATION_CHUNKS` ni el compactado normal. Es comportamiento deliberado de la Fase 3 y la Fase 4 no lo modifica.

**LLM pre-retrieval.** `conversational_turn_analysis`, `SemanticQueryAnalyzer` y Haiku están en shadow u observacional para este flujo. No gobiernan la elegibilidad de `StructuredEvidenceRoute`, la cobertura, el rescate ni la construcción del segundo retrieve. La Fase 4 no añade una llamada LLM.

### Fase 4 — La fila explícita pesa más que el número del dibujo, y dos filas explícitas siguen en conflicto

Objetivo único: integrar la excepción en la regla de conflicto que `generation.txt` ya tiene. No añadir otra que diga que la tabla gana siempre.

La regla viva está en el bloque que empieza por «When two retrieved fragments conflict»: hay que citar las dos lecturas, nombrar la página si está, y no elegir en silencio. El punto siguiente dice lo mismo cuando el conflicto está dentro de un fragmento. Ahí se integra, en ese bloque, sin un segundo policy:

- Un número suelto, o un número junto a un rótulo en el esquema, no es por sí solo una asignación explícita.
- Una fila explícita `borne N → función X` (o la celda equivalente) tiene más autoridad que esa proximidad gráfica cuando la pregunta pide la asignación.
- Si hay dos asignaciones explícitas incompatibles — `borne 23 → Seguridad OUT` frente a `borne 24 → Seguridad OUT`, o el mismo borne con dos funciones — sigue siendo conflicto. Se citan las dos, con su página, y no se elige.

Una fila explícita correcta pesa más que un número visual junto a un rótulo. Dos filas explícitas incompatibles no se resuelven eligiendo una. El presostato se prueba con el contenido real de `chunk_p1_2`, no con 14/15 dibujados al lado de un rótulo. Ese chunk publica a la vez `| 14 | PRESOSTATO IN |`, `| 15 | PRESOSTATO OUT |`, `| 24 | PRESOSTATO IN |` y `| 25 | PRESOSTATO OUT |`. Eso ya es conflicto dentro del fragmento. Si otra página trae otra fila explícita distinta, también se cita. La Fase 5 es la que deja de publicar la fila falsa; hasta entonces el conflicto se muestra.

No hace falta un parser nuevo de `FIELD_RECORD`. Un post-procesador que borre bornes no está justificado. No se añade una llamada LLM. No se toca la ventana de rescate de la Fase 3: si hubo rescate, la primera ventana completa y los chunks rescatados siguen enteros.

Test, sin modelo: el prompt renderizado contiene la excepción y conserva «leave the conflict unresolved» / «Never choose one silently». No contiene una instrucción de elegir siempre la tabla. El fixture del presostato es el extracto real de la Fase 3; el prompt no lo describe como resuelto ni trata 14/15 como proximidad gráfica. Una fila explícita sí pesa más que un número suelto junto a un rótulo cuando el otro chunk no tiene fila. Dos filas explícitas incompatibles siguen sin resolverse. Un procedimiento ya citado — cadena de seguridad, foso, K1/K2 — no cambia: la regla no lo sustituye. Medir tokens: si el prompt pasa de 1,05× el actual, se compacta dentro de la regla existente, no se añade otro. No ampliar `SourceFidelityGuard` en esta fase. No se añade una llamada LLM.

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
| 4 | el bloque de conflicto ya existente en `generation.txt`, un test del prompt | `SourceFidelityGuard`, `StructuredEvidenceRoute`, `QueryEntities`, retrieval, `PINNED_DOCUMENT_RESULTS`, la ventana de rescate, una llamada LLM, una regla de «la tabla gana siempre» |
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
- El segundo retrieve del camino (a) es solo un query auxiliar de recall. En un self-contained puede usar el tramo de designadores derivado del turno crudo; no se manda el turno crudo completo. En un elíptico válido usa el goal vigente más el turno crudo, sin identifiers históricos fuera de ese goal y sin el composed como fuente. La intención técnica completa permanece en la pregunta original, en la primera ventana conservada y en la generación. Cuando hay rescate, esa ventana completa más los chunks rescatados se conserva; ahí no corre `MAX_GENERATION_CHUNKS` ni el compactado normal.
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
- No añadir una llamada LLM para decidir el conflicto, la elegibilidad o el rescate. `SemanticQueryAnalyzer` sigue en shadow.
- No aplicar `MAX_GENERATION_CHUNKS` ni el compactado normal a la ventana que el rescate de la Fase 3 ya conservó entera.

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

La Fase 2 está COMPLETED en `d5b97bf19dfd0c139a9c333dc644bbcb782287d6`. Un chat nuevo no la vuelve a implementar: lee Execution State y el prompt de la Fase 3.

Fase 3:

```
Repo: /Users/lahirisan/smart_deal

Commit de la Fase 1: 763db1d975ee53791762e0fd963c666c9662c927
Mensaje: Hide pins from an expired session on the home checkbox.

Commit de la Fase 2: d5b97bf19dfd0c139a9c333dc644bbcb782287d6
Mensaje: Keep a question with its own object out of the previous episode.
La Fase 2 ya está COMPLETED. No la reabras. No implementes la Fase 1 ni la Fase 2 otra vez.

El chat no es la memoria. Antes de codear:
1. Lee docs/PLAN_FIX_RETRIEVAL_PIN_Y_CONTINUIDAD_2026-09-28.md, incluida Execution State.
2. git status
3. git log -1 y los commits de Fase 1 y Fase 2 anotados arriba. La Fase 2 es ancestro de HEAD.
4. Lee este prompt. Si un mensaje viejo contradice el repo o el plan, ganan repo y plan.

Implementa SOLO la Fase 3. No implementes la Fase 4. No deploy. No SSH. No Kamal remoto. No AWS remoto. No browser. No logs remotos.

Hallazgos materiales de la Fase 2, ya en el repo:
- self_contained? cede solo ante una pregunta explícita con designador (names_equipment?) o 6+ palabras cuando los únicos marcadores que quedan son "esta"/"este" ya normalizados (incluye "está"). No corre si el turno crudo matchea RagRetrievalProfile#safety_critical_query?. No se copió SAFETY_CRITICAL_PATTERNS dentro de ActiveEpisodeTurn.
- FOLLOWUP_START_RE y "la misma" / "el mismo" / "lo mismo" siguen ganando. "eso" y el resto de FOLLOWUP_RE (esa, ese, esto, ahi, same, that, this, it) no se relajan. followup_marker? sigue decidiendo los turnos cortos.
- "Tengo encendida la luz H4. ¿Qué me está indicando?" y "¿Qué temporizadores tiene este tablero y cómo están configurados?" quedan continued_self_contained, composed nil, y reemplazan el goal. El texto efectivo es el turno crudo. No arrastran HIDRA/TPR60 ni el goal del presostato.
- "¿Y para BAJA cuál es el relé?", "la misma falla", "¿Cómo soluciono eso si ya cambié la placa?" y "¿Cómo reseteo esta falla si ya cambié el fusible?" siguen continued_elliptical y componen el goal vigente. "este defecto" también, porque defecto ya es safety_critical_query?.
- identity_items ya no añade identifiers source=user que no estén en el texto del goal vigente. Fabricante, modelo y código de falla siguen componiéndose. Los identifiers históricos siguen guardados en el episodio; no entran al texto de retrieval.
- "Edel-k2" después de "EDEL K2 cerrojos exteriores" sigue continued_elliptical. El composed es ese goal (K2 y cerrojos) más el turno. No añade EM2000, DL4, CTA ni ALJO.
- Un turno elíptico todavía llega compuesto. Ese composed no es la fuente del rescate. Si el turno es self-contained y el designador no está en la primera ventana, el segundo retrieve usa el tramo de designadores, no la repetición del turno. Si es un follow-up elíptico válido, usa el goal vigente más el turno crudo. "Edel-k2" después de "EDEL K2 cerrojos exteriores" conserva "cerrojos exteriores" y no reintroduce EM2000, DL4, CTA ni ALJO.

Objetivo único: con un solo documento pineado, como máximo un retrieve_chunks adicional, dentro de esas mismas URI, antes de generar. Dos caminos de la misma clase. Ningún if por Seguridad, Micro, Llamada, H4 ni por número de hoja.

No subas PINNED_DOCUMENT_RESULTS. No reintentes en el corpus abierto. No enganches el rescate al Sorry de BedrockRagService#query: retrieve_and_generate ya generó, y una ventana incorrecta pero no vacía nunca pasa por localized_pinned_no_results.

Dueño: Rag::StructuredEvidenceRoute#execute, que ya separa retrieve_chunks de @generator.query. QueryOrchestratorService no gana una rama nueva: sigue entrando por StructuredEvidenceRoute.build. Ampliar eligible? es lo que saca estas preguntas de BedrockRagService#query. El segundo retrieve_chunks ocurre en execute, sobre el resultado del primero, y el conjunto fusionado entra a complete_from_retrieval. Ese método sigue sin recuperar: lo usan AmbiguousModelResponder y ContextEvidenceRoute, que ya gastaron su retrieve. Si RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED está apagado, no hay rescate; en config/deploy.yml ya está "true". No añadas otro flag.

Flujo:
pregunta
  → retrieve inicial, mismas URI, force_entity_filter
  → ¿el designador está en la ventana, o ya hay una fila explícita que coincide?
  → si no, como máximo un retrieve más, mismas URI
  → merge por chunk_sha256 (el mismo uniq que expand_dividers)
  → select_generation_chunks
  → generación

Un miss del segundo retrieve no dispara un tercero ni cae a BedrockRagService#query. Si el merge viene vacío, vale la abstención que la ruta ya tiene. Si viene con chunks que no cubren, se genera sobre ese merge; no se fabrica otro Sorry.

Presupuesto:
- Pregunta que ya era elegible hoy: el primer retrieve sigue en STRUCTURED_MAPPING_RESULTS (12).
- Pregunta elegible solo por este rescate: el primer retrieve usa RagRetrievalProfile#number_of_results (3, o 5 si es safety-critical). No 12.
- El retrieve adicional, en los dos caminos, pide PINNED_DOCUMENT_RESULTS (3), las mismas entity_s3_uris y force_entity_filter: true.
- El pin tiene que ser uno (entity_s3_uris únicas == 1), el mismo conteo que ya usa pinned_exact_designator_lookup?. Cero pines o dos pines: sin rescate.

QueryEntities, case-insensitive estrecho. identifier_candidate? hoy exige IDENTIFIER_SHAPE sobre el token crudo, y esa forma exige mayúsculas.
- Un token mixto o en minúsculas entra solo si, además, tiene un dígito o un separador de los que la forma ya admite (-, ., _). Edel-k2 → EDELK2, em4000 → EM4000, t1 → T1, h4 → H4. shape_of y canonical_of se calculan sobre el fold en mayúsculas; el raw no se reescribe para mostrarlo.
- Ese fold no convierte unidades ni ordinales en identifiers. Rechaza 24v, 220v, 10a, 1er, 2do. La forma, ya en mayúsculas, es dígitos seguidos de un sufijo corto de unidad u ordinal (V, A, ER, DO). No hace falta un diccionario de palabras. t1 y h4 siguen entrando: la letra va delante del dígito. em4000 y Edel-k2 también.
- Un token solo alfabético conserva la regla actual: el crudo ya tiene que cumplir IDENTIFIER_SHAPE. SCI y OUT en mayúsculas siguen contando. sci, out, seguridad, falla, tabla no. Una palabra normal no se vuelve identifier por pasar a mayúsculas.
- Un número suelto sigue fuera salvo el contexto etiquetado que ya existe (shape == :numeric && position == :bare se descarta). El dígito que autoriza el fold no salta esa regla. 24 y 41 solos no son identifiers; borne 24 sí.
- Un alfabético puro no es designador de rescate. El designador del camino (a) es RagRetrievalProfile#designator?: shape distinto de :numeric y canonical con dígito. OUT, IN y SCI no abren ese camino y no lo bloquean. MR08 sí lo abre, y con él entra el oráculo SCI.

Camino (a) — designador exacto, intención vigente + designador, primera ventana completa:
- Entra si la pregunta tiene al menos un designador con dígito, aunque sea safety-critical. Esa es la única excepción a eligible?'s !safety_critical_query?. pinned_exact_designator_lookup? no se reescribe: otros llamadores siguen viéndolo en false cuando hay falla. Sin designador con dígito, el tope 5 actual se queda y este camino no corre.
- Después del primer retrieve, si ningún chunk cumple QueryEntities.identifier_present? para ese designador, un solo retrieve_chunks más.
- El primer retrieve usa la pregunta vigente. El segundo no la repite. En un self-contained el segundo texto es el tramo de designadores: "EDEL K2 dos embarques" reintenta "EDEL K2"; "luz H4" reintenta "H4"; "SCI del MR08" conserva SCI. El probe midió que repetir el turno devuelve el mismo top-3.
- Follow-up elíptico válido: el segundo texto es el goal vigente más el turno crudo. "Edel-k2" después de "EDEL K2 cerrojos exteriores" conserva "cerrojos exteriores". No añadas identifiers históricos del episodio que no estén ya en ese goal. No uses el composed del episodio como fuente directa.
- Hoy StructuredEvidenceRoute recibe @query, que puede ser ya el effective_question compuesto. El turno crudo entra como argumento cuando @query no es ese turno. El goal se lee de episode.goal, no del composed. Eso no abre una rama nueva en QueryOrchestratorService. Si el primero ya contiene el designador, no hay segundo retrieve.
- La generación recibe la primera ventana completa más los chunks rescatados, únicos por chunk_sha256 (el mismo uniq que expand_dividers). No recortes esa evidencia a los chunks que contienen el designador. El cover greedy de select_generation_chunks no es, en este rescate, el filtro que tira el resto de la primera ventana. MAX_GENERATION_CHUNKS (5) no autoriza a dejar fuera esa ventana: se conserva entera y se le agregan los rescatados que no estaban. Un miss del segundo retrieve no dispara un tercero.

Camino (b) — mapping estrecho, sin designador con dígito:
- Entra solo si el camino (a) no entró, el pin es un documento, y la pregunta pide conexión, localización o asignación con una señal explícita de lookup que ya existe. No añadas una clave a RELATION_TRIGGERS. requested_relation solo no alcanza, ni en :location, ni en :connection, ni en :attribution.
- Hacen falta las dos cosas: requested_relation corta :connection, :location o :attribution, y además matchea BORNE_TERMINAL_PATTERN, label_terms? o EXACT_LOOKUP_PATTERN.
- Una pregunta normal de manual que solo dispara "dónde" o "conector" no abre el segundo retrieve. No entra si safety_critical_query?, exhaustive_query? o COMPARATIVE_PATTERN. "¿A qué borne corresponde Seguridad OUT?" entra: borne es BORNE_TERMINAL_PATTERN y corresponde corta :attribution. "Micro nivel inferior" a secas, sin borne / label / lookup, no entra. No escribas reglas para Seguridad, Micro, Llamada ni H4.
- Después del primer retrieve, si ningún chunk trae una fila de tabla con solape real, un solo retrieve_chunks más. Una fila es "| celda | celda |" o "TOKEN | resto". SOURCE_SECTION, un margen y una nota no cuentan. El solape exige el ancla (inferior, superior, llamada, seguridad, presostato) y, si hay un token corto en mayúsculas (OUT, IN), ese token. Si la pregunta pide un borne, la fila tiene que traer un número. "nivel" o "seguridad" solos no tapan el rescate.
- El segundo texto es la frase pedida, sin el marco "¿A qué borne corresponde". El probe midió que concatenar "tabla designacion" a "llamada nivel 1" saca la hoja 2 del top-3, y que "micro de nivel inferior", "llamada de nivel 1" y "Seguridad OUT" sí la traen. OUT, IN y nivel 1 siguen en esa frase.
- Si el primer retrieve ya trae esa fila, no hay segundo.
- Selección, cuando no hay identifier que cubrir: hoy select_generation_chunks devuelve chunks.first(PINNED_DOCUMENT_RESULTS) en cuanto covering está vacío. En este camino eso no alcanza. Se prefiere el chunk con una fila explícita — las formas que assignment_line? ya reconoce, o una fila de tabla — y solape léxico con la pregunta. Un token de 2 o 3 letras entra en ese solape solo si va en mayúsculas o tiene dígito, para que OUT no empate con IN por la sola palabra "seguridad". Un número junto a un rótulo, sin fila, no gana por eso. Si ninguna fila explícita solapa, se conserva el fallback de los primeros 3.

Fixture real de chunk_p1_2. Fuente local: tmp/elemont_patch_2026-09-23/chunk_p1_2_current.txt. No es un esquema con números sueltos junto al rótulo. La bornera está en filas explícitas, y los FIELD_RECORD las repiten:
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
El mismo objeto dice H4 como lámpara vinculada a K5 y K7, y T1 / T2 como transformadores (220VAC/18VCD y 220VAC/24VAC), no como temporizadores. Un rescate que se salta el segundo retrieve en cuanto el token ya está en la primera ventana deja esa lectura como si cubriera el hecho. El probe de la sección 10 lo dice. No añadas un if por H4, T1 ni T2.

Tests con fake de retrieve_chunks, no con un chunk bueno inyectado al selector. La pregunta es textual. No llames a Bedrock.

Preguntas canónicas. La intención sale de borne y corresponde, que ya están en RELATION_TRIGGERS. Los nombres van en la pregunta del test, no en código:
- "¿A qué borne corresponde Seguridad OUT?"
- "¿A qué borne corresponde Seguridad IN?"
- "¿A qué borne corresponde el micro de nivel inferior?"
- "¿A qué borne corresponde el micro de nivel superior?"
- "¿A qué borne corresponde la llamada de nivel 1?"
- "¿A qué borne corresponde la llamada de nivel 2?"

Seguridad OUT, Seguridad IN y presostato: el primer retorno es el extracto real de chunk_p1_2 (filas explícitas 12/13, 22/23, 14/15, 24/25), o un fixture que lo copie. El chunk ya trae fila explícita con solape (SEGURIDAD OUT, SEGURIDAD IN, PRESOSTATO). Si el rescate de mapping no dispara, afirma una sola llamada y la fila que el chunk sí publica. No cambies el primer retorno por "un número junto a un rótulo" para forzar el segundo retrieve ni para afirmar 23, 24, 25 o 26. Esos casos dependen de la Fase 5. Dos filas explícitas incompatibles no se descartan aquí; eso es la Fase 4.

Micros y llamadas: el mismo archivo ya tiene | 26 | LIMITE INFERIOR |, | 27 | LIMITE SUPERIOR |, | 31 | LLAMADA NIVEL 1 |, | 32 | LLAMADA NIVEL 2 |. Si el primer retorno es ese chunk y el solape léxico ya cuenta, no fuerces el segundo retrieve y documenta la dependencia de la Fase 5. Si "micro" no solapa con LIMITE, el camino (b) sí puede pedir el segundo retrieve; el segundo retorno puede traer la tabla de la hoja 2. El primer retorno no se sustituye por un fake de proximidad.

Donde el primer retorno no trae fila explícita con solape, afirma:
1. build devuelve ruta con el flag en true y un solo pin; con el flag en false, o con cero o dos pines, devuelve nil.
2. retrieve_chunks se llama dos veces, nunca tres.
3. El segundo texto es la pregunta más tabla y designacion, y contiene la frase propia (nivel inferior, nivel superior, nivel 1, nivel 2 cuando esas preguntas sí reintentan). No es una lista fija de etiquetas.
4. Las dos llamadas llevan las mismas entity_s3_uris del pin y force_entity_filter: true. number_of_results del segundo es 3.
5. Si los dos retornos comparten un chunk_sha256, el merge lo deja una vez.
6. Los chunks finales son la primera ventana completa más los rescatados.
7. El hecho de la hoja 2 se afirma solo si el segundo retorno lo trajo. No se afirma 23/24/25/26 contra el extracto real de chunk_p1_2.

Además:
- Pregunta normal de manual que solo corta :location o :connection, sin BORNE_TERMINAL_PATTERN, label_terms? ni EXACT_LOOKUP_PATTERN: una llamada. "¿Qué elementos aparecen en esa línea?" sigue en una llamada.
- Cadena de seguridad, redactada sin borne / label / lookup: una llamada. Foso, igual: una llamada.
- Designador presente en la primera ventana ("¿Qué es H4?" y un chunk con H4): una llamada. En un self-contained cuyo primer retrieve no trae el designador, el segundo texto es el tramo de designadores, no la repetición del turno. En un elíptico válido contiene el goal vigente y el turno crudo, no el composed ni identifiers históricos fuera de ese goal.
- Designador ausente (EM4000 V1 obstáculo, EDEL K2 cerrojos exteriores, EDEL K2 dos embarques, MR08 serie SCI): dos llamadas como máximo. El segundo texto del self-contained es el tramo de designadores (EM4000 V1, EDEL K2, SCI del MR08, H4), no la repetición del turno. Un follow-up elíptico "Edel-k2" conserva el goal vigente "cerrojos exteriores". Si el segundo tampoco trae el designador, siguen siendo dos. La generación ve la primera ventana completa y los chunks rescatados.
- Mapping sin identifier: como máximo un reintento, y solo con la señal explícita de lookup. Si el segundo tampoco trae fila explícita, siguen siendo dos y no hay caída a BedrockRagService#query.
- PINNED_DOCUMENT_RESULTS sigue en 3. El test de RagRetrievalProfile que lo fija no se toca.
- QueryEntities: acepta Edel-k2, em4000, t1, h4. Rechaza 24v, 220v, 10a, 1er, 2do, seguridad, falla, tabla, out en minúsculas, y 24 suelto. SCI y OUT en mayúsculas siguen el criterio alfabético actual. borne 24 sigue siendo identifier etiquetado.

Los oráculos 1–6, 13 y 14 de la sección 9 usan el doble fake cuando el designador no está en el primer retorno: el chunk final contiene el hecho y también el resto de la primera ventana. No se llama a Bedrock. El assert no es "el modelo redactó esta frase". Si el primer retorno ya contiene el token (H4, T1, T2 dentro de chunk_p1_2) y por eso no hay segundo retrieve, el test no inventa un primer retorno vacío para hacer pasar el hecho. El probe read-only decide si la Fase 3 queda BLOCKED.

Archivos: app/services/rag/query_entities.rb, app/services/rag/structured_evidence_route.rb, test/services/rag/query_entities_test.rb, test/services/rag/structured_evidence_route_test.rb. app/services/query_orchestrator_service.rb solo si algún test con el flag en true espera build nil para una pregunta de un solo pin que ahora es elegible; el caso flag false sigue en nil. No toques el Sorry de app/services/bedrock_rag_service.rb. No toques ActiveEpisodeTurn, generation.txt, PINNED_DOCUMENT_RESULTS ni el checkbox de la Fase 1.

Probe read-only, obligatorio antes de marcar la Fase 3 COMPLETED. Cuando la Fase 3 está implementada, un script en script/ — al estilo de script/rag_seguridades_recall_probe.rb, que solo llama retrieve_chunks — corre el retrieval real de estos 14 casos, con el mismo pin y la misma decisión de rescate que usaría la ruta. No es un paso opcional y no se sustituye por los fakes de minitest.
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
- Read-only. Sin generación, sin escritura, sin deploy. No escribe S3, no ingesta, no toca producción, no llama a BedrockRagService#query ni a @generator.query.
- Cada caso tiene que recuperar evidencia suficiente del hecho de la sección 9. Ver las filas explícitas de chunk_p1_2 no cuenta como evidencia suficiente de la hoja 2.
- Sale 0 solo si los 14 recuperaron esa evidencia. Sale 1 si falta alguno. No pide interpretación y no se maquilla un caso faltante.
- No entra en CI. Sí bloquea marcar la Fase 3 como COMPLETED. Con el probe en rojo el estado es BLOCKED. No se deploya la fase como cerrada.

No marques la Fase 3 COMPLETED sin ese probe en verde. Si un caso esperado no recupera evidencia suficiente, el estado es BLOCKED. No maquilles el probe. Si los tests y el probe pasan: commit, marca Fase 3 COMPLETED en Execution State, registra findings materiales, reescribe el prompt de Fase 4 para un chat nuevo. DETENTE. No implementes la Fase 4.
```
Fase 4:

La Fase 4 está COMPLETED en el commit cuyo mensaje es `Leave two incompatible assignment rows unresolved in generation.` Un chat nuevo no la vuelve a implementar: lee Execution State y el prompt de la Fase 5.

Fase 5:

La Fase 5 está COMPLETED. Un chat nuevo no la vuelve a implementar: lee Execution State. No hay Fase 6.

```
Repo: /Users/lahirisan/smart_deal

Commit de la Fase 1: 763db1d975ee53791762e0fd963c666c9662c927
Mensaje: Hide pins from an expired session on the home checkbox.

Commit de la Fase 2: d5b97bf19dfd0c139a9c333dc644bbcb782287d6
Mensaje: Keep a question with its own object out of the previous episode.

Commit de la Fase 3: 68365a981dc3830237c7cc672cd5129d0081324e
Mensaje: Rescue a missed designator or borne row inside the pinned document.

Commit de la Fase 4: el commit con mensaje
"Leave two incompatible assignment rows unresolved in generation."
Confírmalo con git log -1 --format='%H %s'. La Fase 4 es ancestro de HEAD.
Las fases 1–4 están COMPLETED. La Fase 3 no está BLOCKED. No las reabras.

El chat no es la memoria. Antes de codear:
1. Lee docs/PLAN_FIX_RETRIEVAL_PIN_Y_CONTINUIDAD_2026-09-28.md, incluida Execution State y las aclaraciones fijadas antes de la Fase 4.
2. git status
3. git log -1 y los commits de las fases 1–4.
4. Lee este prompt. Si un mensaje viejo contradice el repo o el plan, ganan repo y plan.

Implementa SOLO la Fase 5. No reimplementes la Fase 4. No cambies generation.txt, StructuredEvidenceRoute, QueryEntities, SourceFidelityGuard, retrieval ni PINNED_DOCUMENT_RESULTS. No añadas una llamada LLM. No toques la ventana de rescate: cuando hay rescate, la primera ventana completa más los chunks rescatados sigue entera.

Hallazgos de la Fase 4 que no hay que deshacer:
- El bloque de generation.txt que empieza por "When two retrieved fragments conflict" ya distingue una fila explícita de un número suelto o dibujado junto a un rótulo. La fila explícita tiene más autoridad que esa proximidad. Dos filas explícitas incompatibles siguen sin resolverse: se citan las dos y no se elige. No dice que la tabla gana siempre.
- Esa regla no sustituye un procedimiento ya documentado. Cadena de seguridad, foso y K1/K2 no se reescribieron.
- El prompt grounded quedó en 1,043× el anterior, bajo 1,05×.
- Una fila explícita con solape puede haber tapado el rescate aunque la fila sea falsa. Eso no se corrigió en la Fase 3 ni en la Fase 4. Corregir o remover esas filas del chunk de origen es esta fase.

Objetivo único: chunk_p1_2.txt deja de afirmar bornes que la hoja 2 desmiente.

La fuente local tmp/elemont_patch_2026-09-23/chunk_p1_2_current.txt publica filas explícitas, no números junto a rótulos. El probe de la Fase 3 ya vio el conflicto hoja 1 / hoja 2:
- Seguridad: hoja 1 | 13 | SEGURIDAD OUT | y | 22 | SEGURIDAD OUT | frente a hoja 2 | 23 | Seguridad OUT |. IN: 12/23 frente a 24.
- Micros: hoja 1 | 26 | LIMITE INFERIOR | y | 27 | LIMITE SUPERIOR | frente a hoja 2 | 30 | Micro nivel inferior | y | 31 | Micro nivel superior |.
- Llamadas: hoja 1 | 31 | LLAMADA NIVEL 1 | y | 32 | LLAMADA NIVEL 2 | frente a hoja 2 | 33 | Llamada nivel 1 | y | 34 | Llamada nivel 2 |.
- Presostato, en el mismo chunk: | 14 | PRESOSTATO IN |, | 15 | PRESOSTATO OUT |, | 24 | PRESOSTATO IN |, | 25 | PRESOSTATO OUT |, más los FIELD_RECORD que las repiten.

Lee la hoja 2 antes de escribir. Solo se reescriben las filas explícitas de chunk_p1_2 que contradicen esa tabla, incluidos 22/23 y 24/25, no solo 12–15. Llamadas 31/32 y límites 26/27 se reescriben solo si contradicen la hoja 2. El reemplazo es la remisión a la hoja 2, no una bornera nueva. No inventes otros bornes.

- Script al estilo script/patch_elemont_chunk_p1_2_2026-09-23.rb.
- Comprueba el SHA vivo antes de subir. Si no coincide, no subas. Guarda el objeto anterior. Rollback = re-subir ese objeto.
- Escribe por S3DocumentsService para que SectionNeighborExpander.invalidate! corra.
- No cambies código de retrieve. No despliegues la aplicación. No lo mezcles con las fases 1–4.

Al terminar: commit de la Fase 5, marca Fase 5 COMPLETED en Execution State, registra solo findings materiales. DETENTE.
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
- La Fase 2 no tocó el pin ni el retrieve. Ya está COMPLETED. El prompt vigente es el de Phase 2.
Next phase prompt:
```text
La Fase 2 está COMPLETED en d5b97bf19dfd0c139a9c333dc644bbcb782287d6.
No la reimplementes. El prompt vigente es Phase 2 → Next phase prompt, y el mismo texto está en la sección 15 bajo Fase 3.
```

### Phase 2
Status: COMPLETED
Commit: d5b97bf19dfd0c139a9c333dc644bbcb782287d6
Tests: PASS
Material findings:
- `self_contained?` cede solo ante una pregunta explícita con designador o 6+ palabras cuando los únicos marcadores que quedan son `esta`/`este` ya normalizados. No corre si el turno crudo matchea `RagRetrievalProfile#safety_critical_query?`. `FOLLOWUP_START_RE` y `la misma` / `el mismo` / `lo mismo` siguen ganando. `eso` y el resto de `FOLLOWUP_RE` no se relajan. `followup_marker?` sigue en los turnos cortos. No se copió `SAFETY_CRITICAL_PATTERNS`.
- H4 y temporizadores quedan `continued_self_contained`, `composed` nil, y reemplazan el goal. El texto efectivo es el turno crudo.
- BAJA, `la misma falla`, `eso` y `esta falla` / `este defecto` siguen `continued_elliptical` y componen el goal vigente.
- `identity_items` ya no añade identifiers `source=user` que no estén en el texto del goal vigente. Fabricante, modelo y código de falla siguen. Los identifiers históricos permanecen guardados. `Edel-k2` después de `EDEL K2 cerrojos exteriores` compone K2 y cerrojos, sin EM2000, DL4, CTA ni ALJO.
- Suite: `BUNDLE_PATH=vendor/bundle bin/rails test test/services/rag/active_episode_turn_test.rb` — 114 runs, 602 assertions, 0 failures. Sin Bedrock.
- Suite de episodios en el concern: `BUNDLE_PATH=vendor/bundle bin/rails test test/controllers/concerns/rag_query_concern_test.rb -n "/episode|composed|follow-up|followup|ActiveEpisode|field companion|turn flag/"` — 18 runs, 471 assertions, 0 failures, 1 skip. El skip es el test previo de WhatsApp `whatsapp short follow-up keeps cached locale`, que el filtro nombró por `follow-up`.
Next phase impact:
- Un turno self-contained llega con `composed` nil. Un turno elíptico sigue compuesto con el goal vigente, sin identifiers históricos fuera de ese goal. El rescate self-contained usa el turno crudo más el designador. El rescate elíptico usa ese goal vigente más el turno crudo más el designador, no el composed: en `Edel-k2` se conserva `cerrojos exteriores` y no entran EM2000, DL4, CTA ni ALJO.
Next phase prompt:
```text
Repo: /Users/lahirisan/smart_deal

Commit de la Fase 1: 763db1d975ee53791762e0fd963c666c9662c927
Mensaje: Hide pins from an expired session on the home checkbox.

Commit de la Fase 2: d5b97bf19dfd0c139a9c333dc644bbcb782287d6
Mensaje: Keep a question with its own object out of the previous episode.
La Fase 2 ya está COMPLETED. No la reabras. No implementes la Fase 1 ni la Fase 2 otra vez.

El chat no es la memoria. Antes de codear:
1. Lee docs/PLAN_FIX_RETRIEVAL_PIN_Y_CONTINUIDAD_2026-09-28.md, incluida Execution State.
2. git status
3. git log -1 y los commits de Fase 1 y Fase 2 anotados arriba. La Fase 2 es ancestro de HEAD.
4. Lee este prompt. Si un mensaje viejo contradice el repo o el plan, ganan repo y plan.

Implementa SOLO la Fase 3. No implementes la Fase 4. No deploy. No SSH. No Kamal remoto. No AWS remoto. No browser. No logs remotos.

Hallazgos materiales de la Fase 2, ya en el repo:
- self_contained? cede solo ante una pregunta explícita con designador (names_equipment?) o 6+ palabras cuando los únicos marcadores que quedan son "esta"/"este" ya normalizados (incluye "está"). No corre si el turno crudo matchea RagRetrievalProfile#safety_critical_query?. No se copió SAFETY_CRITICAL_PATTERNS dentro de ActiveEpisodeTurn.
- FOLLOWUP_START_RE y "la misma" / "el mismo" / "lo mismo" siguen ganando. "eso" y el resto de FOLLOWUP_RE (esa, ese, esto, ahi, same, that, this, it) no se relajan. followup_marker? sigue decidiendo los turnos cortos.
- "Tengo encendida la luz H4. ¿Qué me está indicando?" y "¿Qué temporizadores tiene este tablero y cómo están configurados?" quedan continued_self_contained, composed nil, y reemplazan el goal. El texto efectivo es el turno crudo. No arrastran HIDRA/TPR60 ni el goal del presostato.
- "¿Y para BAJA cuál es el relé?", "la misma falla", "¿Cómo soluciono eso si ya cambié la placa?" y "¿Cómo reseteo esta falla si ya cambié el fusible?" siguen continued_elliptical y componen el goal vigente. "este defecto" también, porque defecto ya es safety_critical_query?.
- identity_items ya no añade identifiers source=user que no estén en el texto del goal vigente. Fabricante, modelo y código de falla siguen componiéndose. Los identifiers históricos siguen guardados en el episodio; no entran al texto de retrieval.
- "Edel-k2" después de "EDEL K2 cerrojos exteriores" sigue continued_elliptical. El composed es ese goal (K2 y cerrojos) más el turno. No añade EM2000, DL4, CTA ni ALJO.
- Un turno elíptico todavía llega compuesto. Ese composed no es la fuente del rescate. Si el turno es self-contained y el designador no está en la primera ventana, el segundo retrieve usa el tramo de designadores, no la repetición del turno. Si es un follow-up elíptico válido, usa el goal vigente más el turno crudo. "Edel-k2" después de "EDEL K2 cerrojos exteriores" conserva "cerrojos exteriores" y no reintroduce EM2000, DL4, CTA ni ALJO.

Objetivo único: con un solo documento pineado, como máximo un retrieve_chunks adicional, dentro de esas mismas URI, antes de generar. Dos caminos de la misma clase. Ningún if por Seguridad, Micro, Llamada, H4 ni por número de hoja.

No subas PINNED_DOCUMENT_RESULTS. No reintentes en el corpus abierto. No enganches el rescate al Sorry de BedrockRagService#query: retrieve_and_generate ya generó, y una ventana incorrecta pero no vacía nunca pasa por localized_pinned_no_results.

Dueño: Rag::StructuredEvidenceRoute#execute, que ya separa retrieve_chunks de @generator.query. QueryOrchestratorService no gana una rama nueva: sigue entrando por StructuredEvidenceRoute.build. Ampliar eligible? es lo que saca estas preguntas de BedrockRagService#query. El segundo retrieve_chunks ocurre en execute, sobre el resultado del primero, y el conjunto fusionado entra a complete_from_retrieval. Ese método sigue sin recuperar: lo usan AmbiguousModelResponder y ContextEvidenceRoute, que ya gastaron su retrieve. Si RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED está apagado, no hay rescate; en config/deploy.yml ya está "true". No añadas otro flag.

Flujo:
pregunta
  → retrieve inicial, mismas URI, force_entity_filter
  → ¿el designador está en la ventana, o ya hay una fila explícita que coincide?
  → si no, como máximo un retrieve más, mismas URI
  → merge por chunk_sha256 (el mismo uniq que expand_dividers)
  → select_generation_chunks
  → generación

Un miss del segundo retrieve no dispara un tercero ni cae a BedrockRagService#query. Si el merge viene vacío, vale la abstención que la ruta ya tiene. Si viene con chunks que no cubren, se genera sobre ese merge; no se fabrica otro Sorry.

Presupuesto:
- Pregunta que ya era elegible hoy: el primer retrieve sigue en STRUCTURED_MAPPING_RESULTS (12).
- Pregunta elegible solo por este rescate: el primer retrieve usa RagRetrievalProfile#number_of_results (3, o 5 si es safety-critical). No 12.
- El retrieve adicional, en los dos caminos, pide PINNED_DOCUMENT_RESULTS (3), las mismas entity_s3_uris y force_entity_filter: true.
- El pin tiene que ser uno (entity_s3_uris únicas == 1), el mismo conteo que ya usa pinned_exact_designator_lookup?. Cero pines o dos pines: sin rescate.

QueryEntities, case-insensitive estrecho. identifier_candidate? hoy exige IDENTIFIER_SHAPE sobre el token crudo, y esa forma exige mayúsculas.
- Un token mixto o en minúsculas entra solo si, además, tiene un dígito o un separador de los que la forma ya admite (-, ., _). Edel-k2 → EDELK2, em4000 → EM4000, t1 → T1, h4 → H4. shape_of y canonical_of se calculan sobre el fold en mayúsculas; el raw no se reescribe para mostrarlo.
- Ese fold no convierte unidades ni ordinales en identifiers. Rechaza 24v, 220v, 10a, 1er, 2do. La forma, ya en mayúsculas, es dígitos seguidos de un sufijo corto de unidad u ordinal (V, A, ER, DO). No hace falta un diccionario de palabras. t1 y h4 siguen entrando: la letra va delante del dígito. em4000 y Edel-k2 también.
- Un token solo alfabético conserva la regla actual: el crudo ya tiene que cumplir IDENTIFIER_SHAPE. SCI y OUT en mayúsculas siguen contando. sci, out, seguridad, falla, tabla no. Una palabra normal no se vuelve identifier por pasar a mayúsculas.
- Un número suelto sigue fuera salvo el contexto etiquetado que ya existe (shape == :numeric && position == :bare se descarta). El dígito que autoriza el fold no salta esa regla. 24 y 41 solos no son identifiers; borne 24 sí.
- Un alfabético puro no es designador de rescate. El designador del camino (a) es RagRetrievalProfile#designator?: shape distinto de :numeric y canonical con dígito. OUT, IN y SCI no abren ese camino y no lo bloquean. MR08 sí lo abre, y con él entra el oráculo SCI.

Camino (a) — designador exacto, intención vigente + designador, primera ventana completa:
- Entra si la pregunta tiene al menos un designador con dígito, aunque sea safety-critical. Esa es la única excepción a eligible?'s !safety_critical_query?. pinned_exact_designator_lookup? no se reescribe: otros llamadores siguen viéndolo en false cuando hay falla. Sin designador con dígito, el tope 5 actual se queda y este camino no corre.
- Después del primer retrieve, si ningún chunk cumple QueryEntities.identifier_present? para ese designador, un solo retrieve_chunks más.
- El primer retrieve usa la pregunta vigente. El segundo no la repite. En un self-contained el segundo texto es el tramo de designadores: "EDEL K2 dos embarques" reintenta "EDEL K2"; "luz H4" reintenta "H4"; "SCI del MR08" conserva SCI. El probe midió que repetir el turno devuelve el mismo top-3.
- Follow-up elíptico válido: el segundo texto es el goal vigente más el turno crudo. "Edel-k2" después de "EDEL K2 cerrojos exteriores" conserva "cerrojos exteriores". No añadas identifiers históricos del episodio que no estén ya en ese goal. No uses el composed del episodio como fuente directa.
- Hoy StructuredEvidenceRoute recibe @query, que puede ser ya el effective_question compuesto. El turno crudo entra como argumento cuando @query no es ese turno. El goal se lee de episode.goal, no del composed. Eso no abre una rama nueva en QueryOrchestratorService. Si el primero ya contiene el designador, no hay segundo retrieve.
- La generación recibe la primera ventana completa más los chunks rescatados, únicos por chunk_sha256 (el mismo uniq que expand_dividers). No recortes esa evidencia a los chunks que contienen el designador. El cover greedy de select_generation_chunks no es, en este rescate, el filtro que tira el resto de la primera ventana. MAX_GENERATION_CHUNKS (5) no autoriza a dejar fuera esa ventana: se conserva entera y se le agregan los rescatados que no estaban. Un miss del segundo retrieve no dispara un tercero.

Camino (b) — mapping estrecho, sin designador con dígito:
- Entra solo si el camino (a) no entró, el pin es un documento, y la pregunta pide conexión, localización o asignación con una señal explícita de lookup que ya existe. No añadas una clave a RELATION_TRIGGERS. requested_relation solo no alcanza, ni en :location, ni en :connection, ni en :attribution.
- Hacen falta las dos cosas: requested_relation corta :connection, :location o :attribution, y además matchea BORNE_TERMINAL_PATTERN, label_terms? o EXACT_LOOKUP_PATTERN.
- Una pregunta normal de manual que solo dispara "dónde" o "conector" no abre el segundo retrieve. No entra si safety_critical_query?, exhaustive_query? o COMPARATIVE_PATTERN. "¿A qué borne corresponde Seguridad OUT?" entra: borne es BORNE_TERMINAL_PATTERN y corresponde corta :attribution. "Micro nivel inferior" a secas, sin borne / label / lookup, no entra. No escribas reglas para Seguridad, Micro, Llamada ni H4.
- Después del primer retrieve, si ningún chunk trae una fila de tabla con solape real, un solo retrieve_chunks más. Una fila es "| celda | celda |" o "TOKEN | resto". SOURCE_SECTION, un margen y una nota no cuentan. El solape exige el ancla (inferior, superior, llamada, seguridad, presostato) y, si hay un token corto en mayúsculas (OUT, IN), ese token. Si la pregunta pide un borne, la fila tiene que traer un número. "nivel" o "seguridad" solos no tapan el rescate.
- El segundo texto es la frase pedida, sin el marco "¿A qué borne corresponde". El probe midió que concatenar "tabla designacion" a "llamada nivel 1" saca la hoja 2 del top-3, y que "micro de nivel inferior", "llamada de nivel 1" y "Seguridad OUT" sí la traen. OUT, IN y nivel 1 siguen en esa frase.
- Si el primer retrieve ya trae esa fila, no hay segundo.
- Selección, cuando no hay identifier que cubrir: hoy select_generation_chunks devuelve chunks.first(PINNED_DOCUMENT_RESULTS) en cuanto covering está vacío. En este camino eso no alcanza. Se prefiere el chunk con una fila explícita — las formas que assignment_line? ya reconoce, o una fila de tabla — y solape léxico con la pregunta. Un token de 2 o 3 letras entra en ese solape solo si va en mayúsculas o tiene dígito, para que OUT no empate con IN por la sola palabra "seguridad". Un número junto a un rótulo, sin fila, no gana por eso. Si ninguna fila explícita solapa, se conserva el fallback de los primeros 3.

Fixture real de chunk_p1_2. Fuente local: tmp/elemont_patch_2026-09-23/chunk_p1_2_current.txt. No es un esquema con números sueltos junto al rótulo. La bornera está en filas explícitas, y los FIELD_RECORD las repiten:
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
El mismo objeto dice H4 como lámpara vinculada a K5 y K7, y T1 / T2 como transformadores (220VAC/18VCD y 220VAC/24VAC), no como temporizadores. Un rescate que se salta el segundo retrieve en cuanto el token ya está en la primera ventana deja esa lectura como si cubriera el hecho. El probe de la sección 10 lo dice. No añadas un if por H4, T1 ni T2.

Tests con fake de retrieve_chunks, no con un chunk bueno inyectado al selector. La pregunta es textual. No llames a Bedrock.

Preguntas canónicas. La intención sale de borne y corresponde, que ya están en RELATION_TRIGGERS. Los nombres van en la pregunta del test, no en código:
- "¿A qué borne corresponde Seguridad OUT?"
- "¿A qué borne corresponde Seguridad IN?"
- "¿A qué borne corresponde el micro de nivel inferior?"
- "¿A qué borne corresponde el micro de nivel superior?"
- "¿A qué borne corresponde la llamada de nivel 1?"
- "¿A qué borne corresponde la llamada de nivel 2?"

Seguridad OUT, Seguridad IN y presostato: el primer retorno es el extracto real de chunk_p1_2 (filas explícitas 12/13, 22/23, 14/15, 24/25), o un fixture que lo copie. El chunk ya trae fila explícita con solape (SEGURIDAD OUT, SEGURIDAD IN, PRESOSTATO). Si el rescate de mapping no dispara, afirma una sola llamada y la fila que el chunk sí publica. No cambies el primer retorno por "un número junto a un rótulo" para forzar el segundo retrieve ni para afirmar 23, 24, 25 o 26. Esos casos dependen de la Fase 5. Dos filas explícitas incompatibles no se descartan aquí; eso es la Fase 4.

Micros y llamadas: el mismo archivo ya tiene | 26 | LIMITE INFERIOR |, | 27 | LIMITE SUPERIOR |, | 31 | LLAMADA NIVEL 1 |, | 32 | LLAMADA NIVEL 2 |. Si el primer retorno es ese chunk y el solape léxico ya cuenta, no fuerces el segundo retrieve y documenta la dependencia de la Fase 5. Si "micro" no solapa con LIMITE, el camino (b) sí puede pedir el segundo retrieve; el segundo retorno puede traer la tabla de la hoja 2. El primer retorno no se sustituye por un fake de proximidad.

Donde el primer retorno no trae fila explícita con solape, afirma:
1. build devuelve ruta con el flag en true y un solo pin; con el flag en false, o con cero o dos pines, devuelve nil.
2. retrieve_chunks se llama dos veces, nunca tres.
3. El segundo texto es la pregunta más tabla y designacion, y contiene la frase propia (nivel inferior, nivel superior, nivel 1, nivel 2 cuando esas preguntas sí reintentan). No es una lista fija de etiquetas.
4. Las dos llamadas llevan las mismas entity_s3_uris del pin y force_entity_filter: true. number_of_results del segundo es 3.
5. Si los dos retornos comparten un chunk_sha256, el merge lo deja una vez.
6. Los chunks finales son la primera ventana completa más los rescatados.
7. El hecho de la hoja 2 se afirma solo si el segundo retorno lo trajo. No se afirma 23/24/25/26 contra el extracto real de chunk_p1_2.

Además:
- Pregunta normal de manual que solo corta :location o :connection, sin BORNE_TERMINAL_PATTERN, label_terms? ni EXACT_LOOKUP_PATTERN: una llamada. "¿Qué elementos aparecen en esa línea?" sigue en una llamada.
- Cadena de seguridad, redactada sin borne / label / lookup: una llamada. Foso, igual: una llamada.
- Designador presente en la primera ventana ("¿Qué es H4?" y un chunk con H4): una llamada. En un self-contained cuyo primer retrieve no trae el designador, el segundo texto es el tramo de designadores, no la repetición del turno. En un elíptico válido contiene el goal vigente y el turno crudo, no el composed ni identifiers históricos fuera de ese goal.
- Designador ausente (EM4000 V1 obstáculo, EDEL K2 cerrojos exteriores, EDEL K2 dos embarques, MR08 serie SCI): dos llamadas como máximo. El segundo texto del self-contained es el tramo de designadores (EM4000 V1, EDEL K2, SCI del MR08, H4), no la repetición del turno. Un follow-up elíptico "Edel-k2" conserva el goal vigente "cerrojos exteriores". Si el segundo tampoco trae el designador, siguen siendo dos. La generación ve la primera ventana completa y los chunks rescatados.
- Mapping sin identifier: como máximo un reintento, y solo con la señal explícita de lookup. Si el segundo tampoco trae fila explícita, siguen siendo dos y no hay caída a BedrockRagService#query.
- PINNED_DOCUMENT_RESULTS sigue en 3. El test de RagRetrievalProfile que lo fija no se toca.
- QueryEntities: acepta Edel-k2, em4000, t1, h4. Rechaza 24v, 220v, 10a, 1er, 2do, seguridad, falla, tabla, out en minúsculas, y 24 suelto. SCI y OUT en mayúsculas siguen el criterio alfabético actual. borne 24 sigue siendo identifier etiquetado.

Los oráculos 1–6, 13 y 14 de la sección 9 usan el doble fake cuando el designador no está en el primer retorno: el chunk final contiene el hecho y también el resto de la primera ventana. No se llama a Bedrock. El assert no es "el modelo redactó esta frase". Si el primer retorno ya contiene el token (H4, T1, T2 dentro de chunk_p1_2) y por eso no hay segundo retrieve, el test no inventa un primer retorno vacío para hacer pasar el hecho. El probe read-only decide si la Fase 3 queda BLOCKED.

Archivos: app/services/rag/query_entities.rb, app/services/rag/structured_evidence_route.rb, test/services/rag/query_entities_test.rb, test/services/rag/structured_evidence_route_test.rb. app/services/query_orchestrator_service.rb solo si algún test con el flag en true espera build nil para una pregunta de un solo pin que ahora es elegible; el caso flag false sigue en nil. No toques el Sorry de app/services/bedrock_rag_service.rb. No toques ActiveEpisodeTurn, generation.txt, PINNED_DOCUMENT_RESULTS ni el checkbox de la Fase 1.

Probe read-only, obligatorio antes de marcar la Fase 3 COMPLETED. Cuando la Fase 3 está implementada, un script en script/ — al estilo de script/rag_seguridades_recall_probe.rb, que solo llama retrieve_chunks — corre el retrieval real de estos 14 casos, con el mismo pin y la misma decisión de rescate que usaría la ruta. No es un paso opcional y no se sustituye por los fakes de minitest.
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
- Read-only. Sin generación, sin escritura, sin deploy. No escribe S3, no ingesta, no toca producción, no llama a BedrockRagService#query ni a @generator.query.
- Cada caso tiene que recuperar evidencia suficiente del hecho de la sección 9. Ver las filas explícitas de chunk_p1_2 no cuenta como evidencia suficiente de la hoja 2.
- Sale 0 solo si los 14 recuperaron esa evidencia. Sale 1 si falta alguno. No pide interpretación y no se maquilla un caso faltante.
- No entra en CI. Sí bloquea marcar la Fase 3 como COMPLETED. Con el probe en rojo el estado es BLOCKED. No se deploya la fase como cerrada.

No marques la Fase 3 COMPLETED sin ese probe en verde. Si un caso esperado no recupera evidencia suficiente, el estado es BLOCKED. No maquilles el probe. Si los tests y el probe pasan: commit, marca Fase 3 COMPLETED en Execution State, registra findings materiales, reescribe el prompt de Fase 4 para un chat nuevo. DETENTE. No implementes la Fase 4.
```

### Phase 3
Status: COMPLETED
Commit: 68365a981dc3830237c7cc672cd5129d0081324e
Tests: PASS
Material findings:
- Probe `script/rag_pinned_rescue_probe_2026-09-28.rb` contra el KB de producción, sin generación: 14 hits, 0 phase_3_miss, 0 phase_5_dependency. Rescate en 4, 6, 9, 10, 11 y 12. El resto ya traía el hecho en la primera ventana.
- Self-contained cuyo designador no está en la primera ventana: el segundo texto es el tramo de designadores (`EDEL K2`, `H4`), no la repetición del turno. Elíptico: goal vigente más el turno crudo. `Edel-k2` conserva `cerrojos exteriores` y no reintroduce EM2000, DL4, CTA ni ALJO.
- Mapping: la fila que tapa el rescate es una fila de tabla con el ancla y, si la pregunta pide un borne, un número. El segundo texto es la frase pedida (`micro de nivel inferior`, `llamada de nivel 1`), sin `tabla designacion`.
- `chunk_p1_2` sigue publicando filas de hoja 1 que solapan. Si esa es la única ventana, no hay segundo retrieve. Cuando el rescate también trae la hoja 2, las dos filas quedan en la ventana. Elegir una es la Fase 4. Borrar la falsa es la Fase 5.
- Tests: `BUNDLE_PATH=vendor/bundle bin/rails test test/services/rag/query_entities_test.rb test/services/rag/structured_evidence_route_test.rb test/services/rag_retrieval_profile_test.rb test/services/rag/structured_evidence_route_flag_test.rb test/services/query_orchestrator_service_test.rb` — 157 runs, 867 assertions, 0 failures.
Next phase impact:
- La Fase 4 cita el conflicto hoja 1 / hoja 2. No elige. No parchea chunks.
Next phase prompt:
```text
OBSOLETO. La Fase 4 está COMPLETED. No ejecutes este prompt. El vigente es Phase 4 → Next phase prompt.
Implementa solo la Fase 4 de docs/PLAN_FIX_RETRIEVAL_PIN_Y_CONTINUIDAD_2026-09-28.md.
Antes de codear: lee el plan, Execution State, git status, el commit de la Fase 3 y este prompt.
La Fase 3 está COMPLETED. No la reimplementes. No deploy. No empieces la Fase 5.

Probe read-only 2026-09-28, script/rag_pinned_rescue_probe_2026-09-28.rb,
KB de producción, sin generación: 14/14 hits, 0 misses.
Rescate (2 retrieves, k final 3): 4 EDEL K2, 6 H4, 9 micro inferior,
10 micro superior, 11 llamada 1, 12 llamada 2.
Sin rescate, el hecho ya estaba en la primera ventana: 1 EM2000 CN7/CN8,
2 EM4000 XC4/XC7, 3 EDEL K2 LED 40 SERIE CERROJOS EXTERIORES,
5 MR08 SCI, 7 borne 23 Seguridad OUT, 8 borne 24 Seguridad IN,
13 T1 modo E < 3 min, 14 T2 modo Wu < 1 s.

La ventana recuperada puede traer a la vez las filas de la hoja 1 y las de
la hoja 2. Eso es conflicto, no una fila ganadora:
- Seguridad: hoja 1 | 13 | SEGURIDAD OUT | y | 22 | SEGURIDAD OUT |,
  hoja 2 | 23 | Seguridad OUT |. IN: 12/23 frente a 24.
- Micros: hoja 1 | 26 | LIMITE INFERIOR | y | 27 | LIMITE SUPERIOR |,
  hoja 2 | 30 | Micro nivel inferior | y | 31 | Micro nivel superior |.
- Llamadas: hoja 1 | 31 | LLAMADA NIVEL 1 | y | 32 | LLAMADA NIVEL 2 |,
  hoja 2 | 33 | Llamada nivel 1 | y | 34 | Llamada nivel 2 |.
- Presostato, en el mismo plano: | 14 | PRESOSTATO IN |, | 15 | PRESOSTATO OUT |,
  | 24 | PRESOSTATO IN |, | 25 | PRESOSTATO OUT |. No son un número junto al rótulo.
Si el primer retorno es solo chunk_p1_2, el rescate no corre: esas filas
ya solapan. La hoja 2 queda fuera hasta la Fase 5. No parchees ese chunk aquí.

Integra la excepción en el bloque de generation.txt que ya dice
"When two retrieved fragments conflict" y "Never choose one silently".
No añadas una regla que diga que la tabla gana siempre.
Un número suelto o junto a un rótulo no es una asignación explícita.
Una fila explícita borne N → función X pesa más que esa proximidad.
Dos filas explícitas incompatibles se citan las dos, con su página, y no se elige.
No añadas un post-procesador. No reescribas el resto del prompt.
Test sin modelo: el prompt contiene la excepción y conserva el conflicto sin
resolver; el fixture real de chunk_p1_2 no queda descrito como resuelto.
Si el bloque pasa de 1,05× el prompt actual, compacta dentro de la regla existente.
```

### Phase 4
Status: COMPLETED
Commit: this commit, subject `Leave two incompatible assignment rows unresolved in generation.`
Tests: PASS
Material findings:
- La excepción quedó en el bloque ya existente de `generation.txt`, sin un segundo policy. Un número suelto o dibujado junto a un rótulo no es una asignación explícita. Si la pregunta pide la asignación, la fila explícita tiene más autoridad que esa proximidad. Dos filas explícitas incompatibles, también dentro de un fragmento, siguen sin resolverse: se citan las dos y no se elige. El prompt no dice que la tabla gana siempre y no nombra Seguridad, Micro, Llamada, Presostato, H4, K1 ni K2.
- La regla no sustituye un procedimiento que el texto ya documenta. El prompt grounded pasó de 11801 a 12309 caracteres (1,043×), bajo 1,05×.
- El bloque no lleva prefijo de contrato, así que el digest estricto con el contrato parcial apagado pasó a `ba6e7e51f03c6d72e4b64b4d575baa6353be222c77845423dc79678a7ff985bc` y el del archivo a `dcd444d7c15a740e0b7dcd62998552eb9b321b19b91a294c0216cebe8a4c8359`. No se tocó `SourceFidelityGuard`, `StructuredEvidenceRoute`, `QueryEntities`, el retrieval ni la ventana de rescate. No se añadió una llamada LLM.
- Suites: `bedrock_generation_prompt` + `bedrock_rag_service_grounded_synthesis` + `followup_query_rewriter` + `structured_evidence_route` + `rag_retrieval_profile` — 172 runs, 1221 assertions, 0 failures. `query_entities` + `active_episode_turn` + `structured_evidence_route_flag` + `query_orchestrator_service` + `rag_query_concern` — 273 runs, 1545 assertions, 0 failures, 22 skips. Sin generación Bedrock.
Next phase impact:
- La Fase 5 corrige o remueve del chunk de origen las filas explícitas que contradicen la hoja 2, incluidas las que solapan bastante como para haber evitado el rescate. La Fase 4 no eligió entre ellas.
Next phase prompt:
```text
OBSOLETO. La Fase 5 está COMPLETED. No ejecutes este prompt. No hay Fase 6.
Repo: /Users/lahirisan/smart_deal

Commit de la Fase 1: 763db1d975ee53791762e0fd963c666c9662c927
Mensaje: Hide pins from an expired session on the home checkbox.

Commit de la Fase 2: d5b97bf19dfd0c139a9c333dc644bbcb782287d6
Mensaje: Keep a question with its own object out of the previous episode.

Commit de la Fase 3: 68365a981dc3830237c7cc672cd5129d0081324e
Mensaje: Rescue a missed designator or borne row inside the pinned document.

Commit de la Fase 4: el commit con mensaje
"Leave two incompatible assignment rows unresolved in generation."
Confírmalo con git log -1 --format='%H %s'. La Fase 4 es ancestro de HEAD.
Las fases 1–4 están COMPLETED. La Fase 3 no está BLOCKED. No las reabras.

El chat no es la memoria. Antes de codear:
1. Lee docs/PLAN_FIX_RETRIEVAL_PIN_Y_CONTINUIDAD_2026-09-28.md, incluida Execution State y las aclaraciones fijadas antes de la Fase 4.
2. git status
3. git log -1 y los commits de las fases 1–4.
4. Lee este prompt. Si un mensaje viejo contradice el repo o el plan, ganan repo y plan.

Implementa SOLO la Fase 5. No reimplementes la Fase 4. No cambies generation.txt, StructuredEvidenceRoute, QueryEntities, SourceFidelityGuard, retrieval ni PINNED_DOCUMENT_RESULTS. No añadas una llamada LLM. No toques la ventana de rescate: cuando hay rescate, la primera ventana completa más los chunks rescatados sigue entera.

Hallazgos de la Fase 4 que no hay que deshacer:
- El bloque de generation.txt que empieza por "When two retrieved fragments conflict" ya distingue una fila explícita de un número suelto o dibujado junto a un rótulo. La fila explícita tiene más autoridad que esa proximidad. Dos filas explícitas incompatibles siguen sin resolverse: se citan las dos y no se elige. No dice que la tabla gana siempre.
- Esa regla no sustituye un procedimiento ya documentado. Cadena de seguridad, foso y K1/K2 no se reescribieron.
- El prompt grounded quedó en 1,043× el anterior, bajo 1,05×.
- Una fila explícita con solape puede haber tapado el rescate aunque la fila sea falsa. Eso no se corrigió en la Fase 3 ni en la Fase 4. Corregir o remover esas filas del chunk de origen es esta fase.

Objetivo único: chunk_p1_2.txt deja de afirmar bornes que la hoja 2 desmiente.

La fuente local tmp/elemont_patch_2026-09-23/chunk_p1_2_current.txt publica filas explícitas, no números junto a rótulos. El probe de la Fase 3 ya vio el conflicto hoja 1 / hoja 2:
- Seguridad: hoja 1 | 13 | SEGURIDAD OUT | y | 22 | SEGURIDAD OUT | frente a hoja 2 | 23 | Seguridad OUT |. IN: 12/23 frente a 24.
- Micros: hoja 1 | 26 | LIMITE INFERIOR | y | 27 | LIMITE SUPERIOR | frente a hoja 2 | 30 | Micro nivel inferior | y | 31 | Micro nivel superior |.
- Llamadas: hoja 1 | 31 | LLAMADA NIVEL 1 | y | 32 | LLAMADA NIVEL 2 | frente a hoja 2 | 33 | Llamada nivel 1 | y | 34 | Llamada nivel 2 |.
- Presostato, en el mismo chunk: | 14 | PRESOSTATO IN |, | 15 | PRESOSTATO OUT |, | 24 | PRESOSTATO IN |, | 25 | PRESOSTATO OUT |, más los FIELD_RECORD que las repiten.

Lee la hoja 2 antes de escribir. Solo se reescriben las filas explícitas de chunk_p1_2 que contradicen esa tabla, incluidos 22/23 y 24/25, no solo 12–15. Llamadas 31/32 y límites 26/27 se reescriben solo si contradicen la hoja 2. El reemplazo es la remisión a la hoja 2, no una bornera nueva. No inventes otros bornes.

- Script al estilo script/patch_elemont_chunk_p1_2_2026-09-23.rb.
- Comprueba el SHA vivo antes de subir. Si no coincide, no subas. Guarda el objeto anterior. Rollback = re-subir ese objeto.
- Escribe por S3DocumentsService para que SectionNeighborExpander.invalidate! corra.
- No cambies código de retrieve. No despliegues la aplicación. No lo mezcles con las fases 1–4.

Al terminar: commit de la Fase 5, marca Fase 5 COMPLETED en Execution State, registra solo findings materiales. DETENTE.
```

### Phase 5
Status: COMPLETED
Commit: this commit, subject `Refer contradicted Elemont MH sheet-1 bornera rows to sheet 2.`
Tests: PASS
Material findings:
- Objeto: `bulk_chunks/1/121bfffe0827f6bc681ba9bdc91050390055/chunk_p1_2.txt`. SHA vivo antes de escribir: `688a5d780eef8845c489af53f186d275a3a1cc7a4b35f42b38cc2d53be03776c` (el activo registrado en `docs/PLAN_PILOTO_ELEMONT_2026-09-24.md`). Hoja 2 `chunk_p2_1.txt` SHA `70fa1eafac8b2b2baa707d7941e7f1879f4c2e1a5c2fec081c9b262a52d543f6`, con una sola fila de cada hecho autoritativo (23 Seguridad OUT, 24 Seguridad IN, 25 Presostato OUT, 26 Presostato IN, 30 Micro nivel inferior, 31 Micro nivel superior, 33 Llamada nivel 1, 34 Llamada nivel 2).
- Backup exacto del objeto anterior: `tmp/elemont_patch_2026-09-28/chunk_p1_2_before.txt`, SHA `688a5d780eef8845c489af53f186d275a3a1cc7a4b35f42b38cc2d53be03776c`. El bucket no tiene versionado. Rollback = re-subir ese archivo por `S3DocumentsService#upload_text` a la misma clave y arrancar `BulkKbSyncService` como el script. No es un `PutObject` crudo.
- SHA después: `aea5a4bde1a85002b772488e8ca2a1107151f0171e9481cb418274d0f15c2ee5`. Lectura posterior: el objeto ya no empareja 12 con Seguridad IN, 13 con Seguridad OUT, ni 14/15 con Presostato. La fila `| 25 | PRESOSTATO OUT |` se dejó: la hoja 2 dice lo mismo. No se copiaron a la hoja 1 los bornes 23, 24, 26, 30, 31, 33 ni 34.
- Se reescribieron las filas que contradicen la hoja 2 (12, 13, 14, 15, 22, 23, 24, 26, 27, 31, 32) y los `FIELD_RECORD` que las repetían. El reemplazo es `ver tabla de borneras, hoja 2`. El resto del chunk no cambió.
- Escritura por `S3DocumentsService#upload_text`, que llama `SectionNeighborExpander.invalidate!` en ese proceso (Solid Cache local). No se entró al contenedor web: la caché de producción de ese índice no se borró aquí. Sync `JUEUYVFGLN` status `COMPLETE`: scanned=14918, new=0, modified=1, deleted=0, failed=1. El fallo no es este objeto: `bulk_chunks/3/5b1859a0bfe1c5b11e58214555f8c2fe93e6/chunk_p5_1.txt` (400, demasiados tokens para el embedding). No se lanzó otro job.
- Test: `BUNDLE_PATH=vendor/bundle bin/rails test test/services/elemont_mh_sheet1_bornera_patch_test.rb` — 4 runs, 46 assertions, 0 failures. Sin deploy.
Next phase impact:
- none
Next phase prompt:
```text
none
```

