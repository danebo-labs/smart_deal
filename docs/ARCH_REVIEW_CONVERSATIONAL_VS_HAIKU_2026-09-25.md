# Revisión arquitectónica adversarial — conversación determinística vs Haiku

**Fecha:** 2026-09-25  
**Alcance:** análisis solamente; no propone cambios de runtime en esta revisión.  
**Baseline inspeccionado:** `04586d560121f2812f06161cacad350ed95b862c` (`experiment/haiku-semantic-query-analysis`), cuyo runtime conversacional corresponde a v4 en `dce25d0` más el plan experimental.  
**Modelo de query configurado:** `global.anthropic.claude-haiku-4-5-20251001-v1:0`.

## 1. Executive summary

La recomendación es **HYBRID_MINIMAL**: conservar a Ruby como dueño de estado, policy, provenance, seguridad y transiciones; introducir una sola percepción semántica Haiku para turnos donde la interpretación puede cambiar la relación entre equipo, componente, falla, procedimiento o medición; y retirar gradualmente las heurísticas semánticas abiertas cuando la evidencia de shadow/golden demuestre que Haiku las reemplaza sin contaminación.

v4 no es scaffolding descartable. Su arquitectura durable ya existe en:

- `ConversationSession` como límite tenant/session;
- `ActiveEpisode` como envelope versionado, acotado y fail-closed;
- `correlation_id`, provenance, ventana temporal y límites de composición;
- precedencia de correcciones, invalidación de identidad heredada, conflictos foto/usuario y persistencia atómica;
- separación entre estado declarado por el técnico y evidencia documental;
- policy Ruby que decide qué se persiste y qué llega a retrieval.

El problema no se cierra agregando únicamente `typed referent`. Eso mejora la representación de una decisión ya tomada, pero no resuelve la decisión open-world: si `freno`, `relé`, `polea`, `MaxPro`, `Nova`, una frase de ASR imperfecta o “el otro” denotan componente, equipo, corrección, cambio de episodio o respuesta a una pregunta anterior. `TechnicalReferentResolver` evidencia el límite: está especializado en `ajust*`, extrae sintagmas nominales con regex y termina usando fonotáctica aproximada en `common_noun?` para separar sustantivo común de nombre de producto.

Haiku sí compra una capacidad real: percepción semántica compartida para continuidad, referente, corrección, intent, observaciones y routing. No compra seguridad por sí mismo. No debe escribir DB, inventar facts, decidir una instrucción técnica ni reemplazar provenance, límites, evidencia RAG o policy. Si Haiku falla, el sistema debe conservar el turno crudo, no reutilizar estado dudoso y continuar por una ruta segura.

La variante recomendada para el siguiente incremento es **conditional**, pero con una definición estricta: el fast path sólo puede aceptar casos donde no se crea una relación semántica cross-turn. No debe existir un segundo clasificador Ruby intentando decidir “componente vs equipo” para decidir si llama a Haiku; eso recrearía Estrategia A delante de Estrategia B. En voz, referencias al asistente, mediciones, foto+texto y troubleshooting guiado, el analyzer será de facto frecuente y puede evolucionar a always-on por modo, no necesariamente para toda pregunta RAG autocontenida.

El costo del analyzer es aceptable. Con la hipótesis conservadora del plan previo —600 tokens de entrada y 120 de salida— cuesta **USD 0,0012 por análisis** con el modelo global a USD 1/MTok input y USD 5/MTok output. Esto agrega USD 1,20 por 1.000 consultas always-on. El costo es pequeño frente al costo conservador actual de generación, USD 9,25 por 1.000 consultas. El riesgo principal es latencia serial y duplicación de inferencias, no unit economics.

La migración correcta no es poner Haiku encima y conservar para siempre todos los regex. Es un strangler con frontera explícita: contrato request-scoped único, shadow, activación de un slice ambiguo, consumers compartidos y retiro por familias de heurísticas con tests de invariantes hostiles.

## 2. Estado actual

### 2.1 Flujo real del turno web

El camino observado es:

```text
RagController#ask
  → ConversationSession#record_user_turn!
      → ActiveEpisodeTurn.call
      → un UPDATE atómico de history + active_episode + expires_at
  → SessionContextBuilder.build
  → RagQueryConcern#execute_rag_query
      → episode_turn.composed || raw question
      → QueryOrchestratorService
          → rutas determinísticas
          → explicit Retrieve + generation en rutas selectivas
          → BedrockRagService#query / RetrieveAndGenerate como fallback general
  → ConversationSession#record_assistant_turn!
      → pending_fact derivado de la respuesta completa
```

Con `FieldCompanionTurnFlag`, el `episode_turn` es el único dueño de composición; `FollowupQueryRewriter` sólo queda como fallback para `no_episode`, `skipped` o ausencia de resultado. Esto ya creó dos generaciones de lógica conversacional que deben converger.

En el entorno inspeccionado, `QUERY_ROUTING_ENABLED=false`, `BEDROCK_RERANKER_ENABLED=false` y las dos flags del Field Companion están apagadas. Eso describe la configuración local, no una afirmación sobre todos los despliegues. El código y los tests de v4 sí están presentes.

### 2.2 Estado persistido

`ConversationSession` mantiene:

- `conversation_history`: máximo 20 mensajes, cada contenido truncado a 300 caracteres;
- `active_episode`: JSONB versionado, con presupuesto de 2.048 bytes;
- `active_entities`: pins de documentos, separado del estado del trabajo;
- `current_procedure`: columna existente pero sin contrato activo; fuera de `reset_procedure!` no tiene consumidores de runtime.

`ActiveEpisode` persiste hoy:

- identidad/lifecycle: `episode_id`, `status`, `opened_at`, `updated_at`, `opened_by`;
- `goal.text` con `correlation_id` y marca de truncamiento;
- facts tipados `manufacturer`, `model`, `fault_code`, con status, source, correlation y timestamp;
- identificadores literales;
- `pending_fact` limitado a esos tres facts;
- referencia de foto, facts leídos de foto y conflictos usuario/foto.

