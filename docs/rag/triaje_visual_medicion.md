# Fase 1 — Medición de triaje visual (SEGURIDADES 1.1-1.pdf, 98 páginas)

> Entregable bloqueante de la Fase 1 (`docs/rag/plan_conocimiento_visual.md`). Sin este
> número el flag `INGESTION_VISUAL_TRIAGE_ENABLED` no se activa en producción.

## Metodología

Dos señales alimentan el segundo disparador del router (`FileMultimodalRouter#route_page`,
detrás del flag). Se midieron sobre el PDF real, **no sobre una muestra**:

1. **Señal geométrica (real, medida, costo cero).** Se corrió el extractor privado
   `FileMultimodalRouter#geometry_signal` (mismo código de Apéndice B: un único
   `HexaPDF::Content::Processor` capturando `move_to`/`line_to`, filtrando segmentos con
   `|Δx|+|Δy| ≤ 20`, más recuento de imágenes pequeñas vía XObjects) contra las 98 páginas
   reales de `SEGURIDADES 1.1-1.pdf` (el binario vive fuera del repo, en
   `~/Documents/Danebo/Danebo Elevator Rag Julio 2026/entrevosdtas /SEGURIDADES 1.1-1.pdf`;
   `pdfinfo` confirma 98 páginas, 960×540pt, export de PowerPoint — coincide exactamente con
   lo que documenta el plan). Página 3 midió 73 segmentos largos, **idéntico** al número
   verificado en el Apéndice B del plan — confirma que la medición reproduce la verdad-terreno
   ya establecida.
2. **Señal Haiku (`visual_complexity`/`has_visual_relations`/`component_count`).** **No se
   invocó en vivo.** Ejecutar el batch classifier extendido contra las 98 páginas reales
   implica llamadas pagas a la API de Anthropic; dado que el flag está apagado por defecto y
   esta fase es "medir antes de gastar", se optó por no autorizar ese gasto sin pedirlo
   explícitamente. Ver "Limitación conocida" más abajo — no cambia el resultado de la
   clasificación tier por tier para este documento (se explica por qué).

Todo el código que produjo estos números ya vive en el repo (`FileMultimodalRouter`,
`DocumentClassProfile`, `IngestionVisualTriageFlag`) y está cubierto por tests offline; esta
medición no agrega ningún artefacto de producción nuevo.

## Censo geométrico de las 98 páginas (real, medido)

| Métrica | Valor |
|---|---|
| Páginas totales | 98 |
| `scanned_dense` (gate existente, sin cambios: `text_chars < 100 && image_ratio > 0.7`) | **19** |
| Candidatas al segundo disparador (`long_segments ≥ 10 && small_images ≥ 3`, y no `scanned_dense`) | **79** |
| Ninguno de los dos disparadores | **0** |
| Páginas con 0 segmentos largos (divisores) | 12 |

**Las 19 páginas `scanned_dense`:** 1, 2, 8, 15, 23, 27, 35, 37, 41, 47, 49, 51, 54, 60, 66,
70, 80, 87, 92 — es decir, la portada (p1) más las **18 páginas divisoras de sección** del
Apéndice E, sin excepción. Tiene sentido: un divisor es casi todo logo/imagen con poco texto,
así que ya cruza el gate de "página escaneada" que existe hoy. Esto es consistente con que
`ROUTE_PAGE` no cambia su comportamiento para ninguna de ellas.

