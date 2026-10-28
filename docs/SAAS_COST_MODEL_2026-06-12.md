# Costos consolidados — Danebo Vertical

**Actualizado: 2026-10-28.** Este documento conserva su ruta histórica para no romper referencias. Las secciones anteriores al anexo son la referencia vigente de costos; el anexo conserva evidencia de junio/agosto y no fija precios actuales.

**Producto:** el companion y el intérprete forman parte de Danebo Vertical. No se presupone una versión comercial sin ellos. **Estado financiero:** unitarios parciales disponibles; costo completo por turno y conciliación global todavía pendientes. Los importes son USD antes de impuestos, salvo indicación expresa.

## 1. Alcance y procedencia de la evidencia

- Código base leído: `39f2d63c54b6d7fa5d40da0d632033a892a9e82f`. La auditoría de Grok del 28 de octubre identifica esa misma imagen en el export de 14:01 UTC; capturas del 27 identifican `e45088fd` y las del 26, `1bdf5eb`.
- La auditoría recibida por Lahiri se denomina `INFORME_LLAMADAS_Y_COSTOS.md`, en `tmp/auditoria_llamadas_2026-10-28/`, con `escenarios.csv`, `ejemplos_correlation.csv`, `componentes_costo.csv`, `configuracion.csv` y `faltantes.csv`. Esos archivos viven en el entorno de Grok y no están versionados ni se consideran enlaces disponibles en un clon. Este consolidado incorpora el informe compartido; los CSV detallados no se han inspeccionado aquí.
- Los valores de ingesta e infraestructura se contrastaron con los archivos entregados por Lahiri: `costos_unitarios.csv` e `infra_24x7.csv`. No se afirma haber consultado AWS de nuevo durante esta consolidación.
- Distinguir código, configuración de deploy, proceso observado y gasto facturado. El informe no leyó todo el env del contenedor ni ejecutó `GetKnowledgeBase`.
- Ninguna llamada nueva a modelos ni cambio de código, configuración o infraestructura fue necesario para esta actualización documental.

## 2. Unidad de consumo y recorrido actual

Un **turno** es un mensaje del técnico y la respuesta de Danebo; puede ejecutar varias operaciones. Un **caso** agrupa varios turnos de una falla. Los 3–5 turnos mencionados por Gonzalo son una hipótesis de consumo, no una garantía de resolución ni una regla técnica de corte.

Ruta textual medida, equipo conocido y manual compatible:

```text
mensaje → Converse del intérprete Haiku → Retrieve de la KB
        → Converse companion_plan → comprobación/render en Rails
```

Son tres operaciones externas en el recorrido exitoso básico. El embedding interno del Retrieve puede invocar otro modelo sin una llamada Rails explícita. Reintentos, descubrimiento y respaldos pueden ampliar el recorrido.

`companion_plan` ES la generación de esa rama: no se suma otra generación después. El companion como producto no debe confundirse con el nombre de esta rama; otras ramas del mismo producto generan con `InvokeModel`.

