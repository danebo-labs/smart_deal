# Danebo — Plan de Implementación: Módulo Certificador (2026-08-09)

**Documento padre:** [PLAN_GENERAL_2026-09-03.md](PLAN_GENERAL_2026-09-03.md) (sección 4) · [PLAN_SEPTIEMBRE_2026.md](PLAN_SEPTIEMBRE_2026.md) (sección 3).
**Naturaleza:** documento vivo de ejecución. Las fases se ejecutan en sesiones de agente independientes ("ejecutores"), potencialmente con modelos distintos. Ver protocolo en sección 1.
**Realineación 2026-09-08:** la premisa original ("adelantar la construcción a agosto: primero lo determinista, después la voz") caducó — agosto cerró sin ejecutar fases y el [plan de septiembre](PLAN_SEPTIEMBRE_2026.md) vigente (secciones 2.1, 2.2 y 8) manda el orden contrario: primero dictar → corregir → confirmar → guardar → recuperar; exportable, estructura de 8 ítems, normativa y PDF quedan condicionados a uso real. Este documento se reordenó en consecuencia y cerró cinco gaps críticos de una auditoría externa (sección 2.2). Los cortes del 16 de septiembre y del 2 de octubre (plan de septiembre, sección 8) gobiernan qué se ejecuta y qué se congela.

---

## 0. Reglas fijas (ningún ejecutor las contradice)

Heredadas del Plan General sección 4.2 y de los `AGENTS.md` del repositorio:

1. **Danebo no evalúa cumplimiento.** No clasifica gravedad por su cuenta, no decide si un equipo aprueba o reprueba, no firma. La clasificación leve/grave y la casilla de norma las asigna **el certificador** al revisar; Danebo solo ofrece los campos.
2. **Todo documento exportado sale marcado como BORRADOR.**
3. **Ninguna versión de voz envía audio directo a generación.** La transcripción es siempre visible y editable antes de incorporarse al borrador (gate de los puntos 2–3 de la sección 2.1 del plan de septiembre).
4. **La captura es dictado libre; la estructura se aplica después.** Sin formularios extensos ni clasificación obligatoria durante la inspección.
5. **Derivación determinista de la norma aplicable** desde la fecha de recepción municipal, en Rails, sin llamada al modelo. Presentarla es ayuda documental, no evaluación.
6. **No se toca `ConversationSession`** (ruta caliente de latencia).
7. **Cost-first:** ninguna llamada externa nueva sin telemetría de costo. Las transcripciones **no** crean filas en `bedrock_queries` (enum `source` cerrado, asume tokens): tienen su propia tabla (Fase 4).
8. **Multi-tenant:** todo modelo nuevo lleva `account_id` y sigue el scoping por host (`current_account`).
9. Antes de tocar un directorio, leer su `AGENTS.md` scoped (`app/`, `app/javascript/`, `app/views/`, `test/`, `app/prompts/`).
10. **Retención de evidencia:** ninguna purga automática (`FieldPhotoRetentionJob` o su homóloga de audio) elimina artefactos vinculados a un informe. La exclusión se implementa en la misma fase que crea el vínculo, con test que lo pruebe (Fase 0 para fotos, Fase 4 para audio).
11. **Persistencia ante interrupción:** cerrar, recargar o reabrir no pierde audio ya subido, transcripción ni texto confirmado (plan de septiembre, sección 2.1, punto 5). Un blob local en memoria es mitigación de upload, no mecanismo de persistencia.
12. **Aislamiento doble:** scoping por cuenta (host) **y** propiedad por usuario en "mis informes". Los broadcasts de dictado van por stream privado del usuario — no por el patrón `KbSyncChannel`, que transmite a toda la cuenta.
13. **Un dictado = una llamada facturada = un hallazgo:** claim atómico del estado antes de llamar al proveedor STT; confirmación idempotente; un resultado tardío del proveedor nunca sobrescribe ediciones ni entra al borrador sin confirmación.

---

## 1. Protocolo de documento vivo

- **Antes de ejecutar una fase**, el ejecutor lee: este documento completo, los bloques *Cierre de fase* de todas las fases anteriores, y el bloque *Insumos* de su propia fase.
- **Al cerrar una fase**, el ejecutor: (a) llena su bloque *Cierre de fase* con hallazgos y desviaciones; (b) **edita los bloques *Insumos* de las fases siguientes afectadas** — no basta con anotar el hallazgo en la fase propia; (c) actualiza la tabla de estado de la sección 2.
- **Prompt de lanzamiento:** cada fase tiene su bloque *Prompt de lanzamiento* con el modelo asignado (tabla de la sección 2). Todos extienden esta base común, que no se repite en cada bloque pero es parte del prompt:

> Lee `docs/PLAN_IMPLEMENTACION_CERTIFICADOR_2026-08-09.md` completo. Crea el branch `certificador/fase-N-<nombre>` desde `main` actualizado y trabaja ahí (sección 2.1). Ejecuta la Fase N respetando la sección 0 (reglas fijas), las resoluciones de la sección 2.2 y los `AGENTS.md` del repositorio. Todo cambio de comportamiento lleva tests Minitest; prueba en local antes de dar por cerrada la fase. Al terminar: llena el bloque "Cierre de fase" de la Fase N y actualiza los bloques "Insumos" de las fases siguientes que tus hallazgos afecten.

---

## 2. Estado de ejecución

