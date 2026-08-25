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
| Crédito Anthropic disponible | **US$116,78** (menos **US$0,3162** gastados por el Paso 2 → ~US$116,46) |
| Tandas de ingesta `complete` | **10** (BulkUploads 2–11 + **12**, cuenta 3, `piloto.danebo.ai`) — actualizado 2026-08-25 por el Paso 2 |
| Deploy vigente | **`56a68fb`** (desplegado 2026-08-25 por el Paso 2; antes `bc3bf7d`) |
| Presupuesto del plan | **~US$3,2** (re-ingesta **US$0,3162 medido** + batería &lt;US$3 + diagnóstico **US$0,00**) — corregido 2026-08-25 por el Paso 1: los 3 PDFs son de **3 páginas en total**, no 60 |

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
| 1 | Fix de `PageRelevanceFilter` | claude-opus-5-thinking-high | **hecho** (2026-08-25, desplegado en el Paso 2) |
| 2 | Re-ingesta de los 3 PDFs | claude-sonnet-5-thinking | **hecho** (2026-08-25) — desplegado `56a68fb`, 3/3 assets `complete`, US$0,3162 all-in |
| 3 | Devise trackable | claude-sonnet-5-thinking | **hecho** (2026-08-25) — `9085408`, migración `20260825183000` **sin desplegar** (va con el Paso 4) |
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

- **AWS** — **corregido 2026-08-25 (Paso 2, segunda sesión). Leer esto antes de
  tocar infra; la instrucción anterior era la causa del bloqueo.**
  `bin/stack` y `kamal` necesitan el perfil **`default`** de
  `~/.aws/credentials` (`arn:aws:iam::935142957735:user/Lahiri`), que es el que
  tiene `ssm:GetParameter`, EC2, RDS y `scheduler`.
  **No sourcear `.env` antes de `bin/stack` ni de `kamal`:** las `AWS_*` de
  `.env` son de `bedrock-integration-user`, alcanzado sólo para Bedrock, y
  **pisan el perfil `default`**, produciendo `AccessDenied` /
  `UnauthorizedOperation` que parecen políticas incompletas y no lo son. No hace
  falta exportarlo: `.kamal/secrets` lee las claves de la app del **fichero**
  `.env`. El perfil `smart_deal` tiene claves muertas
  (`InvalidClientTokenId`) — ignorarlo.
  Si `bin/stack` falla con un error de credenciales, revisar primero
  `env | grep AWS_` en la shell.
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

**Estado:** **hecho** (2026-08-25, segunda sesión). Deploy `56a68fb` en
producción, `BulkUpload 12` `complete`, los **3 assets `complete` con
`error_message` nulo**, 12 chunks bajo `bulk_chunks/3/`, KB reindexada y
retrieval verificado para los tres ficheros. Coste medido **US$0,3162 all-in**
(umbral de parada US$1, no se acercó). **El hueco de contenido del piloto está
cerrado:** ya no queda ningún asset en toda la base con
`bulk_uploads.all_pages_filtered`.

> **El bloqueo de la primera sesión no era un permiso IAM que faltara: eran
> las credenciales equivocadas.** Ver el Hallazgo 1 de la segunda sesión. La
> sección "Qué faltaba" original queda **obsoleta** y se sustituye más abajo;
> el registro de la primera sesión se conserva como historia porque su
> diagnóstico de kamal (Hallazgos 2 y 3) sigue siendo válido.

### Primera sesión (2026-08-25) — bloqueada, se conserva como registro

**Comandos ejecutados:**

