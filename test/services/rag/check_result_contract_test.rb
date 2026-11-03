# frozen_string_literal: true

require "test_helper"

class Rag::CheckResultContractTest < ActiveSupport::TestCase
  RESULT_SENTENCE = "result is the outcome the technician states for that verification, " \
    "copied literally from the turn, or null; that outcome stays the result even when it also reads as an observation."
  PREVIOUS_SENTENCE = "result is a literal substring of the turn, or null."
  DOCUMENTED_CONTEXT_PARAGRAPH = "When pending.clarification_target is documented_context, the turn may answer a published part, " \
    "state other facts of the case, or both. A slice answers a part only when it states what that part asks: the value, " \
    "the yes or no, which published option matches, or that none matches. A fact of the same case that states something else " \
    "does not answer that part, even when it makes one option more or less likely. That fact is an observation and has no part_reply. " \
    "complete = the slice states everything the part asks. partial = the part asks for more than one thing and the slice states only some of them. " \
    "unknown = the technician says they do not know or cannot see what the part asks. contradictory = the turn gives answers to that part " \
    "that cannot both be true. A fact next to an answer does not change that answer's state. A turn that answers no part has no part_replies. " \
    "An answer that states what the technician sees is also an observation. A partial answer does not fill the missing part. " \
    "Example: the part asks \"¿El manómetro marca más o menos de 2 bar, y la aguja oscila?\". \"Marca 1,5.\" is partial. " \
    "\"Marca 1,5 y no oscila.\" is complete. \"Desde ayer la bomba arranca cada diez minutos.\" answers no part: it is an observation with no part_reply."
  OBSERVATIONS_PARAGRAPH = "Every span is the shortest literal substring of turn, not the sentence. observations holds up to three facts " \
    "of the case stated in this turn, one contiguous literal phrase each, or is empty. The reported fault and what the technician sees " \
    "or does not see are observations, not identifiers and not checks. So are when it happens, how often, under which condition, and how it changed, " \
    "also when the phrase refers to a fault already in work_context without repeating it. Keep every word between its ends. Do not drop words. " \
    "Do not paraphrase. Do not invent an observation. Do not describe the photo. A correction of manufacturer, model, controller, or fault code " \
    "still negates the stored value and asserts the replacement. Keep every other symptom in that same turn as an observation. " \
    "A correction of an observation keeps the replacement phrase as the observation and does not need a slot negate or an assert span."
  PREVIOUS_DOCUMENTED_CONTEXT_PARAGRAPH = "When pending.clarification_target is documented_context, the turn may answer that question. " \
    "Record the technician's words as an observation. A partial answer stays an observation and does not fill the missing part."
  FAILED_DOCUMENTED_CONTEXT_PARAGRAPH = "When pending.clarification_target is documented_context, the turn may answer that question, " \
    "add other facts of the case, or both. Record each fact the technician states as its own observation, whether or not it answers."
  PREVIOUS_OBSERVATION_SENTENCE = "An observation is one contiguous symptom phrase copied from the turn, or empty."
  PROMPT_SHA256 = "a5de394a7d87687763b0cd4bd03313ed687a29637698e45e34e05b3aed015b3e"

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
    assert_includes Rag::TurnInterpreter::PROMPT, DOCUMENTED_CONTEXT_PARAGRAPH
    assert_includes Rag::TurnInterpreter::PROMPT, OBSERVATIONS_PARAGRAPH
    assert_not_includes Rag::TurnInterpreter::PROMPT, PREVIOUS_DOCUMENTED_CONTEXT_PARAGRAPH
    assert_not_includes Rag::TurnInterpreter::PROMPT, FAILED_DOCUMENTED_CONTEXT_PARAGRAPH
    assert_not_includes Rag::TurnInterpreter::PROMPT, PREVIOUS_OBSERVATION_SENTENCE
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
