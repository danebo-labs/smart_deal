# Plan de liberación del piloto Gonzalo — documento vivo (2026-08-25)

**Naturaleza:** única fuente de verdad dinámica de la ejecución. Cada paso se corre en una sesión propia, con el modelo asignado. El plan estático de origen es `.cursor/plans/liberación_piloto_gonzalo_bf68cf2e.plan.md`; este documento lo sustituye para el estado operativo.

**Paso 0 (este documento):** cerrado 2026-08-25.

---

## Protocolo multi-modelo

1. **Antes de empezar**, toda sesión lee este documento **completo** (no el plan estático ni la memoria del chat).
2. **Antes de terminar**, la sesión actualiza su sección: `Estado` (`hecho` / `bloqueado` / `desviado`), `Comandos ejecutados`, `Hallazgos`, y cualquier cifra medida.
3. Si un hallazgo **invalida un paso posterior**, se edita la sección de ese paso en este mismo documento, marcando el cambio con **fecha** — el siguiente modelo lo hereda sin depender del chat.
4. No se salta un gate explícito (p. ej. Paso 2 exige Paso 1 `hecho`; Paso 6 exige Paso 2 `hecho`; Paso 7 exige Pasos 2, 3, 4 y 6 `hecho` y batería por umbrales).
5. **Toda sesión que toque producción** (Pasos 2, 3, 4, 6 y 7) pasa antes el
   preflight de infra y usa el toolkit existente. Está escrito una sola vez, en el
   [Preflight de infra del Paso 2](#preflight-de-infra-en-producción-obligatorio-antes-de-desplegar):
   EC2/RDS arriba con `bin/stack` (la infra **no** está encendida de forma continua:
   se apaga a las 18:00 de Chile), dónde viven las credenciales, y la regla de
   **reutilizar los scripts de `script/AGENTS.md` sin crear ninguno nuevo**.

---

## Cifras de partida (2026-08-25)

| Concepto | Valor |
|---|---|
| Crédito Anthropic disponible | **US$116,78** |
| Tandas de ingesta `complete` | **9** (BulkUploads 2–11, cuenta 3, `piloto.danebo.ai`) |
| Deploy vigente | **`bc3bf7d`** |
| Presupuesto del plan | **~US$3,2** (re-ingesta **~US$0,15** + batería &lt;US$3 + diagnóstico **US$0,00**) — corregido 2026-08-25 por el Paso 1: los 3 PDFs son de **3 páginas en total**, no 60 |

**Corrección de cifra (2026-08-25, Paso 1).** El presupuesto original asumía
~US$3 de re-ingesta porque el plan y
[`docs/INGESTA_PILOTO_GONZALO_2026-08-20.md`](INGESTA_PILOTO_GONZALO_2026-08-20.md)
daban "60 páginas" a los dos PDFs de BLT. Es un error de transcripción: el
inventario del corpus (`tmp/gonzalo_zips/scope.json`, con los SHA-256 que se
ingirieron) registra `pages: 1` para los tres ficheros. El hueco de contenido son
**3 páginas**, no 60.

---

## Estado de ejecución

| Paso | Título | Modelo asignado | Estado |
|---|---|---|---|
| 1 | Fix de `PageRelevanceFilter` | claude-opus-5-thinking-high | **hecho** (2026-08-25, sin desplegar) |
| 2 | Re-ingesta de los 3 PDFs | claude-sonnet-5-thinking | pendiente |
| 3 | Devise trackable | claude-sonnet-5-thinking | pendiente |
| 4 | Telemetría durable (frente B) | claude-sonnet-5-thinking-xhigh | pendiente |
| 5 | Actualizar costes medidos en docs | composer-2.5-fast | pendiente |
| 6 | Batería de precisión (gate) | claude-sonnet-5-thinking-xhigh | pendiente |
| 7 | Liberación | claude-sonnet-5-thinking (+ humano) | pendiente |

---

## Paso 1 — Fix de `PageRelevanceFilter` (único hueco de contenido)

**Objetivo:** Diagnosticar y arreglar por qué el filtro descartó el 100% de las páginas de tres PDFs de tablas de E/S de PLC (`05.- BLT-ES_PLC input.pdf`, `08.- BLT-ES_PLC output.pdf` — 60 págs, tanda `02`; `Conectores QS.pdf` — tanda `04b`), fallidos con `bulk_uploads.all_pages_filtered`. Fix quirúrgico recomendado: guard fail-open a nivel documento (`:all_pages_filtered_guard`) + tests; sin bump de `INGESTION_CONTRACT_VERSION`; sin deploy (el deploy es del Paso 2). Verificar en lectura que `ContentDedupService` no cortocircuita assets `failed` (el Paso 2 depende de eso).

**Modelo asignado:** claude-opus-5-thinking-high

**Estado:** **hecho** (2026-08-25). Código y tests en el árbol, **sin desplegar** — el deploy es del Paso 2. Suite completa verde: 2.444 runs, 9.324 assertions, 0 failures, 0 errors, 189 skips (los mismos skips de antes del cambio).

**Coste real del paso: US$0,00.** El diagnóstico no necesitó ni una llamada a Haiku, porque el descarte es determinista. El presupuesto asumía "centavos".

**Comandos ejecutados:**

```bash
# Los 3 PDFs se sacan de los ZIPs que realmente se subieron, no del Drive:
# así el binario diagnosticado es byte a byte el que falló (SHA-256 verificado).
unzip -o -j tmp/gonzalo_zips/02_ingesta.zip \
  "BLT/BLT/05.- BLT-ES_PLC input.pdf" "BLT/BLT/08.- BLT-ES_PLC output.pdf" -d tmp/prf_diag
unzip -o -j tmp/gonzalo_zips/04b_ingesta.zip "BLT/Conectores QS.pdf" -d tmp/prf_diag

# Diagnóstico por página (coste cero: no llama a Haiku)
bin/rails runner tmp/prf_diag/dump_pages.rb     # texto, líneas, densidad, heurística que dispara
bin/rails runner tmp/prf_diag/geometry.rb       # señal geométrica del triaje visual + veredicto del router web
bin/rails runner tmp/prf_diag/verify_guard.rb   # end-to-end con el fix, aborta si intenta llamar a Haiku

bin/rails test test/services/page_relevance_filter_test.rb        # 67 runs, 288 assertions
bin/rails test test/services/batch_ingestion_service_test.rb test/services/content_dedup_service_test.rb
bin/rails test   # suite completa: 2.444 runs, 0 failures, 0 errors
bundle exec rubocop --cache false <ficheros tocados>              # sin ofensas
```

El Drive local de manuales, para futuras sesiones:
`/Users/lahirisan/Documents/Danebo/Danebo RAG elevator  Agosto/Manuales Gonzalo`
(dos espacios entre "elevator" y "Agosto", no es un typo).

**Hallazgos:**

**1. Los tres PDFs son de UNA página, no de 60.** Es el hallazgo que más cambia el
plan. Tres fuentes independientes lo confirman con los mismos SHA-256 que se
ingirieron: `HexaPDF` y `PDF::Reader` sobre el binario extraído del ZIP subido,
el inventario `tmp/gonzalo_zips/scope.json`, y el `manifest.json` que viaja dentro
de `02_ingesta.zip` y `04_ingesta.zip`. La cifra "60 páginas" de
[`docs/INGESTA_PILOTO_GONZALO_2026-08-20.md`](INGESTA_PILOTO_GONZALO_2026-08-20.md)
no tiene respaldo en ninguna fuente y es un error de transcripción. **El hueco de
contenido del piloto son 3 páginas.**

**2. El descarte viene de una heurística, `toc?`, no del prompt de Haiku.** Los
tres cayeron por `reason: :table_of_contents`, con **cero llamadas a Haiku** — lo
que explica el "sin coste" que ya registraba el runbook. La causa es un falso
positivo perfectamente explicable: una tabla de E/S de PLC tiene ≥10 líneas y la
mayoría acaban en un número de señal o de borne, que es exactamente la firma que
`toc?` usa para reconocer un índice con números de página.

| Fichero | Págs | Chars | Líneas | Acaban en dígito | Fracción (umbral 0,30) |
|---|---|---|---|---|---|
| `05.- BLT-ES_PLC input.pdf` | 1 | 10.174 | 89 | 32 | **0,360** |
| `08.- BLT-ES_PLC output.pdf` | 1 | 8.778 | 88 | 31 | **0,352** |
| `Conectores QS.pdf` | 1 | 5.618 | 103 | 33 | **0,320** |

Las tres pasan el umbral por poco, y ninguna tiene imágenes
(`image_area_ratio = 0,000`). Como `apply_heuristics` corre **antes** de
`high_confidence_content`, los 10.174 caracteres de tabla densa no salvan la
página: el `toc?` gana primero.

**3. Dos partes del fix propuesto quedaron invalidadas por la medición.**

- **La línea en `HAIKU_BATCH_SYSTEM` no se añadió, y era correcto no añadirla.**
  Un documento de una página va por el camino por página, no por `call_batch`, así
  que ese prompt **nunca se invoca** para estos ficheros. Tocarlo habría sido un
  cambio sin efecto sobre el fallo real.
- **El guard NO puede limitarse a documentos multipágina.** Tal como lo describía
  el plan, no habría arreglado ninguno de los tres. Un documento de una página es
  precisamente el caso donde un solo descarte pierde el documento entero.

**4. El camino web/chat ya era inmune, y por dos mecanismos distintos.**
`FileMultimodalRouter#classify_pdf` devuelve `mode: :pdf_text_only` cuando
`total_pages <= 1`, así que `PageRelevanceFilter` **ni se llama** para estos
ficheros (verificado: los tres clasifican `pdf_text_only` / Sonnet). Y para
multipágina, `SingleFileChunkingService#handle_pdf_mixed` ya tenía su propio
fail-open a nivel documento (`kept_pages.empty?` → parseo del fichero completo, o
keep-all por página si supera la ventana). **El hueco era exclusivo del camino
bulk**, donde `BulkCostV2RequestBuilder#build_for_pdf` trocea y filtra incluso con
`total_pages == 1` y devuelve `[[], []]`, que `BatchIngestionService` traduce a
`failed`.

Consecuencia menor y deliberada: con el guard en `filter_pages`, el fallback de
`handle_pdf_mixed` queda inalcanzable en producción (nunca verá `kept_pages`
vacío). No se retira: sus tests lo siguen ejerciendo porque stubean
`filter_pages`, y quitarlo sería un cambio de comportamiento del camino web sin
motivo en este paso.

**5. La opción de reutilizar el T2 vision se midió y NO discrimina aquí.** El
criterio geométrico es `long_segments >= 10 AND small_images >= 3`, y estas
páginas son tablas vectoriales sin componentes rasterizados:

| Fichero | `long_segments` | `small_images` | ¿Elegible T2? |
|---|---|---|---|
| `05.- BLT-ES_PLC input.pdf` | 145 | **0** | no |
| `08.- BLT-ES_PLC output.pdf` | 84 | **0** | no |
| `Conectores QS.pdf` | 15 | **0** | no |

Las otras dos ramas de `VisionTopologyExtractor.eligible?` tampoco disparan
(`text_layer_chars < 100` falla con 5.618–10.174 chars). Además hay un impedimento
de política sobre el de medición: `VisionTopologyExtractor` está anotado **"NEVER
AT RUNTIME"** y cuesta una llamada Opus de visión por página. Queda descartado por
las dos razones.

**6. El fix implementado.** Guard fail-open a nivel documento en
`PageRelevanceFilter.filter_pages`, para **cualquier número de páginas**: si
ninguna página sobrevive, se conservan todas con `reason:
:all_pages_filtered_guard` y un log estructurado
(`event: "page_relevance_filter_all_pages_filtered_guard"` con `filename`, `pages`
y el recuento de motivos de descarte). Sólo dispara cuando la alternativa es cero
contenido, así que no puede ensanchar el gasto normal del filtro.

Dos detalles que importan para la calidad:

- El guard **recupera `force_opus`** para las páginas que rescata, usando el mismo
  corte de siempre (`text_layer_chars < 100 && image_area_ratio > 0.7`). Sin eso,
  un documento escaneado rescatado por el guard iría entero a Sonnet, porque en el
  camino bulk `force_opus` es la **única** vía a Opus para páginas de PDF. Los tres
  PDFs del piloto salen `force_opus: false`, que es lo correcto: tienen capa de
  texto y van a Sonnet.
- Se unificó el umbral: `BatchFilter#scanned_dense?` (privado, duplicado) se
  sustituyó por `PageRelevanceFilter.scanned_dense?`, para que exista un único
  sitio donde vive ese corte.

**No se tocó** `INGESTION_CONTRACT_VERSION`, ni `safety_action_guard?`, ni
`section_identity_guard?`, ni `toc?`, ni `TOC_LINE_FRACTION` (verificado sobre el
diff). El dedupe por `(cuenta, SHA-256, contrato)` sigue válido.

**7. Verificación end-to-end sobre los binarios reales.** Con el fix, y con
`Anthropic::Client.new` sobrescrito para abortar si alguien intenta una llamada:

```
05.- BLT-ES_PLC input.pdf    páginas=1 kept=1 reason=all_pages_filtered_guard force_opus=false
08.- BLT-ES_PLC output.pdf   páginas=1 kept=1 reason=all_pages_filtered_guard force_opus=false
Conectores QS.pdf            páginas=1 kept=1 reason=all_pages_filtered_guard force_opus=false
llamadas a Haiku intentadas: 0
```

**8. Riesgo residual que el guard NO cubre, anotado a propósito.** `toc?` sigue
teniendo el falso positivo. En un PDF **multipágina** de tablas de E/S, el filtro
descartaría las páginas-tabla una por una y, si alguna otra página sobrevive, el
guard **no** dispara: se perdería contenido en silencio, sin `failed` que avise.
No se endureció `toc?` en este paso por una razón concreta: `toc?` es una
dependencia de `safety_action_guard?` y de `section_identity_guard?`, así que
cambiarlo altera el comportamiento de dos guards de seguridad y el coste de todo
el corpus, y eso exige la batería del Paso 6 como red, no una sesión de fix
quirúrgico. Queda como candidato post-piloto, con la medición ya hecha (fracciones
0,32–0,36 contra el umbral 0,30) para que quien lo tome no repita el trabajo.

**9. `ContentDedupService` no cortocircuita assets `failed` — confirmado, y hay
más.** Ver la nota para el Paso 2 justo debajo.

**Tests añadidos** (`test/services/page_relevance_filter_test.rb`, 6 casos):
guard sobre documento de una página con texto **verbatim** de `Conectores QS.pdf`
(con una aserción que falla si el fixture deja de disparar `toc?`, para que la
regresión no se vuelva vacía en silencio); guard sobre multipágina 100%
descartado; no-disparo cuando sobrevive una página; recuperación de `force_opus`
en páginas escaneadas; el log estructurado y su contenido; y que `call_batch` por
sí solo **no** aplica el guard (el guard vive en `filter_pages`).

---

## Paso 2 — Re-ingesta de los 3 PDFs

**Objetivo:** Desplegar el fix del filtro (cola Solid Queue vacía) y re-ingerir los 3 PDFs vía `08_recuperacion.zip` en la cuenta piloto (Account 3, `piloto.danebo.ai`), siguiendo el runbook de `docs/INGESTA_PILOTO_GONZALO_2026-08-20.md`. Verificar assets `complete`, chunks bajo `bulk_chunks/3/`, audit de coste, y retrieval de E/S PLC BLT. Confirmación humana antes del deploy y del job.

### Correcciones heredadas del Paso 1 (2026-08-25) — leer antes de ejecutar

**a) El coste esperado baja de ~US$2–3 a ~US$0,15.** Son **3 páginas** en total
(una por PDF), no 60. Incluso al peor ritmo medido del piloto (0,0514/pág de la
tanda `07`), la re-ingesta cuesta ~US$0,15. **Nuevo umbral de parada: US$1.** Si el
audit de coste devuelve algo del orden de dólares, no es "más caro de lo previsto":
es la señal de que se está re-procesando algo que no toca, y hay que parar y mirar
antes de seguir.

