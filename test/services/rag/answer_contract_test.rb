# frozen_string_literal: true

require "test_helper"

# Synthetic contract objects. These turns are not captured model output.
# A stored reply is a reference into history. Ruby checks the reference.
# It does not decide that two new questions mean the same thing.
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
      assert_nil pending_payload(kept)
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
      answer(session, body, [ reply_for(episode, part_id(episode, "main"), "partial", body, "COLA_LARGA") ])
      stored = reload_episode(session)
      message = session.reload.conversation_history.find { |item| item["role"] == "user" && item["full_content"] == body }
      reply = stored.replies.last

      assert message
      assert_operator body.length, :>, ConversationSession::MAX_MSG_LENGTH
      assert_operator body.length, :<, ConversationSession::USER_TEXT_MAX_CHARS
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

  def boot_session(text = "El conjunto no responde.", observation = text)
    session = ConversationSession.create!(
      identifier: "web:contract-#{SecureRandom.hex(3)}",
      channel: "web",
      expires_at: 1.hour.from_now,
      user: @user,
      account: @account,
      active_episode: {},
      conversation_history: []
    )
    session.record_user_turn!(
      text, user_id: @user.id, correlation_id: "query:boot-#{SecureRandom.hex(2)}",
      interpreter_client: tool_client("report", [ observation ])
    )
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

  def answer(session, text, replies)
    session.record_user_turn!(
      text, user_id: @user.id, correlation_id: "query:ans-#{SecureRandom.hex(2)}",
      interpreter_client: tool_client("report", [], part_replies: replies)
    )
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

  def pending_payload(episode)
    interpreter = Rag::TurnInterpreter.allocate
    interpreter.instance_variable_set(:@episode, episode)
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

  def plan_result(question)
    Rag::CompanionPlanCheck::Result.new(
      links: [], steps: [], question: question, rejections: [], associations: [],
      confirmed_items: {}, question_targets: [], limits: [], omissions: [],
      question_scope: nil, question_role: nil
    )
  end

  def tool_client(move, observations, part_replies: nil, target: nil)
    input = {
      "move" => move,
      "assertions" => [],
      "observations" => observations,
      "pending_resolution" => nil,
      "clarification_target" => target
    }
    input["part_replies"] = part_replies if part_replies
    Struct.new(:input) do
      def converse(_params)
        tool = Struct.new(:name, :input).new(Rag::TurnInterpreter::TOOL_NAME, input)
        block = Struct.new(:tool_use).new(tool)
        message = Struct.new(:content).new([ block ])
        output = Struct.new(:message).new(message)
        usage = Struct.new(:input_tokens, :output_tokens).new(0, 0)
        Struct.new(:output, :usage).new(output, usage)
      end
    end.new(input)
  end
end
