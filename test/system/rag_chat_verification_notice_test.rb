# frozen_string_literal: true

require "application_system_test_case"

# Guardrail del piloto (decisión #8, componente A —
# docs/rag/plan_ciclo4_ajuste_final_2026-08-03.md Fase 3): aviso estático de
# verificación en TODAS las respuestas del chat web, vivo en la capa de
# presentación (nunca en el string `answer` del JSON — E7). Ejercita el
# controlador Stimulus real ya montado por `visit root_path` (mismo patrón que
# test/system/rag_evidence_cards_test.rb), sin red ni Bedrock.
class RagChatVerificationNoticeTest < ApplicationSystemTestCase
  include Warden::Test::Helpers

  NOTICE_CLASS = "answer-verification-notice"

  setup do
    login_as users(:one), scope: :user
    visit root_path
  end

  teardown do
    Warden.test_reset!
  end

  test "the notice renders on the assistant bubble but the answer string never carries it" do
    answer_text = "En TW1: el LED SPM indica falla en la serie de puertas [1]."

    bubble_html = render_assistant_answer(answer: answer_text, citations: [])

    assert_match(/#{NOTICE_CLASS}/, bubble_html)
    assert_match(/verifica cualquier acci[oó]n sobre seguridades contra el manual/i, bubble_html)
    assert_not_includes answer_text, "verifica"
    assert_not_includes answer_text, NOTICE_CLASS
  end

  test "the notice appears identically across repeated answers, always outside the answer HTML" do
    2.times do |i|
      bubble_html = render_assistant_answer(answer: "Respuesta ##{i} sin relación con seguridades.", citations: [])
      assert_match(/#{NOTICE_CLASS}/, bubble_html)
    end

    assert_selector ".answer-verification-notice", count: 2, visible: :all
  end

  test "switches to English copy when response_locale is en, still never inside answer" do
    # Chat chrome follows the server's response_locale for THIS answer, never
    # document.documentElement.lang (that reflects the Devise auth-time locale
    # switcher, session[:locale] — must never leak into response-language policy,
    # P0 idioma). Mutating documentElement.lang here must have NO effect.
    execute_script("document.documentElement.lang = 'en'")

    bubble_html = render_assistant_answer(
      answer: "En TW1 el LED SPM indica falla en la serie de puertas [1].",
      citations: [],
      response_locale: "es"
    )
    assert_match(/verifica cualquier acci[oó]n sobre seguridades/i, bubble_html)

    bubble_html = render_assistant_answer(
      answer: "In TW1 the SPM LED reports a fault [1].",
      citations: [],
      response_locale: "en"
    )
    assert_match(/verify any action on safety devices/i, bubble_html)
    assert_no_match(/verifica cualquier acci[oó]n/i, bubble_html)
  end

  test "answer_presenter's formatAnswerForWeb output never contains the notice, independent of the controller" do
    source = Rails.root.join("app/javascript/rag/answer_presenter.js").read
    module_url = "data:text/javascript;base64,#{Base64.strict_encode64(source)}"

    result = page.driver.browser.execute_async_script(<<~JAVASCRIPT, module_url)
      const [moduleUrl, done] = arguments
      import(moduleUrl).then(({ formatAnswerForWeb, renderVerificationNotice }) => {
        done({
          answerHtml: formatAnswerForWeb("Respuesta con [1] cita.", [ { number: 1, title: "Manual — p. 46" } ]),
          noticeEs: renderVerificationNotice("es"),
          noticeEn: renderVerificationNotice("en")
        })
      }).catch((error) => done({ error: error.message }))
    JAVASCRIPT

    assert_not result["error"], "module import failed: #{result['error']}"
    assert_not_includes result["answerHtml"], NOTICE_CLASS
    assert_not_includes result["answerHtml"], "verifica"
    assert_includes result["noticeEs"], NOTICE_CLASS
    assert_includes result["noticeEs"], "verifica cualquier acci\u00f3n sobre seguridades"
    assert_includes result["noticeEn"], "verify any action on safety devices"
  end

  private

  # Calls the real Stimulus controller instance's `renderAssistantAnswer`
  # (the exact code path `sendMessage` uses) with a fake, network-free
  # payload — same shape as the JSON `RagController#ask` returns — and
  # returns the innerHTML of the resulting assistant bubble.
  def render_assistant_answer(answer:, citations:, response_locale: nil)
    evaluate_script(<<~JAVASCRIPT, answer, citations, response_locale)
      (function (answerText, citationsArg, responseLocale) {
        const element = document.querySelector('[data-controller~="rag-chat"]')
        const controller = window.Stimulus.getControllerForElementAndIdentifier(element, "rag-chat")
        controller.renderAssistantAnswer({ answer: answerText, citations: citationsArg, response_locale: responseLocale })
        const rows = element.querySelectorAll(".chat-row-assistant")
        const lastRow = rows[rows.length - 1]
        return lastRow.querySelector(".chat-message").innerHTML
      })(arguments[0], arguments[1], arguments[2])
    JAVASCRIPT
  end
end
