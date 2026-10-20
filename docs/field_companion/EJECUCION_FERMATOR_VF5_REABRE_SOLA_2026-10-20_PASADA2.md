# Ejecución Fermator VF5+, pasada 2, 2026-10-20

Segunda pasada de la matriz de [CASO_FERMATOR_VF5_REABRE_SOLA_2026-10-19.md](CASO_FERMATOR_VF5_REABRE_SOLA_2026-10-19.md). No reescribe [EJECUCION_FERMATOR_VF5_REABRE_SOLA_2026-10-20.md](EJECUCION_FERMATOR_VF5_REABRE_SOLA_2026-10-20.md). No es aceptación textual. No declara `EPISODIO_VALIDADO`.

## Resultado provisional

No candidato. Una sesión, un episodio y el foco del VF5+ se conservaron. El flag documental estaba encendido: hubo Retrieve y generación en los siete turnos y en la republicación del clic. Ninguna respuesta citó las tres comprobaciones de 8.2. El primer fallo está en el turno 1 y se repite: la generación publicada declara causas sin un pasaje del manual.

La corrección del LED sí quedó en el episodio. La respuesta del turno 4 igual rechaza el turno porque lee el LED encendido como detección en el campo óptico.

## Continuidad

| Dato | Valor |
|---|---|
| Sesión | 198, cuenta 1 `index-account-1`, usuario 27 |
| Episodio anterior | `ep_f69a3833934c3a08`, conservado en la copia |
| Episodio de esta pasada | `ep_6c39a8887dc07569`, abierto `2026-10-20T10:35:13-03:00` |
| Copia previa | `tmp/field_companion/clean_starts/20261020T133513Z_aa8e8901_session_198.json` |
| Resumen previo | `tmp/field_companion/vf5_20261020_pass2/session_198_before_clean.json` |
| Captura | `tmp/field_companion/validation_captures/vf5-reabre-20261020T1328Z/` |
| Foco tras el clic | documento 122, `s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf`, nombre VF5 |
| UID pulsado | `126cda62-64ad-4469-8674-a29f12e38d48` |
| Proceso web | Puma 90271, sin reinicio durante la pasada |
| Partida Git | `700e60e1d70bb15d320f60a31affe56efcc196b5` |

El episodio, el foco y la sesión no cambiaron entre el turno 1 y el turno 7. Al cierre, las observaciones vigentes eran el síntoma, «no observo una obstrucción mecánica», «el LED de fotocélula está encendido» y «SW4 está en OFF, modo esclavo». El LED apagado no quedó como observación vigente. El fabricante siguió en Fermator y los identificadores en Fermator VF5+ y operador de puerta.

## Configuración efectiva del proceso web

Leída en el proceso Puma antes del primer mensaje, sin volcar el resto del entorno:

- `DOCUMENT_IDENTITY_SCOPE_ENABLED=true`
- `BEDROCK_KNOWLEDGE_BASE_ID=Y7RZWMFJSR`
- `KNOWLEDGE_BASE_S3_BUCKET=multimodal-source-destination`
- `DEV_TUNNEL_FALLBACK_ACCOUNT_SLUG=index-account-1`
- `SHARED_SESSION_ENABLED=false`
- `FIELD_COMPANION_EPISODE_ENABLED=true`
- `FIELD_COMPANION_TURN_ENABLED=true`
- `RAG_EPISODE_SCOPE_ENABLED=true`
- `HAIKU_QUERY_ANALYSIS_MODE=owner`
- `AWS_MAX_ATTEMPTS=1`
- `RAG_LOCAL_PASS_GUARD=1`
- `RAG_LOCAL_PASS_CALL_CAP=24`
- `RAG_LOCAL_PASS_COST_CAP_USD=1`
- `RAG_VALIDATION_CAPTURE_RUN=vf5-reabre-20261020T1328Z`

