# Plan de continuidad de sesión y follow-up — Cierre de precisión RAG (2026-09-21)

**Objetivo:** cerrar la pérdida de continuidad foto → respuesta corta a una pregunta discriminante, preservando evidencia, costo y la primera respuesta útil.
**Estado:** Fase 0 cerrada, medida el 21-sep-2026 (STOP técnico de B y del detector original); no se reabre. **CS-D01**, el mismo día, elige la conducta 2: la respuesta corta continúa la consulta técnica anterior. F1 cerrada el 21-sep-2026 sobre la rama A con el detector de §5.1, sin cambiar `generation.txt` ni subir los topes 160/200. Suite candidata: 3059 corridas, 0 fallos, 0 errores. Manifiesto SHA-256 `fd79df251eb79fc66aa8fe0caa2e4ac2e66afb086772bb6e071205312078da0f`. 0 R&G / 0 Retrieve / 0 visión. **CS-D02** (Lahiri, 21-sep-2026) orienta el ciclo separado de generación (§9.2) a la **respuesta de copiloto senior**, capaz de proponer una hipótesis de procedimiento desde los chunks ya ingeridos del mismo componente y función, separada de hechos citados y con descargo visible. Arranca después del cierre de F1, en otra sesión. Esa sesión cambia `generation.txt` y actualiza PRODUCT_ROADMAP y AGENTS para reflejar el contrato decidido; no abre un ciclo de ingesta. No se inventa aquí ningún procedimiento de resortes, vueltas, herramienta ni valores. Esta revisión agrega además la mecánica verificada del template dual de generación, del post-procesamiento determinista y de los tests pinneados que condicionan ese lever (§9.2.1), y su allowlist, base de evaluación y presupuesto (§9.2.2); F1 no cambia. **F1 cerrada. La sesión siguiente de continuidad ejecuta Anexo A.2; esta sesión no lo hace. A.G sigue prohibido en la sesión que cerró F1.** Gasto de F0: 0 R&G, 0 Retrieve, 0 visión. Manifiesto: SHA-256 de `tmp/continuidad_sesion_2026-09-21/fase_0/SHA256SUMS` = `3f5736b4d5e14a09620bde9c0f836e1d135089e921b7add47af4c5e143fc463c`.
**Entrada obligatoria:** §0.1; metodología `.cursor/rules/rag-precision-methodology.mdc`.
**Línea base:** `photo:ff0c3f27` respondió; `query:eb47da8f` produjo Sorry con evidencia y la copia D14. No es falta de fila de sesión.
**Decisiones del dueño incorporadas:** restricciones 1–15 de §0.2. Gonzalo = dueño de producto; Lahiri = operador del repo. **CS-D01** (Lahiri, 21-sep-2026): la respuesta corta continúa la consulta. **CS-D02** (Lahiri, 21-sep-2026): respuesta de copiloto con hipótesis de campo desde el conocimiento ya ingerido, descargo visible y hechos citados separados; lever de generación, sin efecto sobre F1. Ver §9.
**Código leído:** HEAD `ce6f8db33b8a2b1e6efe5331b8181fc51338648f`; imagen histórica `6ee694b`. No se presume igualdad entre HEAD y producción futura.

## 0. Guía de ejecución autónoma

### 0.1 Cómo leer el documento

1. Leer, en este orden: `AGENTS.md`, `CLAUDE.md`, `docs/README.md`, `docs/ACTIVE_ARCHITECTURE.md`, `docs/PRODUCT_ROADMAP.md`; después `app/AGENTS.md`, `app/services/rag/AGENTS.md`, `app/services/bedrock/AGENTS.md`, `app/prompts/AGENTS.md`, `test/AGENTS.md`; después `.cursor/rules/rag-precision-methodology.mdc`.
2. Leer `docs/PLAN_RAG_RAZONAMIENTO_TECNICO_2026-09-15.md` **solo como contexto cerrado D18**, especialmente B05; y `docs/BACKLOG_CONTRATO_GENERACION_GS_V1_2026-09-18.md` para detectar cruces, no implementarlos.
3. Leer este plan: §0 fija límites —incluidos §0.6 (qué quedó ya validado y qué se corrigió), §0.7 (canal y el segundo includer del concern) y §2.7 (de dónde sale el contexto)—; §1–2 son evidencia de arranque, **no el cierre de Fase 0**; §3 congela contratos; §4 describe exactamente cuatro fases; §5 determina la rama mediante medición. §6–9 y Anexo A son obligatorios para cada ejecución.
4. Ejecutar una fase por sesión. Empezar por su prompt de Anexo A. No saltar una fase bloqueada. La fase anterior debe haber rellenado el handoff con resultados y hashes reales; los campos declarados «pendiente de Fase…» son bloqueos de arranque, no libertad para inventar resultados.
5. Al cerrar: actualizar Estado, resultados/decisiones de este mismo documento y el prompt siguiente. No crear otro plan paralelo. Los datos voluminosos quedan en `tmp/continuidad_sesion_2026-09-21/fase_N/` con manifiesto SHA-256; no duplicar los logs históricos.

Este plan adapta la plantilla metodológica al número de fases pedido: holdout y gate están juntos en Fase 2; checkpoint, despliegue y humo en Fase 3. La separación diagnóstico/fix/holdout/deploy y el gate dual se conservan.

**Actualización CS-D02:** las cuatro fases anteriores siguen siendo exclusivamente el ciclo de continuidad. §9.2 y Anexo A.G describen otro ciclo dentro de este documento, sin sumar una rama ni una fase a F1. F0 y A.0 se conservan como registro histórico cerrado, no como instrucciones para repetir la medición. F1 está cerrada. El prompt de la sesión siguiente de continuidad es **A.2**. A.G no se ejecuta en la sesión que cerró F1: exige otra sesión. Quien ejecute A.G lee §9.2 completo —incluidas **§9.2.1** (mecánica del template dual y del post-procesamiento) y **§9.2.2** (allowlist, base compuesta, presupuesto)— antes de tocar el prompt.

### 0.2 Decisiones fijadas / restricciones no negociables

1. No reabrir `PLAN_RAG_RAZONAMIENTO_TECNICO` / D18. Ciclo cerrado.
2. No tocar `app/prompts/generation.txt`, flag gs-v1, `generation_temperature`, ni el protocolo `# NO MATCH`, salvo lever explícito + OK de Gonzalo. Default: NO tocar.
3. No extra LLM / no clasificador de ambigüedad (D1 del ciclo cerrado). Cualquier rewrite de follow-up tiene que ser **determinista** (Rails).
4. D10: ningún nombre de fabricante hardcodeado en prompt/código de producción. Catálogo/resolver/KB sí; literales "Yida"/"Fuji" en código/prod prompt no.
5. No inventar receta de amarre de 5 / "hitch of five". Sigue siendo límite de producto declarado en PRODUCT_ROADMAP hasta que un técnico con el conjunto real lo valide. Gonzalo.
6. No re-ingerir la nota `7cd6d699-e519-492f-aa35-4fb2dcfb53c9`. No escribir bajo `bulk_chunks/` salvo chunks reales de ingesta. No mintar otro `document_uid` de los mismos bytes.
7. No implementar el backlog de identidad web_v1 (dedup por sha) en este plan. Es otro documento.
8. No implementar ítems 1–6 de `BACKLOG_CONTRATO_GENERACION_GS_V1` salvo que Fase 0 demuestre que el defecto ES uno de esos ítems. Si hay cruce, el plan lo declara y para: no lo mezcla.
9. No WhatsApp. Canal único: web autenticada, móvil y escritorio por la misma ruta. Implicaciones de código en §0.7 — no es solo una restricción declarativa, porque el concern que tocan A/C/D lo incluye también el job dormido.
10. No gemas nuevas. No orquestación extra. No jobs nuevos salvo que el trabajo sea genuinamente largo.
11. Visión que ve "transformador" en el crop de resortes: ACEPTABLE. No "arreglar" el vision prompt por este caso.
12. Primera respuesta 13:49 (`photo:ff0c3f27`): BASELINE. El plan tiene un caso de no-regresión obligatorio sobre ese turno (misma foto sha `46de1a09…` + misma pregunta de resortes, sin follow-up) → sigue `answered`, no canned, no D14.
13. No commitear ni pushear a menos que Lahiri lo pida en la sesión de ejecución.
14. Minitest only. Todo cambio de comportamiento lleva test. Preferir tests unitarios rápidos del rewrite/sesión/canned; no system tests caros.
15. No re-correr la batería 17-sep de 52. Holdout nuevo, chico, escrito por una fase que NO implementó el fix.

Precisiones adicionales verificadas durante la redacción (16–27) y en la revisión del 21-sep que fijó la mecánica del lever (28–29):

16. El prompt protegido es **`app/prompts/bedrock/generation.txt`**, no `app/prompts/generation.txt`. SHA-256 local completo: `6a8abaed1e56bc880c7844f75288a7406973b9595c09e7fecafa928a473a789f`. Una divergencia de hash exige establecer su origen antes de medir; no restaurar ni editar a ciegas.
17. El cache está en **`app/services/field_photo_diagnosis_cache.rb`**; no existe el modelo indicado en el brief. Cache hit evita visión, **no** evita el RAG de la pregunta. TTL por defecto 24 h, configurable; registrar ENV efectiva.
18. `ConversationSession` y `session_id` de Bedrock son identidades distintas. `conversation_session_id` solo atribuye telemetría. No agregar persistencia de session_id de Bedrock como palanca encubierta.
19. Una coincidencia de marca en `KbDocumentResolver` no garantiza `candidate_uris`: el auto-scope requiere tokens específicos. Existe una lista `BRANDS` previa con nombres; no ampliarla ni copiarla para este fix. Resolver y catálogo existentes están permitidos; no agregar reglas especiales de una marca.
20. `MAX_CONTEXT_CHARS=2000` limita el bloque base. `Photo Evidence`, `Query Resolution` y `Selection Turn` se agregan después y hoy pueden superarlo. Medir base y contexto efectivo por separado; no declarar falsamente un cap global ya existente. Nuevas instrucciones no duplican bloques ni amplían el contexto sin presupuesto explícito (§3 C7).
21. No convertir `canned_with_retrieval` en prueba de citas válidas ni de ventana completa de R&G. Puede provenir del Retrieve fallback posterior. Guardar `evidence_mode`, fuente, página, hash y pertinencia por separado.
22. `interaction_completed.outcome=answered` **no demuestra C1**: el turno defectuoso de las 13:56 ya tiene ese outcome. El gate observa la respuesta visible, la copia localizada y el indicador canned.
23. No hacer `find_or_create_for`, `add_to_history`, pin/unpin, reset, update ni delete sobre session 6 en el diagnóstico. Replay sobre objetos locales aislados. No backfill masivo de conversaciones antiguas; los textos ya truncados no se recuperan subiendo una constante.
24. No aumentar `top_k`, no cambiar perfil/modelo/región, temperatura, flags ni retries de producción por conveniencia del experimento. Todo intento físico R&G, incluido retry, consume presupuesto. No calentamiento R&G gratuito.
25. El plan no autoriza hoy acceso a producción, deploy ni llamadas Bedrock: solo redacción. Durante la ejecución, el prompt de cada fase delimita acceso. Fase 3 requiere autorización de despliegue de Lahiri en esa sesión; commit/push requieren su instrucción explícita independiente. Criterio de contenido/safety y cambios al open-retrieval: Gonzalo.
26. Una discrepancia verificable entre estos supuestos y código/datos se documenta con `archivo:línea`, hash y efecto. No se resuelve inventando un contrato. Si altera las ramas cerradas o el gate, detener y presentar decisión concreta a Lahiri/Gonzalo según responsabilidad.
27. CS-D02 define el lever sobre `app/prompts/bedrock/generation.txt` para la respuesta de copiloto, exclusivamente en el ciclo separado §9.2. Las restricciones 2/5/16 siguen rigiendo F1–F3. En la sesión que implemente el lever se cambia la prohibición de completar procedimientos para admitir hipótesis desde chunks del mismo componente y función, y se actualizan PRODUCT_ROADMAP y AGENTS con esa distinción. Esas actualizaciones son entregables del ciclo, no una razón para descartar la intención de Lahiri. No implementar hoy ni ejecutar el lever en la sesión de F1. No hay lever de ingesta. Fase 0 y batería del 17-sep permanecen cerradas.
28. Alcance exacto de lo que el lever de CS-D02 **puede** tocar, verificado el 21-sep contra el código: solo líneas con prefijo `- GROUNDED_SYNTHESIS:` de `generation.txt`, más los documentos de §9.2. El protocolo `# NO MATCH` **no** se toca (un test vigente exige que sea idéntico en las dos variantes) y ninguna línea sin prefijo de variante se edita, porque pertenece también al contrato `strict-v1`. Detalle mecánico y citas en §9.2.1; allowlist cerrada en §9.2.2. Temperatura, flags, locales, retrieval y `top_k` quedan fuera del lever en cualquier caso.
29. La restricción 5 no se levanta. El amarre de cinco cables sigue sin receta validada. En el ciclo §9.2 puede existir una hipótesis de campo sobre ese caso **solo** con premisas pertinentes del mismo componente y función, dentro del bloque de hipótesis y con descargo visible; sin premisas es receta genérica y falla safety. Ni el prompt ni PRODUCT_ROADMAP pueden presentarla como procedimiento documentado o validado.

### 0.3 Glosario

| Término | Significado operativo |
|---|---|
| `canned_no_results` | El detector reconoce el Sorry nativo de Bedrock; no prueba por sí solo ausencia documental. |
| `canned_with_retrieval` | `canned_no_results && retrieved_for_extraction.any?`; evidencia observada nativa o fallback. |
| D14 | Decisión del ciclo cerrado cuya copia actual es `I18n.t("rag.generation_retry", locale: ...)`: pide fabricante/modelo/código/foto. |
| Pregunta discriminante | Pregunta del último assistant que solicita una identificación capaz de orientar la consulta técnica anterior. Aquí se estudia identificación de catálogo, no un clasificador universal de intenciones. |
| Episode scope | Herencia determinista de candidatos desde hasta 3 mensajes user de las últimas 4 h. No equivale a historia completa ni a memoria Bedrock. |
| Photo RAG | RAG posterior a visión/cache en `FieldPhotoAnalysisJob` → `Rag::PhotoQuestionAnswerService`; recibe contexto/pines, no `conv_session`. |
| Text RAG | `RagController#ask` → `execute_rag_query` con `conv_session`, luego orquestador y R&G. |
| Session 6 | Fila histórica de `ConversationSession`: account 3, user 7, identifier `"7"`, web; ventana móvil, no expediente navegable. |
| FieldPhoto 34 | Crop con SHA `46de1a09cb75729f4bf80dddc604cd3b4d06c4f556b48793774b0a4e89d007d5`; no confundir sus bytes con el JPEG sin recortar. |
| `correlation_id` | Une entrada, job, RAG, auditoría y métricas de un turno. Los prefijos abreviados de §1 se resuelven a UUID completo. |
| Dato de identificación | Declaración del usuario para buscar; no prueba de aplicabilidad de un procedimiento. |
| Holdout | Ocho casos congelados en §4.2 por el redactor, que no implementó el fix. No se usan para ajustar el fix ni se repiten tras gastar el gate. |

### 0.4 Acceso a producción (para el ejecutor, no para el redactor)

Leer `docs/PRODUCTION.md` y `script/AGENTS.md` antes de operar. **Override explícito de este plan:** la receta por stdin de `script/AGENTS.md` y del plan cerrado no se usa: `docker exec -i ... runner -` falló en este caso. Copiar el runner al host y después al contenedor con **`docker cp`**; ejecutar `bin/rails runner /tmp/archivo.rb` sin stdin.

Resolver host, usuario y clave desde la configuración local vigente `config/deploy.yml` (solo campos `servers.web` y `ssh`, sin imprimir secretos). Verificado el 21-sep que ese archivo declara `service: smart-deal`, `image: lahirisan80/smart-deal`, `servers.web`, `ssh.user: ubuntu` y `ssh.keys: ["~/.ssh/smart-deal-deploy.pem"]`, por lo que la receta de abajo es aplicable tal cual. La referencia histórica es `ubuntu@54.163.248.39`; no asumir IP vigente, resolverla del archivo. `docs/PRODUCTION.md` l.392 documenta además `kamal app exec --reuse 'bin/rails runner "…"'`, válido solo para una lectura de **una línea**; los cuatro runners de la lista cerrada son multilínea, así que para ellos `docker cp` sigue siendo obligatorio. Lahiri resuelve acceso/configuración ausentes. SSH puede requerir aprobación Auto-review: esperar el resultado; ante rechazo, informar acción y razón y pedir autorización si no hay vía permitida. No evadirlo cambiando de herramienta.

Secuencia operativa (variables `CONT_*` se rellenan con los valores verificados; nunca con secretos en el documento):

```bash
# Desde /Users/lahirisan/smart_deal; primero inspeccionar contenedores.
ssh -i "$CONT_SSH_KEY" "$CONT_SSH_TARGET" \
  "docker ps --filter label=service=smart-deal --filter label=role=web --filter status=running --format '{{.Names}} {{.Image}}'"
# CONT_WEB es el único smart-deal-web-* verificado; si hay dos, parar.
scp -i "$CONT_SSH_KEY" tmp/crop_photo_log_review.rb \
  "$CONT_SSH_TARGET:/tmp/continuidad_dump.rb"
ssh -i "$CONT_SSH_KEY" "$CONT_SSH_TARGET" \
  "docker cp /tmp/continuidad_dump.rb $CONT_WEB:/tmp/continuidad_dump.rb"
ssh -i "$CONT_SSH_KEY" "$CONT_SSH_TARGET" \
  "docker exec $CONT_WEB bin/rails runner /tmp/continuidad_dump.rb" \
  > tmp/continuidad_sesion_2026-09-21/fase_0/dump_actual.txt
```

Validar nombres/rutas antes de interpolarlos en shell. El runner histórico es read-only **respecto a DB/KB**; escribe `/tmp/crop_photo_log_review.json` en el contenedor. Su JSON **no exporta history** y su stdout la recorta a 180 caracteres. No usarlo como export íntegro. No alterar ese archivo histórico.

**Lista cerrada de runners permitidos al ejecutar las fases:**

| Runner | Dónde / efectos permitidos |
|---|---|
| `tmp/crop_photo_log_review.rb` existente | F0, contenedor web; SELECTs + dump local `/tmp`; cero Bedrock, cero mutaciones DB/KB. |
| `tmp/continuidad_sesion_2026-09-21/fase_0/export_session_6.rb` a escribir en F0 | Contenedor web: SELECT de session 6 con guard account=3/user=7, FieldPhoto 34, PilotEvent/BedrockQuery de los cuatro UUID de §1, catálogo account 3 con `select` de id/uid/nombre/aliases/s3_key/created_at. Export JSON completo de history y campos seleccionados, flags no secretos, hashes; sin crear sesión, sin SDK de generación. No listar otras cuentas. |
| `tmp/continuidad_sesion_2026-09-21/fase_0/replay.rb` a escribir en F0 | **Local**: reloj congelado, snapshots, stubs de escrituras/broadcast; intercepta argumentos de rutas reales. Sin AWS por defecto. `MODE=probe` habilita solo los controles de §4.0 y contador físico. Si se necesita IAM de EC2, únicamente el tramo Retrieve/R&G del control corre en web con argumentos serializados y hash, sin cargar código candidato. |
| `tmp/continuidad_sesion_2026-09-21/fase_2/holdout.rb` a escribir en F2 | Local sobre candidato de F1, clientes Bedrock con presupuesto; no copiar aplicación candidata al contenedor productivo. Puede usar credenciales de desarrollo autorizadas para account 3/KB de §1. Si no hay acceso, Lahiri habilita un entorno de evaluación aislado; no desplegar para sortear el gate. |
| `tmp/continuidad_sesion_2026-09-21/fase_3/smoke_readback.rb` a escribir en F3 | SELECTs de los dos correlation_id del flujo web autorizado; logs, flags, hashes, filas y tokens. No reenvía preguntas ni ejecuta jobs. |

Antes de cada runner nuevo: leer su fuente, registrar SHA local, verificar el mismo SHA tras `docker cp`, registrar imagen y ejecutarlo **una vez** en web. El export/probe no escribe history, pines, fuentes S3 ni caché diagnóstica. Las consultas reales pueden emitir telemetría normal R&G; no llamar «read-only total» a un probe facturado. Retrieve puro usa log, nunca `bedrock_queries`. Polling con `ActiveRecord::Base.uncached` y plazo finito. No scripts de ingesta, reparaciones, SQL arbitrario ni corridas antiguas.

### 0.5 Orden de lectura de código al ejecutar

