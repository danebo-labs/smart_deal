# Plan quirúrgico: consultas de Jesús en producción

Fecha: 16-sep-2026. Estado: **cerrado.** Diagnóstico validado contra código (v2, 11:30). P0/P1 ya están en `main` (`4f883e0`, `332ac23`, `75dc8ff`, `474352c`). No reabrir ni re-correr la batería de sonda.

## Resultado

El servidor respondió las tres consultas, pero no encaminó la falla de la puerta. La causa principal identificada es la selección de fuentes: el plano Elemont fijado excluyó un manual CEA15 disponible en la misma cuenta. Se añaden pérdida de continuidad y recomendaciones de comprobación que no están sustentadas como procedimientos en los fragmentos citados.

Dos causas independientes, dos correcciones que deben ir juntas: la agregación de especificidad en el auto-scope (turno 1) y la ausencia de herencia del alcance en seguimientos sin designador (turnos 2 y 3). Corregir solo la primera deja al técnico exactamente donde está desde su segunda pregunta.

No corresponde empezar aumentando el modelo, `top_k` o flexibilizando todo el prompt. Primero hay que entregar al flujo existente la fuente pertinente y conservar el problema del técnico.

## Evidencia de producción

- Host: `elevator.danebo.ai`; cuenta `danebo-legacy`, `account_id=1`.
- Usuario: `jesus.graterol@danebo.ai`, `user_id=6`; sesión web 5.
- Imagen: `263b26ce8a37af334621ad013403534286363f1e`.
- Horarios: America/Santiago, UTC−03.
- Exportación oficial: `bin/pilot_metrics --from 2026-09-16 --to 2026-09-16 --account danebo-legacy --with-questions --format human`.
- Artefactos: `tmp/pilot_exports/2026-09-16_2026-09-16_danebo-legacy/`. Incluye dossier HTML, respuestas completas, CSV, JSON, eventos originales, manifiesto y SHA256SUMS verificado.
- Se leyeron 7 contenedores web/worker, sin contenedores ilegibles ni líneas inválidas. Las 3 interacciones exportadas pertenecen a Jesús y tienen respuesta completa y fragmentos auditados: 5, 3 y 3 respectivamente.
- La exportación marca la ventana diaria como `partial`: fue ejecutada a las 11:18, antes del fin del día. Esto no implica que falten las tres consultas investigadas. No se ejecutó validación `--strict` ni se verificó el render en el navegador del técnico.
- Evidencia adicional de solo lectura: `tmp/jesus_diagnostic_2026-09-16/{case,evidence,scope}.json` y `web_window.log`.

| Hora de pregunta | Consulta | HTTP / tiempo Rails | Resultado observado |
|---|---|---|---|
| 10:49:41 | Falla eléctrica Elemont, imanes y tarjeta CEA15 | 200 / 5,250 s | Declara que el plano no documenta CEA15; pide tres aclaraciones. |
| 10:50:55 | Puerta 1 no magnetiza bien para iniciar movimiento | 200 / 6,583 s | Reitera ausencia; añade tres supuestas verificaciones documentadas. |
| 10:51:54 | Elemont Montacargas Hidraulico Modelo MH | 200 / 8,253 s | Devuelve resumen general del equipo; no retoma la falla. |

Correlaciones, en el mismo orden:

1. `query:9e2568bf-70c4-476e-8891-584dc587e70b` — BedrockQuery 14155.
2. `query:b0ed8a78-5114-4cb1-878f-76283f3f34b0` — BedrockQuery 14156.
3. `query:96671a4e-5a64-44f8-9b6e-cbfcde18a072` — BedrockQuery 14157.

Las tres registran `forced=true`, un único documento, evidencia presente y `canned_with_retrieval=false`. No aparece un timeout ni una respuesta vacía en estas peticiones. `abstained=3` es la clasificación automática; no equivale a evaluación humana ni prueba que las tres respuestas carezcan completamente de contenido.

Evidencia adicional verificada el 16-sep (validación del plan):

