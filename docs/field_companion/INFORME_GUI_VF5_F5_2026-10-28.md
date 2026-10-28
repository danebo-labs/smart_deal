# Informe GUI VF5 — F5, 28 de octubre de 2026

Dictamen de la corrida web sobre `39f2d63`. No cambia código, modelo, configuración ni sesión. No reabre F2, F3 ni F4. No abre el plano Elemont. La selección explícita del VF5 no acredita selección automática.

## Veredicto

**F5 cumple en el guion de cinco frases del episodio `ep_71e5c284b0315a41`.**

Quedó acreditado, sobre la imagen de la reparación:

- T2 sustituye «apagado» por «el LED está encendido», no publica parpadeo ni asigna el indicador, y guarda «¿Cuál LED está encendido, el de Fotocélula o el de Estado?» junto a #21.
- T3 no funda #21 en el LED genérico. La fotocélula queda hecha y aparte. La orientación del síntoma sigue.
- T4 no guarda «¿Qué sigue?». #21 y la pregunta del LED siguen.
- T5 guarda el desconocimiento de #21 y del contacto #21–#23 sobre la pregunta de #21, no los vuelve a pedir, no publica la lectura que aplica la función de fotocélula al LED observado, y deja la pregunta del LED como pendiente.
- #54 y las mediciones siguen sin hacer. «No veo obstrucción» sigue siendo observación.

Hay un episodio anterior, `ep_032b31a16efcf861`, en la misma sesión y el mismo día. No entra en este dictamen: el historial se vació antes del guion evaluado y ese episodio no recorre las cinco frases.

## Precedencia

El criterio usado es la comprobación web mínima de [PLAN_CORRECCION_VF5_COMPANION.md](PLAN_CORRECCION_VF5_COMPANION.md), sección «Respaldo del componente — 27 de octubre de 2026, 15:00». La corrida de las 15:00, imagen `e45088f`, está en [INFORME_GUI_VF5_F5_2026-10-27_15h.md](INFORME_GUI_VF5_F5_2026-10-27_15h.md). Allí #21 cumplía y T3/T5 usaban el LED genérico como el de fotocélula. Esta corrida es la comprobación web de esa reparación.

## Ejecución comprobada

| Dato | Valor |
|---|---|
| Cuenta | `danebo-legacy`, id 1 |
| Usuario | id 3, sesión 128, canal web |
| Episodio evaluado | `ep_71e5c284b0315a41`, abierto `2026-10-28T10:43:29-03:00` |
| Episodio anterior, fuera de muestra | `ep_032b31a16efcf861` |
| Imagen web | `docker.io/lahirisan80/smart-deal:39f2d63c54b6d7fa5d40da0d632033a892a9e82f` |
| `KAMAL_VERSION` en las capturas de la muestra | `39f2d63c54b6d7fa5d40da0d632033a892a9e82f` |
| Intérprete y plan | `global.anthropic.claude-haiku-4-5-20251001-v1:0` |
| Modo | `owner`. Episodio activo |
| Exportación | `tmp/vf5_f5_gui_20261028/2026-10-28_2026-10-28_danebo-legacy/`, generada `2026-10-28T13:52:03Z` |
| Cuerpos | copiados en solo lectura a `tmp/vf5_f5_gui_20261028/captures/`. El paquete del export no los guarda |

El índice del export está `partial`: 11 archivos, 12 filas. No basta. `bin/pilot_metrics` arma el índice y borra el tar. Los `capture.json` y `bodies/` seguían en el contenedor web `acc53d824f2e`. Se copiaron sin escribir en producción. Los cinco turnos evaluados tienen cuerpos legibles, `body_truncated` false y el tamaño del índice. El cuerpo de `chunk_p7_3.txt` en T3 es el SHA-256 `34c7d25fa5e3214cf138696f46a5b314c049e2ccdc27db3ce223ac0da777e9dc`, 4660 bytes. Contiene la frase del indicador de fotocélula y «LED parpadeante indicando condiciones apropiadas de trabajo.». No contiene «Verificar que el LED de ESTADO parpadea».

## Recomendación y selección

El guion evaluado empieza sin manual. En T1, `query:ee71eb83-e043-4256-b7bd-576c4d791895`, el foco antes y después del primer paso está vacío.

