# frozen_string_literal: true

require "test_helper"

class EquipmentManualFocusTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  ELEMONT_UID = "dcc8e046-037d-48a6-8913-1992aed28507"

  setup do
    @user = users(:two)
    @account = accounts(:climb)
    host! "ascensoresclimb.localhost"
    sign_in @user
  end

  test "the equipment card is offered, confirmed, and the next query stays on that pin" do
    assert_equal 0, Rag::Stage2RunBudget::PASS_CALL_CAP
    document = catalog_document("MH")
    session = web_session
    discovery_calls = 0
    result = Rag::DocumentDiscovery.call(
      question: "El equipo es un Elemont MH.",
      viewer_account: @account,
      session: session,
      retriever: lambda { |*|
        discovery_calls += 1
        { chunks: [] }
      }
    )

    card = result.cards.sole
    assert_equal 0, discovery_calls
    assert_equal ELEMONT_UID, card.document_uid
    assert_equal document.id, card.kb_document_id
    assert_not_equal 213, card.kb_document_id
    assert_equal "Elemont Montacargas Hidraulico Modelo MH", card.display_name
    assert_equal "add", result.action
    assert_nil result.payload[:selected_document_uid]
    assert_empty session.reload.document_focus_entries
    assert_equal "open", retrieval_scope([]).reason
    assert_equal false, retrieval_scope([]).force_entity_filter

    assert_no_enqueued_jobs only: TrackBedrockQueryJob do
      declare_equipment(session, "equip:open")
    end
    session.reload
    assert_equal "Elemont", session.active_episode.dig("facts", "manufacturer", "value")
    assert_includes identifier_values(session), "Elemont MH"
    assert_nil session.active_episode["pending_question"]
    assert_empty session.document_focus_entries
    episode_id = session.live_episode_id
    assert episode_id.present?
    assert_not_equal "ep_063f3f66656047d2", episode_id

    assert_enqueued_jobs 1, only: DocumentOverviewWarmJob do
      post_card(document, episode_id: episode_id)
    end
    assert_response :success
    body = response.parsed_body
    assert_equal "focused", body["status"]
    assert_equal [ document.id ], body["focus_ids"]
    session.reload
    entry = session.document_focus_entries.sole
    assert_equal ConversationSession::DOCUMENT_FOCUS_KEYS.sort, entry.keys.sort
    uri = document.display_s3_uri(KbDocument::KB_BUCKET)
    assert_equal uri, entry["source_uri"]
    assert_nil session.active_episode.dig("facts", "compatibility")

    assert_no_enqueued_jobs only: DocumentOverviewWarmJob do
      post_card(document, episode_id: episode_id)
    end
    assert_response :success
    assert_equal "already_focused", response.parsed_body["status"]
    assert_equal 1, session.reload.document_focus_entries.size

    scope = retrieval_scope([ uri ])
    assert_equal "pin_only", scope.reason
    assert_equal true, scope.force_entity_filter
    assert_equal [ uri ], scope.uris
    focus_before = session.document_focus
    query = empty_pin_query(scope)

    assert_equal 1, query[:retrieves].size
    assert_equal [ uri ], Array(query[:retrieves].first[:entity_s3_uris])
    assert_equal true, query[:retrieves].first[:force_entity_filter]
    assert query[:retrieves].none? { |call| Array(call[:entity_s3_uris]).empty? }
    assert_includes query[:result][:answer], I18n.t("rag.pinned_focus_empty", locale: :es)
    assert_equal focus_before, session.reload.document_focus
  end

  test "the writer episode offers and confirms MH and the later query follows that identity" do
    document = catalog_document("MH")
    session = web_session
    declare_equipment(session, "equip:writer-shape")
    session.reload
    assert_equal "Elemont", session.active_episode.dig("facts", "manufacturer", "value")
    assert_equal "user", session.active_episode.dig("facts", "manufacturer", "source")
    assert_nil session.active_episode.dig("facts", "model")
    assert_includes identifier_values(session), "Elemont MH"
    identity = Rag::EquipmentIdentity.from_episode(session.active_episode)
    assert identity.known?
    assert_equal "Elemont", identity.manufacturer
    assert_nil identity.facts.find { |fact| fact["slot"] == "model" }

    calls = 0
    result = Rag::DocumentDiscovery.call(
      question: "El equipo es un Elemont MH.",
      viewer_account: @account,
      session: session,
      retriever: lambda { |*|
        calls += 1
        { chunks: [] }
      }
    )
    card = result.cards.sole
    assert_equal 0, calls
    assert_equal ELEMONT_UID, card.document_uid
    assert_equal document.id, card.kb_document_id
    assert_nil result.payload[:selected_document_uid]
    assert_empty session.document_focus_entries

    post_card(document, episode_id: session.live_episode_id)
    assert_response :success
    session.reload
    uri = document.display_s3_uri(KbDocument::KB_BUCKET)
    entry = session.document_focus_entries.sole
    assert_equal document.id, entry["kb_document_id"]
    assert_equal uri, entry["source_uri"]
    focus_before = session.document_focus

    isolate_env("DOCUMENT_IDENTITY_SCOPE_ENABLED", "false") do
      closed = identity_query(session, uri)
      assert_equal [], closed[:retrieves]
      assert_equal "scope_disabled", closed[:result][:equipment_identity_reason]
      assert_equal focus_before, session.reload.document_focus
    end

    isolate_env("DOCUMENT_IDENTITY_SCOPE_ENABLED", "true") do
      scoped = identity_query(session, uri)
      assert_equal 1, scoped[:retrieves].size
      assert_equal [ uri ], Array(scoped[:retrieves].first[:entity_s3_uris])
      assert_equal true, scoped[:retrieves].first[:force_entity_filter]
      assert_equal 0, scoped[:open_generations]
      assert_equal focus_before, session.reload.document_focus
    end
  end

  test "a new observation that keeps the equipment designator still confirms the card" do
    document = catalog_document("MH")
    session = web_session
    declare_equipment(session, "equip:open-chapa")
    with_owner do
      ask_turn(
        session,
        "Veo Chapa nivel 3.",
        perception("report", assertions: [ assertion("Chapa nivel 3", "assert") ]),
        "equip:chapa"
      )
    end
    session.reload
    assert_includes identifier_values(session), "Elemont MH"
    assert_includes identifier_values(session), "Chapa nivel 3"
    assert_equal "Elemont", session.active_episode.dig("facts", "manufacturer", "value")

    post_card(document, episode_id: session.live_episode_id)

    assert_response :success
    assert_equal [ document.id ], session.reload.focus_document_ids
  end

  test "an identity correction does not confirm the old card and does not drop a pin" do
    document = catalog_document("MH")
    session = web_session
    declare_equipment(session, "equip:open-correct")
    episode_id = session.reload.live_episode_id
    post_card(document, episode_id: episode_id)
    assert_equal [ document.id ], session.reload.focus_document_ids

    with_owner do
      ask_turn(
        session,
        "No es Elemont MH.",
        perception("correct", assertions: [ assertion("Elemont MH", "negate") ]),
        "equip:correct"
      )
    end
    session.reload
    assert_equal episode_id, session.live_episode_id
    assert_not_includes identifier_values(session), "Elemont MH"
    assert_not Rag::DocumentDiscovery.equipment_candidate?(
      session: session, document: document, viewer_account: @account
    )
    assert_equal [ document.id ], session.focus_document_ids

    post_card(document, episode_id: episode_id, model: "MH", designator: "MH", candidate: true)

    assert_response :unprocessable_entity
    assert_equal I18n.t("rag.manual_focus_invalid"), response.parsed_body["error"]
    assert_equal [ document.id ], session.reload.focus_document_ids
    assert_nil session.active_episode.dig("facts", "compatibility")
  end

  test "a changed episode does not confirm the old card" do
    document = catalog_document("MH")
    session = web_session
    declare_equipment(session, "equip:open-episode")
    episode_id = session.reload.live_episode_id
    with_owner do
      ask_turn(
        session,
        "Es otro ascensor, marca KONE.",
        perception("new_work", assertions: [ assertion("KONE", "assert") ]),
        "equip:new"
      )
    end
    session.reload
    assert_not_equal episode_id, session.live_episode_id

    post_card(document, episode_id: episode_id)

    assert_response :unprocessable_entity
    assert_empty session.reload.document_focus_entries
  end

  test "a missing episode id does not confirm the equipment card" do
    document = catalog_document("MH")
    session = web_session
    declare_equipment(session, "equip:open-missing")

    post_card(document)

    assert_response :unprocessable_entity
    assert_empty session.reload.document_focus_entries
  end

  test "a mismatched uid does not confirm inside the lock" do
    document = catalog_document("MH")
    session = web_session
    declare_equipment(session, "equip:open-uid")
    session.reload

    posted = session.confirm_equipment_manual!(
      document,
      expected_episode_id: session.live_episode_id,
      document_uid: SecureRandom.uuid,
      viewer_account: @account
    )

    assert_equal false, posted
    assert_empty session.reload.document_focus_entries

    post_card(document, episode_id: session.live_episode_id, document_uid: SecureRandom.uuid)
    assert_response :unprocessable_entity
    assert_empty session.reload.document_focus_entries
  end

  test "authorization revoked inside the lock does not confirm" do
    document = catalog_document("MH")
    session = web_session
    declare_equipment(session, "equip:open-auth")
    calls = []
    original = Rag::KnowledgeScopePolicy.method(:authorized?)
    Rag::KnowledgeScopePolicy.define_singleton_method(:authorized?) do |row, **kwargs|
      calls << row.id
      calls.size == 1 ? original.call(row, **kwargs) : false
    end

    post_card(document, episode_id: session.reload.live_episode_id)

    assert_response :not_found
    assert_equal I18n.t("rag.manual_focus_unavailable"), response.parsed_body["error"]
    assert_operator calls.size, :>=, 2
    assert_empty session.reload.document_focus_entries
  ensure
    if original
      Rag::KnowledgeScopePolicy.define_singleton_method(:authorized?) { |*args, **kwargs|
        original.call(*args, **kwargs)
      }
    end
  end

  test "a known model MH+ does not confirm the MH equipment manual" do
    document = catalog_document("MH")
    session = web_session
    declare_equipment(session, "equip:open-model")
    session.reload
    episode = Rag::ActiveEpisode.parse(session.active_episode)
    episode.write_fact!(
      "model",
      status: "known",
      value: "MH",
      source: "user",
      correlation_id: "equip:model-mh",
      at: Time.current.iso8601
    )
    session.update!(active_episode: episode.to_h)
    assert Rag::DocumentDiscovery.equipment_candidate?(
      session: session, document: document, viewer_account: @account
    )

    episode.write_fact!(
      "model",
      status: "known",
      value: "MH+",
      source: "user",
      correlation_id: "equip:model-plus",
      at: Time.current.iso8601
    )
    session.update!(active_episode: episode.to_h)

    assert_not Rag::DocumentDiscovery.equipment_candidate?(
      session: session, document: document, viewer_account: @account
    )
    post_card(document, episode_id: session.live_episode_id, model: "MH", designator: "MH")

    assert_response :unprocessable_entity
    assert_empty session.reload.document_focus_entries
  end

  test "a component manual is not an equipment candidate" do
    equipment = catalog_document("MH")
    component = catalog_document("CEA15+")
    session = web_session
    declare_equipment(session, "equip:open-component")
    session.reload

    assert Rag::DocumentDiscovery.equipment_candidate?(
      session: session, document: equipment, viewer_account: @account
    )
    assert_not Rag::DocumentDiscovery.equipment_candidate?(
      session: session, document: component, viewer_account: @account
    )
  end

  test "a library pin of the equipment manual does not require an episode" do
    document = catalog_document("MH")

    post pinned_documents_path, params: { kb_document_id: document.id }

    assert_response :no_content
    assert_equal [ document.id ], web_session.focus_document_ids
    assert_nil web_session.live_episode_id
  end

  private

  def declare_equipment(session, correlation)
    with_owner do
      ask_turn(
        session,
        "El equipo es un Elemont MH.",
        perception("report", assertions: [ assertion("Elemont MH", "assert") ]),
        correlation
      )
    end
  end

  def ask_turn(session, text, response, correlation)
    session.record_user_turn!(
      text,
      user_id: @user.id,
      correlation_id: correlation,
      interpreter_client: client(response)
    )
  end

  def post_card(document, episode_id: :omit, **extra)
    params = {
      kb_document_id: document.id,
      document_uid: extra.key?(:document_uid) ? extra.delete(:document_uid) : document.document_uid,
      focus_mode: "add"
    }
    params[:episode_id] = episode_id unless episode_id == :omit
    post pinned_documents_path, params: params.merge(extra), as: :json
  end

  def identity_query(session, uri)
    service = BedrockRagService.new(account: @account, knowledge_base_id: "test-kb")
    retrieves = []
    open_generations = 0
    service.define_singleton_method(:retrieve_chunks) do |*, **kwargs|
      retrieves << kwargs
      { chunks: [], retrieval_trace: {} }
    end
    service.define_singleton_method(:retrieve_and_generate_with_retry) do |_params|
      open_generations += 1
      flunk "pinned identity query must not open another retrieve"
    end
    generator = Object.new
    generator.define_singleton_method(:query) { |_prompt, **| "Sin evidencia nueva." }
    service.define_singleton_method(:document_identity_generator) { generator }
    result = service.query(
      "¿Dónde está el contactor?",
      episode: session.active_episode,
      entity_s3_uris: [ uri ],
      force_entity_filter: true,
      output_channel: :web,
      response_locale: :es
    )
    { result: result, retrieves: retrieves, open_generations: open_generations }
  end

  def retrieval_scope(uris)
    Object.new.extend(RagQueryConcern).send(:resolve_retrieval_scope, pinned_uris: uris)
  end

  def empty_pin_query(scope)
    service = BedrockRagService.new(account: @account, knowledge_base_id: "test-kb")
    retrieves = []
    service.define_singleton_method(:retrieve_chunks) do |*, **kwargs|
      retrieves << kwargs
      { chunks: [], retrieval_trace: {} }
    end
    service.define_singleton_method(:retrieve_and_generate_with_retry) { |_params|
      flunk "empty pin retrieval must not open another generation retrieve"
    }
    generator = Object.new
    generator.define_singleton_method(:query) { |_prompt, **| "Sin evidencia nueva." }
    service.define_singleton_method(:document_identity_generator) { generator }
    result = service.query(
      "¿Dónde está el contactor?",
      equipment_identity: nil,
      entity_s3_uris: scope.uris,
      force_entity_filter: scope.force_entity_filter,
      output_channel: :web,
      response_locale: :es
    )
    { result: result, retrieves: retrieves }
  end

  def identifier_values(session)
    Array(session.active_episode["identifiers"]).pluck("value")
  end

  def web_session
    ConversationSession.find_or_create_for(
      identifier: @user.id.to_s,
      channel: "web",
      user_id: @user.id,
      account_id: @account.id
    )
  end

  def catalog_document(designator)
    entry = Rag::DocumentIdentityCatalog.current.entries.find { |row|
      Array(row.designators).include?(designator)
    }
    KbDocument.create!(
      account: @account,
      s3_key: entry.s3_key,
      document_uid: entry.document_id,
      display_name: entry.display_name,
      aliases: []
    )
  end

  def with_owner(&block)
    isolate_env("FIELD_COMPANION_EPISODE_ENABLED", "true") do
      isolate_env("FIELD_COMPANION_TURN_ENABLED", "true") do
        isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "owner", &block)
      end
    end
  end

  def perception(move, assertions: [], observations: [])
    {
      "move" => move,
      "assertions" => assertions,
      "observations" => observations,
      "pending_resolution" => nil,
      "clarification_target" => nil
    }
  end

  def assertion(span, act)
    { "span" => span, "act" => act }
  end

  def client(response)
    ScriptedPerceptionClient.new(response)
  end

  class ScriptedPerceptionClient
    def initialize(response)
      @response = response
    end

    def converse(_params)
      tool = Struct.new(:name, :input).new("turn_perception", @response)
      block = Struct.new(:tool_use).new(tool)
      message = Struct.new(:content).new([ block ])
      output = Struct.new(:message).new(message)
      usage = Struct.new(:input_tokens, :output_tokens).new(0, 0)
      Struct.new(:output, :usage).new(output, usage)
    end
  end
end
