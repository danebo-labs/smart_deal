# Plan de precisión — wording, multi-lookup y F1/F2

Fecha: 29-sep-2026. Estado: ver **Execution State**. P1 está `COMPLETED`. P2 está `COMPLETED`. P3 está `COMPLETED`. P4 está `PENDING`. No hay sexta fase. El plan cerrado de Fases 1–5 no se modifica.

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

Codex, 29-sep-2026, reestructura el cierre de P1. P2 quedó `COMPLETED` en Execution State. Las seis filas permanecen. No es un solo commit para todas. Se trabaja caso por caso. Una fila `BLOCKED` no bloquea el resto de P2. F1/F2 no entra aquí. El prompt de la sección 14 es el que se ejecuta.

Filas:

1. Bornera IN. `¿Dónde está conectada Seguridad IN en la bornera del tablero?` `primary_cause`: `route eligibility`.
2. OUT+IN. `¿Cuáles son los bornes de Seguridad OUT y Seguridad IN?` `primary_cause`: `evidence selection/coverage`.
3. Micros inferior+superior. `primary_cause`: `retrieval/ranking`.
4. Llamadas 1+2. `primary_cause`: `retrieval/ranking`.
5. SUBE+BAJA. `¿Qué relés corresponden a SUBE y BAJA en este tablero?` `primary_cause`: `route eligibility`.
6. T1+T2. `¿Cómo están configurados T1 y T2?` `primary_cause`: `rescue eligibility/query`.

A. Bornera IN. Fix autorizado por P1. Tratar `bornera` como stem compatible con `borne`/`terminal` si esa sigue siendo la corrección mínima. No se añade una clave a `RELATION_TRIGGERS`. Rescue query medida: `conectada Seguridad IN bornera tablero`. Misma URI, `force_entity_filter: true`, k=3, como máximo un retrieve adicional. `¿Dónde está el cuadro de maniobra?` sigue nil.

B. OUT+IN. No añadir retrieval. La hoja 2 ya estaba en el retrieve inicial (`| 23 | Seguridad OUT |`, `| 24 | Seguridad IN |`) y `selected_generation_chunks` se quedó con la página 5. Corregir selection/coverage con la sección 4: cada mapping pedido necesita su asociación explícita. Una sola asociación no puede cancelar el rescue ni la selección de todo el turno.

C. Micros, llamadas, SUBE+BAJA y T1+T2. No inventar un fix particular ni una query por caso. Para cada fila: revisar la primaria de P1 y buscar una generalización determinística que quepa en las restricciones. Si se puede resolver sin hardcodes, sin LLM nuevo, sin tercer retrieve y sin abrir el corpus global, se implementa con tests. Si no, esa fila queda `BLOCKED` con `primary_cause`, la restricción que lo impide y la condición concreta de desbloqueo.

La sección 6 sigue vigente. `anchor_phrase` solo está autorizada para bornera IN. SUBE+BAJA midió `reles corresponden SUBE BAJA tablero` y no metió K1 con SUBE ni K2 con BAJA: esa función no se adopta. T1+T2 midió `configurados T1 T2` y no trajo modo E ni modo Wu: no se les aplica otra función de query. Micros y llamadas corrieron el rescue con la pregunta sin el `?` final y no trajeron la hoja 2: no hay contrafactual y no se inventa otra query. `synthesis` y `source/chunk representation` no son la primaria de estas seis filas. No se toca el prompt ni se parchea el chunk. No se toca `ActiveEpisodeTurn`. `PINNED_DOCUMENT_RESULTS` sigue en 3.

Al cerrar, cada una de las seis filas queda implementada o `BLOCKED` individual. Se reescribe el prompt de P3. No se implementa P3.

Archivos probables: `app/services/rag/structured_evidence_route.rb` y su test. `app/services/rag_retrieval_profile.rb` solo si el stem `bornera` tiene que vivir en `BORNE_TERMINAL_PATTERN`. `app/services/query_orchestrator_service.rb` no gana una rama.

Tests, sin Bedrock, con fake de `retrieve_chunks`:

- Bornera IN: el string medido, distinto de la query inicial, misma URI, `force_entity_filter: true`, k=3.
- Una fila de `OUT` no cubre el mapping de `IN`.
- `¿Cuáles son los bornes de Seguridad OUT y Seguridad IN?` con las dos asociaciones en el primer retorno: una llamada, y `selected_generation_chunks` conserva 23 y 24.
- Ventana que menciona `inferior` y `superior` sin asociación a 30 y 31: esos dos mappings quedan descubiertos.
- N mappings cubiertos en el primer retorno: una llamada. Un mapping cubierto y otro no, con rescue autorizado: dos llamadas, nunca tres.
- Para C, tests solo de la generalización que se haya implementado. Una fila `BLOCKED` no gana un test de un fix que no existe.
- `¿Cómo están configurados T1 y T2?` conserva el camino de designador si no hubo esa generalización.
- `¿Dónde está el cuadro de maniobra?` sigue en nil. Cadena de seguridad y foso siguen en una llamada.
- `¿Y para BAJA cuál es el relé?` sigue elíptica.
- `PINNED_DOCUMENT_RESULTS` sigue en 3.

Criterio: tests verdes de lo implementado, y la suite de `structured_evidence_route`, `query_entities`, `rag_retrieval_profile`, `active_episode_turn` y `rag_query_concern` sin fallos nuevos. Cada fila de P2 tiene disposición en Execution State. Los controles de un solo mapping no pierden la asociación ni ganan un retrieve.

Rollback: revertir el commit.

## 10. P3 — F1/F2

`COMPLETED`. No está `BLOCKED` globalmente y no es `SKIP`. Las dos formulaciones quedaron `RESOLVED`. El control positivo sigue en `EDEL K2` y no ganó un retrieve.

Filas:

- `En EDEL K2, ¿qué función tienen F1 y F2 en los embarques?` `primary_cause`: `retrieval/ranking`.
- `¿qué indican F1 y F2?` `primary_cause`: `retrieval/ranking`.

Control positivo, ya cubierto en P1. No se reabre como fallo:

- `En EDEL K2 con dos embarques, ¿qué fotocélulas identifica el manual para cada embarque?` Página 25. F1 fotocélula embarque 1. F2 fotocélula embarque 2. `primary_cause`: `none`.

`source/chunk representation` no es la hipótesis primaria. La evidencia existe: esa formulación ya recupera la página 25 y expresa las dos asociaciones. Las dos formulaciones fallidas devolvieron 0 chunks en la query inicial y en el `designator_span`. El rescue corrió con otra query, así que P1 no autorizó un contrafactual.

Contrato: buscar una solución general de query, rescue o ranking. No hardcodear F1/F2. No parchear el chunk. No reabrir la Fase 5. No tocar el prompt si la evidencia no llega a `selected_generation_chunks`. Sin tercer retrieve, sin corpus global, sin LLM nuevo. El retrieve adicional, si cabe, es uno: k=3, misma URI, `force_entity_filter: true`. `SCI del MR08` y `cerrojos exteriores` siguen siendo el segundo query de sus tests actuales. El control positivo no gana un retrieve extra si el primer retorno ya trae la página 25.

Si no hay solución dentro de esas restricciones, cada formulación fallida queda `BLOCKED` por separado, con `primary_cause`, la restricción y la condición de desbloqueo. El control positivo no se marca `BLOCKED` por eso.

Cierre. La función es `condensed_designator_query`. El span con una palabra de contenido pasa a los identificadores del turno, en orden. Una pregunta de atribución cuyo único extra es una conjunción pasa a los designadores sin esa conjunción. Un span cuyos extras son solo palabras funcionales queda literal. Medido en la KB de P1, k=3, la misma URI, `force_entity_filter: true`: `EDEL K2 F1 F2` y `F1 F2` traen la página 25 con `| F1 | FOTOCELULA EMBARQUE 1 |` y `| F2 | FOTOCELULA EMBARQUE 2 |`. El span en prosa, `F1 y F2` y las dos `anchor_phrase` devolvieron 0. `SCI del MR08`, `T1 y T2`, `EDEL K2`, `EM4000 V1`, `H4`, `T1` y `T2` no cambian.

