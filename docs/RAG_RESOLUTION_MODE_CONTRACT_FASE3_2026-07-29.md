# Fase 3 — Contrato del payload `resolution_mode` y política de telemetría/flag

**Fecha:** 2026-07-29.
**Alcance ejecutado:** fila «Contrato del payload `resolution_mode` + política de
telemetría/flag — Opus» de la tabla de asignación de modelos
(`~/.claude/plans/valida-este-plan-y-memoized-biscuit.md`, A10 §12), que cierra las
decisiones transversales de Fase 3 de
[RAG_PRECISION_V2_PLAN_2026-07-29.md](RAG_PRECISION_V2_PLAN_2026-07-29.md).
**Lo que este documento NO hace:** no implementa. Las tarjetas, el renderer, el CSS y los
locales son las filas Sonnet/Haiku de Fase 3. No toca `app/`, fixtures, S3/KB ni producción.
**Precedentes consumidos:**
[RAG_EVIDENCE_SELECTOR_FASE1_DESIGN_2026-07-29.md](RAG_EVIDENCE_SELECTOR_FASE1_DESIGN_2026-07-29.md)
(`Rag::EvidenceSelection` es la fuente de `resolution_mode`),
[RAG_SEGURIDADES_METADATA_BACKFILL_FASE2_DECISION_2026-07-29.md](RAG_SEGURIDADES_METADATA_BACKFILL_FASE2_DECISION_2026-07-29.md)
(`section_identity` poblado ⇒ `breadcrumb` tiene fuente durable),
[RAG_REGEX_AUDIT_FASE05_2026-07-29.md](RAG_REGEX_AUDIT_FASE05_2026-07-29.md).

---

## 1. Dos correcciones de hecho antes del contrato

El plan describe la situación actual con una precisión insuficiente en dos puntos, y ambos
cambian el diseño.

### C1 · El `content` completo no se transporta «solo cuando el flag está apagado»

Fase 3 punto 5 dice: «con el flag apagado, no enviar el contenido completo de las citas al
navegador». Medido: el arreglo completo con el `content` íntegro de cada chunk viaja
**siempre** (`bedrock/citation_processor.rb:87-96` lo inyecta;
`rag_controller.rb:74-91` lo serializa sin gate). Y con el flag **encendido** tampoco se
necesita: el único consumidor de `content` en todo el frontend es
`answer_presenter.js:68-70`, que lo trunca a **150 caracteres** para el `title=` de un
marcador `[n]`. `sources_renderer.js` no lo lee nunca (usa `metadata.canonical_name`,
`title`, `filename`, `page`, `matched_excerpt`).

Conclusión: el campo correcto no es «`content` gateado por flag» sino un
`tooltip_excerpt` acotado a 150 caracteres que solo viaja con el flag encendido. Se
elimina entre 10 y 50 KB por cita en **ambos** estados del flag sin cambiar un pixel de lo
renderizado.

### C2 · Quitar los marcadores en el backend tiene un orden obligatorio

El plan pide que «el backend entregue la respuesta ya limpia de marcadores». La regla que
hoy aplica el frontend no es «quitar todo `[n]`»: `answer_presenter.js:61` quita
**únicamente** los números que resuelven a una cita real, para que un `[24]` literal —un
borne, un pin— sobreviva. Estos manuales citan esquemas: la versión naíf del stripping
borraría datos técnicos de la respuesta.

Por tanto el backend debe hacer el stripping **con la lista de citas en mano y antes de
vaciarla**. Si primero se aplica el gate del flag (`citations: []`) y después se limpia el
texto, la información necesaria para distinguir marcador de borne ya no existe. Es un
requisito de orden, no de implementación, y por eso pertenece al contrato.

---

## 2. El contrato del payload

### 2.1 Forma

Todo lo nuevo vive bajo una sola clave `resolution`. Un solo objeto que versionar, un solo
objeto sobre el que ramificar en el frontend, y ninguna colisión con las claves actuales.

