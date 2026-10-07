# Field Companion: conversación técnica real

**Estado: PENDIENTE DE REVISIÓN OPUS Y VALIDACIÓN FINAL DEL FUNDADOR.**

Este documento es el único plan vigente del companion. Una revisión documental no lo deja listo para piloto. Este cambio no implementa producto, no llama a Bedrock y no despliega.

Pregunta rectora: ¿Danebo puede acompañar una conversación técnica real, encontrar documentación pertinente, incorporar lo comprobado y distinguir casos hasta llegar a una respuesta útil?

Ancestro de trabajo: `738b4c6`. Los planes anteriores conservan su historia. Sus encabezados apuntan aquí. Section O del [plan del 6 de octubre](PLAN_FIELD_COMPANION_MVP_CONTINUITY_RECOVERY_2026-10-06.md) queda como regresión secundaria del instrumento A‴. O-P2 a O-P5, F3b y F4 no se reanudan.

## Objetivo

Danebo acompaña como el equipo de ingeniería en campo. Comprende la consulta y lo que ya se sabe del equipo, busca documentación pertinente, guía el diagnóstico o el procedimiento con esa evidencia, incorpora resultados, correcciones y comprobaciones, y sigue hasta una respuesta útil, una verificación o un escalamiento fundamentado. Distingue casos distintos dentro de la misma conversación.

No es un formulario ni una secuencia obligatoria de preguntas. Equipo, fabricante, modelo, controlador, operador, tarea, falla, componente, código y observaciones son dimensiones para comprender y acotar la búsqueda. Identificar el equipo temprano puede ser necesario. En una consulta de puertas, identificar el operador puede servir más que completar la identidad del ascensor. Si la sesión, el texto, la foto o la documentación ya traen el dato, se reutiliza.

Buscar puede ayudar a identificar el equipo. No se exige completar campos antes de buscar. Un manual recuperado no demuestra por sí solo que aplique a este equipo.

La próxima respuesta puede ser directa, una búsqueda más precisa, una explicación o una aclaración. No hay una pregunta obligatoria en cada turno.

Si el primer mensaje ya nombra el equipo y ese equipo coincide con un manual que contiene la respuesta, se busca en ese turno. Se pide evidencia solo cuando, sin ella, no se sabe qué manual consultar. Mientras esa evidencia no está, la respuesta no trae un procedimiento técnico. Con evidencia, puede entrar un paso general y rudimentario. El dato del manual entra cuando el manual coincide con el equipo y contiene la respuesta. La orientación y las hipótesis de Danebo pueden aparecer, identificadas como tales. No se inventan valores, terminales, códigos ni instrucciones específicas del fabricante.

Un pin de sesión orienta la búsqueda y no prueba aplicabilidad. El sistema no lo suelta en silencio (FC-D17).

## Referencias industriales

Las páginas siguientes son evidencia publicada, citada por el fundador. Este cambio no las vuelve a descargar. Lo que sigue es el patrón que esas páginas describen, no una auditoría de su implementación. La conclusión de Danebo es una decisión propuesta, no algo que esas páginas ordenen.