Rollback: revertir el commit.

## 11. P4 — Gate

Chat nuevo, que no implementó P2 ni P3. No entra en CI. No deploy.

Cada fila de este gate cierra en `RESOLVED`, `BLOCKED` o `DEFERRED`. Ninguna se elimina en silencio. `DEFERRED` exige justificación y no cuenta como éxito del plan.

`RESOLVED`: si la causa era de retrieve o de selección, el hecho correcto está en `selected_generation_chunks` y no se genera. Si la causa era `synthesis`, una generación grounded y la respuesta expresa las asociaciones.

`BLOCKED`: causa, restricción que impide resolverla, condición concreta de desbloqueo.

Filas obligatorias de este plan:

- Bornera IN
- OUT+IN
- Micros juntos
- Llamadas juntas
- SUBE+BAJA
- T1+T2
- F1/F2 función
- F1/F2 indican
- Fotocélulas F1/F2, control positivo: página 25, F1 embarque 1, F2 embarque 2

Dos comprobaciones. Los fallos que quedaron `RESOLVED` están cubiertos según la sección 4. Los controles de abajo no ganan un rescue.

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

Fotocélulas entra siempre, como control positivo. Las dos formulaciones fallidas de F1/F2 entran siempre. Un `BLOCKED` individual no se borra ni cuenta como éxito.

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
Status: COMPLETED
Commit: this change
Tests: `test/services/rag/structured_evidence_route_test.rb` — 80 runs, 661 assertions, 0 failures. También verdes: `query_entities_test.rb`, `rag_retrieval_profile_test.rb`, `active_episode_turn_test.rb`, `rag_query_concern_test.rb` — 280 runs, 1544 assertions, 0 failures, 22 skips. `PINNED_DOCUMENT_RESULTS` sigue en 3.
1. Bornera IN — RESOLVED. `primary_cause`: `route eligibility`. `bornera` entra como stem de borne/terminal solo en la elegibilidad de mapping. No hay clave nueva en `RELATION_TRIGGERS`. Rescue: `anchor_phrase` de P1, string `conectada Seguridad IN bornera tablero`. Misma URI, `force_entity_filter: true`, k=3, un retrieve adicional. `¿Dónde está el cuadro de maniobra?` sigue nil.
2. OUT+IN — RESOLVED. `primary_cause`: `evidence selection/coverage`. Sin retrieve nuevo. Cada conjunción de borne pide su fila explícita. Las dos filas en el primer retorno: una llamada, y la selección conserva `| 23 | Seguridad OUT |` y `| 24 | Seguridad IN |`. Una fila de OUT no cubre IN, ni al revés. Mencionar las palabras no cubre.
3. Micros inferior+superior — BLOCKED. `primary_cause`: `retrieval/ranking`. Se aplicó la misma cobertura: la prosa con `inferior` y `superior` queda descubierta, y las dos filas explícitas sí contarían. Eso no mete la hoja 2. El rescue ya corrió; la query solo perdió el `?` y devolvió páginas 6, 3 y 5. P1 no midió contrafactual, así que no hay otra query. Desbloqueo: un retrieve medido, k=3, misma URI, `force_entity_filter: true`, de una función determinística que no sea un string por caso, que deje `| 30 |` con inferior y `| 31 |` con superior en la ventana. No un tercer retrieve ni subir k.
4. Llamadas 1+2 — BLOCKED. `primary_cause`: `retrieval/ranking`. Mismo intento y la misma restricción. El rescue devolvió páginas 5, 6 y 3, no la hoja 2. Desbloqueo: el mismo tipo de retrieve medido, con llamada nivel 1 → 33 y llamada nivel 2 → 34 en la ventana.
5. SUBE+BAJA — BLOCKED. `primary_cause`: `route eligibility`. La ruta sigue cerrada. `reles corresponden SUBE BAJA tablero` no juntó K1 con SUBE ni K2 con BAJA. K1/K2 de la página 3 no traen la asociación. K6 no vale como asignación. No hay otra query medida. Desbloqueo: un retrieve medido, k=3, misma URI, `force_entity_filter: true`, que deje las filas explícitas K1–SUBE y K2–BAJA. No abrir la ruta con una query no medida.
6. T1+T2 — BLOCKED. `primary_cause`: `rescue eligibility/query`. Sigue el camino de designador. La rescue query sigue `T1 y T2` y no corrió porque los dos designadores ya estaban en la ventana. `configurados T1 T2` no trajo modo E ni modo Wu. No se adopta otra función. Desbloqueo: un retrieve medido, con las mismas restricciones, que deje T1 modo E t<3 min y T2 modo Wu t<1 s, sin reemplazar el camino de designador en las formulaciones que ya devuelven esas asociaciones.
F1/F2 no fue esta fase. Su `primary_cause` sigue `retrieval/ranking`.
Next phase prompt: el de la sección 14, bajo P3.

