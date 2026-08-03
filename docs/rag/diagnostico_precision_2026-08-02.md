# Diagnóstico de precisión RAG — 2026-08-02

**Para qué sirve este documento:** es la entrada para escribir el próximo plan.
No es un plan. No propone fases. Dice qué está medido, qué no, y cuál es la
única medición que falta para poder decidir.

**Regla que este diagnóstico existe para imponer:** *medir antes de construir*.
El plan anterior (`plan_conocimiento_visual.md`) hizo lo contrario y costó
semanas y ~$500 de API para un delta de precisión de cero.

---

## 1. La premisa que hay que corregir primero

Circulan dos cifras contradictorias y las dos son ciertas. Confundirlas es lo
que descarriló el trabajo anterior.

| Cohorte | Resultado | Fecha | ¿Se puede confiar? |
|---|---|---|---|
| 12 casos, rúbrica `seguridades-v3.2` | **12/12, 83/88** | 2026-07-26 | ⚠️ **sobreajustada** |
| Piloto 10q, rúbrica `pilot-v1.2` | **10/10** | 2026-07-28 | ⚠️ **sobreajustada** |
| Muestreos aleatorios de 10 preguntas (`10q_v2`, `v3`, `v4`, `v4_1`) | siguen mostrando imprecisiones | 07-29 → 08-02 | sí, y es la señal honesta |
| **Holdout v1** (`script/fixtures/rag_seguridades_holdout_v1.json`) | **nunca se abrió** | — | sería la única cifra limpia |

La cifra `62/88` que aparece en documentos y conversaciones es del **2026-07-23**
y está superada. Quien la cite hoy está leyendo un informe caducado.

**Por qué las cohortes verdes no prueban nada.** Las dos rúbricas certificadas se
iteraron contra sus propios casos: `v2 → v3.1 → v3.2` y `pilot-v1.0 → v1.2`. Cada
iteración ajustó el sistema —y a veces la rúbrica— hasta que los casos pasaron.
Eso es sobreajuste por construcción, no fraude, pero significa que **83/88 no
predice el comportamiento sobre una pregunta nueva**. Los muestreos aleatorios,
que no se tocaron, siguieron fallando. Esa contradicción **es** el diagnóstico:
no sabemos cuál es la precisión real del sistema.

---

## 2. La única medición que falta, y cuesta una corrida

`script/fixtures/rag_seguridades_holdout_v1.json` existe, tiene **10 casos**, y
**nunca se ha ejecutado** (no hay ningún artefacto en `tmp/`). Es un holdout
verdadero: no se usó para ajustar nada.

**Ábrelo una vez, con lo que hay hoy en producción, y anota el número.** Esa
cifra es el punto de partida de cualquier plan. Sin ella, todo lo que se decida
es una apuesta — que es exactamente lo que pasó con el plan visual.

Condiciones para que la cifra valga:
- Una sola corrida. Un holdout que se corre dos veces deja de ser holdout.
- Sin tocar nada antes de correrlo.
- Anotar el fallo **caso por caso**: qué chunks recuperó, qué afirmación falló,
  y si el fallo fue de **recuperación** (el hecho no estaba en el contexto) o de
  **generación** (estaba y el modelo lo ignoró o lo deformó).

Esa clasificación —recuperación vs. generación— es la bifurcación del plan
siguiente. Son problemas distintos con soluciones distintas, y hoy nadie sabe
cuál domina. El plan visual asumió que era recuperación, y asumió además que la
causa era la pérdida de información visual. Nunca se comprobó.

---

## 3. Qué está construido y apagado

Todo mergeado, con tests, inerte mientras los flags estén apagados:

| Capacidad | Flag | Estado medido |
|---|---|---|
| Extracción de geometría del PDF (T1) | `INGESTION_LAYOUT_DIGEST_ENABLED` | 19 aristas, **100 % de precisión**, **4,6 % de recall** |
| Tier de visión (T2) — relaciones | `INGESTION_VISION_TIER_RELATIONS_ENABLED` | **refutado**: 88,2 %, LI 81,6 % < 85 % |
| Teselas de zoom para T2 | `INGESTION_VISION_TIER_ZOOM_TILES` | **refutado**: 88,49 %, LI 84,14 % < 85 % |
| Identidad de componente (T2) | — | pasó el gate (38/38) pero **no llega al chunk**: nadie consume `Result#components` |
| Triaje visual del router | `INGESTION_VISUAL_TRIAGE_ENABLED` | construido, sin medir contra respuestas |
| Selector de evidencia / expansión / tarjetas | `RAG_EVIDENCE_*` | **NO-GO del Paso G**, no desplegar |

