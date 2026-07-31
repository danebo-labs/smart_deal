# Plan correctivo RAG SEGURIDADES v2 — post Paso G

**Fecha:** 2026-07-30.
**Estado:** revisado el 2026-07-30 por una segunda IA. Veredicto: **RECHAZADO como estaba
escrito**. Esta versión incorpora los cambios obligatorios P0/P1 de esa revisión y queda apta
para implementación por fases.
**Secciones corregidas por la revisión:** §3.2 (fila nueva de etapa 2 y dos filas precisadas),
§3.4 (nueva), §4, §5.1–§5.5, §6 (C0–C6), §7, §9, §11, §12, §13.
**Base evaluada:** `main` en `647d4db`; código del Paso G en `85b7d42`; producción
continúa en `7c5e954` según el diagnóstico.
**Documento origen:** [RAG_PRECISION_V2_PLAN_2026-07-29.md](RAG_PRECISION_V2_PLAN_2026-07-29.md).
**Diagnóstico de entrada:** [RAG_SEGURIDADES_PASO_G_DESPUES_2026-07-30.md](RAG_SEGURIDADES_PASO_G_DESPUES_2026-07-30.md).

## 1. Propósito y decisión

Este plan sustituye **solo el trabajo pendiente desde el NO-GO del Paso G**. No
reinicia las fases ya ejecutadas ni invalida su evidencia histórica.

La decisión sigue siendo:

- no desplegar el selector actual;
- no activar `RAG_EVIDENCE_SELECTOR_ENABLED`,
  `RAG_EVIDENCE_EXPANSION_ENABLED` ni `RAG_EVIDENCE_CARDS_ENABLED`;
- mantener `SHOW_RAG_SOURCES=false`;
- no ejecutar otro backfill, reingesta ni sincronización del Knowledge Base;
- corregir y certificar primero la resolución de alcance y de hechos técnicos.

`section_identity` ya está sincronizado en los 97 chunks de SEGURIDADES y la
expansión ENIER p. 35 → p. 36 funciona. El siguiente trabajo es exclusivamente de
selección, representación de hechos, integración y medición.

## 2. Objetivos heredados que no cambian

El plan se considera terminado solo si logra simultáneamente los objetivos del plan
original:

1. Responder correctamente las nueve consultas directas de la cohorte v2.1.
2. Resolver la consulta Elecmegon como ambigua, sin presentar equipos ajenos.
3. No mezclar fabricantes, modelos, placas, filas ni relaciones.
4. Abstenerse de condiciones ON/OFF, normal/fallo u otros estados no documentados.
5. Asociar cada afirmación técnica con documento, página, chunk y extracto real.
6. Mantener una sola llamada `Retrieve` y ninguna llamada LLM adicional en las
   consultas que puedan resolverse como hechos estructurados.
7. Mantener costo y latencia dentro de los gates del plan original.
8. Preservar las cohortes certificadas v3.2 y v1.2.
9. Mantener una UX móvil útil y una ruta de reversión por feature flag.

## 3. Estado comprobado y causas del NO-GO

### 3.1 Lo que sí quedó resuelto

- El job `D3QMVZNBEH` terminó y modificó únicamente metadata.
- `section_identity` aparece en 160/160 conjuntos recuperados de la Config B.
- Las páginas y rangos de Retrieve son estables.
- ENIER usa `section_identity`, no `adjacent_page_interim`, para llegar a p. 36.
- No se observaron invenciones críticas en la corrida end-to-end posterior.
- La infraestructura de tarjetas, telemetría, visibilidad de fuentes y transporte
  acotado ya existe detrás de flags apagados.

### 3.2 Defectos bloqueantes del selector actual

| Defecto | Evidencia verificable | Efecto |
|---|---|---|
| La etapa 2 rechaza por una unión de aliases de documento | `metadata_only_match?` (`evidence_candidate_selector.rb:152-164`) lee `chunk[:metadata]["aliases"]` creyendo que son aliases de chunk; los 97 sidecars llevan la misma unión de nivel documento (97/97 mencionan «ALTIUS»). Artefacto: `altius_d8_d11` → `rejection_reasons: {"metadata_only_match": 19}` en 5/5 corridas | Una pregunta que nombre cualquiera de esos 15 términos descarta 19 de 20 candidatos antes de que corran scope, relación y expansión |
| El alcance técnico no llega al selector | `Rag::QueryEntities.analyze` deja `manufacturer`, `model` y `board` en `nil`; `EvidenceCandidateSelector` declara la etapa de scope “resuelta upstream”, pero upstream solo resuelve cuenta/documento | TPR50, SR8P, EM2000, EM4000 V1, EDEL-K3, MXL1 y Serie E conservan placas ajenas |
| La puerta de familia nunca puede excluir | `QueryEntities.analyze` (`query_entities.rb:79-88`) fija siempre `manufacturer: nil` y `confidence: {}`; en `family_excluded?` (`:138-146`) ambos guardas retornan `false` | La etapa 4 es código muerto: una identidad explícita escrita por el técnico no restringe nada |
| La relación se valida por longitud | `responds_to_relation?` acepta cualquier fragmento de tres palabras | Encabezados, aliases y conteos de pines pasan sin responder la pregunta |
| Metadata de transporte se usa como evidencia | Los artefactos de Paso G seleccionan `[SEARCH_ALIASES: ...]` como `evidence_excerpt` en ALTIUS p. 7, TPR50 p. 9, TOKIBAT p. 40, Thyssen p. 93, EDEL-542 p. 24, EM3000 hidráulico p. 30 y EM2000 hidráulico p. 32 | La tarjeta no contiene el hecho técnico que afirma respaldar; los dos únicos `direct` de v2.1 se apoyan en esa línea |
| Los números se aceptan en cualquier contexto del cuerpo | Para un objetivo numérico, `find_identifier_in_body` busca el número aislado en cualquier fragmento | ENIER 12/19 mezcla conectores de 12 pines, bornes y listas de otros equipos |
| El modo inverso usa coincidencia de una sola palabra | `function_match?` usa `keywords.any?` | “puertas”, “obstáculo” o “condición” dejan pasar páginas no relacionadas |
| Se retorna el primer hecho y se detiene | `evaluate_direct` y `evaluate_inverse` retornan al primer fragmento válido | D8+D11, 12+19, L9+L8+L7 y los cuatro LEDs EM2000 quedan incompletos |
| La agrupación no equivale a identidad de placa | `board_key` concatena identificadores de un encabezado libre | Aparecen claves como `S7 DIAGRAM`, `EM` o `ALTIUSJ3 J5 J6`; no son un scope estable |
| No se deduplican hechos/contextos antes de decidir el modo | TPR50 p. 9 entra por Retrieve y nuevamente por expansión | Se altera el conteo de contextos y la telemetría |
| El recorte conserva primero el rango, no la completitud | Se toman los primeros cinco sobrevivientes | Falsos positivos desplazan la evidencia correcta |
| La ruta es solo sombra | `RagController#build_resolution` ejecuta el selector después de la respuesta viva | El score end-to-end sigue 6/10 aunque el selector encuentre ENIER p. 36 |
| La sombra agrega una llamada externa síncrona | La respuesta viva usa `retrieve_and_generate` y el controlador ejecuta otro `Retrieve` | No es una arquitectura aceptable para activar en tráfico normal |

