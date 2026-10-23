# frozen_string_literal: true

require "test_helper"

class Rag::CheckResultContractTest < ActiveSupport::TestCase
  RESULT_SENTENCE = "result is the outcome the technician states for that verification, " \
    "copied literally from the turn, or null; that outcome stays the result even when it also reads as an observation."
  PREVIOUS_SENTENCE = "result is a literal substring of the turn, or null."
  PROMPT_SHA256 = "78124b2d34fb48e47af0f62502153ed0cb2ba7eea5b40fd70cf7681102016dde"

  setup do
    @now = Time.zone.parse("2026-10-21 18:00:00 UTC")
  end

  test "the schema sent to the interpreter requires result and still allows null" do
    schema = Rag::TurnPerception.tool_schema
    check = schema.dig(:properties, :checks, :items)

    assert_equal %w[subject status result], check[:required]
    assert_equal %w[string null], check.dig(:properties, :result, :type)
    assert_equal RESULT_SENTENCE, prompt_result_sentence
    assert_not_includes Rag::TurnInterpreter::PROMPT, PREVIOUS_SENTENCE
    assert_equal PROMPT_SHA256, Digest::SHA256.hexdigest(Rag::TurnInterpreter::PROMPT)
  end

  test "a previous payload without the result key stays parseable and that is not schema validation" do
    turn = "no he mirado la fotocélula"
    raw = payload(checks: [ { "subject" => "la fotocélula", "status" => "not_done" } ])

    assert_nil Rag::TurnPerception.structural_failure(raw)
    assert_equal true, Rag::InterpreterPayloadContract.evaluate(raw, sent_turn: turn)["valid"]

    perception = perceive(raw, turn)
    episode, = settle(raw, turn)

    assert perception.valid
    assert_nil perception.checks.sole["result"]
    assert_nil episode.checks.sole["result"]
    assert_equal false, episode.checks.sole.key?("result")
  end

  test "a literal result is stored and a literal that is not the outcome is stored too" do
    turn = "Ya revisé la fotocélula y no está activada."
    kept = settle(payload(checks: [ check("fotocélula", "done", "no está activada") ]), turn).first

    assert_equal "done", kept.checks.sole["status"]
    assert_equal "no está activada", kept.checks.sole["result"]
    assert_equal "fotocélula", kept.checks.sole["subject"]

    other = settle(payload(checks: [ check("fotocélula", "done", "fotocélula") ]), turn).first

    assert_equal "fotocélula", other.checks.sole["result"]
  end

  private

  def prompt_result_sentence
    match = Rag::TurnInterpreter::PROMPT.match(/result is the outcome.*observation\./)
    match.to_s
  end

  def open_episode
    Rag::ActiveEpisode.open(correlation_id: "seed", now: @now)
  end

  def check(subject, status, result)
    { "subject" => subject, "status" => status, "result" => result }
  end

  def payload(move: "report", observations: [], checks: nil)
    raw = {
      "move" => move,
      "assertions" => [],
      "observations" => observations,
      "pending_resolution" => nil,
      "clarification_target" => nil
    }
    raw["checks"] = checks unless checks.nil?
    raw
  end

  def perceive(raw, turn, episode = open_episode)
    Rag::TurnPerception.build(raw, turn: turn, episode: episode, catalog: nil, viewer_account: nil)
  end

  def settle(raw, turn)
    episode = open_episode
    perception = perceive(raw, turn, episode)
    decision = Rag::RoutePolicy.call(previous: episode, perception: perception, focus_count: 0, locale: :es)
    with_owner do
      Rag::WorkContextReducer.apply!(
        episode: episode, perception: perception, decision: decision,
        turn: turn, correlation_id: "turn", now: @now
      )
    end
    [ episode, perception ]
  end

  def with_owner(&block)
    isolate_env("FIELD_COMPANION_EPISODE_ENABLED", "true") do
      isolate_env("FIELD_COMPANION_TURN_ENABLED", "true") do
        isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "owner", &block)
      end
    end
  end
end
