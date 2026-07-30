# Plan RAG SEGURIDADES v2 — precisión y usabilidad

**Estado:** Paso G ejecutado; metadata sincronizada, gates externos fallidos y Paso H bloqueado.
**Fecha:** 2026-07-29.
**Entorno diagnosticado:** producción, de forma únicamente lectora, mediante Kamal.
**Regla de ejecución:** no sincronizar el Knowledge Base, cambiar flags en producción ni desplegar esta versión sin autorización explícita y sin cerrar los gates externos.

### Estado de ejecución al 2026-07-30

| Paso A–I | Estado verificable |
|---|---|
| A — integración inicial del contrato | implementado y cubierto por tests |
| B — Fase 1 selector | integrado en `main` mediante fast-forward de `2d1e141` |
| C — selector en sombra | implementado; no sustituye la respuesta generativa |
| D — tarjetas y accesibilidad | implementado y validado localmente a 320/375/430 px |
| E — locales | implementado en español e inglés |
| F — medición «antes» | ejecutada; fixture v2.1 = **6/10**, por lo que no habilita release |
| G — backfill/sincronización | job `D3QMVZNBEH` completado: 97 metadata modificadas; medición «después» v2.1 = **6/10**, selector sobre-ambiguo |
| H — despliegue/flags | **bloqueado por gates fallidos**; no ejecutado y flags apagados |
| I — cierre | resultado externo de G documentado; falta corregir selector y repetir gates antes de H |

Resultado completo de G:
[RAG_SEGURIDADES_PASO_G_DESPUES_2026-07-30.md](RAG_SEGURIDADES_PASO_G_DESPUES_2026-07-30.md).

El despliegue que el usuario ejecutó desde `main` ocurrió antes del fast-forward local
de `7c5e954` a `2d1e141`; por tanto no contiene ni el selector de Fase 1 ni los cambios
locales posteriores documentados aquí.

## 1. Resultado del diagnóstico

La causa principal no es que el PDF carezca de la información ni que Rails pierda una respuesta correcta al renderizarla. La falla dominante ocurre antes de la generación:

1. Los chunks de las nueve preguntas con respuesta directa contienen el dato esperado: **completitud 9/9**.
2. La recuperación ubica el chunk correcto en el top 3 solo en **5/9** casos directos; en top 10 llega a **8/9** y top 20 no mejora (MXL1 permanece fuera del top 20).
3. La metadata de producción aplana todo el manual: los sidecars auditados usan el mismo `canonical_name` de ALJO/ALTIUS, incluso en páginas Carlos Silva, CTA, Elecmegon, Enier y Thyssen. No aportan una identidad de sección/modelo confiable.
4. `Rag::AmbiguousModelResponder` toma los primeros tres encabezados/modelos distintos. No exige que contengan el identificador consultado —por ejemplo, `SPM`— ni una frase que responda la relación pedida. En producción ofreció tres opciones con **0/3 de relevancia para SPM**.
5. Las páginas divisorias recuperan bien el nombre del modelo, pero la página siguiente contiene la tabla o dato. Esto perjudica TPR50 y MXL1.
6. El generador recibe un contexto incorrecto o incompleto y luego responde sobre ese contexto. El problema no se resuelve agregando reglas de respuesta ni ampliando globalmente `top_k`.

Conclusión: hay que corregir **identidad estructural + selección de evidencia + representación de ambigüedad**. Las expresiones regulares deben quedar limitadas a normalización y validaciones de seguridad, no convertirse en una clase especial por página.

## 2. Fuente de verdad verificada

Se verificó el PDF nativo y su render visual. Las páginas indicadas son páginas del archivo PDF.

PDF fuente: `/Users/lahirisan/Documents/Danebo/Danebo Elevator Rag Julio 2026/entrevosdtas /SEGURIDADES 1.1-1.pdf` — atención: el nombre de la carpeta `entrevosdtas ` termina en un espacio; una ruta escrita sin ese espacio no resuelve. Artefactos de verificación en `tmp/pdfs/seguridades_audit/`.

Nota de nomenclatura: el PDF usa tanto «TOKIBAT 2007» (página divisoria) como «TOKIBAT – 2.007» (tablas). Tratar ambas como variantes del mismo modelo en la normalización de Fase 1.

| Caso | Evidencia literal verificada | Página |
|---|---|---:|
| ALTIUS | D8 = `SERIE SEGURIDAD LIMITADOR`; D11 = `SERIE CERRADURAS CABINA`. No se documenta lógica ON/OFF. | 7 |
| Carlos Silva HIDRA-TPR50 | SPM = `SERIE PUERTAS CABINA - EXTERIORES`. | 9 |
| CTA SR8P | SPH, placa SR8P = `SERIE PUERTAS CAB. EXT. CERRADA`. | 17–18 |
| EM2000 eléctrico | LEDs `SEG`, `SCE`, `SCC`, `AP`; no `SPE`. | 31 |
| EM4000 V1 | El encabezado del obstáculo documenta `XC4` y `XC7`. | 33 |
| EDEL-K3 | 37 = `PUERTAS HUECO`; 39 = `PUERTAS CABINA`; 41 = `CERROJOS CABINA Y EXTERIORES`. | 26 |
| TOKIBAT 2.007 | DL27/SSH = `SERIE SEGURIDAD HUECO CERRADA`. No se documenta cuándo se enciende. | 40 |
| ENIER MXL1 | 12 = `SERIE STOP Y SEGURIDADES HUECO`; 19 = `SERIE TOPE FOSO`. | 36 |
| Thyssen Serie E | L9 = seguridades principales; L8 = puertas exteriores; L7 = cerrojos exteriores-cabina. No se documenta normal/fallo. | 93 |
| Elecmegon, sin modelo | Depende del modelo: EM2000/EM4000 usan LED AP; EM3000 presenta el obstáculo por conector CN y no como LED AP en su tabla de seguridades. Se debe pedir el modelo. | 29–33 |

