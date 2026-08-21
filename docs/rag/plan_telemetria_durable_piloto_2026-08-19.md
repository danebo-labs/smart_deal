# Plan telemetría durable del piloto — Que un log rotado no vuelva a borrar un día del piloto (2026-08-19)

**Objetivo:** que ninguna interacción del piloto sea irrecuperable por rotación del log
de Docker: (A) el pipeline de export debe poder reconstruir pregunta y respuesta
completas desde los S3 Model Invocation Logs que ya existen y ya se pagan, y (B) la
telemetría que hoy solo vive en stdout (`[PILOT_USAGE]`, `[RAG_QUALITY]`) debe tener
una copia durable en RDS sin bloquear el request del usuario.

**Estado: PENDIENTE DE APROBACIÓN HUMANA. Ninguna fase se ejecuta sin luz verde
explícita.**

**Entrada obligatoria:** este documento,
`docs/rag/plan_tracking_piloto_2026-08-04.md` (contrato de tracking y hallazgo H11),
`app/services/bedrock_invocation_log_reconciler.rb`,
`app/services/pilot_usage_log.rb`, `app/services/pilot_audit_log.rb`,
`app/services/bedrock_rag_service.rb` (`log_quality_signal`, `track_rag_usage`),
`app/jobs/track_bedrock_query_job.rb`, `app/services/pilot_metrics_report.rb`,
`bin/pilot_metrics`, `docs/METRICS.md` (§ export diario, § PILOT_AUDIT_CAPTURE) y
el artefacto de recuperación
`tmp/pilot_exports/2026-08-10_2026-08-12_danebo-legacy/recovered_2026-08-19.json`.

**Línea base (incidente 2026-08-10/13):** el export del 13 de agosto para el rango
2026-08-10 → 2026-08-12 produjo `source_events.jsonl` vacío: los eventos
`[PILOT_USAGE]`/`[RAG_QUALITY]` del 10 de agosto (9 interacciones reales de
user_id 6, sesión 5) habían rotado con el log de Docker antes del export. El
hallazgo H11 del plan de tracking ya advertía este riesgo el 4 de agosto y la
mitigación elegida fue disciplina operativa (export diario), no persistencia
durable. Esa decisión falló en producción. La recuperación del 2026-08-19
demostró que los S3 invocation logs contienen el 100% del contenido perdido
(9/9 interacciones reconstruidas con prompt y respuesta completos, verificación
por contenido en verde), pero mediante emparejamiento heurístico manual, no por
pipeline.

## Restricciones no negociables

1. Minitest. Todo cambio de comportamiento cubierto por tests deterministas,
   sin fixtures excesivas. Los `.json.gz` de prueba se generan en memoria
   (StringIO + Zlib), no se versionan binarios.
2. Ningún cambio a `config/deploy.yml`, infraestructura o producción sin
   aprobación explícita separada de este plan (incluye migraciones en prod:
   entran con el deploy aprobado, no antes).
3. Ningún payload nuevo persiste prompt, respuesta cruda, backtrace ni
   credenciales fuera del gate ya existente de `PILOT_AUDIT_CAPTURE`. La copia
   durable de `[RAG_QUALITY]` en RDS EXCLUYE `question`, `answer_snippet` y
   `citation_titles` (texto crudo); conserva hashes, conteos, flags de evidencia
   y latencias. El texto completo se recupera por el frente A (S3), no por la
   tabla.
4. Cero llamadas Bedrock nuevas en los caminos calientes. El frente A solo lee
   S3 en tiempo de export (laptop); el frente B agrega como máximo un
   `perform_later` + un INSERT async por evento, sin callbacks, sin broadcast,
   sin retención de referencias a modelos completos.
5. El emparejamiento S3↔interacción se rotula siempre como
   `timestamp_matching + content_verification`, nunca como unión por id exacto:
   los registros de invocación no llevan `correlation_id`. Todo registro sin
   verificación de contenido en verde se reporta como `unverified`, jamás se
   presenta como match confirmado.
