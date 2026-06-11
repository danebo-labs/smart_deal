---
name: Cierre RAG 100% con FIELD_RECORD
version: 2026-06-10-v8.2
corpus_cohort: 2026-06-10-v2
status: VALIDADO INDEPENDIENTEMENTE 2026-06-10 — ACEPTADO PARA IMPLEMENTACION (cohorte v2)
implementation_blocked: false
paid_calls_blocked: solo via gates B-I en orden (sin generacion pagada antes de Gate E)
---

# Plan de cierre del benchmark RAG al 100% de fidelidad documental

> Este documento es autocontenido. Otra IA debe poder revisar el objetivo, el
> estado real del repositorio, las decisiones arquitectonicas, los riesgos y los
> gates sin depender de la conversacion que lo produjo.

## 1. Objetivo exacto

Lograr **100% de fidelidad documental en el corpus fijo del benchmark**:

- 16 consultas por corrida;
- 3 corridas certificables;
- 48/48 respuestas sin omisiones documentales ni afirmaciones no sustentadas;
- 6/6 respuestas exhaustivas con todas las unidades accion-resultado;
- 6/6 respuestas stop-work sin promover precauciones a detencion obligatoria;
- aislamiento estricto de fuentes;
- cero funciones inventadas para etiquetas visuales;
- autoridad de reparacion preservada;
- costo proyectado <= USD 7,50 por 1.000 consultas.

Esto es una certificacion de regresion para este corpus y configuracion, no una
certificacion universal de seguridad del producto, de todos los manuales ni de
cumplimiento normativo chileno.

## 2. Corpus canonico — cohorte v2 (2026-06-10)

La cohorte v1 (`danebo_fidelity_v2_22_paginas.pdf` `987ab388…` +
`IMG_20260609_121243.jpg` `0eb04508…`) queda **retirada**: el contenido del
manual es el mismo, pero los bytes fuente disponibles no conservan esos hashes.
Conforme a la regla de cohorte, esto se versiona como corpus nuevo
(`2026-06-10-v2` en `script/fixtures/rag_quality_benchmark_corpus.json`, que
conserva los hashes v1 bajo `retired_cohorts` como registro historico).

### Manual

- Archivo local fuente:
  `/Users/lahirisan/Desktop/manual web:chat/22 paginas.pdf`
  (el nombre local dice "22 paginas"; el PDF tiene **24 paginas A4** — por eso
  el key canonico no repite ese numero erroneo).
- S3 key canonico:
  `uploads/2026-06-10/manual_plataforma_tijera_24_paginas.pdf`
- SHA-256 de bytes fuente:
  `852f508da648aa7f06dcbaeb49a28ab714ae361d1591f9b4dadb3dd36652c064`
- Contenido verificado: plataforma tijera, 5 partes, controles tierra/plataforma,
  inspecciones, pruebas funcionales §2.4 (las 24 unidades), stop-work, autoridad
  de reparacion, esquema hidraulico §3.

### Imagen

- Archivo local fuente: `/Users/lahirisan/Desktop/pagina_16.png`
- S3 key canonico:
  `uploads/2026-06-10/pagina_16_esquema_hidraulico.png`
- SHA-256 de bytes fuente:
  `b9293866d4aa0b947b2c4aed5760963cbb9d3d351d44b57cc78dc04357bde3c5`
- Contiene identificadores como `FRRV1`, `P41`, `P42`, `ORF1` y `BRK`.
- No contiene una leyenda suficiente para asignarles funcion, valor o conexion.

**Procedencia de la imagen (cambio vs v1):** es un **PNG exportado de la pagina
16 del propio manual** (§3 "Esquema electrico hidraulico"), no una foto JPG de
celular como en v1. El caso `visual_fidelity:1` sigue siendo semanticamente
valido (mismas etiquetas, sin leyenda funcional), pero la cohorte v2 ya no
ejercita el patron "field photo movil"; documentar esto en cualquier conclusion
sobre fidelidad visual. Con 1.434.536 bytes queda bajo
`FieldPhotoDensityGate::LARGE_PHOTO_THRESHOLD` (1.500.000) → ruta Sonnet
`FieldPhotoPrompt` (`field_photo_v1`), igual que una foto normal.

Si los objetos subidos no conservan estos hashes, el benchmark deja de ser la
cohorte v2 y debe detenerse o versionarse como un corpus nuevo.

## 3. Configuracion canonica

**Alcance: solo DEV.** No tocar recursos de produccion.

- Query model:
  `us.anthropic.claude-haiku-4-5-20251001-v1:0`
- Region: `us-east-1`
- Bucket S3: `smart-deal-dev-kb`
- Knowledge Base: `QGVYLPTEGT`
- Data Source: `1ICX1LL7A5`
- Session: `mvp-shared`
- Channel: `shared`
- Retrieval: `HYBRID`
- Reranking: desactivado
- Query routing / Text-to-SQL: desactivado
- Temperatura generativa actual: `0.1`
- Maximo generativo actual: `3000`
- Exhaustive retrieval: `N=15`
- Safety retrieval actual: `N=5`

No cambiar modelo, KB, search type, reranking o presupuestos de retrieval sin
volver a planificar y repetir los preflights.

## 4. Estado real al redactar este plan

### Datos locales

La limpieza local fue ejecutada y verificada:

- `KbDocument`: 0
- `KbDocumentThumbnail`: 0
- `BulkUploadAsset`: 0
- `BulkUpload`: 0
- sesion `mvp-shared`: conservada, sin pins ni historial
- usuarios: conservados
- `BedrockQuery`: 501, conservadas
- `CostMetric`: 402, conservadas
- JSON temporales `tmp/rag_quality_benchmark*.json`: eliminados

### Estado AWS dev (actualizado 2026-06-10, tras la ingesta diagnostica)

- Manual: subido por chat web e ingestado el 2026-06-10 (63 chunks en
  `bulk_chunks/2026-06-10/852f508d…/`, `KbDocument` creado, sidecars con
  `original_source_uri` y `doc_sha256` canonicos, `ingestion_path=web_v1`).