**b) `08_recuperacion.zip` no existe todavía**: `tmp/gonzalo_zips/` no lo contiene.
Hay que armarlo con los tres ficheros, que se extraen de los ZIPs ya subidos (no
del Drive, para que el binario sea byte a byte el que falló y el dedupe por SHA-256
se comporte como se espera):

```bash
unzip -o -j tmp/gonzalo_zips/02_ingesta.zip \
  "BLT/BLT/05.- BLT-ES_PLC input.pdf" "BLT/BLT/08.- BLT-ES_PLC output.pdf" -d tmp/recuperacion
unzip -o -j tmp/gonzalo_zips/04b_ingesta.zip "BLT/Conectores QS.pdf" -d tmp/recuperacion
```

SHA-256 esperados (verificados contra los manifests de los ZIPs subidos):

| Fichero | Págs | SHA-256 (12) |
|---|---|---|
| `05.- BLT-ES_PLC input.pdf` | 1 | `50e921385b8b` |
| `08.- BLT-ES_PLC output.pdf` | 1 | `ddae9a0f9af5` |
| `Conectores QS.pdf` | 1 | `6bcb89e82e7f` |

**c) No hace falta `pdf_split_peak_audit.rb` con criterio de riesgo**: 3 páginas de
PDFs de 10–65 KB no tienen presupuesto de disco que discutir. Correrlo si se quiere
por disciplina de runbook, pero no es un gate aquí.

