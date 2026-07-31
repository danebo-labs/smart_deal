# Contrato de atribución de citas — ejecución y evidencia

**Fecha:** 2026-07-30
**Rama:** `pilot/abstention-contract`
**Base:** `dd0a421` (worktree limpio verificado antes del primer commit)
**Estado:** implementado, verificado offline, **flag apagado por defecto**. Pendiente la corrida
del gate de piloto (§13 del plan), que sí consume AWS.

## Resumen ejecutivo

`RAG_ABSTENTION_CONTRACT_2026-07-30.md` cerró la serie D5 en NO-GO por dos defectos que el
contrato de abstención parcial no cubría, ambos de **atribución de citas**:

1. **Trasplante de familia** (`thyssen_e_led`): la respuesta usaba L9/L8/L7 de THYSSEN y después
   importaba lógica LED de una placa de la sección OTIS, con la rúbrica marcándola `passed` y
   `penalized:false`.
2. **`citation_failure`** (`edel_k3_leds`): respuesta técnicamente correcta (3/3 `required`) que
   numeró marcadores por afirmación (`[1] [2] [3]`) contra una ventana de un solo bloque de
   evidencia; `valid_citations?` los interpretó como índices de chunk y la ruta abstuvo con
   `citations: []`.

Esta iteración cierra ambos de forma determinista: cero llamadas AWS nuevas, cero cambios de
prompt, cero recuperaciones adicionales, y sin debilitar `valid_citations?`, la rúbrica ni la
abstención segura.

Resultado offline sobre los 32 resultados archivados: **fidelidad 32/32**, **rollback 32/32
byte-idéntico**, **exactamente 2 respuestas cambian**, **0 nuevos `citation_failure`**,
**0 regresiones de rúbrica**.

## Qué se implementó

### Nuevos servicios de producción

| Ruta | Responsabilidad |
|---|---|
| [app/services/rag/citation_attribution_contract_flag.rb](../app/services/rag/citation_attribution_contract_flag.rb) | Interruptor único de rollback para ambas mitades del contrato |
| [app/services/rag/citation_marker_normalizer.rb](../app/services/rag/citation_marker_normalizer.rb) | Contrato de numeración `[n]` para ventana de evidencia única |
| [app/services/rag/citation_attribution_guard.rb](../app/services/rag/citation_attribution_guard.rb) | Atribución determinista por `section_identity` de los tramos citados |

### Puntos de cableado

| Ruta | Cambio |
|---|---|
| [app/services/rag/structured_evidence_route.rb](../app/services/rag/structured_evidence_route.rb) | Normalizador antes de safety, guarda después; `:attribution_failure`; `attribution_dropped` en `log_route` |
| [app/services/bedrock_rag_service.rb](../app/services/bedrock_rag_service.rb) | Guarda tras `AnswerSafetyProcessor` y antes de telemetría; fail-safe I11; 3 claves en `log_quality_signal`; `attribution_dropped` en `diagnostics` |
| [app/services/pilot_usage_log.rb](../app/services/pilot_usage_log.rb) | `attribution_dropped` en `ALLOWED_FIELDS` (lista cerrada) |
| [app/services/rag/evidence_selection_telemetry.rb](../app/services/rag/evidence_selection_telemetry.rb) | Propagación del campo por el adaptador existente, sin eventos ni rutas nuevas |

`RagController`, `Bedrock::CitationProcessor`, `Rag::AnswerSafetyProcessor`,
`Rag::EvidenceCandidateSelector`, `Rag::QueryEntities`, `app/prompts/bedrock/generation.txt`,
`Rag::BenchmarkRubricEvaluator`, el evaluador, las rúbricas, los locales, la ingestión, S3, la KB
y la metadata **no se tocaron**.

### Nota sobre el nombre de la variable en el camino genérico

`BedrockRagService#query` ya usaba `attribution` para la atribución de cuenta/usuario/sesión. La
del contrato de citas se llama `citation_attribution` para evitar colisión; no es una desviación
del plan sino su condición de aplicabilidad.

## I15 — cambio de la puerta de fidelidad (obligatorio para la próxima iteración)

