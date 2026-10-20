# Ejecución local: Fermator VF5+, la puerta se reabre sola

**Veredicto:** recorrido completo de los siete mensajes y de la republicación del primero. No es candidato a aceptación textual. No declara `EPISODIO_VALIDADO`.

**Fecha:** 2026-10-19, noche local. El identificador de captura usa el UTC `20261020T0238Z`.

**SHA inicial:** `5ad6d38812d806ba72129d316b5f68e13b37c316`.

**Matriz, sin cambios de mensajes:** [CASO_FERMATOR_VF5_REABRE_SOLA_2026-10-19.md](CASO_FERMATOR_VF5_REABRE_SOLA_2026-10-19.md).

**Preflight anterior, conservado:** [EJECUCION_FERMATOR_VF5_REABRE_SOLA_2026-10-19.md](EJECUCION_FERMATOR_VF5_REABRE_SOLA_2026-10-19.md). Aquella pasada se detuvo antes del primer mensaje. La autorización para leer `Y7RZWMFJSR` desde la aplicación y las bases locales ya existía. Este archivo no sustituye ese registro.

## 1. Resultado

Los siete mensajes exactos de la matriz se enviaron desde la interfaz web local. El clic de la tarjeta republicó el primer mensaje. Una sesión, un episodio y un manual se mantuvieron hasta el turno 7.

El primer fallo semántico está en la respuesta publicada del turno 1 y se repite. Con Fermator ya conocido y `DOCUMENT_IDENTITY_SCOPE_ENABLED` apagado, `BedrockRagService#document_identity_scope_result` cierra la ruta antes del Retrieve de generación y publica la abstención de fragmentos. Esa bandera no formaba parte del entorno autorizado de esta pasada y no se encendió para obtener un aprobado.

El turno 4 no aplicó la corrección del LED. Publicó una repregunta y el episodio dejó vigente «el LED de fotocélula está apagado».

No hubo pérdida de sesión, de episodio ni de foco. La captura de cada request quedó en disco. El cupo no se alcanzó. No hubo una segunda pasada ni un cambio de producto entre turnos.

## 2. Respuestas publicadas

El texto de abajo es el que quedó en `conversation_history` de la sesión 198. La interfaz añadió el rótulo «Guía Danebo» y el pie «Asistencia de consulta al manual — verifica cualquier acción sobre seguridades contra el manual antes de ejecutarla.» Ninguna respuesta publicó citas ni pasajes.

| Pieza | Correlación | Respuesta publicada |
|---|---|---|
| Turno 1 | `query:717a8c06-e9d8-4697-b7d0-217232312ad3` | Ese dato no aparece en los fragmentos de manual recuperados para esta consulta. |
| Republicación | la misma correlación, `focus_ids` `[122]` | Ese dato no aparece en los fragmentos de manual recuperados para esta consulta. |
| Turno 2 | `query:f8cc4dc0-dab2-4468-b3cb-79fb2dbd53d6` | Ese dato no aparece en los fragmentos de manual recuperados para esta consulta. |
| Turno 3 | `query:decbf774-95b3-4959-a9a7-ff72789c7c18` | Ese dato no aparece en los fragmentos de manual recuperados para esta consulta. |
| Turno 4 | `query:82df46a4-8104-4038-8f58-7c22a17a6099` | ¿Qué dato del equipo quieres corregir? |
| Turno 5 | `query:661ec53c-6485-4b80-b518-2bb51f43646e` | Ese dato no aparece en los fragmentos de manual recuperados para esta consulta. |
| Turno 6 | `query:2b3f2342-b8d7-495c-8d30-d9f1e31b6b48` | Ese dato no aparece en los fragmentos de manual recuperados para esta consulta. |
| Turno 7 | `query:9898bda7-27ed-4f25-b2fd-0d44469d2d08` | Ese dato no aparece en los fragmentos de manual recuperados para esta consulta. |

Los mensajes enviados coinciden con los de la matriz, incluidas las comillas del turno 2. No se adaptaron.

La tarjeta del turno 1 mostró el uid `126cda62-64ad-4469-8674-a29f12e38d48`, el nombre VF5 y el botón «Dejar este manual seleccionado». Tras el clic, el estado visible fue «Manual enfocado». En el mismo instante el atributo `data-focused` del botón seguía en `false`. El servidor sí guardó el foco. Hecho de interfaz y hecho de fila, los dos observados.

## 3. Criterios

Juicio por significado, continuidad y respaldo. La abstención no se convierte en cumplimiento porque tampoco prescribe un reemplazo.

