# frozen_string_literal: true

require "test_helper"

class Rag::CitationAttributionGuardTest < ActiveSupport::TestCase
  THYSSEN_QUESTION = "En Thyssen-E, ¿qué LED señala una condición normal y cuál un fallo?"
  THYSSEN_ANSWER = <<~ANSWER.chomp
    En el sistema Thyssen-E (Serie E), la documentación identifica tres LEDs de supervisión principales:

    **LED L9** — supervisa la SERIE SEGURIDADES PRINCIPALES
    **LED L8** — supervisa la SERIE PUERTAS EXTERIORES
    **LED L7** — supervisa la SERIE CERROJOS EXTERIORES - CABINA

    Sin embargo, la documentación recuperada **no especifica explícitamente la lógica de encendido/apagado** de estos LEDs. Es decir, no define si un LED encendido indica condición normal o fallo, ni si apagado indica lo contrario.

    Para determinar qué estado (encendido o apagado) corresponde a operación normal y cuál a fallo, se requiere verificación en campo contra el esquema eléctrico detallado o la placa de control específica del sistema[1]. **Nota:** La documentación menciona que en otras placas de control (como la NE 300 – LB II), los LEDs de serie (ES, DFC, DW) están descritos como "rojo" y se entiende que un LED encendido indica interrupción en la serie correspondiente. Si el sistema Thyssen-E utiliza la misma lógica, un LED encendido señalaría fallo. Pero esto debe confirmarse en el equipo específico[2].

    **El documento no incluye este dato** — el estado solicitado no está documentado. **Verificar en campo o en el esquema completo**.
  ANSWER
  THYSSEN_EXPECTED = <<~ANSWER.chomp
    En el sistema Thyssen-E (Serie E), la documentación identifica tres LEDs de supervisión principales:

    **LED L9** — supervisa la SERIE SEGURIDADES PRINCIPALES
    **LED L8** — supervisa la SERIE PUERTAS EXTERIORES
    **LED L7** — supervisa la SERIE CERROJOS EXTERIORES - CABINA

    Sin embargo, la documentación recuperada **no especifica explícitamente la lógica de encendido/apagado** de estos LEDs. Es decir, no define si un LED encendido indica condición normal o fallo, ni si apagado indica lo contrario.

    Para determinar qué estado (encendido o apagado) corresponde a operación normal y cuál a fallo, se requiere verificación en campo contra el esquema eléctrico detallado o la placa de control específica del sistema[1].

    **El documento no incluye este dato** — el estado solicitado no está documentado. **Verificar en campo o en el esquema completo**.
  ANSWER

  setup do
    @original_flag = ENV.fetch("RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED", nil)
    ENV["RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED"] = "true"
  end

  teardown do
    if @original_flag.nil?
      ENV.delete("RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED")
    else
      ENV["RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED"] = @original_flag
    end
  end

  test "drops the OTIS segment from the archived Thyssen answer byte exactly" do
    result = guard(
      THYSSEN_QUESTION,
      citations("THYSSEN", "OTIS")
    ).call(THYSSEN_ANSWER)

    assert_equal THYSSEN_EXPECTED, result.answer
    assert_equal 1, result.dropped_segments.size
    assert result.dropped_segments.first.start_with?(". **Nota:**")
    assert_equal [ "THYSSEN" ], result.anchors
    assert_equal %w[THYSSEN OTIS], result.identities
  end

  test "is inert when only one identity is cited" do
    answer = "Dato Thyssen [1]."

    result = guard("En Thyssen-E, ¿qué indica?", citations("THYSSEN")).call(answer)

    assert_equal answer, result.answer
    assert_not result.dropped_any?
  end

  test "is inert and logs when the question names none of three identities" do
    answer = "Cerrojos documentados [1]. Otra evidencia [2]."

    log = capture_logs do
      result = guard(
        "¿Cómo se conectan los cerrojos?",
        citations("HATS - ASOCIADOS", "OTIS", "THYSSEN")
      ).call(answer)
      assert_equal answer, result.answer
      assert_not result.dropped_any?
    end

    assert_includes log, "Rag::CitationAttributionGuard: anchor_missing"
  end

  test "keeps both families when the question names both" do
    answer = "Dato Thyssen [1]. Dato Otis [2]."

    result = guard(
      "Compare THYSSEN con OTIS",
      citations("THYSSEN", "OTIS")
    ).call(answer)

    assert_equal answer, result.answer
    assert_not result.dropped_any?
    assert_equal %w[THYSSEN OTIS], result.anchors
  end

  test "keeps a mixed marker run and drops only purely foreign segments" do
    answer = "Mixto [1][3]. Foráneo tres [3]. Ancla dos [2]. Foráneo cuatro [4]."

    result = guard(
      "Compare THYSSEN con OTIS",
      citations("THYSSEN", "OTIS", "EDEL", "ORONA")
    ).call(answer)

    assert_includes result.answer, "Mixto [1][3]"
    assert_includes result.answer, "Ancla dos [2]"
    assert_not_includes result.answer, "Foráneo tres"
    assert_not_includes result.answer, "Foráneo cuatro"
    assert_equal 2, result.dropped_segments.size
  end

  test "keeps a segment whose marker has no citation entry" do
    answer = "Dato Thyssen [1]. Marcador desconocido [5]."

    result = guard(
      "En THYSSEN, ¿qué indica?",
      citations("THYSSEN", "OTIS")
    ).call(answer)

    assert_equal answer, result.answer
    assert_not result.dropped_any?
  end

  test "is inert when section identities are blank or absent" do
    answer = "Primero [1]. Segundo [2]."
    citation_set = [
      { metadata: { "section_identity" => "" } },
      { "metadata" => { "section_identity" => nil } }
    ]

    result = guard("En THYSSEN, ¿qué indica?", citation_set).call(answer)

    assert_equal answer, result.answer
    assert_empty result.identities
  end

  test "reports no attributed claims when every marked segment is foreign" do
    result = guard(
      "En OTIS, ¿qué indica?",
      citations("THYSSEN", "OTIS")
    ).call("Dato exclusivamente Thyssen [1]")

    assert result.dropped_any?
    assert_equal "", result.answer
    assert_not result.attributed_claims?
  end

  test "flag off preserves the archived Thyssen answer byte identical" do
    ENV["RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED"] = "false"

    result = guard(THYSSEN_QUESTION, citations("THYSSEN", "OTIS")).call(THYSSEN_ANSWER)

    assert_equal THYSSEN_ANSWER, result.answer
    assert_not result.dropped_any?
  end

  test "seam repair removes a duplicate sentence terminator" do
    repaired = guard("", []).send(:repair_seam, "Texto.", ". Más texto")

    assert_equal " Más texto", repaired
  end

  test "seam repair bounds multiple newlines to a paragraph break" do
    repaired = guard("", []).send(:repair_seam, "Texto", "\n\n\n\nMás texto")

    assert_equal "\n\nMás texto", repaired
  end

  test "dropping the first segment leaves no orphan punctuation" do
    result = guard(
      "En THYSSEN, ¿qué indica?",
      citations("THYSSEN", "OTIS")
    ).call("Dato Otis[2]Dato Thyssen[1]")

    assert_equal "Dato Thyssen[1]", result.answer
    assert_not result.answer.start_with?(".", ",", ";", ":")
  end

  test "separate instances do not leak citation identities across accounts" do
    first = guard("En THYSSEN", citations("THYSSEN", "OTIS")).call("T [1]. O [2].")
    second = guard("En EDEL", citations("EDEL", "ORONA")).call("E [1]. O [2].")

    assert_equal [ "THYSSEN" ], first.anchors
    assert_equal %w[THYSSEN OTIS], first.identities
    assert_equal [ "EDEL" ], second.anchors
    assert_equal %w[EDEL ORONA], second.identities
    assert_not_includes second.identities, "THYSSEN"
  end

  test "names identity with accent folding and separator tolerance" do
    assert Rag::CitationAttributionGuard.names?("En Thyssen-E, revise el equipo", "THYSSEN")
    assert_not Rag::CitationAttributionGuard.names?("En Thyssen-E, revise el equipo", "OTIS")
    assert Rag::CitationAttributionGuard.names?("Manual de Carlos Silva", "CARLOS SILVA")
    assert_not Rag::CitationAttributionGuard.names?("Sistema AB", "AB")
  end

  private

  def citations(*identities)
    identities.map do |identity|
      {
        content: "Contenido #{identity}",
        location: { key: "#{identity.parameterize}.txt" },
        metadata: { "section_identity" => identity }
      }
    end
  end

  def guard(question, citation_set)
    Rag::CitationAttributionGuard.new(question: question, citations: citation_set)
  end

  def capture_logs
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)
    yield
    output.string
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end
end
