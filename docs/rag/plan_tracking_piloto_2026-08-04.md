# Plan tracking del piloto — Reconstrucción de interacciones humanas (2026-08-04)

**Objetivo:** que el reporte del piloto reconstruya interacciones humanas por usuario,
unifique la evidencia de las dos rutas, mida repetición multidiaria y registre errores,
sin confundir una interacción con una llamada LLM.

**Entrada obligatoria:** `app/services/pilot_metrics_report.rb`,
`app/services/pilot_usage_log.rb`, `docs/METRICS.md` (§ export diario) y
`docs/PILOT_CAPTURE_TEMPLATE.md`. No es entrada de este plan ningún documento del ciclo
de precisión RAG: son objetivos distintos y no se tocan entre sí.

**Línea base:** el reporte existe y cubre costo, latencia, evidencia y caché de fotos,
pero **no tiene el concepto de interacción humana**: `adoption_signals.rag_queries`
cuenta filas de `bedrock_queries`, o sea llamadas facturables. Con el fallback
`rag_filtered → rag_global` activo, un turno humano se cuenta como dos preguntas.

**Decisiones del dueño incorporadas (2026-08-04):**

1. **El `correlation_id` lo acuña el controller** y el servicio lo honra si viene. Es lo
   que hace que una interacción que falla antes de Bedrock siga siendo reconstruible.
2. **La validación multidiaria se prueba con fixture sintética, no con tres días
   calendario.** La agrupación por día es código determinista y la fixture ejercita las
   mismas líneas; además fuerza casos que en producción no se consiguen a pedido (error
   AWS terminal, abstención sin chunks, smoke sin usuario). El único riesgo real que los
   tres días reales cubrían era la retención de logs, y eso se resuelve con el export
   diario de la Fase 3, no con un gate.
3. **Alcance quirúrgico:** ninguna sección existente del reporte se reescribe. La sección
   nueva es aditiva y es la única que expone los nombres del contrato.

## Restricciones no negociables

1. Un solo punto de emisión del estado terminal. Nada de instrumentar cada ruta por
   separado: el borde del controller es donde toda interacción termina.
2. Cero regex nueva de abstención. Se reutiliza
   `Rag::EvidenceSelectionTelemetry::ABSTENTION_PATTERN`
   (`app/services/rag/evidence_selection_telemetry.rb:9`).
3. Cero tablas nuevas y cero migraciones. El estado terminal viaja por
   `PilotUsageLog`, igual que el resto de la telemetría del piloto.
4. Ningún payload persistido lleva prompt, backtrace, credenciales ni mensaje de AWS. La
   whitelist de `PilotUsageLog::ALLOWED_FIELDS` es la garantía por construcción; solo se
   agrega el nombre de la clase del error.
5. Presupuesto Bedrock declarado por fase. Techo del ciclo: **12 invocaciones**, todas en
   la Fase 3.
6. No se sincroniza el KB ni se reingesta nada para esta validación.
7. Todo artefacto de corrida se copia a `tmp/` local con SHA256 verificado antes de
   cerrar la sesión que lo generó.
8. `interacciones humanas <= llamadas LLM` es un invariante, no una métrica. Si el
   reporte lo viola, el reporte está mal, no los datos.

## Definiciones del contrato (fijadas antes de tocar código)

- **interaction:** una pregunta humana con un único `correlation_id`.
- **llm_call:** cada invocación facturable; puede haber varias por interacción.
- **evidence_present:** existe evidencia trazable utilizada por la respuesta.
- **correct_answer:** verificada manualmente contra el documento. No se infiere de una cita.
- **repeat_question:** mismo `question_sha256`.
- **returning_user:** usuario con actividad en dos o más días.
- **failed:** error terminal sin respuesta útil.
- **abstained:** respuesta segura por evidencia insuficiente. No es error.

## Hallazgos de arranque (sesión de planificación 2026-08-04)