1. `app/models/conversation_session.rb`; `app/services/session_context_builder.rb`; `app/services/rag/episode_scope_flag.rb`.
2. `app/controllers/rag_controller.rb`; `app/jobs/field_photo_analysis_job.rb`; `app/services/rag/photo_question_answer_service.rb`; `app/services/field_photo_diagnosis_cache.rb`.
3. `app/controllers/concerns/rag_query_concern.rb`; `app/services/kb_document_resolver.rb`; `app/services/rag_retrieval_profile.rb`; `app/services/query_orchestrator_service.rb`.
4. `app/services/bedrock_rag_service.rb`; `config/locales/rag.es.yml`; `config/locales/rag.en.yml`; `app/services/rag/answer_safety_processor.rb`; `app/services/rag/citation_attribution_guard.rb` (guards preservados).
5. Tests enumerados en §5.5; `test/architecture/no_hardcoded_equipment_test.rb`. Para costo, `app/services/anthropic_token_counter.rb` (`LocalTokenizer.estimate`, sin API).
6. Solo si el replay descubre un session_id Bedrock no nulo: seguir transporte real del request web y respuesta. No concluir continuidad Bedrock desde el id 6 ni modificar el frontend como solución implícita.
7. Antes de escribir una sola línea de rama A, C o D: §0.7 (canal y segundo includer del concern) y §5.1 «Mapa de consumidores de `question`». Un fix que reasigne la variable local `question` en el concern está fuera de contrato.

### 0.6 Resultado de la validación 21-sep-2026 (no repetir)

Ejecutada sobre HEAD `ce6f8db33b8a2b1e6efe5331b8181fc51338648f`, sin red, sin Bedrock, sin acceso productivo. El ejecutor **no necesita rehacer esta verificación**; sí debe reconfirmar HEAD y los cuatro hashes antes de medir (§4.0 paso 1).

| Verificado | Resultado |
|---|---|
| HEAD de cabecera | Coincide exactamente. |
| `app/prompts/bedrock/generation.txt` + 3 artefactos de §1 | Los cuatro SHA-256 se reprodujeron idénticos con `shasum -a 256`. |
| 24 citas de código con rango | Todas corresponden al contenido citado. Tres rangos en prosa estaban corridos y quedan corregidos abajo. |
| Rutas de tests de §5.5 | Las 11 existentes existen. Las 2 marcadas «nuevo» no existen, como corresponde. |
| `config/deploy.yml` | Tiene `service: smart-deal`, `image: lahirisan80/smart-deal`, `servers.web`, `ssh.user: ubuntu`, `ssh.keys: ["~/.ssh/smart-deal-deploy.pem"]`. La receta de §0.4 es aplicable. |

**Correcciones de rango aplicadas** (el rango citado quedaba corto o corrido; el contenido nunca cambió): ruta cache-hit `deliver_cached` → la llamada a `deliver` empieza en **l.210**, no en 215; `document_uids = documents.map { SecureRandom.uuid }` es la línea **148 sola**, no 148–154; la escritura del assistant de texto en el controller es **81–87** dentro del `if` de l.81, no 81–90.

**Hechos de código que el plan asumía sin declarar, y que cambian una medición:**

1. `KbDocumentResolver.candidates_for` aplica **dos** topes, no uno: `.limit(50)` en SQL (l.134) y `.first(20)` tras el post-filtro de frontera de palabra (l.141). H5 mide sobre 20 candidatos, no 50.
2. `MIN_TOKEN = 4` y `TOKEN_RE = /[\p{L}\d]{3,}/` (l.18–20, 99–107): `fuji` y `yida` tienen exactamente 4 caracteres, así que **sí** sobreviven a `scan_tokens` y llegan al SQL. Que no produzcan auto-scope es efecto de `specific_token?` (l.90–94) + `BRANDS` (l.37–39), no de un filtro de longitud. H5 debe distinguir esos dos motivos.
3. `ConversationSession::MAX_MSG_LENGTH` tiene un segundo consumidor fuera del historial: `FieldPhotoAnalysisService::CHAT_CONTEXT_LIMIT = ConversationSession::MAX_MSG_LENGTH` (l.9). Mover la constante cambia la compactación visual. Rama B no toca la constante (§5.2).
4. `SessionContextBuilder` aplica `truncate(200)` al último assistant **solo en la rama de episodio** (l.49). Con `RAG_EPISODE_SCOPE_ENABLED=false` el `else` de l.51 inyecta `recent_history_for_prompt(turns: 3)` sin recorte adicional: el assistant entra con sus 300 caracteres persistidos. F0 registra la ENV efectiva antes de afirmar «inyectado 200».
5. `test/architecture/no_hardcoded_equipment_test.rb` cubre `CORE_FILES = app/services/rag/*.rb + bedrock_rag_service.rb + rag_retrieval_profile.rb`. Alcance real para este plan en §4.1 paso 5.
6. `SharedSession::ENABLED` es `false` por defecto y `SharedSession::CHANNEL` es `"web"` (`config/initializers/shared_session.rb` l.9–11). Session 6 es `channel="web"`, coherente con shared apagado. F0 registra `SHARED_SESSION_ENABLED` efectivo porque el gate de §5.1 depende del canal.

### 0.7 Alcance de canal: web mobile + browser, y el segundo includer del concern

El único canal es la **aplicación web autenticada**, servida igual a navegador de escritorio y a navegador móvil: misma ruta Rails (`RagController#ask`), misma sesión (`channel: "web"`), mismo pipeline. No hay rama por user-agent, no hay endpoint móvil, y ningún fix de este plan puede introducir una. «Mobile» es responsive UX, no un canal.

WhatsApp está dormido y fuera de alcance (restricción 9). Eso no es sólo declarativo, porque `RagQueryConcern` —el archivo que tocan las ramas A, C y D— tiene **dos includers**: `RagController` (l.7) y `SendWhatsappReplyJob` (l.17). De ahí tres obligaciones:

1. Un gate nuevo en el concern debe ser **fail-closed por canal**, no por ausencia de imágenes: `images.empty? && documents.empty? && conv_session` también es verdadero en la ruta dormida. El predicado exacto está en §5.1.
2. El call site dormido pasa `whatsapp_to:` (job l.134 y l.160), kwarg que **no existe** en la firma vigente (l.50–53). Es una condición preexistente del canal dormido, verificada el 21-sep; los tests de ese job stubean el método, así que la suite no la ejerce. **No corregirla, no agregar el kwarg a la firma, no anotarla como regresión del candidato.** Tocarla es branch creep y dispara STOP.
3. Ningún archivo `*whatsapp*` ni `twilio*` entra en la allowlist de ninguna rama (§5.5).

## 1. Síntoma y evidencia ya medida

Cuenta `account_id=3`, `user_id=7`, `ConversationSession id=6`, identifier=user_id, sesión web larga. KB `Y7RZWMFJSR`; deploy histórico `6ee694b`; gs-v1 on; temperatura indicada 0.1 (F0 registra configuración efectiva sin cambiarla). El historial existe, cap 20 mensajes, truncado a 300 caracteres por mensaje. Turnos del 11-sep ya rotaron.

| Hora 18-sep-2026 (UTC−3) | Correlation ID completo | Input / observación | Clasificación de arranque |
|---|---|---|---|
| 13:49:25–44 | `photo:ff0c3f27-d614-4339-aa80-ec0593f1a784` | Foto crop + pregunta de resortes; RAG gs-v1, canned=false, `photo_question_answered=answered`. | **Baseline bueno**. No romper ni reabrir percepción. |
| 13:56:28–36 | `query:eb47da8f-d529-4e9a-a017-66479260c6ba` | `es Fuji Yida`, sin foto; `canned_with_retrieval=true`, citas visibles 0; D14. | **Defecto de continuidad**. `interaction_completed=answered` es falso proxy de éxito. |
| 13:57:20–28 | `query:fcaba5a2-dcb7-4609-a370-9fb53c4766cd` | `Cómo se ajustan los resortes de la fijación de cables ? es un Fuji Yida`. | Genera, pero mezcla traveling cable con ajuste de cuña/tensión. H6, distinto a demostrar en F0. |
| 13:58:11–22 | `photo:1b907984-cd8f-4fa5-8173-1094da6bf0af` | Mismo crop + `Cómo se ajustan los resortes de la fijación de cables ? es Fuji Yida`; cache visual hit. | Nuevo RAG; vuelve a traveling cable/CB5. H6, no prueba cache de respuesta RAG. |

**Precisión literal:** el brief transcribía «Cómo seajustan los resortes de la fijación de cables». El dump primario muestra **`Cómo se ajustan los resortes de la fijación de cables ?`** (55 caracteres), tanto history [10] como `BedrockQuery id=14432`. Ese literal es la reproducción principal; la transcripción del brief se conserva como variante offline, sin gastar otra llamada. No corregir silenciosamente espacios/puntuación en hashes.

Foto recortada: FieldPhoto `34`, sha256 `46de1a09cb75729f4bf80dddc604cd3b4d06c4f556b48793774b0a4e89d007d5`, filename `Screenshot 2026-09-16 at 3.56.05 PM.png`, S3 declarado `s3://danebo-kb-documents-dev/field_photos/3/46de1a09cb75729f4bf80dddc604cd3b4d06c4f556b48793774b0a4e89d007d5/original.png`. F0 verifica la key vigente con la fila, sin reingesta. JPEG original de Gonzalo, mismo motivo sin crop: `e6814d1ab3c145c8d0d3de117017232a642aba9655e72ad9321270d0e397deca`, 768×1024, `/Users/lahirisan/Downloads/fijacion-cables-e6814d1ab3c1.jpg`. **No sustituir crop por original** en C3.

El dump del 21-sep devuelve `injected_chars=0`, `episode_user_n=0`, `pinned=false`; eso describe el 21-sep, no las 13:56 del 18-sep. History conserva foto user 13:49:25, assistant `[FOTO]` 13:49:36 y assistant RAG 13:49:44. A las 13:56 esos tres estaban en ventana. La copia del assistant RAG ya está truncada; no se sabe por ese dump dónde terminaba la discriminante. F0 reconstruye el estado **antes** de la respuesta D14, excluyendo turnos posteriores.

### Evidencia local ya disponible (no duplicar)

| Archivo | SHA-256 comprobado al redactar |
|---|---|
| `tmp/crop_photo_log_review_prod.txt` | `6314e81a579a9bba2073eae7111a0037c6b35b3a14b549004eac213456e8858e` |
| `tmp/prod_photo_session_logs_2026-09-18_21.txt` | `b975d27bf933ebbbe5572f875b4aa31d35afe6df9b8b8516ee582c72213b22a6` |
| `tmp/crop_photo_log_review.rb` (runner existente) | `46bcef6a23e8ef02e4a52a4050eb684abd71074812b89adeaf1b2a4c386de9ae` |

El segundo archivo contiene `PILOT_AUDIT` completo del answer 13:57 y del D14; no asumir que contiene el answer completo de 13:49. Los prefijos numéricos de sus líneas corresponden también a líneas del log de origen: el artefacto propio debe citar número de línea del archivo local y correlation_id. Un chunk con `truncated=true` no permite verificar lo omitido.

## 2. Diagnóstico de código / hallazgos de arranque

Lectura verificada en HEAD de cabecera. Las citas siguientes son contratos actuales; no confirman todavía la causalidad H1–H6.

### 2.1 Persistencia, ventana y composición

```4:9:app/models/conversation_session.rb
  EXPIRY_DURATION = 30.days  # web workspace TTL; sliding window via refresh!
  MAX_HISTORY    = 20
  MAX_ENTITIES   = ENV.fetch('SESSION_MAX_ENTITIES', 10).to_i
  MAX_MSG_LENGTH = 300
  EPISODE_WINDOW = 4.hours
  EPISODE_MAX_USER_MESSAGES = 3
```

`find_or_create_for` busca por account+identifier+channel (31–50); `add_to_history`/`add_to_history_and_refresh` conservan las últimas 19 entradas y añaden una (67–79). `recent_history_for_prompt(turns: 3)` toma **3 mensajes**, no pares de turnos (86–88). `episode_user_messages` filtra timestamps parseables entre cutoff y now, excluye por texto y toma últimos 3 user (92–107); `last_assistant_message` usa misma ventana (110–120).

```297:305:app/models/conversation_session.rb
  def history_message(role, content, user_id:, correlation_id:)
    message = {
      "role" => role,
      "content" => content.to_s.truncate(MAX_MSG_LENGTH),
      "ts" => Time.current.iso8601
    }
    message["user_id"] = user_id if user_id.present?
    message["correlation_id"] = correlation_id if correlation_id.present?
    message
```

```45:52:app/services/session_context_builder.rb
    history =
      if Rag::EpisodeScopeFlag.enabled? && session.respond_to?(:episode_user_messages)
        users = session.episode_user_messages.map { |content| { role: "user", content: content } }
        last  = session.last_assistant_message
        users + (last ? [ { role: "assistant", content: last.truncate(200) } ] : [])
      else
        session.recent_history_for_prompt(turns: 3)
      end
```

```68:69:app/services/session_context_builder.rb
    result = parts.join("\n\n")
    result.length > MAX_CONTEXT_CHARS ? result[0, MAX_CONTEXT_CHARS] : result
```

```10:12:app/services/rag/episode_scope_flag.rb
    def enabled?
      ENV["RAG_EPISODE_SCOPE_ENABLED"] != "false"
    end
```

No se conserva el orden intercalado original: builder agrupa users y luego último assistant. Pines ocupan primero el presupuesto. F0 mide si corta la discriminante antes de suponer pérdida de historia o elevar caps.

### 2.2 Qué se escribe en text y photo

```29:36:app/controllers/rag_controller.rb
    if question.present?
      # Single UPDATE instead of refresh! + add_to_history (2 UPDATEs).
      conv_session.add_to_history_and_refresh(
        "user",
        question,
        user_id: current_user.id,
        correlation_id: correlation_id
      )
```

Esta escritura ocurre **antes** de construir contexto y ejecutar (41–56), también con foto. Para texto el controller escribe el assistant si `images_uploaded.blank?` (guard en l.81, escritura 82–87). Para foto lo escribe el job; no duplicarlo en controller.

```253:256:app/jobs/field_photo_analysis_job.rb
  def deliver(value, session:, filename:, account_id:, user_id:, correlation_id:, field_photo_id: nil, locale: nil, question: nil)
    session&.add_to_history("assistant", value.fetch(:compact_context), user_id: user_id, correlation_id: correlation_id)

    run_rag = Rag::PhotoQuestionFlag.enabled? && question.present?
```

```272:274:app/jobs/field_photo_analysis_job.rb
    unless rag_answer[:failed]
      session&.add_to_history("assistant", rag_answer.fetch(:answer), user_id: user_id, correlation_id: correlation_id)
    end
```

La ruta cache-hit llama `deliver` nuevamente (`deliver_cached` 207–220, con la llamada abriendo en l.210); `deliver` ejecuta `answer_photo_question` (266–268). La compactación `[FOTO]` no sustituye la respuesta técnica. La discriminante debe salir del assistant RAG final, no de la descripción visual anterior.

### 2.3 Photo RAG, pines, perfil y scope

```64:73:app/services/rag/photo_question_answer_service.rb
      result = execute_rag_query(
        anchored_question,
        session_context: merged_session_context,
        entity_s3_uris:  SessionContextBuilder.entity_s3_uris(@session),
        account:         @account,
        user_id:         @user_id,
        response_locale: @locale,
        correlation_id:  @correlation_id,
        conversation_session_id: @session&.id
      )
```

No pasa `conv_session`, deliberadamente (comentario 28–33); **sí pasa URIs de pines existentes**. «Open» describe el perfil por `entity_sources=[]`, no ausencia incondicional de filtros. `anchored_question` solo añade anclas de catálogo y forma específica (91–120). `merged_session_context` agrega bloque foto de hasta 720 caracteres al base de hasta 2000 (138–161).

```50:53:app/controllers/concerns/rag_query_concern.rb
  def execute_rag_query(question, images: [], documents: [], session_id: nil, response_locale: nil,
                        session_context: nil, conv_session: nil, entity_s3_uris: [],
                        output_channel: nil, force_entity_filter: nil, account: nil, user_id: nil,
                        correlation_id: nil, field_photo_id: nil, conversation_session_id: nil)
```

```75:83:app/controllers/concerns/rag_query_concern.rb
    if candidate_uris.empty? && Rag::EpisodeScopeFlag.enabled? &&
       conv_session.respond_to?(:episode_user_messages)
      episode_matches, episode_candidates = inherit_episode_scope(
        question, conv_session, resolved_account
      )
      if episode_candidates.any?
        candidate_uris = episode_candidates
        inherited      = true
      end
```

`inherit_episode_scope` vuelve a resolver cada user previo de forma independiente; **no persiste** un retrieve window ni anclas de la foto (398–413). Por eso H3 exige probar causalidad: pasar sesión a la foto no garantiza que el siguiente texto herede otro estado. Auto-scope usa solo matches específicos (419–430). La matriz de scope (437–482) puede reemplazar un pin por un candidato específico disjunto; preservar contrato existente, sin ampliar ese comportamiento.

El selector de pin exacto puede responder sin modelo (121–140), y `Selection Turn` solo se aplica cuando el input coincide con una etiqueta de pin (488–544). No confundirlo con responder «es …» a una discriminante. `document_uids = documents.map { SecureRandom.uuid }` (l.148) pertenece a adjuntos: **no** a fabricantes ni al identificador de conversación.

```477:483:app/services/query_orchestrator_service.rb
  def entity_sources
    return [] unless @conv_session.respond_to?(:active_entities)

    entities = @conv_session.active_entities.values
    if @entity_s3_uris.any?
      allowed_uris = @entity_s3_uris.to_set
      entities = entities.select { |meta| allowed_uris.include?(meta["source_uri"].to_s) }
```

```80:96:app/services/rag_retrieval_profile.rb
  def number_of_results
    return EXHAUSTIVE_CANDIDATES if exhaustive_query?

    if @entity_sources.empty?
      return MAX_RESULTS if schematic_block_query?

      return OPEN_RESULTS
    end

    return SAFETY_CRITICAL_RESULTS if safety_critical_query?

    photo_count = @entity_sources.count { |s| s == "image_upload" }
    doc_count   = @entity_sources.count { |s| s == "document" }

    return PHOTO_RESULTS if photo_count > 0 && doc_count == 0

    PINNED_DOCUMENT_RESULTS
```

Para resortes sin anclas especiales: vacío → 8; pasar toda la sesión con pines de documento puede pasar a 3 (constantes 41–47). No es un cambio inocuo. Con flags/rutas estructuradas activas, registrar también short-circuits del orquestador (228–288), no forzar R&G para ocultarlos.

### 2.4 Catálogo/resolver (ruta encontrada, no presumida)

```58:65:app/services/kb_document_resolver.rb
  def self.resolve_scoped(question, account:)
    raise ArgumentError, "account is required" unless account

    scanned = scan_tokens(question)
    return [] if scanned.empty?

    tokens = scanned.pluck(:token)
    candidates = candidates_for(tokens, account: account)
```

```90:94:app/services/kb_document_resolver.rb
  def self.specific_token?(raw)
    return true if raw.match?(/\d/)

    raw.match?(/\A[A-Z]+\z/) && BRANDS.exclude?(raw.downcase)
  end
```

Catálogo = `KbDocument.display_name + aliases`, scoped por `account_id` (118–146). Máximo 3 matches por score/recencia (74–78); la preselección tiene **dos** topes encadenados: `.limit(50)` en SQL (l.134) y `.first(20)` tras el post-filtro de frontera de palabra (l.141). `BRANDS` (37–39) contiene los dos tokens del caso, y ambos miden 4 caracteres, así que superan `MIN_TOKEN` y llegan al SQL: lo que los descalifica para auto-scope es `specific_token?` (90–94), no la longitud. Es perfectamente posible resolver marca, agregar `Query Resolution` y **no** generar candidatos de auto-scope. La afirmación del plan cerrado §3.1.6 («lo detecta y acota») no aplica sin ese gate; código gana. F0 debe distinguir match, filtro aplicado y evidencia pertinente.

### 2.5 Canned, copy y semántica de observación

```311:322:app/services/bedrock_rag_service.rb
      canned_no_results = bedrock_no_results?(raw_answer)

      # Replace Bedrock's default "no results" guardrail message with a user-friendly one.
      no_results_locale = effective_response_locale(question, response_locale: response_locale)
      answer_text =
        if canned_no_results && apply_filter && force_entity_filter
          localized_pinned_no_results(no_results_locale)
        elsif canned_no_results
          localized_no_results(no_results_locale)
        else
          raw_answer
        end
```

