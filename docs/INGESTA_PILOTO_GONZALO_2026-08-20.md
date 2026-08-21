# Ingesta piloto Gonzalo (2026-08-20)

**Estado: validación superada.** Alcance cerrado en seis marcas, tenant piloto
desplegado y `00_validacion.zip` ingerido con aislamiento entre tenants
verificado. Los seis ZIPs de ingesta están armados y pendientes de arrancar, con
el presupuesto revisado al alza (ver más abajo).

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

### El coste medido no cuadra con el estimado

La validación (27 páginas reales, batch `msgbatch_01Bw3jABL34nKXhf3AmccDUF`) dio
**US$1,0877, o US$0,0403/página — un 49% por encima de los US$0,027 asumidos**:

| Modelo | Págs | Input | Output | Cache lect. | Cache escr. | USD | USD/pág |
|---|---|---|---|---|---|---|---|
| `claude-opus-4-8` | 10 | 17.811 | 28.162 | 33.536 | 50.304 | 0,5621 | 0,0562 |
| `claude-sonnet-4-6` | 17 | 40.426 | 49.614 | 51.066 | 45.392 | 0,5255 | 0,0309 |
| **Total** | **27** | | | | | **1,0877** | **0,0403** |

El coste por página depende de a qué modelo enruta `FileMultimodalRouter`: Opus
(multimodal) cuesta el doble por página que Sonnet (texto).

Extrapolado, el alcance completo son **~US$421**, y los créditos cargados cubren
unas **9.234 páginas (88% del corpus)**. Además la cifra es un piso, no un techo:
`00_validacion.zip` se armó con los PDFs **más livianos** de cada marca, y el peso
de KONE son planos y esquemas — justo lo que va a Opus.

Los ZIPs están troceados en checkpoints de US$15–127 para poder parar al agotar
créditos sin perder lo ya procesado.

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
por páginas antes de meterlos en un ZIP. Son 927 páginas, ~US$33.

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

## Pendientes

1. **Validación sin cerrar**: confirmar `complete` en `00_validacion.zip` y los dos
   controles de aislamiento antes de gastar los ~US$365 restantes.
2. **Usuarios nominales**: falta el nombre y correo de cada ingeniero.
3. **Manuales que Gonzalo dijo que faltaban**: si llegan, se re-corre el script y
   se ingiere sólo lo nuevo — el dedupe por cuenta evita pagar dos veces.
4. **Los dos PDFs de OTIS sobre 50 MB**: 927 páginas de material técnico que
   quedaron fuera y requieren partirse por páginas.

## Notas operativas

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

**`ReconcileBedrockCostJob` está fallando.** `AccessDenied` en `s3:ListBucket` para
el rol `smart-deal-ec2-role`. Es la reconciliación de coste que las reglas del
proyecto tratan como autoridad sobre las estimaciones por tokens, así que ahora
mismo no hay auditoría del gasto real de Bedrock.

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