Hasta ahora el replay usaba **I0**:

```
answer == AnswerSafetyProcessor.call(internal_answer, evidence: chunks)
```

Con el flag encendido, para artefactos generados **a partir de ahora**, el baseline pasa a ser
**I15**:

```
answer == CitationAttributionGuard.call(AnswerSafetyProcessor.call(internal_answer, …))
```

Los 3 artefactos de `tmp/d5_abstention_contract/` se generaron **antes** de que el flag
existiera, así que su baseline sigue siendo I0 y la guarda se les aplica como transformación.
**Si la próxima iteración replaya artefactos nuevos contra I0, reportará mismatches falsos.**

### Excepción de fidelidad medida: `edel_k3_leds`

Una fila de las 32 no reproduce con la estrategia `answer_safety`: su
`diagnostics[:internal_answer]` archivado es la respuesta técnica **previa** al gate de citas,
mientras la `answer` archivada es la abstención **posterior**. Reproducirla exige repetir el gate
terminal estructurado, no sólo `AnswerSafetyProcessor`.

El script lo codifica explícitamente como `fidelity_strategy: "structured_terminal_gate"` en la
fila correspondiente; las otras 31 usan `answer_safety`. Es la única excepción de las 32 y está
verificada fila a fila, no asumida.

## Evidencia offline (cero AWS)

Reproducida con [script/replay_d5_attribution_contract.rb](../script/replay_d5_attribution_contract.rb),
afirmada por [test/services/rag/d5_attribution_replay_test.rb](../test/services/rag/d5_attribution_replay_test.rb).

Los 3 artefactos originales se trataron como **solo lectura**; las salidas transformadas se
escriben en `tmp/replay_attribution/`. Integridad verificada al inicio de la ejecución y de nuevo
al cierre:

| Artefacto | SHA-256 |
|---|---|
| `d5_rag_seguridades_rubric_run1.json` | `a408b5df2d2ecbc586b0fca3d0815ec74a0a7b493f44d44687c534adef8f0ffd` |
| `d5_rag_seguridades_pilot_10q_run1.json` | `6fc848f79ec6e79b8c4ab4a02cd1473e98a0889e33710dade7af6a34a0e1929d` |
| `d5_rag_seguridades_pilot_10q_v2_run1.json` | `4d621519c38142d5c4d1689b687e7ad347a3754a1050249daf29958cccacae07` |

### Gates del §10

| Gate | Esperado | Medido |
|---|---|---|
| Fidelidad de baseline | 32/32 | **32/32** |
| Rollback con el flag apagado (I14) | 32/32 byte-idénticas | **32/32** |
| Respuestas que cambian con el flag encendido | exactamente 2 | **2** |
| `changed_ids` literal | `["thyssen_e_led", "edel_k3_leds"]` | **idéntico** |
| Respuestas byte-idénticas | 30 | **30** |
| Nuevos `citation_failure` (19 turnos estructurados) | 0 | **0** |
| Regresiones de rúbrica (`passed:true` → `passed:false`) | 0 | **0** |

### Re-scoring con el evaluador existente, sin modificarlo

| Rúbrica | Casos | Passed | Score |
|---|---|---|---|
| `seguridades-v3.2` | 12 | 12 | 82/88 |
| `seguridades-pilot-v1.2` | 10 | 10 | 83/88 |
| `seguridades-pilot-v2.1` | 10 | 10 | 94/101 |

### SHA-256 por resultado (32 filas, prefijo de 12 caracteres)

`answer` antes → después. `answer_sha256` completo en `tmp/replay_attribution/replay_report.json`.

