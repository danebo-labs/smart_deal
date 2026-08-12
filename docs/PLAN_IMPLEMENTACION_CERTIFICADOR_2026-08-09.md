# Danebo — Plan de Implementación: Módulo Certificador (2026-08-09)

**Documento padre:** [PLAN_GENERAL_2026-08-07.md](PLAN_GENERAL_2026-08-07.md) (sección 4) · [PLAN_SEPTIEMBRE_2026.md](PLAN_SEPTIEMBRE_2026.md) (sección 3).
**Naturaleza:** documento vivo de ejecución. Las fases se ejecutan en sesiones de agente independientes ("ejecutores"), potencialmente con modelos distintos. Ver protocolo en sección 1.
**Motivo del adelanto:** el plan de septiembre ordenaba modelo de datos → voz → estructura → exportable porque septiembre tiene solo 15 días hábiles efectivos. Al adelantar la construcción a agosto con ejecución por agentes, se recupera el orden que pide el fundador: primero lo determinista y verificable (modelo de datos + exportable según formato real), después la voz. El corte del 16 de septiembre y la escalera de recorte del plan de septiembre siguen vigentes como red de seguridad.

---

## 0. Reglas fijas (ningún ejecutor las contradice)

Heredadas del Plan General sección 4.2 y de los `AGENTS.md` del repositorio:

1. **Danebo no evalúa cumplimiento.** No clasifica gravedad por su cuenta, no decide si un equipo aprueba o reprueba, no firma. La clasificación leve/grave y la casilla de norma las asigna **el certificador** al revisar; Danebo solo ofrece los campos.
2. **Todo documento exportado sale marcado como BORRADOR.**
3. **Ninguna versión de voz envía audio directo a generación.** La transcripción es siempre visible y editable antes de incorporarse al borrador (gate de la sección 3.2 del plan de septiembre).
4. **La captura es dictado libre; la estructura se aplica después.** Sin formularios extensos ni clasificación obligatoria durante la inspección.
5. **Derivación determinista de la norma aplicable** desde la fecha de recepción municipal, en Rails, sin llamada al modelo. Presentarla es ayuda documental, no evaluación.
6. **No se toca `ConversationSession`** (ruta caliente de latencia).
7. **Cost-first:** ninguna llamada externa nueva sin telemetría de costo. Las transcripciones **no** crean filas en `bedrock_queries` (enum `source` cerrado, asume tokens): tienen su propia tabla (Fase 4).
8. **Multi-tenant:** todo modelo nuevo lleva `account_id` y sigue el scoping por host (`current_account`).
9. Antes de tocar un directorio, leer su `AGENTS.md` scoped (`app/`, `app/javascript/`, `app/views/`, `test/`, `app/prompts/`).

---

## 1. Protocolo de documento vivo

- **Antes de ejecutar una fase**, el ejecutor lee: este documento completo, los bloques *Cierre de fase* de todas las fases anteriores, y el bloque *Insumos* de su propia fase.
- **Al cerrar una fase**, el ejecutor: (a) llena su bloque *Cierre de fase* con hallazgos y desviaciones; (b) **edita los bloques *Insumos* de las fases siguientes afectadas** — no basta con anotar el hallazgo en la fase propia; (c) actualiza la tabla de estado de la sección 2.
- **Prompt sugerido para lanzar cada fase:**

> Lee `docs/PLAN_IMPLEMENTACION_CERTIFICADOR_2026-08-09.md` completo. Crea el branch `certificador/fase-N-<nombre>` desde `main` actualizado y trabaja ahí (sección 2.1). Ejecuta la Fase N respetando la sección 0 (reglas fijas) y los `AGENTS.md` del repositorio. Todo cambio de comportamiento lleva tests Minitest; prueba en local antes de dar por cerrada la fase. Al terminar: llena el bloque "Cierre de fase" de la Fase N y actualiza los bloques "Insumos" de las fases siguientes que tus hallazgos afecten.

