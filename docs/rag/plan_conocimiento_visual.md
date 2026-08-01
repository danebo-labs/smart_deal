# Plan: capacidad de generar conocimiento desde documentos técnicos visuales complejos

> **Estado:** plan aceptado, sin implementar. Lo ejecutan varios modelos, una fase cada uno.
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
| Capa de texto **+** vectores (80/98 aquí) | **T1 geométrico** | Rails determinista, 0 LLM | ~0 | `TOPOLOGY_EDGE` `method: leader_line` |
| Imagen densa sin vectores / sin capa de texto | **T2 visión** | Opus 4.8 + prompt de relaciones sobre ráster + crops | alto, acotado | `TOPOLOGY_EDGE` `method: vision` |
| Ambas señales | **T1 + T2** | T1 ancla, T2 reconoce; T1 gana en conflicto | medio | ambos, con procedencia distinguible |

**Complementariedad, no competencia.** T1 sabe *que* la etiqueta `LIMITADOR` está unida al
`CONECTOR AI` por una línea trazada, pero no sabe qué es la foto pequeña de 105×183 que está al
lado. T2 sí puede reconocerla. T1 aporta el **anclaje** (bbox de cada imagen pequeña y su
etiqueta adyacente); T2 aporta el **reconocimiento**. Eso es el caso "identificar visualmente
componentes pequeños que son parte de un subconjunto".

**T1 es verdad-terreno gratis para calibrar T2.** En las 80 páginas donde ambos aplican, las
aristas deterministas de T1 permiten medir y calibrar el prompt de visión de T2 sin trabajo
humano. Eso es lo que hace confiable a T2 en los documentos donde T1 no puede correr — y es la
clave de la generalidad. Es el Gate B.

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
| 0a | pendiente | — | | |
| 0b | pendiente | — | | |
| 1 | pendiente | `INGESTION_VISUAL_TRIAGE_ENABLED` | | |
| 2 | pendiente | — (offline) | | |
| 3 | pendiente | — (offline) | | |
| Gate A | pendiente | — | | |
| 4 | pendiente | `INGESTION_LAYOUT_DIGEST_ENABLED` | | |
| 5 | pendiente | `INGESTION_VISION_TIER_ENABLED` | | |
| Gate B | pendiente | — | | |
| 6a | pendiente | — | | |
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
    { text: "LIMITADOR",   bbox: [504.0, 155.0, 560.0, 168.0] }
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

### `TopologyEdgeDeriver.derive(layout)` → Fase 3 produce, Fase 4 consume

```ruby
[
  { from: "LIMITADOR", to: "CONECTOR AI", method: :leader_line,
    evidence: "polilínea (332.2,153.3)->(332.2,248.1)->(252.4,154.7) termina en el corchete rotulado CONECTOR AI (x 305-385, y 242-248)",
    chain: [[332.2,153.3],[332.2,248.1],[252.4,154.7]] }
]
```

Reglas: si una etiqueta no resuelve, **no aparece en el array**. Sin entradas parciales, sin
`nil`, sin `confidence` numérica. El array vacío es una salida válida y frecuente (12 páginas
divisoras).

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
- [ ] `locale_switchable.rb` usa `around_action` + `I18n.with_locale`; ninguna asignación global
- [ ] `bin/rails test` **9 veces seguidas**, 0 failures (el síntoma era 1 de 9 con 7 fallos en
      `document_overview_responder_test.rb` esperando `"Documento:"` y recibiendo `"Document:"`)
- [ ] `bin/rubocop` limpio
- [ ] H-05 marcado cerrado en `docs/rag/hallazgos_gate_piloto.md`