```bash
# 1. Verificación local antes de tocar producción
bin/rails test                                              # 2.444 runs, 0 failures, 0 errors, 189 skips

# 2. Armado y verificación de 08_recuperacion.zip (desde los ZIPs ya subidos, no del Drive)
unzip -o -j tmp/gonzalo_zips/02_ingesta.zip \
  "BLT/BLT/05.- BLT-ES_PLC input.pdf" "BLT/BLT/08.- BLT-ES_PLC output.pdf" -d tmp/recuperacion
unzip -o -j tmp/gonzalo_zips/04b_ingesta.zip "BLT/Conectores QS.pdf" -d tmp/recuperacion
shasum -a 256 tmp/recuperacion/*.pdf
cd tmp/recuperacion && zip -j ../gonzalo_zips/08_recuperacion.zip \
  "05.- BLT-ES_PLC input.pdf" "08.- BLT-ES_PLC output.pdf" "Conectores QS.pdf"
bin/rails runner 'ZipExtractionService.new("tmp/gonzalo_zips/08_recuperacion.zip").each_entry { |e| puts e.except(:binary) }'

# 3. Preflight de infra — bin/stack no funciona (ver Hallazgo 1), preflight hecho por SSH directo
ssh -i ~/.ssh/smart-deal-deploy.pem ubuntu@54.163.248.39 "docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'"
ssh ... "docker exec smart-deal-web-bc3bf7d... bin/rails runner '... SolidQueue::*Execution.count ...'"

# 4. Commit del fix del Paso 1 (estaba en el árbol sin commitear)
git add -A && git commit -F /tmp/commit_msg.txt          # 56a68fb, rubocop 0 offenses

# 5. Deploy — FALLÓ
bundle exec kamal deploy
#  -> nuevo contenedor smart-deal-web-56a68fb... crash-loop:
#     "ArgumentError: Missing `secret_key_base` for 'production' environment"
#  -> kamal detectó el fallo de healthcheck (30s) y NO promovió el contenedor nuevo:
#     el contenedor viejo (bc3bf7d) siguió corriendo, kamal-proxy no cambió de target.

# 6. Diagnóstico de la causa raíz — confirmado, no es un defecto de código
set -a; source .env; set +a
aws ssm get-parameter --name /smart-deal/master_key --with-decryption \
  --query 'Parameter.Value' --output text --region us-east-1
#  -> AccessDeniedException: bedrock-integration-user no tiene ssm:GetParameter
#     sobre arn:aws:ssm:us-east-1:935142957735:parameter/smart-deal/master_key

# 7. Verificación de que producción quedó sana tras el intento fallido
curl -s -o /dev/null -w '%{http_code}' https://piloto.danebo.ai/users/sign_in   # 200
ssh ... "docker ps --format '{{.Names}}\t{{.Status}}'"                          # web/worker bc3bf7d "Up", kamal-proxy "Up"
ssh ... "docker exec kamal-proxy kamal-proxy list"                              # target -> bc3bf7d, state running, TLS yes
```

**Hallazgos:**

**1. Las credenciales AWS de `.env` (`bedrock-integration-user`) están
alcanzadas sólo para Bedrock, no para infra.**

> ⚠️ **Superado 2026-08-25 (segunda sesión).** La observación es correcta, pero
> la conclusión que sacó — "falta un permiso IAM, hace falta una persona con
> acceso a IAM" — **es falsa**. El error estaba en *usar* esas credenciales:
> `source .env` pisa el perfil `default`, que sí tiene todos los permisos.
> `bin/stack` y `kamal deploy` funcionan sin cambiar ninguna política. Ver el
> Hallazgo 1 de la segunda sesión. No pedir permisos a nadie.

Confirmado con errores
`AccessDenied`/`UnauthorizedOperation` explícitos (no ambiguos) en:
`ec2:DescribeInstances`, `rds:DescribeDBInstances`,
`scheduler:ListSchedules`, y **`ssm:GetParameter`** sobre
`/smart-deal/master_key` (probablemente también sobre `/smart-deal/db_password`,
mismo mecanismo en `.kamal/secrets`, no probado explícitamente porque el primer
fallo ya bloqueaba el deploy). Consecuencia doble:

- `bin/stack` (`status`/`up`/`hold`/`release`/`ssh-ip`) **no funciona** con
  estas credenciales — todo el preflight de este paso se hizo con SSH directo
  en su lugar (funciona: la clave `~/.ssh/smart-deal-deploy.pem` sí tiene
  acceso).
- **`kamal deploy` falla al arrancar el contenedor nuevo.** `.kamal/secrets`
  resuelve `RAILS_MASTER_KEY` con
  `aws ssm get-parameter --name /smart-deal/master_key --with-decryption`, que
  con las credenciales de `.env` devuelve un `AccessDeniedException` en stderr
  y **cadena vacía en stdout** — kamal no lo trata como error fatal en esta
  fase, lo inyecta como env var vacía, y Rails aborta al arrancar con
  `Missing secret_key_base for 'production' environment` porque no puede
  descifrar `config/credentials.yml.enc` sin la master key real.

**No es un problema del fix del Paso 1 ni del código de la aplicación.** El
`Dockerfile`/`config/deploy.yml` no cambiaron de forma relevante a este fallo;
es puramente el secreto vacío en tiempo de arranque.

**2. Kamal se comportó exactamente como debía — cero impacto en producción.**
El contenedor nuevo (`smart-deal-web-56a68fb...`) no pasó el healthcheck de
`kamal-proxy` (`GET /up`, timeout 30s) porque nunca llegó a levantar el
servidor Puma (murió en el boot de Rails). Kamal:
- no detuvo el contenedor viejo (`bc3bf7d`, que siguió `Up` durante y después
  del intento),
- no cambió el target de `kamal-proxy` hacia el contenedor roto,
- dejó el contenedor fallido en `Exited (1)` (housekeeping pendiente, ver
  Pendientes abajo),
- liberó el deploy lock y salió con código de error, tal como se espera de un
  rollback automático sano.

