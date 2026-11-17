# frozen_string_literal: true

require "application_system_test_case"
require_relative "../support/opening_chat_double"

class OpeningChatTest < ApplicationSystemTestCase
  setup do
    OpeningChatDouble.install!
    OpeningChatDouble.answer = "Respuesta:"
  end

  teardown do
    OpeningChatDouble.answer = nil
    ENV.delete("FIELD_CASE_HISTORY_ENABLED")
    FieldTurn.delete_all
    FieldCase.delete_all
  end

  test "login opens an empty chat and the first two texts stay in one case" do
    ENV.delete("FIELD_CASE_HISTORY_ENABLED")
    sign_in_through_the_form

    assert_selector "[data-rag-chat-target='input']:not([disabled])"
    assert_no_selector "[data-rag-chat-target='messages'] .chat-message"
    assert_no_selector "[data-selected='true']"
    assert_equal 0, FieldCase.count

    click_button "＋ Nuevo caso"
    assert_equal 0, FieldCase.count
    visit root_path
    assert_equal 0, FieldCase.count
    assert_field_ready

    find("[data-rag-chat-target='input']").set("primer aviso")
    page.execute_script(<<~JS)
      const form = document.querySelector("form.chat-composer-form")
      form.requestSubmit()
      form.requestSubmit()
    JS
    assert_text "Respuesta: primer aviso"
    assert_field_ready
    assert_current_path(/caso=\d+/)
    assert_equal 1, FieldCase.count
    assert_equal 1, FieldTurn.count

    find("[data-rag-chat-target='input']").set("segundo aviso")
    find("[data-rag-chat-target='sendButton']").click
    assert_text "Respuesta: segundo aviso"
    case_id = FieldCase.pick(:id)
    assert_equal [ "primer aviso", "segundo aviso" ], FieldTurn.order(:sequence).pluck(:message)
    assert_equal 1, FieldCase.count

    visit current_url
    assert_text "primer aviso"
    assert_text "Respuesta: primer aviso"
    assert_text "segundo aviso"
    assert_text "Respuesta: segundo aviso"
    assert_current_path(/caso=#{case_id}/)

    find("summary", text: "Historial").click
    click_button "Caso #{case_id}"
    assert_text "primer aviso"
    assert_text "segundo aviso"
    assert_current_path(/caso=#{case_id}/)

    click_button "＋ Nuevo caso"
    assert_no_selector "[data-rag-chat-target='messages'] .chat-message"
    assert_field_ready
    assert_no_current_path(/caso=/)
    assert_equal 1, FieldCase.count
    assert_equal 2, FieldTurn.count
  end

  test "the empty chat selects a manual without asking for a new case" do
    ENV["FIELD_CASE_HISTORY_ENABLED"] = "false"
    sign_in_through_the_form
    page.execute_script(<<~JS)
      const root = document.querySelector("[data-controller='rag-chat']")
      const button = document.createElement("button")
      button.type = "button"
      button.dataset.docId = "4242"
      button.dataset.selected = "false"
      button.dataset.action = "click->rag-chat#toggleDocSelection"
      button.textContent = "Manual Thyssen"
      root.appendChild(button)
    JS

    click_button "Manual Thyssen"
    assert_selector "[data-doc-id='4242'][data-selected='true']"
    assert_no_text "Abre un caso para fijar manuales."
    assert_equal 0, FieldCase.count

    click_button "＋ Nuevo caso"
    assert_selector "[data-doc-id='4242'][data-selected='false']"
    click_button "Manual Thyssen"
    assert_selector "[data-doc-id='4242'][data-selected='true']"
    assert_no_text "Abre un caso para fijar manuales."
    assert_equal 0, FieldCase.count
  end

  test "a failed first send keeps the draft and the retry creates one case" do
    ENV["FIELD_CASE_HISTORY_ENABLED"] = "false"
    sign_in_through_the_form
    page.execute_script(<<~JS)
      window.__originalFetch = window.fetch
      window.fetch = (url, options) => {
        if (String(url).includes("/rag/ask")) {
          return Promise.resolve(new Response(JSON.stringify({ error: "down" }), {
            status: 500,
            headers: { "Content-Type": "application/json" }
          }))
        }
        return window.__originalFetch(url, options)
      }
    JS

    find("[data-rag-chat-target='input']").set("borrador que queda")
    find("[data-rag-chat-target='sendButton']").click
    assert_selector "[data-rag-chat-target='caseNotice']", text: /\S/
    assert_selector "[data-rag-chat-target='sendButton']:not([disabled])"
    assert_no_text "Respuesta:"
    assert_equal "borrador que queda", find("[data-rag-chat-target='input']").value
    assert_equal 0, FieldCase.count
    assert_equal 0, FieldTurn.count

    page.execute_script("window.fetch = window.__originalFetch")
    find("[data-rag-chat-target='sendButton']").click
    assert_text "Respuesta: borrador que queda"
    assert_equal 1, FieldCase.count
    assert_equal 1, FieldTurn.count
    assert_equal [ "borrador que queda" ], FieldTurn.order(:sequence).pluck(:message)
  end

  test "history stays on when the env is absent" do
    ENV.delete("FIELD_CASE_HISTORY_ENABLED")
    sign_in_through_the_form

    assert_button "＋ Nuevo caso"
    find("[data-rag-chat-target='input']").set("aviso suelto")
    find("[data-rag-chat-target='sendButton']").click
    assert_text "Respuesta: aviso suelto"
    assert_equal 1, FieldCase.count
    assert_equal [ "aviso suelto" ], FieldTurn.order(:sequence).pluck(:message)
    assert_current_path(/caso=/)
  end

  private

  def sign_in_through_the_form
    visit new_user_session_path
    fill_in "user_email", with: users(:one).email
    fill_in "user_password", with: "password123"
    find("input[type=submit]").click
    assert_selector "[data-rag-chat-target='input']"
  end

  def assert_field_ready
    assert_selector "[data-rag-chat-target='input']:not([disabled])"
    assert_equal "", find("[data-rag-chat-target='input']").value
  end
end