- El objeto original `uploads/2026-06-10/manual_plataforma_tijera_24_paginas.pdf`
  fue borrado por error junto con la imagen; **restaurado** via `aws s3 cp`
  desde el archivo local y verificado round-trip (SHA == manifest). Restaurar
  el original no requiere re-parse: el `doc_sha256` de los chunks prueba que la
  ingesta uso esos mismos bytes.
- Imagen: **no ingestada** (sin creditos Anthropic). Pendiente via
  `script/ingest_benchmark_image.rb` (ver §12).
- `BulkUploadAsset`: 0 filas — el dedup no bloqueara re-ingestas.
- Sesion `mvp-shared`: 1 pin y 2 turnos de historial generados por la subida;
  se limpia y re-pinnea en Fase 3 paso 11.

### 4.1 Auditoria de la ingesta diagnostica del manual (2026-06-10)

La subida ocurrio **antes** de implementar Fase 1 (versionado de contrato) y
Fase 2 (evaluador de ingesta), fuera del orden del plan. Se audito manualmente
el output completo (equivale a una corrida manual de Fase 2) con este resultado:

**Inventario:** 63 chunks, 195 `FIELD_RECORD` (31 `FUNCTIONAL_TEST`,
5 `STOP_WORK_CONDITION`, 30 `SAFETY_WARNING`, 47 `SCHEMATIC_LABEL`, resto
inspeccion/instalacion/comisionado).

**Defectos encontrados (verificados contra el PDF fuente):**

- **D1 — paginas truncadas:** p3 (§2.1.1/§2.1.2 controles de tierra y
  controlador de plataforma) y p18 (§4 Especificaciones, tabla E80N–E160W)
  quedaron como placeholders `S0 - EXTRACCION PARCIAL` sin records. El
  placeholder es honesto (`REQUIRES_FIELD_VERIFICATION`), pero p3 alimenta los
  casos de componentes/controles del benchmark.
- **D2 — perdida de continuacion entre paginas:** la "Prueba de direccion"
  empieza al final de la p9 y continua al inicio de la p10. El chunk de p9
  termina honesto (`DATA_NOT_AVAILABLE — continua en pagina siguiente`), pero
  los chunks de p10 arrancan recien en "Prueba de funcion de conduccion y
  freno": se perdieron el resultado de direccion **izquierda** y el paso y
  resultado de direccion **derecha**. Resultado: `steering-right` sin record y
  `steering-left` sin resultado → **el gate 24/24 de Fase 2 FALLA**. Es la
  historica "omision de direccion derecha", ahora demostrada a nivel de
  ingesta (borde de pagina en parse paginado), no de generacion.
- **D3 — tipado dudoso:** la unidad `ground-diagnostic-led` (§2.4.1
  preparacion + LEDs de diagnostico) existe pero como `COMMISSIONING_STEP`,
  no `FUNCTIONAL_TEST`; el renderer exhaustivo (que filtra `FUNCTIONAL_TEST`)
  la omitiria. Decidir el tipo correcto en la revision del manifest (Fase 4) y
  alinear prompt de ingesta o seleccion del renderer.

**Veredicto:** ingesta diagnostica, **no certificable**. Antes de la reingesta
limpia (Fase 3) se requiere: (1) Fase 1 implementada; (2) fix del defecto de
continuacion inter-pagina (D2) y reintento/reparacion de paginas truncadas
(D1) en el pipeline de parse; (3) resolver D3. Los hallazgos D1–D3 validan el
diseño del gate de ingesta: el benchmark RAG no puede superar la fidelidad de
los chunks.

### Worktree

El worktree esta dirty. Las corridas diagnosticas pueden ejecutarse dirty, pero
las tres corridas certificables requieren:

- todos los cambios relevantes en un commit;
- `git_dirty=false`;
- la misma revision y fingerprint en las tres corridas.

### Observabilidad ya implementada

El runner `script/rag_quality_benchmark.rb` ya contiene:

- modos `retrieval_preflight`, `diagnostic` y `certification`;
- selector `RAG_BENCHMARK_TARGETS`;
- expansion de dependencias conversacionales;
- valores canonicos;
- SHA-256 de corpus;
- `resolved_scope_s3_uris`;
- `applied_filter_s3_uris`;
- configuracion vectorial y su hash;
- fingerprint de codigo, evaluador y manifests;
- rechazo de `git_dirty=true` en certificacion.

El evaluador `script/evaluate_rag_quality_benchmark.rb` ya valida:

- cohorte;
- matriz 16/16;
- ejecucion;
- aislamiento;
- fidelidad visual;
- reparacion;
- una primera gramatica exhaustiva y stop-work.

### Evidencia historica

`docs/RAG_QUALITY_BENCHMARK_EVIDENCE_2026-06-10.md` documenta que Retrieve
HYBRID N=15 contenia las 24 unidades funcionales requeridas antes de la
reingesta. Esa evidencia pertenece a la **cohorte v1** (bytes retirados).

Los hashes de chunks y el fixture
`script/fixtures/rag_quality_benchmark_atomic_rubric.json` son historicos de la
cohorte v1 (su `source_uri` apunta al PDF retirado). Tras reindexar la cohorte
v2 con `FIELD_RECORD`, no pueden considerarse evidencia canonica ni usarse como
rubrica de diagnostico: deben regenerarse desde los chunks v2 y revisarse contra
el PDF v2 (Fase 4).

## 5. Por que fallo el ultimo intento

Las tres corridas iniciales y cuatro diagnosticos posteriores demostraron:

1. Retrieve N=15 tenia la evidencia documental.
2. Haiku omitio unidades presentes en los chunks.
3. Haiku reasigno acciones entre controladores.
4. Invento resultados para pasos sin resultado propio.
5. Promovio inspecciones o precauciones a stop-work.
6. Endurecer solamente el prompt no produjo determinismo.

Ejemplos observados:

- omision de direccion derecha;
- omision completa de pruebas del controlador de tierra;
- mezcla entre pruebas de tierra y plataforma;
- resultado inventado al reactivar una parada de emergencia;
- detencion obligatoria inventada para defectos, fugas o personal no autorizado.

Por tanto, no se debe volver al supuesto:

> prompt mas estricto => lista completa y segura

## 6. Cambio arquitectonico nuevo

El prompt de ingesta manual ahora solicita `chunks[].field_records`.

Contrato compacto de Claude:

- `k`: tipo de registro;
- `h`: heading/figura/tabla visible;
- `a`: accion, comprobacion o etiqueta exacta;
- `r`: resultado exacto o `DATA_NOT_AVAILABLE`;
- `ev`: frase corta de evidencia;
- opcionales:
  `x` detalles, `sw` par stop-work, `ra` autoridad de reparacion,
  `u` incertidumbre.

`BatchResultsParserService`:

- rechaza manuales sin `field_records`;
- valida tipos y claves;
- exige ambos elementos de `sw`;
- genera un `RECORD_ID` determinista;
- expande cada registro a un bloque indexable:

```text
FIELD_RECORD:
RECORD_ID: FR-...
SOURCE_SECTION_OR_PAGE: ...
RECORD_TYPE: ...
ACTION: ...
EXPECTED_RESULT: ...
DETAILS: ...                    # opcional
STOP_WORK_TRIGGER: ...          # opcional, par completo
STOP_WORK_REQUIRED_ACTION: ...  # opcional, par completo
REPAIR_AUTHORITY: ...           # opcional
UNCERTAINTY: ...                # opcional
EVIDENCE: ...
END_FIELD_RECORD
```

El esquema compacto medido usa aproximadamente 73,4% menos tokens por registro
que la propuesta extensa de veinte campos.

Sonnet y Opus usan el mismo `BatchChunkingPrompt` monolitico para manuales:

- Sonnet por defecto;
- Opus solo para paginas rasterizadas/densas.

Las fotos normales siguen usando `FieldPhotoPrompt`; fotos densas con Opus usan
el prompt monolitico.

### 6.1. Mapa de cobertura industrial del parser

El contrato de records debe ser capaz de representar estas familias sin convertir
ninguna practica de industria en requisito cuando el documento no la contiene:

| Familia documental | Records esperables cuando hay evidencia |
|---|---|
| Mantencion mensual | `MAINTENANCE_TASK`, `INSPECTION_CHECK`, `REPAIR_ACTION`, `DOCUMENTATION_REQUIREMENT` |
| Certificacion | `CERTIFICATION_REQUIREMENT`, `DOCUMENTATION_REQUIREMENT`, `FAULT_CONDITION` |
| Inspeccion en terreno | `INSPECTION_CHECK`, `SAFETY_WARNING`, `FAULT_CONDITION` |
| Pruebas funcionales | `FUNCTIONAL_TEST` con precondicion, accion, resultado y criterio explicitos |
| Sistemas de seguridad | record segun la accion documental; el subsistema queda en `x`, no define por si solo una obligacion |
| Troubleshooting | `FAULT_CONDITION`, `TROUBLESHOOTING_STEP`, `REPAIR_ACTION` |
| Emergencia/rescate | `EMERGENCY_OR_RESCUE` solo con protocolo explicito |
| Modernizacion/alteracion | `MODERNIZATION_STEP`, `INSTALLATION_STEP`, `CERTIFICATION_REQUIREMENT`, `DOCUMENTATION_REQUIREMENT` |
| Fotos/esquemas | `SCHEMATIC_LABEL` y evidencia visible; funcion/valor/conexion solo si estan documentados |
| Seguridad del trabajo | `SAFETY_WARNING` o `STOP_WORK_CONDITION`; stop-work exige el par explicito |

Antes de reingestar, revisar si `x` necesita estas etiquetas compactas adicionales:

- `frequency=` para periodicidad documentada;
- `classification=` para no conformidad grave/leve solo cuando el documento la clasifica;
- `status=` para estado operativo/no operativo o sello documentado;
- `document=` para informe, plan, certificado, registro o plano requerido.

No agregar campos obligatorios ni placeholders. Estos detalles siguen siendo
opcionales y solo se emiten si la fuente los declara.

LOTO, jumpers, acceso a caja/pozo/techo, espacios confinados, PPE, herramientas,
sellos, no conformidades o protocolos de rescate no se convierten en reglas
globales. Se extraen solamente de una fuente visible y aplicable.

La referencia mencionada como "Safety Handbook 2025", sus "Nine Safety
Absolutes" y cualquier norma chilena deben verificarse contra una fuente oficial,
versionada y legalmente utilizable antes de entrar a un corpus o criterio de
aceptacion. Este plan no afirma su contenido ni vigencia.

## 7. Decision central de esta iteracion

No reconstruir el ledger desde Markdown narrativo cuando existe una estructura
canonica.

Para las consultas criticas conocidas:

- parsear `FIELD_RECORD` de forma determinista;
- construir la respuesta desde esos registros;
- no pedirle a Haiku que vuelva a descubrir, deduplicar o emparejar la evidencia;
- no usar una segunda llamada LLM;
- fallar de forma explicita si los registros son incompletos o invalidos.

Esto sigue las reglas del proyecto:

- retrieval es la fuente de verdad;
- logica determinista antes que llamadas LLM;
- no inventar procedimientos ni stop-work;
- minimizar costo y latencia.

## 8. Alcance propuesto

### Incluido

1. Versionar el contrato de ingesta.
2. Reingestar el corpus desde cero.
3. Auditar los `FIELD_RECORD` antes de probar RAG.
4. Congelar un nuevo manifest de evidencia.
5. Parsear bloques canonicos desde Retrieve.
6. Renderizar deterministicamente los casos exhaustivos y stop-work.
7. Mantener el camino generativo actual para las otras doce consultas.
8. Actualizar runner, evaluador, tests y documentacion.
9. Ejecutar diagnostico y certificacion 16x3.
10. Preparar una expansion Chile/global versionada, sin mezclarla con la cohorte
    actual de 16 consultas.

### Fuera de alcance

- eliminar el antiguo flujo AWS/Lambda de ingesta;
- eliminar `lambda_parity_test`;
- cambiar Knowledge Base o Data Source;
- activar reranking;
- cambiar modelo;
- hardcodear reglas del manual en codigo de produccion;
- agregar un LLM reparador;
- reescribir todas las respuestas RAG como deterministas;
- limpiar telemetria historica;
- certificar seguridad universal.

