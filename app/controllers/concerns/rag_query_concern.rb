# frozen_string_literal: true

# app/controllers/concerns/rag_query_concern.rb
# Shared logic for hybrid queries (RAG + Text-to-SQL) across controllers.
# Used by RagController (API/JSON) and TwilioController (WhatsApp).

module RagQueryConcern
  extend ActiveSupport::Concern

  # Result object for queries (works for both RAG and SQL responses)
  RagResult = Struct.new(:success?, :answer, :citations, :retrieved_citations, :doc_refs, :session_id, :documents_uploaded, :error_type, :error_message, keyword_init: true)

  # Short follow-ups (e.g. "modernización") keep the thread language instead of re-inferring from Spanish UI labels.
  WHATSAPP_SHORT_FOLLOWUP_MAX_CHARS = 200
  WHATSAPP_CONV_CACHE_TTL = 7.days

  private

  # Executes a query through the orchestrator, which classifies intent
  # and delegates to either BedrockRagService (knowledge base) or
  # SqlGenerationService (database) as appropriate.
  #
  # @param question [String] The question to query
  # @param images [Array<Hash>] Optional images as [{ data: "base64...", media_type: "image/png" }]
  # @param documents [Array<Hash>] Optional docs as [{ data: "base64...", media_type: "text/plain", filename: "x.txt" }]
  # @param session_id [String, nil] Bedrock session for multi-turn (web/API); merged with whatsapp_to cache when blank
  # @param response_locale [Symbol, String, nil] Force :en / :es for generation; nil = detect from question (and WhatsApp sticky rules)
  # @param whatsapp_to [String, nil] Recipient id (e.g. whatsapp:+...) — enables session + locale persistence across messages
  # @return [RagResult] Structured result with success status and data or error info
  def execute_rag_query(question, images: [], documents: [], session_id: nil, response_locale: nil, whatsapp_to: nil, session_context: nil,
                         conv_session: nil)
    question = question.to_s.strip
    images = Array(images).compact
    documents = Array(documents).compact

    if question.blank? && images.empty? && documents.empty?
      return RagResult.new(success?: false, error_type: :blank_question)
    end

    body_stripped = question
    detected = BedrockRagService.detect_language_from_question(body_stripped)
    cache_key = nil
    cached_locale = nil

    if whatsapp_to.present?
      cache_key = "rag_whatsapp_conv/v1/#{whatsapp_to}"
      raw = Rails.cache.read(cache_key)
      # Handle legacy Hash format written by a previous deploy ({ "locale" => "en", ... })
      cached_locale = (raw.is_a?(Hash) ? raw["locale"] : raw)&.to_sym
    end

    # For WhatsApp threads: short follow-ups (e.g. "modernización") should inherit
    # the language of the FIRST message rather than being re-detected from the word alone.
    # session_id is intentionally NOT forwarded to Bedrock for WhatsApp — stateless KB
    # retrieval produces better results for short follow-ups than session-narrowed search.
    resolved_response_locale = if response_locale.present?
      response_locale.to_sym
    elsif whatsapp_to.present?
      if cached_locale.present? && body_stripped.length <= WHATSAPP_SHORT_FOLLOWUP_MAX_CHARS
        cached_locale
      else
        detected
      end
    else
      detected
    end

    result = QueryOrchestratorService.new(
      question,
      images: images,
      documents: documents,
      tenant: rag_tenant,
      session_id: session_id,
      response_locale: resolved_response_locale,
      session_context: session_context,
      conv_session: conv_session
    ).execute

    if whatsapp_to.present? && cache_key
      # Update cached locale only when the message is long enough to reliably detect language.
      new_locale = body_stripped.length > WHATSAPP_SHORT_FOLLOWUP_MAX_CHARS ? detected : (cached_locale.presence || detected)
      Rails.cache.write(cache_key, new_locale.to_s, expires_in: WHATSAPP_CONV_CACHE_TTL)
    end

    RagResult.new(
      success?:            true,
      answer:              result[:answer],
      citations:           result[:citations],
      retrieved_citations: result[:retrieved_citations],
      doc_refs:            result[:doc_refs],
      session_id:          result[:session_id],
      documents_uploaded:  result[:documents_uploaded]
    )
  rescue ImageCompressionService::CompressionError => e
    log_rag_error("Image compression", e)
    RagResult.new(success?: false, error_type: :image_compression, error_message: e.message)
  rescue BedrockRagService::MissingKnowledgeBaseError => e
    log_rag_error("RAG config error", e)
    RagResult.new(success?: false, error_type: :config_error, error_message: e.message)
  rescue BedrockRagService::BedrockServiceError => e
    log_rag_error("RAG AWS error", e)
    RagResult.new(success?: false, error_type: :service_error, error_message: e.message)
  rescue SqlGenerationService::SqlExecutionError => e
    log_rag_error("SQL execution error", e)
    RagResult.new(success?: false, error_type: :service_error, error_message: e.message)
  rescue StandardError => e
    log_rag_error("Query unexpected error", e, include_backtrace: true)
    RagResult.new(success?: false, error_type: :unexpected_error, error_message: e.message)
  end

  WHATSAPP_CHUNK_SIZE = 1550

  # Formats RAG result for WhatsApp/SMS text responses.
  # Returns the full answer — callers must use split_for_whatsapp before sending
  # via Twilio REST API (1600 char/message limit).
  # @param result [RagResult] The result from execute_rag_query
  # @return [String] Human-readable text response (may exceed 1600 chars)
  def format_rag_response_for_whatsapp(result)
    return whatsapp_error_message(result.error_type, result.error_message) unless result.success?

    text = result.answer.to_s

    if result.citations.present?
      refs = result.citations.map { |c| "[#{c[:number]}] #{c[:filename]}" }.join("\n")
      text += "\n\nFuentes:\n#{refs}"
    end

    text.presence || "I couldn't find an answer."
  end

  # Splits a response string into chunks that fit within Twilio's 1600-char limit.
  # Cuts at paragraph → line → sentence → word boundaries (in that priority order)
  # so logical blocks are never broken mid-thought.
  # @param text [String]
  # @return [Array<String>]
  def split_for_whatsapp(text)
    return [ text ] if text.length <= WHATSAPP_CHUNK_SIZE

    chunks    = []
    remaining = text.dup

    while remaining.length > WHATSAPP_CHUNK_SIZE
      slice = remaining[0, WHATSAPP_CHUNK_SIZE]

      cut = slice.rindex("\n\n") ||
            slice.rindex("\n")   ||
            slice.rindex(". ")   ||
            slice.rindex(" ")    ||
            WHATSAPP_CHUNK_SIZE

      chunks    << remaining[0, cut].rstrip
      remaining  = remaining[cut..].lstrip
    end

    chunks << remaining if remaining.present?
    chunks
  end

  # Maps error types to WhatsApp-friendly messages
  def whatsapp_error_message(error_type, error_message = nil)
    case error_type
    when :blank_question
      "Please send a question (message cannot be empty)."
    when :image_compression
      I18n.t('rag.image_compression_failed')
    when :config_error
      "The query service is not properly configured."
    when :service_error
      "Error querying knowledge base. Please try again later."
    when :unexpected_error
      "Sorry, an error occurred: #{error_message}"
    else
      "An unexpected error occurred."
    end
  end

  # Renders JSON error response for API endpoints
  # @param result [RagResult] The failed result from execute_rag_query
  def render_rag_json_error(result)
    error_config = json_error_config(result.error_type)

    render json: {
      message: error_config[:message],
      status: 'error'
    }, status: error_config[:http_status]
  end

  # Maps error types to JSON API error responses
  def json_error_config(error_type)
    case error_type
    when :blank_question
      { message: 'Question cannot be empty', http_status: :bad_request }
    when :image_compression
      { message: I18n.t('rag.image_compression_failed'), http_status: :bad_request }
    when :config_error
      { message: 'RAG service is not properly configured', http_status: :internal_server_error }
    when :service_error
      { message: 'Error querying knowledge base', http_status: :bad_gateway }
    when :unexpected_error
      { message: 'Unexpected error processing request', http_status: :internal_server_error }
    else
      { message: 'Unknown error', http_status: :internal_server_error }
    end
  end

  # Tenant for multi-tenant data source selection (nil when single-tenant or User has no tenant)
  def rag_tenant
    return nil unless respond_to?(:current_user)
    user = current_user
    return nil unless user&.respond_to?(:tenant)
    user.tenant
  end

  # Centralized error logging for RAG operations
  def log_rag_error(prefix, error, include_backtrace: false)
    message = "#{prefix}: #{error.message}"
    message += "\n#{error.backtrace.first(5).join("\n")}" if include_backtrace

    if include_backtrace
      Rails.logger.fatal(message)
    else
      Rails.logger.error(message)
    end
  end
end
