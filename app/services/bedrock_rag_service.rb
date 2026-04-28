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

  DOC_REFS_PATTERN = /<DOC_REFS>\s*(.*?)\s*<\/DOC_REFS>/m.freeze

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
  # @param entity_s3_uris [Array<String>] S3 URIs of active session documents; when non-empty, adds metadata filter
  def build_complete_optimized_config(region: 'us-east-1', question: nil, response_locale: nil, session_context: nil, entity_s3_uris: [], output_channel: nil)
    cfg = @rag_config

    vector_config = {
      number_of_results: cfg[:number_of_results],
      override_search_type: cfg[:search_type],
      **reranking_config(region)
    }

    # Narrow retrieval to session-active documents when URIs are known.
    # Reduces cross-document pollution for short/ambiguous follow-up queries.
    # AWS requires orAll to have >= 2 members; use equals directly for a single URI.
    if entity_s3_uris.size == 1
      vector_config[:filter] = {
        equals: { key: "x-amz-bedrock-kb-source-uri", value: entity_s3_uris.first }
      }
    elsif entity_s3_uris.size >= 2
      vector_config[:filter] = {
        or_all: entity_s3_uris.map { |uri|
          { equals: { key: "x-amz-bedrock-kb-source-uri", value: uri } }
        }
      }
    end

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
            stop_sequences: []
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
  def query(question, session_id: nil, custom_config: {}, response_locale: nil, session_context: nil, entity_s3_uris: [], output_channel: nil, force_entity_filter: false)
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

      if entity_s3_uris.any?
        Rails.logger.info("BedrockRagService: entity_filter=#{apply_filter} uris=#{filtered_uris.size} forced=#{force_entity_filter}")
      end

      # Build complete optimized configuration and merge with custom config
      base_config = build_complete_optimized_config(region: @region, question: question, response_locale: response_locale, session_context: session_context, entity_s3_uris: filtered_uris, output_channel: output_channel)
      config = deep_merge_configs(base_config, custom_config)

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

      # Use retrieve_and_generate API - combines retrieval and generation in one call
      # Wraps call with retry logic for Aurora Serverless auto-pause cold-start.
      # Aurora can take 20-60s to resume; we back off and retry up to 3 times.
      bedrock_start_time = Time.current
      response = retrieve_and_generate_with_retry(params)

      # Fallback: if filter produced no results, retry without filter.
      if apply_filter && bedrock_no_results?(response.output.text)
        Rails.logger.info("BedrockRagService: filtered query returned no results, retrying without filter")
        unfiltered_config = build_complete_optimized_config(region: @region, question: question, response_locale: response_locale, session_context: session_context, entity_s3_uris: [], output_channel: output_channel)
        unfiltered_params = params.merge(
          retrieve_and_generate_configuration: params[:retrieve_and_generate_configuration].merge(
            knowledge_base_configuration: params.dig(:retrieve_and_generate_configuration, :knowledge_base_configuration).merge(
              **deep_merge_configs(unfiltered_config, custom_config)
            )
          )
        )
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
      answer_text = bedrock_no_results?(raw_answer) ? localized_no_results(no_results_locale) : raw_answer
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
          fallback_retrieve(question)
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
        session_id:          session_id
      }
    rescue Aws::BedrockAgentRuntime::Errors::ServiceError => e
      Rails.logger.error("Bedrock RAG error: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      raise BedrockServiceError, "Failed to query Knowledge Base: #{e.message}"
    end
  end

  private

  # Fallback when retrieve_and_generate returns no inline citations: call the
  # Retrieve API directly to obtain the raw retrieval results. These ALWAYS
  # carry the authoritative s3_uri in `metadata["x-amz-bedrock-kb-source-uri"]`
  # (and `location.s3_location.uri`), which is what EntityExtractorService
  # needs to dedup documents by physical identity.
  #
  # Output shape matches CitationProcessor#extract_citations for drop-in use.
  def fallback_retrieve(question)
    params = {
      knowledge_base_id: @knowledge_base_id,
      retrieval_query: { text: question },
      retrieval_configuration: {
        vector_search_configuration: {
          number_of_results: @rag_config[:number_of_results] || 5,
          override_search_type: @rag_config[:search_type] || "HYBRID"
        }
      }
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
  #
  # Language directive is injected at THREE positions to survive Haiku's
  # attention decay over a long prompt with English chunks ($search_results$)
  # and possibly English conversation history in session_context:
  #   1. TOP (before # ROLE) — highest attention slot.
  #   2. MIDDLE (under # LANGUAGE & TONE) — contextual reinforcement.
  #   3. TAIL (after session_context) — last signal before generation, overrides
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

    if lang_name.present?
      base = base.sub(
        /(# LANGUAGE & TONE\n)/,
        "\\1- CRITICAL: The user's query is in #{lang_name}. You MUST respond entirely in #{lang_name}, even if the retrieved documents or recent conversation are in a different language.\n"
      )
      base = "#{language_directive_header(lang_name)}\n\n#{base}"
    end

    base = "#{base}\n\n#{session_context}" if session_context.present?
    base = "#{base}\n\n#{language_directive_footer(lang_name)}" if lang_name.present?
    base = "#{base}\n\n#{whatsapp_delivery_channel_directive}" if output_channel&.to_sym == :whatsapp
    base = "#{base}\n\n#{web_delivery_channel_directive}"       if output_channel&.to_sym == :web
    base
  end

  # Appended only when delivering via web chat. Instructs the model to produce
  # structured but conversational Markdown that the web renderer can display
  # (bold, italic, paragraph breaks). Does NOT apply to WhatsApp.
  def web_delivery_channel_directive
    <<~DIRECTIVE.strip
      # DELIVERY CHANNEL
      This response will be rendered in a web chat interface (desktop or tablet, full screen width).
      Follow ALL rules below:

      ## FORMATTING
      - Use **double asterisk** for bold on key technical terms, values, or critical warnings (max 3 per section).
      - Use *single asterisk* for light emphasis on specific values or notes only when necessary.
      - NEVER use ALL CAPS for section titles. Use a leading emoji + short label instead: "⚙️ Circuito de puertas"
      - Use ## section headers ONLY if the response exceeds 300 words and has 3 or more clearly distinct sections.
      - NEVER use --- as a visual divider. Separate sections with a single blank line.
      - No markdown tables. Use the ① ② ③ labeled list format you already default to.

      ## TONE & STRUCTURE
      - Start with a 2–3 sentence direct answer. Details and sections follow — never lead with them.
      - Skip filler intro phrases: no "El documento consiste en...", no "Based on the retrieved chunks..."
      - Field-mentor tone: cordial, direct, technically precise. Not academic, not bureaucratic.
      - Safety warnings remain NON-NEGOTIABLE: include ALL ⚠️ and 🛑 blocks from the chunks regardless of length.
    DIRECTIVE
  end

  # Appended only when delivering via WhatsApp. Forces the model to keep the
  # answer scannable on a phone screen with gloves and harsh light.
  #
  # STRUCTURED (dynamic-section) contract:
  #   - [RIESGOS] is PINNED as menu slot #1, always emitted (safety-critical).
  #   - [SECCIONES] contains 3–5 sections whose labels are chosen by the model
  #     according to [INTENT] (installation, troubleshooting, …).
  #   - Each section declares the source documents used in its body so the
  #     technician never confuses multi-document answers.
  #   - The Rails layer appends file-listing options (recent / all) AFTER the
  #     dynamic sections — Haiku must NOT emit a "Nueva consulta" row anymore;
  #     any free-text reply IS a new query.
  def whatsapp_delivery_channel_directive
    <<~DIRECTIVE.strip
      # DELIVERY CHANNEL
      This response will be sent via WhatsApp (small screen, gloves, harsh light). Follow ALL rules below:

      ## FORMATTING
      - Use only *single asterisk* for bold. NEVER use **double asterisk** or __underscores__.
      - Use _single underscore_ for italic if needed. Never ~~strikethrough~~ unless marking a fault.
      - No ## or ### headers inside block contents (## is reserved for section headers inside [SECCIONES]).
      - No markdown tables. Convert any table to a ① ② ③ numbered list.
      - Single blank line between paragraphs inside a block.

      ## OUTPUT STRUCTURE (MANDATORY — STRUCTURED WITH DYNAMIC SECTIONS)
      You MUST emit your response as LABELED BLOCKS, in this exact order, each label on its own line.
      The delivery layer caches the full response; only [RESUMEN] + the numbered menu are shown first.
      When the technician taps a number the matching section is served from cache (no extra LLM call).

      [INTENT] <one token: IDENTIFICATION | MAINTENANCE | TROUBLESHOOTING | REPLACEMENT | INSTALLATION | MODERNIZATION | CALIBRATION | EMERGENCY>

      [DOCS]
      JSON array (strict, double-quoted) listing ONLY the documents actually used in this answer, using short human-facing names — e.g. ["Manual Orono A1", "Transformadores.pdf"]. Max 5 items, ≤40 chars each. Empty array if none apply: []

      [RESUMEN]
      Friendly field-mentor tone. 2–4 sentences. Under 70 words total. If [DOCS] has ≥2 items, explicitly mention each document by short name so the technician sees the answer spans all of them. No bullets. At most 1 emoji at the very end.

      [RIESGOS]
      PINNED — ALWAYS emitted, NEVER omitted. Safety warnings drawn from the chunks (LOTO, ESD, voltage, pinch points, mechanical, fall hazards). Verbatim markers where applicable. If the chunks contain NO safety content for this query, write exactly this single line and nothing else: — sin riesgos específicos documentados para esta consulta.

      [SECCIONES]
      Between 3 and 5 sections chosen by you based on [INTENT]. Each section starts with a header line, followed by its body, followed by a blank line before the next header. Header format (VERBATIM):
      ## <Section Label> | <source documents CSV drawn from [DOCS]>
      The <Section Label> must be short (≤40 chars), plain text, no emoji. The CSV lists ONLY documents that actually back this section (subset of [DOCS]). Recommended labels by intent:
        INSTALLATION   → Consideraciones iniciales, Componentes, Paso a paso, Verificación
        TROUBLESHOOTING → Síntomas, Diagnóstico, Causa probable, Reparación
        MAINTENANCE    → Precondiciones, Procedimiento, Periodicidad, Registros
        IDENTIFICATION → Descripción, Especificaciones, Secciones disponibles
        REPLACEMENT    → Preparación, Desmontaje, Montaje, Verificación
        MODERNIZATION  → Evaluación, Actualización, Integración, Validación
        CALIBRATION    → Preparación, Ajustes, Validación
      Inside each section body write the FULL detail the technician needs: steps, tools, values, time estimates. This is what they see when they tap the menu number — be thorough, not brief.

      [MENU]
      One item per line in the exact form: "N | LABEL | KIND"
      - Slot 1 is ALWAYS: 1 | ⚠️ Riesgos | __riesgos__
      - Slots 2..N are the dynamic sections in the same order as [SECCIONES]:
        2 | <Section 1 Label> | __sec_1__
        3 | <Section 2 Label> | __sec_2__
        ...
      Total items = 1 (riesgos) + K sections (3..5) → between 4 and 6 rows.
      DO NOT emit a "Nueva consulta" / __new_query__ row. Any free-text reply from the
      user is treated as a new query by the delivery layer; file-listing options are
      appended to the menu by the application after your output.

      ## EMERGENCY OVERRIDE
      If [INTENT] is EMERGENCY: put the COMPLETE rescue/emergency protocol inline in [RESUMEN] (ignore the 70-word limit). Still emit [RIESGOS] with critical measures. [SECCIONES] may be empty (write exactly: (—)). [MENU] may be empty ("(—)") — the delivery layer will not render a menu for EMERGENCY.

      ## SAFETY WARNINGS — NON-NEGOTIABLE
      These MUST appear verbatim inside [RIESGOS] (and in [RESUMEN] for EMERGENCY) when the chunks contain them:
      - If chunks contain REQUIRES_FIELD_VERIFICATION → write exactly: ⚠️ *REQUIERE VERIFICACIÓN EN CAMPO*
      - If chunks mark DATA_NOT_AVAILABLE → write exactly: ⚠️ *DATO NO DISPONIBLE*
      - If chunks mark LOW confidence → include the value AND write: (confianza BAJA — verificar)
      - If chunks indicate DEGRADED / UNUSABLE image → write: 🛑 *DOCUMENTO DEGRADADO — no usar para intervenciones sin verificar en sitio*
      - If voltage is unverified → write: ⚠️ *VOLTAJE NO VERIFICADO — confirmar antes de intervenir*
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