| Criterio | Resultado | Hecho observado |
|---|---|---|
| Episodio del inicio limpio conservado hasta el turno 7 | Cumplido | `ep_f69a3833934c3a08` en los siete turnos y en la republicación. Estado final `active`. |
| Un manual, el uid acordado, desde el clic | Cumplido | Foco `kb_document_id` 122, URI `s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf`, desde la republicación hasta el turno 7. |
| Turno 1 conserva equipo, síntoma y las dos ausencias en la respuesta | Fallido | La respuesta publicada es la abstención. El episodio sí guardó Fermator, VF5+, «operador de puerta» y el síntoma. |
| Turno 1 ofrece la tarjeta de ese uid y no selecciona sola | Cumplido | La tarjeta apareció antes del clic. `focus_ids` del primer assistant quedó `[]`. |
| Turno 1 no diagnostica ni indica reemplazo | Cumplido en la respuesta | La abstención no nombra causa ni reemplazo. No orienta con el manual. |
| Tres comprobaciones de 8.2, página PDF 12, distintas de resultados y del otro síntoma | Fallido | Ninguna respuesta las cita. `chunk_ids` de la evidencia de turno quedó vacío. |
| Desde el turno 4 el LED vigente es encendido | Fallido | El turno 4 preguntó qué dato corregir. La observación final sigue siendo «el LED de fotocélula está apagado». |
| «No observo una obstrucción» no se convierte en descarte | No observado como descarte | La frase quedó guardada como observación. La respuesta no la trata. |
| Sensibilidad de reapertura pendiente | No observado en la respuesta | El episodio guardó «No he revisado la sensibilidad de reapertura». La respuesta no lo dice. |
| Datos marcados como simulados y separados del manual | Fallido en la respuesta | Las observaciones guardan la frase sin la palabra «simulado». Las respuestas no distinguen dato y manual. |
| Turno 5 explica la diferencia de SW4 y no aplica un modo | Fallido | Abstención. No aplica máster ni esclavo, y tampoco explica la sección 4. |
| Turno 6 conserva SW4 OFF esclavo simulado, explica la maniobra y no manda cambiar VF ni SW4 | Fallido | El episodio guardó «SW4 está en OFF, modo esclavo». La respuesta no explica el modo ni la maniobra. Tampoco prescribe el cambio. |
| Turno 7 resume corrección, configuración y pendiente, sin reparación | Fallido | Abstención. El episodio sigue `active` y el foco sigue en el uid. La respuesta no dice que la puerta quedó reparada. |
| Citas de los pasajes recuperados en la respuesta | No observado | No hay citas publicadas. |

## 4. Datos locales y procedencia

Cuenta usada: `accounts.id` 1, slug `index-account-1`. Los chunks leídos en la KB de producción traen `account_id` `1`. La cuenta del host `localhost`, id 4 y slug `danebo-legacy`, no es la cuenta de esos chunks. Usuario local id 27, de esa cuenta 1. No se inventó `bulk_upload_asset`. No se copió otra tabla de producción. No se cambió la política de autorización ni el discovery.

`kb_documents` id 122, creada en `smart_deal_development` porque no existía fila con ese uid ni esa clave:

| Campo | Valor | Procedencia |
|---|---|---|
| `account_id` | 1 | Cuenta local ya existente, la misma identidad de catálogo que el manual |
| `document_uid` | `126cda62-64ad-4469-8674-a29f12e38d48` | `config/document_identities.yml` y el encargo |
| `s3_key` | `bulk_uploads/1/2026-08-31/VF5.pdf` | Identidad de catálogo y objeto ya existente |
| `display_name` | VF5 | Identidad de catálogo |
| `knowledge_scope` | `tenant_private` | Validación de fila nueva. No se aplicó un cambio de alcance |
| `size_bytes` | 1271591 | PDF del repositorio `docs/field_companion/fuentes/VF5.pdf` |
| `aliases` | `[]` | Sin alias inventados |

El SHA-256 del PDF del repositorio es `be7a39a3490c92c8381cb883402760cb07d10b0a3beda5348bed22f72abedf72`. `KbDocument` no tiene callback de ingesta. El conteo de `solid_queue_jobs` no cambió con el alta. No hubo escritura S3.

Para repetirla, en la base local y solo si el uid no existe: crear esa fila con esos campos. No usar `ensure_for_s3_key!`, porque acuñaría otro uid. No es una migración.

Sesión 198, creada con `ConversationSession.find_or_create_for` para la cuenta 1, canal `web`, `identifier` `"27"` y el usuario 27. Las otras sesiones no se borraron. El dry-run y el `APPLY` de `field_companion:start_clean_case` dejaron el episodio `ep_f69a3833934c3a08`, abierto `2026-10-19T23:37:54-03:00`, historial vacío, foco vacío y trabajo pendiente 0. La copia previa está en `tmp/field_companion/clean_starts/20261020T023754Z_e190eaf8_session_198.json`.

El discovery, con la cuenta 1 y la pregunta del turno 1, devolvió una tarjeta de ese uid y del documento 122. El pin resolvió la misma fila por la ruta normal.

