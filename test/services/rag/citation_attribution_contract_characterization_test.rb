# frozen_string_literal: true

require "test_helper"

class Rag::CitationAttributionContractCharacterizationTest < ActiveSupport::TestCase
  THYSSEN_QUESTION = "En Thyssen-E, ¿qué LED señala una condición normal y cuál un fallo?"
  THYSSEN_VISIBLE_ANSWER = <<~ANSWER.chomp
    En el sistema Thyssen-E (Serie E), la documentación identifica tres LEDs de supervisión principales:

    **LED L9** — supervisa la SERIE SEGURIDADES PRINCIPALES
    **LED L8** — supervisa la SERIE PUERTAS EXTERIORES
    **LED L7** — supervisa la SERIE CERROJOS EXTERIORES - CABINA

    Sin embargo, la documentación recuperada **no especifica explícitamente la lógica de encendido/apagado** de estos LEDs. Es decir, no define si un LED encendido indica condición normal o fallo, ni si apagado indica lo contrario.

    Para determinar qué estado (encendido o apagado) corresponde a operación normal y cuál a fallo, se requiere verificación en campo contra el esquema eléctrico detallado o la placa de control específica del sistema[1]. **Nota:** La documentación menciona que en otras placas de control (como la NE 300 – LB II), los LEDs de serie (ES, DFC, DW) están descritos como "rojo" y se entiende que un LED encendido indica interrupción en la serie correspondiente. Si el sistema Thyssen-E utiliza la misma lógica, un LED encendido señalaría fallo. Pero esto debe confirmarse en el equipo específico[2].

    **El documento no incluye este dato** — el estado solicitado no está documentado. **Verificar en campo o en el esquema completo**.
  ANSWER
  THYSSEN_INTERNAL_ANSWER = THYSSEN_VISIBLE_ANSWER
    .sub("**El documento no incluye este dato**", "**DATA_NOT_AVAILABLE**")
    .sub("**Verificar en campo o en el esquema completo**", "**REQUIRES_FIELD_VERIFICATION**")
    .freeze
  THYSSEN_CITATIONS = [
    {
      content: THYSSEN_INTERNAL_ANSWER,
      location: { key: "chunk_91.txt" },
      metadata: { "section_identity" => "THYSSEN", "page_number" => 93 }
    },
    {
      content: "NE 300 – LB II. Los LEDs ES, DFC y DW están descritos como rojo.",
      location: { key: "chunk_65.txt" },
      metadata: { "section_identity" => "OTIS", "page_number" => 67 }
    }
  ].freeze
  EDEL_RAW_ANSWER = <<~ANSWER.chomp
    # Respuesta

    En la placa EDEL-K3, los LEDs 37, 39 y 41 son indicadores de fallo de serie que señalan defectos en circuitos de seguridad específicos:

    **LED 37:** "PUERTAS HUECO" [1] — indica fallo en la serie de puertas de hueco.

    **LED 39:** "PUERTAS CABINA" [2] — indica fallo en la serie de puertas de cabina.

    **LED 41:** "CERROJOS CABINA Y EXTERIORES" [3] — indica fallo en la serie de cerrojos de cabina y exteriores.

    El documento identifica estos LEDs como indicadores de fallo pero no especifica su lógica de encendido/apagado (cuándo se encienden durante operación normal o durante una falta). DATA_NOT_AVAILABLE respecto a las condiciones exactas de activación de cada LED.
  ANSWER

  class FakeRagService
    def initialize(chunks)
      @chunks = chunks
    end

    def retrieve_chunks(*)
      {
        chunks: @chunks,
        retrieval_trace: {
          vector_search_configuration: { "number_of_results" => 12 }
        }
      }
    end
  end

  class FakeGenerator
    def initialize(answer)
      @answer = answer
    end

    def query(*)
      @answer
    end
  end

  class FakeExpander
    def neighbor_chunk(**)
      nil
    end
  end

  test "generic path preserves the archived foreign-family paragraph byte for byte" do
    rendered = Rag::AnswerSafetyProcessor.new(locale: :es).call(
      THYSSEN_INTERNAL_ANSWER,
      evidence: THYSSEN_CITATIONS,
      require_cited_evidence: true
    )

    assert_equal %w[THYSSEN OTIS], THYSSEN_CITATIONS.pluck(:metadata).pluck("section_identity")
    assert_equal THYSSEN_VISIBLE_ANSWER, rendered
    assert_includes rendered, "NE 300 – LB II"
    assert_includes rendered, "misma lógica"
  end

  test "structured route currently abstains on marker two with one evidence chunk" do
    chunk = {
      content: "Afirmación técnica",
      metadata: {
        "canonical_name" => "Manual",
        "original_source_uri" => "s3://test-bucket/manual.pdf",
        "page_number" => 1
      },
      location_uri: "s3://test-bucket/chunk.txt",
      chunk_sha256: "characterization-chunk",
      rank: 1
    }
    route = Rag::StructuredEvidenceRoute.new(
      question: "¿Qué indica el LED ABC12?",
      account: accounts(:legacy),
      entity_s3_uris: [ "s3://test-bucket/manual.pdf" ],
      entity_sources: [ "document" ],
      force_entity_filter: true,
      response_locale: :es,
      rag_service: FakeRagService.new([ chunk ]),
      generator: FakeGenerator.new("Afirmación técnica [2]"),
      expander: FakeExpander.new
    )

    outcome = route.execute

    assert_equal :abstained, outcome.status
    assert_empty outcome.result[:citations]
    assert_equal :citation_failure, outcome.result.dig(:diagnostics, :outcome_reason)
  end

  test "citation processor currently drops markers with no citation entry" do
    references = Bedrock::CitationProcessor.new.build_numbered_references(
      [ THYSSEN_CITATIONS.first ],
      "Primera [1]. Segunda [2]. Tercera [3]."
    )

    assert_equal [ 1 ], references.pluck(:number)
  end

  test "answer safety accepts foreign-family prose present in flattened evidence" do
    paragraph = "La placa NE 300 – LB II usa los LEDs DFC y DW. [2]"
    processed = Rag::AnswerSafetyProcessor.new(locale: :es).call(
      paragraph,
      evidence: [ { content: "La placa NE 300 – LB II usa los LEDs DFC y DW." } ],
      require_cited_evidence: true
    )

    assert_equal paragraph, processed
  end

  test "current rubric passes the archived Thyssen answer without penalty" do
    evaluation = evaluator(
      "script/fixtures/rag_seguridades_rubric.json",
      id: "thyssen_e_led",
      answer: THYSSEN_VISIBLE_ANSWER,
      citations: [ THYSSEN_CITATIONS.first ]
    )
    result = evaluation.fetch("cases").find { |item| item["id"] == "thyssen_e_led" }

    assert_equal true, result["passed"]
    assert_equal false, result.dig("penalized", 0, "matched")
  end

  test "current Edel result fails citation gate while raw answer satisfies all required checks" do
    archived = evaluator(
      "script/fixtures/rag_seguridades_pilot_10q_v2.json",
      id: "edel_k3_leds",
      answer: "El documento no incluye este dato",
      citations: []
    ).fetch("cases").find { |item| item["id"] == "edel_k3_leds" }
    raw = evaluator(
      "script/fixtures/rag_seguridades_pilot_10q_v2.json",
      id: "edel_k3_leds",
      answer: EDEL_RAW_ANSWER,
      citations: [ { number: 1 } ]
    ).fetch("cases").find { |item| item["id"] == "edel_k3_leds" }

    assert_equal false, archived["passed"]
    assert_equal false, archived["citation_passed"]
    assert raw["required"].all? { |check| check["matched"] }
    assert_equal false, raw.dig("penalized", 0, "matched")
  end

  private

  def evaluator(rubric_path, id:, answer:, citations:)
    rubric = JSON.parse(Rails.root.join(rubric_path).read)
    payload = {
      "run_id" => "characterization",
      "results" => [ { "id" => id, "answer" => answer, "citations" => citations } ]
    }
    Rag::BenchmarkRubricEvaluator.new(rubric: rubric, payload: payload).evaluate
  end
end