- En `web_window.log` no existe ninguna línea `RagQueryConcern: auto-scope overrides pin` para los tres `POST /rag/ask`; confirma `question_wins=false` en los tres turnos.
- El pin de Elemont (`kb_document_id=213`) no es de hoy: la sesión 5 muestra el mismo envío del nombre del documento el 2026-08-31 17:30. El pin llevaba 16 días activo cuando llegó la primera pregunta del día (TTL deslizante de 30 días, `ConversationSession::EXPIRY_DURATION`). El `DELETE`/`POST /pinned_documents/213` de las 10:51:50–10:51:51 solo refrescó `added_at`.
- El historial de la sesión conserva 20 mensajes que mezclan agosto (SEGURIDADES, Excelsior, «Dónde puenteo las seguridades») y septiembre. Solo los últimos 3 entran al prompt; no hubo contaminación de agosto en estas respuestas, pero el estado existe.
- En el turno 2 el bloque `## Recent Conversation` sí contenía la primera pregunta con «Cea15» (el mensaje del usuario se agrega al historial antes de construir el contexto, `RagController#ask`). Aun así la recuperación fue solo Elemont: `input.text` de Bedrock es únicamente la pregunta actual. Esto prueba que agregar historial al prompt no cambia qué fragmentos se recuperan.
- En el turno 1 el bloque `## Query Resolution` listó `manual-cea15p` con la instrucción «Do NOT claim the document is not found», mientras la recuperación lo excluía. El modelo resolvió la contradicción preguntando «¿Tienes acceso al manual de la tarjeta CEA15?», documento que ya estaba en el catálogo.

## Hallazgos y grado de certeza

### H1. El manual relevante existe, pero queda fuera del filtro

Confirmado en catálogo de producción:

- Documento 213: plano Elemont, 9 chunks. Incluye PLC Mitsubishi MELSEC FX 3S; esto requiere comprobar compatibilidad con el controlador indicado por el técnico.
- Documento 207: `manual-cea15p.pdf`, alias `controlador ascensor CEA15`, ingestión `complete`, 122 chunks. El cuerpo identifica **CEA15+**. No asumir equivalencia entre CEA15, CEA15P y CEA15+ sin confirmar la placa/revisión.
- Documento 205: CEA51FB; no es sustituto de CEA15.

Se reconstruyó el resolver en producción con la pregunta literal. Devuelve Elemont por `Elemont`, CEA15 por `Cea15` y un manual de montacargas no pertinente por `eléctrica`.

Dos defectos concretos en `RagQueryConcern`:

1. `auto_scope_uris_from` comprueba si **algún** resultado tiene un token específico, pero después devuelve las URI de **todos** los resultados, incluidos los genéricos.
2. `question_wins` solo cambia el alcance si todos los candidatos son disjuntos del pin. Como Elemont también está entre los candidatos, la intersección no está vacía y prevalece únicamente Elemont. CEA15 desaparece del alcance efectivo.

La reproducción determinista explica el filtro observado. Los hashes de `rag_query_concern.rb`, `kb_document_resolver.rb`, `bedrock_rag_service.rb`, `session_context_builder.rb`, `conversation_session.rb`, `rag_controller.rb` y `generation.txt` coinciden entre producción y el código local revisado. No se preservó un snapshot histórico del catálogo anterior a la consulta; esa es la limitación de la reconstrucción.

Tercer defecto, derivado de los dos anteriores: `merge_resolver_context` inyecta en el prompt **todos** los matches del resolver como documentos existentes, sin distinguir cuáles quedaron dentro del filtro de recuperación. El prompt afirma que CEA15 existe y la evidencia no lo contiene; el modelo no puede citarlo ni puede negarlo, y termina pidiendo el manual al técnico.

Alcance real de este hallazgo: **explica solo el turno 1**. La segunda pregunta («La falla es en la puerta número 1 el equipo no magnetiza bien el imán…») no contiene ningún token específico (`specific_token?` exige dígito o mayúsculas completas); con el código corregido de P0 seguiría produciendo `candidate_uris=[]` y recuperación solo sobre el pin. La corrección del turno 2 y 3 depende de P1, no de P0.