```json
{
  "answer": "LED SPM: SERIE PUERTAS CABINA – EXTERIORES.",
  "status": "success",
  "session_id": null,
  "correlation_id": "…",
  "citations": [],
  "resolution": {
    "contract_version": "resolution_v1",
    "mode": "direct",
    "needs_selection": false,
    "answered_relations": ["attribution"],
    "abstained_relations": [],
    "insufficient_reason": null,
    "facts": [
      {
        "identifier": "SPM",
        "relation": "attribution",
        "value": "SERIE PUERTAS CABINA – EXTERIORES",
        "card_id": "c1"
      }
    ],
    "evidence_cards": [
      {
        "id": "c1",
        "label": "HIDRA – TPR50",
        "breadcrumb": ["HIDRA – TPR50", "CARLOS SILVA", "SEGURIDADES 1.1-1"],
        "excerpt": "SPM | SERIE PUERTAS CABINA – EXTERIORES",
        "select_query": "¿a qué serie corresponde SPM?\nEn el modelo HIDRA – TPR50.",
        "page": null,
        "evidence_url": null
      }
    ]
  }
}
```

### 2.2 Campo por campo

| Campo | Tipo | Presencia | Depende del flag | Fuente |
|---|---|---|---|---|
| `resolution.contract_version` | String, enum abierto | siempre | no | constante |
| `resolution.mode` | `direct`·`ambiguous`·`insufficient`·`not_applicable` | siempre | no | `EvidenceSelection#mode` |
| `resolution.needs_selection` | Boolean | siempre | no | **exactamente** `mode == "ambiguous"` |
| `resolution.answered_relations` | Array\<String\>, enum cerrado | siempre (puede ser `[]`) | no | `EvidenceSelection#answered_relations` |
| `resolution.abstained_relations` | Array\<String\>, enum cerrado | siempre (puede ser `[]`) | no | `EvidenceSelection#abstained_relations` |
| `resolution.insufficient_reason` | String\|null, enum cerrado | `null` salvo `mode == "insufficient"` | no | rechazo dominante de `EvidenceSelection#rejections` |
| `resolution.facts` | Array\<Fact\> | siempre (puede ser `[]`) | no | render determinista / selector |
| `resolution.evidence_cards` | Array\<Card\> | siempre (puede ser `[]`) | **parcialmente** | `EvidenceSelection#contexts` |
| `card.id` | String | siempre | no | ordinal estable dentro de la respuesta |
| `card.label` | String | siempre | no | `EvidenceContext#label` |
| `card.breadcrumb` | Array\<String\>, específico→general | siempre | no | `board_key` → `section_identity` → `canonical_name` |
| `card.excerpt` | String, ≤ 200 car. | siempre | **no** | `EvidenceContext#evidence_excerpt` |
| `card.select_query` | String | solo si `needs_selection` | no | pregunta + selección de placa |
| `card.page` | Integer\|null | siempre presente | **sí**: `null` con flag apagado | `EvidenceContext#page_number` |
| `card.evidence_url` | String\|null | siempre presente | **sí**: `null` con flag apagado | `evidence_target` |
| `citations[]` | Array | siempre presente | **sí**: `[]` con flag apagado | `CitationProcessor` |
| `citations[].tooltip_excerpt` | String ≤ 150 car. | solo con flag encendido | sí | reemplaza a `content` (C1) |
| `citations[].content` | — | **eliminado del payload** | — | — |

`card.excerpt` viaja en ambos estados del flag por decisión explícita del plan: «la
evidencia breve de una tarjeta ambigua no se considera un bloque de citas: es el contenido
mínimo necesario para que el técnico pueda elegir el modelo correcto». La cota de 200
caracteres alinea con `EXCERPT_MAX_CHARS = 140` de `citation_processor.rb:134` dejando
margen para una fila de tabla completa, que es la forma real de la evidencia en este
manual.

**`insufficient_reason`, enum cerrado** — deriva de `Rejection#reason` del selector y es lo
que elige el copy; el texto libre nunca inventa la causa:

| Valor | Significado | Qué pide la respuesta |
|---|---|---|
| `model_required` | hay evidencia en ≥ 2 contextos pero la pregunta no nombra el modelo | el modelo o la placa |
| `identifier_not_in_evidence` | el código consultado no aparece en ningún cuerpo recuperado | confirmar el código |
| `relation_not_documented` | el identificador existe, la relación pedida no está escrita | nada: se declara la ausencia **acotada a esa relación** |
| `function_without_identifier` | modo inverso, la función aparece sin identificador asociado | la placa, para acotar |
| `no_candidate_retrieved` | nada pasó la etapa 1/2 | reformulación o documento |

