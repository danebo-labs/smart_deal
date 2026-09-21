# Plan hilo de consulta — Cierre de precisión RAG (2026-09-21)

> **Validado contra el código el 21-sep-2026, noche.** Los hallazgos de esa
> validación están en «Validación contra código» (V1–V22) y en «Medición
> offline del episodio real». Donde un hallazgo contradice el plan anterior,
> gana el hallazgo. Lo que sigue marcado como hipótesis se mide en F0 antes de
> escribir código.

**Objetivo:** el copiloto de campo no pierde el hilo, con el nivel de soporte de un copiloto de desarrollo de software (CS-H06): distingue la intención del turno, se da cuenta de si continúa la consulta anterior o si es nueva, y cuando no le alcanza pregunta para precisar. El orden de preferencia es **unir** antes que **responder nombrando el supuesto** antes que **preguntar**, y ese es también el orden que menos pantalla gasta en mobile (CS-H08).

La validación contra código encontró la razón de fondo de las fallas H1 y H3, y ordena todo lo que sigue: **el episodio ya le llega al modelo en el prompt de generación (V20); lo que nunca vio el hilo es la recuperación**, porque `retrieve_and_generate` recupera con el texto literal del turno. Por eso la continuidad se arregla resolviendo la consulta antes de buscar, no pidiéndole al modelo que sea más listo — que es exactamente lo que dice la literatura de búsqueda conversacional y lo que hacen los copilotos de código cuando eligen qué buscar (ver «Cómo lo hacen los copilotos»).
**Entrada obligatoria.** Este archivo y [PLAN_CONTINUIDAD_SESION_FOLLOWUP_2026-09-21.md](PLAN_CONTINUIDAD_SESION_FOLLOWUP_2026-09-21.md) (su F1 ya está desplegada; no se reabre). Archivos exactos, con las líneas que este plan cita:

| Archivo | Qué mirar |
|---|---|
| `app/services/rag/followup_query_rewriter.rb` | `call` l.48–85 (orden de los `reason`), `discriminant_pair` l.131–154, `explicit_question?` l.208–214, `stored_whole?` l.216–222, `closed_followup_shape?` l.124–129, `new_question?` l.117–122, `normalize_label` l.280–287 |
| `app/controllers/concerns/rag_query_concern.rb` | llamada al rewriter l.69–78, resolver l.80–84, `resolved_output_channel` l.129, gate de selección l.140–160, `selection_quick_replies` l.541–554, `selection_turn?` l.556–567 |
| `app/controllers/rag_controller.rb` | el turno del usuario entra al historial **antes** de la consulta l.29–39; la respuesta del assistant entra al historial l.81–87; `quick_replies` al JSON l.125–132 |
| `app/models/conversation_session.rb` | `MAX_MSG_LENGTH` 300 l.7, `EPISODE_WINDOW` l.8, `EPISODE_MAX_USER_MESSAGES` l.9, `episode_user_messages` l.92–108, `last_assistant_message` l.110–121, `history_message` l.297–306 |
| `app/javascript/controllers/rag_chat_controller.js` | `renderQuickReplies` l.939–953 (`slice(0, 3)` l.940), `sendQuickReply` l.955–961, `escapeHtml` l.898–902, `sendMessage` l.348–351 |
| `app/services/session_context_builder.rb` | el episodio **ya** viaja al prompt de generación: `## Recent Conversation` l.45–59, tope `MAX_CONTEXT_CHARS` 2000 l.13 |
| `app/services/rag/ambiguous_model_responder.rb` | precedente de menú determinista con `quick_replies` l.87–102 |
| `app/prompts/bedrock/generation.txt` | l.141 `- GROUNDED_SYNTHESIS:` (bloque `Interpretación técnica:`), l.145–146 (sin cierre genérico de seguridad), l.148 (una sola pregunta por turno) |
| `test/controllers/concerns/rag_query_concern_test.rb` | arnés reutilizable: `SPRING_QUESTION` l.1922, `build_followup_session` l.2166, `create_followup_guide` l.2184, `wrap_episode_exclude` l.2193, `with_followup_orchestrator` l.2203, `with_resolver_calls` l.2218, `with_followup_log` l.2231 |
| `test/services/rag/followup_query_rewriter_test.rb` | forma de llamada directa al rewriter l.211 |

**Línea base:** imagen de producción `9977c7aa2c215794df0cf99cf2c901d75835c2f5` el 21-sep-2026. Cuenta 3, usuario 7, sesión 6, KB `Y7RZWMFJSR`. Export `tmp/pilot_exports/2026-09-21_2026-09-21_danebo-pilot-elevator`.
**Decisiones del dueño incorporadas:**

1. **CS-H01 (Lahiri, 21-sep-2026).** No inferir el hilo como lo haría una persona. Cero consultas recuperables: el turno se busca solo. Una sola: se une con las consultas de usuario de ese hilo. Dos o más: el turno no se busca; se pregunta a cuál se refiere, y una opción es «es una consulta nueva». *Precisión de la validación: «dos o más» se cuenta **después** de deduplicar tramos (V11). En el episodio real eso da 1, o sea que el caso correcto ahí es unir, no preguntar.*
2. **CS-H02 (Lahiri, 21-sep-2026).** La pregunta de desambiguación sale de las consultas ya guardadas en el episodio. No crea una bandeja de conversaciones ni borra el historial.
3. **CS-H03 (Lahiri, 21-sep-2026).** MVO, sin cliente en producción. Una fase de código por sesión. Cero Bedrock en F0 y en el menú. El holdout es otra sesión.
4. **CS-H04 (Lahiri, 21-sep-2026, tarde).** Tiene que servir en el campo. Si hay ambigüedad, revisa la sesión —preguntas del episodio, lo que el técnico contestó entre ellas, y el pin o la foto ya guardados— y se lo pregunta. No hace otra llamada para armar esa pregunta.
5. **CS-H05 (Lahiri, 21-sep-2026, tarde).** El copiloto apunta siempre a darle una solución al técnico en campo. Consulta cualquier dato ya recuperado que permita entender mejor y afinar la respuesta: el índice, un procedimiento parecido, o un modelo o equipo del RAG sobre el que quepa una analogía. Si la consulta puntual no tiene procedimiento, arma la guía desde esa analogía. El descargo es obligatorio y visible: no es una verdad absoluta para este equipo ni el procedimiento del fabricante de este trabajo. Incluye los aspectos de seguridad indispensables que ese conocimiento trae, para considerarlos antes de actuar. Puede hacer una pregunta más, pidiendo un dato —tuerca, medida, peso u otro concreto y relacionado— si ese dato ayuda a ser más preciso. Es el ciclo de `generation.txt` de CS-D02, afinado por esta decisión, y no entra en la fase del menú.
6. **CS-H06 (Lahiri, 21-sep-2026, noche).** El nivel de soporte deseado es el de un copiloto de desarrollo de software: distingue la intención en la consulta, se da cuenta de si el turno se relaciona con el anterior o si es una consulta nueva, y cuando no le alcanza pregunta para precisar el camino y la respuesta. Esto **no** reabre CS-H01: el copiloto de código no adivina el hilo con una segunda llamada a un modelo; resuelve la referencia con el historial que ya lleva en la misma llamada y decide qué buscar. La regla determinista de CS-H01 es la capa que arregla **qué se busca**; el comportamiento de copiloto es la capa que arregla **cómo se responde**, y vive en la misma única llamada de generación. Ver «Cómo lo hacen los copilotos» y «Arquitectura objetivo en tres capas».
7. **CS-H07 (Lahiri, 21-sep-2026, noche).** Se acepta ampliar las estructuras que dan consistencia, aunque el producto siga en MVP sin clientes de SaaS. Ampliar significa **unificar** las cuatro definiciones de «episodio» que hoy conviven (V20), no agregar arquitectura de empresa. Queda como Fase S, sin autorización de ejecución en este documento.
8. **CS-H08 (Lahiri, 21-sep-2026, noche).** La solución tiene que funcionar en mobile. El menú compite por alto de pantalla con la respuesta, con guantes y a contraluz. De ahí las reglas de V19: una sola línea por opción, tope de 4 chips, y preferir siempre la unión —que no muestra menú— sobre preguntar.