### H2. Hay evidencia candidata más útil en CEA15

La lectura directa de sus chunks encontró contenido sobre seguridad automática y patín retráctil (páginas de extracción 24 y 61), función PAT1 (70), PATR (73) y diagnóstico/display (84–85). Estas referencias justifican recuperar ese manual antes de declarar ausencia.

No prueban que el «imán de la puerta» de Jesús sea un patín retráctil ni que esa revisión sea la instalada. Son candidatos para identificación y diagnóstico documentado, no instrucciones de intervención. Falta contrastar las páginas originales y el modelo real antes de fijar una respuesta técnica esperada.

### H3. Una etiqueta del plano se convierte en comprobación operativa

La segunda respuesta pide «Confirmar que la alimentación +18Vdc llega correctamente» a la chapa, verificar continuidad y revisar estado físico. Los chunks citados identifican rótulos y buses; no documentan esos tres pasos como procedimiento de diagnóstico de esta falla. El plano además contiene incertidumbres sobre conexiones.

Una referencia adjunta no demuestra que una instrucción esté respaldada. El plan debe impedir presentar una etiqueta, un bus común o una conexión ambigua como valor esperado del electroimán.

### H4. El turno de selección pierde el objetivo

La tercera respuesta pasa a un resumen, aunque el mensaje anterior describía la falla. `recent_history_for_prompt(turns: 3)` toma tres **mensajes**, no tres pares: en ese tercer turno conserva síntoma, respuesta y nombre del documento, pero ya no la primera descripción con CEA15. Cada mensaje está truncado a 300 caracteres.

La UI también agrega el nombre del documento al cuadro de consulta cuando se fija un documento. Hubo cambio de pin a las 10:51:51 y envío del nombre a las 10:51:54; es compatible con ese flujo, aunque los logs no prueban el gesto exacto del usuario. El contexto reciente aporta texto al prompt; el `input.text` enviado para recuperación sigue siendo la pregunta actual.

También aparece un `toc_v1.json` inexistente en ese turno. Hubo fallback exitoso a generación y HTTP 200; no es la causa del bloqueo funcional ni la primera corrección.

### H5. Un pin de hace 16 días acotó la primera consulta del día

El pin Elemont se fijó el 31-ago y seguía activo el 16-sep por el TTL deslizante de 30 días. La tarjeta del documento aparece seleccionada en la UI, así que el técnico pudo verlo; pero nada en la respuesta le dijo «solo consulté el plano Elemont». Con cualquier pregunta que no nombre un designador específico (como el turno 2), un pin antiguo sigue filtrando la recuperación en silencio.

No se propone despinnear automáticamente ni cambiar el TTL en este incidente (decisión de producto). Sí se exige que la respuesta y la telemetría hagan visible la **fuente efectiva** cuando un pin restringe la recuperación (P0, tercer punto) y que el problema activo pueda ampliar el alcance por mención explícita (P1).

## Contrato esperado por turno tras la corrección

Este contrato es el criterio de «funciona para todas las consultas» de la secuencia real. Se congela como fixture en P3.

| Turno | Entrada | Alcance de recuperación esperado | Respuesta esperada |
|---|---|---|---|
| 1 | «…elevador hidráulico Elemont, con imanes y tarjeta Cea15» con pin Elemont | Elemont ∪ CEA15 (unión, `auto_scope_filter=true`, `force_entity_filter=false`); forklift excluido | Identifica que el catálogo tiene un manual candidato (CEA15+/CEA15P) y el plano Elemont; no afirma que falte el manual; pide confirmar variante de la tarjeta (rótulo/foto). Sin pasos de medición. |
| 2 | «La falla es en la puerta número 1… no magnetiza bien el imán…» sin token específico | Hereda el alcance del problema activo: Elemont ∪ CEA15 | Busca en CEA15 lo que documenta sobre puerta/patín/seguridad; distingue «modelo sin confirmar» de «dato no documentado»; una sola pregunta de avance; cero verificaciones inventadas. |
| 3 | «Elemont Montacargas Hidraulico Modelo MH» tras re-pin, con problema activo | Igual que el turno 2 | No devuelve un resumen general no solicitado; ofrece continuar con la falla de la puerta 1 o, explícitamente, resumir el documento (`quick_replies`). |
| 4 (hipotético) | Pregunta que nombra otro equipo con designador específico disjunto | Solo el nuevo documento (comportamiento actual de `question_wins`) | El problema activo se reemplaza; no se arrastra CEA15. |

