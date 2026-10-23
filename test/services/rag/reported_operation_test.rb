# frozen_string_literal: true

require "test_helper"

class Rag::ReportedOperationTest < ActiveSupport::TestCase
  CHECK = "Comprobar que la fotocélula no esté activada."
  COMPOUND = "En caso que el problema persista, desconectar la fotocélula y volver a pulsar el botón de TEST. Si la puerta no se abre o cierra completamente, debe haber una obstrucción mecánica en la puerta."
  SENSITIVITY = "Comprobar la sensibilidad del #54."
  FUSE_CHECK = "Comprobar el fusible F2."
  FUSE_REPLACE = "Sustituir el fusible F2."
  FUSE_COMPOUND = "Si persiste, desconectar el fusible F2 y pulsar TEST."
  FUSE_STATE = "Comprobar el estado del fusible F2."

  test "review of a state completes that check and not a different operation" do
    assert_equal :complete, relate("Ya revisé la fotocélula y no está activada.", "done", CHECK)
    assert_equal :complete, relate("Desconecté la fotocélula y pulsé TEST.", "done", COMPOUND)
    assert_equal :pending, relate("No he comprobado el #54.", "not_done", SENSITIVITY)
    assert_equal :complete, relate("Comprobé la sensibilidad del 54.", "done", SENSITIVITY)

    assert_equal :complete, relate("Ya revisé el fusible F2 y está abierto.", "done", FUSE_CHECK)
    assert_equal :complete, relate("Desconecté el fusible F2 y pulsé TEST.", "done", FUSE_COMPOUND)
    assert_equal :pending, relate("No he comprobado el fusible F2.", "not_done", FUSE_CHECK)
    assert_equal :complete, relate("Comprobé el estado del fusible F2.", "done", FUSE_STATE)
  end

  test "a different act, a partial act, and a nominal are not execution" do
    assert_equal :related, relate("Ya revisé la fotocélula y no está activada.", "done", COMPOUND)
    assert_equal :partial, relate("Desconecté la fotocélula, todavía no pulsé TEST.", "done", COMPOUND)
    assert_equal :related, relate("Revisé el #54.", "done", SENSITIVITY)
    assert_equal :related, relate("Revisé el F2.", "done", FUSE_STATE)
    assert_equal :complete, relate("Sustituí el fusible F2.", "done", FUSE_REPLACE)
    assert_empty Rag::ReportedOperation.parse("potenciómetro de regulación").acts
    assert_empty Rag::ReportedOperation.parse("No hice mediciones.").acts
    assert_equal :none, relate("No hice mediciones.", "not_done", "Medir la corriente del motor.")
    assert_empty Rag::ReportedOperation.parse("No veo obstrucción.").acts
  end

  test "the same component keeps two operations and normalizes the identifier" do
    episode = Rag::ActiveEpisode.open(correlation_id: "t1", now: Time.current)
    episode.upsert_check!(
      { "subject" => "fotocélula", "status" => "done", "result" => "no está activada", "operation" => [ "check" ] },
      correlation_id: "t1"
    )
    episode.upsert_check!(
      { "subject" => "fotocélula", "status" => "done", "operation" => [ "disconnect" ] },
      correlation_id: "t2"
    )
    episode.upsert_check!(
      { "subject" => "#54", "status" => "not_done", "operation" => [ "check" ] },
      correlation_id: "t1"
    )
    episode.upsert_check!(
      { "subject" => "el #54", "status" => "done", "operation" => [ "check" ] },
      correlation_id: "t3"
    )

    stored = Rag::ActiveEpisode.parse(episode.to_h, now: Time.current)
    photocell = stored.checks.select { |row| row["subject"] == "fotocélula" }
    assert_equal [ [ "check" ], [ "disconnect" ] ], photocell.pluck("operation")
    assert_equal "no está activada", photocell.find { |row| row["operation"] == [ "check" ] }["result"]
    fifty = stored.checks.select { |row| row["subject"].include?("54") }
    assert_equal 1, fifty.size
    assert_equal "done", fifty.first["status"]
    assert_equal [ "check" ], fifty.first["operation"]
  end

  private

  def relate(report, status, step)
    Rag::ReportedOperation.correspondence(report_text: report, result: nil, status: status, statement_text: step)
  end
end
