# frozen_string_literal: true

require "test_helper"

class Rag::QuoteContractTest < ActiveSupport::TestCase
  CAPTURES = Rails.root.join("test/fixtures/quote_reply/vf5_t2_quote_calls.json")

  test "captured quotes locate to the same offsets the experiment stored" do
    calls = JSON.parse(CAPTURES.read)["calls"]

    assert_equal %w[t2 led mixed ac code], calls.pluck("id")
    calls.each do |row|
      adapted = Rag::TurnPerception.adapt(row["raw"], row["turn"])
      span = located_span(row)

      assert_equal row["adapted_part_replies"], adapted["adapted"]["part_replies"], row["id"]
      assert_equal row["adapted_observations"], adapted["adapted"]["observations"], row["id"]
      assert_equal row["observation_notes"], adapted["observation_notes"], row["id"]
      assert_equal row["resolutions"], adapted["resolutions"], row["id"]
      if span
        assert_equal span[:a], adapted["adapted"]["part_replies"].first["start"]
        assert_equal span[:b], adapted["adapted"]["part_replies"].first["end"]
      else
        assert_empty adapted["adapted"]["part_replies"]
      end
    end
  end

  test "a located symptom quote is copied and the perception stays valid" do
    row = JSON.parse(CAPTURES.read)["calls"].find { |item| item["id"] == "mixed" }
    perception = Rag::TurnPerception.build(
      row["raw"], turn: row["turn"], episode: Rag::ActiveEpisode.new,
      catalog: nil, viewer_account: nil
    )

    assert perception.valid
    assert_equal [ "Fue solo la primera apertura", "El LED STATUS está apagado" ], perception.observations
    assert_equal "El LED STATUS está apagado", perception.part_replies.first["quote"]
    assert_equal "partial", perception.part_replies.first["state"]
    assert perception.adjustments.any? { |note| note["rule"] == "quote_observation" && note["reason"] == "added" }
  end

  test "an ambiguous quote and a missing quote are refused without a stored reply" do
    repeated = apply_quote("abre despacio", "abre despacio y abre despacio")
    missing = apply_quote("el encoder", "La puerta abre.")
    absent = apply_quote(nil, "La puerta abre.")

    assert_equal "quote_ambiguous", repeated["refused"].first["reason"]
    assert_equal "quote_not_literal", missing["refused"].first["reason"]
    assert_equal "invalid_span", absent["refused"].first["reason"]
    assert_empty repeated["stored"]
    assert_empty missing["stored"]
    assert_empty absent["stored"]
  end

  test "stored offset replies from session 198 and the gui turn still read the same slice" do
    require_historical_capture("tmp/field_companion/validation_captures/vf5-corrected-20261103T201414Z/d84e8a77-e272-44f1-ae84-1c9646468f06/capture.json")
    capture = JSON.parse(Rails.root.join(
      "tmp/field_companion/validation_captures/vf5-corrected-20261103T201414Z/" \
      "d84e8a77-e272-44f1-ae84-1c9646468f06/capture.json"
    ).read)
    delta = capture["events"].find { |event| event["kind"] == "episode_delta" }
    stored = delta["episode_after"]
    message = capture["events"].find { |event| event["kind"] == "user_message" }
    session = history_session(message["correlation_id"], message["original"])
    at = Time.zone.parse(stored["updated_at"]) + 1.second
    travel_to(at) do
      episode = Rag::ActiveEpisode.parse(stored)
      reply = episode.replies.find { |row| row["id"] == "r1" }
      lines = Rag::AnswerContract.context_lines(episode, session)

      assert_equal 198, delta["session_id"]
      assert_not reply.key?("a")
      assert_not reply.key?("b")
      assert_equal message["original"], Rag::AnswerContract.reconstruct(reply, session)
      assert_includes lines.join("\n"), message["original"]
      assert_includes Rag::AnswerContract.open_parts(episode).pluck("id"), "p1"
      assert_equal [ "r1" ], Rag::AnswerContract.current_replies(episode, "p1").pluck("id")
    end

    user = JSON.parse(Rails.root.join("test/fixtures/vf5_gui_replay/t5.json").read)["user"]
    clause = "si hay un contacto cerrado entre #21 y #23"
    start = user.index(clause)
    gui = history_session("query:gui-t5", user)
    episode = Rag::ActiveEpisode.open(correlation_id: "query:gui-t5", now: Time.current)
    episode.pending_question = {
      "type" => "documented_context", "id" => "q1", "question" => "¿Qué información necesitas?",
      "parts" => [ { "id" => "p1", "role" => "main", "text" => "¿Qué información necesitas?" } ]
    }
    episode.replies = [ {
      "id" => "r1", "q" => "q1", "p" => "p1", "state" => "partial",
      "cid" => "query:gui-t5", "a" => start, "b" => start + clause.length
    } ]
    direct = user[start...(start + clause.length)]

    assert_equal clause, direct
    assert_equal direct, Rag::AnswerContract.reconstruct(episode.replies.first, gui)
    assert_includes Rag::AnswerContract.context_lines(episode, gui).join("\n"), direct
    assert_equal [ "r1" ], Rag::AnswerContract.current_replies(episode, "p1").pluck("id")
  end

  private

  def located_span(row)
    reply = Array(row.dig("raw", "part_replies")).first
    return nil unless reply.is_a?(Hash) && reply["quote"].present?

    Rag::AnswerContract.send(:span_for, row["turn"], reply)
  end

  def apply_quote(quote, turn)
    episode = Rag::ActiveEpisode.open(correlation_id: "query:quote", now: Time.current)
    episode.pending_question = {
      "type" => "documented_context", "id" => "q1", "question" => "¿Sigue?",
      "parts" => [ { "id" => "p1", "role" => "main", "text" => "¿Sigue?" } ]
    }
    proposal = { "question_id" => "q1", "part_id" => "p1", "state" => "partial" }
    proposal["quote"] = quote unless quote.nil?
    Rag::AnswerContract.apply!(
      episode, turn: turn, correlation_id: "query:quote",
      proposals: [ proposal ], contract: true, field: "present"
    )
  end

  def history_session(correlation_id, text)
    Struct.new(:conversation_history).new([
      { "role" => "user", "content" => text, "correlation_id" => correlation_id }
    ])
  end
end
