# frozen_string_literal: true

require "test_helper"

class Rag::FieldJourneyTest < ActiveSupport::TestCase
  EXCELSIOR = "Hola, tengo una falla en un equipo Excélsior de 10 niveles, el equipo se pasa en alta velocidad en el piso inferior, es de 1.5 m/s"
  DESCENT = "Se pasa en bajada en alta velocidad"

  setup do
    @episode_flag = ENV["FIELD_COMPANION_EPISODE_ENABLED"]
    ENV["FIELD_COMPANION_EPISODE_ENABLED"] = "true"
  end

  teardown do
    if @episode_flag.nil?
      ENV.delete("FIELD_COMPANION_EPISODE_ENABLED")
    else
      ENV["FIELD_COMPANION_EPISODE_ENABLED"] = @episode_flag
    end
  end

  test "the excelsior descent journey keeps the symptom and drops meta talk" do
    opened = turn(EXCELSIOR)
    assert_equal "technical_report", opened.understanding.dialogue_function
    assert opened.state["observations"].any? { |row| row["text"].downcase.include?("alta velocidad") }

    descent = turn(DESCENT, prior: opened.state)
    assert_equal "technical_report", descent.understanding.dialogue_function
    assert_includes descent.understanding.retrieval_query.downcase, "bajada"
    assert_includes descent.understanding.retrieval_query.downcase, "excélsior"
    assert_includes descent.understanding.retrieval_query, "1.5"
    assert_equal true, descent.understanding.owns_query

    meta = turn("¿Necesitas controlador?", prior: descent.state)
    assert_equal "meta_question", meta.understanding.dialogue_function
    assert_not_includes meta.understanding.retrieval_query.downcase, "necesitas"
    assert_not_includes meta.understanding.retrieval_query.downcase, "controlador"
    assert_includes meta.understanding.retrieval_query.downcase, "bajada"
    assert Array(meta.state["observations"]).none? { |row| row["text"].downcase.include?("necesitas") }

    unknown = turn("Volviendo a la pregunta del controlador, no lo sé", prior: meta.state)
    assert_equal "answer_pending", unknown.understanding.dialogue_function
    assert_equal "best_effort", unknown.understanding.decision
    assert_equal "unknown_confirmed", unknown.state.dig("facts", "controller", "status")
    assert_not_includes unknown.understanding.retrieval_query.downcase, "controlador"
    assert_includes unknown.understanding.retrieval_query.downcase, "bajada"
  end

  test "que reviso keeps Nice300 and E51 and a meta line does not" do
    decision = Rag::TechnicalUnderstanding.call(
      text: "¿Qué reviso?",
      episode: opened_episode("Nice300 e51"),
      prior_turns: [
        { "content" => "Nice300 e51" },
        { "content" => "¿Necesitas controlador?" }
      ]
    )

    assert_equal "follow_up", decision.dialogue_function
    assert_equal true, decision.owns_query
    assert_includes decision.retrieval_query.downcase, "nice300"
    assert_includes decision.retrieval_query.downcase, "e51"
    assert_not_includes decision.retrieval_query.downcase, "necesitas"
  end

  test "no lo se after a controller question continues the same job" do
    episode = opened_episode("Nice300 e51")
    episode.pending_fact = { "subject" => "controller", "correlation_id" => "c" }
    decision = Rag::TechnicalUnderstanding.call(text: "No lo sé", episode: episode)

    assert_equal "best_effort", decision.decision
    assert_equal "answer_pending", decision.dialogue_function
    assert_nil decision.pending_subject
    assert_includes decision.retrieval_query.downcase, "nice300"
    assert_includes decision.retrieval_query.downcase, "e51"
    assert_not_includes decision.retrieval_query.downcase, "controlador"
  end

  test "q2 without context stays clarify first" do
    decision = Rag::TechnicalUnderstanding.call(text: "¿Qué es Q2?", episode: Rag::ActiveEpisode.new, focus_count: 0)

    assert_equal "clarify_first", decision.decision
    assert_equal false, decision.outside_discovery
  end

  test "a full VF5+ question stays on its own sentence" do
    episode = opened_episode("las puertas no cierran")
    decision = Rag::TechnicalUnderstanding.call(
      text: "¿Cómo uso el módulo electrónico VF5+?",
      episode: episode,
      prior_turns: [ { "content" => "¿Necesitas controlador?" } ]
    )

    assert_equal false, decision.owns_query
    assert_not_includes decision.retrieval_query.downcase, "necesitas"
    assert_includes decision.retrieval_query, "VF5"
  end

  test "an analyzer observation is kept only when the span is in the turn" do
    episode = opened_episode("excel")
    analysis = Rag::ConversationalTurnAnalysis.new(
      relation: "continue",
      technical_observations: [ "imán inventado", "en bajada" ]
    )
    decision = Rag::TechnicalUnderstanding.call(
      text: DESCENT,
      episode: episode,
      analysis: analysis
    )
    Rag::TechnicalUnderstanding.apply!(episode, decision)

    texts = episode.observations.pluck("text")
    assert_includes texts, "en bajada"
    assert texts.none? { |text| text.include?("inventado") }
  end

  private

  def turn(text, prior: {})
    Rag::ActiveEpisodeTurn.call(
      state: prior,
      text: text,
      now: Time.zone.parse("2026-09-28 15:55:00 -0300"),
      enabled: true,
      correlation_id: "query:journey"
    )
  end

  def opened_episode(goal)
    episode = Rag::ActiveEpisode.open(correlation_id: "query:open", now: Time.current)
    episode.assign_goal!(goal, correlation_id: "query:open")
    episode
  end
end
