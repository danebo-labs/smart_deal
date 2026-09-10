# Danebo — Plan de Implementación: Módulo Certificador (2026-08-09)

**Documento padre:** [PLAN_GENERAL_2026-09-03.md](PLAN_GENERAL_2026-09-03.md) (sección 4) · [PLAN_SEPTIEMBRE_2026.md](PLAN_SEPTIEMBRE_2026.md) (sección 3).
**Naturaleza:** documento vivo de ejecución. Las fases se ejecutan en sesiones de agente independientes ("ejecutores"), potencialmente con modelos distintos. Ver protocolo en sección 1.
**Realineación 2026-09-08:** la premisa original ("adelantar la construcción a agosto: primero lo determinista, después la voz") caducó — agosto cerró sin ejecutar fases y el [plan de septiembre](PLAN_SEPTIEMBRE_2026.md) vigente (secciones 2.1, 2.2 y 8) manda el orden contrario: primero dictar → corregir → confirmar → guardar → recuperar; exportable, estructura de 8 ítems, normativa y PDF quedan condicionados a uso real. Este documento se reordenó en consecuencia y cerró cinco gaps críticos de una auditoría externa (sección 2.2). Los cortes del 16 de septiembre y del 2 de octubre (plan de septiembre, sección 8) gobiernan qué se ejecuta y qué se congela.

**Decisión del fundador, 2026-09-09 — generación de informe ACTIVADA:** tras probar el circuito en producción y reportar que funciona salvo detalles de UI, el fundador pidió avanzar con revisión y PDF, con encabezado/pie comunes por cuenta y una experiencia mínima. Esta instrucción adelanta **solo las Fases 1 y 3 y los datos necesarios para ellas**, ahora divididas en **1A → 1B → 3A → 3B**. Es una excepción explícita al calendario anterior; no acredita el gate comercial ni activa la Fase 7, el catálogo normativo completo o la derivación automática de normativa. Los planes padre no se editan en esta actualización: sus condiciones de validación comercial siguen vigentes; para ejecutar este alcance adelantado rige esta decisión registrada. **No se autorizó quitar BORRADOR ni emitir/fimar una certificación.** Próximo prompt: **Fase 1A**. Ninguna de estas cuatro subfases está implementada por la sola actualización del plan.