**d) El dedupe NO cortocircuita estos assets — verificado en lectura, y con un
matiz que importa.** `ContentDedupService.find_completed` filtra por
`BulkUploadAsset.complete`, así que un asset `failed` es MISS y el camino bulk
(`BatchIngestionService#process!`, que llama al mismo servicio) cae al parseo
normal. Ahora el matiz: `find_or_initialize_by(custom_id:)` **reutiliza la fila del
intento fallido** (mismo `custom_id`, porque es el mismo binario, contrato y
cuenta), reasignándola al nuevo `BulkUpload` con `status: "uploaded_s3"`, y
`submit!` la recoge por ese estado. Es decir: se re-parsea de verdad, y no se
duplica la fila.

**e) Corregido en el Paso 1 (fuera de `PageRelevanceFilter`): el
`error_message` viejo ya se limpia.** Esa reutilización de fila **no** borraba el
`error_message`, así que los tres assets habrían acabado en `complete` arrastrando
todavía el texto `bulk_uploads.all_pages_filtered`. `bulk_upload_status.rb` y la UI
habrían mostrado una fila que dice `complete` junto al fallo que la re-ingesta
acaba de arreglar — una falsa alarma justo en el paso que verifica el fix. Se añadió
`error_message: nil` a esa reasignación en `BatchIngestionService`, con test
(`process! clears the stale failure when it reuses a failed asset row`). **Al
verificar el Paso 2, el criterio es `status == "complete"` Y `error_message` nulo.**

