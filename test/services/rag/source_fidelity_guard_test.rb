# frozen_string_literal: true

require "test_helper"

class Rag::SourceFidelityGuardTest < ActiveSupport::TestCase
  LCB = JSON.parse(Rails.root.join("test/fixtures/real_gonzalo/chunks/lcbii.json").read).freeze
  FUJI = JSON.parse(Rails.root.join("test/fixtures/real_gonzalo/chunks/fuji_kone.json").read).freeze

  test "keeps LCB II voltages that the chunks state and removes an absent voltage" do
    # The F1 chunk states both "24 Vcc" (the supply the fuse protects) and
    # "30 Vcc" (the voltage absent when F1 opens). Pair occurrence keeps 24 V.
    answer = <<~TEXT.squish
      Verifique el fusible F1 4 A, que protege la alimentación de 24 V.
      Cuando F1 está quemado no hay tensión de 30 V.
      Ajuste el borne a 12 V antes de continuar.
    TEXT

    result = guard(answer, evidence: chunk_texts(LCB))

    assert_includes result[:answer], "24 V"
    assert_includes result[:answer], "30 V"
    assert_includes result[:answer], "F1 4 A"
    assert_not_includes result[:answer], "12 V"
    assert_equal 1, result[:removed]
    assert_equal 1, result[:answer].scan(I18n.t("rag.unsupported_value_removed", locale: :es)).size
  end

  test "keeps Fuji 5 percent and KONE 3 mm and 20 mm" do
    answer = "La diferencia máxima es 5 %. El desvío es 3 mm. C = 20 mm."

    result = guard(answer, evidence: chunk_texts(FUJI))

    assert_equal 0, result[:removed]
    assert_equal answer, result[:answer]
  end

  test "keeps a nameplate voltage that is only in this turn's photo block" do
    photo = "## Photo Evidence (this turn)\n- Visible text/codes: 380 V"
    answer = "La placa muestra 380 V."

    result = guard(answer, evidence: [ "procedimiento sin tension" ], allowed: [ "como se ajusta", photo ])

    assert_equal answer, result[:answer]
    assert_equal 0, result[:removed]
  end

  test "removes 24 V when it exists only in prior assistant history" do
    answer = "La alimentación es de 24 V."
    history = "El asistente dijo 24 V en el turno anterior."

    result = guard(
      answer,
      evidence: [ "F1 = 4A protege el circuito." ],
      allowed: [ "que tension hay", "que tension hay" ]
    )
    assert_includes history, "24 V"

    assert_not_includes result[:answer], "24 V"
    assert_equal 1, result[:removed]
  end

  test "a deterministic route with no evidence leaves the answer unchanged" do
    answer = "La alimentación es de 24 V."
    logged = log_lines do
      result = guard(answer, evidence: [])
      assert_equal answer, result[:answer]
      assert_equal 0, result[:removed]
    end

    assert_equal "no_evidence", logged.fetch("skipped")
  end

  test "keeps a visual spring comparison and removes an unsupported torque" do
    answer = "Los resortes se ven de largo distinto. Apriete a 30 N·m."

    result = guard(answer, evidence: [ "comparar los resortes visualmente" ])

    assert_includes result[:answer], "largo distinto"
    assert_not_includes result[:answer], "30"
    assert_equal 1, result[:removed]
  end

  test "removes an unsupported list item and keeps the supported one" do
    answer = "- Verifique 30 V.\n- Apriete a 12 V."

    result = guard(answer, evidence: [ "tensión de 30 Vcc" ])

    assert_includes result[:answer], "30 V"
    assert_not_includes result[:answer], "12 V"
    assert_equal 1, result[:removed]
  end

  private

  def guard(answer, evidence:, allowed: [])
    Rag::SourceFidelityGuard.call(
      answer: answer,
      evidence_texts: evidence,
      allowed_texts: allowed,
      locale: :es,
      correlation_id: "query:406f82ce-5071-42cb-b740-688ed9924b68"
    )
  end

  def chunk_texts(payload)
    payload.fetch("chunks").map { |chunk| chunk.fetch("text") }
  end

  def log_lines
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)
    yield
    line = output.string.lines.reverse.find { |entry| entry.include?("source_fidelity_guard") }
    JSON.parse(line[line.index("{")..])
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end
end