## Restricciones no negociables

1. La fase del menú no edita `app/prompts/bedrock/generation.txt`, gs-v1, temperatura ni `# NO MATCH`. CS-H05 solo puede tocar líneas `- GROUNDED_SYNTHESIS:` de ese archivo, en otra sesión, como CS-D02.
2. No hay lever de ingesta. No reingestar. No escribir bajo `bulk_chunks/`. El índice se usa solo si ya vino en los chunks de ese turno.
3. No reabrir F2 del plan de continuidad ni D18. CS-D02 no se reescribe: CS-H05 lo afina y se ejecuta en su propia sesión.
4. La analogía no se presenta como verdad absoluta ni como el procedimiento documentado de este equipo. Nombra de qué procedimiento, modelo o equipo sale. Incluye los aspectos de seguridad indispensables que el conocimiento recuperado trae.
5. El menú no llama a Bedrock. Reutiliza el transporte `quick_replies` que ya existe (`rag_chat_controller.js` l.939–961). No reutiliza el copy `rag.selection_turn_prompt` (ese es resumen de documento): estrena claves propias, V5.
6. Canal igual que F1: `web`, o `shared` solo si `SharedSession::ENABLED`. WhatsApp sigue dormido. No tocar el kwarg `whatsapp_to:`.
7. La variable local `question` del concern no se reasigna. La consulta efectiva es `effective_question`, la variable que ya existe en l.68.
8. Tope de composición: 442 caracteres (`MAX_COMPOSED_CHARS`). Si no entra, no se recorta a la mitad: no se une, no se abre menú, y se registra `budget_exceeded` (V14).
9. No persistir URIs citadas ni agregar tablas ni columnas en este ciclo. El filtro por manuales citados queda fuera salvo decisión nueva si el holdout falla el gate de seguridad.
10. Presupuesto de este documento: F0 = 0 Retrieve y 0 `retrieve_and_generate`. F1 = 0. Holdout = otra sesión, máximo 2 `retrieve_and_generate` sobre el candidato, no en el contenedor de producción.
11. **Lever de rollback obligatorio.** Todo comportamiento nuevo de este ciclo va detrás de `Rag::ThreadMenuFlag` (`ENV["RAG_THREAD_MENU_ENABLED"] != "false"`), con el mismo patrón exacto de `app/services/rag/episode_scope_flag.rb`. Con la flag apagada el turno recorre el camino de hoy, sin unión y sin menú (V13).
12. **Mobile primero (CS-H08).** Máximo 4 chips. Cada rótulo en una sola línea de ≤48 caracteres visibles. La unión gana siempre que sea posible, porque no gasta pantalla (V19).
13. **No se agrega una segunda llamada a Bedrock para decidir el hilo.** Ni router de intención, ni reescritor con LLM, ni clasificador. Si alguien quiere eso, es una decisión humana numerada nueva y no entra acá (V22).

## Hallazgos de arranque

| # | Hallazgo | Evidencia |
|---|---|---|
| H1 | `ThyssenKrupp Synergy` se buscó solo y la respuesta definió el equipo. El rewriter no unió. | `query:dd855ad6-071f-4032-b39e-9c18bbcd592b`, 16:11:35 −03. `[RAG_FOLLOWUP] applied=false reason=ambiguous_history`. Citas CMC3 SCM Synergy y Manual de Montaje Synergy Brasil. |
| H2 | La consulta escrita a mano en dos líneas sí siguió en fijación de cables y Synergy. | `query:e47bd5e8-917d-4d1d-a6cc-b6694098e53e`, 16:17:02 −03. Pregunta `Cómo se ajustan los resortes de la fijación de cables ?\nThyssenKrupp Synergy` (76 caracteres). `reason=new_question` porque el texto trae `?`. Citas: THYSSEN maniobra TCM / Isostop 60 p. 24 y p. 10; Manual de Montaje Synergy Brasil p. 27. `entity_filter` null. |
| H3 | `si, me refiero a resoretes de tension` se buscó sola y la única cita fue la escalera OTIS. | `query:ac78bcbf-735e-41f3-8782-f44e73695d9c`, 16:17:47 −03. `applied=false reason=ambiguous_history`. 37 caracteres. Única cita: Otis Escalator 506 NCE, p. 51, chunk `…/563d15bf19a164ceba066fa0239ab0bdcce7/chunk_p51_1.txt`. La respuesta incluye la cota 102 mm y un procedimiento de seis pasos, y después dice que Synergy no lo documenta. |
| H4 | Con más de una pregunta explícita en el episodio, F1 aborta y la búsqueda usa el texto literal. | `FollowupQueryRewriter#discriminant_pair`: `explicit.size > 1` → `ambiguous_history` (`followup_query_rewriter.rb`, el `return` de `ambiguous_history` sobre `explicit.size`). |
| H5 | Una frase corta sin `?` no es identificador de catálogo. Si el par del episodio es válido, F1 no la une: `not_identifier`, y se busca sola. Si el assistant no deja par válido, el reason es otro y también se busca sola. | Orden en `call`: `closed_followup_shape?` pasa si no hay `?`, cabe en 120 caracteres y en 12 tokens. `catalog_identifier?` exige nombre exacto o designador específico. Antes de eso, `discriminant_pair` puede devolver `no_discriminant` o `ambiguous_history`. F0 mide el reason real de los dos episodios sintéticos. `si, me refiero a resoretes de tension` no es un alias. |
| H6 | El historial no guarda citas ni la pregunta final del assistant si la respuesta supera 300 caracteres. | `history_message` guarda `role`, `content` truncado a `MAX_MSG_LENGTH` 300, `ts`, `user_id`, `correlation_id` (`conversation_session.rb`). La respuesta de H2 mide 1024 caracteres. La pregunta al técnico va al final y no queda en el historial. El menú no puede leerla de ahí. |
| H7 | Ya existe un menú sin generación para otra ambigüedad: modelos de hardware. El chip manda la pregunta más una línea. | `Rag::AmbiguousModelResponder` arma `quick_replies` con `query: "#{@question}\n…"`. El chat los pinta en `rag_chat_controller.js`. Ese responder sí hace Retrieve; el de este plan no. |
| H8 | Elegir siempre la pregunta explícita más nueva sería adivinar el hilo. Queda fuera. | Decisión CS-H01. El episodio de la sesión 6 tenía varias preguntas de resortes, Fuji y Synergy en la misma ventana de 4 horas. |
| H9 | `generation.txt` ya tiene el bloque de inferencia y lo prohíbe: sin valores, vueltas, torques, secuencias ni intervención prescrita. | `generation.txt` l.141, línea `- GROUNDED_SYNTHESIS:`, encabezado `Interpretación técnica:`. CS-H05 cambia esa prohibición solo en líneas con ese prefijo, en otra sesión. |

## Revisión del 21-sep, tarde

El otro modelo no terminó. Estos huecos salen de leer el plan contra el rewriter y cambian F1. No cambian el gate de seguridad.

| # | Hueco | Efecto |
|---|---|---|
| R1 | H5 decía siempre `not_identifier`. El par puede cortarse antes, en `no_discriminant` o `ambiguous_history`. | F0 registra el reason real. F1 no depende de que sea uno solo. |
| R2 | Un chip sin `?` —pregunta explícita solo porque contiene «como»— vuelve a entrar al menú. El plan solo cerraba el caso con `?`. | ~~F1 marca el turno elegido.~~ **Superada por V2 y V3:** no hay marca. El chip de tramo queda afuera por forma (lleva `\n`), y el chip de consulta nueva —que era un bucle infinito— se corta con la supresión del lado del servidor. |
| R3 | La misma pregunta en texto y en foto contaría como dos opciones. | ~~Una opción por texto normalizado.~~ **Corregida por V11:** la dedup va por el texto del **tramo** normalizado. Con la regla original el episodio real mostraba dos chips con rótulo idéntico. |
| R4 | El chip de solo la pregunta pierde lo que el técnico dijo después, por ejemplo `ThyssenKrupp Synergy`, hasta la pregunta siguiente. | La opción es ese tramo: la pregunta más esos turnos. No elige entre tramos; se los muestra al técnico. |

