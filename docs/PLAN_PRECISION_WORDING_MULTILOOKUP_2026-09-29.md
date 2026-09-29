# Plan de precisión — wording, multi-lookup y F1/F2

Fecha: 29-sep-2026. Estado: ver **Execution State**. P1 está `COMPLETED`. P2 está `READY` y no se ha ejecutado. No hay sexta fase. El plan cerrado de Fases 1–5 no se modifica.

No reescribir el RAG. No subir `PINNED_DOCUMENT_RESULTS`. No tocar el tono companion, `SourceFidelityGuard`, `SemanticQueryAnalyzer`, la política de pin, product discovery ni el auto-pin.

## 1. Objetivo

Cerrar los fallos de precisión que siguen vivos después de las Fases 1–5. P1 mide. P2 y P3 tocan solo la causa primaria que esa medida demuestre.

Entrada obligatoria de cada fase: este documento, Execution State, y el plan cerrado solo como contrato de lo que no se reabre.

Línea base: Fases 1–5 `COMPLETED`. `script/rag_pinned_rescue_probe_2026-09-28.rb` cerró 14/14 con las preguntas canónicas. Los fallos de este plan usan otra redacción. El gate es la lista de mappings, caso por caso.

## 2. Decisiones incorporadas (29-sep-2026)

1. La cobertura se evalúa por cada mapping solicitado. Una asociación explícita es entidad o designador, relación solicitada y valor. Mencionar las palabras no cubre el mapping. N mappings exigen N asociaciones, con su identidad y su cardinalidad.
2. Cada fila lleva `primary_cause` y `contributing_causes[]`. La frontera es `selected_generation_chunks`. P2 y P3 implementan solo la causa primaria.
3. La query de rescue, si P1 demuestra que hace falta, sale de una función determinística. Este plan no fija esa función. P1 registra cómo construye la contrafactual. Los tests afirman el string resultante.
4. P4 comprueba que los fallos nuevos pasan y que no aparecen rescues de más. Cobertura inicial completa: una llamada. Cobertura parcial con rescue permitido: como máximo dos. Nunca tres, nunca otra URI, nunca el corpus global.

## 3. Restricciones

1. Sin hardcode de Seguridad, Micro, Llamada, SUBE, BAJA, EDEL, F1 o F2. Los pares de la sección 4 son oráculos de test, no ramas de producción.
2. `PINNED_DOCUMENT_RESULTS` sigue en 3. Sin retry fuera del pin. Como máximo un `retrieve_chunks` adicional: k=3, la misma URI, `force_entity_filter: true`.
3. Sin llamada LLM nueva. `SemanticQueryAnalyzer` no decide elegibilidad, cobertura ni rescue.
4. Sin product discovery, auto-pin ni sugerencia de manual.
5. Síntesis grounded, citas y tono companion se mantienen. `SourceFidelityGuard` no se toca. El bloque de conflicto de `app/prompts/bedrock/generation.txt` solo se toca si `primary_cause` es `synthesis` y las reglas determinísticas no alcanzan.
6. La query de rescue no repite en literal la query inicial cuando el objetivo es ampliar recall. No mete identifiers históricos que no estén ya en el turno o en el goal vigente.
7. Cada fase corre en un chat nuevo, termina en un commit y reescribe el prompt de la fase siguiente. Si el hallazgo contradice una restricción, no se implementa: se escala.
8. P2 y P3 no arreglan una causa posterior a la primaria.

## 4. Cobertura por mapping

Definición usada por P1, P2 y P4.

Un mapping solicitado es una terna: entidad o designador pedido, relación pedida, valor que respondería esa relación. Para que ese mapping esté cubierto, `selected_generation_chunks` tiene que contener una asociación explícita entre las tres. Una fila, una celda o la forma que `explicit_assignment_line?` ya reconoce cuenta cuando une esas tres. La presencia de las palabras en el chunk no cuenta.

Con N mappings pedidos hacen falta N asociaciones compatibles. Cada una conserva su entidad y su valor. Una asociación no cubre otra entidad del mismo turno.

Oráculos, solo en tests y en la matriz. No se escriben como `if` de producción:

- `inferior` → `30` y `superior` → `31`. Ver las dos palabras no cubre ninguno de los dos.
- `Seguridad OUT` → `23` y `Seguridad IN` → `24`. Una fila que menciona `OUT` no cubre `IN`.

