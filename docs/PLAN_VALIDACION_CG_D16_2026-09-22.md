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