`RetrieveAndGenerate` dejó de tener llamador en `app/` desde [0832d6e](https://github.com/danebo-labs/smart_deal/commit/0832d6ed496d1f0839bc30c340e4451ccb62466d), 5 de octubre. El método permanece; su existencia o la etiqueta `generation_mode=generative` no prueban ejecución. La imagen del 3 de octubre todavía podía usar hasta dos RetrieveAndGenerate. No mezclar esas cohortes.

| Escenario | Operaciones y condiciones |
|---|---|
| Texto con identidad conocida y manual compatible | Intérprete + Retrieve + companion_plan; según condiciones de la rama, la generación puede ser InvokeModel en su lugar |
| Identidad conocida sin manual compatible | Intérprete + Retrieve + generación de guía por InvokeModel |
| Identidad desconocida | Intérprete + Retrieve + publicación por Converse o guía por InvokeModel; si la publicación es rechazada puede añadirse generación de respaldo |
| Aclaración/meta con salida local | Intérprete y respuesta local; sin búsqueda/generación cuando la policy corta ahí |
| Pin no forzado que vuelve vacío | Puede añadirse otro Retrieve sobre corpus abierto en la rama descrita por la auditoría; no convierte en público el contenido ni elimina la autorización |
| Foco + abstención + descubrimiento permitido | Puede añadirse Retrieve con route_taken=document_discovery; no es otra generación |
| Error transitorio del intérprete | Hasta tres intentos Converse; sin usage no se deduce costo cero |
| Aurora en pausa | Reintentos físicos de Retrieve; un único kb_retrieve exitoso no cuenta todos los intentos |
| Foto nueva con texto | Intérprete en request + visión en job; búsqueda/generación posterior si PHOTO_QUESTION_RAG_ENABLED=true, sin repetir intérprete |
| Foto nueva sin texto | Visión; no intérprete del texto inexistente ni RAG de pregunta inexistente |
| Seguimiento con observación reutilizada | No nueva visión; intérprete y búsqueda/generación que corresponda al seguimiento |
| Relectura explícita | Nuevo análisis visual de los bytes guardados |
| Warmup | Retrieve de "warm", k=1; operación compartida, no turno vendido |

### Configuración observada y límites

El informe identifica `owner`, episodio/turno/alcance de identidad activos y sesión compartida apagada en la captura del 27. Intérprete y plan usan `global.anthropic.claude-haiku-4-5-20251001-v1:0`; Retrieve observado: HYBRID, k=3 con foco, sin reranking.

Cohere Rerank v3.5 solo se solicita si `BEDROCK_RERANKER_ENABLED=true` y la pregunta es exhaustiva. No aparece en los payloads observados ni en usage de Cohere: no cargar una cuota ficticia. El ranking normal híbrido no equivale al modelo de reranking.

Nova no está en la ruta auditada de `Y7RZWMFJSR`; la referencia histórica corresponde a otra KB. Titan v2 está nombrado en el deploy y es el default de atribución, pero falta confirmar el ARN interno real con GetKnowledgeBase.

El deploy local dice PHOTO_QUESTION_RAG_ENABLED=true; el ejemplo versionado dice false. Falta confirmar el flag del contenedor y una traza posterior al 5 de octubre que junte foto nueva, texto, visión y respuesta RAG. No inferir ese recorrido a partir de una foto sola.

## 3. Unitarios disponibles: no son todos costo completo

| Unidad/ruta | Muestra y costo USD | Cobertura / límite |
|---|---|---|
| Intérprete + companion_plan | 20 turnos de desarrollo, 24–26 oct; **0,009713/turno**; intérprete 0,003527 + plan 0,006186 | Usage del proveedor, reconstruido con tarifa de código. No incluye embedding/búsqueda vectorial, fotos, reranking, warmup, soporte ni impuestos |
| Intérprete + query_direct (InvokeModel) | 139 correlaciones; **0,013556/turno**, total 1,884296 | Otra ruta; NO sumar al unitario anterior |
| Plan, ejemplo del 27 oct | query:94499190-12c1-49a0-9f88-aa2b1ecc607f; **0,010259** = 0,003242 + 0,007017 | Intérprete 2627/123 tokens; plan 5277/348. Embedding no medido por correlación |
| Seguimiento, ejemplo del 27 oct | query:0ecc5031-4f62-4853-adb4-df2b4057ffe3; **0,008415** | Reconstrucción del intérprete + plan, sin búsqueda |
| Pilotos anteriores Gonzalo / Jesús | **0,011481 / 0,009800** por turno; 361 / 196 correlaciones | Ruta anterior, en gran parte estimated; no incluye intérprete vigente. No es unitario del companion actual |
| Foto nueva Sonnet 5.5 directo | 10 análisis; **0,012539/foto** | Solo visión, muestra pequeña; no es mezcla Sonnet/Opus ni turno completo con pregunta |
| Foto nueva Sonnet 4.6 directo | 41 análisis; **0,019482/foto** | Histórica; no promediar con 5.5 como si fueran la misma ruta |
| Visión al reutilizar observación | **0** solo cuando está probado que NO hubo nueva llamada | No significa que todo el turno sea gratuito |

Los costos reconstruidos con usage no son por sí mismos factura conciliada. No convertir percentiles de una cohorte pequeña de desarrollo en máximos contractuales.

### Fotos: selección de modelo y estimación histórica

La regla actual de FieldPhotoDensityGate usa el binario recibido: **>= 1.500.000 bytes → Opus; menor → Sonnet**. Es una heurística de tamaño, no un clasificador validado de dificultad visual. El gate no es otra llamada LLM. Fotos: Anthropic Direct; manuales grandes: Batch. No trasladar el unitario por página Batch a cada foto.

El modelo de junio estimaba 200 fotos en **3,40 esperado / 4,62 conservador**, mezcla 80% Sonnet y 20% Opus. Eso equivale a 0,017 / 0,0231 por foto, pero es una **hipótesis histórica**, no un precio medido para la mezcla de modelos 5.5. Puede mostrarse en sensibilidad con esa etiqueta; no prometer un máximo a partir de ella.

Faltan muestra Opus actual y mezcla representativa de fotos. Relectura paga visión otra vez; reutilización de observación aceptada no la vuelve a pagar. El objetivo es una foto por turno en los ejercicios comerciales; debe declararse si se permiten más.

## 4. Ingesta: corpus de Gonzalo + Jesús y proyección por página

El total de una ingesta piloto no equivale al costo mensual de un cliente. La ingesta inicial se paga una vez por carga; nuevas cargas mensuales son una decisión comercial aparte. Las reparaciones de fidelidad son responsabilidad de Danebo y no se facturan al cliente como recargo correctivo; sirven como evidencia de consumo, diferenciando ruta y denominador.

Muestra combinada de las 11 tandas completas del CSV: **10.355 páginas facturadas**, 10.826 de origen clasificadas, costo total **269,381123**; promedio observado **0,026015/facturada** o **0,024883/origen**. Cache incluida; filtro pagado también para páginas descartadas. El desglose técnico del CSV identifica Sonnet 4.6 Batch y Opus 4.8 Batch; no renombrar la cohorte a los modelos actuales.

| Componente histórico | Denominador | USD |
|---|---:|---:|
| Sonnet Batch | 8.823 páginas; total 166,066495 | **0,018821999/página** |
| Opus Batch | 1.532 páginas; total 76,470372 | **0,049915386/página** |
| Filtro Haiku | 10.826 páginas originales; total 23,859338 | **0,002203892/origen** |
| Reintentos, incidencia del corpus combinado | 10.355 páginas procesadas; total 2,984918 | **0,000288259/página** |

Inconsistencia de origen: la fila de retry del CSV dice denominador 9.765 pero average 0,000288. Ese average corresponde al corpus combinado de 10.355, no a 9.765. Aquí se recalcula explícitamente con el combinado; no se oculta la discrepancia.

Para presupuestar **todas las páginas originales**, sin depender del descarte de portadas/índices, y con mezcla de planificación 80% Sonnet / 20% Opus:

```text
pagina_proyectada =
  0,8 × 0,018821999 + 0,2 × 0,049915386
  + 0,002203892 filtro + 0,000288259 incidencia de retry
  = 0,027532827 USD/página
```

Esto conserva el mix y los unitarios históricos; no es un peor caso absoluto ni el precio actual demostrado de Batch 5.5. No incluye embeddings Titan de indexación ni impuestos, trabajo humano o utilidad. El 20% Opus es un supuesto, no un máximo del algoritmo.

La ruta de código apunta ya a Sonnet 5.5 y Opus 5.5. La muestra Batch Sonnet 5.5 de cinco páginas no es representativa del corpus: no proyectar toda una cartera con ella. Mantener separados: media observada de agosto, presupuesto sin descartes y muestra actual 5.5.

Las cifras históricas anteriores de Gonzalo (9.650 páginas y 255,21) y Jesús (613 páginas de origen) quedan conservadas en el anexo y documentos originales. No se suman encima de la auditoría combinada. La discrepancia de corpus requiere inventario por tanda/documento; para Jesús, el filtro más reciente registra 612 páginas de origen y 590 facturadas, total 14,1139.

## 5. Infraestructura: base separada de actividad

`infra_24x7.csv` proyecta un mes de **720 horas**, no una factura ya pagada ni una prueba de capacidad para 50 clientes.

| Partida pretax | USD/mes | Tratamiento |
|---|---:|---|
| EC2 t3.medium, 720 h | 29,9520 | Base compartida |
| RDS aplicación db.t4g.micro, 720 h | 11,5200 | Base compartida |
| IPv4 pública | 3,6000 | Base compartida |
| Discos EBS + RDS | 4,7000 | Base al tamaño actual |
| Aurora storage + backup, S3 observados | 0,1063 | Compartido; crece con datos |
| Secrets Manager + zona Route 53 | 2,5000 | Base compartida |
| **Subtotal base a configuración/volumen actuales** | **52,3783** | No multiplicar por cliente |
| Aurora Serverless: 29,052 ACU-h de septiembre | 3,4862 | Actividad observada; NO fija al crecer |
| Aurora I/O | 0,2398 | Actividad observada |
| Transferencia regional | 0,1073 | Actividad observada |
| Peticiones S3 + Secrets API + consultas DNS | 0,0610 | Actividad observada, pequeñas fracciones de cuenta mezcladas según CSV |
| **Subtotal actividad histórica** | **3,8943** | No es una función validada de clientes/turnos |
| **Proyección base + actividad septiembre** | **56,2726** | Antes de modelos e impuestos |

Septiembre medido sin modelos fue **36,722734**: EC2/RDS estuvieron unas 365 h, no 720. No sumar este histórico a la proyección. La cuenta contiene recursos ajenos a Danebo que el CSV separa.

La base anterior no contiene Haiku, fotos, parseo ni embeddings. La renovación del dominio no equivale a la zona DNS. Dominio, equipamiento, herramientas, contabilidad y otros gastos no documentados siguen pendientes.

Aurora vectorial es compartida: ACU-h e I/O responden a consultas, warmups, ingesta y reintentos. Asignar una parte a cada cliente puede servir para rentabilidad, pero la suma atribuida y el residuo deben coincidir con el total compartido. No sumar todo el clúster y volver a sumar cuotas por cliente.

## 6. Impuestos, reserva y horas de ambos

- Septiembre: Tax 10,6100 sobre pretax 55,8085 de toda la cuenta. Razón aproximada observada **0,190114**. Aplicarla a otro mes o a un subtotal proyectado es un supuesto presupuestario, no impuesto observado de esa proyección.
- Con esa razón, 52,3783 de base serían aproximadamente **62,34**; 3,8943 de actividad serían **4,63**; total aproximadamente **66,97**. No se aplica otra vez a unitarios ya expresados con impuestos.
- El impuesto de Anthropic debe confirmarse con su factura. No atribuirle automáticamente el observado en AWS sin marcar proxy.
- La reserva del 25% discutida en planificación es una decisión editable. No es consumo observado, utilidad ni intervalo estadístico.
- El soporte humano ofrecido es en horario laboral. La aplicación 24/7 no significa soporte humano 24/7.
- Horas y remuneraciones de Lahiri y Gonzalo, incorporación y equipamiento: **pendientes, no cero**. El desarrollo previo del MVP puede registrarse como aporte/inversión separado de trabajo futuro.

## 7. Conciliación de factura: diferencia pendiente

Periodo de comparación de los exports AWS: **1 septiembre–26 octubre 2026**. No limita el corpus de ingesta a septiembre; la evidencia de agosto se utiliza para página de manual.

| Importe Haiku reportado en la auditoría | USD |
|---|---:|
| Cost Explorer | 29,051010 |
| Reconstrucción desde la base | 11,892272 |
| **Resta aritmética de esos dos totales** | **17,158738** |
| Diferencia que escribe el informe de Grok | 17,292166 |
| **Inconsistencia entre diferencia declarada y resta** | **0,133428** |

**No se da por conciliado.** Solicitar los CSV de diferencias y comprobar si el agregado incorpora otros modelos/componentes o distintos cortes. No explicar 0,133428 como redondeo ni asignarlo a clientes sin evidencia. Octubre reportado por separado: 9,967513 frente a 1,596769, diferencia aritmética 8,370744.

El informe cita Haiku facturado y reconstruido cero el 5 y 20 de octubre. Cero filas no demuestra costo cero. En el export auditado `bedrock_daily_costs` tiene cero filas; la existencia del reconciliador y de evidencia exitosa en junio NO demuestra cobertura de esta ventana.

Jerarquía: factura/Cost Explorer para desembolso y logs proveedor para corroborar invocaciones; usage para atribución por llamada; estimaciones etiquetadas cuando no hay usage. No sumar factura total y filas reconstruidas como gastos distintos. El residuo es diferencia de conciliación, no otro unitario.

## 8. Fórmulas para trial y suscripción

Costo de turno atribuible al cliente:

```text
C_turno = intérprete realmente ejecutado
        + generación(es) realmente ejecutada(s)
        + visión nueva o relectura, si existe
        + embeddings de consultas Retrieve y cargos API que se confirmen
        + reranking, solo si se ejecuta
        + consumo vectorial atribuible
        + reintentos facturables, sin duplicar usage ya contado
```

El embedding interno puede faltar en Rails sin ser gratuito. No inventar una tarifa adicional por API Retrieve: confirmar si aplica al tipo de KB y al periodo facturado. En las capturas no hay Cohere ni Nova; no agregarlos preventivamente.

```text
C_operacion_mensual =
  base compartida
  + actividad compartida total (incluye la parte atribuida a clientes)
  + modelos de turnos e ingesta
  + otros gastos y horas humanas
  + impuestos que correspondan
```

Si se analiza el costo directo de suscripción, se suma allí la cuota vectorial atribuible y se resta esa misma cuota de actividad compartida residual. El total no cambia. Los warmups se cuentan una vez como operación compartida incluso si una foto con pregunta los dispara.

### Hipótesis comerciales en conversación, no oferta cerrada

- Trial acordado antes del ajuste de presupuesto: 7 días, un PDF hasta 300 páginas, 10 casos, hasta 10 turnos/caso, hasta 4 fotos/caso: presupuesto de consumo completo 100 turnos y 40 fotos.
- Objetivo posterior: menos de 10 USD tecnológicos por trial. La alternativa de 150 páginas manteniendo 100 turnos/40 fotos arrojó 9,54 USD con impuesto proxy y reserva, usando unitarios históricos y sin cerrar búsqueda/vectorial. **Es propuesta no aceptada y no es máximo garantizado.**
- Suscripción en discusión: **500 turnos mensuales totales por empresa**; 100 turnos con foto nueva incluidos es propuesta de mezcla del 20%, no acuerdo cerrado. Las 800 páginas de manuales mencionadas requieren definir si son carga inicial o cupo mensual. No imponer ingestión recurrente sin acuerdo.
- A 3–5 turnos/caso, 500 turnos admiten aproximadamente 100–166 casos al mes, 23–38 por semana (4,33 semanas) y 4,5–7,6 por día laboral (22 días). Es capacidad de empresa, no por técnico, y depende de qué sea un caso.
- La mensualidad de 50.000 CLP fue ejemplo de Gonzalo, no precio aprobado. Cambio de 1.000 CLP/USD y UF de 40.000 CLP son supuestos de planificación, no cotizaciones actuales.
- Setup histórico 5 UF con 2.000 páginas y trial histórico 500 páginas son propuestas anteriores, no se superponen automáticamente a los cupos nuevos. Comisión, descuentos y remuneraciones deben acordarse.

El presupuesto que asegura consumir todos los cupos no es peor caso absoluto de tokens. Los percentiles tampoco lo son. Para presentar utilidad, descontar costos completos y horas; hasta entonces llamar al remanente saldo disponible, no utilidad final.

## 9. Datos pendientes con prioridad

1. Conciliar 29,051010 / 11,892272 / 17,292166 contra los CSV originales y deduplicar exports repetidos de las mismas cuentas/eventos.
2. Leer GetKnowledgeBase de Y7RZWMFJSR y usage types de Titan/rerank del periodo. Separar embeddings de búsqueda, ingesta y warmups; no usar tres filas Titan de ingesta como prueba de todas las búsquedas.
3. Recuperar logs de invocación de los días 5 y 20 de octubre y comprobar cobertura real de bedrock_daily_costs; atribuir el residuo solo con evidencia.
4. Completar las correlaciones con las filas bedrock_queries (modelo, ruta, caché, usage) y confirmar PHOTO_QUESTION_RAG_ENABLED en el contenedor.
5. Obtener evidencia ya existente de foto nueva con texto después del 5 de octubre y de relectura; actualizar costo Sonnet/Opus de fotos sin trasladar precios Batch.
6. Medir/proyectar ACU-h, I/O y almacenamiento según actividad y concurrencia. La máquina actual no tiene capacidad demostrada para 50 clientes.
7. Acordar cupos de carga, política de casos, mensualidad y horas de ambos. Luego cerrar los escenarios 1/10/30/50 y punto de equilibrio.

## 10. Referencias de implementación y evidencia

- [Intérprete](../app/services/rag/turn_interpreter.rb), [sesión](../app/models/conversation_session.rb), [Bedrock client](../app/services/bedrock_client.rb).
- [Búsqueda y generación](../app/services/bedrock_rag_service.rb), [plan](../app/services/rag/companion_plan.rb), [perfil de recuperación](../app/services/rag_retrieval_profile.rb).
- [Warmup](../app/jobs/warm_bedrock_kb_job.rb), [modelos/precios en código](../app/models/bedrock_query.rb), [atribución de embedding](../app/services/bedrock_embedding_model.rb).
- [Visión](../app/services/field_photo_analysis_service.rb), [gate fotográfico](../app/services/field_photo_density_gate.rb), [job de foto](../app/jobs/field_photo_analysis_job.rb).
- [Configuración de ejemplo](../config/deploy.yml.example), [plan del intérprete](PLAN_TURN_INTERPRETER_2026-10-01.md), [discovery y benchmark visual](PLAN_FIELD_COMPANION_DISCOVERY_2026-09-29.md).
- [Ingesta Gonzalo original](INGESTA_PILOTO_GONZALO_2026-08-20.md), [ingesta Jesús original](INGESTA_PILOTO_JESUS_2026-08-31.md), [métricas](METRICS.md).

Otros documentos conservan afirmaciones históricas sobre RetrieveAndGenerate y precios de junio. Para costos actuales prevalecen estas secciones y la evidencia fechada. No reabrir planes de producto cerrados como consecuencia de esta consolidación.

## Anexo histórico — versión previa conservada, no vigente para presupuestar

El texto siguiente se conserva como evidencia de los cálculos de junio/agosto. Sus expresiones “current”, “canonical”, “exact”, sus precios mínimos y techos técnicos pertenecen a esa revisión; NO reemplazan las salvedades y pendientes actuales de este documento.

<details>
<summary>Consultar documento anterior a la consolidación del 28 de octubre</summary>

# SaaS Cost Model — Reconciled 2026-06-18 · measurement upgraded 2026-06-19

**Status:** current canonical source for Danebo variable AI COGS and pricing floors.

This document supersedes prior package totals, benchmark extrapolations and
unreconciled harness estimates. Historical run documents remain useful for
quality/audit evidence, but their cost figures are not current pricing inputs.

> **2026-06-23 — max_top_k raised 15→20 (schematic tier).** `RagRetrievalProfile::MAX_RESULTS`
> and `ContractualLimits::QUERY[:max_top_k]` raised from 15 to 20. This tier fires only on
> no-pin schematic block/connector queries (designador `-Pxxx` + keyword conector/borne/bloque/
> esquema). Rationale: Climb Gate B revealed that intra-doc recall failed on connector-block
> queries where the relevant chunk landed outside the former 15-result window. The fix closed
> the Q6/Q8 ambiguity class. Contractual max unchanged (bounded by Haiku 200k context window,
> not chunk count). Conservative query reserve updated — see canonical table below.

> **2026-06-19 — cost measurement is now bill-exact.** Authority levels 1–2 below
> are no longer aspirational: Bedrock Model Invocation Logging is enabled and
> `BedrockInvocationLogReconciler` reads the exact billed tokens
> (`inputTokenCount`/`outputTokenCount`/cache) per UTC day straight from S3.
> `ReconcileBedrockCostJob` persists them daily into `bedrock_daily_costs` (and
> on demand via `bedrock:reconcile_persist[date]`). This **replaces the
> ~3.8%-undercounting `BedrockQuery` estimator as the authority for spend**. See
> *Cost measurement upgrade* below for evidence and scope.

## Authority order

Use cost evidence in this order:

1. Provider invoice or provider cost export.
2. Bedrock model-invocation logs / CloudWatch billing telemetry. **Operational:**
   `bin/rails 'bedrock:reconcile_logs[YYYY-MM-DD]'` (read-only report) or the
   persisted `bedrock_daily_costs` rows (`ReconcileBedrockCostJob`, daily 04:00).
3. Provider `usage` token payload persisted with `token_source: provider_usage`.
4. Application token estimates, explicitly labeled provisional (`token_source:
   estimated` — the live `#chat-usage-metrics-container` footer reads these for a
   provisional "today" figure; the exact value lands next day via level 2).

All figures below are USD variable model costs. They exclude fixed Aurora/S3/
compute costs, support, taxes and commercial margin.

## Cost measurement upgrade (2026-06-19)

**What changed.** Bedrock `retrieve_and_generate` returns no `usage` block, so
`BedrockQuery` query rows reconstructed input from cited chunks and undercounted
(~3.8% average; larger on hybrid). Spend authority has moved from that estimator
to the **AWS Model Invocation Logs in S3** — the same token counts AWS bills.

**Mechanism (in-repo).**

- `BedrockInvocationLogReconciler#day(date)` — parses `*.json.gz` invocation logs,
  aggregates exact `inputTokenCount`/`outputTokenCount`/`cacheRead`/`cacheWrite`
  per model for one UTC day, prices via `BedrockQuery::BEDROCK_PRICING`.
- `ReconcileBedrockCostJob` — persists that into `bedrock_daily_costs`
  (idempotent, one row per `[utc_date, model_id]`); scheduled daily 04:00 for the
  prior UTC day; manual via `bedrock:reconcile_persist[YYYY-MM-DD]`.
- `BedrockDailyCost.truth_vs_estimate(date)` — exposes the log-vs-estimate drift.

**Evidence (validated against the logs that feed the AWS bill).** Invocation
logging was enabled **2026-06-18**, so the reconciled window starts there:

| UTC day | Haiku (R&G) inv | input tok | output tok | Titan embeds | **Exact cost** |
|---|---:|---:|---:|---:|---:|
| 2026-06-18 (complete) | 52 | 224,097 | 22,213 | 106 | **$0.33518** |
| 2026-06-19 (in progress) | 14 | 72,570 | 6,732 | 50 | $0.10626 (partial) |

The logs capture **every** Bedrock model invocation that day (RAG generation +
no-results retries + page-filter + alias-extraction + embeddings), i.e. total
billable Bedrock spend — not just user-facing queries.

**Scope / honesty.** The *method* is now exact and bill-accurate at the
daily/aggregate level. It does **not** yet replace the per-1,000-query package
projection below: only ~1.5 days of low-volume dev/test traffic exist since trace
activation. The package figures stay as the **conservative projection**; they are
now anchored to an exact measurement pipeline and will converge to measured truth
as `bedrock_daily_costs` accumulates production volume. Keep the conservative
reserve until a representative production cohort is reconciled.

## Canonical package economics

| Cost line | Expected | Conservative | Evidence |
|---|---:|---:|---|
| 1,000 RAG queries / month | $6.14 | $9.25 | Run4 cohort + schematic-tier sensitivity (see note below) |
| 200 field photos / month | ~$3.40 | ~$4.62 | Estimate, 80% Sonnet / 20% Opus; not invoice-validated |
| **Recurring monthly COGS** | **~$9.54** | **~$13.87** | Queries + photos only |
| 200-page manual onboarding | **$5.32 one-time** | **$5.32 measured** | Reconciled Anthropic invoice, 168 kept pages |
| **First month including onboarding** | **~$14.86 (~$15)** | **~$19.19** | Recurring COGS + one-time onboarding |

**Query conservative reserve note (updated 2026-06-23):** The prior $8.65 figure was the
run4 all-generative benchmark cohort, which did not include schematic block/connector queries
at top_k=20. With the new schematic tier (~15% of queries est., +5 chunks × ~800 tokens/chunk
= +4,000 input tokens/query, Haiku global $0.001/1k): +$0.60/1,000 queries worst-case.
Rounded reserve $9.25. Carry this until a production cohort with schematic traffic is
reconciled in `bedrock_daily_costs`. The contractual_max ($424.00) is unchanged — it is
bounded by the Haiku 200k context window, not chunk count.

The manual is not a monthly recurring cost. It is charged once during
onboarding, or amortized explicitly as a commercial choice.

### Photo-routing sensitivity

The canonical photo estimate uses 80% Sonnet / 20% Opus. If production settles
at 90% Sonnet / 10% Opus with the same token profile, the linear sensitivity is:

- 200 photos: approximately $3.20.
- Recurring expected COGS: approximately $9.34.
- First month including onboarding: approximately $14.66.

This is sensitivity analysis, not reconciled billing truth. Keep the $13.87
monthly reserve until at least 50 diverse production photos are invoice-checked.

## Manual onboarding reconciliation

Retained batch: `msgbatch_017UYaG9fXBGkovuE6ENmaRv`.

| Component | Billed cost |
|---|---:|
| Sonnet 4.6 Batch: input | $0.50 |
| Sonnet 4.6 Batch: cache write | $1.50 |
| Sonnet 4.6 Batch: output | $2.51 |
| Haiku page filter + 2 bounded Sonnet-direct retries | $0.81 |
| **Full onboarding** | **$5.32** |

Run facts: 200 source pages, 168 kept/succeeded, 0 failed, 0 degraded, 0 Opus
pages and 2 bounded retries. The harness calculated $5.4434, 2.3% above the
invoice; retain that value only as a conservative diagnostic, not as billed cost.

## Medido en piloto ago-2026

**Fuente:** nueve tandas bulk en cuenta piloto (Account 3, `piloto.danebo.ai`),
auditoría con `script/bulk_upload_cost_audit.rb`. Registro operativo primario:
[`INGESTA_PILOTO_GONZALO_2026-08-20.md`](INGESTA_PILOTO_GONZALO_2026-08-20.md)
— **no se alteran sus cifras históricas aquí**.

| Concepto | Valor |
|---|---:|
| Tandas cerradas | 9 (`00` validación + `02`–`07` ingesta) |
| Páginas facturadas | **9.650** |
| Gasto all-in (batch + rutas directas + caché) | **US$255,21** |
| **Media all-in corpus completo** | **US$0,0265/pág** |
| Media all-in corpus con capa de texto (excl. `04b` y `07`, ambos >70% Opus) | **US$0,0245/pág** |
| Media validada a mitad de ingesta (tandas `00`–`04a`, 5.715 pág) | **US$0,0244/pág** |

**Desglose de rutas (bulk cost-v2).** Sonnet/Opus van por Anthropic Batch API
(`claude-sonnet-4-6-batch` / `claude-opus-4-6-batch`). El coste all-in suma dos
rutas directas además del batch:

| Ruta | Qué es | Modelo |
|---|---|---|
| `batch` | parseo por página de páginas conservadas | Sonnet/Opus batch (~50% off) |
| `page_filter` | `PageRelevanceFilter` por ventana de hasta 20 págs — **se paga aunque la página se descarte** | Haiku directo |
| `bulk_retry` | `BatchPageRetryService` sobre páginas truncadas en batch | Sonnet/Opus **directo** (~2× batch) |

**Peaje Haiku (`page_filter` + `bulk_retry` sobre batch):** **8–14%** por tanda
medido (`02` 13%, `03` 14%, `06` 9,2%, `04b` 12,9%, `01` 10,8%; mínimo `07` 7,6%,
validación `00` 5%). El driver de coste por página sigue siendo la **fracción
Opus** (escaneados densos vía `force_opus`), no el volumen bruto del corpus:
1,1% Opus en `02` → US$0,0277/pág; 73,8% en `04b` → US$0,0470/pág; 100% en `07`
→ US$0,0514/pág.

**Rango por tanda (all-in, US$/pág facturada):**

| Tanda | Págs | Opus | US$/pág |
|---|---:|---:|---:|
| `05_ingesta.zip` | 1.711 | bajo | **0,0184** |
| `04a_ingesta.zip` | 512 | 0% | **0,0212** |
| `02_ingesta.zip` | 985 | 1,1% | **0,0277** |
| `01_ingesta.zip` | 3.447 | mixto | **0,0246** |
| `06_ingesta.zip` | 2.064 | mixto | **0,0255** |
| `00_validacion.zip` | 27 | 37% | **0,0424** |
| `03_ingesta.zip` | 416 | 38,5% | **0,0390** |
| `04b_ingesta.zip` | 187 | 73,8% | **0,0470** |
| `07_ingesta.zip` | 301 | 100% | **0,0514** |

**Implicación para el presupuesto de onboarding.** El manual reconciliado de Gate
9R (US$5,32 / 168 págs kept = **US$0,0317/pág**) sigue siendo la referencia para
un onboarding único con retry acotado. Para bulk a escala sobre corpus con capa de
texto, usar **US$0,0244–0,027/pág all-in** como piso esperado y reservar hasta
**US$0,05/pág** cuando el ZIP concentre escaneados sin capa de texto. El buffer
de `script/gonzalo_corpus_prep.rb` (`PRICE_PER_PAGE = 0.027`, ×1,3) sigue siendo
conservador para planificación; la media medida del piloto completo (US$0,0265/pág)
cae por debajo.

## Production tracking accuracy

- **Authoritative spend is now log-exact.** `bedrock_daily_costs` /
  `bedrock:reconcile_logs` carry the exact billed tokens per UTC day from the AWS
  invocation logs. This is the number to trust for COGS.
- The `BedrockQuery` `token_source: estimated` rows remain **operational only**
  (live footer, latency/route telemetry, retrieval-regression analysis). Their
  historical ~3.8% average undercount — larger on hybrid compare-with-schematic
  queries, where the estimator sees cited chunks, not every retrieved chunk sent
  to generation — no longer affects any reported cost, because spend authority
  moved to the logs.
- Direct parse and normal batch-job parse use `provider_usage` and reconcile to
  the invoice; they are exact independently of the log pipeline.
- The standalone retained manual run did not emit normal `BedrockQuery` rows;
  its provider invoice is therefore the authoritative source.
- Photo cost remains the only package line not validated against a sufficiently
  diverse invoice-backed production cohort. Note: field photos bill via the
  **Anthropic Direct API** (`-direct` rows, `provider_usage` exact) — they do
  **not** appear in the Bedrock invocation logs and must be validated against the
  Anthropic invoice, not `bedrock_daily_costs`.

The larger historical query-estimator gap was a V1 cohort result and is no
longer the current average accuracy statement; it is also now moot for pricing.

## Pricing floor

Use conservative recurring COGS ($13.87), not first-month onboarding cost, to
set the monthly subscription floor.

| Target gross margin | Minimum monthly price |
|---|---:|
| 50% | $27.74 |
| 60% | $34.68 |
| 70% | $46.23 |

Bill onboarding separately with its own margin, or disclose any amortization.

## Technical contractual ceilings

`Gate9CostMatrix#contractual_max` derives finite worst cases from current
technical limits. These are risk bounds, not forecasts, package COGS or customer
prices.

| Unit | Technical ceiling |
|---|---:|
| 1,000 queries | $424.00 |
| 200 photos | $3,224.00 |
| 200-page manual | $2,712.18 |
| Combined | $6,360.18 |

The photo ceiling is intentionally pathological (every photo on the most
expensive route with the full bounded ladder). It shows that commercial quotas
and per-photo limits must remain explicit; it must never be presented as likely
spend.

## Retired calculation methods

Do not use prior monthly totals that included onboarding, 24-page manual
extrapolations, harness output as invoice truth, historical benchmark averages
as current query COGS, or fixed per-photo/per-page token assumptions. Only the
conservative all-generative query reserve remains intentionally carried forward.

## Source references

- Current checkpoint and reconciliation: [GATE9R_STATUS.md](GATE9R_STATUS.md)
- Manual execution evidence: [GATE9_FINAL_MANUAL_AUDIT_2026-06-17.md](GATE9_FINAL_MANUAL_AUDIT_2026-06-17.md)
- Active ingestion architecture: [INGESTION_COST_V2.md](INGESTION_COST_V2.md)
- Usage tracking semantics: [METRICS.md](METRICS.md)
- Exact spend reconciliation: `app/services/bedrock_invocation_log_reconciler.rb`,
  `app/jobs/reconcile_bedrock_cost_job.rb`, `BedrockDailyCost`,
  `lib/tasks/bedrock_reconcile.rake` (`bedrock:reconcile_logs`,
  `bedrock:reconcile_persist`)
- Reproducible historical/contractual matrix: `Gate9CostMatrix`

</details>
