# frozen_string_literal: true

require "test_helper"

# Saving the question a turn published, near the 4 KB episode budget. The
# question may be stored, or refused with the previous state restored, but it
# never costs the case an observation, a check or a declared datum. Only
# unindexed excerpts, which the history can rebuild, are dropped to make room.
class Rag::PendingBudgetTest < ActiveSupport::TestCase
  NOW = Time.zone.parse("2026-11-20 10:00:00 -03:00")
  CID = "query:budget"
  OBSERVATIONS = [
    "En el.piso 3 la puerta intenta cerrar y vuelve abrir " + "a" * 100,
    "En el historial de eventos aparece 0102 0pMode DTC " + "b" * 100,
    "Encontré residuos en la guía del piso 3 " + "c" * 100
  ].freeze
  CHECKS = [
    { "subject" => "Todavía no he confirmado el estado de DCL", "status" => "not_done" },
    { "subject" => "No llegamos a verificar DFC", "status" => "not_done" },
    { "subject" => "Encontré residuos en la guía y los retiré", "status" => "done", "result" => "puerta cerró" }
  ].freeze

  test "a documented question near the limit keeps every observation and check, in both flag modes" do
    [ nil, "true" ].each do |flag|
      with_check_outcome_flag(flag) do
        outcomes = lengths.map { |length| outcome(question("documented_context", length)) }

        assert_includes outcomes.map(&:first), nil, "short questions are stored (flag #{flag.inspect})"
        assert_includes outcomes.map(&:first), "pending_overflow", "the sweep reaches the budget (flag #{flag.inspect})"
        outcomes.each { |_code, kept, stored| assert_case_kept(kept, stored) }
      end
    end
  end

  test "dropping excerpts is what makes room, and the question is then stored" do
    with_check_outcome_flag("true") do
      episode = build_episode(excerpts: 8)
      before = episode.observations.deep_dup
      question = question("documented_context", 380)

      assert Rag::ActiveEpisode.budget_refused?(episode.serial_hash.merge("pending_question" => question).compact),
        "with its excerpts the payload does not fit"
      assert_nil Rag::ActiveEpisodeTurn.install_pending!(episode, question, CID)

      stored = episode.to_h
      assert_equal question["question"], stored.dig("pending_question", "question")
      assert_equal before, stored["observations"]
      assert_operator stored["excerpts"].to_a.size, :<, 8, "the oldest excerpts went first"
      assert_equal episode.excerpts.last(stored["excerpts"].to_a.size), stored["excerpts"].to_a, "and the newest stayed"
      assert_equal CHECKS.pluck("subject"), stored["checks"].pluck("subject")
    end
  end

  test "with the flag on the controller label question is stored as the documented one is; flag off it is refused" do
    question = question("controller", 380)

    with_check_outcome_flag("true") do
      episode = build_episode(excerpts: 8)
      assert_nil Rag::ActiveEpisodeTurn.install_pending!(episode, question, CID)
      assert_case_kept(episode, episode.to_h)
      assert_equal "controller", episode.to_h.dig("pending_question", "type")
    end
    with_check_outcome_flag(nil) do
      episode = build_episode(excerpts: 8)
      assert_equal "pending_overflow", Rag::ActiveEpisodeTurn.install_pending!(episode, question, CID)
      assert_case_kept(episode, episode.to_h)
      assert_nil episode.to_h["pending_question"]
    end
  end

  private

  def lengths
    (0..60).map { |step| 100 + step * 25 }
  end

  def question(type, length)
    text = "¿La puerta del piso 3 es frontal o trasera? #{'x' * length}".first(length)
    { "type" => type, "question" => text, "targets" => [] }
  end

  def outcome(question)
    episode = build_episode(excerpts: 8)
    code = Rag::ActiveEpisodeTurn.install_pending!(episode, question, CID)
    [ code, episode, episode.to_h ]
  end

  def assert_case_kept(episode, stored)
    assert_equal OBSERVATIONS, stored["observations"].pluck("text")
    assert_equal CHECKS.pluck("subject"), stored["checks"].pluck("subject")
    assert_equal CHECKS.pluck("status"), stored["checks"].pluck("status")
    assert_equal OBSERVATIONS, episode.observations.pluck("text")
    assert_operator JSON.generate(stored).bytesize, :<=, Rag::ActiveEpisode::MAX_BYTES
  end

  def build_episode(excerpts:)
    episode = Rag::ActiveEpisode.open(correlation_id: CID, now: NOW)
    episode.goal = { "text" => "En el.piso 3 la puerta intenta cerrar y vuelve abrir", "correlation_id" => CID }
    episode.observations = OBSERVATIONS.map { |text| { "text" => text, "correlation_id" => CID } }
    episode.checks = CHECKS.map { |row| row.merge("correlation_id" => CID) }
    episode.excerpts = Array.new(excerpts) do |index|
      { "text" => "Frase sin indexar número #{index} #{'z' * 300}", "cid" => CID, "a" => 0, "b" => 10, "source" => "turn_excerpt" }
    end
    episode
  end
end
