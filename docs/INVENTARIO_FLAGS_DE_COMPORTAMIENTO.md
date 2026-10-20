# Inventario de flags de comportamiento

Catálogo de los controles que cambian una ruta, una capacidad o una degradación
de Danebo. La decisión de producto y el código vigente se registran por
separado. Este documento no enciende, apaga ni retira ningún control.

Fecha de lectura: 2026-10-20. SHA del código leído para este catálogo:
`700e60e1d70bb15d320f60a31affe56efcc196b5`.

Después de esa lectura, `c68d136` incorporó cambios de retracción de
observaciones y del cupo local en `bedrock_rag_service.rb`,
`local_pass_ledger.rb`, `observation_correction.rb`, `turn_perception.rb`,
`work_context_reducer.rb` y sus pruebas. Este catálogo no los describe.

## Decisión de producto, todavía no implementada

El Companion forma parte del producto por defecto. No es una capacidad
opcional y no tendrá un interruptor para deshabilitarlo. WhatsApp permanece
deshabilitado. Los controles de captura, presupuesto, reintentos, autorización
y protección de datos siguen siendo configurables.

Esa decisión no está aplicada en este SHA. Un arranque que solo carga el
código y el `.env` local no recorre el Companion. Encender a mano las
variables de una prueba no sustituye el comportamiento fijo. «Siempre activo»
tampoco significa encender a la vez modos excluyentes, experimentos
descartados o la sesión compartida.

## Cómo leer cada control

| Capa | Qué es |
|---|---|
| Default del código | Valor que usa el proceso si la variable no está |
| Configuración versionada | `config/deploy.yml.example`, `.env.sample`, CI, Dockerfile o una constante del repositorio. `config/deploy.yml` real no está en Git |
| Valor local observado | Asignación leída en `.env` el 2026-10-20, sin imprimir secretos y sin modificar el archivo |
| Valor desplegado | No comprobado. No se leyó el manifiesto de Kamal ni un proceso de producción |
| Pasada VF5+ | Entorno de proceso documentado en [field_companion/EJECUCION_FERMATOR_VF5_REABRE_SOLA_2026-10-20.md](field_companion/EJECUCION_FERMATOR_VF5_REABRE_SOLA_2026-10-20.md). Foreman arrancó con `bin/dev -e /dev/null`, así que ese proceso no cargó `.env`. No se reinició ni se releyó su entorno vivo |

La lectura «boot» significa que el valor queda congelado al cargar la clase o
el inicializador. Cambiar `.env` después no llega a ese proceso. La lectura
«request» vuelve a leer `ENV` en cada llamada.

Salvo que el control diga otra cosa, solo la cadena exacta `"true"` enciende
un flag booleano. `"1"`, `"TRUE"`, `"yes"` y el vacío quedan apagados.
Excepciones: `SHARED_SESSION_ENABLED` acepta `true` sin distinguir mayúsculas;
`QUERY_ROUTING_ENABLED` igual; `BEDROCK_RERANKER_ENABLED` igual; los kill
switches de default encendido usan distinto de `"false"`.

## Cobertura y límites

Se leyeron `AGENTS.md`, `README.md`, `docs/README.md`,
`docs/ACTIVE_ARCHITECTURE.md`, `docs/SESSION_AND_RETRIEVAL.md` y el estado
actual de [PLAN_FIELD_COMPANION_CONVERSACION_2026-10-07.md](PLAN_FIELD_COMPANION_CONVERSACION_2026-10-07.md).

La búsqueda estática recorrió `app/`, `config/`, `lib/`, `Dockerfile`,
`.github/workflows/ci.yml`, `Procfile.dev`, `.env.sample`,
`config/deploy.yml.example`, `config/credentials.example.yml`, `db/schema.rb`
y `config/routes.rb`. Incluyó módulos `*flag*`, lecturas de `ENV`, modos
`off` / `shadow` / `conditional` / `always` / `owner`, rutas comentadas y
columnas que autorizan un comportamiento. Los consumidores de los controles
del Companion se siguieron hasta la rama que publica o sustituye la respuesta.

Los scripts y las pruebas se usaron para localizar arneses y confirmaciones.
Un `ENV` que solo autoriza un script de reparación o una fase aislada no es un
interruptor del request web. Los planes históricos conservan sus propios
valores; no son este catálogo.

No se ejecutaron modelos, AWS, ingestas ni deploy. No se consultaron filas
vivas de `accounts.danebo_controlled` ni de `kb_documents.knowledge_scope`.
No se abrió `config/deploy.yml`. No se imprimieron secretos. La captura en
disco de la pasada VF5+ no se releyó: la evidencia de esa pasada es el
registro ya versionado.

`lib/tasks/kb.rake` imprime temperatura `0.3` cuando `BEDROCK_RAG_GENERATION_TEMPERATURE`
falta. `BedrockRagService::DEFAULT_RAG_CONFIG` usa `0.1`. Es un default de
presentación de la tarea, no del servicio.

## Índice

| Nombre | Clase | Default del código | Destino propuesto |
|---|---|---|---|
| `FIELD_COMPANION_EPISODE_ENABLED` | Companion | apagado | Integrar la grabación y retirar el flag |
| `FIELD_COMPANION_TURN_ENABLED` | Companion | apagado | Integrar la lectura del episodio y retirar el flag |
| `HAIKU_QUERY_ANALYSIS_MODE` | Companion | `off` | Dejar una sola ruta, `owner`, y retirar el modo |
| `DOCUMENT_IDENTITY_SCOPE_ENABLED` | Companion | apagado | Integrar la política de identidad conocida y retirar el flag |
| `RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE` | Companion | apagado | Fijar la forma de prompt de esa política |
| `RAG_EPISODE_SCOPE_ENABLED` | Companion | encendido | Conservar el comportamiento encendido y retirar el kill switch |
| `RAG_THREAD_MENU_ENABLED` | Companion | encendido | Conservar la resolución del hilo y retirar el kill switch |
| `SHARED_SESSION_ENABLED` | Canal, excluyente | apagado en código; `.env` local `true` | Conservar la sesión por usuario. La sesión compartida bloquea el Companion |
| `RAG_GROUNDED_SYNTHESIS_ENABLED` | Generación | apagado en código; plantilla de deploy `true` | Fijar gs-v1 tras unificar el default |
| `RAG_GROUNDED_SYNTHESIS_ACCOUNT_IDS` | Generación | lista vacía | Conservar vacío |
| `SHOW_RAG_SOURCES` | Presentación | apagado | Integrar la cita visible en la respuesta web |
| `PHOTO_QUESTION_RAG_ENABLED` | Companion, foto | apagado en código; `.env` local `true` | Integrar cuando la foto entre al recorrido vigente. Hoy no es el camino textual |
| `RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED` | Ruta excluyente | apagado | Retirar o dejar apagada. No es la ruta del Companion |
| `RAG_FAMILY_AMBIGUITY_GUARD_ENABLED` | Ruta excluyente | apagado | Sigue a la ruta estructurada |
| `RAG_EVIDENCE_SELECTOR_ENABLED` | Experimento | apagado | Retirar |
| `RAG_EVIDENCE_EXPANSION_ENABLED` | Experimento | apagado | Retirar |
| `RAG_EVIDENCE_CARDS_ENABLED` | Experimento | apagado | Retirar |
| `RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED` | Generación, legado | apagado | Conservar hasta cerrar el contrato de generación |
| `RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED` | Generación, legado | apagado | Conservar junto con el anterior |
| `RAG_AUTO_SCOPE_ENABLED` | Sin consumidores de la ruta | distinto de `false` | Retirar |
| `RAG_PAGE_PIN_ENABLED` | Sin consumidores de la ruta | apagado | Retirar |
| `HAIKU_EXPLICIT_RETRIEVE_OVERLAP` | Sin consumidores de la ruta | apagado | Retirar |
| `BEDROCK_RERANKER_ENABLED` | Experimento | apagado | Conservar apagado |
| `QUERY_ROUTING_ENABLED` | Legado | apagado | Conservar apagado |
| WhatsApp / Twilio | Canal | ruta desmontada | Seguir deshabilitado |
| `CERTIFIER_MODULE_ENABLED` | Módulo | apagado en código; `.env` local `true` | Conservar |
| `ACTIVITY_DASHBOARD_ENABLED` | Operación | apagado en código; `.env` local `true` | Conservar |
| `SHOW_USAGE_METRICS` | Operación | apagado | Conservar |
| `PILOT_AUDIT_CAPTURE` | Protección | apagado | Conservar |
| `PILOT_EVENTS_PERSIST` | Operación | encendido | Conservar |
| `RAG_LOCAL_PASS_GUARD` y topes | Operación, pasada local | desarmado | Conservar |
| `RAG_VALIDATION_CAPTURE_RUN` | Operación, pasada local | apagado | Conservar |
| `AWS_MAX_ATTEMPTS` | Operación | no fijado por la app | Conservar |
| `APPLY` y confirmaciones de tarea | Autorización | dry-run | Conservar |
| Ingesta visual / layout | Experimento de ingesta | apagado | Conservar apagado |
| `accounts.danebo_controlled` | Dato | `false` | Conservar |
| `kb_documents.knowledge_scope` | Dato | `tenant_private` | Conservar |

