# frozen_string_literal: true

require "test_helper"

class Rag::PhotoIntentRendererTest < ActiveSupport::TestCase
  ANALYSIS = "Se ve un conjunto de cabina y puerta."

  test "a hidden target leads with the missing detail and the standalone reading" do
    missing = "primer plano de las fijaciones de cables con sus resortes"
    prose = Rag::PhotoIntentRenderer.prose(
      reading: { target_visible: false, missing_view_or_detail: missing, analysis: ANALYSIS },
      locale: :es
    )

    assert prose.start_with?(I18n.t("rag.photo_intent.target_hidden", missing: missing, locale: :es))
    assert_includes prose, missing
    assert_includes prose, ANALYSIS
    assert_not_includes prose, "No encontré"
    assert_not prose.start_with?("La documentación recuperada")
  end

  test "a hidden target with no missing detail asks for a close-up" do
    prose = Rag::PhotoIntentRenderer.prose(
      reading: { "target_visible" => false, "missing_view_or_detail" => "  ", analysis: ANALYSIS },
      locale: :es
    )

    assert prose.start_with?(I18n.t("rag.photo_intent.target_hidden_default", locale: :es))
    assert_includes prose, "primer plano"
    assert_includes prose, ANALYSIS
  end

  test "a missing or invalid target is uncertain and never the hidden sentence" do
    [ nil, "maybe" ].each do |visible|
      prose = Rag::PhotoIntentRenderer.prose(
        reading: { target_visible: visible, analysis: ANALYSIS },
        locale: :es
      )

      assert_includes prose, I18n.t("rag.photo_intent.target_uncertain", locale: :es)
      assert_includes prose, I18n.t("rag.photo_intent.close_up_request", locale: :es)
      assert_not_includes prose, "Esta foto no muestra"
      assert_includes prose, ANALYSIS
    end
  end

  test "a visible target keeps a missing detail as its own sentence" do
    prose = Rag::PhotoIntentRenderer.prose(
      reading: { target_visible: true, missing_view_or_detail: "falta la placa", analysis: ANALYSIS },
      locale: :es
    )

    assert prose.start_with?(I18n.t("rag.photo_intent.target_visible", locale: :es))
    assert_includes prose, "falta la placa"
    assert_not_includes prose, I18n.t("rag.photo_intent.target_uncertain", locale: :es)
  end

  test "english uncertain prose uses the close-up request" do
    prose = Rag::PhotoIntentRenderer.prose(
      reading: { target_visible: nil, analysis: "A car and door are visible." },
      locale: :en
    )

    assert_includes prose, I18n.t("rag.photo_intent.target_uncertain", locale: :en)
    assert_includes prose, I18n.t("rag.photo_intent.close_up_request", locale: :en)
    assert_includes prose, "A car and door are visible."
  end
end