**0b · H-03 (hueco de seguridad).** `BoardHeading.mentioned?("EDEL-K3 …", "… EDEL-K2 …")` es
`true`: `word_match?` acepta 4 chars de prefijo común y las hermanas con guion comparten seis.
Desde la Fase 2 anterior eso decide "responder en vez de preguntar"
([ambiguous_model_responder.rb:113-137](app/services/rag/ambiguous_model_responder.rb#L113-L137))
⇒ con una sola hermana recuperada el técnico recibe respuesta **sobre la placa equivocada**.

**Fix sin tocar `word_match?`**: capa de rechazo `sibling_conflict?` dentro de `mentioned?` — si
un token de la etiqueta y uno de la pregunta comparten raíz pero difieren en sufijo, exigir
match exacto de token. `word_match?` no se modifica para que la tabla de 36 casos siga verde.

*Definición de terminado:*
- [ ] `mentioned?("EDEL-K3 …", "… EDEL-K2 …") == false`, con test
- [ ] `mentioned?("EDEL-K3 …", "… EDEL-K3 …") == true`, con test
- [ ] Los 36 casos de `test/services/rag/board_heading_test.rb` intactos, sin editar aserciones
- [ ] `test/services/rag/ambiguous_model_responder_test.rb`: con una sola hermana recuperada y
      la pregunta nombrando la otra, se devuelve **menú**, no respuesta
- [ ] Suite completa + rubocop verdes; H-03 cerrado en el libro de hallazgos

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
- [ ] Tests offline con respuestas Haiku dobladas: schema ampliado parseado, campos ausentes
      degradan a `visual_complexity: :none` sin excepción
- [ ] Test de que con el flag apagado el routing es **byte-idéntico** al actual
- [ ] Test de que el tope de fracción se respeta y escala por orden de complejidad descendente
- [ ] **Entregable numérico**: clasificación de las 98 páginas por tier + **proyección de coste**
      de cada fracción de escalada (0 %, 25 %, 50 %, 100 %), en
      `docs/rag/triaje_visual_medicion.md`. **Sin ese número el flag no se activa.**
- [ ] Suite + rubocop verdes

### Fase 2 — Extractor de geometría (offline, impacto cero) · Sonnet

- **Nuevo** `app/services/pdf_layout_extractor.rb` — **un único**
  `HexaPDF::Content::Processor` que en **una sola pasada** captura cajas de glifos
  (`decode_text_with_positions`) y `move_to`/`line_to`/`append_rectangle`. Un procesador, no dos.
  Código base verificado en el **Apéndice B**.
- **Nuevo** `app/services/page_layout_digest.rb` — serializador acotado en tokens.
- **Modificar** `page_image_density_analyzer.rb`: extender `compute_image_area` (:64-88) para
  devolver también `images: [{name:, width:, height:, bbox:, size_class:}]`. Ya recorre los
  XObjects: ~6 líneas, no una clase nueva. El `bbox` es lo que después permite a T2 recortar cada
  componente y a T1 anclarlo a su etiqueta. **No cambiar la forma de retorno existente** —
  añadir la clave; `PageRelevanceFilter` y `FileMultimodalRouter` la consumen hoy.

**Convención de coordenadas fijada: todo en el sistema de HexaPDF (y desde abajo).** `pdftotext`
es top-down; mezclarlos es el bug obvio de esta fase. Conversión: `y_hexapdf = alto − y_pdftotext`
(en la página 3, `CONECTOR AI` está en y=298 top-down = **y≈242 bottom-up**). Test explícito.

*Definición de terminado:*
- [ ] `PdfLayoutExtractor.extract` devuelve exactamente el contrato de datos de arriba
- [ ] Test sobre un PDF fixture de 3 páginas comprometido en `test/fixtures/files/`
- [ ] Test explícito de convención: una etiqueta conocida tiene `y` bottom-up, y el test falla si
      alguien la invierte
- [ ] Test de que `PageLayoutDigest.render` devuelve `nil` sobre el tope de 400 tokens
- [ ] Test de que `PageImageDensityAnalyzer` mantiene sus claves previas
- [ ] Nada del código de producción invoca aún el extractor (grep que lo demuestre)
- [ ] Suite + rubocop verdes

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

*Definición de terminado:*
- [ ] Fixture página 3: las aristas resueltas se comparan contra el **Apéndice D**
- [ ] **Caso fixture #1 — `ACUÑAMIENTO`:** o resuelve a un único conector, o resuelve a dos
      líneas guía distintas, o **no se emite**. Las tres son salidas aceptables; lo inaceptable
      es elegir por proximidad. Ver Apéndice D
- [ ] Fixture de **cadena mala conocida** que debe resolver a **cero** aristas
- [ ] Fixtures de las páginas 17 / 32 / 63 (secciones distintas), aristas revisadas a mano
- [ ] Test de que una página divisora (sin segmentos) devuelve `[]` sin excepción
- [ ] Suite + rubocop verdes; nada en producción invoca el derivador

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

**Umbral para continuar: ≥85 % de aristas correctas y 0 incorrectas en la muestra revisada.**
Si no se alcanza, **parar y registrar el hallazgo**; no seguir a la Fase 4. Este entregable es
además la verdad-terreno de la Fase 8, así que no se desperdicia si se para aquí.

### Fase 4 — Contrato v8: destino común de T1 y T2 · Sonnet

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

En las 80 páginas donde ambos tiers aplican, comparar aristas T1 (deterministas) contra T2
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

**6a — Endurecimiento primero** (`rag/answer_safety_processor.rb`): rechazar cualquier línea con
`->`/`conect…` cuyo par de extremos no sea un par de substrings de alguna línea `ACTION:` de la
evidencia. Bloquea el encadenado obvio (`A→X` + `B→X` ⇒ `A→B`), que hoy **pasa** para nombres
tipo `CONECTOR`. **No se extiende `IDENTIFIER_PATTERN`**: es sitio congelado en
`test/architecture/no_hardcoded_equipment_test.rb`, y una comprobación agnóstica del corpus es
lo correcto. Es un **endurecimiento**, así que puede y debe ir antes que 6b.

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
- [ ] `answer_safety_processor_test.rb`: `"LIMITADOR -> CONECTOR AI"` **sobrevive** cuando la
      evidencia contiene el bloque `TOPOLOGY_EDGE`
- [ ] Mismo archivo: **se rechaza** cuando la evidencia sólo tiene las dos etiquetas en líneas
      separadas. *Éste es el control real*
- [ ] Mismo archivo: encadenar `A -> B` desde `A -> X` + `B -> X` se rechaza
- [ ] Mismo archivo: una arista `DERIVATION: vision` llega a la respuesta **con** su calificador
      de verificación en campo; sin él, se rechaza
- [ ] `seguridades_rubric_calibration_test.rb`: los **42 casos pasan sin cambios**, y el
      renderizado de topología matchea **cero** patrones `penalized` de las 6 rúbricas
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

1. **Qué cuenta es dueña del documento.** No existe account 1 localmente y el documento es
   invisible en la UI. Es decisión, no código;
   `script/backfill_seguridades_kb_document_2026-07-26.rb` la ejecuta después.
2. **Si se autoriza el sync del backfill de `section_identity`** como paso medido propio, o se
   deja morir superado por el shadow ingest v8 (opción preferida).
3. **La fracción de páginas que se autoriza escalar a Opus**, con la proyección de coste de la
   Fase 1 en mano.

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

**Fase 4 · Sonnet**
> Ejecuta la Fase 4 de `<PLAN>` (requiere Gate A aprobado). Sube el contrato de ingesta a
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
| — | — | — | *(vacío: sin implementación aún)* | — |