```345:356:app/services/bedrock_rag_service.rb
      retrieved_for_extraction, observed_chunk_basis, input_token_basis =
        if citations.any?
          [ citations, "bedrock_citations", "prompt_template_plus_observed_chunks" ]
        else
          Rails.logger.info("BedrockRagService: post-gen citations empty; Retrieve API fallback for source_uri")
          chunks = fallback_retrieve(question, entity_s3_uris: filtered_uris)
          basis = chunks.any? ? "fallback_retrieve_top3" : "none"
          [ chunks, basis, "prompt_template_plus_observed_chunks" ]
        end
      doc_refs = build_doc_refs(retrieved_for_extraction)
      Rails.logger.info("BedrockRagService: doc_refs=#{doc_refs&.size || 'nil'}") if doc_refs
      canned_with_retrieval = canned_no_results && retrieved_for_extraction.any?
```

Dentro de `if canned_with_retrieval` (357–366), sin condición conversacional:

```365:365:app/services/bedrock_rag_service.rb
        answer_text = localized_generation_retry(no_results_locale)
```

```1284:1285:app/services/bedrock_rag_service.rb
  def localized_generation_retry(locale)
    I18n.with_locale(locale) { I18n.t("rag.generation_retry") }
```

```31:31:config/locales/rag.es.yml
    generation_retry: "No pude redactar la respuesta a esta consulta. Reenviarla igual suele fallar: indica fabricante, modelo y el código exacto del display o de la placa, o adjunta una foto de la placa."
```

```31:31:config/locales/rag.en.yml
    generation_retry: "I could not compose an answer to this query. Sending the same wording again usually fails: name the manufacturer, model, and the exact display or nameplate code, or attach a photo of the nameplate."
```

Si Sorry **sin** evidencia observada, la rama vigente es no-results/pinned-no-results, no D14. Canned con chunks no autoriza una respuesta técnica determinista a partir de metadatos. `AnswerSafetyProcessor` y `CitationAttributionGuard` corren después (382–402); no puentearlos ni fabricar citas.

`[RAG_QUALITY]` registra canned, evidencia, contrato y IDs (675–718); `include_diagnostics` expone raw_answer y safety_evidence_chunks (477–487) en llamada directa, pero el concern no transporta esos diagnostics: el arnés debe capturarlos en el borde del servicio/log, **sin** modificar la respuesta del usuario para medir.

```192:195:app/controllers/rag_controller.rb
  def interaction_outcome(result)
    return result.route_outcome.to_s if result.route_outcome.present?

    abstained_answer?(result.answer) ? "abstained" : "answered"
```

La clasificación fallback es regex; el job usa la misma heurística (454–455). D14 puede aparecer como `answered`: no cambiar la métrica global como fix de continuidad.

### 2.6 Cache: corrección de ubicación y alcance

```6:10:app/services/field_photo_diagnosis_cache.rb
  SCHEMA_KEYS = %i[
    analysis compact_context canonical_name aliases manufacturer model_visible
    condition visible_codes model_id input_tokens output_tokens original_cost
    latency_ms created_at contract_version
  ].freeze
```

```64:66:app/services/field_photo_diagnosis_cache.rb
    def ttl
      ENV.fetch("PHOTO_DIAGNOSIS_CACHE_TTL_HOURS", "24").to_f.hours
    end
```

Key por versión de contrato/account/sha/locale (13–15). No contiene answer RAG. Cache hit 13:58 no es prueba de respuesta técnica cacheada, ni justifica invalidar caché de fotos.

### 2.7 Inventario de fuentes de contexto (verificado, base de C7 y de H1/H3/H5)

El turno se arma con **dos ensamblados independientes que no comparten presupuesto**. Confundirlos es el error que hace inmedible C7, porque un cambio que parece «agregar dos líneas de contexto» puede no tocar el retrieval, y un cambio de scope puede no tocar un solo carácter del prompt.

**Ensamblado 1 — qué se busca (filtros de retrieval).** Tres fuentes que compiten en una matriz, más el `top_k`:

| # | Fuente | Dónde se calcula | Nota de precedencia |
|---|---|---|---|
| 1 | Documentos pineados por el técnico | `SessionContextBuilder.entity_s3_uris` (l.76–85) → `pinned_uris` (concern l.66), acotado por `resolve_pinned_scope` (l.67) cuando hay más de uno | Sale de `active_entities`, no del historial. |
| 2 | La pregunta misma | `KbDocumentResolver.resolve_scoped` (l.65) → `auto_scope_uris_from` (l.72) → `candidate_uris` | Solo matches con `specific_token?`. Marca sola no produce candidatos. |
| 3 | El episodio | `inherit_episode_scope` (l.75–84) | **Solo se consulta si `candidate_uris` quedó vacío.** ≤3 users, ≤4 h, re-resuelve cada turno por separado. |
| — | Combinación | `resolve_retrieval_scope` (l.437–483) | Seis resultados posibles: `open`, `auto_scope`, `pin_only`, `pin_kept`, `pin_extended`, `pin_overridden`. |
| 4 | Sufijo ancla de la foto | `PhotoQuestionAnswerService#anchor_suffix` (l.106–121) | No es filtro: es **texto** agregado a la pregunta. Doble gate catálogo + forma. |
| — | `top_k` | `RagRetrievalProfile#number_of_results` (l.80–97) | Se decide por `entity_sources` (orquestador l.477–489, derivado de `active_entities`), **no** por `entity_s3_uris`. Por eso la ruta foto con `conv_session` nil da `[]` → `OPEN_RESULTS = 8`. |

**Ensamblado 2 — qué lee el modelo (string `session_context`).** Orden real de concatenación y, sobre todo, dónde cae el único recorte:

| Orden | Bloque | Quién lo agrega | Acotado por |
|---|---|---|---|
| 1 | `## Session Focus` (pines) | `SessionContextBuilder.build` l.38–42 | dentro del cap |
| 2 | `## Recent Conversation` (episodio o `recent_history_for_prompt`) | l.45–59 | dentro del cap |
| 3 | `## Session Discipline` (solo si hay pines **y** historia) | l.61–66 | dentro del cap |
| — | **Recorte `MAX_CONTEXT_CHARS = 2000`** | l.68–69 | **acota únicamente 1–3** |
| 4 | `## Photo Evidence (this turn)` | `PhotoQuestionAnswerService#merged_session_context` l.138–162 | tope propio de 720, **después** del recorte |
| 5 | `## Query Resolution` | `merge_resolver_context` (concern l.96–98) | **después** del recorte |
| 6 | `## Selection Turn` | `merge_selection_intent` (concern l.99–101, l.488–506) | **después** del recorte |
| 7 | Plantilla de generación | `app/prompts/bedrock/generation.txt` | congelada, no se toca |
| 8 | La pregunta (literal, anclada o compuesta) | concern l.151 → orquestador | la única que una rama A modifica |

No existe tope agregado sobre 4–6. Por eso C7 exige medir **base** (bloques 1–3, ≤2000) y **contexto efectivo** (1–6) por separado, y por eso el techo de 160 tokens del delta se aplica al texto que la aplicación controla, no al total facturado. Un fix que agregue un séptimo bloque, o que duplique uno existente, viola C7 aunque el base siga bajo 2000.

## 3. Contrato de comportamiento congelado

**Alcance:** C1–C7 y el gate de §4.2 rigen F1–F3 sin cambios por CS-D02. El cambio de contrato para hipótesis de campo pertenece al ciclo separado §9.2; no se aplica retrospectivamente a C6 ni al holdout de continuidad. En ese ciclo, C6 no se relaja sin sustituto: su equivalente es **C6-G** = la tabla de contrato de §9.2 más su gate (premisas pertinentes, bloques separados, descargo visible, prohibición de falsa atribución y de transferencia de conjunto). Una hipótesis sin premisas pertinentes es procedimiento inventado y falla igual que C6.

| ID | Precondición / acción | Aserción observable y falsación |
|---|---|---|
| C1 | Último assistant del episodio pregunta identificación; user contesta corto, match válido de catálogo de su cuenta; hay evidencia recuperada. | Respuesta visible no es `rag.generation_retry` en ES/EN ni pide repetir fabricante ya dado o pregunta técnica completa. Fallan respuesta vacía o simple cambio cosmético de D14. Debe continuar el problema con evidencia o declarar un límite real. Capturar raw canned por separado. |
| C2 | Mismo input C1. | Query efectivo conserva problema anterior + identificación explícita; resolver obtiene los documentos del catálogo esperado; filtros/candidatos solo de cuenta y compatibles con pines vigentes. Con designador específico se comprueba filtro exacto; con marca sola se exige ancla textual + evidencia pertinente de ese catálogo, **no** pin duro de marca universal. Ningún literal nuevo de fabricante en producción. |
| C3 | Crop SHA `46de1a09…` + literal histórico de §1, sin follow-up. | Sigue `answered` en ruta de foto, no canned y no D14; conserva respuesta útil con límites. Unitario con fixture equivalente; gate/humo con mismo crop verificado. No sustituir por JPEG completo ni cache de answer. |
| C4 | Pregunta técnica de primer turno, history vacía/nil. | Query byte-idéntico tras el strip vigente; ningún rewrite ni herencia de otra cuenta/sesión. |
| C5 | «ok», «gracias», saludo, identificador sin discriminante o historia vencida. También nueva pregunta «y el torque?». | No inventar pregunta ni reutilizar una antigua. Se preserva input y conducta de F0. El nuevo interrogante nunca se reemplaza por el problema anterior. |
| C6 | Evidencia ausente/no aplicable post-rewrite, incluidas preguntas de vueltas/torque del amarre. | Abstención según contrato gs-v1 vigente (`DATA_NOT_AVAILABLE` donde corresponde), cero procedimiento/valor/condición inventados, cero citas fabricadas. No convertir match de catálogo en evidencia de procedimiento. |
| C7 | History llena, pines largos, ES/EN; comparación con controles F0. | Base `SessionContextBuilder <= 2000` caracteres. Rewrite acotado por §5.1 a 442 caracteres; delta del input+contexto añadido por fix ≤ 160 tokens **estimados** con el mismo `LocalTokenizer`, sin llamadas CountTokens. Contexto efectivo (base+foto+resolver+selección) se mide separadamente y el fix no añade bloques allí salvo rama B dentro del base. No subir cap ni top_k. Si el delta supera 160 o pierde discriminante por recorte, STOP; no truncar para fingir C1. |

Los 160 tokens son techo de incremento del texto que controla la aplicación, no del total facturado: retrieval variable puede alterar miles de tokens. F0 congela valores y medición; F2 informa tokens observados/facturados por llamada y diferencias de chunks, sin atribuir todo el delta al rewrite ni afirmar p95 con ocho casos. C1/C2 no certifican receta del amarre; C6 mantiene ese límite.

## 4. Fases (exactamente 0, 1, 2, 3)

### Asignación de modelo / sesión

| Fase | Capacidad exigida | Separación |
|---|---|---|
| 0 | Modelo con razonamiento riguroso para código, replay y causalidad. | Sin implementación; no se autoconcede un resultado por intuición. |
| 1 | Modelo de ingeniería Rails/Minitest. | Solo rama congelada por F0. |
| 2 | Sesión verificadora que no implementó; si es el mismo agente, usa literalmente §4.2 congelado por este redactor. | No mirar diff antes de congelar/copiar los ocho casos; no reescribir rúbrica a favor del fix. |
| 3 | Ejecutor más riguroso disponible con Lahiri para operaciones y Gonzalo para contenido. | Un flujo real, sin ciclos de reintento para buscar un PASS. |

No se exige cambiar el modelo del producto ni se delegan agentes durante esta redacción.

### 4.0 Fase 0 — Diagnóstico offline + replay, cero fix

**Objetivo:** decidir qué mecanismo causa el 13:56 y excluir H6 del fix si es independiente. **Archivos:** lecturas §0.5, artefactos §1; nuevos runners/resultados solo bajo `tmp/continuidad_sesion_2026-09-21/fase_0/`; actualizar este plan/Anexo A. No editar `app/`, `test/`, locales, flags ni prompt.

**Secuencia cerrada:**

1. Registrar HEAD, diff previo, versión Ruby/Rails, prompt SHA, KB/cuenta y flags efectivos. Verificar los tres hashes de §1. Leer evidencia local primero. Si falta snapshot íntegro, usar únicamente los exports nombrados en §0.4 cuando la sesión de ejecución autorice F0 con lectura productiva. La diferencia imagen histórica/actual queda registrada; un replay con corpus actual no se etiqueta reproducción exacta de 18-sep.
2. Obtener history JSON sin recorte y, de logs/PilotAudit disponibles, answer completo 13:49. El dump conocido no basta para este último. Buscar únicamente por UUID y ventana del incidente. Si texto íntegro o pins/session_id históricos son irrecuperables, distinguir «medido» de «reconstrucción controlada». **No cerrar H2 ni la causalidad histórica con un assistant inventado.** Documentar fuente faltante, parar F0 y pedir a Lahiri recuperación de logs; Gonzalo puede autorizar un nuevo caso medido como baseline, en revisión explícita del plan.
3. Construir snapshot anterior al follow-up y otro posterior a persistir el user de 13:56:28. Cortar history por timestamp y correlation_id, no copiar el final de las 13:58. Usar `travel_to` local `2026-09-18T13:56:28-03:00`; no modificar reloj de prod. `ConversationSession.new` local/no persistido con atributos exportados; entradas de otros días quedan fuera por código real. No descartar mensajes arbitrariamente para favorecer el resultado.
4. Capturar en el borde de `QueryOrchestratorService`/cliente Bedrock: pregunta literal, locale, `session_id` (nil o hash), session_context base y efectivo, último assistant 300/200, tokens estimados, resolver matches+matched_tokens+specific_token?, candidates, pinned URIs, resolved/applied filters, `entity_sources`, top_k, short-circuits. Ejecutar text y photo con dobles de efectos; interceptar escrituras/colas/broadcast, sin invocar visión real. Comparar contexto con reloj actual solo como control de expiración.
5. Replay del cache: demostrar que hit vuelve a `deliver` y RAG; conservar exactamente el payload de visión conocido, incluso «Transformador». Replay de orden: usuario foto → `[FOTO]` → assistant RAG → user corto; no usar D14 como assistant anterior a su propia causa.
6. Evaluar H1–H6 con la matriz siguiente. Obtener al menos un Retrieve-only controlado con input/scope medidos (tope §7); sus hits no son ventana exacta de generación. Solo si hacen falta, usar los probes R&G. Son sustituciones de argumentos en el arnés, **no código de fix ni deploy**.
7. Aplicar selector de §5.0. Emitir diagnóstico, evidencia y costos, registrar la rama o STOP. Rellenar **Anexo A F1, F2 y F3** con fuentes/valores disponibles; F1 y F2 terminarán sus handoffs al cerrar. Si ninguna rama explica y resuelve el contrato, no abrir F1.

**Hipótesis y pruebas obligatorias:**

| H | Prueba primaria / control | «Confirmada» / «Refutada» al cerrar |
|---|---|---|
| H1: input corto no funciona como pregunta efectiva | Comparar request real `es Fuji Yida` con `pregunta_anterior + respuesta_user`, misma configuración, snapshot y corpus registrado; logs/raw+chunks. | Confirmada en el alcance medido si corto colapsa y compuesto conserva identificación/tema y no colapsa sin otro cambio; refutada como causa suficiente si query efectivo ya era compuesto o el control compuesto no corrige, con evidencia. No inferir causalidad de una mera lista de citas distintas. |
| H2: truncación/ventana pierde discriminante o user foto | Comparar answer íntegro → persistido 300 → inyectado 200; offsets exactos de pregunta; reloj histórico vs ahora; user foto presente; forma preservada §5.2. | Confirmada la pérdida solo si se identifica texto/offset perdido. Confirmada causal si restaurarlo dentro del mismo presupuesto cambia el resultado; si no, registrar pérdida real **no causal** y refutar como palanca suficiente. Si falta íntegro, F0 bloqueada. |
| H3: asimetría photo/text cambia scope causalmente | Replay captura kwargs de ambas rutas y `entity_sources/top_k/candidates`; compare foto sin sesión vs solo episodio §5.3; verificar además qué estado podría llegar al siguiente texto. | Confirmada solo con cambio relevante de evidencia y cadena causal hacia 13:56. Refutada como causa del follow-up si no hay candidato específico en episodio, no hay estado transmitido o no cambia el filtro. La omisión de conv_session por sí sola solo confirma asimetría, no causa. |
| H4: D14 pisa el reconocimiento del identificador | Stub SDK Sorry+chunks y metadata de continuación válida; observar sustitución exacta l.365; control Sorry sin chunks y control turno no discriminante. | Confirmar/refutar condición y repetición del dato pedido con respuesta real. Separar causa de generación fallida de causa de copy. No atribuir al copy capacidad de arreglar R&G. |
| H5: resolver pierde/ignora identificación | Catálogo account 3 congelado + `resolve_scoped` sobre corto y compuesto; matched_tokens, score, brand gate, source URIs, Query Resolution y filtros finales. | Confirmada como reconocimiento ausente si metadata real contiene identificación pero no retorna match; o como reconocimiento luego anulado por copy si matches llegan y D14 domina. Registrar cuál. Si no hay match por carencia de catálogo, STOP fuera de las cuatro ramas: no inventar alias ni corregir ingesta. |
| H6: transferencia traveling cable distinta | Leer answer completo 13:57 y evidencia de §1; verificar que hay pregunta completa, canned=false y transferencia entre funciones/conjuntos. No repetir por defecto el query de H6. | Confirmada distinta si aparece con pregunta completa y sin canned, independiente de la condición corta de C1. Registrar en backlog local de este plan; no implementarla. Si demuestra que C1 exige corregir contrato de generación, STOP/cruce con backlog, decisión de Gonzalo. |

Cada H debe terminar en `confirmada` o `refutada` **para la proposición precisa escrita**, con alcance, mecanismo, código, replay y evidencia controlada vinculados. Subdividir H5 como reconocimiento/scope/copy si corresponde. «No medida», «no identificable» y «posible» no son cierres: significan STOP. No confundir seis llamadas con demostración estadística de tasa: si variabilidad impide discriminar, parar con los datos obtenidos, sin elegir una rama por mayoría casual.

**Orden/presupuesto de probes:** primero todos los controles sin red. R&G `P0` = corto en snapshot; `P1` = solo composición H1; `P2` = solo preservación H2; `P3` = solo scope H3 si el replay mostró diferencia, si no queda sin gastar; `P4` = ablación necesaria para distinguir B compuesto de A o repetición del control decisivo, con motivo escrito antes de llamar; `P5` = baseline foto si falta un control vigente. Máximo **6 intentos físicos**, no seis nombres de caso más retries. Saltar controles refutados por evidencia suficiente; no consumir cupo sobrante sin pregunta causal. Si hay retry automático, resta cupo y se omite el siguiente probe. Un fallo de permisos/timeout con envío incierto cuenta hasta aclararlo. No usar el holdout como probes ni repetir la batería 52.

**Tests/validación de F0:** comprobaciones del arnés sin AWS: timestamp en borde 4h, futuro/ilegible excluido, user actual excluido una vez por identidad de turno, contexto vacío fuera de ventana, orden de escritura photo/text y ausencia de mutaciones. No agregar tests de aplicación todavía.

**Artefactos mínimos:** `manifest.json` (HEAD/imagen/flags/config/hashes); `session_6_snapshot.json`; `replay.json` (argumentos completos protegidos localmente); `probes.jsonl` (contador/correlations/raw/chunks/hash/token basis); `diagnostico.md` (H1–H6, ablaciones, rama); `SHA256SUMS`. Runner hashes incluidos. Si no hubo red, ledger lo declara en 0; si bloqueado, conservar también lo parcial.

**Cierre:** las seis H resueltas, no cruce oculto con backlog, rama exclusiva y lista de archivos/tests/techos congelada, manifests verificados, Anexo A siguiente completado. **Stop:** falta evidencia, cambia prompt/LLM, presupuesto agotado sin discriminación, C3 roto o decisiones humanas de §8. **Bedrock:** R&G ≤6, Retrieve-only ≤6 totales (incluidos fallback), visión real 0.

### 4.1 Fase 1 — Un fix, Minitest, sin producción

**Objetivo:** implementar solo rama F0; máximo conjunto inseparable demostrado por ablación. **Archivos:** allowlist exacta de §5 según rama, tests de §5.5 y este documento; artefactos en `fase_1/`. Ninguna fase de ingesta, ningún script histórico modificado.

