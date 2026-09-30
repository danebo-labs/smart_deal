# frozen_string_literal: true

require "test_helper"

class RagControllerManualSuggestionTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = users(:two)
    @account = accounts(:climb)
    host! "ascensoresclimb.localhost"
  end

  test "owned unclassified manuals are suggested without writing a pin" do
    question = "Estoy en un OTIS y tengo este problema."
    scored = Rag::ManualCandidateRanker.score(question, Rag::DocumentIdentityCatalog.current.entries)
    owned = scored.candidates.first(2)
    owned.each_with_index do |candidate, index|
      KbDocument.create!(
        s3_key: "uploads/suggestion/#{candidate.document_id}.pdf",
        document_uid: candidate.document_id,
        display_name: "Owned #{index}",
        aliases: [],
        account: @account
      )
    end
    body = nil
    session = nil
    with_pin_tracker do |pin_calls|
      body = ask(question)
      session = web_session

      assert_equal 0, pin_calls[:n]
    end

    cards = body.dig("manual_suggestion", "cards")
    assert_equal owned.map(&:document_id), cards.pluck("document_uid")
    assert_equal [ "tenant_private", "tenant_private" ], cards.pluck("knowledge_scope")
    assert_equal [ Rag::ManualCandidateRanker::PRIVATE_PROVENANCE, Rag::ManualCandidateRanker::PRIVATE_PROVENANCE ],
      cards.pluck("provenance")
    assert_equal [ "BRAND_ONLY", "BRAND_ONLY" ], cards.pluck("label")
    assert cards.all? { |card| card["text"] == Rag::ManualCandidateRanker::BRAND_ONLY_TEXT }
    assert_equal true, body.dig("manual_suggestion", "tie_at_top")
    assert_nil body.dig("manual_suggestion", "selected_document_uid")
    assert_not_includes body["answer"], Rag::ManualCandidateRanker::BRAND_ONLY_TEXT
    assert_equal({}, session.active_entities)
    assert_suggestion_telemetry(owned.map(&:document_id), [ "tenant_private", "tenant_private" ])
  end

  test "an unclassified document owned by another account is not suggested" do
    question = "Estoy en un OTIS y tengo este problema."
    candidate = Rag::ManualCandidateRanker.score(question, Rag::DocumentIdentityCatalog.current.entries).candidates.first
    KbDocument.create!(
      s3_key: "uploads/suggestion/foreign-#{candidate.document_id}.pdf",
      document_uid: candidate.document_id,
      display_name: "Foreign",
      aliases: [],
      account: accounts(:legacy)
    )
    body = nil
    with_pin_tracker do |pin_calls|
      body = ask(question)
      assert_equal 0, pin_calls[:n]
    end

    assert_empty body.dig("manual_suggestion", "cards")
    assert_equal Rag::ManualCandidateRanker::EMPTY_TEXT, body.dig("manual_suggestion", "message")
    assert_nil body.dig("manual_suggestion", "selected_document_uid")
    assert_not_includes body["answer"], Rag::ManualCandidateRanker::EMPTY_TEXT
    assert_equal({}, web_session.active_entities)
  end

  test "a symptom without a manufacturer returns no cards and does not add a retrieve" do
    queries = []
    body = nil
    with_pin_tracker do |pin_calls|
      body = ask("Tengo un problema en la puerta.", queries: queries)
      assert_equal 0, pin_calls[:n]
    end

    assert_nil body["manual_suggestion"]
    assert_equal 1, queries.size
    assert_equal({}, web_session.active_entities)
  end

  private

  def ask(question, queries: [])
    sign_in @user
    with_orchestrator(queries) do
      post rag_ask_path, params: { question: question }, as: :json
    end
    assert_response :success
    response.parsed_body
  end

  def web_session
    ConversationSession.find_by!(identifier: @user.id.to_s, channel: "web", account_id: @account.id)
  end

  def with_orchestrator(queries)
    original = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) do |query, **_kwargs|
      queries << query
      service = Object.new
      service.define_singleton_method(:execute) { { answer: "Respuesta de prueba.", citations: [], session_id: "suggestion" } }
      service
    end
    yield
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*args, **kwargs| original.call(*args, **kwargs) }
  end

  def with_pin_tracker
    calls = { n: 0 }
    original = ConversationSession.instance_method(:pin_kb_document!)
    ConversationSession.define_method(:pin_kb_document!) do |*_args, **_kwargs|
      calls[:n] += 1
      false
    end
    yield calls
  ensure
    ConversationSession.define_method(:pin_kb_document!) { |*args, **kwargs| original.bind_call(self, *args, **kwargs) }
  end

  def assert_suggestion_telemetry(uids, scopes)
    row = PilotEvent.where(event: "manual_suggestion_shown").order(:id).last
    assert row, "manual_suggestion_shown must be recorded"
    payload = row.payload.with_indifferent_access
    assert_equal uids, payload[:suggestion_document_uids]
    assert_equal scopes, payload[:suggestion_scopes]
    assert_nil payload[:knowledge_scope]
  end
end