**f) Los tres son `pdf_text_only` de una página con capa de texto**, así que la
expectativa es **100% Sonnet, 0% Opus** y `force_opus: false`. Un Opus aquí sería
señal de que algo no cuadra.

### Preflight de infra en producción (obligatorio, antes de desplegar)

**La infra no está encendida de forma continua.** Cuatro schedules de EventBridge
(`danebo-{start,stop}-{ec2,rds}`) la mantienen arriba de **10:00 a 18:00 hora de
Chile**, y las dos piezas se paran por separado: con RDS parada los contenedores
levantan pero `kamal-proxy` devuelve **502**. Fuera de esa ventana hay que
arrancarla a mano.

Todo se hace con [`bin/stack`](../bin/stack), que ya encapsula esto — **no escribir
comandos `aws` a mano**:

```bash
bin/stack status    # EC2, RDS, salud HTTP, uploads en vuelo y estado de los schedules
bin/stack up        # si está caída: autoriza tu IP en el 22, arranca RDS antes que EC2 y espera un 200
bin/stack hold      # deshabilita danebo-stop-{ec2,rds} ANTES de lanzar el job
bin/stack ssh-ip    # reautoriza tu IP pública en el puerto 22
bin/stack release    # repone los schedules al terminar
```

Gate para pasar del preflight: **EC2 `running`, RDS `available`, HTTP 200, 0
uploads en vuelo, cola SolidQueue en cero** y `hold` aplicado.

