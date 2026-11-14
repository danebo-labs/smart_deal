# frozen_string_literal: true

require "test_helper"

class Rag::ProcedureContinuationTest < ActiveSupport::TestCase
  TABLE = <<~TEXT
    **Arranque:**

    | Paso | Acción | Display |
    |------|--------|---------|
    | 2 | Mida la salida. Si marca 0 => el cable no está puesto o la separación es grande. | valor |
    | 3 | Grabe el cero en el registro del equipo. | listo |
  TEXT
  QUOTE = "Si marca 0 => el cable no está puesto o la separación es grande"
  NEXT_ACTION = "Grabe el cero en el registro del equipo."

  test "a report continues with the next step of the cited section" do
    prompt = prompt_for("Lo conecté y ahora marca 7 mA.", TABLE)

    assert_includes prompt, "«Arranque»"
    assert_includes prompt, "«#{NEXT_ACTION}» [1]"
    assert_includes prompt, "sin [n]"
  end

  test "a prior case condition stays beside the section title" do
    episode = Rag::ActiveEpisode.open(correlation_id: "query:t1", now: Time.current)
    episode.excerpts = [ { "text" => "La cabina está vacía" }, { "text" => "Lo conecté y ahora marca 7 mA" } ]

    prompt = Rag::ProcedureContinuation.prompt(
      history: [ { role: "assistant", text: "«#{QUOTE}» [1]." } ],
      chunks: [ { content: TABLE } ],
      question: "Lo conecté y ahora marca 7 mA.",
      episode: episode
    )

    assert_includes prompt, "La cabina está vacía"
    assert_includes prompt, "no la sustituyas por el título"
    assert_not_includes prompt, "Lo conecté y ahora marca 7 mA. Si esa"
  end

  test "an omitted cabin condition is placed ahead of the generated answer" do
    episode = Rag::ActiveEpisode.open(correlation_id: "query:t1", now: Time.current)
    episode.excerpts = [
      { "text" => "La cabina está vacía y no logro terminar el ajuste" },
      { "text" => "Lo conecté y ahora marca 7 mA" }
    ]
    generated = "Tras conectar el sensor, LOP-CB marca 7 mA, dentro del rango 6-8 de carga cero. " \
      "El paso siguiente es: «Seleccione el parámetro de registro.» [1]."

    carried = Rag::ProcedureContinuation.carry(generated, episode: episode, question: "Lo conecté y ahora marca 7 mA.")
    reflected = Rag::ProcedureContinuation.carry(
      "La cabina está vacía y no logro terminar el ajuste. #{generated}",
      episode: episode, question: "Lo conecté y ahora marca 7 mA."
    )

    assert_includes carried, "Condición ya reportada: La cabina está vacía y no logro terminar el ajuste."
    assert_includes carried, "«Seleccione el parámetro de registro.» [1]"
    assert_not_includes carried, "Condición ya reportada: Lo conecté"
    assert_equal "La cabina está vacía y no logro terminar el ajuste. #{generated}", reflected
    published = Rag::CompanionTurnPublication.call(
      text: carried, stop_reason: "end_turn",
      technician_texts: [ "Lo conecté y ahora marca 7 mA.", "La cabina está vacía y no logro terminar el ajuste" ],
      sources: [ { "content" => "Seleccione el parámetro de registro. El 0 parpadea.", "applicability" => "compatible" } ]
    )
    assert_equal true, published.accepted?, published.reasons.inspect
  end

  test "a question and the last step do not invent a continuation" do
    assert_nil prompt_for("¿Qué valor marca ahora?", TABLE)
    last = TABLE.sub("3 | Grabe el cero en el registro del equipo.", "3 | Listo.")
    assert_nil prompt_for("Lo conecté y ahora marca 7 mA.", last)
    assert_nil prompt_for("Lo conecté y ahora marca 7 mA.", "El cable no está puesto o la separación es grande, en prosa.")
  end

  test "the captured zero branch continues inside its own section" do
    body = Rails.root.join("test/fixtures/field_companion/audit_20261113/kone_lwi_p38.txt").read
    other = "Ajuste el potenciómetro OFFSET en la placa LCEVTC para que LOP-CB muestre el valor entre 6-8 (mA)."
    quoted = "Si el valor es 0 => El sensor no está conectado o hay un espacio demasiado grande"
    history = [ { role: "assistant", text: "«#{quoted}»." } ]
    chunks = [ { content: other }, { content: body } ]

    prompt = Rag::ProcedureContinuation.prompt(
      history: history, chunks: chunks, question: "Estaba desconectado. Lo conecté y ahora marca 7 mA."
    )

    assert_includes prompt, "«Carga cero»"
    assert_includes prompt, "«Seleccione el parámetro de Ajuste del pesacargas (6_74).» [2]"
    assert_not_includes prompt, "OFFSET"
  end

  test "prepare places that continuation before the sources" do
    body = Rails.root.join("test/fixtures/field_companion/audit_20261113/kone_lwi_p38.txt").read
    quoted = "Si el valor es 0 => El sensor no está conectado o hay un espacio demasiado grande"
    session = ContinuationSession.new([
      { "role" => "user", "content" => "La cabina está vacía.", "correlation_id" => "query:t1" },
      { "role" => "assistant", "content" => "«#{quoted}».", "correlation_id" => "query:t2" }
    ])
    episode = Rag::ActiveEpisode.open(correlation_id: "query:t1", now: Time.current)
    prepared = Rag::CompanionDirectAnswer.prepare(
      raw_question: "Estaba desconectado. Lo conecté y ahora marca 7 mA.",
      chunks: [ { content: body, metadata: { "canonical_name" => "manual", "page_number" => 38 } } ],
      episode: episode, session: session
    )

    assert_includes prepared.user, "Apartado en curso"
    assert_includes prepared.user, "«Seleccione el parámetro de Ajuste del pesacargas (6_74).» [1]"
    assert prepared.user.index("Apartado en curso") < prepared.user.index("Fuentes de este turno:")
  end

  test "the same quote in two sources does not choose one" do
    quoted = "Si marca 0 => el cable no está puesto o la separación es grande"
    history = [ { role: "assistant", text: "«#{quoted}»." } ]
    chunks = [ { content: TABLE }, { content: TABLE } ]

    assert_nil Rag::ProcedureContinuation.prompt(history: history, chunks: chunks, question: "Ahora marca 7 mA.")
  end

  class ContinuationSession
    def initialize(history)
      @history = history
    end

    def conversation_history
      @history
    end

    def episode_history_cutoff
      nil
    end
  end

  private

  def prompt_for(question, body)
    Rag::ProcedureContinuation.prompt(
      history: [ { role: "assistant", text: "«#{QUOTE}» [1]." } ],
      chunks: [ { content: body } ],
      question: question
    )
  end
end
