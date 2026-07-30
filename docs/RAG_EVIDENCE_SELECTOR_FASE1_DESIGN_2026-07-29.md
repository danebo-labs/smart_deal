# Fase 1 — Diseño del selector de evidencia y del extractor de entidades

**Fecha:** 2026-07-29.
**Alcance ejecutado:** Fase 1 de [RAG_PRECISION_V2_PLAN_2026-07-29.md](RAG_PRECISION_V2_PLAN_2026-07-29.md), fila asignada a Opus en §12 («diseño del selector de evidencia + extractor de entidades — API, reglas de agrupación»).
**Lo que este documento NO hace:** no implementa. La normalización de variantes y el código del selector son la fila Sonnet de Fase 1. No toca `app/`, fixtures, S3/KB ni producción.
**Precedentes que consume:** [RAG_REGEX_AUDIT_FASE05_2026-07-29.md](RAG_REGEX_AUDIT_FASE05_2026-07-29.md) (contrato `Rag::QueryAnalysis`, paso P0 verde) y [RAG_PRODUCTION_TRACE_2026-07-29.md](RAG_PRODUCTION_TRACE_2026-07-29.md) (auditoría de 97 sidecars reales).

---

## 1. Cuatro hallazgos que cambian el diseño

### F1 · `metadata_label` es código inalcanzable en producción

