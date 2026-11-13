# frozen_string_literal: true

require "test_helper"

class CompanionSignalReferenceTest < ActiveSupport::TestCase
  setup do
    @cases = JSON.parse(Rails.root.join("test/fixtures/files/field_companion/companion_revision/cea_reference_failures.json").read)
  end

  test "CEA T2 answers the three terminal definitions from the delivered page" do
    result = reference(2)
    assert_match(/Seguridad manual.*terminal SM/i, result)
    assert_includes result, "terminal SPC"
    assert_includes result, "terminal SA"
    assert_accepted(result, 2, [3])
  end

  test "CEA T3 keeps the two signal levels together in their literal rule" do
    result = reference(3)
    assert_includes result, '24 Vcc, o "0" si la tensión en el terminal correspondiente es 0 Vcc'
    assert_accepted(result, 3, [6])
  end

  test "CEA T5 drops an uncited heading while retaining the verified example and its pending contact" do
    data = @cases.fetch("5")
    backing = Rag::CompanionClaimBacking.call(text: data.fetch("raw"), sources: sources(5))
    refute_includes backing.text, "Según el Ejemplo 1 de la fuente"
    assert_includes backing.text, "Los contactos de traba de las puertas de piso se incluyen en SA"

    result = reference(5)
    assert_includes result, "contacto de traba por patín retráctil"
    assert_includes result, "¿El contacto de traba de la puerta de piso cierra por acción del patín retráctil?"
    refute_includes result, "SA no iría a SPC"
    assert_accepted(result, 5, [7])
  end

  test "a foreign passage or an unsupported question cannot supply a signal rule" do
    data = @cases.fetch("3")
    refute Rag::CompanionSignalReference.resolve(question: data.fetch("question"),
      sources: sources(3).map { |source| source&.merge("reference_only" => true) })
    refute Rag::CompanionSignalReference.resolve(question: "¿Qué tensión tiene el freno?", sources: sources(3))
  end

  private

  def reference(turn)
    Rag::CompanionSignalReference.resolve(question: @cases.fetch(turn.to_s).fetch("question"), sources: sources(turn),
      technician_texts: @cases.fetch(turn.to_s).fetch("history", []))
  end

  def sources(turn)
    rows = @cases.fetch(turn.to_s).fetch("rows")
    indexed = rows.index_by { |row| row.fetch("number") }
    Array.new(indexed.keys.max) do |index|
      row = indexed[index + 1]
      { "index" => index + 1, "content" => row&.fetch("content"), "reference_only" => row.nil? }
    end
  end

  def assert_accepted(answer, turn, citations)
    result = Rag::CompanionTurnPublication.call(text: answer, sources: sources(turn))
    assert result.accepted?, result.reasons.inspect
    assert_equal citations, result.quotes.pluck("source").uniq
  end
end
