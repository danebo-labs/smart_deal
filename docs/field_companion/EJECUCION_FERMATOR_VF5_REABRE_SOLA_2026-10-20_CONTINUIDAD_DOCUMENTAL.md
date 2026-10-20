# Fermator VF5+: continuidad documental del apartado, 2026-10-20

Informe de una reparación local de ingesta y de tres generaciones del turno 1. La rúbrica quedó escrita antes de las llamadas y no se modificó después. No declara corregida la KB compartida, validado el reductor, completada la conversación ni `EPISODIO_VALIDADO`. No hubo push, deploy, Retrieve ni intérprete. El contrato, los roles y el estado del turno quedaron como en D-histórico.

## Veredicto

Mejora documental, y en conjunto mejora parcial. Las tres muestras conservan las tres comprobaciones, la prueba de TEST y la condición de que el problema persista, con el resultado de obstrucción si el recorrido queda incompleto. La condición no se pierde. El caso no cumple 3/3: las tres muestras atribuyen un significado eléctrico al LED de fotocélula. La muestra 1 además manda ajustar `#54`. La muestra 3 propone la lógica de la maniobra como causa de esta reapertura. No queda lista para una conversación nueva. Este encargo termina aquí. La línea «or user input» sigue igual.

## Qué se reparó

El apartado «La puerta se re-abre sola» de la sección 8.2, «Funcionamiento normal», queda unido entre la página PDF 12 (impresa 11/21) y la página PDF 13 (impresa 12/21). El encabezado, las tres comprobaciones y la continuación condicionada viajan juntos. La continuación deja de heredar los aliases de LED STATUS, fusibles y los demás síntomas. El cuarto guion sale de un `FIELD_RECORD` ya parseado, vuelto a renderizar por `BatchResultsParserService`, con la condición en la acción y el resultado condicional. No se reescribió la acción ni el resultado a mano.

La unión es general: una página que abre a mitad de un ítem se cose al ítem abierto de la página anterior. El código no nombra este manual ni este síntoma. `ChunkMergerService` la aplica cuando recibe el texto de página. Sin ese texto, las páginas ordinarias siguen igual.

El prompt enviado usa el modo aislado. Del segundo resultado solo se retira la frase de continuación. Sus aliases y sus registros quedan byte a byte. La fusión completa, que sí reetiqueta los encabezados de los otros síntomas, queda guardada y no se envió.

## Rúbrica, congelada antes de las llamadas

SHA-256 `50116f404a0e6cf3937deb1440d6d171f38fd21c9d7023faf8150e5421242e7f`.

Fidelidad documental:

- Las tres comprobaciones iniciales conservan su significado.
- TEST aparece como prueba posterior pendiente, condicionada a que el problema persista.
- Se conserva el resultado documental: si no completa apertura o cierre en esa prueba, el manual señala obstrucción.
- Las citas corresponden a los fragmentos realmente usados.

Fidelidad al caso:

1. La observación visual no descarta globalmente la obstrucción.
2. No se atribuye al técnico una comprobación documental realizada que no reportó. Se puede reconocer su observación visual, conservando su alcance.
3. No se inventa el significado eléctrico del LED.
4. No se prescribe ajustar `#54` ni otro procedimiento que los pasajes no documenten.
5. No se prioriza una causa sin respaldo.
6. SW4 puede explicarse documentalmente; su ejemplo no se presenta como mecanismo confirmado de esta puerta.
7. No se inventan mediciones, reparaciones ni resultados.

Lectura: vale «tres comprobaciones iniciales y, si persiste, una prueba adicional». «Para descartar» se juzga por si extrapola una conclusión que el pasaje no permite. «Eso explicaría» puede ser hipótesis si está presentada como posibilidad y no presupone hechos no confirmados. El estilo no cuenta como fallo. Los criterios no se rebajan.

## Matriz

Cumple es pase. Tres muestras son una señal inicial.

| Criterio | s1 | s2 | s3 |
|---|---|---|---|
| D1 Tres comprobaciones | Cumple | Cumple | Cumple |
| D2 TEST pendiente, si persiste | Cumple | Cumple | Cumple |
| D3 Obstrucción si el recorrido queda incompleto | Cumple | Cumple | Cumple |
| D4 Citas del fragmento usado | Cumple | Cumple | Cumple |
| C1 La observación visual no cierra la obstrucción | Cumple | Cumple | Cumple |
| C2 No atribuye una comprobación no reportada | Cumple | Cumple | Cumple |
| C3 No inventa el significado del LED | No | No | No |
| C4 No prescribe ajustar `#54` | No | Cumple | Cumple |
| C5 No prioriza una causa sin respaldo | Cumple | Cumple | No |
| C6 SW4 documental, ejemplo no confirmado aquí | Cumple | Cumple | Cumple |
| C7 Sin medición, reparación ni resultado inventado | Cumple | Cumple | Cumple |