| Orden | Fase | Entregable | Estado | Modelo asignado | Effort |
|---|---|---|---|---|---|
| 1º | 0 | Modelo de datos del borrador (alcance núcleo) | **cerrada** (2026-09-08, branch `certificador/fase-0-modelo-datos`, suite local verde) | Opus última versión | high |
| 2º | 2 | Lista "mis informes" + editor mínimo | **cerrada** (2026-09-08, branch `certificador/fase-2-mis-informes`, suite local verde) | Sonnet última versión | medium |
| 3º | 4 | Capa de transcripción agnóstica al proveedor | **cerrada** (2026-09-08, branch `certificador/fase-4-transcripcion`, suite local verde, mergeada a `main` vía PR #22; transcripción real end-to-end con **Transcribe (USD 0,0124) y OpenAI (USD 0,0016)**, total USD 0,0140) | Opus última versión | high |
| 4º | 5 | UI de captura de audio (dictado) | pendiente | Fable última versión | high |
| 5º | 6 | Benchmark de costo/calidad STT + COGS de voz | pendiente | Grok (variante rápida) | low/fast |
| — | 1 | Exportable HTML con hoja de impresión (formato NCh 2840) | **condicionada** (gate 2-oct) | Sonnet última versión | medium |
| — | 3 | PDF server-side | **condicionada** | Grok (variante rápida) | low/fast |
| — | 7 | Estructuración del dictado en hallazgos | **condicionada** (gate 2-oct) | Opus última versión | high |

**Criterio de asignación de modelo (parque disponible: GPT Ultra, Fable última versión, Opus última versión, Sonnet última versión, Grok):**

- **Razonamiento alto** — **Opus última versión** (alternativa: **GPT Ultra**, útil como segunda opinión de diseño): fases cuyo error es caro de deshacer — esquema de datos, contrato del adapter y máquina de estados, prompts con red lines de seguridad. Fases 0, 4 y 7.
- **Estándar** — **Sonnet última versión** o **Fable última versión**: implementación sobre diseño ya decidido — vistas, CRUD, Stimulus. Fases 1 y 2 (Sonnet); Fase 5 (Fable: es el tramo estándar más delicado, UI de captura con contratos de persistencia y recuperación finos).
- **Rápido/económico** — **Grok (variante rápida)** (alternativa: Sonnet): trabajo mecánico y determinista con criterios de aceptación cerrados — scripts, una gem, una vista más. Fases 3 y 6.
**Criterio de nivel de esfuerzo (effort/thinking):** el effort se paga solo donde el error es caro de deshacer, no donde hay más código que escribir — en fases mecánicas, effort alto es más lento, más caro y tiende a sobre-ingeniería.

- **high:** Fases 0, 4 y 7 (esquema, concurrencia y máquina de estados, red lines) y Fase 5 (los contratos de recuperación — upload-first, autosave, reapertura — son diseño fino, no solo UI).
- **medium/estándar:** Fases 1 y 2 (implementación sobre diseño ya decidido).
- **low/fast, sin thinking extendido:** Fases 3 y 6 (trabajo mecánico con criterios de aceptación cerrados).
- Regla práctica de escalamiento, en dos ejes: si una fase se traba dos veces en lo mismo, primero se relanza subiendo el effort (medium → high); si persiste, se relanza con Opus o GPT Ultra. Reintentos fallidos cuestan más que el upgrade.

### 2.1 Flujo de trabajo de ejecución (decidido 2026-08-09)

**Branches.** Un branch por fase (`certificador/fase-0-modelo-datos`, `certificador/fase-1-exportable`, …), un PR chico y revisable por fase. El cierre de fase (bloque de este documento) se edita dentro del mismo PR. **Prerrequisito antes de la Fase 0:** cumplido — verificado el 2026-09-08: el working tree de `main` está limpio y los branches de fase parten de `main` actualizado.

**Prueba y deploy.** Local primero: tests Minitest de la fase + prueba manual en dev (la Fase 4 exige además una transcripción real end-to-end en dev). Fase verde → merge a `main` → deploy a producción con Kamal, el flujo existente. No se acumulan fases sin mergear: cada fase entra a `main` al cerrarse.

**Feature flag.** Gating mínimo Rails-native, sin gem: `ENV["CERTIFIER_MODULE_ENABLED"]` que (a) oculta la entrada de navegación y (b) protege los controladores del módulo con un `before_action` que devuelve 404. Permite mergear y deployar fases incompletas mientras usuarios reales (ingenieros/técnicos de Gonzalo) usan producción. La Fase 0 puede mergear sin flag: son migraciones aditivas sin superficie visible. El flag se retira cuando el módulo se libere a un certificador real.

**Plan de rollback.** El flag es el mecanismo principal — **no** `git reset`/reescribir `main`:

- **Kill switch instantáneo:** apagar `ENV["CERTIFIER_MODULE_ENABLED"]` en producción oculta la navegación y devuelve 404 en los controladores del módulo, sin deploy de código ni operación de git. Es la respuesta a "no funciona, hay que pararlo ahora".
- **Por qué no resetear `main`:** cada fase se mergea individualmente y se deploya (este mismo apartado); entre el cierre de una fase y una eventual decisión de abandonar el módulo, `main` sigue recibiendo commits no relacionados (otras correcciones del repo). Resetear `main` a un punto anterior los borraría también y exigiría force-push — fuera de las reglas de git de este workspace.
- **Retirar el código de una fase puntual:** `git revert` del merge commit de esa fase (no `reset`) — no reescribe historia, es seguro sobre una rama ya deployada. Las migraciones de cada fase se exigen reversibles como criterio de aceptación (Fase 0 ya lo probó con `db:rollback:primary STEP=2`), así que `rails db:rollback` deshace el esquema si además se quiere botar las tablas.
- **Estado de reposo aceptable:** el módulo es aditivo (tablas y rutas nuevas; nunca toca `ConversationSession` ni rutas existentes — regla fija 6). Si el piloto no valida el módulo, dejarlo mergeado y apagado por el flag indefinidamente es un desenlace válido — no hay obligación de deshacer git.

**Rutas.** Path nuevo, recurso REST plano siguiendo el patrón existente (`resources :field_photos`): `resources :certification_reports` (Fase 2) con member `get :export` (Fase 1, condicionada), y `resources :voice_dictations, only: %i[create show]` (Fases 4–5). Nada anidado bajo el chat ni bajo `/rag`.

**UI: sección propia, no el chat.** El módulo es un editor de documento (lista + borrador), no una conversación: reutiliza el layout/shell de la app (navegación, Tailwind, i18n) pero con vistas y controladores Stimulus propios. No se monta sobre `rag_chat_controller` ni sobre `ConversationSession` (regla fija 6). El chat queda intacto para el flujo mantenedor.

**Mockup de diseño (insumo opcional de la Fase 2).** Si se quiere un borrador visual antes de implementar el editor: pedir un **mockup HTML estático + Tailwind** (sin framework, casi copy-paste a ERB) a un modelo fuerte, o usar herramientas tipo v0.app **solo como referencia visual** — generan React/shadcn, que no es el stack (ERB + Stimulus + importmap); de ahí solo transfieren las clases Tailwind y el layout. Brief fijo: mobile-first, tap targets mínimo 60px (72px en acciones primarias, 16px de espaciado — cifras y referencias de la sección 2.3), alto contraste (poca luz), mínimo tipeo, sin estado SPA. El exportable de la Fase 1 no necesita mockup: su diseño es el PDF de referencia de la sección 3.1.

### 2.2 Auditoría de gaps y realineación (2026-09-08)

Cinco gaps críticos señalados por una revisión externa, verificados contra el código y los planes vigentes. Los ejecutores no repiten el análisis: aplican estas resoluciones, que ya están integradas en las reglas fijas y en las fases.

1. **Orden contradictorio con el alcance vigente — confirmado.** El plan de septiembre (sección 2.2) excluye exportable, estructura completa de 8 ítems, normativa exhaustiva y PDF hasta observar uso real, y su corte del 16-sep congela estructura y exportación si el circuito de voz no está en pie. Resolución: nuevo orden 0 → 2 → 4 → 5 → 6; las Fases 1, 3 y 7 y el tramo extendido de la Fase 0 quedan **condicionados** al gate del 2 de octubre (plan de septiembre, sección 8). Las referencias internas al plan de septiembre apuntaban a una versión anterior del documento (secciones 3.2, 5.1, 6.1, 6.2 ya no existen) y fueron corregidas fase por fase.
2. **Purga de fotos vinculadas a informes — confirmado.** `FieldPhotoRetentionJob` borra el prefijo S3 y destruye la fila de toda foto que supere `FIELD_PHOTO_RETENTION_DAYS` (90 por defecto), sin distinguir fotos referenciadas por un informe, y borra S3 **antes** de destruir la fila — una FK restrictiva no protegería el archivo. Resolución: regla fija 10 + política de retención en la Fase 0 (exclusión en el job, FK como respaldo, fila antes que S3, test de supervivencia).
3. **Recuperación del trabajo interrumpido sin garantía — confirmado.** Un blob local en memoria no sobrevive recarga ni cierre; el requisito vigente es cerrar y reabrir sin perder audio, transcripción ni texto (plan de septiembre, sección 2.1, punto 5). Resolución: regla fija 11 + upload-first, autosave de ediciones no confirmadas y pruebas de recuperación explícitas en la Fase 5; estados de dictado recuperables en la Fase 4.
4. **Aislamiento especificado a medias — confirmado.** `KbSyncChannel`/`KbSyncBroadcaster` transmiten a `account:<id>:kb_sync` — toda la cuenta — y no sirven de patrón para el dictado; y "mis informes" exige propiedad por usuario, no solo por cuenta. Resolución: regla fija 12 + canal privado del usuario en la Fase 4 + criterios de aislamiento en dos ejes (cuenta ajena y otro usuario de la misma cuenta) en las Fases 0, 1 y 2.
5. **Contrato de idempotencia y confirmación insuficiente — confirmado.** `sha256` único + `rescue RecordNotUnique` garantizan una fila, no una sola llamada facturada al proveedor STT bajo reintentos concurrentes, ni un solo hallazgo ante doble confirmación, ni protegen las ediciones contra un resultado tardío del proveedor; y la deduplicación global por cuenta impediría usar el mismo audio en informes distintos. Resolución: regla fija 13 + máquina de estados con claim atómico, confirmación idempotente con vínculo único dictado→hallazgo, descarte de resultados tardíos y dedup por informe en la Fase 4.

### 2.3 Referencias de UX y guidelines para dictado + evidencia en campo (grounding, 2026-09-08)

No se pide copiar el diseño visual de ninguna de estas apps — la UI de Danebo sigue siendo minimalista, propia y mobile-first (regla fija de frontend). Se referencian por el **contrato de interacción**, que sí conviene reusar porque ya está validado en producción en el mismo dominio (voz → texto estructurado, revisión humana antes de comprometer el dato).

**Apps de referencia, mismo patrón dictar → estructurar → revisar:**

| Referencia | Patrón que aporta | Aplica a |
|---|---|---|
| Salesforce Field Service *Voice to Form* ([ingeniería](https://engineering.salesforce.com/delivering-accurate-low-latency-voice-to-form-ai-in-real-world-field-conditions/), [producto](https://www.salesforce.com/blog/voice-to-form/)) | Voz embebida en el formulario existente con **un solo control**, no un chat nuevo; los campos que la IA llenó se resaltan visualmente al terminar; **undo inline** y edición de texto siempre disponibles; cero automatización silenciosa — "los técnicos prefirieron transparencia y corrección antes que automatización silenciosa" | Fase 5 (botón único grabar/parar, resaltar el hallazgo recién creado, undo visible) |
| Voice-to-inspection-form con revisión ([dev.to](https://dev.to/toddsullivan/i-used-claude-to-fill-inspection-forms-by-voice-without-building-a-voice-stack-3ha)) | Los valores propuestos por la IA se muestran como **diffs sobre lo ya existente**, nunca sobrescriben en silencio; "el LLM propone, el humano aplica"; solo escribe tras un sí explícito | Fase 7 condicionada (sugerencias de estructuración nunca reemplazan texto ya confirmado sin mostrarlo como cambio explícito) |
| SafetyCulture / iAuditor ([review](https://fluix.io/blog/safetyculture-review)) | Inspección completable a una mano ("todo el audit con una mano mientras sostienes un café con la otra"); capturar foto y anotarla es el mismo gesto que abrir la cámara, sin pantallas intermedias; una acción de seguimiento se ofrece en el momento del hallazgo, no después | Fase 2 (adjuntar foto a un hallazgo en un solo flujo, sin navegación extra) |
| Wispr Flow ([producto](https://wisprflow.ai/), [docs](https://docs.wisprflow.ai/articles/5096240724-navigating-the-wispr-flow-app-desktop-ios-and-android)) | Indicador de estado como **un solo elemento mínimo** (reposo/grabando/procesando), no un panel; en apps de dictado en vivo el texto interino aparece atenuado y "solidifica" al finalizar — útil como referencia visual para el estado "transcribiendo…" de un dictado batch | Fase 5 (indicador de estado del dictado: grabando → subiendo → transcribiendo → editable) |

**Guideline de confirmación de voz — Google Conversation Design ([fuente](https://developers.google.com/assistant/conversation-design/confirmations)):** confirmación **explícita** solo para lo caro de deshacer; confirmación **implícita** (mostrar y seguir) para todo lo demás; **corrección en un paso** — el usuario corrige directamente en vez de reiniciar el flujo. Aplicado aquí: incorporar un dictado a un hallazgo del borrador es la acción cara de deshacer → confirmación explícita (ya es regla fija 3, no cambia); mostrar nivel de audio o duración durante la grabación no necesita confirmación; editar la transcripción es corrección en un paso, no "grabar de nuevo".

**Tap targets con guantes — cifra concreta que reemplaza el "tap targets grandes" genérico:** consumidor sin guantes, 9–11mm ≈ 44px a 160dpi (Apple HIG, W3C [M002](https://w3c.github.io/Mobile-A11y-TF-Note/Techniques/M002)); con guantes de trabajo, **mínimo 60px (≈15mm)** para cualquier control interactivo y **mínimo 72px (≈20mm) para la acción primaria** (grabar/parar, confirmar), con **al menos 16px de espaciado** entre controles adyacentes — fuentes: [CDTech/ISO 9241-9](https://www.cdtech-display.com/knowledges/how-to-optimize-ui-button-size-for-gloved-users-in-industrial-hmis/), [guía de apps para construcción](https://weareaffective.com/learning-centre/how-should-i-design-apps-for-construction-workers). Estas cifras son el criterio de aceptación de tap targets en las Fases 2 y 5, no una revisión subjetiva.

---

## 3. Evidencia de formato (grounding, 2026-08-09)

### 3.1 El informe real

**Archivo:** [referencias/2023_informe_certificacion_ascensores_NCh2840_torre_amunategui.pdf](referencias/2023_informe_certificacion_ascensores_NCh2840_torre_amunategui.pdf) — Informe N°328/2023, Pizarro y Cía. Ltda. "INAE", Registro MINVU Rol 063, Torre Amuñátegui (Catedral 1401, Santiago), 6 equipos, resultado RECHAZADO. Documento público de 7 páginas.

**Estructura observada, que es la que replica el exportable:**

1. **Encabezado de identificación:** empresa certificadora + rol MINVU, N° interno de informe, fecha de informe y de inspección, normativa aplicable (checkbox: NCh 440/1/2 2000, NCh 3395, NCh 440/1/2 2014/5, otras), comuna/calle/N°, nombre del edificio, destino del inmueble (vivienda/equipamiento/…), características básicas por equipo: con/sin sala de máquinas, hidráulico/electromecánico, tipo de puertas, N° embarques, cantidad de equipos, cables de tracción, N° paradas, velocidad, carga útil, capacidad, fecha última mantención, **empresa mantenedora y técnico mantenedor**, técnico de apoyo en inspección.
2. **Tabla de defectos GRAVES** (o leves anteriores no resueltos): casilla + punto de norma + aclaración.
3. **Resultado:** APROBADO (sin defectos / con nuevos defectos) o RECHAZADO (por leves anteriores no resueltos / por graves de esta inspección), con declaración del inspector y firmas (G. Técnico / I. Técnico).
4. **Tabla de defectos LEVES:** casilla + punto + aclaración (deben resolverse para la próxima certificación).
5. **Guía de inspección completa NCh 2840:2018:** ~370 casillas numeradas, cada una con punto de norma y clasificación L/G predefinida, agrupadas en 13 secciones (1 Caja de elevadores, 2 Espacio de máquinas y poleas, 3 Puertas de piso, 4 Cabina/contrapeso/masa de equilibrado, 5 Suspensión/sobrevelocidad, 6 Guías/amortiguadores/final de recorrido, 7 Holguras, 8 Máquina, 9 Sin sala de máquinas, 10 Protección eléctrica/mandos, 11 Excepciones autorizadas, 12 —, 13 Cumplimiento del plan de mantención y Carpeta de Ascensores) más pruebas D (paracaídas, limitador, frenado) y E (rótulos). Las revisadas sin observación quedan sin color; leves en amarillo, graves en rojo.

### 3.2 Lo que dice el Decreto 37 (leychile.cl, consultado 2026-08-09)

El **Certificado de Conformidad** se confecciona "usando el protocolo y formularios que para dichos efectos disponga el MINVU" — formato prescrito, se emite en el portal MINVU, **fuera del alcance de Danebo**. El **Informe** técnico sigue la guía de inspección de la norma aplicable; cada certificadora lo diagrama a su manera dentro de esa estructura. Esto **cierra la verificación pendiente** de la sección 3.5 del plan de septiembre: no hay formato de informe prescrito → el módulo debe permitir ajustar orden y nomenclatura, y el exportable se valida con Carlos Schwartz (TAQUIÓN-CERT) recién cuando el dictado funcione.

### 3.3 Decisión de estructura (tomada 2026-08-09)

**Híbrido:** el dictado libre se organiza en los **8 ítems CENTRAVE** (esqueleto del borrador: Carpeta de Ascensores, Cabina, Espacio de máquinas, Contrapeso, Caja de elevadores, Pozo, Puertas y cerraduras, Suspensión/cables/amarras), y cada hallazgo lleva **campos opcionales** — casilla NCh 2840, punto de norma, gravedad L/G — que el certificador asigna al revisar. El exportable replica el formato de la sección 3.1. No se precarga el catálogo completo de ~370 casillas en esta etapa (queda como hallazgo posible de la validación con un certificador real).

---

## 4. Evidencia de costos de voz (grounding, 2026-08-09)

Precios públicos por minuto de audio, batch salvo indicación. Un dictado de certificación (15–20 min) es naturalmente **batch**, no streaming — y en español el batch es además más preciso (89–91% streaming vs 95–97% batch en los mejores motores).

| Proveedor / modelo | USD/min | Dictado de 20 min | Notas |
|---|---:|---:|---|
| Amazon Transcribe standard | 0.024 | $0.48 | Batch y streaming mismo precio; mínimo 15 s por request; ya estamos en AWS (IAM, S3, sin vendor nuevo) |
| OpenAI gpt-4o-transcribe | 0.006 | $0.12 | 95–97% precisión en español batch |
| OpenAI gpt-4o-mini-transcribe | 0.003 | $0.06 | Mitad de precio, precisión comparable en audio limpio |
| Deepgram Nova-3 | 0.0036–0.0043 | ~$0.08 | Streaming $0.0056–0.0077; fuerte en tiempo real, que no necesitamos |
| AssemblyAI Universal-2 | 0.0025 | $0.05 | |
| Groq Whisper Large v3 Turbo | ~0.0007 | $0.013 | El hosted más barato (~35× menos que Transcribe); sin streaming; throughput 100×+ tiempo real |
| Kimi-Audio (Moonshot) | — | — | **Open-weights, self-hosting.** Sin API hosted práctica. No aplica al MVP; los Kimi K son LLM de texto |
| Anthropic | — | — | **No ofrece API de transcripción.** Su rol posible es la etapa de estructuración (Fase 7), no la de voz |

**Consecuencia de arquitectura:** "flexibilidad de proveedor" son **dos capas separadas e intercambiables por separado**: (a) **transcripción** audio→texto (Transcribe, OpenAI, Groq, Deepgram — Fase 4); (b) **estructuración** texto→hallazgos (Bedrock Haiku por defecto; Kimi u otro LLM económico como alternativa — Fase 7). Cambiar de proveedor en cualquiera de las dos es configuración, no arquitectura.

**Punto de partida:** Amazon Transcribe como baseline (cero fricción de onboarding: misma cuenta AWS, es-CL soportado), y el benchmark de la Fase 6 decide el default definitivo contra los económicos. Con estos precios, el costo de voz por informe (~$0.01–0.48) es marginal frente al precio por informe: el driver de la decisión será la **tasa de error sobre jerga técnica**, no el costo — pero eso se confirma midiendo, no asumiendo.

---

## 5. Arquitectura objetivo

```
Certificador (móvil, guantes, poca luz)
  │ dicta (Fase 5: Stimulus + MediaRecorder, blob local)
  ▼
POST audio ──► S3 (patrón FieldPhoto: bytes fuera de args de job)
  │
  ▼
TranscriptionJob (Solid Queue, idempotente)
  │  SpeechToText::Client.for(ENV["STT_PROVIDER"])  ◄── Fase 4: adapters
  │    ├─ AmazonTranscribeAdapter
  │    ├─ OpenAiAdapter
  │    └─ GroqAdapter
  ▼
Transcripción VISIBLE Y EDITABLE (gate, regla fija 3)
  │ certificador confirma / corrige
  ▼
Estructuración → hallazgo en ítem CENTRAVE (Fase 7, condicionada; Bedrock Haiku default, LLM configurable)
  ▼
CertificationReport (borrador persistente, Fase 0) ──► pausar / retomar / revisar
  │ certificador asigna casilla / punto / gravedad (opcional, Fase 2)
  ▼
Exportable HTML print (Fase 1, condicionada) ──► PDF server-side (Fase 3, condicionada)
                    [marca de agua BORRADOR]
```

Patrones existentes que se reutilizan (informe de arquitectura, 2026-08-09): tenancy por host (`AccountHostResolver` + `current_account`), fotos vía `FieldPhoto` + S3 con `sha256` único por cuenta (no Active Storage, nunca bajo `bulk_chunks/`), jobs idempotentes con `rescue RecordNotUnique → find`, servicios PORO con inyección `client:` para tests (sin WebMock), broadcast por canal privado del usuario (el patrón `KbSyncChannel` transmite a toda la cuenta y no sirve aquí — regla fija 12), locales pareados `certifier.es.yml`/`certifier.en.yml` siguiendo el patrón `rag.*`.

---

## Fase 0 — Modelo de datos del borrador persistente

**Orden de ejecución:** 1º. **Modelo asignado:** Opus última versión (alternativa: GPT Ultra). El esquema es lo más caro de rehacer; todo lo demás se apoya en él.
**Depende de:** nada. **Bloquea a:** todas las demás.

**Insumos:** secciones 0, 3 y 5 de este documento; flujo de trabajo de la sección 2.1 (branch `certificador/fase-0-modelo-datos`; **verificar antes que `main` esté limpio** — prerrequisito 2.1); `app/models/field_photo.rb` y `app/models/conversation_session.rb` como referencia de estilo; `db/schema.rb`.

**Alcance núcleo (se ejecuta ahora — es el "modelo mínimo de borrador" del plan de septiembre, sección 3.2):**

- `CertificationReport`: `account_id` (NOT NULL, indexado), `user_id` (**NOT NULL, indexado** — "mis informes" es propiedad del usuario, no solo de la cuenta; regla fija 12), estado (`en_progreso` / `listo_revision` / `enviado`), datos del edificio (nombre, comuna, calle, número, destino, fecha de recepción municipal definitiva — todos opcionales salvo un nombre identificable), N° interno, fecha inspección, empresa mantenedora y técnico mantenedor (texto libre), timestamps.
- `InspectionFinding`: `certification_report_id` (NOT NULL), texto del hallazgo (el texto **confirmado**; la trazabilidad al dictado llega por FK en la Fase 4), ubicación (texto libre, no piso obligatorio — restricción de usabilidad de la entrevista), `field_photo_id` (nullable, FK real a `field_photos`), `position` para orden manual, y columnas opcionales del certificador creadas desde ya para evitar una segunda migración — `inspection_item` (entero, nullable), `nch2840_box`, `norm_point`, `severity` (enum `leve`/`grave`, **nullable, solo lo asigna el humano**) — cuya **superficie de UI queda condicionada** (sección 2.2, gap 1).
- **Política de retención de evidencia (regla fija 10, gap 2):** modificar `FieldPhotoRetentionJob` para excluir de la purga toda foto referenciada por un hallazgo (`where.not(id: InspectionFinding.where.not(field_photo_id: nil).select(:field_photo_id))`); agregar la FK como respaldo; invertir el orden del job — destruir la fila **antes** de borrar el prefijo S3, para que una violación de FK aborte sin haber perdido los bytes.
- Fixtures mínimos (un informe con 3 hallazgos, uno con foto) para que las Fases 2, 4 y 5 testeen sin UI.

**Alcance extendido (condicionado — se ejecuta junto con la Fase 1, tras el gate del 2-oct):** `ReportEquipment` (un informe cubre 1..n equipos; todos los campos técnicos opcionales — regla fija 4), `report_equipment_id` nullable en `InspectionFinding`, `NormativeGroupResolver` (PORO determinista: fecha de recepción → grupo 1/2/3 → normas aplicables, tabla del Plan General sección 4, con tests de bordes de fecha exactos), constantes de los 8 ítems CENTRAVE con i18n (`certifier.es.yml` / `certifier.en.yml`), seeds del informe de ejemplo realista (sección 3.1).

**No incluye:** UI, voz, export, catálogo de casillas NCh 2840, y — hasta su condición de activación — el alcance extendido.

**Criterios de aceptación (núcleo):** migraciones reversibles; unique/índices coherentes con tenancy y con la propiedad por usuario; tests Minitest de modelos; test de retención de evidencia (una foto vinculada a un hallazgo sobrevive la purga, una no vinculada se purga); `ConversationSession` intacto; fixtures cargan.

**Prompt de lanzamiento (Opus última versión · effort high):**

> Lee `docs/PLAN_IMPLEMENTACION_CERTIFICADOR_2026-08-09.md` completo, con foco en las secciones 0, 2.2 y la Fase 0. Crea el branch `certificador/fase-0-modelo-datos` desde `main` actualizado. Ejecuta **solo el alcance núcleo** de la Fase 0 — el extendido está condicionado y no se toca. No negociable: `user_id` NOT NULL en `certification_reports`; política de retención de evidencia con test de que una foto vinculada a un hallazgo sobrevive `FieldPhotoRetentionJob` (regla fija 10); migraciones reversibles; `ConversationSession` intacto. Lee `app/AGENTS.md` y `test/AGENTS.md` antes de tocar esos directorios. Minitest para todo cambio de comportamiento; corre la suite local antes de cerrar. Al terminar: llena "Cierre de fase" de la Fase 0 y actualiza los "Insumos" de las Fases 2 y 4 con lo que hayas descubierto.

### Cierre de fase (lo llena el ejecutor)

- **Estado: cerrada** — 2026-09-08, branch `certificador/fase-0-modelo-datos` desde `main` limpio y al día con `origin/main`. Solo alcance núcleo; el extendido no se tocó. Suite local completa verde: **2513 runs, 10055 assertions, 0 failures, 0 errors, 189 skips** (los skips son los preexistentes de WhatsApp dormido). Rubocop sin ofensas. `ConversationSession` y todo `app/services` / `app/controllers` sin una línea de diff.

**Entregado:** migraciones `20260908180000_create_certification_reports` y `20260908180100_create_inspection_findings`; modelos `CertificationReport` e `InspectionFinding`; `has_many :certification_reports` en `Account`; política de retención de evidencia en `FieldPhotoRetentionJob`; fixtures `certification_reports` / `inspection_findings` / `field_photos`; tests de modelo (2 archivos nuevos) y 4 tests nuevos de retención.

**Criterios de aceptación, verificados uno por uno:**

- *Migraciones reversibles:* probado el round-trip real `db:rollback:primary STEP=2` → `db:migrate`, no solo asumido por usar `create_table`.
- *`user_id` NOT NULL:* además de `belongs_to :user`, hay test que inserta por SQL crudo sin `user_id` y espera `ActiveRecord::NotNullViolation` — la garantía es de la base, no del modelo.
- *Retención de evidencia:* una foto vinculada a un hallazgo sobrevive la purga y una no vinculada se purga, con los bytes de la evidencia intactos en S3.
- *Aislamiento:* `owned_by(account_id:, user_id:)` testeado en los dos ejes (otra cuenta y otro usuario de la misma cuenta).
- *Fixtures cargan* y `ConversationSession` intacto.

**Hallazgos:**

1. **Los tests de retención se validaron por mutación, no solo por color verde.** Un test que solo comprueba "la foto sobrevivió" pasa igual con la exclusión borrada, porque la FK la salva de todos modos: las dos capas producen el mismo resultado observable. Se resolvió haciendo que `FieldPhotoRetentionJob#perform` devuelva `{ purged:, kept:, aborted: }`; una corrida sana tiene `aborted == 0` (protege la consulta, no la constraint). Verificado borrando la exclusión (2 tests fallan: `aborted` pasa a 1) y volviendo a invertir el orden a S3-primero (2 tests fallan: los bytes de la evidencia se borran antes del abort de la FK). **Fase 4 debe replicar este patrón en la purga de audio: sin el contador, su test de "un dictado sin confirmar no es purgado" pasaría por la razón equivocada.**
2. **Las fixtures con FK reales exigen un rol de Postgres que pueda desactivar triggers (superusuario).** Rails carga fixtures con un `DELETE FROM` por tabla en orden alfabético dentro de una transacción, envuelto en `disable_referential_integrity`, que hace `ALTER TABLE … DISABLE TRIGGER ALL` — privilegio de superusuario, sin fallback diferido en Rails 8.1. `accounts` se borra primero y choca con las FK de `certification_reports` / `field_photos`. **CI pasa** (conecta como `postgres`, superusuario), pero el default local de `config/database.yml` es `app_user`, que no lo es: falla con `PG::InsufficientPrivilege` + `PG::ForeignKeyViolation` en **la segunda corrida en adelante** (la primera pasa porque no hay filas que borrar). Este es el primer set de fixtures del repo con FK reales — antes solo `field_photos` y `technician_documents` tenían FK y ninguna tenía fixtures. **Localmente la suite se corre como `DB_USERNAME=lahirisan bin/rails test`** (rol superusuario ya existente; las bases `smart_deal_test*` siguen siendo de `app_user`, así que no cambia propiedad de objetos). Cualquier fase que agregue fixtures a tablas con FK hereda esta condición.
3. **`S3DocumentsService#delete_prefix` nunca levanta excepción:** rescata `StandardError` y devuelve `0`. Es decir, la inversión "fila antes que S3" protege contra el abort de la FK, **no** contra un fallo de S3: si S3 falla después de destruir la fila, los bytes quedan huérfanos y el job no se enteraba. Se agregó un `warn` con el prefijo cuando `delete_prefix` devuelve 0, para que ese caso sea recuperable a mano. No se convirtió en excepción a propósito: la fila ya no existe y re-levantar solo abortaría el resto del lote.
4. **No hizo falta savepoint explícito para el abort de la FK.** La transacción de fixtures de Rails es `joinable: false`, así que `photo.destroy!` abre savepoint propio y el `ActiveRecord::InvalidForeignKey` no envenena la transacción del test; en producción el job corre sin transacción ambiente. Se descartó un `transaction(requires_new: true)` por innecesario.
5. **Rails autogenera nombres de índice con hash cuando superan 63 caracteres** (`idx_on_account_id_user_id_created_at_9358e260e0`). Los dos índices compuestos se nombraron explícitamente (`idx_certification_reports_account_user_recent`, `idx_inspection_findings_report_position`), siguiendo el estilo del repo.
6. **`db/schema.rb` está excluido de Rubocop pero commiteado con espaciado `[ "x" ]`**, que el dumper de Rails no produce: regenerarlo reformatea el archivo entero (89 líneas de ruido). El diff se dejó en 43 líneas puramente aditivas aplicando a mano las tablas nuevas y verificando por script que el resultado es equivalente byte a byte al dump. `db:migrate` también reescribe `db/{cable,cache,queue}_schema.rb` con el mismo ruido: revertirlos.
7. **Orden de asociaciones en `Account`:** `has_many :certification_reports, dependent: :restrict_with_error` va declarado **antes** de `has_many :field_photos, dependent: :destroy`. Al revés, destruir una cuenta intentaría cascadear las fotos y moriría con `InvalidForeignKey` desde `inspection_findings` en vez de con un error de validación limpio. Hay test que lo fija.
8. **Decisiones de nomenclatura** (para que las fases siguientes no las re-litiguen): columnas en inglés, valores de enum en español (`en_progreso`/`listo_revision`/`enviado`, `leve`/`grave`), como `BedrockQuery`. El texto confirmado del hallazgo es `body`. `status` **no** tiene estado de veredicto (regla fija 1) y hay test que fija las tres claves. `user_id` es `bigint` NOT NULL **sin** FK, siguiendo el patrón del repo (`conversation_sessions`, `field_photos`, `pilot_events`); la presencia la garantiza `belongs_to :user`.

**Desviaciones del plan:**

1. **`InspectionFinding` lleva `account_id` (NOT NULL, FK, indexado), que no estaba en la lista de columnas de la fase.** La regla fija 8 ("todo modelo nuevo lleva `account_id` y sigue el scoping por host") es explícita y la sección 0 manda sobre el detalle de la fase; la lista de columnas omitía el campo, no lo prohibía. Se hereda del informe en `before_validation` y una validación exige que coincida con el informe, así que no puede divergir. Beneficio concreto: scoping por cuenta sin join en cualquier consulta futura de hallazgos.
2. **Validación extra: la foto de un hallazgo debe ser de la misma cuenta que el informe.** Cuatro líneas que cierran una fuga de tenancy real (un `field_photo_id` de otra cuenta llegando por params). Con test.
3. **`FieldPhotoRetentionJob#perform` ahora devuelve un resumen** (`{ purged:, kept:, aborted: }`) además de loguearlo. Solid Queue ignora el valor de retorno; existe para que los tests distingan las dos capas de la política (ver hallazgo 1).
4. **No se agregó índice sobre `status`.** El índice compuesto `[account_id, user_id, created_at]` cubre la lista de "mis informes"; filtrar por estado sobre las pocas filas de un usuario no lo justifica todavía. Si la Fase 2 mide lo contrario, es una migración de una línea.

**Actualizaciones aplicadas a fases siguientes:** bloques *Insumos* de la **Fase 2** y la **Fase 4** reescritos con lo anterior (fixtures y scopes disponibles, requisito de rol superusuario para correr la suite local, patrón de contador para la purga de audio, límite de nombre de índice, orden de asociaciones y nomenclatura ya fijada). La Fase 1 no se tocó: sigue condicionada y su insumo real es el tramo extendido, que no se ejecutó.

---

## Fase 1 — Exportable HTML con hoja de impresión

**Estado: CONDICIONADA** (sección 2.2, gap 1). **Condición de activación:** gate del 2 de octubre superado con uso real (plan de septiembre, sección 8), o un validador real (Carlos u otro certificador) pide el exportable para avanzar. **Modelo asignado:** Sonnet última versión (alternativa: Fable última versión). Render determinista sobre datos conocidos.
**Depende de:** Fase 0 — incluido su alcance extendido, que se ejecuta junto con esta fase. **Bloquea a:** Fase 3.

**Insumos:** PDF de evidencia (sección 3.1) como plantilla visual; seeds de la Fase 0; `app/views/AGENTS.md` (Tailwind, mobile-first); ruta y flag según sección 2.1 (member `get :export`, guard `CERTIFIER_MODULE_ENABLED` desde esta fase, que es la primera con superficie visible). *(Actualizar con hallazgos de Fase 0.)*

**Alcance:**

- Vista `certification_reports/:id/export` (HTML + CSS de impresión `@media print`), replicando la estructura del informe real: encabezado de identificación, tabla de defectos graves, resultado **(sección que Danebo deja en blanco o con lo que el certificador haya marcado — Danebo no aprueba ni rechaza)**, tabla de defectos leves, hallazgos agrupados por ítem CENTRAVE con foto miniatura, norma aplicable derivada (rotulada "norma aplicable según fecha de recepción — ayuda documental").
- **Marca de agua BORRADOR** en toda página, no removible por CSS de impresión.
- Sin gem nueva, sin costo de servidor: el certificador imprime/guarda como PDF desde el dispositivo.
- Tailwind print utilities (`print:`) donde alcance; hoja dedicada si no.

**Criterios de aceptación:** el informe de ejemplo de seeds rinde las secciones en el orden del informe real; marca BORRADOR presente en todas las páginas al imprimir; fotos con presigned URL (`FieldPhotoUrlService`); test de controlador con aislamiento en dos ejes (cuenta ajena: 404; otro usuario de la misma cuenta: 404 — regla fija 12) + test de vista mínimo.

**Prompt de lanzamiento (Sonnet última versión · effort medium) — solo con la condición de activación registrada:**

> Lee `docs/PLAN_IMPLEMENTACION_CERTIFICADOR_2026-08-09.md` completo; verifica en el cierre de esta fase que la condición de activación esté registrada como cumplida — si no lo está, detente. Crea `certificador/fase-1-exportable` desde `main`. Ejecuta primero el alcance extendido de la Fase 0 (ReportEquipment, NormativeGroupResolver, ítems CENTRAVE, seeds) si ninguna fase anterior lo hizo, y después el exportable. No negociable: marca BORRADOR en toda página; la sección de resultado queda en blanco o con lo que el certificador marcó (regla fija 1); guard `CERTIFIER_MODULE_ENABLED`; tests de aislamiento cross-account y cross-user. Lee `app/views/AGENTS.md` antes de tocar vistas. Cierra con la suite verde y el bloque de cierre actualizado.

### Cierre de fase (lo llena el ejecutor)
- Estado: condicionada — no ejecutar sin la condición de activación
- Hallazgos:
- Desviaciones del plan:
- Actualizaciones aplicadas a fases siguientes:

---

## Fase 2 — Lista "mis informes" + editor del borrador

**Orden de ejecución:** 2º. **Modelo asignado:** Sonnet última versión (alternativa: Fable última versión).
**Depende de:** Fase 0 (núcleo). La vista de la Fase 1 ya no es insumo: el botón "exportar" aparece recién cuando la Fase 1 (condicionada) se active.

**Insumos:** `app/javascript/AGENTS.md` y `app/views/AGENTS.md`; rutas y flag según sección 2.1 (`resources :certification_reports`, `CERTIFIER_MODULE_ENABLED`); referencias de UX de la sección 2.3 (patrón SafetyCulture: foto+hallazgo en un solo flujo; cifras de tap target); mockup HTML+Tailwind opcional (sección 2.1).

*Actualizado con el cierre de la Fase 0 (2026-09-08):*

- **La suite local se corre con un rol superusuario de Postgres:** `DB_USERNAME=lahirisan bin/rails test`. Con el default `app_user` las fixtures del certificador fallan de la segunda corrida en adelante (`PG::InsufficientPrivilege` al no poder desactivar triggers, luego `ForeignKeyViolation` al borrar `accounts`). CI no lo nota porque conecta como `postgres`. Si esta fase agrega fixtures a tablas con FK, hereda la condición.
- **Ya existe lo que la lista necesita, no lo reimplementes:** `CertificationReport.owned_by(account_id:, user_id:)` (los dos ejes de aislamiento en un scope), `.recent_first`, `has_many :inspection_findings` ya ordenado por `(position, id)`, e `InspectionFinding.with_photo`. Para la lista sin N+1 no hay counter cache: usa `includes(:inspection_findings)` o un `group(...).count` explícito — evaluar cuál según lo que muestre la vista.
- **Fixtures disponibles:** `certification_reports(:torre_amunategui)` (propiedad de `users(:one)` de `accounts(:legacy)`, estado `en_progreso`, datos del edificio del informe real) con tres hallazgos `inspection_findings(:cabina_puerta, :pozo_iluminacion, :maquinas_carpeta)` en posiciones 0/1/2, y `field_photos(:cabina_evidence)` adjunta al primero. **No hay fixture de un segundo usuario de `accounts(:legacy)`**: el test de "otro usuario de la misma cuenta recibe 404" tiene que crearlo (`User.create!(email:, password:, account: accounts(:legacy))`), como hace `test/models/certification_report_test.rb`.
- **Campos y contratos ya fijados:** el único campo obligatorio al crear es `building_name` (todo el resto del edificio es opcional — regla fija 4, con test). Estados: `en_progreso` / `listo_revision` / `enviado`, sin estado de veredicto (regla fija 1). El texto del hallazgo es `body`; `location` es texto libre opcional; `position` viene con default 0.
- **Adjuntar foto:** `InspectionFinding` ya valida que la foto sea de la misma cuenta que el informe, así que un `field_photo_id` ajeno rebota en el modelo — pero el controlador igual debe buscar la foto dentro de `current_account`, no confiar solo en la validación.
- **Ojo al borrar:** destruir un informe destruye sus hallazgos (`dependent: :destroy`) y con eso **libera sus fotos para la purga** de `FieldPhotoRetentionJob`. Es el comportamiento correcto, pero si la UI ofrece "borrar informe" conviene que el copy lo diga.
- **Nada de UI se construyó en la Fase 0** (no había superficie visible, por eso mergeó sin flag). Esta fase es la primera que necesita el guard `CERTIFIER_MODULE_ENABLED`.
- **Al regenerar el schema:** `db/schema.rb` está fuera de Rubocop pero commiteado con espaciado `[ "x" ]`; un dump crudo reformatea el archivo entero. Revertir también `db/{cable,cache,queue}_schema.rb`, que `db:migrate` reescribe con el mismo ruido.

**Alcance:**

- Lista mínima "mis informes": **solo borradores del usuario** (propiedad por `user_id`, no solo por cuenta — regla fija 12), orden por fecha, botón retomar. **No** un browser genérico de conversaciones — esto es la "revisión simple de los hallazgos acumulados" del plan de septiembre (sección 2.1, punto 6).
- Crear informe (datos de edificio mínimos), agregar/editar/borrar hallazgos de texto, adjuntar foto (reutilizando el flujo `FieldPhoto`, en un solo flujo sin pantalla intermedia — patrón SafetyCulture, sección 2.3), cambiar estado del informe.
- **Condicionado (se activa con el tramo extendido de la Fase 0 y la Fase 1):** norma derivada al crear, reordenar hallazgos, asignar ítem CENTRAVE, casilla, punto y gravedad. Las columnas ya existen desde la Fase 0; solo la superficie de UI espera el gate.
- Mobile-first: tap targets **mínimo 60px, 72px en la acción primaria, 16px de espaciado** (cifras de la sección 2.3, no "grandes" a criterio); mínimo tipeo; alto contraste (guantes, poca luz). Hotwire/Turbo, sin estado SPA.
- El editor debe funcionar **sin** voz: texto tecleado es el fallback permanente y lo que se prueba primero.

**Criterios de aceptación:** un usuario crea un informe, agrega 3 hallazgos con foto, cierra sesión, vuelve y lo encuentra intacto (plan de septiembre, sección 10, puntos 1–2, versión sin voz); aislamiento testeado en dos ejes — cuenta ajena: 404; **otro usuario de la misma cuenta: 404** (los informes no se comparten dentro de la cuenta en esta etapa; regla fija 12); tap targets verificados contra las cifras de la sección 2.3; tests de controlador; sin N+1 en la lista (includes de counts/fotos).

**Prompt de lanzamiento (Sonnet última versión · effort medium):**

> Lee `docs/PLAN_IMPLEMENTACION_CERTIFICADOR_2026-08-09.md` completo, con foco en la sección 2.3 (referencias de UX y cifras de tap target), el cierre de la Fase 0 y la Fase 2. Crea `certificador/fase-2-mis-informes` desde `main`. **Corre la suite local con `DB_USERNAME=lahirisan bin/rails test`** (hallazgo 2 del cierre de la Fase 0: el `app_user` default no puede desactivar triggers para las fixtures con FK). Reusa `CertificationReport.owned_by(account_id:, user_id:)`, `.recent_first` e `InspectionFinding.with_photo` — no los reimplementes. Ejecuta solo el alcance mínimo — el bloque "Condicionado" no se construye. No negociable: propiedad por usuario ("mis informes" filtra por `user_id`; otro usuario de la misma cuenta recibe 404, con test); guard `CERTIFIER_MODULE_ENABLED` en navegación y controladores (404 sin flag); tap targets mínimo 60px (72px en acciones primarias, 16px de espaciado — sección 2.3), mínimo tipeo, alto contraste; adjuntar foto a un hallazgo en un solo flujo sin pantalla intermedia; Hotwire sin estado SPA; el editor funciona sin voz. Lee `app/views/AGENTS.md` y `app/javascript/AGENTS.md` antes de tocar esos directorios. Cierra con el test de cerrar sesión/reabrir intacto en verde y el bloque de cierre actualizado; actualiza los "Insumos" de la Fase 5.

### Cierre de fase (lo llena el ejecutor)

- **Estado: cerrada** — 2026-09-08, branch `certificador/fase-2-mis-informes` desde `main` limpio. Solo el alcance mínimo — el bloque "Condicionado" (norma derivada, reordenar, ítem CENTRAVE/casilla/punto/gravedad) no se tocó. Suite local completa verde con `DB_USERNAME=lahirisan bin/rails test`: **2552 runs, 10180 assertions, 0 failures, 0 errors, 189 skips** (2513/10055/189 de la Fase 0 + 39 tests nuevos de esta fase). Rubocop (`bundle exec rubocop`, sin `--cache`, disco de caché de `~/.cache` no escribible en este entorno) sin ofensas sobre las 558 files del repo. `ConversationSession` y todo `app/services`/`app/prompts` preexistente sin una línea de diff salvo el fix de aislamiento de test descrito en el hallazgo 3.

**Entregado:**

- `CertifierModuleFlag` (`app/services/certifier_module_flag.rb`) + `CertifierModuleGuard` (`app/controllers/concerns/`), el mismo patrón `module_function`/`enabled?` que `Rag::EvidenceCardsFlag`, aplicado a `CertificationReportsController` e `InspectionFindingsController` — 404 sin `ENV["CERTIFIER_MODULE_ENABLED"] == "true"`, gate también en la entrada de navegación del layout.
- Rutas REST planas: `resources :certification_reports` con `resources :inspection_findings, only: %i[create]` anidado (adjuntar hallazgo+foto en un solo POST) y `resources :inspection_findings, only: %i[edit update destroy]` a nivel raíz (edición/borrado no necesitan el id del informe en la URL).
- `CertificationReportsController` (index/show/new/create/edit/update/destroy) e `InspectionFindingsController` (create/edit/update/destroy), reusando `CertificationReport.owned_by(account_id:, user_id:)`, `.recent_first` e `InspectionFinding.with_photo` sin reimplementarlos, como pedía el insumo de esta fase.
- `InspectionFindingPhotoAttacher` (PORO en `app/services/`): adapta un `ActionDispatch::Http::UploadedFile` del campo de foto del propio formulario de hallazgo al contrato ya existente de `ImageCompressionService.compress_with_thumbnail` + `FieldPhotoStore.persist!` — cero código nuevo de compresión/S3, solo el pegamento entre un upload directo y el pipeline que ya usaba el chat.
- Vistas Tailwind mobile-first: `certification_reports/{index,new,edit,show,_building_fields,_finding,_errors}` e `inspection_findings/edit`, con tap targets `min-h-[60px]` (mínimo) y `min-h-[72px]` en la acción primaria de cada pantalla (nuevo informe, agregar hallazgo, guardar hallazgo), `gap-4`/`space-y-4` (16px) entre controles adyacentes, y paleta de alto contraste ya usada en el resto de la app (`hsl(222,47%,10%)` sobre blanco).
- `config/locales/certifier.{es,en}.yml` pareados, siguiendo el patrón `rag.*`.
- 39 tests nuevos: `CertifierModuleFlagTest`, `InspectionFindingPhotoAttacherTest`, `CertificationReportsControllerTest`, `InspectionFindingsControllerTest`, `CertifierModuleFlowTest` (el test de cierre: crear informe, agregar 3 hallazgos con foto, cerrar sesión, volver a entrar y encontrarlo intacto).

**Criterios de aceptación, verificados uno por uno:**

- *Propiedad por usuario:* `owned_reports`/`owned_finding` filtran siempre por `account_id` **y** `user_id`; test explícito de que un segundo usuario de `accounts(:legacy)` (creado en el test, como anticipaba el insumo) recibe 404 en show/edit/update/destroy de informe y en edit/update/destroy de hallazgo — no solo el eje cross-account.
- *Guard del flag:* test de 404 en index y show con `ENV["CERTIFIER_MODULE_ENABLED"]` sin definir; el link de navegación solo se renderiza con el flag activo (verificado por inspección del layout, no hay superficie de UI que lo revele si está apagado).
- *Tap targets:* verificados por assertion sobre el HTML renderizado (`assert_match(/min-h-\[72px\]/, ...)`, `/min-h-\[60px\]/`, `/space-y-4|gap-4/`) en vez de revisión subjetiva — las cifras de la sección 2.3 son literales en las clases Tailwind, no aproximadas.
- *Adjuntar foto en un solo flujo:* el mismo formulario/POST que crea el hallazgo lleva el campo de archivo (`capture="environment"`); no hay pantalla intermedia. Test que confirma un solo request crea el hallazgo y adjunta la foto.
- *Sin N+1 en la lista:* test que cuenta las queries SQL emitidas (`ActiveSupport::Notifications.subscribed("sql.active_record")`) y afirma exactamente una consulta a `inspection_findings` sin importar cuántos informes tenga el usuario — usa `includes(:inspection_findings)`, no counter cache (no hacía falta, Fase 0 ya lo había descartado).
- *Editor funciona sin voz:* todos los campos son texto tecleado nativo; no hay ninguna dependencia de audio en esta fase (llega en la Fase 5).
- *Criterio de cierre (crear + 3 hallazgos + cerrar sesión + reabrir intacto):* `CertifierModuleFlowTest` verde — crea el informe, agrega 3 hallazgos (uno con foto), `sign_out`, confirma 302 a login, `sign_in` de nuevo, y verifica que el `show` y el `index` siguen mostrando todo.

**Hallazgos:**

1. **`link_to` con bloque no acepta un primer argumento de texto — bug de implementación, no de arquitectura.** `link_to text, url, html_options do ... end` desplaza silenciosamente los argumentos: `text` pasa a ser la URL, `url` pasa a ser `html_options` (un String, no un Hash), y el bloque se vuelve el contenido real del enlace. El error solo aparece en runtime (`undefined method 'stringify_keys' for an instance of String`) al primer render con datos reales; los tests de fixtures sin request nunca lo habrían atrapado si la vista no se ejecuta. Corregido en `certification_reports/index.html.erb` (el único sitio donde se cometió). Vale como recordatorio para cualquier vista nueva del módulo: `link_to` con bloque nunca lleva el texto como primer argumento.
2. **`CertificationReport.order(:id).last` (y el equivalente en `InspectionFinding`) no es un lookup seguro para verificar un registro recién creado cuando el fixture set ya cargó filas con IDs generados por hash (`ActiveRecord::FixtureSet.identify`).** Esos IDs son típicamente mayores que los que asigna la secuencia real de Postgres a una fila insertada por `create!` en el mismo test — `order(:id).last` devuelve el fixture, no la fila nueva, y el test pasa "por la razón equivocada" porque el fixture usado (`torre_amunategui`, mismo usuario/cuenta/estado) casualiza casi todas las aserciones. Los cuatro tests que lo hacían se corrigieron a `find_by!(atributo_único: ...)`. Cualquier test futuro que islice "la última fila creada" en una tabla con fixtures debe evitar `order(:id).last` por el mismo motivo.
3. **Bug preexistente en `test/services/kb_document_thumbnail_from_s3_test.rb`: su bloque `ensure` "restauraba" `ImageCompressionService.compress_with_thumbnail` con un wrapper que solo reenviaba `*args`, sin `**kwargs`.** Esto no rompía nada mientras ningún llamador posterior en el mismo proceso de test pasara keywords (`filename:`, `correlation_id:`) — pero `InspectionFindingPhotoAttacher` sí los pasa, y cuando ese test corría antes en el mismo worker paralelo, el singleton method quedaba permanentemente roto (`ArgumentError: wrong number of arguments (given 3, expected 2)`) para cualquier test posterior en el mismo proceso, de forma no determinista según el seed/orden de ejecución. Corregido a `{ |*args, **kwargs| original_compress.call(*args, **kwargs) }` — un fix de una línea, sin tocar código de producción, que además blinda cualquier fase futura (4, 5, 7) que también llame `compress_with_thumbnail` con keywords.
4. **La foto se adjunta creando un `FieldPhoto` nuevo en el propio request del hallazgo, no reutilizando un `field_photo_id` preexistente del chat.** El insumo de la fase advertía "el controlador debe buscar la foto dentro de `current_account`, no confiar solo en la validación" pensando en un flujo que recibiera un `field_photo_id` ya existente; en la práctica no existe todavía ningún endpoint de creación de `FieldPhoto` fuera del pipeline de análisis del chat (`FieldPhotosController` solo tiene `show`). Se optó por `InspectionFindingPhotoAttacher`, que llama a `FieldPhotoStore.persist!` con `account_id: current_account.id` directamente — el registro nace ya scopeado a la cuenta correcta, así que la advertencia del insumo queda satisfecha por construcción en vez de por un chequeo posterior.
5. **Cambio de estado del informe con guardado explícito, no `onchange` autosubmit.** Se consideró un `<select>` que enviara el formulario solo al cambiar, pero con guantes un cambio accidental de valor (o un focus/blur torpe) dispararía un submit no deseado sin confirmación visual — se prefirió un botón "Guardar estado" separado, más previsible, en línea con "corrección en un paso" pero sin sorpresas (sección 2.3, guideline de confirmación de Google: implícita para lo barato de deshacer, pero un cambio de estado del informe no es tan barato como para no pedir un tap explícito).
6. **`enum` de Rails lanza `ArgumentError` en la asignación, no en la validación, ante un valor de `status` fuera de `STATUSES`.** `@report.update(status: "aprobado")` explota antes de llegar a `save`, así que el `unprocessable_entity` normal (`if @report.update(...) ... else render :edit ...`) no lo captura — se agregó `rescue ArgumentError` a nivel de método en `update` para devolver 422 en vez de un 500, con test explícito.

**Desviaciones del plan:**

1. **No se usó Turbo Stream/Frame para nada del CRUD** — cada acción hace un redirect de página completa. El plan pedía "Hotwire sin estado SPA"; Turbo Drive (activo por defecto) ya da la sensación de app sin JS a medida y sin el riesgo de estado implícito que traería Turbo Streams para una fase de alcance mínimo. Se deja como mejora futura si la latencia percibida en 3G real lo justifica.
2. **La foto se resuelve con `f.file_field` nativo (`capture="environment"`) en vez de un flujo `MediaRecorder`/Stimulus.** No corresponde a esta fase (eso es voz, Fase 5) — para foto, el input de archivo nativo con `capture` ya abre la cámara directo en móvil sin código adicional, cumpliendo "un solo flujo, sin pantalla intermedia" sin necesitar JavaScript nuevo (regla de minimizar JS de `app/javascript/AGENTS.md`).
3. **El formulario de "nuevo informe" colapsa los campos opcionales bajo un `<details>`** en vez de mostrarlos siempre — no estaba explícito en el plan, pero maximiza "mínimo tipeo" (sección 2.3): la única fricción obligatoria para crear un borrador es escribir el nombre del edificio.

**Actualizaciones aplicadas a fases siguientes:** bloque *Insumos* de la **Fase 5** reescrito con los hallazgos 1–3 de arriba (bug de `link_to` con bloque, `order(:id).last` inseguro contra fixtures con ID hasheado, y el bug de restauración de `compress_with_thumbnail` en `kb_document_thumbnail_from_s3_test.rb` — relevante porque la Fase 5 también llama esa misma función al procesar la evidencia de un dictado) y con el patrón de guardado explícito para cambios de estado/campos sensibles con guantes (hallazgo 5). Las Fases 4, 6 y 7 no se tocaron: esta fase no descubrió nada que las afecte directamente.

---

## Fase 3 — PDF server-side (condicionada)

**Modelo asignado:** Grok (variante rápida; alternativa: Sonnet última versión). Trabajo de una tarde con criterios cerrados.
**Depende de:** Fase 1 (a su vez condicionada). **Condición de activación:** un certificador real (o la demo con TAQUIÓN-CERT) pide un archivo adjuntable a la Carpeta Cero, **o** la validación de formato de la Fase 1 quedó aprobada y sobra capacidad. No se activa antes.

**Insumos:** vista de la Fase 1. *(Actualizar con hallazgos de Fases 1–2.)*

**Alcance:** gem `grover` o `ferrum` (headless Chrome) rendereando la misma vista HTML de la Fase 1 → botón "Descargar PDF". Nota de deploy: Chrome/Chromium en la imagen de producción — documentar el costo operativo antes de mergear. La marca BORRADOR persiste.

**Criterios de aceptación:** PDF binario válido generado desde el informe de ejemplo; test que verifica header `%PDF` y páginas > 0; sin regresión en la vista HTML.

**Prompt de lanzamiento (Grok, variante rápida · effort low, sin thinking extendido) — solo con la condición de activación registrada:**

> Lee `docs/PLAN_IMPLEMENTACION_CERTIFICADOR_2026-08-09.md` (secciones 0 y 2.2, cierres de Fases 1–2, Fase 3); verifica que la condición de activación esté registrada — si no lo está, detente. Crea `certificador/fase-3-pdf` desde `main`. Renderiza la misma vista HTML de la Fase 1 con `grover` o `ferrum` hacia un botón "Descargar PDF"; documenta el costo operativo de Chrome/Chromium en la imagen de producción antes de mergear. La marca BORRADOR persiste. Test de header `%PDF` y páginas > 0; sin regresión en la vista HTML. Cierra el bloque de fase.

### Cierre de fase (lo llena el ejecutor)
- Estado: condicionada — no ejecutar sin la condición de activación
- Hallazgos:
- Desviaciones del plan:
- Actualizaciones aplicadas a fases siguientes:

---

## Fase 4 — Capa de transcripción agnóstica al proveedor

**Orden de ejecución:** 3º. **Modelo asignado:** Opus última versión (alternativa: GPT Ultra) — el contrato del adapter, la máquina de estados y el contrato de confirmación son lo caro de rehacer; la implementación de cada adapter puede quedar en la misma sesión.
**Depende de:** Fase 0 (núcleo). **Bloquea a:** Fases 5, 6, 7.

**Insumos:** sección 4 (costos y proveedores); patrón `FieldPhoto` (S3 + job + fila durable); patrón de inyección `client:`; `ClaudeChunkingClient` como referencia de cliente HTTP a API externa.

*Actualizado con el cierre de la Fase 0 (2026-09-08):*

- **El test de retención de audio necesita un contador, no solo un assert de supervivencia.** Lección medida en la Fase 0: un test que solo verifica "el dictado sin confirmar sigue ahí" pasa igual si la exclusión está rota, porque cualquier segunda capa lo salva. `FieldPhotoRetentionJob#perform` devuelve `{ purged:, kept:, aborted: }` y sus tests afirman `aborted == 0` en la corrida sana; **replica ese contrato en la purga de audio** y valida por mutación (rompe la exclusión y comprueba que el test falla). El job de fotos es la referencia directa para el orden seguro fila-antes-que-S3 y para la consulta de exclusión.
- **`S3DocumentsService#delete_prefix` rescata `StandardError` y devuelve `0`, nunca levanta.** El orden "fila antes que S3" protege contra el abort de una FK, no contra un fallo de S3: si S3 falla con la fila ya destruida, los bytes quedan huérfanos. El job de fotos loguea un `warn` con el prefijo cuando devuelve 0 para que sea recuperable; haz lo mismo con el audio.
- **`inspection_findings` ya existe** y esta fase solo le agrega `voice_dictation_id` + índice único. Dos cosas al hacerlo: (a) **nombra el índice explícitamente** — Rails autogenera nombres con hash pasando 63 caracteres, y el compuesto `[account_id, certification_report_id, sha256]` de `voice_dictations` los supera holgadamente; (b) `inspection_findings.account_id` es **NOT NULL y se hereda del informe en un `before_validation`**, así que un hallazgo creado desde la confirmación de un dictado debe pasar por el modelo (`create!`), o setear `account_id` a mano si alguna vez se usa `insert_all` por idempotencia.
- **El texto confirmado del hallazgo es `body`** (no `text` ni `description`); `severity`, `nch2840_box`, `norm_point` e `inspection_item` existen ya, son nullable y **ningún código de Danebo los escribe** (regla fija 1, con test que lo fija). La confirmación de un dictado solo debe poblar `body`, `location` y `position`.
- **`VoiceDictation` lleva `account_id`** por regla fija 8, igual que `InspectionFinding` — que lo lleva aunque la lista de columnas de la Fase 0 no lo mencionaba. Si lo denormalizas desde el informe, copia el patrón: heredar en `before_validation` **y** validar que coincida, para que no pueda divergir.
- **La suite local se corre con un rol superusuario de Postgres:** `DB_USERNAME=lahirisan bin/rails test`. Con el default `app_user` las fixtures con FK reales fallan de la segunda corrida en adelante (Rails necesita `ALTER TABLE … DISABLE TRIGGER ALL` para cargarlas y no tiene fallback diferido en 8.1). CI conecta como `postgres` y no lo nota. Aplica a cualquier fixture nueva de `voice_dictations`.
- **Si agregas `has_many` a `Account`, cuida el orden de declaración:** los guards `dependent: :restrict_with_error` deben ir antes de `has_many :field_photos, dependent: :destroy`, o destruir una cuenta cascadea fotos y muere con `InvalidForeignKey` desde `inspection_findings` en vez de con un error de validación limpio. Hay test que lo fija.
- **`FieldPhoto` no tiene `belongs_to :user`** (su `user_id` es un `bigint` suelto); si el flujo de audio necesita atribución por usuario, `VoiceDictation` la lleva propia.
- **Al regenerar el schema:** `db/schema.rb` está fuera de Rubocop pero commiteado con espaciado `[ "x" ]`; un dump crudo reformatea el archivo entero. Revertir también `db/{cable,cache,queue}_schema.rb`.

**Alcance:**

- Contrato único: `SpeechToText::Client.for(provider)` → `#transcribe(s3_key:, language:)` → `Result` (texto, duración en segundos, proveedor, metadata cruda). Proveedor por `ENV["STT_PROVIDER"]`, con override por llamada (lo necesita el benchmark de la Fase 6).
- Adapters iniciales: **`AmazonTranscribeAdapter`** (gem `aws-sdk-transcribeservice`, batch, `es-US` — ver corrección de idioma en el diseño más abajo, reutilizando `AwsClientInitializer`) y **`OpenAiAdapter`** (`gpt-4o-mini-transcribe`, HTTP directo sin gem nueva, siguiendo el estilo de `ClaudeChunkingClient`). `GroqAdapter` es opcional en esta fase — la API es Whisper-compatible y puede caer en Fase 6 si el contrato quedó bien hecho; si el ejecutor lo agrega aquí, son ~30 líneas.
- Modelo `VoiceDictation`: `account_id`, `user_id`, `certification_report_id` (nullable), `s3_key_audio` (prefijo `voice_dictations/<account_id>/...`, **fuera de `bulk_chunks/`**), `sha256`, `duration_seconds`, `provider`, `status`, `transcript_raw`, `transcript_edited`, `confirmed_at`, `cost_estimate_usd`. **Telemetría propia — no toca `bedrock_queries`** (regla fija 7). Costo estimado = duración × tarifa del proveedor (tabla de tarifas en constante versionada).
- **Máquina de estados (regla fija 13, gap 5):** `pending` → `transcribing` → `transcribed` | `failed`; `transcribed` → `confirmed`. Las transiciones se hacen con updates condicionales, nunca con asignación directa.
- **Deduplicación por informe, no global (gap 5):** índice único compuesto `[account_id, certification_report_id, sha256]` — un doble upload del mismo audio al mismo informe deduplica (doble tap); el mismo audio en otro informe es una fila nueva legítima. Para `certification_report_id` nulo: `NULLS NOT DISTINCT` (PostgreSQL 15+) o índice parcial equivalente.
- `TranscriptionJob` (Solid Queue): **una sola llamada facturada por dictado** — el job reclama el dictado con compare-and-set atómico (`VoiceDictation.where(id: id, status: :pending).update_all(status: :transcribing) == 1`; si no reclama, termina sin llamar al proveedor), de modo que reintentos y ejecuciones concurrentes no dupliquen el gasto. El resultado se escribe solo si el estado sigue siendo `transcribing` (update condicional): **un resultado tardío que llegue tras la confirmación se descarta y se loguea, jamás sobrescribe `transcript_edited`**. `retry_on` acotado (el reintento vuelve a intentar el claim); creación idempotente con el índice único + `rescue RecordNotUnique → find`.
- **Contrato de confirmación (regla fija 13, gap 5):** confirmar fija `confirmed_at`, congela `transcript_edited` como versión confirmada y crea el `InspectionFinding` con `voice_dictation_id` (migración de esta fase: columna + **índice único** en `inspection_findings.voice_dictation_id`). Doble confirmación — doble tap, requests concurrentes, respuesta tardía del cliente — produce un solo hallazgo y la misma respuesta. El índice único se relaja solo si la Fase 7 (condicionada) se activa y necesita varios hallazgos por dictado.
- Broadcast del resultado por **canal privado del usuario** (`VoiceDictationChannel` nuevo, stream `user:<user_id>:voice_dictations`) — **no** el patrón `KbSyncChannel`/`KbSyncBroadcaster`, que transmite a `account:<id>:kb_sync`, toda la cuenta (regla fija 12, gap 4). Test de canal: un segundo usuario de la misma cuenta no recibe el evento.
- Retención de audio (regla fija 10): job recurrente de purga que **solo toca dictados en estado terminal** (`confirmed`/`failed`) fuera de la ventana — nunca dictados sin confirmar, porque "cerrar y reabrir sin perder audio" es requisito vigente (plan de septiembre, sección 2.1, punto 5). Mismo orden seguro que la Fase 0: fila antes que S3.

**No incluye:** UI de captura (Fase 5), streaming en tiempo real (no lo necesita el dictado batch; queda en backlog), estructuración LLM (Fase 7).

**Criterios de aceptación:** ambos adapters pasan tests con fakes inyectados (sin WebMock, estilo del repo); **una sola llamada facturada bajo concurrencia** (test: dos performs del mismo dictado → el fake del proveedor recibe exactamente una llamada); doble confirmación → un solo hallazgo, misma respuesta; resultado tardío tras confirmación → descartado, `transcript_edited` intacto; un dictado sin confirmar no es purgado por el job de retención; mismo `sha256` en dos informes distintos → dos filas; un audio de prueba real transcrito end-to-end en dev con ambos proveedores; `cost_estimate_usd` poblado; documentado en el cierre cuánto costó la prueba.

**Prompt de lanzamiento (Opus última versión · effort high):**

> Lee `docs/PLAN_IMPLEMENTACION_CERTIFICADOR_2026-08-09.md` completo, con foco en las secciones 0 (reglas 7, 10, 12 y 13), 2.2, 4 y 5, más el cierre de la Fase 0. Crea `certificador/fase-4-transcripcion` desde `main`. Diseña primero y por escrito (en el PR) el contrato `SpeechToText::Client` y la máquina de estados de `VoiceDictation`; después implementa. No negociable: claim atómico antes de llamar al proveedor (dos performs concurrentes → una sola llamada facturada, con test); resultado tardío nunca sobrescribe `transcript_edited`; confirmación idempotente con índice único dictado→hallazgo; dedup por `[account_id, certification_report_id, sha256]`; broadcast por canal privado del usuario con test de que otro usuario de la cuenta no recibe el evento; purga solo de estados terminales; telemetría propia sin tocar `bedrock_queries`. Prueba end-to-end real en dev con Transcribe y OpenAI, y documenta el costo en el cierre. Actualiza los "Insumos" de las Fases 5 y 6.

### Diseño (escrito antes de implementar, 2026-09-08)

Este bloque es el contrato que consumen las Fases 5, 6 y 7. Se escribió y revisó **antes** de escribir código, como exige el prompt de la fase.

#### A. Contrato `SpeechToText::Client`

```ruby
SpeechToText::Client.for(provider = nil, client: nil)   # → adapter
adapter.transcribe(s3_key:, language: "es-CL", duration_hint_seconds: nil)
# → SpeechToText::Result(text:, duration_seconds:, provider:, model:, raw:)
```

- **Resolución de proveedor:** argumento explícito → `ENV["STT_PROVIDER"]` → default `amazon_transcribe`. El override por llamada existe porque la Fase 6 corre el mismo audio por todos los adapters en un solo proceso.
- **Errores:** `SpeechToText::Error` (base) con tres hijos que significan cosas distintas para el job — `ConfigurationError` (falta credencial o bucket: **no hubo llamada al proveedor**, no se facturó nada), `ProviderError` (el proveedor respondió error o se agotó el timeout: pudo haberse facturado), `UnknownProviderError` (nombre de proveedor no registrado).
- **Los adapters no tocan la base de datos ni escriben telemetría.** Reciben una key de S3 y devuelven texto. Estado, costo, broadcast y persistencia viven en el job. Eso es lo que hace que cambiar de proveedor sea configuración y no arquitectura (sección 4).
- `language` es BCP-47 canónico (`es-CL`); **ningún proveedor lo acepta tal cual**, y cada adapter lo estrecha a su propio vocabulario (ver la corrección de idioma abajo). OpenAI y Groq solo aceptan el subtag primario, `es`.
- **Inyección:** `client:` para el doble del SDK/HTTP, patrón ya usado en el repo. Los tests de job reemplazan `SpeechToText::Client.for` por una fake (el repo no usa WebMock).

**Corrección al plan: Amazon Transcribe no tiene `es-CL`.** El alcance de esta fase daba `es-CL` por soportado; la tabla oficial de idiomas de Transcribe no lo lista. Sus únicas variantes de español son `es-ES`, `es-US` y `es-MX`, y pasar `es-CL` hace que la API rechace el job. El adapter mapea el tag canónico a **`es-US`**, con override por `STT_AMAZON_LANGUAGE_CODE`. El criterio fue cobertura de jerga de ascensores en la ruta **batch**, que es la que usamos:

| Código | Variante | Números en batch | Siglas en batch | Custom language models |
|---|---|---|---|---|
| `es-US` | Español, EE.UU. (latinoamericano) | sí | sí | **sí (batch y streaming)** |
| `es-ES` | Español peninsular | sí | sí | no |
| `es-MX` | Español, México | **no** (solo streaming) | sí | no |

- `es-US` es la **única** variante de español que acepta *custom language models*, que es la palanca real contra la jerga del dominio (términos NCh 2840, marcas, códigos de falla) una vez que la Fase 6 tenga corpus; y es léxicamente más cercana al español chileno que la peninsular.
- `es-MX` es la más débil de las tres para este caso a pesar de ser latinoamericana: no transcribe números en batch, y un dictado de inspección está lleno de ellos ("embarque 3", "450 kilos", "código A32.4", "1,6 metros por segundo").
- Los *custom vocabularies* (distintos de los custom language models) sí funcionan en cualquier variante: son la palanca inmediata y barata para las 20 frases técnicas que mide la Fase 6, sin depender de esta elección.
- Precedencia en `#provider_language`: variante soportada pedida explícitamente (la usa el benchmark de la Fase 6) → `STT_AMAZON_LANGUAGE_CODE` → `es-US`. Cualquier otro tag de español colapsa al default; un tag no-español pasa intacto.

**Por qué el contrato es bloqueante aunque Transcribe batch sea asíncrono.** Amazon Transcribe batch es `start_transcription_job` + poll. La alternativa sería un segundo job de polling más una tabla de trabajos en vuelo; en su lugar el adapter hace el poll **dentro** de `TranscriptionJob`, que corre en Solid Queue y no en la ruta de request. Se paga un hilo de worker retenido durante la transcripción y se ahorra una máquina de estados paralela, un fan-out y un loop de polling — el balance que pide la sección 0 (ruta de ejecución directa, sin orquestación innecesaria). El poll está acotado por `STT_POLL_TIMEOUT_SECONDS`; agotarlo levanta `ProviderError` y el dictado queda `failed`, nunca colgado.

#### B. Máquina de estados de `VoiceDictation`

Estados: `pending` → `transcribing` → `transcribed` | `failed`; `transcribed` → `confirmed`. **Terminales:** `confirmed`, `failed`. **No terminales (la purga nunca los toca):** `pending`, `transcribing`, `transcribed`.

Toda transición es **un solo `UPDATE` condicional** (`update_all` sobre un `where` que incluye el estado de origen) y se decide por las filas afectadas. Nunca hay asignación directa de `status`.

| # | Transición | Disparador | Guarda (en el propio `UPDATE`) | Escribe |
|---|---|---|---|---|
| T0 | — → `pending` | `VoiceDictationIntake` | único `[account_id, certification_report_id, sha256]` | fila + audio en S3 |
| T1 | `pending` → `transcribing` | claim de `TranscriptionJob` | `status = pending` **o** (`status = transcribing` y `transcribing_since` < corte de obsolescencia) | `provider`, `transcribing_since`, `transcription_claim_id` nuevo |
| T2 | `transcribing` → `transcribed` | resultado del proveedor | `status = transcribing` **y** `transcription_claim_id` = el claim propio | `transcript_raw`, `duration_seconds`, `cost_estimate_usd` |
| T3 | `transcribing` → `failed` | error del proveedor | misma guarda de claim | `failure_reason` |
| T4 | `transcribed` → `confirmed` | confirmación humana | `status = transcribed` (el lock de fila serializa el doble tap) | `confirmed_at`, congela `transcript_edited`, y crea el `InspectionFinding` en la misma transacción |
| T5 | `failed` → `pending` | reintento humano explícito | `status = failed` **y** `audio_purged_at IS NULL` | limpia `failure_reason` y el claim |
| T6 | purga de audio | job de retención | `status IN (confirmed, failed)` **y** `audio_purged_at IS NULL` | `s3_key_audio` → NULL, `audio_purged_at`; después borra S3 |

**Propiedades que la forma de la máquina garantiza, y por qué están ahí:**

1. **Una sola llamada facturada por intento (regla fija 13).** T1 es un `UPDATE` que devuelve filas afectadas: solo el `perform` que obtiene 1 llama al proveedor. Un `perform` concurrente obtiene 0 y **retorna sin tocar el proveedor** — no espera, no reencola, no factura.
2. **Un resultado tardío nunca gana (regla fija 13).** El claim escribe un `transcription_claim_id` (UUID) nuevo; T2 y T3 filtran por él, así que cualquier resultado cuyo claim ya no esté vigente (porque el dictado se confirmó, o porque un reclaim por obsolescencia lo sustituyó) actualiza 0 filas, se loguea y se descarta. Y `transcript_edited` **no lo escribe el job en ninguna transición**: sus únicos escritores son el autosave humano (Fase 5) y el congelado de T4.
3. **Por qué existe el reclaim por obsolescencia (T1, segunda rama).** Un worker muerto en duro (deploy, SIGKILL) en medio de la llamada al proveedor dejaría el dictado en `transcribing` para siempre, y "cerrar y reabrir sin perder audio" es la regla fija 11. Cuesta una segunda llamada facturada después de `STT_STALE_CLAIM_MINUTES` (30 por defecto): es deliberado y nunca es concurrente con la primera.
4. **La confirmación es idempotente por dos caminos independientes (regla fija 13).** El `UPDATE` de T4 toma el lock de la fila, así que un segundo confirm concurrente **se bloquea**, luego ve 0 filas y lee el hallazgo que el ganador ya comiteó — misma respuesta, un solo hallazgo. Y `inspection_findings.voice_dictation_id` lleva **índice único**, así que ni un camino que se saltara el CAS podría crear un segundo hallazgo.
5. **La deduplicación es por informe, no global (gap 5).** Único `[account_id, certification_report_id, sha256]` con `NULLS NOT DISTINCT` (PostgreSQL 16 en dev y prod): doble tap sobre el mismo informe devuelve la misma fila; el mismo audio en otro informe es una fila nueva legítima; y un dictado sin informe todavía deduplica, en vez de que el NULL haga única cada fila.
6. **La purga tiene dos capas independientes, como la Fase 0.** La consulta del lote excluye los estados no terminales, y el `UPDATE` de T6 **vuelve a verificar** la terminalidad fila por fila. El job devuelve `{ purged:, kept:, aborted: }`; una corrida sana tiene `aborted == 0`, que es lo que prueba que el audio lo protegió la consulta y no la guarda de respaldo (hallazgo 1 del cierre de la Fase 0). Se valida por mutación, no por color verde.
7. **La purga borra los bytes del audio, no la fila.** Es una desviación de la letra de "fila antes que S3": destruir la fila rompería la FK de trazabilidad `inspection_findings.voice_dictation_id` y borraría la telemetría de costo que la Fase 6 necesita. El *orden seguro* sí se preserva: la escritura reversible en la base (limpiar el puntero) va antes del borrado irreversible en S3, así que un fallo deja los bytes en el bucket, nunca huérfanos sin registro.
8. **Telemetría propia, `bedrock_queries` intacto (regla fija 7).** `voice_dictations` es la tabla propia de la fase (`provider`, `duration_seconds`, `cost_estimate_usd`) más una línea de log estructurado `[STT_USAGE]`. El costo es duración × tarifa de una constante versionada, no un token count.
9. **El broadcast va por `user:<user_id>:voice_dictations`** — canal privado del usuario, no el patrón `KbSyncChannel`, que transmite a toda la cuenta (regla fija 12, gap 4).

### Cierre de fase (2026-09-08)

- **Estado: CERRADA.** Todos los criterios de aceptación cumplidos. Suite verde (2699 tests, 0 fallos, `PARALLEL_WORKERS=1 DB_USERNAME=lahirisan bin/rails test`), Rubocop limpio en los 24 archivos de la fase, y **transcripción real end-to-end con los dos proveedores exigidos: Amazon Transcribe y OpenAI**. La de OpenAI se completó después del merge (mismo día, sección "Prueba end-to-end real (OpenAI)" más abajo), una vez que se generó la clave y se cargó saldo en la cuenta. **Costo total de la validación de la fase: USD 0,0140.**

**Prueba end-to-end real (Amazon Transcribe, `es-US`):**

| | |
|---|---|
| Audio | 31 s, WAV 16 kHz mono, 987 KB (voz sintética, jerga de ascensores) |
| Job | `danebo-90abaca5ef3af51d-8b901e30`, `LanguageCode=es-US` confirmado en la API |
| Latencia | **11,0 s de reloj** de punta a punta (9,2 s del lado de AWS: 21:20:47.989 → 21:20:57.194) |
| **Costo real** | **USD 0,0124** (31 s × 0,024/min) |
| Costo total de toda la validación de la fase | **USD 0,0124** — el primer intento fue rechazado por IAM antes de crear el job, así que no facturó nada |

Transcripción obtenida:

> Embarque tres, la puerta de cabina **rosa** en el marco al cerrar y el operador de puertas queda desalineado, ascensor de 12 paradas, carga útil 450 kilos, velocidad 1,6 metros por segundo, se registra. Código de falla **a 32.4** en el variador, el limitador de velocidad y el paracaídas fueron probados sin observaciones. Falta señalización de sobrecarga en la cabina, punto de la norma NCH 2840.

**Lo que la ruta completa quedó validada con datos reales**, no solo con fakes: intake → S3 → claim → Transcribe → `transcribed` → confirmación (idempotente: dos llamadas, un solo hallazgo, `id` igual) → `InspectionFinding` con `body`/`location`/`position` poblados y `severity`/`nch2840_box`/`norm_point`/`inspection_item` en `nil` (regla fija 1). Rollup de costo: `{"amazon_transcribe" => {dictations: 1, seconds: 31, cost_usd: 0.0124}}`. **Cero filas nuevas en `bedrock_queries`** (regla fija 7). Y el reintento T5 se ejercitó de verdad: el dictado venía de un fallo previo y `reopen_failed!` lo devolvió a `pending`.

**Calidad sobre jerga — línea base para la Fase 6.** El resultado es mejor de lo esperado en lo que decidió la elección de `es-US` y falla exactamente donde se anticipaba:

- **Correcto, y es la validación de la decisión de idioma:** todos los números en batch — "12 paradas", "carga útil 450 kilos", "velocidad 1,6 metros por segundo" — más "NCH 2840", "limitador de velocidad", "paracaídas", "operador de puertas", "señalización de sobrecarga", "variador", "carga útil". `es-MX` no habría transcrito los números en batch.
- **Dos errores, ambos de la clase que arreglan los *custom vocabularies*:** "**rosa**" por "roza" (homófono; en un informe de certificación cambia el sentido técnico) y "**a 32.4**" por "A32.4" (el código de falla se partió y perdió la mayúscula). Más un corte de oración espurio en "se registra. Código de falla".
- **Conclusión operativa:** la palanca inmediata no es cambiar de proveedor, es cargar un *custom vocabulary* con los términos del dominio. Esa es la primera cosa que debería medir la Fase 6, antes de comparar proveedores.

**Extrapolación de costo para la hipótesis de precio:** a 0,024/min, un dictado de 15–20 min cuesta **USD 0,36–0,48**. Pero el caso base de la fase es un dictado corto por hallazgo, donde domina el mínimo facturable de 15 s (hallazgo 7): ahí el costo por informe se parece a *número de hallazgos × 0,006*, no a *minutos × tarifa*.

**Prueba end-to-end real (OpenAI, `gpt-4o-mini-transcribe`, `language=es`) — 2026-09-08, post-merge:**

| | |
|---|---|
| Audio | 32 s, WAV 16 kHz mono, 1.003 KB (misma voz sintética y misma jerga que la prueba de Transcribe, más una frase final para que el `sha256` difiera y no deduplique contra el dictado 1) |
| Dictado | id 2, informe 2, key `voice_dictations/4/a3224…/audio.wav` |
| Latencia | **5,2 s de reloj** de punta a punta (vs 11,0 s de Transcribe: es un POST síncrono, sin poll) |
| **Costo real** | **USD 0,0016** (32 s × 0,003/min; sin mínimo facturable) |
| Primer intento | `429 insufficient_quota` — la cuenta recién creada no tenía saldo. **No facturó**, y validó el camino de fallo con un error real de OpenAI: `ProviderError` → `failed` con razón guardada en 2,8 s; el segundo intento reabrió ese mismo dictado por T5 sin volver a subir el audio |
| Rollup | `cost_by_provider(account_id: 4)` → `{"amazon_transcribe" => {dictations: 1, seconds: 31, cost_usd: 0.0124}, "openai" => {dictations: 1, seconds: 32, cost_usd: 0.0016}}`; **cero filas nuevas en `bedrock_queries`** |

Transcripción obtenida:

> Embarque 3: la puerta de cabina **rosa** en el marco al cerrar y el operador de puertas queda desalineado. Ascensor de **dos separadas**, carga útil 450 kilos, velocidad 1,6 m/s, código de falla **A32.4** en el variador. El limitador de velocidad y el paracaídas fueron probados sin observaciones. Falta señalización de sobrecarga en la cabina, punto de la norma **NCH28040**. Prueba con proveedor Ropenai.

**Comparación lado a lado sobre las mismas frases (línea base para la Fase 6):**

| Frase dictada | Transcribe `es-US` | OpenAI mini | Lectura |
|---|---|---|---|
| "roza en el marco" | rosa | rosa | Homófono técnico: **falla en ambos** — solo lo arregla vocabulario de dominio (Transcribe: custom vocabulary; OpenAI: parámetro `prompt`) |
| "código de falla A32.4" | a 32.4 | **A32.4** | OpenAI acierta el alfanumérico que Transcribe partió |
| "doce paradas" | **12 paradas** | dos separadas | OpenAI falla una cifra hablada; Transcribe la normaliza bien |
| "norma NCh 2840" | **NCH 2840** | NCH28040 | OpenAI pega un dígito extra a la sigla de norma |
| "450 kilos", "1,6 metros por segundo", "embarque tres" | correcto | correcto (`1,6 m/s`, `Embarque 3`) | Ambos normalizan cifras; OpenAI abrevia unidades |

Ninguno domina: OpenAI es 2× más rápido y ~8× más barato, acierta el código de falla y falla en el número de paradas y en la sigla de norma; Transcribe al revés. Los dos fallan el homófono. **La conclusión operativa de arriba se refuerza:** la palanca es el vocabulario de dominio (que ambos proveedores soportan por caminos distintos), no el proveedor; y con un solo audio sintético limpio ninguna de estas diferencias es estadísticamente sólida — el protocolo de cinco dictados con ruido de la Fase 6 sigue siendo necesario.

**Hallazgos:**

1. **Amazon Transcribe no soporta `es-CL`** — el alcance de esta fase lo daba por soportado y la API rechaza el job. Sus variantes de español son `es-ES`, `es-US` y `es-MX`. Default elegido: **`es-US`**, por ser la única con *custom language models* (la palanca real contra la jerga) y por transcribir números en batch, que `es-MX` no hace. Razonamiento completo y tabla de soporte en el bloque de diseño de esta fase; override por `STT_AMAZON_LANGUAGE_CODE`; la decisión por medición queda en la Fase 6.
2. **`bedrock-integration-user` no tenía permisos de Transcribe — resuelto durante la fase.** El primer smoke test devolvió `AccessDeniedException: not authorized to perform: transcribe:StartTranscriptionJob`. Se agregó una política de usuario con `transcribe:StartTranscriptionJob` y `transcribe:GetTranscriptionJob`; **no** hicieron falta permisos de S3 nuevos, porque Transcribe batch lee el media y escribe el output con las credenciales del llamador, que ya tenía el bucket. **Dos ganancias colaterales:** el camino de fallo quedó validado con un error real del proveedor y no con un fake (el `AccessDeniedException` se mapeó a `ProviderError`, el dictado quedó en `failed` con la razón guardada y sin transcript, todo en 0,7 s), y el reintento T5 quedó ejercitado de verdad al reabrir ese mismo dictado para la corrida facturada. **Nota para producción:** prod **no** usa un usuario IAM sino el rol de instancia `smart-deal-ec2-role`, así que allá el comando es `put-role-policy`; quedó escrito como prerrequisito bloqueante de deploy en los insumos de la Fase 5, que es la primera fase que dispara transcripciones reales.
3. **Validación por mutación, no por color verde** (lección del cierre de la Fase 0). Se rompieron cuatro guardas a propósito y cada una fue detectada por el test correcto: (a) quitar el `return` del claim fallido → caen los 3 tests de una-sola-llamada-facturada; (b) sacar `transcription_claim_id` de la guarda de escritura → caen los 3 de resultado tardío; (c) sacar `.terminal` de la consulta de purga → cae el test de retención **con el mensaje `aborted > 0`**, es decir demostrando que el audio lo salvó la segunda capa y no la consulta, que es exactamente el falso verde que la Fase 0 advirtió; (d) volver el stream del broadcast a `account:<id>` → caen los 6 tests de aislamiento por usuario.
4. **La idempotencia de la confirmación es genuinamente de dos capas, y por eso una sola mutación no la rompe.** Quitar el atajo de "ya confirmado" deja pasar el segundo tap al CAS, que devuelve 0 filas y lee el hallazgo del ganador: misma respuesta, un solo hallazgo. Y quitar el CAS deja el índice único. Es la propiedad buscada, pero implica que **ningún test individual prueba la idempotencia por sí solo** — hay que leer los tres juntos (CAS, atajo, índice único).
5. **`say` + `afconvert` es una fuente de audio de prueba reproducible y gratis**, insumo directo de las Fases 5 y 6: `say -v Paulina -o a.aiff "<jerga>"` y `afconvert -f WAVE -d LEI16@16000 -c 1 a.aiff a.wav` da 16 kHz mono WAV, el formato que Transcribe prefiere. No sustituye a los cinco dictados con ruido de fondo real del protocolo de la Fase 6 (una voz sintética limpia no mide lo que hay que medir), pero sirve para validar cañería sin gastar en audio grabado a mano.
6. **`cost_by_provider` ganó un parámetro `account_id`.** Salió de un test que pasaba por la razón equivocada: el rollup recogía la fixture `cabina_dictado` y los totales cuadraban por casualidad. El parámetro es además el seam de tenancy que pide la sección 0 — el gasto de voz es por cuenta en cuanto haya más de un piloto.
7. **El mínimo facturable de 15 s de Amazon domina el costo del caso de uso real.** Un "la puerta roza" de 5 s cuesta lo mismo que uno de 15 s (USD 0,006). Como el caso base de la fase es un dictado corto por hallazgo, el costo por informe se parece más a *número de hallazgos × 0,006* que a *minutos totales × tarifa*. Insumo directo de la hipótesis de precio.
8. **Operativa local, para no volver a perder tiempo:** la suite necesita `PARALLEL_WORKERS=1` cuando corre en un entorno sin sockets Unix disponibles (la paralelización de Minitest usa DRb y muere con `Errno::EPERM`), y `bin/rubocop` necesita `--cache false` cuando `HOME` no es escribible. `DB_USERNAME=lahirisan` sigue siendo obligatorio, como en la Fase 0.
9. **Quedaron en dev dos dictados reales, y conviene dejarlos:** el dictado id 1 (`confirmed`, Transcribe, con su hallazgo id 1, WAV en `voice_dictations/4/6b18…/audio.wav`) y el dictado id 2 (`transcribed` **sin confirmar**, OpenAI, informe 2, WAV en `voice_dictations/4/a322…/audio.wav`). Son los únicos datos de dictado end-to-end que existen, y se complementan para la Fase 5: el 1 prueba la vista de un hallazgo con origen trazable; el 2 es exactamente el estado que necesita el panel editable y la reapertura (`in_progress`) contra algo que no sea una fixture. La purga tomará al 1 a los 90 días por sí sola; al 2 **nunca lo tocará** mientras siga sin confirmar (regla fija 10), que es el comportamiento correcto.
10. **Un `429 insufficient_quota` de OpenAI no factura y llega al dictado como `ProviderError` legible.** La primera corrida real contra OpenAI falló porque la cuenta recién creada no tenía saldo; el mensaje del proveedor quedó en `failure_reason` truncado a 250 caracteres, suficiente para leer "You have no credits remaining". Con la clave puesta pero sin saldo, el camino es idéntico al de una clave inválida (`401`): `failed` + reintento humano por T5. Para la Fase 5 significa que "reintentar" tiene sentido mostrarlo aun con error del proveedor, porque el arreglo puede ser externo (cargar saldo) y no requiere regrabar.

**Desviaciones del plan:**

- **Idioma:** `es-US` en lugar del `es-CL` que decía el alcance, por el hallazgo 1.
- **La purga borra los bytes del audio, no la fila.** Desviación de la letra de "fila antes que S3" del orden seguro de la Fase 0, argumentada en el punto 7 del bloque de diseño: destruir la fila rompería la FK de trazabilidad y borraría la telemetría de costo de la Fase 6. El *orden* seguro sí se preserva (escritura reversible en la base antes del borrado irreversible en S3).
- **`GroqAdapter` se incluyó aquí**, aunque el plan lo daba como opcional para esta fase. Costó cuatro constantes sobre `OpenAiAdapter`, que es la evidencia de que el contrato quedó bien hecho, y deja a la Fase 6 con tres proveedores desde el día uno.
- **`TranscriptionJob` no lleva `retry_on`.** Un reintento no podría producir una segunda llamada facturada (fallaría el claim), así que lo único que compraría es demora antes de que el certificador sepa que falló. Un fallo del proveedor va a `failed` y se ve; reintentar es una decisión humana explícita (T5).
- **OpenAI end-to-end se probó después del merge, no dentro del PR.** Al cerrar el PR no existía ninguna credencial de OpenAI en dev (ni en `.env` ni en `credentials.yml.enc`, cuyas claves son solo `aws`, `bedrock`, `appsignal`, `secret_key_base`), así que la prueba real quedó registrada como pendiente. El mismo día se generó la clave en el panel de OpenAI, se agregó `OPENAI_API_KEY` a `.env` (dotenv; nunca a credentials ni a git) y se corrió el smoke: resultado en la sección "Prueba end-to-end real (OpenAI)" de este cierre. **Groq sigue sin credencial** y sin prueba real: cae en la Fase 6.

**Actualizaciones aplicadas a fases siguientes:**

- **Fase 5:** bloque de insumos nuevo (contratos que consumir, estados a mostrar al reabrir, quién puede escribir `transcript_edited`).
- **Fase 6:** bloque de insumos nuevo — el benchmark gana una dimensión (las tres variantes de español de Transcribe), más la distinción entre *custom vocabularies* (cualquier variante) y *custom language models* (solo `es-US`) como palancas de jerga, la fuente de audio reproducible del hallazgo 5, y la línea base de calidad medida arriba: `es-US` acierta números y siglas de norma, y falla en homófonos técnicos y códigos de falla alfanuméricos. **Eso reordena la Fase 6:** medir primero el efecto de un *custom vocabulary* sobre esos dos errores, y solo después comparar proveedores.
- **Fase 5 y 6, post-merge (prueba real de OpenAI):** la Fase 5 recibe el dictado real id 2 (`transcribed` sin confirmar) como dato de prueba manual; la Fase 6 recibe el estado de credenciales (OpenAI operativo, Groq pendiente), la advertencia de dedup por `sha256` al reusar un audio entre proveedores, la línea base lado a lado Transcribe/OpenAI, y el parámetro `prompt` de OpenAI como palanca de jerga equivalente al custom vocabulary.

---

## Fase 5 — UI de captura de audio (dictado)

**Orden de ejecución:** 4º. **Modelo asignado:** Fable última versión (alternativa: Sonnet última versión) — es el tramo estándar más delicado: UI de captura con contratos de persistencia y recuperación.
**Depende de:** Fases 2 y 4.

**Insumos:** gate de transcripción visible/editable (regla fija 3); referencias de UX de la sección 2.3 (Salesforce Voice-to-Form: control único + resaltado + undo inline; Wispr Flow: indicador de estado mínimo; cifras de tap target); `app/javascript/AGENTS.md`. *(Actualizar con hallazgos de Fases 2 y 4.)*

*Actualizado con el cierre de la Fase 2 (2026-09-08):*

- **La lista/editor ya existen — esta fase se monta sobre ellos, no los reconstruye.** `certification_reports/show.html.erb` ya renderiza la lista de hallazgos (`_finding.html.erb`) y el formulario que crea uno con foto adjunta en el mismo submit; el control de dictado se agrega **dentro** de ese mismo formulario o como una acción adicional junto a él — no una pantalla nueva. `InspectionFinding#body`/`#location` y el flujo de creación (`InspectionFindingsController#create`) son el punto de entrada: un dictado confirmado termina poblando los mismos campos que hoy pobla el textarea, vía el mismo controlador o uno equivalente que reutilice `owned_reports`/`owned_finding`.
- **`link_to` con bloque no acepta un argumento de texto delante de la URL** (`link_to url, html_options do ... end`, nunca `link_to text, url, html_options do ... end`) — pasar texto ahí desplaza los argumentos y falla en runtime con un error de `stringify_keys` sobre un String, no en el momento de escribir el código. Motivo real por el que esta fase agregará varios `link_to`/botones con icono (grabar/parar, deshacer inline).
- **`Modelo.order(:id).last` no identifica de forma confiable "la fila que acabo de crear" en tests que además cargan fixtures.** Los fixtures usan IDs generados por hash (`ActiveRecord::FixtureSet.identify`), casi siempre mayores que los IDs de secuencia real que Postgres asigna a una fila nueva — `order(:id).last` puede devolver el fixture en vez de la fila nueva y el test pasa por la razón equivocada. Aplica directo a los tests de recuperación de la Fase 5 (dictado en curso al reabrir, confirmación → hallazgo): identificar por un atributo único (`sha256`, `body`) o por el objeto devuelto por el propio `create!`, nunca por "la última fila".
- **Bug ya corregido, pero para que no se repita:** el `ensure` de `test/services/kb_document_thumbnail_from_s3_test.rb` restauraba `ImageCompressionService.compress_with_thumbnail` con un wrapper `{ |*args| original.call(*args) }` que descartaba las keywords (`filename:`, `correlation_id:`), dejando el método roto para cualquier llamador posterior en el mismo proceso de test. Ya se corrigió (Fase 2) a `{ |*args, **kwargs| original.call(*args, **kwargs) }`. Cualquier stub nuevo de esta fase sobre un método con keywords (incluida la propia transcripción, si se stubea igual) debe forwardear `**kwargs` en su restauración — el patrón correcto ya existe en `field_photo_store_test.rb`/`field_photo_analysis_job_test.rb` (reemplazan el método completo por una fake class, no un wrapper parcial).
- **Guardado explícito, no autosubmit en controles sensibles con guantes.** La Fase 2 evaluó y descartó un `<select>` de estado con `onchange` autosubmit por el riesgo de un cambio accidental sin confirmación visual — se prefirió un botón "Guardar" separado. La Fase 5 tiene un caso más delicado (autosave de `transcript_edited` mientras el usuario edita, regla fija 11): el autosave en sí no necesita confirmación (es corrección en un paso, no una acción cara de deshacer — sección 2.3), pero cualquier control que además *cambie de estado* del dictado (confirmar, descartar) debe seguir el patrón de tap explícito, no un side-effect de un evento de input/change.
- **Adjuntar foto ya tiene un patrón de referencia reusable:** `InspectionFindingPhotoAttacher` (`app/services/`) adapta un upload directo (`ActionDispatch::Http::UploadedFile`) al contrato existente de `ImageCompressionService.compress_with_thumbnail` + `FieldPhotoStore.persist!`, sin tocar ninguno de los dos servicios. El adapter equivalente para audio (upload directo → `TranscriptionJob`/S3) puede seguir la misma forma: una clase pequeña que solo traduce el input del formulario al contrato de los servicios ya existentes, nunca reimplementa compresión/almacenamiento.
- **Tap targets ya verificados por assertion, no por revisión visual:** los tests de la Fase 2 comprueban las clases Tailwind literales (`min-h-[72px]`, `min-h-[60px]`, `gap-4`/`space-y-4`) contra el HTML renderizado. Mismo patrón recomendado para el botón único grabar/parar (72px) y los controles del indicador de estado (60px) de esta fase.

*Actualizado con el cierre de la Fase 4 (2026-09-08):*

- **PREREQUISITO BLOQUEANTE DE DEPLOY — el rol de instancia de producción necesita permisos de Transcribe.** Esta fase es la primera que dispara transcripciones desde producción, y la política solo está aplicada en la identidad de dev (hallazgo 2 del cierre de la Fase 4). Sin esto, el primer dictado real termina en `failed` con `AccessDeniedException` y el certificador ve un error que no puede resolver. **No se mergea esta fase sin verificarlo.**

  **Producción no usa un usuario IAM: usa el rol de instancia EC2 `smart-deal-ec2-role`** (verificado el 2026-09-08). Ni `config/deploy.yml` ni las credenciales encriptadas tienen `AWS_ACCESS_KEY_ID` — solo `AWS_REGION` —, así que `AwsClientInitializer` no fija credenciales explícitas y el SDK cae en la cadena por defecto, es decir el perfil de instancia. Por eso el comando es `put-role-policy` y **no** `put-user-policy`, que es lo que se usó en dev:

  ```bash
  aws iam put-role-policy \
    --role-name smart-deal-ec2-role \
    --policy-name DaneboSpeechToText \
    --policy-document '{
      "Version": "2012-10-17",
      "Statement": [
        {
          "Sid": "DaneboSpeechToText",
          "Effect": "Allow",
          "Action": [
            "transcribe:StartTranscriptionJob",
            "transcribe:GetTranscriptionJob"
          ],
          "Resource": "*"
        }
      ]
    }'
  ```

  Cuatro cosas ya verificadas, para no re-descubrirlas: **(a)** `SmartDealAppPolicy` v2 (la política gestionada del rol) **no** tiene ninguna acción de Transcribe, así que el permiso falta de verdad; **(b)** **no** hacen falta permisos de S3 nuevos — Transcribe batch lee el media y escribe el JSON de salida con las credenciales del llamador, y el statement `S3KbBuckets` ya cubre `arn:aws:s3:::multimodal-source-destination/*` completo, que incluye `voice_dictations/` y `voice_dictations/transcripts/`; **(c)** el comando corre con credenciales de administrador, no con la identidad de la aplicación, que no puede modificar IAM (verificar antes con `aws sts get-caller-identity`); **(d)** se eligió una política *inline* sobre el rol en vez de una versión nueva de `SmartDealAppPolicy` porque es un solo comando, no consume el límite de 5 versiones de la política gestionada, y se revierte con `aws iam delete-role-policy --role-name smart-deal-ec2-role --policy-name DaneboSpeechToText`.

  Si después se quiere acotar el `Resource`: los jobs de la aplicación se llaman siempre `danebo-<hash>-<hex>`, así que el ARN candidato es `arn:aws:transcribe:us-east-1:935142957735:transcription-job/danebo-*`. Acotarlo **después** de ver una transcripción real funcionar en prod, para no confundir un permiso mal escrito con otro problema.

  Verificación antes de mergear: `aws iam get-role-policy --role-name smart-deal-ec2-role --policy-name DaneboSpeechToText`.

- **Los tres contratos que esta fase consume, y ninguno más:**
  - `VoiceDictationIntake.call(account_id:, user_id:, binary:, content_type:, certification_report_id:, duration_seconds:, filename:)` → `VoiceDictation`. **Encola el `TranscriptionJob` por sí mismo**: esta fase nunca debe encolarlo, sería la segunda llamada facturada que todo el diseño existe para evitar. Devuelve `nil` solo si el upload a S3 falló o los argumentos eran inusables — trata `nil` como "no se grabó nada", nunca como éxito.
  - `VoiceDictationConfirmation.call(dictation, location: nil)` → `InspectionFinding`. Es el **único** camino de dictado a hallazgo. Ya es idempotente por CAS + índice único, así que el doble tap con guantes está resuelto en el servidor: deshabilitar el botón es cuestión de feedback visual, no de corrección. Devuelve `nil` si el dictado no está `transcribed`, no tiene informe, o el texto está vacío.
  - `VoiceDictation.reopen_failed!(id:)` → reintento humano de un dictado `failed`. **Cuesta una llamada facturada nueva**, así que va detrás de un tap explícito, nunca de un retry automático. Se rechaza si el audio ya fue purgado (`audio_available?` es falso), caso en que la UI debe ofrecer regrabar y no reintentar.
- **No existe ningún controlador ni ruta de dictado: los crea esta fase.** Para el scoping usa `VoiceDictation.owned_by(account_id:, user_id:)` — aísla por cuenta **y** por usuario, no solo por cuenta — más el patrón `owned_reports` de la Fase 2.
- **La deduplicación es por contenido y la calcula el servidor** (SHA-256 de los bytes, por informe). Eso es lo que hace barato el reintento de upload en conexión inestable: reenviar el mismo blob devuelve el mismo dictado, sin segunda subida ni segunda transcripción. La UI puede reintentar el POST sin lógica de idempotencia propia.
- **Manda la duración medida en el navegador.** OpenAI y Groq no reportan largo de audio, así que sin ese número su `cost_estimate_usd` queda en `nil` y la Fase 6 se queda sin la mitad de la tabla de COGS. Amazon sí lo reporta y sobrescribe el medido.
- **Manda también el nombre del archivo:** de él sale la extensión de la key en S3. Formatos que acepta Transcribe: `webm`, `m4a`, `mp3`, `wav`, `ogg`, `flac`. **No mandes el idioma desde el cliente** — es configuración del servidor (`STT_LANGUAGE`, y su estrechamiento por proveedor).
- **Payload del broadcast** (`VoiceDictationChannel`, stream `user:<user_id>:voice_dictations`): `voice_dictation_id`, `certification_report_id`, `status` (`"transcribed"` o `"failed"`), más `transcript` o `reason` según el caso. **El `transcript` del broadcast es un preview de 2.000 caracteres**, no la fuente de verdad: el panel editable tiene que leer el texto completo de la base. Un resultado tardío no emite broadcast, así que la UI no puede recibir un transcript obsoleto.
- **Quién puede escribir `transcript_edited`:** solo dos escritores, y ambos son de esta fase — el autosave humano y el congelado de la confirmación. El PATCH del autosave **no debe tocar `transcript_raw` ni `status`**; el `status` solo cambia por las transiciones del modelo. Eso es lo que garantiza que un resultado tardío del proveedor no pise una corrección.
- **Qué mostrar al reabrir un informe:** `report.voice_dictations.in_progress` da exactamente los no terminales (`pending`, `transcribing`, `transcribed`). Para el texto del panel usa `record.confirmed_text` (la corrección si existe, la transcripción cruda si no). `audio_available?` decide si el reintento es posible.
- **Un dictado en `transcribing` puede quedar hasta 30 minutos ahí** si murió el worker (`STT_STALE_CLAIM_MINUTES`), antes de que otro job lo reclame. El indicador de estado debería tolerar esa espera sin parecer colgado, y no reintentar solo.
- **Fixture ya disponible para los tests de esta fase:** `voice_dictations(:cabina_dictado)`, un dictado `transcribed` sin confirmar del informe `torre_amunategui` — justo el estado que necesita el panel editable. Ojo con el hallazgo 6 del cierre de la Fase 4: esa fixture contamina cualquier rollup de costo que no filtre por cuenta.
- **Y en la base de dev hay dos dictados reales para la prueba manual** (hallazgo 9 del cierre de la Fase 4): el id 1 `confirmed` (Transcribe, con hallazgo id 1) y el id 2 `transcribed` **sin confirmar** (OpenAI, informe 2, `transcript_raw` con los errores reales "rosa"/"dos separadas"/"NCH28040"). El 2 es el caso ideal para probar en móvil el panel editable, el autosave de `transcript_edited` y la confirmación explícita contra un texto que de verdad necesita corrección — no lo confirmes desde consola.
- **Fuente de audio de prueba, gratis y reproducible** (hallazgo 5 del cierre de la Fase 4): `say -v Paulina -o a.aiff "<texto>"` y `afconvert -f WAVE -d LEI16@16000 -c 1 a.aiff a.wav`. Sirve para los tests de cañería sin grabar a mano ni gastar en transcripción.

**Alcance:**

- Controlador Stimulus nuevo (no extender `rag_chat_controller`): `MediaRecorder` + `getUserMedia`, **un solo control** grabar/parar (patrón Salesforce Voice-to-Form, sección 2.3 — no un flujo de varios pasos), indicador de nivel/duración.
- **Indicador de estado como un solo elemento** (reposo → grabando → subiendo → transcribiendo → editable), no un panel — patrón Wispr Flow, sección 2.3.
- **Upload-first (regla fija 11, gap 3):** el audio se sube a S3 apenas termina la grabación, antes de cualquier otra interacción. El blob local cubre solo el intervalo grabación→upload y el reintento si el upload falla; **no es persistencia**: si no hay conexión y se recarga la página antes del upload, el blob se pierde — límite aceptado; la arquitectura offline completa sigue fuera de alcance (Plan General, sección 12, P1.7). Ensayo manual de pérdida de conexión según plan de septiembre, sección 3.4.
- **Autosave de correcciones (gap 3):** `transcript_edited` se persiste con PATCH debounced mientras el usuario edita — recargar o cerrar no pierde correcciones aún no confirmadas. Corrección **en un paso** sobre el texto ya transcrito (guideline de confirmación de voz, sección 2.3): el usuario edita directamente, nunca tiene que regrabar para corregir una palabra.
- **Reapertura:** al abrir un informe, los dictados en curso (`pending`/`transcribing`/`transcribed` sin confirmar) se muestran con su estado para retomar donde quedó.
- Flujo: grabar → subir → estado "transcribiendo…" (broadcast privado del usuario, Fase 4) → **panel de transcripción editable** → confirmar (confirmación explícita — regla fija 3, es la acción cara de deshacer; nada intermedio la necesita, sección 2.3) → el hallazgo recién creado se **resalta** en el borrador y ofrece deshacer inline (patrón Salesforce Voice-to-Form).
- Tap targets: **mínimo 60px, y 72px para el botón grabar/parar** (acción primaria, sección 2.3), 16px de espaciado mínimo entre controles.
- Un dictado por hallazgo como caso base; dictado largo multiitem queda para la Fase 7 (condicionada).

**Criterios de aceptación:** dictar → editar transcripción → confirmar → hallazgo en el borrador, en móvil real; nada entra al borrador sin pasar por el panel editable y la confirmación explícita; el hallazgo recién creado se resalta y ofrece undo; **pruebas de recuperación (gap 3):** (a) recargar tras el upload y antes del resultado → al reabrir, el dictado aparece con su estado; (b) recargar con ediciones sin confirmar → el autosave las conserva; (c) doble confirmación → un solo hallazgo; tap targets verificados contra las cifras de la sección 2.3; funciona el fallback de texto tecleado; test de sistema mínimo (o test de controlador + test JS si el repo no usa system tests aquí — verificar patrón en `test/system/`).

**Prompt de lanzamiento (Fable última versión · effort high):**

> Lee `docs/PLAN_IMPLEMENTACION_CERTIFICADOR_2026-08-09.md` completo, con foco en las reglas fijas 3, 11 y 13, la sección 2.3 (referencias de UX: Salesforce Voice-to-Form, Wispr Flow, guideline de confirmación de Google, cifras de tap target) y los cierres de las Fases 2 y 4. Crea `certificador/fase-5-captura-audio` desde `main`. Controlador Stimulus nuevo, sin tocar `rag_chat_controller` ni `ConversationSession`. No negociable: un solo control de grabar/parar, sin flujo de varios pasos; indicador de estado como un solo elemento mínimo (no un panel); upload-first (subir a S3 apenas termina la grabación); autosave debounced de `transcript_edited` (corrección en un paso, nunca regrabar para corregir texto); al reabrir un informe se ven los dictados en curso con su estado; nada entra al borrador sin pasar por el panel de transcripción editable y la confirmación explícita; el hallazgo recién creado se resalta con undo inline; tap targets mínimo 60px, 72px en el botón grabar/parar, 16px de espaciado; alto contraste (guantes, poca luz). Prueba las tres rutas de recuperación de los criterios en móvil real y ensaya una pérdida de conexión. Lee `app/javascript/AGENTS.md` y `app/views/AGENTS.md` antes de tocar esos directorios. Cierra el bloque de fase y actualiza los "Insumos" de la Fase 6 si descubriste algo del flujo de audio.

### Cierre de fase (lo llena el ejecutor)
- Estado: pendiente
- Hallazgos:
- Desviaciones del plan:
- Actualizaciones aplicadas a fases siguientes:

---

## Fase 6 — Benchmark de costo/calidad STT + COGS de voz

**Orden de ejecución:** 5º. **Modelo asignado:** Grok (variante rápida; alternativa: Sonnet última versión) para el script; la evaluación de la tasa de error sobre jerga la revisa el fundador (juicio de dominio, no se delega al modelo).
**Depende de:** Fase 4. Puede correr en paralelo con la 5. Ejecuta el mandato de medición del plan de septiembre (secciones 3.6 y 5: COGS de voz por audio y por recorrido).

**Insumos:** protocolo definido en este documento: cinco dictados simulados con ruido de fondo real + veinte frases técnicas representativas (códigos KM, marcas, códigos de falla tipo A32.4), en español chileno. *(Actualizar con hallazgos de Fase 4.)*

*Actualizado con el diseño de la Fase 4 (2026-09-08):*

- **El benchmark tiene una dimensión más que la prevista: la variante de español de Transcribe.** `es-CL` no existe en Transcribe; el default quedó en `es-US` por análisis de la tabla de soporte, no por medición. Corre el mismo set de audios por `es-US`, `es-ES` y `es-MX` (el adapter acepta la variante como argumento explícito, que gana sobre el ENV, precisamente para esto) y deja que la tasa de error sobre las 20 frases decida. `es-MX` probablemente salga última por no transcribir números en batch — confírmalo con los audios que llevan medidas y códigos.
- **Empieza por el custom vocabulary, no por comparar proveedores.** La corrida real de la Fase 4 con `es-US` acertó todos los números, "NCh 2840" y el vocabulario mecánico ("limitador de velocidad", "paracaídas", "operador de puertas", "variador", "carga útil"), y falló solo en dos cosas: un homófono técnico ("**rosa**" por "roza") y un código de falla alfanumérico partido ("**a 32.4**" por "A32.4"). Los dos son exactamente lo que arregla una lista de términos, que funciona en cualquier variante y no cuesta cambiar de proveedor. Medir eso primero puede hacer irrelevante media tabla comparativa.
- **Palanca de jerga separada de la elección de proveedor:** los *custom vocabularies* funcionan en cualquier variante. Los *custom language models* (corpus propio) solo existen en `es-US`: si el benchmark lo elige, esa puerta queda abierta; si elige otro, se cierra. Vale registrarlo explícitamente en la decisión.
- **Línea base ya medida contra la que comparar:** 31 s de audio → 11,0 s de reloj de punta a punta (9,2 s del lado de AWS), USD 0,0124. Y ojo con el mínimo facturable de 15 s de Amazon al costear dictados cortos: distorsiona cualquier extrapolación hecha solo con minutos totales.
- **Cuidado al interpretar jobs viejos en la cuenta de AWS:** hay trabajos de Transcribe anteriores (`gonzalo-demo-danebo`, `victor_entrevista`) creados a mano con `es-ES`, que no pasaron por Danebo. Los jobs de la aplicación se llaman siempre `danebo-<hash>-<hex>`.
- **Credenciales: OpenAI ya está operativo en dev; Groq no.** `OPENAI_API_KEY` está en `.env` (dotenv) con saldo cargado, y la prueba real de la Fase 4 lo ejercitó de punta a punta (USD 0,0016, 5,2 s). **Groq nunca ha sido llamado de verdad** — sin `GROQ_API_KEY` en dev; su adapter está verificado solo con fakes. Antes del benchmark: crear la clave en `console.groq.com/keys`, ponerla en `.env`, y hacer un smoke de un solo audio con `STT_PROVIDER=groq DB_USERNAME=lahirisan bin/rails "stt:smoke[tmp/stt/groq.wav,32]"`. **Pasa siempre la duración como segundo argumento** para OpenAI y Groq — sin ella dejan `cost_estimate_usd` en `nil` y la tabla de COGS queda a medias.
- **El mismo archivo no sirve para dos proveedores:** el intake deduplica por `sha256` dentro del informe, así que el segundo smoke con el mismo WAV aborta con "already transcribed; use a different audio file". Genera un audio por proveedor (basta con cambiar una palabra del texto de `say`), o usa informes distintos. El script de benchmark tiene que tenerlo en cuenta desde el diseño.
- **Línea base OpenAI ya medida, lado a lado con Transcribe, sobre el mismo texto** (tabla en el cierre de la Fase 4): OpenAI acierta `A32.4` (Transcribe no), pero falla "doce paradas" → "dos separadas" y "NCh 2840" → "NCH28040" (Transcribe acierta ambos); los dos fallan "roza" → "rosa". OpenAI: 2× más rápido, ~8× más barato, sin mínimo facturable. Es un solo audio sintético limpio: **no decide nada por sí solo**, pero fija qué frases hay que incluir en las 20 técnicas (homófonos, cifras habladas, siglas de norma con número, códigos alfanuméricos). Para OpenAI, la palanca de jerga equivalente al custom vocabulary de Transcribe es el parámetro `prompt` del endpoint de transcripción (el adapter no lo envía todavía; agregarlo es un `text_part` más en `multipart_body`).

**Alcance:**

- Script/rake reproducible: mismo set de audios → todos los adapters disponibles (Transcribe, OpenAI mini, y Groq si existe; agregar `GroqAdapter` aquí si no cayó en Fase 4) → tabla comparativa: costo real por minuto (facturado, no estimado, cuando el proveedor lo exponga), latencia de batch, y transcripciones lado a lado para conteo manual de errores sobre las 20 frases técnicas.
- Registrar resultados **en este documento** (tabla en el cierre de esta fase) y actualizar la recomendación de `STT_PROVIDER` default en la sección 4.
- Salida esperada: costo por dictado de 15–20 min por proveedor + tasa de error sobre jerga → insumo directo de la hipótesis de precio por informe (sección 6 del plan de septiembre).

**Criterios de aceptación:** tabla completa con al menos 3 proveedores; decisión de default tomada y escrita; costo total del benchmark documentado (debería ser < USD 2).

**Prompt de lanzamiento (Grok, variante rápida · effort low, sin thinking extendido):**

> Lee `docs/PLAN_IMPLEMENTACION_CERTIFICADOR_2026-08-09.md` (secciones 0, 4 y Fase 6, más el cierre de la Fase 4). Crea `certificador/fase-6-benchmark-stt` desde `main`. Escribe un script/rake reproducible que corra el mismo set de audios contra todos los adapters disponibles y produzca la tabla comparativa (costo real por minuto, latencia de batch, transcripciones lado a lado). Si `GroqAdapter` no existe, agrégalo aquí (~30 líneas, API Whisper-compatible). No tomes la decisión de proveedor default: registra la tabla en el cierre de esta fase y deja el conteo de errores sobre las 20 frases técnicas al fundador. Documenta el costo total del benchmark (< USD 2).

### Cierre de fase (lo llena el ejecutor)
- Estado: pendiente
- Hallazgos / tabla de resultados:
- Decisión de proveedor default:
- Actualizaciones aplicadas a fases siguientes:

---

## Fase 7 — Estructuración del dictado en hallazgos

**Estado: CONDICIONADA** (sección 2.2, gap 1): el circuito base funciona con un dictado = un hallazgo, sin LLM. **Condición de activación:** gate del 2 de octubre superado con uso real (plan de septiembre, sección 8), y dictados largos multi-hallazgo observados en uso que la justifiquen. **Modelo asignado:** Opus última versión (alternativa: GPT Ultra). Toca prompts con red lines de seguridad y el costo por informe.
**Depende de:** Fases 4 y 5 (y de la evidencia de la 6).

**Insumos:** `app/prompts/AGENTS.md` (prompts compactos, determinista antes que LLM); reglas fijas 1 y 4. *(Actualizar con hallazgos de Fases 4–6.)*

**Alcance:**

- Servicio que toma la transcripción **confirmada** de un dictado largo y propone: segmentación en hallazgos, ítem CENTRAVE sugerido por hallazgo, ubicación si fue dictada. **Nunca** propone gravedad ni casilla de norma ni juicio de cumplimiento — esos campos quedan vacíos para el certificador (regla fija 1).
- Determinista primero: si el certificador dictó marcadores explícitos ("ítem cabina:", "siguiente hallazgo"), se segmenta en Rails sin LLM. El LLM entra solo para dictado sin marcadores.
- LLM configurable como la capa STT: default Bedrock Haiku (`BEDROCK_MODEL_ID` existente); contrato de cliente inyectable que permita evaluar un proveedor económico (p. ej. Kimi K2.5, $0.60/M input — sección 4) sin tocar el servicio. Telemetría: esta llamada **sí** es una invocación de modelo de texto — decidir en ejecución si entra por `bedrock_queries` (si va por Bedrock) o por log estructurado (si es proveedor externo), siguiendo la regla de `AGENTS.md` raíz.
- Todo lo propuesto llega al borrador como **sugerencia editable**, nunca auto-confirmado.
- Al activarse, relajar el índice único `inspection_findings.voice_dictation_id` (Fase 4) para permitir varios hallazgos por dictado **sin perder la idempotencia de la confirmación** (p. ej. clave única `[voice_dictation_id, segment_index]`): reconfirmar el mismo dictado no duplica hallazgos.

**Criterios de aceptación:** dictado con marcadores se estructura sin ninguna llamada LLM (test determinista); dictado libre produce sugerencias con ítem CENTRAVE y sin gravedad/casilla; reconfirmación de un dictado ya estructurado no duplica hallazgos; costo por estructuración registrado; tests con cliente fake.

**Prompt de lanzamiento (Opus última versión · effort high) — solo con la condición de activación registrada:**

> Lee `docs/PLAN_IMPLEMENTACION_CERTIFICADOR_2026-08-09.md` completo (reglas fijas 1, 4, 7 y 13; sección 2.2; cierres de Fases 4–6) y `app/prompts/AGENTS.md`; verifica que la condición de activación esté registrada — si no lo está, detente. Crea `certificador/fase-7-estructuracion` desde `main`. No negociable: determinista primero (marcadores dictados se segmentan en Rails sin LLM, con test); el LLM jamás propone gravedad, casilla de norma ni juicio de cumplimiento; toda sugerencia es editable y nunca auto-confirmada; reconfirmar no duplica hallazgos; telemetría de costo por estructuración (por `bedrock_queries` si va por Bedrock, log estructurado si es proveedor externo, según `AGENTS.md` raíz). Cliente LLM inyectable como la capa STT. Cierra el bloque de fase con el costo medido.

### Cierre de fase (lo llena el ejecutor)
- Estado: condicionada — no ejecutar sin la condición de activación
- Hallazgos:
- Desviaciones del plan:
- Actualizaciones aplicadas a fases siguientes:

---

## 6. Lo que este plan NO construye

- Evaluación de cumplimiento, clasificación automática de gravedad, resultado aprobado/rechazado automático — red line permanente.
- El Certificado de Conformidad (formulario MINVU, lo emite el certificador en el portal).
- Catálogo completo de ~370 casillas NCh 2840 como datos precargados (se revisita tras validación con certificador real).
- Streaming de voz en tiempo real y conversación hands-free del mantenedor (se apoya en la capa de la Fase 4 cuando toque; fuera de alcance según plan de septiembre, sección 2.2).
- Arquitectura offline completa (plan de septiembre, sección 3.4; Plan General, sección 12, P1.7) — la Fase 5 entrega solo recuperación simple: upload-first + autosave.
- Historial genérico de conversaciones y registro diagnóstico por equipo (backlog).

## 7. Relación con los cortes de septiembre

Este plan ejecuta directamente el calendario del plan de septiembre (sección 3): Fases 0 (núcleo) y 2 en la semana del 7 al 11 de septiembre — borrador persistente demostrable con texto manual; Fases 4 y 5 entre el 14 y el 16 — circuito de audio extremo a extremo para el corte del 16-sep; Fase 6 en la semana del 17 al 21 — instrumentación de costo y correcciones. Si el corte del 16-sep no encuentra el borrador y el circuito confirmable en pie, se congela todo lo condicionado y el resto del ciclo se dedica al circuito reutilizable (plan de septiembre, sección 8). Las Fases 1, 3 y 7 y el tramo extendido de la Fase 0 se activan solo tras el gate del 2 de octubre con uso real, registrando la activación en el cierre de la fase correspondiente. Lo que **nunca** se recorta no cambia: borrador persistente y transcripción visible/editable.
