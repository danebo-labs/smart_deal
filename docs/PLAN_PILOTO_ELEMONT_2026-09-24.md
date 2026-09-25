# Plan piloto Elemont MH — 2026-09-24

> **Documento vivo.** Escrito la noche del 23-sep-2026 contra `main 2d937df` (producción: imagen `2d456f8`) y la rama `fc/pr2` (`6c46aa5`, sin desplegar). Verificado contra S3 (`bulk_chunks/1/121bfffe0827f6bc681ba9bdc91050390055/`), sin Bedrock y sin cambios de código.
> Alcance: el piloto de mañana con Jesús Graterol (Elemont), cuenta `danebo-legacy` (`account_id` 1 en el índice), host `elevator.danebo.ai`, plano «Montacargas 2N Temporizado-1», 7 hojas, 9 chunks, `kb_document_id` 213.
> Este plan **no reabre** el [Plan maestro Field Companion](Plan%20maestro%20de%20implementaci%C3%B3n%20%E2%80%94%20Danebo%20.md) (parado en Fase 2b por FC-D10) ni el [plan copiloto](PLAN_COPILOTO_GENERACION_2026-09-22.md) (dueño de FC-D10 / CG-D19). Registra qué ya cubren y qué no.

---

## 0. Entrada disponible y hueco

- La revisión de 12 preguntas «sin fijar el documento» quedó reconstruida en P0.1 (sección 7). No está en el export por cohorte: la batería corrió por `rails runner` con `user_id` nulo (`mh_battery:1`–`12`, 23-sep 19:45 −03, imagen `2d456f8`). El export de las 19:36 no podía verla.
- La verdad-terreno del plano (hoja 2 designaciones, hoja 4 unilineal, hoja 5 seguridad, hoja 7 circuitos 5 y 6) queda copiada en la sección 6 y es la rúbrica de todo lo que sigue.

## 1. Diagnóstico por capa (verificado)