### 3.3 Corrección al diagnóstico por capas

El problema ya no debe describirse solo como “scope + relation gate”. Hay cuatro
capas pendientes:

1. **Análisis de consulta:** distinguir alcance, identificadores, objetos pedidos y
   relaciones.
2. **Lectura del chunk:** separar identidad estructural, metadata de transporte y
   evidencia técnica.
3. **Resolución de hechos:** producir todos los hechos solicitados, no un extracto
   genérico por chunk.
4. **Ruta viva:** renderizar esos hechos de forma determinista o mostrar
   desambiguación, sin hacer dos recuperaciones.

### 3.4 Correcciones al diagnóstico de entrada

Dos números del Paso G se corrigen aquí; su documento no se reescribe, este plan es la fuente
viva:

1. `elecmegon_obstaculo_ambiguo` entrega **3/5** tarjetas Elecmegon, no 2/5: OTIS p. 67,
   ELECMEGON p. 29, ELECMEGON p. 30, RECOBA p. 74, ELECMEGON p. 31, idéntico en 5/5 corridas.
   El gate de C3 se mide contra 3/5.
2. Los dos `direct` de v2.1 son **falsos positivos**, no aciertos parciales: su
   `evidence_excerpt` es una línea `[SEARCH_ALIASES: …]`, y `altius_d8_d11` sólo cubre D8
   porque `evaluate_direct` retorna al primer identificador válido
   (`evidence_candidate_selector.rb:180`). El baseline de C0 los registra como fallo.

## 4. Arquitectura objetivo corregida

```text
pregunta técnica elegible + documento fijado
  → QueryAnalysis v2
      alcance explícito
      identificadores objetivo
      objetos/funciones objetivo
      relaciones pedidas
  → Retrieve único, top_k=20
  → deduplicar chunks
  → ChunkEvidenceParser
      zona de identidad
      unidades de evidencia
      metadata de transporte excluida
  → TechnicalScopeResolver
      validar el alcance contra identidad estructural
  → TechnicalFactExtractor
      hechos atómicos, tipados y verbatim
  → EvidenceCandidateSelector v2
      filtrar scope
      exigir relación
      comprobar completitud
      agrupar sin mezclar placas
  → direct: EvidenceAnswerRenderer, sin LLM
  → ambiguous: tarjetas con hechos y selección de contexto
  → insufficient: pedir el dato faltante o abstenerse, sin ausencia global falsa
  → not_applicable: ruta RAG existente
```

Esta ruta se aplica inicialmente solo a consultas de mapeo técnico estructurado:
LED/serie, identificador/función, conector/componente, placa/ubicación y estado
documentado. El resto de las consultas conserva `retrieve_and_generate`.

`top_k=20` es el contrato de descubrimiento de esta ruta y sustituye a
`RagRetrievalProfile#number_of_results` **sólo** dentro de ella;
`RagRetrievalProfile::MAX_RESULTS` sigue siendo el techo y no se supera. Una consulta que
`RagRetrievalProfile#safety_critical_query?` clasifique como safety-critical **no es elegible**
para la ruta estructurada: conserva su perfil reducido y su directiva STOP-WORK por el camino
existente. Esta excepción se documenta aquí para no contradecir la regla de recuperación
adaptativa de `AGENTS.md` §Cost And Latency.

## 5. Contratos nuevos

### 5.1 `Rag::QueryAnalysis` v2

El extractor no debe intentar conocer una lista cerrada de fabricantes. Debe extraer
spans y validarlos después contra los chunks recuperados.

Contrato mínimo:

```ruby
QueryAnalysis = Data.define(
  :intent,
  :scope_mentions,
  :target_identifiers,
  :requested_objects,
  :requested_relations,
  :question
)

ScopeMention = Data.define(:raw, :key, :role_hint, :polarity, :source_span)
RequestedObject = Data.define(:terms, :operator, :position, :required)
```

Reglas:

- `scope_mentions` captura expresiones introducidas por “en”, “modelo”, “placa”,
  “serie”, “de” y equivalentes, sin decidir aún que sean verdad.
- `polarity` distingue el alcance pedido de exclusiones como “no EM3000”.
- Un código alfanumérico técnico puede ser objetivo aunque no repita “LED”
  inmediatamente antes. Esto cubre L9/L8/L7.
- Un número desnudo solo es objetivo cuando está gobernado por una etiqueta técnica
  en la misma cláusula o enumeración. Esto cubre 37/39/41 y 12/19 sin convertir
  páginas, voltajes o cantidades en LEDs.
- `requested_objects` conserva por separado listas como “seguridades principales,
  puertas, cerraduras y obstáculo”; no se reduce a una bolsa de palabras.
- `requested_relations` continúa siendo un conjunto y puede contener atribución +
  estado o atribución + ubicación.