## Recorrido del Companion

La ruta vigente del recorrido textual, la que ejecutan los arneses de fase y
la que usó la pasada VF5+, es esta combinación: sesión web por usuario,
`HAIKU_QUERY_ANALYSIS_MODE=owner`, episodio y turno encendidos, y la política
de identidad cuando el equipo ya es conocido. Esa combinación no es el default
del código, no está en `.env` y no es la plantilla versionada de deploy, que
fija el modo `conditional` y no define episodio ni turno.

| Paso | Qué lo gobierna hoy | Arranque normal | Si falta el control | Comportamiento que debe quedar fijo |
|---|---|---|---|---|
| Identificar equipo | `owner` escribe el episodio con `TurnInterpreter`. `conditional` solo posee cambio y corrección. `off` usa reglas deterministas si el episodio ya se graba | No graba episodio | Sin episodio no hay identidad de caso | Grabar el episodio en la sesión web por usuario y percibir el turno con el intérprete |
| Obtener antecedentes | `FIELD_COMPANION_EPISODE_ENABLED` y `FIELD_COMPANION_TURN_ENABLED` juntos arman el bloque de problema. `RAG_EPISODE_SCOPE_ENABLED` elige la ventana de historial | No hay bloque de problema | El prompt de generación no recibe el estado del caso | Incluir el estado del caso en el contexto de generación |
| Ofrecer y seleccionar manual | `Rag::DocumentDiscovery` no tiene flag propio. El foco lo confirma el técnico. `start_clean_case` con `APPLY=true` exige episodio, turno, alcance, `owner` y sesión no compartida | La tarjeta puede ofrecerse igual | La ingesta con episodio apagado pincha como antes; con episodio encendido el pin automático exige el episodio vivo | La oferta y el foco del técnico siguen. El pin no lo elige la pregunta |
| Recuperar evidencia | Con identidad conocida, `DOCUMENT_IDENTITY_SCOPE_ENABLED` decide si hay Retrieve de generación | Identidad conocida cierra antes del Retrieve | Abstención `DATA_NOT_AVAILABLE` y cero citas | Ejecutar la política de compatibilidad y generar desde los fragmentos que aplican |
| Responder con citas | La generación cita si llegó a `retrieve_and_generate` o al generador de identidad. `SHOW_RAG_SOURCES` decide si el navegador conserva `[n]` y la lista | El navegador recibe la respuesta sin marcadores y con `citations: []` | El técnico no ve la cita aunque el modelo la haya escrito | Publicar la cita en la respuesta web |
| Conservar contexto | Episodio, turno y sesión no compartida. `RAG_THREAD_MENU_ENABLED` solo entra si el turno del episodio no se adueña del hilo | Historial de chat, sin `active_episode` | Otra sesión compartida, o el mismo chat sin caso | Una sesión por usuario y un caso que sobrevive a los turnos |
| Aplicar correcciones | En `owner`, `TurnPerception` y `RoutePolicy`. No depende de la bandera documental | Sin `owner` no corre el intérprete | Una corrección sin negación de slot pide qué dato corregir y no sustituye la observación | Sustituir el dato que el técnico corrigió dentro del mismo caso |
| Pedir configuración faltante | `RoutePolicy` y `TechnicalUnderstanding` publican la pregunta y no recuperan | Solo en la ruta `owner` o en la ruta determinista si el episodio se graba | El técnico recibe una repregunta en lugar del manual | Seguir pidiendo el dato que falta, sin saltar el manual cuando la identidad y el foco ya alcanzan |
| Resumir y verificar el caso | El episodio guardado es el estado. La respuesta solo lo resume si la generación corre | La abstención no resume | El caso puede quedar `active` con el foco puesto y la respuesta muda | El cierre del turno dice el estado del caso cuando el técnico lo pide |

Capacidades adicionales que el código ya tiene, con su propio control:

| Capacidad | Control | Estado frente al producto |
|---|---|---|
| Pregunta literal sobre una foto de campo | `PHOTO_QUESTION_RAG_ENABLED` | Código presente. El orden 4 del plan del 7 de octubre todavía no es este recorrido |
| Síntesis fundamentada gs-v1 | `RAG_GROUNDED_SYNTHESIS_ENABLED` | Plantilla de deploy encendida. Código y `.env` local apagados |
| Ruta estructurada de bornes y designadores | `RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED` | Ruta distinta. Los arneses de fase la exigen distinta de `true` |
| Menú de hilo corto | `RAG_THREAD_MENU_ENABLED` | Fallback cuando el episodio no posee el turno |
| Selector, expansión y tarjetas de evidencia | tres flags `RAG_EVIDENCE_*` | Experimento apagado en la plantilla de deploy |
| WhatsApp | ruta comentada | Deshabilitado |

Controles que siguen separados aunque el Companion quede fijo: captura de
auditoría, persistencia de `pilot_events`, cupo de pasada local, reintentos
AWS, retención de fotos y dictados, presupuesto de lotes, confirmación `APPLY`
de tareas que escriben, y el módulo certificador.

## Controles del Companion

### `FIELD_COMPANION_EPISODE_ENABLED`

| Campo | Información |
|---|---|
| Propósito | Permitir escribir `conversation_sessions.active_episode` |
| Qué controla | `ConversationSession#episode_recording?`: canal `web` y sesión no compartida. También el id de episodio que la ingesta captura antes de encolar |
| Valores | Exactamente `true` enciende. Cualquier otro valor apaga |
| Default real | Apagado |
| Encendido | `record_user_turn!` persiste episodio e historial en un mismo `UPDATE`. La respuesta y la foto posteriores comprueban `expected_episode_id` |
| Apagado | El turno solo escribe historial y devuelve `nil`. No hay caso, no hay dueño de foto y el pin automático de la ingesta sigue el camino anterior |
| Lectura | Request |
| Consumidores | `ConversationSession`, `SessionContextBuilder.field_problem_readable?`, `QueryOrchestratorService#upload_owner_episode_id`, `BedrockIngestionJob`, `Rag::ActiveEpisodeTurn` |
| Dependencias | `SHARED_SESSION_ENABLED` apagado y canal `web`. El turno legible exige además `FIELD_COMPANION_TURN_ENABLED` |
| Conflictos | Sesión compartida efectiva deja la grabación en falso aunque esta variable sea `true` |
| Configuración versionada | Ausente en `.env.sample` y en `config/deploy.yml.example` |
| Clasificación | Companion |
| Vigencia | Activo |
| Destino propuesto | Integrar la grabación en la sesión web por usuario y retirar el flag |
| Local observado | Ausente en `.env` |
| Desplegado | No comprobado |
| VF5+ | `true` en el prefijo del proceso |

### `FIELD_COMPANION_TURN_ENABLED`

| Campo | Información |
|---|---|
| Propósito | Meter el episodio en el texto del turno |
| Qué controla | `RagQueryConcern#episode_turn_owns_thread?` y, junto con el flag de episodio, el bloque «Active Field Problem» |
| Valores | Exactamente `true` enciende |
| Default real | Apagado. El comentario del módulo dice que la fase 1 no lo lee; el código actual sí lo lee cuando está encendido |
| Encendido | Si la decisión del episodio no es `no_episode` ni `skipped`, esa decisión compone la pregunta y el menú de hilo no corre |
| Apagado | El episodio puede haberse escrito y el request sigue con el rewriter y el menú de hilo. El prompt no recibe el problema de campo |
| Lectura | Request |
| Consumidores | `RagQueryConcern`, `SessionContextBuilder` |
| Dependencias | Episodio encendido, sesión no compartida, canal `web` |
| Conflictos | Episodio encendido y turno apagado guarda estado que la generación no lee |
| Configuración versionada | Ausente |
| Clasificación | Companion |
| Vigencia | Activo |
| Destino propuesto | Integrar la lectura del episodio y retirar el flag |
| Local observado | Ausente en `.env` |
| Desplegado | No comprobado |
| VF5+ | `true` en el prefijo del proceso |

### `HAIKU_QUERY_ANALYSIS_MODE`