**Verificado al cierre:** `http_code=200` en `https://piloto.danebo.ai/users/sign_in`,
`web`/`worker` de `bc3bf7d` `Up`, `kamal-proxy` `Up`, con
`kamal-proxy list` apuntando al contenedor de `bc3bf7d`. **El fix del Paso 1
NO está en producción todavía** — sigue desplegado el código anterior al
commit `56a68fb`.

**3. Hallazgo colateral, no causado por esta sesión: `kamal-proxy` llevaba
~17h caído antes de empezar.** El preflight (antes de tocar nada) encontró
`kamal-proxy` en `Exited (0)` y `https://piloto.danebo.ai` respondiendo
*connection refused* en el 443 (ni siquiera 502) — un incidente de
producción preexistente, no relacionado con el Paso 2. El intento de deploy
disparó `kamal proxy boot`, que restauró `kamal-proxy` con su estado de
enrutamiento persistido (apuntando al contenedor `bc3bf7d`, el único sano en
ese momento). **Efecto neto: el sitio quedó mejor que como se encontró**
(HTTP 200 en vez de connection refused), aunque sigue sirviendo el código
viejo. No se investigó por qué `kamal-proxy` se había caído — la sesión que
retome el deploy debería confirmar que no vuelve a pasar tras el próximo
`kamal deploy` exitoso.

**4. Un perfil AWS alterno (`smart_deal` en `~/.aws/credentials`, distinto de
`default`) existe pero **queda sin verificar** — no asumir que sirve.**
Se probó brevemente con resultados inconsistentes (un `sts:get-caller-identity`
falló con `InvalidClientTokenId` pero un `ssm:get-parameter` con el mismo
`--profile` pareció devolver un valor) y la sesión se cortó a mitad de una
verificación limpia (variables `AWS_*` sin exportar, un comando por vez). La
hipótesis más probable es que ese perfil requiera login interactivo (SSO) que
se cuelga en un shell no interactivo — pero **no está confirmado**. La
siguiente sesión debe volver a probarlo desde cero, en un shell limpio
(`env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN aws sts
get-caller-identity --profile smart_deal`) antes de confiar en él para nada.

**5. Estado verificado de producción al cierre de esta sesión (no repetir el
preflight, partir de aquí):**

| Comprobación | Valor |
|---|---|
| HTTP | `200` en `https://piloto.danebo.ai/users/sign_in` |
| Deploy vigente | `bc3bf7d` (sin cambios — el fix del Paso 1 no llegó) |
| `web`/`worker` `bc3bf7d` | `Up`, ~1h en el momento de la verificación |
| `kamal-proxy` | `Up`, target apunta a `bc3bf7d`, TLS `yes` |
| Contenedor fallido `smart-deal-web-56a68fb...` | `Exited (1)`, no limpiado — no bloquea nada, housekeeping pendiente |
| SolidQueue | `ready=0 scheduled=0 claimed=0 blocked=0` |
| `BulkUpload` en `pending`/`processing` | 0 |
| `FailedExecution` | 5 (las mismas ya conocidas, ninguna nueva) |
| Commit local | `56a68fb` en `main`, **1 commit por delante de `origin/main`** (no se hizo push) |
| `08_recuperacion.zip` | armado y verificado en `tmp/gonzalo_zips/08_recuperacion.zip`, SHA-256 del ZIP `ea3dc023906f475e...` — **no subido a S3 todavía** |
| Gasto Anthropic de esta sesión | **US$0,00** — el job de ingesta nunca se lanzó (correctamente bloqueado detrás del deploy) |

### Segunda sesión (2026-08-25) — paso cerrado

**Comandos ejecutados:**