- El extractor de spans es **uno solo y se comparte con el lado del chunk**: la misma ventana
  multitoken se normaliza en la pregunta y en el encabezado de la página. `QueryEntities`
  tokeniza hoy por `\S+` (`query_entities.rb:99`) y `fold` (`:58`) sólo une separadores dentro
  de un token, por lo que `EM 2000` produce `EM` y el `board_key` observado en Paso G para
  p. 31 es literalmente `"EM"`. Sin span multitoken, EM2000/EM3000/EM4000 V1 no son
  distinguibles.
- `split_variant` (`:40`, `:69`) sólo reconoce sufijos `V\d+`. Un calificativo de placa que no
  sea versión no se fusiona ni se ignora: se conserva en el span como parte de la identidad a
  comparar, sin convertirse en vocabulario técnico dentro del código.
- La normalización actual de EM4000/EM 4000, TPR50/TPR-50 y TOKIBAT 2007/2.007 se
  conserva, junto con sus controles negativos.

### 5.2 `Rag::ChunkEvidenceParser`

Debe parsear una vez el contenido y entregar zonas explícitas:

```ruby
ChunkView = Data.define(
  :identity_units,
  :evidence_units,
  :transport_units,
  :metadata
)

EvidenceUnit = Data.define(
  :kind,          # table_row | field_record | evidence_heading | prose
  :fields,
  :excerpt,
  :position
)
```

Clasificación obligatoria:

- `[DOCUMENT]`, `[SOURCE_URI]`, `[SEARCH_ALIASES]`: transporte; nunca evidencia.
- `**Document:**`, `**Section:**`, `**Page:**`: atribución/scope; nunca hecho.
- primer `##`: identidad visible de página/placa. Es evidencia sólo cuando contiene sujeto,
  relación y valor en la misma línea.
- `###` / `####`: `evidence_heading`. Son evidencia de primera clase cuando contienen sujeto,
  relación y valor. Es obligatorio: en p. 33 `XC4`/`XC7` no aparecen en ninguna fila de tabla,
  sólo en `### OBSTÁCULO — Conectores XC4 y XC7 en Placa EM4000 V1`, en la nota en prosa y en
  los `FIELD_RECORD`. Autorizar sólo el primer `##` haría el gate C2 inalcanzable.
- filas de tabla: evidencia preferida, **con roles de celda explícitos**. El identificador debe
  ocupar la celda de identificador de la fila; un identificador que sólo aparece dentro de una
  celda de lista o de valor no sostiene un hecho. El valor es la primera celda siguiente que no
  esté vacía ni sea puramente decorativa. Caso obligatorio: en p. 26 conviven
  `| JH2 | Magenta/Pink | SC, 37, 38, 39, 40 |` — que el selector de Paso G eligió como
  evidencia de `edel_k3_leds` — y `| 37 | 🔴 | PUERTAS HUECO |`, cuyo valor está en la tercera
  celda porque la segunda es un emoji.
- `FIELD_RECORD`: evidencia estructurada secundaria; usar campos concretos, no el
  bloque entero.
- prosa: fallback únicamente cuando contiene sujeto, relación y valor en el mismo fragmento.
  Una frase que declara `DATA_NOT_AVAILABLE` —presente en p. 33 para APC, POS, NVI y AP— nunca
  produce un hecho.
- `metadata["aliases"]` **no es una zona de chunk y no participa en ninguna decisión**: ni
  admite ni rechaza candidatos, ni valida alcance, ni sostiene evidencia. Los 97 sidecars de
  SEGURIDADES llevan la misma unión de aliases de nivel documento.

El parser reutiliza lo que ya existe y no crea una cuarta interpretación del header de ingesta:

1. `Bedrock::CitationProcessor::HEADER_PATTERN` (`:134`) y `METADATA_LINE_PATTERN` (`:144`) para
   las reglas de exclusión de header y de líneas de metadata;
2. `Rag::FieldRecordParser` para los bloques `FIELD_RECORD`, con su contrato estricto de
   etiquetas obligatorias, dedupe por `RECORD_ID` y detección de conflicto de ledger;
3. `Rag::AnswerSafetyProcessor.fragments` (`:65-67`) como splitter de fragmentos, que es el que
   el selector actual ya usa.

### 5.3 `Rag::TechnicalScopeResolver`

Entrada: `QueryAnalysis` + `ChunkView[]`.
Salida:

```ruby
ScopeResolution = Data.define(
  :mode,                 # unique | ambiguous | unresolved
  :matched_context_keys,
  :matches,
  :rejections
)
```

Fuentes autorizadas para validar alcance:

1. `section_identity`;
2. primer encabezado `##` de la página;
3. etiqueta visible de una divisoria y su vecino autorizado;
4. nombre/modelo explícito dentro de una unidad técnica.

`canonical_name`, `metadata["aliases"]` y `SEARCH_ALIASES` no pueden demostrar identidad de
placa ni descartar un candidato. El `canonical_name` de este documento es
`ALJO Control Level 1B Altius` en los 97 chunks, incluidas las páginas de ENIER, y
`metadata["aliases"]` es una unión de nivel documento idéntica en los 97 sidecars.

La coincidencia de alcance se hace con el extractor de spans multitoken de §5.1, el mismo en la
pregunta y en el encabezado del chunk. Comparar tokens sueltos no sirve: `EM 2000` produce el
token `EM`.

Reglas:

- Si la pregunta nombra un alcance y una única familia/modelo recuperada lo valida,
  se excluyen contextos que no lo validan.
- Si solo nombra fabricante/sección —Elecmegon— se conservan sus modelos hermanos y
  se excluyen secciones ajenas.
- Si dos contextos validan exactamente el mismo alcance, el resultado permanece
  ambiguo; no se elige por rango.
- Si ningún contexto valida el alcance, no se inventa una coincidencia: el resultado
  es `unresolved`.
- La coincidencia debe soportar variantes normalizadas, pero no fusionar versiones o
  placas distintas.
