# frozen_string_literal: true

require "test_helper"
require_relative "../../support/companion_plan_response"

class Rag::CompanionPinnedWindowTest < ActiveSupport::TestCase
  PIN = "s3://multimodal-source-destination/bulk_uploads/1/2026-08-31/VF5.pdf"
  RAW = "¿qué sigue?"
  COMPOSED = "COMPUESTA la puerta abrió despacio"
  Row = Struct.new(:index, :relevance_score)
  Response = Struct.new(:results, :next_token)

  test "a pinned companion turn retrieves sixteen, orders them with Cohere, and caps narrative" do
    kept = "COHERE_MANTIENE Fermator"
    dropped = "HIBRIDO_CAE #{'a' * 15_990}"
    other = "OTRO_CAE #{'c' * 800}"
    chunks = [
      window_chunk(dropped, score: 0.9, sha: "sha-hibrido"),
      window_chunk(kept, score: 0.2, sha: "sha-cohere"),
      window_chunk(other, score: 0.5, sha: "sha-otro")
    ]
    retrieved = []
    reranks = []
    prompts = []
    flag = ENV["BEDROCK_RERANKER_ENABLED"]
    ENV["BEDROCK_RERANKER_ENABLED"] = "false"

    result = with_companion_scope do
      ask(chunks, retrieved: retrieved, reranks: reranks, prompts: prompts, episode: known_episode)
    end

    assert_equal 16, retrieved.first[:number_of_results]
    assert_equal [ PIN ], retrieved.first[:entity_s3_uris]
    assert_equal true, retrieved.first[:force_entity_filter]
    assert_equal 1, reranks.size
    assert_equal COMPOSED, reranks.first.dig(:queries, 0, :text_query, :text)
    assert_equal [ dropped, kept, other ], reranks.first[:sources].map { |source|
      source.dig(:inline_document_source, :text_document, :text)
    }
    assert_equal 3, reranks.first.dig(:reranking_configuration, :bedrock_reranking_configuration, :number_of_results)
    assert_equal "BEDROCK_RERANKING_MODEL", reranks.first.dig(:reranking_configuration, :type)
    assert_not retrieved.first.key?(:reranking_configuration)
    assert_includes prompts.first, kept
    assert_not_includes prompts.first, "HIBRIDO_CAE"
    assert_not_includes prompts.first, "OTRO_CAE"
    citation = result[:retrieved_citations].find { |row| row[:content] == kept }
    assert_equal PIN, citation.dig(:location, :uri)
    assert_not result[:retrieved_citations].any? { |row| row[:content] == dropped }
    assert_equal "false", ENV["BEDROCK_RERANKER_ENABLED"]
    assert_equal true, result[:companion_turn]
    profile = RagRetrievalProfile.new(entity_sources: [ "document" ], question: COMPOSED)
    assert_empty service_for.send(:reranking_config, "us-east-1", profile: profile)
  ensure
    restore_env("BEDROCK_RERANKER_ENABLED", flag)
  end

  test "a denied companion rerank keeps the retrieved order and still answers" do
    first = "PRIMERO_HIBRIDO Fermator"
    second = "SEGUNDO_HIBRIDO Fermator"
    prompts = []
    denied = Aws::BedrockAgentRuntime::Errors::AccessDeniedException.new(
      Seahorse::Client::RequestContext.new,
      "not authorized to perform: bedrock:Rerank"
    )

    result = with_companion_scope do
      ask(
        [ window_chunk(first, score: 0.9, sha: "sha-primero"), window_chunk(second, score: 0.4, sha: "sha-segundo") ],
        retrieved: [],
        reranks: [],
        prompts: prompts,
        episode: known_episode,
        rerank_error: denied
      )
    end

    assert_equal "scoped", result[:equipment_identity_status]
    assert_not_equal "service_unavailable", result[:generation_mode]
    assert_not_equal I18n.t("rag.service_unavailable", locale: :es), result[:answer]
    assert_includes prompts.first, first
    assert_operator prompts.first.index(first), :<, prompts.first.index(second)
  end

  test "a pinned plan question keeps the pinned retrieve count and does not rerank" do
    retrieved = []
    reranks = []

    with_companion_scope do
      ask(
        [ window_chunk("Manual Fermator estable.", score: 0.4, sha: "sha-uno") ],
        retrieved: retrieved,
        reranks: reranks,
        prompts: [],
        episode: known_episode,
        raw_question: "Según el plano, ¿dónde está el contactor?"
      )
    end

    assert_equal RagRetrievalProfile::PINNED_DOCUMENT_RESULTS, retrieved.first[:number_of_results]
    assert_empty reranks
  end

  private

  def ask(chunks, retrieved:, reranks:, prompts:, episode:, raw_question: RAW, rerank_error: nil)
    service = service_for
    service.define_singleton_method(:retrieve_chunks) do |_query, **kwargs|
      retrieved << kwargs
      { chunks: chunks, retrieval_trace: {}, retrieval: "retrieve" }
    end
    client = Object.new
    client.define_singleton_method(:rerank) do |payload|
      reranks << payload
      raise rerank_error if rerank_error

      Response.new([ Row.new(1, 0.9), Row.new(0, 0.1), Row.new(2, 0.05) ], nil)
    end
    service.instance_variable_set(:@client, client)
    generator = Object.new
    generator.define_singleton_method(:query) do |user, **|
      prompts << user
      "respuesta documental"
    end
    generator.define_singleton_method(:last_stop_reason) { "end_turn" }
    generator.define_singleton_method(:converse) do |params|
      prompts << params[:messages].first[:content].first[:text]
      CompanionPlanResponse.build({ "links" => [], "steps" => [], "question" => "" })
    end
    service.define_singleton_method(:document_identity_generator) { generator }
    session = session_for(episode)
    service.send(
      :document_identity_scope_result,
      COMPOSED,
      episode: episode,
      response_locale: :es,
      entity_s3_uris: [ PIN ],
      entity_sources: [ "document" ],
      force_entity_filter: true,
      account_id: accounts(:legacy).id,
      user_id: users(:one).id,
      conversation_session_id: session.id,
      correlation_id: "query:window",
      raw_question: raw_question,
      conv_session: session
    )
  end

  def service_for
    BedrockRagService.new(account: accounts(:legacy), knowledge_base_id: "kb-test")
  end

  def window_chunk(content, score:, sha:)
    {
      rank: 1,
      content: content,
      score: score,
      metadata: {
        "account_id" => accounts(:legacy).id.to_s,
        "document_id" => "vf5",
        "canonical_name" => "Manual Fermator",
        "original_source_uri" => PIN,
        "page_number" => "8"
      },
      original_source_uri: PIN,
      location_uri: PIN,
      chunk_sha256: sha
    }
  end

  def known_episode
    now = Time.current
    episode = Rag::ActiveEpisode.open(correlation_id: "case", now: now)
    episode.assign_goal!("La puerta abrió despacio", correlation_id: "case")
    episode.write_fact!(
      "manufacturer", status: "known", value: "Fermator", source: "user",
      correlation_id: "case", at: now.iso8601
    )
    episode
  end

  def session_for(episode)
    ConversationSession.create!(
      identifier: "web:companion-window-#{SecureRandom.hex(4)}",
      channel: "web",
      expires_at: 1.hour.from_now,
      user: users(:one),
      account: accounts(:legacy),
      active_episode: episode&.to_h || {}
    )
  end

  def with_companion_scope
    previous = {
      "DOCUMENT_IDENTITY_SCOPE_ENABLED" => ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"],
      "RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE" => ENV["RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE"],
      "RAG_COMPANION_TURN" => ENV["RAG_COMPANION_TURN"]
    }
    ENV["DOCUMENT_IDENTITY_SCOPE_ENABLED"] = "true"
    ENV["RAG_COMPANION_TURN"] = "1"
    ENV.delete("RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE")
    yield
  ensure
    previous.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  def restore_env(key, value)
    value.nil? ? ENV.delete(key) : ENV[key] = value
  end
end
