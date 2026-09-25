# frozen_string_literal: true

require "test_helper"

class ProductionConversationalBaselineV2Test < ActiveSupport::TestCase
  FIXTURE = Rails.root.join("script/fixtures/production_conversational_baseline_v2.json")

  setup do
    @corpus = JSON.parse(FIXTURE.read)
  end

  test "the frozen production baseline keeps 14 flows and 29 turns" do
    flows = @corpus.fetch("flows")
    turns = flows.flat_map { |flow| flow.fetch("turns") }.grep(String)

    assert_equal "PRODUCTION_CONVERSATIONAL_BASELINE_V2", @corpus.fetch("id")
    assert_equal 14, flows.length
    assert_equal 29, turns.length
    assert_equal "¿Cómo se ajusta el freno en el KONE MiniSpace?", flows[0].fetch("turns").first
    assert_equal "¿qué reviso primero?", flow("CONTINUE").fetch("turns")[1]
    assert_equal "cambia al MiniSpace", flow("SWITCH").fetch("turns")[1]
    assert_equal "No, no es MonoSpace. Es MiniSpace.", flow("CORRECT").fetch("turns")[1]
    assert_equal "el modelo es MonoSpace, como se ajustan los resortes de la fijación de cables?", flow("REAFFIRMATION").fetch("turns")[1]
    assert_equal "cambia al ZzzUnknown99", flow("CATALOG_MISS").fetch("turns")[1]
    assert_equal "Ahora es un OTIS NE-300. ¿Qué muestra el esquema 3907-ST?", flow("BRAND_SWITCH_WITH_EPISODE").fetch("turns")[1]
    assert_equal "MonoSpace", flow("CLOSED_FOLLOWUP_NO_EPISODE").fetch("turns").last
    assert_equal true, flow("CLOSED_FOLLOWUP_NO_EPISODE").fetch("turns")[1]["clear_episode"]
    assert_equal "¿Qué LED se enciende cuando falla el cerrojo?", flow("PENDING_QUESTION").fetch("turns").first
    assert_equal "cambia al MonoSpace", flow("MULTI_TURN_STALE_CONTEXT").fetch("turns")[3]
  end

  private

  def flow(id)
    @corpus.fetch("flows").find { |row| row.fetch("id") == id }
  end
end
