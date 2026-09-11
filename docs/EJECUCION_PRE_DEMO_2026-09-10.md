# Ejecución pre-demo — noche del 10-sep

**Estado:** documento vivo. Se actualiza al cerrar cada fase.
**Objetivo:** cerrar los defectos visibles detectados en las respuestas del RAG antes de la reunión con Gonzalo (viernes 11-sep, 09:30).
**Referencias:** [PREP_REUNION_GONZALO_2026-09-11.md](PREP_REUNION_GONZALO_2026-09-11.md) §2–§4 · [script/AGENTS.md](../script/AGENTS.md) (*Running against production*).

---

## Contexto de producto (§2 del prep)

| Capacidad | Estado |
|---|---|
| Consulta documental multimarca con cita de documento y página | **Existe y está en producción** |
| Comprensión de fotos (consolas, tarjetas, planos) | **Existe** |
| Declaración de ausencia de evidencia | **Existe** |
| Trazabilidad de sesión | **Existe** |
| Aislamiento por cuenta y usuarios nominales | **Existe** — falta crear usuarios nominales de Gonzalo |
| Circuito de voz del certificador | **En construcción** — borrador persistente sí |
| Voz conversacional manos libres | **No existe** |

**Corpus piloto** (`piloto.danebo.ai`, cuenta 3): 180 PDF, 10.442 páginas, seis marcas (KONE 62, Thyssen/TKE 37, BLT 30, OTIS 24, Fuji Yida 23, Mitsubishi 4). Hueco de contenido efectivo: 0 páginas (solo fuera `KONE_Parts_2002.pdf` por decisión de producto).

---

## Producción — patrón de ejecución (script/AGENTS.md)

La imagen desplegada **no contiene** `script/`. Pasar el script por **stdin**:

```bash
CID=$(ssh -i ~/.ssh/smart-deal-deploy.pem ubuntu@54.163.248.39 \
  "docker ps --filter label=service=smart-deal --filter label=role=web \
   --filter status=running --format '{{.Names}}' | head -1")
ssh -i ~/.ssh/smart-deal-deploy.pem ubuntu@54.163.248.39 \
  "docker exec -i -e PILOT_BATTERY_ACCOUNT_ID=3 $CID bin/rails runner -" \
  < script/ejemplo.rb
```

Reglas incidentales: **pin the role** (web, no `kamal app exec` sin `--roles=web`); **polling reads en `ActiveRecord::Base.uncached`**.

---

## Regla del documento vivo

Cada fase termina escribiendo su bloque y, si un hallazgo invalida algo posterior, edita el bloque de esa fase **antes** de continuar. Nunca se avanza con "Ajustes a fases siguientes" vacío si hubo hallazgo.

---

## Fase 1 — Confirmar el off-by-one en vivo

**Estado:** cerrada — **hipótesis confirmada**

Inicio / fin: 23:47 → 23:56 (10-sep). Sonda: `script/span_offset_probe_2026-09-10.rb` (read-only, sin modificar código: dos `prepend` en proceso sobre `Aws::BedrockAgentRuntime::Client#retrieve_and_generate` y `Bedrock::CitationProcessor#add_span_citations`). Ejecutada por stdin en el contenedor web de producción (`smart-deal-web-861eba1`), `PILOT_BATTERY_ACCOUNT_ID=3`. Coste: 2 `retrieve_and_generate` (~3.152 y ~4.900 tokens de entrada, 221 y ~600 de salida) ≈ US$0,02.

Resultado:

**`span.end` es inclusivo.** En ambas preguntas el `end` cae exactamente sobre el índice del último carácter del pasaje citado, nunca sobre el espacio o la puntuación siguiente:

| Pregunta | `chars` | `start` | `end` | `answer[end]` | `answer[end-3..end+3]` | `answer[start..end]` (cola) |
|---|---:|---:|---:|---|---|---|
| 6 (KONE LCE) | 772 | 0 | **771** | `"."` | `"ndo."` | `" que está utilizando."` |
| 8 (Fuji Yida) | 1.976 | 0 | **1975** | `"."` | `"nto."` | `"a este procedimiento."` |

`end == chars - 1` en los dos casos, y `answer[end]` es el punto final de la frase citada. `add_span_citations` inserta con `answer_text[0...offset]`, es decir **antes** de `answer[end]`, así que el marcador aterriza un carácter demasiado pronto — visible en la respuesta real de la pregunta 6: `…que está utilizando[1].` en lugar de `…que está utilizando.[1]`. **Fase 2 = `+1` acotado a `answer_text.length`**, no snap a límite de palabra.

Descartes conseguidos con la misma corrida:

- **No viene de `extract_doc_refs`:** `base_eq_raw=true` en las dos preguntas — el texto que recibe `add_span_citations` es idéntico a `response.output.text` crudo (no hubo bloque `<DOC_REFS>` residual que desplazara offsets).
- **No es un desfase de codificación (bytes vs caracteres):** los offsets son **de carácter**, no de byte. Pregunta 8: 1.976 caracteres / 2.013 bytes, y `end=1975 = chars-1`; si fueran bytes sería 2012. La ventana en bytes (`byteslice`) sale corrida (`"ual del"` frente a `"nto."`) precisamente porque los acentos son multibyte. La indexación de Ruby sobre `String` es la correcta y no hay que convertir nada.