La limpieza del antiguo path AWS sera una tarea posterior. El Data Source S3 con
chunking desactivado sigue siendo necesario para indexar los chunks producidos
por Rails.

## 9. Fase 0: validacion independiente

No implementar ni ejecutar llamadas pagadas hasta que otra IA responda:

1. ¿El plan distingue fidelidad del corpus de seguridad universal?
2. ¿El gate de ingesta impide congelar omisiones o invenciones del parser?
3. ¿Los caminos deterministas usan solo registros recuperados?
4. ¿La logica de produccion evita IDs o reglas especificas del manual?
5. ¿La rubrica corpus-especifica permanece fuera de produccion?
6. ¿El dedup no puede reutilizar chunks de una version anterior?
7. ¿El benchmark demuestra scope y filtro realmente aplicados?
8. ¿La cuenta esperada de invocaciones refleja los casos sin LLM?
9. ¿Las 48 respuestas reciben revision documental?
10. ¿Existe algun riesgo de declarar 100% mediante una rubrica circular?

Un "100%" no es valido si el manifest esperado se deriva ciegamente de la misma
salida LLM que se pretende evaluar.

## 10. Fase 1: versionar la ingesta y el dedup

### Problema

`ContentDedupService` actualmente deduplica solo por SHA-256 del archivo.
Si cambia el prompt, puede reutilizar chunks producidos con el contrato anterior.

La base esta vacia hoy, pero dejar este comportamiento haria que la siguiente
evolucion del prompt repita el problema.

### Cambios

1. Definir una constante canonica, por ejemplo:

```ruby
BatchChunkingPrompt::INGESTION_CONTRACT_VERSION = "field_records_v1"
```

2. Persistir en sidecars:

- `ingestion_contract_version`;
- `prompt_fingerprint_sha256`;
- `doc_sha256`;
- `ingestion_path`.

3. Agregar `ingestion_contract_version` a `BulkUploadAsset`.

4. Hacer el dedup dependiente de:

- SHA-256 de bytes;
- version de contrato;
- estado `complete`.

5. Versionar `custom_id` o su indice para permitir que el mismo archivo sea
procesado otra vez bajo un contrato nuevo.

6. Un asset sin version compatible es miss, nunca hit.

### Tests

- misma fuente + misma version => hit;
- misma fuente + version distinta => miss;
- asset antiguo sin version => miss;
- sidecar contiene version y fingerprint;
- web y bulk usan la misma version;
- fotos especializadas declaran su propia version de contrato.

## 11. Fase 2: benchmark de ingesta antes de indexar

La fidelidad RAG no puede superar la fidelidad de los chunks.

Crear un script versionado, por ejemplo:

`script/evaluate_ingestion_field_records.rb`

Debe recibir la salida de parsing o los chunks S3 previos a KB y producir:

- lista de chunks;
- hash de cada chunk;
- todos los `FIELD_RECORD`;
- IDs, tipos, heading/page, accion, resultado, evidencia y opcionales;
- duplicados exactos;
- registros invalidos;
- records sin evidencia;
- stop-work incompletos;
- conteos por tipo.

### Gate funcional del manual

La revision anterior identifico 24 unidades accion-resultado distintas:

- 6 de controlador de tierra;
- 7 de controlador de plataforma;
- izquierda y derecha;
- avance y retroceso con frenado;
- 2 de velocidad limitada/preparacion;
- sensor de inclinacion;
- 4 estados de proteccion contra fosos.

El nuevo output de ingesta debe:

- representar las 24 unidades por separado;
- no fusionar opuestos;
- no inventar resultado para preparacion;
- conservar `REQUIRES_FIELD_VERIFICATION` donde corresponda;
- no agregar unidades funcionales sin soporte.

### Gate stop-work

- cada `STOP_WORK_CONDITION` tiene trigger y accion del mismo fragmento;
- ninguna precaucion se clasifica como stop-work sin accion explicita;
- autoridad de reparacion solo cuando esta documentada;
- registros adicionales se revisan contra pagina/evidencia.

### Revision independiente de ingesta

Una IA o revisor diferente debe comparar cada record contra el PDF fuente.

La tabla de revision debe incluir:

- record ID;
- pagina/heading;
- accion;
- resultado;
- frase de evidencia;
- veredicto soportado/no soportado;
- observacion de omision o fusion.

No avanzar si falta una de las 24 unidades o existe un record tecnico inventado.

### Gate de cobertura estructural general

Agregar fixtures sinteticos/documentales, separados del corpus certificable, que
demuestren que el parser puede conservar:

- tarea mensual y periodicidad;
- informe de mantencion y plan anual;
- anomalia, defecto y accion correctiva sin fusionarlos;
- requisito de certificacion y evidencia documental requerida;
- sello o estado operativo/no operativo cuando es explicito;
- no conformidad grave/leve solo con clasificacion fuente;
- inspecciones mecanicas, electricas, estructurales y de seguridad;
- precondicion, accion, resultado y criterio pass/fail;
- sintoma, causa, prueba, valor y reparacion documentados;
- autoridad de intervencion;
- protocolo de emergencia solo cuando existe;
- alteracion, plano, permiso o recertificacion solo cuando existe;
- LOTO, PPE, herramientas, señalizacion y out-of-service solo cuando existen;
- etiqueta fotografica sin funcion inferida.

Estos fixtures validan capacidad del esquema, no demuestran cumplimiento legal
ni agregan expectativas al manual actual.

## 12. Fase 3: reingesta limpia

Prerequisitos:

- AWS limpio por el usuario;
- base local limpia;
- cambios de ingesta y dedup aprobados;
- fuente disponible con SHA canonico.

### Mecanica de subida (cohorte v2)

El key S3 del path real se deriva como `uploads/<Date.current>/<filename>`
(`S3DocumentsService#upload_file`). Por tanto:

1. Renombrar los archivos locales **antes** de subir:
   - `22 paginas.pdf` → `manual_plataforma_tijera_24_paginas.pdf`
   - `pagina_16.png` → `pagina_16_esquema_hidraulico.png`
