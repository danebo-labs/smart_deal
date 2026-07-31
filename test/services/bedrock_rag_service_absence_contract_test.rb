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

    assert_operator answer.index("no especifica"), :>, BedrockRagService::ABSENCE_LEAD_CHARS
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

  private

  def normalize(answer)
    BedrockRagService.allocate.send(:normalize_absence_semantics, answer)
  end
end