| Campo | Información |
|---|---|
| Propósito | Elegir quién percibe el turno |
| Qué controla | Una sola ruta de percepción. Los modos son excluyentes |
| Valores | `off`, `shadow`, `conditional`, `always`, `owner`. Vacío, desconocido o ausente queda `off` y registra un aviso una vez |
| Default real | `off` |
| `off` | No llama a Haiku semántico. Si el episodio se graba, `ActiveEpisodeTurn` aplica reglas deterministas |
| `shadow` | `SemanticQueryAnalyzer.observe` llama y no escribe estado |
| `conditional` | Haiku posee solo `switch` y `correct` dentro de `ActiveEpisodeTurn#apply_owned_slice`. El resto sigue determinista. Es el valor de `config/deploy.yml.example` |
| `always` | El modo se acepta y no hay lector `always?`. Queda inerte, igual que documenta el comentario del módulo |
| `owner` | `ConversationSession#record_user_turn!` entra a `TurnInterpreter`, `TurnPerception`, `RoutePolicy` y `WorkContextReducer`. `SemanticQueryAnalyzer.observe` no llama. La foto asistente no reescribe el episodio por el camino de `apply_assistant` |
| Lectura | Request |
| Consumidores | `HaikuQueryAnalysisFlag`, `ConversationSession`, `ActiveEpisodeTurn`, `SemanticQueryAnalyzer`, `RagController` (resta el tiempo semántico solo en `conditional`) |
| Dependencias | El efecto de Companion exige episodio encendido. `owner` con episodio apagado no graba: `episode_recording?` falla antes |
| Conflictos | `conditional` y `owner` no conviven. La plantilla de deploy dice `conditional`. Los arneses y la pasada VF5+ exigen `owner`. `start_clean_case` con `APPLY=true` aborta si el modo efectivo no es `owner` |
| Configuración versionada | `config/deploy.yml.example`: `conditional`. `.env.sample` lo deja comentado con el mismo comentario |
| Clasificación | Companion |
| Vigencia | Activo. `always` no tiene efecto. `shadow` es observacional |
| Destino propuesto | Fijar la ruta `owner` del recorrido vigente y retirar el selector de modo. `conditional`, `shadow` y `always` salen con ese retiro |
| Local observado | Ausente en `.env`. Efectivo `off` en un proceso que cargue ese archivo |
| Desplegado | No comprobado. La plantilla versionada no demuestra el proceso real |
| VF5+ | `owner` |

### `DOCUMENT_IDENTITY_SCOPE_ENABLED`

| Campo | Información |
|---|---|
| Propósito | Aplicar la compatibilidad entre el equipo conocido y los fragmentos |
| Qué controla | `BedrockRagService#document_identity_scope_result` y `StructuredEvidenceRoute#scope_identity` |
| Valores | Exactamente `true` enciende |
| Default real | Apagado |
| Encendido | Con identidad conocida, hace Retrieve, etiqueta fragmentos y genera desde los aplicables. Sin fragmento compatible arma guía de Companion y no vuelve al Retrieve abierto. Identidad desconocida no entra a este cierre: sigue la referencia no confirmada |
| Apagado | Si la identidad es conocida o está malformada, cierra antes del Retrieve de generación. Publica `DATA_NOT_AVAILABLE`, que en español queda «Ese dato no aparece en los fragmentos de manual recuperados para esta consulta.» Citas vacías, `route_outcome` de abstención, `model_invoked` falso |
| Lectura | Request |
| Consumidores | `DocumentIdentityScopeFlag`, `DocumentIdentityScope.applicable?`, `BedrockRagService`, `StructuredEvidenceRoute` |
| Dependencias | Identidad resuelta desde el episodio o desde el argumento del turno. El foco no sustituye a la identidad. La política no lee `config/document_identities.yml` en el request |
| Conflictos | Identidad conocida y flag apagado impide la recuperación para generar. La ruta estructurada, si estuviera encendida, también entrega cero fragmentos y abstiene |
| Configuración versionada | `.env.sample` lo muestra comentado como `false`. No está en la plantilla de deploy |
| Clasificación | Companion |
| Vigencia | Activo |
| Destino propuesto | La política encendida queda fija para identidad conocida. Retirar el flag. El defecto del LED no es esta rama y no justifica dejar el flag |
| Local observado | Ausente en `.env` |
| Desplegado | No comprobado |
| VF5+ | No exportado. Efectivo apagado. Abstención demostrada en el registro de la pasada |

### `RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE`

| Campo | Información |
|---|---|
| Propósito | Partir el prompt de identidad conocida en mensaje system y mensaje user |
| Qué controla | `BedrockRagService#document_identity_system_role?` |
| Valores | Exactamente `1` parte el prompt. Otro valor deja un solo mensaje user |
| Default real | Apagado |
| Encendido | El bloque de contexto, la sesión y el pie de idioma pasan al user. El resto queda en system |
| Apagado | Un solo mensaje user. La generación de identidad conocida sigue disponible si el flag documental está encendido |
| Lectura | Request |
| Consumidores | `BedrockRagService`. Los arneses de fase 2 y 3 lo exigen en `1` |
| Dependencias | Solo corre cuando la generación de identidad conocida arma el prompt. Con el flag documental apagado esta variable no se alcanza |
| Conflictos | No es un segundo Companion. Cambiarla no abre el Retrieve que el flag documental cerró |
| Configuración versionada | Ausente |
| Clasificación | Companion, forma del prompt |
| Vigencia | Activo |
| Destino propuesto | Fijar una forma cuando la política de identidad quede fija. El arnés usa `1`. Este inventario no elige el texto del prompt |
| Local observado | Ausente |
| Desplegado | No comprobado |
| VF5+ | No exportado. La pasada no llegó a generación, así que no ejerció esta forma |

### `RAG_EPISODE_SCOPE_ENABLED`

| Campo | Información |
|---|---|
| Propósito | Kill switch del contexto de episodio que ya no elige el documento del Retrieve |
| Qué controla | La ventana `episode_prompt_history` y el bloque «Selection Turn» cuando el técnico nombra el pin |
| Valores | Distinto de `false` enciende. Ausente queda encendido |
| Default real | Encendido |
| Encendido | El historial inyectado sale del episodio. El turno que nombra el documento enfocado conserva el problema anterior y no pide un resumen general |
| Apagado | El historial vuelve a los tres turnos recientes. No se añade el bloque de selección. El Retrieve no hereda un documento por este flag: `inherit_episode_scope` ya devuelve vacío |
| Lectura | Request |
| Consumidores | `SessionContextBuilder`, `RagQueryConcern#merge_selection_intent`. `FieldCompanionCleanStart` lo exige encendido para `APPLY=true` |
| Dependencias | Hay episodio y foco para que el bloque de selección tenga contenido |
| Conflictos | Ninguno con la sesión por usuario |
| Configuración versionada | Ausente. El comentario del módulo dice que el Retrieve ya no hereda documento |
| Clasificación | Companion |
| Vigencia | Activo como kill switch. La herencia de URI que le dio nombre está sustituida |
| Destino propuesto | Dejar fijo el comportamiento encendido y retirar el kill switch |
| Local observado | Ausente. Efectivo encendido |
| Desplegado | No comprobado |
| VF5+ | `true` explícito |

### `RAG_THREAD_MENU_ENABLED`

| Campo | Información |
|---|---|
| Propósito | Kill switch para unir un turno corto a un hilo recuperable |
| Qué controla | `EpisodeThreadResolver`. El chat no publica un menú de botones |
| Valores | Distinto de `false` enciende |
| Default real | Encendido |
| Encendido | Un turno corto con un hilo recuperable se une a ese texto. Con varios, la aclaración sigue al hilo más reciente |
| Apagado | El turno corto sigue literal, sin esa unión |
| Lectura | Request |
| Consumidores | `EpisodeThreadResolver`, `RagQueryConcern#thread_menu_applicable?` |
| Dependencias | Si el turno del episodio posee el hilo, este resolver no corre |
| Conflictos | Con Companion fijo y decisión de episodio presente, este camino queda de respaldo para `no_episode` y `skipped` |
| Configuración versionada | Ausente |
| Clasificación | Companion |
| Vigencia | Activo |
| Destino propuesto | Conservar la unión del turno corto y retirar el kill switch |
| Local observado | Ausente. Efectivo encendido |
| Desplegado | No comprobado |
| VF5+ | No exportado. Efectivo encendido. El turno `owner` poseyó el hilo cuando la decisión no fue `no_episode` ni `skipped` |

### `SHARED_SESSION_ENABLED`, `SHARED_SESSION_IDENTIFIER`, `SHARED_SESSION_CHANNEL`

