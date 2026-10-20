# Haiku 4.5 y Sonnet 4.5 sobre los tres prompts VF5, 2026-10-20

Comparación exclusiva de generación. No evalúa el intérprete ni las cuatro combinaciones del Companion. No declara el Companion aceptado, el guion de demo validado ni `EPISODIO_VALIDADO`.

HEAD al generar: `759f1c3e1a392c9f10b389c67a6823fc222126b7`. El código de producto no se modificó durante las seis llamadas. La herramienta local es `script/field_companion/vf5_generator_benchmark.rb`, que llama a `Rag::CapturedGenerationReplay`. `BEDROCK_MODEL_ID` no elige el modelo de este replay: el id va en el argumento `model_id` del SDK.

## Verificación documental

PDF `docs/field_companion/fuentes/VF5.pdf`. SHA-256 `be7a39a3490c92c8381cb883402760cb07d10b0a3beda5348bed22f72abedf72`, igual al esperado. 22 páginas. La página PDF 5 imprime «Pág. 4/21» y abre con «4 Programación». La página PDF 13 imprime «Pág. 12/21». No se modificó el PDF, los chunks, el `FIELD_RECORD`, el corpus ni la ingesta.

Las tres discrepancias quedan confirmadas. El texto siguiente es el de la página o el del prompt capturado en `tmp/field_companion/validation_captures/vf5-bound-20261020T1728Z/354da85f-c20c-4d36-bb88-45a0c059bc2e/bodies/b0005.txt`.

**Encabezado y nota añadidos en el chunk de la página 5. Confirmada.** La página 5 no contiene «S4 — SAFETY SYSTEM» ni «NOTA DE SEGURIDAD». El encabezado impreso es «4 Programación» y el apartado es «SW4.- Máster y Esclavo». El chunk del turno 1, fuente 3, inserta:

> S4 — SAFETY SYSTEM
>
> NOTA DE SEGURIDAD: En modo Esclavo, la re-apertura de emergencia por fotocélula depende de la respuesta del módulo de maniobra del ascensor. Verificar que la maniobra procesa correctamente la señal FOTOCÉLULA (terminales 36, 37, 38) durante la puesta en marcha.

El mismo chunk normaliza «SW4 — Máster y Esclavo», «Las puertas solo» y «desactivará». El PDF dice «SW4.- Máster y Esclavo», «Las puerta solo» y «desactivara».

**El ejemplo de SW4 pasa a paso general. Confirmada.** El PDF, SW4 OFF, dice:

> Ejemplo: con la fotocélula obstruida la unidad enviará una señal a la maniobra mediante la salida FOTOCÉLULA (36, 37, 38). Entonces, la maniobra desactivara la señal de cerrar y activará la señal de abrir.

El chunk conserva «Ejemplo:». El registro `FR-C02534CE5E0DFAAA`, tipo `COMMISSIONING_STEP`, sección «SW4.- Máster y Esclavo», lo convierte en acción general:

> ACTION: Configurar SW4 en OFF (Esclavo): la unidad envía señal a la maniobra mediante salida FOTOCÉLULA (terminales 36, 37, 38) cuando la fotocélula está obstruida; la maniobra desactiva cerrar y activa abrir.
>
> EVIDENCE: la maniobra desactivara la señal de cerrar y activará la señal de abrir

**Continuación de la reapertura omitida en la página 13. Confirmada.** La página PDF 13 abre con la continuación de 8.2:

> En caso que el problema persista, desconectar la fotocélula y volver a pulsar el botón de TEST. Si la puerta no se abre o cierra completamente, debe haber una obstrucción mecánica en la puerta.

Esa frase no está en el chunk de la página 12 ni en el de la página 13. El chunk de la página 13 empieza en «La puerta no alcanza la posición de apertura completa», después de un encabezado añadido «Problemas adicionales del operador de puerta VF5+». No se penaliza a un modelo por no repetir una frase que su prompt no contenía.

## Entradas

Los tres cuerpos son el mensaje `user` del `generate_text` con `result=prepared`. No hay campo `system`. Temperatura 0,1. `max_tokens` 3000. `anthropic_version` `bedrock-2023-05-31`. El id del modelo no entra en el JSON: el `body_sha256` es el mismo para Haiku y Sonnet en cada turno. Los tokens de entrada coinciden con la captura viva.