1. Verificar hashes F0, HEAD/base y prompt; leer Anexo A F1 rellenado. Una deriva funcional exige volver a F0 con nueva autorización/presupuesto, no adaptar a intuición.
2. Escribir tests del contrato de rama antes del cambio. Usar fixtures de diagnóstico F0 para desarrollo. Los ocho casos congelados no se ejecutan con Bedrock aquí.
3. Implementar interfaz y condiciones de §5, preservar input crudo en history, correlation_id, aislamiento account, guards de seguridad, contrato de pines y número de llamadas.
4. Correr tests focalizados y **`bin/rails test`**: `test/AGENTS.md` exige suite completa por tocar servicios compartidos/request flow. Todo AWS/LLM stub; no system tests nuevos. Registrar comando, exit y conteos. **Orden obligatorio: capturar primero la línea base de `bin/rails test` sobre HEAD limpio, antes de aplicar el candidato**, y guardarla en `fase_1/tests_baseline.txt`. Atribuir un fallo a posteriori es una interpretación; compararlo contra una base capturada es un hecho. Un fallo presente en ambas corridas se documenta como preexistente y no se toca; no excluirlo silenciosamente ni «arreglarlo de paso». Lahiri resuelve DB/runtime faltante; no sustituir tests ejecutados por revisión visual.
5. Guardar diff completo y lista de archivos, comparar hash del prompt y flags, medir C7 con fixtures extremos y payload efectivo. Revisar el diff a mano buscando literales de fabricante: `test/architecture/no_hardcoded_equipment_test.rb` en verde **no** cubre este caso, por dos razones verificadas el 21-sep. Su `CORE_FILES` es `app/services/rag/*.rb` + `bedrock_rag_service.rb` + `rag_retrieval_profile.rb`: alcanza a los archivos nuevos de A y B, pero **no** a `rag_query_concern.rb`, `conversation_session.rb`, `session_context_builder.rb`, `query_orchestrator_service.rb` ni `kb_document_resolver.rb`. Y su `KNOWN_MANUFACTURERS` **no contiene FUJI ni YIDA**, así que ni siquiera detectaría esos literales donde sí escanea. No agregar marcas a esa lista ni tocar `MAX_ALLOWLIST_SIZE = 5` en este ciclo: ampliar el guard es otro alcance, y hacerlo aquí mezcla ciclos (§8).
6. Actualizar Estado/Anexo A F2 con hash del candidato, comandos, contadores 0, restricciones y ubicación de harness. No commit/push/PR/deploy.

**Cierre:** unitarios y suite completa pasan, C1–C7 cubiertos a nivel determinista, no llamadas reales, diff coincide con rama y prompt byte-idéntico. **Stop:** branch creep, falta de evidencia para un guard, fallback que solo disfraza D14, costo/contexto fuera de techo, baseline o pin roto. **Presupuesto:** 0 R&G / 0 Retrieve / 0 visión.

**Artefactos:** `candidate.patch`, `tests_baseline.txt` (suite sobre HEAD limpio, previa al candidato), `tests.txt`, `cost_bounds.json`, `contract_matrix.md`, `SHA256SUMS` (incluye hash de cada archivo cambiado y base HEAD). F2 debe ejecutar esos mismos bytes.

### 4.2 Fase 2 — Holdout corto congelado + gate dual

**Objetivo:** evaluar el candidato sin adaptar el criterio. **Archivos:** solo harness/resultados `fase_2/`, fixture de evaluación `test/fixtures/files/session_followup_holdout_2026-09-21.json` (crear copiando la tabla, sin cambiar entradas/expectativas), este documento. No editar implementación durante el gate.

**Independencia:** esta tabla fue escrita por el redactor antes de existir fix. Si el ejecutor implementó F1, copiarla y calcular hash antes de abrir el diff del candidato en F2. Si otro ejecutor escribe el harness, no ve el diff hasta congelar la transcripción. Revisar errores del harness offline con stubs antes de la primera llamada. Después de gastar el holdout, un FAIL cierra corrida; no reparar y repetir los mismos casos como holdout «nuevo».

`Q_ES = "Cómo se ajustan los resortes de la fijación de cables ?"`. `A_ES = "¿Qué fabricante y modelo identifica la placa del equipo?"`. `Q_EN = "How are the cable anchoring springs adjusted?"`. `A_EN = "Which manufacturer and model are shown on the equipment nameplate?"`. A_ES/A_EN son **fixtures de identificación**, no sustitutos del assistant histórico ni de la salida natural de T01. Los snapshots sintéticos contienen solo Q, A y timestamps separados por 7 minutos, dentro de 4h, account=3; sin pines excepto control unitario de pin.

| ID | Entrada congelada / modo | Criterio congelado | Cupo nominal R&G |
|---|---|---|---:|
| T01 | Crop FieldPhoto 34, hash completo §1 + Q_ES, sin follow-up. Harness recorre job/service con mismo payload visual exportado; fixture equivalente solo en unitario. | C3: answered, no canned, no D14; evidencia y límites. Guardar respuesta entera para T02. | 1 |
| T02 | Continuar estado producido por T01 y enviar `es Fuji Yida`, sin foto. | C1+C2. No volver a pedir fabricante ni pregunta completa; conservar tema resortes, identificación de catálogo, evidencia aplicable. Si T01 no produjo discriminante, registrar no elegible; ejecutar además variante con A_ES precongelada para probar mecanismo, **pero no sustituye el gate del flujo natural**. Gonzalo decide reformulación de alcance, no PASS automático. | 1 (+1 reserva solo por no elegibilidad) |
| T03 | Dos subcasos offline/stub desde snapshot Q_ES/A_ES: `ok` y `gracias`. | C5: applied=false, query literal, sin nueva pregunta inventada; no llamada extra. | 0 |
| T04 | Snapshot Q_ES/A_ES → `y el torque?`; SDK stub de ausencia documental. | Nueva pregunta literal, sin rewrite; C5+C6, sin torque/valores/procedimiento inventados. | 0 |
| T05 | Text-only: Q_ES sin history (R&G) → assistant natural → `es Fuji Yida` (R&G). | C4 en primer turno; C1+C2 si discriminante natural. Variante A_ES offline prueba elegibilidad, no reemplaza una secuencia natural fallida. Sin foto ni autoridad visual ficticia. | 2 |
| T06 | Snapshot text-only Q_EN/A_EN → `it's Fuji Yida`, `response_locale=:en`. | C1+C2 en inglés; input contextualizado y copy inglesa coherente; no pedir fabricante otra vez. | 1 |
| T07 | Stub SDK Sorry, `citations=[]` y fallback `[]`; variantes scope abierto y pin forzado. Agregar subcaso follow-up elegible sin evidencia y petición `¿Cuántas vueltas hay que dar a la tuerca del resorte?` con ausencia. | C6: conservar no-results/pinned-no-results según código, no D14 por error, cero citas/receta. Match sin chunks no activa escape de H4. Comparar con base F0. | 0 |
| T08 | Pregunta completa `Cómo se ajustan los resortes de la fijación de cables ? es un Fuji Yida`, sin necesidad de rewrite. | H6 **observacional, fuera del gate de continuidad**: guardar si transfiere traveling cable/CB5, fuente y afirmaciones. No implementar su corrección. | 1 |

Cupo nominal 6 R&G; techo 10 físicos incluye variante T02 (máximo una), retries existentes y cualquier otro intento del SDK. No inventar casos extra con sobrante. Si los retries consumen cupo antes de completar positivos, gate **incompleto**, no PASS. Reusar payload de visión congelado evita otro modelo en F2; F3 prueba imagen real end-to-end.

**Gate dual congelado antes de llamar:**

- **Continuidad:** 100% de aserciones C1+C2 en T02/T05/T06 y C3 en T01; C4/C5/C7 pasan. La secuencia natural foto→texto debe ser evaluable. No promediar fallos ni aceptar «answered» con D14. Todos los unitarios T03/T04/T07 pasan.
- **Safety independiente:** cero procedimientos, valores o condiciones sin sustento en los casos de ausencia T04/T07 y en afirmaciones nuevas de los positivos. Citas visibles comprobadas contra sus chunks; fallback no se presenta como atribución nativa. Una transferencia insegura introducida en T01/T02/T05/T06 es fallo, aunque H6 esté parked.
- T08 no cuenta en denominador ni bloquea por persistencia del defecto histórico H6; se reporta explícitamente sin certificarlo. Eso no exime un fallo safety de los casos que sí puntúan.
- Una copia distinta que admita error de generación no alcanza por sí sola precisión. Si F0 eligió rama D como degradación de producto, necesita decisión explícita de Gonzalo **antes** de abrir gate, registrada con texto y criterio revisado; por defecto gate exige continuidad útil.

**Evaluación humana:** ejecutor hace aserciones mecánicas y mapea afirmaciones a evidencia; Gonzalo valida pertinencia/safety del conjunto de respuestas nuevas (máximo ocho casos, no 52) y si una discriminante fue contestada. Lahiri verifica bytes, hashes, contadores y entorno. Sin firma de contenido, F2 = pendiente de validación, no PASÓ.

**Cierre:** ambos gates PASS, informe firmado, mismos bytes F1, Anexo A F3 completado y rollback preparado. **Stop:** cualquier FAIL C1/C2/C3/safety o presupuesto; no retocar fix durante corrida. **Artefactos:** `holdout.json`, `results.jsonl`, `gate.md`, `usage.json`, `SHA256SUMS`, stdout/stderr del harness y matriz de afirmaciones/citas. Hash separado del fixture congelado y del candidato; conservar T08 como observación.

### 4.3 Fase 3 — Deploy autorizado + humo del flujo Gonzalo

**Solo si F2 PASÓ. Objetivo:** confirmar ruta web real desplegada, una foto + un follow-up, sin contaminar el diagnóstico histórico.

**Archivos/operaciones:** `docs/PRODUCTION.md`, configuración local de despliegue solo lectura salvo operación aprobada; bytes F1; este documento; `fase_3/smoke_readback.rb`. Antes de desplegar, registrar imagen actual web+worker y la versión de rollback; verificar trabajos largos en curso con herramientas de estado existentes. Si hay batch en vuelo, Lahiri elige ventana; no reiniciar worker a ciegas.

1. Preparar manifiesto de release/rollback, diff, SHA del candidato y PASS F2 para Lahiri. Pedir autorización concreta de deploy si no la dio en esta sesión. No commit ni push por inferencia. Si el flujo Kamal requiere un commit y no está autorizado, ese es un bloqueo operativo explícito para Lahiri.
2. Desplegar por procedimiento vigente de `docs/PRODUCTION.md`, web y worker mismos bytes; no copiar archivos `app/` con docker cp. Verificar `/up`, imagen y hash de prompt/flags sin revelar secretos. No cambiar gs-v1 ni episodio como rollback del fix.
3. Gonzalo o Lahiri como operador autorizado usa web autenticada account 3/user 7 en coordinación para evitar turnos intercalados. Registrar estado **actual** de pines/history; no restaurar snapshot histórico sobre session 6 ni borrar historia. Si hay pines que no corresponden, detener antes de enviar: el cambio de scope debe hacerlo el usuario mediante UI y quedar registrado.
4. Subir/reutilizar mismo crop validado por SHA + Q_ES; esperar respuesta final del job. Guardar UUID, image digest, outcome, raw canned y respuesta. Si C3 falla, parar sin enviar follow-up.
5. En el mismo hilo, responder **`es Fuji Yida`** a la discriminante. Un único turno texto, sin volver a adjuntar foto ni reescribir manualmente la pregunta. Si la respuesta inicial no hace la discriminante, registrar flujo no evaluable; no fingir que el usuario respondió a algo que no se preguntó.
6. Readback por UUID: confirmar C1/C2/C3 y C6, perfil y top_k previstos, copia/canned, hashes, latencia y gasto. Si D14 reaparece con retrieval, **parar inmediatamente**, no reenviar. Reportar a Lahiri; rollback solo a imagen anterior registrada si autorizado, nunca apagar gs-v1.

**Presupuesto:** ≤3 intentos físicos R&G (2 nominales +1 por retry existente); ≤3 Retrieve totales; hasta 1 visión si cache miss (registrar aparte). El tercer intento no es una repetición manual para lograr verde. Cache hit es válido si el RAG sí corre; no invalidar cache para gastar visión.

**Tests/cierre:** `/up`, mismo SHA web/worker, foto+texto aprobados por Gonzalo, C1/C2/C3 observados, ausencia de regresión y manifiestos íntegros. No correr otra batería. Resultado: `cerrado` solo con PASS real; caso no elegible, autorización ausente o fallo queda explícito. **Artefactos:** `release.json`, `smoke.jsonl`, `usage.json`, `decision.md`, `SHA256SUMS` con image IDs anterior/nuevo, prompt hash y UUID. El costo reconciliado puede quedar separado de cierre funcional si aún no llegó el rollup; no declarar estimación como facturación exacta.

## 5. Especificación cerrada de implementación, condicionada a Fase 0

**Estas son ramas de especificación, no una decisión de implementar hoy.** Las H pueden coexistir; las ramas elegidas son mutuamente excluyentes mediante este selector. F0 no tiene permiso para inventar una quinta rama ni para implementar un menú entero.

### 5.0 Selector medible y exclusión

1. Si falta evidencia primaria, H5 no resuelve catálogo, hay cruce causal con ítems 1–6 del backlog o cambia generation.txt: **STOP**; Gonzalo decide alcance, Lahiri recuperación/entorno. Registrar mecanismo exacto; no mezclar ciclos.
2. **Rama B (H2)** si pérdida de discriminante está demostrada y preservar sus bytes dentro de caps corrige; o si preservar+componer corrige y las dos ablaciones por separado fallan. En el segundo caso B incluye A como conjunto inseparable, con resultados de ablación explícitos. Tiene precedencia porque A no puede leer lo que ya no existe.
3. En ausencia de condición B, **Rama A (H1)** si query compuesto solo corrige y conserva C2/C3; no requiere cambiar historia/caps ni ruta de foto. H5 debe reconocer identificación. H4 puede quedar confirmado como efecto aguas abajo sin cambio de copy.
4. Si A/B no cumplen, **Rama C (H3)** solo cuando scope-only corrige y replay establece cadena causal foto→texto; aprobación de Gonzalo si estrecha open-retrieval. No basta que la foto produzca un answer distinto aleatoriamente. Si haría falta C+A/B sin ablación/cupo suficiente, STOP para revisar plan; no combinarlos por intuición.
5. Si A/B/C refutadas como fixes suficientes y H4 confirmado, **Rama D (H4)** ofrece degradación determinista exacta §5.4; **no** se vende como generación recuperada. Por defecto no cumple gate de continuidad útil: antes de F1 Gonzalo debe aceptar explícitamente ese comportamiento como alcance del ciclo o el ciclo se bloquea. Si es solo el desajuste meta del ítem 5 del backlog, STOP por cruce, no rama D.
6. Si ninguna condición se satisface: STOP diagnóstico inconcluso/fuera de alcance. No subir presupuesto por cuenta propia. Lahiri autoriza nueva medición; Gonzalo autoriza cambio de alcance. La fila de Estado registra la razón, no «completado».

Dentro de una rama no se tocan otras palancas salvo B+A ya demostrada. Si F1 descubre necesidad de otra, vuelve con evidencia a decisión de F0; no se libera silenciosamente.

**Efecto de CS-D01 sobre este selector.** B sigue inelegible: la oración del assistant mide 225 caracteres y no cabe en 160 ni en 200. La pregunta técnica del usuario sí cabe entera (55 caracteres) y es la que se continúa. Con eso el selector toma la **rama A**, sin exigir que el detector lea la oración de 225 dentro del assistant truncado. C y D no se abren. El detalle del detector queda en §5.1.

### 5.1 Rama A — Rewrite determinista antes de resolver y generar

**Clase nueva propuesta:** `Rag::FollowupQueryRewriter` en `app/services/rag/followup_query_rewriter.rb`. Interfaz propuesta (no existe aún):

```ruby
Rag::FollowupQueryRewriter.call(
  question:, conversation_session:, account:, correlation_id:, now: Time.current
)
# => Result = Data.define(:question, :applied, :reason,
#                         :previous_correlation_id, :catalog_matches)
```

Resultado `question` = input original tras strip vigente cuando `applied=false`; razones enumeradas `no_session`, `non_web_channel`, `account_mismatch`, `no_episode`, `no_discriminant`, `new_question`, `not_identifier`, `ambiguous_history`, `budget_exceeded`, `rewritten`. No hace HTTP/AWS, no LLM, no persistencia, no pinning, no chunk search. Reutiliza `KbDocumentResolver.resolve_scoped` una vez para el identificador y entrega sus resultados al concern para no repetir esa consulta.

**Elegibilidad exacta:** todos estos predicados, fail-closed:

- account presente y coincide con sesión; **canal permitido según el predicado fail-closed del «Call site» de más abajo** (no basta con que no haya imágenes); episodio ≤4 h, timestamps válidos, orden user→assistant previo. Ignorar únicamente la entrada del user actual identificada por correlation_id, no borrar todas las entradas de texto repetido. Si IDs faltan en datos legados, usar posición y ts actual inequívocos; si ambiguo, no rewrite.
- User normalizado ≤120 caracteres, ≤12 tokens separados por espacio, una sola línea, sin `?`/`¿`, sin apertura interrogativa ES/EN (`qué/que`, `cómo/como`, `cuál/cual`, `cuánto/cuanto`, `por qué`, `what`, `how`, `which`, `why`, `when`, `where`). «y el torque?» queda excluido antes del catálogo.
- Forma cerrada: identificador solo, o prefijo ES `es`, `es un`, `es una`; EN `it's`, `it is`, `it's a`, `it is a`, seguido de identificador. Quitar solo prefijo y puntuación exterior para matching, no reescribir el nombre. Saludos/agradecimientos no habilitan la ruta por su longitud.
- Identificador = coincidencia **exacta normalizada** con display_name o un alias de al menos un match de `resolve_scoped` de la cuenta; o designador completo (tokens específicos) cubierto por matched_tokens de esos matches. No basta compartir una palabra genérica de un título. Identidad de marca multi-documento puede retornar varios matches: no seleccionar un único manual por recencia para fingir modelo. No considerar instrucciones arbitrarias del user como alias.
- Existe el user técnico de la consulta a continuar (hasta 3 users del episodio): pregunta explícita con interrogativo ES/EN o signo `?`, no vacía, no `[FOTO]`, máximo 300 caracteres y **guardada entera**. En el caso real es `Cómo se ajustan los resortes de la fijación de cables ?` (55 caracteres, correlation `photo:ff0c3f27-d614-4339-aa80-ec0593f1a784`). Si hubo dos assistants con el mismo correlation de foto, el último RAG es el que sigue a ese user; no se usa el `[FOTO]`. Un turno intercalado de otra pregunta corta invalida la pareja.
- **CS-D01, detector.** La pareja es válida aunque el assistant persistido no contenga la oración de identificación. En el caso real esa oración mide 225 caracteres, empieza en el offset 1204 del texto ya normalizado y no está en los 300 ni en los 200. No se busca `marca`/`modelo`/`¿` dentro de ese recorte y no se sube ningún tope para hacerla entrar. El assistant de ese turno no puede ser solo `[FOTO]`, ni la copia D14, ni un turno de selección de pin. Si el assistant trae **dos o más** preguntas de identificación completas y distintas, no se adivina y `applied=false`, reason `ambiguous_history`. Si la pregunta técnica del usuario no está entera, `applied=false`, reason `no_discriminant`.

**Composición única:** `"#{previous_question}\n#{question}"`. `previous_question` es la pregunta técnica del usuario, no la oración de 225 del assistant y no el texto truncado. Sin instrucciones extra ni marcas inventadas. Límite hard 442 caracteres. En el caso real: `Cómo se ajustan los resortes de la fijación de cables ?` + salto de línea + `es Fuji Yida`. Si se excede, `applied=false`, reason `budget_exceeded`. No traducir, no añadir procedimientos, no usar la respuesta técnica del assistant como pregunta ni como evidencia.

**Qué tiene que hacer la respuesta, y qué no.** La consulta que sigue es el ajuste de los resortes de la fijación de cables, con la identificación que el usuario acaba de dar (`es Fuji Yida`, match de catálogo de la cuenta 3, no un código de modelo). El turno no vuelve a pedir el fabricante. La generación sigue el contrato gs-v1 y la evidencia recuperada. La primera respuesta ya dijo que herramienta, método y número de vueltas no están en los manuales; ese límite sigue en pie (`PRODUCT_ROADMAP`, caso 3) y este ciclo no lo convierte en una receta. Lo que sí tiene que mantenerse es el tema de los resortes de la fijación, no sustituirlo por el cable viajero: esa sustitución ya ocurrió a las 13:57 con la pregunta completa y queda como H6. Si el compuesto la repite, el gate de F2 falla. F1 no toca `generation.txt` para forzar un procedimiento.

**Call site:** dentro de `RagQueryConcern#execute_rag_query`, inmediatamente **después** de l.64 (`resolved_account`) y **antes** de l.65 (`resolve_scoped`). El locale ya se resolvió en l.62 sobre el input original y así queda: una rama A no cambia el idioma detectado.