| Campo | Información |
|---|---|
| Propósito | Una sola sesión web para todos los usuarios, pensada como demo |
| Qué controla | `SharedSession::ENABLED`, el identificador y el canal. En test `ENABLED` queda falso aunque el entorno diga lo contrario |
| Valores | `true` en cualquier capitalización enciende. Identificador default `mvp-shared`. Canal default `web` |
| Default real | Apagado en el inicializador. El `.env` local observado lo enciende, con identificador `mvp-shared` y canal `shared` |
| Encendido | `HomeController` y `RagController` usan una sesión común. `episode_recording?` queda falso. `start_clean_case` aborta |
| Apagado | Una sesión por `user_id`, canal `web` |
| Lectura | Boot. El test lo fuerza a falso al cargar el inicializador |
| Consumidores | `config/initializers/shared_session.rb`, `HomeController`, `RagController`, `ConversationSession`, `SessionContextBuilder`, `FollowupQueryRewriter`, `EpisodeThreadResolver`, `WhatsappAnswerCache` |
| Dependencias | Reinicio de web y worker después de cambiarlo |
| Conflictos | Encendido impide el Companion aunque episodio y turno estén en `true` |
| Configuración versionada | Plantilla de deploy: `false`. `.env.sample` lo deja comentado. README histórico lo presentaba como modo MVP |
| Clasificación | Canal. Excluyente con el Companion |
| Vigencia | Activo |
| Destino propuesto | La sesión de producto es por usuario. Retirar el modo compartido, o dejarlo imposible de combinar con el Companion. No es un interruptor del Companion |
| Local observado | `true` / `mvp-shared` / `shared` |
| Desplegado | No comprobado. La plantilla dice `false` |
| VF5+ | `false` en el prefijo. El proceso no cargó el `.env` |

## Generación, citas y rutas excluyentes

### `RAG_GROUNDED_SYNTHESIS_ENABLED` y `RAG_GROUNDED_SYNTHESIS_ACCOUNT_IDS`

| Campo | Información |
|---|---|
| Propósito | Contrato de generación gs-v1 |
| Qué controla | Qué líneas del prompt `generation.txt` entran. La lista de cuentas, si tiene ids, restringe |
| Valores | Flag exactamente `true`. La lista es ids separados por coma. Lista vacía incluye toda cuenta, también `nil` |
| Default real | Flag apagado. Lista vacía |
| Encendido | Entran las líneas `GROUNDED_SYNTHESIS` y `FIELD_GUIDANCE` y salen las líneas estrictas marcadas para el otro contrato |
| Apagado | El prompt queda sin el bloque gs-v1 |
| Lectura | Request. En producción la plantilla se memoriza por combinación de flags |
| Consumidores | `GroundedSynthesisFlag`, `BedrockRagService`, `PhotoQuestionAnswerService`, `StructuredEvidenceRoute` |
| Dependencias | No sustituye la política de identidad. Con identidad conocida y flag documental apagado, gs-v1 no se alcanza |
| Conflictos | Una lista no vacía en producción contradice la decisión D13 citada en el ejemplo de deploy |
| Configuración versionada | Plantilla de deploy: flag `true`, lista omitida. `.env.sample` lo deja comentado |
| Clasificación | Generación |
| Vigencia | Activo |
| Destino propuesto | Fijar gs-v1 para toda cuenta y retirar el flag y el restrictor. Hoy el default del código y el `.env` local siguen apagados: retirarlo exige ese cambio, no solo la plantilla |
| Local observado | Ambos ausentes. Efectivo apagado |
| Desplegado | No comprobado |
| VF5+ | No exportado. No hubo `retrieve_and_generate` |

### `SHOW_RAG_SOURCES`

| Campo | Información |
|---|---|
| Propósito | Mostrar citas y marcadores `[n]` en el navegador |
| Qué controla | El JSON de `/rag/ask` y el valor Stimulus `show-sources` |
| Valores | Exactamente `true` |
| Default real | Apagado |
| Encendido | La respuesta conserva los marcadores y `citations` lleva las referencias |
| Apagado | El navegador recibe el texto sin marcadores y `citations: []`. El historial guardado usa `result.answer`, que puede conservar marcadores que la burbuja ya no muestra |
| Lectura | Request |
| Consumidores | `Rag::SourcesVisibility`, `RagController`, `home/index.html.erb`, `PhotoQuestionAnswerService` |
| Dependencias | Hay citas que mostrar. La abstención por identidad no produce citas |
| Conflictos | El recorrido pide respuesta con citas. El default y la plantilla de deploy las ocultan |
| Configuración versionada | Plantilla de deploy: `false`. Ausente en `.env.sample` |
| Clasificación | Presentación |
| Vigencia | Activo |
| Destino propuesto | Publicar marcadores y referencias como parte fija de la respuesta web y retirar el flag |
| Local observado | Ausente |
| Desplegado | No comprobado |

### `PHOTO_QUESTION_RAG_ENABLED`

| Campo | Información |
|---|---|
| Propósito | Responder la pregunta escrita junto a una foto, no solo describir la foto |
| Qué controla | `FieldPhotoAnalysisJob` y `PhotoQuestionAnswerService` |
| Valores | Exactamente `true` |
| Default real | Apagado en código |
| Encendido | Si hay pregunta, la foto no está vieja y las consecuencias del análisis lo permiten, corre un turno RAG anclado al componente detectado |
| Apagado | La foto queda en el diagnóstico visual. La pregunta literal no entra a ese servicio |
| Lectura | Request, en el job |
| Consumidores | `PhotoQuestionFlag`, `FieldPhotoAnalysisJob`, `PhotoQuestionAnswerService` |
| Dependencias | Puede usar gs-v1 si ese flag también está encendido. El episodio de la foto depende del flag de episodio |
| Conflictos | El `.env` local lo enciende. La plantilla de deploy lo deja en `false`. El plan operativo pone las fotos en el orden 4, después del caso del plano |
| Configuración versionada | Plantilla `false`. `.env.sample` no lo lista en el bloque leído; el ejemplo de deploy sí |
| Clasificación | Companion, capacidad de foto |
| Vigencia | Activo y fuera del recorrido textual vigente |
| Destino propuesto | Integrarlo al comportamiento normal cuando la foto entre al Companion. Retirarlo ahora encendería una capacidad que el orden de trabajo todavía no mide |
| Local observado | `true` |
| Desplegado | No comprobado |

### `RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED` y `RAG_FAMILY_AMBIGUITY_GUARD_ENABLED`

| Campo | Información |
|---|---|
| Propósito | Ruta local de evidencia para consultas de mapeo, designador o un solo documento pineado. El guard añade la ventana por familia |
| Qué controla | `StructuredEvidenceRoute.eligible?` y, dentro, el guard de ambigüedad |
| Valores | Cada uno exactamente `true` |
| Default real | Ambos apagados |
| Encendido | La ruta estructurada puede responder o abstener sin el `retrieve_and_generate` general. Con identidad conocida y alcance documental apagado, devuelve cero fragmentos y abstiene. El guard solo cambia esa ruta |
| Apagado | Esa ruta no es elegible. El guard no corre |
| Lectura | Request |
| Consumidores | `StructuredEvidenceRoute`, `AmbiguousModelResponder`, `RagController` no la selecciona por sí mismo: la elige el orquestador cuando el flag está encendido |
| Dependencias | Canal web, fuente `document`, URIs de foco, consulta no exhaustiva. El arnés de fase pide ambos distintos de `true` |
| Conflictos | Encenderla junto con el Companion de identidad abre otra ruta para el mismo pin. Son excluyentes |
| Configuración versionada | Plantilla de deploy: ruta `false`. El guard no está en la plantilla |
| Clasificación | Experimento de ruta |
| Vigencia | Activo y fuera de la ruta vigente del Companion |
| Destino propuesto | Conservar una sola ruta de respuesta. La vigente es la de identidad y generación. Esta ruta y su guard se retiran o quedan apagados |
| Local observado | Ambos ausentes |
| Desplegado | No comprobado |

### `RAG_EVIDENCE_SELECTOR_ENABLED`, `RAG_EVIDENCE_EXPANSION_ENABLED`, `RAG_EVIDENCE_CARDS_ENABLED`

| Campo | Información |
|---|---|
| Propósito | Rollout del selector de evidencia, de la expansión a páginas vecinas y de las tarjetas |
| Qué controla | `RagController` corre el selector y el expansor, y arma tarjetas, solo con el flag correspondiente |
| Valores | Exactamente `true` cada uno |
| Default real | Apagados |
| Encendido | Trabajo adicional sobre la respuesta. El selector no reemplaza por sí solo el modo de resolución |
| Apagado | Esa capa no corre |
| Lectura | Request |
| Consumidores | `RagController` |
| Dependencias | Independientes entre sí. La expansión sin selector no cambia el selector |
| Conflictos | No son la ruta `owner` ni la política de identidad |
| Configuración versionada | Plantilla de deploy: los tres `false` |
| Clasificación | Experimento |
| Vigencia | Activo como código apagado |
| Destino propuesto | Retirar. No forman la respuesta vigente del Companion |
| Local observado | Ausentes |
| Desplegado | No comprobado |

### `RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED` y `RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED`