**`hold` no es opcional y la razón es dinero.** Si la infra se apaga a las 18:00 con
un batch en vuelo, los batches siguen procesándose y **facturándose** en Anthropic,
pero `PollClaudeBatchJob` tiene un `HARD_TIMEOUT` de 24h desde su primer intento: si
el worker vuelve pasado ese plazo, marca el upload como `failed` sobre resultados ya
pagados. Aquí son 3 páginas, así que el daño monetario sería mínimo, pero el
procedimiento es el mismo y un `failed` espurio confundiría la verificación del fix.

Recursos de producción, para reconocerlos en la salida:

| Recurso | Valor |
|---|---|
| Región | `us-east-1` |
| EC2 | `i-09db5c5fc53e973b0` |
| RDS | `smart-deal-db` |
| Security group | `sg-06d4cf4fc9a5e3749` |
| IP pública (elástica, sobrevive stop/start) | `54.163.248.39` |
| Host de la cuenta piloto | `piloto.danebo.ai` (Account **3**) |
| Deploy vigente antes de este paso | `bc3bf7d` |

### Dónde están las credenciales (ninguna va en este documento)

- **AWS** (lo que usa `bin/stack`): `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` /
  `AWS_REGION` viven en el **`.env` local**, que está gitignorado. Si `bin/stack`
  falla con un error de credenciales, el problema es el entorno de la shell, no el
  script.
