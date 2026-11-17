# frozen_string_literal: true

require "test_helper"
require_relative "../../support/field_case_history_helper"

class Rag::FieldCaseDialogueTest < ActiveSupport::TestCase
  include FieldCaseHistoryHelper

  setup { enable_history! }
  teardown { disable_history! }

  test "field turns keep the stored dialogue and attach the captured layers" do
    user = users(:one)
    traced = open_case(account: user.account, user: user)
    opening = finish_turn(
      traced,
      message: "Hay un ruido fuerte en el motor de tracción del controlador MCINV4",
      published_text: "¿Cómo evalúa la intensidad del ruido?",
      citations: [],
      checkpoint: {},
      technical_state: opening_state
    )
    corrected = finish_turn(
      traced,
      message: "El valor de KP-VS es 2,5",
      published_text: ABSTENTION,
      citations: [],
      checkpoint: corrected_state,
      technical_state: corrected_state
    )
    silent = open_case(account: user.account, user: user)
    stored = finish_turn(
      silent,
      message: "El contacto quedó abierto",
      published_text: "La respuesta guardada.",
      citations: [ { "page" => 7, "title" => "Manual" } ],
      checkpoint: { "goal" => { "text" => "sin traza" } },
      technical_state: { "goal" => { "text" => "sin traza" } }
    )
    foreign = finish_turn(
      open_case(account: accounts(:climb), user: users(:two)),
      message: "caso de otra cuenta",
      published_text: "no exportar",
      citations: [],
      checkpoint: {},
      technical_state: { "v" => 1 }
    )
    capture_opening(opening)
    capture_correction(corrected)
    durable_answer(corrected, "texto durable que no es la publicación")
    pilot_event(corrected)
    legacy = legacy_session(user, corrected.correlation_id)

    report = PilotMetricsReport.new(from: Date.current, to: Date.current, user_ids: [ user.id ]).as_json
    threads = report[:field_case_threads]
    opening_row = turn_row(threads, opening.correlation_id)
    corrected_row = turn_row(threads, corrected.correlation_id)
    stored_row = turn_row(threads, stored.correlation_id)

    assert_equal [ traced.id, silent.id ].sort, threads.pluck(:field_case_id)
    assert_equal [ 1, 2 ], threads.find { |thread| thread[:field_case_id] == traced.id }[:turns].pluck(:sequence)
    assert_equal 1, threads.find { |thread| thread[:field_case_id] == silent.id }[:turns].size
    assert threads.all? { |thread| thread[:device_note] == Rag::FieldCaseDialogue::DEVICE_NOTE }
    assert_not_includes report.to_s, foreign.correlation_id
    assert_not_includes report.to_s, "caso de otra cuenta"

    assert_equal opening.message, opening_row[:message]
    assert_equal "¿Cómo evalúa la intensidad del ruido?", opening_row[:published_text]
    assert_equal({}, opening_row[:checkpoint])
    assert_equal "Ruido fuerte en el motor de tracción", opening_row.dig(:trace, :interpretation, :observed_state, "goal", "text")
    assert_equal false, opening_row.dig(:trace, :interpretation, :checkpoint_matches_observed)
    assert_equal "uncaptured", opening_row.dig(:trace, :query, :provenance)
    dialogue = opening_row.dig(:trace, :entry, :interpreter_input)
    assert_equal opening.message, dialogue["turn"]
    assert_nil dialogue.dig("work_context", "recent_turns")

    assert_equal corrected.message, corrected_row[:message]
    assert_equal ABSTENTION, corrected_row[:published_text]
    assert_equal [], corrected_row[:citations]
    assert_equal [ 1, 2 ], corrected_row.dig(:trace, :attempts)
    history = corrected_row.dig(:trace, :entry, :interpreter_input)
    assert_equal corrected.message, history["turn"]
    assert_equal %w[técnico Danebo técnico], history.dig("work_context", "recent_turns").pluck("role")
    assert_equal "El valor de kp-cs es 2,5", history.dig("work_context", "recent_turns", 2, "text")
    assert_not_includes history.dig("work_context", "recent_turns").pluck("text"), corrected.message
    assert_equal [ "kp-cs es 2,5" ], corrected_row.dig(:trace, :interpretation, :changes, "observations", "removed")
    assert_equal [ "KP-VS es 2,5" ], corrected_row.dig(:trace, :interpretation, :changes, "observations", "added")
    assert_equal "¿Cómo evalúa la intensidad del ruido?", corrected_row.dig(:trace, :interpretation, :observed_state, "pending_question", "text")
    assert_equal true, corrected_row.dig(:trace, :interpretation, :checkpoint_matches_observed)
    assert_equal [ FIRST_QUERY, FIRST_QUERY, SECOND_QUERY, SECOND_QUERY ], corrected_row.dig(:trace, :query, :steps).pluck(:effective)
    assert_equal FILTER, corrected_row.dig(:trace, :query, :steps, 1, :filter)
    assert_includes corrected_row.dig(:trace, :query, :uncaptured), "query_rewrite"
    assert_includes corrected_row.dig(:trace, :evidence, :pages), 18
    assert_includes corrected_row.dig(:trace, :evidence, :uncaptured), "rerank"
    guard = corrected_row.dig(:trace, :publication, :citation_guard)
    assert_equal "unbacked_citation", guard.dig(0, "removed", 0, "reason")
    assert_operator guard.first["sequence"], :<, corrected_row.dig(:trace, :publication, :publication_decision, "sequence")
    assert_equal ABSTENTION, corrected_row.dig(:trace, :publication, :published_text)
    assert_not_equal corrected_row.dig(:trace, :publication, :model_output), ABSTENTION

    assert_equal "missing", stored_row.dig(:trace, :status)
    assert_equal "La respuesta guardada.", stored_row[:published_text]
    assert_equal [ { "page" => 7, "title" => "Manual" } ], stored_row[:citations]
    assert_includes stored_row.dig(:trace, :uncaptured), "publication"
    assert_equal "sin traza", stored_row.dig(:checkpoint, "goal", "text")

    interaction = report.dig(:interactions, :by_correlation).find { |row| row[:correlation_id] == corrected.correlation_id }
    assert_equal corrected.message, interaction[:question]
    assert_equal ABSTENTION, interaction[:answer]
    assert_equal corrected.id, interaction[:field_turn_id]
    assert_not_includes report[:session_archive].pluck(:correlation_id), corrected.correlation_id
    assert_not_includes report[:session_archive].pluck(:content), "placa que no debe duplicarse"
    legacy_row = report[:session_archive].find { |row| row[:correlation_id] == legacy && row[:role] == "user" }
    assert_equal "pregunta anterior sin caso", legacy_row[:content]
    assert_includes report.dig(:data_quality, :limits), "Device capture only records the web channel, so desktop and mobile cannot be distinguished."
  end

  private

  ABSTENTION = "No hay evidencia citada para confirmar ese ajuste."
  FIRST_QUERY = "El valor de KP-VS es 2,5 kp-cs es 2,5 El valor de kp-cs es 2,5"
  SECOND_QUERY = "El valor de KP-VS es 2,5"
  FILTER = { "equals" => { "key" => "manufacturer", "value" => "Thyssen" } }.freeze

  def finish_turn(kase, message:, published_text:, citations:, checkpoint:, technical_state:)
    admitted = admit(kase, message: message)
    assert admitted.ok?, admitted.error.inspect
    closed = close_turn(
      kase, admitted.turn,
      published_text: published_text,
      citations: citations,
      checkpoint: checkpoint,
      technical_state: technical_state
    )
    assert closed.ok?, closed.error.inspect
    closed.turn
  end

  def opening_state
    {
      "goal" => { "text" => "Ruido fuerte en el motor de tracción" },
      "pending_question" => { "text" => "¿Cómo evalúa la intensidad del ruido?" }
    }
  end

  def corrected_state
    {
      "goal" => { "text" => "Ruido fuerte en el motor de tracción" },
      "facts" => { "controller" => { "value" => "MCINV4", "source" => "user" } },
      "observations" => [ { "text" => "KP-VS es 2,5" } ],
      "pending_question" => { "text" => "¿Cómo evalúa la intensidad del ruido?" }
    }
  end

  def capture_opening(turn)
    write_capture(turn, 1, [
      event(turn, 1, "interpreter_request", "structured" => {
        "turn" => turn.message,
        "work_context" => { "pending_question" => "¿Cómo evalúa la intensidad del ruido?" }
      }),
      event(turn, 2, "interpreter_raw", "tool_input" => { "move" => "meta" }),
      event(turn, 3, "perception_applied", "rule" => "meta_incompatible"),
      event(turn, 4, "episode_delta", "episode_after" => opening_state, "changed" => true)
    ])
  end

  def capture_correction(turn)
    write_capture(turn, 1, [
      event(turn, 1, "interpreter_request", "structured" => {
        "turn" => turn.message,
        "work_context" => {
          "recent_turns" => [
            { "role" => "técnico", "text" => "kp-cs en el controlador MCINV4" },
            { "role" => "Danebo", "text" => "¿Cómo evalúa la intensidad del ruido?" },
            { "role" => "técnico", "text" => "El valor de kp-cs es 2,5" }
          ]
        }
      }),
      event(turn, 2, "interpreter_raw", "tool_input" => { "move" => "report" }),
      event(turn, 3, "perception_applied", "rule" => "supersede_corrected_parameter"),
      event(turn, 4, "episode_delta",
        "episode_before" => corrected_state.merge("observations" => [ { "text" => "kp-cs es 2,5" } ]),
        "episode_after" => corrected_state,
        "observations" => { "removed" => [ "kp-cs es 2,5" ], "added" => [ "KP-VS es 2,5" ] },
        "pending_question" => {
          "before" => "¿Cómo evalúa la intensidad del ruido?",
          "after" => "¿Cómo evalúa la intensidad del ruido?"
        }),
      event(turn, 5, "effective_query",
        "sent_turn" => turn.message,
        "composed" => "El valor de KP-VS es 2,5 kp-cs es 2,5",
        "effective" => FIRST_QUERY,
        "components" => { "observations" => "kp-cs es 2,5" }),
      event(turn, 6, "retrieve",
        "retrieval_query" => { "text" => FIRST_QUERY },
        "retrieval_configuration" => { "vector_search_configuration" => { "filter" => FILTER } }),
      event(turn, 7, "retrieve", "retrieval_query" => { "text" => SECOND_QUERY }),
      event(turn, 8, "retrieval_results", "query" => FIRST_QUERY, "rows" => [ { "page" => 18 } ]),
      event(turn, 9, "companion_sources", "kept" => [
        { "page" => 18, "content" => "En caso de ruido audible muy elevado: disminuya el valor del parámetro KP-VS." }
      ]),
      event(turn, 10, "companion_direct", "text" => "Conviene disminuir \"KP-VS\". El técnico reporta 2,5."),
      event(turn, 11, "companion_claim_backing", "removed" => [
        { "sentence" => "Conviene disminuir \"KP-VS\".", "reason" => "unbacked_citation" }
      ], "text" => "El técnico reporta 2,5."),
      event(turn, 12, "companion_publication", "accepted" => false, "reasons" => [ "citations_empty" ])
    ])
    write_capture(turn, 2, [
      event(turn, 1, "retrieve", "retrieval_query" => { "text" => SECOND_QUERY })
    ])
  end

  def event(turn, sequence, kind, payload)
    { "kind" => kind, "sequence" => sequence, "correlation_id" => turn.correlation_id }.merge(payload)
  end

  def write_capture(turn, attempt, events)
    FieldCompanionTrace.create!(
      account_id: turn.field_case.account_id,
      user_id: turn.field_case.user_id,
      correlation_id: turn.correlation_id,
      episode_id: turn.field_case.episode_id,
      kind: "capture",
      provenance: "observed",
      occurred_at: Time.current,
      attempt: attempt,
      idempotency_key: "capture:#{turn.correlation_id}:#{attempt}",
      deployed_version: "test",
      payload: { "events" => events }
    )
  end

  def durable_answer(turn, text)
    FieldCompanionTrace.create!(
      account_id: turn.field_case.account_id,
      user_id: turn.field_case.user_id,
      correlation_id: turn.correlation_id,
      kind: "assistant_message",
      provenance: "observed",
      occurred_at: Time.current,
      attempt: 1,
      idempotency_key: "assistant:#{turn.correlation_id}",
      deployed_version: "test",
      payload: { "literal" => text, "role" => "assistant" }
    )
  end

  def pilot_event(turn)
    PilotEvent.create!(
      account_id: turn.field_case.account_id,
      user_id: turn.field_case.user_id,
      correlation_id: turn.correlation_id,
      event: "interaction_completed",
      occurred_at: Time.current,
      payload: { "outcome" => "abstained", "route" => "rag" }
    )
  end

  def legacy_session(user, duplicated_correlation)
    legacy = "query:#{SecureRandom.uuid}"
    now = Time.current.iso8601
    ConversationSession.create!(
      identifier: "web:field-dialogue:#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 1.day.from_now,
      user: user,
      account: user.account,
      conversation_history: [
        { "role" => "user", "content" => "pregunta anterior sin caso", "correlation_id" => legacy, "user_id" => user.id, "ts" => now },
        { "role" => "assistant", "content" => "respuesta anterior sin caso", "correlation_id" => legacy, "user_id" => user.id, "ts" => now },
        { "role" => "assistant", "content" => "placa que no debe duplicarse", "correlation_id" => duplicated_correlation, "user_id" => user.id, "ts" => now }
      ]
    )
    legacy
  end

  def turn_row(threads, correlation_id)
    found = threads.flat_map { |thread| thread[:turns] }.find { |row| row[:correlation_id] == correlation_id }
    assert found, "missing field turn #{correlation_id}"
    found
  end
end
