# Plan — Haiku Semantic Query Analysis (2026-09-24)

**Objetivo:** decidir, con evidencia, si un análisis semántico síncrono de Claude Haiku 4.5 puede reemplazar la frontera `common_noun?` sin reabrir contaminación conversacional, y a qué costo de latencia y tokens.

**Estado de este documento:** plan solamente. No hay implementación de `SemanticQueryAnalyzer` en este branch más allá de este archivo.

**Entrada:** baseline conversacional v4 en `dce25d080aaba1779898339206d7ec297bdbd3e7`. Código leído el 24-sep-2026 en `experiment/haiku-semantic-query-analysis`.

## 1. Baseline y branch

| Dato | Valor |
|---|---|
| Branch del baseline | `main` (al momento del commit, ahead de `origin/main` por 1) |
| Commit | `dce25d080aaba1779898339206d7ec297bdbd3e7` |
| Mensaje | `Fail closed when copying a technical referent from the active episode.` |
| Convención del repo | Frase imperativa, sin prefijo `feat(rag):`. El mensaje pedido se ajustó a esa convención. |
| Branch experimental | `experiment/haiku-semantic-query-analysis` |
| Convención de branches | Mixta (`rag/`, `docs/`, `pilot/`, `codex/`). No hay prefijo `experiment/`. Se usó el nombre pedido. |

Tests del baseline, antes del commit, con `env -u BUNDLE_PATH`:

```text
bin/rails test \
  test/services/rag/active_episode_turn_test.rb \
  test/models/conversation_session_test.rb \
  test/controllers/concerns/rag_query_concern_test.rb
```

Resultado: 294 runs, 1476 assertions, 0 failures, 0 errors, 22 skips.

Archivos del commit (7, +1211/−9):

- `app/models/conversation_session.rb`
- `app/services/rag/active_episode.rb`
- `app/services/rag/active_episode_turn.rb`
- `app/services/rag/technical_referent_resolver.rb` (nuevo)
- `test/controllers/concerns/rag_query_concern_test.rb`
- `test/models/conversation_session_test.rb`
- `test/services/rag/active_episode_turn_test.rb`

Fuera del commit, ajenos al fix conversacional, siguen sin stagear en el working tree:

- `docs/PLAN_PILOTO_ELEMONT_2026-09-24.md`
- `script/patch_elemont_chunk_p1_2_q123_2026-09-24.rb`
- `script/patch_elemont_chunk_p1_2_q4_2026-09-24.rb`
- `script/patch_elemont_designator_retrieval_2026-09-24.rb`
- `script/patch_elemont_random12_gaps_2026-09-24.rb`

## 2. Hallazgos de arranque

