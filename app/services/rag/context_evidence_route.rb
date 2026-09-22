# frozen_string_literal: true

module Rag
  # One Retrieve on the short projection, a body filter, then one generation
  # on the original question. retrieve_and_generate cannot do that split: it
  # generates before the references are visible.
  class ContextEvidenceRoute
    def self.build(question:, account:, entity_s3_uris:, entity_sources:, response_locale:,
                   output_channel:, account_id: nil, user_id: nil, conversation_session_id: nil,
                   correlation_id: nil, rag_service: nil, generator: nil, expander: nil)
      return nil unless output_channel.to_s == "web"
      return nil if Array(entity_s3_uris).any?
      return nil unless ContextProjection.applicable?(question)

      new(
        question: question,
        account: account,
        entity_sources: entity_sources,
        response_locale: response_locale,
        account_id: account_id,
        user_id: user_id,
        conversation_session_id: conversation_session_id,
        correlation_id: correlation_id,
        rag_service: rag_service,
        generator: generator,
        expander: expander
      )
    end

    def initialize(question:, account:, entity_sources:, response_locale:, account_id: nil,
                   user_id: nil, conversation_session_id: nil, correlation_id: nil,
                   rag_service: nil, generator: nil, expander: nil)
      @question = question.to_s
      @account = account
      @entity_sources = Array(entity_sources)
      @response_locale = response_locale
      @account_id = account_id || account&.id
      @user_id = user_id
      @conversation_session_id = conversation_session_id
      @correlation_id = correlation_id
      @rag_service = rag_service || BedrockRagService.new(account: account)
      @generator = generator
      @expander = expander
    end

    def execute
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      retrieval = retrieve_projection
      return retrieval if retrieval.is_a?(StructuredEvidenceRoute::Outcome)

      retrieval_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      kept = Array(retrieval[:chunks]).select { |chunk| ContextChunkFilter.keep?(@question, chunk) }
      stack.complete_from_retrieval(retrieval.merge(chunks: kept), retrieval_ms: retrieval_ms)
    end

    private

    def stack
      StructuredEvidenceRoute.new(
        question: @question,
        account: @account,
        entity_s3_uris: [],
        entity_sources: @entity_sources,
        force_entity_filter: false,
        response_locale: @response_locale,
        account_id: @account_id,
        user_id: @user_id,
        conversation_session_id: @conversation_session_id,
        correlation_id: @correlation_id,
        rag_service: @rag_service,
        generator: @generator,
        expander: @expander
      )
    end

    def retrieve_projection
      @rag_service.retrieve_chunks(
        ContextProjection.search_text(@question),
        entity_s3_uris: [],
        entity_sources: @entity_sources,
        force_entity_filter: false,
        number_of_results: RagRetrievalProfile::OPEN_RESULTS,
        account_id: @account_id,
        correlation_id: @correlation_id
      )
    rescue BedrockRagService::BedrockServiceError, StandardError => e
      Rails.logger.warn("Rag::ContextEvidenceRoute: retrieve failed — #{e.class}: #{e.message}")
      StructuredEvidenceRoute::Outcome.new(status: :unavailable, result: nil)
    end
  end
end