```bash
# 1. Diagnóstico de credenciales (coste US$0,00) — desmonta la hipótesis del permiso IAM
env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN -u AWS_PROFILE \
  aws sts get-caller-identity --profile smart_deal --region us-east-1
#  -> InvalidClientTokenId: el perfil alterno tiene claves muertas (cierra el Hallazgo 4)
env -u AWS_ACCESS_KEY_ID ... aws sts get-caller-identity --profile default --region us-east-1
#  -> arn:aws:iam::935142957735:user/Lahiri  <-- identidad DISTINTA y con permisos
for P in master_key db_password; do
  aws ssm get-parameter --name /smart-deal/$P --with-decryption \
    --query 'Parameter.Value' --output text --profile default --region us-east-1
done
#  -> ambos resuelven (len 32 y 16). NO falta ningún permiso IAM.

# 2. Preflight de infra — bin/stack SÍ funciona con la identidad correcta
bin/stack status   # ec2 running / rds available / http 200 / 0 en vuelo
#  -> danebo-stop-{ec2,rds} ya estaban DISABLED: el gate `hold` ya estaba satisfecho

# 3. Deploy — OK a la primera, SIN sourcear .env
bundle exec kamal deploy          # Finished all in 59.3 seconds
curl -s -o /dev/null -w '%{http_code}' https://piloto.danebo.ai/users/sign_in   # 200
ssh ... "docker exec kamal-proxy kamal-proxy list"   # target -> 56a68fb, running, TLS yes
# guard verificado dentro de la imagen desplegada:
#   has_guard_method=true has_scanned_dense=true src_has_guard=true

# 4. Staging del ZIP (sin gasto Anthropic, sin arrancar proceso)
ZIP=tmp/gonzalo_zips/08_recuperacion.zip; SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
aws s3 cp "$ZIP" "s3://multimodal-source-destination/bulk_upload_archives/$SHA.zip" \
  --content-type application/zip

# 5. Gate humano -> confirmado. Lanzamiento fijado al rol web, script por stdin.
#    (Era un one-off, ya borrado; el cuerpo exacto fue este, con guard de idempotencia)
#      abort "..." if BulkUpload.exists?(sha256: sha)
#      user = User.find_by!(email: "gonzalo.campos@danebo.ai")
#      bu = BulkUpload.create!(user:, sha256: sha,
#             original_filename: "08_recuperacion.zip", status: "pending")
#      ProcessBulkUploadJob.perform_later(bu.id, "bulk_upload_archives/#{sha}.zip", "es")
ssh ... "docker exec -i smart-deal-web-56a68fb... bin/rails runner -" < <one-off>
#  -> bulk_upload_id=12, ProcessBulkUploadJob encolado en bulk_ingestion

# 5b. El sync a la KB falló una vez (Aurora auto-pausada, ver Hallazgo 5) y se reintentó:
#      SolidQueue::FailedExecution...where(class_name: "IngestBatchResultsJob").last.retry

# 6. Seguimiento y verificación (toolkit existente, ningún script nuevo)
ssh ... "docker exec -i -e BULK_UPLOAD_ID=12 -e FOLLOW=true ... bin/rails runner -" \
  < script/bulk_upload_status.rb
ssh ... "docker exec -i -e BULK_UPLOAD_ID=12 ... bin/rails runner -" \
  < script/bulk_upload_cost_audit.rb
aws bedrock-agent get-ingestion-job --knowledge-base-id Y7RZWMFJSR \
  --data-source-id PJ0N58DMHG --ingestion-job-id DVWMKTVZJW --region us-east-1
aws bedrock-agent-runtime retrieve --knowledge-base-id Y7RZWMFJSR \
  --retrieval-configuration '{"vectorSearchConfiguration":{"numberOfResults":5,
    "filter":{"equals":{"key":"account_id","value":"3"}}}}' ...   # x3 consultas
```

**Hallazgos:**

**1. El bloqueo NO era un permiso IAM que faltara: era la identidad
equivocada.** Es el hallazgo que ahorra más trabajo futuro. En
`~/.aws/credentials` hay tres identidades y sólo una sirve:

| Identidad | Origen | `ssm:GetParameter` | `bin/stack` |
|---|---|---|---|
| `bedrock-integration-user` | **`.env`** (gitignorado) | no | no |
| `user/Lahiri` | perfil **`default`** | **sí** | **sí** |
| perfil `smart_deal` | `~/.aws/credentials` | claves muertas (`InvalidClientTokenId`) | no |

La primera sesión hizo `set -a; source .env; set +a` **antes** de `kamal deploy`,
y esas variables `AWS_*` **pisan el perfil `default`**, así que todo el
`AccessDenied` observado era el usuario de Bedrock hablando, no una política
incompleta. **Regla operativa: no sourcear `.env` antes de `kamal` ni de
`bin/stack`.** No hace falta: `.kamal/secrets` lee `ANTHROPIC_API_KEY`,
`APPSIGNAL_PUSH_API_KEY` y `MISSION_CONTROL_JOBS_*` del **fichero** `.env` con
`grep`/Ruby, no del entorno exportado, así que con la shell limpia se resuelven
igual los secretos de la app **y** los de infra. Con eso `kamal deploy` pasó a
la primera en 59,3 s y `bin/stack` funciona completo. **No hay que pedir ningún
permiso IAM a nadie** — queda anulado el punto 1 de la lista de desbloqueo de la
primera sesión, y con él el `smart_deal` del Hallazgo 4 (descartado, no volver a
probarlo).

