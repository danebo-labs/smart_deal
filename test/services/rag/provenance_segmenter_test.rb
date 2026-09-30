# frozen_string_literal: true

require "test_helper"

class Rag::ProvenanceSegmenterTest < ActiveSupport::TestCase
  test "a marker that resolves to a server citation is a manual fact" do
    segments = segment("El procedimiento indica desconectar la alimentación [1].", citations: cite(1))

    assert_equal "MANUAL_FACT", segments.sole["band"]
    assert_equal "El procedimiento indica desconectar la alimentación.", segments.sole["text"]
  end

  test "a cited manual sentence keeps its prefix and drops the resolved marker" do
    segments = segment("Según el manual: el ajuste se realiza en ambos lados [1].", citations: cite(1))

    assert_equal "MANUAL_FACT", segments.sole["band"]
    assert_includes segments.sole["text"], "Según el manual:"
    assert_not_includes segments.sole["text"], "[1]"
  end

  test "an unresolved marker is not a manual fact" do
    segments = segment("El fabricante indica X [99].", citations: cite(1, 2))

    assert_equal "DANEBO_GUIDANCE", segments.sole["band"]
    assert_includes segments.sole["text"], "[99]"
  end

  test "citation numbers may arrive as strings" do
    segments = segment(
      "Desconectá la alimentación [1].",
      citations: [ { "number" => "1", "title" => "Manual" } ]
    )

    assert_equal "MANUAL_FACT", segments.sole["band"]
  end

  test "según el manual without a citation is guidance and loses the prefix" do
    segments = segment("Según el manual: revisá el resorte antes de continuar.")

    assert_equal "DANEBO_GUIDANCE", segments.sole["band"]
    assert_equal "revisá el resorte antes de continuar.", segments.sole["text"]
    assert_not_includes segments.sole["text"].downcase, "según el manual"
  end

  test "a schematic pin that is not a citation stays in the guidance text" do
    segments = segment("Ver borne [24].", citations: cite(1))

    assert_equal "DANEBO_GUIDANCE", segments.sole["band"]
    assert_includes segments.sole["text"], "[24]"
  end

  test "a sentence based on canonical_component is a visual observation" do
    segments = segment("Componente conjunto de resortes.", observation: observation)

    assert_equal "VISUAL_OBSERVATION", segments.sole["band"]
  end

  test "a sentence based on the observed manufacturer is a visual observation" do
    segments = segment("Fabricante KONE.", observation: observation)

    assert_equal "VISUAL_OBSERVATION", segments.sole["band"]
  end

  test "a sentence based on the observed model is a visual observation" do
    segments = segment("Modelo MX20.", observation: observation)

    assert_equal "VISUAL_OBSERVATION", segments.sole["band"]
  end

  test "a sentence based on visible_text is a visual observation" do
    segments = segment("Texto 708A.", observation: observation)

    assert_equal "VISUAL_OBSERVATION", segments.sole["band"]
  end

  test "without a valid observation there is no visual segment" do
    segments = segment("En la foto: se observa KONE.")

    assert_equal [ "DANEBO_GUIDANCE" ], segments.pluck("band")
  end

  test "an invalid observation payload does not create a visual segment" do
    segments = segment("Fabricante KONE.", observation: { "manufacturer" => "KONE", "summary" => "prosa" })

    assert_equal [ "DANEBO_GUIDANCE" ], segments.pluck("band")
  end

  test "summary aliases and condition are not visual authority" do
    raw = observation.merge(
      "summary" => "tablero secreto",
      "aliases" => [ "muelle" ],
      "documented_functions" => [ "frenar" ]
    )
    segments = segment(
      "En la foto: tablero secreto. En la foto: se observa un muelle. La condición es DEGRADED.",
      observation: raw
    )

    assert_equal [ "DANEBO_GUIDANCE", "DANEBO_GUIDANCE", "DANEBO_GUIDANCE" ], segments.pluck("band")
  end

  test "the mechanical photo line is not a manual fact" do
    line = "[FOTO] Componente: conjunto de resortes | Fabricante: KONE | Modelo: MX20 | Códigos: 708A | Condición: DEGRADED"
    segments = segment(line, observation: observation)

    assert_equal [ "DANEBO_GUIDANCE" ], segments.pluck("band")
  end

  test "a manufacturer name inside an uncited procedure is not a visual observation" do
    segments = segment("El procedimiento KONE recomienda revisar el freno del equipo.", observation: observation)

    assert_equal [ "DANEBO_GUIDANCE" ], segments.pluck("band")
  end

  test "an uncited answer without a photo is guidance" do
    segments = segment("Podés empezar revisando la alimentación antes de desmontar.")

    assert_equal [ "DANEBO_GUIDANCE" ], segments.pluck("band")
  end

  test "a danebo recommendation is guidance and keeps its prefix" do
    segments = segment("Para revisar: verificá primero que ambos lados tengan una carga similar.")

    assert_equal "DANEBO_GUIDANCE", segments.sole["band"]
    assert_includes segments.sole["text"], "Para revisar:"
  end

  test "an answer whose sentences are all cited stays manual" do
    segments = segment("Desconectá la alimentación [1]. Verificá el contacto [2].", citations: cite(1, 2))

    assert_equal %w[MANUAL_FACT MANUAL_FACT], segments.pluck("band")
  end

  test "a visual-only answer does not invent a manual fact" do
    segments = segment("En la foto: se observan resortes en el conjunto.", observation: observation)

    assert_equal [ "VISUAL_OBSERVATION" ], segments.pluck("band")
  end

  test "a valid citation wins over a visual match in the same sentence" do
    segments = segment("En la foto: se observa KONE [1].", citations: cite(1), observation: observation)

    assert_equal "MANUAL_FACT", segments.sole["band"]
  end

  test "a technician manufacturer stays guidance and the photo manufacturer can be visual" do
    segments = segment(
      "El fabricante es Fuji Yida. En la foto: se observa KONE.",
      observation: observation
    )

    assert_equal [ "DANEBO_GUIDANCE", "VISUAL_OBSERVATION" ], segments.pluck("band")
    assert_equal "El fabricante es Fuji Yida.", segments.first["text"]
    assert_includes segments.last["text"], "KONE"
    assert segments.none? { |item| item["band"] == "MANUAL_FACT" }
    assert_not_includes segments.first["text"], "KONE"
  end

  test "a mixed answer keeps manual, visual, and guidance in order" do
    answer = [
      "Según el manual: el ajuste se realiza en ambos lados [1].",
      "En la foto: se observan resortes en el conjunto.",
      "Para revisar: verificá primero que ambos lados tengan una carga similar."
    ].join(" ")
    segments = segment(answer, citations: cite(1), observation: observation)

    assert_equal %w[MANUAL_FACT VISUAL_OBSERVATION DANEBO_GUIDANCE], segments.pluck("band")
    assert_includes segments[0]["text"], "Según el manual:"
    assert_includes segments[1]["text"], "En la foto:"
    assert_includes segments[2]["text"], "Para revisar:"
    assert_not_includes segments[0]["text"], "[1]"
  end

  test "a manual suggestion sentence is not a manual fact" do
    segments = segment(
      "Manual Schindler 3300. manual de la misma marca; compatibilidad con este equipo no confirmada"
    )

    assert segments.all? { |item| item["band"] == "DANEBO_GUIDANCE" }
  end

  test "blank text and marker-only sentences are dropped" do
    assert_empty segment("  \n[1]\n", citations: cite(1))
    assert_empty segment("[99]")
    assert_empty segment("Según el manual:")
  end

  test "generation prompt names each provenance prefix once" do
    raw = Rails.root.join("app/prompts/bedrock/generation.txt").read
    grounded = BedrockRagService.load_generation_prompt_template(grounded_synthesis: true)
    strict = BedrockRagService.load_generation_prompt_template(grounded_synthesis: false)

    [ "Según el manual:", "En la foto:", "Para revisar:" ].each do |prefix|
      assert_equal 1, raw.scan(prefix).size, prefix
      assert_equal 1, grounded.scan(prefix).size, prefix
      assert_equal 0, strict.scan(prefix).size, prefix
    end
  end

  test "the web answer presenter displays server bands and does not read the payload key" do
    source = Rails.root.join("app/javascript/rag/answer_presenter.js").read

    assert_includes source, "MANUAL_FACT"
    assert_includes source, "VISUAL_OBSERVATION"
    assert_includes source, "DANEBO_GUIDANCE"
    assert_includes source, "Guía Danebo"
    assert_not_includes source, "provenance_segments"
  end

  private

  def segment(answer, citations: [], observation: nil)
    Rag::ProvenanceSegmenter.call(answer: answer, citations: citations, visual_observation: observation)
  end

  def cite(*numbers)
    numbers.map { |number| { number: number, title: "Manual #{number}" } }
  end

  def observation(overrides = {})
    FieldPhotoObservation.from_analysis(
      parsed: {
        "canonical_component" => "conjunto de resortes",
        "manufacturer" => "KONE",
        "model" => "MX20",
        "subsystem" => "DOOR_OPERATOR",
        "condition" => "DEGRADED",
        "visible_text" => [ "708A" ],
        "target_visible" => true,
        "relevance_to_goal" => "relevant"
      }.merge(overrides),
      model_id: "claude-sonnet-5-5"
    )
  end
end
