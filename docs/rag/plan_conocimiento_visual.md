# Plan: capacidad de generar conocimiento desde documentos técnicos visuales complejos

> **Estado:** Fases 0-3, 2b y 3b cerradas. El Gate A falló (4 aristas falsas de 23) y **el
> Gate A-bis SE SUPERÓ** (2026-08-01, I-26): **19 aristas en 18 páginas, 19/19 correctas, 0
> incorrectas**, revisadas todas con visión. **La Fase 4 sigue bloqueada**, y no por el gate:
> falta la **decisión humana #4** — *¿Fase 7 con T1 solo o se espera a T2?* — que el Gate A-bis
> expuso y **está esperando respuesta escrita del dueño del producto** (ver "Decisión humana #4").
> Los dos números para responderla: precisión **100 %**, recall **4,6 %**.
> Lo ejecutan varios modelos, una fase cada uno.
> **Antes de tocar código, lee "Cómo usar este documento".**

---

## Cómo usar este documento

Eres el modelo asignado a **una** fase. Nadie te va a dar el contexto que produjo este plan:
está todo aquí y en el Apéndice.

**Lectura obligatoria antes de empezar, en este orden:**

1. Este documento completo, incluido el **Registro de hallazgos de implementación** al final:
   contiene correcciones de fases anteriores que pueden invalidar lo que lees arriba. Si una
   sección está marcada `⚠️ revisado en I-NN`, la entrada `I-NN` gana.
2. [AGENTS.md](AGENTS.md) y el `AGENTS.md` con scope de cada directorio que toques
   (`app/services/rag/`, `app/prompts/`, `app/services/bedrock/`, `test/`).
3. `docs/ACTIVE_ARCHITECTURE.md` y `docs/RAG_SEGURIDADES_STATUS.md`.
4. `docs/rag/hallazgos_gate_piloto.md` (H-01…H-05, hallazgos abiertos de la Fase 2 anterior).
5. [`docs/rag/gate_a_medicion_topologia.md`](gate_a_medicion_topologia.md) — la medición real de
   T1 sobre las 98 páginas, con **todas** las aristas revisadas una a una con visión (23 en el
   Gate A, las 19 vigentes en el Gate A-bis), los defectos que hicieron fallar el primer gate y la
   **verdad-terreno de la Fase 8**. Si tu fase toca ingesta, geometría o evaluación, ese informe
   manda sobre los apéndices de aquí.
   ✅ **Actualizado por el Gate A-bis (I-26), y es un único documento** — se reescribió en el
   sitio, no hay informe nuevo. Sus §1, §2, §3, §4.1-4.5, §7 y §10 traen ya las cifras vigentes
   (19 aristas / 18 páginas / 100 % de precisión / 4,6 % de recall) y §4.6, §4.7 son límites
   nuevos. §5, §6, §8 y §9 —la verdad-terreno humana, los divisores, los títulos, las filas LED y
   los verbatims— no se tocaron: es la parte cara y sólo se hizo una vez.

**Reglas de la ejecución:**

- **Sólo tu fase.** Si ves algo roto en otra, se registra como hallazgo, no se arregla.
- **Un flag por fase, apagado por defecto.** Ninguna fase 1-5 cambia el comportamiento de
  producción al mergear.
- **`bin/rails test` + `bin/rubocop` verdes antes de entregar.** La suite base es de 1987 runs
  / 0 failures; cualquier fallo nuevo es tuyo.
- **Sin dependencias nuevas.** HexaPDF, pdf-reader, ruby-vips e image_processing ya están en
  el Gemfile. Si crees necesitar una gema, es un hallazgo, no una decisión.
- **Nada nuevo bajo `bulk_chunks/`** salvo chunks y sus sidecars. Es el único prefijo que el
  data source de Bedrock indexa (chunking `NONE`: 1 `.txt` = 1 chunk del KB). Manifests,
  backups y cachés van fuera.
- **Al cerrar, actualiza este documento** siguiendo el *Protocolo de traspaso*.

**Invariantes que ninguna fase puede romper:**

| Invariante | Dónde vive |
|---|---|
| `$output_format_instructions$` es lo **último** del prompt de generación | `bedrock_rag_service.rb:905-933`; romperlo colapsa las respuestas en el "Sorry" canónico. Ya pasó tres veces |
| Sin `stop_sequences` en generación RAG | `AGENTS.md:156-162` |
| `section_identity == section_path.first` | Garantía de retrocompatibilidad de la Fase 4 |
| Máximo 1 etiqueta de sección prepuesta a los aliases de chunk | `chunk_merger_service.rb:154-159`, `CHUNK_ALIAS_LIMIT = 8` |
| Sin literales de fabricante/modelo/placa en `app/services/rag/*`, `bedrock_rag_service.rb`, `rag_retrieval_profile.rb` | `test/architecture/no_hardcoded_equipment_test.rb`, allowlist congelada que sólo puede encoger |
| Sin visión en runtime; el enriquecimiento visual es en ingesta | `docs/RAG_SEGURIDADES_BENCHMARK.md:109-115` |
| Las llamadas `Retrieve` internas no crean filas en `bedrock_queries` | `AGENTS.md:171-175` |

---

## Contexto

Smart_Deal está bloqueada para piloto porque los benchmarks de precisión no alcanzan umbral y
los muestreos aleatorios de 10 preguntas siguen mostrando imprecisiones. Se cerró la Fase 2
del Plan Definitivo (`2d6ea8b`, `9941f9e`, `12f7a51`; 1987 runs, 0 failures) y la imprecisión
de fondo persiste — señal de que se venía parcheando en el lugar equivocado.

La revisión humana del PDF SEGURIDADES identificó la sospecha correcta: no es un documento de
texto, son láminas con fotos de placas, componentes pequeños y **relaciones dibujadas**.

**El objetivo de este plan no es que la aplicación procese este documento.** Es dotarla de una
capacidad que hoy no tiene: **generar conocimiento con sentido desde documentos cuya
información es visual y relacional** — esquemas eléctricos, simbología, cableado, fotos de
placa con componentes anotados y enlazados entre sí, componentes pequeños que son parte de un
subconjunto. SEGURIDADES es el primer caso de prueba de esa capacidad, no su alcance.

---

## Diagnóstico: tres defectos independientes, todos en ingesta

### Defecto 1 — La ingesta descarta la geometría que ya está en el PDF

Verificado sobre `SEGURIDADES 1.1-1.pdf` (98 páginas, 960×540, export de PowerPoint):

1. **Las etiquetas son texto real con bounding boxes** (`pdftotext -bbox-layout`). Tabla
   completa de la página 3 en el **Apéndice A**.
2. **Las líneas guía son polilíneas vectoriales extraíbles.** Un
   `HexaPDF::Content::Processor` capturando `move_to`/`line_to` da 73 segmentos largos en la
   página 3: codos en L que **terminan en y≈242-248, exactamente sobre el corchete rotulado
   CONECTOR AI (x 305-385) o CONECTOR AG (x 638-784)**. Encadenando por extremos compartidos
   sale la arista etiqueta→conector. Código verificado en el **Apéndice B**.
3. **El patrón es general dentro del documento:** **80 de 98 páginas** tienen ≥10 segmentos
   largos *y* ≥3 imágenes pequeñas. 12 páginas con 0 segmentos (divisores). 0 sin imágenes.
   Censo en el **Apéndice C**.