Hallazgos fuera de plan:

1. **La pregunta 6 (KONE LCE) NO es terreno fuerte — es un hueco de contenido.** La respuesta empieza con «La documentación recuperada no contiene información sobre una tarjeta denominada "LCE"» y el único chunk citado es `MPDK136 - COMMISSIONING MANUAL.pdf` p. 200 (BLT, tarjeta **MCTC-JT-IC** de control de accesos), que no tiene relación con la placa LCE de KONE. Esto contradice el Plan B del prep, que apoya el guion en «KONE LCE».
2. **Enumeración de otra marca sobre una ausencia.** Tras declarar la ausencia, la respuesta enumera cuatro tipos de tarjeta ajenos a la pregunta (MCTC-JT-IC, tarjetas de datos de usuario, de tiempo, de propietario) y cuelga `[1]` de la frase de cierre «verifique el modelo exacto…», que no es una afirmación citable. Es exactamente el defecto que ataca la Fase 3, ahora con caso reproducible y `correlation_id` (`query:28c48353-c321-4292-8cae-81a6d24906df`).
3. **Un solo grupo de citación que cubre la respuesta entera.** En las dos preguntas Bedrock devolvió `groups=1` con `start=0`. En la 8 ese grupo agrupa **3** `retrieved_references`, así que `add_span_citations` concentra `[1][2][3]` en un único punto al final. El `+1` corrige la posición, pero no reparte la atribución: es un límite del contrato de Bedrock, no un defecto nuestro. No ampliar el alcance de la Fase 2 por esto.
4. **Aurora auto-pause: 23 s en la primera consulta.** La pregunta 6 pagó un reintento de arranque en frío (`The Aurora DB instance … is resuming after being auto-paused`, espera 15 s, total 23.174 ms); la 8, ya caliente, 8.612 ms. La primera pregunta del día ante Gonzalo se vería así.
5. **Fuji Yida sí es terreno fuerte.** La pregunta 8 devolvió una parametrización estructurada y correcta (P01/P02/P03/P06/P12 contra placa, L01=5, L02=2048, curvas S=0, ganancias PID, compensación de carga) sobre 3 chunks de los dos manuales Yida (castellano p. 154/156, inglés p. 151).

Ajustes a fases siguientes:

- **Fase 2:** confirmado `+1` con `clamp(0, answer_text.length)`. El test debe fijar el caso medido: span inclusivo terminando en `.` ⇒ marcador **después** del punto. No introducir snap a límite de palabra.
- **Fase 3:** el contrato anti-enumeración debe cubrir el patrón observado — cuando se declara ausencia, prohibir enumerar componentes de otra marca/documento y prohibir marcador de cita en la frase de cierre («verifique el modelo…»), que no es afirmación con evidencia.
- **Fase 5:** **sustituir la pregunta 6 (KONE LCE)** — no hay evidencia en el corpus. Usar la 5 (KONE LCB II) como pregunta KONE y verificar que sí resuelve; si tampoco, KONE no entra al guion. La 8 (Fuji Yida) queda como ancla.
- **Fase 6:** el guion **no puede** apoyarse en «KONE LCE» (Plan B del prep, línea final). Terreno fuerte verificado hasta ahora: Fuji Yida. Añadir al guion una consulta de calentamiento antes de la reunión para no pagar los 23 s de Aurora delante de Gonzalo.
- **Plan B (§ final):** corregido — quitar «KONE LCE» de la lista de terreno fuerte.

---

## Fase 2 — Fix de citas con test

**Estado:** cerrada — **fix aplicado, suite completa en verde. Sin commit.**

Inicio / fin: 00:00 → 00:06 (11-sep).

Resultado:

`Bedrock::CitationProcessor#add_span_citations` ahora inserta en `span.end + 1` acotado a `answer_text.length` cuando el span existe. El fallback sin span (`answer_text.length`) queda igual: no recibe `+1`.

Se añadió una defensa de límite de palabra (`word_boundary_offset`, clase `/[\p{L}\p{M}\d]/`): si el offset resultante cae **dentro** de una palabra (carácter de palabra a ambos lados), avanza hasta el final del token. No se dispara en el caso medido en Fase 1 — el offset aterriza sobre un espacio o el fin de cadena — así que no cambia el comportamiento en producción; solo evita `destin[1]o` si el contrato del span cambiara.

Tests (`test/services/bedrock/citation_processor_test.rb`):

- Nuevo: span inclusivo terminando en la última letra de «destino» ⇒ `destino[1]`, con aserción explícita de que no aparece `destin[1]o`.
- Nuevo: offset en mitad de palabra («principal») avanza al límite ⇒ `principal[1]`.
- Ajustados al contrato inclusivo los dos tests de span (`-1` en los fixtures de `span_end`). El test de dos referencias mantiene `span_end: answer.length` a propósito: ahora ejercita el `clamp` con el `+1`.

