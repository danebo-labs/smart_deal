# Plan de validación independiente — CG-D16

Fecha: 22-sep-2026  
Repo: `/Users/lahirisan/smart_deal`  
Tipo de sesión: lectura y validación estática. No implementación de CG-D16.

## 1. Objetivo

Validar con un segundo modelo si CG-D16 debe resolverse mediante:

- **(a)** conservar la gramática visible de las consultas exhaustivas y de parada;
- **(a) con excepción explícita** para `literal_label_rules`; o
- **(b)** abrir un plan separado que cambie coordinadamente las directivas, los
  renderers deterministas, el evaluador, los locales y los tests.

La validación debe decidir también si una consulta que activa simultáneamente
completitud y parada tiene hoy un conflicto de contrato con impacto de safety.

## 2. Estado del repo al abrir esta validación

> Desactualizado al ejecutarse la validación: HEAD = `origin/main` = `29dd6f2`,
> working tree limpio. Ver §11.7 C2.

- Rama: `main`.
- HEAD y `origin/main`: `d81220b`.
- Los cambios del copiloto están en el working tree; todavía no están
  commiteados.
- CG-D16 no está implementada.
- La Fase D y la medición 8 están cerradas. No se reabren.
- La ruta medida no está desplegada.

Correcciones locales previas a este plan:

1. `Rag::ContextChunkFilter` dejó de comparar contra el literal productivo
   `THYSSEN`: deriva la familia del modelo reconocido.
2. `PhotoQuestionAnswerServiceTest` conserva su contrato de «pregunta literal
   sin ancla de catálogo» con una pregunta que no activa la nueva ruta de
   contexto de resortes.

Verificación local posterior:

- Tests focalizados: 27 corridas, 105 aserciones, 0 fallos, 0 errores.
- Suite completa: 3.093 corridas, 12.444 aserciones, 0 fallos, 0 errores,
  186 skips.

Los warnings de VIPS observados durante la suite no produjeron fallos.

## 3. Restricciones

Durante esta validación:

- cero edición de código, prompts, locales, tests o este plan;
- cero Bedrock;
- cero `Retrieve`;
- cero reindexación o sync;
- cero escritura bajo `bulk_chunks/`;
- cero medición nueva;
- cero commit, push o deploy;
- no reabrir Fase G, Fase D ni crear una medición 9;
- no editar `ROLE`, `# NO MATCH` ni `generation.txt` para resolver CG-D16;
- no proponer `top_k`, parche de chunks ni una llamada adicional como solución.

Si el código contradice este documento, gana el código. La entrega debe citar
archivo y línea.

## 4. Lectura obligatoria, en orden

1. `docs/PLAN_COPILOTO_GENERACION_2026-09-22.md`:
   CG-D09, CG-D16, restricción 6, V3, Estado, Fase D y «Qué NO está en este plan».
2. `app/services/bedrock_rag_service.rb`:
   `load_generation_prompt_with_locale`, `visual_label_directive`,
   `literal_label_rules`, `query_safety_directive` y
   `query_completeness_directive`.
3. `app/services/rag_retrieval_profile.rb`:
   `EXHAUSTIVE_PATTERNS`, `SAFETY_CRITICAL_PATTERNS` y `exhaustive_query?`.
4. `app/services/rag/deterministic_intent.rb`:
   `FUNCTIONAL_TEST_PATTERNS`, `STOP_WORK_PATTERNS` y sus predicados.
5. `app/services/rag/deterministic_renderer.rb`, especialmente `build`.
6. `app/services/rag/functional_test_renderer.rb` y
   `app/services/rag/stop_work_renderer.rb`.
7. `config/locales/rag.es.yml` y `config/locales/rag.en.yml`.
8. `script/evaluate_rag_quality_benchmark.rb`, especialmente
   `parse_exhaustive_entries` y `validate_stop_work_cases`.
9. Tests que congelan la gramática:
   - `test/services/bedrock_rag_service_test.rb`;
   - `test/services/rag/deterministic_renderer_test.rb`;
   - `test/scripts/rag_quality_benchmark_evaluator_test.rb`;
   - `test/services/rag/regex_characterization_test.rb`.
10. `app/services/query_orchestrator_service.rb`, para confirmar la prioridad y
    el fallback entre rutas.

## 5. Hechos que deben verificarse contra código