**2. El gate `hold` ya estaba satisfecho, y eso destapa una fuga de coste
ajena a este paso.** `bin/stack status` reporta `danebo-stop-ec2` y
`danebo-stop-rds` **DISABLED** desde antes de esta sesión (ninguna sesión de
este plan los tocó: la primera no podía por credenciales, esta no necesitó
hacerlo). Efecto: los schedules de **arranque** siguen `ENABLED` y los de
**parada** no, así que **la infra no se apaga a las 18:00 — lleva días
corriendo 24/7** y facturando EC2 + RDS fuera de la ventana 10:00–18:00 CLT.
No se ejecutó `bin/stack release` en esta sesión **a propósito**, por dos
razones: el Paso 6 (batería de precisión) necesita la infra arriba, y
re-habilitar la parada es una decisión de coste del dueño del proyecto, no de
este paso. **Acción pendiente para el humano / Paso 7:** decidir cuándo correr
`bin/stack release`. Mientras siga así, ningún paso necesita `hold`.

**3. La re-ingesta confirma el fix del Paso 1 de punta a punta.** Los tres
assets recorrieron `in_batch → parsed → syncing → complete`, cuando antes morían
en el filtro sin llegar a batch:

| Asset | Fichero | `canonical_name` | Chunks | `chunks_s3_prefix` |
|---|---|---|---|---|
| 11 | `05.- BLT-ES_PLC input.pdf` | BLT Escalator PLC Input Diagram | 5 | `bulk_chunks/3/50e921385b8b…` |
| 12 | `08.- BLT-ES_PLC output.pdf` | BLT PLC Output Wiring Diagram | 2 | `bulk_chunks/3/ddae9a0f9af5…` |
| 112 | `Conectores QS.pdf` | Conectores QS Catedral DHT-070187T | 5 | `bulk_chunks/3/6bcb89e82e7f…` |

Los tres cumplen el criterio estricto heredado del Paso 1: `status ==
"complete"` **y** `error_message` **nulo** — es decir, la corrección (e) del
Paso 1 (limpiar el `error_message` viejo al reutilizar la fila) también quedó
verificada en producción. **`BulkUploadAsset.where("error_message LIKE
'%all_pages_filtered%'").count == 0`**: no queda rastro del fallo en toda la
base. Los assets `failed` totales bajan de **5 a 2**, y los dos que quedan son
ajenos a este paso (`otis_2000.pdf`, un `field_record` desconocido; y
`V3F18 MX05 MX06 MX10.pdf`, el `No space left on device` del 2026-08-22).

**4. Coste medido: US$0,3162 all-in / US$0,1054 por página — el doble de la
estimación, y la razón está identificada.** Muy por debajo del umbral de parada
de US$1, así que no hubo que parar:

| Concepto | Valor |
|---|---|
| Batch (`claude-sonnet-4-6-batch`) | US$0,1606 (3 páginas) |
| Ruta directa `bulk_retry` (1 llamada) | US$0,1556 (**+96,9%** sobre el batch) |
| **Total all-in** | **US$0,3162** → **US$0,1054/pág** |
| Share Opus | **0/3 páginas (0,0%)** |

El share Opus 0% y `force_opus: false` confirman la expectativa (f) del plan:
100% Sonnet. El sobrecoste viene entero de **una** llamada `bulk_retry`: una
página se truncó en el batch y `retry_truncated_pages!` la reintentó por la ruta
directa, que se paga ~2x. Es coherente con lo que son estos ficheros — tablas de
E/S densas (8.000–17.600 tokens de entrada por página) que topan `max_tokens`.
Nota para el Paso 5: **US$0,1054/pág no es representativo del corpus**; es el
peor caso de una tanda de 3 páginas donde una sola retry pesa un tercio del
total.

**5. Incidente resuelto: la KB de Bedrock vive sobre Aurora Serverless v2 con
auto-pausa, y eso rompe la sincronización de toda tanda que tarde >5 min.** Es
el hallazgo que más afecta a los pasos siguientes.
`IngestBatchResultsJob(12)` falló una vez con:

```
Aws::BedrockAgent::Errors::ValidationException
The knowledge base storage configuration provided is invalid...
The vector database encountered an error while processing the request:
Client execution did not complete before the specified timeout
configuration: 28000 millis
```

Causa raíz medida: los dos clusters `knowledgebasequickcreateaurora-*` están
configurados con **`MinCapacity: 0.0`** y **`SecondsUntilAutoPause: 300`**. El
parseo de la tanda duró ~10 min (10:41→10:51) con el vector store inactivo, así
que Aurora se auto-pausó a 0 ACU; cuando `BulkKbSyncService#sync!` llamó a
`StartIngestionJob`, Bedrock se encontró el cluster frío y agotó su timeout
interno de 28 s. **No es un defecto del código ni del fix del Paso 1.**

Reintentar fue seguro y suficiente (`SolidQueue::FailedExecution#retry`), y lo
fue por una propiedad concreta del job que conviene conocer antes de repetirlo:
`IngestBatchResultsJob` construye su `asset_map` sólo con assets
`status: "in_batch"`, y en el reintento los tres ya estaban `parsed`, así que
**saltó todo el parseo de resultados y fue directo al sync** — cero llamadas a
Anthropic, cero doble conteo de tokens. El reintento resolvió en segundos
(`bedrock_ingestion_job_id=DVWMKTVZJW`) y `FailedExecution` volvió a su línea
base de 5.

