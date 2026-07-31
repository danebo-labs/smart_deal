# frozen_string_literal: true

require "test_helper"

class BedrockRagServiceAbsenceContractTest < ActiveSupport::TestCase
  LEGACY_TAIL =
    "**DATA_NOT_AVAILABLE** — el dato solicitado no está documentado; requiere verificación en campo."

  test "lead-scoped absence appends the legacy tail today" do
    answer = "La documentación no especifica la condición solicitada."

    assert_equal "#{answer}\n\n#{LEGACY_TAIL}", normalize(answer)
  end

  test "an absence phrase past ABSENCE_LEAD_CHARS is ignored today" do
    answer = "#{"Respuesta documentada. " * 15}El manual no especifica la condición restante."

    assert_operator answer.index("no especifica"), :>, BedrockRagService::LEGACY_ABSENCE_LEAD_CHARS
    assert_same answer, normalize(answer)
  end

  test "an existing sentinel is never double-marked" do
    [
      "La documentación no especifica el dato. DATA_NOT_AVAILABLE",
      "La documentación no especifica el dato. REQUIRE_FIELD_VERIFICATION"
    ].each do |answer|
      assert_same answer, normalize(answer)
    end
  end

  test "a grounded answer with no absence vocabulary is returned unchanged" do
    answer = "La placa ZR7-K1 documenta la etiqueta SERIE ZETA HUECO."

    assert_same answer, normalize(answer)
  end

  test "blank and nil answers are returned unchanged" do
    assert_nil normalize(nil)
    assert_same empty = +"", normalize(empty)
  end

  test "the legacy tail is fully localized for the en locale" do
    answer = "The document does not specify the requested condition."

    normalized = I18n.with_locale(:en) { normalize(answer) }

    assert_equal(
      "#{answer}\n\n**DATA_NOT_AVAILABLE** — " \
        "the requested information is not documented; field verification is required.",
      normalized
    )
  end

  test "partial absence sharing a requested relation appends the partial rendering" do
    question = "¿Cuándo se enciende el LED DL91 en condición normal y en fallo?"
    answer = "La placa ZR7-K1 identifica el LED DL91.\n\n" \
      "El documento no especifica la condición normal ni el estado en fallo."

    normalized = normalize(answer, question:, partial_contract: true)

    assert_includes normalized, I18n.t("rag.absence_partial_contract", locale: :es)
    assert_not_includes normalized, LEGACY_TAIL
  end

  test "total absence in the leading fragment keeps the legacy rendering byte-for-byte in es" do
    answer = "La documentación no especifica la condición solicitada."

    assert_equal(
      "#{answer}\n\n#{LEGACY_TAIL}",
      normalize(answer, question: "¿Cuál es la condición normal?", partial_contract: true)
    )
  end

  test "an incidental sub-absence that shares no requested relation is not marked" do
    question = "¿En qué conector está documentada la señal XQ22?"
    answer = "La señal ZR7-K1 está documentada en el conector XQ22.\n\n" \
      "El manual no especifica la condición normal de otra etiqueta."

    assert_same answer, normalize(answer, question:, partial_contract: true)
  end

  test "idempotency running the transform twice is a fixed point" do
    question = "¿Cuándo se enciende el LED L4 en condición normal?"
    answer = "El esquema identifica el LED L4.\n\nNo especifica la condición normal."

    once = normalize(answer, question:, partial_contract: true)

    assert_equal once, normalize(once, question:, partial_contract: true)
  end

  test "flag off is byte-identical to the legacy behaviour" do
    fixtures = [
      [ "La documentación no especifica la condición solicitada.", :es ],
      [ "#{"Respuesta documentada. " * 15}El manual no especifica la condición restante.", :es ],
      [ "No se especifica el dato. DATA_NOT_AVAILABLE", :es ],
      [ "No se especifica el dato. REQUIRE_FIELD_VERIFICATION", :es ],
      [ "La placa ZR7-K1 documenta la etiqueta SERIE ZETA HUECO.", :es ],
      [ nil, :es ],
      [ "", :es ],
      [ "The document does not specify the requested condition.", :en ]
    ]

    fixtures.each do |answer, locale|
      expected = I18n.with_locale(locale) { normalize(answer) }
      actual = normalize(
        answer,
        question: "¿Cuándo se enciende el LED DL91 en condición normal?",
        locale:,
        partial_contract: false
      )
      expected.nil? ? assert_nil(actual) : assert_equal(expected, actual)
    end
  end

  test "the partial rendering carries no digit and no identifier-shaped token" do
    [ :es, :en ].each do |locale|
      internal = I18n.t("rag.absence_partial_contract", locale:)
      rendered = Rag::AnswerSafetyProcessor.new(locale:).call(internal, evidence: [])

      assert_no_match(/\d/, rendered)
      assert_no_match(Rag::AnswerSafetyProcessor::IDENTIFIER_PATTERN, rendered)
      assert_no_match(Rag::AnswerSafetyProcessor::EVIDENCE_SENSITIVE_VALUE_PATTERN, rendered)
      assert_no_match(Rag::AnswerSafetyProcessor::EVIDENCE_SENSITIVE_STATE_PATTERN, rendered)
      assert_no_match(Rag::AnswerSafetyProcessor::COMPONENT_CODE_PATTERN, rendered)
    end
  end

  test "es and en renderings localize both sentinels" do
    [ :es, :en ].each do |locale|
      internal = I18n.t("rag.absence_partial_contract", locale:)
      rendered = Rag::AnswerSafetyProcessor.new(locale:).call(internal, evidence: [])

      assert_no_match(BedrockRagService::ABSENCE_MARKER_PATTERN, rendered)
      assert_includes rendered, I18n.t("rag.data_not_available", locale:)
      assert_includes rendered, I18n.t("rag.requires_field_verification", locale:)
    end
  end

  test "the environment flag wires the partial contract default" do
    answer = "La placa ZR7-K1 identifica el LED DL91.\n\n" \
      "El documento no especifica la condición normal."

    with_partial_contract("true") do
      assert_includes(
        normalize(answer, question: "¿Cuál es la condición normal?"),
        I18n.t("rag.absence_partial_contract", locale: :es)
      )
    end
  end

  private

  def normalize(answer, **kwargs)
    BedrockRagService.allocate.send(:normalize_absence_semantics, answer, **kwargs)
  end

  def with_partial_contract(value)
    original = ENV.fetch("RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED", nil)
    ENV["RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED"] = value
    yield
  ensure
    if original.nil?
      ENV.delete("RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED")
    else
      ENV["RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED"] = original
    end
  end
end