6. Los artefactos de export existentes no cambian de semántica ni de nombre. Lo
   recuperado desde S3 entra como artefacto/clave adicional explícitamente
   rotulado (patrón `recovered_*`), igual que en la recuperación manual del
   2026-08-19.
7. Todo artefacto de corrida real se copia a `tmp/` local con SHA256 verificado
   antes de cerrar la sesión que lo generó (restricción heredada del plan de
   tracking).
8. Presupuesto Bedrock del ciclo: **≤ 4 invocaciones**, todas en la fase de
   gate (preguntas reales para validar la escritura durable de B). Fases de
   implementación: 0 invocaciones.

## Hallazgos de arranque (sesión de recuperación 2026-08-19)

| # | Hallazgo | Evidencia |
|---|---|---|
| H1 | **El log de Docker rotó y se llevó el único ejemplar de la telemetría del 10 de agosto.** `config/deploy.yml` no declara `logging:`, así que aplica la rotación default del driver json-file. `source_events.jsonl` del export 2026-08-10→12 quedó en 0 bytes. | `tmp/pilot_exports/2026-08-10_2026-08-12_danebo-legacy/source_events.jsonl` (0 bytes, SHA de archivo vacío en `SHA256SUMS`) |
| H2 | **Los S3 invocation logs contienen el 100% del contenido perdido, sin truncar.** `input.inputBodyJson` (prompt completo con chunks) y `output.outputBodyJson` (respuesta completa). Recuperadas 9/9 interacciones de user 6. | `recovered_2026-08-19.json`; horas 16-17 UTC de `s3://multimodal-logs/bedrock-invocation-logs/.../2026/08/10/` |
| H3 | **El emparejamiento es heurístico y existen registros degenerados.** Los registros no llevan `correlation_id`; se emparejó por `created_at - latency_ms` (±90s) más verificación de que `bedrock_queries.user_query` aparece en los mensajes del input. 9/9 en verde, pero apareció un registro `Converse` sin input ni output (17:25:27Z) coherente con un intento fallido. | `recovered_2026-08-19.json` → `correlation_method` |
| H4 | **`[PILOT_USAGE]` y `[RAG_QUALITY]` no tienen copia durable en ningún lado.** `PilotUsageLog.log` y `log_quality_signal` escriben solo a `Rails.logger` → stdout → Docker. `interaction_completed` (evento terminal del contrato) incluido. | `app/services/pilot_usage_log.rb:35`; `app/services/bedrock_rag_service.rb:653-708` |
| H5 | **La decisión "cero tablas nuevas" del plan de tracking ya falló en producción.** "Qué NO está en este plan" descartó la tabla de BD "a cambio de nada que el log no dé"; el log no dio nada el 13 de agosto. Corresponde revisar la decisión, no repetirla. | `docs/rag/plan_tracking_piloto_2026-08-04.md` § Qué NO está en este plan; H11 del mismo doc |
| H6 | **`bedrock_queries` ya guarda el `user_query` (≤500 chars) y los metadatos de matching.** La recuperación usó `created_at`/`latency_ms`/`user_query` de esa tabla como ancla; el pipeline A puede hacer exactamente lo mismo sin dato nuevo. | `app/jobs/track_bedrock_query_job.rb:58-76`; `db/schema.rb` (tabla `bedrock_queries`) |
| H7 | **El bucket `multimodal-logs` no tiene lifecycle policy: crece para siempre.** Hoy es lo que hizo posible la recuperación; a futuro es una decisión de costo/gobernanza sin dueño. | `aws s3api get-bucket-lifecycle-configuration` → `NoSuchLifecycleConfiguration` (verificado 2026-08-19) |

## Trade-off de performance/costo (evaluación explícita, reglas del proyecto)

