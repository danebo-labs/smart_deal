# Fermator VF5+: correcciones de estado y secuencia, 2026-10-20

No es aceptación textual. No declara `EPISODIO_VALIDADO`. No recorre los siete turnos. El benchmark de generación queda aparte: [BENCHMARK_HAIKU_SONNET_VF5_2026-10-20.md](BENCHMARK_HAIKU_SONNET_VF5_2026-10-20.md).

## Qué cambió en el código

Tres correcciones, sin excepción para Fermator y sin respuesta fija.

- El objetivo ya no parte una observación guardada por la «y» interna. Después de corregir el LED, el objetivo queda en «en funcionamiento normal la puerta empieza a cerrar y vuelve a abrirse sola».
- «el LED está apagado», cuando hay un solo LED cualificado retractado, se guarda como «LED de fotocélula está apagado».
- Si el historial tiene una línea del asistente, el contexto dice que esa línea es una conclusión anterior, no un reporte del técnico ni un hecho confirmado.

Los dobles están en `work_context_reducer`, `turn_perception_test` y `session_context_builder_test`. No llaman a AWS.

## Primera pasada, inválida para el manual

Run `vf5-corrected-20261020T184008Z`, episodio `ep_e2e688df7d747176`, sesión 198. El pin escribió `s3://smart-deal-dev-kb/.../VF5.pdf` porque `KbDocument::KB_BUCKET` salió del `.env` al arrancar. La política de recuperación quedó `no_compatible`. Las tres respuestas dicen que falta el manual e inventan causas. No miden la generación con el cuerpo del VF5. Seis invocaciones, US$0,019271. El archivo de cupo no se reinició.

## Pasada con el bucket indexado

El proceso arrancó con `KNOWLEDGE_BASE_S3_BUCKET=multimodal-source-destination` y `SHARED_SESSION_ENABLED=false`. No se editó `.env`. Run `vf5-corrected-20261020T184147Z`, episodio `ep_c1d63fc0e8275734`, sesión 198, cuenta `index-account-1`, usuario 27. Haiku 4.5 en intérprete y generación: `global.anthropic.claude-haiku-4-5-20251001-v1:0`. KB `Y7RZWMFJSR`. Modo `owner`. Foco del documento 122, URI `s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf`. La ruta es la de `record_user_turn!`, `execute_rag_query` y `record_assistant_turn!`, no una segunda ventana del navegador.

| | Turno 1 | Turno 2 | Turno 3 |
|---|---|---|---|
| Request | `ae305e38-56fe-4dbf-8599-7bc585c00104` | `b8fd0290-5a93-4210-bf54-c2fb89c4b685` | `5a604a08-ae87-488a-abb2-07481a1bf3b9` |
| Política | `scoped`, páginas 12, 13 y 5 | `scoped`, páginas 12 y 5 | `scoped`, páginas 12, 13, 5, 1 y 4 |
| Objetivo | Síntoma, LED encendido y la observación de obstrucción | Síntoma completo, con «vuelve a abrirse sola» | El mismo |
| LED vigente | encendido, de fotocélula | `LED de fotocélula está apagado` | El mismo |
| Generación | 8129 / 526, US$0,010759 | 7421 / 445, US$0,009646 | 10053 / 578, US$0,012943 |
| Intérprete | US$0,004052 | US$0,003066 | US$0,002862 |

El prompt del turno 1 tiene el mismo SHA-256 que el del benchmark: `5dc531b35ab27d69df989d0d09de57e247108bab07b3ce14652d01e029fda306`. Las correcciones de estado no podían cambiar esa entrada. El turno 2 ya lleva el objetivo completo, el LED cualificado y la nota del historial. También vuelve a traer la página 5, con el ejemplo de SW4 y la nota que el PDF no contiene. El turno 3 conserva ese objetivo y ese LED.

## Criterios decisivos de esta pasada

Siguen fallando.

- Turno 1: «Ya has descartado la obstrucción mecánica». «Esta es la causa más probable». El ejemplo de los bornes 36, 37 y 38 queda como el mecanismo de esta reapertura. Pide limpiar la fotocélula.
- Turno 2: «Ya has descartado la obstrucción mecánica». El LED apagado «sugiere que la fotocélula no está detectando obstrucción». Llama al `#54` causa probable. Repite el ejemplo de SW4, que esta vez sí está en el prompt.
- Turno 3: separa el reporte y nombra «LED de fotocélula apagado», sin convertirlo en LED STATUS. Después dice que la observación visual «cubre» la comprobación de obstrucción y pide medir los bornes 36, 37 y 38.

La nota del historial está en los turnos 2 y 3. No impide que la respuesta vuelva a publicar el descarte. La sensibilidad sigue pendiente y el episodio no registra una reparación. Eso no alcanza para continuar la regresión de siete turnos.

## Cupo

48 invocaciones y US$4, compartido con el benchmark. Al cerrar: 18 invocaciones, US$0,194311, cero bloqueos. El benchmark usó 6 y US$0,131712. La pasada con el bucket de desarrollo usó 6 y US$0,019271. Esta pasada usó 6 y US$0,043328. No se reinició el archivo.

## Qué queda

El estado del caso ya conserva el síntoma y el referente del LED. La generación, con el mismo manual y las mismas discrepancias de chunk, sigue convirtiendo la observación en una comprobación hecha y el ejemplo de SW4 en el mecanismo de este equipo. El siguiente encargo mínimo es ese contrato de generación: una observación del técnico no cierra la comprobación del manual, y un ejemplo o una nota añadida al chunk no se presentan como el mecanismo confirmado de este trabajo. Sin hardcodear Fermator, sin reescribir el corpus y sin declarar `EPISODIO_VALIDADO`.
