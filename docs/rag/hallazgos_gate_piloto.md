# Libro de hallazgos — gate del piloto SEGURIDADES

Append-only. Una entrada por hallazgo, con la fase que lo encontró, la
evidencia, a qué fases afecta y su estado.

Tres reglas:

1. Al empezar cada fase, leer este archivo y atender toda entrada **abierta**
   cuyo *Afecta a* la nombre. Es el primer paso, antes de tocar código.
2. Al cerrar cada fase, anexar lo encontrado, incluido lo que parezca menor.
3. Si un hallazgo afecta a una fase ya cerrada, **parar y reportar**. No
   diferirlo.

---

## H-00 — El libro no se creó en la Fase 0

- **Encontrado en:** Fase 2 (al aplicar la regla 1)
- **Evidencia:** el plan lo manda crear en la Fase 0 (`docs(rag): findings
  ledger for the pilot gate`); los commits `067f334`, `fc3f5cb` y `71c4fd1`
  cerraron las Fases 0 y 1 sin él.
- **Afecta a:** Fases 0 y 1, ya cerradas — no hay traspaso escrito de lo que se
  encontró en ellas.
- **Estado:** cerrado por creación. Las entradas de las Fases 0 y 1 se dan por
  perdidas; se reconstruyen desde los mensajes de commit si hacen falta.

## H-01 — El hallazgo 8 del plan (`EDEL-K2`) ya estaba arreglado

