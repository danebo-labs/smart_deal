# Plan quirúrgico de precisión RAG — 2026-08-02

**Objetivo:** liberar la aplicación a piloto lo antes posible, al mínimo costo,
mejorando la precisión de respuesta sólo donde una medición lo justifique.

**Entrada obligatoria:** `docs/rag/diagnostico_precision_2026-08-02.md`. Este
plan implementa su §8 y no lo contradice en ningún punto. La regla es una:
**medir barato primero, construir sólo si la medición lo justifica.**

**Línea base honesta (actualizada 2026-08-03):** **47/88 (53%), 2/10 casos** —
holdout v1, una sola corrida contra el KB de producción
([holdout_v1_resultado_2026-08-03.md](holdout_v1_resultado_2026-08-03.md)).
`62/88` está caducado (2026-07-23); las dos cohortes verdes (83/88, 10/10)
están sobreajustadas por construcción. El v1 queda **gastado**: ningún arreglo
se verifica reabriéndolo — sólo tests unitarios ($0) o preguntas ad-hoc nuevas.

**Decisiones del dueño del producto (2026-08-03), incorporadas a este plan:**

1. Holdout v2 **estratificado** por taxonomía (no aleatorio puro) + QA de
   patrones de rúbrica (§Fase 0b).
2. **Autorizado** el A/B medido Haiku vs Sonnet del modelo de generación en
   Bedrock, sólo si el prompt no basta (§Fase 3, Rama G, paso 3).
3. **Reparar el sidecar** con la anotación `FIELD_RECORD` corrupta
   ("OSBTACULO") en vez de sólo mitigar por prompt (§Fase 3, Rama G, paso 2).
4. **Alcance de generalización:** los documentos ya indexados en producción
   distintos a `SEGURIDADES 1.1-1` se **ignoran** (ingesta con versión
   deprecada del RAG). El foco es SEGURIDADES ahora y cualquier documento que
   se indexe de aquí en adelante con el pipeline actual (§Generalización).

---

## Restricciones no negociables (del dueño del producto)

1. **Nada de regex nuevo en la aplicación** para "maquillar" respuestas. El
   único post-proceso existente (`rag/answer_safety_processor.rb`, en `main`
   sin flag) iba a revisarse en la "Rama P", pero el holdout v1 mostró que
   **no disparó en ningún fallo** — su revisión con flag queda pospuesta
   hasta que una medición la justifique. No se añade ningún regex más.
2. **No indexar datos con falta de información.** Cero re-ingesta, cero
   re-troceo. Sólo se permiten pases de metadatos que *añaden* información a
   sidecars existentes (patrón `section_identity`), nunca que la quitan.
3. **Presupuesto agotado.** Cada fase declara su costo antes de ejecutarse.

## ⚠️ Advertencia operativa: sin saldo en la API de Anthropic

Desde 2026-08-02 la cuenta de Anthropic API de la aplicación no tiene saldo.
Las corridas que la usan (visión, Batch API de ingesta) **"terminan bien" con
resultados vacíos y $0** — sin error visible. Este plan **no contiene ningún
paso que llame a la API de Anthropic desde la aplicación**. Si alguien propone
re-ingestar o re-trocear: además de estar prohibido (§5 del diagnóstico),
fallaría en silencio produciendo chunks vacíos.

Las corridas de benchmark van por **AWS Bedrock** (`retrieve_and_generate`,
perfil `global.anthropic.claude-haiku-4-5`), facturación AWS aparte, y no
están afectadas.

---

## Asignación de modelo por fase (sesión de IA que ejecuta el paso)

Precios API de Anthropic vigentes:

| Modelo | Precio in/out por MTok | Perfil |
|---|---|---|
| Claude Haiku 4.5 (`claude-haiku-4-5`) | $1 / $5 | Pasos mecánicos: correr scripts, recolectar artefactos, pases de metadatos |
| Claude Sonnet 5 (`claude-sonnet-5`) | $2 / $10 (intro hasta 2026-08-31; luego $3/$15) | Análisis: redactar rúbricas, cambios de prompt/código, clasificar fallos |
| Claude Opus 5 (`claude-opus-5`) | $5 / $25 | **Sólo** consultas acotadas cuando un hallazgo resulta ambiguo — nunca una sesión completa |

Asignación por fase pendiente (el prompt de arranque de cada una está en el
**Anexo A** al final de este documento):

| Fase | Modelo de sesión | Racional |
|---|---|---|
| 0a arnés | Haiku 4.5 | Mecánico, con test |
| 0b holdout v2 + QA de rúbrica | Sonnet 5 | La redacción de patrones exige el análisis fino que falló en el v1 (2 falsos positivos por regex) |
| 3 Rama Guard | Sonnet 5 | Cambio de heurístico + tests unitarios |
| 3 Rama Generación | Sonnet 5 | Prompt de generación + pase de metadatos |
| 3 A/B Bedrock (condicional) | Haiku 4.5 (sesión); el sistema bajo prueba compara Bedrock Haiku 4.5 vs Sonnet | 3-5 llamadas dirigidas, ~3x costo por llamada, centavos en total |
| 4 gate v2 | Haiku 4.5 | Correr el script, ~10 llamadas Bedrock |

Reglas que se mantienen: ninguna fase requiere Opus por defecto y ninguna usa
Fable ($10/$50). El grueso del costo de sesión es lectura de artefactos —
sesiones cortas, un solo objetivo. **El juez del benchmark no es un LLM**: es
puntuación determinística por regex
(`app/services/rag/benchmark_rubric_evaluator.rb`), cuesta $0 y no depende de
saldo en ninguna API.

---

## Fase 0 — Preparación sin tocar el sistema

**Modelo:** Haiku 4.5 (0a, 0c) · Sonnet 5 (0b). **Costo API de la app: $0.**

- **0a. Parametrizar el arnés.** `script/rag_seguridades_benchmark.rb:8` tiene
  `RUBRIC_PATH` hardcodeado a `rag_seguridades_rubric.json`. Añadir
  `ENV["RAG_SEGURIDADES_FIXTURE_PATH"]` con el valor actual como default.
  Esto cambia el *arnés*, no el sistema bajo prueba — la condición "sin tocar
  nada antes de correrlo" del diagnóstico se refiere al RAG y al KB, y ambos
  quedan intactos. Con test.