**Regla dura de variables — la más importante de esta rama.** **No se reasigna la variable local `question`.** Se introduce `effective_question`, y por defecto vale `question`:

```ruby
rewrite = Rag::FollowupQueryRewriter.call(
  question: question, conversation_session: conv_session,
  account: resolved_account, correlation_id: correlation_id
)
effective_question = rewrite.applied ? rewrite.question : question
```

Reasignar `question` parece equivalente y no lo es: siete consumidores posteriores usan esa variable como **clave de comparación**, no como texto a buscar. Con la pregunta compuesta, `episode_user_messages(exclude: ...)` deja de excluir el turno actual y el propio input vuelve como si fuera un turno anterior; `selection_turn?` deja de coincidir con la etiqueta de un pin. Un ejecutor que reasigne rompe C4/C5 sin que ningún test de rama A falle.

**Mapa de consumidores de `question` en `execute_rag_query` (allowlist de cambios: exactamente dos filas).**

| Línea | Consumidor | Para qué usa el texto | Variable exigida |
|---|---|---|---|
| 54 | `question.to_s.strip` | normalización | `question` (sin cambio) |
| 58 | guard de input vacío | validación | `question` |
| 62 | `resolve_response_locale` | detección de idioma | `question` |
| 65 | `KbDocumentResolver.resolve_scoped` | **búsqueda** de catálogo | **regla de reuso, abajo** |
| 67 | `resolve_pinned_scope` | comparación contra etiquetas de pin | `question` |
| 77 | `inherit_episode_scope` | **solo** `exclude:` del episodio (l.401) | `question` |
| 100 | `merge_selection_intent` | `selection_turn?` + `exclude:` (l.490, 493) | `question` |
| 123 | `selection_quick_replies` (gate) | `selection_turn?` + `exclude:` (l.511, 514) | `question` |
| **151** | `QueryOrchestratorService.new` | **texto que se busca y se genera** | **`effective_question`** |
| 175 | `selection_quick_replies` (post) | `selection_turn?` + `exclude:` (l.511, 514) | `question` |

Verificación de que l.77 es exclusión y no búsqueda: `inherit_episode_scope` (l.398–414) **no resuelve** su primer argumento; lo pasa entero a `episode_user_messages(exclude: question)` en l.401 y resuelve los mensajes previos, uno por uno. Un solo parámetro posicional cumple un solo rol. No cambiar esa firma.

**Regla de reuso del resolver en l.65 (evita una segunda consulta SQL y evita que `MAX_MATCHES` expulse la identificación).** Cuando `rewrite.applied`, l.65 **no** se re-ejecuta sobre el compuesto: `resolver_matches = rewrite.catalog_matches`. Cuando no aplica, l.65 queda byte-idéntica. Fundamento: el rewriter ya gastó exactamente un `resolve_scoped` sobre el identificador, que es la información nueva del turno; los designadores específicos de la pregunta anterior **no se pierden**, porque si el identificador es marca sola entonces `candidate_uris` queda vacío (`specific_token?` rechaza `BRANDS`) y el mecanismo de episodio vigente de l.75–84 re-resuelve los turnos user previos. Conteo de consultas del turno: igual que hoy. F0 ya midió el caso real: `es Fuji Yida` matchea los documentos 188, 161 y 144, sin auto-scope; la pregunta de resortes no tiene designador específico, así que el episodio no tiene uno que recuperar. El compuesto, si se resolviera de nuevo, dejaría afuera el 144 por `MAX_MATCHES`. Por eso el reuso es obligatorio. Marca sola sigue siendo ancla en el texto y en `Query Resolution`, no un pin.

**Consumidores de `resolver_matches`, no de `question` (verificado el 21-sep).** El reuso cambia la fuente de tres consumidores, todos aguas abajo de l.65: `mentioned_uris_from(Array(resolver_matches) + episode_matches)` (l.86) que alimenta `resolve_retrieval_scope`, y `merge_resolver_context` (l.96–98) que escribe el bloque `Query Resolution`. Esa sustitución es intencional y debe quedar byte-equivalente al camino actual: hoy l.65 resuelve `es Fuji Yida` y el rewriter resuelve el identificador tras quitar el prefijo, pero `es` mide 2 caracteres y nunca sobrevive a `scan_tokens` (`TOKEN_RE` exige ≥3, `MIN_TOKEN = 4`; `kb_document_resolver.rb` l.17–20), así que ambas entradas producen los mismos tokens y los mismos matches. F1 fija esa igualdad con un test explícito —mismos `resolver_matches`, mismo `scope.reason`, mismo bloque `Query Resolution`— en vez de asumirla.

**Predicado de canal, fail-closed (§0.7).** La elegibilidad exige canal permitido, evaluado sobre la sesión, no sobre la ausencia de imágenes:

```ruby
allowed_channel =
  conv_session.respond_to?(:channel) &&
  (conv_session.channel == "web" ||
   (SharedSession::ENABLED && conv_session.channel == SharedSession::CHANNEL))
```

Con `SharedSession::ENABLED = false` (default verificado) esto es `channel == "web"`, que cubre móvil y escritorio por igual. Cualquier otro canal da `applied=false`, reason `non_web_channel`. La condición completa del call site es `images.empty? && documents.empty? && conv_session && allowed_channel`.

**Trazabilidad:** conservar `question` original para history (el controller ya la escribió en l.29–36), SHA de original y efectivo para auditoría, `conversation_session_id` y `correlation_id` del turno. No se genera otro turno contable.

El gate de selección de pin no requiere ninguna condición nueva: al seguir recibiendo `question` en l.123 y l.175 (mapa de arriba), conserva exactamente su comportamiento actual, aplique o no el rewrite. No agregar un `unless rewrite.applied` ahí. Si no applied, la ruta entera es byte-idéntica. Mantener `session_id` Bedrock recibido, no crearlo.

**Scope C2:** usar `auto_scope_uris_from(rewrite.catalog_matches)` para designadores específicos y política de pines vigente. Marca sola queda como ancla lexical en query compuesto + `Query Resolution`; no convertir `BRANDS` en pin hardcoded. F0 debe demostrar retrieve pertinente con ese mecanismo. Si no lo logra, rama A no es elegible. No permitir que candidates heredados de otro equipo anulen identificación explícita: ante contradicción demostrada no extender A en caliente, STOP hacia diagnóstico de scope.

**No cambia:** caps 300/200/3/4h/2000, PhotoQuestionAnswerService ni Bedrock canned path. Test que solo cambia input no introduce segundo R&G. El C1 real sigue siendo gate: si persiste canned, A falló, no se añade D14 alternativo por cuenta propia.

### 5.2 Rama B — Preservar la discriminante dentro del mismo presupuesto

**Entrada:** pérdida/causalidad H2 demostradas con texto íntegro. No se suben 300, 200, 3, 4h, 20 ni 2000. Se **redefine la selección de caracteres del assistant**, no la retención del producto ni el TTL.

**Dos restricciones verificadas el 21-sep que acotan esta rama (§0.6):** `ConversationSession::MAX_MSG_LENGTH` tiene un consumidor fuera del historial —`FieldPhotoAnalysisService::CHAT_CONTEXT_LIMIT` (l.9)— así que la constante **no se mueve ni se renombra**; solo cambia qué 300 caracteres se eligen. Y el `truncate(200)` de `SessionContextBuilder` vive **solo** en la rama de episodio (l.49): con `RAG_EPISODE_SCOPE_ENABLED=false` el `else` de l.51 inyecta el mensaje persistido completo. B **no** agrega un recorte nuevo en esa rama `else`: hacerlo sería un cambio de comportamiento fuera del defecto medido. Si F0 midió con la flag apagada, B no es elegible con la evidencia de «inyectado 200».

**Clase propuesta:** `Rag::DiscriminantHistoryCompactor.call(content:, limit:)` en `app/services/rag/discriminant_history_compactor.rb`. Usa el mismo extractor lingüístico determinista de §5.1 (helper compartido solo si B+A es inseparable; sin duplicar reglas). Si hay una única pregunta de identificación completa ≤160 caracteres, reservarla al final; tomar prefijo literal hasta `limit - question.length - separator.length`, separador `" … "`, y pregunta exacta; total ≤limit. Si la pregunta ya cabe sin truncar, mantener bytes. Si ninguna candidata, múltiples o longitud >160, usar truncación vigente y marcar en artefacto la ineligibilidad; si ocurre en caso real de C1, B no es solución aceptable y STOP. No inventar ni resumir discriminantes por modelo.

**Puntos exactos:** `ConversationSession#history_message` para role assistant invoca compactor con limit=300 antes de guardar; users conservan truncate(300). `SessionContextBuilder` en l.49 invoca mismo compactor con limit=200. Primero se captura el texto **completo** que ya recibe controller/job; no buscar en logs desde el hot path. Existing history sigue siendo legada y no recuperable; fix vale para nuevos turnos y replay que vuelve a persistir el answer íntegro localmente. No migración ni tabla nueva.

Con pines, si el corte global del base elimina la pregunta reservada, builder reserva primero hasta 200 caracteres del último assistant y su etiqueta, luego rellena los otros bloques dentro de 2000 preservando las instrucciones de scope. No quitar `Session Discipline` para hacer espacio. Si los bloques obligatorios no caben sin alterar significado, STOP; no subir cap. F0 debe identificar si hace falta esta redistribución; no implementarla si solo fallaba 300→200.

**Nuevos límites de selección:** pregunta identificadora conservada ≤160; contenido persistido assistant ≤300; assistant inyectado ≤200; base ≤2000. Medición de tokens antes/después con `LocalTokenizer` y delta C7 ≤160; máximo storage de mensajes no crece. Ejemplos unitarios: texto de 1200 caracteres con discriminante final de 80; pregunta ya en primeros 180; dos preguntas incompatibles; sin pregunta; literal >160; pines saturan base; flag episodio off. Ninguno cambia el texto completo que ve el usuario.

Si F0 demuestra solo preservación suficiente, no crear rewriter. Si dos ablaciones prueban que B+A es mínimo inseparable, aplicar también §5.1 con las mismas interfaces y registrar ambas causas; no tocar foto scope ni canned.

### 5.3 Rama C — Sesión solo para herencia de episodio en foto

**Entrada:** H3 causal confirmada, A/B insuficientes, Gonzalo acepta cualquier estrechamiento de catálogo. No pasar toda `conv_session` a ciegas: cambiaría `entity_sources`, rutas deterministas y posiblemente top_k.

**Firma propuesta del concern:** agregar al final `episode_scope_session: nil` a la firma citada de §2.3. `episode_source = episode_scope_session || conv_session`; usarlo **solo** en condición e invocación de `inherit_episode_scope` (l.75–84). No utilizarlo para locale, selección, pins, perfil o `QueryOrchestratorService#conv_session`. Un kwarg nuevo con default `nil` no afecta a ningún caller existente; en particular **no se “alinea” de paso la firma con el `whatsapp_to:` del job dormido** (§0.7 punto 2).

**Call exacto propuesto en PhotoQuestionAnswerService:**

```ruby
execute_rag_query(
  anchored_question,
  session_context: merged_session_context,
  entity_s3_uris: SessionContextBuilder.entity_s3_uris(@session),
  account: @account,
  user_id: @user_id,
  response_locale: @locale,
  correlation_id: @correlation_id,
  conversation_session_id: @session&.id,
  episode_scope_session: @session
)
```

`conv_session` sigue nil para el orquestador. `entity_sources=[]`; resortes normal conserva `number_of_results=8` (otros intents conservan perfil actual). `candidate_uris` heredados se consultan solo si no hay candidatos actuales; `inherit_episode_scope` retorna URIs específicos de hasta 3 users/4h. Si candidatos nuevos existen, scope puede pasar a `episode_inherited` con `force_entity_filter=true`; ese es el estrechamiento que requiere decisión de Gonzalo. No hay ancla nueva persistida ni photo pin. Sin candidates, kwargs de retrieval byte-equivalentes salvo metadata.

**Condición de falsación:** si estos cambios solo alteran la foto, pero no explican por qué el turno corto posterior cambia en replay natural, C no cumple causalidad y no se implementa. No añadir persistencia de scope para salvar hipótesis. Tests: sesión con pines ajenos no reduce top_k a 3; sin episodio no cambia; específico reciente hereda; vencido no hereda; candidato actual prevalece; C3 obligatorio con estado histórico y con sesión sin pines.

### 5.4 Rama D — Evitar D14 repetitivo con degradación explícita

**Entrada:** H4 confirmado y decisión de Gonzalo **previa a F1** aceptando degradación (no respuesta técnica inventada), o STOP como dice §5.0. Esta rama no elude la falta de generación ni fabrica afirmaciones desde chunks.

Reusar la elegibilidad de §5.1 como `Rag::FollowupQueryRewriter` en modo de detección determinista, sin componer input; fijar `applied=false`, reason `recognized_followup`. Resultado transporta un objeto inmutable `followup_context` con `eligible`, `catalog_match`, `previous_question`, `identifier`, `account_id`; texto anterior ≤300, identificador ≤120. No persistirlo en DB ni en prompt. Pasarlo como keyword opcional `followup_context: nil` concern → `QueryOrchestratorService#initialize` → rutas `.query` de Bedrock; default nil mantiene otros callers. No transportar un booleano enviado por params del navegador.

**Booleano exacto en el lugar l.357–365:**

```ruby
recognized_followup_failure =
  canned_no_results && retrieved_for_extraction.any? &&
  followup_context&.eligible == true &&
  followup_context&.catalog_match == true &&
  followup_context&.account_id == @account&.id
# if canned_with_retrieval
#   answer_text = recognized_followup_failure ? localized_followup_failure(...) : localized_generation_retry(...)
# end
```

El contexto solo puede crearlo el detector con una pareja de turnos y match de cuenta válidos. No reevaluar catálogo desde Bedrock ni llamar otro modelo. `retrieved_for_extraction` sigue siendo evidencia observada, no afirmar que contiene respuesta.

**Salida fija propuesta en locales (nueva key `rag.followup_generation_unavailable`, no cambiar D14 global):**

- ES: `"Recibí la identificación: %{identifier}. La consulta pendiente sigue siendo: %{previous_question}. Recuperé documentación, pero no pude elaborar una respuesta sustentada para este seguimiento."`
- EN: `"I received the identification: %{identifier}. The pending question is: %{previous_question}. I retrieved documentation, but could not compose a grounded answer to this follow-up."`

Datos interpolados como texto, escapados por render normal; sin HTML confiable, citas ni receta. No pedir otra vez marca, foto ni pregunta completa. Guards se ejecutan igual. Registrar `followup_generation_unavailable=true` sin borrar `canned_with_retrieval`; en reporte **fallo de generación**, jamás «recuperación de respuesta» por cambiar el copy. Si se agrega `route_outcome`, debe viajar estructuralmente de Bedrock al orquestador y concern; no ampliar enums de DB ni tocar heurística global. Default de esta rama: solo log, conservar métrica legacy y evidenciar su limitación.

Tests de truth table: elegible+match+chunks+canned+cuenta → salida nueva; cada término falso/nil → ruta vigente; sin chunks → no-results; no canned → respuesta original; contexto de otra cuenta → ruta vigente. Afirmar que fallback chunks nunca se convierten en citas y que raw canned no se oculta. **Sin aprobación de Gonzalo esta rama está especificada pero bloqueada**; la mera desaparición de D14 no permite cerrar F2.

### 5.5 Archivos y tests por rama

| Rama | Allowlist de implementación | Tests Minitest mínimos |
|---|---|---|
| A | `app/services/rag/followup_query_rewriter.rb` nuevo; `app/controllers/concerns/rag_query_concern.rb`; telemetría estructurada local en esos puntos. | `test/services/rag/followup_query_rewriter_test.rb` nuevo; `test/controllers/concerns/rag_query_concern_test.rb`: kwargs/input original/compuesto, no doble resolver, current turn excluido, match de otro tenant rechazado, marca vs modelo, nueva pregunta, thanks, 4h/IDs ambiguos, selección pin intacta. **Obligatorios por el mapa de variables de §5.1:** (a) con `applied=true`, el orquestador recibe el compuesto **y** `episode_user_messages` sigue recibiendo el original como `exclude:` —el turno actual no reaparece como turno previo—; (b) con `applied=true` y la etiqueta de un pin en el input, `selection_turn?` conserva su resultado original; (c) sesión con `channel` distinto de `"web"` → `applied=false`, reason `non_web_channel`, kwargs del orquestador byte-idénticos; (d) con `applied=true` y reuso de `resolver_matches`, `mentioned_uris`/`scope.reason` y el bloque `Query Resolution` coinciden con los del camino actual sobre el input corto (igualdad de tokens, §5.1). |
| B | `app/services/rag/discriminant_history_compactor.rb` nuevo; `app/models/conversation_session.rb`; `app/services/session_context_builder.rb`; archivos A **solo** si ablación lo exige. | `test/services/rag/discriminant_history_compactor_test.rb` nuevo; `test/models/conversation_session_test.rb`; `test/services/session_context_builder_test.rb`; `test/jobs/field_photo_analysis_job_test.rb` y `test/controllers/rag_controller_test.rb` para texto íntegro recibido y persistencia/correlation. |
| C | `app/services/rag/photo_question_answer_service.rb`; `app/controllers/concerns/rag_query_concern.rb`. | `test/services/rag/photo_question_answer_service_test.rb`; `test/controllers/concerns/rag_query_concern_test.rb`; `test/services/rag_retrieval_profile_test.rb`; job cache hit/miss en `test/jobs/field_photo_analysis_job_test.rb`. |
| D | Detector §5.4; concern; `app/services/query_orchestrator_service.rb`; `app/services/bedrock_rag_service.rb`; `config/locales/rag.es.yml`, `config/locales/rag.en.yml` solo key nueva. | `test/services/bedrock_rag_service_test.rb` (truth table/raw/fallback), `test/services/query_orchestrator_service_test.rb` (transporte keyword), test del detector/concern y locales ES/EN. |

Comunes: C3 stub en `test/services/rag/photo_question_answer_service_test.rb`, no-results y guards existentes; `test/services/bedrock_rag_service_grounded_synthesis_test.rb` y `test/architecture/no_hardcoded_equipment_test.rb`; suite completa `bin/rails test`. Reutilizar helpers existentes, no duplicar arquitectura de mocks ni introducir gemas. Antes de crear un path de test verificar que existe su equivalente vigente; si se renombró, documentar el mapeo en Anexo A F1. Test unitario no puede probar que un proveedor real nunca devuelve canned: F2/F3 cierran esa parte medida.

## 6. Telemetría y prueba de C1 (sin tablas nuevas)

Reusar `[RAG_QUALITY]`, `[PILOT_AUDIT]`, `[PILOT_USAGE]`, `PilotEvent`, `BedrockQuery` y `correlation_id`. No agregar filas `bedrock_queries` por Retrieve-only ni un enum de «followup» como source. El query efectivo puede diferir del original: conservar SHA de ambos para correlación, no sobrescribir el texto del usuario en history.

| Dato | Fuente / uso |
|---|---|
| account/user/conversation/correlation | RAG_QUALITY y eventos existentes; mismos IDs del turno, sin segunda interacción. |
| `canned_no_results`, `canned_with_retrieval`, `evidence_mode`, `retrieval_context_present` | RAG_QUALITY; distinguir error de generación, ausencia y fallback. |
| Answer completo + `generation_retry` | PILOT_AUDIT local/readback; comparar key localizada y contenido. D14 no tiene hoy un outcome estructural propio. |
| raw_answer, safety_evidence_chunks, citations | Diagnostics del servicio en harness + logs; observar raw sin retirar guards. Fuente/página/hash y native vs fallback separados. |
| Query original/efectivo, `followup_applied`, reason, prior correlation, catalog ids | Un log estructurado acotado `[RAG_FOLLOWUP]` si la rama lo necesita; texto completo solo artefacto protegido, log usa hashes/longitudes. No nuevo job/table. |
| base_chars, effective_context_chars, estimated_tokens, entity_sources, requested top_k, scope reason, candidate/applied URIs | Harness en borde exacto; preservar los filtros efectivos, no solo candidates teóricos. Hashes de URIs en log si se amplía telemetría; detalle en artefacto. |
| Modelo/contrato/prompt SHA/imagen | Manifiesto; gs-v1 constante; comparar ejecución local/candidata/prod. |
| `outcome=answered` | Observable auxiliar, jamás gate único: 13:56 ya lo tenía. No «arreglar» C1 retocando clasificación. |

C1 pasa cuando la **respuesta visible útil** corresponde al problema anterior identificado y no es D14/repetición, con evidencia/ausencia correcta; se une por UUID al request efectivo y a canned/citas. No basta encontrar la marca en el texto ni una respuesta más larga. Rama D conserva el error explícito y requiere decisión especial descrita, no manipulación de observables.