- **SSH al host** (para el `docker exec` del toolkit): clave
  `~/.ssh/smart-deal-deploy.pem`, usuario `ubuntu@54.163.248.39`, puerto 22
  autorizado **por IP `/32`**. Trampa ya documentada: cuando el ISP rota la IP, el
  SSH **no se rechaza, se queda colgado** hasta el timeout de TCP. Si algo se
  cuelga, `bin/stack ssh-ip` antes de dar por roto nada más.
- **Secretos de la app en producción**: los gestiona kamal vía `.kamal/secrets`
  (`RAILS_MASTER_KEY`, `DB_PASSWORD`, `ANTHROPIC_API_KEY`, etc.). No hay que
  leerlos ni copiarlos para este paso.
- **Credenciales de Rails en local**: `config/credentials.yml.enc` +
  `config/master.key` (gitignorada).

### Monitorizar con el toolkit que ya existe — no crear scripts nuevos

Todo lo que este paso necesita observar ya tiene su herramienta, con tests, y el
inventario canónico está en [`script/AGENTS.md`](../script/AGENTS.md):

| Para | Usar | Efectos |
|---|---|---|
| Estado de la tanda, error de cada fallo, `dropped_field_records` | `script/bulk_upload_status.rb` (`FOLLOW=true` sondea hasta `complete`/`failed`) | sólo lectura |
| Coste all-in real (batch + rutas directas + tokens de caché) | `script/bulk_upload_cost_audit.rb` | sólo lectura |
| Memoria del worker contra su cgroup y caída del contenedor | `bin/worker_watch` | sólo lectura |
| Disco que escribirá el troceo | `script/pdf_split_peak_audit.rb` (no es gate aquí, ver (c)) | sólo lectura |
| Recuperar assets fallidos **con resultados ya devueltos** | `script/bulk_upload_recover_failed.rb` | **escribe** |

**`bulk_upload_recover_failed.rb` no sirve para este paso** y conviene saberlo antes
de intentarlo: recupera assets que fallaron *después* de que llegaran sus
resultados, y estos tres nunca produjeron ninguno. De ahí que la vía sea re-subir un
ZIP.

Dos trampas de ejecutar contra producción, ya pagadas con incidentes y detalladas en
[`script/AGENTS.md`](../script/AGENTS.md): **la imagen desplegada no contiene
`script/`**, así que el script se pasa por **stdin** (`docker exec -i … bin/rails
runner -` < script), y **hay que fijar el rol** (`--roles=web` o `docker exec` sobre
el contenedor web), porque `kamal app exec` corre en todos los roles y un `create!`
se ejecutaría dos veces. Un script pasado por stdin corre dentro de la imagen
desplegada, así que sólo puede llamar a clases que esa imagen contenga.

**Si falta una herramienta, no improvisar un script suelto**: la lógica reusable va a
`app/services` con test y el script queda como envoltorio (regla de
`script/AGENTS.md`). Y **no desplegar para conseguir un script con un ZIP en vuelo**:
un deploy reinicia el worker y reactiva el `HARD_TIMEOUT` de 24h.

### Cierre del paso: actualizar este documento en vivo

Antes de terminar la sesión, rellenar aquí `Estado`, `Comandos ejecutados` y
`Hallazgos` con las cifras **medidas** (páginas facturadas, USD all-in, USD/página,
share Opus, pico de memoria del worker, `chunks_s3_prefix` y `kb_document_id` de cada
asset), y marcar el Paso 6 si algo de lo observado lo invalida. El protocolo del
encabezado aplica: el siguiente modelo hereda este documento, no el chat.

**Modelo asignado:** claude-sonnet-5-thinking

**Estado:** pendiente

**Comandos ejecutados:**

_(vacío)_

**Hallazgos:**

_(vacío)_

---

## Paso 3 — Devise trackable

**Objetivo:** Habilitar Devise `:trackable`: migración (`sign_in_count`, `current_sign_in_at`, `last_sign_in_at`, `current_sign_in_ip`, `last_sign_in_ip`), descomentar `:trackable` en `app/models/user.rb`, test Minitest de que el login puebla contadores/fechas. **No desplegar** — el deploy va junto con el Paso 4 (un solo redeploy).