| Hora −03 | Qué pasó | Qué no es |
|---|---|---|
| 10:43:38 | Retrieve sin filtro de URI. `top_k` 8, HYBRID. Entran cinco fragmentos del VF5 y tres de KONE (MonoSpace). Las citas publicadas son solo `chunk_p12_5.txt` y `chunk_p13_2.txt`. | No es un pin del documento 212. |
| 10:43:41 | `manual_suggestion_shown`. Documento `126cda62-64ad-4469-8674-a29f12e38d48`, alcance `tenant_private`. Se publica la primera orientación. | Recomendación. No aplica el manual como foco. |
| 10:43:47 | `manual_focus_confirmed` del mismo uid. URI `s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf`. El foco queda documento 212, nombre VF5, `added_at` esa hora. | Selección explícita. |
| 10:43:48 | Segundo Retrieve del mismo mensaje, `top_k` 3, filtro de esa URI. Segunda orientación publicada a las 10:43:53. | Aplicación del manual ya elegido. |

T2–T5 conservan ese foco. Su filtro es la URI del VF5. No hay otra sugerencia ni otra confirmación.

## Turnos evaluados

El episodio, antes de T1, no tiene objetivo, observaciones, comprobaciones ni pregunta pendiente.

| Turno | Hora −03 | Request | Correlación |
|---|---|---|---|
| T1, sin pin | 10:43:38 | `f759b2a9-bb50-4d7c-8965-ef1797cd5c8d` | `query:ee71eb83-e043-4256-b7bd-576c4d791895` |
| T1, con pin | 10:43:48 | `6d0691f7-d6ce-43ce-869a-d841a9925133` | la misma, más el Retrieve `query:c7adc016-cfbe-4589-b35a-2ce08ba65242` |
| T2 | 10:44:19 | `a0d2407a-4176-4e09-8ab7-93c58c3da10d` | `query:d01c5d37-918f-48d8-b6fe-2c2c7fa3e09a` |
| T3 | 10:45:29 | `e40a8445-f605-4eeb-9630-c8cee1974dc7` | `query:22c456f0-f4f8-439c-9f51-15f36553c43f` |
| T4 | 10:47:05 | `603a12cc-95bd-4ef5-ab3d-0ce79b5534d3` | `query:cc4748e4-21c1-46fd-afec-388d03487f87` |
| T5 | 10:47:33 | `3328a88a-b63b-4165-8987-3fbbd52bd704` | `query:1a776233-255e-403d-92a2-dad28c7d463a` |

`1ad3c2f2-05d3-4628-9705-873f9b8ce7c2` es solo la apertura del request de T1. `8fc9b2d9-2713-444a-8337-87437f8c1deb` es `pinned_documents#create`, sin mensaje. No son turnos del guion.

| Turno | Esperado | Observado | Evaluación |
|---|---|---|---|
| T1 | Orientar la reapertura. #54 y mediciones pendientes. La obstrucción no es una comprobación hecha. El LED STATUS apagado no se aplica. | Percepción `report`. Las dos respuestas publican los pasos de «La puerta se re-abre sola», dejan #54 pendiente y separan el síntoma del LED STATUS apagado. La pregunta queda «¿Está activada la fotocélula o la entrada de re-apertura (#21)?». | Cumple. La primera respuesta es anterior a la selección; la segunda ya usa el pin. |
| T2 | Encendido sustituye a apagado. El indicador sigue sin identificar. La pregunta de cuál LED queda junto a #21. | Percepción `correct`. Observación vigente «el LED está encendido». «Apagado» ya no está. O3→S2.14, «El LED está encendido, indicando condiciones apropiadas de trabajo.», ítem Estado, se rechaza por `led_context`. | Cumple. |
| T3 | Fotocélula aparte de #21. Orientación documentada. Ninguna identificación implícita del LED. | Percepción `report`. Comprobación hecha, resultado «no está activada». #54 y mediciones siguen `not_done`. La obstrucción no está `done`. La pregunta publicada es «¿Está activada la entrada de re-apertura (#21)?». O3→S3.9, la lectura que unía el LED encendido con la frase del indicador, se rechaza por `ungrounded:documentacion,dice` y no se publica. | Cumple. |
| T4 | Seguir el caso. «¿Qué sigue?» no es una observación. No citar STATUS. | El primer intento del intérprete cae por `Net::ReadTimeout`. El segundo queda `follow_up`, válido, sin observaciones nuevas. Publica el apartado, la fotocélula ya informada y #54 pendiente. Pregunta #21. | Cumple. El timeout es un reintento, no un fallo del criterio. |
| T5 | Desconocimiento de #21 y del contacto #21–#23 sobre esa pregunta. No repreguntar. La aclaración del LED sigue pendiente. | Percepción `report`. `r: unknown` sobre «¿Está activada la entrada de re-apertura (#21)?». El texto del desconocimiento nombra #21 y el contacto. La pregunta del contacto se rechaza por `declared_unknown`. El pendiente pasa a «¿Cuál LED está encendido, el de Fotocélula o el de Estado?», con los dos ítems. | Cumple. |

