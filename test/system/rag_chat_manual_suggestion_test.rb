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
      assert_includes html, "Usar este manual"
      assert_includes html, "manual-focus-action"
      assert_not_includes html, 'data-focused="true"'
      assert_not_includes html, ">Quitar foco<"
      assert_not_includes payload[:answer], "Tu biblioteca"
    end

    sections = all(".manual-suggestion", visible: :all)
    assert_equal 2, sections.size
    sections.each do |section|
      articles = section.all("article", visible: :all)
      assert_equal 3, articles.size
      assert_equal 3, section.all("button", text: "Usar este manual", visible: :all).size
      assert_equal "none", section["data-selected"]
      assert_equal "true", section["data-tie-at-top"]
      articles.each do |article|
        assert_equal "false", article["data-focused"]
      end
    end
  end

  test "a card tap shows focus and a denied tap does not select the manual" do
    page.current_window.resize_to(390, 844)
    install_pin_fetch(ok: true, message: "Manual enfocado")
    render_assistant_answer(two_card_payload)

    assert_equal 0, evaluate_script("window.pinFetches")
    assert_equal "none", find(".manual-suggestion", visible: :all)["data-selected"]

    execute_script("document.querySelectorAll('.manual-focus-action')[0].click()")

    assert_selector ".manual-focus-status", text: "Manual enfocado", visible: :all
    assert_equal "none", find(".manual-suggestion", visible: :all)["data-selected"]
    assert_equal 1, all("button", text: "Quitar foco", visible: :all).size
    assert_equal 1, all("button", text: "Usar este manual", visible: :all).size
    request = JSON.parse(evaluate_script("JSON.stringify(window.lastPinRequest)"))
    assert_equal "POST", request["method"]
    assert_includes request["body"], "kb_document_id"
    assert_includes request["body"], "uid-manual-a"
    assert_not_includes request["body"], "knowledge_scope"
    assert_not_includes request["body"], "authorized"

    install_pin_fetch(ok: false, message: "Este manual ya no está disponible.")
    execute_script("document.querySelectorAll('.manual-focus-action')[1].click()")

    assert_selector ".manual-focus-status", text: "Este manual ya no está disponible.", visible: :all
    assert_equal 1, all("article[data-focused='true']", visible: :all).size
    assert_equal "none", find(".manual-suggestion")["data-selected"]
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

  def two_card_payload
    {
      answer: "La puerta puede quedar sin cierre.",
      citations: [],
      response_locale: "es",
      manual_suggestion: {
        tie_at_top: true,
        selected_document_uid: nil,
        correlation_id: "query:focus",
        focus_action: "Usar este manual",
        focus_clear: "Quitar foco",
        focus_status: "Manual enfocado",
        focus_invalid: "No pude seleccionar este manual.",
        cards: [
          card("Manual A", "BRAND_ONLY", "tenant_private", "Tu biblioteca", id: 11),
          card("Manual B", "BRAND_ONLY", "tenant_private", "Tu biblioteca", id: 12)
        ]
      }
    }
  end

  def install_pin_fetch(ok:, message:)
    payload = ok ? { status: "focused", message: message } : { error: message }
    execute_script(<<~JAVASCRIPT, payload.to_json, ok)
      (function (json, success) {
        const body = JSON.parse(json)
        window.pinFetches = window.pinFetches || 0
        window.fetch = (url, options) => {
          window.pinFetches += 1
          window.lastPinRequest = {
            url: String(url),
            method: options && options.method,
            body: options && options.body
          }
          return Promise.resolve({
            ok: success,
            status: success ? 200 : 404,
            json: async () => body
          })
        }
      })(arguments[0], arguments[1])
    JAVASCRIPT
  end

  def card(name, label, scope, provenance, id: nil)
    text = if label == "EXACT_DESIGNATOR"
      "el documento coincide con el modelo/designador indicado"
    else
      "manual de la misma marca; compatibilidad con este equipo no confirmada"
    end
    {
      document_uid: "uid-#{name.parameterize}",
      kb_document_id: id || name.hash.abs,
      display_name: name,
      label: label,
      text: text,
      knowledge_scope: scope,
      provenance: provenance,
      focused: false
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