### P3
Status: COMPLETED
Commit: this change
Tests: `test/services/rag/structured_evidence_route_test.rb` — 87 runs, 737 assertions, 0 failures. `query_entities_test.rb` — 18 runs, 79 assertions, 0 failures. `PINNED_DOCUMENT_RESULTS` sigue en 3.
Medición, KB `Y7RZWMFJSR`, URI de SEGURIDADES, k=3, `force_entity_filter: true`. Sin generación.
- Función. Identifiers: EDEL alpha, K2, F1, F2. `requested_relation` vacío. Query inicial: la pregunta, 0 chunks. Rescue real: `designator_span` = `EDEL K2, ¿qué función tienen F1 y F2`, 0 chunks.
- Indican. Identifiers: F1, F2. `requested_relation`: attribution. Query inicial: la pregunta, 0 chunks. Rescue real: `F1 y F2`, 0 chunks.
- Control. Identifiers: EDEL, K2. `requested_relation`: attribution. Query inicial: 0 chunks. Rescue `EDEL K2`: páginas 23, 25 y 26. La página 25 tiene `| F1 | FOTOCELULA EMBARQUE 1 |` y `| F2 | FOTOCELULA EMBARQUE 2 |`.
El control llega porque el span se corta en K2 y ese string es el alias del chunk. Las otras dos no: la prosa y la conjunción `y` vacían la ventana. `anchor_phrase` también devolvió 0 (`EDEL K2 funcion tienen F1 F2 embarques`, `indican F1 F2`). Quitar `¿` y `?` a la pregunta entera también devolvió 0.
Generalización: `condensed_designator_query`. Palabra de contenido dentro del span → los identificadores del turno, en orden. Atribución y el único extra es una conjunción → los designadores sin esa conjunción. Extras que son solo palabras funcionales → el span literal.
Hits medidos, la misma página 25 y las dos filas: `EDEL K2 F1 F2`, `F1 F2`, y el control `EDEL K2`.
Strings que no cambian: `EDEL K2` (cerrojos), `SCI del MR08`, `EM4000 V1`, `H4`, `T1`, `T2`, `T1 y T2`.
1. F1/F2 función — RESOLVED. `primary_cause`: `retrieval/ranking`. Rescue: `EDEL K2 F1 F2`. Un retrieve adicional, k=3, misma URI, `force_entity_filter: true`. Si K2, F1 y F2 ya están en la primera ventana, una llamada. Nunca tres.
2. F1/F2 indican — RESOLVED. `primary_cause`: `retrieval/ranking`. Rescue: `F1 F2`. Mismo presupuesto. Si F1 y F2 ya están en la primera ventana, una llamada.
Control positivo — sin cambio. Rescue `EDEL K2`. Una llamada si la primera ventana ya trae K2. No es `BLOCKED`.
P2 no se reabrió. Micros, llamadas, SUBE+BAJA y T1+T2 siguen `BLOCKED`.
Next phase prompt: el de la sección 14, bajo P4.