### 5.1 Respuesta ordinaria

Una pregunta ordinaria de procedimiento no activa estas directivas y conserva
la prosa de compañero definida por las líneas `GROUNDED_SYNTHESIS`.

### 5.2 Ruta determinista

Solo existe cuando:

- hay `force_entity_filter` y al menos un URI pineado; y
- la pregunta pide pruebas funcionales **con resultados**, o comprobaciones
  que requieren **detener el trabajo**.

La ruta emite las etiquetas desde Rails, sin modelo.

### 5.3 Ruta generativa

- `query_safety_directive` se activa con `detener`, `parar`, `stop`,
  `prohibir` o `fuera de servicio`, aunque no haya pin.
- `query_completeness_directive` se activa mediante `exhaustive_query?`, con
  frases como `lista completa`, `todas las pruebas` o `exhaustiva`.
- Estas rutas son más anchas que los dos intents deterministas.
- `SAFETY_CRITICAL_PATTERNS` es todavía más ancho porque incluye fallos y
  reparación, pero no equivale a activar la gramática de parada.

### 5.4 Tercer contrato

`literal_label_rules` es independiente de las dos gramáticas anteriores. Para
identificadores de esquema cuya función no está documentada, hoy exige la forma
segura:

`<IDENTIFICADOR>: identificador visible; función: DATA_NOT_AVAILABLE`.

La opción (a), redactada solo para preguntas exhaustivas y de parada, no cubre
este caso sin una frase adicional.

### 5.5 Intersección exhaustiva + parada

Evaluar estáticamente esta consulta representativa sin ejecutarla:

> Dame la lista completa de comprobaciones que obligan a detener el trabajo.

Confirmar:

1. que activa `query_safety_directive`;
2. que activa `query_completeness_directive`;
3. que Rails agrega ambas directivas al mismo prompt;
4. que parada exige secciones `Precauciones e inspecciones` y
   `Detención obligatoria con evidencia explícita`;
5. que completitud exige una respuesta formada exclusivamente por bloques
   `Prueba` / `Acción` / `Resultado esperado`, sin encabezados ni advertencias;
6. si existe una regla de precedencia o un test de esta intersección.

No inferir un fallo observado: clasificarlo como conflicto estático si no fue
medido. Explicar si puede omitir o degradar información de parada.

### 5.6 Locale inglés

Verificar si `rag.en.yml` define `rag.deterministic.*`. Si no existe el bloque,
confirmar el efecto de `config.i18n.fallbacks = true` en producción y distinguir
un defecto de localización de uno de safety.

## 6. Matriz de decisión

El segundo modelo debe completar esta matriz:

| Pregunta | (a) | (a) + literal explícito | (b) |
|---|---|---|---|
| Conserva el benchmark actual | | | |
| Alinea ruta LLM y determinista | | | |
| Protege precaución ≠ parada | | | |
| Evita inventar resultados | | | |
| Cubre identificadores de esquema | | | |
| Resuelve la intersección exhaustiva + parada | | | |
| Resuelve locale inglés | | | |
| Requiere código nuevo | | | |

## 7. Alcance mínimo si la recomendación es (b)

El entregable sigue siendo un plan, no un parche. Debe incluir como mínimo:

- contrato visible y parseable para completitud;
- contrato visible y parseable para parada;
- precedencia o gramática combinada cuando ambas intenciones coinciden;
- decisión explícita para `literal_label_rules`;
- `FunctionalTestRenderer` y `StopWorkRenderer`;
- evaluador de benchmark;
- `rag.deterministic.*` en español e inglés;
- tests de directivas, renderers, evaluador, locale inglés e intersección;
- preservación explícita de estas invariantes:
  - una precaución no se promueve a parada;
  - disparador y acción obligatoria salen del mismo fragmento;
  - un resultado no se inventa ni se toma de la acción vecina;
  - el renderer determinista continúa sin invocar al modelo.

No incluir implementación, diff, Bedrock ni una medición nueva.

## 8. Frontera de commits

Los cambios actuales del copiloto y sus tests pueden commitearse cuando Lahiri
lo autorice, porque la suite está verde. Ese commit no debe incorporar una
implementación de CG-D16 que todavía no fue validada.

Si se elige (b), su implementación debe ir en un commit posterior y separado,
después de aprobar el nuevo plan y dejar verdes sus tests. No desplegar desde un
working tree sucio ni mezclar la decisión de deploy con esta validación.