- **Frente A (S3 → export):** costo cero en el camino caliente. No agrega
  queries, ni jobs, ni llamadas en producción; paga solo GETs de S3 en tiempo
  de export desde la laptop, sobre horas UTC acotadas por los `created_at` de
  las filas ya seleccionadas. Es la opción "sin nueva captura": la fuente ya
  existe, ya se paga por tener Model Invocation Logging activo, y ya dura para
  siempre (H7).
- **Frente B (tabla RDS async):** agrega exactamente 1 `perform_later` + 1
  INSERT por evento de piloto, en el worker, nunca en el request (mismo patrón
  de `TrackBedrockQueryJob`, sin su broadcast ni su upsert de `CostMetric`). A
  escala del piloto (decenas de eventos/día) el costo es despreciable frente al
  costo ya pagado de este incidente (un día del piloto irrecuperable por
  pipeline y una recuperación manual de una sesión completa de ingeniería).
  Alternativas descartadas: escribir síncrono en el request (viola latencia
  primero), un buffer batch con flush periódico (orquestación innecesaria a
  este volumen), y duplicar `[PILOT_AUDIT]` a la tabla (violaría la
  restricción 3: el texto crudo queda bajo su gate en logs, y A ya cubre la
  reconstrucción completa).
- **Por qué A y B y no solo uno:** A reconstruye contenido (prompt/respuesta)
  pero no los eventos de pipeline (`evidence_route`, cache de fotos, etapas,
  abstención) que nunca llegan a Bedrock; B persiste esos eventos pero no debe
  llevar texto crudo (restricción 3). Son complementarios y cada uno es la
  solución mínima de su frente.

## Asignación de modelo por fase

| Fase | Modelo | Racional |
|---|---|---|
| 0 Verificación de vigencia | Sonnet 5 | lectura de código, sin escrituras |
| A1 Recuperador S3 → export | Sonnet 5 | código nuevo con parser existente como base, tests sintéticos |
| B1 Tabla durable + emisión async | Sonnet 5 | migración + camino caliente del worker |
| B2 Reporte lee la tabla + docs | Sonnet 5 | integración en `pilot_metrics_report.rb` (972 líneas) |
| Gate corrida real | **Sonnet 5 — NO Haiku** | ejecuta contra producción |

Nunca Fable en ninguna fase (regla heredada del plan de tracking).

## Fase 0 — Verificación de vigencia (Sonnet 5; 0 invocaciones)

Lectura pura. Confirma que al día de ejecución siguen vigentes:

- **(a) H4:** `PilotUsageLog.log` sigue escribiendo solo a `Rails.logger` y no
  existe ninguna tabla de eventos de piloto en `db/schema.rb`.
- **(b) H6:** `TrackBedrockQueryJob` sigue persistiendo `user_query`,
  `created_at`, `latency_ms`, `correlation_id` en `bedrock_queries`.
- **(c) H2/H3:** el layout del bucket y la forma de los registros
  (`operation`, `modelId`, `timestamp`, `input.inputBodyJson`,
  `output.outputBodyJson`) no cambió — se verifica contra UN objeto reciente,
  sin descargar días completos.
- **(d)** `bin/pilot_metrics` sigue teniendo los dos scripts de implementación
  (`script/pilot_metrics_export.rb` remoto, `script/pilot_metrics_package.rb`
  local) y el flag `--with-questions` con su frontera de privacidad.

Salida: filas vigente sí/no en el Anexo B. Si algo cambió, se corrige la fase
afectada y su prompt del Anexo A antes de continuar.

## Fase A1 — Recuperador S3 conectado al export (Sonnet 5; 0 invocaciones)