---

## 2. Estado de ejecución

| Fase | Entregable | Estado | Modelo recomendado |
|---|---|---|---|
| 0 | Modelo de datos del borrador persistente | pendiente | Razonamiento alto |
| 1 | Exportable HTML con hoja de impresión (formato NCh 2840) | pendiente | Estándar |
| 2 | Lista "mis informes" + editor del borrador | pendiente | Estándar |
| 3 | PDF server-side | **condicionada** | Rápido/económico |
| 4 | Capa de transcripción agnóstica al proveedor | pendiente | Razonamiento alto (diseño) |
| 5 | UI de captura de audio (dictado) | pendiente | Estándar |
| 6 | Benchmark de costo/calidad STT + COGS de voz | pendiente | Rápido/económico + evaluación humana |
| 7 | Estructuración del dictado en hallazgos | pendiente | Razonamiento alto |

**Criterio de asignación de modelo (optimización de costo):**

- **Razonamiento alto** (p. ej. Claude Opus / GPT high / Sonnet thinking en su nivel máximo): fases cuyo error es caro de deshacer — esquema de datos, contratos de adapter, prompts con red lines de seguridad. Son las fases 0, 4 y 7.
- **Estándar** (p. ej. Sonnet-tier / Composer): implementación sobre diseño ya decidido — vistas, Stimulus, CRUD. Fases 1, 2 y 5.
- **Rápido/económico** (p. ej. Composer / Haiku-tier): trabajo mecánico y determinista con criterios de aceptación cerrados — scripts, una gem, una vista más. Fases 3 y 6.
- Regla práctica: si una fase "estándar" se traba dos veces en lo mismo, se relanza con el tier superior en vez de insistir; reintentos fallidos cuestan más que el upgrade.

### 2.1 Flujo de trabajo de ejecución (decidido 2026-08-09)

**Branches.** Un branch por fase (`certificador/fase-0-modelo-datos`, `certificador/fase-1-exportable`, …), un PR chico y revisable por fase. El cierre de fase (bloque de este documento) se edita dentro del mismo PR. **Prerrequisito antes de la Fase 0:** aterrizar los cambios sin commitear que hoy están en `main` (~25 archivos), para que los branches de fase partan limpios.

**Prueba y deploy.** Local primero: tests Minitest de la fase + prueba manual en dev (la Fase 4 exige además una transcripción real end-to-end en dev). Fase verde → merge a `main` → deploy a producción con Kamal, el flujo existente. No se acumulan fases sin mergear: cada fase entra a `main` al cerrarse.

**Feature flag.** Gating mínimo Rails-native, sin gem: `ENV["CERTIFIER_MODULE_ENABLED"]` que (a) oculta la entrada de navegación y (b) protege los controladores del módulo con un `before_action` que devuelve 404. Permite mergear y deployar fases incompletas mientras usuarios reales (ingenieros/técnicos de Gonzalo) usan producción. La Fase 0 puede mergear sin flag: son migraciones aditivas sin superficie visible. El flag se retira cuando el módulo se libere a un certificador real.

**Rutas.** Path nuevo, recurso REST plano siguiendo el patrón existente (`resources :field_photos`): `resources :certification_reports` con member `get :export` (Fases 1–2), y `resources :voice_dictations, only: %i[create show]` (Fases 4–5). Nada anidado bajo el chat ni bajo `/rag`.

**UI: sección propia, no el chat.** El módulo es un editor de documento (lista + borrador), no una conversación: reutiliza el layout/shell de la app (navegación, Tailwind, i18n) pero con vistas y controladores Stimulus propios. No se monta sobre `rag_chat_controller` ni sobre `ConversationSession` (regla fija 6). El chat queda intacto para el flujo mantenedor.