- La clave de contexto se deriva de documento + sección + identidad de equipo
  normalizada; la página identifica evidencia, no una placa nueva.
- Los prefijos de formato como `S7 — DIAGRAM:` se eliminan mediante reglas del
  contrato de chunk, no mediante reglas por fabricante.
- El resolver puede compartir tokenización con `PinnedEntityScopeResolver`, pero
  documento y placa siguen siendo niveles distintos y no deben compartir la misma
  decisión.

### 5.4 `Rag::TechnicalFact`

El selector debe operar sobre hechos, no sobre chunks o extractos sueltos:

```ruby
TechnicalFact = Data.define(
  :subject,
  :relation,
  :value,
  :equipment_context_key,
  :section_key,
  :document_id,
  :source_uri,
  :page_number,
  :chunk_sha256,
  :source_kind,
  :evidence_excerpt,
  :rank
)
```

Invariantes:

- sujeto y valor aparecen en la misma unidad de evidencia;
- `evidence_excerpt` no proviene de una zona de transporte;
- el identificador debe ocupar la celda/posición de identificador de su unidad de evidencia, no
  estar meramente presente como pin, borne, cantidad o elemento de una lista de valores; el
  valor es la primera celda siguiente no vacía y no decorativa;
- la relación es específica: atribución, conexión, ubicación o estado;
- un hecho de una placa nunca cambia de `equipment_context_key`;
- duplicados se eliminan por contexto + sujeto + relación + valor + chunk;
- el renderer solo puede emitir sujeto/valor verbatim y frases UI localizadas.

### 5.5 `Rag::EvidenceSelection` v2

Debe agregar:

- `facts`;
- `missing_targets`;
- `scope_resolution`;
- `contexts` agrupados por hechos completos;
- razones de rechazo por `scope`, `zone`, `relation`, `numeric_role`,
  `incomplete_target` y `duplicate`.

Reglas de modo:

- `direct`: un solo contexto técnico validado y todos los objetivos obligatorios
  respondidos; una relación de estado puede quedar explícitamente abstendida.
- `ambiguous`: dos o más contextos técnicos válidos con **hechos discrepantes** después de
  aplicar el alcance y el colapso por identidad de hechos.
- `insufficient`: alcance válido pero faltan hechos requeridos.
- `not_applicable`: la pregunta no pertenece al contrato estructurado.

**Colapso por identidad de hechos.** Si dos o más contextos válidos producen exactamente el
mismo conjunto de hechos —igual `subject`, `relation` y `value`— se resuelven como un único
hecho con varias evidencias (`supporting_evidence[]`), no como ambigüedad. La ambigüedad exige
hechos **discrepantes**, no contextos múltiples. Caso obligatorio: p. 31 (EM 2000 eléctrico) y
p. 32 (EM 2000 hidráulico) documentan las mismas cuatro filas SEG/SCE/SCC/AP; sin esta regla
`em2000_leds_seguridad` sería ambiguo por construcción y su gate no podría cerrar. El colapso
nunca cruza `equipment_context_key` distintos con valores distintos.

`EvidenceSelection` v2 añade `supporting_evidence[]` por hecho y la razón de rechazo
`numeric_role` para un identificador hallado fuera de su celda de identificador.

El modo no se decide contando chunks ni contextos. Se decide contando **hechos completos
distintos** dentro del alcance validado.

## 6. Plan de ejecución

### Fase C0 — Congelar el fallo y crear replay determinista

1. No modificar las tres rúbricas existentes.
2. Registrar como baseline:
   - v3.2 = 12/12;
   - v1.2 = 10/10;
   - v2.1 = 6/10;
   - modos y contextos del selector de Paso G, registrando que `altius_d8_d11` y
     `tokibat_dl27_v2` figuran como `direct` pero son **falsos positivos** (excerpt de
     transporte; ALTIUS sólo cubre D8) y que `elecmegon_obstaculo_ambiguo` entrega 3/5
     tarjetas Elecmegon;
   - commit, flags, KB, data source e ingestion job.
3. Crear un fixture compacto de replay, **construido y ejecutable offline, sin AWS**, con los
   chunks necesarios para reproducir cada falso positivo de Paso G. Fuentes locales exactas:
   - cuerpos: `tmp/seguridades_chunks_2026-07-28/chunk_*.txt`;
   - metadata base: los sidecars `*.metadata.json` del mismo directorio;
   - `section_identity`: **no está en las copias locales** (0/97, son anteriores al backfill).
     Se reconstruye desde el campo `section_identity_after` de
     `tmp/rag_seguridades_section_identity_backfill_diff_2026-07-29.json`. Sin este paso el
     replay de ENIER ejercitaría `adjacent_page_interim`, que §7 prohíbe.
   El fixture conserva header real de ingesta, encabezado de identidad, fila o fragmento
   técnico, metadata, rango y hash del chunk original.
4. Incluir al menos estos distractores:
   - TPR50 vs SISTEL;
   - SR8P vs CR8PH2/M8PC;
   - EM4000 vs EM2000/EM3000, y EM 2000 eléctrico vs EM 2000 hidráulico con hechos idénticos;
   - EDEL-K3 vs EDEL-K2/EDEL-542;
   - la fila `| JH2 | Magenta/Pink | SC, 37, 38, 39, 40 |` de p. 26 frente a
     `| 37 | 🔴 | PUERTAS HUECO |`, en la misma página y la misma tabla;
   - `### OBSTÁCULO — Conectores XC4 y XC7 …` de p. 33, cuya evidencia no es una fila de tabla;
   - ENIER 12/19 vs conectores/listas numéricas;
   - Thyssen vs una frase ajena con “condición”;
   - Elecmegon vs OTIS/RECOBA;
   - una pregunta que nombre un término de la unión de aliases del documento, para fijar que
     ningún candidato se rechaza por `metadata["aliases"]`.
5. Añadir una prueba que falla con `evidence_candidate_selector_v1` y reproduce los
   modos del diagnóstico.
6. No se caracteriza la ruta sombra: C5 la retira. Su comportamiento queda cubierto por la
   aserción de conteo de `retrieve_chunks` del Gate C5.

