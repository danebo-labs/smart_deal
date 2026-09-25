# frozen_string_literal: true

require "test_helper"
require Rails.root.join("script/production_conversational_baseline_v2.rb").to_s

class ProductionConversationalBaselineV2VerdictTest < ActiveSupport::TestCase
  setup do
    @rows = passing_rows
  end

  test "the approved baseline shape passes" do
    assert_empty ProductionConversationalBaselineV2.failures(@rows)
  end

  test "a MiniSpace brake citation fails the stale-context check" do
    row = find("MULTI_TURN_STALE_CONTEXT", 5)
    row["citations"] = [ "KONE MiniSpace PT Instrucciones Instalación — p. 152" ]

    assert_includes ProductionConversationalBaselineV2.failures(@rows).join("\n"), "MULTI_TURN_STALE_CONTEXT#5"
  end

  test "an unknown switch that stores a model fails closed-check" do
    find("CATALOG_MISS", 2)["model_after"] = "ZzzUnknown99"

    assert_includes ProductionConversationalBaselineV2.failures(@rows).join("\n"), "CATALOG_MISS#2"
  end

  test "an http 500 fails" do
    find("NORMAL_RAG", 1)["http"] = 500

    assert_includes ProductionConversationalBaselineV2.failures(@rows).join("\n"), "NORMAL_RAG#1 http=500"
  end

  private

  def find(flow_id, turn)
    @rows.find { |row| row["flow_id"] == flow_id && row["turn"] == turn }
  end

  def passing_rows
    specs = {
      "NORMAL_RAG" => 1,
      "CONTINUE" => 2,
      "SWITCH" => 2,
      "CORRECT" => 2,
      "MODEL_VALUE_FREEZE" => 2,
      "REAFFIRMATION" => 2,
      "AMBIGUOUS_FAIL_CLOSED" => 2,
      "CATALOG_MISS" => 2,
      "SAME_EQUIPMENT_NEW_QUESTION" => 2,
      "BRAND_SWITCH_WITH_EPISODE" => 2,
      "CLOSED_FOLLOWUP_NO_EPISODE" => 2,
      "PENDING_QUESTION" => 1,
      "FAILURE_PATH" => 2,
      "MULTI_TURN_STALE_CONTEXT" => 5
    }
    specs.flat_map do |flow_id, count|
      (1..count).map { |turn| blank(flow_id, turn) }
    end.tap { |rows| stamp(rows) }
  end

  def blank(flow_id, turn)
    {
      "flow_id" => flow_id,
      "turn" => turn,
      "question" => "q",
      "http" => 200,
      "ownership_applied" => false,
      "model_after" => nil,
      "goal_after" => nil,
      "episode_id" => "ep-#{flow_id}",
      "citations" => []
    }
  end

  def stamp(rows)
    find_in(rows, "CONTINUE", 2)["goal_after"] = "Cómo se ajustan los resortes de la fijación de cables?"
    find_in(rows, "SWITCH", 2).merge!("model_after" => "MiniSpace", "ownership_applied" => true)
    find_in(rows, "CORRECT", 2).merge!("model_after" => "MiniSpace", "ownership_applied" => true)
    find_in(rows, "MODEL_VALUE_FREEZE", 2)["model_after"] = "MonoSpace"
    find_in(rows, "REAFFIRMATION", 2)["model_after"] = "MonoSpace"
    find_in(rows, "MULTI_TURN_STALE_CONTEXT", 3)["episode_id"] = "ep-before"
    find_in(rows, "MULTI_TURN_STALE_CONTEXT", 4).merge!("model_after" => "MonoSpace", "episode_id" => "ep-after")
    find_in(rows, "MULTI_TURN_STALE_CONTEXT", 5).merge!(
      "model_after" => "MonoSpace",
      "episode_id" => "ep-after",
      "citations" => [ "KONE MonoSpace 2.5 Installation Guide — p. 85" ]
    )
    rows
  end

  def find_in(rows, flow_id, turn)
    rows.find { |row| row["flow_id"] == flow_id && row["turn"] == turn }
  end
end