2. Subir el **2026-06-10** (el key embebe `Date.current`); en otra fecha el key
   no coincidira con el manifest y habria que versionar keys y manifest de nuevo.
3. Preservacion de bytes (corregido 2026-06-10):
   - **PDF: chat web esta bien.** Los documentos no se comprimen en el
     navegador ni en el servidor → SHA preservado (verificado: el `doc_sha256`
     de los sidecars coincide con el SHA local).
   - **Imagen: NUNCA por chat web.** `rag_chat_controller.js#compressImageOnClient`
     re-encodea toda imagen a JPEG (canvas, max 1024 px, q=0.82) **antes** del
     POST; los bytes resultantes dependen del navegador (no reproducibles) y
     degradan etiquetas pequeñas del esquema. La nota previa sobre
     `should_skip_compression?` solo aplica server-side y no salva el caso.
   - La imagen se ingesta con `script/ingest_benchmark_image.rb`
     (`RAG_INGEST_CONFIRM=1 bin/rails runner script/ingest_benchmark_image.rb`):
     entra al path real en el borde del job (`UploadAndSyncAttachmentsJob` →
     `CustomChunkingPipeline`), saltando solo el transporte del navegador;
     valida SHA local vs manifest antes y SHA S3 vs manifest despues.
4. Verificar el SHA-256 de ambos objetos en S3 contra el manifest
   **inmediatamente despues de subir y antes de ingestar**; abortar si difiere.

Secuencia:

1. Subir manual e imagen con las claves canonicas.
2. Ejecutar el path real de ingesta.
3. Esperar estado `complete`.
4. Verificar sidecars y contrato.
5. Ejecutar el evaluador de ingesta.
6. Revisar los records contra el documento.
7. Iniciar sync de Knowledge Base.
8. Esperar ingestion job `COMPLETE`.
9. Verificar que solo existen las dos fuentes canonicas.
10. Crear/preservar los dos `KbDocument`.
11. Limpiar pins e historial y volver a pinnear exactamente ambos documentos.

No usar dedup para este primer indice certificable.

## 13. Fase 4: nuevo manifest de evidencia

Reemplazar el manifest historico por uno derivado de los chunks nuevos, pero
validado contra el documento fuente.

Nuevo fixture sugerido:

`script/fixtures/rag_quality_benchmark_field_records.json`

Cada unidad debe contener:

- ID corpus-especifico estable;
- `RECORD_ID`;
- tipo;
- heading/page;
- accion exacta; 
- resultado exacto;
- evidencia exacta;
- source URI;
- source SHA-256;
- chunk S3 key;
- chunk SHA-256;
- casos del benchmark a los que aplica;
- veredicto humano/independiente.

El manifest tambien debe congelar:

- todos los stop-work records validos;
- todas las precauciones esperadas del caso #3;
- autoridad de reparacion;
- identificadores visuales sin funcion documentada.

El manifest forma parte del fingerprint del benchmark.

## 14. Fase 5: Retrieve preflight posterior a reindex

Extender `retrieval_preflight` para cuatro casos:

- `isolated:3`;
- `isolated:5`;
- `conversation:3`;
- `conversation:5`.

### Exhaustivos

Con HYBRID N=15:

- parsear todos los `FIELD_RECORD`;
- exigir los 24 `RECORD_ID` funcionales;
- exigir igualdad exacta entre IDs esperados por el manifest e IDs recuperados;
- registrar rank, URI y chunk hash;
- comparar el conjunto aislado y conversacional;
- detenerse si un record requerido no fue recuperado.

### Stop-work

Con el presupuesto real N=5:

- recuperar todos los `STOP_WORK_CONDITION` esperados;
- recuperar las inspecciones/precauciones necesarias para responder;
- asegurar que los dos lados de cada par estan en el mismo bloque;
- detenerse si la evidencia queda fuera del contexto recuperado.

No aumentar N hasta demostrar que el problema es retrieval.

## 15. Fase 6: parser canonico de records recuperados

Crear `Rag::FieldRecordParser`.

Entrada:

- chunks devueltos por `BedrockRagService#retrieve_chunks`.

Salida:

- records validos con:
  `record_id`, `type`, `source`, `action`, `expected_result`, `details`,
  `stop_trigger`, `stop_action`, `repair_authority`, `uncertainty`,
  `evidence`, rank, URI y chunk hash.

Reglas:

- parser por lineas y delimitadores exactos;
- un bloque empieza en `FIELD_RECORD:` y termina en `END_FIELD_RECORD`;
- etiquetas duplicadas invalidan el record;
- claves obligatorias ausentes invalidan el record;
- IDs duplicados con contenido distinto invalidan todo el ledger;
- duplicados fisicos exactos se deduplican por ID + chunk hash;
- no inferir tipo, accion, resultado o stop-work desde narrativa vecina;
- el parser nunca consulta el manifest corpus-especifico.

## 16. Fase 7: respuestas deterministas para los cuatro casos criticos

### Clasificacion estrecha

No usar todo `safety_critical_query?`, porque tambien incluye fallo/reparacion.

Crear intenciones explicitas:

- `exhaustive_functional_test_query?`;
- `stop_work_checklist_query?`.

Solo estas intenciones usan el renderer determinista.

### Ajustes de implementacion (2026-06-11, medidos contra el indice v2)

1. **Retrieval full-scope para renderers (N=100, max del API Retrieve), no
   N=15/N=5.** Medido: top-15 y hasta top-40 por similitud omitian bloques
   documentados (proteccion de pozos, sensor de inclinacion, velocidad
   limitada). Un ledger de checklist que muestrea por similitud esta mal por
   construccion. El presupuesto N=15/N=5 existia para acotar el input de Haiku;
   este camino no invoca modelo (costo solo embeddings) y siempre corre con
   scope pineado forzado, asi que el resultado queda acotado por los documentos
   pineados, nunca el catalogo global. Los presupuestos generativos no cambian.
