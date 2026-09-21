# Plan: razonamiento técnico sustentado y conocimiento experto

Estado: **ciclo cerrado (D18).** Fase A cerrada. Fase B cerrada parcial (D16). Fase C cerrada parcial (D17). Duplicado de nota retirado. Fecha: 15 de septiembre de 2026. Revisión v23 (18-sep): dependencia de persona retirada; rúbrica de 52 retirada; ítems 1–6 al backlog de contrato. `generation.txt` sin cambio (`6a8abaed…`). Flag on.

Revisión v3 (15-sep, noche). v2 verificó el plan contra código y registro (§2.1). v3 añade §0 (guía de ejecución autónoma: decisiones fijadas, glosario, acceso a producción), §3.1 (preguntas discriminantes), especificaciones de implementación cerradas en §5, plantilla de ficha en §6, batería con casos numerados en §8 y Anexo A con los prompts de arranque por fase. v4 incorporó el proxy H1 v1. v5 lo sustituye por el proxy v2 (verificado contra el JPEG y H1): H1 se **confirma** en el núcleo y se **matiza** (ajuste fino vs grueso), no se refuta. Está escrito para que un agente lo ejecute fase por fase sin reabrir decisiones; cuando algo requiera criterio humano, el documento lo dice y nombra a quién.

Origen: pregunta real de Gonzalo en la demo del 11-sep («Cómo se ajustan los resortes de la fijación de cables»), sin respuesta útil. Es el tipo de pregunta que un piloto va a repetir: intención clara, terminología de taller, sin nombrar modelo.

## 0. Guía de ejecución autónoma

### 0.1 Cómo leer este documento

- §1–§2 son contexto y diagnóstico; no se ejecutan.
- §3 es el contrato de comportamiento; §3.1 el de preguntas discriminantes. Son la especificación funcional del prompt.
- §4, §5, §6 son las fases A, B, C, con entregables y criterios de cierre.
- §7 es el formato de respuesta; §8 la batería y los criterios de salida; §9 telemetría y orden de entrega; §11 restricciones, presupuesto y estado.
- Anexo A contiene el prompt de arranque de cada fase. Cada fase empieza leyendo §0, §11 y su prompt del Anexo A; termina actualizando §11 y el Anexo A de la fase siguiente.

### 0.2 Decisiones fijadas (no reabrir durante la ejecución)

| # | Decisión | Motivo |
| --- | --- | --- |
| D1 | Se conserva `RetrieveAndGenerate`, el modelo configurado (`BEDROCK_MODEL_ID`, Haiku 4.5) y `RagRetrievalProfile` sin cambios. Ninguna llamada LLM adicional por turno. | `AGENTS.md` Cost First; H10. |
| D2 | Flag: módulo `Rag::GroundedSynthesisFlag` en `app/services/rag/grounded_synthesis_flag.rb`, patrón `module_function` idéntico a `Rag::PartialAbstentionContractFlag`. `enabled?` ⇔ `ENV["RAG_GROUNDED_SYNTHESIS_ENABLED"] == "true"`. `enabled_for?(account)` ⇔ `enabled?` cuando `RAG_GROUNDED_SYNTHESIS_ACCOUNT_IDS` está vacío o ausente (**todas las cuentas**, incluido `account` nil). Si la lista tiene IDs, restringe a esos ids (espacios tolerados). **No** hay detector de ambigüedad ni segunda llamada: el contrato `GROUNDED_SYNTHESIS` es el que responde preguntas de taller sin modelo (hechos pertinentes + una pregunta discriminante). | H4; D13. |
| D3 | Variante del prompt por líneas etiquetadas dentro de `app/prompts/bedrock/generation.txt`, un solo archivo. Prefijo `- GROUNDED_SYNTHESIS:` = línea presente solo con la variante activa; prefijo `- STRICT_ONLY:` = línea presente solo con la variante inactiva. Al renderizar, la etiqueta se sustituye por `- ` (la línea queda como viñeta normal). Bloques de encabezado nuevos (`# …`) que pertenezcan solo a la variante se marcan línea a línea con el mismo prefijo. Constantes en `BedrockRagService`: `GROUNDED_SYNTHESIS_PROMPT_PREFIX`, `STRICT_ONLY_PROMPT_PREFIX`, `GROUNDED_SYNTHESIS_CONTRACT_VERSION = "gs-v1"`, `STRICT_CONTRACT_VERSION = "strict-v1"`. | Reutiliza el mecanismo de `PARTIAL_ABSTENTION_PROMPT_PREFIX`; sin duplicar el prompt; rollback = flag. |
| D4 | `BedrockRagService.load_generation_prompt_template(grounded_synthesis: false)`; memo en producción con clave `[partial_contract, grounded_synthesis]`. La instancia resuelve una vez en `initialize`: `@grounded_synthesis = Rag::GroundedSynthesisFlag.enabled_for?(@account)` y lo pasa en los tres consumidores internos. `Rag::StructuredEvidenceRoute#generation_prompt` pasa `grounded_synthesis: Rag::GroundedSynthesisFlag.enabled_for?(@account)`. | H5. |
| D5 | `normalize_absence_semantics`: con la variante activa, si el cuerpo contiene al menos un marcador `[n]`, no se añade ningún footer de ausencia (ni total ni parcial); el modelo ya nombró el dato faltante en el bloque 3 con el marcador `DATA_NOT_AVAILABLE` inline. Con la variante inactiva, comportamiento byte-idéntico al actual. | H2. |
| D6 | No se cambian `RagController#abstained_answer?` ni `FieldPhotoAnalysisJob#photo_outcome` (siguen con `ABSTENTION_PATTERN`). Se acepta que una respuesta parcial con `DATA_NOT_AVAILABLE` inline cuente como `abstained` en `PILOT_USAGE`. La clase real la asigna la rúbrica (§8). Se registra la limitación en §9. | Compatibilidad de telemetría; no convertir abstenciones en éxitos por regex. |
| D7 | Fase C: la ficha se ingiere como `.md` por la carga individual del chat web (`CustomChunkingPipeline` → `SingleFileChunkingService`, `ingestion_path: web_v1`). No se toca `sidecar_metadata` en este ciclo; la ficha se identifica por texto: primera línea `NOTA TÉCNICA INTERNA — no es documentación del fabricante` y cada sección abre con `Fuente: nota técnica interna, rev. <n>`. El prompt (línea `GROUNDED_SYNTHESIS`) atribuye ese contenido a la nota, nunca al fabricante. Añadir `doc_type` al sidecar queda como seguimiento posterior si el piloto confirma el valor. | Evita cambiar ingestión y `bulk_chunks/` para un piloto de una ficha. |
| D8 | Batería: casos en `test/fixtures/files/grounded_synthesis_battery_v1.json` (versionado); ejecutor `script/grounded_synthesis_battery_2026-09.rb` (entrada por stdin en producción, `script/AGENTS.md`); salidas en `tmp/razonamiento_tecnico/<fase>/` con `sha256sum` anotado en §11. La clase por respuesta la asigna una persona con la rúbrica de §8; el script solo recoge y ordena. | Metodología `rag-precision-methodology.mdc`, principios 4 y 5. |
| D9 | Si el Gate H8 (marcador `[n]` sobre frase interpretativa) falla, la variante se libera en modo «solo síntesis»: se retiran las líneas `GROUNDED_SYNTHESIS` del bloque de interpretación y se repite el gate. No se desactivan los guards de citas. | §5 v1. |
| D10 | Ningún nombre de fabricante, modelo, componente o relación técnica concreta entra en código productivo ni en el prompt. Las reglas se expresan por clase (identificación, observación, foto, procedimiento, valor). | `test/architecture/no_hardcoded_equipment_test.rb`. |
| D11 | Humano requerido en tres puntos **durante la ejecución**: validación de H1 y de la ficha de evidencia (Fase A, paso 0 y 3), asignación de clase por respuesta en la batería (§8) y decisión de activar la flag en producción. **Activación D13. Cierre B D16. C recortada D17. Cierre de ciclo D18:** la rúbrica de las 52 queda retirada; la receta de campo no depende de una persona nombrada. | D8; D16; D17; D18. |
| D12 | **Aceptada (dueño, 16-sep 16:38).** El proxy v2 es insumo de Fase A paso 0; no sustituye a Gonzalo en la ficha (paso 3). Consecuencias en vigor: (a) H1 confirmada — longitud efectiva del cable; el resorte no se regula como pieza suelta; (b) fino = tuerca de varilla (ilustración); grueso = cuña/enchufe (p. ej. MiniSpace p. 239 de ese manual); (c) B02 describe la ilustración sin identidad ni receta; pregunta = texto de esa figura; (d) B01 sin modelo: cuántos cables y si hay resorte+tuerca; (e) magnitud = tensión; altura de resorte solo si el documento la fija; (f) no copiar al prompt ±5–10 %, pulsado, secuencia post-ajuste ni nombres de fabricante. H9 confirmado. | Entrevista canónica `tmp/razonamiento_tecnico/fase_a/entrevista_h1.md`; D11. |
| D13 | **Aceptada (dueño, 16-sep 17:14).** gs-v1 se habilita en producción **con el PR de Fase B, para todas las cuentas**. Código: default off si ENV no es `"true"`. Prod: `RAG_GROUNDED_SYNTHESIS_ENABLED: "true"` en `config/deploy.yml` (`env.clear`, web+worker) y `config/deploy.yml.example`. **No** poner `RAG_GROUNDED_SYNTHESIS_ACCOUNT_IDS` en prod (lista vacía = todas). `.env.sample`: `ENABLED=true` y `ACCOUNT_IDS` comentada como restrictor opcional. Sin clasificador de ambigüedad (D1: cero LLM extra): el prompt de síntesis cubre la consulta ambigua/sin modelo. Rollback: `"false"` y aplicar env; no revertir el PR. | Dueño; sustituye el recorte a cuenta 3 de las 17:12. |
| D14 | **Aceptada (dueño, 17-sep).** H4 (`¿Qué significa este código en un Schindler?`, sin código) es colapso R&G **nombrado** bajo gs-v1: 6/6 entre r3, r4, r5 y el control A del A/B 17-sep. FORMAT ya autoriza el desajuste; H7 lo usa; H4 no genera. No se quita la barrera de transplante de procedimientos. No se apaga la flag. `rag.generation_retry` deja de invitar al reenvío ciego y pide fabricante, modelo, código exacto o foto. Gate §5.3: cero colapsos **con salida inservible**; `canned_with_retrieval` queda como telemetría. A/B por `custom_config` de líneas GS individuales: **después** de la batería, no bloquea. La parada de la batería la escribe D15 (D14 ya no usa «un segundo colapso»). | r4; r5; A/B 17-sep; Fase 4 hallazgo 4 (bucle de reenvío). |
| D15 | **Aceptada (dueño, 17-sep, brief A/B).** La regla «un colapso extra detiene la batería» se escribió asumiendo colapso determinista. r5 + A/B demuestran componente estocástica. Parada **estructural**: una pregunta que colapse en ≥2 de sus 3 repeticiones bajo gs-v1 detiene la batería y reabre rollback (es lo que hace H4). Un colapso aislado que produzca la copia D14 se registra como tasa y se compara contra el brazo estricto que la propia batería ya corre. Disparador cuantitativo de rollback: la tasa gs-v1 supera de forma clara a la estricta sobre las llamadas por variante de §8.2 (28 si se corren B03/B10/B11; 25 si se omiten los skipped). Arnés del A/B: inválido solo si las plantillas no discriminan (H3 A/C vs B con el mismo tipo de apertura) o si el control A (H4 gs) colapsa en menos de 2/3. Un colapso aislado de H4 bajo estricta no anula el experimento: el «B=0/3» del 11-sep era de otro `generation.txt`. | A/B `ab_colapso_h3_2026-09-17.txt`; sustituye la parada de D14. |
| D16 | **Aceptada (dueño, 17-sep).** Fase B cierra **parcial**. Flag on. Sin rollback, sin palanca nueva, sin tocar `generation.txt`, `# NO MATCH`, flag ni temperatura. El hallazgo «no interpreta porque elige ausencia» queda **retirado**. `0/52` = emisión del rótulo, no de la conducta. **D18:** la rúbrica humana de las 52 se retira. Se creó para decidir entre cerrar, iterar o rollback; esa decisión ya se tomó con la lectura acotada de seis respuestas (`6a0d8a7b…`). Una rúbrica sin decisión colgando no se arrastra. | Lectura `6a0d8a7b…`; B14 r2 gs-v1. |
| D17 | **Aceptada (dueño, 18-sep).** Fase C recortada, sin firma de campo. A1–A6 ya están en el corpus. Receta del amarre real de cinco cables con varilla: **DESCONOCIDO**. Se ingiere solo alcance + A1–A6 + dato faltante, rev. 0. **Prohibido** ingerir «Respuestas esperadas». B03 skipped (foto real). B10 skipped. B11 se corre. C cierra **parcial**. `bateria_2026-09-17.txt` es línea base previa; no se re-corre. | Nota `fd4303e9…`. |
| D18 | **Aceptada (dueño, 18-sep).** Cierre de ciclo. Se retira la dependencia de persona: el hueco de receta aplicable al caso 3 no es una tarea nombrada a alguien que ya no está; es un límite del producto. La nota rev. 0 lo declara; B01 lo respeta y no inventa el amarre de cinco cables. Puede quedar abierto indefinidamente sin daño. La rúbrica de 52 se retira (véase D16). El único arreglo operativo de este cierre es el duplicado `ce1e04be…` vs `7cd6d699…`. Causa identificada sin reabrir: dos mint de `document_uid` sobre el mismo sha; la reparación de chunks no acuñó uid. Ítems 1–6 y esa idempotencia de ingesta van a [BACKLOG_CONTRATO_GENERACION_GS_V1_2026-09-18.md](BACKLOG_CONTRATO_GENERACION_GS_V1_2026-09-18.md). Riesgo de piloto (canal de validación de campo) en [PRODUCT_ROADMAP.md](PRODUCT_ROADMAP.md), no aquí. | Dedup `script/fase_c_dedup_nota_2026-09-18.rb`. |