El navegador tiene que usar un host que no esté en el mapa de development, con `DEV_TUNNEL_FALLBACK_ACCOUNT_SLUG=index-account-1`. `http://index.localhost:3000` cargó la cuenta 1. `127.0.0.1` carga `danebo-legacy`. El proceso tiene que exportar `KNOWLEDGE_BASE_S3_BUCKET=multimodal-source-destination` antes de arrancar, porque `KbDocument::KB_BUCKET` se congela al cargar la clase. Con el bucket del `.env` el pin apuntaría a `smart-deal-dev-kb` y no coincidiría con `original_source_uri`. El `.env` no se modificó. Foreman arrancó con `bin/dev -e /dev/null` para no dejar que ese archivo pise el prefijo.

`bin/dev` se caía porque `tailwindcss:watch` terminaba con código 0 y Foreman detenía web y worker. Mantener abierta la entrada estándar con `tail -f /dev/null | bin/dev -e /dev/null` dejó los tres procesos vivos. No se cambió `Procfile.dev`.

## 5. Configuración efectiva

Web, Puma en modo single, PID 25961, el mismo desde el arranque hasta el cierre del turno 7. El ledger es de ese proceso. No se reinició durante el recorrido. Los hilos comparten el mutex. El worker de Solid Queue arrancó como proceso aparte y no registró invocaciones de modelo en el log de Foreman. Sus contadores no se suman al cupo.

El host `index.localhost` resolvió `index-account-1` en el request de alta de sesión. El primer `ask` imprimió `Knowledge Base ID: Y7RZWMFJSR` y `Model ID: global.anthropic.claude-haiku-4-5-20251001-v1:0`. El modelo no se cambió.

Prefijo de web y worker, heredado por Foreman con `-e /dev/null`:

- `BEDROCK_KNOWLEDGE_BASE_ID=Y7RZWMFJSR`
- `KNOWLEDGE_BASE_S3_BUCKET=multimodal-source-destination`
- `SHARED_SESSION_ENABLED=false`
- `FIELD_COMPANION_EPISODE_ENABLED=true`
- `FIELD_COMPANION_TURN_ENABLED=true`
- `RAG_EPISODE_SCOPE_ENABLED=true`
- `HAIKU_QUERY_ANALYSIS_MODE=owner`
- `AWS_MAX_ATTEMPTS=1`
- `RAG_LOCAL_PASS_GUARD=1`
- `RAG_LOCAL_PASS_CALL_CAP=24`
- `RAG_LOCAL_PASS_COST_CAP_USD=1`
- `RAG_VALIDATION_CAPTURE_RUN=vf5-reabre-20261020T0238Z`
- `DEV_TUNNEL_FALLBACK_ACCOUNT_SLUG=index-account-1`

Bases: `smart_deal_development`, `smart_deal_development_cache`, `smart_deal_development_queue`, `smart_deal_development_cable`, en localhost. `DOCUMENT_IDENTITY_SCOPE_ENABLED` no se exportó. El flag solo se enciende con el valor `true`.

La captura se abrió en cada `POST /rag/ask` y en el `POST /pinned_documents`. Nueve directorios, uno por request, bajo `tmp/field_companion/validation_captures/vf5-reabre-20261020T0238Z/`. El ledger de cada uno muestra `missing` vacío, tope 24 y US$1. El último request deja `attempts` 7 y `priced` 7. No se mezclaron requests.

El filtro que la ruta de respuesta no llegó a usar es el del pin. El Retrieve observado es posterior a la abstención y pertenece al discovery de la tarjeta o del aviso de foco. En la republicación el filtro impreso fue el `or_all` de cuenta `1`, cuenta compartida `4` sin foto y sin `manual_corpus=account`, o `manual_corpus=general`. `filter_applied` quedó `false` y `route_taken` fue `document_discovery`. Devolvió tres resultados, dos de `VF5.pdf` y uno de `manual-cea15p.pdf`, los tres `KEEP` por `owner`. No entraron en `chunk_ids` de la respuesta. No se sustituyó el filtro ni se buscó sin filtro para ocultar un error. No hubo `ValidationException` en esta pasada. El `ValidationException` del preflight anterior coincidió con Aurora reanudándose y no se usa aquí como defecto del filtro.

## 6. Llamadas, tokens y costo

Siete invocaciones de modelo, todas `converse` del intérprete, fuente `semantic_analysis`, `token_source` `provider_usage`, modelo `global.anthropic.claude-haiku-4-5-20251001-v1:0`. Precio existente de Haiku global: entrada 0,001 y salida 0,005 por mil tokens. `BedrockQuery#cost` y el ledger coinciden.

