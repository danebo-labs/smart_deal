# Plan quirúrgico de precisión RAG — 2026-08-02

**Objetivo:** liberar la aplicación a piloto lo antes posible, al mínimo costo,
mejorando la precisión de respuesta sólo donde una medición lo justifique.

**Entrada obligatoria:** `docs/rag/diagnostico_precision_2026-08-02.md`. Este
plan implementa su §8 y no lo contradice en ningún punto. La regla es una:
**medir barato primero, construir sólo si la medición lo justifica.**

**Línea base honesta:** no existe. `62/88` está caducado (2026-07-23); las dos
cohortes verdes (83/88, 10/10) están sobreajustadas por construcción. La única
cifra limpia posible es el holdout v1, que nunca se abrió. Ese número es la
Fase 1.

---

## Restricciones no negociables (del dueño del producto)

1. **Nada de regex nuevo en la aplicación** para "maquillar" respuestas. El
   único post-proceso existente (`rag/answer_safety_processor.rb`, en `main`
   sin flag) queda **bajo revisión** en la Rama P — se le pone flag y sólo
   sobrevive si la medición lo justifica. No se añade ninguno más.
2. **No indexar datos con falta de información.** Cero re-ingesta, cero
   re-troceo. Sólo se permiten pases de metadatos que *añaden* información a
   sidecars existentes (patrón `section_identity`), nunca que la quitan.
3. **Presupuesto agotado.** Cada fase declara su costo antes de ejecutarse.

## ⚠️ Advertencia operativa: sin saldo en la API de Anthropic

Desde 2026-08-02 la cuenta de Anthropic API de la aplicación no tiene saldo.
Las corridas que la usan (visión, Batch API de ingesta) **"terminan bien" con
resultados vacíos y $0** — sin error visible. Este plan **no contiene ningún
paso que llame a la API de Anthropic desde la aplicación**. Si alguien propone
re-ingestar o re-trocear: además de estar prohibido (§5 del diagnóstico),
fallaría en silencio produciendo chunks vacíos.

Las corridas de benchmark van por **AWS Bedrock** (`retrieve_and_generate`,
perfil `global.anthropic.claude-haiku-4-5`), facturación AWS aparte, y no
están afectadas.

---

## Asignación de modelo por fase (sesión de IA que ejecuta el paso)

| Modelo | Precio in/out por MTok | Se usa para |
|---|---|---|
| Claude Haiku 4.5 (`claude-haiku-4-5`) | $1 / $5 | Pasos mecánicos: correr scripts, recolectar artefactos, pases de metadatos |
| Claude Sonnet 5 (`claude-sonnet-5`) | $2 / $10 (intro hasta 2026-08-31; luego $3/$15) | Análisis: clasificar fallos, redactar holdout v2, cambios de prompt/código |
| Claude Opus 5 (`claude-opus-5`) | $5 / $25 | **Sólo** si la clasificación de la Fase 2 resulta ambigua: una consulta acotada, no una sesión completa |

Regla: ninguna fase de este plan requiere Opus por defecto, y ninguna usa
Fable ($10/$50). El grueso del costo de sesión es lectura de artefactos —
mantener las sesiones cortas y con un solo objetivo.

---

## Fase 0 — Preparación sin tocar el sistema

**Modelo:** Haiku 4.5 (0a, 0c) · Sonnet 5 (0b). **Costo API de la app: $0.**

- **0a. Parametrizar el arnés.** `script/rag_seguridades_benchmark.rb:8` tiene
  `RUBRIC_PATH` hardcodeado a `rag_seguridades_rubric.json`. Añadir
  `ENV["RAG_SEGURIDADES_FIXTURE_PATH"]` con el valor actual como default.
  Esto cambia el *arnés*, no el sistema bajo prueba — la condición "sin tocar
  nada antes de correrlo" del diagnóstico se refiere al RAG y al KB, y ambos
  quedan intactos. Con test.
- **0b. Congelar holdout v2.** El v1 se gasta en la Fase 1 (un holdout corrido
  dos veces deja de ser holdout), así que el gate de salida necesita otro:
  10 preguntas nuevas, escritas desde la verdad-terreno ya pagada (Gate A
  §5-§9 y el PDF `SEGURIDADES 1.1-1`), mismo formato que el v1
  (`required`/`optional`/`penalized`, `passing_score: 70`). Se guarda en
  `script/fixtures/rag_seguridades_holdout_v2.json` y **no se abre** hasta la
  Fase 4. Quien lo redacta no participa en los arreglos de la Fase 3.
- **0c. Resolver `account_id` (§7 del diagnóstico).** Decisión de negocio
  pendiente: ¿la base del piloto tiene la cuenta 1?
  - Sí → correr `script/backfill_seguridades_kb_document_2026-07-26.rb` allí.
  - No → reescribir `account_id` en los 97 sidecars + resync del KB (pase de
    metadatos, 0 llamadas a Claude).
  Esto **bloquea el piloto aunque la precisión fuese perfecta** (el documento
  no se lista en la UI del técnico). No crear la fila de catálogo bajo otra
  cuenta.

## Fase 1 — La única medición que falta (holdout v1, UNA corrida)

**Modelo:** Haiku 4.5. **Costo:** ~10 llamadas `retrieve_and_generate` en
Bedrock (centavos) + tokens de sesión.

1. Verificar casos sueltos NO aplica aquí: es el holdout, va completo y una
   sola vez.
2. Correr contra el **KB de producción** — sobreescribir en la línea de
   comandos las variables del KB (el `.env` local apunta a desarrollo).