Documental 3/3. Caso 0/3.

## Evidencia

### s1

D2: «si el problema persiste después de las comprobaciones anteriores, desconectar la fotocélula y volver a pulsar el botón de TEST». D3: «Si la puerta no se abre o cierra completamente tras desconectar la fotocélula, entonces debe haber una obstrucción mecánica [1]». C1 y C2: «Ya has observado que no hay obstrucción mecánica visible, pero el manual ofrece un test adicional». C3: «el LED de fotocélula está encendido, lo que sugiere que la fotocélula está detectando algo». El pasaje no documenta ese significado. C4: «Comienza por ajustar la sensibilidad del potenciómetro #54 según lo que indique el manual de regulación». El ítem dice comprobar la sensibilidad. También añade «falsa detección», que el pasaje no trae. C6 explica el modo esclavo con la frase del manual y no cierra esa vía como causa de esta puerta. [1] es el apartado reparado. [3] es SW4.

### s2

D2: «Si el problema persista después de verificar el potenciómetro #54, el manual indica: desconectar la fotocélula y volver a pulsar el botón de TEST». La condición queda. El «después de verificar #54» estrecha la puerta de entrada respecto de «si el problema persiste», y aun así la prueba sigue condicionada. D3: «Si la puerta no se abre o cierra completamente en esa condición, debe haber una obstrucción mecánica en la puerta [1]». C1 y C2: «Tú ya observaste que no hay obstrucción visible» y la prueba sigue pendiente. C3: «lo que indica que la fotocélula está activada». C4 se queda en comprobar y verificar. C6 describe el ejemplo de esclavo sin declararlo mecanismo confirmado de esta reapertura.

### s3

D2 y D3 repiten la estructura de s2, con «después de revisar el potenciómetro #54» y «en ese caso, debe haber una obstrucción mecánica [1]». C1 y C2 reconocen la observación visible y dejan la prueba pendiente. C3: «lo que indica que la fotocélula sí está activada». C5: «la re-apertura que observas podría no ser causada directamente por la fotocélula, sino por la lógica de control del ascensor respondiendo a esa señal». El «podría» la deja como posibilidad, y presupone la señal del ejemplo. Por eso C6 se mantiene: no la presenta como mecanismo confirmado. C5 no: prioriza esa causa sin respaldo del apartado.

Ninguna muestra cita fusibles, LED STATUS ni el segundo resultado.

## Respuestas completas

### s1

```
# Orientación según el manual VF5

Según la sección 8.2 "Funcionamiento normal" del manual, cuando **la puerta se re-abre sola**, el procedimiento documentado requiere comprobar tres elementos en este orden [1]:

**Comprobaciones pendientes:**

1. **Sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54)** — Esta es la primera verificación que falta en tu reporte. El manual la menciona explícitamente como paso inicial [1].

2. **Fotocélula activada** — El manual indica comprobar que la fotocélula no esté activada [1]. Tú reportas que el LED de fotocélula está encendido, lo que sugiere que la fotocélula está detectando algo. Esta condición requiere verificación.

3. **Obstrucción mecánica** — Ya has observado que no hay obstrucción mecánica visible, pero el manual ofrece un test adicional: **si el problema persiste después de las comprobaciones anteriores, desconectar la fotocélula y volver a pulsar el botón de TEST**. Si la puerta no se abre o cierra completamente tras desconectar la fotocélula, entonces debe haber una obstrucción mecánica [1].

**Contexto de tu configuración:**

Estás en modo esclavo (SW4 = OFF). En este modo, según la sección de programación, **no hay movimientos de re-apertura automáticos** [3]. Las puertas solo responden a instrucciones del módulo de control del ascensor. Cuando la fotocélula se obstruye, la unidad envía una señal a la maniobra mediante la salida FOTOCÉLULA (terminales 36, 37, 38), y entonces la maniobra desactiva la señal de cerrar y activa la de abrir [3].

**Próximo paso:** Comienza por ajustar la sensibilidad del potenciómetro #54 según lo que indique el manual de regulación, luego verifica el estado real de la fotocélula (si está realmente obstruida o si hay una falsa detección).
```

### s2

