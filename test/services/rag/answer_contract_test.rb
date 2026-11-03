# frozen_string_literal: true

require "test_helper"

# Synthetic contract objects. These turns are not captured model output.
# A stored reply is a reference into history. Ruby checks the reference.
# The same normalized wording of a closed part is that publication again.
# A different wording is not decided to be the same question.
class Rag::AnswerContractTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  MAIN = "¿La válvula 4 está abierta?"
  CLARIFICATION = "¿El indicador encendido es el de marcha o el de fallo?"
  BOTH = "X no sé, Y sí"
  T1 = "Estoy con un Fermator VF5+. Después de un corte de alimentación, al volver la corriente la puerta abrió muy despacio. ¿Por dónde empiezo?"
  T2 = "Fue solo la primera apertura. Después volvió a abrir y cerrar como antes."
  SLOW = "¿La primera apertura después del corte fue lenta?"

  setup do
    @user = users(:one)
    @account = accounts(:legacy)
  end

  test "both clauses survive reload and only the named clause is unknown" do
    with_flags do
      session = boot_session
      episode = publish(session, MAIN, shown: CLARIFICATION)
      main_id = part_id(episode, "main")
      clarification_id = part_id(episode, "clarification")
      answer(session, BOTH, [
        reply_for(episode, main_id, "unknown", BOTH, "X no sé"),
        reply_for(episode, clarification_id, "complete", BOTH, "Y sí")
      ])
      stored = reload_episode(session)
      lines = Rag::AnswerContract.context_lines(stored, session.reload)

      assert_equal "unknown", Rag::AnswerContract.part_state(stored, main_id)
      assert_equal "complete", Rag::AnswerContract.part_state(stored, clarification_id)
      assert lines.any? { |line| line.include?("X no sé") && line.include?("unknown") }
      assert lines.any? { |line| line.include?("Y sí") && line.include?("complete") }
      assert_equal MAIN, stored.pending_question["parts"].find { |part| part["role"] == "main" }["text"]
      assert_equal CLARIFICATION, stored.pending_question["parts"].find { |part| part["role"] == "clarification" }["text"]
    end
  end

  test "a partial clause stays open and keeps its text" do
    with_flags do
      session = boot_session
      episode = publish(session, MAIN)
      text = "La válvula 4 abre solo un tramo."
      answer(session, text, [ reply_for(episode, part_id(episode, "main"), "partial", text, "solo un tramo") ])
      stored = reload_episode(session)
      payload = pending_payload(stored)

      assert_equal "partial", Rag::AnswerContract.part_state(stored, part_id(stored, "main"))
      assert_includes payload["questions"].first["parts"].pluck("id"), part_id(stored, "main")
      assert_includes Rag::AnswerContract.context_lines(stored, session.reload).join("\n"), "solo un tramo"
    end
  end

  test "the published main and its clarification both reach the interpreter" do
    with_flags do
      session = boot_session
      episode = publish(session, MAIN, shown: CLARIFICATION)
      payload = pending_payload(episode)
      parts = payload["questions"].first["parts"]

      assert_equal "documented_context", payload["clarification_target"]
      assert_match(/\Aq\d+\z/, payload["questions"].first["id"])
      assert_equal [ "main", "clarification" ], parts.pluck("role")
      assert_equal [ MAIN, CLARIFICATION ], parts.pluck("text")
      assert parts.all? { |part| part["id"].match?(/\Ap\d+\z/) }
    end
  end

  test "a paraphrasing replan keeps the published formulation" do
    with_flags do
      session = boot_session
      episode = publish(session, MAIN)
      paraphrase = "¿Sigue abierta la válvula 4 en este momento?"
      prepared = Rag::CompanionPlan.prepare(
        raw_question: paraphrase, chunks: [ chunk ], episode: episode, session: session, correlation_id: "query:replan"
      )
      check = plan_result(paraphrase)
      kept = Rag::CompanionPlan.published_pending(
        "texto que no repite la formulación publicada",
        check,
        prepared,
        { "question_ref" => episode.pending_question["id"], "question" => paraphrase }
      )

      assert_equal MAIN, kept["question"]
      assert_equal MAIN, kept["parts"].find { |part| part["role"] == "main" }["text"]
      assert_equal episode.pending_question["id"], kept["id"]
    end
  end

  test "resolving the main keeps the clarification open" do
    with_flags do
      session = boot_session
      episode = publish(session, MAIN, shown: CLARIFICATION)
      answer(session, "La válvula 4 está abierta.", [
        reply_for(episode, part_id(episode, "main"), "complete")
      ])
      stored = reload_episode(session)
      payload = pending_payload(stored)

      assert_equal "complete", Rag::AnswerContract.part_state(stored, part_id(stored, "main"))
      assert_nil Rag::AnswerContract.part_state(stored, part_id(stored, "clarification"))
      assert_equal [ CLARIFICATION ], payload["questions"].first["parts"].pluck("text")
      assert_equal CLARIFICATION, payload["question"]
    end
  end

  test "resolving a clarification does not close the main" do
    with_flags do
      session = boot_session
      episode = publish(session, MAIN, shown: CLARIFICATION)
      answer(session, "Es el de marcha.", [
        reply_for(episode, part_id(episode, "clarification"), "complete")
      ])
      stored = reload_episode(session)
      payload = pending_payload(stored)

      assert_nil Rag::AnswerContract.part_state(stored, part_id(stored, "main"))
      assert_equal "complete", Rag::AnswerContract.part_state(stored, part_id(stored, "clarification"))
      assert_equal MAIN, stored.pending_question["question"]
      assert_equal [ MAIN ], payload["questions"].first["parts"].pluck("text")
    end
  end

  test "a reference to an answered part does not reopen it" do
    with_flags do
      session = boot_session
      episode = publish(session, MAIN)
      answer(session, "No sé si la válvula 4 está abierta.", [
        reply_for(episode, part_id(episode, "main"), "unknown")
      ])
      stored = reload_episode(session)
      facts = Rag::CompanionCaseFacts.build(stored, session: session)
      prepared = Rag::CompanionPlan.prepare(
        raw_question: MAIN, chunks: [ chunk ], episode: stored, session: session, correlation_id: "query:again"
      )
      checked = Rag::CompanionPlanCheck.call(
        { "links" => [], "steps" => [], "question" => MAIN, "question_about" => [], "part_ref" => part_id(stored, "main") },
        facts: facts, statements: prepared.statements, turns: []
      )
      session.record_assistant_turn!(
        "Sigo con la pregunta publicada.",
        user_id: @user.id, correlation_id: "query:keep-#{SecureRandom.hex(2)}",
        pending_question: nil, expected_episode_id: stored.episode_id
      )
      kept = reload_episode(session)

      assert_nil checked.question
      assert checked.rejections.any? { |row| row["reason"] == "part_settled" }
      assert_equal MAIN, kept.pending_question["question"]
      assert_equal "unknown", Rag::AnswerContract.part_state(kept, part_id(kept, "main"))
      payload = pending_payload(kept, session)
      assert_nil payload["question"]
      correction = payload["corrections"].find { |row| row["part_id"] == part_id(kept, "main") }
      assert_equal "r1", correction["id"]
      assert_equal "unknown", correction["state"]
      assert_includes correction["text"], "No sé si la válvula 4 está abierta."
    end
  end

  test "an unknown part repeated without references is part_settled" do
    with_flags do
      session = boot_session
      episode = publish(session, MAIN, shown: CLARIFICATION)
      answer(session, "No sé si la válvula 4 está abierta.", [
        reply_for(episode, part_id(episode, "main"), "unknown")
      ])
      stored = reload_episode(session)
      facts = Rag::CompanionCaseFacts.build(stored, session: session)
      checked = check_again(session, MAIN)

      assert_equal [ MAIN ], facts.settled_part_texts
      assert_nil Rag::AnswerContract.part_state(stored, part_id(stored, "clarification"))
      assert stored.observations.none? { |item| item.dig("answers", "r") == "unknown" }
      assert stored.observations.none? { |item| item.dig("answers", "q").present? }
      assert_nil checked.question
      assert_equal "part_settled", checked.rejections.find { |row| row["part"] == "question" }["reason"]
      assert_equal MAIN, checked.rejections.find { |row| row["part"] == "question" }["value"]

      # Case, accents, and spacing fold through the existing normalizer.
      folded = "¿LA  valvula 4 esta ABIERTA?"
      folded_check = check_again(session, folded)
      assert_nil folded_check.question
      assert_equal "part_settled", folded_check.rejections.find { |row| row["part"] == "question" }["reason"]
    end
  end

  test "a complete part repeated without references is part_settled" do
    with_flags do
      session = boot_session
      episode = publish(session, MAIN, shown: CLARIFICATION)
      answer(session, "La válvula 4 está abierta.", [
        reply_for(episode, part_id(episode, "main"), "complete")
      ])
      stored = reload_episode(session)
      checked = check_again(session, MAIN)

      assert_equal "complete", Rag::AnswerContract.part_state(stored, part_id(stored, "main"))
      assert_nil Rag::AnswerContract.part_state(stored, part_id(stored, "clarification"))
      assert stored.observations.none? { |item| item.dig("answers", "q").present? }
      assert_nil checked.question
      assert_equal "part_settled", checked.rejections.find { |row| row["part"] == "question" }["reason"]
    end
  end

  test "an open clarification stays accepted after another part is settled" do
    with_flags do
      session = boot_session
      episode = publish(session, MAIN, shown: CLARIFICATION)
      answer(session, "No sé si la válvula 4 está abierta.", [
        reply_for(episode, part_id(episode, "main"), "unknown")
      ])
      stored = reload_episode(session)
      facts = Rag::CompanionCaseFacts.build(stored, session: session)
      checked = check_again(session, CLARIFICATION)

      assert_equal [ MAIN ], facts.settled_part_texts
      assert_nil Rag::AnswerContract.part_state(stored, part_id(stored, "clarification"))
      assert_equal CLARIFICATION, checked.question
      assert checked.rejections.none? { |row| row["reason"] == "part_settled" }
    end
  end

  test "normalized equality does not reject a paraphrase of a settled part" do
    with_flags do
      session = boot_session
      episode = publish(session, MAIN, shown: CLARIFICATION)
      answer(session, "No sé si la válvula 4 está abierta.", [
        reply_for(episode, part_id(episode, "main"), "unknown")
      ])
      # Limitation: this guard is normalized equality. It does not decide that
      # a paraphrase is the same publication, so it does not reject this one.
      paraphrase = "¿Sigue abierta la válvula 4 en este momento?"
      facts = Rag::CompanionCaseFacts.build(reload_episode(session), session: session)
      checked = check_again(session, paraphrase)

      assert_includes facts.settled_part_texts, MAIN
      assert_equal paraphrase, checked.question
      assert checked.rejections.none? { |row| row["reason"] == "part_settled" }
    end
  end

  test "a valid reference to a settled part still rejects that part" do
    with_flags do
      session = boot_session
      episode = publish(session, MAIN, shown: CLARIFICATION)
      answer(session, "No sé si la válvula 4 está abierta.", [
        reply_for(episode, part_id(episode, "main"), "unknown")
      ])
      stored = reload_episode(session)
      paraphrase = "¿Sigue abierta la válvula 4 en este momento?"
      assert_not_equal Rag::CompanionPlanCheck.normal(paraphrase), Rag::CompanionPlanCheck.normal(MAIN)
      checked = check_again(session, paraphrase, part_ref: part_id(stored, "main"))
      rejection = checked.rejections.find { |row| row["part"] == "question" }

      assert_nil checked.question
      assert_equal "part_settled", rejection["reason"]
      assert_equal paraphrase, rejection["value"]
      assert_equal "unknown", Rag::AnswerContract.part_state(stored, part_id(stored, "main"))
    end
  end

  test "closed wording stays part_settled with any reference" do
    with_flags do
      session = boot_session
      episode = publish(session, MAIN, shown: CLARIFICATION)
      answer(session, "No sé si la válvula 4 está abierta.", [
        reply_for(episode, part_id(episode, "main"), "unknown")
      ])
      stored = reload_episode(session)

      assert_equal "q1", stored.pending_question["id"]
      assert_equal "unknown", Rag::AnswerContract.part_state(stored, part_id(stored, "main"))
      assert_nil Rag::AnswerContract.part_state(stored, part_id(stored, "clarification"))
      assert_not_includes stored.pending_question["parts"].pluck("id"), "p9"

      [
        check_again(session, MAIN),
        check_again(session, MAIN, part_ref: part_id(stored, "clarification")),
        check_again(session, MAIN, part_ref: "principal"),
        check_again(session, MAIN, part_ref: " "),
        check_again(session, MAIN, part_ref: "null"),
        check_again(session, MAIN, part_ref: "p9"),
        check_again(session, MAIN, question_ref: "q1")
      ].each do |checked|
        assert_nil checked.question
        rejection = checked.rejections.find { |row| row["part"] == "question" }
        assert_equal "part_settled", rejection["reason"]
        assert_equal MAIN, rejection["value"]
      end
    end
  end

  test "an invalid association keeps the turn and the pending" do
    with_flags do
      session = boot_session
      episode = publish(session, MAIN)
      text = "No sé cuál es el dato pedido ahora."
      2.times do
        answer(session, text, [ {
          "question_id" => episode.pending_question["id"],
          "part_id" => "p999",
          "state" => "unknown"
        } ])
      end
      stored = reload_episode(session)
      history = session.reload.conversation_history.select { |message| message["role"] == "user" && message["content"] == text }

      assert_equal MAIN, stored.pending_question["question"]
      assert_empty stored.replies
      assert_equal 0, stored.id_seq["r"]
      assert_equal 2, history.size
      assert_nil Rag::AnswerContract.part_state(stored, part_id(stored, "main"))
    end
  end

  test "an invalid association does not clear a referent clarification" do
    with_flags do
      session = boot_session
      episode = reload_episode(session)
      episode.pending_question = { "type" => "referent" }
      session.update!(active_episode: episode.to_h)
      session.record_user_turn!(
        "No sé a cuál de los dos me refiero.",
        user_id: @user.id, correlation_id: "query:referent-#{SecureRandom.hex(2)}",
        interpreter_client: tool_client(
          "unclear", [],
          target: "referent",
          part_replies: [ { "question_id" => "q9", "part_id" => "p999", "state" => "unknown" } ]
        )
      )
      stored = reload_episode(session)

      assert_equal "referent", stored.pending_question["type"]
      assert_empty stored.replies
    end
  end

  test "a contradiction keeps both versions and a correction keeps the history" do
    with_flags do
      session = boot_session
      episode = publish(session, MAIN)
      pid = part_id(episode, "main")
      first = "La válvula queda abierta."
      second = "La válvula queda cerrada."
      third = "Corrijo: queda abierta de nuevo."
      answer(session, first, [ reply_for(episode, pid, "complete") ])
      answer(session, second, [ reply_for(episode, pid, "contradictory") ])
      answer(session, third, [ reply_for(episode, pid, "complete", supersedes: [ "r1", "r2" ]) ])
      stored = reload_episode(session)
      lines = Rag::AnswerContract.context_lines(stored, session.reload)

      assert_equal %w[r1 r2 r3], stored.replies.pluck("id")
      assert_equal 3, stored.id_seq["r"]
      assert_equal "complete", Rag::AnswerContract.part_state(stored, pid)
      assert_includes lines.join("\n"), first
      assert_includes lines.join("\n"), second
      assert_includes lines.join("\n"), third
      assert_equal [ "r3" ], Rag::AnswerContract.current_replies(stored, pid).pluck("id")
    end
  end

  test "a settled part stays available for correction and an invalid supersedes is ignored" do
    with_flags do
      session = boot_session
      episode = publish(session, MAIN)
      pid = part_id(episode, "main")
      first = "La válvula queda abierta."
      answer(session, first, [ reply_for(episode, pid, "complete") ])
      settled = reload_episode(session)
      payload = pending_payload(settled, session)
      prepared = Rag::CompanionPlan.prepare(
        raw_question: "¿Qué sigue?", chunks: [ chunk ], episode: settled, session: session, correlation_id: "query:correct"
      )

      assert_nil payload["question"]
      assert_equal [ "r1" ], payload["corrections"].pluck("id")
      assert_includes prepared.user, first
      assert_includes prepared.user, "r1"
      assert_not Rag::AnswerContract.open_part?(settled, settled.pending_question, settled.pending_question["parts"].first)

      answer(session, "Corrijo: queda cerrada.", [ reply_for(settled, pid, "complete", supersedes: [ "r1" ]) ])
      corrected = reload_episode(session)
      assert_equal [ "r2" ], Rag::AnswerContract.current_replies(corrected, pid).pluck("id")
      assert_includes corrected.replies.pluck("id"), "r1"
      assert_includes Rag::AnswerContract.context_lines(corrected, session.reload).join("\n"), first

      before = corrected.replies.map(&:dup)
      answer(session, "Otra corrección que no cita la vigente.", [
        reply_for(corrected, pid, "complete", supersedes: [ "r9" ])
      ])
      kept = reload_episode(session)

      assert_equal "invalid_supersedes", session.last_answer_report["refused"].first["reason"]
      assert_empty session.last_answer_report["stored"]
      assert_equal before.pluck("id"), kept.replies.pluck("id")
      assert_equal [ "r2" ], Rag::AnswerContract.current_replies(kept, pid).pluck("id")
    end
  end

  test "a contradiction reaches the planner as two versions and not as a resolved fact" do
    with_flags do
      session = boot_session
      episode = publish(session, MAIN)
      pid = part_id(episode, "main")
      first = "La válvula queda abierta."
      second = "La válvula queda cerrada."
      answer(session, first, [ reply_for(episode, pid, "complete") ])
      answer(session, second, [ reply_for(episode, pid, "contradictory") ])
      stored = reload_episode(session)
      lines = Rag::AnswerContract.context_lines(stored, session).join("\n")
      prepared = Rag::CompanionPlan.prepare(
        raw_question: "¿Qué sigue?", chunks: [ chunk ], episode: stored, session: session, correlation_id: "query:conflict"
      )
      payload = pending_payload(stored, session)

      assert_includes lines, first
      assert_includes lines, second
      assert_includes lines, "en conflicto"
      assert_includes lines, "Ninguna queda elegida como hecho resuelto."
      assert_includes prepared.user, first
      assert_includes prepared.user, second
      assert_includes prepared.user, "Ninguna queda elegida como hecho resuelto."
      assert_equal [ "r1", "r2" ], payload["conflicts"].first["reply_ids"]
      assert_includes payload["question"], "válvula"
    end
  end

  test "legacy answers still bind and a contract episode does not bind by stems" do
    with_flags do
      legacy_session = boot_legacy
      publish(legacy_session, MAIN)
      answer(legacy_session, "No sé")
      legacy = reload_episode(legacy_session)
      report = legacy_session.last_answer_report

      assert_nil legacy.qc
      assert_not legacy_session.reload.active_episode.key?("qc")
      assert_equal "legacy", report["route"]
      assert_equal "absent", report["field"]
      assert_empty report["stored"]
      assert legacy.observations.any? { |item| item.dig("answers", "r") == "unknown" }

      session = boot_session
      episode = publish(session, MAIN)
      unknown_before = reload_episode(session).observations.count { |item| item.dig("answers", "r") == "unknown" }
      answer(session, "No sé")
      contract = reload_episode(session)
      refused = session.last_answer_report

      assert_equal 1, episode.qc
      assert_equal "contract", refused["route"]
      assert_equal "absent", refused["field"]
      assert_empty refused["stored"]
      assert_empty contract.replies
      assert_equal unknown_before, contract.observations.count { |item| item.dig("answers", "r") == "unknown" }
      assert_equal MAIN, contract.pending_question["question"]
    end
  end

  test "an empty list and an invalid list do not invent an association" do
    with_flags do
      session = boot_session
      episode = publish(session, MAIN)
      answer(session, "No sé", [])
      empty = session.last_answer_report
      stored = reload_episode(session)

      assert_equal "empty", empty["field"]
      assert_equal "contract", empty["route"]
      assert_empty empty["stored"]
      assert_empty stored.replies
      assert_equal MAIN, stored.pending_question["question"]

      answer(session, "No sé", "no es una lista")
      invalid = session.last_answer_report
      kept = reload_episode(session)

      assert_equal "invalid", invalid["field"]
      assert_empty invalid["stored"]
      assert_empty kept.replies
      assert kept.observations.none? { |item| item.dig("answers", "r") == "unknown" }
      assert_equal MAIN, kept.pending_question["question"]
    end
  end

  test "publishing a question leaves a legacy episode on the legacy reading" do
    with_flags do
      session = boot_legacy
      publish(session, "¿Está el piloto encendido?")
      answer(session, "No sé", [ {
        "question_id" => "q1", "part_id" => "p1", "state" => "unknown"
      } ])
      interpreted = reload_episode(session)

      assert_equal "legacy", session.last_answer_report["route"]
      assert_equal "not_contract", session.last_answer_report["refused"].first["reason"]
      assert_empty interpreted.replies
      assert_nil interpreted.qc
      assert interpreted.observations.any? { |item| item.dig("answers", "r") == "unknown" }

      publish(session, MAIN)
      published = reload_episode(session)
      assert_nil published.qc
      assert_nil published.pending_question["id"]
      assert_nil published.pending_question["parts"]
      answer(session, "No sé")
      followed = reload_episode(session)
      bound = followed.observations.find { |item| item.dig("answers", "r") == "unknown" }

      assert_equal "legacy", session.last_answer_report["route"]
      assert_equal "absent", session.last_answer_report["field"]
      assert_empty followed.replies
      assert_nil followed.qc
      assert_equal MAIN, bound.dig("answers", "q")
    end
  end

  test "a valid contract reply does not also close the part by stems" do
    with_flags do
      session = boot_session
      episode = publish(session, MAIN)
      answer(session, "No sé", [ reply_for(episode, part_id(episode, "main"), "unknown") ])
      stored = reload_episode(session)

      assert_equal [ "r1" ], session.last_answer_report["stored"]
      assert_equal "unknown", Rag::AnswerContract.part_state(stored, part_id(stored, "main"))
      assert stored.observations.none? { |item| item.dig("answers", "r") == "unknown" }
      assert_equal MAIN, stored.pending_question["question"]
    end
  end

  test "a source that left the history is not reused as a reconstructed answer" do
    with_flags do
      session = boot_session
      episode = publish(session, MAIN)
      clause = "La válvula 4 está abierta del todo."
      answer(session, clause, [ reply_for(episode, part_id(episode, "main"), "complete") ])
      stored = reload_episode(session)
      assert_includes Rag::AnswerContract.reconstruct(stored.replies.last, session), clause

      session.update!(conversation_history: Array.new(ConversationSession::MAX_HISTORY) { |index|
        {
          "role" => "user",
          "content" => "relleno #{index}",
          "correlation_id" => "query:fill-#{index}",
          "ts" => Time.current.iso8601
        }
      })
      lines = Rag::AnswerContract.context_lines(stored, session.reload)
      missing = lines.find { |line| line.include?("r1") }

      assert_nil Rag::AnswerContract.reconstruct(stored.replies.last, session)
      assert_includes missing, "no se reconstruyó"
      assert_includes missing, "no se usa como respuesta reconstruida"
      assert_not_includes missing, "complete"
      assert_not_includes missing, clause
      assert_equal "complete", Rag::AnswerContract.part_state(stored, part_id(stored, "main"))
    end
  end

  test "a persisted reply omitted from the case budget is not treated as present in that context" do
    with_flags do
      session = boot_session
      episode = publish(session, MAIN)
      marker = "COLA_PRESUPUESTO"
      body = ("dato " * 800) + marker
      assert_operator body.length, :>, SessionContextBuilder::COMPANION_CASE_BUDGET
      answer(session, body, [ reply_for(episode, part_id(episode, "main"), "partial") ])
      stored = reload_episode(session)
      context = SessionContextBuilder.companion_context(session, episode: stored)

      assert_equal [ "r1" ], stored.replies.pluck("id")
      assert_includes Rag::AnswerContract.reconstruct(stored.replies.last, session), marker
      assert_not_includes context, marker
      assert_not_includes context, "q1.p1 partial"
    end
  end

  test "synthetic contract replies stay under the episode budget" do
    with_flags do
      session = boot_session
      episode = publish(session, MAIN, shown: CLARIFICATION)
      main_id = part_id(episode, "main")
      clarification_id = part_id(episode, "clarification")
      sizes = {}
      sizes["published"] = persisted_bytes(session)
      answer(session, "La válvula abre.", [ reply_for(episode, main_id, "partial", "La válvula abre.", "abre") ])
      sizes["partial"] = persisted_bytes(session)
      answer(session, "El indicador es el de marcha.", [
        reply_for(episode, clarification_id, "complete", "El indicador es el de marcha.", "marcha")
      ])
      sizes["clarification"] = persisted_bytes(session)
      answer(session, "La válvula queda abierta.", [ reply_for(episode, main_id, "complete", supersedes: [ "r1" ]) ])
      sizes["correction"] = persisted_bytes(session)
      answer(session, "La válvula queda cerrada.", [ reply_for(episode, main_id, "contradictory") ])
      sizes["contradiction"] = persisted_bytes(session)
      assert sizes.values.all? { |bytes| bytes <= Rag::ActiveEpisode::MAX_BYTES }, sizes.inspect
      assert_operator sizes["contradiction"], :>, sizes["published"]
      stored = reload_episode(session)
      assert_equal "contradictory", Rag::AnswerContract.part_state(stored, main_id)
      assert_equal "complete", Rag::AnswerContract.part_state(stored, clarification_id)
    end
  end

  test "a reply that does not fit is refused without dropping stored text" do
    with_flags do
      session = boot_session
      episode = publish(session, MAIN)
      pid = part_id(episode, "main")
      12.times do |index|
        episode.append_observation!(
          format("Falla %02d ", index) + ("m#{index}" * 40),
          correlation_id: "pad-o-#{index}"
        )
      end
      6.times do |index|
        episode.upsert_check!(
          {
            "subject" => format("Comprobar punto %02d ", index) + ("s#{index}" * 20),
            "status" => "done",
            "result" => format("resultado %02d ", index) + ("r#{index}" * 16)
          },
          correlation_id: "pad-c-#{index}"
        )
      end
      session.update!(active_episode: episode.to_h)
      padded = reload_episode(session)
      observation_count = padded.observations.size
      kept_text = nil
      refused = nil
      12.times do |index|
        text = "Respuesta parcial #{index} del tecnico sobre la valvula."
        before = reload_episode(session).replies.size
        answer(session, text, [ reply_for(padded, pid, "partial") ])
        after = reload_episode(session)
        if after.replies.size == before
          refused = text
          assert_equal "budget", session.last_answer_report["refused"].first["reason"]
          assert_empty session.last_answer_report["stored"]
          break
        end
        kept_text = text
      end
      stored = reload_episode(session)
      lines = Rag::AnswerContract.context_lines(stored, session.reload).join("\n")

      assert kept_text, "bytes=#{JSON.generate(stored.serial_hash).bytesize}"
      assert refused, "bytes=#{JSON.generate(stored.serial_hash).bytesize}"
      assert_equal observation_count, stored.observations.size
      assert_includes session.conversation_history.map { |message| message["full_content"].presence || message["content"] }, refused
      assert_includes lines, kept_text
      persisted = JSON.generate(session.active_episode)
      assert_operator persisted.bytesize, :<=, Rag::ActiveEpisode::MAX_BYTES
    end
  end

  test "a turn past the history preview reconstructs from the stored text" do
    with_flags do
      session = boot_session
      episode = publish(session, MAIN)
      body = ("A" * 650) + "COLA_LARGA"
      start, finish = span_for(body, "COLA_LARGA")
      client = tool_client("report", [], part_replies: [
        reply_for(episode, part_id(episode, "main"), "partial", body, "COLA_LARGA")
      ])
      session.record_user_turn!(
        body, user_id: @user.id, correlation_id: "query:long-#{SecureRandom.hex(2)}",
        interpreter_client: client
      )
      stored = reload_episode(session)
      message = session.conversation_history.find { |item| item["role"] == "user" && item["full_content"] == body }
      reply = stored.replies.last
      sent = JSON.parse(client.payloads.first[:messages].first[:content].first[:text])

      assert message
      assert_operator body.length, :>, ConversationSession::MAX_MSG_LENGTH
      assert_operator body.length, :<, ConversationSession::USER_TEXT_MAX_CHARS
      assert_equal body, sent["turn"]
      assert_equal "COLA_LARGA", sent["turn"][start...finish]
      assert_not_equal "COLA_LARGA", sent["turn"][0...10]
      assert_not_includes message["content"], "COLA_LARGA"
      assert_equal "COLA_LARGA", Rag::AnswerContract.reconstruct(reply, session)
      assert_equal start, reply["a"]
      assert_equal finish, reply["b"]
    end
  end

  test "a synthetic first opening answer is in the next plan context" do
    with_flags do
      session = boot_session(T1, "la puerta abrió muy despacio")
      episode = publish(session, SLOW)
      answer(session, T2, [ reply_for(episode, part_id(episode, "main"), "complete") ])
      stored = reload_episode(session)
      prepared = Rag::CompanionPlan.prepare(
        raw_question: "¿Qué sigue?", chunks: [ chunk ], episode: stored, session: session.reload, correlation_id: "query:next"
      )
      context = SessionContextBuilder.companion_context(session, episode: stored)

      assert_equal "complete", Rag::AnswerContract.part_state(stored, part_id(stored, "main"))
      assert_includes prepared.user, "Fue solo la primera apertura"
      assert_includes prepared.user, "q1.p1 complete"
      assert_includes context, "Fue solo la primera apertura"
      assert_includes context, T2
    end
  end

  test "a question removed before publication is not stored" do
    pending = {
      "type" => "documented_context",
      "question" => MAIN,
      "targets" => [ target("Válvula.") ]
    }

    assert_nil Rag::PendingQuestion.presented(pending, "La bomba no arranca.")
  end

  test "the version is chosen when the episode opens and a later turn cannot change it" do
    with_flags do
      session = ConversationSession.create!(
        identifier: "web:contract-#{SecureRandom.hex(3)}",
        channel: "web",
        expires_at: 1.hour.from_now,
        user: @user,
        account: @account,
        active_episode: {},
        conversation_history: []
      )
      client = tool_client("report", [ "El conjunto no responde." ])
      events = Rag::ValidationCapture.capture do
        session.record_user_turn!(
          "El conjunto no responde.",
          user_id: @user.id,
          correlation_id: "query:select-#{SecureRandom.hex(2)}",
          interpreter_client: client,
          answer_contract: Rag::AnswerContract::VERSION
        )
      end
      selected = events.find { |event| event["kind"] == "answer_contract" }
      request = events.find { |event| event["kind"] == "interpreter_request" }
      stored = session.reload.active_episode

      assert_equal "prepare", selected["stage"]
      assert_equal "contract", selected["result"]
      assert_equal 1, selected["qc"]
      assert_equal stored["episode_id"], selected["episode_id"]
      assert_operator selected["sequence"], :<, request["sequence"]
      assert_nil client.input["qc"]
      assert_equal 1, stored["qc"]
      assert_equal({ "q" => 0, "p" => 0, "r" => 0 }, stored["id_seq"])

      session.record_user_turn!(
        "Sigue igual.",
        user_id: @user.id,
        correlation_id: "query:keep-#{SecureRandom.hex(2)}",
        interpreter_client: tool_client("report", []),
        answer_contract: nil
      )

      assert_equal 1, session.reload.active_episode["qc"]
    end
  end

  test "an existing legacy episode stays legacy when a later turn asks for the new contract" do
    with_flags do
      session = boot_legacy
      events = Rag::ValidationCapture.capture do
        session.record_user_turn!(
          "Sigue igual.",
          user_id: @user.id,
          correlation_id: "query:stay-#{SecureRandom.hex(2)}",
          interpreter_client: tool_client("report", []),
          answer_contract: Rag::AnswerContract::VERSION
        )
      end
      stored = session.reload.active_episode

      assert_nil events.find { |event| event["kind"] == "answer_contract" }
      assert_not stored.key?("qc")
      assert_not stored.key?("id_seq")
      assert_not stored.key?("replies")
    end
  end

  test "opening without a selector records the legacy reading before the interpreter" do
    with_flags do
      session = ConversationSession.create!(
        identifier: "web:legacy-#{SecureRandom.hex(3)}",
        channel: "web",
        expires_at: 1.hour.from_now,
        user: @user,
        account: @account,
        active_episode: {},
        conversation_history: []
      )
      events = Rag::ValidationCapture.capture do
        session.record_user_turn!(
          "El conjunto no responde.",
          user_id: @user.id,
          correlation_id: "query:legacy-open-#{SecureRandom.hex(2)}",
          interpreter_client: tool_client("report", [ "El conjunto no responde." ])
        )
      end
      selected = events.find { |event| event["kind"] == "answer_contract" }
      request = events.find { |event| event["kind"] == "interpreter_request" }
      stored = session.reload.active_episode

      assert_equal "legacy", selected["result"]
      assert_nil selected["qc"]
      assert_equal "prepare", selected["stage"]
      assert_operator selected["sequence"], :<, request["sequence"]
      assert_not stored.key?("qc")
      assert_equal selected["episode_id"], stored["episode_id"]
    end
  end

  test "legacy answers keep their labels and an unmarked episode has no contract" do
    episode = Rag::ActiveEpisode.open(correlation_id: "synthetic", now: Time.current)
    target = target("Piloto.")
    episode.append_observation!(
      "El técnico no lo distinguió.",
      correlation_id: "c1",
      answers: { "q" => "¿Está el piloto?", "t" => [ target ], "r" => "unknown", "contract" => "ref" }
    )
    episode.append_observation!(
      "El piloto está encendido.",
      correlation_id: "c2",
      answers: { "q" => "¿Está el piloto?", "t" => [ target ], "r" => "yes" }
    )
    episode.append_observation!(
      "No consta el estado.",
      correlation_id: "c3",
      answers: { "q" => "¿Está el piloto?", "t" => [ target ], "r" => "unknown" }
    )
    block = Rag::CompanionCaseFacts.build(episode).prompt_block
    stored = episode.to_h

    assert_includes block, "«El técnico no lo distinguió»"
    assert_includes block, "«sí»"
    assert_includes block, "«no sé»"
    assert_not stored.key?("qc")
    assert_not stored.key?("replies")
    selected = Rag::ActiveEpisode.open(
      correlation_id: "synthetic", now: Time.current, contract: Rag::AnswerContract::VERSION
    )
    assert_equal 1, selected.to_h["qc"]
  end

  private

  def with_flags
    previous_mode = ENV["HAIKU_QUERY_ANALYSIS_MODE"]
    previous_episode = ENV["FIELD_COMPANION_EPISODE_ENABLED"]
    ENV["HAIKU_QUERY_ANALYSIS_MODE"] = "owner"
    ENV["FIELD_COMPANION_EPISODE_ENABLED"] = "true"
    assert_no_enqueued_jobs only: TrackBedrockQueryJob do
      yield
    end
  ensure
    ENV["HAIKU_QUERY_ANALYSIS_MODE"] = previous_mode
    ENV["FIELD_COMPANION_EPISODE_ENABLED"] = previous_episode
  end

  # The new contract is selected only on the call that opens the episode.
  def boot_session(text = "El conjunto no responde.", observation = text)
    start_session(text, observation, answer_contract: Rag::AnswerContract::VERSION)
  end

  def boot_legacy(text = "El conjunto no responde.", observation = text)
    start_session(text, observation)
  end

  def start_session(text, observation, answer_contract: nil)
    session = ConversationSession.create!(
      identifier: "web:contract-#{SecureRandom.hex(3)}",
      channel: "web",
      expires_at: 1.hour.from_now,
      user: @user,
      account: @account,
      active_episode: {},
      conversation_history: []
    )
    options = {
      user_id: @user.id,
      correlation_id: "query:boot-#{SecureRandom.hex(2)}",
      interpreter_client: tool_client("report", [ observation ])
    }
    options[:answer_contract] = answer_contract if answer_contract
    session.record_user_turn!(text, **options)
    session
  end

  def publish(session, question, shown: nil)
    episode = reload_episode(session)
    payload = {
      "type" => "documented_context",
      "question" => question,
      "targets" => [ target("Primera apertura.") ]
    }
    if shown
      payload["shown"] = { "question" => shown, "targets" => [ target("Aclaración.") ] }
    end
    session.record_assistant_turn!(
      [ question, shown ].compact.join(" "),
      user_id: @user.id, correlation_id: "query:pub-#{SecureRandom.hex(2)}",
      pending_question: payload, expected_episode_id: episode.episode_id
    )
    reload_episode(session)
  end

  def answer(session, text, replies = :omit)
    session.record_user_turn!(
      text, user_id: @user.id, correlation_id: "query:ans-#{SecureRandom.hex(2)}",
      interpreter_client: tool_client("report", [], part_replies: replies)
    )
  end

  def persisted_bytes(session)
    JSON.generate(session.reload.active_episode).bytesize
  end

  def reply_for(episode, part, state, text = nil, clause = nil, supersedes: nil)
    row = {
      "question_id" => episode.pending_question["id"],
      "part_id" => part,
      "state" => state
    }
    if text && clause
      start, finish = span_for(text, clause)
      row["start"] = start
      row["end"] = finish
    end
    row["supersedes"] = supersedes if supersedes
    row
  end

  def span_for(text, clause)
    start = text.index(clause)
    flunk("missing clause #{clause.inspect}") if start.nil?

    [ start, start + clause.length ]
  end

  def part_id(episode, role)
    episode.pending_question["parts"].find { |part| part["role"] == role }["id"]
  end

  def reload_episode(session)
    Rag::ActiveEpisode.parse(session.reload.active_episode)
  end

  def pending_payload(episode, session = nil)
    interpreter = Rag::TurnInterpreter.allocate
    interpreter.instance_variable_set(:@episode, episode)
    interpreter.instance_variable_set(:@session, session)
    interpreter.send(:pending_payload)
  end

  def target(item)
    {
      "item" => item,
      "document_key" => "s3://synthetic/contract.txt",
      "filename" => "contract.txt",
      "page" => "8"
    }
  end

  def chunk
    {
      content: "• Primera apertura.\nLas puertas se abren despacio en la primera operación.\n– Comprobar si la válvula 4 está abierta.\n",
      metadata: {
        "page_number" => "8",
        "original_source_uri" => "s3://synthetic/contract.txt",
        "filename" => "contract.txt"
      },
      identity_applicability: "compatible"
    }
  end

  # The clarification's own words have to be in the source. Otherwise the
  # existing lexical gate rejects that open part before this guard is visible.
  def check_again(session, question, part_ref: nil, question_ref: nil)
    stored = reload_episode(session)
    source = chunk
    wording = CLARIFICATION.delete_prefix("¿").delete_suffix("?")
    source = source.merge(content: "#{source[:content]}#{wording}.\n")
    facts = Rag::CompanionCaseFacts.build(stored, session: session)
    prepared = Rag::CompanionPlan.prepare(
      raw_question: question, chunks: [ source ], episode: stored, session: session,
      correlation_id: "query:again-#{SecureRandom.hex(2)}"
    )
    plan = { "links" => [], "steps" => [], "question" => question, "question_about" => [] }
    plan["part_ref"] = part_ref if part_ref
    plan["question_ref"] = question_ref if question_ref
    Rag::CompanionPlanCheck.call(plan, facts: facts, statements: prepared.statements, turns: [])
  end

  def plan_result(question)
    Rag::CompanionPlanCheck::Result.new(
      links: [], steps: [], question: question, rejections: [], associations: [],
      confirmed_items: {}, question_targets: [], limits: [], omissions: [],
      question_scope: nil, question_role: nil
    )
  end

  def tool_client(move, observations, part_replies: :omit, target: nil)
    input = {
      "move" => move,
      "assertions" => [],
      "observations" => observations,
      "pending_resolution" => nil,
      "clarification_target" => target
    }
    input["part_replies"] = part_replies unless part_replies == :omit
    payloads = []
    client = Struct.new(:input, :payloads).new(input, payloads)
    client.define_singleton_method(:converse) do |params|
      payloads << params
      tool = Struct.new(:name, :input).new(Rag::TurnInterpreter::TOOL_NAME, input)
      block = Struct.new(:tool_use).new(tool)
      message = Struct.new(:content).new([ block ])
      output = Struct.new(:message).new(message)
      usage = Struct.new(:input_tokens, :output_tokens).new(0, 0)
      Struct.new(:output, :usage).new(output, usage)
    end
    client
  end
end