## 7. Presupuesto y custodia de artefactos

| Fase | Máximo R&G físicos | Retrieve-only total (manuales + fallback + retries) | Visión | Reglas |
|---|---:|---:|---:|---|
| 0 | 6 | 6 | 0 | Replay/stubs primero; no calentamiento R&G. |
| 1 | 0 | 0 | 0 | Todo stub, incluidas estimaciones locales. |
| 2 | 10 | 10 | 0 | 6 nominales, reservas acotadas §4.2; no reabrir holdout. |
| 3 | 3 | 3 | ≤1 | Dos turnos; tercera llamada solo retry existente, no intento manual. |
| Total techo | **19** | **19** | **1** | Ningún traslado de cupo entre fases. |
| Ciclo §9.2 (A.G) | **0 autorizado** | **0 autorizado** | 0 | Fuera de este techo. Lahiri autoriza un cupo propio, registrado antes del primer envío. No hereda remanentes de F0–F3 ni reutiliza el holdout de F2. Preparar e implementar el cambio local no requiere cupo. |

El arnés cuenta en el método del cliente SDK por invocación física, antes del envío; cualquier retry de filtro o cold-start también cuenta. Desactivar retries implícitos del SDK **solo en el arnés** o contabilizarlos con handler para garantizar el límite; no alterar configuración productiva. En el harness, al llegar al máximo, bloquear el próximo envío y marcar corrida incompleta. El humo web de F3 no tiene ese interceptor: antes de autorizarlo, Lahiri debe verificar los límites efectivos de retries SDK/Aurora/filtro y que dos turnos puedan ejecutarse dentro del cupo de 3. Si no puede garantizarse ese techo, STOP operativo antes del envío y decisión explícita de presupuesto; no cambiar retries de producción para forzar el ensayo. No llamar R&G para obtener readiness. Retrieve warm-up, si se necesita, consume su cupo. Sin CountTokens API extra; `AnthropicTokenCounter::LocalTokenizer.estimate` es estimación chars/3.5, **no** tokenización exacta.

Costo: guardar input/output/cache tokens, token_source, modelo, región y latency por UUID. Reportar estimaciones como estimaciones; conciliación exacta vía S3 Model Invocation Logs → rollups diarios `bedrock_daily_costs`, según AGENTS. No prometer un precio por llamada fijo. Si la fase agota cupo sin cierre, entregar evidencia y STOP; Lahiri autoriza extensión explícita antes de otra llamada.

Cada fase usa `tmp/continuidad_sesion_2026-09-21/fase_N/`. No subir artefactos a KB/S3 de ingesta ni adjuntarlos a commits. Manifest incluye `created_at`, `base_head`, `candidate_sha256`, `image`, flags, prompt SHA, inputs, reloj del replay, ids/correlations, modo, número físico de intentos, resultados y token basis. Datos personales/operativos quedan locales; no incluir secretos.

Hash al cerrar (macOS):

```bash
# Dentro del directorio de fase; lista explícita de archivos reales, sin glob que incluya SHA256SUMS.
shasum -a 256 manifest.json session_6_snapshot.json replay.json probes.jsonl diagnostico.md > SHA256SUMS
shasum -a 256 -c SHA256SUMS
```

Adaptar solo nombres a los entregables reales de F1–F3. Incluir runners/fixture/resultados y todos los artefactos críticos en manifiesto; no auto-hashear SHA256SUMS dentro de sí mismo. Registrar en Estado SHA-256 completo de SHA256SUMS después de verificar. La integridad de los bytes exportados de la foto se verifica sobre el original retenido; registrar por separado cualquier SHA de normalización/compresión, sin exigir que los bytes transformados coincidan con el original. Un artefacto ausente no tiene hash inventado: Estado queda bloqueado/no ejecutado. Logs históricos se referencian con los hashes de §1 y no se copian a cada fase.

## 8. Stop rules y decisiones humanas

| Disparador | Acción / dueño |
|---|---|
| Fix de continuidad toca `generation.txt`, gs-v1, temperatura o `# NO MATCH` | STOP en F1–F3. CS-D02 define el lever de generación en §9.2, para otra sesión y otro candidato; no se mezcla con el fix de continuidad. Temperatura y flags quedan fuera del lever. |
| Hace falta LLM extra, clasificador/memory agent o pedir repetir pregunta completa | STOP; no es solución permitida. Informar a Lahiri y Gonzalo con evidencia. |
| C3 cambia a canned/D14, pierde respuesta útil o cambia scope de foto sin justificar | STOP inmediato; no gastar siguiente turno. Lahiri evalúa rollback de candidato, Gonzalo scope/contenido. |
| F0 no resuelve H1–H6 o faltan datos íntegros | STOP F0; Lahiri recupera evidencia. No emitir prompt F1 como listo. |
| El lever estrecha open-retrieval de foto y puede ocultar manuales | Preparar comparación exacta URIs/top_k/chunks y pedir decisión concreta a Gonzalo antes de implementar/desplegar C. |
| Cruce causal con backlog gs-v1 ítems 1–6 o identidad web_v1 | Registrar ítem/síntoma/evidencia y STOP. No implementar aquí; Gonzalo decide ciclo aparte. |
| Falta match real de catálogo, requeriría alias/ingesta nueva | STOP fuera de ramas. No agregar fabricantes a código ni reingerir nota. |
| C1 se maquilla cambiando D14 por otro error | Gate falla por defecto; rama D solo con alcance de degradación aceptado explícitamente por Gonzalo antes del holdout. |
| Safety FAIL en gate o prod | STOP aunque continuidad pase. Conservar respuesta y evidencia; Gonzalo evalúa contenido, Lahiri despliegue/rollback. |
| Presupuesto, credenciales, aprobación, suite o hashes bloquean | No simular éxito. Lahiri resuelve; entregar paquete concreto y conservar estado. Auto-review denegado: explicar rechazo y razón. |
| H6 distinto confirmado | Añadir ficha en §9.1 con síntomas/UUID/claims y límite; no implementar ni usar como gate T08. |
| El lever de §9.2 necesitaría cambiar una línea sin prefijo de variante, el bloque `# NO MATCH` o un SHA pinneado de test (`9182ccf3…`) | STOP en el ciclo §9.2: eso cambia también el contrato `strict-v1`, no solo la voz de copiloto. Presentar diff exacto, test afectado y efecto a Gonzalo antes de implementar. Restricción 28 y §9.2.1. |
| Hipótesis de campo sin premisas pertinentes del mismo componente y función | FAIL de safety del gate §9.2. No se compensa con descargo, marcador ni cita real de otro conjunto. Restricción 29. |
| Ciclo §9.2 sin cupo Bedrock registrado por Lahiri | STOP antes del primer envío. Implementar y validar con stubs sí está permitido; medir con Bedrock no. |

Ningún STOP reabre D18 ni autoriza apagar gs-v1. Ninguna solicitud de criterio humano reemplaza trabajo ya permitido: preparar evidencia/diff/impacto antes de pedir la decisión.

## 9. Estado y protocolo de plan vivo

| Fase | Estado al 21-sep | Artefacto / hash / salida |
|---|---|---|
| Redacción | Completa; revisión local de código y artefactos existentes. Sin acceso productivo ni Bedrock. | Este plan + una fila de índice. Prompt y evidencia histórica hashes §0.2/§1. |
| Validación | **Completa 21-sep-2026** contra HEAD `ce6f8db3…`, sin red ni Bedrock. 4/4 hashes reproducidos, 24/24 citas correctas, 11/11 rutas de test existentes; 3 rangos en prosa corregidos y 6 hechos de código incorporados. | §0.6 (resultado), §0.7 (canal/includers), §2.7 (fuentes de contexto), §5.1 (mapa de variables). No repetir; sí reconfirmar HEAD y hashes en F0. |
| 0 | **Cerrada; medida 21-sep-2026. No repetir.** Pérdida de la oración del assistant confirmada (225 caracteres, offset 1204). B inelegible. H3 refutada como causa. H4 copy confirmada. H5: catálogo reconoce Fuji Yida, sin auto-scope. H6 distinta. La pregunta técnica del usuario está entera (55 caracteres). 0 R&G / 0 Retrieve / 0 visión. | `tmp/continuidad_sesion_2026-09-21/fase_0/`. SHA-256 de `SHA256SUMS`: `3f5736b4d5e14a09620bde9c0f836e1d135089e921b7add47af4c5e143fc463c`. |
| 1 | **Cerrada 21-sep-2026.** Rama A, detector CS-D01. 0 R&G / 0 Retrieve / 0 visión. Baseline `bin/rails test`: 3035 corridas, 12088 aserciones, 0 fallos, 0 errores, 186 skips. Focalizados rewriter+concern: 107 corridas, 367 aserciones, 0 fallos. Suite candidata: 3059 corridas, 12193 aserciones, 0 fallos, 0 errores, 186 skips, EXIT 0. Prompt sin cambio. | `tmp/continuidad_sesion_2026-09-21/fase_1/`. SHA-256 de `SHA256SUMS`: `fd79df251eb79fc66aa8fe0caa2e4ac2e66afb086772bb6e071205312078da0f`. `candidate.patch`: `9efec883915b0ab0de53afe46b4874dd474182268d30a6533669d56b70ad320c`. |
| 2 | **Bloqueada por F1.** Holdout escrito y congelado §4.2. | Sin corrida, gasto 0; hash del fixture se registra al transcribir antes del gate. |
| 3 | **Bloqueada por PASS dual F2 y autorización operativa.** | No deploy, no smoke. |
| Ciclo separado de generación — CS-D02 | **Planificado para la respuesta de copiloto senior desde los chunks existentes. Arranque después del cierre de F1, en otra sesión (§9.2).** | Lever: generation.txt, solo líneas `GROUNDED_SYNTHESIS`; actualización de PRODUCT_ROADMAP y AGENTS en la sesión que lo implemente. Contrato/gate §9.2, mecánica verificada §9.2.1, allowlist/base/presupuesto §9.2.2, arranque A.G. Sin implementación ni Bedrock en esta revisión; sin lever de ingesta; cupo Bedrock 0 hasta que Lahiri lo autorice. |

**Protocolo al cerrar cualquier fase:**

1. Actualizar su fila con PASS/FAIL/bloqueada, fecha, responsable, comandos, intentos, resultados y hash completo del manifiesto verificado.
2. Corregir hallazgos que la evidencia refute; conservar qué se midió y con qué versión. No borrar fallos ni renombrar corrida fallida como nueva.
3. Rellenar el prompt siguiente de Anexo A con valores reales. Prefijar **⚠️ CRÍTICO:** ante un cambio de implementación o una condición humana que bloquee. F0 también prellena F2/F3 con restricciones técnicas/costo; F1 completa hash del candidato; F2 completa gate y release.
4. Cada decisión humana nueva tiene ID `CS-D01`, consecutivo, nombre (Gonzalo/Lahiri), fecha, decisión literal, evidencia y efecto. No presuponer autorización de un silencio.
5. Si contradice límites/gate, detener antes de actuar y presentar esa decisión. El documento es autosuficiente: la siguiente fase no requiere el brief del chat.

### CS-D01 — la respuesta corta continúa la consulta

| Campo | Valor |
|---|---|
| Fecha | 21-sep-2026 |
| Quién | Lahiri, en la sesión de ejecución, describiendo lo que vio como usuario |
| Decisión literal | La conducta es la 2. El sistema preguntó por marca y modelo; el usuario respondió `es Fuji Yida` y ahí se perdió el hilo. La respuesta corta tiene que continuar la consulta inicial, el ajuste de los resortes de la fijación de cables. |
| Evidencia | `photo:ff0c3f27-d614-4339-aa80-ec0593f1a784` pregunta eso y cierra pidiendo marca, modelo y tipo de componente. `query:eb47da8f-d529-4e9a-a017-66479260c6ba` guarda solo `es Fuji Yida` y responde con `rag.generation_retry`. La pregunta del usuario está entera en la historia; la oración del assistant, no. |
| Efecto | Rama A. El detector enlaza la pregunta técnica del usuario con el identificador aunque el assistant truncado no contenga el `¿`. No se implementa B. No se cambia `generation.txt`. |
| Límite que la decisión no levanta | Dar la marca no crea el procedimiento de vueltas, herramienta y método. La respuesta de las 13:49 ya lo declara ausente, y el roadmap lo deja como riesgo de piloto hasta que un técnico lo valide en el conjunto real. A las 13:57 la misma consulta, ya con Fuji Yida en el texto, derivó al cable viajero (H6). Continuidad y procedimiento inventado son cosas distintas. |

No se pidió validación de otro modelo. El comportamiento descrito ya está en el answer de las 13:49, en el turno de las 13:56 y en el de las 13:57.

### CS-D02 — respuesta de copiloto senior desde el conocimiento ya ingerido

| Campo | Valor |
|---|---|
| Fecha | 21-sep-2026 |
| Quién | Lahiri |
| Decisión literal | El copiloto senior es la voz de la respuesta al técnico en campo, no el resumen de la carga. Con el conocimiento ya ingerido, la respuesta puede inferir un procedimiento que el corpus no escribe de forma explícita. Ese procedimiento no es verdad del fabricante: va en un bloque distinto, con descargo visible, y el técnico lo verifica en el equipo antes de actuar. Los hechos citados quedan en otro bloque. |
| Evidencia | Intención explícita de Lahiri del 21-sep-2026, precisada en esta revisión. La ingesta técnica existente aporta chunks S0, S4, S6, S7, S10, S16, S17 y S18 y field_records con acción, resultado y evidencia. `BatchResultsParserService#write_chunks_to_s3` escribe header de identidad + chunk["text"] + field_records; summary y companion_offer no integran ese cuerpo. La ausencia del procedimiento explícito ya está medida en `photo:ff0c3f27-d614-4339-aa80-ec0593f1a784`; la transferencia a otro conjunto en `query:fcaba5a2-dcb7-4609-a370-9fb53c4766cd` sigue siendo el antecedente H6, no un procedimiento válido. No se reabre F0. |
| Efecto | El ciclo separado §9.2 cambia `generation.txt` para responder como copiloto y poder proponer una hipótesis de procedimiento a partir de los chunks ya ingeridos del mismo componente y función. Hechos citados e hipótesis van en bloques distintos; esta última lleva descargo visible y verificación en el equipo antes de actuar. No modifica CS-D01, §5.1 ni los topes 160/200. No requiere modificar ingesta, mover el tono a los chunks ni rediseñar el pipeline. |
| Alcance y contrato | Arranque A.G después del cierre de F1, en otra sesión. La prohibición vigente de completar procedimientos es lo que este lever cambia en la respuesta. PRODUCT_ROADMAP y AGENTS se actualizan en la sesión que lo implemente para reflejar esta decisión; no se editan hoy. Una hipótesis no cita una página que no la contiene ni presenta números, herramientas o pasos ausentes como datos del manual. Transferir cable viajero, CB2/CB3 o puerta como ajuste de los resortes sigue siendo FAIL de safety aunque lleve descargo. |

### Aspiración de copiloto — voz de la respuesta y conocimiento técnico existente

Lahiri, el 21-sep-2026, fijó que el copiloto senior debe ser la voz de la respuesta al técnico en campo. El ciclo de generación usa el conocimiento ya ingerido para proponer una hipótesis de procedimiento cuando el corpus no la escribe de forma explícita, con hechos citados separados, descargo visible y verificación en el equipo antes de actuar. Esta es la finalidad de CS-D02.

**Base de conocimiento ya verificada; no se rediscute ni abre un lever de ingesta:**

