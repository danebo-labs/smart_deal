# frozen_string_literal: true

require "test_helper"

class Rag::RoutePolicyTest < ActiveSupport::TestCase
  setup do
    @now = Time.current
  end

  test "unclear asks in i18n and does not retrieve even with focus and identity" do
    episode = open_episode
    episode.assign_goal!("la puerta no cierra", correlation_id: "seed")
    episode.write_fact!("controller", status: "known", value: "NICE3000", source: "user", correlation_id: "seed", at: @now.iso8601)

    decision = Rag::RoutePolicy.call(
      previous: episode,
      perception: perception("unclear", target: "work_relation"),
      focus_count: 2,
      focus_document_ids: [ 1 ],
      focus_uris: [ "s3://bucket/manual.pdf" ]
    )

    assert_equal "clarify_first", decision.decision
    assert_equal false, decision.outside_discovery
    assert_equal false, decision.owns_query
    assert_equal "¿Esto sigue siendo el mismo equipo o estás hablando de otro?", decision.clarification
    assert_equal "work_relation", decision.pending_question["type"]
    assert_equal [ 1 ], decision.focus_document_ids
  end

  test "a thin new work clarifies without retrieval even when a manual is focused" do
    decision = Rag::RoutePolicy.call(
      previous: Rag::ActiveEpisode.new,
      perception: perception("new_work"),
      focus_count: 2,
      focus_uris: [ "s3://bucket/manual.pdf" ]
    )

    assert_equal "clarify_first", decision.decision
    assert_equal false, decision.owns_query
    assert_equal false, decision.outside_discovery
    assert_nil decision.pending_question
    assert_equal "¿Qué equipo o qué falla estás revisando?", decision.clarification
  end

  test "a new work with a technical payload is ready" do
    observed = perception("new_work", observations: [ "que no nivela" ])

    decision = Rag::RoutePolicy.call(previous: Rag::ActiveEpisode.new, perception: observed, focus_count: 2)

    assert_equal "ready", decision.decision
    assert decision.performs_retrieval?
  end

  test "fallback on a work relation pending repeats that question and keeps its carry" do
    episode = open_episode
    episode.assign_goal!("la puerta no cierra", correlation_id: "seed")
    episode.write_fact!("controller", status: "known", value: "NICE3000", source: "user", correlation_id: "seed", at: @now.iso8601)
    episode.pending_question = { "type" => "work_relation", "carry" => [ "Q2" ] }

    decision = fallback_for(episode, "Es otro ascensor")

    assert_equal "clarify_first", decision.decision
    assert_equal false, decision.outside_discovery
    assert_equal false, decision.owns_query
    assert_nil decision.retrieval_query
    assert_equal "¿Esto sigue siendo el mismo equipo o estás hablando de otro?", decision.clarification
    assert_equal "work_relation", decision.pending_question["type"]
    assert_equal [ "Q2" ], decision.pending_question["carry"]
    assert_equal true, decision.fallback
  end

  test "fallback on a referent pending repeats that question without retrieval" do
    episode = open_episode
    episode.assign_goal!("la puerta no cierra", correlation_id: "seed")
    episode.pending_question = { "type" => "referent" }

    decision = fallback_for(episode, "el de arriba", focus_count: 2)

    assert_equal "clarify_first", decision.decision
    assert_equal false, decision.outside_discovery
    assert_equal false, decision.owns_query
    assert_nil decision.retrieval_query
    assert_equal "¿A qué equipo o elemento te refieres?", decision.clarification
    assert_equal "referent", decision.pending_question["type"]
    assert_equal [ 4 ], decision.focus_document_ids
  end

  test "fallback on a correction target repeats that question and keeps carry" do
    episode = open_episode
    episode.assign_goal!("la puerta no cierra", correlation_id: "seed")
    episode.pending_question = { "type" => "correction_target", "carry" => [ "Q2" ] }

    decision = fallback_for(episode, "no era ese")

    assert_equal "clarify_first", decision.decision
    assert_equal false, decision.owns_query
    assert_nil decision.retrieval_query
    assert_equal "¿Qué dato del equipo quieres corregir?", decision.clarification
    assert_equal [ "Q2" ], decision.pending_question["carry"]
  end

  test "fallback with a controller pending still composes the turn" do
    episode = open_episode
    episode.assign_goal!("la puerta no cierra", correlation_id: "seed")
    episode.pending_question = { "type" => "controller" }

    decision = fallback_for(episode, "sigue igual")

    assert_equal "ready", decision.decision
    assert_includes decision.retrieval_query, "sigue igual"
    assert_equal I18n.t("rag.clarify_controller", locale: :es), decision.clarification
  end

  test "a symptom with an equipment token searches without asking the controller" do
    episode = open_episode
    episode.write_fact!("manufacturer", status: "known", value: "Elemont", source: "catalog", correlation_id: "seed", at: @now.iso8601)
    episode.append_identifier!("MH", correlation_id: "seed")
    observed = perception("report", observations: [ "la puerta 1 no termina de cerrar" ])

    decision = Rag::RoutePolicy.call(previous: episode, perception: observed, focus_count: 0, locale: :es)

    assert_equal "ready", decision.decision
    assert_nil decision.clarification
    assert decision.performs_retrieval?
  end

  test "an ambiguous designator still asks which document it is" do
    episode = open_episode
    decision = Rag::RoutePolicy.call(
      previous: episode,
      perception: perception(
        "report",
        ambiguities: [ Rag::TurnPerception::Ambiguity.new(span: "nice300", candidates: [ "NICE3000", "NICE3000new" ]) ]
      ),
      focus_count: 0,
      locale: :es
    )

    assert_equal "search_and_clarify", decision.decision
    assert_includes decision.clarification, "NICE3000"
    assert_equal :always, decision.ask_when
  end

  test "a short token inside a focused manual still asks only if the manual does not define it" do
    mention = Rag::TurnPerception::Identity.new(
      span: "Q2", act: "mention", kind: "mention", slot: nil, value: "Q2", source: nil, manufacturer: nil
    )
    decision = Rag::RoutePolicy.call(
      previous: open_episode,
      perception: perception("report", identities: [ mention ]),
      focus_count: 1,
      locale: :es
    )

    assert_equal "search_and_clarify", decision.decision
    assert_equal :absence, decision.ask_when
    assert_includes decision.clarification, "Q2"
  end

  test "an empty episode fallback searches a symptom and does not ask the controller first" do
    decision = Rag::RoutePolicy.fallback(
      episode: Rag::ActiveEpisode.new,
      turn: "la puerta no cierra",
      focus_count: 0,
      focus_document_ids: [],
      focus_uris: [],
      catalog: nil,
      viewer_account: nil,
      locale: :es
    )

    assert_equal "ready", decision.decision
    assert_nil decision.clarification
    assert_includes decision.retrieval_query, "puerta"
    assert decision.performs_retrieval?
  end

  test "an empty episode fallback still clarifies a greeting" do
    decision = Rag::RoutePolicy.fallback(
      episode: Rag::ActiveEpisode.new,
      turn: "hola",
      focus_count: 0,
      focus_document_ids: [],
      focus_uris: [],
      catalog: nil,
      viewer_account: nil,
      locale: :es
    )

    assert_equal "clarify_first", decision.decision
    assert_equal I18n.t("rag.clarify_controller", locale: :es), decision.clarification
    assert_not decision.performs_retrieval?
  end

  test "meta still wins over unclear" do
    decision = Rag::RoutePolicy.call(
      previous: open_episode,
      perception: perception("meta", target: "work_relation"),
      focus_count: 0
    )

    assert_equal "meta", decision.decision
  end

  private

  def open_episode
    Rag::ActiveEpisode.open(correlation_id: "seed", now: @now)
  end

  def fallback_for(episode, turn, focus_count: 0)
    Rag::RoutePolicy.fallback(
      episode: episode,
      turn: turn,
      focus_count: focus_count,
      focus_document_ids: [ 4 ],
      focus_uris: [ "s3://bucket/manual.pdf" ],
      catalog: nil,
      viewer_account: nil
    )
  end

  def perception(move, target: nil, observations: [], identities: [], ambiguities: [])
    Rag::TurnPerception::Result.new(
      valid: true,
      move: move,
      observations: observations,
      pending_resolution: nil,
      clarification_target: target,
      identities: identities,
      ambiguities: ambiguities,
      field_rejections: [],
      catalog_disagreements: [],
      invalid_reason: nil
    )
  end
end