`AmbiguousModelResponder#metadata_label` ([:113-123](../app/services/rag/ambiguous_model_responder.rb#L113-L123))
exige `metadata["manufacturer"]` y devuelve `nil` sin él. Ese contrato de sidecar
**no existe**: `BatchResultsParserService#sidecar_metadata`
([:495-518](../app/services/batch_results_parser_service.rb#L495-L518)) es el único
escritor de `metadataAttributes` en todo el código y sus claves son

```
account_id · document_id · original_source_uri · original_filename · canonical_name
doc_sha256 · ingestion_path · ingestion_contract_version · prompt_fingerprint_sha256
aliases · page_number · section_identity
```

Ningún camino de ingesta escribe `manufacturer`, `controller_model` ni `board_model`.
Por tanto `metadata_label` siempre retorna `nil`, **todas** las etiquetas provienen de
`heading_label`, y `MODEL_PATTERN` (usado solo en `:119`) es inalcanzable.

Dos consecuencias:

1. **Corrección a la auditoría de Fase 0.5:** R2 (`MODEL_PATTERN`) no está «bloqueado por Fase 2». Es código muerto y su retiro es una **eliminación pura**, ejecutable en P1 sin esperar el backfill. R1 y R3 siguen bloqueados.
2. **Un test da confianza falsa.** `ambiguous_model_responder_test.rb:28-45` construye chunks con `"manufacturer" => "TOKIBAT"` y espera la etiqueta `"TOKIBAT — DL27"`. Valida una rama que producción no puede alcanzar. No debe borrarse sin más: hay que convertirlo en el test del mecanismo que **sí** va a existir (§8), o el retiro de `metadata_label` pasaría inadvertido.

### F2 · El seam de identidad estructural ya existe y se llama `section_identity`

No hay que inventar `manufacturer`/`controller_model`/`board_model`. El contrato
`field_records_v7` ya define `section_identity` —la familia marca/controlador que una
página divisoria declara— y `ChunkMergerService`
([:77-98](../app/services/chunk_merger_service.rb#L77-L98)) **ya la arrastra hacia
adelante en orden de página** a cada chunk siguiente hasta que otra divisoria declara
una nueva, y la antepone a los alias del chunk para que sobreviva al tope.

Es decir: el vínculo divisoria→página de contenido que Fase 1 pide en su punto 4 **ya
está construido para documentos futuros**. Lo que falta es solo para SEGURIDADES: el
trace de producción confirma que sus 97 sidecars son `field_records_v5` y no traen
`section_identity`.

Reencuadre del trabajo:

| | Mecanismo |
|---|---|
| Documentos futuros | nada que construir — v7 lo hace en ingesta |
| SEGURIDADES | backfill de `section_identity` en los sidecars existentes → **Fase 2** |
| Fase 1 | una señal **interina** para agrupar y expandir mientras el backfill no exista, medida y con fecha de retiro |

El diseño debe apuntar a `section_identity` como clave durable y tratar la señal
interina como andamiaje explícito, no como la arquitectura.

### F3 · La mitad de la cohorte v2 son preguntas inversas

El plan asume el caso directo («¿a qué serie corresponde SPM?») con «salvo preguntas
inversas» como nota al margen. Contando sobre las diez preguntas reales:

| Modo | Casos |
|---|---|
| **Directo** — la pregunta nombra el identificador y pide su significado | `altius_d8_d11`, `tpr50_spm`, `edel_k3_leds`, `tokibat_dl27_v2`, `enier_mxl1_leds` |
| **Inverso** — la pregunta nombra la función y pide el identificador | `cta_sr8p_sph`, `em2000_leds_seguridad`, `em4000_obstaculo_conectores`, `thyssen_serie_e_leds`, `elecmegon_obstaculo_ambiguo` |

Son 5 y 5. El modo inverso es donde el riesgo de invención es máximo, porque el
identificador es la **salida** y el modelo tiene que elegirlo. No es un caso especial:
es la mitad del contrato y necesita su propia regla de selección (§7, etapa 3).

### F4 · `requested_relation` no puede ser un único símbolo

Corrección al contrato que diseñé en Fase 0.5. Tres de las diez preguntas piden **dos
relaciones a la vez** y el PDF documenta solo una:

| Caso | Relaciones pedidas | Documentado |
|---|---|---|
| `tokibat_dl27_v2` | atribución + estado («qué indica **y cuándo se enciende**») | solo atribución |
| `thyssen_serie_e_leds` | atribución + estado («**¿cuál indica condición normal?**») | solo atribución |
| `cta_sr8p_sph` | atribución + ubicación («**y en qué placa** se encuentra») | ambas |

Con un `requested_relation` escalar, la respuesta correcta a `tokibat_dl27_v2` es
irrepresentable: hay que responder la atribución **y** abstenerse del estado, en la
misma respuesta. Por eso el campo pasa a `Set<Symbol>` y **cada relación se resuelve o
se abstiene por separado**. Esto es exactamente el gate «abstención ante estados no
documentados» de Fase 0, y sin este cambio el selector no puede alimentarlo.

---

## 2. Resolución de una colisión de nombres

El plan §8 lista `app/services/rag/query_entities.rb`; la auditoría de Fase 0.5 definió
`Rag::QueryAnalysis`. Son la misma cosa descrita dos veces, y dos descripciones de la
pregunta es precisamente el defecto que Fase 0.5 vino a eliminar.

Decisión: **un solo objeto de valor y un constructor.**

- `Rag::QueryAnalysis` — el objeto de valor inmutable (contrato de la auditoría §5.1), con `requested_relation` corregido a `Set<Symbol>` por F4.
- `Rag::QueryEntities` — el **extractor**: reglas que leen la pregunta y construyen ese objeto. No es un segundo value object y no se pasa a nadie.

`app/services/rag/query_entities.rb` conserva el nombre del plan; su contenido es el
builder, no un contrato paralelo.

---

## 3. Normalización de variantes — especificación cerrada

Regla marco: **se normaliza para comparar, nunca para mostrar.** Cada candidato lleva
`raw` (lo impreso en el PDF) y `key` (la forma plegada). Todo lo que ve el técnico es
`raw`.

Pliegues permitidos, en este orden:

1. `unicode_normalize(:nfkd)` + quitar marcas diacríticas + `upcase`.
2. Quitar separadores (` `, `-`, `_`, `.`) **entre una corrida de letras y una corrida de dígitos**: `EM 4000` → `EM4000`, `TPR-50` → `TPR50`, `EDEL K3` → `EDELK3`.
3. Quitar un punto **entre dos corridas de dígitos cuando la derecha tiene exactamente 3 dígitos** (separador de miles): `2.007` → `2007`.

Pliegues **prohibidos** — cada uno tiene un caso del gate detrás:

| Prohibición | Caso que protege |
|---|---|
| No plegar dígitos entre sí | `CN7` ≠ `CN8` ≠ `CN9` (`em4000_obstaculo_conectores`) |
| No plegar el sufijo alfabético final | `EDEL-K2` ≠ `EDEL-K3` (contaminación, Fase 6) |
| No plegar dentro de una corrida de dígitos que no sea separador de miles | `CN-112.SC` conserva su punto (regresión MR08) |
| No absorber el sufijo de versión | `EM4000 V1` ≠ `EM4000` |

El sufijo de versión se modela aparte: la clave se descompone en `model_key` +
`variant`. La coincidencia exige igualdad de `model_key`; una discrepancia de `variant`
degrada a **hermano** y nunca fusiona hechos. Así `EM4000 V1` encuentra la página de
`EM4000` sin que sus conectores se mezclen con los de otra versión.

Variantes conocidas del corpus que la especificación debe cubrir, con su origen:
`EM4000`↔`EM 4000` (§3.2 del plan), `TPR50`↔`TPR-50` (Fase 1.2),
`TOKIBAT 2007`↔`TOKIBAT – 2.007` (dos formas dentro del mismo PDF, hallazgo #5 de la
revisión).

---

## 4. Extractor: reglas de extracción

**Identificadores.** Se toman por forma y **posición**, no por familia sintáctica (esa
es la lección de H1 de Fase 0.5). Un token es candidato si es una corrida alfanumérica
en mayúsculas de 1–12 caracteres con separadores internos opcionales. Se clasifica su
`position`:

- `:labelled` — precedido por un término de etiqueta (`LED`, `serie`, `borne`, `terminal`, `conector`, `placa`, `pin`) o dentro de una enumeración encabezada por uno de esos términos;
- `:bare` — cualquier otro caso.

Un token **numérico desnudo** (`37`, `12`) cuenta como identificador **solo** si su
posición es `:labelled`. Sin esa condición, `p. 31`, `24 V` y `3 pasos` entrarían como
identificadores y el guard se volvería inusable. Es la regla que cubre `edel_k3_leds` y
`enier_mxl1_leds` sin agregar una rama por documento.

**Relación pedida.** Conjunto, por F4:

| Símbolo | Disparadores | Ejemplo del corpus |
|---|---|---|
| `:attribution` | indica, corresponde, señala, identifica, a qué serie | «¿a qué serie corresponde el LED SPM?» |
| `:state` | cuándo se enciende, condición normal, en fallo, apagado | «¿cuándo se enciende?» |
| `:connection` | conector, borne, terminal, cableado, en qué placa | «¿qué conectores documenta el encabezado?» |
| `:location` | en qué placa, dónde, en qué página | «¿en qué placa se encuentra?» |

**Identidad de equipo.** Hipótesis con confianza (auditoría §5.2, Regla 1). En Fase 1,
extraída de la pregunta, siempre `source: :lexical_fallback`, `confidence ≤ 0.4`.
Nunca se usa para **descartar** candidatos con esa confianza (§7, etapa 4).

---

## 5. Presupuesto de recuperación: descubrir amplio, entregar estrecho

`tpr50_spm` tiene su chunk objetivo en el rango **10**. Una consulta sin pin recibe hoy
`OPEN_RESULTS = 8` ([rag_retrieval_profile.rb:29](../app/services/rag_retrieval_profile.rb#L29)):
el chunk correcto **está fuera de la ventana**, así que ninguna mejora de selección
puede alcanzarlo. La recuperación tiene que ampliarse.

Decisión: cuando el selector está activo, el `top_k` de **descubrimiento** es
`MAX_RESULTS` (20) y el conjunto **final entregado al generador** es ≤ 5 contextos.

Esto no contradice §9 «No ampliar `top_k` globalmente»: lo que §9 prohíbe es enviar
veinte chunks al generador, y §3.2 lo autoriza explícitamente —«debe usarse para
descubrir candidatos y después reducirse a evidencia validada»—. El costo de generación
**baja**, porque hoy llegan hasta 8 chunks sin filtrar y con el selector llegan ≤ 5
validados. El costo de embedding del `Retrieve` es el mismo: una sola llamada.

Invariante a probar en Fase 6: `contextos_entregados ≤ 5` para las diez preguntas, y
`tokens_de_contexto` no mayor que el baseline de Fase 0.

---

## 6. API

```ruby
# app/services/rag/evidence_candidate_selector.rb
Rag::EvidenceCandidateSelector.new(
  analysis:,          # Rag::QueryAnalysis
  chunks:,            # Array<Hash> tal como los devuelve BedrockRagService#retrieve_chunks
  expander: nil       # Rag::SectionNeighborExpander, opcional (§7 etapa 5)
).select               # => Rag::EvidenceSelection

Rag::EvidenceSelection = Data.define(
  :mode,              # :direct | :ambiguous | :insufficient  (= resolution_mode de Fase 3)
  :contexts,          # Array<EvidenceContext>, ordenados por mejor rango del grupo
  :answered_relations,# Set<Symbol> — subconjunto de analysis.requested_relation con evidencia
  :abstained_relations,# Set<Symbol> — pedidas y NO documentadas (F4)
  :rejections,        # Array<Rejection> — auditoría, alimenta la telemetría de Fase 3
  :expansions,        # Array<Expansion> — qué se expandió y qué mecanismo lo autorizó
  :selector_version   # String — versionado del selector, exigido por Fase 3 punto 3
)

Rag::EvidenceSelection::EvidenceContext = Data.define(
  :section_key, :board_key, :label, :breadcrumb,
  :document_id, :source_uri, :page_number,
  :evidence_excerpt,   # frase del CUERPO que responde la relación
  :identifiers,        # Array<Identifier> presentes en la evidencia
  :relations_covered,  # Set<Symbol>
  :chunk_sha256, :rank, :match_reason
)

Rag::EvidenceSelection::Rejection = Data.define(:chunk_sha256, :stage, :reason)
```

`EvidenceContext` cumple el «contrato mínimo de evidencia» de §4 del plan. `breadcrumb`
se deriva de `section_key` → `board_key` → `canonical_name`, específico a general.
`rejections` es lo que permite cumplir el gate «ninguna respuesta de ausencia cuando el
dato existe en un chunk candidato»: si el modo es `:insufficient`, el rechazo dice en
qué etapa murió el chunk que sí tenía el dato.

---

## 7. Pipeline del selector — ocho etapas deterministas

**Etapa 1 · Alcance.** Ya resuelto aguas arriba (filtro de cuenta y pines). El selector
no reabre el alcance.

**Etapa 2 · Coincidencia contra el CUERPO, nunca contra metadata.** Los identificadores
y los términos de función se buscan solo en `chunk[:content]`. `metadata` y `aliases`
sirven para **agrupar y etiquetar**, jamás como evidencia.

Es la regla que corrige el defecto documentado en el propio código
([ambiguous_model_responder.rb:110-112](../app/services/rag/ambiguous_model_responder.rb#L110-L112)):
`ChunkMergerService#with_section_identity` **antepone `section_identity` a la lista de
alias de cada chunk que arrastra**, así que un chunk de la página de CTA puede llevar
`ALTIUS` en sus alias sin que la palabra aparezca en la página. Cualquier coincidencia
de fabricante que provenga de alias es, por construcción, no verificable.

**Etapa 3 · Puerta de relación, según modo.**

- *Modo directo* (la pregunta nombra el identificador): el cuerpo debe contener el identificador **y** una frase o registro que responda al menos una relación pedida. La mera presencia del código no basta — es lo que hoy permite ofrecer una página que solo lo menciona.
- *Modo inverso* (la pregunta nombra la función): el cuerpo debe contener el término de función **y** al menos un identificador en posición `:labelled`. El identificador se **extrae** de la evidencia; nunca se genera. Si la función aparece sin identificador asociado en la misma fila/fragmento, el candidato se rechaza con `reason: :function_without_identifier`.

El fragmento se delimita con el mismo criterio ya probado del guard —salto de línea,
`|` de fila de tabla, o fin de oración que no rompa un identificador
([answer_safety_processor.rb:236-241](../app/services/rag/answer_safety_processor.rb#L236-L241))—.
Reutilizarlo, no reinventarlo: ese split ya sobrevivió la regresión `CN-112.SC`.

**Etapa 4 · Puerta de fabricante/modelo, asimétrica.** Con `confidence ≥ 0.7` (solo
alcanzable desde metadata, no desde la pregunta) la puerta **excluye** familias ajenas.
Con confianza baja **no descarta nada**: marca `match_reason` y deja pasar. Descartar
con una hipótesis léxica es exactamente el bucle H2 de Fase 0.5 trasladado al selector.
Hasta que Fase 2 exista, esta puerta está en modo permisivo por diseño, no por olvido.

**Etapa 5 · Expansión de divisoria — reparación, no descubrimiento.** Se dispara solo
cuando un chunk pasa la identidad pero **falla la etapa 3** y es una divisoria.

*Detección de divisoria*, por forma y sin conocimiento del documento: el cuerpo tiene un
encabezado `## `, no contiene ninguna fila de tabla (`|`) ni bloque `FIELD_RECORD:`, y
su longitud está por debajo de un umbral.

*Autorización de la expansión*, por precedencia:

| Prioridad | Mecanismo | Disponible |
|---|---|---|
| 1 | `section_identity` igual entre divisoria y vecino | tras Fase 2 |
| 2 | **interino** — página contigua bajo el mismo `document_id`, y el vecino no declara un encabezado de sección distinto | hoy |

*Obtención del vecino sin una segunda llamada `Retrieve`.* Los chunks se escriben como
`bulk_chunks/{account_id}/{document_uid}/chunk_p{page}_{n}.txt` + su
`.metadata.json` ([batch_results_parser_service.rb:28,381-387](../app/services/batch_results_parser_service.rb#L381-L387)),
de modo que la página vecina se lee con un GET de S3 sobre una clave derivada. No es
otra llamada al KB, no hay embedding nuevo, no hay LLM. `Rag::DocumentOverviewBuilder`
([:72-101](../app/services/rag/document_overview_builder.rb#L72-L101)) ya estableció ese
patrón en el camino de request, con tope de chunks y manifiesto persistido — el
expansor **reutiliza ese índice** en vez de agregar un recorrido de S3 propio.

Tras expandir, se vuelve a correr la etapa 3 sobre el vecino. Si tampoco responde, se
rechaza; la expansión no es una licencia para entregar la divisoria.

Cada expansión se registra en `expansions` con el mecanismo que la autorizó, para poder
**medir cuántas veces se usó el interino** y borrarlo cuando el backfill lo vuelva
innecesario. Sin esa medición, el andamiaje se queda para siempre.

**Etapa 6 · Agrupación.** Clave compuesta `(section_key, board_key)`:

- `section_key` ← `section_identity` (metadata) → etiqueta del encabezado `## ` del chunk → `nil`;
- `board_key` ← `model_key` + `variant` del §3.

Placas hermanas (`EM2000` / `EM3000` / `EM4000 V1`) caen en `board_key` distintos dentro
de la misma sección: se agrupan sin mezclarse, y **ningún hecho cruza de `board_key`**.
Es la barrera que impide que los `CN7/CN8` de EM2000 aparezcan como conectores de
EM4000 — el fallo crítico que la rúbrica v2.1 penaliza.

**Etapa 7 · Modo.**

| Grupos supervivientes | Modo |
|---:|---|
| 1 | `:direct` |
| ≥ 2 | `:ambiguous` |
| 0 | `:insufficient` |

**El umbral de ambigüedad baja de 3 a 2.** Hoy `MIN_DISTINCT_MODELS = 3`
([ambiguous_model_responder.rb:9](../app/services/rag/ambiguous_model_responder.rb#L9))
exige tres modelos distintos para preguntar. Pero `elecmegon_obstaculo_ambiguo` tiene
exactamente **dos** contextos documentados (EM2000 con LED `AP`, EM3000 con conector
`CN`) y es el caso de ambigüedad canónico de la cohorte. Dos contextos documentados que
se contradicen **son** ambigüedad; con el umbral en 3 el sistema elegiría uno en
silencio. El umbral de 3 solo tenía sentido cuando el disparo venía de vocabulario
faltante y había que evitar preguntar de más.

En `:insufficient` la respuesta pide el dato que falta y **no declara una ausencia
global** — `rejections` dice exactamente qué faltó.

**Etapa 8 · Recorte final.** Se entregan al generador los ≤ 5 mejores contextos. El
payload de Fase 3 conserva **todos** los grupos: el tope de tres tarjetas es visual y
el backend no descarta candidatos válidos por él.

---

## 8. Cobertura caso por caso de la cohorte v2

Qué etapa resuelve cada caso y de qué depende. Es la traza que Fase 6 debe convertir en
Minitest.

| Caso | Modo | Rango hoy | Etapa que lo resuelve | Depende de |
|---|---|---:|---|---|
| `altius_d8_d11` | directo | 1 | 2 + 3 | — |
| `tpr50_spm` | directo | 10 | **§5 descubrimiento a 20** + 2 + 3 | top_k de descubrimiento |
| `cta_sr8p_sph` | inverso | 1 | 3 inverso (función→identificador) + relación `:location` | F4 |
| `em2000_leds_seguridad` | inverso | 3 | 3 inverso, multi-identificador | la puerta no se detiene en el primero |
| `em4000_obstaculo_conectores` | inverso | 7 | **6 barrera de `board_key`** | normalización §3 (`V1` como `variant`) |
| `edel_k3_leds` | directo | 1 | 2 + 3, identificadores numéricos `:labelled` | §4 regla de posición |
| `tokibat_dl27_v2` | directo | 1 | 3 + **abstención de `:state`** | F4 |
| `enier_mxl1_leds` | directo | **>20** | **5 expansión de divisoria** (divisoria en 3) | mecanismo interino hasta Fase 2 |
| `thyssen_serie_e_leds` | inverso | 6 | 3 inverso + abstención de `:state` | F4 |
| `elecmegon_obstaculo_ambiguo` | inverso | — | **7 umbral 2** | umbral 3→2 |

Los tres casos con dependencia estructural son `tpr50_spm` (presupuesto),
`enier_mxl1_leds` (expansión) y `em4000_obstaculo_conectores` (barrera de hermanos). El
resto lo resuelve la puerta de relación.

---

## 9. Riesgos y límites

1. **`enier_mxl1_leds` es el único caso que depende del mecanismo interino.** Si la expansión por página contigua se considera inaceptable, ese caso no cierra hasta Fase 2 y hay que decirlo en el gate en vez de forzarlo. No inventar una regla por documento para taparlo.
2. **La etapa 4 en modo permisivo tolera un candidato de familia ajena** que la etapa 3 no haya filtrado. La mitigación no es endurecerla con hipótesis léxicas, sino que un modo `:ambiguous` con tarjetas de evidencia es una salida **correcta** cuando el sistema no puede decidir: el técnico ve el extracto y elige.
3. **El extractor sigue siendo léxico.** Fase 1 no lo elimina: lo acota a normalización y posición, y le quita la autoridad para descartar. La autoridad se traslada a la evidencia.
4. **Latencia de la expansión.** Un GET de S3 en el camino del request. Acotar a ≤ 2 páginas vecinas por consulta y reutilizar el manifiesto cacheado; medir contra el p95 del baseline (gate: sin regresión > 15%).
5. **No cubierto por diseño:** el retiro de R1/R3, que sigue bloqueado por Fase 2.

---

## 10. Handoff

**Fila Sonnet de Fase 1** («implementación de normalización de variantes»): §3 es la
especificación cerrada. Entregar `Rag::QueryEntities` con los pliegues permitidos, las
cuatro prohibiciones como controles negativos, y las tres variantes del corpus como
casos positivos. No implementar el selector todavía.

**Tests que exige el selector** (Fase 6, criterios explícitos):

1. Un candidato cuya única coincidencia de fabricante está en `aliases` se rechaza con `reason: :metadata_only_match` (etapa 2).
2. Modo inverso: función presente sin identificador en el mismo fragmento → `:function_without_identifier`.
3. `tokibat_dl27_v2`: `answered_relations == [:attribution]` y `abstained_relations == [:state]`.
4. `em4000_obstaculo_conectores`: ningún `EvidenceContext` de `board_key` EM2000 entra en el grupo de EM4000 V1, aun cuando `CN7/CN8` aparezcan en el conjunto recuperado.
5. `EDEL-K2` y `EDEL-K3` producen `board_key` distintos; `EM 4000` y `EM4000` el mismo; `EM4000 V1` un `variant` distinto.
6. `elecmegon_obstaculo_ambiguo` con dos grupos → `mode == :ambiguous` (regresión del umbral 3→2).
7. La expansión de divisoria nunca cruza `section_key`, y registra su mecanismo en `expansions`.
8. `:insufficient` con `rejections` no vacío para toda pregunta cuyo dato exista en un candidato — el gate de «ausencia falsa».
9. `contexts.size <= 5` en las diez preguntas.

**Orden sugerido:** normalización (Sonnet) → selector en sombra comparando contra el
camino actual sobre las tres cohortes → conmutación detrás del feature flag «selector de
evidencia» de §7 del plan.

---

## 11. Correcciones que este documento impone

**Al plan:**

1. **§8** — `app/services/rag/query_entities.rb` es el **extractor** que construye `Rag::QueryAnalysis`, no un contrato paralelo (§2).
2. **Fase 1 punto 2** — la normalización de variantes necesita `model_key` + `variant` separados, y cuatro pliegues prohibidos con un caso del gate detrás de cada uno (§3).
3. **Fase 1 punto 3** — el modo inverso es la mitad de la cohorte, no una excepción (F3), y necesita su propia regla de selección.
4. **Fase 1 punto 4** — el vínculo divisoria→contenido ya existe como `section_identity` (`ChunkMergerService`, `field_records_v7`); lo que Fase 1 aporta es un mecanismo interino medido, porque SEGURIDADES es `v5` (F2).
5. **Fase 1 punto 5** — hacer explícito el presupuesto asimétrico: descubrimiento 20, entrega ≤ 5, con la justificación contra §9 (§5). Sin esto `tpr50_spm` es inalcanzable.
6. **Fase 3** — el umbral de ambigüedad es **2** grupos documentados, no 3 (§7 etapa 7).
7. **Fase 2** — el backfill es de `section_identity`; no crear claves `manufacturer`/`controller_model`/`board_model` que ningún escritor produce (F1, F2).

**A la auditoría de Fase 0.5:**

8. **§3.1, R2** — `MODEL_PATTERN` es inalcanzable en producción (F1): retiro por eliminación pura en P1, no bloqueado por Fase 2.
9. **§5.1** — `requested_relation` pasa de `Symbol` a `Set<Symbol>` (F4).
10. **§7.2** — el test `ambiguous_model_responder_test.rb:28-45` ejercita una rama inalcanzable; debe migrar al mecanismo de `section_key`, no borrarse.