| Campo | Información |
|---|---|
| Propósito | Contrato de atribución de citas y contrato de abstención parcial. El comentario de deploy pide encenderlos juntos |
| Qué controla | `CitationMarkerNormalizer`, `CitationAttributionGuard` y las líneas de abstención parcial del prompt |
| Valores | Exactamente `true` cada uno |
| Default real | Apagados. El comentario del código llama a ese estado el comportamiento de `dd0a421` |
| Encendido | Normaliza `[n]` y filtra atribuciones. El parcial cambia el prompt de generación |
| Apagado | Esos filtros no corren |
| Lectura | Request |
| Consumidores | `CitationMarkerNormalizer`, `CitationAttributionGuard`, `BedrockRagService` |
| Dependencias | Conviven con gs-v1 porque el prompt se memoriza por la tupla de los dos contratos y de la síntesis |
| Conflictos | La plantilla de deploy los deja en `false` y a gs-v1 en `true` |
| Configuración versionada | Plantilla: ambos `false` |
| Clasificación | Generación, legado de contrato |
| Vigencia | Activo |
| Destino propuesto | Conservarlos configurables hasta cerrar cuál contrato de generación queda. No son el interruptor del Companion |
| Local observado | Ausentes |
| Desplegado | No comprobado |

### `RAG_AUTO_SCOPE_ENABLED`, `RAG_PAGE_PIN_ENABLED`, `HAIKU_EXPLICIT_RETRIEVE_OVERLAP`

| Campo | Información |
|---|---|
| Propósito | Residuos de alcance automático, de pin por número de página y de reutilizar un Retrieve |
| Qué controla | Cada módulo expone `enabled?` o `decision`. Ningún request del `app/` los llama |
| Valores | Auto-scope: distinto de `false`. Page pin: exactamente `true`. Overlap: exactamente `1` |
| Default real | Auto-scope encendido en el lector muerto. Page pin y overlap apagados |
| Encendido | No cambia el Retrieve. `inherit_episode_scope` y `auto_scope_uris_from` devuelven vacío. Una pregunta no elige manual ni página |
| Apagado | Igual para el request |
| Lectura | Request, si alguien llamara al módulo |
| Consumidores | Solo su archivo y las pruebas. `PhotoQuestionFlag` menciona el auto-scope en un comentario |
| Dependencias | Ninguna efectiva |
| Conflictos | Un operador puede creer que encenderlos acota el manual |
| Configuración versionada | Ausentes |
| Clasificación | Legado, sin consumidores de ruta |
| Vigencia | Sustituido |
| Destino propuesto | Retirar las variables y los módulos |
| Local observado | Ausentes |
| Desplegado | No comprobado |

### `BEDROCK_RERANKER_ENABLED`

| Campo | Información |
|---|---|
| Propósito | Rerank Cohere en consultas exhaustivas |
| Qué controla | `BedrockRagService#reranking_config`. Las consultas focalizadas no lo usan aunque esté encendido |
| Valores | `true` en cualquier capitalización, y además consulta exhaustiva |
| Default real | Apagado |
| Encendido | Añade `cohere.rerank-v3-5:0` y un número de resultados rerankeados |
| Apagado | Sin esa configuración |
| Lectura | Request |
| Consumidores | `BedrockRagService`. Los arneses Gate 9 fallan el preflight si está encendido |
| Dependencias | Modelo Cohere en la región. El benchmark de 2026-06-09 lo dejó apagado por regresión de recall |
| Conflictos | Encenderlo cambia el conjunto que llega a generación |
| Configuración versionada | `.env.sample` comentado en `false`. No está en la plantilla de deploy |
| Clasificación | Experimento |
| Vigencia | Activo y mantenido apagado |
| Destino propuesto | Conservar apagado hasta un benchmark que lo autorice |
| Local observado | `false` |
| Desplegado | No comprobado |

### `QUERY_ROUTING_ENABLED`

| Campo | Información |
|---|---|
| Propósito | Clasificar la pregunta hacia base de negocio, conocimiento o híbrido |
| Qué controla | `QueryOrchestratorService.skip_routing?` |
| Valores | `true` en cualquier capitalización |
| Default real | Apagado |
| Encendido | Llama al clasificador y puede ejecutar SQL o una síntesis híbrida |
| Apagado | El request web sigue a RAG |
| Lectura | Request |
| Consumidores | `QueryOrchestratorService` |
| Dependencias | `Account#data_sources` no existe en el modelo actual. `rag_only_account?` queda verdadero y el enrutamiento sigue saltado aunque el flag esté encendido |
| Conflictos | Encenderlo no abre la base cliente mientras falte `data_sources` |
| Configuración versionada | Plantilla y `.env.sample`: `false` |
| Clasificación | Legado |
| Vigencia | Activo como código. El brazo de base no tiene columna |
| Destino propuesto | Conservar apagado. Retirar el brazo cuando se retire el código dormido |
| Local observado | `false` |
| Desplegado | No comprobado |

## Canal

### WhatsApp / Twilio

| Campo | Información |
|---|---|
| Propósito | Canal de mensajería |
| Qué controla | La ruta `POST /twilio/webhook` está comentada en `config/routes.rb`. Los jobs `ProcessWhatsappMediaJob` y `SendWhatsappReplyJob` siguen en el repositorio y no se encolan desde la ruta web |
| Valores | No hay un flag de producto que monte el webhook |
| Default real | Canal desmontado |
| `WA_FACETED_OUTPUT_ENABLED` | Dentro del job de respuesta. Default del código `true` si la variable falta. Solo corre si el job se ejecuta |
| `WA_PROCESSING_ACK_ENABLED` | Igual, default del código `true` |
| `WHATSAPP_CHANNEL_DISABLED` | Solo pruebas. Default `true` en `test/test_helper.rb`: salta las clases WhatsApp y Twilio |
| Lectura | La ruta es de boot. Los dos flags WA son del job |
| Dependencias | `TWILIO_ACCOUNT_SID` y `TWILIO_AUTH_TOKEN` son credenciales, no interruptores |
| Conflictos | Encender los flags WA no monta el webhook |
| Configuración versionada | `.env.sample` documenta el canal como dormido. CI no define el skip: el default de test lo apaga |
| Clasificación | Canal |
| Vigencia | Código conservado, canal inactivo |
| Destino propuesto | Seguir deshabilitado. Los flags WA se retiran con el canal o permanecen dormidos |
| Local observado | `WA_FACETED_OUTPUT_ENABLED=true`. El ack no está asignado. Hay credenciales Twilio en `.env`; no se reproducen |
| Desplegado | No comprobado |

### `CERTIFIER_MODULE_ENABLED`

| Campo | Información |
|---|---|
| Propósito | Módulo de informes de certificación |
| Qué controla | `CertifierModuleGuard` responde 404. La navegación lo oculta |
| Valores | Exactamente `true` |
| Default real | Apagado en código |
| Encendido | Los controladores del módulo responden |
| Apagado | 404 |
| Lectura | Request |
| Consumidores | `CertifierModuleFlag`, `CertifierModuleGuard`, layout |
| Dependencias | `STT_PROVIDER` y las claves del proveedor son operación de dictado, no este interruptor |
| Conflictos | No participa en el chat del Companion |
| Configuración versionada | Las rutas están montadas y el guard las cierra. La plantilla de deploy no define el flag |
| Clasificación | Módulo |
| Vigencia | Activo |
| Destino propuesto | Conservar el interruptor. No es el Companion |
| Local observado | `true` |
| Desplegado | No comprobado |

### `ACTIVITY_DASHBOARD_ENABLED` y `SHOW_USAGE_METRICS`

| Campo | Información |
|---|---|
| Propósito | Vista de volumen `/actividad` y pie interno de tokens y costo |
| Qué controla | `ActivityController` 404 y redirección desde `/dashboard`. El pie sale de `home/_chat_box.html.erb` |
| Valores | Exactamente `true` cada uno |
| Default real | Ambos apagados en código |
| Encendido | La vista de actividad responde. El pie muestra uso |
| Apagado | 404 en actividad. El pie no se renderiza |
| Lectura | Request |
| Consumidores | `ActivityDashboardFlag`, `ActivityController`, `DashboardController`, vista del chat |
| Dependencias | Hay filas de `BedrockQuery` para que el pie tenga números. No es una compuerta de privacidad del texto del técnico |
| Conflictos | El `.env` local enciende la actividad. La plantilla de deploy no la define |
| Configuración versionada | README y `.env.sample` documentan el pie como apagado |
| Clasificación | Operación |
| Vigencia | Activo |
| Destino propuesto | Conservar ambos. El pie sigue oculto en una demo de cliente |
| Local observado | Actividad `true`. Pie ausente, efectivo apagado |
| Desplegado | No comprobado |

### `DEV_TUNNEL_FALLBACK_ACCOUNT_SLUG`

