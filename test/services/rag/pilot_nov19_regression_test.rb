# frozen_string_literal: true

require "test_helper"
require_relative "../../support/field_case_history_helper"
require_relative "../../support/pilot_nov19_rubric"

class Rag::PilotNov19RegressionTest < ActiveSupport::TestCase
  include FieldCaseHistoryHelper
  include PilotNov19Rubric

  CASES = JSON.parse(Rails.root.join("test/fixtures/files/field_companion/pilot_2026_11_19.json").read).fetch("cases")

  test "Err14 preserves a Celsius measurement and every accepted manual quote across publication" do
    turns = CASES.fetch("25").fetch("turns")
    capture = turns.last.fetch("capture")
    source = capture.fetch("source").fetch("text")

    assert_equal [ { "rule" => "R5", "detail" => "quote_removed" } ], capture.fetch("reasons")
    assert_no_match(/temperatura ambiental es demasiado alta/i, capture.fetch("after_guard"))

    [ turns[1].fetch("message"), turns[1].fetch("message").sub("26 grados centígrados", "26 °C") ].each do |reading|
      turns.drop(1).each do |turn|
        draft = turn.dig("capture", "draft")
        publication = Rag::CompanionTurnPublication.call(
          text: draft, sources: [ { "content" => source } ], stop_reason: "end_turn"
        )
        assert publication.accepted?, publication.reasons.inspect
        guarded = Rag::SourceFidelityGuard.call(answer: draft, evidence_texts: [ source ],
          allowed_texts: [ reading, turn.fetch("message") ], locale: :es)
        assert_nil Rag::CompanionTurnPublication.after_guards(guarded[:answer], publication)
        assert_equal 0, guarded[:removed], draft
        assert PilotNov19Rubric.claim?(guarded[:answer], TEMPERATURE), guarded[:answer]
      end
    end
    assert PilotNov19Rubric.claim?(capture.fetch("draft"), FAN, ROTATION, /[?¿]/)
    assert PilotNov19Rubric.claim?(capture.fetch("draft"), TEMPERATURE, DOC_LIMIT, UNDOCUMENTED)
  end

  test "a different Celsius reading still needs evidence" do
    source = at(25, 4).dig("capture", "source", "text")
    reply = Rag::SourceFidelityGuard.call(answer: "Hay 26 °C junto al gabinete.", evidence_texts: [ source ],
      allowed_texts: [ "Medí 29 grados centígrados junto al gabinete." ], locale: :es)
    assert_equal 1, reply[:removed]
    assert_not_includes reply[:answer], "26 °C"
  end

  test "Err14 keeps the literal reading and dust after reduction and reload" do
    turn = at(25, 2)
    saved, = reduce_and_reload(turn)

    reading = saved.observations.find { |row| row["text"].match?(/26 grados centígrados/i) }
    assert reading, saved.observations.inspect
    assert_equal turn.fetch("correlation_id"), reading.fetch("correlation_id")
    assert Rag::TurnPerception.literal_fragment?(reading.fetch("text"), turn.fetch("message"))
    assert saved.observations.any? { |row| row["text"].match?(/polvo/i) }
  end

  test "Elemont binds a short answer to the last stop actually asked about" do
    turn = at(24, 9)
    saved, = reduce_and_reload(turn)

    reply = Rag::AnswerContract.current_replies(saved, "p8").sole
    assert_equal "q8", reply.fetch("q")
    assert_equal "complete", reply.fetch("state")
    assert_equal "Desenclavada", turn.fetch("message")[reply.fetch("a")...reply.fetch("b")]
    assert_equal turn.fetch("correlation_id"), reply.fetch("cid")
    assert_not saved.replies.any? { |row| row["p"] != "p8" && row["cid"] == reply["cid"] }
  end

  test "Thyssen keeps the new functional check at the captured episode size" do
    turn = at(28, 11)
    captured_state = turn.fetch("before").merge(turn.fetch("observed_state"))
    previous = Rag::ActiveEpisode.parse(captured_state, now: Time.iso8601(turn.fetch("at")))
    question = Rag::PendingQuestion.followup_line(turn.fetch("published"), locale: :es)

    outcome = Rag::ActiveEpisodeTurn.apply_assistant(state: previous, text: turn.fetch("published"),
      now: Time.iso8601(turn.fetch("at")), correlation_id: turn.fetch("correlation_id"),
      pending_question: { "type" => "documented_context", "question" => question, "targets" => [ { "item" => question } ] })
    assert_equal question, outcome.state.dig("pending_question", "question"), outcome.reason
    assert_operator JSON.generate(outcome.state).bytesize, :<=, Rag::ActiveEpisode::MAX_BYTES

    last = at(28, 12).deep_dup
    pending = outcome.state.fetch("pending_question")
    part_id = pending.fetch("parts").sole.fetch("id")
    # The actual tool answered the stale q8. Here the double points at the
    # new question and cites the whole message that answers its three facts.
    last["tool"]["part_replies"] = [
      { "question_id" => pending.fetch("id"), "part_id" => part_id, "state" => "complete", "quote" => last.fetch("message") }
    ]
    last["before"] = outcome.state
    saved, = reduce_and_reload(last)
    assert_equal "complete", Rag::AnswerContract.part_state(saved, part_id)
    assert_empty Rag::AnswerContract.open_parts(saved)
    assert_nil Rag::PendingQuestion.followup_line(close_followup(last.dig("capture", "draft"), saved, last), locale: :es)
  end

  test "Thyssen confirms only the reported maneuver and drops the repeated EA question" do
    turn = at(28, 12)
    saved, = reduce_and_reload(turn)

    assert_equal "complete", Rag::AnswerContract.part_state(saved, "p8")
    assert_empty Rag::AnswerContract.open_parts(saved)
    draft = turn.dig("capture", "draft")
    answer = close_followup(draft, saved, turn)
    assert_nil Rag::PendingQuestion.followup_line(answer, locale: :es)
    field = PilotNov19Rubric.field_text(answer)
    assert PilotNov19Rubric.claim?(field, TEST_SCOPE, DONE, without: NEGATED_OUTCOME), answer
    assert PilotNov19Rubric.claim?(field, STOP_INTERLOCK, ACTED, without: NEGATED_OUTCOME), answer
    assert PilotNov19Rubric.claim?(field, /\bea\b/, ABSENT_FAULT), answer
    assert PilotNov19Rubric.claim?(field, /\bcaus\w*\b/, CAUSE_OPEN), answer
    assert_empty PilotNov19Rubric.language_findings(answer)
    different = "La maniobra quedó confirmada. ¿Apareció una falla nueva al reiniciar?"
    assert_equal different, close_followup(different, saved, turn)
  end

  test "Otis closes DFC and keeps a separate unanswered DCL in the stored case" do
    turn = at(29, 6)
    saved, = reduce_and_reload(turn)

    assert_equal "complete", Rag::AnswerContract.part_state(saved, "p3")
    assert_empty Rag::AnswerContract.open_parts(saved)
    assert saved.checks.any? { |check| check["subject"] == "DCL" && check["status"] == "not_done" }
    answer = close_followup(turn.dig("capture", "draft"), saved, turn)
    assert_nil Rag::PendingQuestion.followup_line(answer, locale: :es)
    field = PilotNov19Rubric.field_text(answer)
    assert PilotNov19Rubric.claim?(field, /\bdfc\b/, ENERGIZED, STAYED, without: NEGATED_OUTCOME), answer
    assert PilotNov19Rubric.claim?(field, /\bdcl\b/, APPLICABILITY_PENDING), answer
    assert PilotNov19Rubric.claim?(field, /\b0102\b/, ABSENT_FAULT, TEST_SCOPE), answer
    assert_empty PilotNov19Rubric.language_findings(answer)
    different = "En esa prueba se completó el cierre. ¿Apareció DW en el historial después?"
    assert_equal different, close_followup(different, saved, turn)
  end

  test "FIELD_CHECK_OUTCOME names the settled Otis check, the unverified DCL and the closed q1 text" do
    turn = at(29, 6)
    saved, = reduce_and_reload(turn)
    session = history_session(29, 6)
    previous = ENV["FIELD_CHECK_OUTCOME"]
    ENV["FIELD_CHECK_OUTCOME"] = "true"
    outcome = Rag::CheckOutcome.new(episode: saved, session: session, correlation_id: turn.fetch("correlation_id"))
    lines = outcome.lines

    assert outcome.settled_this_turn?
    assert_equal [ [ "q3", "p3", "complete" ] ], outcome.active.map { |part| [ part.question_id, part.part_id, part.state ] }
    dcl = outcome.unverified.select { |row| row.text.match?(/\bDCL\b/i) }
    assert_equal [ 3, 5, 6 ], dcl.map(&:turn), lines.inspect
    assert_equal CASES.fetch("29").fetch("turns").values_at(2, 4, 5).pluck("correlation_id"), dcl.map(&:correlation_id)
    assert_not_empty outcome.closed
    q1 = outcome.closed.find { |row| row.question_id == "q1" }
    assert q1&.question.present?, lines.inspect
    # Growth of the block, not a pass for the plan's 3 % criterion. That
    # criterion is measured on the block itself, in the plan's stage 1 note.
    # This only stops the block from growing without bound.
    grown = lines.join("\n").bytesize - Rag::AnswerContract.context_lines(saved, session).join("\n").bytesize
    assert_operator grown, :<, 1_200
    assert lines.none? { |line| line.match?(/\ARespuesta r\d+ a q\d+\.p\d+/) }
    assert_equal outcome.to_trace, Rag::CheckOutcome.new(episode: saved, session: session, correlation_id: turn.fetch("correlation_id")).to_trace
  ensure
    ENV["FIELD_CHECK_OUTCOME"] = previous
  end

  test "the generator block names the Otis check answered in this turn only when the correlation travels" do
    turn = at(29, 6)
    saved, = reduce_and_reload(turn)
    history = history_session(29, 6).conversation_history
    cid = turn.fetch("correlation_id")
    previous = ENV["FIELD_CHECK_OUTCOME"]
    ENV["FIELD_CHECK_OUTCOME"] = "true"
    fresh = lambda do
      FieldCases::TurnContext.new(channel: "web").tap { |context| context.conversation_history = history }
    end
    answered = /Comprobación activa q3\.p3 .*contestada en este turno \(complete, r\d+\)/

    block = SessionContextBuilder.companion_case(saved, {}, session: fresh.call, correlation_id: cid)
    assert_match answered, block
    assert_no_match answered, SessionContextBuilder.companion_case(saved, {}, session: fresh.call)
    assert_match answered, Rag::CompanionCaseFacts.build(saved, session: fresh.call, correlation_id: cid).prompt_block
    assert_match answered, SessionContextBuilder.companion_context(
      fresh.call, episode: saved, current_message: turn.fetch("message"), current_correlation_id: cid
    )

    prepared = Rag::CompanionDirectAnswer.prepare(
      raw_question: turn.fetch("message"), chunks: [], episode: saved, session: fresh.call, correlation_id: cid
    )
    assert_match answered, prepared.user
    assert_equal 1, prepared.user.scan("Comprobación activa q3.p3").size
  ensure
    ENV["FIELD_CHECK_OUTCOME"] = previous
  end

  # Live round 0 (20261119T215845Z): the generator closed T11 and T5 without a
  # question. It had the closure rule and, for T11, "no pidas la siguiente por
  # inercia", while q4.p4 / q7.p7 (T11) and q2.p2 (T5) were still partial.
  test "FIELD_CHECK_OUTCOME tells the generator not to close Thyssen T11 while earlier checks are partial" do
    turn = at(28, 11)
    saved, = reduce_and_reload(turn)
    user = with_check_outcome("true") { direct_user(turn, saved, 28, 11) }

    assert_match(/contestada en este turno/, user)
    assert_equal 1, user.scan("No cierres el caso").size, user
    assert_no_match(/por inercia/, user)
    assert_match(/no la repitas ni pidas de nuevo lo que el técnico declaró no verificado/i, user)
    assert_match(/no uses esta nota para cerrar el intercambio/, user)
    assert_match(/no los conviertas en condición de la pregunta/, user)
    assert_match(/si esa falla vuelve/, user)
    assert_no_match(/prevalece sobre pedir la siguiente comprobación/, user)
    outcome = Rag::CheckOutcome.new(episode: saved, session: history_session(28, 11), correlation_id: turn.fetch("correlation_id"))
    assert_equal %w[p4 p7], outcome.closed.select { |row| row.state == "partial" }.map(&:part_id)
    assert outcome.leaves_checks_open?
    assert outcome.settled_this_turn?
  end

  # Live 20261120T234638Z. T12 has the same open earlier parts as T11, and the
  # technician has already reported the maneuver result. The note closes that
  # check and does not ask for another cycle.
  test "FIELD_CHECK_OUTCOME closes Thyssen T12 when the technician already reported the maneuver result" do
    turn = at(28, 12)
    saved, = reduce_and_reload(turn)
    user = with_check_outcome("true") { direct_user(turn, saved, 28, 12) }
    outcome = Rag::CheckOutcome.new(episode: saved, session: history_session(28, 12), correlation_id: turn.fetch("correlation_id"))

    assert outcome.settled_this_turn?
    assert outcome.leaves_checks_open?
    assert_match(/prevalece sobre pedir la siguiente comprobación/, user)
    assert_match(/sobre repetir la misma prueba/, user)
    assert_no_match(/si esa falla vuelve|no uses esta nota para cerrar/, user)
  end

  test "a reported maneuver result drops the order to repeat it and keeps what is still unverified" do
    text = <<~TEXT
      Con la maniobra completa, el cambio queda acotado a esa prueba.

      Queda sin verificar:
      - Si el contacto permanece cerrado en distintas maniobras (solo tienes esta prueba).

      Pendiente de tu lado: repetir la maniobra completa y anotar si el EA vuelve a aparecer.
    TEXT
    cleaned = Rag::CompanionDirectAnswer.without_repeated_cycle(text)
    reported = "Si confirmo que la maniobra se completa , el display sigue sin mostrar EA ni otra falla"
    opened = "P28 volvio a marcar +110 vcc y EA desapareció"

    assert_includes cleaned, "distintas maniobras"
    assert_not_includes cleaned, "repetir la maniobra"
    cycles = "La prueba queda cerrada.\n\nComprobación siguiente: ¿el EA no reaparece tras varios ciclos de cierre y apertura?"
    assert_not_includes Rag::CompanionDirectAnswer.without_repeated_cycle(cycles), "varios ciclos"
    assert_includes Rag::CompanionDirectAnswer.without_repeated_cycle(cycles), "La prueba queda cerrada"
    mixed = "La tabla de EA indica «revisar linha dos trincos» [5]. Conviene verificar la línea en ciclos sucesivos de cierre. ¿Repitió esos ciclos y el EA no volvió a aparecer?"
    kept_citation = Rag::CompanionDirectAnswer.without_repeated_cycle(mixed)
    assert_includes kept_citation, "revisar linha dos trincos"
    assert_not_includes kept_citation, "ciclos sucesivos"
    assert_not_includes kept_citation, "Repitió"
    several = "La comprobación queda cerrada.\n\nQueda pendiente: confirmar que el enclavamiento actúa en varias maniobras."
    assert_not_includes Rag::CompanionDirectAnswer.without_repeated_cycle(several), "varias maniobras"
    assert_includes Rag::CompanionDirectAnswer.without_repeated_cycle(several), "queda cerrada"
    again = "La comprobación queda cubierta.\n\nPregunta: ¿Repetiste la maniobra completa al menos unas veces sin que EA reaparezca?"
    assert_not_includes Rag::CompanionDirectAnswer.without_repeated_cycle(again), "Repetiste"
    assert_includes Rag::CompanionDirectAnswer.without_repeated_cycle(again), "queda cubierta"
    closings = "El display no muestra EA.\n\nPregunta: Tras varios cierres y aperturas seguidas de la puerta, ¿el display se mantiene sin EA?"
    assert_not_includes Rag::CompanionDirectAnswer.without_repeated_cycle(closings), "?"
    assert_includes Rag::CompanionDirectAnswer.without_repeated_cycle(closings), "no muestra EA"
    assert Rag::CompanionDirectAnswer.functional_result_reported?(reported)
    assert_not Rag::CompanionDirectAnswer.functional_result_reported?(opened)
    assert Rag::CompanionDirectAnswer.functional_check_opened?(opened)
    assert_not Rag::CompanionDirectAnswer.functional_check_opened?(reported)
  end

  # Live 20261121T002654Z. The note asked whether the maneuver completes and
  # the fault returns. The draft asked only whether EA returns, across
  # several closings. A question that already names the maneuver stays.
  test "an opened functional check asks whether the maneuver completes and the fault returns" do
    draft = "Siguiente comprobación: con la puerta cerrada y trabada, haz varios cierres seguidos. ¿El EA vuelve a aparecer en alguno de ellos?"
    cleaned = Rag::CompanionDirectAnswer.with_opened_functional_check(draft)

    assert_includes cleaned, "¿La maniobra se completa y esa falla vuelve?"
    assert_not_includes cleaned, "cierres seguidos"
    assert_includes cleaned, "puerta cerrada y trabada"
    already = "¿la maniobra se completa y el EA no vuelve en varios cierres seguidos?"
    assert_nil Rag::CompanionDirectAnswer.with_opened_functional_check(already)
    refusal = "La identidad de este equipo no está confirmada.\n\n¿El EA vuelve a aparecer?"
    assert_nil Rag::CompanionDirectAnswer.with_opened_functional_check(refusal)
  end

  # Live 20261121T003218Z. The quote is only the first clause and the
  # interpreter left the part partial. The message already reports the
  # maneuver and the absent fault, so that part is complete.
  test "a reported maneuver result completes the partial reply it already contains" do
    message = "Si confirmo que la maniobra se completa , el enclavamiento de puerta actúa cuando corresponde y el display sigue sin mostrar EA ni otra falla"
    replies = [ { "part_id" => "p9", "state" => "partial", "quote" => "la maniobra se completa" } ]
    promoted = Rag::TurnPerception.complete_functional_replies(replies, message)

    assert_equal "complete", promoted.first["state"]
    untouched = Rag::TurnPerception.complete_functional_replies(replies, "P28 volvio a marcar +110 vcc y EA desapareció")
    assert_equal "partial", untouched.first["state"]
    missing = [ { "part_id" => "p9", "state" => "partial", "quote" => "una frase que no está" } ]
    assert_equal "partial", Rag::TurnPerception.complete_functional_replies(missing, message).first["state"]
  end

  # Live 20261121T004105Z. The quote appended "EA no vuelve a aparecer" to a
  # clause the technician did say. The display line is "sin mostrar EA".
  test "a functional result keeps the clause the technician actually wrote" do
    message = "Si confirmo que la maniobra se completa , el enclavamiento de puerta actúa cuando corresponde y el display sigue sin mostrar EA ni otra falla"
    replies = [ {
      "part_id" => "p9", "state" => "complete",
      "quote" => "la maniobra se completa y EA no vuelve a aparecer"
    } ]
    anchored = Rag::TurnPerception.anchor_functional_quotes(replies, message)

    assert_equal "la maniobra se completa", anchored.first["quote"]
    assert_equal "complete", anchored.first["state"]
    assert_equal "located", Rag::TurnPerception.locate(anchored.first["quote"], message)["status"]
  end

  # Live 20261121T004419Z. The result sentence repeated P28 from the manual,
  # so the filter treated it as a foreign value and the empty citation list
  # replaced the whole close with the identity refusal.
  test "a reported maneuver result is kept and is not replaced by the identity refusal" do
    sentence = "**Resultado:** Con la puerta cerrada y trabada, P28 marcó +110 Vcc, el EA desapareció, la maniobra se completa y el enclavamiento actúa cuando corresponde."
    message = "Si confirmo que la maniobra se completa , el enclavamiento de puerta actúa cuando corresponde y el display sigue sin mostrar EA ni otra falla"
    chunk = { content: "P28 = +110 Vcc. Ponto para ligar sinal do contato de engate do trinco." }
    answer = "#{sentence}\n\nEl detalle exacto del ajuste no quedó especificado."
    result = { answer: answer, citations: [ { "number" => 1 } ] }
    service = BedrockRagService.allocate
    processor = Object.new
    processor.define_singleton_method(:build_numbered_references) { |*| [] }
    service.instance_variable_set(:@citation_processor, processor)

    with_check_outcome("true") do
      filtered = Rag::DocumentIdentityScope.unconfirmed_reference_filter(sentence, [ chunk ], message, technician_texts: [ message ])
      assert_empty filtered.removed
      service.send(:filter_unconfirmed_reference!, result, citations: [], passages: {}, chunks: [], question: message, locale: :es, technician_texts: [ message ])
    end

    assert_includes result[:answer], "maniobra se completa"
    assert_not_includes result[:answer], "identidad de este equipo"
    assert_nil result[:applicability_violation]
  end

  # Live 20261121T003707Z. The reading was stored as an observation and
  # part_replies was absent, so the open EA check never completed.
  test "an opened EA reading completes the single open part when no reply was returned" do
    message = "con la puerta cerrada  y trabada , P28  volvio a marcar +110 vcc y EA desapareció"
    episode = Struct.new(:qc, :pending_question, :replies).new(
      Rag::AnswerContract::VERSION,
      {
        "id" => "q8", "type" => "documented_context", "question" => "¿Sigue marcando EA?",
        "parts" => [ { "id" => "p8", "role" => "main", "text" => "¿Sigue marcando EA?" } ]
      },
      []
    )
    reply = Rag::TurnPerception.opened_functional_reply(message, episode: episode)

    assert_equal "complete", reply["state"]
    assert_equal "p8", reply["part_id"]
    assert_equal "q8", reply["question_id"]
    assert_equal "EA desapareció", reply["quote"]
    result = "Si confirmo que la maniobra se completa , el display sigue sin mostrar EA ni otra falla"
    assert_nil Rag::TurnPerception.opened_functional_reply(result, episode: episode)
  end

  # Live 20261121T003454Z. An accepted close with no citation left was
  # abstained, and the fallback asked the check again.
  test "an accepted functional close without citations is not replaced by the open question" do
    message = "Si confirmo que la maniobra se completa , el display sigue sin mostrar EA ni otra falla"
    result = {
      answer: "La comprobación queda cerrada. La causa no está confirmada.",
      route_outcome: :abstained,
      citations: [],
      companion_contract_invalid: false,
      pending_question: { "question" => "¿la maniobra se completa y el EA vuelve?" }
    }
    service = BedrockRagService.allocate

    with_check_outcome("true") { service.send(:keep_functional_close!, result, message) }

    assert_equal :answered, result[:route_outcome]
    assert_nil result[:pending_question]
    assert_includes result[:answer], "queda cerrada"
  end

  test "FIELD_CHECK_OUTCOME tells the generator not to close Otis T5 while its active check is partial" do
    turn = at(29, 5)
    saved, = reduce_and_reload(turn)
    user = with_check_outcome("true") { direct_user(turn, saved, 29, 5) }

    assert_match(/contestada solo en parte/, user)
    assert_equal 1, user.scan("No cierres el caso").size, user
    assert_match(/no pidas de nuevo lo que el técnico ya reportó/, user)
    assert_match(/cita esa fuente \[n\]/, user)
    assert_no_match(/por inercia|la que falta/, user)
    assert_match(/prevalece sobre pedir la siguiente comprobación/, user)
    assert_no_match(/si esa falla vuelve/, user)
  end

  test "FIELD_CHECK_OUTCOME lets Otis T6 close with the declared unverified DCL" do
    turn = at(29, 6)
    saved, = reduce_and_reload(turn)
    user = with_check_outcome("true") { direct_user(turn, saved, 29, 6) }

    assert_match(/contestada en este turno/, user)
    assert_no_match(/No cierres el caso/, user)
    assert_match(/por inercia/, user)
  end

  test "without FIELD_CHECK_OUTCOME the generator note is the baseline one for T11, T12, T5 and T6" do
    [ [ 28, 11 ], [ 28, 12 ], [ 29, 5 ], [ 29, 6 ] ].each do |case_id, sequence|
      turn = at(case_id, sequence)
      saved, = reduce_and_reload(turn)
      user = with_check_outcome(nil) { direct_user(turn, saved, case_id, sequence) }

      assert_match(/Si el último resultado permite avanzar/, user)
      assert_no_match(/No cierres el caso|por inercia|si esa falla vuelve/, user)
    end
  end

  test "FIELD_CHECK_OUTCOME clears the settled pending when the publication asks nothing" do
    turn = at(28, 11)
    saved, = reduce_and_reload(turn)
    assert_equal "q8", saved.pending_question.fetch("id")
    assert_equal "complete", Rag::AnswerContract.part_state(saved, "p8")
    closing = "Cierre de comprobación: EA no volvió a aparecer con la puerta cerrada y trabada."

    kept = with_owner_and_check_outcome(nil) { publish_without_question(saved, turn, closing) }
    assert_equal "q8", kept.state.dig("pending_question", "id"), "flag off keeps the stored pending"

    cleared = with_owner_and_check_outcome("true") { publish_without_question(saved, turn, closing) }
    assert_nil cleared.state["pending_question"]
    assert_nil cleared.state["pending_fact"]
    reloaded = Rag::ActiveEpisode.parse(cleared.state, now: Time.iso8601(turn.fetch("at")))
    assert_equal "complete", Rag::AnswerContract.part_state(reloaded, "p8")
    assert_equal %w[p4 p7], Rag::CheckOutcome.new(episode: reloaded, session: history_session(28, 11),
      correlation_id: "query:next").closed.select { |row| row.state == "partial" }.map(&:part_id)
  end

  # Same input as live replay 2 (20261120T134952Z) T5: q was answered in part and
  # the technician reported the maneuver result. Keeping it made the reload wait
  # on a question the closing no longer asks. Without a test result in the turn
  # the partial pending is still owed.
  test "FIELD_CHECK_OUTCOME keeps a partial pending unless the turn reported a test result and the publication asks nothing" do
    turn = at(29, 5)
    saved, = reduce_and_reload(turn)
    assert_equal "partial", Rag::AnswerContract.part_state(saved, "p2")
    assert saved.checks.any? { |check| check["correlation_id"] == turn.fetch("correlation_id") }, "the turn reported a check"
    closing = "Retiraste los residuos de la guía."

    cleared = with_owner_and_check_outcome("true") { publish_without_question(saved, turn, closing) }
    assert_nil cleared.state["pending_question"]
    kept = with_owner_and_check_outcome(nil) { publish_without_question(saved, turn, closing) }
    assert_equal "q2", kept.state.dig("pending_question", "id"), "flag off keeps it"

    saved.checks.reject! { |check| check["correlation_id"] == turn.fetch("correlation_id") }
    owed = with_owner_and_check_outcome("true") { publish_without_question(saved, turn, closing) }
    assert_equal "q2", owed.state.dig("pending_question", "id"), "no test result this turn: still owed"
  end

  test "FIELD_CHECK_OUTCOME keeps a pending nobody answered when the turn reported no test result and the publication asks nothing" do
    turn = at(28, 11)
    saved, = reduce_and_reload(turn)
    saved.replies.reject! { |reply| reply["p"] == "p8" }
    saved.checks.reject! { |check| check["correlation_id"] == turn.fetch("correlation_id") }
    assert_nil Rag::AnswerContract.part_state(saved, "p8")

    kept = with_owner_and_check_outcome("true") { publish_without_question(saved, turn, "Respuesta sin pregunta.") }
    assert_equal "q8", kept.state.dig("pending_question", "id")
  end

  # Live T4 → T5: nobody bound q4, T5 reported a test result and the publication
  # closed it without a question. q4 must not wait for the next turn.
  test "FIELD_CHECK_OUTCOME clears a pending nobody answered when the turn reported a test result and the publication asks nothing" do
    turn = at(28, 11)
    saved, = reduce_and_reload(turn)
    saved.replies.reject! { |reply| reply["p"] == "p8" }
    assert saved.checks.any? { |check| check["correlation_id"] == turn.fetch("correlation_id") }, "the turn reported a check"

    cleared = with_owner_and_check_outcome("true") { publish_without_question(saved, turn, "Respuesta sin pregunta.") }
    assert_nil cleared.state["pending_question"]
    kept = with_owner_and_check_outcome(nil) { publish_without_question(saved, turn, "Respuesta sin pregunta.") }
    assert_equal "q8", kept.state.dig("pending_question", "id"), "flag off keeps it"
  end

  # Live rounds 0, 1 and 2: the block listed the technician's words of this
  # turn ("No llegamos a verificar DCL ni DFC") under "No lo pidas de nuevo",
  # so the generator never asked DFC. Only what an earlier turn declared, and
  # what the technician cannot provide, stays under that rule.
  test "FIELD_CHECK_OUTCOME separates what this turn left undone from what earlier turns declared" do
    turn = at(29, 6)
    saved, = reduce_and_reload(turn)
    session = history_session(29, 6)
    outcome = with_check_outcome("true") do
      Rag::CheckOutcome.new(episode: saved, session: session, correlation_id: turn.fetch("correlation_id"))
    end
    lines = outcome.lines
    now = outcome.unverified.select { |row| row.kind == "not_done" && row.correlation_id == turn.fetch("correlation_id") }

    assert_not_empty now, outcome.unverified.inspect
    assert_equal [ 3, 5, 6 ], outcome.unverified.select { |row| row.text.match?(/\bDCL\b/i) }.map(&:turn)
    earlier_at = lines.index { |line| line.start_with?("Declarado por el técnico como no verificado o inaccesible") }
    now_at = lines.index { |line| line.start_with?("Declarado en este turno como no hecho todavía") }
    assert earlier_at && now_at && earlier_at < now_at, lines.inspect
    assert_match(/no figure arriba/, lines[now_at])
    assert_match(/una fuente de este turno lo respalda y la citas/, lines[now_at])
    now.each { |row| assert_includes lines[(now_at + 1)..], "- «#{row.text}» (turno #{row.turn})" }
    assert_not_includes lines[(earlier_at + 1)...now_at].join("\n"), now.first.text
  end

  test "without FIELD_CHECK_OUTCOME the case block keeps the AnswerContract lines for T6" do
    turn = at(29, 6)
    saved, = reduce_and_reload(turn)
    session = history_session(29, 6)

    with_check_outcome(nil) do
      lines = Rag::CheckOutcome.context_lines(saved, session, correlation_id: turn.fetch("correlation_id"))
      assert_equal Rag::AnswerContract.context_lines(saved, session), lines
      assert_none = lines.none? { |line| line.start_with?("Declarado en este turno") || line.start_with?("Estado de la comprobación") }
      assert assert_none, lines.inspect
    end
  end

  test "photo context preserves the visible diagram and distinguishes its labels from the technician's EA" do
    turn = at(28, 1)
    context = photo_context(turn)

    assert_includes context.to_prompt.fetch("visible_text"), "P28"
    assert_not_includes context.to_prompt.fetch("visible_text"), "EA"
    assert_empty context.query_terms
    assert_includes context.observed_labels, "P28"
    assert_equal "photo", context.to_prompt.fetch("source")
    assert_equal false, context.to_prompt.fetch("target_visible")
    assert_equal "uncertain", context.to_prompt.fetch("relevance_to_goal")
    assert_operator JSON.generate(context.to_prompt).bytesize, :<=, Rag::ActivePhotoContext::MAX_BYTES
  end

  test "Otis vision keeps COR and CR while the second photo concerns the guide" do
    rows = CASES.fetch("29").fetch("turns")
    assert_equal [ 1, 3 ], rows.each_index.filter_map { |index| index + 1 if rows[index].key?("attachment") }
    console = photo_context(at(29, 1))
    guide = photo_context(at(29, 3))

    assert_empty %w[COR CR] - console.observed_labels.join(" ").scan(/\b[A-Z]+\b/)
    assert_no_match(/\b0102\b/, console.observed_labels.join(" "))
    assert_equal at(29, 3).dig("vision", "canonical_component"), guide.to_prompt.fetch("component")
    assert_no_match(/\bDCL\b/, guide.observed_labels.join(" "))
  end

  test "reordered closure paraphrases preserve facts, negation and test scope" do
    closing = [
      "Durante el ensayo no se registró el evento 0102. DCL quedó pendiente de control. La luz DFC permaneció iluminada.",
      "DFC se mantuvo activado. No se verificó DCL. En esa maniobra el 0102 estuvo ausente."
    ]
    closing.each do |answer|
      assert PilotNov19Rubric.claim?(answer, /\bdfc\b/, ENERGIZED, STAYED, without: NEGATED_OUTCOME), answer
      assert PilotNov19Rubric.claim?(answer, /\bdcl\b/, APPLICABILITY_PENDING), answer
      assert PilotNov19Rubric.claim?(answer, /\b0102\b/, ABSENT_FAULT, TEST_SCOPE), answer
    end
    assert_not PilotNov19Rubric.claim?("El 0102 volvió a aparecer durante el ensayo.", /\b0102\b/, ABSENT_FAULT, TEST_SCOPE)
    assert_not PilotNov19Rubric.claim?("El 0102 estuvo ausente.", /\b0102\b/, ABSENT_FAULT, TEST_SCOPE)
    assert_not PilotNov19Rubric.claim?("DFC no se mantuvo activado.", /\bdfc\b/, ENERGIZED, STAYED, without: NEGATED_OUTCOME)
  end

  test "rewritten documentary and temperature answers retain their conditions and sources" do
    opening = "Solo en el primer ciclo tras perder el suministro eléctrico se mueve despacio."
    assert PilotNov19Rubric.claim?(opening, FIRST_OPERATION, POWER_LOSS, ELECTRICAL_SUPPLY, SLOW)
    adjustment = "Retirar o reconectar la célula fotoeléctrica, o restaurar los parámetros de fábrica, puede requerir autoajuste. Por el corte descrito, la calibración automática es innecesaria."
    assert PilotNov19Rubric.claim?(adjustment, ADJUSTMENT, UNNECESSARY)
    assert PilotNov19Rubric.claim?(adjustment, ADJUSTMENT, DEFAULTS)
    assert PilotNov19Rubric.claim?(adjustment, PHOTOCELL, CONNECT, DISCONNECT)
    response = "Aquí falta un umbral documentado para interpretar los 26 grados Celsius que mediste junto al gabinete."
    assert PilotNov19Rubric.claim?(response, TEMPERATURE, DOC_LIMIT, UNDOCUMENTED)
    assert_not PilotNov19Rubric.claim?("El manual fija un umbral de 26 °C.", TEMPERATURE, DOC_LIMIT, UNDOCUMENTED)
  end

  test "the Portuguese source can be quoted with a faithful Spanish gloss and the field language is audited separately" do
    original = at(28, 1).fetch("sources").sole.fetch("excerpt").split(" … ").last
    p28 = /\bp28\b/
    assert PilotNov19Rubric.claim?(original, p28, /\bfalha\b/, /\bporta aberta\b/, /linha dos trincos/)
    spanish = [
      "Cuando falla P28 con la puerta abierta, corresponde revisar la línea de los trincos.",
      "La línea de los pestillos se revisa si, con una puerta abierta, P28 presenta una falla."
    ]
    claims = [ p28, /\bfall\w*\b/, /\bpuerta abierta\b/, /(?:linea|circuito)\b.*(?:trincos|pestillos|cerrojos|cerraduras)/, CONDITION ]
    spanish.each do |gloss|
      assert PilotNov19Rubric.claim?(gloss, *claims), gloss
      assert_empty PilotNov19Rubric.language_findings("#{gloss} «#{original}» [1].")
    end
    assert_not PilotNov19Rubric.claim?("Si falla P28 con la puerta cerrada, revisa la línea de los trincos.", *claims)
    assert_not PilotNov19Rubric.claim?("Siempre que falla P28 se revisa la línea de los trincos.", *claims)
    assert_equal [ "question:pt" ], PilotNov19Rubric.language_findings(at(28, 9).fetch("published"))
    portuguese = "Verifique a linha dos trincos quando falha P28 com a porta aberta."
    assert PilotNov19Rubric.claim?(portuguese, p28, /\bfalha\b/, /\bporta aberta\b/, /linha dos trincos/)
    assert_equal [ "orientation:pt" ], PilotNov19Rubric.language_findings(portuguese)

    english = "The display did not show 0102 during the test. Was DCL still unverified?"
    gloss = "El display no mostró 0102 durante la prueba. ¿DCL quedó sin verificar?"
    assert PilotNov19Rubric.claim?(english, /\b0102\b/, /did not show/, /during the test/)
    assert PilotNov19Rubric.claim?(gloss, /\b0102\b/, ABSENT_FAULT, TEST_SCOPE)
    assert_equal %w[orientation:en question:en], PilotNov19Rubric.language_findings(english).sort
    assert_empty PilotNov19Rubric.language_findings(gloss)
  end

  private

  def at(case_id, sequence)
    CASES.fetch(case_id.to_s).fetch("turns").fetch(sequence - 1)
  end

  def reduce(turn, episode)
    text = turn.fetch("message")
    perception = Rag::TurnPerception.build(turn.fetch("tool"), turn: text, episode: episode,
      catalog: nil, viewer_account: nil, require_work_change_evidence: true)
    assert perception.valid, perception.invalid_reason
    route = Rag::RoutePolicy.call(previous: episode, perception: perception, turn: text, focus_count: 1)
    Rag::WorkContextReducer.apply!(episode: episode, perception: perception, decision: route, turn: text,
      correlation_id: turn.fetch("correlation_id"), now: Time.iso8601(turn.fetch("at")))
  end

  def reduce_and_reload(row)
    time = Time.iso8601(row.fetch("at"))
    travel_to(time) do
      episode = reduce(row, Rag::ActiveEpisode.parse(row.fetch("before"), now: time))
      kase = open_case
      admitted = admit(kase, message: row.fetch("message"))
      assert admitted.ok?, admitted.error.inspect
      assert close_turn(kase, admitted.turn, state: episode.to_h, checkpoint: episode.to_h).ok?
      assert_equal row.fetch("message"), admitted.turn.reload.message
      checkpoint = admitted.turn.checkpoint
      assert_equal checkpoint, kase.reload.technical_state
      return [ Rag::ActiveEpisode.parse(checkpoint, now: time), admitted.turn ]
    end
  end

  # The history a reload would give: each case turn and what was published.
  def history_session(case_id, upto)
    session = ConversationSession.new(account: accounts(:legacy), user: users(:one), channel: "web", identifier: "web:probe-#{case_id}")
    session.conversation_history = CASES.fetch(case_id.to_s).fetch("turns").first(upto).flat_map do |row|
      [
        session.send(:history_message, "user", row.fetch("message"), user_id: users(:one).id, correlation_id: row.fetch("correlation_id")),
        session.send(:history_message, "assistant", row["published"].to_s, user_id: users(:one).id, correlation_id: row.fetch("correlation_id"))
      ]
    end
    session
  end

  def with_check_outcome(value)
    previous = ENV["FIELD_CHECK_OUTCOME"]
    value.nil? ? ENV.delete("FIELD_CHECK_OUTCOME") : ENV["FIELD_CHECK_OUTCOME"] = value
    yield
  ensure
    previous.nil? ? ENV.delete("FIELD_CHECK_OUTCOME") : ENV["FIELD_CHECK_OUTCOME"] = previous
  end

  def with_owner_and_check_outcome(value, &block)
    previous = ENV["HAIKU_QUERY_ANALYSIS_MODE"]
    ENV["HAIKU_QUERY_ANALYSIS_MODE"] = "owner"
    with_check_outcome(value, &block)
  ensure
    previous.nil? ? ENV.delete("HAIKU_QUERY_ANALYSIS_MODE") : ENV["HAIKU_QUERY_ANALYSIS_MODE"] = previous
  end

  def direct_user(turn, episode, case_id, sequence)
    Rag::CompanionDirectAnswer.prepare(
      raw_question: turn.fetch("message"), chunks: [], episode: episode,
      session: history_session(case_id, sequence), correlation_id: turn.fetch("correlation_id")
    ).user
  end

  def publish_without_question(episode, turn, text)
    Rag::ActiveEpisodeTurn.apply_assistant(
      state: Rag::ActiveEpisode.parse(episode.to_h, now: Time.iso8601(turn.fetch("at"))), text: text,
      now: Time.iso8601(turn.fetch("at")), correlation_id: turn.fetch("correlation_id"), pending_question: nil
    )
  end

  def close_followup(draft, episode, turn)
    Rag::CompoundCheckReply.without_redundant_followup(draft, episode: episode,
      turn: turn.fetch("message"), correlation_id: turn.fetch("correlation_id"), locale: :es)
  end

  def photo_context(row)
    account = accounts(:legacy)
    photo = field_photo_for(account, sha: row.dig("attachment", "sha256"))
    assert FieldPhotoObservation.persist!(photo, row.fetch("vision"))
    episode = Rag::ActiveEpisode.open(correlation_id: row.fetch("correlation_id"), now: Time.current)
    episode.active_photo = { "field_photo_id" => photo.id, "sha256" => photo.sha256 }
    Rag::ActivePhotoContext.resolve(episode: episode, viewer_account: account)
  end
end
