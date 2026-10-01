# frozen_string_literal: true

require "test_helper"

class RagControllerTechnicalUnderstandingTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = users(:two)
    @account = accounts(:climb)
    host! "ascensoresclimb.localhost"
    @episode_flag = ENV["FIELD_COMPANION_EPISODE_ENABLED"]
    ENV["FIELD_COMPANION_EPISODE_ENABLED"] = "true"
    sign_in @user
    web_session.update!(document_focus: [], active_episode: {}, conversation_history: [])
  end

  teardown do
    if @episode_flag.nil?
      ENV.delete("FIELD_COMPANION_EPISODE_ENABLED")
    else
      ENV["FIELD_COMPANION_EPISODE_ENABLED"] = @episode_flag
    end
  end

  test "Q2 without context asks once and does not retrieve" do
    queries = []
    retrieves = []
    body = ask("¿Qué es Q2?", queries: queries, retrieves: retrieves)

    assert_empty queries
    assert_empty retrieves
    assert_includes body["answer"], "puede significar"
    assert_nil body["manual_suggestion"]
    assert_empty web_session.reload.document_focus_entries
    assert_equal "controller", web_session.active_episode.dig("pending_question", "type")
  end

  test "Monarch NICE3000 continues the same work and the next Q2 searches" do
    ask("¿Qué es Q2?")
    queries = []
    named = ask("Es Monarch NICE3000", queries: queries)

    assert_equal 1, queries.size
    assert_match(/NICE3000/i, queries.first)
    assert_match(/MONARCH/i, queries.first)
    assert_not_includes named["answer"], "puede significar"
    assert_empty web_session.reload.document_focus_entries

    queries = []
    again = ask("¿Qué es Q2?", queries: queries)
    assert_equal 1, queries.size
    assert_match(/Q2/, queries.first)
    assert_match(/NICE3000/, queries.first)
    assert_not_includes again["answer"], "puede significar"
    assert_empty web_session.reload.document_focus_entries
  end

  test "no se busca con eso searches and does not define Q2 as universal" do
    ask("¿Qué es Q2?")
    queries = []
    body = ask(
      "No sé, busca con eso",
      queries: queries,
      orchestrator: { answer: "Q2 es un terminal.", citations: [], session_id: "best" }
    )

    assert_equal 1, queries.size
    assert_match(/Q2/, queries.first)
    assert_includes body["answer"], "No puedo confirmar"
    assert_not_includes body["answer"], "puede significar"
    assert_empty web_session.reload.document_focus_entries
    assert_equal "unknown_confirmed", web_session.active_episode.dig("facts", "controller", "status")
  end

  test "Q2 missing from the selected manual asks and does not suggest the first global hit" do
    manual = KbDocument.create!(
      s3_key: "uploads/2026/technical-q2.pdf", document_uid: SecureRandom.uuid,
      display_name: "Plano local", aliases: [], account: @account
    )
    web_session.pin_kb_document!(manual)
    queries = []
    retrieves = []
    body = ask(
      "¿Qué es Q2?",
      queries: queries,
      retrieves: retrieves,
      orchestrator: {
        answer: "El documento no incluye este dato.",
        citations: [],
        route_outcome: "abstained",
        session_id: "focus"
      }
    )

    assert_equal 1, queries.size
    assert_empty retrieves
    assert_includes body["answer"], "En este manual no encuentro"
    assert_nil body["manual_suggestion"]
    assert_equal [ manual.id ], web_session.reload.document_focus_entries.pluck("kb_document_id")
  end

  test "ROS missing from the selected manual asks and does not retrieve outside" do
    manual = KbDocument.create!(
      s3_key: "uploads/2026/technical-ros.pdf", document_uid: SecureRandom.uuid,
      display_name: "Plano local ROS", aliases: [], account: @account
    )
    web_session.pin_kb_document!(manual)
    retrieves = []
    body = ask(
      "¿Qué es ROS?",
      retrieves: retrieves,
      orchestrator: {
        answer: "El documento no incluye este dato.",
        citations: [],
        route_outcome: "abstained",
        session_id: "ros"
      }
    )

    assert_empty retrieves
    assert_includes body["answer"], "ROS"
    assert_includes body["answer"], "En este manual no encuentro"
    assert_nil body["manual_suggestion"]
    assert_equal [ manual.id ], web_session.reload.document_focus_entries.pluck("kb_document_id")
  end

  test "VF5 with Elemont selected still offers the VF5 manual" do
    elemont = catalog_row("MH")
    vf5 = catalog_row("VF5+")
    web_session.pin_kb_document!(elemont)
    queries = []
    body = ask("¿Cómo uso el módulo electrónico VF5?", queries: queries)

    assert_equal 1, queries.size
    assert_not_includes body["answer"], "puede significar"
    assert_equal [ vf5.document_uid ], body.dig("manual_suggestion", "cards").pluck("document_uid")
    assert_equal [ elemont.id ], web_session.reload.document_focus_entries.pluck("kb_document_id")
  end

  private

  def ask(question, queries: [], retrieves: [], orchestrator: nil)
    with_orchestrator(queries, orchestrator) do
      with_retrieve_counter(retrieves) do
        post rag_ask_path, params: { question: question }, as: :json
      end
    end
    assert_response :success
    response.parsed_body
  end

  def web_session
    ConversationSession.find_or_create_for(
      identifier: @user.id.to_s, channel: "web", user_id: @user.id, account_id: @account.id
    )
  end

  def catalog_row(designator)
    entry = Rag::DocumentIdentityCatalog.current.entries.find { |row| Array(row.designators).include?(designator) }
    KbDocument.create!(
      s3_key: entry.s3_key, document_uid: entry.document_id,
      display_name: entry.display_name, aliases: [], account: @account
    )
  end

  def with_orchestrator(queries, orchestrator)
    original = QueryOrchestratorService.method(:new)
    payload = orchestrator || { answer: "Respuesta de prueba.", citations: [], session_id: "understanding" }
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

  def with_retrieve_counter(calls)
    original = BedrockRagService.instance_method(:retrieve_chunks)
    BedrockRagService.define_method(:retrieve_chunks) do |text, **_kwargs|
      calls << text
      { chunks: [] }
    end
    yield
  ensure
    BedrockRagService.define_method(:retrieve_chunks) { |*args, **kwargs| original.bind_call(self, *args, **kwargs) }
  end
end
