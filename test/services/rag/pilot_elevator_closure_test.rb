# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
require_relative "../../../config/environment"
require "minitest/autorun"
require_relative "../../support/live_aws_block"
require_relative "../../support/pilot_elevator_closure"

LiveAwsBlock.install!

class Rag::PilotElevatorClosureTest < Minitest::Test
  CAPTURE = PilotElevatorClosure.load_capture
  TURNS = CAPTURE.fetch("turns")
  LIVE_DRAFT = JSON.parse(Rails.root.join("test/fixtures/files/field_companion/pilot_elevator_t12_live_draft.json").read)

  def test_valid_functional_reply_survives_episode_budget
    turn = TURNS.last
    episode = replay_perception(TURNS[-2].fetch("checkpoint"), turn)
    assert_empty episode.answer_report["refused"]
    assert_equal "complete", Rag::AnswerContract.part_state(episode, "p9")
    assert_empty Rag::AnswerContract.open_parts(episode)
    assert_operator JSON.generate(episode.to_h).bytesize, :<=, Rag::ActiveEpisode::MAX_BYTES
  end

  def test_marker_and_dependent_claim_do_not_block_captured_field_report
    turn = TURNS.last
    answer = finish(turn.fetch("raw_answer"), turn)
    assert_equal :answered, answer[:route_outcome], answer[:companion_publication].inspect
    assert_match(/maniobra se completa/i, answer[:answer])
    refute_match(/REQUIRES_FIELD_VERIFICATION|puentes (?:de instalación|provisorios)/i, answer[:answer])
  end


  def test_partial_or_ambiguous_reply_leaves_the_check_open
    previous = TURNS[-2].fetch("checkpoint").deep_dup.except("excerpts", "checks", "observations")
    partial = TURNS.last.deep_dup
    partial.dig("tool", "part_replies", 0)["state"] = "partial"
    episode = replay_perception(previous, partial)
    assert_equal "partial", Rag::AnswerContract.part_state(episode, "p9")
    assert_equal [ "p9" ], Rag::AnswerContract.open_parts(episode).pluck("id")

    ambiguous = TURNS.last.deep_dup
    ambiguous["message"] = ([ambiguous.fetch("message")] * 2).join(" ")
    episode = replay_perception(previous, ambiguous)
    assert_equal "quote_ambiguous", episode.answer_report.fetch("refused").first.fetch("reason")
    assert_equal [ "p9" ], Rag::AnswerContract.open_parts(episode).pluck("id")
  end

  def test_compound_check_requires_the_complete_unambiguous_report
    previous = TURNS[-2].fetch("checkpoint")
    original = TURNS.last
    tool = JSON.parse(Rails.root.join("test/fixtures/files/field_companion/pilot_elevator_t12_unlinked_check.json").read).fetch("tool")
    variants = [
      original.fetch("message").sub("confirmó que", "cree que"),
      original.fetch("message").split(", el enclavamiento").first,
      original.fetch("message").sub("la maniobra se completa", "la maniobra no se completa"),
      original.fetch("message") + " Sin embargo, después volvió a fallar."
    ]
    variants.each do |message|
      turn = original.merge("tool" => tool, "message" => message)
      episode = replay_perception(previous, turn)
      assert_equal [ "p9" ], Rag::AnswerContract.open_parts(episode).pluck("id"), message
      assert_nil Rag::AnswerContract.part_state(episode, "p9"), message
    end

    explicit = original.fetch("message").sub(" y el display", ". El display")
    episode = replay_perception(previous, original.merge("tool" => tool, "message" => explicit))
    assert_equal "complete", Rag::AnswerContract.part_state(episode, "p9")
  end

  def test_completed_compound_check_does_not_suppress_a_different_diagnostic_question
    turn = TURNS.last
    episode = replay_perception(TURNS[-2].fetch("checkpoint"), turn)
    text = "El técnico confirmó el resultado. ¿Apareció una falla nueva al reiniciar?"
    assert_equal text, Rag::CompoundCheckReply.without_redundant_followup(text, episode: episode,
      turn: turn.fetch("message"), correlation_id: turn.fetch("correlation_id"), locale: :es)
  end

  def test_independent_sentence_survives_an_internal_marker_in_its_paragraph
    marker = "REQUIRES_FIELD_VERIFICATION: confirmar a tensão do motor"
    turn = TURNS.last.merge("sources" => [
      { "n" => 1, "text" => "Nota de extracción. #{marker}.", "uri" => "s3://test/manual/page.txt", "page" => 2 }
    ])
    answer = finish("El técnico confirmó que la maniobra se completa. El manual dice «#{marker}» [1]. Esto aplica al motor.", turn)
    assert_equal :answered, answer[:route_outcome]
    assert_match(/maniobra se completa/, answer[:answer])
    refute_match(/REQUIRES_FIELD_VERIFICATION|aplica al motor/, answer[:answer])
    assert_empty answer.dig(:companion_publication, "quotes")
  end

  def test_case_replay_through_twelve_turns_and_reports_a_supported_closure
    first = TURNS.first
    state = first.fetch("checkpoint").deep_dup
    visual = FieldPhotoObservation.sanitize(first.fetch("visual_context"))
    assert_includes visual.fetch("visible_text"), "P28"
    assert_equal first.dig("attachment", "sha256"), state.dig("active_photo", "sha256")
    assert_equal "user", state.dig("facts", "fault_code", "source")

    TURNS.drop(1).each do |turn|
      episode = replay_perception(state, turn)
      assert_equal CAPTURE.fetch("episode_id"), episode.episode_id
      assert_equal state.fetch("active_photo"), episode.active_photo
      assert_equal state.dig("facts", "manufacturer"), episode.facts["manufacturer"]
      assert_equal [ CAPTURE.fetch("pin_uri") ], turn.fetch("focus_uris")
      assert_equal [ 53 ], turn.fetch("focus_ids")
      assert_observation_provenance(episode, turn)
      state = episode.to_h
      if turn != TURNS.last
        # Captured earlier answers act as the assistant double. Carry the
        # user state produced by the reducer into the next fixture turn.
        checkpoint = turn.fetch("checkpoint")
        state["pending_question"] = checkpoint["pending_question"]
        state["id_seq"] = state["id_seq"].merge(checkpoint.fetch("id_seq").slice("q", "p"))
      else
        assert_empty Rag::AnswerContract.open_parts(episode)
        assert_equal turn.fetch("correlation_id"), episode.replies.last.fetch("cid")
      end
    end

    generation_double = <<~ANSWER
      El técnico constató que el contacto de enganche no cerraba eléctricamente aunque el trinco trababa. Después de la intervención, con la puerta cerrada y trabada, P28 recuperó +110 Vcc y EA desapareció.

      El técnico confirmó que la maniobra terminó correctamente y que el enclavamiento actuó cuando correspondía. El display sigue sin EA ni otra falla. El detalle de la reparación quedó sin especificar. La relación causal entre el contacto y la falla sigue siendo una hipótesis.
    ANSWER
    result = finish(generation_double, TURNS.last)
    assert_equal :answered, result[:route_outcome], result[:companion_publication].inspect
    assert_empty PilotElevatorClosure.missing_closure_facts(result[:answer]), result[:answer]
    assert_empty result.dig(:companion_publication, "quotes")
    assert_match(/relación causal[^.]*hipótesis/i, result[:answer])
    assert_nil result[:pending_question]
  end

  def test_captured_draft_reproduces_the_missing_finding_before_publication
    turn = TURNS.last
    assert_equal TURNS[-2].fetch("message"), LIVE_DRAFT.fetch("technician_report_in_request")
    result = finish(LIVE_DRAFT.fetch("draft"), turn)
    assert_equal :answered, result[:route_outcome]
    assert_equal [:electrical_finding], PilotElevatorClosure.missing_closure_facts(result[:answer])
  end

  def test_direct_closure_request_keeps_the_report_and_distinguishes_it_from_hypotheses
    turn = TURNS.last
    episode = replay_perception(TURNS[-2].fetch("checkpoint"), turn)
    history = TURNS[-4, 3].map do |row|
      { "role" => "user", "content" => row.fetch("message"), "ts" => row.fetch("admitted_at"),
        "correlation_id" => row.fetch("correlation_id") }
    end
    session = Struct.new(:conversation_history).new(history)
    prepared = Rag::CompanionDirectAnswer.prepare(raw_question: turn.fetch("message"),
      chunks: [], episode: episode, session: session, correlation_id: turn.fetch("correlation_id"))

    dispatched = prepared.messages.filter_map { |message| message.dig(:content, 0, :text) if message[:role] == "user" }.join("\n")
    assert_includes dispatched, LIVE_DRAFT.fetch("technician_report_in_request")
    assert_includes dispatched, turn.fetch("message")
    closure = prepared.system.split("\n\n").find { |paragraph| paragraph.start_with?("Si el técnico confirma el funcionamiento") }
    assert_match(/hallazgo[^.]*atribuye al técnico[^.]*qué comprobó/i, closure)
    assert_match(/intervención[^.]*detalle[^.]*especificar/i, closure)
    assert_match(/resultado[^.]*lecturas/i, closure)
    assert_match(/hipótesis[^.]*sin confirmar/i, closure)
    assert_empty Rag::AnswerContract.open_parts(episode)
  end

  def test_portuguese_passage_keeps_its_condition_and_literal_quote_contract
    turn = TURNS.last
    original = "Quando falha de P28 - porta aberta - revisar linha dos trincos"
    translated = "Cuando falla P28 con la puerta abierta, revisar la línea de trincos"
    valid = finish("El manual indica «#{original}» [1].", turn)
    assert_equal :answered, valid[:route_outcome]
    assert_equal [ original ], valid.dig(:companion_publication, "quotes").pluck("text")

    faithful = finish("Según el manual, #{translated} [1].", turn)
    assert_equal :answered, faithful[:route_outcome]
    assert_empty faithful.dig(:companion_publication, "quotes")
    assert_match(/puerta abierta[^.]*trincos.*\[1\]/i, faithful[:answer])

    reading = finish("P28 (RA-53) = +110 Vdc [4].", turn)
    assert_equal :answered, reading[:route_outcome]
    assert_equal :abstained, finish("P28 (RA-53) = +110 Vca [4].", turn)[:route_outcome]
    assert_equal :abstained, finish("P28 (RA-53) = -110 Vcc [4].", turn)[:route_outcome]

    lost_condition = finish("El manual indica revisar la línea de trincos si falla P28 [1].", turn)
    assert_equal :abstained, lost_condition[:route_outcome]
    false_quote = finish("El manual indica «#{translated}» [1].", turn)
    assert_equal :abstained, false_quote[:route_outcome]
  end

  def assert_observation_provenance(episode, turn)
    messages = TURNS.first(turn.fetch("sequence")).index_by { |row| row.fetch("correlation_id") }
    episode.observations.each do |row|
      source = messages.fetch(row.fetch("correlation_id")).fetch("message")
      assert Rag::TurnPerception.literal_fragment?(row.fetch("text"), source), row.inspect
    end
  end

  private

  def replay_perception(state, turn)
    now = Time.iso8601(turn.fetch("admitted_at"))
    episode = Rag::ActiveEpisode.parse(state, now: now)
    text = turn.fetch("message")
    perception = Rag::TurnPerception.build(turn.fetch("tool"), turn: text, episode: episode,
      catalog: nil, viewer_account: nil, require_work_change_evidence: true)
    if !perception.valid
      assert_equal "meta_incompatible", perception.invalid_reason
      assert_equal "meta", turn.dig("tool", "move")
      # Captured legacy fallback continued this turn without admitting
      # new user facts. Its published next question is replayed below.
      return episode
    end
    route = Rag::RoutePolicy.call(previous: episode, perception: perception, turn: text,
      focus_count: turn.fetch("focus_ids").size, focus_document_ids: turn.fetch("focus_ids"),
      focus_uris: turn.fetch("focus_uris"))
    Rag::WorkContextReducer.apply!(episode: episode, perception: perception, decision: route, turn: text,
      correlation_id: turn.fetch("correlation_id"), now: now)
  end

  def finish(raw, turn)
    service = BedrockRagService.allocate
    service.instance_variable_set(:@companion_direct_turn, true)
    service.instance_variable_set(:@citation_processor, Bedrock::CitationProcessor.new)
    chunks = PilotElevatorClosure.numbered_chunks(turn, key: "sources", pin_uri: CAPTURE.fetch("pin_uri"))
    service.send(:finish_companion_turn_generation, question: turn.fetch("message"), raw_answer: raw,
      chunks: chunks, response_locale: :es, retrieval: {}, stop_reason: "end_turn",
      technician_texts: TURNS.pluck("message"), manufacturer: "Thyssen")
  end
end