`selected_generation_chunks` es el conjunto que vería el generador. Con ruta elegible: la salida de `select_generation_chunks`, o la ventana de rescue entera cuando `@preserve_rescue_window` ya la conserva, o el compactado de designador cuando ese camino corre. `pinned_retrieval` devuelve la ventana expandida antes de esa selección; P1 no la usa como frontera. Sin ruta: los chunks del único `retrieve_chunks`, porque ese camino no tiene selector local.

## 5. Causalidad

Cada fila guarda:

- `primary_cause`
- `contributing_causes[]`, que puede ir vacío

Valores: `query analysis`, `route eligibility`, `retrieval/ranking`, `rescue eligibility/query`, `expansion`, `evidence selection/coverage`, `source/chunk representation`, `synthesis`.

Regla, sobre `selected_generation_chunks`:

- Si la asociación correcta de un mapping pedido no está ahí, `primary_cause` está antes de `synthesis`. El valor sale de la primera frontera que ya perdió esa asociación: análisis de la query, elegibilidad de la ruta, retrieve inicial, rescue, expansión, selección, o el texto del chunk.
- Si todas las asociaciones pedidas están ahí y la respuesta final no las expresa, `primary_cause` es `synthesis`.

Una causa posterior puede anotarse en `contributing_causes` cuando se vio. P2 y P3 no la implementan en el mismo cambio.

La respuesta final se genera una sola vez, y solo cuando todas las asociaciones ya están en `selected_generation_chunks` y la respuesta reportada no las dice. Si falta alguna asociación, la celda queda `no generada; evidencia ausente` y la primaria no es `synthesis`.

## 6. Contrato de la rescue query

P1 registra, en cada fila, cómo se armó la query que se midió. Si la ruta ya lanzó un rescue, registra el método real (`mapping_rescue_query`, `designator_span` u otro) y el string. Si ese rescue no corrió, o corrió con un string idéntico a la query inicial, y algún mapping sigue descubierto, P1 puede hacer un solo retrieve contrafactual.

Ese contrafactual usa una sola función determinística para toda la corrida, elegida antes de lanzar los retrieves y escrita en el artefacto. Las entradas son la relación ya detectada, los mappings, anclas o identifiers ya solicitados en el turno, y el texto actual del turno cuando haga falta para conservar la intención. No es una tabla por caso. No usa LLM. No usa identifiers históricos fuera del turno y del goal vigente.

El string resultante cumple: misma URI, `force_entity_filter: true`, k=3, distinto en literal de la query inicial. Un miss de ese retrieve no autoriza un segundo candidato.

P2 no hereda una plantilla escrita en esta sección. Adopta una función solo si `primary_cause` es `rescue eligibility/query` o `route eligibility` y el retrieve medido por P1 metió en la ventana las asociaciones que faltaban. Los tests afirman ese string, el pin, k=3 y `force_entity_filter: true`. Si P1 no demuestra eso, P2 no inventa otra función: se escala.

## 7. Hallazgos de arranque

Autorizan la hipótesis. No autorizan el fix. P1 los confirma o los tira. La cobertura de la sección 4 es la que se mide, no el predicado léxico de hoy.