| Turno | Request | Prompt SHA-256 | Bytes | Body SHA-256 | Tokens de entrada |
|---|---|---|---|---|---|
| 1 | `354da85f-c20c-4d36-bb88-45a0c059bc2e` | `5dc531b35ab27d69df989d0d09de57e247108bab07b3ce14652d01e029fda306` | 28951 | `47964437ac447b69fd4a502e1bcd181e3c91e1985e7b5e401a34c81155294c53` | 8129 |
| 2 | `8205d72d-d67f-4dcb-b9d6-532fb3373768` | `2c284b7070cd536ed28a4dc04ce98322eaa430a9edec4b28479bcc93cb32a607` | 28342 | `d021867dbbf9bb5cdcd4f327fc19854d966ff0066f2c4b5b45f31fa63ed61cab` | 7775 |
| 3 | `76c894c8-7042-4798-90e2-c7ccd284daaf` | `1e2f454821246041d4a3f4624b9e257ccd3fe460865059c394fa6324ee1155b8` | 33128 | `c959372fc46daf00a3ff1fd6f2e038fcd6541b2600230322aaf2edbb021ab4d0` | 9704 |

Run `vf5-generator-benchmark-20261020T181317Z`. Respuestas completas, una por intento, en `tmp/field_companion/vf5_generator_benchmark/vf5-generator-benchmark-20261020T181317Z/{haiku,sonnet}/t{1,2,3}/attempt-1/answer.txt`. No se vuelven a meter en un prompt.

Ids enviados al SDK:

- Haiku 4.5: `global.anthropic.claude-haiku-4-5-20251001-v1:0`
- Sonnet 4.5: `global.anthropic.claude-sonnet-4-5-20250929-v1:0`

`ListInferenceProfiles` respondió `AccessDenied` para esta cuenta. La invocación global de Sonnet 4.5 sí entró. No hubo fallback al perfil `us.` y no se usó un modelo 5.5. Seis generaciones, un intento físico cada una, sin error.

## Criterios

Quedaron escritos en `Rag::CapturedGenerationReplay::CRITERIA` antes de leer estas respuestas. Juicio por significado. C = cumplido, F = fallido, N = no evaluable en ese turno. Una celda puede ser fiel al prompt y, a la vez, discordante con el PDF.

| Criterio | H1 | S1 | H2 | S2 | H3 | S3 |
|---|---|---|---|---|---|---|
| 1. La observación de obstrucción no se convierte en descarte | F | F | F | F | F | C |
| 2. No afirma causa probable ni ordena causas sin evidencia | F | C | C | F | C | F |
| 3. El ejemplo documental no pasa a mecanismo de este equipo | F | F | C | F | C | C |
| 4. El LED sigue siendo el de fotocélula | C | C | C | C | F | F |
| 5. LED apagado vigente en los turnos 2 y 3 | N | N | C | C | C | C |
| 6. Sensibilidad pendiente; sin mediciones ni reparaciones hechas | C | C | C | C | C | C |
| 7. Comprobaciones documentales con sus condiciones | F | F | F | F | F | F |
| 8. Separa reporte, manual e incertidumbre | F | F | F | F | F | F |
| 9. Sin reemplazo ni intervención sin respaldo y condición | F | F | C | F | F | F |
| 10. La cita corresponde a un pasaje de ese prompt | C | C | C | C | C | C |

Extractos que sostienen los fallos decisivos:

- Haiku 1: «Ya has descartado una (obstrucción mecánica)». «Esta es la causa más probable». «significa que la maniobra está respondiendo a esa señal de fotocélula». «limpia/realinea la fotocélula». Inventa que el LED encendido indica alimentación.
- Sonnet 1: «ya descartaste obstrucción visible». Presenta el ejemplo y la nota de seguridad del chunk como el mecanismo de este esclavo y pide «Ajustar o verificar el potenciómetro #54». No dice «causa más probable».
- Haiku 2: «Que no hay obstrucción mecánica — ya descartada». Conserva «LED de fotocélula» y el dato apagado. Dice que el documento no especifica qué estado del LED significa fotocélula activada. No inventa los bornes de SW4, que este prompt ya no trae.
- Sonnet 2: «Que el LED de fotocélula esté apagado descarta la segunda comprobación». «ya lo hiciste visualmente». Traslada la «obstrucción continuada» de la página 13, cuyo pasaje habla del LED STATUS y de una puerta que no obedece, a la reapertura de este caso. «Ajusta la sensibilidad».
- Haiku 3: «ya lo descartaste en campo». En «Lo que reportas» escribe «LED STATUS apagado». Añade «Conexiones del cableado» y admite que el manual no lo menciona para este síntoma. El patín queda condicionado a «si la puerta se vuelve a abrir cuando el patín está cerrando».
- Sonnet 3: «No observas obstrucción mecánica» queda como observación, sin la palabra descarte. Después aplica «LED STATUS está apagado» y el cambio de fusibles de 250 V y 4 A sin la condición del PDF: sistema con alimentación que no funciona. Esta puerta está en movimiento.

