# Registro de versiones — Danebo Vertical, 5 de noviembre de 2026

Referencia de la ejecución de este día. No despliega, no arranca la instancia y no
cambia el valor por defecto de la generación.

## Qué se observó

La instancia `i-09db5c5fc53e973b0` (`t3.medium`, IP elástica `54.163.248.39`) está
`stopped`. `elevator.danebo.ai` y `danebo.ai` resuelven esa IP. SSH al puerto 22 y
`https://elevator.danebo.ai/up` agotaron el tiempo. No se inspeccionó el contenedor
y no se encendió la máquina.

El último tag de `docker.io/lahirisan80/smart-deal` es
`72ee437d8e3518e438591d59b2c5c3614c8d416a`, actualizado el `2026-10-30T23:37:20Z`.
`latest` tiene el mismo segundo (`2026-10-30T23:37:22Z`). No hay un tag posterior.
La instancia había arrancado ese día a las `23:24:38Z`, antes de esa subida. Esa
imagen es el último despliegue observable. El worktree aislado está en
`/Users/lahirisan/smart_deal-prod-72ee437`, HEAD `72ee437`, sin el árbol de trabajo
de `main`.

`config/deploy.yml` del portátil tiene fecha de modificación posterior
(4 de noviembre) y no se leyó desde el contenedor parado. Describe la intención
del operador, no el entorno que quedó congelado en el último `docker create`.

## Cuatro puntos

| Punto | SHA | Qué es |
|---|---|---|
| Aceptación histórica del guion 1 | `4a6deb9ecc81752479fdbbd0a53ac06ef13dacbc` | Imagen `docker.io/lahirisan80/smart-deal:4a6deb9ecc81752479fdbbd0a53ac06ef13dacbc`. Episodio `ep_63de315872dfed14`, sesión 128, cuenta `danebo-legacy`, documento 212, pin `s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf`. Modelo `global.anthropic.claude-haiku-4-5-20251001-v1:0`. Informe: [INFORME_GUI_VF5_4a6deb9_2026-10-29.md](INFORME_GUI_VF5_4a6deb9_2026-10-29.md). Alcance: continuidad de T2 a T5 de ese guion y separación de la cita `[4]`. No es estabilidad general ni aceptación del guion 2. |
| Producción observada | `72ee437d8e3518e438591d59b2c5c3614c8d416a` | Última imagen en el registro y tag `latest`. Ancestro de `origin/main`. El contenedor no estaba en ejecución. |
| Main remoto | `49e6cfcd11c159722115da130d4d84547eef8e3b` | `origin/main`. No tiene tag en Docker Hub. No está desplegado. |
| HEAD local | `1ba0d91d2ae47a7c42688b546072ee8286ca9966` | Un commit por delante de `origin/main`, más la candidata direct sin commit. |

`4a6deb9` es ancestro de `72ee437`, y `72ee437` es ancestro de `49e6cfc` y de `1ba0d91`.

## Imagen desplegada frente a la aceptación

Entre `4a6deb9` y `72ee437` solo entra documentación del companion y el filtro de
páginas por lotes (`72ee437`, Haiku 5.5, escaneo sobre el PDF original). El
recorrido conversacional del companion en esa imagen es el de `4a6deb9`. El guion 1
aceptado el 29 de octubre sigue siendo la evidencia equivalente de ese recorrido
sin pensamiento extendido. El guion 2 no se ejecutó sobre esa imagen.

Intención del `deploy.yml` local, no leída del contenedor: KB `Y7RZWMFJSR`, bucket
`multimodal-source-destination`, modelo Haiku 4.5 global, `RAG_COMPANION_TURN=1`,
episodio y turno activos, `DOCUMENT_IDENTITY_SCOPE_ENABLED=true`,
`SHARED_SESSION_ENABLED=false`. No hay `RAG_COMPANION_GENERATION`: el valor por
defecto sigue siendo el plan. `HAIKU55_PAGE_FILTER=1` está en ese archivo; no
consta que el contenedor del 30 de octubre lo tuviera.

