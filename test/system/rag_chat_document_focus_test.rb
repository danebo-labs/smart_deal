# frozen_string_literal: true

require "application_system_test_case"

class RagChatDocumentFocusTest < ApplicationSystemTestCase
  include Warden::Test::Helpers

  QUESTION = "¿Qué reviso si no nivela?"

  setup do
    @document = KbDocument.create!(
      account: users(:one).account,
      s3_key: "uploads/f3-vf5-#{SecureRandom.hex(4)}.pdf",
      display_name: "Fermator VF5 Door Controller",
      aliases: []
    )
    login_as users(:one), scope: :user
    visit root_path
    page.current_window.resize_to(1400, 1400)
  end

  teardown do
    Warden.test_reset!
  end

  test "a document check leaves the question alone and the ask waits for the pin" do
    install_focus_fetch(mode: "hold")
    fill_question

    assert_equal %w[0 0], focus_counts
    click_document
    assert_equal %w[1 1], focus_counts
    assert_equal QUESTION, question_text
    assert_not_includes question_text, @document.display_name

    click_send
    assert_equal 0, ask_count

    release_pin(ok: true)
    assert_user_question
    assert_equal "", question_text
    assert_equal [ QUESTION ], ask_questions
  end

  test "a failed document check does not send the waiting question" do
    install_focus_fetch(mode: "hold")
    fill_question
    click_document
    click_send

    release_pin(ok: false)
    wait_until { document_selected == "false" && focus_busy.zero? && focus_counts == %w[0 0] }

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.6
    while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      assert_equal QUESTION, question_text
      assert_equal 0, ask_count
      sleep 0.05
    end
  end

  test "a failed document check does not block the next question" do
    install_focus_fetch(mode: "fail")
    click_document
    wait_until { document_selected == "false" && focus_busy.zero? }

    fill_question
    click_send
    assert_user_question
    assert_equal [ QUESTION ], ask_questions
  end

  private

  def fill_question
    find("[data-rag-chat-target='input']", visible: true).set(QUESTION)
  end

  def question_text
    find("[data-rag-chat-target='input']", visible: true).value
  end

  def click_document
    document_button.click
  end

  def document_button
    find(".kb-doc-btn[data-doc-id='#{@document.id}']", visible: true)
  end

  def document_selected
    document_button["data-selected"]
  end

  def click_send
    find("[data-rag-chat-target='sendButton']", visible: true).click
  end

  def ask_count
    evaluate_script("window.focusAsks.length")
  end

  def ask_questions
    JSON.parse(evaluate_script("JSON.stringify(window.focusAsks)"))
  end

  def assert_user_question
    html = nil
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Capybara.default_max_wait_time
    until html.to_s.include?(QUESTION)
      html = evaluate_script("document.querySelector('[data-rag-chat-target=messages]')?.innerHTML")
      break if html.to_s.include?(QUESTION)
      flunk "user question missing: #{html}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
  end

  def focus_counts
    JSON.parse(evaluate_script(<<~JS))
      JSON.stringify([...document.querySelectorAll("[data-focus-count]")].map((node) => node.textContent.trim()))
    JS
  end

  def focus_busy
    evaluate_script(<<~JS).to_i
      (() => {
        const el = document.querySelector('[data-controller~="rag-chat"]')
        const controller = window.Stimulus.getControllerForElementAndIdentifier(el, "rag-chat")
        return controller ? controller._focusBusy : 1
      })()
    JS
  end

  def release_pin(ok:)
    execute_script("window.releaseFocusPin(arguments[0])", ok)
    wait_until { evaluate_script("window.focusPinSettled") }
  end

  def wait_until
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Capybara.default_max_wait_time
    until yield
      flunk "timed out waiting for the document focus action" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
  end

  def install_focus_fetch(mode:)
    execute_script(<<~JS, mode)
      (function (mode) {
        window.focusAsks = []
        window.focusPinSettled = false
        const original = window.fetch.bind(window)
        window.fetch = (url, options) => {
          const target = String(url)
          if (target.includes("/pinned_documents")) {
            const finish = (success) => ({
              ok: success,
              status: success ? 204 : 500,
              json: async () => ({})
            })
            if (mode === "hold") {
              return new Promise((resolve) => {
                window.releaseFocusPin = (success) => {
                  window.focusPinSettled = true
                  resolve(finish(success))
                }
              })
            }
            window.focusPinSettled = true
            return Promise.resolve(finish(mode === "ok"))
          }
          if (target.includes("/rag/ask")) {
            const body = JSON.parse(options.body)
            window.focusAsks.push(body.question)
            return Promise.resolve({
              ok: true,
              status: 200,
              json: async () => ({ status: "success", answer: "ok", citations: [], response_locale: "es" })
            })
          }
          return original(url, options)
        }
      })(arguments[0])
    JS
  end
end