**Modelo asignado:** claude-sonnet-5-thinking

**Estado:** pendiente

**Comandos ejecutados:**

_(vacío)_

**Hallazgos:**

_(vacío)_

---

## Paso 4 — Telemetría durable, frente B

**Objetivo:** Implementar la tabla de eventos de piloto en RDS según `docs/rag/plan_telemetria_durable_piloto_2026-08-19.md` (jsonb + `account_id`, `event_type`, `occurred_at`) para persistir lo que hoy solo va a `Rails.logger` (`PilotAuditLog`, `PilotUsageLog`, `[RAG_QUALITY]`). Escritura en el mismo ciclo que el log (un INSERT, sin job extra ni broadcast). Tests de persistencia y de queries del hot path. Deploy junto con el Paso 3 previa confirmación humana. Mantener `bin/pilot_metrics_daily` como respaldo hasta una semana de datos en la tabla.

**Modelo asignado:** claude-sonnet-5-thinking-xhigh

**Estado:** pendiente

**Comandos ejecutados:**

_(vacío)_

**Hallazgos:**

_(vacío)_

---

## Paso 5 — Actualizar los costes estimados con lo medido

**Objetivo:** Con base en 9.650 páginas facturadas / 9 tandas, añadir sección "Medido en piloto ago-2026" en `docs/SAAS_COST_MODEL_2026-06-12.md` y `docs/INGESTION_COST_V2.md` (media all-in US$0,0244/pág fuente; Sonnet/Opus batch; peaje Haiku 8–14%; rango por tanda). En `script/gonzalo_corpus_prep.rb` mantener `PRICE_PER_PAGE = 0.027` y anotar la media real en el comentario. No tocar cifras históricas de `INGESTA_PILOTO_GONZALO` (registro primario).

**Nota heredada del Paso 1 (2026-08-25).** La instrucción de "no tocar cifras
históricas de `INGESTA_PILOTO_GONZALO`" sigue en pie para las **mediciones de
coste**. Ya se corrigió allí una cosa que no era una medición sino un error: el
recuento de páginas de los 3 PDFs fallidos ("60 páginas" → 1 página cada uno), con
nota fechada y las tres fuentes que lo verifican. No revertirlo ni volver a
documentarlo. Ninguna cifra de coste por página cambia: esas 3 páginas nunca se
facturaron.

**Modelo asignado:** composer-2.5-fast

**Estado:** pendiente

**Comandos ejecutados:**

_(vacío)_

**Hallazgos:**

_(vacío)_

---

## Paso 6 — Batería de precisión (una sola ejecución, gate de liberación)

**Objetivo:** Construir y ejecutar una sola vez `script/pilot_release_precision_battery.rb`: 60 preguntas estratificadas por marca; retrieval top-5 ≥ 85% (cuenta 3); respuesta completa en subconjunto de 20 ≥ 80% (`Rag::BenchmarkRubricEvaluator`). Salida JSON en `tmp/` + resumen en este documento. Presupuesto &lt; US$3. Si un umbral falla, no liberar: analizar, anotar y marcar Paso 7 como `bloqueado`. Requiere Paso 2 `hecho`. Confirmación humana antes de gastar créditos.

**Modelo asignado:** claude-sonnet-5-thinking-xhigh

**Estado:** pendiente

**Comandos ejecutados:**

_(vacío)_

**Hallazgos:**

_(vacío)_

---

## Paso 7 — Liberación

**Objetivo:** Re-verificar gates (español por defecto, `PILOT_AUDIT_CAPTURE=true`) en el deploy vigente. Crear Users nominales con nombres/correos de Gonzalo (sin credenciales compartidas; si no llegan, `bloqueado`). Registrar decisión de producto: PDFs troceados se citan como "página N de la parte pX-Y" (revisable post-piloto). Dejar texto de comunicación con URL `piloto.danebo.ai` y cerrar este documento con el estado final. Requiere Pasos 2, 3, 4 y 6 `hecho` y batería por umbrales.

**Modelo asignado:** claude-sonnet-5-thinking (+ acción humana: credenciales, comunicación)

**Estado:** pendiente

**Comandos ejecutados:**

_(vacío)_

**Hallazgos:**

_(vacío)_