- **Encontrado en:** Fase 2
- **Evidencia:** el plan afirma que `EXPLICIT_EQUIPMENT_PATTERN` "exige un
  dígito pegado a las letras (`EDEL-542` matchea, `EDEL-K2` no)" y que
  `TWISTER TW` es el mismo bug abierto desde el 2026-07-28. Medido: el commit
  `4a66b01` (2026-07-28 21:22, *"fix(rag): resolve edel_k2_led31/altius_d9_d10
  routing…"*) añadió el `[A-Z]?` opcional ese mismo día. Hoy
  `ambiguous_hardware_query?("En la EDEL-K2, ¿qué LED indica que los cerrojos
  están cerrados?")` es `false`: la pregunta nunca llega a
  `AmbiguousModelResponder`.
- **Afecta a:** solo a la Fase 2 (elimina uno de los tests que el plan pedía).
  El bug real que queda es el de una placa **sin ningún dígito**, que es
  exactamente `TWISTER TW`.
- **Estado:** cerrado. Queda fijado en
  `ambiguous_model_responder_test.rb` con un test de intención, para que la
  distinción no se vuelva a perder.

## H-02 — El `retrieve_invocations: 2` de `twister` es del arnés, no del producto

- **Encontrado en:** Fase 2
- **Evidencia:** [script/rag_seguridades_benchmark.rb#L175](../../script/rag_seguridades_benchmark.rb#L175)
  llama `counted_service.retrieve_chunks` **siempre**, solo para poblar el
  bloque `retrieval` del artefacto, y después construye el responder sobre el
  mismo `CountingRagService`. Ese es el segundo Retrieve que
  `tmp/pilot_gate/pilot_10q_v4_1.json` registra para
  `twister_embarba_puertas`. En producción
  (`QueryOrchestratorService`) el responder ya era terminal para ese caso: el
  contador real era 1 antes de la Fase 2 y sigue siendo 1 después.
- **Afecta a:** Fase 6 y Fase 7 — el plan espera que ese contador **baje** a 1
  en el artefacto tras la Fase 2, y no va a bajar mientras el arnés siga
  haciendo su propio Retrieve. La casilla de la Definición de terminado
  (*"`retrieve_invocations` … bajó en los tocados por la Fase 2"*) no es
  verificable como está escrita.
- **Estado:** abierto. Requiere decidir en la Fase 6 entre (a) medir el
  contador del arnés menos 1 para los casos que no toman la ruta estructurada,
  o (b) reestructurar el benchmark para reutilizar el retrieval del responder,
  que es un cambio del instrumento y no estaba en el alcance de la Fase 2.
  El hallazgo 7 del plan (16/52 casos con doble Retrieve) hay que releerlo con
  esto delante: parte de esos 16 puede ser el mismo artefacto de arnés.

## H-03 — `BoardHeading.mentioned?` colisiona entre placas hermanas con guion

- **Encontrado en:** Fase 2
- **Evidencia:** `Rag::BoardHeading.mentioned?("EDEL-K3 Wiring Overview", "…
  EDEL-K2 …")` devuelve `true`. `word_match?` acepta un prefijo común de 4
  caracteres y `EDEL-K3` / `EDEL-K2` comparten seis. La regla del dígito no lo
  atrapa porque el dígito vive dentro del token compuesto. Las hermanas sin
  guion sí se distinguen (`TPR60`/`TPR70` comparten solo 3, `ARCA III`/`ARCA
  II` caen por la regla de token corto).
- **Afecta a:** Fase 2 (lo que acaba de entrar) y Fase 6. Hasta hoy
  `mentioned?` solo **añadía** cobertura en `StructuredEvidenceRoute`, un uso
  aditivo e inocuo; la Fase 2 lo convierte en la decisión "responder en vez de
  preguntar". Con una sola placa hermana recuperada, el técnico recibiría una
  respuesta sobre la placa equivocada en lugar del menú. Con las dos hermanas
  recuperadas el filtro da `named.size == 2` y el menú se mantiene, que es el
  caso benigno.
- **Estado:** abierto, **no corregido a propósito**. Arreglar `word_match?`
  toca la tabla de verdad 36/36 de `board_heading_test.rb` y las dos rutas que
  la consumen: está fuera del alcance aprobado de la Fase 2 y necesita decisión
  del usuario. Mitigación vigente: la respuesta sale por la ruta estructurada,
  con directiva verbatim y citas, de modo que la placa realmente usada queda
  impresa y trazable en la respuesta.

## H-04 — `retrieval_budget` mal reportado cuando el responder entrega el retrieval

- **Encontrado en:** Fase 2
- **Evidencia:** `StructuredEvidenceRoute#structured_trace` y `#log_route`
  emiten la constante `RagRetrievalProfile::STRUCTURED_MAPPING_RESULTS` como
  `retrieval_budget`. Cuando el Retrieve lo hizo `AmbiguousModelResponder`, el
  presupuesto real fue `RETRIEVAL_RESULTS` (20).
- **Afecta a:** nada funcional; solo la telemetría de esos turnos.
- **Estado:** abierto, coste conocido. Arreglarlo pide pasar el presupuesto
  como parámetro de `#complete_from_retrieval`, lo que ensancharía el *extract
  method* que la Fase 2 quiso mantener puro.

## H-05 — La suite completa es dependiente del orden por una fuga de `I18n.locale`

- **Encontrado en:** Fase 2
- **Evidencia:** 1 de 9 corridas completas de `bin/rails test` dio 7 fallos
  (`document_overview_responder_test.rb:152/161/169`, esperando `"Documento:"`
  y recibiendo `"Document:"`); las otras 8, incluidas las de semillas fijas 1,
  2, 3 y 42417, dieron `1987 runs, 0 failures`.
  [locale_switchable.rb:17](../../app/controllers/concerns/locale_switchable.rb#L17)
  asigna `I18n.locale` global en un `before_action` y nunca lo restaura, así
  que un test de controlador con `session[:locale] = :en` contamina a todos los
  que corran después en el mismo proceso.
- **Afecta a:** Fase 7 (*"suite Minitest completa verde"*). No tiene relación
  con la Fase 2: ningún archivo tocado interviene en esos tests.
- **Estado:** abierto, preexistente. En la Fase 7 hay que decidir si se sella
  (`I18n.with_locale` o un reset en el teardown de los tests de controlador) o
  si se declara limitación conocida. Fijar la semilla oculta el problema, no lo
  cierra.

---

## Fase 2 — cerrada

- **Commits:** `2d6ea8b` (*extract method*), `9941f9e` (cambio de conducta).
- **Verificado:** `bin/rails test` 1987 runs / 0 failures (8 corridas de 9; ver
  H-05), `bin/rubocop` limpio sobre los cinco archivos tocados.
- **No verificado en producción:** el caso `twister_embarba_puertas` no se ha
  vuelto a correr contra Bedrock. Eso es la Fase 6.
- **Entradas abiertas que la Fase 6 debe atender:** H-02, H-03.
