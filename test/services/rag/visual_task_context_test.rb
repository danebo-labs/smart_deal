# frozen_string_literal: true

require "test_helper"

class Rag::VisualTaskContextTest < ActiveSupport::TestCase
  FIXTURE = Rails.root.join("test/fixtures/real_gonzalo/photo_81515_episode.json")
  NOW = Time.zone.parse("2026-09-25T20:38:39-03:00")

  setup do
    @fixture = JSON.parse(File.read(FIXTURE))
  end

  test "an explicit question is the visual task with no lexicon check" do
    context = build_context(
      question: "que voltaje tiene",
      episode_state: episode(goal: "revisa la placa"),
      history: [ user_turn("ajusta los resortes", NOW - 10.minutes) ]
    )

    assert_equal "question", context.visual_task["source"]
    assert_equal "que voltaje tiene", context.visual_task["text"]
    assert_equal "ongoing_episode", context.mode
    assert context.relevance_anchor?
  end

  test "the Gonzalo blank photo inherits the spring sentence and not the meta goal as the task" do
    context = build_context(
      question: "",
      episode_state: @fixture.fetch("active_episode"),
      history: @fixture.fetch("history"),
      now: Time.zone.parse(@fixture.fetch("photo_now"))
    )

    assert_equal "recent_user_target", context.visual_task["source"]
    assert_includes context.visual_task["text"], "resortes"
    assert_includes context.visual_task["text"], "fijación"
    assert_not_includes context.visual_task["text"], "otra imagen"
    assert_includes context.goal, "otra imagen"
    assert_not context.to_h.key?("previous_visual_evidence")
  end

  test "only the three newest messages drops the spring sentence" do
    context = build_context(
      question: nil,
      episode_state: @fixture.fetch("active_episode"),
      history: @fixture.fetch("history").last(3),
      now: Time.zone.parse(@fixture.fetch("photo_now"))
    )

    assert_nil context.visual_task
    assert context.relevance_anchor?
    assert_equal "ongoing_episode", context.mode
  end

  test "a blank or expired episode with a blank question has no anchor" do
    visual = [ user_turn("ajusta los resortes", NOW - 10.minutes) ]

    [ {}, nil ].each do |state|
      context = build_context(question: nil, episode_state: state, history: visual)
      assert_nil context.visual_task
      assert_equal "standalone", context.mode
      assert_not context.relevance_anchor?
    end

    expired = build_context(
      question: "  ",
      episode_state: episode(updated_at: NOW - 5.hours, goal: "ajusta los resortes"),
      history: visual
    )
    assert_nil expired.visual_task
    assert_equal "standalone", expired.mode
    assert_not expired.relevance_anchor?
  end

  test "a visual message before the episode opened is ignored" do
    opened = NOW - 30.minutes
    context = build_context(
      question: nil,
      episode_state: episode(opened_at: opened, goal: "hola"),
      history: [ user_turn("ajusta los resortes", opened - 1.minute) ]
    )

    assert_nil context.visual_task
    assert_equal "hola", context.goal
  end

  test "a newer visual target beats an older one" do
    context = build_context(
      question: nil,
      episode_state: episode,
      history: [
        user_turn("ajusta los resortes", NOW - 20.minutes),
        user_turn("mira la placa", NOW - 5.minutes)
      ]
    )

    assert_equal "recent_user_target", context.visual_task["source"]
    assert_includes context.visual_task["text"], "placa"
    assert_not_includes context.visual_task["text"], "resortes"
  end

  test "a captionless photo uses a visual goal and keeps a non-visual goal as work context" do
    door = build_context(question: nil, episode_state: episode(goal: "la puerta no cierra"), history: [])
    board = build_context(question: nil, episode_state: episode(goal: "revisar el tablero"), history: [])

    assert_equal "goal", door.visual_task["source"]
    assert_includes door.visual_task["text"], "puerta"
    assert_nil board.visual_task
    assert_equal "revisar el tablero", board.goal
    assert board.relevance_anchor?
    assert_equal "ongoing_episode", board.mode
  end

  test "a visual goal is the fallback when history has no visual target" do
    context = build_context(
      question: nil,
      episode_state: episode(goal: "revisa el freno"),
      history: [ user_turn("no se la marca", NOW - 5.minutes) ]
    )

    assert_equal "goal", context.visual_task["source"]
    assert_includes context.visual_task["text"], "freno"
  end

  test "meta photo offers are not a visual task" do
    offers = [
      "si te doy otra imagen , te ayuidaria a orientarme?",
      "puedo enviarte otra foto",
      "te paso otra imagen"
    ]

    offers.each do |offer|
      context = build_context(
        question: nil,
        episode_state: episode(goal: offer),
        history: [ user_turn(offer, NOW - 5.minutes) ]
      )
      assert_nil context.visual_task, offer
      assert_equal offer.squish, context.goal
    end
  end

  test "assistant prose and a previous vision reading are not the target" do
    context = build_context(
      question: nil,
      episode_state: episode(goal: "si te doy otra imagen"),
      history: [
        user_turn("Cómo se ajustan los resortes", NOW - 20.minutes),
        { "role" => "assistant", "content" => "Transformador trifásico", "ts" => (NOW - 15.minutes).iso8601 },
        { "role" => "assistant", "content" => "[FOTO] Componente: Transformador", "ts" => (NOW - 14.minutes).iso8601 },
        user_turn("si te doy otra imagen", NOW - 5.minutes)
      ]
    )

    assert_equal "recent_user_target", context.visual_task["source"]
    assert_includes context.visual_task["text"], "resortes"
    assert_not_includes context.to_h.to_json, "Transformador"
  end

  test "visual task text is squished and cut at 240 characters" do
    question = "resorte #{'a' * 400}"
    context = build_context(question: question, episode_state: nil, history: [])

    assert_equal Rag::VisualTaskContext::MAX_TASK_CHARS, context.visual_task["text"].length
    assert_equal "question", context.visual_task["source"]
    assert_equal "standalone", context.mode
    assert context.relevance_anchor?
  end

  test "a goal without a visual stem is ongoing work and not a visual task" do
    context = build_context(
      question: nil,
      episode_state: episode(goal: "no nivela en planta 3"),
      history: []
    )

    assert_nil context.visual_task
    assert_equal "no nivela en planta 3", context.goal
    assert_equal "ongoing_episode", context.mode
    assert context.relevance_anchor?
    assert_not context.visual_task?
  end

  test "pending is type only and is not a visual task" do
    context = build_context(
      question: nil,
      episode_state: episode(pending: "controller", carry: [ "Q2" ]),
      history: []
    )

    assert_nil context.visual_task
    assert_equal({ "type" => "controller" }, context.to_h["pending"])
    assert_not_includes context.to_h.to_json, "Q2"
    assert context.relevance_anchor?
    assert_equal "ongoing_episode", context.mode
  end

  test "a conversational pending does not count as active work" do
    context = build_context(
      question: nil,
      episode_state: episode(pending_question: { "type" => "work_relation", "carry" => [ "Q2" ] }),
      history: []
    )

    assert_nil context.to_h["pending"]
    assert_equal "standalone", context.mode
    assert_not context.relevance_anchor?
  end

  test "equipment context keeps known facts only and drops rejected values" do
    state = episode
    state["facts"] = {
      "manufacturer" => known_fact("KONE"),
      "model" => {
        "status" => "unknown_confirmed", "source" => "user",
        "correlation_id" => "seed", "at" => NOW.iso8601
      },
      "controller" => known_fact("NICE3000")
    }
    state["rejected"] = [ { "slot" => "manufacturer", "value" => "OTIS-REJECTED" } ]
    state["observations"] = [
      { "text" => "primera", "correlation_id" => "a" },
      { "text" => "segunda", "correlation_id" => "b" },
      { "text" => "tercera #{'z' * 200}", "correlation_id" => "c" }
    ]
    context = build_context(question: nil, episode_state: state, history: [ user_turn("el manual Otis pagina 4", NOW - 1.minute) ])

    assert_equal({ "manufacturer" => "KONE", "controller" => "NICE3000" }, context.to_h["equipment_context"])
    assert_equal [ "segunda", "tercera #{'z' * 200}".squish.first(120) ], context.to_h["observations"]
    assert_not_includes context.to_h.to_json, "OTIS-REJECTED"
    assert_not_includes context.to_h.to_json, "Otis"
    assert_not_includes context.to_h.to_json, "correlation_id"
    assert_equal %w[schema_version mode equipment_context observations], context.to_h.keys
  end

  test "a photo-only episode is standalone" do
    context = build_context(question: nil, episode_state: episode, history: [])

    assert_equal "standalone", context.mode
    assert_equal %w[schema_version mode], context.to_h.keys
    assert_not context.relevance_anchor?
    assert_operator context.bytesize, :<=, Rag::VisualTaskContext::MAX_BYTES
  end

  test "the serialized context stays inside the byte budget and drops in order" do
    payload = {
      "schema_version" => 1,
      "mode" => "ongoing_episode",
      "goal" => "á" * 240,
      "equipment_context" => {
        "manufacturer" => "é" * 60,
        "model" => "é" * 60,
        "controller" => "é" * 60,
        "fault_code" => "é" * 60
      },
      "observations" => [ "í" * 400, "í" * 400 ],
      "pending" => { "type" => "fault_code" },
      "visual_task" => { "text" => "ó" * 240, "source" => "question" }
    }
    assert_operator JSON.generate(payload).bytesize, :>, Rag::VisualTaskContext::MAX_BYTES

    fitted = Rag::VisualTaskContext.send(:fit!, payload.deep_dup)

    assert_operator JSON.generate(fitted).bytesize, :<=, Rag::VisualTaskContext::MAX_BYTES
    assert_equal "á" * 240, fitted["goal"]
    assert_equal "ó" * 240, fitted.dig("visual_task", "text")
    assert_nil fitted["observations"]
    assert_nil fitted.dig("equipment_context", "fault_code")
    assert_equal "é" * 60, fitted.dig("equipment_context", "manufacturer")
  end

  test "building the context does not query or write" do
    assert_no_queries do
      build_context(question: "mira la placa", episode_state: episode(goal: "no nivela en planta 3"), history: [])
    end
  end

  private

  def build_context(question:, episode_state:, history:, now: NOW)
    Rag::VisualTaskContext.build(
      question: question, episode_state: episode_state, history: history, now: now
    )
  end

  def episode(opened_at: NOW - 1.hour, updated_at: NOW - 1.minute, goal: nil, pending: nil, pending_question: nil, carry: nil)
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
    if pending_question
      payload["pending_question"] = pending_question
    elsif pending
      question = { "type" => pending }
      question["carry"] = carry if carry
      payload["pending_question"] = question
      payload["pending_fact"] = { "subject" => pending, "correlation_id" => "seed" }
    end
    payload
  end

  def known_fact(value)
    {
      "status" => "known",
      "value" => value,
      "source" => "user",
      "correlation_id" => "seed",
      "at" => NOW.iso8601
    }
  end

  def user_turn(content, time)
    { "role" => "user", "content" => content, "ts" => time.iso8601 }
  end
end
