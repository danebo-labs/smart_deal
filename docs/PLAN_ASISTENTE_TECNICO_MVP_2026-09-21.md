# Plan asistente de técnico — Potenciación del MVP (2026-09-21)

> **Para validar, no para ejecutar.** Otro modelo ataca huecos contra el código y
> contra los planes ya medidos. Si un hueco contradice una restricción o el gate,
> no se implementa: se escala como decisión humana numerada. Este archivo no
> autoriza llamadas a Bedrock ni ediciones de `generation.txt`.

**Objetivo:** potenciar el MVP para que el técnico de campo reciba la respuesta de un asistente inteligente. El conocimiento útil sale de la base de conocimiento de manuales estructurados ya ingeridos.

**Qué es este documento.** Una decisión de producto que ordena levers que ya están escritos. No es un ciclo nuevo de ingesta, no es un agente, y no reescribe el contrato de generación. Si la validación descubre que hace falta un lever que estos planes no tienen, se numera como decisión humana y no se cuela en una fase.

**Entrada obligatoria.** Este archivo y solo estos, en este orden:

| Documento | Qué mirar |
|---|---|
| [PRODUCT_ROADMAP.md](PRODUCT_ROADMAP.md) | El loop del MVP, l.37–48. El límite del piloto, l.77–85. La etapa siguiente, que este plan no abre, l.166–187. |
| [PLAN_HILO_CONSULTA_2026-09-21.md](PLAN_HILO_CONSULTA_2026-09-21.md) | F1 implementada en `d81220b`. Holdout, Fase G y Fase S no corridas. La arquitectura de tres capas y el gate de la escalera OTIS. |
| [PLAN_CONTINUIDAD_SESION_FOLLOWUP_2026-09-21.md](PLAN_CONTINUIDAD_SESION_FOLLOWUP_2026-09-21.md) | §9.2, CS-D02. Es la especificación del lever de respuesta. Este plan no la reescribe. |
| `app/prompts/bedrock/generation.txt` | l.123–124, l.133–137 (`# NO MATCH`), l.141, l.145–148. SHA `6a8abaed1e56bc880c7844f75288a7406973b9595c09e7fecafa928a473a789f`. |
| `app/services/bedrock_rag_service.rb` | `filter_generation_prompt` l.1310–1318. Prefijos l.32–34. |
| `app/services/rag/grounded_synthesis_flag.rb` | l.11–12. Default off salvo `ENV == "true"`. |
| `app/services/session_context_builder.rb` | `## Recent Conversation` l.45–59. Tope `MAX_CONTEXT_CHARS` 2000, l.13. |

**Línea base:** commit local `d81220b` (hilo de consulta). El dueño despliega. Imagen anterior de producción `9977c7aa2c215794df0cf99cf2c901d75835c2f5`. Cuenta 3, usuario 7, sesión 6, KB `Y7RZWMFJSR`. `generation.txt` no cambió en `d81220b`.

**Decisiones del dueño incorporadas:**

1. **CS-P01 (Lahiri, 21-sep-2026).** El approach deseado es un asistente de técnico inteligente. El conocimiento útil se apoya en la vasta documentación técnica de manuales estructurados, que ya es la base de conocimiento. Es una decisión de producto para potenciar el MVP. No abre la etapa siguiente del roadmap.
2. **CS-D02, CS-H05, CS-H06, CS-H08.** Siguen vigentes en sus documentos. CS-P01 las ordena; no las reemplaza. CS-H01 (no adivinar el hilo) y la restricción de cero llamadas extra para decidir el hilo siguen cerradas.
3. **CS-P02 (Lahiri, 21-sep-2026).** Se retira, como restricción de producto, la frase «el procedimiento que el manual de este trabajo no trae no se infiere». Se reemplaza por: si ese manual no trae el procedimiento, el asistente puede inferirlo desde el conocimiento ya ingerido, por analogía técnica, y proponer una solución o una guía hacia la solución. La analogía sale de un procedimiento del mismo componente y la misma función que sí está en los chunks de esa búsqueda. Se marca como hipótesis, nombra el manual de origen y lleva descargo visible. No es la instrucción del fabricante para este trabajo. Cotas, torques y pasos de seguridad que esos chunks no traen no se completan. Sigue siendo la misma llamada de generación: no hay una segunda llamada para «pensar» la analogía.
4. **CS-P03 (Lahiri, 21-sep-2026), a considerar. No es fase de este archivo.** Lo que hace inteligente al producto, además de los manuales ya ingeridos, es que un diagnóstico de campo pase a conocimiento de la organización y la consulta siguiente pueda usarlo. El non-goal vigente dice «automatic conversion of a diagnosis into organizational knowledge» (PRODUCT_ROADMAP l.256). CS-P03 no levanta la palabra automática. Un diagnóstico sin revisión no se indexa, no se vuelve `KbDocument` y no se escribe bajo `bulk_chunks/`. El registro de diagnóstico sigue siendo evidencia operativa, separada de la base (l.185–187). La promoción a conocimiento exige el flujo revisado que esa misma línea ya pide, y una fuente técnica distinta de la nota interna antes de indexarla como aplicable (l.83–85). El piloto, hoy, no tiene ese técnico (l.79–81). Este plan no construye ese flujo y no adelanta la etapa de l.166–187. Si la validación lo mete en la Fase R, el plan se detiene: es otra decisión, con ingesta.

