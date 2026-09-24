# frozen_string_literal: true

require "application_system_test_case"

# CG-D19: a photo with a question is one visible answer. The chat never draws
# a vision card, a "searching the manuals" placeholder, or a redraw.
class FieldCompanionPhotoTest < ApplicationSystemTestCase
  include Warden::Test::Helpers

  setup do
    login_as users(:one), scope: :user
    visit root_path
  end

  teardown do
    Warden.test_reset!
  end

  test "photo and question use one visible answer bubble on mobile" do
    page.driver.browser.execute_cdp(
      "Emulation.setDeviceMetricsOverride",
      width: 390, height: 844, deviceScaleFactor: 1, mobile: true
    )
    before = all(".chat-row-assistant", visible: :all).size

    invoke_chat_controller(
      "addPhotoQuestionAnswer",
      status: "photo_question_answered",
      correlation_id: "photo:cg-d19",
      answer: "Por la foto, esto parece el conjunto de fijación de los cables. El manual recuperado no trae la cota.",
      citations: [],
      field_photo_id: 42,
      thumbnail_url: "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==",
      response_locale: "es"
    )

    assert_selector ".chat-row-assistant", count: before + 1, visible: :all
    within(all(".chat-row-assistant", visible: :all).last) do
      assert_text "Por la foto, esto parece el conjunto de fijación de los cables."
      assert_no_text "Buscando tu pregunta en los manuales"
      assert_button "Preguntar sobre esta foto"
      assert_selector "img"
      assert_no_selector "[data-photo-answer]"
    end

    capture = ENV["FIELD_COMPANION_PHOTO_CAPTURE"]
    page.save_screenshot(capture) if capture.present?
  end

  test "a failed answer shows the paid visual reading in the same bubble" do
    before = all(".chat-row-assistant", visible: :all).size
    invoke_chat_controller(
      "addPhotoQuestionAnswer",
      correlation_id: "photo:failed",
      visual_summary: "Se ve una placa con un indicador rojo.",
      answer: "No pude consultar los manuales.", citations: [], field_photo_id: 42, response_locale: "es"
    )

    assert_selector ".chat-row-assistant", count: before + 1, visible: :all
    within(all(".chat-row-assistant", visible: :all).last) do
      assert_text "Se ve una placa con un indicador rojo."
      assert_text "No pude consultar los manuales."
      assert_selector "[data-photo-visual-summary]"
      assert_button "Preguntar sobre esta foto"
    end
  end

  test "a photo alone shows the reading in prose without metadata" do
    before = all(".chat-row-assistant", visible: :all).size
    invoke_chat_controller(
      "addImageSummaryMessage",
      status: "photo_analyzed",
      correlation_id: "photo:alone",
      canonical_name: "UNKNOWN",
      aliases: [ "Hidden alias" ],
      summary: "Veo un amarre de cables con resortes.",
      field_photo_id: 42,
      response_locale: "es"
    )

    assert_selector ".chat-row-assistant", count: before + 1, visible: :all
    within(all(".chat-row-assistant", visible: :all).last) do
      assert_text "Veo un amarre de cables con resortes."
      assert_no_text "UNKNOWN"
      assert_no_text "Hidden alias"
      assert_button "Preguntar sobre esta foto"
    end
  end

  private

  def invoke_chat_controller(method, payload)
    result = evaluate_script(<<~JAVASCRIPT, method, payload.to_json)
      (function (methodName, payloadJson) {
        const element = document.querySelector('[data-controller~="rag-chat"]')
        const controller = window.Stimulus.getControllerForElementAndIdentifier(element, "rag-chat")
        controller[methodName](JSON.parse(payloadJson))
        return true
      })(arguments[0], arguments[1])
    JAVASCRIPT
    assert_equal true, result
  end
end
