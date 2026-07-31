# Contrato de abstención parcial — ejecución y diagnóstico

**Fecha:** 2026-07-30  
**Rama:** `pilot/abstention-contract`  
**Estado:** **NO-GO — no desplegar**

## Resumen ejecutivo

El contrato determinista de abstención parcial quedó implementado, cubierto por
tests y validado offline. El replay reproduce 160/160 respuestas archivadas byte
a byte antes de transformar, y el re-scoring no introduce regresiones.

La validación AWS se detuvo tras 3/15 artefactos por dos NO-GO independientes:

1. `seguridades-pilot-v2.1` run 1 quedó 9/10. `edel_k3_leds` generó marcadores
   `[1]`, `[2]` y `[3]` con una ventana de un solo chunk; el gate de citas rechazó
   correctamente la respuesta y emitió abstención total sin citas.
2. `thyssen_e_led` pasó su rúbrica y tuvo cero penalizaciones, pero trasplantó
   lógica LED de la placa hermana NE 300–LB II a Thyssen Serie E. El evaluador
   sigue sin detectar este defecto de atribución.

No se abrió el holdout, no se ejecutó el A/B de latencia, no se creó tag y no se
desplegó.

## D0 — aislamiento y pre-flight offline

La base fue `main` en
`647d4db4e2db4191ed89a27f718426dd2b141f85`. El inventario real tenía 27
entradas (20 modificadas y 7 nuevas), no las 22 indicadas en el plan. Todas
quedaron preservadas en el snapshot:

`45af04a chore: snapshot worktree before abstention contract work`

Los seis tests de caracterización pasaron contra el código legado:

- 6 runs;
- 10 assertions;
- 0 failures;
- 0 errors.

El replay correcto separa dos operaciones:

1. reproducir el `answer` archivado aplicando sólo
   `Rag::AnswerSafetyProcessor` al `internal_answer`;
2. retirar el tail legado y aplicar el normalizador nuevo.

La primera tentativa mezcló ambas operaciones y dio 155/160. No se utilizó como
evidencia. Al respetar la separación, el gate quedó:

| Métrica | Resultado |
|---|---:|
| artefactos archivados | 15 |
| respuestas | 160 |
| replay byte-idéntico | **160/160** |
| regresiones de `passed:true` a `false` | **0** |
| artefactos verdes tras re-score | **15/15** |

### Blast radius medido

El contrato se añadió a 27 respuestas:

- camino genérico: **8/50**;
- ruta estructurada: **19** respuestas;
- respuestas deterministas: sin cambio.

Las ocho instancias genéricas coinciden con el diagnóstico previo:

| Caso | Instancias |
|---|---:|
| `thyssen_e_led` | 5 |
| `tokibat_dl27` | 1 |
| `altius_d8` | 1 |
| `mr08_sci` | 1 |

No hubo regresiones de rúbrica. Las cinco respuestas históricas de
`torque_ausente` y las cinco de `indice_carlos_silva` conservaron el texto
visible legado.

### Contradicción detectada en el plan

El gate 3 exige a la vez:

- marcar las ocho instancias anteriores, incluidas las cinco de
  `thyssen_e_led`; y
- marcar cero respuestas que ya satisfacían todos sus `required`.

Siete de las ocho ya satisfacían todos sus `required` y pasaban la rúbrica; el
propio diagnóstico explica que cuatro `thyssen_e_led` pasaban por eco de prompt.
Ambas condiciones no pueden cumplirse simultáneamente. Las ocho instancias
contienen abstención parcial relevante; no se clasificaron como falsos
positivos. La contradicción impide usar ese gate como señal automática de GO.

## Cambios implementados

- Flag `RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED`, apagado por defecto y activo
  sólo con el string exacto `"true"`.
- Cláusula de prompt removible bajo el mismo flag.
- SHA-256 del prompt con flag apagado:
  `bed763f75b9adaad91d8bb535e7f33775b23c83b5d88c8fcc676cb689fb6c8da`.
- SHA-256 del prompt con flag encendido:
  `d13c570377247d7330d8003591a843a672778c333fa43a7e0ebb06c98c341d18`.
