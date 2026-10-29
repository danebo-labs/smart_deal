# frozen_string_literal: true

# app/services/bedrock_rag_service.rb

require 'aws-sdk-bedrockagentruntime'
require 'aws-sdk-core/static_token_provider'
require 'digest'
require 'json'
require_relative 'bedrock/citation_processor'
require_relative 'rag/answer_safety_processor'

class BedrockRagService
  include AwsClientInitializer

  # Custom error classes
  class MissingKnowledgeBaseError < StandardError; end
  class BedrockServiceError < StandardError; end

  # Matches the default Bedrock guardrail response when no KB results are found.
  BEDROCK_NO_RESULTS_PATTERN = /\AI'?m sorry[,.]|sorry,?\s+i\s+(am\s+)?unable\s+to\s+(assist|help)/i.freeze

  DOC_REFS_PATTERN = /<DOC_REFS>\s*(.*?)\s*<\/DOC_REFS>/m.freeze

  # retrieve_and_generate owns the output/citation contract through this
  # placeholder. Verified 2026-07-26 against the production KB: any text emitted
  # AFTER it makes Bedrock discard the generated answer and return its canned
  # "Sorry, I am unable to assist you with this request." — the same failure mode
  # the retired </DOC_REFS> stop sequence caused. Every dynamic directive is
  # therefore appended before the placeholder, which is always re-emitted last.
  OUTPUT_FORMAT_PLACEHOLDER = "$output_format_instructions$"
  # Bedrock fills $output_format_instructions$ inside retrieve_and_generate and
  # parses the model's citation XML. A direct generation cannot receive that
  # opaque text. This line only numbers the same chunks so [n] can be resolved.
  DOCUMENT_IDENTITY_CITATION_INSTRUCTIONS = <<~TEXT.strip
    Cite a claim taken from a search result with [n], where n is that result's source number. Do not cite a result you did not use.
  TEXT
  # Attribution contract for direct document-identity generation. It is not
  # part of the shared generation template, so retrieve_and_generate and the
  # other direct routes do not receive it. This route also omits the three
  # FIELD_GUIDANCE lines and the two general-inference clauses below. The
  # contract keeps documented information, optional interpretation, and
  # missing information distinct, and it precedes the citation line.
  # Replaces the previous field-report paragraph. A report that something was
  # not seen leaves that check open. It does not count as performing the check.
  FIELD_REPORT_PARAGRAPH = <<~TEXT.strip.freeze
    The technician's report records what was stated, including what was not seen, not measured, and not done. A report that something was not seen leaves the documentary check about that thing open: state the check and the condition the passage gives, and do not mark it done or discarded. Do not rank a cause the passages do not rank. An example in the retrieved text stays an example and does not establish that mechanism on this equipment. Keep the indicator name the technician used; a different indicator named in a passage is a different indicator. Earlier assistant lines are previous conclusions of this assistant, not the technician's report and not confirmed facts. The Active Field Problem record is shown to the technician with your answer; do not restate whether a check is done or open. State the documented checks that fit the report with the passage's own verb and condition. Then give one next observation or check as your own orientation, with its reason taken from the report and the passages, not as an order or likelihood the passages do not state, and ask at most one question. Do not replace those checks with a refusal, and do not add a step, adjustment, or replacement the passages do not state.
  TEXT
  DOCUMENTED_INFORMATION_PLAN = <<~TEXT.strip.freeze
    - Documented information ("Según el plano" for this drawing): state only what the retrieved body text supports and links to the component asked about, with [n]. Compatible fragments of the same document may be combined when they support that same link. A printed label, a column heading, or a bus name supports the label and its documented section, location, and neighboring labels; it does not by itself establish the component's function, supply, voltage, or connection. ACTION and EXPECTED_RESULT lines in FIELD_RECORD are extraction annotations, not independent evidence from the original document. They must not by themselves establish a function, supply, voltage, or connection. The physical-connection rule and TOPOLOGY_EDGE records above remain in force. Do not transfer a fact from another label. Distinguish extracted table indices from numbering printed on the drawing.
  TEXT
  DOCUMENTED_INFORMATION_GENERAL = <<~TEXT.strip.freeze
    - Documented information: state only what the retrieved body text supports, with [n]. ACTION and EXPECTED_RESULT lines in FIELD_RECORD are extraction annotations, not independent evidence from the original document.
  TEXT
  DOCUMENT_IDENTITY_ATTRIBUTION_CONTRACT = <<~TEXT.strip.freeze
    # DOCUMENT IDENTITY ATTRIBUTION
    Keep documented statements, optional interpretations, and missing information distinct. Never mix a documented claim and an unconfirmed interpretation in the same sentence. Express these distinctions naturally in the question's language without headings.

    #{FIELD_REPORT_PARAGRAPH}

    #{DOCUMENTED_INFORMATION_PLAN}

    - Optional interpretation ("Interpretación posible, no confirmada por estos pasajes"): omit it unless it helps the technician. Use at most two sentences without [n]. It may explain only what a label's word commonly designates in the trade, explicitly as a possibility and with the reservation that these passages do not confirm it. It must not state this equipment's function, what the component drives, its supply, voltage, connection, terminal, or wiring. A marker does not make an unsupported equipment specification acceptable.

    - Missing information ("Falta en los pasajes"): state the relevant information these passages do not provide once, scoped to the passages in this prompt. Do not claim that the whole drawing, document, PDF, or manual lacks it. Do not assert a datum as documented and then deny that it is documented.

    When distinguishing two labels, explain their documented sections and locations first. A concise answer based on those distinctions is sufficient; do not enumerate every neighboring label or the complete circuit unless it helps answer the question. If the evidence does not settle which physical element the technician is following, say so and ask for one useful observation that the technician can see or read on the equipment or drawing. A closing question must not presuppose an undocumented function, connection, or value.
  TEXT
  PARTIAL_ABSTENTION_PROMPT_PREFIX = "- PARTIAL_ABSTENTION_CONTRACT:"
  GROUNDED_SYNTHESIS_PROMPT_PREFIX = "- GROUNDED_SYNTHESIS:"
  FIELD_GUIDANCE_PROMPT_PREFIX = "- FIELD_GUIDANCE:"
  # Removed only by document_identity_generation_prompt. The same lines keep
  # compatible documented facts, the manual-citation voice, and the ban on
  # invented values and procedures. Other routes keep both clauses.
  # The shared role says explicit user input is an answer source. On this route
  # that sentence makes a report of what was not seen look like a finished check.
  DOCUMENT_IDENTITY_ROLE_SENTENCE = <<~TEXT.strip.freeze
    Answer only from the retrieved documentation and explicit user input. Your job is
    to make documented information clear and actionable without adding technical
    knowledge, requirements, procedures, or safety judgments from memory.
  TEXT
  DOCUMENT_IDENTITY_ROLE_REPLACEMENT = <<~TEXT.strip.freeze
    Answer from the retrieved documentation. The technician's words are the report of this job, not a documented procedure; a check is done only when the technician reports doing it. State the documented checks and their conditions. Do not add technical knowledge, requirements, procedures, or safety judgments from memory.
  TEXT
  DOCUMENT_IDENTITY_INFERENCE_CLAUSES = [
    "Reason, infer, and conclude from chunks. ",
    " A field check that is inference says so (\"Como verificación de campo …\")."
  ].freeze
  # Lines 7-9 of generation.txt. The system-role path removes this block
  # before substitution and does not edit its text.
  DOCUMENT_IDENTITY_CONTEXT_BLOCK = "# CONTEXT\nQuery: $query$\nResults: $search_results$".freeze
  # system is nil while RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE is off. to_s is then
  # the single user message, byte for byte the previous prompt.
  DocumentIdentityPrompt = Data.define(:system, :user) do
    def to_s
      system.nil? ? user.to_s : "#{system}\n\n#{user}"
    end
  end
  STRICT_ONLY_PROMPT_PREFIX = "- STRICT_ONLY:"
  GROUNDED_SYNTHESIS_CONTRACT_VERSION = "gs-v1"
  STRICT_CONTRACT_VERSION = "strict-v1"
  CITATION_MARKER_PATTERN = /\[[1-9]\d*\]/.freeze
  RAG_QUALITY_EXCLUDED_KEYS = %i[question answer_snippet citation_titles].freeze
  # Query configurations: one embedded logical operator, five clauses per list.
  # https://docs.aws.amazon.com/bedrock/latest/userguide/kb-test-config.html
  BEDROCK_FILTER_MAX_LIST = 5
  URI_METADATA_KEYS = %w[x-amz-bedrock-kb-source-uri original_source_uri].freeze
  # Explicit document scope was requested and is not fully authorized.
  # No Bedrock call, no open retry, no account_filter.
  DENY_RETRIEVAL = "DENY_RETRIEVAL"

  # Deterministic failure-semantics normalization (Gate B).
  # Haiku frequently states absence in prose ("la documentación no contiene…")
  # without emitting the literal protocol marker. Total absence keeps the legacy
  # behavior; partial absence is marked only when the missing fragment requests
  # the same relation as the question.
  ABSENCE_MARKER_PATTERN = /DATA_NOT_AVAILABLE|REQUIRES?_FIELD_VERIFICATION/.freeze
  LEGACY_ABSENCE_LEAD_CHARS = 280
  ABSENCE_PHRASE_PATTERNS = [
    /no\s+(?:se\s+)?proporciona/i,
    /no\s+(?:se\s+)?especifica/i,
    /no\s+contiene/i,
    /no\s+(?:se\s+)?documenta/i,
    /no\s+se\s+(?:encontr[oó]|encuentra)/i,
    /\bno\s+encontr[eé]\b/i,
    /(?:does\s+not|doesn'?t|do\s+not)\s+(?:contain|specify|document|provide)/i,
    /\bnot\s+(?:available|documented|specified|found)\b/i
  ].freeze

  # Default RAG config (safety-critical for elevator domain).
  # Overridden by ENV (BEDROCK_RAG_*) and account.bedrock_config.rag_config when present.
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
  def build_complete_optimized_config(region: 'us-east-1', question: nil, response_locale: nil, session_context: nil, entity_s3_uris: [], entity_sources: [], output_channel: nil, apply_page_filter: true)
    cfg = @rag_config
    vector_config = build_vector_search_configuration(
      region: region,
      question: question,
      entity_s3_uris: entity_s3_uris,
      entity_sources: entity_sources,
      apply_page_filter: apply_page_filter
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
            max_tokens: cfg[:generation_max_tokens]
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
                                        reranking: true, apply_page_filter: true)
    profile = RagRetrievalProfile.new(entity_sources: entity_sources, question: question)
    vector_config = {
      number_of_results: number_of_results || profile.number_of_results,
      override_search_type: @rag_config[:search_type],
      **(reranking ? reranking_config(region, profile: profile) : {})
    }

    vector_config[:filter] = retrieval_filter(
      entity_s3_uris: entity_s3_uris,
      entity_sources: entity_sources,
      question: question,
      apply_page_filter: apply_page_filter
    )

    vector_config
  end

  # @param knowledge_base_id [String, nil] Override KB ID (takes precedence)
  # @param account [Account] Required account for metadata filter enforcement
  def initialize(knowledge_base_id: nil, account: nil)
    raise ArgumentError, "account is required for BedrockRagService" unless account

    client_options = build_aws_client_options
    @region = client_options[:region] || 'us-east-1'
    @client = Aws::BedrockAgentRuntime::Client.new(client_options)
    @account = account
    @knowledge_base_id = knowledge_base_id.presence ||
                         account_bedrock_config&.knowledge_base_id ||
                         ENV.fetch('BEDROCK_KNOWLEDGE_BASE_ID', nil).presence ||
                         Rails.application.credentials.dig(:bedrock, :knowledge_base_id)
    @citation_processor = Bedrock::CitationProcessor.new
    @rag_config = resolve_rag_config

    # @model_ref holds either a Bedrock inference profile ID or a full foundation-model ARN.
    @model_ref = BedrockClient::QUERY_MODEL_ID
    @grounded_synthesis = Rag::GroundedSynthesisFlag.enabled_for?(@account)

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
  # @param auto_scope_filter [Boolean] Ignored. WhatsApp used it to turn a
  #   catalog token into a URI filter because that channel had no pin control.
  #   The web pin is entity_s3_uris. A question does not choose a document.
  def query(question, session_id: nil, custom_config: {}, response_locale: nil, session_context: nil,
            entity_s3_uris: [], entity_sources: [], output_channel: nil, force_entity_filter: false,
            auto_scope_filter: false, account_id: nil, user_id: nil, conversation_session_id: nil,
            correlation_id: nil, include_diagnostics: false, episode: nil, equipment_identity: :omit,
            raw_question: nil, context_truncated: nil, omit_evidence_records: false,
            conv_session: nil)
    unless @knowledge_base_id
      error_msg = 'Knowledge Base ID not configured. Please set BEDROCK_KNOWLEDGE_BASE_ID environment variable or configure in Rails credentials.'
      Rails.logger.error(error_msg)
      raise MissingKnowledgeBaseError, error_msg
    end

    Rails.logger.info("Querying Knowledge Base with: #{question}")

    start_time = Time.current
    @omit_evidence_records = omit_evidence_records == true
    attribution = {
      account_id: account_id || @account&.id,
      user_id: user_id,
      conversation_session_id: conversation_session_id
    }

    begin
      @retrieval_denied = false
      @open_retrieval_outcome_reason = nil
      @evidence_applicability = nil
      explicit_uris = Array(entity_s3_uris).map(&:to_s).compact_blank.uniq
      if explicit_uris.any?
        decision = Rag::KnowledgeScopePolicy.authorize_retrieval_set(explicit_uris, viewer_account: @account)
        if decision.denied?
          return deny_retrieval_result(question: question, session_id: session_id, response_locale: response_locale, correlation_id: correlation_id)
        end

        entity_s3_uris = decision.uris
      end

      effective_session_context = session_context_with_entity_safety(
        session_context,
        entity_sources: entity_sources
      )
      if (scoped = document_identity_scope_result(
        question,
        episode: episode,
        equipment_identity: equipment_identity,
        response_locale: response_locale,
        session_context: effective_session_context,
        output_channel: output_channel,
        entity_s3_uris: entity_s3_uris,
        entity_sources: entity_sources,
        force_entity_filter: force_entity_filter,
        account_id: attribution[:account_id],
        user_id: user_id,
        conversation_session_id: conversation_session_id,
        correlation_id: correlation_id,
        raw_question: raw_question,
        context_truncated: context_truncated,
        conv_session: conv_session
      ))
        return scoped
      end
      @evidence_applicability = Rag::DocumentIdentityScope::IDENTITY_UNKNOWN_REFERENCE
      @open_retrieval_outcome_reason = "identity_unknown"

      # Apply the technician pin when the caller forced it, or when the query
      # does not name a different document. auto_scope_filter is ignored: a
      # question does not choose a manual.
      apply_filter = entity_s3_uris.any? &&
        (force_entity_filter || !query_names_different_document?(question, entity_s3_uris))
      filtered_uris = apply_filter ? entity_s3_uris : []

      if entity_s3_uris.any?
        Rails.logger.info("BedrockRagService: entity_filter=#{apply_filter} uris=#{filtered_uris.size} forced=#{force_entity_filter}")
      end

      unknown_identity_reference_result(
        question: question,
        session_id: session_id,
        response_locale: response_locale,
        session_context: effective_session_context,
        output_channel: output_channel,
        entity_sources: entity_sources,
        force_entity_filter: force_entity_filter,
        custom_config: custom_config,
        attribution: attribution,
        correlation_id: correlation_id,
        include_diagnostics: include_diagnostics,
        raw_question: raw_question,
        context_truncated: context_truncated,
        start_time: start_time,
        filtered_uris: filtered_uris,
        apply_filter: apply_filter
      )
    rescue Aws::BedrockAgentRuntime::Errors::ServiceError => e
      Rails.logger.error("Bedrock RAG error: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      raise BedrockServiceError, "Failed to query Knowledge Base: #{e.message}"
    end
  end

  def retrieve_chunks(question, entity_s3_uris: [], entity_sources: [],
                      force_entity_filter: false, number_of_results: nil,
                      account_id: nil, user_id: nil, conversation_session_id: nil,
                      correlation_id: nil, route_taken: nil,
                      vector_search_configuration: nil)
    unless @knowledge_base_id
      raise MissingKnowledgeBaseError, "Knowledge Base ID not configured"
    end

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    resolved_uris = Array(entity_s3_uris).map(&:to_s).compact_blank.uniq
    if resolved_uris.any?
      decision = Rag::KnowledgeScopePolicy.authorize_retrieval_set(resolved_uris, viewer_account: @account)
      if decision.denied?
        r1a_probe_filter(correlation_id, question, nil, reason: "DENY_RETRIEVAL")
        return {
          chunks: [],
          retrieval: DENY_RETRIEVAL,
          retrieval_trace: { retrieval: DENY_RETRIEVAL, bedrock_calls: 0 }
        }
      end

      resolved_uris = decision.uris
    end
    if vector_search_configuration
      vector_config = vector_search_configuration
      apply_filter = Array(@applied_pin_uris).any?
    else
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
    end
    r1a_probe_filter(correlation_id, question, { retrieval_configuration: { vector_search_configuration: vector_config } })
    response = retrieve_with_retry(
      knowledge_base_id: @knowledge_base_id,
      retrieval_query: { text: question },
      retrieval_configuration: { vector_search_configuration: vector_config }
    )

    chunks = Array(response.retrieval_results).each_with_index.map do |result, index|
      metadata = retrieval_chunk_metadata({ metadata: result.metadata })
      source_uri = result.location&.s3_location&.uri
      content = result.content&.text.to_s

      {
        rank: index + 1,
        content: content,
        score: result.score,
        original_source_uri: metadata&.[]("original_source_uri"),
        bedrock_source_uri: metadata&.[]("x-amz-bedrock-kb-source-uri"),
        location_uri: source_uri,
        metadata: metadata,
        chunk_sha256: Digest::SHA256.hexdigest(content)
      }
    end
    kept, rejected = select_publishable_chunks(
      chunks,
      probe: { correlation_id: correlation_id, query: question, stage: "publication_gate" }
    )
    @rejected_result_count = rejected
    chunks = kept.each_with_index.map { |chunk, index| chunk.merge(rank: index + 1) }

    elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    PilotUsageLog.log(
      "kb_retrieve",
      account_id: account_id,
      user_id: user_id,
      conversation_session_id: conversation_session_id,
      correlation_id: correlation_id,
      route: "retrieve_only", route_taken: route_taken || "retrieve_only",
      latency_ms: elapsed_ms, result: "ok",
      results_count: chunks.size, filter_applied: apply_filter,
      rejected_result_count: @rejected_result_count.to_i,
      retrieval_denied_reason: @retrieval_denied_reason,
      retrieval_query_text: question.to_s,
      retrieval_query_sha: Digest::SHA256.hexdigest(question.to_s),
      requested_k: vector_config[:number_of_results],
      effective_k: chunks.size,
      search_type: vector_config[:override_search_type],
      filter_fingerprint: Digest::SHA256.hexdigest(vector_config[:filter].to_json)[0, 16]
    )

    {
      chunks: chunks,
      retrieval_trace: retrieval_trace(
        resolved_scope_s3_uris: resolved_uris,
        applied_filter_s3_uris: apply_filter ? Array(@applied_pin_uris) : [],
        force_entity_filter: force_entity_filter,
        vector_search_configuration: vector_config
      )
    }
  rescue Aws::BedrockAgentRuntime::Errors::ServiceError => e
    raise BedrockServiceError, "Failed to retrieve Knowledge Base chunks: #{e.message}"
  end

  def self.deny_retrieval_result(question:, session_id: nil, response_locale: nil)
    Rag::ValidationCapture.record(
      "route_exit",
      "stage" => "route",
      "result" => "deny_retrieval",
      "exit" => "deny_retrieval",
      "condition" => "pin_denied"
    )
    locale = response_locale.presence || I18n.locale
    {
      answer: I18n.with_locale(locale) { I18n.t("rag.pin_unavailable") },
      citations: [],
      retrieved_citations: [],
      doc_refs: nil,
      session_id: session_id,
      rag_ms: 0,
      retrieval: DENY_RETRIEVAL,
      generation_mode: DENY_RETRIEVAL,
      model_invoked: false,
      route_outcome: "abstained",
      retrieval_trace: {
        retrieval: DENY_RETRIEVAL,
        bedrock_calls: 0,
        resolved_scope_s3_uris: [],
        applied_filter_s3_uris: [],
        question_sha256: Digest::SHA256.hexdigest(question.to_s)
      }
    }
  end

  def deny_retrieval_result(question:, session_id: nil, response_locale: nil, correlation_id: nil)
    log_open_retrieval(correlation_id)
    self.class.deny_retrieval_result(question: question, session_id: session_id, response_locale: response_locale)
  end

  private

  def document_identity_scope_result(question, episode:, response_locale:, entity_s3_uris:, entity_sources:,
                                     force_entity_filter:, account_id:, user_id:, conversation_session_id:,
                                     correlation_id:, session_context: nil, output_channel: nil,
                                     equipment_identity: :omit, raw_question: nil, context_truncated: nil,
                                     conv_session: nil)
    Thread.current[:document_identity_scope] = nil
    @evidence_applicability = nil
    identity = resolved_equipment_identity(episode, equipment_identity)
    return nil unless identity == :malformed || (identity.respond_to?(:known?) && identity.known?)
    if identity == :malformed || !Rag::DocumentIdentityScopeFlag.enabled?
      Rag::DocumentIdentityScopeEvent.record(
        identity: identity.is_a?(Rag::EquipmentIdentity) ? identity : nil,
        status: :unavailable,
        reason: identity == :malformed ? :malformed_identity : :scope_disabled,
        correlation_id: correlation_id,
        account_id: account_id,
        user_id: user_id,
        conversation_session_id: conversation_session_id,
        episode: episode
      )
      return identity_closed_result(
        status: :unavailable,
        reason: identity == :malformed ? :malformed_identity : :scope_disabled,
        question: question,
        response_locale: response_locale
      )
    end

    profile = RagRetrievalProfile.new(entity_sources: entity_sources, question: question)
    number_of_results = profile.number_of_results.clamp(1, ContractualLimits::QUERY[:max_top_k])
    retrieval = retrieve_chunks(
      question,
      entity_s3_uris: entity_s3_uris,
      entity_sources: entity_sources,
      force_entity_filter: force_entity_filter,
      number_of_results: number_of_results,
      account_id: account_id,
      user_id: user_id,
      conversation_session_id: conversation_session_id,
      correlation_id: correlation_id
    )
    if retrieval[:retrieval].to_s == DENY_RETRIEVAL
      return deny_retrieval_result(question: question, response_locale: response_locale, correlation_id: correlation_id)
    end

    enforce_phase2_retrieved_body!(retrieval[:chunks], correlation_id: correlation_id)

    original = Array(retrieval[:chunks])
    applied = Rag::DocumentIdentityScope.apply(
      original, identity, focus_uris: entity_s3_uris, viewer_account: @account
    )
    record_document_identity_scope(original, applied, path: "document_identity")
    delivered_chunks = applied.status == :scoped ? applied.chunks.size : 0
    Rag::DocumentIdentityScopeEvent.record(
      identity: identity,
      applied: applied,
      correlation_id: correlation_id,
      account_id: account_id,
      user_id: user_id,
      conversation_session_id: conversation_session_id,
      episode: episode,
      results_count: original.size,
      contexts_delivered: delivered_chunks
    )
    if applied.status == :unavailable
      return identity_closed_result(
        status: :unavailable,
        reason: applied.reason || :identity_unavailable,
        question: question,
        response_locale: response_locale,
        retrieval: retrieval
      )
    end
    companion = applied.status == :no_compatible
    guidance = if companion
      Rag::CompanionGuidanceContext.build(
        question: question,
        identity: identity,
        session_context: session_context,
        labels: applied.labels,
        locale: effective_response_locale(question, response_locale: response_locale)
      )
    end
    companion_turn = companion_turn_applies?(
      applied: applied,
      chunks: applied.chunks,
      episode: episode,
      raw_question: raw_question
    )
    @companion_plan_pending = nil
    @companion_plan_retained = nil
    companion_chunks = companion_turn ? companion_assembled_chunks(applied.chunks, episode: episode) : nil
    companion_plan = if companion_turn
      Rag::CompanionPlan.prepare(
        raw_question: raw_question, chunks: companion_chunks, episode: episode,
        session: conv_session, correlation_id: correlation_id
      )
    end
    prompt = if companion
      guidance.to_s
    elsif companion_turn
      DocumentIdentityPrompt.new(system: companion_plan.system, user: companion_plan.user)
    else
      document_identity_generation_prompt(
        question, applied.chunks,
        labels: applied.labels,
        response_locale: response_locale,
        session_context: session_context,
        output_channel: output_channel,
        omit_evidence_records: @omit_evidence_records == true
      )
    end
    generation_truncated = context_truncated == true || (companion && guidance.context_truncated?)
    raw_answer = begin
      Rag::ValidationCapture.attempt_unless_set(1)
      generation_kwargs = {
        max_tokens: @rag_config[:generation_max_tokens],
        temperature: @rag_config[:generation_temperature],
        tracking: {
          account_id: account_id,
          user_id: user_id,
          conversation_session_id: conversation_session_id,
          correlation_id: correlation_id
        }
      }
      if companion
        document_identity_generator.query(prompt, **generation_kwargs)
      elsif companion_turn
        companion_plan_answer(companion_plan, generation_kwargs[:tracking].merge(user_query: question))
      else
        document_identity_generator.query(prompt.user, system: prompt.system, **generation_kwargs)
      end
    rescue Timeout::Error, Net::ReadTimeout, Net::OpenTimeout, BedrockServiceError => e
      return attach_generation_trace!(
        identity_closed_result(
          status: :unavailable,
          reason: identity_failure_reason(e, stage: :generation),
          question: question,
          response_locale: response_locale,
          retrieval: retrieval,
          model_invoked: true
        ),
        prompt, raw_turn: raw_question, sent_question: question, truncated: generation_truncated
      )
    rescue StandardError => e
      raise unless e.class.name.start_with?("Aws::", "Seahorse::")

      return attach_generation_trace!(
        identity_closed_result(
          status: :unavailable,
          reason: :generation_error,
          question: question,
          response_locale: response_locale,
          retrieval: retrieval,
          model_invoked: true
        ),
        prompt, raw_turn: raw_question, sent_question: question, truncated: generation_truncated
      )
    end
    if raw_answer.blank? && !companion_turn
      Rails.logger.warn("[DOCUMENT_IDENTITY] generation_blank; required identity stays closed")
      return attach_generation_trace!(
        identity_closed_result(
          status: :unavailable,
          reason: :generation_blank,
          question: question,
          response_locale: response_locale,
          retrieval: retrieval,
          model_invoked: true
        ),
        prompt, raw_turn: raw_question, sent_question: question, truncated: generation_truncated
      )
    end

    result = finish_document_identity_generation(
      question: question,
      raw_answer: raw_answer,
      chunks: companion_turn ? companion_chunks : applied.chunks,
      response_locale: response_locale,
      retrieval: retrieval,
      companion: companion,
      safety_evidence: guidance&.safety_evidence,
      companion_turn: companion_turn,
      stop_reason: companion_turn ? @companion_plan_stop_reason : nil,
      technician_texts: companion_turn ? companion_technician_texts(conv_session, episode, raw_question) : nil,
      manufacturer: companion_turn ? companion_manufacturer(episode) : nil,
      raw_question: raw_question
    )
    if companion && result[:answer].blank?
      return attach_generation_trace!(
        identity_closed_result(
          status: :unavailable,
          reason: :generation_blank,
          question: question,
          response_locale: response_locale,
          retrieval: retrieval,
          model_invoked: true
        ),
        prompt, raw_turn: raw_question, sent_question: question, truncated: generation_truncated
      )
    end
    result[:equipment_identity_status] = applied.status.to_s
    result[:equipment_identity_reason] = applied.reason&.to_s
    attach_generation_trace!(
      result, prompt, raw_turn: raw_question, sent_question: question, truncated: generation_truncated
    )
  rescue Timeout::Error, Net::ReadTimeout, Net::OpenTimeout, BedrockServiceError => e
    identity_closed_result(
      status: :unavailable,
      reason: identity_failure_reason(e, stage: :retrieval),
      question: question,
      response_locale: response_locale
    )
  rescue StandardError => e
    raise unless e.class.name.start_with?("Aws::", "Seahorse::")

    identity_closed_result(
      status: :unavailable,
      reason: :retrieval_error,
      question: question,
      response_locale: response_locale
    )
  end

  def unknown_identity_retrieval_config(question:, response_locale:, session_context:, output_channel:,
                                         entity_s3_uris:, entity_sources:, custom_config:, apply_page_filter:)
    base_config = build_complete_optimized_config(
      region: @region,
      question: question,
      response_locale: response_locale,
      session_context: session_context,
      entity_s3_uris: entity_s3_uris,
      entity_sources: entity_sources,
      output_channel: output_channel,
      apply_page_filter: apply_page_filter
    )
    enforce_account_filter(enforce_query_contractual_limits(deep_merge_configs(base_config, custom_config)))
  end

  def unknown_identity_guidance(raw_turn:, session_context:, chunks:, response_locale:, question:,
                                 empty_retrieval: false, pinned_focus_empty: false)
    Rag::CompanionGuidanceContext.build(
      question: raw_turn,
      identity: nil,
      session_context: session_context,
      labels: [],
      locale: effective_response_locale(question, response_locale: response_locale),
      mode: :unknown,
      manuals: Rag::CompanionGuidanceContext.withheld_manuals(chunks),
      empty_retrieval: empty_retrieval,
      pinned_focus_empty: pinned_focus_empty
    )
  end

  # Unknown identity: one Retrieve. A positive reference enters the publication
  # contract. Every other unknown turn, and every contract failure, uses
  # body-free companion guidance. An unforced pin that comes back empty still
  # retries once over the open corpus before that choice.
  def unknown_identity_reference_result(question:, session_id:, response_locale:, session_context:,
                                        output_channel:, entity_sources:, force_entity_filter:,
                                        custom_config:, attribution:, correlation_id:,
                                        include_diagnostics:, raw_question:, context_truncated:,
                                        start_time:, filtered_uris:, apply_filter:)
    @last_citation_attribution = nil
    @unknown_identity_publication = nil
    query_correlation_id = correlation_id.presence || "query:#{SecureRandom.uuid}"
    config = unknown_identity_retrieval_config(
      question: question,
      response_locale: response_locale,
      session_context: session_context,
      output_channel: output_channel,
      entity_s3_uris: filtered_uris,
      entity_sources: entity_sources,
      custom_config: custom_config,
      apply_page_filter: true
    )
    if @retrieval_denied
      r1a_probe_filter(query_correlation_id, question, nil, reason: @retrieval_denied_reason.presence || "DENY_RETRIEVAL")
      return deny_retrieval_result(
        question: question, session_id: session_id, response_locale: response_locale, correlation_id: query_correlation_id
      )
    end

    retry_open = apply_filter && !force_entity_filter
    retrieval = nil
    marked = []
    prompt = nil
    raw_answer = nil
    raw_turn = raw_question.presence || question
    reference_turn = Rag::UnknownIdentityPublication.reference_request?(raw_turn)
    guidance = nil
    focus_empty = false

    2.times do |index|
      Rag::ValidationCapture.attempt = index + 1
      if index == 1
        config = unknown_identity_retrieval_config(
          question: question,
          response_locale: response_locale,
          session_context: session_context,
          output_channel: output_channel,
          entity_s3_uris: [],
          entity_sources: entity_sources,
          custom_config: custom_config,
          apply_page_filter: false
        )
        if @retrieval_denied
          r1a_probe_filter(query_correlation_id, question, nil, reason: @retrieval_denied_reason.presence || "DENY_RETRIEVAL")
          return deny_retrieval_result(
            question: question, session_id: session_id, response_locale: response_locale, correlation_id: query_correlation_id
          )
        end
      end

      attempt_uris = index.zero? ? filtered_uris : []
      retrieval = retrieve_chunks(
        question,
        entity_s3_uris: attempt_uris,
        entity_sources: entity_sources,
        force_entity_filter: force_entity_filter && index.zero? && attempt_uris.any?,
        vector_search_configuration: config.dig(:retrieval_configuration, :vector_search_configuration),
        account_id: attribution[:account_id],
        user_id: attribution[:user_id],
        conversation_session_id: attribution[:conversation_session_id],
        correlation_id: query_correlation_id,
        route_taken: "identity_unknown_reference"
      )
      if retrieval[:retrieval].to_s == DENY_RETRIEVAL
        return deny_retrieval_result(
          question: question, session_id: session_id, response_locale: response_locale, correlation_id: query_correlation_id
        )
      end

      chunks = Array(retrieval[:chunks])
      enforce_phase2_retrieved_body!(chunks, correlation_id: query_correlation_id)
      if chunks.empty?
        focus_empty = true if apply_filter && index.zero?
        if retry_open && index.zero?
          Rag::ValidationCapture.record(
            "route_exit",
            "exit" => "retry_open",
            "condition" => "empty_retrieval",
            "attempt" => index + 1,
            "correlation_id" => query_correlation_id
          )
          next
        end

        Rag::ValidationCapture.record(
          "route_exit",
          "exit" => "empty_guidance",
          "condition" => "empty_retrieval",
          "attempt" => index + 1,
          "correlation_id" => query_correlation_id
        )
        log_open_retrieval(query_correlation_id, outcome_reason: @open_retrieval_outcome_reason)
        return unknown_empty_guidance_result(
          question: question, raw_turn: raw_turn, session_id: session_id,
          response_locale: response_locale, session_context: session_context,
          output_channel: output_channel, retrieval: retrieval, config: config,
          attribution: attribution, correlation_id: query_correlation_id,
          include_diagnostics: include_diagnostics, raw_question: raw_question,
          context_truncated: context_truncated, start_time: start_time,
          focus_empty: focus_empty
        )
      end

      marked = Rag::DocumentIdentityScope.mark_unconfirmed_reference(chunks)
      publication = nil
      if reference_turn
        publication = Rag::UnknownIdentityPublication.attempt(
          client: document_identity_generator,
          question: question,
          chunks: chunks,
          locale: effective_response_locale(question, response_locale: response_locale),
          tracking: {
            account_id: attribution[:account_id],
            user_id: attribution[:user_id],
            conversation_session_id: attribution[:conversation_session_id],
            correlation_id: query_correlation_id,
            route: Array(@applied_pin_uris).any? ? "rag_filtered" : "rag_global",
            attempt: index + 1
          }
        )
        @unknown_identity_publication = publication
      end
      if publication&.accepted?
        guidance = nil
        prompt = publication.prompt
        raw_answer = publication.answer
      else
        guidance = unknown_identity_guidance(
          raw_turn: raw_turn,
          session_context: session_context,
          chunks: chunks,
          response_locale: response_locale,
          question: question
        )
        prompt = guidance.to_s
        raw_answer = document_identity_generator.query(
          prompt,
          max_tokens: @rag_config[:generation_max_tokens],
          temperature: @rag_config[:generation_temperature],
          tracking: {
            account_id: attribution[:account_id],
            user_id: attribution[:user_id],
            conversation_session_id: attribution[:conversation_session_id],
            correlation_id: query_correlation_id,
            route: Array(@applied_pin_uris).any? ? "rag_filtered" : "rag_global",
            attempt: index + 1
          }
        )
      end
      break unless publication&.accepted? && retry_open && index.zero? && (raw_answer.blank? || bedrock_no_results?(raw_answer))
    end

    if raw_answer.blank?
      locale = effective_response_locale(question, response_locale: response_locale)
      log_open_retrieval(query_correlation_id, outcome_reason: @open_retrieval_outcome_reason)
      return attach_generation_trace!(
        observe_unknown_reference!(
          open_reference_no_results(
            question: question,
            response_locale: response_locale,
            retrieval: retrieval,
            session_id: session_id,
            pinned: false
          ).merge(answer: localized_generation_retry(locale)),
          question: question, raw_answer: raw_answer, chunks: Array(retrieval[:chunks]), config: config,
          prompt: prompt,
          correlation_id: query_correlation_id, attribution: attribution,
          response_locale: response_locale, session_context: session_context,
          output_channel: output_channel, start_time: start_time,
          include_diagnostics: include_diagnostics
        ),
        prompt,
        raw_turn: raw_question,
        sent_question: question,
        truncated: context_truncated
      )
    end

    result = finish_document_identity_generation(
      question: question,
      raw_answer: raw_answer,
      chunks: Array(retrieval[:chunks]),
      response_locale: response_locale,
      retrieval: retrieval,
      companion: guidance.present?,
      safety_evidence: guidance&.safety_evidence
    )
    if bedrock_no_results?(raw_answer) && marked.any?
      result[:answer] = localized_generation_retry(effective_response_locale(question, response_locale: response_locale))
    end
    result.delete(:generation_mode)
    result.delete(:document_identity)
    result.delete(:route_outcome)
    result.delete(:model_invoked)
    result[:session_id] = session_id
    result[:rag_ms] = ((Time.current - start_time) * 1000).to_i
    stamp_unknown_identity_publication!(result)
    if guidance && result[:publication_mode] != Rag::UnknownIdentityPublication::MODE_FALLBACK
      result[:publication_mode] = "unknown_identity_guidance"
    end
    withhold_unconfirmed_identity!(
      result,
      raw_answer: raw_answer,
      chunks: Array(retrieval[:chunks]),
      question: question,
      response_locale: response_locale,
      check_raw: !@unknown_identity_publication&.accepted?
    )
    log_open_retrieval(query_correlation_id, outcome_reason: @open_retrieval_outcome_reason)
    attach_generation_trace!(
      observe_unknown_reference!(
        result,
        question: question, raw_answer: raw_answer, chunks: Array(retrieval[:chunks]), config: config,
        prompt: prompt,
        correlation_id: query_correlation_id, attribution: attribution,
        response_locale: response_locale, session_context: session_context,
        output_channel: output_channel, start_time: start_time,
        include_diagnostics: include_diagnostics
      ),
      prompt, raw_turn: raw_question, sent_question: question, truncated: context_truncated
    )
  end

  # Quality and regression logs only. The generation row is the direct invoke.
  # Retrieve stays off bedrock_queries.
  def observe_unknown_reference!(result, question:, raw_answer:, chunks:, config:, prompt:, correlation_id:,
                                 attribution:, response_locale:, session_context:, output_channel:,
                                 start_time:, include_diagnostics:)
    retrieved = Array(result[:retrieved_citations])
    doc_refs = result[:doc_refs]
    canned_no_results = raw_answer.present? && bedrock_no_results?(raw_answer)
    canned_with_retrieval = canned_no_results && chunks.any?
    evidence_mode = chunks.any? ? "retrieve_chunks" : "none"
    latency_ms = ((Time.current - start_time) * 1000).to_i
    guard = @last_citation_attribution || Rag::CitationAttributionGuard.new(question: question, citations: retrieved).call(result[:answer].to_s)
    tracked_model_id = @model_ref.to_s.include?("/") ? @model_ref.split("/").last : @model_ref
    input_tokens = AnthropicTokenCounter::LocalTokenizer.estimate([ prompt, question ].compact_blank.join("\n\n"))
    output_tokens = AnthropicTokenCounter::LocalTokenizer.estimate(raw_answer.to_s)

    log_rag_regression(
      config: config, retrieved_chunks: retrieved, observed_chunk_basis: evidence_mode,
      input_token_basis: "prompt_template_plus_observed_chunks",
      bedrock_cited_references_count: 0,
      doc_refs_present: doc_refs.present?, doc_refs_valid: doc_refs.present?,
      doc_refs_count: doc_refs&.size.to_i,
      entity_filter_applied: Array(@applied_pin_uris).any?,
      raw_answer: raw_answer.to_s, visible_answer: result[:answer],
      input_tokens: input_tokens, output_tokens: output_tokens, model_id: tracked_model_id, latency_ms: latency_ms
    )
    log_quality_signal(
      question: question, answer: result[:answer], citations: Array(result[:citations]),
      doc_refs: doc_refs, raw_citations: [], latency_ms: latency_ms,
      entity_filter: Array(@applied_pin_uris), evidence_mode: evidence_mode,
      retrieved_chunks: retrieved, canned_no_results: canned_no_results,
      canned_with_retrieval: canned_with_retrieval, correlation_id: correlation_id,
      attribution: attribution, citation_attribution: guard
    )
    if include_diagnostics
      result[:diagnostics] = {
        raw_answer: raw_answer.to_s,
        cited_chunks: Array(result[:citations]),
        safety_evidence_chunks: retrieved,
        canned_no_results: canned_no_results,
        canned_with_retrieval: canned_with_retrieval,
        raw_citation_groups: 0,
        raw_cited_references: 0,
        attribution_dropped: guard.dropped_segments
      }
      if result[:applicability_violation]
        result[:diagnostics][:applicability_violation] = result[:applicability_violation]
        if result[:applicability_violation_basis]
          result[:diagnostics][:applicability_violation_basis] = result[:applicability_violation_basis]
        end
      end
      %i[publication_mode publication_reference publication_rejected_fields publication_fallback_reason].each do |key|
        result[:diagnostics][key] = result[key] if result.key?(key)
      end
    end
    result
  end

  # Zero chunks reuse the retrieves already done in this turn. Guidance is the
  # one generation this path did not have. A failed generation keeps the retry
  # copy. The session pin is not cleared.
  def unknown_empty_guidance_result(question:, raw_turn:, session_id:, response_locale:, session_context:,
                                     output_channel:, retrieval:, config:, attribution:, correlation_id:,
                                     include_diagnostics:, raw_question:, context_truncated:, start_time:,
                                     focus_empty:)
    guidance = unknown_identity_guidance(
      raw_turn: raw_turn,
      session_context: session_context,
      chunks: [],
      response_locale: response_locale,
      question: question,
      empty_retrieval: true,
      pinned_focus_empty: focus_empty
    )
    prompt = guidance.to_s
    raw_answer = generate_empty_guidance(prompt, attribution, correlation_id)
    locale = effective_response_locale(question, response_locale: response_locale)
    if raw_answer.blank? || bedrock_no_results?(raw_answer)
      return empty_guidance_retry(
        question: question, response_locale: response_locale, retrieval: retrieval,
        session_id: session_id, prompt: prompt, config: config, attribution: attribution,
        correlation_id: correlation_id, include_diagnostics: include_diagnostics,
        raw_question: raw_question, context_truncated: context_truncated,
        start_time: start_time, session_context: session_context, output_channel: output_channel,
        locale: locale
      )
    end

    result = finish_document_identity_generation(
      question: question,
      raw_answer: raw_answer,
      chunks: [],
      response_locale: response_locale,
      retrieval: retrieval,
      companion: true,
      safety_evidence: guidance&.safety_evidence
    )
    if result[:answer].blank?
      return empty_guidance_retry(
        question: question, response_locale: response_locale, retrieval: retrieval,
        session_id: session_id, prompt: prompt, config: config, attribution: attribution,
        correlation_id: correlation_id, include_diagnostics: include_diagnostics,
        raw_question: raw_question, context_truncated: context_truncated,
        start_time: start_time, session_context: session_context, output_channel: output_channel,
        locale: locale
      )
    end

    notice = empty_retrieval_notice(locale, focus_empty: focus_empty)
    result[:answer] = [ notice, result[:answer] ].compact_blank.join("\n\n")
    result.delete(:generation_mode)
    result.delete(:document_identity)
    result.delete(:route_outcome)
    result.delete(:model_invoked)
    result[:session_id] = session_id
    result[:rag_ms] = ((Time.current - start_time) * 1000).to_i
    result[:publication_mode] = "unknown_identity_guidance"
    withhold_unconfirmed_identity!(
      result,
      raw_answer: raw_answer,
      chunks: [],
      question: question,
      response_locale: response_locale,
      check_raw: true
    )
    unless result[:answer].to_s.include?(I18n.t("rag.empty_search_notice", locale: locale))
      result[:answer] = [ notice, result[:answer] ].compact_blank.join("\n\n")
    end
    attach_generation_trace!(
      observe_unknown_reference!(
        result,
        question: question, raw_answer: raw_answer, chunks: [], config: config, prompt: prompt,
        correlation_id: correlation_id, attribution: attribution,
        response_locale: response_locale, session_context: session_context,
        output_channel: output_channel, start_time: start_time,
        include_diagnostics: include_diagnostics
      ),
      prompt,
      raw_turn: raw_question,
      sent_question: question,
      truncated: context_truncated == true || guidance.context_truncated?
    )
  end

  def generate_empty_guidance(prompt, attribution, correlation_id)
    document_identity_generator.query(
      prompt,
      max_tokens: @rag_config[:generation_max_tokens],
      temperature: @rag_config[:generation_temperature],
      tracking: {
        account_id: attribution[:account_id],
        user_id: attribution[:user_id],
        conversation_session_id: attribution[:conversation_session_id],
        correlation_id: correlation_id,
        route: Array(@applied_pin_uris).any? ? "rag_filtered" : "rag_global",
        attempt: 1
      }
    )
  rescue Timeout::Error, Net::ReadTimeout, Net::OpenTimeout, BedrockServiceError
    nil
  rescue StandardError => error
    raise unless error.class.name.start_with?("Aws::", "Seahorse::")

    nil
  end

  def empty_guidance_retry(question:, response_locale:, retrieval:, session_id:, prompt:, config:,
                            attribution:, correlation_id:, include_diagnostics:, raw_question:,
                            context_truncated:, start_time:, session_context:, output_channel:, locale:)
    failed = open_reference_no_results(
      question: question,
      response_locale: response_locale,
      retrieval: retrieval,
      session_id: session_id,
      pinned: false
    ).merge(answer: localized_generation_retry(locale))
    attach_generation_trace!(
      observe_unknown_reference!(
        failed,
        question: question, raw_answer: nil, chunks: [], config: config, prompt: prompt,
        correlation_id: correlation_id, attribution: attribution,
        response_locale: response_locale, session_context: session_context,
        output_channel: output_channel, start_time: start_time,
        include_diagnostics: include_diagnostics
      ),
      prompt,
      raw_turn: raw_question,
      sent_question: question,
      truncated: context_truncated
    )
  end

  def empty_retrieval_notice(locale, focus_empty:)
    parts = []
    parts << I18n.t("rag.pinned_focus_empty", locale: locale) if focus_empty
    parts << I18n.t("rag.empty_search_notice", locale: locale)
    parts.join(" ")
  end

  def open_reference_no_results(question:, response_locale:, retrieval:, session_id:, pinned:)
    locale = effective_response_locale(question, response_locale: response_locale)
    answer = pinned ? localized_pinned_no_results(locale) : localized_no_results(locale)
    answer = Rag::AnswerSafetyProcessor.new(locale: locale).call(answer, evidence: [])
    {
      answer: answer,
      citations: [],
      retrieved_citations: [],
      doc_refs: nil,
      session_id: session_id,
      retrieval_trace: retrieval.is_a?(Hash) ? retrieval[:retrieval_trace] : {},
      rag_ms: 0
    }
  end

  def document_identity_generation_prompt(question, chunks, response_locale:, session_context:, output_channel:,
                                          labels: [], omit_evidence_records: false)
    system_role = document_identity_system_role?
    plan = self.class.plan_context?(question, session_context, chunks)
    search_results = Rag::DocumentIdentityScope.generation_context(
      chunks,
      labels,
      records: plan || omit_evidence_records != true
    )
    template = withheld_document_identity_template(
      question,
      response_locale: response_locale,
      session_context: system_role ? nil : session_context,
      output_channel: output_channel
    )
    template = restore_plan_blocks(template) if plan
    if system_role
      parts = partition_document_identity_template(
        template,
        question: question,
        search_results: search_results,
        session_context: session_context,
        response_locale: response_locale,
        plan: plan
      )
      return DocumentIdentityPrompt.new(system: parts.fetch(:system), user: parts.fetch(:user))
    end

    DocumentIdentityPrompt.new(
      system: nil,
      user: substitute_document_identity_template(template, question, search_results, plan: plan)
    )
  end

  # The only read of RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE. Off keeps one user message.
  def document_identity_system_role?
    ENV["RAG_DOCUMENT_IDENTITY_SYSTEM_ROLE"] == "1"
  end

  # The only read of RAG_COMPANION_TURN. Absent or blank enables the plan
  # path. "0" and "false" keep the documentary prompt.
  def companion_turn_enabled?
    value = ENV["RAG_COMPANION_TURN"]
    return true if value.nil? || value.strip.empty?

    value == "1" || value == "true"
  end

  def companion_turn_applies?(applied:, chunks:, episode:, raw_question:)
    return false unless companion_turn_enabled?

    reason = companion_turn_skip_reason(applied: applied, chunks: chunks, episode: episode, raw_question: raw_question)
    note_companion_turn(reason || "applied")
    reason.nil?
  end

  def companion_turn_skip_reason(applied:, chunks:, episode:, raw_question:)
    return :system_role if document_identity_system_role?
    return :identity unless applied.status == :scoped
    return :plan if self.class.plan_request?(raw_question.to_s, nil)

    parsed = episode.is_a?(Rag::ActiveEpisode) ? episode : Rag::ActiveEpisode.parse(episode)
    return :episode if parsed.nil? || parsed.blank? || parsed.status != "active"
    return :raw_question if raw_question.blank?
    return :field_records if companion_field_records?(chunks)

    nil
  end

  def companion_field_records?(chunks)
    Array(chunks).any? do |chunk|
      next false if Rag::DocumentIdentityScope.reference_only_chunk?(chunk)

      narrative = Rag::DocumentIdentityScope.omit_terminal_evidence_records(chunk[:content].to_s)
      narrative.lines.any? { |line| line.strip.start_with?("FIELD_RECORD") }
    end
  end

  def note_companion_turn(reason)
    Rails.logger.info("[COMPANION_TURN] #{reason}")
    return unless Rag::ValidationCapture.active?

    Rag::ValidationCapture.record(
      "companion_turn",
      "result" => reason.to_s == "applied" ? "applied" : "skipped",
      "reason" => reason.to_s
    )
  end

  # One forced tool call. The answer text is rendered from the checked plan,
  # so a blank text reaches publication and abstains there.
  def companion_plan_answer(prepared, tracking)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = document_identity_generator.converse(prepared.params)
    latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    usage = track_companion_plan_usage(response, latency_ms, tracking)
    composed = Rag::CompanionPlan.compose(response, prepared)
    @companion_plan_pending = composed.pending
    @companion_plan_retained = prepared.facts.open_question
    @companion_plan_stop_reason = composed.stop_reason
    record_companion_plan(composed, usage.merge("latency_ms" => latency_ms, "model_id" => prepared.params[:model_id]))
    composed.text
  end

  def track_companion_plan_usage(response, latency_ms, tracking)
    usage = response.respond_to?(:usage) ? response.usage : nil
    input_tokens = usage.respond_to?(:input_tokens) ? usage.input_tokens.to_i : 0
    output_tokens = usage.respond_to?(:output_tokens) ? usage.output_tokens.to_i : 0
    tokens = { "input_tokens" => input_tokens.positive? ? input_tokens : nil, "output_tokens" => input_tokens.positive? ? output_tokens : nil }
    return tokens if input_tokens <= 0

    TrackBedrockQueryJob.perform_later(
      source: "query",
      route: "companion_plan",
      model_id: BedrockClient::QUERY_MODEL_ID,
      token_source: "provider_usage",
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      latency_ms: latency_ms,
      **tracking.to_h.symbolize_keys.slice(:correlation_id, :user_query, :account_id, :user_id, :conversation_session_id)
    )
    tokens
  rescue StandardError => error
    Rails.logger.warn("companion plan usage tracking failed #{error.class}")
    tokens || {}
  end

  def record_companion_plan(composed, usage)
    Rails.logger.info("[COMPANION_PLAN] usable=#{composed.check.usable?} rejections=#{composed.check.rejections.size}")
    return unless Rag::ValidationCapture.active?

    Rag::ValidationCapture.record(
      "companion_plan",
      usage.merge(
        "tool_input" => composed.input,
        "check" => composed.check.to_h,
        "stop_reason" => composed.stop_reason,
        "rendered" => composed.text
      )
    )
  end

  def companion_definition_source
    @companion_definition_source ||= Rag::CompanionDefinitionSource.new
  end

  def companion_assembled_chunks(chunks, episode: nil)
    catalog = companion_definition_source.catalog_for(chunks)
    result = Rag::CompanionDefinitionExpander.expand(
      chunks, catalog: catalog, targets: companion_answer_targets(episode)
    )
    if Rag::ValidationCapture.active?
      Rag::ValidationCapture.record(
        "companion_definitions",
        "catalog" => catalog.nil? ? "absent" : "present",
        "catalog_origin" => Rag::CompanionDefinitionCatalog.current.nil? ? "document_chunks" : "process",
        "added" => result.added,
        "omitted" => result.omitted
      )
    end
    result.chunks
  end

  def companion_answer_targets(episode)
    parsed = episode.is_a?(Rag::ActiveEpisode) ? episode : Rag::ActiveEpisode.parse(episode)
    return [] if parsed.nil? || parsed.blank?

    parsed.observations.flat_map { |item|
      answers = item["answers"]
      answers.is_a?(Hash) ? Array(answers["t"]) : []
    }.filter_map { |target|
      next unless target.is_a?(Hash) && target["document_key"].present? && target["filename"].present?

      target
    }.uniq { |target| [ target["document_key"], target["filename"] ] }
  end

  def companion_publication_sources(chunks)
    Array(chunks).each_with_index.map do |chunk, index|
      applicability = (chunk[:identity_applicability] || chunk["identity_applicability"]).to_s
      {
        "index" => index + 1,
        "content" => chunk[:content].to_s,
        "applicability" => applicability,
        "reference_only" => Rag::DocumentIdentityScope.reference_only_chunk?(chunk)
      }
    end
  end

  def companion_technician_texts(conv_session, episode, raw_question)
    texts = [ raw_question.to_s ]
    parsed = episode.is_a?(Rag::ActiveEpisode) ? episode : Rag::ActiveEpisode.parse(episode)
    unless parsed.nil? || parsed.blank?
      texts << parsed.goal&.[]("text")
      Array(parsed.observations).each { |item| texts << item["text"] }
      Array(parsed.checks).each do |item|
        texts << item["subject"]
        texts << item["result"]
      end
      Array(parsed.identifiers).each { |item| texts << item["value"] }
    end
    if conv_session.respond_to?(:conversation_history)
      Array(conv_session.conversation_history).each do |message|
        texts << message["content"] if message.is_a?(Hash) && message["role"] == "user"
      end
    end
    texts.compact
  end

  def companion_manufacturer(episode)
    parsed = episode.is_a?(Rag::ActiveEpisode) ? episode : Rag::ActiveEpisode.parse(episode)
    return nil if parsed.nil? || parsed.blank?

    fact = parsed.fact("manufacturer")
    return nil unless fact.is_a?(Hash) && fact["status"] == "known"

    fact["value"].to_s.squish.presence
  end

  def withheld_document_identity_template(question, response_locale:, session_context:, output_channel:)
    self.class.withhold_document_identity_inference(
      load_generation_prompt_with_locale(
        question,
        response_locale: response_locale,
        session_context: session_context,
        output_channel: output_channel,
        field_guidance: false
      )
    )
  end

  def substitute_document_identity_template(template, question, search_results, plan:)
    template
      .sub("$query$") { question.to_s }
      .sub("$search_results$") { search_results }
      .sub(OUTPUT_FORMAT_PLACEHOLDER) { document_identity_output_contract(plan: plan) }
  end

  def document_identity_output_contract(plan:)
    body = DOCUMENT_IDENTITY_ATTRIBUTION_CONTRACT
    body = body.sub(DOCUMENTED_INFORMATION_PLAN, DOCUMENTED_INFORMATION_GENERAL) unless plan
    "#{body}\n\n#{DOCUMENT_IDENTITY_CITATION_INSTRUCTIONS}"
  end

  def restore_plan_blocks(template)
    rules = self.class.topology_edge_rules
    template = insert_before_output_contract(template, rules) unless template.include?("RECORD_TYPE: TOPOLOGY_EDGE record")
    template = insert_before_output_contract(template, literal_label_rules) unless template.include?("# LITERAL LABEL RULES")
    template
  end

  def insert_before_output_contract(template, block)
    text = block.to_s.strip
    return template if text.empty?
    return "#{template.rstrip}\n\n#{text}\n" unless template.include?(OUTPUT_FORMAT_PLACEHOLDER)

    template.sub(OUTPUT_FORMAT_PLACEHOLDER, "#{text}\n\n#{OUTPUT_FORMAT_PLACEHOLDER}")
  end

  # Moves the context block, the session, and the language footer into the
  # user message. The remaining text stays in its current order.
  def partition_document_identity_template(template, question:, search_results:, session_context:, response_locale:, plan:)
    system_template = template.sub(DOCUMENT_IDENTITY_CONTEXT_BLOCK, "")
    footer = removable_language_footer(system_template, question, response_locale)
    system_template = system_template.sub("\n\n#{footer}", "") if footer
    context = DOCUMENT_IDENTITY_CONTEXT_BLOCK
      .sub("$query$") { question.to_s }
      .sub("$search_results$") { search_results }
    user = [ context, session_context.presence, footer ].compact.join("\n\n")
    system = system_template.sub(OUTPUT_FORMAT_PLACEHOLDER) { document_identity_output_contract(plan: plan) }
    { system: system, user: user }
  end

  def removable_language_footer(template, question, response_locale)
    locale = effective_response_locale(question, response_locale: response_locale)
    lang_name = locale_to_language_name(locale)
    return nil if lang_name.blank?

    footer = language_directive_footer(lang_name)
    template.include?("\n\n#{footer}") ? footer : nil
  end

  def document_identity_generator
    @document_identity_generator ||= AiProvider.new
  end

  def record_document_identity_scope(original, applied, path:, fallback: false)
    labels = applied.labels
    stats = {
      "retrieved" => original.size,
      "sent" => applied.chunks.size,
      "labels" => labels.count(&:present?),
      "other_equipment" => labels.count { |line| line.to_s.start_with?(Rag::DocumentIdentityScope::OTHER_EQUIPMENT_PREFIX) },
      "this_job" => labels.count { |line| line.to_s.start_with?("THIS JOB'S EQUIPMENT:") },
      "unconfirmed_general" => applied.unconfirmed_general,
      "undeclared_private" => applied.undeclared_private,
      "status" => applied.status&.to_s,
      "reason" => applied.reason&.to_s,
      "reference_only" => applied.reference_only?,
      "path" => path,
      "fallback" => fallback,
      "label_lines" => labels.compact
    }
    Thread.current[:document_identity_scope] = stats
    Rails.logger.info("[DOCUMENT_IDENTITY] #{stats.to_json}")
    capture_identity_policy(original, applied)
  end

  def resolved_equipment_identity(episode, equipment_identity)
    if equipment_identity != :omit
      return nil if equipment_identity.nil?
      return equipment_identity if equipment_identity.is_a?(Rag::EquipmentIdentity)

      return :malformed
    end

    Rag::EquipmentIdentity.from_episode(episode)
  end

  def identity_closed_result(status:, reason:, question:, response_locale:, retrieval: nil, model_invoked: false)
    Rag::ValidationCapture.record(
      "route_exit",
      "stage" => "route",
      "result" => "identity_closed",
      "exit" => "identity_closed",
      "condition" => reason&.to_s.presence || "unavailable",
      "status" => status.to_s
    )
    seal_identity_outcome(status: status, reason: reason, fallback: false)
    locale = effective_response_locale(question, response_locale: response_locale)
    answer = Rag::AnswerSafetyProcessor.new(locale: locale).call("DATA_NOT_AVAILABLE", evidence: [])
    {
      answer: answer,
      citations: [],
      retrieved_citations: [],
      doc_refs: nil,
      session_id: nil,
      retrieval_trace: retrieval.is_a?(Hash) ? retrieval[:retrieval_trace] : {},
      generation_mode: "document_identity_scope",
      model_invoked: model_invoked,
      route_outcome: :abstained,
      equipment_identity_status: status.to_s,
      equipment_identity_reason: reason&.to_s,
      document_identity: Thread.current[:document_identity_scope]
    }
  end

  def seal_identity_outcome(status:, reason:, fallback:)
    stats = Thread.current[:document_identity_scope] || {}
    stats["status"] = status.to_s
    stats["reason"] = reason.to_s if reason
    stats["fallback"] = fallback
    stats["path"] = "document_identity"
    Thread.current[:document_identity_scope] = stats
    Rails.logger.info("[DOCUMENT_IDENTITY] #{stats.to_json}")
  end

  def attach_generation_trace!(result, prompt, raw_turn:, sent_question:, truncated:)
    return result unless result.is_a?(Hash)

    result.merge!(Rag::CausalTrace.generation_fields(
      text: prompt,
      raw_turn: raw_turn,
      sent_question: sent_question,
      truncated: truncated
    ))
    record_published_answer(result, prompt, truncated)
    result
  rescue StandardError => error
    Rails.logger.warn("generation trace failed #{error.class}")
    result
  end

  def identity_failure_reason(error, stage:)
    timeout = error.is_a?(Timeout::Error) || error.is_a?(Net::ReadTimeout) || error.is_a?(Net::OpenTimeout)
    if stage == :generation
      timeout ? :generation_timeout : :generation_error
    else
      timeout ? :retrieval_timeout : :retrieval_error
    end
  end

  def finish_document_identity_generation(question:, raw_answer:, chunks:, response_locale:, retrieval:,
                                           companion: false, safety_evidence: nil, companion_turn: false,
                                           stop_reason: nil, technician_texts: nil, manufacturer: nil,
                                           raw_question: nil)
    if companion_turn
      return finish_companion_turn_generation(
        question: raw_question.presence || question,
        raw_answer: raw_answer,
        chunks: chunks,
        response_locale: response_locale,
        retrieval: retrieval,
        stop_reason: stop_reason,
        technician_texts: technician_texts,
        manufacturer: manufacturer
      )
    end

    no_results_locale = effective_response_locale(question, response_locale: response_locale)
    answer_text = extract_doc_refs(raw_answer.to_s)[:clean_answer]
    canned_no_results = bedrock_no_results?(answer_text)
    answer_text = localized_no_results(no_results_locale) if canned_no_results

    citations = document_identity_citation_records(chunks)
    unless companion
      answer_text = normalize_absence_semantics(
        answer_text,
        question: question,
        locale: no_results_locale,
        grounded_synthesis: @grounded_synthesis
      )
    end
    evidence = citations
    if companion && safety_evidence.present?
      evidence = citations + [ { content: safety_evidence } ]
    end
    answer_text = Rag::AnswerSafetyProcessor.new(locale: no_results_locale).call(
      answer_text,
      evidence: evidence,
      require_cited_evidence: !companion && !canned_no_results,
      companion_guidance: companion
    )
    attribution = Rag::CitationAttributionGuard.new(question: question, citations: citations).call(answer_text)
    @last_citation_attribution = attribution
    answer_text = attribution.answer
    if attribution.dropped_any? && !attribution.attributed_claims? &&
       Rag::AnswerSafetyProcessor.requires_evidence?(answer_text)
      answer_text = Rag::AnswerSafetyProcessor.new(locale: no_results_locale)
        .call("DATA_NOT_AVAILABLE", evidence: [])
    elsif companion
      answer_text = answer_text.gsub(/[ \t]*\[\d+\]/, "")
    end

    uncited = I18n.t("rag.uncited_technical_answer", locale: no_results_locale)
    missing = I18n.t("rag.data_not_available", locale: no_results_locale)
    route_outcome = if canned_no_results || answer_text == uncited || answer_text.strip == missing
      :abstained
    else
      :answered
    end

    result = {
      answer: answer_text,
      citations: @citation_processor.build_numbered_references(citations, answer_text, question: question),
      retrieved_citations: citations.compact,
      doc_refs: build_doc_refs(chunks.reject { |chunk| Rag::DocumentIdentityScope.reference_only_chunk?(chunk) }),
      session_id: nil,
      retrieval_trace: retrieval[:retrieval_trace],
      generation_mode: "document_identity_scope",
      model_invoked: true,
      route_outcome: route_outcome,
      document_identity: Thread.current[:document_identity_scope]
    }
    capture_cited_sources(result[:citations])
    result
  end

  def finish_companion_turn_generation(question:, raw_answer:, chunks:, response_locale:, retrieval:,
                                       stop_reason:, technician_texts:, manufacturer:)
    locale = effective_response_locale(question, response_locale: response_locale)
    extracted = extract_doc_refs(raw_answer.to_s)[:clean_answer]
    citations = document_identity_citation_records(chunks)
    safety = Rag::AnswerSafetyProcessor.new(locale: locale).call(
      extracted,
      evidence: citations,
      require_cited_evidence: true
    )
    attribution = Rag::CitationAttributionGuard.new(question: question, citations: citations).call(safety)
    @last_citation_attribution = attribution
    guarded = attribution.answer
    publication = Rag::CompanionTurnPublication.call(
      text: extracted,
      guarded_text: guarded,
      sources: companion_publication_sources(chunks),
      stop_reason: stop_reason,
      technician_texts: technician_texts,
      manufacturer: manufacturer,
      guards: [
        { "name" => "answer_safety", "before" => extracted, "after" => safety },
        { "name" => "citation_attribution", "before" => safety, "after" => guarded }
      ],
      locale: locale
    )
    record_companion_publication(publication, stop_reason)
    accepted = publication.accepted?
    answer_text = accepted ? guarded : Rag::CompanionTurnPublication.abstain_message(locale)
    result = {
      answer: answer_text,
      citations: @citation_processor.build_numbered_references(citations, answer_text, question: question),
      retrieved_citations: citations.compact,
      doc_refs: build_doc_refs(chunks.reject { |chunk| Rag::DocumentIdentityScope.reference_only_chunk?(chunk) }),
      session_id: nil,
      retrieval_trace: retrieval[:retrieval_trace],
      generation_mode: "document_identity_scope",
      model_invoked: true,
      route_outcome: accepted ? :answered : :abstained,
      companion_turn: true,
      companion_contract_invalid: !accepted,
      companion_reason: accepted ? nil : "companion_contract_invalid",
      companion_publication: publication.to_h,
      document_identity: Thread.current[:document_identity_scope],
      pending_question: companion_turn_pending(accepted, answer_text)
    }
    capture_cited_sources(result[:citations])
    result
  end

  def companion_turn_pending(accepted, answer_text)
    return nil unless accepted

    Rag::PendingQuestion.presented(@companion_plan_pending, answer_text, retained: @companion_plan_retained)
  end

  def record_companion_publication(publication, stop_reason)
    return unless Rag::ValidationCapture.active?

    Rag::ValidationCapture.record(
      "companion_publication",
      publication.to_h.merge("stop_reason" => stop_reason)
    )
  end

  def document_identity_citation_records(chunks)
    records = Array(chunks).map do |chunk|
      metadata = chunk[:metadata].to_h.stringify_keys
      uri = chunk[:location_uri].to_s
      location = nil
      if uri.present?
        bucket, key = uri.delete_prefix("s3://").split("/", 2)
        location = { bucket: bucket, key: key, uri: uri, type: "s3" }
      end
      {
        content: chunk[:content],
        location: location,
        metadata: metadata,
        identity_applicability: chunk[:identity_applicability]
      }
    end
    Rag::DocumentIdentityScope.citable_evidence(records)
  end

  private

  def stamp_unknown_identity_publication!(result)
    publication = @unknown_identity_publication
    return result unless publication

    result[:publication_mode] = publication.mode
    result[:publication_reference] = publication.reference_status
    result[:publication_rejected_fields] = publication.rejected_fields
    result[:publication_fallback_reason] = publication.fallback_reason
    result
  end

  def withhold_unconfirmed_identity!(result, raw_answer:, chunks:, question:, response_locale:, check_raw: true)
    checked_raw = check_raw ? raw_answer : nil
    kind = Rag::DocumentIdentityScope.unconfirmed_applicability_violation(
      result[:answer], checked_raw, chunks, question
    )
    return if kind.nil?

    basis = if kind == :procedure_application
      Rag::DocumentIdentityScope.unconfirmed_applicability_basis(result[:answer], checked_raw, chunks, question)
    end
    locale = effective_response_locale(question, response_locale: response_locale)
    result[:answer] = Rag::DocumentIdentityScope.unconfirmed_reference_withheld(chunks, locale: locale)
    result[:citations] = []
    result[:applicability_violation] = kind
    result[:applicability_violation_basis] = basis if basis
    Rag::DocumentIdentityScope.log_applicability_violation(kind, basis: basis)
  end

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
                         doc_refs_valid:, doc_refs_count:, entity_filter_applied:,
                         input_token_basis: "prompt_template_plus_observed_chunks")
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
      "input_token_basis" => input_token_basis,
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
                                        latency_ms:, response_locale:, session_context:, output_channel:,
                                        attribution:)
    tracked_model_id = @model_ref.include?('/') ? @model_ref.split('/').last : @model_ref
    prompt_text = [
      load_generation_prompt_with_locale(question,
                                         response_locale: response_locale,
                                         session_context: session_context,
                                         output_channel: output_channel),
      question
    ].compact_blank.join("\n\n")

    TrackBedrockQueryJob.perform_later(
      model_id:       tracked_model_id,
      input_tokens:   AnthropicTokenCounter::LocalTokenizer.estimate(prompt_text),
      output_tokens:  AnthropicTokenCounter::LocalTokenizer.estimate(raw_answer),
      token_source:   "estimated",
      user_query:     question,
      latency_ms:     latency_ms,
      route:          "rag_filtered",
      attempt:        1,
      max_tokens:     config.dig(:generation_configuration, :inference_config, :text_inference_config, :max_tokens),
      correlation_id: correlation_id,
      source:         "query",
      **attribution
    )
  rescue StandardError => e
    Rails.logger.warn("BedrockRagService: failed to track filtered no-results attempt — #{e.message}")
  end

  def log_quality_signal(question:, answer:, citations:, doc_refs:, raw_citations:, latency_ms:,
                         entity_filter:, evidence_mode:, retrieved_chunks:, canned_no_results:,
                         canned_with_retrieval:, correlation_id:, attribution:,
                         citation_attribution:)
    retrieved_source_uris = Array(retrieved_chunks)
      .filter_map { |chunk| observed_chunk_descriptor(chunk)["retrieved_source_uri"] }
      .uniq
      .first(10)

    payload = {
      ts:              Time.current.iso8601,
      question:        question.to_s.first(300),
      correlation_id:  correlation_id,
      account_id:      attribution[:account_id],
      user_id:         attribution[:user_id],
      conversation_session_id: attribution[:conversation_session_id],
      answer_snippet:  answer.to_s.first(600),
      answer_length:   answer.to_s.length,
      latency_ms:      latency_ms,
      chunk_count:     raw_citations.size,
      citations_count: citations.size,
      citation_titles: citations.map { |c| c[:title].to_s.first(80) },
      doc_refs:        doc_refs,
      entity_filter:   Array(entity_filter).first&.to_s&.first(80),
      entity_filter_count: Array(entity_filter).size,
      # Only references rendered with the answer count as attributed evidence.
      # DOC_REFS and Retrieve fallbacks are useful internal context/metadata, but
      # they do not prove that a generated claim was cited.
      evidence_present: citations.any?,
      retrieval_context_present: Array(retrieved_chunks).any? || Array(doc_refs).any? ||
        raw_citations.any?,
      canned_no_results: canned_no_results,
      canned_with_retrieval: canned_with_retrieval,
      evidence_mode:    evidence_mode,
      doc_refs_count:   Array(doc_refs).size,
      retrieved_source_uris: retrieved_source_uris,
      attribution_dropped_segments: citation_attribution.dropped_segments.size,
      attribution_anchors: citation_attribution.anchors,
      attribution_identities: citation_attribution.identities,
      contract_version: grounded_synthesis_contract_version,
      grounded_synthesis: grounded_synthesis?,
      model_id:        @model_ref,
      kb_id:           @knowledge_base_id
    }
    Rails.logger.info("[RAG_QUALITY] #{JSON.generate(payload)}")
    persist_quality_event(payload, question: question, answer: answer)
    PilotAuditLog.log(
      question: question,
      answer: answer,
      citations: citations,
      retrieved_chunks: retrieved_chunks,
      correlation_id: correlation_id,
      attribution: attribution
    )
  rescue => e
    Rails.logger.warn("log_quality_signal failed: #{e.message}")
  end

  # Durable [RAG_QUALITY] copy without raw text. Hashes stay so the report can
  # still join repeats; the full question/answer remain on the log line and
  # under PILOT_AUDIT_CAPTURE / Frente A.
  def persist_quality_event(payload, question:, answer:)
    durable = payload.except(*RAG_QUALITY_EXCLUDED_KEYS).merge(
      question_sha256: Digest::SHA256.hexdigest(question.to_s),
      answer_sha256: Digest::SHA256.hexdigest(answer.to_s)
    )
    PilotEventRecorder.record(PilotEvent::RAG_QUALITY_EVENT, durable)
  end

  # Builds prompt, estimates tokens via LocalTokenizer (~0 ms), logs [RAG_REGRESSION],
  # and enqueues TrackBedrockQueryJob. No network calls; safe to call on the request path.
  def track_rag_usage(question:, raw_answer:, visible_answer:, config:,
                      retrieved_chunks:, observed_chunk_basis:, input_token_basis:,
                      bedrock_cited_references_count:, doc_refs_present:, doc_refs_valid:,
                      doc_refs_count:, entity_filter_applied:, response_locale:,
                      session_context:, output_channel:, correlation_id:, generation_attempt:,
                      applied_filter_uris:, latency_ms:, model_id:, attribution:)
    chunks_text = Array(retrieved_chunks).filter_map { |c| c[:content].presence }.join("\n\n")
    full_prompt = [
      load_generation_prompt_with_locale(question, response_locale: response_locale,
                                         session_context: session_context, output_channel: output_channel),
      chunks_text,
      question
    ].compact_blank.join("\n\n")

    input_tokens  = AnthropicTokenCounter::LocalTokenizer.estimate(full_prompt)
    output_tokens = AnthropicTokenCounter::LocalTokenizer.estimate(raw_answer)

    log_rag_regression(
      config: config, retrieved_chunks: retrieved_chunks, observed_chunk_basis: observed_chunk_basis,
      input_token_basis: input_token_basis, bedrock_cited_references_count: bedrock_cited_references_count,
      doc_refs_present: doc_refs_present, doc_refs_valid: doc_refs_valid, doc_refs_count: doc_refs_count,
      entity_filter_applied: entity_filter_applied, raw_answer: raw_answer, visible_answer: visible_answer,
      input_tokens: input_tokens, output_tokens: output_tokens, model_id: model_id, latency_ms: latency_ms
    )

    TrackBedrockQueryJob.perform_later(
      model_id:       model_id,
      input_tokens:   input_tokens,
      output_tokens:  output_tokens,
      token_source:   "estimated",
      user_query:     question.to_s.truncate(500),
      latency_ms:     latency_ms,
      route:          applied_filter_uris.any? ? "rag_filtered" : "rag_global",
      attempt:        generation_attempt,
      max_tokens:     config.dig(:generation_configuration, :inference_config, :text_inference_config, :max_tokens),
      correlation_id: correlation_id,
      source:         "query",
      **attribution
    )
  end

  # Port of TrackBedrockQueryJob#log_regression_telemetry — runs in the service so
  # visible_output_tokens uses LocalTokenizer (zero latency) instead of the API counter.
  def log_rag_regression(config:, retrieved_chunks:, observed_chunk_basis:, input_token_basis:,
                         bedrock_cited_references_count:, doc_refs_present:, doc_refs_valid:,
                         doc_refs_count:, entity_filter_applied:, raw_answer:, visible_answer:,
                         input_tokens:, output_tokens:, model_id:, latency_ms:)
    ctx = regression_context(
      config: config,
      observed_chunks: retrieved_chunks,
      observed_chunk_basis: observed_chunk_basis,
      input_token_basis: input_token_basis,
      bedrock_cited_references_count: bedrock_cited_references_count,
      doc_refs_present: doc_refs_present,
      doc_refs_valid: doc_refs_valid,
      doc_refs_count: doc_refs_count,
      entity_filter_applied: entity_filter_applied
    )

    visible_tokens =
      if visible_answer.nil? || visible_answer.to_s == raw_answer.to_s
        output_tokens
      else
        AnthropicTokenCounter::LocalTokenizer.estimate(visible_answer.to_s)
      end

    payload = ctx.merge(
      "model_id"               => model_id,
      "latency_ms"             => latency_ms,
      "input_tokens_estimate"  => input_tokens,
      "raw_output_tokens"      => output_tokens,
      "visible_output_tokens"  => visible_tokens,
      "hidden_output_tokens"   => [ output_tokens.to_i - visible_tokens.to_i, 0 ].max,
      "raw_output_chars"       => raw_answer.to_s.length,
      "visible_output_chars"   => visible_answer.to_s.length,
      "contract_version"      => grounded_synthesis_contract_version,
      "grounded_synthesis"    => grounded_synthesis?
    )

    max_tokens = payload["configured_max_tokens"].to_i
    if max_tokens.positive?
      payload["raw_output_utilization"] = (output_tokens.to_f / max_tokens).round(4)
      payload["possible_truncation"]    = output_tokens.to_i >= (max_tokens * 0.95).floor
    end

    Rails.logger.info("[RAG_REGRESSION] #{JSON.generate(payload)}")
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
  def fallback_retrieve(question, entity_s3_uris: [], correlation_id: nil)
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
    r1a_probe_filter(correlation_id, question, params)
    resp = retrieve_with_retry(params)
    results = Array(resp.retrieval_results).map do |r|
      uri = r.location&.s3_location&.uri
      location = uri ? { bucket: uri.split('/')[2], key: uri.split('/')[3..].join('/'), uri: uri, type: 's3' } : nil
      {
        content:  r.content&.text,
        location: location,
        metadata: r.metadata,
        score: r.score
      }
    end
    results, rejected = select_publishable_chunks(
      results,
      probe: { correlation_id: correlation_id, query: question, stage: "fallback_retrieve" }
    )
    @rejected_result_count = @rejected_result_count.to_i + rejected
    Rails.logger.info(
      "BedrockRagService: fallback Retrieve returned #{results.size} authorized chunk(s) rejected=#{rejected}"
    )
    results
  rescue Aws::BedrockAgentRuntime::Errors::ServiceError => e
    Rails.logger.warn("BedrockRagService: fallback_retrieve failed — #{e.message}")
    []
  end

  # Nil until the phase 4 web check has loaded. Does not autoload it.
  def phase4_web_budget
    return unless defined?(Rag::Phase4WebCheck)

    Rag::Phase4WebCheck::Budget
  end

  # Nil until the phase 1 service has loaded its budget. Does not autoload it.
  def phase1_model_budget
    return unless defined?(Rag::Phase1ModelBudget)

    Rag::Phase1ModelBudget
  end

  # Nil until the phase 2 harness has loaded its budget. Does not autoload it.
  def phase2_model_budget
    return unless defined?(Rag::Phase2ModelBudget)

    Rag::Phase2ModelBudget
  end

  def phase2_retrieve_limit
    return unless defined?(Rag::Phase2RetrieveLimit)

    Rag::Phase2RetrieveLimit
  end

  # Nil until the phase 3 harness has loaded its budget. Does not autoload it.
  def phase3_model_budget
    return unless defined?(Rag::Phase3ModelBudget)

    Rag::Phase3ModelBudget
  end

  def phase3_retrieve_limit
    return unless defined?(Rag::Phase3RetrieveLimit)

    Rag::Phase3RetrieveLimit
  end

  # Nil until the phase 2 harness has loaded the body gate. Does not autoload it.
  def phase2_retrieved_body_gate
    return unless defined?(Rag::Phase2RetrievedBodyGate)

    Rag::Phase2RetrievedBodyGate
  end

  # Uses the chunks this turn already retrieved. A disarmed gate returns
  # without reading them and without starting another retrieval.
  def enforce_phase2_retrieved_body!(chunks, correlation_id: nil)
    gate = phase2_retrieved_body_gate
    return unless gate&.armed?

    gate.check!(chunks, correlation_id: correlation_id)
  end

  # The phase 4 web check applies only while that process is armed. Otherwise
  # phase 3, then phase 2, then phase 1, or nil when none of those runs is armed.
  def armed_validation_budget
    phase4 = phase4_web_budget
    return phase4 if phase4&.armed?

    phase3 = phase3_model_budget
    return phase3 if phase3&.armed?

    phase2 = phase2_model_budget
    return phase2 if phase2&.armed?

    phase1 = phase1_model_budget
    return phase1 if phase1&.armed?

    nil
  end

  def armed_retrieve_limit
    phase4 = phase4_web_budget
    return phase4 if phase4&.armed?

    phase3 = phase3_retrieve_limit
    return phase3 if phase3&.armed?

    phase2 = phase2_retrieve_limit
    return phase2 if phase2&.armed?

    nil
  end

  # Retries the retrieve_and_generate call when Aurora Serverless is cold-starting.
  # Delegates to Bedrock::AuroraColdStartRetry (shared with KbSyncService).
  # An armed phase 1 or phase 2 budget makes one attempt and skips that retry.
  def retrieve_and_generate_with_retry(params)
    record_retrieve_and_generate_request(params)
    budget = armed_validation_budget
    if budget&.armed?
      begin
        # One model attempt. The cold-start retry is another model call.
        budget.checkpoint!("retrieve_and_generate")
      rescue budget::Stop
        Rag::ValidationCapture.record_model_boundary("retrieve_and_generate", "blocked")
        raise
      end
    end
    Rag::ValidationCapture.record_model_boundary("retrieve_and_generate", "attempt_started")
    transport_attempt = 0
    response = begin
      if budget&.armed?
        transport_attempt = 1
        local_retrieve_and_generate(params)
      else
        Bedrock::AuroraColdStartRetry.with_retry(
          error_classes: [ Aws::BedrockAgentRuntime::Errors::ServiceError ],
          on_retry: (Rag::ValidationCapture.active? ? method(:note_cold_start_retry) : nil)
        ) do
          transport_attempt += 1
          local_retrieve_and_generate(params)
        end
      end
    rescue Rag::LocalPassLedger::Stop
      Rag::ValidationCapture.record_model_boundary("retrieve_and_generate", "blocked")
      raise
    rescue StandardError => error
      record_terminal_remote_error("retrieve_and_generate", error, transport_attempt)
      if budget&.armed?
        budget.record_error!("retrieve_and_generate", error)
        raise budget::Stop, "retrieve_and_generate stopped after #{error.class}"
      end

      raise
    end
    budget&.record_success!("retrieve_and_generate") if budget&.armed?
    record_retrieve_and_generate_response(response)
    response
  end

  # One physical retrieve_and_generate. The local ledger, when armed, counts
  # this call and refuses it before the SDK. Aurora retries call it again.
  def local_retrieve_and_generate(params)
    Rag::LocalPassLedger.single_attempt!(@client)
    result = Rag::LocalPassLedger.protect!(
      operation: "retrieve_and_generate",
      model_id: @model_ref.to_s,
      input_tokens: ContractualLimits::QUERY[:max_input_tokens],
      output_tokens: Rag::LocalPassLedger.output_tokens_from(params)
    ) { @client.retrieve_and_generate(params) }
    settle_local_retrieve_and_generate!(result, params)
    result
  end

  # The API returns no usage block. Provider usage, when present, replaces
  # the contractual hold. Request leaves and cited passages omit the chunks
  # the provider retrieved, so that estimate is recorded beside the hold and
  # does not release it. A response with no citations is not treated as a
  # near-zero input.
  def settle_local_retrieve_and_generate!(result, params)
    return if Rag::LocalPassLedger.settle_usage!(result, model_id: @model_ref.to_s)

    cited = retrieve_and_generate_citation_text(result)
    Rag::LocalPassLedger.note_partial_estimate!(
      model_id: @model_ref.to_s,
      input_tokens: AnthropicTokenCounter::LocalTokenizer.estimate(
        [ string_leaves(params), cited ].compact_blank.join("\n")
      ),
      output_tokens: AnthropicTokenCounter::LocalTokenizer.estimate(retrieve_and_generate_output_text(result))
    )
  end

  def retrieve_and_generate_output_text(result)
    output = result.respond_to?(:output) ? result.output : nil
    return output.text if output.respond_to?(:text)
    return output[:text] || output["text"] if output.is_a?(Hash)

    nil
  end

  def retrieve_and_generate_citation_text(result)
    citations = result.respond_to?(:citations) ? result.citations : nil
    parts = []
    Array(citations).each do |citation|
      refs = citation.respond_to?(:retrieved_references) ? citation.retrieved_references : nil
      Array(refs).each do |ref|
        content = ref.respond_to?(:content) ? ref.content : nil
        text = content.respond_to?(:text) ? content.text : content
        parts << text if text.is_a?(String)
      end
    end
    parts.join("\n")
  end

  def string_leaves(value)
    case value
    when String
      value
    when Hash
      value.values.map { |item| string_leaves(item) }.compact_blank.join("\n")
    when Array
      value.map { |item| string_leaves(item) }.compact_blank.join("\n")
    else
      ""
    end
  end

  def retrieve_with_retry(params)
    if Rag::ValidationCapture.active?
      recorded = if params.is_a?(Hash)
        params.merge("stage" => "retrieve", "result" => "sent")
      else
        params
      end
      Rag::ValidationCapture.record("retrieve", recorded)
    end
    transport_attempt = 0
    limit = armed_retrieve_limit
    limit.begin_logical! if limit&.armed?
    begin
      Bedrock::AuroraColdStartRetry.with_retry(
        error_classes: [ Aws::BedrockAgentRuntime::Errors::ServiceError ],
        on_retry: (Rag::ValidationCapture.active? ? method(:note_cold_start_retry) : nil)
      ) do
        transport_attempt += 1
        limit.before_physical! if limit&.armed?
        @client.retrieve(params)
      end
    rescue StandardError => error
      record_terminal_remote_error("retrieve", error, transport_attempt)
      raise
    end
  end

  def record_retrieve_and_generate_request(params)
    return unless Rag::ValidationCapture.active?

    recorded = params.is_a?(Hash) ? params.dup : { "params" => "unavailable" }
    recorded = recorded.merge(
      "stage" => "generate",
      "result" => "prepared",
      "operation" => "retrieve_and_generate",
      "documentary_context" => "template",
      "documentary_context_note" => "placeholders_are_not_resolved_chunks"
    )
    Rag::ValidationCapture.record("retrieve_and_generate", recorded)
  end

  def record_retrieve_and_generate_response(response)
    return unless Rag::ValidationCapture.active?

    output = response.respond_to?(:output) ? response.output : nil
    answer = output.respond_to?(:text) ? output.text : "unavailable"
    citations = response.respond_to?(:citations) ? response.citations : nil
    rows = []
    Array(citations).each do |citation|
      refs = citation.respond_to?(:retrieved_references) ? Array(citation.retrieved_references) : []
      refs.each do |ref|
        chunk = reference_to_chunk(ref)
        publishable, reason = publication_gate(chunk)
        score = ref.respond_to?(:score) ? ref.score : nil
        rows << retrieved_capture_row(chunk, publishable, reason).merge(
          "score" => score.nil? ? "unavailable" : score,
          "decision" => publishable ? "cited" : "rejected"
        )
      end
    end
    Rag::ValidationCapture.record(
      "generation_result",
      "stage" => "generate",
      "result" => "returned",
      "operation" => "retrieve_and_generate",
      "source" => "retrieve_and_generate",
      "answer" => answer,
      "full_result_set" => "unavailable",
      "error_class" => nil,
      "rows" => rows
    )
  end

  def note_cold_start_retry(attempt, delay)
    return unless Rag::ValidationCapture.active?

    Rag::ValidationCapture.record(
      "retry",
      "reason" => "aurora_cold_start",
      "attempt" => attempt,
      "delay_seconds" => delay
    )
  end

  def record_terminal_remote_error(operation, error, transport_attempt)
    return unless Rag::ValidationCapture.active?

    reason = error.respond_to?(:message) ? error.message.to_s : ""
    Rag::ValidationCapture.record(
      "terminal_error",
      "stage" => operation,
      "result" => "error",
      "operation" => operation,
      "error_class" => error.class.name,
      "reason" => reason.presence || "unavailable",
      "transport_attempt" => transport_attempt.to_i
    )
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

  # Resolves RAG config: defaults + ENV + account.bedrock_config.rag_config.
  # Precedence: account config > ENV > defaults.
  def resolve_rag_config
    from_env = {
      number_of_results: parse_int(ENV['BEDROCK_RAG_NUMBER_OF_RESULTS']),
      search_type: ENV['BEDROCK_RAG_SEARCH_TYPE'].presence,
      generation_temperature: parse_float(ENV['BEDROCK_RAG_GENERATION_TEMPERATURE']),
      generation_max_tokens: parse_int(ENV['BEDROCK_RAG_GENERATION_MAX_TOKENS'])
    }.compact
    from_account = account_bedrock_config&.rag_config
    from_account = from_account&.symbolize_keys&.compact || {}
    DEFAULT_RAG_CONFIG.merge(from_env).merge(from_account)
  end

  def account_bedrock_config
    @account.bedrock_config if @account.respond_to?(:bedrock_config)
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
  #
  # OUTPUT_FORMAT_PLACEHOLDER is lifted out before the dynamic directives are
  # appended and re-emitted last, so the citation contract always closes the prompt.
  def load_generation_prompt_with_locale(question = nil, response_locale: nil, session_context: nil, output_channel: nil, field_guidance: true)
    base = self.class.load_generation_prompt_template(
      grounded_synthesis: grounded_synthesis?,
      field_guidance: field_guidance
    )
    base = self.class.without_plan_blocks(base) unless self.class.plan_request?(question, session_context)
    output_contract = base.include?(OUTPUT_FORMAT_PLACEHOLDER)
    base = base.sub(OUTPUT_FORMAT_PLACEHOLDER, "").rstrip if output_contract
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
    # Detection stays on the two methods above. This substitute is the only
    # place that decides which completeness text is allowed into the prompt.
    prompt_completeness = completeness_directive_for(safety_directive, completeness_directive)
    visual_directive = visual_label_directive(question, session_context)

    base = "#{language_directive_header(lang_name)}\n\n#{base}" if lang_name.present?

    if output_channel&.to_sym == :web && completeness_directive.blank?
      base = "#{base}\n\n#{web_delivery_channel_directive}"
    end
    base = "#{base}\n\n#{session_context}" if session_context.present?
    base = "#{base}\n\n#{language_directive_footer(lang_name)}" if lang_name.present?
    base = "#{base}\n\n#{safety_directive}" if safety_directive.present?
    base = "#{base}\n\n#{prompt_completeness}" if prompt_completeness.present?
    base = "#{base}\n\n#{visual_directive}" if visual_directive.present?
    applicability = Rag::DocumentIdentityScope.applicability_block_for(@evidence_applicability)
    base = "#{base}\n\n#{applicability}" if applicability
    base = "#{base}\n\n#{OUTPUT_FORMAT_PLACEHOLDER}\n" if output_contract
    base
  end

  # Question-triggered counterpart of the photo-only override: fires whenever
  # the question asks for functions/identification of schematic/diagram labels,
  # regardless of the pinned scope (a schematic page inside a pinned manual
  # carries the same inference risk as a pinned photo).
  def visual_label_directive(question, session_context = nil)
    return nil unless self.class.plan_request?(question, session_context)

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
        The completeness and stop-work overrides do not remove or invalidate this safe form.
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
      - No headings or section titles: running prose only.
      - Keep focused answers under 300 words. Exhaustive checklists may be longer only
        to preserve every retrieved fact and expected result.
      - Use short paragraphs; no tables or horizontal rules.
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
      The question asks when work must stop. Answer in running prose, in the
      question's language, with no headings, field labels, bullets, or numbering.
      - Keep two things apart in that prose: the precautions, operator conditions,
        and preventive checks that the retrieved evidence does not explicitly pair
        with stopping, prohibiting operation, marking the machine, or taking it out
        of service; and the conditions that the evidence explicitly pairs with one
        of those mandatory actions. Say which is which in words.
      - Say each mandatory condition as one sentence that carries the documented
        trigger and the documented stop, prohibit, mark, or out-of-service action.
        Both must come from the same retrieved evidence fragment. Never transfer an
        action from a neighboring sentence, another trigger, or prior conversation.
      - If the same fragment does not contain the mandatory action, say the finding
        as a precaution, never as a stop condition.
      - Prior conversation context never promotes a precaution, including
        dizziness, unauthorized-person interference, leaks, missing labels, or
        electrical/hydraulic findings, into mandatory stop-work.
      Do not invent stop-work rules or broaden the retrieved evidence.
    DIRECTIVE
  end

  def query_completeness_directive(question)
    profile = RagRetrievalProfile.new(question: question)
    return nil unless profile.exhaustive_query?

    <<~DIRECTIVE.strip
      # EXHAUSTIVE COMPLETENESS OVERRIDE
      The user requested a complete list. Write it as running prose in the
      question's language: one short paragraph per documented test, with no
      headings, field labels, bullets, or numbering.
      - Use prior conversation only to resolve the referent. Never treat a partial
        earlier list as coverage; rebuild the answer from the chunks retrieved for
        this turn.
      - Silently build a ledger of every explicit `Resultado` or `Resultado esperado`
        statement in the retrieved functional-test blocks, keyed by its controller
        or section heading. Drive paragraphs from that result ledger, not from the
        list of actions: the paragraph count must equal the ledger count.
      - Treat every separate source occurrence labeled `Resultado`, `Resultados`,
        `Resultado esperado`, or `Resultados esperados` as an independent ledger
        item. Do not deduplicate, merge, or suppress occurrences because their
        wording or expected behavior resembles another test.
      - Associate each result only with the numbered action that immediately governs
        it under the same heading: a result line belongs to the nearest preceding
        numbered action before the next numbered action. Preserve every result
        clause in that paragraph. Preserve a following REQUIRES_FIELD_VERIFICATION
        note in the same paragraph, said in words, instead of replacing it with a
        concrete observation.
      - Keep preparation steps without an independent result inside the paragraph
        of the action that enables the next verifiable result; never invent a
        result for preparation. A reset, reactivation, setup, or cleanup step with
        no explicit result is not a paragraph. Merge it into the next supported
        action when relevant, otherwise omit it. Never borrow a result from a
        preceding or following action, and never infer that a system is ready,
        normal, or restored.
      - Each paragraph names the source controller or section and the
        distinguishing action, then says the documented result as a sentence, so
        every paragraph remains independently traceable. When the document gives
        no result for that action, say so in one clause; do not print
        DATA_NOT_AVAILABLE.
      - For this exhaustive response, override the general instruction to start
        with a direct sentence. Begin immediately with the first paragraph.
      - The entire visible response must consist only of those paragraphs. Do not
        add a title, introduction, section header, separators, notes, warnings,
        conclusions, or test prose outside them.
      - One paragraph covers exactly one action-result unit. Do not combine
        multiple documented results into a summary paragraph.
      - Preserve documentary grouping and order. Never merge symmetric or opposite
        units: keep left/right, forward/reverse, and ground/platform controls as
        separate paragraphs whenever the retrieved evidence documents both.
      - Before answering, silently audit every retrieved heading and test, including
        those symmetric pairs, against the paragraphs you will emit.
      - Do not omit retrieved units for brevity; the 300-word target does not apply.
      - Do not name or invent a counterpart that is absent from the retrieved chunks.
    DIRECTIVE
  end

  # Stop-work owns the answer when both intents match. Completeness remains
  # only as coverage inside that prose. The one-paragraph-per-test instruction
  # is not injected beside the stop-work override.
  def completeness_directive_for(safety_directive, completeness_directive)
    return nil if completeness_directive.blank?
    return stop_work_exhaustive_coverage_directive if safety_directive.present?

    completeness_directive
  end

  def stop_work_exhaustive_coverage_directive
    <<~DIRECTIVE.strip
      # EXHAUSTIVE STOP-WORK COVERAGE
      The stop-work evidence override above governs the answer. Completeness
      applies only as coverage: include every documented stop-relevant
      condition from the chunks retrieved for this turn, in that same prose.
      Do not omit a retrieved stop-relevant condition for brevity.
      - Do not recast a stop condition as a test with an action and an expected
        result. Say every stop-relevant condition with its documented trigger
        and its documented mandatory action, including when the fragment has no
        separate expected result.
      - Never invent an expected result. Never copy a result from a
        neighboring action.
    DIRECTIVE
  end

  # Top-of-prompt banner — first thing Haiku reads.
  def language_directive_header(lang_name)
    <<~HEADER.strip
      # RESPONSE LANGUAGE (ABSOLUTE PRIORITY)
      You MUST write your ENTIRE response in #{lang_name}.
      - This overrides the language of the retrieved documents and any prior conversation.
      - If chunks are in another language, translate the relevant content into #{lang_name}.
      - Labels, time estimates, safety notes, and the closing must all be in #{lang_name}.
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

  # Explicit, high-confidence English signal — required before ever returning :en.
  # Excludes homographs with Spanish (a, me, no, has, he, son, van, sea) on purpose.
  EN_TOKENS = %w[
    the is are was were do does did of to in on for with and or not
    you we it this that these those your its my
    how what when where which who why
    can could would should must need want show tell give please
    from about there here been have had get make
  ].freeze
  EN_TOKEN_SET = Set.new(EN_TOKENS).freeze

  def detect_language_from_question(question)
    self.class.detect_language_from_question(question)
  end

  # Returns :es for Spanish, :en otherwise. Default (no clear signal either way)
  # is :es — I18n.default_locale — matching the primary user base.
  #
  # Blank question falls back to I18n.default_locale, NOT the ambient I18n.locale.
  # Ambient locale is request-scoped session[:locale] (LocaleSwitchable) — using it
  # here would let an auth-time locale switch leak into the response-language
  # policy for blank-question uploads (photo/document with no question), which must
  # default to Spanish regardless of session locale unless conversation history is
  # confidently English (see RagQueryConcern#resolve_response_locale).
  def self.detect_language_from_question(question)
    return I18n.default_locale if question.blank?

    return :es if strong_spanish_evidence?(question)
    return :en if strong_english_evidence?(question)

    I18n.default_locale
  end

  # Explicit, high-confidence Spanish signal — unchanged from the pre-existing
  # heuristic (accent/inverted-punctuation, or >=2 distinct ASCII stopwords).
  def self.strong_spanish_evidence?(question)
    text = question.to_s.strip.downcase
    return true if text.match?(ES_DIACRITIC_PATTERN)

    tokens = text.scan(/\b[a-z]+\b/).uniq
    tokens.count { |t| ES_TOKEN_SET.include?(t) } >= 2
  end

  # Explicit, high-confidence English signal — required before ever returning :en.
  def self.strong_english_evidence?(question)
    tokens = question.to_s.strip.downcase.scan(/\b[a-z]+\b/).uniq
    tokens.count { |t| EN_TOKEN_SET.include?(t) } >= 2
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

  def localized_generation_retry(locale)
    I18n.with_locale(locale) { I18n.t("rag.generation_retry") }
  end

  def self.withhold_document_identity_inference(text)
    replaced = DOCUMENT_IDENTITY_INFERENCE_CLAUSES.reduce(text.to_s) { |current, clause| current.sub(clause, "") }
    replaced.sub(DOCUMENT_IDENTITY_ROLE_SENTENCE, DOCUMENT_IDENTITY_ROLE_REPLACEMENT)
  end

  # Reads `app/prompts/bedrock/generation.txt` once per process in production
  # (and per call in dev/test so prompt edits are picked up without a restart).
  # Each RAG request renders the prompt twice (build_complete_optimized_config
  # + the post-response token-count assembly) — without memoization that means
  # 2 File.read syscalls per request multiplied by N concurrent requests.
  # "etiqueta del equipo" is the nameplate the technician is reading, not a request
  # for the label table. A plan word negated in the same sentence is not a request
  # either: "no necesito el plano" matched the old alternation and would have
  # taken the turn off the companion.
  PLAN_REQUEST = /plano|esquema|\betiquetas?\b(?!\s+del\s+equipo)|schematic|diagram|\blabels?\b/i
  PLAN_NEGATION = /\A(?:no|ni|nunca|sin|tampoco|ningun[oa]?)\z/i
  DIAGRAM_SECTION = /(?:^|\n)\s*(?:#+\s*)?(?:diagrama|plano|esquema|tabla de etiquetas|schematic|label table)\b/i
  TOPOLOGY_EDGE_MARK = "The one exception is a RECORD_TYPE: TOPOLOGY_EDGE record:"

  def self.plan_request?(question, session_context = nil)
    text = "#{question}\n#{session_context}"
    offset = 0
    while (match = text.match(PLAN_REQUEST, offset))
      return true unless plan_term_negated?(text, match.begin(0))

      offset = match.end(0)
      offset += 1 if offset <= match.begin(0)
    end
    false
  end

  def self.plan_term_negated?(text, offset)
    sentence = text.to_s[0...offset].to_s.split(/[.!?\n]/).last.to_s
    sentence.scan(/[[:alpha:]]+/).last(3).any? { |word| word.match?(PLAN_NEGATION) }
  end
  private_class_method :plan_term_negated?

  def self.plan_context?(question, session_context, chunks)
    return true if plan_request?(question, session_context)

    Array(chunks).any? { |chunk| plan_chunk?(chunk_body(chunk)) }
  end

  def self.without_plan_blocks(template)
    span = topology_span(template)
    return template unless span

    copy = template.dup
    copy.slice!(span)
    copy
  end

  def self.topology_edge_rules(template = nil)
    template ||= Rails.root.join("app/prompts/bedrock/generation.txt").read
    span = topology_span(template)
    span ? template[span] : ""
  end

  def self.plan_chunk?(text)
    body = text.to_s
    body.match?(/RECORD_TYPE:\s*TOPOLOGY_EDGE/) || body.match?(DIAGRAM_SECTION)
  end
  private_class_method :plan_chunk?

  def self.chunk_body(chunk)
    case chunk
    when Hash
      chunk[:content] || chunk["content"] || chunk[:text] || chunk["text"]
    else
      chunk.respond_to?(:content) ? chunk.content : nil
    end.to_s
  end
  private_class_method :chunk_body

  def self.topology_span(template)
    lines = template.lines
    start_line = lines.index { |line| line.include?(TOPOLOGY_EDGE_MARK) }
    return nil if start_line.nil?

    finish = lines.index { |line| line.strip == "the complete diagram." }
    return nil if finish.nil? || finish < start_line

    offset = lines[0...start_line].sum(&:length)
    length = lines[start_line..finish].sum(&:length)
    offset...(offset + length)
  end
  private_class_method :topology_span

  def self.load_generation_prompt_template(grounded_synthesis: false, field_guidance: true)
    partial_contract = Rag::PartialAbstentionContractFlag.enabled?
    grounded_synthesis = grounded_synthesis == true
    field_guidance = field_guidance == true

    if Rails.env.production?
      @generation_prompt_templates ||= {}
      @generation_prompt_templates[[partial_contract, grounded_synthesis, field_guidance]] ||= begin
        template = @generation_prompt_template ||=
          Rails.root.join("app/prompts/bedrock/generation.txt").read
        filter_generation_prompt(template, partial_contract:, grounded_synthesis:, field_guidance:)
      end
    else
      template = Rails.root.join("app/prompts/bedrock/generation.txt").read
      filter_generation_prompt(template, partial_contract:, grounded_synthesis:, field_guidance:)
    end
  end

  def self.filter_generation_prompt(template, partial_contract:, grounded_synthesis:, field_guidance:)
    template.lines.filter_map do |line|
      next if !partial_contract && line.start_with?(PARTIAL_ABSTENTION_PROMPT_PREFIX)
      next if grounded_synthesis && strict_only_prompt_line?(line)
      next if !grounded_synthesis && grounded_synthesis_prompt_line?(line)
      next if !field_guidance && field_guidance_prompt_line?(line)

      strip_variant_prompt_prefix(line)
    end.join
  end
  private_class_method :filter_generation_prompt

  def self.grounded_synthesis_prompt_line?(line)
    line.match?(/\A\s*-?\s*(?:GROUNDED_SYNTHESIS|FIELD_GUIDANCE):/)
  end
  private_class_method :grounded_synthesis_prompt_line?

  def self.field_guidance_prompt_line?(line)
    line.match?(/\A\s*-?\s*FIELD_GUIDANCE:/)
  end
  private_class_method :field_guidance_prompt_line?

  def self.strict_only_prompt_line?(line)
    line.match?(/\A\s*-?\s*STRICT_ONLY:/)
  end
  private_class_method :strict_only_prompt_line?

  def self.strip_variant_prompt_prefix(line)
    if line.match?(/\A\s*-?\s*(?:GROUNDED_SYNTHESIS|FIELD_GUIDANCE|STRICT_ONLY):/)
      rest = line.sub(/\A\s*-?\s*(?:GROUNDED_SYNTHESIS|FIELD_GUIDANCE|STRICT_ONLY):\s?/, "")
      return rest if rest.start_with?("#")
      return line.sub(/\A(\s+)(?:GROUNDED_SYNTHESIS|FIELD_GUIDANCE|STRICT_ONLY):\s?/, "\\1") if line.match?(/\A\s+(?:GROUNDED_SYNTHESIS|FIELD_GUIDANCE|STRICT_ONLY):/)

      line.sub(/\A(\s*)-\s*(?:GROUNDED_SYNTHESIS|FIELD_GUIDANCE|STRICT_ONLY):\s?/, "\\1- ")
    else
      line
    end
  end
  private_class_method :strip_variant_prompt_prefix

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

  # Bedrock RetrievalFilter: one embedded logical operator, and at most five
  # clauses in each andAll/orAll.
  # https://docs.aws.amazon.com/bedrock/latest/userguide/kb-test-config.html
  # A question does not choose a manual or a page. Without a pin the filter is
  # the viewer's own chunks, the other SharedManualCorpus account's manuals
  # (photos excluded), and chunks tagged manual_corpus=general. With a pin
  # the filter is only the URIs that resolve to exactly one KbDocument the
  # viewer may use. A caller-supplied URI is not authorization. An
  # unauthorized pin does not fall through to the open corpus on this call.
  # A caller filter may narrow that corpus. It cannot widen it.
  def retrieval_filter(entity_s3_uris:, entity_sources:, question:, apply_page_filter:)
    uris = Array(entity_s3_uris).map(&:to_s).compact_blank.uniq
    if uris.empty?
      @applied_pin_uris = []
      return account_filter
    end

    decision = Rag::KnowledgeScopePolicy.authorize_retrieval_set(uris, viewer_account: @account)
    unless decision.allowed?
      @retrieval_denied = true
      @applied_pin_uris = []
      return nil
    end

    @applied_pin_uris = decision.uris
    checked_bedrock_filter(document_pin_filter(decision.uris))
  end

  # The technician pinned these files. Retrieval is those files alone.
  def document_pin_filter(uris)
    leaves = URI_METADATA_KEYS.map do |key|
      if uris.one?
        { equals: { key: key, value: uris.first } }
      else
        { in: { key: key, value: uris } }
      end
    end
    or_all_clause(leaves)
  end

  def extract_constrained_uris(filter)
    found = []
    walk = lambda do |node|
      case node
      when Hash
        [ node[:equals], node["equals"], node[:in], node["in"] ].each do |clause|
          next unless clause.is_a?(Hash)

          metadata_key = (clause[:key] || clause["key"]).to_s
          next unless URI_METADATA_KEYS.include?(metadata_key)

          Array(clause[:value] || clause["value"]).each do |value|
            found << value.to_s if value.present?
          end
        end
        node.each_value { |value| walk.call(value) }
      when Array
        node.each { |value| walk.call(value) }
      end
    end
    walk.call(filter)
    found.uniq
  end

  def account_filter
    clauses = [ account_id_equals(@account.id) ]
    Rag::SharedManualCorpus.account_ids.each do |id|
      next if id == @account.id.to_s

      clauses << shared_manual_clause(id)
    end
    clauses << {
      equals: {
        key: Rag::SharedManualCorpus::ATTRIBUTE,
        value: Rag::SharedManualCorpus::GENERAL
      }
    }
    checked_bedrock_filter(or_all_clause(clauses))
  end

  # Flat shared base used when a technical caller filter is ANDed on.
  # account_filter already nests andAll for the other shared account, so
  # wrapping that filter again would exceed Bedrock's depth of 2.
  def account_scope_clause
    ids = [ @account.id.to_s ]
    Rag::SharedManualCorpus.account_ids.each { |id| ids << id unless ids.include?(id) }
    equals = ids.map { |id| account_id_equals(id) }
    equals << {
      equals: {
        key: Rag::SharedManualCorpus::ATTRIBUTE,
        value: Rag::SharedManualCorpus::GENERAL
      }
    }
    or_all_clause(equals)
  end

  def photo_exclusion_clause
    {
      not_equals: {
        key: "ingestion_path",
        value: Rag::SharedManualCorpus::PHOTO_INGESTION_PATH
      }
    }
  end

  # Historical manuals of Danebo and the pilot. Photos stay out. A new
  # manual marked manual_corpus=account stays out. A chunk indexed before
  # that marker has no key, and Bedrock notEquals still matches it.
  def shared_manual_clause(id)
    {
      and_all: [
        account_id_equals(id),
        photo_exclusion_clause,
        private_corpus_exclusion_clause
      ]
    }
  end

  def private_corpus_exclusion_clause
    {
      not_equals: {
        key: Rag::SharedManualCorpus::ATTRIBUTE,
        value: Rag::SharedManualCorpus::ACCOUNT
      }
    }
  end

  def or_all_clause(clauses)
    { or_all: clauses }
  end

  def and_all_clause(clauses)
    { and_all: clauses }
  end

  def checked_bedrock_filter(filter)
    validate_bedrock_filter!(filter)
    filter
  end

  def validate_bedrock_filter!(node, depth: 1)
    list = bedrock_filter_list(node)
    return unless list

    raise ArgumentError, "Bedrock filter nests more than 2 levels" if depth > 2
    raise ArgumentError, "Bedrock filter list has #{list.size} clauses (max #{BEDROCK_FILTER_MAX_LIST})" if list.size > BEDROCK_FILTER_MAX_LIST
    raise ArgumentError, "Bedrock andAll/orAll needs at least 2 clauses" if list.size < 2

    list.each { |child| validate_bedrock_filter!(child, depth: depth + 1) if child.is_a?(Hash) }
  end

  def bedrock_filter_list(node)
    return nil unless node.is_a?(Hash)

    node[:or_all] || node["or_all"] || node[:and_all] || node["and_all"]
  end

  def account_id_equals(id)
    { equals: { key: "account_id", value: id.to_s } }
  end

  def enforce_account_filter(config)
    guarded = config.deep_dup
    vector = guarded.dig(:retrieval_configuration, :vector_search_configuration)
    return guarded unless vector

    vector[:filter] = merge_account_filter(vector[:filter])
    guarded
  end

  def merge_account_filter(filter)
    return filter if @retrieval_denied

    filter = filter.deep_dup if filter.respond_to?(:deep_dup)
    return account_filter if filter.blank?
    if document_uri_constrained?(filter)
      uris = extract_constrained_uris(filter)
      decision = Rag::KnowledgeScopePolicy.authorize_retrieval_set(uris, viewer_account: @account)
      unless decision.allowed?
        @retrieval_denied = true
        @retrieval_denied_reason = "caller_uri_denied"
        @applied_pin_uris = []
        return filter
      end

      @applied_pin_uris = decision.uris
      return checked_bedrock_filter(document_pin_filter(decision.uris))
    end
    return filter if same_open_filter?(filter)
    # build_complete_optimized_config already installed account_filter.
    # A technical custom_config is deep-merged beside that orAll. Peel the
    # open list off before the widen check so our own shared-account clauses
    # are not read as a caller trying to add another tenant.
    filter = detach_open_corpus(filter)
    if caller_filter_widens?(filter)
      @retrieval_denied = true
      @retrieval_denied_reason = "caller_filter_widens_scope"
      return nil
    end

    # account_filter nests andAll. A technical predicate uses the flat
    # account_scope_clause so the AND stays at depth 2. Photo exclusion
    # sits beside that clause because the flat OR does not carry it.
    begin
      checked_bedrock_filter(and_all_clause([
        account_scope_clause,
        filter,
        photo_exclusion_clause,
        private_corpus_exclusion_clause
      ]))
    rescue ArgumentError
      @retrieval_denied = true
      @retrieval_denied_reason = "caller_filter_shape"
      nil
    end
  end

  def same_open_filter?(filter)
    normalize_filter(filter) == normalize_filter(account_filter)
  end

  def detach_open_corpus(filter)
    return filter unless filter.is_a?(Hash)

    open_list = bedrock_filter_list(account_filter)
    own_list = filter[:or_all] || filter["or_all"]
    return filter if own_list.nil? || open_list.nil?
    return filter unless normalize_filter(own_list) == normalize_filter(open_list)

    rest = filter.except(:or_all, "or_all")
    rest.empty? ? filter : rest
  end

  # An account_id other than the viewer, an account_id inside orAll, or
  # manual_corpus cannot be proved to be a subset. Those deny. A technical
  # predicate is intersected with the open corpus by the caller.
  def caller_filter_widens?(node, inside_or: false)
    case node
    when Hash
      or_list = node[:or_all] || node["or_all"]
      return true if or_list && or_list.any? { |child| caller_filter_widens?(child, inside_or: true) }

      and_list = node[:and_all] || node["and_all"]
      return true if and_list && and_list.any? { |child| caller_filter_widens?(child, inside_or: inside_or) }

      if mentions_metadata_key?(node, "manual_corpus")
        return true
      end

      %i[equals in not_equals not_in].each do |operator|
        clause = node[operator] || node[operator.to_s]
        next unless clause.is_a?(Hash)
        next unless (clause[:key] || clause["key"]).to_s == "account_id"
        return true if inside_or || operator != :equals

        values = Array(clause[:value] || clause["value"]).map(&:to_s)
        return true unless values == [ @account.id.to_s ]
      end

      node.any? { |key, value| !filter_operator?(key) && caller_filter_widens?(value, inside_or: inside_or) }
    when Array
      node.any? { |value| caller_filter_widens?(value, inside_or: inside_or) }
    else
      false
    end
  end

  def filter_operator?(key)
    %w[equals in not_equals not_in or_all and_all].include?(key.to_s)
  end

  def mentions_metadata_key?(node, metadata_key)
    %i[equals in not_equals not_in].any? do |operator|
      clause = node[operator] || node[operator.to_s]
      clause.is_a?(Hash) && (clause[:key] || clause["key"]).to_s == metadata_key
    end
  end

  def normalize_filter(node)
    case node
    when Hash
      node.each_with_object({}) { |(key, value), normalized| normalized[key.to_s] = normalize_filter(value) }
    when Array
      node.map { |value| normalize_filter(value) }
    else
      node
    end
  end

  def document_uri_constrained?(filter)
    case filter
    when Hash
      equals = filter[:equals] || filter["equals"]
      included = filter[:in] || filter["in"]
      key = (equals || included || {}).then { |clause| clause[:key] || clause["key"] }
      return true if URI_METADATA_KEYS.include?(key.to_s)

      filter.any? { |_k, value| document_uri_constrained?(value) }
    when Array
      filter.any? { |value| document_uri_constrained?(value) }
    else
      false
    end
  end

  # Keep pricing and runtime behavior aligned even when ENV, account config or a
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

  # F1 — Deterministic document identity. Builds the doc_refs contract from the
  # metadata carried by the native citations (or the fallback_retrieve chunks),
  # instead of asking Haiku to emit a <DOC_REFS> block. Prefers the batch
  # sidecar's original_source_uri, then the Bedrock-reserved source URI, then the
  # chunk location. Keeps the same hash shape KbDocumentEnrichmentService and
  # EntityExtractorService already consume (source_uri/canonical_name/aliases/doc_type).
  def build_doc_refs(chunks)
    refs = Array(chunks).filter_map do |chunk|
      metadata = (chunk[:metadata] || chunk["metadata"] || {}).to_h.stringify_keys
      location = (chunk[:location] || chunk["location"] || {})
      source_uri = metadata["original_source_uri"].presence ||
        metadata["x-amz-bedrock-kb-source-uri"].presence ||
        (location[:uri] || location["uri"]).presence
      next if source_uri.blank?

      aliases = Array(metadata["aliases"])
        .map { |a| a.to_s.strip }
        .select { |a| a.length.between?(2, 60) }
        .first(10)

      {
        "source_uri"     => source_uri,
        "canonical_name" => metadata["canonical_name"].to_s.strip.presence ||
          File.basename(source_uri, ".*"),
        "aliases"        => aliases,
        "doc_type"       => metadata["doc_type"].to_s.presence || "unknown"
      }
    end
    refs = refs.uniq { |ref| ref["source_uri"] }
    refs.presence
  end

  def grounded_synthesis?
    @grounded_synthesis == true
  end

  def grounded_synthesis_contract_version
    grounded_synthesis? ? GROUNDED_SYNTHESIS_CONTRACT_VERSION : STRICT_CONTRACT_VERSION
  end

  # Appends an internal absence contract without rewriting the generated answer.
  # With the partial contract disabled this preserves the former 280-character
  # behavior byte-for-byte. With it enabled, a leading absence remains total while
  # a later absence is marked only when its fragment shares a requested relation
  # with the question.
  # D5: with grounded synthesis, a body that already carries a citation marker
  # [n] must not receive an absence footer — the model named the missing datum
  # inline. Variant off stays byte-identical to the current behaviour.
  def normalize_absence_semantics(
    answer,
    question: nil,
    locale: I18n.locale,
    partial_contract: Rag::PartialAbstentionContractFlag.enabled?,
    grounded_synthesis: false
  )
    return answer if answer.blank?
    return answer if answer.match?(ABSENCE_MARKER_PATTERN)
    return answer if grounded_synthesis && answer.match?(CITATION_MARKER_PATTERN)

    return normalize_legacy_absence(answer, locale:) unless partial_contract

    fragments = Rag::AnswerSafetyProcessor.fragments(answer)
    absence_fragments = fragments.each_with_index.filter_map do |fragment, index|
      [ fragment, index ] if absence_phrase?(fragment)
    end
    return answer if absence_fragments.empty?

    contract_key =
      if absence_fragments.any? { |_fragment, index| index.zero? }
        "rag.absence_total_contract"
      elsif partial_absence_relevant?(question, absence_fragments)
        "rag.absence_partial_contract"
      end
    return answer unless contract_key

    "#{answer.rstrip}\n\n#{I18n.t(contract_key, locale: locale)}"
  end

  def normalize_legacy_absence(answer, locale:)
    lead = answer[0, LEGACY_ABSENCE_LEAD_CHARS].to_s.tr("#*`>_", " ")
    return answer unless absence_phrase?(lead)

    "#{answer.rstrip}\n\n#{I18n.t('rag.absence_total_contract', locale: locale)}"
  end

  def absence_phrase?(text)
    ABSENCE_PHRASE_PATTERNS.any? { |pattern| text.match?(pattern) }
  end

  def partial_absence_relevant?(question, absence_fragments)
    question_relations = Rag::QueryEntities.requested_relation(question)
    return false if question_relations.empty?

    absence_fragments.any? do |fragment, _index|
      (question_relations & Rag::QueryEntities.requested_relation(fragment)).any?
    end
  end

  CitationGate = Data.define(:groups, :rejected, :seen) do
    def dropped_all?
      seen.positive? && groups.empty?
    end
  end
  FilteredCitation = Struct.new(:generated_response_part, :retrieved_references, keyword_init: true)

  def authorize_raw_citations(raw, correlation_id: nil, query: nil)
    groups = []
    rejected = 0
    seen = 0
    rank = 0
    capture = Rag::ValidationCapture.active?
    rows = [] if capture
    Array(raw).each do |citation|
      refs = Array(citation.respond_to?(:retrieved_references) ? citation.retrieved_references : nil)
      seen += refs.size
      kept = []
      refs.each do |ref|
        rank += 1
        chunk = reference_to_chunk(ref)
        publishable, reason = publication_gate(chunk)
        rows << retrieved_capture_row(chunk, publishable, reason) if capture
        r1a_probe_chunk(correlation_id, query, chunk, publishable, rank, "bedrock_raw_result")
        r1a_probe_chunk(correlation_id, query, chunk, publishable, rank, "publication_gate")
        if publishable
          kept << ref
        else
          rejected += 1
        end
      end
      next if kept.empty?

      groups << FilteredCitation.new(
        generated_response_part: citation.respond_to?(:generated_response_part) ? citation.generated_response_part : nil,
        retrieved_references: kept
      )
    end
    if capture
      payload = {
        "role" => "cited",
        "source" => "authorize_raw_citations",
        "query" => query.presence || "unavailable",
        "rows" => rows
      }
      payload["correlation_id"] = correlation_id if correlation_id.present?
      Rag::ValidationCapture.record("retrieval_results", payload)
    end
    CitationGate.new(groups: groups, rejected: rejected, seen: seen)
  end

  def reference_to_chunk(ref)
    metadata = ref.respond_to?(:metadata) ? ref.metadata : nil
    location = ref.respond_to?(:location) ? ref.location : nil
    uri = if location.respond_to?(:s3_location)
      location.s3_location&.uri
    elsif location.is_a?(Hash)
      location[:uri] || location["uri"]
    end
    content = ref.respond_to?(:content) ? ref.content : nil
    {
      content: content.respond_to?(:text) ? content.text : content,
      metadata: metadata,
      location: uri ? { uri: uri } : nil
    }
  end

  def open_retrieval_applicability(outcome_reason)
    return nil unless outcome_reason.to_s == "identity_unknown"

    Rag::DocumentIdentityScope::IDENTITY_UNKNOWN_REFERENCE
  end

  def log_open_retrieval(correlation_id, outcome_reason: nil)
    Rails.logger.info(
      "[OPEN_RETRIEVAL] account_id=#{@account&.id} " \
        "rejected=#{@rejected_result_count.to_i} reason=#{@retrieval_denied_reason}"
    )
    PilotUsageLog.log(
      "open_retrieval",
      account_id: @account&.id,
      correlation_id: correlation_id,
      rejected_result_count: @rejected_result_count.to_i,
      retrieval_denied_reason: @retrieval_denied_reason,
      result: @retrieval_denied ? "deny" : "ok",
      outcome_reason: outcome_reason,
      evidence_applicability: open_retrieval_applicability(outcome_reason)
    )
  rescue StandardError => e
    Rails.logger.warn("BedrockRagService: open retrieval log failed — #{e.class}")
  end

  # Open-retrieval publish gate. Mirrors account_filter. It does not compare
  # chunk document_id with KbDocument.document_uid: bulk ingestion writes
  # sha256[0,36] into the sidecar and the row receives a separate UUID.
  # Missing or unreadable metadata fails closed. Pin authorization stays
  # on KnowledgeScopePolicy and is not this method.
  def publishable_retrieved_chunk?(chunk)
    publication_gate(chunk).first
  end

  def publication_gate(chunk)
    metadata = retrieval_chunk_metadata(chunk)
    return [ false, "metadata_unreadable" ] if metadata.nil?

    account_id = metadata["account_id"].to_s.presence
    return [ false, "account_missing" ] if account_id.blank?

    photo = metadata["ingestion_path"].to_s == Rag::SharedManualCorpus::PHOTO_INGESTION_PATH
    corpus = metadata[Rag::SharedManualCorpus::ATTRIBUTE].to_s
    return [ true, "viewer_account" ] if account_id == @account&.id.to_s
    return [ false, "other_account_photo" ] if photo
    return [ false, "manual_corpus_account" ] if corpus == Rag::SharedManualCorpus::ACCOUNT
    return [ true, "manual_corpus_general" ] if corpus == Rag::SharedManualCorpus::GENERAL
    return [ true, "shared_corpus" ] if Rag::SharedManualCorpus.member_id?(account_id)

    [ false, "foreign_account" ]
  end

  def select_publishable_chunks(chunks, probe: nil)
    kept = []
    rejected = 0
    capture = Rag::ValidationCapture.active?
    rows = [] if capture
    Array(chunks).each_with_index do |chunk, index|
      publishable, reason = publication_gate(chunk)
      rows << retrieved_capture_row(chunk, publishable, reason) if capture
      if probe
        score = chunk.is_a?(Hash) ? (chunk[:score] || chunk["score"]) : nil
        %w[bedrock_raw_result publication_gate].each do |stage|
          r1a_probe_chunk(probe[:correlation_id], probe[:query], chunk, publishable, index + 1, stage, score: score)
        end
        extra = probe[:stage].to_s
        if extra.present? && %w[bedrock_raw_result publication_gate].exclude?(extra)
          r1a_probe_chunk(probe[:correlation_id], probe[:query], chunk, publishable, index + 1, extra, score: score)
        end
      end
      if publishable
        kept << chunk
      else
        rejected += 1
      end
    end
    record_retrieval_results(rows, probe) if capture
    [ kept, rejected ]
  end

  def record_retrieval_results(rows, probe)
    query = probe.is_a?(Hash) ? probe[:query] : nil
    source = probe.is_a?(Hash) ? probe[:stage].to_s.presence : nil
    payload = {
      "role" => "retrieved",
      "stage" => source || "publication_gate",
      "result" => "returned",
      "source" => source || "publication_gate",
      "query" => query.presence || "unavailable",
      "rows" => rows
    }
    correlation_id = probe[:correlation_id] if probe.is_a?(Hash)
    payload["correlation_id"] = correlation_id if correlation_id.present?
    Rag::ValidationCapture.record("retrieval_results", payload)
  end

  def retrieved_capture_row(chunk, publishable, reason)
    metadata = retrieval_chunk_metadata(chunk) || {}
    {
      "document" => metadata["canonical_name"].presence || metadata["original_filename"].presence || "unavailable",
      "page" => metadata["page_number"].presence || "unavailable",
      "document_id" => metadata["document_id"].presence || "unavailable",
      "uri" => captured_chunk_uri(chunk),
      "score" => captured_chunk_score(chunk),
      "text" => captured_chunk_text(chunk),
      "decision" => publishable ? "accepted" : "rejected",
      "reason" => reason
    }
  end

  def captured_chunk_score(chunk)
    return "unavailable" unless chunk.is_a?(Hash)

    score = chunk.key?(:score) ? chunk[:score] : chunk["score"]
    score.nil? ? "unavailable" : score
  end

  def captured_chunk_text(chunk)
    return "unavailable" unless chunk.is_a?(Hash)

    text = chunk.key?(:content) ? chunk[:content] : chunk["content"]
    text = text.text if text.respond_to?(:text)
    text.to_s.presence || "unavailable"
  end

  def captured_chunk_uri(chunk)
    return "unavailable" unless chunk.is_a?(Hash)

    uri = chunk[:location_uri] || chunk["location_uri"]
    if uri.blank?
      location = chunk[:location] || chunk["location"]
      if location.is_a?(Hash)
        uri = location[:uri] || location["uri"]
      elsif location.respond_to?(:s3_location)
        uri = location.s3_location&.uri
      end
    end
    uri.presence || "unavailable"
  end

  def capture_cited_sources(citations)
    return unless Rag::ValidationCapture.active?

    Rag::ValidationCapture.record(
      "retrieval_results",
      "role" => "cited",
      "stage" => "citations",
      "result" => "returned",
      "rows" => Array(citations).map { |citation| cited_capture_row(citation) }
    )
  end

  def cited_capture_row(citation)
    data = citation.is_a?(Hash) ? citation.deep_stringify_keys : {}
    metadata = data["metadata"].is_a?(Hash) ? data["metadata"].stringify_keys : {}
    location = data["location"].is_a?(Hash) ? data["location"].stringify_keys : {}
    {
      "document" => data["canonical_name"].presence || data["title"].presence || metadata["canonical_name"].presence || "unavailable",
      "page" => data["page"].presence || data["page_number"].presence || metadata["page_number"].presence || "unavailable",
      "uri" => data["uri"].presence || location["uri"].presence || metadata["original_source_uri"].presence || "unavailable",
      "document_id" => data["document_id"].presence || metadata["document_id"].presence || "unavailable",
      "score" => data.key?("score") && !data["score"].nil? ? data["score"] : "unavailable",
      "text" => data["content"].presence || "unavailable",
      "decision" => "cited"
    }
  end

  def capture_identity_policy(original, applied)
    return unless Rag::ValidationCapture.active?

    chunks = Array(original)
    labels = Array(applied.labels)
    applicability = Array(applied.applicability)
    aligned = labels.size == chunks.size && (applicability.empty? || applicability.size == chunks.size)
    rows = if aligned
      chunks.each_with_index.map { |chunk, index|
        identity_policy_row(chunk, applicability[index], applied)
      }
    else
      [ { "alignment" => "unavailable" } ]
    end
    Rag::ValidationCapture.record(
      "retrieval_policy",
      "role" => "policy",
      "status" => applied.status&.to_s || "unavailable",
      "reason" => applied.reason&.to_s,
      "rows" => rows
    )
  end

  def identity_policy_row(chunk, applicability, applied)
    metadata = retrieval_chunk_metadata(chunk) || {}
    decision, reason = identity_policy_decision(applicability, applied)
    {
      "document" => metadata["canonical_name"].presence || metadata["original_filename"].presence || "unavailable",
      "page" => metadata["page_number"].presence || "unavailable",
      "uri" => captured_chunk_uri(chunk),
      "document_id" => metadata["document_id"].presence || "unavailable",
      "decision" => decision,
      "reason" => reason,
      "body_replaced" => applicability == "reference_only"
    }
  end

  def identity_policy_decision(applicability, applied)
    case applicability
    when "compatible", "neutral"
      [ "accepted", "this_job" ]
    when "reference_only"
      [ "reference_only", "other_equipment" ]
    when nil
      applied.reason.to_s == "not_required" ? [ "not_required", "not_required" ] : [ "rejected", "applicability_nil" ]
    else
      [ "unavailable", "unavailable" ]
    end
  end

  def record_published_answer(result, prompt, truncated)
    return unless Rag::ValidationCapture.active?

    citations = result[:citations] unless result[:citations].nil?
    citations = result["citations"] if citations.nil? && result.is_a?(Hash) && !result["citations"].nil?
    payload = {
      "stage" => "publish",
      "result" => "published",
      "answer" => result[:answer],
      "generation_mode" => result[:generation_mode],
      "route_outcome" => result[:route_outcome],
      "truncated" => truncated == true,
      "prompt_chars" => prompt.to_s.length,
      "documentary_context" => Rag::ValidationCapture.documentary_context(prompt),
      "error_class" => nil
    }
    payload["citations"] = citations unless citations.nil?
    Rag::ValidationCapture.record("published_answer", payload)
  end

  def r1a_probe_filter(correlation_id, question, params, reason: nil, attempt: nil)
    filter = bedrock_filter_from(params)
    Rag::R1aRetrievalProbe.emit(
      correlation_id: correlation_id,
      stage: "bedrock_request_filter",
      query: question,
      rank: attempt,
      decision: reason ? "DROP" : nil,
      reason: reason,
      filter: filter
    )
  rescue StandardError
    nil
  end

  def r1a_probe_chunk(correlation_id, query, chunk, publishable, rank, stage, score: nil)
    Rag::R1aRetrievalProbe.observe_chunk(
      correlation_id: correlation_id,
      stage: stage,
      chunk: chunk,
      kept: publishable,
      viewer_account_id: @account&.id,
      query: query,
      rank: rank,
      score: score
    )
  rescue StandardError
    nil
  end

  def r1a_probe_evidence(correlation_id, question, chunks, stage:, basis: nil)
    rows = Array(chunks)
    if rows.empty?
      Rag::R1aRetrievalProbe.emit(
        correlation_id: correlation_id,
        stage: stage,
        query: question,
        rank: 0,
        decision: "DROP",
        reason: basis.presence || "empty"
      )
      return
    end

    rows.each_with_index do |chunk, index|
      r1a_probe_chunk(correlation_id, question, chunk, true, index + 1, stage)
    end
  rescue StandardError
    nil
  end

  def bedrock_filter_from(params)
    return nil unless params.is_a?(Hash)

    filter = params.dig(
      :retrieve_and_generate_configuration,
      :knowledge_base_configuration,
      :retrieval_configuration,
      :vector_search_configuration,
      :filter
    )
    filter ||= params.dig(:retrieval_configuration, :vector_search_configuration, :filter)
    return nil if filter.nil?

    JSON.parse(JSON.generate(filter))
  rescue StandardError
    nil
  end

  def retrieval_chunk_metadata(chunk)
    return nil unless chunk.is_a?(Hash)

    raw = chunk.key?(:metadata) ? chunk[:metadata] : chunk["metadata"]
    return nil if raw.nil?

    raw = raw.to_h if !raw.is_a?(Hash) && raw.respond_to?(:to_h)
    return nil unless raw.is_a?(Hash)

    raw.stringify_keys
  rescue StandardError
    nil
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

      sanitized = parsed.filter_map do |ref|
        source_uri = ref["source_uri"].to_s
        next if source_uri.present? && !source_uri_resolves_to_account_document?(source_uri)

        aliases = Array(ref["aliases"])
          .map { |a| a.to_s.strip }
          .select { |a| a.length.between?(2, 60) }
          .reject { |a| a.match?(/[|⚠️→←]|\*\*|^\#/) }
          .first(10)

        {
          "source_uri"     => source_uri,
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

  def source_uri_resolves_to_account_document?(source_uri)
    Rag::KnowledgeScopePolicy.authorized_retrieval_uris([ source_uri ], viewer_account: @account).any?
  end
end