**Mockup de diseño (insumo opcional de la Fase 2).** Si se quiere un borrador visual antes de implementar el editor: pedir un **mockup HTML estático + Tailwind** (sin framework, casi copy-paste a ERB) a un modelo fuerte, o usar herramientas tipo v0.app **solo como referencia visual** — generan React/shadcn, que no es el stack (ERB + Stimulus + importmap); de ahí solo transfieren las clases Tailwind y el layout. Brief fijo: mobile-first, tap targets grandes (guantes), alto contraste (poca luz), mínimo tipeo, sin estado SPA. El exportable de la Fase 1 no necesita mockup: su diseño es el PDF de referencia de la sección 3.1.

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
Estructuración → hallazgo en ítem CENTRAVE (Fase 7; Bedrock Haiku default, LLM configurable)
  ▼
CertificationReport (borrador persistente, Fase 0) ──► pausar / retomar / revisar
  │ certificador asigna casilla / punto / gravedad (opcional, Fase 2)
  ▼
Exportable HTML print (Fase 1) ──► PDF server-side (Fase 3, condicionada)
                    [marca de agua BORRADOR]
```

Patrones existentes que se reutilizan (informe de arquitectura, 2026-08-09): tenancy por host (`AccountHostResolver` + `current_account`), fotos vía `FieldPhoto` + S3 con `sha256` único por cuenta (no Active Storage, nunca bajo `bulk_chunks/`), jobs idempotentes con `rescue RecordNotUnique → find`, servicios PORO con inyección `client:` para tests (sin WebMock), broadcast por `KbSyncChannel`-style, locales pareados `certifier.es.yml`/`certifier.en.yml` siguiendo el patrón `rag.*`.

---

## Fase 0 — Modelo de datos del borrador persistente

**Modelo recomendado:** razonamiento alto. El esquema es lo más caro de rehacer; todo lo demás se apoya en él.
**Depende de:** nada. **Bloquea a:** todas las demás.

**Insumos:** secciones 0, 3 y 5 de este documento; flujo de trabajo de la sección 2.1 (branch `certificador/fase-0-modelo-datos`; **verificar antes que `main` esté limpio** — prerrequisito 2.1); `app/models/field_photo.rb` y `app/models/conversation_session.rb` como referencia de estilo; `db/schema.rb`.

**Alcance:**

- `CertificationReport`: `account_id` (NOT NULL, indexado), `user_id`, estado (`en_progreso` / `listo_revision` / `enviado`), datos del edificio (nombre, comuna, calle, número, destino, **fecha de recepción municipal definitiva**), datos de identificación del informe (N° interno, fecha inspección), empresa mantenedora y técnico mantenedor (texto libre), timestamps.
- `ReportEquipment` (un informe cubre 1..n equipos, como el informe real que cubre 6): identificador del equipo (A, B, …), tipo (eléctrico/hidráulico), con/sin sala de máquinas, N° paradas, velocidad, carga útil, capacidad, tipo de puertas, N° embarques. Todos los campos técnicos opcionales — regla fija 4: no se obliga a llenar nada durante la inspección.
- `InspectionFinding`: `certification_report_id`, `report_equipment_id` (nullable — un hallazgo puede ser general), `inspection_item` (enum/entero de los 8 ítems CENTRAVE, **nullable**: el dictado libre puede llegar sin clasificar), texto del hallazgo, transcripción original (para trazabilidad dictado→hallazgo), ubicación (texto libre, no piso obligatorio — restricción de usabilidad de la entrevista), `field_photo_id` (nullable, reutiliza `FieldPhoto`), campos opcionales del certificador: `nch2840_box` (casilla), `norm_point` (punto), `severity` (enum `leve`/`grave`, **nullable, solo lo asigna el humano**), `position` para orden manual.
- `NormativeGroupResolver` (PORO en `app/services/`): fecha de recepción → grupo 1/2/3 → normas aplicables (tabla de la sección 3.1 del plan de septiembre: <24-10-2010 → NCh3395/1:2016 · NCh440/2:2001; 24-10-2010 a 28-02-2017 → NCh440/1:2000 · NCh440/2:2001; >01-03-2017 → NCh440/1:2014 · NCh440/2:2015). Determinista, sin LLM, con tests de bordes de fecha exactos.
- Constantes de los 8 ítems CENTRAVE con i18n (`certifier.es.yml` / `certifier.en.yml`).
- Seeds/fixtures de un informe de ejemplo realista (basado en la evidencia de la sección 3.1) para que la Fase 1 pueda renderizar sin UI.

**No incluye:** UI, voz, export, catálogo de casillas NCh 2840.

**Criterios de aceptación:** migraciones reversibles; unique/índices coherentes con tenancy; tests Minitest de modelo + resolver (incluyendo los tres bordes de fecha); `ConversationSession` intacto; fixtures del informe de ejemplo cargan.

### Cierre de fase (lo llena el ejecutor)
- Estado: pendiente
- Hallazgos:
- Desviaciones del plan:
- Actualizaciones aplicadas a fases siguientes:

---

## Fase 1 — Exportable HTML con hoja de impresión

**Modelo recomendado:** estándar. Render determinista sobre datos conocidos.
**Depende de:** Fase 0. **Bloquea a:** Fase 3.

**Insumos:** PDF de evidencia (sección 3.1) como plantilla visual; seeds de la Fase 0; `app/views/AGENTS.md` (Tailwind, mobile-first); ruta y flag según sección 2.1 (member `get :export`, guard `CERTIFIER_MODULE_ENABLED` desde esta fase, que es la primera con superficie visible). *(Actualizar con hallazgos de Fase 0.)*

**Alcance:**

- Vista `certification_reports/:id/export` (HTML + CSS de impresión `@media print`), replicando la estructura del informe real: encabezado de identificación, tabla de defectos graves, resultado **(sección que Danebo deja en blanco o con lo que el certificador haya marcado — Danebo no aprueba ni rechaza)**, tabla de defectos leves, hallazgos agrupados por ítem CENTRAVE con foto miniatura, norma aplicable derivada (rotulada "norma aplicable según fecha de recepción — ayuda documental").
- **Marca de agua BORRADOR** en toda página, no removible por CSS de impresión.
- Sin gem nueva, sin costo de servidor: el certificador imprime/guarda como PDF desde el dispositivo.
- Tailwind print utilities (`print:`) donde alcance; hoja dedicada si no.

**Criterios de aceptación:** el informe de ejemplo de seeds rinde las secciones en el orden del informe real; marca BORRADOR presente en todas las páginas al imprimir; fotos con presigned URL (`FieldPhotoUrlService`); test de controlador (autorización cross-account: 404 para cuenta ajena) + test de vista mínimo.

### Cierre de fase (lo llena el ejecutor)
- Estado: pendiente
- Hallazgos:
- Desviaciones del plan:
- Actualizaciones aplicadas a fases siguientes:

---

## Fase 2 — Lista "mis informes" + editor del borrador

**Modelo recomendado:** estándar.
**Depende de:** Fase 0 (y usa la vista de Fase 1 como destino de "exportar").

**Insumos:** `app/javascript/AGENTS.md` y `app/views/AGENTS.md`; rutas y flag según sección 2.1 (`resources :certification_reports`, `CERTIFIER_MODULE_ENABLED`); mockup HTML+Tailwind opcional (sección 2.1). *(Actualizar con hallazgos de Fases 0–1.)*

**Alcance:**

- Lista mínima "mis informes": solo borradores propios del certificador, orden por fecha, botón retomar. **No** un browser genérico de conversaciones (excepción acotada del plan de septiembre, sección 3.1).
- Crear informe (datos de edificio mínimos + fecha de recepción → muestra norma derivada), agregar/editar/reordenar/borrar hallazgos, asignar ítem CENTRAVE, adjuntar foto (reutilizando el flujo `FieldPhoto`), asignar casilla/punto/gravedad manualmente, cambiar estado del informe.
- Mobile-first: tap targets grandes, mínimo tipeo, alto contraste (guantes, poca luz). Hotwire/Turbo, sin estado SPA.
- El editor debe funcionar **sin** voz: texto tecleado es el fallback permanente y lo que se prueba primero.

**Criterios de aceptación:** un usuario crea un informe, agrega 3 hallazgos con foto, cierra sesión, vuelve y lo encuentra intacto (criterio de éxito #1 del plan de septiembre, versión sin voz); scoping por cuenta testeado; tests de controlador; sin N+1 en la lista (includes de counts/fotos).

### Cierre de fase (lo llena el ejecutor)
- Estado: pendiente
- Hallazgos:
- Desviaciones del plan:
- Actualizaciones aplicadas a fases siguientes:

---

## Fase 3 — PDF server-side (condicionada)

**Modelo recomendado:** rápido/económico. Trabajo de una tarde con criterios cerrados.
**Depende de:** Fase 1. **Condición de activación:** un certificador real (o la demo con TAQUIÓN-CERT) pide un archivo adjuntable a la Carpeta Cero, **o** la validación de formato de la Fase 1 quedó aprobada y sobra capacidad. No se activa antes.

**Insumos:** vista de la Fase 1. *(Actualizar con hallazgos de Fases 1–2.)*

**Alcance:** gem `grover` o `ferrum` (headless Chrome) rendereando la misma vista HTML de la Fase 1 → botón "Descargar PDF". Nota de deploy: Chrome/Chromium en la imagen de producción — documentar el costo operativo antes de mergear. La marca BORRADOR persiste.

**Criterios de aceptación:** PDF binario válido generado desde el informe de ejemplo; test que verifica header `%PDF` y páginas > 0; sin regresión en la vista HTML.

### Cierre de fase (lo llena el ejecutor)
- Estado: condicionada — no ejecutar sin la condición de activación
- Hallazgos:
- Desviaciones del plan:
- Actualizaciones aplicadas a fases siguientes:

---

## Fase 4 — Capa de transcripción agnóstica al proveedor

**Modelo recomendado:** razonamiento alto para el contrato del adapter y el esquema de telemetría; la implementación de cada adapter es estándar.
**Depende de:** Fase 0 (destino del dictado). **Bloquea a:** Fases 5, 6, 7.

**Insumos:** sección 4 (costos y proveedores); patrón `FieldPhoto` (S3 + job + fila durable); patrón de inyección `client:`; `ClaudeChunkingClient` como referencia de cliente HTTP a API externa. *(Actualizar con hallazgos de Fase 0.)*

**Alcance:**

- Contrato único: `SpeechToText::Client.for(provider)` → `#transcribe(s3_key:, language:)` → `Result` (texto, duración en segundos, proveedor, metadata cruda). Proveedor por `ENV["STT_PROVIDER"]`, con override por llamada (lo necesita el benchmark de la Fase 6).
- Adapters iniciales: **`AmazonTranscribeAdapter`** (gem `aws-sdk-transcribeservice`, batch, `es-CL`, reutilizando `AwsClientInitializer`) y **`OpenAiAdapter`** (`gpt-4o-mini-transcribe`, HTTP directo sin gem nueva, siguiendo el estilo de `ClaudeChunkingClient`). `GroqAdapter` es opcional en esta fase — la API es Whisper-compatible y puede caer en Fase 6 si el contrato quedó bien hecho; si el ejecutor lo agrega aquí, son ~30 líneas.
- Modelo `VoiceDictation`: `account_id`, `user_id`, `certification_report_id` (nullable), `s3_key_audio` (prefijo `voice_dictations/<account_id>/...`, **fuera de `bulk_chunks/`**), `sha256` (unique por cuenta), `duration_seconds`, `provider`, `status` (`pending`/`transcribed`/`failed`), `transcript_raw`, `transcript_edited`, `cost_estimate_usd`. **Telemetría propia — no toca `bedrock_queries`** (regla fija 7). Costo estimado = duración × tarifa del proveedor (tabla de tarifas en constante versionada).
- `TranscriptionJob` (Solid Queue): idempotente (`sha256` + `rescue RecordNotUnique`), `retry_on` acotado, broadcast del resultado al canal del usuario (patrón `KbSyncBroadcaster.photo_analyzed`).
- Retención de audio: job recurrente de purga (patrón `FieldPhotoRetentionJob`) — el audio crudo no es el artefacto, el texto editado sí.