El rastro de producción de hoy no replica exactamente la batería: contiene DL27 dos veces y no muestra una ejecución equivalente de EDEL-K3. Por ello, el benchmark posterior debe usar las diez preguntas canónicas, no contar el recorrido manual como una corrida completa.

## 3. Diagnóstico medible por capa

### 3.1 Ingesta y chunks

- Los valores objetivo están en el cuerpo del chunk y en registros estructurados ya presentes.
- Los chunks actuales usan el contrato `field_records_v5`; la propagación jerárquica más reciente no está aplicada a este documento.
- Faltan campos confiables de sección: fabricante, modelo/controlador, placa, ruta jerárquica y relación entre página divisoria y página de contenido.
- En TOKIBAT aparece prosa especulativa sobre el significado habitual de “activo/encendido” antes de retractarse. La ingesta no debe introducir convenciones no escritas en el PDF.

### 3.2 Recuperación

Resultado del diagnóstico `Retrieve` de producción:

| Consulta explícita | Rango del chunk objetivo |
|---|---:|
| ALTIUS D8/D11 | 1 |
| HIDRA-TPR50 SPM | 10 |
| CTA SR8P SPH | 1 |
| EM2000 | 3 |
| EM4000 V1 | 7 |
| EDEL-K3 | 1 |
| TOKIBAT DL27 | 1 |
| ENIER MXL1 LED 12/19 | >20; la divisoria MXL1 aparece en 3 |
| Thyssen Serie E L9/L8/L7 | 6 |

Problemas concretos:

- `EM4000` no se equipara de forma robusta con `EM 4000`.
- La señal de la página divisoria no se transmite a la página de respuesta.
- El aumento global de resultados introduciría más placas hermanas y elevaría el riesgo de mezcla. Debe usarse para descubrir candidatos y después reducirse a evidencia validada, nunca para enviar veinte chunks al generador.

### 3.3 Selección determinista

`Rag::AmbiguousModelResponder`:

- recupera 20 chunks;
- obtiene una etiqueta desde el encabezado o metadata;
- toma los primeros tres modelos distintos;
- no comprueba coincidencia del identificador ni de la relación solicitada.

Esto explica la selección `SMART 001`, `MR08`, `MICONIC LX` para SPM, aunque ninguno de esos tres chunks contiene SPM.

### 3.4 Generación y seguridad

- `AnswerSafetyProcessor` evita varias invenciones de estado, pero no puede compensar una selección incorrecta.
- El guard corre en un solo punto (`bedrock_rag_service.rb:342`). Las rutas deterministas —incluida la tarjeta de desambiguación— no lo atraviesan.
- No conviene seguir agregando regex que “sepan” respuestas técnicas. La verdad debe vivir en evidencia recuperada/estructurada.
- El modelo existente puede redactar una respuesta una vez que la evidencia sea correcta; no debe elegir libremente entre placas mezcladas.

### 3.5 Presentación web

- Producción tiene `SHOW_RAG_SOURCES=false`.
- Las opciones ambiguas se muestran como tres botones con solo una etiqueta.
- El frontend limita nuevamente la lista a tres.
- Aunque existe soporte para `matched_excerpt`, la selección ambigua no entrega una tarjeta que explique por qué cada opción responde la pregunta.

## 4. Arquitectura objetivo

Flujo propuesto:

```text
pregunta
  → extraer fabricante/modelo/placa/identificadores/relación solicitada
  → resolver alcance estructural
  → recuperar candidatos amplios
  → exigir evidencia que contenga el identificador y responda la relación
  → agrupar por contexto técnico
  → 1 contexto: respuesta directa
  → varios contextos: tarjetas de evidencia y selección
  → 0 contextos: pedir el dato faltante, sin declarar una ausencia global
```

### Contrato mínimo de evidencia

Cada candidato debe transportar:

- `document_id`
- `page_number`
- `section_id`
- `section_path`, de específico a general
- `manufacturer`
- `controller_model`
- `board_model`
- `identifiers`
- `evidence_excerpt`
- `source_uri`
- `evidence_target` para abrir página/pasaje

En Bedrock, los campos usados por filtros deben mantenerse escalares y normalizados. La ruta y los identificadores pueden conservarse además en el contenido estructurado para validación.

## 5. Plan de implementación por fases

### Fase 0 — Congelar el baseline

1. Usar la batería ya versionada
   `script/fixtures/rag_seguridades_pilot_10q_v2.json`
   (`seguridades-pilot-v2.0`) como tercera cohorte. No crear un fixture
   duplicado.
2. Guardar el rastro sanitizado de producción de 2026-07-29.
3. Medir por separado:
   - completitud del chunk;
   - `recall@3`, `recall@10`, `recall@20` y MRR;
   - precisión de las opciones ambiguas;
   - fidelidad de la respuesta a la evidencia;
   - abstención ante estados no documentados;
   - latencia y costo.