4. **Nada de eso llega al modelo.** No hay rasterización, OCR ni extracción de layout en el
   repo (0 hits de textract/ocr/pdftoppm/poppler/rasterize).
   [pdf_page_splitter_service.rb](app/services/pdf_page_splitter_service.rb) parte la página en
   un PDF de una hoja y
   [batch_chunking_prompt.rb:502-512](app/prompts/batch_chunking_prompt.rb#L502-L512) la manda
   como bloque `document`. El modelo recibe las etiquetas **en orden de lectura**, que es lo
   que destruye la agrupación: `tmp/pdfs/seguridades.txt` muestra el aplanamiento literal —
   `CONECTOR AI  CONECTOR AG / LIMITADOR / FINAL …`.
   [page_image_density_analyzer.rb](app/services/page_image_density_analyzer.rb) sólo lee
   *dimensiones* de XObjects; `PdfImageDetector` sólo *presencia*.
5. **El contrato v7 entonces prohíbe adivinar, correctamente.**
   [batch_chunking_prompt.rb:310-335](app/prompts/batch_chunking_prompt.rb#L310-L335)
   (*"line position is not evidence"*) y
   [generation.txt:35-39](app/prompts/bedrock/generation.txt#L35-L39).

### Defecto 2 — El router nunca escala a visión para documentos visualmente complejos

[file_multimodal_router.rb:126-137](app/services/file_multimodal_router.rb#L126-L137) manda una
página a Opus 4.8 sólo si `text_layer_chars < 100 && image_area_ratio > 0.7`.

**Eso es un gate de "página escaneada", no de "complejidad visual".** Una lámina con dos fotos
de placa, 15 componentes fotografiados, etiquetas y líneas de relación —pero con títulos
tipeados— tiene miles de chars de capa de texto y **nunca lo cruza**. Resultado: las 98 páginas
de este documento fueron a Sonnet 4.6; **Opus 4.8 no se activó ni una vez**.

Es un defecto general, no una particularidad del PDF: cualquier documento técnico moderno
(export de PowerPoint/CAD, manual con capturas anotadas) cae en el mismo agujero. Y es
plausible que Opus, viendo la lámina, sí hubiera captado relaciones que Sonnet aplanó — no está
medido, y medirlo es el Gate B.

**El clasificador correcto ya existe y ya se paga.**
[page_relevance_filter.rb:409-419](app/services/page_relevance_filter.rb#L409-L419)
(`BatchFilter::HAIKU_BATCH_SYSTEM`) ya recorre cada página con Haiku en ventanas de ≤20 páginas
para decidir keep/drop. Ampliar **su schema JSON** para que en la misma llamada emita un
veredicto de complejidad visual cuesta ~0 tokens extra y es exactamente el triaje descrito: el
modelo barato decide, el caro sólo entra donde hace falta.

### Defecto 3 — Producción está dos contratos por detrás

Los 97 chunks indexados se parsearon con `field_records_v5` / `ingestion_path: web_v1`; el
código está en v7. Subir el contrato no re-parsea. **Toda mejora de prompt es inerte hasta
re-ingestar.** Además `section_identity` es una etiqueta **plana** (≤60 chars) cuando la
jerarquía real está impresa en tres niveles en el divisor (`ALJO` / `CONTROL LEVEL 1B` /
`ALTIUS`) más el subtítulo de página.

### Lo que NO es el problema

- **`AnswerSafetyProcessor` no rechaza esto.** `IDENTIFIER_PATTERN`
  ([:18-30](app/services/rag/answer_safety_processor.rb#L18-L30)) matchea `X…`, `CN-\d`, `B\d`,
  `C\d`, `[DLT]\d`, `LED-?\d` — **nunca `CONECTOR AI`/`AG`**. El guard ni se dispara. Lo único
  que rechaza este conocimiento es un párrafo del prompt. Verificado leyendo el patrón.
  ⚠️ **revisado en I-24:** sigue siendo cierto de `IDENTIFIER_PATTERN` (que no se tocó), pero
  desde la Fase 6a ya no es cierto del guard: un par de extremos digit-less se valida ahora
  contra las líneas `ACTION:` de la evidencia, sin vocabulario de equipo.
- **Retrieval.** `RagRetrievalProfile:13-39` documenta dos rechazos **medidos** de los tweaks
  obvios (top_k 6 bajó un caso de 5/7 a 0/7; 5 preguntas no rankean ni en top-20 porque el
  contenido no está). El input del embedding es el cuerpo del chunk escrito por la ingesta.
- **La audiencia del prompt.** `generation.txt` ya declara "technical field assistant for
  elevator technicians" y el de ingesta "Senior Elevator Systems Engineer". Acotar más no
  mejora nada: el fallo es evidencia ausente, no tono.
- **Las rúbricas.** Los 42 casos son controles negativos de alucinación y son la única prueba
  de que la relajación de la Fase 6 no filtró. Se congelan; la ampliación es aditiva.

> **El sistema se comporta como fue diseñado. El diseño está desnutrido, no roto.**
> Reingeniería **parcial y sólo en ingesta**.

---

## Arquitectura objetivo: matriz de capacidades por página

La generalidad no viene de un caso especial, viene de clasificar cada página por **la señal que
tiene disponible** y aplicar el motor correspondiente. Los cuatro tiers escriben en el **mismo
contrato v8**, así que retrieval y generación son agnósticos al motor que produjo el
conocimiento.

| Señal disponible | Tier | Motor | Coste | Salida |
|---|---|---|---|---|
| Texto plano estructurado, sin relaciones | **T0** | Sonnet 4.6 (como hoy) | bajo | chunks + `field_records` |
| Capa de texto **+** vectores (80/98 aquí) | **T1 geométrico** | Rails determinista, 0 LLM | ~0 | `TOPOLOGY_EDGE` `method: leader_line` ¹ |
| Imagen densa sin vectores / sin capa de texto | **T2 visión** | Opus 4.8 + prompt de relaciones sobre ráster + crops | alto, acotado | `TOPOLOGY_EDGE` `method: vision` |
| Ambas señales | **T1 + T2** | T1 ancla, T2 reconoce; T1 gana en conflicto | medio | ambos, con procedencia distinguible |

¹ ⚠️ **revisado en I-09, en I-20 y confirmado con visión en I-26.** Que 80/98 páginas *tengan* la
señal no significa que T1 derive algo en ellas: medido con el derivador ya implementado, T1 emitía
alguna arista en 22 de 98 páginas (23 aristas). **Cerradas 2b y 3b y superado el Gate A-bis, la
cifra es 19 aristas en 18 de 98 páginas, las 19 verificadas correctas una a una.** El resto de la
relación dibujada de este documento **cae en T2**, y ésa es la cifra con la que hay que
dimensionarlo, no 80.

**Complementariedad, no competencia.** T1 sabe *que* la etiqueta `LIMITADOR` está unida al
`CONECTOR AI` por una línea trazada, pero no sabe qué es la foto pequeña de 105×183 que está al
lado. T2 sí puede reconocerla. T1 aporta el **anclaje** (bbox de cada imagen pequeña y su
etiqueta adyacente); T2 aporta el **reconocimiento**. Eso es el caso "identificar visualmente
componentes pequeños que son parte de un subconjunto".

**T1 es verdad-terreno gratis para calibrar T2.** En las 80 páginas donde ambos aplican, las
aristas deterministas de T1 permiten medir y calibrar el prompt de visión de T2 sin trabajo
humano. Eso es lo que hace confiable a T2 en los documentos donde T1 no puede correr — y es la
clave de la generalidad. Es el Gate B.

⚠️ **revisado en el Gate A y confirmado en el Gate A-bis — esta premisa no se sostiene en este
documento.** Revisadas las 23 aristas una a una con visión: **4 eran falsas** (I-13, I-14) y las
19 correctas caen en 18 páginas y se reducen a **~15 pares distintos**. Tras 2b/3b, las 19 están
**limpias** (100 % de precisión, I-26) pero **siguen siendo 19**: el Gate A-bis arregló la mitad
"no está limpia" del problema y no tocó la mitad "es demasiado pequeña", que es la que decide.
La verdad-terreno útil de este documento la escribió el Gate A **a mano, con visión**: 153
relaciones en 11 páginas de 10 secciones.

**El triaje asigna el tier antes de parsear**, dentro de la llamada Haiku que ya existe, con un
tope de presupuesto que escala a Opus primero las páginas de mayor complejidad.

---

## Modelo recomendado por fase (para implementar)

Regla: el modelo barato hace el trabajo mecánico con especificación cerrada; el caro hace
juicio algorítmico, seguridad y visión.

| Fase | Qué es | Modelo | Por qué |
|---|---|---|---|
| 0a | `I18n.with_locale` en un `around_action` | **Haiku** | Un archivo, fix mecánico, verificación por suite |
| 0b | Guard de colisión de placas hermanas (H-03) | **Sonnet** | Toca una decisión de seguridad y una tabla de 36 casos |
| 1 | Triaje de clase de documento y complejidad | **Sonnet** | Extiende un schema y un router existentes; especificación cerrada |
| 2 | Extractor de geometría | **Sonnet** | API de HexaPDF verificada y snippet dado (Apéndice B); la trampa es la convención de coordenadas, cubierta por test |
| 3 | Derivador de aristas T1 | **Opus** | Algoritmo geométrico con guardas de correctitud; una arista falsa citada es el peor fallo del sistema |
| Gate A | Medición + verdad-terreno contra el PDF | **Opus** | Requiere visión para leer las páginas y comparar contra lo derivado |
| 2b | Texto rotado en el extractor (I-13) | **Sonnet** | Especificación cerrada y decisión ya tomada; se verifica con fixture |
| 3b | Guarda anti-ráster en el derivador (I-14) | **Opus** | Lógica de seguridad: una arista falsa citada es el peor fallo del sistema |
| Gate A-bis | Re-medición con la misma muestra | **Opus** | Requiere visión para comparar contra la página renderizada |
| 4 | Contrato v8 | **Sonnet** | Muchos archivos, hilado mecánico; invariantes cubiertos por test |
| 5 | Motor T2 visión | **Opus** | Diseño de prompt de extracción de relaciones + razonamiento visual |
| Gate B | T1 como verdad-terreno para calibrar T2 | **Opus** | Juicio comparativo e iteración de prompt |
| 6a | Endurecimiento de `AnswerSafetyProcessor` | **Opus** | Lógica de seguridad; un falso negativo deja pasar una alucinación |
| 6b | Párrafo de `generation.txt` + controles negativos | **Sonnet** | El párrafo va escrito verbatim abajo; el trabajo son los tests |
| 7 | Script de shadow ingest | **Sonnet** | Guion operativo con invariantes explícitos |
| 7-go | Revisión del diff de 6 páginas y go/no-go | **Opus** | Juicio + visión contra el PDF antes del paso irreversible |
| 8 | Batería de eval ampliada | **Sonnet** | Los `required` se generan del digest, no se inventan |
| 9 | Promoción (re-apuntar el pin) | **Haiku** | Operativo |
| 10 | Diseño de foto-consulta (sin código) | **Sonnet** | Documento de diseño |

### Protocolo de traspaso entre fases (obligatorio)

Cada fase, al cerrar, **actualiza este mismo documento** antes de entregar:

1. Añade su entrada en **Registro de hallazgos de implementación**, con ID `I-NN`, siguiendo la
   convención de `docs/rag/hallazgos_gate_piloto.md`.
2. Si un hallazgo invalida una premisa de una fase posterior, **edita esa fase en el sitio** y
   marca el cambio con `⚠️ revisado en I-NN`.
3. Si un umbral o número medido difiere de lo escrito aquí, gana el medido y se corrige el texto.
4. Marca la fase como cerrada en la **Tabla de estado de fases** y anota el commit.

La fase siguiente lee el documento actualizado, no el original.

### Tabla de estado de fases

| Fase | Estado | Flag | Commit | Cerrada por |
|---|---|---|---|---|
| 0a | cerrada | — | e187323 | I-01 |
| 0b | cerrada | — | 72fc7ee | I-02 |
| 1 | cerrada | `INGESTION_VISUAL_TRIAGE_ENABLED` | 2f0bfd3 | I-04, I-05, I-06 |
| 2 | cerrada | — (offline) | 09c813b | I-07, I-08 |
| 3 | cerrada | — (offline) | ed8bd56 | I-09, I-10, I-11, I-12 |
| Gate A | **NO SUPERADO** — informe entregado | — | f7aa592 | I-13 … I-18 |
| 2b | cerrada — cierra I-13 (parcialmente: ver I-28) | — (offline) | f4ab397 | I-19 |
| 3b | cerrada — cierra I-14 | — (offline) | 1cb789b | I-20, I-21, I-22 |
| Gate A-bis | **SUPERADO** — 19/19 correctas, 0 incorrectas, todas revisadas con visión | — | 582ede3 | I-26 … I-29 |
| 4 | **bloqueada por la decisión humana #4** (el gate ya está aprobado; falta la respuesta escrita del dueño del producto) | `INGESTION_LAYOUT_DIGEST_ENABLED` | | |
| 5 | pendiente | `INGESTION_VISION_TIER_ENABLED` | | |
| Gate B | pendiente | — | | |
| 6a | cerrada | — | 1ecd41c | I-24, I-25 |
| 6b | pendiente | — | | |
| 7 | pendiente | — | | |
| 8 | pendiente | — | | |
| 9 | pendiente | — | | |
| 10 | pendiente | — | | |

### Paso 0 — Publicar este plan en el repositorio

Este documento vive hoy en `~/.claude/plans/`, fuera del repo. Los modelos que ejecuten cada
fase no lo encontrarán ahí. **Primera acción antes de la Fase 0:** copiarlo a
`docs/rag/plan_conocimiento_visual.md` y commitearlo. A partir de ese momento **esa copia es la
canónica**: el Protocolo de traspaso se aplica sobre ella, y cada fase la actualiza en su propio
commit. Añadir el puntero en `docs/README.md` bajo las referencias RAG activas.

### Mapa de dependencias y paralelización

```
0a ──┐                      (independientes entre sí y de todo lo demás)
0b ──┤
     │
1  ──┼── (independiente de 2/3; sólo la Fase 5 la necesita)
     │
2  ──┴──▶ 3 ──▶ GATE A ──▶ 4 ──▶ 5 ──▶ GATE B ──┐
                              │                  │
6a ──▶ 6b ────────────────────┴──────────────────┴──▶ 7 ──▶ 8 ──▶ 9

10 ── (independiente, sólo documento)
```

⚠️ **revisado tras el Gate A (no superado) y de nuevo tras el Gate A-bis (superado).** El tramo
real desde aquí:

```
GATE A (fallido) ──▶ 2b ✅ ──▶ 3b ✅ ──▶ GATE A-bis ✅ ──▶ [decisión humana #4] ⏳ ──▶ 4 ──▶ 5 ──▶ GATE B ──▶ 7 …
                     f4ab397     1cb789b      100 %, 0 falsas    ← AQUÍ ESTAMOS: esperando
                                                                   respuesta escrita del dueño
```

**2b antes que 3b, sin excepción:** 3b consume el contrato que 2b arregla y una de sus guardas
depende de la marca `rotated:`. **6a · 6b · 10 siguen siendo paralelizables** con todo esto: no
tocan ningún archivo de ingesta. La **Fase 8 ya no está bloqueada por el Gate A** — su verdad-terreno
se entregó completa en `gate_a_medicion_topologia.md` aunque el gate fallara, así que puede
escribirse en paralelo a 2b/3b, con la salvedad de que sus `required` de topología no existirán
hasta que haya aristas indexadas.

| Se puede hacer en paralelo | Motivo |
|---|---|
| 0a · 0b · 1 · 2 · 10 | Tocan archivos disjuntos y ninguna depende de otra |
| 6a · 6b junto a 2/3/4 | 6 es del lado de respuesta; 2-4 del lado de ingesta. Cero solape de archivos |
| — | **3 requiere 2** (consume su contrato de datos) · **Gate A requiere 3** · **4 requiere Gate A aprobado** · **5 requiere 1 y 4** · **7 requiere 4, 5 y 6** |

**Serializaciones obligatorias, no negociables:** nada entra a la Fase 4 sin el Gate A aprobado
(≥85 % de aristas correctas, 0 incorrectas); nada entra a la Fase 7 sin el Gate B cerrado y la
Fase 6 mergeada. **6a va siempre antes que 6b** — el endurecimiento antes de la relajación, no
al revés.

**Conflictos de archivo a vigilar** si se paraleliza: la Fase 1 y la Fase 2 tocan las dos
`page_image_density_analyzer.rb` (la 1 lee su salida, la 2 añade `images:`). Que la Fase 2 la
modifique y la 1 sólo consuma; si ambas escriben, hay merge manual y hallazgo.

⚠️ **revisado en I-05.** La Fase 1 terminó **sin tocar** `page_image_density_analyzer.rb` (el
conflicto de archivo no llegó a ocurrir): el segundo disparador geométrico del router necesitaba
datos (segmentos largos, imágenes pequeñas) que sólo `PdfLayoutExtractor` (Fase 2) formalizará,
así que se implementó un probe privado y no contractual directamente en
`file_multimodal_router.rb` (`FileMultimodalRouter#geometry_signal` + `SegmentCollector`
privado). Ver I-05 para el detalle y la decisión pendiente de si Fase 2 debe deduplicar esto
una vez exista el contrato de `PdfLayoutExtractor.extract`.

---

## Contratos de datos entre fases

Esto es lo que una fase entrega y la siguiente consume. **No lo cambies sin registrar un
hallazgo y editar la fase consumidora.**

### `PdfLayoutExtractor.extract(page_binary)` → Fase 2 produce, Fases 3 y 5 consumen

```ruby
{
  page_number: 3,
  media_box:   [0, 0, 960, 540],          # ancho/alto en unidades PDF
  words: [                                 # coordenadas HexaPDF, y desde ABAJO
    { text: "CONECTOR AI", bbox: [305.0, 236.0, 385.0, 250.0] },
    { text: "LIMITADOR",   bbox: [504.0, 155.0, 560.0, 168.0] },
    { text: "B", bbox: [781.3, 322.6, 790.3, 329.2], rotated: true }  # ⚠️ I-13/Fase 2b
  ],
  lines: [                                 # segmentos rectos, sin curvas
    { from: [332.2, 153.3], to: [332.2, 248.1] },
    { from: [333.3, 154.7], to: [252.4, 154.7] }
  ],
  rects:  [ { bbox: [x0, y0, x1, y1] } ],
  images: [                                # de PageImageDensityAnalyzer ampliado
    { name: "Image35", width: 1920, height: 1080, bbox: [...], size_class: :large },
    { name: "Image58", width: 105,  height: 183,  bbox: [...], size_class: :small }
  ],
  text_layer_chars: 1_842,
  image_area_ratio: 0.61
}
```

Reglas: **una sola pasada** del processor. `words` agrupa glifos en cadenas visualmente
contiguas, no en orden de lectura del stream. `lines` excluye segmentos de longitud
`|Δx|+|Δy| ≤ 20` (ruido de bordes y subrayados finos). Curvas (`curve_to`) se cuentan pero no
se emiten.

⚠️ **revisado en Fase 2b (cierra I-13).** `rotated:` es una clave **aditiva**: presente y `true`
sólo en las entradas cuyo glifo tiene la matriz de texto rotada (detectado por eje, no por el
signo del bbox agregado — ver el archivo); **ausente**, no `false`, en el resto. No cambia la
forma de las entradas no rotadas ni el orden del array. El `text` de una entrada `rotated: true`
**no está en orden de lectura** (I-13): la Fase 3b debe ignorarla como extremo de arista, nunca
citarla. De paso se corrigió `merge_into_words` para que un rótulo que cambia de tipografía a
mitad (p. ej. el divisor de la página 8, `CARLOS` → `SILVA`) ya no pierda el límite de palabra: la
tolerancia del hueco usa la altura **menor** de los dos glifos adyacentes, no sólo la del anterior.

### `TopologyEdgeDeriver.derive(layout)` → Fase 3 produce, Fase 4 consume

```ruby
[
  { from: "LIMITADOR", to: "CONECTOR AI", method: :leader_line,
    evidence: "polilínea (485.6,154.9)->(405.2,154.1)->(405.8,248.1) une LIMITADOR (x 504-541, y 154-161) con CONECTOR AI (x 316-382, y 231-240)",
    chain: [[485.6,154.9],[405.2,154.1],[405.8,248.1]] }
]
```

⚠️ **revisado en I-09 e I-11.** El ejemplo de arriba es ahora la salida **real y verificada** de
la página 3; el que estaba escrito aquí antes (`(332.2,153.3)->(332.2,248.1)->(252.4,154.7)`) era
ilustrativo y geométricamente imposible — esos tres puntos no forman una cadena en el PDF. Dos
cambios de contrato, ambos en I-11: (a) la redacción de `evidence` es `… une X (bbox) con Y
(bbox)`, no "termina en el corchete rotulado …" — el derivador no detecta corchetes; (b) `from`
y `to` están ordenados **geométricamente** (el extremo más abajo en la página primero) y **no son
una afirmación de dirección**: la geometría no dice cuál extremo es el componente y cuál el
conector, así que la Fase 4 no debe presentar la flecha como direccional.

Reglas: si una etiqueta no resuelve, **no aparece en el array**. Sin entradas parciales, sin
`nil`, sin `confidence` numérica. El array vacío es una salida válida y frecuente (12 páginas
divisoras) — y, medido en I-09, también en **76 de las 98 páginas**.

### `PageLayoutDigest.render(layout, edges)` → Fase 2/3 producen, Fase 4 consume

Texto plano, **≤400 tokens**, en contenido de **usuario**. Sólo: aristas resueltas, bboxes de
etiquetas que participan en una arista o en una fila de tabla, e inventario de imágenes con su
`size_class` y bbox. Sobre el tope ⇒ devolver `nil` y loguear. **No es un volcado de words.**

### Veredicto de triaje → Fase 1 produce, Fase 5 consume

Campos añadidos por página al JSON que ya devuelve `BatchFilter`:
`visual_complexity` (`none|moderate|high`), `has_visual_relations` (bool),
`component_count` (entero).

---

## Plan por fases

Decisión tomada: **medir antes de gastar**. Las fases 2-3 son offline, coste ~0, riesgo 0, y
producen la evidencia dura del Gate A.

### Fase 0 — Correcciones de bajo riesgo, independientes · Haiku (0a) / Sonnet (0b)

Cierra las dos decisiones abiertas de la Fase 2 anterior.

**0a · H-05 (suite dependiente del orden).**
[locale_switchable.rb:17](app/controllers/concerns/locale_switchable.rb#L17) asigna
`I18n.locale` global en un `before_action` sin restaurar; con hilos Puma reutilizados
(`RAILS_MAX_THREADS=5`) se filtra fuera de la request. Es el único `I18n.locale =` sin scope del
repo; todo lo demás ya usa `I18n.with_locale`. Fix:
`around_action { |_, blk| I18n.with_locale(resolved, &blk) }`.

*Definición de terminado:*
- [x] `locale_switchable.rb` usa `around_action` + `I18n.with_locale`; ninguna asignación global
- [x] `bin/rails test` **9 veces seguidas**, 0 failures (el síntoma era 1 de 9 con 7 fallos en
      `document_overview_responder_test.rb` esperando `"Documento:"` y recibiendo `"Document:"`)
- [x] `bin/rubocop` limpio
- [x] H-05 marcado cerrado en `docs/rag/hallazgos_gate_piloto.md`

**0b · H-03 (hueco de seguridad).** `BoardHeading.mentioned?("EDEL-K3 …", "… EDEL-K2 …")` es
`true`: `word_match?` acepta 4 chars de prefijo común y las hermanas con guion comparten seis.
Desde la Fase 2 anterior eso decide "responder en vez de preguntar"
([ambiguous_model_responder.rb:113-137](app/services/rag/ambiguous_model_responder.rb#L113-L137))
⇒ con una sola hermana recuperada el técnico recibe respuesta **sobre la placa equivocada**.

**Fix sin tocar `word_match?`**: capa de rechazo `sibling_conflict?` dentro de `mentioned?` — si
un token de la etiqueta y uno de la pregunta comparten raíz pero difieren en sufijo, exigir
match exacto de token. `word_match?` no se modifica para que la tabla de 36 casos siga verde.

*Definición de terminado:*
- [x] `mentioned?("EDEL-K3 …", "… EDEL-K2 …") == false`, con test
- [x] `mentioned?("EDEL-K3 …", "… EDEL-K3 …") == true`, con test
- [x] Los 36 casos de `test/services/rag/board_heading_test.rb` intactos, sin editar aserciones
- [x] `test/services/rag/ambiguous_model_responder_test.rb`: con una sola hermana recuperada y
      la pregunta nombrando la otra, se devuelve **menú**, no respuesta
- [x] Suite completa + rubocop verdes; H-03 cerrado en el libro de hallazgos

**Housekeeping:** `.claude/settings.json` sigue modificado desde la Fase 0 original — commit o
revert, y anotarlo.

### Fase 1 — Triaje de clase de documento y complejidad visual · Sonnet

La palanca de generalidad. **No añade ninguna llamada LLM.**

- **Extender el schema de la llamada Haiku que ya corre**
  ([page_relevance_filter.rb:409-419](app/services/page_relevance_filter.rb#L409-L419)). Hoy
  devuelve `{"pages":[{"page":N,"keep":bool,"reason":"…"}]}`. Añadir por página:
  `visual_complexity` (`none|moderate|high`), `has_visual_relations` (bool: ¿hay líneas,
  llamadas o flechas que enlacen elementos entre sí?), `component_count` (imágenes pequeñas
  rotuladas). Instrucción: **clasificar, no describir** — el coste está en los tokens de salida.
  La decisión `keep`/`drop` actual **no cambia de semántica**; si cambia, es un hallazgo.
- **Nuevo** `app/services/document_class_profile.rb`: agrega los veredictos de página a una
  clase de **documento** (`text_manual | visual_technical | mixed | photo_set`) y fija
  presupuesto y tiers por defecto. Se apoya en el `Result` que
  [file_multimodal_router.rb](app/services/file_multimodal_router.rb) ya devuelve.
- **Corregir el gate del router** (`route_page`, :126-137). El gate actual
  (`text_chars < 100 && ratio > 0.7`) se **conserva** como detector de página escaneada, y se le
  añade un segundo disparador de complejidad visual: **polilíneas presentes Y ≥N imágenes
  pequeñas**, o `visual_complexity: high` del triaje. Con eso una lámina con títulos tipeados sí
  escala. Fijar N con el censo del Apéndice C, no a ojo.
- **Tope de presupuesto explícito.** El triaje ordena las páginas por complejidad y el router
  escala a Opus sólo hasta una fracción configurable
  (`ContractualLimits::MANUAL[:max_opus_page_fraction]`, hoy `1.0` — fijar un valor real). El
  resto va a Sonnet.
- Flag: `INGESTION_VISUAL_TRIAGE_ENABLED`, misma forma que los `app/services/rag/*_flag.rb`.

*Definición de terminado:*
- [x] Tests offline con respuestas Haiku dobladas: schema ampliado parseado, campos ausentes
      degradan a `visual_complexity: :none` sin excepción
- [x] Test de que con el flag apagado el routing es **byte-idéntico** al actual
- [x] Test de que el tope de fracción se respeta y escala por orden de complejidad descendente
- [x] **Entregable numérico**: clasificación de las 98 páginas por tier + **proyección de coste**
      de cada fracción de escalada (0 %, 25 %, 50 %, 100 %), en
      `docs/rag/triaje_visual_medicion.md`. **Sin ese número el flag no se activa.**
- [x] Suite + rubocop verdes (2033 runs / 0 failures; 462 files, 0 offenses en los archivos de
      esta fase — ver I-04/I-05/I-06 para las decisiones de diseño no explícitas en el plan)

### Fase 2 — Extractor de geometría (offline, impacto cero) · Sonnet

- **Nuevo** `app/services/pdf_layout_extractor.rb` — **un único**
  `HexaPDF::Content::Processor` que en **una sola pasada** captura cajas de glifos
  (`decode_text_with_positions`) y `move_to`/`line_to`/`append_rectangle`. Un procesador, no dos.
  Código base verificado en el **Apéndice B**.
- **Nuevo** `app/services/page_layout_digest.rb` — serializador acotado en tokens.
- **Modificar** `page_image_density_analyzer.rb`: extender `compute_image_area` (:64-88) para
  devolver también `images: [{name:, width:, height:, bbox:, size_class:}]`. ⚠️ revisado en I-07:
  no son ~6 líneas — el `bbox` de posición requiere el CTM vigente en cada operador `Do`, que el
  recorrido de `Resources` no tiene. El `bbox` es lo que después permite a T2 recortar cada
  componente y a T1 anclarlo a su etiqueta. **No cambiar la forma de retorno existente** —
  añadir la clave; `PageRelevanceFilter` y `FileMultimodalRouter` la consumen hoy.

**Convención de coordenadas fijada: todo en el sistema de HexaPDF (y desde abajo).** `pdftotext`
es top-down; mezclarlos es el bug obvio de esta fase. Conversión: `y_hexapdf = alto − y_pdftotext`
(en la página 3, `CONECTOR AI` está en y=298 top-down = **y≈242 bottom-up**). Test explícito.

*Definición de terminado:*
- [x] `PdfLayoutExtractor.extract` devuelve exactamente el contrato de datos de arriba
- [x] Test sobre un PDF fixture de 3 páginas comprometido en `test/fixtures/files/`
      (`pdf_layout_extractor_sample.pdf`)
- [x] Test explícito de convención: una etiqueta conocida tiene `y` bottom-up, y el test falla si
      alguien la invierte
- [x] Test de que `PageLayoutDigest.render` devuelve `nil` sobre el tope de 400 tokens
- [x] Test de que `PageImageDensityAnalyzer` mantiene sus claves previas
- [x] Nada del código de producción invoca aún el extractor (grep que lo demuestre) — cubierto por
      test, no sólo manual
- [x] Suite + rubocop verdes (2033 runs / 0 failures; 462 files, 0 offenses) — ver I-07/I-08

### Fase 3 — Derivador de aristas T1 (offline) · Opus

- **Nuevo** `app/services/topology_edge_deriver.rb`: encadena polilíneas por extremos compartidos
  y resuelve la etiqueta de destino.

**Guardas de correctitud** (una arista falsa citada es el peor fallo posible de un sistema de
seguridad):
- el extremo terminal debe caer **dentro del bbox de una etiqueta impresa** (+ tolerancia
  explícita y justificada, no mágica);
- cadena de ≤4 segmentos;
- exactamente una etiqueta en cada extremo;
- **ambiguo ⇒ no emitir nada.** La negativa de hoy es correcta ahí.

**`method: column_proximity` no se implementa.** Una arista débil en el cuerpo del chunk será
recuperada y citada, y el calificador `method:` es lo primero que se pierde al parafrasear. Sólo
`leader_line`. El enum queda abierto a `vision`.

⚠️ **revisado en I-09 y en I-20.** Las cuatro guardas de arriba resultaron necesarias pero **no
suficientes** contra la geometría real: hicieron falta tres rechazos más en la Fase 3 (unión T,
etiqueta que la cadena *atraviesa*, y texto que no es un nombre) y **dos más en la Fase 3b**
(etiqueta a la que otra etiqueta impresa gana en cercanía a la imagen sobre la que muere el
extremo, y etiqueta rotada), cada uno con su contraejemplo medido. Además
las líneas guía de este documento son en su mayoría **bucles** que salen de un terminal del
conector y vuelven a otro del mismo conector, con el componente en el medio: ambos extremos
resuelven a la misma etiqueta y no se emite nada. Detalle y cifras en I-09.

*Definición de terminado:*
- [x] Fixture página 3: las aristas resueltas se comparan contra el **Apéndice D** — 2 aristas
      (`FINALES`↔`CONECTOR AI`, `LIMITADOR`↔`CONECTOR AI`), ambas en la lista humana de AI
- [x] **Caso fixture #1 — `ACUÑAMIENTO`:** resuelve a la salida **(c) ninguna arista**, y por
      evidencia, no por descarte: ningún extremo de cadena cae dentro de la tolerancia de esa
      etiqueta (la única línea cercana la *pasa* a 6.4 pt). La proximidad en x nunca se consulta.
      Aserción explícita en `topology_edge_deriver_test.rb`
- [x] Fixture de **cadena mala conocida** que debe resolver a **cero** aristas (`known_bad_layout`:
      cadena de 5 segmentos, bifurcación, bucle a su propia etiqueta, unión T, cable que corre por
      debajo de la etiqueta que reclamaría, y fila de números de borne)
- [x] Fixtures de las páginas 17 / 32 / 63 (secciones distintas), aristas revisadas a mano contra
      la página renderizada: 63 → 1 arista correcta; 17 y 32 → `[]` correcto (ver I-09)
- [x] Test de que una página divisora (sin segmentos) devuelve `[]` sin excepción (página 2 real)
- [x] Suite + rubocop verdes (2056 runs / 0 failures; 464 files, 0 offenses); nada en producción
      invoca el derivador, cubierto por test

### ⛔ Gate A — Medición (entregable de las fases 2-3) · Opus

Correr extractor + derivador sobre las 98 páginas y escribir
`docs/rag/gate_a_medicion_topologia.md` con:

- aristas resueltas por página y total; páginas con 0 aristas y **por qué** (divisor, sin
  vectores, ambigüedad rechazada);
- **tasa de acierto contra lectura humana** en ≥6 páginas de secciones distintas, incluida la 3
  (verdad-terreno en el Apéndice D). Leer las páginas con visión y comparar, no asumir;
- `section_path` de 3 niveles derivado de las 12 páginas divisoras, contra el Apéndice E;
- filas de tabla LED con su agrupación;
- **cuántas páginas quedan sin cobertura T1** (dimensiona T2);
- resolución del caso `ACUÑAMIENTO`.

⚠️ **revisado en I-09.** La Fase 3 ya corrió extractor + derivador sobre las 98 páginas como
control propio: **23 aristas en 22 páginas**; las otras 76 devuelven `[]`. De esas 23, las **9 que caen en 8
páginas (3, 11, 12, 14, 52, 63, 93, 95) se revisaron a mano con visión** contra la página
renderizada y **0 son incorrectas**; 17 y 32 se revisaron y su `[]` es correcto. Eso **no sustituye al
Gate A**: falta la tasa contra lectura humana en ≥6 páginas *completas* (cuántas de las aristas
que un humano ve quedan sin derivar, que aquí es la mayoría), el `section_path`, las filas LED y
el dimensionado de T2. Punto de partida, no entregable.

**Umbral para continuar: ≥85 % de aristas correctas y 0 incorrectas en la muestra revisada.**
Si no se alcanza, **parar y registrar el hallazgo**; no seguir a la Fase 4. Este entregable es
además la verdad-terreno de la Fase 8, así que no se desperdicia si se para aquí.

⛔ **EJECUTADO — NO SUPERADO.** Informe en
[gate_a_medicion_topologia.md](gate_a_medicion_topologia.md). Medido sobre las 98 páginas: 23
aristas en 22 páginas; **las 23 revisadas una a una con visión sobre la página rasterizada**;
**4 incorrectas** (págs. 56, 61, 67, 97). Precisión 63,6 % en la muestra de 11 páginas / 10
secciones y 82,6 % sobre el documento entero; recall 7 de 153 relaciones humanas ≈ **4,6 %**. Las
tres condiciones del umbral fallan. **La Fase 4 no queda autorizada.** Las 4 aristas falsas se
reducen a dos defectos acotados, ninguno de la Fase 4: **I-13** (la Fase 2 rompe el texto rotado
90°) e **I-14** (la guarda de unicidad de la Fase 3 es ciega ante bornes rasterizados). Ver
también I-15 (los bucles no eran el mecanismo dominante), I-16 (bajar el corte de ruido empeora
la cobertura, contra lo que suponía I-10), I-17 (`section_path` son 2 niveles, no 3) e I-18
(`ACUÑAMIENTO` y la corrección del Apéndice D).

✅ **Reintentado y superado como Gate A-bis** tras cerrar I-13 e I-14: 19 aristas en 18 páginas,
**19/19 correctas, 0 incorrectas**, mismas 11 páginas de muestra, mismo guion (I-26). El informe
enlazado es **uno solo** y ya trae las cifras vigentes; lo de arriba es el estado del primer
intento.

---

### ⚑ Ruta de remediación tras el Gate A fallido (leer antes de tocar nada)

El Gate A no se superó por **4 aristas falsas de 23**, y las cuatro se reducen a **dos defectos
acotados, con contraejemplo medido y página de fixture identificada**: I-13 (texto rotado, Fase 2)
e I-14 (guarda de unicidad ciega ante rásters, Fase 3). No es un fallo de diseño del plan; es un
fallo de dos implementaciones concretas.

**El orden es obligatorio y no negociable: 2b → 3b → Gate A-bis → (decisión humana #4) → Fase 4.**
2b va antes que 3b porque 3b consume el contrato que 2b arregla, y porque una de las guardas de 3b
depende de saber qué es texto rotado y qué no.

✅ **2b, 3b y el Gate A-bis cerrados.** El derivador emite hoy **19 aristas en 18 páginas**, las
cuatro falsas resuelven a `[]`, no aparece ninguna nueva, y las 19 se revisaron una a una con
visión después del cambio: **19/19 correctas, 0 incorrectas — gate superado** (I-26). El informe
`gate_a_medicion_topologia.md` ya está reescrito con esas cifras. **Lo único que queda de este
tramo es la decisión humana #4, que está esperando respuesta.**

**Lo caro ya está hecho y no se repite.** La verdad-terreno humana —153 relaciones leídas con
visión en 11 páginas de 10 secciones, la página 3 completa y corregida, los 18 divisores, los 98
títulos, 272 filas LED y 14 verbatims— está escrita en
[gate_a_medicion_topologia.md](gate_a_medicion_topologia.md). El Gate A-bis **reusa esa muestra y
esos guiones**; sólo vuelve a medir.

| Paso | Qué es | Modelo | Por qué ese modelo |
|---|---|---|---|
| 2b | Texto rotado 90° en `PdfLayoutExtractor` (I-13) | **Sonnet** | Especificación cerrada, dos opciones y la decisión ya tomada abajo; se verifica con fixture |
| 3b | Guarda anti-ráster en `TopologyEdgeDeriver` (I-14) | **Opus** | Lógica de seguridad: una arista falsa citada es el peor fallo del sistema. Es la misma razón por la que la Fase 3 era Opus |
| Gate A-bis | Re-medición con la misma muestra y los mismos guiones | **Opus** | Requiere visión para comparar contra la página renderizada |

### Fase 2b — Texto rotado en `PdfLayoutExtractor` (cierra I-13) · Sonnet

**Decisión ya tomada, no la reabras: se descarta, no se rescata.** Un rótulo rotado se marca y la
Fase 3 no lo usa nunca como extremo de arista. Rescatar el orden de lectura correcto es más
trabajo, más riesgo, y **no compra cobertura** — los bornes que importan están rasterizados
(I-15), no rotados. Lo que compra descartarlos es eliminar dos citas falsas.

- Detectar en `build_words` el glifo con matriz de texto rotada. Señal barata y ya disponible:
  `bbox` con `x0 > x1` o altura ~0. Fijar el criterio con los datos de la página 61, no a ojo.
- Añadir `rotated: true` a esas entradas de `words`. **Es una clave nueva, aditiva**: no cambies
  la forma de las entradas existentes ni el orden del array — la Fase 3 y la 5 consumen el
  contrato tal cual.
- Arreglar de paso el espacio perdido cuando el rótulo **cambia de tipografía a mitad**
  (`CARLOS SILVA` → `CARLOSSILVA`, divisor de la página 8). Es el mismo `merge_into_words`.
- Actualizar el bloque de contrato de datos de este documento con la clave nueva.

*Definición de terminado:*
- [x] Fixture con texto rotado 90° comprometido en `test/fixtures/files/`; test de que sus
      entradas llevan `rotated: true` y las horizontales no
- [x] Test de que ninguna entrada de `words` sale con `bbox` invertido (`x0 > x1`) ni de altura 0
- [x] Test de que un rótulo con cambio de tipografía interno conserva su espacio
- [x] Test de que las claves y el orden previos de `words` no cambian
- [x] Suite + rubocop verdes; nada de producción invoca el extractor todavía (2061 runs / 0
      failures; 469 files, 0 offenses) — ver I-19

### Fase 3b — Guarda anti-ráster en `TopologyEdgeDeriver` (cierra I-14) · Opus

El comentario de `TERMINAL_TOLERANCE_PT` ya dice lo correcto: *lo que hace segura la holgura no es
la distancia, es la unicidad*. El defecto es que **la unicidad se evalúa sólo sobre texto**, y en
este documento el competidor legítimo suele ser un ráster. Hay que darle al derivador una señal de
"aquí hay un rival que no puedo leer".

- **Guarda nueva:** si el extremo de la cadena cae **dentro del `bbox` de una imagen** y la
  etiqueta candidata cae **fuera de esa imagen**, no emitir. El extremo está sobre un gráfico que
  probablemente lleva su propio rótulo impreso dentro; la etiqueta de al lado no es su nombre.
  `images[].bbox` existe en el contrato de la Fase 2 desde I-07 y **hoy no se usa**.

  ⚠️ **revisado en I-20 — esta redacción literal mata dos aristas correctas y hubo que medir la
  frontera.** Cada página de este documento lleva dos imágenes de fondo a página completa, así que
  "el extremo cae dentro de una imagen" es cierto en el 100 % de los casos, y en las págs. 3 y 63
  la etiqueta correcta cae **fuera** del gráfico que rotula. La regla implementada, medida contra
  las seis páginas: **ninguna otra etiqueta impresa con otro nombre puede estar más cerca de esa
  imagen que la candidata**. Subsume la redacción original (una etiqueta dentro de la imagen tiene
  distancia 0 y nadie la supera), vuelve inertes las imágenes de fondo, y separa los cuatro casos
  con margen medido.
- **Guarda nueva:** ignorar como extremo cualquier etiqueta con `rotated: true` (Fase 2b).
- Contraejemplos que deben pasar a `[]`, cada uno con su fixture y su aserción explícita:
  **pág. 56** (`PISO SUPERIOR -> CC2`), **pág. 97** (`PUERTAS FRONTALES -> PESTLLOS TECHO CABINA`),
  **pág. 61** (`CERRADURAS EXTERIORES -> B`), **pág. 67** (`PUERTAS EXTE. -> SE`).
- Y las que **no** pueden romperse: las 19 correctas siguen saliendo. Las más expuestas a la
  guarda nueva son **pág. 3** (`LIMITADOR ↔ CONECTOR AI`, el extremo cae sobre la foto del
  limitador) y **pág. 63** (`ALUMBRADO CABINA ↔ J12`, el extremo cae sobre la lámpara). Si la
  guarda las mata, está mal formulada: la diferencia es que ahí la etiqueta **rotula esa misma
  imagen**, mientras que en la 56 y la 97 rotula otra cosa. Mídelo, no lo supongas.
- **No** cambies `TERMINAL_TOLERANCE_PT`. Está medido en I-09 y bajarlo mata aristas correctas.
- **No** toques el corte de ruido de la Fase 2 ni `MAX_CHAIN_SEGMENTS`: I-16 midió que ninguno de
  los dos compra cobertura y que bajar el corte de ruido la **empeora**.
- Registrar el delta: cuántas de las 23 sobreviven y cuántas aristas nuevas aparecen, si alguna.

*Definición de terminado:*
- [x] Las 4 aristas falsas del Gate A resuelven a `[]`, con fixture y aserción por cada una
      (págs. 56, 61, 67 y 97 añadidas al fixture de layouts reales; dos aserciones por página —
      la arista ausente y la geometría impresa que la hacía falsa)
- [x] Las 19 correctas siguen emitiéndose, con aserción explícita para las págs. 3 y 63
      (medido: 19 aristas en 18 páginas, **0 aristas nuevas**)
- [x] `TERMINAL_TOLERANCE_PT`, `LINE_NOISE_MAX_MANHATTAN_PT` y `MAX_CHAIN_SEGMENTS` sin tocar
- [x] Suite + rubocop verdes (2081 runs / 0 failures; 469 files, 0 offenses); nada de producción
      invoca el derivador, cubierto por test — ver I-20/I-21/I-22

### ✅ Gate A-bis — Re-medición · Opus — **SUPERADO (2026-08-01, I-26)**

> **Resultado, para no volver a medirlo:** 19 aristas en 18 páginas, **19/19 correctas, 0
> incorrectas**, las 19 revisadas con visión sobre el render a 150 dpi. En la muestra congelada de
> 11 páginas: 7 aristas, **7/7 correctas**, y 56/61/67/97 en `[]`. Precisión 63,6 % → **100 %**;
> **recall sin moverse: 4,6 %**. Suite y linter verdes (2090 runs / 0 failures; 469 files / 0
> offenses). Informe reescrito en el sitio; §2, §3.1 y las cifras derivadas ya no son las del
> Gate A. Tres límites conocidos nuevos o ampliados, ninguno una arista falsa: **I-27** (`bbox`
> inflado por espacios sin tinta: 1 de las 19 se emite por eso), **I-28** (`CARLOS SILVA` sigue
> roto: el arreglo de 2b no aplica al PDF real) e **I-29** (3 de las 19 omiten dispositivos
> intermedios de la serie).
>
> **Herramienta añadida:** `script/gate_a/zoom.py` — una arista por imagen, render limpio junto al
> derivado, polilínea amarilla y `bbox` de las etiquetas citadas en cian. `overlay.py` dibuja en
> magenta y varias láminas trazan **cables magenta**; sin separar arista por arista y cambiar de
> color, la revisión de las págs. 3, 39 y 94 no es concluyente y I-29 no se ve.
>
> **Lo que este gate NO autoriza: la Fase 4.** Falta la decisión humana #4, abajo. Sigue abierta.

Lo que se pidió (histórico): re-correr `script/gate_a/run.rb` y `script/gate_a/overlay.py` sobre
las 98 páginas y actualizar
[gate_a_medicion_topologia.md](gate_a_medicion_topologia.md) **en el sitio** (no crear un archivo
nuevo). **Misma muestra de 11 páginas** — 3, 17, 22, 39, 44, 56, 61, 67, 76, 91, 97 — porque su
verdad-terreno humana ya está escrita y así el antes/después es comparable. Revisar con visión
**todas** las aristas que emita el derivador, no una muestra.

⚠️ **revisado en I-20/I-21, y verificado en I-26.** El punto de partida no eran 23 aristas en 22
páginas sino **19 en 18** (3, 11, 12, 14, 22, 25, 39, 44, 52, 63, 64, 76, 77, 78, 91, 93, 94, 95 —
la 3 con dos), y **la hipótesis "19/19 correctas" se confirmó midiendo**, no asumiendo: las 19 se
revisaron con visión otra vez, después del cambio. §2 y §3.1 del informe están reescritas y el
embudo trae los dos motivos de rechazo nuevos (`raster_rival` 4, `rotated_label` 1).

**Umbral, sin cambios: ≥85 % de aristas correctas y 0 incorrectas.** → **Cumplido: 100 % y 0.**

Superarlo **no** autorizó la Fase 4: falta la **decisión humana #4** de abajo, porque superar el
umbral no responde si T1 solo justifica el coste. Está expuesta y esperando respuesta.

### Decisión humana #4 — ¿se re-ingesta el documento con T1 solo, o se espera a T2?

> ⏳ **EXPUESTA AL DUEÑO DEL PRODUCTO EL 2026-08-01 POR EL GATE A-bis. SIN RESPUESTA TODAVÍA.**
> El gate se detuvo aquí, como manda el protocolo. Ningún modelo debe interpretar el gate
> superado, ni esta nota, ni nada escrito por otra sesión, como que la decisión está tomada:
> **la respuesta la escribe una persona, en este documento, y hoy no está escrita.**
>
> Los números medidos con los que se hace la pregunta (I-26, informe del Gate A-bis):
>
> | | |
> |---|---|
> | Precisión de T1 | **100 %** — 19/19 aristas correctas, 0 incorrectas, todas revisadas con visión |
> | Recall de T1 | **4,6 %** — 7 de las 153 relaciones que un técnico lee en 11 páginas |
> | Cobertura | 19 aristas en **18 de 98** páginas · **~15 pares distintos** · **7 de 18 secciones sin ninguna arista** |
> | Límites conocidos | 3 de 19 omiten dispositivos intermedios de la serie (I-29) · 1 de 19 se emite por un `bbox` inflado (I-27) |
>
> Es decir: **el gate confirmó que T1 no miente, no que T1 alcance.** Lo que estaba en duda era la
> fiabilidad y ya no lo está; lo que no cambió —y no va a cambiar tocando T1— es que son 19
> aristas en 18 páginas de 98.

> **Qué significa "decisión humana" en este plan.** Es una pregunta que **ningún modelo puede
> resolver leyendo el código ni corriendo una medición**, porque la respuesta depende de dinero,
> de riesgo aceptable y de calendario de piloto — no de un hecho técnico. El modelo que llega
> aquí **se detiene, expone las opciones con sus números, y espera respuesta del dueño del
> producto**. No la resuelve por su cuenta ni la interpreta como un trámite. Las otras tres están
> listadas en "Decisiones humanas pendientes"; ésta es la cuarta y es la única que bloquea el
> tramo siguiente.

**Quién decide:** el dueño del producto (no el modelo, no el revisor de código).
**Cuándo:** justo después del Gate A-bis, con su número de precisión en la mano.
**Qué hay que responder, literalmente:** *¿se autoriza ejecutar la Fase 7 (shadow ingest, único
paso irreversible del plan) con las aristas de T1 solas, o se espera a tener también T2?*

**El dato que obliga a preguntarlo.** El Gate A-bis dio **100 % de precisión** — y aun así T1
aporta **19 aristas en 18 páginas de 98**, con un recall del **4,6 %** frente a lo que un técnico
lee en la página. Ese "aunque" del plan ya no es hipotético: se midió, y no cambia la pregunta.
Y el riesgo #1 de la tabla de riesgos —que añadir texto de topología **diluya el
embedding y baje** el recall, que es el mecanismo plausible del 62/88 → 57/88 ya medido en el
re-ingest anterior— se paga **entero** por esas 19 aristas, porque el coste del riesgo no depende
de cuántas aristas añadas sino de que toques los cuerpos de los chunks.

| Opción | Qué implica | A favor | En contra |
|---|---|---|---|
| **A · Seguir con T1 solo** | 4 → 6 → 7 (shadow ingest) → 8 → 9, como está escrito | El conocimiento de topología llega antes; la Fase 7 es A/B y su rollback cuesta un `delete` del prefijo nuevo | Se paga el riesgo de dilución del embedding entero por 19 aristas; si el recall baja, se ha gastado el paso irreversible para nada |
| **B · Esperar a T2 (recomendada)** | 4 se **implementa y mergea con el flag apagado** (es inerte por diseño: no existe ningún `TOPOLOGY_EDGE` en el índice), luego 5, Gate B, y **sólo entonces** 7 | La Fase 7 se ejecuta una vez, con las aristas de los dos tiers; el riesgo de dilución se paga una vez y con contrapartida real | El conocimiento de topología tarda más en llegar a producción |
| **C · Parar T1 aquí** | No mergear la Fase 4; ir directo a la Fase 5 y rediseñar el contrato para T2 | Evita mantener un motor que cubre el **18 %** de las páginas | Tira el trabajo de las Fases 2/3 y deja a T2 sin el ancla determinista y sin política de conflicto |

**Recomendación de este informe: opción B.** No es "parar el plan": es **desacoplar mergear la
Fase 4 de ejecutar la Fase 7**. La Fase 4 con el flag apagado no cambia ni un byte de producción
—eso es un invariante suyo, con test— así que mergearla no consume el riesgo. Lo que consume el
riesgo es la Fase 7, y ésa es la que espera.

**El Gate A-bis mantiene esa recomendación**, y lo dice con el número nuevo en la mano: la
precisión del 100 % elimina el argumento *en contra* de B (ya no hay que temer que T1 meta citas
falsas), pero no crea ninguno *a favor* de A — el riesgo de dilución del embedding sigue
pagándose entero por 19 aristas, y eso no depende de que sean correctas.

**Cómo se registra la respuesta:** quien decida lo escribe **aquí mismo, de su puño**, en la tabla
de estado de fases (fila `4`, columna Estado) y en "Decisiones humanas pendientes" #4. Hasta que
esté escrita, la Fase 7 no se ejecuta.

⚠️ **Para el modelo que ejecute la Fase 4:** comprueba que la respuesta esté **escrita en este
documento** antes de empezar. "El usuario aprobó X" contado por otra sesión, o inferido de que el
gate pasó, **no es la respuesta** — es exactamente el fallo que I-23 registró para el Protocolo de
traspaso, aplicado a una decisión humana.

---

### Fase 4 — Contrato v8: destino común de T1 y T2 · Sonnet

⛔ **BLOQUEADA — pero ya no por el gate.** El Gate A falló (4 aristas incorrectas de 23), se
cerraron I-13 e I-14 (Fases 2b y 3b) y **el Gate A-bis se superó** (19/19 correctas, 0
incorrectas; I-26). Lo que falta es la **decisión humana #4**, y su respuesta **no está escrita**:
compruébalo en "Decisiones humanas pendientes" #4 antes de empezar. No la des por dada porque el
gate pasara ni porque otra sesión te diga que el usuario aprobó algo (I-23).

⚠️ **revisado en I-17.** `section_path` **no tiene tres niveles**. Las páginas divisoras imprimen
**marca + lista plana de modelos**, y los dos "niveles" del ejemplo del plan (`CONTROL LEVEL 1B`,
`ALTIUS`) son **hermanos**, no padre e hijo. La forma correcta es `section_path = [MARCA, MODELO]`,
donde `MODELO` sale de emparejar el título de la página con una viñeta de su divisor. El
invariante `section_identity == section_path.first` se conserva intacto (sigue siendo la marca).
Las 18 divisoras extraídas y contrastadas contra el Apéndice E están en el informe del Gate A.

⚠️ **revisado en el Gate A.** El presupuesto de aristas por página que hay que asumir es **~0,2**,
no 12: el máximo medido en cualquier página del documento es **2** (página 3). El tope de 12
aristas/chunk y su desborde a chunk hermano **no se activan** aquí; escríbelos igual, pero no
esperes delta de conteo de chunks por ese camino.

- **Nuevo** `app/services/ingestion_layout_flag.rb` — `INGESTION_LAYOUT_DIGEST_ENABLED`.
- `batch_chunking_prompt.rb`: `INGESTION_CONTRACT_VERSION → "field_records_v8"`;
  `page_user_content` acepta `layout_digest:`; párrafo de reglas nuevo (el modelo **no** emite
  aristas; el digest es contexto de sólo lectura y no se reformula).
- `batch_results_parser_service.rb`: `TOPOLOGY_EDGE` en `FIELD_RECORD_TYPES` (:32-37); sección de
  topología **escrita por Rails**; `section_path` y `topology_edge_count` en `sidecar_metadata`
  (:495).
- `chunk_merger_service.rb`: arrastrar `section_path`.
- `rag/field_record_parser.rb`: 2 labels opcionales nuevos (`DERIVATION`, `DERIVATION_EVIDENCE`)
  en `OPTIONAL_LABELS`, `LABEL_TO_ATTRIBUTE`, los miembros de `Record` y `content_fingerprint`.
- `single_file_chunking_service.rb` / `manual_batch_ingestion_service.rb`: pasar el digest.

**Decisión clave: las aristas de T1 NO son salida del modelo.** Se derivan en Rails y se
renderizan en Rails, junto a `append_field_records` (:399-406). El modelo recibe el digest en
contenido de **usuario**, sólo lectura. `validate_field_record!` (:307-351) **rechaza** un
`TOPOLOGY_EDGE` con `method: leader_line` emitido por el modelo. Ése es el airlock que hace
verdadera la afirmación de procedencia de la Fase 6. (T2 sí emite `method: vision`, y por eso su
procedencia es distinta y más débil.)

*Definición de terminado:*
- [ ] End-to-end sobre un PDF sintético de 6 páginas, flag encendido, doble de S3
- [ ] **Invariante**: `section_identity == section_path.first`, con test
- [ ] **Invariante**: los aliases de chunk siguen recibiendo **exactamente una** etiqueta de
      sección prepuesta
- [ ] **Airlock**: un `field_record` del modelo con `k: "TOPOLOGY_EDGE"` y `method: leader_line`
      **levanta `ParseError`**, con test
- [ ] `DERIVATION` fuera del enum degrada a `DATA_NOT_AVAILABLE` vía `allowlisted_value`
      (:465-468), con test
- [ ] `RECORD_ID` idempotente: la misma geometría re-deriva el mismo ID, con test
- [ ] Tope de 12 aristas/chunk con desborde a chunk hermano, con test del conteo
- [ ] Con el flag apagado, los cuerpos y sidecars son **byte-idénticos** a v7, con test
- [ ] Suite + rubocop verdes

### Fase 5 — Motor T2: visión sobre páginas triadas · Opus

Lo que da la capacidad **general**, para documentos donde no hay vectores que trazar.

⚠️ **revisado en el Gate A, y en I-20.** Dimensionado real: **T2 tiene que correr en las 80
páginas** (79 de contenido relacional + la portada, que no tiene capa de texto). En **61 de ellas
es el único motor posible** (57 antes de que 3b vaciara las cuatro páginas de aristas falsas); en
18 T1 aporta un ancla y nada más. El motivo dominante del silencio de T1 —42,5 % de
los rechazos, dominante en 32 páginas— es que **la numeración de bornes del conector está dentro
del ráster de la regleta, no en la capa de texto** (contraejemplo canónico: la página 17 tiene ~15
relaciones con número de borne explícito y T1 emite `[]`). Eso es exactamente lo que T2 sí puede
leer, y es la mayor palanca de cobertura del plan entero.

- **Nuevo** `app/services/pdf_page_rasterizer.rb` con `Vips::Image.pdfload_buffer` (libvips ya es
  dependencia vía `image_processing`/`ruby-vips`). **Verificar primero** que el libvips de
  `Dockerfile:19` traiga el loader de poppler (`VipsForeignLoadPdfBuffer`); si no, una línea de
  apt y registrarlo como hallazgo. Reutilizar `ImageCompressionService` para acotar bytes.
- **Crops de componentes.** Con los bboxes de la Fase 2, recortar cada imagen pequeña y enviarla
  junto a su etiqueta adyacente. Eso resuelve el reconocimiento de componentes pequeños que son
  parte de un subconjunto.
- **Nuevo prompt de extracción de relaciones**, reutilizando la forma `from`/`to`/`evidence` que
  **ya existe** en
  [field_photo_prompt.rb:55-61](app/prompts/field_photo_prompt.rb#L55-L61)
  (`documented_connections`). **No se inventa schema.**
- Emite los **mismos** registros v8 con `method: vision`.
- Respeta `docs/RAG_SEGURIDADES_BENCHMARK.md:109-115`: enriquecimiento **en ingesta**, nunca
  visión en runtime.
- Flag: `INGESTION_VISION_TIER_ENABLED`.

*Definición de terminado:*
- [ ] Rasterizador con test sobre el fixture; DPI justificado, no mágico
- [ ] Crops anclados a su etiqueta adyacente, con test
- [ ] Prompt de relaciones emitiendo v8 `method: vision`, con test de parseo
- [ ] Test de que sin capa de texto ni vectores el tier igual produce salida
- [ ] Coste por página **medido**, no estimado, registrado en el informe del Gate B
- [ ] Suite + rubocop verdes

### ⛔ Gate B — T1 calibra T2 · Opus

⚠️ **revisado en el Gate A, sin cambios tras el Gate A-bis.** La premisa "80 páginas donde ambos
tiers aplican" es falsa y la corrección de I-09 (22 páginas) todavía se queda corta en el sentido
que importa: **la verdad-terreno gratis de T1 son 19 aristas correctas en 18 páginas, y de ellas
sólo ~15 son pares distintos** (las págs. 44/76/77/78 repiten `LIMITADOR↔C300` en láminas casi
idénticas). Eso **no da significancia estadística** para medir precisión y recall de T2. Que el
Gate A-bis diera 100 % de precisión **no agranda este conjunto ni un par** (I-26). El Gate B tiene
que apoyarse además en verdad-terreno **humana**, y ya existe el primer trozo: **153 relaciones
leídas a mano con visión en 11 páginas de 10 secciones**, en el informe del Gate A. Empieza por
ahí, no por T1.

En las páginas donde ambos tiers aplican, comparar aristas T1 (deterministas) contra T2
(visión) y escribir `docs/rag/gate_b_calibracion_vision.md` con:

- **precisión y recall de T2 contra T1** — verdad-terreno gratis, sin trabajo humano;
- **qué ve T2 que T1 no puede ver** (relaciones en foto ráster, identidad de componentes
  pequeños, agrupaciones semánticas). Aquí se responde empíricamente si Opus habría captado
  relaciones que Sonnet aplanó — la pregunta que originó el Defecto 2;
- coste real por página de T2 y coste total proyectado del documento.

**Salidas obligatorias:**
- el prompt de T2 se itera hasta alcanzar umbral contra T1;
- política de conflicto fijada: **T1 gana siempre**; T2 aporta sólo lo que T1 no cubre;
- si T2 no alcanza precisión suficiente, **se limita a campos no-relacionales** (identidad de
  componente, calidad de imagen) y las relaciones quedan sólo en T1. Esa degradación es
  aceptable y se documenta como límite conocido del producto.

### Fase 6 — Contrato de generación · Opus (6a) / Sonnet (6b)

Se envía **antes** del re-ingest porque es demostrablemente inerte: no existe ningún
`TOPOLOGY_EDGE` en el índice todavía. Se observa delta cero y eso valida el despliegue.

> ⚠️ **revisado en I-24.** Eso vale para **6b**, no para 6a. 6a **sí** cambia respuestas hoy: al
> anclar el soporte de un par a una línea `ACTION:`, degrada también el par correcto que la
> evidencia documenta sólo en prosa o en una fila de tabla (medido). Es fail-closed y es lo que
> pide la instrucción, pero el delta esperado de 6a **no es cero**.

**6a — Endurecimiento primero** (`rag/answer_safety_processor.rb`): rechazar cualquier línea con
`->`/`conect…` cuyo par de extremos no sea un par de substrings de alguna línea `ACTION:` de la
evidencia. Bloquea el encadenado obvio (`A→X` + `B→X` ⇒ `A→B`), que hoy **pasa** para nombres
tipo `CONECTOR`. **No se extiende `IDENTIFIER_PATTERN`**: es sitio congelado en
`test/architecture/no_hardcoded_equipment_test.rb`, y una comprobación agnóstica del corpus es
lo correcto. Es un **endurecimiento**, así que puede y debe ir antes que 6b.

**Cerrada en `1ecd41c`.** Los extremos se leen de la propia línea: la etiqueta en mayúsculas más
cercana a cada lado de una flecha o de un verbo `conect…`/`cablead…`/`wired` (`conector`/
`conectores` son sustantivos y no cuentan como relación). El chequeo es **aditivo**: la ruta de
identificadores conserva su contrato exacto en toda línea cuyos extremos sabe leer, y la nueva
sólo corre donde aquélla no emite veredicto. `IDENTIFIER_PATTERN` quedó intacto. Alcance y
contrapartidas medidas en **I-24** y **I-25**.

**6b — Relajación con procedencia**, reemplazando
[generation.txt:35-39](app/prompts/bedrock/generation.txt#L35-L39):

```
- A physical connection claim ("component → connector/terminal") is supported only
  when the same evidence fragment explicitly names both endpoints as a pair. Seeing
  both labels on a page, nearby labels, or a diagram title is not enough. YOUR OWN
  reading of a line's position is never evidence.
  The one exception is a RECORD_TYPE: TOPOLOGY_EDGE record: its endpoint pair was
  traced from the drawing before indexing, so you may report it. Reproduce its ACTION
  pair verbatim and state it comes from the diagram's traced connection line. When the
  record's DERIVATION is vision, add that it was read from the image and must be
  confirmed against the complete diagram. Never merge two TOPOLOGY_EDGE records into a
  chain, never invert one, and never create one for a pair no TOPOLOGY_EDGE record
  names — for those, say the diagram shows the wiring and it must be confirmed against
  the complete diagram.
```

Tres propiedades: la lectura de posición **por el modelo** sigue prohibida; el encadenado queda
vetado; y la licencia está anclada a un tipo de registro que **sólo la ingesta escribe**, con la
procedencia `leader_line` vs `vision` visible en la respuesta.

*Definición de terminado — controles negativos (Minitest offline, sin Bedrock):*
- [ ] `test/prompts/bedrock_generation_prompt_test.rb`: la inferencia por posición sigue
      prohibida; `$output_format_instructions$` sigue **último**; el párrafo nuevo aparece
      **exactamente una vez** (compactación de prompt, `AGENTS.md:163-165`)
- [x] `answer_safety_processor_test.rb`: `"LIMITADOR -> CONECTOR AI"` **sobrevive** cuando la
      evidencia contiene el bloque `TOPOLOGY_EDGE` — *cubierto por 6a (`1ecd41c`)*
- [x] Mismo archivo: **se rechaza** cuando la evidencia sólo tiene las dos etiquetas en líneas
      separadas. *Éste es el control real* — *cubierto por 6a*
- [x] Mismo archivo: encadenar `A -> B` desde `A -> X` + `B -> X` se rechaza — *cubierto por 6a,
      con arista y con prosa; y la inversión también (⚠️ revisado en I-25)*
- [ ] Mismo archivo: una arista `DERIVATION: vision` llega a la respuesta **con** su calificador
      de verificación en campo; sin él, se rechaza
- [ ] `seguridades_rubric_calibration_test.rb`: los **52 casos pasan sin cambios** (⚠️ revisado
      en I-24: son 52 desde la rúbrica v4.1, no 42), y el renderizado de topología matchea
      **cero** patrones `penalized` de las 6 rúbricas
- [ ] Suite + rubocop verdes

### Fase 7 — Shadow ingest A/B (único paso irreversible, des-riesgado) · Sonnet + Opus (go/no-go)

**No se re-ejecuta `script/reingest_seguridades_2026-07-25.rb`.** Hace `delete_prefix` en un
bucket **sin versionado** y su corrida previa bajó la precisión 62/88 → 57/88; está documentado
como "no repetir" en `docs/RAG_SEGURIDADES_STATUS.md`.

- **Nuevo** `script/shadow_ingest_v8.rb`:
  - **nunca borra**; escribe en `bulk_chunks/<account>/<uid_nuevo>/` bajo un **segundo
    `KbDocument`**. Los 97 chunks actuales siguen indexados y consultables;
  - parametrizado por ENV (hoy `ACCOUNT_ID = 1` es literal en los scripts existentes);
  - gate de confirmación explícito, al estilo `RAG_INGEST_CONFIRM=1`;
  - **ingesta por `manual_batch_v1`**, no `web_v1`: las claves codifican la página
    (`chunk_p<N>_<M>.txt`) y se retira gratis el índice de páginas que
    `SectionNeighborExpander` se construye a mano (:86-131).
- Secuencia: **6 páginas primero** → diff de cuerpos revisado con visión contra el PDF (**Opus**)
  → go/no-go → sólo entonces las 98.
- Puntuar ambos documentos con las mismas rúbricas vía `RAG_SEGURIDADES_DOCUMENT_KEY`.
- Los documentos deprecados se purgan del KB en **un paso propio y medido**, no aquí.

*Definición de terminado:*
- [ ] El script no contiene ninguna llamada de borrado sobre el prefijo de producción
- [ ] Corrida de 6 páginas, diff de cuerpos revisado y adjuntado al informe
- [ ] Delta de conteo de chunks explicado antes de las 98 (el desborde de topología crea chunks
      nuevos; hoy son 97 = 1 por página)
- [ ] Las 42 rúbricas corridas sobre **ambos** documentos, resultados lado a lado
- [ ] `script/rag_seguridades_recall_probe.rb`: **rank por caso antes/después**, no sólo
      pass/fail
- [ ] Rollback probado: borrar el prefijo shadow y su `KbDocument` deja producción intacta

### Fase 8 — Eval ampliado · Sonnet

- Congelar los 42 casos actuales como gate de no-regresión.
- **Nuevo** `script/fixtures/rag_seguridades_topology_v1.json`: los `required` son **cadenas de
  etiqueta verbatim emitidas por el digest de la Fase 2**, no regex ajustadas a mano. Una cadena
  impresa citada del PDF no se puede "tunear". Ojo con los verbatim reales: el PDF imprime
  `STOP FOSO` y `BOTO. REVISION`, no "STOP FONDO" ni "BOTÓN REVISIÓN" (ver Apéndice D).

⚠️ **revisado en el Gate A.** El informe del Gate A **es la verdad-terreno de esta fase y ya está
escrito**, aunque el gate no se superara: trae los 18 divisores extraídos y contrastados, los 98
títulos de página, **272 filas de tabla LED bien formadas en 72 páginas**, la verdad-terreno visual
completa de la página 3 (que **corrige el Apéndice D**, ver I-18) y una tabla de 14 verbatims
impresos con la paráfrasis que **no** matchea. Úsala; no reconstruyas nada de eso. Dos trampas
adicionales medidas allí: `PdfLayoutExtractor` devuelve `CARLOSSILVA` donde la página imprime
`CARLOS SILVA` (I-13), y la extracción de tablas LED mete filas espurias en 40 de las 72 páginas,
así que los `required` de tabla hay que tomarlos de las 32 páginas limpias o filtrarlos por columna.
- Cubrir las **18 marcas** del Apéndice E, no 10 preguntas: eso es lo que hace que el muestreo
  aleatorio deje de sorprender.
- Reutilizar `script/rag_seguridades_recall_probe.rb` tal cual para el rank por caso.
- Cada patrón relajado necesita su control negativo pareado, congelado como test
  (`docs/RAG_SEGURIDADES_BENCHMARK.md:76-79`).

*Definición de terminado:*
- [ ] Batería nueva con cobertura de las 18 secciones
- [ ] Los 42 casos previos intactos, sin editar aserciones
- [ ] Cada `required` nuevo trazable a una cadena verbatim del digest
- [ ] `seguridades_rubric_calibration_test.rb` extendido, suite verde

### Fase 9 — Promoción · Haiku

Gate verde en ambas baterías ⇒ re-apuntar el pin al documento v8. Rollback: re-apuntar.

*Definición de terminado:* pin re-apuntado, gate verde adjunto, `docs/RAG_SEGURIDADES_STATUS.md`
actualizado con la nueva identidad de producción.

### Fase 10 — Foto-consulta: sólo diseño, sin código · Sonnet

Hoy `QueryOrchestratorService` (:109-170) corta en `@images.any?` antes de cualquier
clasificación o retrieval y devuelve un diagnóstico; `BedrockClient#query` (:55-58) hace
literalmente `opts.delete(:images)`. Escribir `docs/rag/foto_consulta_diseno.md`:
`FieldPhotoAnalysisService` → etiquetas visibles y familia de placa → query de retrieval →
`Rag::StructuredEvidenceRoute.build` reutilizado verbatim, detrás de flag, **sin crear nunca un
`KbDocument`**. Nota de sinergia: el motor T2 de la Fase 5 y esta ruta comparten el problema de
reconocimiento visual, así que el prompt de T2 es el punto de reutilización natural. Incluir
coste del turno extra y superficie de abstención nueva. **Sin código.**

---

## Decisiones de diseño fijadas

### Dónde vive una arista: en el **cuerpo** del chunk, más dos escalares en el sidecar

Los `metadataAttributes` son filtrables, **no embebidos**. Una arista ahí no se recupera con
"¿a qué conector va el LIMITADOR?", no puede ser un fragmento citado y es invisible para
`AnswerSafetyProcessor#evidence_text` (:239-247) — quedaría inerte igual que el backfill de
`section_identity`. Tampoco en `aliases`: `CHUNK_ALIAS_LIMIT = 8` y el slot 1 ya es
`section_identity`.

### Forma exacta: se reutiliza la gramática `FIELD_RECORD` existente, no se inventa bloque

```
FIELD_RECORD:
RECORD_ID: FR-<sha16>
SOURCE_SECTION_OR_PAGE: CONTROL LEVEL 1B – HIDRAULICO - PREMONTADA
RECORD_TYPE: TOPOLOGY_EDGE
ACTION: LIMITADOR -> CONECTOR AI
EXPECTED_RESULT: DATA_NOT_AVAILABLE
DERIVATION: leader_line
DERIVATION_EVIDENCE: polilínea (332.2,153.3)->(332.2,248.1)->(252.4,154.7) termina en el corchete rotulado CONECTOR AI (x 305-385, y 242-248)
EVIDENCE: LIMITADOR | CONECTOR AI
END_FIELD_RECORD
```

Cada elección es portante:
- **`ACTION: A -> B`** hace que la línea matchee `CONNECTION_CLAIM_PATTERN` (:36-37) y nombre
  ambos extremos en un mismo fragmento — lo que exige `reject_unsupported_connection_claims`
  (:144-152). Es byte-idéntico a lo que ya renderiza la ruta de foto
  ([field_photo_results_parser.rb:62](app/services/field_photo_results_parser.rb#L62)). Cero
  gramática nueva del lado de respuesta.
- **`RECORD_TYPE`** no se valida contra lista en `FieldRecordParser#build_record` ⇒ sin cambio de
  parser por el tipo.
- **`DERIVATION`** es enum cerrado (`leader_line` | `vision`) por `allowlisted_value` (:465-468):
  un valor suministrado por el LLM degrada a `DATA_NOT_AVAILABLE` en vez de forjar procedencia.
  Es también lo que permite a la respuesta calificar distinto una arista trazada de una leída
  por visión.
- **`EXPECTED_RESULT: DATA_NOT_AVAILABLE`** — label obligatorio; una arista no tiene resultado
  esperado.
- **`EVIDENCE`** no puede ir vacío (`unverifiable_non_stop_field_record?` :231-242 descarta
  registros con `ev` en `DATA_NOT_AVAILABLE`). Ambos extremos son texto real del PDF, así que la
  cita es literalmente cierta.
- **`RECORD_ID`** por el `field_record_id` existente (:447-463) con los campos de derivación
  añadidos ⇒ geometría idéntica re-deriva ID idéntico y el re-ingest es idempotente.

**Presupuesto y consecuencia en número de chunks.** Objetivo ~150-700 palabras, nunca >1000. Una
arista renderizada ≈35 palabras; las ~12 de la página 3 ≈420 sobre ~300 de narrativa. **Tope 12
aristas/chunk con desborde a un chunk hermano.** SEGURIDADES es hoy exactamente 1 chunk por
página (97 chunks = páginas 2-98), así que un chunk de desborde es un chunk *nuevo*: **eso es un
delta de conteo y debe aparecer en el diff del re-ingest**, no descubrirse después.

**Sidecar: exactamente dos claves nuevas.** `topology_edge_count` (entero, filtrable, y le da al
gate un número que comparar sin descargar cuerpos) y `section_path` (lista; `aliases` ya prueba
que Bedrock acepta listas). **`section_identity` se queda con su significado exacto actual,
definido como `section_path.first`**, así que `DocumentOverviewBuilder`,
`SectionNeighborExpander` y `FamilyAmbiguityDetector` no ven ningún cambio. Esa derivación es la
garantía de retrocompatibilidad y es un invariante testeable. El subtítulo de página **no** entra
en `section_path`: sigue siendo el heading `## ` del cuerpo, que `Rag::BoardHeading.label` ya lee.

---

## Riesgos y rollback

| Riesgo | Mecanismo | Mitigación |
|---|---|---|
| **La topología diluye el embedding y BAJA el recall** — la repetición más probable de la historia | 12-15 aristas × 35 palabras sobre 300 de narrativa halvan la densidad léxica del texto que responde; la página rankea *peor* para preguntas de LED/tabla. Es plausiblemente el mecanismo del 62/88 → 57/88, cuando v4→v5 también añadió texto | Tope 12 + desborde. **Medir rank por caso antes/después** en los 42, no sólo pass/fail (Fase 7) |
| **Escalar a Opus dispara el coste** | Un gate de complejidad mal calibrado manda ~todas las páginas a Opus 4.8: coste *y* comportamiento de extracción distinto | Fase 1 exige proyección de coste antes de activar; tope explícito de fracción; escalada por orden de complejidad |
| El digest cambia lo que el modelo escribe del contenido no-topológico | Entrada nueva re-tira la narrativa de cada página, o sea los 42 casos que hoy pasan | Digest sólo en contenido de usuario; instrucción explícita de no reformularlo; diff de 6 páginas antes de las 98 |
| **Una arista errónea es peor que ninguna** | Encadenado mal resuelto en T1, o alucinación en T2 | T1: extremo dentro de bbox de etiqueta impresa, ≤4 segmentos, una etiqueta por extremo, ambiguo ⇒ nada. T2: calibrado contra T1 en Gate B y degradado a campos no-relacionales si no alcanza umbral. Fixture de cadena mala que debe dar cero |
| **T2 se convierte en canal de alucinación** | Visión inventa una relación que no está dibujada | `DERIVATION: vision` es procedencia más débil y **visible en la respuesta**; T1 gana en conflicto; control negativo que exige el calificador |
| `section_path` se filtra a los aliases | Reproduce la fuga de ALTIUS ya documentada | `with_section_identity` sigue prepongiendo exactamente una etiqueta; test de invariante |
| **Sincronizar el backfill de `section_identity` cambia DOS comportamientos a la vez** | `SectionNeighborExpander#authorize` (:150-165) tiene un acantilado en :156 (`return nil if divider_identity.present?`): al sincronizar, el mecanismo interino de página adyacente se **apaga** para todos los divisores; y `DocumentOverviewBuilder` empieza a responder overview de forma determinista | **Paso propio y medido, nunca plegado al re-ingest.** Con el shadow ingest v8 los sidecars nuevos llevan `section_path` nativo, así que el backfill sobre los 97 viejos queda superado y puede no necesitar sync |
| El bump de contrato invalida la deduplicación | `ContentDedupService` tratará todos los assets v7 como MISS | Correcto e inerte: un bump no dispara re-parseo por sí solo. Registrar si se observa lo contrario |

**Irreversible: sólo el re-ingest.** Convertido en A/B por la Fase 7, su rollback cuesta un
`delete` del prefijo **nuevo**.

**Rollback por fase:** 0 → `git revert`. 1-5 → nada cambia en producción (flags apagados, ningún
artefacto escrito). 6 → `git revert` de un archivo; inerte hasta que exista una arista. 7 →
borrar prefijo shadow + `KbDocument` shadow. 9 → re-apuntar el pin.

---

## Decisiones humanas pendientes (antes de la Fase 7)

> **Qué es una "decisión humana" aquí.** Una pregunta que ningún modelo puede cerrar leyendo el
> código ni corriendo una medición, porque depende de dinero, de riesgo aceptable o de calendario
> de piloto. El modelo que llegue a una de éstas **se detiene, expone las opciones con sus
> números y espera respuesta del dueño del producto**; no la resuelve por su cuenta. La respuesta
> se escribe **aquí**, en esta lista, y en la Tabla de estado de fases.

1. **Qué cuenta es dueña del documento.** No existe account 1 localmente y el documento es
   invisible en la UI. Es decisión, no código;
   `script/backfill_seguridades_kb_document_2026-07-26.rb` la ejecuta después.
2. **Si se autoriza el sync del backfill de `section_identity`** como paso medido propio, o se
   deja morir superado por el shadow ingest v8 (opción preferida).
3. **La fracción de páginas que se autoriza escalar a Opus**, con la proyección de coste de la
   Fase 1 en mano.
4. **Si se ejecuta la Fase 7 (shadow ingest) con las aristas de T1 solas o se espera a T2.**
   Añadida tras el Gate A fallido. Bloquea la Fase 7, **no** la Fase 4 (que es inerte con el flag
   apagado). Opciones, números y recomendación —opción B, desacoplar mergear la 4 de ejecutar la
   7— en "Decisión humana #4" dentro de la Ruta de remediación. **Sin respuesta escrita aquí, la
   Fase 7 no se ejecuta.**
   **⏳ Expuesta al dueño del producto el 2026-08-01 por el Gate A-bis, con sus números medidos:
   precisión de T1 100 % (19/19, 0 incorrectas), recall 4,6 %, 19 aristas en 18 de 98 páginas,
   ~15 pares distintos, 7 de 18 secciones sin ninguna arista.** El gate se detuvo aquí.
   - Respuesta: _(pendiente — nadie la ha escrito; que el Gate A-bis se superara **no** es la
     respuesta, y ninguna sesión posterior debe darla por dada)_

## Fuera de alcance

- Reescribir retrieval, `RagRetrievalProfile` o `generation.txt` desde cero: los comentarios de
  `RagRetrievalProfile:13-39` son dos rechazos **medidos** de los tweaks obvios; rehacerlo es
  volver a perder ambos experimentos.
- Tirar las rúbricas actuales.
- Acotar el prompt por audiencia.
- Visión en runtime (sólo en ingesta).
- Retirar `KNOWN_HARDCODED_LOCATIONS` R1/R3/R4 del test de arquitectura: post-piloto, los
  desbloquean precisamente chunks más ricos.
- Arreglar la deriva de configuración detectada de paso (registrada aquí para no perderla, **no
  se toca en este plan**): `bin/update-parsing-prompt.sh:8-9` apunta a KB/DS obsoletos
  (`VBB72VKABV`/`OWRPGSX6XK`) y sería peligroso ejecutarlo; `lib/tasks/kb.rake:457` reporta
  temperatura por defecto `0.3` cuando el real es `0.1`; `BedrockKbChunk:45,65` guarda un
  snapshot que contradice producción; `RAG_FAMILY_AMBIGUITY_GUARD_ENABLED` no está declarado en
  `config/deploy.yml`.

---

# Apéndices — referencia verificada

## Apéndice A — Comandos de inspección usados

```bash
# Texto con geometría de una página (y desde ARRIBA)
pdftotext -bbox-layout -f 3 -l 3 "<pdf>" -

# Texto plano de todo el documento (ya extraído en tmp/pdfs/seguridades.txt)
pdftotext -layout "<pdf>" -

# Suite y linter
bin/rails test                       # base: 1987 runs / 0 failures
bin/rails test test/services/rag     # subconjunto RAG
bin/rubocop
bin/ci                               # gate completo

# Estado real del KB en AWS
bin/rails kb:config                  # embeddings, prefijos, chunking, parsing prompt
bin/rails kb:documents               # documentos indexados + estado
bin/rails kb:status

# Auditoría de chunks / sidecars existentes
RAG_INGESTION_CHUNKS_PREFIX=bulk_chunks/1/<uid>/ bin/rails runner script/evaluate_ingestion_field_records.rb
bin/rails runner script/audit_seguridades_sidecar_manifest_2026-07-29.rb

# Benchmarks
RAG_SEGURIDADES_RUBRIC=script/fixtures/rag_seguridades_rubric.json \
  RAG_SEGURIDADES_OUTPUT=tmp/run.json bin/rails runner script/rag_seguridades_benchmark.rb
bin/rails runner script/rag_seguridades_recall_probe.rb   # rank real por pregunta, top-k 20
```

## Apéndice B — Extracción de geometría verificada (base de la Fase 2)

Este código **se ejecutó** contra la página 3 y produjo los números de este plan. Es el punto de
partida, no pseudocódigo. Nótese que hereda de `HexaPDF::Content::Processor` y que hay que
añadirle la captura de texto (`decode_text_with_positions`) en la misma pasada.

```ruby
require "hexapdf"

doc = HexaPDF::Document.open(pdf_path)
page = doc.pages[2]                       # 0-indexado ⇒ página 3

collector = Class.new(HexaPDF::Content::Processor) do
  attr_reader :ops, :segs
  def initialize(*a)
    super
    @ops = Hash.new(0); @segs = []; @cur = nil
  end
  def move_to(x, y)  = (@ops[:m] += 1; @cur = [x, y])
  def line_to(x, y)  = (@ops[:l] += 1; @segs << [@cur, [x, y]] if @cur; @cur = [x, y])
  def curve_to(*)    = @ops[:c] += 1
  def append_rectangle(x, y, w, h) = @ops[:re] += 1
end.new

page.process_contents(collector)
long = collector.segs.select { |a, b| (a[0] - b[0]).abs + (a[1] - b[1]).abs > 20 }

# Inventario de imágenes con clase de tamaño
xo = page[:Resources] && page[:Resources][:XObject]
xo&.each { |name, obj| next unless obj[:Subtype] == :Image
  puts "#{name}: #{obj[:Width]}x#{obj[:Height]}" }
```

**Resultado medido en la página 3:** `MediaBox [0,0,960,540]`; **73 segmentos largos**;
**19 XObjects imagen** — `Image35` 1920×1080 e `Image48` 1536×864 (fotos de placa) más ~15
pequeñas (`Image52` 127×94, `Image58` 105×183, `Image67` 77×175, `Image120` 63×232,
`Image118` 41×36, …). Ejemplos de cadenas en codo:

```
(332.2,153.3) -> (332.2,248.1)      # vertical, sube al corchete
(333.3,154.7) -> (252.4,154.7)      # horizontal, hacia la etiqueta
(252.4, 23.5) -> (252.4,156.3)
(405.8,153.3) -> (405.8,248.1)      # otra, también al corchete de AI
(719.2,151.6) -> (719.2,246.4)      # al corchete de AG
(750.7,151.6) -> (750.7,246.4)      # al corchete de AG
(305.4,241.9) -> (384.7,244.4)      # el corchete de CONECTOR AI
```

**Conversión de coordenadas:** `y_hexapdf = 540 − y_pdftotext`. `CONECTOR AI` está en
y=298 top-down ⇒ **y≈242 bottom-up**, que es exactamente donde terminan las verticales.

## Apéndice C — Censo del documento (98 páginas)

| Métrica | Valor |
|---|---|
| Páginas totales | 98 |
| Páginas con ≥10 segmentos largos **y** ≥3 imágenes pequeñas | **80** |
| Páginas con 0 segmentos largos (divisores) | 12 |
| Páginas sin ninguna imagen | 0 |

Muestra de las primeras 30 (página · segmentos largos · imágenes · imágenes pequeñas):

```
1:40/10/6   2:0/4/1    3:73/19/16  4:64/21/18  5:67/24/21  6:64/21/18
7:66/27/24  8:4/4/1    9:70/33/30  10:77/35/32 11:82/39/36 12:87/26/23
13:67/32/29 14:93/34/31 15:0/4/1   16:63/26/24 17:65/27/25 18:70/37/34
19:65/27/25 20:70/37/34 21:64/27/25 22:110/33/30 23:0/4/1  24:47/20/17
25:86/33/30 26:88/32/29 27:4/4/1   28:55/25/23 29:68/23/21 30:79/26/24
```

Las páginas con 0-4 segmentos y 1 imagen pequeña (2, 8, 15, 23, 27…) son los **divisores de
sección**: coinciden con el Apéndice E. Sirven de fixture del caso "array vacío".

⚠️ **revisado en el Gate A.** "12 páginas con 0 segmentos (divisores)" es correcto pero se lee
mal: **hay 18 divisores**, los del Apéndice E. Sólo 12 tienen 0 segmentos (2, 15, 23, 35, 41, 49,
51, 54, 60, 66, 87, 92); los otros 6 (8, 27, 37, 47, 70, 80) llevan un adorno vectorial de esquina
de 4-6 segmentos. Ninguno de los 18 tiene líneas guía y en los 18 el derivador devuelve `[]`
correctamente. Cifras exactas del recuento completo (9 078 segmentos, 18 156 extremos) en el
informe del Gate A §3.

## Apéndice D — Verdad-terreno de la página 3 (fixture principal de la Fase 3)

Subtítulo impreso: `CONTROL LEVEL 1B – HIDRAULICO - PREMONTADA`
Sección jerárquica (impresa en el divisor, página 2): `ALJO` / `CONTROL LEVEL 1B` / `ALTIUS`

Tabla LED impresa (y top-down):
```
y=80   LED (x=40)              SERIE (x=169)
y=99   DL2                     SERIE CERROJOS CERRADA
y=118  DL3                     SERIE PUERTAS CERRRADA      ← "CERRRADA" con tres R en el original
y=138  DL4                     SERIE SEGURIDADES CERRADA
```

Conectores: `CONECTOR AI` (x=316, y=298) · `CONECTOR AG` (x=701, y=298).
Corchetes medidos: **AI x 305-385**, **AG x 638-784**, ambos en y≈242-248 bottom-up.

**Las 12 etiquetas de componente, con su x medida y su texto VERBATIM:**

| Texto impreso (verbatim) | x |
|---|---|
| `FINAL CARRERA SUPERIOR` (+ `SOLO HIDRAULICO`) | 64-79 |
| `CERROJOS EXTERIORES` | 188-192 |
| `PUERTAS EXTERIORES` | 291-298 |
| `FINALES` | 395 |
| `STOP FOSO` | 462 |
| `POLEA TENSORA` | 476-482 |
| `LIMITADOR` | 504 |
| `AFLOJACABLES` | 572 |
| `ACUÑAMIENTO` | 574 |
| `BOTO. REVISION` | 650-657 |
| `CERROJOS EMBARQUE 1` | 797-802 |
| `CERROJOS EMBARQUE 2` | 797-802 |

⚠️ **Verbatim vs. paráfrasis.** El PDF imprime `STOP FOSO` y `BOTO. REVISION`. La lectura humana
los citó como "STOP FONDO" y "BOTÓN REVISIÓN". **La Fase 8 debe usar el verbatim**, no la
paráfrasis, o los `required` no matchearán nunca.

**Caso fixture #1 — la ambigüedad de `ACUÑAMIENTO`.** La lectura humana asignó 8 componentes a
AI y 5 a AG, con `ACUÑAMIENTO` en **ambas** listas (13 menciones, 12 etiquetas distintas). La
proximidad en x daría AI=7 / AG=5, con `ACUÑAMIENTO` (x=574) sólo en AG. **La diferencia es
exactamente `ACUÑAMIENTO`.** El derivador debe resolverlo por polilíneas, y las tres salidas
aceptables son: (a) una arista a un único conector, (b) dos aristas si hay dos líneas guía
distintas, (c) **ninguna arista** si es ambiguo. **Lo inaceptable es elegir por proximidad.**
Registrar la resolución en el informe del Gate A.

Lectura humana de referencia (a validar, no a asumir):
- AI → LIMITADOR, FINAL CARRERA SUPERIOR, CERROJOS EXTERIORES, ACUÑAMIENTO, PUERTAS EXTERIORES,
  FINALES, POLEA TENSORA, STOP FOSO
- AG → ACUÑAMIENTO, AFLOJACABLES, BOTO. REVISION, CERROJOS EMBARQUE 1, CERROJOS EMBARQUE 2

⚠️ **revisado en I-18 — la lectura humana de arriba es incorrecta y queda superada.** Validada con
visión sobre la lámina renderizada en el Gate A: `ACUÑAMIENTO` está **sólo en AG**, no en ambos.
El cable verde sale del borne 8 de AG, entra en `ACUÑAMIENTO`, sigue a `AFLOJACABLES`, sigue a
`BOTO. REVISION` y vuelve al borne 7 de AG: una serie de tres dispositivos en un lazo. Verdad-terreno
corregida, **7 en AI y 5 en AG, 12 relaciones para 12 etiquetas, ninguna repetida**:

- **AI** → `FINAL CARRERA SUPERIOR` (vía el bloque auxiliar 10/9 y el enlace punteado) ·
  `CERROJOS EXTERIORES` (gris) · `PUERTAS EXTERIORES` (rojo) · `FINALES` · `STOP FOSO` ·
  `POLEA TENSORA` (los tres en un lazo magenta en serie) · `LIMITADOR` (dos cables, marrón y azul
  marino)
- **AG** → `ACUÑAMIENTO` · `AFLOJACABLES` · `BOTO. REVISION` (lazo verde en serie) ·
  `CERROJOS EMBARQUE 1` · `CERROJOS EMBARQUE 2` (lazo violeta en serie)

Ésta es la verdad-terreno de la página 3 para la Fase 8. Detalle y capturas en
[gate_a_medicion_topologia.md](gate_a_medicion_topologia.md) §8.

## Apéndice E — Las 18 secciones y sus páginas divisoras

Tabla revisada por humano contra el PDF, ya congelada como aserción de aborto dentro de
`script/backfill_seguridades_section_identity_2026-07-29.rb` y documentada en
`docs/RAG_SEGURIDADES_METADATA_BACKFILL_FASE2_DECISION_2026-07-29.md`. **No la reconstruyas.**

| Página divisora | Sección |
|---|---|
| 2 | ALJO |
| 8 | CARLOS SILVA |
| 15 | CTA |
| 23 | EDEL |
| 27 | ELECMEGON |
| 35 | ENIER |
| 37 | EXCELSIOR |
| 41 | FAIN |
| 47 | HATS-ASOCIADOS |
| 49 | INELCA |
| 51 | KONE |
| 54 | MP |
| 60 | ORONA |
| 66 | OTIS |
| 70 | RECOBA |
| 80 | SCHINDLER |
| 87 | SISTEL |
| 92 | THYSSEN |

El inventario de series/LED por marca y modelo está en
`/Users/lahirisan/Documents/Danebo/Danebo RAG elevator  Agosto/estructura_pdf_seguridades.txt`
(18 marcas, p.ej. `EDEL-K3: 37 Puertas Hueco / 39 Puertas Cabina / 41 Cerrojos Cabina y
Exteriores`; `TWISTER TW: SSEG / SPM / SPA`). Es material de apoyo para la Fase 8.

## Apéndice F — Identidad de producción y flags

**Producción** (`docs/RAG_SEGURIDADES_STATUS.md:334-342`):
KB `Y7RZWMFJSR` · DS `PJ0N58DMHG` · bucket `multimodal-source-destination` ·
`account_id: 1` · `document_uid: b61f5d54-ff42-414a-97b7-01682d16f4b5` ·
prefijo `bulk_chunks/1/b61f5d54-…/` = **97 objetos** ·
contrato `field_records_v5`, `ingestion_path: web_v1` · SHA del PDF `1843b13d81ae…`.
**El bucket no tiene versionado.**

**Modelos:** generación/query `global.anthropic.claude-haiku-4-5-20251001-v1:0`
(`bedrock_client.rb:14`) · embeddings `amazon.titan-embed-text-v2:0`, 1024 dim ·
ingesta texto `claude-sonnet-4-6` (`MODEL_TEXT`) · ingesta multimodal `claude-opus-4-8`
(`MODEL_MULTIMODAL`), ambos vía Anthropic Messages/Batch API, no Bedrock.

**Flags existentes** (todos `ENV[...] == "true"` detrás de un módulo de un método):
`RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED` (**el único encendido en producción**),
`RAG_EVIDENCE_SELECTOR_ENABLED`, `RAG_EVIDENCE_EXPANSION_ENABLED`,
`RAG_EVIDENCE_CARDS_ENABLED`, `RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED`,
`RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED`, `RAG_FAMILY_AMBIGUITY_GUARD_ENABLED`,
`SHOW_RAG_SOURCES`, `BEDROCK_RERANKER_ENABLED` (los gates de coste **fallan** si está en
`true`), `QUERY_ROUTING_ENABLED`.

**Flags nuevos de este plan:** `INGESTION_VISUAL_TRIAGE_ENABLED` (Fase 1),
`INGESTION_LAYOUT_DIGEST_ENABLED` (Fase 4), `INGESTION_VISION_TIER_ENABLED` (Fase 5).

**Retrieval de referencia:** `RagRetrievalProfile` da top-k 3 (pinned) / 5 (safety) / 8 (open) /
10 (foto) / 15 (exhaustivo) / 20 (bloque esquemático), techo `max_top_k = 20` impuesto por
`ContractualLimits`; búsqueda `HYBRID`; reranking **apagado**; máximo 2 llamadas al modelo por
turno.

## Apéndice G — Prompts de arranque por fase

Copiar y pegar tal cual al modelo asignado. Cada uno es autosuficiente: asume que el modelo no
tiene ningún contexto previo. Sustituir `<PLAN>` por `docs/rag/plan_conocimiento_visual.md` una
vez hecho el Paso 0.

**Preámbulo común** (va al inicio de todos):

> Lee `<PLAN>` completo antes de escribir una línea de código, incluida la sección "Cómo usar
> este documento", la tabla de invariantes y el "Registro de hallazgos de implementación" al
> final: si una sección está marcada `⚠️ revisado en I-NN`, la entrada `I-NN` gana. Lee también
> `AGENTS.md`, el `AGENTS.md` con scope de cada directorio que toques, y
> `docs/rag/hallazgos_gate_piloto.md`. Trabaja **sólo** tu fase; lo que veas roto en otra se
> registra como hallazgo, no se arregla. Sin dependencias nuevas. `bin/rails test` (base 1987
> runs / 0 failures) y `bin/rubocop` verdes antes de entregar. Al cerrar, aplica el "Protocolo de
> traspaso": entrada `I-NN`, edición en el sitio de las fases que invalides, y tu fila en la
> Tabla de estado de fases.

---

**Fase 0a · Haiku**
> Ejecuta la Fase 0a de `<PLAN>`. `app/controllers/concerns/locale_switchable.rb:17` asigna
> `I18n.locale` global en un `before_action` sin restaurarlo; con hilos de Puma reutilizados se
> filtra fuera de la request y hace la suite dependiente del orden (síntoma: 1 de 9 corridas da
> 7 fallos en `document_overview_responder_test.rb`, que espera `"Documento:"` y recibe
> `"Document:"`). Conviértelo en `around_action` con `I18n.with_locale`. Es el único
> `I18n.locale =` sin scope del repo; el resto ya usa `I18n.with_locale` y te sirve de patrón.
> Verifica con **9 corridas consecutivas** de la suite completa. Cierra H-05 en el libro de
> hallazgos.

**Fase 0b · Sonnet**
> Ejecuta la Fase 0b de `<PLAN>`. `Rag::BoardHeading.mentioned?("EDEL-K3 …", "… EDEL-K2 …")`
> devuelve `true` porque `word_match?` acepta 4 caracteres de prefijo común y las placas hermanas
> con guion comparten seis. Desde el commit `9941f9e` eso decide "responder en vez de preguntar"
> en `app/services/rag/ambiguous_model_responder.rb:113-137`, así que con una sola hermana
> recuperada el técnico puede recibir una respuesta **sobre la placa equivocada** — es un hueco de
> seguridad (H-03). Arréglalo **sin modificar `word_match?`**: añade una capa de rechazo
> `sibling_conflict?` dentro de `mentioned?` que, cuando un token de la etiqueta y uno de la
> pregunta comparten raíz pero difieren en sufijo, exija match exacto de token. Los 36 casos de
> `test/services/rag/board_heading_test.rb` deben seguir verdes **sin editar ninguna aserción**.
> Añade el test de responder: una sola hermana recuperada + pregunta que nombra la otra ⇒ menú,
> no respuesta. Cierra H-03.

**Fase 1 · Sonnet**
> Ejecuta la Fase 1 de `<PLAN>`. Objetivo: que el clasificador Haiku que **ya corre** decida la
> escalada a visión antes de parsear, sin añadir ninguna llamada LLM. Amplía el schema JSON de
> `PageRelevanceFilter::BatchFilter` (`app/services/page_relevance_filter.rb:409-419`) con
> `visual_complexity` (`none|moderate|high`), `has_visual_relations` y `component_count` —
> clasificar, no describir, el coste está en los tokens de salida. Crea
> `app/services/document_class_profile.rb`. Corrige el gate de
> `FileMultimodalRouter#route_page:126-137`: conserva `text_chars < 100 && ratio > 0.7` como
> detector de página escaneada y **añade** un disparador de complejidad visual (polilíneas
> presentes Y ≥N imágenes pequeñas, o `visual_complexity: high`); fija N con el censo del
> Apéndice C, no a ojo. El defecto que arreglas: en el documento de prueba, con miles de chars de
> capa de texto, ese gate **nunca** se cruzó y Opus 4.8 no se activó en 98 páginas. Impón un tope
> de fracción de páginas escalables (`ContractualLimits::MANUAL[:max_opus_page_fraction]`, hoy
> `1.0`) escalando por complejidad descendente. Todo detrás de
> `INGESTION_VISUAL_TRIAGE_ENABLED`. **Entregable bloqueante**: `docs/rag/triaje_visual_medicion.md`
> con la clasificación de las 98 páginas y la proyección de coste al 0/25/50/100 % de escalada.
> Sin ese número el flag no se activa. Test de que con flag apagado el routing es byte-idéntico.

**Fase 2 · Sonnet**
> Ejecuta la Fase 2 de `<PLAN>`. Crea `app/services/pdf_layout_extractor.rb` y
> `app/services/page_layout_digest.rb`, y amplía `PageImageDensityAnalyzer#compute_image_area`
> (:64-88) para devolver también `images:` con `bbox` y `size_class` **sin cambiar las claves que
> ya devuelve** (`PageRelevanceFilter` y `FileMultimodalRouter` las consumen). Parte del código
> del **Apéndice B**, que está verificado contra el documento real: un **único**
> `HexaPDF::Content::Processor` que en **una sola pasada** capture cajas de glifos
> (`decode_text_with_positions`) y `move_to`/`line_to`/`append_rectangle`. Respeta el contrato de
> datos de `PdfLayoutExtractor.extract` tal como está escrito en el plan; la Fase 3 lo consume.
> **La trampa de esta fase es la convención de coordenadas**: todo en el sistema de HexaPDF, y
> desde abajo (`y_hexapdf = alto − y_pdftotext`); escribe un test que falle si alguien la
> invierte. Descarta segmentos con `|Δx|+|Δy| ≤ 20`. `PageLayoutDigest` devuelve `nil` sobre 400
> tokens. Nada de producción debe invocar el extractor todavía: demuéstralo con un grep.

**Fase 3 · Opus**
> Ejecuta la Fase 3 de `<PLAN>`. Crea `app/services/topology_edge_deriver.rb`, que consume el
> contrato de `PdfLayoutExtractor.extract` (Fase 2) y encadena polilíneas por extremos
> compartidos para resolver aristas etiqueta→conector. Es la pieza de mayor riesgo del plan:
> **una arista falsa citada es el peor fallo posible de un sistema de seguridad**, así que las
> guardas son el trabajo, no un detalle — el extremo terminal debe caer dentro del bbox de una
> etiqueta impresa (tolerancia explícita y justificada), cadena de ≤4 segmentos, exactamente una
> etiqueta en cada extremo, y **ambiguo ⇒ no emitir nada**. No implementes
> `method: column_proximity`: sólo `leader_line`. Fixture principal: página 3, contra la
> verdad-terreno del **Apéndice D**, que incluye las 12 etiquetas con su x medida y los corchetes
> de `CONECTOR AI` (x 305-385) y `CONECTOR AG` (x 638-784) en y≈242-248. Resuelve el **caso
> fixture #1, `ACUÑAMIENTO`**: la lectura humana lo puso en ambos conectores, la proximidad en x
> lo pone sólo en AG; las tres salidas aceptables son una arista, dos aristas si hay dos líneas
> guía, o ninguna — lo inaceptable es elegir por proximidad. Añade un fixture de cadena mala
> conocida que debe resolver a **cero**, y una página divisora que devuelva `[]`.

**Gate A · Opus**
> Ejecuta el Gate A de `<PLAN>`. Corre el extractor (Fase 2) y el derivador (Fase 3) sobre las 98
> páginas de `SEGURIDADES 1.1-1.pdf` y escribe `docs/rag/gate_a_medicion_topologia.md` con: aristas
> por página y total; páginas con 0 aristas y por qué (divisor / sin vectores / ambigüedad
> rechazada); **tasa de acierto contra lectura humana** en ≥6 páginas de secciones distintas
> incluida la 3 — **lee las páginas con visión y compara, no asumas**; el `section_path` de 3
> niveles derivado de las 12 divisoras contra el Apéndice E; filas de tabla LED con su agrupación;
> cuántas páginas quedan sin cobertura T1 (dimensiona la Fase 5); y la resolución del caso
> `ACUÑAMIENTO`. **Umbral para continuar: ≥85 % de aristas correctas y 0 incorrectas en la muestra
> revisada.** Si no se alcanza, **para y registra el hallazgo** — no autorices la Fase 4. Este
> informe es además la verdad-terreno de la Fase 8, así que no se desperdicia si se para.

**Fase 2b · Sonnet** — *el siguiente paso real del plan*
> Ejecuta la Fase 2b de `<PLAN>`, que cierra el hallazgo **I-13** y es una de las dos causas por
> las que el Gate A **no se superó**. Lee primero
> `docs/rag/gate_a_medicion_topologia.md` §4.2 completo: tiene los contraejemplos medidos.
> `PdfLayoutExtractor` (Fase 2) rompe el texto rotado 90°: devuelve un `words` **por glifo**, con
> `bbox` invertido (`x0 > x1`) o de altura cero, y el agrupamiento por `y` descendente **invierte
> el orden de lectura**. Eso produjo dos citas falsas en producción de la Fase 3: en la página 61
> el borne impreso `P35B` sale como `"P"`,`"3"`,`"5"`,`"B"` y el derivador emitió
> `CERRADURAS EXTERIORES -> B`; en la página 67 el borne `ES` se emitió como `SE`, escrito al
> revés. **La decisión ya está tomada y no la reabras: se descarta, no se rescata** — marca esas
> entradas con `rotated: true` y deja que la Fase 3b las ignore. Rescatar el orden de lectura es
> más trabajo y más riesgo, y **no compra cobertura**, porque los bornes que importan están
> rasterizados (I-15), no rotados. `rotated:` es una clave **aditiva**: no cambies la forma ni el
> orden de las entradas de `words`, que la Fase 3 y la 5 consumen tal cual. Arregla de paso el
> espacio que se pierde cuando un rótulo **cambia de tipografía a mitad** (el divisor de la
> página 8 imprime `CARLOS SILVA` y el extractor devuelve `CARLOSSILVA`); es el mismo
> `merge_into_words`. Actualiza el bloque de contrato de datos de `<PLAN>` con la clave nueva.
> **No toques `LINE_NOISE_MAX_MANHATTAN_PT`**: I-16 midió que bajarlo **empeora** la cobertura
> (23 → 21 aristas) y mata una arista correcta de la página 3.

**Fase 3b · Opus**
> Ejecuta la Fase 3b de `<PLAN>` (requiere 2b mergeada). Cierra el hallazgo **I-14**, la segunda
> causa del Gate A fallido, y es la pieza de mayor riesgo que queda: **una arista falsa citada es
> el peor fallo posible de un sistema de seguridad**. Lee `docs/rag/gate_a_medicion_topologia.md`
> §4.3 antes de escribir nada. El defecto: el comentario de `TERMINAL_TOLERANCE_PT = 25` dice, con
> razón, que lo que hace segura la holgura no es la distancia sino la **unicidad** — pero la
> unicidad se evalúa **sólo sobre texto**, y en este documento la numeración de bornes suele estar
> **dentro del ráster de la regleta**. Resultado medido: en la página 56 el cable magenta va del
> borne `+24` de `CC1` a `CC2` (un puente conector→conector), los rótulos de `CC1` no existen en
> `words`, y el único texto a ≤25 pt es `PISO SUPERIOR` —que pertenece a **otro** cable—, así que
> se emitió `PISO SUPERIOR -> CC2`, una conexión que no está dibujada; en la página 97 se emitió
> `PUERTAS FRONTALES -> PESTLLOS TECHO CABINA`, dos dispositivos reales que ningún cable une.
> Añade dos guardas: **(a)** si el extremo cae **dentro del `bbox` de una imagen** y la etiqueta
> candidata cae **fuera** de esa imagen, no emitir — `images[].bbox` está en el contrato de la
> Fase 2 desde I-07 y hoy no se usa; **(b)** ignorar como extremo cualquier etiqueta con
> `rotated: true`. Fixture y aserción explícita por cada una de las **cuatro** aristas falsas
> (56, 61, 67, 97) que deben pasar a `[]`. Y aserción explícita de que **no** rompes las dos
> correctas más expuestas a la guarda (a): **pág. 3 `LIMITADOR ↔ CONECTOR AI`** y **pág. 63
> `ALUMBRADO CABINA ↔ J12`**, donde el extremo también cae sobre una foto — la diferencia es que
> ahí la etiqueta rotula **esa misma** imagen. Mídelo, no lo supongas. **No cambies
> `TERMINAL_TOLERANCE_PT` (medido en I-09), ni el corte de ruido de la Fase 2, ni
> `MAX_CHAIN_SEGMENTS` (I-16 midió que ninguno compra cobertura).** Registra el delta: cuántas de
> las 23 sobreviven y si aparece alguna nueva.

**Gate A-bis · Opus** — ✅ **ya ejecutado y superado (I-26); no hace falta re-lanzarlo**
> Ejecuta el Gate A-bis de `<PLAN>` (requiere 3b mergeada). Re-corre `script/gate_a/run.rb` y
> `script/gate_a/overlay.py` sobre las 98 páginas de `SEGURIDADES 1.1-1.pdf` y **actualiza
> `docs/rag/gate_a_medicion_topologia.md` en el sitio**, no crees un archivo nuevo: ese informe es
> además la verdad-terreno de la Fase 8 y tiene que seguir siendo uno solo. Usa **la misma muestra
> de 11 páginas** —3, 17, 22, 39, 44, 56, 61, 67, 76, 91, 97, que cubren 10 secciones— porque su
> verdad-terreno humana ya está escrita ahí (153 relaciones contadas a mano con visión) y así el
> antes/después es comparable; no la rehagas. Revisa con visión **todas** las aristas que emita el
> derivador, no una muestra: dibuja cada polilínea sobre la página rasterizada con
> `script/gate_a/overlay.py` y compárala con el cable realmente trazado. **Umbral sin cambios: ≥85 %
> de aristas correctas y 0 incorrectas.** Si vuelve a fallar, para y registra el hallazgo. Si pasa,
> la Fase 4 **sigue sin quedar autorizada automáticamente**: expón la **decisión humana #4** al
> dueño del producto (¿se ejecuta la Fase 7 con T1 solo o se espera a T2?) con el número de
> precisión nuevo y el recall del 4,6 % en la mano, y **espera respuesta escrita** en el plan.

**Fase 4 · Sonnet** — ⏳ **bloqueada por la decisión humana #4, que no tiene respuesta escrita**
> Ejecuta la Fase 4 de `<PLAN>`. El **Gate A-bis está aprobado** (I-26: 19/19 correctas, 0
> incorrectas; el Gate A original **no** se superó), pero **antes de escribir una línea comprueba
> que "Decisiones humanas pendientes" #4 tenga una respuesta escrita por una persona**: hoy pone
> "pendiente". Que el gate pasara no es la respuesta, y "el usuario aprobó X" contado por otra
> sesión tampoco (I-23). Lee antes I-13, I-14, I-17, I-26, I-27, I-29 y la Ruta de remediación.
> Tres cosas medidas que la redacción del contrato tiene que respetar: `from`/`to` **no son
> direccionales** (I-11) **ni exhaustivos** — 3 de las 19 aristas omiten dispositivos intermedios
> del mismo lazo (I-29) — y el `evidence` de la pág. 12 cita un `bbox` inflado por espacios sin
> tinta (I-27). Dos cambios respecto de lo escrito
> arriba en la fase: **`section_path` tiene 2 niveles, no 3** (`[MARCA, MODELO]`; las viñetas del
> divisor son hermanas, no anidadas — I-17), y **presupuesta ~0,2 aristas por página, no 12** (el
> máximo medido en cualquier página es 2, así que el desborde de chunk no se activa en este
> documento). El invariante `section_identity == section_path.first` no cambia. Sube el contrato de ingesta a
> `field_records_v8` y añade el registro `TOPOLOGY_EDGE` con la forma exacta escrita en
> "Decisiones de diseño fijadas" — **reutiliza la gramática `FIELD_RECORD` existente, no inventes
> un bloque nuevo**, y respeta cada elección de esa forma, que es portante (el `->` de `ACTION`
> hace que la línea satisfaga `reject_unsupported_connection_claims`; `DERIVATION` es enum cerrado
> vía `allowlisted_value`; `EVIDENCE` no puede ir vacío). Archivos: `batch_chunking_prompt.rb`,
> `batch_results_parser_service.rb`, `chunk_merger_service.rb`, `rag/field_record_parser.rb`,
> `single_file_chunking_service.rb`, `manual_batch_ingestion_service.rb`, más el flag
> `INGESTION_LAYOUT_DIGEST_ENABLED`. **Decisión que no puedes cambiar: las aristas no son salida
> del modelo.** Se derivan en Rails y se renderizan en Rails; el digest va en contenido de
> **usuario**, sólo lectura; y `validate_field_record!` debe **rechazar con `ParseError`** un
> `TOPOLOGY_EDGE` con `method: leader_line` emitido por el modelo. Ese airlock es lo que hace
> verdadera la procedencia que la Fase 6 va a autorizar. Invariantes con test:
> `section_identity == section_path.first`; exactamente **una** etiqueta de sección prepuesta a
> los aliases; `RECORD_ID` idempotente; tope de 12 aristas por chunk con desborde a chunk hermano;
> y con flag apagado, cuerpos y sidecars **byte-idénticos** a v7.

**Fase 5 · Opus**
> Ejecuta la Fase 5 de `<PLAN>` (requiere Fases 1 y 4). Construye el tier T2 de visión, que es lo
> que da la capacidad **general** para documentos sin vectores que trazar. Crea
> `app/services/pdf_page_rasterizer.rb` con `Vips::Image.pdfload_buffer` — libvips ya es
> dependencia, pero **verifica primero** que el libvips de `Dockerfile:19` traiga
> `VipsForeignLoadPdfBuffer`; si no lo trae, es un hallazgo y una línea de apt. Usa los bboxes de
> la Fase 2 para recortar cada imagen pequeña y enviarla junto a su etiqueta adyacente: eso es lo
> que resuelve el reconocimiento de componentes pequeños que son parte de un subconjunto. Para el
> prompt de relaciones **reutiliza la forma `from`/`to`/`evidence` que ya existe** en
> `app/prompts/field_photo_prompt.rb:55-61` (`documented_connections`); no inventes schema. Emite
> los mismos registros v8 con `method: vision`. DPI justificado, no mágico. Flag
> `INGESTION_VISION_TIER_ENABLED`. Nunca visión en runtime: sólo en ingesta.

**Gate B · Opus**
> Ejecuta el Gate B de `<PLAN>`. En las 80 páginas donde T1 (geometría determinista) y T2 (visión)
> aplican a la vez, usa las aristas de T1 como **verdad-terreno gratis** para medir T2 y escribe
> `docs/rag/gate_b_calibracion_vision.md` con: precisión y recall de T2 contra T1; **qué ve T2 que
> T1 no puede ver** (relaciones en foto ráster, identidad de componentes pequeños, agrupaciones
> semánticas) — aquí se responde empíricamente la pregunta que originó el Defecto 2, si Opus habría
> captado relaciones que Sonnet aplanó; y coste real por página, medido. Itera el prompt de T2
> hasta alcanzar umbral. Fija la política de conflicto: **T1 gana siempre**, T2 sólo aporta lo que
> T1 no cubre. Si T2 no alcanza precisión suficiente, **limítalo a campos no-relacionales**
> (identidad de componente, calidad de imagen) y deja las relaciones sólo en T1; esa degradación
> es aceptable y se documenta como límite conocido del producto.

**Fase 6a · Opus**
> Ejecuta la Fase 6a de `<PLAN>`. Es un **endurecimiento** de `app/services/rag/answer_safety_processor.rb`
> y va **antes** de la relajación de 6b. Hoy una respuesta puede encadenar `A -> B` a partir de
> `A -> X` y `B -> X` cuando los nombres no llevan dígitos: `IDENTIFIER_PATTERN` (:18-30) matchea
> `X…`, `CN-\d`, `B\d`, `C\d`, `[DLT]\d`, `LED-?\d` pero **nunca `CONECTOR AI`/`AG`**, así que el
> guard ni se dispara. Añade una comprobación agnóstica del corpus: rechaza cualquier línea con
> `->`/`conect…` cuyo par de extremos no sea un par de substrings de alguna línea `ACTION:` de la
> evidencia. **No extiendas `IDENTIFIER_PATTERN`**: es sitio congelado en
> `test/architecture/no_hardcoded_equipment_test.rb`. Los 42 casos de rúbrica deben seguir verdes.

**Fase 6b · Sonnet**
> Ejecuta la Fase 6b de `<PLAN>` (requiere 6a mergeada). Reemplaza
> `app/prompts/bedrock/generation.txt:35-39` por el párrafo que está escrito **verbatim** en la
> Fase 6 del plan; no lo reescribas ni lo resumas. Es la única relajación del contrato de
> seguridad de todo el plan, y funciona porque está anclada a un tipo de registro que sólo la
> ingesta puede escribir. El trabajo real son los controles negativos; están enumerados en la
> Definición de terminado y el que importa es el segundo: `"LIMITADOR -> CONECTOR AI"` debe
> **sobrevivir** cuando la evidencia trae el bloque `TOPOLOGY_EDGE` y **ser rechazado** cuando la
> evidencia sólo trae las dos etiquetas en líneas separadas. Verifica también que
> `$output_format_instructions$` sigue siendo lo último del prompt (romperlo ya colapsó la
> generación tres veces) y que el párrafo nuevo aparece exactamente una vez. Este cambio es
> demostrablemente inerte al desplegarse: no existe ningún `TOPOLOGY_EDGE` en el índice todavía,
> así que el delta esperado es cero.

**Fase 7 · Sonnet (script) + Opus (go/no-go)**
> Ejecuta la Fase 7 de `<PLAN>` (requiere 4, 5 y 6). Escribe `script/shadow_ingest_v8.rb`.
> **No re-ejecutes `script/reingest_seguridades_2026-07-25.rb` bajo ninguna circunstancia**: hace
> `delete_prefix` sobre un bucket sin versionado y su corrida previa bajó la precisión 62/88 →
> 57/88; está documentado como "no repetir". Tu script **nunca borra**: escribe en
> `bulk_chunks/<account>/<uid_nuevo>/` bajo un segundo `KbDocument`, dejando los 97 chunks
> actuales indexados y consultables, con gate de confirmación por ENV y parametrizado (hoy
> `ACCOUNT_ID = 1` es literal en los scripts existentes). Ingesta por `manual_batch_v1`, no
> `web_v1`, para que las claves codifiquen la página. Secuencia: **6 páginas primero**, diff de
> cuerpos revisado con visión contra el PDF por el modelo de go/no-go, y sólo entonces las 98.
> Explica el delta de conteo de chunks **antes** de la corrida completa (hoy son 97 = 1 por
> página; el desborde de topología crea chunks nuevos). Corre las 42 rúbricas sobre **ambos**
> documentos y `script/rag_seguridades_recall_probe.rb` para el **rank por caso antes/después** —
> no sólo pass/fail: el riesgo principal del plan es que la topología diluya el embedding y baje
> el recall. Prueba el rollback.

**Fase 8 · Sonnet**
> Ejecuta la Fase 8 de `<PLAN>`. Congela los 42 casos actuales como gate de no-regresión —son los
> controles negativos de alucinación y la única prueba de que la Fase 6 no filtró, así que no se
> editan aserciones— y añade `script/fixtures/rag_seguridades_topology_v1.json` cubriendo las **18
> marcas** del Apéndice E, no 10 preguntas. Los `required` deben ser **cadenas verbatim emitidas
> por el digest de la Fase 2**, no regex escritas a mano: una cadena impresa citada del PDF no se
> puede tunear. Ojo con los verbatim reales, están en el Apéndice D: el PDF imprime `STOP FOSO` y
> `BOTO. REVISION`, no "STOP FONDO" ni "BOTÓN REVISIÓN", y `SERIE PUERTAS CERRRADA` lleva tres R.
> Cada patrón relajado necesita su control negativo pareado, congelado como test.

**Fase 9 · Haiku**
> Ejecuta la Fase 9 de `<PLAN>`. Con gate verde en ambas baterías, re-apunta el pin al documento
> v8 y actualiza `docs/RAG_SEGURIDADES_STATUS.md` con la nueva identidad de producción. Adjunta el
> gate. Rollback: re-apuntar el pin.

**Fase 10 · Sonnet**
> Ejecuta la Fase 10 de `<PLAN>`. **Sólo documento, sin código.** Escribe
> `docs/rag/foto_consulta_diseno.md`. Hoy `QueryOrchestratorService:109-170` corta en
> `@images.any?` antes de cualquier clasificación o retrieval y devuelve un diagnóstico que nunca
> consulta el KB, y `BedrockClient#query:55-58` hace literalmente `opts.delete(:images)`. Diseña
> el puente: `FieldPhotoAnalysisService` → etiquetas visibles y familia de placa → query de
> retrieval → `Rag::StructuredEvidenceRoute.build` reutilizado verbatim, detrás de flag, **sin
> crear nunca un `KbDocument`**. Incluye el coste del turno extra y la superficie de abstención
> nueva. Señala la sinergia con el prompt del tier T2 de la Fase 5, que resuelve el mismo problema
> de reconocimiento visual.

---

## Registro de hallazgos de implementación

Cada fase añade aquí sus hallazgos antes de entregar, y edita las fases posteriores afectadas
marcándolas `⚠️ revisado en I-NN`. Convención de `docs/rag/hallazgos_gate_piloto.md`.

| ID | Fase | Modelo | Hallazgo | Impacto en fases posteriores |
|---|---|---|---|---|
| I-01 | 0a | Cursor Grok 4.5 | H-05 cerrado: `LocaleSwitchable` pasó de `before_action` + `I18n.locale =` a `around_action :with_request_locale` + `I18n.with_locale`. Es el único `I18n.locale =` sin scope del repo; queda eliminado. Test de no-fuga en `locale_switch_test.rb`. Verificado: `bin/rails test` ×9 → 1988 runs / 0 failures cada una; `bin/rubocop` limpio (453 files). | Ninguno. 0b y fases posteriores no dependen de este archivo. |
| I-02 | 0b | Sonnet | H-03 cerrado sin tocar `word_match?`: `token_match?` gana una capa `sibling_conflict?` — dos designadores que comparten raíz pero cuyo resto (a partir de la raíz común) lleva un dígito en cualquiera de los dos lados sólo cuentan como coincidencia si son idénticos. `BASICO`/`básica` (sin dígito en el resto) sigue matcheando por prefijo; `EDEL-K3`/`EDEL-K2` (dígito en el resto) ya no. Tests nuevos: `board_heading_test.rb` (par positivo/negativo) y `ambiguous_model_responder_test.rb` (una sola hermana recuperada + pregunta nombrando la otra ⇒ menú, 0 llamadas al generador). Los 36 casos de la tabla de verdad y el resto de `board_heading_test.rb` quedan intactos, sin editar ninguna aserción. Verificado: `bin/rails test` 1990 runs / 0 failures; `bin/rubocop` limpio (453 files). | Ninguno. Sólo toca `app/services/rag/board_heading.rb` y sus dos tests; ninguna fase posterior depende de `word_match?`'s comportamiento interno. |
| I-03 | 0b | Sonnet | La redacción de la Fase 0b ("cuando un token de la etiqueta y uno de la pregunta comparten raíz pero difieren en sufijo, exija match exacto") es más amplia que lo implementado y, tomada literalmente, es autocontradictoria con el propio requisito de no editar ninguna aserción de `board_heading_test.rb`: `BASICO`/`básica` también "comparten raíz y difieren en sufijo" (`BASIC-O` vs `BASIC-A`). Probado en vivo: quitar la condición de dígito de `sibling_conflict?` (dejar sólo `common_prefix_length >= MIN_COMMON_PREFIX`) rompe 3 tests — `board_heading_test.rb` ("gender and plural variants…") y dos en `structured_evidence_route_test.rb:747,788` (`arca-basico`), porque `StructuredEvidenceRoute`'s comparative-selection pass reutiliza `BoardHeading.board_tokens`/`mentioned?`. El daño se revirtió y el archivo quedó byte-idéntico al commit `72fc7ee`. La implementación cerrada acota el rechazo a sufijos con dígito, que es lo único que distingue una placa hermana (`EDEL-K3`/`K2`) de una variante de género/plural (`BASICO`/`BASICA`). | Fase 1+: si alguna fase futura toca `sibling_conflict?` para "completar" la regla al pie de la letra del texto original, debe releer esta entrada antes — reintroduce la regresión medida arriba. |
| I-04 | 1 | Sonnet 5 | `ContractualLimits::MANUAL[:max_opus_page_fraction]` (citado en el plan como el knob de presupuesto de esta fase) **no es ese knob**: `test/services/contractual_limits_test.rb:75-78` lo fija en `1.0` como el peor-caso de facturación de Gate 9 (`Gate9CostMatrix#max_manual_cost`), y bajarlo rompería esa garantía sin relación con el triaje visual. Se introdujo `DocumentClassProfile::DEFAULT_MAX_OPUS_PAGE_FRACTION = 0.15` como el presupuesto propio y ajeno de esta feature (tomado del "target histórico <15%" que el propio comentario de `ContractualLimits` documenta), consumido únicamente por `FileMultimodalRouter` detrás del flag. `ContractualLimits::MANUAL[:max_opus_page_fraction]` queda intacto en `1.0`. | Ninguno directo. Si un futuro E3a decide unificar ambos knobs, es una decisión explícita a tomar entonces, no algo que esta fase implique. |
| I-05 | 1 | Sonnet 5 | El segundo disparador del router (`route_page`) necesita saber si una página tiene polilíneas largas y varias imágenes pequeñas — dato que formalmente entrega `PdfLayoutExtractor` (Fase 2), que aún no existía al cerrar esta fase. Esto contradice el mapa de dependencias del plan ("Fase 1: independiente de 2/3"). Se implementó un probe privado, no contractual (`FileMultimodalRouter#geometry_signal` + clase privada `SegmentCollector`, mismo patrón del Apéndice B) directamente en `file_multimodal_router.rb`, sin tocar `page_image_density_analyzer.rb` (evitando así el conflicto de archivo que el plan anticipa con la Fase 2, confirmado en curso: `page_image_density_analyzer.rb` apareció modificado por otra sesión durante esta ejecución). Umbrales fijados del propio censo del Apéndice C, no a ojo: `LONG_SEGMENT_MIN_COUNT = 10`, `SMALL_IMAGE_MIN_COUNT = 3`, `LONG_SEGMENT_MIN_LENGTH_PT = 20` (igual al corte de ruido que Fase 2 documenta para `lines`). El umbral de "imagen pequeña" (`SMALL_IMAGE_MAX_AREA_PX2 = 50_000`) **no** está fijado en ningún lado del plan — es una estimación propia basada en el hueco de tamaño observado en los ejemplos del Apéndice B (componentes ≤~19k px² vs fotos de placa ≥~1.3M px²). | Fase 2: al existir `PdfLayoutExtractor.extract`, decidir si conviene refactorizar `FileMultimodalRouter` para consumirlo en vez de este probe duplicado (deduplicación cosmética, no bloqueante) y, si se hace, fijar `size_class` con criterio autoritativo en vez del umbral estimado aquí. |
| I-06 | 1 | Sonnet 5 | Entregable numérico corrido contra el PDF real completo (no una muestra): con los umbrales de I-05, **98/98 páginas (100 %) califican para Opus antes de aplicar presupuesto** — 19 `scanned_dense` (portada + las 18 divisoras del Apéndice E, sin excepción) + 79 candidatas geométricas (el resto exacto del documento). Cifra consistente con la del Apéndice C (80/98 vía muestreo) y con la página 3 del Apéndice D (73 segmentos largos medidos, idéntico al valor verificado ahí). Con `DocumentClassProfile::DEFAULT_MAX_OPUS_PAGE_FRACTION = 0.15` el resultado real es **33.7 %** de páginas en Opus, no 15 % — el presupuesto se aplica sólo sobre el disparador geométrico y se suma al 19.4 % ya incondicional de `scanned_dense`. Tabla completa, ranking por complejidad y proyección de coste (Sonnet $3/$15, Opus $5/$25 por MTok; ~2,250 tokens de entrada/página por bloque `document`, 8,000 de salida) en `docs/rag/triaje_visual_medicion.md`. **No se invocó Haiku en vivo** con el schema v2 (costo real, no autorizado sin pedirlo) — no cambia el resultado de tier para este documento porque el disparador geométrico por sí solo ya cubre el 100 % de las páginas de contenido (el OR con `visual_complexity: high` no tiene nada que agregar aquí), pero significa que `DocumentClassProfile.classify` nunca corrió con datos reales de Haiku para SEGURIDADES. | Fase 5/Gate B: no asumir que existe una clasificación de documento (`DocumentClassProfile.classify`) medida para SEGURIDADES — no corrió. Decisión humana pendiente #3 del plan: la fracción de producción, con esta tabla en mano. |
| I-07 | 2 | Sonnet 5 | El `bbox` de `images:` no salió de "~6 líneas" dentro del recorrido de `Resources` existente, como estimaba el plan: ese recorrido es puramente sobre el diccionario de recursos (sin content stream) y no tiene forma de saber dónde se pintó cada XObject. Se agregó un segundo pase de content-stream (`PageImageDensityAnalyzer::ImagePlacementCollector`, processor privado que trackea el CTM vigente en cada operador `Do`) que alimenta el mismo bucle de `compute_image_area`; ese método pasa de devolver `[total_area, has_images]` a `[total_area, has_images, images]`. Un XObject declarado en `Resources` pero nunca pintado (`Do`) recibe `bbox: nil` en vez de romper — cubierto por test. `has_images`/`text_layer_chars`/`image_area_ratio` no cambian de valor ni de fuente; `PageRelevanceFilter` y `FileMultimodalRouter` siguen viendo exactamente las mismas claves que antes. | Fase 3/5: al consumir `images[].bbox`, tratar `nil` como "sin posición conocida" — no debería ocurrir en páginas reales bien formadas (todo XObject declarado en un PDF exportado se pinta), pero la guarda existe y el contrato lo permite. |
| I-08 | 2 | Sonnet 5 | `words` agrupa por adyacencia visual — glifos en la misma línea (baseline `y` dentro de una tolerancia) fusionados si el hueco horizontal entre ellos es pequeño relativo a la altura del glifo — y no por operador `Tj`/`TJ` ni por separación en espacios. Verificado en el fixture: `CONECTOR AI` (una sola etiqueta impresa con espacio interno) queda en una única entrada de `words`, mientras que `CONECTOR AI` y `CONECTOR AG` en la misma fila, con hueco grande entre ellas, quedan separadas — exactamente el ejemplo del contrato de datos. La Fase 3, al resolver el extremo de una arista, debe comparar contra `words[].text` tal como sale de este agrupamiento (puede incluir espacios internos; no asumir tokens de una sola palabra). Por separado: la Fase 1 (I-05) implementó su propio probe geométrico privado (`FileMultimodalRouter#geometry_signal` + `SegmentCollector`) porque `PdfLayoutExtractor` no existía todavía, y dejó registrado como hallazgo propio decidir si conviene refactorizarlo para consumir este contrato ahora que existe. Esta fase no toca `file_multimodal_router.rb` — es archivo de la Fase 1, fuera de alcance ("sólo tu fase") — así que esa deduplicación queda pendiente y sin dueño. | Fase 3: usar `words[].text` verbatim (con espacios) al resolver etiquetas, no tokens partidos. Sin dueño: alguien debe decidir si refactorizar `FileMultimodalRouter#geometry_signal` para usar `PdfLayoutExtractor` en vez de su probe duplicado (I-05), y si lo hace, fijar `size_class` ahí con el criterio autoritativo de `PageImageDensityAnalyzer::SMALL_IMAGE_MAX_AREA_PX2` en vez del umbral estimado por separado en I-05. |
| I-09 | 3 | Opus 5 | **La geometría real no es la que el plan supone, y por eso las cuatro guardas escritas no bastaban.** Medido con el extractor de la Fase 2 sobre `SEGURIDADES 1.1-1.pdf`: (a) las líneas guía de la página 3 son en su mayoría **bucles** — el cable sale de un terminal de `CONECTOR AI`, baja, pasa por la foto del componente y **vuelve a otro terminal del mismo conector**; los dos extremos resuelven a la misma etiqueta y no se emite nada, que es lo correcto, porque el componente está en el *medio* de la cadena y ningún extremo lo nombra; (b) el extremo del lado del componente **no cae sobre la etiqueta sino sobre la foto**, y la etiqueta está al lado (18.8 pt en `LIMITADOR` p.3, 22.8 pt en `ALUMBRADO CABINA` p.63); (c) el extremo del lado del conector **queda oculto detrás del gráfico de la regleta** (la Fase 2 ve el punto real, no el visible) y a veces fuera del rótulo impreso (23.7 pt en el borne 1 de `CONECTOR AI`). De ahí `TERMINAL_TOLERANCE_PT = 25.0`, medido, no elegido; lo que hace segura esa holgura no es la distancia sino la unicidad: dos etiquetas en rango ⇒ nada. Guardas añadidas sobre las cuatro del plan, cada una con contraejemplo medido: **unión T** (un extremo que toca el interior de otro segmento no es un final — es lo que elimina las reglas de tabla, cuyos extremos tocan la caja exterior a 0.75 pt en la página 3), **etiqueta que la cadena pasa por encima** (página 32: un cable de `CN7` a `OBSTACULO` termina a 14 pt de `FOTOCELULA` pero corre 5.2 pt **por debajo** de ese texto ⇒ el texto rotula el recorrido, no el final), y **texto que no es un nombre** (fila de números de borne `4  5  6  7…` p.93, fila de conectores fusionada `C1 C 2  C3…` p.95, anotación `(NO)` p.14, que la página imprime tres veces junto a tres aparatos distintos). También hubo que **fusionar palabras apiladas** para obtener el verbatim del Apéndice D (`STOP FOSO`, `BOTO. REVISION`): la Fase 2 entrega una entrada de `words` por línea de texto (I-08), y la fusión se bloquea si hay una **regla dibujada** entre las dos (sin eso, las filas de tabla de la página 17, a 3.2 pt, se fusionan en `PS2V… PS2VH ….`). **Rendimiento medido sobre las 98 páginas: 23 aristas en 22 páginas; 76 páginas devuelven `[]`.** Revisión a mano con visión de las 9 aristas que caen en 8 páginas (3, 11, 12, 14, 52, 63, 93, 95) contra la página renderizada: **0 incorrectas**; páginas 17 y 32 revisadas y su `[]` es correcto (en la 17 la regleta es un ráster, así que sus números no son texto impreso y ningún extremo puede resolver). El caso `ACUÑAMIENTO` del Apéndice D resuelve a **(c) ninguna arista** por evidencia: ningún extremo de cadena cae dentro de la tolerancia; la única línea cercana la pasa a 6.4 pt. | **Gate A:** el número de cobertura ya está (22/98 páginas), pero la tasa contra lectura humana sigue pendiente y va a salir baja en *recall* — el objetivo del gate (≥85 % correctas, 0 incorrectas) es de **precisión** y se cumple en la muestra revisada. **Fase 4:** presupuestar ~1 arista por página, no 12; el desborde de chunk por tope de 12 aristas **no se va a activar en este documento**. **Fase 5 / Gate B:** T1 como verdad-terreno gratis para calibrar T2 sólo existe en 22 páginas, no en 80 — y en la página 3 el propio T1 deja 11 de las 13 relaciones humanas sin derivar. El anclaje foto→etiqueta que describe la matriz de capacidades (`images[].bbox` + etiqueta adyacente) **no está implementado** y es la palanca más grande sobre la cobertura de T1: los bucles y los extremos sobre foto se resolverían con él. Queda fuera de la Fase 3 a propósito (el plan pide resolver *la etiqueta del extremo*, y sólo `leader_line`). |
| I-10 | 3 | Opus 5 | El corte de ruido de la Fase 2 (`LINE_NOISE_MAX_MANHATTAN_PT = 20`, documentado como "ruido de bordes y subrayados finos") **corta cadenas legítimas**: los codos cortos de una polilínea caen por debajo del umbral y desaparecen. Medido en la página 3: el cable magenta que une `FINALES` con `CONECTOR AI` pasa por un codo de 14.2 pt de longitud Manhattan que `build_lines` descarta, y la polilínea llega al derivador partida en dos trozos inconexos (uno de 1 segmento y otro de 5). El de 1 segmento resuelve y produce la arista correcta; el de 5 se rechaza por longitud. Es decir: **una arista de las dos de la página 3 se salvó por casualidad**. No se toca `pdf_layout_extractor.rb` — es archivo de la Fase 2, fuera de alcance. | Gate A: al contar páginas sin cobertura T1, distinguir "sin evidencia" de "cadena partida por el corte de ruido". Si alguien quiere subir la cobertura de T1 sin tocar el diseño, bajar ese umbral (o emitir los segmentos cortos con una marca) es probablemente el cambio más barato — pero es una edición al contrato de la Fase 2 y necesita su propia medición de falsos positivos. |
| I-11 | 3 | Opus 5 | **El derivador no afirma dirección, y el contrato del plan sí la afirmaba.** No hay nada en la geometría que diga cuál extremo es el componente y cuál el conector. Se probaron y descartaron dos reglas: por *hub* (la etiqueta con ≥2 terminales de cadena) da la dirección **al revés** en la página 63, donde tres cables convergen en la lámpara `ALUMBRADO CABINA` y sólo uno resuelve al conector `J12`; por *corchete* (rótulo encerrado en un recuadro dibujado) no es detectable — el pill de `J12` no deja ni rects ni segmentos en el contrato de la Fase 2. La implementación ordena el par **geométricamente** (extremo más abajo en la página primero, desempate por x), sólo para que la salida y el `RECORD_ID` de la Fase 4 sean estables; en las tres aristas verificadas a mano ese orden coincide con componente→conector, pero es una convención de maquetación de este documento, no una inferencia. En consecuencia `evidence` dice `… une X (bbox) con Y (bbox)` en vez de "termina en el corchete rotulado …": no se detectan corchetes y no se debe escribir que se detectaron. | **Fase 4:** `ACTION: A -> B` sigue siendo la gramática correcta (es lo que matchea `CONNECTION_CLAIM_PATTERN` y nombra ambos extremos en un mismo fragmento), pero el párrafo de reglas **no debe presentar la flecha como dirección** ni la respuesta debe parafrasearla como "A alimenta a B". Si la Fase 5 (visión) sí puede decir cuál extremo es el conector, ahí se gana la dirección — no aquí. |
| I-12 | 3 | Opus 5 | El test de la Fase 2 "nada en producción invoca el extractor" (`pdf_layout_extractor_test.rb:85-95`) hace grep sobre el **texto crudo** del archivo, comentarios incluidos, así que cualquier fase posterior que **documente** el contrato en un comentario (`# … PdfLayoutExtractor.extract …`) lo rompe. Ocurrió en vivo al escribir esta fase. Se resolvió redactando el comentario propio para no matchear; **no se tocó el test de la Fase 2** (archivo de otra fase). El test equivalente de esta fase sí ignora las líneas de comentario. | Cualquier fase futura que mencione `PdfLayoutExtractor.extract` o `.new` en un comentario dentro de `app/**/*.rb` verá fallar ese test sin haber invocado nada. Arreglo de una línea (saltar líneas que empiezan por `#`), sin dueño asignado. |
| I-13 | Gate A | Opus 5 | **`PdfLayoutExtractor` rompe el texto rotado 90°, y eso produce citas falsas.** Los rótulos verticales de borne llegan a `words` **glifo a glifo**, con `bbox` invertido (`x0 > x1`) o de altura cero, y el agrupamiento por `y` descendente **invierte el orden de lectura**. Medido en la página 61, regleta `JC3`: el borne impreso `P35B` sale como cuatro entradas `"P"`,`"3"`,`"5"`,`"B"`, todas con `bbox [790.3, …, 781.3, …]`; el derivador se queda con `"B"` y emite `CERRADURAS EXTERIORES -> B`, un nombre que no está impreso en ninguna parte. Página 67, misma raíz y otro síntoma: el borne 2 de `P3` está rotulado **`ES`** y se emite `PUERTAS EXTE. -> SE`, escrito al revés. Bajo la Fase 4 eso se renderiza como `ACTION:` y bajo la 6b la respuesta queda autorizada a reproducirlo verbatim. Hay un tercer síntoma sin relación con la rotación pero de la misma familia (agrupamiento de glifos): el divisor de la página 8 imprime `CARLOS SILVA` con espacio —verificado con visión— y el extractor devuelve `CARLOSSILVA`, porque `SILVA` cambia de tipografía a mitad del rótulo. **No se tocó `pdf_layout_extractor.rb`: es archivo de la Fase 2 y el Gate A no implementa.** | **Bloquea la Fase 4** junto con I-14. **Fase 2:** hay que decidir la política —emitir el texto rotado como una sola entrada con su orden de lectura correcto, o marcarlo y que la Fase 3 lo descarte—; cualquiera de las dos cierra el defecto, la segunda es más barata y más segura. **Fase 8:** el verbatim bueno del divisor 8 es `CARLOS SILVA`, no lo que devuelve el extractor hoy. |
| I-14 | Gate A | Opus 5 | **La guarda de unicidad de `TopologyEdgeDeriver` es ciega ante bornes rasterizados, y ahí produce aristas que no están dibujadas.** El comentario de `TERMINAL_TOLERANCE_PT = 25` dice, correctamente, que lo que hace segura esa holgura no es la distancia sino la unicidad. Pero **la unicidad sólo funciona si las etiquetas rivales están en la capa de texto**, y en este documento la numeración de bornes suele estar dentro de la foto de la regleta. Dos falsos positivos medidos. **Página 56 (MP–MICROBASIC):** el cable magenta va del borne `+24` de `CC1` al conector `CC2` —es un puente conector→conector—; los rótulos `109 111 … 120 +24 A B C D` **no existen en `words`**, así que el único texto a ≤25 pt del extremo es `PISO SUPERIOR`, 22,9 pt más abajo y perteneciente a **otro cable** (el rojo del borne 120 al display "10"); se emite `PISO SUPERIOR -> CC2`, una conexión que no está dibujada. **Página 97 (THYSSEN–CMC 4):** el cable va del borne `C1` de `CN32` a `PUERTAS FRONTALES`; `C1`/`C2` son ráster y el texto más cercano es `PESTLLOS TECHO CABINA`, a 14,1 pt y de otro grupo del dibujo arriba a la derecha; se emite `PUERTAS FRONTALES -> PESTLLOS TECHO CABINA`, dos dispositivos reales que ningún cable une. Reserva aparte, no contada como incorrecta: **página 64**, `LIMITADOR CONTRAPESO -> J22` sale de un conductor que **atraviesa `LIMITADOR CABINA`**; el par comparte conductor y la afirmación es cierta, pero se pierde el dispositivo intermedio, que es justo el dato que importa con la serie abierta. | **Bloquea la Fase 4** junto con I-13. **Fase 3:** la guarda necesita una señal de "aquí hay un competidor que no puedo leer" —p. ej. rechazar cuando el extremo cae dentro del `bbox` de una imagen y la etiqueta candidata está fuera de ella; `images[].bbox` ya existe en el contrato de la Fase 2 desde I-07 y no se está usando. **Fase 6a:** el endurecimiento de `AnswerSafetyProcessor` no salva esto — la línea `ACTION:` estará en la evidencia, así que el guard la dará por soportada. La procedencia `leader_line` es tan fuerte como esta guarda. |
| I-15 | Gate A | Opus 5 | **Los bucles no son el mecanismo dominante del silencio de T1; I-09 se equivocó en el porqué, no en el qué.** I-09 escribió que las líneas guía "son en su mayoría bucles … ambos extremos resuelven a la misma etiqueta y no se emite nada". Medido sobre las 98 páginas, la guarda `same_label_loop` **se dispara exactamente 1 vez** (página 98). Los bucles **no llegan** a esa guarda: mueren antes en `MAX_CHAIN_SEGMENTS` o en la guarda de bifurcación. Embudo completo medido: 18 156 extremos de segmento → **9 706 (53,5 %) en nudos de 3+**, 5 164 en codos, 3 286 libres → 2 652 recorren cadena válida (468 mueren por `>4 segmentos`, 166 por bifurcación) → **1 326 cadenas** → rechazos: **unión T 639 (48,2 %)**, **extremo sin etiqueta impresa a ≤25 pt 563 (42,5 %)**, pasa junto a la etiqueta 46, dos etiquetas en rango 39, no es un nombre 13, **bucle 1** → 25 emitidas → **23 tras deduplicar**. En la página 3, de 28 extremos libres, 12 mueren por `>4 segmentos` y ninguno por bucle. La conclusión práctica de I-09 (los bucles no producen aristas, y eso es correcto) se sostiene. | **Fase 5:** el motivo dominante real —42,5 % de los rechazos, dominante en 32 páginas— es que **la numeración de bornes está dentro del ráster de la regleta**. Contraejemplo canónico: la página 17 (CTA–SR8P) tiene ~15 relaciones con número de borne explícito y T1 emite `[]` porque `32 78 77 76 185 184…` son píxeles. Eso es exactamente lo que T2 sí puede leer, y es la mayor palanca de cobertura del plan. |
| I-16 | Gate A | Opus 5 | **Bajar el corte de ruido de la Fase 2 empeora la cobertura: el remedio propuesto en I-10 está medido y es contraproducente.** I-10 sugirió bajar `LINE_NOISE_MAX_MANHATTAN_PT` como "probablemente el cambio más barato" para subir el recall de T1. Barrido sobre las 98 páginas: con el corte actual de 20 pt, **23 aristas / 22 páginas**; con corte de 2 pt, **21 aristas / 21 páginas**, y en la página 3 **desaparece `FINALES ↔ CONECTOR AI`**. El mecanismo que I-10 describió es correcto —esa arista se salvó porque el corte partió la polilínea y el trozo de 1 segmento resolvió—; al reunir la polilínea entera la cadena vuelve a chocar con la bifurcación y el tope de longitud. Segundo barrido, sobre `MAX_CHAIN_SEGMENTS`: de 4 a 6 gana **una** arista en todo el documento (23→24) y de 6 a 12 no gana ninguna; en la página 3 ni con tope 40 aparece una tercera arista. **Ninguna de las dos constantes es el cuello de botella.** El techo es estructural: el documento dibuja series y bucles, no líneas guía punto a punto, y el otro extremo suele ser un ráster. | **Fase 2 / Fase 3:** no gastar trabajo en calibrar estas dos constantes; está medido que no compran cobertura. La palanca real es el anclaje `images[].bbox` → etiqueta adyacente que I-09 dejó sin dueño, y para el 42,5 % de rechazos del lado del conector, T2. |
| I-17 | Gate A | Opus 5 | **`section_path` tiene 2 niveles, no 3.** El plan describe "el `section_path` de 3 niveles derivado de las 12 divisoras" y ejemplifica con `ALJO` / `CONTROL LEVEL 1B` / `ALTIUS`. Extraída la página 2: `ALJO` en y=517,9 (marca, centrada, cuerpo grande) y dos viñetas `- CONTROL LEVEL 1B` (y=389,4) y `- ALTIUS` (y=324,6). **Son hermanos, no padre e hijo**: son dos modelos de ALJO, y las páginas 3-6 son de `CONTROL LEVEL 1B` mientras la 7 es de `ALTIUS`. El divisor entrega **marca + lista plana de modelos**; el segundo nivel de una página de contenido sale de emparejar su título con una viñeta de su divisor. Forma correcta: `section_path = [MARCA, MODELO]`, con `section_identity == section_path.first` intacto. Extracción verificada en las **18** divisoras (no 12: ver la corrección del Apéndice C) y contrastada 18/18 contra el Apéndice E, más los 98 títulos de página. Dos discrepancias de verbatim, ninguna de la tabla: `CARLOSSILVA` es defecto del extractor (I-13, la página imprime `CARLOS SILVA`) y `HATS_-_ASOCIADOS` lleva los guiones bajos **en el PDF** — el Apéndice E los normalizó. | **Fase 4:** implementar 2 niveles, no 3; el invariante de retrocompatibilidad no cambia. **Fase 8:** las páginas 46 y 76-79 caen en secciones (`FAIN`, `RECOBA`) cuyo título nombra **otra marca** (`RECOBA` monta placa FAIN). Es fiel al PDF; no tratarlo como error de ingesta. |
| I-18 | Gate A | Opus 5 | **`ACUÑAMIENTO` resuelve a (c) ninguna arista por evidencia, y la lectura humana del Apéndice D es incorrecta.** Medido: la etiqueta ocupa `bbox [573.9, 117.5, 633.0, 124.8]` y el extremo de segmento **más cercano está a 28,1 pt** (en `(638.2, 152.9)`), fuera de `TERMINAL_TOLERANCE_PT = 25`. La proximidad en `x` nunca se consulta. Verificado además que la abstención **no depende del tope de cadena**: con `MAX_CHAIN_SEGMENTS` en 4, 8, 16 y 40 la página 3 emite siempre las mismas dos aristas. Verdad-terreno visual leída de la lámina: `ACUÑAMIENTO` está **sólo en AG** — el cable verde sale del borne 8 de AG, entra en `ACUÑAMIENTO`, sigue a `AFLOJACABLES`, sigue a `BOTO. REVISION` y vuelve al borne 7. El Apéndice D lo puso en **ambas** listas (13 menciones para 12 etiquetas) y eso es un error humano, ya corregido en el sitio. Verdad-terreno buena: **7 en AI, 5 en AG, 12 relaciones, 12 etiquetas, ninguna repetida**. Nota honesta: aquí la proximidad en `x` habría acertado por casualidad; eso no la valida — no hay forma de saber cuándo miente, y la abstención sigue siendo la conducta correcta. | **Fase 3:** el caso fixture #1 sigue verde y su aserción es correcta. **Fase 8:** usar la tabla corregida del Apéndice D, no la original. |
| I-19 | 2b | Sonnet 5 | **I-13 cerrado: la causa raíz es geométrica y direction-agnostic, no "x0 > x1 o altura cero" literal.** Derivado del propio `decode_horizontal_text` de HexaPDF (`ctm.premultiply(tm)` por glifo): una rotación de 90° en cualquier sentido intercambia los dos ejes del glifo exactamente — el borde "ancho" (`lower_left→lower_right`) deja de ser horizontal y el borde "alto" (`lower_left→upper_left`) deja de ser vertical. Medido con fixture propio (no se tuvo acceso al PDF real de producción): en un sentido de rotación el bbox agregado sale con `x0 > x1` (el síntoma citado en el plan); en el sentido contrario sale con `y0 > y1` (altura invertida, no exactamente "cero" pero sí inválida) — los dos son la misma causa vista desde ejes distintos. Implementado: `rotated_glyph?` comprueba los dos bordes del glifo contra `GLYPH_AXIS_TOLERANCE_PT = 1.0`, sin depender de qué eje salió invertido; detecta ambos sentidos con la misma prueba. Efecto de segundo orden, más general de lo pedido: `word_entry` pasó de calcular el bbox con sólo dos esquinas (`lower_left` min / `upper_right` max, válido sólo si el glifo es axis-aligned) a las **cuatro** esquinas de cada glifo, así que ninguna entrada —rotada o no— puede salir con bbox inválido; para glifos no rotados el resultado es matemáticamente idéntico al cálculo anterior (verificado: los 9 tests previos de la Fase 2 pasan sin cambiar una sola aserción). Cerrado de paso, mismo método: el hueco perdido en `CARLOS`→`SILVA` (divisor p.8) no era por la rotación, sino porque `word_gap_tolerance` sólo miraba la altura del glifo **anterior**; si el rótulo cambia a una tipografía/tamaño menor a mitad, la tolerancia calculada con el glifo grande "traga" el hueco real entre palabras (no hay glifo de espacio explícito en ese layout). Fix: la tolerancia usa la altura **menor** de los dos glifos adyacentes. Verificado con fixture (`CARLOS`/`SILVA` a tamaño 14/6pt, hueco de 6.5pt: antes fusionaba en `CARLOSSILVA`, ahora emite dos entradas separadas). **No se tocó `LINE_NOISE_MAX_MANHATTAN_PT`** (I-16). Fixture nuevo: `test/fixtures/files/pdf_layout_extractor_rotated_sample.pdf` (no se modificó el fixture de la Fase 2, que sigue intacto). Suite + rubocop verdes: 2061 runs / 0 failures (2056 + 5 tests nuevos); 469 files, 0 offenses. | **Bloquea la Fase 4 junto con I-14** hasta que 3b cierre — I-13 solo, por diseño, no autoriza nada. **Fase 3b (siguiente):** `rotated:` es una clave que sólo aparece (con valor `true`) en la entrada de `words` que la produjo; su ausencia significa "no rotada" — no comprobar `== false`. El `text` de una entrada rotada **no está en orden de lectura** (síntoma original de I-13, decisión de no rescatarlo se mantiene): la guarda de 3b debe descartarla como candidata a extremo de arista por la clave, no intentar leer o normalizar su texto. **Fase 8:** el verbatim bueno de un rótulo con cambio de tipografía interno (`CARLOS SILVA`) ya no requiere reconstrucción manual — sale como dos entradas de `words` adyacentes en la misma línea; quien lo lea debe unirlas con espacio si reconstruye el título, no concatenarlas directo. |
| I-20 | 3b | Opus 5 | **I-14 cerrado, pero la guarda que el plan redactó, tomada al pie de la letra, mata dos aristas correctas: la frontera hubo que medirla.** El plan pedía rechazar cuando "el extremo cae dentro del `bbox` de una imagen y la etiqueta candidata cae fuera de esa imagen". Medido sobre las seis páginas en juego, esa regla literal rechaza **todo**: cada página de este documento lleva **dos imágenes de fondo a página completa** (`[0,0,960,540]`), así que todo extremo cae dentro de una imagen, y en las dos aristas correctas más expuestas la etiqueta cae **fuera** del gráfico que rotula (pág. 63, `J12` a 16,03 pt de la regleta que nombra; pág. 3, `LIMITADOR` sí solapa su foto, pero `FINALES` y `CONECTOR AI` sólo están dentro del fondo). Regla implementada, que subsume la del plan y es la que separa los cuatro casos: **el extremo puede ser nombrado sólo por una etiqueta a la que ninguna otra etiqueta impresa con otro nombre esté más cerca de esa misma imagen.** Una etiqueta dentro de la imagen tiene distancia 0 y nadie la supera (caso pág. 3), y las imágenes de fondo quedan inertes porque todas las etiquetas están a 0 de ellas. Distancias medidas, gap Chebyshev caja-a-caja: pág. 3 `LIMITADOR` **0,00** (rival más cercano `POLEA` a 11,37) ✅ · pág. 63 `J12` **16,03** (rival impreso recto más cercano `CERROJOS` a 45,79) ✅ · pág. 56 `PISO SUPERIOR` **18,23** contra `CC1` —el nombre de la propia regleta— a **13,18** ❌ · pág. 97 `PESTLLOS TECHO CABINA` **6,56** contra dos filas de nombres de conector que **solapan** la regleta, a **0,00** ❌. Dos exclusiones del ranking, ambas con contraejemplo medido: (a) **una etiqueta con el mismo texto no es rival** —la pág. 39 imprime `CERROJOS EXTERIORES` dos veces, arriba y abajo de la misma foto, a 1,14 y 4,22 pt; sin esta exclusión la arista correcta `CERROJOS EXTERIORES ↔ HUE_1` muere a manos de su propio nombre, y se comprobó en vivo que muere—; (b) **las etiquetas rotadas no cuentan** como candidatas a rotular la imagen —son la numeración de bornes de la propia regleta, nunca pueden ser extremo, y en la pág. 63 cuatro de ellas están a 1,2-4,0 pt de la regleta que `J12` legítimamente nombra—. **Delta medido sobre las 98 páginas** (`script/gate_a/run.rb`, mismo guion del Gate A): **22 aristas / 21 páginas → 19 aristas / 18 páginas**; sobreviven **las 19 correctas del Gate A, todas**; **0 aristas nuevas**; embudo: `raster_rival` 4 rechazos, `rotated_label` 1, el resto de las etapas idéntico (1 326 cadenas, `t_junction` 639, `no_label_at_terminal` 562). **No se tocaron** `TERMINAL_TOLERANCE_PT`, `LINE_NOISE_MAX_MANHATTAN_PT` ni `MAX_CHAIN_SEGMENTS` (I-09, I-16). | **Gate A-bis:** el punto de partida son **19 aristas en 18 páginas**, no 23 en 22; hay que revisarlas todas con visión. La muestra de 11 páginas sigue valiendo: en ella T1 emite ahora 7 aristas, las 7 correctas del Gate A, con las 4 falsas en `[]`. **Fase 5:** `images[].bbox` ya tiene su primer consumidor y la relación "imagen ↔ etiqueta que la rotula" está implementada como *ranking de cercanía*, no como anclaje; el anclaje foto→etiqueta que I-09 dejó sin dueño puede reutilizar `outranked_on_an_image?` en vez de reinventarlo. **Fase 4:** la salida no cambia de forma; sigue siendo ~0,2 aristas por página. |
| I-21 | 3b | Opus 5 | **"4 aristas falsas" era la cuenta del Gate A; al empezar 3b ya eran 3, y una había cambiado de nombre.** Medido con el extractor de 2b ya mergeado y el derivador sin tocar: **pág. 67 ya devolvía `[]`** —el `PUERTAS EXTE. -> SE` del Gate A desapareció con el bbox corregido de 2b, y no por una guarda de nombre sino porque, con la caja bien puesta, el cable **pasa por encima** de `SE` y salta la guarda de "la cadena pasa junto a la etiqueta"; es una abstención correcta obtenida por un camino incidental— y **pág. 61 mutó**: de `CERRADURAS EXTERIORES -> B` (Gate A) a `TENSORA -> A 8 2 P`, el borne vertical `P28A` leído al revés. Es decir, 2b arregló el bbox pero **no** el defecto de citar texto rotado: sólo cambió qué basura se citaba. Eso confirma la decisión de I-13/2b de descartar y no rescatar, y confirma que la guarda de rotación de 3b era necesaria y no redundante. Efecto colateral registrado: en la pág. 98 la única cadena que el Gate A rechazaba por `same_label_loop` ahora muere una guarda antes, por `raster_rival` — mismo resultado, motivo distinto, y por eso el contador de bucles del embudo pasa de 1 a 0. | **Gate A-bis:** la tabla de 23 aristas de `gate_a_medicion_topologia.md` §2 y el embudo de §3.1 están **obsoletos** y hay que reescribirlos en el sitio, no compararse contra ellos. El antes/después publicable es 23 (Gate A) → 22 (tras 2b) → **19 (tras 3b)**. |
| I-22 | 3b | Opus 5 | **Tres decisiones de implementación de la guarda de rotación que no estaban en el plan y que hay que conocer antes de tocar este archivo.** (a) **Una palabra rotada no se apila con una recta.** `group_stacked` fusiona palabras verticalmente contiguas para reconstruir rótulos de dos líneas (`STOP` / `FOSO`); sin separar por rotación, un borne vertical pegado bajo un rótulo recto lo contamina con su texto **y con su marca `rotated`**, y la etiqueta correcta se pierde por la guarda nueva. Con la separación, el recuento total de etiquetas del documento sube de 3 229 a 3 233 y ninguna arista cambia. (b) **Una etiqueta rotada no se elimina del conjunto, se rechaza al final.** Igual que las "no-nombre" de I-09: quitarlas antes convertiría un "dos etiquetas en rango ⇒ rechazar" en un acierto limpio. Verificado con test: una etiqueta rotada en rango junto a una buena sigue dando `[]`. (c) **`script/gate_a/run.rb` se actualizó** —el `DiagnosticDeriver` del Gate A duplica a mano la lógica de `sole_label_at` para poder atribuir el motivo de cada rechazo; sin añadirle los dos motivos nuevos, su embudo dejaría de cuadrar con `derive` y el Gate A-bis mediría mal. Es un archivo de otra fase; se tocó **sólo** ese espejo, y es la única edición fuera de la Fase 3b. | **Cualquiera que toque `TopologyEdgeDeriver`:** si cambia el orden de rechazos de `sole_label_at`, tiene que cambiar el mismo orden en `DiagnosticDeriver#label_state`, o el embudo del gate miente. Son dos copias de la misma decisión y no hay test que las ate. |
| I-23 | 3b | Opus 5 | **El Protocolo de traspaso se incumplió dos veces seguidas y casi cuesta el entregable más caro del plan: ni el Gate A ni la Fase 2b commitearon.** Al empezar 3b, el árbol tenía sin commitear el extractor de 2b y su fixture, y **sin trackear** `docs/rag/gate_a_medicion_topologia.md` y `script/gate_a/` — es decir, el informe que contiene las 153 relaciones leídas a mano (la verdad-terreno de la Fase 8, la parte cara e irrepetible del plan) y los guiones que el Gate A-bis tiene que volver a correr vivían sólo en el working tree, a un `git clean` de desaparecer. Por eso las tres celdas de la columna Commit de la tabla de estado estaban vacías pese a decir "cerrada". Resuelto aquí commiteando las tres fases en orden de dependencia y anotando los hashes: **2b `f4ab397`**, **Gate A `f7aa592`**, **3b `1cb789b`**. Commitear sólo 3b no era opción: habría dejado un árbol donde la guarda de rotación no tiene ningún extractor que emita `rotated`. **Sigue pendiente** el housekeeping de `.claude/settings.json` que la Fase 0 dejó abierto (decisión del dueño: no se commitea todavía). | **Toda fase siguiente:** el punto 4 del Protocolo de traspaso ("marca la fase como cerrada y anota el commit") no es burocracia — es lo que hace que el trabajo exista fuera de tu sesión. Comprueba `git status` **antes** de declarar cerrada tu fase, y si encuentras trabajo de una fase anterior sin commitear, regístralo en vez de construir encima en silencio. |
| I-24 | 6a | Opus 5 | **6a no es inerte al desplegarse: el ancla `ACTION:` rechaza también pares correctos que la evidencia documenta en prosa o en fila de tabla.** La instrucción se implementó al pie de la letra (el par de extremos tiene que ser un par de substrings de **una misma línea `ACTION:`**), y eso bloquea el defecto buscado, pero la contrapartida está medida con el procesador ya construido: (a) `"El LIMITADOR se conecta al PARACAIDAS."` con dos `ACTION:` que comparten `CONECTOR AI` ⇒ **rechazado**, que es el objetivo de la fase; (b) `"La FOTOCELULA se conecta a la SERIE PUERTAS."` con evidencia que contiene **esa misma frase verbatim** ⇒ **rechazado**, siendo una respuesta correcta y citada; (c) el par en una fila de tabla (`\| CERROJOS CABINA \| CUADRO DE MANIOBRA \|`) ⇒ **rechazado**. Es una asimetría con la ruta de identificadores, que acepta cualquier `relationship_fragment?` (`ACTION`/`DETAILS`/`EXPECTED_RESULT`, fila con `\|`, o línea con `conect…`) y que quedó intacta a propósito. La relajación de una línea que conserva entera la defensa anti-encadenado es exigir que ambos extremos estén en **una misma línea de relación** en vez de específicamente en una `ACTION:`: el encadenado sigue muerto porque sigue haciendo falta que los dos extremos estén en la **misma** línea, y el control de 6b "las dos etiquetas en líneas separadas" sigue fallando. **No se hizo: no es lo que dice la instrucción de 6a.** Es decisión humana. Medición asociada: ninguna verificación `required`/`optional` de las 5 rúbricas contiene `/conect\|cablead\|->\|→/`, así que **ningún caso puntuado depende de una redacción que este guard pueda degradar**; y el test de calibración carga hoy **52 casos** (12 + 10 + 10 + 10 + 10), no 42 — el 42 del plan es anterior a la rúbrica v4.1. Suite completa 2090 runs / 0 failures, rubocop limpio. | **Fase 6 (preámbulo):** "demostrablemente inerte … delta cero" es cierto de 6b y **falso de 6a** — corregido en el sitio. **Fase 6b:** si se prefiere la variante de "línea de relación", el sitio exacto es `traced_action_lines` (un patrón, un test) y hay que añadir el control positivo de prosa; si se deja como está, la respuesta correcta para un par digit-less no derivado se degrada a `unsupported_connection`, que es fail-closed pero no gratis. **Fase 8:** medir la tasa de `unsupported_connection` antes/después sobre las 98 páginas; es el único sitio del plan donde se puede cuantificar el coste de este endurecimiento. |
| I-25 | 6a | Opus 5 | **Lo que este guard no cubre, para que 6b no lo sobreestime.** (a) **Sólo lee etiquetas en mayúsculas.** Una paráfrasis en minúsculas (`"El limitador se conecta al paracaidas."`) **escapa** — medido. Se probó y descartó hacer el patrón de etiqueta insensible a mayúsculas: cualquier palabra de ≥3 letras pasa a ser candidata a extremo y la prosa normal se degrada en masa. El ancla de mayúsculas es la misma forma léxica que ya usa `COMPONENT_CODE_PATTERN`, y lo que la sostiene es la regla de reproducción **verbatim** del `generation.txt`: **6b no debe debilitarla**, es el único motivo por el que las etiquetas llegan en mayúsculas a la respuesta. (b) **Necesita una etiqueta a cada lado de la relación**; si un lado no tiene ninguna, la línea se deja intacta a propósito (`"No se documenta a qué borne se conecta la fotocelula."` sobrevive, correcto) — no hay cota de distancia, se toma la etiqueta más cercana, porque una cota sería un bypass. (c) **Extra sobre lo pedido:** una afirmación con flecha debe respetar además el orden de la línea `ACTION:`, así que `"CONECTOR AI -> LIMITADOR"` derivado de `ACTION: LIMITADOR -> CONECTOR AI` se rechaza. Eso hace determinista el "never invert one" de 6b en vez de dejarlo sólo en el prompt; **no contradice I-11**: no se afirma que la flecha sea dirección, se exige reproducir el par tal como está escrito. (d) Reafirma I-14: el guard **no salva** una arista falsa que sí está en la evidencia — si la ingesta escribe `ACTION: PUERTAS FRONTALES -> PESTLLOS TECHO CABINA`, la respuesta que la reproduzca queda autorizada. La procedencia `leader_line` sigue siendo tan fuerte como la guarda de la Fase 3b. | **Fase 6b:** el párrafo verbatim se escribe igual, pero el control de inversión ya está cubierto por test en `answer_safety_processor_test.rb` (no hace falta un control negativo nuevo para eso; sí para los otros cuatro). **Fase 8:** un caso de la batería debería cubrir explícitamente la paráfrasis en minúsculas, que es hoy la vía de escape más barata para un encadenado. |
| I-26 | Gate A-bis | Opus 5 | **Gate A-bis SUPERADO: 19 aristas en 18 páginas, 19/19 correctas, 0 incorrectas — verificadas todas con visión, no una muestra.** Re-corridos `script/gate_a/run.rb`, `walk.rb` y `sensitivity.rb` sobre las 98 páginas con 2b (`f4ab397`) y 3b (`1cb789b`) mergeadas: salida idéntica a la que I-20 predijo (19/18), embudo con `raster_rival` 4, `rotated_label` 1, `same_label_loop` 0, y la mitad de arriba del embudo **byte-idéntica** al Gate A (18 156 extremos, 3 286 libres, 1 326 cadenas) — 2b/3b no tocan la formación de cadenas, sólo el nombrado del extremo. En la muestra congelada de 11 páginas T1 emite 7, **7/7 correctas**, y 56/61/67/97 devuelven `[]`; **recall sin moverse: 7/153 = 4,6 %**. Precisión 63,6 % → **100 %**; el precio es cobertura: 22 → 18 páginas y 5 → **7 secciones de 18 sin ninguna arista** (se suman MP y OTIS, cuyas únicas aristas eran las falsas). Sensibilidad re-medida: mismas dos conclusiones de I-16 con las cifras desplazadas (tope de cadena 4→12 compra +1 arista; bajar el corte de ruido a 2 pt **empeora** 19→17). Suite y linter verdes con el código medido: 2090 runs / 0 failures, 469 files / 0 offenses. `docs/rag/gate_a_medicion_topologia.md` reescrito **en el sitio** (§1, §2, §3.1-3.4, §4.1-4.5, §7, §10); §5, §8 y §9 —la verdad-terreno cara— intactos salvo notas. `led.rb` también se re-corrió: 72/26 páginas y variantes de cabecera idénticas, total de filas 426 → **425** (una fila, por el reagrupamiento de 2b); el corte bien-formada/ruido de §6 (272/154) fue un juicio manual del Gate A y **no se rehizo**. | **Fase 8:** la verdad-terreno de §5, §8 y §9 sigue válida palabra por palabra; de §6 sirve el reparto de páginas, pero **el corte 272/154 hay que rehacerlo con criterio propio** si se generan `required` desde ahí. **Fase 4:** desbloqueada por el gate **pero no autorizada** — falta la decisión humana #4, que este gate expone y **no** resuelve. Los dos números para responderla: precisión **100 %**, recall **4,6 %**, 19 aristas en 18/98 páginas, ~15 pares distintos. **Gate B:** el conjunto de calibración T1 sigue siendo ~15 pares; el gate superado no lo agranda. **Fase 5:** T2 es el único motor posible en **61** páginas de contenido (antes 57). |
| I-27 | Gate A-bis | Opus 5 | **El `bbox` de una etiqueta incluye sus espacios finales, que no tienen tinta — y 1 de las 19 aristas se emite sólo por eso.** `merge_into_words` mete los glifos de espacio en la palabra y `word_entry` los abarca en el `bbox`, así que la etiqueta reclama área donde no hay nada impreso. Medido: **615 de 4 306 entradas de `words` (14,3 %) en 80 de 98 páginas** llevan espacios finales, con tramos fantasma de hasta **889 pt** (`MICONIC BX -6200`, divisor p80). Caso que toca la salida: **pág. 12**, `BM2` tiene tinta hasta x=126,9 pero `bbox` hasta x=281,5, y el extremo de la cadena está en x=186,2 — a **59,3 pt** de la tinta, muy fuera de `TERMINAL_TOLERANCE_PT = 25`; sin el tramo fantasma la arista `PUERTAS MANUALES ↔ BM2` **no se emitiría**. La pág. 11 (`B6`, tinta hasta x=55,4, extremo a 24,4 pt) sobrevive sin el fantasma. Las dos aristas son **correctas contra el dibujo** —verificado con visión— así que el veredicto del gate no cambia; lo que cambia es por qué: aquí el tramo fantasma se extiende sobre la propia regleta que la etiqueta rotula, y nada garantiza que la próxima vez apunte al sitio correcto. Es el mismo mecanismo que hizo fallar el Gate A (creer que hay un nombre impreso donde sólo hay papel), en su tercera variante tras I-13 (rotado) e I-14 (ráster). **No se arregló aquí:** es una decisión de la Fase 2 y tocarlo mueve el agrupamiento de las 98 páginas. | **Cualquiera que toque `PdfLayoutExtractor`:** recortar el `bbox` a la tinta (ignorar glifos de espacio al calcular las esquinas, sin cambiar el `text`) es un arreglo de una línea conceptual pero **cambia el conteo de aristas** y exige re-correr el Gate A — no es cosmético. **Fase 3/3b:** el `bbox` inflado alimenta también `outranked_on_an_image?` y la guarda de unicidad, que comparan distancias caja-a-caja. **Fase 4:** el `evidence` de la arista de la pág. 12 cita un `bbox` que no corresponde a la tinta; si el digest publica coordenadas, publica ésas. |
| I-28 | Gate A-bis | Opus 5 | **`CARLOS SILVA` sigue saliendo `CARLOSSILVA`: el arreglo de I-19/2b se validó con un fixture que no reproduce el caso real.** I-19 cambió `word_gap_tolerance` a la altura **menor** de los dos glifos adyacentes y lo verificó con `CARLOS`/`SILVA` a **14 pt y 6 pt**. Medido sobre el PDF real (divisor p8): las dos tipografías tienen **prácticamente la misma altura** (53,60 y 52,76 pt), el hueco real entre `CARLOS` y `SILVA` es **16,08 pt** y la tolerancia aplicada **31,66 pt** — tomar la menor no cambia nada. La causa es `WORD_GAP_RATIO = 0.6`, que a cuerpo 53 pt da 32 pt cuando un espacio impreso a ese tamaño mide ~14-16 pt: **el problema nunca fue el cambio de tamaño, es el ratio**. No afecta a ninguna arista (ningún divisor emite) y **no se arregló aquí**: bajar el ratio mueve el agrupamiento de palabras de las 98 páginas y necesita su propia medición. §5.2 y §9 del informe del Gate A **siguen vigentes tal cual**. | **Fase 8:** el verbatim bueno del divisor p8 sigue siendo `CARLOS SILVA` y **sigue habiendo que corregirlo a mano** — I-19 decía que ya salía como dos entradas de `words`; sobre el PDF real, no. **Fase 2 (si alguien la reabre):** el defecto de I-13 marcado "cerrado de paso" no lo está; es un hallazgo abierto con causa medida. **Toda fase:** un fixture sintético que no reproduce las magnitudes del documento real no cierra un hallazgo medido sobre el documento real. |
| I-29 | Gate A-bis | Opus 5 | **La "serie con intermedio omitido" son 3 de las 19 aristas (16 %), no una: §4.4 del Gate A se quedó corta, y sólo se ve mirando arista por arista.** Además de la pág. 64 (`LIMITADOR CONTRAPESO ↔ J22` atraviesa `LIMITADOR CABINA`, ya registrada), la revisión visual encontró **pág. 14** (`STOP BOTO. CABINA ↔ XP11`: el conductor magenta atraviesa **`BOTONERA REVISION` y `BARANDILLA`**, dos dispositivos) y **pág. 22** (`OBSTACULO ↔ CN-112`: el cable azul atraviesa `FOTOCELULA`). En los tres la guarda "la cadena pasa junto a la etiqueta" no salta porque el conductor entra y sale del **dibujo** del dispositivo, no de su rótulo, que cae a un lado fuera de la holgura de una altura de línea. No son aristas falsas —el conductor es el mismo— pero un técnico que reciba "LIMITADOR CONTRAPESO va a J22" no sabrá que hay otro dispositivo en el mismo lazo, que es justo el dato que importa cuando la serie está abierta. Detectado sólo porque el Gate A-bis dibujó **una arista por imagen** con `zoom.py`; con `overlay.py` (todas las aristas de la página a la vez, en magenta, sobre láminas que trazan cables magenta) no es distinguible. | **Fase 4:** redactar estas aristas sin sugerir que el lazo tiene sólo dos elementos; el contrato ya dice que `from`/`to` **no** son direccionales (I-11), y esto añade que tampoco son **exhaustivos**. Es el 16 % de la salida de T1, no un caso aislado. **Fase 6b:** el párrafo que autoriza citar topología verbatim debería no autorizar a afirmar que la serie es sólo ese par. **Fase 5/Gate B:** ésta es una capacidad donde T2 gana claramente a T1 — leer los tres dispositivos de un lazo es reconocimiento visual, no encadenado de polilíneas. |