| Artefacto | Caso | Antes | Después | Cambia |
|---|---|---|---|---|
| v3.2 | `altius_d8` | `81e96a150b2d` | `81e96a150b2d` | no |
| v3.2 | `tpr70_epc_b8` | `6b8189e143f3` | `6b8189e143f3` | no |
| v3.2 | `kdt_evo_presostato` | `e6dbb29370f6` | `e6dbb29370f6` | no |
| v3.2 | `mr08_sci` | `0284aa1636cd` | `0284aa1636cd` | no |
| v3.2 | `edel_k2_c2` | `fe0a19c7101b` | `fe0a19c7101b` | no |
| v3.2 | `em3000_fotocelula_220v` | `a2281e464d57` | `a2281e464d57` | no |
| v3.2 | `em2000_contradiccion` | `e53df20a124c` | `e53df20a124c` | no |
| v3.2 | `tokibat_dl27` | `5398f9266a23` | `5398f9266a23` | no |
| v3.2 | `thyssen_e_led` | `74b53905ba82` | `9adc01b4e160` | **sí** |
| v3.2 | `cerrojos_generica` | `2815e1bd5a3f` | `2815e1bd5a3f` | no |
| v3.2 | `torque_ausente` | `41772badf0fc` | `41772badf0fc` | no |
| v3.2 | `indice_carlos_silva` | `92412ac34e2e` | `92412ac34e2e` | no |
| pilot-v1.2 | `altius_d9_d10` | `ece5d6041d3f` | `ece5d6041d3f` | no |
| pilot-v1.2 | `tpr60_pp` | `b76233ee2bad` | `b76233ee2bad` | no |
| pilot-v1.2 | `cta_cr8ph2_sph` | `1a7f3584d88b` | `1a7f3584d88b` | no |
| pilot-v1.2 | `em3000_leds_seguridad` | `e9358d32a484` | `e9358d32a484` | no |
| pilot-v1.2 | `em3000_fotocelula_tension` | `fd9730271b33` | `fd9730271b33` | no |
| pilot-v1.2 | `em2000_contradiccion_conectores` | `97f986979515` | `97f986979515` | no |
| pilot-v1.2 | `edel_k2_led31` | `1e82cae2c18d` | `1e82cae2c18d` | no |
| pilot-v1.2 | `ekm66_h40_sin_averia` | `15c50f340ab0` | `15c50f340ab0` | no |
| pilot-v1.2 | `mr08_sci_conectores` | `4e438d8e879e` | `4e438d8e879e` | no |
| pilot-v1.2 | `cerrojos_conexion_generica` | `b5e84bc4067f` | `b5e84bc4067f` | no |
| pilot-v2.1 | `altius_d8_d11` | `7ac4f7ed2b89` | `7ac4f7ed2b89` | no |
| pilot-v2.1 | `tpr50_spm` | `70124824b248` | `70124824b248` | no |
| pilot-v2.1 | `cta_sr8p_sph` | `4ec9e8d40c98` | `4ec9e8d40c98` | no |
| pilot-v2.1 | `em2000_leds_seguridad` | `ef1eed371f87` | `ef1eed371f87` | no |
| pilot-v2.1 | `em4000_obstaculo_conectores` | `db71ea590fb9` | `db71ea590fb9` | no |
| pilot-v2.1 | `edel_k3_leds` | `b45c067eecef` | `674ea4721825` | **sí** |
| pilot-v2.1 | `tokibat_dl27_v2` | `bbf1faea9135` | `bbf1faea9135` | no |
| pilot-v2.1 | `enier_mxl1_leds` | `86bc7d822b6f` | `86bc7d822b6f` | no |
| pilot-v2.1 | `thyssen_serie_e_leds` | `f3298bdf1bee` | `f3298bdf1bee` | no |
| pilot-v2.1 | `elecmegon_obstaculo_ambiguo` | `6fdd65b8f957` | `6fdd65b8f957` | no |

### Los dos casos corregidos

**`thyssen_e_led`** (camino genérico, `bedrock_retrieve_and_generate`). La guarda elimina un solo
tramo — el que cierra en `[2]`, cuya cita resuelve a `section_identity = "OTIS"` mientras la
pregunta ancla en `THYSSEN`:

> `. **Nota:** La documentación menciona que en otras placas de control (como la NE 300 – LB II),
> los LEDs de serie (ES, DFC, DW) están descritos como "rojo" … Si el sistema Thyssen-E utiliza
> la misma lógica, un LED encendido señalaría fallo. Pero esto debe confirmarse en el equipo
> específico[2]`