4. Registrar commit, ID del documento, versión de contrato y configuración de recuperación en cada corrida.
5. Antes de la primera corrida, recalibrar el patrón penalizado «inventa conectores CN7/CN8/CN9» del caso `em4000_obstaculo_conectores` (v2.0 → v2.1): CN7/CN8/CN9 están documentados en el PDF para EM2000 («OBSTACULO .- CONECTORES CN7 Y CN8 EN PLACA EM2000»), por lo que una respuesta correcta contrastiva que mencione CN7/CN8 cerca de «obstáculo» dispararía el patrón como invención crítica. Aplicar la disciplina ya establecida (precedente `em3000_fotocelula_tension`, v1.1→v1.2): solo el patrón, nunca quitar el check, controles negativos bloqueados en test offline («EM4000 usa los conectores CN7 y CN8» debe seguir disparando; «en EM2000 son CN7/CN8; en EM4000 V1, XC4/XC7» no debe disparar).
6. Selección de cohorte: `RAG_SEGURIDADES_RUBRIC=script/fixtures/rag_seguridades_pilot_10q_v2.json` sobre `script/rag_seguridades_benchmark.rb` y `script/evaluate_rag_seguridades_benchmark.rb` (sin la variable, el runner usa la rúbrica v3.2 por defecto). Ver `docs/RAG_SEGURIDADES_BENCHMARK.md`.
7. El criterio del gate es por caso: 10/10 `passed` en cinco corridas consecutivas. El campo `passing_score: 24/30` del fixture es un umbral heredado de v1.x y no sustituye al criterio por caso.

**Salida:** benchmark reproducible que identifica en qué capa falla cada pregunta.

#### Política de rúbricas acumulativas

Mantener tres gates separados:

1. `rag_seguridades_rubric.json` (`seguridades-v3.2`, 12 casos): regresión
   técnica base.
2. `rag_seguridades_pilot_10q.json` (`seguridades-pilot-v1.2`, 10 casos):
   cohorte piloto ya certificada.
3. `rag_seguridades_pilot_10q_v2.json` (`seguridades-pilot-v2.0`, 10 casos):
   nueva cohorte de generalización descrita en este plan.

Reglas:

- no modificar v3.2 ni v1.2 para acomodar una implementación nueva;
- una corrección de ground truth exige nueva versión, evidencia del PDF,
  changelog y controles negativos;
- ejecutar las tres cohortes ante cada cambio de retrieval, parsing, guardrails
  o generación;
- v3.2 y v1.2 nunca pueden retroceder respecto de su baseline certificado;
- v2.0 se convierte en regresión estable cuando alcance los gates y sea
  certificada;
- si el código se calibra usando todos los casos v2.0, crear una futura cohorte
  no vista para volver a medir generalización;
- no resolver un fallo agregando conocimiento de la pregunta al código
  productivo.

No fusionar las tres rúbricas en un único puntaje: reportar por cohorte permite
distinguir estabilidad histórica de generalización real.

### Fase 0.5 — Auditar y contener la lógica basada en regex

**Ejecutada el 2026-07-29. Resultado completo en
[RAG_REGEX_AUDIT_FASE05_2026-07-29.md](RAG_REGEX_AUDIT_FASE05_2026-07-29.md)** —
inventario `keep/consolidate/retire` de los 116 patrones, contrato de
`Rag::QueryAnalysis`, orden de migración y hallazgos empíricos H1–H5. Esta sección
queda corregida con esas mediciones; el documento de auditoría es la fuente.

La medición con `Ripper` (2026-07-29, commit `7c5e954`) encontró **98** literales
regex en el núcleo estricto (`app/services/rag/*`, `bedrock_rag_service.rb`,
`rag_retrieval_profile.rb`) y **116** incluyendo la periferia de formato
(`app/services/bedrock/*`, `rag_query_concern.rb`). La cantidad no constituye por sí
sola un defecto: 68 parsean protocolos, rutas, citas, unidades o Markdown de forma
apropiada, y 18 de los 98 pertenecen al canal WhatsApp dormante. El núcleo activo
del canal web son 80 patrones, y el riesgo se concentra en los 5 que representan
identidad de equipo o relaciones técnicas concretas.

Hallazgos que obligan a refactorizar:

1. `AnswerSafetyProcessor::IDENTIFIER_PATTERN` enumera familias sintácticas y deja
   sin cobertura **14 de los 25 identificadores reales del manual**, en dos
   familias: códigos de sólo letras (`SPM`, `SPH`, `SEG`, `SCE`, `SCC`, `SSH`,
   `AP`, `SPE`, `PP`) y códigos numéricos desnudos (`37/39/41` de EDEL-K3,
   `12/19` de ENIER MXL1). El efecto no es que la afirmación quede fuera de una
   validación parcial: `requires_evidence?` devuelve `false` para una respuesta
   como `SPM: SERIE PUERTAS CABINA - EXTERIORES.`, así que la atribución **no se
   valida en absoluto** y una invención atraviesa el guard intacta.
2. `DEVICE_FUNCTION_CLAIM_PATTERN` codifica específicamente la relación
   limitador/sobrecarga. Es una protección útil, pero no generaliza a la próxima
   función técnica inventada.
3. La intención se clasifica en **tres** puntos activos: `Rag::DeterministicIntent`
   (renderer y disparo de tarjeta), `RagRetrievalProfile` (única fuente de `top_k`
   y reranking) y directivas de prompt inline en `BedrockRagService`
   (`:914-915`, `:991`). `QueryOrchestratorService#classify_query_intent` **no
   cuenta**: está apagado por contrato de gate (`QUERY_ROUTING_ENABLED=false` en
   `config/deploy.yml:58`, exigido por `gate9_v1_validation.rb:176`). Los dos
   costes reales, medidos: `RagRetrievalProfile` se instancia dos veces por
   request generativo con argumentos distintos (`bedrock_rag_service.rb:114` y
   `:1023`), y el patrón safety de `:991` usa el literal `fuera de servicio`
   mientras `rag_retrieval_profile.rb:53` usa `fuera\s+de\s+servicio` — con doble
   espacio o salto de línea la consulta recibe el `top_k` reducido de
   safety-critical **sin** la directiva STOP-WORK. `top_k`, en cambio, tiene una
   sola fuente.