## Medición offline del episodio real (21-sep, noche)

Hecha sobre `tmp/pilot_exports/2026-09-21_2026-09-21_danebo-pilot-elevator/interactions.csv`, que **sí** trae la columna `question` con el texto crudo. Cero Bedrock, cero producción.

⚠️ **CRÍTICO — el export citado no alcanza.** Tiene 6 interacciones y su `generated_at` es `2026-09-21T16:14:45-03:00` (`report.json`), o sea **anterior** a los dos turnos sobre los que descansa todo el plan: H2 (16:17:02) y H3 (16:17:47). No están en el archivo. La frase de la Fase 0 «no hace falta volver a producción si el export alcanza» es falsa tal como está escrita. F0 necesita un export nuevo del día o una lectura del `conversation_history` de la sesión 6 en producción, y tiene que transcribir los dos turnos **verbatim**.

Turnos de usuario medidos, en orden, con longitudes reales:

| # | Hora −03 | Ruta | Texto | Chars |
|---|---|---|---|---|
| u1 | 16:01:36 | foto | `EN la imgen, como se ajustan los resortes ?` | 43 |
| u2 | 16:02:31 | texto | `si dame mas detalle del amarred de cables de suspension` | 55 |
| u3 | 16:03:27 | texto | `ok, como seria para el caso Fuji Yida` | 37 |
| u4 | 16:10:23 | texto | `Cómo se ajustan los resortes de la fijación de cables ?` | 55 |
| u5 | 16:10:44 | foto | `Cómo se ajustan los resortes de la fijación de cables ?` | 55 |
| u6 | 16:11:35 | texto | `ThyssenKrupp Synergy` | 20 |
| u7 | 16:17:02 | texto | `Cómo se ajustan los resortes de la fijación de cables ?\nThyssenKrupp Synergy` | 76 |
| u8 | 16:17:47 | texto | `si, me refiero a resoretes de tension` | 37 |

u1–u6 salen del export. u7 y u8 salen de H2 y H3 de este documento; la aritmética cierra (55 + 1 + 20 = 76), pero **no están medidos** y F0 los tiene que confirmar.

**R3 queda confirmada con datos reales:** u4 y u5 son la misma pregunta en texto y en foto, separadas por 21 segundos.

**Resultado de aplicar la regla de la Fase 1 al turno u8** (ver V11 para la regla de dedup corregida):

1. `previous_users` toma los 3 últimos turnos de usuario anteriores: u5, u6, u7.
2. `explicit_question?`: u5 sí (trae `?`), u7 sí (trae `?`), u6 no (`thyssenkrupp synergy` no tiene ningún lexema de `TECHNICAL_LEXEME`).
3. Tramos: tramo(u5) = u5 + u6 = `Cómo se ajustan los resortes de la fijación de cables ?\nThyssenKrupp Synergy`. tramo(u7) = u7, que es **el mismo string**.
4. Dedup por tramo normalizado ⇒ **1 sola consulta recuperable**. Se conserva la más nueva, u7.
5. ⇒ **Se une, no se abre menú.** Consulta efectiva = 76 + 1 + 37 = **114 caracteres**, muy debajo de 442.

Esto cambia la expectativa del plan: en el episodio real el camino correcto es la unión automática con **una** generación, y el menú no aparece. Si en F1 el menú aparece en este episodio, la implementación está mal. Con la regla literal del plan anterior («una opción por texto normalizado», mirando el texto de la pregunta y no el del tramo) el técnico habría visto **dos chips con el rótulo idéntico**, porque el rótulo arranca por la primera línea y u5 y u7 comparten la primera línea. Ese es el error que V11 corrige.

## Validación contra código (V1–V22)

Hecha el 21-sep de noche leyendo el código, no el plan. Cada fila trae archivo y línea. `⚠️` marca lo que obliga a cambiar la implementación o una restricción.

### Bloqueantes del menú

| # | Hallazgo | Evidencia | Qué hacer |
|---|---|---|---|
| ⚠️ V1 | El cuarto chip se descarta en silencio. El menú necesita hasta 3 tramos más «Es una consulta nueva» = 4 opciones. | `renderQuickReplies` hace `replies.slice(0, 3)` (`rag_chat_controller.js` l.940). | Subir a `slice(0, 4)`. Es seguro para los tres productores actuales: `AmbiguousModelResponder` ya corta en `MAX_OPTIONS` 3, `selection_quick_replies` devuelve 2, y el fallback del controlador usa `.first(3)` (`rag_controller.rb` l.127). Tope de servidor `MAX_MENU_OPTIONS = 4`. |
| ⚠️ V2 | El chip «Es una consulta nueva» reabre el menú para siempre. Manda exactamente `turno_actual`, o sea el mismo texto que abrió el menú, así que el conteo de recuperables da igual y vuelve a salir el menú. Bucle infinito, 0 Bedrock, técnico encerrado. R2 nombraba una «marca» pero no la definía, y el plan de continuidad prohíbe transportar un booleano del navegador. | Deriva de `sendQuickReply` l.955–961: el chip sólo sabe poner texto en el textarea y enviar. | Supresión del lado del servidor, sin params: no abrir el menú si el último mensaje de assistant del episodio es el copy del menú **y** el último mensaje de usuario anterior a ese, normalizado, es igual al turno actual. Las dos lecturas son en memoria sobre `conversation_history`. Obliga a que el copy mida ≤300 caracteres y a comparar contra `.truncate(300)`, porque `history_message` trunca (`conversation_session.rb` l.300). |
| V3 | El chip de tramo **no** reabre el menú, pero no por una marca: el texto compuesto lleva `\n`, y `closed_followup_shape?` rechaza cualquier texto con `\n` (l.125). | `followup_query_rewriter.rb` l.124–129. | Definir la puerta del menú por forma, no por marca: se abre sólo si `new_question?` es falso **y** `closed_followup_shape?` es verdadero. Como efecto lateral, un turno largo de 200 caracteres sin `?` tampoco abre el menú, que es lo correcto: es una consulta nueva, no una aclaración. |
| ⚠️ V4 | `data-query` se rompe con el texto del técnico. `escapeHtml` usa `textContent`→`innerHTML`, que escapa `& < >` pero **no** las comillas dobles. Hasta hoy el payload de los chips eran nombres de placa y copy de I18n; el menú del hilo es la primera vez que texto libre del técnico entra a un atributo HTML. Un turno con `"` rompe el atributo, y es un vector de inyección. | `escapeHtml` l.898–902, interpolación en `data-query="${safeQuery}"` l.947. | Escapar `"` y `'`, y codificar el salto de línea como `&#10;` al construir el atributo. No es opcional. |
| ⚠️ V5 | El menú necesita copy propio y no existe. La restricción 5 prohíbe reusar `rag.selection_turn_prompt`. | `config/locales/rag.es.yml` l.62 y `rag.en.yml` l.62. | Crear `rag.thread_menu_prompt` y `rag.thread_menu_new_query` como hermanas de `selection_turn_prompt` en **los dos** archivos. El prompt tiene que medir <300 caracteres por V2. |
| ⚠️ V19 | Mobile (CS-H08). Los chips son botones full-width apilados con `min-h-11` (44 px) y `text-left`; 4 chips con rótulos que envuelven a tres líneas empujan la respuesta fuera de la pantalla, con guantes y a contraluz. | clases en `renderQuickReplies` l.948. | Rótulo de una sola línea: unir las líneas del tramo con ` — ` y truncar a 48 caracteres. Tope duro de 4 chips. Y la consecuencia de diseño: preferir siempre la unión, que no gasta pantalla, sobre preguntar. |

### Orden, costo y alcance en el concern

