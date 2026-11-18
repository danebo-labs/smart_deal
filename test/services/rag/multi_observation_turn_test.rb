# frozen_string_literal: true

require "test_helper"

# A turn that reports an intervention, its outcome, a trait of the equipment
# and a reading carries several facts. The interpreter returned four of them
# in the sixth Thyssen run and the whole structure was rejected for the cap.
class Rag::MultiObservationTurnTest < ActiveSupport::TestCase
  THYSSEN_TURN = "Ya lo alinearon. Ahora la puerta cierra y traba bien, pero sigue marcando EA. " \
    "Tiene motor de operador. Con la puerta cerrada y trabada, medí 0 Vcc en RA\u201153/P28. " \
    "¿Qué me dice esa lectura?"
  THYSSEN_FACTS = [
    "la puerta cierra y traba bien",
    "sigue marcando EA",
    "Tiene motor de operador",
    "medí 0 Vcc en RA\u201153/P28"
  ].freeze

  setup do
    @now = Time.zone.parse("2026-11-18 14:00:00 UTC")
  end

  test "four literal facts of one turn are kept and the extra inert key is only noted" do
    raw = thyssen_payload.merge("observations_note" => "unused")

    perception = perceive(raw, THYSSEN_TURN)

    assert perception.valid, perception.invalid_reason.inspect
    assert_equal THYSSEN_FACTS, perception.observations
    assert_empty perception.field_rejections
    assert_includes perception.adjustments.pluck("datum"), "observations_note"
  end

  test "an equivalent turn on another equipment keeps every fact and its reading" do
    turn = "Ya cambiaron el contactor. Ahora la cabina arranca, pero sigue el error 5. " \
      "Tiene variador de frecuencia. Medí 380 Vca entre U1 y V1. ¿Eso es normal?"
    facts = [ "la cabina arranca", "sigue el error 5", "Tiene variador de frecuencia", "Medí 380 Vca entre U1 y V1" ]
    raw = payload(observations: facts)

    perception = perceive(raw, turn)

    assert perception.valid, perception.invalid_reason.inspect
    assert_equal facts, perception.observations
  end

  test "the facts keep the provenance of the technician turn that stated them" do
    episode = open_episode
    perception = perceive(thyssen_payload, THYSSEN_TURN, episode)
    decision = Rag::RoutePolicy.call(previous: episode, perception: perception, focus_count: 0, locale: :es)

    with_owner do
      Rag::WorkContextReducer.apply!(
        episode: episode, perception: perception, decision: decision,
        turn: THYSSEN_TURN, correlation_id: "query:t4", now: @now
      )
    end

    stored = episode.observations.select { |row| row["correlation_id"] == "query:t4" }.pluck("text")
    assert_equal THYSSEN_FACTS, stored
  end

  test "facts beyond the per-turn cap are traced and do not invalidate the rest" do
    facts = (1..8).map { |index| "el sensor #{index} marca una lectura distinta" }
    turn = "#{facts.join('. ')}."

    perception = perceive(payload(observations: facts), turn)

    assert perception.valid, perception.invalid_reason.inspect
    assert_equal facts.first(Rag::TurnPerception::MAX_TURN_OBSERVATIONS), perception.observations
    over = perception.field_rejections.select { |row| row["reason"] == "over_cap" }
    assert_equal 2, over.size
    assert_equal %w[observations[6] observations[7]], over.pluck("field")
  end

  test "the schema and the prompt state the same per-turn cap" do
    cap = Rag::TurnPerception::MAX_TURN_OBSERVATIONS

    assert_equal cap, Rag::TurnPerception.tool_schema.dig(:properties, :observations, :maxItems)
    assert_includes Rag::TurnInterpreter::PROMPT, "observations holds up to #{cap} facts"
  end

  test "the strict experiment contract still refuses more than the cap" do
    facts = (1..7).map { |index| "el sensor #{index} marca una lectura distinta" }
    result = Rag::InterpreterPayloadContract.evaluate(payload(observations: facts), sent_turn: facts.join(". "))

    assert_equal false, result["valid"]
    assert_equal "too_many_observations", result["reason"]
  end

  private

  def thyssen_payload
    payload(
      move: "answer_pending",
      assertions: [
        { "span" => "Ya lo alinearon", "act" => "assert", "slot_hint" => nil },
        { "span" => "sigue marcando EA", "act" => "assert", "slot_hint" => nil }
      ],
      observations: THYSSEN_FACTS,
      checks: [
        { "subject" => "Ya lo alinearon", "status" => "done", "result" => "Ya lo alinearon" },
        { "subject" => "medí 0 Vcc en RA\u201153/P28", "status" => "done", "result" => "0 Vcc en RA\u201153/P28" }
      ]
    )
  end

  def payload(move: "report", assertions: [], observations: [], checks: nil)
    raw = {
      "move" => move,
      "assertions" => assertions,
      "observations" => observations,
      "pending_resolution" => nil,
      "clarification_target" => nil
    }
    raw["checks"] = checks unless checks.nil?
    raw
  end

  def open_episode
    Rag::ActiveEpisode.open(correlation_id: "seed", now: @now)
  end

  def perceive(raw, turn, episode = open_episode)
    Rag::TurnPerception.build(raw, turn: turn, episode: episode, catalog: nil, viewer_account: nil)
  end

  def with_owner(&block)
    isolate_env("FIELD_COMPANION_EPISODE_ENABLED", "true") do
      isolate_env("FIELD_COMPANION_TURN_ENABLED", "true") do
        isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "owner", &block)
      end
    end
  end
end