- `mapping_lookup_question?` exige relación `:connection`, `:location` o `:attribution` y, además, `BORNE_TERMINAL_PATTERN`, `label_terms?` o `EXACT_LOOKUP_PATTERN` (`app/services/rag/structured_evidence_route.rb`, líneas 102–112). `¿A qué borne corresponde…?` y `¿Cuáles son los bornes…?` cumplen `bornes?`. `¿Dónde está conectada Seguridad IN en la bornera del tablero?` tiene `:location` por `dónde` y `:connection` porque `requested_relation` hace `include?("borne")` sobre `bornera` (`app/services/rag/query_entities.rb`, líneas 33–38 y 150–154). `\bbornes?\b` no matchea `bornera`, no hay label stem y no hay `qué es|indica|función|hay`. La ruta sale nil. `¿Dónde está el cuadro de maniobra?` sigue en nil (`test/services/rag/structured_evidence_route_test.rb`, línea 107).
- `MAPPING_FRAME` solo recorta `¿A qué borne/terminal corresponde…?` (línea 27). `mapping_rescue_query` devuelve entonces la pregunta entera (líneas 657–659) y `same_retrieval_query?` (línea 180) no lanza el segundo retrieve. El primer retrieve de estas paráfrasis pide k=3 (`initial_result_count`, líneas 549–554): no son `structured_mapping_query?` (`app/services/rag_retrieval_profile.rb`, líneas 128–136).
- `explicit_row_covered?` da por cubierta la pregunta si alguna fila solapa alguna ancla (líneas 681–699). Ese predicado no es la cobertura de la sección 4. P1 anota, por mapping, si la asociación está en `selected_generation_chunks` y si el predicado actual habría cancelado el rescue con una sola ancla.
- `T1` y `T2` son designadores con dígito. `uncovered_designators` exige todos, y `designator_span` recorta de `T1` a `T2` (líneas 636–669). `cómo` enciende `EXACT_PROCEDURE_PATTERN` y apaga `pinned_exact_designator_lookup?`. No apaga el camino de designador. P2 no mueve ese camino.
- `SUBE` y `BAJA` son identifiers alfabéticos, sin dígito. `corresponden` da `:attribution`. No hay `borne`, ni label stem, ni `EXACT_LOOKUP`. La ruta sale nil y sigue `BedrockRagService#query` con k=3. La primaria de K6 la decide la sección 5, sobre `selected_generation_chunks`.
- `En EDEL K2, ¿qué función tienen F1 y F2 en los embarques?` entra por designador. `designator_span` corta desde `EDEL` hasta `F2` e incluye `qué función tienen`. `¿qué indican F1 y F2?` recorta a `F1 y F2`. La pregunta de fotocélulas que llega a EDEL p.25 se clasifica con la misma frontera. P3 no arranca si la primaria de esas filas es la misma que la de P2.
- `está` normaliza a `esta`. Con pregunta explícita y 6 palabras o más, `self_contained?` cede ante `esta`/`este` cuando no hay seguimiento fuerte ni `safety_critical_query?` (`app/services/rag/active_episode_turn.rb`, líneas 18–21 y 552–573). P1 registra `effective_question` con episodio vacío y, en las que llevan `está` o `este`, también con un goal previo.
- La Fase 5 ya remite la bornera contradicha de `chunk_p1_2` a la hoja 2. Este plan no vuelve a parchear ese chunk. Si P1 viera las filas viejas tapando una asociación, la primaria sería `source/chunk representation` y se escala.

## 8. P1 — Diagnóstico

Sin cambio de comportamiento. El commit es un script read-only, al estilo de `script/rag_pinned_rescue_probe_2026-09-28.rb`, y un minitest del clasificador sobre un fixture. No se llama a `@generator.query` ni a `retrieve_and_generate`, salvo la única generación de la sección 5. No escribe S3, no ingesta, no deploy.

El script envuelve `retrieve_chunks`. Si `build` devuelve ruta, usa `pinned_retrieval` y después la misma selección que `complete_from_retrieval` para llenar `selected_generation_chunks`, sin generar. Si `build` es nil, un solo `retrieve_chunks` con el `number_of_results` del perfil, la URI del pin y `force_entity_filter: true`; ese resultado es `selected_generation_chunks`. Misma cuenta y los mismos dos documentos que el probe del 28-sep (`danebo-legacy`, SEGURIDADES y Elemont MH / Montacargas). Sin credenciales o sin esos documentos: `BLOCKED`, sin inventar la matriz.

Cada fila guarda: `raw_question`, `effective_question`, identifiers, `requested_relation`, query inicial, chunks iniciales (página, sha, excerpt), rescue sí/no, `mode`, construcción y string de la rescue query, chunks del rescue, `selected_generation_chunks`, `primary_cause`, `contributing_causes`, y la respuesta reportada.

Por cada mapping de esa fila: entidad o designador pedido, relación pedida, evidencia explícita que matcheó, valor, `covered` sí/no. La evidencia vacía y `covered: no` es una medición válida.

Filas, texto literal:

- `¿Cuáles son los bornes de Seguridad OUT y Seguridad IN?` Mappings: OUT → 23, IN → 24.
- `¿Dónde está conectada Seguridad IN en la bornera del tablero?` Mapping: Seguridad IN → 24.
- Canónicos del plan cerrado para micro inferior, micro superior, llamada 1 y llamada 2, más `¿Cuáles son los bornes del micro de nivel inferior y del micro de nivel superior?` (30 y 31) y `¿Cuáles son los bornes de llamada de nivel 1 y nivel 2?` (33 y 34).
- `SUBE` en la forma que el plan cerrado ya conservó (K1), `¿Y para BAJA cuál es el relé?` (K2), y `¿Qué relés corresponden a SUBE y BAJA en este tablero?` (K1 y K2).
- `¿Cómo están configurados T1 y T2?` T1 modo E t<3 min, T2 modo Wu t<1 s.
- `En EDEL K2, ¿qué función tienen F1 y F2 en los embarques?`
- `¿qué indican F1 y F2?`
- `En EDEL K2 con dos embarques, ¿qué fotocélulas identifica el manual para cada embarque?` Registrar la página y si hay asociación explícita F1 y F2.

El contrafactual sigue la sección 6. También anota si `explicit_row_covered?` marcaría cubierta la ventana con una sola ancla, y qué línea, sin usar ese predicado como `covered`.

El minitest del clasificador, sin Bedrock, fija la sección 5 sobre un fixture: asociación ausente → primaria anterior a `synthesis`; asociaciones presentes y respuesta que no las dice → `synthesis`. Los pares de la sección 4 viven en ese fixture. El test no llama a la red.

El probe sale 0 cuando toda fila tiene sus mappings, `selected_generation_chunks`, `primary_cause` y `contributing_causes`, aunque algún mapping esté descubierto. Sale 1 si una fila no se pudo medir. No es gate de precisión y no entra en CI. Artefacto: `tmp/pilot_gate/wording_multilookup_probe_2026-09-29.json`, con hash en Execution State.

Al cerrar, P1 reescribe el prompt de P2 con `primary_cause`, `contributing_causes` y, solo si la sección 6 autoriza adoptarla, la función de rescue query y sus strings. Marca P3 `SKIP` cuando la primaria de F1/F2 es la misma que P2 va a implementar. No implementa P2.

## 9. P2 — Wording y multi-lookup

No empieza con el prompt de esta sección si P1 lo reescribió. Implementa únicamente el `primary_cause` demostrado de las filas A y de los multi-lookup. No toca una causa que solo esté en `contributing_causes`.

Formas que puede usar, y solo si ese es el primario:

- Rescue query: la función que la sección 6 haya autorizado. Tests determinísticos del string. `¿Dónde está el cuadro de maniobra?` sigue inelegible.
- Cobertura: la sección 4. Un mapping descubierto no queda tapado por la asociación de otro. Cobertura completa de todos los mappings pedidos: una llamada. Cobertura parcial, si el primario autorizado es rescue: como máximo dos.
- `bornera` como el mismo stem que `borne`, solo si el primario de la fila A es `route eligibility`. No se añade una clave a `RELATION_TRIGGERS`. Un `dónde` sin ese stem no entra.
- Abrir la ruta ya existente para dos identifiers no numéricos con relación de mapping, solo si el primario de SUBE+BAJA es `route eligibility` y K1/K2 no están en `selected_generation_chunks`. La query es la función de la sección 6. Una pregunta con un solo identifier alfabético se queda como hoy.

Si el primario es `synthesis`, P2 no abre la ruta ni cambia el retrieve. La excepción, si hace falta, entra en el bloque de conflicto ya existente. Si el primario es `source/chunk representation`, P2 se escala y no parchea el chunk.

`T1`+`T2` siguen en el camino de designador. `uncovered_designators` sigue exigiendo los dos. P2 no les aplica otra función de query.

Archivos probables: `app/services/rag/structured_evidence_route.rb` y su test. `app/services/rag_retrieval_profile.rb` solo si el stem `bornera` tiene que vivir en `BORNE_TERMINAL_PATTERN`. `app/services/query_orchestrator_service.rb` no gana una rama.

Tests, sin Bedrock, con fake de `retrieve_chunks`:

- La query de rescue de cada fallo cuyo primario sea rescue es el string registrado por P1, distinta de la query inicial, con la misma URI, `force_entity_filter: true` y k=3.
- Ventana cuya texto menciona `inferior` y `superior` sin asociación a 30 y 31: esos dos mappings quedan descubiertos.
- Una fila de `OUT` no cubre el mapping de `IN`.
- N mappings cubiertos en el primer retorno: una llamada.
- Un mapping cubierto y otro no, con rescue autorizado: dos llamadas, nunca tres.
- `¿Cuáles son los bornes de Seguridad OUT y Seguridad IN?` con las dos asociaciones en el primer retorno: una llamada, y `selected_generation_chunks` conserva 23 y 24.
- `¿Cómo están configurados T1 y T2?` conserva el camino de designador.
- `¿Dónde está el cuadro de maniobra?` sigue en nil. Cadena de seguridad y foso, sin borne, label ni lookup, siguen en una llamada.
- `¿Y para BAJA cuál es el relé?` sigue elíptica, sin tocar `ActiveEpisodeTurn` si P1 no marcó continuidad como primaria.
- `PINNED_DOCUMENT_RESULTS` sigue en 3.