**Hipótesis:** con las filas de `bedrock_queries` como ancla
(`correlation_id`, `created_at`, `latency_ms`, `user_query`), un servicio que
extienda el patrón de `BedrockInvocationLogReconciler` puede reconstruir
pregunta y respuesta completas por `correlation_id` para cualquier rango cuyo
log de Docker ya rotó, sin nueva captura y sin tocar producción.
**Qué la refutaría:** que exista una ruta facturable cuyo `user_query` en
`bedrock_queries` no aparezca en los mensajes del `inputBodyJson` (la
verificación de contenido daría `unverified` sistemáticamente — en ese caso el
match se degrada a solo-timestamp y se rotula como tal), o que el volumen de
registros por hora haga inviable el escaneo acotado (hoy: decenas de objetos
por hora, trivial).

Cambios acotados:

1. **`app/services/bedrock_invocation_log_recovery.rb` (PORO nuevo):** reutiliza
   la lectura de bucket/prefijo/horas de `BedrockInvocationLogReconciler`
   (extraer el iterador `each_record` a un módulo compartido o composición —
   no duplicar el parser). Entrada: filas ancla (pluck de `bedrock_queries`) y
   rango. Salida: por `correlation_id`, el registro emparejado con
   `input_body`, `output_body`, `delta_s`, `content_match` (bool) y los
   registros sin asignar. Método exacto validado el 2026-08-19: inicio estimado
   `created_at - latency_ms`, ventana ±90s, exigir `inputBodyJson` presente,
   preferir candidatos cuyo input contenga el `user_query`.
2. **`bin/pilot_metrics --recover-from-invocation-logs` (flag opt-in):** cuando
   se pasa, el empaquetador local agrega `recovered.json` al paquete (mismo
   esquema del artefacto manual del 2026-08-19: fuente, método, warning de
   no-exactitud, interacciones por `correlation_id`) y lo suma a `SHA256SUMS`.
   No modifica `report.json` ni ningún artefacto existente (restricción 6). Al
   igual que `--with-questions`, imprime advertencia de privacidad y restringe
   permisos del paquete: el contenido recuperado es texto real de técnicos.
3. **Sin cambio alguno en producción:** corre en la laptop con las credenciales
   AWS del operador, como el reconciliador de costo.

Tests de la fase (Minitest, deterministas): matcher con registros sintéticos
gzip en memoria — match feliz, registro degenerado sin body ignorado, dos
candidatos cercanos resueltos por contenido, ancla sin candidato dentro de la
ventana reportada como `unmatched`, `content_match: false` rotulado
`unverified`. Cero AWS real: cliente S3 inyectado (el reconciliador ya acepta
`s3:` en el constructor — mismo patrón).

## Fase B1 — Copia durable de la telemetría del piloto (Sonnet 5; 0 invocaciones)

**Hipótesis:** persistir cada evento de `PilotUsageLog` y la señal de
`[RAG_QUALITY]` (sin texto crudo) en una tabla `pilot_events` vía job async
elimina la dependencia de la rotación de Docker sin costo perceptible en el
request. **Qué la refutaría:** que el volumen de eventos saturara la cola
`default` o que el INSERT compitiera con el camino del usuario — a escala del
piloto (decenas/día) es refutación teórica; el gate lo mide igual.

Cambios acotados:

1. **Migración `pilot_events`:** `event` (string, not null), `correlation_id`
   (string), `account_id`/`user_id`/`conversation_session_id` (bigint, sin FK,
   igual que `bedrock_queries`), `occurred_at` (datetime, not null; el `ts` del
   evento, no el del INSERT — lección del reconciliador de costo), `payload`
   (jsonb, default `{}`). Índices: `[occurred_at]`, `[correlation_id]`,
   `[event, occurred_at]`. Multi-tenant ready: `account_id` presente desde el
   día uno.
2. **`PilotUsageLog.log` persiste además de loguear:** tras el
   `Rails.logger.info` actual (que no cambia — los lectores existentes de
   `[PILOT_USAGE]` siguen funcionando), encola `PersistPilotEventJob` con el
   payload YA whitelisteado/truncado por `ALLOWED_FIELDS`/`safe_value`. La
   whitelist existente es la garantía por construcción de la restricción 3
   para este emisor. El job hace `PilotEvent.insert!` (sin callbacks, sin
   validaciones de modelo, sin broadcast). Fallo del encolado nunca rompe el
   request: mismo `rescue` blando que ya tiene la clase.
