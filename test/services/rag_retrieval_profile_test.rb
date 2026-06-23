# frozen_string_literal: true

require "test_helper"

class RagRetrievalProfileTest < ActiveSupport::TestCase
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
end