| Campo | Información |
|---|---|
| Propósito | Elegir la cuenta cuando el host de development no está en `AccountHosts::DEVELOPMENT` |
| Qué controla | `AccountHostResolver`. En production el mapa ya es el de producción y este fallback no corre |
| Valores | Slug de `accounts.slug`. Vacío no resuelve |
| Default real | `nil` |
| Encendido | El host desconocido carga esa cuenta |
| Apagado | Host desconocido no resuelve cuenta |
| Lectura | Request, solo development |
| Consumidores | `AccountHostResolver` |
| Dependencias | La cuenta existe. `127.0.0.1` sigue el mapa y no usa este fallback: en development cae en `localhost` |
| Conflictos | Un slug distinto cambia de cuenta y, con ello, el catálogo visible |
| Configuración versionada | Ausente |
| Clasificación | Operación local |
| Vigencia | Activo |
| Destino propuesto | Conservar como escape de túnel y de host local. No es un flag del Companion |
| Local observado | Ausente en `.env` |
| Desplegado | No aplica: el código no lo consulta en production |
| VF5+ | `index-account-1` en el prefijo, para `index.localhost` |

### Rutas desmontadas sin variable

`resources :bulk_uploads` está comentada. El código de ZIP masivo permanece.
`MissionControl::Jobs` sigue montado en `/jobs` fuera de test. Su usuario y
clave son credenciales, con default de development `dev` / `dev` en el
inicializador.

## Operación, presupuesto, reintentos, autorización y protección

Estos controles permanecen configurables.

### `PILOT_AUDIT_CAPTURE`

| Campo | Información |
|---|---|
| Propósito | Incluir pregunta, consulta efectiva y respuesta en claro en `[TURN_EVIDENCE]` |
| Qué controla | `Rag::TurnEvidence`. No abre `ValidationCapture` |
| Valores | Exactamente `true` |
| Default real | Apagado. Sin él igual se registran los SHA |
| Encendido | El log lleva el texto del técnico |
| Apagado | El log lleva hashes y metadatos |
| Lectura | Request |
| Consumidores | `TurnEvidence` |
| Dependencias | Autorización de privacidad para dejar texto en logs de producción |
| Conflictos | No sustituye la captura de validación ni corrige una abstención |
| Configuración versionada | Plantilla de deploy: `false`, con el comentario de privacidad |
| Clasificación | Protección |
| Vigencia | Activo |
| Destino propuesto | Conservar |
| Local observado | Ausente |
| Desplegado | No comprobado |
| VF5+ | No formaba parte del prefijo publicado en el registro |

### `PILOT_EVENTS_PERSIST`

| Campo | Información |
|---|---|
| Propósito | Kill switch del `INSERT` en `pilot_events` |
| Qué controla | `PilotEventRecorder.persist_enabled?` |
| Valores | Distinto de `false` persiste |
| Default real | Persiste |
| Encendido | Un insert en el mismo ciclo del log. Un fallo no llega al técnico |
| Apagado | No inserta |
| Lectura | Request |
| Consumidores | `PilotEventRecorder` |
| Dependencias | No es la compuerta de texto en claro. Esa es `PILOT_AUDIT_CAPTURE` |
| Conflictos | Ninguno con el Companion |
| Configuración versionada | Plantilla: `true` |
| Clasificación | Operación |
| Vigencia | Activo |
| Destino propuesto | Conservar |
| Local observado | Ausente. Efectivo encendido |
| Desplegado | No comprobado |

### `RAG_LOCAL_PASS_GUARD`, `RAG_LOCAL_PASS_CALL_CAP`, `RAG_LOCAL_PASS_COST_CAP_USD`

| Campo | Información |
|---|---|
| Propósito | Techo de una pasada local explícita |
| Qué controla | `Rag::LocalPassLedger`. No reemplaza `Stage2RunBudget` |
| Valores | Guard exactamente `1`. Tope de llamadas entero. Tope de costo decimal. Además `AWS_MAX_ATTEMPTS=1` y base local |
| Default real | Guard ausente: la llamada sigue y no se cuenta |
| Encendido incompleto | `Stop` antes del SDK y nombra el requisito que falta. `Stop` no es `StandardError` |
| Apagado | Sin cupo de esta clase |
| Lectura | Request, estado en el proceso |
| Consumidores | `LocalPassLedger`, `WebRequestCapture` si el guard fue pedido |
| Dependencias | Precio de `BedrockQuery`. Un `Retrieve` puro no entra en este cupo |
| Conflictos | Un proceso de test borra estas variables al empezar para no heredar el guard |
| Configuración versionada | Ausente |
| Clasificación | Operación de pasada local |
| Vigencia | Activo |
| Destino propuesto | Conservar |
| Local observado | Ausentes |
| Desplegado | No es un control de producción |
| VF5+ | Guard `1`, 24 llamadas, US$1. La pasada usó 7 llamadas de intérprete y US$0,021354 |

### `RAG_VALIDATION_CAPTURE_RUN`

| Campo | Información |
|---|---|
| Propósito | Abrir `ValidationCapture` en el request que pinta el navegador |
| Qué controla | `WebRequestCapture`. El id debe cumplir el patrón de 1 a 81 caracteres seguros |
| Valores | Id presente y proceso con base local |
| Default real | Apagado |
| Encendido | Escribe `tmp/field_companion/validation_captures/<run>/<request>/` |
| Apagado | El request no exporta esa captura. `PILOT_AUDIT_CAPTURE` no la abre |
| Lectura | Request. El cubo es del hilo. El worker de Solid Queue no lo hereda |
| Consumidores | `WebRequestCapture` |
| Dependencias | `LocalPassLedger.local_process?` |
| Conflictos | No es telemetría de producción |
| Configuración versionada | Ausente |
| Clasificación | Operación de pasada local |
| Vigencia | Activo |
| Destino propuesto | Conservar |
| Local observado | Ausente |
| VF5+ | `vf5-reabre-20261020T0238Z` |

### `AWS_MAX_ATTEMPTS`

| Campo | Información |
|---|---|
| Propósito | Tope de reintentos del SDK en el proceso |
| Qué controla | El ledger local lo exige en `1`. Los clientes que arma la app no siempre lo copian: `build_aws_client_options` no escribe `max_attempts`. El cliente `converse` fija sus propios intentos |
| Valores | El ledger solo acepta `1` |
| Default real | No lo fija la aplicación. El SDK usa su default |
| Lectura | Request para el ledger. Boot para un cliente ya construido |
| Consumidores | `LocalPassLedger`, arneses de fase, `Phase4WebCheck` |
| Dependencias | No sustituye un reintento de Aurora ya codificado en el servicio |
| Conflictos | Exportarlo no convierte por sí solo todos los clientes a un intento |
| Configuración versionada | Ausente |
| Clasificación | Operación |
| Vigencia | Activo donde el ledger o el arnés lo leen |
| Destino propuesto | Conservar como control de la pasada. Un cambio de reintentos de producto es otro encargo |
| Local observado | Ausente |
| VF5+ | `1` |

### `PHASE4_WEB_CHECK` y autorizaciones de arnés

`PHASE4_WEB_CHECK=1` registra un `after_initialize` que aborta el boot si el
contrato aislado no cierra. Development y production habituales no lo cargan.
El comentario exige que no esté en `.env`. Local observado: ausente.

Estas variables autorizan un arnés o una reparación. El request web normal no
las lee. Default: ausentes, y el arnés se niega.

| Nombre | Efecto si no es el valor exigido |
|---|---|
| `PHASE1_PINNED_TURN_AUTHORIZED=1` | El arnés de fase 1 no corre |
| `PHASE2_PINNED_TURN_AUTHORIZED=1` | Igual para fase 2 |
| `PHASE2_ATTRIBUTION_GENERATION_AUTHORIZED` | La generación de atribución de fase 2 no corre |
| `PHASE3_PINNED_TURN_AUTHORIZED=1` | Fase 3 no corre |
| `PHASE3_SUMMARY_GENERATION_AUTHORIZED` | El replay de resumen no corre |
| `PHASE5_GENERATION_REPLAY_AUTHORIZED` | El replay de fase 5 no corre |
| `DIRECT_SENTENCE_ABLATION_AUTHORIZED` | El arnés de ablación no corre |
| `LABEL_COMPARISON_VARIANT_AUTHORIZED` | La variante de comparación no corre |
| `RAG_PAGE5_BOTONERA_BRANCH_CONFIRM` | El reparador de la página 5 no escribe |
| `APPLY=true` | `field_companion:start_clean_case`, `field_companion:reset_active_episode` y `knowledge_scope:*` quedan en dry-run |
| `FORCE_PURGE_QUEUE` | `solid_queue:purge_all` se niega fuera de development/test |
| `CLEAN_BULK_UPLOADS` | La purga no borra filas `BulkUpload` |
| `FIELD_COMPANION_CLEAN_START_COPY_DIR` | Directorio de la copia. Default `tmp/field_companion/clean_starts` |