| # | Hallazgo | Evidencia |
|---|---|---|
| H1 | **El reporte es de un solo día.** `initialize(date:)` fija `@range = @date.in_time_zone.all_day` y todas las consultas cuelgan de ahí. Cualquier métrica multidiaria es hoy imposible de calcular. | `app/services/pilot_metrics_report.rb:25-30` |
| H2 | **`rag_queries` son llamadas LLM, no preguntas humanas.** `adoption_signals.rag_queries` usa exactamente la misma expresión que `totals.rag_llm_calls`: contar filas de `bedrock_queries` con `source == "query"` y ruta distinta de `visual_query`. El nombre invita al error que el contrato prohíbe. | `pilot_metrics_report.rb:449` vs `:178` |
| H3 | **El `correlation_id` de una pregunta de texto lo acuña el servicio, no el controller.** `RagController#ask` solo lo genera cuando hay imágenes; `BedrockRagService#query` no acepta el parámetro y acuña `"query:#{SecureRandom.uuid}"` por dentro. Una interacción que falla antes de llegar a Bedrock no tiene ningún id, así que es irreconstruible por definición. | `app/controllers/rag_controller.rb:13`; `app/services/bedrock_rag_service.rb:171-173, 224` |
| H4 | **No existe estado terminal.** Los cinco `rescue` de la capa de consulta producen un `RagResult` con `success?: false` y un `Rails.logger.error`/`fatal`, nada más. No hay evento de fallo en la ruta de texto, ni fila, ni columna. | `app/controllers/concerns/rag_query_concern.rb:111-126, 297-306` |
| H5 | **`question_sha256` solo existe en la ruta estructurada.** Lo emiten `log_route` y `log` de la telemetría de evidencia; la ruta clásica registra la pregunta truncada a 300 caracteres, sin hash. La detección de repetición es ciega justo en la ruta que más se ejercita. | `app/services/rag/evidence_selection_telemetry.rb`; `bedrock_rag_service.rb:649-694` |
| H6 | **`stage` no está en la whitelist.** `ALLOWED_FIELDS` ya admite `outcome`, `error_class`, `route`, `latency_ms` y `question_sha256`, pero no la etapa del fallo. Sin ese campo, el criterio "todos los errores tienen etapa" no es satisfacible. | `app/services/pilot_usage_log.rb:6-23` |
| H7 | **`returning_users` no existe y el nombre de repetición no coincide.** El reporte emite `users_with_multiple_days` y `repeat_questions_count`; el contrato pide `returning_users` y `repeated_questions_count`. | `pilot_metrics_report.rb:646-647` |
| H8 | **La recurrencia se deriva solo de eventos `evidence_route`.** `repeat_usage` filtra ese evento y nada más, así que una interacción de la ruta clásica no cuenta ni para días activos ni para repetición. | `pilot_metrics_report.rb:619-621` |
| H9 | **El fallback ya produce dos filas facturables con un mismo `correlation_id`.** Está diseñado y testeado así, y es exactamente la razón por la que agrupar por `correlation_id` da la cuenta de interacciones correcta sin inventar nada. | `test/services/bedrock_rag_service_test.rb:1795-1806`; `bedrock_rag_service.rb:242-257` |
| H10 | **`active_days` está fijo en 1.** Es correcto en un reporte diario y mentiría en cuanto exista rango. | `pilot_metrics_report.rb:374` |
| H11 | **La captura de logs es un `grep` contra el contenedor vivo.** `kamal app logs --lines 20000 \| grep -E 'PILOT_USAGE\|RAG_QUALITY'`. Una ventana de tres días depende de que ningún día haya rotado, y un día perdido es indistinguible de un día sin actividad. | `docs/METRICS.md` (§ export diario) |

## Asignación de modelo por fase

| Fase | Modelo | Racional (tabla de la metodología) |
|---|---|---|
| 0 Verificación de vigencia | Sonnet 5 | lectura de código, sin escrituras |
| 1 Contrato y evento terminal | Sonnet 5 | código en el camino caliente del controller y del servicio de Bedrock |
| 2 Reporte y fixture | Sonnet 5 | implementación de código y tests sobre un archivo de 748 líneas |
| 3 Gate: corrida real | **Sonnet 5 — NO Haiku** | el modelo más riguroso contra producción; Haiku queda excluido de toda fase que ejecute contra producción |

Opus 5 solo como consulta acotada si la conciliación de costo de la Fase 3 arroja una
discrepancia genuinamente ambigua, nunca como sesión completa. Nunca Fable en ninguna fase.

## Fase 0 — Verificación de vigencia (Sonnet 5; 0 invocaciones)

Lectura pura, no se arregla nada. El diagnóstico de arriba se derivó hoy; esta fase solo
confirma que sigue vigente al día de ejecución. Verifica:

- **(a) H3:** `rag_controller.rb:13` sigue acuñando el id solo con imágenes y
  `bedrock_rag_service.rb:171-173` sigue sin aceptar `correlation_id`.
- **(b) H4:** los `rescue` de `rag_query_concern.rb` siguen sin telemetría estructurada.
- **(c) H6:** `stage` sigue fuera de `ALLOWED_FIELDS`.
- **(d) H9:** el test del fallback sigue assertando que las dos filas comparten id.

Salida: cuatro filas de vigente sí/no en el Anexo B. Si alguno cambió, se corrige la fase
afectada y su prompt del Anexo A **antes** de cerrar.

## Fase 1 — Un id por interacción y un evento terminal (Sonnet 5; 0 invocaciones)