Traducción operativa de CS-P01 y CS-P02, para que la validación no la convierta en un agente:

1. La búsqueda recibe el hilo de la consulta. Eso ya está en `Rag::EpisodeThreadResolver` (`d81220b`). Una sola consulta recuperable se une. Dos o tres se preguntan. Cero no se toca.
2. La respuesta usa los chunks de esa búsqueda. Si el manual de este equipo trae el dato o el procedimiento, se cita como hecho. Si no lo trae, propone una solución o una guía por analogía técnica desde un procedimiento parecido de esos mismos chunks, del mismo componente y la misma función. Nombra de qué manual sale, lleva descargo visible, e incluye los aspectos de seguridad que esos chunks ya traen.
3. Una sola pregunta al técnico, al final, solo si un dato concreto cambiaría la respuesta.
4. La analogía no se presenta como el procedimiento del fabricante para este trabajo.

Eso es el producto de este plan. Infiere desde los manuales. No completa lo que los manuales no apoyan. No es un router de intención. No es una segunda llamada al modelo para reescribir la consulta ni para armar la analogía. La inteligencia que crece con el uso es CS-P03: queda nombrada y queda fuera de estas fases.

## Qué potencia el MVP y qué deja quieto

El loop vigente está en PRODUCT_ROADMAP l.40–48. CS-P01 cambia solo la calidad de la respuesta de ese loop.

| Paso del MVP | Con CS-P01 | Qué no cambia |
|---|---|---|
| El técnico pregunta o manda una foto | Igual | La foto no es `KbDocument` ni fuente de la KB |
| Una respuesta concisa, con la incertidumbre visible | La respuesta se comporta como asistente: distingue hecho citado de guía inferida | Sigue siendo una respuesta, no un informe ni un registro de diagnóstico |
| Los manuales indexados son la fuente | Es el conocimiento de arranque | No se reingesta ni se amplía el corpus en este plan. CS-P03, el diagnóstico revisado que pasa a conocimiento de la organización, no entra en estas fases |
| Trazabilidad de la consulta | Igual | Sin tabla nueva y sin columna nueva |
| Resumen determinista de un pin | Igual | El gate de selección de documento sigue ganando al menú del hilo |

La etapa «persistent conversations and diagnostic records» (l.166–187) sigue esperando demanda del piloto. CS-P01 no la adelanta.

## Restricciones no negociables