`Rag::InterpreterAnthropicExperiment::LIVE_CALLS_ENABLED` es la constante
`false`. No hay variable que abra esas llamadas. `Stage2RunBudget::PASS_CALL_CAP`
es `0`: ese techo cerrado no abre llamadas. No es el cupo de `LocalPassLedger`.

Destino: conservar las autorizaciones de arnés y de tareas que escriben.
Retirarlas no forma parte de dejar el Companion siempre activo.

### Ingesta

Todos apagados salvo la cadena exacta `true`. No cambian el chat.

| Nombre | Efecto encendido | Destino |
|---|---|---|
| `INGESTION_LAYOUT_DIGEST_ENABLED` | Digest de layout y aristas T1 en el chunk | Conservar apagado. El plan visual lo dejó así |
| `INGESTION_VISION_TIER_ENABLED` | Raster y llamada de visión en la ingesta | Conservar apagado hasta otra decisión |
| `INGESTION_VISION_TIER_RELATIONS_ENABLED` | La visión puede afirmar relaciones. Gate B lo dejó apagado | Conservar apagado |
| `INGESTION_VISION_TIER_ZOOM_TILES` | Teselas de 300 dpi. La medición lo refutó | Conservar apagado |
| `INGESTION_VISUAL_TRIAGE_ENABLED` | Campos extra de triaje en el lote Haiku y otra ruta de página | Conservar apagado |
| `INGESTION_REENQUEUE` | `BedrockIngestionJob` puede reencolar. Default del código `false` | Conservar. Plantilla y `.env` local: `true` |

### Retención y umbrales operativos

No eligen una ruta del Companion. Siguen configurables.

| Nombre | Default del código | Efecto |
|---|---|---|
| `FIELD_PHOTO_RETENTION_DAYS` | 90 | El job borra foto y miniatura más viejas |
| `PHOTO_PENDING_IMAGE_TTL_MINUTES` | 10 | Vida de la imagen pendiente de la pregunta |
| `VOICE_DICTATION_RETENTION_DAYS` | el default del job | Borra audio de dictados terminales |
| `STT_STALE_CLAIM_MINUTES` | el default del modelo | Reclama un dictado colgado en `transcribing` |
| `STT_POLL_TIMEOUT_SECONDS` | el default del adaptador Amazon | Abandona un job de Transcribe |
| `STT_PROVIDER` | `groq` en el cliente | `groq`, `openai` o `amazon_transcribe`. Sin failover automático |
| `SESSION_MAX_ENTITIES` | 10 | Tope de entidades de la sesión. Se lee al cargar el modelo |
| `WEB_SYNC_PDF_PAGE_THRESHOLD` | el tope del pipeline | A partir de ahí el PDF web va a lote |
| `WEB_URGENT_TRIAGE_PAGES` | el default del selector | Páginas del triaje urgente |
| `WEB_MANUAL_BATCH_SUBMITTING_TIMEOUT` | 30 minutos | Un lote atascado en submitting se reconcilia |
| `INGESTION_BATCH_TARGET_MB` | documentado 50 | Tamaño crudo del grupo Anthropic |
| `INGESTION_MAX_BATCH_PAYLOAD_MB` | documentado 150 | Tope antes de serializar |
| `INGESTION_BATCH_MAX_REQUESTS` | documentado 100 | Tope de requests del lote |

`FieldPhotoDensityGate::LARGE_PHOTO_THRESHOLD` es una constante de 1_500_000
bytes. Elige el símbolo de ruta de la foto. No es una variable.

`AI_PROVIDER` default `bedrock`. Otro valor cambia el proveedor del
orquestador. Local observado: `bedrock`. Es selección de proveedor, no un
flag del Companion.

## Datos que autorizan comportamiento

No son variables de entorno. No se leyeron filas vivas.

| Control | Default de esquema | Efecto |
|---|---|---|
| `accounts.danebo_controlled` | `false` | Marca de cuenta origen exigida antes de promover un documento a `danebo_general`. El slug no la pone. La tarea `knowledge_scope:mark_account` la escribe con `APPLY=true` |
| `kb_documents.knowledge_scope` | `tenant_private` | `tenant_private` o `danebo_general`. `KnowledgeScopeChange.apply!` es el escritor y agrega `knowledge_scope_changes` |
| `accounts.branded` | `false` | Marca de presentación del host. No autoriza un pin ni un corpus |

`Account` no define `bedrock_config` ni `data_sources`. Las ramas que los
llaman con `respond_to?` no tienen fila que leer. `BedrockRagService` resuelve
el id de KB por entorno y credenciales.

## Parámetros que no son interruptores

Modelos, buckets, ids de base, región, claves, nombres de base y timeouts
HTTP son dependencias. El inventario no los trata como flags. Los lee
`BedrockClient`, `AwsClientInitializer`, `config/database.yml` y
`.env.sample`.

`BEDROCK_MODEL_ID` está asignado en `.env`. El valor no se copia aquí.
`BEDROCK_VISION_MODEL_ID` también está asignado y no tiene lector en `app/`.
`KbDocument::KB_BUCKET` y `BedrockClient::QUERY_MODEL_ID` se congelan al
cargar la clase: el bucket del `.env` y el bucket exportado después no son el
mismo objeto si el proceso ya arrancó.

La plantilla de deploy fija el modelo
`global.anthropic.claude-haiku-4-5-20251001-v1:0` y el embedding Titan v2.
Eso es la plantilla, no una lectura del deploy real.

## Impactos

### Demostrado

La pasada de [EJECUCION_FERMATOR_VF5_REABRE_SOLA_2026-10-20.md](field_companion/EJECUCION_FERMATOR_VF5_REABRE_SOLA_2026-10-20.md)
recorrió los siete mensajes y la republicación del primero. SHA inicial de
esa pasada: `5ad6d38812d806ba72129d316b5f68e13b37c316`. Este inventario no la
repitió.

| Impacto | Configuración | Punto | Consecuencia | Recomendación mínima |
|---|---|---|---|---|
| Abstención con Fermator conocido | `DOCUMENT_IDENTITY_SCOPE_ENABLED` ausente. Episodio, turno y `owner` encendidos. Sesión compartida apagada | `BedrockRagService#document_identity_scope_result`, antes del Retrieve de generación | El técnico lee que el dato no está en los fragmentos. No hay citas ni `retrieve_and_generate`. El episodio sí guardó Fermator, VF5+, el operador y el síntoma | Quitar el cierre previo y aplicar la política de identidad sobre el manual enfocado |
| El caso y el foco sí se conservaron | Episodio y turno `true`, `owner`, sesión no compartida | `record_user_turn!` y el pin del técnico | Una sesión, un episodio y el manual 122 desde el clic hasta el turno 7 | Ese tramo ya es el comportamiento que debe quedar fijo |
| El LED no se sustituyó | La misma pasada. La bandera documental no participa en esta frase | Turno 4, correlación `query:82df46a4-8104-4038-8f58-7c22a17a6099` | La respuesta fue «¿Qué dato del equipo quieres corregir?». El episodio siguió con el LED apagado | Tratarlo en la percepción de la corrección. No encender el flag documental para darlo por resuelto |

La frase del LED es la clave `rag.clarify_correction_target`. `RoutePolicy`
la publica con `clarify_first` cuando la percepción queda `unclear` y el
objetivo es `correction_target`. Esa salida no llama al Retrieve. Es
independiente de `DOCUMENT_IDENTITY_SCOPE_ENABLED`.

### Confirmado por código

