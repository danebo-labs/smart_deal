# Piloto de ruta estructurada — evidencia y gates

**Fecha:** 2026-07-30  
**Plan:** `genera-un-plan-correctivo-lazy-jellyfish.md`  
**Estado actual:** **NO-GO**. La serie diagnóstica completa anterior a la
corrección final de caché falló en la segunda corrida de
`seguridades-v3.2`. La nueva serie sobre el código final se detuvo por
instrucción del usuario después de 4/15 artefactos verdes. No se abrieron C7,
C6.8 ni C6.9.

## Alcance

La corrección activa preguntas de mapeo estructurado por dos formas genéricas:

1. etiqueta adyacente a un identificador;
2. co-ocurrencia, en cualquier orden, de un término de etiqueta y un designador
   alfanumérico con al menos un dígito.

La recuperación ancha de 12 chunks pertenece exclusivamente a
`Rag::StructuredEvidenceRoute`. El perfil compartido conserva el presupuesto
de documento fijado en 3. La ventana generativa queda limitada a 5 chunks.

## C0 — base certificada antes de editar

| Comprobación | Resultado |
|---|---|
| Suite completa | 1840 runs, 5760 assertions, 0 failures, 0 errors, 189 skips |
| Guardián de hardcodes | 3 runs, 14 assertions, 0 failures |
| RuboCop | 432 files, 0 offenses |
| Brakeman | 0 warnings activos, 2 ignorados preexistentes |
| bundler-audit | sin vulnerabilidades |
| importmap audit | sin paquetes vulnerables |

La primera invocación del shell tomó Ruby 2.6 del sistema y no alcanzó Rails. La
certificación se ejecutó nuevamente con Ruby 3.4.7 y Bundler 2.7.2 mediante
`mise`. PostgreSQL y las comprobaciones de red se ejecutaron con los permisos
locales requeridos. No se modificaron archivos para resolver esos problemas de
entorno.

## Contratos implementados

- `Rag::QueryEntities` conserva intacta la semántica de extracción y expone
  `label_terms?` como consulta de forma independiente de posición.
- La guarda comparativa se evalúa antes de ambas formas de elegibilidad.
- Los identificadores `:labelled` conservan prioridad para cobertura; cuando no
  existen, la ventana intenta cubrir los identificadores `:bare` extraídos.
- Los valores documentales deben reproducirse literalmente antes de cualquier
  explicación. La prosa se localiza, pero el valor literal no se traduce ni
  reescribe.
- Después de un `Retrieve` consumido, la ruta termina como `:answered` o
  `:abstained`; nunca cae en una segunda recuperación.
- Una respuesta `:answered` requiere marcadores válidos y al menos una
  referencia numerada. Una `:abstained` no transporta citas.
- La ruta viva sólo acepta expansión `section_identity`; nunca
  `adjacent_page_interim`.

## Coste y telemetría

`Retrieve` puro no crea filas en `bedrock_queries`. La generación directa pasa
por `AiProvider`/`BedrockClient`; `BedrockClient` obtiene el `usage` del
proveedor y encola `TrackBedrockQueryJob` de forma asíncrona.

La interfaz pública `AiProvider#query` devuelve sólo texto y no devuelve el
objeto `usage` a `Rag::StructuredEvidenceRoute`. Por eso el evento
`evidence_route` registra:

- `generation_input_tokens` y `generation_output_tokens` estimados localmente;
- `generation_prompt_chars`;
- número de chunks generativos;
- tiempos separados de recuperación, expansión, trabajo local y generación.

Limitación conocida: la fila asíncrona conserva tokens reales del proveedor,
pero hoy no recibe el `correlation_id` de la ruta. La reconciliación exacta de
coste sigue teniendo como autoridad los Model Invocation Logs de S3. La
consolidación de la directiva literal en el prompt compartido y una devolución
estructurada de `usage` por `AiProvider` quedan fuera del piloto.

## Holdout congelado

Archivo: `script/fixtures/rag_seguridades_holdout_v1.json`  
Versión: `seguridades-holdout-v1.0`  
Casos: 10  
SHA-256 registrado antes de la primera corrida:
`34682fb13ca5acf0e635d42ad285be039749b4d07f090a728ef43371d4325309`

La verdad-terreno se verificó visualmente contra
`SEGURIDADES 1.1-1.pdf`, páginas 17, 19, 26, 33, 44, 45, 64 y 66–69.

### Recursos preservados para la próxima revisión

El PDF fuente no fue modificado ni eliminado:

`/Users/lahirisan/Documents/Danebo/Danebo Elevator Rag Julio 2026/entrevosdtas /SEGURIDADES 1.1-1.pdf`

La carpeta `entrevosdtas ` termina en espacio. El archivo mide 36.419.336 bytes
y su SHA-256 es
`1843b13d81ae8756fef7dcbda72d287790a79e656472b6716e9752d9474496d1`.

Para evitar repetir el render y la extracción en otro chat, se preservan:

- `tmp/pdfs/seguridades.txt`, extracción de texto con layout;
- `tmp/pdfs/holdout-page-{17,18,19,26,33,44,45,64,65,66,67,68,69}.png`,
  páginas renderizadas a 150 DPI.

Estos recursos son sólo de lectura/verificación. No son insumos de ingestión y
no deben escribirse bajo `bulk_chunks/`.

| Categoría de riesgo | Caso | Páginas |
|---|---|---:|
| etiqueta e identificador no adyacentes | `holdout_nonadjacent_ekm66_codes` | 44–45 |
| placa hermana negada | `holdout_sibling_ne300_p36` | 64, 67 |
| número distractor como página | `holdout_page64_table` | 64 |
| mismo código en dos placas | `holdout_sph_two_boards` | 17, 19 |
| fabricante sin modelo | `holdout_otis_es_ambiguous` | 66–69 |
| modelo inexistente | `holdout_unknown_zz9000` | — |
| sufijo de versión no fusionado | `holdout_em4000_v2_absent` | 33 |
| pregunta multiobjetivo parcial | `holdout_arca_p36_torque` | 64 |
| comparativa | `holdout_compare_ekm66_pressure` | 44–45 |
| etiqueta sin identificador | `holdout_page26_led_count` | 26 |

El holdout no se ejecutará hasta que las 15 corridas de las cohortes históricas
estén verdes. Si falla, no se editará ni se reutilizará para calibrar.

## Configuración de deploy leída

| Variable | Valor en `config/deploy.yml` |
|---|---|
| `RAG_EVIDENCE_SELECTOR_ENABLED` | `"false"` |
| `RAG_EVIDENCE_EXPANSION_ENABLED` | `"false"` |
| `RAG_EVIDENCE_CARDS_ENABLED` | `"false"` |
| `SHOW_RAG_SOURCES` | `"false"` |
| `RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED` | `"true"` |

## C6.6 — serie diagnóstica completa anterior a la corrección C5.2

| Cohorte | Run 1 | Run 2 | Run 3 | Run 4 | Run 5 |
|---|---:|---:|---:|---:|---:|
| `seguridades-v3.2` | 12/12 (83/88) | **11/12 (81/88)** | 12/12 (83/88) | 12/12 (83/88) | 12/12 (82/88) |
| `seguridades-pilot-v1.2` | 10/10 (82/88) | 10/10 (82/88) | 10/10 (82/88) | 10/10 (82/88) | 10/10 (82/88) |
| `seguridades-pilot-v2.1` | 10/10 (94/101) | 10/10 (95/101) | 10/10 (94/101) | 10/10 (95/101) | 10/10 (94/101) |

Los 15 artefactos se conservaron en `tmp/c6_pre_cache_fix/`, sin descartar ni
repetir ninguna corrida. Resultado agregado:

- 14/15 artefactos verdes;
- 0 penalizaciones marcadas;
- `retrieve_invocations == 1` en todos los turnos de ruta estructurada;
- máximo observado de `generation_chunks`: 1;
- única expansión observada: `section_identity`.

La falla única fue `thyssen_e_led` en
`tmp/c6_pre_cache_fix/c6_rag_seguridades_rubric_run2.json`. La respuesta citó
la evidencia, identificó los LEDs documentados y no inventó un estado
normal/fallo, pero la evaluación no reconoció la exigencia «expone falta de
lógica documentada». El caso tomó el camino
`bedrock_retrieve_and_generate`, no la ruta estructurada. No se modificó la
rúbrica ni se ajustó código para acomodar ese resultado.

Después de esta serie se detectó una desviación de C5.2: la segunda instancia
del expansor reutilizaba el índice y evitaba sidecars, pero volvía a descargar
el cuerpo del chunk. Se corrigió para persistir el cuerpo autorizado en Solid
Cache y el test ahora exige delta cero tanto en `list_keys` como en
`download`. Por esta modificación, la serie completa anterior es evidencia
diagnóstica, no certificación del código final.

### Serie final interrumpida

Se inició una serie nueva sobre el código final y se detuvo a solicitud del
usuario para evitar más coste AWS. Quedaron cuatro artefactos finalizados:

| Artefacto | Resultado |
|---|---:|
| `tmp/c6_rag_seguridades_rubric_run1.json` | 12/12 |
| `tmp/c6_rag_seguridades_pilot_10q_run1.json` | 10/10 |
| `tmp/c6_rag_seguridades_pilot_10q_v2_run1.json` | 10/10 |
| `tmp/c6_rag_seguridades_rubric_run2.json` | 12/12 |

Los otros archivos `tmp/c6_*.json` pueden corresponder a la serie anterior; no
deben mezclarse para declarar cinco corridas consecutivas. El proceso fue
interrumpido durante `seguridades-pilot-v1.2` del ciclo 2 y no generó un
artefacto nuevo para esa ejecución.

## C6.1–C6.5 — validación final local

| Comprobación | Resultado |
|---|---|
| Tests dirigidos | 126 runs, 429 assertions, 0 failures, 0 errors |
| Guardián de hardcodes | 3 runs, 14 assertions, 0 failures |
| Suite completa | 1870 runs, 5903 assertions, 0 failures, 0 errors, 189 skips |
| RuboCop | 432 files, 0 offenses |
| Brakeman | 0 warnings activos, 2 ignorados preexistentes |
| bundler-audit | sin vulnerabilidades |
| importmap audit | sin paquetes vulnerables |

Para el próximo diagnóstico deben ejecutarse los tests necesarios. Para ahorrar
tiempo y coste, no repetir RuboCop, Brakeman, bundler-audit, importmap audit ni
otros checks sintácticos/estáticos ya certificados en este estado, salvo que
una modificación posterior afecte su alcance. Antes de deploy, todo check
invalidado por código nuevo debe volver a ejecutarse.

## C6.8 — revisión humana

Bloqueada por C6.6. Deben revisarse contra el PDF los dos casos objetivo y los
cuatro casos colaterales activados por co-ocurrencia.

## C6.9 — A/B de latencia

| Par | Ruta encendida | Ruta apagada | p50/p95 por etapa |
|---|---|---|---|
| 1 | bloqueado por C6.6 | bloqueado por C6.6 | no medido |
| 2 | bloqueado por C6.6 | bloqueado por C6.6 | no medido |
| 3 | bloqueado por C6.6 | bloqueado por C6.6 | no medido |

Las etapas a comparar son `retrieval_ms`, `expansion_ms`, `local_ms` y
`generation_ms`. No se usarán mediciones de `Retrieve` puro como baseline del
camino generativo. No se ejecutó el A/B porque el orden estricto exige C6.6
verde antes de continuar.

## Gates GO/NO-GO

| # | Gate | Estado |
|---:|---|---|
| 1 | `seguridades-v3.2` 12/12 en 5 corridas | no certificado en código final |
| 2 | `seguridades-pilot-v1.2` 10/10 en 5 corridas | no certificado en código final |
| 3 | `seguridades-pilot-v2.1` 10/10 en 5 corridas | no certificado en código final |
| 4 | tres cohortes en cinco corridas consecutivas | **no medido: serie final 4/15** |
| 5 | 0 penalizaciones críticas | 0 en la serie diagnóstica; serie final incompleta |
| 6 | 0 invenciones en revisión humana | bloqueado; no medido |
| 7 | una recuperación por turno estructurado | cumple en artefactos y tests |
| 8 | `generation_chunks <= 5` | cumple; máximo observado 1 |
| 9 | sólo expansión `section_identity` | cumple |
| 10 | suite, guardián, estilo y auditorías finales | cumple |
| 11 | holdout sin invenciones críticas | bloqueado; holdout no ejecutado |
| 12 | cuatro flags de sombra/fuentes en `false` | confirmado por lectura local |
| 13 | A/B con p95 por etapa | bloqueado; no medido |
| 14 | coste reconciliado o limitación documentada | hueco y autoridad de coste documentados |

Con gates 1, 4, 6, 11 y 13 sin cumplir, el sistema no está listo para deploy.

## Rollback y limitaciones conocidas

`RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED=false` impide construir la ruta,
mantiene el presupuesto del camino genérico en 3 y elimina la directiva literal
y la selección de hasta 5 chunks. No requiere resincronizar el Knowledge Base
ni modificar sidecars.

Tras un `Retrieve` exitoso, un fallo de generación termina en abstención segura
en vez de reintentar por el camino genérico. Esta decisión evita una segunda
recuperación facturable y prioriza seguridad; su tasa debe vigilarse mediante
`outcome=abstained` y `outcome_reason=generation_failure`.