Verificación: `bin/rails test test/services/bedrock/ test/services/rag/ test/services/bedrock_rag_service_test.rb` + el de guardia de atribución ⇒ 623 runs, 0 failures. Suite completa ⇒ **2.923 runs, 11.557 aserciones, 0 failures, 0 errors**. RuboCop limpio en los tres archivos tocados.

Hallazgos fuera de plan:

1. **El contrato exclusivo también estaba fijado en `test/services/bedrock_rag_service_attribution_guard_test.rb`.** Tres tests esperaban `"Dato Thyssen[1]."`. Los fixtures (`raw_answer.index(".")`) ya eran correctos bajo el contrato inclusivo —el índice del punto final—, así que solo se corrigieron las aserciones a `"Dato Thyssen.[1]"`. `Rag::CitationAttributionGuard` no necesitó cambios: segmenta por corridas de marcadores, y el marcador desplazado un carácter sigue cerrando el mismo segmento (el descarte del segmento ajeno y la reparación de costura se comportan igual).
2. **Sin coste Bedrock.** Toda la fase se validó con fixtures; cero llamadas a `retrieve_and_generate`.

Ajustes a fases siguientes:

- **Fase 4 (gate de deploy):** el gate ya tiene su evidencia local (suite completa en verde). Falta únicamente commit + deploy; el cambio es de una sola línea de posición de marcador, sin migración ni variable de entorno nueva.
- **Fase 5:** al revisar las 12 preguntas, verificar la posición del marcador en la respuesta real (debe quedar **después** del punto). Es la única señal visible de que el fix llegó a producción.

---

## Fase 3 — Contrato anti-enumeración en el prompt

**Estado:** pendiente

Inicio / fin:

Resultado:

Hallazgos fuera de plan:

Ajustes a fases siguientes:

---

## Fase 4 — Gate de deploy

**Estado:** pendiente

Inicio / fin:

Resultado:

Hallazgos fuera de plan:

Ajustes a fases siguientes:

---

## Fase 5 — Batería de las 12 preguntas

**Estado:** pendiente

Las 12 preguntas de §4 del prep (ninguna delante de Gonzalo):

| # | Marca | Pregunta |
|---:|---|---|
| 1 | BLT | ¿Qué significa el código de error de la tarjeta MPK 708A y qué reviso primero? |
| 2 | BLT | Tengo un código de error en un BL6, ¿qué indica? |
| 3 | OTIS | ¿Qué significan los códigos de la serie LG-Sigma en un OTIS? |
| 4 | Thyssen | En un CMC-3 hidráulico, ¿qué se revisa cuando el equipo no responde a la llamada? |
| 5 | KONE | ¿Cómo se hace la puesta en servicio de la placa LCB II y qué se verifica antes de energizar? |
| 6 | KONE | ~~¿Qué hace la tarjeta LCE y dónde está su configuración?~~ **Descartada en Fase 1: sin evidencia en el corpus** (cita un manual BLT sin relación). No usar en el guion. |
| 7 | BLT | ¿Cuáles son los pasos de puesta en marcha del MPDK136 / MPDK176? |
| 8 | Fuji Yida | ¿Cómo se parametriza el variador en un Yida y qué valores trae por defecto? |
| 9 | OTIS | Foto consola/URM: ¿Qué equipo es esto y qué me está mostrando? *(manual: ya probada OK)* |
| 10 | Mitsubishi/BLT | En el plano, ¿por dónde va el circuito de la serie de seguridad y en qué bornes? |
| 11 | Variador | ¿Cómo se configura un WEG en lazo abierto para un ascensor? |
| 12 | Schindler/Fermator | ¿Qué significa este código en un Schindler? *(respuesta correcta: no hay evidencia)* |

Inicio / fin:

Resultado:

Hallazgos fuera de plan:

Ajustes a fases siguientes:

---

## Fase 6 — Ajuste del guion

**Estado:** pendiente

Inicio / fin:

Resultado:

Hallazgos fuera de plan:

Ajustes a fases siguientes:

---

## Fuera del alcance del ejecutor (manual)

- Los 5 recorridos del circuito de voz (§3 tarea 3 del prep).
- Confirmar el 09:30 con Gonzalo (§3 tarea 1).
- Cargar fotos propias en la galería del teléfono (§3 tarea 5).
- Dejar la app abierta y logueada en el teléfono (§3 tarea 4).

---

## Plan B (sin deploy)

Si Fase 1 no confirma la hipótesis en 20 min, o Fase 4 no pasa el gate: saltar Fases 2–4, ejecutar solo Fases 5 y 6. El guion absorbe los defectos visibles eligiendo terreno fuerte (BLT, Fuji Yida; foto consola/tarjeta, no plano).

> **Corregido en Fase 1 (10-sep 23:56):** «KONE LCE» **no** es terreno fuerte — el corpus no documenta esa placa y la respuesta cita un manual BLT sin relación. Queda fuera de la lista. La cobertura KONE del guion depende de validar la pregunta 5 (LCB II) en la Fase 5.