- ABB My Measurement Assistant+ / Genix Copilot: [página de servicio](https://new.abb.com/products/measurement-products/service/advanced-services/remote-support-services/my-measurement-assistant). Publica identificación por placa, AutoID y QR, documentación del dispositivo, interpretación de errores, asistencia específica y acceso a expertos. Patrón publicado: identidad accesible, conocimiento pertinente, asistencia fundamentada.
- Siemens Maintenance Copilot / Asset Essentials: [documentación](https://help.assetmanagement.siemens.com/help/Content/Documentation/Maintenance/Asset%20Essentials/EnterpriseFeatures/AI-Driven%20Capabilities/Maintenance%20Copilot.htm). Trabaja sobre una orden asociada a un activo. Usa manuales e historial para diagnóstico, causas posibles y reparaciones, con documento y página. Patrón publicado: activo, problema, antecedentes y documentación.
- Siemens Senseye: [nota de prensa](https://press.siemens.com/global/en/pressrelease/generative-artificial-intelligence-takes-siemens-predictive-maintenance-solution-next). Describe conversación de mantenimiento y contextualización con casos anteriores y sus soluciones.
- Wittur ElevatorSense: [página del producto](https://www.wittur.com/elevatorsenseinfo/). Combina hardware y aplicación para pruebas, análisis de puertas y recomendaciones a partir de resultados. La fuente no demuestra que sea un chatbot RAG. Este plan no lo trata como uno.
- Microsoft Dynamics 365 Contact Center: [Ask a question](https://learn.microsoft.com/en-us/dynamics365/contact-center/use/use-ask-a-question). Describe preguntas libres, seguimientos y cambio de contexto al seleccionar un caso. No demuestra detección automática de episodios dentro de una conversación libre.

Decisión propuesta para Danebo: esos productos reciben el activo por una orden, un QR o una conexión. Danebo tiene que adquirir o reutilizar ese contexto con lenguaje natural y evidencia. No se copia su arquitectura. IoT, órdenes de trabajo y módulos nuevos no son requisitos del MVP.

## Puertas, como patrón publicado

El troubleshooting del operador LD-16 está publicado por TKE en el [manual de operador](https://shop-us.tkelevator.com/media/download_files/component_manuals/ld_16_door_operator_manual.pdf) y en [esta versión](https://shop-us.tkelevator.com/media/download_files/component_manuals/ld_16_udo.pdf). Documenta, para ese operador: puerta sin movimiento, no abre o no cierra, apertura o cierre parcial, no reabre, fallos por LED, rendimiento reducido y problemas de comunicación entre operador y controlador. Las ramas consideran alimentación, órdenes, fricción, motor o encoder, reapertura, aprendizaje, temperatura, referencia y comunicación.

Eso es el mapa documentado de ese operador. No es un ranking universal de frecuencia ni un procedimiento para cualquier ascensor. No hay un corpus representativo de conversaciones reales. Las frases de los journeys son ejemplos de aceptación, no transcripciones.

`config/document_identities.yml` no contiene el LD-16. Sí contiene el Elemont MH (`Montacargas 2N Temporizado`) y otros documentos de puerta (E-Shine YS-K01, variador Thyssen MCP7, puertas KES). Esos otros documentos no se enseñan como procedimiento del Elemont. La validación reutiliza el journey A de puertas del Elemont. No se agregan turnos, no se inyectan cuerpos de chunk y no se inventan códigos. Antes de la etapa 2 se comprueba que el manual del Elemont MH esté en el índice del entorno. Si no está, esa ejecución se detiene en `RETRIEVAL_EMPTY` y no se sustituye por el LD-16.

## Hallazgos confirmados en el código

Ruta de producción, con `HAIKU_QUERY_ANALYSIS_MODE=owner` y los flags de episodio y turno: `RagController#ask` → `ConversationSession#record_owner_turn!` → `Rag::TurnInterpreter` → `Rag::RoutePolicy` → `Rag::WorkContextReducer` → `Rag::QueryComposer` → `SessionContextBuilder` → `RagQueryConcern#execute_rag_query` → `QueryOrchestratorService` → `BedrockRagService`.

El intérprete usa `BedrockClient#converse`. `converse_message` es otro cliente. El harness longitudinal (`script/field_companion/longitudinal_journeys.rb`) niega `converse_message` y no niega `#converse`. `Runner#run` no es una sonda: ejecuta los journeys con percepción escrita en el fixture, KB `mvp-journey-stub` y un chunk congelado. Un PASS de ese harness demuestra que el estado se actualiza cuando la percepción ya viene escrita. No demuestra que Haiku comprenda la frase.

Límites de sesión, en `ConversationSession`: `MAX_HISTORY = 20` mensajes de usuario y asistente; `EPISODE_MAX_USER_MESSAGES = 3`; `EPISODE_WINDOW = 4.hours`. No son un máximo de consultas. El historial se recorta con `last(MAX_HISTORY - 1)`. El episodio vive en `active_episode` y no se borra por ese recorte. El último mensaje del asistente que entra al prompt se corta a 200 caracteres.

Observaciones:

- `QueryComposer#observations` las mete en la cadena de retrieval.
- `SessionContextBuilder#render_field_problem` no las recorre. Arma hechos, identificadores, foto, conflictos y objetivo.
- `MAX_PROBLEM_CHARS = 400`. El encabezado mide 79 caracteres y el pie 188. Con los dos saltos de línea ocupan 269. `fit_problem` acorta primero el objetivo y después descarta líneas. Encabezado y pie se conservan.
- El guidance de identidad conocida (`CompanionGuidanceContext#turn_block`) lee objetivo, identidad y las dos últimas líneas `User:` (`TURN_CHARS = 160`, `MAX_TURNS = 2`). No lee el resto del bloque de problema.
- El guidance de identidad desconocida lee `problem_projection_lines`. Con cero chunks y sin pin, `BedrockRagService#open_reference_no_results` responde el texto fijo «No se encontró información…» y no arma guidance. Reparar solo el builder no alcanza si el guidance no usa esas líneas, ni si la ruta de cero chunks no tiene prompt.

Pregunta de controlador:

- `RoutePolicy#ask_controller?` arma `search_and_clarify` cuando hay fabricante, no hay modelo ni controlador, y hay síntoma.
- `ask_when: :always`. `RagQueryConcern#append_turn_clarification` agrega «¿Qué controlador o modelo estás revisando?» aunque la búsqueda ya pueda hacerse.
- `clarify_first?` no busca y no escribe observaciones. Devuelve falso si la percepción ya trae observaciones, hechos o un identificador afirmado. El síntoma se pierde por `unclear`, por fallback o porque el intérprete no extrajo observaciones.
- El fallback de un episodio vacío y sin foco también pregunta el controlador antes de buscar.
- En el catálogo, `MH` es designador del Elemont y `CEA15+` es el designador del manual CEA15, no el token `CEA15`. Un designador que no queda como hecho `model` o `controller` no cancela `ask_controller?`.

Guidance:

- `ADVANCE_FAULT` dice «Equipment identity is not the current objective» cuando el turno no pide identificar el equipo.
- Si ese objetivo está activo y no hay estado reportado, `TASK_LEAD` pide una comprobación pasiva de una lista fija: ocupación, posición de cabina, estado de puertas, display o sonido.
- `RESOLVE_IDENTITY` pide leer la placa. `nameplate_rule` en el otro caso dice que la identidad desconocida limita las afirmaciones del fabricante y no debe ser la pregunta principal.
- Esas frases pueden sesgar el turno hacia una pregunta que la consulta no necesita. La reparación no consiste en preguntar siempre la identidad. Depende de la consulta, del contexto y de si la documentación ya se distingue.

Correcciones, en dos capas distintas:

- Identidad o código: el prompt del intérprete dice «A correction has empty observations» y exige un span negado y uno afirmado para fabricante, modelo o controlador. `TurnPerception#adjust_move` convierte `correct` sin negación de slot en `unclear`, vacía identidades y vacía observaciones. El reducer adopta un código de reemplazo solo cuando el movimiento ya es `correct` y el slot negado es `fault_code`.
- Observación («planta 1», «por arriba», «ya revisé eso»): no es un slot. Si el modelo emite `correct` sin negación de slot, `adjust_move` borra la observación antes de que el reducer escriba. El prompt empuja al modelo a dejar esas observaciones vacías. La capa responsable de esa pérdida es el intérprete y `adjust_move`, no el reducer. `QueryComposer#current_turn` solo recorta spans negados; el turno literal puede conservar «no de planta 1». Una línea `User:` anterior puede conservar un valor ya descartado. Eso es un hallazgo aparte: falla si la respuesta publicada lo trata como vigente.

Continuidad:

- `new_work` evalúa la política sobre un `ActiveEpisode` vacío y abre otro con `ActiveEpisode.open`. El episodio nuevo no hereda identidad, síntomas, foto ni resultados del anterior.
- `case_boundary_changes` limpia `current_procedure` y deja `pin_release_reason` en nil. El pin de sesión permanece. Persistirlo no prueba que aplique al caso nuevo.
- El escritor tardío se rechaza con `expected_episode_id`.
- No hay almacén de episodios anteriores ni una operación de la ruta owner que reabra un caso cerrado. `voice_dictation` reabre otra cosa y no cuenta como recuperación de episodio. Recuperar un caso anterior no está implementado.

Retrieval vacío no demuestra que el manual no exista. Una respuesta útil sin documentación compatible no es éxito documental. A‴ no recorre esta ruta: en Section N quedó useful 28/68, S3 4/44 y unsafe humano confirmado 0. Esos números se conservan. No son la puerta de esta validación.

## Recomendaciones que no se copian

- Conservar solo la observación más reciente. Borraría «ya revisé eso y está bien». La reparación mínima conserva comprobaciones y correcciones que cambian el paso siguiente, dentro del presupuesto existente.
- Una sonda completa sin retrieval ni generación, y repetirla, como requisito general. Un defecto visible en el código se reproduce con un test local. No se paga una llamada para confirmar que existe.
- Preguntar la identidad en todos los turnos para corregir el sesgo contrario. La identidad se pide cuando la consulta o la evidencia documental lo necesitan.
- Tratar el LD-16 como corpus de prueba o como chatbot de referencia. No está en el catálogo local y la página de Wittur no demuestra un RAG.
- Declarar implementada la recuperación de un caso anterior.
- Cerrar O-P1 porque no hay archivos en git, o cerrarlo porque el fundador informó que terminó. Las dos afirmaciones conviven hasta que haya un artefacto.
- Reanudar O-P2 a O-P5, agregar scorer, benchmark grande, ramas por fixture o una llamada de producto extra.
- Una tabla o un módulo nuevo de episodios. Se reutilizan `active_episode`, `new_work` y la protección del escritor tardío.

## Inventario

| Gap | Decisión |
|---|---|
| Discovery F0–F8, visual F1–F3, R1A, harness scripted scope.1 | Resuelto con evidencia en sus planes. |
| Observaciones fuera del prompt de generación y presupuesto de 400 que prioriza encabezado y pie | Necesario. Etapa 1. |
| `ask_controller?` con `ask_when: :always` y fallback que pregunta antes de buscar | Necesario. Etapa 1. |
| `TASK_LEAD` y el objetivo de identidad como sesgo de pregunta | Necesario, acotado. Etapa 1 cambia la instrucción; no invierte el sesgo. |
| Corrección de observación destruida por el prompt y `adjust_move` | Necesario. Etapa 1. La calidad del intérprete real se ve en la etapa 2. |
| Corrección de identidad o código (8→18, Fuji Yida→KONE) | Parcial. El reducer ya adopta el código cuando el movimiento es `correct`. La etapa 2 comprueba el intérprete real. |
| Hechos del episodio que sobreviven al recorte de 20 mensajes | Parcial. El JSON del episodio sobrevive; el prompt no. La etapa 1 proyecta lo necesario. La etapa 2 cruza el recorte. |
| Episodio nuevo sin heredar el caso anterior; pin de sesión que no prueba aplicabilidad | Parcial, ya en código. La etapa 2 lo comprueba con el texto L3 existente. |
| Recuperar un caso anterior dentro de la sesión | No implementado. Pospuesto. Separar hacia adelante alcanza para esta validación. Un archivo de casos sería una tabla nueva. |
| R2 del 30 de septiembre (consulta KONE sobre un episodio Elemont vivo, pin MonoSpace, código 515) | Absorbido como mapa. Esos tres restos quedan pospuestos salvo que una traza de la etapa 2 los muestre. |
| Hilo de consulta en la ruta web owner | Sustituido por `QueryComposer`. |
| F9, soltar el pin | Retirado de esta cola. Contradice FC-D17. |
| T3, R3, CG-D19, CS-P01 a CS-P03 | Retirados de esta validación. CG-D19 solo vuelve si la etapa 2 muestra una respuesta inutilizable por el formato. |
| Smoke de producción R1B, verificación de producción N1–N6, G5 de foco, presentación | Pospuestos. No se cierran por quedar fuera. El smoke de la etapa 3 es el del companion, no esos pendientes. |
| O-P1 | Incierto. Ver abajo. |
| Si Haiku extrae movimiento, observaciones y correcciones; si el índice devuelve el Elemont MH; si cero chunks es índice frío o manual ausente | Incierto hasta la etapa 2. No se confirma con una sonda previa. |

## O-P1

El fundador informó que O-P1 terminó. En el repositorio, incluido el árbol de trabajo, no están `architecture_faithful_s3.yml`, `architecture_faithful_s3.rb` ni `architecture_faithful_score.rb`. La ausencia en un commit no descarta una ejecución local fuera de este árbol. El informe tampoco deja un artefacto visible aquí. O-P1 queda incierto. No se reanuda y no se da por cerrado. O-P2 a O-P5 no se reanudan.

De Section O se conserva, como regresión secundaria y sin volver a ejecutarla: A‴ no recorre el ciclo de vida; el pin no prueba aplicabilidad; `clarify_first` no busca ni guarda observaciones; no se inventan cuerpos de manual; los SHA y conteos históricos permanecen.

## Continuidad que debe sobrevivir

En el episodio vigente, después del recorte de historial: equipo vigente, problema, observaciones que cambian el paso, comprobaciones y resultados, correcciones, desconocimientos confirmados y pregunta pendiente.

La etapa 2 distingue, sin una tabla nueva:

- seguimiento del mismo caso;
- corrección del mismo caso;
- síntoma adicional relacionado;
- problema independiente en el mismo equipo;
- otro equipo u otra obra;
- referencia a un caso anterior.

Un cambio de componente no abre un episodio por sí solo. Ante un cambio claro, se separan los casos. Ante ambigüedad real, una aclaración mínima. El episodio nuevo no hereda identidad, síntomas, fotos ni resultados. El pin de sesión, si existe, no se trata como aplicabilidad del caso nuevo.

Abrir un caso nuevo está soportado con `new_work`. Recuperar uno anterior no está soportado. Queda pospuesto, con esa limitación escrita. No se declara implementado.

## Tres etapas

Ninguna etapa empieza con este documento. Hace falta la revisión de Opus, la validación del fundador con ChatGPT y la frase que autoriza la etapa. «Ejecuta la etapa 1» autoriza solo la etapa 1. No autoriza la 2 ni la 3. La etapa 2 no arranca sola aunque la traza nombre un dueño: esa regla anterior queda retirada. La etapa 3 pide su propia frase.

No se promete éxito después de un número fijo de reparaciones. Cada etapa se detiene cuando se cumple su resultado o su condición de parada.

### 1. Reparar los gaps confirmados

Reproducciones locales y tests Minitest. Sin Bedrock.

- Proyectar en el prompt final, de las dos rutas de guidance, el problema, las correcciones y las comprobaciones que cambian el paso. Acortar encabezado y pie para que el presupuesto de 400 no se los coma. No ampliar el presupuesto. No quedarse solo con la observación más reciente. Un test lee `turn_block` y el bloque de identidad desconocida, no solo `SessionContextBuilder`.
- No agregar la pregunta de controlador cuando el turno ya trae síntoma y un token de equipo (fabricante, modelo, controlador o identificador) y la búsqueda puede seguir. Conservar la aclaración cuando distingue documentos o permite avanzar. El fallback de un episodio vacío no pregunta el controlador antes de poder buscar el síntoma.
- Quitar el menú fijo de ocupación, posición, puertas, display y sonido cuando la consulta ya trae síntoma o una pregunta que se puede buscar. No sustituirlo por «pregunta siempre la identidad». La identidad sigue siendo el objetivo solo si el técnico pide identificar o confirmar el equipo.
- Distinguir en el prompt y en `adjust_move` la corrección de identidad o código de la corrección de una observación. La segunda no se convierte en `unclear` ni se vacía.

Resultado: los tests de esos cuatro puntos pasan. No hay llamada de modelo.

Parada: si la reparación exige una segunda llamada de producto, una tabla nueva o cambiar el presupuesto de 400, se detiene y vuelve al plan.

### 2. Validar conversaciones con búsqueda y respuesta reales

Intérprete, sesión, retrieval y generación, en la base local, con el índice real. Una pasada de tres escenarios ya escritos. No se crea otro corpus.

- Puertas y continuidad: journey A, turnos 1 a 14, más el texto L3 ya escrito en el mismo archivo de fixtures, en la misma sesión. El primer turno busca. Con las respuestas del asistente, el historial supera 20 mensajes. L3 es otro ascensor: si el intérprete emite `new_work`, el episodio nuevo no hereda la falla de puerta, el código ni la identidad. Si duda, una aclaración mínima no es fallo. El pin no se setea en el escenario.
- Equipo que al principio no se identifica: journey B, turnos 1 a 10. La primera búsqueda puede usar el síntoma. La identidad llega por el texto y por la foto ya guionada, sin Vision y sin formulario previo.
- Corrección de fabricante: los cuatro textos del técnico en T-F. No se inyectan las preguntas del asistente que trae el fixture.

Cada turno anota la decisión, si buscó, si el chunk es compatible con el equipo, si la respuesta usa ese chunk o se declara orientación de Danebo, y si conserva o descarta lo ya comprobado. `RETRIEVAL_EMPTY` no se anota como «el manual no existe». Una respuesta general sin documento compatible no se anota como éxito documental.

Se repara solo la falla observada y se repite solo el escenario que falló.

Presupuesto: 16 + 10 + 4 = 30 turnos de intérprete en la pasada inicial, más generación en los turnos que buscan. Los reintentos internos de producción (`retrieve_with_retry`, arranque frío, segundo retrieve, publicación y guidance) siguen activos y cuentan dentro del turno, no como otro experimento. Tope de la pasada, reintentos incluidos: 90 llamadas de generación. Una repetición usa solo los turnos del escenario reparado.

Parada: error de transporte en el primer turno de un escenario; el manual del Elemont no está en el índice; la misma falla vuelve después de una reparación; la reparación pide una tabla, un segundo modelo o un escenario nuevo. No se sigue para completar un cupo.

Aceptación de la etapa: en el primer turno del journey A se busca sin pedir fabricante, modelo ni controlador. Cuando el índice devuelve documentación compatible, la respuesta la usa y cita documento y página. Cuando no la devuelve, no inventa valores, terminales, códigos ni un procedimiento de fabricante, y no se anota como éxito documental. A los 14 intercambios siguen el equipo, el problema, las comprobaciones, las correcciones y la pregunta pendiente. El caso nuevo no hereda el anterior. Una pregunta repetida o un valor ya corregido tratado como vigente es fallo. Timeout, throttle o error de transporte es inconcluso, no un fallback de producto.

### 3. Smoke de producción y cierre

Primera consulta, continuidad de un caso y el cambio de episodio, sobre los mismos tres escenarios, en producción. Una pasada. Sin sonda previa.

Resultado: la misma aceptación de la etapa 2 contra el índice de producción, más una reconciliación final de la tabla de gaps. Los inciertos que el smoke no toque siguen inciertos. El companion no queda listo para piloto por haber pasado el smoke.

Parada: la misma de la etapa 2. Un fallo de producción no se repara en caliente dentro de esta etapa.

## Qué debe revisar Opus

- Si la etapa 1 cubre los huecos que el código confirma y no mete una sonda pagada para demostrarlos.
- Si acortar encabezado y pie, sin subir el presupuesto de 400 y sin dejar solo la última observación, alcanza para conservar problema, corrección y comprobación en las dos rutas de guidance.
- Si dejar de preguntar el controlador cuando ya hay síntoma y un token de equipo debilita un caso en el que dos manuales solo se separan por el controlador.
- Si cambiar `TASK_LEAD` quita el sesgo sin abrir la puerta a un procedimiento de fabricante sin evidencia.
- Si tratar la recuperación de un caso anterior como pospuesta es aceptable para el MVP.
- Si los tres escenarios alcanzan para la pregunta rectora sin turnos redundantes.
- Si el tope de 90 llamadas de generación, con los reintentos internos activos, es un límite de gasto y no una promesa de éxito.
- La discrepancia de O-P1: sin artefacto en el repo y con el informe del fundador. No hace falta elegir un lado para aprobar este plan.
- Las páginas industriales no se re-descargaron en este cambio. Si una frase atribuida no está en la página, se corrige el plan; no se copia la arquitectura de ese producto.