| ID | Capa | Hallazgo | Evidencia | ¿Ya lo cubre un plan? |
|---|---|---|---|---|
| **I1** | Indexación | El chunk de la hoja 1 (`chunk_p1_2.txt`) escribe **T1 = transformador 220VAC/18VCD** y **T2 = transformador 220VAC/24VAC** (l.24–25 y FIELD_RECORDs l.112, l.121). La hoja 2 (`chunk_p2_1.txt`) dice T1 y T2 = relés temporizadores. Misma bornera: hoja 1 pone **12 = SEGURIDAD IN, 13 = SEGURIDAD OUT** (l.61–62) y repite 22/23; la hoja 2 pone 12 = L electroválvula bajando, 23/24 = Seguridad OUT/IN. El documento se contradice a sí mismo. | SHA vivo = SHA local (`79300034…` p1_2, `cb7e2348…` p2_1). Ya salió en producción: sesión 5 de hoy, 11:05:44, la respuesta citó «transformadores T1 (220VAC/18VCD) y T2 (220VAC/24VAC)». | **No.** Restricción 13 del Plan maestro («no se escribe bajo `bulk_chunks/`») y CG-D02 del copiloto («no se parchean chunks») son restricciones **de esos planes**, no del producto. `app/services/rag/AGENTS.md` sí regula el parche de chunk (invalidar `SectionNeighborExpander`) y existe precedente: `script/patch_seguridades_chunk9_2026-07-26.rb` (PutObject + sync de un solo objeto, cero llamadas a Claude). |
| **I2** | Indexación → generación | Cada designación de la hoja 2 quedó como FIELD_RECORD `SCHEMATIC_LABEL` con **`EXPECTED_RESULT: DATA_NOT_AVAILABLE`** (Q1 l.186–188, Q2, Q3, K1, K7, T1…). `generation.txt` l.27 dice «If evidence is insufficient, say DATA_NOT_AVAILABLE». Es la hipótesis principal de **Q1**: hoja 2 citada y respuesta «no está documentado». | `chunk_p2_1.txt`; `generation.txt` l.27 y l.142 (gs-v1 intenta neutralizarlo: «a chunk's mark does not forbid a reference», y aun así abstuvo). | **Parcial.** CG-D08 cubre que la etiqueta no se muestre al técnico, no que la marca del chunk provoque la abstención. Sin medición. |
| **R1** | Recuperación | Sin pin, el retrieve es la base compartida (cuentas 1 + 3 + `manual_corpus=general`), `OPEN_RESULTS = 8`. Para Q2 (11–17 A) y Q3 (25 A 30 mA) la hoja 2 no entra y sí entran Monarch/Thyssen. «Elemont» no está en `KbDocumentResolver::BRANDS` ni auto-fija nada: por decisión, **una pregunta no fija un manual**. | Revisión Q2/Q3; `rag/AGENTS.md` «Manual corpus scope»; `rag_retrieval_profile.rb`. | **Sí, como decisión vigente:** el pin es el único filtro duro (restricción 5 del Plan maestro; `PINNED_DOCUMENT_RESULTS = 3`, 5 si la pregunta trae «falla/defecto/reparar»). No se cambia `top_k` (restricción 2; medición del 26-jul). La mitigación de mañana es operativa: **pin**. |
| **R2** | Recuperación con pin | Con pin, 3 de 9 chunks. Para preguntas de T1/T2 o bornes, entran **las dos hojas** (1 y 2) y el modelo recibe la contradicción de I1. El pin no resuelve I1; lo expone. | Estructura de los 9 chunks. | No. Depende de D1. |
| **G1** | Generación | Sin pin, la respuesta transplanta bornes y valores de otra marca al equipo del técnico (hoy 11:09: XB21/LCECCB y «6±1 mm» de KONE para un Elemont). Es FC-D10 / E27–E29. | Sesión 5, turno 25; `gate_2/run.json`. | **Sí:** FC-D10 → plan copiloto, V41–V45. FC-D12 implementado detrás de flag apagada y **la medición no pasó**. No hay nada desplegable para mañana. Con pin Elemont, el turno solo ve el plano y el transplante desaparece **para ese turno**. |
| **S1** | Sesión | La sesión 5 de Jesús acumula pines (Elemont + Crown FC-4000 + Excelsior 40/10 a las 11:02 de hoy), 20 mensajes mixtos y un `active_episode` shadow. Un pin viejo filtra en silencio (incidente del 16-sep). | `consolidado_piloto_2026-09-23.md` turnos 13–14; PLAN_QUIRURGICO_JESUS. | Parcial: E19 dejó `field_companion:reset_active_episode` (dry-run por defecto). Los pines se limpian por UI. |

## 2. Qué NO se hace antes del piloto

1. **No se despliega `fc/pr2`.** Producción sigue en `2d456f8` (Fase 1 shadow, E13). Las 14 commits de 2a/2b/FC-D12 quedan en la rama. Comitear antes de cualquier `kamal deploy` futuro (lección Fase 2 ciclo 4).
2. No se encienden `FIELD_COMPANION_TURN_ENABLED` ni `DOCUMENT_IDENTITY_SCOPE_ENABLED` (gate NO PASA, FC-D12 «medición no pasa»).
3. No se edita `generation.txt` (no hay tiempo de holdout; CG-D06 exige las pruebas de lo medido).
4. No se cambia `top_k`, `OPEN_RESULTS` ni `PINNED_DOCUMENT_RESULTS`.
5. No se reingiere el PDF ni se sube el `INGESTION_CONTRACT_VERSION`.

## 3. Fases

### P0 — Esta noche (sin deploy; Bedrock solo en P0.4 con tope)

**P0.1 Reconstruir las 12 preguntas.** Correr

```bash
bin/pilot_metrics --from 2026-09-23 --to 2026-09-23 --account danebo-legacy --with-questions
```

y volcar en la sección 7 las 12 filas con `correlation_id`, documentos citados, ruta y veredicto I/R/G contra la sección 6. Si el export de hoy no las trae (la corrida pudo ser de otra cuenta u otra ventana), ampliar `--to 2026-09-24` mañana temprano. Sin esto, Q4–Q12 quedan sin veredicto.

**P0.2 Preparar la sesión de Jesús (UI, cuenta legacy).** Despinnear Crown FC-4000/4500, Excelsior 40/10 PM y SEGURIDADES 1.1-1. Dejar pinneado **solo** «Elemont Montacargas Hidraulico Modelo MH» (doc 213). Verificar en el panel que el pin figura como fuente activa. Opcional: `bin/rails "field_companion:reset_active_episode[danebo-legacy,<email de Jesús>]"` en dry-run; con la turn flag apagada el episodio no se lee, así que no cambia respuestas y puede omitirse.

**P0.3 Decisión D1 — parche del chunk de la hoja 1 (I1).** Ver sección 4. Si se aprueba, ejecutar con el patrón del precedente:

1. Copiar `script/patch_seguridades_chunk9_2026-07-26.rb` a `script/patch_elemont_chunk_p1_2_2026-09-23.rb`. Clave: `bulk_chunks/1/121bfffe0827f6bc681ba9bdc91050390055/chunk_p1_2.txt`. `EXPECTED_LIVE = 79300034c8252dc2…` (sha completo con `shasum -a 256 /private/tmp/montacargas_chunks/chunk_p1_2.txt`). Backup local ya existe en `/private/tmp/montacargas_chunks/` (copiarlo a `tmp/elemont_patch_2026-09-23/chunk_p1_2_current.txt`).
2. Contenido corregido (`chunk_p1_2_corrected.txt`), **solo** lo que la hoja 2 desmiente:
   - l.24–25: «T1: Relé temporizador (Modo E, t < 3 minutos) — ver tabla de designaciones, hoja 2» y «T2: Relé temporizador (Modo Wu, t < 1 segundo) — ver tabla de designaciones, hoja 2». La frase del rectificador 24VAC/24VCD se conserva si sigue impresa en el dibujo; si no, se quita.
   - FIELD_RECORDs l.112 y l.121: misma corrección en `ACTION` y `EVIDENCE`.
   - Bornera l.61–62 (12/13) y l.71–72 (22/23): **verificar contra el dibujo de la hoja 1 antes de tocar.** Si la hoja 1 no tiene bornera propia, reemplazar la tabla por «Bornera: ver tabla de la hoja 2 (12 = L electroválvula bajando, 13 = N electroválvula, 23 = Seguridad OUT, 24 = Seguridad IN)». Si sí tiene una bornera distinta, dejarla y solo corregir la fila 12. No se inventa ninguna fila.
   - `[SEARCH_ALIASES:]` l.3: agregar `Elemont, Modelo MH, T1 T2 relé temporizador` para que la hoja 1 ancle a la marca (hoy solo lista K1…K7, Q1).
3. `RAG_CHUNK_PATCH_CONFIRM=1 bin/rails runner script/...` desde la máquina local con credenciales del usuario `Lahiri` (verificadas hoy). El sync (`BulkKbSyncService#sync!`) re-embebe solo el objeto cambiado; el precedente tardó menos de 15 minutos. `S3DocumentsService#upload_text` invalida `SectionNeighborExpander` solo.
4. Rollback: re-subir `chunk_p1_2_current.txt` con el mismo script invertido. El bucket no tiene versionado.
5. Verificación sin Bedrock: `aws s3 cp` del objeto y diff contra el corregido; `get_ingestion_job` en `COMPLETE`.

Si D1 se rechaza: el facilitador sabe que T1/T2 y el borne 12 en la hoja 1 están mal indexados y lo dice si la respuesta los cita. Se anota como defecto conocido en la captura.

**P0.4 Decisión D2 — medición mínima con pin (Bedrock).** Tres `retrieve_and_generate`, cuenta 1, pin Elemont, preguntas Q1, Q2, Q3 literales de la revisión, **tope US$0,10 y 3 llamadas**, fuera del contenedor, con el patrón de `tmp/field_companion_2026-09-23/gate_2/run.rb` (cap por `prepend`). Propósito único: saber si con pin (a) la hoja 2 entra para Q2 y Q3, y (b) Q1 sigue en «no está documentado» pese a estar en el chunk. Si (b) ocurre, I2 queda confirmado como causa de generación y pasa a P2. Si D1 se ejecutó, correr después del `COMPLETE`. Artefactos en `tmp/elemont_pilot_2026-09-24/premedicion/`.

### P1 — Durante el piloto (captura, cero cambios)

- Antes de la primera pregunta: confirmar el pin Elemont y ningún otro.
- Guion sugerido a Jesús: nombrar el designador («¿Qué es Q2?», «¿Qué hace T1?», «¿Qué va en el borne 12?») y la hoja cuando la sepa. Sin pin, ninguna de esas preguntas recupera el plano.
- Captura con [PILOT_CAPTURE_TEMPLATE.md](PILOT_CAPTURE_TEMPLATE.md): `correlation_id`, veredicto I/R/G, y si la respuesta cita bornes o valores de otra marca (XB21, BM/B1, 6±1 mm, 00 71): marcar **FC-D10, defecto conocido**, y decírselo a Jesús en el momento.
- Si Jesús quita el pin para preguntar por la CEA15: la CEA15 (`manual-cea15p`, doc 207) se pinnea junto al plano. El caso del 16-sep (pin Elemont excluyendo la CEA15) ya tiene P0/P1 desplegados; no se reabre.

### P2 — Después del piloto (backlog, con dueño)

| Ítem | Qué | Dónde vive |
|---|---|---|
| I2 | Si D2 lo confirma: `EXPECTED_RESULT: DATA_NOT_AVAILABLE` en registros `SCHEMATIC_LABEL` empuja la abstención. Opciones a evaluar: normalizar del lado de lectura (`normalize_absence_semantics` / `FieldRecordParser`) o del lado del parser de ingesta para documentos nuevos. Ninguna se hace sin medición. | Plan nuevo o fila V del copiloto |
| I1 (resto del corpus) | El mismo defecto de esquema denso puede existir en otros planos de Jesús (16 PDFs). Auditar hoja 1 vs tabla de designaciones en los planos con dos hojas de ese tipo antes de parchear más. | INGESTA_PILOTO_JESUS (cerrado) → nota nueva |
| R1 | La decisión «una pregunta no fija un manual» se mantiene. Lo que falta es UX: cuando `## Query Resolution` lista un documento del catálogo fuera del alcance, la respuesta ya dice «no consultado en esta sesión»; medir si Jesús lo pinnea solo. | Plan copiloto CG-D19 (prosa) |
| G1 | Sigue en FC-D10 / FC-D12. La medición del 23-sep no pasó con el rótulo por chunk. | Plan copiloto |
| Export | `bin/pilot_metrics --from 2026-09-24 --to 2026-09-24 --account danebo-legacy --with-questions` y comparar las 12 preguntas sin pin vs con pin. | `tmp/elemont_pilot_2026-09-24/` |

## 4. Decisiones que necesita el dueño

| ID | Decisión | Recomendación | Riesgo si no |
|---|---|---|---|
| **D1** | Parchear `chunk_p1_2.txt` esta noche (T1/T2, borne 12, aliases). Cero Claude, un sync de un objeto, rollback por re-subida. | **Sí, acotado**, si el dueño confirma contra el plano las filas de la bornera de la hoja 1. Sin esa confirmación, solo T1/T2 y aliases. | El plano se contradice en producción; con pin, cualquier pregunta por T1/T2 o borne 12 recibe las dos versiones. |
| **D2** | Medición previa con pin: 3 llamadas, tope US$0,10. | **Sí.** Separa I2 (generación) de R1 (recuperación) antes de que Jesús lo vea. | Q1 se repite mañana sin saber por qué. |
| **D3** | No desplegar `fc/pr2` ni encender flags antes del piloto. | **Sí.** | Regresiones medidas (E26, E29) delante del piloto. |

## 5. Restricciones

1. Sin push, deploy ni migración (restricción 15 del Plan maestro). El parche de S3 de D1 **no es deploy**, pero muta la KB de producción: exige instrucción explícita.
2. Sin Bedrock fuera de D2 y su tope.
3. No se debilita ningún test. D1 no toca código.
4. Todo hallazgo nuevo va a la sección 7 de este archivo y, si toca Field Companion, al Anexo E del Plan maestro (E31 ya remite aquí).

## 6. Verdad-terreno del plano (rúbrica)

Hoja 2, tabla de designaciones: Q1 interruptor automático 3 polos 25 A · Q2 partidor de motor 11–17 A · Q3 interruptor diferencial 25 A 30 mA · K1 contactor 24 VAC SUBE · K7 contactor 220 VAC Seguridad · T1 relé temporizador modo E, t < 3 min · T2 relé temporizador modo Wu, t < 1 s · borne 12 L electroválvula bajando · borne 10 L iluminación foso, 11 N · borne 14 L 220 VAC cabina, 15 N.
Hoja 4, unilineal circuito 1: fase RST, bomba hidráulica, sala de máquinas, cable 4×2,5 mm².
Hoja 5, línea de seguridad: tras Seg In, primero «Parada emergencia sobre cabina»; dos ramas, no una serie única de puertas 5→1 (el chunk `p5_1` ya marca REQUIRES_FIELD_VERIFICATION en ese punto).
Hoja 7, circuito 5: lámpara de cabina 40 W en serie con K4, L/N 220 VAC en bornes 15 y 16. Circuito 6: 3 lámparas de foso 20 W en paralelo, bornes 10 (L) y 11 (N), S2 en L, S1 en N.

Nota: la hoja 7 pone la cabina en bornes 15/16 y la hoja 2 en 14/15. Es una discrepancia **del plano**, no de la indexación; el chunk `p7_1` transcribe 15/16 tal cual. Si sale mañana, la respuesta correcta es decir las dos hojas.

## 7. Resultados de la revisión (12 preguntas, sin pin, 23-sep)

Reconstruido el 23-sep 21:30 −03 desde el stdout de la batería (cuenta `danebo-legacy`, KB `Y7RZWMFJSR`, imagen `2d456f8`, sin pin, `filter_applied=false`). Ruta de generación: `rag_global` en las 12. Costo de la corrida, warmup incluido: **US$0,0932** desde `bedrock_queries.id` 14565. La sonda `retrieve` pidió 5; la generación pide 8, así que una cita puede salir de un chunk que la sonda de 5 no listó.

| # | correlation_id | Pregunta (tema) | Índice (sonda top 5) | Cita de generación | Respuesta | Veredicto | Capa |
|---|---|---|---|---|---|---|---|
| 1 | `mh_battery:1` | Q1, 25 A | hoja 4, hoja 1, hoja 2; también CMC-3 e IRC | `chunk_p2_1.txt` p.2 | «no está documentada», citando la hoja 2 | el dato está en el chunk citado | G (I2) |
| 2 | `mh_battery:2` | Q2, 11–17 A | Monarch p.111, MCINV5, MPDK176; hoja 2 fuera | ninguna (`fallback_retrieve_top3`) | no hay Elemont | recuperación | R1 |
| 3 | `mh_battery:3` | Q3, 25 A 30 mA | solo CMC-3 Thyssen | ninguna (`fallback_retrieve_top3`) | no hay Elemont | recuperación | R1 |
| 4 | `mh_battery:4` | K1, 24 VAC SUBE | Crown FC-4000 y Thyssen Serie F; hoja 2 fuera | `chunk_p47_1.txt` p.47 (CMC-3, otro equipo) | no hay Elemont; nombra K1 del CMC-3 como otro equipo | recuperación; la cita ajena no se transplanta | R1 |
| 5 | `mh_battery:5` | K7, 220 VAC seguridad | hoja 2 en el puesto 1; también hoja 1 | `chunk_p2_1.txt` p.2 | contactor 220 VAC Seguridad | correcta | — |
| 6 | `mh_battery:6` | T1, modo E, t < 3 min | hoja 4 y hoja 2 | `chunk_p2_1.txt` p.2 | dice modo E y t<3 min, y luego que el tiempo concreto no está escrito | el dato está; el cierre lo niega | G (I2) |
| 7 | `mh_battery:7` | T2, modo Wu, t < 1 s | hojas 4, 2 y 1 | `chunk_p1_2.txt` p.1 y `chunk_p2_1.txt` p.2 | dice modo Wu y t<1 s; añade «típico de control rápido» | el dato está; esa frase no está en el plano. Las dos hojas entran y la respuesta sigue la hoja 2 | G leve; I1 expuesto, no copiado |
| 8 | `mh_battery:8` | borne 12 | MCP7 y Thyssen; hoja 2 fuera | ninguna (`fallback_retrieve_top3`) | no está | recuperación | R1 |
| 9 | `mh_battery:9` | lámpara cabina 40 W, K4, bornes 15/16 | hoja 7 en el puesto 2; también CMC4 | `chunk_p7_1.txt` p.7 | 40 W, K4, bornes 15 y 16, 220 VAC | correcta (hoja 7; la discrepancia 14/15 de la hoja 2 no salió) | — |
| 10 | `mh_battery:10` | circuito 1, bomba | hoja 4 en el puesto 1 | `chunk_p4_1.txt` p.4 | bomba hidráulica, sala de máquinas, 4×2,5 mm², fase RST | correcta | — |
| 11 | `mh_battery:11` | primer elemento tras Seg In | hoja 5 en el puesto 1; también hoja 1 | `chunk_p1_2.txt` p.1 y `chunk_p5_1.txt` p.5 | parada de emergencia sobre cabina, y después una serie única 5→1; la nota dice que el dibujo tiene ramas | lo preguntado está bien; la serie aplana las dos ramas | G parcial |
| 12 | `mh_battery:12` | foso, 3×20 W, bornes 10/11 | hoja 7 en el puesto 1 | `chunk_p7_2.txt` p.7 | 3×20 W, bornes 10 y 11, S2 en L y S1 en N | correcta | — |

Conteo contra la sección 6: 4 correctas (5, 9, 10, 12), 4 de recuperación (2, 3, 4, 8), 4 de generación con el chunk correcto en contexto (1, 6, 7, 11). Ninguna de las 12 transplanta un borne o un valor de otra marca como dato del Elemont. Q4 nombra el K1 del CMC-3 y lo marca como otro equipo.

El warmup `mh_battery_warmup` (no es una de las 12) sí repitió I1: citó `chunk_p1_2.txt` y escribió T1 como transformador 220VAC/18VCD y T2 como 220VAC/24VAC.

### D2 — las mismas Q1–Q3 con pin, después del parche

Pin: solo el PDF del plano. Tope 3 llamadas / US$0,10. Gasto US$0,0272.

| # | Hoja 2 en la cita | Respuesta |
|---|---|---|
| Q1 | no (`chunk_p1_2`, `chunk_p4_1`) | Q1 es el interruptor trifásico; **los amperes no están** |
| Q2 | no (`chunk_p4_1`, `chunk_p1_2`) | el rango 11–17 A no está |
| Q3 | sí (`chunk_p2_1`) | diferencial 25 A, 30 mA |

Con pin, Q1 ya no es I2: la hoja 2 no entra entre los 3 chunks, y la hoja 1 no trae los 25 A. Q2 sigue sin la hoja 2. Q3 sí la trae y responde bien. I2 queda sin confirmar en esta corrida.

## 8. Estado

| Paso | Estado | Artefacto |
|---|---|---|
| Diagnóstico I1/I2/R1/R2/G1/S1 | **Hecho 23-sep**, sin Bedrock | Este archivo, sección 1 |
| P0.1 export 12 preguntas | **Hecho 23-sep 21:30** | stdout de la batería (`mh_battery:1`–`12`). `bin/pilot_metrics` por cohorte no las ve: `user_id` nulo |
| P0.2 pines de la sesión | Pendiente (UI) | — |
| D1 parche hoja 1 | **Hecho 23-sep 21:35.** Solo T1/T2 y alias. Bornera sin tocar. Sync `F5S1ESDYNI` `COMPLETE`. SHA vivo `79300034c825` → `559e682e518c` | `script/patch_elemont_chunk_p1_2_2026-09-23.rb`; backup `tmp/elemont_patch_2026-09-23/chunk_p1_2_current.txt` |
| D2 medición con pin | **Hecho 23-sep 21:36.** 3 llamadas, US$0,0272. Hoja 2 entra en Q3 y no en Q1 ni Q2 | `tmp/elemont_pilot_2026-09-24/premedicion/results.txt` |
| D3 no desplegar fc/pr2 | **Vigente.** Sin deploy | — |

## 9. Cierre del gate de recuperación — 24-sep

### Cambio activo

No se cambió `PINNED_DOCUMENT_RESULTS = 3`, no hubo deploy y el pin de la
sesión 5 permaneció en `[213]`. La causa de las consultas cortas es que un
designador aislado (`Q1`, `Q4`, `PET`) aparece en varios chunks; los chunks de
diagrama/distribución con una descripción genérica pueden ganar a la tabla de
designaciones. Subir `top_k` afectaría todos los manuales y ya tiene la
regresión crítica documentada del 26-jul.

La reparación activa queda limitada al prefijo de nueve chunks de este plano:

| Objeto | Cambio | SHA anterior → activo | Sync |
|---|---|---|---|
| `chunk_p1_2.txt` | Copia literal desde la tabla viva de las designaciones Q1, Q2, Q3, Q4 y K6 en las viñetas que ya ganan; actualiza los `FIELD_RECORD` existentes de Q1/Q2; no toca bornera ni Q5/Q6. | `559e682e518ceb77b259b5701b5dc99c8b6a9c3f18003a536c119a1cbbfc6a6c` → `688a5d780eef8845c489af53f186d275a3a1cc7a4b35f42b38cc2d53be03776c` | `0ZD14YUMFP`, `K6TTYQFFHJ` y `QXM2UCQ3FY`, todos `COMPLETE` |
| `chunk_p2_1.txt` | Amplía solo `SEARCH_ALIASES` con las designaciones y valores literales de las 12 preguntas adicionales; el cuerpo y los `FIELD_RECORD` no cambian. | `cb7e2348cf94529cec9534d37055060d8627ca18a68704e1ed53d9744c46b549` → `70fa1eafac8b2b2baa707d7941e7f1879f4c2e1a5c2fec081c9b262a52d543f6` | `0ZD14YUMFP`, `COMPLETE` |
| `chunk_p4_1.txt` | Reemplaza la descripción genérica de H1/H2/H3 por la designación literal «Luces piloto, presencia de fase» y conserva la referencia a la hoja 2. | `05542e3d815c986e89080207482205669807de70e38f07aec329651110162953` → `1855de2076f1a55045a034e0051201c736a619c24590b407eb75ec47b67a6442` | `QXM2UCQ3FY`, `COMPLETE` |

El primer intento Q1–Q3 (`KMKT0VHK7J`) pasó las 12 preguntas originales pero
dio 21/24: Q4, Q6 y PET no recuperaron la tabla. Se restauró con
`V6RJG40DFX` (`COMPLETE`). El alias dirigido corrigió Q6 y PET, pero no Q4:
para Q4 seguían ganando `chunk_p1_2` y `chunk_p3_1`. Por eso la última
intervención fue una sola viñeta Q4 en el chunk ganador; la verificación causal
posterior recuperó 10 A desde `chunk_p1_2`.

### Batería de 24

Ejecución completa: 24 llamadas, cuenta `danebo-legacy`, usuario 6, sesión 5,
pin único 213, `force_entity_filter: true`, mismo URI del documento. Las filas
Q4, Q6 y PET muestran la verificación dirigida posterior a sus reparaciones;
las demás conservan la corrida completa porque sus datos no fueron modificados
después. Todas las citas resuelven bajo
`bulk_chunks/1/121bfffe0827f6bc681ba9bdc91050390055/`.

| # | correlation_id | Pregunta | Dato observado | Cita | Veredicto |
|---|---|---|---|---|---|
| 1 | `pilot24:retrieval:1:61a3cc` | ¿Qué es Q1? | Interruptor automático 3 polos, 25 A | `chunk_p4_1.txt` p.4 + `chunk_p1_2.txt` p.1 | Pasa |
| 2 | `pilot24:retrieval:2:0c26f2` | ¿Qué es Q2? | Partidor de motor, 11–17 A | `chunk_p1_2.txt` p.1 | Pasa |
| 3 | `pilot24:retrieval:3:21057f` | ¿Qué es Q3? | Diferencial, 25 A, 30 mA | `chunk_p3_1.txt` p.3 + `chunk_p1_2.txt` p.1 | Pasa |
| 4 | `pilot24:4:c27083` | ¿Qué es K1? | Contactor 24 VAC SUBE | `chunk_p2_1.txt` p.2 + `chunk_p1_2.txt` p.1 | Pasa |
| 5 | `pilot24:5:32c777` | ¿Qué es K7? | Contactor 220 VAC Seguridad | `chunk_p2_1.txt` p.2 | Pasa |
| 6 | `pilot24:6:289872` | ¿Qué hace T1? | Relé temporizador, modo E, t < 3 min; no dice transformador | `chunk_p2_1.txt` p.2 | Pasa |
| 7 | `pilot24:7:8bbde1` | ¿Qué hace T2? | Relé temporizador, modo Wu, t < 1 s | `chunk_p1_2.txt` p.1 + `chunk_p2_1.txt` p.2 | Pasa |
| 8 | `pilot24:8:1f68c9` | ¿Qué va en el borne 12? | L electroválvula bajando | `chunk_p2_1.txt` p.2 | Pasa |
| 9 | `pilot24:9:55f242` | ¿Qué lámpara tiene la cabina y en qué bornes va? | 40 W, K4, bornes 15/16 | `chunk_p7_1.txt` p.7 | Pasa |
| 10 | `pilot24:10:907dc6` | ¿Qué hay en el circuito 1? | Bomba, RST, sala de máquinas, 4×2,5 mm² | `chunk_p4_1.txt` p.4 | Pasa |
| 11 | `pilot24:11:8cb21a` | ¿Qué es lo primero después de seguridad in? | Parada de emergencia sobre cabina; mantiene advertencia sobre ramas | `chunk_p5_1.txt` p.5 | Pasa en lo preguntado |
| 12 | `pilot24:12:49ecd0` | ¿Cómo es la iluminación del foso? | 3×20 W, bornes 10/11, paralelo | `chunk_p7_2.txt` p.7 | Pasa |
| 13 | `pilot24:q4-final:442e5b` | ¿Qué es Q4? | Interruptor automático 1 polo, 10 A, iluminación foso | `chunk_p1_2.txt` p.1 | Pasa tras viñeta dirigida |
| 14 | `pilot24:14:7de451` | ¿Qué es Q5? | Interruptor automático 1 polo, 16 A, iluminación cabina | `chunk_p2_1.txt` p.2 | Pasa |
| 15 | `pilot24:retrieval:5:65bcc0` | ¿Qué es Q6? | Interruptor automático 1 polo, 6 A, control | `chunk_p2_1.txt` p.2 | Pasa tras alias dirigido |
| 16 | `pilot24:16:a49e19` | ¿Qué es K2? | Relé 11 pines, 24 VCA, BAJA | `chunk_p2_1.txt` p.2 + `chunk_p4_1.txt` p.4 | Pasa |
| 17 | `pilot24:17:32c291` | ¿Qué es K4? | Relé 11 pines, 24 VCA, PRESOSTATO | `chunk_p2_1.txt` p.2 + `chunk_p7_1.txt` p.7 | Pasa |
| 18 | `pilot24:18:84b67c` | ¿Qué es K8? | Contactor 220 VAC BAJA | `chunk_p2_1.txt` p.2 | Pasa |
| 19 | `pilot24:19:ca7b16` | ¿Qué va en el borne 10? | L iluminación foso | `chunk_p2_1.txt` p.2 | Pasa |
| 20 | `pilot24:20:6c6132` | ¿Qué va en el borne 14? | L 220 VAC cabina; informa contradicción con hoja 1 | `chunk_p1_2.txt` p.1 + `chunk_p2_1.txt` p.2 | Pasa |
| 21 | `pilot24:21:65407b` | ¿Qué va en el borne 23? | Seguridad OUT; advierte discrepancia interna | `chunk_p2_1.txt` p.2 + `chunk_p1_2.txt` p.1 | Pasa |
| 22 | `pilot24:22:c6d45f` | ¿Qué calibre tienen F1, F2 y F3? | Fusible seccionador 2 A | `chunk_p2_1.txt` p.2 | Pasa |
| 23 | `pilot24:23:8e5826` | ¿Qué bornes corresponden al presostato? | 25 OUT y 26 IN | `chunk_p2_1.txt` p.2 | Pasa |
| 24 | `pilot24:retrieval:6:8e26dc` | ¿Qué es PET? | Parada de emergencia | `chunk_p2_1.txt` p.2 | Pasa tras alias dirigido |

Resultado del gate: **24/24 con evidencia Elemont**, sin CMC3, KONE,
Excelsior ni Thyssen; Q1/Q2/Q3 incluyen el calibre solicitado. La evidencia
bruta queda en `tmp/elemont_patch_2026-09-24/results_24.jsonl`,
`tmp/elemont_retrieval_patch_2026-09-24/results_6.jsonl` y
`tmp/elemont_q4_patch_2026-09-24/result_q4.jsonl`.

### Extensión aleatoria: consultas 25–36

Se ejecutaron 12 preguntas adicionales con las mismas invariantes: cuenta 1,
usuario 6, sesión 5, pin único 213 y filtro forzado por el URI del documento.
La primera corrida pasó 10/12: K6 recuperó la tabla correcta pero la respuesta
abstuvo, y H1/H2/H3 recuperó la descripción genérica del unilineal. Se
repararon únicamente las viñetas ganadoras de `chunk_p1_2` y `chunk_p4_1`, se
sincronizó con `QXM2UCQ3FY` (`COMPLETE`) y se repitieron esas dos consultas.

| # | correlation_id | Pregunta | Dato observado | Cita | Veredicto |
|---|---|---|---|---|---|
| 25 | `pilot24:random12:1:f583f3` | ¿Qué certificación figura en el plano? | ROL 2740 | `chunk_p1_1.txt` p.1 | Pasa |
| 26 | `pilot24:random12:2:c642d9` | ¿Qué es R1? | Relé de tensión, U=0 / U<, protección por falta o baja tensión | `chunk_p4_1.txt` p.4 | Pasa con observación: la tabla de la hoja 2 lo denomina «relé de asimetría» |
| 27 | `pilot24:random12:3:b575dd` | ¿Qué es K3? | Relé plano 24 VDC, bloqueo presostato | `chunk_p2_1.txt` p.2 | Pasa |
| 28 | `pilot24:random12:4:dc4da1` | ¿Qué es K5? | Relé plano 24 VDC, indicador seguridad | `chunk_p2_1.txt` p.2 | Pasa |
| 29 | `pilot24:random12-recheck:1:63edff` | ¿Qué es K6? | Relé 11 pines, 24 VCA, INSPECCION | `chunk_p2_1.txt` p.2 + `chunk_p1_2.txt` p.1 | Pasa tras viñeta dirigida |
| 30 | `pilot24:random12-recheck:2:0cd923` | ¿Qué indican H1, H2 y H3? | Luces piloto, presencia de fase | `chunk_p4_1.txt` p.4 | Pasa tras viñeta dirigida |
| 31 | `pilot24:random12:7:e7cc1d` | ¿Qué indica H4? | Luz piloto, falla seguridad | `chunk_p2_1.txt` p.2 | Pasa |
| 32 | `pilot24:random12:8:0c4011` | ¿Qué va en el borne 24? | Seguridad IN | `chunk_p2_1.txt` p.2 | Pasa |
| 33 | `pilot24:random12:9:38c7aa` | ¿Qué va en el borne 27? | Hoja 1: límite superior; hoja 2: indicador sobre carga | `chunk_p1_2.txt` p.1 + `chunk_p2_1.txt` p.2 | Pasa: expone la discrepancia interna |
| 34 | `pilot24:random12:10:f8183d` | ¿Cómo se alimenta la sirena? | Fuente 220 VCA/12 VCD, cable 3×0,75 mm², foso | `chunk_p4_1.txt` p.4 | Pasa |
| 35 | `pilot24:random12:11:097483` | ¿Qué colores tienen los sensores sobre cabina? | PAS/PAD: rojo, gris y negro | `chunk_p6_1.txt` p.6 | Pasa |
| 36 | `pilot24:random12:12:e0bf01` | ¿Cómo están conectados los indicadores de subida y bajada? | Cinco pares LFS/LFB en paralelo, PasCom 24 V | `chunk_p6_1.txt` p.6 | Pasa |

Resultado consolidado: **36/36 con evidencia del manual Elemont**. Es una
batería completa más rechecks causales de las consultas que fallaron; no se
presenta como una única corrida ininterrumpida sobre el estado final. Las dos
observaciones documentales que deben conservarse en campo son R1 y el borne
27: el manual contiene nomenclaturas distintas entre hojas y no corresponde
ocultarlas ni elegir una como verdad única.

Evidencia bruta adicional:
`tmp/elemont_random_12_2026-09-24/results_12.jsonl` y
`tmp/elemont_random12_patch_2026-09-24/results_2.jsonl`.