2. **Seleccion por heading de seccion de prueba.** La ingesta v2 tipa como
   `FUNCTIONAL_TEST` tambien pasos de secciones de componentes/operacion
   (§2.1, §2.5). El renderer exhaustivo selecciona records cuyo
   `SOURCE_SECTION_OR_PAGE` denota seccion de prueba (/\bprueba|test\b/i) o
   continuacion de pagina. Es una regla generica de lenguaje documental (la
   misma señal del contrato de ingesta), no una regla especifica del manual.
3. **El conjunto esperado no es exactamente 24 records:** el manual v2
   documenta 37 records de prueba (las 24 unidades + extras documentales:
   parada auxiliar de tierra, principio basico, verificaciones de continuacion,
   ambos sentidos LED on/off). El manifest congela los 37 con el mapeo
   unidad→record para las 24; la igualdad expected==parsed==rendered se evalua
   contra esos 37, y la cobertura 24/24 contra el mapeo. Cada extra esta
   revisado contra el PDF (pp. 8-11 leidas integras).
4. **Determinismo verificado:** las variantes isolated y conversational de cada
   caso rinden conjuntos de RECORD_IDs identicos (37 y 72) con scopes
   distintos.
5. **D4 — fidelidad de simbolos de esquema (Gate F, 2026-06-11).** La corrida
   diagnostica completa expuso que el parse v2 de la pagina 16 del manual
   nombraba componentes por reconocimiento de simbologia ISO ("flow regulator
   FRRV1", "solenoid valve SV1", "orifice ORF1") y el parse de la foto expandia
   acronimos ("BRK: punto de conexion de freno", "P: puerto de presion") con
   evidencia que era solo la etiqueta impresa. Haiku luego citaba fielmente ese
   contenido contaminado: la fabricacion estaba en el INDICE, no en la
   generacion. Fix: regla "SCHEMATIC / DIAGRAM SYMBOL FIDELITY" en
   `BatchChunkingPrompt` (contrato → `field_records_v3`) y regla reforzada de
   acronimos/simbolos en `FieldPhotoPrompt` (contrato → `field_photo_records_v2`),
   seguidas de re-parse completo del corpus y regeneracion del manifest.
   Valida una vez mas el principio: la fidelidad RAG no puede superar la
   fidelidad de los chunks.
6. **D5 — directiva de etiquetas literales disparada por pregunta + excepciones
   de negacion en el evaluador (2026-06-11).** El override photos-only no cubria
   `visual_fidelity:1` (scope mixto manual+imagen). Se agrego
   `BedrockRagService#visual_label_directive`: cualquier pregunta sobre
   funciones/identificacion de etiquetas de esquema recibe las reglas de
   etiqueta literal (lista plana sin encabezados de categoria, lenguaje
   posicional neutro, sin expansion de acronimos), independiente del scope.
   El detector `inferred_visual_classifications` del evaluador gano dos
   excepciones de principio: (a) negaciones explicitas ("su funcion no esta
   documentada") no son clasificaciones; (b) "con puerto(s) [numerados] N"
   describe digitos impresos visibles, no asigna funcion. Verificado: 3/3 casos
   visuales con 0 clasificaciones inferidas y DATA_NOT_AVAILABLE por codigo.
   El contrato foto avanzo a `field_photo_records_v3` (las etiquetas de
   puerto/letra P, T, M, L, BRK tambien son acronimos, sin excepciones).

### Exhaustive renderer

Crear `Rag::FunctionalTestRenderer`.

Proceso:

1. Un unico Retrieve N=15.
2. Parsear `FIELD_RECORD`.
3. Seleccionar `FUNCTIONAL_TEST`.
4. Validar ledger.
5. Ordenar por rank, heading y orden fisico.
6. Renderizar cada unidad:

```text
Prueba: <heading + identificador discriminante>
Accion: <accion documental>
Resultado esperado: <resultado documental>
```

7. No usar Haiku.
8. No traducir ni parafrasear accion/resultado.
9. Localizar solo las etiquetas fijas de presentacion.
10. Mantener un `rendered_record_ids` interno.

El coverage ledger es una igualdad de conjuntos, no una estimacion:

```text
expected_record_ids == retrieved_record_ids == rendered_record_ids
```

Si retrieval trae 24 records y el renderer usa 23, falla aunque el texto visible
sea correcto. Los `RECORD_ID` deben aparecer en el payload interno/auditable del
benchmark; pueden ocultarse de la respuesta visible al tecnico.

Si el ledger esta vacio, incompleto o invalido:

- responder `DATA_NOT_AVAILABLE`;
- marcar error estructurado;
- no presentar una lista como completa.

### Stop-work renderer

Crear `Rag::StopWorkRenderer`.

Proceso:

1. Un unico Retrieve con el presupuesto real.
2. Parsear records.
3. `STOP_WORK_CONDITION` alimenta exclusivamente:
   `Detencion obligatoria con evidencia explicita`.
4. `INSPECTION_CHECK`, `SAFETY_WARNING` y records pertinentes alimentan:
   `Precauciones e inspecciones`.
5. Cada obligatorio se renderiza:

```text
Disparador: <stop trigger>
Accion obligatoria: <stop action>
```

6. No usar Haiku.
7. No promover un record sin `sw`.
8. Mantener internamente IDs de obligatorios y precauciones.

### Scope de retrieval de los renderers

Ambos renderers deben ejecutar su unico Retrieve con el mismo scope que el
camino generativo:

- resolucion de pins via `Rag::PinnedEntityScopeResolver`;
- filtro de entidad forzado (`force_entity_filter`), sin fallback global;
- si el Retrieve filtrado no devuelve records validos, la respuesta es
  `DATA_NOT_AVAILABLE`, nunca una recuperacion sin filtro.

Esto cierra la pregunta 9 de la seccion 25: no debe existir ningun camino por el
que un record fuera del scope filtrado alimente una respuesta determinista.

### Citas y referencias

Ambos renderers deben conservar:

- source URI;
- `retrieved_citations`;
- referencias numeradas por chunk;
- `doc_refs`;
- retrieval trace;
- session context del turno;
- continuidad conversacional mediante el answer final guardado en historial.

No simular una cita a un chunk que no participo en el record.

## 17. Consecuencia de costo y observabilidad

Cuatro de las 16 consultas no invocaran Haiku:

- isolated:3;
- isolated:5;
- conversation:3;
- conversation:5.

Por corrida:

- consultas totales: 16;
- respuestas deterministas: 4;
- invocaciones Haiku esperadas: 12.
- `tracked_query_count` de modelo esperado: 12, no 16.

En tres corridas:

- consultas totales: 48;
- respuestas deterministas: 12;
- invocaciones Haiku esperadas: 36.

Actualizar runner y gate:

- `query_count=16`;
- `deterministic_query_count=4`;
- `model_invocation_count=12`;
- `tracked_query_count=12`;
- no crear telemetria que finja una invocacion de modelo;
- registrar costo cero de generacion para respuestas deterministas;
- CloudWatch debe mostrar exactamente 36 invocaciones atribuibles en la ventana
  certificable, no 48.

La proyeccion por 1.000 se calcula:

```text
coste CloudWatch de las 3 corridas / 48 consultas * 1000
```

## 18. Fase 8: runner y payload

Incrementar `BENCHMARK_VERSION`.

Por resultado agregar:

- `generation_mode`:
  `bedrock_retrieve_and_generate`,
  `deterministic_functional_tests` o
  `deterministic_stop_work`;
- `model_invoked`;
- `parsed_record_ids`;
- `rendered_record_ids`;
- `expected_record_ids`;
- `record_ledger_sha256`;
- `retrieved_chunk_sha256s`;
- `deterministic_validation`;
- conteo de records por tipo.

El payload global agrega:

- `ingestion_contract_version`;
- `ingestion_prompt_fingerprint_sha256`;
- manifest de field records y su hash;
- `deterministic_query_count`;
- `model_invocation_count`;
- `expected_model_invocation_count`.

`FINGERPRINT_PATHS` debe incluir:

- prompts de ingesta;
- parser de resultados;
- parser de FIELD_RECORD;
- renderers;
- perfil de intenciones;
- runner;
- evaluador;
- manifests;
- prompt generativo general;
- resolucion de pins;
- filtros y citation processor.

## 19. Fase 9: evaluador actualizado

### Exhaustivos

Para los dos casos #5:

- `generation_mode=deterministic_functional_tests`;
- `model_invoked=false`;
- ledger contiene exactamente los 24 IDs esperados;
- `expected_record_ids == parsed_record_ids == rendered_record_ids`;
- rendered IDs son exactamente iguales al ledger;
- sin faltantes, duplicados ni extras;
- texto visible contiene exactamente una entrada por ID;
- accion y resultado corresponden al record;
- no aparece ningun resultado inventado;
- IDs internos no son visibles al usuario.

La gramatica visible sigue siendo:

- una linea `Prueba`;
- una linea `Accion`;
- una linea `Resultado esperado`;
- una linea vacia entre entradas.

### Stop-work

Para los dos casos #3:

- `generation_mode=deterministic_stop_work`;
- `model_invoked=false`;
- obligatorios visibles corresponden exactamente a STOP_WORK records;
- ninguna precaucion aparece en obligatorios;
- ningun obligatorio carece de trigger o accion;
- ninguna entrada extra;
- IDs internos no visibles.

### Resto de reglas

Conservar:

- cohorte canonica;
- matriz exacta;
- ejecucion exitosa;
- source isolation;
- visual literal;
- reparacion;
- revision documental.

### Evitar circularidad

El evaluador no aprueba un record solo porque aparezca en el indice.
El manifest esperado debe estar firmado por la revision contra el PDF fuente.

## 20. Fase 10: tests Minitest

### Ingesta

- schema compacto;
- records obligatorios;
- stop pair completo;
- ID determinista;
- version de contrato;
- prompt fingerprint;
- dedup versionado;
- no reutilizar asset de version anterior;
- no aceptar manual sin records.

### Parser

- bloque valido;
- delimitador faltante;
- etiqueta duplicada;
- ID duplicado conflictivo;
- record truncado;
- stop-work incompleto;
- narrativa con palabras "stop" fuera del bloque no crea record.

### Renderers

- exactamente 24 functional tests;
- izquierda/derecha separadas;
- tierra/plataforma separadas;
- avance/retroceso separados;
- preparacion agrupada sin resultado inventado;
- RFV preservado;
- no LLM;
- una sola recuperacion;
- error seguro ante ledger incompleto.

### Stop-work

- solo records con par completo;
- mareo y personal no autorizado permanecen precaucion;
- fuga sin accion no es obligatoria;
- trigger y accion del mismo record;
- ningun tercer item inventado.

### Orquestacion

- seleccion correcta de camino;
- otras doce consultas siguen usando `retrieve_and_generate`;
- session history recibe la respuesta determinista;
- citas y trace se conservan;
- errores estructurados llegan a `RagResult`.

### Runner/evaluador

- 16 queries, 4 deterministas, 12 modeladas;
- diagnostico expande dependencias;
- fingerprint completo;
- corpus y contrato canonicos;
- evaluador rechaza IDs faltantes, extras y divergentes;
- evaluador rechaza cualquier diferencia entre expected/retrieved/rendered IDs;
- cohorte rechaza distinta ingesta, revision o manifest.

Ejecutar suite completa porque se toca el camino compartido RAG.

## 21. Fase 11: gates de ejecucion

### Gate A: local

- `git diff --check`;
- tests focalizados;
- `bin/rails test`;
- cero fallos;
- skips documentados, sin nuevos skips de los caminos tocados.

### Gate B: preflight sin generacion

- AWS identity;
- modelo;
- region;
- KB;
- sesion;
- corpus SHA;
- contrato de ingesta;
- prompt fingerprint;
- reranking off;
- routing off;
- exactamente dos fuentes.

### Gate C: ingesta

- 24/24 unidades funcionales;
- igualdad exacta expected/retrieved/rendered `RECORD_ID`;
- cero extras no sustentados;
- stop-work revisado;
- autoridad de reparacion;
- revision independiente del output de ingesta.

### Gate D: Retrieve

- exhaustivos recuperan 24/24 records;
- stop-work recupera todos los pares esperados;
- scope y filtro aplicados correctos;
- cero fuentes externas.

### Gate E: diagnostico pagado

Objetivos:

```text
isolated:3
isolated:5
conversation:3
conversation:5
```

El runner ejecuta dependencias conversacionales, pero las cuatro respuestas
objetivo deben:

- ser deterministas;
- no invocar modelo;
- pasar evaluador;
- pasar revision documental.

Este diagnostico no cuenta como certificacion.

### Gate F: corrida completa diagnostica

Ejecutar una matriz completa dirty-permitida antes del commit certificable.

Revisar las 16 respuestas. Si cualquiera de las otras doce contiene una
afirmacion no sustentada, detenerse y planificar el defecto concreto. No ampliar
el renderer determinista sin evidencia del fallo.

### Gate G: certificacion 3x

Prerequisitos:

- cambios committeados;
- `git_dirty=false`;
- mismo commit;
- misma configuracion;
- mismo corpus;
- misma version de ingesta;
- mismo manifest.

Ejecutar serialmente:

```bash
RAG_BENCHMARK_MODE=certification \
RAG_BENCHMARK_OUTPUT=tmp/rag_quality_benchmark_run1.json \
bin/rails runner script/rag_quality_benchmark.rb
```

Repetir para run2 y run3.

### Gate H: evaluador y revisiones

- 3/3 JSON pasan;
- cohorte pasa;
- revision documental 48/48;
- segunda revision independiente de los 12 casos criticos;
- artefacto persistido en docs con evidencia por respuesta.

### Gate I: CloudWatch

- ventana UTC despues del diagnostico;
- exactamente 36 invocaciones Haiku;
- input/output tokens;
- latencia;
- formula explicita;
- costo proyectado <= USD 7,50/1.000 consultas.

Si hay trafico ajeno o el conteo no es 36, la ventana no es atribuible.

El conteo de 36 se filtra por el model ID de Haiku. Las llamadas Retrieve de los
caminos deterministas tambien aparecen en CloudWatch bajo el modelo de
embeddings; no cuentan contra las 36 ni invalidan la ventana, pero su costo de
embedding si entra en la formula de costo total si es distinguible.

## 22. Criterio final de aprobacion

Se puede declarar 100% del benchmark solo si:

- ingesta auditada 24/24;
- cero field records inventados;
- Retrieve entrega todos los records requeridos;
- 48/48 consultas exitosas;
- 48/48 revision documental;
- 12/12 segunda revision critica;
- 3/3 evaluaciones automaticas;
- cohorte reproducible y limpia;
- 6/6 exhaustivas contienen exactamente 24 unidades;
- 6/6 stop-work contienen solo pares documentados;
- cero contaminacion de fuentes;
- cero funciones visuales inventadas;
- autoridad de reparacion correcta;
- CloudWatch atribuible;
- costo <= USD 7,50/1.000.

El resultado final debe decir:

> 100% de fidelidad documental para el corpus y matriz versionados.

No debe decir:

> sistema universalmente seguro o infalible.

## 23. Artefactos finales esperados

- manifest de corpus;
- manifest de FIELD_RECORD revisado;
- reporte de ingesta;
- preflight Retrieve;
- diagnostico;
- tres JSON certificables;
- reporte del evaluador;
- revision 48/48;
- segunda revision 12/12;
- ventana y calculo CloudWatch;
- documento canonico actualizado;
- commit limpio con todos los hashes.

## 24. Expansion Chile/global posterior al cierre actual

No agregar estas consultas a la matriz certificable v8: hacerlo cambiaria el
objetivo mientras se intenta cerrar una regresion ya definida.

Despues de aprobar 16x3, crear una version nueva del benchmark con documentos
oficiales/aplicables que realmente contengan la evidencia. Candidatos:

1. Segun el manual, ¿que debe ir al informe de mantencion mensual?
2. Distingue inspecciones normales versus condiciones que dejan el equipo fuera de servicio.
3. Lista no conformidades graves/leves solo si el documento las clasifica.
4. ¿Quien puede reparar o intervenir este equipo segun el documento?
5. ¿Que evidencia documental debe existir para certificacion?
6. Extrae todos los tests funcionales como pares accion -> resultado esperado.
7. De esta foto/esquema, lista solo etiquetas visibles y usa
   `DATA_NOT_AVAILABLE` si no hay leyenda funcional.
8. ¿Que elementos corresponden a certificacion, mantencion o instalacion?
9. ¿Que dice el documento sobre sello o condicion operativo/no operativo?
10. ¿Que informacion falta para responder con seguridad?

Para esta expansion:

- corpus separado y versionado;
- SHA-256 de cada fuente;
- procedencia y fecha normativa;
- revision de aplicabilidad chilena por una persona competente;
- manifests derivados de fuentes, no de respuestas del modelo;
- `DATA_NOT_AVAILABLE` es el resultado correcto cuando el documento no contiene
  la clasificacion, sello, informe o requisito solicitado;
- no mezclar manuales del fabricante, normas, reglamentos y handbooks como si
  tuvieran la misma autoridad.

## 25. Preguntas concretas para la IA revisora

1. ¿Es correcto reemplazar el ledger Markdown por FIELD_RECORD?
2. ¿Debe el renderer critico ser 100% determinista y sin Haiku?
3. ¿La version de contrato propuesta evita dedup obsoleto?
4. ¿El gate de ingesta evita una rubrica circular?
5. ¿Hay algun dato obligatorio ausente del manifest?
6. ¿Las citas pueden reconstruirse de forma fiable por chunk/record?
7. ¿El presupuesto N=5 de stop-work debe probarse antes de cambiarlo?
8. ¿36 es la cuenta correcta de invocaciones para 48 consultas?
9. ¿Existe algun camino por el que una respuesta determinista pueda usar un
   record fuera del scope filtrado?
10. ¿La separacion entre benchmark v8 y expansion Chile/global evita mover el
    objetivo o afirmar cumplimiento sin corpus oficial?
11. ¿Hay alguna imprecision tecnica que bloquee implementacion o nuevas llamadas?

Hasta recibir esa validacion, este plan permanece bloqueado.