## Ejecución propuesta

### P0. Corregir alcance de fuentes, con casos de regresión

Archivos: `app/controllers/concerns/rag_query_concern.rb` (`auto_scope_uris_from`, cálculo de `question_wins`/`retrieval_uris`, `merge_resolver_context`), `test/controllers/concerns/rag_query_concern_test.rb`. `KbDocumentResolver` no requiere cambios: `resolve_scoped` ya devuelve `matched_tokens` por documento; el defecto está en cómo el concern los agrega.

- `auto_scope_uris_from`: filtrar especificidad **por documento**. Solo entran las URI de los matches cuyo `matched_tokens` incluya un token específico. `eléctrica` (forklift) y `Elemont` (plano) no heredan la especificidad de `Cea15`.
- Precedencia pin vs. pregunta, tres casos explícitos:
  - A. Los candidatos específicos están dentro del pin → se mantiene el pin, `force_entity_filter=true` (test existente «keeps the pin when the question match overlaps it», l. 468).
  - B. Candidatos específicos disjuntos del pin y la pregunta **no** menciona ningún documento del pin → se reemplaza el pin para este turno (test existente «overrides a disjoint pin», l. 428). Sin cambios.
  - C. **Caso Jesús.** Candidatos específicos disjuntos del pin, pero algún match del resolver (aunque genérico) es un documento pinneado → alcance = pin ∪ candidatos específicos, `auto_scope_filter=true`, `force_entity_filter=false` (mantiene vivo el reintento sin filtro). El pin no se modifica en la sesión. Loggear `RagQueryConcern: auto-scope extends pin (pinned=…, added=…)`.
- `merge_resolver_context`: el bloque `## Query Resolution` solo debe afirmar existencia de los documentos que están **dentro de `retrieval_uris`**. Los matches fuera del alcance se listan aparte como «en catálogo, no consultado en este turno» o se omiten. El prompt no puede prometer un documento que la evidencia no contiene.
- Fuente efectiva visible: `log_quality_signal` ya registra `entity_filter`; añadir a `retrieval_trace` el motivo de selección (`pin_only`, `auto_scope`, `pin_extended`, `pin_overridden`) para P3 y para la exportación. Sin cambio de UI en P0.
- Conservar pins como límite salvo mención explícita con designador específico. Ante una ausencia no se consulta el catálogo global; el reintento sin filtro existente en `BedrockRagService` (solo cuando `force_entity_filter=false`) sigue siendo la única ampliación automática.
- Preservar variantes: CEA15 puede localizar el manual candidato CEA15+; la respuesta debe confirmar identidad antes de trasladar sus datos al equipo (P2).
- No añadir marcas/modelos a `BRANDS`/`STOPWORDS` ni crear una llamada LLM de clasificación. No tocar `top_k`: con pin activo y «falla» en la pregunta, `RagRetrievalProfile` ya pide 5 resultados; la verificación de que entran chunks de CEA15 se hace en P3, no subiendo el presupuesto.

Rollback: `RAG_AUTO_SCOPE_ENABLED=false` desactiva el auto-scope completo (vuelve a pin puro). No se añade una segunda flag para P0.

Cierre: la pregunta literal produce alcance Elemont ∪ CEA15, sin el manual forklift; el bloque de resolución solo nombra documentos consultados; los tres tests de precedencia existentes (l. 428, 468, 501) siguen pasando; aislamiento por cuenta intacto (`KbDocumentResolver` ya filtra por `account_id`).

