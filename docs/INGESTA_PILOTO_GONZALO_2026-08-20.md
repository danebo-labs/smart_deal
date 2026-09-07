# Ingesta piloto Gonzalo (2026-08-20)

**Estado: NUEVE tandas cerradas, CERO ZIPs pendientes — la ingesta del piloto
queda completa (24-ago).** Alcance cerrado en seis marcas, tenant piloto
desplegado, y `00`, `02`, `03`, `04a`, `04b`, `05`, `06`, `01` y `07` en
`complete` sobre el deploy `bc3bf7d`. Los tres incidentes que bloquearon la
ingesta —OOM del worker en la submission, explosión de disco por página, OOM al
reintentar páginas— están **cerrados con código desplegado y tests**, y
`01_ingesta.zip` (3.615 páginas, 62 PDFs, el mayor riesgo técnico abierto) los
confirmó en la tanda más exigente medida hasta ahora: pico de memoria del
worker **836,8 MiB de 2 GiB (41%)** durante la submission, partiendo de una
línea base de 365,9 MiB tras el reinicio — muy por debajo del 97% que rozó
`05`, y el **frente de memoria de la submission queda cerrado** (ver
[nota de cierre](#01-cierra-el-frente-de-memoria-de-la-submission-24-ago)).
`07_ingesta.zip` (319 páginas est., los dos PDFs de OTIS troceados por rango de
página) cerró la ingesta a **US$0,0514/página** — nuevo techo de coste, por
encima del 0,0470 de `04b`, explicado por el 100% de páginas escaneadas a
Opus, no por un defecto de código (ver
[nota de cierre](#07-cierra-el-piloto-nuevo-techo-de-coste-00514pág-24-ago)).
Gastado **US$255,21 all-in** de los US$371,99 de créditos; quedan
**US$116,78** sin ninguna tanda pendiente. Ver [Pendientes](#pendientes).

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

Presupuesto tras las dos primeras tandas (**histórico**; el vigente está en
[Cerrado tras `07`](#cerrado-tras-07-24-ago-el-piloto-completa-la-ingesta-con-nuevo-techo-de-coste)):

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

**Medido en la re-submission de `03` (22-ago): pico de 928 MiB de 1.024, y swap
usado 0.** Es decir, cupo por 96 MiB sin tocar el swap. Lo que marcó la
diferencia no fue el swap sino arrancar el worker limpio: post-deploy partía de
375 MiB, mientras que en el intento fallido venía de 609 MiB con el heap
acumulado de las 62 PDFs de `02`. El swap queda como seguro para cuando eso
vuelva a pasar — y `01_ingesta.zip` son 62 PDFs otra vez, así que va a pasar.

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

**Verificado en vivo:** durante la re-submission de `03` se observó
`claude_batch_ids` con **3 ids mientras aún quedaban grupos por enviar**, y 5 al
terminar. Con el código anterior el campo habría pasado de 0 a 5 de golpe, o se
habría quedado en 0 para siempre si el proceso moría en el grupo 4.

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

**Sincronización del Drive verificada (22-ago).** Duda razonable a mitad de la
ingesta: si el Drive local no estaba completo cuando se armó el inventario, el
corpus ingerido sería incompleto sin que nada avisara — un fichero que no ha
bajado **no aparece como ilegible, no aparece en absoluto**, así que el informe no
puede distinguir "no existe" de "no se sincronizó". Se re-corrió
`script/gonzalo_corpus_prep.rb` sobre el mismo directorio y da cifras **idénticas**
a las del 20-ago:

| | 20-ago | 22-ago |
|---|---|---|
| PDFs únicos en alcance | 180 | 180 |
| Páginas | 10.442 | 10.442 |
| PDFs en las 6 carpetas | 208 | 208 |
| Duplicados exactos | 25 | 25 |
| Excluidos por tamaño | 3 | 3 |
| Ilegibles / colisiones | 0 / 0 | 0 / 0 |

La aritmética cierra sin huecos (208 − 25 − 3 = 180) y no hay ni un placeholder
`.icloud` ni un fichero de 0 bytes en todo el árbol. **El alcance está completo.**

**El Drive tiene mucho más que el alcance, y es deliberado.** En disco hay 622
PDFs repartidos en 23 carpetas de marca/categoría; el alcance cubre 6 de ellas
(208 PDFs). Las otras 17 suman 365 PDFs únicos y **15.904 páginas** —un 52% más
que todo el alcance vigente— e incluyen `03 ESCALERAS` (207 PDFs, 3.791 págs),
`FERMATOR` (49, 3.158), `SCHINDLER` (20, 2.311), `variadores` (15, 1.920) y
`Hyundai` (14, 1.761). **Gonzalo autorizó indexar sólo las seis marcas del plan
inicial, no la carpeta entera**, así que eso queda fuera por decisión de producto,
no por un límite técnico. Se anota para que la cifra no vuelva a sorprender: el
corpus completo serían 26.346 páginas, muy por encima de los créditos.

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

## Herramientas de operación

El inventario completo, con qué escribe cada una y las dos trampas de ejecutarlas
contra producción, está en [`script/AGENTS.md`](../script/AGENTS.md). Resumen:

| Herramienta | Para qué |
|---|---|
| [`script/bulk_upload_status.rb`](../script/bulk_upload_status.rb) | Estado de una tanda: assets por estado, el error de cada fallo y los `field_records` descartados. `FOLLOW=true` sondea hasta `complete`/`failed`. |
| [`script/bulk_upload_cost_audit.rb`](../script/bulk_upload_cost_audit.rb) | Coste all-in de una tanda, incluidas las rutas directas y los tokens de caché. |
| [`script/bulk_upload_recover_failed.rb`](../script/bulk_upload_recover_failed.rb) | Recupera assets que fallaron **después** de volver los resultados, sin pagarlos otra vez. |
| [`script/pdf_split_peak_audit.rb`](../script/pdf_split_peak_audit.rb) | Disco que escribirá un ZIP al trocear páginas, contra el espacio libre del host. Pasarlo antes de subir. |
| [`script/split_oversized_pdfs.rb`](../script/split_oversized_pdfs.rb) | Parte los PDFs sobre 50 MB por rangos de página y arma un ZIP verificado. |
| [`script/gonzalo_corpus_prep.rb`](../script/gonzalo_corpus_prep.rb) | Inventario, presupuesto y armado de los ZIPs del corpus. |
| [`bin/worker_watch`](../bin/worker_watch) | Muestrea la memoria del worker contra su límite de cgroup y avisa si el contenedor deja de estar `Up`. |

La lógica reusable vive en servicios con tests (`BulkUploadStatusReport`,
`BulkUploadAssetRecovery`, `PdfSplitPeakEstimator`,
`PdfPageSplitterService#each_part`); los scripts son envoltorios. Los dos motivos: el parseo de un fallo nuevo suele necesitar
iteración, y un descarte de seguridad no puede depender de un script sin cobertura.

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
| `03_ingesta.zip` | 4 | 7 (**7/7 complete**) | 416 | `complete`, **US$16,2100** all-in (0,0390/pág) |
| `05_ingesta.zip` | 5 | 22 (**22/22 complete**) | 1.711 facturadas de 1.827 enviadas | `complete`, **US$31,5610** all-in (**0,0184/pág**) |
| `06_ingesta.zip` | 6 | 12 (**12/12 complete**) | 2.064 | `complete`, **US$52,6563** all-in (**0,0255/pág**) |
| `04a_ingesta.zip` | 8 | 1 (el KONE de 515 págs, **complete**) | 512 | `complete`, **US$10,8422** all-in (**0,0212/pág**) — ver cierre abajo |
| `04b_ingesta.zip` | 9 | 10 (**9/9 no filtrados complete**, 1 filtrado por completo) | 187 | `complete`, **US$8,7897** all-in (**0,0470/pág**) — ver [nota de coste](#04b-el-ritmo-más-caro-medido-hasta-ahora-00470pág-24-ago) |
| `01_ingesta.zip` | 10 | 62 (**62/62 complete**) | 3.447 facturadas de 3.615 est. | `complete`, **US$84,9042** all-in (**0,0246/pág**) — ver [nota de cierre](#01-cierra-el-frente-de-memoria-de-la-submission-24-ago) |
| `07_ingesta.zip` | 11 | 4 (**4/4 complete**) | 301 facturadas de 319 est. | `complete`, **US$15,4685** all-in (**0,0514/pág**) — ver [nota de cierre](#07-cierra-el-piloto-nuevo-techo-de-coste-00514pág-24-ago) |

`06` cerró 12/12 sólo tras recuperar `CMC3 SCM Synergy.pdf`, que había fallado con
`Invalid k in chunk 47 field_record 11`: el modelo emitió el tipo
`"MODIFICATION_RECORD"` en la página 42, con las cinco claves obligatorias
correctas y sin `sw`. Es la **tercera rama** del mismo defecto —una alucinación en
un registro tiraba el documento entero ya pagado— y se cerró con la misma regla:
un `k` fuera del enum no puede ser una parada de seguridad mal etiquetada, porque
sin el par `sw` incluso un `STOP_WORK_CONDITION` bien formado falla en duro y uno
que lo lleva ya se descartaba antes. Una etiqueta que aún mencione un stop sigue
fallando en duro. Las 59 páginas se recuperaron **sin re-pagar** con
[`script/bulk_upload_recover_failed.rb`](../script/bulk_upload_recover_failed.rb).

Dato de coste que conviene no olvidar: en `06` el `page_filter` hizo 235 llamadas
para 2.131 páginas, no ~107, porque `PageRelevanceFilter::MAX_WINDOW_BYTES`
(22 MB) parte las ventanas antes de las 20 páginas cuando el material viene
escaneado. El recargo de las rutas directas fue 9,2%.

### El disco es un presupuesto, y los bytes de origen no lo miden (22-ago, `04`)

`04_ingesta.zip` (BulkUpload 7) murió con `No space left on device` en
`/tmp/danebo-page-383-*.pdf`: 11 assets a `failed`, 0 batches, **US$1,44**
gastados en filtro de páginas sin ingerir nada. No fue memoria — el worker nunca
pasó de 921 MiB de 2 GiB.

`BulkCostV2RequestBuilder#collect_pages` materializa **todas** las páginas de un
documento en disco antes de filtrar. Medido sobre el escaneo KONE que lo reventó:
16 MB de origen, 515 páginas, **10,4 MB por página, 5,61 GB en disco**, inflación
de ~350×. El host tiene 28 GB con ~9,9 GB libres, así que dos manuales así en el
mismo ZIP pedían 8,9 GB.

La causa raíz inmediata está en el reparto: `gonzalo_corpus_prep.rb` bina por
bytes de origen, y como predictor del disco se equivoca por dos órdenes de
magnitud. La prevención es
[`script/pdf_split_peak_audit.rb`](../script/pdf_split_peak_audit.rb), que mide
`páginas × tamaño por página` y falla con código 1 si un ZIP pasa del presupuesto.
**Pásalo antes de subir cualquier ZIP.**

> ⚠️ **Corregido el 22-ago (noche), tras el OOM de `IngestBatchResultsJob(8)`.**
> Esta sección atribuía la inflación a que "la extracción por página copia el
> árbol de recursos compartidos del PDF en cada página". **Es falso**, y sobre esa
> frase se construyó todo el presupuesto de disco. La causa real es una sola clave
> del diccionario de página: **`/B`**, el array de *article thread beads* (el
> catálogo tiene `/Threads`). Cada bead apunta al siguiente y cada bead apunta a
> su página, así que importar una página enhebrada recorre el hilo entero y
> arrastra las demás páginas con sus imágenes. La página 1 de este manual tiene
> **0 XObjects propios** y `/Resources` propio: no heredaba nada.
>
> Medido con HexaPDF 1.8.0, idéntico en local y en producción:
>
> | | Antes | Con `/B` podado |
> |---|---|---|
> | Página 1 extraída | 12,296 MiB | **0,097 MiB** |
> | Página 250 | 12,296 MiB | **0,034 MiB** |
> | Objetos en el PDF de 1 página | 1.864 (435 `Page` huérfanas) | 20–29 |
> | Documento completo, 515 págs | 6,18 GiB | **17,9 MiB** |
>
> **355× de reducción.** 435 de las 515 páginas llevaban `/B`; las del apéndice no,
> y por eso la inflación parecía una propiedad de las páginas con imagen. Es
> seguro: el texto extraído es idéntico y la página rasterizada por poppler a 150
> dpi da un PNG **byte a byte idéntico** (mismo SHA-256 en las páginas 1, 250 y
> 509). El fix vive en `PdfPageSplitterService::WHOLE_DOCUMENT_ONLY_KEYS`,
> aplicado en `#import_page`, el único punto por donde una página cruza al
> documento destino — cubre `each_page`, `each_split_page` y `each_part` a la vez,
> y `PdfSplitPeakEstimator` poda igual para seguir midiendo lo que de verdad se
> escribe.
>
> **Consecuencia operativa:** el presupuesto de disco deja de ser una compuerta
> para esta clase de documento, y **todas las cifras de pico de más abajo son
> pre-fix**. No las reutilices: vuelve a medir con
> `pdf_split_peak_audit.rb` sobre el código nuevo. Lo que sigue vigente es la
> regla, no el número — el disco se presupuesta por `páginas × tamaño por página`,
> nunca por bytes de origen.

Medir exacto, no muestrear: en ese manual tres muestras predijeron 4,45 GB y
6,64 GB contra 5,61 GB reales, porque la inflación se concentraba en las páginas
enhebradas.

**Re-medido sobre el código nuevo (24-ago)** con
[`script/pdf_split_peak_audit.rb`](../script/pdf_split_peak_audit.rb) y
`DISK_FREE_GB=9.9` (presupuesto resultante: 6,93 GB):

| ZIP | Pico pre-fix | Pico post-fix |
|---|---|---|
| `04b_ingesta.zip` | 0,11 GB | **0,11 GB** |
| `07_ingesta.zip` | 0,14 GB | **0,14 GB** |
| `01_ingesta.zip` | 1,06 GB | **0,29 GB** |

`04b` y `07` no se mueven porque no traen documentos enhebrados; `01` cae 3,6×
porque sí. Los tres pasan con margen amplio: **el disco ya no es la compuerta de
esta ingesta**. La regla sigue siendo la misma — se presupuesta por
`páginas × tamaño por página`, nunca por bytes de origen — y el audit hay que
pasarlo igual antes de subir cualquier ZIP nuevo.

Hallazgo lateral que ahorró 514 páginas: los dos escaneos KONE de 515 páginas de
`04` eran **el mismo manual** con SHA-256 distinto, así que el dedupe por
`(cuenta, SHA-256, contrato)` no los veía. 514 de 515 páginas con texto idéntico
carácter a carácter; sólo la última difiere y ninguna contiene a la otra (tabla
`PARÁMETROS DE LCE 813131`). Se ingiere uno y esa página se rescata sola.

`04` se relanzó repartido por pico de disco, no por bytes (picos **pre-fix**; con
`/B` podado `04a` cae a ~0,02 GB y el reparto habría sido innecesario):

| ZIP | BulkUpload | Contenido | Págs | Pico (pre-fix) |
|---|---|---|---|---|
| `04a_ingesta.zip` | 8 | el manual KONE de 515 págs, solo | 515 | 5,61 GB |
| `04b_ingesta.zip` | — | los otros 9 documentos + la página rescatada | 189 | 0,11 GB |

Total 704 págs en vez de 1.218: ~US$18 en vez de ~US$31.

### `05` pasó, pero por 29 MiB: hay que subir `memory` antes de `01`

`03` murió en el grupo **2 de 5**. `05` submitió **55 de 55** con 22 PDFs y 1.827
páginas —4,4× las páginas de `03`—, así que la persistencia incremental y el
arranque limpio funcionaron. Pero el margen fue mínimo (104 muestras cada 20 s):

| Fase | Memoria del worker | Swap del host |
|---|---|---|
| Arranque limpio post-deploy | 375 MiB | 0 |
| Tras descomprimir el ZIP de 128 MB | 694 MiB | 0 |
| Filtrado de páginas (191 llamadas) | 640–818 MiB | 25–40 MB |
| **Cola de la submission (10:02:34)** | **995 MiB de 1.024 (97%)** | 41 MB |
| Reposo posterior | 705 MiB | 41 MB |

**Sobrevivió por 29 MiB.** Y el detalle que desarma la hipótesis del swap: el
high-water del swap del host fueron **41 MB de 4.096**. Es decir, el contenedor
nunca superó su límite de 1 GiB, así que **nunca llegó a usar swap** — el swap
sigue sin estar probado como red, y a 1.024 MiB el cgroup mata antes de swapear
lo suficiente. Lo que evitó el OOM fue el reciclaje del GC. El grupo más grande
fueron 73 requests y **52 MB de bytes crudos**, que es el pico real de presión.

Conclusión operativa para `01_ingesta.zip` (**3.615 páginas, 62 PDFs**: el doble
de páginas de `05` y casi el triple de ficheros): **hay que subir `memory` del
worker en `config/deploy.yml` antes de dispararlo**, como ya anticipaba la nota de
la re-submission de `03`. El host tiene 3.831 MB con ~2.095 disponibles y el web
reservado a 1.465 GiB, así que subir el worker de `1g` a `2g` entra. Ese redeploy
hay que hacerlo **con la cola vacía**, no con un ZIP en vuelo.

`03` se reanudó sin re-extraer: los 7 assets seguían en `uploaded_s3` con sus
objetos intactos en S3, así que bastó `SubmitClaudeBatchJob.perform_later(4)` en
vez de re-subir el ZIP. Salieron 416 requests en 5 grupos (no 423: el
`PageRelevanceFilter` descarta algunas páginas antes de facturar), 416/416
correctas y 0 errores de batch.

### El ritmo de `03` no es el de `02`: 0,0341/página

| Tanda | Págs | Opus | USD | USD/pág |
|---|---|---|---|---|
| `00_validacion.zip` | 27 | 10 (37%) | 1,0877 | 0,0403 |
| `02_ingesta.zip` | 985 | 11 (1,1%) | 24,1381 | 0,0245 |
| `03_ingesta.zip` | 416 | 160 (**38,5%**) | 14,2056 | **0,0341** |

El share de Opus vuelve a ser el único driver, y `03` es material OTIS/BLT
**escaneado**: `LG-OTIS DI 60-105 IV.pdf` sale a 0,0521/pág y `manual placa LCB II
(parte2).pdf` a 0,0436, mientras `MPDK176manual-1.pdf` (con capa de texto) se
queda en 0,0276. O sea que el 0,0245 de `02` no es una constante del corpus sino
una propiedad de qué tan escaneado viene cada ZIP.

### El batch no era toda la factura: +13% por rutas directas

El audit medía sólo `route: "batch"`. Hay **dos rutas más** facturadas contra las
mismas páginas, y ninguna aparecía en ninguna cifra de este documento:

| Ruta | Qué es | Modelo |
|---|---|---|
| `page_filter` | `PageRelevanceFilter`, una llamada por tramo de 20 páginas — **se paga incluso por las páginas que luego descarta** | Haiku directo |
| `bulk_retry` | `BatchPageRetryService` sobre páginas truncadas, a precio **directo**, no batch | Sonnet/Opus directo |

Coste all-in real, ya integrado en `script/bulk_upload_cost_audit.rb`:

| Tanda | Págs | Opus | batch | no-batch | **all-in** | **USD/pág** |
|---|---|---|---|---|---|---|
| `00_validacion.zip` | 27 | 37% | 1,0877 | 0,0576 (+5%) | **1,1453** | **0,0424** |
| `02_ingesta.zip` | 985 | 1,1% | 24,1381 | 3,1536 (+13%) | **27,2918** | **0,0277** |
| `03_ingesta.zip` | 416 | 38,5% | 14,2056 | 2,0044 (+14%) | **16,2100** | **0,0390** |

Lo tranquilizador: el filtro sólo desperdició **US$0,03** en los 3 assets de BLT que
descartó por completo. El coste del filtro no es basura, es peaje.

### El corpus cabe sólo por debajo de US$0,0361/página

| Concepto | USD |
|---|---|
| Créditos | 371,99 |
| Gastado all-in (`00` 1,1453 + `02` 27,2918 + `03` 16,2100 + huérfanos ~4,90) | −49,55 |
| **Disponible** | **322,44** |
| 8.930 págs a 0,0277 (ritmo de `02`, con capa de texto) | −247,36 → holgura 75 (23%) |
| 8.930 págs a 0,0361 | −322,37 → **break-even exacto** |
| 8.930 págs a 0,0390 (ritmo de `03`, escaneado) | −348,27 → **no cabe, faltan 26** |

O sea que ya no es "cabe con holgura": **cabe si la media se queda bajo
US$0,0361/página**, y eso lo decide cuánto material escaneado traiga cada ZIP.
`05` (1.966 págs, 22% del pendiente) es el primer voto real.

#### Cerrado (24-ago): la media real es 0,0244 y el presupuesto deja de apretar

Los votos ya están contados. Con `05`, `06` y `04a` cerrados, el gasto
**productivo** es US$139,71 por 5.715 páginas facturadas = **US$0,0244/página**,
casi exactamente el ritmo de `02` y muy por debajo del break-even de 0,0361:

| Concepto | USD |
|---|---|
| Créditos | 371,99 |
| `00` 1,1453 + `02` 27,2918 + `03` 16,2100 + `05` 31,5610 + `06` 52,6563 + `04a` 10,8422 | −139,71 |
| Huérfanos de `03` (~4,90) + filtro del `04` fallido (1,44) | −6,34 |
| **Gastado all-in** | **−146,05** |
| **Disponible** | **225,94** |
| 4.123 págs pendientes a 0,0244 (media real) | −100,60 → holgura **125 (55%)** |
| 4.123 págs a 0,0390 (ritmo de `03`, el peor medido) | −160,80 → holgura **65 (29%)** |

**Entra incluso en el peor escenario medido.** El coste dejó de ser el riesgo de
esta ingesta; el riesgo que queda es operativo (memoria en la submission de `01`).

**Actualizado tras `04b` (24-ago):** `04b` cerró a **US$8,7897 / 187 págs =
0,0470/pág**, el ritmo más caro medido hasta ahora — ver
[nota de coste](#04b-el-ritmo-más-caro-medido-hasta-ahora-00470pág-24-ago) para
la explicación (fracción de páginas escaneadas del ZIP, no un defecto):

| Concepto | USD |
|---|---|
| Gastado all-in previo | 146,05 |
| `04b` | +8,79 |
| **Gastado all-in** | **154,84** |
| **Disponible** | **217,15** |
| 3.934 págs pendientes (`07`+`01`) a 0,0244 (media real) | −95,99 → holgura **121 (56%)** |
| 3.934 págs a 0,0390 (ritmo de `03`) | −153,43 → holgura **64 (29%)** |
| 3.934 págs a 0,0470 (ritmo de `04b`, el nuevo peor medido) | −184,90 → holgura **32 (15%)** |

Sigue entrando incluso al ritmo de `04b`, pero la holgura ya es más ajustada:
**vale la pena auditar `07` igual de cerca antes de comprometer `01`.**

#### Cerrado tras `01` (24-ago): el mayor pendiente cerró al ritmo medio, no al peor

`01` votó por el escenario bueno, no el peor: **0,0246/pág**, prácticamente
idéntico al ritmo medio de `0,0244`, muy lejos del 0,0470 de `04b` que se usaba
como cota superior. Con las ocho tandas cerradas, el gasto productivo es
US$154,84 + US$84,9042 = **US$239,7442 all-in**:

| Concepto | USD |
|---|---|
| Gastado all-in previo | 154,84 |
| `01` | +84,90 |
| **Gastado all-in** | **239,74** |
| **Disponible** | **132,25** |
| 319 págs de `07` a 0,0246 (ritmo de `01`, el más reciente) | −7,85 → holgura **124 (94%)** |
| 319 págs a 0,0470 (ritmo de `04b`, el peor medido) | −14,99 → holgura **117 (89%)** |

**`07` cabe con holgura amplia en cualquier escenario.** Ya no hay ninguna
tensión de presupuesto: `07` son 319 páginas frente a los US$132,25
disponibles, así que incluso al ritmo más caro jamás medido en esta ingesta el
sobrante es de US$117. El presupuesto dejó de ser una variable a vigilar de
cerca en esta ingesta.

#### Cerrado tras `07` (24-ago): el piloto completa la ingesta con nuevo techo de coste

`07` no votó por el escenario medio ni por el peor ya medido: votó **por
encima** de los dos. Cerró a **0,0514/pág**, por encima del 0,0470 de `04b` que
se usaba como cota superior de esta ingesta. Con las nueve tandas cerradas, el
gasto productivo es US$239,7442 + US$15,4685 = **US$255,2127 all-in**:

| Concepto | USD |
|---|---|
| Gastado all-in previo | 239,74 |
| `07` | +15,47 |
| **Gastado all-in** | **255,21** |
| **Disponible** | **116,78** |

Sin tandas pendientes, la holgura de US$116,78 no se contrasta contra ninguna
página futura — el corpus del piloto (seis marcas, alcance acordado) queda
**completo**. El detalle de por qué `07` rompe el techo, y por qué no es un
defecto de código, está en la [nota de cierre](#07-cierra-el-piloto-nuevo-techo-de-coste-00514pág-24-ago).

#### El audit medía de menos: `bulk_uploads.updated_at` miente

La primera lectura de `03` dio 367 páginas y US$12,17, sin el fichero recuperado.
No faltaban filas en `bedrock_queries` —las 49 estaban— sino que caían fuera de la
ventana del audit, que terminaba en `bu.updated_at + 6h`. El pipeline avanza
estados con `update_columns` y `update_all`, y **ninguno de los dos toca los
timestamps**, así que `updated_at` seguía congelado en la corrida original: la
ventana cerró a las 01:55 de Chile y el re-parseo fue a las 05:30.

Corregido anclando el final también en `bulk_upload_assets.maximum(:updated_at)`,
que sí se mueve porque el parser escribe el asset con `update!`. Los nombres de
fichero son el guard de corrección; la ventana sólo evita que se cuele un upload
concurrente. `00` y `02` re-auditados dan exactamente lo mismo que antes
(1,0877 y 24,1381), así que el cambio no reescribe historia.

Sigue cabiendo, pero la holgura ya no es cómoda. De ahí el orden: **KONE primero
(`05`, `06`)**, cuyos planos tienen capa de texto y van a Sonnet, para medir el
ritmo barato antes de comprometer las 3.615 páginas de `01`.

Reparto por marca de lo pendiente, para decidir el orden:

| ZIP | PDFs | Págs | Marcas dominantes | USD a 0,0245 |
|---|---|---|---|---|
| `01_ingesta.zip` | 62 | 3.615 | KONE 1.241, BLT 723, FUJI 660, TKE 554, OTIS 417 | 88,57 |
| `03_ingesta.zip` | 7 | 423 | OTIS 138, BLT 258, KONE 27 | 10,36 |
| `04_ingesta.zip` | 11 | 1.218 | KONE 1.030, BLT 108 | 29,84 |
| `05_ingesta.zip` | 22 | 1.966 | KONE 1.644, FUJI 216 | 48,17 |
| `06_ingesta.zip` | 12 | 2.131 | KONE 1.320, TKE 411, OTIS 399 | 52,21 |

### Fallos de `02_ingesta.zip`

**Dos PDFs de BLT** (`05.- BLT-ES_PLC input.pdf`, `08.- BLT-ES_PLC output.pdf`)
fallaron con `bulk_uploads.all_pages_filtered`: el filtro descartó todas
sus páginas antes de enviarlas, así que no consumieron créditos. Son tablas de E/S
de PLC; recuperarlos exige revisar `PageRelevanceFilter`, no reintentar el ZIP.

> ⚠️ **Corregido 2026-08-25.** Esta sección decía que los dos PDFs sumaban **60
> páginas**. Son **1 página cada uno**. La cifra no tenía respaldo en ninguna
> fuente y se propagó al plan de liberación, inflando el presupuesto de la
> re-ingesta de ~US$0,15 a ~US$3. Verificado por tres vías con los mismos SHA-256
> que se ingirieron: `HexaPDF` y `PDF::Reader` sobre el binario extraído de
> `02_ingesta.zip`, el inventario `tmp/gonzalo_zips/scope.json`, y el
> `manifest.json` que viaja dentro del propio ZIP subido. Lo mismo aplica a
> `Conectores QS.pdf` de `04b` (1 página). **El hueco de contenido del piloto son 3
> páginas en total.**
>
> Causa raíz del descarte, medida el 25-ago: la heurística `toc?` de
> `PageRelevanceFilter`, **no** el prompt de Haiku (cero llamadas a Haiku, que es
> lo que explica el "sin coste"). Una tabla de E/S tiene ≥10 líneas y la mayoría
> acaban en un número de señal o de borne — 32/89, 31/88 y 33/103 líneas, o sea
> fracciones 0,360 / 0,352 / 0,320 contra el umbral `TOC_LINE_FRACTION = 0.30`.
> Arreglado con un guard fail-open a nivel documento
> (`:all_pages_filtered_guard`); detalle y riesgo residual en
> [`docs/PLAN_LIBERACION_PILOTO_2026-08-25.md`](PLAN_LIBERACION_PILOTO_2026-08-25.md),
> Paso 1.

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

#### El mismo problema por otra rama: `sw` mal tipado

La tolerancia de claves desconocidas salvó tres documentos en la re-ingesta de
`03` (log del worker: `unknown keys: value`, `unknown keys: connection` ×2), pero
un cuarto documento cayó por **otra** validación:

```
manual placa LCB II (parte 1).pdf  failed
  Unexpected sw outside STOP_WORK_CONDITION in chunk 26 field_record 2
```

El modelo puso un par de evidencia `sw` en un registro tipado como otra cosa.
Coste: 49 páginas ya facturadas, ~US$2,14, 0 chunks. Misma clase de defecto que
la clave sobrante, distinta rama de `validate_field_record!`.

**Resuelto (22-ago) con la misma regla y una traza durable.** Un registro que
lleva `sw` sin ser `STOP_WORK_CONDITION` no es fiable como ninguna de las dos
cosas —ni parada de seguridad, ni instancia limpia del tipo que declara— así que
se descarta. La asimetría se mantiene y ahora es un solo guard al principio de
`droppable_field_record_reason`: **un registro que el modelo declara
`STOP_WORK_CONDITION` nunca se descarta**, falla en duro.

Como descartar contenido de seguridad no puede vivir sólo en `Rails.logger` —que
rota con el `json-file` de 10m sin `max-file`, el mismo agujero que la telemetría—
se añadió `bulk_upload_assets.dropped_field_records` (jsonb). Guarda chunk,
`record`, página, `k` y motivo de cada descarte, y se escribe **dentro del
`update!` que ya existía**, sin queries extra.

### Cierre de `BulkUpload` 8 tras el fix de memoria (24-ago)

`IngestBatchResultsJob(8)` murió por `SIGKILL` el 22-ago a las 13:00:46 UTC
reintentando páginas del KONE de 515 págs sin acotar (`each_page` materializaba
las 515 en memoria, y cada página pesaba 12,296 MiB por el `/B` de article-thread
sin podar — ver la corrección de más arriba). Los 108 batches ya estaban
`ended`/pagados; el job nunca llegó a escribir nada a S3.

**Desplegado:** SHA `bc3bf7d` (antes `223c936`), con el fix de
`PdfPageSplitterService#each_page(only:)` + poda de `/B` en `#import_page`,
`BatchPageRetryService` acotado a las páginas fallidas, `PdfSplitPeakEstimator`,
y el toolkit de operación (`bulk_upload_status.rb`, `bulk_upload_cost_audit.rb`
ya existente, `bulk_upload_recover_failed.rb`, `pdf_split_peak_audit.rb`,
`bin/worker_watch`). Cola confirmada vacía antes del deploy: sólo el
`BulkUpload` 8 en `processing`, `ready`/`scheduled`/`claimed`/`blocked` en
SolidQueue en cero.

**Reanudación sin re-pagar:** `IngestBatchResultsJob.perform_later(8)` releyó los
108 batches ya `ended` desde Anthropic (no se llamó a `SubmitClaudeBatchJob` ni se
resometió el ZIP). El asset 116 pasó `in_batch → parsed → syncing → complete` en
~5 minutos.

| Métrica | Valor |
|---|---|
| Estado final | `BulkUpload` 8 `complete`, asset 116 `complete` |
| `chunks_s3_prefix` | `bulk_chunks/3/38a1b716d1f432d3cb088c83c5c14efa8490` (1000+ objetos en S3) |
| `kb_document_id` | 119 |
| `dropped_field_records` | 0 — el documento parseó limpio, sin descartes |
| Páginas que necesitaron retry directo | **1** (`bulk_retry`: 1 llamada, US$0,1004) — confirma que el pico del retry quedó acotado a una página, no a las 515 |
| Pico de memoria del worker | **~630 MiB de 2 GiB (31%)**, arranque limpio en 369 MiB — sin alerta, lejos del ceiling que mató el job el 22-ago |
| Coste all-in | **US$10,8422** sobre 512 páginas = **US$0,0212/página** (batch US$9,4876 + no-batch US$1,3547: `page_filter` 439 llamadas US$1,2543, `bulk_retry` 1 llamada US$0,1004) |
| Opus | 0% — 100% Sonnet |

El worker sigue en `memory: 2g` (subido antes de `05`/`06`), no se tocó ese límite
como parte de este cierre — el fix fue acotar el pico, no subir el techo.

### `04b`: el ritmo más caro medido hasta ahora, 0,0470/pág (24-ago)

Primer ZIP **multi-documento** sobre `bc3bf7d` (`04a` sólo había probado el
camino de un documento). `BulkUpload` 9, 10 assets (9 docs + la página LCE
rescatada de KONE): 9 `complete`, 1 `failed` — `Conectores QS.pdf` (1 página) con
`bulk_uploads.all_pages_filtered` (mismo motivo ya visto en dos PDFs de BLT en
`02`: el filtro descarta todas sus páginas antes de enviarlas, **sin coste** —
causa raíz identificada el 25-ago, ver la corrección en
[Fallos de `02_ingesta.zip`](#fallos-de-02_ingestazip)).
`dropped_field_records`: 2, ambos en `Weg_Lazo_Abierto.pdf`, `k=SCHEMATIC_LABEL`,
`reason="unknown keys: connection"` — la misma tolerancia de claves cerrada el
22-ago, no un `STOP_WORK_CONDITION`. Pico de memoria del worker **~906 MiB de
2 GiB (44%)**, sin alertas de disco ni de memoria en ningún momento.

| Métrica | Valor |
|---|---|
| Páginas facturadas | 187 |
| Coste all-in | **US$8,7897** (batch US$7,7884 + no-batch US$1,0013: `page_filter` 13 llamadas US$0,3384, `bulk_retry` 3 llamadas US$0,6630 — 12,9% sobre el batch) |
| **USD/página** | **0,0470** — nuevo peor ritmo medido, por encima de `03` (0,0390) |
| Opus | **73,8%** (138/187 págs) — nuevo máximo, por encima del 38,5% de `03` |

El share de Opus tan alto **no es una firma de código nueva**: sigue siendo el
mismo (y único) gate de `FileMultimodalRouter` (`text_layer_chars < 100 &&
image_area_ratio > 0.7`) que ya gobierna todas las tandas anteriores. Lo que
cambia es la composición del ZIP. Desglose por fichero (vía `bedrock_queries`,
sólo lectura):

| Fichero | Págs | Opus |
|---|---|---|
| `r.pdf` | 40 | 100% |
| `BLTpdf.pdf` | 34 | 100% |
| `Planos BLT.pdf` | 34 | 100% |
| `manual placa LCB II (parte3).pdf` | 19 | 100% |
| `Weg_Lazo_Abierto.pdf` | 21 | 52% |
| `mpk708a配线图 diargramas blt.pdf`, `Informe KidZania…`, `Conectores NS(1).pdf`, `KONE…LCE p515.pdf` | 39 | 0% |

Cuatro de los nueve documentos son escaneos completos (planos y esquemas sin
capa de texto) y concentran el 100% de sus páginas en Opus; sólo cuatro
documentos con capa de texto se quedan enteramente en Sonnet. `04b` es un ZIP
pequeño (189 páginas) armado con "el resto" de BLT/OTIS/TKE tras separar el
KONE de 515 páginas en `04a`, así que la fracción escaneada pesa mucho más que
en los ZIPs grandes de KONE (`05`, `06`), donde los planos con capa de texto
dominan. Confirma la regla ya anotada en `03`: **el driver siempre es qué
fracción del ZIP viene escaneada, no el corpus en su conjunto** — y en un ZIP
chico esa fracción puede dispararse sin que sea un defecto.

### `01` cierra el frente de memoria de la submission (24-ago)

`BulkUpload` 10, la tanda más grande del piloto (62 PDFs, 3.615 páginas
estimadas — el doble de páginas de `05` y casi el triple de ficheros). Se
disparó siguiendo el runbook al pie de la letra: worker reiniciado con la cola
vacía (línea base **365,9 MiB de 2 GiB**, frente a los 777 MiB en reposo
previos), audit de disco re-confirmado en 0,29 GB, y `bin/worker_watch`
corriendo desde antes de crear el `BulkUpload`.

**El pico de memoria durante la submission fue 836,8 MiB de 2 GiB (41%).**
Llegó en el mismo instante en que `claude_batch_ids` pasó de 25 a 35 grupos —la
cola de la submission, igual que en `05`— y en menos de un minuto volvió a
730-770 MiB, donde se mantuvo estable durante el resto del procesamiento
(parseo, retry, sync). En ningún momento `bin/worker_watch` emitió
`WORKER_ALERT` ni `DISK_ALERT`; el disco libre del host no se movió de 10 GB en
las 66 minutos que tardó la tanda completa, de principio (creación del
`BulkUpload`) a fin (`status=complete`).

**El delta no escaló con las páginas — al contrario.** `05` (1.827 páginas, 22
PDFs) hizo pico en 995 MiB partiendo de 375 MiB: un delta de **~620 MiB**. `01`
(3.615 páginas, 62 PDFs — 2× las páginas y ~3× los ficheros de `05`) hizo pico
en 836,8 MiB partiendo de 365,9 MiB: un delta de **~471 MiB**, más chico en
términos absolutos pese a tener más del doble de páginas. La hipótesis del
runbook anterior —que el heap acumulado escala con el número de grupos
enviados a lo largo de la submission— **no se confirma**: los grupos siguen
topados en ≤100 requests/~50 MB cada uno, la persistencia incremental de
`claude_batch_ids` libera la referencia a cada grupo apenas se confirma, y el
GC recicla entre grupos con margen de sobra. El techo real que importa no es
"páginas totales" sino el tamaño de un grupo individual, que el propio diseño
ya acota.

**Conclusión operativa: el frente de memoria de la submission queda cerrado.**
Con `01` —la tanda más grande y la única que quedaba por probar en ese eje—
completada a 41% del techo de 2 GiB y sin necesitar una sola página de swap, no
hay evidencia de que ninguna tanda futura de este piloto (`07` son sólo 319
páginas en 4 archivos) vaya a acercarse al límite. El reinicio del worker antes
de una submission grande sigue siendo buena higiene operativa barata, pero deja
de ser la mitigación crítica que era cuando `05` sobrevivió por 29 MiB.

Ningún `dropped_field_records` fue un `STOP_WORK_CONDITION`: los 20 registros
descartados en 11 de los 62 documentos caen en las dos tolerancias ya cerradas
el 22-ago —7 por falta de evidencia (`k` en `COMMISSIONING_STEP`,
`SCHEMATIC_LABEL`, `INSTALLATION_STEP`, `INSPECTION_CHECK`), 7 por clave
sobrante (`unknown keys: value/criteria/function`) y 6 por `sw` fuera de
`STOP_WORK_CONDITION` (`k=SAFETY_WARNING`/`COMMISSIONING_STEP`)—, sin firma
nueva.

| Métrica | Valor |
|---|---|
| Páginas facturadas | 3.447 de 3.615 estimadas (el `page_filter` descarta el resto antes de facturar) |
| Coste all-in | **US$84,9042** (batch US$76,6443: Sonnet US$54,4477/2.962 pág + Opus US$22,1966/485 pág; no-batch US$8,2599: `page_filter` 217 llamadas US$7,6772, `bulk_retry` 5 llamadas US$0,5827 — 10,8% sobre el batch) |
| **USD/página** | **0,0246** — prácticamente el ritmo medio real (0,0244), muy por debajo del peor caso presupuestado (0,0470 de `04b`) |
| Opus | **14,1%** (485/3.447 págs) — entre el 1,1% de `02` y el 73,8% de `04b`; ninguna firma nueva, sigue siendo el mismo gate de `FileMultimodalRouter` |
| Batches | 35 |
| Pico de memoria del worker | **836,8 MiB de 2 GiB (41%)**, línea base tras reinicio 365,9 MiB |
| Duración total | ~66 minutos (creación del `BulkUpload` a `status=complete`) |

Los cinco documentos más caros por página son los mismos que llevan el 100% de
Opus — escaneos sin capa de texto, no un defecto de código:

| Fichero | Págs | USD/pág | Opus |
|---|---|---|---|
| `CMC3.pdf` | 22 | 0,0641 | 100% |
| `THYSSEN (SERIE CMC-3 HIDRAULICO).pdf` | 46 | 0,0591 | 100% |
| `Enviando OTIS+(Codigos+LG-SIGMA)-2.pdf` | 9 | 0,0576 | 100% |
| `mcinv4.pdf` | 11 | 0,0568 | 100% |
| `THYSSEN SERIE F HIDRAULICO.pdf` | 34 | 0,0510 | 100% |

Los cinco documentos más caros en total (por volumen de páginas, no por
ritmo) son los manuales más largos del ZIP y confirman que el peso absoluto lo
pone el tamaño del documento, no el share de Opus: `MPDK136 - COMMISSIONING
MANUAL.pdf` (278 pág, US$4,8394), `BLT MPDK136 puesta en marcha ingles.pdf`
(273 pág, US$4,7026), `KOYO MANUAL TARJETA BL2000 - STB.pdf` (190 pág,
US$4,4118), `xizi FO VF.pdf` (92 pág, US$4,1847, 100% Opus) y `manual en
castellano yida.pdf` (162 pág, US$3,5521).

### `07` cierra el piloto: nuevo techo de coste, 0,0514/pág (24-ago)

`BulkUpload` 11, la última tanda del piloto y la primera armada íntegramente
con PDFs troceados por rango de página (los dos manuales de OTIS que superaban
`ZipExtractionService::MAX_FILE_BYTES`). Se disparó siguiendo el runbook al pie
de la letra: gate de disco re-confirmado en 0,14 GB, `bin/worker_watch`
corriendo desde antes de crear el `BulkUpload`, y los 4 assets pasaron
`uploaded_s3 → in_batch → parsed → syncing → complete` en ~23 minutos (16:28 a
16:51), sin ninguna `FailedExecution` nueva.

| Métrica | Valor |
|---|---|
| Páginas facturadas | 301 de 319 estimadas (`page_filter` descarta el resto antes de facturar) |
| Coste all-in | **US$15,4685** (batch US$14,3736: 100% Opus/301 pág; no-batch US$1,0950: `bulk_retry` 3 llamadas US$0,5478, `page_filter` 18 llamadas US$0,5471 — 7,6% sobre el batch) |
| **USD/página** | **0,0514** — **nuevo peor ritmo medido**, por encima del 0,0470 de `04b` |
| Opus | **100%** (301/301 pág) — nuevo máximo, por encima del 73,8% de `04b` |
| Pico de memoria del worker | sin presión: 808 MiB en reposo antes de crear el `BulkUpload`, 825 MiB en reposo después — nunca se acercó al techo de 2 GiB, como anticipaba el runbook para 319 páginas en 4 ficheros |
| `dropped_field_records` | 5 (ver abajo), ninguno `STOP_WORK_CONDITION` |

**El ritmo rompe el techo que se venía usando como cota superior de esta
ingesta, y la explicación es la misma que ya cerró `03` y `04b`: qué fracción
del ZIP viene escaneada.** Los dos manuales de OTIS de esta tanda —`MMR.pdf` y
`MANUAL DE AYUDA TÉCNICA ( Act. Marzo 2010 ).pdf`, ambos manuales antiguos sin
capa de texto— cayeron el 100% de sus páginas en el único gate de Opus que
gobierna todas las tandas anteriores (`FileMultimodalRouter`:
`text_layer_chars < 100 && image_area_ratio > 0.7`). No hay firma de código
nueva: es el mismo mecanismo que llevó a `04b` a 73,8% y a `03` a 38,5%, sólo
que aquí los dos únicos documentos del ZIP son escaneos completos, así que la
fracción se va a 100%. Ningún indicio de defecto — pero por instrucción
explícita de la sesión (coste medido por encima de 0,0470/pág es motivo de
escalado), se reporta como hallazgo y no se normaliza en silencio.

**`dropped_field_records`: 5, las mismas dos tolerancias cerradas el 22-ago,
ninguna nueva.**

| Asset | Página | `k` | Motivo |
|---|---|---|---|
| `MANUAL … (p1-123).pdf` | 48 | `FAULT_CONDITION` | `sw` fuera de `STOP_WORK_CONDITION` (×2 registros) |
| `MANUAL … (p1-123).pdf` | 77 | `TROUBLESHOOTING_STEP` | `sw` fuera de `STOP_WORK_CONDITION` |
| `MANUAL … (p1-123).pdf` | 102 | `REPAIR_ACTION` | `unknown keys: tools` |
| `MANUAL … (p124-245).pdf` | 99 | `REPAIR_ACTION` | `sw` fuera de `STOP_WORK_CONDITION` |

Los dos ficheros `MMR (p1-37).pdf` y `MMR (p38-74).pdf` parsearon limpios, sin
descartes.

**Hallazgo propio de esta tanda: el troceo por rango de página no deja rastro
estructurado hacia el documento original.** Es la primera vez que el pipeline
recibe un PDF partido por páginas (no por documento), y el camino funciona de
principio a fin, pero con una consecuencia a tener en cuenta para retrieval:

- Cada mitad se ingiere como **documento independiente**: `canonical_name`,
  `doc_sha256` y `kb_document_id` propios. `MANUAL DE AYUDA TÉCNICA ( Act.
  Marzo 2010 ) (p1-123)` y `(p124-245)` son dos `KbDocument` distintos (192 y
  193), sin ningún campo que los declare "parte 1/2 del mismo manual" — la
  única señal es el rango de páginas embebido en el nombre de fichero, que
  viaja tal cual a `canonical_name` y a `metadataAttributes.original_filename`.
- `page_number` en el sidecar de cada chunk (`BatchResultsParserService
  #sidecar_metadata`) es **local a la parte partida**, no al documento
  original: la página 99 registrada en `(p124-245).pdf` es la página real 222
  del manual de 245 páginas (124 + 99 − 1), pero ese offset no se guarda en
  ningún campo — sólo se puede reconstruir parseando a mano el rango del
  nombre de fichero.
- No es un defecto que haya que arreglar para este piloto (los chunks son
  recuperables y citables, sólo que la cita apunta a "página 99 de la parte
  p124-245" en vez de "página 222 del manual completo"), pero si en el futuro
  se trocean más manuales por rango de página, vale la pena decidir si se
  quiere una identidad de documento compartida y un offset de página
  explícito, o si citar por parte es aceptable para el producto.

**Comprobación de retrieval (única consulta, sólo lectura, sin coste de
generación):** `BedrockRagService.new(account: Account.find(3)).retrieve_chunks`
con una pregunta de mantenimiento OTIS devuelve, entre los 5 resultados con más
score, 3 chunks de los ficheros de esta tanda (ambas partes de `MANUAL DE AYUDA
TÉCNICA`) junto a 2 de `Manual de URM (OTIS) 1.1.pdf`, ya ingerido en una tanda
anterior — todos con `metadataAttributes.account_id = 3`. El material de OTIS
de `07` es recuperable en la cuenta del piloto.

## Pendientes

### Estado verificado antes de la siguiente tanda (24-ago, tras cerrar `01`)

Comprobado en vivo para no re-investigarlo al abrir `07`:

| Comprobación | Valor |
|---|---|
| Deploy en producción | `bc3bf7d` (`/rails/REVISION` del contenedor web) |
| `HEAD` local | `c82d810` — todos los commits por encima de `bc3bf7d` son **solo documentación**, así que **no hace falta desplegar** |
| Árbol de trabajo | limpio, `01` ya commiteado |
| `bin/stack status` | EC2 `running`, RDS `available`, HTTP 200, 0 uploads en vuelo |
| `bin/stack hold` | aplicado — `danebo-stop-ec2` y `danebo-stop-rds` `DISABLED` |
| Cola SolidQueue | `ready` / `scheduled` / `claimed` / `blocked` en **0** |
| `BulkUpload` en `pending`/`processing` | ninguno; el último es el 10 (`01`) `complete`, 62/62 assets |
| Worker | **808 MiB de 2 GiB (39%)** en reposo tras la tanda de `01` (nunca pasó de 836,8 MiB, 41% del techo, durante toda la corrida) |
| Disco del host | **9,7 GB libres**; swap 4 GB con 197 MB en uso, sin alerta de `bin/worker_watch` |
| Audit de disco de `07` | **0,14 GB** re-medido contra presupuesto de 6,79 GB, salida 0 — los 4 documentos dan pico exacto de 0,03–0,04 GB cada uno |
| `INGESTION_CONTRACT_VERSION` | `field_records_v8` — sin cambios; el dedupe de las ocho tandas sigue válido |

Las **5 `FailedExecution`** que hay no son un hallazgo nuevo: tres son
`ReconcileBedrockCostJob` con el `AccessDenied` ya documentado (una por día,
sube a diario mientras siga abierto), y las otras dos son los incidentes ya
cerrados —el `Errno::ENOSPC` de `04` y el `SIGKILL` de
`IngestBatchResultsJob(8)`, ambos del 22-ago—. Ninguna `FailedExecution` nueva
apareció durante la corrida de `01`.

### Ingesta — completa (24-ago)

`07_ingesta.zip` cerró `complete` el 24-ago (`BulkUpload` 11, ver
[nota de cierre](#07-cierra-el-piloto-nuevo-techo-de-coste-00514pág-24-ago)).
Con las nueve tandas cerradas y `07` ya subido, **no queda ningún ZIP
pendiente** — el alcance acordado (seis marcas, 180 PDFs, 10.442 páginas) está
íntegramente ingerido:

| ZIP | Docs | Págs facturadas | Estado |
|---|---|---|---|
| `01_ingesta.zip` | 62 | 3.447 de 3.615 est. | **hecho** — `BulkUpload` 10 `complete`, 0,0246/pág |
| `07_ingesta.zip` | 4 | 301 de 319 est. | **hecho** — `BulkUpload` 11 `complete`, **0,0514/pág** (nuevo techo, ver nota de cierre) |

Lo que queda abierto ya no es ingesta — es la lista de [Fuera de la
ingesta](#fuera-de-la-ingesta) de abajo.

### Fuera de la ingesta

Corpus paralelo en legacy (no es este piloto): los manuales de Jesús Graterol se
ingerieron el 31-ago en `danebo-legacy` (account 1) — ver
[`INGESTA_PILOTO_JESUS_2026-08-31.md`](INGESTA_PILOTO_JESUS_2026-08-31.md).

1. **Usuarios nominales**: falta el nombre y correo de cada ingeniero. El plan de
   agosto exige usuarios atribuibles; no entregar credenciales compartidas.
2. **Manuales que Gonzalo dijo que faltaban**: si llegan, se re-corre el script y
   se ingiere sólo lo nuevo — el dedupe por cuenta evita pagar dos veces.
3. **`ReconcileBedrockCostJob`** sigue fallando con `AccessDenied` en
   `s3:ListBucket`: sin auditoría autoritativa del gasto de Bedrock.
4. **Devise `trackable`**: decidir si se añade o se acepta el hueco de login.
5. **`BulkUploadsController#create` busca por `sha256` global** — hay que
   resolverlo antes de reactivar la UI de `/bulk_uploads` (T-31).

### Resueltos

- **22-ago:** OOM del worker en submission (swap de 4 GB + `memory: 2g`),
  submission no atómica (`claude_batch_ids` grupo a grupo), tolerancia del parser
  a claves y tipos alucinados, cola `solid_queue_recurring` sin consumidor.
- **24-ago** (`bc3bf7d`, ver [Cierre de `BulkUpload` 8](#cierre-de-bulkupload-8-tras-el-fix-de-memoria-24-ago)):
  OOM al reintentar páginas — `each_page(only:)` acota el retry y la poda de `/B`
  baja la extracción por página 355×. Con eso, `03` re-ingerido y `04a`, `05` y
  `06` cerrados `complete`.
- **24-ago:** `04b_ingesta.zip` (`BulkUpload` 9) cerrado `complete`, primer ZIP
  multi-documento sobre `bc3bf7d`. Sin hallazgos de código; el ritmo de
  0,0470/pág y el 73,8% de Opus son los más altos medidos, explicados por la
  fracción de páginas escaneadas del ZIP, no por un defecto — ver
  [nota de coste](#04b-el-ritmo-más-caro-medido-hasta-ahora-00470pág-24-ago).
- **24-ago:** `01_ingesta.zip` (`BulkUpload` 10) cerrado `complete`, la tanda
  más grande del piloto y el único riesgo técnico abierto. Pico de memoria del
  worker 836,8 MiB de 2 GiB (41%), muy por debajo del 97% que rozó `05` pese a
  tener el doble de páginas — **el frente de memoria de la submission queda
  cerrado**. Coste 0,0246/pág, prácticamente el ritmo medio real. Sin
  hallazgos de código: los 20 `dropped_field_records` caen en tolerancias ya
  cerradas el 22-ago, ninguno `STOP_WORK_CONDITION` — ver
  [nota de cierre](#01-cierra-el-frente-de-memoria-de-la-submission-24-ago).
- **24-ago:** `07_ingesta.zip` (`BulkUpload` 11) cerrado `complete`, la última
  tanda del piloto y la primera con PDFs troceados por rango de página (los
  dos manuales de OTIS sobre 50 MB). Sin presión de memoria ni disco. Coste
  0,0514/pág y 100% Opus — nuevo techo por encima de `04b`, explicado por que
  los dos únicos documentos del ZIP son escaneos completos, mismo gate de
  código que gobierna todas las tandas anteriores. Los 5 `dropped_field_records`
  caen en tolerancias ya cerradas, ninguno `STOP_WORK_CONDITION`. Hallazgo de
  producto (no de código): cada mitad partida se indexa como documento
  independiente y `page_number` es local a la parte, sin offset hacia la
  página real del manual completo — ver
  [nota de cierre](#07-cierra-el-piloto-nuevo-techo-de-coste-00514pág-24-ago).
  **Con esto, la ingesta del piloto queda completa: nueve tandas, cero ZIPs
  pendientes.**

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