El texto superviviente conserva L9/L8/L7, la declaración de incertidumbre y el tail
`El documento no incluye este dato`. `result[:citations]` pasa de 2 a 1 entrada;
`retrieved_citations` y `doc_refs` no se filtran (I13). Re-evaluado: **5/5, `passed:true`**, y
verificado automáticamente que no contiene `NE 300`, `LB II`, `DFC`, `DW` ni `misma lógica`.

**`edel_k3_leds`** (ruta estructurada). Con `evidence_count == 1`, `[2]` y `[3]` se normalizan a
`[1]`; `[24]`-style literales impresos en la evidencia quedan intactos por la salvaguarda
(verificado: 0 literales `[\d+]` en los 12 chunks archivados). Reconstruido con el pipeline local
completo: `expansion_count == 0`, `generation_chunks == 1`, `retrieve_invocations == 1`
(idénticos al trace archivado), `outcome.status == :answered`, `citations.size == 1`, sin
`citation_failure`. Pasa de `passed:false` a **`passed:true`, 8/9**.

### Limitación honesta del replay

El replay pasa a `AnswerSafetyProcessor` los 12 chunks recuperados, mientras la ruta viva le pasa
sólo el chunk de generación. Es un **superconjunto**, así que sólo puede producir *menos*
rechazos, nunca más. La reproducción exacta del contexto de generación se obtiene por la vía
determinista de `select_generation_chunks` sobre los chunks archivados, que es la usada para
`edel_k3_leds`.

## Verificación local ejecutada

| Comprobación | Resultado |
|---|---|
| Tests dirigidos (13 archivos del §15) | 217 runs, 798 assertions, **0 failures, 0 errors** |
| Suite completa | 1.932 runs, 6.346 assertions, **0 failures, 0 errors**, 189 skips |
| Replay offline | gates del §10 verdes (tabla anterior) |
| Rollback (`RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED=false`) | 32/32 byte-idénticas |
| Guardián de hardcodes (`regex_characterization_test.rb`) | 25 runs, 172 assertions, 0 failures |
| RuboCop | 445 archivos, **0 ofensas** |
| Brakeman | 0 security warnings (2 ignoradas preexistentes) |
| `bin/importmap audit` | sin paquetes vulnerables |
| `bundler-audit check --update` | **1 advisory preexistente**, ver abajo |

### Advisory de bundler-audit — preexistente, no introducido aquí

`activestorage 8.1.3` — CVE-2026-66066 / GHSA-xr9x-r78c-5hrm, «arbitrary file read and remote code
execution in Active Storage variant processing». Solución: `>= 8.1.3.1`.

Esta iteración **no tocó `Gemfile` ni `Gemfile.lock`** (`git log dd0a421..HEAD -- Gemfile.lock`
está vacío), así que el hallazgo es anterior a la serie y el gate «sin ofensas nuevas» se cumple.
Queda **abierto como trabajo de plataforma independiente**: debe cerrarse antes del gate de
producción, y no lo cierra este plan.

## Configuración de despliegue

`config/deploy.yml` está en `.gitignore` (línea 66), por lo que **no viaja en estos commits**. Ya
contiene localmente ambas variables, explícitas y apagadas:

```yaml
    RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED: "false"
    RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED: "false"
```

`SHOW_RAG_SOURCES`, `RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED` y los tres flags del selector no se
tocaron. **Cualquier máquina que despliegue debe replicar estas dos líneas a mano**: al estar
ignorado el archivo, un entorno sin ellas hereda el comportamiento de `dd0a421` (ambos contratos
inertes), que es el fallo seguro correcto pero no es el entorno del gate de piloto.

## Rollback

- **Nivel 1 — runtime, sin deploy.** `RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED` a cualquier valor
  distinto de `"true"`, o borrarla. Normalizador y guarda retornan en su primera línea.
  Comportamiento idéntico a `dd0a421`, probado por las 32/32 byte-idénticas.