Ninguno de estos valores autoriza una ausencia global. `relation_not_documented` es el que
sostiene el gate «abstención ante estados no documentados» para `tokibat_dl27_v2` y
`thyssen_serie_e_leds`: la respuesta afirma la atribución y niega **solo** el estado.

### 2.3 `resolution.mode` no es `generation_mode`

`generation_mode` ya existe, tiene consumidores (`rag_controller.rb:87`, telemetría, tests)
y significa **por qué carril salió la respuesta**. `resolution.mode` significa **qué tan
resuelta está la pregunta**. Son ortogonales y fundirlos es la clase de atajo que Fase 0.5
vino a eliminar. `generation_mode` permanece interno —no se agrega al JSON— y el mapeo es:

| `generation_mode` | `resolution.mode` |
|---|---|
| generativo con selector, 1 grupo | `direct` |
| generativo con selector, ≥ 2 grupos | `ambiguous` |
| generativo con selector, 0 grupos | `insufficient` |
| `deterministic_model_disambiguation` | `ambiguous` |
| `deterministic_render` (ledger verbatim) | `direct` |
| `deterministic_document_overview` | `not_applicable` |
| SQL, subida de imagen/documento, error | `not_applicable` |

`not_applicable` existe porque el frontend necesita distinguir «el selector dijo directo»
de «el selector no corrió». Sin ese valor, la ausencia de tarjetas es ambigua y la rama de
render se decide por adivinanza.

### 2.4 `needs_selection` queda amarrado

El plan lo especifica y es redundante con `mode`. Se conserva —es lo que el frontend lee
para decidir si pinta acciones— pero se define como **igualdad**, no como campo
independiente, y un test asserta `needs_selection == (mode == "ambiguous")` para las tres
cohortes. Un booleano derivable que puede divergir de su fuente es una fuente de bugs; uno
derivable con la igualdad probada, no.

### 2.5 Compatibilidad: `quick_replies` queda deprecado, no roto

`quick_replies` es hoy `[{label, query}]` (`ambiguous_model_responder.rb:69-74`) y
`rag_chat_controller.js:882` lo recorta a 3. Es exactamente `evidence_cards` sin evidencia.

Regla de migración: mientras `contract_version == "resolution_v1"`, el backend emite
**ambos** — `quick_replies` derivado de `evidence_cards` (`label` + `select_query`, primeros
3) y `evidence_cards` completo. El canal WhatsApp dormante y cualquier cliente viejo siguen
funcionando sin cambios. `quick_replies` se retira cuando el renderer de tarjetas sea el
único consumidor, en un `resolution_v2`. El tope de 3 pasa a ser exclusivamente visual: el
payload lleva **todos** los grupos supervivientes y el «Ver más contextos» del plan opera
sobre lo que ya está en el cliente.

---

## 3. Política del flag `SHOW_RAG_SOURCES`

### 3.1 Un solo lector, dos consumidores

Hoy el flag se lee en un único sitio y es el sitio equivocado:
`app/views/home/index.html.erb:21` (`ENV["SHOW_RAG_SOURCES"] == "true"`), es decir en la
**vista**, mientras la decisión que ahora hay que tomar es de **transporte** y ocurre en el
controlador. Leerlo dos veces en dos capas con dos expresiones es cómo se produce una
divergencia igual a la de `fuera de servicio` / `fuera\s+de\s+servicio` documentada en
Fase 0.5.

Decisión: un único lector server-side —`Rag::SourcesVisibility.enabled?`— consumido por el
controlador (para gatear el transporte) y por la vista (para gatear el render). El
`data-rag-chat-show-sources-value` sigue existiendo, pero deja de ser una segunda fuente:
pasa a ser el valor que el servidor ya resolvió.

Corolario: `formatAnswerForWeb(..., { showMarkers })` deja de ser necesario. Con el
stripping hecho en el backend (C2), mantener la rama cliente es tener dos implementaciones
de la misma regla. Se elimina.