1. Esta sesión de validación no edita código, no edita `generation.txt`, y no llama a Bedrock.
2. No reescribir §9.2 ni la Fase G del plan de hilo. El texto del lever de respuesta es el de esos dos documentos. Este plan solo dice cuándo se abre.
3. No hay una segunda llamada a Bedrock para decidir el hilo, ni para «pensar» la respuesta, ni para clasificar la intención. Si la validación concluye que el asistente la necesita, es una decisión humana nueva y este plan se detiene.
4. No hay lever de ingesta. No reingestar. No escribir bajo `bulk_chunks/`.
5. Cuando una sesión futura ejecute la respuesta, el lever es únicamente líneas `- GROUNDED_SYNTHESIS:` de `generation.txt`. `filter_generation_prompt` (l.1310–1318) tira esas líneas si gs-v1 está apagado, y tira las `- STRICT_ONLY:` si está prendido. Una línea sin prefijo cambia los dos contratos. `# NO MATCH` (l.133–137) no se edita.
6. Temperatura, `top_k`, flags de retrieval y el interruptor de gs-v1 no son levers de este documento. Confirmar el valor de `RAG_GROUNDED_SYNTHESIS_ENABLED` en el contenedor es una lectura. No se cambia en la validación.
7. El amarre de cinco cables con varilla sigue sin receta validada (PRODUCT_ROADMAP l.77–85). CS-P02 permite proponer ahí una guía por analogía, con las mismas condiciones: mismo componente y función, bloque de hipótesis, manual de origen y descargo. Sin esas premisas en los chunks no hay analogía, y el hueco queda declarado. La guía no se presenta como la receta validada de ese amarre.
8. Canal web. WhatsApp sigue dormido. La voz no entra en este plan: el roadmap ya la separó como interfaz, y no es lo que CS-P01 decide.
9. El holdout del hilo es puerta de este producto. Si la búsqueda pierde el hilo y la escalera OTIS aparece como el ajuste de la fijación, no se despliega la voz de asistente para disculpar esa búsqueda. No se improvisa ahí el lever de §9.2.
10. Una fase de código por sesión. La validación de este archivo es cero Retrieve y cero `retrieve_and_generate`.
11. Mobile primero. La unión gana al menú. Este plan no agrega pantalla.
12. La Fase S del plan de hilo (unificar las cuatro definiciones de episodio) no está autorizada. No es necesaria para la promesa de CS-P01.
13. El presupuesto de la sesión que ejecute la respuesta lo fija quien la abra. Este documento le deja el cupo en cero.

## Hallazgos de arranque

Leídos el 21-sep-2026 contra el código y los planes citados. No son una Fase 0 nueva.

| # | Hallazgo | Evidencia |
|---|---|---|
| P1 | La base de conocimiento del piloto ya existe. CS-P01 no pide otra. | Corpus Gonzalo ingerido en la cuenta 3. PRODUCT_ROADMAP l.43. §9.2 dice que la ingesta ya es la base y no se mide de nuevo. |
| P2 | «Saber de qué consulta habla el técnico» ya está resuelto en la búsqueda, sin un modelo extra. | `Rag::EpisodeThreadResolver`, commit `d81220b`. En el episodio real medido corresponde unir, 114 caracteres, y no abrir menú. |
| P3 | El modelo de generación ya ve el episodio. Lo que no veía el hilo era la recuperación. | `SessionContextBuilder` l.45–59, tope l.13. Plan de hilo, V20. |
| P4 | El contrato de respuesta todavía prohíbe la guía que CS-P01 quiere cuando el manual no trae el procedimiento. | `generation.txt` l.141, línea `- GROUNDED_SYNTHESIS:`: «no values, turns, torques, sequences, or prescribed intervention». l.123–124 exige que los pasos estén documentados para el equipo nombrado. |
| P5 | Dos piezas del asistente ya están en el prompt y no hay que reinventarlas. | l.145–146: la nota de seguridad sale de la evidencia, sin cierre genérico. l.148: una sola pregunta, al final, solo si cambiaría la respuesta. |
| P6 | El fallo de producto del episodio real es de búsqueda, no de tono. | `si, me refiero a resoretes de tension` se buscó sola. La única cita fue Otis Escalator 506 NCE, p. 51, cota 102 mm y seis pasos, presentados junto al ajuste de la fijación. Plan de hilo, H3. El holdout de ese plan es el gate. |
| P7 | El lever de la voz de asistente ya está especificado. | CS-D02 en §9.2. La Fase G del plan de hilo lo afina: el delta nuevo es la analogía con descargo; l.145–148 ya cubren seguridad y la pregunta única. La colisión con l.141 queda explícita y sin resolver en código. |
| P8 | gs-v1 no está prendido por el default del código. D18 lo declaró live. Las dos frases pueden ser ciertas a la vez: el default es off y el contenedor puede tener el ENV. | `grounded_synthesis_flag.rb` l.11–12. Sin confirmar el ENV, un lever solo de líneas `GROUNDED_SYNTHESIS` no se ve en el piloto. |
| P9 | El backlog de generación (rótulo que no se emite, más de una pregunta, citas apiladas) no es esta decisión. | [BACKLOG_CONTRATO_GENERACION_GS_V1_2026-09-18.md](BACKLOG_CONTRATO_GENERACION_GS_V1_2026-09-18.md), ítems 1–6. |
| P10 | Persistencia de conversaciones, registro de diagnóstico y voz son otra etapa. | PRODUCT_ROADMAP l.166–187 y l.106–120. |
| P11 | Convertir un diagnóstico en conocimiento de la organización es lo que el dueño señala como inteligencia que crece. El roadmap prohíbe hacerlo automático y lo separa de la base hasta un flujo revisado. | Non-goal l.256. Separación l.185–187. Nota interna l.83–85. Sin técnico de campo designado, l.79–81. |