## Qué hay en main y no en la imagen

`72ee437..origin/main`, y el commit local `1ba0d91`.

### Contrato de respuestas

Conserva el texto publicado y evita repetir una parte ya respondida aunque el
planificador cambie la referencia.

- `0a4b3dc` guarda el texto de cada respuesta con referencia al historial.
- `70dfd38` selecciona la versión del contrato al abrir el episodio.
- `ac32007` impide repetir partes respondidas.
- `e1d9d87` integra esa rama en main.
- `a80b787` abre los episodios nuevos con el contrato vigente.
- `65b3c84` conserva la aclaración y el dato no identificado del guion aceptado.
- `f7ad716` representa un desconocimiento ajeno a la parte publicada.
- `6c518bd` compara offsets solo dentro del mismo mensaje.
- `4d65956` guarda el informe de respuestas junto a la correlación.

### Recuperación

Hace entrar el apartado 5.8 en la ventana del turno con manual fijado.

- `22aa8f7` da al turno con pin su propia ventana, todavía de 3, y un tope de
  16_000 caracteres. 12_000 quitaba la página que cita el T5 de la regresión.
- `1448ad8` registra la sonda: `chunk_p8_1` queda en el puesto 15 y el tope lo
  suelta. No sube la ventana y no corre las fases vivas.
- `716cc82` recupera dieciséis candidatos, los ordena con Cohere aparte del
  Retrieve y no cuenta el registro terminal, para que 5.8 quepa en 16_000 sin
  activar el reranker global.

### Repetición

- `c1f93c6` hace que el checker descarte la pregunta que repite una negación del
  técnico o que cambia «conectado» y «desconectado» por «conexión».
- `e899996` deja pasar la pregunta por el tipo de motor, que el técnico no declaró.

### Applicability

- `99108da` permite al plan decir si una condición del manual aplica a lo ya
  contado. El checker solo cierra esa conclusión cuando las citas cubren la regla.
- `1ba0d91`, solo en HEAD local, baja a parcial una condición marcada como
  descartada cuando la cita no contiene el fragmento, y el texto nombra la acción
  solo si ese fragmento está en la regla.

`49e6cfc` reconoce el escalón de ledger 185 a 194. No cambia la respuesta.

## Qué queda fuera del recorrido direct

La revisión de Fable aprobó sustituir, solo en el turno companion y detrás de
`RAG_COMPANION_GENERATION=direct`, la cadena plan → checker → render por una
redacción sin herramientas. El plan sigue como valor por defecto. Fuera de esa
ruta caliente, a propósito:

- el esquema y el prompt de la herramienta `companion_plan`;
- `CompanionStatements` y los identificadores S/O/G en el prompt;
- `CompanionPlanCheck`, `CompanionPlanRender` y `applicability`;
- `CompanionCaseFacts` como bloque del prompt;
- la pregunta pendiente estructurada dentro del turno companion.

Siguen en el recorrido direct: pin y `KnowledgeScopePolicy`,
`DocumentIdentityScope`, la recuperación de `716cc82` (k=16, Cohere, 16_000,
sin registro terminal), `CompanionDefinitionExpander`, intérprete y episodio,
historial con `full_content` / `prompt_reply`, la compuerta
`CompanionTurnPublication` y el ledger.

La candidata sin commit hace ese corte. `app/services/bedrock_rag_service.rb`
lee `RAG_COMPANION_GENERATION` solo para entrar en direct. El prompt es
`app/prompts/bedrock/companion_direct.txt`, SHA-256
`0bf3610b29f5b839d5f27917bce5b728a47f0d8f0551755fa3f56744a6fc901f`.
`CompanionDirectAnswer` arma un Converse sin `tool_config`, con temperatura 0 y
`max_tokens` 700 en la ruta Bedrock. El historial quita los marcadores `[n]`.
El diff de trabajo también mueve el ledger local (escalón de la corrida direct)
en `assignment_spend.rb` y `local_pass_ledger.rb`. Esos cuatro archivos de ledger
no forman parte de la redacción.

