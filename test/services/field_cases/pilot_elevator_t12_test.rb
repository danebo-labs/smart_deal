# frozen_string_literal: true

require "test_helper"
require_relative "../../support/field_case_history_helper"
require_relative "../../support/pilot_elevator_closure"

class FieldCases::PilotElevatorT12Test < ActiveSupport::TestCase
  include FieldCaseHistoryHelper

  test "the captured report and draft close the same persisted turn" do
    with_shared_session(false) do
      capture = PilotElevatorClosure.load_capture
      turns = capture.fetch("turns")
      checkpoint = turns[-2].fetch("checkpoint")
      unlinked = JSON.parse(Rails.root.join("test/fixtures/files/field_companion/pilot_elevator_t12_unlinked_check.json").read)
      kase = open_case
      kase.update!(episode_id: capture.fetch("episode_id"), technical_state: checkpoint)
      message = turns.last.fetch("message")
      admission = admit(kase, message: message, correlation_id: unlinked.fetch("correlation_id"))
      field_turn = FieldCases::TextTurn.new(admission, account: kase.account, user: kase.user)
      context = field_turn.context
      episode = Rag::ActiveEpisode.parse(context.active_episode)
      perception = Rag::TurnPerception.build(unlinked.fetch("tool"), turn: message, episode: episode,
        catalog: nil, viewer_account: kase.account)
      decision = Rag::RoutePolicy.call(previous: episode, perception: perception, turn: message, focus_count: 1)
      cid = admission.turn.correlation_id
      Rag::WorkContextReducer.apply!(episode: episode, perception: perception, decision: decision, turn: message,
        correlation_id: cid, now: Time.current)
      assert_empty episode.answer_report.fetch("refused")
      assert_equal "complete", Rag::AnswerContract.part_state(episode, "p9")
      context.update!(active_episode: episode.to_h)

      service = BedrockRagService.allocate
      service.instance_variable_set(:@companion_direct_turn, true)
      service.instance_variable_set(:@citation_processor, Bedrock::CitationProcessor.new)
      service.send(:snapshot_direct_case!, context, episode, cid)
      chunks = PilotElevatorClosure.numbered_chunks(turns.last, key: "sources", pin_uri: capture.fetch("pin_uri"))
      generated = service.send(:finish_companion_turn_generation, question: message, raw_answer: unlinked.fetch("draft"),
        chunks: chunks, response_locale: :es, retrieval: {}, stop_reason: "end_turn",
        technician_texts: turns.pluck("message"), manufacturer: "Thyssen", episode: episode, correlation_id: cid)
      assert_equal :answered, generated.fetch(:route_outcome)
      result = RagQueryConcern::RagResult.new(**generated.slice(:answer, :citations, :pending_question, :case_outcome,
        :case_evidence, :expected_case_revision, :correlation_id), response_locale: :es, history_answer: generated[:case_history])
      context.capture_pending!(result)
      written = Rag::CompanionCaseWrite.persist!(context, result, user_id: kase.user_id, expected_episode_id: kase.episode_id)
      refute Rag::CompanionCaseWrite.conflict?(written)

      assert field_turn.complete({ answer: result.answer, citations: result.citations, provenance_segments: [] },
        context, prompt_reply: result.history_answer).ok?
      reloaded = Rag::ActiveEpisode.parse(kase.reload.technical_state)
      published = admission.turn.reload.response.fetch("published_text")
      assert_equal "complete", Rag::AnswerContract.part_state(reloaded, "p9")
      assert_equal cid, Rag::AnswerContract.current_replies(reloaded, "p9").sole.fetch("cid")
      assert_empty Rag::AnswerContract.open_parts(reloaded)
      assert_equal checkpoint.dig("id_seq", "p"), reloaded.id_seq.fetch("p")
      assert_empty PilotElevatorClosure.missing_closure_facts(published), published
      assert_match(/según el técnico[^.]*contacto[^.]*no cerraba eléctricamente[^.]*trinco trababa/i, published)
      assert_match(/relación causal.*hipótesis/i, published)
      refute_match(/[¿?]/, published)
    end
  end
end