## 9. Entrega requerida al segundo modelo

Responder, en este orden:

1. recomendación única: (a), (a) con frase explícita para
   `literal_label_rules`, o (b);
2. mapa de las rutas determinista y generativa, con ejemplos;
3. resultado del análisis de la consulta exhaustiva + parada;
4. efecto del faltante o presencia del locale inglés;
5. seguridad preservada y huecos restantes;
6. archivos y tests del alcance si recomienda (b);
7. contradicciones entre el plan y el código, con archivo y línea.

## 10. Prompt de arranque para otro modelo

> Validá CG-D16 en `/Users/lahirisan/smart_deal` siguiendo
> `docs/PLAN_VALIDACION_CG_D16_2026-09-22.md`. Es una revisión de solo lectura:
> cero edición, Bedrock, Retrieve, reindex, medición, commit, push o deploy. Leé
> los archivos en el orden del §4 y completá la entrega del §9. Si el código
> contradice el plan, gana el código y debés citar archivo y línea. Prestá
> especial atención a la consulta que activa simultáneamente completitud y
> parada, a `literal_label_rules` y a la presencia real de
> `rag.deterministic.*` en `rag.en.yml`.

## 11. Resultado de la validación (22-sep-2026, segundo modelo)

Lectura estática sobre HEAD `29dd6f2`, working tree limpio. Cero Bedrock, cero
`Retrieve`, cero test nuevo. La única ejecución fue un `rails runner -e test`
local que evaluó regex, `I18n.t` y el armado del prompt en memoria, sin red.
Esta sección es la única edición a este archivo, autorizada por Lahiri para
registrar gaps e inconsistencias.

### 11.1 Recomendación única

**(a) con frase explícita para `literal_label_rules`**, más dos ítems que el
plan no ofrecía como opción y que no son cambio de gramática:

1. una regla de precedencia en Rails para la intersección exhaustiva + parada de
   la ruta generativa (§11.3), con su test;
2. el bloque `rag.deterministic.*` en `rag.en.yml` como defecto de
   localización, no de safety (§11.4).

No se recomienda (b). La razón central de CG-D16 para temer un cambio —«rompe
el evaluador para la ruta LLM»— no se sostiene en el código: el evaluador de
certificación solo acepta respuestas deterministas en los casos exhaustivos y
de parada (§11.7, C1). Aun así, (b) sigue siendo la opción más cara: toca dos
renderers, evaluador, directivas, dos locales, `code_fingerprint` del benchmark
y unas 25 aserciones, para una gramática que H6 ya excluye del juicio de tono
y que solo aparece en intents estrechos. La frase para `literal_label_rules`
alcanza porque su salida visible ya llega traducida al técnico (§11.5).

### 11.2 Mapa de rutas

Orden del orquestador (`app/services/query_orchestrator_service.rb`):
`DocumentOverviewResponder` (l.228) → `StructuredEvidenceRoute` (l.239–256) →
`AmbiguousModelResponder` (l.258–275) → `DeterministicRenderer` (l.277–288) →
`ContextEvidenceRoute` (l.291–293) → `BedrockRagService#query` (l.295–306).

**Ruta determinista** (`app/services/rag/deterministic_renderer.rb`):

- Existe solo con `force_entity_filter` y al menos un URI (l.31). Elige
  `FunctionalTestRenderer` si `exhaustive_functional_test_query?` y, si no,
  `StopWorkRenderer` si `stop_work_checklist_query?` (l.33–38). Primer match
  gana; no hay renderer combinado.
- Patrones (`app/services/rag/deterministic_intent.rb` l.11–19):
  `pruebas funcionales|de funcionamiento … resultados?` y
  `comprobaciones|verificaciones … detener el trabajo` (más sus formas en
  inglés).
- Un renderer que construye **no vuelve a la generativa**: `failure_result`
  (l.119–137) se entrega tal cual (`query_orchestrator_service.rb` l.285–288).
- Etiquetas desde `I18n.t("rag.deterministic.*")` (l.161–163);
  `functional_test_renderer.rb` l.53–57; `stop_work_renderer.rb` l.51–64.