**Gate C0:** replay ejecutable offline, sin AWS, que reproduce los defectos de
selección, más caracterización de la ruta sombra. No se cambia aún ninguna expectativa
productiva.

### Fase C1 — Análisis de consulta y alcance técnico

1. Evolucionar `QueryAnalysis` y `QueryEntities`.
2. Implementar `TechnicalScopeResolver`.
3. Reutilizar la normalización existente; no introducir nombres de equipos en código.
4. **Retirar la etapa 2** (`metadata_only_match?`). No se evoluciona: se elimina, y la
   separación de zonas del parser (§5.2) ocupa su lugar. Añadir un test que falle si cualquier
   decisión del pipeline lee `metadata["aliases"]`.
5. Convertir en tests las expectativas correctas:
   - una pregunta explícita por SR8P excluye CR8PH2;
   - EDEL-K3 excluye EDEL-K2;
   - EM4000 V1 excluye EM2000/EM3000;
   - TPR50 de Carlos Silva excluye SISTEL;
   - ENIER MXL1 excluye secciones con pines 12/19;
   - Elecmegon conserva varios modelos Elecmegon.
6. Cambiar los tests actuales que consideran “ambigüedad segura” ante un modelo
   explícito. Después de validar el scope, esa ambigüedad es un fallo de precisión.
7. Mantener casos ficticios NOVARIS y agregar variantes de mayúsculas, guiones y
   orden de fabricante/modelo.

**Gate C1:**

- 9/9 consultas directas resuelven un único scope esperado;
- Elecmegon conserva únicamente scopes `section_identity=ELECMEGON`;
- 0 nombres de fabricantes/modelos nuevos en el código productivo;
- 0 candidatos rechazados por `metadata["aliases"]`;
- una pregunta que nombre un término de la unión de aliases del documento conserva sus 20
  candidatos hasta las etapas de scope y relación;
- preguntas sin alcance explícito continúan ambiguas cuando corresponde.

### Fase C2 — Parser de evidencia y extracción de hechos

1. Implementar `ChunkEvidenceParser`.
2. Implementar `TechnicalFactExtractor`.
3. Retirar el criterio “tres palabras” como demostración de relación.
4. Para modo directo:
   - buscar cada identificador solicitado;
   - exigir sujeto y valor en la misma fila/unidad;
   - producir un hecho por identificador y relación.
5. Para modo inverso:
   - comparar cada objeto/función solicitada como grupo;
   - extraer el identificador solo de la misma fila/unidad;
   - exigir la relación adecuada según headers o etiqueta explícita.
6. Para preguntas multiobjetivo, no retornar al primer match.
7. Usar prioridad:
   - fila de tabla;
   - encabezado técnico explícito;
   - `FIELD_RECORD` estructurado;
   - prosa co-localizada.
8. Un `EXPECTED_RESULT` de un `FIELD_RECORD` no demuestra por sí solo una condición
   de estado. La misma condición debe estar presente en `EVIDENCE` o en otra unidad
   técnica explícita; esto impide promover frases inferidas como “LED activo”.
9. Prohibir como evidencia:
   - `SEARCH_ALIASES`;
   - headers Document/Section/Page;
   - una frase de descripción general que solo menciona el tema;
   - números sin rol técnico compatible.
10. Hacer que el extracto mostrado sea exactamente la unidad que sostiene el hecho.

**Gate C2:**

- 0 facts/excerpts provenientes de transporte;
- `false_rejection_rate=0%`: ningún chunk que contenga un hecho solicitado se descarta antes de
  las etapas de scope y relación;
- 0 falsos positivos numéricos del replay;
- cobertura completa de D8+D11, 12+19, 37+39+41, L9+L8+L7 y los cuatro LEDs
  EM2000;
- XC4 y XC7 provienen del `###` técnico de EM4000 V1 en p. 33, no de una fila de tabla ni de la
  línea de aliases;
- `edel_k3_leds` no puede usar la fila `| JH2 | … | SC, 37, 38, 39, 40 |` como evidencia;
- la prosa `DATA_NOT_AVAILABLE` de p. 33 no produce ningún hecho;
- la prueba de una función sin identificador sigue devolviendo insuficiente.

### Fase C3 — Selector v2 y completitud

1. Integrar scope y facts en `EvidenceCandidateSelector`.
2. Incrementar `SELECTOR_VERSION` a `evidence_candidate_selector_v2`.
3. Deduplicar chunks recuperados/expandidos antes de evaluar el modo. En Paso G, TPR50 p. 9
   sobrevive dos veces (rango 1 por expansión, rango 10 por Retrieve) y EDEL-542 p. 24 también,
   gastando dos de los cinco huecos de `MAX_CONTEXTS`.
4. Aplicar el colapso por identidad de hechos de §5.5 antes de decidir el modo.
5. Mantener expansión por `section_identity`; retirar para SEGURIDADES el fallback
   interino como mecanismo efectivo.
   El índice `page → chunk` de `SectionNeighborExpander` debe cachearse por documento entre
   requests, o declararse un tope explícito de GET de sidecars por turno. Hoy `page_index`
   (`section_neighbor_expander.rb:85-104`) hace un `list_keys` más hasta
   `MAX_INDEX_CHUNKS = 500` descargas, con caché por instancia y una instancia por request
   (`rag_controller.rb:172`): ~97 GET de S3 en el primer divisor de cada turno de SEGURIDADES.
6. Re-evaluar el vecino expandido con el mismo parser, scope y fact extractor.
7. Ordenar por:
   - scope validado;
   - completitud de objetivos;
   - calidad de fuente;
   - rango Retrieve.
8. No aplicar `MAX_CONTEXTS` hasta después de preservar todos los hechos de cada
   contexto válido.
9. Separar:
   - `selected_context_rank`;
   - `raw_retrieve_rank`;
   - `fact_coverage`;
   - `scope_precision`.
10. Un estado no documentado produce `abstained_relations`, nunca un hecho inferido.