```
# Orientación según el manual VF5

Según la sección 8.2 "Funcionamiento normal" del manual, cuando **la puerta se re-abre sola**, el documento establece tres comprobaciones ordenadas [1]:

1. **Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54)** — Esta es la primera verificación que falta en tu reporte.

2. **Comprobar que la fotocélula no esté activada** — Tú reportas que el LED de fotocélula está encendido, lo que indica que la fotocélula está activada. Sin embargo, en modo esclavo (SW4 en OFF), el comportamiento es diferente al modo máster.

3. **Comprobar que no hay obstrucción mecánica en la puerta** — Tú ya observaste que no hay obstrucción visible.

## Consideración del modo esclavo

En modo esclavo, **no hay movimientos de re-apertura automáticos**. Las puertas solo responden a instrucciones del módulo de control del ascensor [3]. Cuando la fotocélula está obstruida en modo esclavo, la unidad envía una señal a la maniobra mediante la salida FOTOCÉLULA (terminales 36, 37, 38), y entonces la maniobra desactiva la señal de cerrar y activa la de abrir.

## Próximo paso documentado

Si el problema persista después de verificar el potenciómetro #54, el manual indica: **desconectar la fotocélula y volver a pulsar el botón de TEST**. Si la puerta no se abre o cierra completamente en esa condición, debe haber una obstrucción mecánica en la puerta [1].

**Falta comprobar:** la sensibilidad del potenciómetro #54 y, si es necesario, ejecutar la prueba con fotocélula desconectada.
```

### s3

```
# Orientación según el manual VF5

Según la sección 8.2 "Funcionamiento normal" del manual, cuando **la puerta se re-abre sola**, el documento establece tres comprobaciones ordenadas [1]:

1. **Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54)** — Esta es la primera verificación que falta en tu reporte.

2. **Comprobar que la fotocélula no esté activada** — Tú reportas que el LED de fotocélula está encendido, lo que indica que la fotocélula sí está activada. Sin embargo, en modo esclavo (SW4 en OFF), el comportamiento es diferente al modo máster.

3. **Comprobar que no hay obstrucción mecánica en la puerta** — Tú ya observaste que no hay obstrucción mecánica visible.

## Diferencia crítica: modo esclavo

Dado que SW4 está en OFF (modo esclavo), el manual aclara que **no hay movimientos de re-apertura automáticos**. En modo esclavo, cuando la fotocélula se obstruye, la unidad envía una señal a la maniobra mediante la salida FOTOCÉLULA (terminales 36, 37, 38), y entonces la maniobra desactiva la señal de cerrar y activa la de abrir [3].

Esto significa que la re-apertura que observas podría no ser causada directamente por la fotocélula, sino por la lógica de control del ascensor respondiendo a esa señal.

## Próximo paso según el manual

Si el problema persista después de revisar el potenciómetro #54, el manual indica: **desconectar la fotocélula y volver a pulsar el botón de TEST**. Si la puerta no se abre o cierra completamente en ese caso, debe haber una obstrucción mecánica en la puerta [1].

**Falta comprobar:** la sensibilidad del potenciómetro #54 de regulación de fuerza de re-apertura.
```

## Procedencia

HEAD `d7212bbd0e1a9235d78d9e678b9f69afb9a2901e`.

PDF `docs/field_companion/fuentes/VF5.pdf`, SHA-256 `be7a39a3490c92c8381cb883402760cb07d10b0a3beda5348bed22f72abedf72`. El texto de página sale de `pdftotext -layout` de las páginas 12 y 13. La página 5 no hizo falta: SW4 ya estaba en el tercer resultado y no se tocó.

El registro del cuarto guion sale de `tmp/field_companion/local_ingestion/raw-p13.txt`, primer registro del primer chunk, tipo `TROUBLESHOOTING_STEP`. Acción: «En caso que el problema persista, desconectar la fotocélula y volver a pulsar el botón de TEST». Resultado: «Si la puerta no se abre o cierra completamente, debe haber una obstrucción mecánica en la puerta.» Evidencia: «desconectar la fotocélula y volver a pulsar el botón de TEST». Se volvió a renderizar con página PDF 13 y encabezado `8.2 Funcionamiento normal — La puerta se re-abre sola.` El identificador resultante es `FR-E38B9F0FD033204F`. Las tres comprobaciones se re-renderizaron con página PDF 12 y el mismo encabezado: `FR-FC381FC90C61BE34`, `FR-0FA4AEE227742905`, `FR-0035DE12471FB0D6`. Acción, resultado y evidencia de esas tres quedaron como estaban. Parseo nuevo: cero llamadas.

Los originales de `tmp/field_companion/local_ingestion/` no se sobrescribieron. El artefacto regenerado es el prompt del replay.