| # | Hallazgo | Evidencia | Qué hacer |
|---|---|---|---|
| ⚠️ V6 | Dónde se engancha decide el costo y la precedencia. El gate de selección desplegado (l.140–160) tiene que seguir ganando cuando el turno es el nombre de un pin. | `rag_query_concern.rb`: rewriter l.69–78, resolver l.80–84, gate l.140–160. | El bloque nuevo va **inmediatamente después** de `log_rag_followup` (l.77) y **antes** de `resolver_matches` (l.80), y se saltea cuando `selection_turn?(question, conv_session)` es verdadero — una comprobación en memoria sobre `active_entities`, cero SQL. Así el camino del menú cuesta 0 queries extra y el gate desplegado conserva su dominio. Requiere mover la asignación de `resolved_output_channel` de l.129 a justo después de l.62; no tiene dependencias. |
| ⚠️ V7 | Cuando se une, el resolver tiene que ver el texto compuesto. Hoy l.83 resuelve `question`, así que la unión no le mostraría al resolver el manual que el técnico nombró en el turno anterior. | `rag_query_concern.rb` l.80–84. | Cambiar el argumento de `resolve_scoped` a `effective_question`. Es un no-op para todo lo de hoy, porque `effective_question == question` cuando nada se unió. **No esperar filtro:** `ThyssenKrupp` y `Synergy` no pasan `KbDocumentResolver.specific_token?` (no tienen dígito y no están todo en mayúsculas, `kb_document_resolver.rb` l.90–94), así que no hay auto-scope. Coincide con el `entity_filter: null` medido en H2. El holdout no debe exigir filtro. |
| V8 | La hipótesis `not_identifier` de H5 se sostiene, pero el reason es ambiguo como señal. Traza de `si, me refiero a resoretes de tension`: sin `?`; 37 ≤ 120; 7 tokens ≤ 12 ⇒ pasa la forma; con un solo explícito y assistant válido sale par; compuesto 114 ≤ 442; `identifier_for_match` lo deja igual (`IDENTIFIER_PREFIX` exige `es `/`it is ` al inicio); `resolve_scoped` no da cobertura de token específico ⇒ `not_identifier` en l.73. | `followup_query_rewriter.rb` l.48–85. | F1 **no** puede ramificar por `reason == "not_identifier"`: el mismo string sale también de l.53 (forma inválida) y de l.66 (identificador vacío). Ramificar por `applied == false` más la puerta de forma de V3. |
| ⚠️ V9 | El episodio medido no tiene la forma de tramo que el plan supone. u7 es **un solo** mensaje con `\n` que ya lleva pregunta e identificador. La premisa de R4 es real sólo para la forma de H1 (u6 suelto). | Medición offline, arriba. | El tramo tiene que tolerar un recuperable que ya contiene `\n` internamente: ni `stored_whole?` ni `explicit_question?` lo rechazan, y está bien. El que no puede llevar `\n` es el **rótulo** (V19). |
| V10 | `explicit_question?` es ancho: cuenta cualquier turno con `que, como, cual, cuanto, por que, what, how, which, why, when, where` en cualquier posición. `ThyssenKrupp Synergy` no cuenta (bien), pero `no se que hacer` sí. | `TECHNICAL_LEXEME` l.28, uso en l.208–214. | Se acepta: es la definición desplegada y CS-H01 dice no adivinar. F0 tiene que reportar el conteo sobre el episodio real para saber si el caso común es 1 (unión) o 2+ (menú). |
| ⚠️ V11 | La dedup de R3 estaba mal ubicada. Deduplicar por el texto **de la pregunta** deja dos chips con rótulo idéntico en el episodio real (u5 y u7 comparten primera línea). | Medición offline, paso 5. | Deduplicar por `normalize_label` del **tramo completo**, conservando la ocurrencia más nueva. En el episodio real colapsa a 1 y el resultado es la unión, que es lo que se busca. |
| V12 | El copy del menú queda en el historial como mensaje de assistant, porque `images_uploaded` está vacío. | `rag_controller.rb` l.81–87. | Dos consecuencias: (a) la supresión de V2 funciona; (b) en un turno corto posterior, `assistant_after(...).last` del rewriter será el copy del menú, que **no** está en `blocked_assistant_copies` (l.231–238), así que el rewriter todavía puede unir. **Decisión: no agregarlo a esa lista** — bloquearlo convertiría un turno unible en `no_discriminant`, que es exactamente la falla H3. Fijarlo con un test. |
| ⚠️ V13 | No hay lever de rollback. Todo lo comparable en este concern va detrás de una flag de ENV. | `episode_scope_flag.rb`, `auto_scope_flag.rb`, `structured_evidence_route_flag.rb`. | Crear `Rag::ThreadMenuFlag`, restricción 11. |
| ⚠️ V14 | El tope de 442 no estaba definido para el menú, sólo para la unión. | Restricción 8 original. | Si **algún** tramo candidato supera 442 compuesto, no se abre menú y no se une: el turno se busca solo y se registra `budget_exceeded`. Sin menús parciales y sin opciones recortadas. El peor caso medido es 114. |
| V15 | F0 no es reproducible sin un detalle de construcción. `find_current` busca el turno actual primero por `correlation_id` y después por texto exacto; en producción el turno **ya está** en el historial cuando corre la consulta. | `rag_controller.rb` l.29–39, `find_current` l.180–192, y el corte de l.145. | El fixture de F0 **tiene** que incluir el turno actual como última fila con su `correlation_id`. Si no, `previous_users` se incluye a sí mismo y l.145 corta en `ambiguous_history`: F0 «confirmaría» un reason equivocado. `build_followup_session` (test l.2166) ya arma exactamente esa forma. |
| V16 | F0 no necesita arnés nuevo. | Helpers del test, listados en «Entrada obligatoria». | Medir los reason llamando `Rag::FollowupQueryRewriter.call` directo. `resolve_scoped` pega a Postgres: está permitido (0 Bedrock), pero no es gratis. |
| ⚠️ V17 | Copiar los predicados los hace divergir, y la divergencia entre dos definiciones de «pregunta explícita» es justo la falla que este plan arregla. Hoy son privados. | `followup_query_rewriter.rb` l.117–129, 208–222, 280–287. | Publicarlos como métodos de clase (`self.explicit_question?`, `self.stored_whole?`, `self.closed_followup_shape?`, `self.new_question?`, `self.normalize_label`) y que los métodos de instancia deleguen. El servicio nuevo llama a esos. Cero duplicación. |
| V18 | `aria-label="Opciones de placa"` está hardcodeado: un menú de consultas se anunciaría como opciones de placa, y sólo en español. | `rag_chat_controller.js` l.952. | Opcional y barato: aceptar el rótulo como argumento con el string actual por defecto. |

### Lo que cambia por CS-H06 (nivel copiloto)

| # | Hallazgo | Evidencia | Qué implica |
|---|---|---|---|
| ⚠️ V20 | **El episodio ya llega al prompt de generación.** `SessionContextBuilder` inyecta un bloque `## Recent Conversation` con `episode_user_messages` más `last_assistant_message` truncado a 200, con tope global de 2000 caracteres. | `session_context_builder.rb` l.45–59, tope l.13. | El modelo **ya puede** ver que el turno se relaciona con el anterior. Lo que no ve el episodio es la **recuperación**: `retrieve_and_generate` recupera con el texto literal de la consulta. Por eso H3 trajo la escalera OTIS por más contexto conversacional que hubiera en el prompt. Conclusión que ordena todo el plan: la continuidad del hilo es un problema de recuperación, no de generación. |
| ⚠️ V21 | **La sesión de Bedrock está muerta en web.** El servicio manda y devuelve `session_id`, el controlador lo pone en el JSON, y el JS **nunca** lo guarda ni lo reenvía: `grep session_id` en `rag_chat_controller.js` no da ninguna coincidencia. Cada turno abre una sesión nueva de Bedrock. | `bedrock_rag_service.rb` l.239 y l.325, `rag_controller.rb` l.117, ausencia en el JS. | Es un lever de continuidad disponible y sin usar. **No se activa en este ciclo**, y la razón hay que dejarla escrita: reusar `sessionId` le entrega a Bedrock la reescritura de la consulta dentro de una caja negra de 24 horas, que no se puede auditar ni fijar con un test, y este dominio exige trazabilidad de la evidencia. Además reinyecta turnos anteriores como input facturado. Si alguien lo quiere, es decisión humana numerada nueva. |
| V22 | Cuatro definiciones de «episodio» conviven y se pueden separar: `episode_rows` del rewriter (con índice y ts), `episode_user_messages` del modelo (sólo contenido, excluye por igualdad de texto), `detect_locale_from_history` del concern (últimos 6), y `SessionContextBuilder` (otra forma más). | `followup_query_rewriter.rb` l.156–169, `conversation_session.rb` l.92–108, `rag_query_concern.rb` l.368–380, `session_context_builder.rb` l.45–52. | Es la «estructura de consistencia» de CS-H07. Va a Fase S, no a F1. |