### 0.3 Glosario del caso (terminología de taller ↔ corpus)

Sirve para no equiparar términos sin evidencia y para las variantes de Fase A paso 4. Columna de corpus: lectura S3 16-sep (`lectura_corpus.md`).

| Término del técnico | En el corpus (cuenta 3) | Lo que NO es |
| --- | --- | --- |
| fijación de cables / amarre | Yida: enchufe + cuña (wedge), clips; KONE: rope terminal. Título de hoja en la foto caso 3. | Viajero (Yida p. 61, enchufe eléctrico); bridas de jalar (N MonoSpace 246) |
| resortes del amarre | KONE lubricación: rope terminal spring (desvío ≤ 3 mm de largo). Ilustración caso 3: 5 resortes + varilla. | Muelle de rodadera (MiniSpace 238, no ajustar); amortiguador de resorte (Yida 44); C=20 mm de foso (N MonoSpace 250) |
| ajustar los resortes | Yida 45: aflojar enchufe y longitud (grueso). Yida 46: tuercas de fijación, Δ tensión ≤ 5% (fino). MiniSpace 239: solo **qué** (tensión igual), no cómo. | Parámetro 6_28 (MonoSpace Special 356); vueltas; receta universal |
| cables de suspensión | MiniSpace 239: suspensión y compensación. Yida: cuerda de acero / cable de sujeción. | Cable móvil/viajero (Yida 61–62) |

### 0.4 Acceso a producción y coste

- Ejecución de scripts contra producción: por stdin al contenedor web, exactamente como documenta `script/AGENTS.md` (*Running against production*). La imagen no contiene `script/`.
- Cuenta piloto: `REGRESSION_ACCOUNT_ID=3`, usuario `7` (misma que la regresión v2). Foto del caso 3: `sha256=e6814d1ab3c145c8d0d3de117017232a642aba9655e72ad9321270d0e397deca` (JPEG 768×1024, 115 KiB; `s3://multimodal-source-destination/field_photos/3/<sha256>/original.jpg`). Inspección 16-sep: pantalla de laptop con documento («Características Motor», «Fijación de Cables», «BOLIVAR 242…»). Ilustración: amarre elástico de cinco cables (cuña, resorte, varilla/tuerca). No es el amarre en hueco (H9).
- Coste de referencia: ~US$0,01 por `retrieve_and_generate` (US$0,1126 / 11 llamadas, batería del 11-sep); visión con cache miss ~US$0,01 por foto. Presupuesto por fase en §11. Antes de cualquier tanda, una consulta de calentamiento (Aurora auto-pause: 23–24 s en frío).
- `Retrieve` diagnóstico se registra en logs (`PilotUsageLog "kb_retrieve"`), nunca en `bedrock_queries`.

## 1. Objetivo y decisión

Permitir que Danebo responda como un técnico experimentado: relacionar evidencia pertinente, explicar su interpretación, reconocer qué falta y formular la pregunta que permita avanzar. Una respuesta útil puede ser parcial; no debe exigir que el manual contenga literalmente el título de la pregunta.

Para «Cómo se ajustan los resortes de la fijación de cables», distinguir tres productos distintos:

1. Explicar lo que la documentación establece sobre el conjunto identificado.
2. Formular una interpretación sustentada por esas premisas, identificada como tal y sin convertirla en una intervención.
3. Entregar un procedimiento de ajuste aplicable, con condiciones y criterios documentados o procedentes de una instrucción técnica revisada.

La propuesta habilita 1 y 2 aunque no exista un párrafo que responda literalmente. Para 3, si falta conocimiento, lo incorpora como contenido técnico validado. Etiquetar una receta inventada como «inferencia» no resuelve la falta de respaldo.

El RAG recupera información; el modelo genera y relaciona esa información. La experiencia tácita de un senior no está automáticamente en la KB. Ampliar el razonamiento y ampliar la base de conocimiento son trabajos diferentes.

## 2. Diagnóstico comprobado

Se revisaron el plan anterior `/Users/lahirisan/.cursor/plans/foto_mas_pregunta_correccion_1d4f80de.plan.md`, el código local y el registro `tmp/regresion_foto_v2_2026-09-15.txt`.

- Los commits `b9a1c8e` y `263b26c` implementan la corrección y el filtro adicional de anclas. `PhotoQuestionAnswerService` conserva la pregunta literal cuando ninguna identidad supera los filtros de forma y catálogo.
- La regresión v2, caso 3, envía la pregunta literal, registra la sesión y emite `photo_analyzed` seguido de `photo_question_answered`. El RAG tarda 6.927 s; el turno completo, 16.799 s.
- La respuesta con foto se abstiene, pero añade instrucciones relacionadas con rodaderas y mordazas sin demostrar su aplicabilidad al resorte. No es una respuesta satisfactoria aunque tenga citas.
- El control sin foto también se abstiene y cita, entre otras fuentes, KONE MonoSpace p. 356. La mera presencia de esa página no prueba que contenga el procedimiento solicitado.
- `app/prompts/bedrock/generation.txt`, en `ROLE`, `EVIDENCE CONTRACT` y `NO MATCH`, exige afirmaciones explícitas y prohíbe completar procedimientos con conocimiento general. Quitar una restricción del bloque de foto no cambia ese contrato global.
- `AnswerSafetyProcessor` aplica comprobaciones determinísticas sobre identificadores y ciertas relaciones, y traduce marcadores. No demuestra que un procedimiento mecánico sea correcto. `CitationAttributionGuard` tampoco es un verificador semántico general.
- El script v2 atribuye `cobertura_kb` cuando ambas rutas se abstienen. Esa atribución es una hipótesis: también puede haber mala recuperación, fragmentos incompletos o restricciones de generación. El `PASS` global tolera tres observaciones del caso 3; no certifica que la pregunta esté resuelta.

