# frozen_string_literal: true

require "test_helper"

class ManualFocusConfirmationTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  setup do
    @user = users(:two)
    @account = accounts(:climb)
    host! "ascensoresclimb.localhost"
    sign_in @user
  end

  test "an authorized own card pins that row and records server scope" do
    document = own_manual("own-card.pdf", "Own card")

    assert_no_difference [ "KbDocument.count", "KnowledgeScopeChange.count" ] do
      confirm(document, correlation_id: "query:own", knowledge_scope: "danebo_general", authorized: true)
    end

    assert_response :ok
    assert_equal "Manual enfocado", response.parsed_body["message"]
    assert_equal document.id, response.parsed_body["kb_document_id"]
    meta = pinned_meta(web_session, document)
    assert_equal ConversationSession::DOCUMENT_FOCUS_KEYS, meta.keys.sort
    assert_equal document.display_name, meta["display_name"]
    assert_equal document.display_s3_uri(KbDocument::KB_BUCKET), meta["source_uri"]
    event = focus_event("manual_focus_confirmed")
    assert_equal document.document_uid, event.payload["document_id"]
    assert_equal document.display_s3_uri(KbDocument::KB_BUCKET), event.payload["source_uri"]
    assert_equal "tenant_private", event.payload["knowledge_scope"]
    assert_equal "query:own", event.payload["correlation_id"]
    assert_nil event.payload["authorized"]
    assert_equal 0, PilotEvent.where(event: "manual_focus_denied").count
  end

  test "a second tap says the manual is already focused and does not emit another confirmation" do
    document = own_manual("already.pdf", "Already")
    confirm(document)
    assert_difference -> { PilotEvent.where(event: "manual_focus_confirmed").count }, 0 do
      confirm(document)
    end

    assert_response :ok
    assert_equal "already_focused", response.parsed_body["status"]
    assert_equal "Este manual ya está enfocado.", response.parsed_body["message"]
    assert_equal 1, web_session.document_focus_entries.size
  end

  test "a suggestion-card re-pin renews added_at and still answers already focused" do
    document = own_manual("renew-focus.pdf", "Renew focus")
    other = own_manual("renew-other.pdf", "Renew other")
    first_at = Time.zone.parse("2026-09-30 09:00:00")
    second_at = first_at + 3.hours

    travel_to(first_at) do
      confirm(document)
      confirm(other)
    end

    travel_to(second_at) do
      assert_no_enqueued_jobs only: DocumentOverviewWarmJob do
        assert_no_difference -> { PilotEvent.where(event: "manual_focus_confirmed").count } do
          confirm(document)
        end
      end
    end

    assert_response :ok
    assert_equal "already_focused", response.parsed_body["status"]
    session = web_session
    assert_equal 2, session.document_focus_entries.size
    assert_equal second_at.to_i, Time.zone.parse(pinned_meta(session, document)["added_at"]).to_i
    assert_equal first_at.to_i, Time.zone.parse(pinned_meta(session, other)["added_at"]).to_i
  end

  test "an authorized general card pins the existing row without a copy" do
    shared = general_manual("shared-card.pdf")
    owner_session = ConversationSession.create!(
      identifier: users(:one).id.to_s, channel: "web", expires_at: 1.day.from_now,
      user: users(:one), account: shared.account
    )
    before_batches = WebManualBatch.count

    assert_no_difference "KbDocument.count" do
      assert_enqueued_jobs 0, only: BedrockIngestionJob do
        confirm(shared)
      end
    end

    assert_response :ok
    assert_equal shared.id, pinned_meta(web_session, shared)["kb_document_id"]
    assert_equal "danebo_general", shared.reload.knowledge_scope
    assert_equal accounts(:legacy).id, shared.account_id
    assert_equal before_batches, WebManualBatch.count
    assert_empty owner_session.reload.document_focus_entries
    assert_equal "danebo_general", focus_event("manual_focus_confirmed").payload["knowledge_scope"]
    assert Rag::KnowledgeScopePolicy.authorized?(shared, viewer_account: @account)
  end

  test "a foreign private card is denied without content and without a pin" do
    foreign = KbDocument.create!(
      account: accounts(:legacy), s3_key: "manuals/foreign-private-card.pdf",
      display_name: "Foreign private body", document_uid: SecureRandom.uuid, aliases: []
    )

    assert_no_difference "KbDocument.count" do
      confirm(foreign, knowledge_scope: "danebo_general", authorized: true)
    end

    assert_response :not_found
    assert_equal "Este manual ya no está disponible.", response.parsed_body["error"]
    assert_not_includes response.body, foreign.display_name
    assert_not_includes response.body, foreign.s3_key
    assert_not_includes response.body, "tenant_private"
    assert_not_includes response.body, "danebo_general"
    assert_nil web_session_if_any
    assert_nil focus_event("manual_focus_confirmed")
    assert_equal "unavailable", focus_event("manual_focus_denied").payload["outcome_reason"]
  end

  test "a foreign private row is excluded by the initial lookup before final authorization" do
    foreign = KbDocument.create!(
      account: accounts(:legacy), s3_key: "manuals/foreign-private-lookup.pdf",
      display_name: "Foreign private lookup", document_uid: SecureRandom.uuid, aliases: []
    )
    authorization_calls = 0
    allow_everything = lambda do |*_args, **_kwargs|
      authorization_calls += 1
      true
    end

    original = Rag::KnowledgeScopePolicy.method(:authorized?)
    begin
      Rag::KnowledgeScopePolicy.define_singleton_method(:authorized?, allow_everything)
      confirm(foreign)
    ensure
      Rag::KnowledgeScopePolicy.define_singleton_method(:authorized?) { |*args, **kwargs|
        original.call(*args, **kwargs)
      }
    end

    assert_response :not_found
    assert_equal 0, authorization_calls
    assert_equal "Este manual ya no está disponible.", response.parsed_body["error"]
    assert_nil web_session_if_any
    assert_nil focus_event("manual_focus_confirmed")
  end

  test "a revoked card cannot be pinned" do
    shared = general_manual("revoked-card.pdf")
    KnowledgeScopeChange.apply!(
      kb_document: shared, to_scope: "tenant_private", actor: "ops", reason: "withdrawn"
    )

    confirm(shared)

    assert_response :not_found
    assert_equal "Este manual ya no está disponible.", response.parsed_body["error"]
    assert_nil web_session_if_any
    assert_nil focus_event("manual_focus_confirmed")
  end

  test "a mismatched uid cannot pin an authorized row" do
    document = own_manual("mismatch.pdf", "Mismatch")

    confirm(document, uid: SecureRandom.uuid)

    assert_response :unprocessable_entity
    assert_equal "No pude seleccionar este manual.", response.parsed_body["error"]
    assert_nil web_session_if_any
    assert_nil focus_event("manual_focus_confirmed")
    assert_equal "invalid", focus_event("manual_focus_denied").payload["outcome_reason"]
  end

  test "the same uid on another account does not select that row" do
    uid = SecureRandom.uuid
    own = KbDocument.create!(
      account: @account, s3_key: "manuals/row-x.pdf", display_name: "Row X",
      document_uid: uid, aliases: []
    )
    other = KbDocument.create!(
      account: accounts(:legacy), s3_key: "manuals/row-y.pdf", display_name: "Row Y",
      document_uid: uid, aliases: []
    )

    confirm(own)

    assert_response :ok
    assert_equal own.id, pinned_meta(web_session, own)["kb_document_id"]
    assert_equal own.display_s3_uri(KbDocument::KB_BUCKET), pinned_meta(web_session, own)["source_uri"]
    assert_nil web_session.find_entity_by_kb_document_id(other.id)
    assert_equal 1, web_session.document_focus_entries.size
  end

  test "a failed tap leaves the previous pin in place" do
    kept = own_manual("kept.pdf", "Kept")
    other = own_manual("other.pdf", "Other")
    confirm(kept)

    confirm(other, uid: "not-the-row")

    assert_response :unprocessable_entity
    assert_equal [ kept.id ], web_session.reload.document_focus_entries.map { |meta| meta.fetch("kb_document_id") }
  end

  test "the pin is stored only on the session that confirmed it" do
    document = own_manual("session-only.pdf", "Session")
    peer = User.create!(email: "peer-#{SecureRandom.hex(4)}@example.com", password: "password123", account: @account)
    peer_session = ConversationSession.create!(
      identifier: peer.id.to_s, channel: "web", expires_at: 1.day.from_now,
      user: peer, account: @account
    )
    other_session = ConversationSession.create!(
      identifier: "other-web-#{SecureRandom.hex(4)}", channel: "web", expires_at: 1.day.from_now,
      user: @user, account: @account
    )
    foreign_session = ConversationSession.create!(
      identifier: users(:one).id.to_s, channel: "web", expires_at: 1.day.from_now,
      user: users(:one), account: accounts(:legacy)
    )

    confirm(document)

    assert_equal document.id, pinned_meta(web_session, document)["kb_document_id"]
    assert_empty peer_session.reload.document_focus_entries
    assert_empty other_session.reload.document_focus_entries
    assert_empty foreign_session.reload.document_focus_entries
  end

  test "removing focus works for a live pin, a revoked pin, and a deleted row" do
    live = own_manual("live-unpin.pdf", "Live")
    confirm(live)
    delete pinned_document_path(live.id), params: { document_uid: live.document_uid }, as: :json
    assert_response :ok
    assert_equal "Listo. Esta consulta ya no usa ese manual.", response.parsed_body["message"]
    assert_empty web_session.reload.document_focus_entries
    assert_equal "unpinned", focus_event("manual_suggestion_dismissed").payload["outcome"]
    assert_equal live.document_uid, focus_event("manual_suggestion_dismissed").payload["document_id"]

    revoked = general_manual("revoked-unpin-card.pdf")
    confirm(revoked)
    KnowledgeScopeChange.apply!(
      kb_document: revoked, to_scope: "tenant_private", actor: "ops", reason: "withdrawn"
    )
    delete pinned_document_path(revoked.id), params: { document_uid: revoked.document_uid }, as: :json
    assert_response :ok
    assert_empty web_session.reload.document_focus_entries
    assert revoked.reload.persisted?

    stale = own_manual("stale-unpin.pdf", "Stale")
    confirm(stale)
    stale_id = stale.id
    stale_uid = stale.document_uid
    stale.delete
    delete pinned_document_path(stale_id), params: { document_uid: stale_uid }, as: :json
    assert_response :ok
    assert_empty web_session.reload.document_focus_entries
  end

  test "a missing row cannot be pinned from a card" do
    post pinned_documents_path, params: { kb_document_id: 9_999_999, document_uid: SecureRandom.uuid }, as: :json

    assert_response :not_found
    assert_equal "Este manual ya no está disponible.", response.parsed_body["error"]
    assert_nil focus_event("manual_focus_confirmed")
  end

  test "a follow-up after the tap retrieves only the pinned document" do
    document = own_manual("follow-up.pdf", "Follow up")
    open_general = general_manual("open-not-used.pdf")
    body = nil
    with_identity(document, brands: [ "Otis" ]) do
      body, = ask("Estoy en un OTIS y tengo este problema.")
    end
    card = body.dig("manual_suggestion", "cards").find { |item| item["kb_document_id"] == document.id }
    assert_equal document.document_uid, card["document_uid"]
    assert_equal false, card["focused"]
    assert_nil body.dig("manual_suggestion", "selected_document_uid")
    assert_nil web_session.document_focus_entries.presence
    confirm(document, uid: card["document_uid"])
    _body, calls = ask("qué mantenimiento corresponde")
    scope = calls.last[:kwargs]

    assert_equal [ document.display_s3_uri(KbDocument::KB_BUCKET) ], scope[:entity_s3_uris]
    assert_equal true, scope[:force_entity_filter]
    assert_not_includes scope[:entity_s3_uris], open_general.canonical_uri

    client = FakeClient.new
    with_bedrock do
      with_client(client) do
        BedrockRagService.new(account: @account).query(
          "qué mantenimiento corresponde",
          entity_s3_uris: scope[:entity_s3_uris],
          force_entity_filter: true
        )
      end
    end

    sent = values_for(client.filter, "original_source_uri")
    assert_includes sent, document.canonical_uri
    assert_not_includes sent, open_general.canonical_uri
    assert_empty values_for(client.filter, "account_id")
    assert_equal 1, client.generate_calls
  end

  test "two pins are both sent and one revoked member denies the set without dropping pins" do
    first = own_manual("pin-x.pdf", "Pin X")
    shared = general_manual("pin-y.pdf")
    confirm(first)
    confirm(shared)
    KnowledgeScopeChange.apply!(
      kb_document: shared, to_scope: "tenant_private", actor: "ops", reason: "withdrawn"
    )
    uris = SessionContextBuilder.entity_s3_uris(web_session)
    client = FakeClient.new
    result = nil
    with_bedrock do
      with_client(client) do
        result = BedrockRagService.new(account: @account).query(
          "qué mantenimiento corresponde",
          entity_s3_uris: uris,
          force_entity_filter: true
        )
      end
    end

    both = [ first, shared ].map { |document| document.display_s3_uri(KbDocument::KB_BUCKET) }
    assert_equal both.sort, uris.sort
    assert_equal BedrockRagService::DENY_RETRIEVAL, result[:retrieval]
    assert_equal 0, client.generate_calls
    assert_equal 0, client.retrieve_calls
    assert_equal both.sort, SessionContextBuilder.entity_s3_uris(web_session.reload).sort
  end

  test "a revoked foreign pin denies retrieval and contributes no metadata to a later question" do
    shared = general_manual("revoked-focus-notice.pdf")
    confirm(shared)
    KnowledgeScopeChange.apply!(
      kb_document: shared, to_scope: "tenant_private", actor: "ops", reason: "withdrawn"
    )

    uris = SessionContextBuilder.entity_s3_uris(web_session)
    client = FakeClient.new
    result = nil
    with_bedrock do
      with_client(client) do
        result = BedrockRagService.new(account: @account).query(
          "Estoy en un OTIS Y9 y la puerta no cierra.",
          entity_s3_uris: uris,
          force_entity_filter: true
        )
      end
    end

    assert_equal BedrockRagService::DENY_RETRIEVAL, result[:retrieval]
    assert_equal 0, client.generate_calls
    assert_equal 0, client.retrieve_calls

    body = nil
    with_identity(shared, brands: [ "Schindler" ], designators: [ "X1" ]) do
      body, = ask("Estoy en un OTIS Y9 y la puerta no cierra.")
    end

    assert_nil body["pin_conflict"]
    assert_nil focus_event("equipment_switch_prompted")
    assert_equal [ shared.display_s3_uri(KbDocument::KB_BUCKET) ],
      SessionContextBuilder.entity_s3_uris(web_session.reload)
  end

  test "two authorized pins do not fall back to the open corpus" do
    first = own_manual("both-x.pdf", "Both X")
    second = own_manual("both-y.pdf", "Both Y")
    confirm(first)
    confirm(second)
    _body, calls = ask("qué mantenimiento corresponde")
    uris = calls.last[:kwargs][:entity_s3_uris]
    client = FakeClient.new
    with_bedrock do
      with_client(client) do
        BedrockRagService.new(account: @account).query(
          "qué mantenimiento corresponde",
          entity_s3_uris: uris,
          force_entity_filter: calls.last[:kwargs][:force_entity_filter]
        )
      end
    end

    sent = values_for(client.filter, "original_source_uri")
    assert_equal [ first.canonical_uri, second.canonical_uri ].sort, sent.sort
    assert_empty values_for(client.filter, "account_id")
    assert_equal true, calls.last[:kwargs][:force_entity_filter]
  end

  test "tie cards and a symptom do not pin by themselves" do
    body, = ask("Estoy en un OTIS y tengo este problema.")
    assert_nil body.dig("manual_suggestion", "selected_document_uid")
    Array(body.dig("manual_suggestion", "cards")).each do |card|
      assert_equal false, card["focused"]
    end
    assert_nil web_session_if_any&.document_focus_entries&.presence

    symptom, = ask("Tengo un problema en la puerta.")
    assert_nil symptom["manual_suggestion"]
    assert_nil web_session_if_any&.document_focus_entries&.presence
  end

  test "a pin conflict is shown and the previous pin stays" do
    document = own_manual("conflict.pdf", "Manual Schindler")
    confirm(document)
    catalog = Rag::DocumentIdentityCatalog.new({
      "documents" => [
        {
          "account_id" => @account.id.to_s,
          "document_id" => document.document_uid,
          "s3_key" => document.s3_key,
          "display_name" => document.display_name,
          "brands" => [ "Schindler" ],
          "designators" => [],
          "confirmed" => false
        }
      ]
    })
    body = nil
    Rag::DocumentIdentityCatalog.with_catalog(catalog) do
      body, = ask("Estoy en un OTIS y la puerta no cierra.")
    end

    assert_includes body.dig("pin_conflict", "message"), "Otis"
    assert_includes body.dig("pin_conflict", "message"), "Schindler"
    assert_equal document.id, pinned_meta(web_session.reload, document)["kb_document_id"]
    event = focus_event("equipment_switch_prompted")
    assert_equal "otis", event.payload["manufacturer"]
    assert_equal "pin_conflict", event.payload["outcome_reason"]
    assert_nil event.payload["previous_manufacturer"]
  end

  test "an identity conflict shows both names and keeps the technician fact" do
    session = ConversationSession.find_or_create_for(
      identifier: @user.id.to_s, channel: "web", user_id: @user.id, account_id: @account.id
    )
    session.update!(active_episode: {
      "facts" => { "manufacturer" => { "status" => "known", "value" => "OTIS", "source" => "user" } },
      "conflicts" => [ { "fact" => "manufacturer", "user" => "OTIS", "photo" => "KONE" } ]
    })

    body, = ask("Tengo un problema en la puerta.")

    assert_includes body.dig("identity_conflict", "message"), "OTIS"
    assert_includes body.dig("identity_conflict", "message"), "KONE"
    assert_equal "OTIS", session.reload.active_episode.dig("facts", "manufacturer", "value")
    assert_equal "user", session.active_episode.dig("facts", "manufacturer", "source")
    assert_empty session.document_focus_entries
  end

  test "a photo observation does not replace the technician manufacturer" do
    previous = ENV["FIELD_COMPANION_EPISODE_ENABLED"]
    session = ConversationSession.create!(
      identifier: "photo-conflict-#{SecureRandom.hex(4)}", channel: "web",
      expires_at: 1.hour.from_now, user: users(:one), account: accounts(:legacy)
    )
    document = KbDocument.create!(
      account: accounts(:legacy), s3_key: "manuals/photo-pin.pdf", display_name: "Photo pin", aliases: []
    )
    session.pin_kb_document!(document)
    ENV["FIELD_COMPANION_EPISODE_ENABLED"] = "true"
    session.record_user_turn!("Cómo se ajustan los resortes de la fijación de cables ?", user_id: users(:one).id, correlation_id: "query:1")
    owner = session.live_episode_id
    session.record_assistant_turn!(
      "… ¿Qué marca y modelo es el equipo?", user_id: users(:one).id, correlation_id: "query:2", expected_episode_id: owner
    )
    session.record_user_turn!("Fuji Yida", user_id: users(:one).id, correlation_id: "query:3")
    session.record_photo_observation!(
      photo_value: {
        manufacturer: "KONE", model_visible: "UNKNOWN",
        target_visible: true, relevance_to_goal: "relevant"
      },
      field_photo_id: 42, sha256: "abc123", correlation_id: "photo:1", expected_episode_id: owner
    )

    session.reload
    assert_equal "Fuji Yida", session.active_episode.dig("facts", "manufacturer", "value")
    assert_equal "user", session.active_episode.dig("facts", "manufacturer", "source")
    assert_equal "KONE", session.active_episode["conflicts"].first["photo"]
    assert_equal "Fuji Yida", session.active_episode["conflicts"].first["user"]
    assert_equal document.id, pinned_meta(session, document)["kb_document_id"]
  ensure
    previous.nil? ? ENV.delete("FIELD_COMPANION_EPISODE_ENABLED") : ENV["FIELD_COMPANION_EPISODE_ENABLED"] = previous
  end

  private

  def own_manual(key, name)
    KbDocument.create!(
      account: @account, s3_key: "manuals/focus/#{key}", display_name: name,
      document_uid: SecureRandom.uuid, aliases: []
    )
  end

  def general_manual(key)
    owner = accounts(:legacy)
    owner.update!(danebo_controlled: true)
    document = KbDocument.create!(
      account: owner, s3_key: "manuals/focus/#{key}", display_name: "General #{key}",
      document_uid: SecureRandom.uuid, aliases: []
    )
    index_manual_for_retrieval!(document)
    KnowledgeScopeChange.apply!(
      kb_document: document, to_scope: "danebo_general", actor: "ops", reason: "approved manual"
    )
    document
  end

  def confirm(document, uid: document.document_uid, **extra)
    post pinned_documents_path, params: {
      kb_document_id: document.id,
      document_uid: uid,
      **extra
    }, as: :json
  end

  def ask(question)
    calls = nil
    body = nil
    with_orchestrator do |captured|
      post rag_ask_path, params: { question: question }, as: :json
      calls = captured
    end
    assert_response :success
    [ response.parsed_body, calls ]
  end

  def with_identity(document, brands:, designators: [])
    catalog = Rag::DocumentIdentityCatalog.new({
      "documents" => [
        {
          "account_id" => @account.id.to_s,
          "document_id" => document.document_uid,
          "s3_key" => document.s3_key,
          "display_name" => document.display_name,
          "brands" => brands,
          "designators" => designators,
          "confirmed" => false
        }
      ]
    })
    Rag::DocumentIdentityCatalog.with_catalog(catalog) { yield }
  end

  def with_orchestrator
    captured = []
    original = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) do |query, **kwargs|
      captured << { query: query, kwargs: kwargs }
      service = Object.new
      service.define_singleton_method(:execute) { { answer: "Respuesta de prueba.", citations: [], session_id: "focus" } }
      service
    end
    yield captured
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*args, **kwargs| original.call(*args, **kwargs) }
  end

  def web_session
    ConversationSession.find_by!(identifier: @user.id.to_s, channel: "web", account_id: @account.id)
  end

  def web_session_if_any
    ConversationSession.find_by(identifier: @user.id.to_s, channel: "web", account_id: @account.id)
  end

  def pinned_meta(session, document)
    session.document_focus_entries.find { |row| row["kb_document_id"] == document.id }
  end

  def focus_event(name)
    PilotEvent.where(event: name).order(:id).last
  end

  def with_bedrock
    previous = {
      "BEDROCK_KNOWLEDGE_BASE_ID" => ENV["BEDROCK_KNOWLEDGE_BASE_ID"],
      "AWS_REGION" => ENV["AWS_REGION"]
    }
    ENV["BEDROCK_KNOWLEDGE_BASE_ID"] = "test-kb-id"
    ENV["AWS_REGION"] = "us-east-1"
    yield
  ensure
    previous.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  def with_client(client)
    original = Aws::BedrockAgentRuntime::Client.method(:new)
    Aws::BedrockAgentRuntime::Client.define_singleton_method(:new) { |*| client }
    yield
  ensure
    Aws::BedrockAgentRuntime::Client.define_singleton_method(:new) { |*args, **kwargs| original.call(*args, **kwargs) }
  end

  def values_for(node, key)
    case node
    when Hash
      equals = node[:equals] || node["equals"]
      included = node[:in] || node["in"]
      found = []
      if equals && (equals[:key] || equals["key"]).to_s == key
        found << (equals[:value] || equals["value"]).to_s
      end
      if included && (included[:key] || included["key"]).to_s == key
        found.concat(Array(included[:value] || included["value"]).map(&:to_s))
      end
      found + node.flat_map { |_k, value| values_for(value, key) }
    when Array
      node.flat_map { |value| values_for(value, key) }
    else
      []
    end
  end

  class FakeClient
    attr_reader :filter, :generate_calls, :retrieve_calls

    def initialize
      @generate_calls = 0
      @retrieve_calls = 0
    end

    def retrieve(_params)
      @retrieve_calls += 1
      OpenStruct.new(retrieval_results: [])
    end

    def retrieve_and_generate(params)
      @generate_calls += 1
      @filter = params.dig(
        :retrieve_and_generate_configuration,
        :knowledge_base_configuration,
        :retrieval_configuration,
        :vector_search_configuration,
        :filter
      )
      OpenStruct.new(output: OpenStruct.new(text: "ok"), citations: [], session_id: "sid")
    end
  end
end