El payload inválido o expirado queda vacío y nunca levanta excepción. Si excede el budget, primero descarta conflictos y luego identificadores. Esa disciplina es arquitectura reusable.

### 2.3 Interpretación actual

`ActiveEpisodeTurn` aplica reglas first-match-wins para:

- reset explícito y apertura de episodio;
- corrección de fabricante y limpieza de modelo/identificadores heredados;
- cambio de sujeto/equipo explícito;
- extracción de fabricante, modelo, fault code y ausencias confirmadas;
- elipsis, composición, context break y actualización de goal.

`TechnicalReferentResolver` es mucho más estrecho que el nombre sugiere:

- sólo corre si el turno contiene `ajust*`;
- exige que el goal también contenga `ajust*`;
- extrae el objeto desde la forma `se ajust... <objeto>`;
- sólo hereda complementos `de/del` bajo reglas específicas;
- compara una ventana de tres turnos del usuario y cuatro horas;
- bloquea coordinación, modelo no reafirmado y equipo contaminante;
- usa `common_noun?` para resolver el caso abierto de una palabra.

Los tests cubren con profundidad el slice implementado: correcciones, modelos mixed-case, stale identifiers, demostrativos, objeto omitido con acuerdo de número, coordinación, 442/443 caracteres, provenance, ventana temporal, quiebre persistente y nombres de equipo desconocidos. En esta revisión se ejecutaron 394 tests relevantes con 1.865 assertions: 0 failures, 0 errors y 22 skips.

### 2.4 RAG y otras inferencias

El camino general usa `RetrieveAndGenerate` con Haiku 4.5. Existen además:

- rutas de `Retrieve` explícito seguidas por generación controlada;
- `DocumentIdentityScope`, que recupera primero y genera sólo cuando hay labels aplicables;
- generación en `StructuredEvidenceRoute` y `ContextEvidenceRoute`;
- router LLM KB/SQL/hybrid, apagado por default;
- síntesis LLM adicional para `HYBRID_QUERY`;
- Cohere Rerank 3.5, implementado sólo para consultas exhaustivas y apagado por regresiones de recall;
- análisis visual async como inferencia de otra modalidad.

No existe hoy una inferencia antes de retrieval cuya salida pueda reutilizarse como percepción conversacional.

### 2.5 Colisión arquitectónica encontrada

Ya existe `Rag::QueryAnalysis`, construido por `Rag::QueryEntities`, para selección de evidencia. Contiene `intents`, hipótesis de equipo, identificadores y relaciones solicitadas, pero hoy sólo llena parte del contrato de forma determinística.

Crear un segundo `Rag::QueryAnalysis` con otra semántica sería una colisión de ownership. La implementación futura debe escoger una de estas dos rutas:

1. evolucionar el objeto existente hacia un análisis único del turno sin romper sus consumidores; o
2. introducir temporalmente `Rag::ConversationalTurnAnalysis`, adaptarlo hacia el `QueryAnalysis` existente y converger después.

No se debe mantener dos “análisis de query” independientes que vuelvan a clasificar intent/equipo/referente.

## 3. Root cause del blocker

El blocker no es la ausencia de un slot. Es la combinación de tres problemas:

1. **Resolución open-world.** El vocabulario de componentes y productos no es cerrado y cambia por fabricante, país, manual y transcripción.
2. **Relación discursiva.** El mismo texto puede ser identidad, corrección, respuesta a una pregunta, cambio de equipo, comparación o nuevo problema según el turno anterior y la pregunta del asistente.
3. **Impacto asimétrico.** Un false negative pierde continuidad; un false positive puede recuperar el manual/equipo equivocado y contaminar una instrucción técnica.

Typed slots resuelven representación y validación. No resuelven clasificación ni coreferencia. Cada heurística nueva que intenta hacerlo en Ruby agrega vocabulario, orden de precedencia y excepciones cruzadas. El costo no crece por número de regex sino por interacciones entre reglas: una nueva forma de corrección puede cambiar extracción, continuity break, goal replacement, query composition y retrieval scope.

La frontera correcta es separar:

```text
Perception: propone qué significa el turno
Policy/state: decide qué proposiciones son admisibles y persistibles
Retrieval/tools: busca sólo bajo una identidad y un objetivo validados
Response: responde con evidencia y actualiza la pregunta pendiente
```

## 4. Estrategia A — determinístico extendido

### 4.1 Qué sí compraría

Agregar un `component` tipado, identidad explícita de equipo y un pending-question mejorado produciría valor inmediato:

- dejaría de usar `goal.text` como única memoria del objeto;
- permitiría invalidar el componente al cambiar de equipo;
- haría más explícitas las transiciones y tests;
- reduciría algunas composiciones de texto completo;
- preservaría latencia casi cero para interpretación.

Esto es necesario incluso si se introduce Haiku. No es suficiente como arquitectura conversacional final.

### 4.2 Dónde sigue rompiéndose

| Conversación futura | Qué ya resuelve v4 | Límite concreto |
|---|---|---|
| Pronombres y deícticos | algunos `este/ese/esos` dentro del patrón `ajust*` | no resuelve candidatos múltiples, “el otro”, “ese de arriba”, ni referencia general a una respuesta del asistente |
| Componentes implícitos | objeto omitido con acuerdo de número y antecedente único | no infiere componente desde síntoma/acción fuera del patrón de ajuste |
| Correcciones indirectas | cues como `no es`, `me equivoqué`, fabricante explícito | no representa “es el que está al lado”, “la placa era la anterior”, ni correcciones sin lexema predefinido |
| Mediciones | detecta algunas formas `lo medí/medimos` y marca `measurement_unbound` | no extrae valor, unidad, punto, condición, polaridad ni la vincula a la pregunta pendiente |
| Pasos de procedimiento | conserva goal y facts | `current_procedure` no tiene workflow activo; no hay `active_step`, precondición, resultado ni completitud |
| Troubleshooting multi-turn | mantiene fabricante/modelo/código y symptom dentro de goal | no tiene hipótesis, observaciones, pruebas realizadas ni transición por resultado |
| Voz/ASR | normaliza case/acentos y tolera texto corto | no usa confianza, alternativas ASR, homófonos, autocorrecciones ni fragmentos incompletos |
| Foto + texto | foto async guarda manufacturer/model, referencia y conflictos | no une componente/medición/step de la foto con el diálogo; la respuesta visual sigue una ruta separada |
| Referencia al asistente | `pending_fact` detecta una sola pregunta por regex | sólo entiende preguntas de marca/modelo/código; no “sí”, “no”, “al abrir”, “el segundo” o “haz eso” de forma general |
| Cambio de equipo | marcas explícitas, subject form, reset y modelo explícito cubren casos importantes | falla en cambios deícticos, mismo fabricante con otro equipo, equipo descrito sin nombre y cambios inducidos por foto |