3. **`[RAG_QUALITY]` durable sin texto crudo:** `log_quality_signal` emite
   además un evento `rag_quality` por la misma vía, con el payload EXCLUYENDO
   `question`, `answer_snippet` y `citation_titles` y agregando
   `question_sha256`/`answer_sha256` (claves que `ALLOWED_FIELDS` ya admite).
   La línea de log actual no cambia (compatibilidad con
   `script/export_rag_trace.rb`).
4. **`PILOT_EVENTS_PERSIST` (env, default `true`):** kill-switch operativo para
   apagar la persistencia sin deploy si algo se comporta mal. No es un gate de
   privacidad (eso sigue siendo la whitelist); es un freno de emergencia.

Tests de la fase: el evento encolado lleva exactamente el payload
whitelisteado; `rag_quality` persistido no contiene ninguna clave de texto
crudo (aserción negativa explícita); un fallo del INSERT no propaga al emisor;
idempotencia del job frente a retry (clave natural `event + correlation_id +
occurred_at` o tolerancia a duplicados documentada — decidir en implementación
y testearlo).

## Fase B2 — El reporte lee la tabla y los docs reflejan la decisión (Sonnet 5; 0 invocaciones)

**Hipótesis:** `PilotTelemetryReader`/`PilotMetricsReport` pueden usar
`pilot_events` como fuente cuando el log no está (o como fuente primaria), sin
cambiar ninguna clave del contrato del reporte. **Qué la refutaría:** que
alguna métrica dependa de un campo que solo existe en la línea de log y no en
el payload persistido; en ese caso se amplía el payload en B1, no se agrega una
segunda fuente ad-hoc.

1. **Lectura:** el reader acepta la fuente BD para el rango (`occurred_at` +
   cohorte) y la usa cuando `source_events` está vacío/parcial; `data_quality`
   declara la fuente usada (`usage_log: "db"` / `"log"` / `"db+log"`) — nunca
   se fabrican eventos.
2. **Docs:** actualizar `docs/METRICS.md` (§ export diario: el disclaimer "un
   deploy borra la historia" se reescribe con la nueva realidad; § nueva de
   `pilot_events`), `docs/PILOT_CAPTURE_TEMPLATE.md` (el anexo de métricas
   automáticas deja de asumir que `bin/pilot_metrics` depende del contenedor
   vivo) y `docs/rag/plan_tracking_piloto_2026-08-04.md` (tabla de Estado +
   protocolo de plan vivo: la entrada "Tabla de interacciones en base de datos"
   de "Qué NO está en este plan" se anota como REVISADA por este plan, con
   referencia al incidente y a este documento — no se borra el texto original,
   se le agrega la revisión fechada).

Tests: reporte con log vacío + tabla poblada reproduce la sección
`interactions` completa; con ambas fuentes no duplica eventos.

## Gate — Corrida real (Sonnet 5; ≤4 invocaciones; requiere aprobación de deploy separada)

Sesión NUEVA que no implementó A1/B1/B2. Checkpoint previo: el deploy vigente
incluye las fases (verificable por `manifest.json.image_version` contra el SHA
del commit). **El deploy en sí requiere la aprobación separada de la
restricción 2 — este plan no lo autoriza.**

**Criterio congelado antes de abrir:**

- 2-4 preguntas reales → cada una produce su fila en `pilot_events`
  (`interaction_completed` + `rag_quality`) visible por consola de solo
  lectura, con `occurred_at` coherente con el momento real.
- Ningún payload persistido contiene pregunta/respuesta en texto crudo
  (inspección directa de las filas del gate).