3. Guardar el artefacto completo en `tmp/` y anotar su hash en este documento:
   por caso, **pregunta, chunks recuperados, respuesta cruda, respuesta
   final, scoring por patrón**.
4. **Gate:** si el resultado ≥ `passing_score` (70/88) → saltar directo a la
   Fase 4 (el v2 confirma) y preparar piloto. No construir nada.

## Fase 2 — Clasificar los fallos, caso por caso

**Modelo:** Sonnet 5. **Costo API de la app: $0** (sólo lectura del artefacto
de la Fase 1).

Para cada caso fallido, una fila con exactamente una categoría:

| Categoría | Criterio |
|---|---|
| **R — recuperación** | El hecho requerido no está en ningún chunk recuperado |
| **G — generación** | El hecho está en los chunks y el modelo lo omitió o deformó |
| **P — post-proceso** | La respuesta cruda lo tenía y `answer_safety_processor` lo tumbó |

La categoría P existe porque la Fase 6a es fail-closed y "tumba algún par
correcto documentado sólo en prosa" (diagnóstico §3) — hay que separarla de G
o se arreglará el prompt para un fallo que causa un filtro.

**Salida:** tabla caso × categoría × hecho faltante, commiteada junto a este
plan. Si un caso es genuinamente ambiguo, una consulta acotada a Opus 5 —
no una re-corrida.

## Fase 3 — Intervención mínima, sólo en la rama dominante

**Regla previa a cada intervención (§8.3 del diagnóstico):** declarar por
escrito (a) la medición barata que la justifica, (b) el resultado esperado si
la hipótesis es falsa. Verificar con `RAG_SEGURIDADES_CASE_IDS=<casos>` sobre
los casos afectados (1–3 llamadas) **antes** de cualquier corrida completa.

- **Rama G — generación.** Modelo: Sonnet 5. Ajustes de prompt de generación
  o configuración de `retrieve_and_generate`. Prohibido (medido, §5):
  texto después de `$output_format_instructions$`, `stop_sequences`,
  reintento para `canned_with_retrieval`, ampliar `top_k` pinneado en
  comparativas.
- **Rama R — recuperación.** Modelo: Haiku 4.5. Pase de metadatos sobre los
  sidecars de los chunks afectados (enriquecer, nunca quitar), resync del KB.
  0 llamadas a Claude. **No** re-ingestar, **no** `delete_prefix`, **no**
  tocar `bulk_chunks/` con artefactos derivados.
- **Rama P — post-proceso.** Modelo: Sonnet 5. Poner
  `answer_safety_processor` tras flag; medir los casos afectados con flag
  on/off. Si tumba más pares correctos de los que protege → flag off por
  defecto y se documenta. Esto *reduce* regex en la aplicación, no lo aumenta.

Presupuesto de la fase: **< 20 llamadas Bedrock dirigidas** en total. Si un
arreglo pide más que eso para demostrarse, es la señal de que no es
quirúrgico: se detiene y se reporta.

## Fase 4 — Gate de salida a piloto (holdout v2, UNA corrida)

**Modelo:** Haiku 4.5. **Costo:** ~10 llamadas Bedrock.

1. Criterio definido **antes** de abrirlo: ≥ 70/88 y cero fallos en casos
   `safety_critical` (si el v2 los marca).
2. Una corrida contra producción, artefacto y hash anotados.
3. **Pasa** → liberar a piloto (con 0c ya resuelto).
   **No pasa** → los fallos del v2 se clasifican con el método de la Fase 2;
   el v2 queda gastado; se congela v3 sólo si de verdad hay otro ciclo. Dos
   ciclos fallidos seguidos = parar y re-plantear con humanos, no iterar.

---

## Qué NO está en este plan (y no se negocia dentro de él)

- Nada de visión: T1, T2, zoom, triaje visual, selector de evidencia — todo
  apagado se queda apagado. Dos hipótesis ya fueron refutadas con datos.
- Nada que llame a la API de Anthropic desde la aplicación (sin saldo →
  vacío silencioso).
- Ninguna corrida completa de rúbrica sobreajustada (`seguridades-v3.2`,
  `pilot-v1.2`) como evidencia de nada.
- Ningún prompt nuevo "por si acaso": cada llamada facturable aparece en una
  fase con su costo declarado.

## Presupuesto total estimado

| Concepto | Estimado |
|---|---|
| Llamadas Bedrock (Fases 1+3+4) | ~40 llamadas `retrieve_and_generate` con Haiku → **< $2** |
| Sesiones de IA (Haiku/Sonnet, sesiones cortas) | dominado por lectura; **1–2 órdenes de magnitud menos** que los ~$500 ya gastados |
| Llamadas a la API de Anthropic desde la app | **$0** (ninguna) |

## Estado

| Fase | Estado | Artefacto / hash |
|---|---|---|
| 0a arnés parametrizado | pendiente | — |
| 0b holdout v2 congelado | pendiente | — |
| 0c account_id resuelto | **hecho 2026-08-02** — decisión: la cuenta 1 es la del piloto (opción a); backfill corrido en producción vía Kamal: `KbDocument 12` ya existía, `in home list: true`, `RESULT: OK` | Nota: quedan aliases contaminados del bug de enriquecimiento (p. ej. `"ALJO Control Level 1B Altius"`) — el script sólo los limpia cuando repara `display_name`. No bloquea; limpiar sólo si una medición lo justifica. |
| 1 holdout v1 medido | pendiente | — |
| 2 fallos clasificados | pendiente | — |
| 3 intervención (rama __) | bloqueada por Fase 2 | — |
| 4 gate v2 → piloto | bloqueada por Fase 3 | — |
