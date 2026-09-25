# frozen_string_literal: true

require "test_helper"

class Rag::HaikuOwnershipSliceTest < ActiveSupport::TestCase
  NOW = Time.zone.parse("2026-09-23 14:00:00 -03:00")
  GOAL = "cómo se ajustan los resortes de la fijación de cables"

  test "validated switch drops the stale model and does not compose it" do
    with_mode("conditional") do
      result = turn("¿y en el Nova?", analysis: perception("switch", [ [ "Nova", "equipment" ] ]))

      assert_nil result.state.dig("facts", "model", "value")
      assert_nil result.composed
      assert_equal "¿y en el Nova?", result.state.dig("goal", "text")
    end
  end

  test "equipment switch writes a model only after one catalog match" do
    account = accounts(:legacy)
    document = Struct.new(:display_name).new("Nova")
    with_mode("conditional") do
      with_catalog([ document ]) do
        result = turn(
          "¿y en el Nova?",
          analysis: perception("switch", [ [ "Nova", "equipment" ] ]),
          account: account
        )
        assert_equal "Nova", result.state.dig("facts", "model", "value")
        assert_equal "catalog", result.state.dig("facts", "model", "source")
      end
    end
  end

  test "catalog miss does not persist the model or manufacturer" do
    with_mode("conditional") do
      with_catalog([]) do
        result = turn(
          "¿y en el Nova?",
          analysis: perception("switch", [ [ "Nova", "equipment" ] ]),
          account: accounts(:legacy)
        )
        assert_nil result.state.dig("facts", "model")
        assert_nil result.state.dig("facts", "manufacturer")
      end
    end
  end

  test "correct drops the prior model and keeps the explicit current fact" do
    with_mode("conditional") do
      result = turn(
        "el modelo es MonoSpace",
        analysis: perception("correct"),
        model: "Nova"
      )
      assert_equal "MonoSpace", result.state.dig("facts", "model", "value")
      assert_not_equal "Nova", result.state.dig("facts", "model", "value")
      assert_nil result.composed
    end
  end

  test "an explicit current-turn fact wins over the inherited model" do
    with_mode("conditional") do
      result = turn("el modelo es MonoSpace, como se ajustan los resortes?", analysis: perception("continue"))
      assert_equal "MonoSpace", result.state.dig("facts", "model", "value")
    end
  end

  test "a hostile switch whose span is not in the turn does not change state" do
    with_mode("conditional") do
      result = turn("el freno no suelta", analysis: perception("switch", [ [ "Nova", "equipment" ] ]))
      assert_equal "MonoSpace", result.state.dig("facts", "model", "value")
      assert_not_equal :new_episode, result.decision
    end
  end

  test "ambiguous and unclear fail closed without copying the old model" do
    with_mode("conditional") do
      ambiguous = turn("¿y en el Nova?", analysis: perception("continue", [], ambiguous: true))
      unclear = turn("¿y en el Nova?", analysis: perception("unclear"))
      assert_nil ambiguous.state.dig("facts", "model")
      assert_nil unclear.state.dig("facts", "model")
      assert_nil ambiguous.composed
      assert_nil unclear.composed
    end
  end

  test "analyzer failure on a switch turn does not keep the stale model" do
    with_mode("conditional") do
      result = turn("¿y en el Nova?", analysis: :failed)
      assert_nil result.state.dig("facts", "model")
      assert_nil result.composed
    end
  end

  test "continue stays on v4 and answer_pending stays on the pending parser" do
    with_mode("conditional") do
      continued = turn("el freno no suelta", analysis: perception("continue"))
      assert_equal "MonoSpace", continued.state.dig("facts", "model", "value")
      assert_not_equal :new_episode, continued.decision

      episode = prior(model: "MonoSpace")
      episode.pending_question = { "type" => "fault_code" }
      answered = Rag::ActiveEpisodeTurn.call(
        state: episode.to_h,
        text: "ninguno",
        now: NOW,
        enabled: true,
        correlation_id: "query:pending",
        analysis: perception("answer_pending")
      )
      assert_equal "absent_confirmed", answered.state.dig("facts", "fault_code", "status")
      assert_nil answered.state["pending_question"]
    end
  end

  test "the effective query is the raw turn and the injected analysis makes no model call" do
    with_mode("conditional") do
      result = turn("¿y en el Nova?", analysis: perception("switch", [ [ "Nova", "equipment" ] ]))
      assert_nil result.composed
      assert_equal "¿y en el Nova?", result.state.dig("goal", "text")
    end
  end

  test "shadow mode ignores a switch analysis" do
    with_mode("shadow") do
      result = turn("¿y en el Nova?", analysis: perception("switch", [ [ "Nova", "equipment" ] ]))
      assert_equal "MonoSpace", result.state.dig("facts", "model", "value")
    end
  end

  test "frozen switch fixtures do not keep MonoSpace when the gold relation is applied" do
    rows = Rails.root.join("script/fixtures/haiku_semantic_perception_p0.jsonl").readlines.map { |line| JSON.parse(line) }
    switches = rows.select { |row| row.dig("expected", "relation") == "switch" && row.dig("safety", "equipment_inheritance") == "forbidden" }
    assert switches.any?

    with_mode("conditional") do
      switches.each do |row|
        mentions = row.dig("expected", "mentions").map { |item| [ item["span"], item["role"] ] }
        result = turn(row["turn"], analysis: perception("switch", mentions), model: row.dig("state", "equipment", "model"))
        if row.dig("safety", "equipment_inheritance") == "forbidden" && result.state.dig("facts", "model", "value") == "MonoSpace"
          flunk "P0 safety conflict on #{row["id"]}"
        end
      end
    end
  end

  test "unclear and new are not reported as semantic ownership" do
    with_mode("conditional") do
      unclear = ownership_log { turn("¿y en el otro?", analysis: perception("unclear", ambiguous: true)) }
      fresh = ownership_log { turn("El modelo es MonoSpace", analysis: perception("new")) }

      assert_equal true, unclear["analysis_called"]
      assert_equal true, unclear["analysis_valid"]
      assert_equal "unclear", unclear["relation"]
      assert_equal false, unclear["ownership_eligible"]
      assert_equal false, unclear["ownership_applied"]
      assert_equal "new", fresh["relation"]
      assert_equal false, fresh["ownership_applied"]
    end
  end

  test "a validated switch is reported as ownership applied" do
    with_mode("conditional") do
      payload = ownership_log { turn("¿y en el Nova?", analysis: perception("switch", [ [ "Nova", "equipment" ] ])) }

      assert_equal true, payload["ownership_eligible"]
      assert_equal true, payload["ownership_applied"]
      assert_equal "switch", payload["relation"]
    end
  end

  private

  def perception(relation, mentions = [], ambiguous: false)
    Rag::ConversationalTurnAnalysis.new(
      relation: relation,
      mentions: mentions.map { |span, role| { "span" => span, "role" => role } },
      ambiguous: ambiguous
    )
  end

  def turn(text, analysis:, model: "MonoSpace", account: nil)
    Rag::ActiveEpisodeTurn.call(
      state: prior(model: model).to_h,
      text: text,
      now: NOW,
      enabled: true,
      correlation_id: "query:p3",
      analysis: analysis,
      account: account
    )
  end

  def prior(model:)
    episode = Rag::ActiveEpisode.open(correlation_id: "query:prior", now: NOW)
    episode.assign_goal!(GOAL, correlation_id: "query:prior")
    if model.present?
      episode.write_fact!("model", status: "known", value: model, source: "user", correlation_id: "query:prior", at: NOW.iso8601)
    end
    episode
  end

  def with_catalog(docs)
    singleton = KbDocumentResolver.singleton_class
    singleton.alias_method(:resolve_without_p3, :resolve) unless singleton.method_defined?(:resolve_without_p3)
    singleton.define_method(:resolve) { |*_args, **_kwargs| docs }
    yield
  ensure
    singleton.alias_method(:resolve, :resolve_without_p3)
  end

  def ownership_log
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)
    yield
    line = output.string.lines.reverse.find { |entry| entry.include?("haiku_ownership_slice") }
    JSON.parse(line[line.index("{")..])
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end

  def with_mode(value)
    previous = ENV["HAIKU_QUERY_ANALYSIS_MODE"]
    ENV["HAIKU_QUERY_ANALYSIS_MODE"] = value
    yield
  ensure
    previous.nil? ? ENV.delete("HAIKU_QUERY_ANALYSIS_MODE") : ENV["HAIKU_QUERY_ANALYSIS_MODE"] = previous
  end
end
