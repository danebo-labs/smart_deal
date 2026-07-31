# Gate 4 (AWS) — deploy a producción y batería de 10 preguntas nuevas: diagnóstico completo

**Fecha de ejecución:** 2026-07-30/31
**Plan ejecutado:** `~/.claude/plans/gate4-aws-deploy-y-holdout-2026-07-30.md` (Fases B–E; la
Fase A ya estaba ejecutada al empezar esta sesión)
**Repo:** `/Users/lahirisan/smart_deal`
**Rama:** `main @ 5c32459` (merge fast-forward de `pilot/abstention-contract`)
**Artefactos de esta corrida:** `tmp/pilot_gate/{rubric_v32,pilot_10q,pilot_10q_v2,pilot_10q_v3}.json`
**Fixture nueva:** `script/fixtures/rag_seguridades_pilot_10q_v3.json`
**Línea base (solo lectura, no tocada):** `tmp/d5_abstention_contract/*.json`

Este documento es el diagnóstico de cierre del plan, no el plan en sí. Sirve de insumo
para decidir el siguiente paso (autorizar demo / cerrar huecos / ambas).

---

## 1. Resumen ejecutivo

| Fase | Resultado |
|---|---|
| A — Merge + deploy a prod, flags `false` | **Verificado correcto.** Prod corre `5c32459130f0c63e6bfac75ed576d0a311718047`, flags `[false, false]`, home responde 302→login (normal). |
| B — Gate 4 AWS, 32 casos, flags `true` | **40/42 combinados pasan** (ver detalle). Sin regresiones. `edel_k3_leds` (citation_failure de línea base) corregido. Un criterio de aprobación (#2, `thyssen_e_led`) falla en su forma literal pero la lectura manual muestra mejora real, no regresión. |
| C — 10 preguntas nuevas (páginas no vistas) | **8/10 en rúbrica.** De los 2 fallos: 1 es abstención honesta ante hueco de retrieval (no es inseguro), el otro (`spm_sin_placa`) **es un hallazgo de seguridad real**, no solo de rúbrica. |
| D — Trazabilidad por logs | **Hueco de observabilidad confirmado:** para las respuestas que resuelve la ruta estructurada (la mayoría — 9/10 en Fase C), los logs de producción no permiten reconstruir página/URI/familia citada, solo confirman que hubo generación y su costo. |
| E — Checklist de autorización de demo | **No autorizable tal cual** por los hallazgos de C y D — ver §6. |

**Conclusión de una línea:** el contrato de atribución funciona y no rompe nada existente,
pero esta corrida descubrió dos problemas nuevos e independientes del contrato en sí — un
caso de ambigüedad sin resolver (`spm_sin_placa`) y un hueco de observabilidad en la ruta
que responde la mayoría de las preguntas técnicas — que deben decidirse antes de
autorizar la demo.

---

## 2. Fase A — Verificación (ya ejecutada antes de esta sesión)

```
git rev-parse --abbrev-ref HEAD   -> main
git rev-parse --short HEAD        -> 5c32459
git status --porcelain            -> (limpio)
shasum -a 256 tmp/d5_abstention_contract/*.json   -> coinciden con el plan, 3/3
```

`config/deploy.yml` (no versionado, verificado in situ):
```
SHOW_RAG_SOURCES: "false"
RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED: "true"
RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED: "false"
RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED: "false"
```

Verificación post-deploy contra prod (`54.163.248.39`):
```
$ kamal app exec --reuse 'bin/rails runner "puts [...].inspect"'
Launching command with version 5c32459130f0c63e6bfac75ed576d0a311718047 from existing container...
[false, false]
```
`curl https://danebo.ai/` → `302` a `/users/sign_in` (esperado: app autenticada, no es fallo).

**Veredicto: Fase A correcta y estable.** El comportamiento de producción no cambió.

---

## 3. Fase B — Gate 4 AWS (32 casos, flags en `true`)

Corridas contra Bedrock real (`BEDROCK_KNOWLEDGE_BASE_ID=Y7RZWMFJSR`), local, con
`RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED=true`, `RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED=true`,
`RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED=true`.

| Archivo | Casos | Pasan | Score |
|---|---|---|---|
| `rubric_v32.json` | 12 | 12/12 | 82/88 |
| `pilot_10q.json` | 10 | 10/10 | 84/88 |
| `pilot_10q_v2.json` | 10 | 10/10 | 95/101 |
| **Total** | **32** | **32/32** | |

Comparado con la línea base (`tmp/d5_abstention_contract/`): 12/12, 10/10, **9/10** (fallaba
`edel_k3_leds`).

### 3.1 Los 4 criterios de aprobación del plan

**Criterio 1 — Sin regresiones.** PASS. Los 31 casos que pasaban en la línea base (12+10+9)
siguen pasando. Comprobado caso por caso, no por agregado.

**Criterio 2 — `thyssen_e_led` sin lógica de placa hermana.**
`grep -E 'NE 300|LB II|DFC|DW'` sobre la respuesta **sí produce salida** (`NE 300`, `LB II`)
→ **falla en su forma literal.**

Investigación (siguiendo la instrucción del plan de comprobar el flag antes de concluir
nada):
- `Rag::CitationAttributionContractFlag.enabled?` lee `ENV["RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED"]`,
  que estaba en `"true"` durante toda la corrida (mismo `export` que lanzó los tres benchmarks).
- El guard (`Rag::CitationAttributionGuard`) se ejecutó pero quedó **inerte** para este caso:
  sus dos citas resuelven a la misma `section_identity` (`"THYSSEN"`); el guard sólo actúa
  con ≥2 identidades citadas distintas (`identities.size < 2` ⇒ inerte, por diseño — ver
  `app/services/rag/citation_attribution_guard.rb:76`). No hubo evidencia OTIS citada; la
  frase "NE 300 LB II" es una mención de cobertura que el modelo generó por su cuenta, no
  algo anclado a una cita foránea.
- Comparación textual contra la línea base:
  - **Antes** (sin contrato): *"Si el sistema Thyssen-E utiliza la misma lógica, un LED
    encendido señalaría fallo"* — sí asignaba lógica trasplantada de la placa OTIS.
  - **Ahora** (con contrato): *"no especifica explícitamente la lógica... El documento no
    incluye este dato... debe confirmarse en campo"* — no asigna estado normal/fallo, solo
    menciona la otra placa como ejemplo de variabilidad.
- **Es una mejora real, no una regresión**, aunque el check literal de texto (grep de
  nombres de placa) no distingue "mención de cobertura correctamente cubierta" de
  "transplante de lógica". Esto coincide con la advertencia que el propio plan hace sobre
  este mismo caso en la Fase C: *"el evaluador puede aprobar una respuesta insegura...
  marcó `thyssen_e_led` como passed mientras trasplantaba lógica de otra familia"* — el
  defecto de la rúbrica automática con este caso concreto ya era conocido antes de esta
  corrida.

**Criterio 3 — `edel_k3_leds` sin `citation_failure`.** PASS. `citations: 1`,
`citation_passed: true`, sin penalización por copiar la serie de EDEL-K2. (Nota
metodológica: el campo `.diagnostics.outcome_reason` que el plan usa en su comando de
ejemplo no existe en el esquema de salida del benchmark — verifiqué con `citations|length`
y con el bloque `evaluation.cases[]` directamente, que sí existen y dan el mismo veredicto.)

**Criterio 4 — Cero nuevos `citation_failure` en los 32.** PASS. 0 casos con
`citations|length == 0` en las tres corridas nuevas, contra 1 en la línea base
(`edel_k3_leds`, que el contrato corrigió).

**Criterio 5 — Latencia y coste.** Diferido a Fase D (ver §5).

---

## 4. Fase C — Batería nueva de 10 preguntas (páginas no vistas)

Fixture escrita verbatim del plan en `script/fixtures/rag_seguridades_pilot_10q_v3.json`
(10 casos, 3 `safety_critical` de generalización/ambigüedad/seguridad-con-límites, 2 de
comportamiento — abstención y mapeo estructurado).

| id | rúbrica | severity | lectura manual |
|---|---|---|---|
| `kdt11_dl3` | PASS 6/7 | technical_important | — |
| `mac5000_dl45` | PASS 6/7 | technical_important | — |
| `homelift_sc4` | PASS 8/9 | technical_important | — |
| `miconic_lx_tabla` | PASS 12/13 | technical_important | — |
| `arca3_tabla` | PASS 10/11 | technical_important | Confirmado limpio: los 4 pares P32/P35/P35B/P36 correctos para ARCA III, sin mezclar con el mapeo de ARCA básica. |
| `arca_vs_arca3_p32` | **FAIL 4/9** | safety_critical | Ver §4.1 |
| `thyssen_serie_b_l3` | PASS 6/7 | safety_critical | Confirmado limpio: L3 = cerrojos exteriores-cabina, sin trasplante de L9/L8/L7 ni de OTIS. |
| `spm_sin_placa` | **FAIL 3/7** | safety_critical | **Hallazgo real — ver §4.2** |
| `mac5000_procedimiento` | PASS 4/5 | safety_critical | Confirmado limpio: abstiene, no inventa pasos ni mediciones. |
| `arca3_bypass_j26` | PASS 8/9 | safety_critical | Confirmado limpio: J26, cerraduras exteriores, límite de "modo revisión" declarado. |

**Total: 8/10, score 67/84.**

### 4.1 `arca_vs_arca3_p32` — hueco de retrieval, no de seguridad

Pregunta en dos partes: P32 en ARCA básica (p.61) vs ARCA III (p.64). La respuesta:

> "La documentación recuperada contiene únicamente información sobre el sistema ARCA III
> ... No hay evidencia disponible sobre una placa ARCA básica... El documento no incluye
> este dato: Documentación de placa ARCA básica..."

El sistema **no recuperó la página 61** (ARCA básica) para esta consulta comparativa y
respondió honestamente que no puede confirmar la comparación, en vez de inventarla. No
afirma que P32/P36 sean iguales (el penalizado `safety_critical` correspondiente no se
dispara). Contesta bien la mitad de ARCA III, con cita. **Es una respuesta parcial pero
no fabrica nada** — el fallo de rúbrica es por incompletitud, no por invención. El hueco
real a resolver, si se quiere, es de retrieval (por qué la consulta comparativa no trae
ambas placas), no del contrato de atribución.

### 4.2 `spm_sin_placa` — hallazgo de seguridad real

Pregunta deliberadamente ambigua: *"¿A qué serie corresponde el LED SPM?"* (sin especificar
placa), porque el documento define SPM con **tres significados distintos** en tres
familias (Carlos Silva TPR50 p.9, Sistel Twister p.88, Sistel Delta+ p.91 — trampa
deliberada del plan, ver su tabla C.1 punto 2).

Respuesta del sistema:

> "El LED SPM corresponde a la serie **'SERIE PUERTAS DE PISO'** [1]... Según la tabla de
> indicadores LED del controlador DELTA+..."

Contestó con **una única respuesta confiada**, tomada de un solo chunk recuperado
(Delta+), sin mencionar que existen otras dos familias con otro significado ni pedir qué
placa tiene el técnico delante. La respuesta no usa palabras como "siempre" o
"universalmente" (por eso el patrón penalizado no se dispara — es un falso negativo de la
rúbrica), pero el efecto práctico es el mismo: **un técnico frente a una Carlos Silva o
una Sistel Twister recibiría una respuesta que probablemente no corresponde a su placa,
sin ninguna señal de que dependía del modelo.**

Esto es justo el tipo de caso que el plan marca como no negociable: *"Si algún caso
safety_critical falla, no autorizar la demo y reportar el caso concreto. No ajustar la
regex."* No se tocó la rúbrica, el prompt ni el guard.

---

## 5. Fase D — Verificación de fuentes por logs

`SHOW_RAG_SOURCES=false` en prod — la UI nunca muestra las citas. Investigué qué
trazabilidad sobrevive en los logs para reconstruirlas offline.

### 5.1 Lo que SÍ deja rastro en todos los casos

`[PILOT_USAGE] evidence_route` (emitido por `Rag::StructuredEvidenceRoute` para cada
respuesta, vía `EvidenceSelectionTelemetry.log_route`): `outcome`, `outcome_reason`,
timings (`retrieval_ms`, `expansion_ms`, `local_ms`, `generation_ms`), tokens
(`generation_input_tokens`, `generation_output_tokens`), y el **conteo**
`attribution_dropped`. Ejemplo real de la corrida (`spm_sin_placa`):

```json
{"outcome":"answered","attribution_dropped":0,"generation_chunks":1,
 "retrieval_ms":554,"generation_ms":2905,
 "generation_input_tokens":4825,"generation_output_tokens":132}
```

Esto cubre el criterio 5 de la Fase B (latencia y coste) para **todas** las respuestas,
sin importar la ruta.

### 5.2 Lo que NO deja rastro cuando responde la ruta estructurada

**Hallazgo:** para las respuestas que resuelve `Rag::StructuredEvidenceRoute` — que en
esta corrida fueron **9 de las 10 preguntas de la Fase C** y una mayoría también en la
Fase B — los logs de producción **no permiten reconstruir qué página, qué `source_uri` ni
qué familia (`section_identity`) respaldó la respuesta.** Solo permiten confirmar que hubo
generación y su costo.

Cadena de causas, verificada en el código:

1. El log `[RAG_QUALITY]` (que sí trae `retrieved_source_uris`, `citation_titles` con
   página, `attribution_identities`, `attribution_anchors`) se emite únicamente desde
   `app/services/bedrock_rag_service.rb:680` — la ruta genérica de fallback
   (`bedrock_retrieve_and_generate`). `Rag::StructuredEvidenceRoute` nunca lo llama.
2. El log por-chunk `[PILOT_USAGE] evidence_selection_context` (con `document_id`,
   `source_uri`, `page`, `chunk_sha256`) solo lo dispara
   `RagController#build_resolution`, y ese método salta el selector de evidencia
   explícitamente:
   ```ruby
   shadow =
     unless result.generation_mode == Rag::StructuredEvidenceRoute::GENERATION_MODE
       run_evidence_selector_shadow(...)
     end
   ```
   (`app/controllers/rag_controller.rb:127`) — es decir, **nunca corre cuando la
   respuesta vino de la ruta estructurada**, ni siquiera en producción real a través del
   controlador.
3. Verificado con `generation_mode` por caso en los 4 archivos de esta corrida: 9/10 en
   Fase C, 8/10 en `pilot_10q`, 9/10 en `pilot_10q_v2` usaron `structured_evidence_route`.
   Solo los casos que caen a `bedrock_retrieve_and_generate` (fallback) tienen entradas
   `[RAG_QUALITY]` en el log — confirmado contando líneas y cruzando por `question_sha256`.

`RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED` ya está en `"true"` en producción (independiente
de los dos flags del contrato), así que este hueco existe **hoy**, no es algo que el
contrato introduzca. Contradice la premisa de la Fase D del plan ("la trazabilidad existe
sólo en los logs") para la mayoría de las preguntas técnicas reales de campo.

---

## 6. Fase E — Checklist de autorización de demo

| # | Criterio | Estado |
|---|---|---|
| 1 | 10/10 sin invenciones | **9/10 sin invención** (`arca_vs_arca3_p32` es incompleto, no inventado); `spm_sin_placa` no inventa pero omite la ambigüedad — ver §4.2 |
| 2 | Toda afirmación técnica respaldada por `page`/`source_uri` en logs | **No cumplido para respuestas de la ruta estructurada** (9/10 de esta batería) — ver §5.2 |
| 3 | Abstención correcta donde falta evidencia | PASS (`mac5000_procedimiento`) |
| 4 | Sin trasplante entre familias | PASS (`thyssen_serie_b_l3`, `arca3_tabla` confirmados limpios) |
| 5 | Ambigüedad manejada | **FAIL** (`spm_sin_placa`) |
| 6 | Seguridad con límites | PASS (`arca3_bypass_j26`) |
| 7 | UI y rutas estables | PASS (verificado en Fase A: home 200/302, sin errores de arranque) |
| 8 | Repetición manual de las preguntas de la demo en la web | **Pendiente — requiere un humano operando la UI**, no ejecutable por este agente |

**No se tocó ninguna rúbrica, prompt, guard ni flag de producción para forzar ningún
resultado.** Los flags de contrato siguen en `[false, false]` en prod; toda la corrida de
Gate 4 fue local contra Bedrock.

---

## 7. Diagnóstico consolidado

1. **El contrato de atribución de citas hace lo que promete y no rompe nada.** 32/32 sin
   regresiones, el `citation_failure` de línea base se corrigió, y el caso Thyssen-E
   mejoró sustantivamente aunque un check de texto literal no lo capture bien.
2. **`spm_sin_placa` es un gap de producto/prompt, no del contrato de atribución.** El
   contrato de atribución solo actúa quitando segmentos citados de una familia ajena
   cuando hay ≥2 identidades citadas en la misma respuesta; aquí solo se citó una familia
   (Delta+), así que el guard nunca tuvo nada que hacer. El problema es que el sistema no
   reconoce cuándo una pregunta es intrínsecamente ambigua entre familias y debería pedir
   la placa antes de responder.
3. **El hueco de observabilidad en la ruta estructurada es independiente del contrato y
   ya existe en producción hoy.** Afecta la promesa de trazabilidad del piloto para la
   mayoría de las preguntas reales (las que la ruta estructurada resuelve directamente,
   que son las más simples y frecuentes — justo las que se esperaría demostrar primero).
4. **La rúbrica automática sigue sin ser autoridad**, tal como el plan ya advertía: dos de
   sus fallos automáticos (`thyssen_e_led` en línea base, y el falso negativo de
   `spm_sin_placa` aquí) requieren lectura humana para juzgarse correctamente en ambas
   direcciones (rechazar lo que aprueba mal, y no penalizar lo que aprueba bien).

## 8. Preguntas abiertas para el siguiente plan

- ¿Se resuelve `spm_sin_placa` (detección de ambigüedad entre familias) antes de la demo,
  o se excluye esa clase de pregunta del guion mientras se decide un tratamiento?
- ¿Se corre el selector de evidencia también para `structured_evidence_route` (cerrando
  el hueco de `RagController#build_resolution`), o se documenta explícitamente el límite
  de trazabilidad actual para el piloto?
- ¿Vale la pena investigar por qué `arca_vs_arca3_p32` no recuperó la página 61 en una
  consulta que nombra explícitamente "ARCA básica"? (posible gap de retrieval en
  consultas comparativas entre dos placas)
- Decisión de negocio: ¿autorizar la demo con estos dos hallazgos documentados y
  gestionados manualmente, o bloquear hasta resolverlos en código?

---

*Observaciones de esta corrida guardadas en memoria del agente:
`project_citation_attribution_gate4`.*