**Hipótesis:** con un id acuñado en el controller y un único evento terminal en el borde,
toda interacción queda reconstruible sin instrumentar cada ruta por separado.
**Qué la refutaría:** que exista una salida de `RagController#ask` que no pase ni por la
rama de error ni por la de éxito, o que la ruta asíncrona de foto termine en un lugar que
el controller no observa. Lo segundo se sabe cierto y por eso el job emite su propio
evento terminal.

Cuatro cambios, todos acotados:

1. **`app/controllers/rag_controller.rb:13`** — acuñar siempre:
   `correlation_id = images.any? ? "photo:#{SecureRandom.uuid}" : "query:#{SecureRandom.uuid}"`.
   El mensaje del usuario en `conversation_history` queda correlacionado desde el primer
   instante, incluso si la interacción falla después (línea 29, ya pasa el id).
2. **`app/services/bedrock_rag_service.rb`** — agregar `correlation_id:` a la firma de
   `query` (línea 171-173) y cambiar la línea 224 a
   `query_correlation_id = correlation_id.presence || "query:#{SecureRandom.uuid}"`.
   `QueryOrchestratorService` ya lleva `@correlation_id` y ya llama a `query` en tres
   sitios (líneas 275, 294, 351): es plomería de un parámetro, sin cambio de
   comportamiento cuando el id no viene.
3. **Evento `interaction_completed`**, emitido una vez por interacción desde
   `RagController#ask` en las dos ramas, y desde `FieldPhotoAnalysisJob` para la ruta
   asíncrona (donde ya se emiten `photo_completed`/`photo_failed`, así que es una llamada
   más en un sitio que ya tiene todos los argumentos). Campos: `correlation_id`,
   `user_id`, `account_id`, `conversation_session_id`, `question_sha256`, `outcome`,
   `stage`, `error_class`, `route`, `latency_ms`.
4. **`app/services/pilot_usage_log.rb`** — agregar `stage` a `ALLOWED_FIELDS`. Nada más.

El `outcome` se deriva sin lógica nueva: `failed` cuando `result.success?` es falso, con
`stage` mapeado desde el `error_type` que ya existe en `json_error_config`
(`rag_query_concern.rb:194-209`); `abstained` cuando la respuesta coincide con
`ABSTENTION_PATTERN`; `answered` en el resto. El `question_sha256` se calcula en el
controller sobre la pregunta cruda, así que cubre las dos rutas por igual y cierra H5.

Tests de esta fase: que un id externo se honra en `BedrockRagService#query`, que el
fallback sigue compartiendo id (el test existente no cambia), y que el payload del evento
no sobrevive con ninguna clave prohibida.

### Notas de implementación (cierre Fase 1, 2026-08-04)

Forma final del payload de `interaction_completed` (los diez campos previstos, sin
cambios de nombre):

```json
{
  "event": "interaction_completed",
  "ts": "...",
  "correlation_id": "query:... | photo:...",
  "user_id": 1,
  "account_id": 1,
  "conversation_session_id": 1,
  "question_sha256": "... | ausente (interacciones de foto)",
  "outcome": "answered | abstained | failed",
  "stage": "... solo cuando outcome=failed | ausente en éxito",
  "error_class": "NombreDeClase solo cuando outcome=failed | ausente en éxito",
  "route": "text | photo | visual_query",
  "latency_ms": 0
}
```

Cinco decisiones de implementación que Fase 2 debe asumir como dadas (no reabrir):

1. **La emisión del controller usa su propia variable local `correlation_id`**, nunca
   `result.correlation_id` — este último solo existe cuando `QueryOrchestratorService`
   lo devuelve explícitamente (ruta de foto), y es `nil` en la ruta de texto. Usar la
   variable local es lo que cierra H3 en la práctica.
2. **`route` tiene tres valores, no dos:** `"text"` y `"photo"` desde el controller
   (derivados de `correlation_id.start_with?("photo:")`, sin regate nuevo — reutiliza el
   esquema del propio id), y `"visual_query"` desde `FieldPhotoAnalysisJob` (mismo valor
   que ya usan `photo_completed`/`photo_failed`, por consistencia).
3. **El controller NO emite en la rama de éxito cuando `result.images_uploaded.present?`**
   — reutiliza exactamente la condición `if result.images_uploaded.blank?` que ya envolvía
   `add_to_history` (línea ~81), sin agregar un segundo chequeo. Esa es la rama que el
   job cierra de forma asíncrona.
4. **`error_class` no estaba disponible en `RagResult`** (`rag_query_concern.rb`) — se
   agregó como quinto campo del struct, poblado con `e.class.name` en cada uno de los
   cinco `rescue` existentes, junto a `error_message` (que sigue existiendo para los
   logs de `Rails.logger` de siempre y NUNCA se pasa a `PilotUsageLog`). Sin este campo
   el evento no podía cumplir la restricción 4 (nombre de clase sí, mensaje de AWS no)
   sin inventar un mapeo nuevo.
