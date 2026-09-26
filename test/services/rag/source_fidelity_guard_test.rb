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
    assert_no_match Rag::EvidenceSelectionTelemetry::ABSTENTION_PATTERN, result[:answer]
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

  test "does not read a lowercase a as amperes in a side comparison" do
    answer = "Compara los 2 a cada lado."

    result = guard(answer, evidence: [ "comparar visualmente" ])

    assert_equal answer, result[:answer]
    assert_equal 0, result[:removed]
  end

  test "does not read a lowercase a as amperes in a month interval" do
    answer = "Revisa cada 3 a 6 meses."

    result = guard(answer, evidence: [ "mantenimiento periodico" ])

    assert_equal answer, result[:answer]
    assert_equal 0, result[:removed]
  end

  test "keeps an F1 fuse rating of 4 A" do
    answer = "Verifique el fusible F1 4 A."

    result = guard(answer, evidence: [ "F1 = 4A: protege la fuente." ])

    assert_equal answer, result[:answer]
    assert_equal 0, result[:removed]
  end

  test "keeps a spring comparison that states no measured specification" do
    answer = "Revisa si un resorte está más comprimido que otro."

    result = guard(answer, evidence: [ "comparar los resortes visualmente" ])

    assert_equal answer, result[:answer]
    assert_equal 0, result[:removed]
  end

  test "accepts both celsius degree signs as the same unit" do
    answer = "La temperatura es 20 °C."

    result = guard(answer, evidence: [ "temperatura 20 ºC" ])

    assert_equal answer, result[:answer]
    assert_equal 0, result[:removed]
  end

  test "keeps each end of a shared-unit range" do
    slash = guard("La alimentación es 220 V.", evidence: [ "220/380 VAC" ])
    words = guard("La holgura mínima es 3 mm.", evidence: [ "entre 3 y 5 mm" ])
    dash = guard("Ajuste a 24 V.", evidence: [ "24–30 V" ])

    assert_equal 0, slash[:removed]
    assert_includes slash[:answer], "220 V"
    assert_equal 0, words[:removed]
    assert_includes words[:answer], "3 mm"
    assert_equal 0, dash[:removed]
    assert_includes dash[:answer], "24 V"
  end

  test "treats a trailing decimal zero as the same ampere value" do
    comma = guard("El fusible es de 4 A.", evidence: [ "4,0 A" ])
    dotted = guard("El fusible es de 4 A.", evidence: [ "4.00 A" ])

    assert_equal 0, comma[:removed]
    assert_includes comma[:answer], "4 A"
    assert_equal 0, dotted[:removed]
    assert_includes dotted[:answer], "4 A"
  end

  test "does not attach a later unit to an unbound step number" do
    answer = "La holgura es 3 mm."

    result = guard(answer, evidence: [ "paso 3 de 5, holgura 5 mm" ])

    assert_not_includes result[:answer], "3 mm"
    assert_equal 1, result[:removed]
  end

  test "removes the whole sentence after an abbreviation instead of splitting it" do
    page = "Según el manual LCB II, p. 4, la alimentación es 24 V. Ajuste a 12 V. Luego energiza."
    approx = "Deja aprox. 12 mm de holgura. Sigue con el otro lado."

    kept = guard(page, evidence: [ "alimentación de 24 Vcc" ])
    dropped = guard(approx, evidence: [ "sin esa medida" ])

    assert_includes kept[:answer], "p. 4, la alimentación es 24 V."
    assert_not_includes kept[:answer], "12 V"
    assert_includes kept[:answer], "Luego energiza."
    assert_no_match(/p\.\s+(?:Luego|Ajuste)/, kept[:answer])
    assert_not_includes dropped[:answer], "aprox"
    assert_not_includes dropped[:answer], "12 mm"
    assert_includes dropped[:answer], "Sigue con el otro lado."
    assert_equal 1, dropped[:removed]
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