### P4
Status: PENDING
Ready after: P3 COMPLETED
P2 y P3 ya cerraron. Cada fila obligatoria de la sección 11 cierra en `RESOLVED`, `BLOCKED` o `DEFERRED`. Ninguna se elimina en silencio. `DEFERRED` no cuenta como éxito. Un `BLOCKED` no se convierte en éxito.
Disposición que P2 deja, y que este gate no reabre:
- Bornera IN — RESOLVED
- OUT+IN — RESOLVED
- Micros juntos — BLOCKED, `retrieval/ranking`
- Llamadas juntas — BLOCKED, `retrieval/ranking`
- SUBE+BAJA — BLOCKED, `route eligibility`
- T1+T2 — BLOCKED, `rescue eligibility/query`
F1/F2 función y F1/F2 indican quedaron `RESOLVED` en P3. El control de fotocélulas sigue en `EDEL K2`, página 25. El gate no los reabre como fallo. Un `BLOCKED` de P2 no se convierte en éxito.

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
P2 está READY. No implementes P3 ni P4. No deploy. No toques P1 ni 81e3caf.

Seis filas, caso por caso. Una fila BLOCKED no bloquea el resto. F1/F2 no es esta fase.

A. Bornera IN, route eligibility.
Trata bornera como stem de borne/terminal si esa es la corrección mínima.
No añadas una clave a RELATION_TRIGGERS.
Rescue query medida: conectada Seguridad IN bornera tablero.
Misma URI, force_entity_filter true, k=3, un retrieve adicional.
¿Dónde está el cuadro de maniobra? sigue nil.

B. OUT+IN, evidence selection/coverage.
No añadas retrieval. La hoja 2 ya estaba en el primer retrieve.
Cada mapping pedido necesita su asociación explícita.
Una sola asociación no cancela rescue ni selección de todo el turno.
selected_generation_chunks conserva 23 y 24.

C. Micros, llamadas, SUBE+BAJA, T1+T2.
No inventes un fix ni una query por caso.
Busca una generalización determinística dentro de las restricciones.
Si no cabe: marca ESA fila BLOCKED con primary_cause, la restricción
y la condición de desbloqueo.
No adoptes reles corresponden SUBE BAJA tablero ni configurados T1 T2:
P1 mostró que no meten la asociación.
PINNED_DOCUMENT_RESULTS sigue en 3. Sin tercer retrieve. Sin corpus global.
Sin LLM nuevo. Sin hardcodes. No toques ActiveEpisodeTurn ni el prompt.
Tests sin Bedrock de lo que implementes. Commit. Reescribe P3. Detente.
```

### P3

```
Repo: /Users/lahirisan/smart_deal
Implementa solo P3 de docs/PLAN_PRECISION_WORDING_MULTILOOKUP_2026-09-29.md.
P3 está PENDING. P2 está COMPLETED. No está BLOCKED globalmente.
No implementes P4. No deploy. No reabras P1 ni P2. No toques 81e3caf.

P2 dejó RESOLVED:
- Bornera IN, route eligibility. Stem bornera y anchor_phrase.
- OUT+IN, evidence selection/coverage. Sin retrieve nuevo.

P2 dejó BLOCKED. No las implementes:
- Micros inferior+superior, retrieval/ranking.
- Llamadas 1+2, retrieval/ranking.
- SUBE+BAJA, route eligibility. La ruta sigue cerrada.
- T1+T2, rescue eligibility/query. El camino de designador sigue.

Filas de esta fase, primary_cause retrieval/ranking:
- En EDEL K2, ¿qué función tienen F1 y F2 en los embarques?
- ¿qué indican F1 y F2?
Control positivo, no reabrir:
- En EDEL K2 con dos embarques, ¿qué fotocélulas identifica el manual para cada embarque?
  Página 25. F1 fotocélula embarque 1. F2 fotocélula embarque 2.