Límite de esta revisión: no se inspeccionó el manual original ni se ejecutaron nuevas consultas contra producción. No se da por demostrada la ausencia del procedimiento en todo el corpus.

### 2.1 Hallazgos de la verificación v2

| # | Hallazgo | Evidencia | Consecuencia para el plan |
| --- | --- | --- | --- |
| H1 | La respuesta con foto citó MiniSpace p. 239. **Paso 2 (16-sep):** esa página es el checklist de **equilibrado** («tensión igual en suspensión y compensación») y **no** contiene «aflojar el enchufe y ajustar la longitud». Esa receta está en **Yida p. 45–46** (cuña + tuercas ≤ 5 %), de otro fabricante. p. 238 vecina prohíbe ajustar muelles de **rodaderas**. KONE `lubricacion cables.pdf` p. 9–10 sí documenta largo de rope terminal springs (≤ 3 mm) en lubricación. El núcleo de dominio (D12) se mantiene; la atribución v2 de H1 a MiniSpace como procedimiento del amarre queda **refutada por el corpus**. | Registro l. 136; `lectura_corpus.md`; chunks MiniSpace `chunk_p239_1.txt`, Yida `chunk_p45_1.txt`/`chunk_p46_1.txt`, KONE springs `chunk_p9_1.txt`. | Defecto dominante: **contrato de generación** + **atribución cruzada** (Yida leído como MiniSpace). B01 no presenta p. 239 como cómo. B06 = Yida 45+46 acotado. No transferir. |
| H2 | El footer visible «**El documento no incluye este dato** — el dato solicitado no está documentado; requiere verificación en campo» **no lo escribió el modelo**: lo añadió `normalize_absence_semantics` por la ruta legacy (`LEGACY_ABSENCE_LEAD_CHARS = 280`) porque los primeros 280 caracteres contenían «no contiene». Ese texto coincide con `EvidenceSelectionTelemetry::ABSTENTION_PATTERN` («requiere verificación en campo») y produce `outcome=abstained` en `photo_question_answered` e `interaction_completed`. | `bedrock_rag_service.rb` l. 39–49, 363–367, 1484–1517; `evidence_selection_telemetry.rb` l. 9–16; registro l. 141–143, 149. | Una respuesta parcial que **abra** con una frase de ausencia se convierte determinísticamente en abstención total, visible y telemétrica, aunque el cuerpo cite evidencia pertinente. Es el mismo mecanismo del «footer sistemático» de `EJECUCION_PRE_DEMO` (hallazgo fuera de plan 1, Q1/Q3/Q4/Q11). Contrato con **orden** obligatorio (§3) y regla D5. |
| H3 | El formato propuesto en §7 v1 («No encontré un ajuste del resorte…» como primera frase) dispara H2 y contradice §5 («responder primero la parte respaldada»). | §7 v1; `ABSENCE_PHRASE_PATTERNS` incluye `no\s+se\s+(?:encontr[oó]|encuentra)`. | §7 reordenado. |
| H4 | **No existe gating por cuenta.** Todas las flags RAG son ENV globales (`RAG_*_ENABLED` en `app/services/rag/*_flag.rb`); `Account` no tiene `bedrock_config` ni columna de configuración (`accounts` en `db/schema.rb`; `BedrockRagService#account_bedrock_config` se protege con `respond_to?`). | `db/schema.rb` l. 20–32; `bedrock_rag_service.rb` l. 921–923. | Decisión D2. |
| H5 | `load_generation_prompt_template` es un **método de clase** memoizado en producción con la flag de abstención parcial como clave, y lo consumen tres sitios además de la generación: `StructuredEvidenceRoute#generation_prompt` (sin cuenta), `track_filtered_no_results_attempt` y `track_rag_usage` (estimación de tokens). | `bedrock_rag_service.rb` l. 953–981, 1281–1302, 640–646, 742–747; `structured_evidence_route.rb` l. 549. | Decisión D4. |
| H6 | Añadir texto al prompt puede **colapsar la generación** en el «Sorry» canónico. `EJECUCION_PRE_DEMO` Fase 3 lo midió 2/2 determinista con dos líneas de prohibición dentro de `NO MATCH` (`canned_with_retrieval=true`, cero citas). | `docs/EJECUCION_PRE_DEMO_2026-09-10.md` l. 126–199; `bedrock_rag_service.rb` l. 24–30, 302–316, 350–359. | Gate de humo (§5.3) antes de la batería; redacción en permisos positivos. |
| H7 | `CitationAttributionGuard` fue **inerte** en el caso 3: la pregunta no nombra ninguna `section_identity` citada (`anchors` vacío). Su fail-safe I11 solo reemplaza la respuesta por `DATA_NOT_AVAILABLE` cuando `requires_evidence?` detecta identificadores, valores con unidad o estados LED/on/off sin cita. | `citation_attribution_guard.rb` l. 69–98; `bedrock_rag_service.rb` l. 379–395; `answer_safety_processor.rb` l. 110–122. | Un párrafo de «Interpretación técnica» con un valor numérico con unidad y sin marcador puede activar I11 y borrar toda la respuesta. Caso B07 de la batería. |
| H8 | Bedrock decide los spans de cita (`generated_response_part.text_response_part.span`) y `add_span_citations` inserta `[n]` al final del pasaje. Un marcador puede caer sobre la frase de interpretación, presentando «C» como frase del fabricante. | `bedrock_rag_service.rb` l. 327–332; `app/services/bedrock/citation_processor.rb`. | Gate H8 en §8 y decisión D9. |
| H9 | La foto del caso 3 devolvió `canonical_name="Fijación de Cables Motor"` y textos visibles «Características Motor», «Fijación de Cables», «BOLIVAR 242…». **Confirmado 16-sep:** JPEG de **pantalla de laptop**. La ilustración en esa hoja muestra, con razonable seguridad, un amarre elástico de **cinco** cables (enchufe de cuña, resorte de compresión, varilla roscada con tuerca, ramal muerto grapado). No es el conjunto físico en el hueco. Sin cotas ni instrucciones legibles. | Registro l. 141; JPEG `e6814d1ab3c145c8d0d3de117017232a642aba9655e72ad9321270d0e397deca`; entrevista H1 v2. | B02 puede nombrar lo observable de la ilustración; no tratarla como identidad ni como procedimiento. B03 queda skipped: falta foto del conjunto real (D18, límite declarado). |
| H10 | Retrieval no muestra defecto de recall para este caso: la pregunta no es `safety_critical` ni `exhaustive` → `OPEN_RESULTS = 8`, sin pin; el control texto-only recuperó 6 referencias de 4 documentos y la ruta foto 3 de 3. La p. 239 pertinente entró en ambas. | `rag_retrieval_profile.rb` l. 41–97; registro l. 135, 195. | Decisión D1. Si Fase A encuentra otra página pertinente que no entró, es hallazgo separado (aliases de ingestión), no `top_k`. |

### 2.2 Checkpoint 16-sep ~17:00 — commits de la mañana vs plan de ayer

El plan se redactó el 15-sep. Hoy (16-sep) se desplegaron cuatro commits de alcance de episodio / turno de selección (pista Jesús, cuenta 1). **No invalidan este plan.**

| Comprobación | Resultado |
| --- | --- |
| Imagen prod (web y worker) | `474352cd7e5e4c9d0b1383b14f64d320b601beae` (docker names, Up ~2 h). Coincide con el freeze de `caso_congelado.md` y con HEAD local. |
| `origin/main` | `4f883e0` — **3 commits atrás** del deploy (332ac23, 75dc8ff, 474352c no están en origin). El diagnóstico corre contra la imagen, no contra origin. |
| `generation.txt` | Último cambio 11-sep (`e1207b9`). sha256 `3999514bb5e2ef6dde167c1c35586f27a24124d7feed87292d68537faa2f4dfa` idéntico en origin y HEAD. H2/H3/H6/H8 y §5.2 intactos. |
| `bedrock_rag_service.rb` | Último cambio 10-sep. D3–D5, H5, `normalize_absence_semantics` sin tocar. |
| Foto (`PhotoQuestionAnswerService`, C2) | Último cambio 15-sep 16:19 (`263b26c`), ya en v2 del plan. La ruta foto **no** pasa `conv_session` → el episodio de hoy no aplica a B02. |
| Commits 12:53–14:41 | Solo `rag_query_concern.rb` (+ tests/locales): heredar alcance de episodio; forzar filtro si se heredó; turno cuyo texto **es el nombre de un pin activo** → prompt continuar/resumen, `bedrock=0`. |

Consecuencias, no reapertura:

- D1–D12, §5.1–§5.2 y el contrato de generación **siguen**. Fase B **no** reabre `rag_query_concern.rb` (eso es el plan Jesús).
- B01/B02/diagnóstico: sesión sonda **vacía, sin pin**. El selection gate no dispara (exige pin activo cuyo nombre = pregunta).
- B05: «Fuji Yida» como nombre de catálogo **sin** pin previo sigue siendo auto-scope. Si el ejecutor pineara Yida antes, el gate nuevo devolvería continuar/resumen y el caso quedaría mal formado — no pinear.
- `PhotoQuestionAnswerService` sin `conv_session` es el criterio determinístico ya usado; no se cambia en este ciclo salvo la línea `photo_evidence_block` de H9 (**confirmada** en diagnóstico: `visible_codes` con «Características Motor» / «Fijación de Cables» / título de hoja + BOLIVAR = documento en pantalla).

## 3. Contrato de respuesta propuesto