- `bin/pilot_metrics` del rango del gate, con los logs de Docker INTACTOS,
  produce el mismo `interactions` leyendo de BD que leyendo de log (fuente
  cruzada en verde).
- `bin/pilot_metrics --recover-from-invocation-logs` sobre el rango del
  incidente original (2026-08-10 → 2026-08-12) reproduce por pipeline lo que
  la recuperación manual del 2026-08-19 produjo a mano: mismas 9 interacciones,
  mismos matches (comparación contra `recovered_2026-08-19.json` por
  `correlation_id` + `request_id`).
- p95 de latencia del rango del gate sin regresión atribuible (el INSERT es
  async; cualquier regresión sería un hallazgo para escalar, no para parchear
  en la sesión del gate).
- Artefactos a `tmp/` con SHA256 (restricción 7).

## Decisiones pendientes (escaladas, NO se ejecutan con este plan)

| # | Decisión | Contexto | Dueño |
|---|---|---|---|
| D1 | **TTL / lifecycle policy para `s3://multimodal-logs`.** Hoy sin lifecycle (`NoSuchLifecycleConfiguration`): crece indefinido. Es exactamente lo que salvó este incidente, así que el TTL elegido debe ser ≥ la ventana de auditoría que el negocio quiera garantizar (propuesta a evaluar: transición a Glacier a 90 días, expiración ≥ 1 año; decidir con costo real del bucket en mano). Es una decisión de costo/gobernanza de datos, no un bug. | H7 | Dueño del producto / operación |
| D2 | **Declarar `logging:` (max-size/max-file) en `config/deploy.yml`.** Mitiga la ventana de rotación pero NO sustituye a A/B (un deploy sigue reemplazando el contenedor y su historia). Cambio de infraestructura: fuera de este plan por restricción 2. | H1; docs/METRICS.md § "kamal deploy silently drops" | Dueño del producto / operación |

## Presupuesto del ciclo

- Fases 0, A1, B1, B2: 0 invocaciones Bedrock.
- Gate: 2-4 preguntas reales, techo 4 invocaciones.
- Cero ingesta, cero re-embedding, cero sync de KB.
- Frente A: solo GETs S3 en export (centavos); frente B: 1 job + 1 INSERT por
  evento a volumen de piloto.

## Estado

| Fase | Estado | Artefacto / hash |
|---|---|---|
| 0 Verificación de vigencia | No iniciada (bloqueada por aprobación del plan) | — |
| A1 Recuperador S3 → export | No iniciada | — |
| B1 Tabla durable + emisión async | No iniciada | — |
| B2 Reporte + docs | No iniciada | — |
| Gate corrida real | No iniciada (requiere además aprobación de deploy) | — |

Antecedente ejecutado (fuera de este plan, sesión 2026-08-19): recuperación
manual del incidente —
`tmp/pilot_exports/2026-08-10_2026-08-12_danebo-legacy/recovered_2026-08-19.json`
(SHA256 `b65006b78cf1785954eed91e3f2c0db2f72dfde055e89ca15122c104977b466c`,
agregado por append a `SHA256SUMS` sin tocar los 7 hashes originales).

## Protocolo de plan vivo

1. Actualiza tu fila de Estado.
2. Corrige las fases posteriores afectadas por tus hallazgos.
3. Actualiza el prompt de la fase siguiente en el Anexo A (⚠️ CRÍTICO si cambia
   su implementación).
4. Si un hallazgo contradice una restricción o el criterio del gate: no se
   ejecuta, se escala como decisión humana numerada (tabla de Decisiones
   pendientes).

## Anexo A — Prompt de arranque por fase

**Pie común:** leé este documento completo antes de tocar nada. Regís por las
restricciones no negociables y el protocolo de plan vivo. Un objetivo por
sesión. No abras trabajo de otra fase. Al cerrar, actualizá tu fila de Estado y
el prompt de la fase siguiente.