- Ejemplos: `¿Qué pruebas funcionales previas al uso indica el manual y qué
  resultado esperado tiene cada una?` → `FunctionalTestRenderer`;
  `Antes de operar este equipo, ¿qué comprobaciones debo realizar y en qué
  condiciones debo detener el trabajo?` → `StopWorkRenderer`
  (`test/services/rag/deterministic_renderer_test.rb` l.108–109).

**Ruta generativa** (`app/services/bedrock_rag_service.rb`
`load_generation_prompt_with_locale`, l.949–977):

- `query_safety_directive` (l.1061–1091): regex
  `detener|detenga|parar|pare|stop|prohibir|fuera de servicio` (l.1062). El
  plan omite `detenga` y `pare`. Exige `Precauciones e inspecciones` (l.1067),
  `Detención obligatoria con evidencia explícita` (l.1071) y pares
  `Disparador:` / `Acción obligatoria:` (l.1077–1078).
- `query_completeness_directive` (l.1093–1148): gate `exhaustive_query?`
  (l.1095) sobre `EXHAUSTIVE_PATTERNS` (`rag_retrieval_profile.rb` l.56–65).
  Exige entradas `Prueba:` / `Acción:` / `Resultado esperado:` (l.1125–1127) y
  que «the entire visible response must consist only of those entries. Do not
  use a title, introduction, section header, bullets, separators, notes,
  warnings…» (l.1133–1136).
- Orden de inyección: idioma → `# DELIVERY CHANNEL` (solo web y **solo si no
  hay completitud**, l.967) → contexto de sesión → recordatorio de idioma →
  parada (l.972) → completitud (l.973) → `literal_label_rules` (l.974) →
  contrato de salida (l.975).
- `SAFETY_CRITICAL_PATTERNS` (l.67–71) comparte el vocabulario de parada y
  agrega fallo/reparación; solo mueve `top_k` a 5 con pin (l.89) y excluye la
  `StructuredEvidenceRoute` (`structured_evidence_route.rb` l.60–61). No
  activa gramática.
- Ejemplos: `¿Cuándo debo detener el trabajo?` → solo parada;
  `Enumera todas las pruebas de funcionamiento antes de operar` → solo
  completitud (`bedrock_rag_service_test.rb` l.830–847, l.1466–1485);
  `¿Cómo pruebo el freno?` → ninguna (l.1487–1497).

**Respuesta ordinaria** (§5.1): confirmado. Ninguna directiva se inyecta y la
única mención de la gramática en `generation.txt` es la línea GS l.142 («Do
not restate stop-work or exhaustive grammar»). El bloque base l.126–132, sin
prefijo, ya exige disparador y acción en el mismo fragmento y separa
precaución de parada en prosa: la invariante «precaución ≠ parada» no depende
de la gramática.

### 11.3 Intersección exhaustiva + parada

Consulta: `Dame la lista completa de comprobaciones que obligan a detener el
trabajo.` Evaluada en memoria, sin Bedrock:

| Predicado | Resultado | Evidencia |
|---|---|---|
| `query_safety_directive` | activa | l.1062, `detener` |
| `exhaustive_query?` | activa | `rag_retrieval_profile.rb` l.58 (`lista completa`) y l.62 (`completa`) |
| `stop_work_checklist_query?` | **activa** | `deterministic_intent.rb` l.17: `comprobaciones … detener el trabajo` |
| `exhaustive_functional_test_query?` | no | l.12 pide `pruebas funcionales … resultados` |
| `ContextProjection.applicable?` | no | `context_projection.rb` l.32–34 |
| `top_k` | 15, rerank 12 | l.81 gana sobre l.89 |
| `# DELIVERY CHANNEL` | omitido | l.967 |

Hay dos comportamientos según el pin:

1. **Con pin y `force_entity_filter`:** la consulta va al `StopWorkRenderer`
   (l.36–37) y nunca llega al modelo. No hay conflicto: la gramática la emite
   Rails. La completitud queda implícita en `FULL_SCOPE_CANDIDATES` (l.25).
2. **Sin pin:** `BedrockRagService#query` agrega **las dos** directivas al
   mismo prompt (l.972–973). Verificado: `# STOP-WORK EVIDENCE OVERRIDE` en el
   offset 9.495 y `# EXHAUSTIVE COMPLETENESS OVERRIDE` en 11.022, este último
   más cerca del final. Parada exige dos secciones con encabezado y pares de
   dos líneas; completitud exige que **toda** la respuesta sean ternas
   `Prueba/Acción/Resultado esperado` sin encabezados ni advertencias
   (l.1133–1136). Son incompatibles por construcción.