| # | Hallazgo | Evidencia |
|---|---|---|
| H1 | El turno de texto persiste el episodio antes de cualquier modelo. | `RagController#ask` llama `record_user_turn!` y después `execute_rag_query`. |
| H2 | Con el flag de episodio, la query efectiva es `episode_turn.composed` o el texto crudo. `FollowupQueryRewriter` no corre en ese camino. | `RagQueryConcern#execute_rag_query`, rama `episode_turn_owns_thread?`. |
| H3 | `QUERY_ROUTING_ENABLED` default `"false"`. `classify_query_intent` no corre en el camino de producción. | `QueryOrchestratorService.skip_routing?`, `config/deploy.yml.example`. |
| H4 | La generación de manuales es `retrieve_and_generate` con `BedrockClient::QUERY_MODEL_ID`. No hay un análisis estructurado previo al Retrieve. | `BedrockRagService#query`, `model_arn: @model_ref`. |
| H5 | `aws-sdk-bedrockruntime` 1.63.0 expone `converse` y `tool_config`. No expone `output_config`. | Grep del gem instalado: cero `output_config`. |
| H6 | Structured outputs de Bedrock para Haiku 4.5 existen en la API (GA 2026-02-04, `outputConfig.textFormat`). El SDK bloqueado es anterior a ese parámetro. | [Claude structured outputs](https://docs.aws.amazon.com/bedrock/latest/userguide/claude-messages-structured-outputs.html). |
| H7 | `Aws::Bedrock::Client#create_model_invocation_job` existe en `aws-sdk-bedrock` 1.65.0. Batch Converse está anunciado desde 2026-02-27. | Gem + [what's new](https://aws.amazon.com/about-aws/whats-new/2026/02/amazon-bedrock-batch-inference-supports-converse-api-format/). |
| H8 | El estado cabe en 2048 bytes. Un slot nuevo compite con `identifiers`. | `ActiveEpisode::MAX_BYTES`, `shrink_to_budget!`. |
| H9 | `common_noun?` es la única frontera componente/identidad para un complemento de una palabra junto a un modelo nuevo. | `TechnicalReferentResolver#identity_complement?` / `#common_noun?`. |
| H10 | `generation.txt` casi no guarda estado conversacional. Achicarlo no paga el Haiku previo. | Lectura de `app/prompts/bedrock/generation.txt` (152 líneas). Las reglas de episodio viven en Ruby. |
| H11 | La telemetría de interacción guarda un solo `latency_ms` total. No hay p50/p95 persistidos ni fases. | `RagController#emit_interaction_completed` → `PilotUsageLog`. |
| H12 | No hay k6, vegeta ni wrk en el repo. Sí hay runners de benchmark RAG. | `script/rag_quality_benchmark.rb`, `script/rag_seguridades_benchmark.rb`. |

## 3. Auditoría de uso actual de Haiku

Modelo de query configurado:

```text
BedrockClient::QUERY_MODEL_ID
  ENV BEDROCK_MODEL_ID
  || credentials :bedrock, :model_id
  || global.anthropic.claude-haiku-4-5-20251001-v1:0
```

Región de cliente: `AWS_REGION` || credentials || `us-east-1` (`config/initializers/bedrock.rb`). Deploy de ejemplo: `us-east-1` y el mismo model id global.

Precios ya codificados en `BedrockQuery::BEDROCK_PRICING`, por 1 000 tokens:

| model id | input | output |
|---|---|---|
| `global.anthropic.claude-haiku-4-5-20251001-v1:0` | 0.001 USD | 0.005 USD |
| `us.anthropic.claude-haiku-4-5-20251001-v1:0` | 0.0011 USD | 0.0055 USD |
| `claude-haiku-4-5-20251001-direct` (API Anthropic, ingesta) | 0.001 USD | 0.005 USD |

Esos números son $1 / $5 por millón en el perfil global, y el perfil `us.` lleva el +10% ya documentado en el repo. El experimento debe leer `pricing_for(QUERY_MODEL_ID)` en runtime. No hardcodear otro precio.

### Camino de la pregunta técnica (web)

| file | method | model | input | output | cuándo | vs Retrieve | sync |
|---|---|---|---|---|---|---|---|
| `app/controllers/rag_controller.rb` | `ask` | ninguno | texto del técnico | `episode_turn` persistido | siempre que hay pregunta | antes | sync, Ruby |
| `app/services/rag/active_episode_turn.rb` | `call` | ninguno | turno + episodio | decisión + `composed` | flag de episodio on | antes | sync |
| `app/services/query_orchestrator_service.rb` | `classify_query_intent` | Haiku vía `AiProvider` → `BedrockClient#generate_text` → `invoke_model` | prompt de tool name | `DATABASE_QUERY` / `KNOWLEDGE_BASE_QUERY` / `HYBRID_QUERY` | solo si `QUERY_ROUTING_ENABLED=true` y la cuenta tiene `data_sources` con `"db"` | antes de Retrieve | sync |
| `app/services/query_orchestrator_service.rb` | `synthesize_hybrid_answer` | mismo Haiku | dos respuestas ya generadas | prosa unificada | solo `HYBRID_QUERY` | después | sync, segunda inferencia |
| `app/services/bedrock_rag_service.rb` | `query` | mismo Haiku, `retrieve_and_generate` | pregunta + prompt + chunks | respuesta citada | camino generativo de manual | el Retrieve va dentro de la misma API | sync |
| `app/services/bedrock_rag_service.rb` | `document_identity_scope_result` | Retrieve, y si hay labels un `invoke_model` del mismo Haiku | chunks etiquetados + `generation.txt` | respuesta | flag `DOCUMENT_IDENTITY_SCOPE_ENABLED` y episodio con manufacturer o model conocido, y el scope etiquetó chunks | Retrieve primero; si el InvokeModel falla, cae a `retrieve_and_generate` | sync |
| `app/services/rag/structured_evidence_route.rb` | `execute` | Haiku vía `AiProvider` en el tramo generativo | evidencia ya recuperada | respuesta cerrada | intent determinístico que matchea | después de Retrieve | sync |
| `app/services/rag/context_evidence_route.rb` | `execute` | igual | evidencia | respuesta | preguntas de contexto de procedimiento | después de Retrieve | sync |

`classify_query_intent` no se puede reutilizar. Está apagado en deploy, clasifica herramienta (KB vs SQL), corre después de que el episodio ya se persistió, y su salida no es un referente. Encenderlo para este experimento cambiaría routing de cuentas con base de datos.

`retrieve_and_generate` no se puede reutilizar. Es la generación. Ve chunks y `generation.txt`. Pedirle además el JSON de la query mezcla el contrato de citas con el análisis y no evita el Retrieve.

### Fuera del camino de la pregunta

| file | method | model | cuándo | nota |
|---|---|---|---|---|
| `app/services/page_relevance_filter.rb` | filtro de página | `claude-haiku-4-5-20251001` vía API Anthropic directa | ingesta, página ambigua | no es Bedrock; no está en el request del técnico |
| `app/services/claude_chunking_client.rb` | parseo | Sonnet/Opus directos | ingesta | |
| `app/services/claude_batch_client.rb` | Message Batches de Anthropic | Sonnet/Opus | ingesta masiva | no es Bedrock Batch Inference |
| `app/services/field_photo_analysis_service.rb` | visión | modelo de foto, async | foto | otro request |
| `app/services/sql_generation_service.rb` | SQL | Haiku vía `AiProvider` | solo si el router eligió DB | apagado por default |

**Conclusión:** `SemanticQueryAnalyzer` agrega una inferencia nueva en el camino crítico. No hay una llamada previa al Retrieve que ya entienda referente, quiebre semántico o ambigüedad.

## 4. Opciones de arquitectura

### Candidata principal

```text
User turn
   |
   v
SemanticQueryAnalyzer (Haiku, Converse)
   |
   v
QueryAnalysis          # request-scoped, inmutable
   |
   +-------------------------+
   |                         |
   v                         v
ActiveEpisodeTurn      QueryOrchestrator
valida y persiste      en el experimento NO cambia retrieval
   |
   v
effective query (composed v4, o el texto crudo)
   |
   v
RAG existente
```

Haiku propone. Ruby decide. El orquestador recibe el mismo objeto para un uso posterior de routing. En P0–P4 ese objeto no altera `top_k`, filtros ni rerank.

### Opciones de secuencia

| | Secuencia | Consistencia | Latencia | Una clasificación | Fallo |
|---|---|---|---|---|---|
| A | analizar → `record_user_turn!(analysis:)` → orquestador | un UPDATE, el estado ya vio el análisis | el Haiku está en el camino, antes del Retrieve | sí, el objeto viaja al orquestador | timeout: el turno sigue con v4 y `analysis=nil` |
| B | persistir v4 → analizar → segundo UPDATE | dos writes; un retry puede pisar el episodio | igual de bloqueante, más queries | el orquestador puede no ver el análisis si lee antes del segundo write | el segundo write es otro punto de fallo |
| C | analizar en job después de responder | el usuario no espera | no mide el camino crítico | el orquestador de ese request no lo ve | útil solo para shadow de calidad, no para latencia |

**Recomendación: A para las variantes que pueden cambiar estado (conditional y always-on).** Un solo objeto `QueryAnalysis` por turno, creado antes de `record_user_turn!`, pasado a `ActiveEpisodeTurn` y al orquestador. Sin segundo UPDATE. Sin segunda clasificación.

Shadow (P1–P2) usa el mismo call site y el mismo timeout, y `ActiveEpisodeTurn` ignora el objeto. Así la latencia medida es la del camino real y la respuesta sigue siendo v4. Si el timeout vence, se loguea `analyzer_status=timeout` y el turno continúa. El analyzer no es punto único de falla.

No usar C como diseño de producción. Sí se puede usar un job solo si P1 muestra que el timeout propuesto no alcanza para no degradar al técnico; en ese caso shadow pasa a async y la latencia de camino se mide aparte, en el load test de P3.

## 5. Arquitectura experimental recomendada

1. PORO `Rag::SemanticQueryAnalyzer` junto a `BedrockClient`, no dentro del modelo.
2. Cliente: `Aws::BedrockRuntime::Client#converse` sobre `BedrockClient::QUERY_MODEL_ID`. Misma región que el resto (`us-east-1` en el deploy de ejemplo).
3. Contrato de salida: JSON schema chico. Ver sección 12 sobre el SDK.
4. `Rag::QueryAnalysis` es un `Data` inmutable. No escribe la base.
5. `ActiveEpisodeTurn` sigue siendo el único escritor de `active_episode`.
6. `TechnicalReferentResolver` y `common_noun?` siguen en el primer incremento. El analyzer corre al lado.
7. El orquestador acepta `query_analysis:` y no lo lee para routing hasta una fase explícita posterior a este plan.
8. Timeout duro en el cliente. Cero reintentos en el request. Un reintento duplica la latencia del técnico.
9. Temperature `0`. `maxTokens` 200. Sin chain-of-thought. Sin texto libre fuera del schema.

## 6. Contrato QueryAnalysis

Schema mínimo. Sin ontología. Sin confidence numérico.

```json
{
  "intent": "adjust_procedure",
  "query_kind": "procedural",
  "equipment": {
    "manufacturer": null,
    "model": null,
    "evidence": "unknown"
  },
  "referent": {
    "surface": null,
    "head": null,
    "modifier": null,
    "type": "unknown",
    "evidence": "unknown"
  },
  "semantic_break": false,
  "ambiguity": false
}
```

Enums cerrados:

```text
intent:      adjust_procedure | identity_fact | fault | other
query_kind:  procedural | identity | fault | other
type:        technical_component | equipment_identity | unknown
evidence:    explicit | semantic | unknown
```

`explicit` = el turno actual contiene el string. `semantic` = Haiku lo infiere del goal o de un fact guardado y el string no está en el turno. `unknown` = no afirma.

Campos que no entran: score, explicación, lista de candidatos, spans, embeddings, historial.

`intent` existe para no reanalizar la query en un routing futuro. En este experimento no cambia `RagRetrievalProfile`. Si P0 muestra que `intent` no discrimina nada que `query_kind` no discrimine, se elimina antes de P3.

Ruby descarta el objeto entero si falta una clave, si un enum es ajeno, o si `surface` / `head` / `modifier` / `model` / `manufacturer` no son substrings normalizados del turno actual o del goal guardado. Un nombre que no está en ese texto no se persiste. Eso impide que Haiku invente `MiniSpace` o `relé`.

## 7. Ownership de estado

Invariante: Haiku propone; `ActiveEpisodeTurn` dispone.

| Propuesta | Qué hace Ruby |
|---|---|
| `equipment.model` o `manufacturer` con `evidence=explicit` y el string está en el turno | Pasa por el extractor actual (`MODEL_VALUE_RE`, `MANUFACTURERS`). Si el extractor no lo acepta, no se persiste. Haiku no abre un segundo escritor de facts. |
| `equipment.evidence=semantic` | No se persiste. Un modelo heredado solo entra por el puente de identidad que v4 ya tiene. |
| `referent.type=technical_component`, `evidence=explicit`, head presente en el turno, sin modifier heredado | En shadow: solo log. En conditional/always, candidato a slot. No copia un complemento del goal por sí solo. |
| `referent.type=equipment_identity` | No se copia como objeto técnico. Si el turno además declara modelo, sigue el `context_break` actual cuando el resolver v4 ya lo marca. |
| `semantic_break=true` y el turno nombra un componente distinto del goal | `context_break` solo si v4 ya lo haría, o si en una fase posterior el golden set lo exige y el string del componente nuevo está en el turno. |
| `semantic_break=true` sin componente nuevo en el turno | Se ignora. Un quiebre sin evidencia en el texto no borra el goal. |
| `ambiguity=true` | No persiste referente. Mantiene el fallo cerrado de v4 (`rejected` o `context_break` según el resolver). |
| `type=unknown` o `evidence=unknown` | No persiste. El referente anterior, si existiera, no se renueva. |
| JSON inválido, timeout, 5xx, throttle | `analysis=nil`. Camino v4 completo. |

Prohibido:

```text
JSON de Haiku → update!(active_episode:)
```

### Slot de referente

`active_episode` hoy tiene facts `manufacturer`, `model`, `fault_code`. No tiene slot de componente. `goal.text` mezcla tarea, objeto y pregunta (`MAX_GOAL_CHARS = 300`). El historial sigue siendo transcript (`conversation_history`), con `correlation_id` y `ts`.

| Opción | Qué se guarda | Cuándo merece |
|---|---|---|
| 1. Referente completo (`surface`, `head`, `modifier`, `type`, `evidence`, `correlation_id`, `at`) | ~250–400 bytes encima de un episodio que ya recorta identifiers a 2048 | Solo si P0 muestra que el modifier heredado es estable y el budget aguanta |
| 2. `QueryAnalysis` solo en el request | Cero bytes de episodio | P0, P1, P2, y la variante shadow |
| 3. Subset mínimo | `head`, `type`, `evidence`, `correlation_id` | Primera persistencia, si P3 se aprueba |

**Recomendación para el experimento: opción 2 hasta cerrar P2. Opción 3 si P3 escribe estado.** `surface` se reconstruye del turno. `modifier` no se hereda desde Haiku: copiarlo es exactamente la contaminación que v4 cerró. `at` ya está en el fact pattern y puede esperar. Medir `JSON.generate(episode).bytesize` con el subset antes de subirlo; si `shrink_to_budget!` empieza a soltar identifiers, el slot no entra.

El resolver determinístico sigue decidiendo `resolved` / `rejected` / `context_break` / `not_applicable`. El slot no sustituye esa máquina en el primer incremento que persista.

## 8. `common_noun?` y heurísticas a jubilar

No se borran en el primer incremento.

Candidatas a retiro, solo si el desacuerdo medido lo justifica:

| Heurística | Función única | Archivo |
|---|---|---|
| `common_noun?` | una palabra de complemento, con modelo nuevo en el turno, ¿es pieza o nombre de equipo? | `technical_referent_resolver.rb` |
| `unreaffirmed_name?` | token con mayúscula no repetido en el turno = identidad | el mismo |
| `identity_complement?` | une el modelo nuevo con `common_noun?` | el mismo |

Se quedan, porque no clasifican componente vs equipo:

- ventana 4 h y últimos 3 turnos (`ConversationSession::EPISODE_WINDOW`, `EPISODE_MAX_USER_MESSAGES`);
- correlación única y provenance texto-goal == texto del antecedente;
- `identity_bridge?` (marca, código, designator, medición, “no lo sé”);
- coordinación (`y` / `o` de dos palabras de contenido);
- tope 442 caracteres (`FollowupQueryRewriter::MAX_COMPOSED_CHARS`);
- `pure_complement?` (solo cadena `de`/`del`; `en minispace` no se copia);
- acuerdo de número verbo/objeto.

Shadow compara, por correlation_id:

```text
ruby_status:     resolved | rejected | context_break | not_applicable
haiku_type:      technical_component | equipment_identity | unknown
disagreement:    none | ruby_resolved_haiku_identity | ruby_rejected_haiku_component |
                 ruby_break_haiku_same | schema_invalid | analyzer_failed
```

`ruby_resolved_haiku_identity` es el desacuerdo que más importa: v4 copió y Haiku dice que el complemento es identidad de equipo.

## 9. Shadow mode

Flag `shadow`. Haiku corre. `ActiveEpisodeTurn` no lee el resultado. La query efectiva es la de v4.

Log estructurado, un evento, sin el transcript completo y sin chunks:

```text
event=haiku_query_analysis_shadow
correlation_id
analyzer_status          ok | timeout | http_5xx | throttle | invalid_schema
ruby_status
ruby_composed_sha256     solo si composed cambió el texto; no el texto completo si supera 200 chars
goal_correlation_id
haiku_referent_type
haiku_evidence
haiku_semantic_break
haiku_ambiguity
disagreement
semantic_analysis_ms
haiku_input_tokens
haiku_output_tokens
haiku_cost_usd           pricing_for(QUERY_MODEL_ID)
```

El texto crudo del turno no va al log de aplicación si ya está en `conversation_history` bajo el mismo `correlation_id`. El evaluador offline une por ese id. No loguear fotos, tokens de sesión, ni el prompt completo.

## 10. Evaluación offline y batch

### Corpus

Armar un JSONL etiquetado a mano, chico, antes de cualquier batch:

| Fuente | Qué aporta |
|---|---|
| `test/services/rag/active_episode_turn_test.rb` | invariantes v4 ya congelados (anexo B, flows A/B, 442/443, coordinación, quiebre persistente, nombres de equipo) |
| probes nuevos, no como código de producción | `freno`, `relé`, `polea`, `eje`, `tubo`, `regulador`, `maxpro`, `nova`, `delta`, `mono`, `MiniSpace` |
| `script/fixtures/rag_quality_benchmark_corpus.json` y batteries de `test/services/rag/*qa_test.rb` | preguntas reales de manual, casi todas autocontenidas |
| logs de piloto | solo filas `interaction_completed` con `question_sha256`; el texto hay que reconstruirlo de sesiones autorizadas, no de un volcado ciego |

Clases de etiqueta, una por caso:

```text
SAFE_RESOLUTION     copiar el referente localizado es seguro
SAFE_REJECTION      no copiar es lo correcto
SEMANTIC_BREAK      el turno corta continuidad
IDENTITY_BRIDGE     marca, código, designator o medición mantiene el goal
UNKNOWN             fail-closed aceptable
CONTAMINATION       copiar sería inseguro
```

Métrica primaria: **tasa de contaminación semántica insegura**. Un caso `CONTAMINATION` que el sistema trata como `resolved` cuenta 1. Accuracy general no desempata.

Orden de lectura del reporte:

1. false-positive de arrastre semántico;
2. `semantic_break` incorrecto (borró un goal vigente, o no borró uno roto);
3. contaminación de identidad (modelo/marca heredados);
4. false-negative de referente (dejó de copiar un complemento seguro);
5. accuracy.

Fail-closed sigue ganando: un `SAFE_RESOLUTION` caído a `rejected` es peor que v4 en utilidad y mejor que una contaminación.

### Batch Bedrock (solo offline)

No usar batch en el request del técnico. El batch existente del repo es Anthropic Message Batches de ingesta (`ClaudeBatchClient`), otro producto.

Workflow:

```text
dataset JSONL local
  → JSONL Converse en S3
  → Aws::Bedrock::Client#create_model_invocation_job
  → S3 output
  → reporte local (no bulk_chunks/)
```

Input de cada línea (formato Converse, el que batch acepta desde 2026-02-27):

```json
{
  "recordId": "case-0042",
  "modelInput": {
    "system": [{ "text": "<analyzer system, el mismo de runtime>" }],
    "messages": [{ "role": "user", "content": [{ "text": "<turno + facts + goal, sin chunks>" }] }],
    "inferenceConfig": { "maxTokens": 200, "temperature": 0 }
  }
}
```

`recordId` es la correlación. El output de batch trae `recordId` + `modelOutput` o `error`. El reporte une por ese id. Líneas con error se reintentan en un segundo JSONL; no se reescribe el job entero.

Paths propuestos, fuera de `bulk_chunks/`:

```text
s3://<bucket-de-eval>/haiku-query-analysis/<fecha>/input/requests.jsonl
s3://<bucket-de-eval>/haiku-query-analysis/<fecha>/output/
```

El bucket de knowledge base no sirve: un objeto bajo el prefijo de ingesta puede indexarse. Usar un prefijo de evaluación o el bucket que ya usan los artefactos de Gate 9, y confirmar que no es data source de la KB.

IAM mínimo del job role:

```text
bedrock:CreateModelInvocationJob
bedrock:GetModelInvocationJob
bedrock:InvokeModel          sobre el inference profile y el foundation model
s3:PutObject                 en el prefijo input
s3:GetObject, s3:ListBucket  en input y output
```

`modelId`: el mismo `QUERY_MODEL_ID` global. Verificar en P0 que batch en `us-east-1` acepta el perfil `global.`. Si el job rechaza el perfil, parar y escalar; no cambiar el modelo de producción.

Costo: Bedrock batch suele ser 50% del on-demand en modelos soportados. **Eso hay que confirmarlo en la página de precios vigente para Haiku 4.5 global antes de lanzar el job.** Hasta confirmarlo, presupuestar on-demand.

Reanudación: `client_request_token` estable por hash del JSONL. Si el job está `InProgress` o `Submitted`, no crear otro. Guardar `job_arn` en un archivo local al lado del reporte.

Presupuesto de P0, propuesta a validar: un solo job, corpus ≤ 300 casos, tope de gasto 2 USD on-demand. Si el corpus crece, se para y se pide otro tope.

## 11. Variantes online

| | Qué corre | Qué cambia la respuesta |
|---|---|---|
| A baseline | v4. Cero Haiku previo. | nada; es `dce25d0` |
| B always-on | analyzer en todo turno de texto con pregunta, antes de `record_user_turn!` | en P4, solo si el exit de P3 se cumplió; hasta entonces el objeto se loguea y v4 responde |
| C conditional | analyzer solo si el gate determinístico marca ambigüedad | igual: no cambia respuesta hasta el exit de la fase anterior |

Gate condicional, candidatos leídos del resolver, **no reglas finales**. Se congelan después de ver los desacuerdos de P0:

- `identity_complement?` es true o está a un `common_noun?` de serlo (modelo nuevo + un solo token de complemento);
- `pure_complement?` es false y el goal sí tiene complemento `de`/`del`;
- `technical_nps` devuelve más de un sintagma;
- `expand` rechaza porque el sintagma actual ya trae modifier.

No llamar a Haiku en `not_applicable` (el turno no es `ajust*`) dentro de la variante C. Esos turnos siguen el compose legado y son la mayoría del tráfico de manual.

La variante B existe para medir el sobrecosto de llamar siempre. No es el default de rollout.

## 12. Structured output y el SDK

API disponible para Haiku 4.5: `outputConfig.textFormat.type = json_schema` en `converse` y en `invoke_model`. Documentación AWS, GA 2026-02-04. El perfil global está en la lista pública de perfiles que lo soportan.

SDK del repo: `aws-sdk-bedrockruntime` **1.63.0**. Tiene `converse` y `tool_config`. No tiene `output_config`. Un hash desconocido lo rechaza el cliente antes de llegar a AWS.

Prerrequisito de implementación, fase propia, antes de P1:

1. Subir `aws-sdk-bedrockruntime` a una versión que modele `output_config`.
2. Test de contrato: el client acepta el parámetro. Sin llamada de red en la suite.
3. Si el bump arrastra `aws-sdk-core` y rompe otros clientes, parar. Fallback de implementación: `tool_config` con `tool_choice` forzado al tool `query_analysis`, que 1.63.0 ya modela. Es peor (un tool-call envuelve el JSON y suma tokens) y solo se usa si el bump no es viable.
4. No parsear JSON “a mano” desde prosa como camino principal. Si el schema falla, es `invalid_schema` y cae a v4.

Temperature 0. `maxTokens` 200. Target de salida **< 150 tokens**. Medir en P0; si la mediana pasa de 150, achicar el schema antes de seguir.

## 13. Prompt del analyzer

System, fijo, cacheable si más adelante se mide que vale la pena. User, por turno:

```text
current_turn
goal.text            solo si hay goal no truncado, mismo correlation guardado
goal_correlation_id
facts                manufacturer, model, fault_code: status + value, sin historial
referent_slot        solo si la opción 3 ya existe; si no, omitir
```

No enviar: transcript, últimos mensajes que no sean el goal, chunks, `generation.txt`, corpus, fotos, session_id de Bedrock.

El system dice: devolver solo el schema; no inventar un string que no esté en `current_turn` o en `goal.text`; `equipment_identity` incluye nombres de modelo o producto aunque parezcan sustantivos; `technical_component` es una pieza o función (freno, relé, polea, eje) aunque el manual no la liste; si hay duda, `unknown` y `ambiguity=true`.

Esos ejemplos del system son ilustración para el modelo. No se copian a una lista Ruby.

Tope de input, propuesta a medir: 800 tokens. Si P0 pasa de eso, cortar `goal.text` al mismo `MAX_GOAL_CHARS` (300) que ya persiste el episodio.

## 14. Reducción del prompt de generación (P5, no ahora)

`generation.txt` no es el guardián del estado conversacional. Clasificación:

| Bloque | Líneas aprox. | Si QueryAnalysis funciona |
|---|---|---|
| Rol, idioma, tono | 1–14 | se queda; es formato para el técnico |
| Evidence contract, STRICT/GROUNDED, topología, LED, glosario NO/NC | 16–100 | **se queda**. Seguridad técnica y evidencia |
| Document identity, sibling model, versión | 82–106 | **se queda**. Es contaminación de evidencia, no de diálogo |
| Response selection, stop-work, no match, format | 108–151 | **se queda** en P5 salvo medición que muestre un párrafo redundante con el estado |

Lo que sí podría achicarse, en otra fase y con números, es el `session_context` que `SessionContextBuilder` inyecta, no el archivo de prompt. P5 compara:

```text
prompt actual + session_context actual
vs
prompt actual + session_context recortado a facts + referent validado
```

Medir tokens de input de `retrieve_and_generate` antes y después, con el mismo set de preguntas. Si el ahorro no cubre el costo del analyzer (sección 16), P5 no se hace. No editar `generation.txt` en este experimento.

## 15. Fallos

| Fallo | Comportamiento |
|---|---|
| timeout del cliente | `analysis=nil`, v4, log `timeout`. Sin retry. |
| 5xx, `ServiceUnavailable`, red | igual |
| throttling | igual. No hacer backoff dentro del request. |
| JSON que no cumple el schema o enums | igual, `invalid_schema` |
| Haiku propone un string ausente del turno y del goal | Ruby tira el objeto, log `rejected_span`. Cuenta como fallo de analyzer, no como estado. |
| Bedrock caído del todo | el turno de RAG ya falla hoy en `BedrockRagService`. El analyzer no agrega un modo degradado distinto: la pregunta sigue y falla donde ya falla. |

Excepción: no hay. Ni siquiera un `semantic_break` de Haiku se aplica si el objeto es inválido.

Timeout propuesto, a calibrar en P1 con p95 real: **800 ms**. Si el p95 de Haiku en P0 batch no predice la cola online, el load test de P3 fija el número antes de pilot shadow. Hasta medirlo, 800 ms es una propuesta, no un SLO.

## 16. Costo

Por request experimental, en el log de la sección 9 más los campos que `BedrockQuery` ya guarda para la generación:

```text
haiku_input_tokens
haiku_output_tokens
haiku_cost                 pricing_for(QUERY_MODEL_ID)
generation_input_tokens    fila bedrock_queries de ese correlation_id
generation_output_tokens
generation_cost
total_llm_cost
```

`retrieve_and_generate` hoy a menudo estima tokens (`token_source=estimated`). El reporte debe separar estimado vs contado y no presentar el estimado como factura. El analyzer, al ser `converse`/`invoke_model`, sí devuelve `usage`. Ese número es contado.

### Modelo de costo (hipótesis, no medición)

Precios del perfil global ya en el repo. Hipótesis de tamaño, a reemplazar por la mediana de P0:

```text
input  600 tokens × 0.001 / 1000 = 0.00060 USD
output 120 tokens × 0.005 / 1000 = 0.00060 USD
por análisis always-on             = 0.00120 USD
```

| tráfico | always-on / día | always-on / mes (30 d) |
|---|---|---|
| 100 queries | 0.12 USD | 3.60 USD |
| 1 000 | 1.20 USD | 36 USD |
| 10 000 | 12 USD | 360 USD |

Conditional = always-on × fracción de turnos que disparan el gate. Esa fracción no se inventa: P0 la cuenta sobre el corpus; P2 la cuenta sobre el piloto. Si la fracción es 10%, los números de arriba bajan un orden.

Batch, si el 50% se confirma: la evaluación de 300 casos sale ~0.18 USD con la hipótesis de arriba. El tope de 2 USD deja margen.

Estos cuadros se rehacen con tokens reales al cerrar P0. No son umbral de salida.

## 17. Latencia e instrumentación

Hoy:

```text
RagController started_at → interaction_completed.latency_ms   (total)
BedrockRagService log "retrieve_and_generate Nms"            (string, no percentil)
StructuredEvidenceRoute retrieval_ms + generation_ms         (solo esa ruta)
```

Agregar al mismo `PilotUsageLog` de `interaction_completed`, sin tabla nueva:

```text
semantic_analysis_ms   0 en baseline
episode_ms             record_user_turn!
orchestrator_ms        hasta el return del orquestador, menos retrieval y generation si se pueden separar
retrieval_ms           solo donde la ruta ya lo mide (structured, context, document identity)
generation_ms          bedrock_latency_ms del retrieve_and_generate, o el invoke_model de identidad
total_ms               el latency_ms actual
```

En `retrieve_and_generate` retrieval y generation son una sola API. No inventar un `retrieval_ms` ahí. Reportar `rag_ms` para esa ruta y reservar el split para las rutas que ya llaman `retrieve` aparte.

Reportar p50, p95, p99 y, donde la API sea stream, TTFT. `retrieve_and_generate` en el código actual no es stream (`retrieve_and_generate_with_retry` espera el body). TTFT de esa ruta es el mismo número que `rag_ms` hasta que exista stream. Medir TTFT solo del `converse` del analyzer si se usa `converse_stream`; con `converse` bloqueante, `semantic_analysis_ms` es el número.

Comparar A/B/C sobre el mismo set, no con promedios sueltos de días distintos.

Presupuesto de overhead, **propuesta**: p95 de `semantic_analysis_ms` ≤ 800 ms y p95 de `total_ms` ≤ p95 baseline + 800 ms en la variante que se quiera encender. Se confirma o se baja después del load test. No es un SLO de producto todavía.

## 18. Load test

No hay herramienta de carga en el repo. No agregar k6 como dependencia para este experimento.

Runner mínimo, hermano de `script/rag_quality_benchmark.rb`: N workers, cada uno llama el mismo entrypoint que el benchmark (orquestador o el concern, con Bedrock real), mezcla fija, concurrencia 1, 5, 10, 20.

Mezcla por oleada de 20:

```text
8  autocontenidas (not_applicable para el resolver)
4  elipsis segura ya cubierta por tests (resortes de la fijación)
2  puente de identidad (Fuji Yida, código, “no lo sé”)
4  complemento ambiguo (modelo nuevo + una palabra: freno, maxpro, nova, MiniSpace)
2  quiebre (componente explícito distinto)
```

Medir: tasa de error, throttling (`ThrottlingException` / 429), p95 de `semantic_analysis_ms`, p95 de `total_ms`.

Parar la oleada si throttling > 1% o si aparecen 5xx. El piloto no necesita 20 concurrentes para decidir; 20 es el techo del experimento, no un objetivo de capacidad.

Correr contra una cuenta de eval, no contra la KB de producción si el entorno de benchmark ya tiene una separación. Si no la tiene, el runner usa la misma KB que `rag_quality_benchmark.rb` y se declara así en el reporte.

## 19. Evaluación de calidad

La suite v4 permanece verde en todas las fases. Haiku no puede reabrir:

- modelo heredado después de una declaración explícita;
- coordinación pegada como un solo objeto;
- override de componente explícito;
- antecedente sin provenance (texto distinto al goal);
- ventana de últimos 3 y de 4 h;
- correlación ausente, duplicada o nula;
- expansión de 442 caracteres aceptada y de 443 rechazada sin truncar;
- corrección de marca con precedencia sobre la expansión;
- quiebre persistente (el goal viejo no vuelve en el turno siguiente).

Esos casos ya están en `active_episode_turn_test.rb`. La fase que conecte Haiku al estado agrega un test por cada uno con el analyzer stubbeado en el sentido que tentaría a romper el invariante (por ejemplo `semantic_break=false` cuando el turno es un componente nuevo). El stub no puede ganar.

Probes de golden, etiquetados en el JSONL, no hardcodeados en el resolver:

```text
freno relé polea eje tubo regulador
maxpro nova delta mono MiniSpace
```

Cada probe va en dos contextos mínimos: (1) turno con modelo nuevo explícito y complemento de una palabra; (2) elipsis `cómo se ajustan` sin modelo nuevo. La etiqueta humana dice `CONTAMINATION` o `SAFE_RESOLUTION` antes de ver la salida de Haiku.

Gate de seguridad del experimento, independiente del accuracy:

```text
unsafe_contamination = 0
```

sobre el golden etiquetado. Un solo caso `CONTAMINATION` resuelto como copia falla la fase.

## 20. Feature flags

Un solo enum. Combinaciones de tres booleanos (`ENABLED` + `SHADOW` + `CONDITIONAL`) permiten estados inválidos.

```text
HAIKU_QUERY_ANALYSIS_MODE=off|shadow|conditional|always
```

Default: `off`. Cualquier otro string es `off` y se loguea una vez.

| modo | llama Haiku | escribe estado distinto de v4 | cambia la query al RAG |
|---|---|---|---|
| off | no | no | no |
| shadow | sí, todo turno de texto | no | no |
| conditional | sí, solo gate | solo a partir de P3, y solo lo que la sección 7 permite | no en este plan |
| always | sí, todo turno de texto | igual que conditional | no en este plan |

`FIELD_COMPANION_EPISODE_ENABLED` sigue siendo el interruptor del episodio. Con el episodio apagado, el modo Haiku también queda en `off`: no hay estado que analizar contra un goal.

Patrón de código: un PORO `Rag::HaikuQueryAnalysisFlag` como `FieldCompanionEpisodeFlag`, testeado, sin leer el ENV en el medio del turno más de una vez.

## 21. Rollout y criterios de salida

No hay avance automático. Cada fase actualiza la tabla de estado de este archivo.

| Fase | Qué | Exit para abrir la siguiente |
|---|---|---|
| P0 | Corpus etiquetado + un job batch. Cero cambio de runtime. | `unsafe_contamination=0` en los casos que v4 ya resuelve bien. En el subset ambiguo (complemento de una palabra junto a modelo nuevo), Haiku acierta más casos `SAFE_RESOLUTION`+`CONTAMINATION` que `common_noun?`, sin ningún `CONTAMINATION` nuevo. Tokens medidos reemplazan la hipótesis de la sección 16. |
| P1 | Modo `shadow` en local, timeout puesto, v4 intacto. | Suite v4 verde. 100% de los fallos de analyzer caen a v4 en test (timeout, schema, string inventado). p95 local anotado. |
| P2 | `shadow` en el piloto, flag por entorno. | ≥ 200 turnos de texto o 14 días, lo que pase último. Contaminación insegura observada en el log = 0. Fracción de `disagreement` publicada. Costo/día real ≤ el cuadro rehecho en P0 para ese tráfico, con margen 2×. |
| P3 | `conditional` en piloto, todavía sin cambiar retrieval. El estado solo se aparta de v4 en el subset ambiguo, con la política de la sección 7. | Golden v4 sigue en 0 contaminaciones. p95 `total_ms` dentro del presupuesto de la sección 17 ya calibrado por el load test. Throttling de la oleada 10 concurrentes ≤ 1%. Fallback probado con el cliente stubbeado en producción vía un caso de test, no vía apagar AWS. |
| P4 | `always` solo como A/B de costo, misma política de estado que P3. | El costo incremental vs conditional no compra una baja medible de false-negatives en el subset ambiguo. Si no la compra, se vuelve a conditional y always queda descartado. |
| P5 | Recorte de `session_context`, no de `generation.txt`, solo si P3 o P4 quedó encendido. | Input tokens de generación bajan lo suficiente para cubrir ≥ el 50% del costo del analyzer en el mismo set. Si no, se revierte el recorte. |

Umbrales marcados como propuesta hasta tener la medición de P0/P3:

- timeout 800 ms;
- p95 agregado ≤ baseline + 800 ms;
- tope P0 de 2 USD;
- margen 2× sobre el costo/día modelado;
- 200 turnos o 14 días en P2.

`unsafe_contamination=0` no es propuesta. Es el gate.

## 22. Fases de implementación (cuando se autorice)

Ninguna de estas fases se ejecuta con este documento.

### P0 — sin runtime

| Archivo | Cambio |
|---|---|
| `script/fixtures/haiku_query_analysis_corpus.jsonl` | casos etiquetados, incluidos los probes |
| `script/haiku_query_analysis_batch.rb` | arma el JSONL Converse, sube a S3, crea el job, baja el output, escribe el reporte |
| `test/scripts/haiku_query_analysis_batch_test.rb` | formato de línea, `recordId`, resume por token, no toca `bulk_chunks/` |
| este documento | fila P0 de la tabla de estado, con job arn y hash del corpus |

### Prerrequisito SDK — antes de P1

| Archivo | Cambio |
|---|---|
| `Gemfile.lock` | bump de `aws-sdk-bedrockruntime` con `output_config` |
| `test/services/rag/semantic_query_analyzer_test.rb` | el client fake recibe `output_config` o, si el bump fracasa, `tool_config` |

### P1 — shadow local

| Archivo | Cambio |
|---|---|
| `app/services/rag/haiku_query_analysis_flag.rb` | enum `off/shadow/conditional/always` |
| `app/services/rag/query_analysis.rb` | `Data` + validación de spans y enums |
| `app/services/rag/semantic_query_analyzer.rb` | `converse`, timeout, sin retry, costo vía `pricing_for` |
| `app/services/bedrock_client.rb` | método `converse_json` o cliente dedicado; no reutilizar `generate_text` (temperature 0.7, max 2000, prosa) |
| `app/controllers/rag_controller.rb` | en `shadow`/`always`, llamar analyzer antes de `record_user_turn!` y pasar el objeto; el turno lo ignora |
| `app/controllers/concerns/rag_query_concern.rb` | aceptar `query_analysis:` y no usarlo para la query efectiva |
| tests de flag, schema inválido, timeout, string inventado, y un test de que `composed` no cambia en `shadow` |

### P3 — conditional, estado

| Archivo | Cambio |
|---|---|
| `app/services/rag/technical_referent_resolver.rb` | exponer el gate de ambigüedad sin borrar `common_noun?` |
| `app/services/rag/active_episode_turn.rb` | aplicar la tabla de la sección 7 solo en `conditional`/`always` |
| `app/services/rag/active_episode.rb` | slot mínimo de la opción 3, con sanitize y budget |
| tests v4 existentes | siguen igual con el flag `off` |
| tests nuevos | cada invariante de la sección 19 con analyzer hostil stubbeado |

`QueryOrchestratorService` no cambia de ruta en este plan. Recibe el objeto y lo ignora, para no analizar dos veces cuando una fase futura lo use.

## 23. Test plan (de la implementación futura)

- Flag: `off` default; string basura = `off`; episodio apagado fuerza `off`.
- Analyzer: schema válido; enum ajeno; span que no está en el turno ni en el goal; timeout; 5xx; throttle; usage → costo con el precio global del repo.
- Shadow: `record_user_turn!` produce el mismo `composed` y el mismo `active_episode` que v4, con analyzer devolviendo `equipment_identity` sobre un caso que v4 resuelve.
- Conditional apagado en `not_applicable`.
- 442 se acepta, 443 se rechaza, con analyzer pidiendo copiar igual.
- Corrección de marca gana a un `semantic_break=false`.
- Quiebre persistente: el turno siguiente no recupera el goal viejo aunque Haiku diga `semantic_break=false`.
- Suite actual de los tres archivos del baseline, más la suite de prompt (`test/prompts/bedrock_generation_prompt_test.rb`) para probar que P0–P4 no tocan `generation.txt`.
- Cero llamadas de red en tests. Client inyectado.

## 24. Riesgos

| Riesgo | Por qué importa | Mitigación en el plan |
|---|---|---|
| El analyzer agrega latencia fija a cada pregunta | el camino ya espera `retrieve_and_generate` | conditional; timeout; P4 solo si compra calidad |
| Haiku “resuelve” dudas copiando | es la contaminación que v4 cerró | Ruby exige el string en el turno o en el goal; gate de 0 contaminaciones |
| SDK sin `output_config` | la primera implementación puede parecer lista y no serializar el parámetro | bump explícito antes de P1 |
| Batch rechaza el inference profile `global.` | el corpus no se evalúa barato | parar P0; no cambiar `BEDROCK_MODEL_ID` |
| 2048 bytes | el slot empuja identifiers fuera | opción 2 hasta medir; opción 3 mínima |
| Ahorro de prompt inexistente | `generation.txt` no guarda el diálogo | P5 mira `session_context` y se cancela si no paga |
| Shadow síncrono degrada el piloto | aunque no cambie la respuesta, el timeout largo sí | 800 ms propuesto; si no entra, shadow pasa a job y la latencia se mide en el load test |
| Dos clasificaciones | costo doble | un objeto por turno, pasado al orquestador, no releído por un segundo Haiku |

## 25. Fuera de alcance

- LangGraph, agents, graph memory, memoria vectorial de diálogo, framework externo de estados.
- Ontología de componentes.
- Cambiar embeddings, `top_k`, reranker, `ContextProjection`, `DocumentIdentityScope`, modelo de generación.
- Borrar `common_noun?` en el primer incremento.
- Encender `QUERY_ROUTING_ENABLED` para reutilizar `classify_query_intent`.
- Batch en el request interactivo.
- Editar `generation.txt` en P0–P4.
- Tabla nueva.
- Commit de los scripts `patch_elemont_*` o del plan de piloto dentro de este trabajo.

## Estado

| Fase | Estado | Artefacto |
|---|---|---|
| Baseline v4 | cerrado | `dce25d080aaba1779898339206d7ec297bdbd3e7` en `main` |
| Branch experimental | abierto, sin código de analyzer | `experiment/haiku-semantic-query-analysis` |
| P0 batch | no empezado | — |
| P1 shadow local | no empezado | — |
| P2 pilot shadow | no empezado | — |
| P3 conditional | no empezado | — |
| P4 always-on A/B | no empezado | — |
| P5 prompt/context reduction | no empezado | — |

## Protocolo

1. Actualizar la fila de Estado al cerrar una fase.
2. Corregir el exit de la fase siguiente si la medición contradice un número marcado como propuesta.
3. `unsafe_contamination=0` no se relaja por accuracy ni por costo.
4. Si un hallazgo pide LangGraph, una tabla nueva, o un rewriter general, no se implementa: se anota y se escala.
