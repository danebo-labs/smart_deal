# Field Companion: conversación técnica real

**Estado: ETAPA 2 BLOQUEADA.** No es `EPISODIO_VALIDADO`. La última evidencia de producción registrada en este plan es la imagen `6ca7788`: web y worker, `https://elevator.danebo.ai/up` en 200, y un POST real. Esa imagen contiene la etapa 1 (`78df58a`), el código de la corrección de planta que llega hasta ella desde `66dd9e0`, la regla de hipótesis y el contrato N4 (`71b83a4`). La corrección de planta no está revalidada. La expansión del nombre canónico quedó fuera de esa imagen. Un turno real no trajo el plano Elemont y no reabre la etapa. `47c43e2` es la base de la reparación de designadores; `700d9d0` la contiene, está en `main` y no forma parte de la imagen evidenciada. La composición por unidades del guidance quedó en `085969c`, en `main`, y tampoco está en esa imagen. La continuidad bajo presión quedó en `8274192`, en `main`, y no está en esa imagen. Al juntar la pregunta larga, la búsqueda vacía y la corrección de 217 caracteres, esa reparación conservaba la corrección y expulsaba el objetivo. Esa pérdida queda reparada en local: no está desplegada y no está revalidada. La pasada local aislada del journey A, sesión 1, sigue `BLOQUEADA`. Los defectos de planta, objetivo residual, identificador «clic», resumen técnico y captura del fallo del intérprete quedan reparados en local y no están revalidados. La clase de la excepción del turno 1 no está en la captura. El cumplimiento del modelo y la búsqueda documental del Elemont siguen pendientes. No es `EPISODIO_VALIDADO`. Faltan 202 filas del catálogo. La validación de producción sigue pendiente. La etapa 3 no empieza. La revisión Opus del 2026-10-07 sobre `7076f05` sigue incorporada. Esta revisión no habilita un piloto.

Este documento es el único plan vigente del companion. Una revisión documental no autoriza a empezar. La etapa 1 está en la imagen evidenciada `6ca7788`. Este documento no llama a Bedrock y no despliega.

Pregunta rectora: ¿Danebo sostiene un solo episodio técnico completo hasta una conclusión útil?

Ancestro de trabajo: `738b4c6`. Los planes anteriores conservan su historia. Sus encabezados apuntan aquí. Section O del [plan del 6 de octubre](PLAN_FIELD_COMPANION_MVP_CONTINUITY_RECOVERY_2026-10-06.md) queda como regresión secundaria del instrumento A‴. O-P2 a O-P5, F3b y F4 no se reanudan.

La luz verde de este texto autoriza las etapas 1, 2 y 3, en ese orden, dentro del alcance y del presupuesto de abajo. No autoriza el backlog. El backlog se prioriza y se autoriza después, como incremento aparte.

## Alcance inmediato

Un episodio es la consulta técnica en curso, con su equipo, su problema y lo que ya se comprobó. Puede contener incertidumbre, correcciones y comprobaciones que descartan hipótesis. No es un formulario ni un guion rígido.

Dentro de ese episodio Danebo:

- Comprende la consulta natural.
- Reutiliza e identifica lo necesario para buscar. Identificar el equipo temprano puede ser necesario. En una consulta de puertas, identificar el operador puede servir más que completar la identidad del ascensor. Si la sesión, el texto, la foto o la documentación ya traen el dato, se reutiliza. No se exige completar campos antes de buscar.
- Encuentra y utiliza documentación pertinente cuando existe. Un manual recuperado no demuestra por sí solo que aplique a este equipo. Buscar puede ayudar a identificar el equipo.
- Pide únicamente aclaraciones o comprobaciones que permitan avanzar: elegir qué manual consultar, establecer si un manual recuperado aplica, distinguir entre causas posibles, interpretar un resultado o decidir el siguiente paso. Identificar el equipo entra en esa misma regla. No se pide por rutina. No hay una pregunta obligatoria en cada turno.
- Incorpora resultados y correcciones. No repite una pregunta ni una comprobación ya hecha si no cambia el paso.
- Conserva los hechos críticos después del recorte del historial.
- Llega a una respuesta sustentada, una siguiente acción verificable o un escalamiento fundamentado.

No se garantiza que la falla física quede reparada.

Si el primer mensaje ya nombra el equipo y ese equipo coincide con un manual que contiene la respuesta, se busca en ese turno. Sin manual compatible, la respuesta no trae un procedimiento del fabricante. Puede traer orientación general de campo y la seguridad que esa secuencia exige. El dato del manual entra cuando el manual coincide con el equipo y contiene la respuesta. La orientación y las hipótesis de Danebo pueden aparecer, identificadas como tales. No se inventan valores, terminales, códigos ni instrucciones específicas del fabricante.

Un pin de sesión orienta la búsqueda y no prueba aplicabilidad. El sistema no lo suelta en silencio (FC-D17). En el journey de esta validación el pin no se setea.

Quedan fuera de esta ejecución, y no se cierran por quedar fuera: el cambio explícito de caso, el cambio ambiguo, el regreso tras una pausa, el journey B, T-F y la recuperación de un caso anterior. Están en el backlog.

## Referencias industriales

Las páginas siguientes son evidencia publicada, citada por el fundador. Este cambio no las vuelve a descargar. Lo que sigue es el patrón que esas páginas describen, no una auditoría de su implementación. La conclusión de Danebo es una decisión propuesta, no algo que esas páginas ordenen.