### P1. Mantener equipo, síntoma y aclaración pendiente

Archivos: `app/controllers/concerns/rag_query_concern.rb`, `app/models/conversation_session.rb`, `app/services/session_context_builder.rb`, `app/services/rag/episode_scope_flag.rb` (nueva, mismo patrón `module_function` que `Rag::AutoScopeFlag`); sin migración, sin cambios en `rag_chat_controller.js` (los `quick_replies` ya se renderizan, l. 933).

Diseño: el «problema activo» **no se persiste como estado nuevo**; se deriva de forma determinista del `conversation_history` existente en cada petición. Evita migración, evita promover texto del asistente a hecho, y el reset es automático por ventana temporal.

- Episodio activo: mensajes `role=user` del historial con `ts` dentro de las últimas 4 horas respecto de la pregunta actual (constante `EPISODE_WINDOW`), máximo 3 mensajes. Los mensajes de agosto quedan fuera por construcción. Un cambio de pin **no** corta el episodio (el turno 3 real ocurre 3 s después de un re-pin y debe conservar la falla).
- Herencia de alcance (`rag_query_concern.rb`): cuando la pregunta actual no produce candidatos específicos y existe episodio, ejecutar **una sola** llamada `KbDocumentResolver.resolve_scoped` sobre el texto concatenado de los mensajes del episodio y aplicar exactamente las mismas reglas A/B/C de P0 a esos candidatos. Costo: una consulta SQL ILIKE adicional solo en turnos de seguimiento sin designador. Motivo de selección en `retrieval_trace`: `episode_inherited`.
- Reemplazo: si la pregunta actual sí tiene candidatos específicos disjuntos (caso B), el episodio no se consulta; el nuevo equipo manda (turno 4 hipotético del contrato).
- Contexto del prompt (`SessionContextBuilder`): `## Recent Conversation` debe incluir **todos** los mensajes de usuario del episodio (máx. 3 × 300 chars) más el último mensaje del asistente truncado a 200 chars, en vez de los últimos 3 mensajes sin distinción de rol. Se mantiene `MAX_CONTEXT_CHARS=2000`; verificar en test que el bloque completo cabe sin truncar cuando hay 1 pin con 15 alias (caso real).
- No se altera `input.text` enviado a Bedrock para recuperación. La herencia actúa sobre el **filtro** (`retrieval_uris`), que es lo que falló; reescribir la consulta de recuperación con síntoma concatenado queda fuera de este incidente (riesgo de sesgar el embedding sin medición; ver `PLAN_RAG_RAZONAMIENTO_TECNICO_2026-09-15.md` Fase A paso 4).
- Turno de selección: si la pregunta actual, normalizada, es igual a `display_name` o a un alias de un documento pinneado y existe episodio con al menos una pregunta de usuario previa, la respuesta se genera igual (no se bloquea), pero `RagResult#quick_replies` devuelve dos opciones: «Continuar: <última pregunta del episodio truncada a 60 chars>» y «Resumen del documento». Detección determinista en el concern; sin LLM.
- Rollback: `RAG_EPISODE_SCOPE_ENABLED=false` desactiva herencia y quick_replies de selección, dejando P0 intacto.

Cierre: con el fixture real, el turno 2 recupera con alcance Elemont ∪ CEA15 sin repetir «Cea15»; el turno 3 conserva el mismo alcance y ofrece continuar con la falla; una pregunta 5 horas después, o que nombre otro designador, no arrastra CEA15.

### P2. Respuesta útil con límites verificables

Archivos: `app/prompts/bedrock/generation.txt`. El mecanismo de variante por cuenta de `PLAN_RAG_RAZONAMIENTO_TECNICO_2026-09-15.md` (`Rag::GroundedSynthesisFlag`, prefijos `GROUNDED_SYNTHESIS:`/`STRICT_ONLY:`) **no está implementado**; P2 no puede depender de él sin bloquear P0/P1.