source/chunk representation no es la hipótesis. La evidencia existe:
la formulación de fotocélulas ya trae la página 25.
La query inicial y el designator_span de las dos filas fallidas devolvieron 0 chunks.
El rescue ya había corrido, así que P1 no autorizó contrafactual.
Busca una solución general de query, rescue o ranking.
No hardcodees F1/F2. No parchees el chunk. No reabras la Fase 5.
No toques el prompt si la evidencia no llega a selected_generation_chunks.
Sin tercer retrieve, sin corpus global, sin LLM nuevo.
PINNED_DOCUMENT_RESULTS sigue en 3. El retrieve adicional, si cabe, es uno:
k=3, misma URI, force_entity_filter true.
SCI del MR08 y cerrojos exteriores siguen siendo el segundo query de sus tests.
El control positivo no gana un retrieve extra si el primer retorno ya trae la página 25.
Si no hay solución, marca cada formulación BLOCKED por separado,
con primary_cause, restricción y condición de desbloqueo.
El control positivo no se marca BLOCKED por eso.
Commit. Reescribe P4 con el estado real. Detente.
```

### P4

```
Chat que no tocó P2 ni P3. Probe read-only. No deploy. No editar el umbral.
Lee Execution State después de P3. No conviertas un BLOCKED en éxito.

Disposición que P2 ya cerró y este gate no reabre:
- Bornera IN — RESOLVED. route eligibility. La asociación de Seguridad IN
  tiene que estar en selected_generation_chunks. Una llamada si el primer
  retorno ya la trae; como máximo dos si hace falta el rescue medido.
- OUT+IN — RESOLVED. evidence selection/coverage. Las dos asociaciones en
  selected_generation_chunks. Si el primer retorno ya trae las dos filas,
  una llamada.
- Micros juntos — BLOCKED. retrieval/ranking. Sin query medida que meta 30 y 31.
- Llamadas juntas — BLOCKED. retrieval/ranking. Sin query medida que meta 33 y 34.
- SUBE+BAJA — BLOCKED. route eligibility. La ruta sigue cerrada.
  K6 no es la asignación. K1/K2 sin SUBE/BAJA no cuentan.
- T1+T2 — BLOCKED. rescue eligibility/query. Conserva el camino de designador.
  configurados T1 T2 no trajo los modos.

F1/F2 función — RESOLVED. retrieval/ranking.
La asociación tiene que estar en selected_generation_chunks:
| F1 | FOTOCELULA EMBARQUE 1 | y | F2 | FOTOCELULA EMBARQUE 2 |, página 25.
No generes. Si la primera ventana ya trae K2, F1 y F2, una llamada.
Si no, un retrieve adicional con la query EDEL K2 F1 F2.
k=3, misma URI, force_entity_filter true. Nunca tres.

F1/F2 indican — RESOLVED. retrieval/ranking.
Las mismas dos filas en selected_generation_chunks. No generes.
Si la primera ventana ya trae F1 y F2, una llamada.
Si no, un retrieve adicional con la query F1 F2.
k=3, misma URI, force_entity_filter true. Nunca tres.

Fotocélulas — control positivo, primary_cause none.
Página 25, F1 embarque 1, F2 embarque 2.
La rescue query sigue EDEL K2. No es un fallo.
Si la primera ventana ya trae K2, una llamada. No gana un retrieve de más.

KB de la medición de P3: Y7RZWMFJSR, el mismo documento pin de P1.

Más los controles históricos de la sección 11.
Cada fila cierra en RESOLVED, BLOCKED o DEFERRED. Ninguna se elimina.
DEFERRED no cuenta como éxito. BLOCKED no cuenta como éxito.
RESOLVED de retrieve o selección: el hecho está en selected_generation_chunks, sin generar.
RESOLVED de synthesis: una generación grounded.
Cobertura completa: una llamada. Parcial con rescue permitido: como máximo dos.
Nunca tres, nunca otra URI, nunca el corpus global.
Los controles de la sección 11 no ganan un rescue.
Los individuales ya buenos, cuando el primer retorno trae su asociación, hacen una llamada.
```

## Qué no está en este plan

Deploy, Kamal, reindex, parche nuevo de `chunk_p1_2`, subida de top-k, tercer retrieve, analyzer LLM, auto-pin, cambios de UX, y una fase nueva.