### Fase 0 — Sonnet 5

> Verificá la vigencia de H2, H3, H4 y H6 de este documento contra el estado
> actual del código y contra UN objeto reciente del bucket (no descargues días
> completos). Lectura pura: no arreglés nada, no llames a Bedrock. Devolvé la
> tabla de vigencia en un Anexo B de este documento.

### Fase A1 — Sonnet 5

> Implementá el recuperador S3: PORO `BedrockInvocationLogRecovery` que reutiliza
> el iterador de lectura de `BedrockInvocationLogReconciler` (extraer a módulo
> compartido, no duplicar), matching por `created_at - latency_ms` ±90s con
> verificación de contenido contra `bedrock_queries.user_query`, y el flag
> `--recover-from-invocation-logs` en `bin/pilot_metrics` que agrega
> `recovered.json` al paquete con append a `SHA256SUMS`, advertencia de
> privacidad y permisos restringidos. No toqués `report.json` ni ningún
> artefacto existente. Tests con gzip sintético en memoria y cliente S3
> inyectado; cero AWS real en tests.

### Fase B1 — Sonnet 5

> Implementá la migración `pilot_events`, `PersistPilotEventJob` (INSERT sin
> callbacks ni broadcast), la doble emisión de `PilotUsageLog.log` (log intacto
> + encolado con el payload ya whitelisteado) y el evento `rag_quality` sin
> texto crudo desde `log_quality_signal` (excluye question/answer_snippet/
> citation_titles; agrega question_sha256/answer_sha256). Kill-switch
> `PILOT_EVENTS_PERSIST`. La restricción 3 es innegociable: aserción negativa
> explícita en tests de que ninguna clave de texto crudo llega a la tabla. No
> despliegues nada: la migración corre en prod solo con el deploy aprobado del
> gate.

### Fase B2 — Sonnet 5

> Hacé que `PilotTelemetryReader`/`PilotMetricsReport` lean `pilot_events` como
> fuente cuando el log falta, declarando la fuente en `data_quality`, sin
> cambiar ninguna clave del contrato. Actualizá `docs/METRICS.md`,
> `docs/PILOT_CAPTURE_TEMPLATE.md` y la revisión fechada de "Qué NO está en
> este plan" en `docs/rag/plan_tracking_piloto_2026-08-04.md` (anotar, no
> borrar). Tests: log vacío + tabla poblada reproduce `interactions`; doble
> fuente no duplica.

### Gate — Sonnet 5

> Sesión NUEVA que no implementó A1/B1/B2. Verificá el checkpoint de deploy
> (aprobación separada), ejecutá 2-4 preguntas reales y validá el criterio
> congelado del Gate de este documento, incluyendo la reproducción por pipeline
> de `recovered_2026-08-19.json` para el rango 2026-08-10 → 2026-08-12.
> Artefactos a `tmp/` con SHA256. Si algo falla, es un hallazgo para escalar,
> no algo para parchear en la sesión del gate.

## Qué NO está en este plan

- **Persistir `[PILOT_AUDIT]` (texto crudo) en base de datos.** El texto
  completo queda bajo su gate en logs y bajo el frente A (S3) para
  reconstrucción. Mover texto crudo a RDS sería un cambio de postura de
  privacidad que requiere su propia decisión.
- **Cambiar `config/deploy.yml` o el bucket S3.** D1 y D2 son decisiones
  humanas escaladas, no fases.
- **Backfill histórico de `pilot_events`.** La tabla arranca vacía; lo anterior
  se reconstruye bajo demanda por el frente A. Un backfill sería trabajo sin
  consumidor definido.
- **Tocar el ciclo de precisión RAG.** Objetivo distinto, documentos distintos.
- **Dashboards o alertas sobre `pilot_events`.** Consumidor único por ahora:
  `pilot_metrics_report.rb`. Nada de Turbo broadcasts nuevos (regla de
  performance).
