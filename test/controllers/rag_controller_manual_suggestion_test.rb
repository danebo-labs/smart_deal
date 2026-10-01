# frozen_string_literal: true

require "test_helper"

class RagControllerManualSuggestionTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = users(:two)
    @account = accounts(:climb)
    host! "ascensoresclimb.localhost"
  end

  test "a brand without a designator or a dominant citation is not a card" do
    body = nil
    with_pin_tracker do |pin_calls|
      body = ask("Estoy en un OTIS y tengo este problema.")
      assert_equal 0, pin_calls[:n]
    end

    assert_nil body["manual_suggestion"]
    assert_empty web_session.document_focus_entries
  end

  test "Monarch NICE3000 offers that manual without selecting it" do
    entry = Rag::DocumentIdentityCatalog.current.entries.find { |row| Array(row.designators).include?("NICE3000") }
    document = KbDocument.create!(
      s3_key: entry.s3_key,
      document_uid: entry.document_id,
      display_name: entry.display_name,
      aliases: [],
      account: @account
    )
    body = nil
    with_pin_tracker do |pin_calls|
      body = ask("Es Monarch / NICE3000.")
      assert_equal 0, pin_calls[:n]
    end

    card = body.dig("manual_suggestion", "cards").sole
    assert_equal document.document_uid, card["document_uid"]
    assert_equal document.id, card["kb_document_id"]
    assert_equal false, card["focused"]
    assert_equal "add", card["action"]
    assert_equal "Dejar este manual seleccionado", body.dig("manual_suggestion", "focus_action")
    assert_not_includes body["answer"], card["display_name"]
    assert_empty web_session.document_focus_entries
    assert_suggestion_telemetry([ document.document_uid ], [ "tenant_private" ])
  end

  test "an outside card is not a citation while another manual stays selected" do
    monarch = catalog_row("NICE3000")
    elemont = catalog_row("MH")
    sign_in @user
    ConversationSession.find_or_create_for(
      identifier: @user.id.to_s,
      channel: "web",
      user_id: @user.id,
      account_id: @account.id
    ).pin_kb_document!(elemont)
    body = ask(
      "Es Monarch / NICE3000.",
      orchestrator: {
        answer: "En Elemont no está.",
        citations: [ { "title" => elemont.display_name, "filename" => "elemont.pdf" } ],
        doc_refs: [ { "source_uri" => elemont.display_s3_uri(KbDocument::KB_BUCKET) } ],
        session_id: "suggestion"
      }
    )

    titles = Array(body["citations"]).pluck("title")
    assert_not_includes titles, monarch.display_name
    assert_not_includes body["answer"], monarch.display_name
    assert_equal [ monarch.document_uid ], body.dig("manual_suggestion", "cards").pluck("document_uid")
    assert_equal [ elemont.id ], web_session.reload.document_focus_entries.pluck("kb_document_id")
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

  def ask(question, queries: [], orchestrator: nil)
    sign_in @user
    with_orchestrator(queries, orchestrator) do
      post rag_ask_path, params: { question: question }, as: :json
    end
    assert_response :success
    response.parsed_body
  end

  def catalog_row(designator)
    entry = Rag::DocumentIdentityCatalog.current.entries.find { |row| Array(row.designators).include?(designator) }
    KbDocument.create!(
      s3_key: entry.s3_key,
      document_uid: entry.document_id,
      display_name: entry.display_name,
      aliases: [],
      account: @account
    )
  end

  def web_session
    ConversationSession.find_by!(identifier: @user.id.to_s, channel: "web", account_id: @account.id)
  end

  def with_orchestrator(queries, orchestrator = nil)
    original = QueryOrchestratorService.method(:new)
    payload = orchestrator || { answer: "Respuesta de prueba.", citations: [], session_id: "suggestion" }
    QueryOrchestratorService.define_singleton_method(:new) do |query, **_kwargs|
      queries << query
      service = Object.new
      service.define_singleton_method(:execute) { payload }
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