### 3.2 Matriz: computa · transporta · muestra

| | Flag apagado | Flag encendido |
|---|---|---|
| Recuperación, selección de evidencia, agrupación, guardrails | idénticos | idénticos |
| `resolution.mode` / `needs_selection` / relaciones | se transporta | se transporta |
| `card.label`, `breadcrumb`, `excerpt`, `select_query` | se transporta | se transporta |
| `card.page`, `card.evidence_url` | `null` | se transporta |
| `citations[]` | `[]` | se transporta, con `tooltip_excerpt` |
| `citations[].content` | nunca | nunca |
| Marcadores `[n]` en `answer` | eliminados en el backend, preservando los `[n]` que no resuelven a cita | presentes |
| Bloque de fuentes, página, deep link | no se renderiza | se renderiza |
| Telemetría exportada | idéntica salvo el campo `sources_visible` | idéntica salvo el campo `sources_visible` |

### 3.3 Invariantes probables

Cada una es una aserción, no una intención:

1. Con el mismo input, el conjunto de `chunk_sha256` seleccionados, `resolution.mode`,
   `answered_relations`, `abstained_relations` y el texto de `answer` **sin marcadores** son
   idénticos en ambos estados del flag.
2. Con el flag apagado, ninguna respuesta serializada contiene la clave `content`, ni un
   `page` no nulo, ni un `evidence_url` no nulo, ni un elemento en `citations`.
3. En ningún estado del flag el payload contiene `content`.
4. Una respuesta con `[24]` que no resuelve a cita conserva el `[24]` con el flag apagado
   (regresión directa de C2).
5. El evento de telemetría emitido en ambos estados difiere **únicamente** en
   `sources_visible`.

---

## 4. Política de telemetría

### 4.1 Ningún seam nuevo

Existen dos seams y ambos sirven; crear un tercero es lo que el plan quiere evitar.

| Carril | Seam | Ya parseado por |
|---|---|---|
| Generativo | `[RAG_QUALITY]` (`bedrock_rag_service.rb:653`) | `PilotMetricsReport#read_log_data:143` |
| Determinista / `Retrieve` interno | `[PILOT_USAGE]` (`PilotUsageLog`) | `PilotMetricsReport#read_log_data:141` |

Decisión: un evento nuevo `evidence_selection` sobre `PilotUsageLog`, emitido **por el
selector**, en los dos carriles. El carril generativo lo emite además de su
`[RAG_QUALITY]` actual, que no se modifica. Así la atribución de evidencia queda en un solo
formato para las rutas deterministas y las generativas, y el exportador diario ya lo
recoge sin cambios estructurales.

**Se mantiene la regla de coste:** un `Retrieve` puro **no** crea fila en `bedrock_queries`
(AGENTS.md «Internal `Retrieve` calls stay off `bedrock_queries`», Fase 3 punto 2). El
esquema de esa tabla no gana ninguna columna: no tiene ni una sola de evidencia
(`db/schema.rb:43-66`) y no debe tenerla en el MVP.

### 4.2 Campos del evento `evidence_selection`

Uno por respuesta, más un registro por contexto entregado.

| Campo | Por qué |
|---|---|
| `account_id`, `user_id`, `conversation_session_id`, `correlation_id` | atribución y multi-tenancy (Fase 3 punto 3) |
| `generation_mode` | carril |
| `resolution_mode`, `needs_selection` | el nuevo contrato, medible por sí mismo |
| `answered_relations`, `abstained_relations` | alimenta «abstención ante estados no documentados» |
| `insufficient_reason` | separa «no hay dato» de «falta el modelo» |
| `contexts_delivered`, `groups_total` | invariante `≤ 5` de Fase 1 §5, y el tope visual de 3 |
| `document_id`, `source_uri`, `page`, `chunk_sha256` | traza por afirmación (gate de trazabilidad) |
| `excerpt_sha256` + `excerpt` acotado a 200 car. | «extracto acotado y su hash» |
| `question_sha256`, `answer_sha256` | vínculo sin duplicar el texto (Fase 3 punto 3) |
| `selector_version` | versión del selector, exigida por Fase 3 punto 3 |
| `expansion_mechanism` | `section_identity` \| `adjacent_page_interim` \| `none` — **medir el andamiaje interino** de Fase 1 §7 etapa 5 para poder borrarlo |
| `rejection_reasons` | cuenta por razón; es el gate «ninguna ausencia falsa» |
| `sources_visible` | el único campo que puede diferir entre estados del flag |
| `ts` | lo añade `PilotUsageLog` |

