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

  test "a full VF5 question keeps the written token and does not become VF5+" do
    text = "¿Cómo uso el módulo electrónico VF5?"
    decision = module_decision(text)
    resolution = Rag::DocumentIdentityCatalog.current.resolve_designator("VF5")

    assert_includes text.scan(Rag::TechnicalUnderstanding::TOKEN_RE), "VF5"
    assert_not_includes text.scan(Rag::TechnicalUnderstanding::TOKEN_RE), "VF5+"
    assert_equal :none, resolution.status
    assert_nil resolution.value
    assert_includes decision.retrieval_query, text
    assert_not_includes decision.retrieval_query, "VF5+"
    assert_not_includes decision.retrieval_query.downcase, "necesitas"
    assert_equal true, decision.owns_query
    assert identity_writes(decision).empty?
    assert_equal [ "VF5" ], stored_identifiers(text)
  end

  test "a full VF5+ question stays on its own sentence" do
    text = "¿Cómo uso el módulo electrónico VF5+?"
    decision = module_decision(text)
    resolution = Rag::DocumentIdentityCatalog.current.resolve_designator("VF5+")

    assert_includes text.scan(Rag::TechnicalUnderstanding::TOKEN_RE), "VF5+"
    assert_equal :exact, resolution.status
    assert_equal "VF5+", resolution.value
    assert_nil resolution.type
    assert_equal false, decision.owns_query
    assert_includes decision.retrieval_query, text
    assert_not_includes decision.retrieval_query.downcase, "necesitas"
    assert identity_writes(decision).empty?
    assert_equal [ "VF5+" ], stored_identifiers(text)
    assert_not Rag::ActiveEpisodeTurn.written_token?(text, "VF5")
  end

  test "CEA15 and CEA15+ stay the tokens that were written" do
    catalog = Rag::DocumentIdentityCatalog.current
    plain = catalog.resolve_designator("CEA15")
    plus = catalog.resolve_designator("CEA15+")

    assert_equal :none, plain.status
    assert_nil plain.value
    assert_equal :exact, plus.status
    assert_equal "CEA15+", plus.value
    assert_nil plus.type

    {
      "CEA15" => "¿Cómo uso la placa electrónica CEA15?",
      "CEA15+" => "¿Cómo uso la placa electrónica CEA15+?"
    }.each do |token, text|
      decision = module_decision(text)

      assert_includes text.scan(Rag::TechnicalUnderstanding::TOKEN_RE), token, text
      assert_includes decision.retrieval_query, text
      assert identity_writes(decision).empty?, text
      assert_equal [ token ], stored_identifiers(text), text
    end
    assert_not_includes module_decision("¿Cómo uso la placa electrónica CEA15?").retrieval_query, "CEA15+"
    assert_not Rag::ActiveEpisodeTurn.written_token?("¿Cómo uso la placa electrónica CEA15+?", "CEA15")
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

  def module_decision(text)
    Rag::TechnicalUnderstanding.call(
      text: text,
      episode: opened_episode("las puertas no cierran"),
      prior_turns: [ { "content" => "¿Necesitas controlador?" } ]
    )
  end

  def identity_writes(decision)
    decision.mutations.select { |item| item[:op] == :write }
  end

  def stored_identifiers(text)
    result = turn(text)
    assert_nil result.state.dig("facts", "controller")
    assert_nil result.state.dig("facts", "model")
    assert_nil result.state.dig("facts", "manufacturer")
    Array(result.state["identifiers"]).pluck("value")
  end

  def opened_episode(goal)
    episode = Rag::ActiveEpisode.open(correlation_id: "query:open", now: Time.current)
    episode.assign_goal!(goal, correlation_id: "query:open")
    episode
  end
end