**Consecuencia para el Paso 6 y para cualquier ingesta futura:** una tanda que
tarde más de 5 minutos en parsear puede volver a fallar el sync por lo mismo. No
es una regresión que haya que arreglar en este paso, pero **quien vea ese
`ValidationException` no debe tratarlo como corrupción de datos: es una pausa de
Aurora, y el reintento del job es la respuesta correcta.** Arreglo de fondo, si
llega a molestar: subir `MinCapacity` por encima de 0 o alargar
`SecondsUntilAutoPause` en los clusters de la KB.

**6. KB reindexada y retrieval verificado para los tres ficheros.** Job de
ingesta `DVWMKTVZJW`: `status=COMPLETE`, **12 documentos nuevos indexados**, que
son exactamente los 5+2+5 chunks de esta tanda (cada uno con su
`.metadata.json`, `account_id: "3"`, `ingestion_contract_version:
field_records_v8`). El job reporta también `numberOfDocumentsFailed: 1` sobre
13.968 escaneados: **no es de esta tanda** — los 12 chunks nuestros están todos
contabilizados como indexados; pertenece a otro documento del data source y es
preexistente. `KbDocument` de la cuenta 3: **183**.

Retrieval con filtro `account_id = 3` (`Retrieve` puro, sin generación, sin fila
en `bedrock_queries` por la regla de coste del AGENTS raíz):

| Consulta | Fichero recuperado | Score |
|---|---|---|
| "entradas y salidas del PLC del escalador BLT, señales Omron" | `05.- BLT-ES_PLC input.pdf` p1 | 0,431 |
| "salidas del PLC BLT-ES output bobinas contactores" | `08.- BLT-ES_PLC output.pdf` p1 | 0,440 |
| "conectores QS identificación de bornes y pines" | `Conectores QS.pdf` p1 | 0,564 |

Los tres son recuperables, que es lo que este paso tenía que demostrar. Nota
honesta para el Paso 6: en las dos consultas de PLC los ficheros nuevos entran
**por debajo** de `Planos BLT.pdf` y de los listados de fallas, que puntúan
0,49–0,56. Aparecen en top-5, no en top-1. La batería del Paso 6 debe medir
esto con sus propios criterios en vez de dar por hecho que el hueco cerrado
implica top-1.

**7. Lo que NO se hizo, dicho explícitamente:**

- **`bin/worker_watch` no se corrió.** 3 páginas y 12 chunks no ejercen ni el
  cgroup de 2 GiB ni el disco; el pico de memoria del worker **no está medido**
  para esta tanda. Si el Paso 6 o una ingesta futura mueven volumen de verdad,
  hay que correrlo — no reutilizar la ausencia de incidente de aquí como
  evidencia.
- **`pdf_split_peak_audit.rb` no se corrió**, según la corrección (c) de este
  mismo paso (3 páginas de 10–65 KB, no es gate).
- **`bin/stack release` no se corrió**, deliberadamente (ver Hallazgo 2).
- **El contenedor muerto no se borró a mano**: `kamal deploy` lo renombró a
  `…_replaced_86014db5906d9bb3` y su fase de *prune* lo limpió sola, así que el
  punto 3 de la lista de desbloqueo ya no aplica.
- **`git push` no se hizo.** El commit `56a68fb` **está desplegado en
  producción pero sigue sin estar en `origin/main`** (`main` va 1 commit por
  delante). Conviene empujarlo antes de que otra sesión trabaje sobre el
  repositorio remoto.

---

## Paso 3 — Devise trackable

**Objetivo:** Habilitar Devise `:trackable`: migración (`sign_in_count`, `current_sign_in_at`, `last_sign_in_at`, `current_sign_in_ip`, `last_sign_in_ip`), descomentar `:trackable` en `app/models/user.rb`, test Minitest de que el login puebla contadores/fechas. **No desplegar** — el deploy va junto con el Paso 4 (un solo redeploy).

**Modelo asignado:** claude-sonnet-5-thinking

**Estado:** **hecho** (2026-08-25). Migración `20260825183000_add_trackable_to_users.rb`
aplicada en local (reversible, verificada con `db:rollback:primary`), `:trackable`
activo en `app/models/user.rb`, 4 tests de integración nuevos. Suite completa
verde: **2.448 runs, 9.343 assertions, 0 failures, 0 errors, 189 skips** (los
mismos 189 skips de antes; +4 runs son los de este paso). Commiteado en
**`9085408`**, **sin desplegar y sin push**, según el plan: el deploy va con el
Paso 4. Coste Anthropic/Bedrock del paso: **US$0,00** (ninguna llamada externa).

