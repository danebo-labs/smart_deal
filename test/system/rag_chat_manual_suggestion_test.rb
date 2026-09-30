# frozen_string_literal: true

require "application_system_test_case"

class RagChatManualSuggestionTest < ApplicationSystemTestCase
  include Warden::Test::Helpers

  setup do
    login_as users(:one), scope: :user
    visit root_path
  end

  teardown do
    Warden.test_reset!
  end

  test "brand cards render in the answer bubble and do not pin or choose one" do
    payload = {
      answer: "La puerta puede quedar sin cierre por el final de carrera.",
      citations: [],
      response_locale: "es",
      manual_suggestion: {
        tie_at_top: true,
        selected_document_uid: nil,
        message: nil,
        cards: [
          card("Manual Otis A", "BRAND_ONLY", "tenant_private", "Tu biblioteca"),
          card("Manual Otis B", "BRAND_ONLY", "tenant_private", "Tu biblioteca"),
          card("Manual general", "EXACT_DESIGNATOR", "danebo_general", "Biblioteca general de Danebo")
        ]
      }
    }

    [ [ 1400, 1400 ], [ 390, 844 ] ].each do |width, height|
      page.current_window.resize_to(width, height)
      html = render_assistant_answer(payload)

      assert_includes html, "manual-suggestion"
      assert_includes html, "manual de la misma marca; compatibilidad con este equipo no confirmada"
      assert_includes html, "el documento coincide con el modelo/designador indicado"
      assert_includes html, "Tu biblioteca"
      assert_includes html, "Biblioteca general de Danebo"
      assert_includes html, 'data-tie-at-top="true"'
      assert_includes html, 'data-selected="none"'
      assert_not_includes html, "<button"
      assert_not_includes payload[:answer], "Tu biblioteca"
    end

    sections = all(".manual-suggestion", visible: :all)
    assert_equal 2, sections.size
    sections.each do |section|
      assert_equal 3, section.all("article", visible: :all).size
      assert_empty section.all("button", visible: :all)
      assert_equal "none", section["data-selected"]
      assert_equal "true", section["data-tie-at-top"]
    end
  end

  test "a symptom answer does not render suggestion cards" do
    html = render_assistant_answer(
      answer: "Revisá el final de carrera de la puerta.",
      citations: [],
      response_locale: "es"
    )

    assert_not_includes html, "manual-suggestion"
    assert_not_includes html, "No encontré un manual claramente asociado"
  end

  private

  def card(name, label, scope, provenance)
    text = if label == "EXACT_DESIGNATOR"
      "el documento coincide con el modelo/designador indicado"
    else
      "manual de la misma marca; compatibilidad con este equipo no confirmada"
    end
    {
      document_uid: "uid-#{name.parameterize}",
      display_name: name,
      label: label,
      text: text,
      knowledge_scope: scope,
      provenance: provenance
    }
  end

  def render_assistant_answer(payload)
    evaluate_script(<<~JAVASCRIPT, payload.to_json)
      (function (json) {
        const data = JSON.parse(json)
        const element = document.querySelector('[data-controller~="rag-chat"]')
        const controller = window.Stimulus.getControllerForElementAndIdentifier(element, "rag-chat")
        controller.renderAssistantAnswer(data)
        const rows = element.querySelectorAll(".chat-row-assistant")
        return rows[rows.length - 1].querySelector(".chat-message").innerHTML
      })(arguments[0])
    JAVASCRIPT
  end
end