**Hallazgo central: con el gate calibrado según el Apéndice C (≥10 segmentos Y ≥3 imágenes
pequeñas), el 100 % del documento (98/98) califica para Opus antes de aplicar cualquier
presupuesto.** Las 79 páginas de contenido restantes (todo lo que no es portada ni divisor)
pasan el segundo disparador sin excepción — no hay ningún punto intermedio en este documento.
Esto confirma exactamente la preocupación que el propio plan anticipa ("Escalar a Opus dispara
el coste"; "El triaje ordena las páginas por complejidad... escala a Opus sólo hasta una
fracción configurable") y es la razón de que el tope de fracción no sea opcional.

### Ranking de complejidad (candidatas geométricas, score = `long_segments + small_images`)

Las 79 páginas candidatas, ordenadas de mayor a menor complejidad (esto es lo que
`DocumentClassProfile.select_escalation_pages` usa para decidir qué escala primero):

```
1. p95 (863)   2. p96 (747)   3. p64 (383)   4. p62 (373)   5. p63 (319)
6. p61 (313)   7. p57 (272)   8. p55 (261)   9. p56 (260)  10. p94 (257)
11. p59 (229) 12. p58 (203)  13. p93 (170)  14. p98 (168)  15. p65 (154)
16. p33 (151) 17. p22 (131)  18. p34 (128)  19. p14 (123)  20. p97 (123)
21. p50 (116) 22. p26 (116)  23. p11 (114)  24. p25 (111)  25. p69 (107)
26. p12 (106) 27. p10 (105)  28. p75 (104)  29. p84 (103)  30. p32 (103)
31. p38 (102) 32. p77 (102)  33. p86 (102)  34. p36  (99)  35. p72  (98)
36. p30  (98) 37.  p9  (96)  38. p71  (95)  39. p52  (95)  40. p13  (94)
41. p20  (93) 42. p18  (93)  43. p73  (92)  44. p31  (90)  45.  p7  (88)
46. p82  (87) 47. p74  (86)  48. p68  (86)  49. p78  (86)  50.  p3  (86)
51. p29  (85) 52. p89  (85)  53. p90  (85)  54. p85  (84)  55. p76  (83)
56. p91  (83) 57.  p5  (82)  58. p19  (81)  59. p17  (81)  60. p21  (80)
61. p44  (79) 62.  p4  (78)  63.  p6  (78)  64. p16  (78)  65. p67  (76)
66. p81  (76) 67. p43  (75)  68. p42  (75)  69. p39  (75)  70. p28  (71)
71. p45  (65) 72. p48  (64)  73. p83  (62)  74. p88  (62)  75. p53  (60)
76. p24  (59) 77. p79  (37)  78. p46  (37)  79. p40  (21)
```

(Score mínimo 21, máximo 863, mediana 94 — dos páginas, 95 y 96, son atípicas: >700 puntos
frente a una mediana de 94. Vale la pena revisarlas a mano en el Gate A de la Fase 3: podrían
ser una tabla densa o un artefacto de conversión de PowerPoint, no necesariamente una lámina
más "compleja" en sentido visual.)

Página 3 (fixture del Apéndice D) puntúa 86 — 73 segmentos + 13 imágenes pequeñas — y queda en
el puesto 50 de 79, complejidad media-baja dentro de este documento.

## Clasificación por tier bajo el tope de fracción

`DocumentClassProfile.select_escalation_pages` calcula `budget = floor(total_pages ×
fracción)` y escala las candidatas geométricas de mayor a menor score hasta agotar ese
presupuesto. Las 19 páginas `scanned_dense` **no** están sujetas al tope — ese gate ya existe
hoy sin presupuesto y esta fase no lo toca.

| Fracción | Presupuesto (`floor(98×f)`) | Geométricas escaladas | Total Opus (+19 scanned) | Total Sonnet | % del documento en Opus |
|---:|---:|---:|---:|---:|---:|
| 0 % | 0 | 0 | 19 | 79 | 19.4 % |
| 15 % (`DocumentClassProfile::DEFAULT_MAX_OPUS_PAGE_FRACTION`) | 14 | 14 | 33 | 65 | 33.7 % |
| 25 % | 24 | 24 | 43 | 55 | 43.9 % |
| 50 % | 49 | 49 | 68 | 30 | 69.4 % |
| 100 % | 98 (tope real: 79 candidatas) | 79 | 98 | 0 | 100 % |

**Nota importante para quien autorice la fracción de producción:** el nombre "15 %" en
`DEFAULT_MAX_OPUS_PAGE_FRACTION` es engañoso para este documento — como el 15 % se aplica
*encima* del 19.4 % ya escalado incondicionalmente por `scanned_dense`, el resultado real es
33.7 %, no 15 %. Esa es la aritmética que hay que tener en mente al fijar el valor de
producción (Decisión humana pendiente #3 del plan).

## Proyección de coste (ingesta, no consulta)

Coste de **parsear las 98 páginas una vez** (ingesta), no de responder preguntas después.
Cada página se envía una sola vez a un modelo — Sonnet o Opus según el tier — así que el coste
adicional de escalar es únicamente la diferencia de precio por página entre ambos modelos.

**Insumos, todos verificados, ninguno inventado:**
- Precio Sonnet 4.6 (`MODEL_TEXT`): **$3.00 / $15.00** por MTok (input/output) — Anthropic,
  tabla de precios vigente.
- Precio Opus 4.8 (`MODEL_MULTIMODAL`): **$5.00 / $25.00** por MTok (input/output) — ídem.
- Tokens de entrada por página de un bloque `document` (PDF): **1,500–3,000 tokens/página**,
  según la documentación oficial de Anthropic sobre soporte de PDF (combina el costo de
  extracción de texto y el costo de la página convertida a imagen). Se usa el punto medio,
  **2,250 tokens**, para el número de la tabla; el rango completo se muestra como banda de
  incertidumbre.
- Tokens de salida por página: **8,000** — primer peldaño de
  `ContractualLimits::MANUAL[:output_token_ladder]` (`BatchPageRetryService`), el mismo que ya
  usa la ingesta hoy. No se asume reintento.

Coste por página: Sonnet ≈ `2250×$3 + 8000×$15` (por millón) ≈ **$0.12675**; Opus ≈
`2250×$5 + 8000×$25` (por millón) ≈ **$0.21125**. Delta por página escalada: **+$0.0845**.
Con el rango 1,500–3,000 tokens de entrada el delta por página varía muy poco (±3.5 %) porque
el costo está dominado por los 8,000 tokens de salida, iguales en ambos modelos.

| Fracción | Total Opus | Coste total del documento (98 páginas) | Δ vs. 0 % |
|---:|---:|---:|---:|
| 0 % (hoy, sin flag) | 19 | **$14.03** | — |
| 15 % (default del código) | 33 | **$15.21** | +$1.18 |
| 25 % | 43 | **$16.06** | +$2.03 |
| 50 % | 68 | **$18.17** | +$4.14 |
| 100 % | 98 | **$20.70** | +$6.67 |

(Baseline: 98 páginas × $0.12675 = $12.42 si todo fuera Sonnet; cada página que escala a Opus
suma +$0.0845 sobre ese baseline. Los números de la tabla ya incluyen las 19 páginas
`scanned_dense`, que hoy **ya** van a Opus con el flag apagado — por eso el costo a 0 % no es
el baseline sino $12.42 + 19×$0.0845 = $14.03.)

**Coste del propio triaje (Haiku, la llamada que ya corre).** Extender el schema añade
`PageRelevanceFilter::PER_PAGE_OUTPUT_TOKENS_V2 = 56` frente a los 32 tokens/página actuales
— +24 tokens de salida por página. Sobre 98 páginas eso es +2,352 tokens de salida en total,
a precio Haiku ($5/MTok salida): **+$0.012 por documento**. Confirma la afirmación del plan de
que ampliar el schema "cuesta ~0 tokens extra" — es un 0.06 % del coste de ingesta.

## Limitación conocida — señal Haiku no medida en vivo

`visual_complexity`, `has_visual_relations` y `component_count` no se ejecutaron contra el
documento real: hacerlo exige llamadas pagas a Haiku con el schema v2, y esta fase eligió no
autorizar ese gasto sin pedirlo explícitamente (el flag está apagado por defecto precisamente
para no forzar esa decisión). Esto **no invalida la tabla de arriba** por una razón concreta:
el disparador geométrico y el de Haiku están unidos por **OR** — el geométrico, ya medido, deja
**0 páginas de contenido sin cubrir** (79/79 candidatas geométricas más 19 `scanned_dense` =
98/98). No queda ninguna página en la que la señal de Haiku pudiera *agregar* una escalada que
el geométrico no haya cubierto ya. La señal de Haiku sí importa para documentos donde HexaPDF
no encuentra vectores trazables (fotos escaneadas sin geometría, el caso T2 de la Fase 5) —
pero ese no es el caso de SEGURIDADES.

Por la misma razón, `DocumentClassProfile.classify` no se invocó con datos reales de Haiku para
este informe — hacerlo con datos inventados sería fabricar evidencia. Dado que 79/98 páginas
(81 %) muestran geometría de esquema trazado con corchetes y líneas guía (exactamente el patrón
que `DocumentClassProfile::RELATIONAL_PAGE_FRACTION_FLOOR` busca), es razonable *esperar* que
la clasificación real converja a `:visual_technical`, pero esa es una expectativa, no una
medición, y se registra como tal.

## Recomendación para la decisión humana pendiente (plan, ítem #3)

No es esta fase quien fija la fracción de producción — eso es una decisión humana explícita
pendiente. Con los números de arriba en mano: **25 %** sube el coste de ingesta de este
documento un 14 % sobre el 0 % actual (+$2.03) y escala, además de las 19 `scanned_dense`, las
24 páginas de mayor complejidad geométrica (top del ranking, hasta el score 111 — p25), dejando
las 55 páginas restantes de la lista de candidatas (scores 21–107) en Sonnet. **100 %** es el
escenario ya rechazado implícitamente por el Defecto 2 del plan (coste sin medir, comportamiento
de extracción sin medir) y debería esperar al Gate B, no activarse junto con esta fase.

## Reproducir esta medición

```
bin/rails runner - <<'RUBY'
binary = File.binread("<ruta al PDF real de SEGURIDADES>")
splitter = PdfPageSplitterService.new(binary)
router = FileMultimodalRouter.allocate
splitter.each_page do |page_num, page_binary|
  density  = PageImageDensityAnalyzer.analyze(page_binary)
  geometry = router.send(:geometry_signal, page_binary)
  puts [page_num, density[:text_layer_chars], density[:image_area_ratio], geometry].inspect
end
RUBY
```
