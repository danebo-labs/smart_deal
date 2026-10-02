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

  def perception(move, target: nil, observations: [])
    Rag::TurnPerception::Result.new(
      valid: true,
      move: move,
      observations: observations,
      pending_resolution: nil,
      clarification_target: target,
      identities: [],
      ambiguities: [],
      field_rejections: [],
      catalog_disagreements: [],
      invalid_reason: nil
    )
  end
end