**Comandos ejecutados:**

```bash
bin/rails db:migrate                        # add_column x5 sobre users
bundle exec rubocop -A --cache false db/schema.rb   # ver Hallazgo 1
bin/rails test test/integration/user_trackable_test.rb   # 4 runs, 19 assertions
bin/rails test                              # suite completa: 2.448 runs, 0 failures, 0 errors
bundle exec rubocop --cache false app/models/user.rb \
  db/migrate/20260825183000_add_trackable_to_users.rb \
  test/integration/user_trackable_test.rb   # sin ofensas

# Reversibilidad (app multi-DB: db:rollback exige el namespace)
bin/rails db:rollback:primary STEP=1 && bin/rails db:migrate
```

**Hallazgos:**

**1. `db/schema.rb` hay que pasarlo por rubocop después de migrar, o el diff
crece 44 líneas de puro espacio en blanco.** El fichero versionado usa el estilo
`t.index [ "slug" ], …` (espacios dentro de los corchetes, de
`rubocop-rails-omakase`), pero el volcado del schema dumper los escribe sin
espacios, así que un `db:migrate` limpio reescribe **todos** los `t.index` del
fichero. `db/schema.rb` está en el `Exclude` de `.rubocop.yml`, pero un fichero
pasado **explícitamente** en la línea de comandos se inspecciona igual (rubocop
sólo respeta el `Exclude` para argumentos explícitos con `--force-exclusion`), así
que `bundle exec rubocop -A db/schema.rb` restaura el estilo. Con eso el diff del
paso queda en **6 líneas** (la versión + las 5 columnas), que es lo que se puede
revisar de un vistazo. Vale para cualquier migración futura de este repo.

**2. `sign_in_count` cuenta credenciales aceptadas, no sesiones en este host — y
es una limitación estructural, no un bug que se pueda arreglar aquí.**
`Users::SessionsController#create` llama primero a `warden.authenticate!`, y el
hook `after_set_user` de Devise (`update_tracked_fields!`) corre **dentro** de esa
llamada; el rechazo por `account_id != host_account.id` viene después, con el
contador ya incrementado. Un login de un usuario de otra cuenta queda registrado
como sign-in aunque la sesión se cierre acto seguido. Está documentado con un test
(`a login rejected by host mismatch still counts as a sign-in`) para que nadie lo
descubra leyendo métricas. **Impacto en el piloto: nulo** — los usuarios de Gonzalo
son de la cuenta 3 y entran por `piloto.danebo.ai`, así que la rama de mismatch no
se ejerce. No se corrigió a propósito: saltarse el tracking requeriría
`devise.skip_trackable` **antes** de autenticar (que apagaría el tracking de todos
los logins) o deshacer las columnas tras el `sign_out` (queries extra en el hot
path del login para un caso que el piloto no produce).

**3. No hay doble conteo.** El `sign_in(resource_name, resource)` explícito que
hace el controlador después de `warden.authenticate!` **no** vuelve a disparar el
hook: `Devise#sign_in` no llama a `warden.set_user` cuando
`warden.user(scope) == resource` y no se pasa `force`. Verificado por test: un
login por formulario deja `sign_in_count == 1`, no 2. El segundo login rota bien
(`last_sign_in_at` recibe el `current_sign_in_at` anterior, contador a 2).

**4. La migración llega a producción sola con el deploy del Paso 4 — no hay paso
manual.** `bin/docker-entrypoint` corre `./bin/rails db:prepare` cuando el comando
del contenedor es `./bin/rails server`, así que el `kamal deploy` del Paso 4 la
aplica al arrancar el contenedor web. `add_column` de un `integer NOT NULL DEFAULT
0` no reescribe la tabla en PostgreSQL 11+, y `users` en producción tiene un puñado
de filas, así que el bloqueo es instantáneo. **Ojo con el orden**: si el Paso 4 añade
su tabla de eventos, ambas migraciones se aplican en el mismo arranque; conviene que
la sesión del Paso 4 corra `bin/rails test` con las dos ya aplicadas antes de
desplegar.

**5. Nadie consume todavía estas columnas, y el histórico anterior al deploy no
existe.** `PilotMetricsReport` deriva la adopción de `ConversationSession` y de los
logs, no de `users`; las cinco columnas nacen en `0`/`nil` para los usuarios ya
creados, así que **los logins previos al deploy no son recuperables**. Lo que este
paso habilita es exactamente el hueco que
[`docs/INGESTA_PILOTO_GONZALO_2026-08-20.md`](INGESTA_PILOTO_GONZALO_2026-08-20.md)
(línea ~1299) daba por abierto: verificar "quién entró y cuándo" con
`users.current_sign_in_at` / `sign_in_count` en vez de rebuscar en un log Docker que
rota a los 10 MB. El Paso 4 debería decidir si además emite un evento de login en la
tabla durable (el contador de Devise no da la **serie temporal**, sólo el último
acceso y el total).