**Gate C3 sobre replay v2.1:**

| Caso | Modo esperado | Cobertura obligatoria |
|---|---|---|
| `altius_d8_d11` | direct | D8 y D11 |
| `tpr50_spm` | direct | SPM |
| `cta_sr8p_sph` | direct | SPH + SR8P + serie |
| `em2000_leds_seguridad` | direct por colapso de hechos (p. 31 y p. 32 son idénticas) | SEG, SCE, SCC y AP |
| `em4000_obstaculo_conectores` | direct | XC4 y XC7 |
| `edel_k3_leds` | direct | 37, 39 y 41 |
| `tokibat_dl27_v2` | direct | DL27 + abstención de estado |
| `enier_mxl1_leds` | direct | 12 y 19, expansión `section_identity` |
| `thyssen_serie_e_leds` | direct | L9, L8 y L7 + abstención de estado |
| `elecmegon_obstaculo_ambiguo` | ambiguous con hechos discrepantes por modelo | solo contextos Elecmegon con hechos/extractos pertinentes; baseline a superar: 3/5 |

Métricas obligatorias:

- `scope_precision=100%`;
- `required_fact_coverage=100%`;
- `foreign_context_rate=0%`;
- `transport_evidence_rate=0%`;
- `duplicate_fact_rate=0%`;
- contexto objetivo en posición 1 después del selector para 9/9 directos;
- 100% de tarjetas ambiguas con al menos un hecho que responde la consulta.

### Fase C4 — Render determinista y contrato web

C4 y C5 se entregan como una sola fase de release: el contrato web sólo es observable a través
de la ruta viva, porque la sombra desaparece en C5. C4 se prueba con tests de controlador sobre
una `EvidenceSelection` fabricada; el gate real end-to-end es C5.

1. Crear `Rag::EvidenceAnswerRenderer` para `direct`.
2. Renderizar mappings desde `TechnicalFact`; no volver a pedirle a un LLM que los
   interprete.
3. Renderizar abstenciones con copy localizado fijo:
   - el documento respalda la atribución;
   - el estado/condición no está documentado.
4. Evolucionar el payload como `resolution_v2`; no cambiar silenciosamente
   `resolution_v1`.
5. Cada tarjeta puede contener varios facts/excerpts del mismo contexto.
6. Mantener:
   - objetivos táctiles de 44 px;
   - primeras tres tarjetas visibles y “ver más”;
   - `quick_replies` de compatibilidad;
   - fuentes visibles solo con `SHOW_RAG_SOURCES=true`;
   - ningún chunk completo transportado al navegador.
7. La selección de una tarjeta debe enviar un identificador de contexto estable y
   validable, no depender solo de volver a interpretar una etiqueta libre. Ese
   identificador nunca puede omitir los filtros de cuenta y documento al resolver
   el follow-up.
8. Extender telemetría con:
   - versión del parser/selector;
   - scope solicitado y scope validado;
   - fact coverage;
   - missing targets;
   - source kind;
   - rechazos por etapa;
   - contexto seleccionado en el follow-up.

**Gate C4:**

- el renderer no emite sujeto o valor técnico ausente del fact;
- facts multi-LED completos en web;
- navegación y fuentes no alteran el resultado técnico;
- selección de tarjeta no repite el mismo menú;
- pruebas 320/375/430 px y accesibilidad en verde.

### Fase C5 — Integración viva sin doble Retrieve

1. Crear una ruta de servicio explícita, por ejemplo `Rag::EvidenceResolutionService`, dentro
   de `QueryOrchestratorService`, **evaluada después de `DocumentOverviewResponder` —que no
   recupera— y antes de `AmbiguousModelResponder` y `DeterministicRenderer`**. Ambos ya hacen su
   propio `retrieve_chunks` (`ambiguous_model_responder.rb:47`,
   `deterministic_renderer.rb:62`) en la cascada de `query_orchestrator_service.rb:223-248`;
   insertar la ruta después de ellos produciría dos o tres recuperaciones por turno.
2. Resolver la elegibilidad mediante una clasificación determinista local antes de
   llamar AWS. Una consulta no elegible cae directamente al RAG existente.
3. Elegibilidad inicial:
   - canal web;
   - documento fijado mediante el scope de sesión existente;
   - consulta de mapeo técnico soportada;
   - consulta **no** clasificada como safety-critical por `RagRetrievalProfile`, que conserva su
     perfil reducido y su directiva STOP-WORK por el camino existente;
   - feature flag vivo separado del flag de sombra.
4. Ejecutar un solo `retrieve_chunks(top_k: 20)`.
5. Si el resultado es:
   - `direct`: devolver renderer determinista;
   - `ambiguous`: devolver tarjetas y prompt de selección;
   - `insufficient` con scope sin resolver: `REQUIRE_FIELD_VERIFICATION` y pedir el
     scope faltante;
   - `insufficient` con scope validado: `DATA_NOT_AVAILABLE` solo para la relación
     no evidenciada, nunca para el documento completo.
6. Después de iniciar el Retrieve, no caer a `retrieve_and_generate` en el mismo
   turno. Esto evita pagar y esperar dos recuperaciones por un fallo del selector.
7. No ejecutar simultáneamente el selector del controlador y la ruta viva.
8. Retirar `run_evidence_selector_shadow` del ciclo síncrono antes de activar tráfico
   normal. La comparación en sombra debe ejecutarse en benchmark controlado, no
   agregando una llamada externa a cada interacción.
9. Cuando la ruta nueva sea elegible, no invocar `AmbiguousModelResponder`.
10. Mantener `AmbiguousModelResponder` solo para consultas fuera del contrato hasta
   completar su retiro con evidencia.
11. Una consulta directa resuelta no llama `retrieve_and_generate` ni otro LLM.
12. Un `Retrieve` puro sigue sin crear filas ficticias en `bedrock_queries`.

**Gate C5:**

- exactamente un `Retrieve` por resolución estructurada, verificado con una aserción de conteo
  de invocaciones de `retrieve_chunks` por turno, no por inspección de logs;