No existe regla de precedencia ni test de la intersección: ninguna aserción
en `bedrock_rag_service_test.rb`, `regex_characterization_test.rb` ni
`rag_quality_benchmark_evaluator_test.rb` arma un prompt con ambas directivas.
`regex_characterization_test.rb` l.404–425 prueba cada polaridad por separado.

**Clasificación: conflicto estático, no medido.** Riesgo de safety si el
modelo obedece la directiva más reciente (completitud): un disparador de
parada sin `Resultado esperado` documentado queda fuera («never invent a
result… otherwise omit it», l.1116–1122) o se le fabrica uno; la `Acción
obligatoria` no tiene casilla en la terna y es «warning» prohibido por
l.1134; la sección `Precauciones e inspecciones` desaparece. Si obedece
parada, la respuesta viola la gramática de completitud pero no degrada
safety. Mitigación parcial: el bloque base l.126–132 sigue exigiendo
disparador y acción del mismo fragmento. El caso 1 (con pin) es el que hoy
está medido y protegido por el evaluador; el caso 2 no está en ningún
benchmark. La ruta medida en la medición 8 no está desplegada, así que en
producción hoy corre el mismo prompt con las dos directivas.

Hueco análogo en la ruta determinista: una pregunta que empareje los dos
patrones de `DeterministicIntent` cae en `FunctionalTestRenderer` y descarta
los `STOP_WORK_CONDITION` sin aviso (l.33–38). No hay test de esa
intersección.

### 11.4 Locale inglés

`config/locales/rag.en.yml` **no define** `rag.deterministic.*` (las claves
vecinas están en l.30–40; el bloque español está en `rag.es.yml` l.75–82).
Nunca existió: `git show d81220b:config/locales/rag.en.yml` tampoco lo tiene.
No hay test de paridad de locales ni test del renderer con
`response_locale: "en"`.

Efecto verificado con `I18n.t("rag.deterministic.test_label", locale: :en)`:

- **Producción** (`config/environments/production.rb` l.79,
  `config.i18n.fallbacks = true`; `application.rb` l.15 `default_locale = :es`):
  cae al español. Una pregunta en inglés con pin (`Which functional tests apply
  and what are the expected results?`, `regex_characterization_test.rb`
  l.433–435) recibe `Prueba:` / `Acción:` / `Resultado esperado:` con acciones
  y resultados en el idioma del manual. Defecto de localización; el evaluador
  (regex en español, l.277, l.360–361, l.380–381) lo parsea igual.
- **Development y test** (sin fallbacks): las etiquetas visibles son
  `Translation missing: en.rag.deterministic.test_label`. Ningún test lo
  cubre porque todos pasan `response_locale: "es"`.

**No es defecto de safety:** el contenido (acción, resultado, disparador,
acción obligatoria) sale verbatim del `FIELD_RECORD`; solo el rótulo cambia.
Agregar las siete claves en inglés es un cambio de copia; si algún día el
benchmark corre en inglés, el evaluador tendría que aceptar ambos rótulos.

### 11.5 `literal_label_rules` y seguridad preservada

- `literal_label_rules` (l.991–1008) se inyecta vía `visual_label_directive`
  (l.983–989) cuando la pregunta trae `esquema|diagrama|plano|etiqueta|…` y
  `función|identifica|componentes|qué es`. Es independiente de las otras dos
  y puede coexistir con ellas (l.974). Su forma segura es
  `<IDENTIFICADOR>: identificador visible; función: DATA_NOT_AVAILABLE`
  (l.997).
- **En la ruta principal el técnico ya no ve ese token.**
  `AnswerSafetyProcessor#call` (`answer_safety_processor.rb` l.124–138) termina
  en `render_internal_markers` (l.366–373), que reemplaza todo
  `DATA_NOT_AVAILABLE` por `rag.data_not_available`. La línea visible es
  `FRRV1: identificador visible; función: El documento no incluye este dato`.
  CG-D08 ya se cumple para este contrato sin editar la directiva; la frase
  explícita de (a) solo tiene que declarar que el token es contrato del prompt
  y la traducción es la salida.
