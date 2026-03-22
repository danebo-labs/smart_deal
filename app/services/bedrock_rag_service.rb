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
    number_of_results: 10,
    search_type: "HYBRID",
    generation_temperature: 0.3,
    generation_max_tokens: 3000
  }.freeze

  # Build complete optimized configuration for retrieve_and_generate API
  # This method constructs the config dynamically to include prompt templates
  # @param question [String] Used to detect response language when response_locale is nil
  # @param response_locale [Symbol, nil] When set (:en / :es), overrides question-based detection for the generation prompt
  def build_complete_optimized_config(region: 'us-east-1', question: nil, response_locale: nil)
    cfg = @rag_config
    {
      # ===== RETRIEVAL CONFIGURATION =====
      retrieval_configuration: {
        vector_search_configuration: {
          number_of_results: cfg[:number_of_results],
          override_search_type: cfg[:search_type],

          # Reranking — disabled by default until ARN / availability confirmed.
          # Enable via BEDROCK_RERANKER_ENABLED=true after verifying the model is
          # accessible in your region and the ARN is correct.
          # WARNING: if the reranker fails silently, retrieved_references = 0 and
          # Haiku generates a response from parametric memory ($search_results$ = empty).
          **reranking_config(region)

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

        # Custom prompt template for generation (includes language instruction from question text)
        prompt_template: {
          text_prompt_template: load_generation_prompt_with_locale(question, response_locale: response_locale)
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
  def query(question, session_id: nil, custom_config: {}, response_locale: nil)
    unless @knowledge_base_id
      error_msg = 'Knowledge Base ID not configured. Please set BEDROCK_KNOWLEDGE_BASE_ID environment variable or configure in Rails credentials.'
      Rails.logger.error(error_msg)
      raise MissingKnowledgeBaseError, error_msg
    end

    Rails.logger.info("Querying Knowledge Base with: #{question}")

    start_time = Time.current

    begin
      # Build complete optimized configuration and merge with custom config
      base_config = build_complete_optimized_config(region: @region, question: question, response_locale: response_locale)
      config = deep_merge_configs(base_config, custom_config)

      # ── DIAGNOSTIC LOGGING (temporary) ──────────────────────────────────────
      Rails.logger.info("[RAG_DIAG] session_id sent: #{session_id.inspect}")
      prompt_preview = config.dig(:generation_configuration, :prompt_template, :text_prompt_template).to_s[0, 200]
      Rails.logger.info("[RAG_DIAG] prompt_template[0..200]: #{prompt_preview}")
      Rails.logger.info("[RAG_DIAG] retrieval_configuration: #{config[:retrieval_configuration].inspect}")
      # ────────────────────────────────────────────────────────────────────────

      # Use retrieve_and_generate API - combines retrieval and generation in one call
      # Wraps call with retry logic for Aurora Serverless auto-pause cold-start.
      # Aurora can take 20-60s to resume; we back off and retry up to 3 times.
      bedrock_start_time = Time.current
      response = retrieve_and_generate_with_retry({
        input: {
          text: question
        },
        retrieve_and_generate_configuration: {
          type: 'KNOWLEDGE_BASE',
          knowledge_base_configuration: {
            knowledge_base_id: @knowledge_base_id,
            model_arn: @model_ref,
            **config
          }
        },
        session_id: session_id
      })
      bedrock_latency_ms = ((Time.current - bedrock_start_time) * 1000).to_i

      # ── DIAGNOSTIC: raw response ─────────────────────────────────────────────
      raw_citations = response.citations || []
      total_refs = raw_citations.sum { |c| c.retrieved_references&.size.to_i }
      Rails.logger.info("[RAG_DIAG] response.session_id: #{response.session_id.inspect}")
      Rails.logger.info("[RAG_DIAG] citation groups: #{raw_citations.size}, total retrieved_references: #{total_refs}")
      Rails.logger.info("[RAG_DIAG] raw output text[0..300]: #{response.output.text.to_s[0, 300]}")
      if total_refs.zero?
        Rails.logger.warn("[RAG_DIAG] ⚠ ZERO retrieved_references — $search_results$ was empty when Haiku generated the response. Likely cause: reranker misconfiguration or filter discarding all chunks.")
      else
        raw_citations.each_with_index do |cit, ci|
          cit.retrieved_references.each_with_index do |ref, ri|
            Rails.logger.info("[RAG_DIAG] ref[#{ci}][#{ri}] score=#{ref.score rescue 'n/a'} uri=#{ref.location&.s3_location&.uri} content[0..100]=#{ref.content&.text.to_s[0, 100]}")
          end
        end
      end
      # ────────────────────────────────────────────────────────────────────────

      Rails.logger.info("BedrockRagService: retrieve_and_generate #{bedrock_latency_ms}ms")

      # Process response
      raw_answer = response.output.text
      # Replace Bedrock's default "no results" guardrail message with a user-friendly one.
      no_results_locale = effective_response_locale(question, response_locale: response_locale)
      answer_text = bedrock_no_results?(raw_answer) ? localized_no_results(no_results_locale) : raw_answer
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

      # Prefer actual usage from Bedrock response; fall back to local estimate.
      # Note: retrieve_and_generate does NOT return token counts in the response struct,
      # so we estimate from text length. The "input_tokens: 4" log is estimate_tokens(question),
      # not from Bedrock — this is expected and does NOT indicate chunks were skipped.
      input_tokens = estimate_tokens(question)
      output_tokens = estimate_tokens(answer_text)

      # Enqueue tracking asynchronously — never block the response on DB writes.
      TrackBedrockQueryJob.perform_later(
        model_id: tracked_model_id,
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        user_query: question,
        latency_ms: latency_ms
      )
      Rails.logger.info("✓ BedrockQuery tracking enqueued (#{input_tokens} in + #{output_tokens} out tokens)")

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

  AURORA_RESUME_PATTERN = /aurora.*auto-paused|resuming after being auto-paused/i.freeze
  AURORA_RETRY_DELAYS   = [ 15, 30, 45 ].freeze  # seconds between attempts

  # Retries the retrieve_and_generate call when Aurora Serverless is cold-starting.
  # Aurora can take up to 60s to resume; three attempts cover the typical warm-up window.
  def retrieve_and_generate_with_retry(params)
    attempts = 0
    begin
      attempts += 1
      @client.retrieve_and_generate(params)
    rescue Aws::BedrockAgentRuntime::Errors::ServiceError => e
      delay = AURORA_RETRY_DELAYS[attempts - 1]
      if delay && e.message.match?(AURORA_RESUME_PATTERN)
        Rails.logger.warn("[RAG] Aurora auto-pause detected (attempt #{attempts}). Waiting #{delay}s before retry...")
        sleep(delay)
        retry
      end
      raise
    end
  end

  # Returns reranking_configuration hash when BEDROCK_RERANKER_ENABLED=true,
  # otherwise returns an empty hash (no reranking step — safest default).
  # Reranking uses Cohere Rerank v3.5 when enabled.
  def reranking_config(region)
    return {} unless ENV['BEDROCK_RERANKER_ENABLED'].to_s.downcase == 'true'

    {
      reranking_configuration: {
        type: "BEDROCK_RERANKING_MODEL",
        bedrock_reranking_configuration: {
          model_configuration: {
            model_arn: "arn:aws:bedrock:#{region}::foundation-model/cohere.rerank-v3-5:0"
          }
        }
      }
    }
  end

  def effective_response_locale(question, response_locale: nil)
    response_locale.present? ? response_locale.to_sym : detect_language_from_question(question)
  end

  # Resolves RAG config: defaults + ENV + tenant.bedrock_config.rag_config.
  # Precedence: tenant config > ENV > defaults.
  def resolve_rag_config
    from_env = {
      number_of_results: parse_int(ENV['BEDROCK_RAG_NUMBER_OF_RESULTS']),
      search_type: ENV['BEDROCK_RAG_SEARCH_TYPE'].presence,
      generation_temperature: parse_float(ENV['BEDROCK_RAG_GENERATION_TEMPERATURE']),
      generation_max_tokens: parse_int(ENV['BEDROCK_RAG_GENERATION_MAX_TOKENS'])
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

  # Loads generation prompt with explicit language instruction.
  # Uses response_locale when set; otherwise detects from question or I18n.locale.
  def load_generation_prompt_with_locale(question = nil, response_locale: nil)
    base = self.class.load_generation_prompt_template
    locale = if response_locale.present?
      response_locale.to_sym
    elsif question.present?
      detect_language_from_question(question)
    else
      I18n.locale
    end
    lang_name = locale_to_language_name(locale)
    return base if lang_name.blank?

    # Inject explicit language instruction after LANGUAGE & TONE header
    base.sub(
      /(# LANGUAGE & TONE\n)/,
      "\\1- CRITICAL: The user's query is in #{lang_name}. You MUST respond entirely in #{lang_name}.\n"
    )
  end

  # Detects response language from the question text. Does not depend on browser/headers.
  # Returns :es for Spanish, :en otherwise.
  def detect_language_from_question(question)
    self.class.detect_language_from_question(question)
  end

  def self.detect_language_from_question(question)
    return I18n.locale if question.blank?

    text = question.to_s.strip.downcase
    return :es if text.match?(/[áéíóúñ¿¡]/)
    return :es if text.match?(/\b(que|qué|cómo|cuál|cuáles|dónde|quién|por qué|para qué|cuándo|cuánto|cuánta|necesito|quiero|explica|explicame|dime|dame|busco|buscar|información|informacion|sobre|instalación|instalacion|reparar|mantenimiento|documentación|documentacion)\b/i)
    return :es if text.match?(/\b(es|son|está|están|hay|tiene|tienen|puedo|puede|pueden)\b/) && text.length < 80

    :en
  end

  def locale_to_language_name(locale)
    { es: "Spanish", en: "English" }[locale.to_sym]
  end

  def localized_no_results(locale)
    I18n.with_locale(locale) { I18n.t("rag.no_results_found") }
  end

  def self.load_generation_prompt_template
    Rails.root.join("app/prompts/bedrock/generation.txt").read
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