- **0b. Congelar holdout v2 (estratificado, con QA de rúbrica).** El v1 ya se
  gastó en la Fase 1, así que el gate de salida necesita otro: 10 preguntas
  nuevas, escritas desde la verdad-terreno ya pagada (Gate A §5-§9 y el PDF
  `SEGURIDADES 1.1-1`), mismo formato que el v1
  (`required`/`optional`/`penalized`, `passing_score: 70`). Se guarda en
  `script/fixtures/rag_seguridades_holdout_v2.json` y **no se abre** hasta la
  Fase 4. Quien lo redacta no participa en los arreglos de la Fase 3.

  **Distribución estratificada** (decisión #1 del dueño): las 10 preguntas se
  muestrean **al azar dentro de cada estrato**, no al azar puro — con n=10, el
  azar puro puede dejar sin cubrir modos de fallo que acabamos de arreglar:

  | Estrato | # |
  |---|---|
  | Determinísticas (dato exacto en el documento) | 3 |
  | Mapeos estructurados (tabla/etiqueta → identificador) | 2 |
  | Generalización (síntesis a partir de varios chunks) | 2 |
  | Ambigua (debe desambiguar o preguntar bien) | 1 |
  | Sin respaldo en el documento (debe declararlo, no inventar) | 1 |
  | Seguridad (debe responder con límites y fuentes) | 1 |

  **QA de patrones de rúbrica (nuevo, motivado por los 2 falsos positivos del
  v1):** antes de congelar, cada patrón `penalized` se prueba contra al menos
  una respuesta correcta conocida, vía test unitario que usa el evaluador real
  (`Rag::BenchmarkRubricEvaluator`, regex puro, $0). Reglas concretas
  aprendidas del v1: (a) prohibidas las ventanas `.{0,N}` que puedan cruzar
  ítems de una lista (caso `holdout_nonadjacent_ekm66_codes`); (b) los
  lookaheads de negación deben cubrir el "no" tanto **antes como después** del
  término objetivo (caso `holdout_compare_ekm66_pressure`).

  **Trampa del arnés a verificar a mano:** el evaluador **no lee**
  `max_score` ni `passing_score` del JSON — los campos son documentales.
  Comprobar que la suma real (`required×2 + optional + citas`) dé 88 y anotar
  el umbral 70 aquí. (El fixture `taxonomia` declara `max_score: 30` con suma
  real 102: ese campo no es de fiar en ningún fixture.)
- **0c. Resolver `account_id` (§7 del diagnóstico).** Decisión de negocio
  pendiente: ¿la base del piloto tiene la cuenta 1?
  - Sí → correr `script/backfill_seguridades_kb_document_2026-07-26.rb` allí.
  - No → reescribir `account_id` en los 97 sidecars + resync del KB (pase de
    metadatos, 0 llamadas a Claude).
  Esto **bloquea el piloto aunque la precisión fuese perfecta** (el documento
  no se lista en la UI del técnico). No crear la fila de catálogo bajo otra
  cuenta.

## Fase 1 — Holdout v1, UNA corrida (**hecha 2026-08-03**: 47/88, gate no superado)

**Modelo:** Haiku 4.5. **Costo:** ~10 llamadas `retrieve_and_generate` en
Bedrock (centavos) + tokens de sesión.

1. Verificar casos sueltos NO aplica aquí: es el holdout, va completo y una
   sola vez.
2. Correr contra el **KB de producción** — sobreescribir en la línea de
   comandos las variables del KB (el `.env` local apunta a desarrollo).
3. Guardar el artefacto completo en `tmp/` y anotar su hash en este documento:
   por caso, **pregunta, chunks recuperados, respuesta cruda, respuesta
   final, scoring por patrón**.
4. **Gate:** si el resultado ≥ `passing_score` (70/88) → saltar directo a la
   Fase 4 (el v2 confirma) y preparar piloto. No construir nada.

## Fase 2 — Clasificar los fallos, caso por caso

**Modelo:** Sonnet 5. **Costo API de la app: $0** (sólo lectura del artefacto
de la Fase 1).

Para cada caso fallido, una fila con exactamente una categoría:

| Categoría | Criterio |
|---|---|
| **R — recuperación** | El hecho requerido no está en ningún chunk recuperado |
| **G — generación** | El hecho está en los chunks y el modelo lo omitió o deformó |
| **P — post-proceso** | La respuesta cruda lo tenía y `answer_safety_processor` lo tumbó |

La categoría P existe porque la Fase 6a es fail-closed y "tumba algún par
correcto documentado sólo en prosa" (diagnóstico §3) — hay que separarla de G
o se arreglará el prompt para un fallo que causa un filtro.

**Salida:** tabla caso × categoría × hecho faltante, commiteada junto a este
plan. Si un caso es genuinamente ambiguo, una consulta acotada a Opus 5 —
no una re-corrida.

## Fase 3 — Intervención mínima (alcance corregido 2026-08-03)

La clasificación de la Fase 2 redefine las ramas: **0 fallos de recuperación,
4 de generación (4 causas distintas), 2 de guard (1 solo bug)**. La "Rama P"
original queda **anulada**: `answer_safety_processor.rb` no disparó en ningún
fallo del v1; el guard real es otro componente.

**Regla previa a cada intervención (§8.3 del diagnóstico):** declarar por
escrito (a) la medición barata que la justifica, (b) el resultado esperado si
la hipótesis es falsa. **El holdout v1 está gastado**: prohibido usar
`RAG_SEGURIDADES_CASE_IDS` sobre él, ni siquiera para 1 caso. La verificación
va por tests unitarios ($0) o por preguntas ad-hoc **nuevas** (redactadas al
momento, que no entrarán al v2), 1–3 llamadas dirigidas por hipótesis.

### Rama Guard (2 fallos, 1 bug) — Modelo: Sonnet 5

- **Componente:** `app/services/rag/deterministic_intent.rb`
  (`ambiguous_hardware_query?`, líneas 54-64), **no**
  `answer_safety_processor.rb`. `EXPLICIT_EQUIPMENT_PATTERN` (líneas 26-27)
  sólo acepta fabricantes de una lista fija o códigos letras+dígito pegados;
  una pregunta ya desambiguada por número de página ("¿cuántos LED hay en la
  página 26?") se marca ambigua igual y `AmbiguousModelResponder` responde el
  menú "elige una" con `model_invoked: false` — sin retrieval real.
- **Fix:** reconocer la referencia explícita a página (`p[áa]gina\s+\d+` y
  variantes) como vía de escape válida del heurístico. Evaluar en el mismo
  cambio si placas sin dígito ("Twister TW") merecen entrar — sólo si hay un
  caso de verdad-terreno que lo respalde.
- **Verificación:** sólo tests unitarios sobre el heurístico
  (`test/services/rag/deterministic_intent_test.rb`,
  `test/services/rag/regex_characterization_test.rb`). $0, 0 llamadas Bedrock.
- `answer_safety_processor.rb` sale de esta fase; su revisión con flag queda
  pospuesta hasta que una medición la justifique.

### Rama Generación (dominante: 4 fallos, 4 causas) — Modelo: Sonnet 5

En orden, del más barato al más caro; cada paso se mide antes de pasar al
siguiente:

1. **Prompt de generación** (dentro de lo permitido por §5: nada después de
   `$output_format_instructions$`, sin `stop_sequences`, sin reintentos, sin
   ampliar `top_k` pinneado). Tres instrucciones dirigidas a las causas
   medidas:
   - fidelidad al chunk mejor puntuado antes que a chunks hermanos (caso
     `holdout_sibling_ne300_p36`: ignoró el chunk top-1 y citó la placa
     hermana; caso `holdout_otis_es_ambiguous`: ignoró el hecho presente);
   - declarar explícitamente el desajuste cuando la versión/modelo pedido no
     está documentado, en vez de sustituir en silencio (caso
     `holdout_em4000_v2_absent`);
   - preferir las tablas del documento sobre bloques `FIELD_RECORD` derivados
     de ingesta cuando ambos están en el mismo chunk (caso
     `holdout_arca_p36_torque`).
2. **Calidad de datos (decisión #3 del dueño): reparar la anotación corrupta.**
   Primero un grep barato sobre los 97 sidecars para dimensionar si el defecto
   es sistémico (bloques `FIELD_RECORD` duplicados o con typos); después
   corregir "OSBTACULO" → forma correcta en el sidecar del chunk de ARCA III
   (pág. 64) — y los demás que aparezcan en el grep — + resync del KB. Es
   reparación de un artefacto de ingesta defectuoso, no eliminación de
   información del documento (compatible con la restricción #2). $0 llamadas
   a Claude.
3. **A/B del modelo de generación en Bedrock (condicional; decisión #2 del
   dueño).** Sólo si tras 1 y 2 las preguntas ad-hoc dirigidas siguen
   fallando: comparar `global.anthropic.claude-haiku-4-5` vs Sonnet en
   `retrieve_and_generate` sobre 3-5 preguntas ad-hoc nuevas. Costo declarado:
   ~3x por consulta (~$3/$15 vs $1/$5 por MTok) — centavos en total. Si Sonnet
   corrige los fallos, la decisión de subir `BEDROCK_MODEL_ID` en producción
   (`config/deploy.yml`) se presenta con números al dueño del producto como
   decisión humana; no se cambia producción dentro de esta fase.

### Rama Recuperación — sin trabajo este ciclo

0 fallos puros. El único hueco real (chunks LCB II / GEN II ausentes en
`holdout_otis_es_ambiguous`) fue secundario a un fallo de generación. Se anota
como candidato a pase de metadatos (alias) **sólo si reaparece en el v2**.

Presupuesto de la fase: **< 20 llamadas Bedrock dirigidas** en total. Si un
arreglo pide más que eso para demostrarse, es la señal de que no es
quirúrgico: se detiene y se reporta.

## Fase 4 — Gate de salida a piloto (holdout v2, UNA corrida)

**Modelo:** Haiku 4.5. **Costo:** ~10 llamadas Bedrock.

1. Criterio definido **antes** de abrirlo: ≥ 70/88 y cero fallos en casos
   `safety_critical` (si el v2 los marca).
2. Una corrida contra producción, artefacto y hash anotados.
3. **Pasa** → liberar a piloto (con 0c ya resuelto).
   **No pasa** → los fallos del v2 se clasifican con el método de la Fase 2;
   el v2 queda gastado; se congela v3 sólo si de verdad hay otro ciclo.
   **El v1 ya consumió el primer ciclo**: si el v2 también falla, aplica la
   regla — parar y re-plantear con humanos, no iterar.

---

## Generalización — precisión por tipo de documento (no sólo SEGURIDADES)

La precisión no se certifica "para un documento" sino para el pipeline, y el
esfuerzo de certificación depende del tipo de documento. El pipeline ya
clasifica cada documento en la ingesta
(`app/services/document_class_profile.rb`):
`text_manual | visual_technical | mixed | photo_set`.

**Alcance (decisión #4 del dueño):** los documentos ya indexados en
producción distintos a `SEGURIDADES 1.1-1` se **ignoran** — fueron ingeridos
con una versión deprecada del RAG y no representan al pipeline actual. No se
corre ninguna batería sobre ellos y no cuentan en ningún gate. El protocolo
aplica a SEGURIDADES ahora y a cualquier documento que se indexe **de aquí en
adelante**.

**Por qué SEGURIDADES es el gate correcto para el piloto:** es
`visual_technical` — la clase más difícil (~todo el PDF son diagramas técnicos
complejos; el censo midió 80/98 páginas visuales). Un `text_manual` produce
conocimiento estructurado mucho más fácil en la ingesta. Si la clase difícil
pasa el gate, las clases fáciles no bloquean el piloto: se validan al
onboarding con su propia batería. Además SEGURIDADES es el manual que el
cliente compartió para su demo — es literalmente el caso a validar.

**Protocolo por clase (plantilla, se ejecuta al indexar el primer documento
de cada clase con el pipeline actual):**

1. Ingestar el documento y anotar la clase que `DocumentClassProfile` le
   asignó.
2. Congelar una batería de 10 preguntas con la **misma distribución
   estratificada de la Fase 0b** (3 determinísticas / 2 mapeos / 2
   generalización / 1 ambigua / 1 sin respaldo / 1 seguridad), redactada
   desde verdad-terreno de ese documento, mismo formato de fixture.
3. Correrla una vez con el arnés existente (`RAG_SEGURIDADES_RUBRIC` /
   `RAG_SEGURIDADES_OUTPUT` ya soportan fixtures arbitrarios; la Fase 0a
   termina de parametrizarlo). Umbral relativo: ~80% del máximo, cero fallos
   `safety_critical`.
4. Pasa → el documento entra al catálogo del piloto. No pasa → clasificar
   fallos con el método de la Fase 2 antes de intervenir nada.

**Prerrequisito operativo (bloqueo duro):** indexar un documento nuevo llama
a la API de Anthropic (visión con Opus para páginas escaneadas/diagramas vía
`app/prompts/batch_chunking_prompt.rb`; texto con Sonnet). **Sin saldo, la
ingesta "termina bien" con chunks vacíos y $0.** No indexar nada nuevo hasta
reponer saldo, y verificar post-ingesta que los chunks no estén vacíos antes
de congelar la batería.

---

## Protocolo de plan vivo (regla operativa)

Motivación: el holdout v1 invalidó la "Rama P" de la Fase 3 tal como estaba
escrita — el plan sólo sirve si los hallazgos de cada fase corrigen las fases
siguientes.

1. **Toda sesión que ejecuta una fase termina actualizando este documento
   antes de cerrar:** (a) su fila en la tabla de Estado (hecho/bloqueado +
   artefacto/hash); (b) **las fases posteriores afectadas por sus hallazgos**
   — si un hallazgo invalida un supuesto de una fase futura, se corrige el
   alcance de esa fase en el mismo commit, no se deja para después.
2. Cada corrección de alcance se anota con fecha y evidencia (patrón ya usado
   en la fila de la Fase 3: "alcance corregido: …").
3. Si un hallazgo contradice una restricción no negociable o el criterio del
   gate, **no se ejecuta**: se documenta y se escala al dueño del producto
   como decisión humana numerada.
4. La memoria persistente de la IA (`project_plan_quirurgico_2026-08-02`) se
   actualiza junto con el documento, para que la siguiente sesión arranque
   con el estado real y no con el plan original.

---

## Qué NO está en este plan (y no se negocia dentro de él)

- Nada de visión: T1, T2, zoom, triaje visual, selector de evidencia — todo
  apagado se queda apagado. Dos hipótesis ya fueron refutadas con datos.
- Nada que llame a la API de Anthropic desde la aplicación (sin saldo →
  vacío silencioso).
- Ninguna corrida completa de rúbrica sobreajustada (`seguridades-v3.2`,
  `pilot-v1.2`) como evidencia de nada.
- Ningún prompt nuevo "por si acaso": cada llamada facturable aparece en una
  fase con su costo declarado.

## Presupuesto total estimado

| Concepto | Estimado |
|---|---|
| Llamadas Bedrock (Fases 1+3+4) | ~40 llamadas `retrieve_and_generate` con Haiku, más 3-5 con Sonnet si el A/B condicional se activa (~3x por llamada) → **< $2** |
| Sesiones de IA (Haiku/Sonnet, sesiones cortas) | dominado por lectura; **1–2 órdenes de magnitud menos** que los ~$500 ya gastados |
| Llamadas a la API de Anthropic desde la app | **$0** (ninguna) |

## Estado

| Fase | Estado | Artefacto / hash |
|---|---|---|
| 0a arnés parametrizado | **hecho 2026-08-03** — `FIXTURE_PATH` constante añadida; `ENV["RAG_SEGURIDADES_FIXTURE_PATH"]` parametriza ruta base (default: `script/fixtures/rag_seguridades_rubric.json`); `ENV["RAG_SEGURIDADES_RUBRIC"]` unificado sin romper invocaciones en holdout_v1_resultado_2026-08-03.md §1. | `test/scripts/rag_seguridades_benchmark_test.rb` — 4 tests cobertura |
| 0b holdout v2 congelado | pendiente | — |
| 0c account_id resuelto | **hecho 2026-08-02** — decisión: la cuenta 1 es la del piloto (opción a); backfill corrido en producción vía Kamal: `KbDocument 12` ya existía, `in home list: true`, `RESULT: OK` | Nota: quedan aliases contaminados del bug de enriquecimiento (p. ej. `"ALJO Control Level 1B Altius"`) — el script sólo los limpia cuando repara `display_name`. No bloquea; limpiar sólo si una medición lo justifica. |
| 1 holdout v1 medido | **hecho 2026-08-03** — 2/10, 47/88 (53%), por debajo de `passing_score: 70`. Holdout v1 queda gastado, no se reabre. | `docs/rag/holdout_v1_resultado_2026-08-03.md`, `tmp/rag_seguridades_holdout_v1_run1_2026-08-03.json` |
| 2 fallos clasificados | **hecho 2026-08-03** — de 8 fallos: 2 Guard (mismo bug), 4 Generación (4 causas distintas), 0 Recuperación pura, 2 falsos positivos de rúbrica (no cuentan como fallo del sistema). Rama dominante: **Generación**, con un bug de Guard de un solo origen. | `docs/rag/holdout_v1_resultado_2026-08-03.md` §3-§4 |
| 3 Rama Guard | pendiente — **alcance corregido 2026-08-03:** el componente es `app/services/rag/deterministic_intent.rb#ambiguous_hardware_query?` (no `answer_safety_processor.rb`, que nunca disparó). Reconocer "página N" como desambiguación válida. Verificación sólo con tests unitarios; el v1 está gastado. | — |
| 3 Rama Generación | pendiente — 3 pasos en orden: prompt (§5-compatible) → reparar `FIELD_RECORD` corrupto en sidecar + resync (decisión #3) → A/B Haiku vs Sonnet en Bedrock sólo si hace falta (decisión #2, 3-5 llamadas) | — |
| 3 Rama Recuperación | sin trabajo este ciclo (0 fallos puros); alias LCB II/GEN II sólo si reaparece en v2 | — |
| 4 gate v2 → piloto | bloqueada por Fase 3 (y por Fase 0b, holdout v2 aún sin congelar). Ciclo 1 ya consumido por el v1: si el v2 falla, parar y re-plantear con humanos. | — |

---

## Anexo A — Prompt de arranque por fase

Cada fase pendiente se ejecuta en una sesión nueva y corta, con el modelo
indicado. Todos los prompts comparten el mismo pie obligatorio, que no se
repite abajo:

> **Pie común (añadir al final de cada prompt):** Lee primero
> `docs/rag/plan_quirurgico_precision_2026-08-02.md` completo y
> `docs/rag/holdout_v1_resultado_2026-08-03.md`. Respeta las restricciones no
> negociables y la advertencia de saldo (nada llama a la API de Anthropic
> desde la app). El holdout v1 está gastado: no lo reabras ni con
> `RAG_SEGURIDADES_CASE_IDS`. Antes de cerrar, aplica el Protocolo de plan
> vivo: actualiza tu fila de Estado y corrige las fases posteriores que tus
> hallazgos afecten, en el mismo commit.

### Fase 0a — Haiku 4.5

> Parametriza el arnés de benchmark: en
> `script/rag_seguridades_benchmark.rb:8`, `RUBRIC_PATH` está hardcodeado a
> `script/fixtures/rag_seguridades_rubric.json`. Añade
> `ENV["RAG_SEGURIDADES_FIXTURE_PATH"]` con el valor actual como default, con
> test. No toques el RAG ni el KB: esto cambia el arnés, no el sistema bajo
> prueba. Nota: ya existe `ENV["RAG_SEGURIDADES_RUBRIC"]` en la línea ~40 —
> unifica sin romper las invocaciones documentadas en
> `docs/rag/holdout_v1_resultado_2026-08-03.md` §1.

### Fase 0b — Sonnet 5

> Redacta y congela `script/fixtures/rag_seguridades_holdout_v2.json`: 10
> preguntas nuevas desde la verdad-terreno ya pagada (Gate A §5-§9 y el PDF
> `SEGURIDADES 1.1-1`), con la distribución estratificada de la Fase 0b del
> plan (3 determinísticas / 2 mapeos estructurados / 2 generalización / 1
> ambigua / 1 sin respaldo / 1 seguridad con límites y fuentes), formato
> `required`/`optional`/`penalized`, `passing_score: 70`. QA obligatorio: un
> test unitario que pase cada patrón `penalized` contra al menos una
> respuesta correcta conocida usando `Rag::BenchmarkRubricEvaluator` ($0).
> Prohibido: ventanas `.{0,N}` que crucen ítems de lista; lookaheads de
> negación que no cubran el "no" pospuesto. Verifica a mano que la suma real
> de puntos dé 88 (el evaluador ignora `max_score`/`passing_score` del JSON).
> **No ejecutes el fixture contra Bedrock** — se abre una sola vez en la
> Fase 4. Si participaste en los arreglos de la Fase 3, detente: lo redacta
> otra sesión.

### Fase 3 — Rama Guard — Sonnet 5

> Corrige `Rag::DeterministicIntent.ambiguous_hardware_query?`
> (`app/services/rag/deterministic_intent.rb:54-64`): hoy
> `EXPLICIT_EQUIPMENT_PATTERN` (líneas 26-27) sólo escapa fabricantes de la
> lista fija o códigos letras+dígito, así que una pregunta ya desambiguada
> por página ("¿cuántos LED hay en la página 26?") cae al menú "elige una"
> sin retrieval (fallos `holdout_page64_table` y `holdout_page26_led_count`).
> Añade la referencia explícita a página como vía de escape. Verifica sólo
> con tests unitarios (`test/services/rag/deterministic_intent_test.rb`,
> `test/services/rag/regex_characterization_test.rb`): $0, 0 llamadas
> Bedrock. Declara antes la hipótesis y el resultado esperado si es falsa
> (§8.3). No toques `answer_safety_processor.rb`.

### Fase 3 — Rama Generación — Sonnet 5

> Interviene la rama dominante (4 fallos de generación del holdout v1) en
> este orden, midiendo cada paso antes del siguiente, con < 20 llamadas
> Bedrock dirigidas en total: (1) ajusta el prompt de generación dentro de lo
> permitido por §5 del diagnóstico — fidelidad al chunk mejor puntuado,
> declarar desajuste de versión en vez de sustituir en silencio, preferir
> tablas sobre bloques `FIELD_RECORD`; (2) grep sobre los 97 sidecars para
> dimensionar anotaciones `FIELD_RECORD` corruptas/duplicadas y repara el
> typo "OSBTACULO" (chunk ARCA III pág. 64) y los que aparezcan + resync del
> KB ($0 en Claude; decisión #3 del dueño); (3) sólo si 1-2 no bastan: A/B
> `global.anthropic.claude-haiku-4-5` vs Sonnet en `retrieve_and_generate`
> sobre 3-5 preguntas ad-hoc NUEVAS (nunca del holdout v1 ni del v2;
> decisión #2). Si Sonnet corrige, presenta números al dueño como decisión
> humana — no cambies `BEDROCK_MODEL_ID` de producción en esta fase. Cada
> intervención declara hipótesis y resultado esperado si es falsa (§8.3).

### Fase 4 — Gate v2 — Haiku 4.5

> Corre el holdout v2 UNA sola vez contra el KB de producción, con el patrón
> Kamal exacto de la corrida del v1 (`docs/rag/holdout_v1_resultado_2026-08-03.md`
> §1): `kamal app exec --reuse`, variables de KB de producción
> (`config/deploy.yml`, no el `.env` local), `RAG_SEGURIDADES_RUBRIC` al
> fixture v2, `RAG_SEGURIDADES_OUTPUT` a `tmp/`. Antes de gastar el holdout
> verifica que Aurora no esté fría (latencias `kb_retrieve` < 1s, sin
> `AuroraColdStartRetry` en el log). Criterio ya congelado: ≥ 70/88 y cero
> fallos `safety_critical`. Guarda el artefacto completo y anota su hash en
> la tabla de Estado. Pasa → preparar piloto. No pasa → clasifica los fallos
> con el método de la Fase 2 (el v2 queda gastado) y aplica la regla: ciclo 1
> ya se consumió con el v1 — dos ciclos fallidos = parar y re-plantear con
> humanos.