Arranque: `tail -f /dev/null | bin/dev -e /dev/null`. No se modificó `Procfile.dev` ni `.env`. Host `http://index.localhost:3000`. Bases locales: `smart_deal_development`, `smart_deal_development_cache`, `smart_deal_development_queue`, `smart_deal_development_cable`.

Con el flag apagado, la ruta de la pasada 1 cierra en `scope_disabled` antes del Retrieve de generación. Esa abstención no acredita fragmentos recuperados ni un dato ausente. Esta pasada no está en esa condición.

## Juicio

| Paso | Episodio y foco | Recuperación | Respuesta | Juicio |
|---|---|---|---|---|
| 1 | `ep_6c39a8887dc07569`, foco vacío. Tarjeta del uid, sin «Manual enfocado» todavía | Sin pin. Página 12 del VF5 y también CEA15P, CEA51 y Monarch. Política `no_compatible`. Citas 0 | Declara tres causas probables | Rechazado |
| Clic | Mismo episodio. Estado «Manual enfocado». Mismo uid | Pin del VF5.pdf. Páginas 12, 13 y 8. Cuerpos sustituidos. Citas 0 | Republica causas | Foco aceptable. Republicación rechazada |
| 2 | Mismo episodio y mismo foco | Pin. Página 12 contiene las tres comprobaciones de 8.2. Cuerpo sustituido. Citas 0 | No enumera las tres. Inventa terminal y corrosión | Rechazado |
| 3 | Guarda LED apagado y la observación de obstrucción | Pin. Páginas 12, 13 y 5. Citas 0 | Trata la obstrucción como «no presente» e inventa falta de alimentación | Rechazado |
| 4 | Sustituye el LED: vigente encendido; apagado retirado; obstrucción, síntoma, equipo y foco conservados | Pin. Citas 0 | Dice que el LED encendido detecta algo en el campo óptico | Estado corregido. Respuesta rechazada |
| 5 | LED encendido se conserva. No guarda posición de SW4 | Pin. Entra la página 5 y no se cita | No distingue máster y esclavo según la sección 4. Manda limpiar lentes | Rechazado |
| 6 | Guarda SW4 OFF, modo esclavo. LED encendido se conserva | Pin. Página 5 otra vez sin cita | No ordena cambiar el VF. Ordena desconectar la fotocélula. No explica el esclavo de la sección 4 | Rechazado |
| 7 | Mismo episodio y mismo foco. LED encendido y SW4 OFF siguen | Pin. Citas 0 | Dice que no hay registro de la corrección. Trata la obstrucción como ausencia | Rechazado |

Los cuatro criterios decisivos fallan en el respaldo documental, en el límite de la obstrucción y en SW4. La continuidad de episodio y foco se cumple. El LED vigente del episodio, desde el turno 4, está encendido.

## Primer fallo y causa

El primer texto rechazado es la respuesta del turno 1, correlación `query:06e92a0a-4904-42db-95db-dfbf1a2a2a15`. Publica como causas más probables un sensor de obstáculo, un contacto de seguridad mecánico y una falla de la lógica de control. No hay cita.

La misma clasificación explica los turnos siguientes. En el turno 2, correlación `query:a88c29bb-5b2e-4a87-bf66-bd3c2cdcaa10`, el Retrieve usó `Y7RZWMFJSR` y el filtro del pin:

`x-amz-bedrock-kb-source-uri` o `original_source_uri` iguales a `s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf`.

El primer fragmento es la página 12, documento VF5, y su texto recuperado empieza por «8.2 Funcionamiento normal» y las tres comprobaciones. `retrieval_policy` quedó en `no_compatible`, con `reason` vacío. Las tres filas quedaron `reference_only` / `other_equipment` y `body_replaced`. `generation_mode` fue `document_identity_scope`. Las citas publicadas fueron 0. El prompt de generación dice que no hay procedimiento compatible y nombra VF5 solo como referencia, sin enseñar el cuerpo.

