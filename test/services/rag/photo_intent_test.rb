# frozen_string_literal: true

require "test_helper"

class Rag::PhotoIntentTest < ActiveSupport::TestCase
  FIXTURE = Rails.root.join("test/fixtures/real_gonzalo/photo_81515_episode.json")
  NOW = Time.zone.parse("2026-09-25T20:38:39-03:00")

  setup do
    @fixture = JSON.parse(File.read(FIXTURE))
  end

  test "an explicit question is the intent with no lexicon check" do
    intent = Rag::PhotoIntent.resolve(
      question: "que voltaje tiene",
      episode_state: episode(goal: "revisa la placa"),
      history: [ user_turn("ajusta los resortes", NOW - 10.minutes) ],
      now: NOW
    )

    assert_equal "question", intent["source"]
    assert_equal "que voltaje tiene", intent["text"]
  end

  test "the Gonzalo blank photo inherits the spring sentence and not the meta goal" do
    intent = Rag::PhotoIntent.resolve(
      question: "",
      episode_state: @fixture.fetch("active_episode"),
      history: @fixture.fetch("history"),
      now: Time.zone.parse(@fixture.fetch("photo_now"))
    )

    assert_equal "history", intent["source"]
    assert_includes intent["text"], "resortes"
    assert_includes intent["text"], "fijación"
    assert_not_includes intent["text"], "otra imagen"
  end

  test "only the three newest messages drops the spring sentence" do
    intent = Rag::PhotoIntent.resolve(
      question: nil,
      episode_state: @fixture.fetch("active_episode"),
      history: @fixture.fetch("history").last(3),
      now: Time.zone.parse(@fixture.fetch("photo_now"))
    )

    assert_nil intent
  end

  test "a blank or expired episode with a blank question resolves to nil" do
    visual = [ user_turn("ajusta los resortes", NOW - 10.minutes) ]

    assert_nil Rag::PhotoIntent.resolve(question: nil, episode_state: {}, history: visual, now: NOW)
    assert_nil Rag::PhotoIntent.resolve(question: "  ", episode_state: nil, history: visual, now: NOW)
    assert_nil Rag::PhotoIntent.resolve(
      question: nil,
      episode_state: episode(updated_at: NOW - 5.hours, goal: "ajusta los resortes"),
      history: visual,
      now: NOW
    )
  end

  test "a visual message before the episode opened is ignored" do
    opened = NOW - 30.minutes
    intent = Rag::PhotoIntent.resolve(
      question: nil,
      episode_state: episode(opened_at: opened, goal: "hola"),
      history: [ user_turn("ajusta los resortes", opened - 1.minute) ],
      now: NOW
    )

    assert_nil intent
  end

  test "a newer visual target beats an older one" do
    intent = Rag::PhotoIntent.resolve(
      question: nil,
      episode_state: episode,
      history: [
        user_turn("ajusta los resortes", NOW - 20.minutes),
        user_turn("mira la placa", NOW - 5.minutes)
      ],
      now: NOW
    )

    assert_equal "history", intent["source"]
    assert_includes intent["text"], "placa"
    assert_not_includes intent["text"], "resortes"
  end

  test "a captionless photo uses a visual goal and ignores a goal with no visual target" do
    door = Rag::PhotoIntent.resolve(
      question: nil, episode_state: episode(goal: "la puerta no cierra"), history: [], now: NOW
    )
    board = Rag::PhotoIntent.resolve(
      question: nil, episode_state: episode(goal: "revisar el tablero"), history: [], now: NOW
    )

    assert_equal "goal", door["source"]
    assert_includes door["text"], "puerta"
    assert_nil board
  end

  test "a visual goal is the fallback when history has no visual target" do
    intent = Rag::PhotoIntent.resolve(
      question: nil,
      episode_state: episode(goal: "revisa el freno"),
      history: [ user_turn("no se la marca", NOW - 5.minutes) ],
      now: NOW
    )

    assert_equal "goal", intent["source"]
    assert_includes intent["text"], "freno"
  end

  test "meta photo offers are not a technical target" do
    offers = [
      "si te doy otra imagen , te ayuidaria a orientarme?",
      "puedo enviarte otra foto",
      "te paso otra imagen"
    ]

    offers.each do |offer|
      intent = Rag::PhotoIntent.resolve(
        question: nil,
        episode_state: episode(goal: offer),
        history: [ user_turn(offer, NOW - 5.minutes) ],
        now: NOW
      )
      assert_nil intent, offer
    end
  end

  test "assistant prose and a previous vision reading are not the target" do
    intent = Rag::PhotoIntent.resolve(
      question: nil,
      episode_state: episode(goal: "si te doy otra imagen"),
      history: [
        user_turn("Cómo se ajustan los resortes", NOW - 20.minutes),
        { "role" => "assistant", "content" => "Transformador trifásico", "ts" => (NOW - 15.minutes).iso8601 },
        { "role" => "assistant", "content" => "[FOTO] Componente: Transformador", "ts" => (NOW - 14.minutes).iso8601 },
        user_turn("si te doy otra imagen", NOW - 5.minutes)
      ],
      now: NOW
    )

    assert_equal "history", intent["source"]
    assert_includes intent["text"], "resortes"
    assert_not_includes intent["text"], "Transformador"
  end

  test "intent text is squished and cut at the goal limit" do
    question = "resorte #{'a' * 400}"
    intent = Rag::PhotoIntent.resolve(question: question, episode_state: nil, history: [], now: NOW)

    assert_equal Rag::ActiveEpisode::MAX_GOAL_CHARS, intent["text"].length
    assert_equal "question", intent["source"]
  end

  private

  def episode(opened_at: NOW - 1.hour, updated_at: NOW - 1.minute, goal: nil)
    payload = {
      "v" => 1,
      "episode_id" => "ep_test",
      "status" => "active",
      "opened_at" => opened_at.iso8601,
      "updated_at" => updated_at.iso8601
    }
    if goal
      payload["goal"] = { "text" => goal, "correlation_id" => "query:goal", "truncated" => false }
    end
    payload
  end

  def user_turn(content, time)
    { "role" => "user", "content" => content, "ts" => time.iso8601 }
  end
end
