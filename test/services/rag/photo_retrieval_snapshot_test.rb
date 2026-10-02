# frozen_string_literal: true

require "test_helper"

class Rag::PhotoRetrievalSnapshotTest < ActiveSupport::TestCase
  LEGACY_QUESTION = "la consulta anterioir , de eso estoy hablando y por eso te comparti la foto"
  SAME_TURN_QUESTION = "¿Qué ves y qué debería revisar primero?"

  test "nil relevance supplies ephemeral identity without writing the episode" do
    episode = leveling_episode
    before = episode.to_h
    result = capture(episode, question: LEGACY_QUESTION, relevance: nil)

    assert_equal "Orona", result.equipment_identity.manufacturer
    assert_includes result.equipment_identity.needles, "PBCM-V3"
    assert_equal "photo", result.equipment_identity.facts.find { |fact| fact["slot"] == "model" }["source"]
    assert_includes result.retrieval_question, LEGACY_QUESTION
    assert_includes result.retrieval_question, "no nivela en planta 3"
    assert_includes result.retrieval_question, "Orona"
    assert_includes result.retrieval_question, "PBCM-V3"
    assert_nil episode.fact("manufacturer")
    assert_nil episode.fact("model")
    assert_equal before, episode.to_h
  end

  test "uncertain relevance supplies ephemeral identity and does not promote facts" do
    episode = leveling_episode
    result = capture(episode, question: "de la foto, qué reviso primero", relevance: "uncertain")

    assert_equal "Orona", result.equipment_identity.manufacturer
    assert_includes result.equipment_identity.needles, "PBCM-V3"
    assert_nil episode.fact("manufacturer")
    assert_includes result.retrieval_question, "no nivela en planta 3"
    assert_includes result.retrieval_question, "Orona"
  end

  test "relevant observation is identity and still does not write from the snapshot" do
    episode = leveling_episode
    result = capture(episode, question: SAME_TURN_QUESTION, relevance: "relevant")

    assert_equal "Orona", result.equipment_identity.manufacturer
    assert_includes result.retrieval_question, SAME_TURN_QUESTION
    assert_includes result.retrieval_question, "no nivela en planta 3"
    assert_includes result.retrieval_question, "PBCM-V3"
    assert_nil episode.fact("manufacturer")
  end

  test "unrelated photo does not contribute identity and an episode fact still can" do
    episode = leveling_episode
    episode.write_fact!(
      "manufacturer", status: "known", value: "KONE", source: "user",
      correlation_id: "ep", at: Time.current.iso8601
    )
    result = capture(episode, question: "según la foto", relevance: "unrelated")

    assert_equal "KONE", result.equipment_identity.manufacturer
    assert_equal [ "KONE" ], result.equipment_identity.needles
    assert_not_includes result.retrieval_question, "Orona"
    assert_not_includes result.retrieval_question, "PBCM-V3"
    assert_includes result.retrieval_question, "KONE"
    assert_includes result.retrieval_question, "no nivela en planta 3"
  end

  test "unrelated photo with no other identity leaves both fields without that plate" do
    result = capture(leveling_episode, question: "según la foto", relevance: "unrelated")

    assert_nil result.equipment_identity
    assert_not_includes result.retrieval_question, "Orona"
    assert_not_includes result.retrieval_question, "PBCM-V3"
    assert_includes result.retrieval_question, "no nivela en planta 3"
  end

  test "a photo without a question does not take ephemeral identity" do
    episode = leveling_episode
    result = Rag::PhotoRetrievalSnapshot.capture(
      episode: episode,
      question: nil,
      observation: orona_observation(nil),
      correlation_id: "photo:1"
    )

    assert_nil result.equipment_identity
    assert_nil result.retrieval_question
    assert_nil episode.fact("manufacturer")
  end

  test "rejected photo values and catalog facts stay out" do
    episode = leveling_episode
    episode.append_rejected!("manufacturer", "Orona")
    episode.append_rejected!("model", "PBCM-V3")
    episode.write_fact!(
      "controller", status: "known", value: "CAT-1", source: "catalog",
      correlation_id: "ep", at: Time.current.iso8601
    )
    result = capture(episode, question: "qué es", relevance: nil)

    assert_nil result.equipment_identity
    assert_not_includes result.retrieval_question, "Orona"
    assert_not_includes result.retrieval_question, "PBCM-V3"
    assert_not_includes result.retrieval_question, "CAT-1"
  end

  test "a long turn keeps the goal and the accepted identity inside the composer cap" do
    episode = leveling_episode
    3.times do |index|
      episode.append_observation!("observacion larga #{index} " + ("detalle " * 20), correlation_id: "ep")
    end
    episode.write_fact!(
      "fault_code", status: "known", value: "E51", source: "user",
      correlation_id: "ep", at: Time.current.iso8601
    )
    result = capture(episode, question: "pregunta " * 80, relevance: nil)

    assert_operator result.retrieval_question.length, :<=, Rag::FollowupQueryRewriter::MAX_COMPOSED_CHARS
    assert_includes result.retrieval_question, "no nivela en planta 3"
    assert_includes result.retrieval_question, "Orona"
    assert_includes result.retrieval_question, "PBCM-V3"
    assert_not_includes result.retrieval_question, "observacion larga"
  end

  private

  def leveling_episode
    episode = Rag::ActiveEpisode.open(correlation_id: "ep", now: Time.zone.parse("2026-10-02 12:00:00"))
    episode.assign_goal!("no nivela en planta 3", correlation_id: "ep")
    episode
  end

  def orona_observation(relevance)
    {
      "manufacturer" => "Orona",
      "model" => "PBCM-V3",
      "relevance_to_goal" => relevance
    }
  end

  def capture(episode, question:, relevance:)
    Rag::PhotoRetrievalSnapshot.capture(
      episode: episode,
      question: question,
      observation: orona_observation(relevance),
      correlation_id: "photo:1"
    )
  end
end