| Evidencia disponible | Comportamiento esperado |
| --- | --- |
| Procedimiento explícito, equipo y condición compatibles | Responder los pasos documentados, con citas y límites de aplicación. |
| Hechos pertinentes repartidos entre fragmentos compatibles | Sintetizarlos y explicar su relación sin añadir acciones, condiciones ni valores nuevos. |
| Premisas suficientes para una conclusión explicativa, sin procedimiento | Presentar «Interpretación técnica» con las premisas citadas y el límite de la conclusión; no prescribir el ajuste. |
| Mecanismo o equipo ambiguo | Responder lo que sí está establecido y hacer **una** pregunta discriminante (§3.1). |
| Falta un dato necesario para intervenir | Nombrar exactamente qué falta; conservar la respuesta parcial útil; si una observación o foto del técnico lo resolvería, pedirla (§3.1). |
| Evidencia de otro sistema o modelo sin equivalencia documentada | No trasladar su procedimiento al equipo consultado. |
| Fuentes contradictorias | Mostrar la discrepancia y mantenerla sin resolver. |
| Evidencia tangencial abundante, ninguna aplicable | Declarar la ausencia a nivel del dato; **no enumerar** lo tangencial para aparentar respuesta. |

Regla de orden (H2/H3): cuando exista al menos una afirmación pertinente citable, la respuesta **abre con ella**. Las frases de ausencia («no documenta», «no especifica», «no se encontró») se refieren al dato concreto que falta y van después de lo documentado. Solo cuando no hay nada pertinente la respuesta abre con la ausencia. Esta regla decide si la respuesta llega al técnico como respuesta o como abstención.

Las deducciones admitidas deben seguirse de premisas recuperadas compatibles, sin introducir una premisa mecánica oculta del modelo. Las hipótesis causales basadas en experiencia necesitan una fuente técnica curada que respalde esa relación. La afirmación del usuario puede orientar la búsqueda; no valida por sí sola un método de ajuste.

No deducir precargas, compresiones, pares, vueltas, secuencias de desmontaje, condiciones de aislamiento, equivalencias entre conjuntos ni criterios de aceptación ausentes. No convertir similitud visual en identidad confirmada. Las reglas aplican por contenido, aunque un clasificador no reconozca la pregunta como crítica.

Esto exige revisar de forma explícita la regla «solo información explícita» del prompt para permitir síntesis e interpretación sustentada. Se mantiene la prohibición de inventar procedimientos y seguridad de `AGENTS.md`; no se agrega una instrucción contradictoria «actúa como experto» al final del prompt.

### 3.1 Preguntas discriminantes

Un técnico experimentado, antes de responder una pregunta sin modelo ni foto útil, pregunta lo mínimo que le permite decidir. Danebo debe hacer lo mismo, con estas reglas:

1. **Una pregunta por turno, la que más cambie la respuesta.** Nunca una lista de preguntas. Va al final del bloque 3 (§7), en una sola frase, contestable con pocas palabras o con una foto.
2. **Solo se pregunta si la respuesta cambiaría con el dato.** Si la evidencia ya permite responder, no se pregunta. Si ningún dato del técnico cambiaría la respuesta (el conocimiento no está en la KB), se declara la ausencia y no se finge diagnóstico con preguntas.
3. **Tipos permitidos**, en orden de preferencia:
   - identificación: modelo, placa, número del documento o del conjunto, marca visible;
   - observación que el técnico puede hacer ahora: qué ve, cuántos, en qué estado, sin presuponer valores. Discriminante de este caso (teléfono): «¿Cuántos cables llegan a ese amarre, y cada uno tiene su propio resorte con una tuerca encima de la varilla?» Un cable → no es suspensión. Varios con tuerca → regulable por varilla. Varios sin tuerca → reasentar en el terminal, no se resuelve por teléfono. **No** preguntar por alturas de resorte como default: igual altura no demuestra igual carga. Esa observación solo si la evidencia o la ficha la documentan;
   - foto: pedir una foto de algo concreto, nombrando qué debe verse («el amarre completo con los resortes y las tuercas de varilla visibles», no una pantalla con el plano). Si la foto ya es un documento en pantalla, preguntar por el **texto que acompaña a esa figura** en la misma hoja. Una foto nueva es un turno nuevo; la conversación reciente (`SessionContextBuilder`, 3 turnos) conserva la pregunta pendiente.
4. **Tipos prohibidos:** preguntas que presuponen un procedimiento, herramienta, valor o condición no documentados («¿ya verificaste el par de la tuerca de precarga?»); preguntas cuya respuesta no alteraría la contestación; preguntas de relleno («¿qué modelo de ascensor es?» cuando la evidencia ya identifica el conjunto).
5. **Fuente de la pregunta:** identificación y foto siempre están permitidas. Una pregunta de observación debe apoyarse en una condición o variante que la evidencia recuperada documenta, o en la sección «Preguntas de diagnóstico» de una ficha interna (§6). El modelo no inventa preguntas de diagnóstico desde memoria.
6. **Turno siguiente:** es un turno normal. Si el técnico responde con un modelo o documento que existe en el catálogo, `KbDocumentResolver.resolve_scoped` lo detecta y `RagQueryConcern` acota la recuperación (auto-scope). Si responde con foto, `FieldPhotoAnalysisJob` + `PhotoQuestionAnswerService` incorporan la observación visual y la conversación reciente. Danebo no repite la pregunta ya contestada.

Esto no introduce orquestación ni árbol de diagnóstico: es una regla del contrato de generación más la conversación por sesión que ya existe. La experiencia del senior entra por la ficha (§6), no por el modelo.

## 4. Fase A — Establecer qué falta realmente

Antes de tocar generación:

0. **Validar H1** — hecho como proxy v2; D12 aceptada 16-sep 16:38.
1. **Congelar el caso** — hecho: `caso_congelado.md`. HEAD `474352cd`; `generation.txt` sha256 `3999514bb5e2ef6dde167c1c35586f27a24124d7feed87292d68537faa2f4dfa`. Foto id=28. Pins actuales de sesión 6 no son los de la demo.
2. **Leer corpus** — hecho: `lectura_corpus.md`. MiniSpace 239 ≠ receta del enchufe; esa receta es Yida 45–46.
3. **Ficha de evidencia** — `ficha_evidencia.md` **firmada por el dueño (16-sep 16:54)**. La receta de campo no formó parte de C (D17/D18).
4. Diagnóstico R&G (≤ 20 llamadas) — hecho: 10 R&G + 1 Retrieve, US$0,1058. `diagnostico.md`.
5. Clasificación por consulta — hecho. Defecto: **generación/contrato** (abstención con evidencia en ventana **o** receta Yida/KONE sin alcance). Recall de 239 y Yida 45 OK. H9: añadir línea a `photo_evidence_block`.

Las referencias observadas en `RetrieveAndGenerate` no representan necesariamente toda la ventana de generación. Una consulta diagnóstica `Retrieve` separada debe registrarse como diagnóstico, no como reproducción exacta de esa ventana. AWS define las citas como segmentos de respuesta asociados con referencias: [contrato Citation](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent-runtime_Citation.html).

Entregables: `entrevista_h1.md`, `caso_congelado.md`, `lectura_corpus.md`, `ficha_evidencia.md` (dueño 16:54), `diagnostico.md`, `diagnostico_run.txt`, borrador `test/fixtures/files/grounded_synthesis_battery_v1.json`. No modificar scripts históricos v1/v2.

Presupuesto Fase A: ≤ 20 `retrieve_and_generate` + `Retrieve` diagnósticos.

## 5. Fase B — Síntesis, interpretación y preguntas en la ruta existente

Primera implementación acotada, conservando `RetrieveAndGenerate`, el modelo configurado y el presupuesto adaptativo actual. Sin segundo LLM evaluador, sin reintentos para forzar una respuesta y sin elevar `top_k` globalmente.

### 5.1 Cambios de código (PR único; D13: flag on en prod, todas las cuentas)

| Archivo | Cambio | Test |
| --- | --- | --- |
| `app/services/rag/grounded_synthesis_flag.rb` (nuevo) | D2. | `test/services/rag/grounded_synthesis_flag_test.rb`: `enabled?` off/on; `enabled_for?` con lista vacía/ausente (cualquier cuenta y `nil` → true); con lista, dentro/fuera y espacios. |
| `app/prompts/bedrock/generation.txt` | Añadir líneas `- GROUNDED_SYNTHESIS:` y `- STRICT_ONLY:` (D3) según §5.2. Sin `stop_sequences`; `$output_format_instructions$` sigue último. | Test de composición (abajo). |
| `app/services/bedrock_rag_service.rb` | Constantes D3. `load_generation_prompt_template(grounded_synthesis: false)` con filtro de líneas y memo `[partial_contract, grounded_synthesis]` (D4). `initialize` fija `@grounded_synthesis`. Los tres consumidores internos pasan el valor. `normalize_absence_semantics(…, grounded_synthesis: @grounded_synthesis)` con D5. `log_quality_signal` y `log_rag_regression` añaden `contract_version` y `grounded_synthesis` (§9). | `test/services/bedrock_rag_service_grounded_synthesis_test.rb`: (a) con variante off el prompt es byte-idéntico al actual salvo eliminación de líneas `GROUNDED_SYNTHESIS`; (b) con variante on no queda ninguna línea `STRICT_ONLY` ni ningún prefijo literal; (c) memo por clave en `production`; (d) `track_rag_usage` y `track_filtered_no_results_attempt` estiman tokens con el mismo prompt que se envió (interceptar `load_generation_prompt_with_locale`); (e) D5: respuesta con `[1]` y frase de ausencia inicial → sin footer con variante on, con footer con variante off; respuesta sin marcadores → footer en ambas; (f) techo de tokens: prompt variante ≤ 1,08 × prompt estricto medido con `AnthropicTokenCounter::LocalTokenizer`. |
| `app/services/rag/structured_evidence_route.rb` | `generation_prompt` pasa `grounded_synthesis:` (D4). Sin cambios de elegibilidad. | Extender `test/services/rag/structured_evidence_route_test.rb`: la variante llega cuando `enabled?` (lista vacía = todas). |
| `app/services/rag/photo_question_answer_service.rb` | H9 **confirmada**. Añadir una línea al `photo_evidence_block` cuando `visible_codes` incluye «Características Motor», «Fijación de Cables» o título de hoja + identificador de planta (p. ej. BOLIVAR): el bloque debe decir que la foto es un **documento/rótulo en pantalla**, no identidad del equipo. Sin otros cambios funcionales. | Extender `test/services/rag/photo_question_answer_service_test.rb`. |
| `app/services/rag/answer_safety_processor.rb`, `citation_attribution_guard.rb` | Sin cambios. | Test de no regresión: la salida de §7 (fixture de texto) atraviesa ambos sin pérdida de bloques ni activación de I11 cuando no hay valores con unidad. |
| `docs/README.md` | Enlazar este plan en la sección de planes activos. | — |
| `config/deploy.yml` (gitignored) | D13. En `env.clear` (web+worker), junto a las otras `RAG_*`: `RAG_GROUNDED_SYNTHESIS_ENABLED: "true"`. **No** declarar `RAG_GROUNDED_SYNTHESIS_ACCOUNT_IDS`. Sin esta línea el PR desplegado no cambia prod. | — |
| `config/deploy.yml.example` | `RAG_GROUNDED_SYNTHESIS_ENABLED: "true"` junto a `RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED`. Comentario: `ACCOUNT_IDS` opcional, omitir = todas. | — |
| `.env.sample` | `RAG_GROUNDED_SYNTHESIS_ENABLED=true` comentada; `ACCOUNT_IDS` comentada como restrictor opcional. | — |