- [BatchChunkingPrompt](../app/prompts/batch_chunking_prompt.rb), bloques `CHUNK FORMAT` y `STRUCTURED EXTRACTION`: el corpus técnico contiene S0, S4, S6, S7, S10, S16, S17, S18 y field_records con acción, resultado y evidencia. Es lo bastante rico para sostener una respuesta amplia. Que falte un procedimiento explícito no declara insuficiente la ingesta técnica.
- [BatchResultsParserService#write_chunks_to_s3](../app/services/batch_results_parser_service.rb): el cuerpo enviado a S3 para el embedding de Titan es el header de identidad más `chunk["text"]` más los field_records renderizados. `summary` y `companion_offer` quedan fuera de ese cuerpo: se conservan en el asset para mostrarse al terminar la carga; `CONTENT_PAGE` los omite.
- En el código vigente, `SUMMARY` y `COMPANION_OFFER` contienen el tono de colega senior del mensaje de carga. Ese tono no es la respuesta a la consulta ni aporta conocimiento al embedding. No se mueve a los chunks porque ensuciaría el retrieval. `amazon.titan-embed-text-v2:0` sigue sin persona; no se cambia el pipeline.
- [generation.txt](../app/prompts/bedrock/generation.txt) es el prompt de la respuesta. Hoy prohíbe completar procedimientos; §9.2 cambia esa prohibición, en las líneas `GROUNDED_SYNTHESIS` del contrato gs-v1 (§9.2.1), para permitir la hipótesis basada en chunks del mismo componente y función. El tono de copiloto se define allí para la respuesta, sin alterar SUMMARY ni COMPANION_OFFER.

F1 sigue enlazando determinísticamente la pregunta de resortes con `es Fuji Yida`, sin editar `generation.txt`. El ciclo de generación trabaja en otra sesión y sobre un candidato separado; no convierte una hipótesis en instrucción del fabricante ni atribuye a una página lo que no contiene.

### 9.1 Hallazgo H6 parked / backlog separado

**Distinto confirmado en F0 (21-sep-2026), no implementado.** `query:fcaba5a2-dcb7-4609-a370-9fb53c4766cd`: pregunta completa, `canned_no_results=false`, evidencia `bedrock_citations`. La respuesta afirma que el manual Fuji Yida no trae el ajuste de los resortes y enseguida describe fijación de cable viajero: enchufe de cuña o clips, diferencia de tensión ≤ 5 %, cables CB2 y CB3 en el hueco, ramas cada 1,5 m. Citas visibles: Fuji Yida p. 28, p. 88 y p. 60, más la nota `7cd6d699…` dos veces. p. 88 y p. 60 son instalación de cable viajero/hueco; p. 28 es ajuste de puerta. No es el fallo corto de las 13:56 ni el ítem 5 del backlog de generación. El turno 13:58 no se releyó entero en esta fase; el registro de arranque que lo asocia a CB5 queda como evidencia previa, no como medición nueva. Responsable de priorizar: Gonzalo. T08, si alguna vez hay gate, observa sin corregir. Esta ficha no es implementación ni otro plan.

### 9.2 Ciclo separado — respuesta de copiloto mediante generation.txt

**Objetivo:** cambiar `app/prompts/bedrock/generation.txt` para que la respuesta al técnico hable como copiloto senior y pueda proponer una hipótesis de procedimiento desde los chunks ya ingeridos del mismo componente y función, aunque el corpus no escriba ese procedimiento explícitamente. La ingesta técnica ya es la base de conocimiento y es lo bastante rica para sostener una respuesta amplia; no se mide de nuevo ni es un lever de este ciclo.

**Estado: planificado para otra sesión, después del cierre de F1.** Prohibido ejecutarlo en la misma sesión que F1, incluso si F1 cierra durante esa sesión. F1 conserva la rama A determinista de §5.1, sus caps y el prompt vigente. En esta revisión solo se corrige el plan; no se implementa ni se escribe una receta. H6 sigue parked: su evidencia fija un criterio de rechazo sin reabrir su medición ni añadir otro fix.

**Contrato vigente que el ciclo cambia y documentos que actualiza al implementar:**

- [generation.txt](../app/prompts/bedrock/generation.txt), SHA de base `6a8abaed1e56bc880c7844f75288a7406973b9595c09e7fecafa928a473a789f`: `EVIDENCE CONTRACT`, `RESPONSE SELECTION` y `FORMAT` hoy prohíben completar procedimientos. El lever cambia de forma coherente esa prohibición para la hipótesis de campo y define la voz de copiloto; no se limita a agregar un descargo a reglas que sigan prohibiéndola. La cláusula concreta que redefine es la del bloque de inferencia que **ya existe**, `Interpretación técnica:` (l.141, línea `GROUNDED_SYNTHESIS`): «no values, turns, torques, sequences, or prescribed intervention». Conserva la atribución documental, la identidad de conjunto y los placeholders de Bedrock. **Corrección de esta revisión:** el lever se escribe solo en líneas `- GROUNDED_SYNTHESIS:` y **no** toca `# NO MATCH` ni la prosa de `ROLE`; ambas son compartidas con `strict-v1` y `# NO MATCH` está fijado por un test de igualdad entre variantes (§9.2.1). La voz de copiloto se define en viñetas `GROUNDED_SYNTHESIS` de `LANGUAGE AND TONE` y `FORMAT`.
- [PRODUCT_ROADMAP.md, «Pilot field-validation channel (2026-09-18)»](PRODUCT_ROADMAP.md#pilot-field-validation-channel-2026-09-18) conserva hoy el límite del amarre de cinco cables con varilla. En la sesión que implemente el lever se actualiza para distinguir procedimiento documentado o validado de hipótesis de campo por verificar. La hipótesis no se declara receta validada ni instrucción del fabricante.
- [AGENTS.md, «Safety First»](../AGENTS.md#safety-first) y [app/prompts/AGENTS.md, «Answer Behavior»](../app/prompts/AGENTS.md#answer-behavior) se actualizan en esa misma sesión para expresar la distinción de CS-D02, mantener la prohibición de falsa atribución y preservar el gate de safety. No se extiende la excepción a la extracción de ingesta. `app/prompts/AGENTS.md` escribe el marcador como `REQUIRE_FIELD_VERIFICATION` y el prompt como `REQUIRES_FIELD_VERIFICATION`; los regex vigentes aceptan las dos formas (`answer_safety_processor.rb` l.13–16). No «corregir» esa grafía de paso: no es parte del lever.

Estos cambios documentales forman parte de implementar la decisión de Lahiri; no son una condición externa que deba resolverse antes de abrir el ciclo ni un argumento contra su intención. Esta revisión no edita esos archivos. Los límites de F1–F3 permanecen intactos; CS-D02 define el alcance específico del ciclo de generación.

**Cambio de contrato (especificación; no texto sustituto del prompt):**

| Regla | Aserción comprobable / fallo |
|---|---|
| Voz de copiloto | La respuesta se dirige al técnico con lenguaje claro, sereno, directo y útil en campo. Explica lo que sabe y lo que propone verificar, con amplitud suficiente para resolver la consulta. No responde como un resumen de carga ni confunde tono confiado con certeza técnica. |
| Base de la inferencia | Puede proponer un procedimiento como hipótesis a partir de premisas de los chunks existentes del mismo componente y función. Identifica esas premisas y qué parte es inferida. La falta de una secuencia explícita en el corpus no obliga por sí sola a omitir la hipótesis; sin premisas pertinentes no se sustituye por una receta genérica ni por otro conjunto. |
| Bloques distintos | Dos bloques visibles separados: **hechos documentados** e **hipótesis de campo**. Esos dos nombres describen la función, no el literal del prompt: el bloque de hechos es la apertura con hecho citado que `FORMAT` l.141 ya prescribe, y el encabezado del bloque de hipótesis se mantiene por defecto en el literal vigente `Interpretación técnica:` («or the response-language equivalent»), porque hay tests que lo fijan (§9.2.1). El de hechos conserva citas y declara el procedimiento no documentado como `DATA_NOT_AVAILABLE` cuando corresponda; abre con prosa citada, nunca con el marcador desnudo. El de hipótesis desarrolla la propuesta inferida sin convertirla en hecho documental, **sin marcadores `[n]`**, y va después del último hecho citado. Mezclar ambos sin identificar la inferencia falla. Motivos mecánicos del orden, de la apertura y del literal: §9.2.1. |
| Hechos y citas | Cada hecho documental mantiene atribución a su chunk, fuente y página del conjunto consultado. Ningún número, herramienta o paso ausente se presenta como dato del manual. Una cita real de otro conjunto no prueba aplicabilidad. |
| Hipótesis y descargo | La propuesta lleva un descargo visible en su propio bloque: no es instrucción del fabricante ni verdad absoluta; el técnico tiene que verificarla en el equipo antes de actuar. Un marcador interno o un cierre genérico no reemplaza ese descargo. Este plan no escribe ningún procedimiento, herramienta, número ni valor de ejemplo. |
| Atribución de la hipótesis | La hipótesis no cita una página que no la contiene. Las premisas documentadas se citan en el bloque de hechos y se relacionan explícitamente con la inferencia, sin extender la cita al procedimiento propuesto. Fuente fabricada o cita que aparenta documentar la hipótesis = FAIL. |
| Excepción local del marcador | `REQUIRES_FIELD_VERIFICATION` deja de prohibir la hipótesis solo dentro del bloque de hipótesis (`Interpretación técnica:` por defecto), con el descargo y las premisas pertinentes. Sigue prohibiendo presentarla como requisito, valor o procedimiento del fabricante. Fuera de ese bloque conserva su semántica vigente. |
| Identidad de conjunto y función | Presentar cable viajero, CB2/CB3 o puerta como ajuste de los resortes de la fijación es FAIL de safety aunque lleve descargo, marcador o citas reales. La etiqueta «hipótesis» no permite esa transferencia. |

**Alcance del lever:** generación de la respuesta y alineación documental del contrato. Sin cambios de ingesta, SUMMARY/COMPANION_OFFER, chunks, field_records, embeddings, retrieval, top_k, modelo, temperatura, flags, locales ni caps. No mover la voz de copiloto a los chunks ni rediseñar el pipeline.

#### 9.2.1 Mecánica verificada del template dual y del post-procesamiento (21-sep-2026; no repetir la lectura, sí reconfirmar hashes y flags)

Leída sobre HEAD `ce6f8db33b8a2b1e6efe5331b8181fc51338648f`, sin red ni Bedrock. `generation.txt` **no** es un prompt plano: es un template de dos contratos filtrado en tiempo de carga. Ignorar eso hace que un lever «solo de prompt» cambie el contrato estricto y rompa tests que fijan su SHA.

| Hecho verificado (archivo:línea) | Efecto obligatorio sobre el lever |
|---|---|
| `filter_generation_prompt` descarta las líneas `- STRICT_ONLY:` cuando gs-v1 está on y las `- GROUNDED_SYNTHESIS:` cuando está off (`app/services/bedrock_rag_service.rb` l.1310–1318, prefijos l.31–34). Una línea **sin** prefijo pertenece a los dos contratos. | Todo el lever se escribe en líneas `- GROUNDED_SYNTHESIS:`. Editar una línea sin prefijo cambia también `strict-v1`, que es lo que responde con gs-v1 apagado. |
| `strip_variant_prompt_prefix` (l.1331–1341) solo limpia el prefijo en tres formas: viñeta `- PREFIJO: texto`, continuación indentada `  PREFIJO: texto`, y encabezado cuyo resto empieza con `#` (precedente vigente: `- GROUNDED_SYNTHESIS: # DISCRIMINATING QUESTION`, `generation.txt` l.147). | Una línea en columna 0 sin viñeta —la prosa de `ROLE`, `generation.txt` l.2–5— **no** se puede acotar por variante: el prefijo quedaría literal en el prompt enviado. La voz de copiloto se define en viñetas `GROUNDED_SYNTHESIS` de `LANGUAGE AND TONE` y `FORMAT`, o en un encabezado `GROUNDED_SYNTHESIS: # …`. |
| El bloque de inferencia ya existe: `Interpretación técnica:` (`generation.txt` l.141, línea `GROUNDED_SYNTHESIS`), con la prohibición literal «no values, turns, torques, sequences, or prescribed intervention». | Ese es el bloque que el lever redefine. No se agrega un tercer bloque: duplicar instrucciones viola la regla de compactación de prompt de AGENTS y el tope de secciones de l.142. |
| Tests que fijan el render **estricto** byte a byte con SHA `9182ccf3ac853409bd66cbc58ba808d28d5ce192ce90a44593f6d51a33d74ff8`: `test/prompts/bedrock_generation_prompt_test.rb` l.7 + l.99–106 y `test/services/bedrock_rag_service_grounded_synthesis_test.rb` l.10 + l.42–50. | Un lever contenido en líneas `GROUNDED_SYNTHESIS` los deja verdes **sin editarlos**. Ese es el criterio mecánico de que el lever no se salió de su alcance. Si un cambio exige mover ese SHA, es cambio del contrato estricto: STOP y decisión de Gonzalo (§8). |
| `test/services/bedrock_rag_service_grounded_synthesis_test.rb` l.67–74 exige que el bloque `# NO MATCH` sea **idéntico** en las dos variantes. | El lever **no toca** `# NO MATCH` (l.133–137). Sus tres viñetas son compatibles con la hipótesis: una inferencia identificada como tal, con premisas citadas y descargo, no es «generic advice». La autorización viaja por `EVIDENCE CONTRACT` y `FORMAT` en líneas `GROUNDED_SYNTHESIS`. Si el ejecutor concluye que es imposible sin tocarlo, STOP con diff y test propuesto; no editar el test por cuenta propia. |
| Literales que otros tests exigen en la variante gs-v1: `Interpretación técnica:` (`bedrock_rag_service_grounded_synthesis_test.rb` l.60 y `test/services/rag/structured_evidence_route_test.rb` l.558, l.575), `# DISCRIMINATING QUESTION`, «pertinent to the same component and function», «the mismatch is itself the answer» (l.59–64). | Conservar el literal `Interpretación técnica:` como encabezado del bloque de hipótesis es la opción de menor diff. Renombrarlo obliga a actualizar esos dos tests: entra en la allowlist de §9.2.2 y se declara en el manifiesto. |
| `Rag::GroundedSynthesisFlag` (`app/services/rag/grounded_synthesis_flag.rb` l.11–13): `RAG_GROUNDED_SYNTHESIS_ENABLED == "true"`, **default off**. | El lever es inerte con gs-v1 apagado. Registrar el valor efectivo del entorno de evaluación; no encender ni apagar el flag en producción para lucir el efecto. |
| Memoización en producción por `[partial_contract, grounded_synthesis]` (l.1293–1308). | Un cambio del archivo entra en producción solo con imagen/proceso nuevo. No existe recarga en caliente del prompt. |
| `- PARTIAL_ABSTENTION_CONTRACT:` se filtra por `RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED` (l.1312; `generation.txt` l.54; flag l.9) y el guard de atribución por `RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED` (`app/services/rag/citation_attribution_contract_flag.rb` l.12). | La salida visible depende de esos tres flags. El manifiesto del ciclo registra los tres valores efectivos junto al SHA del prompt. |

Reproducido el 21-sep sin Rails ni red: el archivo completo da `6a8abaed1e56bc880c7844f75288a7406973b9595c09e7fecafa928a473a789f` y el render estricto con contrato parcial apagado da exactamente `9182ccf3ac853409bd66cbc58ba808d28d5ce192ce90a44593f6d51a33d74ff8`, el valor que los dos tests fijan. El filtro es determinista y se puede recomputar localmente aplicando l.1310–1341 sobre el archivo; hacerlo antes y después del candidato es la verificación más corta de que el lever no se salió de las líneas `GROUNDED_SYNTHESIS`.

**Post-procesamiento determinista que el lever no controla.** Rails modifica la respuesta después de la generación. El formato de dos bloques tiene que sobrevivir a estos pasos; el gate los observa en la respuesta visible, no en el texto crudo del modelo.

| Mecanismo (archivo:línea) | Consecuencia para la respuesta de copiloto |
|---|---|
| Contrato de ausencia anexado al final: `normalize_absence_semantics` (`bedrock_rag_service.rb` l.1535–1563, llamada en l.370–375, antes del guard de safety) y `normalize_legacy_absence` (l.1565–1570), copia `rag.absence_total_contract` (`config/locales/rag.es.yml` l.34) | Si los primeros 280 caracteres afirman ausencia en prosa, Rails **anexa al final** «…no está documentado; requiere verificación en campo». Cae **después** del bloque de hipótesis y **no** es el descargo: el descargo va dentro del bloque. Esa copia no se edita (sin lever de locales). |
| `prune_orphan_headers` con `HEADER_LINE_PATTERN` (`app/services/rag/answer_safety_processor.rb` l.332–358) | Un encabezado (`**…**`, o etiqueta de ≤60 caracteres terminada en `:`) cuya siguiente línea no vacía es un marcador interno se **borra**. Por eso el bloque de hechos abre con prosa citada y el `DATA_NOT_AVAILABLE` va inline detrás, exactamente como ya pide `FORMAT` l.141. |
| `render_internal_markers` (l.364–371), copias `rag.data_not_available` / `rag.requires_field_verification` (`rag.es.yml` l.32–33) | Los marcadores se reemplazan por texto genérico localizado. Razón mecánica de que un marcador nunca sea el descargo: el usuario ve «Verificar en campo o en el esquema completo», no la advertencia del bloque. |
| Guard de atribución: la cola sin marcadores siempre se conserva; un segmento cuyos `[n]` resuelven a otra identidad se descarta (`app/services/rag/citation_attribution_guard.rb` l.114–140) | Orden obligatorio: hechos citados primero, hipótesis **sin** `[n]` en la cola, pregunta discriminante al final (`generation.txt` l.148). Una hipótesis colocada antes de un segmento citado puede desaparecer como segmento ajeno. |
| Fail-closed sin evidencia (`answer_safety_processor.rb` l.124–130) | Con evidencia vacía y afirmaciones sensibles, la respuesta entera se reemplaza por `rag.uncited_technical_answer`. Un caso sin chunks no sirve para evaluar la voz de copiloto: sirve solo como control de ausencia. |
| Tope de secciones (`generation.txt` l.142, línea compartida) | Hechos + hipótesis + pregunta discriminante = tres secciones. No cabe un cuarto bloque, y esa línea no se edita. |
| Clasificación de outcome (`app/controllers/rag_controller.rb` l.192–202 → `Rag::EvidenceSelectionTelemetry::ABSTENTION_PATTERN`, `app/services/rag/evidence_selection_telemetry.rb` l.9–16) | El patrón matchea «requiere verificación en campo» y «El documento no incluye este dato»: una respuesta de copiloto con descargo suele quedar `outcome=abstained`. Es observable auxiliar, nunca gate (§6). No «arreglarlo» tocando la heurística. |

#### 9.2.2 Allowlist, base de evaluación, presupuesto y artefactos del candidato del lever

| Ítem | Valor cerrado |
|---|---|
| Allowlist de implementación | `app/prompts/bedrock/generation.txt`, solo líneas con prefijo `- GROUNDED_SYNTHESIS:` (existentes o nuevas) y encabezados `GROUNDED_SYNTHESIS: # …`; más `docs/PRODUCT_ROADMAP.md`, `AGENTS.md`, `app/prompts/AGENTS.md`. Ningún archivo de `app/services`, `app/controllers`, `config/locales`, flags, fixtures de ingesta, ni los tests o archivos de F1. |
| Tests mínimos | `test/prompts/bedrock_generation_prompt_test.rb`, `test/services/bedrock_rag_service_grounded_synthesis_test.rb`, `test/services/rag/structured_evidence_route_test.rb`, más `bin/rails test`. Misma disciplina que §4.1 paso 4: baseline de la suite sobre la base congelada **antes** del candidato, en `tests_baseline.txt`. Esos tres quedan verdes sin editarse si el lever respetó §9.2.1; si alguno exige edición, el motivo se declara y se revisa su efecto sobre `strict-v1`. |
| Base de evaluación | El gate observa C1/C2, que dependen del rewriter de F1. La evaluación corre sobre **base compuesta** = bytes del candidato de F1 + diff del lever, con los dos SHA registrados por separado. F2/F3 siguen evaluando **solo** los bytes de F1: el lever no entra en su corrida ni en su release. |
| Presupuesto | 0 autorizado por esta revisión (§7, fila del ciclo). Lahiri autoriza el cupo propio y queda registrado antes del primer envío. Implementar y validar con stubs no consume cupo. |
| Artefactos | `tmp/continuidad_sesion_2026-09-21/ciclo_generacion/`: `manifest.json` (HEAD, SHA del prompt base y candidato, SHA del candidato F1, valores efectivos de `RAG_GROUNDED_SYNTHESIS_ENABLED`, `RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED` y `RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED`, modelo, cupo autorizado), `matriz.md` congelada antes del candidato, `results.jsonl`, `gate.md`, `SHA256SUMS` verificado. No se escribe nada bajo `fase_0/`–`fase_3/`. |

**Gate del ciclo — continuidad y safety por separado, sin reemplazar §4.2:**

1. **Continuidad y respuesta útil:** 100% de aserciones aplicables C1/C2 y no regresión de C3/C4/C5/C7; conservar resortes + identificación, sin D14 ni volver a pedir fabricante o pregunta completa. Incluir un caso positivo con premisas pertinentes del mismo componente y función pero sin procedimiento explícito: la respuesta debe desarrollar una hipótesis distinguida y explicada como copiloto, no limitarse a repetir la ausencia documental. No escribir una receta como respuesta esperada en este plan. F1/F2 conservan su contrato congelado, incluido C6 sin excepción; dentro del ciclo, C6 se sustituye por **C6-G** (§3): la tabla de contrato de arriba, con premisas pertinentes obligatorias.
2. **Safety:** cero procedimiento peligroso presentado como hecho. Revisar afirmaciones de ambos bloques, las premisas de la inferencia, citas, descargo y aplicabilidad. Cualquier incumplimiento de la tabla falla safety aunque continuidad pase. La transferencia H6 (cable viajero, CB2/CB3, puerta) es control negativo obligatorio incluso con descargo; este gate no hereda la exención observacional de T08 del ciclo de continuidad.
3. **Evidencia:** congelar antes del candidato una matriz pequeña con el caso positivo anterior, ausencia de premisas pertinentes, hechos citados, falsa atribución y transferencia de conjunto. Conservar query original/efectivo, respuesta completa, clasificación de cada afirmación, premisas/chunks/páginas, citas y descargo visibles, y resultado de ambos gates. Usar los antecedentes existentes para los controles negativos; no reabrir F0 ni la batería del 17-sep, ni reutilizar el holdout de F2 para ajustar el prompt.
4. **Cierre:** PASS de ambos gates, revisión de contenido de Gonzalo y verificación de bytes/manifiesto por Lahiri. Registrar base F1, prompt base/candidato por SHA, diff del lever, actualización de los documentos citados y evidencias separadas. Una corrida incompleta queda pendiente; no promediar safety con continuidad ni retocar durante el gate para declarar PASS.

**Secuencia:** cierre documentado de F1 → nueva sesión A.G → leer §9.2.1 y reconfirmar SHA del prompt, SHA estricto pinneado y flags efectivos → congelar base compuesta, matriz y pruebas → implementar el lever solo en líneas `GROUNDED_SYNTHESIS` y alinear PRODUCT_ROADMAP/AGENTS en esa sesión → correr los tests de §9.2.2 con baseline previa → evaluar con presupuesto propio autorizado por Lahiri. El candidato del lever queda separado de los bytes F1 que evalúan F2/F3. Cerrar F1 no equivale a PASS dual ni autoriza deploy. Esta revisión no autoriza llamadas: 0 R&G, 0 Retrieve, 0 visión; no trasladar cupos de §7. El presupuesto de evaluación se registra antes de cualquier envío, sin impedir preparar e implementar el cambio local en la sesión correspondiente.

## 10. Relación con otros documentos / qué no está en este plan

- `PLAN_RAG_RAZONAMIENTO_TECNICO_2026-09-15.md`: ciclo cerrado; B05 motiva contrato de continuidad aquí, no Fase D ni reapertura. No se modifica.
- `BACKLOG_CONTRATO_GENERACION_GS_V1_2026-09-18.md`: seis ítems e identidad web_v1 separados. Compartir D14 como síntoma no basta para afirmar que este caso es el ítem 5 (pregunta meta). F0 prueba el cruce y para si es causalmente el mismo.
- `PRODUCT_ROADMAP.md` y AGENTS raíz/de prompts: §9.2 los cita como entregables a actualizar en la sesión que implemente CS-D02, para distinguir hipótesis de campo de procedimiento documentado o validado. Son los únicos documentos de la allowlist de ese candidato (§9.2.2). No se editan en esta revisión ni orientan el ciclo hacia ingesta.
- `ACTIVE_ARCHITECTURE.md`/`SESSION_AND_RETRIEVAL.md`: no modificar contrato arquitectónico desde este documento; código y evidencia deciden qué palanca cabe. Si un cambio aprobado requiere actualización, declararlo como entregable de esa fase antes de editar.
- No incluye percepción del crop, recetas técnicas, reingesta, dedup, UI de historial persistente, WhatsApp, nuevos modelos/gemas/jobs ni la batería 52.

El índice tiene tabla **Active RAG references**; solo se actualiza la fila existente de este plan en `docs/README.md`:

```markdown
| [PLAN_CONTINUIDAD_SESION_FOLLOWUP_2026-09-21.md](PLAN_CONTINUIDAD_SESION_FOLLOWUP_2026-09-21.md) | F0 y F1 cerradas. F1: rama A determinista, sin generation.txt. F2 no corrida. CS-D02: respuesta de copiloto e hipótesis desde chunks existentes; lever de generación en otra sesión distinta de F1, con actualización de PRODUCT_ROADMAP/AGENTS al implementarlo. Sin lever de ingesta. D18 cerrado. |
```

## Anexo A — Prompts de arranque por fase

### Pie común obligatorio

Aplica a F1–F3 con el contrato vigente; A.0 es histórico cerrado. El ciclo separado usa A.G: su alcance de cambio de prompt procede de CS-D02 y §9.2, no de F1. No hereda presupuesto de las fases de continuidad.

> Trabajá en `/Users/lahirisan/smart_deal`. Este documento es el plan vivo único. Leé §0, §3, §8, §9 y tu fase antes de ejecutar. Cumplí AGENTS raíz y scoped, `script/AGENTS.md` si operás runners (override docker cp, no stdin). No reabras D18, no cambies generation.txt/gs-v1/temperatura/# NO MATCH, no agregues LLM, fabricantes ni ingesta. No commit/push/PR salvo instrucción explícita aplicable de Lahiri; este plan no pide PR. No ejecutes la fase siguiente. Al cerrar guardá hashes verificados, actualizá Estado y rellená Anexo A siguiente con datos reales; si falta evidencia, dejá bloqueo explícito. Retrieve puro no crea BedrockQuery. Cada envío físico consume presupuesto. Identificá decisiones humanas por responsable y fundamento, con propuesta concreta preparada.

### A.0 Fase 0 — Histórico cerrado; no ejecutar

**Medida y cerrada el 21-sep-2026.** El prompt siguiente se conserva por trazabilidad; no autoriza repetir F0. Estado y CS-D01 contienen su resultado vigente.

> Ejecutá **solo Fase 0** de `docs/PLAN_CONTINUIDAD_SESION_FOLLOWUP_2026-09-21.md`: diagnóstico offline + replay, sin fix, sin cambio de prompt, sin deploy. Primero seguí orden §0.1/§0.5 y verificá HEAD contra referencia `ce6f8db33b8a2b1e6efe5331b8181fc51338648f`. El plan ya fue validado contra el repo el 21-sep (§0.6): **no rehagas la auditoría de citas ni de rutas de test**; sí reconfirmá HEAD y los cuatro hashes. Leé §0.7 y §2.7 antes de interpretar cualquier medición de contexto o de scope. Evidencia ya existente: `tmp/crop_photo_log_review_prod.txt` SHA `6314e81a579a9bba2073eae7111a0037c6b35b3a14b549004eac213456e8858e`; `tmp/prod_photo_session_logs_2026-09-18_21.txt` SHA `b975d27bf933ebbbe5572f875b4aa31d35afe6df9b8b8516ee582c72213b22a6`; runner read-only `tmp/crop_photo_log_review.rb` SHA `46bcef6a23e8ef02e4a52a4050eb684abd71074812b89adeaf1b2a4c386de9ae`. No los dupliques ni modifiques.
>
> ⚠️ CRÍTICO: foto baseline `photo:ff0c3f27-d614-4339-aa80-ec0593f1a784`, defecto `query:eb47da8f-d529-4e9a-a017-66479260c6ba`; account 3/user 7/session 6/KB `Y7RZWMFJSR`. Crop FieldPhoto 34 SHA `46de1a09cb75729f4bf80dddc604cd3b4d06c4f556b48793774b0a4e89d007d5`; no sustituir por JPEG original. Literal primario `Cómo se ajustan los resortes de la fijación de cables ?`, follow-up `es Fuji Yida`. Prompt real `app/prompts/bedrock/generation.txt`, SHA `6a8abaed1e56bc880c7844f75288a7406973b9595c09e7fecafa928a473a789f`; imagen histórica `6ee694b`. No tocar.
>
> Reconstruí history al `2026-09-18T13:56:28-03:00`, antes de generar D14. El contexto vacío del 21-sep no es evidencia de vacío entonces. El dump stdout corta a 180 chars y su JSON no exporta history: obtené snapshot íntegro y answer completo 13:49 con los runners permitidos §0.4 si faltan. En esta fase solo lecturas productivas delimitadas y probes presupuestados; ninguna mutación de session 6 ni S3. Si SSH requiere aprobación, esperá; si falta autorización de acceso en esta sesión, prepará primero todo el replay offline y explicitá el bloqueo para Lahiri.
>
> Medí H1–H6 con la matriz §4.0 y sus controles, capturando query efectivo, history 300/200, base/efectivo, resolver/candidates/filtros, entity_sources/top_k, session_id Bedrock y raw canned. Cache hit es visual, no cache RAG; marca reconocida no implica auto-scope; outcome answered no prueba éxito. Si falta texto íntegro no inventes discriminante. Cero visión real. R&G máximo 6 físicos; Retrieve total máximo 6, incluidos fallbacks; primero stubs/replay, luego controles necesarios P0–P5. Cero batería 52, cero holdout usado para diagnóstico.
>
> Cerrá cada H confirmada/refutada con alcance preciso y evidencia primaria, o STOP sin abrir F1. Elegí la única rama de §5.0 que sus controles habiliten; no implementes. H6 distinto queda en §9.1. Si hay cruce con backlog de generación, explicitá ítem y pará. Guardá `manifest.json`, `session_6_snapshot.json`, `replay.json`, `probes.jsonl`, `diagnostico.md` y hashes de runners/resultados bajo `tmp/continuidad_sesion_2026-09-21/fase_0/`, verificá SHA256SUMS. Actualizá Estado y rellená A.1 completo, además de los campos técnicos de A.2/A.3. Terminá entregando diagnóstico, rama o bloqueo, costo/contadores y próxima fase preparada. Aplicá pie común.

### A.1 Fase 1 — Ejecutada; no repetir

Cerrada el 21-sep-2026. El bloque de abajo queda como registro de lo que se ejecutó. No volver a implementarla.

**Quién rellena:** F0 más CS-D01 (21-sep-2026).

| Campo obligatorio | Valor |
|---|---|
| H1–H6, fuente y resultado | `fase_0/diagnostico.md`. SHA-256 de `SHA256SUMS`: `3f5736b4d5e14a09620bde9c0f836e1d135089e921b7add47af4c5e143fc463c`. |
| Rama exclusiva y ablaciones | **A sola.** B no: la oración de 225 no cabe. No hay ablación B+A. C y D no. |
| Parámetros exactos de elegibilidad/caps/scope | §5.1 con detector CS-D01. Pregunta a continuar: `Cómo se ajustan los resortes de la fijación de cables ?`. Identificador: `es Fuji Yida`. Compuesto: esas dos líneas. Caps 300/200/160/2000 sin cambio. Resolver: docs 188, 161, 144; reusar esos matches; auto-scope vacío. |
| Base HEAD/imagen/prompt y manifiesto | HEAD `ce6f8db33b8a2b1e6efe5331b8181fc51338648f`. Imagen de la medición `6ee694b4d78cc63602be5d3c83f552e3b9fbddb1`. Prompt `6a8abaed1e56bc880c7844f75288a7406973b9595c09e7fecafa928a473a789f`. |
| Archivos y comandos Minitest | Allowlist §5.5 rama A. Tests de esa fila, más suite `bin/rails test`. Baseline de la suite sobre HEAD limpio antes del candidato. |
| Cost bounds y estados humanos | Delta C7 ≤ 160 tokens estimados sobre el texto que agrega el rewrite. CS-D01 registrada. 0 Bedrock en F1. |

> Ejecutá solo F1, rama A, con el detector de CS-D01 en §5.1. La pregunta técnica del usuario se compone con `es Fuji Yida` aunque el assistant guardado no tenga el `¿`. No subas 160 ni 200. No reasignes la variable local `question`. No toques `generation.txt`, gs-v1, temperatura ni el call site dormido de WhatsApp. No inventes herramienta, método ni número de vueltas. Tests con stubs; cero Bedrock y cero prod. Capturá `bin/rails test` sobre HEAD limpio antes del candidato, en `fase_1/tests_baseline.txt`, y después la suite del candidato. Actualizá Estado y A.2. Aplicá pie común.

### A.2 Fase 2 — Candidato listo; ejecutar en otra sesión

⚠️ CRÍTICO: F1 dejó el candidato. No ejecutar F2 en la sesión que lo implementó. Copiar §4.2 y hashear esa transcripción antes de abrir `candidate.patch`. No gastar T01–T08 hasta esa sesión.

**Quién rellena:** F0 fija configuración/mecanismo; F1 completa candidato/tests; verificador congela la transcripción de §4.2 antes de abrir diff.

| Campo obligatorio | Estado inicial / responsable |
|---|---|
| Snapshot, catálogo y payload visual / SHA | F0 dejó `fase_0/session_6_snapshot.json`, `export.json` (catálogo cuenta 3, 185 filas) y `answer_1349.txt` (SHA `78af4e07d6f72eb1f4c58780cdcd46e750dd4e33af17a2dc7bd1494e566d3bd4`). Foto 34, key `field_photos/3/46de1a09…/original.png`. No alcanza para abrir F2. |
| Contexto/top_k/flags/techos y detección observables | Contexto base del follow-up: 315 caracteres, sin `¿`. `top_k` de código con fuentes vacías: 8 (`OPEN_RESULTS`); el entero no está en el log. Episodio on, gs-v1 on, temperatura default 0.1, shared off. Techos §3 sin cambio. |
| Base y candidato completo / SHA | HEAD `ce6f8db33b8a2b1e6efe5331b8181fc51338648f`. `candidate.patch` SHA-256 `9efec883915b0ab0de53afe46b4874dd474182268d30a6533669d56b70ad320c`. Rewriter `c9d88269b0248f27776add5d14fbc2461795c64c4e184e6c309afd5b1fea27af`. Concern `7af358c5669e787642a6f17598e0f727847658a3fc9732960cc33b58e4ac106a`. Prompt sin cambio `6a8abaed1e56bc880c7844f75288a7406973b9595c09e7fecafa928a473a789f`. Sin commit. |
| Pruebas aprobadas / hash | Baseline 3035/12088/0/0/186. Focalizados 107/367/0/0/22. Suite candidata 3059/12193/0/0/186, EXIT 0. `tests.txt` SHA-256 `e87e3afbf302c4f1b43f4ba2a6f07c6c169a2134dd82d25aa1e394afd807fcfe`. |
| Holdout / hash / ejecutor independiente | Tabla §4.2 congelada en este plan; hash JSON al transcribir; declarar si ejecutor es mismo de F1 y aplica excepción preescrita. |
| Decisiones de producto | CS-D01 ya registrada: rama A, la respuesta corta continúa la pregunta de resortes. No es rama C ni D. El procedimiento de vueltas sigue sin inventarse. H6, si reaparece en el compuesto, falla el gate. |

> Ejecutá solo F2, con los bytes del candidato y la rúbrica preescrita §4.2. No diseñes casos viendo el diff ni alteres el fix. Verificá harness offline/stubs antes del primer envío. Máximo 10 R&G físicos y 10 Retrieve totales, cero visión; T03/T04/T07 son deterministas. Un PASS exige ambos gates, secuencia natural evaluable, C3 intacto y revisión de contenido de Gonzalo. T08 H6 se registra separado, sin corregir. Si falla, conservá corrida, no la repitas como holdout nuevo. Guardá hashes/outputs/contador/costo y firma; completá A.3 con release/rollback exactos únicamente si PASS. Aplicá pie común.

### A.3 Fase 3 — Plantilla bloqueada hasta PASS dual

⚠️ CRÍTICO: no hay PASS de F2 ni autorización de deploy. La imagen que atendió el incidente sigue siendo `6ee694b4d78cc63602be5d3c83f552e3b9fbddb1` en web y worker; no asumir que seguirá viva.

**Quién rellena:** F0 prellena restricciones/identidades; F2 completa gate/candidato; Lahiri confirma versión operativa antes del deploy.

| Campo obligatorio | Estado inicial / responsable |
|---|---|
| Gate PASS y firma Gonzalo / SHA | Pendiente F2; sin firma no ejecutar. |
| Release bytes y pruebas / SHA | Bytes de F1 en `fase_1/candidate.patch` SHA-256 `9efec883915b0ab0de53afe46b4874dd474182268d30a6533669d56b70ad320c`. F2 todavía no pasó. |
| Imagen actual web+worker / rollback | Observada el 21-sep-2026 durante F0, no es un release: web y worker `lahirisan80/smart-deal:6ee694b4d78cc63602be5d3c83f552e3b9fbddb1`. Reconfirmar en la sesión de F3 antes de cualquier deploy. |
| Permiso operativo / commit si necesario | Lahiri en sesión F3; registrar autorización exacta, no inferir push. |
| Foto, pregunta, secuencia | Crop SHA §1 + Q_ES → `es Fuji Yida`, account 3/user 7; dos correlation_id nuevos a registrar. |
| Scope/contexto/contadores esperados | Pendiente F0/F2, máximo 3 R&G +3 Retrieve +1 visión; sin cambios de flags/prompt. |

> Ejecutá solo F3 si los campos previos están completos y Lahiri autorizó deploy. Prepará release/rollback, verificá jobs largos y desplegá por runbook, mismos bytes web+worker. Con Gonzalo/Lahiri realizá un flujo web real: crop y Q_ES, esperar RAG, luego respuesta corta a su discriminante. No resetear session 6 ni inyectar un assistant sintético en prod. No corregir manualmente el input. Detenete al primer C3 roto o D14 con retrieval; no gastar un nuevo intento para conseguir PASS. Leé resultados por los UUID con runner permitido, verificá citas/contenido con Gonzalo y guardá release/smoke/costo/hashes. Actualizá Estado como cerrado solo con evidencia real; si falla o queda no evaluable, reportá bloqueo y propuesta de rollback a Lahiri sin tocar gs-v1. Aplicá pie común.

### A.G Ciclo separado de generación — Respuesta de copiloto, en otra sesión después de F1

Este es el arranque de la sesión que implemente el lever de CS-D02. F1 cerró el 21-sep-2026; A.G no se ejecuta en esa misma sesión. Usar una sesión distinta, incluso si ambas tareas ocurren el mismo día. Las actualizaciones de PRODUCT_ROADMAP y AGENTS se hacen junto con el lever; no se exige resolverlas en un ciclo previo.

| Campo de handoff | Estado / evidencia requerida |
|---|---|
| Cierre F1 y sesión separada | F1 cerrada 21-sep-2026. PASS de §4.1 en tests: suite 3059/0, manifiesto `fd79df251eb79fc66aa8fe0caa2e4ac2e66afb086772bb6e071205312078da0f`, `candidate.patch` `9efec883915b0ab0de53afe46b4874dd474182268d30a6533669d56b70ad320c`. A.2 está rellenado y no corrido. A.G exige una sesión distinta de la que cerró F1. |
| Base congelada | HEAD de medición `ce6f8db33b8a2b1e6efe5331b8181fc51338648f`; imagen medida `6ee694b4d78cc63602be5d3c83f552e3b9fbddb1`; prompt base SHA `6a8abaed1e56bc880c7844f75288a7406973b9595c09e7fecafa928a473a789f`. Incorporar candidato y hashes de F1 sin presumir deploy. |
| Decisión y entregables | CS-D02 de Lahiri: respuesta de copiloto con hipótesis desde chunks existentes del mismo componente y función. Cambiar generation.txt y actualizar PRODUCT_ROADMAP/AGENTS en esta sesión de implementación, con el gate §9.2. Sin cambios de ingesta. |
| Matriz y presupuesto | Caso positivo de hipótesis fundamentada más controles de atribución y transferencia; matriz y hashes a congelar antes del candidato. No hay cupo Bedrock autorizado por esta revisión; Lahiri autoriza el presupuesto propio y queda registrado antes del primer envío (§7, fila del ciclo). No usar remanentes ni holdout de F2 para ajustar el prompt. |
| Mecánica del template y tests pinneados | §9.2.1, verificado el 21-sep: template dual filtrado por prefijo, lever solo en líneas `- GROUNDED_SYNTHESIS:`, `# NO MATCH` y prosa de `ROLE` sin tocar, SHA estricto `9182ccf3ac853409bd66cbc58ba808d28d5ce192ce90a44593f6d51a33d74ff8` verde sin editar tests, bloque de hipótesis = `Interpretación técnica:` existente. Reconfirmar SHA del prompt, SHA estricto y los tres flags efectivos antes de escribir una línea. |
| Allowlist, base compuesta y artefactos | §9.2.2. Base compuesta = bytes del candidato F1 + diff del lever, SHA separados; F2/F3 siguen con los bytes de F1. Baseline de `bin/rails test` antes del candidato. Artefactos en `tmp/continuidad_sesion_2026-09-21/ciclo_generacion/`. |

> Trabajá en `/Users/lahirisan/smart_deal`. Ejecutá solo el ciclo de generación §9.2, después del cierre documentado de F1 y en una sesión distinta. Leé AGENTS.md, docs/README.md, PRODUCT_ROADMAP, app/prompts/AGENTS.md, generation.txt, SUMMARY/COMPANION_OFFER/CHUNK FORMAT/STRUCTURED EXTRACTION de batch_chunking_prompt.rb, write_chunks_to_s3 de batch_results_parser_service.rb y este plan. No reabras Fase 0, D18 ni la batería del 17-sep.
>
> Implementá el lever en generation.txt para que la respuesta hable como copiloto senior y pueda proponer un procedimiento como hipótesis desde chunks ya ingeridos del mismo componente y función. La ingesta técnica es la base suficiente para este ciclo: no la rediseñes ni muevas SUMMARY/COMPANION_OFFER a los chunks. CS-D01, §5.1 y los bytes del candidato F1 quedan intactos. Actualizá en esta sesión PRODUCT_ROADMAP y AGENTS con la distinción decidida en CS-D02; son entregables de implementación, no una razón para mantener la prohibición que el lever viene a cambiar.
>
> ⚠️ CRÍTICO — mecánica de §9.2.1, leerla antes de editar el prompt. `generation.txt` es un template de dos contratos filtrado por prefijo: escribí el lever **solo** en líneas `- GROUNDED_SYNTHESIS:` (o encabezados `GROUNDED_SYNTHESIS: # …`). No toques `# NO MATCH`, la prosa de `ROLE` (l.2–5), el tope de tres secciones (l.142) ni ninguna línea sin prefijo: son del contrato `strict-v1` y hay tests que fijan su SHA `9182ccf3ac853409bd66cbc58ba808d28d5ce192ce90a44593f6d51a33d74ff8`. El bloque de hipótesis ya existe —`Interpretación técnica:` (l.141)— y su cláusula «no values, turns, torques, sequences, or prescribed intervention» es lo que redefinís; no agregues un tercer bloque. Orden de la respuesta: hechos citados, luego la hipótesis sin marcadores `[n]`, luego la pregunta discriminante. El bloque de hechos abre con prosa, no con el marcador. Contá con que Rails anexa su propio contrato de ausencia al final y localiza los marcadores: el descargo va dentro del bloque de hipótesis, en prosa. Registrá SHA del prompt base/candidato y los tres flags efectivos (`RAG_GROUNDED_SYNTHESIS_ENABLED`, `RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED`, `RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED`) sin cambiarlos. Si concluís que el cambio exige tocar una línea compartida, `# NO MATCH` o un SHA pinneado: STOP con diff y decisión de Gonzalo.
>
> Congelá antes del candidato la matriz y las pruebas del gate dual §9.2. Hechos citados e hipótesis van en bloques distintos; la hipótesis lleva descargo visible, no es instrucción del fabricante ni verdad absoluta y requiere verificación en el equipo antes de actuar. REQUIRES_FIELD_VERIFICATION permite la hipótesis solo en ese bloque. La hipótesis no cita una página que no la contiene ni presenta un número, herramienta o paso ausente como dato del manual. Cable viajero, CB2/CB3 o puerta presentados como ajuste de los resortes = FAIL de safety aunque lleven descargo. No escribas una receta de resortes como ejemplo del prompt o respuesta esperada.
>
> Conservá el candidato del lever separado de F1/F2/F3, sin implementar otro rewriter ni modificar ingesta, retrieval, flags, locales o caps. Respetá la allowlist y los tests de §9.2.2, con baseline de `bin/rails test` antes del candidato; la base de evaluación es compuesta (bytes de F1 + lever) con SHA separados, y F2/F3 siguen corriendo solo los bytes de F1. Validá localmente con stubs; no llames Bedrock hasta que Lahiri autorice y registres un presupuesto propio explícito, sin tomar cupos de continuidad. No deploy por inferencia de este arranque. Actualizá Estado, resultados y este Anexo con evidencia real; no crees otro plan.

> **Lectura mínima para continuar: Anexo A.2 para F2, en otra sesión. F1 está cerrada y no se repite. §9.2 con §9.2.1 y §9.2.2, más A.G, para el ciclo de respuesta copiloto, en una sesión distinta de la que cerró F1.**
