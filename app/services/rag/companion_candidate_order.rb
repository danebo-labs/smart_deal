# frozen_string_literal: true

module Rag
  # Orders the candidates already retrieved for one pinned companion turn.
  # Retrieve stays hybrid: this is a separate Rerank call, not
  # reranking_configuration and not BEDROCK_RERANKER_ENABLED.
  # The original body, its metadata, and its location stay on the chunk.
  class CompanionCandidateOrder
    MODEL_ID = "cohere.rerank-v3-5:0"
    Error = Class.new(StandardError)

    def self.call(chunks, question:, client:, region:)
      new(chunks, question: question, client: client, region: region).call
    end

    def initialize(chunks, question:, client:, region:)
      @chunks = Array(chunks)
      @question = question.to_s
      @client = client
      @region = region.presence || "us-east-1"
    end

    def call
      return @chunks if @chunks.size < 2 || @question.strip.empty?

      Rag::InferencePolicy.check!(operation: "companion_candidate_order.rerank", model_id: MODEL_ID)
      response = @client.rerank(payload)
      rows = Array(response.respond_to?(:results) ? response.results : nil)
      raise Error, "companion rerank returned no results" if rows.empty?

      ordered = []
      seen = {}
      rows.sort_by { |row| [ -relevance(row), index_of(row) ] }.each do |row|
        index = index_of(row)
        next unless index >= 0 && index < @chunks.size
        next if seen[index]

        seen[index] = true
        ordered << @chunks[index].merge(score: relevance(row), rank: ordered.size + 1)
      end
      raise Error, "companion rerank returned no usable indexes" if seen.empty?

      token = response.respond_to?(:next_token) ? response.next_token : nil
      raise Error, "companion rerank returned another page" if token.present? && seen.size < @chunks.size

      @chunks.each_with_index do |chunk, index|
        next if seen[index]

        ordered << chunk.merge(rank: ordered.size + 1)
      end
      ordered
    end

    private

    def payload
      {
        queries: [ { type: "TEXT", text_query: { text: @question } } ],
        sources: @chunks.map { |chunk|
          {
            type: "INLINE",
            inline_document_source: {
              type: "TEXT",
              text_document: { text: chunk[:content].to_s }
            }
          }
        },
        reranking_configuration: {
          type: "BEDROCK_RERANKING_MODEL",
          bedrock_reranking_configuration: {
            number_of_results: @chunks.size,
            model_configuration: { model_arn: model_arn }
          }
        }
      }
    end

    def model_arn
      "arn:aws:bedrock:#{@region}::foundation-model/#{MODEL_ID}"
    end

    def index_of(row)
      value = row.respond_to?(:index) ? row.index : nil
      return -1 unless value.is_a?(Integer) || value.to_s.match?(/\A\d+\z/)

      value.to_i
    end

    def relevance(row)
      row.relevance_score.to_f
    end
  end
end