No es correcto decir que v4 “no entiende pronombres” o “no entiende cambios de equipo”: sí resuelve un subconjunto probado. El problema es que ese subconjunto está codificado por forma lingüística y operación, no por un modelo de diálogo general.

### 4.3 Veredicto sobre A

Como baseline y fallback seguro, A es valiosa. Como arquitectura base hands-free, A se convierte gradualmente en un parser y dialogue-state tracker artesanal. Typed referent sólo pospone la frontera; no la elimina.

## 5. Estrategia B — Haiku como semantic perception layer

### 5.1 Capacidades que sí agrega

Una única inferencia estructurada puede proponer:

- intent y acción pedida;
- identidad de equipo explícita o corregida;
- componente/referente y relación con el turno anterior;
- si el turno responde la pregunta pendiente;
- síntoma, fault observation y medición candidata;
- continuity, switch, correction, ambiguity;
- query efectiva y route hint reutilizable.

Esto está mejor alineado con voz, frases cortas, self-correction y troubleshooting. Además, una misma salida puede alimentar state, routing y retrieval; esa reutilización es la principal justificación arquitectónica del costo.

### 5.2 Qué infraestructura actual debe permanecer

Haiku no reemplaza:

- `ConversationSession`, locks y update atómico;
- `ActiveEpisode` como estado versionado, acotado y sanitizado;
- correlation/provenance, account scope y duplicate protection;
- precedence de correcciones y resets;
- validation de spans: un entity/fact persistible debe estar literalmente presente en input autorizado;
- status/source/provenance de facts y conflictos usuario/foto;
- límites temporales, de tamaño y composición;
- context break como transición de policy;
- evidencia RAG, pins, safety processor, attribution guard y abstención;
- feature flags, shadow, fallback y telemetría.

### 5.3 Qué puede retirar eventualmente

Si el analyzer demuestra calidad y seguridad, puede reemplazar la parte de v4 que intenta comprender lenguaje abierto:

- `common_noun?`;
- casing como proxy de identidad en `unreaffirmed_name?`;
- parsing de `technical_nps` específico a ajuste;
- `identity_complement?` como decisión semántica;
- catálogos hardcoded usados para comprender identidad, conservando catálogos sólo como validación/resolución;
- detección de continuidad basada en listas de cues;
- el rol semántico de `FollowupQueryRewriter`.

No debe retirar de inmediato los guards. Primero se muda ownership; después se elimina código.

### 5.4 Problemas que Haiku no resuelve

| Riesgo | Por qué sigue existiendo | Control requerido |
|---|---|---|
| Entidades alucinadas | puede producir un fabricante, modelo o borne plausible pero ausente | schema cerrado + span validation + catálogo/evidencia; nunca persistir strings inventados |
| Clasificación inestable | temperatura 0 reduce, no elimina variación de servicio/modelo | golden versionado, prompt version, output schema y shadow drift |
| Estado stale | el modelo puede preferir contexto viejo | Ruby aplica correlation, timestamp, correction precedence y invalidación |
| Prompt drift | una edición puede cambiar clases silenciosamente | contract tests, corpus adversarial y versión de analyzer |
| Reproducibilidad | una inferencia externa no es una función Ruby pura | guardar decisión normalizada/telemetría, no el reasoning; stubs determinísticos en tests |
| Latencia | es una nueva llamada síncrona previa a RAG | conditional por riesgo semántico, timeout sin retry, medición por fase |
| Outage/throttle | añade un nuevo failure point | `analysis=nil`, no mutation semántica, turno crudo/fallback seguro |
| Model update/EOL | Haiku 4.5 tiene lifecycle externo | modelo/config versionados, eval antes de migrar y contrato provider-agnostic |
| Safety técnica | entender el turno no valida procedimiento/valor | RAG y policy siguen siendo fuente de verdad; analyzer no produce instrucciones |

### 5.5 Veredicto sobre B

B alinea mejor la percepción con el producto futuro, pero **Haiku-first sin policy determinística no es aceptable**. Always-on para todo texto RAG también paga latencia donde no hay continuidad que interpretar. B es un buen componente; no debe ser el sistema completo.

## 6. Estrategia C — Hybrid minimal

### 6.1 Frontera recomendada

```text
Turno normalizado + estado mínimo + pregunta pendiente
  → guards estructurales no semánticos
  → ¿el significado puede alterar una relación cross-turn?
      no  → fast path sin analyzer
      sí  → ConversationalTurnAnalysis/QueryAnalysis (Haiku)
  → Ruby valida spans, provenance y policy
  → ActiveEpisode muta una sola vez
  → una query efectiva + route hint compartidos
  → Retrieval/Tools
  → Response + pending question explícita
```

El fast path no debe afirmar que una palabra es componente o modelo, ni ejecutar un clasificador Ruby de “autocontenido”. Su elegibilidad debe depender de estructura/estado observable. Puede aceptar:

- reset explícito exacto;
- request sin episodio activo legible, enviado raw sin heredar semántica; puede abrir un goal literal y guardar facts explícitamente etiquetados, pero no tipar un referente implícito;
- selección/pin explícito resuelto por identidad de catálogo exacta;
- facts con label explícito y parser cerrado (`modelo es X`, `código 8`), siempre sujetos a validación;
- controles de tamaño, recency, tenant y duplicados;
- rutas determinísticas que no componen semántica.

