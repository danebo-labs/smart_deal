# frozen_string_literal: true

require "test_helper"
require "json"

# Fase 0.5 · paso P0 — caracterización de la lógica basada en regex.
#
# Especificación: docs/RAG_REGEX_AUDIT_FASE05_2026-07-29.md §7.2 y §7.3.
#
# ESTOS TESTS FIJAN EL COMPORTAMIENTO ACTUAL, INCLUIDO EL INCORRECTO. Son la red
# de seguridad que permite demostrar que los pasos P1 (mover 43 patrones a un
# vocabulario único) y P2 (consumir `Rag::QueryAnalysis`) son neutrales.
#
# Los bloques marcados DEUDA documentan un defecto medido. NO se "arreglan" aquí:
# cambiar su expectativa sin introducir el sustituto es agregar una rama más al
# mismo antipatrón que la fase busca eliminar. Cada uno indica el paso en el que
# su expectativa debe invertirse:
#
#   P3 → identificadores validados contra el vocabulario de la evidencia
#   P4 → identidad de equipo desde metadata (bloqueado por Fase 2)
#
# Los controles negativos de `board_model_name?` / `SERIES_LABEL_PATTERN`
# (hueco 9 de §7.2) ya están cubiertos en answer_safety_processor_test.rb
# ("preserves a connector line that only mentions the board's own model name",
# "preserves a connector line naming a documented SERIE category label",
# "still rejects an invented connector pairing despite the SERIE/digit carve-outs",
# "preserves a connector line whose pin enumeration includes digit-bearing pin
# labels") y no se duplican aquí.
class Rag::RegexCharacterizationTest < ActiveSupport::TestCase
  # BedrockRagService instancia un cliente AWS en el constructor; misma
  # preparación que bedrock_rag_service_test.rb, sin llamadas de red.
  parallelize(workers: 1)

  setup do
    ENV["BEDROCK_KNOWLEDGE_BASE_ID"] = "test-kb-id"
    ENV["AWS_REGION"] = "us-east-1"
  end

  teardown do
    ENV.delete("BEDROCK_KNOWLEDGE_BASE_ID")
    ENV.delete("AWS_REGION")
  end

  # Identificadores verificados en el PDF SEGURIDADES 1.1-1 (plan §2).
  COVERED_IDENTIFIERS = %w[D8 D11 DL27 XC4 XC7 CN7 CN8 CN9 L9 L8 L7].freeze

  # DEUDA · P3 — dos familias sin cobertura, no una.
  UNCOVERED_ALPHA_IDENTIFIERS   = %w[SPM SPH SEG SCE SCC SSH AP SPE PP].freeze
  UNCOVERED_NUMERIC_IDENTIFIERS = %w[37 39 41 12 19].freeze

  # ---------------------------------------------------------------------------
  # Hueco 1 — IDENTIFIER_PATTERN contra los 25 identificadores reales del manual
  # ---------------------------------------------------------------------------

  test "IDENTIFIER_PATTERN reconoce los 11 identificadores con prefijo alfabetico y digito" do
    COVERED_IDENTIFIERS.each do |identifier|
      assert_match Rag::AnswerSafetyProcessor::IDENTIFIER_PATTERN, identifier,
                   "se esperaba cobertura para #{identifier}"
    end
  end

  # DEUDA · P3 — todas las ramas del patron exigen un digito salvo `X...`, asi que
  # los codigos de serie de solo letras del manual quedan fuera del guard.
  test "DEUDA IDENTIFIER_PATTERN no reconoce los 9 codigos de solo letras del manual" do
    UNCOVERED_ALPHA_IDENTIFIERS.each do |identifier|
      assert_no_match Rag::AnswerSafetyProcessor::IDENTIFIER_PATTERN, identifier,
                      "#{identifier} paso a estar cubierto: invertir esta expectativa solo en P3"
    end
  end

  # DEUDA · P3 — ninguna rama admite un numero sin prefijo alfabetico, y EDEL-K3
  # (37/39/41) y ENIER MXL1 (12/19) usan exactamente esa forma como identificador.
  test "DEUDA IDENTIFIER_PATTERN no reconoce los identificadores numericos desnudos" do
    UNCOVERED_NUMERIC_IDENTIFIERS.each do |identifier|
      assert_no_match Rag::AnswerSafetyProcessor::IDENTIFIER_PATTERN, identifier,
                      "#{identifier} paso a estar cubierto: invertir esta expectativa solo en P3"
    end
  end

  # ---------------------------------------------------------------------------
  # Hueco 2 — requires_evidence? con un codigo de solo letras
  # ---------------------------------------------------------------------------

  # DEUDA · P3 — la respuesta correcta del caso tpr50_spm no dispara ninguno de los
  # tres patrones de sensibilidad (identificador / valor con unidad / estado), asi
  # que el contrato fail-closed no aplica.
  test "DEUDA requires_evidence? es false para una atribucion de serie con codigo de solo letras" do
    assert_not Rag::AnswerSafetyProcessor.requires_evidence?(
      "SPM: SERIE PUERTAS CABINA - EXTERIORES."
    )
  end

  # DEUDA · P3 — el efecto agravado: incluso cuando la palabra "LED" si eleva
  # requires_evidence? a true, `reject_unsupported_identifiers` no encuentra ningun
  # identificador que validar, de modo que una atribucion contradicha por la
  # evidencia se entrega intacta.
  test "DEUDA una atribucion SPM contradicha por la evidencia se entrega intacta" do
    answer = "El LED SPM corresponde a la SERIE CERROJOS CABINA."
    evidence = [ { content: "SPM | SERIE PUERTAS CABINA - EXTERIORES" } ]

    assert Rag::AnswerSafetyProcessor.requires_evidence?(answer),
           "la palabra LED deberia elevar requires_evidence?"
    assert_equal answer, processor.call(answer, evidence: evidence, require_cited_evidence: true)
  end

  # ---------------------------------------------------------------------------
  # Hueco 3 — requires_evidence? con identificadores numericos desnudos
  # ---------------------------------------------------------------------------

  # DEUDA · P3 — caso edel_k3_leds.
  test "DEUDA requires_evidence? es false para una atribucion con identificador numerico desnudo" do
    assert_not Rag::AnswerSafetyProcessor.requires_evidence?("37 = PUERTAS HUECO.")
  end

  test "DEUDA una atribucion numerica desnuda contradicha por la evidencia se entrega intacta" do
    answer = "Los LEDs 37, 39 y 41 indican cerrojos de cabina."
    evidence = [ { content: "37 | PUERTAS HUECO\n39 | PUERTAS CABINA\n41 | CERROJOS CABINA Y EXTERIORES" } ]

    assert_equal answer, processor.call(answer, evidence: evidence, require_cited_evidence: true)
  end

  # ---------------------------------------------------------------------------
  # Hueco 4 — EXPLICIT_EQUIPMENT_PATTERN y el ruteo a la tarjeta de desambiguacion
  # ---------------------------------------------------------------------------

  # Reformulaciones que SI nombran fabricante o modelo del manual y aun asi se
  # rutean a la tarjeta, porque el patron exige el digito pegado a las letras y su
  # lista de fabricantes no incluye CTA, Elecmegon, ENIER ni TOKIBAT.
  FALSELY_AMBIGUOUS_QUESTIONS = [
    "En TOKIBAT 2007, ¿qué LED indica que las puertas de cabina están cerradas?",
    "En TOKIBAT 2.007, ¿qué LED indica el hueco cerrado?",
    "En la placa EM 2000, ¿qué LEDs identifican las seguridades?",
    "En EDEL K3, ¿qué indican los LEDs de puertas?",
    "¿Qué LEDs de seguridades documenta CTA?",
    "En las placas de ENIER, ¿qué LED indica el tope de foso?",
    "En la placa NE 300 - LB II, ¿qué LED indica los cerrojos?",
    "En MICONIC LX, ¿qué contactos de seguridad documenta?"
  ].freeze

  CORRECTLY_EXPLICIT_QUESTIONS = [
    "En Elecmegon EM2000, ¿qué LED indica obstáculo?",
    "En Thyssen Serie E, ¿qué LEDs documenta?",
    "En el modelo TPR-50 de Carlos Silva, ¿a qué serie corresponde el LED de puertas?"
  ].freeze

  # DEUDA · P4 (bloqueado por Fase 2) — la ambiguedad debe decidirse por evidencia
  # divergente, no por vocabulario faltante.
  test "DEUDA ocho reformulaciones que nombran el equipo se rutean a desambiguacion" do
    FALSELY_AMBIGUOUS_QUESTIONS.each do |question|
      assert Rag::DeterministicIntent.ambiguous_hardware_query?(question),
             "dejo de rutearse a desambiguacion: invertir esta expectativa solo en P4 — #{question}"
    end
  end

  test "las reformulaciones con fabricante de la lista o con modelo alfanumerico no se desambiguan" do
    CORRECTLY_EXPLICIT_QUESTIONS.each do |question|
      assert_not Rag::DeterministicIntent.ambiguous_hardware_query?(question), question
    end
  end

  # DEUDA · P4 — la razon por la que la cohorte v2 acierta es incidental: en
  # tokibat_dl27_v2 el patron matchea por el codigo del LED preguntado, no por el
  # modelo. Sin ese codigo, la misma pregunta cae en la tarjeta.
  #
  # Este par de tests ES el item de Fase 6 «una pregunta que nombra el modelo sin
  # escribir el codigo del LED no se rutea a la tarjeta de desambiguacion», y esta
  # BLOQUEADO: su gate exige identidad de equipo desde metadata (P4), cuya
  # precondicion es Fase 2 completa — backfill de sidecars aplicado Y KB
  # sincronizado. Mientras el KB no devuelva `section_identity` no hay metadata que
  # consultar, asi que la expectativa correcta no es escribible todavia. Se fija
  # aqui el comportamiento actual; se invierte en P4, no antes.
  test "DEUDA el nombre de modelo TOKIBAT 2007 no satisface EXPLICIT_EQUIPMENT_PATTERN por si mismo" do
    pattern = Rag::DeterministicIntent::EXPLICIT_EQUIPMENT_PATTERN

    assert_no_match pattern, "TOKIBAT 2007"
    assert_no_match pattern, "TOKIBAT 2.007"
    assert_equal "DL27", "En TOKIBAT 2007, ¿qué indica el LED DL27?"[pattern],
                 "el match proviene del identificador preguntado, no del modelo"
  end

  test "DEUDA cuatro de los seis fabricantes de SEGURIDADES no estan en la lista del patron" do
    pattern = Rag::DeterministicIntent::EXPLICIT_EQUIPMENT_PATTERN

    %w[ALTIUS THYSSEN].each { |m| assert_match pattern, m }
    [ "CARLOS SILVA" ].each { |m| assert_match pattern, m }
    %w[CTA ELECMEGON ENIER TOKIBAT].each do |manufacturer|
      assert_no_match pattern, manufacturer,
                      "#{manufacturer} paso a estar reconocido: invertir esta expectativa solo en P4"
    end
  end

  # ---------------------------------------------------------------------------
  # Hueco 5 — MODEL_PATTERN del desambiguador
  # ---------------------------------------------------------------------------

  MODEL_PATTERN_BLIND_SPOTS = [
    "ALTIUS", "ENIER", "ELECMEGON", "CTA",
    "Thyssen Serie E", "NE 300 - LB II", "MICONIC LX", "SMART 001", "TOKIBAT 2007"
  ].freeze

  # DEUDA · P4 — la etiqueta de una opcion no puede depender de la forma lexica del
  # texto; debe venir de metadata de seccion.
  test "DEUDA MODEL_PATTERN no reconoce nueve de los modelos y fabricantes del corpus" do
    MODEL_PATTERN_BLIND_SPOTS.each do |candidate|
      assert_nil candidate[Rag::AmbiguousModelResponder::MODEL_PATTERN],
                 "#{candidate} paso a estar reconocido: invertir esta expectativa solo en P4"
    end
  end

  test "DEUDA MODEL_PATTERN pierde el sufijo de version de EM4000 V1" do
    assert_equal "EM4000", "EM4000 V1"[Rag::AmbiguousModelResponder::MODEL_PATTERN]
  end

  # ---------------------------------------------------------------------------
  # Hueco 6 — divergencia medida entre el patron safety duplicado
  # ---------------------------------------------------------------------------

  # DEUDA · P2 — `rag_retrieval_profile.rb:53` usa `fuera\s+de\s+servicio`;
  # `bedrock_rag_service.rb:991` usa el literal `fuera de servicio`. Con doble
  # espacio o salto de linea la consulta recibe el top_k reducido de
  # safety-critical SIN la directiva STOP-WORK que separa precauciones de
  # detencion obligatoria: menos evidencia y menos contencion a la vez.
  test "ambos patrones safety coinciden con un espaciado simple" do
    text = "Si la puerta no cierra, dejarla fuera de servicio."

    assert safety_profile(text).safety_critical_query?
    assert_not_nil safety_directive(text)
  end

  test "DEUDA con doble espacio el perfil safety se activa pero la directiva STOP-WORK no" do
    text = "Si la puerta no cierra, dejarla fuera  de   servicio."

    assert safety_profile(text).safety_critical_query?
    assert_equal RagRetrievalProfile::SAFETY_CRITICAL_RESULTS,
                 safety_profile(text).number_of_results
    assert_nil safety_directive(text),
               "la divergencia se cerro: invertir esta expectativa solo en P2"
  end

  test "DEUDA con salto de linea el perfil safety se activa pero la directiva STOP-WORK no" do
    text = "Si la puerta no cierra, dejarla fuera\nde servicio."

    assert safety_profile(text).safety_critical_query?
    assert_nil safety_directive(text),
               "la divergencia se cerro: invertir esta expectativa solo en P2"
  end

  # Gate de Fase 6 (plan §5, backend): «`fuera  de  servicio` con doble espacio o
  # salto de linea activa la directiva STOP-WORK y el perfil safety-critical
  # simultaneamente». Es la expectativa INVERSA de los dos DEUDA de arriba.
  #
  # Queda en `skip` a proposito: cerrar la divergencia exige editar
  # `bedrock_rag_service.rb:991` (literal `fuera de servicio` -> `fuera\s+de\s+servicio`),
  # que es el paso P2 de la migracion, no una tarea de test. Cuando P2 lo cierre:
  # quitar el skip aqui y borrar los dos DEUDA de arriba en el mismo commit.
  test "gate Fase 6 el espaciado irregular activa perfil safety y directiva STOP-WORK a la vez" do
    skip "pendiente de P2: bedrock_rag_service.rb:991 usa el literal 'fuera de servicio' " \
         "mientras rag_retrieval_profile.rb:53 usa 'fuera\\s+de\\s+servicio'"

    [ "Si la puerta no cierra, dejarla fuera  de   servicio.",
      "Si la puerta no cierra, dejarla fuera\nde servicio." ].each do |text|
      assert safety_profile(text).safety_critical_query?, text
      assert_not_nil safety_directive(text), text
    end
  end

  # ---------------------------------------------------------------------------
  # Hueco 7 — equivalencia entre las dos instanciaciones de RagRetrievalProfile
  # ---------------------------------------------------------------------------

  # Red de seguridad de P2: `bedrock_rag_service.rb:114` construye el perfil con
  # `entity_sources:` + `question:` y `:1023` solo con `question:`. La
  # consolidacion debe preservar que la clasificacion de intencion no dependa del
  # alcance fijado; si alguna vez divergen, este test lo detecta antes.
  test "exhaustive_query? no depende de entity_sources" do
    questions = [
      "Enumera todas las pruebas de funcionamiento antes de operar",
      "Give me the complete checklist",
      "¿Qué pruebas funcionales previas al uso indica el manual?",
      "¿Cómo pruebo el freno?",
      "En ALTIUS, ¿qué serie indica el LED D8?"
    ]

    questions.each do |question|
      bare = RagRetrievalProfile.new(question: question).exhaustive_query?
      %w[document image_upload].each do |source|
        scoped = RagRetrievalProfile.new(entity_sources: [ source ], question: question).exhaustive_query?
        assert_equal bare, scoped, "divergencia de intencion con entity_sources=#{source}: #{question}"
      end
    end
  end

  test "la directiva de completitud y el perfil de recuperacion clasifican igual la misma pregunta" do
    service = BedrockRagService.new(account: accounts(:legacy))

    [
      [ "Enumera todas las pruebas de funcionamiento antes de operar", true ],
      [ "¿Cómo pruebo el freno?", false ]
    ].each do |question, expected|
      assert_equal expected, RagRetrievalProfile.new(question: question).exhaustive_query?
      directive = service.send(:query_completeness_directive, question)
      assert_equal expected, directive.present?, question
    end
  end

  # ---------------------------------------------------------------------------
  # Hueco 8 — las rutas deterministas no atraviesan AnswerSafetyProcessor
  # ---------------------------------------------------------------------------

  FakeRetrievalService = Struct.new(:chunks) do
    def retrieve_chunks(*, **)
      {
        chunks: chunks,
        retrieval_trace: {
          resolved_scope_s3_uris: [],
          applied_filter_s3_uris: [],
          force_entity_filter: false
        }
      }
    end
  end

  # DEUDA · P3 — el guard se invoca en un unico punto
  # (`bedrock_rag_service.rb:342`, dentro de `BedrockRagService#query`), y el
  # desambiguador retorna antes en el orquestador.
  #
  # Sonda: `DATA_NOT_AVAILABLE` es un marcador de protocolo que la ingesta escribe
  # en el cuerpo de los chunks y que el guard reescribe SIEMPRE a copy localizada
  # (`render_internal_markers`, sin condiciones). Si sobrevive en la respuesta
  # entregada, el guard no corrio.
  test "DEUDA la tarjeta de desambiguacion entrega su etiqueta sin pasar por el guard" do
    responder = Rag::AmbiguousModelResponder.new(
      question: "¿Qué LED se enciende cuando falla?",
      account: accounts(:legacy),
      entity_s3_uris: [],
      entity_sources: [],
      force_entity_filter: false,
      response_locale: :es,
      output_channel: nil,
      rag_service: FakeRetrievalService.new(
        [
          heading_chunk("## EM4000 V1 DATA_NOT_AVAILABLE", 33),
          heading_chunk("## S4 — SAFETY SYSTEM: ARCA III — Diagrama de Series", 52),
          heading_chunk("## S7 — DIAGRAM: MAC 5000 — Esquema de Cadena", 55)
        ]
      )
    )

    result = responder.execute

    assert_includes result[:answer], "DATA_NOT_AVAILABLE",
                    "el guard paso a cubrir la ruta determinista: invertir esta expectativa solo en P3"
    assert_not_includes processor.call(result[:answer], evidence: []), "DATA_NOT_AVAILABLE",
                        "el guard si habria reescrito el marcador de haber corrido"
  end

  # ---------------------------------------------------------------------------
  # Hueco 10 — golden de intencion sobre la cohorte v2 y sus reformulaciones
  # ---------------------------------------------------------------------------

  # Red de seguridad principal de P2: para cada pregunta, el conjunto completo de
  # decisiones de intencion que hoy toman los tres clasificadores activos. Tras
  # consumir `Rag::QueryAnalysis`, este golden debe seguir identico.
  test "golden de intencion de las diez preguntas de la cohorte v2" do
    expected = {
      "altius_d8_d11"               => { ambiguous: false, exhaustive: false, safety: false, schematic: false },
      "tpr50_spm"                   => { ambiguous: false, exhaustive: false, safety: false, schematic: false },
      "cta_sr8p_sph"                => { ambiguous: false, exhaustive: false, safety: false, schematic: false },
      "em2000_leds_seguridad"       => { ambiguous: false, exhaustive: false, safety: false, schematic: false },
      "em4000_obstaculo_conectores" => { ambiguous: false, exhaustive: false, safety: false, schematic: false },
      "edel_k3_leds"                => { ambiguous: false, exhaustive: false, safety: false, schematic: false },
      "tokibat_dl27_v2"             => { ambiguous: false, exhaustive: false, safety: false, schematic: false },
      "enier_mxl1_leds"             => { ambiguous: false, exhaustive: false, safety: false, schematic: false },
      "thyssen_serie_e_leds"        => { ambiguous: false, exhaustive: false, safety: false, schematic: false },
      "elecmegon_obstaculo_ambiguo" => { ambiguous: true,  exhaustive: false, safety: false, schematic: false }
    }

    cases = v2_cohort
    assert_equal expected.keys.sort, cases.pluck("id").sort,
                 "la cohorte v2 cambio de casos; revisar el golden antes de continuar"

    cases.each do |kase|
      assert_equal expected.fetch(kase["id"]), intent_snapshot(kase["question"]), kase["id"]
    end
  end

  test "golden de intencion de las reformulaciones de la cohorte v2" do
    FALSELY_AMBIGUOUS_QUESTIONS.each do |question|
      assert_equal({ ambiguous: true, exhaustive: false, safety: false, schematic: false },
                   intent_snapshot(question), question)
    end

    CORRECTLY_EXPLICIT_QUESTIONS.each do |question|
      assert_equal({ ambiguous: false, exhaustive: false, safety: false, schematic: false },
                   intent_snapshot(question), question)
    end
  end

  # El golden de la cohorte v2 tiene `exhaustive`, `safety` y `schematic` en false
  # para los diez casos: detecta un falso positivo nuevo, pero NO detectaria que P1
  # perdiera una alternativa de un vocabulario. Este golden aporta la polaridad
  # contraria — un representante por vocabulario consolidable — para que mover los
  # patrones no pueda reducir cobertura en silencio.
  test "golden de intencion de polaridad positiva, un representante por vocabulario" do
    {
      # V1 · intencion exhaustiva
      "Enumera todas las pruebas de funcionamiento antes de operar" =>
        { ambiguous: false, exhaustive: true, safety: false, schematic: false },
      "Give me the complete checklist" =>
        { ambiguous: false, exhaustive: true, safety: false, schematic: false },
      # V2 · intencion safety / stop-work
      "¿Cuándo debo detener el trabajo?" =>
        { ambiguous: false, exhaustive: false, safety: true, schematic: false },
      "Si una prueba falla, ¿quién puede reparar la máquina?" =>
        { ambiguous: false, exhaustive: false, safety: true, schematic: false },
      # V4 · hardware generico sin equipo explicito
      "¿Cómo se conectan los cerrojos en las placas de seguridad?" =>
        { ambiguous: true, exhaustive: false, safety: false, schematic: false },
      # V5 · intencion esquematico / bloque de conectores
      "¿Qué conectores visibles aparecen en el bloque -PDCM?" =>
        { ambiguous: false, exhaustive: false, safety: false, schematic: true }
    }.each do |question, snapshot|
      assert_equal snapshot, intent_snapshot(question), question
    end
  end

  # V3 · intencion prueba funcional y checklist de detencion: ambos vocabularios
  # viven en DeterministicIntent y deciden renderer, no top_k.
  test "golden de polaridad positiva de los renderers deterministas" do
    assert Rag::DeterministicIntent.exhaustive_functional_test_query?(
      "¿Qué pruebas funcionales indica el manual y cuáles son los resultados esperados?"
    )
    assert Rag::DeterministicIntent.exhaustive_functional_test_query?(
      "Which functional tests apply and what are the expected results?"
    )
    assert Rag::DeterministicIntent.stop_work_checklist_query?(
      "¿Qué comprobaciones obligan a detener el trabajo?"
    )
    assert Rag::DeterministicIntent.stop_work_checklist_query?(
      "Which checks require stop working?"
    )
  end

  test "ninguna pregunta de la cohorte v2 activa un renderer determinista" do
    v2_cohort.each do |kase|
      question = kase["question"]
      assert_not Rag::DeterministicIntent.exhaustive_functional_test_query?(question), kase["id"]
      assert_not Rag::DeterministicIntent.stop_work_checklist_query?(question), kase["id"]
    end
  end

  private

  def processor
    @processor ||= Rag::AnswerSafetyProcessor.new(locale: :es)
  end

  def safety_profile(text)
    RagRetrievalProfile.new(entity_sources: [ "document" ], question: text)
  end

  def safety_directive(text)
    @service ||= BedrockRagService.new(account: accounts(:legacy))
    @service.send(:query_safety_directive, text)
  end

  def intent_snapshot(question)
    profile = RagRetrievalProfile.new(entity_sources: [], question: question)
    {
      ambiguous:  Rag::DeterministicIntent.ambiguous_hardware_query?(question),
      exhaustive: profile.exhaustive_query?,
      safety:     profile.safety_critical_query?,
      schematic:  profile.schematic_block_query?
    }
  end

  def v2_cohort
    @v2_cohort ||= JSON.parse(
      Rails.root.join("script/fixtures/rag_seguridades_pilot_10q_v2.json").read
    ).fetch("cases")
  end

  def heading_chunk(heading, page)
    {
      content: heading,
      location_uri: "s3://bucket/chunk_p#{page}_1.txt",
      original_source_uri: "s3://bucket/seguridades.pdf",
      metadata: {}
    }
  end
end