## Colisión que la validación mira y no implementa

l.141 prohíbe una secuencia prescrita dentro de `Interpretación técnica:`. CS-P02 decide lo contrario como producto: esa prohibición se reemplaza por la analogía técnica que propone una solución o una guía, marcada como hipótesis. Sigue siendo el cambio de mayor riesgo de seguridad del ciclo de respuesta.

Este documento no edita el prompt. La sesión de la Fase R reemplaza esa prohibición solo en líneas `- GROUNDED_SYNTHESIS:`, con su propio holdout. El gate de esa sesión, ya escrito en §9.2 y en la Fase G, incluye: la escalera OTIS no se copia como el ajuste de la fijación; cable viajero, CB2/CB3 o puerta no se presentan como el ajuste de los resortes; la analogía no se presenta como instrucción del fabricante; cotas, torques y pasos de seguridad que los chunks no traen no se completan.

## Fases

### Fase V — Validación de este documento

La hace el otro modelo. Cero código. Cero Bedrock. Confirma o corrige P1–P10 contra archivo y línea. Agrega filas `V1+` solo cuando un hallazgo obliga a cambiar una restricción, el gate o el orden de las fases. No abre la Fase R.

Lectura obligatoria de esa sesión, sin cambiarla: el valor de `RAG_GROUNDED_SYNTHESIS_ENABLED` en el contenedor de producción. Si no se puede leer, la fila queda abierta y la Fase R no arranca, porque P8 dice que el lever puede ser invisible.

### Fase H — Holdout del hilo

Ya está especificada en la Fase 2 del plan de hilo. Este documento no la reescribe. Máximo 2 `retrieve_and_generate`, sobre el candidato, no en el contenedor de producción. Gate independiente: la respuesta de la fijación de cables no copia la cota 102 mm ni los seis pasos de la escalera OTIS 506 NCE como el ajuste a ejecutar. Si eso falla, la Fase R no se abre.

### Fase R — Respuesta del asistente

Otra sesión, solo con la Fase H en verde y con P8 cerrado. Ejecuta §9.2 tal como lo afina la Fase G del plan de hilo. No redacta un prompt nuevo en este archivo. Entregables de esa sesión, ya exigidos por CS-D02: las líneas `- GROUNDED_SYNTHESIS:`, y la distinción entre procedimiento documentado e hipótesis de campo en PRODUCT_ROADMAP y en AGENTS. Cupo de llamadas: cero hasta que quien abra la sesión lo fije. Holdout propio, de una sesión que no escribió el prompt.

### Fase D — Checkpoint del MVP potenciado

Solo con H y R en verde. No es una fase de código. El episodio real del 21-sep (aclaración de resortes de tensión sobre Synergy) tiene que mostrar, en el candidato: consulta unida, el procedimiento citado si el manual lo trae, y —si el manual no lo trae— una guía marcada como hipótesis, con el manual de origen y el descargo. La escalera OTIS no es la instrucción del trabajo. Si eso no se cumple, no se improvisa otro lever: se vuelve a la fase que falló.

## Qué refutaría CS-P01