Con un episodio activo, si el turno puede leer, conservar, corregir o invalidar estado heredado, el default es llamar al analyzer salvo que encaje en uno de esos contratos cerrados. También debe llamarlo cuando haya elipsis/deixis, corrección, respuesta corta a pregunta previa, múltiples referentes, potencial cambio de equipo, medición, voz con incertidumbre, foto+texto, referencia al asistente o continuación de troubleshooting. En modo hands-free/troubleshooting esta política puede equivaler prácticamente a always-on, sin imponer always-on a consultas documentales independientes.

### 6.2 Por qué es más sostenible

- limita la inferencia a donde compra capacidad;
- mantiene fail-closed y testabilidad de policy;
- evita extender regex semánticos para decidir semántica;
- permite que voz/troubleshooting usen analyzer casi siempre sin cobrarlo a cada consulta documental autocontenida;
- conserva reversibilidad: apagar analyzer vuelve a un comportamiento seguro, aunque menos conversacional;
- permite retirar heurísticas por ownership, no por big bang.

El ahorro monetario de conditional por sí solo no justifica un gate complejo. La justificación principal es menor latencia y menor superficie de fallo en turnos donde la semántica heredada no participa.

## 7. Comparative tradeoffs

| Criterio | A — determinístico extendido | B — Haiku perception | C — hybrid minimal |
|---|---|---|---|
| Evitar contaminación | fuerte en casos enumerados; frágil al crecer | débil sin validators; fuerte con policy Ruby | **más fuerte**: percepción + invariantes determinísticos |
| Calidad conversacional | media y localizada | alta potencial | alta donde importa; fast path en lo obvio |
| Latencia | mejor | peor si serial always-on | mejor que B, aunque los turnos ambiguos pagan todo el analyzer |
| Mantenibilidad | empeora con lenguaje nuevo | buena si hay contrato único; mala si se superpone a v4 | **mejor**, condicionado a retirar legacy |
| Testabilidad | excelente unitariamente, cobertura infinita imposible | necesita evals + tests de policy | combinación adecuada de unit tests, adversarial stubs y golden |
| Outage behavior | sin dependencia nueva | requiere fallback | fallback delimitado |
| Costo | menor | +USD 1,20/1k con supuesto actual | +USD 1,20/1k × fracción invocada |
| Voz/foto/troubleshooting | deuda creciente | buena base perceptiva | **mejor trayectoria** sin framework prematuro |
| Reversibilidad | alta | media si estado depende del LLM | alta con `analysis=nil` y shadow |
| Riesgo de doble sistema | bajo al inicio, alto si luego llega Haiku | muy alto si sólo se “pone encima” | controlable con plan de retiro |

## 8. Long-term classification de reglas actuales

La pregunta relevante no es si una regla “es regex”, sino si puede crear una relación semántica falsa. Una regla determinística es segura cuando un error produce abstención/false negative, o cuando valida estructura/provenance sin decidir significado abierto.

| Rule | Current role | Semantic inference? | Failure consequence | Keep deterministic? | Classification | Reason |
|---|---|---:|---|---:|---|---|
| account/session scope | evita mezclar tenants/sesiones | no | fuga/contaminación cross-tenant | sí | KEEP_LONG_TERM | boundary de seguridad |
| unique `correlation_id` / duplicate protection | enlaza goal, history y turno | no | antecedente equivocado | sí | KEEP_LONG_TERM | identidad causal, no NLU |
| exact provenance match goal↔history | prueba origen del texto heredado | no | copiar texto sin antecedente válido | sí | KEEP_LONG_TERM | Haiku no debe declarar su propia provenance |
| 4h window | expira episodio/referencias | no | estado excesivamente stale o pérdida de continuidad | sí | KEEP_LONG_TERM | policy configurable |
| last 3 user turns | limita búsqueda de antecedente | no | false negative o stale reference | sí | KEEP_LONG_TERM | mantener como guard; el estado tipado debe evitar depender de transcript largo |
| 442/443 composition cap | limita query compuesta | no | truncamiento o prompt inflado | sí | KEEP_LONG_TERM | guard contractual |
| explicit reset | abre trabajo nuevo | mínima, si el comando es exacto | reset accidental | sí, vocabulario cerrado | KEEP_LONG_TERM | una orden explícita tiene semántica controlada |
| `context_break` state transition | impide revivir goal viejo | no; la detección sí | contaminación persistente | sí | KEEP_LONG_TERM | policy durable; cambiar el detector |
| `current_breaks_continuity?` actual | detecta nuevo componente/equipo | sí | limpia o conserva goal incorrectamente | parcialmente | KEEP_BUT_SIMPLIFY | conservar la transición; mover percepción al análisis |
| `common_noun?` | componente vs nombre de producto | sí, open-world | falsa composición o false negative | no | HAIKU_REPLACES_EVENTUALLY | fonotáctica aproximada, no policy |
| `identity_complement?` | interpreta un complemento junto a modelo nuevo | sí | copia identidad como componente | no | HAIKU_REPLACES_EVENTUALLY | depende de `common_noun?` |
| `unreaffirmed_name?` | casing como proxy de identidad | sí | falso break o contaminación por casing/ASR | no | HAIKU_REPLACES_EVENTUALLY | señal útil para shadow, no verdad semántica |
| `technical_nps` / `split_np` | parser nominal específico | sí | componente equivocado o no resuelto | no como parser principal | HAIKU_REPLACES_EVENTUALLY | no escala a voz ni otras operaciones |
| `pure_complement?` | permite sólo cadenas `de/del` | mixta | si es permisiva, hereda equipo/location; si es estricta, false negative | sí como veto simplificado | KEEP_BUT_SIMPLIFY | validar forma de un span propuesto es seguro; descubrirlo no |
| coordination detection | impide tratar A y B como un objeto | baja; actúa como veto | principalmente false negative | sí | KEEP_LONG_TERM | guard conservador de composición |
| number agreement | valida objeto omitido | baja | false negative o inserción gramatical errónea | sí como validator | KEEP_BUT_SIMPLIFY | no debe elegir referente, sólo rechazar uno incompatible |
| `identity_bridge?` | permite atravesar turnos intermedios | mixta | revive un antecedente a través de una tarea nueva | parcialmente | KEEP_BUT_SIMPLIFY | dividir facts explícitos seguros de medición/proposición semántica |
| hardcoded manufacturers | extrae y compara marca | sí por catálogo cerrado | marca nueva ignorada o palabra homónima mal clasificada | sólo como validator/catalog resolver | KEEP_BUT_SIMPLIFY | catálogo account-scoped, no lista universal en código |
| explicit `modelo es X` / `código X` | extracción de facts etiquetados | acotada | valor falso si el capture es laxo | sí con stopwords/shape/span | KEEP_LONG_TERM | parser cerrado y auditable |
| facts manufacturer/model/fault_code | estado tipado con source/status | no | estado stale si policy falla | sí | KEEP_LONG_TERM | ampliar schema, no reemplazarlo |
| `goal.text` | problema literal y semilla de composición | sí cuando actúa como memoria semántica | pega contexto stale | sí como audit/summary | KEEP_BUT_SIMPLIFY | no debe ser el único referent store |
| `pending_fact` | recuerda una pregunta simple del asistente | detección actual sí | interpreta mal una respuesta corta | state sí; detector no | KEEP_BUT_SIMPLIFY | persistir `pending_question` explícita desde response stage |
| `FollowupQueryRewriter` | une pregunta previa con identificador de catálogo | sí, aunque muy acotada | composición falsa o doble lógica | sólo sus primitives | REMOVE_IF_HAIKU_SUCCEEDS | migrar caps/provenance; retirar servicio legacy |
| selection gate/pin identity | evita generar sobre una selección sin intent | no cuando el match es exacto | respuesta no pedida | sí | KEEP_LONG_TERM | UI/catalog contract |
| photo-vs-user conflict | no deja que visión reemplace al técnico | no | una lectura visual domina indebidamente | sí | KEEP_LONG_TERM | policy de provenance multimodal |