**Nada de esto está indexado.** Los 97 chunks de producción son contrato v7, sin
un solo `TOPOLOGY_EDGE`. Encender un flag sólo afecta a documentos ingestados a
partir de ese momento.

**Lo único del plan visual que sí cambia respuestas hoy** es la Fase 6a
(`rag/answer_safety_processor.rb`, `1ecd41c`), que va **sin flag** y ya está en
`main`: bloquea toda relación `A → B` cuyos extremos no aparezcan juntos en una
línea `ACTION:` de la evidencia. Es fail-closed: sube precisión relacional y
tumba algún par correcto documentado sólo en prosa.

---

## 4. Por qué el plan anterior no sirvió, en una línea

Contó **líneas** (80 de 98 páginas tienen ≥10 segmentos) y concluyó que había
relaciones extraíbles. Construyó tres fases sobre esa inferencia. Cuando por fin
contó **relaciones derivables**, eran el 4,6 %. Un script de un día, antes de
escribir código de producción, habría dado ese número.

El próximo plan tiene que invertir el orden: **la medición barata primero, y la
construcción sólo si la medición la justifica.**

---

## 5. Lo que está prohibido repetir (medido, no opinado)

- **No re-ingestar `SEGURIDADES 1.1-1`.** La corrida del 2026-07-25 bajó la
  precisión de 62/88 a 57/88. El daño no fue borrar, fue **re-trocear peor**.
- **No `script/reingest_seguridades_2026-07-25.rb`.** Hace `delete_prefix`.
- **No** añadir texto después de `$output_format_instructions$` en el prompt de
  generación. Colapsa las respuestas en el "Sorry" canónico. Ha pasado tres veces.
- **No** ampliar el `top_k` de documento pinneado para preguntas comparativas:
  regresión medida.
- **No** añadir reintento para `canned_with_retrieval`.
- **No** desplegar el selector de evidencia (NO-GO del Paso G).
- Los comandos de benchmark deben **sobreescribir las variables del KB de
  producción**: el `.env` local apunta a desarrollo.
- Verificar casos sueltos con `RAG_SEGURIDADES_CASE_IDS` antes de gastar una
  corrida completa de rúbrica.

---

## 6. Lo que sí quedó y tiene valor

- **La verdad-terreno del Gate A**: 153 relaciones leídas a mano contra las
  láminas (`gate_a_medicion_topologia.md` §5, §6, §8, §9). Es la parte cara e
  irrepetible, y sirve para evaluar cualquier cosa futura.
- **Tres hipótesis descartadas con datos**, que ya no hay que volver a pagar.
- **El holdout sin abrir**, que es el activo más valioso que queda porque es la
  única medición no contaminada disponible.

---

## 7. Ítem abierto que no es de precisión

Los sidecars de los 97 chunks llevan `account_id: "1"` y
`BedrockRagService#account_filter` filtra la recuperación por cuenta. Si la base
de datos del piloto no tiene la cuenta 1, el documento **no se lista en la UI del
técnico** (los gates sí pasan porque el benchmark resuelve por otra vía).

Dos salidas, y es una decisión de negocio, no técnica:
1. La cuenta 1 existe en la base del piloto → correr
   `script/backfill_seguridades_kb_document_2026-07-26.rb` allí.
2. La cuenta del piloto es otra → reescribir `account_id` en los 97 sidecars y
   resincronizar el KB. Pase de metadatos, **cero llamadas a Claude**.

No crear la fila de catálogo bajo otra cuenta: el PDF se listaría y no
recuperaría nada.

---

## 8. Forma recomendada del próximo plan

1. **Medir el holdout.** Una corrida. Un número.
2. **Clasificar los fallos** en recuperación vs. generación, caso por caso.
3. **Sólo entonces** decidir dónde intervenir, y exigir que cada intervención
   propuesta declare *antes de construirse* cuál es la medición barata que la
   justificaría y cuál sería su resultado si la hipótesis fuese falsa.
4. Ninguna fase que construya antes de tener esa medición.

**Coste estimado de los pasos 1 y 2:** una corrida de 10 preguntas contra el KB
de producción, más lectura humana o de un modelo caro de los fallos. Es el orden
de magnitud de una comida, no de un plan de semanas.