- ABB My Measurement Assistant+ / Genix Copilot: [página de servicio](https://new.abb.com/products/measurement-products/service/advanced-services/remote-support-services/my-measurement-assistant). Publica identificación por placa, AutoID y QR, documentación del dispositivo, interpretación de errores, asistencia específica y acceso a expertos. Patrón publicado: identidad accesible, conocimiento pertinente, asistencia fundamentada.
- Siemens Maintenance Copilot / Asset Essentials: [documentación](https://help.assetmanagement.siemens.com/help/Content/Documentation/Maintenance/Asset%20Essentials/EnterpriseFeatures/AI-Driven%20Capabilities/Maintenance%20Copilot.htm). Trabaja sobre una orden asociada a un activo. Usa manuales e historial para diagnóstico, causas posibles y reparaciones, con documento y página. Patrón publicado: activo, problema, antecedentes y documentación.
- Siemens Senseye: [nota de prensa](https://press.siemens.com/global/en/pressrelease/generative-artificial-intelligence-takes-siemens-predictive-maintenance-solution-next). Describe conversación de mantenimiento y contextualización con casos anteriores y sus soluciones.
- Wittur ElevatorSense: [página del producto](https://www.wittur.com/elevatorsenseinfo/). Combina hardware y aplicación para pruebas, análisis de puertas y recomendaciones a partir de resultados. La fuente no demuestra que sea un chatbot RAG. Este plan no lo trata como uno.
- Microsoft Dynamics 365 Contact Center: [Ask a question](https://learn.microsoft.com/en-us/dynamics365/contact-center/use/use-ask-a-question). Describe preguntas libres, seguimientos y cambio de contexto al seleccionar un caso. No demuestra detección automática de episodios dentro de una conversación libre. El cambio de caso que esa página describe no se valida en esta ejecución.

Decisión propuesta para Danebo: esos productos reciben el activo por una orden, un QR o una conexión. Danebo tiene que adquirir o reutilizar ese contexto con lenguaje natural y evidencia. No se copia su arquitectura. IoT, órdenes de trabajo y módulos nuevos no son requisitos del MVP.

## Puertas, como patrón publicado

El troubleshooting del operador LD-16 está publicado por TKE en el [manual de operador](https://shop-us.tkelevator.com/media/download_files/component_manuals/ld_16_door_operator_manual.pdf) y en [esta versión](https://shop-us.tkelevator.com/media/download_files/component_manuals/ld_16_udo.pdf). Documenta, para ese operador: puerta sin movimiento, no abre o no cierra, apertura o cierre parcial, no reabre, fallos por LED, rendimiento reducido y problemas de comunicación entre operador y controlador. Las ramas consideran alimentación, órdenes, fricción, motor o encoder, reapertura, aprendizaje, temperatura, referencia y comunicación.

Eso es el mapa documentado de ese operador. No es un ranking universal de frecuencia ni un procedimiento para cualquier ascensor. No hay un corpus representativo de conversaciones reales. Las frases del journey son ejemplos de aceptación, no transcripciones.

`config/document_identities.yml` no contiene el LD-16. Sí contiene el Elemont MH (`Montacargas 2N Temporizado`) y otros documentos de puerta (E-Shine YS-K01, variador Thyssen MCP7, puertas KES). Esos otros documentos no se enseñan como procedimiento del Elemont. La validación reutiliza el journey A de puertas del Elemont, turnos 1 a 14, sin L3. No se agregan turnos, no se inyectan cuerpos de chunk y no se inventan códigos. Antes de la etapa 2 se comprueba el acceso a la Knowledge Base de producción y que el retrieve devuelve el manual del Elemont MH. Una búsqueda vacía no demuestra que el manual no exista. Si el retrieve no lo devuelve, esa ejecución se detiene en `RETRIEVAL_EMPTY` y no se sustituye por el LD-16.

## Hallazgos confirmados en el código

Ruta de producción, con `HAIKU_QUERY_ANALYSIS_MODE=owner` y los flags de episodio y turno: `RagController#ask` → `ConversationSession#record_owner_turn!` → `Rag::TurnInterpreter` → `Rag::RoutePolicy` → `Rag::WorkContextReducer` → `Rag::QueryComposer` → `SessionContextBuilder` → `RagQueryConcern#execute_rag_query` → `QueryOrchestratorService` → `BedrockRagService`.

El intérprete usa `BedrockClient#converse`. `converse_message` es otro cliente. El harness longitudinal (`script/field_companion/longitudinal_journeys.rb`) niega `converse_message` y no niega `#converse`. `Runner#run` no es una sonda: ejecuta los journeys con percepción escrita en el fixture, KB `mvp-journey-stub` y un chunk congelado. Un PASS de ese harness demuestra que el estado se actualiza cuando la percepción ya viene escrita. No demuestra que Haiku comprenda la frase.

Límites de sesión, en `ConversationSession`: `MAX_HISTORY = 20` mensajes de usuario y asistente; `EPISODE_MAX_USER_MESSAGES = 3`; `EPISODE_WINDOW = 4.hours`. No son un máximo de consultas. Cada append guarda `last(MAX_HISTORY - 1)` más el mensaje nuevo, así que el historial almacenado no pasa de 20. El mensaje 21 empieza a descartar los anteriores. Con respuesta del asistente en cada turno, eso ocurre en el turno 11 del journey A. El episodio vive en `active_episode` y no se borra por ese recorte. `EPISODE_MAX_USER_MESSAGES` limita cuántos mensajes de usuario del historial leen algunos lectores. No es el almacén del episodio. El último mensaje del asistente que entra al prompt se corta a 200 caracteres.

Observaciones:

- `QueryComposer#observations` las mete en la cadena de retrieval.
- `SessionContextBuilder#render_field_problem` no las recorre. Arma hechos, identificadores, foto, conflictos y objetivo.
- `MAX_PROBLEM_CHARS = 400`. El encabezado mide 79 caracteres y el pie 188. Con los dos saltos de línea ocupan 269. `fit_problem` acorta primero el objetivo y después descarta líneas. Encabezado y pie se conservan.
- El guidance de identidad conocida (`CompanionGuidanceContext#turn_block`) lee objetivo, identidad y las dos últimas líneas `User:` (`TURN_CHARS = 160`, `MAX_TURNS = 2`). No lee el resto del bloque de problema.
- El guidance de identidad desconocida lee `problem_projection_lines`. Con cero chunks, después del segundo retrieve que ya hace `retry_open`, `BedrockRagService#open_reference_no_results` responde el texto fijo «No se encontró información…» (o el aviso de pin vacío) y no arma guidance ni llama a generación. El técnico recibe una negativa documental sin aclaración ni orientación, lo que contradice la regla de AGENTS.md de no detenerse en una negativa de búsqueda. Reparar solo el builder no alcanza si el guidance no usa esas líneas, ni si la ruta de cero chunks no tiene prompt.

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
- `RESOLVE_IDENTITY` solo se activa con una petición explícita del técnico (`explicit_identification_request` o `explicit_identity_confirmation_request`). No hay otra base para que la identidad sea el objetivo del turno, aunque la documentación la necesite.
- Esas frases pueden sesgar el turno hacia una pregunta que la consulta no necesita, o impedir la que sí necesita. La reparación no consiste en preguntar siempre la identidad. Depende de la consulta, del contexto y de si la documentación ya se distingue.

Correcciones, en dos capas distintas:

- Identidad o código: el prompt del intérprete dice «A correction has empty observations» y exige un span negado y uno afirmado para fabricante, modelo o controlador. `TurnPerception#adjust_move` convierte `correct` sin negación de slot en `unclear`, vacía identidades y vacía observaciones. El reducer adopta un código de reemplazo solo cuando el movimiento ya es `correct` y el slot negado es `fault_code`.
- Observación («planta 1», «por arriba», «ya revisé eso»): no es un slot. Si el modelo emite `correct` sin negación de slot, `adjust_move` borra la observación antes de que el reducer escriba. El prompt empuja al modelo a dejar esas observaciones vacías. La capa responsable de esa pérdida es el intérprete y `adjust_move`, no el reducer. `QueryComposer#current_turn` solo recorta spans negados; el turno literal puede conservar «no de planta 1». Una línea `User:` anterior puede conservar un valor ya descartado. Eso es un hallazgo aparte: falla si la respuesta publicada lo trata como vigente.

Continuidad, ya en código y no reabierta por este plan:

- `new_work` evalúa la política sobre un `ActiveEpisode` vacío y abre otro con `ActiveEpisode.open`. El episodio nuevo no hereda identidad, síntomas, foto ni resultados del anterior.
- `case_boundary_changes` limpia `current_procedure` y deja `pin_release_reason` en nil. El pin de sesión permanece. Persistirlo no prueba que aplique al caso nuevo.
- El escritor tardío se rechaza con `expected_episode_id`.
- No hay almacén de episodios anteriores ni una operación de la ruta owner que reabra un caso cerrado. `voice_dictation` reabre otra cosa y no cuenta como recuperación de episodio. Recuperar un caso anterior no está implementado.

Esos cuatro puntos se conservan. Esta validación no los amplía y no los prueba con una llamada de pago. Las pruebas locales de separación siguen obligatorias en la etapa 1. Su comprobación de conversación real está en el backlog.

Retrieval vacío no demuestra que el manual no exista. Una respuesta útil sin documentación compatible no es éxito documental. A‴ no recorre esta ruta: en Section N quedó useful 28/68, S3 4/44 y unsafe humano confirmado 0. Esos números se conservan. No son la puerta de esta validación.

## Recomendaciones que no se copian

- Conservar solo la observación más reciente. Borraría «ya revisé eso y está bien». La reparación mínima conserva comprobaciones y correcciones que cambian el paso siguiente, dentro del presupuesto del bloque de problema.
- Una sonda completa sin retrieval ni generación, y repetirla, como requisito general. Un defecto visible en el código se reproduce con un test local. No se paga una llamada para confirmar que existe. Esta validación no añade una fase previa de medición pagada.
- Preguntar la identidad en todos los turnos para corregir el sesgo contrario. La identidad se pide cuando la consulta, la evidencia documental o el diagnóstico lo necesitan.
- Tratar el LD-16 como corpus de prueba o como chatbot de referencia. No está en el catálogo local y la página de Wittur no demuestra un RAG.
- Declarar implementada la recuperación de un caso anterior.
- Cerrar O-P1 porque no hay archivos en git, o cerrarlo porque el fundador informó que terminó. Las dos afirmaciones conviven hasta que haya un artefacto.
- Reanudar O-P2 a O-P5, agregar scorer, benchmark grande, ramas por fixture o una llamada de producto extra.
- Una tabla, varios episodios activos, un archivo de casos o una llamada LLM nueva para dejar preparado el backlog.
- Meter L3, el journey B, T-F, el cambio ambiguo o la pausa dentro del gate o del presupuesto de este plan.
- Alargar el journey A para cumplir un número de mensajes.
- Declarar habilitado un piloto de consultas libres al cerrar un solo episodio.
- Reutilizar el techo anterior de 360 llamadas y US$5, calculado para tres escenarios.

## Inventario

Los pendientes históricos siguen en esta tabla. No son los seis escenarios del backlog y no se cierran porque esta validación no los ejecute.

| Gap | Decisión |
|---|---|
| Discovery F0–F8, visual F1–F3, R1A, harness scripted scope.1 | Resuelto con evidencia en sus planes. |
| Observaciones fuera del prompt de generación y presupuesto de 400 que prioriza encabezado y pie | Necesario. Etapa 1. |
| Cero chunks con identidad desconocida: texto fijo, sin guidance ni aclaración | Necesario. Etapa 1, con tests locales. El journey A no recorre esa ruta si la identidad Elemont queda conocida. |
| `ask_controller?` con `ask_when: :always` y fallback que pregunta antes de buscar | Necesario. Etapa 1. |
| `TASK_LEAD` y el objetivo de identidad como sesgo de pregunta; identidad como objetivo solo por petición explícita | Necesario, acotado. Etapa 1 cambia la instrucción; no invierte el sesgo. |
| Corrección de observación destruida por el prompt y `adjust_move` | Necesario. Etapa 1. La calidad del intérprete real, para la planta del journey A, se ve en la etapa 2. |
| Corrección de identidad o código (8→18, Fuji Yida→KONE) | Parcial. El reducer ya adopta el código cuando el movimiento es `correct`. La etapa 2 comprueba 8→18 con el intérprete real. Fuji Yida→KONE es T-F y queda en el backlog. Las pruebas locales de las dos se conservan. |
| Hechos del episodio que sobreviven al recorte de 20 mensajes | Parcial. El JSON del episodio sobrevive; el prompt no. La etapa 1 proyecta lo necesario. La etapa 2 cruza el recorte en el journey A, sin L3. |
| Episodio nuevo sin heredar el caso anterior; pin de sesión que no prueba aplicabilidad | Parcial, ya en código. Las pruebas locales de separación se conservan. La comprobación pagada con L3 sale de este gate y queda en el backlog. No se cierra. |
| Recuperar un caso anterior dentro de la sesión | No implementado. Backlog, para evaluar necesidad y solución mínima. No se declara implementado. |
| R2 del 30 de septiembre (consulta KONE sobre un episodio Elemont vivo, pin MonoSpace, código 515) | Absorbido como mapa. Sigue pospuesto. No es un ítem del backlog de escenarios y no se cierra. |
| Hilo de consulta en la ruta web owner | Sustituido por `QueryComposer`. |
| F9, soltar el pin | Retirado de esta cola. Contradice FC-D17. |
| T3, R3, CG-D19, CS-P01 a CS-P03 | Retirados de esta validación. CG-D19 solo vuelve si la etapa 2 o la 3 muestra una respuesta inutilizable por el formato. |
| Smoke de producción R1B, verificación de producción N1–N6, G5 de foco, presentación | Pospuestos. No se cierran por quedar fuera. El smoke de la etapa 3 es el del episodio de puertas, no esos pendientes. |
| O-P1 | Incierto. Ver abajo. |
| Si Haiku extrae movimiento, observaciones y la corrección de código del journey A; si el índice devuelve el Elemont MH; si cero chunks es índice frío o manual ausente | Incierto hasta la etapa 2, y solo para ese journey. Journey B, T-F y el cambio de caso no quedan resueltos ahí. No se confirma con una sonda previa. |

## O-P1

El fundador informó que O-P1 terminó. En el repositorio, incluido el árbol de trabajo, no están `architecture_faithful_s3.yml`, `architecture_faithful_s3.rb` ni `architecture_faithful_score.rb`. La ausencia en un commit no descarta una ejecución local fuera de este árbol. El informe tampoco deja un artefacto visible aquí. O-P1 queda incierto. No se reanuda y no se da por cerrado. O-P2 a O-P5 no se reanudan.

De Section O se conserva, como regresión secundaria y sin volver a ejecutarla: A‴ no recorre el ciclo de vida; el pin no prueba aplicabilidad; `clarify_first` no busca ni guarda observaciones; no se inventan cuerpos de manual; los SHA y conteos históricos permanecen.

## Arquitectura que se conserva

Se mantienen, sin ampliarlos para el backlog:

- `episode_id` del episodio vigente.
- El estado del episodio en `active_episode`, separado del historial que se recorta.
- `new_work`, que abre otro episodio sin heredar identidad, síntomas, foto ni resultados.
- La aclaración de relación entre casos cuando el cambio no es claro.
- El rechazo del escritor tardío con `expected_episode_id`.

No se agregan tablas, varios episodios activos, un archivo de casos ni una llamada LLM para dejar eso preparado. Abrir un caso nuevo ya está soportado. Recuperar uno anterior no lo está.

## Continuidad dentro del episodio

Después del recorte tienen que seguir disponibles para la respuesta: equipo vigente, problema, observaciones que cambian el paso, comprobaciones y resultados, correcciones, desconocimientos confirmados y pregunta pendiente.

En el journey A eso es, como mínimo: Elemont, MH, CEA15, la puerta 1 que no termina de cerrar, el imán que no magnetiza, el código 18 y no el 8, la planta 2 y no la planta 1, la guía de la puerta sin obstrucción, el LED 7 apagado, el clic al pedir cierre y que no había personas dentro. El historial ya no tiene por qué conservar los primeros mensajes. El episodio y el prompt de la conclusión sí.

## Tres etapas

Ninguna etapa empieza con este documento. Hace falta la luz verde final del fundador sobre este texto. Esa luz verde autoriza ejecutar las etapas 1, 2 y 3 en orden, sin una frase nueva por etapa, dentro del alcance y del presupuesto escritos aquí. Incluye desplegar los commits de las etapas 1 y 2 con el procedimiento vigente antes de la etapa 3. Una etapa empieza solo si la anterior cumplió su resultado. El backlog no entra en esa autorización.

La ejecución se detiene y vuelve al fundador ante cualquiera de estas condiciones: una condición de parada de la etapa en curso; la aceptación de la etapa 2 no se cumple después de las repeticiones permitidas; se alcanza el presupuesto global; el despliegue falla o pide migración, variable de entorno nueva o cambio de infraestructura; una respuesta inventa un valor, terminal, código o procedimiento de fabricante.

No se promete éxito después de un número fijo de reparaciones. Cada etapa se detiene cuando se cumple su resultado o su condición de parada.

### Presupuesto

El techo anterior de 360 llamadas y US$5 cubría journey A con L3, journey B y T-F. No se reutiliza.

Este presupuesto es el journey A local y una verificación de ese mismo episodio en producción. La etapa 1 no lo consume.

Precio en `BedrockQuery::BEDROCK_PRICING` para `global.anthropic.claude-haiku-4-5-20251001-v1:0`: US$0,001 por 1K tokens de entrada y US$0,005 por 1K de salida. Supuesto por llamada, heredado del texto anterior y no reestimado con una sonda: intérprete, 3K de entrada y 0,3K de salida, US$0,0045; generación, publicación o guidance, 8K de entrada y 0,7K de salida, US$0,0115.

Llamadas de modelo por turno, en el peor caso de este escenario:

- Una del intérprete (`BedrockClient#converse`).
- Una de generación si la identidad queda conocida: un `Retrieve` y después `document_identity_generator.query`.
- Hasta dos de publicación o guidance si el turno cae en identidad desconocida. `UnknownIdentityPublication` cuenta, y si no acepta también cuenta el guidance del mismo intento.
- El segundo intento del bucle `retry_open` no entra: exige un pin, y este journey no lo setea.
- `AuroraColdStartRetry` puede repetir el `Retrieve` hasta tres veces, con esperas de 15, 30 y 45 segundos, si el error es el auto-pause de Aurora. Esas repeticiones no crean fila `BedrockQuery` y no suman al techo de llamadas.

El journey A tiene 14 turnos. Una pasada, en ese peor caso: 14 intérpretes y 28 llamadas de generación, publicación o guidance. Total: 42 llamadas de modelo. Costo estimado de la pasada: 14 × 0,0045 + 28 × 0,0115 = US$0,385.

La etapa 2 admite como máximo dos repeticiones. Cada una repite solo los turnos de la falla observada. El techo reserva dos pasadas completas por si la falla es el episodio entero: 126 llamadas. La etapa 3 es una pasada, sin reparación en caliente: 42 llamadas.

Techo global de las etapas 2 y 3, reintentos de publicación y guidance incluidos: 168 llamadas de modelo. Costo estimado de ese techo: US$1,54. Tope de costo: US$2,50.

Supuestos del margen. No se conocen los tokens reales con el prompt reparado. Si `MAX_PROBLEM_CHARS` sube a 600, son unos 50 tokens más por generación: alrededor de US$0,006 en las 112 generaciones del techo. El costo de `Retrieve` y del embedding de la consulta no está en `bedrock_queries`. El tope cubre ese desconocido y no es una factura. Referencia histórica: US$0,0073 por consulta respondida, medido el 6 de agosto con otros prompts. Cuatro pasadas de 14 consultas a esa tarifa serían unos US$0,41. No sustituye el peor caso de dos generaciones por turno.

El conteo y el costo se leen de las filas `BedrockQuery` del periodo de ejecución. El cierre los reconcilia con `bedrock_daily_costs` cuando esa rollup esté disponible.

### 1. Reparar los gaps confirmados del episodio

Reproducciones locales y tests Minitest. Sin Bedrock. Sin fase previa de medición pagada.

- Proyectar en el prompt final, de las dos rutas de guidance, el problema, las observaciones, las correcciones y las comprobaciones que cambian el paso. Un test lee `turn_block` y el bloque de identidad desconocida, no solo `SessionContextBuilder`.
- Contexto compacto. Primero compactar encabezado, pie y redacción de líneas. Si con eso no caben, en el estado del journey A al turno 14, el equipo, el problema, la corrección vigente y las comprobaciones que cambian el paso, se permite subir `MAX_PROBLEM_CHARS` hasta 600, con un test que mida el bloque. Doscientos caracteres más son unos 50 tokens por llamada. No se sacrifica una comprobación o una corrección para cumplir el número. No quedarse solo con la observación más reciente.
- Continuidad útil con retrieval vacío. Cero chunks con identidad desconocida: en lugar del texto fijo, usar el mismo guidance de identidad desconocida que ya existe para la ruta con chunks, con cero manuales y las líneas del problema. La respuesta dice que la búsqueda no devolvió documentación (no que el manual no exista) y ofrece una aclaración que permita una búsqueda mejor o una orientación general de Danebo identificada como tal, sin procedimiento, valores ni terminales de fabricante. Con pin, conserva el aviso de que el foco no devolvió evidencia y no suelta el pin (FC-D17). Es una generación en una ruta que hoy no genera. La ruta de cero chunks reutiliza el resultado de los intentos de retrieval existentes, sin agregar búsquedas adicionales. Si la generación falla, se conserva el mensaje actual de reintento. Un test cubre la ruta con y sin pin.
- Preguntas rutinarias. No agregar la pregunta de controlador cuando el turno ya trae síntoma y un token de equipo (fabricante, modelo, controlador o identificador) y la búsqueda puede seguir. Conservar la aclaración cuando distingue documentos o permite avanzar. El fallback de un episodio vacío no pregunta el controlador antes de poder buscar el síntoma.
- Sesgos del guidance. Quitar el menú fijo de ocupación, posición, puertas, display y sonido cuando la consulta ya trae síntoma o una pregunta que se puede buscar. La comprobación que se pida debe distinguir causas, interpretar un resultado o decidir el siguiente paso de esta consulta. No sustituir el menú por «pregunta siempre la identidad». Identidad como objetivo del turno: además de la petición explícita, cuando una señal determinista ya presente en el turno muestra que la identidad decide la documentación o la aplicabilidad. Ejemplos: manuales recuperados o retenidos de equipos distintos, un manual cuya aplicabilidad depende del modelo, o un código cuyo significado depende del equipo. `ADVANCE_FAULT` deja de afirmar que la identidad no es el objetivo; dice que no se pregunta por rutina. Sin llamada nueva.
- Correcciones de observaciones. Distinguir en el prompt y en `adjust_move` la corrección de identidad o código de la corrección de una observación. La segunda no se convierte en `unclear` ni se vacía.

Siguen siendo parte de esta etapa, y tienen que pasar, las pruebas locales ya existentes de corrección de identidad, de corrección de código y de separación de episodio (`new_work`, `expected_episode_id`). Acotar la aceptación no autoriza borrarlas, saltarlas ni debilitarlas. No se vuelven a pagar contra Bedrock.

Resultado: los tests de las reparaciones y esas pruebas locales pasan. No hay llamada de modelo.

Parada: si la reparación exige una llamada adicional en un turno que ya genera, una tabla nueva o subir `MAX_PROBLEM_CHARS` por encima de 600, se detiene y vuelve al plan. La generación de la ruta de cero chunks, que hoy no genera, es la excepción ya escrita arriba.

#### Cierre local (2026-10-07)

Base `78df58a`, rama `main`, árbol limpio al empezar. Sin llamadas a Bedrock, sin journeys reales y sin despliegue. Veredicto de esta etapa: `ETAPA_1_COMPLETADA`. No declara `EPISODIO_VALIDADO`.

El bloque del estado del journey A en el turno 14 mide 585 caracteres, por encima de 400 y dentro de 600. Con el pie anterior el mismo estado quedaba en 603 y `fit_problem` recortaba el final del problema. El pie quedó en «Ignore for other equipment.» y el objetivo completo cabe, junto con Elemont, MH, CEA15, el código 18, la corrección del código 8 y las comprobaciones que cambian el paso. El código 8 y la planta 1 no salen como hechos vigentes. La puerta y el imán siguen en la línea de objetivo; no se duplican en observaciones.

Las seis reparaciones quedaron en las rutas que ya existían:

- `SessionContextBuilder` proyecta observaciones y correcciones. Las dos rutas de guidance leen ese bloque en el prompt final.
- `MAX_PROBLEM_CHARS` pasó a 600. El encabezado, el pie y la línea de identificadores se acortaron antes.
- Cero chunks e identidad desconocida generan una vez con el guidance existente, sin otro `Retrieve`. La respuesta antepone el aviso de búsqueda vacía. Con pin forzado, un solo retrieve conserva el aviso de foco vacío. Si la generación sale vacía o es el rechazo de Bedrock, queda el texto de reintento.
- `RoutePolicy` ya no pregunta el controlador por rutina cuando hay síntoma y un token de equipo. El designador ambiguo y la mención dentro del foco siguen aclarando. El fallback de un episodio vacío busca el síntoma; un saludo sigue aclarando.
- El menú fijo salió de `TASK_LEAD`. `ADVANCE_FAULT` dice que la identidad no se pregunta por rutina. Pasa a objetivo con una duda explícita de aplicabilidad o con un código cuyo significado se pregunta. Dos títulos no se leen como equipos distintos. Un procedimiento, un reset o un valor siguen en `advance_fault`.
- Una corrección de observación permanece `correct` y conserva la frase de reemplazo. Una corrección de fabricante, modelo, controlador o código sin la negación ranurada sigue yéndose a `unclear`.

Evidencia local, con dependencias externas stubbeadas: `session_context_builder_test`, `companion_guidance_context_test`, `route_policy_test`, `turn_perception_test` y `work_context_reducer_test`, 106 pruebas, 943 aserciones. `bedrock_rag_service_test` y `document_identity_scope_test`, 177 pruebas, 1399 aserciones, 6 skips previos. `conversation_session_turn_interpreter_test` junto con `turn_perception_test`, incluidas las de `new_work`, `expected_episode_id`, NICE3000 a NICE1000 y el código 8 a 18. Cero fallos en esas corridas.

Corrección de revisión, sobre `e62a4ab`. `stale_observation?` ya no descarta una observación por compartir el número rechazado. «El display muestra código 8» deja de salir como vigente cuando el código pasa a 18. «El LED 8 está apagado», «la puerta 8 no cierra» y «detenida en planta 8» se conservan. Un identificador numérico tampoco arrastra esas frases. `distinct_retrieved_manuals?` salió: dos manuales del mismo equipo, o dos títulos sin datos de equipo, no piden la placa. Siguen la duda explícita de aplicabilidad y el código cuyo significado depende del equipo. Evidencia de esta corrección: `session_context_builder_test`, `companion_guidance_context_test`, `turn_perception_test`, `work_context_reducer_test` y `conversation_session_turn_interpreter_test`, 136 pruebas, 1199 aserciones, cero fallos y cero skips. Incluyen el journey A, la corrección de código, `new_work` y `expected_episode_id`. Sin Bedrock y sin despliegue. El veredicto de la etapa sigue siendo local: no es `EPISODIO_VALIDADO`.

Pendiente para la etapa 2: el journey A con el intérprete real, ejecutado como se describe abajo. Esta etapa no demuestra que el retrieve devuelva el manual del Elemont ni que la conclusión use un chunk compatible. `TechnicalUnderstanding` no es la ruta owner y no se tocó. La planta 1 no es un slot rechazado: el reducer la saca de las observaciones cuando el turno dice «no de», y el prompt muestra la observación de reemplazo. La preparación y la ejecución real de la etapa 2 siguen pendientes en este cierre de la etapa 1. El resultado está en el cierre de la etapa 2.

Condición para iniciar la etapa 2: revisión de este diff. El presupuesto y las paradas de la etapa 2 no cambian. No se empieza la etapa 2 ni la 3 desde este cierre.

### 2. Validar un episodio real

La etapa 2 ejecuta el código de Rails local contra la Knowledge Base real de producción mediante Bedrock. Requiere configurar credenciales AWS autorizadas, región y Knowledge Base, y disponer en la base Rails local de registros documentales y de cuenta coherentes con el corpus remoto para aplicar las políticas existentes. Sesiones, mensajes y trazas se guardan localmente. No requiere desplegar ni escribir en la base Rails de producción.

AWS CLI Retrieve puede comprobar acceso y retrieval, pero no sustituye Journey A. Una búsqueda vacía no demuestra que el manual no exista. Se distinguen la falta de acceso o de configuración, los registros locales ausentes o incompatibles, y una búsqueda sin resultados. No se copian secretos al repositorio ni se muestran en la entrega. El cierre de esta etapa está más abajo.

Journey A de puertas, turnos 1 a 14, sin L3. Intérprete, sesión, retrieval y generación, con el código Rails local y la Knowledge Base de producción. No se crea otro corpus.

El manual del Elemont MH tiene que devolverse en el retrieve antes de empezar. Si la búsqueda, con acceso y registros locales coherentes, no lo devuelve, parada en `RETRIEVAL_EMPTY`. No se sustituye por el LD-16 y no se aprueba el episodio con orientación general.

Los textos del técnico son los del fixture. Los hechos de cada turno son fijos: código 8 y después 18, planta 1 y después 2, la guía sin obstrucción, el LED 7 apagado y el clic al pedir cierre. La redacción se adapta a la respuesta real anterior cuando el texto presupone algo que Danebo no dijo. A3 responde a una pregunta sobre ocupación o posición. A11 dice «esa revisión». Si Danebo no lo preguntó o no lo mostró, el turno entrega el mismo hecho como dato espontáneo, o se refiere a la comprobación que Danebo sí mostró. Si Danebo pregunta algo que el caso responde, el técnico responde con el hecho del fixture. Si el caso no lo sabe, responde «no lo sé». La traza guarda el texto original y el enviado. Un turno adaptado no es un turno nuevo ni otro escenario.

Catorce intercambios con respuesta del asistente son 28 mensajes. El recorte empieza en el turno 11. La corrección de planta (turno 13) y la conclusión (turno 14) quedan después. No se agregan turnos para llegar a 20. El turno 12, «Sigue igual», ya está entre el recorte y la corrección de planta y se mantiene. Si en una corrida Danebo ya cerró y los turnos que faltan no traen un hecho nuevo, no se redactan turnos adicionales. En este fixture la corrección de código, la comprobación de la guía y la corrección de planta son hechos nuevos y se entregan antes de cerrar. Si una corrida se cerrara antes del turno 11 sin esos hechos, no habría demostrado el recorte: se anota y no se alarga.

Límite del fixture, y ajuste mínimo ya hecho en este texto: `longitudinal_journeys.yml` no define el significado del código 18, del LED 7, de las plantas, de la guía ni del clic, y no trae un diagnóstico esperado del fabricante. No se inventa ese diagnóstico ni se abre otro corpus. El punto de conclusión es el turno 14, «¿Y ahora?», con los hechos vigentes después del recorte. La utilidad se juzga por las tres salidas, no por coincidir con una causa guionada.

Cada turno anota la decisión, si buscó, si el chunk es compatible con el equipo, si la respuesta usa ese chunk o se declara orientación de Danebo, y si conserva o descarta lo ya comprobado. `RETRIEVAL_EMPTY` no se anota como «el manual no existe». Una respuesta general sin documento compatible no se anota como éxito documental.

Se repara solo la falla observada y se repite solo lo necesario. Como máximo dos repeticiones, siempre dentro del presupuesto de la etapa. Una repetición no es un pretexto para completar un cupo ni para agregar turnos.

Parada: error de transporte en el primer turno; el retrieve, con acceso y registros locales coherentes, no devuelve el manual del Elemont; la misma falla vuelve después de una reparación; la reparación pide una tabla, un segundo modelo, L3 u otro escenario; se agota el presupuesto de la etapa.

Aceptación:

- En el primer turno se busca sin pedir fabricante, modelo ni controlador.
- Utilidad y avance, en el turno 14: una respuesta sustentada, una siguiente acción verificable o un escalamiento fundamentado. La respuesta usa lo ya comprobado. No repite una comprobación descartada ni trata como vigente el código 8 o la planta 1. No se exige que la puerta quede reparada.
- Memoria: después del recorte siguen el equipo, el problema, las correcciones y las comprobaciones relevantes nombradas arriba.
- Documentación: si el retrieve devuelve un chunk compatible, la conclusión lo usa y cita documento y página. Si no lo devuelve, la respuesta no inventa valores, terminales, códigos ni un procedimiento de fabricante. Eso no es éxito documental. Con el manual recuperable en la Knowledge Base de producción, un episodio que nunca usa documentación compatible no llega a `EPISODIO_VALIDADO`.
- Una pregunta repetida, un valor ya corregido tratado como vigente o una pregunta de identidad sin función documental ni diagnóstica es fallo. Timeout, throttle o error de transporte es inconcluso, no un fallback de producto.

#### Cierre (2026-10-07)

Base `322ea00`, rama `main`. Rails local, base `smart_deal_development` en localhost, Knowledge Base `Y7RZWMFJSR`, región `us-east-1`. El `.env` apunta al índice de desarrollo; el proceso exportó el id de producción y dejó la sesión compartida apagada. Las credentials cifradas no tienen access key y su id de índice no es el de producción. Las access keys del `.env` sí llamaron a `Y7RZWMFJSR`. No se escribió la base Rails de producción y no se desplegó.

La cuenta local `danebo-legacy` es el id 4. Los chunks del índice están en `account_id` 1. Con el filtro de la cuenta 4 el retrieve devolvió cero. Se creó en local la cuenta id 1 (`index-account-1`), un usuario local y la fila `KbDocument` del Elemont (`dcc8e046-037d-48a6-8913-1992aed28507`, clave del PDF `Montacargas 2N`). La base local no tenía la columna `document_focus` que el código ya espera; se aplicó solo ahí la migración `20261001160000`. Con la cuenta 1, una búsqueda sin generación devolvió el manual Elemont MH, páginas 1 y 7, junto con un manual Crown. El manual es recuperable. Una búsqueda del síntoma no lo devuelve: el ranking trae `manual-cea15p`, VF5 y Monarch.

Tres pasadas del journey A, turnos 1 a 14, sin pin y sin L3. Intérprete, retrieve y generación reales. Sesiones locales 193, 194 y 195. Trazas en `tmp/stage2_journey_a/`, fuera del repositorio.

| Pasada | Llamadas | Costo `BedrockQuery` | Qué mostró |
|---|---:|---:|---|
| 1 | 25 | US$0,052129 | Buscó en el turno 1. El código 18 y la planta 2 se preguntaron como dato a corregir y no se guardaron. El turno 12 trató el código 8 y la planta 1 como vigentes. Los síntomas ocuparon los cinco identificadores y Elemont salió del prompt. |
| 2 | 27 | US$0,054390 | El estado guardó el código 18, rechazó el 8, reemplazó la planta y conservó Elemont, MH y CEA15 después del recorte. La conclusión dijo que el código había pasado de 18 a 8. La línea `Corrected: fault code 8` se leía como el valor nuevo. |
| 3 | 28 | US$0,055043 | La conclusión ya no invierte el código ni declara la planta 1. Sigue pidiendo de dónde sale el clic. El bloque del turno 14, al pasar de 600 caracteres, soltó el objetivo, el código 18 y los identificadores, y conservó las observaciones. |

Total de llamadas de modelo: 80, de las 126 de esta etapa. Costo atribuido en `BedrockQuery`: US$0,161562. 42 filas son el intérprete (`semantic_analysis`) y 38 son generación (`query`). `Retrieve` y el embedding de la consulta no están en esa tabla. El tope de US$2,50 no se acercó. No hay rollup de `bedrock_daily_costs` de esta corrida. La etapa 3 no se ejecutó.

Aceptación de la pasada 3:

- Primer turno: buscó, sin pedir fabricante, modelo ni controlador. Dijo que la identidad no está confirmada y pidió mirar el imán.
- Memoria: el episodio conserva Elemont, MH, CEA15, el código 18, la planta 2, la guía sin obstrucción, el LED 7, el clic y que no había personas. El prompt de la conclusión no: `fit_problem` suelta primero identificadores y hechos, y la lista de observaciones ya no cabía con ellos.
- Código 8: queda rechazado. La respuesta del turno 14 no lo trata como vigente. El turno 7 vuelve a pedir la placa aunque el turno 1 ya dijo Elemont MH y CEA15.
- Planta 1: sale de las observaciones en el turno 13. El turno 10, anterior a esa corrección, todavía la nombra.
- Conclusión: no cita el manual del Elemont. Pide otra vez de dónde viene el clic, comprobación ya entregada. No declara la puerta reparada y no inventa un terminal ni un valor de fabricante. Tampoco es una respuesta sustentada en documentación compatible.
- Documentación: ninguna de las 14 búsquedas del episodio devolvió el Elemont MH. Devolvieron CEA15P, VF5 y Monarch. Eso no se anotó como éxito documental ni como ausencia del manual.

Reparaciones, con test local antes de repetir. No se hizo una tercera. La misma comprobación del clic volvió después de la segunda.

- Una corrección que ya nombra el código viejo y el nuevo, o una observación con «corrijo» y «no de», deja de convertirse en `correction_target`.
- Una frase de síntoma no ocupa un cupo de identificador. Un código rechazado sale también de esa lista.
- La línea del valor rechazado dice `Not current:`, no `Corrected:`.

Veredicto de la etapa: `BLOQUEADA`. No es `EPISODIO_VALIDADO`. La etapa 3 no empieza.

#### Reparaciones locales posteriores (2026-10-07)

Sobre `9dbc655`. Sin Bedrock, sin Retrieve, sin otra pasada y sin despliegue. La etapa 2 sigue `BLOQUEADA`. Estas reparaciones no reinician el presupuesto ni autorizan otra corrida. Veredicto de este diff: `REPARACIONES_LOCALES_COMPLETADAS`. No es `EPISODIO_VALIDADO`.

La medición de 601 caracteres del turno 12 y del 14 era el bloque de 599 más los dos saltos de línea que lo separan de `## Recent Conversation`. Esos dos caracteres no entran en `MAX_PROBLEM_CHARS`. El límite sigue en 600.

Con el estado guardado de la sesión 195, turnos 12 y 14, el bloque reserva el objetivo, Elemont MH, CEA15, el código 18 y `Not current: fault code 8`. Una observación cubierta por el objetivo sale del bloque solo si ese objetivo se imprime. Los ecos exactos y «Sigue igual» no ocupan cupo. El mismo bloque entra en `text_prompt_template` de `build_complete_optimized_config`, que es el prompt de la ruta `rag_global`. No se subió el límite y no se escribieron Elemont, CEA15 ni los hechos del fixture en las reglas de producto.

Una corrección de código ya no vacía el resto del turno. La instrucción del intérprete deja de pedir observaciones vacías y `recover_stated_correction` combina. «Era código 18, no 8. La guía no tiene obstrucción» guarda 18, rechaza 8 y conserva la guía. El rechazo es por slot: LED 8, puerta 8 y planta 8 siguen. El mensaje del técnico no se reescribe. La consulta no deja «no .» ni vuelve a poner el código 8 como vigente. La redundancia entre el turno, el objetivo y las observaciones se quita sin soltar la identidad ni el código cuando la lista llena el tope.

`append_observation!` no guarda una copia normalizada ni un eco de continuidad. No une dos frases por compartir tokens: «no cierra» y «cierra», o el clic con «pero», siguen siendo comprobaciones distintas. Un «Sigue igual» no borra el objetivo ni las comprobaciones. Al llegar al tope de 12, la observación contenida en el objetivo no es la que sale.

El armado de mensajes del journey A ya no antepone un hecho de otro turno. Si la pregunta pide el origen del clic, el significado de un código o de un LED, o un terminal, y el fixture no lo trae, la respuesta añadida es «No lo sé.». No se inventa ese origen. Una comprobación ya dicha no se vuelve a pegar como si faltara.

`pending_question` sigue vacío. No se proyecta como pregunta pendiente algo inferido del texto de la respuesta: no hay un mecanismo que guarde la pregunta que Danebo acaba de hacer. Propuesta aparte, no implementada: al cerrar el turno, si la respuesta termina en una comprobación, guardarla como pregunta abierta y no repetirla cuando el técnico ya dijo que no la sabe. Eso queda fuera de este diff.

La próxima corrida, solo si se autoriza, usa `script/field_companion/stage2_journey_a.rb` con `STAGE2_JOURNEY_AUTHORIZED=1`. El runner local `tmp/stage2_journey_a.rb` carga ese archivo. Esta sección no la autoriza. El presupuesto de esa corrida está en el ajuste siguiente: no se reabre contando solo filas posteriores al baseline.

Sigue sin demostrarse, y este diff no lo cambia: el ranking que no devolvió el Elemont en las consultas del episodio, el cuerpo del filtro de la cuenta 1 de esas pasadas, si algún chunk del Elemont habla de la puerta o del imán, y si `manual-cea15p` aplica a la placa CEA15. No se tocó el pin ni el filtro de aplicabilidad.

Condición para otra validación: revisión de este diff y una autorización explícita. El techo sigue en 126 llamadas de esta etapa, 168 globales y US$2,50. Lo ya gastado, 80 llamadas y US$0,161562, no se borra. La etapa 3 no empieza.

#### Ajuste sobre 0ec8ba6 (2026-10-07)

Sin Bedrock, sin Retrieve, sin otra pasada y sin despliegue. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. Este ajuste no autoriza la pasada que deja preparada.

El runner suma siempre las 80 llamadas y US$0,161562 ya gastados. Un baseline nuevo, o una base sin esas filas, no devuelve el techo a 126. La pasada futura, si se autoriza, puede añadir como máximo 42 llamadas nuevas, reintentos de publicación y guidance incluidos. Antes de cada turno tiene que quedar margen para 3 llamadas de modelo: el intérprete y hasta dos de publicación o guidance. El segundo intento `retry_open` no entra, porque este journey no usa pin. Con eso, la etapa 2 sigue dentro de 126 y la etapa 3 conserva sus 42 dentro del techo global de 168. El costo histórico también entra en el tope de US$2,50; el margen de costo de un turno es el supuesto ya escrito, US$0,0045 más dos veces US$0,0115.

Cada ejecución escribe en `tmp/stage2_journey_a/runs/<corrida>-session-<id>/`. No reescribe `trace.json` ni las pasadas anteriores. El manifiesto guarda el SHA y el consumo histórico. No reconstruye los requests que no se guardaron.

La captura, solo dentro del bloque, registra también el prompt que sale por generación directa: `BedrockClient#generate_text` (guidance y generación con identidad conocida) y `converse_message` (contrato de publicación). `max_tokens` se conserva. Las credenciales se quitan por nombre exacto (`access_key_id`, `session_token`, `secret_access_key`); una clave no se borra por contener la palabra token. No hay llamada extra.

`merge_phrase` ya no descarta una frase porque otra esté contenida en ella. «La guía no tiene obstrucción, pero el rodillo está trabado» conserva la guía y el rodillo trabado, y no guarda al lado la frase corta. Dos comprobaciones que no se contienen siguen las dos.

#### Pasada autorizada sobre da8d32b (2026-10-07)

SHA `da8d32b38b8f9333fcdbb81936c07f2a21f6fad4`. Una sola pasada de los turnos 1 a 14. Sesión local 196. Trazas en `tmp/stage2_journey_a/runs/20261007T193541Z-session-196/`. Las trazas anteriores, en `tmp/stage2_journey_a/`, no se reescribieron. Sin pin, sin L3, sin despliegue y sin escritura en la base Rails de producción. No hubo segunda pasada ni reparación en caliente. Esta autorización no abre la etapa 3.

Rails local, `smart_deal_development` en localhost, Knowledge Base `Y7RZWMFJSR`, región `us-east-1`. El proceso exportó el índice de producción y apagó la sesión compartida. Cuenta 1 y documento Elemont `dcc8e046-037d-48a6-8913-1992aed28507`. La disponibilidad prevista en el runner devolvió el Elemont MH, páginas 1 y 7, junto con un manual Crown. El filtro capturado es el mismo en esa disponibilidad y en los turnos del episodio: cuenta 1, o la cuenta 4 sin foto y sin `manual_corpus=account`, o `manual_corpus=general`. Híbrido. Disponibilidad con k=5; el episodio con k=8. Ningún retrieve del episodio devolvió el Elemont. Devolvieron `manual-cea15p`, `manual-cea51fb-das`, VF5, Monarch e IME01. El parecido del nombre no hace compatible a `manual-cea15p` con la placa CEA15. La diferencia observada es la consulta, no otro filtro. No se hicieron búsquedas adicionales.

Presupuesto de esta pasada, leído de `BedrockQuery`: 26 llamadas nuevas y US$0,053276. 14 son el intérprete (`semantic_analysis`) y 12 son generación (`query`, ruta `rag_global`). Los turnos 10 y 13 no generaron. Con las 80 llamadas y US$0,161562 ya gastados: 106 llamadas y US$0,214838. Cabe en 42 nuevas, en 126 de la etapa y en 168 globales. `Retrieve` y el embedding de la consulta no están en esa cifra. No hay rollup de `bedrock_daily_costs`.

El bloque del turno 14 mide 563 caracteres y no se recortó. El prompt enviado a generación lleva el objetivo, Elemont MH, CEA15, el código 18, `Not current: fault code 8`, el LED 7, la guía sin obstrucción y el clic. El turno 1 buscó sin pedir fabricante, modelo ni controlador. El turno 5 guardó el código 18, rechazó el 8, sacó «El display muestra código 8» y conservó la puerta, el imán, la planta, la ocupación y la reapertura. La consulta quedó en «era código 18», sin «no .». «Sigue igual» no reemplazó el estado.

El turno 13 no aplicó la corrección. El técnico dijo planta 2, no planta 1. La salida cruda del intérprete fue `correct`, con la aserción «cerca de planta 2» y observaciones vacías. La respuesta fue «¿Qué dato del equipo quieres corregir?». La planta 1 siguió en el episodio y en el prompt del turno 14. Un `correct` sin negación ranurada se vacía si queda un assert de identificador, y la frase «la cabina está detenida cerca de planta 2» no se guardó.

No se envió «No lo sé». El turno 11 pasó de «Hice esa revisión» a «Sigue el clic y la puerta no termina de cerrar» porque la respuesta anterior no nombraba esa revisión. El turno 7 tenía Elemont MH, CEA15 y el código 18 en el prompt, y la respuesta volvió a pedir la placa. Es orientación con identidad no confirmada, no éxito documental. El turno 10, sin retrieve, respondió «Puedes seguir con lo que ya me contaste.»

Respuesta completa del turno 14: «Escucha el sonido del imán cuando la puerta llega al marco y dime si oyes un chasquido o un zumbido que se sostiene, o si el sonido se detiene apenas la puerta toca el marco.» No cita el Elemont. No declara la puerta reparada. No inventa un terminal ni un valor de fabricante. Esa pregunta distingue chasquido, zumbido sostenido y si el sonido se detiene al tocar el marco. «Se oye un clic» no la responde: es una precisión nueva, no una escucha ya contestada. La pasada queda bloqueada porque la corrección de planta no se aplicó y no hubo éxito documental. Deja la planta 1 como vigente. No es una respuesta sustentada, ni una siguiente acción que use la corrección, ni un escalamiento fundamentado.

Veredicto de esta pasada: `BLOQUEADA`. No es `EPISODIO_VALIDADO`. La etapa 3 no empieza. Este cierre no autoriza otra pasada.

#### Reparación local sobre 66dd9e0 (2026-10-07)

Sin Bedrock, sin Retrieve, sin otra pasada y sin despliegue. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. Esta reparación no autoriza una pasada.

La salida cruda del turno 13 era `correct`, con la aserción «cerca de planta 2» y observaciones vacías. La recuperación armaba «la cabina está detenida cerca de planta 2» y conservaba el fragmento como identificador. `observation_correction?` lo rechazaba y el turno volvía a preguntar qué dato corregir. Un fragmento contenido en la observación recuperada ya no bloquea esa corrección ni se guarda como identidad del equipo. Otro identificador del mismo turno se conserva. Una negación con slot o un par negar/afirmar siguen exigiendo el valor vigente y su reemplazo.

El consumo histórico pasa a 106 llamadas y US$0,214838 registrados en `BedrockQuery`. Quedan 20 llamadas dentro de 126. La etapa 3 conserva 42 dentro del techo global de 168 y el tope sigue en US$2,50. El saldo no abre otra pasada: el tope de la pasada siguiente queda en 0. `Retrieve` y el embedding siguen fuera de esa cifra. No hay rollup de `bedrock_daily_costs`.

Los cuerpos de los chunks no se guardaron. `availability.json` y `trace.json` guardan la consulta, el filtro, k y las citas: nombre, página, cuenta, marca `elemont` y URI truncada. No hay texto de página. Lo capturado del Elemont es la disponibilidad: «Elemont Montacargas Hidraulico Modelo MH», páginas 1 y 7, cuenta 1, `chunk_p1_1.txt` y `chunk_p7_2.txt`, más Crown en las páginas 99 y 383. El texto de esa consulta de disponibilidad es el título del manual. Ninguna cita del episodio tiene `elemont: true`. Esa metadata no dice si el manual habla de la puerta o del imán. Falta el texto de esas páginas para saber si puede responder al caso. No se atribuye el fallo al ranking y `manual-cea15p` no queda como compatible con la placa CEA15.

Pendiente: otra pasada solo con autorización explícita. La corrección de planta está demostrada en local y no está revalidada contra el índice. El éxito documental del Elemont sigue abierto porque el cuerpo de las páginas 1 y 7 no está en la traza.

#### Ajuste sobre 2faa7d0 (2026-10-07)

Sin Bedrock, sin Retrieve, sin otra pasada y sin despliegue. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. Este ajuste no autoriza una pasada.

Una corrección de observación ya no borra los `fact` del turno cuando el intérprete dejó las observaciones vacías. Se elimina solo el identificador que es la frase recuperada o un fragmento de ella. Un controlador que el catálogo reconoce, aunque su nombre aparezca dentro de esa frase, sigue vigente junto con la planta nueva. La planta anterior deja de estarlo. La consulta y el bloque de contexto conservan los dos. Un reemplazo de identidad o de código incompleto sigue pidiendo el dato: hace falta la negación con slot, o el par negar y afirmar.

Con `PASS_CALL_CAP` en 0, `stage2_journey_a_main` consulta `Stage2RunBudget` y vuelve antes de crear la sesión de validación, de `Retrieve` y de la generación, aunque `STAGE2_JOURNEY_AUTHORIZED=1`. El control anterior a cada turno sigue en el recorrido. El histórico permanece en 106 llamadas y US$0,214838. Los techos siguen en 126, 42 reservadas para la etapa 3, 168 y US$2,50.

#### Instrumentación local

`Rag::ValidationCapture` queda como capacidad permanente del flujo. No pertenece a un journey ni a una sesión. La captura detallada sigue apagada: solo existe dentro de un bloque `capture` abierto a propósito. Cualquier validación o diagnóstico futuro reutiliza la misma implementación y puede etiquetar el bloque con los identificadores que ya tiene (`sha`, sesión, episodio, cuenta, usuario, `correlation_root`). El producto no ramifica por el texto de un fixture.

Con la captura abierta, el flujo anota la percepción aplicada y la regla que cambió un dato, el delta del episodio, la ruta y la condición que la eligió, las salidas tempranas y el reintento de Aurora, la consulta efectiva con filtro, modalidad y k, cada chunk recibido con documento, página, id, URI y score —o `unavailable` si la API no lo trae—, la decisión de la compuerta y de la política de identidad, el prompt realmente enviado y si todavía es una plantilla, y la respuesta con sus citas. El texto de chunk y los prompts quedan solo en ese bloque local. `PilotUsageLog` no sube sus límites y no guarda cuerpos. No se reconstruyen solicitudes viejas que no se guardaron.

Limitaciones: un score ausente queda `unavailable`; `RetrieveAndGenerate` no expone el top-k completo ni el score de la cita; un prompt con `$search_results$` o `$output_format_instructions$` se marca como plantilla, no como contexto resuelto. La membresía de las páginas 5 y 6 el 2026-10-07 no se volvió a consultar.

Esa última frase es el estado de la instrumentación. La comprobación documental posterior está en la sección siguiente. No reabre esta pieza.

Veredicto de esta pieza: `INSTRUMENTACION_LOCAL_COMPLETADA`. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. No autoriza otra pasada. El presupuesto no cambia: 106 llamadas, US$0,214838, techos 126, 42, 168 y US$2,50, `PASS_CALL_CAP` en 0.

Cada turno abre un contexto en `ValidationCapture` y, al salir, restaura la correlación y el intento anteriores, también si el bloque falla. Así la solicitud del intérprete, la salida cruda, la percepción y los eventos siguientes de ese turno comparten su correlación. `correlation_root` y el resto de identificadores se mantienen. Un retrieve o `RetrieveAndGenerate` que falla de forma terminal, incluidos los reintentos de Aurora ya agotados, deja operación, correlación, intento de producto, intento de transporte, clase y motivo sanitizado, y vuelve a lanzar la excepción original. La captura detallada sigue apagada por defecto.

Veredicto de estas dos correcciones: `CORRECCIONES_INSTRUMENTACION_COMPLETADAS`. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. No autoriza otra pasada ni una comprobación documental. El presupuesto no cambia.

#### Comprobación documental (2026-10-07)

Autorizada después, sobre `bb672e7`, como una sola Retrieve y sin generación. No es una pasada del journey A. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. El presupuesto de modelos no cambia: 106 llamadas y US$0,214838. `PASS_CALL_CAP` sigue en 0. Estas dos Retrieve no entran en `BedrockQuery`.

La sesión 196 y esta comprobación fueron sin pin. Escribir «Elemont» en la consulta no pinea. El foco web vive en `document_focus`. El corpus compartido explica que el filtro abierto también devuelva manuales de otras marcas. No demuestra la causa del fallo de retrieval de la sesión 196. `viewer_account` es autorización de acceso del chunk, no compatibilidad técnica con el equipo.

Consulta: `Elemont Montacargas Hidraulico Modelo MH Seguridad Puerta nivel 1`. Knowledge Base `Y7RZWMFJSR`, HYBRID, k=8, cuenta local 1, con el filtro capturado en la sesión 196. Hubo dos invocaciones. La primera, `tmp/documentary_retrieve/20261007T212004Z/`, falló porque Aurora se estaba reanudando tras la pausa. La segunda, `tmp/documentary_retrieve/20261007T212124Z/`, devolvió ocho resultados y ninguno fue rechazado.

`chunk_p5_1.txt` del Elemont MH salió primero, página 5, aceptado por `viewer_account`. El texto es el diagrama de circuito 3: la línea de seguridad incluye la etiqueta «Seguridad Puerta nivel 1», y también está la botonera de pasillo del nivel 1. No menciona el código 18, el LED 7 ni el imán. `chunk_p6_1.txt` no entró en los ocho. Esta consulta no lo devolvió. Eso no dice que falte en el índice.

El contrato del filtro, resuelto por slug y no por estos ids locales, está en [SESSION_AND_RETRIEVAL.md](SESSION_AND_RETRIEVAL.md#shared-corpus-current-contract).

#### Comprobación web y reparación local (2026-10-07)

La imagen web de producción seguía en `d5660d72a1e676ef9f054dd49ccc7e65511b9f2c`. Una sola solicitud autenticada en `https://elevator.danebo.ai`, con un usuario aislado de `danebo-legacy`. No usó la sesión 5. La pregunta fue la del turno 1 de la sesión 196, sin pin y sin agregar a mano el nombre del catálogo. Correlación `query:126c8fa5-5ccb-49e6-b92b-37534c8853e2`. HTTP 200. Ruta `identity_unknown_reference`, HYBRID, k=8. La cadena de retrieval fue el texto del técnico. Ocho chunks, ninguno del Elemont MH. Citas publicadas vacías. La respuesta dijo que la identidad no está confirmada y pidió observar si el imán de la puerta 1 está alineado con el sensor de cierre en la jamba. Ese sensor y esa jamba no estaban en la pregunta ni en una cita. La frase la escribió el modelo.

Dos filas de `BedrockQuery`: análisis semántico US$0,00348 y generación `rag_global` US$0,000868. Total US$0,004348. Esas dos llamadas quedan aparte del histórico de la etapa 2, que sigue en 106 llamadas y US$0,214838. `Retrieve` y el embedding de la consulta no están en esa tabla. `PASS_CALL_CAP` sigue en 0. Los techos siguen en 126, 42, 168 y US$2,50.

Límites de esa evidencia. La solicitud corrió en `rails runner` dentro del contenedor web, no en Puma, así que el log del rol web no tiene sus marcadores. La base guardó el turno y las dos filas de costo. El paquete está en `tmp/pilot_exports/trace-once/2026-10-07_2026-10-07_danebo-legacy/`. El reporte marca el rol web como ausente por esa razón. La sesión 5 no cambió. El usuario de la comprobación se borró al terminar. No hubo despliegue. Recuperar el dibujo no resuelve la falla: la página 5 no explica el código 18, el LED 7 ni el imán.

`BedrockIngestionJob#persist_to_technician_documents` omite `account_id`. Queda registrado aparte. Esta reparación no lo toca y no es la causa de la consulta corta.

Reparación local, sobre la misma base, sin llamadas a AWS y sin despliegue. Un span que es la marca y el designador exactos de una sola entrada confirmada y autorizada agrega el `display_name` a los identificadores del episodio, con origen `catalog`. `QueryComposer` ya compone esos identificadores y mantiene el tope de 442 caracteres. El span del técnico sigue con origen `user`. No se escribe un hecho de fabricante ni de modelo, así que la expansión sola no vuelve `EquipmentIdentity#known?` verdadero ni confirma aplicabilidad. No escribe pin ni cambia el filtro. Varios candidatos, una fila no autorizada o una vinculación ambigua no eligen uno. `CEA15` no selecciona `CEA15+`. Una corrección que niega ese span retira también el nombre canónico y no lo deja rechazado de forma global. El identificador de catálogo admite 120 caracteres; el del técnico sigue en 30.

En un caso genérico, la consulta pasa de `Acme ZX no arranca` a esa frase más `Acme Freight Controller ZX Field Manual`. En el caso investigado, la consulta pasa del texto del técnico a ese mismo texto más `Elemont Montacargas Hidraulico Modelo MH`. Esos nombres son datos del catálogo de prueba y del manual ya publicado. No hay una rama de producto para ellos.

El prompt de orientación, con identidad conocida y con identidad desconocida, separa el reporte, la evidencia y la hipótesis. Un componente o un lugar que no quedó establecido es condicional: no se trata como si ya estuviera. No se agregó un cuestionario ni una pregunta de identidad por rutina. El test comprueba que esa instrucción está en el prompt. No demuestra que el modelo la cumpla.

Pendiente: el efecto de la consulta expandida sobre el retrieval y sobre la respuesta real. Esta reparación no lo ejecuta. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. `PASS_CALL_CAP` sigue en 0.

Veredicto de este diff: `REPARACION_LOCAL_COMPLETADA`.

#### Correcciones del review (2026-10-07)

Sobre `77b3de6`. Sin llamadas a AWS, sin Retrieve, sin journeys, sin despliegue y sin cambios en datos de producción. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. `PASS_CALL_CAP` sigue en 0. Los techos y el histórico de 106 llamadas y US$0,214838 no cambian. Las dos llamadas de la comprobación web siguen aparte.

Una expansión de catálogo ya no ocupa una plaza que expulse un identificador del técnico o de una foto. El tope sigue en 5. Entre identificadores originales se conserva el FIFO. Si no queda una plaza libre, la expansión no se escribe. La misma prioridad vale al guardar y al releer. Si el JSON pasa el tope de bytes, también sale primero una expansión de catálogo.

El nombre canónico se guarda, se compara y se retira con el mismo literal, incluido el corte a 120 caracteres. Negar el span después de persistir y releer saca esa expansión de la consulta y del contexto. No se rechaza el nombre canónico de forma global y no se borra un identificador independiente.

La consulta compuesta puede ser igual al texto del técnico cuando ese texto ya trae lo necesario. Un identificador del episodio que el texto no trae sí cambia la consulta. El hash se calcula sobre esos textos. La ruta, la correlación, el Retrieve, la generación directa y la separación entre la consulta de recuperación y el prompt de generación siguen cubiertos. No se cambió el producto para forzar hashes distintos.

La regla de hipótesis del guidance se conserva. Para que el prompt de identidad desconocida del turno 14 siguiera mostrando el código rechazado, se acortaron dos frases de esa instrucción. El tope de este diff sigue en 2400. La reparación del recorte, más abajo, lo sube a 2472. La reparación de continuidad lo devuelve a 2400.

Pendiente: el efecto de la consulta expandida sobre el retrieval y sobre la respuesta real. Esta corrección no lo ejecuta.

Veredicto de este diff: `CORRECCIONES_LOCALES_COMPLETADAS`.

#### Contrato N4 de citas ajenas (2026-10-07)

Sobre `12af56c`. El test `foreign manufacturer chunks cannot create manual fact` seguía omitido por `n0_contract!("N4")`. Con `N0_CONTRACTS=1` se ejecutó de verdad: 1 corrida, 3 aserciones, 0 fallos, 0 skips. `retrieve_chunks` y el generador están stubbeados. No hubo llamada a AWS, Retrieve ni modelo.

El contrato ya se cumple: un chunk de otro fabricante no queda citable y la respuesta no forma un `MANUAL_FACT`. Se retiró solo ese `n0_contract!("N4")`. Las aserciones siguen. El helper global y los demás contratos N0 no se tocaron. No hubo cambio de producto.

La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. `PASS_CALL_CAP` sigue en 0. Los techos y el histórico no cambian.

Veredicto de este diff: `VALIDACION_LOCAL_COMPLETADA`.

#### Comparación de retrieval (2026-10-07)

Autorizada sobre `71b83a467dad8f94a820c85d6c2054b0b65df578`. Mide si la expansión de catálogo cambia el top 8. No valida el episodio ni la respuesta del modelo. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. `PASS_CALL_CAP` sigue en 0. El histórico sigue en 106 llamadas y US$0,214838. Los techos siguen en 126, 42, 168 y US$2,50. Las dos llamadas de la comprobación web, US$0,004348, siguen aparte. Esta comparación no creó filas de `BedrockQuery`. El costo de `Retrieve` y del embedding de la consulta no está en esa tabla y queda sin cifra.

La consulta expandida salió del código local, reusando la percepción ya capturada del turno 1 de la sesión 196 (`stage2:a:t01`). No hubo una llamada nueva al intérprete. El span `Elemont MH` quedó con origen `user`. El nombre `Elemont Montacargas Hidraulico Modelo MH` entró con origen `catalog`. `CEA15` siguió con origen `user` y sin expansión a `CEA15+`. Los hechos quedaron vacíos, así que `known?` sigue falso. No hubo pin. La consulta tiene 138 caracteres, dentro del tope de 442. El visor de esa composición fue la cuenta local dueña de la fila del Elemont. El slug `danebo-legacy` de la base local es otra cuenta y no se usó para armar el filtro.

El servicio que recuperó es la imagen web `d5660d72a1e676ef9f054dd49ccc7e65511b9f2c`. Ese SHA no contiene la expansión. `BedrockRagService` no cambió entre esa imagen y `71b83a4`. Las dos llamadas fueron `retrieve_chunks` dentro del contenedor web, con la cuenta `danebo-legacy` de producción, sin URIs de foco. El filtro, la Knowledge Base `Y7RZWMFJSR`, la región `us-east-1`, HYBRID y k=8 son los de ese servicio. El filtro de las dos operaciones es el mismo. No se afirma que el compositor nuevo esté desplegado.

Hubo dos recuperaciones lógicas. La original reintentó una vez el transporte por la pausa de Aurora, espera de 15 segundos, y después respondió. La expandida no reintentó. No hubo repetición manual ni cambio de la configuración de reintentos. Ocho resultados en cada una, todos aceptados, ninguno rechazado. Duración 20542 ms y 548 ms. `PILOT_EVENTS_PERSIST=false` solo en ese proceso, para no insertar `pilot_events`. No se modificaron cuentas, documentos, sesiones ni configuración.

Elemont no aparece en ningún documento, URI ni texto de los dieciséis chunks. El rank 1 sigue siendo KONE MonoSpace, página 375, score 0,5, en las dos consultas. La expandida sube `manual-cea15p` página 84 del puesto 4 al 2, reordena páginas KONE, KOYO y VF5, saca KONE página 374 y mete el manual de ayuda técnica página 55. Esas páginas hablan de puertas de otros equipos. El único imán del texto es de zona de puertas KONE, página 444, presente en las dos consultas. No hay código 18 ni LED 7. La cifra 18 que aparece está dentro de un identificador de registro del chunk CEA15+, no es un código de falla. Un score no dice que el chunk aplique ni que un plano resuelva la falla. Este par no se generaliza a otros equipos ni a la estabilidad del ranking.

Evidencia: `tmp/documentary_retrieve/20261007T233903Z/`.

Veredicto de esta comparación: `SIN_MEJORA_OBSERVADA`.

#### Candidato a desplegar (2026-10-07)

La comparación anterior mezcló el compositor local con el servicio de `d5660d72`. No valida el companion con el código nuevo desplegado. El diff `d5660d72..2b7cbc4` tiene cuatro commits de producto y de plan. La revisión separa tres piezas:

- La expansión del nombre canónico. Queda fuera de este despliegue. En la comparación no metió el Elemont en el top 8 y cambió el orden de manuales de otros equipos. No se declara como reparación de ese fallo.
- La regla de hipótesis del guidance y el acortamiento que la mantiene dentro de 2400 caracteres. Entra. Está cubierta por test. No demuestra que el modelo la cumpla. La siguiente prueba del flujo real es la que puede observarlo.
- El contrato N4, ya sin el skip, y el test que acepta hashes iguales cuando la consulta no cambia. Entran. No cambian la consulta ni el filtro.

Salen con la expansión el tope de 120 caracteres, la plaza de identificador `catalog` y los tests de esa expansión. Nada más escribe ese origen. 156 corridas de guidance, episodio, alcance, percepción y reducer: 1693 aserciones, 0 fallos. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. `PASS_CALL_CAP` sigue en 0.

El candidato quedó en `6ca7788dd3694b90c8e6cd5d4f04d68be08f0407` y es la imagen que ejecutan el web y el worker. `https://elevator.danebo.ai/up` respondió 200. Justo después del despliegue, el contenedor web anterior `d5660d72` seguía presente, detenido. Volver a esa imagen es `kamal rollback d5660d72a1e676ef9f054dd49ccc7e65511b9f2c`. Los trabajos de ingesta sin terminar estaban fallidos desde agosto y no había ninguno en ejecución.

#### Turno real sobre la imagen nueva (2026-10-07)

Un solo `POST /rag/ask` dentro del contenedor web, por el mismo controlador que usa el formulario. Host `elevator.danebo.ai`, cuenta `danebo-legacy`, usuario aislado creado para esta prueba y borrado al terminar. La sesión de ese usuario quedó en cero. No pasó por el socket público de Puma: el cliente fue el proceso de Rails, así que el log de acceso del proxy no tiene esta petición. La pregunta fue la del turno 1, sin pin y sin el nombre canónico agregado a mano. Correlación `query:9ff9190d-225c-4439-bef3-f5db8f0a22e6`. HTTP 200.

La consulta efectiva es el texto del técnico, 97 caracteres, el mismo SHA que la consulta original de la comparación anterior. HYBRID, k=8, el mismo filtro, ocho chunks aceptados. No hay Elemont. El orden coincide con la columna original de esa comparación: KONE 375, KONE 446, KOYO 131, CEA15+ 84, VF5 13, KONE 444, KONE 374, KONE 442. Aurora reintentó una vez el transporte, 15 segundos. No hubo repetición manual.

La respuesta no cita el Elemont ni nombra un sensor de jamba. Dice que la puerta no cierra y el imán no magnetiza, y luego presenta desalineación, obstrucción o falla de alimentación del circuito del imán de retención. Esas tres causas no están en la pregunta ni en una cita del Elemont. Una respuesta no demuestra que la regla de hipótesis se cumpla. El turno ofreció dos manuales privados, `manual-cea15p` y el plano Elemont, como sugerencia. La sugerencia no es un chunk recuperado y no dice que el plano resuelva la falla.

Dos filas de `BedrockQuery`: intérprete US$0,00348 y generación `rag_global` US$0,001403. Total US$0,004883. Quedan aparte del histórico de 106 llamadas y US$0,214838, y aparte de los US$0,004348 de la comprobación web anterior. `Retrieve` y el embedding no están en esa tabla. `PASS_CALL_CAP` sigue en 0. Los techos no cambian.

Evidencia: `tmp/documentary_retrieve/20261008T002051Z/evidence.json`.

La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`.

#### Reparación de designadores con signo (2026-10-07)

Sobre `47c43e24bd8dd561f696fe095feae14fa46ec487`. Sin AWS, sin Retrieve, sin modelos, sin embeddings, sin journeys, sin despliegue y sin cambios de infraestructura. `PASS_CALL_CAP` sigue en 0. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. Esta reparación no autoriza una pasada ni revalida el episodio.

La última evidencia de imagen es `6ca7788`. Esa imagen no contiene la resolución de marca compuesta ni esta reparación. `47c43e2` es la base. La comparación que conserva el signo quedó en `700d9d0`, en `main`, y no es la imagen evidenciada.

Antes de corregir, cinco pruebas nuevas fallaban. El control positivo no fallaba: «Elemont MH+» ya resolvía la entrada Elemont / MH+.

- `resolve_compound_brand` comparaba el designador con `normalize_label`, que elimina «+». La entrada confirmada y visible Elemont / MH+ resolvía el span «Elemont MH» y escribía el fabricante.
- Con Elemont / MH y Controles S.A. / CEA15+, ambos confirmados, vinculados a `KbDocument` y autorizados para el mismo visor, el turno «Elemont MH con placa CEA15; la puerta 1 no termina de cerrar y el imán no magnetiza. ¿Qué reviso?» resolvía CEA15 como CEA15+. El reducer sustituía el fabricante del equipo por Controles S.A. El intérprete de sesión hacía lo mismo.
- El span explícito CEA15+ sí resolvía el controlador, y su fabricante sustituía al Elemont ya establecido.

`FollowupQueryRewriter.normalize_label` no cambió. La comparación de designadores conserva «+». No hay coincidencia difusa. MH no selecciona MH+. CEA15 no selecciona CEA15+. MH+ y CEA15+ siguen resolviendo su entrada. El prefijo que ya existía, como NICE3000n, sigue. VF5 deja de seleccionar VF5+ por la misma comparación; VF5+ sigue siendo exacto. Un designador sin tipo, MH, sigue sin escribir controlador ni modelo.

La marca del controlador llena el fabricante del equipo solo cuando ese hecho está vacío. No sustituye uno ya guardado. NICE3000 sigue pudiendo escribir MONARCH cuando no hay fabricante. No se tocó `EquipmentIdentity#known?`, `NEEDLE_SOURCES` ni el origen `catalog`. No hay pin ni expansión del nombre canónico. Siguen los controles de ambigüedad, de otro tenant, de entradas duplicadas, de negación y de conservación de otro fabricante. No se modificó el fixture del journey A.

Evidencia local, con `PASS_CALL_CAP=0`: `turn_perception_test`, `conversation_session_turn_interpreter_test`, `technical_understanding_test`, `document_identity_catalog_tenant_test`, `route_policy_test`, `companion_guidance_context_test` y `work_context_reducer_test`. 154 corridas, 1322 aserciones, 0 fallos, 0 errores y 0 skips.

Pendiente, y este diff no lo ejecuta: el efecto sobre el retrieval y sobre la respuesta real. El ranking que no devolvió el Elemont sigue abierto. La etapa 3 no empieza.

Veredicto de este diff: `REPARACION_LOCAL_COMPLETADA`.

#### Reparación del recorte de guidance (2026-10-08)

Sobre `700d9d0`. Sin AWS, sin Retrieve, sin modelos, sin embeddings, sin journeys, sin despliegue y sin cambios de infraestructura. `PASS_CALL_CAP` sigue en 0. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. Esta reparación no autoriza una pasada y no revalida el episodio.

`CompanionGuidanceContext#to_s` terminaba en `text[0, MAX_CHARS]`. En `tmp/stage2_journey_a/runs/20261007T193541Z-session-196/` hay 12 prompts de `generate_text`. Diez miden 2400 caracteres. El turno 14 termina en «Corrijo al». La frase completa está en `history.user_texts`: «Corrijo algo de antes: la cabina está detenida cerca de planta 2, no de planta 1.» Ese corte también se lleva el Follow-up y la lista de manuales. El turno 2 mide 2380 y sí cierra con `manual-cea15p` p. 84.0, `manual-cea51fb-das` p. 82.0, `manual-cea15p` p. 65.0 y `Follow-up: yes.` Los turnos 10 y 13 no tienen prompt de generación. Esos prompts son del código de `da8d32b`. La reproducción usa el compositor actual y los textos capturados. No reconstruye el cuerpo que el corte ya había eliminado.

Ese recorte es distinto de la planta. El episodio capturado del turno 14 sigue con la observación «cerca de planta 1», porque el turno 13 no aplicó la corrección. El código que después la aplica está en la imagen evidenciada `6ca7788` y no fue revalidado. Esta reparación no reescribe esa observación.

Antes del cambio, la prueba con el bloque capturado del turno 14 y los tres manuales del turno 2 falló: el prompt medía 2400 y no contenía la corrección completa. El visible terminaba en «Corrijo al».

Con la instrucción actual, el resto obligatorio mide 2472 caracteres después de sacar enteros los manuales candidatos y el turno «Sigue igual.»: la instrucción, «¿Y ahora?», el objetivo, el código 18, los identificadores, las observaciones, `Not current: fault code 8`, la corrección y el Follow-up. 2400 no lo contiene. El tope pasa a 2472, que es ese resto. No hay margen añadido para que la prueba pase.

Bajo esa presión se conserva la instrucción, incluida la regla de hipótesis, la prohibición de enseñar manuales recuperados y la de inventar valores, terminales y significados de código. Se conserva la pregunta, el problema vigente, la corrección completa y el Follow-up. Se descartan las tres líneas de manual y su encabezado, y el turno anterior «Sigue igual.». Un objetivo que no cabe, como ochocientas repeticiones de «detalle», sale entero. La línea de objetivo de la instrucción permanece.

Si el bloque de problema ya trae planta 2 en lugar de planta 1, la línea `Obs:` conserva planta 2 y no contiene planta 1. El código 18 sigue vigente. El código 8 aparece solo en `Not current: fault code 8`. La frase de corrección puede nombrar planta 1 como el valor que se dejó atrás. Identidad conocida, con la instrucción más corta, cabe con los manuales de referencia y los dos turnos. Español e inglés comparten la composición; «English» y «Spanish» ocupan los mismos caracteres. Un contexto corto no omite unidades.

Una pregunta que ya usa casi el tope de entrada de 400 caracteres deja el episodio fuera: se omiten enteros el objetivo, la foto, el historial y los manuales, y se conservan la pregunta y el Follow-up. La frase de búsqueda vacía, sumada a este episodio, tampoco deja sitio a las observaciones: salen enteras. Quedan la corrección, el código 18, el Follow-up y la pregunta. Conservar además esas observaciones mediría 2706. No se sube el tope hasta ahí.

La captura `context_fit` anota cada unidad omitida con su rol y su texto. Ya no guarda un sufijo cortado a 2400.

No cambió la percepción, el reducer, `EquipmentIdentity#known?`, el retrieval, los pins, la aceptación del journey A ni su fixture. No hay `pending_question` conversacional ni respuesta meta. No hay otro agente ni otra llamada.

Evidencia, con `PASS_CALL_CAP=0`: `companion_guidance_context_test`, `validation_capture_test` y `session_context_builder_test`. 92 corridas, 1126 aserciones, 0 fallos, 0 errores y 0 skips. Dos pruebas de guidance con búsqueda vacía en `document_identity_scope_test`: 2 corridas, 29 aserciones, 0 fallos.

Esas pérdidas bajo pregunta larga y búsqueda vacía, y el tope 2472 calculado sobre el turno 14, quedan cerradas por la reparación de continuidad. Esta sección describe el commit de unidades, no el compositor vigente.

Pendiente de ese commit: el efecto sobre una pasada real y sobre la respuesta del modelo. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. La etapa 3 no empieza. Ese commit quedó en `main` para revisión y no se desplegó. No hay una comprobación nueva de la imagen en ejecución.

#### Continuidad del episodio bajo presión (2026-10-08)

Sobre `085969c`. Sin AWS, sin Retrieve, sin modelos, sin embeddings, sin journeys, sin despliegue y sin cambios de infraestructura. `PASS_CALL_CAP` sigue en 0. Los techos y el histórico de 106 llamadas y US$0,214838 no cambian. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. Esta reparación no autoriza una pasada y no revalida el episodio.

La composición por unidades se conserva. No vuelve el corte ciego del prompt final. El tope vuelve a 2400: la compactación cabe y 2472 era el resto exacto del turno 14, no un presupuesto general. No se sube el tope.

La instrucción se parte en reglas que no salen antes que el episodio y en frases de estilo que sí pueden salir enteras. Se conservan el objetivo del turno, la separación entre reporte, evidencia e hipótesis, el límite de procedimientos sin evidencia, el componente no confirmado como condicional, la búsqueda vacía que no significa que el manual no exista, el idioma y la continuidad. No se borró una restricción del compositor para hacer caber un fixture. La frase media de la búsqueda vacía se acortó; siguen «Do not say the manual does not exist.» y, con foco fijado, «Do not release the pin.»

El orden de descarte es: manuales candidatos sin contenido aplicable, historial redundante o duplicado de forma comprobable, turnos viejos, el indicador Follow-up y después las frases de estilo. El Follow-up no sustituye al caso. Una observación no se funde con otra por compartir tokens: solo sale si es un eco de continuidad o si la frase completa ya está en el objetivo o en una observación anterior. Si aún no cabe, salen unidades enteras. Una corrección no se parte en 160 caracteres. Una pregunta de más de 400, o un turno que no es corrección y pasa de 160, se corta en el último espacio útil y el resto queda como recorte previo.

`context_fit` distingue la unidad omitida del recorte previo. El recorte lleva `prior_cut`. No se anota como intacto el texto que ya se cortó.

Antes de cambiar las expectativas, la pregunta larga, la búsqueda vacía, el foco fijado, la corrección de más de 160 caracteres y el caso genérico perdían el episodio o partían la corrección. Con el tope en 2400:

- Turno 14 de la sesión 196: 2359 caracteres. Conserva la pregunta, el objetivo, el código 18, los identificadores, las observaciones y sus comprobaciones, el código 8 solo como no vigente y la corrección completa. Salen los manuales candidatos, «Sigue igual.» y el Follow-up.
- La misma sesión con la planta ya corregida conserva planta 2 en `Obs:` y planta 1 solo en la corrección.
- Pregunta natural cercana al máximo, sobre ese episodio: 2359 caracteres. Conserva objetivo, identidad, código, corrección y comprobaciones. El Follow-up sale.
- Búsqueda vacía sobre ese episodio: 2341 caracteres. Conserva el episodio y la regla de búsqueda vacía.
- Búsqueda vacía con foco fijado: 2219 caracteres. Conserva el episodio y la regla del pin.
- Corrección relevante por encima de 160 caracteres: queda entera.
- Caso genérico, distinto de Elemont, con pregunta larga y búsqueda vacía: 2393 caracteres. Conserva el objetivo, Nortec, el código 41, el código 7 solo como no vigente, la planta 4 vigente, la corrección que deja atrás la planta 3 y la comprobación del indicador. En ese caso, ya sin manuales en el prompt, también sale la frase de no enseñar manuales recuperados. Las reglas de procedimiento, hipótesis, invención y búsqueda vacía siguen.
- Un contexto corto no omite unidades. Identidad conocida y desconocida, en español y en inglés, usan el mismo presupuesto. La instrucción conocida, más corta, sigue pudiendo incluir manuales de referencia, historial y Follow-up.

No hay rama por sesión, fixture, fabricante ni texto del journey. No hay otra llamada de modelo, tabla, agente ni sistema de memoria. No cambió la percepción, el reducer, `EquipmentIdentity#known?`, el retrieval, los pins ni el fixture del journey A.

Evidencia local, con dependencias externas stubbeadas y `PASS_CALL_CAP=0`: `companion_guidance_context_test`, `validation_capture_test` y `session_context_builder_test`, 98 corridas, 1243 aserciones, 0 fallos, 0 errores y 0 skips. Rutas de guidance con búsqueda vacía, pin vacío, identidad conocida sin manual y conflicto de fabricante, en `document_identity_scope_test` y `field_companion_pilot_readiness_test`: 8 corridas, 179 aserciones, 0 fallos, 0 errores y 0 skips. RuboCop sobre el compositor y esas pruebas no reportó ofensas. `git diff --check` quedó limpio.

Implementado: la continuidad local del compositor. Desplegado: no. La imagen evidenciada sigue siendo `6ca7788`. Revalidado: no. Pendiente de ese commit: el efecto sobre una pasada real y sobre la respuesta del modelo. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. La etapa 3 no empieza. Ese commit quedó en `main` y no se desplegó. El caso combinado que todavía expulsaba el objetivo queda en la sección siguiente.

#### El objetivo no compite por longitud (2026-10-08)

Sobre `8274192`. Sin AWS, sin Retrieve, sin modelos, sin embeddings, sin journeys, sin despliegue y sin cambios de infraestructura. `PASS_CALL_CAP` sigue en 0. Los techos y el histórico de 106 llamadas y US$0,214838 no cambian. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. Esta reparación no autoriza una pasada y no revalida el episodio.

Antes de cambiar el producto, el test de Rails juntó el episodio genérico de Nortec, la pregunta larga, `empty_retrieval: true` y la corrección de 217 caracteres. El prompt midió 2368 caracteres. Conservó la pregunta, el fabricante, los identificadores, el código 41, el código 7 como no vigente, las comprobaciones y la corrección completa. Omitió `Goal: la puerta del montacargas no termina de cerrar`. La unidad omitida era el hecho de rol `problem`, rango 4 y `seq` 52, igual a su longitud. La corrección, también rango 4, tenía `seq` 1 por su posición. `fit_guidance` comparaba esos números y sacaba el objetivo antes que la corrección. El caso genérico anterior, con la corrección corta, seguía en 2393 y sí conservaba el objetivo.

`MAX_CHARS` sigue en 2400. El objetivo y el resto de los hechos dejan de usar la longitud como `seq`. El objetivo queda en 0. Identidad, códigos, conflicto y la observación visual quedan en 1. Las observaciones siguen ordenadas por posición. La composición por unidades no cambia y no vuelve el corte final.

Para que ese cambio no desplace la pérdida a la identidad, el código, la corrección o una comprobación, se acortó la instrucción que ya estaba en el prompt. Sale «then ask that one check», porque la regla breve lo cubre. La intervención física y la operativa quedan en una frase. La búsqueda vacía conserva «The search returned no documentation. Do not say the manual does not exist.» y suelta la oferta intermedia, que ninguna prueba exigía y que las reglas de procedimiento e invención ya cubren. Entra en el núcleo «One useful question when needed. Not a questionnaire.» Siguen la hipótesis, el componente no establecido como condicional, los límites de procedimiento, valor e intervención, el uso de lo ya comprobado, el idioma y la continuidad.

Con la corrección de 217 caracteres el prompt mide 2361. Con el foco fijado vacío mide 2394. Los dos conservan la pregunta, el objetivo, Nortec, el identificador, el código 41, el código 7 solo como no vigente, la corrección completa, las cinco comprobaciones, la regla de búsqueda vacía y la pregunta útil. El segundo también conserva la regla del pin. Salen los manuales candidatos, «Sigue igual.», el Follow-up y las frases de estilo. En el caso con pin también sale «Do not cite manuals with [n].». Esas omisiones siguen anotadas en `context_fit`.

Evidencia local, con dependencias externas stubbeadas y `PASS_CALL_CAP=0`: `companion_guidance_context_test` y `validation_capture_test`, 53 corridas, 905 aserciones, 0 fallos, 0 errores y 0 skips. `session_context_builder_test`, 47 corridas, 412 aserciones, 0 fallos y 0 skips. Rutas de guidance con búsqueda vacía, pin vacío, identidad conocida sin manual, conflicto de fabricante y la proyección del journey A: 10 corridas, 301 aserciones, 0 fallos y 0 skips. RuboCop no reportó ofensas. `git diff --check` quedó limpio.

Implementado: esta reparación local. Desplegado: no. La imagen evidenciada sigue siendo `6ca7788`. Revalidado: no. Pendiente: el efecto sobre una pasada real y sobre la respuesta del modelo. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. La etapa 3 no empieza. Este diff queda en `main` para revisión y no se despliega.

#### Aislamiento del Journey A de texto (2026-10-08)

Sobre `c6c80ad`. Sin AWS, sin Retrieve, sin intérprete, sin generación, sin journey y sin despliegue. No cambia código de producto, filtros, presupuesto ni la configuración habitual. `PASS_CALL_CAP` sigue en 0. El histórico sigue en 106 llamadas y US$0,214838. Los techos siguen en 126, 42 reservadas para la etapa 3, 168 y US$2,50. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. Este ajuste no autoriza la pasada.

El runner de `c6c80ad` exigía `smart_deal_development` en localhost. El proceso que carga `script/field_companion/stage2_journey_a.rb` ahora exige el adaptador `postgresql`, el entorno de desarrollo, el host `localhost` o `127.0.0.1` y la base `smart_deal_stage2_isolated`. Solid Cache y Solid Cable se conectan en ese mismo proceso a `smart_deal_stage2_isolated_cache` y `smart_deal_stage2_isolated_cable`. Cambiar `ActiveRecord::Base` no mueve esas dos conexiones: cada clase se conecta sola y la conexión efectiva tiene que coincidir con el nombre. Solid Queue no se redirige y no se crea otra base de cola. `TrackBedrockQueryJob` se ejecuta en línea. Cualquier otro `perform_later` aborta antes de escribir `smart_deal_development_queue`. No se arrancan workers ni se ejecutan trabajos pendientes.

Esos cambios viven en el proceso de validación. No editan `.env`, credentials, `database.yml`, `cache.yml`, `cable.yml` ni `deploy.yml`. Un proceso que no carga el runner sigue en `smart_deal_development`, `smart_deal_development_cache`, `smart_deal_development_cable` y `smart_deal_development_queue`, y arma el filtro local de las cuentas 1 y 4.

La base aislada conserva las dos cuentas y los dos documentos ya reconstruidos desde evidencia. No había un usuario en esa evidencia, así que usuarios, sesiones, fotos, documentos de técnico, ingestas y la auditoría de esta prueba empiezan vacíos. El control de presupuesto no lee esas filas: `Stage2RunBudget` suma las 106 llamadas y US$0,214838 aunque `BedrockQuery` esté en cero. `stage2_journey_a_main` consulta ese control y vuelve antes de crear la sesión, de `Retrieve` y de la generación, aunque `STAGE2_JOURNEY_AUTHORIZED=1`.

El catálogo tiene 204 entradas. En esa base se enlazan 2. Faltan 202 filas. La preparación no demuestra equivalencia completa con producción. No se borraron datos de desarrollo ni capturas anteriores para lograr el aislamiento.

Evidencia local, con dependencias externas stubbeadas y `PASS_CALL_CAP=0`: `stage2_journey_a_runner_test`, `stage2_run_budget_test` y `validation_capture_test`. 30 corridas, 271 aserciones, 0 fallos, 0 errores y 0 skips. `ruby -c` del runner quedó correcto. RuboCop no reportó ofensas. `git diff --check` quedó limpio.

Veredicto de este diff: `AISLAMIENTO_LOCAL_PUBLICADO`. Implementado: el aislamiento del proceso de validación. Desplegado: no. La imagen evidenciada sigue siendo `6ca7788`. Revalidado: no. Pendiente: la revisión de este diff. La pasada no empieza desde aquí. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. La etapa 3 no empieza.

#### Pasada local aislada (2026-10-08)

Sobre `10dda24`, con el cupo de esta única corrida todavía abierto: `PASS_CALL_CAP` 42, techo de etapa 2 en 148, reserva de etapa 3 en 42 y techo global en 190. El histórico de entrada siguió en 106 llamadas y US$0,214838. `AWS_MAX_ATTEMPTS=1` en ese proceso limita los reintentos. No prueba que un error haya ocurrido antes de enviar la solicitud. Una fila `BedrockQuery` demuestra una llamada registrada; no demuestra por sí sola un intento remoto que falló antes de crear esa fila. Sin despliegue y sin escribir producción. La etapa 3 no empieza.

Rails local. Bases `smart_deal_stage2_isolated`, `smart_deal_stage2_isolated_cache` y `smart_deal_stage2_isolated_cable`, host local. La cola siguió en `smart_deal_development_queue` y no recibió trabajos: el tracker corrió en línea. El filtro, armado con el código de producto antes de la primera llamada, fue el de la captura: cuenta 1, o la cuenta 3 sin foto de campo y sin `manual_corpus=account`, o `manual_corpus=general`. Knowledge Base `Y7RZWMFJSR`, región `us-east-1`, modelo `global.anthropic.claude-haiku-4-5-20251001-v1:0`. Sin pin. Una sesión, episodio `ep_dfae85c99c49b0a7` desde el turno 2. SHA de git `10dda240cb71533518ace53a1ef24b58ede06be2`; el cupo abierto estaba en el árbol de trabajo y este cierre lo deja en 0.

La disponibilidad devolvió el Elemont MH, páginas 1 y 7, y también Thyssen CMC-3. Aurora reanudó una vez, 15 segundos. Esa repetición no creó fila `BedrockQuery`. Ninguna búsqueda del episodio devolvió el Elemont. Devolvieron, entre otros, KONE MonoSpace, CEA15+, CEA51FB, VF5 y CMC4. Todas las filas registradas quedaron aceptadas: 199 por corpus compartido y 45 por la cuenta del visor. Ninguna fue rechazada. Recuperar esos manuales no los hace aplicables al Elemont. Desde el turno 7 la captura muestra dos `Retrieve` híbridos de la misma consulta, k=20 y k=8, con el mismo filtro. El costo de `Retrieve` y del embedding no está en las 26 filas.

El turno 1 buscó sin pedir fabricante, modelo ni controlador. El intérprete devolvió `transport_error` y no escribió percepción: la traza no guardó la clase de la excepción. El episodio no conservó Elemont MH ni CEA15. No los convirtió en `CEA15+`. El objetivo pasó a ser «El display muestra código 8» y, tras la corrección, quedó en «El display muestra».

La corrección 8 → 18 sí se aplicó en el turno 5. El código 18 quedó como hecho y el 8 como no vigente. La planta 1, la reapertura, la guía sin obstrucción, el LED 7 y el clic siguieron en las observaciones. «Sigue igual» y «¿Y ahora?» permanecieron en el mismo episodio. El historial se recortó a 20 mensajes desde el turno 10 y esos hechos siguieron.

La corrección de planta no reemplazó la observación anterior. El turno 13 emitió `correct`, la percepción recuperó «la cabina está detenida cerca de planta 2» y el delta solo agregó esa frase: `removed` quedó vacío. El prompt del turno 14, 2376 caracteres en el guidance, lleva las dos plantas en `Obs:` y solo saca el código 8 en `Not current`. La respuesta dijo planta 2. El estado y la consulta siguieron tratando la planta 1 como vigente.

El turno 5 dijo que el código 18 típicamente indica una falla de cierre, sin una cita del Elemont. El turno 1 pidió mirar terminales del imán. Esas frases no salen del reporte ni de un chunk compatible. El turno 14 nombra solenoide, motor o trinquete como el mecanismo del clic, resume lo comprobado y pide observar desgaste o desalineación en el marco. No cita el Elemont, no declara la puerta reparada y no es éxito documental. La disponibilidad ya había mostrado que el manual es recuperable.

Consumo de modelo en `BedrockQuery`: 13 análisis y 13 generaciones `rag_global`, 26 llamadas, US$0,060975. Acumulado con el histórico: 132 llamadas y US$0,275813. Quedan 16 dentro de 148. `PASS_CALL_CAP` vuelve a 0 y no abre otra pasada. La etapa 3 conserva 42 dentro de 190. Tope US$2,50. No hay rollup de `bedrock_daily_costs` de esta corrida.

Evidencia: `tmp/stage2_journey_a/runs/20261008T214541Z-session-1/` y la exportación `tmp/stage2_journey_a/exports/20261008T215032Z/`. 101 `pilot_events`. Un proceso que no carga el runner sigue en las bases de desarrollo: 4 cuentas, 25 documentos, 8 usuarios, 57 sesiones, 2649 consultas y 5173 eventos.

Faltan 202 filas del catálogo. El recorrido es el runner, no `POST /rag/ask`. Esta corrida no demuestra equivalencia completa con producción.

Veredicto: `BLOQUEADO`. No es `EPISODIO_VALIDADO`. La falla demostrada es la planta 1 vigente después de la corrección, más significados y terminales que no están en la evidencia. La búsqueda del episodio sin el Elemont, con el manual recuperable en la disponibilidad, impide por sí sola el éxito documental. No se repara ni se repite desde este cierre. La reparación local posterior está en la sección siguiente y no reabre esta pasada. La etapa 3 no empieza.

#### Reparaciones locales sobre la evidencia de la pasada (2026-10-08)

Sobre `aac7ff789e5d42a918ed12c64d2fe43a98cefa0c`. Sin AWS, sin Retrieve, sin intérprete real, sin generación real, sin journey y sin despliegue. `PASS_CALL_CAP` sigue en 0. El histórico sigue en 132 llamadas y US$0,275813. No se asigna costo al intento que no creó fila. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. La etapa 3 no empieza.

Reparado y probado en local, con la percepción y el estado capturados:

- Planta. El primer punto es `WorkContextReducer#retracted_phrases`. La etiqueta normalizada perdía el punto y capturaba «planta 1 no», así que el turno 13 no retiraba la observación. La retracción se corta en la puntuación de la oración. `excise_retracted_phrase` quita solo la cláusula que contiene la frase y conserva el resto unido por « y ». Planta 2 queda vigente. Planta 1 deja de estarlo. «No hay personas dentro», la puerta, la reapertura, la guía, el LED, el clic y el código 18 se conservan. El estado, la consulta y el prompt coinciden después de guardar y releer.
- Objetivo residual. El primer punto es `SlotRejection.excise_text` al negar el código 8 sobre «El display muestra código 8». El resto no es un problema. `adopt_problem_goal!` toma una observación que sí lo es. Informar o corregir un código no convierte ese resto en el objetivo. Un seguimiento o una comprobación no lo sustituye. Un `new_work` explícito sigue abriendo el objetivo nuevo. No se escribe una frase fija del fixture.
- Identificador «clic». El primer punto es `WorkContextReducer#durable_identifier?`. Un identificador mencionado dentro de una observación no se guarda si la etiqueta no tiene dígito. «clic» queda como observación. Elemont MH y CEA15, cuando una percepción válida los trae y no están dentro del síntoma, siguen. Una extracción fallida no escribe fabricante ni modelo.
- Resumen técnico. El primer punto es `TurnPerception#adjust_move`. El modelo marcó el turno 10 como `meta` y `RoutePolicy` respondió «Puedes seguir con lo que ya me contaste.» antes de generar. Un pedido de resumen del problema, o de la observación siguiente, pasa a `follow_up`. Un saludo, un pedido de lo que Danebo necesita y una oferta de foto siguen en `meta`. El episodio se conserva. El generador recibe el problema, las comprobaciones y las correcciones vigentes. El pedido mixto mantiene las dos intenciones.
- Fallo del intérprete. La captura del turno 1 tiene `route_exit` `fallback` / `transport_error` y no tiene `interpreter_raw` ni la clase de la excepción. Esa causa no se recupera. El rescate ahora registra `interpreter_failure` con clase, motivo sanitizado, etapa `converse`, correlación e intento. Los reintentos no cambian. Si el reporte es un síntoma buscable, el fallback conserva el texto literal como objetivo y observación, con la correlación, y no escribe hechos ni identificadores. El turno siguiente ve ese antecedente. No confirma identidad.

Causa aún desconocida: la excepción del turno 1. El límite de reintentos no prueba que la solicitud haya salido del proceso.

Comportamiento del modelo aún no revalidado. Los prompts guardados de los turnos 5, 8 y 12 ya traían la regla de no inventar, la separación del reporte y la regla de hipótesis. «El código 18 típicamente indica…», «el clic indica que el comando de cierre se recibe…» y «clic repetido» están en las respuestas, no en los hechos del episodio. El prompt del turno 14 repite «clic repetido» porque la respuesta anterior entra en el historial como asistente. Un test del prompt no declara corregida esa conducta. No se añadieron filtros de esas frases.

Retrieval documental aún pendiente. La disponibilidad recuperó el Elemont MH y el episodio no lo usó. Faltan 202 filas del catálogo. El recorrido fue el runner, no `POST /rag/ask`.

Evidencia local, con dependencias externas stubbeadas y `PASS_CALL_CAP=0`: `work_context_reducer_test`, `turn_perception_test`, `conversation_session_turn_interpreter_test`, `route_policy_test`, `validation_capture_test`, `query_composer_test`, `session_context_builder_test`, `stage2_run_budget_test`, `stage2_journey_a_runner_test`, `work_context_goal_test` y `companion_guidance_context_test`. 252 corridas, 2512 aserciones, 0 fallos, 0 errores y 0 skips. RuboCop no reportó ofensas en los archivos tocados. `git diff --check` quedó limpio.

Veredicto de este diff: `REPARACIONES_LOCALES_COMPLETADAS`. Implementado: las correcciones locales de arriba. Desplegado: no. La imagen evidenciada sigue siendo `6ca7788`. Revalidado: no. Pendiente: la causa del `transport_error` del turno 1, el cumplimiento del modelo en una pasada real y la búsqueda documental del Elemont. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. La etapa 3 no empieza. Este diff queda en `main` para revisión y no se despliega.

#### Correcciones de la revisión local (2026-10-08)

Sobre `337ea91e843b46983c36c0e5bcf9265c8ec14e48`. Sin AWS, sin Retrieve, sin intérprete real, sin generación real, sin journey y sin despliegue. `PASS_CALL_CAP` sigue en 0. El histórico sigue en 132 llamadas y US$0,275813. No se abre otra pasada. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. La etapa 3 no empieza.

Dos puntos de la reparación anterior quedaron mal cerrados. No cambian filtros, modelos ni presupuesto.

- Observaciones numéricas. `WorkContextReducer#durable_identifier?` guardaba como identificador una frase de la observación si contenía un dígito. «planta 2» y «LED 7 apagado», devueltos a la vez como observación y como assert sin slot, ocupaban plazas de identidad. Un dígito separado no es un designador. La frase sigue en las observaciones. Se conserva el identificador cuando el catálogo o un slot de fabricante, modelo o controlador ya lo registró, o cuando el token es un designador (`CEA15`, `NICE3000`, `Elemont MH`), también si la observación nombra ese equipo. No se escribe fabricante ni modelo si el catálogo no lo confirmó. `known?` no cambia. La ambigüedad y la autorización del catálogo no cambian. `CEA15` no pasa a `CEA15+`. Al guardar y releer, planta, LED y clic no entran en los identificadores.
- Etapa del intérprete. `interpret_turn` rescataba también lo que ocurre después de `converse`, y `interpreter_failure` y `PilotUsageLog` decían siempre etapa `converse` y fallo de transporte. La etapa queda en `prepare`, `converse`, `extract` o `perception`. Solo `converse` clasifica transporte (`timeout`, `throttle`, `transport_error`). Un error local posterior usa `local_error`. El contrato de una herramienta inválida sigue en `invalid_schema`, sin `interpreter_failure`. El motivo se sanitiza igual. La correlación y el intento se conservan. Los reintentos no cambian. Si ya había usage válido, `TrackBedrockQueryJob` se encola una vez y el fallo queda en otro evento. Sin usage no se inventan tokens ni costo.

Evidencia local, con dependencias externas stubbeadas y `PASS_CALL_CAP=0`: `work_context_reducer_test`, `turn_perception_test`, `turn_interpreter_failure_test` y `conversation_session_turn_interpreter_test`. 117 corridas, 1017 aserciones, 0 fallos, 0 errores y 0 skips. RuboCop no reportó ofensas en los archivos tocados. `git diff --check` quedó limpio.

Veredicto de este diff: `CORRECCIONES_LOCALES_COMPLETADAS`. Implementado: las dos correcciones de arriba. Desplegado: no. La imagen evidenciada sigue siendo `6ca7788`. Revalidado: no. Pendiente: la causa del `transport_error` del turno 1, el cumplimiento del modelo en una pasada real y la búsqueda documental del Elemont. La etapa 2 sigue `BLOQUEADA`. No es `EPISODIO_VALIDADO`. La etapa 3 no empieza. Este diff queda en `main` para revisión y no se despliega.

#### Pasada local aislada sobre 1570d7d (2026-10-08)

Sobre `1570d7d1be0afb813cf94705649017d90f329177`. Una sola pasada de los turnos 1 a 14. Sesión aislada 2, episodio `ep_4e26498ea955c600` desde el turno 1. Trazas en `tmp/stage2_journey_a/runs/20261008T234453Z-session-2/`. Exportación de esta sesión: `tmp/stage2_journey_a/exports/20261008T234658Z/`. La pasada anterior, `tmp/stage2_journey_a/runs/20261008T214541Z-session-1/`, no se reescribió. Sin pin, sin L3, sin fotos, sin journey B, sin cambio de caso y sin recuperación de casos. Sin segunda pasada y sin reparación durante la corrida. Sin despliegue y sin escritura en las bases Rails de producción. La etapa 3 no empieza.

El cupo de esta corrida estuvo abierto en el árbol de trabajo: `PASS_CALL_CAP` 42, techo de etapa 2 en 174, reserva de etapa 3 en 42 y techo global en 216. El histórico de entrada siguió en 132 llamadas y US$0,275813. El tope de costo siguió en US$2,50. `AWS_MAX_ATTEMPTS=1`. Este cierre deja `PASS_CALL_CAP` en 0. El control del runner ahora suma los intentos de modelo que la captura muestra y que no crearon fila. Una fila sigue siendo una llamada registrada con usage. Un intento sin fila consume cupo y no inventa costo. `Retrieve` sigue fuera de ese cupo. En esta pasada los intentos y las filas coincidieron: 28 y 28. No hubo intento de modelo sin costo determinado.

Rails local. El proceso de la corrida usó `smart_deal_stage2_isolated`, `smart_deal_stage2_isolated_cache` y `smart_deal_stage2_isolated_cable`. La cola siguió en `smart_deal_development_queue` y no recibió trabajos: el tracker corrió en línea. Antes de la primera llamada, el filtro armado con las cuentas 1 y 3 fue cuenta 1, o la cuenta 3 sin foto de campo y sin `manual_corpus=account`, o `manual_corpus=general`. Knowledge Base `Y7RZWMFJSR`, región `us-east-1`, modelo `global.anthropic.claude-haiku-4-5-20251001-v1:0`. Esos valores iban en el proceso. `.env`, credentials, `database.yml`, `cache.yml`, `cable.yml` y las políticas de acceso no se editaron. Un proceso nuevo, sin el runner, vuelve a `smart_deal_development`, `smart_deal_development_cache`, `smart_deal_development_cable` y `smart_deal_development_queue`. Su filtro es cuenta 1, o la cuenta 4 sin foto de campo y sin `manual_corpus=account`, o `manual_corpus=general`. La Knowledge Base habitual de ese proceso es `QGVYLPTEGT`. Conteos: 4 cuentas, 25 documentos, 8 usuarios, 57 sesiones, 2649 consultas y 5173 eventos. `PASS_CALL_CAP` en ese proceso quedó en 0.

La disponibilidad, separada de las búsquedas del episodio, recuperó el Elemont MH, páginas 1 y 7, cuenta 1, y Thyssen CMC-3. Aurora reanudó una vez, 15 segundos. Esa repetición no creó fila `BedrockQuery`. Cada turno del episodio hizo un `Retrieve` híbrido, k=8, con el mismo filtro. La compuerta aceptó los 8 resultados: corpus compartido o cuenta del visor. El conjunto citado de la publicación quedó vacío. Ningún resultado del episodio fue el Elemont. Aparecieron, entre otros, KONE MonoSpace, `manual-cea15p`, VF5, BL6, CMC4 y Fuji Yida. Aceptar esos manuales, ver un score o autorizar el acceso no los hace aplicables al Elemont MH. El prompt de guidance declara la identidad sin confirmar, retira el contenido de los manuales recuperados y prohíbe inventar el significado de un código. El costo de `Retrieve` y del embedding no está en las 28 filas.

El turno 1 interpretó y buscó. El objetivo quedó «la puerta 1 no termina de cerrar el imán no magnetiza». Elemont MH y CEA15 quedaron como identificadores de procedencia `user`. El fabricante Elemont quedó como hecho de catálogo. El prompt dice que la identidad no está confirmada. CEA15 no pasó a CEA15+. El código 8 pasó a 18 en el turno 5: el 18 es el hecho vigente y el 8 queda en `Not current`. El objetivo no se degradó. La guía quedó en la observación «no veo una obstrucción». El LED 7 apagado, el clic y la reapertura siguieron. Ubicación, LED y clic no ocuparon plazas de identidad.

«Sigue igual» y «¿Y ahora?» permanecieron en el mismo episodio, también con el historial recortado a 20 mensajes. El turno 10 recibió el resumen del problema y una observación siguiente: el intérprete había marcado `meta` y la regla lo pasó a `follow_up`. El turno 14 añadió «No lo sé» porque la respuesta anterior pedía el estado de un conector que el fixture no trae. No se inventó esa comprobación.

La planta 1 salió de las observaciones y se conservó «no hay personas dentro». Planta 2 no quedó en el episodio. La percepción del turno 13 traía «La cabina está detenida cerca de planta 2, no de planta 1» y `drop_contained_phrases` soltó el fragmento de planta 2. El delta agregó solo «no hay personas dentro» y quitó la frase de planta 1. El `Obs` del prompt del turno 14 no tiene planta. La frase de la corrección sigue en el historial reciente, y por eso la respuesta nombra planta 2. La consulta del turno 14 ya no la lleva.

El turno 8 dijo que el código 18 en esta placa típicamente relaciona falta de retención. Los turnos 6, 11, 13 y 14 también atribuyen al código 18 o al LED 7 una falla de cierre, de señal o de alimentación. El turno 12 convirtió el clic en «clic repetido». El turno 13 pide mirar corrosión, soltura o quemadura en el conector del imán. Esas frases están en las respuestas. El prompt guardado les prohíbe inventar ese significado y mandar a un terminal desconocido. El turno 9 nombró KONE MonoSpace como referencia no aplicada a este trabajo y no enseñó su procedimiento. El turno 14 resume parte de lo comprobado y pide otra luz en otros LED. No cita el Elemont, no declara la puerta reparada y no dice qué documentación falta. No es una respuesta documental útil ni un escalamiento fundamentado.

Consumo registrado en `BedrockQuery` de esta sesión: 14 análisis y 14 generaciones `rag_global`, 28 llamadas, 41096 tokens de entrada, 5373 de salida, US$0,067961. Intentos de modelo sin fila: 0. Acumulado con el histórico: 160 llamadas y US$0,343774. Quedan 14 dentro de 174. `PASS_CALL_CAP` vuelve a 0. La etapa 3 conserva 42 dentro de 216. Tope US$2,50. No hay rollup de `bedrock_daily_costs` de esta corrida.

Comparado con `20261008T214541Z-session-1`: el turno 1 ya interpreta y conserva el problema, Elemont MH y CEA15; el objetivo ya no se vuelve el código; el 8 pasa a 18; el turno 10 ya resume; la planta 1 ya no queda vigente. Sigue el ranking del episodio sin el Elemont, con el manual recuperable en la disponibilidad. Siguen los significados de código y de LED sin documentación aplicable, y aparece «clic repetido». La planta 2, que aquella pasada agregaba al lado de la planta 1, en esta no queda guardada.

Faltan 202 filas del catálogo. El recorrido es el runner, no `POST /rag/ask`. Esta corrida no demuestra equivalencia completa con producción.

Veredicto: `BLOQUEADO`. No es `EPISODIO_VALIDADO`. La falla demostrada es la planta 2 fuera del episodio después de la corrección, más significados, un terminal y un clic repetido que no están en la evidencia. La búsqueda del episodio sin el Elemont, con el manual recuperable en la disponibilidad, impide el éxito documental. No se repara ni se repite desde este cierre. La etapa 3 no empieza.

#### Diagnóstico consolidado y reparación local posterior (2026-10-08)

**Base y límite.** Inicio `0cfd7297597d38d6d3dc31d627a927e6545168dc`, árbol limpio; `1570d7d1be0afb813cf94705649017d90f329177` fue la base de la última corrida. El único cambio posterior al primero es el cierre del runner y el presupuesto en `0cfd729`. Evidencia: `tmp/stage2_journey_a/runs/20261008T234453Z-session-2/{manifest.json,trace.json,availability.json,filter.json}` y `tmp/stage2_journey_a/exports/20261008T234658Z/`. La corrida anterior sirve solo de contraste. Esta revisión no ejecuta otro journey, AWS, intérprete, Retrieve ni generación; `PASS_CALL_CAP=0`. El histórico queda en 160 llamadas registradas y US$0,343774, sin consumo atribuible a estas pruebas.

**Matriz del episodio.** Los catorce turnos quedaron en `ep_4e26498ea955c600`. En cada turno la captura muestra un `Retrieve` híbrido, k=8, con el mismo filtro de cuentas 1/3 y corpus general, seguido de `generate_text` directo. No hubo `RetrieveAndGenerate`; los ocho chunks recuperados por turno pasaron la compuerta de acceso, ninguno fue Elemont, y no se publicaron citas. El runner no ejecuta `RagController#attach_manual_suggestion`, por lo que la traza no contiene tarjetas candidatas. `DocumentDiscovery` puede ofrecer la entrada Elemont MH por designador sin escribir identidad ni pin, como comprueba una prueba local independiente. La tabla resume la entrada literal y la salida cruda; el detalle completo de percepciones, consultas, prompts y chunks está en `trace.json`.

| Turno | Entrada del técnico | Percepción / estado tras relectura | Consulta, documentación y respuesta |
| --- | --- | --- | --- |
| 1 | «Elemont MH con placa CEA15; la puerta 1 no termina de cerrar y el imán no magnetiza. ¿Qué reviso?» | `report`; objetivo de cierre e imán, fabricante Elemont de catálogo, identificadores de usuario Elemont MH y CEA15. | Busca la entrada literal; recupera KONE, KOYO, CEA15+ y VF5; guidance sin cuerpos; propone hipótesis condicionales y pregunta por posición del imán. |
| 2 | «El display muestra código 8.» | `report`; añade observación del display; todavía no hay código tipado como hecho. | Consulta con objetivo e identificadores; CEA15+ y manuales ajenos; respuesta atribuye al 8 una posible falta de energía o señal sin manual aplicable. |
| 3 | «La cabina está detenida cerca de planta 1 y no hay personas dentro.» | `report`; guarda ubicación y ocupación juntas. | Consulta incluye ambas; documentación ajena; respuesta conserva el reporte pero vuelve a inferir significado del 8. |
| 4 | «La puerta llega al marco, pero vuelve a abrir.» | `report`; añade reapertura. | Consulta conserva el problema; documentación ajena; respuesta propone retención o bloqueo sin fuente compatible. |
| 5 | «No, leí mal: era código 18, no 8.» | `correct`; código 18 vigente, 8 rechazado, objetivo intacto. | Consulta retira 8 y mantiene síntoma; CEA15+ y manuales ajenos; respuesta reconoce la corrección. |
| 6 | «Ya comprobé visualmente la guía de la puerta; no veo una obstrucción.» | `report`; conserva «no veo una obstrucción». | Consulta incluye código 18 y comprobación; manuales ajenos; respuesta vuelve a atribuirle un significado al código. |
| 7 | «El LED 7 está apagado. ¿Qué indica para esta placa?» | `follow_up`; LED como observación, no identidad. | Consulta contiene LED 7; manuales ajenos; ninguna fuente aplicable define su significado. |
| 8 | «Al pedir cierre se oye un clic, pero no termina de cerrar.» | `report`; guarda un clic, no repetición. | Consulta incluye clic, LED y código; manuales ajenos; respuesta lo atribuye a relé/solenoide y vuelve a interpretar el 18. |
| 9 | «Sigue igual. ¿Y ahora?» | `follow_up`; mismo episodio, sin nueva observación. | Consulta recompone el estado; manuales ajenos; nombra KONE como referencia no aplicada. |
| 10 | «Resúmeme lo que llevamos y dime qué observación segura sigue.» | `meta` crudo, normalizado a `follow_up`; objetivo, código y observaciones persisten. | Consulta técnica recompuesta; resumen útil de lo reportado, seguido de inferencia sobre el clic sin sustento. |
| 11 | «Hice esa revisión: sigue el clic y la puerta no termina de cerrar.» | `follow_up`; añade persistencia del clic y cierre incompleto. | Consulta conserva continuidad; documentación ajena; respuesta afirma comportamiento de circuito sin fuente aplicable. |
| 12 | «Sigue igual.» | `follow_up`; sin hecho nuevo. | Consulta recompone el episodio; respuesta transforma el clic reportado en «clic repetido». |
| 13 | «Corrijo algo de antes: la cabina está detenida cerca de planta 2, no de planta 1.» | `correct`; el intérprete entregó la frase completa. `drop_contained_phrases` descartó la sustitución corta; el reductor retiró planta 1 y dejó solo «no hay personas dentro». | La consulta aún contiene planta 2 por el texto actual; el prompt de estado ya no la contiene. La respuesta la menciona por el turno reciente y añade LED/conector con funciones no documentadas. |
| 14 | «¿Y ahora? No lo sé.» | `answer_pending` crudo, normalizado a `follow_up`; planta 2 sigue ausente del episodio persistido. | Consulta sin planta 2; el prompt la recibe solo desde historial reciente. Respuesta la repite, pero no informa la carencia documental ni prepara escalamiento. |

**Decisión por línea.**

| Línea | Clasificación y evidencia | Decisión |
| --- | --- | --- |
| Continuidad | Defecto determinista solo para la corrección de ubicación: turno 13 pierde planta 2 en `episode_delta`, y la consulta del 14 la omite. Objetivo, Elemont MH, CEA15, código 18 y rechazo de 8 sí persisten. | Reparar la sustitución de observaciones; verificar persistencia, consulta y prompt con la salida cruda capturada. |
| Correcciones | Defecto determinista: el fragmento vigente estaba contenido en la frase cruda con cola retractiva, y la deduplicación eligió esa frase. El reductor quitó correctamente el valor anterior y conservó ocupación. | Eliminar la cola retractiva de esa observación antes de deduplicar; conservar las demás observaciones y la procedencia. Cubrir «no de» y «no del» como formas gramaticales, no como vocabulario del caso. |
| Recuperación | Evidencia insuficiente para un defecto de ranking: disponibilidad devuelve Elemont p. 1/7; catorce búsquedas del episodio no lo incluyen. Acceso autorizado no implica aplicabilidad. El runner no captura sugerencias del controlador. | No cambiar ranking, filtro ni permisos. Proponer captura de candidatos/resolución y una única validación real autorizada. Un candidato no confirma la identidad ni aplica su contenido. |
| Respuestas sin sustento | Incumplimiento del modelo: código 18, LED 7, «clic repetido» y componentes se afirmaron o insinuaron sin chunk aplicable. Los prompts de guidance retiraron cuerpos ajenos y prohibieron significados de códigos y terminales; no hay evidencia de que una respuesta anterior del asistente entrara como hecho en esos prompts. | Mantener bloqueada la etapa. La instrucción del prompt no demuestra cumplimiento; pedir en la validación real una respuesta que diga qué falta y llegue a una observación decisiva o un escalamiento fundado. No derivar una causa física del plano Elemont. |
| Intentos | Defecto determinista de telemetría: `stage2_unbilled_attempts` veía un fallo del intérprete, pero no una respuesta correcta cuya escritura de `BedrockQuery` falló. | Capturar `interpreter_attempt` justo antes de `converse`; reconciliar por correlación contra filas, contando una vez el intento con o sin fila, sin estimar costo. |

**Cambios locales y comprobaciones.** `TurnPerception` conserva la frase sustituta cuando el intérprete entrega también la retractación; `WorkContextReducer` reconoce «no del»; `TurnInterpreter` captura el intento antes de invocar al cliente; el runner lo contabiliza aunque el registro de usage falle. `test/fixtures/files/field_companion/journey_a_interpreter_raw_20261008.json` contiene solo las 14 entradas y salidas crudas del intérprete capturadas; su replay stubbeado comprueba un único episodio hasta el turno 14, relectura, objetivo, identidad, código vigente/rechazado, planta 2, ocupación, LED, clic, consulta y bloque de prompt. Otras pruebas cubren variantes gramaticales, descubrimiento sin pin y conteo con/sin fila. `Rag::DocumentDiscovery` no requiere identidad persistida para ofrecer un designador; la prueba comprueba que la tarjeta no escribe identidad ni pin. Suites focalizadas tras el replay: 137 corridas, 1.189 aserciones, sin fallos. Suite completa anterior al replay, con credenciales AWS ficticias y salida HTTP cerrada: 4.440 corridas, 26.165 aserciones, 3 fallos, 0 errores, 191 skips. Los tres fallos se repitieron aisladamente en una copia sin cambios de `0cfd729`: dos expectativas de cero generaciones en `BedrockRagServiceKnowledgeScopeTest` (líneas 63 y 293) y `owns_query=false` para VF5 en `Rag::FieldJourneyTest` (línea 94). Son preexistentes a esta intervención; no se modificaron sus rutas. RuboCop y `git diff --check` se vuelven a comprobar en el cierre. Ninguna prueba local establece que el modelo acate el prompt o que el Elemont aparezca en el retrieval real. La siguiente pregunta de validación, **sin ejecutar ahora**, es: «¿El episodio completo conserva las correcciones y llega a un siguiente paso sustentado o un escalamiento útil, con el retrieval y el modelo reales?». Será una sola ejecución longitudinal autorizada de Journey A con capturas de estado, recuperación y generación. Hasta entonces: **ETAPA 2 BLOQUEADA; no `EPISODIO_VALIDADO`**.

### 3. Verificar ese alcance en producción

Primera consulta y continuidad del mismo episodio, sobre el journey A ya aceptado en local. Una pasada. Sin sonda previa. Sin L3, sin journey B y sin T-F. Las reparaciones de las etapas 1 y 2 entran por el procedimiento de despliegue vigente.

Resultado: la misma aceptación de la etapa 2 contra el índice de producción, más una reconciliación del costo. Los inciertos que esta pasada no toque siguen inciertos. Los pendientes históricos siguen abiertos.

Parada: la misma de la etapa 2, con el presupuesto de 42 llamadas. Un fallo de producción no se repara en caliente dentro de esta etapa.

Veredicto, sobre la evidencia de las etapas 2 y 3 juntas. El smoke solo no decide. El veredicto no declara habilitado un piloto de consultas libres. Eso queda para después de validar la separación mínima entre casos.

- `EPISODIO_VALIDADO`: la aceptación de la etapa 2 se cumplió en local y en producción para este episodio; la conclusión usó documentación compatible cuando el retrieve la devolvió; ninguna respuesta inventó un valor, terminal, código o procedimiento de fabricante; el gasto quedó dentro del presupuesto. El veredicto nombra lo que sigue abierto: el backlog, la recuperación de un caso anterior, O-P1, el smoke R1B y N1–N6.
- `PENDIENTE`: alguna aceptación quedó inconclusa por transporte, falta de acceso o configuración, registros locales ausentes o incompatibles, búsqueda sin resultados, o presupuesto agotado, sin una falla de producto confirmada. También si el manual es recuperable en la Knowledge Base de producción y el episodio no llegó a usar documentación compatible.
- `BLOQUEADO`: una falla de producto confirmada y no reparada (valor corregido tratado como vigente, pregunta repetida, pérdida de lo comprobado, o documentación compatible ignorada) o una respuesta insegura.

## Backlog posterior

Empieza después del cierre de este alcance. No se ejecuta con la luz verde de este plan. El orden de abajo es la prioridad propuesta. Cada ítem se autoriza como incremento. Adelantar uno es una decisión del fundador. Aquí no se diseña la implementación.

### 1. Cambio explícito de caso dentro de la misma sesión

Objetivo: abrir otro episodio ante un cambio claro, sin contaminación del caso anterior y sin una escritura tardía sobre el episodio que ya cerró.

Reutiliza los dos textos L3 de `test/fixtures/files/field_companion/longitudinal_journeys.yml`, `new_work` y `expected_episode_id`. El caso previo puede ser el episodio de puertas ya corrido. No se abre otro corpus.

Inicio: este alcance está cerrado y el incremento está autorizado.

Aceptación: `new_work` directo, o una aclaración mínima que el técnico responde y que termina en un episodio nuevo. El seguimiento queda en el episodio nuevo y su respuesta no usa la falla de puerta, el código 18, la planta 2 ni la identidad Elemont. Una escritura con el `episode_id` anterior se rechaza.

### 2. Cambio ambiguo

Objetivo: distinguir seguimiento, otro problema del mismo equipo y otro equipo. Aclarar y procesar la consulta original sin exigir que el técnico la repita.

Reutiliza la aclaración de relación entre casos ya presente en la ruta owner. No hay un fixture dedicado. Al autorizarse, las frases salen del mismo equipo de puertas o de L3. No se abre otro corpus en este plan.

Inicio: el ítem 1 está cerrado, o el fundador adelanta este, y el incremento está autorizado.

Aceptación: ante ambigüedad real hay una aclaración mínima. La respuesta del técnico separa o continúa. La consulta original se procesa sin pedirle que la repita. Una aclaración que no produce esa separación o esa continuación no pasa.

### 3. Regreso tras una pausa

Objetivo: dentro de las cuatro horas, comprobar continuidad del mismo episodio y un cambio de caso. Comprobar también qué ocurre al vencer el episodio.

Reutiliza `ConversationSession::EPISODE_WINDOW` (4 horas), el episodio de puertas y el texto L3. El fixture longitudinal trae un reloj fijo. Mover ese reloj se decide al autorizar el incremento, no ahora.

Inicio: los ítems 1 y 2 están cerrados, o el fundador lo adelanta, y el incremento está autorizado.

Aceptación: antes de las cuatro horas el mismo caso conserva los hechos, y un cambio claro abre otro episodio sin contaminación. Al vencer la ventana, ese episodio no sigue tratándose como abierto.

### 4. Journey B completo

Objetivo: adquirir una identidad que al principio se desconoce, buscar con el síntoma antes de completarla e incorporarla cuando llega.

Reutiliza el journey B, turnos 1 a 10, del mismo fixture longitudinal, incluido el payload de foto ya escrito. Esa foto no valida Vision.

Inicio: este alcance está cerrado y el incremento está autorizado. No depende de haber ejecutado el cambio de caso, salvo que el fundador ate las prioridades.

Aceptación: la primera búsqueda puede usar el síntoma. Orona y PBCM-V3 quedan en el episodio cuando el texto los confirma. «Por arriba», corregido a «por debajo», no vuelve como vigente. Una respuesta sin manual compatible no es éxito documental. El payload de foto no se anota como validación de Vision.

### 5. T-F completo

Objetivo: corregir el fabricante y seguir el mismo caso con el intérprete real.

Reutiliza los cuatro textos del técnico en T-F (`test/fixtures/files/field_companion/cases.yml`): la consulta de los resortes, «Fuji Yida», «el modelo no lo sé» y «No, no es Fuji Yida. Es KONE». No se inyectan las preguntas del asistente que trae el fixture. La misma regla de adaptación del journey A sirve cuando un texto presupone una pregunta que Danebo no hizo.

Inicio: este alcance está cerrado y el incremento está autorizado.

Aceptación: el fabricante vigente pasa a ser KONE, el episodio sigue siendo el mismo, el objetivo no cambia y Fuji Yida no vuelve como marca vigente. La traza usa el intérprete real.

### 6. Recuperación de un caso anterior

Objetivo: evaluar si hace falta recuperar un caso ya cerrado dentro de la sesión y, si hace falta, cuál es la solución mínima.

Hoy no hay almacén de episodios anteriores ni una operación de la ruta owner que reabra un caso cerrado. `voice_dictation` no cuenta. No está implementado y este ítem no lo declara implementado. No se diseña aquí una tabla ni un archivo.

Inicio: este alcance está cerrado y el fundador pide esa evaluación. No la dispara el cierre del episodio de puertas.

Aceptación: un juicio de necesidad y, si hace falta, de la solución mínima. Si esa solución pidiera una tabla, varios episodios activos o un archivo, vuelve al fundador antes de construirse. Declarar la recuperación como ya hecha no es un resultado válido.

## Pendientes históricos

Siguen en el inventario y en O-P1. No son los seis escenarios de arriba. Quedar fuera de esta ejecución no los cierra: O-P1, el mapa R2, el smoke de producción R1B, la verificación de producción N1–N6, G5, la presentación, T3, R3, CG-D19, CS-P01 a CS-P03 y F9. A‴ permanece como regresión secundaria, con sus conteos.

## Límites explícitos

- El journey A no trae la causa que el manual debería nombrar. `EPISODIO_VALIDADO` no significa que la puerta quedó reparada ni que la respuesta coincidió con un dictamen guionado.
- La ruta de cero chunks con identidad desconocida se repara en la etapa 1 y se cubre con tests locales. Si el intérprete deja Elemont como identidad conocida, la etapa 2 no recorre esa ruta. No se agrega el journey B para cubrirla.
- Las pruebas locales de separación no sustituyen a L3 con el intérprete real. `EPISODIO_VALIDADO` no habilita un piloto de consultas libres.
- R2 sigue pospuesto y no es el escenario del cambio de caso. Ese escenario, cuando se autorice, reutiliza L3.
- El tope de US$2,50 no mide `Retrieve` ni el embedding. Es un margen sobre US$1,54 de llamadas de modelo.

## Revisión Opus (2026-10-07)

Incorporado entonces, y todavía vigente dentro de este alcance: la identidad puede ser objetivo cuando decide la documentación, la aplicabilidad o el diagnóstico; las aclaraciones sirven también para distinguir causas, interpretar resultados y decidir el paso; la ruta de cero chunks recibe guidance en la etapa 1; el límite de 400 admite un ajuste acotado hasta 600; los textos del técnico se adaptan a la respuesta real y conservan sus hechos; presupuesto con supuestos explícitos; ejecución autónoma tras la luz verde final.

Esta revisión de alcance deja atrás, para el gate y el presupuesto: la aritmética 16 + 10 + 4, las tres pasadas de los tres escenarios, el techo de 360 llamadas y US$5, la comprobación pagada de L3 dentro de la etapa 2, y el veredicto `RECOMENDAR_PILOTO_CONTROLADO`. La separación de casos y la recuperación de un caso anterior siguen sin declararse hechas. La discrepancia de O-P1 sigue sin un lado elegido. Las páginas industriales no se re-descargaron.