`SectionPageContinuity` une el fragmento. `ChunkMergerService#merge_with_report` acepta `page_texts` y llama a esa clase antes de serializar. Sin texto de página, el gancho no cose nada.

## Diff

Run `tmp/field_companion/vf5_section_continuity/vf5-section-continuity-20261020T222748Z/`.

- `diff-prompt.diff`, `diff-result-0.diff`, `diff-result-1.diff`, `diff-result-2.diff`.
- `diff-pipeline-result-1.diff` es la fusión no enviada.
- `prompt-before.txt` y `prompt-after.txt`.

Fuera de los tres `<search_result>` el prompt es idéntico: `Goal:`, `Query:`, identificadores, reporte, historial y contrato. El tercer resultado es idéntico, diff de cero bytes. El segundo resultado solo pierde la línea de continuación y el blanco que la seguía.

El primer resultado gana:

- `[PDF_PAGE: 12]` y `[PRINTED_PAGE: 11/21]`.
- `8.2 Funcionamiento normal`.
- Las tres comprobaciones, ya presentes.
- `[PDF_PAGE: 13]`, `[PRINTED_PAGE: 12/21]` y el cuarto guion.
- Los tres registros con el encabezado de 8.2, más el registro condicional.

Los aliases del primer resultado siguen siendo `re-apertura sola, potenciómetro #54, fotocélula activada, obstrucción mecánica, funcionamiento normal`.

## Generación

Control: `tmp/field_companion/vf5_fidelity_replay/vf5-fidelity-D-historico-20261020T202806Z/t1/attempt-1/bodies/b0001.txt`.

SHA-256 del prompt de control `a3dc05933eaa46bfb7af798f41992660e438e6f3575e50973af4871184564754`. SHA-256 del body de control `3a0f1c55a52b0ce56b056488a9ec05541c36e018ab9169d4f741aa4d7522f25a`.

SHA-256 del prompt reparado `e4db4fde8644ca108e9420e009dd86547a2e66a9b5377379e3b4242ee4e50b18`. SHA-256 del body reparado `59dbe894c3725e4f264c6e684eeb591ce8c3acace2731d024e2f92fa05bccea9`. Las tres muestras comparten esos dos hashes. El body de cada intento está en `sN/attempt-1/bodies/b0001.txt` y coincide con `prompt-after.txt`.

Modelo `global.anthropic.claude-haiku-4-5-20251001-v1:0`. Temperatura 0,1. Máximo 3000 tokens. `anthropic_version` `bedrock-2023-05-31`. Sin `system`. Un mensaje de usuario. Request histórico `354da85f-c20c-4d36-bb88-45a0c059bc2e`. Reintento solo dentro de `CapturedGenerationReplay.run_sample`, límite 3, backoff del módulo existente, SDK en un intento. No hubo segundo probe. No hubo reintento: cada muestra respondió al primer intento.

Manifiesto: `manifest.json`. Rúbrica: `rubric.json`. Harness: `script/field_companion/vf5_section_continuity.rb`. La vista previa, sin llamadas, está en `tmp/field_companion/vf5_section_continuity/preview/`.

## Saldo

Ledger `tmp/field_companion/vf5_generator_benchmark/assignment_spend.json`, sin reinicio.

| | Intentos | Calculado | Desconocido | Reservas |
|---|---|---|---|---|
| Inicial | 55 | US$0,773828 | US$0 | 0 |
| Final | 58 | US$0,805683 | US$0 | 0 |

Este encargo: 3 intentos, US$0,031855. s1 US$0,010720 (8020/540). s2 US$0,010470 (8020/490). s3 US$0,010665 (8020/529). Parseo US$0. Reintentos 0. Tope de este encargo: 10 intentos y US$0,50. Quedan 7 intentos y US$0,468145 de ese tope, sin usarlos. El acumulado sigue bajo 96 intentos y US$4. La reserva de 15 intentos queda intacta: después de esta pasada hay 38 intentos libres hasta el tope de 96.

## Comprobación local

`bin/rails test test/services/section_page_continuity_test.rb test/services/chunk_merger_service_test.rb`, semilla 57894: 50 corridas, 259 aserciones, 0 fallos. Eso cubre la unión, el rechazo de un registro que pierde la condición, la página que abre con encabezado, las páginas no consecutivas y el gancho del merger. No valida al asistente ni la KB.

## Siguiente paso

La conversación integrada de tres turnos, y después el recorrido de siete, queda para cuando una generación también cumpla la fidelidad al caso. Hoy no. El fallo que sigue es de respuesta: el LED recibe un significado que el apartado no da, y una de las tres muestras vuelve a mandar ajustar `#54`.
