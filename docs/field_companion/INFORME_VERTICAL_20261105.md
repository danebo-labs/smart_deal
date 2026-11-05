# Informe Danebo Vertical — 5 de noviembre de 2026

Producción no se tocó. La instancia sigue parada. No hubo deploy ni commit.
El mapa de versiones es [REGISTRO_VERSIONES_VERTICAL_20261105.md](REGISTRO_VERSIONES_VERTICAL_20261105.md).

## Candidata

Ninguna configuración pasó los dos guiones. No hay candidata conservadora ni
candidata final. No se repitieron los guiones.

La base recuperable del guion 1 sigue siendo la aceptación acotada de
`4a6deb9` (`ep_63de315872dfed14`, imagen
`docker.io/lahirisan80/smart-deal:4a6deb9ecc81752479fdbbd0a53ac06ef13dacbc`).
Cubre la continuidad de T2 a T5 de ese guion y la separación de la cita `[4]`.
No cubre el guion 2 ni el código posterior.

## Versiones

| Punto | SHA | Estado |
|---|---|---|
| Aceptación del guion 1 | `4a6deb9` | Histórica y acotada. |
| Última imagen observada | `72ee437` | Tag `latest` del `2026-10-30T23:37:22Z`. Instancia `i-09db5c5fc53e973b0` en `stopped`. El contenedor no se inspeccionó. |
| `origin/main` | `49e6cfc` | No desplegado. Trae contrato de respuestas, recuperación, repetición y applicability. |
| HEAD local | `1ba0d91` | Un commit más (`1ba0d91`, applicability parcial) y la candidata direct sin commit. |

Entre `4a6deb9` y la imagen `72ee437` el companion conversacional no cambia.
Entra el filtro de páginas por lotes. El contrato de respuestas, la recuperación
de dieciséis candidatos, el checker de repetición y applicability están en main
y no en esa imagen.

Fable dejó fuera de la ruta caliente direct el plan, sus identificadores,
`CompanionPlanCheck`, `CompanionPlanRender`, applicability, `CompanionCaseFacts`
como bloque y la pregunta pendiente estructurada. La candidata conserva pin,
alcance, recuperación, definiciones, intérprete, historial y la compuerta.

## Base productiva

No se llamó. En `72ee437` el plan y el intérprete fuerzan la herramienta y usan
temperatura 0. Bedrock documenta que el pensamiento extendido no admite
temperatura ni `tool_choice` forzado. Haiku 4.5 no tiene `effort`; `xhigh` no
aplica. Subir el razonamiento rompería el contrato. No se envió esa solicitud.

El guion 1 sin ese cambio ya está aceptado en `4a6deb9`. El guion 2 no tiene una
pasada equivalente en la imagen.

## Haiku 5.5, respuestas encadenadas

Prompt `0bf3610b…`. Thinking adaptativo con `display: summarized`. `max_tokens`
48000 en todos los turnos. Temperatura omitida. Cliente sin reintentos ocultos.
Ningún reintento. Geo informada `global`.

La recuperación no se repitió. El guion 2 reutilizó las fuentes de las
solicitudes canónicas de la sesión 269. El guion 1 reutilizó los cuerpos de
`ep_63de315872dfed14` y los chunks de definición que esa captura nombra
(`chunk_p8_3.txt`, `chunk_p7_2.txt`). La ventana de 16_000 de la candidata no
soltó ninguno. Cada corrida empezó limpia y encadenó su texto publicado, con
los marcadores `[n]` quitados del historial, como hace `CompanionDirectAnswer`.

El descenso se detuvo en max: el guion 2 no pasó. High y medium no se enviaron.
El guion 1 se corrió igual en max, como registro. No hubo nivel que pasara los
dos, así que no hubo repetición.

Gasto de estas ocho llamadas: **US$0,150027**. Todo liquidado.