`pilot_events` de `document_identity_scope` registró, en los ocho llamados de esta pasada, agujas `Fermator`, `Fermator VF5+` y `operador de puerta`, sin modelo, sin conflicto, `results_count` mayor que cero y `contexts_delivered` 0.

La repetición local, sin modelo, usa esas agujas, el pin y un chunk con `canonical_name` `VF5`, `original_source_uri` del PDF y `location_uri` del chunk. La membresía del foco es `:in`. `identity_matches?` es falso. `VF5` cumple `CHUNK_DESIGNATOR_PATTERN`. `DocumentIdentityScope.apply` devuelve `:no_compatible` y sustituye el cuerpo por «Manual: VF5». El mismo chunk con `canonical_name` `Fermator VF5`, que es el nombre del doble de `document_identity_scope_test`, queda `:compatible` y conserva el texto de 8.2. El doble no reproduce el nombre que devolvió la KB.

No es el cierre `scope_disabled` de la pasada 1. Los fragmentos se recuperaron. El dato de 8.2 estaba en el fragmento de la página 12. No entró a la generación.

## Corrección del LED

La pasada 1, `query:82df46a4-8104-4038-8f58-7c22a17a6099`, dejó esta salida del intérprete: movimiento `correct`, una aserción «el LED de fotocélula está encendido» y observaciones vacías. La gramática `TAIL` exigía una palabra de función después de `no`, así que «, no apagado» no activaba la corrección. La percepción bajaba `correct` a `unclear` / `correction_target` y la respuesta preguntaba qué dato corregir. El reducer no veía una corrección activa.

El arreglo no nombra esta frase ni este LED. Con una señal explícita (`Corrijo`, `Me equivoqué`, y las equivalentes ya del contrato) y un estado de una sola palabra cerrado por puntuación o por el fin, la corrección queda activa. Un contraste de varias palabras, como «no Tablero norte», sigue en la ruta de identificadores. Sin la señal, el contraste breve no retracta. Si varias observaciones guardadas coinciden y el reemplazo no nombra una sola, se pide aclaración. Una observación no se reinterpreta como identidad del equipo.

En esta pasada el intérprete repitió la misma forma, correlación `query:92a3842d-f961-4acd-9265-69ad4b2d3009`: movimiento `correct`, aserción «el LED de fotocélula está encendido», observaciones vacías, sin aclaración. El ajuste aplicado fue `recover_stated_correction` / `observation_correction`. El episodio pasó a LED encendido y retiró el apagado. Esa parte del turno 4 cumple. La respuesta publicada no: atribuye al LED encendido una detección en el campo óptico, y el cuerpo del manual no estaba en el prompt.

## Consumo

Quince invocaciones en el proceso web, todas con `token_source=provider_usage`. Siete `semantic_analysis` y ocho `query` (siete turnos más la republicación). El clic de foco no llamó al modelo. No hubo reintento ni bloqueo. `partial_estimate_usd` quedó en 0 y la reserva final en 0 porque cada llamada traía uso del proveedor y liquidó la reserva. El saldo comprometido del ledger es el precio Haiku global de esos tokens: entrada 0,001 USD y salida 0,005 USD por mil.

| | Tokens | USD |
|---|---:|---:|
| Entrada | 20 639 | 0,020639 |
| Salida | 4 484 | 0,022420 |
| Comprometido | | 0,043059 |
| Reserva al cierre | | 0 |
| Estimación parcial | | 0 |

Límite de la pasada: 24 llamadas y 1 USD. Quedan 9 llamadas y 0,956941 USD. Latencia sumada de `bedrock_queries` 5191–5205: 55 916 ms. Modelo `global.anthropic.claude-haiku-4-5-20251001-v1:0`. El worker no sumó llamadas a este cupo.

## Pruebas anteriores a la pasada