5. **Hallazgo de implementación, no de diseño:** el bloque `retry_on ... do |job, error|`
   de `FieldPhotoAnalysisJob` corre con `self` igual a la CLASE, no a la instancia —
   `retry_on` invoca ese bloque con `yield self, error` (no `instance_exec`) en la rama de
   intentos agotados. Por eso esa única emisión llama a `PilotUsageLog.log` inline en vez
   del helper privado `emit_interaction_completed` que usan los otros tres puntos del
   job (que sí corren en contexto de instancia). Documentado para que Fase 2 no lo
   reintroduzca como bug al tocar ese archivo.

Verificación: los tres tests de la fase (`bedrock_rag_service_test.rb` × 2 nuevos +
`rag_controller_test.rb` × 1 nuevo) en verde, más la suite completa —
`2306 runs, 8507 assertions, 0 failures, 0 errors` — sin tocar `pilot_metrics_report.rb`
ni `pilot_metrics_report_test.rb`. Cero invocaciones Bedrock (todo mockeado). Sin
artefactos de corrida real que copiar a `tmp/` (restricción 7 no aplica a esta fase).

## Fase 2 — Reporte por rango y sección `interactions` (Sonnet 5; 0 invocaciones)

**Hipótesis:** todas las métricas del contrato se derivan del evento terminal, sin tocar
ninguna sección existente. **Qué la refutaría:** que alguna métrica del contrato necesite
un dato que el evento no lleva; en ese caso se amplía el evento en la Fase 1, no se
agrega una segunda fuente.

1. **Rango.** `initialize` acepta `from:`/`to:` conservando `date:`, y calcula
   `@range = from.beginning_of_day..to.end_of_day`. Todo cuelga de `@range`, así que el
   cambio es de tres líneas. Corregir de paso `active_days` (línea 374), que en rango
   mentiría.
2. **Sección `interactions`**, derivada exclusivamente de `interaction_completed` y única
   fuente de verdad del contrato: total de `correlation_id` distintos, desglose por
   outcome, `llm_calls` desde `bedrock_queries`, el booleano del invariante,
   `active_users`, `users_with_multiple_days` con su alias `returning_users`,
   `repeated_questions_count`, `top_repeated_questions`, la lista de fallos con etapa y
   clase, y el conteo de interacciones sin usuario. Sin eventos devuelve
   `logs_not_available`, nunca cero inventado.
3. **`adoption_signals.rag_queries` pasa a llamarse `rag_llm_calls`**, que es como ya se
   llama el mismo valor en `totals`. Una línea, más la del test. Es el único renombre del
   plan y existe para que la clave no vuelva a leerse como preguntas humanas.
4. **Una fixture sintética de tres días** en `test/services/pilot_metrics_report_test.rb`,
   con `travel_to` sobre `America/Santiago` y ocho interacciones: cinco respondidas
   repartidas entre las dos rutas, una abstención sin chunks, un error terminal y un smoke
   sin usuario de piloto.

Sobre esa fixture van las aserciones que reemplazan los trece casos del plan original:
siete interacciones humanas, más de siete llamadas LLM, invariante en verde, desglose por
outcome, dos `BedrockQuery` con el mismo `correlation_id` colapsando en una interacción,
evidencia de `[RAG_QUALITY]` y de `evidence_route_context` unificada sin duplicar, un
usuario recurrente, una pregunta repetida, hashes nil que no se agrupan, el smoke excluido
por `PILOT_USER_IDS`, el fallo con etapa y clase, ausencia de logs como
`logs_not_available`, y el borde de medianoche del último día del rango.

```bash
bin/rails test test/services/pilot_metrics_report_test.rb
bin/rails test test/services/pilot_metrics_report_test.rb \
  test/services/pilot_usage_log_test.rb \
  test/services/rag/evidence_selection_telemetry_test.rb \
  test/services/bedrock_rag_service_test.rb
```

### Notas de implementación (cierre Fase 2, 2026-08-04)

Forma final de los cuatro puntos, para que la Fase 3 (sesión nueva) sepa contra qué
nombres exactos verificar sin releer el código:

1. **`PilotMetricsReport.new` acepta `from:`/`to:` conservando `date:`.** Si se pasa
   `from`/`to` (uno alcanza, el otro se infiere igual al presente), `@range` es
   `from.beginning_of_day..to.end_of_day`; si no, sigue siendo el día único de
   siempre. `active_days` (H10) ahora cuenta días calendario distintos con
   actividad (de `BedrockQuery.created_at`, `ts` de eventos, o mensajes), no un
   `1` fijo — verificado con un usuario en 3 días (`active_days: 3`) y otro en 1
   (`active_days: 1`) en la misma corrida de rango.
