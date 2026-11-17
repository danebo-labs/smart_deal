# frozen_string_literal: true

require "test_helper"

class Rag::OpenReplyTest < ActiveSupport::TestCase
  LATCH = "¿La puerta de piso está abierta al momento de la falla, o el cerrojo (trinco) no enganchó?"
  FIRM = "¿La conexión de P28 en la bornera está firme?"
  VOLTAGE = "¿Qué tensión lees en RA-53/P28?"
  CODE = "¿Qué código de falla o de estado muestra la MCINV4?"
  ACTIVE = "Para decidir entre ambas ramas necesito una lectura: con la puerta de piso cerrada, ¿la línea de trincos (P28) está activa?"
  CONNECTIONS = "¿Ya revisaste las conexiones de esas líneas?"
  DOOR = "Pregunta: ¿La puerta de piso queda abierta o sólo no cierra del todo?"
  LATCH_OPEN = "Pregunta: Al intentar cerrar la puerta, ¿los trincos del piso quedan cerrados o alguno queda abierto?"
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

  test "the runner keeps the display reading that answers the published code question" do
    questions = photo_questions
    row = { "pending_question" => documented(CODE), "answer" => CODE }

    select_photo_reply(questions, 0, row)

    assert_nil row["block_reason"]
    assert_equal "El display marca EA.", questions[1]
  end

  test "a voltage reading answers the latch-line check and another component does not" do
    question = documented(ACTIVE)

    assert Rag::WorkContextReducer.open_reply?(question, "Sí, marca 0 Vcc.")
    assert Rag::WorkContextReducer.open_reply?(question, "La línea marca 0 Vcc.")
    assert_not Rag::WorkContextReducer.open_reply?(question, "El freno marca 0 Vcc.")
    assert_not Rag::WorkContextReducer.open_reply?(question, "Sí, está firme.")
    assert_not Rag::WorkContextReducer.open_reply?(documented(CODE), "Sí, marca 0 Vcc.")
  end

  test "a latch that does not engage answers whether it stays closed and a brake does not" do
    question = documented("¿el contacto del cerrojo queda cerrado cuando la puerta está cerrada?")

    assert Rag::WorkContextReducer.open_reply?(question, "No engancha.")
    assert Rag::WorkContextReducer.open_reply?(question, "El trinco no enganchó.")
    assert_not Rag::WorkContextReducer.open_reply?(question, "El freno no engancha.")
    assert_not Rag::WorkContextReducer.open_reply?(question, "Sí, está firme.")
    assert_not Rag::WorkContextReducer.open_reply?(documented("¿el freno queda cerrado?"), "No engancha.")
    assert_not Rag::WorkContextReducer.open_reply?(documented(ACTIVE), "No engancha.")
    code = documented("Pregunta: con la puerta de piso cerrada y trincada, ¿el display sigue mostrando EA?")
    assert_not Rag::WorkContextReducer.open_reply?(code, "No engancha.")
    assert_not Rag::WorkContextReducer.open_reply?(
      documented("Consulta: ¿la pantalla sigue marcando EC con el cerrojo cerrado?"),
      "El trinco no engancha."
    )

    questions = photo_questions
    row = { "pending_question" => code, "answer" => code["question"] }

    select_photo_reply(questions, 1, row)

    assert_nil row["block_reason"]
    assert_equal "Todavía no cierra ni traba. Solo aparece EA.", questions[2]
    assert_includes questions.drop(3), "No engancha."
  end

  test "only the displayed code answers which line failed, and a brake does not" do
    questions = photo_questions
    published = "Pregunta: ¿La MCINV4 o algún indicador te muestra cuál de esas líneas falla, o solo aparece EA?"
    row = { "pending_question" => documented(published), "answer" => published }

    select_photo_reply(questions, 1, row)

    assert_nil row["block_reason"]
    assert_equal "Solo aparece EA.", questions[2]
    assert_includes questions.drop(3), "No engancha."

    questions = photo_questions
    questions[1] = "La pantalla marca EC."
    row = { "answer" => "¿El visor indica la línea, o solamente marca EC?" }
    select_photo_reply(questions, 1, row)
    assert_equal "Solo aparece EC.", questions[2]

    questions = photo_questions
    row = { "answer" => "¿El freno muestra cuál falla, o solo aparece EA?" }
    select_photo_reply(questions, 1, row)
    assert_equal "pending_question_unanswered", row["block_reason"]
    assert_equal "Sí, está firme.", questions[2]
  end

  test "a latch that does not engage answers the open trinco and a brake does not" do
    question = documented(LATCH_OPEN)

    assert Rag::WorkContextReducer.open_reply?(question, "No engancha.")
    assert Rag::WorkContextReducer.open_reply?(question, "El trinco no engancha.")
    assert_not Rag::WorkContextReducer.open_reply?(question, "El freno no engancha.")
    assert_not Rag::WorkContextReducer.open_reply?(question, "Sí, está firme.")
  end

  test "a missing pending question is read from the one published question" do
    load_runner
    questions = photo_questions
    row = { "answer" => "#{LATCH_OPEN} La tabla indica «linha dos trincos» [1]." }

    select_photo_reply(questions, 1, row)

    assert_nil row["block_reason"]
    assert_equal LATCH_OPEN, row.dig("pending_question", "question")
    assert_equal "No engancha.", questions[2]
  end

  test "a string-keyed source still stores its published question" do
    service = BedrockRagService.allocate
    service.instance_variable_set(:@companion_direct_turn, true)
    sources = service.send(:companion_publication_sources, [
      { "content" => "linha dos trincos", "metadata" => { "original_filename" => "Manual de maniobra." }, "identity_applicability" => "compatible" }
    ])
    service.instance_variable_set(:@companion_direct_sources, sources)

    stored = service.send(:direct_documented_question, "#{LATCH_OPEN} [1]")

    assert_equal LATCH_OPEN, stored["question"]
    assert_equal "Manual de maniobra.", stored.dig("targets", 0, "item")
    assert_nil service.send(:direct_documented_question, "#{LATCH_OPEN} ¿Y el freno? [1]")
  end

  test "an open-or-not-closed door gets the reported closure and a brake does not" do
    [ DOOR, "¿La puerta queda abierta o no llega a cerrar?" ].each do |published|
      questions = photo_questions
      row = { "answer" => published }

      select_photo_reply(questions, 1, row)

      assert_nil row["block_reason"]
      assert_equal "La puerta de piso no cierra del todo.", questions[2]
      assert_equal "Sí, está firme.", questions[3]
    end

    questions = photo_questions
    row = { "answer" => "¿El freno queda abierto o sólo no cierra?" }
    select_photo_reply(questions, 1, row)
    assert_equal "pending_question_unanswered", row["block_reason"]
    assert_equal "Sí, está firme.", questions[2]
  end

  test "a firm connection answers the connection check and another component does not" do
    question = documented(CONNECTIONS)

    assert Rag::WorkContextReducer.open_reply?(question, "Sí, está firme.")
    assert Rag::WorkContextReducer.open_reply?(question, "Las conexiones están firmes.")
    assert_not Rag::WorkContextReducer.open_reply?(question, "El freno está firme.")
    assert_not Rag::WorkContextReducer.open_reply?(documented("¿Ya revisaste las conexiones del freno?"), "Sí, está firme.")
  end

  test "the runner uses the prepared firm reply for the connection check" do
    questions = photo_questions
    row = { "pending_question" => documented(CONNECTIONS), "answer" => CONNECTIONS }

    select_photo_reply(questions, 1, row)

    assert_nil row["block_reason"]
    assert_equal "Sí, está firme.", questions[2]
    assert_equal "No engancha.", questions[3]
  end

  test "the runner waits for restored engagement before reporting voltage" do
    questions = photo_questions
    row = { "answer" => ACTIVE }
    select_photo_reply(questions, 1, row)
    assert_equal "pending_question_unanswered", row["block_reason"]
    assert_equal "Sí, está firme.", questions[2]

    row = { "answer" => ACTIVE }
    select_photo_reply(questions, 5, row)
    assert_nil row["block_reason"]
    assert_equal Haiku55Http::PHOTO_OPEN_READING_REPLY, questions[6]
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

  test "a code check with the repaired door uses the reported mechanical result" do
    questions = photo_questions
    row = { "answer" => "Pregunta: con la puerta de piso cerrada, ¿el display sigue marcando EA?" }

    select_photo_reply(questions, 5, row)

    assert_nil row["block_reason"]
    assert_equal "Sí, cierra y traba bien. El display sigue marcando EA.", questions[6]
    assert_equal "Sí, marca 0 Vcc.", questions[7]
    assert_not Rag::WorkContextReducer.open_reply?(row["pending_question"], questions[5])
    assert_not Rag::WorkContextReducer.open_reply?(row["pending_question"], "El freno sigue marcando EA.")
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

  test "the runner follows the published latch question when the episode still has a different question" do
    questions = photo_questions
    row = { "pending_question" => documented(FIRM), "answer" => LATCH }

    select_photo_reply(questions, 1, row)

    assert_nil row["block_reason"]
    assert_equal "No engancha.", questions[2]
    assert_not_includes questions, "Sí, está firme."
  end

  test "the photo opening checks relevant labels and rejects unsupported photo claims" do
    load_runner
    assert_empty Haiku55JourneyRubric.photo_ea_reasons(1, "En el esquema se lee P28. ¿Qué muestra el display?")
    assert_includes Haiku55JourneyRubric.photo_ea_reasons(1, "En el esquema se leen P28 y P99."), "unsupported_photo_label"
    assert_includes Haiku55JourneyRubric.photo_ea_reasons(1, "La foto muestra P28 a 0 Vcc."), "photo_used_as_measurement"
    assert_includes Haiku55JourneyRubric.photo_ea_reasons(1, "La imagen confirma que P28 está activo."), "photo_used_as_measurement"
  end

  test "the live state-code question gets the observed EA and remains a presentation failure" do
    questions = photo_questions
    published = "EA es una falla de señales. «Quando falha de P28 - porta aberta - revisar linha dos trincos» [1].\n\n" \
      "¿Qué código de estado muestra la MCINV4 ahora, detenido?"
    row = { "answer" => published }

    select_photo_reply(questions, 1, row)

    assert_nil row["block_reason"]
    assert_equal "Solo aparece EA.", questions[2]
    assert_equal [ "display_state_reasked" ], Haiku55JourneyRubric.photo_ea_reasons(2, published)
  end

  test "a code-only detour can reach the electrical follow-up within the existing reservation" do
    questions = photo_questions
    expected = [ questions[0], questions[1], "Solo aparece EA.", *questions.drop(3) ]
    expected[expected.index(questions[6])] = Haiku55Http::PHOTO_OPEN_READING_REPLY
    published = [
      CODE,
      "¿El indicador identifica una línea o solo aparece EA?",
      "¿El trinco de piso engancha?",
      "¿Ves el cerrojo desplazado respecto a su alojamiento?",
      "Corrige la alineación conforme al procedimiento autorizado. Después comprueba cierre, enganche y EA.",
      "Con la puerta cerrada y trabada, ¿qué tensión lees en RA-53/P28?",
      "Con los 0 Vcc reportados queda por revisar el contacto del trinco y la línea."
    ]

    published.each_with_index do |answer, index|
      row = { "answer" => answer }
      select_photo_reply(questions, index, row)
      assert_nil row["block_reason"], answer
      assert_equal expected[index + 1], questions[index + 1]
    end
    assert_equal expected, questions
  end

  test "after the repair a connection check gets a firm line once and the reading follows" do
    questions = photo_questions
    sent = [ questions[0], questions[1], "No engancha.", "Sí, está desalineado.", questions[5] ]
    questions[0, questions.size] = [ *sent, questions[6], questions[7] ]
    connection = { "answer" => "La falla EA sigue. La foto muestra P28 como rótulo visible.\n\n" \
      "Pregunta: ¿puedes ver el cable que llega al borne P28 y está firme?" }
    select_photo_reply(questions, 4, connection)

    assert_nil connection["block_reason"]
    assert_equal "Sí, está firme.", questions[5]

    reading = { "answer" => "Con la puerta cerrada y trabada, ¿qué tensión lees en RA-53/P28?" }
    select_photo_reply(questions, 5, reading)
    assert_nil reading["block_reason"]
    assert_equal Haiku55Http::PHOTO_OPEN_READING_REPLY, questions[6]

    again = { "answer" => "¿El cable de P28 está firme en el borne?" }
    select_photo_reply(questions, 5, again)
    assert_equal "pending_question_unanswered", again["block_reason"]
  end

  test "after the reading the documented operator condition is answered once and the how question follows" do
    questions = photo_questions
    sent = [ questions[0], questions[1], "No engancha.", "Sí, está desalineado.", questions[5], questions[6] ]
    questions[0, questions.size] = [ *sent, questions[7] ]
    condition = { "answer" => "Ese valor corresponde al caso con motor de operador de puerta.\n\n¿La puerta tiene motor de operador?" }
    select_photo_reply(questions, 5, condition)

    assert_nil condition["block_reason"]
    assert_equal Haiku55Http::PHOTO_OPERATOR_REPLY, questions[6]
    assert_equal "¿Cómo reviso eso?", questions[7]

    compared = { "answer" => "Con motor de operador, los 0 Vcc no coinciden con +110 Vcc. ¿Hay +110 Vcc en RA-30?" }
    select_photo_reply(questions, 6, compared)
    assert_nil compared["block_reason"]
    assert_equal "¿Cómo reviso eso?", questions[7]

    early = photo_questions
    before = { "answer" => "¿La puerta tiene motor de operador?" }
    select_photo_reply(early, 1, before)
    assert_equal "pending_question_unanswered", before["block_reason"]
  end

  test "a nominal +110 check is negated and an open reading reports the measured value" do
    published = "Con el trinco alineado y trabando bien, EA sigue.\n\n" \
      "Pregunta: con la puerta cerrada y trabada, ¿mides +110 Vcc en el borne P28 de la bornera? " \
      "Si no puedes ubicarlo con certeza en el tablero, dime y lo dejamos pendiente."
    questions = repaired_photo_questions
    row = { "answer" => published }
    select_photo_reply(questions, 4, row)

    assert_nil row["block_reason"]
    assert_equal Haiku55Http::PHOTO_NOMINAL_READING_REPLY, questions[5]
    assert_equal "¿Cómo reviso eso?", questions[6]
    assert_not_includes questions, "Sí, marca 0 Vcc."
    assert_not Rag::WorkContextReducer.open_reply?(row["pending_question"], "Sí, marca 0 Vcc.")
    assert_not Rag::WorkContextReducer.open_reply?(row["pending_question"], Haiku55Http::PHOTO_NOMINAL_READING_REPLY)

    open = { "answer" => "Con la puerta cerrada y trabada, ¿qué tensión lees en RA-53/P28?" }
    fresh = repaired_photo_questions
    select_photo_reply(fresh, 4, open)
    assert_nil open["block_reason"]
    assert_equal Haiku55Http::PHOTO_OPEN_READING_REPLY, fresh[5]
    assert Rag::WorkContextReducer.open_reply?(open["pending_question"], Haiku55Http::PHOTO_OPEN_READING_REPLY)
    assert Rag::WorkContextReducer.open_reply?(open["pending_question"], "Sí, marca 0 Vcc.")

    weak = "Sigue la falla."
    met = "Mediste 0 Vcc contra «RA-53 / P28 = +110 Vcc» [3]. Revisa el contacto del trinco."
    [ "Sí, marca 0 Vcc.", Haiku55Http::PHOTO_OPEN_READING_REPLY, Haiku55Http::PHOTO_NOMINAL_READING_REPLY ].each do |line|
      journey = photo_questions
      journey[6] = line
      assert_equal [ "voltage_comparison_missing", "contact_or_wiring_not_addressed" ],
        Haiku55JourneyRubric.reasons("audit_thyssen_photo_ea", 7, weak, journey), line
      assert_empty Haiku55JourneyRubric.reasons("audit_thyssen_photo_ea", 7, met, journey), line
    end
    assert_equal [ Haiku55Http::PHOTO_OPEN_READING_REPLY, Haiku55Http::PHOTO_NOMINAL_READING_REPLY ],
      Haiku55JourneyRubric::PHOTO_READING_VARIANTS
  end

  test "a label-to-latch-line check is answered once and the latch question follows" do
    [
      "En la foto aparece el rótulo P28.\n\n¿El borne rotulado P28 en tu bornera es el que llega desde los trincos de piso?",
      "¿El cable del trinco de piso llega al borne rotulado P28 en su bornera?"
    ].each do |answer|
      questions = photo_questions
      row = { "answer" => answer }
      select_photo_reply(questions, 1, row)
      assert_nil row["block_reason"], answer
      assert_equal Haiku55Http::PHOTO_LABEL_LINE_REPLY, questions[2]

      latch = { "answer" => LATCH }
      select_photo_reply(questions, 2, latch)
      assert_nil latch["block_reason"]
      assert_equal "No engancha.", questions[3]

      again = { "answer" => answer }
      select_photo_reply(questions, 2, again)
      assert_equal "pending_question_unanswered", again["block_reason"]
    end

    brake = { "answer" => "¿El cable del freno llega al borne del contactor?" }
    select_photo_reply(photo_questions, 1, brake)
    assert_equal "pending_question_unanswered", brake["block_reason"]

    engaged = { "answer" => "¿El trinco que llega al borne engancha?" }
    questions = photo_questions
    select_photo_reply(questions, 1, engaged)
    assert_equal "No engancha.", questions[2]
  end

  private

  def photo_questions
    load_runner
    Haiku55Http::AUDIT_JOURNEYS.fetch("photo_ea").dup
  end

  def repaired_photo_questions
    questions = photo_questions
    sent = [ questions[0], questions[1], "No engancha.", "Sí, está desalineado.", questions[5] ]
    questions[0, questions.size] = [ *sent, questions[6], questions[7] ]
    questions
  end

  def select_photo_reply(questions, index, row)
    Haiku55Http.place_photo_reply!(questions, index, row)
  end

  def load_runner
    return if defined?(Haiku55Http)

    ENV["HTTP55_REQUIRE"] = "1"
    load Rails.root.join("script/field_companion/run_haiku55_http.rb")
  end

  def documented(text)
    { "type" => "documented_context", "question" => text, "targets" => TARGETS }
  end
end