- Normalización por fragmento y relación compartida usando
  `Rag::QueryEntities.requested_relation`.
- Aplicación del mismo contrato al camino genérico y a
  `Rag::StructuredEvidenceRoute`.
- Localización completa del tail en español e inglés.
- Los centinelas unidos dejaron de tratarse como componentes de una conexión.
- Los encabezados sólo se podan cuando el párrafo siguiente empieza por un
  centinela; una mención interna no elimina encabezados válidos.
- Re-scoring offline opcional con
  `RAG_SEGURIDADES_ANSWER_TRANSFORM=partial_abstention`.

El método privado necesitó keywords `question:` y `locale:` además de
`partial_contract:`. El pseudocódigo del plan no transportaba la pregunta,
aunque el predicado de relación depende de ella.

## D4 — validación local

| Gate | Resultado |
|---|---:|
| tests dirigidos | 157 runs, 892 assertions, 0 failures/errors |
| guardián de hardcodes | 3 runs, 14 assertions, 0 failures/errors |
| suite completa | 1.892 runs, 6.165 assertions, 0 failures/errors, 189 skips |
| RuboCop | 435 archivos, 0 ofensas |
| Brakeman | 0 warnings activos, 2 ignorados preexistentes |
| bundler-audit | sin vulnerabilidades |
| importmap audit | sin paquetes vulnerables |

Ruby: `3.4.7`  
Bundler: `2.7.2`

El primer intento de la suite completa fue bloqueado por el sandbox al acceder a
PostgreSQL. RuboCop fue bloqueado al escribir su caché e importmap al consultar
el registro npm. Las mismas comprobaciones pasaron al repetirse con los permisos
locales/red necesarios. No se modificó código para resolver esos fallos de
entorno.

## D5 — serie AWS detenida por NO-GO

La primera ejecución sin identidad externa se detuvo antes de AWS y no creó
artefactos. Se reutilizó después la identidad preservada del documento:

- Knowledge Base: `Y7RZWMFJSR`;
- bucket: `multimodal-source-destination`;
- account: `1`;
- document key:
  `uploads/1/b61f5d54-ff42-414a-97b7-01682d16f4b5/original.pdf`.

Resultados antes de detener el loop:

| Artefacto | Resultado | SHA-256 |
|---|---:|---|
| `d5_rag_seguridades_rubric_run1.json` | 12/12, 82/88 | `a408b5df2d2ecbc586b0fca3d0815ec74a0a7b493f44d44687c534adef8f0ffd` |
| `d5_rag_seguridades_pilot_10q_run1.json` | 10/10, 83/88 | `6fc848f79ec6e79b8c4ab4a02cd1473e98a0889e33710dade7af6a34a0e1929d` |
| `d5_rag_seguridades_pilot_10q_v2_run1.json` | **9/10, 86/101** | `4d621519c38142d5c4d1689b687e7ad347a3754a1050249daf29958cccacae07` |

La cuarta ejecución alcanzó a iniciar una llamada antes de que el loop fuera
interrumpido; no produjo artefacto y no se mezcla con la serie.

### Invariantes observados en los 3 artefactos

- penalizaciones `matched:true`: **0**;
- turnos de ruta estructurada: 19;
- recuperaciones por turno estructurado: mínimo 1, máximo **1**;
- `generation_chunks` máximo: **1**;
- expansión observada: sólo `section_identity`;
- el camino genérico registra 2 invocaciones en este benchmark porque éste hace
  un `retrieve_chunks` diagnóstico y después `RetrieveAndGenerate`; no es la
  ruta estructurada.

### Falla de `edel_k3_leds`

Datos medidos:

- `generation_mode`: `structured_evidence_route`;
- `retrieve_invocations`: 1;
- `generation_chunks`: 1;
- `raw_answer`: contiene `[1]`, `[2]` y `[3]`;
- `citations`: `[]`;
- respuesta visible: `El documento no incluye este dato`.