- cero llamadas LLM en los diez casos v2.1;
- cero segundo Retrieve en controlador;
- flags apagados preservan byte por byte el comportamiento vivo anterior;
- fallos AWS tienen manejo explícito y no producen una respuesta técnica inventada.

### Fase C6 — Validación acumulativa y holdout

Orden obligatorio:

1. Tests unitarios de cada contrato.
2. Replay offline de Paso G.
3. Suite Rails completa.
4. Retrieve controlado contra el KB ya sincronizado.
5. Benchmark end-to-end con la ruta viva en entorno controlado.
6. Revisión humana contra el PDF renderizado.
7. Holdout no visto.

Rúbricas acumulativas:

- v3.2, sin modificaciones;
- v1.2, sin modificaciones;
- v2.1, sin modificaciones;
- nueva cohorte holdout en `script/fixtures/rag_seguridades_holdout_v1.json`, versión
  `seguridades-holdout-v1.0`, creada y aprobada por un humano antes de implementar, con su
  `sha256` registrado en este documento y sin usarse para calibrar el código. La verdad-terreno
  se verifica contra el PDF renderizado; la ruta es
  `~/Documents/Danebo/Danebo Elevator Rag Julio 2026/entrevosdtas /SEGURIDADES 1.1-1.pdf`
  — la carpeta `entrevosdtas ` **termina en espacio** y una ruta sin él no resuelve.

El holdout debe incluir, como mínimo:

- paráfrasis donde “LED” no se repite antes de cada identificador;
- negación de una placa hermana;
- números distractores usados como página, pin, voltaje y cantidad;
- mismo código en dos placas;
- fabricante sin modelo;
- modelo inexistente;
- versión/sufijo que no debe fusionarse;
- pregunta multiobjetivo parcial.

No abrir el holdout para ajustar una rama productiva. Si falla, corregir el mecanismo
general y volver a crear otro holdout independiente.

## 7. Gates finales de aceptación

No avanzar a piloto hasta cumplir todos:

### Calidad

- v3.2: cohorte completa correcta en cinco corridas consecutivas.
- v1.2: 10/10 en cinco corridas consecutivas.
- v2.1: 10/10 en cinco corridas consecutivas.
- holdout: 100% de veredictos críticos y 0 invenciones críticas.
- 0 ausencias falsas cuando el fact está en un chunk recuperado o vecino autorizado.
- 0 hechos de placa/fabricante ajeno.
- 100% de objetivos obligatorios respondidos en consultas multiobjetivo.
- 100% de relaciones no documentadas abstienen de forma explícita.
- 100% de cards ambiguas relevantes.
- 100% de facts con documento, página, chunk, source kind y extracto.

### Recuperación y selector

- Mantener medición separada de raw `recall@3/@10/@20` y MRR.
- No exigir que Bedrock mueva físicamente TPR50 o Thyssen al top 3.
- Exigir que el selector promueva el contexto correcto a selected rank 1 en 9/9
  directos.
- ENIER debe resolver por `section_identity` en 5/5 corridas.
- Ningún resultado puede usar `adjacent_page_interim` para SEGURIDADES.

### Rendimiento y costo

- Un solo Retrieve y cero LLM para la ruta estructurada.
- Sin aumento de tokens de generación en consultas directas: deben ser cero.
- p95 end-to-end ≤ +15% respecto del baseline comparable, definido explícitamente como: el
  camino vivo generativo actual (`retrieve_and_generate`), mismo documento fijado, misma
  ventana temporal, corridas A/B intercaladas. Los p95 de Paso F/G son de `Retrieve` puro sin
  generación y **no** son ese baseline.
- Reportar por separado el tramo `Retrieve`, el trabajo local del selector y el costo de
  expansión, con y sin divisor recuperado, porque la expansión añade E/S de S3 dentro del
  request.
- La latencia se mide con corridas A/B intercaladas en la misma ventana, separando
  cold start de steady state; no comparar dos horas distintas como causalidad.
- Reportar p50, p95, tamaño de muestra, warming y errores.
- Reconciliar costo Bedrock por el mecanismo vigente; no inferir ahorro solo desde
  conteos locales.

### Ingeniería y UX

- Tests dirigidos y suite completa en verde.
- Guardián `no_hardcoded_equipment_test` en verde.
- Feature flags apagados preservan comportamiento.
- No se transporta contenido completo de chunks.
- Accesibilidad y móvil validados.
- Revisión humana de las diez respuestas contra las páginas fuente.

## 8. Despliegue, observación y reversión

1. Implementar con todos los flags de producción apagados.
2. Desplegar código inerte solo después de cerrar tests y revisión.
3. Ejecutar benchmark controlado con el documento SEGURIDADES fijado.
4. Activar la ruta viva únicamente para el alcance de piloto configurado, sin
   `account_id` ni URI hardcodeados en código.
5. Mantener `SHOW_RAG_SOURCES=false` para usuario final; activarlo solo en QA.
6. Observar:
   - tasa direct/ambiguous/insufficient/not_applicable;
   - facts por respuesta;
   - missing targets;
   - selección de tarjetas;
   - latencia/error;
   - llamadas LLM evitadas;
   - fallbacks a RAG.
7. Reversión inmediata: apagar el flag vivo. No requiere restaurar sidecars ni
   resincronizar el KB.
8. No tocar el backup de sidecars salvo una reversión específica del Paso G
   autorizada por el usuario; este plan no la necesita.

## 9. Alcance probable de archivos

### Modificar

- `app/services/rag/query_analysis.rb`
- `app/services/rag/query_entities.rb`
- `app/services/rag/evidence_candidate_selector.rb`
- `app/services/rag/evidence_selection.rb`
- `app/services/rag/resolution_presenter.rb`
- `app/services/rag/evidence_selection_telemetry.rb`
- `app/services/query_orchestrator_service.rb`
- `app/controllers/rag_controller.rb`
- `app/javascript/rag/evidence_cards_renderer.js`
- `config/locales/rag.es.yml`
- `config/locales/rag.en.yml`
- scripts de benchmark y tests correspondientes

