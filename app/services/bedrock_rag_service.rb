# frozen_string_literal: true

# app/services/bedrock_rag_service.rb

require 'aws-sdk-bedrockagentruntime'
require 'aws-sdk-core/static_token_provider'
require 'json'
require_relative 's3_documents_service'
require_relative 'bedrock/citation_processor'

class BedrockRagService
  include AwsClientInitializer

  # Custom error classes
  class MissingKnowledgeBaseError < StandardError; end
  class BedrockServiceError < StandardError; end

  # Build complete optimized configuration for retrieve_and_generate API
  # This method constructs the config dynamically to include prompt templates
  def build_complete_optimized_config(region: 'us-east-1')
    {
      # ===== RETRIEVAL CONFIGURATION =====
      retrieval_configuration: {
        vector_search_configuration: {
          # Source chunks optimized
          number_of_results: 20,              # Was 5 by default

          # Search type optimized
          override_search_type: "HYBRID",     # HYBRID vs SEMANTIC

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
        # Optimized inference parameters
        inference_config: {
          text_inference_config: {
            temperature: 0.3,                 # Creativity control
            top_p: 0.9,                      # Token diversity
            max_tokens: 3000,                # Maximum output tokens (was 2048)
            stop_sequences: []               # Stop sequences (empty, without "observation")
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
            temperature: 0.1,                # More deterministic for query processing
            top_p: 0.8,
            max_tokens: 2048
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

  def initialize(knowledge_base_id: nil)
    client_options = build_aws_client_options
    region = client_options[:region]
    @client = Aws::BedrockAgentRuntime::Client.new(client_options)
    @knowledge_base_id = knowledge_base_id.presence ||
                         ENV.fetch('BEDROCK_KNOWLEDGE_BASE_ID', nil).presence ||
                         Rails.application.credentials.dig(:bedrock, :knowledge_base_id)
    @citation_processor = Bedrock::CitationProcessor.new

    # Use Claude 3 Haiku by default for cost optimization (12x cheaper than Sonnet)
    # Alternative: Can use Claude 3 Sonnet, Opus, or other models that support foundation-model ARN
    # Set BEDROCK_MODEL_ID env var or configure in Rails credentials to override
    model_id = ENV.fetch('BEDROCK_MODEL_ID', nil).presence ||
               Rails.application.credentials.dig(:bedrock, :model_id) ||
               'anthropic.claude-3-haiku-20240307-v1:0'

    # Use the model ID directly as the model_arn.
    # Newer models (e.g., us.anthropic.claude-3-5-haiku) require an inference profile ID,
    # NOT a foundation-model ARN. The inference profile ID is the model_id itself.
    @model_arn = model_id

    # Debug logging
    Rails.logger.info("BedrockRagService initialized - Knowledge Base ID: #{@knowledge_base_id.presence || 'NOT SET'}")
    Rails.logger.info("BedrockRagService initialized - Model ID: #{@model_arn}")
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
      # Get region from client options
      client_options = build_aws_client_options
      region = client_options[:region] || 'us-east-1'

      # Build complete optimized configuration and merge with custom config
      base_config = build_complete_optimized_config(region: region)
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
            model_arn: @model_arn,
            **config  # All optimized configuration
          }
        },
        session_id: session_id
      })

      # Process response
      answer_text = response.output.text
      citations = @citation_processor.extract_citations(response.citations)
      session_id = response.session_id

      # Get S3 documents list to map citations to document numbers in Data Source
      s3_documents = S3DocumentsService.new.list_documents

      # Build mapping from Bedrock citation numbers to Data Source numbers
      citation_to_datasource_map = @citation_processor.build_citation_mapping(citations, s3_documents)

      # Replace Bedrock citation numbers [1], [2] with Data Source numbers in answer text
      answer_text = @citation_processor.replace_citation_numbers(answer_text, citation_to_datasource_map)

      # If answer doesn't contain citations but we have citations from Bedrock,
      # add them automatically at the end of sentences/phrases
      if citations.any? && !answer_text.match(/\[\d+\]/)
        answer_text = @citation_processor.add_citations_to_answer(answer_text, citations, citation_to_datasource_map)
        Rails.logger.info("Added citations automatically to answer text")
      end

      latency_ms = ((Time.current - start_time) * 1000).to_i
      model_id = @model_arn.split('/').last

      # Extract tokens - estimate from input and output
      input_tokens = estimate_tokens(question)
      output_tokens = estimate_tokens(answer_text)

      # Save query to database for metrics tracking
      # Metrics tracking failure should not fail the request
      begin
        BedrockQuery.create!(
          model_id: model_id,
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

      # Extract numbered citations from answer text and map to documents
      numbered_references = @citation_processor.build_numbered_references(citations, answer_text, s3_documents)

      Rails.logger.info("Found #{citations.length} citation(s)")
      numbered_references.each do |ref|
        Rails.logger.info("  Citation #{ref[:number]}: #{ref[:title]} (#{ref[:filename]}) -> Data Source doc #{ref[:number]}")
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
