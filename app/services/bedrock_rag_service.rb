# frozen_string_literal: true

# app/services/bedrock_rag_service.rb

require 'aws-sdk-bedrockagentruntime'
require 'aws-sdk-core/static_token_provider'
require 'digest'
require 'json'
require_relative 'bedrock/citation_processor'

class BedrockRagService
  include AwsClientInitializer

  # Custom error classes
  class MissingKnowledgeBaseError < StandardError; end
  class BedrockServiceError < StandardError; end

  # Matches the default Bedrock guardrail response when no KB results are found.
  BEDROCK_NO_RESULTS_PATTERN = /\AI'?m sorry[,.]|sorry,?\s+i\s+(am\s+)?unable\s+to\s+(assist|help)/i.freeze

  DOC_REFS_PATTERN = /<DOC_REFS>\s*(.*?)\s*<\/DOC_REFS>/m.freeze

  # Default RAG config (safety-critical for elevator domain).
  # Overridden by ENV (BEDROCK_RAG_*) and tenant.bedrock_config.rag_config when present.
  DEFAULT_RAG_CONFIG = {
    number_of_results: 10,
    search_type: "HYBRID",
    generation_temperature: 0.1,
    generation_max_tokens: 3000
  }.freeze

  # Build complete optimized configuration for retrieve_and_generate API
  # This method constructs the config dynamically to include prompt templates
  # @param question [String] Used to detect response language when response_locale is nil
  # @param response_locale [Symbol, nil] When set (:en / :es), overrides question-based detection for the generation prompt
  # @param entity_s3_uris [Array<String>] S3 URIs of active session documents; when non-empty, adds metadata filter
  # @param entity_sources [Array<String>] Source types of pinned entities ("image_upload"|"document"); used by RagRetrievalProfile
  def build_complete_optimized_config(region: 'us-east-1', question: nil, response_locale: nil, session_context: nil, entity_s3_uris: [], entity_sources: [], output_channel: nil)
    cfg = @rag_config
    vector_config = build_vector_search_configuration(
      region: region,
      question: question,
      entity_s3_uris: entity_s3_uris,
      entity_sources: entity_sources
    )

    {
      # ===== RETRIEVAL CONFIGURATION =====
      retrieval_configuration: {
        vector_search_configuration: vector_config
      },

      # ===== GENERATION CONFIGURATION =====
      generation_configuration: {
        inference_config: {
          text_inference_config: {
            temperature: cfg[:generation_temperature],
            max_tokens: cfg[:generation_max_tokens],
            # Stop before </DOC_REFS> is emitted to trim tail noise.
            # query() re-appends the tag before extract_doc_refs so the regex still matches.
            stop_sequences: ["</DOC_REFS>"]
          }
        },

        # Custom prompt template for generation (includes language instruction from question text)
        prompt_template: {
          text_prompt_template: load_generation_prompt_with_locale(question, response_locale: response_locale, session_context: session_context, output_channel: output_channel)
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

  def build_vector_search_configuration(region: @region, question: nil, entity_s3_uris: [],
                                        entity_sources: [], number_of_results: nil,
                                        reranking: true)
    profile = RagRetrievalProfile.new(entity_sources: entity_sources, question: question)
    vector_config = {
      number_of_results: number_of_results || profile.number_of_results,
      override_search_type: @rag_config[:search_type],
      **(reranking ? reranking_config(region, profile: profile) : {})
    }

    uris = Array(entity_s3_uris).map(&:to_s).compact_blank.uniq
    if uris.any?
      filters = uris.flat_map do |uri|
        [
          { equals: { key: "x-amz-bedrock-kb-source-uri", value: uri } },
          { equals: { key: "original_source_uri", value: uri } }
        ]
      end
      vector_config[:filter] = { or_all: filters }
    end

    vector_config
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
  # @param entity_s3_uris [Array<String>] S3 URIs from active session entities; used to
  #   scope retrieval when the query is short/ambiguous and doesn't name a different document.
  # @param force_entity_filter [Boolean] When true, ALWAYS apply the entity filter
  #   if entity_s3_uris is non-empty, bypassing the query_names_different_document?
  #   heuristic. Use this when the caller has explicitly bound the query to a
  #   document (e.g. a WhatsApp picker selection) so heavy-capitalized seed
  #   queries like "Describe Orona ARCA BASICO ..." don't trip the bypass.
  def query(question, session_id: nil, custom_config: {}, response_locale: nil, session_context: nil, entity_s3_uris: [], entity_sources: [], output_channel: nil, force_entity_filter: false)
    unless @knowledge_base_id
      error_msg = 'Knowledge Base ID not configured. Please set BEDROCK_KNOWLEDGE_BASE_ID environment variable or configure in Rails credentials.'
      Rails.logger.error(error_msg)
      raise MissingKnowledgeBaseError, error_msg
    end

    Rails.logger.info("Querying Knowledge Base with: #{question}")

    start_time = Time.current

    begin
      # Apply entity filter when explicitly forced (caller bound the query to a
      # specific doc) OR when the query is short/ambiguous and doesn't name a
      # different document.
      apply_filter = entity_s3_uris.any? && (force_entity_filter || !query_names_different_document?(question, entity_s3_uris))
      filtered_uris = apply_filter ? entity_s3_uris : []
      effective_session_context = session_context_with_entity_safety(
        session_context,
        entity_sources: entity_sources
      )

      if entity_s3_uris.any?
        Rails.logger.info("BedrockRagService: entity_filter=#{apply_filter} uris=#{filtered_uris.size} forced=#{force_entity_filter}")
      end

      # Build complete optimized configuration and merge with custom config
      base_config = build_complete_optimized_config(region: @region, question: question, response_locale: response_locale, session_context: effective_session_context, entity_s3_uris: filtered_uris, entity_sources: entity_sources, output_channel: output_channel)
      config = enforce_query_contractual_limits(deep_merge_configs(base_config, custom_config))
      applied_filter_uris = filtered_uris

      params = {
        input: { text: question },
        retrieve_and_generate_configuration: {
          type: 'KNOWLEDGE_BASE',
          knowledge_base_configuration: {
            knowledge_base_id: @knowledge_base_id,
            model_arn: @model_ref,
            **config
          }
        },
        session_id: session_id
      }

      # Gate 9R I0: groups every billable invocation of this turn (filtered
      # attempt + global fallback) so the cost matrix can count real calls/query.
      query_correlation_id = "query:#{SecureRandom.uuid}"
      generation_attempt   = 1

      # Use retrieve_and_generate API - combines retrieval and generation in one call
      # Wraps call with retry logic for Aurora Serverless auto-pause cold-start.
      # Aurora can take 20-60s to resume; we back off and retry up to 3 times.
      bedrock_start_time = Time.current
      response = retrieve_and_generate_with_retry(params)

      # Fallback: if filter produced no results, retry without filter.
      if apply_filter && !force_entity_filter && bedrock_no_results?(response.output.text)
        Rails.logger.info("BedrockRagService: filtered query returned no results, retrying without filter")
        # The filtered attempt is a billable generation in its own right — track it
        # before re-running so the turn leaves one row per invocation (I0).
        track_filtered_no_results_attempt(
          question:        question,
          raw_answer:      response.output.text,
          config:          config,
          correlation_id:  query_correlation_id,
          latency_ms:      ((Time.current - bedrock_start_time) * 1000).to_i,
          response_locale: response_locale,
          session_context: effective_session_context,
          output_channel:  output_channel
        )
        generation_attempt = 2
        unfiltered_config = build_complete_optimized_config(region: @region, question: question, response_locale: response_locale, session_context: effective_session_context, entity_s3_uris: [], entity_sources: entity_sources, output_channel: output_channel)
        unfiltered_params = params.merge(
          retrieve_and_generate_configuration: params[:retrieve_and_generate_configuration].merge(
            knowledge_base_configuration: params.dig(:retrieve_and_generate_configuration, :knowledge_base_configuration).merge(
              **enforce_query_contractual_limits(deep_merge_configs(unfiltered_config, custom_config))
            )
          )
        )
        params = unfiltered_params
        config = params.dig(
          :retrieve_and_generate_configuration,
          :knowledge_base_configuration
        ).except(:knowledge_base_id, :model_arn)
        applied_filter_uris = []
        response = retrieve_and_generate_with_retry(unfiltered_params)
      end

      bedrock_latency_ms = ((Time.current - bedrock_start_time) * 1000).to_i

      raw_citations = response.citations || []
      total_refs = raw_citations.sum { |c| c.retrieved_references&.size.to_i }

      Rails.logger.info("BedrockRagService: retrieve_and_generate #{bedrock_latency_ms}ms")

      # Process response
      raw_answer = response.output.text
      # Replace Bedrock's default "no results" guardrail message with a user-friendly one.
      no_results_locale = effective_response_locale(question, response_locale: response_locale)
      answer_text =
        if bedrock_no_results?(raw_answer) && apply_filter && force_entity_filter
          localized_pinned_no_results(no_results_locale)
        elsif bedrock_no_results?(raw_answer)
          localized_no_results(no_results_locale)
        else
          raw_answer
        end
      # stop_sequences ["</DOC_REFS>"] causes the model to stop before emitting the closing tag.
      # Re-append it so DOC_REFS_PATTERN can match.
      answer_text = normalize_doc_refs_tag(answer_text)
      doc_refs_result = extract_doc_refs(answer_text)
      answer_text = doc_refs_result[:clean_answer]
      doc_refs = doc_refs_result[:doc_refs]
      Rails.logger.info("BedrockRagService: doc_refs=#{doc_refs&.size || 'nil'}") if doc_refs
      citations = @citation_processor.extract_citations(response.citations)
      session_id = response.session_id

      # GAP: Bedrock only populates response.citations for chunks that Haiku
      # inline-cites ([n] markers). When Haiku emits <DOC_REFS> but omits inline
      # citations, response.citations is empty and EntityExtractorService has
      # no metadata to resolve source_uri. Fall back to the Retrieve API —
      # cheap vector search — to obtain the authoritative s3_uri metadata.
      retrieved_for_extraction =
        if citations.any?
          citations
        elsif doc_refs&.any?
          Rails.logger.info("BedrockRagService: post-gen citations empty; using Retrieve API fallback for source_uri resolution")
          fallback_retrieve(question, entity_s3_uris: filtered_uris)
        else
          []
        end

      # If answer doesn't contain inline citations but Bedrock returned source chunks,
      # distribute [n] markers across the answer automatically.
      if citations.any? && !answer_text.match(/\[\d+\]/)
        answer_text = @citation_processor.add_citations_to_answer(answer_text, citations)
        Rails.logger.info("Added citations automatically to answer text")
      end

      latency_ms = ((Time.current - start_time) * 1000).to_i
      tracked_model_id = @model_ref.include?('/') ? @model_ref.split('/').last : @model_ref

      # Build the full prompt that was sent to the model so the job can count tokens accurately.
      # retrieved_for_extraction holds the chunks Haiku actually cited; using them as a
      # proxy for $search_results$ gives ~95% accuracy without a second Bedrock call.
      # NOTE: token counting is deferred to TrackBedrockQueryJob to avoid up to ~16s of
      # request-blocking latency when the Anthropic count_tokens endpoint is slow.
      chunks_text = Array(retrieved_for_extraction).filter_map { |c| c[:content].presence }.join("\n\n")
      full_prompt = [
        load_generation_prompt_with_locale(question,
                                           response_locale: response_locale,
                                           session_context: effective_session_context,
                                           output_channel: output_channel),
        chunks_text,
        question
      ].compact_blank.join("\n\n")

      TrackBedrockQueryJob.perform_later(
        model_id:           tracked_model_id,
        prompt_text:        full_prompt,
        answer_text:        raw_answer,
        visible_answer_text: answer_text,
        user_query:         question,
        latency_ms:         latency_ms,
        # route reflects the retrieval scope of THIS generation call:
        # "rag_filtered" = entity filter applied; "rag_global" = unscoped
        # (either no filter or the attempt-2 no-results fallback).
        route:              applied_filter_uris.any? ? "rag_filtered" : "rag_global",
        attempt:            generation_attempt,
        max_tokens:         config.dig(:generation_configuration, :inference_config, :text_inference_config, :max_tokens),
        correlation_id:     query_correlation_id,
        source:             "query",
        model_for_counting: "haiku",
        regression_context: regression_context(
          config: config,
          observed_chunks: retrieved_for_extraction,
          observed_chunk_basis: citations.any? ? "bedrock_citations" : (doc_refs&.any? ? "fallback_retrieve_top3" : "none"),
          bedrock_cited_references_count: total_refs,
          doc_refs_present: raw_answer.include?("<DOC_REFS>"),
          doc_refs_valid: doc_refs.present?,
          doc_refs_count: doc_refs&.size.to_i,
          entity_filter_applied: apply_filter
        )
      )
      Rails.logger.info("✓ BedrockQuery tracking enqueued (token counting deferred to job)")

      # Build numbered references from the KB response — no S3 listing required.
      numbered_references = @citation_processor.build_numbered_references(citations, answer_text)

      Rails.logger.info("Found #{citations.length} citation(s)")
      numbered_references.each do |ref|
        Rails.logger.info("  Citation [#{ref[:number]}]: #{ref[:title]} (#{ref[:filename]})")
      end

      {
        answer:              answer_text,
        citations:           numbered_references,
        # Chunks that Haiku actually cited anywhere in the answer (superset of
        # numbered_references, which only includes those with explicit [n] markers).
        # NOTE: these are NOT "all retrieved chunks" — Bedrock's vector search
        # retrieves top-N chunks and passes ALL of them to Haiku as $search_results$,
        # but only the ones Haiku chose to cite appear in response.citations[].
        # retrieved_references[]. Uncited chunks are not returned by the API.
        # EntityExtractorService uses this to parse DOCUMENT_ALIASES from S0-section
        # chunks that were cited but happened to not get an explicit [n] marker.
        retrieved_citations: retrieved_for_extraction,
        doc_refs:            doc_refs,
        session_id:          session_id,
        retrieval_trace: retrieval_trace(
          resolved_scope_s3_uris: entity_s3_uris,
          applied_filter_s3_uris: applied_filter_uris,
          force_entity_filter: force_entity_filter,
          vector_search_configuration: config.dig(
            :retrieval_configuration,
            :vector_search_configuration
          )
        )
      }
    rescue Aws::BedrockAgentRuntime::Errors::ServiceError => e
      Rails.logger.error("Bedrock RAG error: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      raise BedrockServiceError, "Failed to query Knowledge Base: #{e.message}"
    end
  end

  def retrieve_chunks(question, entity_s3_uris: [], entity_sources: [],
                      force_entity_filter: false, number_of_results: nil)
    unless @knowledge_base_id
      raise MissingKnowledgeBaseError, "Knowledge Base ID not configured"
    end

    resolved_uris = Array(entity_s3_uris).map(&:to_s).compact_blank.uniq
    apply_filter = resolved_uris.any? &&
      (force_entity_filter || !query_names_different_document?(question, resolved_uris))
    applied_uris = apply_filter ? resolved_uris : []
    vector_config = build_vector_search_configuration(
      region: @region,
      question: question,
      entity_s3_uris: applied_uris,
      entity_sources: entity_sources,
      number_of_results: number_of_results
    )
    response = retrieve_with_retry(
      knowledge_base_id: @knowledge_base_id,
      retrieval_query: { text: question },
      retrieval_configuration: { vector_search_configuration: vector_config }
    )

    chunks = Array(response.retrieval_results).each_with_index.map do |result, index|
      metadata = result.metadata.to_h
      source_uri = result.location&.s3_location&.uri
      content = result.content&.text.to_s

      {
        rank: index + 1,
        content: content,
        score: result.score,
        original_source_uri: metadata["original_source_uri"] || metadata[:original_source_uri],
        bedrock_source_uri: metadata["x-amz-bedrock-kb-source-uri"] ||
          metadata[:"x-amz-bedrock-kb-source-uri"],
        location_uri: source_uri,
        metadata: metadata,
        chunk_sha256: Digest::SHA256.hexdigest(content)
      }
    end

    {
      chunks: chunks,
      retrieval_trace: retrieval_trace(
        resolved_scope_s3_uris: resolved_uris,
        applied_filter_s3_uris: applied_uris,
        force_entity_filter: force_entity_filter,
        vector_search_configuration: vector_config
      )
    }
  rescue Aws::BedrockAgentRuntime::Errors::ServiceError => e
    raise BedrockServiceError, "Failed to retrieve Knowledge Base chunks: #{e.message}"
  end

  private

  def retrieval_trace(resolved_scope_s3_uris:, applied_filter_s3_uris:,
                      force_entity_filter:, vector_search_configuration:)
    vector_config = vector_search_configuration.to_h.deep_stringify_keys

    {
      resolved_scope_s3_uris: Array(resolved_scope_s3_uris).map(&:to_s).compact_blank.uniq.sort,
      applied_filter_s3_uris: Array(applied_filter_s3_uris).map(&:to_s).compact_blank.uniq.sort,
      force_entity_filter: force_entity_filter,
      vector_search_configuration: vector_config,
      vector_search_configuration_sha256: Digest::SHA256.hexdigest(
        JSON.generate(deep_sort(vector_config))
      )
    }
  end

  def deep_sort(value)
    case value
    when Hash
      value.keys.sort.index_with { |key| deep_sort(value[key]) }
    when Array
      value.map { |item| deep_sort(item) }
    else
      value
    end
  end

  # Bedrock retrieve_and_generate does not expose every top-N chunk in its response.
  # This telemetry records only chunks observable through citations or the explicit
  # Retrieve fallback, so regression analysis does not mistake them for the full set.
  def regression_context(config:, observed_chunks:, observed_chunk_basis:,
                         bedrock_cited_references_count:, doc_refs_present:,
                         doc_refs_valid:, doc_refs_count:, entity_filter_applied:)
    inference = config.dig(
      :generation_configuration,
      :inference_config,
      :text_inference_config
    ) || {}
    retrieval = config.dig(
      :retrieval_configuration,
      :vector_search_configuration
    ) || {}
    descriptors = Array(observed_chunks).map { |chunk| observed_chunk_descriptor(chunk) }

    {
      "configured_max_tokens" => inference[:max_tokens],
      "temperature" => inference[:temperature],
      "requested_result_count" => retrieval[:number_of_results],
      "input_token_basis" => "prompt_template_plus_observed_chunks",
      "observed_chunk_basis" => observed_chunk_basis,
      "observed_chunk_count" => descriptors.size,
      "observed_chunks" => descriptors,
      "bedrock_cited_references_count" => bedrock_cited_references_count,
      "doc_refs_present" => doc_refs_present,
      "doc_refs_valid" => doc_refs_valid,
      "doc_refs_count" => doc_refs_count,
      "entity_filter_applied" => entity_filter_applied
    }
  end

  def observed_chunk_descriptor(chunk)
    metadata = (chunk[:metadata] || chunk["metadata"] || {}).to_h
    location = (chunk[:location] || chunk["location"] || {}).to_h

    {
      "canonical_name" => metadata["canonical_name"] || metadata[:canonical_name],
      "doc_sha256" => metadata["doc_sha256"] || metadata[:doc_sha256],
      "ingestion_path" => metadata["ingestion_path"] || metadata[:ingestion_path],
      "original_source_uri" => metadata["original_source_uri"] || metadata[:original_source_uri],
      "retrieved_source_uri" => location[:uri] || location["uri"] ||
        metadata["x-amz-bedrock-kb-source-uri"] || metadata[:"x-amz-bedrock-kb-source-uri"]
    }.compact
  end

  # Gate 9R I0: one row for the filtered retrieve_and_generate attempt that hit
  # Bedrock's no-results guardrail before the global (unfiltered) re-run.
  # Token counting is deferred to the job. prompt_text omits $search_results$
  # because a no-results response carries no usable citations — the input
  # estimate is a documented undercount for this row, but the invocation itself
  # is recorded once with its route/attempt/correlation.
  def track_filtered_no_results_attempt(question:, raw_answer:, config:, correlation_id:,
                                        latency_ms:, response_locale:, session_context:, output_channel:)
    tracked_model_id = @model_ref.include?('/') ? @model_ref.split('/').last : @model_ref

    TrackBedrockQueryJob.perform_later(
      model_id:       tracked_model_id,
      prompt_text:    [
        load_generation_prompt_with_locale(question,
                                           response_locale: response_locale,
                                           session_context: session_context,
                                           output_channel: output_channel),
        question
      ].compact_blank.join("\n\n"),
      answer_text:    raw_answer,
      user_query:     question,
      latency_ms:     latency_ms,
      route:          "rag_filtered",
      attempt:        1,
      max_tokens:     config.dig(:generation_configuration, :inference_config, :text_inference_config, :max_tokens),
      correlation_id: correlation_id,
      source:         "query",
      model_for_counting: "haiku"
    )
  rescue StandardError => e
    Rails.logger.warn("BedrockRagService: failed to track filtered no-results attempt — #{e.message}")
  end

  # Fallback when retrieve_and_generate returns no inline citations: call the
  # Retrieve API directly to obtain the raw retrieval results. These ALWAYS
  # carry the authoritative s3_uri in `metadata["x-amz-bedrock-kb-source-uri"]`
  # (and `location.s3_location.uri`), which is what EntityExtractorService
  # needs to dedup documents by physical identity.
  #
  # Uses N=3 (not the main query's number_of_results) — we only need enough
  # to resolve canonical_name/source_uri, not to feed generation context.
  # Scopes to the same entity filter applied in the main query when provided.
  #
  # Gate 9R I0 note: Retrieve is vector-only — no Claude tokens are billed and
  # the API returns no usage block, so it intentionally leaves no BedrockQuery
  # row. The billable invocations of a turn are the retrieve_and_generate calls.
  #
  # Output shape matches CitationProcessor#extract_citations for drop-in use.
  def fallback_retrieve(question, entity_s3_uris: [])
    vector_cfg = build_vector_search_configuration(
      question: question,
      entity_s3_uris: entity_s3_uris,
      number_of_results: 3,
      reranking: false
    )

    params = {
      knowledge_base_id: @knowledge_base_id,
      retrieval_query: { text: question },
      retrieval_configuration: { vector_search_configuration: vector_cfg }
    }
    resp = @client.retrieve(params)
    results = Array(resp.retrieval_results).map do |r|
      uri = r.location&.s3_location&.uri
      location = uri ? { bucket: uri.split('/')[2], key: uri.split('/')[3..].join('/'), uri: uri, type: 's3' } : nil
      {
        content:  r.content&.text,
        location: location,
        metadata: r.metadata || {}
      }
    end
    Rails.logger.info("BedrockRagService: fallback Retrieve returned #{results.size} chunk(s)")
    results
  rescue Aws::BedrockAgentRuntime::Errors::ServiceError => e
    Rails.logger.warn("BedrockRagService: fallback_retrieve failed — #{e.message}")
    []
  end

  # Retries the retrieve_and_generate call when Aurora Serverless is cold-starting.
  # Delegates to Bedrock::AuroraColdStartRetry (shared with KbSyncService).
  def retrieve_and_generate_with_retry(params)
    Bedrock::AuroraColdStartRetry.with_retry(
      error_classes: [ Aws::BedrockAgentRuntime::Errors::ServiceError ]
    ) do
      @client.retrieve_and_generate(params)
    end
  end

  def retrieve_with_retry(params)
    Bedrock::AuroraColdStartRetry.with_retry(
      error_classes: [ Aws::BedrockAgentRuntime::Errors::ServiceError ]
    ) do
      @client.retrieve(params)
    end
  end

  # Exhaustive queries retrieve broadly, then rerank down before generation.
  # Focused queries skip reranking to avoid an unnecessary paid model call.
  def reranking_config(region, profile:)
    return {} unless ENV['BEDROCK_RERANKER_ENABLED'].to_s.downcase == 'true'
    return {} unless profile.exhaustive_query?

    {
      reranking_configuration: {
        type: "BEDROCK_RERANKING_MODEL",
        bedrock_reranking_configuration: {
          number_of_reranked_results: profile.number_of_reranked_results,
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
  #
  # Language directive injected at TWO positions (reduced from 3 to save ~30–40 tokens/query):
  #   1. TOP (before # ROLE) — highest attention slot, first thing Haiku reads.
  #   2. TAIL (after session_context) — last signal before generation, overrides
  #      any English leakage from Recent Conversation or retrieved chunks.
  def load_generation_prompt_with_locale(question = nil, response_locale: nil, session_context: nil, output_channel: nil)
    base = self.class.load_generation_prompt_template
    locale = if response_locale.present?
      response_locale.to_sym
    elsif question.present?
      detect_language_from_question(question)
    else
      I18n.locale
    end
    lang_name = locale_to_language_name(locale)
    safety_directive = query_safety_directive(question)
    completeness_directive = query_completeness_directive(question)
    visual_directive = visual_label_directive(question)

    base = "#{language_directive_header(lang_name)}\n\n#{base}" if lang_name.present?

    if output_channel&.to_sym == :web && completeness_directive.blank?
      base = "#{base}\n\n#{web_delivery_channel_directive}"
    end
    base = "#{base}\n\n#{session_context}" if session_context.present?
    base = "#{base}\n\n#{language_directive_footer(lang_name)}" if lang_name.present?
    base = "#{base}\n\n#{safety_directive}" if safety_directive.present?
    base = "#{base}\n\n#{completeness_directive}" if completeness_directive.present?
    base = "#{base}\n\n#{visual_directive}" if visual_directive.present?
    base
  end

  # Question-triggered counterpart of the photo-only override: fires whenever
  # the question asks for functions/identification of schematic/diagram labels,
  # regardless of the pinned scope (a schematic page inside a pinned manual
  # carries the same inference risk as a pinned photo).
  def visual_label_directive(question)
    text = question.to_s
    return nil unless text.match?(/esquema|diagrama|plano|etiqueta|schematic|diagram|label/i) &&
                      text.match?(/funci[oó]n|identifica|componentes|qu[eé] es/i)

    literal_label_rules
  end

  def literal_label_rules
    <<~DIRECTIVE.strip
      # LITERAL LABEL RULES (schematic/diagram identifiers)
      For any identifier whose function the retrieved evidence does not state in
      printed words:
      - Render each such identifier as EXACTLY ONE line in this safe form:
        `<IDENTIFICADOR>: identificador visible; función: DATA_NOT_AVAILABLE`.
        No multi-line entries, no location prose, no neighboring-symbol
        descriptions — one line per identifier, nothing else about it.
      - Acronym expansion (BRK→freno, P→presión, T→tanque, RV→alivio, ORF→orificio)
        is forbidden. Never use the words puerto, válvula, solenoide, alivio,
        retención, orificio, freno, presión, diodo for these identifiers — not as
        descriptions, not as category headings, not for neighboring symbols.
      - Output undocumented identifiers as ONE flat list without category headers.
      - Locate identifiers with neutral position language only (bloque, línea,
        zona, esquina) and call printed numbers "marcas numeradas visibles".
    DIRECTIVE
  end

  # Appended only when delivering via web chat. Instructs the model to produce
  # structured but conversational Markdown that the web renderer can display
  # (bold, italic, paragraph breaks). Does NOT apply to WhatsApp.
  def web_delivery_channel_directive
    <<~DIRECTIVE.strip
      # DELIVERY CHANNEL
      Render concise Markdown for a technician using web chat.
      - Start with one direct sentence. Do not restate the question.
      - Keep focused answers under 300 words. Exhaustive checklists may be longer only
        to preserve every retrieved fact and expected result.
      - Use short paragraphs or numbered lists; no tables or horizontal rules.
      - Use bold sparingly for critical values or warnings.
      - Do not repeat the conclusion or recommend extra documents unless the selected
        evidence is insufficient.
      - Preserve relevant documented safety warnings without broadening them.
    DIRECTIVE
  end

  def session_context_with_entity_safety(session_context, entity_sources:)
    sources = Array(entity_sources).compact
    return session_context unless sources.any? && sources.all? { |source| source == "image_upload" }

    directive = <<~DIRECTIVE.strip
      # PHOTO LABEL SAFETY OVERRIDE
      The only selected evidence is a field-photo identity record. When it contains
      `Visible labels:` and says no legend or functional description is available:
      - Reproduce identifiers exactly as a flat list.
      - State DATA_NOT_AVAILABLE for category, function, acronym expansion, value,
        connection, translation, or procedure.
      - Do not group labels under inferred categories and do not describe what their
        prefixes, symbols, positions, or conventional names usually mean.
      - NEVER organize undocumented identifiers under category headings such as
        "Válvulas", "Diodos", "Puertos", "Orificios", "Relés", "Solenoides",
        "Componentes de alivio" — output ONE flat list of identifiers. A category
        heading over a label IS an inferred classification.
      - When locating an undocumented label, use neutral position language only
        (bloque, línea, zona, esquina). Do not name neighboring symbols by type
        (símbolo de válvula/bomba/motor/diodo) and do not call printed numbers
        "puertos" — refer to them as "marcas numeradas visibles".
      - Words such as valve, relief, check, orifice, pressure, brake, port, solenoid,
        válvula, alivio, retención, orificio, presión, freno and puerto are forbidden
        classifications unless those exact meanings appear under `Documented functions`,
        `Documented connections`, `Documented values`, or explicit visible text.
      - Safe form: `<LABEL>: identificador visible; categoría y función:
        DATA_NOT_AVAILABLE`.
      This override applies even when the user asks which "components" appear.
    DIRECTIVE

    [ session_context.presence, directive ].compact.join("\n\n")
  end

  def query_safety_directive(question)
    return nil unless question.to_s.match?(/\b(?:detener|detenga|parar|pare|stop|prohibir|fuera de servicio)\b/i)

    <<~DIRECTIVE.strip
      # STOP-WORK EVIDENCE OVERRIDE
      Separate inspection precautions from mandatory stop-work actions.
      - Use the exact text label `Precauciones e inspecciones` for findings,
        operator conditions, and preventive checks that the retrieved evidence
        does not explicitly pair with stopping, prohibiting operation, marking
        the machine, or taking it out of service.
      - Use the exact text label `Detención obligatoria con evidencia explícita`
        only for triggers that the retrieved evidence explicitly pairs with one
        of those mandatory actions.
      - When both evidence classes exist, include both labeled sections.
      - Inside `Detención obligatoria con evidencia explícita`, emit each item
        using exactly two non-empty lines, followed by one blank line:
        `Disparador: ...`
        `Acción obligatoria: ...`
      - Do not use bullets, sub-bullets, duplicated labels, multiline fields, or
        mandatory trigger prose outside those two-line items.
      - The trigger and its explicit mark/stop/prohibit/out-of-service action must
        come from the same retrieved evidence fragment. Never transfer an action
        from a neighboring sentence, another trigger, or prior conversation.
      - If the same fragment does not contain the mandatory action, place the
        finding under `Precauciones e inspecciones`.
      - Prior conversation context never promotes a precaution, including
        dizziness, unauthorized-person interference, leaks, missing labels, or
        electrical/hydraulic findings into mandatory stop-work.
      Do not invent stop-work rules or broaden the retrieved evidence.
    DIRECTIVE
  end

  def query_completeness_directive(question)
    profile = RagRetrievalProfile.new(question: question)
    return nil unless profile.exhaustive_query?

    <<~DIRECTIVE.strip
      # EXHAUSTIVE COMPLETENESS OVERRIDE
      The user requested a complete list.
      - Use prior conversation only to resolve the referent. Never treat a partial
        earlier list as coverage; rebuild the answer from the chunks retrieved for
        this turn.
      - Silently build a ledger of every explicit `Resultado` or `Resultado esperado`
        statement in the retrieved functional-test blocks, keyed by its controller
        or section heading. Drive entries from that result ledger, not from the list
        of actions: the final entry count must equal the ledger count.
      - Treat every separate source occurrence labeled `Resultado`, `Resultados`,
        `Resultado esperado`, or `Resultados esperados` as an independent ledger
        item. Do not deduplicate, merge, or suppress occurrences because their
        wording or expected behavior resembles another test.
      - Associate each result only with the numbered action that immediately governs
        it under the same heading: a result line belongs to the nearest preceding
        numbered action before the next numbered action. Preserve every result
        clause in that entry. Preserve a following REQUIRES_FIELD_VERIFICATION note
        in the same result instead of replacing it with a concrete observation.
      - Keep preparation steps without an independent result inside the `Acción`
        that enables the next verifiable result; never invent a result for
        preparation. A reset, reactivation, setup, or cleanup step with no explicit
        result is not an entry. Merge it into the next supported action when
        relevant, otherwise omit it. Never borrow a result from a preceding or
        following action, and never infer that a system is ready, normal, or
        restored.
      - Every entry must use exactly three non-empty lines, followed by one blank
        line, with these exact labels:
        `Prueba: ...`
        `Acción: ...`
        `Resultado esperado: ...`
        The three lines must be consecutive, with no blank line between fields.
        Put exactly one blank line only after `Resultado esperado`.
      - For this exhaustive response, override the general instruction to start
        with a direct sentence or numbered list. Begin immediately with the first
        `Prueba:` line.
      - The entire visible response must consist only of those entries. Do not use
        a title, introduction, section header, bullets, separators, notes, warnings,
        duplicated labels, multiline fields, conclusions, or test prose outside
        entries.
      - One entry may satisfy only one action-result unit. Do not combine multiple
        documented results into a summary entry.
      - Each `Prueba:` value must identify the source controller or section and the
        distinguishing action so every entry remains independently traceable.
      - Preserve documentary grouping and order. Never merge symmetric or opposite
        units: keep left/right, forward/reverse, and ground/platform controls as
        separate entries whenever the retrieved evidence documents both.
      - Before answering, silently audit every retrieved heading and test, including
        those symmetric pairs, against the entries you will emit.
      - Do not omit retrieved units for brevity; the 300-word target does not apply.
      - Do not name or invent a counterpart that is absent from the retrieved chunks.
    DIRECTIVE
  end

  # Top-of-prompt banner — first thing Haiku reads.
  def language_directive_header(lang_name)
    <<~HEADER.strip
      # RESPONSE LANGUAGE (ABSOLUTE PRIORITY)
      You MUST write your ENTIRE response in #{lang_name}.
      - This overrides the language of the retrieved documents and any prior conversation.
      - If chunks are in another language, translate the relevant content into #{lang_name}.
      - Section headers, bullet labels, time estimates, safety notes, and the closing must all be in #{lang_name}.
    HEADER
  end

  # Tail reminder — placed AFTER session_context so it is the last instruction
  # Haiku sees before producing the answer. Counteracts language drift caused
  # by English assistant turns in Recent Conversation history.
  def language_directive_footer(lang_name)
    <<~FOOTER.strip
      # FINAL LANGUAGE REMINDER
      Regardless of the language used in the retrieved documents or in the recent conversation above, your answer MUST be written entirely in #{lang_name}. Do not mix languages.
    FOOTER
  end

  # Detects response language from the question text. Does not depend on browser/headers.
  # Returns :es for Spanish, :en otherwise.
  #
  # Heuristic (robust to accent-less Spanish typical of WhatsApp/field typing):
  #   1. Any Spanish diacritic or inverted punctuation (á é í ó ú ü ñ ¿ ¡) → :es
  #   2. At least 2 distinct ASCII-only Spanish stopwords present → :es
  #   3. Else → :en
  #
  # The token list is kept intentionally conservative: only words with no common
  # English homograph ("is", "the", "a" are excluded) so that 2 hits is a strong
  # signal without false-positives on English queries mentioning Spanish names.
  ES_TOKENS = %w[
    el la los las un una unos unas
    ellos ellas nosotros vosotros ustedes
    esto eso este ese esta estos estas esos esas
    aquel aquella aquellos aquellas
    mi tu su sus mis tus
    para por con sin desde hasta hacia entre segun sobre
    pero porque aunque mientras cuando donde como cual quien
    cuanto cuanta cuantos cuantas que
    es son esta estan estas estamos hay tiene tienen tenemos
    puedo puede pueden podemos podria podrian
    deseo quiero quieres quiere queremos quieren
    tengo tenemos
    hacer hace hacen hago hiciste
    decir dice dicen digo
    guiame dame dime busco buscar necesito explica explicame ayudame ayuda
    paso pasos tiempo tarda tardar tardara duracion integracion
    instalacion reparar mantenimiento documentacion informacion
    hola gracias buenos buenas
  ].freeze
  ES_TOKEN_SET = Set.new(ES_TOKENS).freeze

  ES_DIACRITIC_PATTERN = /[áéíóúüñ¿¡]/.freeze

  def detect_language_from_question(question)
    self.class.detect_language_from_question(question)
  end

  def self.detect_language_from_question(question)
    return I18n.locale if question.blank?

    text = question.to_s.strip.downcase
    return :es if text.match?(ES_DIACRITIC_PATTERN)

    # Tokenize on ASCII letters (diacritic case already handled above).
    tokens  = text.scan(/\b[a-z]+\b/).uniq
    matches = tokens.count { |t| ES_TOKEN_SET.include?(t) }
    return :es if matches >= 2

    :en
  end

  def locale_to_language_name(locale)
    { es: "Spanish", en: "English" }[locale.to_sym]
  end

  def localized_no_results(locale)
    I18n.with_locale(locale) { I18n.t("rag.no_results_found") }
  end

  def localized_pinned_no_results(locale)
    I18n.with_locale(locale) { I18n.t("rag.pinned_no_results") }
  end

  # Reads `app/prompts/bedrock/generation.txt` once per process in production
  # (and per call in dev/test so prompt edits are picked up without a restart).
  # Each RAG request renders the prompt twice (build_complete_optimized_config
  # + the post-response token-count assembly) — without memoization that means
  # 2 File.read syscalls per request multiplied by N concurrent requests.
  def self.load_generation_prompt_template
    if Rails.env.production?
      @generation_prompt_template ||= Rails.root.join("app/prompts/bedrock/generation.txt").read
    else
      Rails.root.join("app/prompts/bedrock/generation.txt").read
    end
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

  # Keep pricing and runtime behavior aligned even when ENV, tenant config or a
  # caller-supplied custom_config requests a larger generation/retrieval budget.
  def enforce_query_contractual_limits(config)
    bounded = config.deep_dup
    limits  = ContractualLimits::QUERY

    vector = bounded.dig(:retrieval_configuration, :vector_search_configuration)
    if vector
      requested = vector[:number_of_results].to_i
      vector[:number_of_results] = requested.clamp(1, limits[:max_top_k])
    end

    inference = bounded.dig(:generation_configuration, :inference_config, :text_inference_config)
    if inference
      requested = inference[:max_tokens].to_i
      inference[:max_tokens] = requested.clamp(1, limits[:max_output_tokens])
    end

    bounded
  end

  # Returns true when the query explicitly names a document not in the session URIs,
  # or when the query is long enough to suggest a new document context.
  # Checking explicit names first ensures short queries like "Que es el Esquema SOPREL?"
  # are not incorrectly filtered to the current session document.
  SHORT_QUERY_MAX_CHARS = 60
  def query_names_different_document?(question, entity_s3_uris)
    # Extract basenames (without extension) from the session URIs.
    session_stems = entity_s3_uris.map { |uri|
      File.basename(uri.to_s, ".*").downcase.gsub(/[_\-]/, " ")
    }

    # Always check for capitalised words that look like a document name.
    # This catches short queries like "Que es el Esquema SOPREL?" where the
    # length heuristic alone would incorrectly apply the session filter.
    candidate_names = question.to_s.scan(/[A-Z][a-zA-Z0-9]{3,}(?:\s+[A-Z][a-zA-Z0-9]{3,})*/).map(&:downcase)
    if candidate_names.any?
      return true if candidate_names.any? { |name|
        session_stems.none? { |stem| stem.include?(name) || name.include?(stem) }
      }
    end

    # No explicit document name signal — for short queries assume same-document follow-up.
    return false if question.to_s.length <= SHORT_QUERY_MAX_CHARS

    false
  end

  # When stop_sequences includes "</DOC_REFS>", the model halts before emitting the
  # closing tag. Re-append it so DOC_REFS_PATTERN can still match the block.
  def normalize_doc_refs_tag(text)
    return text if text.blank?
    return text if text.include?("</DOC_REFS>")
    return "#{text}</DOC_REFS>" if text.include?("<DOC_REFS>")
    text
  end

  def extract_doc_refs(answer_text)
    match = answer_text.match(DOC_REFS_PATTERN)
    return { clean_answer: answer_text, doc_refs: nil } unless match

    begin
      parsed = JSON.parse(match[1].strip)

      unless parsed.is_a?(Array) && parsed.all? { |r| r.is_a?(Hash) && r["canonical_name"].present? }
        Rails.logger.warn("BedrockRagService: <DOC_REFS> JSON valid but unexpected structure")
        return { clean_answer: answer_text, doc_refs: nil }
      end

      sanitized = parsed.map do |ref|
        aliases = Array(ref["aliases"])
          .map { |a| a.to_s.strip }
          .select { |a| a.length.between?(2, 60) }
          .reject { |a| a.match?(/[|⚠️→←]|\*\*|^\#/) }
          .first(10)

        {
          "source_uri"     => ref["source_uri"].to_s,
          "canonical_name" => ref["canonical_name"].to_s.strip,
          "aliases"        => aliases,
          "doc_type"       => ref["doc_type"].to_s.presence || "unknown"
        }
      end

      clean = answer_text.sub(DOC_REFS_PATTERN, '').rstrip
      { clean_answer: clean, doc_refs: sanitized }

    rescue JSON::ParserError => e
      Rails.logger.warn("BedrockRagService: <DOC_REFS> JSON parse failed: #{e.message}")
      { clean_answer: answer_text, doc_refs: nil }
    end
  end
end