**No incluye:** UI de captura (Fase 5), streaming en tiempo real (no lo necesita el dictado batch; queda en backlog), estructuración LLM (Fase 7).

**Criterios de aceptación:** ambos adapters pasan tests con fakes inyectados (sin WebMock, estilo del repo); job idempotente testeado (doble perform → una fila); un audio de prueba real transcrito end-to-end en dev con ambos proveedores; `cost_estimate_usd` poblado; documentado en el cierre cuánto costó la prueba.

### Cierre de fase (lo llena el ejecutor)
- Estado: pendiente
- Hallazgos:
- Desviaciones del plan:
- Actualizaciones aplicadas a fases siguientes:

---

## Fase 5 — UI de captura de audio (dictado)

**Modelo recomendado:** estándar.
**Depende de:** Fases 2 y 4.

**Insumos:** gate de transcripción visible/editable (regla fija 3); `app/javascript/AGENTS.md`. *(Actualizar con hallazgos de Fases 2 y 4.)*

**Alcance:**

- Controlador Stimulus nuevo (no extender `rag_chat_controller`): `MediaRecorder` + `getUserMedia`, botón grande grabar/parar (guantes), indicador de nivel/duración, **blob local hasta confirmar upload** — semilla de la decisión de conectividad de septiembre: si el upload falla, el blob no se pierde y se reintenta; la decisión formal de sincronización diferida sigue siendo de septiembre (sección 6.1 del plan de septiembre), esta fase solo no la bloquea.
- Flujo: grabar → subir → estado "transcribiendo…" (broadcast) → **panel de transcripción editable** → confirmar → se crea el hallazgo (o el texto queda listo para la estructuración de la Fase 7).
- Un dictado por hallazgo como caso base; dictado largo multiitem queda para la Fase 7.

