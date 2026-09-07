# Ingesta piloto Jesús → `danebo-legacy` (2026-08-31)

**Estado: CERRADA.** Dos tandas `complete`, 16/16 assets, chunks bajo
`bulk_chunks/1/`, gasto all-in **US$14,11** (techos US$0,060/pág y US$50
acumulados respetados). Corpus paralelo en legacy respecto al piloto de
Gonzalo — ver
[`INGESTA_PILOTO_GONZALO_2026-08-20.md`](INGESTA_PILOTO_GONZALO_2026-08-20.md).

## Destino

| Recurso | Valor |
|---|---|
| `Account` | `danebo-legacy` (id **1**) |
| `User` | `jesus.graterol@danebo.ai` (id **6**, ya existía) |
| Host | `elevator.danebo.ai` |
| Prefijo chunks | `bulk_chunks/1/…` |
| Fuente | `…/Manules Jesus` (typo en disco) |
| Knowledge Base | `Y7RZWMFJSR` / data source bulk `PJ0N58DMHG` |

Password temporal: **no se generó uno nuevo** — el user id=6 ya existía en
account 1. Credenciales previas siguen vigentes (fuera de git).

## Decisión Monarch near-dupe

Dos PDFs de 219 páginas, SHA-256 distintos:

| Archivo | Págs | MB | SHA-256 |
|---|---|---|---|
| `Monarch nice 3000.pdf` | 219 | 12,4 | `0c99f1fe…` |
| `Manual_monarch_Español_3000+.pdf` | 219 | 10,1 | `31df6013…` |

Muestreo denso (págs 1, 50, 100, 150, 219) + normalización de whitespace:
diffs triviales de OCR/espaciado (`NICE3000new` vs `NICE3000 new`, bullets
unicode, reorden de columnas de tablas con los mismos códigos F6/FA/FP). Conteos
de caracteres del texto completo ~364 733 vs ~364 454; diff normalizado del
documento entero = 6 líneas. **Mismo manual, distinta exportación** (caso análogo
al KONE LCE de Gonzalo).

**Decisión: EXCLUIR** `Monarch nice 3000.pdf` (el más pesado). Movido a
`…/Danebo RAG elevator  Agosto/_jesus_excluded/` (no borrado). Se conservan
`Manual_monarch_Español_3000+.pdf` + `Monarch nice 3000 fallas-1.pdf`.

## Alcance post-exclusión

| | Valor |
|---|---|
| PDFs | **16** |
| Páginas | **613** (832 − 219) |
| Ilegibles HexaPDF | 0 |
| Excluidos por tamaño | 0 |
| Colisiones basename | 0 |
| Candidato `all_pages_filtered` | `Citifono.pdf` (1 pág) — **no filtrado**; cerró `complete` |

## Prep local (Fase 0)

| ZIP | PDFs | Págs | Pico disco | Extractor |
|---|---|---|---|---|
| `00_validacion.zip` | 4 | 67 | **0,01 GB** | OK |
| `01_ingesta.zip` | 12 | 546 | **0,09 GB** | OK |

`pdf_split_peak_audit` contra `DISK_FREE_GB=10` → **exit 0** (presupuesto 7,00 GB).
Artefactos: `tmp/jesus_zips/{00_validacion,01_ingesta}.zip`, `manifest.json`,
`scope.json`.

## Tandas de producción

| ZIP | `BulkUpload` | Assets | Págs fact. | All-in USD | USD/pág | % Opus | Pico mem worker | Estado |
|---|---|---|---|---|---|---|---|---|
| `00_validacion.zip` | **13** | 4/4 complete | 66 | **1,7810** | **0,0270** | 7,6% | ~735 MiB / 2 GiB | `complete` |
| `01_ingesta.zip` | **14** | 12/12 complete | 524 | **12,3329** | **0,0235** | 3,4% | **~888 MiB / 2 GiB** | `complete` |
| **Total** | | **16/16** | **590** | **14,1139** | **0,0239** | | | |

Autoridad de coste: `script/bulk_upload_cost_audit.rb` (batch + `page_filter`;
sin `bulk_retry` en ninguna tanda).

Gates de coste: ninguna tanda > US$0,060/pág; acumulado ≪ US$50.

### Detalle `00` (BU 13)

- SHA-256 ZIP: `de2b6b35dd4f6dfd4e39525399174c8a677244517ed002f9404b2341e4919cd9`
- batch US$1,6431 + non-batch US$0,1379 (`page_filter` ×5)
- `dropped_field_records`: 0
- Prefijos: todos `bulk_chunks/1/…`
- Duración ~12 min (creación → `complete`)

### Detalle `01` (BU 14)

- SHA-256 ZIP: `6ccece123d81e88f36fef94d17bd87a7561c06c0867b9cf9aa0bfb21d42b5759`
- batch US$11,0382 + non-batch US$1,2946 (`page_filter` ×34, +11,7%)
- 6 batches; `dropped_field_records`: 0 (ningún `STOP_WORK_CONDITION`)
- Prefijos: 12/12 bajo `bulk_chunks/1/…`
- Duración ~23 min
- Sin `WORKER_ALERT` / `DISK_ALERT`

## Retrieval

Filtro `account_id=1` verificado (AWS CLI + `BedrockRagService#retrieve_chunks`).

Query post-`00`: *"inspección foso reducido eléctrico control"* → top-5 =
`CONTROL_20INSPECCION_20FOSO_20REDUCIDO_20ELECTRICO.pdf` bajo
`bulk_uploads/1/2026-08-31/…` / `bulk_chunks/1/…`.

Query post-`01`: *"códigos de falla NICE3000 Monarch controlador"* → top-5 =
`Monarch nice 3000 fallas-1.pdf` (Err51/52/53, niveles de fallo NICE3000),
metadato de tenant 1. Sin mezcla de `account_id` de otros tenants.

`KbDocument` count account 1 al cierre: **19**.

## Fallos

Ninguno. 16/16 assets `complete`. `Citifono.pdf` (1 pág), candidato a
`all_pages_filtered` por el patrón BLT/Conectores QS de Gonzalo, **pasó el
filtro** y se facturó US$0,0660.

## Operativa

- Identidad AWS: `arn:aws:iam::935142957735:user/Lahiri` (sin sourcear `.env`)
- `bin/stack hold` aplicado (`danebo-stop-ec2` / `danebo-stop-rds` DISABLED)
- Cola SolidQueue vacía antes y después; 0 uploads en vuelo al terminar
- `bin/worker_watch` corriendo durante ambas tandas; sin alertas
- Sin redeploy; sin bumpear `INGESTION_CONTRACT_VERSION`
- Create/enqueue fijados a contenedor `role=web`

## Checklist

- [x] Monarch decidido y documentado (excluido el más pesado)
- [x] `scope.json` + `manifest.json` + extractor OK
- [x] `pdf_split_peak_audit` exit 0
- [x] User `jesus.graterol@danebo.ai` en account 1 (id 6, preexistente)
- [x] `bin/stack status` OK + hold satisfecho
- [x] `00` complete + cost audit + retrieve account 1 OK
- [x] `01` complete + cost audit OK
- [x] Todos los `chunks_s3_prefix` bajo `bulk_chunks/1/`
- [x] Doc cerrado + link en `docs/README.md`
- [x] Password: user ya existía — no se rotó; nada nuevo fuera de git que entregar
- [x] Sin `WORKER_ALERT` / sin uploads en vuelo al terminar