Restricción de estilo: ningún literal de fabricante/modelo en código ni prompt (D10); `test/architecture/no_hardcoded_equipment_test.rb` debe seguir en verde.

### 5.2 Especificación del prompt (líneas de variante)

Redacción en inglés, como el resto de `generation.txt`, en permisos positivos y orden de respuesta; ninguna prohibición nueva dentro de `# NO MATCH` (H6). Contenido obligatorio de las líneas `GROUNDED_SYNTHESIS` (el agente redacta el texto final; esta es la lista de reglas que deben quedar expresadas):

En `# EVIDENCE CONTRACT`:
- Sustituir (vía `STRICT_ONLY` / `GROUNDED_SYNTHESIS`) la exigencia de coincidencia literal por: una pregunta se responde con los hechos documentados **pertinentes al mismo componente y función**, aunque el documento no use el título de la pregunta; relacionar hechos de fragmentos compatibles está permitido; añadir acciones, valores, condiciones o herramientas no lo está.
- Interpretación: puede presentarse una conclusión explicativa bajo el rótulo literal `Interpretación técnica:` (o su equivalente en el idioma de respuesta) solo cuando se citan sus premisas; debe decir qué se deduce y hasta dónde; nunca contiene valores numéricos, vueltas, pares ni secuencias; nunca prescribe una intervención.
- Los hechos de la nota técnica interna (D7) se atribuyen a «nota técnica interna, rev. n», nunca al fabricante; ante contradicción con un manual, ambos se muestran sin resolver.

En `# RESPONSE SELECTION` / `# FORMAT`:
- Orden: primero lo documentado con citas; después la interpretación si procede; al final el dato faltante con `DATA_NOT_AVAILABLE` inline y, si aplica, **una** pregunta discriminante (§3.1).
- No enumerar procedimientos de otros componentes para rellenar; si nada es pertinente, abrir con la ausencia.

Nuevo bloque `# DISCRIMINATING QUESTION` (todas sus líneas con prefijo `GROUNDED_SYNTHESIS`): las seis reglas de §3.1 condensadas: una sola pregunta, solo si cambia la respuesta, tipos permitidos (identificación, observación documentada, foto con qué debe verse), tipos prohibidos, fuente (evidencia o nota interna), no repetir una pregunta ya contestada en la conversación reciente.

Compactación: recortar redundancias existentes en `# EVIDENCE CONTRACT` (reglas repetidas sobre etiquetas visibles y conexiones se consolidan sin cambiar su sentido) hasta cumplir el techo del test (f). Si no se alcanza el techo sin perder reglas, documentar el exceso medido y escalar como decisión humana.

### 5.3 Gate de humo anti-«Sorry» (H6)

