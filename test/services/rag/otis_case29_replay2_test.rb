# frozen_string_literal: true

require "test_helper"

module Stage1Live
  NO_RUN = true unless const_defined?(:NO_RUN)
end
load Rails.root.join("script/field_companion/run_stage1_live.rb") unless Stage1Live.respond_to?(:judge, true)
require Rails.root.join("test/support/otis_case29_replay")

# Offline replay of live run 20261120T134952Z (replay 2 of Otis case 29, flag
# on). T1, T2 and T3 were accepted. T4, T5 and T6 failed for three reasons the
# capture shows, none of them in the generator:
#
# T4 published "¿en qué punto exacto se detiene la hoja? ¿…? La respuesta
# cambia si…": the explanation after the question shared its line, so no line
# ended in "?" and the question was never stored. The pending stayed on T3's
# q3. T5 and T6 closed the check, but q3 was answered in part, and a pending
# answered in part stayed owed after a publication that no longer shows it.
# The T5 rubric did not read «Esta lectura se limita a la prueba que
# reportaste» as the limit it states.
class Rag::OtisCase29Replay2Test < ActiveSupport::TestCase
  FIXTURE = JSON.parse(Rails.root.join("test/fixtures/files/field_companion/otis_case29_live_20261120T134952Z.json").read).fetch("turns")
  Q3 = "¿Al intentar cerrar, ves que la hoja roce o se trabe en la guía del piso 3, o que haya algún obstáculo en el recorrido?"
  Q4 = "¿en qué punto exacto se detiene la hoja? ¿Dentro de la zona con residuos de la guía del piso 3 o antes de llegar a ella?"

  test "with the flag on the six turns of the live run pass offline" do
    with_check_outcome_flag("true") do
      verdicts = replay.to_h { |label, row| [ label, row[:summary].dig("rubric", "failed") ] }

      assert_equal %w[t1 t2 t3 t4 t5 t6].index_with { [] }, verdicts
    end
  end

  test "T4 stores the question it published even when its reason shares the line" do
    with_check_outcome_flag("true") do
      row = replay.fetch("t4")

      assert_equal Q3, row[:summary].dig("pending_before", "question")
      assert_equal Q4, row[:reloaded].pending_question["question"]
      assert_equal Q4, row[:summary]["asked_again"]
    end
  end

  test "T5 leaves nothing waiting and T6 only the plate question, though q3 was answered in part" do
    with_check_outcome_flag("true") do
      turns = replay

      assert_equal "partial", Rag::AnswerContract.part_state(turns.dig("t5", :episode_after_reduction), "p3")
      assert_nil turns.dig("t5", :reloaded).pending_question
      assert_equal "controller", turns.dig("t6", :reloaded).pending_question["type"], "the only question T6 publishes is the plate one, with no documented question left open"
      assert_includes turns.dig("t6", :published), turns.dig("t6", :reloaded).pending_question["question"]
      assert_equal %w[dcl dfc], Rag::DeclaredUnverified.open_codes(turns.dig("t5", :reloaded)).sort
      assert_equal [ "dcl" ], Rag::DeclaredUnverified.open_codes(turns.dig("t6", :reloaded))
    end
  end

  test "a pending answered in part is cleared only when the publication hides it and the turn reported a test result" do
    with_check_outcome_flag("true") do
      episode = replay.dig("t5", :episode_after_reduction)
      cid = FIXTURE.dig("t5", "correlation_id")
      closing = FIXTURE.dig("t5", "live", "published")
      supersede = ->(text, correlation_id) { Rag::ActiveEpisodeTurn.superseded_pending?(episode, text, correlation_id) }

      assert supersede.(closing, cid), "T5 reported a maneuver result and the closing does not show the question"
      assert_equal Q4, episode.pending_question["question"], "T4 stored its own question"
      assert_not supersede.("#{closing}\n\n#{Q4}", cid), "the publication shows it again: still owed"
      assert_not supersede.(closing, FIXTURE.dig("t4", "correlation_id")), "a turn with no test result leaves it owed"
    end
  end

  test "with the flag off the base behavior is kept: the question with its reason is not stored and q3 stays" do
    with_check_outcome_flag(nil) do
      turns = replay

      assert_not_equal Q4, turns.dig("t4", :reloaded).pending_question&.dig("question")
      assert_nil turns.dig("t4", :summary, "asked_again")
    end
  end

  include Otis29Replay
end
