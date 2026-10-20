# Fermator VF5+: fidelidad documental y contrato, 2026-10-20

No es aceptación textual. No declara `EPISODIO_VALIDADO`. No reingesta la KB ni reescribe el benchmark ni la secuencia histórica.

HEAD de partida: `54026325f34c8a12535f22d35a33db4fe57f519b`. Los cuatro fallos de `MAX_MSG_LENGTH` siguen anteriores a este encargo y no se tocaron.

## Causas de las tres discrepancias

El PDF no se modificó. SHA-256 `be7a39a3490c92c8381cb883402760cb07d10b0a3beda5348bed22f72abedf72`.

1. Encabezado y nota de la página PDF 5. La instrucción de troceo manda abrir el cuerpo en la etiqueta canónica `S4 — SAFETY SYSTEM` aunque la página imprima `4 Programación` y `SW4.- Máster y Esclavo`. El modelo de ingesta añadió también `NOTA DE SEGURIDAD`. El parser no compara con el PDF y guarda ese texto.
2. Ejemplo de SW4. El relato del chunk conserva `Ejemplo:`. El registro `FR-C02534CE5E0DFAAA` copia la acción que el modelo generalizó, sin esa palabra, como `COMMISSIONING_STEP`.
3. Apertura de la página PDF 13. La página empieza con «En caso que el problema persista, desconectar la fotocélula…», continuación de 8.2. El chunk sustituye esas líneas por un título de continuación escrito por el modelo y empieza en «La puerta no alcanza…».

La corrección de ingesta está en el prompt de troceo y en el parser: un ejemplo no se renderiza como instrucción general. Los chunks ya indexados no se reescriben. El replay local sustituye el cuerpo de cada resultado por el texto de `pdftotext` de la página que alinea, y deja iguales la pregunta, el historial y el contrato de esa comparación. La KB compartida sigue con los chunks defectuosos. La ruta real los usa solo si el proceso arranca con `RAG_LOCAL_PAGE_FIDELITY=1` y el directorio de páginas cuyo `document_id.txt` coincide. Esa conversación de siete turnos no se ejecutó.

## Comparaciones

Misma captura `vf5-bound-20261020T1728Z`. Haiku 4.5, temperatura 0,1, 3000 tokens, sin sistema. El historial sigue siendo el capturado.

| Variante | Qué cambia | Run | Turnos | USD de las respuestas |
|---|---|---|---|---|
| A | Contexto corregido, contrato capturado | `vf5-fidelity-A-20261020T192814Z` | 3/3 al primer intento | 0,031217 |
| B | El mismo contexto y el párrafo de reporte, procedimiento, inferencia y comprobación hecha | `vf5-fidelity-B-20261020T194317Z` | 1 y 2 al primer intento; el 3 al tercero | 0,032588 |

Hashes del prompt de B: turno 1 `e66f3ffa1e783d5caf2c671209c66531b55c619ea642ba4397c5a6881b4a4a72`, turno 2 `94e7d7a654435e6fe2664af339f171c009cd1c6d053aac03be705cf2e879edf2`, turno 3 `ea38fcc6f99ee692841dd201c4789fac7b7114b1317c82a260d87909dc776fb0`.

Criterios, sin cambiarlos. N/E: el dato no está en ese turno. A no mete el ejemplo de SW4 en los turnos 2 y 3, porque la captura no lo traía.

| Criterio | A1 | A2 | A3 | B1 | B2 | B3 |
|---|---|---|---|---|---|---|
| 1 Observación, no descarte | Falla | Falla | Falla | Falla | Falla | Falla |
| 2 Sin causa probable | Cumple | Falla | Cumple | Falla | Falla | Cumple |
| 3 Ejemplo distinto del mecanismo | Falla | N/E | N/E | Falla | N/E | N/E |
| 4 LED de fotocélula, no STATUS | Cumple | Cumple | Falla | Cumple | Falla | Falla |
| 5 LED apagado vigente | N/E | Cumple | Cumple | N/E | Cumple | Cumple |
| 6 Sensibilidad y ausencia de mediciones y reparaciones | Falla | Falla | Falla | Falla | Falla | Falla |
| 7 Comprobaciones con su condición | Falla | Falla | Falla | Falla | Falla | Falla |
| 8 Reporte, manual e incertidumbre | Falla | Falla | Falla | Falla | Falla | Falla |
| 9 Sin reemplazo ni ajuste no documentado | Falla | Falla | Cumple | Falla | Falla | Cumple |
| 10 Citas del propio prompt | Cumple | Falla | Cumple | Cumple | Cumple | Cumple |

A sigue pidiendo ajustar `#54` y trata «no observo» como comprobación hecha. Conserva el LED de fotocélula en los turnos 1 y 2. B no mejora el descarte. En el turno 1 repite el ejemplo de SW4 como mecanismo de este esclavo y manda medir o ajustar `#54`. En el turno 2 convierte el LED apagado en LED STATUS y cita el cambio de fusible. Esa regresión no estaba en A. La frase restaurada «En caso que el problema persista…» está en los tres prompts y ninguna respuesta la presenta.

Dos variantes seguidas no mueven el descarte. El párrafo sí viajó en el request de B. El modelo lo tiene al final y, aun así, cierra la observación. Seguir añadiendo la misma regla no es el siguiente paso. El cupo que queda no preserva la repetición y los siete turnos, así que no hay otra variante.

## ServiceUnavailable

El mensaje del log es el de las 13:45: `Bedrock is unable to process your request.` Cero tokens. No es el timeout de lectura. El primer replay de B lanzó tres intentos seguidos y cada uno consumió el techo local, unos US$0,043, aunque AWS no cobró. Los reintentos posteriores, de a uno, repitieron el costo. La recuperación que ya había dejado pasar la llamada siguiente es la del intérprete: SDK en un intento, y la aplicación espera 0,4 s y 1,2 s antes del segundo y del tercer intento. Un 503 sin tokens queda ahora en US$0. En el run que sí respondió, el turno 3 falló dos veces y salió al tercer intento.

## Saldo

Archivo `tmp/field_companion/vf5_generator_benchmark/assignment_spend.json`. No se reinició.

32 invocaciones. US$0,519002 comprometidos. Quedan 16 invocaciones y US$3,480998. Repetir los tres turnos y recorrer los siete exige 17 invocaciones. No se hace ninguna de las dos. La KB compartida no se modificó.