**6. Nota de entorno para las siguientes sesiones.** En este entorno el shell trae
`BUNDLE_PATH`/`GEM_SPEC_CACHE` apuntando a una caché temporal vacía, y todo comando
de Ruby muere con `Bundler::GemNotFound` listando el Gemfile entero. No es que
falten gems: basta prefijar con `env -u BUNDLE_PATH -u GEM_SPEC_CACHE`.

**Ficheros tocados** (commit `9085408`, sin desplegar: el Paso 4 hace el único
deploy):

| Fichero | Cambio |
|---|---|
| `db/migrate/20260825183000_add_trackable_to_users.rb` | nuevo: las 5 columnas de `:trackable` |
| `db/schema.rb` | versión + 5 columnas en `users` (6 líneas) |
| `app/models/user.rb` | `:trackable` añadido a `devise …` |
| `test/integration/user_trackable_test.rb` | nuevo: 4 tests (primer login, segundo login, password incorrecta, mismatch de host) |

---

## Paso 4 — Telemetría durable, frente B

**Objetivo:** Implementar la tabla de eventos de piloto en RDS según `docs/rag/plan_telemetria_durable_piloto_2026-08-19.md` (jsonb + `account_id`, `event_type`, `occurred_at`) para persistir lo que hoy solo va a `Rails.logger` (`PilotAuditLog`, `PilotUsageLog`, `[RAG_QUALITY]`). Escritura en el mismo ciclo que el log (un INSERT, sin job extra ni broadcast). Tests de persistencia y de queries del hot path. Deploy junto con el Paso 3 previa confirmación humana. Mantener `bin/pilot_metrics_daily` como respaldo hasta una semana de datos en la tabla.

### Notas heredadas del Paso 3 (2026-08-25) — leer antes de ejecutar

**a) El Paso 3 ya está commiteado (`9085408`) pero no desplegado.** Migración
`20260825183000_add_trackable_to_users.rb`, `:trackable` en `User`,
`test/integration/user_trackable_test.rb` y las 6 líneas de `db/schema.rb`. El
deploy de este paso es el que lleva las dos cosas a producción; correr
`bin/rails test` con **ambas** migraciones aplicadas antes de desplegar.
`bin/docker-entrypoint` hace `db:prepare` al arrancar el contenedor web, así que
las migraciones se aplican solas — no hay `kamal app exec db:migrate` que correr.

**b) Después de `db:migrate`, pasar `bundle exec rubocop -A db/schema.rb`**, o el
volcado reescribe 44 líneas de `t.index` sólo por el espaciado (Hallazgo 1 del
Paso 3).

**c) El contador de Devise no da serie temporal.** `sign_in_count` +
`current_sign_in_at` dicen "cuántas veces y la última"; si la telemetría del piloto
necesita "logins por día", eso es un evento en la tabla durable de este paso.

**d) `main` va 3 commits por delante de `origin/main`** (`56a68fb` del Paso 1/2,
`9085408` del Paso 3 y el commit de este documento): `56a68fb` está desplegado sin
estar en el remoto. El push sigue pendiente de decisión humana.

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

### Notas heredadas del Paso 2 (2026-08-25) — leer antes de ejecutar

**a) El gate está cumplido:** Paso 2 `hecho`, deploy `56a68fb` en producción con
el guard del Paso 1 verificado dentro de la imagen, y los 3 PDFs de E/S de PLC
BLT ya recuperables en la cuenta 3.

**b) Las preguntas de BLT deben medir ranking, no sólo presencia.** El retrieval
de cierre del Paso 2 encontró los tres ficheros nuevos en top-5 pero **por
debajo** de `Planos BLT.pdf` y de los listados de fallas (0,43–0,56 frente a
0,49–0,56). Cerrar el hueco de contenido **no** implica top-1: conviene que la
batería incluya preguntas de E/S de PLC BLT y reporte la posición, no un
booleano.

**c) Si el sync de la KB falla con `ValidationException` / "vector database …
28000 millis", no es corrupción:** son los clusters Aurora Serverless v2 de la
KB con `MinCapacity: 0.0` y `SecondsUntilAutoPause: 300`, que se auto-pausan.
Reintentar el job es la respuesta correcta (detalle en el Hallazgo 5 del Paso 2).

**d) `bin/stack hold` no hace falta hoy:** `danebo-stop-{ec2,rds}` están
`DISABLED` desde antes del Paso 2, así que la infra no se apaga a las 18:00.
Es también una fuga de coste pendiente de decisión humana — ver Hallazgo 2 del
Paso 2.

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