Decisión: P2 se ejecuta **después** de medir P0+P1 con la batería de P3 y solo si persisten extrapolaciones o cierres «no tengo el manual» con el manual en alcance. Si se ejecuta, se limita a líneas puntuales en `generation.txt` bajo el prefijo ya existente `PARTIAL_ABSTENTION_PROMPT_PREFIX` o como líneas base (sin variante), midiendo el delta de tokens del prompt. El gate de tokens del plan del 15-sep (≤ 1,05 × prompt actual) aplica igual.

Nota sobre H3: la regla «Documentary lookup must not become an intervention procedure» ya existe en el prompt (`# RESPONSE SELECTION`) y `Rag::AnswerSafetyProcessor` no bloqueó la lista «Verificaciones documentadas en campo». Antes de añadir texto al prompt, registrar en P3 si el fallo se repite con el alcance correcto (con CEA15 en evidencia el modelo tiene menos motivo para inventar comprobaciones sobre rótulos del plano).

- Primero identificación y hechos pertinentes con citas; luego dato faltante específico; finalmente una sola pregunta que permita avanzar.
- Para este caso, la aclaración inicial debe confirmar la variante de la tarjeta mediante rótulo/foto. Una vez confirmada, preguntar por la indicación visible de diagnóstico que el manual realmente describe.
- No afirmar que falta el manual cuando está en catálogo pero quedó fuera del alcance. Distinguir «no consultado», «modelo sin confirmar» y «dato no documentado».
- No convertir rótulos de esquemas en secuencias de medición, tensiones esperadas de una bobina, puentes o pruebas. Las intervenciones requieren procedimiento aplicable documentado.
- Conservar las salvaguardas de citas, sin `stop_sequences` y con `$output_format_instructions$` al final.
- Revisar el cierre genérico de ausencia sin cambiar artificialmente la métrica a `answered`. Utilidad y resolución se evalúan aparte.

Cierre: la respuesta propone un siguiente paso de identificación pertinente y no inventa procedimiento. La expectativa técnica final se valida con el manual original y un técnico.

### P3. Validación y liberación acotada