Criterio: esos tests verdes, y la suite de `structured_evidence_route`, `query_entities`, `rag_retrieval_profile`, `active_episode_turn` y `rag_query_concern` sin fallos nuevos. El probe de P1, sin contrafactuales, muestra las asociaciones pedidas en `selected_generation_chunks` de las filas cuyo primario era anterior a `synthesis`. Los controles de un solo mapping no pierden la asociación ni ganan un retrieve.

Rollback: revertir el commit.

## 10. P3 — F1/F2

Si P1 marca `SKIP`, no se implementa.

Implementa solo el `primary_cause` de esas filas. No corrige una causa que P1 haya dejado como contribuyente.

Si el primario es el corte de `designator_span` y P1 demostró un string de rescue que mete las asociaciones, el cambio es ese corte, en el mismo rescue. `SCI del MR08` y `cerrojos exteriores` en el elíptico siguen siendo el segundo query de sus tests actuales. La función obedece la sección 6.

Si el primario es `synthesis`, no se añade un retrieve. La excepción entra en el bloque grounded que ya pide decir las filas. Sin una policy nueva y sin otra llamada.

Si el primario es `source/chunk representation`, queda `BLOCKED` y se escala. No se parchea el chunk. La Fase 5 del plan cerrado no se reabre.

Tests: el caso que P1 haya marcado, con el string de query que P1 haya registrado, más los oráculos 3 y 4 del probe cerrado sin un retrieve extra cuando el primer retorno ya trae el designador.

Rollback: revertir el commit.

## 11. P4 — Gate

Chat nuevo, que no implementó P2 ni P3. No entra en CI. No deploy.

Dos comprobaciones. Los fallos de este plan quedan cubiertos según la sección 4. Los controles de abajo no ganan un rescue.

`retrieve_chunks`:

- Cobertura inicial completa de todos los mappings pedidos: exactamente una llamada.
- Cobertura inicial parcial, y la clase confirmada permite rescue: como máximo dos.
- Nunca tres. Nunca otra URI. Nunca el corpus global.

Controles que no disparan un rescue de más:

- `¿Cómo están configurados T1 y T2?` conserva el camino de designadores.
- Individuales ya buenos: micro inferior, micro superior, llamada 1, llamada 2, Seguridad OUT, Presostato OUT, Presostato IN, SUBE, y BAJA en seguimiento.
- Esos individuales, cuando el primer retorno ya trae su asociación, hacen una llamada.

Hechos que siguen en `selected_generation_chunks`:

- EM2000 hidráulico obstáculo → CN7/CN8
- EM4000 V1 obstáculo → XC4/XC7
- MR08 SCI → CN-112 / CN-109
- EDEL K2 cerrojos exteriores → serie 40
- Seguridad OUT → 23; Seguridad IN → 24
- Presostato OUT → 25; Presostato IN → 26
- micro inferior → 30; micro superior → 31
- llamada 1 → 33; llamada 2 → 34
- T1 modo E t<3 min; T2 modo Wu t<1 s, también juntos
- SUBE → K1; BAJA en seguimiento → K2
- iluminación de foso → circuito 6, 10/11, 3x20W
- cadena de seguridad en su hoja
- el turno de temporizadores después de presostato no arrastra el goal del presostato

Validación del gate, la misma frontera de la sección 5:

- Si la causa cerrada fue de retrieve o de selección, el probe afirma `selected_generation_chunks` y no genera.
- Si la causa cerrada fue `synthesis`, una sola generación grounded, y la respuesta expresa las asociaciones.

La fila de fotocélulas afirma F1 y F2 cuando P3 no quedó en `SKIP` o `BLOCKED`.

Rollback: no hay cambio de runtime. Si el probe falla, no se edita el umbral: se reabre la fase cuyo mapping cayó.

## 12. Presupuesto