### Leer sin modificar salvo necesidad demostrada

- `app/services/rag_retrieval_profile.rb` — techo `MAX_RESULTS` y clasificación
  safety-critical que la ruta estructurada debe respetar
- `app/services/rag/field_record_parser.rb` — parser `FIELD_RECORD` a reutilizar
- `app/services/bedrock/citation_processor.rb` — reglas de exclusión de header/metadata
- `app/services/chunk_merger_service.rb` — origen de la metadata de aliases; explica por qué no
  es utilizable, no se cambia

### Nuevos candidatos

- `app/services/rag/chunk_evidence_parser.rb`
- `app/services/rag/technical_scope_resolver.rb`
- `app/services/rag/technical_fact.rb`
- `app/services/rag/technical_fact_extractor.rb`
- `app/services/rag/evidence_answer_renderer.rb`
- `app/services/rag/evidence_resolution_service.rb`
- flag separado para activación viva
- fixture compacto de replay del Paso G

### Conservar sin ampliar salvo necesidad demostrada

- `app/services/rag/section_neighbor_expander.rb`
- `app/services/rag/answer_safety_processor.rb`
- `app/services/rag/pinned_entity_scope_resolver.rb`
- `app/services/bedrock_rag_service.rb`
- `app/services/rag/ambiguous_model_responder.rb`

La IA ejecutora debe confirmar el alcance exacto y los `AGENTS.md` aplicables antes
de editar. La lista no autoriza una reescritura del pipeline RAG general.

## 10. Acciones descartadas

- No ejecutar otra reingesta o sincronización para intentar cambiar rankings.
- No ampliar `top_k` por encima de 20 ni enviar veinte chunks al generador.
- No agregar fabricantes, modelos, LEDs o respuestas del benchmark a regex
  productivas.
- No considerar “ambiguous” una salida aceptable cuando el técnico ya dio un scope
  que la evidencia valida de forma única.
- No usar aliases de búsqueda como evidencia técnica.
- No aceptar un número por mera presencia.
- No mantener el word-count de tres palabras como relation gate.
- No truncar al primer hecho de una consulta multiobjetivo.
- No agregar otro LLM para clasificar scope o seleccionar facts.
- No ejecutar selector sombra y respuesta viva como dos llamadas síncronas en
  tráfico normal.
- No activar tarjetas antes de que sus facts y follow-ups estén certificados.
- No modificar las rúbricas históricas para acomodar la implementación.

## 11. Orden recomendado de commits

1. `test(rag): add Paso G selector replay and failing characterizations`
2. `feat(rag): add query analysis v2 and technical scope resolver`
3. `feat(rag): parse trusted evidence units and extract typed facts`
4. `fix(rag): select complete facts within validated equipment scope`
5. `feat(rag): render evidence resolutions deterministically and integrate single-retrieve live route`
6. `test(rag): close cumulative cohorts and holdout gates`
7. `docs(rag): record corrective benchmark and rollout decision`

Cada commit debe dejar tests dirigidos verdes. No mezclar despliegue, flags o
operaciones AWS con los commits de implementación.

## 12. Resultado de la revisión

Revisión ejecutada el 2026-07-30, sin editar código, S3, Knowledge Base ni producción.
Veredicto: **RECHAZADO como estaba escrito; aprobado con los cambios P0/P1 ya incorporados.**

Confirmado correcto y sin cambios: las 12 filas de §3.2 verificadas una por una contra el
código, §10 completo, la negativa a reingerir y resincronizar, el rechazo del doble Retrieve en
tráfico normal y la política de rúbricas acumulativas.

Hallazgos incorporados:

| Sev | Hallazgo | Dónde se resolvió |
|---|---|---|
| P0 | Gate C3 exigía `direct` para EM2000 mientras §5.3 obligaba a `ambiguous` | §5.5 colapso por identidad de hechos; Gate C3 |
| P0 | La etapa 2 rechaza por una unión de aliases de documento (19/20 en ALTIUS) | §3.2, §5.2, §5.3, C1, Gate C2 |
| P1 | La identidad de equipo multitoken no era extraíble (`EM 2000` → `EM`) | §5.1, §5.3 |
| P1 | «Filas de tabla preferidas» no discriminaba la fila JH2 de p. 26 | §5.2, §5.4, C0, Gate C2 |
| P1 | XC4/XC7 viven en un `###`, no en el primer `##` ni en una tabla | §5.2, C0, Gate C2 |
| P1 | «Un solo Retrieve» sin punto de inserción en la cascada | C5.1, Gate C5 |
| P1 | El costo de S3 de la expansión no estaba presupuestado | C3, §7 |
| P2 | `top_k=20` fijo vs perfil adaptativo y safety-critical | §4, C5.3 |
| P2 | Gate de latencia sin baseline definido | §7 |
| P2 | El replay no podía reproducir el mecanismo ENIER offline | C0.3 |
| P2 | Holdout sin ruta, versión ni hash | C6 |
| P2 | Reuso incompleto (`FieldRecordParser`, `fragments`) | §5.2, §9 |
| P2 | C4 no verificable antes de C5 | C4, §11 |
| P3 | La puerta de familia nunca excluye, no «casi nunca» | §3.2 |
| P3 | Elecmegon 3/5, no 2/5 | §3.4 |
| P3 | Los dos `direct` actuales son falsos positivos | §3.4, C0.2 |

## 13. Handoff a la IA ejecutora

Usar solo después de aprobar la revisión:

> Implementa por fases
> `docs/RAG_PRECISION_V2_PLAN_CORRECTIVO_2026-07-30.md`, incorporando primero los
> cambios obligatorios de la revisión. Empieza por el replay offline y no edites
> expectativas para ocultar el fallo. No hardcodees equipos ni respuestas. No
> ejecutes reingesta, sync KB, escritura S3, despliegue ni cambios de flags. Entrega
> cada gate con tests Minitest, métricas separadas de scope/facts/selector y un diff
> mínimo. Detente antes de cualquier operación externa que requiera autorización.
