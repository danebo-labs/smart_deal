# Ingesta piloto Gonzalo (2026-08-20)

**Estado: memoria mitigada, pendiente de deploy para reanudar (22-ago).** Alcance
cerrado en seis marcas, tenant piloto desplegado, `00_validacion.zip` y
`02_ingesta.zip` ingeridos. El coste real medido sobre 985 páginas es
**US$0,0245/página, por debajo** del estimado — los créditos alcanzan para todo el
corpus pendiente. El bloqueo era otro: `03_ingesta.zip` murió por **OOM del
contenedor worker** durante la submission, dejando dos batches pagados y
huérfanos. Ya hay **4 GB de swap en el host** (duplica el presupuesto efectivo del
worker sin redeploy) y la submission **ya persiste cada batch id de forma
incremental** en local, a falta de desplegarlo. Ver
[El límite real es la memoria del worker](#el-límite-real-es-la-memoria-del-worker).

## Presupuesto y alcance

El corpus entregado (2,7 GB) tiene **31.943 páginas en 622 PDFs**: US$1.121 con
buffer, fuera de presupuesto. El alcance acordado son **seis marcas**, medidas
sobre el corpus en disco a US$0,027/página en modo batch más 30% de buffer:

| Marca | PDFs | Páginas | Coste con buffer |
|---|---|---|---|
| KONE | 62 | 5.488 | US$193 |
| Thyssen (`TKE`) | 37 | 1.307 | US$46 |
| BLT | 30 | 1.274 | US$45 |
| OTIS | 24 | 1.194 | US$42 |
| Fuji Yida | 23 | 1.141 | US$40 |
| Mitsubishi | 4 | 38 | US$1 |
| **Total** | **180** | **10.442** | **US$366,53** |

Créditos cargados: **US$371,99**.

### Coste real medido: US$0,0245/página

La validación (27 páginas) sugirió US$0,0403/página, un 49% por encima de lo
estimado. **Esa cifra era un artefacto del tamaño de muestra.** Medido sobre las
985 páginas de `02_ingesta.zip` con
[`script/bulk_upload_cost_audit.rb`](../script/bulk_upload_cost_audit.rb):

| Tanda | Págs | Opus | USD | USD/pág |
|---|---|---|---|---|
| `00_validacion.zip` | 27 | 10 (37%) | 1,0877 | 0,0403 |
| `02_ingesta.zip` | 985 | 11 (1,1%) | 24,1381 | **0,0245** |

Lo que mueve el coste es **qué fracción de páginas va a Opus**, que cuesta ~2x
Sonnet por página (US$0,0533 vs US$0,0242 medidos). La validación tenía 37% de
Opus porque se armó a mano con 4 PDFs; el corpus real tiene 1,1%.

El único camino a Opus en el deploy vigente es el gate de página escaneada de
`FileMultimodalRouter` (`text_layer_chars < 100 && image_area_ratio > 0.7`).
**`IngestionVisualTriageFlag` está `false` en producción**, así que la escalada
geométrica —la que sí subiría los planos vectoriales a Opus— no se aplica. En
`02_ingesta.zip` sólo escalaron `PLANO 4 mitsubishi.pdf` (8 págs) y
`variador de puerta thyssen mcp7.pdf` (3 págs): planos **escaneados**. Los planos
con capa de texto (`Planos BLT QS.pdf`, `QS PLANOS.pdf`) se fueron a Sonnet. El
temor de que "el peso de KONE son planos y por eso irá a Opus" no se materializa
mientras ese flag siga apagado.

Presupuesto vigente:

| Concepto | USD |
|---|---|
| Créditos cargados | 371,99 |
| Gastado (`00` + `02`) | −25,23 |
| **Disponible** | **346,76** |
| 9.353 páginas pendientes a US$0,0245 | −229,15 |
| **Holgura** | **117,61 (34%)** |

**Los cinco ZIPs pendientes entran completos**, incluidos los dos PDFs de OTIS
sobre 50 MB. Sólo un corpus con >65% de páginas escaneadas agotaría los créditos,
y el medido es 1,1%. Aun así se ingiere de a un ZIP y se audita cada uno: la
proyección vale mientras la mezcla Opus/Sonnet se mantenga.

### El límite real es la memoria del worker

`03_ingesta.zip` (`BulkUpload` 4) **falló por OOM del cgroup del contenedor
worker**, no por presupuesto ni por la instancia:

```
oom-kill:constraint=CONSTRAINT_MEMCG … task=bundle
Memory cgroup out of memory: Killed process 2601 (bundle) anon-rss:558608kB
```

- El worker está limitado a **1 GiB** (`HostConfig.Memory=1073741824`); el web a
  1,5 GiB. La instancia es `t3.medium` (3,8 GB, **sin swap**) y tenía 2,3 GB
  libres: **el host no se quedó sin memoria, el contenedor sí**.
- `SolidQueue` no puede rescatar un SIGKILL, así que el `rescue` de
  `SubmitClaudeBatchJob#mark_failed` **nunca corrió**: el upload quedó en
  `processing` con los 7 assets en `uploaded_s3`.

Por qué `02` pasó y `03` no: `02` son 62 PDFs pequeños (ZIP de 23 MB); `03` son 7
PDFs grandes (ZIP de 140 MB). Los cuatro ZIPs pendientes (`01`, `04`, `05`, `06`)
son de 134–137 MB con la misma forma → **mismo riesgo**.

#### Mitigación aplicada (22-ago): 4 GB de swap en el host

El contenedor **ya pedía swap** y nadie se lo podía dar:

```
Memory=1073741824  MemorySwap=2147483648   ← 1 GiB RAM + 1 GiB swap
memory.max      = 1073741824
memory.swap.max = 1073741824               ← permiso concedido…
Swap:  0 total                             ← …sin nada detrás
```

`memory.swap.max` de 1 GiB estaba concedido, pero el host no tenía swap: el
cgroup no podía paginar una sola página y moría en seco al tocar 1 GiB. El
swapfile no cambia la configuración de Docker, **la vuelve real** — el
presupuesto efectivo del worker pasa de 1 GiB a 2 GiB **sin redeploy ni cambio de
config**. `vm.swappiness` es 60 (el default) y los 629 MB del worker son casi
todo `anon`, que es exactamente lo que el swap absorbe.

```bash
sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo "/swapfile none swap sw 0 0" | sudo tee -a /etc/fstab   # sobrevive reinicios
```

El dato que dimensiona el problema: el worker está a **609 MiB de 1 GiB en
reposo** (59%), o sea tenía ~415 MiB de aire. Ahora tiene ~1,4 GiB. Si aun así
volviera a morir, el siguiente paso es subir `memory` en `config/deploy.yml`, no
más swap.

#### Dos batches pagados y huérfanos

El OOM no ocurrió armando las requests sino **a mitad de la submission**, después
de que `ClaudeBatchSubmissionService` ya hubiera creado 2 de 5 grupos.
`bulk_upload.update!(claude_batch_id:)` corre **después** de que `submit!`
devuelva todos los ids, así que los dos batches quedaron sin registro en la BD:

| Batch | Requests | Estado | Coste aprox. |
|---|---|---|---|
| `msgbatch_015ULaoex4qt2AEWtK3HxxHX` | 100 | `ended`, 100/100 succeeded | ~US$2,45 |
| `msgbatch_01Evr6UMUGmz3PnCkmCaJ33S` | 100 | `ended`, 100/100 succeeded | ~US$2,45 |

Están **pagados y completos**, con `results_url` disponible, y nada los va a
pollear: `claude_batch_ids` de `BulkUpload` 4 es `[]`. Los ids de la tabla salieron
del log del worker (`ClaudeBatchSubmissionService: submitted group=…`) y se
transcriben aquí porque ese log es efímero — es la única copia durable.

Recuperarlos exige coserlos a mano y sólo cubren 200 de las 423 páginas del ZIP,
o sea documentos a medias — peor para retrieval que no tenerlos. La
recomendación es **asumir los ~US$4,90 y re-ingerir `03` completo** una vez
arreglada la memoria; el dedupe no ayuda porque ningún asset llegó a `complete`.

**Corregido (22-ago): la submission ya persiste grupo a grupo.**
`ClaudeBatchSubmissionService#submit!` acumulaba los ids con `groups.map` y sólo
los entregaba al terminar el bucle. Ahora acepta un bloque que se invoca tras
cada grupo aceptado, y `BatchIngestionService#submit!` escribe
`claude_batch_ids` **antes de enviar el siguiente**. El coste es un `UPDATE`
pequeño por grupo en un job de fondo; lo que compra es que ningún batch
facturado quede invisible.

Esto es lo que evita el daño grande, no el swap: el swap hace el OOM menos
probable, pero cualquier reinicio, deploy o `SIGKILL` a mitad de submission
repetía la pérdida. `01_ingesta.zip` son 3.615 páginas en ~37 grupos — una caída
a mitad podía orfanar decenas de dólares de una vez.

Las cifras por marca no se pueden sumar desde mediciones separadas: el dedupe por
SHA-256 es global al corpus, así que medir marca por marca cuenta dos veces los
PDFs que aparecen en varias carpetas. La tabla sale de una sola pasada con las
seis marcas juntas.

## No hace falta ingerir todo de una vez

El dedupe es por `(cuenta, SHA-256, versión de contrato)`. Un ZIP posterior que
incluya manuales ya ingeridos produce dedup hit: los assets se marcan `complete`
sin llamar a Anthropic y no se pagan dos veces. La ingesta puede hacerse por
tandas sin penalización.

La única condición es no bumpear `BatchChunkingPrompt::INGESTION_CONTRACT_VERSION`
entre tandas: un cambio de contrato invalida el dedupe a propósito y fuerza el
re-parseo — y el recobro — de todo lo anterior.

## Hallazgos del corpus que sobreviven al recambio de alcance

**Carpetas espejo.** El corpus trae pares `kone` / `kone (1)`, `polaris2` /
`polaris2 (1)`, `planos stella` / `planos stella (1)` y `manuales KONE español` /
`manuales KONE español (1)`. Sólo en KONE+TKE eran 11 PDFs byte a byte idénticos.
El script se queda con un representante por contenido.

**Tres PDFs no pueden ir en un ZIP.** Superan
`ZipExtractionService::MAX_FILE_BYTES` (50 MB) y ese límite **no salta la entrada:
lanza `ZipExtractionService::Error` y aborta el ZIP completo**. Quedan excluidos:

| Archivo | Tamaño | Páginas |
|---|---|---|
| `KONE/MINISPACE/KONE_Parts_2002.pdf` | 54,0 MB | 608 |
| `OTIS/otis/MANUAL DE AYUDA TÉCNICA ( Act. Marzo 2010 ).pdf` | 72,5 MB | 245 |
| `OTIS/otis/MMR.pdf` | 68,0 MB | 74 |

El de KONE es un catálogo de repuestos, de bajo valor para diagnóstico en campo.
Los dos de OTIS sí son material técnico y merecen recuperarse: hay que partirlos
por páginas antes de meterlos en un ZIP. **Los dos de OTIS son 319 páginas
(245 + 74), ~US$7,8** al coste medido. Las 927 páginas que decía antes esta
sección incluían el catálogo `KONE_Parts_2002.pdf` (608 págs), que está excluido
a propósito.

**Los basenames se aplastan.** `sanitize_filename` reduce la ruta a
`File.basename` y la clave S3 del original es
`bulk_uploads/<account_id>/<fecha>/<basename>`, así que dos archivos distintos con
el mismo nombre en subcarpetas distintas se pisarían. En KONE+TKE no había
ninguna colisión tras deduplicar, pero el script aborta si aparece alguna.

**Sólo PDFs.** El corpus trae además 139 JPG, 35 PPT, 19 RTF, 8 DOC, DWG, XLS, MOV
y varios `.rar`/`.zip` anidados. Fuera del perímetro de este piloto.

## Herramienta de preparación

[`script/gonzalo_corpus_prep.rb`](../script/gonzalo_corpus_prep.rb) hace
inventario, presupuesto y armado de ZIPs en una pasada:

```bash
# Sólo reportar
GONZALO_MANUALS_DIR="/ruta/Manuales Gonzalo" \
  bin/rails runner script/gonzalo_corpus_prep.rb

# Reportar y armar los ZIPs del alcance vigente
GONZALO_MANUALS_DIR="/ruta/Manuales Gonzalo" \
GONZALO_VENDORS="KONE,TKE,OTIS,FUJI YIDA,MITSUBISHI,BLT" \
GONZALO_ZIPS_DIR=tmp/gonzalo_zips \
GONZALO_REPORT=tmp/gonzalo_zips/scope.json \
  bin/rails runner script/gonzalo_corpus_prep.rb
```

Produce `00_validacion.zip` (4 PDFs, 27 págs, ~US$1) más seis ZIPs de ingesta, con
`manifest.json` de SHA-256 y páginas por archivo. Los PDFs de la validación no se
repiten en los de ingesta.

Detalles que importan:

- Cuenta páginas con `PdfPageSplitterService` (HexaPDF), **el mismo motor que usa
  el pipeline**, para que el presupuesto salga del número que después se factura.
  Se contrastó contra `pdfinfo`: coinciden exactamente en las 6.795 páginas.
- Lee los topes de `ZipExtractionService` en vez de replicarlos, así que sigue
  siendo correcto si esos guardrails cambian.
- Arma bins de ~140 MB, muy por debajo del tope de 500 MB. Pequeños a propósito:
  un ZIP que falla a mitad ya consumió créditos por las páginas procesadas.
- Reserva un `00_validacion.zip` con los PDFs cortos más livianos repartidos entre
  marcas, para probar el pipeline end-to-end por menos de un dólar.
- **Cada ZIP se relee con el `ZipExtractionService` real** antes de darlo por
  bueno; si una entrada no se detecta como PDF, se salta o colisiona, aborta.

## Prerrequisito de código: fix de tenancy

Antes de esta ingesta el pipeline bulk escribía todos los chunks con
`account_id: "bulk_v1"` hardcodeado, y el retrieval filtra siempre por
`account_id`, así que los manuales habrían sido invisibles para la cuenta de
Gonzalo. Cambios (todos con tests):

- `IngestBatchResultsJob` deriva el account de `bulk_upload.user.account_id` y lo
  pasa al parser; sin cuenta, falla el upload en vez de escribir chunks huérfanos.
- `PollBulkBedrockIngestionJob#upsert_kb_document` hace el upsert scoped por
  `(account_id, s3_key)`.
- `BatchIngestionService` sube los originales a `bulk_uploads/<account_id>/…` y
  aborta antes de tocar S3 si el ZIP no tiene dueño.
- `ContentDedupService` y `BulkUploadAsset.custom_id_for` incorporan el
  `account_id`. Sin esto, `custom_id` (índice único global) haría que el segundo
  tenant que subiera un archivo ya ingerido por el primero reutilizara su fila y
  se quedara sin chunks propios.

Consecuencia de coste: los manuales que ya existen en `danebo-legacy` se
re-parsean para la cuenta de Gonzalo. Es lo correcto en multi-tenant y está
contemplado en las cifras de arriba.

## Runbook de ingesta

### 1. Cuenta piloto — hecho

| Recurso | Valor |
|---|---|
| `Account` | `danebo-pilot-elevator` (id 3), "Piloto Elevator", `branded: false` |
| `User` | `gonzalo.campos@danebo.ai` (id 7) |
| Host | `piloto.danebo.ai` → registro A a `54.163.248.39`, TLS emitido |
| Deploy | `935c84d` |

El slug es temporal y es barato de cambiar: los chunks se indexan bajo
`bulk_chunks/<account.id>/` y el filtro de retrieval usa `account.id`, no el slug.
El slug sólo aparece en `AccountHosts` y en rutas de assets de marca, que este
piloto no usa. El **host** no es igual de barato: cambiarlo implica DNS,
certificado y volver a comunicar la URL a los técnicos.

Falta un `User` por cada ingeniero nombrado — el plan de agosto exige usuarios
nominales para que la telemetría sea atribuible. No entregar credenciales
compartidas.

Gates previos a dar acceso: respuesta en español por defecto y
`PILOT_AUDIT_CAPTURE=true` en el deploy vigente (ambos cumplidos en `935c84d`).

### 2. Subir el ZIP a S3 desde local

`kamal console` corre en el servidor, donde el ZIP no existe, así que el archivo
va a S3 primero. La clave que espera `BulkUploadArchiveService` es
`bulk_upload_archives/<sha256>.zip`:

El bucket de producción es `multimodal-source-destination`, no el fallback del
código:

```bash
ZIP=tmp/gonzalo_zips/00_validacion.zip
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
aws s3 cp "$ZIP" "s3://multimodal-source-destination/bulk_upload_archives/$SHA.zip" \
  --content-type application/zip
echo "$SHA"
```

### 3. Disparar el procesamiento desde consola

**Fijar el rol.** `kamal app exec` corre el comando en *todos* los roles (web y
worker), así que un `create!` se ejecuta dos veces y el segundo choca con el
índice único de `sha256`. Usar siempre `--roles=web` para comandos con efectos:

```bash
kamal app exec --reuse --roles=web 'bin/rails runner "..."'
```

```ruby
user = User.find_by!(email: "gonzalo.campos@danebo.ai")
sha  = "<sha del paso 2>"
bu   = BulkUpload.create!(
  user:              user,
  sha256:            sha,
  original_filename: "00_validacion.zip",
  status:            "pending"
)
ProcessBulkUploadJob.perform_later(bu.id, "bulk_upload_archives/#{sha}.zip", "es")
```

El `user` no es opcional en la práctica: es lo único que determina el tenant de
todo lo que produce la ingesta.

### 4. Verificación antes de gastar el resto

```ruby
bu.reload.status                                   # => "complete"
bu.bulk_upload_assets.group(:status).count         # => {"complete" => N}
bu.bulk_upload_assets.pluck(:chunks_s3_prefix)     # => todos bajo bulk_chunks/<account.id>/
KbDocument.where(account_id: account.id).count
```

Y el control que justifica el fix de tenancy, con `retrieve_chunks` (Retrieve puro,
sin coste de generación) sobre la misma pregunta en las dos cuentas:

```ruby
q = "listado de fallas MPK 708A codigos de error"
[ 3, 1 ].each do |aid|
  res = BedrockRagService.new(account: Account.find(aid)).retrieve_chunks(q, number_of_results: 5)
  # cuenta 3 → Listado Fallas MPK 708A.pdf, codigos error BL6.pdf (account_id=3)
  # cuenta 1 → original.pdf                                       (account_id=1)
end
```

Resultado de la validación: cero solapamiento, y el metadato `account_id` de cada
chunk coincide con la cuenta consultada.

Monitoreo durante la corrida: Mission Control en `/jobs`, estados de
`BulkUpload`/`BulkUploadAsset`, y `bedrock_daily_costs` para el gasto de
embeddings.

### 5. Resto de los ZIPs

Repetir pasos 2–3 de a uno, confirmando `complete` antes del siguiente, para no
perder créditos si algo falla en el camino.

## Tandas

| ZIP | `BulkUpload` | Assets | Págs facturadas | Estado |
|---|---|---|---|---|
| `00_validacion.zip` | 2 | 4 | 27 | `complete`, US$1,0877 |
| `02_ingesta.zip` | 3 | 62 (59 ok, 3 fallidos) | 985 | `complete`, US$24,1381 |
| `03_ingesta.zip` | 4 | 7 (todos `uploaded_s3`) | 200 pagadas, 0 ingeridas | **OOM del worker**, ver arriba |

Reparto por marca de lo pendiente, para decidir el orden:

| ZIP | PDFs | Págs | Marcas dominantes | USD a 0,0245 |
|---|---|---|---|---|
| `01_ingesta.zip` | 62 | 3.615 | KONE 1.241, BLT 723, FUJI 660, TKE 554, OTIS 417 | 88,57 |
| `03_ingesta.zip` | 7 | 423 | OTIS 138, BLT 258, KONE 27 | 10,36 |
| `04_ingesta.zip` | 11 | 1.218 | KONE 1.030, BLT 108 | 29,84 |
| `05_ingesta.zip` | 22 | 1.966 | KONE 1.644, FUJI 216 | 48,17 |
| `06_ingesta.zip` | 12 | 2.131 | KONE 1.320, TKE 411, OTIS 399 | 52,21 |

### Fallos de `02_ingesta.zip`

**Dos PDFs de BLT** (`05.- BLT-ES_PLC input.pdf`, `08.- BLT-ES_PLC output.pdf`, 60
páginas) fallaron con `bulk_uploads.all_pages_filtered`: el filtro descartó todas
sus páginas antes de enviarlas, así que no consumieron créditos. Son tablas de E/S
de PLC; recuperarlos exige revisar `PageRelevanceFilter`, no reintentar el ZIP.

**`otis_2000.pdf`** falló con `Unknown value in chunk 16 field_record 1`. Origen
exacto: `BatchResultsParserService#validate_field_record!` compara las claves del
`field_record` contra `FIELD_RECORD_ALLOWED_KEYS` (`k h a r ev x sw ra u`) y
**lanza `ParseError` si sobra alguna**. El modelo emitió una clave `value` de más
en un registro, y eso descartó el documento entero: 17 páginas ya pagadas, 0
chunks escritos, y ni siquiera quedaron filas en `bedrock_queries` (el tracking
por página corre después del parseo, de ahí el hueco 1.002 → 985).

El radio de daño escala con el tamaño del documento: una clave alucinada en un
manual de 245 páginas cuesta ~US$6. Los ZIPs pendientes traen 954 páginas más de
OTIS.

**Resuelto (22-ago): se descarta el `field_record`, no el documento.** El chequeo
de claves sobrantes se movió de `validate_field_record!` a
`discard_unverifiable_field_records!`, que ya era el airlock que descarta
registros sin evidencia con `filter_map` + `warn`. Una clave alucinada es un
registro defectuoso, no un documento corrupto.

La asimetría es deliberada: **`STOP_WORK_CONDITION` sigue fallando en duro**, por
la misma razón que `unverifiable_non_stop_field_record?` ya lo excluía — una
condición de parada de seguridad no puede desaparecer del ledger sin traza. Sólo
los registros no-seguridad se degradan a descarte.

Sigue siendo fallo de documento todo lo que sí indica corrupción (JSON inválido,
`chunks` vacío, chunk sin `text`, `k` fuera del enum) y el airlock de
`TOPOLOGY_EDGE` emitido por el modelo. **No se bumpea
`INGESTION_CONTRACT_VERSION`**: el contrato de salida no cambia, sólo la
tolerancia del parser, así que el dedupe por `(cuenta, SHA-256, contrato)` sigue
válido.

## Pendientes

1. **Desplegar** los tres fixes de código (submission durable, tolerancia del
   parser, `bin/pilot_metrics`). Hasta el deploy, no relanzar ningún ZIP.
2. **Re-ingerir `03_ingesta.zip`** como canario tras el deploy (~US$10,36; se
   pierden los ~US$4,90 ya pagados).
3. **Usuarios nominales**: falta el nombre y correo de cada ingeniero.
4. **Manuales que Gonzalo dijo que faltaban**: si llegan, se re-corre el script y
   se ingiere sólo lo nuevo — el dedupe por cuenta evita pagar dos veces.
5. **Los dos PDFs de OTIS sobre 50 MB**: 319 páginas, ~US$7,8, requieren partirse
   por páginas.
6. **`ReconcileBedrockCostJob`** sigue fallando con `AccessDenied` en
   `s3:ListBucket`: sin auditoría autoritativa del gasto de Bedrock.

Resueltos el 22-ago: memoria del worker (swap de 4 GB en el host), submission no
atómica (`claude_batch_ids` grupo a grupo) y tolerancia del parser.

## Auditoría de coste por tanda

[`script/bulk_upload_cost_audit.rb`](../script/bulk_upload_cost_audit.rb)
reconstruye el coste real de una tanda desde las filas de `bedrock_queries` que
`IngestBatchResultsJob` escribe por página. Es de sólo lectura y no llama a
ninguna API: incluye `cache_read`/`cache_creation`, que es lo que
`bulk_upload_assets` **no** permite tarifar porque los suma dentro de
`claude_input_tokens`. Reproduce exactamente el US$1,0877 de la validación.

El script no está en la imagen desplegada, así que `kamal app exec … 'bin/rails
runner script/…'` falla con *file could not be found*. Se pasa por stdin sin
redeployar:

```bash
CID=$(ssh -i ~/.ssh/smart-deal-deploy.pem ubuntu@54.163.248.39 \
  "docker ps --filter label=service=smart-deal --filter label=role=web \
   --filter status=running --format '{{.Names}}' | head -1")
ssh -i ~/.ssh/smart-deal-deploy.pem ubuntu@54.163.248.39 \
  "docker exec -i -e BULK_UPLOAD_ID=3 $CID bin/rails runner -" \
  < script/bulk_upload_cost_audit.rb
```

## Notas operativas

**La cola `solid_queue_recurring` no la consumía nadie (corregido 22-ago).**
`clear_solid_queue_finished_jobs` está declarado en `config/recurring.yml` con
`command:` en vez de `class:`, así que SolidQueue lo envuelve en
`SolidQueue::RecurringJob` y lo encola en `solid_queue_recurring`. Los tres
workers de `config/queue.yml` cubrían `default`, `ingestion` y `bulk_ingestion`:
ninguno esa. Consecuencia doble — **el job que limpia los jobs terminados nunca
corrió ni una vez**, y sus propios encolados se apilaron: 553 filas en `ready`
entre el 5-may y el 21-ago, con 6.188 jobs `finished` sin purgar.

Arreglado añadiendo la cola al lane `default`. Orden importante: **primero se
descartó el backlog, después se habilitó el consumo**; al revés, los 553
`RecurringJob` se habrían ejecutado todos de golpe al arrancar el worker.

Se descartaron también las 16 `FailedExecution` acumuladas, ninguna reintentable
con sentido: 12 de `ReconcileBedrockCostJob` (el `AccessDenied` sigue sin
resolver, así que volverán a aparecer), un `ProcessBulkUploadJob` del 5-jun por
un ZIP ya borrado, un `UploadAndSyncAttachmentsJob`, y las dos muertes por OOM.
Estado final: `ready`, `claimed`, `failed`, `blocked` y `scheduled` a cero, y los
6.188 jobs restantes todos `finished`.

**El OOM del worker era crónico, no de `03`.** Entre esas fallidas estaba
`SubmitManualBatchJob` del **23-jul** sobre `SEGURIDADES 1.1-1.pdf`, muerta con
la misma firma que `03`: `ProcessExitError — Received unhandled signal 9`. El
límite de 1 GiB llevaba un mes matando jobs sin que nadie lo diagnosticara.

`SubmitClaudeBatchJob` (job 6718, `args=[4]`) se descartó **a propósito**: seguía
siendo reintentable, y reintentarla habría re-enviado los cinco grupos desde cero
—re-facturando las 423 páginas— dejando además los dos huérfanos igual de
huérfanos.

**Acceso SSH.** El security group `sg-06d4cf4fc9a5e3749` (`smart-deal-sg-web`)
autoriza el puerto 22 por IP `/32`. Una IP nueva no entra hasta añadir la regla.
Hay reglas antiguas sin descripción que conviene depurar.

**Apagar la infra a mitad de una ingesta cuesta dinero.** El stack son dos piezas
que se paran por separado: la instancia `i-09db5c5fc53e973b0` y la instancia RDS
`smart-deal-db`. Con RDS parada la app devuelve 502 aunque los contenedores estén
arriba. Lo caro es el worker: los batches siguen procesándose y facturándose en
Anthropic, pero `PollClaudeBatchJob` tiene un `HARD_TIMEOUT` de 24h contado desde
su primer intento, así que si el worker vuelve pasado ese plazo marca el upload
como `failed` sobre resultados ya pagados. Con los ZIPs grandes eso son cientos de
dólares. No parar la infra con un batch en vuelo.

La IP pública `54.163.248.39` es elástica y sigue asociada tras un stop/start, así
que el DNS y los certificados no se rompen al reiniciar.

**Control manual del stack.** [`bin/stack`](../bin/stack) encapsula lo anterior:
`up` autoriza la IP local en el puerto 22, arranca RDS antes que EC2 y espera un
200; `down` se **niega** a parar si hay uploads en vuelo; `hold` / `release`
deshabilitan y reponen los schedules `danebo-stop-{ec2,rds}` de EventBridge, que
por defecto apagan todo a las 18:00 de Chile. `hold` está aplicado mientras corre
esta ingesta. `status` resume EC2, RDS, salud HTTP, uploads en vuelo y schedules.

**`ReconcileBedrockCostJob` está fallando.** `AccessDenied` en `s3:ListBucket` para
el rol `smart-deal-ec2-role`. Es la reconciliación de coste que las reglas del
proyecto tratan como autoridad sobre las estimaciones por tokens, así que ahora
mismo no hay auditoría del gasto real de Bedrock. Falla a diario desde el 6-ago.

**La IP local rota y tumba el SSH.** El `docker exec` de este runbook y
`bin/pilot_metrics` entran por el puerto 22, autorizado por IP `/32`. Cuando el
ISP renueva la IP el SSH **no se rechaza: se queda colgado** hasta el timeout de
TCP. `bin/stack ssh-ip` reautoriza; `bin/pilot_metrics` ahora usa
`ConnectTimeout` para fallar rápido en vez de colgarse.

**Export diario de telemetría.** [`bin/pilot_metrics_daily`](../bin/pilot_metrics_daily)
saca una copia durable de la telemetría del piloto para las dos cuentas
(`danebo-legacy` y `danebo-pilot-elevator`) antes de que los schedules apaguen el
stack. Motivo: `PilotAuditLog`/`PilotUsageLog`/`[RAG_QUALITY]` sólo escriben a
`Rails.logger` → stdout → Docker `json-file` con `max-size=10m` y **sin
`max-file`**, así que al rotar se pierde lo anterior; eso ya destruyó un día del
piloto el 10-ago (hallazgo H1 de
[plan_telemetria_durable_piloto](rag/plan_telemetria_durable_piloto_2026-08-19.md)).
El frente B (tabla en RDS) sigue pendiente de aprobación humana.

Instalación en cron local:

```cron
20 * * * * cd /Users/lahirisan/smart_deal && ./bin/pilot_metrics_daily >> tmp/pilot_metrics_daily.log 2>&1
```

Decisiones de diseño que conviene no revertir sin leer esto:

- **Cron cada hora, no una vez al día.** El export es idempotente: escribe en un
  directorio por `(rango, cuenta)`, así que re-ejecutarlo el mismo día sobrescribe
  sus propios artefactos y gana la última corrida. Con una sola ejecución diaria,
  una laptop dormida a esa hora pierde el día entero.
- **La ventana se evalúa en `America/Santiago`** (9–17h), no en la hora local, para
  que el DST de cualquiera de las dos zonas no la desplace contra el apagado de
  las 18:00. Fuera de la ventana el script sale 0 sin intentar nada.
- **Reautoriza la IP** con `bin/stack ssh-ip` antes de exportar, por lo de arriba.
- **No usa `--strict`.** `--strict` falla cuando un rol no produjo eventos, y un
  día de piloto sin actividad es un resultado real y esperado: un job que avisa
  todos los días se acaba ignorando, que es justo el punto ciego que venía a
  cerrar. En su lugar valida invariantes **estructurales** del `manifest.json`
  (`containers_read` no vacío, `containers_unreadable` vacío, los dos roles
  descargados), que distinguen "hoy nadie lo usó" de "no pudimos leer los logs" —
  el fallo real del 13-ago.
- **Limitación asumida:** un cron en la laptop sólo dispara si la laptop está
  encendida. La solución durable es el frente B, no un cron mejor; la alternativa
  server-side (timer en la EC2 exportando a S3) necesita la misma aprobación.
- **Los tests fijan `PILOT_METRICS_DAILY_FORCE=true`.** Esa misma ventana 9–17h
  hacía que diez de los doce tests del wrapper sólo pasaran si la suite corría
  dentro de ella: verdes de día, rojos de noche, por la hora y no por el código.
  El bypass va en el env base y sólo los dos tests que cubren la ventana lo
  desactivan.

**`bin/pilot_metrics` leía sólo contenedores corriendo.** `resolve_container` usaba
`docker ps`, que omite los `exited`. Tras un deploy los logs de los días
anteriores quedan en el contenedor viejo —hoy mismo `cc0cadb` (exited) tenía del
11 al 20-ago— y el export los ignoraba **en silencio**. Ahora resuelve por
separado el contenedor corriendo (para `docker exec`, que lo necesita vivo) y la
lista de contenedores del rol (`docker ps --all`, más antiguo primero, tope de 6),
concatena los logs de todos y registra en el manifest `containers_read` y
`containers_unreadable`.

**Devise `trackable` no está habilitado.** `users` no tiene `last_sign_in_at` ni
`sign_in_count`, así que hoy un login sólo se puede verificar en el log web
efímero — la misma fuente que rota. Decisión pendiente: añadir `trackable` o
aceptar el hueco.

**Deriva entre el host map y kamal.** `config/deploy.yml` está en `.gitignore`, así
que la lista real de `proxy.hosts` no viaja en el repo. El test de
`AccountHostResolver` compara `AccountHosts::PRODUCTION` contra
`config/deploy.yml.example`, que sí está versionado: al añadir un host hay que
tocar los tres sitios.

## Seam conocido, no corregido

`BulkUploadsController#create` busca el ZIP por `sha256` global, así que dos
cuentas subiendo el mismo ZIP colisionarían en la fila `BulkUpload`. No se tocó
porque las rutas `/bulk_uploads` siguen deshabilitadas (T-31) y toda esta carga va
por consola. Hay que resolverlo antes de reactivar la UI.