### Clasificación resumida solicitada

- **KEEP_LONG_TERM:** provenance, correlation, tenant scope, 4h, last-3 como guard, límites, reset explícito, context-break transition, facts tipados, coordinación-veto, selección/pins, conflictos foto/usuario.
- **KEEP_BUT_SIMPLIFY:** `current_breaks_continuity?`, `identity_bridge?`, `pure_complement?`, number agreement, hardcoded manufacturer extraction, `goal.text`, `pending_fact`.
- **HAIKU_REPLACES_EVENTUALLY:** `common_noun?`, `identity_complement?`, `unreaffirmed_name?`, `technical_nps` como parser y detección lingüística de continuidad.
- **REMOVE_IF_HAIKU_SUCCEEDS:** `FollowupQueryRewriter` como segundo motor semántico; conservar normalización, caps y catálogo como librerías compartidas.

## 9. State model recommendation

### 9.1 ¿Es suficiente `ActiveEpisode`?

Es suficiente como **envelope y ownership boundary**, no como schema final hands-free. No hace falta reemplazarlo ni crear una state machine/framework. Sí necesita evolucionar a un payload v2 cuando haya evidencia de uso.

Separación recomendada:

```text
ActiveEpisode
  identity/lifecycle
  equipment
    manufacturer fact
    model fact
  focus
    component/referent fact
  problem
    symptom literal
    fault_code fact
  dialogue
    pending_question key/type
  media
    active_photo + conflicts
  workflow            # sólo al activar troubleshooting guiado
    procedure_id/evidence identity
    active_step
    observations/measurements relevantes
```

No introducir ahora todos los campos del esquema futuro. El mínimo próximo es:

1. `equipment` (reorganización compatible de manufacturer/model);
2. `active_referent` con `head`, literal source span, type, correlation y source;
3. `problem.symptom` literal opcional y `fault_code` existente;
4. `pending_question` explícita, no inferida a posteriori desde prosa;
5. mantener foto/conflictos.

`measurement`, `active_step` y un historial de pruebas deben esperar al primer flujo de troubleshooting guiado. Persistirlos antes sería diseñar una ontología sin consumer. Cuando entren:

- una medición debe incluir valor, unidad, location/test point, condición de la prueba y provenance;
- el sistema no debe interpretar que “24 V” es esperado/correcto; sólo es una observación del técnico;
- `active_step` debe estar ligado a un procedimiento/evidencia identificable, no a texto generado libremente.

La columna `current_procedure` existente no debe adoptarse por conveniencia: hoy no tiene contrato ni ownership activo.

### 9.2 Request-scoped `QueryAnalysis`

El análisis del turno puede contener datos transitorios más ricos:

- turn kind / intent / desired action;
- continuity relation (`same`, `correction`, `switch`, `new`, `unknown`);
- candidates con spans para equipment, component, fault y measurement;
- referencia a `pending_question` o respuesta del asistente;
- ambiguity y missing information;
- effective-query proposal y route hint;
- analyzer/model/prompt/schema version y timing.

No almacenar el JSON completo. Persistir sólo facts que pasan policy:

- valor literal presente en el turno o artefacto autorizado;
- type permitido;
- provenance/correlation/timestamp;
- confidence cualitativa sólo para decidir, no como “verdad” durable;
- invalidación explícita de facts incompatibles.

El reasoning del modelo, candidatos descartados y route hint son request-scoped/telemetría, no memoria del episodio.

## 10. Hands-free implications

Para el flujo objetivo:

```text
“Estoy en un MonoSpace y no abre.”
“ninguno, pero el operador hace ruido.”
“al abrir. Mira esta foto.”
“medí 24 volts en X7.”
```

la arquitectura necesita estas transiciones:

1. Perception propone `model=MonoSpace`, symptom=`no abre`, equipo nuevo.
2. Ruby valida que `MonoSpace` está en el turno, abre episodio y guarda provenance.
3. Response registra `pending_question=fault_code`, no sólo texto de asistente.
4. “ninguno” se vincula a esa pregunta; `operador hace ruido` agrega observación y componente candidato sin borrar equipo.
5. Response registra una pregunta de condición temporal.
6. “al abrir” se vincula a esa pregunta; “esta foto” crea relación multimodal por correlation, no por proximidad de strings.
7. El job visual agrega observaciones con source=`photo`; cualquier conflicto queda abierto.
8. “24 volts en X7” se persiste sólo como medición reportada: value=24, unit=V, location=X7, condición activa si está inequívocamente ligada. No se concluye que sea normal ni que X7 pertenezca al modelo sin evidencia.

A requeriría una regla por cada forma de respuesta/medición/referencia. B puede percibirlas, pero sin state/policy contaminaría facts. C soporta el flujo con menor deuda porque cada etapa tiene ownership claro.

Voz agrega además dos requirements que v4 no tiene:

- metadata de ASR (confidence y alternativas) debe llegar a perception; una transcripción dudosa no debe persistir identidad como fact conocido;
- la UX debe poder pedir confirmación corta cuando la ambigüedad cambia equipo, procedimiento o punto de medición.

## 11. RAG/retrieve implications

### 11.1 Caso 1 — analyzer antes de Retrieve

```text
Haiku → effective query → Retrieve/RetrieveAndGenerate
```

Es el camino más seguro cuando la query raw es elíptica, contiene corrección, depende de una pregunta pendiente o puede cambiar equipo/componente. En la primera fase no hace falta reescribir todas las rutas: el analyzer conditional puede producir la query efectiva y mantener el `RetrieveAndGenerate` existente.

Desventaja: la latencia es serial.

### 11.2 Caso 2 — speculative raw Retrieve en paralelo

```text
Haiku ───────────┐
                 ├→ reconcile → generation
Retrieve(raw) ───┘
```

Es seguro sólo si el Retrieve es recuperable y no genera respuesta todavía. Nunca lanzar `RetrieveAndGenerate` especulativo: una query con meaning equivocado gastaría generación y produciría una respuesta que luego debe descartarse.

Puede reutilizarse el Retrieve raw cuando:

- el turno es autocontenido y el analyzer sólo confirma campos ya explícitos;
- scope/pins no cambian;
- no hay correction, switch, negation ni deictic;
- el `retrieval fingerprint` validado coincide: equipment, component, intent/procedure/fault y constraints relevantes son equivalentes;
- el analyzer sólo agrega discourse metadata que no cambia términos ni filtros.

Debe descartarse cuando:

- “ese”, “el otro”, “al abrir”, “ninguno” o una respuesta corta dependen del pending question;
- cambia/corrige manufacturer, model, component o fault;
- la query efectiva agrega el antecedente que aporta los discriminantes de búsqueda;
- la foto cambia identidad/scope;
- la medición sólo tiene sentido bajo un test point/step heredado;
- el analyzer detecta ambigüedad o continuity break.

No usar igualdad de strings como reconciliación. Definir un fingerprint estructural. Si falta un campo crítico, no reutilizar.

### 11.3 Encaje con rutas actuales

- `RetrieveAndGenerate`: mantenerlo como default inicial; no mezclar su output contract de citas con JSON semántico.
- `StructuredEvidenceRoute` / `ContextEvidenceRoute` / `DocumentIdentityScope`: ya separan retrieval y generación; son el lugar natural para experimentar con reconcile sin migración global.
- fallback `Retrieve` por citas ausentes: no sirve como speculative retrieval porque ocurre después de generar.
- reranker: no debe correr sobre una query especulativa ambigua. Además está apagado hoy y cuesta USD 2/1.000 queries de rerank.

## 12. Latency implications

### 12.1 Baseline observado

La base local contiene 1.386 invocaciones Haiku query entre 2026-06-12 y 2026-09-23:

- p50 de invocación: **4.656 ms**;
- p95 de invocación: **8.707 ms**;
- `rag_filtered`: promedio 5.716 ms;
- `rag_global`: promedio 8.798 ms;
- `query_direct`: promedio 4.353 ms.

Son latencias de filas `bedrock_queries`, no una medición representativa de end-to-end ni del analyzer. El conjunto durable de `interaction_completed` disponible localmente tiene sólo 10 filas y no debe usarse como SLO.

No existe medición online de `SemanticQueryAnalyzer`. El presupuesto de 800 ms p95 del plan anterior es una propuesta, no un dato.

### 12.2 Modelos de latencia

```text
serial always-on:
Tturn = Tanalyzer + Tstate + Trag

conditional:
Tturn(ambiguous) = Tanalyzer + Tstate + Trag
Tturn(fast)      = Tstate + Trag

parallel explicit Retrieve:
Tturn = max(Tanalyzer, Tretrieve_raw) + Treconcile + Tgeneration
```

No se deben sumar p95 como si fueran medias independientes. La instrumentación debe medir la distribución conjunta por route.

Impacto perceptual:

- +300–800 ms sobre 5–9 s de RAG puede ser aceptable en texto si mejora coherencia;
- en voz, 800 ms adicionales antes de cualquier feedback son notorios;
- el RAG actual no streama `RetrieveAndGenerate`, de modo que el usuario percibe todo como silencio;
- el mayor upside de UX no es ahorrar USD, sino ocultar trabajo con acknowledgement/streaming y paralelizar sólo cuando la semántica lo permite.

Campos mínimos de telemetría: `semantic_analysis_ms`, `state_ms`, `retrieve_ms` cuando exista, `generation_ms`/`rag_ms`, `total_ms`, route, mode, timeout y si retrieval especulativo fue reused/discarded. Reportar p50/p95/p99 por route y por analyzer mode.

## 13. Cost and unit-economics implications

### 13.1 Precios y evidencia

El repo configura y contabiliza Haiku 4.5 global a:

- input: USD 0,001 por 1.000 tokens = USD 1/MTok;
- output: USD 0,005 por 1.000 tokens = USD 5/MTok.

Esto coincide con el precio publicado por Anthropic para Haiku 4.5. AWS confirma que el model ID global configurado es válido para Bedrock Runtime y que Haiku 4.5 soporta Converse y structured outputs. AWS también publica Cohere Rerank 3.5 a USD 2 por 1.000 queries, con hasta 100 chunks por query.

