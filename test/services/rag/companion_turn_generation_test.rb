# frozen_string_literal: true

require "test_helper"

class Rag::CompanionTurnGenerationTest < ActiveSupport::TestCase
  RAW = "¿qué sigue?"
  COMPOSED = "COMPUESTA_Z9 la puerta se reabre sola"
  PHOTOCELL = "Indicador LED y relé activado cuando la fotocélula o la entrada de re-apertura está activada."
  WHEN_QUOTE = "cuando la fotocélula o la entrada de re-apertura está activada"

  class ProbeController
    include RagQueryConcern
    attr_accessor :current_account
  end

  test "generation receives the technician message and retrieval receives the composed query" do
    episode = known_episode
    before = JSON.generate(episode.to_h)
    session = session_for(episode)
    history = session.conversation_history.deep_dup
    stored_episode = session.active_episode.deep_dup
    calls = []
    retrieved = []

    result = with_scope do
      with_companion do
        ask(episode, session, calls: calls, retrieved: retrieved, chunks: [ fermator_chunk(PHOTOCELL) ])
      end
    end

    assert_equal [ COMPOSED ], retrieved
    assert_equal 1, calls.size
    assert_includes calls.first[:user], "Mensaje del técnico:"
    assert_includes calls.first[:user], RAW
    assert_not_includes calls.first[:user], "COMPUESTA_Z9"
    assert_includes calls.first[:system], "una sola respuesta integrada"
    assert_equal 3000, calls.first[:max_tokens]
    assert_in_delta 0.1, calls.first[:temperature]
    assert_equal true, result[:companion_turn]
    assert_equal :answered, result[:route_outcome]
    assert_equal before, JSON.generate(episode.to_h)
    session.reload
    assert_equal stored_episode, session.active_episode
    assert_equal history, session.conversation_history
  end

  test "the opt-in off, a plan chunk, leftover records, and no compatible source keep the previous prompt" do
    episode = known_episode
    session = session_for(episode)
    off = plan = records = foreign = nil
    off_calls = plan_calls = record_calls = foreign_calls = nil

    with_scope do
      off_calls = []
      off = without_companion do
        ask(episode, session, chunks: [ fermator_chunk(PHOTOCELL) ], calls: off_calls, retrieved: [])
      end
      plan_calls = []
      plan = with_companion do
        ask(
          episode, session,
          chunks: [ fermator_chunk("RECORD_TYPE: TOPOLOGY_EDGE\n#{PHOTOCELL}") ],
          calls: plan_calls, retrieved: []
        )
      end
      record_calls = []
      records = with_companion do
        ask(
          episode, session,
          chunks: [ fermator_chunk("#{PHOTOCELL}\n\n# FIELD-SAFETY EVIDENCE RECORDS\n\nFIELD_RECORD:\nRECORD_TYPE: NOTE\nEND_FIELD_RECORD\n\nTexto posterior.") ],
          calls: record_calls, retrieved: []
        )
      end
      foreign_calls = []
      foreign = with_companion do
        ask(
          episode, session,
          chunks: [ fermator_chunk("Procedimiento Otis.", name: "Manual Otis") ],
          calls: foreign_calls, retrieved: []
        )
      end
    end

    [ off_calls, plan_calls, record_calls ].each do |calls|
      assert_equal 1, calls.size
      assert_nil calls.first[:system]
      assert_includes calls.first[:user], "COMPUESTA_Z9"
      assert_not_includes calls.first[:user], "Mensaje del técnico:"
    end
    assert_not off[:companion_turn]
    assert_not plan[:companion_turn]
    assert_includes record_calls.first[:user], "FIELD_RECORD"
    assert_not records[:companion_turn]
    assert_includes foreign_calls.first[:user], "# FIELD COMPANION"
    assert_not_includes foreign_calls.first[:user], "Mensaje del técnico:"
    assert_not foreign[:companion_turn]
  end

  test "an invalid contract publishes the fixed message and does not call again" do
    episode = known_episode
    calls = []

    result = with_scope do
      with_companion do
        ask(
          episode, session_for(episode),
          chunks: [ fermator_chunk(PHOTOCELL) ],
          calls: calls,
          retrieved: [],
          answer: "Según el manual, hay que ajustar el cierre."
        )
      end
    end

    assert_equal 1, calls.size
    assert_equal Rag::CompanionTurnPublication.abstain_message(:es), result[:answer]
    assert_not_includes result[:answer], "ajustar"
    assert_not_includes result[:answer], "Según el manual"
    assert_equal true, result[:companion_contract_invalid]
    assert_equal :abstained, result[:route_outcome]
    assert_equal "companion_contract_invalid", result[:companion_reason]
  end

  test "a valid companion answer is the history copy and a broken citation abstains" do
    episode = turn_episode
    session = session_for(episode)
    quote = "«#{WHEN_QUOTE}»"
    valid = "La página dice #{quote} [1]."
    controller = ProbeController.new
    controller.current_account = accounts(:legacy)

    published = deliver(controller, session, companion_result(valid, quotes: [ { "text" => WHEN_QUOTE } ]))
    stripped = deliver(
      controller, session,
      companion_result("# #{quote} [1]", quotes: [ { "text" => WHEN_QUOTE } ])
    )
    raw = "Según el manual, hay que ajustar el cierre."
    rejected = deliver(
      controller, session,
      companion_result(raw, accepted: false, quotes: [])
    )

    assert_equal valid, published.answer
    assert_equal valid, published.history_answer
    assert_not_includes published.answer, "Registro del caso"
    assert_equal Rag::CompanionTurnPublication.abstain_message(:es), stripped.answer
    assert_equal "", stripped.history_answer
    assert_equal :abstained, stripped.route_outcome
    assert_not_includes stripped.answer, WHEN_QUOTE
    assert_equal Rag::CompanionTurnPublication.abstain_message(:es), rejected.answer
    assert_equal "", rejected.history_answer
    assert_not_includes rejected.answer, "ajustar"
  end

  test "a companion reply longer than 600 characters is the stored prompt reply and the companion context" do
    body = "El cierre puede quedar pendiente. " * 30
    assert body.length > ConversationSession::MAX_MSG_LENGTH
    episode = turn_episode
    session = session_for(episode)
    session.record_user_turn!(RAW, user_id: users(:one).id, correlation_id: "case")
    session.record_assistant_turn!(
      body,
      user_id: users(:one).id,
      correlation_id: "case-reply",
      expected_episode_id: episode.episode_id,
      prompt_reply: body
    )
    session.reload
    stored = session.conversation_history.reverse.find { |row| row["role"] == "assistant" }

    assert_equal body, stored["prompt_reply"]
    assert_not stored.key?("prompt_reply_truncated")
    assert_equal ConversationSession::MAX_MSG_LENGTH, stored["content"].length
    context = SessionContextBuilder.companion_context(session)
    default_context = SessionContextBuilder.build(session)
    assert_includes context, body
    assert_not_includes default_context, body
  end

  test "both controller publication points pass the presented history answer" do
    source = Rails.root.join("app/controllers/rag_controller.rb").read
    assert_equal 2, source.scan("prompt_reply: result.history_answer").size
  end

  private

  def ask(episode, session, chunks:, calls:, retrieved:, answer: "El cierre puede quedar pendiente [1].")
    service = BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "kb-test")
    service.define_singleton_method(:retrieve_chunks) do |query, **|
      retrieved << query
      { chunks: chunks, retrieval_trace: {}, retrieval: "retrieve" }
    end
    generator = Object.new
    generator.define_singleton_method(:query) do |user, system: nil, max_tokens: nil, temperature: nil, **|
      calls << { user: user, system: system, max_tokens: max_tokens, temperature: temperature }
      answer
    end
    generator.define_singleton_method(:last_stop_reason) { "end_turn" }
    service.define_singleton_method(:document_identity_generator) { generator }
    service.send(
      :document_identity_scope_result,
      COMPOSED,
      episode: episode,
      response_locale: :es,
      entity_s3_uris: [],
      entity_sources: [],
      force_entity_filter: false,
      account_id: accounts(:legacy).id,
      user_id: users(:one).id,
      conversation_session_id: session.id,
      correlation_id: "query:companion",
      raw_question: RAW,
      conv_session: session
    )
  end

  def with_scope
    previous = {
      "DOCUMENT_IDENTITY_SCOPE_ENABLED" => ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"],
      "RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE" => ENV["RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE"]
    }
    ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"] = "true"
    ENV.delete("RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE")
    yield
  ensure
    previous.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  def without_companion
    previous = ENV["RAG_COMPANION_TURN"]
    ENV.delete("RAG_COMPANION_TURN")
    yield
  ensure
    previous.nil? ? ENV.delete("RAG_COMPANION_TURN") : ENV["RAG_COMPANION_TURN"] = previous
  end

  def with_companion
    previous = ENV["RAG_COMPANION_TURN"]
    ENV["RAG_COMPANION_TURN"] = "1"
    yield
  ensure
    previous.nil? ? ENV.delete("RAG_COMPANION_TURN") : ENV["RAG_COMPANION_TURN"] = previous
  end

  def known_episode
    now = Time.current
    episode = Rag::ActiveEpisode.open(correlation_id: "case", now: now)
    episode.assign_goal!("La puerta se reabre sola", correlation_id: "case")
    episode.write_fact!(
      "manufacturer", status: "known", value: "Fermator", source: "user",
      correlation_id: "case", at: now.iso8601
    )
    episode
  end

  def turn_episode
    episode = known_episode
    episode.append_observation!("El LED de fotocélula está encendido", correlation_id: "case")
    episode
  end

  def session_for(episode)
    ConversationSession.create!(
      identifier: "web:companion-gen-#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 1.hour.from_now,
      user: users(:one),
      account: accounts(:legacy),
      active_episode: episode.to_h
    )
  end

  def fermator_chunk(content, name: "Manual Fermator")
    {
      rank: 1,
      content: content,
      metadata: {
        "account_id" => accounts(:legacy).id.to_s,
        "document_id" => "vf5",
        "canonical_name" => name,
        "page_number" => 7
      },
      chunk_sha256: Digest::SHA256.hexdigest(content)
    }
  end

  def companion_result(answer, quotes:, accepted: true)
    {
      answer: accepted ? answer : answer,
      citations: [],
      retrieved_citations: [ { content: PHOTOCELL } ],
      session_id: "session-1",
      generation_mode: "document_identity_scope",
      route_outcome: accepted ? :answered : :abstained,
      companion_turn: true,
      companion_contract_invalid: !accepted,
      companion_reason: accepted ? nil : "companion_contract_invalid",
      companion_publication: {
        "accepted" => accepted,
        "reasons" => [],
        "signals" => [],
        "quotes" => quotes
      }
    }
  end

  def deliver(controller, session, payload)
    mock = Object.new
    mock.define_singleton_method(:execute) { payload }
    original = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) { |*_args, **_kwargs| mock }
    controller.send(:execute_rag_query, RAW, conv_session: session, account: accounts(:legacy))
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*args, **kwargs| original.call(*args, **kwargs) } if original
  end
end