## Cómo lo hacen los copilotos (grounding de CS-H06)

Consultado el 21-sep-2026. Importa porque fija qué parte del nivel deseado es alcanzable sin romper Cost First.

1. **Una sola llamada por turno, no un router aparte.** Cursor arma en cada Enter una única llamada con el system prompt, las reglas, el historial compactado y el estado del editor; el modelo es stateless entre mensajes y resuelve la referencia dentro de esa misma llamada. Copilot hace lo mismo en `AgentIntent`, con compactación y presupuesto de tokens explícitos. Nadie gasta una llamada extra en preguntar «¿esto es un follow-up?». Fuentes: [How Cursor Actually Works](https://theaiengineer.substack.com/p/how-cursor-actually-works), [reverse-engineering del agente](https://dev.to/vikram_ray/i-reverse-engineered-cursors-ai-agent-heres-everything-it-does-behind-the-scenes-3d0a), [`agentIntent.ts`](https://github.com/microsoft/vscode-copilot-chat/blob/5863f5a7/src/extension/intents/node/agentIntent.ts).
2. **La inteligencia está en que el modelo elige qué buscar.** La búsqueda es una herramienta (`#search/codebase`, `#githubRepo`): el modelo emite la consulta de búsqueda ya resuelta. Esa es la diferencia real con `retrieve_and_generate`, donde la recuperación la maneja el string literal del turno. Fuente: [cheat sheet de VS Code](https://code.visualstudio.com/docs/agents/reference/ai-features-cheat-sheet).
3. **La literatura de búsqueda conversacional es explícita: resolver el follow-up es un problema de recuperación, no de generación.** QuReTeC lo llama «query resolution» porque el turno viene incompleto por elipsis y anáfora. Y en dominios cargados de identificadores la recomendación es **seleccionar términos del historial y anexarlos**, en vez de reescribir libre, porque la reescritura deriva e inventa versiones. La unión verbatim de este plan es exactamente el extremo seguro de ese espectro. Fuentes: [comparación de métodos de question rewriting](https://arxiv.org/pdf/2101.07382), [CMU-LTI CAsT](https://trec.nist.gov/pubs/trec30/papers/CMU-LTI-CAsT.pdf).
4. **Preguntar sólo cuando la evidencia se parte, no cuando el historial es ambiguo.** ClarifyRAG condiciona la aclaración a que la masa de la evidencia se reparta entre dos sentidos comparables, y con eso llega a 100 % de acierto preguntando 38 % menos que la política de preguntar siempre. Y las opciones de la pregunta salen del corpus recuperado. Fuentes: [clarifyrag](https://github.com/ahmeddoghri/clarifyrag), [intent clarification en RAG](https://www.weblineglobal.com/blog/llm-intent-clarification-rag-systems/).
5. **Compactar, no truncar.** Los dos copilotos resumen los turnos viejos en vez de cortarlos. Danebo trunca a 300 caracteres y con eso pierde la pregunta final del assistant (H6).

Consecuencias directas sobre este plan:

- El punto 3 valida la unión determinista y desautoriza un reescritor con LLM para manuales de ascensor.
- El punto 4 dice que este proyecto **ya tiene** la forma correcta de preguntar, en `AmbiguousModelResponder`: el menú sale de los encabezados recuperados. El menú de este plan, en cambio, pregunta por ambigüedad de **historial**. Es más pobre que el estándar, y por eso se degrada a fallback y no es el objetivo del producto.
- El punto 1 dice que el nivel de copiloto no cuesta una llamada más: cuesta contexto en la llamada que ya existe, y ese contexto ya se está enviando (V20).

## Arquitectura objetivo en tres capas

Esto reemplaza la lectura de que «el menú es el producto».

| Capa | Qué resuelve | Dónde vive | Costo | Fase |
|---|---|---|---|---|
| 1. Resolución de la consulta | Que la **recuperación** reciba el hilo. Une verbatim cuando hay una sola consulta recuperable. Es lo único que arregla H1 y H3. | `Rag::FollowupQueryRewriter` (desplegado) + el servicio nuevo de F1 | 0 llamadas extra | **F1** |
| 2. Respuesta de copiloto | Que el turno se lea como intención: nombra qué asumió, dice si lo tomó como continuación o como consulta nueva, y hace una sola pregunta si un dato cambiaría la respuesta. | `generation.txt`, líneas `- GROUNDED_SYNTHESIS:`, y el `## Recent Conversation` que ya se inyecta | 0 llamadas extra, sólo input | **Fase G** |
| 3. Preguntar cuando de verdad no alcanza | Elegir entre interpretaciones. El estándar es partir por desacuerdo de **evidencia** (precedente vivo: `AmbiguousModelResponder`). El menú por historial de este plan es el fallback pobre de esta capa. | menú de F1 (fallback) y `AmbiguousModelResponder` (ya vivo) | 0 Bedrock en el menú | **F1** (fallback) |

Orden de preferencia en un turno ambiguo, y es el orden de la implementación: **unir** > **responder como copiloto nombrando el supuesto** > **preguntar**. En mobile (CS-H08) ese orden además es el orden de menor consumo de pantalla.

## Asignación de modelo por fase

| Fase | Modelo | Racional |
|---|---|---|
| Validación de este plan | Cerrada 21-sep noche, contra código | V1–V22. No se repite. |
| F0 | Modelo que lee código y tests | Confirma H5 y la lista de opciones del episodio medido. Cero Bedrock. |
| F1 | Modelo fuerte en código Rails | Un cambio: menú o unión. Tests. Sin UI nueva más allá del copy y de los `quick_replies` ya existentes. |
| Holdout | Sesión que no escribió F1 | Como máximo 2 generaciones. Gate de seguridad independiente. |

## Fase 0 — Medición, sin escribir código de producción

Cero Retrieve y cero `retrieve_and_generate`. Sí se permiten tests nuevos y Postgres. Cada punto termina en un número o en un string anotado en este documento; «parece que sí» no cierra un punto.

1. **Transcribir u7 y u8 verbatim.** Es bloqueante: el export citado no los tiene (ver la medición offline). Un export nuevo del día, o leer `conversation_history` de la sesión 6 en producción sin escribir nada. Confirmar los 76 y 37 caracteres y el `\n` interno de u7. Si u7 no es exactamente pregunta + `\n` + identificador, recalcular los tramos y corregir la sección de medición antes de seguir.
2. **Reason real del caso de una sola pregunta explícita.** Fixture estilo `build_followup_session` (test l.2166), con el turno actual como última fila y su `correlation_id` (V15). Turno: `si, me refiero a resoretes de tension`. Hipótesis: `not_identifier` por la rama de catálogo (l.73), con `catalog_matches` presente. Anotar el reason y si `catalog_matches` viene vacío o no — eso distingue l.53 de l.73 (V8).
3. **Reason con dos preguntas explícitas previas.** Hipótesis: `ambiguous_history` por `explicit.size > 1` (l.141). Es el caso de producción de H3.
4. **Reason con el assistant truncado.** Repetir el punto 2 con un assistant de 300 caracteres terminado en `...`. Anotar si pasa a `no_discriminant`.
5. **Lista de recuperables y tramos sobre el episodio real.** Reconstruir u1–u8 en un fixture y aplicar la definición de la Fase 1. Anotar: cuántos recuperables, el texto de cada tramo, el texto normalizado de cada tramo, cuántos sobreviven a la dedup de V11, y la longitud compuesta. Hipótesis: **1 recuperable, se une, 114 caracteres**. Si sale 2, la implementación de F1 arranca por el menú y no por la unión, y hay que decirlo en Estado.
6. **Puerta de forma.** Confirmar sobre el rewriter actual que un turno con `?` da `new_question` (l.52) y que un texto con `\n` da `not_identifier` por forma (l.53 vía l.125). Son las dos condiciones de V3 que impiden el bucle del chip de tramo.
7. **Conteo de chips del peor caso.** Construir un episodio con los 3 turnos previos de usuario explícitos y distintos. Anotar cuántas opciones devuelve la regla: la hipótesis es 3 tramos + 1 = **4**, que es la que rompe `slice(0, 3)` (V1).
8. **Tope de 300 del copy.** Redactar los dos copys de V5 y anotar su longitud en `es` y en `en`. Si alguno pasa de 300, acortarlo: de eso depende la supresión de V2.

No se implementa nada de F1. Al cerrar: actualizar Estado, corregir las filas que no coincidan, y recién entonces escribir el prompt de F1 con los reason medidos.

⚠️ Si el punto 1 no se puede cerrar (sin acceso a producción y sin export nuevo), F0 queda abierta y F1 **no** arranca: todo el diseño del tramo descansa en el texto exacto de u7.

## Resultados de la Fase 0 (21-sep-2026, noche)

Cero Retrieve y cero `retrieve_and_generate`. El punto 1 se cerró leyendo, sin escribir, `conversation_history` de la sesión 6 y `bedrock_queries.user_query` de `query:e47bd5e8-917d-4d1d-a6cc-b6694098e53e` y `query:ac78bcbf-735e-41f3-8782-f44e73695d9c`. La imagen en el contenedor web era `9977c7aa2c215794df0cf99cf2c901d75835c2f5`.

| Punto | Resultado |
|---|---|
| 1 | u7 es `Cómo se ajustan los resortes de la fijación de cables ?\nThyssenKrupp Synergy`: 76 caracteres, 78 bytes, con `\n` interno. u8 es `si, me refiero a resoretes de tension`: 37 caracteres, 37 bytes. El historial y `user_query` coinciden. No hay que recalcular tramos. |
| 2 | Una sola explícita: `not_identifier`, `previous_correlation_id` presente, `resolve_scoped` llamado con el turno entero, `catalog_matches` size 0. Es la rama de l.73. El array vacío **no** distingue l.53 de l.73; lo que las distingue es el `previous_correlation_id` y la llamada al resolver. F1 sigue sin ramificar por `reason`. |
| 3 | Dos explícitas: `ambiguous_history`, resolver no llamado. El episodio real reconstruido da el mismo reason. |
| 4 | Assistant de 300 caracteres terminado en `...`: sigue `not_identifier` por l.73. No pasa a `no_discriminant`. |
| 5 | `previous_users` = u5, u6, u7. Recuperables: u5 y u7. Tramos idénticos. Normalizado: `como se ajustan los resortes de la fijacion de cables thyssenkrupp synergy`. Tras dedup: **1**. Compuesto: **114**. No supera 442. Se une. Si el menú aparece en este episodio, la implementación está mal. |
| 6 | Turno con `?`: `new_question`, resolver no llamado. Turno con `\n` y sin `?`: `not_identifier`, `previous_correlation_id` nil, resolver no llamado. |
| 7 | Tres explícitas distintas: **4** opciones. |
| 8 | `rag.thread_menu_prompt` es 72 / en 89. `rag.thread_menu_new_query` es 21 / en 22. Todas bajo 300. |

Lectura fijada del paso 4 del Anexo B: recuperables = los últimos 3 turnos de usuario (`previous_users`) y, de esos, los que pasan `explicit_question?` y `stored_whole?`. Filtrar primero en toda la ventana metería u4, dejaría 2 tramos tras la dedup y abriría el menú en el episodio real.

## Fase 1 — Unión primero, menú como fallback

**Hipótesis.** H1 y H3 fallan porque la **recuperación** recibe el turno solo, no porque al modelo le falte contexto conversacional: ese contexto ya se le manda (V20). La corrección no elige un hilo. Une cuando queda una sola consulta recuperable, y sólo pregunta cuando quedan varias. Medido en el episodio real, el camino correcto es unir: el menú es el fallback, no el objetivo.

**Consulta recuperable.** Mensaje de usuario dentro de `EPISODE_WINDOW` (4 horas), anterior al turno actual, guardado entero (`stored_whole?`), y que cumple `explicit_question?` del rewriter. Máximo los últimos `EPISODE_MAX_USER_MESSAGES` (3) turnos de usuario anteriores, con la misma semántica que `previous_users` (l.194–198). No se usa el texto del assistant para armar opciones.

**Tramo.** Una consulta recuperable más los turnos de usuario que la siguen y **no** son pregunta explícita, hasta la recuperable siguiente o hasta el turno actual. Se unen con `\n`. Un turno no explícito que no tiene ninguna recuperable antes en la ventana no pertenece a ningún tramo y se ignora.

**Dedup (V11).** Agrupar por `normalize_label(texto_del_tramo)` y conservar la ocurrencia más nueva. No por el texto de la pregunta.

**Puerta de entrada (V3).** El bloque sólo actúa si: `followup.applied == false`; `Rag::ThreadMenuFlag.enabled?`; canal `web`; sin imágenes y sin documentos; `conv_session` presente; `selection_turn?` falso (V6); `new_question?(turno)` falso; y `closed_followup_shape?(turno)` verdadero. Si cualquiera falla, el turno sigue el camino de hoy sin tocarse.

**Regla.**

| Recuperables tras dedup | Qué pasa | Bedrock |
|---|---|---|
| 0 | El turno se busca tal cual. | El camino de hoy. |
| 1 | `effective_question = tramo + "\n" + turno_actual`. Si el turno actual ya está contenido en el tramo, no se duplica. El resolver también recibe el texto compuesto (V7). | Una generación, con la consulta unida. |
| 2 a 3 | No se busca. Menú: una opción por tramo más «Es una consulta nueva». | Cero. |
| cualquiera, si algún tramo compuesto > 442 | No se une y no se abre menú. Se busca solo y se registra `budget_exceeded` (V14). | El camino de hoy. |

**Supresión del menú ya preguntado (V2).** No se abre menú si el último mensaje de assistant del episodio, comparado contra `I18n.t("rag.thread_menu_prompt", locale:).truncate(300)` en `es` y en `en`, es el copy del menú, **y** el último mensaje de usuario anterior a ese, normalizado, es igual al turno actual normalizado. En ese caso el turno se busca solo. Es lo que corta el bucle del chip «Es una consulta nueva». Límite aceptado y documentado: si el técnico ignora los chips y escribe otra aclaración corta distinta, el menú **sí** vuelve a abrirse, porque el texto no coincide; lo que no se repite es la misma pregunta sobre el mismo texto.

**Chips.** Tope 4 (`MAX_MENU_OPTIONS`). Chip de tramo: `query = tramo + "\n" + turno_actual`; `label` = las líneas del tramo unidas con ` — ` y truncadas a 48 caracteres (V19). Chip de consulta nueva: `query = turno_actual`, `label = I18n.t("rag.thread_menu_new_query")`, y va **último**. El chip de tramo no reabre el menú porque su texto lleva `\n` y no pasa `closed_followup_shape?` (V3), no porque lleve una marca.

Un turno con imagen no abre el menú ni une. Sigue el camino de foto. La pregunta de esa foto sí puede ser recuperable después: en el episodio real u5 es una pregunta de foto y es recuperable.

**Diff esperado de F1.** Nada más que esto:

1. `app/services/rag/thread_menu_flag.rb` — nuevo, copia exacta del patrón de `episode_scope_flag.rb`.
2. `app/services/rag/episode_thread_resolver.rb` — nuevo, PORO, sin HTTP, sin persistencia. Contrato en el Anexo B.
3. `app/services/rag/followup_query_rewriter.rb` — publicar los 5 predicados como métodos de clase, delegando (V17). Sin cambio de comportamiento.
4. `app/controllers/concerns/rag_query_concern.rb` — mover `resolved_output_channel` de l.129 a después de l.62; el bloque nuevo entre l.77 y l.80; `resolve_scoped(effective_question, ...)` en l.83.
5. `config/locales/rag.es.yml` y `rag.en.yml` — las dos claves de V5.
6. `app/javascript/controllers/rag_chat_controller.js` — `slice(0, 4)`; escapado de `"`, `'` y `\n` en `data-query` (V4); opcional el `aria-label` de V18.
7. Tests: unitarios de `Rag::EpisodeThreadResolver`; de concern reusando el arnés existente; y uno que fije V12 (el copy del menú **no** entra a `blocked_assistant_copies`).

**Qué la refutaría.** Que el menú aparezca en el episodio real de u8, donde la medición dice que corresponde unir. Que el compuesto medido pase de 442. Que un chip vuelva a abrir el menú. Que el menú necesite el final truncado del assistant para armar las opciones.

**Fuera de F1.** Elegir la explícita más nueva cuando hay varias. Reglas especiales para «sí», «me refiero» o typos. Filtrar por URI citada. Bandeja de hilos. Tocar `generation.txt`. Activar la sesión de Bedrock (V21). Cualquier segunda llamada al modelo (restricción 13).

## Fase 2 — Holdout (sesión que no tocó F1)

Máximo 2 `retrieve_and_generate`, sobre el candidato, no desplegado.

1. **El episodio real completo** (u1–u8, ya no un episodio sintético de una sola consulta): la consulta efectiva tiene que ser el compuesto de 114 caracteres con la pregunta de los resortes, `ThyssenKrupp Synergy` y la aclaración. La respuesta no incluye la cota `102 mm` ni los seis pasos de la escalera OTIS. **No se exige `entity_filter`**: ni `ThyssenKrupp` ni `Synergy` pasan `specific_token?`, así que la corrida correcta va sin filtro, igual que el `entity_filter: null` medido en H2 (V7).
2. Episodio con dos consultas explícitas **distintas** después de la dedup de V11, y el mismo texto de aclaración. Cero generación. Hay chips, la consulta nueva es el último. Elegir el chip de los resortes produce la unión y recién ahí hay generación; esa segunda generación es la misma corrida 1 si el texto unido coincide, y no se paga dos veces.

Verificaciones que **no** gastan generación y son obligatorias en el holdout: que 4 chips se rendericen los 4 en un viewport de 390 px de ancho sin empujar la respuesta fuera de pantalla (CS-H08/V19), y que un `data-query` con `"` y con `\n` sobreviva el ida y vuelta del chip (V4).

**Criterio congelado antes de abrir el holdout.** Seguridad, independiente del resto: la respuesta de la fijación de cables no copia los pasos ni la cota 102 mm de la escalera OTIS 506 NCE como el ajuste a ejecutar. Nombrar que apareció otro manual no alcanza si los pasos van como instrucción de la fijación. Si eso ocurre, el ciclo del menú no se despliega. No se improvisa ahí el lever de CS-H05 ni un filtro de URIs.

## Fase G — Guía desde el RAG, o inferencia (otra sesión, no junto al menú)

Afinado de CS-D02 con CS-H05, y es la capa 2 de la arquitectura objetivo: es acá donde aparece el comportamiento de copiloto de CS-H06. No se abre en la sesión que implemente el menú. No hay una segunda búsqueda ni un índice nuevo: se usa el conocimiento que este turno ya recuperó, índice incluido si vino en los chunks.

⚠️ **Hallazgo de la validación: el delta real de esta fase es más chico de lo que el plan decía.** `generation.txt` ya trae implementados los puntos 4 y 5 de abajo: l.145–146 prohíbe el cierre genérico de seguridad y exige que la nota salga de la evidencia, y l.148 ya limita a una sola pregunta por turno, sólo si la respuesta cambiaría, y ya fija el orden de preferencia (identificación, observación de campo, foto). Lo nuevo de CS-H05 es únicamente el punto 2 (la analogía desde otro modelo o equipo) y el descargo del punto 3. Y ahí hay una colisión que la sesión de Fase G tiene que resolver explícitamente, no esquivar: **l.141 prohíbe hoy «no values, turns, torques, sequences, or prescribed intervention» dentro de `Interpretación técnica:`, y CS-H05 pide armar una guía desde la analogía, que es exactamente una secuencia prescrita.** Aflojar esa prohibición es el cambio de mayor riesgo de seguridad de todo el ciclo. No se toca sin su propio holdout y su propio gate.

Además, el comportamiento de copiloto que pide CS-H06 —decir si el turno se tomó como continuación o como consulta nueva, y nombrar el supuesto— es barato acá y no en otra parte: el episodio **ya** viaja en el prompt (`## Recent Conversation`, V20), así que es prompt y cero llamadas nuevas.

Orden de la respuesta:

1. Si el índice o los chunks traen datos para responder la consulta, la guía sale de ahí, citada.
2. Si no está el procedimiento de esta consulta, busca en ese mismo conocimiento un procedimiento parecido, u otro modelo o equipo sobre el que quepa una analogía. Lo nombra y dice de qué manual sale.
3. Bloque `Interpretación técnica:` con la guía inferida. Sin marcadores `[n]` en la inferencia. El descargo va en ese bloque: no es una verdad absoluta para este equipo.
4. En esa guía van los aspectos de seguridad indispensables que el conocimiento recuperado asocia al trabajo, para considerarlos antes de actuar. No se agrega un cierre genérico que los chunks no traigan.
5. Una pregunta más, al final, solo si un dato concreto la haría más precisa: tuerca, medida, peso, u otro igual de relacionado. Si nada de eso la cambiaría, no pregunta.

La analogía sin descargo, o presentada como el procedimiento del fabricante para este trabajo, falla. La fase del menú no usa esta forma para disculpar una búsqueda que perdió el hilo: si el turno se buscó solo y la escalera OTIS aparece como el ajuste de la fijación, el holdout del menú sigue en rojo.

Lever: únicamente líneas `- GROUNDED_SYNTHESIS:` de `generation.txt`, más la actualización de PRODUCT_ROADMAP y AGENTS que CS-D02 ya exige en la sesión que lo implemente. `# NO MATCH` no se edita. Presupuesto de esa sesión: lo fija quien la abra; esta revisión no autoriza llamadas.

## Fase S — Estructuras de consistencia (CS-H07, sin autorización de ejecución)

Registrada para que no se improvise dentro de F1. MVP sin clientes: consolidar lo que ya existe, no agregar capas.

| # | Qué | Por qué | Riesgo de no hacerlo |
|---|---|---|---|
| S1 | Una sola definición de episodio. Hoy hay cuatro traversales distintos sobre `conversation_history` (V22). Consolidar en un accessor estructurado —índice, rol, ts, `correlation_id`, entero o truncado— que consuman el rewriter, el servicio de F1, `SessionContextBuilder` y `inherit_episode_scope`. | Es la «estructura de consistencia» que pide CS-H07. Cambio de comportamiento nulo si se hace bien, y habilita todo lo demás. | Dos definiciones de «pregunta explícita» que se separan sin que ningún test lo note. Es la falla que este plan está arreglando. |
| S2 | Compactar en vez de truncar (H6, punto 5 del grounding). Guardar la pregunta final del assistant aparte del `content` truncado a 300. | Hoy la pregunta al técnico se pierde y ni el menú ni el modelo la pueden leer. Los dos copilotos resumen en vez de cortar. | El copiloto repite preguntas ya hechas, que es justo lo que l.148 prohíbe y no puede verificar. |
| S3 | Trazar la decisión del hilo en un log estructurado `[RAG_THREAD]` con conteo de recuperables, decisión, longitud compuesta y hashes. Sin tabla nueva y sin columna nueva (restricción 9). | Sin esto, «el menú se abrió cuando no debía» no es auditable en producción. | El holdout es la única evidencia que va a existir. |

Recomendado primero S1, porque no cambia comportamiento y es la base de S2 y S3. Ninguna de las tres está autorizada por este documento.

## Fase 3 — Checkpoint de despliegue

Solo después del holdout en verde. Imagen distinta de `9977c7a`. No mezclar con otro lever. Smoke, los tres: un turno ambiguo no crea fila de `retrieve_and_generate`; un turno unido crea exactamente una; y `RAG_THREAD_MENU_ENABLED=false` devuelve el comportamiento de hoy sin redeploy (restricción 11).

## Presupuesto del ciclo

| Fase | Retrieve | retrieve_and_generate |
|---|---|---|
| Validación del plan | 0 | 0 |
| F0 | 0 | 0 |
| F1 | 0 | 0 |
| Holdout | 0 | máximo 2 |
| Menú en producción, cuando exista | 0 | 0 |

## Estado

| Fase | Estado | Artefacto / hash |
|---|---|---|
| Plan | **Validado contra código el 21-sep-2026, noche.** V1–V22 incorporados. CS-H06, CS-H07 y CS-H08 registrados. Restricciones 11–13 nuevas. Medición offline del episodio real hecha. R1–R4 de la tarde siguen válidos, salvo R2 (la «marca» se resuelve por forma y por supresión, V2/V3) y R3 (la dedup va por tramo, no por pregunta, V11). | Este archivo. |
| F0 | **Cerrada 21-sep-2026, noche.** u7 y u8 verbatim. Una recuperable, unión, 114 caracteres. Ver «Resultados de la Fase 0». | Sesión 6, lectura sin escritura. |
| F1 | **Implementada en esta sesión, sin desplegar.** Unión si queda 1 tramo; menú de hasta 4 chips si quedan 2 o 3. Flag `RAG_THREAD_MENU_ENABLED`. No toca `generation.txt`. | `Rag::EpisodeThreadResolver`, `Rag::ThreadMenuFlag`. |
| Holdout | No empezado. | — |
| Fase G | No empezada. Otra sesión. No bloquea el menú. Delta reducido: l.145–148 ya cubre los puntos 4 y 5; queda la colisión con l.141. | — |
| Fase S | Registrada, sin autorización. | — |

## Protocolo de plan vivo

1. Actualiza tu fila de Estado.
2. Corrige fases posteriores afectadas por tus hallazgos.
3. Actualiza el prompt de la fase siguiente. Si cambia la implementación, márcalo con `⚠️ CRÍTICO:`.
4. Si un hallazgo contradice una restricción o el gate: no se ejecuta. Se escala como decisión humana numerada.

## Anexo A — Prompt de arranque por fase

**Pie común:** restricciones 1–13. CS-H01 a CS-H08. Cero Bedrock salvo el holdout. No adivinar el hilo. F1 no edita `generation.txt`. Fase G y Fase S son otras sesiones. Toda la validación V1–V22 ya está incorporada: no la vuelvas a derivar, ejecutala.

### Validación — cerrada

> Cerrada el 21-sep de noche. No la repitas. Si encontrás un hueco nuevo, agregalo como fila `V23+` con archivo y línea, y decí qué restricción o gate obliga a cambiar.

### Fase 0 — cerrada

> Cerrada el 21-sep de noche. Los ocho puntos están en «Resultados de la Fase 0». No la repitas. u7 y u8 quedaron verbatim; el episodio real se une en 114 caracteres.

### Fase 1 — ejecutada al cerrar F0

> F0 quedó cerrada con los números de «Resultados de la Fase 0»: el episodio real se une (114 caracteres) y el menú es el fallback. Alcance: los 7 puntos del «Diff esperado de F1» y el Anexo B. `previous_users` primero, predicados después. No ramificar por `reason`. No editar `generation.txt`. Holdout, Fase G y Fase S no entran en esta sesión.

## Anexo B — Contrato del servicio nuevo

`app/services/rag/episode_thread_resolver.rb`. PORO. Sin HTTP, sin Bedrock, sin escrituras, sin queries nuevas: lee `conversation_session.conversation_history`, que ya está en memoria.

```ruby
Rag::EpisodeThreadResolver.call(
  question:,              # el turno crudo, ya stripeado
  conversation_session:,
  correlation_id:,
  locale:,                # para el copy y para la supresión de V2
  now: Time.current
) # => Result

Result = Data.define(:outcome, :composed, :options, :reason, :recoverable_count)
# outcome: :pass | :join | :menu
# composed: String, sólo en :join
# options:  Array<{label:, query:}>, sólo en :menu, máximo MAX_MENU_OPTIONS = 4
# reason:   string corto para el log: passthrough, joined, menu,
#           budget_exceeded, already_asked, not_followup_shape, no_recoverable
```

Constantes propias: `MAX_MENU_OPTIONS = 4`, `MAX_LABEL_CHARS = 48`. El tope de composición se reusa de `Rag::FollowupQueryRewriter::MAX_COMPOSED_CHARS` (442), no se redefine.

Orden interno, y es el orden en que hay que escribirlo:

1. `:pass` si la flag está apagada, si no hay sesión, si el canal no corresponde, o si `new_question?(question)` o `!closed_followup_shape?(question)` (V3).
2. Armar las filas del episodio con índice y ts, con la misma semántica que `episode_rows` del rewriter (ventana de 4 horas, fila sin ts parseable afuera).
3. Ubicar el turno actual por `correlation_id` y, si no está, por texto exacto; excluirlo por índice, nunca por igualdad de contenido (V15).
4. Recuperables = los últimos 3 turnos de usuario anteriores (`previous_users`) que pasan `explicit_question?` y `stored_whole?`. No son los últimos 3 que pasan el predicado en toda la ventana: esa lectura abre el menú en el episodio real (F0 punto 5).
5. Tramos, dedup por `normalize_label` del tramo conservando el más nuevo (V11).
6. `:pass` con `reason: "budget_exceeded"` si algún tramo compuesto pasa de 442 (V14).
7. `:join` si queda 1. `:composed` = tramo + `\n` + turno, sin duplicar si ya está contenido.
8. Si quedan 2 o 3: `:pass` con `reason: "already_asked"` si aplica la supresión de V2; si no, `:menu`.

Los cinco predicados (`explicit_question?`, `stored_whole?`, `closed_followup_shape?`, `new_question?`, `normalize_label`) se llaman como métodos de clase del rewriter. **No se copian** (V17).

## Qué NO está en este plan

- Bandeja de conversaciones, botón de consulta nueva como producto, o borrar la sesión 6.
- Elegir automáticamente la última pregunta cuando hay varias.
- Reglas especiales para «sí», «me refiero» o typos.
- Filtrar la búsqueda a los manuales citados en el turno anterior. Solo vuelve si el holdout falla el gate de la escalera OTIS, y como decisión nueva.
- Cambiar `generation.txt` en la fase del menú. CS-H05 lo cambia en otra sesión, solo en líneas `- GROUNDED_SYNTHESIS:`.
- Reescribir CS-D02 o correr F2 del plan de continuidad.
- Presentar una analogía como verdad absoluta o como el procedimiento documentado de este equipo.
- Inventar un procedimiento sin conocimiento citado en la evidencia de ese turno.
- Un router de intención, un reescritor con LLM o un clasificador: sería una segunda llamada facturada por turno y la literatura de dominios con identificadores lo desaconseja (restricción 13, grounding 3).
- Reusar el `sessionId` de Bedrock para la continuidad. Está disponible y sin usar en web (V21), y queda como decisión humana nueva: le entrega la reescritura de la consulta a una caja negra de 24 horas que no se puede auditar ni fijar con un test.
- Marcar el chip con un parámetro del navegador. La supresión es del lado del servidor (V2).
- Agregar tabla o columna para trazar la decisión del hilo. Log estructurado, y recién en Fase S.
