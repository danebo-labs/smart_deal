# Field Companion: conversación técnica real

**Estado: PENDIENTE DE VALIDACIÓN FINAL DEL FUNDADOR — ALCANCE: UN EPISODIO COMPLETO.** La revisión Opus del 2026-10-07 sobre `7076f05` sigue incorporada. Esta revisión acota la ejecución. No la deja lista para piloto.

Este documento es el único plan vigente del companion. Una revisión documental no autoriza a empezar. Este cambio no implementa producto, no llama a Bedrock y no despliega.

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

`config/document_identities.yml` no contiene el LD-16. Sí contiene el Elemont MH (`Montacargas 2N Temporizado`) y otros documentos de puerta (E-Shine YS-K01, variador Thyssen MCP7, puertas KES). Esos otros documentos no se enseñan como procedimiento del Elemont. La validación reutiliza el journey A de puertas del Elemont, turnos 1 a 14, sin L3. No se agregan turnos, no se inyectan cuerpos de chunk y no se inventan códigos. Antes de la etapa 2 se comprueba que el manual del Elemont MH esté en el índice del entorno. Si no está, esa ejecución se detiene en `RETRIEVAL_EMPTY` y no se sustituye por el LD-16.

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
- Continuidad útil con retrieval vacío. Cero chunks con identidad desconocida: en lugar del texto fijo, usar el mismo guidance de identidad desconocida que ya existe para la ruta con chunks, con cero manuales y las líneas del problema. La respuesta dice que la búsqueda no devolvió documentación (no que el manual no exista) y ofrece una aclaración que permita una búsqueda mejor o una orientación general de Danebo identificada como tal, sin procedimiento, valores ni terminales de fabricante. Con pin, conserva el aviso de que el foco no devolvió evidencia y no suelta el pin (FC-D17). Es una generación en una ruta que hoy no genera; no agrega retrieve, porque `retry_open` ya hizo el segundo. Si la generación falla, se conserva el mensaje actual de reintento. Un test cubre la ruta con y sin pin.
- Preguntas rutinarias. No agregar la pregunta de controlador cuando el turno ya trae síntoma y un token de equipo (fabricante, modelo, controlador o identificador) y la búsqueda puede seguir. Conservar la aclaración cuando distingue documentos o permite avanzar. El fallback de un episodio vacío no pregunta el controlador antes de poder buscar el síntoma.
- Sesgos del guidance. Quitar el menú fijo de ocupación, posición, puertas, display y sonido cuando la consulta ya trae síntoma o una pregunta que se puede buscar. La comprobación que se pida debe distinguir causas, interpretar un resultado o decidir el siguiente paso de esta consulta. No sustituir el menú por «pregunta siempre la identidad». Identidad como objetivo del turno: además de la petición explícita, cuando una señal determinista ya presente en el turno muestra que la identidad decide la documentación o la aplicabilidad. Ejemplos: manuales recuperados o retenidos de equipos distintos, un manual cuya aplicabilidad depende del modelo, o un código cuyo significado depende del equipo. `ADVANCE_FAULT` deja de afirmar que la identidad no es el objetivo; dice que no se pregunta por rutina. Sin llamada nueva.
- Correcciones de observaciones. Distinguir en el prompt y en `adjust_move` la corrección de identidad o código de la corrección de una observación. La segunda no se convierte en `unclear` ni se vacía.

Siguen siendo parte de esta etapa, y tienen que pasar, las pruebas locales ya existentes de corrección de identidad, de corrección de código y de separación de episodio (`new_work`, `expected_episode_id`). Acotar la aceptación no autoriza borrarlas, saltarlas ni debilitarlas. No se vuelven a pagar contra Bedrock.

Resultado: los tests de las reparaciones y esas pruebas locales pasan. No hay llamada de modelo.

Parada: si la reparación exige una llamada adicional en un turno que ya genera, una tabla nueva o subir `MAX_PROBLEM_CHARS` por encima de 600, se detiene y vuelve al plan. La generación de la ruta de cero chunks, que hoy no genera, es la excepción ya escrita arriba.

### 2. Validar un episodio real

Journey A de puertas, turnos 1 a 14, sin L3. Intérprete, sesión, retrieval y generación, en la base local, con el índice real. No se crea otro corpus.

El manual del Elemont MH tiene que estar en el índice antes de empezar. Si no está, parada en `RETRIEVAL_EMPTY`. No se sustituye por el LD-16 y no se aprueba el episodio con orientación general.

Los textos del técnico son los del fixture. Los hechos de cada turno son fijos: código 8 y después 18, planta 1 y después 2, la guía sin obstrucción, el LED 7 apagado y el clic al pedir cierre. La redacción se adapta a la respuesta real anterior cuando el texto presupone algo que Danebo no dijo. A3 responde a una pregunta sobre ocupación o posición. A11 dice «esa revisión». Si Danebo no lo preguntó o no lo mostró, el turno entrega el mismo hecho como dato espontáneo, o se refiere a la comprobación que Danebo sí mostró. Si Danebo pregunta algo que el caso responde, el técnico responde con el hecho del fixture. Si el caso no lo sabe, responde «no lo sé». La traza guarda el texto original y el enviado. Un turno adaptado no es un turno nuevo ni otro escenario.