## Estado del LED y de #21

En T2 el pendiente es «¿Está activada la fotocélula o la entrada de re-apertura (#21)?», destino «La puerta se re-abre sola.», `chunk_p12_5.txt`, página 12. En `shown` queda «¿Cuál LED está encendido, el de Fotocélula o el de Estado?», destinos «Fotocélula.» y «Estado.», los dos en `chunk_p7_3.txt`, página 7. Las dos preguntas están en el texto publicado. No hay «parpadeante». La observación no dice fotocélula ni Estado.

En T3 el pendiente pasa a «¿Está activada la entrada de re-apertura (#21)?». `shown` no cambia. El destino de #21 es el ítem «Fotocélula.», `chunk_p7_3.txt`, página 7: ahí vive la frase citada, no una identificación del LED observado. La comprobación de fotocélula es otra fila, `done`, «no está activada».

En T4 el pendiente y `shown` siguen igual. «¿Qué sigue?» no está entre las observaciones. El texto no repite la pregunta del LED; el episodio sí la conserva.

En T5 el `unknown` no apunta a «¿Cuál LED…?». Al cerrar #21, esa pregunta ocupa el pendiente, con los dos destinos. El texto publicado no la repite. Eso es presentación: el dato queda en el episodio.

## Fidelidad

Las citas publicadas están en los cuerpos recuperados de esa URI. No se exige la misma redacción que en las 15:00.

- T2 cita «La puerta se re-abre sola» y los pasos de obstrucción, fotocélula y #54 desde `chunk_p12_5.txt`. La única lectura de Danebo aceptada es «La puerta se reabre sola durante el cierre.». La lectura del LED de Estado no se publica. `chunk_p7_3.txt` sí trae el parpadeo de Estado; la respuesta no lo usa.
- T3 cita esa misma orientación y, como [3], «Indicador LED y relé activado cuando la fotocélula o la entrada de re-apertura está activada», presente en `chunk_p7_3.txt`. Es cita del fabricante. La pregunta que sigue es solo #21. No aparece «pero el LED está encendido» ni «El LED se activa cuando…».
- T4 cita el apartado y #54 desde `chunk_p12_5.txt`. No hay lectura del LED ni la frase STATUS «no obedece a las señales».
- T5 cita el ítem «Fotocélula» en `chunk_p7_3.txt` y otra vez el apartado. La frase publicada es «la indicación de «Fotocélula» depende de ese dato». El `unknown` guardado es la pregunta de #21. No publica la función del indicador aplicada al LED observado. La lectura que explicaba el contacto #21–#23 se rechaza por `operation`.

`chunk_p12_4.txt` entra en T3 y T5. Su paso «Comprobar si el LED de la fotocélula esta activado» pertenece a otro síntoma y no se publica como dato de este LED.

En el Retrieve sin pin de T1, tres fragmentos KONE quedaron `accepted` por corpus compartido y no se citaron. No seleccionan el VF5.

## Fuera de la muestra

`ep_032b31a16efcf861`. El foco del documento 212 ya estaba desde `2026-10-28T10:35:17-03:00`, antes del primer envío.

| Hora | Correlación | Qué pasó |
|---|---|---|
| 10:35:42 | `query:6665916d-164c-4102-aa31-1fb4f9d45971` | El intérprete recibe `ServiceUnavailableException`. No hay Retrieve. El texto publicado es «No pude interpretar este mensaje». |
| 10:40:55 | `query:3b4e6aee-19b6-4771-9bee-4c6890bd4901` | El mismo T1, ya con el pin. Publica la orientación y acepta «¿Está activado el LED de la fotocélula o hay alguna señal de re-apertura (#21) activa continuamente?». |
| 10:42:30 | `query:225b7775-b774-43ea-9298-a635ae4f0705` | T2. «Apagado» sale. La pregunta del LED queda en `shown`. El guion no sigue. |

Ese episodio no es el guion de cinco frases. No cambia el dictamen de `ep_71e5c284b0315a41`.