**Decisión del fundador, 2026-09-09 (noche) — tramo de funcionalidades CERRADO; piloto con lo construido:** tras revisar en local la plantilla de impresión y la visualización del informe (Fase 1B), el fundador declara el look de revisión/impresión suficiente y **cierra la incorporación de funcionalidades** de este plan. El circuito a pilotar es el ya implementado: dictar → corregir → confirmar → editar datos/equipos/hallazgos → Revisar informe HTML → imprimir desde el navegador (marcado BORRADOR). **No se autoriza una fase de features nueva.** **3A y 3B quedan diferidas:** el PDF asíncrono, el archivo conservado y la vista previa/descarga del mismo archivo no son requisito del piloto; la impresión del navegador es la salida provisional. La Fase 7, el catálogo normativo y quitar BORRADOR siguen fuera. El siguiente trabajo no es construir: es recorrer el flow, anotar fricción real y aplicar **solo mejoras de UX** sobre superficies existentes. Un ejecutor no reabre 3A/3B/7 ni inventa un alcance de PDF por leer el contrato compartido de más abajo — esa autorización del 9-sep (mañana) queda sustituida por esta. 1A ya está en `main` (PR #28). Merge/deploy de 1B siguen pendientes de commit/PR; no se dan por hechos.

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
14. **Un solo diseño de informe para el SaaS.** Encabezado y pie comunes a todos los informes de una cuenta: nombre de certificadora, rol MINVU y logo opcional, configurados una vez. Sin variantes por informe, editor de plantillas, temas ni imágenes de encabezado/pie completo. Número, fecha y paginación son datos variables, no personalización del diseño.
15. **Lo visto es lo descargado.** La vista previa PDF y su descarga usan el mismo archivo conservado. Cambiar texto, equipo, foto, encabezado o plantilla invalida su vigencia para el borrador actual, pero no modifica una versión ya generada. Descargar no evalúa cumplimiento, no firma y no cambia automáticamente el estado a `enviado`.
16. **Generación determinista y asíncrona.** Sin LLM/RAG adicional para redactar, completar o diagramar el informe. HTML y PDF comparten plantilla de contenido; Chromium y las lecturas/escrituras de archivos del PDF se ejecutan en un job, nunca en el request de generación.

---

## 1. Protocolo de documento vivo

- **Antes de ejecutar una fase**, el ejecutor lee: este documento completo, los bloques *Cierre de fase* de todas las fases anteriores, y el bloque *Insumos* de su propia fase.
- **Al cerrar una fase**, el ejecutor: (a) llena su bloque *Cierre de fase* con hallazgos y desviaciones; (b) **edita los bloques *Insumos* de las fases siguientes afectadas** — no basta con anotar el hallazgo en la fase propia; (c) actualiza la tabla de estado de la sección 2.
- **Cierre transferible obligatorio para 1A/1B/3A/3B:** registrar fecha, modelo/effort realmente usados, branch/commit/PR, archivos y contratos creados, migraciones y configuración, comandos ejecutados con resultados, revisión visual y límites, hallazgos, decisiones/desviaciones y el siguiente paso exacto. Distinguir `pendiente`, `en curso`, `cerrada en local`, `integrada` y `verificada en producción`; nunca confundir pruebas locales con deploy. Si falta una verificación, nombrarla y dejar el estado parcial.
- **Autonomía:** las decisiones de alcance ya están tomadas. Resolver detalles rutinarios con patrones del repositorio y documentarlos. **No reabrir 3A/3B, no quitar BORRADOR, no inventar features.** Un bloqueo externo no autoriza “completar el PDF” por inercia. No inventar datos de certificadora, credenciales, resultados técnicos ni verificaciones realizadas.
- **Prompt de lanzamiento:** cada fase tiene su bloque *Prompt de lanzamiento* con el modelo asignado (tabla de la sección 2). Todos extienden esta base común, que no se repite en cada bloque pero es parte del prompt:

> Lee `docs/PLAN_IMPLEMENTACION_CERTIFICADOR_2026-08-09.md` completo. Verifica el estado del repositorio y los cierres de las dependencias. Crea el branch indicado por la fase desde una base que contenga esas dependencias (sección 2.1), sin descartar cambios ajenos. Ejecuta el alcance autorizado respetando sección 0, sección 2.2 y los `AGENTS.md` aplicables. Todo cambio de comportamiento lleva tests Minitest; prueba en local. Al terminar, completa el cierre transferible, actualiza la tabla de estado y los Insumos de todas las fases afectadas. No marques merge/deploy como hechos sin evidencia.

---

## 2. Estado de ejecución

| Orden | Fase | Entregable | Estado | Modelo asignado | Effort |
|---|---|---|---|---|---|
| 1º | 0 | Modelo de datos del borrador (alcance núcleo) | **cerrada** (2026-09-08, branch `certificador/fase-0-modelo-datos`, suite local verde) | Opus última versión | high |
| 2º | 2 | Lista "mis informes" + editor mínimo | **cerrada** (2026-09-08, branch `certificador/fase-2-mis-informes`, suite local verde) | Sonnet última versión | medium |
| 3º | 4 | Capa de transcripción agnóstica al proveedor | **cerrada** (2026-09-08, branch `certificador/fase-4-transcripcion`, suite local verde, mergeada a `main` vía PR #22; transcripción real end-to-end con **Transcribe (USD 0,0124) y OpenAI (USD 0,0016)**, total USD 0,0140) | Opus última versión | high |
| 4º | 5 | UI de captura de audio (dictado) | **cerrada en local** (2026-09-08, branch `certificador/fase-5-captura-audio`, suite local verde 2743/0/0, end-to-end real en dev con OpenAI + cable privado, USD 0,0013; **reserva:** la prueba en móvil real queda para el fundador — necesita HTTPS, receta en el cierre) | Fable última versión | high |
| 5º | 6 | Benchmark de costo/calidad STT + COGS de voz | **cerrada** (2026-09-09, benchmark en `certificador/fase-6-benchmark-stt` / PR #24; default `STT_PROVIDER=groq` + `JargonPrompt` en `certificador/fase-6-default-groq`) | Grok (variante rápida) | low/fast |
| 6º | 1A | Datos mínimos del informe y encabezado común por cuenta | **integrada** (2026-09-09, `codex/certificador-1a-datos` mergeada a `main` vía PR #28; Opus 4.5 / thinking alto; **pendiente nombrado en su cierre:** revisión visual del fundador de settings/equipos — distinta de la revisión de impresión de 1B) | GPT-6 Astra | high |
| 7º | 1B | Revisión HTML y plantilla de impresión compartida | **cerrada en local; revisión visual del fundador hecha** (2026-09-09, branch `codex/certificador-1b-revision` sobre `main` con 1A ya mergeada vía PR #28; look de revisión/impresión aprobado en local — “quedó buenísimo”; suite local verde 2890/0/0; **pendiente:** commit/PR, merge y deploy) | GPT-6 Astra | medium |
| 8º | 3A | PDF asíncrono, archivo conservado y aislamiento | **diferida** (2026-09-09 noche: no es requisito del piloto; la salida es imprimir desde el navegador. No ejecutar sin reactivación explícita.) | GPT-6 Astra | high |
| 9º | 3B | Vista previa real, descarga y verificación de extremo a extremo | **diferida** (pende de 3A; misma decisión: no construir ahora) | GPT-6 Astra | high |
| — | 7 | Estructuración del dictado en hallazgos | **condicionada** (gate 2-oct) | Opus última versión | high |

**Asignación revisada el 2026-09-09 — recomendación de ingeniería, no benchmark entre proveedores:**

- **Histórico del tramo 1A→3B.** La recomendación operativa de esa noche era `gpt-6-astra` en cuatro entregas secuenciales. **Quedó sin efecto para 3A/3B** con la decisión de la misma noche que cierra funcionalidades: no lanzar esas subfases. 1A y 1B ya se ejecutaron (modelos reales en cada cierre).
- **1A / high:** esquema, permisos para datos compartidos y relaciones equipo/hallazgo. **1B / medium:** ERB/CSS y revisión sobre contratos fijados. **3A / high** y **3B / high** describen el trabajo *si se reactivan*; no son la cola actual.
- La antigua asignación **Grok rápido / low para toda la Fase 3 deja de ser apropiada para este alcance**: ya no es solamente agregar una gem y un botón. Un ejecutor estándar como Sonnet puede implementar 1B; para 1A/3A/3B usar un modelo fuerte de ingeniería y razonamiento alto (Opus si se ejecuta fuera de Codex y está disponible). Son equivalencias de complejidad, no una afirmación de superioridad medida.
- Los nombres de las fases cerradas se conservan como historial. No reutilizar aliases ambiguos como “GPT Ultra” o “Fable última versión” para un lanzamiento nuevo sin identificar el modelo concreto disponible. La Fase 7 sigue condicionada: al activarse, registrar su modelo exacto y usar razonamiento alto.
- **Fuente y límites:** la [guía oficial de GPT-6 Astra](https://developers.openai.com/api/docs/guides/latest-model) consultada el 9-sep describe su uso para ingeniería y flujos de varios pasos. El entorno Codex de esta sesión ofrece `gpt-6-astra` con `medium`/`high`, entre otros niveles; eso no garantiza disponibilidad en otra herramienta o cuenta. La asignación por subfase es criterio propio sobre este repositorio, sin estimar precios ni tiempos no medidos. Estos son modelos **ejecutores del desarrollo**; no cambian STT ni los modelos de producción de Danebo.

### 2.1 Flujo de trabajo de ejecución (decidido 2026-08-09)

**Branches.** Un branch por fase (`certificador/fase-0-modelo-datos`, `certificador/fase-1-exportable`, …), un PR chico y revisable por fase. El cierre de fase (bloque de este documento) se edita dentro del mismo PR. **Prerrequisito antes de la Fase 0:** cumplido — verificado el 2026-09-08: el working tree de `main` está limpio y los branches de fase parten de `main` actualizado.

**Para 1A → 1B (ejecutado) y 3A → 3B (diferido):** los nombres de branch siguen siendo `codex/certificador-1a-datos`, `codex/certificador-1b-revision`, `codex/certificador-3a-pdf` y `codex/certificador-3b-preview`. 1A ya está en `main` (PR #28). 1B vive en `codex/certificador-1b-revision` hasta commit/PR. **No crear `codex/certificador-3a-pdf` ni `codex/certificador-3b-preview`** hasta que el fundador reactive esas fases por escrito en este documento. Merge/deploy de 1B siguen la autorización de la sesión, no se presumen por leer este archivo.

**Prueba y deploy.** Local primero: tests Minitest de la fase + prueba manual en dev (la Fase 4 exige además una transcripción real end-to-end en dev). Fase verde → merge a `main` → deploy a producción con Kamal, el flujo existente. No se acumulan fases sin mergear: cada fase entra a `main` al cerrarse.

**Feature flag.** Gating mínimo Rails-native, sin gem: `ENV["CERTIFIER_MODULE_ENABLED"]` que (a) oculta la entrada de navegación y (b) protege los controladores del módulo con un `before_action` que devuelve 404. Permite mergear y deployar fases incompletas mientras usuarios reales (ingenieros/técnicos de Gonzalo) usan producción. La Fase 0 puede mergear sin flag: son migraciones aditivas sin superficie visible. El flag se retira cuando el módulo se libere a un certificador real.

**Plan de rollback.** El flag es el mecanismo principal — **no** `git reset`/reescribir `main`:

- **Kill switch instantáneo:** apagar `ENV["CERTIFIER_MODULE_ENABLED"]` en producción oculta la navegación y devuelve 404 en los controladores del módulo, sin deploy de código ni operación de git. Es la respuesta a "no funciona, hay que pararlo ahora".
- **Por qué no resetear `main`:** cada fase se mergea individualmente y se deploya (este mismo apartado); entre el cierre de una fase y una eventual decisión de abandonar el módulo, `main` sigue recibiendo commits no relacionados (otras correcciones del repo). Resetear `main` a un punto anterior los borraría también y exigiría force-push — fuera de las reglas de git de este workspace.
- **Retirar el código de una fase puntual:** `git revert` del merge commit de esa fase (no `reset`) — no reescribe historia, es seguro sobre una rama ya deployada. Las migraciones de cada fase se exigen reversibles como criterio de aceptación (Fase 0 ya lo probó con `db:rollback:primary STEP=2`), así que `rails db:rollback` deshace el esquema si además se quiere botar las tablas.
- **Estado de reposo aceptable:** el módulo es aditivo (tablas y rutas nuevas; nunca toca `ConversationSession` ni rutas existentes — regla fija 6). Si el piloto no valida el módulo, dejarlo mergeado y apagado por el flag indefinidamente es un desenlace válido — no hay obligación de deshacer git.

**Rutas.** Reutilizar `resources :certification_reports` y las rutas de dictado ya existentes; nada bajo el chat ni `/rag`. 1A agrega un recurso singular de configuración de certificadora y las rutas mínimas de equipos; 1B, `GET /certification_reports/:id/export` para revisión HTML (esta es la superficie de salida del piloto). 3A, si se reactiva, agregaría `POST /certification_reports/:id/exports` y rutas autenticadas de estado/vista/descarga por ID de exportación. Un `GET` nunca genera ni cambia estados. Los nombres definitivos se registran en cada cierre.

**UI: sección propia, no el chat.** El módulo es un editor de documento (lista + borrador), no una conversación: reutiliza el layout/shell de la app (navegación, Tailwind, i18n) pero con vistas y controladores Stimulus propios. No se monta sobre `rag_chat_controller` ni sobre `ConversationSession` (regla fija 6). El chat queda intacto para el flujo mantenedor.

**Mockup de diseño (insumo opcional de la Fase 2).** Si se quiere un borrador visual antes de implementar el editor: pedir un **mockup HTML estático + Tailwind** (sin framework, casi copy-paste a ERB) a un modelo fuerte, o usar herramientas tipo v0.app **solo como referencia visual** — generan React/shadcn, que no es el stack (ERB + Stimulus + importmap); de ahí solo transfieren las clases Tailwind y el layout. Brief fijo: mobile-first, tap targets mínimo 60px (72px en acciones primarias, 16px de espaciado — cifras y referencias de la sección 2.3), alto contraste (poca luz), mínimo tipeo, sin estado SPA. El exportable de la Fase 1 no necesita mockup: su diseño es el PDF de referencia de la sección 3.1.

### 2.2 Auditoría de gaps y realineación (2026-09-08)

Cinco gaps críticos señalados por una revisión externa, verificados contra el código y los planes vigentes. Los ejecutores no repiten el análisis: aplican estas resoluciones, que ya están integradas en las reglas fijas y en las fases.

1. **Orden contradictorio con el alcance vigente — confirmado el 8-sep.** Se ejecutó primero 0 → 2 → 4 → 5 → 6 y se condicionó el resto. **Actualización 9-sep:** se adelantaron 1A y 1B (cerradas en local). **Misma noche:** 3A/3B se diferieron; no repetir su activación por leer el texto de la mañana. La Fase 7 y la automatización normativa mantienen su condición. Los gates comerciales de septiembre no se dan por cumplidos.
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

### 2.4 Alcance de piloto y cola de trabajo (2026-09-09 noche)

**Qué se tiene para pilotar** (funcionalidades ya construidas; 1B aún no mergeada):

1. Borrador persistente, lista “mis informes”, aislamiento por cuenta y por usuario.
2. Dictado → transcripción visible/editable → confirmación → un hallazgo (STT default Groq).
3. Datos de edificio, emisor por cuenta (nombre, rol MINVU, logo), equipos, clasificación manual opcional, resultado manual.
4. **Revisar informe** HTML + plantilla de impresión compartida + imprimir desde el navegador con BORRADOR, encabezado y pie.

**Qué no se construye ahora** (queda escrito, no en cola):

- 3A/3B: job PDF, snapshot, archivo conservado en S3, vista previa/descarga del mismo archivo.
- Fase 7, catálogo de ~370 casillas, derivación automática de norma, quitar BORRADOR, firmar/emitir.

**Cola actual — no es una fase de features:**

1. El fundador recorre el flow en local (y anota fricción: taps, retorno, vacíos, luz/guantes, textos, cortes de impresión).
2. Commit/PR/merge/deploy de 1B cuando lo autorice — sin eso el piloto en producción no tiene “Revisar informe”.
3. Mejoras de UX **solo** sobre pantallas y rutas ya existentes, cada una con hallazgo concreto (no “pulir en general”).
4. Reactivar 3A/3B o 7 exige una decisión nueva en este documento, no un prompt aislado.

---

## 3. Evidencia de formato (grounding, 2026-08-09)

### 3.1 El informe real

**Archivo:** [referencias/2023_informe_certificacion_ascensores_NCh2840_torre_amunategui.pdf](referencias/2023_informe_certificacion_ascensores_NCh2840_torre_amunategui.pdf) — Informe N°328/2023, Pizarro y Cía. Ltda. "INAE", Registro MINVU Rol 063, Torre Amuñátegui (Catedral 1401, Santiago), 6 equipos. Documento público de 7 páginas. **Corrección por inspección visual del 9-sep:** las casillas marcadas en página 1 son **APROBADO / CON NUEVOS DEFECTOS**; la descripción anterior “RECHAZADO” confundía el texto impreso del formulario con la opción seleccionada. El ejemplo es referencia visual; jamás copiar sus personas, empresa, rol, declaración o resultado a informes reales de otra cuenta.

**Estructura observada del ejemplo (el subconjunto del primer exportable se fija en Fase 1B):**

1. **Encabezado de identificación:** empresa certificadora + rol MINVU, N° interno de informe, fecha de informe y de inspección, normativa aplicable (checkbox: NCh 440/1/2 2000, NCh 3395, NCh 440/1/2 2014/5, otras), comuna/calle/N°, nombre del edificio, destino del inmueble (vivienda/equipamiento/…), características básicas por equipo: con/sin sala de máquinas, hidráulico/electromecánico, tipo de puertas, N° embarques, cantidad de equipos, cables de tracción, N° paradas, velocidad, carga útil, capacidad, fecha última mantención, **empresa mantenedora y técnico mantenedor**, técnico de apoyo en inspección.
2. **Tabla de defectos GRAVES** (o leves anteriores no resueltos): casilla + punto de norma + aclaración.
3. **Resultado:** APROBADO (sin defectos / con nuevos defectos) o RECHAZADO (por leves anteriores no resueltos / por graves de esta inspección), con declaración del inspector y firmas (G. Técnico / I. Técnico).
4. **Tabla de defectos LEVES:** casilla + punto + aclaración (deben resolverse para la próxima certificación).
5. **Guía de inspección completa NCh 2840:2018:** ~370 casillas numeradas, cada una con punto de norma y clasificación L/G predefinida, agrupadas en 13 secciones (1 Caja de elevadores, 2 Espacio de máquinas y poleas, 3 Puertas de piso, 4 Cabina/contrapeso/masa de equilibrado, 5 Suspensión/sobrevelocidad, 6 Guías/amortiguadores/final de recorrido, 7 Holguras, 8 Máquina, 9 Sin sala de máquinas, 10 Protección eléctrica/mandos, 11 Excepciones autorizadas, 12 —, 13 Cumplimiento del plan de mantención y Carpeta de Ascensores) más pruebas D (paracaídas, limitador, frenado) y E (rótulos). Las revisadas sin observación quedan sin color; leves en amarillo, graves en rojo.

### 3.2 Lo que dice el Decreto 37 (leychile.cl, consultado 2026-08-09)

El **Certificado de Conformidad** se confecciona "usando el protocolo y formularios que para dichos efectos disponga el MINVU" — formato prescrito, se emite en el portal MINVU, **fuera del alcance de Danebo**. El **Informe** técnico sigue la guía de inspección de la norma aplicable; cada certificadora lo diagrama a su manera dentro de esa estructura. Esto **cierra la verificación pendiente** de la sección 3.5 del plan de septiembre: no hay formato de informe prescrito → el módulo debe permitir ajustar orden y nomenclatura, y el exportable se valida con Carlos Schwartz (TAQUIÓN-CERT) recién cuando el dictado funcione.

### 3.3 Decisión de estructura (tomada 2026-08-09)

**Híbrido:** captura libre y revisión posterior con agrupación opcional en los **8 ítems CENTRAVE** (Carpeta de Ascensores, Cabina, Espacio de máquinas, Contrapeso, Caja de elevadores, Pozo, Puertas y cerraduras, Suspensión/cables/amarras). Cada hallazgo admite campos opcionales — casilla NCh 2840, punto de norma, gravedad L/G — asignados por el certificador. Se conservan los no clasificados en un grupo explícito; no se fuerza a completar ocho secciones. El primer exportable adapta identificación, tablas y resultado de la sección 3.1 y agrega evidencia fotográfica, **sin reproducir la guía completa de ~370 casillas ni afirmar cobertura completa de inspección**.

**Normativa pendiente de resolver, sin bloquear el PDF:** el ejemplo rotula la norma según “fecha de permiso de edificación”; el plan general usa “fecha de recepción municipal definitiva”. No resolver esa diferencia por intuición ni copiando el ejemplo. En 1A/1B se admite referencia normativa ingresada por el certificador, sin recomendación automática. `NormativeGroupResolver` sigue diferido hasta verificar fuente oficial, criterio de fechas y bordes, y registrar su activación. La regla fija 5 define cómo construirlo cuando corresponda; no obliga a activarlo en este tramo.

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

**DEFAULT DEFINITIVO (decidido 2026-09-09, con la evidencia de la Fase 6): `groq` / `whisper-large-v3-turbo`.** Escrito en `SpeechToText::Client::DEFAULT_PROVIDER`. La medición contradijo la expectativa de arriba: el costo no fue el criterio irrelevante que se anticipaba, porque el proveedor más barato ganó también en latencia y en el tipo de error. Groq es 34× más barato que Transcribe, 12× más rápido en p50 (0,87 s contra 10–14 s, con un p95 de 912 s en el poll de batch de Amazon), y es el único lane cuyo único error de contenido es un homófono que el certificador lee de corrido ("rosa" por "roza") en vez de una palabra destruida ("Hura" por "holgura", Amazon) o un número cambiado ("dos separadas" por "doce paradas", OpenAI). El detalle está en el cierre de la Fase 6.

- **Orden operativo:** `groq` default → `openai` si Groq se degrada → `amazon_transcribe` solo si un certificador exige que el audio no salga de AWS. Es un cambio de `STT_PROVIDER`, sin deploy.
- **Nada hace failover automático.** Una segunda llamada a otro proveedor es una segunda factura; el reintento sigue siendo decisión humana explícita (regla fija 13, `TranscriptionJob`).
- **`GROQ_API_KEY` es ahora un requisito de arranque del módulo de voz.** Sin ella, cada dictado termina en `failed` nombrando la variable que falta. Amazon nunca tuvo este requisito (misma cuenta AWS), así que es la única deuda operativa nueva que introduce el cambio de default.
- **Palanca de jerga activada junto con el default, y medida contra la API real:** `SpeechToText::JargonPrompt` envía el campo `prompt` del endpoint de OpenAI/Groq (`STT_JARGON_PROMPT` lo reemplaza; vacío lo desactiva). Corridas pareadas contra Groq, mismos clips, 2026-09-09, < USD 0,01 en total:

| Caso | sin prompt | con prompt |
|---|---|---|
| Marca, clip A | Kone Monoespace | **Kone MonoSpace** (correcto) |
| Marca, clip B | Kony Mono Espacio | Kone MonoEspacio (parcial) |
| Marca, clip B | Jingles 3300 | Shingles 3300 (sin ganancia; era "Schindler") |
| Homófono | rosa | rosa (sin ganancia) |
| Código de falla | A32. 4 | A32. 4 (sin ganancia) |
| Silencio 13 s | "Gracias." | "Gracias por ver el video." |
| Ruido sin voz 13 s | "y" | "Más información www.mono.org." |

  Tres conclusiones que corrigen lo que el hallazgo 4 daba por supuesto: **(i)** la forma importa — una lista de términos separada por comas no movió nada, solo la forma de transcripción previa; **(ii)** el `prompt` **no arregla el homófono** ni el código partido, ni siquiera con "La puerta de cabina roza en el marco" literal dentro del prompt, así que la palanca no es el sustituto del custom vocabulary que se esperaba; **(iii)** empeora el audio sin voz y puede sembrarlo — "mono.org" parece fuga de "MonoSpace".

- **Se deja activada de todos modos, y el criterio es cuál error es peligroso:** lo que el prompt empeora es basura evidente sobre audio sin voz, que el certificador borra en un gesto y que nunca se auto-confirma (regla fija 3); lo que mejora es ortografía de marca, que es *plausible y falsa* — "Jingles 3300" en el encabezado de identificación de un informe firmado se lee como algo que un técnico pudo haber dicho. El arreglo correcto de las dos últimas filas es la guarda de nivel RMS que la Fase 5 dejó pendiente: si el silencio no llega al proveedor, el costo de la palanca desaparece.
- **El prompt no lleva ningún número, por diseño:** sesga la transcripción hacia lo que nombra, así que un código de falla o una cantidad ahí podría poner en un informe un valor que nadie dictó. El número de la norma se probó y no arregló nada, lo que dejó sin razón los únicos dígitos del string.
- **El *custom vocabulary* de Amazon sigue sin correrse** y ya no está en la ruta crítica: Amazon dejó de ser el default. Nota para una eventual vuelta a Amazon por residencia de datos — es la palanca que reemplaza a este prompt, y la evidencia de arriba sugiere que un vocabulario explícito podría lograr lo que el prompt no logró (el homófono).
- **Lo que queda sin medir y puede revertir esta decisión:** el ruido de sala de máquinas real, el códec `webm/opus` de Chrome, y el scorecard completo de las 20 frases (solo 8 publicadas).

### 4.1 ¿Y el mismo modelo desde Bedrock? (grounding 2026-09-09)

Pregunta legítima: si el default es `whisper-large-v3-turbo`, y ya estamos en AWS, ¿conviene llamarlo por Bedrock en vez de por la API de Groq? **Existe, y no conviene.** Es el mismo modelo con precio de infraestructura en vez de precio de uso.

- **Disponible, pero solo por Bedrock Marketplace, no serverless.** *Whisper Large V3 Turbo* está en el Model Catalog de Bedrock ([AWS ML blog](https://aws.amazon.com/blogs/machine-learning/build-a-serverless-audio-summarization-solution-with-amazon-bedrock-and-whisper/)), y los modelos de Marketplace se **despliegan a un endpoint dedicado de SageMaker AI** que se invoca por ARN ([docs](https://docs.aws.amazon.com/bedrock/latest/userguide/bedrock-marketplace-deploy-a-model.html)). No soporta `Converse`; se llama con `InvokeModel` pasando el audio como hex en `audio_input`. No hay tarifa por minuto de audio: **se paga la instancia por hora, encendida o no**, y el despliegue toma 10–15 min.
- **La cuenta, con la instancia GPU más chica razonable (`ml.g5.xlarge`, 1× A10G):** USD 1,408/hora en us-east-1 → **~USD 1.028/mes** con el endpoint arriba 24/7. Ojo con la cifra de USD 730/mes que circula: esa es la tarifa EC2 de `g5.xlarge`; la de SageMaker Hosting es ~40% más alta.
- **Punto de equilibrio contra Groq directo** (USD 0,0007 por minuto de audio, sin costo en reposo): habría que transcribir **~1,47 millones de minutos de audio al mes** — unas 24.500 horas, es decir ~33 flujos de audio simultáneos día y noche — para que el endpoint dedicado empate. En unidades del producto: **~73.000 dictados de 20 minutos al mes**, o ~857.000 informes del caso base de 8 hallazgos cortos. No es una diferencia de margen, son cuatro órdenes de magnitud.
- **Sí cambia una cosa, y vale registrarla:** este camino satisface la restricción de residencia de datos *sin* degradar la calidad, porque es el mismo modelo que ya elegimos. Es un tercer plan de escape, mejor que Transcribe en precisión. **Pero Transcribe sigue siendo más barato que un endpoint dedicado por debajo de ~714 horas de audio al mes** (USD 1.028 ÷ USD 0,024/min), así que para un solo cliente con exigencia de residencia el orden correcto sigue siendo `amazon_transcribe`, y Bedrock Marketplace recién entra si ese cliente trae volumen industrial.
- **Conclusión operativa: no se implementa nada.** Groq directo se queda. Si algún día entra por residencia + volumen, es un cuarto adapter en el registro de la Fase 4 (`InvokeModel` con `audio_input` en hex), no un cambio de arquitectura.

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
Un dictado confirmado → un hallazgo (operativo, sin LLM)
  ▼
CertificationReport (borrador persistente, Fase 0) ──► pausar / retomar / revisar
  │ datos/encabezado por cuenta + equipo/clasificación manual opcional (Fase 1A)
  ▼
Revisión HTML / plantilla de impresión compartida (Fase 1B)
  │ Imprimir (navegador) — salida del piloto, marcada BORRADOR
  │
  ╎  [diferido] Ver PDF: POST → snapshot → job (Fase 3A)
  ╎  [diferido] PDF en S3 → vista previa → descargar el mismo archivo (Fase 3B)

Fase 7: segmentación multi-hallazgo sigue condicionada; no es dependencia del piloto.
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

**Alcance extendido revisado el 9-sep:** la **Fase 1A** ejecuta `ReportEquipment`, vínculo opcional del hallazgo, constantes de los 8 ítems e i18n, datos del emisor y fixtures/seeds de demostración sintéticos. No se reabre el núcleo ya cerrado de Fase 0. **Permanece condicionado:** `NormativeGroupResolver`, incluyendo verificación oficial de criterio/fechas y tests de bordes (sección 3.3). No derivar datos técnicos faltantes ni obligar a ingresarlos durante el dictado.

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

## Fase 1 — Datos del emisor y revisión HTML (1A y 1B cerradas en local)

**Activación:** decisión del fundador del 9-sep al inicio del documento. **Cierre de funcionalidades:** decisión de la misma noche — 1A+1B son el techo de features del piloto; 3A/3B no completan el PDF ahora. No tratar HTML y PDF como documentos independientes ni crear un editor visual nuevo. El contrato de los puntos 3–4 más abajo describe el PDF *si se reactiva 3A/3B*; el piloto usa el punto 2 (Revisar informe) más impresión del navegador.

### Contrato de producto compartido por 1A → 1B → 3A → 3B

1. **Editar:** el borrador persistente actual conserva dictados y hallazgos. Configurar el emisor no bloquea crear un informe, dictar ni confirmar texto.
2. **Revisar informe:** página HTML legible en móvil, con contenido ordenado como el informe y enlaces Editar a la sección/hallazgo correspondiente. Guardar y volver conserva el contexto. No hay formulario A4 rígido en el teléfono.
3. **Ver PDF:** guarda explícitamente los cambios pendientes del formulario o pide guardarlos antes de continuar; jamás usa cambios solo presentes en el navegador. Muestra “Preparando PDF…” mientras el job trabaja. Los dictados sin confirmar se avisan y no se incluyen ni confirman automáticamente.
4. **Descargar PDF:** sirve el archivo exacto que se previsualizó. Si el borrador cambió, mostrar “Hay cambios posteriores a esta vista previa” y “Actualizar PDF”; no sustituir el archivo bajo el visor. Se puede descargar la versión anterior, rotulada como tal.
5. **Sin paso de aprobación adicional en este alcance:** descargar conserva BORRADOR y no implica aprobación técnica, firma, envío ni retiro de marca de agua. Una futura emisión sin BORRADOR requiere decisión explícita y sincronizar la regla fija 2 con el Plan General; no bloquea estas subfases.
6. **Un encabezado/pie por cuenta:** mismo diseño SaaS, empresa + rol + logo opcional. Sin selector por informe, contacto adicional ni personalización de fuentes/colores en el primer alcance. Pie automático con número de informe y página X de Y. El logo no es obligatorio; no usar la marca Danebo como identidad de la certificadora.

### Fase 1A — Datos mínimos y configuración de certificadora

**Estado:** CERRADA EN LOCAL e integrada a `main` vía PR #28 (2026-09-09). **Modelo real:** Claude Opus 4.5, thinking alto. **Branch:** `codex/certificador-1a-datos`. **Entrega usada por:** 1B. **Pendiente del cierre 1A que sigue nombrado:** revisión visual del fundador de la UI de settings/equipos (distinta de la revisión de impresión de 1B, ya hecha).

**Insumos verificados el 9-sep (revalidar si cambió el código):**

- `README.md`, `docs/ACTIVE_ARCHITECTURE.md`, `docs/MULTI_TENANT_ARCHITECTURE.md`, `docs/ACCOUNT_BRANDING.md`. Los nombres `docs/ARCHITECTURE.md` y `docs/TENANCY.md` citados por reglas antiguas no existen al corte; usar estas referencias vigentes.
- `Account` tiene `display_name`/`branded`; `AccountBranding` resuelve logos estáticos por slug para la app. No es un perfil de certificadora ni un upload de logo. No alterar el branding del chat/login ni reutilizar automáticamente su identidad para certificar.
- `User` no tiene nombre profesional, rol admin ni sistema de permisos. No asumir `admin?` o `current_user.name`. La autenticación y host-account check ya están en `ApplicationController`/`AuthenticationConcern`.
- `CertificationReport.owned_by(account_id:, user_id:)`; `InspectionFinding` ya tiene `inspection_item`, `nch2840_box`, `norm_point`, `severity` y `position`, pero el controller admite solo `body`/`location`. No recrear esas columnas. No existe aún `ReportEquipment`.
- `FieldPhotoStore`, `FieldPhotoUrlService`, `S3DocumentsService` e `ImageCompressionService` fijan el patrón de archivos privados. `config/storage.yml` no tiene S3 de Active Storage operativo: no introducirlo para este feature.

**Alcance y decisiones mínimas:**

- Datos del emisor en columnas explícitas de `Account`: nombre de certificadora, rol MINVU, metadatos del logo opcional (clave S3, tipo, tamaño y digest). No crear motor de configuración/plantillas. Formulario único “Datos de la certificadora”, sin edición por informe, con muestra compacta del encabezado. Nombre y rol pueden faltar mientras se captura; exigir ambos al solicitar PDF como regla de completitud de producto, sin validar habilitación profesional por inferencia.
- **Permisos de configuración compartida:** agregar un responsable de configuración por cuenta mediante FK nullable a `User` de esa misma cuenta (`certifier_settings_user_id`, nombre propuesto). Solo ese usuario modifica emisor/logo; los demás usuarios de la cuenta pueden ver los datos y usarlos en sus propios informes. Asignación inicial por operación explícita de onboarding, documentada con comando Rails parametrizable; sin elegir al primer visitante ni al primer usuario arbitrariamente, sin dashboard de roles. Si no hay responsable, configuración de solo lectura e instrucción breve de contactar al responsable de la cuenta. Tests con responsable y segundo usuario. Si el código ya incorporó un permiso equivalente, reutilizarlo en lugar de duplicarlo.
- Logo: PNG/JPEG, validar bytes reales y límites (propuesta inicial: 2 MB y 4 megapíxeles), normalizar con la librería existente; no SVG, URL arbitraria ni imagen de encabezado entero. Clave propia `certifier_assets/<account_id>/<digest>/logo.<ext>`; no `FieldPhoto`, para evitar purgas/diagnóstico de una marca. Reemplazar/quitar cambia la referencia de cuenta, no sobreescribe bytes ni borra assets usados por una exportación. Documentar límites definitivos y política de limpieza; no agregar purga automática en esta fase.
- `ReportEquipment`: `account_id`, informe, identificador visible (ej. “Ascensor A”), posición; especificaciones técnicas opcionales y acotadas a las de la sección 3.1. Agregar `report_equipment_id` nullable al hallazgo, con validación de **mismo informe y cuenta**, no solo mismo tenant. Informe admite cero equipos durante captura; no asociar hallazgos automáticamente al primero. Los no asignados se muestran explícitamente. Borrar equipo referenciado requiere desasignar previamente sus hallazgos; nunca borrar hallazgos en cascada por esa acción.
- Datos opcionales del informe: nombre del inspector en texto, fecha del informe, referencia normativa ingresada por el certificador, resultado manual nullable y observación del resultado. `status` sigue siendo ciclo del borrador, nunca veredicto. No copiar email como nombre/firma. Conservar número interno existente y, si falta, usar un identificador técnico estable rotulado como referencia Danebo, sin fingir correlativo oficial.
- En revisión, permitir equipo, ítem CENTRAVE, casilla, punto normativo, leve/grave y orden manual con controles simples; revelar detalles opcionales al editar. Resultado `aprobado`/`rechazado` exclusivamente seleccionado por el certificador, inicialmente vacío y sin cálculo basado en defectos. No inventar el subtipo de resultado del ejemplo ni importar automáticamente una declaración jurada.
- La ausencia de clasificación no equivale a “sin defectos”; agrupar pendientes visiblemente. Catálogo completo, firma, numeración oficial, norma automática y segmentación LLM quedan fuera. Fixtures de dos cuentas, dos usuarios en una cuenta, informes sintéticos con/sin equipo y con/sin logo; nunca cargar datos de demostración en producción.

**Aceptación:** migraciones aditivas y reversibles; compatibilidad con borradores existentes; identidad común al abrir dos informes de una cuenta; otra cuenta no puede leer/modificar emisor ni adjuntar su logo/equipo; usuario no responsable no puede cambiar configuración; otro usuario de la misma cuenta no accede a informes ajenos; campos técnicos vacíos permanecen vacíos; resultado/gravedad nunca se completan solos; logo inválido falla sin perder el anterior; captura sigue funcionando con configuración incompleta. Ejecutar tests Minitest afectados y suite conforme a CI; registrar comandos/resultados y verificar formulario en navegador.

**Prompt de lanzamiento — GPT-6 Astra / high:**

> Implementa únicamente la Fase 1A de `docs/PLAN_IMPLEMENTACION_CERTIFICADOR_2026-08-09.md`. Lee el documento completo, especialmente decisión del 9-sep, reglas fijas, contrato compartido y cierres de Fases 0/2/4/5/6, más los AGENTS.md aplicables. La fase está autorizada por la decisión registrada: no esperes al 2 de octubre. Trabaja en `codex/certificador-1a-datos` siguiendo sección 2.1. Revalida los insumos y reutiliza el esquema existente. Implementa configuración única por cuenta (nombre/rol/logo opcional y responsable explícito), datos de equipos e inspector y campos de revisión manual sin interrumpir el dictado. Mantén aislamiento de cuenta/usuario, cero inferencias técnicas, sin normativa automática y sin motor de plantillas. Prueba éxito, permisos, datos antiguos y fallos de logo; verifica UI en navegador. No construyas aún el PDF. Completa el cierre transferible de 1A, la tabla de estado y los Insumos de 1B/3A con nombres reales, rutas, migraciones, comandos y límites. Resuelve detalles rutinarios autónomamente; no declares deploy sin haberlo realizado y verificado.

### Cierre 1A

**Estado: cerrada en local, con una verificación pendiente nombrada.** Implementada y probada en local sobre `codex/certificador-1a-datos`. **No** mergeada, **no** deployada, **no** verificada en producción. La revisión visual en navegador la debe confirmar el fundador (ver *Pendiente explícito* abajo); hasta entonces esta fase no se declara `integrada`.

**Fecha:** 2026-09-09. **Modelo/effort:** Claude Opus 4.5, thinking alto (no GPT-6 Astra: la sesión de ejecución corrió en Cursor con ese parque de modelos; se registra el modelo real, no el recomendado). **Branch:** `codex/certificador-1a-datos`, base `main` en `2b4c78d` ("Allow attaching a photo when confirming a voice dictation"), verificado como ancestro de HEAD. **Commit/PR:** sin commit ni PR al momento de escribir este cierre — el árbol de trabajo contiene los cambios; commitear y abrir PR es el siguiente paso. **Ruby 3.4.7 / Rails 8.1.3.1.**

**Migraciones (cuatro, aditivas, reversibilidad probada con `db:rollback:primary STEP=4` y vuelta a migrar):**

| Migración | Efecto |
| --- | --- |
| `20260909210000_add_certifier_profile_to_accounts.rb` | `accounts`: `certifier_name`, `certifier_minvu_role`, `certifier_logo_s3_key`, `certifier_logo_content_type`, `certifier_logo_byte_size`, `certifier_logo_sha256`, y FK `certifier_settings_user_id → users` con `on_delete: :nullify`, índice `idx_accounts_certifier_settings_user`. Todo nullable. |
| `20260909210100_create_report_equipments.rb` | `report_equipments`: `certification_report_id`, `account_id`, `label` (NOT NULL), `position` (NOT NULL default 0), y opcionales `machine_room`, `drive_type`, `door_type`, `boardings_count`, `landings_count`, `traction_cables`, `speed_mps` (decimal 6,3), `rated_load_kg`, `capacity_persons`, `last_maintenance_date`. Índice `idx_report_equipments_report_position`. |
| `20260909210200_add_report_equipment_to_inspection_findings.rb` | `inspection_findings.report_equipment_id` nullable con FK **restrictiva** (sin cascada ni nullify) e índice `idx_inspection_findings_report_equipment`. |
| `20260909210300_add_review_fields_to_certification_reports.rb` | `certification_reports`: `inspector_name`, `report_date`, `normative_reference`, `result`, `result_note`. Todo nullable. |

**Archivos y contratos creados:**

- `app/models/report_equipment.rb` — `MACHINE_ROOMS = %w[con_sala sin_sala]`, `DRIVE_TYPES = %w[hidraulico electromecanico]`, `scope :ordered`, `account_id` denormalizado con validación `account_matches_report` (patrón de `InspectionFinding`), `has_many :inspection_findings, dependent: :restrict_with_error`.
- `app/services/certifier_logo_store.rb` — `CertifierLogoStore.call(uploaded_file, account_id:) → Result(s3_key, content_type, byte_size, sha256, error)`. Claves de error para i18n: `:missing`, `:too_large`, `:too_many_pixels`, `:unsupported_format`, `:unreadable`, `:upload_failed`.
- `app/services/certifier_logo_url_service.rb` — `CertifierLogoUrlService.new(account:).call → URL prefirmada`; `#trusted_redirect_url?` delega en `FieldPhotoUrlService.trusted_redirect_url?` para no duplicar la definición de "esta URL apunta a nuestro bucket".
- `app/controllers/certifier_settings_controller.rb` (recurso singular) y `app/controllers/report_equipments_controller.rb`.
- Vistas: `app/views/certifier_settings/show.html.erb`, `app/views/report_equipments/edit.html.erb`, y las parciales `certification_reports/_equipments`, `_issuer_strip`, `_review_fields`.
- `lib/tasks/certifier.rake` — onboarding del responsable.
- Helpers nuevos en `app/helpers/certification_reports_helper.rb`: `certifier_equipment_specs(equipment)` (omite toda especificación en blanco; nunca la muestra como guion, cero ni default) y `certifier_finding_equipment_label(finding)`.
- Constantes: `InspectionFinding::CENTRAVE_ITEMS` (Hash `1..8 → símbolo`, sobre la columna `inspection_item` ya existente) y `CertificationReport::RESULTS = { aprobado:, rechazado: }` como `enum ... prefix: true`. `CertificationReport#danebo_reference` devuelve `"DAN-<id>"`, rotulado en la UI como referencia Danebo y nunca como correlativo oficial.

**Rutas reales (nombres para 1B/3A):**

```
GET/PATCH  /certifier_settings          certifier_settings_path
GET        /certifier_settings/logo     logo_certifier_settings_path   (redirect 302 a URL prefirmada)
DELETE     /certifier_settings/logo     logo_certifier_settings_path   (destroy_logo)
POST       /certification_reports/:certification_report_id/report_equipments
                                        certification_report_report_equipments_path
GET        /report_equipments/:id/edit  edit_report_equipment_path
PATCH/DELETE /report_equipments/:id     report_equipment_path
```

**Permisos de configuración compartida.** `Account#certifier_settings_manager?(user)` es la única puerta: exige `certifier_settings_user_id` presente **e** igual al usuario. Sin responsable asignado, la configuración es de solo lectura para todos — el primer visitante no se apropia de la identidad de la empresa. Un colega de la misma cuenta **lee** los datos (no es 404: ver el encabezado que va a salir en su propio informe es legítimo) pero no los edita. `Account` valida que el responsable pertenezca a la misma cuenta, y el FK `on_delete: :nullify` degrada la cuenta a solo lectura si ese usuario se elimina, en lugar de bloquear el borrado o dejar un puntero colgante. No se creó rol admin ni dashboard de roles.

**Onboarding (comandos reales, agregar `DB_USERNAME=lahirisan` en local):**

```
bin/rails "certifier:settings_owner[danebo-legacy,alguien@empresa.cl]"
bin/rails "certifier:settings_owner:show[danebo-legacy]"
bin/rails "certifier:settings_owner:clear[danebo-legacy]"
```

Aborta con mensaje si la cuenta o el usuario no existen, si faltan argumentos, o si el usuario pertenece a otra cuenta (imprime ambos `account_id`). No promueve a nadie automáticamente.

**Almacenamiento del logo y límites definitivos.** Prefijo propio `certifier_assets/<account_id>/<sha256>/logo.{png,jpg}` vía `S3DocumentsService#upload_binary`; **nunca** bajo `field_photos/` (una marca no se purga con la retención de evidencia ni entra al pipeline de diagnóstico) ni bajo `bulk_chunks/`. Límites: **2 MB** (`MAX_BYTES`) y **4 megapíxeles** (`MAX_PIXELS`), comprobados por separado porque una bomba de descompresión es pequeña en disco y enorme en memoria. **El formato lo deciden los bytes reales**, no el `content_type` declarado ni la extensión: se husmean las firmas PNG (`\x89PNG\r\n\x1A\n`) y JPEG (`\xFF\xD8\xFF`); un SVG, un PDF o texto renombrado a `.png` se rechaza antes de tocar S3. Normaliza con `ImageCompressionService`, que bajo el límite es pass-through, así que un PNG conserva su transparencia y no se re-codifica a JPEG sobre fondo blanco. Clave por digest: reemplazar escribe un objeto nuevo en vez de sobreescribir bytes que una exportación ya generada podría estar referenciando. **Política de limpieza: no hay purga automática en esta fase, por decisión explícita.** Quitar el logo limpia la referencia de la cuenta y deja el objeto en S3. Consecuencia a resolver cuando exista historial de exportaciones (3A/3B): los objetos de `certifier_assets/` se acumulan a razón de uno por logo distinto subido; el borrado seguro exige saber que ninguna exportación conservada lo referencia.

**Comandos ejecutados y resultados:**

| Comando | Resultado |
| --- | --- |
| `DB_USERNAME=lahirisan bin/rails db:migrate` | 4 migraciones aplicadas |
| `DB_USERNAME=lahirisan bin/rails db:rollback:primary STEP=4` + `db:migrate` | reversibilidad confirmada en ambos sentidos |
| `DB_USERNAME=lahirisan bin/rails test` | **2861 runs, 11329 assertions, 0 failures, 0 errors, 189 skips** |
| `TEST_WORKERS=1 DB_USERNAME=lahirisan bin/rails test` (9 archivos de 1A) | **141 runs, 424 assertions, 0 failures** |
| `bin/rubocop --cache false --no-parallel app/ test/ lib/tasks/certifier.rake db/migrate/2026090921*.rb config/routes.rb` | 475 archivos, sin ofensas |
| `bin/rails zeitwerk:check` | "All is good!" |
| `bin/rails routes` | las 6 rutas nuevas resuelven con los nombres de arriba |

**Pruebas nuevas (todas Minitest, sin system tests):** `test/models/report_equipment_test.rb`, `test/models/account_certifier_settings_test.rb`, `test/services/certifier_logo_store_test.rb`, `test/controllers/certifier_settings_controller_test.rb`, `test/controllers/report_equipments_controller_test.rb`, `test/tasks/certifier_settings_owner_test.rb`, más ampliaciones de `test/models/inspection_finding_test.rb` y de los dos controller tests existentes. Cubren: éxito; permisos (responsable, colega de la misma cuenta, cuenta sin responsable); datos antiguos (cuenta sin configurar, informe sin equipos, hallazgo sin clasificar); fallos de logo (SVG/PDF/texto disfrazados, PNG truncado, sobre 2 MB, sobre 4 MP, S3 que no confirma, archivo vacío); y aislamiento en los dos ejes para equipos y configuración.

**Fixtures.** `accounts.yml`: `legacy` queda **sin configurar y sin responsable** (es el caso de datos antiguos, y su informe/hallazgos existentes son la prueba de regresión real); `climb` queda completamente configurada con logo y `users(:two)` como responsable. `certification_reports.yml` agrega `edificio_portales` (cuenta `climb`) con los campos de revisión llenos y **`result` deliberadamente vacío**: un borrador completo sin veredicto es el estado normal. `report_equipments.yml` agrega `climb_ascensor_a` (con características) y `climb_ascensor_b` (solo etiqueta). `inspection_findings.yml` agrega uno clasificado y `portales_sin_clasificar`, que es el estado que nunca debe leerse como "sin defectos". Nada de esto se carga en producción.

**Hallazgos para quien siga:**

1. **El host es la frontera de tenant en los tests, no solo `sign_in`.** `ensure_user_belongs_to_host_account!` rechaza a un usuario autenticado contra el host de otra empresa, y el host por defecto de los tests de integración (`www.example.com`) mapea a `danebo-legacy`. Para probar la cuenta `climb` hay que `host! "ascensoresclimb.localhost"` (ver `config/account_hosts.rb`). Sin eso todo redirige a login y el fallo parece de permisos. 1B/3A: cualquier test multi-cuenta necesita esto.
2. **`es` no tenía ningún `date.formats`,** así que `l(date)` en español levantaba `Translation missing: es.date.formats.default` en cuanto una vista formateaba una fecha. Se agregó `date.formats.certifier_short` en `es.yml` y `en.yml` como formato **nombrado** (no `:default`) para no cambiar la forma de ninguna vista existente. 1B va a formatear fechas: usar `l(date, format: :certifier_short)` o agregar otro formato nombrado, nunca `l(date)` a secas.
3. **El `ArgumentError` de los enums (hallazgo 6 del cierre de Fase 2) se propaga a cada enum nuevo.** Ya se sabía que un valor fuera de rango explota en la asignación, antes de validar, así que nunca llega a `save` y el 422 normal no lo ve. Lo nuevo: `certification_reports#update` ahora tiene **dos** enums en el mismo formulario (`status` y `result`), y el rescate existente culpaba siempre a `status`; se cambió para identificar cuál fue el inválido. Y `inspection_findings#update` no tenía rescate: `severity` es enum y un valor forjado devolvía 500. Cualquier enum nuevo en 1B/3A necesita su propio rescate.
4. **`position` tiene default 0 en la base, así que el atributo nunca está en blanco.** El primer intento de "asignar orden solo si el certificador no lo eligió" miraba `equipment.position.blank?` y nunca disparaba: todos los equipos quedaban en posición 0. Hay que mirar los **params enviados**, no el atributo. Mismo cuidado con el campo de orden del hallazgo, donde un `""` enviado se borra del hash para no violar el NOT NULL.
5. **El orden de declaración de los `has_many` con `dependent:` es carga funcional.** `report_equipments` se declara **después** de `inspection_findings` en `CertificationReport` a propósito: un equipo se niega a ser destruido mientras un hallazgo lo apunte (FK restrictiva + `restrict_with_error`), así que los hallazgos tienen que destruirse primero o borrar el informe falla. Hay un test que lo fija.
6. **`restrict_with_error` agrega el error en `:base`, no en el nombre de la asociación** (Rails 8.1). Un test que espere `errors[:inspection_findings]` falla.
7. **Dos botones "Editar" en la misma pantalla es un error de toque garantizado con guantes.** Al agregar la sección de equipos al informe, sus acciones quedaron con las mismas etiquetas que las del hallazgo. Se renombraron a "Editar equipo"/"Eliminar equipo". 1B: al agregar enlaces "Editar" que vuelven a secciones, nombrar el objeto en la etiqueta.
8. **`db/schema.rb` se reformatea completo si se deja el dump crudo.** El repositorio tiene `[ "x" ]` y el dumper escribe `["x"]` (hallazgo 6 del cierre de Fase 0, confirmado otra vez): el dump produjo 98 inserciones y 58 borrados de puro formato. Se aplicaron las adiciones a mano y se verificó equivalencia con el dump real normalizando el espaciado de corchetes; el diff final es de **41 inserciones y 1 borrado** (la línea de versión). Los `db/{cable,cache,queue}_schema.rb` también se reescriben y se revirtieron.

**Decisiones y desviaciones justificadas:**

- **Sin logo, el encabezado degrada a bloque tipográfico** (nombre + "Registro MINVU Rol X"), **nunca a la marca Danebo.** El fundador pidió inicialmente usar el logo de Danebo por defecto; se le planteó el conflicto con el punto 6 del contrato compartido y eligió el bloque tipográfico. Danebo es la herramienta, no el emisor del informe.
- **`result` es una columna aparte de `status`**, nullable y vacía hasta que un humano elige. Hay un test que confirma que guardar otros campos en un informe con tres defectos registrados **no** produce veredicto.
- **El acceso a "Datos de la certificadora" quedó en la lista de informes, no en el header global.** El header móvil ya está apretado; la identidad se configura una vez. Se pinta en ámbar cuando faltan nombre o rol.
- **La completitud de nombre y rol MINVU no se validó en el modelo**, a propósito: se expone `Account#certifier_identified?` para que 1B/3A la exijan al pedir PDF. Capturar y dictar tiene que funcionar antes de que nadie configure nada (punto 1 del contrato).
- **No se implementó `NormativeGroupResolver`:** sigue condicionado. `normative_reference` es texto libre que escribe el certificador, con ayuda en pantalla que dice explícitamente que Danebo no deduce la norma.
- **No se agregó purga automática de `certifier_assets/`** (ver *Almacenamiento* arriba).
- **Se descartó un system test de las pantallas.** Se escribió uno temporal con Selenium para recorrer los 13 pasos en Chrome headless a 390 px; recorrió correctamente los primeros siete (login, configuración de solo lectura, formulario del responsable, guardar identidad sin logo, logo rechazado con su mensaje, informe sin equipos, agregar equipo) y falló en el octavo por la ambigüedad de las etiquetas "Editar" — el hallazgo 7. Corregidas las etiquetas, el archivo se borró: `test/AGENTS.md` pide evitar system tests cuando un test de integración cubre lo mismo, y las 141 pruebas rápidas lo cubren.

**Pendiente explícito, no dar por hecho:** (a) **revisión visual en navegador por el fundador** — datos sembrados en dev en la cuenta `danebo-legacy`, informe 2 con dos equipos y hallazgos sin clasificar, servidor en `http://localhost:3000` con `CERTIFIER_MODULE_ENABLED=true`; pantallas a mirar: `/certifier_settings`, `/certification_reports`, `/certification_reports/2` y sus editores; (b) commit, PR y merge a `main`; (c) deploy con Kamal y verificación en producción. Nada de esto está hecho.

**Insumos actualizados:** los de **1B** y los de **3A/3B** (dentro de la sección de la Fase 3), abajo. **Próximo paso exacto:** confirmar la revisión visual, commitear en `codex/certificador-1a-datos`, abrir PR chico, mergear y recién entonces lanzar el prompt de 1B.

### Fase 1B — Revisión HTML y plantilla compartida

**Estado:** CERRADA EN LOCAL (2026-09-09) — revisión visual del fundador hecha en local (plantilla de impresión y visualización del informe, aprobadas). Pendiente: commit/PR, merge y deploy. **Modelo real:** Claude Sonnet 5 (thinking). **Branch:** `codex/certificador-1b-revision`, sobre `main` con 1A ya integrada (PR #28). **Entrega para el piloto:** Revisar informe + imprimir. 3A/3B quedan diferidas (sección 2.4); los Insumos de esas fases se conservan por si se reactivan.

**Insumos actualizados por el cierre 1A (2026-09-09) — verificados contra el código, revalidar si cambió:**

- **Base.** 1A está en `codex/certificador-1a-datos`, **no** en `main` al momento de escribir esto. Verificar el merge antes de partir; si el fundador pide seguir sin merge, ramificar desde ese branch y documentar la base exacta (sección 2.1). Leer el cierre 1A completo: sus 8 hallazgos son trampas que 1B va a pisar.
- **Datos disponibles para el documento.** Emisor en `Account`: `certifier_name`, `certifier_minvu_role`, `certifier_logo_s3_key` + `certifier_logo_content_type`/`byte_size`/`sha256`; predicados `Account#certifier_identified?` y `#certifier_logo?`. Informe: los campos de edificio de Fase 2 más `inspector_name`, `report_date`, `normative_reference`, `result` (enum `RESULTS`, nullable) y `result_note`. Equipos: `report_equipments` con `label` y las 10 especificaciones opcionales, ordenables con `ReportEquipment.ordered`. Hallazgos: `report_equipment_id` nullable más `inspection_item`/`nch2840_box`/`norm_point`/`severity`/`position`, con `InspectionFinding::CENTRAVE_ITEMS` (1..8) y `#centrave_item_key`. Identificador de respaldo: `CertificationReport#danebo_reference` → `"DAN-<id>"`, que **debe** rotularse como referencia Danebo y jamás como correlativo oficial.
- **Reutilizar, no reescribir.** `certifier_equipment_specs(equipment)` ya arma la línea de especificaciones omitiendo las vacías, y `certifier_finding_equipment_label(finding)` ya devuelve la etiqueta o el marcador de no asignado — ambos en `app/helpers/certification_reports_helper.rb`. La parcial `certification_reports/_issuer_strip` es la franja **del editor web** y depende de `current_account`: **no** la reutilices como encabezado del documento; el punto de la plantilla de 1B es recibir un conjunto explícito de datos, sin `current_user` ni `request`. `InspectionFinding.unassigned_equipment` trae los pendientes de asignar.
- **Encabezado sin logo.** Degrada a bloque tipográfico con nombre y `t("certifier.settings.minvu_role_line", role:)`. **Nunca** la marca Danebo (decisión del fundador registrada en el cierre 1A). Con logo, servirlo por `logo_certifier_settings_path`, que redirige 302 a una URL prefirmada; para el job de 3A eso no sirve — ver Insumos de 3A.
- **Precarga obligatoria.** El informe ya carga `inspection_findings.includes(:field_photo, :report_equipment)`; mantenerlo y agregar `report_equipments` al armar el documento. La aceptación de 1B exige que no haya consultas por fila.
- **Fechas.** `l(date)` en español **rompe** salvo con formato nombrado: existe `date.formats.certifier_short` en `es.yml`/`en.yml` (hallazgo 2 del cierre 1A). Para el documento impreso probablemente quieras un formato más formal: agregarlo como formato **nombrado** nuevo en los dos locales, nunca cambiando `:default`.
- **i18n.** Todo lo del módulo está en `config/locales/certifier.{es,en}.yml`, ya con `certifier.centrave.*` (los 8 ítems), `certifier.severities.*`, `certifier.results.*` (incluido `unrecorded`: "Resultado no registrado"), `certifier.equipment.*` (incluidos `machine_rooms.*`, `drive_types.*`, `specs.*`, `unassigned`) y `certifier.settings.*`. Reutilizar esas claves; los archivos van pareados.
- **Datos de prueba.** Usar los fixtures de 1A: `certification_reports(:edificio_portales)` es el informe con equipos, campos de revisión llenos y `result` vacío; `certification_reports(:torre_amunategui)` es el informe antiguo sin equipos ni clasificación. Ojo con el host: para tocar la cuenta `climb` hace falta `host! "ascensoresclimb.localhost"` (hallazgo 1 del cierre 1A).
- **Sin cambios.** `CERTIFIER_MODULE_ENABLED` y `CertifierModuleGuard` ya existen: no introducir otro gating. `config/storage.yml` sigue sin S3 de Active Storage y no se debe introducir. Referencia visual: PDF de la sección 3.1, con la corrección del 9-sep sobre las casillas de resultado.
- **Otros AGENTS.md aplicables:** `app/views/AGENTS.md`, `app/javascript/AGENTS.md`, `test/AGENTS.md`.

**Alcance:**

- `GET /certification_reports/:id/export` muestra “Revisar informe”, autenticado y aislado por propietario. Enlaces “Editar” vuelven al formulario/sección correspondientes, conservando retorno local seguro (ruta/anchor permitidos, no URL libre). HTML de lectura responsive, sin controles dentro del documento impreso.
- Una plantilla ERB/partials de contenido recibe un conjunto explícito de datos, sin depender de `current_user`/`request` para el documento; el wrapper web añade navegación y controles. Prepararla para que el job de 3A renderice exactamente esa plantilla desde el snapshot. CSS de impresión y fuentes locales; A4 como referencia, sin CDN.
- Orden: **encabezado del emisor e identificación → equipos/datos técnicos presentes → defectos graves registrados → resultado ingresado por el certificador → defectos leves registrados → hallazgos pendientes de clasificación → evidencia fotográfica por hallazgo**. Referencias de hallazgo estables dentro de la versión conectan tablas y fotos; ubicación/equipo siempre visibles cuando fueron ingresados. Agrupación CENTRAVE opcional, sin ocho secciones vacías forzadas. Tablas usan casilla/punto/aclaración cuando existen; conservar texto íntegro.
- Resultado vacío: “Resultado no registrado”. Tabla sin registros: “Sin hallazgos registrados en esta categoría”, **nunca** “sin defectos” o “cumple”. Avisar datos pendientes en revisión, sin inventarlos y sin ocultar hallazgos no clasificados. No mostrar checklist como inspeccionado por omisión.
- Encabezado y pie automáticos y BORRADOR en cada página impresa. Fotos proporcionadas sin deformación y con identificación; no reducirlas siempre a miniaturas ilegibles. `break-inside`/repetición de cabeceras con tratamiento de texto o imagen que excede una página: permitir continuidad sin cortar ni perder contenido. La copia de BORRADOR no debe tapar evidencia.
- Puede ofrecer impresión del navegador como salida provisional marcada BORRADOR, pero **no afirmar que el HTML responsive reproduce exactamente la paginación final**; esa garantía corresponde al visor del PDF real de 3B. No añadir botón de PDF inoperante antes de 3A/3B.

**Aceptación:** lectura/edición/retorno en móvil y escritorio; mismo emisor en dos informes de cuenta; datos vacíos y no clasificados visibles; texto largo, acentos y fotos vertical/horizontal preservados; referencias coherentes entre tabla/foto; sin consultas por fila evitables; tests de autenticación, flag y aislamiento en ambos ejes; HTML escapado contra inyección. Revisión visual de todas las páginas de una impresión multipágina de prueba, incluyendo marca BORRADOR, encabezado, pie y cortes. Documentar cualquier diferencia de impresión del navegador que deba resolver 3A.

**Prompt de lanzamiento — GPT-6 Astra / medium:**

> Implementa únicamente la Fase 1B de `docs/PLAN_IMPLEMENTACION_CERTIFICADOR_2026-08-09.md`. Lee el documento y el cierre de 1A; verifica que su implementación está en tu base y usa sus nombres/rutas reales. Trabaja en `codex/certificador-1b-revision` según sección 2.1. Construye Revisar informe en HTML responsive con edición y retorno directo, y una sola plantilla ERB de contenido reutilizable por el futuro job PDF. Usa el encabezado/pie común de cuenta y el orden exacto definido en 1B; inspecciona visualmente el PDF de referencia, pero usa datos sintéticos propios. Conserva BORRADOR, no clasificados y resultado manual; no copies declaraciones ni construyas la guía normativa completa. Verifica permisos, XSS, fotos/textos largos y todas las páginas de una impresión de prueba. No prometas paginación idéntica al HTML ni implementes otra plantilla para PDF. Actualiza cierre 1B, estado e Insumos de 3A/3B con contrato de datos, CSS/assets, hallazgos y comandos de verificación.

**Cierre 1B:**

- **Estado:** cerrada en local. Suite completa verde (2890 corridas, 0 fallas, 0 errores, 189 skips), `bin/rubocop` limpio (614 archivos) y `bin/rails zeitwerk:check` limpio. Revisión visual del fundador hecha en local (2026-09-09 noche): plantilla de impresión y visualización del informe aprobadas. Pendiente: commit/PR, merge a `main` y deploy.
- **Fecha / modelo / effort / branch / commit / PR:** 2026-09-09 · Claude Sonnet 5 (thinking), no el modelo recomendado · alto · `codex/certificador-1b-revision` (parte de `main` en `7863aeb`, con 1A ya integrada vía PR #28) · sin commit todavía (working tree) · PR pendiente de abrir.
- **Plantilla / contrato de datos / rutas / assets / retorno de edición:**
  - Ruta: `GET /certification_reports/:id/export` (miembro de `resources :certification_reports`) → `CertificationReportsController#export`.
  - Contrato de datos explícito (sin `current_user`/`request` dentro de la plantilla): hash `@export_document` con `report:` (el `CertificationReport`), `issuer: { name:, minvu_role:, identified:, logo_url: }`, `report_edit_url:`, `equipment_rows: [{ equipment:, edit_url: }]` y `finding_rows: [{ finding:, reference:, photo_url:, edit_url: }]`. Todas las URLs de edición y de foto se resuelven en el controlador (`export_issuer_data`, `export_equipment_rows`, `export_finding_rows`, `export_trusted_photo_url`) antes de pasarlas como locals — la plantilla nunca llama a un helper de rutas de sesión ni a `current_account`.
  - Plantilla de contenido única: `app/views/certification_reports/exports/_document.html.erb` (+ `_findings_table.html.erb` para graves/leves/no clasificados). Recibe solo los locals anteriores; es la misma parcial que 3A debe renderizar desde el snapshot con `ApplicationController.render(partial:, locals:)` fuera de un request autenticado (ya lo hice así en la verificación manual, ver abajo).
  - Wrapper web: `app/views/certification_reports/export.html.erb` — enlace "Volver al informe", botón "Imprimir" (Stimulus `print_controller.js` → `window.print()`, sin `onclick` inline), disclaimer BORRADOR/impresión provisional, renderiza `_document`.
  - CSS: `app/assets/stylesheets/certifier_export_print.css`, cargado directo con `stylesheet_link_tag "certifier_export_print"` (no vía el manifest `:app` de Propshaft). Hoja plana, sin Tailwind ni CDN — el mismo archivo en disco que 3A debe apuntar Chromium a leer.
  - Retorno de edición: `app/controllers/concerns/certifier_export_redirect.rb`, incluido en `CertificationReportsController`, `InspectionFindingsController` y `ReportEquipmentsController`. Si `params[:return_to] == "export"`, el `update` de cada uno redirige a `export_certification_report_path(report, anchor: dom_id(recurso))` en vez de a su ruta normal. Los enlaces "Editar" de la revisión agregan `return_to=export`; los tres formularios de edición propagan el parámetro (y el anchor del recurso) en su `form_with` y en "Cancelar"/"Volver".
  - i18n: `certifier.export.*` nuevo en `certifier.es.yml`/`certifier.en.yml` (título, secciones, tabla, estados vacíos, encabezado/pie, disclaimer); `date.formats.certifier_long` agregado como formato **nombrado** en ambos locales (no se tocó `:default`) para la fecha larga del documento.
- **Pruebas y páginas inspeccionadas / límites:**
  - `test/controllers/certification_reports_export_test.rb`: flag `CERTIFIER_MODULE_ENABLED` + autenticación, aislamiento por cuenta y por usuario (404 en ambos ejes), orden exacto de las 7 secciones, contenido con datos antiguos sin clasificar (`torre_amunategui`) y completos (`edificio_portales`), resultado vacío → "Resultado no registrado", tabla vacía → "Sin hallazgos registrados en esta categoría" (nunca "sin defectos"/"cumple"), XSS (nombre de edificio y cuerpo de hallazgo con `<script>`), texto largo sin truncar, sin consultas por fila (`assert_queries_count`/límite fijo), enlaces `return_to=export` desde equipos/hallazgos/datos del informe.
  - Comandos: `bin/rails test test/controllers/certification_reports_export_test.rb`; `bin/rails test` (suite completa); `bin/rubocop`; `bin/rails zeitwerk:check`.
  - Revisión visual manual (no test de sistema, ver hallazgo): sembré un `Account`/`User`/`CertificationReport` sintéticos con 3 equipos y 15 hallazgos (severidades graves/leves/no clasificadas intercaladas, uno con foto) mediante un script desechable ejecutado con `bin/rails runner`, renderizando `_document` fuera de un request con `ApplicationController.render`, CSS inyectado inline (sin depender del asset pipeline) e impreso a PDF con Chrome headless (`--headless=new --print-to-pdf`), produciendo un PDF A4 real de **7 páginas**. Conté las páginas con la gema `pdf-reader` y las inspeccioné una por una convirtiéndolas a PNG con `pdftoppm` (poppler). El script destruye el dato sintético al final (`report.destroy!`/`user.destroy!`/`account.destroy!`) y los artefactos quedaron en `tmp/` (borrados, no en el repo) — **ojo:** una corrida fallida a mitad de camino (antes de corregir el valor inválido de `inspection_item`, ver hallazgos) sí dejó una cuenta/usuario/informe huérfanos en la base de dev porque el script no tenía un `ensure`; se detectó y se limpió a mano después de cerrar esta fase. Si se reejecuta el script, envolver la siembra en `begin/ensure` o una transacción con rollback para no depender de que el script llegue completo al final.
  - Límite conocido y aceptado: la paginación del navegador sigue siendo una aproximación (el propio CSS ya lo documentaba); no se intentó ni se prometió que coincida con la paginación final de 3B.
- **Hallazgos / desviaciones justificadas:**
  - **Bug real de Chromium encontrado y corregido durante la revisión visual.** El CSS de impresión original repetía encabezado/pie con `position: fixed` y un offset **negativo** (`top: -14mm` / `bottom: -12mm`) para empujarlos hacia el margen de página. Al imprimir el PDF sintético de 7 páginas, Chromium invirtió el eje: el encabezado aparecía al **pie** de cada página y el pie al **encabezado** de la siguiente, superponiéndose con la fila repetida de la tabla (`thead` con `display: table-header-group`) y volviéndola ilegible; además el encabezado faltaba por completo en la página 1 y el pie en la última página. Es la misma familia de bugs de Chromium documentados públicamente para `position: fixed` + offset negativo en paginación de impresión (issues de Puppeteer/Chromium abiertos desde 2018 sobre encabezados/pies que desaparecen en la primera/última página). **Corrección aplicada:** los elementos fijos ahora usan `top: 0` / `bottom: 0` (sin excursión negativa hacia el margen) y el espacio se reserva con `padding-top`/`padding-bottom` en `.certifier-doc__body`; reimprimí el mismo documento sintético y confirmé encabezado + pie correctos en las 7 páginas, incluida la primera y la última, sin superposición con el contenido.
  - **Implicación directa para 3A (ya incorporada en Insumos abajo):** no reutilizar el truco de `position: fixed` para repetir encabezado/pie en el PDF final. Chromium `--print-to-pdf` tiene un mecanismo nativo para esto (`headerTemplate`/`footerTemplate` + márgenes explícitos vía la API/CLI de impresión) que no está sujeto a este bug — es la vía que ya preveía el comentario original del archivo CSS ("Fase 3A's own Chromium print-to-PDF call is the source of true page numbers via its native header/footer templates").
  - Por instrucción explícita del fundador durante esta sesión ("no nada de test de sistema, a menos que los test funcionales no lo cubran y sea crítico"), no se agregó ningún test de sistema (Capybara/Selenium) a la suite. La verificación multipágina se hizo íntegramente fuera de la suite de tests (script desechable + Chrome headless + `pdftoppm`), justificada porque (a) Minitest no puede ejercitar el motor de paginación de impresión de Chromium y (b) el hallazgo resultó crítico (contenido ilegible/encabezado ausente). Ningún archivo de test de sistema quedó en el repo.
  - No se copiaron declaraciones del PDF de referencia ni se construyó la guía normativa CENTRAVE completa; se reutilizaron únicamente los 8 ítems ya existentes de 1A vía `InspectionFinding#centrave_item_key`.
  - No se prometió paginación idéntica al HTML ni se implementó una plantilla adicional para PDF, conforme al mandato.
- **Insumos de 3A y 3B actualizados / próximo paso:** contrato de datos, rutas, CSS/assets, mecanismo de retorno y el hallazgo del bug de Chromium quedaron documentados en la sección "Insumos de 3A/3B" de la Fase 3, más abajo. **No activar 3A:** decisión del fundador de la misma noche (sección 2.4). Próximo paso: recorrer el flow y anotar UX; commit/PR de 1B cuando se autorice.

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

## Fase 3 — PDF server-side (diferida; subfases 3A y 3B)

**Activación original:** decisión del fundador del 9-sep al inicio del documento, que divide esta fase en **3A** (PDF asíncrono, archivo conservado y aislamiento) y **3B** (vista previa real, descarga y verificación de extremo a extremo). **Estado vigente (misma noche):** **diferida.** El piloto no exige archivo PDF conservado; la salida es `GET …/export` + imprimir. No lanzar `codex/certificador-3a-pdf` ni `codex/certificador-3b-preview` sin reactivación explícita en la sección 2. **Si se reactiva:** depende de 1B integrada; rige el contrato de producto compartido de la Fase 1 (puntos 3, 4, 5 y 6) más las reglas fijas 15 y 16. Los Insumos de 1A/1B más abajo siguen siendo el contrato técnico — no se tiran.

> **Deuda de documento, detectada al cerrar 1A:** la actualización del 9-sep reescribió la tabla de estado, el diagrama de flujo y la sección de la Fase 1, pero **no** reescribió el alcance ni los criterios de aceptación de esta sección, que abajo siguen redactados como la Fase 3 monolítica y condicionada (una gem, un botón, "trabajo de una tarde"). Esa descripción **ya no corresponde** al alcance decidido — snapshot consistente, job, archivo conservado, retención, aislamiento y fidelidad vista previa/descarga. Quien ejecute 1B debe dividir esta sección en 3A y 3B con alcance y aceptación propios antes de lanzar 3A; el ejecutor de 1A no lo hizo porque implicaba inventar alcance fuera de su mandato. El texto viejo se conserva abajo como historial, no como contrato.

**Insumos de 3A/3B actualizados por el cierre 1A (2026-09-09):**

- **Servir el logo dentro del job no puede pasar por HTTP.** `logo_certifier_settings_path` es un redirect 302 autenticado a una URL prefirmada, y depende de `current_account`: sirve para el navegador, no para Chromium renderizando desde un job sin sesión. Para el PDF, leer los bytes desde S3 con la clave (`Account#certifier_logo_s3_key`) e incrustarlos, o resolver una URL prefirmada de vida corta y asumir que Chromium tiene salida a S3. Decidirlo explícitamente y dejarlo en el cierre 3A.
- **`certifier_assets/` no tiene purga automática, por decisión de 1A.** Quitar o reemplazar un logo limpia la referencia de la cuenta y deja el objeto en S3, precisamente para que una exportación ya generada no pierda sus bytes (regla fija 15). Cuando 3A introduzca el historial de exportaciones, ahí recién se puede definir un borrado seguro: exige saber que ninguna exportación conservada referencia ese digest. No agregar purga sin esa información.
- **El snapshot tiene que incluir la identidad del emisor,** no solo el contenido del informe: nombre, rol MINVU y digest del logo vigentes al generar. Si no, cambiar el encabezado altera retroactivamente cómo se re-renderizaría un PDF ya entregado. El digest (`certifier_logo_sha256`) es el dato que hace verificable esa consistencia.
- **Aislamiento.** El patrón ya probado en 1A y en las fases anteriores: alcance por `CertificationReport.owned_by(account_id:, user_id:)` y ownership heredada del informe padre, nunca chequeada sobre el recurso hijo. Ambos ejes dan 404 (cuenta ajena y otro usuario de la misma cuenta). Para las rutas de estado/vista/descarga por ID de exportación, aplicar lo mismo. Para servir el archivo, el patrón de `FieldPhotosController` + `FieldPhotoUrlService.trusted_redirect_url?`, que `CertifierLogoUrlService` ya reutiliza: **una sola** definición de "esta URL apunta a nuestro bucket", para no abrir un redirect.
- **Almacenamiento.** `S3DocumentsService` (`upload_binary`, `download`, `delete_prefix`) es el camino; `config/storage.yml` no tiene S3 de Active Storage operativo y no se debe introducir. Prefijo propio para las exportaciones, jamás bajo `bulk_chunks/` (lo ingiere el KB) ni bajo `field_photos/` (lo purga la retención de evidencia).
- **Completitud antes de generar.** `Account#certifier_identified?` es el predicado que 1A dejó para exigir nombre y rol MINVU al pedir el PDF. 1A deliberadamente **no** lo validó en el modelo para no romper la captura (punto 1 del contrato compartido). El resultado (`CertificationReport#result`) puede estar vacío y el PDF debe generarse igual, mostrando "Resultado no registrado".
- **Tests.** Ojo con el host en cualquier prueba multi-cuenta (`host! "ascensoresclimb.localhost"`, hallazgo 1 del cierre 1A) y con el rescate de `ArgumentError` si se agrega algún enum de estado de exportación (hallazgo 3). `db/schema.rb` se edita a mano para mantener el diff aditivo (hallazgo 8).

**Insumos de 3A/3B actualizados por el cierre 1B (2026-09-09):**

- **La plantilla de contenido ya existe y es la que hay que renderizar, sin tocarla.** `app/views/certification_reports/exports/_document.html.erb` (+ `_findings_table.html.erb`) no depende de `current_user`/`request`/`current_account`: recibe únicamente el hash de locals descrito en el cierre 1B (`report:`, `issuer:`, `report_edit_url:`, `equipment_rows:`, `finding_rows:`), con toda URL ya resuelta de antemano. 3A debe construir ese mismo hash a partir del snapshot (no del informe en vivo) y renderizarlo con `ApplicationController.render(partial: "certification_reports/exports/document", locals: ..., layout: false)` — así lo verifiqué manualmente para la revisión visual de 1B, funciona fuera de un request autenticado. Los enlaces de edición (`report_edit_url`, `edit_url` por fila) deben venir en `nil` o ausentes en el snapshot: son de la revisión web, no tienen sentido en un PDF ya generado.
- **CSS: un solo archivo en disco, sin pipeline.** `app/assets/stylesheets/certifier_export_print.css` es hoja plana (sin Tailwind, sin CDN, sin fuentes remotas) — leerla con `File.read` e inyectarla en un `<style>` inline (o apuntar Chromium al archivo servido) es válido; no hace falta que el asset pipeline esté corriendo. Es el mismo archivo que ya estiliza la vista de revisión HTML: cualquier cambio visual al documento se hace ahí, una sola vez, para HTML y PDF.
- **Bug de Chromium confirmado — no reintroducirlo.** El CSS de impresión usa `position: fixed` con `top: 0`/`bottom: 0` (sin offset negativo) para el encabezado/pie repetido, y reserva el espacio con `padding-top`/`padding-bottom` en `.certifier-doc__body`, precisamente porque un offset negativo (`top: -14mm` tipo) dispara un bug real de Chromium: invierte qué borde de página ocupa el elemento y lo omite en la primera/última página (confirmado imprimiendo un PDF sintético de 7 páginas, ver cierre 1B). **3A no debe usar este mismo truco de `position: fixed` para repetir encabezado/pie en el PDF final** — usar en su lugar el mecanismo nativo de Chromium `--print-to-pdf` (`displayHeaderFooter` + `headerTemplate`/`footerTemplate` + márgenes explícitos vía la API/CLI de impresión, no CSS del documento), que no está sujeto a este bug y es el camino que ya preveía el comentario original del archivo CSS. Si 3A igual necesita el BORRADOR/marca de agua dentro del propio HTML (no como header/footer nativo), el patrón de `.certifier-doc__watermark` (posicionado con `top`/`left` + `transform`, sin offset negativo de borde) sí se comportó bien en las 7 páginas de la prueba y puede reutilizarse tal cual.
- **Verificación reproducible sin depender de un test de sistema.** Para revalidar el PDF de un snapshot real: renderizar el HTML final (con la plantilla + CSS embebido) a un archivo, e imprimir con Chrome headless: `"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --no-pdf-header-footer --print-to-pdf=out.pdf file:///ruta/al.html`. Contar páginas con la gema `pdf-reader` (`PDF::Reader.new("out.pdf").page_count`) y convertir cada página a imagen para inspección visual con `pdftoppm -png -r 100 out.pdf pagina` (Homebrew `poppler`). Esto es lo que usé para encontrar y confirmar la corrección del bug anterior; no requiere Capybara/Selenium ni agregar nada a la suite Minitest.
- **Retorno de edición no aplica al PDF.** El mecanismo `return_to=export` (concern `CertifierExportRedirect`) es exclusivo de la revisión HTML editable; el snapshot/PDF de 3A no tiene edición in-place, así que no hay nada que reutilizar ahí más allá de no romper esas rutas.

### Historial: alcance original de la Fase 3 monolítica (sustituido, ver deuda de documento arriba)

**Modelo asignado (histórico):** Grok (variante rápida; alternativa: Sonnet última versión). **Condición de activación (histórica, ya superada por la decisión del 9-sep):** un certificador real (o la demo con TAQUIÓN-CERT) pide un archivo adjuntable a la Carpeta Cero, **o** la validación de formato de la Fase 1 quedó aprobada y sobra capacidad.

**Alcance:** gem `grover` o `ferrum` (headless Chrome) rendereando la misma vista HTML de la Fase 1 → botón "Descargar PDF". Nota de deploy: Chrome/Chromium en la imagen de producción — documentar el costo operativo antes de mergear. La marca BORRADOR persiste.

**Criterios de aceptación:** PDF binario válido generado desde el informe de ejemplo; test que verifica header `%PDF` y páginas > 0; sin regresión en la vista HTML.

**Prompt de lanzamiento (Grok, variante rápida · effort low, sin thinking extendido) — solo con la condición de activación registrada:**

> Lee `docs/PLAN_IMPLEMENTACION_CERTIFICADOR_2026-08-09.md` (secciones 0 y 2.2, cierres de Fases 1–2, Fase 3); verifica que la condición de activación esté registrada — si no lo está, detente. Crea `certificador/fase-3-pdf` desde `main`. Renderiza la misma vista HTML de la Fase 1 con `grover` o `ferrum` hacia un botón "Descargar PDF"; documenta el costo operativo de Chrome/Chromium en la imagen de producción antes de mergear. La marca BORRADOR persiste. Test de header `%PDF` y páginas > 0; sin regresión en la vista HTML. Cierra el bloque de fase.

**Cierre 3A — lo llena el ejecutor:**

- Estado: **diferida** (2026-09-09 noche). No pendiente de 1B como siguiente entrega. Alcance y aceptación propios **aún no redactados** (ver deuda de documento al inicio de la Fase 3) — solo se redactan si se reactiva.
- Fecha / modelo / effort / branch / commit / PR:
- Snapshot / job / archivo conservado / retención / rutas / decisión sobre el logo en el job:
- Pruebas y verificación (comandos, resultados, límites):
- Hallazgos / desviaciones justificadas:
- Insumos de 3B actualizados / próximo paso:

**Cierre 3B — lo llena el ejecutor:**

- Estado: **diferida** (pende de reactivar 3A). Alcance y aceptación propios **aún no redactados**.
- Fecha / modelo / effort / branch / commit / PR:
- Vista previa / descarga / fidelidad con lo previsualizado / manejo de cambios posteriores:
- Pruebas y verificación de extremo a extremo (comandos, resultados, límites):
- Hallazgos / desviaciones justificadas:
- Próximo paso:

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

### Cierre de fase (2026-09-08)

- **Estado: CERRADA EN LOCAL, con una reserva explícita.** Branch `certificador/fase-5-captura-audio` desde `main`. Todos los criterios de aceptación se cumplen en navegador (Chrome headless a 390×844, micrófono falso), y la ruta completa se validó además **contra el servidor de dev real**: Puma + worker de Solid Queue + OpenAI + `VoiceDictationChannel` por `solid_cable`, sin recargar la página. Suite local completa verde: **2743 runs, 10928 assertions, 0 failures, 0 errors, 189 skips** (2699 de la Fase 4 + 44 tests nuevos: 31 de controlador, 3 de sistema, y el resto de modelo/servicios/job). Rubocop (`--cache false`) sin ofensas en los 15 archivos Ruby de la fase. `rag_chat_controller` y `ConversationSession` sin una línea de diff. **Costo de la validación: USD 0,0013** (dos dictados de 13 s por OpenAI, `gpt-4o-mini-transcribe`).
- **La reserva:** el criterio "en móvil real" **no se ejecutó** — el ejecutor no tiene un teléfono, y además hay un prerrequisito que el plan no anticipaba (hallazgo 3: `getUserMedia` exige HTTPS, así que `http://<ip-del-mac>:3000` desde el teléfono muestra "Este navegador no permite grabar"). Queda como paso del fundador, con receta abajo; lo que sí se ensayó en navegador real fue cada una de las tres rutas de recuperación y la pérdida de conexión.

**Qué se construyó (sin tocar nada del chat):**

| Pieza | Archivo | Nota |
|---|---|---|
| Un control + un elemento de estado | `app/javascript/controllers/voice_dictation_controller.js` | máquina `idle → starting → recording → uploading → idle / failed`; `MediaRecorder` con negociación de MIME (`webm/opus`, `mp4`, `ogg`); upload-first por `fetch` con respuesta Turbo Stream; guarda de doble tap (< 1 s no se sube ni se factura); reintento del upload por tap o por evento `online`; suscripción al canal privado como *señal* y refetch de la tarjeta desde la base (nunca pinta el preview del broadcast); re-lectura de lo que está en vuelo al reconectar el cable y al volver la pestaña a primer plano |
| Autosave de la corrección | `app/javascript/controllers/transcript_autosave_controller.js` | PATCH debounced (800 ms tras el último `input`); muestra "Guardando… / Guardado / No se guardó"; un fallo de red reintenta a los 5 s; un `409` (el dictado ya dejó `transcribed`) se muestra y no se reintenta |
| Tarjeta del dictado por estado | `app/views/voice_dictations/_voice_dictation.html.erb` | `pending`/`transcribing` → "Transcribiendo…"; `transcribed` → panel editable (textarea 172 px, ubicación 60 px, Confirmar 72 px, Descartar 72 px); `failed` → razón + Reintentar (solo si hay audio) o regrabar + Descartar |
| Hallazgo resaltado con undo inline | `app/views/certification_reports/_finding.html.erb` | etiqueta "Agregado desde dictado", marco azul, botón Deshacer 60 px como acción primaria, solo en el render inmediatamente posterior a confirmar (`flash[:highlight_finding_id]`) |
| Controlador y rutas | `app/controllers/voice_dictations_controller.rb`, `config/routes.rb` | `create` (upload), `show` (refetch de la tarjeta), `update` (autosave), `confirm`, `undo`, `retry`, `destroy`; todo por `VoiceDictation.owned_by(account_id:, user_id:)` |
| Modelo / servicios | `VoiceDictation.record_edit`, `.reopen_confirmed!`, scope `awaiting_certifier`; `VoiceDictationConfirmation.undo`; `VoiceDictationRetry` | `record_edit` es un UPDATE condicional a `status = transcribed`: un resultado tardío del proveedor nunca pisa una corrección, y una corrección nunca entra a un dictado ya confirmado |
| Cola propia | `app/jobs/transcription_job.rb` (`queue_as :transcription`), `config/queue.yml` | ver desviación 1 |

**Prueba end-to-end contra el servidor de dev (OpenAI, `language=es`, cable privado):**

| | |
|---|---|
| Montaje | `bin/rails s -p 3005` + `STT_PROVIDER=openai bin/jobs start` (ambos con `DB_USERNAME=lahirisan`), Chrome headless 390×900 con micrófono falso, usuario temporal `fase5-e2e@danebo.test` en la cuenta legacy (creado y **borrado** al terminar, con sus dos informes, dos dictados y su audio en S3) |
| Grabar → tarjeta en pantalla | tap parar → **2,2 s** después la tarjeta está en `pending` (upload a S3 + fila + job encolado + Turbo Stream renderizado) |
| Tarjeta → panel editable | **4,1 s** más tarde la tarjeta pasa a `transcribed` **sin recargar**: broadcast privado → refetch → `turbo_stream.replace`. Es la única prueba que existe del camino por cable, porque el adapter de test de ActionCable no llega al navegador (hallazgo 6) |
| Autosave | escribir en el textarea → "Guardado" en < 1 s; recargar la página conserva la corrección (criterio b) |
| Confirmar | hallazgo creado con `body` = texto corregido y `location` = "Embarque 4", resaltado con Deshacer; la tarjeta desaparece del panel |
| Deshacer | el hallazgo se elimina, el dictado vuelve al panel **con la corrección intacta**; re-confirmar vuelve a crear el hallazgo |
| Costo | 2 dictados × 13 s × USD 0,003/min = **USD 0,0013**; cero filas en `bedrock_queries` |

**Hallazgos:**

1. **El test de sistema atrapó un bug real que los 31 tests de controlador no podían ver.** `form_with url:` **sin `scope:`** genera campos con nombre plano (`transcript_edited`, `location`), no anidados (`voice_dictation[transcript_edited]`). El controlador leía `params[:voice_dictation]`, así que **el texto que el certificador tenía en pantalla al tocar Confirmar se ignoraba** y la confirmación usaba solo lo que el autosave hubiera alcanzado a guardar — funcionaba "casi siempre" por la carrera del debounce, que es el peor tipo de bug. Los tests de controlador pasaban porque posteaban los params anidados a mano. Lección para las fases con formulario: **cada `form_with url:` lleva `scope:` explícito**, y al menos un test tiene que enviar el formulario *renderizado*, no params construidos.
2. **Un dictado en silencio produce una transcripción convincente en un idioma al azar, con `language=es` puesto.** Chrome headless no reprodujo el WAV del micrófono falso (hallazgo 5), así que los dos dictados de la prueba real fueron **13 s de silencio** (3,4 KB de Opus, ~2 kbps). OpenAI devolvió `"In der Tat,"` (alemán) y `"我嘅意思係,我哋關於打工嘅問題…"` (cantonés) — la alucinación conocida de la familia Whisper sobre silencio, que **el parámetro `language` no evita**. En terreno es un caso real: tap accidental, micrófono silenciado por el sistema, o el teléfono en el bolsillo. Hoy la única defensa es el gate de la regla fija 3 (el certificador ve el texto y no lo confirma), que funciona pero **cuesta una llamada facturada y un tap de descartar**. Palancas, en orden de preferencia: **(a)** en el cliente, un medidor de nivel (`AnalyserNode`) durante la grabación que no suba un audio cuyo RMS nunca superó el umbral — es determinista, gratis, y de paso da el "indicador de nivel" del alcance que esta fase no implementó (desviación 2); **(b)** en el servidor, `bytes/segundo` es un proxy fuerte de silencio para Opus (~2 kbps vs ~30 kbps con voz) pero depende del códec — Safari graba AAC/mp4 con otra curva — así que **no** sirve como guarda universal sin medirlo por códec. Ninguna de las dos se hizo aquí: el umbral de (a) hay que calibrarlo con ruido real de sala de máquinas, no con el micrófono de un Mac, y eso es exactamente el material de la Fase 6. **Insumo directo de la Fase 6.**
3. **`getUserMedia` exige contexto seguro: la prueba en móvil real necesita HTTPS.** Desde un teléfono contra `http://<ip>:3000`, `navigator.mediaDevices` es `undefined` y la UI cae correctamente en "Este navegador no permite grabar. Escribe el hallazgo abajo." (el fallback de texto tecleado del criterio). Producción no tiene el problema (Kamal termina TLS). Para dev ya existe el mecanismo: `AccountHostResolver` acepta `DEV_TUNNEL_FALLBACK_ACCOUNT_SLUG` justo para túneles HTTPS, y `development.rb` ya tiene `config.hosts.clear`. **Receta para el fundador:**

   ```bash
   # terminal 1 — servidor (el flag del certificador ya está en .env)
   DEV_TUNNEL_FALLBACK_ACCOUNT_SLUG=danebo-legacy DB_USERNAME=lahirisan bin/rails s -p 3000
   # terminal 2 — worker (STT_PROVIDER=openai si se quiere barato y rápido; sin él, Transcribe)
   DB_USERNAME=lahirisan bin/jobs start
   # terminal 3 — túnel HTTPS (sin cuenta) → imprime una URL https://…lhr.life
   ssh -R 80:localhost:3000 nokey@localhost.run
   ```

   Abrir la URL en el teléfono, entrar como `lahiri.sanchez@gmail.com`, abrir el informe 2 ("STT smoke test"): el **dictado id 2** aparece en el panel editable con sus errores reales ("rosa", "dos separadas", "NCH28040") — es el caso ideal para autosave + confirmación, como anticipó el cierre de la Fase 4. Después grabar uno nuevo con voz propia. **Dos avisos:** (i) ActionCable en development solo acepta orígenes `localhost`, así que a través del túnel el websocket será rechazado y la tarjeta **no** cambiará sola — cambiará al bloquear/desbloquear el teléfono (refresh por `visibilitychange`) o al recargar. Para ver el camino en vivo, descomentar por esa sesión la línea `config.action_cable.disable_request_forgery_protection = true` que ya está en `config/environments/development.rb` (y no commitearla). (ii) Usar `DB_USERNAME=lahirisan` es obligatorio por el hallazgo 4.
4. **La tabla `voice_dictations` de dev pertenece a `lahirisan`, no a `app_user`.** La migración de la Fase 4 corrió con `DB_USERNAME=lahirisan`, así que es la única tabla del certificador sobre la que `app_user` (el rol por defecto de `database.yml`) no tiene permisos: `PG::InsufficientPrivilege: permission denied for table voice_dictations`. Antes no importaba; **desde esta fase el `show` del informe consulta la tabla, así que `bin/dev` sin `DB_USERNAME` devuelve 500 en todos los informes.** El ejecutor no lo corrigió (es un cambio en la base de dev, fuera del repo); el fix es una línea, como superusuario: `psql -U lahirisan -d smart_deal_development -c "ALTER TABLE voice_dictations OWNER TO app_user; ALTER SEQUENCE voice_dictations_id_seq OWNER TO app_user;"`. Regla para las próximas migraciones en dev: correrlas con el mismo rol que corre el servidor, o alinear el owner después.
5. **El micrófono falso de Chrome sirve para probar la cañería, no para meter voz real por el navegador.** `--use-fake-device-for-media-stream` funciona en headless y produce audio (tono/silencio) suficiente para ejercitar `MediaRecorder`, el upload y el flujo completo. Pero `--use-file-for-fake-audio-capture=<wav>` **no reprodujo el archivo** en `--headless=new`, ni con WAV 16 kHz mono ni con 48 kHz estéreo — los dos dictados salieron en silencio (hallazgo 2). Consecuencia para la Fase 6: **el benchmark no debe pasar por el navegador**; la vía correcta sigue siendo `bin/rails "stt:smoke[archivo.wav,segundos]"` o el script de la fase llamando a los adapters directo, y la voz real por el navegador se prueba con un teléfono.
6. **Cómo se testea la UI de audio en este repo, para no redescubrirlo:** `test/system/voice_dictation_capture_test.rb` declara su propio `driven_by` con los flags `--use-fake-ui-for-media-stream` y `--use-fake-device-for-media-stream` y un viewport de 390×844 (el `ApplicationSystemTestCase` compartido sigue en 1400×1400, sin tocar); con eso el test graba de verdad con `MediaRecorder`. Tres límites y sus soluciones: (a) **ActionCable no llega al navegador en tests** (adapter `test`), así que el resultado del job se simula con los métodos del modelo y se fuerza el refresh disparando `visibilitychange` — el camino por cable se validó en dev (tabla de arriba); (b) **la pérdida de conexión se ensaya con CDP** (`driver.browser.network_conditions = { offline: true }`), que sí bloquea el `fetch` a Puma; (c) **el doble tap hay que dispararlo desde la página** (`execute_script` con dos clicks a 300 ms), porque los round-trips de Selenium estiran el intervalo por encima del umbral de 1 s y el test falla por la razón equivocada. El test tarda 12 s en total.
7. **La fixture `cabina_dictado` vive en el mismo informe que usan los tests, y lo volvió a hacer.** Los dos primeros "Expected 0, Actual 1" del test de sistema no eran bugs: eran la fixture. Misma familia que el hallazgo 6 de la Fase 4 y el `order(:id).last` de la Fase 2: todo conteo en tests de este módulo se hace sobre `where.not(id: fixture.id)` o sobre el objeto recién creado. Como contrapartida, tener la fixture en la página **es** la prueba de "al reabrir se ven los dictados en curso", y el test la usa así.
8. **`awaiting_certifier`, no `in_progress`, para la reapertura.** El insumo de la Fase 4 decía "muestra `in_progress` (`pending`/`transcribing`/`transcribed`)"; eso habría escondido los `failed`, que son precisamente los que necesitan una decisión humana (reintentar T5 o descartar — regla fija 13). El scope nuevo es "todo lo no confirmado", ordenado por creación.
9. **Tiempos observados**, para calibrar el indicador de estado: parar → tarjeta 2,2 s; tarjeta → panel 4,1 s con OpenAI. Con Transcribe el segundo tramo será 10–15 s (Fase 4: 11 s) y el indicador ya lo tolera sin reintentar solo; el caso de 30 min de claim huérfano (`STT_STALE_CLAIM_MINUTES`) se ve como "Transcribiendo…" sin cambios, que es lo acordado.
10. **Operativa local, igual que en la Fase 4:** `PARALLEL_WORKERS=1 DB_USERNAME=lahirisan bin/rails test` y `bin/rubocop --cache false`. Y el CSS: `bin/rails tailwindcss:build` antes de una prueba manual, porque las variantes nuevas (`data-[state=recording]:…`) no existen en el `tailwind.css` compilado de la fase anterior.

**Desviaciones del plan:**

1. **`TranscriptionJob` se movió a una cola propia `transcription` (2 threads)** — toca un archivo de la Fase 4 (una línea) y `config/queue.yml`. Motivo: el job hace el *poll* del proveedor dentro del propio job, así que retiene un thread 10–60 s por dictado; en la cola `default` compartida, dos o tres certificadores dictando a la vez retrasarían el pie de costo del chat y el análisis de fotos. Dos threads además acotan el gasto: nunca hay más de dos llamadas al proveedor en vuelo. Con test que fija el nombre de la cola y verifica que `queue.yml` tenga un worker para ella.
2. **Sin indicador de nivel de audio; solo duración.** El alcance decía "indicador de nivel/duración". El estado muestra "Grabando · 0:07" y el botón cambia a rojo con icono de parar; no hay vúmetro. Decisión deliberada por el principio de "un solo elemento mínimo" (Wispr Flow) y porque un medidor exige `AudioContext`+`AnalyserNode`, que es exactamente la pieza que resolvería el hallazgo 2 — mejor construirla una vez, calibrada con ruido real, en la Fase 6.
3. **Confirmar manda el texto en pantalla, no depende del autosave.** El POST de `confirm` lleva `transcript_edited` y lo guarda antes de confirmar; así la carrera entre el debounce de 800 ms y el tap de confirmar no puede perder la última palabra escrita. El hallazgo 1 es la prueba de que esto importaba.
4. **Deshacer = borrar el hallazgo y devolver el dictado a `transcribed`** (`reopen_confirmed!`, UPDATE condicional), conservando `transcript_edited`. El botón solo existe en el render inmediatamente posterior a confirmar (patrón Salesforce); después, el camino es el "Eliminar" normal del hallazgo, que no reabre el dictado. No es un deshacer genérico ni una papelera.
5. **Servicio `VoiceDictationRetry` nuevo** (12 líneas): envuelve `reopen_failed!` + `perform_later` para que el único lugar que gasta una segunda llamada facturada sea explícito y testeable, y no una línea suelta en el controlador.
6. **El estado `starting`** no estaba en el diseño: se agregó al ver que un segundo tap mientras el permiso de micrófono está abierto habría creado un segundo `MediaRecorder`. El botón se deshabilita en cuanto se toca y se rehabilita al empezar a grabar.
7. **Móvil real: no ejecutado** (ver reserva y hallazgo 3).

**Actualizaciones aplicadas a fases siguientes:**

- **Fase 6:** bloque de insumos nuevo — la alucinación sobre silencio como caso a medir y la guarda de nivel como palanca (hallazgo 2); el benchmark no pasa por el navegador (hallazgo 5); la cola `transcription` de 2 threads implica que el script del benchmark debe llamar a los adapters directo y no encolar jobs (o serializaría el benchmark); una muestra de costo real de dictado corto por OpenAI (13 s → USD 0,00065, sin mínimo facturable, vs USD 0,006 fijos de Transcribe); y el códec real que sale del navegador (`audio/webm;codecs=opus` en Chrome; Safari dará `audio/mp4`), que el set de audios del benchmark debería incluir junto al WAV limpio.
- **Fase 7 (condicionada):** sin cambios. El panel editable ya recibe el texto completo desde la base, así que una estructuración posterior tiene dónde colgarse sin tocar la captura.

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

*Actualizado con el cierre de la Fase 5 (2026-09-08):*

- **Agrega un caso al protocolo: silencio.** Dos dictados de 13 s de silencio (3,4 KB de Opus) volvieron de OpenAI como `"In der Tat,"` y una frase en cantonés, **con `language=es` puesto** — alucinación de la familia Whisper sobre audio vacío, que el parámetro de idioma no evita (hallazgo 2 del cierre de la Fase 5). Mide qué devuelve cada proveedor ante (i) silencio puro, (ii) ruido de sala de máquinas sin voz, (iii) voz muy baja: es un dato de calidad tanto como la tasa de error sobre jerga, porque un texto plausible en otro idioma dentro del panel editable es peor que un texto vacío. Y **calibra ahí el umbral de la guarda de nivel** (RMS con `AnalyserNode` en el cliente) que la Fase 5 dejó pendiente: el umbral tiene que dejar pasar la voz sobre ruido de fondo real y cortar el silencio, y eso solo se puede fijar con las grabaciones con ruido de este protocolo. Es también la pieza que daría el "indicador de nivel" del alcance original de la Fase 5.
- **El benchmark no pasa por el navegador.** El micrófono falso de Chrome headless no reproduce archivos (`--use-file-for-fake-audio-capture` no funcionó, hallazgo 5), así que la voz de prueba entra por `bin/rails "stt:smoke[archivo.wav,segundos]"` o llamando a los adapters directo desde el script. Y **llámalos directo, no vía `TranscriptionJob`**: el job vive ahora en la cola `transcription` con 2 threads (desviación 1 de la Fase 5), que serializaría el benchmark de a dos.
- **Incluye el códec real del navegador en el set de audios, no solo WAV limpio.** Chrome graba `audio/webm;codecs=opus` (~30 kbps con voz; ~2 kbps en silencio); Safari dará `audio/mp4` (AAC). Un mismo dictado en WAV 16 kHz, webm/opus y m4a mide si la compresión del cliente le cuesta precisión a algún proveedor — Transcribe acepta los tres; OpenAI y Groq también.
- **Muestra de costo real de dictado corto** para la tabla de COGS: 13 s por OpenAI `gpt-4o-mini-transcribe` = **USD 0,00065** (sin mínimo facturable), contra los **USD 0,006** fijos de Transcribe por el mínimo de 15 s. En el caso base "un dictado corto por hallazgo", la diferencia es ~9× por hallazgo; el benchmark debería costear un informe tipo (n hallazgos × dictado corto) además del dictado largo de 15–20 min.

**Alcance:**

- Script/rake reproducible: mismo set de audios → todos los adapters disponibles (Transcribe, OpenAI mini, y Groq si existe; agregar `GroqAdapter` aquí si no cayó en Fase 4) → tabla comparativa: costo real por minuto (facturado, no estimado, cuando el proveedor lo exponga), latencia de batch, y transcripciones lado a lado para conteo manual de errores sobre las 20 frases técnicas.
- Registrar resultados **en este documento** (tabla en el cierre de esta fase) y actualizar la recomendación de `STT_PROVIDER` default en la sección 4.
- Salida esperada: costo por dictado de 15–20 min por proveedor + tasa de error sobre jerga → insumo directo de la hipótesis de precio por informe (sección 6 del plan de septiembre).

**Criterios de aceptación:** tabla completa con al menos 3 proveedores; decisión de default tomada y escrita; costo total del benchmark documentado (debería ser < USD 2).

**Prompt de lanzamiento (Grok, variante rápida · effort low, sin thinking extendido):**

> Lee `docs/PLAN_IMPLEMENTACION_CERTIFICADOR_2026-08-09.md` (secciones 0, 4 y Fase 6, más el cierre de la Fase 4). Crea `certificador/fase-6-benchmark-stt` desde `main`. Escribe un script/rake reproducible que corra el mismo set de audios contra todos los adapters disponibles y produzca la tabla comparativa (costo real por minuto, latencia de batch, transcripciones lado a lado). Si `GroqAdapter` no existe, agrégalo aquí (~30 líneas, API Whisper-compatible). No tomes la decisión de proveedor default: registra la tabla en el cierre de esta fase y deja el conteo de errores sobre las 20 frases técnicas al fundador. Documenta el costo total del benchmark (< USD 2).

### Cierre de fase (2026-09-09)

- **Estado: CERRADA EN LOCAL.** Branch `certificador/fase-6-benchmark-stt` desde `main`. `GroqAdapter` ya existía (Fase 4). Runner: `SpeechToText::Benchmark` + `bin/rails stt:benchmark` (adapters directo, sin `TranscriptionJob`, sin filas `VoiceDictation`). 22 tests nuevos/actualizados verdes. **`STT_PROVIDER` default no se cambió** (`amazon_transcribe`). El conteo de errores sobre las 20 frases técnicas queda al fundador (scorecard vacío en `tmp/stt_benchmark/20260909Tfase6/table.md`).

**Corrida oficial** (`STT_BENCHMARK_RUN_ID=20260909Tfase6`, 10 clips, Paulina TTS 16 kHz + ruido sintético mezclado; silencio / ruido / voz baja / m4a). List-price × billed seconds, tabla `Pricing` 2026-08-09. Ningún proveedor devolvió línea de factura en la respuesta.

| Lane | OK | Errors | Billed s | Cost USD | USD / billed min | p50 latency s | p95 latency s |
|---|---:|---:|---:|---:|---:|---:|---:|
| amazon_es-US | 10 | 0 | 210 | 0.084000 | 0.024000 | 14.13 | 26.46 |
| amazon_es-ES | 10 | 0 | 210 | 0.084000 | 0.024000 | 10.54 | 32.76 |
| amazon_es-MX | 10 | 0 | 210 | 0.084000 | 0.024000 | 13.83 | 911.67 |
| openai (`gpt-4o-mini-transcribe`) | 10 | 0 | 179 | 0.008950 | 0.003000 | 2.59 | 4.85 |
| groq (`whisper-large-v3-turbo`) | 10 | 0 | 179 | 0.002088 | 0.000700 | 0.87 | 3.49 |

**Costo total de esta corrida: USD 0,263** (bajo USD 2). Una segunda corrida solapada con el mismo `RUN_ID` sumó ~USD 0,23 más y un 404 de S3 (hallazgo 3); all-in de medición **< USD 0,50**.

**COGS proyectado (list price, no el audio de esta corrida):**

| Lane | Hallazgo 13 s | Informe 8 hallazgos cortos | Dictado 15 min | Dictado 20 min |
|---|---:|---:|---:|---:|
| amazon_* | 0.006 | 0.048 | 0.360 | 0.480 |
| openai | 0.00065 | 0.0052 | 0.045 | 0.060 |
| groq | 0.00015 | 0.0012 | 0.0105 | 0.014 |

Transcripciones lado a lado (paquete de 20 frases — para el scorecard del fundador):

| Esperado (extracto) | amazon es-US / es-ES / es-MX (idénticos) | OpenAI | Groq |
|---|---|---|---|
| roza en el marco | **rosa** | **roza** | **rosa** |
| A32.4 | a 32, cuatro | A324 | A32. 4 |
| doce paradas | 12 **separadas** | **dos separadas** | **12 paradas** |
| NCh 2840 | Nch 2840 | NCH2840 | NCH 2840 |
| 450 kilos / 1,6 m/s | correcto | correcto | correcto |
| holgura | **Hura** | Holgura | Holgura |
| KM 887 | Km 887 | KM887 | KM887 |
| Kone MonoSpace | **Kne mono espace** | Kone MonoSpace | Kone Monoespace |

Silencio 13 s: Amazon → vacío; OpenAI → coreano; Groq → "Gracias.". Ruido sin voz: Amazon y OpenAI → vacío; Groq → "y". Voz baja: OpenAI vacío, Groq "y", Amazon alucina ("flecha de cadena"). m4a: los tres transcriben, con más errores que el WAV.

- **Decisión de proveedor default:** **tomada el 2026-09-09 por el fundador, sobre esta tabla: `groq` / `whisper-large-v3-turbo`.** El razonamiento y el orden operativo (`groq` → `openai` → `amazon_transcribe` solo por residencia de datos) quedan escritos en la sección 4; el cambio es `SpeechToText::Client::DEFAULT_PROVIDER`. La premisa de la sección 4 —"el driver será la tasa de error, no el costo"— no se sostuvo: el más barato ganó también en latencia y en tipo de error, así que las tres columnas apuntaron al mismo lane y el scorecard de 20 frases dejó de ser el desempate. Se activó al mismo tiempo la palanca de jerga (`SpeechToText::JargonPrompt` → campo `prompt` de OpenAI/Groq), que es lo que el hallazgo 4 dejó sin medir; el custom vocabulary de Amazon sigue sin correrse porque Amazon dejó de ser el default.

**Hallazgos:**

1. **`OPENAI_API_KEY` no autentica Groq.** Hace falta `GROQ_API_KEY` (`gsk_`). Quedó en `.env.sample`.
2. **Las tres variantes de Transcribe devolvieron el mismo texto** en TTS limpio. `es-MX` no perdió los números en este set (la predicción de la Fase 4 no se reprodujo aquí). La latencia p95 de `es-MX` llegó a 911 s — el poll de batch, no un fallo.
3. **Cleanup de S3 al terminar no puede ser el default.** Dos `stt:benchmark` con el mismo `RUN_ID` en paralelo: el primero borró el prefijo y el segundo recibió `Failed to download audio from S3` (404) en `es-MX`. `STT_BENCHMARK_CLEANUP_S3` queda opt-in.
4. **Custom vocabulary / `prompt` de OpenAI no se midieron** — el prompt de lanzamiento pedía la tabla cruda y dejar el conteo al fundador. Siguen siendo la palanca de jerga de la Fase 4. *(Cerrado el 2026-09-09 para el `prompt`: medido contra Groq al escribir el default, tabla pareada en la sección 4. Corrige ortografía de marca, no corrige el homófono ni el código partido, y empeora el audio sin voz. El custom vocabulary de Amazon sigue sin correrse.)*
5. **Sin ffmpeg no hay webm/opus.** El set incluye WAV + un m4a (`afconvert`). Chrome real (`webm/opus`) queda fuera.
6. **El ruido es sintético**, no sala de máquinas. El umbral RMS de la Fase 5 sigue sin calibrar con grabación de campo.
7. **Reproducir:** `DB_USERNAME=lahirisan bin/rails stt:benchmark:prepare` y `bin/rails stt:benchmark`. Audio y tabla en `tmp/stt_benchmark/` (gitignored).

**Desviaciones del plan:** default no escrito (el prompt de lanzamiento lo veta); custom vocabulary no corrido; webm no generado; ruido no es de campo.

**Actualizaciones aplicadas a fases siguientes:**

- **Fase 7 (condicionada):** el default STT pasó a `groq` el 2026-09-09 (sección 4). Un dictado confirmado puede llegar con "rosa"/códigos partidos/marcas rotas — la estructuración no debe "corregir" jerga. Silencio/ruido pueden producir texto plausible en otro idioma (OpenAI/Groq): no auto-confirmar nunca (regla fija 3, ya en pie).


---

## Fase 7 — Estructuración del dictado en hallazgos

**Estado: CONDICIONADA** (sección 2.2, gap 1): el circuito base funciona con un dictado = un hallazgo, sin LLM. **Condición de activación:** gate del 2 de octubre superado con uso real (plan de septiembre, sección 8), y dictados largos multi-hallazgo observados en uso que la justifiquen. **Modelo asignado:** Opus última versión (alternativa: GPT Ultra). Toca prompts con red lines de seguridad y el costo por informe.
**Depende de:** Fases 4 y 5 (y de la evidencia de la 6).

**Insumos:** `app/prompts/AGENTS.md` (prompts compactos, determinista antes que LLM); reglas fijas 1 y 4.

*Actualizado con el cierre de la Fase 6 (2026-09-09):*

- **`STT_PROVIDER` default es `groq` / `whisper-large-v3-turbo`** desde el 2026-09-09 (sección 4). Es también el proveedor de menor latencia, así que la estructuración no puede apoyarse en "el certificador ya lleva rato esperando de todos modos" para justificar una llamada LLM lenta.
- **La jerga llega sucia al texto confirmado** (homófono "rosa", "A32.4" partido, marcas). La estructuración no "arregla" eso: segmenta lo que el certificador confirmó. El `prompt` de jerga de la sección 4 es la única capa que toca la ortografía, y actúa antes de la confirmación, no después.
- **Silencio y ruido pueden devolver texto convincente** (OpenAI en coreano, Groq "Gracias." y "y"). Nunca auto-confirmar un dictado (regla fija 3).
- **La alternativa económica de LLM ya no tiene que salir de Bedrock** (grounding 2026-09-09): xAI entró como proveedor de Bedrock — Grok 4.3 en junio por el motor Mantle (endpoint aparte, API compatible con OpenAI, el SDK `bedrock-runtime` no sirve) y **Grok 4.6 en agosto sí sobre `bedrock-runtime` con `Converse` y perfiles cross-region `us.xai.grok-4.6` / `global.xai.grok-4.6`** ([anuncio](https://aws.amazon.com/about-aws/whats-new/2026/08/amazon-bedrock-grok-4-6/), [model card](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-xai-grok-4-6.html)). Consecuencia concreta para el alcance de esta fase: evaluar un modelo económico distinto de Haiku **ya no obliga** a la rama de "proveedor externo → log estructurado", porque por `Converse` la telemetría cae en `bedrock_queries` como cualquier otra invocación. Preferir esa vía sobre un proveedor externo; y si se usa Grok, el perfil `global.` sobre el `us.` por la prima documentada del 10% en perfiles regionales (`AGENTS.md` raíz). Nada de esto se implementa hasta que la condición de activación esté registrada.

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
- **PDF server-side (3A/3B) mientras sigan diferidas** — job, snapshot, archivo conservado, vista previa/descarga del mismo binario. El piloto imprime desde el navegador. No implementar “otra plantilla PDF” ni un botón de PDF inoperante.
- **Features nuevas del módulo certificador** hasta que el fundador liste mejoras de UX concretas (sección 2.4). Un pulido no inventa captura, clasificación automática ni un segundo diseño de informe.

## 7. Relación con los cortes de septiembre

Este plan ejecuta directamente el calendario del plan de septiembre (sección 3): Fases 0 (núcleo) y 2 en la semana del 7 al 11 de septiembre — borrador persistente demostrable con texto manual; Fases 4 y 5 entre el 14 y el 16 — circuito de audio extremo a extremo para el corte del 16-sep; Fase 6 en la semana del 17 al 21 — instrumentación de costo y correcciones. Si el corte del 16-sep no encuentra el borrador y el circuito confirmable en pie, se congela todo lo condicionado y el resto del ciclo se dedica al circuito reutilizable (plan de septiembre, sección 8).

**Actualización 2026-09-09:** 1A y 1B se adelantaron por decisión del fundador y están cerradas en local (1A en `main`; 1B pendiente de PR). **La misma noche se cerró la incorporación de funcionalidades:** 3A/3B quedan diferidas; la Fase 7 sigue condicionada al gate del 2-oct. El piloto usa Revisar informe + impresión del navegador. Lo que **nunca** se recorta no cambia: borrador persistente y transcripción visible/editable.
