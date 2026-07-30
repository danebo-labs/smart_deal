# Fase 0.5 — Auditoría y contención de la lógica basada en regex

**Fecha:** 2026-07-29.
**Alcance ejecutado:** Fase 0.5 de [RAG_PRECISION_V2_PLAN_2026-07-29.md](RAG_PRECISION_V2_PLAN_2026-07-29.md), tarea asignada a Opus en §12 («inventario regex keep/consolidate/retire + diseño de `Rag::QueryAnalysis`»).
**Lo que este documento NO hace:** no modifica código productivo, fixtures, S3/KB ni producción. No escribe los tests de caracterización (tarea Sonnet/Haiku, §7 de este doc). No ejecuta benchmarks (Fase 0).
**Commit base de la medición:** `7c5e954`.

---

## 1. Método y reproducibilidad

El censo no se hizo por `grep` de barras —que confunde división, comentarios y URLs— sino tokenizando cada archivo con `Ripper` y contando tokens `on_regexp_beg`, más las apariciones de `Regexp.new`:

```ruby
# /tmp/regex_count.rb
require 'ripper'
ARGV.each do |f|
  lit = Ripper.lex(File.read(f)).count { |(_p, type, _t)| type == :on_regexp_beg }
  dyn = File.read(f).scan(/Regexp\.new/).size
  puts "#{lit + dyn}\t#{f}"
end
```

Las afirmaciones de comportamiento de §4 se verificaron ejecutando los patrones literales
contra los identificadores y modelos reales del PDF y contra las diez preguntas de
`script/fixtures/rag_seguridades_pilot_10q_v2.json` (hoy en versión `seguridades-pilot-v2.1`,
es decir la recalibración CN de Fase 0 ya está aplicada). No se invocó Bedrock ni producción.

---

## 2. Censo real (corrige la cifra del plan)

El plan decía «88 literales regex»; la revisora estimó «≈94 / ≈112». La medición con Ripper da:

| Ámbito | Patrones |
|---|---:|
| **Núcleo estricto** (`app/services/rag/*`, `bedrock_rag_service.rb`, `rag_retrieval_profile.rb`) | **98** |
| Periferia de formato (`app/services/bedrock/*`, `rag_query_concern.rb`, `rag_controller.rb`) | 18 |
| **Total inspeccionado** | **116** |

Distribución por archivo (núcleo estricto):

| Archivo | Patrones |
|---|---:|
| `app/services/rag/answer_safety_processor.rb` | 23 |
| `app/services/bedrock_rag_service.rb` | 20 |
| `app/services/rag/faceted_answer.rb` | 14 |
| `app/services/rag_retrieval_profile.rb` | 13 |
| `app/services/rag/deterministic_intent.rb` | 9 |
| `app/services/rag/ambiguous_model_responder.rb` | 6 |
| `app/services/rag/pinned_entity_scope_resolver.rb` | 6 |
| `app/services/rag/whatsapp_followup_classifier.rb` | 4 |
| `app/services/rag/functional_test_renderer.rb` | 2 |
| `app/services/rag/benchmark_rubric_evaluator.rb` | 1 (`Regexp.new` desde el fixture) |

Los ocho archivos restantes de `app/services/rag/` no contienen ningún patrón.

**Corrección de encuadre:** el volumen no es el problema. De los 98 del núcleo estricto,
**18 pertenecen al canal WhatsApp dormante** (`faceted_answer.rb` 14 + `whatsapp_followup_classifier.rb` 4)
y son parsing de protocolo del propio prompt facetado. El núcleo **activo del canal web son 80 patrones**,
y sobre esos 80 se decide.

---

## 3. Inventario `keep / consolidate / retire`

Resumen:

| Decisión | Núcleo estricto (98) | De los cuales, núcleo web activo (80) | Periferia (18) |
|---|---:|---:|---:|
| **keep** — protocolo, formato, URI, cita, unidades, normalización | 50 | 32 | 18 |
| **consolidate** — tokens, identificadores, variantes, intención, relación | 43 | 43 | 0 |
| **retire** — fabricante/modelo hardcodeado, relaciones técnicas específicas, identidad inferida por forma | 5 | 5 | 0 |

### 3.1 `retire` — los cinco que deben desaparecer

Son los únicos patrones que *codifican conocimiento del dominio en el código productivo*.
Cada uno tiene un sustituto obligatorio; ninguno se puede borrar antes de que exista el sustituto.