- Que una respuesta útil exija una segunda llamada al modelo. CS-P01 dice que no. Si la evidencia lo pide, el plan se detiene y la decisión es humana.
- Que, con el hilo ya unido, los chunks no traigan un procedimiento del mismo componente y la misma función desde el cual inferir la analogía. Entonces el hueco queda declarado. Completar la solución sin esas premisas, o presentar la analogía como el procedimiento del fabricante, refuta la ejecución de CS-P02. La generación no tapa una búsqueda que perdió el hilo.
- Que el técnico necesite historial persistente o voz antes de poder usar la respuesta. Eso es la etapa siguiente del roadmap, no esta potenciación.
- Que una respuesta útil de este ciclo exija indexar el diagnóstico como conocimiento. Eso es CS-P03. No se cuela en la Fase R.

## Presupuesto del ciclo

| Fase | Retrieve | retrieve_and_generate |
|---|---|---|
| V | 0 | 0 |
| H | 0 | máximo 2, según el plan de hilo |
| R | 0 hasta autorización de quien abra la sesión | 0 hasta esa autorización |
| D | 0 si reutiliza el artefacto del holdout | 0 si reutiliza el artefacto del holdout |

## Estado

| Fase | Estado | Artefacto / hash |
|---|---|---|
| Decisión | **Registrada 21-sep-2026.** CS-P01. Sin validar por otro modelo. | Este archivo. |
| V | No empezada. | — |
| H | No empezada. Especificada en el plan de hilo, Fase 2. | — |
| R | No empezada. Bloqueada a H en verde y a P8 cerrado. Especificada en §9.2 y en la Fase G. | `generation.txt` SHA `6a8abaed…` |
| D | No empezada. | — |

## Protocolo de plan vivo

1. Actualiza tu fila de Estado.
2. Corrige fases posteriores afectadas por tus hallazgos.
3. Actualiza el prompt de la fase siguiente. Si cambia la implementación, márcalo con `⚠️ CRÍTICO:`.
4. Si un hallazgo contradice una restricción o el gate: no se ejecuta. Se escala como decisión humana numerada.

## Anexo A — Prompt para el modelo que valida

**Pie común:** restricciones 1–13. CS-P01, CS-P02 y CS-P03. Cero Bedrock. Cero ediciones. No reescribas §9.2 ni la Fase G. No abras la Fase R. CS-P03 no se implementa en este archivo.

> Lee `docs/PLAN_ASISTENTE_TECNICO_MVP_2026-09-21.md` y solo los archivos que cita. No implementes. No llames Bedrock. No edites `generation.txt`. Ataca huecos: ¿CS-P01 mete un lever que §9.2 y la Fase G no tienen, o se olvida de uno que el asistente necesita para la promesa? ¿P8 está confirmado en el contenedor o sigue abierto? ¿El orden H antes que R es el correcto, o el holdout del hilo no alcanza para proteger el gate de la escalera OTIS? Si encontrás un hueco, agregá una fila `V1+` con archivo y línea, y decí qué restricción o gate obliga a cambiar. Si no contradice nada, dejá la Fase V cerrada y no arranques la Fase R.

## Qué NO está en este plan

- Una segunda llamada al modelo, un router de intención, un reescritor con LLM o un clasificador.
- Reingestar, ampliar el corpus, o escribir bajo `bulk_chunks/`. La conversión automática de un diagnóstico en conocimiento de la organización sigue fuera. CS-P03 nombra la versión revisada y no la construye.
- Reescribir §9.2 o la Fase G. Este plan los cita.
- Ejecutar los ítems 1–6 del backlog de generación. Solo vuelven si un holdout muestra que bloquean el gate, y como decisión nueva.
- Presentar la analogía como el procedimiento del fabricante para este trabajo, o como la receta validada del amarre de cinco cables. CS-P02 sí autoriza la guía inferida, con descargo.
- Voz, WhatsApp, bandeja de conversaciones, registro de diagnóstico, o unificar las cuatro definiciones de episodio.
- Prender o apagar `RAG_GROUNDED_SYNTHESIS_ENABLED` durante la validación.
- Cambiar temperatura, `top_k`, `# NO MATCH`, o una línea de `generation.txt` sin el prefijo `- GROUNDED_SYNTHESIS:`.