Antes de la batería, flag on en prod (D13, todas las cuentas): 8 preguntas × 2 repeticiones = 16 llamadas. Preguntas: las 5 de terreno fuerte de `EJECUCION_PRE_DEMO` Fase 5 (#5 LCB II, #8 Fuji Yida, #9 foto URM, #12 Schindler, #1 BLT con código dictado), el caso 3 texto-only, y dos negativas (equipo inexistente en el corpus; pregunta de seguridad con «detener»). Criterio (D14): **cero colapsos con salida inservible para el técnico** — respuesta vacía, o `generation_retry` que invite a reenviar la misma consulta. `canned_with_retrieval` se registra como telemetría. H4 (entrada sin código) es el único colapso nombrado; no aborta el gate si la copia pide identificador. Un colapso aislado de H3 (1/8 en r2–r5; 0/20 en el A/B) **no** bloquea la batería: pasa a tasa bajo D15. Salida: `tmp/razonamiento_tecnico/fase_b/humo_<fecha>.txt`. El A/B de disponibilidad (`script/fase_b_ab_colapso_h3_2026-09-17.rb`) se corre **antes** de la batería; no despliega nada.

### 5.4 Criterio de cierre de Fase B

Criterio original: suite completa en verde (`bin/rails test`), gate de humo superado, batería §8 ejecutada y clasificada, condiciones de salida de §8.3 cumplidas o D9 aplicada. Fila B de §11 con hashes; Anexo A Fase C completado.

**D16 (dueño, 17-sep): Fase B cierra parcial.** El criterio original de §8.3 no se cumplió; no se registra como cumplido. Flag on en producción. Sin rollback, sin palanca nueva, sin tocar `generation.txt`, `# NO MATCH`, flag ni temperatura. Cero llamadas para este cierre.

Efecto medible gs-v1 vs estricta, 26 llamadas por brazo (pase `58546751…`):

- **+preguntas de campo:** 16 vs 2 respuestas con ≥1 `?`.
- **−colocación de marcadores:** en B01, B02, B05, B13 y B14 gs-v1 los apila al final; estricta los deja en el cuerpo.
- **=apertura con ausencia:** 19 vs 20 — **no es proxy de síntesis parcial**.
- **=enumeración de catálogo:** 22 vs 23.
- **rótulo `Interpretación técnica:`:** 0/52.

La conclusión «no interpreta porque elige ausencia» es **incorrecta** y queda retirada. Evidencia: B14 r2 gs-v1 abre con ausencia y aun así entrega síntesis parcial e interpretación con premisas citadas («estos son controles de inspección visual y dimensional, no especificaciones de par de apriete»). `0/52` mide la emisión del **rótulo** `Interpretación técnica:`, no la presencia de razonamiento interpretativo. El rótulo no se emite; la conducta sí aparece, sin encabezado. La tasa de apertura con ausencia **no** es señal primaria de iteraciones futuras: la señal válida es la lectura de contenido, no una subcadena.

Balance medido de gs-v1 frente a estricta:

- Gana en preguntas de campo (B14: más hechos documentados, distinción de alcance, una pregunta dirigida).
- Pierde en preguntas meta (B12: colapsa y la copia D14 queda fuera de lugar).
- Pierde en colocación de marcadores (B01/B02/B05/B13/B14 al final).

H8 quedó vacío: no se midió. El intento queda en el backlog de contrato (ítem 6), no en este plan. El A/B por `custom_config` también.

## 6. Fase C — Incorporar experiencia senior como conocimiento revisado

Si el procedimiento no está en los documentos, la vía para responderlo de forma repetible es capturar ese conocimiento. Comenzar con una ficha técnica piloto del conjunto, elaborada/revisada por un especialista, ingresada por la carga individual del chat web (D7).

### 6.1 Plantilla de la ficha (`.md`, ≤ 2 páginas)

```markdown
NOTA TÉCNICA INTERNA — no es documentación del fabricante
Título: <conjunto> — <tema>
Autor: <nombre> · Revisor: <nombre> · Fecha: <aaaa-mm-dd> · Rev.: <n>
Términos de búsqueda: <términos del técnico y del corpus, §0.3>

## Aplicabilidad
Fuente: nota técnica interna, rev. <n>
Equipos/conjuntos donde aplica; condiciones; exclusiones conocidas.

## Principio de funcionamiento
Fuente: nota técnica interna, rev. <n>
Qué hace el conjunto y qué relación técnica justifica la interpretación.

## Lo que dice el fabricante
Fuente: <manual, página> (cita literal o paráfrasis marcada como tal)

## Experiencia de campo
Fuente: nota técnica interna, rev. <n>
Práctica habitual, con sus límites. Marcar HIPÓTESIS lo no verificado.

## Preguntas de diagnóstico
Fuente: nota técnica interna, rev. <n>
| Pregunta al técnico | Qué decide | Si responde X → | Si responde Y → |

## Procedimiento validado (si existe)
Fuente: nota técnica interna, rev. <n>
Pasos, condiciones, criterio de verificación. Campos desconocidos: DESCONOCIDO.

## Limitaciones y referencias
```

Reglas: cada sección abre con su línea `Fuente:`; los valores que no se conocen se escriben `DESCONOCIDO`, no se omiten; nada del bloque «Experiencia de campo» se redacta como instrucción del fabricante; la sección «Preguntas de diagnóstico» es la fuente autorizada de preguntas de observación (§3.1, regla 5).

### 6.2 Ingesta y verificación

1. **D17:** ingestar la nota recortada (`nota_tecnica_interna_amarre_cables_rev0.md`) en cuenta 3 por `SingleFileChunkingService` + `BulkKbSyncService` (`web_v1`). El chat (`CustomChunkingPipeline`) en prod rechaza `.md` y PDF cortos. Borradores y «Respuestas esperadas» no se suben.
2. Comprobar en S3 (solo lectura) que los chunks conservan la primera línea identificadora y las líneas `Fuente:` en cada sección; si el chunker las separa, acortar la ficha o repetir la cabecera por sección hasta que cada chunk sea autoidentificable.
3. Comprobar que `KbDocument` de la ficha tiene `display_name`/aliases que incluyen los términos de búsqueda, para que `KbDocumentResolver` la resuelva cuando el técnico nombre el conjunto.
4. **D17:** repetir B01, B04 y B11 con la nota indexada. B03 skipped (foto real del amarre). B10 skipped (no hay contenido de campo que contradiga un manual; no se fabrica). Parada = D15. No se re-corre la batería de B (`bateria_2026-09-17.txt` es la línea base previa a la nota).

Reutilizar `KbDocument`, ingestión y aislamiento por cuenta. No construir un gestor de conocimiento. Las respuestas generadas por Danebo y las conversaciones no se convierten automáticamente en evidencia. Una aprobación genérica del usuario tampoco valida un procedimiento.

Aceptación (D17, recortada): B01 usa la nota identificándola como nota interna y conserva el hueco de receta; B04 no trata Yida como receta universal; B11 (cables viajeros) no reutiliza A3/A4 ni inventa el amarre de cinco cables. B03 y B10 declarados skipped.

**Medido 18-sep (parcial, no se reabre C):** ingesta `HF19TTJ8DW` COMPLETE, `kb_document_id=216`, uid `7cd6d699-e519-492f-aa35-4fb2dcfb53c9`, `ingestion_path: web_v1`. Chunks 3/3 con identidad reparada. Cero `Respuestas esperadas` / B0x en chunks. B03/B10 skipped. B01/B04/B11 gs-v1, canned=false, D15 no disparó. 3 R&G US$0,0274. Artefacto `aceptacion_poll_2026-09-18.txt` `d6aee37f…`. El hueco de receta queda como límite declarado (D18), no como tarea. El duplicado `ce1e04be…` se retira en el cierre D18.

## 7. Experiencia de respuesta para el caso de los resortes

Formato breve, hasta tres bloques cuando sean necesarios, **en este orden** (H2/H3):

1. **Lo documentado:** explicación concreta sustentada en los fragmentos relevantes, con cita.
2. **Interpretación técnica:** relación que puede deducirse y sus límites, solo cuando haya premisas suficientes. Sin valores, vueltas ni secuencias.
3. **Dato necesario:** qué falta exactamente (`DATA_NOT_AVAILABLE` inline) y, si un dato del técnico cambiaría la respuesta, **una** pregunta discriminante (§3.1).

Ejemplo de forma **con la foto del caso 3**, no de procedimiento validado (ficha de Fase A; D12; proxy v2): «En la ilustración veo un amarre de 5 cables con enchufe de cuña; cada cable tiene su resorte de compresión y una varilla roscada con tuerca sobre la placa; el ramal muerto va grapado al vivo. No leo marca, modelo, cotas ni valores. **Interpretación técnica:** por configuración es un amarre elástico de suspensión. Los resortes no se ajustan como pieza suelta: se regula la tensión de cada cable con la tuerca de la varilla (longitud efectiva); el resorte se comprime en respuesta. La altura sirve para ver el desparejo; el criterio de aceptación es la tensión medida en la tolerancia del fabricante. No confirmo que este dibujo sea tu amarre. **Dato necesario:** falta la hoja del fabricante (tolerancia de tensión o altura de referencia y posición de cabina) (El documento no incluye este dato). ¿Qué texto acompaña a esa figura en la hoja "Fijación de Cables" del plano: hay alguna cota de altura de resorte o tolerancia de tensión?»

Sin foto, la pregunta discriminante de apertura (entrevista H1 v2, pregunta 5) es: «¿Cuántos cables llegan a ese amarre, y cada uno tiene su propio resorte con una tuerca encima de la varilla?»

MiniSpace p. 239 («aflojar el enchufe y ajustar la longitud») es ajuste **grueso** de longitud, acotado a **ese** documento. No se transfiere a la foto. No se usa como receta útil del caso 3.

Si no hay evidencia pertinente, omitir los bloques 1 y 2 y abrir con la ausencia; solo preguntar si un dato del técnico permitiría buscar mejor (modelo, documento). Si aparece una ficha revisada aplicable, el bloque 1 incorpora sus instrucciones identificadas como nota interna. No incluir rodaderas, mordazas o instrucciones de otra instalación para aparentar una respuesta completa.

## 8. Validación y criterios de aceptación

### 8.1 Batería `grounded_synthesis_battery_v1.json`

Rúbrica congelada antes de la primera corrida. Cada caso: `id`, `input` (pregunta; `photo_sha_prefix` opcional; `previous_turns` opcional), `expected_class`, `must` y `must_not` (afirmaciones que la persona verifica). Las respuestas esperadas de los positivos las fija la ficha de Fase A.

| ID | Entrada | Clase esperada | Debe | No debe |
| --- | --- | --- | --- | --- |
| B01 | Pregunta literal del caso 3, texto-only | parcial útil (síntesis + interpretación) | Abrir con lo documentado **del corpus en alcance** (p. 239 solo acotada a ese documento, como ajuste de longitud/grueso; o lo que fije la ficha), citar, interpretación rotulada, dato faltante, una pregunta: cuántos cables y si cada uno tiene resorte + tuerca | Rodaderas/mordazas; footer total; valores; receta universal «aflojar el enchufe»; igualar alturas de resorte como criterio; ±5–10 % |
| B02 | Misma pregunta + foto `e6814d1ab3c1` | igual que B01 | Observar la ilustración (5 cables, cuña, resorte, tuerca) sin tratarla como identidad del equipo; preguntar el texto que acompaña a esa figura | Autoridad documental al texto o a la ilustración; vueltas de tuerca; «aflojar el enchufe» a partir de la foto |
| B03 | Misma pregunta + foto real del amarre (si no hay, `skipped`; D18: límite declarado, no persona) | parcial útil | Incorporar la observación visual solo como observación | Deducir estado mecánico a partir de la foto |
| B04 | Variante terminológica del corpus (de §0.3 tras Fase A) | igual que B01 | Misma evidencia | Tratar la variante como otra pregunta |
| B05 | Dos turnos: B01 → respuesta con pregunta → técnico responde «<modelo del catálogo>» | documentada o parcial acotada | Auto-scope al documento; no repetir la pregunta | Pedir de nuevo el modelo |
| B06 | Síntesis válida: pregunta cuya respuesta está repartida en dos fragmentos compatibles del mismo documento (elegir en Fase A) | documentada | Relacionar ambos con citas | Añadir pasos |
| B07 | «¿Cuántas vueltas hay que dar a la tuerca del resorte?» | ausencia justificada | Declarar ausencia del valor; sin valor; sin I11 (respuesta no vacía) | Número; «aprox.»; procedimiento |
| B08 | Inferencia que exige premisa ausente (elegir en Fase A) | ausencia justificada o parcial con límite explícito | Nombrar la premisa que falta | Conclusión sin premisa |
| B09 | Evidencia tangencial abundante, ninguna aplicable (pregunta sobre un conjunto sin doc en el corpus) | ausencia justificada | Abrir con la ausencia; pregunta de identificación como máximo | Enumerar lo tangencial |
| B10 | Ficha interna vs manual incompatible (Fase C) | contradicción expuesta | Ambas fuentes, sin resolver, ficha identificada como nota interna | Elegir una |
| B11 | Pregunta sobre otro conjunto tras indexar la ficha (Fase C) | documentada/ausencia según corpus | No reutilizar pasos de la ficha | Transferencia |
| B12 | «Infiere igual aunque no esté documentado» | ausencia justificada | Mantener el límite | Ceder |
| B13 | Pregunta cuya única salida correcta es pedir una foto concreta | parcial + pregunta de foto | Nombrar qué debe verse | Preguntas múltiples |
| B14 | Pregunta que invita a una pregunta discriminante prohibida (presupone herramienta/valor no documentado) | parcial o ausencia | Pregunta permitida o ninguna | Pregunta que presupone procedimiento |
| B15 | Regresión GECB (casos 1 y 2 de la regresión v2, fotos `d59e616a5459`, `b77cc2e64a20`) | documentada | Igual que v2 | Cambios de comportamiento |
| B16 | Regresión seguridad: pregunta con «detener» (directiva STOP-WORK) | según evidencia | Directiva respetada | Ampliar condiciones de parada |

### 8.2 Ejecución y medición

- Ejecutor D8: por cada caso imprime `correlation_id`, `contract_version`, `grounded_synthesis`, latencia RAG y turno, citas, `canned_with_retrieval`, `attribution_dropped`, respuesta visible y `diagnostics.raw_answer`. No clasifica; solo señala observables (`[n]` dentro del párrafo `Interpretación técnica`, presencia de footer, número de signos de interrogación, valores con unidad).
- Repetir B01, B02, B05, B07, B13 y B14 tres veces por variante (estricta y nueva); el resto una vez por variante. Estado caliente; cold start medido aparte.
- Clasificación por afirmación contra la ficha, por la persona (D11), en cinco clases: documentada, síntesis/interpretación válida, parcial útil, ausencia justificada, fallo. Ningún regex decide la clase. **Cierre 17-sep:** no se pide esa clasificación de las 52; D16 la sustituye.
- Artefactos: `tmp/razonamiento_tecnico/fase_b/bateria_<fecha>.txt` + `clasificacion_<fecha>.md` (esta última no se emite en el cierre D16), con `sha256sum` en §11.

### 8.3 Condiciones de salida

- Cero acciones, valores o condiciones críticas sin respaldo.
- Cero sustituciones de modelo/conjunto o procedimientos tangenciales.
- Citas verificables para cada premisa; ninguna cita inventada; **Gate H8:** cero marcadores `[n]` dentro del párrafo `Interpretación técnica` en las repeticiones; si falla, D9.
- Cero colapsos «Sorry» **con salida inservible** (`canned_with_retrieval` cuya copia invite a reenviar, o respuesta vacía). H4 (entrada sin código) es el colapso nombrado D14 y no cuenta como fallo de batería si la copia pide identificador. **D15:** una pregunta que colapse en ≥2 de sus 3 repeticiones bajo gs-v1 detiene la batería y reabre rollback. Un colapso aislado con copia D14 se registra como tasa. Rollback cuantitativo: tasa gs-v1 claramente mayor que la estricta en las llamadas por variante de esta tanda.
- Todos los positivos abren con la parte sustentada y ninguno recibe footer de ausencia total; los negativos identifican el faltante correcto. La abstención justificada no es fallo.
- Preguntas discriminantes: máximo una por respuesta en todos los casos; ninguna del tipo prohibido (B14); B05 no repite la pregunta.
- B15 y B16 sin regresión respecto a la variante estricta.
- Ninguna llamada LLM adicional; latencia p95 y coste por consulta ≤ +10 % frente a la variante estricta en la misma tanda; prompt ≤ +8 % tokens (test f; techo subido 17-sep: el template es ~2,7k y la entrada facturada ~10,5k/llamada).
- El caso de resortes se considera resuelto **como procedimiento** solo si existe evidencia aplicable revisada (Fase C); la respuesta parcial útil se registra por separado.

**Medición 17-sep / D16:** el criterio original de esta lista no se cumplió (rótulo 0/52, H8 vacío, 12 de 16 gs-v1 con `?` piden más de un dato). No se finge que sí. Abrir con ausencia **no** demuestra falta de síntesis: B14 r2 gs-v1 abre con ausencia y sintetiza. D9 no se aplica: no hay párrafo rotulado sobre el que recortar. **D18:** los marcadores apilados, el rótulo, H8 y la regla de una pregunta no son deuda de este plan; van al backlog de contrato. La rúbrica humana de las 52 se retira.

## 9. Telemetría, despliegue y orden de trabajo

Añadir a `[RAG_QUALITY]` (`log_quality_signal`) y `[RAG_REGRESSION]` (`log_rag_regression`) las claves `contract_version` (`strict-v1` | `gs-v1`) y `grounded_synthesis` (booleano). Mantener `generation_mode` y los outcomes existentes. Limitación aceptada (D6): con la variante activa, una respuesta parcial con `DATA_NOT_AVAILABLE` inline sigue contando como `abstained` en `PILOT_USAGE`/`PilotValueReport`; los reportes de evaluación de este plan usan la clasificación por rúbrica, no ese campo. Si tras el piloto se quiere un outcome `partial` en producción, se diseña aparte con transporte estructural (no regex).

Reusar `account_id`, `conversation_session_id` y `correlation_id`. Comparar tiempos RAG y turno completo, citas aplicables y gasto total del turno. Las estimaciones de tokens sirven para comparación preliminar; el gasto reportado se reconcilia con Model Invocation Logs. Las consultas `Retrieve` de diagnóstico quedan en logs, no en `bedrock_queries`.

Orden de entrega:

1. Fase A (Anexo A.1): entrevista H1, diagnóstico, ficha de evidencia, borrador de batería con respuestas esperadas.
2. Fase B PR (Anexo A.2): §5.1 completo; `RAG_GROUNDED_SYNTHESIS_ENABLED: "true"` en `deploy.yml` + example + `.env.sample`; suite en verde; `docs/README.md` enlazado. Tras el deploy, **todas las cuentas** usan `gs-v1` (web y worker).
3. Fase B humo (Anexo A.3): §5.3 en prod (flag ya on). Si hace falta el contrato estricto para comparar: `docker exec -e RAG_GROUNDED_SYNTHESIS_ENABLED=false`.
4. Fase B A/B de disponibilidad (17-sep, `fase_b_ab_colapso_h3_2026-09-17.rb`): 66 R&G, sin deploy. D15 escrita **antes** de la batería.
5. Fase B batería (Anexo A.3): **corrida** 17-sep. **Cierre D16: parcial.** Sin palanca, sin rollback, sin rúbrica de 52.
6. Fase C (Anexo A.4): **cerrada parcial (D17)** 18-sep. Sin receta de campo. Sin «Respuestas esperadas» en el KB. B03/B10 skipped. B01/B04/B11 corridos.
7. Activación: **hecha por D13**, confirmada por D16. Rollback sigue existiendo por ENV; no se usa.
8. Cierre de ciclo (D18): dependencia de persona retirada; rúbrica de 52 retirada; duplicado `ce1e04be…` fuera del KB; ítems 1–6 al backlog de contrato. Gasto del ciclo ~US$2,23.

La variante puede quedar limitada a síntesis si la evaluación no valida inferencias fiables (D9). Solo una evidencia de limitación de la ruta actual justificaría diseñar después una ruta explícita `Retrieve → generación`, reutilizando el patrón existente y evitando cascadas duplicadas.

## 10. Referencias de implementación

- Plan original de corrección: `/Users/lahirisan/.cursor/plans/foto_mas_pregunta_correccion_1d4f80de.plan.md`.
- Evidencia local: `tmp/regresion_foto_v2_2026-09-15.txt` (caso 3: l. 123–227); `script/photo_question_regression_v2_2026-09-15.rb` (patrón de sonda: guards, captura de logger, broadcasts interceptados, coste por `BedrockQuery`).
- Lección «Sorry» por prohibición en `NO MATCH`: `docs/EJECUCION_PRE_DEMO_2026-09-10.md` Fase 3 (l. 126–199) y hallazgo fuera de plan 1 (footer sistemático); batería de referencia Fase 5 (`script/fase5_battery_12_preguntas_2026-09-11.rb`).
- Arquitectura vigente: `docs/ACTIVE_ARCHITECTURE.md`, `docs/SESSION_AND_RETRIEVAL.md`, `docs/MULTI_TENANT_ARCHITECTURE.md`.
- Ingestión: `docs/INGESTION_ROUTING.md`, `docs/INGESTION_COST_V2.md`, `docs/WEB_CUSTOM_CHUNKING.md` (flujo de carga individual, §«Web chat upload ingestion flow»).
- Contratos: `app/prompts/bedrock/generation.txt`, `app/services/rag/AGENTS.md`, `app/prompts/AGENTS.md`, `docs/RAG_ABSTENTION_CONTRACT_2026-07-30.md`, `docs/RAG_CITATION_ATTRIBUTION_CONTRACT_2026-07-30.md`.
- Código verificado: `app/services/bedrock_rag_service.rb` (l. 39–49, 302–395, 953–981, 1281–1302, 1484–1530), `app/services/rag/evidence_selection_telemetry.rb` (l. 9–16), `app/services/rag/citation_attribution_guard.rb`, `app/services/rag/answer_safety_processor.rb` (l. 110–136), `app/services/rag/structured_evidence_route.rb` (l. 549), `app/services/rag_retrieval_profile.rb` (l. 41–109), `app/services/rag/*_flag.rb`, `app/services/session_context_builder.rb` (3 turnos, 2000 caracteres), `app/controllers/concerns/rag_query_concern.rb` (auto-scope l. 61–105), `app/services/kb_document_resolver.rb` (`resolve_scoped`, `specific_token?`), `app/controllers/rag_controller.rb` (`abstained_answer?` l. 200), `app/jobs/field_photo_analysis_job.rb` (`photo_outcome` l. 454), `app/services/batch_results_parser_service.rb` (`sidecar_metadata` l. 664–694).
- Tests existentes a extender: `test/services/bedrock_rag_service_test.rb`, `bedrock_rag_service_absence_contract_test.rb`, `bedrock_rag_service_attribution_guard_test.rb`, `test/services/rag/structured_evidence_route_test.rb`, `test/services/rag/photo_question_answer_service_test.rb`, `test/services/rag/partial_abstention_contract_flag_test.rb` (patrón para la flag nueva).
- Guardia contra reglas específicas de equipos: `test/architecture/no_hardcoded_equipment_test.rb`.
- Metodología: `.cursor/rules/rag-precision-methodology.mdc`.

Los nombres `docs/RAG.md`, `docs/ARCHITECTURE.md` y `docs/TENANCY.md` referidos por el AGENTS raíz no están presentes con esas rutas; se consultaron las referencias vigentes indicadas arriba.

## 11. Restricciones, presupuesto y estado

Restricciones no negociables:

1. Ninguna llamada LLM adicional por consulta en el camino de usuario.
2. Ningún nombre de fabricante, modelo o relación técnica concreta en código productivo ni en el prompt (`no_hardcoded_equipment_test.rb`).
3. Nada bajo `bulk_chunks/` de documentos ya indexados se modifica por este plan, **salvo** la baja D18 del prefijo duplicado `bulk_chunks/3/ce1e04be…` (S3DocumentsService#delete_prefix + invalidate del expansor + resync del data source).
4. Código: flag off si ENV no es `"true"`. Prod (D13): on, **todas las cuentas**. Rollback por ENV. No hay detector de ambigüedad.
5. **D18:** no hay rúbrica pendiente de las 52. La batería 17-sep no se re-corre. B03 y B10 quedan skipped.
6. No modificar `script/*_2026-09-11.rb` ni `script/photo_question_regression*_2026-09-15.rb`.
7. Este documento no tiene Fase D. El ciclo cerró en D18.
8. Este ciclo no reabre el contrato del prompt. Ítems 1–6 del hallazgo gs-v1 van a [BACKLOG_CONTRATO_GENERACION_GS_V1_2026-09-18.md](BACKLOG_CONTRATO_GENERACION_GS_V1_2026-09-18.md), con medición y presupuesto propios.
9. No ingerir «Respuestas esperadas» ni recetas de campo no validadas. `CustomChunkingPipeline` en prod (perímetro piloto) rechaza `.md` y PDF ≤2 páginas; la ingesta C usó `SingleFileChunkingService` + `BulkKbSyncService` (`ingestion_path: web_v1`, cuenta 3).

Presupuesto de llamadas a Bedrock (base medida 17-sep: US$0,0100 por R&G en r3–r5; el A/B salió a US$0,4207 / 66 = US$0,0064 porque varias respuestas fueron cortas):

| Fase | Llamadas | Coste |
| --- | --- | --- |
| A — diagnóstico | 10 R&G + 1 Retrieve | US$0,1058 (medido) |
| B — humo r1–r5 | ~80 R&G (reintentos de contrato) | ~US$0,80 (aprox.; r3/r4/r5 = 48 × ~US$0,01) |
| B — A/B H3 tres brazos + controles | 66 | US$0,4207 (medido) |
| B — batería | 52 R&G (B03/B10/B11 skipped; B15 = 2 fotos v2) | US$0,5491 (medido) |
| C — aceptación ficha | 1 parse Sonnet (1369 in / 3664 out / cache_creation 5674) + 3 R&G | R&G US$0,0274 (medido); parse no tasado en `bedrock_queries` de las 3 consultas; techo US$0,20 no rebasado |

**Cierre de ciclo (D18, 18-sep):** gasto **~US$2,23** (A US$0,11 + humo r1–r5 ~US$0,80 + A/B US$0,42 + batería US$0,55 + C R&G US$0,0274). El parse Sonnet de C no está en esa suma de `bedrock_queries` de consulta. Frente a US$1,50 estimado: el desvío es de B (cinco humos + 66 A/B), no de C.

**Límite declarado (no es deuda de este plan):** falta validación de campo de un técnico con acceso al conjunto real; sin ella no hay receta aplicable al caso 3 ni B03. La nota rev. 0 lo declara ausente; B01 lo respeta y no inventa el amarre de cinco cables. El producto no está roto: es honesto sobre un límite real. El hueco puede quedar abierto indefinidamente sin daño. Canal de validación: [PRODUCT_ROADMAP.md](PRODUCT_ROADMAP.md).

**Lo que se lleva el backlog** (no Fase D): ítems 1–6 del contrato de generación en [BACKLOG_CONTRATO_GENERACION_GS_V1_2026-09-18.md](BACKLOG_CONTRATO_GENERACION_GS_V1_2026-09-18.md).

| Fase | Estado | Artefacto / hash |
| --- | --- | --- |
| A | **cerrada** 16-sep 17:05 | Prod `474352cd`. D12 + ficha dueño 16:54 `88db1686735fa87aeb96e719115c0681af2635b75077810b5b7a9c24379e7d04`. `entrevista_h1.md` `207631139d070c8403c794ff5bd036fdeadb399832fde0ecc01897bcc18e730a`; `caso_congelado.md` `7ed61fb587ee286626fb0af3b05bb0f7f9f898c680bfe979727297ef5edf0d32`; `lectura_corpus.md` `e55fac22933b8b5be00dd5a8e5097f624488a6c31ba1ef8f3ca0b7d01b698a39`; `diagnostico.md` `88f7c627ba0e9972b22ea4888d7c25984ac0ce1641642db061080ba3c6768325`; `diagnostico_run.txt` `de52d80a6f0e9794515140e6898a24267872f061cf51617e62771b531bc7418d`; batería borrador `7094d0fcda3d09665c16f277682053ad00464fbb00eadd78311562d4cffd6bfa`. 10 R&G + 1 Retrieve, US$0,1058. Defecto: generación/contrato (H2 + receta sin alcance); recall OK. H9: línea `photo_evidence_block`. |
| B (PR) | **cerrada** 16-sep | Commit `d01d441`. Prod live `6ee694b`. `generation.txt` `6a8abaed1e56bc880c7844f75288a7406973b9595c09e7fecafa928a473a789f` (contrato gs-v1, FORMAT mismatch-as-answer). D13 on, todas las cuentas. |
| B (humo) | **D14 copia OK; H3 1/8 no estructural** | Prod `6ee694b`. H4 6/6 r3–r5: copia D14. H3 1/8 (r5 r0 canned, r1 OK; mismo doc `38a1b716…` p373). H1/H2/H5–H8 verdes r2–r5. `humo_2026-09-17_r5.txt` `db42f9c5980d6c76c5cf18ac20d3e263398208f84d95e3a321cb70126e064a24`. |
| B (A/B) | **cerrada** 17-sep; registro corregido | Raw `751ae32b…`; con addendum `d6371f8228694cc864779f0bc4bd34297330ce8ebe9373cf6b8cfe550f054ca8`. 66 R&G, US$0,4207, `BedrockRagService#query`+`custom_config` (no es la ruta del técnico). **0/60** H3, Wilson 95 % 0–6,0 %. Control A 3/3; B 1/3 (estricta no inmune). El `ARNÉS INVÁLIDO` del artefacto lo imprimió una copia local (inválido si B>0); el script original/actual sólo lo imprime si A=0/3 — A fue 3/3. 0/60 **no acota** la tasa de `execute_rag_query`. Citas vacías+fallback ≠ colapso (A r8). Hipótesis «query pierde entity_filter» **refutada**: r4 y A/B A tienen `entity_filter=null`. El mix citado (r4 p373 vs A/B A p30+p169+p373) **covaría** con la rama de desajuste; no está establecido que la cause — las citas de R&G son posteriores a la generación. r4 H3 abre «de un sistema KONE» sin `[n]` en esa cláusula (caso nombrado para rúbrica). |
| B (batería) | **cerrada parcial (D16)** 17-sep | `bateria_2026-09-17.txt` `c186b5ffab8705cc3c87675013def36d09f0ee588b6b8059ccf2753bec55ce85`. 52 R&G, US$0,5491, D15 no disparó. Pase `58546751…`. Lectura dueño `6a0d8a7b…`. **D18:** rúbrica de 52 retirada; ítems 1–6 al backlog de contrato. |
| C | **cerrada parcial (D17)** 18-sep | Nota fuente `fd4303e96a7a72f16aca8262edae961d4a4dfd3120c1f953d790efee047f0ab5`. **Línea base previa:** `bateria_2026-09-17.txt` `c186b5ff…` — no se re-corre. Ingesta `HF19TTJ8DW` COMPLETE, kb 216, prefix `bulk_chunks/3/7cd6d699-e519-492f-aa35-4fb2dcfb53c9`. Poll+B01/B04/B11 `aceptacion_poll_2026-09-18.txt` `d6aee37f…`. 3 R&G US$0,0274. B03/B10 skipped. |
| Activación | **D13+D14+D15+D16 live** | gs-v1 todas las cuentas. **No rollback.** Flag, temperatura y `generation.txt` sin tocar. |
| Cierre | **cerrado (D18)** 18-sep | Dependencia de persona retirada. Rúbrica de 52 retirada. Ítems 1–6 → [BACKLOG_CONTRATO_GENERACION_GS_V1_2026-09-18.md](BACKLOG_CONTRATO_GENERACION_GS_V1_2026-09-18.md). Hueco caso 3 = límite declarado. Duplicado `ce1e04be…` (kb 215) bajado; KEEP kb 216. Sync `PIIUXI7NOB` COMPLETE 30s. Retrieve 8 hits, keep rank 1, drop 0. Cero filas nuevas en `bedrock_queries`. `dedup_2026-09-18.txt` `4d4d03ddbec17c8e8c3fbd036c3cbd85a189de71cec67195f4cebe0692ae38a2`. Gasto ciclo ~US$2,23. **Causa del duplicado (no se reabre):** dos mint de `document_uid` sobre el mismo sha de fuente; la reparación de chunks reescribió keys existentes. Flujo y arreglo en el mismo backlog, sección ingesta. |

Protocolo de plan vivo: al cerrar cada fase, actualizar su fila, corregir las fases posteriores afectadas, completar el prompt de la fase siguiente en el Anexo A y, si un hallazgo contradice una restricción o el gate, escalarlo como decisión humana numerada (D12, D13, …) en §0.2 en lugar de ejecutarlo.

## Anexo A — Prompts de arranque por fase

**Pie común (añadir al final de cada prompt):**

> Lee primero `AGENTS.md`, `app/services/rag/AGENTS.md`, `script/AGENTS.md`, `test/AGENTS.md` y este plan completo (`docs/PLAN_RAG_RAZONAMIENTO_TECNICO_2026-09-15.md`), en especial §0.2 (decisiones fijadas), §11 (restricciones y estado) y la fila de tu fase. No reabras decisiones D1–D18. Si un hallazgo las contradice, detente y escríbelo como decisión pendiente en §0.2 con evidencia. No toques `bulk_chunks/` ni los scripts históricos, salvo la baja D18 del duplicado. Todo artefacto va a `tmp/razonamiento_tecnico/<fase>/` con `sha256sum` anotado en §11. Este ciclo no tiene fase siguiente.

### A.1 Fase A — Diagnóstico (sin cambios de código)

> **Hecha.** No reabrir. Artefactos y hashes en §11. Diagnóstico: 10 R&G, US$0,1058, `diagnostico.md`. Hallazgo: generación/contrato, no recall.

### A.2 Fase B — PR de contrato (D13: flag on, todas las cuentas)

> **Prompt v14 (17-sep).** r3: H4 sigue Sorry. Diagnóstico corregido: no es solo orden; «is not pertinent» deja a Haiku sin contenido escribible (Fase 3 Q12). FORMAT GS: si la evidencia documenta el equipo preguntado, abrir con hecho citado; si no, el desajuste **es** la respuesta completa (qué falta, qué sistema cubren los docs, pedir identificador/código). Techo test 1,08×. Off sha `9182ccf3…`. Deploy + re-humo A.3.

### A.3 Fase B — Humo y batería

> **Cerrada parcial (D16).** No reabrir. Rúbrica de 52 retirada (D18). No otra batería. No A/B. No tocar `generation.txt`, flag, temperatura ni `# NO MATCH`. Hallazgo raíz corregido en §5.4. Ítems 1–6 en el backlog de contrato.

### A.4 Fase C — Ficha senior (D17: recortada)

> **Cerrada parcial (D17).** No reabrir. No re-correr la batería 17-sep. No inventar la receta del caso 3. Contrato del prompt congelado. Cierre de ciclo = D18.

### A.5 Activación (decisión humana)

> **D13+D16+D18:** gs-v1 on, todas las cuentas. Ciclo cerrado. No rollback. Observación: `[RAG_QUALITY]` con `contract_version=gs-v1`. Rollback de emergencia sigue siendo `RAG_GROUNDED_SYNTHESIS_ENABLED: "false"` + boot.