`selector_version` y `expansion_mechanism` no son decoración: sin el primero, una corrida
no se puede atribuir a una versión del selector y las cinco corridas del gate dejan de ser
comparables; sin el segundo, el mecanismo interino de expansión se queda para siempre
porque nadie puede demostrar que ya no se usa.

### 4.3 `ALLOWED_FIELDS` descarta en silencio

`PilotUsageLog.log` hace `fields.slice(*ALLOWED_FIELDS)` (`pilot_usage_log.rb:20`): un
campo no declarado **desaparece sin warning**. Los ~16 nombres de §4.2 deben añadirse a
`ALLOWED_FIELDS`, y la implementación debe traer un test que emita el evento completo y
asserte que todas las claves sobreviven al `slice`. Sin ese test, el modo de fallo es
telemetría parcial que se lee como telemetría correcta — exactamente el defecto que el plan
denuncia en «un log de contenedor sin política de retención no es un registro auditable».

Cotas de `safe_value` a respetar al dimensionar: String → 500 caracteres, Array → 20
elementos de 120 caracteres. `excerpt` (200) y `rejection_reasons` caben; `breadcrumb` como
array cabe.

### 4.4 Qué no se registra, y retención

- **No** se persiste el `content` del chunk en ningún sitio: solo `chunk_sha256` y el
  extracto acotado con su hash. El chunk ya vive en S3; duplicarlo es el «repositorio de
  documentos duplicados» que Fase 3 punto 4 prohíbe.
- **No** se crea tabla de historial de evidencia, ni subsistema de gestión de evidencia, ni
  columna nueva en `bedrock_queries`.
- **La pregunta y la respuesta viajan solo como hash** en el evento nuevo. El
  `[RAG_QUALITY]` actual sigue registrando `question.first(300)` y `answer_snippet.first(600)`
  en claro; no se amplía ese alcance ni se replica en el evento nuevo.
- **El registro auditable es el artefacto del exportador diario**
  (`script/pilot_metrics_export.rb`), no el log del contenedor. La retención debe declararse
  en el propio reporte —período cubierto, método, muestra— porque el plan ya condiciona la
  presentación de métricas a que eso esté registrado en el mismo reporte.

### 4.5 Cómo alimenta los cuatro grupos del plan

| Grupo | Qué aporta este evento |
|---|---|
| Calidad y confianza | `resolution_mode` da directas/ambiguas/insuficientes; `abstained_relations` da abstención; `rejection_reasons` da ausencias falsas; `excerpt_sha256` da tasa de respuestas con evidencia real, no «tiene cita» |
| Adopción | nada nuevo: sigue viniendo de `ConversationSession` |
| Operación y economía | `contexts_delivered` es el proxy directo de tokens de contexto; `generation_mode` separa deterministas de LLM |
| Resultados comerciales | nada: siguen siendo `REQUIRES_MANUAL_SURVEY` |

La regla del plan se mantiene intacta: la presencia de una cita no demuestra corrección.
`evidence_present` deja de significar «hay citas» y pasa a significar «hay un extracto que
responde la relación pedida», que es lo que `answered_relations` no vacío certifica.

---

## 5. Invariantes de gate que este contrato hace testables

Traducción de los gates de §6 del plan a aserciones sobre el contrato:

1. «100% de opciones ambiguas respaldadas por un extracto que responde la consulta» →
   toda `evidence_card` tiene `excerpt` no vacío y su `id` aparece en algún `fact` o su
   contexto declara la relación cubierta.
2. «100% de afirmaciones técnicas asociadas a una traza persistida con documento, página y
   chunk» → cada `fact` referencia un `card_id`, y el evento lleva
   `document_id`/`page`/`chunk_sha256` para ese contexto.