P1: un retrieve de producción por fila, más el segundo solo cuando la ruta ya lo haría, más un contrafactual k=3 solo bajo la sección 6. Generación: una por fila, y solo en el caso de la sección 5. P2 y P3 no añaden llamadas de evaluación en CI. P4 repite el probe sin contrafactuales y genera solo en las filas cuya causa cerrada fue `synthesis`.

## 13. Qué no cambia

- `PINNED_DOCUMENT_RESULTS`, `OPEN_RESULTS`, `SAFETY_CRITICAL_RESULTS`, `STRUCTURED_MAPPING_RESULTS`.
- La política de pin, `force_entity_filter` y la prohibición de reintentar en el corpus global.
- `SemanticQueryAnalyzer`, `SourceFidelityGuard`, el tono companion.
- Product discovery y auto-pin.
- Las Fases 1–5 del plan cerrado, incluido el parche de `chunk_p1_2`.
- Un tercer retrieve, una plantilla de rescue query decidida antes de P1, y una llamada LLM para elegir la cobertura.

## Execution State

P1 lee esto antes de medir. El prompt de la fase siguiente, aquí, gana a un mensaje viejo.

### P1
Status: COMPLETED
Commit: this change
Tests: `test/services/rag/wording_multilookup_cause_test.rb` — 8 runs, 34 assertions, 0 failures
Artifact: `tmp/pilot_gate/wording_multilookup_probe_2026-09-29.json`
SHA256: `ff0c73a0674d5581283b3130179ae69c09470ed4c251a616046bbc59de38851b`
Probe: exit 0, unmeasured 0, 15 filas. KB `Y7RZWMFJSR`, bucket `multimodal-source-destination`. `PINNED_DOCUMENT_RESULTS` no se tocó.
Material findings:
- Hits, `primary_cause` `none`: micro inferior → 30, micro superior → 31, llamada 1 → 33, llamada 2 → 34, SUBE → K1, BAJA → K2. BAJA aporta `source/chunk representation` por `| K8 | Contactor 220vac BAJA |`.
- Fotocélulas, fila 15: `none`. La página 25 en `selected_generation_chunks` tiene `| F1 | FOTOCELULA EMBARQUE 1 |` y `| F2 | FOTOCELULA EMBARQUE 2 |`, y la respuesta los dice. El primer clasificador miraba la primera aparición y marcó `synthesis`; se recomputó sobre la respuesta ya guardada, sin otro retrieve.
- OUT+IN juntos: `evidence selection/coverage`. El primer retrieve ya traía la hoja 2 (`| 23 | Seguridad OUT |`, `| 24 | Seguridad IN |`). El selector se quedó con la página 5. `explicit_row_covered?` canceló el rescue sobre la línea de OUT. No es la fase P2.
- Bornera, Seguridad IN: `route eligibility`. Ruta nil. `anchor_phrase` = `conectada Seguridad IN bornera tablero` metió `| 24 | Seguridad IN |` en la hoja 2. La sección 6 autoriza esa función solo para esta fila. El episodio con goal previo quedó `continued_self_contained` y no compuso la pregunta.
- Micro inferior+superior y llamada 1+2: `retrieval/ranking`. El rescue corrió; la query solo perdió el `?` final y no trajo la hoja 2. No hay contrafactual. No se inventa otra query.
- SUBE+BAJA juntos: `route eligibility`, pero `reles corresponden SUBE BAJA tablero` no metió K1 junto a SUBE ni K2 junto a BAJA. La función no se adopta. Se escala. No se abre esa ruta.
- T1+T2: `rescue eligibility/query`. El rescue no corrió. `configurados T1 T2` no trajo modo E ni modo Wu. La función no se adopta. Siguen en el camino de designador.
- F1/F2, filas 13 y 14: `retrieval/ranking`. La query inicial y el `designator_span` devolvieron 0 chunks. El rescue ya había corrido con otra query, así que la sección 6 no autorizó contrafactual.
Next phase prompt: el de la sección 14, bajo P2.

### P2
Status: READY
Blocked by: none
Scope: solo `route eligibility` de la fila de bornera. El resto de los fallos de arriba no entra en este cambio.

### P3
Status: BLOCKED
May become: SKIP — no aplica. La primaria de F1/F2 no es la de P2, y no hay una función de la sección 6 que adoptar. No se implementa.

### P4
Status: PENDING
Blocked by: P2
P3 queda fuera del gate: las filas 13 y 14 no tienen un cambio autorizado, y la fila 15 ya expresa F1 y F2.

