# frozen_string_literal: true

require "test_helper"

class Rag::CompanionStatementsTest < ActiveSupport::TestCase
  FIXTURE = Rails.root.join("test/fixtures/field_companion/vf5")

  test "the reopen group keeps its checks, its conditional continuation, and the next symptom apart" do
    statements = Rag::CompanionStatements.parse([
      chunk(FIXTURE.join("chunk_p12_5.txt").read, page: "12"),
      chunk(FIXTURE.join("chunk_p13_1.txt").read, page: "13")
    ])
    reopen = "La puerta se re-abre sola."
    steps = statements.statements.select { |item| item.step? && item.item == reopen }

    assert_equal [
      "Comprobar la sensibilidad del potenciómetro de regulación de fuerza de re-apertura (#54).",
      "Comprobar que la fotocélula no esté activada.",
      "Comprobar que no hay una obstrucción mecánica en la puerta.",
      "En caso que el problema persista, desconectar la fotocélula y volver a pulsar el botón de TEST. Si la puerta no se abre o cierra completamente, debe haber una obstrucción mecánica en la puerta."
    ], steps.map(&:text)
    assert_equal [ "12", "12", "12", "13" ], steps.map(&:page)
    assert_equal "8.2 Funcionamiento normal", steps.first.section
    assert steps.last.text.start_with?("En caso que el problema persista")

    other = statements.statements.find { |item| item.text == "La puerta no alcanza la posición de apertura completa." }
    assert_equal "item", other.kind
    assert_not_equal reopen, other.item
    assert statements.statements.none? { |item| item.item == reopen && item.text.match?(/\A(paso\s*)?\d+[\).]/i) }
    assert_equal %i[id source kind text section item page], Rag::CompanionStatements::Statement.members
  end

  test "an extractor note is not split into document text and a manufacturer note stays" do
    body = <<~TEXT
      6.1 Averías
      • El motor se para solo.
      – Comprobar el sensor.
      Nota: Retirar el cableado de la fotocélula de cualquier lugar con interferencias eléctricas.
      Notes: row numbers are printed as shown (the table skips 14). The page does not define the codes; those meanings are DATA_NOT_AVAILABLE here.
      [NOTA_EXTRACCION] Nota: en la tabla de frecuencia, 50 figura en Mínimo y 60 en Máximo.
      [TRANSCRIPCIÓN_VISUAL_LOCAL: lectura local, no es texto del fabricante.]
    TEXT
    parsed = Rag::CompanionStatements.parse([ chunk(body) ])
    kinds = parsed.statements.to_h { |item| [ item.text, item.kind ] }

    assert_equal "text", kinds["Nota: Retirar el cableado de la fotocélula de cualquier lugar con interferencias eléctricas."]
    note = "Notes: row numbers are printed as shown (the table skips 14). The page does not define the codes; those meanings are DATA_NOT_AVAILABLE here."
    assert_equal "extraction_note", kinds[note]
    assert_nil kinds["Notes: row numbers are printed as shown (the table skips 14)."]
    assert_equal "extraction_note", kinds["[NOTA_EXTRACCION] Nota: en la tabla de frecuencia, 50 figura en Mínimo y 60 en Máximo."]
    assert_nil kinds["[TRANSCRIPCIÓN_VISUAL_LOCAL: lectura local, no es texto del fabricante.]"]
    assert_equal "step", kinds["Comprobar el sensor."]

    block = Rag::CompanionPlan.statements_block(parsed, [ chunk(body) ])
    assert_includes block, "Nota: Retirar el cableado"
    assert_not_includes block, "DATA_NOT_AVAILABLE"
    assert_not_includes block, "NOTA_EXTRACCION"
    assert_not_includes block, "tabla de frecuencia"
  end

  private

  def chunk(content, page: "1")
    {
      content: content,
      metadata: { "canonical_name" => "VF5.pdf", "page_number" => page, "original_source_uri" => "s3://local/VF5.pdf" },
      identity_applicability: "compatible"
    }
  end
end
