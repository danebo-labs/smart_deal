# frozen_string_literal: true

require "test_helper"

class Rag::CompanionCitedFloorTest < ActiveSupport::TestCase
  FIXTURE = Rails.root.join("test/fixtures/files/field_companion/companion_revision/thyssen_kpvs.json")

  setup do
    data = JSON.parse(FIXTURE.read)
    @noise = data.dig("quotes", "noise")
    page = data.fetch("indexed").find { |row| row["page"] == 18 }
    @page18 = data.dig("passages", page.fetch("sha256"))
    @cited = "El KP-VS reportado de 2,5 ya está por debajo del mínimo de 3,0: «#{@noise}» [1]"
  end

  test "drops a further decrease when the reported value is already under the cited minimum" do
    cited = "Para el ruido muy elevado, la sección de ajuste por ruido indica «#{@noise}» [1]."
    result = call("#{cited}\n\nComo KP-VS está en 2,5, redúcelo aún más.", @page18, "KP-VS está en 2,5")

    assert_equal "#{cited}\n\nComo KP-VS está en 2,5.", result.text
    assert_equal [ "below_cited_minimum" ], result.removed.pluck("reason")
  end

  test "keeps the negation and the quoted manual instruction" do
    text = "#{@cited}. No lo reduzcas más."
    result = call(text, @page18, "KP-VS está en 2,5")

    assert_equal text, result.text
    assert_empty result.removed
  end

  test "keeps a decrease that stays above the minimum" do
    text = "KP-VS está en 4,0. Disminuye KP-VS."
    result = call(text, @page18, "KP-VS está en 4,0")

    assert_equal text, result.text
    assert_empty result.removed
  end

  test "at the exact minimum a further decrease leaves and the acknowledgement stays" do
    kept = "El KP-VS reportado de 3,0 ya está en el mínimo: «#{@noise}» [1]"
    result = call("#{kept}. Sigue bajando KP-VS un poco más.", @page18, "KP-VS está en 3,0")

    assert_equal "#{kept}.", result.text
    assert_equal [ "below_cited_minimum" ], result.removed.pluck("reason")
  end

  test "an explicit target under the minimum leaves even when the reported value is above it" do
    technician = "KP-VS está en 4,0"
    {
      "Baja KP-VS a 1,5." => "",
      "Reduce KP-VS hasta 2,0." => "",
      "Baja KP-VS en 2,0." => "",
      "Baja KP-VS por debajo de 3,0." => "",
      "Con KP-VS en 4,0, bájalo a 1,5." => " Con KP-VS en 4,0."
    }.each do |sentence, left|
      result = call("#{@cited}. #{sentence}", @page18, technician)
      assert_equal "#{@cited}.#{left}", result.text, sentence
      assert_equal 1, result.removed.size, sentence
    end

    [ "Baja KP-VS a 3,0.", "Baja KP-VS a 3,5.", "Baja KP-VS en 0,5.", "Baja KP-VS hasta el mínimo." ].each do |sentence|
      text = "#{@cited}. #{sentence}"
      result = call(text, @page18, technician)
      assert_equal text, result.text, sentence
      assert_empty result.removed, sentence
    end
  end

  test "a shared figure does not attach the limit to another action" do
    text = "#{@cited}. Reduce la velocidad de inspección a 2,5."
    result = call(text, @page18, "KP-VS está en 2,5")

    assert_equal text, result.text
    assert_empty result.removed
  end

  test "a mention inside a quotation is not the evaluated action" do
    quoted = "El manual dice «reduce KP-VS a 1,5» [1]."
    result = call(quoted, @page18, "KP-VS está en 2,5")

    assert_equal quoted, result.text
    assert_empty result.removed
  end

  test "the minimum of another parameter does not limit this one" do
    content = "- En caso de ruido: disminuya el valor del parámetro \"KP-SLIP\", hasta el mínimo de [3,0]."
    text = "Baja KP-VS a 1,5."
    result = call(text, content, "KP-VS está en 2,5")

    assert_equal text, result.text
    assert_empty result.removed
  end

  test "a minimum with no parameter in its own statement is not attributed from a neighbour" do
    content = "- Ajuste del parámetro \"KP-VS\".\n- Disminuya el valor hasta el mínimo de [3,0]."
    text = "Baja KP-VS a 1,5."
    result = call(text, content, "KP-VS está en 2,5")

    assert_equal text, result.text
    assert_empty result.removed
  end

  test "a statement naming two parameters gives neither a limit" do
    content = "- Disminuya los parámetros \"KP-VS\" y \"KP-SLIP\" hasta el mínimo de [3,0]."
    result = call("Baja KP-VS a 1,5.", content, "KP-VS está en 2,5")

    assert_empty result.removed
  end

  test "a negation covers only its own action" do
    result = call("#{@cited}. No reinicies y baja KP\u2011VS.", @page18, "KP\u2011VS está en 2,5")

    assert_equal "#{@cited}. No reinicies.", result.text
    assert_equal [ "baja KP\u2011VS" ], result.removed.pluck("clause")

    both = "#{@cited}. No reinicies ni bajes KP-VS."
    kept = call(both, @page18, "KP-VS está en 2,5")
    assert_equal both, kept.text
    assert_empty kept.removed

    other = call("#{@cited}. No reinicies, baja KP-VS.", @page18, "KP-VS está en 2,5")
    assert_equal "#{@cited}. No reinicies.", other.text
  end

  test "an order sharing a sentence with the cited evidence leaves the evidence" do
    result = call("#{@cited}, así que redúcelo aún más.", @page18, "KP-VS está en 2,5")
    assert_equal "#{@cited}.", result.text

    leading = call("Reduce KP-VS aún más, pues «#{@noise}» [1].", @page18, "KP-VS está en 2,5")
    assert_equal "«#{@noise}» [1].", leading.text

    middle = call("El KP-VS está en 2,5, redúcelo aún más y revisa el cableado.", @page18, "KP-VS está en 2,5")
    assert_equal "El KP-VS está en 2,5, revisa el cableado.", middle.text
  end

  test "mentioning Engineering does not protect an order" do
    text = "La revisión del ajuste corresponde a Ingeniería, pero baja KP-VS a 1,5."
    result = call(text, @page18, "KP-VS está en 2,5")

    assert_equal "La revisión del ajuste corresponde a Ingeniería.", result.text
    assert_equal [ "baja KP-VS a 1,5" ], result.removed.pluck("clause")
  end

  test "a value reported in a question is not a report" do
    result = call("Baja KP-VS.", @page18, "¿Dejo KP-VS en 2,5?")

    assert_equal "Baja KP-VS.", result.text
    assert_empty result.removed
  end

  test "a question about a decrease stays" do
    text = "¿Ya intentaste reducir KP-VS?"
    result = call(text, @page18, "KP-VS está en 2,5")

    assert_equal text, result.text
    assert_empty result.removed
  end

  test "does not invent a floor from an unnumbered mention" do
    result = call("Disminuye KP-VS.", "Parâmetro KP-VS baixo.", "KP-VS está en 2,5")

    assert_equal "Disminuye KP-VS.", result.text
    assert_empty result.removed
  end

  test "a decrease about another subject stays" do
    result = call("Reduce la velocidad de inspección.", @page18, "KP-VS está en 2,5")

    assert_equal "Reduce la velocidad de inspección.", result.text
    assert_empty result.removed
  end

  test "an order with an implied object follows the parameter of its sentence or of the one before it" do
    same = call("El KP-VS está en 2,5. Redúcelo aún más.", @page18, "KP-VS está en 2,5")
    assert_equal "El KP-VS está en 2,5.", same.text

    apart = "El KP-VS está en 2,5.\n\nRedúcelo aún más."
    assert_equal apart, call(apart, @page18, "KP-VS está en 2,5").text

    quoted = "Indica «#{@noise}» [1]. Redúcelo aún más."
    assert_equal quoted, call(quoted, @page18, "KP-VS está en 2,5").text

    generic = call("KP-VS está en 2,5, reduce el valor aún más.", @page18, "KP-VS está en 2,5")
    assert_equal "KP-VS está en 2,5.", generic.text
  end

  private

  def call(text, content, technician)
    Rag::CompanionCitedFloor.call(
      text: text,
      sources: [ { "content" => content } ],
      technician_texts: [ technician ]
    )
  end
end
