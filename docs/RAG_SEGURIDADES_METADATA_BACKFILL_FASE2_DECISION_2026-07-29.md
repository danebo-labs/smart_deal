# Fase 2 — Decisión de backfill de metadata y revisión del diff

**Fecha:** 2026-07-29.
**Alcance ejecutado:** fila «Decisión de backfill de metadata + revisión del diff — Opus + humano»
de la tabla de asignación de modelos (`~/.claude/plans/valida-este-plan-y-memoized-biscuit.md`,
A10 §12), que implementa los puntos **3, 4 y 5** de Fase 2 de
[RAG_PRECISION_V2_PLAN_2026-07-29.md](RAG_PRECISION_V2_PLAN_2026-07-29.md).
**Precedentes consumidos:**
[RAG_SEGURIDADES_SIDECAR_AUDIT_MANIFEST_2026-07-29.md](RAG_SEGURIDADES_SIDECAR_AUDIT_MANIFEST_2026-07-29.md)
(Fase 2 punto 1, manifiesto de 97 filas),
[RAG_EVIDENCE_SELECTOR_FASE1_DESIGN_2026-07-29.md](RAG_EVIDENCE_SELECTOR_FASE1_DESIGN_2026-07-29.md)
(F1/F2 y corrección #7: el backfill es de `section_identity`),
[RAG_PRODUCTION_TRACE_2026-07-29.md](RAG_PRODUCTION_TRACE_2026-07-29.md).
**Artefactos:** `script/backfill_seguridades_section_identity_2026-07-29.rb` ·
`tmp/rag_seguridades_section_identity_backfill_diff_2026-07-29.json`.

---

## 1. La decisión, en una línea

Se escribe **una sola clave nueva** —`section_identity`— en los 97 sidecars de
`SEGURIDADES 1.1-1`, con el valor de la marca/familia que declara la página divisoria
precedente, arrastrado en orden de página. No se toca ninguna clave existente, ningún
cuerpo `chunk_N.txt`, ninguna otra clave del contrato, ni el Knowledge Base.

### Qué se descartó explícitamente

| Descartado | Razón |
|---|---|
| Crear `manufacturer` / `controller_model` / `board_model` | Ningún escritor del código las produce (`BatchResultsParserService#sidecar_metadata` es el único escritor de `metadataAttributes`). Inventarlas en un backfill crearía un contrato que la ingesta de documentos futuros no mantendría — F1 del diseño de Fase 1. |
| Corregir `canonical_name` («ALJO Control Level 1B Altius» en las 97 páginas) | Es el nombre **del documento**, no de la sección, y es la clave con la que el documento está fijado, resuelto y citado hoy (`KbDocumentResolver`, `citation_processor.rb:82`, `doc_refs`). Cambiarla rompe la atribución en producción para arreglar un problema que `section_identity` ya resuelve. |
| Reescribir los `aliases` del sidecar | Son aliases de **documento**, no de chunk; los de chunk viven en la línea `[SEARCH_ALIASES: …]` del cuerpo, que no se toca. Prependerle la sección (lo que `ChunkMergerService#with_section_identity` hace en ingesta) es precisamente el mecanismo que hoy mete `ALTIUS` en los alias de páginas de otros fabricantes — el defecto que la etapa 2 del selector prohíbe usar como evidencia. Un backfill no debe reproducirlo. |
| Re-chunkear o reingerir el PDF | §7.6 del plan lo prohíbe sin evidencia de pérdida en el cuerpo. La auditoría demuestra lo contrario: la identidad correcta **ya está** en el cuerpo y en los alias. |

---

## 2. Por qué `section_identity` y no otra cosa

`section_identity` no es un campo nuevo inventado para este documento: es el seam que el
contrato `field_records_v7` ya define y que toda la cadena de ingesta ya honra.

| Eslabón | Comportamiento existente |
|---|---|
| `app/prompts/batch_chunking_prompt.rb:94,203` | emite `section_identity` **solo** cuando la página abre visiblemente una sección de marca |
| `ChunkMergerService:77-98,144-149` | la arrastra hacia adelante en orden de página hasta la siguiente divisoria; descarta valores > 60 caracteres (prosa) |
| `BatchResultsParserService:373,495-513` | la escribe en el sidecar; la omite cuando no se declaró |
| `Rag::DocumentOverviewBuilder:83-100` | la agrupa como secciones del índice del documento |

**Respuesta a la pregunta sobre documentos futuros: sí, ya se generan con esta
estructura.** `BatchChunkingPrompt::INGESTION_CONTRACT_VERSION = "field_records_v7"` y
`contract_metadata` la aplica a **todos** los caminos de ingesta excepto el de fotos de
campo. SEGURIDADES es la excepción porque se ingestó bajo `field_records_v5` (el sidecar
lo declara: `"ingestion_path":"web_v1","ingestion_contract_version":"field_records_v5"`).
Este backfill existe únicamente para poner un documento v5 al día — no es un mecanismo
permanente.

> **Pendiente de alcance, no resuelto aquí:** si hay otros documentos indexados bajo v5/v6
> tienen el mismo defecto. Se comprueba con una lectura de `ingestion_contract_version`
> sobre los sidecars de cada documento; queda como tarea separada porque el plan acota
> Fase 2 a SEGURIDADES.

---

## 3. Verdad-terreno: 18 secciones

La estructura del mazo es **alfabética por marca**, lo que da una verificación
independiente: cualquier divisoria omitida rompería el orden entre dos vecinas. No se
rompe.

| Sección | Divisoria | Páginas | Chunks | Modelos que enumera la divisoria |
|---|---:|---:|---:|---|
| ALJO | 2 | 2–7 | 6 | CONTROL LEVEL 1B, ALTIUS |
| CARLOS SILVA | 8 | 8–14 | 7 | HIDRA TPR50/TPR60/TPR70, SIRIUS, KDT EVO |
| CTA | 15 | 15–22 | 8 | M8PC, SR8P, PREMONTADA, CR8PH, MR08 |
| EDEL | 23 | 23–26 | 4 | K2, K3 |
| ELECMEGON | 27 | 27–34 | 8 | EM 3000, EM 2000, EM 4000, EM 1000 |
| ENIER | 35 | 35–36 | 2 | MXL1 |
| EXCELSIOR | 37 | 37–40 | 4 | TOKIBAT 2007 |
| FAIN | 41 | 41–46 | 6 | EKM66 |
| HATS - ASOCIADOS | 47 | 47–48 | 2 | ZEUS |
| INELCA | 49 | 49–50 | 2 | HOMELIFT |
| KONE | 51 | 51–53 | 3 | MONOESPACE, EPB |
| MP | 54 | 54–59 | 6 | 5000, MICROBASIC, VIA SERIE |
| ORONA | 60 | 60–65 | 6 | ARCA, ARCA BASICO, ARCA II, ARCA III |
| OTIS | 66 | 66–69 | 4 | LB II, LCB II, GEN II |
| RECOBA | 70 | 70–79 | 10 | KSA 18, EKM 64, EKM 66 |
| SCHINDLER | 80 | 80–86 | 7 | MICONIC LX, SMART 001 (CRIPS), MICONIC BX-6200, BIONIC 5 |
| SISTEL | 87 | 87–91 | 5 | TW1 INAPELSA, TW1 ELÉCTRICO/HIDRÁULICO EMBARBA, DELTA + |
| THYSSEN | 92 | 92–98 | 7 | SERIE E, SERIE B, SERIE F, SERIE CMC 3/4/4+ |

Suma: 97 chunks = páginas 2–98, una por página, sin huecos. (La página 1 no está
indexada: el filtro de relevancia la descartó como portada.)

### Cómo se derivan, sin conocimiento de marcas

El script no contiene ninguna lista de fabricantes. Detecta la divisoria **por forma** y
toma la etiqueta del propio texto:

1. **Divisoria** = página cuyo cuerpo no declara encabezado `## ` **ni** línea
   `**Section:**`. Es una diapositiva de portada que solo rotula la marca y enumera sus
   modelos. Esta regla produce exactamente 18 páginas sobre 97 — ni una más, ni una menos.
2. **Etiqueta** = primer `[SEARCH_ALIASES: …]` de esa página, que es el título que la
   propia diapositiva imprime. Coincide con la marca en 18/18 casos, incluida la
   normalización que la ingesta ya hizo (`HATS_-_ASOCIADOS` en el PDF →
   `HATS - ASOCIADOS` en los alias).
3. **Arrastre** hacia adelante en orden de página, idéntico a `ChunkMergerService`.

La tabla de 18 pares `(página, etiqueta)` está además **fijada en el script** como
aserción revisada contra el PDF: si la derivación por forma no la reproduce exactamente,
el script aborta en vez de escribir. Derivación mecánica + verdad-terreno humana, sin que
una sustituya a la otra.

### Verificación contra los diez casos de la cohorte v2

| Página | Caso del gate | Sección asignada |
|---:|---|---|
| 7 | ALTIUS D8/D11 | ALJO |
| 9 | TPR50 SPM | CARLOS SILVA |
| 17–18 | CTA SR8P SPH | CTA |
| 26 | EDEL-K3 37/39/41 | EDEL |
| 29 / 31 / 33 | EM3000 / EM2000 / EM4000 V1 | ELECMEGON |
| 35 → 36 | divisoria MXL1 → contenido MXL1 | ENIER (**misma sección**) |
| 39–40 | TOKIBAT DL27 | EXCELSIOR |
| 93 | Thyssen Serie E L9/L8/L7 | THYSSEN |
| 22 / 81 / 82 | MR08 / MICONIC LX / SMART 001 | CTA / SCHINDLER / SCHINDLER |

Las tres últimas son las opciones que producción ofreció para SPM. Hoy las tres comparten
`canonical_name` con la página correcta y son indistinguibles por metadata; después del
backfill pertenecen a CTA y SCHINDLER, y la página correcta a CARLOS SILVA.

---

## 4. Revisión del diff

Dry-run ejecutado. Diff completo en
`tmp/rag_seguridades_section_identity_backfill_diff_2026-07-29.json`.

```
sidecars totales      97
sidecars modificados  97
claves añadidas       section_identity
claves modificadas    (ninguna)
claves eliminadas     (ninguna)
cuerpos .txt escritos 0
```

Forma exacta del cambio, por sidecar — la clave se añade al final, en la misma posición
en la que `sidecar_metadata` la escribiría en una ingesta v7:

```diff
-…,"aliases":[…],"page_number":36}}
+…,"aliases":[…],"page_number":36,"section_identity":"ENIER"}}
```

### Controles de integridad ya ejecutados

1. **La copia local es PROD.** Los 194 objetos de
   `tmp/pdfs/seguridades_audit/production_chunks/` se compararon contra
   `s3://multimodal-source-destination/bulk_chunks/1/b61f5d54-…/`: **97/97 sidecars y
   97/97 cuerpos con MD5 idéntico al ETag remoto**. El diff calculado localmente es
   literalmente el diff de producción.
2. **Round-trip JSON idéntico.** Para cada sidecar se verificó
   `JSON.generate(JSON.parse(original)) == original`, así que la reescritura no puede
   introducir cambios de formato o de orden de claves encubiertos.
3. **El nuevo contenido es el viejo más la clave.** Se verifica por comparación de cadenas
   (`original.sub(/\}\}\z/,"") + ",\"section_identity\":…}}"`), no por confianza en el
   serializador.
4. **Ningún sidecar traía ya `section_identity`** (0/97), así que no hay valor previo que
   se pueda sobrescribir en silencio.
5. **Cota del contrato.** Ninguna etiqueta supera los 60 caracteres de
   `ChunkMergerService::SECTION_IDENTITY_MAX_CHARS`: el backfill no puede introducir un
   valor que la ingesta v7 rechazaría.

### Reversibilidad

- Respaldo de los 97 originales a `s3://…/sidecar_backups/1/<document_id>/<timestamp>/`
  **fuera de `bulk_chunks/`** (regla de AGENTS.md: ese prefijo es lo único que ingesta el
  data source; un respaldo dentro sería un documento fantasma en el KB), más copia local
  en `tmp/` y manifiesto `HASHES.json` con SHA256 antes/después.
- Verificación post-escritura: se relee cada objeto y se compara su SHA256 contra el
  esperado; una discrepancia aborta señalando el prefijo de respaldo.
- Interlock previo a escribir: se vuelve a comparar el ETag de cada objeto contra el MD5
  local. Si PROD cambió desde la auditoría, **no se escribe nada**.

---

## 5. Efectos: qué cambia y qué no

### No cambia hasta que se sincronice el KB

La metadata que Bedrock devuelve en `Retrieve` es la capturada por el índice vectorial en
la ingesta, no la que está en S3 en el momento de la consulta. Mientras no corra un
ingestion job, el backfill es **inerte** para recuperación, generación, guardrails y
telemetría. Esto es deliberado: `Rag::EvidenceCandidateSelector` (Fase 1) todavía no
existe, así que no hay consumidor de `section_identity` en el camino de la consulta.

**Recomendación: no sincronizar el KB en este paso.** El plan ya lo pone tras una
autorización explícita (§7.4) y la sincronización debe hacerse cuando exista el selector
que la aproveche, con las tres cohortes corridas antes y después.

### Sí cambia sin sincronizar el KB — un efecto, identificado

`Rag::DocumentOverviewBuilder` lee los sidecars **directamente de S3**, no del KB.
Hoy `sections_from_sidecars` devuelve `[]` porque ningún sidecar tiene `section_identity`
(`:85`), así que `build_cold` retorna `nil` y **no existe manifiesto**: se verificó que
`s3://…/document_manifests/1/` está vacío. Después del backfill, el primer
`DocumentOverviewWarmJob` —que `PinnedDocumentsController:15` encola cada vez que un
técnico fija el documento— construirá en frío un índice de 18 secciones con sus rangos de
página y lo persistirá.

Consecuencia concreta: la pregunta «¿de qué trata este documento?» pasará de caer al
carril generativo a responderse de forma determinista con la lista de 18 marcas. Es una
mejora alineada con el producto y de coste menor (18 secciones en vez de una llamada al
LLM), pero **es un cambio de comportamiento visible que no está en el baseline de Fase 0 y
no está detrás de un feature flag**. Debe medirse: correr las tres cohortes después de
aplicar y antes de cualquier sincronización, y registrar si algún caso toca el carril de
overview.

### Riesgo residual

Una sincronización del data source disparada por **otro** motivo (otra subida, un
reprocesamiento) arrastraría esta metadata al KB sin anuncio. No es un riesgo de
corrección —el valor es correcto— pero rompería la propiedad «medido antes y después». Si
se quiere eliminar, el orden alternativo es aplicar el backfill inmediatamente antes de la
sincronización planificada, no ahora.

---

## 6. Dos conflictos de verdad-terreno, documentados y no «arreglados»

1. **Páginas 77 y 79 pertenecen a RECOBA pero imprimen FAIN.** La página 77 se titula
   «FAIN – EM66 - HIDRAULCO» y la 79 «EM66 — PLACA EKM 1000» (placa física rotulada «FAIN
   ASCENSORES EKM-1000»), y ambas están dentro de la sección RECOBA (70–79); la 46 es la
   misma diapositiva dentro de FAIN. El mazo reutiliza láminas de FAIN en RECOBA.
   **Decisión: se conserva RECOBA.** `section_identity` es la posición estructural que
   declara la divisoria —exactamente lo que produciría una ingesta v7— y el selector
   compara identificadores contra el **cuerpo**, no contra `section_identity` (etapa 2 del
   diseño de Fase 1). Sobrescribirla por lo que imprime la página sería conocimiento por
   página, que §9 del plan prohíbe. Efecto colateral positivo: las páginas 46 y 79, hoy
   indistinguibles por metadata, quedan separadas como FAIN y RECOBA.

2. **`SPM` está documentado en dos secciones con dos respuestas distintas.**
   Página 9 (CARLOS SILVA, HIDRA-TPR50): `SPM | SERIE PUERTAS CABINA – EXTERIORES`.
   Páginas 88–91 (SISTEL, TWISTER TW): `SPM (rojo) | SERIE DE PUERTAS`. Son las únicas
   cinco páginas del documento que contienen `SPM`.
   Consecuencias, ambas favorables al plan: (a) la desambiguación que producción mostró
   para una pregunta genérica por SPM era **correcta en su decisión y errónea solo en sus
   opciones** — el rastro de producción lo describe como fallo total y conviene matizarlo;
   (b) tras el backfill, agrupar por `section_key` da exactamente **dos** grupos
   documentados, que es el caso que el umbral corregido 3→2 de Fase 1 (§7 etapa 7) existe
   para representar. El caso `tpr50_spm` del fixture nombra TPR50, así que resuelve a un
   solo grupo y sigue siendo un caso `:direct`.

---

## 7. Correcciones que este documento impone a los precedentes

**Al diseño de Fase 1** ([RAG_EVIDENCE_SELECTOR_FASE1_DESIGN_2026-07-29.md](RAG_EVIDENCE_SELECTOR_FASE1_DESIGN_2026-07-29.md)):

1. **§7 etapa 5, «obtención del vecino sin una segunda llamada `Retrieve`»** — la clave S3
   descrita (`chunk_p{page}_{n}.txt`) es la del camino `manual_batch_v1`. SEGURIDADES se
   ingestó por `web_v1`, cuyo `chunk_filename` devuelve `chunk_{idx}.txt`
   (`batch_results_parser_service.rb:381-387`): **la clave no codifica la página**, así que
   el vecino no se puede derivar aritméticamente de ella. Hay que resolver página → clave
   por un índice. El manifiesto de `DocumentOverviewBuilder` —que este backfill hace
   construible por primera vez— es el lugar natural para ese índice, y evita el recorrido
   de S3 propio que el diseño ya quería evitar.
2. **§7 etapa 5, precedencia de la expansión** — tras este backfill y su sincronización, el
   mecanismo 1 (`section_identity` igual entre divisoria y vecino) queda disponible para
   `enier_mxl1_leds`: la divisoria (p35) y la página de contenido (p36) comparten `ENIER`.
   El mecanismo interino por página contigua deja de ser la única vía y el riesgo #1 de §9
   («el único caso que depende del mecanismo interino») se cierra por la vía durable.
3. **§7 etapa 6, `section_key`** — su fuente primaria queda poblada para este documento.
   El fallback a la etiqueta del encabezado `## ` sigue siendo necesario para documentos
   v5 no backfilleados.

**Al plan** ([RAG_PRECISION_V2_PLAN_2026-07-29.md](RAG_PRECISION_V2_PLAN_2026-07-29.md)):

4. **Fase 2 punto 4** («validar que ningún sidecar no-ALTIUS conserve el `canonical_name`
   global de ALJO») queda **reformulado**: `canonical_name` **se conserva a propósito** en
   los 97 —es el nombre del documento y la clave de atribución en producción— y lo que se
   valida es que `section_identity` sea específico por sección. La redacción original
   invita a un cambio que rompería la resolución y la citación.
5. **Fase 2, salida** — «el modelo/fabricante deja de depender de heurísticas sobre el
   cuerpo del chunk» se cumple a nivel de **sección/marca**, no de placa. El `board_key`
   sigue derivándose del cuerpo y de la normalización de §3 de Fase 1; ninguna metadata lo
   aporta, ni la aportará v7.

**Al rastro de producción** ([RAG_PRODUCTION_TRACE_2026-07-29.md](RAG_PRODUCTION_TRACE_2026-07-29.md)):

6. La fila «Pregunta genérica por SPM» debe registrar que SPM está documentado en dos
   secciones con dos series distintas: desambiguar era la conducta correcta; el defecto
   fue el contenido de las opciones (§6.2).

---

## 8. Estado de ejecución

| Paso | Estado |
|---|---|
| Manifiesto de auditoría (Fase 2 punto 1) | hecho, fila Sonnet |
| Corrección de la generación de sidecars futuros (punto 2) | ya vigente en `field_records_v7`; nada que hacer |
| Decisión del valor por chunk + diff revisable (punto 3) | **este documento** |
| Validación de identidad por sección (punto 4, reformulado en §7.4) | verificada en el dry-run |
| Copia y hash previos (punto 5) | implementados en el script; se ejecutan con `--apply` |
| Escritura en S3 de PROD | autorizada por el usuario el 2026-07-29 |
| Sincronización del Knowledge Base | **no autorizada, no ejecutada** — sigue tras el gate de §7.4 |