El normalizador no creó los marcadores `[n]`. La causa proximal es que el modelo
emitió referencias fuera del rango 1..1. `valid_citations?` falló y la ruta
abstuvo de forma segura. El benchmark no persiste `outcome_reason` en el payload;
la clasificación se deriva del camino determinista del código ante una respuesta
no vacía con marcadores fuera de rango. No puede atribuirse causalmente el aumento de
probabilidad al cambio de prompt con un solo artefacto; el pre-flight offline no
puede validar D1.

### Trasplante de familia en `thyssen_e_led`

La respuesta identifica correctamente L9/L8/L7 y declara que Serie E no
documenta la lógica ON/OFF. Después introduce NE 300–LB II, describe su
convención y propone condicionalmente aplicar esa lógica a Thyssen-E.

El texto fuente preservado separa:

- `NE 300 – LB II`: LEDs ES, DFC y DW;
- `THYSSEN / SERIE E`: LEDs L9, L8 y L7.

La sección Thyssen no documenta que su lógica ON/OFF sea la de NE 300. Por tanto
la respuesta viola la prohibición de trasplantar evidencia de una placa hermana.
La rúbrica la marcó como pasada y su penalización permaneció `matched:false`.
Esto confirma el punto ciego de atribución y falla el gate humano 17.

## Latencia y coste

Medición parcial, sólo flag encendido, sobre 19 turnos estructurados:

| Etapa | p50 | p95 | min–max |
|---|---:|---:|---:|
| retrieval | 4.588 ms | 13.077 ms | 616–13.077 ms |
| expansion | 2 ms | 40 ms | 1–40 ms |
| local | 22 ms | 44 ms | 18–44 ms |
| generation | 4.242 ms | 5.815 ms | 2.929–5.815 ms |

No es un A/B y no satisface D7.2.

La afirmación del plan de “0 tokens adicionales por consulta” es incorrecta.
Medición con `AnthropicTokenCounter`:

| Plantilla | Caracteres | Tokens estimados |
|---|---:|---:|
| flag apagado | 7.193 | 1.559 |
| flag encendido | 7.338 | 1.598 |
| delta | **+145** | **+39** |

El coste exacto de las llamadas D5 no se reconcilió con Model Invocation Logs
porque la serie fue detenida. El hueco de coste queda abierto.

## Flags de deploy observados

`config/deploy.yml` permanece sin modificaciones:

| Variable | Valor |
|---|---|
| `RAG_EVIDENCE_SELECTOR_ENABLED` | `"false"` |
| `RAG_EVIDENCE_EXPANSION_ENABLED` | `"false"` |
| `RAG_EVIDENCE_CARDS_ENABLED` | `"false"` |
| `SHOW_RAG_SOURCES` | `"false"` |
| `RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED` | `"true"` |
| `RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED` | ausente, por tanto apagado por defecto |

## Gates finales

| Área | Estado |
|---|---|
| D0 replay y re-score | verde, con contradicción documental del gate 3 |
| D4 tests y auditorías | verde |
| D5 cinco corridas consecutivas | **falló en 3/15** |
| 0 `citation_failure` nuevos | **falló: `edel_k3_leds`** |
| revisión sin trasplantes de familia | **falló: `thyssen_e_led`** |
| D6 holdout | no ejecutado por orden estricto |
| D7 A/B | no ejecutado por orden estricto |
| coste reconciliado | no ejecutado; hueco documentado |
| candidato/tag/deploy | no creado |

## Veredicto

La aplicación no está lista para desplegar este candidato a producción.

La implementación local corrige de forma determinista el defecto original de
abstención y dispone de rollback seguro, pero la evidencia nueva demuestra:

1. una regresión real de citas en la ruta estructurada;
2. un riesgo de seguridad no detectado por la rúbrica debido a atribución entre
   familias;
3. un coste de prompt adicional contrario a la premisa del plan;
4. ausencia de holdout, revisión humana completa, A/B y reconciliación de coste.

La siguiente iteración debe corregir primero la atribución modelo/placa y
endurecer o estabilizar el contrato de referencias de la ruta estructurada.
Después requiere una serie D5 completamente nueva; los tres artefactos de esta
serie fallida no pueden mezclarse con la siguiente.