Catorce intercambios con respuesta del asistente son 28 mensajes. El recorte empieza en el turno 11. La corrección de planta (turno 13) y la conclusión (turno 14) quedan después. No se agregan turnos para llegar a 20. El turno 12, «Sigue igual», ya está entre el recorte y la corrección de planta y se mantiene. Si en una corrida Danebo ya cerró y los turnos que faltan no traen un hecho nuevo, no se redactan turnos adicionales. En este fixture la corrección de código, la comprobación de la guía y la corrección de planta son hechos nuevos y se entregan antes de cerrar. Si una corrida se cerrara antes del turno 11 sin esos hechos, no habría demostrado el recorte: se anota y no se alarga.

Límite del fixture, y ajuste mínimo ya hecho en este texto: `longitudinal_journeys.yml` no define el significado del código 18, del LED 7, de las plantas, de la guía ni del clic, y no trae un diagnóstico esperado del fabricante. No se inventa ese diagnóstico ni se abre otro corpus. El punto de conclusión es el turno 14, «¿Y ahora?», con los hechos vigentes después del recorte. La utilidad se juzga por las tres salidas, no por coincidir con una causa guionada.

Cada turno anota la decisión, si buscó, si el chunk es compatible con el equipo, si la respuesta usa ese chunk o se declara orientación de Danebo, y si conserva o descarta lo ya comprobado. `RETRIEVAL_EMPTY` no se anota como «el manual no existe». Una respuesta general sin documento compatible no se anota como éxito documental.

Se repara solo la falla observada y se repite solo lo necesario. Como máximo dos repeticiones, siempre dentro del presupuesto de la etapa. Una repetición no es un pretexto para completar un cupo ni para agregar turnos.

Parada: error de transporte en el primer turno; el manual del Elemont no está en el índice; la misma falla vuelve después de una reparación; la reparación pide una tabla, un segundo modelo, L3 u otro escenario; se agota el presupuesto de la etapa.

Aceptación:

- En el primer turno se busca sin pedir fabricante, modelo ni controlador.
- Utilidad y avance, en el turno 14: una respuesta sustentada, una siguiente acción verificable o un escalamiento fundamentado. La respuesta usa lo ya comprobado. No repite una comprobación descartada ni trata como vigente el código 8 o la planta 1. No se exige que la puerta quede reparada.
- Memoria: después del recorte siguen el equipo, el problema, las correcciones y las comprobaciones relevantes nombradas arriba.
- Documentación: si el retrieve devuelve un chunk compatible, la conclusión lo usa y cita documento y página. Si no lo devuelve, la respuesta no inventa valores, terminales, códigos ni un procedimiento de fabricante. Eso no es éxito documental. Con el manual en el índice, un episodio que nunca usa documentación compatible no llega a `EPISODIO_VALIDADO`.
- Una pregunta repetida, un valor ya corregido tratado como vigente o una pregunta de identidad sin función documental ni diagnóstica es fallo. Timeout, throttle o error de transporte es inconcluso, no un fallback de producto.

### 3. Verificar ese alcance en producción

Primera consulta y continuidad del mismo episodio, sobre el journey A ya aceptado en local. Una pasada. Sin sonda previa. Sin L3, sin journey B y sin T-F. Las reparaciones de las etapas 1 y 2 entran por el procedimiento de despliegue vigente.

Resultado: la misma aceptación de la etapa 2 contra el índice de producción, más una reconciliación del costo. Los inciertos que esta pasada no toque siguen inciertos. Los pendientes históricos siguen abiertos.

Parada: la misma de la etapa 2, con el presupuesto de 42 llamadas. Un fallo de producción no se repara en caliente dentro de esta etapa.

Veredicto, sobre la evidencia de las etapas 2 y 3 juntas. El smoke solo no decide. El veredicto no declara habilitado un piloto de consultas libres. Eso queda para después de validar la separación mínima entre casos.

- `EPISODIO_VALIDADO`: la aceptación de la etapa 2 se cumplió en local y en producción para este episodio; la conclusión usó documentación compatible cuando el retrieve la devolvió; ninguna respuesta inventó un valor, terminal, código o procedimiento de fabricante; el gasto quedó dentro del presupuesto. El veredicto nombra lo que sigue abierto: el backlog, la recuperación de un caso anterior, O-P1, el smoke R1B y N1–N6.
- `PENDIENTE`: alguna aceptación quedó inconclusa por transporte, índice vacío o presupuesto agotado, sin una falla de producto confirmada. También si el manual está en el índice y el episodio no llegó a usar documentación compatible.
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