- **El evaluador quedó desalineado con esa traducción.**
  `validate_primary_visual_case` (l.426–441) exige `data_not_available` en la
  línea visible de cada código primario sobre `result["answer"]`, que en
  `script/rag_quality_benchmark.rb` l.279–299 es la respuesta ya procesada.
  La traducción entró en `f0be176` (2026-07-26); el evaluador no se toca
  desde `9ee05f7` (2026-06-11). Una certificación hoy fallaría
  `visual_primary` para los cinco códigos. Esto es independiente de CG-D16 y
  no lo arregla ninguna de las tres opciones.

Invariantes de §7, estado actual:

| Invariante | Determinista | Generativa |
|---|---|---|
| Precaución no se promueve a parada | `StopWorkRenderer` l.31–37: solo `stop_work?` va a la sección obligatoria; el parser exige el par | directiva l.1081–1088; base `generation.txt` l.126–132 |
| Disparador y acción del mismo fragmento | contrato del `FIELD_RECORD` | l.1081–1083 |
| Resultado no se inventa ni se toma del vecino | verbatim del record; `DATA_NOT_AVAILABLE` se conserva (`deterministic_renderer_test.rb` l.180) | l.1111–1122 |
| Renderer sin modelo | `model_invoked: false` (l.94) | n/a |

Huecos restantes, todos fuera del alcance de (a):

1. Intersección sin pin (§11.3): conflicto estático, sin precedencia ni test.
2. Intersección determinista: primer match gana (l.33–38), sin test.
3. `Resultado esperado: DATA_NOT_AVAILABLE` sale crudo al técnico en el render
   exitoso (`functional_test_renderer.rb` l.56; test l.180). La Fase A tradujo
   solo `failure_result`. Contradice CG-D08 y se conserva a propósito.
4. `ContextEvidenceRoute` (`context_evidence_route.rb` l.11–13) genera por
   `StructuredEvidenceRoute#generation_prompt` (l.548–564), que **no** inyecta
   ninguna de las tres directivas y salta la exclusión de `eligible?`
   (l.59–73 instancia directo). Una pregunta web sin pin con modelo con guion
   de marca conocida o con «resortes … ajust» que además pida parada o lista
   completa se genera sin gramática ni override de parada. Estrecho; no
   desplegado.
5. `rag.en.yml` sin `rag.deterministic.*` (§11.4).
6. Evaluador `visual_primary` desalineado con `render_internal_markers`.

### 11.6 Archivos y tests si se eligiera (b)

Solo para dimensionar; no es la recomendación.

- `app/services/bedrock_rag_service.rb` l.1061–1148 (las dos directivas) y
  l.991–1008; `app/services/rag/functional_test_renderer.rb`;
  `app/services/rag/stop_work_renderer.rb`;
  `script/evaluate_rag_quality_benchmark.rb` l.267–301, l.347–410, l.426–441;
  `config/locales/rag.es.yml` l.75–82 y el bloque nuevo en `rag.en.yml`;
  `script/rag_quality_benchmark.rb` l.36–54 (`code_fingerprint` cambia con
  cualquiera de esos archivos: la certificación v3 deja de ser comparable).
- Tests: `bedrock_rag_service_test.rb` l.830–847 y l.1466–1485;
  `deterministic_renderer_test.rb` l.170–181, l.204–222;
  `rag_quality_benchmark_evaluator_test.rb` l.60–145, l.345–374, l.380–400;
  `regex_characterization_test.rb` l.293–304, l.429–442; más los nuevos de
  intersección (dos rutas), locale inglés y precedencia.

### 11.7 Contradicciones entre plan y código

