# frozen_string_literal: true

require "test_helper"

module Rag
  class ThreadMenuSelectionTest < ActiveSupport::TestCase
    ORIGINAL = "Otra falla: Elemont MH con placa CEA15, la puerta 1 no magnetiza."

    test "recognizes both thread menu query shapes" do
      history = menu_history(ORIGINAL)

      assert ThreadMenuSelection.call(question: ORIGINAL, conversation_history: history)
      assert ThreadMenuSelection.call(
        question: "Pregunta anterior\n#{ORIGINAL}",
        conversation_history: history
      )
    end

    test "rejects an unrelated manual turn" do
      assert_not ThreadMenuSelection.call(
        question: "texto manual distinto",
        conversation_history: menu_history(ORIGINAL)
      )
    end

    test "requires the immediately preceding assistant message to be the menu" do
      history = menu_history(ORIGINAL)
      history << row("assistant", "respuesta normal")

      assert_not ThreadMenuSelection.call(question: ORIGINAL, conversation_history: history)
    end

    test "recognizes the English menu prompt" do
      history = [
        row("user", ORIGINAL),
        row("assistant", I18n.t("rag.thread_menu_prompt", locale: :en))
      ]

      assert ThreadMenuSelection.call(question: ORIGINAL, conversation_history: history)
    end

    private

    def menu_history(original)
      [
        row("user", "¿qué reviso primero?"),
        row("assistant", "respuesta anterior"),
        row("user", original),
        row("assistant", I18n.t("rag.thread_menu_prompt", locale: :es))
      ]
    end

    def row(role, content)
      { "role" => role, "content" => content, "ts" => Time.current.iso8601 }
    end
  end
end
