# Guion 2 integrado — la sonda se detiene antes de las fases vivas

Código en `22aa8f7`. La sonda de Retrieve quedó en `tmp/field_companion/vf5_guion2_integrado/retrieve_probe.json`. No hubo llamada de modelo, ni cambio de `QueryComposer`, ni subida de la ventana. Las fases vivas del guion 2, de la regresión y de los controles no se ejecutaron.

## Veredictos

| Tramo | Veredicto |
| --- | --- |
| Guion 2 | No ejecutado. No queda acreditado. |
| Regresión del guion 1 | No ejecutada. No queda acreditada. |
| Controles del intérprete | No ejecutados. No quedan acreditados. |

El conjunto no se aprueba. Hace falta que los tres tramos aprueben, y ninguno se corrió.

## Qué quedó en el código

La fase determinista cerró en verde: 5304 pruebas, 0 fallos, 0 errores, 186 omisiones, semilla 20479.

| Punto | Commit |
| --- | --- |
| Paridad del runner | `cb2ddd4` |
| Pregunta abierta | `41de67d` |
| Checker | `9a65599` |
| Cita literal | `a87ee97` |
| Extractos | `a8fc5b3` |
| Ventana y tope de enunciados | `22aa8f7` |

Prompt del producto, SHA-256 `669df150364315bc9a3ef272d4bad8e8703b3a5ad91bb13b8ce2e56a00949905`, 8262 bytes, versión `2026-11-04.1`. Esquema, SHA-256 `7a428ec3bc242b6c32529865855c0dfe356c2d23dd1ba3d11f082d829b72d612`, versión `turn_perception.4`. `BEDROCK_MODEL_ID` en el entorno local es `global.anthropic.claude-haiku-4-5-20251001-v1:0`. La sonda no envió ese modelo. `BEDROCK_RERANKER_ENABLED` es `false` y la petición de Retrieve no lleva `reranking_configuration`.

`COMPANION_PINNED_CANDIDATES` sigue en 3. `STATEMENTS_MAX_CHARS` sigue en 16_000. Ese tope ya está en el techo permitido: 12_000 quitaba una página de la regresión VF5 del 29 de octubre (el t5 mide 14_672 caracteres antes de añadir la definición). El coste de esos 4_000 caracteres es unos US$0,004 por plan, a US$0,001 por mil tokens de entrada de Haiku 4.5 global.

## Sonda

Cuatro Retrieve guardados, más uno anterior de Q1 cuyo cuerpo se perdió porque el script rompió antes de escribir. Cinco en total, por debajo de seis. Sin modelo. `AWS_MAX_ATTEMPTS=1`. `SHARED_SESSION_ENABLED=false` en ese proceso. KB `Y7RZWMFJSR`, la del evento `retrieve` de `vf5-corrected-20261103T201414Z`. Filtro HYBRID, 30 resultados, pin `s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf`. El ledger `tmp/field_companion/vf5_generator_benchmark/assignment_spend.json` conserva el SHA-256 `1a519f8948912e3cdcd6a20e55f330381972264357b9d310979c490c6ec3466e` antes y después. Sigue en 185 intentos, tope 185, comprometido US$1,648972, desconocido US$0,102140, autorización `f2f3-joint-after-134` por US$0,750000, techo global US$4.

| Consulta | Rango de `chunk_p8_1` | Página | Score | Caracteres |
| --- | ---: | ---: | ---: | ---: |
| Q1, texto de `e32425aa` | 10 | 8 | 0,4357 | 4331 |
| Q2, texto de `d84e8a77` | 15 | 8 | 0,4067 | 4331 |
| Q1b | 21 | 8 | 0,3765 | 4331 |
| Q2b | 19 | 8 | 0,3861 | 4331 |

La composición original tiene peor rango 15. La composición b tiene peor rango 21. Se elige la original por ese rango. `k=16` es el menor de {8, 12, 16, 20} que incluye el chunk en T1 y en T2. En las dos consultas los chunks de score mayor ya suman más de 16_000 caracteres (31_466 en T1, 46_559 en T2), así que el recorte suelta `chunk_p8_1` en todas las ventanas, también con tope 12_000. Conservarlo exigiría 35_797 caracteres en T1 y 50_890 en T2. Eso pasa el techo de 16_000. El adicional de T2 frente al tope vigente sería unos 34_890 tokens de entrada, US$0,035 por plan, y aun así no cabe en la autorización de esta fase. El tope no se sube.

La composición b tampoco entra en `k=20`: su peor rango es 21. `QueryComposer` no cambia.

## Qué queda para Lahiri

La siguiente decisión es una de estas tres, sin otra pasada viva mientras tanto:

1. Una consulta distinta de Q1b y Q2b. Esas dos, apoyadas en la observación, empeoraron el rango.
2. Recuperar la sección 5.8, página 8, en lugar de confiar en el orden híbrido.
3. Comprobar si el reranker está disponible en la región. Hoy `BEDROCK_RERANKER_ENABLED` está en falso y el producto solo lo añadiría a una consulta exhaustiva.

La verificación en la aplicación desplegada, con sus seis llamadas y su cupo aparte, queda a la espera de esa decisión. Esta sonda no la adelanta.
