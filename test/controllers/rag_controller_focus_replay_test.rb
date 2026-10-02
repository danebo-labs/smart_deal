# frozen_string_literal: true

require "test_helper"

class RagControllerFocusReplayTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = users(:one)
    @account = @user.account
    @episode_flag = ENV["FIELD_COMPANION_EPISODE_ENABLED"]
    ENV["FIELD_COMPANION_EPISODE_ENABLED"] = "true"
    @first = manual("uploads/2026/replay-a.pdf", "Manual A")
    @second = manual("uploads/2026/replay-b.pdf", "Manual B")
    sign_in @user
    @session = ConversationSession.find_or_create_for(
      identifier: @user.id.to_s, channel: "web", user_id: @user.id, account_id: @account.id
    )
    @session.pin_kb_document!(@first)
    @session.pin_kb_document!(@second)
    @correlation = "query:replay-q2"
    @session.record_user_turn!("¿Qué es Q2?", user_id: @user.id, correlation_id: @correlation)
    @session.stamp_user_retrieval_query!(@correlation, "Q2 en los manuales seleccionados")
    @episode_id = @session.reload.live_episode_id
  end

  teardown do
    if @episode_flag.nil?
      ENV.delete("FIELD_COMPANION_EPISODE_ENABLED")
    else
      ENV["FIELD_COMPANION_EPISODE_ENABLED"] = @episode_flag
    end
  end

  test "replay uses the stored query and does not open another turn" do
    queries = []
    haiku = []
    user_turns = []
    with_counters(queries, haiku, user_turns) do
      post rag_ask_path, params: { replay_correlation_id: @correlation }, as: :json
    end

    assert_response :success
    body = response.parsed_body
    assert_equal false, body["reused"]
    assert_equal "Respuesta del manual nuevo.", body["answer"]
    assert_equal [ "Q2 en los manuales seleccionados" ], queries
    assert_empty haiku
    assert_empty user_turns
    assert_equal @episode_id, @session.reload.live_episode_id
    assert_equal 1, user_messages.size
    assert_equal "Q2 en los manuales seleccionados", @session.user_message_for(@correlation)["retrieval_query"]
    assert_equal @session.focus_document_ids.sort, assistant_messages.sole["focus_ids"]
  end

  test "the same focus is not retrieved again even when the ids are reversed" do
    queries = []
    with_orchestrator(queries) do
      post rag_ask_path, params: { replay_correlation_id: @correlation }, as: :json
      assert_response :success
      @session.reload
      @session.update!(document_focus: @session.document_focus.reverse)
      post rag_ask_path, params: { replay_correlation_id: @correlation }, as: :json
    end

    assert_response :success
    assert_equal true, response.parsed_body["reused"]
    assert_equal 1, queries.size
    assert_equal 1, user_messages.size
    assert_equal 1, assistant_messages.size
  end

  test "a different focus retrieves once more" do
    queries = []
    with_orchestrator(queries) do
      post rag_ask_path, params: { replay_correlation_id: @correlation }, as: :json
      @session.reload.replace_document_focus!(@second)
      post rag_ask_path, params: { replay_correlation_id: @correlation }, as: :json
    end

    assert_response :success
    assert_equal false, response.parsed_body["reused"]
    assert_equal 2, queries.size
    assert_equal 1, user_messages.size
    assert_equal [ @second.id ], @session.reload.focus_document_ids
    assert_equal [ @second.id ], assistant_messages.last["focus_ids"]
  end

  test "owner mode replay does not call the turn interpreter or add a bubble" do
    calls = []
    original = Rag::TurnInterpreter.method(:call)
    Rag::TurnInterpreter.define_singleton_method(:call) do |**kwargs|
      calls << kwargs
      original.call(**kwargs)
    end
    isolate_env("HAIKU_QUERY_ANALYSIS_MODE", "owner") do
      queries = []
      haiku = []
      user_turns = []
      with_counters(queries, haiku, user_turns) do
        post rag_ask_path, params: { replay_correlation_id: @correlation }, as: :json
      end
      assert_response :success
      assert_empty calls
      assert_empty user_turns
      assert_equal 1, user_messages.size
    end
  ensure
    Rag::TurnInterpreter.define_singleton_method(:call) { |**kwargs| original.call(**kwargs) }
  end

  test "a missing turn does not retrieve" do
    queries = []
    with_orchestrator(queries) do
      post rag_ask_path, params: { replay_correlation_id: "query:missing" }, as: :json
    end

    assert_response :unprocessable_entity
    assert_empty queries
    assert_equal [ @first.id, @second.id ].sort, @session.reload.focus_document_ids.sort
  end

  private

  def manual(key, name)
    KbDocument.create!(
      s3_key: key, display_name: name, document_uid: SecureRandom.uuid,
      aliases: [], account: @account
    )
  end

  def user_messages
    @session.reload.conversation_history.select { |row| row["role"] == "user" && row["correlation_id"] == @correlation }
  end

  def assistant_messages
    @session.reload.conversation_history.select { |row| row["role"] == "assistant" && row["correlation_id"] == @correlation }
  end

  def with_orchestrator(queries)
    original = QueryOrchestratorService.method(:new)
    QueryOrchestratorService.define_singleton_method(:new) do |query, **_kwargs|
      queries << query
      service = Object.new
      service.define_singleton_method(:execute) do
        { answer: "Respuesta del manual nuevo.", citations: [], session_id: "replay" }
      end
      service
    end
    yield
  ensure
    QueryOrchestratorService.define_singleton_method(:new) { |*args, **kwargs| original.call(*args, **kwargs) }
  end

  def with_counters(queries, haiku, user_turns)
    observe = Rag::SemanticQueryAnalyzer.method(:observe)
    ownership = Rag::SemanticQueryAnalyzer.method(:observe_ownership)
    user_turn = ConversationSession.instance_method(:record_user_turn!)
    Rag::SemanticQueryAnalyzer.define_singleton_method(:observe) do |**kwargs|
      haiku << :observe
      observe.call(**kwargs)
    end
    Rag::SemanticQueryAnalyzer.define_singleton_method(:observe_ownership) do |**kwargs|
      haiku << :ownership
      ownership.call(**kwargs)
    end
    ConversationSession.define_method(:record_user_turn!) do |*args, **kwargs|
      user_turns << :user
      user_turn.bind_call(self, *args, **kwargs)
    end
    with_orchestrator(queries) { yield }
  ensure
    Rag::SemanticQueryAnalyzer.define_singleton_method(:observe) { |**kwargs| observe.call(**kwargs) }
    Rag::SemanticQueryAnalyzer.define_singleton_method(:observe_ownership) { |**kwargs| ownership.call(**kwargs) }
    ConversationSession.define_method(:record_user_turn!) { |*args, **kwargs| user_turn.bind_call(self, *args, **kwargs) }
  end
end