## 14. Prompts

Pie común: leer este plan, incluidas las secciones 4, 5 y 6, y Execution State. `git status` y `git log -1`. No deploy. No reabrir las Fases 1–5. No hardcodes. No subir `PINNED_DOCUMENT_RESULTS`. No retry fuera del pin. No llamada LLM nueva. No discovery de manuales. No implementar la fase siguiente.

### P1

```
Repo: /Users/lahirisan/smart_deal
Implementa solo P1 de docs/PLAN_PRECISION_WORDING_MULTILOOKUP_2026-09-29.md.
P1 está READY. No implementes P2, P3 ni P4. No deploy.

Script read-only más minitest del clasificador. La cobertura es la sección 4:
por mapping, entidad o designador, relación, evidencia explícita, valor, covered.
Mencionar las palabras no cubre. N mappings exigen N asociaciones.
La frontera de primary_cause es selected_generation_chunks, sección 5.
Registra primary_cause y contributing_causes[].
La rescue query contrafactual, si hace falta, sigue la sección 6: una función
determinística registrada antes de los retrieves, sin fijarla como código de la app.
Escribe el artefacto, su hash y el prompt de P2. Marca P3 SKIP o deja su prompt.
Commit de P1. Detente.
```

### P2

```
Repo: /Users/lahirisan/smart_deal
Implementa solo P2 de docs/PLAN_PRECISION_WORDING_MULTILOOKUP_2026-09-29.md.
P2 está READY. No implementes P3 ni P4. No deploy.

primary_cause: route eligibility. Una sola fila:
¿Dónde está conectada Seguridad IN en la bornera del tablero?
La ruta salió nil. selected_generation_chunks no tenía | 24 | Seguridad IN |.
Función autorizada por la sección 6: anchor_phrase.
String medido: conectada Seguridad IN bornera tablero.
Misma URI, force_entity_filter true, k=3. Esa query metió la fila de la hoja 2.
Trata bornera como el stem de borne. No añadas una clave a RELATION_TRIGGERS.
¿Dónde está el cuadro de maniobra? sigue nil.

No toques las otras filas:
- OUT+IN juntos es evidence selection/coverage. La hoja 2 ya estaba en el primer retrieve.
  No cambies select_generation_chunks.
- Micro inferior+superior y llamada 1+2 son retrieval/ranking. No inventes una query.
- SUBE+BAJA juntos es route eligibility, pero reles corresponden SUBE BAJA tablero
  no metió K1 con SUBE ni K2 con BAJA. No abras esa ruta. Escala.
- T1+T2 es rescue eligibility/query. configurados T1 T2 no trajo modo E ni modo Wu.
  Siguen en el camino de designador. No les apliques otra función.
- F1/F2 no es esta fase.

No toques ActiveEpisodeTurn. PINNED_DOCUMENT_RESULTS sigue en 3.
Tests sin Bedrock, del string medido, el pin, k=3 y force_entity_filter true.
Commit. Detente.
```

### P3

```
P3 está BLOCKED. No implementes.

Filas 13 y 14: primary_cause retrieval/ranking. La query inicial y el
designator_span devolvieron 0 chunks. El rescue ya corrió con otra query,
así que la sección 6 no autorizó un contrafactual. No hay función que adoptar.
No inventes un span ni un retrieve.

Fila 15: primary_cause none. La página 25 ya tenía
| F1 | FOTOCELULA EMBARQUE 1 | y | F2 | FOTOCELULA EMBARQUE 2 |,
y la respuesta guardada los dice.

No es la clase de P2 y no es SKIP: no hay un cambio autorizado.
No parchees chunks. No reabras la Fase 5. Escala y detente.
```

### P4

Chat que no tocó P2 ni P3. Probe read-only. Los fallos nuevos pasan. Los controles de la sección 11 no ganan un rescue. Cobertura completa: una llamada. Parcial con rescue permitido: como máximo dos. Nunca tres, nunca otra URI, nunca el corpus global. Retrieve o selección: afirmar `selected_generation_chunks`. `synthesis`: una generación grounded. Salir 0 solo con eso. No editar el umbral.

## Qué no está en este plan

Deploy, Kamal, reindex, parche nuevo de `chunk_p1_2`, subida de top-k, tercer retrieve, analyzer LLM, auto-pin, cambios de UX, y una fase nueva.
