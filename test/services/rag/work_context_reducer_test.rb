# frozen_string_literal: true

require "test_helper"

class Rag::WorkContextReducerTest < ActiveSupport::TestCase
  setup do
    @now = Time.zone.parse("2026-10-06 15:00:00 UTC")
  end

  test "a fault-code correction stores 18 and keeps 8 rejected" do
    episode = open_episode
    episode.write_fact!(
      "fault_code", status: "known", value: "8", source: "user",
      correlation_id: "seed", at: @now.iso8601
    )
    episode.append_observation!("El display muestra código 8", correlation_id: "seed")
    episode.append_observation!("detenida cerca de planta 1", correlation_id: "seed")
    turn = "No, leí mal: era código 18, no 8."

    with_owner { settle(episode, correction_payload, turn) }

    fact = episode.fact("fault_code")
    assert_equal "known", fact["status"]
    assert_equal "18", fact["value"]
    assert_equal "user", fact["source"]
    assert_includes episode.rejected.pluck("value"), "8"
    assert_not_includes episode.rejected.pluck("value"), "18"
    assert episode.observations.any? { |row| row["text"].include?("planta 1") }
    assert episode.observations.none? { |row| row["text"].match?(/(?<![[:alnum:]])8(?![[:alnum:]])/) }
  end

  test "a no-code report stores fault_code absent_confirmed" do
    episode = open_episode
    turn = "Solo lo he visto en planta 3; en otras plantas no lo observé. No aparece código de falla."

    with_owner do
      settle(episode, report_payload([ "Solo lo he visto en planta 3", "No aparece código de falla" ]), turn)
    end

    fact = episode.fact("fault_code")
    assert_equal "absent_confirmed", fact["status"]
    assert_nil fact["value"]
    assert episode.observations.any? { |row| row["text"] == "No aparece código de falla" }
  end

  test "an unmatched negate does not become an absent fault code" do
    episode = open_episode
    episode.assign_goal!("queda pasado de nivel", correlation_id: "seed")
    turn = "No veo ningún código de falla"

    with_owner { settle(episode, report_payload([], [ { "span" => turn, "act" => "negate" } ]), turn) }

    assert_nil episode.fact("fault_code")
  end

  test "a retracted floor drops that observation and keeps the replacement" do
    episode = open_episode
    episode.append_observation!("detenida cerca de planta 1", correlation_id: "seed")
    episode.append_observation!("no hay personas dentro", correlation_id: "seed")
    turn = "Corrijo algo de antes: la cabina está detenida cerca de planta 2, no de planta 1."

    with_owner { settle(episode, report_payload([ "detenida cerca de planta 2" ]), turn) }

    texts = episode.observations.pluck("text")
    assert_includes texts, "detenida cerca de planta 2"
    assert_includes texts, "no hay personas dentro"
    assert texts.none? { |text| text.match?(/(?<![[:alnum:]])planta 1(?![[:alnum:]])/i) }
  end

  test "a level correction replaces por arriba and keeps the no-code observation" do
    episode = open_episode
    episode.append_observation!("No aparece código de falla", correlation_id: "seed")
    episode.append_observation!("2 o 3 cm por arriba del nivel", correlation_id: "seed")
    turn = "Corrijo lo de arriba: queda unos 2 o 3 cm por debajo del nivel."

    with_owner { settle(episode, report_payload([ "2 o 3 cm por debajo del nivel" ]), turn) }

    texts = episode.observations.pluck("text")
    assert_includes texts, "2 o 3 cm por debajo del nivel"
    assert_includes texts, "No aparece código de falla"
    assert texts.none? { |text| text.include?("por arriba") }
  end

  private

  def settle(episode, raw, turn)
    perception = Rag::TurnPerception.build(
      raw, turn: turn, episode: episode, catalog: nil, viewer_account: nil
    )
    decision = Rag::RoutePolicy.call(previous: episode, perception: perception, focus_count: 0, locale: :es)
    Rag::WorkContextReducer.apply!(
      episode: episode, perception: perception, decision: decision,
      turn: turn, correlation_id: "seed", now: @now
    )
  end

  def open_episode
    Rag::ActiveEpisode.open(correlation_id: "seed", now: @now)
  end

  def correction_payload
    {
      "move" => "correct",
      "assertions" => [
        { "span" => "8", "act" => "negate" },
        { "span" => "18", "act" => "assert", "slot_hint" => "fault_code" }
      ],
      "observations" => [],
      "pending_resolution" => nil,
      "clarification_target" => nil
    }
  end

  def report_payload(observations, assertions = [])
    {
      "move" => "report",
      "assertions" => assertions,
      "observations" => observations,
      "pending_resolution" => nil,
      "clarification_target" => nil
    }
  end

  def with_owner(&block)
    isolate_env("FIELD_COMPANION_EPISODE_ENABLED", "true") do
      isolate_env("FIELD_COMPANION_TURN_ENABLED", "true") do
        isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "owner", &block)
      end
    end
  end
end