**Criterios de aceptación:** dictar → editar transcripción → confirmar → hallazgo en el borrador, en móvil real; nada entra al borrador sin pasar por el panel editable; funciona el fallback de texto tecleado; test de sistema mínimo (o test de controlador + test JS si el repo no usa system tests aquí — verificar patrón en `test/system/`).

### Cierre de fase (lo llena el ejecutor)
- Estado: pendiente
- Hallazgos:
- Desviaciones del plan:
- Actualizaciones aplicadas a fases siguientes:

---

## Fase 6 — Benchmark de costo/calidad STT + COGS de voz

**Modelo recomendado:** rápido/económico para el script; la evaluación de la tasa de error sobre jerga la revisa el fundador (juicio de dominio, no se delega al modelo).
**Depende de:** Fase 4. Puede correr en paralelo con la 5. Es el adelanto de la sección 5.1 del plan de septiembre.

**Insumos:** protocolo del plan de septiembre 5.1: cinco dictados simulados con ruido de fondo real + veinte frases técnicas representativas (códigos KM, marcas, códigos de falla tipo A32.4), en español chileno. *(Actualizar con hallazgos de Fase 4.)*

**Alcance:**

- Script/rake reproducible: mismo set de audios → todos los adapters disponibles (Transcribe, OpenAI mini, y Groq si existe; agregar `GroqAdapter` aquí si no cayó en Fase 4) → tabla comparativa: costo real por minuto (facturado, no estimado, cuando el proveedor lo exponga), latencia de batch, y transcripciones lado a lado para conteo manual de errores sobre las 20 frases técnicas.
- Registrar resultados **en este documento** (tabla en el cierre de esta fase) y actualizar la recomendación de `STT_PROVIDER` default en la sección 4.
- Salida esperada: costo por dictado de 15–20 min por proveedor + tasa de error sobre jerga → insumo directo de la decisión de precio por informe (sección 6.2 del plan de septiembre).