Sin modelos. `bin/rails test` de `observation_correction_test.rb`, `turn_perception_test.rb`, `work_context_reducer_test.rb`, `work_context_goal_test.rb`, `local_pass_ledger_test.rb` y `document_identity_scope_test.rb`: 193 corridas, 2166 aserciones, 0 fallos, 0 errores, semilla 29315.

La prueba del alcance con el pin VF5 usa `canonical_name` `Fermator VF5`. Por eso llega a generación con el cuerpo. No cubre el nombre `VF5` que devolvió esta KB.

## Respuestas publicadas

Las citas de las ocho generaciones fueron una lista vacía. El texto es `published_answer` de la captura, no el texto del DOM, que mezcla la tarjeta.

### Turno 1

Mensaje: «Estoy con un operador de puerta Fermator VF5+. En funcionamiento normal, la puerta empieza a cerrar y vuelve a abrirse sola. Todavía no hice mediciones ni reparaciones. Necesito orientarme con el manual.»

Correlación `query:06e92a0a-4904-42db-95db-dfbf1a2a2a15`. Intérprete 2176/237 tokens, 2802 ms. Generación 526/428, 6099 ms.

```
# INFORME DE CAMPO

## Reporte
Operador de puerta Fermator VF5+. Durante el ciclo de cierre normal, la puerta inicia el movimiento de cierre y se reabre de forma automática sin intervención del operador.

## Evidencia observada
- Equipo: Fermator VF5+
- Comportamiento: apertura involuntaria durante cierre
- Estado: sin mediciones ni reparaciones realizadas aún
- Documentación: no hay procedimiento de fabricante disponible

## Hipótesis de trabajo
El comportamiento de reapertura durante cierre sugiere activación de un dispositivo de seguridad o detección de obstáculo. Las causas más probables son:

1. **Sensor de obstáculo activado** — detector de movimiento, célula fotoeléctrica o sensor de presión interpretando una obstrucción
2. **Contacto de seguridad mecánico** — tope o interruptor de límite en posición intermedia
3. **Falla en la lógica de control** — ciclo de cierre interrumpido por señal de parada

---

## Próxima observación de alto valor
**¿Hay algún objeto, persona o superficie entre los marcos de la puerta durante el cierre?** Esto distingue entre obstrucción real y falsa detección.

## Pregunta principal
¿El operador tiene sensores visibles (células fotoeléctricas, detectores infrarrojos) o contactos mecánicos en los marcos o bordes de la puerta?

**Alternativa:** Si no hay sensores visibles, ¿hay un panel de control o botones de mando? Esto ayuda a identificar qué tipo de seguridades están instaladas.
```

### Republicación del clic

Sin mensaje nuevo. Generación 512/421 tokens, 5255 ms. Correlación de la pregunta original.

```
# INFORME DE CAMPO

**Equipo:** Operador de puerta Fermator VF5+
**Problema activo:** La puerta inicia cierre y se reabre sola durante funcionamiento normal
**Estado:** Sin mediciones ni reparaciones realizadas
**Documentación:** No hay procedimiento de fabricante compatible disponible

---

## EVIDENCIA OBSERVADA

Se requiere verificar el estado actual del sistema antes de hipótesis.

---

## HIPÓTESIS INICIAL (Razonamiento genérico)

Un ciclo de cierre interrumpido por reapertura automática sugiere:

- **Detección de obstáculo:** Un sensor de seguridad (fotocélula, sensor de contacto, o barrera infrarroja) puede estar activándose durante el cierre, interpretando una obstrucción.
- **Falla en la lógica de control:** El controlador puede estar recibiendo una señal de parada o inversión de forma intermitente.
- **Problema mecánico:** Resistencia excesiva en el mecanismo de cierre que dispara protección de sobrecarga.

---

## PRÓXIMA OBSERVACIÓN DE ALTO VALOR

**¿Qué dispositivos de seguridad están instalados en la puerta?** (fotocélulas, sensores de contacto, barrera de luz, detector de movimiento, u otros)

---

## PREGUNTA PRINCIPAL

¿La reapertura ocurre siempre en el mismo punto del recorrido de cierre, o en posiciones variables?

---

## ALTERNATIVA

Si no es posible responder lo anterior: ¿hay indicadores visuales, sonoros o códigos de error en el operador durante el evento?
```

