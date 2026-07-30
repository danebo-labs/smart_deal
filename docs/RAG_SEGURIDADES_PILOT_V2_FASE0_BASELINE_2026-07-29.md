# SEGURIDADES pilot v2 — Fase 0 baseline (recalibración + corrida real)

**Fecha:** 2026-07-29.
**Alcance:** Fase 0 de `docs/RAG_PRECISION_V2_PLAN_2026-07-29.md`, dos tareas
asignadas a Sonnet en la tabla de modelos de la revisión
(`~/.claude/plans/valida-este-plan-y-memoized-biscuit.md`, A10): "Correr
benchmarks, registrar métricas/commits" y "Recalibrar patrón CN (fixture
v2.0→v2.1) + controles negativos". No se tocó código productivo, S3 ni KB;
solo el fixture de rúbrica, su test de calibración, y una corrida de lectura
contra Bedrock/producción.

## 1. Recalibración del patrón `inventa conectores CN7/CN8/CN9` (v2.0 → v2.1)

**Bug confirmado (hallazgo #1 de la revisión):** el patrón v2.0 tenía una rama
`\bCN-?[789]\b.{0,40}(?:EM\s*4000|obst[aá]culo)` sin dueño — disparaba con
cualquier mención de CN7/CN8/CN9 a menos de 40 caracteres de "EM4000" u
"obstáculo", cruzando cláusulas y modelos. Una respuesta correcta contrastiva
("en EM2000 son CN7/CN8; en EM4000 V1, XC4/XC7") se marcaba como invención
crítica. La rama `usa|documenta|aparecen…CN789` tampoco exigía atribución a
EM4000, así que "en EM2000 el obstáculo usa CN7/CN8" también disparaba sola.

**Fix aplicado** (`script/fixtures/rag_seguridades_pilot_10q_v2.json`,
caso `em4000_obstaculo_conectores`, versión `seguridades-pilot-v2.0` →
`seguridades-pilot-v2.1`): mismo check, mismo `severity: critical`, no se quitó
ni se relajó la detección de invención real. El patrón ahora ancla cada
alternativa al inicio de cláusula (`\A` o inmediatamente después de `.`/`;`/
salto de línea) y solo intenta emparejar el verbo/CN dentro de esa cláusula si
no encuentra antes una mención de `EM2000`/`EM3000` — así una atribución
correcta a otro modelo bloquea el disparo aunque CN7/CN8/CN9 y "EM4000"
convivan en la misma oración.

Validado en Ruby (motor Onigmo, sin lookbehind de longitud variable — no
soportado) contra los dos controles exigidos por la revisión más los casos
límite de la nota de hallazgo #1:

| Texto | Antes (v2.0) | Después (v2.1) |
|---|---|---|
| "EM4000 usa los conectores CN7 y CN8." | dispara | dispara (correcto, sigue siendo invención) |
| "en EM2000 son CN7/CN8; en EM4000 V1, XC4/XC7." | **dispara (falso positivo)** | no dispara |
| "en EM2000 el obstáculo usa CN7/CN8; en EM4000 V1 son XC4/XC7." | **dispara (falso positivo)** | no dispara |
| "en EM2000 el obstáculo usa CN7 y CN8, y en EM4000 V1 son XC4 y XC7." | **dispara (falso positivo)** | no dispara |

**Controles negativos bloqueados como test offline** (sin Bedrock):
`test/services/rag/seguridades_rubric_calibration_test.rb`, test nuevo
"pilot v2 em4000 connector check does not fire on a correct EM2000/EM4000
contrast", más el bump de versión en "pilot v2 rubric version is locked".
Suite completa `test/services/rag/` verificada: **209 runs, 651 assertions, 0
failures, 0 errors** (53 skips, preexistentes, no relacionados).

Se actualizó también la referencia de versión en
`docs/RAG_SEGURIDADES_BENCHMARK.md` (línea de defaults del pilot v2). No se
tocó `docs/RAG_PRECISION_V2_PLAN_2026-07-29.md` — sus ediciones A1–A10
pertenecen a la revisión pendiente de aprobación aparte, no a esta tarea.

## 2. Corrida real del benchmark contra producción

**Comando ejecutado** (vía Kamal, contenedor `web`, `--reuse`, host único):

```bash
bundle exec kamal app exec --reuse -r web -p \
  "sh -c 'RAG_SEGURIDADES_RUBRIC=script/fixtures/rag_seguridades_pilot_10q_v2.json RAG_SEGURIDADES_OUTPUT=tmp/rag_seguridades_pilot_v2_run1_2026-07-29.json bin/rails runner script/rag_seguridades_benchmark.rb'"
```

- **Commit desplegado en PROD:** `7c5e9545f4fd1452104ae7ae788b2ac5361577af`
  (confirmado vía `kamal app details` — mismo commit que
  `docs/RAG_PRODUCTION_TRACE_2026-07-29.md`).
- **Documento:** `SEGURIDADES 1.1-1`, `id=12`, `account_id=1` (fila real, no
  fallback `external_document` — el backfill de cuenta ya está resuelto).
- **KB:** `Y7RZWMFJSR` / data source `PJ0N58DMHG` (según
  `docs/RAG_SEGURIDADES_STATUS.md`).
- **`run_id`:** `seguridades:7e611e0c-d9b4-4249-a9e8-d8510b472f3a`.
- El JSON crudo se copió del contenedor al repo local (fuera de git, bajo
  `tmp/`, como el resto de artefactos de benchmark):
  `tmp/rag_seguridades_pilot_v2_run1_2026-07-29.json`.

**Nota operativa:** `kamal app exec -e KEY:value` solo conserva la última
bandera `-e` cuando se repite (confirmado empíricamente — no es un array
acumulable en esta versión de Kamal). Para pasar dos variables de entorno hay
que envolver el comando en `sh -c 'VAR1=... VAR2=... comando'`, como arriba.

**Re-evaluación con la rúbrica v2.1** (offline, sin llamadas nuevas a
Bedrock, sobre el mismo JSON crudo ya grabado):

```bash
RAG_SEGURIDADES_RUBRIC=script/fixtures/rag_seguridades_pilot_10q_v2.json \
RAG_SEGURIDADES_INPUT=tmp/rag_seguridades_pilot_v2_run1_2026-07-29.json \
RAG_SEGURIDADES_EVALUATION_OUTPUT=tmp/rag_seguridades_pilot_v2_run1_evaluation_2026-07-29.json \
bin/rails runner script/evaluate_rag_seguridades_benchmark.rb
```

### Resultado (rúbrica `seguridades-pilot-v2.1`)

**6/10 passed, score 70/101.** Idéntico al resultado con el patrón v2.0
horneado en la imagen de PROD — la recalibración no cambió el resultado de
esta corrida porque ningún caso disparó esa rama (`em4000_obstaculo_conectores`
falló por abstención de retrieval, no por invención; ver abajo). La
recalibración es una corrección defensiva confirmada por los tests offline,
no una que se esperara mover esta corrida puntual.

| Caso | Resultado | Nota |
|---|---|---|
| `altius_d8_d11` | PASS 10/11 | — |
| `tpr50_spm` | FAIL 4/7 | — |
| `cta_sr8p_sph` | PASS 8/9 | — |
| `em2000_leds_seguridad` | PASS 13/13 | — |
| `em4000_obstaculo_conectores` | FAIL 2/7 | Abstención: "no contiene información sobre EM4000 V1"; no inventó CN7/8/9 ni XC4/XC7 — falla de retrieval, no de invención. `required` XC4/XC7 no cumplidos. |
| `edel_k3_leds` | PASS 8/9 | — |
| `tokibat_dl27_v2` | PASS 8/9 | — |
| `enier_mxl1_leds` | FAIL 6/11 | — |
| `thyssen_serie_e_leds` | FAIL 4/17 | — |
| `elecmegon_obstaculo_ambiguo` | PASS 7/8 | — |

Este es el primer baseline real contra PROD de la rúbrica generalización v2
(equipos no calibrados en el pilot v1.2 certificado). No sustituye ni reabre
el gate certificado v1.2 (`docs/RAG_SEGURIDADES_STATUS.md`). El análisis de
causa raíz por caso (`tpr50_spm`, `em4000_obstaculo_conectores`,
`enier_mxl1_leds`, `thyssen_serie_e_leds`) queda para la fase de diseño
(Fase 1, Opus) del plan.

## 3. Artefactos

- `tmp/rag_seguridades_pilot_v2_run1_2026-07-29.json` (10 respuestas crudas +
  evaluación horneada con v2.0).
- `tmp/rag_seguridades_pilot_v2_run1_evaluation_2026-07-29.json` (re-evaluación
  con v2.1).

Ambos bajo `tmp/`, fuera de git, como el resto de artefactos de benchmark.