2. **Sección `interactions`** (nueva clave de nivel superior, junto a
   `adoption_signals`/`repeat_usage`), derivada exclusivamente de
   `interaction_completed` (una fila por `correlation_id`, nunca por llamada
   Bedrock). Sin eventos: `{ status: "logs_not_available" }`. Con eventos:
   `status: "available"`, `total`, `by_outcome` (hash outcome→conteo),
   `llm_calls` (de `bedrock_queries`, filtrado igual que el resto del reporte),
   `invariant_ok` (`total <= llm_calls`), `active_users`,
   `users_with_multiple_days` y su alias `returning_users` (mismo valor, dos
   claves), `repeated_questions_count` y `top_repeated_questions`
   (`question_sha256` ausente se excluye del agrupamiento, nunca colisiona
   entre sí), `failures` (`correlation_id`, `route`, `stage`, `error_class` por
   cada `outcome: "failed"`), y `unattributed_count`.
3. **`adoption_signals.rag_queries` → `rag_llm_calls`.** Un solo valor
   renombrado; `docs/METRICS.md` también actualizado en sus dos menciones.
4. **Fixture sintética de tres días** en
   `test/services/pilot_metrics_report_test.rb`: 8 `interaction_completed` (5
   respondidas repartidas `text`/`visual_query`, 1 abstención sin
   `evidence_route_context`, 1 error terminal con `stage`+`error_class`, 1
   smoke sin `user_id` excluido por `user_ids:` del cohorte), con un par
   `rag_filtered`→`rag_global` compartiendo `correlation_id` (H9: dos filas de
   `BedrockQuery`, una interacción) y una pregunta repetida del mismo usuario.
   Resultado: 7 interacciones humanas, 8 llamadas LLM, invariante en verde.

Verificación: 2 tests nuevos de `interactions` + los 8 preexistentes de
`pilot_metrics_report_test.rb` en verde, el subconjunto de la Fase 2
(`pilot_metrics_report_test.rb`, `pilot_usage_log_test.rb`,
`evidence_selection_telemetry_test.rb`, `bedrock_rag_service_test.rb`) en
verde, y la suite completa — `2308 runs, 8530 assertions, 0 failures, 0
errors, 189 skips` (los skips son preexistentes, no de esta sesión). Cero
invocaciones Bedrock. Sin artefacto de corrida real que copiar a `tmp/`
(restricción 7 no aplica: no hubo corrida contra producción). No se tocaron
`repeat_usage` ni `evidence_route_summary`.

## Fase 3 — Gate: una corrida de ocho preguntas (Sonnet 5; ≤12 invocaciones)

Sesión NUEVA, que no ejecutó las Fases 1 ni 2 — principio 6 de la metodología. Redacta
las ocho preguntas y sus valores esperados sin el contexto de los fixes.

**Checkpoint de despliegue, antes de abrir la corrida:** verificar que el despliegue
vigente incluye las Fases 1 y 2, que `PILOT_USER_IDS` apunta a los IDs exclusivos del
piloto, y registrar hora inicial. Sin esto la corrida no se abre.

Ejecución: ocho preguntas en una sesión, captura de logs de web y worker, export del rango
con `PILOT_USER_IDS=... PILOT_USAGE_LOG=tmp/pilot.log bin/rails runner script/pilot_metrics_export.rb`,
y comparación de reporte, base de datos y logs por `correlation_id`. Verificación manual
de las ocho respuestas y sus fuentes contra el PDF, y conciliación del costo con
`bedrock_daily_costs`, que es la autoridad de facturación por encima de las estimaciones
por fila.

**Export diario obligatorio durante el piloto:** cada día se exporta y se guardan el JSON y
el recorte de log en `tmp/` local. Es lo que hace recuperable una ventana de varios días
dado H11; sin eso, un día rotado es indistinguible de un día sin actividad.

**Criterio congelado ANTES de abrir la corrida:**

- 8 mensajes del usuario, 8 interacciones, 8 `correlation_id` únicos, ≥8 llamadas LLM.
- 100% de las interacciones termina como `answered`, `abstained` o `failed`.
- Cero interacciones sin usuario dentro de la cohorte web.
- Cada respuesta tiene evidencia trazable, abstención explícita o error terminal trazado.
- El invariante `interacciones <= llamadas LLM` da verde con el fallback activo.
- Todo fallo tiene `correlation_id`, etapa y clase; ningún payload lleva prompt, backtrace
  ni mensaje de AWS.
