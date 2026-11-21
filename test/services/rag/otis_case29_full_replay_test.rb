# frozen_string_literal: true

require "test_helper"

module Stage1Live
  NO_RUN = true unless const_defined?(:NO_RUN)
end
load Rails.root.join("script/field_companion/run_stage1_live.rb") unless Stage1Live.respond_to?(:judge, true)
require Rails.root.join("test/support/otis_case29_replay")

# Offline replay of the whole Otis case 29 script (T1 to T6) captured in live
# run 20261120T121417Z. Nothing is injected between turns: the episode a turn
# leaves after publication and reload is the episode the next one starts from.
# The only captured inputs are the interpreter's tool output, the sources the
# generator received and the model's raw draft of each turn. Perception,
# routing, reduction, claim backing, publication, pending storage, reload,
# the runner summary and the rubric are the real code. No model, no network,
# no database.
#
# Two turns stay failed offline on purpose. T1 and T3 fail because of what the
# model drafted (it asked front or rear door again and did not ask for the
# history event, nor move on from the photo), and no deterministic stage can
# invent the question it did not ask. They change only with a new live run.
class Rag::OtisCase29FullReplayTest < ActiveSupport::TestCase
  FIXTURE = JSON.parse(Rails.root.join("test/fixtures/files/field_companion/otis_case29_live_20261120T121417Z.json").read).fetch("turns")
  ALLOWED = Stage1Live::OTIS.map { |_uid, key| File.basename(key, ".pdf") }.freeze

  test "with the flag on T2, T4, T5 and T6 are accepted and T1 and T3 fail only on what the model drafted" do
    with_check_outcome_flag("true") do
      turns = replay
      verdicts = turns.to_h { |label, row| [ label, row[:summary].dig("rubric", "failed") ] }

      assert_equal(
        { "t1" => [ "history_event_or_equivalent_requested" ], "t2" => [], "t3" => [ "advances_from_photo_and_report" ],
          "t4" => [], "t5" => [], "t6" => [] },
        verdicts
      )
      assert_equal %w[t2 t4 t5 t6], turns.select { |_label, row| row[:summary]["accepted"] }.keys
    end
  end

  test "T1 and T3 asked the open front or rear question again: the draft is the first divergence, not a later stage" do
    with_check_outcome_flag("true") do
      turns = replay
      question = "¿La puerta del piso 3 es frontal o trasera?"

      assert_includes FIXTURE.dig("t1", "raw_draft"), question
      assert_equal question, turns.dig("t1", :summary, "asked_again")
      assert_equal question, turns.dig("t2", :summary, "pending_before", "question")
      assert_equal question, turns.dig("t3", :summary, "asked_again")
      assert_equal question, turns.dig("t3", :summary, "pending_before", "question")
    end
  end

  test "with the flag on T1 asks the generator for the history event and T2 to T4 tell it the open question is unanswered" do
    with_check_outcome_flag("true") do
      turns = replay
      base = BedrockRagService::REFERENCE_CONTEXT
      question = "¿La puerta del piso 3 es frontal o trasera?"

      assert_equal "#{base} #{BedrockRagService::REFERENCE_EVENT_REQUEST}", turns.dig("t1", :context)
      %w[t2 t3 t4].each do |label|
        context = turns.dig(label, :context)

        assert_includes context, "Tu pregunta anterior sigue sin respuesta: «#{question}»", label
        assert_includes context, "Repite esa pregunta solo si su respuesta cambia la siguiente comprobación respaldada"
        assert_not_includes context, BedrockRagService::REFERENCE_EVENT_REQUEST
      end
      assert_includes turns.dig("t4", :context), BedrockRagService::REFERENCE_STOP_NEXT
      assert_includes turns.dig("t3", :context), BedrockRagService::REFERENCE_GUIDE_NEXT
      %w[t1 t2 t3 t5 t6].each do |label|
        assert_not_includes turns.dig(label, :context).to_s, BedrockRagService::REFERENCE_STOP_NEXT, label
      end
      %w[t1 t2 t4 t5 t6].each do |label|
        assert_not_includes turns.dig(label, :context).to_s, BedrockRagService::REFERENCE_GUIDE_NEXT, label
      end
      %w[t5 t6].each { |label| assert_equal base, turns.dig(label, :context), "#{label} has no open question to repeat" }
    end
  end

  test "the prompt of T1 and T3 carries the note between the message and the case block, without displacing message, question or sources" do
    with_check_outcome_flag("true") do
      turns = replay
      session = Struct.new(:conversation_history, :ledger).new([], nil)
      prompts = %w[t1 t3].to_h do |label|
        turn = FIXTURE.fetch(label)
        episode = turns.fetch(label).fetch(:episode_after_reduction)
        prepared = Rag::CompanionDirectAnswer.prepare(
          raw_question: turn.fetch("message"), chunks: chunks(turn), episode: episode, session: session,
          correlation_id: turn.fetch("correlation_id"), reference_context: turns.dig(label, :context)
        )
        [ label, prepared.user ]
      end

      assert_operator prompts["t1"].index("Mensaje de este turno:"), :<, prompts["t1"].index(BedrockRagService::REFERENCE_EVENT_REQUEST)
      assert_includes prompts["t1"], FIXTURE.dig("t1", "message")
      assert_includes prompts["t3"], FIXTURE.dig("t3", "message")
      assert_includes prompts["t3"], "Tu pregunta anterior sigue sin respuesta: «¿La puerta del piso 3 es frontal o trasera?»"
      assert_includes prompts["t3"], "Fuentes de este turno"
      assert_includes prompts["t3"], FIXTURE.dig("t3", "sources", 0, "text")[0, 80]
    end
  end

  test "T3 tells the generator that the DCL the technician just declared is a report, not the check to ask now" do
    with_check_outcome_flag("true") do
      turns = replay
      turn = FIXTURE.fetch("t3")
      session = Struct.new(:conversation_history).new([
        { "role" => "user", "correlation_id" => turn.fetch("correlation_id"), "content" => turn.fetch("message") }
      ])
      lines = Rag::CheckOutcome.context_lines(
        turns.dig("t3", :episode_after_reduction), session, correlation_id: turn.fetch("correlation_id")
      )
      now = lines.find { |line| line.start_with?("Declarado en este turno como no hecho todavía") }

      assert_includes now, "no lo pidas como tu siguiente comprobación en este turno"
      assert_includes now, "Parte de lo demás que trae el mismo mensaje (relato o foto)"
      assert_includes now, "La foto de la guía es el dato nuevo"
      assert_includes now, "No pidas ejecutar ajustes mecánicos"
      assert_includes lines.join("\n"), "Todavía no he confirmado el.estado de DCL"
      assert_nil lines.find { |line| line.start_with?("Declarado por el técnico como no verificado") }, "T3 is where it is first declared"
      t5 = FIXTURE.fetch("t5")
      later_session = Struct.new(:conversation_history).new([
        { "role" => "user", "correlation_id" => t5.fetch("correlation_id"), "content" => t5.fetch("message") }
      ])
      later = Rag::CheckOutcome.context_lines(
        turns.dig("t5", :episode_after_reduction), later_session, correlation_id: t5.fetch("correlation_id")
      )
      assert_not_includes later.join("\n"), "La foto de la guía es el dato nuevo"
    end
  end

  test "with the flag off the reference context is the base line in every turn" do
    with_check_outcome_flag(nil) do
      replay.each { |label, row| assert_equal BedrockRagService::REFERENCE_CONTEXT, row[:context], label }
    end
  end

  test "T2 keeps the faithful paraphrase of 0102 and drops the unsupported assignment of signals to the door" do
    with_check_outcome_flag("true") do
      row = replay.fetch("t2")
      removed = row[:result][:companion_publication].to_h

      assert_includes row[:published], "ocurre al faltar DCL, DFC o DW"
      assert_not_includes row[:published], "delantera"
      assert_not_includes row[:published], "trasera con"
      assert_equal [ "unbacked_citation" ], row[:backing_removed], removed.inspect
      assert_equal [ "unbacked_citation", "unbacked_citation" ], FIXTURE.dig("t2", "live", "removed"), "the live run removed both"
    end
  end

  test "T3 keeps the reading of 0102 with the three signals and still drops the rear door assignment" do
    with_check_outcome_flag("true") do
      row = replay.fetch("t3")

      assert_includes row[:published], "DCL,DFC ó DW"
      assert_not_includes row[:published], "^DCL"
      assert_equal [ "unbacked_citation" ], row[:backing_removed]
      assert_equal "Todavía no he confirmado el.estado de DCL", row[:reloaded].checks.first["subject"]
    end
  end

  test "T4 reads the DCL declaration of T3 from the persisted check" do
    with_check_outcome_flag("true") do
      summary = replay.dig("t4", :summary)

      assert_empty summary.dig("earlier_observations").grep(/DCL/), "DCL is not an observation: it is the check the technician declared"
      assert summary.fetch("earlier_checks").any? { |row| row["subject"].match?(/DCL/) && row["status"] == "not_done" }
      assert_empty summary.dig("rubric", "failed")
    end
  end

  test "T5 stores both unverified declarations, closes without a question and nothing waits after the reload" do
    with_check_outcome_flag("true") do
      row = replay.fetch("t5")
      subjects = row[:reloaded].checks.to_h { |check| [ check["subject"], check["status"] ] }

      assert_equal "not_done", subjects["No llegamos a verificar DCL ni DFC"]
      assert_equal "done", subjects["Encontré residuos en la guía y los retire"]
      assert_equal %w[dcl dfc], Rag::DeclaredUnverified.open_codes(row[:reloaded]).sort
      assert_nil row[:reloaded].pending_question
      assert_not_includes row[:published], "?"
      assert_equal [], row[:summary].dig("rubric", "failed")
    end
  end

  test "T6 records the spontaneous DFC reading, keeps DCL unverified and does not ask it" do
    with_check_outcome_flag("true") do
      row = replay.fetch("t6")
      summary = row[:summary]

      assert_includes summary["observations"].join(" "), "LED DFC"
      assert_equal [ "dcl" ], Rag::DeclaredUnverified.open_codes(row[:reloaded])
      assert summary["earlier_checks"].any? { |check| check["subject"].match?(/DFC/) }, "the DFC declaration of T5 is on record"
      assert_not_includes row[:published], "DCL aparece"
      assert_equal [], summary.dig("rubric", "failed")
    end
  end

  test "T6 publishes the plate question for a reason that exists in that turn and the question is stored as the pending" do
    with_check_outcome_flag("true") do
      row = replay.fetch("t6")
      question = I18n.t("rag.controller_label_question", locale: :es)

      assert_nil row[:episode_before].pending_question, "no documented question is open, so the rule may ask"
      assert_nil row[:episode_before].fact("controller"), "the controller was never confirmed"
      assert_includes row[:published], question
      assert_includes row[:published], "[12]", "the DFC table is cited"
      assert_match(/no confirma la placa/, row[:published], "and it keeps the applicability limit")
      assert_equal "controller", row[:reloaded].pending_question["type"]
      assert_equal question, row[:reloaded].pending_question["question"]
    end
  end

  test "flag on: a DCL question after the stop is replaced by the impediment the draft already wrote" do
    draft = "Que la hoja se detenga antes del cierre encaja con el 0102.\n\n" \
      "Siguiente comprobación: con la hoja detenida antes del cierre, ¿qué estado muestra DCL, activo o inactivo?\n\n" \
      "Pendiente: si hay algo que trabe o roce en la guía inferior (la foto muestra suciedad), y el estado real de DCL."
    asked = "con la hoja detenida antes del cierre, ¿qué estado muestra DCL, activo o inactivo?"
    result = { answer: draft, route_outcome: :answered, pending_question: { "question" => asked } }
    service = BedrockRagService.allocate
    service.instance_variable_set(:@companion_direct_sources, [])

    with_check_outcome_flag("true") do
      promoted = service.send(:impediment_question_result, result, "Se detiene antes", :es)

      assert_includes promoted[:answer], "¿Hay algo que trabe o roce en la guía inferior?"
      assert_not_includes promoted[:answer], "activo o inactivo"
      assert_match(/trabe o roce/, promoted[:pending_question]["question"])
    end
    with_check_outcome_flag(nil) do
      assert_nil service.send(:impediment_question_result, result, "Se detiene antes", :es)
    end
  end

  test "with the flag off the base behavior is kept: T5 loses the declarations and T6 shows a question it cannot store" do
    with_check_outcome_flag(nil) do
      turns = replay
      t5 = turns.fetch("t5")
      t6 = turns.fetch("t6")

      assert_empty t5[:reloaded].checks.select { |check| check["subject"].match?(/DCL ni DFC/) }
      assert_includes t6[:published], I18n.t("rag.controller_label_question", locale: :es)
      assert_nil t6[:reloaded].pending_question
    end
  end

  include Otis29Replay
end