4. `EXPLICIT_EQUIPMENT_PATTERN` contiene una lista manual de 8 fabricantes, de los
   cuales **sólo 2 aparecen en SEGURIDADES**: CTA, Elecmegon, ENIER y TOKIBAT no
   están. La cohorte v2 rutea bien por una razón incidental —en 6 de 9 casos el
   patrón matchea por el código alfanumérico que el técnico escribió, no por el
   modelo; en `tokibat_dl27_v2` matchea por `DL27`, no por «TOKIBAT 2007»—. De 11
   reformulaciones realistas que sí nombran el equipo, **8 se rutean a la tarjeta
   de desambiguación**, que es el bucle que `69cd585` atacó por el lado del
   síntoma. Es el riesgo de generalización más grande del gate.
5. `AmbiguousModelResponder` vuelve a inferir el modelo mediante regex sobre un
   encabezado textual, aunque esa identidad debería provenir de metadata
   estructurada.
6. El historial de Git demuestra crecimiento reactivo: el guard se creó el
   2026-07-26 (`f0be176`) y se modificó el 2026-07-28 (`4a66b01`) motivado por los
   casos ALTIUS, EDEL-K2 y MR08; el desambiguador se creó el 2026-07-26 y se
   modificó el 2026-07-29 para elevar `top_k` y volver a interpretar encabezados.
   Precisión verificada: esos ajustes se implementaron como reglas genéricas
   (`board_model_name?`, `SERIES_LABEL_PATTERN`), no como excepciones literales por
   fabricante — los nombres sólo aparecen en comentarios. El riesgo es el patrón de
   crecimiento caso-a-caso, no excepciones hardcodeadas existentes.
7. Las rutas deterministas **no atraviesan `AnswerSafetyProcessor`**: el guard se
   invoca en un único punto (`bedrock_rag_service.rb:342`, dentro de
   `BedrockRagService#query`) y `AmbiguousModelResponder`, `DeterministicRenderer` y
   `DocumentOverviewResponder` retornan antes en el orquestador. Para los renderers
   es defendible (texto verbatim del ledger); para el desambiguador no, porque sus
   etiquetas provienen de `MODEL_PATTERN` o de un encabezado reinterpretado por
   regex y llegan al técnico como opciones accionables sin validar contra evidencia.

Refactor recomendado, sin reescritura abrupta:

1. Crear tests de caracterización de cada regex activa antes de moverla. Ya existían
   75 tests sobre los cinco archivos calientes, así que el trabajo fue cubrir los
   huecos, no reescribir de cero. **Hecho (2026-07-29, paso P0):**
   `test/services/rag/regex_characterization_test.rb`, 24 tests / 172 aserciones en
   verde, validados por mutación sobre el código productivo. Los tests marcados
   `DEUDA` fijan a propósito el comportamiento incorrecto medido y su expectativa
   solo se invierte en el paso que introduce el sustituto (P2/P3/P4).
2. Clasificar cada patrón:
   - **conservar:** protocolo, formato, URI, cita, unidades y normalización;
   - **centralizar:** tokens, identificadores, variantes y clasificación de
     intención;
   - **retirar gradualmente:** fabricante/modelo hardcodeado y relaciones
     técnicas específicas.
3. Crear un único `Rag::QueryAnalysis`, calculado una vez, con:
   `intents`, `manufacturer`, `model`, `board`, `identifiers`,
   `requested_relation` y `confidence`.
4. Hacer que recuperación, renderer y prompt consuman ese objeto en vez de
   ejecutar clasificadores independientes.
5. Obtener fabricante/modelo desde metadata y alias de los documentos
   seleccionados; la regex queda solo como fallback de baja confianza.
   **No ejecutable en Fase 0.5:** su precondición es metadata de sección confiable,
   y hoy los sidecars de SEGURIDADES aplanan el manual al `canonical_name` de
   ALJO/ALTIUS (§1.3). Retirar ahora `EXPLICIT_EQUIPMENT_PATTERN`, `MODEL_PATTERN` y
   `board_model_name?` sustituiría una heurística mala por una metadata peor. Fase
   0.5 los marca y los congela; se retiran en **Fase 2** (paso P4 de la auditoría),
   después del backfill y con los tres gates verdes.
6. Sustituir la validación semántica por comparación de hechos tipados
   `componente + relación + valor + evidencia`, manteniendo temporalmente el
   guard actual como defensa en profundidad.
7. Añadir pruebas de generalización con fabricantes y códigos ficticios que no
   existían cuando se escribieron las reglas. Aprobar solo si funcionan sin
   agregar nuevas ramas al código productivo.

**Salida:** inventario con decisión `keep/consolidate/retire` por patrón, un
clasificador único y una regla de arquitectura: ningún nuevo caso del benchmark
puede solucionarse agregando conocimiento de una placa al código productivo.

**Entregada** en [RAG_REGEX_AUDIT_FASE05_2026-07-29.md](RAG_REGEX_AUDIT_FASE05_2026-07-29.md):
68 `keep` / 43 `consolidate` / 5 `retire`; contrato de `Rag::QueryAnalysis` con
identidad de equipo como hipótesis con confianza y validación de identificadores
contra el vocabulario de la evidencia (mundo cerrado) en vez de contra una lista de
familias sintácticas; regla de arquitectura con guardián ejecutable
(`test/architecture/no_hardcoded_equipment_test.rb`, allowlist que sólo puede
decrecer); migración en 7 pasos P0–P6. Implementación y tests: fases siguientes.

### Fase 1 — Corregir la selección sin reingesta completa

1. Crear un único objeto inmutable `Rag::QueryAnalysis` y construirlo exclusivamente mediante el extractor `Rag::QueryEntities`, con:
   - fabricante;
   - modelo/placa;
   - códigos exactos como `D8`, `SPM`, `XC4`, `DL27`, `L9`;
   - relación pedida: indica, pertenece, conector, estado, condición.
   - `requested_relation` como `Set<Symbol>` para resolver o abstener cada relación por separado.