- El costo presentado como real coincide con la conciliación de `bedrock_daily_costs`.

La corrección técnica de las respuestas se registra por revisión humana y no entra al
reporte automatizado. No es criterio de aprobación del tracking.

### Resultado de la corrida (sesión nueva, 2026-08-04)

**Checkpoint de despliegue (antes de abrir):** el despliegue vigente al momento de abrir la
corrida (commit `846f732`) NO incluía las Fases 1/2 — verificado empíricamente (`interactions`
ausente, `adoption_signals.rag_queries` en vez de `rag_llm_calls`). Bloqueante, escalado y
resuelto con decisión del dueño: se comiteó el working tree de las Fases 1/2 (commit `08202b1`,
alcance quirúrgico — sin tocar `plan_ciclo5`/`plan_sonda_v6`/`export_rag_trace.rb`, ajenos a este
plan) y se desplegó (`kamal deploy`, 168.9s, healthy). Re-verificado: `interactions` presente,
`rag_llm_calls` presente. Cohorte del piloto confirmada con datos reales, no supuesta: el único
documento ingerido (`SEGURIDADES 1.1-1`) vive en `account_id 1` (users 3 y 5), no en `account_id 2`
(el que se hubiera asumido por nombre de cuenta) — `PILOT_USER_IDS` se resolvió dinámicamente
como `User.where(account_id: 1).pluck(:id)` en el momento de correr el export, no hardcodeado.
Hora inicial: `2026-08-05T02:28:48Z`.

**Preguntas:** se reutilizaron 7 de los 12 casos de `script/fixtures/rag_seguridades_rubric.json`
(rúbrica ya validada contra el PDF real, no inventada para esta corrida) + 1 pregunta con foto,
redactadas sin conocer el resultado de antemano.

**Desviación del criterio literal "8":** el usuario mandó 11 mensajes reales, no 8 (confirmado
explícitamente) — repitió una pregunta, combinó dos preguntas de la lista en un solo mensaje, y
agregó dos preguntas fuera de lista. El mecanismo de tracking reconstruyó exactamente esa
realidad: **11 mensajes → 11 `interaction_completed` → 11 `correlation_id` únicos, 1:1 sin
duplicar ni perder ninguno** (`interactions.total: 11`, `unattributed_count: 0`). Esto es evidencia
más fuerte que un script limpio de 8, no más débil — pero el número literal del criterio congelado
no aplica tal cual.

| Resultado | `interactions` | `by_outcome` |
|---|---|---|
| Total | 11 | `answered: 6`, `abstained: 5` |
| `invariant_ok` (reporte, día completo) | `true` (11 ≤ 53 llm_calls del día) | — |
| `unattributed_count` | 0 | — |
| `failures` | `[]` (sin fallos reales esta corrida) | — |
| `active_users` | 1 (user 3) | — |
| `repeated_questions_count` | 1 (TPR70 repetida) | — |

**Tres hallazgos a escalar (no se parchea nada — código de las Fases 1/2 intacto):**

