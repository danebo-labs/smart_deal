# frozen_string_literal: true

require "test_helper"

class Rag::OpenReplyTest < ActiveSupport::TestCase
  LATCH = "¿La puerta de piso está abierta al momento de la falla, o el cerrojo (trinco) no enganchó?"
  FIRM = "¿La conexión de P28 en la bornera está firme?"
  VOLTAGE = "¿Qué tensión lees en RA-53/P28?"
  CODE = "¿Qué código de falla o de estado muestra la MCINV4?"
  TARGETS = [ { "item" => "Manual de maniobra.", "document_key" => "doc", "filename" => "p24.txt", "page" => "24" } ].freeze

  test "a paraphrase answers the latch part and another component does not" do
    question = documented(LATCH)

    assert_equal "el cerrojo (trinco) no enganchó", Rag::WorkContextReducer.answered_part(question, "No engancha.")
    assert_equal "el cerrojo (trinco) no enganchó", Rag::WorkContextReducer.answered_part(question, "El cerrojo no enganchó.")
    assert Rag::WorkContextReducer.open_reply?(question, "No engancha.")
    assert Rag::WorkContextReducer.open_reply?(question, "El trinco no engancha.")
    assert_nil Rag::WorkContextReducer.answered_part(question, "El freno no engancha.")
    assert_not Rag::WorkContextReducer.open_reply?(question, "El freno no engancha.")
    assert_not Rag::WorkContextReducer.open_reply?(question, "Sí, está firme.")
  end

  test "a firm connection and a voltage reading stay on their own questions" do
    firm = documented(FIRM)
    voltage = documented(VOLTAGE)

    assert Rag::WorkContextReducer.open_reply?(firm, "Sí, está firme.")
    assert_not Rag::WorkContextReducer.open_reply?(firm, "Sí, marca 0 Vcc.")
    assert Rag::WorkContextReducer.open_reply?(voltage, "Sí, marca 0 Vcc.")
    assert_not Rag::WorkContextReducer.open_reply?(voltage, "El freno marca 0 Vcc.")
    assert_not Rag::WorkContextReducer.open_reply?(voltage, "Sí, está firme.")
  end

  test "a display code answers the code question and another component does not" do
    question = documented(CODE)

    assert Rag::WorkContextReducer.open_reply?(question, "El display marca EA.")
    assert Rag::WorkContextReducer.open_reply?(question, "En pantalla marca EA.")
    assert_not Rag::WorkContextReducer.open_reply?(question, "El freno marca EA.")
    assert_not Rag::WorkContextReducer.open_reply?(question, "Sí, está firme.")
    assert_not Rag::WorkContextReducer.open_reply?(question, "El display marca 0 Vcc.")
    assert_not Rag::WorkContextReducer.open_reply?(documented(LATCH), "El display marca EA.")
  end

  test "the runner keeps the display reading that answers the code question" do
    load_runner
    questions = [
      "Estoy con el equipo.",
      "El display marca EA.",
      "Sí, está firme.",
      "No engancha."
    ]
    row = { "pending_question" => documented(CODE), "answer" => "publicado" }

    Haiku55Http.place_photo_reply!(questions, 0, row)

    assert_nil row["block_reason"]
    assert_equal "El display marca EA.", questions[1]
  end

  test "a labeled question is stored and a second question is not" do
    service = BedrockRagService.allocate
    service.instance_variable_set(:@companion_direct_turn, true)
    service.instance_variable_set(:@companion_direct_sources, [
      { "document" => "Manual de maniobra.", "reference_only" => false, "applicability" => "compatible" }
    ])
    labeled = "EA es falla de señales. La tabla indica: «linha dos trincos» [1].\n\nPregunta: con la puerta de piso cerrada a mano, ¿el display sigue marcando EA?"
    paraphrase = "Consulta: ¿la pantalla sigue marcando EC con la puerta cerrada a mano? [1]"

    assert_equal "Pregunta: con la puerta de piso cerrada a mano, ¿el display sigue marcando EA?",
      service.send(:direct_documented_question, labeled)["question"]
    assert_equal "Consulta: ¿la pantalla sigue marcando EC con la puerta cerrada a mano?",
      service.send(:direct_documented_question, paraphrase)["question"]
    assert_nil service.send(:direct_documented_question, "#{labeled} ¿Y el freno?")
    assert_nil service.send(:direct_documented_question, "La tabla indica ¿el freno engancha? [1].")
  end

  test "an unmatched code check gets one simulated reply and another component does not" do
    load_runner
    questions = [
      "El display marca EA.",
      "Sí, está firme.",
      "No engancha.",
      "Ya lo alineé. Ahora cierra y traba bien, pero sigue marcando EA."
    ]
    row = {
      "pending_question" => documented("Pregunta: con la puerta de piso cerrada a mano, ¿el display sigue marcando EA?"),
      "answer" => "publicado"
    }

    Haiku55Http.place_photo_reply!(questions, 0, row)

    assert_nil row["block_reason"]
    assert_equal "Sí, la cerré a mano y el display sigue marcando EA.", questions[1]
    assert_equal "Sí, está firme.", questions[2]
    assert_not Rag::WorkContextReducer.open_reply?(
      row["pending_question"],
      "Ya lo alineé. Ahora cierra y traba bien, pero sigue marcando EA."
    )
    assert_not Rag::WorkContextReducer.open_reply?(
      row["pending_question"],
      "El freno sigue marcando EA."
    )

    other = [ "turno", "Sí, está firme.", "No engancha." ]
    blocked = { "pending_question" => documented("¿El freno sigue marcando EA?"), "answer" => "publicado" }
    Haiku55Http.place_photo_reply!(other, 0, blocked)

    assert_equal "pending_question_unanswered", blocked["block_reason"]
    assert_equal "Sí, está firme.", other[1]
  end

  test "a direct answer stores its single published question" do
    service = BedrockRagService.allocate
    service.instance_variable_set(:@companion_direct_turn, true)
    service.instance_variable_set(:@companion_direct_sources, [
      { "document" => "Manual de maniobra.", "reference_only" => false, "applicability" => "compatible" }
    ])
    text = "#{LATCH}\n\nLa tabla dice «Quando falha de P28 - porta aberta - revisar linha dos trincos» [1]."

    stored = service.send(:direct_documented_question, text)

    assert_equal LATCH, stored["question"]
    assert_equal "Manual de maniobra.", stored.dig("targets", 0, "item")
    assert_equal stored, Rag::PendingQuestion.presented(stored, text)
    assert_nil service.send(:direct_documented_question, "#{LATCH} ¿Y el freno?")
    assert_nil service.send(:direct_documented_question, "Sin pregunta y sin cita [1].")
  end

  test "the runner keeps the prepared line that answers the stored question" do
    load_runner
    questions = [
      "El display marca EA.",
      "Sí, está firme.",
      "No engancha.",
      "Sí, está desalineado."
    ]
    row = { "pending_question" => documented(LATCH), "answer" => "publicado" }

    Haiku55Http.place_photo_reply!(questions, 0, row)

    assert_nil row["block_reason"]
    assert_equal "No engancha.", questions[1]
    assert_equal "Sí, está firme.", questions[2]
  end

  private

  def load_runner
    return if defined?(Haiku55Http)

    ENV["HTTP55_REQUIRE"] = "1"
    load Rails.root.join("script/field_companion/run_haiku55_http.rb")
  end

  def documented(text)
    { "type" => "documented_context", "question" => text, "targets" => TARGETS }
  end
end