**Criterios de aceptación:** tabla completa con al menos 3 proveedores; decisión de default tomada y escrita; costo total del benchmark documentado (debería ser < USD 2).

### Cierre de fase (lo llena el ejecutor)
- Estado: pendiente
- Hallazgos / tabla de resultados:
- Decisión de proveedor default:
- Actualizaciones aplicadas a fases siguientes:

---

## Fase 7 — Estructuración del dictado en hallazgos

**Modelo recomendado:** razonamiento alto. Toca prompts con red lines de seguridad y el costo por informe.
**Depende de:** Fases 4 y 5 (y de la evidencia de la 6).

**Insumos:** `app/prompts/AGENTS.md` (prompts compactos, determinista antes que LLM); reglas fijas 1 y 4. *(Actualizar con hallazgos de Fases 4–6.)*

**Alcance:**

- Servicio que toma la transcripción **confirmada** de un dictado largo y propone: segmentación en hallazgos, ítem CENTRAVE sugerido por hallazgo, ubicación si fue dictada. **Nunca** propone gravedad ni casilla de norma ni juicio de cumplimiento — esos campos quedan vacíos para el certificador (regla fija 1).
- Determinista primero: si el certificador dictó marcadores explícitos ("ítem cabina:", "siguiente hallazgo"), se segmenta en Rails sin LLM. El LLM entra solo para dictado sin marcadores.
- LLM configurable como la capa STT: default Bedrock Haiku (`BEDROCK_MODEL_ID` existente); contrato de cliente inyectable que permita evaluar un proveedor económico (p. ej. Kimi K2.5, $0.60/M input — sección 4) sin tocar el servicio. Telemetría: esta llamada **sí** es una invocación de modelo de texto — decidir en ejecución si entra por `bedrock_queries` (si va por Bedrock) o por log estructurado (si es proveedor externo), siguiendo la regla de `AGENTS.md` raíz.
- Todo lo propuesto llega al borrador como **sugerencia editable**, nunca auto-confirmado.