| Corrida | Turno | Parada | Entrada | Salida | Thinking | Coste | Latencia |
|---|---:|---|---:|---:|---:|---:|---:|
| Guion 2 max | 1 | end_turn | 8584 | 40764 | 40497 | 0,021240 | 170 s |
| Guion 2 max | 2 | end_turn | 8879 | 30177 | 29851 | 0,015976 | 121 s |
| Guion 2 max | 3 | end_turn | 9528 | 25881 | 25645 | 0,013893 | 106 s |
| Guion 1 max | 1 | end_turn | 3826 | 24372 | 23782 | 0,012569 | 100 s |
| Guion 1 max | 2 | end_turn | 4600 | 37062 | 36517 | 0,018991 | 144 s |
| Guion 1 max | 3 | max_tokens | 5150 | 48000 | 47756 | 0,024515 | 187 s |
| Guion 1 max | 4 | end_turn | 5003 | 36062 | 35569 | 0,018531 | 143 s |
| Guion 1 max | 5 | end_turn | 6992 | 47225 | 46615 | 0,024312 | 190 s |

El thinking es casi toda la salida. En el T3 del guion 1 ocupó 47756 de 48000
y la respuesta visible quedó cortada.

### Guion 2, effort max — no pasa

T1 pasa el criterio que bloqueaba las corridas anteriores. Cita la primera
apertura lenta, cita las dos condiciones del autoajuste y no manda hacerlo
porque «sigue lenta». Pregunta si la siguiente apertura salió a velocidad
normal. La compuerta lo aceptó.

T2 usa que fue solo la primera apertura y concluye que coincide con lo
previsto. Después pregunta si se conectó o desconectó la fotocélula o si se
configuraron los parámetros por defecto. Esa repregunta incumple el cierre del
turno. Es el fallo de contenido que detuvo el descenso.

T3, en el texto crudo, concluye que no hace falta repetir el autoajuste, cita
la frase con «Solo» y las dos condiciones, y separa el corte de alimentación.
La compuerta lo rechazó por R2 `condition_dropped:configuración de los parámetros
por defecto`. Lo publicado fue la abstención. El técnico no ve la conclusión.

### Guion 1, effort max — no pasa

T1 orienta con «La puerta se re-abre sola», deja «no veo obstrucción» como
observación, deja #54 pendiente y hace una sola pregunta por el LED. Añade una
hipótesis propia sobre un contacto entre 21 y 23. La compuerta aceptó.

T2 toma el LED encendido, retira la inferencia del apagado y no convierte el
parpadeo ni STATUS en un hecho. La compuerta aceptó.

T3 se truncó. El texto visible alcanza a dejar pendientes #54 y la obstrucción.
R4 rechaza `max_tokens` y se publica la abstención. T4 y T5 encadenan esa
abstención, no el texto cortado.

T4 sigue por #54, da por cubierta la fotocélula no activada y no repite toda
la orientación. La compuerta aceptó.

T5 explica el LED, #21 y el contacto 21–23, y distingue el síntoma «se abre
pero no se cierra». R2 rechaza `condition_dropped:La puerta se abre pero no se
cierra`. Se publica la abstención.

## Patrones

1. Effort max gasta el presupuesto de salida en thinking. Con 48000 tokens, un
   turno del guion 1 se queda sin texto visible.
2. El fallo que antes bloqueaba el guion 2, autoajuste porque «sigue lenta»,
   no reaparece en T1 encadenado. El fallo nuevo es la repregunta de T2.
3. R2 tira respuestas cuya cita es literal cuando el texto dice que una
   condición no fue mencionada o nombra el síntoma distinto que la contiene.
4. High y medium no se midieron. El guion 2 ya había fallado en contenido.

## Filtro de páginas, low frente a medium

Después del diagnóstico. Misma solicitud que el lote del filtro, thinking
desactivado, `max_tokens` 256. Páginas 1, 8 y 12 de
`docs/field_companion/fuentes/VF5.pdf`, SHA-256
`be7a39a3490c92c8381cb883402760cb07d10b0a3beda5348bed22f72abedf72`. No hubo
reindexación ni escritura en la KB. Evidencia en
`tmp/field_companion/vf5_page_filter_effort/`.

Las dos decisiones coinciden: página 1 se descarta; 8 y 12 se conservan. Cambia
el wording de `reason`, no `keep`. Thinking 0. Latencia 1,8 s y 1,7 s. Entrada
7809 y salida 119 / 122. El adaptador no puso precio por el campo `speed`; con
la tarifa corta el coste es US$0,000840 y US$0,000842.

## Qué falta

Hace falta un effort que cierre el guion 2 sin repreguntar y que deje terminar
el texto visible del guion 1. High y medium quedan sin medir porque max falló
el contenido. R2 sigue publicando la abstención en conclusiones que el manual
sí respalda. La imagen `72ee437` no está sirviendo.