2. Normalizar variantes para comparar, nunca para mostrar, separando `model_key` de `variant`:
   - espacios y guiones (`EM4000` ↔ `EM 4000`, `TPR50` ↔ `TPR-50`);
   - mayúsculas y tildes;
   - conservar el código técnico exacto.
   - no fusionar `CN7/CN8/CN9`, `EDEL-K2/EDEL-K3`, `CN-112.SC` ni el sufijo `V1` de `EM4000 V1`.
3. Sustituir la selección por “primeros tres encabezados” con un selector de evidencia:
   - el chunk debe coincidir con el código consultado, salvo preguntas inversas como “qué LED…”;
   - debe contener una frase/registro que responda la relación;
   - debe respetar fabricante/modelo cuando se proporcionan;
   - debe excluir coincidencias presentes solo en metadata o alias globales;
   - debe agrupar placas hermanas sin mezclarlas.
   - debe tener una rama inversa explícita para preguntas «qué LED…», que constituyen la mitad de la cohorte.
4. Si hay una divisoria de alta relevancia, expandir únicamente a sus páginas vecinas vinculadas dentro de la misma sección: `section_identity` es el vínculo durable y la página contigua es solo un mecanismo interino medido.
5. Mantener una llamada `Retrieve`; usar 20 resultados para descubrimiento y entregar como máximo 5 contextos validados al generador.

**Salida:** SPM no puede ofrecer SMART/MR08/MICONIC; MXL1 puede unir divisoria y página 36; EM4000 reconoce la variante compacta.

### Fase 2 — Reparar identidad estructural del documento

1. Generar un manifiesto de auditoría, sin escribir, que compare cada chunk con:
   - encabezado visible;
   - página;
   - fabricante/modelo/placa;
   - sección padre;
   - página anterior/siguiente de la misma sección.
2. Corregir la generación de sidecars para documentos futuros mediante la propagación jerárquica ya prevista en el contrato nuevo.
3. Preparar para SEGURIDADES un backfill **solo de `section_identity`**, basado en encabezados verificables, con diff revisable; no inventar claves `manufacturer`, `controller_model` o `board_model` que el contrato no produce.
4. Conservar `canonical_name` en los 97 sidecars porque identifica el documento y sostiene la atribución; validar que `section_identity` sea específico para cada sección.
5. Guardar copia y hash de los sidecars antes de cualquier publicación.

**Salida:** la sección/marca deja de depender de heurísticas sobre el cuerpo. La placa sigue derivándose del cuerpo y de la normalización del selector.

**Límite:** no ejecutar sincronización del Knowledge Base ni modificar S3 sin autorización explícita del usuario.

### Fase 3 — Respuesta directa y ambigüedad útil

Definir un payload independiente del texto libre:

```json
{
  "resolution": {
    "contract_version": "resolution_v1",
    "mode": "direct|ambiguous|insufficient|not_applicable",
    "needs_selection": false,
    "answered_relations": [],
    "abstained_relations": [],
    "insufficient_reason": null,
    "facts": [],
    "evidence_cards": []
  }
}
```

#### Caso directo

Mostrar primero la respuesta:

> LED SPM: **SERIE PUERTAS CABINA - EXTERIORES**.

Una frase cordial breve puede cerrar: “Si quieres, reviso otra señal de esta placa.”

Con `SHOW_RAG_SOURCES=true`, agregar después:

> Carlos Silva › HIDRA-TPR50 · p. 9 · Ver evidencia

#### Caso ambiguo

Mostrar:

> Encontré varios contextos documentados. Elige la placa para darte la respuesta exacta.

Cada tarjeta debe contener:

1. el hecho o extracto que responde la consulta;
2. breadcrumb específico → general;
3. acción primaria “Usar esta placa”.

Solo con `SHOW_RAG_SOURCES=true`, agregar:

4. página;
5. acción “Ver en el documento”.

Ejemplo:

```text
AP — SERIE OBSTÁCULO
“AP: Serie obstáculo”
EM2000 eléctrico › Elecmegon › SEGURIDADES 1.1-1 · p. 31
[Usar esta placa] [Ver evidencia]
```

No mostrar una opción si su extracto no responde la pregunta. No generar relaciones entre componentes de contextos distintos. Si el documento no relaciona dos LEDs, decirlo.

#### Condiciones de terreno

- La respuesta y el extracto deben estar disponibles dentro de la burbuja: el técnico no debe depender del enlace.
- Objetivos táctiles de al menos 44 px.
- Texto breve, alto contraste y jerarquía visual estable.
- Carga progresiva: respuesta primero; fuente expandible únicamente cuando el
  feature flag esté activo.
- Si falla la navegación o conexión, el extracto conserva la información esencial.
- En móvil, máximo tres tarjetas visibles inicialmente y “Ver más contextos”; el backend no debe descartar candidatos válidos por ese límite visual.
- Dos grupos documentados distintos ya constituyen ambigüedad; el umbral no es tres.
- Durante `resolution_v1`, `quick_replies` se deriva de las primeras tres tarjetas y se mantiene para clientes antiguos, sin duplicar botones en el renderer nuevo.

#### Separar visibilidad, transporte y auditoría

`SHOW_RAG_SOURCES` debe seguir siendo una decisión exclusiva de presentación:

- `false`: sin marcadores `[n]`, bloque de fuentes, página ni enlace de evidencia;
- `true`: habilita citas, página y navegación para QA/auditoría;
- en ambos casos, la selección y validación de evidencia se ejecutan igual.

El flag tiene un solo lector server-side, `Rag::SourcesVisibility.enabled?`, cuyo
resultado consumen el controlador y la vista. El frontend no vuelve a leer `ENV`.
El contenido completo del chunk no se transporta en ningún estado: cuando las
fuentes están visibles, las citas llevan únicamente `tooltip_excerpt` acotado.