- **Nivel 2** — `git revert` de los commits de cableado, en orden: primero
  `feat(rag): guard attribution in the generic RAG path`, después
  `feat(rag): enforce the marker contract in the structured route`.
- **Nivel 3** — `git reset --hard dd0a421`.

Ningún nivel requiere reingesta, cambio de metadata, resync de KB ni redeploy de prompts.

## Estado de los gates

### Gate de piloto — lo verde y lo pendiente

| # | Gate | Estado |
|---|---|---|
| 1 | Tests dirigidos, suite completa, RuboCop, Brakeman, bundler-audit, importmap | **verde** (advisory preexistente documentado) |
| 2 | Replay offline: 32/32, `changed_ids` literal, 0 regresiones, 0 nuevos `citation_failure` | **verde** |
| 3 | Rollback con el flag apagado: 32/32 byte-idénticas | **verde** |
| 4 | Una corrida completa de las 3 rúbricas con ambos flags encendidos (32 casos, consume AWS) | **pendiente** |
| 5 | `thyssen_e_led` 5/5 sin lógica de la placa hermana en esa corrida | pendiente (verde en replay) |
| 6 | `edel_k3_leds` sin `citation_failure` en esa corrida | pendiente (verde en replay) |
| 7 | Cero nuevos `citation_failure` frente a los artefactos previos | pendiente (verde en replay) |
| 8 | Sin regresiones de rúbrica en los 32 casos | pendiente (verde en replay) |
| 9 | `correlation_id`, tokens, coste y latencia en `[PILOT_USAGE]` / `[RAG_QUALITY]` / `[RAG_REGRESSION]` | pendiente — requiere la corrida |
| 10 | Revisión humana de las respuestas safety-critical de esa corrida | **pendiente — humana, no automatizable** |

Los artefactos nuevos van a `tmp/pilot_gate/` y **no se mezclan** con `tmp/d5_abstention_contract/`,
que pertenece a la serie fallida y es la línea base byte a byte.

### Gates de producción — diferidos por diseño, no bloquean el piloto

- 5 corridas D5 consecutivas verdes.
- Holdout `script/fixtures/rag_seguridades_holdout_v1.json`: **sigue cerrado, cero medición sobre
  preguntas no vistas**.
- A/B de latencia con el flag encendido/apagado. La medición vigente (retrieval p95 13.077 ms +
  generation p95 5.815 ms ≈ 19 s en el peor caso) es un problema de producto por sí sola.
- Reconciliación de coste contra los Model Invocation Logs de S3, incluidos los **+39
  tokens/consulta** heredados del contrato parcial. Esta iteración añade **0 tokens** (I12) pero
  no cierra ese hueco.
- Actualización de `activestorage` por CVE-2026-66066.
- `SHOW_RAG_SOURCES="false"`: el técnico no ve las citas. Todo este contrato protege contra
  entregar respuestas mal atribuidas; no da trazabilidad visible al usuario.
- Multi-tenant con costuras listas pero ejercitadas sobre **un solo account**.

## Alcance honesto de esta evidencia

Todo lo medido sale de tres rúbricas iteradas (v3.2, pilot-v1.2, pilot-v2.1) sobre **un solo
documento** (`SEGURIDADES 1.1-1.pdf`, 97 chunks, account 1). Volver a pasarlas no es evidencia
fuerte de generalización, y esta misma iteración lo demuestra: la rúbrica marcó `thyssen_e_led`
como `passed` con `penalized:false` mientras la respuesta trasplantaba lógica de una placa de otra
familia. **El evaluador puede aprobar una respuesta insegura.** Se cierra una instancia; la clase
no queda cerrada.

## Residuo conocido, fuera de alcance por diseño

Con **≥2** bloques de evidencia, una respuesta que numera por afirmación **dentro del rango
válido** es indetectable con esta guarda: la atribución familia-a-familia no se viola, pero la
afirmación puede no estar en el chunk citado. Cerrarlo exige validación **a nivel de
identificador** por marcador (¿el chunk citado contiene el identificador de la afirmación?). Es la
siguiente iteración, no un parche aquí. Si el piloto produce un caso así, se registra y se deja
para esa iteración.