**Criterios de aceptación:** dictado con marcadores se estructura sin ninguna llamada LLM (test determinista); dictado libre produce sugerencias con ítem CENTRAVE y sin gravedad/casilla; costo por estructuración registrado; tests con cliente fake.

### Cierre de fase (lo llena el ejecutor)
- Estado: pendiente
- Hallazgos:
- Desviaciones del plan:
- Actualizaciones aplicadas a fases siguientes:

---

## 6. Lo que este plan NO construye

- Evaluación de cumplimiento, clasificación automática de gravedad, resultado aprobado/rechazado automático — red line permanente.
- El Certificado de Conformidad (formulario MINVU, lo emite el certificador en el portal).
- Catálogo completo de ~370 casillas NCh 2840 como datos precargados (se revisita tras validación con certificador real).
- Streaming de voz en tiempo real y conversación hands-free del mantenedor (se apoya en la capa de la Fase 4 cuando toque; plan de septiembre sección 4).
- Decisión formal de conectividad offline (septiembre, sección 6.1) — la Fase 5 solo deja la semilla (blob local).
- Historial genérico de conversaciones y registro diagnóstico por equipo (backlog).

## 7. Relación con los cortes de septiembre

Si todo lo anterior avanza en agosto, el corte del 16 de septiembre deja de evaluar "¿el borrador está en pie?" y pasa a evaluar "¿el dictado end-to-end está en pie?", con la validación de formato ante TAQUIÓN-CERT como siguiente paso. La escalera de recorte del plan de septiembre (sección 2.1) sigue aplicando sobre lo que falte: exportable → 8 ítems completos → hands-free. Lo que **nunca** se recorta no cambia: borrador persistente y transcripción visible/editable.