Fidelidad al contexto y concordancia con el PDF van separadas. Haiku 1 y Sonnet 1 siguen el `FIELD_RECORD` y la nota que el PDF no contiene: fieles a una entrada defectuosa e incorrectos respecto del manual. Sonnet 2 y Sonnet 3 citan pasajes que sí estaban en su prompt y los aplican al síntoma equivocado: la cita es fiel al texto recibido y la inferencia no lo es respecto del apartado 8.2. Haiku 3 renombra el LED del técnico; el prompt del turno 3 dice «el LED está apagado» y, en otro pasaje, «LED STATUS».

## Factores comunes

- El ejemplo de SW4 y la nota añadida están en la fuente 3 del turno 1. Los turnos 2 y 3 no traen ese pasaje. La fuente 3 del turno 2 es programación DIP de SW2 y SW3.
- El historial del turno 2 ya contiene, con etiqueta Assistant, la conclusión «Ya has descartado una (obstrucción mecánica)».
- La corrección guarda «el LED está apagado». «LED de fotocélula» queda en el mensaje del técnico del turno 1, no en la observación vigente.
- El objetivo guardado en los turnos 2 y 3 es «en funcionamiento normal la puerta empieza a cerrar». La observación sigue teniendo «vuelve a abrirse sola». El corte lo produce la conjunción interna del síntoma.
- Las tres discrepancias documentales de arriba entran en la generación tal como estaban.

Este replay mide diferencias de generación con esas entradas. No demuestra fiabilidad general ni valida la conversación.

## Costo

Cupo de este encargo: 48 invocaciones y US$4. No se reinició el archivo. Seis invocaciones, todas con precio, US$0,131712.

| Modelo | Turno | Entrada | Salida | Latencia | Intentos | USD |
|---|---|---|---|---|---|---|
| Haiku 4.5 | 1 | 8129 | 508 | 7425 ms | 1 | 0,010669 |
| Haiku 4.5 | 2 | 7775 | 310 | 4829 ms | 1 | 0,009325 |
| Haiku 4.5 | 3 | 9704 | 544 | 7232 ms | 1 | 0,012424 |
| Sonnet 4.5 | 1 | 8129 | 582 | 12219 ms | 1 | 0,033117 |
| Sonnet 4.5 | 2 | 7775 | 385 | 10040 ms | 1 | 0,029100 |
| Sonnet 4.5 | 3 | 9704 | 531 | 11522 ms | 1 | 0,037077 |

El manifiesto guarda el turno 2 de Sonnet como `0.0291`. El precio de 7775 y 385 tokens a US$3 y US$15 por millón es US$0,029100, y la suma del archivo cierra en US$0,131712.

## Conclusión

Ambos presentan fallos decisivos. Sonnet no los levanta: en el turno 1 trata la obstrucción observada como descarte y el ejemplo de SW4 como mecanismo de este equipo; en el turno 2 el LED apagado le sirve para descartar la fotocélula; en el turno 3 convierte el LED del caso en LED STATUS y manda cambiar fusibles. Haiku repite el descarte en los tres turnos y, en el primero, la causa más probable y la limpieza de la fotocélula.

Siguiente encargo mínimo, sin abrir otro plan: corregir la poda del objetivo para que la conjunción interna del síntoma no se lleve «vuelve a abrirse sola»; conservar el referente cuando la corrección dice solo «el LED está apagado» y hay un único LED cualificado; y marcar en el historial que las líneas del asistente son conclusiones anteriores, no reporte del técnico. Después, una secuencia nueva. Eso no reescribe el corpus ni presenta el chunk añadido como texto literal del PDF.