| # | Patrón | Sitio | Qué codifica indebidamente | Sustituto | Bloqueado por |
|---|---|---|---|---|---|
| R1 | `EXPLICIT_EQUIPMENT_PATTERN` | [deterministic_intent.rb:27](../app/services/rag/deterministic_intent.rb#L27) | Lista manual de 8 fabricantes + forma de modelo | `QueryAnalysis#manufacturer/#model` desde metadata + alias | Fase 2 |
| R2 | `MODEL_PATTERN` | [ambiguous_model_responder.rb:17](../app/services/rag/ambiguous_model_responder.rb#L17) | «esto parece un modelo» por forma léxica | identidad de sección desde metadata | **nada — ver nota** |
| R3 | `board_model_name?` | [answer_safety_processor.rb:267](../app/services/rag/answer_safety_processor.rb#L267) | «`X-Y9` es el nombre de la placa, no un componente cableado» | `board_model` del chunk seleccionado | Fase 2 |
| R4 | `DEVICE_FUNCTION_CLAIM_PATTERN` | [answer_safety_processor.rb:44](../app/services/rag/answer_safety_processor.rb#L44) | La relación limitador↔sobrecarga, una sola función técnica | comparación de hechos tipados `componente + relación + valor` | Fase 1 |
| R5 | heurística de nombre de documento por capitalización | [bedrock_rag_service.rb:1312](../app/services/bedrock_rag_service.rb#L1312) | «palabra Capitalizada ⇒ nombre de documento» | resolución por `canonical_name`/alias | ya disponible |

**Corrección posterior (Fase 1, 2026-07-29): R2 es código inalcanzable.** `MODEL_PATTERN`
se usa solo dentro de `AmbiguousModelResponder#metadata_label`, que exige
`metadata["manufacturer"]`. Ningún camino de ingesta escribe esa clave:
`BatchResultsParserService#sidecar_metadata` es el único escritor de `metadataAttributes`
y su contrato no la incluye. El método siempre retorna `nil` y todas las etiquetas vienen
de `heading_label`. Por tanto R2 **no está bloqueado por Fase 2**: su retiro es una
eliminación pura, ejecutable en P1. Detalle y consecuencias en
[RAG_EVIDENCE_SELECTOR_FASE1_DESIGN_2026-07-29.md](RAG_EVIDENCE_SELECTOR_FASE1_DESIGN_2026-07-29.md) §1 F1.

**Consecuencia de secuenciación, no anticipada por el plan:** R1 y R3 *no son ejecutables en Fase 0.5*.
Su sustituto es metadata de fabricante/modelo confiable, y hoy los sidecars de SEGURIDADES aplanan
todo el manual al `canonical_name` de ALJO/ALTIUS (§1.3 del plan). Retirarlos ahora sustituiría una
heurística mala por una metadata peor. **Fase 0.5 los marca y los congela; se retiran en Fase 2, después
del backfill y con los tres gates verdes.** El plan debe reflejar esta dependencia (ver §8).

### 3.2 `consolidate` — los 43 que se unifican en `Rag::QueryAnalysis`

Agrupados por vocabulario, no por archivo. La consolidación no cambia comportamiento: mueve el
mismo patrón a un único dueño y hace que todos los consumidores lo lean de ahí.

| Vocabulario | Patrones | Sitios actuales |
|---|---:|---|
| **V1 · intención exhaustiva** | 8 | `rag_retrieval_profile.rb:42-49` |
| **V2 · intención safety/stop-work** | 5 | `rag_retrieval_profile.rb:53-55` (3), `deterministic_intent.rb:17-18` (2) |
| **V3 · intención prueba funcional** | 2 | `deterministic_intent.rb:12-13` |
| **V4 · hardware genérico (disparo de ambigüedad)** | 2 | `deterministic_intent.rb:22-23` |
| **V5 · intención esquemático/visual** | 4 | `rag_retrieval_profile.rb:99-100`, `bedrock_rag_service.rb:914-915` |
| **V6 · relación pedida (conexión / estado / atribución)** | 4 | `answer_safety_processor.rb:35,40,41,42` |
| **V7 · taxonomía de identificadores** | 4 | `answer_safety_processor.rb:16,45,258`, `pinned_entity_scope_resolver.rb:110` |
| **V8 · estado sensible a evidencia** | 1 | `answer_safety_processor.rb:32` |
| **V9 · gramática de etiqueta documental (`(SERIE …)`, encabezado de sección)** | 4 | `answer_safety_processor.rb:52`, `ambiguous_model_responder.rb:131,132`, `functional_test_renderer.rb:33` |
| **V10 · léxico de ausencia** | 7 | `bedrock_rag_service.rb:41-47` |
| **V11 · negación de alcance** | 1 | `pinned_entity_scope_resolver.rb:18` |
| **V12 · directiva safety inline (duplicado de V2)** | 1 | `bedrock_rag_service.rb:991` |
| **Total** | **43** | |

### 3.3 `keep` — los 68 que se quedan donde están

No requieren acción y **no deben tocarse** durante el refactor. Son:

- **Protocolo de marcadores** (`DATA_NOT_AVAILABLE`, `REQUIRES_FIELD_VERIFICATION`, `[n]`, `<DOC_REFS>`, `ACTION|DETAILS|EXPECTED_RESULT:`) — 8 patrones.
- **Formato Markdown / tablas / encabezados** — `rag_query_concern.rb:142,145,146,182,186`, `answer_safety_processor.rb:200`, `ambiguous_model_responder.rb:126,130,134` — 9.
- **Parsing de cita y de header de chunk** — los 10 de `bedrock/citation_processor.rb`.
- **Normalización** (diacríticos, tokenización `[\p{L}\d]+`, `[^A-Z0-9]`, trim de puntuación, split de oraciones) — 12.
- **Unidades físicas** — `answer_safety_processor.rb:30` — 1.
- **Detección de idioma** — `bedrock_rag_service.rb:1134,1168,1174`, `rag_query_concern.rb:242` — 4.
- **Protocolo del proveedor** (respuesta canónica de guardrail, Aurora auto-paused) — 2.
- **Canal WhatsApp dormante** — 18 (`faceted_answer.rb`, `whatsapp_followup_classifier.rb`). Fuera de alcance mientras el canal siga dormante; si se reactiva, reauditar.
- **Escapes dinámicos** `Regexp.escape` y el `Regexp.new` del evaluador de rúbricas (el patrón vive en el fixture, no en el código) — 4.

Nota sobre los 10 de `citation_processor.rb`: existen únicamente porque el header de ingesta
(`[DOCUMENT:…]`, `**Page:**…`) viaja dentro del `content` del chunk. Son `keep` hoy y **candidatos a
retire después de Fase 2**, cuando la identidad viva en metadata escalar. Registrarlo, no actuarlo aquí.

---

## 4. Hallazgos empíricos (miden, no describen)

### H1 · `IDENTIFIER_PATTERN` deja sin guardia 14 de los 25 identificadores reales del manual

Ejecutando el patrón literal de [answer_safety_processor.rb:16-28](../app/services/rag/answer_safety_processor.rb#L16-L28) contra los identificadores verificados en el PDF:

| Resultado | Identificadores |
|---|---|
| **MATCH (11)** | `D8` `D11` `DL27` `XC4` `XC7` `CN7` `CN8` `CN9` `L9` `L8` `L7` |
| **NO MATCH (14)** | `SPM` `SPH` `SEG` `SCE` `SCC` `SSH` `AP` `SPE` `PP` · `37` `39` `41` `12` `19` |

Dos familias descubiertas, no una. El plan sólo anotaba la primera:

1. **Códigos de sólo letras** (`SPM`…`PP`): todas las ramas del patrón exigen un dígito, salvo `X…`.
2. **Códigos numéricos desnudos** (`37/39/41` de EDEL-K3, `12/19` de ENIER MXL1): ninguna rama admite un número sin prefijo alfabético. **Hallazgo nuevo de esta fase.**

Falla concreta y verificable: la respuesta `SPM: SERIE PUERTAS CABINA - EXTERIORES.`
no dispara `IDENTIFIER_PATTERN`, no dispara el patrón de valores con unidad y no dispara el
de estado (no contiene la palabra `LED` ni un verbo de estado). Por tanto
`requires_evidence?` devuelve **false**, `require_cited_evidence` no aplica, y
`reject_unsupported_identifiers` no encuentra identificadores que validar: **una atribución
inventada de serie para `SPM` atraviesa el guard sin ninguna verificación**. Lo mismo para
`37 = PUERTAS HUECO` en EDEL-K3.

Esto reordena la severidad: el guard no es «insuficiente» para 2 de las 10 preguntas del piloto,
está **ciego** para las 6 cuyo identificador objetivo es de sólo letras o numérico desnudo.

### H2 · `EXPLICIT_EQUIPMENT_PATTERN` acierta en la cohorte v2 por una razón incidental

Sobre las 10 preguntas de `rag_seguridades_pilot_10q_v2.json` el ruteo actual es **correcto**:
sólo `elecmegon_obstaculo_ambiguo` va a la tarjeta de desambiguación, que es lo esperado. Pero el
motivo por el que las otras nueve *no* van es engañoso:

| Motivo del match | Casos |
|---|---|
| Fabricante de la lista hardcodeada | `altius_d8_d11` (ALTIUS), `thyssen_serie_e_leds` (Thyssen) |
| Fabricante hardcodeado **y** código | `tpr50_spm` (Carlos Silva + `TPR50`) |
| **Sólo un código alfanumérico de la pregunta** | `cta_sr8p_sph` `em2000_leds_seguridad` `em4000_obstaculo_conectores` `edel_k3_leds` `enier_mxl1_leds` `tokibat_dl27_v2` |

En `tokibat_dl27_v2` el patrón matchea por `DL27` —el LED preguntado—, **no** por «TOKIBAT 2007»:
el modelo real del PDF no satisface el patrón porque el dígito está separado por un espacio.
Es decir, la cohorte pasa porque el técnico escribió el código del LED, no porque el sistema
reconozca el modelo.

Reformulaciones realistas que **sí** nombran el equipo y aun así se rutean a la tarjeta de
desambiguación (8 de 11 probadas):

```
En TOKIBAT 2007, ¿qué LED indica que las puertas de cabina están cerradas?   → DESAMBIGUACIÓN
En TOKIBAT 2.007, ¿qué LED indica el hueco cerrado?                          → DESAMBIGUACIÓN
En la placa EM 2000, ¿qué LEDs identifican las seguridades?                   → DESAMBIGUACIÓN
En EDEL K3, ¿qué indican los LEDs de puertas?                                 → DESAMBIGUACIÓN
¿Qué LEDs de seguridades documenta CTA?                                       → DESAMBIGUACIÓN
En las placas de ENIER, ¿qué LED indica el tope de foso?                      → DESAMBIGUACIÓN
En la placa NE 300 - LB II, ¿qué LED indica los cerrojos?                     → DESAMBIGUACIÓN
En MICONIC LX, ¿qué contactos de seguridad documenta?                         → DESAMBIGUACIÓN
```

De los seis fabricantes que aparecen en SEGURIDADES, **cuatro no están en la lista**: CTA, Elecmegon,
ENIER, TOKIBAT. Es exactamente el bucle que `69cd585` («break ambiguous-model loop») atacó por el
lado del marcador de respuesta sin corregir la causa. **Riesgo directo para el gate:** cualquier
cohorte futura no vista que parafrasee sin escribir el código del LED cae en la tarjeta.

`MODEL_PATTERN` de `AmbiguousModelResponder` tiene el mismo sesgo por el lado de la etiqueta:
no reconoce `ALTIUS`, `ENIER`, `ELECMEGON`, `CTA`, `Thyssen Serie E`, `NE 300 – LB II`,
`MICONIC LX`, `SMART 001` ni `TOKIBAT 2007` (0 de 9), y de `EM4000 V1` extrae `EM4000`
perdiendo la variante.

### H3 · La fragmentación de clasificadores: 3 activos, no 4, y uno de ellos corre dos veces

Corrección a la validación: `QueryOrchestratorService#classify_query_intent`
([query_orchestrator_service.rb:391](../app/services/query_orchestrator_service.rb#L391)) **no está
activo en producción** y no puede estarlo. Está detrás de `QUERY_ROUTING_ENABLED`, que vale `"false"`
en [config/deploy.yml:58](../config/deploy.yml#L58), y además `rag_only_account?` lo cortocircuita para
cuentas sin `data_sources: "db"`. Los gates lo prohíben explícitamente
(`gate9_v1_validation.rb:176`, `gate9_final_manual.rb:232`: «QUERY_ROUTING_ENABLED must be false»).
No es un cuarto clasificador de intención a consolidar: es **código dormante con contrato de
apagado**, y su decisión sobre el plan es *dejarlo fuera de `QueryAnalysis`* y no darle entrada.

Los clasificadores realmente activos por request son tres:

1. `Rag::DeterministicIntent` — decide renderer determinista y disparo de tarjeta ambigua.
2. `RagRetrievalProfile` — única fuente de `top_k` y reranking. **Se instancia dos veces por request generativo con argumentos distintos**: [bedrock_rag_service.rb:114](../app/services/bedrock_rag_service.rb#L114) (`entity_sources:` + `question:`) y [bedrock_rag_service.rb:1023](../app/services/bedrock_rag_service.rb#L1023) (`question:` solamente, para la directiva de completitud). Los mismos 8 regex de V1 corren dos veces sobre la misma pregunta; si `exhaustive_query?` llegara a depender de `entity_sources`, las dos instancias divergirían silenciosamente.
3. Directivas de prompt inline en `BedrockRagService` — `:914-915` (visual/etiqueta) y `:991` (stop-work).

La divergencia de `:991` es real y medida. `rag_retrieval_profile.rb:53` usa `fuera\s+de\s+servicio`;
`bedrock_rag_service.rb:991` usa el literal `fuera de servicio`:

| Texto | `RagRetrievalProfile` (top_k) | directiva `:991` |
|---|---|---|
| `dejarla fuera de servicio` | dispara | dispara |
| `dejarla fuera  de   servicio` | dispara | **no dispara** |
| `fuera\nde servicio` | dispara | **no dispara** |

Consecuencia: con doble espacio o salto de línea, la consulta recibe el `top_k` reducido de
safety-critical (5) **sin** la directiva STOP-WORK que separa precauciones de detención obligatoria.
Es la peor combinación posible: menos evidencia y menos contención.

### H4 · Las rutas deterministas no pasan por `AnswerSafetyProcessor`

El guard se invoca en un único punto, [bedrock_rag_service.rb:342](../app/services/bedrock_rag_service.rb#L342),
dentro de `BedrockRagService#query`. `AmbiguousModelResponder`, `DeterministicRenderer` y
`DocumentOverviewResponder` retornan antes en el orquestador
([query_orchestrator_service.rb:211-247](../app/services/query_orchestrator_service.rb#L211-L247)) y
por tanto **nunca lo atraviesan**. `rag_query_concern.rb:84-88` documenta deliberadamente que no
hay segunda pasada.

Para los renderers deterministas es defendible: emiten texto verbatim del ledger.
Para `AmbiguousModelResponder` **no lo es**: sus etiquetas provienen de `MODEL_PATTERN` o de un
encabezado reinterpretado por regex, y viajan al técnico como tres opciones accionables sin ninguna
validación contra evidencia. Es el mismo camino que produjo `SMART 001` / `MR08` / `MICONIC LX`
para una pregunta sobre `SPM`.

### H5 · Crecimiento reactivo: sí; excepciones hardcodeadas por fabricante: no

Se confirma la corrección de la revisora. `f0be176` (2026-07-26) y `4a66b01` (2026-07-28) fueron
motivados por ALTIUS, EDEL-K2 y MR08, pero se implementaron como reglas genéricas
(`board_model_name?` en `:266-268`, `SERIES_LABEL_PATTERN` en `:52`); los nombres de fabricante sólo
aparecen en comentarios. El riesgo señalado es el **patrón de crecimiento caso-a-caso**, no
excepciones literales existentes. Los únicos nombres propios en el código productivo del núcleo
están en `EXPLICIT_EQUIPMENT_PATTERN` (R1), y son ocho fabricantes de los cuales sólo dos aparecen
en SEGURIDADES.

---

## 5. Diseño de `Rag::QueryAnalysis`

### 5.1 Contrato

Objeto de valor inmutable, calculado **una vez por turno**, antes de cualquier `Retrieve`.

```ruby
# app/services/rag/query_analysis.rb
Rag::QueryAnalysis = Data.define(
  :question,             # String — texto original, sin normalizar
  :intents,              # Set<Symbol> — subconjunto de INTENTS
  :identifiers,          # Array<Identifier>
  :requested_relation,   # Set<Symbol> — :attribution | :state | :connection | :location
                         #   CORREGIDO en Fase 1 (era un Symbol escalar): tres preguntas
                         #   de la cohorte v2 piden dos relaciones y el PDF documenta una
                         #   sola, asi que cada relacion se responde o se abstiene por
                         #   separado. Con un escalar la respuesta correcta a
                         #   tokibat_dl27_v2 es irrepresentable. Ver diseno Fase 1 §1 F4.
  :manufacturer,         # Hypothesis | nil
  :model,                # Hypothesis | nil
  :board,                # Hypothesis | nil
  :pinned_scope,         # Array<String> — source_uris fijados en la sesión
  :negated_scope,        # Array<String> — frases tras "no uses…", ya normalizadas
  :confidence            # Hash{Symbol => Float} — por campo, 0.0..1.0
)

Rag::QueryAnalysis::Identifier = Data.define(:raw, :canonical, :shape, :position)
#   raw       "SPM" | "37" | "CN-112.SC"
#   canonical "SPM" | "37" | "CN112SC"        (upcase, sin separadores)
#   shape     :alpha | :numeric | :alnum | :connector
#   position  :labelled | :bare
#             :labelled ⇒ precedido por LED/serie/borne/conector/placa, o dentro de una
#             enumeración encabezada por uno de esos términos. Un número desnudo sólo
#             cuenta como identificador si su posición es :labelled.

Rag::QueryAnalysis::Hypothesis = Data.define(:value, :source, :confidence)
#   source  :metadata | :alias | :pinned_document | :lexical_fallback
```

`INTENTS` (cerrado, uno por vocabulario de §3.2):
`:exhaustive_list`, `:safety_stop_work`, `:functional_test`, `:generic_hardware`,
`:schematic_label`, `:document_overview`.

### 5.2 Dos reglas de diseño que resuelven H1 y H2

**Regla 1 — La identidad de equipo es una hipótesis, nunca un hecho.**
`manufacturer`/`model`/`board` se emiten como `Hypothesis` con `source` y `confidence`. Extraerlos del
texto de la pregunta produce **siempre** `source: :lexical_fallback` con `confidence ≤ 0.4`. Sólo la
metadata del chunk seleccionado o un alias del documento pueden elevar la confianza. Ningún consumidor
puede tomar una decisión irreversible —ofrecer una tarjeta, filtrar por fabricante— con una hipótesis
de baja confianza; con baja confianza la decisión correcta es **ampliar candidatos y dejar que el
selector de evidencia de Fase 1 decida**, no preguntar al técnico.

Esto invierte el defecto de H2: hoy «no reconozco el modelo ⇒ la pregunta es ambigua ⇒ tarjeta».
Con el contrato nuevo: «no reconozco el modelo ⇒ baja confianza ⇒ recupero y compruebo si la
evidencia converge en un solo contexto». La tarjeta se dispara por **evidencia divergente**, no por
vocabulario faltante. `EXPLICIT_EQUIPMENT_PATTERN` deja de ser necesario, y con él el bucle.

**Regla 2 — Los identificadores se validan contra el vocabulario de la evidencia, no contra una lista de formas.**
El guard actual pregunta: «¿esto *parece* un identificador de mis familias sintácticas? entonces
compruebo que esté en la evidencia». Por eso 14 códigos reales quedan fuera (H1). La dirección
correcta es la inversa, mundo cerrado:

1. construir `evidence_vocabulary` = conjunto canónico de tokens etiquetados presentes en la evidencia seleccionada;
2. extraer de la respuesta todo token con `shape` de identificador **en posición `:labelled`**;
3. es no soportado todo token que **no** esté en `evidence_vocabulary`.

Propiedades: no hay ramas por familia, `SPM` y `37` quedan cubiertos por construcción, y el guard
se vuelve *más* estricto, no más laxo (un código con la forma correcta pero ausente de la evidencia
se rechaza igual). El coste es que exige la lista de stopwords de protocolo/Markdown que ya existe
(`COMPONENT_CODE_STOPWORDS`) y una definición precisa de `:labelled` — que es exactamente el
vocabulario V9 consolidado, y **debe cubrir la ambigüedad de números desnudos**: `p. 31`, `24 V` y
`3 pasos` no son identificadores.

### 5.3 Punto de construcción y consumidores

Punto único: `QueryOrchestratorService#execute`, inmediatamente después de resolver el alcance
fijado y antes del primer branch determinista. Se pasa explícitamente hacia abajo; nadie lo
recalcula, nadie lo muta.

| Consumidor | Hoy | Con `QueryAnalysis` |
|---|---|---|
| `RagRetrievalProfile` | reclasifica 13 regex, 2 instancias por request | recibe `analysis.intents`; **única** fuente de `top_k`; una instancia |
| `Rag::DeterministicIntent` | 9 regex, 4 métodos públicos | queda como constructor de `QueryAnalysis`; deja de ser consultado a mitad del flujo |
| `AmbiguousModelResponder` | `MODEL_PATTERN` + encabezado por regex | consume `analysis.model` (hipótesis) y, en Fase 1, el selector de evidencia |
| directivas de prompt (`:914`, `:991`) | 3 regex propias, una divergente | `analysis.intents.include?(:safety_stop_work)` / `:schematic_label` |
| `AnswerSafetyProcessor` | `IDENTIFIER_PATTERN` por familias | `analysis.identifiers` ∪ `evidence_vocabulary` (Regla 2) |
| `PinnedEntityScopeResolver` | `NEGATIVE_CLAUSE`, `code_token?` | `analysis.negated_scope`, `analysis.identifiers` |
| `classify_query_intent` | LLM, apagado por contrato | **sin entrada**; se deja como está o se retira en limpieza aparte |

Efecto colateral deseado: la divergencia H3 desaparece *por construcción*, no por corregir una
de las dos regex — sólo queda un dueño del vocabulario V2.

### 5.4 Lo que `QueryAnalysis` NO hace

- No consulta metadata ni ejecuta `Retrieve`: es pre-recuperación y puro. Testeable sin red ni Bedrock.
- No decide `top_k` (eso es `RagRetrievalProfile`), no decide renderer (eso es el orquestador), no valida respuestas (eso es el guard). Sólo **describe la pregunta**.
- No hace reconciliación contra evidencia. La confirmación de fabricante/modelo contra los chunks recuperados pertenece al selector de evidencia de **Fase 1** y devuelve su propio objeto; `QueryAnalysis` permanece inmutable.
- No llama a un LLM. El fallback Haiku de intención de Fase 5 (si alguna vez se evalúa) sería un *productor alternativo* de este mismo objeto, con `source: :llm_fallback` y confianza acotada — nunca un consumidor.

---

## 6. Regla de arquitectura, ejecutable

> Ningún caso nuevo del benchmark puede resolverse agregando al código productivo el nombre de un
> fabricante, un modelo, una placa, un identificador o una relación técnica concreta. Si un caso sólo
> se arregla así, el defecto está en la metadata o en el selector de evidencia.

Para que no sea aspiracional, la regla necesita un guardián. Propuesta concreta para Fase 6
(diseño aquí, implementación Sonnet):

`test/architecture/no_hardcoded_equipment_test.rb` — recorre el núcleo estricto (los archivos de §2),
extrae los literales de string y regex, y falla si aparece un nombre de fabricante/modelo fuera de
una allowlist congelada. La allowlist arranca con las cinco entradas de R1–R5 y **sólo puede
decrecer**: cada retiro elimina una fila; agregar una fila requiere justificación en el PR. Los
comentarios quedan exentos —documentar por qué existe una regla genérica es correcto—; los literales
ejecutables, no.

Complemento del plan §Fase 0.5 punto 7 (pruebas de generalización con fabricantes ficticios): esas
pruebas demuestran que el sistema *funciona* sin conocimiento hardcodeado; el guardián demuestra que
*sigue sin tenerlo*. Se necesitan las dos.

---

## 7. Handoff: orden de migración y tests de caracterización

### 7.1 Cobertura de tests existente

Contra el punto 1 del refactor del plan («crear tests de caracterización de cada regex activa antes
de moverla»): buena parte ya existe y **no hay que reescribirla**.

| Archivo de test | Tests |
|---|---:|
| `test/services/rag/answer_safety_processor_test.rb` | 27 |
| `test/services/rag_retrieval_profile_test.rb` | 17 |
| `test/services/rag/deterministic_intent_test.rb` | 16 |
| `test/services/rag/ambiguous_model_responder_test.rb` | 8 |
| `test/services/rag/pinned_entity_scope_resolver_test.rb` | 7 |
| **Total sobre los cinco archivos calientes** | **75** |

### 7.2 Huecos de caracterización a cubrir antes de mover nada

> **P0 EJECUTADO (2026-07-29).** Implementado en
> [`test/services/rag/regex_characterization_test.rb`](../test/services/rag/regex_characterization_test.rb) —
> 24 tests, 172 aserciones, en verde contra el código actual sin tocar `app/`.
> Detalle de cierre al final de esta sección.

Estos son los tests que faltan. Son **caracterización**: fijan el comportamiento actual, incluido el
incorrecto, para que la consolidación se demuestre neutral. Los casos marcados 🔴 documentan un
defecto conocido y deben cambiar de expectativa —en el mismo commit que introduce el sustituto—, no antes.

1. `IDENTIFIER_PATTERN` × los 25 identificadores de H1, con los 14 `NO MATCH` aserto explícito. 🔴
2. `requires_evidence?("SPM: SERIE PUERTAS CABINA - EXTERIORES.") == false`. 🔴
3. `requires_evidence?` para un identificador numérico desnudo (`37 = PUERTAS HUECO`). 🔴
4. `EXPLICIT_EQUIPMENT_PATTERN` × las 11 reformulaciones de H2, con las 8 que rutean a desambiguación asertadas. 🔴
5. `MODEL_PATTERN` × los 9 modelos/fabricantes que no reconoce. 🔴
6. Divergencia H3: los tres textos `fuera de servicio` con el veredicto de cada patrón. 🔴
7. `RagRetrievalProfile` instanciado con y sin `entity_sources` sobre la misma pregunta ⇒ mismo `exhaustive_query?` (fija la equivalencia que el refactor debe preservar).
8. `AmbiguousModelResponder` no pasa por `AnswerSafetyProcessor` (H4) — test de contrato que documenta el bypass. 🔴
9. `board_model_name?` y `SERIES_LABEL_PATTERN`: los casos ALTIUS/EDEL-K2/MR08 que motivaron `f0be176`/`4a66b01`, como controles negativos permanentes.
10. Golden test de intención: para cada una de las 10 preguntas v2 + las 11 paráfrasis de H2, el conjunto `{intents, ruta}` resultante. Es la red de seguridad de la migración P2.

Modelo sugerido: Sonnet (mecánico contra especificación); los 🔴 los revisa quien diseñó el contrato.

#### Cierre de P0

| Hueco | Estado | Dónde |
|---|---|---|
| 1 · `IDENTIFIER_PATTERN` × 25 identificadores | ✅ 3 tests (11 cubiertos / 9 solo-letras / 5 numéricos) | `regex_characterization_test.rb` |
| 2 · `requires_evidence?` con código de solo letras | ✅ 2 tests | idem |
| 3 · `requires_evidence?` con numérico desnudo | ✅ 2 tests | idem |
| 4 · `EXPLICIT_EQUIPMENT_PATTERN` × 11 paráfrasis | ✅ 4 tests | idem |
| 5 · `MODEL_PATTERN` × 9 ciegos | ✅ 2 tests | idem |
| 6 · divergencia `fuera de servicio` | ✅ 3 tests | idem |
| 7 · equivalencia de las 2 instancias de `RagRetrievalProfile` | ✅ 2 tests | idem |
| 8 · bypass del guard en la ruta determinista | ✅ 1 test (sonda `DATA_NOT_AVAILABLE`) | idem |
| 9 · controles negativos `board_model_name?` / `SERIES_LABEL_PATTERN` | ✅ **ya existía** — 4 tests | `answer_safety_processor_test.rb:243-286` + `:201-206` |
| — · ⚠️ deuda de test detectada en Fase 1 | `ambiguous_model_responder_test.rb:28-45` ejercita `metadata_label`, una rama inalcanzable en producción (F1). Debe **migrar** al mecanismo de `section_key`, no borrarse: si se borra, el retiro de R2 pasa inadvertido | |
| 10 · golden de intención v2 + paráfrasis | ✅ 3 tests | `regex_characterization_test.rb` |

**Hueco 11, no previsto en la lista original.** El golden del hueco 10 tiene
`exhaustive`, `safety` y `schematic` en `false` para los diez casos v2 —la cohorte no
contiene ninguna pregunta exhaustiva ni de stop-work—, así que detecta un falso
positivo nuevo pero **no** detectaría que P1 perdiera una alternativa de un
vocabulario. Se añadieron dos goldens de polaridad positiva, un representante por
vocabulario consolidable (V1–V5), para que mover los patrones no pueda reducir
cobertura en silencio.

**Verificación de no-vacuidad.** La red se validó por mutación sobre el código
productivo (aplicada, medida y revertida; `app/` quedó intacto):

| Mutación | Resultado |
|---|---|
| Quitar una alternativa de `EXHAUSTIVE_PATTERNS` (P1 descuidado) | detectada |
| «Cerrar» la divergencia safety solo en `rag_retrieval_profile.rb` | detectada |
| Agregar `TOKIBAT` a `EXPLICIT_EQUIPMENT_PATTERN` (el antipatrón que §6 prohíbe) | detectada |

Las tres produjeron 7 fallos con mensaje accionable («invertir esta expectativa solo
en P2/P3/P4»). Los tests no son vacuos.

### 7.3 Orden de migración (estrangulamiento, cada paso con los tres gates verdes)

| Paso | Contenido | Precondición | Retira |
|---|---|---|---|
| **P0** | ✅ **hecho** — tests de §7.2 en verde contra el código actual (`test/services/rag/regex_characterization_test.rb`, 24 tests) | — | nada |
| **P1** | `Rag::QueryLexicon`: mover los 43 patrones de §3.2 a vocabularios nombrados; los llamadores siguen llamando igual | P0 | nada (neutral por construcción) |
| **P2** | `Rag::QueryAnalysis` con `intents` únicamente; conmutar `RagRetrievalProfile`, los llamadores de `DeterministicIntent` y las directivas `:914`/`:991`. Correr en sombra comparando contra los clasificadores viejos sobre las tres cohortes | P1 | duplicado V12 (`:991`), doble instanciación de `RagRetrievalProfile` |
| **P3** | `identifiers` + `requested_relation`; `AnswerSafetyProcessor` pasa a vocabulario derivado de evidencia (Regla 2) | P2 + controles negativos de §7.2 | R4 (`DEVICE_FUNCTION_CLAIM_PATTERN`) |
| **P4** | `manufacturer`/`model`/`board` como hipótesis con confianza; ambigüedad por evidencia divergente | **Fase 2 completa** (metadata de sección confiable) | R1, R2, R3 |
| **P5** | Resolución de documento por `canonical_name`/alias | — | R5 |
| **P6** | Guardián de arquitectura de §6 con la allowlist reducida a lo que quede | P4, P5 | — |

**P4 es la única que cruza fases.** Cualquier intento de retirar R1–R3 antes de Fase 2 debe rechazarse
en revisión.

---

## 8. Correcciones que este documento impone al plan

1. **§Fase 0.5, primer párrafo:** 98 patrones en el núcleo estricto (116 con la periferia de formato), no 88 ni ≈94. Y el encuadre correcto: 80 en el núcleo web activo, 18 en el canal WhatsApp dormante.
2. **§Fase 0.5, hallazgo 1:** son **dos** familias sin cobertura, no una. Los códigos numéricos desnudos (`37/39/41`, `12/19`) tampoco están cubiertos, y el efecto no es «queda fuera del guard» sino que `requires_evidence?` devuelve `false` y la afirmación **no se valida en absoluto**.
3. **§Fase 0.5, hallazgo 3:** los clasificadores activos son **tres**, no cuatro. `classify_query_intent` está apagado por contrato de gate (`QUERY_ROUTING_ENABLED=false`) y queda explícitamente fuera de `QueryAnalysis`. La fragmentación real que cuesta hoy es la doble instanciación de `RagRetrievalProfile` (`:114` y `:1023`) y la divergencia medida de `:991`.
4. **§Fase 0.5, hallazgo 6:** confirmar la corrección de la revisora (reglas genéricas, no excepciones por fabricante).
5. **§Fase 0.5, punto 5 del refactor y §Fase 2:** obtener fabricante/modelo desde metadata **no es ejecutable en Fase 0.5**. R1–R3 se congelan aquí y se retiran en Fase 2 (paso P4).
6. **§Fase 0.5, punto 1 del refactor:** ya existen 75 tests sobre los cinco archivos calientes; el trabajo es cubrir los 10 huecos de §7.2, no reescribir de cero.
7. **§3.4 y §Fase 6:** añadir que las rutas deterministas no atraviesan `AnswerSafetyProcessor` (H4), y que `AmbiguousModelResponder` debe validar sus etiquetas contra evidencia antes de mostrarlas.
8. **§Fase 6, backend:** añadir el caso `fuera  de  servicio` (doble espacio / salto de línea) como regresión permanente de H3.

---

## 9. Estado y límite de esta fase

**Entregado:** censo reproducible (98/116), inventario `keep/consolidate/retire` de los 116 patrones
con sitio y sustituto, cinco hallazgos empíricos medidos contra el PDF y la cohorte v2, contrato y
diseño de `Rag::QueryAnalysis`, regla de arquitectura con guardián ejecutable, orden de migración en
siete pasos con la dependencia P4→Fase 2 explícita, y la lista de tests de caracterización pendientes.

**Entregado también (paso P0, ejecutado a petición del usuario el mismo día):** los tests de
caracterización de §7.2 en `test/services/rag/regex_characterization_test.rb` — 24 tests, 172
aserciones, verdes; validados por mutación; `app/` sin cambios.

**No entregado, por asignación de fase:** implementación de `QueryLexicon`/`QueryAnalysis` (P1–P6) y
las ediciones de §8 al plan correspondientes a Fase 2 y Fase 6, que quedan para quien ejecute esas
fases. Las de Fase 0.5 ya están aplicadas al doc del plan.

**Sin tocar:** código productivo, fixtures, S3/KB, feature flags, producción.