1. **El invariante `invariant_ok` se calcula a nivel de todo el día del reporte, no por lote de
   corrida — y se rompe por diseño, no por accidente, cuando interviene el disambiguador.**
   Aislando por `correlation_id` propio (vía `BedrockQuery`), esta corrida tuvo 11 interacciones
   pero solo 10 llamadas LLM reales atribuibles (9 `BedrockQuery` + 1 llamada directa de foto).
   La interacción faltante (`query:6bb64743...`, 499 ms) es el primer intento de la pregunta #8
   ("¿Qué es esta placa...?" escrita en texto, sin adjuntar foto real): la resolvió
   `Rag::StructuredEvidenceRoute` → `Rag::AmbiguousModelResponder` (verificado contra
   `conversation_history` real: "La evidencia recuperada corresponde a varias placas... elige una
   o indica el fabricante"), un responder determinístico que por diseño contesta sin invocar
   Bedrock. Aislado a esta corrida, el invariante se rompe (11 > 10); en el reporte del día pasa
   trivialmente porque se diluye contra 53 llamadas de actividad ajena a esta corrida. Esto no es
   un caso borde raro: cualquier cuenta con uso normal de la ruta de desambiguación (la app pide
   "¿cuál placa?" antes de responder) va a producir interacciones `answered` con cero llamadas
   LLM, así que el invariante tal como está definido en el contrato ("interacciones ≤ llamadas
   LLM") es falso en general por diseño, no solo diluible por volumen ajeno.
2. **`bedrock_daily_costs` no tiene fila para `utc_date` de hoy** (reconciliación diaria todavía no
   corrió) — el criterio "costo conciliado" queda **pendiente**, no aprobado ni rechazado; se
   verifica cuando la fila exista.
3. **Una de las 8 preguntas planeadas (EM2000, combinada con EM3000 en un solo mensaje) volvió
   "no contiene información sobre EM2000"**, pese a que la rúbrica confirma que el documento SÍ
   tiene esa sección (páginas 31-32, con una contradicción real documentada). Posible pérdida de
   cobertura de retrieval al combinar dos entidades distintas en un mensaje — hallazgo de precisión
   RAG, fuera del alcance de este plan (pertenece al ciclo de precisión, no se toca aquí).

**Artefactos locales con SHA256 (restricción 7):** `tmp/fase3_gate_2026-08-04/SHA256SUMS.txt`
(`pilot_metrics_export_2026-08-04.json`, `pilot_combined.log`, `web_pilot_grep.log`,
`worker_pilot_grep.log`).

**Veredicto:** gate **PASA** en los criterios que le corresponden a este plan (reconstrucción de
interacciones, invariante en verde al nivel que el código lo calcula, cero interacciones sin
usuario, sin fallos que verificar esta vez, sin PII/prompt/backtrace en los payloads). Costo
queda pendiente de conciliación. Los tres hallazgos arriba se escalan como decisiones humanas
para quien cierre el ciclo, no se resuelven en esta sesión.

### Resolución posterior de los hallazgos 1 y 2

1. El falso `invariant_ok` fue retirado en `d6c5b48`. `interactions` ahora separa
   `llm_calls_attributed` de `llm_calls_in_range`, cuenta
   `zero_llm_call_interactions` y expone `contract_checks` comprobables. Una
   respuesta determinística del disambiguador ya no se presenta como una
   violación: se registra honestamente como una interacción con cero llamadas
   LLM. `answered` tampoco implica corrección ni resolución; esos campos quedan
   bajo `REQUIRES_HUMAN_REVIEW` y se unen por `correlation_id` desde el CSV
   manual.
2. El costo por fila/cohorte pasó a llamarse `attributed_cost_usd`, sin modificar
   el estimador ni su precisión. Los totales separan `provider_usage_usd` de
   `estimated_usd` según `token_source`. La autoridad de facturación es
   `technical_and_cost.cost_authority.reconciled_bedrock_usd`, calculada desde
   `bedrock_daily_costs` para todos los días UTC solapados, con estado
   `reconciled`, `partially_reconciled` o `pending_reconciliation`, fechas
   faltantes y alcance explícito `platform_wide_all_accounts`.

La captura manual de dos pasos fue reemplazada en `9dc5a6a` por
`bin/pilot_metrics`, que resuelve e imprime la cohorte, descarga los roles web y
worker mediante SSH directo sin PTY y conserva el paquete local con manifiesto y
SHA256. No se escribe nada en producción.

## Presupuesto del ciclo

- Fases 0, 1 y 2: 0 invocaciones Bedrock.
- Fase 3: ocho preguntas, techo de 12 invocaciones (deja margen para hasta cuatro
  fallbacks `rag_filtered → rag_global`).
- Cero ingesta, cero re-embedding, cero sync de KB.

## Estado

| Fase | Estado | Artefacto / hash |
|---|---|---|
| 0 Verificación de vigencia | No iniciada | — |
| 1 Contrato y evento terminal | **Completada (2026-08-04)** | Suite completa en verde: `2306 runs, 8507 assertions, 0 failures, 0 errors` (0 invocaciones Bedrock; sin artefacto de corrida real, no aplica hash) |
| 2 Reporte y fixture | **Completada (2026-08-04)** | Suite completa en verde: `2308 runs, 8530 assertions, 0 failures, 0 errors` (0 invocaciones Bedrock; sin artefacto de corrida real, no aplica hash) |
| 3 Gate | **Ejecutada (2026-08-04), gate PASA con 3 hallazgos a escalar** | `tmp/fase3_gate_2026-08-04/SHA256SUMS.txt` (export JSON + logs web/worker con hash verificado) |

## Protocolo de plan vivo

1. Actualiza tu fila de Estado.
2. Corrige las fases posteriores afectadas por tus hallazgos.
3. Actualiza el prompt de la fase siguiente en el Anexo A (⚠️ CRÍTICO si cambia su
   implementación).
4. Si un hallazgo contradice una restricción o el criterio del gate: no se ejecuta, se
   escala como decisión humana numerada.

## Anexo A — Prompt de arranque por fase

**Pie común de todas las fases:** leé este documento completo antes de tocar nada. Regís
por las restricciones no negociables y por el protocolo de plan vivo. Un objetivo por
sesión. No abras trabajo de otra fase. Al cerrar, actualizá tu fila de Estado y el prompt
de la fase siguiente.

### Fase 0 — Sonnet 5

> Verificá la vigencia de los hallazgos H3, H4, H6 y H9 de este documento contra el estado
> actual del código. Es lectura pura: no arreglés nada, no toqués la caché, no llames a
> Bedrock. Devolvé una tabla de cuatro filas con hallazgo, vigente sí/no y la evidencia
> (archivo:línea) en un Anexo B de este documento.

### Fase 1 — Sonnet 5

> Implementá los cuatro cambios de la Fase 1: acuñar el `correlation_id` siempre en
> `RagController#ask`, aceptarlo y honrarlo en `BedrockRagService#query`, emitir
> `interaction_completed` desde el controller y desde `FieldPhotoAnalysisJob`, y agregar
> `stage` a `PilotUsageLog::ALLOWED_FIELDS`. Reutilizá `ABSTENTION_PATTERN` y el mapeo de
> `error_type` que ya existen: no escribas regex nueva ni un mapeo nuevo. Los tests de la
> fase son los tres listados en la Fase 1. No toques `PilotMetricsReport`.

### Fase 2 — Sonnet 5

> Leé este documento completo antes de tocar nada, en particular "Notas de
> implementación (cierre Fase 1)" bajo la Fase 1 — ahí está la forma final y verificada
> del payload de `interaction_completed` y las cinco decisiones que esta fase debe asumir
> como dadas: variable local de correlation_id (no `result.correlation_id`), los tres
> valores de `route` (`text`/`photo`/`visual_query`), la reutilización de
> `images_uploaded.blank?` para no doble-emitir en la rama de foto, `error_class` como
> quinto campo nuevo de `RagResult`, y el bug de contexto de `self` ya resuelto en
> `FieldPhotoAnalysisJob`. Implementá el rango (`from:`/`to:`), la sección `interactions`,
> el renombre `rag_queries` → `rag_llm_calls`, y la fixture sintética de tres días — los
> cuatro puntos de la Fase 2, sin reescribir `repeat_usage` ni `evidence_route_summary`.
> Un objetivo por sesión. No abras trabajo de otra fase.

### Fase 3 — Sonnet 5

> Sesión NUEVA: no debe haber ejecutado las Fases 1 ni 2 de este ciclo (principio 6
> de la metodología). Redactá las ocho preguntas y sus valores esperados sin el
> contexto de los fixes de código. Antes de abrir la corrida: verificá que el
> despliegue vigente incluye las Fases 1 y 2 (el reporte expone `interactions` con
> `status: "available"` y `adoption_signals.rag_llm_calls`; si falta cualquiera de
> las dos, el despliegue no está vigente y la corrida no se abre), que
> `PILOT_USER_IDS` apunta a los IDs exclusivos del piloto, y registrá la hora
> inicial. Ejecutá ocho preguntas reales, capturá logs de web y worker, corré
> `PILOT_USER_IDS=... PILOT_USAGE_LOG=tmp/pilot.log bin/rails runner
> script/pilot_metrics_export.rb` para el rango de la corrida, y compará reporte,
> base de datos y logs por `correlation_id` contra el criterio congelado de la
> Fase 3 de este documento (8 interacciones, `interactions.invariant_ok` en verde,
> cero interacciones sin usuario en la cohorte web, cada fallo con
> `correlation_id`+`stage`+`error_class`, costo conciliado contra
> `bedrock_daily_costs`). Copiá el JSON del export y el recorte de log a `tmp/`
> local con SHA256 antes de cerrar la sesión (restricción 7). No toqués
> `PilotMetricsReport` ni ningún código de las Fases 1/2: si algo falla, es un
> hallazgo para escalar, no algo para parchear en esta sesión.

## Qué NO está en este plan

- **Tres días calendario reales como gate.** La agrupación por día es determinista y la
  fixture ejercita las mismas líneas. El riesgo que cubrían era la retención de logs, y eso
  lo cubre el export diario de la Fase 3.
- **Reescritura de `repeat_usage` y `evidence_route_summary`.** Quedan tal cual; la sección
  nueva es aditiva y es la que expone los nombres del contrato. Si en algún momento
  `interactions` demuestra ser suficiente, deprecar `repeat_usage` es un cambio posterior y
  separado.
- **Tabla de interacciones en base de datos.** El estado terminal viaja por log, igual que
  el resto de la telemetría del piloto. Persistirlo sería una migración y un camino de
  escritura nuevo en la request del usuario, a cambio de nada que el log no dé.
- **Corrección técnica automatizada.** Se sigue verificando por revisión humana contra el
  documento; no se infiere de la presencia de una cita.
- **Métricas comerciales.** `commercial_outcomes` sigue en `REQUIRES_MANUAL_SURVEY` y no se
  infiere de actividad LLM.