### Turno 2

Mensaje: «En el manual seleccionado, ¿qué comprobaciones aparecen para “la puerta se reabre sola”?»

Correlación `query:a88c29bb-5b2e-4a87-bf66-bd3c2cdcaa10`. Intérprete 2279/106, 1774 ms. Generación 603/402, 4908 ms. El intérprete dijo `meta`; la percepción lo rechazó por `meta_incompatible` y la ruta siguió a recuperación.

```
# INFORME DE CAMPO

**Equipo:** Fermator VF5+ operador de puerta
**Problema activo:** La puerta inicia cierre y se reabre sola
**Estado:** Sin manual de procedimiento compatible disponible

---

## EVIDENCIA VERIFICADA

- Operador Fermator VF5+ instalado
- Comportamiento observado: ciclo de cierre interrumpido por reapertura automática
- Sin mediciones eléctricas realizadas aún
- Sin inspección física del equipo reportada

---

## HIPÓTESIS DE DIAGNÓSTICO

La reapertura durante cierre sugiere:

1. **Sensor de obstáculo activado** — Detector de movimiento, célula fotoeléctrica o sensor de contacto interpretando una obstrucción falsa
2. **Contacto intermitente en circuito de cierre** — Conexión suelta o corrosión en terminal de mando
3. **Lógica de seguridad activada** — Dispositivo de parada de emergencia parcialmente accionado

---

## PRÓXIMA OBSERVACIÓN DE ALTO VALOR

Observe el **comportamiento del ciclo completo sin intervención**: ¿en qué punto exacto del recorrido de cierre ocurre la reapertura? ¿Siempre en la misma posición o variable?

---

## PREGUNTA PRINCIPAL

¿Hay algún **sensor, célula fotoeléctrica o detector de movimiento** visible en el marco de la puerta o en la trayectoria de cierre que pueda estar obstruido, desalineado o sucio?
```

### Turno 3

Mensaje: «Datos simulados de esta prueba: el LED de fotocélula está apagado y no observo una obstrucción mecánica. No he revisado la sensibilidad de reapertura.»

Correlación `query:1b658304-bb2f-40b5-9c12-4802a5700fee`. Intérprete 2294/204, 2319 ms. Generación 585/444, 4941 ms.

```
# INFORME DE CAMPO

**Reporte:**
Operador Fermator VF5+ presenta ciclo de cierre con reapertura automática. LED de fotocélula apagado. Sin obstrucción mecánica visible.

**Evidencia verificada:**
- LED de fotocélula: apagado
- Obstrucción mecánica: no presente
- Sensibilidad de reapertura: no revisada aún

**Evidencia faltante:**
- Documentación técnica del fabricante Fermator VF5+
- Parámetros de ajuste de sensibilidad disponibles en el equipo

---

# HIPÓTESIS DE TRABAJO

El LED apagado sugiere que la fotocélula no está recibiendo señal o no está alimentada. La reapertura automática durante cierre puede originarse en:

1. **Fotocélula sin alimentación o desconectada** → el equipo interpreta ausencia de señal como obstrucción
2. **Sensibilidad de reapertura configurada muy alta** → detecta movimiento de aire o vibración como obstáculo

---

# PRÓXIMA OBSERVACIÓN DE ALTO VALOR

Verifique si existe un **ajuste de sensibilidad de reapertura accesible en el panel de control o en los bornes de conexión de la fotocélula**. Esto permitirá descartar configuración inadecuada antes de revisar alimentación.

**Pregunta principal:**
¿El LED de la fotocélula estuvo encendido en algún momento, o ha permanecido apagado desde el inicio de la falla?

**Alternativa:**
Si el LED nunca ha estado encendido, revise la conexión física del cable de la fotocélula en los bornes del operador.
```

