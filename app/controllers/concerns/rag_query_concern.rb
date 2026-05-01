# frozen_string_literal: true

# app/controllers/concerns/rag_query_concern.rb
# Shared logic for hybrid queries (RAG + Text-to-SQL) across controllers.
# Used by RagController (API/JSON).

module RagQueryConcern
  extend ActiveSupport::Concern

  # Result object for queries.
  RagResult = Struct.new(:success?, :answer, :citations, :retrieved_citations, :doc_refs,
                         :session_id, :documents_uploaded, :images_uploaded,
                         :error_type, :error_message, keyword_init: true)

  # Circled numerals for ① ② ③ lists in table conversion and WA legacy callers.
  CIRCLED_NUMERALS = %w[① ② ③ ④ ⑤ ⑥ ⑦ ⑧ ⑨ ⑩].freeze

  private

  # Executes a query through the orchestrator, which classifies intent
  # and delegates to either BedrockRagService (knowledge base) or
  # SqlGenerationService (database) as appropriate.
  #
  # @param question [String] The question to query
  # @param images [Array<Hash>] Optional images as [{ data: "base64...", media_type: "image/png" }]
  # @param documents [Array<Hash>] Optional docs as [{ data: "base64...", media_type: "text/plain", filename: "x.txt" }]
  # @param session_id [String, nil] Bedrock session for multi-turn
  # @param response_locale [Symbol, String, nil] Force :en / :es; nil = detect from question
  # @param force_entity_filter [Boolean] When true, forces BedrockRagService to scope
  #   retrieval to entity_s3_uris regardless of the question text.
  # @return [RagResult]
  def execute_rag_query(question, images: [], documents: [], session_id: nil, response_locale: nil,
                        session_context: nil, conv_session: nil, entity_s3_uris: [],
                        output_channel: nil, force_entity_filter: false)
    question  = question.to_s.strip
    images    = Array(images).compact
    documents = Array(documents).compact

    if question.blank? && images.empty? && documents.empty?
      return RagResult.new(success?: false, error_type: :blank_question)
    end

    resolved_response_locale = resolve_response_locale(question, conv_session, override: response_locale)

    resolver_matches       = KbDocumentResolver.resolve(question)
    merged_entity_s3_uris  = merge_resolver_uris(entity_s3_uris, resolver_matches)
    merged_session_context = merge_resolver_context(session_context, resolver_matches)

    resolved_output_channel = output_channel&.to_sym || :web

    result = QueryOrchestratorService.new(
      question,
      images:              images,
      documents:           documents,
      tenant:              rag_tenant,
      session_id:          session_id,
      response_locale:     resolved_response_locale,
      session_context:     merged_session_context,
      conv_session:        conv_session,
      entity_s3_uris:      merged_entity_s3_uris,
      output_channel:      resolved_output_channel,
      force_entity_filter: force_entity_filter
    ).execute

    sanitized_answer = sanitize_answer(result[:answer], channel: resolved_output_channel)

    RagResult.new(
      success?:            true,
      answer:              sanitized_answer,
      citations:           result[:citations],
      retrieved_citations: result[:retrieved_citations],
      doc_refs:            result[:doc_refs],
      session_id:          result[:session_id],
      documents_uploaded:  result[:documents_uploaded],
      images_uploaded:     result[:images_uploaded]
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

  # Defensive sanitizer applied to model answers before delivery.
  # Strips markdown headers, converts pipe-tables to ① ② ③ lists, collapses blank lines.
  # @param channel [Symbol] reserved for future per-channel rules
  def sanitize_answer(text, channel: :web) # rubocop:disable Lint/UnusedMethodArgument
    return "" if text.blank?

    out = text.dup
    out = strip_markdown_headers(out)
    out = convert_markdown_tables(out)
    out = collapse_blank_lines(out)
    out.strip
  end

  def strip_markdown_headers(text)
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
          bullet    = CIRCLED_NUMERALS[row_idx] || "#{row_idx + 1}."
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

  # Renders JSON error response for API endpoints.
  def render_rag_json_error(result)
    error_config = json_error_config(result.error_type)
    render json: { message: error_config[:message], status: 'error' }, status: error_config[:http_status]
  end

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

  def rag_tenant
    return nil unless respond_to?(:current_user)
    user = current_user
    return nil unless user&.respond_to?(:tenant)
    user.tenant
  end

  # Resolves the generation locale with conversation continuity.
  # Field technicians type short, accent-less follow-ups (e.g. "Instalar") that
  # the question-only detector classifies as :en. To prevent the assistant from
  # switching languages mid-thread, we bias toward :es when any recent turn was
  # confidently Spanish.
  #
  # Precedence:
  #   1. Explicit override (response_locale: ...)
  #   2. Confident Spanish from current question (diacritics or stopwords)
  #   3. Recent conversation language (last ~6 turns)
  #   4. App default (I18n.locale, currently :es)
  HISTORY_LOCALE_LOOKBACK = 6
  HISTORY_MIN_CONTENT_LEN = 8

  def resolve_response_locale(question, conv_session, override: nil)
    return override.to_sym if override.present?

    detected = BedrockRagService.detect_language_from_question(question)
    return detected if detected == :es

    history_locale = detect_locale_from_history(conv_session)
    return history_locale if history_locale.present?

    detected
  end

  def detect_locale_from_history(conv_session)
    return nil unless conv_session.respond_to?(:conversation_history)

    history = Array(conv_session.conversation_history).last(HISTORY_LOCALE_LOOKBACK)
    history.reverse_each do |msg|
      content = msg["content"].to_s
      next if content.length < HISTORY_MIN_CONTENT_LEN

      locale = BedrockRagService.detect_language_from_question(content)
      return locale if locale == :es
    end
    nil
  end

  def merge_resolver_uris(caller_uris, resolver_matches)
    return Array(caller_uris) if resolver_matches.blank?

    bucket = ENV.fetch('KNOWLEDGE_BASE_S3_BUCKET', 'multimodal-source-destination')
    resolver_uris = resolver_matches.filter_map { |d| d.display_s3_uri(bucket) }
    (Array(caller_uris) + resolver_uris).uniq
  end

  def merge_resolver_context(session_context, resolver_matches)
    return session_context if resolver_matches.blank?

    lines = resolver_matches.map do |doc|
      aliases    = Array(doc.aliases).map(&:to_s).compact_blank.first(5)
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
