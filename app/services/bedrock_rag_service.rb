# frozen_string_literal: true

# app/services/bedrock_rag_service.rb

require 'aws-sdk-bedrockagentruntime'
require 'aws-sdk-core/static_token_provider'
require 'json'
require_relative 'bedrock/citation_processor'

class BedrockRagService
  include AwsClientInitializer

  # Custom error classes
  class MissingKnowledgeBaseError < StandardError; end
  class BedrockServiceError < StandardError; end

  # Matches the default Bedrock guardrail response when no KB results are found.
  BEDROCK_NO_RESULTS_PATTERN = /\AI'?m sorry[,.]|sorry,?\s+i\s+(am\s+)?unable\s+to\s+(assist|help)/i.freeze

  # Default RAG config (safety-critical for elevator domain).
  # Overridden by ENV (BEDROCK_RAG_*) and tenant.bedrock_config.rag_config when present.
  DEFAULT_RAG_CONFIG = {
    number_of_results: 15,
    search_type: "HYBRID",
    generation_temperature: 0.0,
    generation_max_tokens: 3000,
    orchestration_temperature: 0.0,
    orchestration_max_tokens: 2048
  }.freeze

  # Build complete optimized configuration for retrieve_and_generate API
  # This method constructs the config dynamically to include prompt templates
  def build_complete_optimized_config(region: 'us-east-1')
    cfg = @rag_config
    {
      # ===== RETRIEVAL CONFIGURATION =====
      retrieval_configuration: {
        vector_search_configuration: {
          number_of_results: cfg[:number_of_results],
          override_search_type: cfg[:search_type],

          # Reranking configuration
          # Note: The reranking will use the number_of_results from vector_search_configuration above
          reranking_configuration: {
            type: "BEDROCK_RERANKING_MODEL",
            bedrock_reranking_configuration: {
              model_configuration: {
                model_arn: "arn:aws:bedrock:#{region}::foundation-model/cohere.rerank-v3-5:0"
              }
            }
          }

          # Metadata filtering (optional) - removed empty filter as API requires at least one filter type
          # To add filtering, uncomment and configure:
          # filter: {
          #   and_all: [
          #     {
          #       equals: {
          #         key: "document_type",
          #         value: "manual"
          #       }
          #     }
          #   ]
          # }
        }
      },

      # ===== GENERATION CONFIGURATION =====
      generation_configuration: {
        inference_config: {
          text_inference_config: {
            temperature: cfg[:generation_temperature],
            max_tokens: cfg[:generation_max_tokens],
            stop_sequences: []
          }
        },

        # Custom prompt template for generation
        prompt_template: {
          text_prompt_template: self.class.load_generation_prompt_template
        },

        # Additional model request fields (model-specific parameters)
        additional_model_request_fields: {
          # Specific parameters for Claude
          # "top_k" => 250,
          # "anthropic_version" => "bedrock-2023-05-31"
        }

        # Guardrails (optional)
        # guardrail_configuration: {
        #   guardrail_identifier: "your-guardrail-id",
        #   guardrail_version: "DRAFT"
        # }
      },

      # ===== ORCHESTRATION CONFIGURATION =====
      orchestration_configuration: {
        # Query transformation (Query decomposition - Break down queries)
        query_transformation_configuration: {
          type: "QUERY_DECOMPOSITION"        # ENABLE break down queries
        },

        # Inference config for orchestration
        inference_config: {
          text_inference_config: {
            temperature: cfg[:orchestration_temperature],
            max_tokens: cfg[:orchestration_max_tokens]
          }
        },

        # Custom prompt template for orchestration
        prompt_template: {
          text_prompt_template: self.class.load_orchestration_prompt_template
        },

        # Additional model request fields for orchestration
        additional_model_request_fields: {}
      }
    }
  end

  # @param knowledge_base_id [String, nil] Override KB ID (takes precedence)
  # @param tenant [Tenant, nil] Optional tenant for per-KB config (tenant.bedrock_config.rag_config)
  def initialize(knowledge_base_id: nil, tenant: nil)
    client_options = build_aws_client_options
    @region = client_options[:region] || 'us-east-1'
    @client = Aws::BedrockAgentRuntime::Client.new(client_options)
    @tenant = tenant
    @knowledge_base_id = knowledge_base_id.presence ||
                         tenant&.bedrock_config&.knowledge_base_id ||
                         ENV.fetch('BEDROCK_KNOWLEDGE_BASE_ID', nil).presence ||
                         Rails.application.credentials.dig(:bedrock, :knowledge_base_id)
    @citation_processor = Bedrock::CitationProcessor.new
    @rag_config = resolve_rag_config

    # @model_ref holds either a Bedrock inference profile ID or a full foundation-model ARN.
    @model_ref = BedrockClient::QUERY_MODEL_ID

    Rails.logger.info("BedrockRagService initialized - Knowledge Base ID: #{@knowledge_base_id.presence || 'NOT SET'}")
    Rails.logger.info("BedrockRagService initialized - Model ID: #{@model_ref}")
  end

  # Query the Knowledge Base using RAG with retrieve_and_generate API
  def query(question, session_id: nil, custom_config: {})
    unless @knowledge_base_id
      error_msg = 'Knowledge Base ID not configured. Please set BEDROCK_KNOWLEDGE_BASE_ID environment variable or configure in Rails credentials.'
      Rails.logger.error(error_msg)
      raise MissingKnowledgeBaseError, error_msg
    end

    Rails.logger.info("Querying Knowledge Base with: #{question}")

    start_time = Time.current

    begin
      # Build complete optimized configuration and merge with custom config
      base_config = build_complete_optimized_config(region: @region)
      config = deep_merge_configs(base_config, custom_config)

      # Use retrieve_and_generate API - combines retrieval and generation in one call
      # Apply all optimized configuration (retrieval, generation, orchestration)
      response = @client.retrieve_and_generate({
        input: {
          text: question
        },
        retrieve_and_generate_configuration: {
          type: 'KNOWLEDGE_BASE',
          knowledge_base_configuration: {
            knowledge_base_id: @knowledge_base_id,
            model_arn: @model_ref,
            **config  # All optimized configuration
          }
        },
        session_id: session_id
      })

      # Process response
      raw_answer = response.output.text
      # Replace Bedrock's default "no results" guardrail message with a user-friendly one.
      answer_text = bedrock_no_results?(raw_answer) ? I18n.t("rag.no_results_found") : raw_answer
      citations = @citation_processor.extract_citations(response.citations)
      session_id = response.session_id

      # If answer doesn't contain inline citations but Bedrock returned source chunks,
      # distribute [n] markers across the answer automatically.
      if citations.any? && !answer_text.match(/\[\d+\]/)
        answer_text = @citation_processor.add_citations_to_answer(answer_text, citations)
        Rails.logger.info("Added citations automatically to answer text")
      end

      latency_ms = ((Time.current - start_time) * 1000).to_i
      tracked_model_id = @model_ref.include?('/') ? @model_ref.split('/').last : @model_ref

      # Extract tokens - estimate from input and output
      input_tokens = estimate_tokens(question)
      output_tokens = estimate_tokens(answer_text)

      # Save query to database for metrics tracking
      # Metrics tracking failure should not fail the request
      begin
        BedrockQuery.create!(
          model_id: tracked_model_id,
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          user_query: question,
          latency_ms: latency_ms,
          created_at: Time.current
        )
        Rails.logger.info("✓ Bedrock query tracked: #{input_tokens} input + #{output_tokens} output tokens")

        # Update metrics automatically after each query
        SimpleMetricsService.update_database_metrics_only
        Rails.logger.info("✓ Metrics updated after query")
      rescue StandardError => e
        Rails.logger.error("Failed to track query or update metrics: #{e.message}")
      end

      # Build numbered references from the KB response — no S3 listing required.
      numbered_references = @citation_processor.build_numbered_references(citations, answer_text)

      Rails.logger.info("Found #{citations.length} citation(s)")
      numbered_references.each do |ref|
        Rails.logger.info("  Citation [#{ref[:number]}]: #{ref[:title]} (#{ref[:filename]})")
      end

      {
        answer: answer_text,
        citations: numbered_references,
        session_id: session_id
      }
    rescue Aws::BedrockAgentRuntime::Errors::ServiceError => e
      Rails.logger.error("Bedrock RAG error: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      raise BedrockServiceError, "Failed to query Knowledge Base: #{e.message}"
    end
  end

  private

  # Resolves RAG config: defaults + ENV + tenant.bedrock_config.rag_config.
  # Precedence: tenant config > ENV > defaults.
  def resolve_rag_config
    from_env = {
      number_of_results: parse_int(ENV['BEDROCK_RAG_NUMBER_OF_RESULTS']),
      search_type: ENV['BEDROCK_RAG_SEARCH_TYPE'].presence,
      generation_temperature: parse_float(ENV['BEDROCK_RAG_GENERATION_TEMPERATURE']),
      generation_max_tokens: parse_int(ENV['BEDROCK_RAG_GENERATION_MAX_TOKENS']),
      orchestration_temperature: parse_float(ENV['BEDROCK_RAG_ORCHESTRATION_TEMPERATURE']),
      orchestration_max_tokens: parse_int(ENV['BEDROCK_RAG_ORCHESTRATION_MAX_TOKENS'])
    }.compact
    from_tenant = @tenant&.bedrock_config&.rag_config
    from_tenant = from_tenant&.symbolize_keys&.compact || {}
    DEFAULT_RAG_CONFIG.merge(from_env).merge(from_tenant)
  end

  def parse_int(val)
    return nil if val.blank?
    val.to_i
  end

  def parse_float(val)
    return nil if val.blank?
    val.to_f
  end

  # Returns true when Bedrock's retrieve_and_generate responds with its built-in
  # "no relevant results" guardrail message instead of a real answer.
  def bedrock_no_results?(text)
    text.to_s.strip.match?(BEDROCK_NO_RESULTS_PATTERN)
  end

  # ===== CUSTOM PROMPT TEMPLATES =====

  def self.load_generation_prompt_template
    Rails.root.join("app/prompts/bedrock/generation.txt").read
  end

  def self.load_orchestration_prompt_template
    Rails.root.join("app/prompts/bedrock/orchestration.txt").read
  end

  def estimate_tokens(text)
    return 0 if text.blank?

    # Rough estimation: ~4 characters per token for English text
    # This is a simple heuristic, actual tokenization varies by model
    (text.length / 4.0).ceil
  end

  # Deep merge configurations (supports nested hashes)
  def deep_merge_configs(base_config, custom_config)
    return base_config if custom_config.empty?

    base_config.merge(custom_config) do |key, old_val, new_val|
      if old_val.is_a?(Hash) && new_val.is_a?(Hash)
        deep_merge_configs(old_val, new_val)
      else
        new_val
      end
    end
  end
end