3. «El flag apagado no muestra ni transporta citas completas y no modifica el resultado
   técnico» → §3.3, invariantes 1–3.
4. «Ninguna respuesta de ausencia cuando el dato existe en un chunk candidato» →
   `mode == "insufficient"` exige `rejection_reasons` no vacío.
5. «Costo medio sin segunda llamada LLM en consultas directas» → `mode == "direct"` con un
   solo `generation_mode` por `correlation_id`.
6. Tope visual sin pérdida de payload → `evidence_cards.size >= groups_total` cuando
   `groups_total <= 5`, y `quick_replies.size <= 3`.

---

## 6. Correcciones que este documento impone

**Al plan** ([RAG_PRECISION_V2_PLAN_2026-07-29.md](RAG_PRECISION_V2_PLAN_2026-07-29.md)):

1. **Fase 3, «Situación actual a corregir», primer bullet** — el `content` completo viaja
   en ambos estados del flag, no solo con el flag apagado, y con el flag encendido tampoco
   se necesita: su único uso es un tooltip de 150 caracteres (C1).
2. **Fase 3 punto 5** — el stripping de marcadores en el backend debe preservar los `[n]`
   que no resuelven a una cita y por tanto debe ejecutarse **antes** de vaciar `citations`
   (C2). Sin ese orden, se borran bornes y pines de la respuesta.
3. **Fase 3, payload** — `resolution_mode` necesita un cuarto valor, `not_applicable`, para
   las rutas que no pasan por el selector (§2.3); y `needs_selection` se define como
   igualdad con `mode == "ambiguous"`, no como campo independiente (§2.4).
4. **Fase 3, tarjetas** — el payload conserva todos los grupos y `quick_replies` queda
   deprecado pero emitido durante `resolution_v1` (§2.5).
5. **Fase 3, telemetría** — los campos `selector_version` y `expansion_mechanism` son
   obligatorios, el segundo porque es la única forma de retirar el andamiaje interino de
   Fase 1; y `ALLOWED_FIELDS` descarta en silencio, así que la ampliación de esa constante
   es parte del contrato, con test (§4.3).
6. **§3.5 y Fase 3, flag** — el flag se lee hoy en la vista; debe leerse una sola vez en el
   servidor y consumirse en las dos capas, y la rama `showMarkers` del frontend se elimina
   (§3.1).
7. **§8, archivos afectados** — añadir `app/javascript/rag/answer_presenter.js` (único
   consumidor de `content`) y el nuevo lector único del flag.

**Al diseño de Fase 1** ([RAG_EVIDENCE_SELECTOR_FASE1_DESIGN_2026-07-29.md](RAG_EVIDENCE_SELECTOR_FASE1_DESIGN_2026-07-29.md)):

8. **§6, `EvidenceSelection`** — `expansions` debe llevar el mecanismo en forma de enum
   cerrado (`section_identity` \| `adjacent_page_interim` \| `none`) para que sea agregable
   en telemetría, no una cadena libre.
9. **§6, `EvidenceContext`** — falta el campo que alimenta `card.evidence_url`; el
   `evidence_target` del «contrato mínimo de evidencia» de §4 del plan no está en el
   `Data.define`.

---

## 7. Handoff

**Fila Sonnet de Fase 3** (tarjetas, renderer, CSS, breadcrumbs): §2 es la especificación
cerrada del payload; §3.2 la matriz de transporte. No inventar campos: si algo falta, es una
corrección a este documento, no una adición local.

**Fila Haiku** (locales): las claves de copy se eligen por `insufficient_reason` y por
`abstained_relations`, ambos enums cerrados de §2.2. Un texto que declare una ausencia
global no corresponde a ningún valor del enum.

**Fase 6**: los seis invariantes de §5 y los cinco de §3.3 son los tests del contrato,
además de los nueve del selector que ya lista el diseño de Fase 1 §10.

**Orden sugerido:** lector único del flag y eliminación de `content` del payload (cambio
aislado, medible, sin dependencia del selector) → contrato `resolution` emitido con
`mode: "not_applicable"` en todas las rutas → conmutación por ruta a medida que el selector
de Fase 1 entra detrás de su feature flag.