Archivos nuevos de la candidata, además del prompt y del servicio: el runner
`script/field_companion/run_guion2.rb`, el replay
`script/field_companion/replay_direct_prompt_compare.rb`, el soporte de captura,
la comparación Haiku 5.5 y sus pruebas. El texto local del manual,
`docs/field_companion/fuentes/VF5.txt`, SHA-256
`60cd4f7f2b2251b4779e88591602d343985a66d50c266ce8c223e873a03e6c92`,
queda fuera del repositorio.

## Dónde se ejecutó y falló el guion 2

| Corrida | Dónde | Qué pasó |
|---|---|---|
| Sonda del 4 de noviembre, código `22aa8f7` | `tmp/field_companion/vf5_guion2_integrado/`. Informe [INFORME_GUION2_INTEGRADO_20261104T131731Z.md](INFORME_GUION2_INTEGRADO_20261104T131731Z.md) | No hubo generación. `chunk_p8_1` quedó entre los puestos 15 y 21. El tope de 16_000 lo suelta. El guion 2 y la regresión del guion 1 no se ejecutaron. Ese código no está en la imagen `72ee437`. |
| Sesión 268, `ep_60e1f2ed23ab3bd0` | El directorio de evidencia fue reutilizado después | Pin al documento 122 en `s3://smart-deal-dev-kb/...` con la KB `Y7RZWMFJSR`. Retrieve devolvió 0 fragmentos, la política quedó en `no_compatible` y direct no corrió. Seis Converse de intérprete y de fallback. |
| Sesión 269, `ep_c9049e7575c8ee71` | `tmp/field_companion/vf5_direct_guiones/guion2/` | Direct sí corrió, con el pin en `multimodal-source-destination` y la KB productiva. El prompt era el SHA `30297124…`. T1 cita la apertura lenta y manda autoajuste si persiste, con los pasos. T3 responde que no hace falta y afirma que el equipo está calibrado. |
| Replay del prompt `0bf3610b…` | `tmp/field_companion/vf5_direct_prompt_compare/` y `vf5_direct_prompt_compare_sonnet/` | Haiku 4.5 y Sonnet 4.5, tres generaciones cada uno, historial fijo de la sesión 269. Los dos fallan T1 por prescribir o atribuir más allá del síntoma. |
| Haiku 5.5, historial fijo | `tmp/field_companion/vf5_direct_prompt_compare_haiku55/` | Effort `max`, thinking adaptativo. Los tres turnos pasaron la rúbrica corregida. La continuidad con esas respuestas quedó pendiente: T2 y T3 seguían leyendo la sesión 269. Gasto US$0,039005. |

## Base productiva y razonamiento

En el worktree `72ee437`, el plan y el intérprete fuerzan la herramienta
(`tool_choice` con el nombre de la herramienta) y usan temperatura 0. La
generación RAG de esa imagen usa temperatura 0,1. La documentación de Bedrock
de pensamiento extendido dice que no es compatible con temperatura ni con
herramienta forzada: con thinking solo vale `tool_choice` auto o none. Haiku 4.5
no tiene el parámetro `effort` de Haiku 5.5; `xhigh` no aplica. Subir el
razonamiento en esa ruta obliga a quitar la herramienta forzada o la
temperatura, que son el contrato del producto. No se envía esa solicitud.

La evidencia equivalente del guion 1 sin ese cambio sigue siendo la aceptación
de `4a6deb9`. No hay una pasada equivalente del guion 2 en la imagen desplegada.
La ejecución continúa con la candidata direct y Haiku 5.5 por la API de Anthropic.