| # | Plan | Código | Archivo:línea |
|---|---|---|---|
| C1 | CG-D16 (`PLAN_COPILOTO` decisión 16, V3): las etiquetas de las directivas son «la gramática que el evaluador parsea» y sacarlas «rompe el evaluador para la ruta LLM». | El evaluador solo parsea la gramática en `isolated/conversation:3` y `:5`, y para esos casos exige `generation_mode` determinista y `model_invoked == false`. Una respuesta LLM en esos casos ya falla antes de llegar a la gramática. Cambiar el texto de las directivas no puede romper el evaluador; rompe `bedrock_rag_service_test.rb` y la alineación visual entre rutas. | `script/evaluate_rag_quality_benchmark.rb` l.10–12, l.27–28, l.199, l.229–238, l.356; `test/scripts/rag_quality_benchmark_evaluator_test.rb` l.312–326 |
| C2 | §2: «HEAD y `origin/main`: `d81220b`», «cambios … todavía no están commiteados». | HEAD = `origin/main` = `29dd6f2`; working tree limpio. Los cambios del copiloto ya están en `4863045…a7bb177`; este plan es `29dd6f2`. | `git status`, `git log d81220b..HEAD` |
| C3 | `PLAN_COPILOTO` (entrada obligatoria, restricción 6, C6, V9) cita `literal_label_rules` l.1007, parada l.1077, exhaustivo l.1109. | En HEAD están en l.991, l.1061 y l.1093. Las cifras del plan son de `d81220b`. | `app/services/bedrock_rag_service.rb` |
| C4 | §5.3: parada se activa con `detener`, `parar`, `stop`, `prohibir`, `fuera de servicio`. | El regex también incluye `detenga` y `pare`. | l.1062 |
| C5 | §5.3 / §5.5: la ruta generativa sin pin recibe las directivas. | Cierto para `BedrockRagService#query`, falso para `ContextEvidenceRoute`, que genera sin ninguna de las tres directivas. | `context_evidence_route.rb` l.11–13, l.59–73; `structured_evidence_route.rb` l.548–564 |
| C6 | §5.4: `literal_label_rules` «hoy exige la forma segura … `función: DATA_NOT_AVAILABLE`» como salida. | Es la forma que exige el prompt; la salida visible ya lleva el token traducido. El evaluador todavía busca el token crudo en la respuesta visible. | `answer_safety_processor.rb` l.137, l.366–373; `evaluate_rag_quality_benchmark.rb` l.431–440 |
| C7 | §5.5 pide evaluar la consulta como intersección de las dos directivas generativas. | Con pin, la consulta ni siquiera llega al modelo: también empareja `STOP_WORK_PATTERNS`. El conflicto de directivas existe solo sin pin. | `deterministic_intent.rb` l.17; `deterministic_renderer.rb` l.36–37 |
| C8 | `PLAN_COPILOTO` V3: «1 [aserción] en `bedrock_rag_service_test.rb`». | Hay dos tests que fijan la gramática de las directivas, con ocho aserciones sobre etiquetas. | `bedrock_rag_service_test.rb` l.842–845, l.1475–1482 |
| C9 | `PLAN_COPILOTO` «Pruebas que siguen verdes»: `bedrock_rag_service_test.rb` l.853–857 congela la gramática de parada. | Esas líneas son el test de reintento sin filtro. La gramática está en l.842–845. | `bedrock_rag_service_test.rb` |

### 11.8 Matriz del §6 completada

| Pregunta | (a) | (a) + literal explícito | (b) |
|---|---|---|---|
| Conserva el benchmark actual | Sí | Sí | No: cambia `code_fingerprint`, renderers y evaluador |
| Alinea ruta LLM y determinista | Sí, como hoy | Sí | Sí, si se reescriben las dos a la vez |
| Protege precaución ≠ parada | Sí (renderer, directiva, base l.126–132) | Sí | Sí, si el evaluador nuevo lo verifica; riesgo de regresión durante el cambio |
| Evita inventar resultados | Sí en determinista; sí en directiva; **no probado** en la intersección sin pin | Igual | Igual: (b) tampoco resuelve la intersección sin regla de precedencia |
| Cubre identificadores de esquema | No lo nombra | Sí: token es contrato del prompt, traducción es la salida | Sí |
| Resuelve la intersección exhaustiva + parada | No | No | No por sí sola; solo con la regla de precedencia |
| Resuelve locale inglés | No | No | Sí, como parte del alcance |
| Requiere código nuevo | No | No | Sí: ~9 archivos, ~25 aserciones |

Ni (a) ni (b) resuelven la intersección: la resuelve una regla de precedencia
en `load_generation_prompt_with_locale` con su test, y eso es una decisión
separada que este plan no ofrecía. Propuesta para esa decisión: cuando ambas
directivas se activan, manda la de parada y la completitud se limita a «no
omitir ningún fragmento recuperado dentro de esas dos secciones», sin cambiar
etiquetas. Es un cambio Rails de pocas líneas, sin Bedrock, sin tocar la
gramática, sin mover el evaluador.
