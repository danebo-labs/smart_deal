# frozen_string_literal: true

require "test_helper"

# Replay 1 of the live Otis case 29 (run 20261120T133511Z), turns T1 to T4.
# The generator followed the context it was given in T1 (it asked for the
# event) but the claim guard removed the cited lines that carried the answer
# and the publication fell back to a refusal. The fixture holds, per turn, the
# sources the generator received and its raw draft. The guard is the real one.
class Rag::OtisCase29LiveRun2Test < ActiveSupport::TestCase
  RUN = JSON.parse(Rails.root.join("test/fixtures/files/field_companion/otis_case29_live_20261120T133511Z.json").read).fetch("turns")

  # What the guard still removes, and why it is right to: «clase W, es decir,
  # advertencia» (the row says W, not advertencia), the 694/894 "discrepancy"
  # (an I/O number is not the parameter) and the rear door RDCL claim (no source
  # line ties it to this door).
  STILL_REMOVED = {
    "t1" => [],
    "t2" => [ "En la tabla aparece como clase W, es decir, advertencia [1]." ],
    "t3" => [ "Hay una discrepancia: [4] da DCL como I/O 894, y [1][2] lo citan como parámetro 694.",
              "Si la puerta fuera la trasera, la señal sería RDCL (695) [1][4]." ],
    "t4" => [ "Según [5], DCL figura como I/O-894 y, en [1], [2] y [3], como 694." ]
  }.freeze

  test "live, the guard removed the cited lines that carried the answer in T1, T2 and T4" do
    assert_equal 2, RUN.dig("t1", "live_removed").size
    assert_includes RUN.dig("t1", "live_published"), "No encontré evidencia suficiente"
    assert_not_includes RUN.dig("t1", "live_published"), "evento"
    assert_includes RUN.dig("t2", "live_removed").first, "faltó alguna de las señales DCL, DFC o DW"
    assert_includes RUN.dig("t4", "live_removed").first, "no logra cerrar dentro del tiempo permitido"
  end

  test "with the corrected guard the same drafts keep their cited reading and lose only what no line says" do
    STILL_REMOVED.each do |label, expected|
      removed = backing(label).removed.pluck("sentence")

      assert_equal expected, removed, label
    end
  end

  test "T1 keeps the request for the event, the documented lines and the applicability limit" do
    result = backing("t1")

    assert_includes result.text, "necesito el código o evento que muestra la consola"
    assert_includes result.text, "revisar las señales del PAX y las de reapertura en LCB_II [2]"
    assert_includes result.text, "(DOS) figura en el manual [3]"
    assert_includes result.text, "¿Qué código o evento aparece en la consola para la puerta del piso 3?"
  end

  test "T2 keeps what 0102 means with the three signals" do
    assert_includes backing("t2").text, "faltó alguna de las señales DCL, DFC o DW [2][3]"
  end

  private

  def backing(label)
    turn = RUN.fetch(label)
    by_number = turn.fetch("sources").index_by { |source| source.fetch("n") }
    sources = by_number.map { |number, source| { "index" => number, "content" => source.fetch("text"), "applicability" => "compatible" } }
    chunks = (1..by_number.keys.max).map { |number| { content: by_number[number]&.fetch("text").to_s, case_number: number, metadata: {} } }
    Rag::CompanionClaimBacking.call(text: turn.fetch("raw_draft"), sources: chunks.map.with_index(1) { |chunk, index| chunk.merge("index" => index, "content" => chunk[:content]) })
  end
end