| Impacto | Configuración | Punto | Consecuencia | Recomendación mínima |
|---|---|---|---|---|
| El Companion no graba | Episodio distinto de `true`, o sesión compartida efectiva | `ConversationSession#episode_recording?` | El chat guarda historial y no abre caso | Fijar la grabación en la sesión por usuario |
| El estado no entra al prompt | Turno distinto de `true`, aunque el episodio se escriba | `SessionContextBuilder.field_problem_readable?` | La generación no ve el problema de campo | Fijar las dos lecturas juntas |
| Arranque local habitual | `.env` con `SHARED_SESSION_ENABLED=true` y sin episodio, turno ni modo | Boot de `SharedSession` y defaults de los otros tres | Aunque alguien exporte episodio y turno en un proceso ya arrancado, la sesión compartida sigue bloqueando. Un `bin/dev` nuevo carga el `.env` y deja el modo en `off` | El retiro de flags tiene que dejar de depender de ese archivo |
| Citas ocultas | `SHOW_RAG_SOURCES` distinto de `true` | `RagController`, armado del JSON | El navegador pierde `[n]` y la lista de citas | Publicarlas con la respuesta |
| Identidad desconocida | Flag documental apagado o encendido | `document_identity_scope_result` vuelve `nil` si la identidad no es conocida ni malformada | Sigue la referencia no confirmada. El flag no es el interruptor de ese tramo | Al fijar la política, conservar este tramo para equipo no confirmado |
| `conditional` no es `owner` | Plantilla de deploy | `ActiveEpisodeTurn#apply_owned_slice` | Haiku solo posee cambio y corrección. El intérprete no corre | No copiar `conditional` como si fuera el Companion vigente |
| Ruta estructurada | Flag de ruta `true` e identidad conocida con alcance apagado | `StructuredEvidenceRoute#scope_identity` | Cero fragmentos y abstención, por otra puerta | No encenderla para «completar» el Companion |
| Auto-scope y page pin | Cualquier valor | No hay llamada desde `app/` | El Retrieve no cambia | Retirar los módulos en el encargo de consolidación |
| WhatsApp | Webhook comentado | `config/routes.rb` | No entra mensajería | Dejarlo así |
| Clean start | `APPLY=true` sin la configuración de exclusión | `FieldCompanionCleanStart` | Abort. El dry-run sí imprime y no escribe | La herramienta de debug sigue exigiendo el contrato hasta que el contrato sea el default |

`TurnPerception#adjust_move` convierte un `correct` sin negación de slot en
`unclear` / `correction_target` y vacía identidades y observaciones, salvo
que `observation_correction?` lo acepte. Esa rama explica cómo una corrección
puede terminar en la pregunta del LED y dejar la observación anterior. El
payload exacto del intérprete del turno 4 no se releyó en este encargo.

### Hipótesis pendiente

| Hipótesis | Qué falta |
|---|---|
| El turno 4 de VF5+ entró por `correct_without_slot_negation` | Leer la captura ya escrita del request, sin nueva llamada. Este inventario no la abrió. `c68d136` cambió después la corrección de observaciones y no forma parte de esta lectura |
| El proceso desplegado usa la plantilla `conditional` y gs-v1 | Hace falta el `env.clear` efectivo de Kamal. No está en Git |
| Un `bin/dev` cargado hoy con `.env` deja sesión compartida y foto-pregunta encendidas | Hace falta mirar el proceso web vivo. No se inspeccionó para no tocarlo |
| Fijar `RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE=1` cambia la calidad de la respuesta de identidad | La pasada VF5+ no generó. Hace falta una respuesta real con la política encendida |
| El menú de hilo queda muerto cuando todo turno web tiene episodio | Comprobar turnos `no_episode` y `skipped` después de fijar la grabación |
| `SHOW_RAG_SOURCES` apagado ya ocultó citas en una respuesta que sí recuperó | La pasada VF5+ no recuperó para generar. El efecto está en el controlador y no en esa pasada |

## Destino de los flags

Esto no autoriza el cambio de código. Nombra el comportamiento fijo y el
bloqueo que el retiro tiene que resolver.

### Queda siempre disponible

En la sesión web de un usuario, sin sesión compartida:

1. Grabar el episodio y leerlo en el turno.
2. Percibir el turno con la ruta `owner`: intérprete, percepción, política de
   ruta y reductor de contexto.
3. Ofrecer manuales por descubrimiento y enfocar solo el que el técnico elige.
4. Con equipo conocido, aplicar la política de identidad, recuperar y generar.
   Sin fragmento compatible, seguir en guía de Companion y no abrir el corpus
   ajeno.
5. Con equipo desconocido, mantener la referencia no confirmada.
6. Publicar la respuesta con sus citas.
7. Conservar el caso entre turnos, aplicar la corrección que el técnico
   formuló, pedir el dato que falta y poder resumir el estado del caso.

gs-v1 queda como contrato de generación fijo cuando el default del código
alcance a la plantilla de deploy. Hoy no es el mismo valor.

La pregunta sobre una foto queda fuera de este paquete hasta el orden 4.
Su flag sigue siendo el interruptor de esa capacidad.

### Se retiran

| Flag o modo | Qué lo reemplaza | Bloqueo a resolver en ese cambio |
|---|---|---|
| `FIELD_COMPANION_EPISODE_ENABLED` | Grabación siempre en web por usuario | `start_clean_case` y las pruebas que hoy lo exportan |
| `FIELD_COMPANION_TURN_ENABLED` | El episodio entra siempre al turno | Igual |
| `HAIKU_QUERY_ANALYSIS_MODE` | Solo la ruta `owner` | La plantilla de deploy dice `conditional`. Hay que sustituir esa línea. `shadow`, `conditional` y `always` salen |
| `DOCUMENT_IDENTITY_SCOPE_ENABLED` | La política corre para identidad conocida | Es el cierre que produjo la abstención de VF5+. Retirarlo significa borrar ese `return` de abstención, no dejarlo «por si acaso» |
| `RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE` | Una sola forma de prompt | Elegir la forma `1` del arnés o la forma de un solo user, con una respuesta real de por medio |
| `RAG_EPISODE_SCOPE_ENABLED` | Ventana de episodio y bloque de selección fijos | Ningún defecto abierto lo bloquea |
| `RAG_THREAD_MENU_ENABLED` | La unión del turno corto queda | Comprobar el turno que todavía no abre episodio |
| `SHOW_RAG_SOURCES` | La burbuja muestra marcadores y referencias | Ningún defecto de VF5+ lo bloquea. El default actual las oculta |
| `RAG_AUTO_SCOPE_ENABLED`, `RAG_PAGE_PIN_ENABLED`, `HAIKU_EXPLICIT_RETRIEVE_OVERLAP` | Nada. Ya no tienen llamada | Borrar módulos y pruebas del lector |
| `RAG_EVIDENCE_SELECTOR_ENABLED`, `RAG_EVIDENCE_EXPANSION_ENABLED`, `RAG_EVIDENCE_CARDS_ENABLED` | Nada en la ruta vigente | Quitar la rama del controlador |
| `RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED`, `RAG_FAMILY_AMBIGUITY_GUARD_ENABLED` | La ruta de identidad y generación | No encenderlos como transición |

La corrección que no sustituye una observación, como el LED de VF5+, es un
defecto de `TurnPerception` / `RoutePolicy`. Retirar los flags no lo tapa.
Tampoco es motivo para conservar `DOCUMENT_IDENTITY_SCOPE_ENABLED`.

### Una sola ruta

| Par excluyente | Ruta que queda |
|---|---|
| `owner` / `conditional` / `shadow` / `off` / `always` | `owner` |
| Sesión compartida / sesión por usuario | Sesión por usuario |
| Política de identidad / abstención previa con identidad conocida | Política de identidad |
| Ruta estructurada / generación del Companion | Generación del Companion |
| WhatsApp / web | Web |

### Sigue configurable

Captura de auditoría, persistencia de eventos, cupo local, id de captura,
reintentos de la pasada, `APPLY` y confirmaciones de reparación, purga de
cola, retención, umbrales de lote, proveedor de dictado, módulo certificador,
tablero de actividad, pie de costo, reranker apagado, enrutamiento SQL
apagado, flags de ingesta visual apagados, `danebo_controlled` y
`knowledge_scope`.

### WhatsApp

Sigue deshabilitado. La ruta no se monta. Los flags `WA_*` no lo reactivan.

## Gaps

1. El valor desplegado de cada variable no está en el repositorio.
2. No se leyó el entorno de un proceso web vivo. El `.env` y el prefijo VF5+
   son dos configuraciones distintas.
3. No se releyó el JSON de captura del turno 4. La frase publicada y la rama
   de código coinciden; el payload del intérprete queda por confirmar en ese
   archivo.
4. No se consultaron filas de `danebo_controlled` ni de `knowledge_scope`.
5. `Account#bedrock_config` y `#data_sources` no existen. Cualquier override
   por cuenta que la documentación antigua nombre no tiene modelo.
6. `BEDROCK_VISION_MODEL_ID` está en `.env` y no tiene lector en `app/`.
7. `lib/tasks/kb.rake` muestra temperatura `0.3` cuando la variable falta. El
   servicio usa `0.1`.
8. La búsqueda de scripts históricos puede haber dejado un `ENV` de un
   reparador puntual fuera de la tabla de arneses. Esos scripts no montan una
   ruta del request. Si aparece otro lector en `app/` o `config/`, este
   catálogo está incompleto en ese punto.
9. Combinaciones no ejecutadas en esta lectura: `owner` con sesión compartida,
   identidad conocida con la política encendida en el recorrido VF5+, y
   gs-v1 junto con esa política. El código de cada una está citado arriba.
   Su resultado de producto no se volvió a medir.
10. `c68d136`, citado al inicio, puede cambiar la corrección de observaciones
    y el cupo de `retrieve_and_generate`. No se revisó como contrato y no
    sustituye este catálogo.