La evidencia breve de una tarjeta ambigua no se considera un bloque de citas:
es el contenido mínimo necesario para que el técnico pueda elegir el modelo
correcto. No debe convertirse en una lista adicional de fuentes.

Situación actual a corregir:

- con el flag apagado, el frontend oculta las citas, pero el controlador envía siempre el arreglo completo al navegador (`rag_controller.rb:74-91`), incluyendo el `content` íntegro de cada chunk (`bedrock/citation_processor.rb:87-96`); las tarjetas ambiguas viajan con el mismo shape. El flag solo se lee en `app/views/home/index.html.erb:21`;
- la ruta generativa escribe en `[RAG_QUALITY]` conteos, títulos, documentos y
  URIs observadas, pero no persiste una traza de evidencia completa en
  `bedrock_queries`;
- las rutas deterministas `Retrieve` registran conteo/latencia, pero no la misma
  atribución de cita;
- un log de contenedor sin una política confirmada de retención no constituye
  por sí solo un registro auditable.

Implementación propuesta:

1. Construir siempre la evidencia internamente.
2. Emitir un evento `evidence_selection` mediante `PilotUsageLog` tanto para
   rutas generativas como deterministas, sin modificar `[RAG_QUALITY]`. Un
   `Retrieve` puro no debe crear una invocación ficticia en `bedrock_queries`.
3. Registrar solo lo necesario:
   - `account_id`, usuario/sesión y `correlation_id`;
   - `generation_mode`;
   - URI/ID de documento;
   - página;
   - `chunk_sha256`;
   - extracto acotado y su hash;
   - hash de pregunta/respuesta o vínculo a su registro autorizado;
   - timestamp, versión del selector y `expansion_mechanism`;
   - `resolution_mode`, relaciones respondidas/abstenidas, razón insuficiente,
     grupos entregados y razones de rechazo.
4. Incluir esos eventos en el exportador diario del piloto y conservar el
   artefacto de métricas según una retención explícita. No crear durante el MVP
   una tabla de historial, un repositorio de documentos duplicados ni un
   subsistema genérico de gestión de evidencia.
5. No enviar `content` completo en ningún estado. Con fuentes visibles, transportar
   solo `tooltip_excerpt` de hasta 150 caracteres. Con el flag apagado, limpiar en
   el backend únicamente los marcadores `[n]` que resuelven a una cita y hacerlo
   antes de vaciar el arreglo, preservando números técnicos literales como `[24]`.
6. Probar que activar/desactivar el flag no cambia retrieval, selección,
   generación, guardrails ni la telemetría exportada.

#### Alinear la telemetría con el valor comercial del piloto

Reutilizar el contrato ya definido en `PRODUCT_ROADMAP.md` y `METRICS.md`. El
reporte debe separar cuatro grupos para evitar convertir actividad técnica en
supuestos comerciales:

1. **Calidad y confianza**
   - precisión de benchmarks y muestras auditadas por humanos;
   - tasa de respuestas con evidencia;
   - invenciones críticas;
   - `DATA_NOT_AVAILABLE` y verificación en campo;
   - tasa de reformulación rápida;
   - preguntas directas, ambiguas e insuficientes;
   - relevancia y selección de opciones de desambiguación.
2. **Adopción**
   - usuarios y cuentas activos;
   - sesiones, preguntas y fotos;
   - técnicos que regresan;
   - preguntas por sesión;
   - continuidad foto → consulta de manual.
3. **Operación y economía**
   - éxito/fallo;
   - latencia p50/p95;
   - costo real reconciliado;
   - costo por consulta y, cuando exista confirmación, por resolución;
   - llamadas deterministas/LLM y llamadas evitadas por caché.
4. **Resultados comerciales, obtenidos mediante encuesta**
   - tiempo de resolución;
   - resolución en la primera interacción;
   - escalamiento o revisita evitados;
   - cambio de confianza;
   - utilidad percibida.

La presencia de una cita no demuestra que una respuesta sea correcta, y los
tokens no demuestran ahorro de tiempo. Los resultados del cuarto grupo deben
permanecer como `REQUIRES_MANUAL_SURVEY` cuando no exista una respuesta del
técnico o supervisor.

Métricas defendibles para un pitch posterior:

- porcentaje de consultas resueltas en la primera interacción;
- reducción mediana del tiempo de búsqueda/resolución;
- porcentaje de respuestas verificadas sin invención crítica;
- porcentaje de consultas respaldadas por evidencia;
- reducción de escalaciones/revisitas reportada;
- cambio de confianza y utilidad percibida;
- costo y latencia por resolución confirmada;
- adopción y repetición de uso por técnico.

No presentar estos indicadores si la muestra, el período o el método de
medición no están registrados en el mismo reporte.

### Fase 4 — Patrón NotebookLM adaptado

NotebookLM aporta tres principios aplicables:

1. Respuestas fundamentadas en las fuentes seleccionadas y citas en línea claras.
2. Vista previa inmediata del texto citado.
3. Al pulsar la cita, navegación al lugar exacto del pasaje.

Danebo debe adoptar esos principios, pero adaptarlos al técnico de terreno:

- evidencia asociada internamente a cada afirmación técnica;
- cita visible y deep link solo en modo de fuentes/auditoría;
- evidencia mínima visible en una tarjeta compacta únicamente para resolver
  ambigüedad;
- selección de placa/modelo equivalente a limitar las fuentes;
- no reproducir la densidad de una interfaz de investigación de escritorio.

Referencias oficiales:

- [Google: Use chat in NotebookLM](https://support.google.com/notebooklm/answer/16179559?hl=en)
- [Google: Learn about NotebookLM](https://support.google.com/notebooklm/answer/16164461?hl=en)
- [Google: Add or discover sources](https://support.google.com/notebooklm/answer/16215270?co=GENIE.Platform%3DDesktop&hl=en-GB)

### Fase 5 — Decisión sobre un LLM adicional

**Decisión recomendada:** no agregar un LLM para encontrar o inventar la verdad en cada consulta.

Orden de preferencia:

1. identificadores y metadata estructurada;
2. selector determinista de evidencia;
3. render determinista para respuestas de tabla;
4. modelo actual solo para sintetizar evidencia ya validada.

Un Haiku económico puede evaluarse únicamente como fallback de extracción de intención cuando el parser tenga baja confianza. Su salida debe ser JSON cerrado —fabricante, modelo, códigos y relación— y no una respuesta técnica. Debe fallar de forma segura y no agregar una segunda llamada en las preguntas exactas de la batería.

Para documentos futuros, sí puede usarse el LLM de ingesta para producir hechos genéricos y jerarquía, siempre con:

- cita textual obligatoria;
- página obligatoria;
- validación de que cada valor aparece en el texto fuente;
- rechazo de condiciones o inferencias ausentes;
- auditoría humana por muestra.

No crear schemas por fabricante/página. Usar un registro genérico:

```text
componente + relación + valor + contexto + página + evidencia
```

Solo si las fases 1–3 no alcanzan los gates se evaluará materializar estos hechos en PostgreSQL como índice estructurado. Así se evita introducir una tabla nueva antes de demostrar que es necesaria.

### Fase 6 — Pruebas

#### Backend

- Minitest para las diez preguntas y sus negativas.
- El selector no ofrece un candidato sin evidencia que responda.
- El filtro de fabricante excluye familias ajenas.
- `EDEL-K2` no contamina `EDEL-K3`.
- `EM2000` no usa `SPE` de EM3000.
- `TPR50` no usa `PP` de TPR60.
- `DL27`, Thyssen y ALTIUS se abstienen de estados no documentados.
- EM4000 no inventa `CN7/CN8/CN9`.
- La expansión vecinal nunca cruza de sección/modelo.
- `SPM` y los identificadores numéricos desnudos (`37/39/41`, `12/19`) disparan la
  exigencia de evidencia: `requires_evidence?` debe ser `true` para ellos.
- `fuera  de  servicio` con doble espacio o salto de línea activa la directiva
  STOP-WORK y el perfil safety-critical simultáneamente (regresión de la divergencia
  `bedrock_rag_service.rb:991` vs `rag_retrieval_profile.rb:53`).
- Una pregunta que nombra el modelo sin escribir el código del LED
  («En TOKIBAT 2007, ¿qué LED indica las puertas de cabina?») **no** se rutea a la
  tarjeta de desambiguación.

#### Frontend

- Tarjetas con extracto, breadcrumb, página y dos acciones.
- El límite visual no elimina candidatos del payload.
- Navegación a evidencia exacta.
- Pruebas a 320, 375 y 430 px.
- Accesibilidad por teclado, lector de pantalla, foco y contraste.

#### Producción en sombra

- Cinco corridas de `Retrieve` por pregunta para observar estabilidad.
- Sin invocar generación durante el diagnóstico de recuperación.
- Después, una corrida end-to-end controlada por caso.

## 6. Gates de aceptación

No liberar a piloto hasta cumplir simultáneamente:

- **10/10** respuestas/veredictos correctos en cinco corridas consecutivas.
- **0** invenciones críticas: estados ON/OFF, conectores, modelo o relación.
- **9/9** casos directos con evidencia correcta en top 3 después de resolver estructura.
- **100%** de opciones ambiguas respaldadas por un extracto que responde la consulta.
- **100%** de afirmaciones técnicas asociadas a una traza persistida con
  documento, página y chunk; la navegación visible se prueba con el flag activo.
- El flag apagado no muestra ni transporta citas completas al cliente y no
  modifica el resultado técnico.
- Ninguna respuesta de ausencia cuando el dato existe en un chunk candidato.
- Latencia p95 sin regresión mayor al 15% respecto del baseline.
- Costo medio sin segunda llamada LLM en consultas directas.
- Pruebas Rails y frontend completas en verde.
- Aprobación humana de las diez respuestas contra el PDF renderizado.

## 7. Despliegue y reversión

1. Implementar detrás de feature flags separadas:
   - selector de evidencia;
   - expansión vecinal;
   - tarjetas UX;
   - metadata v2.
2. Activar primero para el documento SEGURIDADES y cuenta objetivo.
3. Ejecutar benchmark en sombra.
4. Publicar metadata/sincronizar KB solo después de aprobación explícita.
5. Mantener respaldo versionado de sidecars y un procedimiento para restaurarlos y resincronizar.
6. No hacer reingesta completa del PDF salvo que una auditoría demuestre pérdida en el cuerpo de los chunks; hoy no existe esa evidencia.

## 8. Archivos probablemente afectados

- `app/services/rag/ambiguous_model_responder.rb`
- `app/services/rag/query_entities.rb` — extractor único que construye `Rag::QueryAnalysis`
- nuevo `app/services/rag/evidence_candidate_selector.rb`
- `app/services/rag/deterministic_intent.rb` — hogar de `EXPLICIT_EQUIPMENT_PATTERN` y de la clasificación de renderer
- `app/services/rag/answer_safety_processor.rb` — hogar de `IDENTIFIER_PATTERN` y `DEVICE_FUNCTION_CLAIM_PATTERN`
- `app/services/query_orchestrator_service.rb` — cascada real de enrutamiento determinista
- `app/services/rag/deterministic_renderer.rb` — consumidor de `DeterministicIntent`
- `app/services/bedrock_rag_service.rb`
- `app/services/bedrock/citation_processor.rb` — punto donde se inyectaba `content` en las citas
- `app/services/rag_retrieval_profile.rb`, solo si los benchmarks justifican un cambio adaptativo
- `app/prompts/batch_chunking_prompt.rb`
- `app/services/chunk_merger_service.rb`
- `app/services/batch_results_parser_service.rb`
- `app/controllers/rag_controller.rb`
- `app/views/home/index.html.erb` — lector server-side de `SHOW_RAG_SOURCES`
- `app/javascript/controllers/rag_chat_controller.js`
- `app/javascript/rag/answer_presenter.js`
- `app/javascript/rag/sources_renderer.js` o un nuevo renderer de tarjetas
- locales `config/locales/rag.*.yml`
- tests unitarios, integración y sistema correspondientes
- script de benchmark SEGURIDADES v2

La IA ejecutora debe confirmar el alcance exacto después de leer los `AGENTS.md` aplicables. Esta lista no autoriza cambios innecesarios.

## 9. Acciones expresamente descartadas

- No ampliar `top_k` globalmente.
- No crear una clase o regex por página/modelo.
- No usar un LLM barato como selector libre sobre chunks mezclados.
- No responder una condición normal/fallo sin evidencia.
- No ocultar toda la evidencia en un enlace.
- No mezclar hechos de modelos distintos para construir una explicación.
- No reingerir todo el documento ni escribir en S3/KB sin aprobación.

## 10. Handoff a la IA revisora

Prompt sugerido:

> Revisa, sin editar código ni producción, `docs/RAG_PRECISION_V2_PLAN_2026-07-29.md` y `docs/RAG_PRODUCTION_TRACE_2026-07-29.md`. Contrasta el diagnóstico con el PDF, los chunks descargados y el código actual. Evalúa por separado ingesta, retrieval, selección, generación, seguridad y UX. Busca especialmente: inferencias no demostradas, gates insuficientes, riesgos de mezcla de modelos, costo/latencia, y cualquier cambio que implique una reingesta innecesaria. Devuelve: (1) aprobado/rechazado, (2) hallazgos por severidad, (3) cambios obligatorios al plan, (4) orden de ejecución recomendado. No implementes.

## 11. Handoff a la tercera IA ejecutora

Usar solo después de que el usuario acepte la revisión:

> Implementa el plan aprobado de precisión RAG SEGURIDADES v2, por fases y con Minitest. Empieza reproduciendo el baseline. Corrige primero selección de evidencia y estructura; no agregues reglas técnicas por página. Mantén las llamadas externas fuera del request cuando corresponda y mide costo/latencia. Usa Kamal en producción solo para verificaciones lectoras. Detente antes de toda escritura en S3, sincronización del Knowledge Base, cambio de feature flag en producción o despliegue, y solicita autorización explícita. Entrega resultados por gate y los diffs mínimos.

## 12. Asignación de modelos por fase

Regla general: **Opus** decide contratos e interfaces; **Sonnet** implementa contra especificación cerrada; **Haiku** solo tareas sin ambigüedad técnica. Todo cambio que escriba en PROD/S3/KB requiere autorización humana explícita, independientemente del modelo.

| Fase | Tarea | Modelo | Justificación |
|---|---|---|---|
| 0 | Correr benchmarks, registrar métricas/commits | Sonnet | Ejecución pautada de scripts; toca PROD en modo lectura → no Haiku |
| 0 | Recalibrar patrón CN (fixture v2.0→v2.1) + controles negativos | Sonnet | Disciplina ya establecida (precedente em3000); requiere validación empírica del patrón |
| 0.5 | Inventario regex keep/consolidate/retire + diseño de `Rag::QueryAnalysis` | Opus | Decisión arquitectónica central; sus errores se propagan a todas las fases |
| 0.5 | Tests de caracterización de las regex existentes | Haiku/Sonnet | Mecánico: capturar el comportamiento actual sin juzgarlo |
| 1 | Diseño del selector de evidencia + extractor de entidades (API, reglas de agrupación) | Opus | Corazón técnico: define qué evidencia llega al generador; alto riesgo de mezcla de modelos |
| 1 | Implementación de normalización de variantes (`EM4000`↔`EM 4000`, `TPR50`↔`TPR-50`, `TOKIBAT 2007`↔`2.007`) | Sonnet | Código directo contra especificación cerrada |
| 2 | Manifiesto de auditoría de sidecars (solo lectura) | Sonnet | Script de comparación mecánico contra reglas dadas |
| 2 | Decisión de backfill de metadata + revisión del diff | Opus + humano | Escribe (previa autorización) sobre datos de PROD; difícil de revertir sin backup |
| 3 | Contrato del payload `resolution_mode` + política de telemetría/flag | Opus | Decisiones de contrato transversales (backend/frontend/auditoría) |
| 3 | Tarjetas UX, renderer, CSS, breadcrumbs | Sonnet | Implementación frontend con diseño ya especificado |
| 3 | Locales `rag.es.yml`/`rag.en.yml`, textos | Haiku | Copy mecánico |
| 4 | Adaptación del patrón NotebookLM | — | No es fase ejecutable separada; queda absorbida por el diseño de Fase 3 (Opus) |
| 5 | Decisión sobre LLM adicional | — | Ya decidida (no agregar). Si se evalúa el fallback Haiku de intención: diseño Opus, implementación Sonnet |
| 6 | Tests backend Minitest + frontend + accesibilidad | Sonnet | Volumen de pruebas con criterios explícitos; los casos negativos delicados los revisa quien diseñó (Opus) |
| 6 | Corridas en sombra en PROD | Sonnet | Operación Kamal solo-lectura, procedimiento pautado |
| 7 | Despliegue, flags en PROD, sync KB | Opus + autorización humana explícita | Acciones difícilmente reversibles; el plan ya exige detenerse y pedir permiso |