Fuentes externas:

- [AWS Bedrock model card — Claude Haiku 4.5](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-anthropic-claude-haiku-4-5.html)
- [AWS — Structured outputs for Claude](https://docs.aws.amazon.com/bedrock/latest/userguide/claude-messages-structured-outputs.html)
- [AWS Bedrock pricing](https://aws.amazon.com/bedrock/pricing/)
- [Anthropic — Introducing Claude Haiku 4.5](https://www.anthropic.com/news/claude-haiku-4-5)

### 13.2 Supuestos explícitos

Analyzer, hasta medir P0:

```text
600 input  × USD 0,001/1k = USD 0,00060
120 output × USD 0,005/1k = USD 0,00060
total por analyzer          = USD 0,00120
```

Generación baseline para proyección: **USD 9,25/1.000 consultas**, reserva conservadora canónica de `docs/SAAS_COST_MODEL_2026-06-12.md`.

Cross-check local actual:

- 1.165 logical turns agrupados por correlation;
- 1,19 invocaciones Haiku por turno;
- 207 turns tuvieron más de una invocación;
- costo promedio por logical turn: USD 0,008801;
- p50: USD 0,006778; p95: USD 0,021938.

La tabla usa USD 0,00925/turn por prudencia. `conditional` se ilustra con una fracción **f=15%**, no medida todavía. La fórmula correcta es `analyzer_cost = queries × f × 0,0012`.

### 13.3 Volumen total

Costos mensuales, 30 días, sólo LLM de query; excluyen fotos, embeddings, vector store, Aurora, S3 e impuestos:

| Queries/día | Queries/mes | v4 generation | Conditional analyzer (15%) | Conditional total | Always analyzer | Always total |
|---:|---:|---:|---:|---:|---:|---:|
| 100 | 3.000 | USD 27,75 | USD 0,54 | USD 28,29 | USD 3,60 | USD 31,35 |
| 1.000 | 30.000 | USD 277,50 | USD 5,40 | USD 282,90 | USD 36,00 | USD 313,50 |
| 10.000 | 300.000 | USD 2.775,00 | USD 54,00 | USD 2.829,00 | USD 360,00 | USD 3.135,00 |

### 13.4 Costo mensual por técnico

| Consultas/día | Consultas/mes | v4 generation | Conditional analyzer (15%) | Conditional total | Always analyzer | Always total |
|---:|---:|---:|---:|---:|---:|---:|
| 20 | 600 | USD 5,55 | USD 0,108 | USD 5,658 | USD 0,72 | USD 6,27 |
| 50 | 1.500 | USD 13,875 | USD 0,27 | USD 14,145 | USD 1,80 | USD 15,675 |
| 100 | 3.000 | USD 27,75 | USD 0,54 | USD 28,29 | USD 3,60 | USD 31,35 |

Sensibilidad conditional:

- a f=10%: USD 0,12 por 1.000 consultas;
- a f=25%: USD 0,30 por 1.000;
- always-on: USD 1,20 por 1.000.

### 13.5 Unit economics

El documento comercial vigente considera aproximadamente 1 UF/mes por técnico (~USD 41 en su supuesto). Bajo esa referencia:

- 20 consultas/día: analyzer always-on cuesta USD 0,72/mes; inmaterial;
- 50/día: USD 1,80/mes; todavía pequeño, y el total query LLM ronda USD 15,68;
- 100/día: el analyzer cuesta sólo USD 3,60, pero el total query LLM llega a USD 31,35 antes de fotos e infraestructura; el problema económico ya es la generación, no perception.

Por tanto:

- no rechazar Haiku por USD 0,0012/turn si compra continuidad segura;
- no justificar un gate conditional complejo sólo por ahorro a bajo volumen;
- desde ~10.000 consultas/día, ahorrar USD 270–324/mes frente a always-on (f=10–25%) ya merece atención, pero sigue siendo menor que la generación;
- el nivel de uso de 100 consultas/día por técnico requiere revisar packaging/fair-use aunque no exista analyzer;
- conditional debe comprarse principalmente por latencia, confiabilidad y reducción de superficie, no por centavos.

## 14. LLM-call redundancy analysis

| Inference | Classification | Estado actual | Recomendación |
|---|---|---|---|
| semantic analyzer | ESSENTIAL_CAPABILITY | no existe | una sola salida por turno contextual; reutilizar para state + routing + retrieval |
| RAG generation | ESSENTIAL_CAPABILITY | varias rutas, una generación final por route | mantener; es la inferencia que produce respuesta con evidencia |
| query router KB/SQL/hybrid | REDUNDANT si corre separado | implementado, default off | no encender como segundo clasificador; route hint debe salir del mismo análisis |
| Cohere reranker | USEFUL_CAPABILITY | sólo exhaustive, flag off por regresión | reactivar sólo con evidencia de recall/precision; nunca universal ni especulativo |
| verifier LLM | PREMATURE_OPTIMIZATION | no hay verifier general; sí guards determinísticos | no agregar hasta medir un fallo que los guards/evals no cubran |
| hybrid-answer synthesis | USEFUL_CAPABILITY, potencialmente REDUNDANT | sólo HYBRID_QUERY, router off | una sola síntesis grounded cuando ambas fuentes son necesarias; evitar re-resumir dos respuestas libres |
| document-identity generation | USEFUL_CAPABILITY | Retrieve explícito + generación; fallback a R&G en failure | es una ruta alternativa, no duplicación normal; medir fallback doble |
| structured/context generation | ESSENTIAL_CAPABILITY dentro de su route | usa evidencia ya recuperada | tratar como variante de RAG generation, no como “otro analyzer” |
| vision analysis | ESSENTIAL_CAPABILITY para foto | async, modalidad separada | no fusionar con analyzer textual; reconciliar resultados vía state/provenance |

Una misma percepción debe alimentar:

```text
continuity/state mutation
route hint (KB/DB/hybrid/tool)
retrieval query/fingerprint
response policy inputs
```

Si cada consumer vuelve a llamar al modelo, el producto pagará latencia, costo y divergencia semántica múltiple. La salida no debe incluir respuesta técnica; eso sigue perteneciendo a RAG generation.

## 15. Migration/refactor strategy

La opción recomendada es **C con migración strangler**, no big bang:

### Fase 0 — definir frontera y nombres

- decidir cómo converge el `Rag::QueryAnalysis` existente;
- definir schema request-scoped, enums, spans, versiones y ownership;
- clasificar cada consumidor: state, route, retrieval, telemetry;
- congelar invariantes v4 y corpus adversarial.

### Fase 1 — offline/shadow

- analyzer sin mutation ni cambio de query;
- medir disagreements, tokens, latencia, invalid schema y hallucinated spans;
- golden con `unsafe_contamination=0`;
- sin retry síncrono.

### Fase 2 — una frontera upstream

- producir analysis antes del único `record_user_turn!`;
- pasar el mismo objeto a `ActiveEpisodeTurn` y `QueryOrchestratorService`;
- un solo UPDATE de episode/history;
- fallback `analysis=nil`.

### Fase 3 — activar un slice ambiguo

- sólo casos que hoy llegan a `common_noun?`/identity ambiguity;
- Ruby mantiene todos los vetos hostiles;
- no cambiar retrieval profile ni prompt generation en la misma fase.

### Fase 4 — mover consumers y retirar duplicación

- route hint reemplaza `classify_query_intent` antes de encender DB routing;
- retrieval usa una query/fingerprint validada;
- `pending_question` explícita reemplaza parsing de prosa del asistente;
- retirar `FollowupQueryRewriter` cuando sus casos estén cubiertos por la nueva frontera.

### Fase 5 — retirar heurísticas por familia

Orden sugerido:

1. `common_noun?` + `identity_complement?`;
2. `unreaffirmed_name?` como decisión;
3. `technical_nps` específico a `ajust*`;
4. cues lingüísticos duplicados de continuity;
5. servicio legacy de follow-up.

Cada retiro requiere:

- coverage equivalente;
- cero contaminación nueva;
- shadow que demuestre ownership único;
- eliminación efectiva, no dejar ambas decisiones en cascada.

### Fase 6 — ampliar estado cuando exista el consumer

- voz/ASR metadata;
- mediciones tipadas;
- workflow de troubleshooting y active step;
- referencias foto+texto.

No introducir LangGraph ni una state machine nueva. El flujo Perception → State/Policy → Retrieval/Tools → Response ya es agentic en el sentido útil: contracts y ownership, no framework.

## 16. Risks

| Riesgo | Severidad | Mitigación |
|---|---:|---|
| Haiku introduce false-positive composition | crítica | span validation, ambiguity fail-closed, hostile tests, golden cero contaminación |
| analyzer + regex antiguo discrepan durante años | alta | ownership map, fechas/exit criteria de retiro, telemetry de double-decision |
| `QueryAnalysis` duplicado | alta | converger objeto existente o adaptador con nombre temporal explícito |
| latencia serial degrada voz | alta | conditional por modo, timeout, phase metrics, explicit-retrieve parallel sólo cuando sea seguro |
| estado crece sobre 2.048 bytes | media | persist subset mínimo, versionar budget y medir eviction |
| prompt/model drift | alta | versionar prompt/schema/model, replay corpus antes de rollout |
| outage/throttle | media | cero retries, no mutation semántica, fallback seguro |
| analysis usado como evidencia técnica | crítica | separación estricta: percepción no es manual; generation sigue grounded |
| speculative retrieval reutilizado con meaning distinto | alta | structural fingerprint y discard por default |
| foto async pisa estado nuevo | alta | mantener locks, correlation y conflict policy ya existentes |
| `current_procedure` revive como estado sin contrato | media | no usar hasta diseñar consumer/provenance/idempotency |
| conditional gate se convierte en otro parser | alta | fast path sólo por estructura/ausencia de dependencia cross-turn |

## 17. Recommendation

Elegir **HYBRID_MINIMAL** como arquitectura base.

La forma precisa es:

- Ruby conserva estado, policy, safety, persistence y retrieval authorization.
- Haiku se convierte en la percepción semántica única de turnos contextuales.
- El mismo análisis alimenta state, routing y retrieval; no se ejecuta otro router semántico.
- Turnos autocontenidos y rutas determinísticas sin composición conservan fast path.
- Voz, mediciones, referencias al asistente, foto+texto y troubleshooting usan perception por defecto.
- El rollout empieza conditional/shadow y sólo pasa a always-on por modo si la medición demuestra que compra false-negative reduction suficiente.
- La migración diseña primero la frontera y después retira heurísticas; no se conserva `LLM + regex semántico + FollowupQueryRewriter` como arquitectura estable.

El siguiente paso no es implementar el analyzer online. Es cerrar P0: contrato único compatible con el `Rag::QueryAnalysis` existente, corpus etiquetado offline y reporte de contamination/tokens/latency sobre el slice ambiguo. Ese paso es reversible, no modifica runtime y decide si Haiku realmente compra capacidad.

```text
RECOMMENDED_ARCHITECTURE:
HYBRID_MINIMAL

CURRENT_V4_ASSESSMENT:
GOOD_BASE_NEEDS_SEMANTIC_LAYER

HAIKU_ROLE:
CONDITIONAL

REFACTOR_REQUIRED:
MODERATE

COST_ASSESSMENT:
ACCEPTABLE_FOR_CAPABILITY

LATENCY_ASSESSMENT:
NEEDS_OPTIMIZATION

NEXT_IMPLEMENTATION_STEP:
Definir un único contrato de análisis compatible con el Rag::QueryAnalysis existente y ejecutar un corpus offline etiquetado, sin cambios de runtime, midiendo unsafe_contamination, tokens y latencia.

MAIN_REASON:
La comprensión open-world debe salir de regex, pero la autoridad sobre estado, seguridad y evidencia debe permanecer determinística en Ruby.

MAIN_RISK:
Mantener simultáneamente Haiku, las heurísticas semánticas v4 y FollowupQueryRewriter convertiría la migración en tres motores de diálogo divergentes.
```