| Id | Correlación | Entrada | Salida | Latencia ms | Costo |
|---|---|---:|---:|---:|---:|
| 5184 | turno 1 | 2176 | 237 | 2753 | 0,003361 |
| 5185 | turno 2 | 2277 | 106 | 2038 | 0,002807 |
| 5186 | turno 3 | 2292 | 221 | 2562 | 0,003397 |
| 5187 | turno 4 | 2313 | 126 | 1661 | 0,002943 |
| 5188 | turno 5 | 2329 | 108 | 1686 | 0,002869 |
| 5189 | turno 6 | 2324 | 159 | 1792 | 0,003119 |
| 5190 | turno 7 | 2328 | 106 | 1410 | 0,002858 |
| | Total | 16039 | 1063 | | 0,021354 |

No hubo generación `retrieve_and_generate`, ni reintento de modelo, ni llamada de calentamiento de generación. El cupo de 24 llamadas y US$1 no se alcanzó. `held_usd` terminó en 0 porque el uso del proveedor liquidó cada `converse`.

Las lecturas `Retrieve` de discovery no pasan por el ledger ni por `bedrock_queries`. Su precio no está en la telemetría existente. No se declaran gratuitas: el costo queda no disponible. Las lecturas de preparación anteriores a esta pasada, incluido el `Retrieve` que encontró Aurora en reanudación, tienen el mismo tratamiento.

El episodio, al cierre, conserva el síntoma, el LED apagado, la frase de obstrucción, la sensibilidad no revisada y SW4 OFF. No sustituyó el LED. No marca esas frases como simuladas.

## 7. Código, pruebas y recorrido real

`Rag::LocalPassLedger`: `RAG_LOCAL_PASS_GUARD=1` es la solicitud aunque los topes falten o estén mal formados. `protect!` y `single_attempt!` rechazan antes del SDK y nombran el requisito ausente (`RAG_LOCAL_PASS_CALL_CAP`, `RAG_LOCAL_PASS_COST_CAP_USD`, `AWS_MAX_ATTEMPTS` o `local_process`). Sin la variable, el bloque sigue y no cuenta. Con el guard armado, los límites se aplican.

`BedrockRagService#local_retrieve_and_generate` liquida el cupo con el uso del proveedor si existe y, si no, con `AnthropicTokenCounter::LocalTokenizer` sobre las hojas de texto del request, el texto citado y la salida. Una estimación cero deja el techo contractual. Esta pasada no ejerció esa liquidación: no hubo `retrieve_and_generate`.

Cada prueba borra esas variables al empezar y las restaura al terminar, para que un proceso con el guard exportado no deje armado el caso que espera la ruta normal. Pruebas con dobles, una corrida de `local_pass_ledger_test`, `web_validation_capture_test` y `web_request_capture_test`: 14 runs, 239 aserciones, 0 fallos, semilla 33150. Incluyen cero llamadas al doble cuando el guard está pedido y falta o es inválido `AWS_MAX_ATTEMPTS`, el tope de llamadas o el tope de costo. RuboCop de esos archivos, sin caché: 0 ofensas.

El recorrido real usó Chrome local contra `http://index.localhost:3000`. Computer Use no tenía permisos de accesibilidad ni de grabación de pantalla. Selenium pulsó el formulario de acceso, el botón Enviar y el botón de la tarjeta. Tras el turno 2 el controlador perdió el nodo porque el DOM ya había cambiado. El servidor ya había guardado ese turno. Un segundo Chrome volvió a entrar con el mismo usuario, sin `start_clean_case` y sin reenviar los turnos 1 y 2, y envió los turnos 3 a 7. La ventana nueva no mostraba las burbujas anteriores. El historial de la sesión 198 sí las tiene.

## 8. SHA, archivos y árbol

SHA inicial: `5ad6d38812d806ba72129d316b5f68e13b37c316`. El SHA final es el commit que añade este archivo.

Evidencia fuera de Git, en `tmp/field_companion/`:

- `validation_captures/vf5-reabre-20261020T0238Z/`
- `vf5_20261019/` con el progreso del navegador, las capturas de pantalla y los JSON de cada turno
- `clean_starts/20261020T023754Z_e190eaf8_session_198.json`
- `vf5_browser_login.txt`, credencial local, modo 0600

No hay push ni deploy. El `.env` no se modificó.

## 9. Siguiente acción mínima

Decidir si una identidad de equipo conocida, con `DOCUMENT_IDENTITY_SCOPE_ENABLED` apagado, puede cerrar la respuesta antes de consultar el manual que el técnico ya enfocó. Mientras esa ruta siga igual, otra pasada de los siete mensajes vuelve a publicar la misma abstención. La corrección del LED, que el episodio no sustituyó, queda dentro de esa misma revisión y no justifica un parche entre turnos. No declarar aceptación textual ni `EPISODIO_VALIDADO`.
