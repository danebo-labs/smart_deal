# frozen_string_literal: true

require "test_helper"

class RagRetrievalProfileTest < ActiveSupport::TestCase
  test "procedural_query matches an adjustment and not a fault report" do
    assert RagRetrievalProfile.new(question: "el modelo es MonoSpace, como se ajustan los resortes?").procedural_query?
    assert_not RagRetrievalProfile.new(question: "KONE muestra código 8 y no nivela").procedural_query?
    assert_not RagRetrievalProfile.new(question: "En Thyssen-E, ¿qué LED señala una condición normal y cuál un fallo?").procedural_query?
  end

  test "returns 8 when no entities pinned" do
    profile = RagRetrievalProfile.new(entity_sources: [])
    assert_equal 8, profile.number_of_results
  end

  test "returns 10 for photo-only session" do
    profile = RagRetrievalProfile.new(entity_sources: [ "image_upload", "image_upload" ])
    assert_equal 10, profile.number_of_results
  end

  test "returns 3 for document-only session" do
    profile = RagRetrievalProfile.new(entity_sources: [ "document", "document" ])
    assert_equal 3, profile.number_of_results
  end

  test "returns 3 for mixed photo+document session" do
    profile = RagRetrievalProfile.new(entity_sources: [ "image_upload", "document" ])
    assert_equal 3, profile.number_of_results
  end

  test "single photo pin returns 10" do
    assert_equal 10, RagRetrievalProfile.new(entity_sources: [ "image_upload" ]).number_of_results
  end

  test "single document pin returns 3" do
    assert_equal 3, RagRetrievalProfile.new(entity_sources: [ "document" ]).number_of_results
  end

  test "structured route eligibility does not widen the shared pinned budget" do
    profile = RagRetrievalProfile.new(
      entity_sources: [ "document" ],
      question: "¿Qué indica el LED ABC12?"
    )

    assert_equal RagRetrievalProfile::PINNED_DOCUMENT_RESULTS, profile.number_of_results
    assert profile.structured_mapping_query?
  end

  test "co-occurrence activates when a digit-bearing identifier precedes the label" do
    profile = RagRetrievalProfile.new(
      entity_sources: [ "document" ],
      question: "En ZZ9000 V1, ¿qué conectores documenta el encabezado de la placa?"
    )

    assert profile.structured_mapping_query?
    assert_equal RagRetrievalProfile::PINNED_DOCUMENT_RESULTS, profile.number_of_results
  end

  test "co-occurrence activates when words separate the label and identifiers" do
    profile = RagRetrievalProfile.new(
      entity_sources: [ "document" ],
      question: "¿Qué LEDs documenta el manual y qué significan L9, L8 y L7?"
    )

    assert profile.structured_mapping_query?
    assert_equal RagRetrievalProfile::PINNED_DOCUMENT_RESULTS, profile.number_of_results
  end

  test "keeps three results for a comparative pinned mapping query" do
    profile = RagRetrievalProfile.new(
      entity_sources: [ "document" ],
      question: "Compara los LED ABC12 y XYZ34"
    )

    assert_equal RagRetrievalProfile::PINNED_DOCUMENT_RESULTS, profile.number_of_results
    assert_not profile.structured_mapping_query?
  end

  test "safety-critical budget takes precedence over a structured mapping query" do
    profile = RagRetrievalProfile.new(
      entity_sources: [ "document" ],
      question: "Si falla el LED ABC12, ¿debo detener el trabajo?"
    )

    assert_equal RagRetrievalProfile::SAFETY_CRITICAL_RESULTS, profile.number_of_results
  end

  test "keeps three results for a generic pinned question without an identifier" do
    profile = RagRetrievalProfile.new(
      entity_sources: [ "document" ],
      question: "¿Qué indica esta señal?"
    )

    assert_equal RagRetrievalProfile::PINNED_DOCUMENT_RESULTS, profile.number_of_results
  end

  test "a structured query without a pin keeps the open-query budget" do
    profile = RagRetrievalProfile.new(
      entity_sources: [],
      question: "¿Qué indica el LED ABC12?"
    )

    assert_equal RagRetrievalProfile::OPEN_RESULTS, profile.number_of_results
  end

  test "a structured query with only a photo pin keeps the photo budget" do
    profile = RagRetrievalProfile.new(
      entity_sources: [ "image_upload" ],
      question: "¿Qué indica el LED ABC12?"
    )

    assert_equal RagRetrievalProfile::PHOTO_RESULTS, profile.number_of_results
  end

  test "numeric distractors and a label without an identifier do not activate co-occurrence" do
    cases = {
      "¿Qué información aparece en la página 31 del manual?" => RagRetrievalProfile::PINNED_DOCUMENT_RESULTS,
      "¿Cuántos pines tiene el conector de maniobra?" => RagRetrievalProfile::PINNED_DOCUMENT_RESULTS,
      "¿Qué tensión de 220 V documenta el esquema de alimentación?" => RagRetrievalProfile::PINNED_DOCUMENT_RESULTS,
      "¿Cuántos LEDs hay en total en el cuadro?" => RagRetrievalProfile::PINNED_DOCUMENT_RESULTS
    }

    cases.each do |question, expected_budget|
      profile = RagRetrievalProfile.new(entity_sources: [ "document" ], question: question)
      assert_not profile.structured_mapping_query?, "unexpected structured activation for: #{question}"
      assert_equal expected_budget, profile.number_of_results
    end
    assert_empty Rag::QueryEntities.analyze(
      "¿Qué tensión de 220 V documenta el esquema de alimentación?"
    ).identifiers
  end

  test "comparative shapes stay outside the route with the narrow budget" do
    [
      "Compara los conectores de la placa A100 y la placa B200",
      "¿Qué diferencias hay entre las placas X1 y X2 en sus LEDs?"
    ].each do |question|
      profile = RagRetrievalProfile.new(entity_sources: [ "document" ], question: question)
      assert_not profile.structured_mapping_query?
      assert_equal RagRetrievalProfile::PINNED_DOCUMENT_RESULTS, profile.number_of_results
      assert_not route_eligible?(profile, entity_sources: [ "document" ])
    end
  end

  test "an alphabetic manufacturer-shaped token without a model does not activate co-occurrence" do
    profile = RagRetrievalProfile.new(
      entity_sources: [ "document" ],
      question: "En FOOBAR, ¿qué LEDs documenta el manual?"
    )

    assert_not profile.structured_mapping_query?
    assert_equal RagRetrievalProfile::PINNED_DOCUMENT_RESULTS, profile.number_of_results
  end

  test "an unknown digit-bearing model remains structurally eligible" do
    profile = RagRetrievalProfile.new(
      entity_sources: [ "document" ],
      question: "En la placa ZZ9000, ¿qué LED indica la serie de puertas?"
    )

    assert profile.structured_mapping_query?
    assert_equal RagRetrievalProfile::PINNED_DOCUMENT_RESULTS, profile.number_of_results
  end

  test "versioned co-occurrence keeps the variant separate" do
    profile = RagRetrievalProfile.new(
      entity_sources: [ "document" ],
      question: "En QQ7 V2, ¿qué conectores documenta el encabezado?"
    )
    normalized = Rag::QueryEntities.normalize("QQ7 V2")

    assert profile.structured_mapping_query?
    assert_equal "QQ7", normalized.model_key
    assert_equal "V2", normalized.variant
  end

  test "generic questions keep the narrow budget and stay outside the route" do
    [
      "¿Cómo pruebo el freno?",
      "¿Cómo se conectan los cerrojos en las placas de seguridad?"
    ].each do |question|
      profile = RagRetrievalProfile.new(entity_sources: [ "document" ], question: question)
      assert_not profile.structured_mapping_query?
      assert_equal RagRetrievalProfile::PINNED_DOCUMENT_RESULTS, profile.number_of_results
    end
  end

  test "safety and photo guards keep their budgets and prevent live route eligibility" do
    safety = RagRetrievalProfile.new(
      entity_sources: [ "document" ],
      question: "Si el LED A100 falla, ¿debo detener el trabajo?"
    )
    photo = RagRetrievalProfile.new(
      entity_sources: [ "image_upload" ],
      question: "¿Qué indica el LED A100?"
    )

    assert_equal RagRetrievalProfile::SAFETY_CRITICAL_RESULTS, safety.number_of_results
    assert_not route_eligible?(safety, entity_sources: [ "document" ])
    assert_equal RagRetrievalProfile::PHOTO_RESULTS, photo.number_of_results
    assert_not route_eligible?(photo, entity_sources: [ "image_upload" ])
  end

  test "handles nil in entity_sources array" do
    profile = RagRetrievalProfile.new(entity_sources: [ nil, "document" ])
    assert_equal 3, profile.number_of_results
  end

  test "returns 15 for an exhaustive Spanish test query" do
    profile = RagRetrievalProfile.new(
      entity_sources: [ "document" ],
      question: "Enumera todas las pruebas de funcionamiento antes de operar"
    )

    assert_equal 15, profile.number_of_results
    assert_equal 12, profile.number_of_reranked_results
  end

  test "returns 15 for an exhaustive English query" do
    profile = RagRetrievalProfile.new(
      entity_sources: [ "document" ],
      question: "Give me the complete checklist"
    )

    assert_equal 15, profile.number_of_results
  end

  test "does not expand a normal specific query" do
    profile = RagRetrievalProfile.new(
      entity_sources: [ "document" ],
      question: "¿Cómo pruebo el freno?"
    )

    assert_equal 3, profile.number_of_results
    assert_nil profile.number_of_reranked_results
  end

  test "uses five results for stop-work intent" do
    profile = RagRetrievalProfile.new(
      entity_sources: [ "document" ],
      question: "¿Cuándo debo detener el trabajo?"
    )

    assert_equal 5, profile.number_of_results
  end

  test "uses five results for failure and repair intent" do
    profile = RagRetrievalProfile.new(
      entity_sources: [ "document" ],
      question: "Si una prueba falla, ¿quién puede reparar la máquina?"
    )

    assert_equal 5, profile.number_of_results
  end

  test "treats a natural plural functional-test question as exhaustive" do
    profile = RagRetrievalProfile.new(
      entity_sources: [ "document" ],
      question: "¿Qué pruebas funcionales previas al uso indica el manual?"
    )

    assert_equal 15, profile.number_of_results
  end

  test "widens open schematic block/connector query to MAX_RESULTS" do
    [
      "¿Qué texto visible aparece asociado a -PBCM -J26?",
      "¿Qué conectores visibles aparecen en el bloque -PDCC?",
      "¿Qué conectores visibles aparecen en el bloque -PDCM?"
    ].each do |q|
      profile = RagRetrievalProfile.new(entity_sources: [], question: q)
      assert_equal RagRetrievalProfile::MAX_RESULTS, profile.number_of_results,
                   "expected schematic recall bump for: #{q}"
    end
  end

  test "does not widen open query without a schematic designator" do
    profile = RagRetrievalProfile.new(
      entity_sources: [],
      question: "PDCM PBCM POSICIONAMIENTO TIPO 3"
    )
    assert_equal 8, profile.number_of_results
  end

  test "schematic bump does not override a pinned-document budget" do
    profile = RagRetrievalProfile.new(
      entity_sources: [ "document" ],
      question: "¿Qué conectores visibles aparecen en el bloque -PDCC?"
    )
    assert_equal 3, profile.number_of_results
  end

  # Regression guard: widening the pinned-document budget for comparative
  # wording was measured on 2026-07-26 and rejected — top-k 6 added off-topic
  # pages and cost the em3000 comparison case a critical penalized hit.
  test "a comparative pinned-document query keeps the narrow document budget" do
    [
      "Compara las dos fotocélulas de EM3000: ¿qué tensión documenta cada una?",
      "¿La configuración aplica a ambas versiones?",
      "Compare both wiring diagrams"
    ].each do |question|
      profile = RagRetrievalProfile.new(entity_sources: [ "document" ], question: question)
      assert_equal RagRetrievalProfile::PINNED_DOCUMENT_RESULTS,
                   profile.number_of_results,
                   "expected the narrow pinned budget for: #{question}"
    end
  end

  test "pinned exact designator lookup stays on the narrow document budget" do
    profile = RagRetrievalProfile.new(entity_sources: [ "document" ], question: "¿Qué es K1?")

    assert profile.pinned_exact_designator_lookup?(document_pins: 1)
    assert_equal RagRetrievalProfile::PINNED_DOCUMENT_RESULTS, profile.number_of_results
  end

  test "an unpinned exact designator keeps the open budget and stays off the branch" do
    profile = RagRetrievalProfile.new(entity_sources: [], question: "¿Qué es K1?")

    assert_not profile.pinned_exact_designator_lookup?(document_pins: 0)
    assert_equal RagRetrievalProfile::OPEN_RESULTS, profile.number_of_results
  end

  test "pinned exact designator lookup accepts one designator on one pin" do
    [
      "¿Qué es K1?",
      "¿Qué es Q1?",
      "¿Qué indica T2?",
      "¿Qué función tiene K7?",
      "¿Qué hay en el borne 12?",
      "¿Qué función tiene el terminal 12?"
    ].each do |question|
      profile = RagRetrievalProfile.new(entity_sources: [ "document" ], question: question)
      assert profile.pinned_exact_designator_lookup?(document_pins: 1), question
    end
  end

  test "pinned exact designator lookup rejects procedures, other intents, and LED questions" do
    rejected = [
      [ "¿Qué es K1?", 0 ],
      [ "¿Qué es K1?", 2 ],
      [ "¿Cómo ajusto K1?", 1 ],
      [ "¿Cómo pruebo K1?", 1 ],
      [ "¿Qué pasos sigo para cambiar K1?", 1 ],
      [ "¿Qué reviso primero?", 1 ],
      [ "Si falla K1, ¿debo detener el trabajo?", 1 ],
      [ "Lista completa de las pruebas de K1", 1 ],
      [ "Compara K1 y K7", 1 ],
      [ "¿Qué indica el LED ABC12?", 1 ],
      [ "¿Qué indica el LED 31?", 1 ],
      [ "¿Qué indica esta señal?", 1 ],
      [ "Problema en borne 12", 1 ],
      [ "Problema borne 12", 1 ],
      [ "Tengo una falla en el borne 12", 1 ],
      [ "Tengo falla en terminal 12", 1 ]
    ]

    rejected.each do |question, pins|
      profile = RagRetrievalProfile.new(entity_sources: [ "document" ], question: question)
      assert_not profile.pinned_exact_designator_lookup?(document_pins: pins), "#{pins} #{question}"
    end
  end

  private

  def route_eligible?(profile, entity_sources:)
    original = ENV.fetch("RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED", nil)
    ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = "true"
    Rag::StructuredEvidenceRoute.send(
      :eligible?,
      profile: profile,
      entity_s3_uris: [ "s3://test-bucket/manual.pdf" ],
      entity_sources: entity_sources,
      output_channel: :web
    )
  ensure
    if original.nil?
      ENV.delete("RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED")
    else
      ENV["RAG_STRUCTURED_EVIDENCE_ROUTE_ENABLED"] = original
    end
  end
end
