# frozen_string_literal: true

require "test_helper"
require_relative "../../support/field_case_history_helper"

class Rag::PilotNov19RegressionTest < ActiveSupport::TestCase
  include FieldCaseHistoryHelper

  CASES = JSON.parse(Rails.root.join("test/fixtures/files/field_companion/pilot_2026_11_19.json").read).fetch("cases")

  test "Err14 preserves a Celsius measurement and every accepted manual quote across publication" do
    turns = CASES.fetch("25").fetch("turns")
    capture = turns.last.fetch("capture")
    source = capture.fetch("source").fetch("text")

    assert_equal [ { "rule" => "R5", "detail" => "quote_removed" } ], capture.fetch("reasons")
    assert_no_match(/temperatura ambiental es demasiado alta/i, capture.fetch("after_guard"))
    assert_equal Rag::CompanionTurnPublication.abstain_message(:es), turns.last.fetch("published")

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
        assert_match(/26 °C/, guarded[:answer])
      end
    end
    assert_match(/ventilador.*gira/i, capture.fetch("draft"))
    assert_match(/no se pueden comparar con un límite/i, capture.fetch("draft"))
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
    assert_match(/maniobra se completa.*enclavamiento actúa.*ya no muestra EA/i, answer)
    assert_match(/no confirma que sea la causa/i, answer)
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
    assert_match(/DFC encendido y estable/i, answer)
    assert_match(/falt[a-z]+ verificar DCL/i, answer)
    assert_match(/0102 no reapareciera.*prueba/i, answer)
    different = "En esa prueba se completó el cierre. ¿Apareció DW en el historial después?"
    assert_equal different, close_followup(different, saved, turn)
  end

  test "photo context preserves the visible diagram and distinguishes its labels from the technician's EA" do
    turn = at(28, 1)
    context = photo_context(turn)

    assert_includes context.to_prompt.fetch("visible_text"), "P28"
    assert_not_includes context.to_prompt.fetch("visible_text"), "EA"
    assert_empty context.query_terms
    assert_includes context.generation_block, "P28"
    assert_includes context.generation_block, "Not stated by the technician."
    assert_includes context.generation_block, "not visible"
    assert_operator JSON.generate(context.to_prompt).bytesize, :<=, Rag::ActivePhotoContext::MAX_BYTES
  end

  test "Otis vision keeps COR and CR while the second photo concerns the guide" do
    rows = CASES.fetch("29").fetch("turns")
    assert_equal [ 1, 3 ], rows.each_index.filter_map { |index| index + 1 if rows[index].key?("attachment") }
    console = photo_context(at(29, 1))
    guide = photo_context(at(29, 3))

    assert_match(/\bCOR\b.*\bCR\b/, console.generation_block)
    assert_no_match(/\b0102\b/, console.generation_block)
    assert_match(/guía de umbral/i, guide.generation_block)
    assert_no_match(/\bDCL\b/, guide.generation_block)
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