1. Congelar los tres turnos reales como fixture Minitest (catálogo mínimo: docs 213, 207 y 13 con sus `display_name`/`aliases` reales de `tmp/jesus_diagnostic_2026-09-16/evidence.json`; historial de sesión 5 con `ts` reales) y reproducir primero **el fallo actual** (los tres turnos con `entity_s3_uris` = solo Elemont) antes de corregir. Sin inferencia facturada ni cambios en la sesión de Jesús. Archivos: `test/controllers/concerns/rag_query_concern_test.rb` (P0/P1, capturando `kwargs` de `QueryOrchestratorService.new` como los tests existentes), `test/services/session_context_builder_test.rb`, `test/models/conversation_session_test.rb`, `test/services/rag/episode_scope_flag_test.rb`.
2. Cubrir, cada uno con el contrato por turno como oráculo: pin Elemont + CEA15 explícito (caso C); palabra genérica que coincide con otro manual (forklift fuera); segunda pregunta sin repetir modelo (herencia); selección de documento (quick_replies); petición explícita de resumen (sin quick_replies de continuación); pin exclusivo sin mención de otro doc (caso A, sin cambios); pin + designador disjunto sin mencionar el pin (caso B, sin cambios); modelo fuera de cuenta (resolver no lo devuelve); episodio vencido a 4 h + 1 s; cambio de equipo con designador (reemplazo); `RAG_AUTO_SCOPE_ENABLED=false` y `RAG_EPISODE_SCOPE_ENABLED=false`; `## Query Resolution` no lista documentos fuera de `retrieval_uris`; `## Recent Conversation` cabe bajo `MAX_CONTEXT_CHARS` con 1 pin de 15 alias.
3. Tras corregir, se corrió una batería aislada (cuenta 1, sesión de sonda, nunca la sesión 5). Artefactos en `tmp/jesus_battery_2026-09-16/` / `tmp/jesus_bateria_padre_2026-09-16/`. El runner de sonda no se versiona: inlinaba código que ya está en producción.
4. Verificación de recuperación, previa a juzgar la redacción: en los turnos 1 y 2 al menos un chunk citado debe provenir de `bulk_chunks/1/c7182dfd9f2d630d7823f0f924c3a7641f3f/` (CEA15). Si el filtro es correcto pero ningún chunk de CEA15 entra en el top-k (5 con «falla»), el problema pasa a ser de ranking/terminología (H2: «imán de puerta» vs «patín retráctil») y se documenta como tal; no se corrige subiendo `top_k` ni reingiriendo en este incidente.
5. Criterios: cero procedimientos/valores extrapolados; cero cruces de cuenta; conservación del problema en todos los seguimientos del episodio; fuente candidata correcta; cero negativas por «manual inexistente» cuando está en alcance; cero respuestas vacías o `canned_with_retrieval`; el bloque de resolución no contradice la evidencia.
6. Comparar latencia y tokens con la línea base del 16-sep (p50 6.463 ms, p95 7.986 ms; 31.506 tokens de entrada en 3 llamadas). Con dos documentos en alcance el prompt puede crecer por chunks más largos de CEA15; aceptar hasta +20% en p95 y en tokens de entrada por llamada. No añadir llamadas generativas al camino normal. Costos por consulta de esta exportación son estimados; el gasto exacto requiere reconciliación de invocaciones.
7. Despliegue: P0 y P1 son cambios de código globales (no existe gating por cuenta; ver H4 del plan del 15-sep). Se despliegan con `RAG_EPISODE_SCOPE_ENABLED=true` solo tras pasar los gates 2–6; rollback = flags. Confirmar ausencia de ingestiones en vuelo antes de reiniciar contenedores. Reexportar la ventana posterior con `bin/pilot_metrics --with-questions` y revisar utilidad con Jesús; HTTP 200, `abstained` y número de citas no son criterios de resolución.

## Orden y alcance

Orden: **P3.1–P3.2 (fixture que reproduce el fallo) → P0 selección → P1 continuidad → P3.3–P3.6 batería → P2 solo si la batería lo exige → P3.7 despliegue**. P0 sin P1 deja el turno 2 y 3 sin corregir; P1 sin P0 no tiene qué heredar. Ambos van en el mismo PR. Verificar el manual y la identidad del equipo (CEA15 vs CEA15P vs CEA15+) acompaña P0/P2 y requiere al técnico. No reingerir el corpus, no aumentar el modelo ni `top_k` para resolver este incidente.

Fuera de alcance, registrado para decisión de producto: caducidad o aviso de pins antiguos (H5); reescritura de la consulta de recuperación con síntoma; despinneo automático.

Este diagnóstico no envió mensajes al técnico, no cambió pins o historiales y no ejecutó nuevas inferencias Bedrock. Las únicas escrituras fueron artefactos locales de investigación/exportación. El plan queda listo para implementación; la reparación eléctrica no se puede prometer sin confirmar el componente y su evidencia aplicable.

## Validación del plan (16-sep, 11:30)

Revisado contra `rag_query_concern.rb`, `kb_document_resolver.rb`, `session_context_builder.rb`, `conversation_session.rb`, `rag_controller.rb`, `bedrock_rag_service.rb`, `rag_retrieval_profile.rb`, `generation.txt`, los tests de precedencia existentes y los artefactos de `tmp/jesus_diagnostic_2026-09-16/`. Hallazgos H1–H4 confirmados. Gaps corregidos en esta versión: alcance real de P0 (solo turno 1), contradicción del bloque `## Query Resolution`, pin de 16 días (H5), decisión unión vs. reemplazo (caso C), diseño determinista de P1 sin migración, desacople de P2 del plan del 15-sep, contrato esperado por turno, verificación de que CEA15 entra en la evidencia y flags de rollback coherentes.
