# Auditoría del estado del Companion y del RAG


**Papel.** Soporte técnico del 19 de octubre de 2026. No es una cola de ejecución. La cola operativa es [PLAN_FIELD_COMPANION_CONVERSACION_2026-10-07.md](PLAN_FIELD_COMPANION_CONVERSACION_2026-10-07.md), sección «Estado actual, 2026-10-19».

La lectura del mismo día cerró el encargo de la sección 10. El texto de abajo conserva la auditoría. Donde una frase de acción quedó superada, la enmienda está marcada en su sitio. Prevalecen estas precisiones:

- El export disponible del viernes termina antes del incidente posterior con foto. No permite descartar su causa.
- H4 fue reproducido en `EpisodeThreadResolver`. No explica los turnos `owner` del export examinado.
- H5 pierde el id explícito de foto. Tras un reset sin selección ese id falta. Tras pulsar reutilizar, viaja.
- Un reset correcto no resuelve la fidelidad de Chapa nivel 2 ni la del resumen.
- La comparación de modelo propuesta por Opus permanece como intervención acotada pendiente. No equivale a migración ni a validación del Companion.

Fecha: 19 de octubre de 2026. Repositorio: `danebo-labs/smart_deal`.

**Snapshot remoto auditado: `0b97c964dab3a6cb2714d6a5b076000d28f394d7`**, resuelto desde el árbol de `main`. Esta auditoría es de código y documentación: no acredita qué corre hoy en producción, no consulta datos reales, no ejecuta Rails ni modelos y no modifica el repositorio. El consolidado de Grok informa cambios posteriores del plan que siguen sin commit; no están en este snapshot. Las aceptaciones del recorrido se conservan según ese consolidado y el handoff entregados por Lahiri.

## 1. Dictamen y decisión inmediata

La sospecha de estructuras heredadas tiene fundamento. Hay columnas y métodos candidatos a limpieza, pero **no hay evidencia para sustituir ahora el modelo de sesión ni para borrar tablas del RAG**. El primer problema funcional es poder comenzar una prueba desde un contexto conocido, observar todo lo que entra al request y preservar un recorrido de regresión.

Hallazgos principales:

1. Ya existe `field_companion:reset_active_episode`, no una limpieza completa. Vacía exclusivamente `active_episode`, conservando historial, foco, procedimiento, TTL y timestamps. Sus tests aseguran precisamente ese comportamiento limitado.
2. `ConversationSession` es un workspace persistente; `ActiveEpisode` es su caso actual. Los manuales seleccionados pertenecen al workspace y sobreviven al cambio de caso por diseño. No son tres nombres para una misma conversación.
3. `current_procedure` y `session_status` son candidatos concretos a retirar: en el código web examinado no gobiernan el recorrido. Debe cerrarse la búsqueda global de consumidores antes de una migración.
4. `active_entities` dejó de ser el foco web; sigue teniendo código para WhatsApp y compatibilidad. Que no sirva para el web actual no significa que se pueda borrar sin retirar esas dependencias.
5. El estado efectivo incluye más que columnas: navegador, jobs en vuelo, tokens de fotos, flags y rutas alternativas. Borrar solo un JSON no certifica un inicio limpio.
6. La auditoría encuentra riesgos concretos en lectores de historial y transporte de foto. **No demuestra que causaran el incidente del viernes ni reemplaza el bloqueo de fidelidad ya auditado.**

Recomendación: completar primero un reset de debug verificable y acotado sobre las estructuras existentes; luego usarlo para el recorrido lineal de texto y su regresión. Mantener identificada la comparación de modelo propuesta por Opus como intervención pendiente para el bloqueo de generación, sin mezclarla con cambios del reset.

## 2. Documentación consultada y autoridad

Se leyó el README raíz y el índice `docs/README.md`; se examinaron las referencias activas de sesiones, arquitectura, orquestación, producto, ingesta, métricas y trazabilidad. Los planes grandes se descargaron íntegros y se inspeccionaron sus apartados relevantes para sesión, foco, fases y estado, no todas sus transcripciones históricas. No se afirma haber leído todos los Markdown del repositorio.

Fuentes principales, ancladas al commit auditado:

- [README](https://github.com/danebo-labs/smart_deal/blob/0b97c964dab3a6cb2714d6a5b076000d28f394d7/README.md).
- [Mapa documental](https://github.com/danebo-labs/smart_deal/blob/0b97c964dab3a6cb2714d6a5b076000d28f394d7/docs/README.md).
- [Contrato de sesión y recuperación](https://github.com/danebo-labs/smart_deal/blob/0b97c964dab3a6cb2714d6a5b076000d28f394d7/docs/SESSION_AND_RETRIEVAL.md).
- [Arquitectura activa](https://github.com/danebo-labs/smart_deal/blob/0b97c964dab3a6cb2714d6a5b076000d28f394d7/docs/ACTIVE_ARCHITECTURE.md).
- [Plan vigente del Companion](https://github.com/danebo-labs/smart_deal/blob/0b97c964dab3a6cb2714d6a5b076000d28f394d7/docs/PLAN_FIELD_COMPANION_CONVERSACION_2026-10-07.md).
- [Refactor del foco documental](https://github.com/danebo-labs/smart_deal/blob/0b97c964dab3a6cb2714d6a5b076000d28f394d7/docs/PLAN_FIELD_COMPANION_DOCUMENT_FOCUS_REFACTOR_2026-10-01.md).
- [R1B: lifecycle y writers tardíos](https://github.com/danebo-labs/smart_deal/blob/0b97c964dab3a6cb2714d6a5b076000d28f394d7/docs/PLAN_R1B_SESSION_CORRECTNESS_2026-09-30.md).
- `docs/QUERY_ORCHESTRATOR.md`, `PRODUCT_ROADMAP.md`, `INGESTION_ROUTING.md`, `WEB_CUSTOM_CHUNKING.md`, `METRICS.md`, `PILOT_TRACEABILITY.md`, `MULTI_TENANT_ARCHITECTURE.md`.
- Instrucciones raíz, `app/AGENTS.md` y `app/services/rag/AGENTS.md`; planes padre de epistemología y multimodalidad, consultados como antecedentes.

El índice recomienda usar el mapa en lugar de tratar cada Markdown histórico como contrato actual. Hay desalineaciones documentales reales: el índice aún dice que tres etapas no empezaron; algunos encabezados del plan son anteriores a sus corridas; comentarios todavía dicen que las URI web vienen de `active_entities`. El código web vigente usa `document_focus`. `docs/TENANCY.md`, citado por AGENTS raíz, no existe en este snapshot; la referencia disponible es `MULTI_TENANT_ARCHITECTURE.md`.

## 3. Cómo se construye una consulta web

1. `RagController#ask` resuelve la fila por cuenta, identificador del usuario y canal. En modo compartido se sustituyen identificador y canal y se omite el dueño individual.
2. Guarda el turno del usuario mediante `record_user_turn!`. Según flags puede interpretar el turno, actualizar el episodio, decidir continuidad/corrección/caso nuevo y componer la consulta efectiva.
3. `SessionContextBuilder` construye el contexto: foco documental, historial reciente y, cuando corresponde, problema activo y proyección de foto. El episodio no equivale a evidencia del manual.
4. Las URI del foco se toman de la captura del turno si existe o de `document_focus` para web. La autorización del documento y el alcance de recuperación pasan por políticas independientes.
5. `RagQueryConcern` decide si responde meta/aclaración, usa la consulta compuesta o recurre a los lectores de seguimiento. `QueryOrchestratorService` encamina texto, foto o ingesta.
6. `BedrockRagService` aplica autorización, identidad, recuperación y generación según la ruta. Hay generación directa a partir de chunks; no debe asumirse que todas las respuestas usan una sesión administrada `RetrieveAndGenerate` porque una descripción general lo diga.
7. Se guarda el assistant con `expected_episode_id`. Con el flag de episodios activo, un resultado que pertenece a otro episodio no escribe el estado del caso actual.
8. Ingesta, fotos y telemetría tienen trabajos asíncronos adicionales. No son la misma clase de memoria.

Fuentes: `app/controllers/rag_controller.rb`, `app/controllers/concerns/rag_query_concern.rb`, `app/services/query_orchestrator_service.rb`, `app/services/bedrock_rag_service.rb`, `app/services/session_context_builder.rb`, `app/models/conversation_session.rb`.

## 4. ConversationSession: todos sus campos

Esquema: `db/schema.rb`, tabla `conversation_sessions`. Rails agrega además `id` como clave primaria.

| Campo | Función comprobada / alcance | Juicio para Companion y debug |
|---|---|---|
| `id` | Identidad física de la fila; la referencian fotos, jobs y telemetría | Conservar; el workspace no es el episodio |
| `account_id` | Aislamiento de cuenta y parte de la clave de búsqueda | Conservar; obligatorio en DB |
| `identifier` | Clave lógica del workspace; web usa el ID del usuario como texto, shared usa identificador configurado | Conservar. Redundancia aparente con `user_id` explicada por canales; validar divergencias de datos |
| `channel` | `web`, `shared` o `whatsapp`; cambia lectores, escritores y flags | Conservar; no asumir que toda fila pertenece al web |
| `user_id` | Atribución del dueño cuando aplica; shared puede ser nulo | Conservar. La tarea de reset filtra por este campo, mientras el runtime resuelve por `identifier` |
| `active_episode` | JSON del caso actual: identidad, objetivo, observaciones, correcciones, pendientes y foto | Estado central del Companion; resetear o sustituir por episodio nuevo según contrato |
| `document_focus` | Array de documentos de catálogo seleccionados en web y shared. Cada entrada guarda `kb_document_id`, `source_uri`, `display_name` y `added_at`. La foto de terreno no es una entrada de este array | Estado activo y necesario; vaciar para debug desde cero y luego seleccionar manual explícitamente |
| `active_entities` | Hash de entidades y pines heredado; foco de WhatsApp y APIs de compatibilidad | No es foco web. Candidato a retirar solo junto con dependencias dormidas; para debug inventariar su presencia |
| `conversation_history` | Últimas 20 entradas, no historial completo; contenido truncado, roles y metadatos | Estado activo. Conservar la columna y la evidencia previa. Excluirlo del intérprete, de la consulta efectiva y de la generación solo si los lectores y flags de la corrida lo demuestran |
| `current_procedure` | Hash inicial vacío; reset y boundaries lo vacían | Candidato fuerte: no se encontró lector funcional en los archivos web examinados; no es el procedimiento que hoy guía al técnico |
| `session_status` | Default `active`; `reset_procedure!` lo vuelve a ese valor | Candidato fuerte: `scope :active` usa `expires_at`, no este campo; falta cierre global de consumidores |
| `expires_at` | TTL deslizante de workspace, 30 días; si vence, `find_or_create_for` destruye y recrea la fila | Conservar; no usar expiración como sustituto del reset de prueba |
| `created_at` | Creación física del workspace | Conservar y exportar |
| `updated_at` | Última escritura convencional de la fila; `update_columns` del reset no lo modifica | No equivale a `active_episode.updated_at`; exportar ambos |

Índice único: `(account_id, identifier, channel)`. Hay GIN sobre historial y entidades; su utilidad de rendimiento no se puede concluir desde el esquema. Confirmar consultas y estadísticas antes de eliminarlos. No hay GIN equivalente sobre `active_episode` o `document_focus` en el esquema auditado.

### Estructura interna de active_episode

No hay una tabla `episodes`: estos campos viven dentro de un JSONB, parseado y limitado por `Rag::ActiveEpisode`.

| Clave | Propósito |
|---|---|
| `v` | Versión del formato; el parser exige 1 |
| `episode_id` | Identidad lógica del caso y guarda de writers tardíos |
| `status` | Estado del payload, normalmente `active`; se conserva, pero no se observó que controle `blank?` o la vigencia. Candidato a revisar, no a borrar sin búsqueda global |
| `opened_at` | Piso temporal de los lectores de historial que respetan boundaries |
| `updated_at` | Vigencia del episodio: ventana de 4 horas respecto a este timestamp |
| `opened_by` | Correlación que abrió el caso; trazabilidad |
| `goal` | Objetivo durable: `text`, `correlation_id`, indicador `truncated` |
| `facts` | Slots `manufacturer`, `model`, `controller`, `fault_code`; cada uno guarda status, source, correlation, fecha y valor cuando es conocido |
| `identifiers` | Etiquetas literales relevantes declaradas; no son funciones inferidas. Valor, fuente y correlación |
| `observations` | Reportes del técnico, texto y correlación; no mediciones inventadas |
| `rejected` | Valores retirados por corrección, con `slot` y `value`; evita reintroducirlos |
| `pending_question` | Pregunta estructurada pendiente: tipo, opciones cuando corresponde y hasta dos spans de `carry`. La escriben y la leen el intérprete, la política de ruta y el reductor en el camino `owner` |
| `pending_fact` | Compatibilidad de pendiente simple: `subject`, `correlation_id`. Se mantiene solo para tipos de fact. No es intercambiable con `pending_question` |
| `active_photo` | Puntero a `field_photo_id`, SHA y correlación; la observación completa se lee de la fila de foto |
| `conflicts` | Desacuerdos entre fuentes, con slot, texto usuario/foto y correlación; no deben resolverse inventando |

`pending_question` y `pending_fact` se solapan, pero hoy no son intercambiables sin migrar los fallbacks. Es un candidato posterior a consolidación, no un campo muerto confirmado.

Límites actuales relevantes: episodio de hasta 4096 bytes; objetivo 300 caracteres; hasta 5 identificadores; hasta 12 observaciones almacenadas de 180 caracteres; hasta 4 rechazos y 3 conflictos. El prompt del problema tiene un cap de 600 caracteres; el contexto de sesión total, 2000. La persistencia de un dato no garantiza que llegue al modelo: hay selección y recorte adicionales.

### Estructura interna de document_focus e historial

| Estructura | Claves | Uso |
|---|---|---|
| Entrada de `document_focus` | `kb_document_id`, `source_uri`, `display_name`, `added_at` | Identidad de la fila, filtro físico, nombre presentado y recencia. Alias y tipo se resuelven desde `KbDocument`, no se duplican aquí |
| Entrada de historial | `role`, `content`, `ts`, `user_id`, `correlation_id` | Secuencia acotada y atribución; `ts` permite el corte temporal |
| Metadatos adicionales de historial | `focus_ids`, `retrieval_query` | Asociación de respuesta con selección documental y consulta efectiva del turno para replay; solo se agregan donde el código los escribe |

El prompt con alcance de episodio usa los últimos 3 mensajes de usuario y el último assistant, en orden almacenado; ese assistant se recorta a 200 caracteres. Con el flag de alcance apagado se usa otro lector de historial reciente. `history_for_prompt` solo lo leen tests. `recent_history_for_prompt` alimenta el prompt si `RAG_EPISODE_SCOPE_ENABLED=false` y el job de WhatsApp. Con el default encendido, el web usa `episode_prompt_history`. `pins_after_expiry` y `pins_after_manufacturer_correction` no tienen caller.

## 5. Reset existente: qué hace y qué no

Fuente: [lib/tasks/field_companion.rake](https://github.com/danebo-labs/smart_deal/blob/0b97c964dab3a6cb2714d6a5b076000d28f394d7/lib/tasks/field_companion.rake), y `test/tasks/field_companion_reset_test.rb`.

Nombre exacto: `field_companion:reset_active_episode[account_slug,user_email]`.

- Resuelve cuenta y usuario; selecciona filas web por `account` y `user`.
- Dry-run por defecto; escritura solo con `APPLY=true`.
- Usa lock por fila y `update_columns(active_episode: {})`.
- Conserva todo lo demás, incluidos timestamps. El test confirma idempotencia, preservación del resto y aislamiento frente a otro usuario.
- No exporta una copia previa, no limpia historial, foco, procedimiento, navegador, jobs ni caché; no selecciona por ID exacto de sesión.
- No se ejecutó durante esta auditoría.

`reset_active_episode!` del modelo también solo vacía el episodio. `reset_procedure!` solo vacía procedimiento y activa status. `start_new_case!` abre otro episodio y vacía procedimiento, manteniendo pines, historial y fotos; está descrito como futuro control explícito y no está conectado a una ruta en el código revisado.

**Riesgo verificable por lectura:** si el episodio queda `{}`, `episode_history_cutoff` vuelve a `now - 4.hours`; no tiene un `opened_at` nuevo con el cual excluir el historial anterior. Una consulta significativa que abra un episodio nuevo puede cerrar ese acceso por su nuevo piso temporal, pero no se debe atribuir esa garantía al reset que solo vacía el JSON ni a todas las rutas.

`start_new_case!` crea el `opened_at` que excluye el historial previo del prompt y del rewriter. Conserva `document_focus`, así que el manual anterior sigue filtrando la recuperación. El resolver de hilo no usa ese piso. La tarea por `user_id` y canal web no es equivalente a la búsqueda del runtime.

## 6. Hallazgos funcionales y grado de certeza

| ID | Hallazgo | Evidencia y límite | Acción propuesta |
|---|---|---|---|
| H1 | Reset parcial presentado como posible base de debug | Código y test preservan historial y foco | Conservar su semántica y añadir una operación explícita de debug completo o ampliación con modo inequívoco |
| H2 | Reset por `user_id`, runtime por `identifier` | Task vs `find_or_create_for`; shared usa otro canal y puede no tener user | Preflight debe mostrar fila exacta y coincidencia de claves; detectar cero/múltiples filas y shared |
| H3 | Pendientes de procedimiento/status heredados | Lectura del 19 de octubre: `current_procedure` y `session_status` no tienen lector web que cambie el recorrido. En las bases locales revisadas están en default | Candidatos a simplificar. Las columnas se conservan. No bloquean el debug ni autorizan una migración |
| H4 | Lector alternativo con piso temporal distinto | `EpisodeThreadResolver#episode_rows` usa solo 4h, sin `opened_at`; rewriter y lectores del modelo sí contemplan el piso | Reproducido el 19 de octubre sin modelo: un mensaje anterior a `opened_at` y dentro de cuatro horas entra al resolver y no al rewriter ni a `episode_prompt_history`. El resolver corre con turno apagado, resultado nulo, `:no_episode` o `:skipped`. El camino `owner` del 16 de octubre no lo invoca. No explica los turnos owner de ese export |
| H5 | Selección explícita de foto se borra antes del envío normal | `reuseFieldPhoto` asigna `pendingFieldPhotoId`; `sendMessage` lo pone a null antes de llamar a `ask`; `ask` lo consulta para añadir `field_photo_id` | Reproducido: después de reutilizar, el payload es solo la pregunta. `ask` tiene un único caller y el id ya fue anulado. Sin id y sin frase visual, la continuidad hace passthrough. El export del 16 de octubre no contiene pedidos de foto. Tras un reset sin selección ese id debe faltar; tras pulsar reutilizar debe viajar. No es la causa del incidente posterior con foto |
| H6 | Foto reutilizable por ID de cuenta, no por sesión original | `PhotoObservationContinuity` acepta ID explícito de foto de la cuenta; fallback usa puntero del episodio | Es compatible con elegir una foto anterior. Reset debe quitar selección implícita y UI residual; no borrar todas las fotos |
| H7 | Jobs pueden completar tras un boundary | Guardas `expected_episode_id` protegen varias escrituras, dependiendo de flags | Test de reset con trabajo anterior en vuelo; comprobar estado y salida al navegador por separado |
| H8 | Reutilización de observación durable y dedup por SHA | `FieldPhotoStore` reutiliza fila por cuenta/SHA; continuidad puede reutilizar `visual_observation` | Una foto reenviada no implica fila nueva ni dueño actualizado; no deducir episodio dueño del FK o timestamp |
| H9 | Metadatos del catálogo pueden persistir tras la conversación | `KbDocumentEnrichmentJob` enriquece nombres/aliases, sin crear pin | No limpiar catálogo por reset. Si se investiga discovery, comparar metadatos antes/después de forma independiente |
| H10 | Comentarios y documentos mezclan contratos históricos | R1B histórico soltaba pines; refactor posterior conserva foco web; flag aún menciona active_entities | Actualizar solo referencias activas conflictivas cuando se cierre el contrato; no borrar evidencia histórica |

H4 y H5 quedaron reproducidos el 19 de octubre, sin modelo. H4 no corre en el camino `owner` del export del 16 de octubre. H5 produce un payload sin `field_photo_id` y ese export no tuvo fotos. Ninguno invalida los tramos aceptados ni explica el fallo de Chapa nivel 2. Un reset correcto tampoco lo resuelve. El export disponible del viernes termina antes del incidente posterior con foto y no permite descartar su causa.

## 7. Tablas y almacenes alrededor del RAG

| Capa | Tablas / almacén | Papel y regla para debug |
|---|---|---|
| Contexto del caso | `conversation_sessions` | Limpiar únicamente el workspace de prueba seleccionado; es el estado central que hay que controlar |
| Fotos de terreno | `field_photos` y originales S3 `field_photos/` | Bytes y observación durable; quitar puntero/selección de caso, conservar evidencia y archivos |
| Catálogo | `kb_documents`, `kb_document_thumbnails` | Manuales disponibles, identidad y miniaturas; conservar |
| Autorización | `accounts`, `users`, `knowledge_scope_changes` | Cuenta, identidad y auditoría de permisos; conservar |
| Auditoría documental | `technician_documents` | Registro de ingesta/uso, ya no precarga pines; conservar hasta evaluar consumidores |
| Ingesta | `web_manual_batches`, `bulk_uploads`, `bulk_upload_assets` | Contratos, trabajos y ledger de indexación; algunos participan en elegibilidad documental. No borrarlos porque la ruta ZIP esté desactivada |
| Trazabilidad / gasto | `pilot_events`, `bedrock_queries`, `bedrock_daily_costs`, `cost_metrics` | Evidencia y costos; conservar, distinguiendo lo anterior y posterior al reset por correlación |
| Canal dormido | `whatsapp_cache_hits` y código WhatsApp | No forma parte del recorrido web; su retiro requiere decisión separada |
| Caché Rails | `solid_cache_entries` en DB cache | Incluye transporte efímero de fotos y cachés documentales; no vaciar globalmente |
| Jobs | `solid_queue_*` en DB queue | Puede haber trabajos activos con snapshot/owner anterior; no purgar globalmente |
| Entrega asíncrona | `solid_cable_messages` en DB cable | Transporte de mensajes, no memoria de razonamiento; comprobar recepción de eventos antiguos |
| Índice vectorial | Aurora/Bedrock, fuera de `db/schema.rb` | No es contexto de conversación; conservar íntegro durante reset |
| Corpus / artefactos | S3 originales, chunks y sidecars; manifests | Conservar. Caché de vecinos solo se invalida al reparar sus documentos, no por empezar una conversación |
| Text-to-SQL | conexión `client_db`, `ClientDatabase` abstracto | Datos operacionales separados; no limpiar como si fueran sesión |
| Módulo de certificación | `certification_reports`, `inspection_findings`, `report_equipments`, `voice_dictations` y campos certifier de accounts | Fuera del reset Companion. Compartir fotos o pertenecer al mismo esquema no los vuelve obsoletos |

`BedrockKbChunk` es una referencia abstracta al almacén externo, no una tabla Rails conectada al arranque. Contiene un snapshot de mayo de `id`, `embedding`, `chunks`, `metadata`, `custommetadata`, dimensión 1024, con inspección SQL pendiente en sus propios comentarios. Eso no certifica el esquema físico actual ni las claves reales de metadatos. El snapshot del 7 de mayo de 2026 corresponde a la KB `VBB72VKABV`. La KB que sirvió el chat del 16 de octubre es `Y7RZWMFJSR`. No hay un `\d` local de esa tabla. Esa ausencia no bloquea el debug de la conversación y no se inventa desde `db/schema.rb`.

### Campos de otras tablas: interpretación

El anexo al final enumera cada columna relevante del esquema con propósito, tipo y definición. La utilidad operacional de un campo de ingesta se distingue de si lo consume cada consulta. Por ejemplo, `bulk_upload_assets.chunks_s3_prefix` puede respaldar elegibilidad/indexación aunque ningún prompt lo imprima.

Observaciones para limpieza posterior:

- `TechnicianDocument` conserva `identifier` y `channel`, pero deduplica por cuenta/URI o nombre; la constante `MAX_PER_TECHNICIAN` aplica el límite por cuenta cuando se pasa `account_id`. El nombre histórico puede inducir a pensar que es memoria individual. No está precargando el Companion.
- `claude_batch_id` y `claude_batch_ids` tienen fallback explícito en modelos de ingesta. No son duplicados eliminables sin migrar datos y callers.
- `document_focus` duplica URI/nombre del catálogo intencionalmente para mantener foco. Hace falta revisar coherencia y autorización, no asumir que la duplicación demuestra error de diseño.
- Ningún campo se considera inútil solo porque no aparece en la demo. Índices, ledger, costo, idempotencia y compatibilidad pueden justificarlo.

## 8. Contrato mínimo del debug propuesto

Esto es una especificación para implementar/revisar, **no una herramienta ya construida o validada**.

**Preflight y evidencia**

- Cuenta, usuario, identificador, canal y `conversation_session_id` exactos. Mostrar modo compartido y rechazar asumir dueño individual si no aplica.
- Registrar commit local, diferencias relevantes sin commit, versión desplegada si se usa web, flags efectivos y modelos por rol. Registrar las conexiones resueltas sin credenciales.
- Exportar estado previo: episodio, historial, foco, entidades y procedimiento; referencias a fotos y jobs relevantes. No borrar ni exportar secretos.
- Detectar trabajo en vuelo de ese workspace. Preferir un caso estable sin trabajo pendiente para la prueba básica; si hay actividad, no declarar limpieza efectiva solo por terminar el UPDATE.

**Aplicación del reset de debug**

- Operación acotada, con dry-run y lock. Preservar la identidad de la fila salvo razón concreta para cambiarla; evitar dejar referencias huérfanas al destruirla.
- Dentro del lock: `start_new_case!` y `document_focus = []` en la misma transición. Conservar la fila, las fotos, `active_entities` y el TTL. Conservar el historial de la columna solo si `episode_prompt_history` y el rewriter, con el alcance de episodio encendido, dejan fuera lo anterior. Si la ruta usa otro lector, el debug queda incompleto.
- Abrir un `episode_id` nuevo o aplicar una transición equivalente que excluya inequívocamente el caso anterior. Evitar el intervalo ambiguo de `{}` más historial antiguo. La alternativa elegida debe funcionar con el modo real de flags.
- Invalidar ownership anterior: comprobar que un assistant, foto o auto-pin iniciado antes no repueble el nuevo caso. Los detalles de flags y writers con IDs ausentes son parte de la prueba.
- Reinicializar la UI y su selección de foto/archivo/replay pendiente. Si hay pestañas viejas, impedir que su estado residual se confunda con el caso nuevo.
- No tocar documentos, índice, permisos, otras sesiones, ingesta, costos o archivos de fotos. No purgar caché, jobs ni cable globalmente.

**Comprobación de limpieza efectiva**

- Captura previa a modelo: episodio, historial elegido, foco/URI, identidad, foto, consulta original y efectiva, bloques de contexto y ruta.
- Verificar ausencia de antecedentes anteriores tanto en request del intérprete como en recuperación y generación; revisar `session_id` externo si algún cliente lo manda.
- Usar una marca de prueba reconocible para detectar arrastre, sin contaminar catálogo/índice.
- La prueba de limpieza debe poder hacerse con dobles y captura de requests sin pagar modelos. Luego ejecutar el recorrido real para evaluar la conducta del modelo.
- El resultado del reset debe poder decir `limpio`, `incompleto` o `no comprobado` con evidencia. Una pantalla vacía y un HTTP 200 no bastan.

`Rag::ValidationCapture` ya ofrece captura local activada explícitamente: contexto, requests, rutas, chunks, publicación y procedencia observada/reconstruida. Reutilizarla; no abrir otra tabla de auditoría ni otro pipeline para obtener la misma evidencia. Los arneses `Phase1PinnedTurn`, `Phase2PinnedTurn` y `Phase3PinnedTurn` ya resuelven aislamiento/captura en parte, pero tienen sesiones nuevas o clonadas y no sustituyen una comprobación web completa.

La selección del debug aborta salvo una fila con cuenta, usuario, canal web e `identifier` igual al id de usuario. La herramienta abre un episodio con `start_new_case!` y vacía `document_focus` en el mismo lock. El historial de la columna se conserva solo si los lectores y los flags de esa corrida demuestran la exclusión. La aceptación lee `ValidationCapture`: episodio nuevo, foco vacío, contexto reciente limitado al turno nuevo y filtro de recuperación vacío hasta el pin explícito. Esta herramienta sigue pendiente en el plan operativo. No está construida aquí.

## 9. Regresión y Plan B de demo

Orden acordado por Lahiri: texto lineal → mismo caso con fotos → varios temas. Las consultas aisladas diagnostican bloqueos y vuelven después a la conversación.

- Primero un recorrido mínimo útil, desde reset comprobado, selección del manual, síntoma, seguimiento, corrección y resumen. No imponer 14 turnos por historia.
- Guardar la secuencia exacta, estado inicial, commit, flags y modelo; separar hechos, inferencias y ausencias esperadas. El primer recorrido completo aún está pendiente.
- A cada interacción nueva aceptada, añadir sus comprobaciones y volver a ejecutar la secuencia ampliada sin reset entre mensajes.
- Dobles verifican lógica/estado/request. Modelo real verifica fidelidad y conducta antes de promover una ampliación de demo. No declarar fiabilidad estadística por una sola pasada.
- Condiciones mínimas: preserva el pin, mantiene la corrección, no inventa observaciones, no contradice conexiones del plano, no atribuye una función como hecho sin respaldo y resume el caso sin fusionar referencias.
- Mantener una versión/configuración anterior recuperable. La nueva versión entra a demo cuando conserva el recorrido base. Si falla, registrar el fallo y conservar la anterior.
- Matriz de alcance: comprobado / falló / no probado. Una demo acotada puede usar el guion de respaldo si se explican sus condiciones; no equivale a Companion completo.

La generación defectuosa de Chapa nivel 2 y la fidelidad del resumen siguen abiertas. El reset no las resuelve por sí mismo. La comparación de Sonnet sobre el request capturado sigue siendo una intervención acotada pendiente, con cambio de solo modelId; su éxito no valida todo el recorrido.

## 10. Encargo concreto para Grok: cerrar los gaps y preparar el debug

**Lectura del 19 de octubre, cerrada.** Este encargo ya se leyó. El resultado está en el plan operativo, sección «Estado actual, 2026-10-19». No es otra cola. No se eliminan columnas y no se reabren los gaps cerrados en esa lectura. La lista de abajo conserva el encargo original.

**Resultado.** Los puntos 1 a 5 quedaron leídos: snapshot `0b97c964`, consumidores inventariados, conteos locales, H4 reproducido fuera del camino `owner` y H5 reproducido como pérdida del id. El punto 6 es la siguiente implementación del plan operativo y sigue pendiente. Los puntos 7 y 8 esperan ese debug y el recorrido de texto. No se corrige aquí el lector de H4.

Trabajar sobre el plan vigente, conservando las aceptaciones registradas y el compromiso del viernes 23. Esta auditoría no crea una nueva secuencia de fases paralela.

1. **Reconciliar snapshot.** Confirmar SHA local, remoto, cambios del plan sin commit y versión efectiva del entorno de prueba. No reexportar artefactos ya disponibles.
2. **Cerrar búsqueda global.** Para `current_procedure`, `session_status`, `active_episode.status`, `pending_fact`, `active_entities`, `history_for_prompt`, `recent_history_for_prompt`, `pins_after_expiry` y `pins_after_manufacturer_correction`: listar lectores, escritores, callers, rutas activas/dormidas y tests. La búsqueda de código del conector devolvió resultados vacíos incluso para símbolos que sí existen; no se usó como prueba de ausencia. Esta revisión local con rg es el gap principal para declarar algo muerto.
3. **Datos reales solo de lectura.** Para la cuenta/usuario de prueba: comprobar correspondencia identifier/user_id, shared, valores no vacíos de campos candidatos y JSON heredado. Informar conteos/resultados, sin volcar datos de otros usuarios. No deducir el contenido de producción del esquema.
4. **Cerrar H4.** Demostrar si `EpisodeThreadResolver` puede leer mensajes anteriores a opened_at con las flags/rutas activas; incluir los casos `no_episode`, `skipped` y fallback. Si hay defecto, corregir el lector pertinente y verificar el recorrido previo.
5. **Cerrar H5.** Reproducir clic reutilizar foto → enviar → payload; corregir el transporte si se confirma. No usarlo como causa del incidente sin su request histórico.
6. **Preparar el debug mínimo.** Reutilizar lifecycle, locks, ownership y ValidationCapture. Presentar los campos antes/después y las guardas; no ejecutar contra producción ni llamar modelos como parte implícita de la auditoría. La tarea actual de reset debe seguir teniendo un nombre/contrato inequívoco.
7. **Verificar aislamiento con dobles.** Caso nuevo no hereda marca, observación, foto, historial ni pin del anterior; otro usuario/cuenta queda intacto; writer anterior no repuebla el nuevo caso. Después pin explícito funciona y permanece entre turnos.
8. **Volver al recorrido.** Con el inicio limpio demostrado, resolver el bloqueo de generación y ejecutar una sola conversación lineal completa con evidencia por turno. Ampliar la regresión y fijar el Plan B de demo a partir de lo aceptado.

Entregar una respuesta acotada: confirmaciones/correcciones a esta auditoría, gaps resueltos, diff propuesto o implementado según autorización del encargo, comprobaciones realizadas y siguiente acción mínima. No reconstruir todo el pasado, no auditar infraestructura del timeout, no rehacer los 14 turnos históricos y no eliminar columnas durante la preparación del reset.

## 11. Límites de esta auditoría

- Revisión estática sobre GitHub, con lectura dirigida de fuentes. Los tests se leyeron, no se ejecutaron.
- No hay inventario SQL actual de producción ni inspección del esquema vectorial externo. Los defaults no prueban datos reales ni flags efectivos.
- Los archivos locales `tmp/` citados por el plan y el request posterior de la demo con foto no forman parte del snapshot remoto auditado. La lectura local no encontró un export posterior al de `2026-10-16T18:05:36Z`. Ese export termina antes del incidente con foto y no permite descartar su causa.
- No se encontró prueba suficiente para eliminar hoy una tabla completa del RAG. Sí hay candidatos de limpieza que se pueden cerrar con búsquedas concretas.
- No se declara viable ni inviable el viernes por esta auditoría. El criterio es completar y comprobar el recorrido, con una base estable de demo y límites visibles.


## Anexo A. Diccionario de columnas del entorno RAG
Inventario del esquema remoto, no lectura de datos. Se cubren 16 tablas en total: contexto, catálogo, ingesta, identidad, telemetría y el registro del canal dormido. Los campos del módulo de certificación se excluyen salvo los que comparten accounts. Cada create_table añade id de Rails; no se repite en cada tabla.
Los propósitos de sesión, catálogo, continuidad, modelos y reset se contrastaron con código. En campos internos de batch/ingesta se describe su papel contractual; esta auditoría no rastreó exhaustivamente cada writer por columna. Antes de retirar alguno, Grok debe cerrar ese rastreo.

### accounts
| Campo | Tipo | Propósito |
|---|---|---|
| `branded` | `boolean` · NOT NULL | Marca visual de tenant; no autoriza corpus compartido. |
| `certifier_logo_byte_size` | `integer` | Módulo de certificación: tamaño del logo. |
| `certifier_logo_content_type` | `string` | Módulo de certificación: MIME del logo. |
| `certifier_logo_s3_key` | `string` | Módulo de certificación: ubicación del logo. |
| `certifier_logo_sha256` | `string` | Módulo de certificación: huella del logo. |
| `certifier_minvu_role` | `string` | Módulo de certificación: rol MINVU configurado. |
| `certifier_name` | `string` | Módulo de certificación: nombre configurado. |
| `certifier_settings_user_id` | `bigint` | Módulo de certificación: propietario de configuración. |
| `created_at` | `datetime` · NOT NULL | Fecha de creación de la fila. |
| `danebo_controlled` | `boolean` · NOT NULL | Marca explícita requerida para ciertas promociones de conocimiento compartido. |
| `display_name` | `string` · NOT NULL | Nombre visible de cuenta. |
| `slug` | `string` · NOT NULL | Identificador lógico; SharedManualCorpus usa slugs determinados para compatibilidad. |
| `updated_at` | `datetime` · NOT NULL | Fecha de última actualización convencional de la fila. |

### bedrock_daily_costs
| Campo | Tipo | Propósito |
|---|---|---|
| `cache_read_tokens` | `bigint` · NOT NULL | Tokens exactos leídos de caché, agregados por día/modelo. |
| `cache_write_tokens` | `bigint` · NOT NULL | Tokens exactos escritos en caché, agregados por día/modelo. |
| `cost_usd` | `decimal` · NOT NULL | Costo conciliado de logs de invocación, autoridad de gasto Bedrock. |
| `created_at` | `datetime` · NOT NULL | Fecha de creación de la fila. |
| `input_tokens` | `bigint` · NOT NULL | Entrada agregada del día/modelo. |
| `invocation_count` | `integer` · NOT NULL | Número de invocaciones conciliadas. |
| `model_id` | `string` · NOT NULL | Modelo de la agrupación. |
| `output_tokens` | `bigint` · NOT NULL | Salida agregada del día/modelo. |
| `reconciled_at` | `datetime` · NOT NULL | Momento de conciliación. |
| `updated_at` | `datetime` · NOT NULL | Fecha de última actualización convencional de la fila. |
| `utc_date` | `date` · NOT NULL | Día UTC de facturación; distinto del hoy local de la UI. |

### bedrock_queries
| Campo | Tipo | Propósito |
|---|---|---|
| `account_id` | `bigint` | Cuenta propietaria o de atribución; delimita el tenant. |
| `attempt` | `integer` | Intento de llamada atribuido; no confundir con turno lógico. |
| `cache_creation_tokens` | `integer` | Tokens de escritura de caché del proveedor registrados en la llamada. |
| `cache_read_tokens` | `integer` | Tokens leídos de caché del proveedor. |
| `conversation_session_id` | `bigint` | Referencia al workspace; no identifica por sí sola el episodio. |
| `correlation_id` | `string` | Enlace de un turno/operación con logs, llamadas y eventos. |
| `created_at` | `datetime` · NOT NULL | Fecha de creación de la fila. |
| `input_tokens` | `integer` | Tokens de entrada registrados/estimados; token_source aclara procedencia. |
| `latency_ms` | `integer` | Latencia atribuida a llamada. |
| `max_tokens` | `integer` | Límite de salida configurado en esa llamada. |
| `model_id` | `string` | Modelo/perfil efectivo de la llamada. |
| `output_tokens` | `integer` | Tokens de salida registrados/estimados. |
| `route` | `string` | Ruta funcional de atribución. |
| `source` | `string` · NOT NULL | Enum: query, ingestion_parse, ingestion_embed o semantic_analysis. |
| `stop_reason` | `string` | Motivo de término reportado por el proveedor, si está disponible. |
| `token_source` | `string` | Procedencia de tokens; estimated identifica estimación, nil puede ser legado. |
| `updated_at` | `datetime` · NOT NULL | Fecha de última actualización convencional de la fila. |
| `user_id` | `bigint` | Usuario propietario o de atribución, cuando existe. |
| `user_query` | `text` | Texto de consulta para atribución/auditoría; no es el historial que lee el Companion. |

### bulk_upload_assets
| Campo | Tipo | Propósito |
|---|---|---|
| `aliases` | `jsonb` · NOT NULL | Nombres alternativos para resolver/buscar el documento. |
| `batch_custom_ids` | `jsonb` · NOT NULL | IDs custom por página o subsolicitud, además del ID principal. |
| `bulk_upload_id` | `bigint` · NOT NULL | Carga ZIP a la que pertenece el asset. |
| `canonical_name` | `string` | Nombre canónico extraído o consolidado para el documento. |
| `chunks_count` | `integer` | Cantidad de chunks producidos por esta ingesta. |
| `chunks_s3_prefix` | `string` | Prefijo S3 de chunks generados; respalda trazabilidad e indexación. |
| `claude_input_tokens` | `integer` | Tokens de entrada atribuidos al parse del asset. |
| `claude_output_tokens` | `integer` | Tokens de salida atribuidos al parse del asset. |
| `content_type` | `string` | Tipo MIME del objeto. |
| `created_at` | `datetime` · NOT NULL | Fecha de creación de la fila. |
| `custom_id` | `string` · NOT NULL | Identificador único de asset/versionado; se usa para enlazar resultados del batch. |
| `dropped_field_records` | `jsonb` · NOT NULL | Registro de elementos descartados por el contrato de extracción; no estado de sesión. |
| `error_message` | `text` | Detalle de fallo del proceso para diagnóstico/operación. |
| `filename` | `string` · NOT NULL | Nombre del archivo procesado. |
| `ingestion_contract_version` | `string` | Versión de contrato con la que se procesó el contenido. |
| `ingestion_path` | `string` | Ruta efectiva de procesamiento registrada en el ledger. |
| `kb_document_id` | `bigint` | Referencia a la fila del catálogo del documento. |
| `office_origin` | `boolean` · NOT NULL | Indica origen Office tras conversión a PDF. |
| `s3_key` | `string` | Ubicación del objeto original en S3, según la ruta de ingesta. |
| `sha256` | `string` · NOT NULL | Huella del contenido para identidad/deduplicación según el contrato de esta tabla. |
| `status` | `string` · NOT NULL | Estado del proceso de esta tabla; no es el estado global del Companion. |
| `updated_at` | `datetime` · NOT NULL | Fecha de última actualización convencional de la fila. |

### bulk_uploads
| Campo | Tipo | Propósito |
|---|---|---|
| `asset_count` | `integer` · NOT NULL | Número de assets contenidos en la carga. |
| `bedrock_ingestion_job_id` | `string` | ID de sincronización del data source en Bedrock. |
| `claude_batch_id` | `string` | ID singular de batch, conservado como fallback de compatibilidad. |
| `claude_batch_ids` | `jsonb` · NOT NULL | IDs de los batches usados cuando el trabajo se reparte. |
| `created_at` | `datetime` · NOT NULL | Fecha de creación de la fila. |
| `error_message` | `text` | Detalle de fallo del proceso para diagnóstico/operación. |
| `original_filename` | `string` · NOT NULL | Nombre del ZIP original. |
| `sha256` | `string` · NOT NULL | Huella de la carga; índice único global en este esquema. No cambiar dentro del reset. |
| `status` | `string` · NOT NULL | Estado del proceso de esta tabla; no es el estado global del Companion. |
| `updated_at` | `datetime` · NOT NULL | Fecha de última actualización convencional de la fila. |
| `user_id` | `bigint` | Usuario propietario o de atribución, cuando existe. |

### conversation_sessions
| Campo | Tipo | Propósito |
|---|---|---|
| `account_id` | `bigint` · NOT NULL | Cuenta propietaria o de atribución; delimita el tenant. |
| `active_entities` | `jsonb` · NOT NULL | Hash heredado de entidades/pines; WhatsApp; no foco web. |
| `active_episode` | `jsonb` · NOT NULL | JSONB del caso activo; estructura desglosada en sección 4. |
| `channel` | `string` · NOT NULL | Canal que selecciona comportamiento web/shared/WhatsApp. |
| `conversation_history` | `jsonb` · NOT NULL | Ventana de 20 entradas y metadatos; lectores con límites propios. |
| `created_at` | `datetime` · NOT NULL | Fecha de creación de la fila. |
| `current_procedure` | `jsonb` · NOT NULL | Hash heredado que hoy se vacía; sin lector funcional web identificado. |
| `document_focus` | `jsonb` · NOT NULL | Array de manuales seleccionados en web/shared. |
| `expires_at` | `datetime` · NOT NULL | Vencimiento deslizante del workspace, 30 días. |
| `identifier` | `string` · NOT NULL | Clave lógica del workspace; ID de usuario como texto en web, configurable en shared. |
| `session_status` | `string` · NOT NULL | Estado heredado, default active; no gobierna scope active ni vigencia. |
| `updated_at` | `datetime` · NOT NULL | Fecha de última actualización convencional de la fila. |
| `user_id` | `bigint` | Usuario propietario o de atribución, cuando existe. |

### cost_metrics
| Campo | Tipo | Propósito |
|---|---|---|
| `created_at` | `datetime` · NOT NULL | Fecha de creación de la fila. |
| `date` | `date` · NOT NULL | Día del agregado operacional. |
| `metadata` | `text` | Metadatos del agregado, serializados como texto JSON; no memoria del caso. |
| `metric_type` | `integer` · NOT NULL | Tipo de métrica enumerado por el modelo. |
| `updated_at` | `datetime` · NOT NULL | Fecha de última actualización convencional de la fila. |
| `value` | `decimal` · NOT NULL | Valor agregado con precisión decimal. |

### field_photos
| Campo | Tipo | Propósito |
|---|---|---|
| `account_id` | `bigint` · NOT NULL | Cuenta propietaria o de atribución; delimita el tenant. |
| `byte_size` | `integer` · NOT NULL | Tamaño del original retenido. |
| `content_type` | `string` · NOT NULL | Tipo MIME del objeto. |
| `conversation_session_id` | `bigint` | Referencia al workspace; no identifica por sí sola el episodio. |
| `created_at` | `datetime` · NOT NULL | Fecha de creación de la fila. |
| `s3_key_original` | `string` · NOT NULL | Objeto S3 del original, fuera del corpus indexado. |
| `sha256` | `string` · NOT NULL | Huella del contenido para identidad/deduplicación según el contrato de esta tabla. |
| `thumbnail_content_type` | `string` | MIME de miniatura inline. |
| `thumbnail_data` | `binary` | Bytes de miniatura para presentación sin descargar original. |
| `thumbnail_height` | `integer` | Alto de miniatura en píxeles. |
| `thumbnail_width` | `integer` | Ancho de miniatura en píxeles. |
| `updated_at` | `datetime` · NOT NULL | Fecha de última actualización convencional de la fila. |
| `user_id` | `bigint` | Usuario propietario o de atribución, cuando existe. |
| `visual_observation` | `jsonb` | Lectura visual sanitizada persistida; puede reutilizarse por la ruta explícita de continuidad. |

### kb_document_thumbnails
| Campo | Tipo | Propósito |
|---|---|---|
| `byte_size` | `integer` | Tamaño de miniatura. |
| `content_type` | `string` · NOT NULL | Tipo MIME del objeto. |
| `created_at` | `datetime` · NOT NULL | Fecha de creación de la fila. |
| `data` | `binary` · NOT NULL | Bytes inline de miniatura documental. |
| `height` | `integer` | Alto en píxeles. |
| `kb_document_id` | `bigint` · NOT NULL | Referencia a la fila del catálogo del documento. |
| `updated_at` | `datetime` · NOT NULL | Fecha de última actualización convencional de la fila. |
| `width` | `integer` | Ancho en píxeles. |

### kb_documents
| Campo | Tipo | Propósito |
|---|---|---|
| `account_id` | `bigint` · NOT NULL | Cuenta propietaria o de atribución; delimita el tenant. |
| `aliases` | `jsonb` · NOT NULL | Nombres alternativos para resolver/buscar el documento. |
| `created_at` | `datetime` · NOT NULL | Fecha de creación de la fila. |
| `display_name` | `string` | Nombre visible del catálogo, enriquecible tras ingesta/respuesta. |
| `document_uid` | `uuid` · NOT NULL | UUID lógico de documento; unicidad por cuenta. |
| `knowledge_scope` | `string` · NOT NULL | tenant_private o danebo_general; autoriza catálogo/pin/sugerencias, no construye solo el filtro abierto. |
| `s3_key` | `string` · NOT NULL | Ubicación del objeto original en S3, según la ruta de ingesta. |
| `size_bytes` | `bigint` | Tamaño del archivo original para catálogo/operación. |
| `updated_at` | `datetime` · NOT NULL | Fecha de última actualización convencional de la fila. |

### knowledge_scope_changes
| Campo | Tipo | Propósito |
|---|---|---|
| `actor` | `string` · NOT NULL | Actor que ejecutó el cambio de alcance. |
| `created_at` | `datetime` · NOT NULL | Fecha de creación de la fila. |
| `from_scope` | `string` · NOT NULL | Alcance anterior. |
| `kb_document_id` | `bigint` · NOT NULL | Referencia a la fila del catálogo del documento. |
| `reason` | `text` · NOT NULL | Motivo explícito del cambio de autorización. |
| `to_scope` | `string` · NOT NULL | Alcance nuevo. |

### pilot_events
| Campo | Tipo | Propósito |
|---|---|---|
| `account_id` | `bigint` | Cuenta propietaria o de atribución; delimita el tenant. |
| `conversation_session_id` | `bigint` | Referencia al workspace; no identifica por sí sola el episodio. |
| `correlation_id` | `string` | Enlace de un turno/operación con logs, llamadas y eventos. |
| `created_at` | `datetime` · NOT NULL | Fecha de creación de la fila. |
| `event` | `string` · NOT NULL | Nombre del evento. |
| `occurred_at` | `datetime` · NOT NULL | Momento del evento, independiente de creación de fila. |
| `payload` | `jsonb` · NOT NULL | Datos estructurados del evento para trazabilidad/métricas; no entrada directa de razonamiento en el flujo revisado. |
| `updated_at` | `datetime` · NOT NULL | Fecha de última actualización convencional de la fila. |
| `user_id` | `bigint` | Usuario propietario o de atribución, cuando existe. |

### technician_documents
| Campo | Tipo | Propósito |
|---|---|---|
| `account_id` | `bigint` · NOT NULL | Cuenta propietaria o de atribución; delimita el tenant. |
| `aliases` | `jsonb` · NOT NULL | Nombres alternativos para resolver/buscar el documento. |
| `canonical_name` | `string` · NOT NULL | Nombre canónico extraído o consolidado para el documento. |
| `channel` | `string` · NOT NULL | Canal de origen histórico/auditoría. |
| `created_at` | `datetime` · NOT NULL | Fecha de creación de la fila. |
| `doc_type` | `string` | Tipo documental recibido en metadatos. |
| `first_answer_summary` | `string` | Resumen heredado recibido como metadato; no precarga automáticamente el prompt web. |
| `identifier` | `string` · NOT NULL | Identificador histórico de origen; no clave actual de deduplicación. |
| `interaction_count` | `integer` · NOT NULL | Número de upserts/uso registrado; no equivale a turnos Companion. |
| `last_used_at` | `datetime` · NOT NULL | Recencia del registro; utilizada para eviction. |
| `source_uri` | `string` | Identidad física documental preferida para deduplicación. |
| `updated_at` | `datetime` · NOT NULL | Fecha de última actualización convencional de la fila. |
| `wa_filename` | `string` | Nombre de archivo heredado del canal; se sigue aceptando como metadato. |

### users
| Campo | Tipo | Propósito |
|---|---|---|
| `account_id` | `bigint` · NOT NULL | Cuenta propietaria o de atribución; delimita el tenant. |
| `created_at` | `datetime` · NOT NULL | Fecha de creación de la fila. |
| `current_sign_in_at` | `datetime` | Momento del acceso actual. |
| `current_sign_in_ip` | `string` | IP del acceso actual. |
| `email` | `string` · NOT NULL | Identidad de acceso y selección explícita de usuario para debug. |
| `encrypted_password` | `string` · NOT NULL | Hash de autenticación Devise; no leer/exportar para la auditoría. |
| `last_sign_in_at` | `datetime` | Momento del acceso anterior. |
| `last_sign_in_ip` | `string` | IP del acceso anterior. |
| `remember_created_at` | `datetime` | Estado temporal de recordar sesión de autenticación. |
| `reset_password_sent_at` | `datetime` | Fecha del flujo de recuperación de contraseña. |
| `reset_password_token` | `string` | Token de recuperación; no leer/exportar para la auditoría. |
| `sign_in_count` | `integer` · NOT NULL | Contador de accesos; no turnos Companion. |
| `updated_at` | `datetime` · NOT NULL | Fecha de última actualización convencional de la fila. |

### web_manual_batches
| Campo | Tipo | Propósito |
|---|---|---|
| `account_id` | `bigint` · NOT NULL | Cuenta propietaria o de atribución; delimita el tenant. |
| `aliases` | `jsonb` · NOT NULL | Nombres alternativos para resolver/buscar el documento. |
| `canonical_name` | `string` | Nombre canónico extraído o consolidado para el documento. |
| `chunks_count` | `integer` | Cantidad de chunks producidos por esta ingesta. |
| `chunks_s3_prefix` | `string` | Prefijo S3 de chunks generados; respalda trazabilidad e indexación. |
| `claude_batch_id` | `string` | ID singular de batch, conservado como fallback de compatibilidad. |
| `claude_batch_ids` | `jsonb` · NOT NULL | IDs de los batches usados cuando el trabajo se reparte. |
| `completed_at` | `datetime` | Fecha de cierre del batch de manual. |
| `content_type` | `string` · NOT NULL | Tipo MIME del objeto. |
| `conv_session_id` | `bigint` | Workspace del envío; no persiste por sí mismo expected_episode_id. |
| `created_at` | `datetime` · NOT NULL | Fecha de creación de la fila. |
| `error_message` | `text` | Detalle de fallo del proceso para diagnóstico/operación. |
| `filename` | `string` · NOT NULL | Nombre del archivo procesado. |
| `ingestion_contract_version` | `string` · NOT NULL | Versión de contrato con la que se procesó el contenido. |
| `kb_document_id` | `bigint` | Referencia a la fila del catálogo del documento. |
| `kept_pages` | `jsonb` · NOT NULL | Páginas retenidas tras selección/filtrado. |
| `locale` | `string` | Idioma para procesamiento y mensajes de la ingesta. |
| `page_customs` | `jsonb` · NOT NULL | Correspondencia por página con identificadores de solicitudes batch; verificar forma JSON en writers actuales. |
| `page_topology_edges` | `jsonb` · NOT NULL | Relaciones/topología por página guardadas por la ingesta; no hechos del caso. |
| `s3_key` | `string` · NOT NULL | Ubicación del objeto original en S3, según la ruta de ingesta. |
| `sha256` | `string` · NOT NULL | Huella del contenido para identidad/deduplicación según el contrato de esta tabla. |
| `status` | `string` · NOT NULL | Estado del proceso de esta tabla; no es el estado global del Companion. |
| `submitted_at` | `datetime` | Fecha de envío del batch al proveedor. |
| `total_pages` | `integer` | Cantidad de páginas del manual. |
| `updated_at` | `datetime` · NOT NULL | Fecha de última actualización convencional de la fila. |
| `urgent_chunks_s3_prefix` | `string` | Prefijo de chunks de la vía urgente. |
| `urgent_completed_at` | `datetime` | Cierre de la vía urgente. |
| `urgent_error_message` | `text` | Error de la vía urgente. |
| `urgent_pages` | `jsonb` · NOT NULL | Páginas seleccionadas para vía urgente. |
| `urgent_started_at` | `datetime` | Inicio de la vía urgente. |
| `urgent_status` | `string` | Estado independiente de vía urgente. |

### whatsapp_cache_hits
| Campo | Tipo | Propósito |
|---|---|---|
| `created_at` | `datetime` · NOT NULL | Fecha de creación de la fila. |
| `recipient` | `string` · NOT NULL | Destino WhatsApp atribuido. |
| `route` | `string` · NOT NULL | Ruta de acierto de caché. |
| `tokens_saved_estimate` | `integer` | Estimación de ahorro por acierto. |
| `updated_at` | `datetime` · NOT NULL | Fecha de última actualización convencional de la fila. |

Cobertura: 16 tablas, 203 columnas explícitas, además de sus IDs implícitos.

## Anexo B. Infraestructura: alcance de campos
Los esquemas cache/queue/cable se revisaron para identificar dónde persiste transporte o trabajo pendiente. Son estructuras de Solid Stack, no un diseño de memoria Companion que convenga simplificar campo por campo.

| Tabla/familia | Campos y propósito |
|---|---|
| `solid_cache_entries` | `key`, `key_hash`: identidad de caché; `value`: payload; `byte_size`: tamaño/gestión; `created_at`: antigüedad; `id`: clave de fila |
| `solid_cable_messages` | `channel`, `channel_hash`: destino; `payload`: mensaje; `created_at`: retención/orden; `id`: clave de fila |
| `solid_queue_jobs` | `active_job_id`, `class_name`, `arguments`: trabajo y payload; `queue_name`, `priority`, `scheduled_at`: despacho; `concurrency_key`: exclusión; `finished_at`, `created_at`, `updated_at`: lifecycle; `id`: clave de fila |
| `solid_queue_*_executions` | `job_id`: vínculo al trabajo; `queue_name`, `priority`, `scheduled_at`, `expires_at`, `concurrency_key`: despacho/bloqueo según tabla; `process_id`: worker reclamante; `error`: fallo; `task_key`, `run_at`: ejecución recurrente; `created_at`, `id`: identificación/retención |
| `solid_queue_processes` | `kind`, `name`, `pid`, `hostname`, `supervisor_id`: procesos; `last_heartbeat_at`: vida; `metadata`: detalles; timestamps/id: identificación |
| `solid_queue_pauses` | `queue_name`: cola detenida; `created_at`, `id`: registro |
| `solid_queue_recurring_tasks` | `key`, `schedule`, `static`: definición; `class_name`, `arguments`, `command`: acción; `queue_name`, `priority`: despacho; `description`: descripción; timestamps/id: lifecycle |
| `solid_queue_semaphores` | `key`, `value`, `expires_at`: control de concurrencia; timestamps/id: lifecycle |

Para reset: localizar los jobs de ese workspace y verificar ownership, no vaciar estas tablas. Los nombres de caché documental están centralizados en `DocumentOverviewCache` y `SectionNeighborExpander`; no reconstruir sus claves manualmente.

## Anexo C. Archivos disponibles para esta revisión
Listado de archivos recuperados del snapshot. Recuperado no significa que cada línea histórica se haya evaluado; el alcance de lectura dirigida está descrito en sección 2.
- `AGENTS.md`
- `app/AGENTS.md`
- `app/controllers/concerns/rag_query_concern.rb`
- `app/controllers/home_controller.rb`
- `app/controllers/pinned_documents_controller.rb`
- `app/controllers/rag_controller.rb`
- `app/javascript/controllers/rag_chat_controller.js`
- `app/jobs/bedrock_ingestion_job.rb`
- `app/jobs/field_photo_analysis_job.rb`
- `app/models/account.rb`
- `app/models/bedrock_daily_cost.rb`
- `app/models/bedrock_kb_chunk.rb`
- `app/models/bedrock_query.rb`
- `app/models/bulk_upload.rb`
- `app/models/bulk_upload_asset.rb`
- `app/models/client_database.rb`
- `app/models/conversation_session.rb`
- `app/models/cost_metric.rb`
- `app/models/field_photo.rb`
- `app/models/kb_document.rb`
- `app/models/knowledge_scope_change.rb`
- `app/models/pilot_event.rb`
- `app/models/technician_document.rb`
- `app/models/web_manual_batch.rb`
- `app/services/bedrock_client.rb`
- `app/services/bedrock_rag_service.rb`
- `app/services/field_photo_observation.rb`
- `app/services/field_photo_pending_image_store.rb`
- `app/services/field_photo_store.rb`
- `app/services/query_orchestrator_service.rb`
- `app/services/rag/AGENTS.md`
- `app/services/rag/active_episode.rb`
- `app/services/rag/active_episode_turn.rb`
- `app/services/rag/active_photo_context.rb`
- `app/services/rag/companion_guidance_context.rb`
- `app/services/rag/context_projection.rb`
- `app/services/rag/document_overview_cache.rb`
- `app/services/rag/episode_scope_flag.rb`
- `app/services/rag/episode_thread_resolver.rb`
- `app/services/rag/field_companion_episode_flag.rb`
- `app/services/rag/field_companion_turn_flag.rb`
- `app/services/rag/followup_query_rewriter.rb`
- `app/services/rag/grounded_synthesis_flag.rb`
- `app/services/rag/haiku_query_analysis_flag.rb`
- `app/services/rag/knowledge_scope_policy.rb`
- `app/services/rag/pending_question.rb`
- `app/services/rag/phase1_pinned_turn.rb`
- `app/services/rag/phase2_pinned_turn.rb`
- `app/services/rag/phase3_pinned_turn.rb`
- `app/services/rag/photo_observation_continuity.rb`
- `app/services/rag/photo_retrieval_snapshot.rb`
- `app/services/rag/section_neighbor_expander.rb`
- `app/services/rag/thread_menu_flag.rb`
- `app/services/rag/turn_interpreter.rb`
- `app/services/rag/turn_perception.rb`
- `app/services/rag/validation_capture.rb`
- `app/services/rag/work_context_reducer.rb`
- `app/services/session_context_builder.rb`
- `config/database.yml`
- `config/initializers/shared_session.rb`
- `config/routes.rb`
- `db/cable_schema.rb`
- `db/cache_schema.rb`
- `db/queue_schema.rb`
- `db/schema.rb`
- `docs/ACTIVE_ARCHITECTURE.md`
- `docs/INGESTION_ROUTING.md`
- `docs/MASTER_PLAN_FIELD_COMPANION_EVIDENCE_INTENT_EPISTEMICS_2026-10-05.md`
- `docs/METRICS.md`
- `docs/MULTI_TENANT_ARCHITECTURE.md`
- `docs/PILOT_TRACEABILITY.md`
- `docs/PLAN_FIELD_COMPANION_CONVERSACION_2026-10-07.md`
- `docs/PLAN_FIELD_COMPANION_DOCUMENT_FOCUS_REFACTOR_2026-10-01.md`
- `docs/PLAN_MULTIMODAL_COMPANION_SAFE_RETRIEVAL_2026-10-02.md`
- `docs/PLAN_R1B_SESSION_CORRECTNESS_2026-09-30.md`
- `docs/PRODUCT_ROADMAP.md`
- `docs/QUERY_ORCHESTRATOR.md`
- `docs/README.md`
- `docs/SESSION_AND_RETRIEVAL.md`
- `docs/WEB_CUSTOM_CHUNKING.md`
- `lib/tasks/field_companion.rake`
- `test/models/conversation_session_case_boundary_test.rb`
- `test/models/conversation_session_document_focus_test.rb`
- `test/tasks/field_companion_reset_test.rb`
