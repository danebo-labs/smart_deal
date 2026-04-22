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
                         conv_session: nil, entity_s3_uris: [], output_channel: nil)
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

    # Catalog-level pre-resolution: if the query mentions a document by its
    # human-facing name (display_name) or any stored alias, we inject its
    # source_uri into entity_s3_uris so retrieval is scoped to it, and we
    # append an explicit equivalence block to session_context so Haiku
    # bridges the user's vocabulary and the chunks' internal canonical.
    resolver_matches       = KbDocumentResolver.resolve(question)
    merged_entity_s3_uris  = merge_resolver_uris(entity_s3_uris, resolver_matches)
    merged_session_context = merge_resolver_context(session_context, resolver_matches)

    # Channel for prompt-side adaptation (e.g. WA short, no markdown tables).
    # Explicit output_channel wins; otherwise infer :whatsapp when whatsapp_to present.
    resolved_output_channel = output_channel&.to_sym || (whatsapp_to.present? ? :whatsapp : :web)

    result = QueryOrchestratorService.new(
      question,
      images: images,
      documents: documents,
      tenant: rag_tenant,
      session_id: session_id,
      response_locale: resolved_response_locale,
      session_context: merged_session_context,
      conv_session: conv_session,
      entity_s3_uris: merged_entity_s3_uris,
      output_channel: resolved_output_channel
    ).execute

    if whatsapp_to.present? && cache_key
      # Update cached locale only when the message is long enough to reliably detect language.
      new_locale = body_stripped.length > WHATSAPP_SHORT_FOLLOWUP_MAX_CHARS ? detected : (cached_locale.presence || detected)
      Rails.cache.write(cache_key, new_locale.to_s, expires_in: WHATSAPP_CONV_CACHE_TTL)
    end

    RagResult.new(
      success?:            true,
      answer:              sanitize_answer(result[:answer], channel: resolved_output_channel),
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

  # Circled numerals for the "Documents consulted" header (UX: quick visual scan
  # for a technician in the field). Falls back to "N." beyond the 10th citation.
  WHATSAPP_CIRCLED_NUMERALS = %w[① ② ③ ④ ⑤ ⑥ ⑦ ⑧ ⑨ ⑩].freeze

  # Defensive sanitizer applied to model answers before delivery (web JSON +
  # WhatsApp formatter). Only normalizes/strips noise that hurts both channels:
  #   - Strips leading "# / ## / ###" markdown headers (keeps the heading text).
  #   - Converts pipe-table blocks (`| col | col |` + `|---|---|`) into a
  #     numbered list ① ② ③ … (falls back to "N." past the 10th row).
  #   - Collapses 3+ consecutive blank lines to 2.
  # Does NOT add new markup (no `*bold*`, no emojis), so web's formatAnswer
  # keeps working unchanged.
  # @param text [String, nil] raw answer from BedrockRagService (already DOC_REFS-stripped)
  # @param channel [Symbol] :web | :whatsapp — reserved for future per-channel rules
  # @return [String]
  def sanitize_answer(text, channel: :web) # rubocop:disable Lint/UnusedMethodArgument
    return "" if text.blank?

    out = text.dup
    out = strip_markdown_headers(out)
    out = convert_markdown_tables(out)
    out = collapse_blank_lines(out)
    out.strip
  end

  def strip_markdown_headers(text)
    # Only at start of line; preserves a `#` that appears mid-sentence.
    text.gsub(/^[ \t]*\#{1,6}\s+/, '')
  end

  TABLE_ROW_PATTERN     = /\A\s*\|.*\|\s*\z/.freeze
  TABLE_DIVIDER_PATTERN = /\A\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*\z/.freeze

  def convert_markdown_tables(text)
    lines = text.split("\n", -1)
    out   = []
    i     = 0

    while i < lines.length
      line = lines[i]
      nxt  = lines[i + 1]

      if line&.match?(TABLE_ROW_PATTERN) && nxt&.match?(TABLE_DIVIDER_PATTERN)
        header_cells = split_table_row(line)
        i += 2
        row_idx = 0
        while i < lines.length && lines[i].match?(TABLE_ROW_PATTERN)
          row_cells = split_table_row(lines[i])
          bullet    = WHATSAPP_CIRCLED_NUMERALS[row_idx] || "#{row_idx + 1}."
          label     = row_cells.first.to_s.strip
          rest      = header_cells.drop(1).zip(row_cells.drop(1)).map { |h, v|
            "#{h.to_s.strip}: #{v.to_s.strip}"
          }.reject { |s| s.end_with?(": ") }.join(" — ")
          out << (rest.empty? ? "#{bullet} #{label}" : "#{bullet} #{label} — #{rest}")
          row_idx += 1
          i += 1
        end
      else
        out << line
        i += 1
      end
    end

    out.join("\n")
  end

  def split_table_row(row)
    row.strip.sub(/\A\|/, '').sub(/\|\z/, '').split('|').map(&:strip)
  end

  def collapse_blank_lines(text)
    text.gsub(/\n{3,}/, "\n\n")
  end

  # Formats RAG result for WhatsApp/SMS text responses.
  # Returns the full answer — callers must use split_for_whatsapp before sending
  # via Twilio REST API (1600 char/message limit).
  # @param result [RagResult] The result from execute_rag_query
  # @return [String] Human-readable text response (may exceed 1600 chars)
  def format_rag_response_for_whatsapp(result)
    return whatsapp_error_message(result.error_type, result.error_message) unless result.success?

    text = result.answer.to_s

    if result.citations.present?
      text = "#{build_documents_consulted_header(result)}\n\n#{text}\n\n#{build_sources_footer(result)}"
    end

    text.presence || "I couldn't find an answer."
  end

  # Builds the opening header that tells the technician, at a glance, which
  # documents were used to answer their question. Bold filename list with
  # circled numerals. Locale matches the answer text.
  def build_documents_consulted_header(result)
    locale = whatsapp_response_locale(result)
    title  = I18n.with_locale(locale) { I18n.t("rag.documents_consulted_header") }

    unique_names = Array(result.citations).filter_map { |c| c[:filename].presence }.uniq
    lines = unique_names.each_with_index.map do |name, i|
      bullet = WHATSAPP_CIRCLED_NUMERALS[i] || "#{i + 1}."
      "#{bullet} #{name}"
    end

    "📄 *#{title}:*\n#{lines.join("\n")}"
  end

  # Builds the legacy "Sources:" footer with [n]-indexed filenames for
  # cross-reference with inline [n] markers in the answer body.
  def build_sources_footer(result)
    locale = whatsapp_response_locale(result)
    label  = I18n.with_locale(locale) { I18n.t("rag.sources_label") }
    refs   = Array(result.citations).map { |c| "[#{c[:number]}] #{c[:filename]}" }.join("\n")

    "#{label}\n#{refs}"
  end

  # Detects the language of the answer so the header/footer labels match.
  # Delegates to BedrockRagService which already owns the es/en heuristics.
  def whatsapp_response_locale(result)
    BedrockRagService.detect_language_from_question(result.answer.to_s)
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

  # Merges resolver-derived s3 URIs into the list passed by the caller,
  # de-duplicated and order-preserving. Caller URIs come first (session takes
  # precedence over catalog hints).
  def merge_resolver_uris(caller_uris, resolver_matches)
    return Array(caller_uris) if resolver_matches.blank?

    bucket = ENV.fetch('KNOWLEDGE_BASE_S3_BUCKET', 'multimodal-source-destination')
    resolver_uris = resolver_matches.filter_map { |d| d.display_s3_uri(bucket) }
    (Array(caller_uris) + resolver_uris).uniq
  end

  # Appends a "Query Resolution" block to session_context so Haiku treats the
  # matched documents as the SAME entity regardless of which alias the user
  # used. Returns the original context unchanged when there are no matches.
  def merge_resolver_context(session_context, resolver_matches)
    return session_context if resolver_matches.blank?

    lines = resolver_matches.map do |doc|
      aliases = Array(doc.aliases).map(&:to_s).compact_blank.first(5)
      alias_note = aliases.any? ? " (aka: #{aliases.join(', ')})" : ""
      "- \"#{doc.display_name}\" → #{doc.s3_key}#{alias_note}"
    end

    block = <<~BLOCK.strip
      ## Query Resolution
      The user's query mentions documents that exist in the catalog. Treat the names below and any of their aliases as references to the SAME physical document. Do NOT claim the document is not found.
      #{lines.join("\n")}
    BLOCK

    [ session_context.presence, block ].compact.join("\n\n")
  end

  # Logs a warning when expected safety markers are absent from a WhatsApp
  # answer whose source chunks contained them. Produces observable signal
  # (grep-able in log) without blocking delivery.
  # @param answer [String] the sanitized answer delivered to the technician
  WHATSAPP_SAFETY_MARKERS = [
    "REQUIERE VERIFICACIÓN EN CAMPO",
    "DATO NO DISPONIBLE",
    "DOCUMENTO DEGRADADO",
    "VOLTAJE NO VERIFICADO",
    "REQUIRES_FIELD_VERIFICATION",
    "DATA_NOT_AVAILABLE"
  ].freeze

  def log_whatsapp_safety_coverage(answer, to:)
    present = WHATSAPP_SAFETY_MARKERS.select { |m| answer.include?(m) }
    absent  = WHATSAPP_SAFETY_MARKERS - present

    if present.any?
      Rails.logger.info("[WA_SAFETY] #{to} — markers present: #{present.join(', ')}")
    end

    if absent.any?
      Rails.logger.debug { "[WA_SAFETY] #{to} — markers absent (may be ok if chunks lacked them): #{absent.join(', ')}" }
    end
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