### Turno 4

Mensaje: «Corrijo un dato: el LED de fotocélula está encendido, no apagado. Lo demás se mantiene.»

Correlación `query:92a3842d-f961-4acd-9265-69ad4b2d3009`. Intérprete 2301/132, 1972 ms. Generación 611/328, 4175 ms.

```
# INFORME DE CAMPO

**Problema activo:** La puerta inicia cierre y se reabre automáticamente sin obstrucción mecánica visible.

**Evidencia verificada:**
- LED de fotocélula: encendido
- Obstrucción mecánica: no observada
- Sensibilidad de reapertura: no revisada aún

**Hipótesis de trabajo:**
El LED encendido en la fotocélula indica que el sensor está activo y detectando algo en su campo óptico durante el cierre. La reapertura automática sugiere que la lógica del operador interpreta una señal de obstrucción o presencia continua, activando el ciclo de apertura de seguridad.

---

# OBSERVACIÓN PRIORITARIA

¿La puerta se reabre siempre en el mismo punto del recorrido de cierre, o varía la posición donde ocurre la reapertura?

---

# VERIFICACIÓN DE CAMPO

**Hipótesis:** Revisar si la fotocélula está recibiendo luz parásita, reflejo interno, o si su alineación óptica se ha desplazado.

**Alternativa:** Confirmar que el LED encendido corresponde al estado de recepción normal (no a una falla o bloqueo permanente del haz).
```

### Turno 5

Mensaje: «Con ese LED encendido, ¿la reapertura ocurre automáticamente igual en modo máster y en modo esclavo?»

Correlación `query:a7d72700-3e08-4b6d-b3dd-c6aa1125bd4f`. Intérprete 2304/108, 1682 ms. Generación 611/466, 5380 ms.

```
# INFORME

**Reporte:** La puerta inicia cierre y reabre automáticamente. LED de fotocélula encendido. Sin obstrucción mecánica visible.

**Evidencia verificada:**
- LED de fotocélula: encendido
- Obstrucción mecánica: no observada
- Comportamiento: reapertura automática durante cierre

**Evidencia faltante:**
- Procedimiento del fabricante Fermator VF5+ no disponible
- Comportamiento en modo máster vs. modo esclavo: sin verificar
- Estado de otras fotocélulas (si existen)
- Alineación óptica de la fotocélula
- Limpieza de lentes de fotocélula

---

# HIPÓTESIS

Con el LED encendido, la fotocélula está detectando señal. La reapertura repetida sugiere que el sensor interpreta una obstrucción continua durante el cierre, aunque no hay obstáculo visible.

**Causas posibles:**
- Fotocélula desalineada (detecta reflejo o luz ambiente como obstrucción)
- Lentes sucios o empañados
- Sensor de la fotocélula receptora no alineado con el emisor

---

# PRÓXIMO PASO

**Observación de alto valor:** Limpie cuidadosamente ambas lentes de la fotocélula (emisor y receptor) con un paño seco. Luego, verifique si la reapertura automática persiste durante un cierre completo.

**Pregunta principal:** ¿Después de limpiar las lentes, la puerta cierra completamente sin reabrirse, o el problema continúa igual?

**Alternativa:** Si el problema persiste, ¿puede confirmar que la reapertura ocurre en ambos modos (máster y esclavo)?
```

### Turno 6

Mensaje: «Dato simulado: SW4 está en OFF, modo esclavo. ¿Qué permite concluir eso y ya corresponde cambiar el controlador VF?»

Correlación `query:35637c6d-0665-4235-92a5-e794c3292679`. Intérprete 2312/140, 1971 ms. Generación 607/548, 6298 ms.

```
# INFORME DE CAMPO

## REPORTE
Operador de puerta Fermator VF5+. La puerta inicia cierre y reabre automáticamente durante el ciclo. LED de fotocélula encendido. Sin obstrucción mecánica visible. SW4 en posición OFF (modo esclavo declarado).

## EVIDENCIA OBSERVADA
- LED de fotocélula: encendido
- Obstrucción mecánica: no visible
- Comportamiento: cierre + reapertura automática
- Configuración SW4: OFF

## HIPÓTESIS DE TRABAJO
El LED encendido en fotocélula sugiere que el sensor está activo o recibiendo alimentación. La reapertura durante cierre es consistente con una **señal de parada o inversión continua** llegando al controlador. Esto puede originarse en:

1. **Fotocélula activada permanentemente** (obstrucción óptica, suciedad en lente, alineación perdida)
2. **Contacto de seguridad intermitente** en la puerta o marco
3. **Cableado de fotocélula con falla intermitente** (cortocircuito, contacto suelto)
4. **Controlador interpretando señal de parada como comando repetido**

---

## OBSERVACIÓN DE ALTO VALOR
**Verificar si el LED de fotocélula permanece encendido constantemente o parpadea durante el ciclo de cierre.**

---

## PREGUNTA PRINCIPAL
¿El LED de fotocélula se apaga cuando bloqueas manualmente el haz de luz (colocando la mano entre emisor y receptor)?

---

## SOBRE SW4 EN OFF (MODO ESCLAVO)
SW4 en OFF indica configuración de esclavo, **no es causa de reapertura automática**. Cambiar el controlador no está justificado sin verificar primero la fotocélula y el cableado de seguridad.

**Alternativa rápida:** Desconecta el cable de fotocélula del controlador y repite el ciclo de cierre. Si la puerta cierra normalmente, la falla está en fotocélula o su cableado.
```

### Turno 7

Mensaje: «Resume el caso, la corrección que hice, la configuración y lo que falta confirmar. No se ha realizado ninguna reparación.»

Correlación `query:6f46a2c5-ad22-4f03-a4dc-9b1107bab0c4`. Intérprete 2316/106, 1610 ms. Generación 602/414, 4730 ms.

```
# RESUMEN DEL CASO

**Reporte:**
Fermator VF5+ operador de puerta. La puerta inicia cierre y reabre sola. SW4 en OFF (modo esclavo). LED de fotocélula encendido. Sin obstrucción mecánica visible.

**Evidencia verificada:**
- SW4 posición OFF confirmada
- Modo esclavo activo
- LED fotocélula encendido (señal presente)
- Sin bloqueo mecánico en recorrido

**Hipótesis de trabajo:**
El LED encendido en fotocélula indica detección continua o permanente. En modo esclavo con cierre automático, una señal de fotocélula activa durante el cierre provoca reapertura. La causa puede ser:
- Fotocélula sucia, desalineada o con reflejo parásito
- Señal de fotocélula no se interrumpe al completar cierre
- Configuración de tiempo de cierre insuficiente

---

# LO QUE FALTA CONFIRMAR

No hay registro de:
- Correcciones previas realizadas
- Configuración actual de parámetros de cierre
- Documentación técnica del equipo

---

# PRÓXIMA OBSERVACIÓN DE ALTO VALOR

**Limpie la lente de la fotocélula (emisor y receptor) con paño seco. Observe si el LED permanece encendido sin objeto frente a ella.**

**Pregunta principal:**
¿El LED de fotocélula se apaga cuando retira cualquier objeto del frente del sensor, o permanece encendido incluso sin obstrucción visible?
```

## Evidencia que queda fuera de Git

Capturas, copias de sesión, progreso del navegador y el resumen JSON están en `tmp/field_companion/`. La captura histórica `vf5-reabre-20261020T0238Z` no se modificó.
