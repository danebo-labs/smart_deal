# frozen_string_literal: true

# app/controllers/concerns/rag_query_concern.rb
# Shared logic for hybrid queries (RAG + Text-to-SQL) across controllers.
# Used by RagController (API/JSON).

module RagQueryConcern
  extend ActiveSupport::Concern

  # Result object for queries.
  RagResult = Struct.new(:success?, :answer, :citations, :retrieved_citations, :doc_refs,
                         :retrieval_trace,
                         :session_id, :documents_uploaded, :images_uploaded, :correlation_id,
                         # Locale actually used to generate this answer (chat chrome/notices
                         # must follow this, never session/html lang — see rag-bedrock rule).
                         :response_locale,
                         :error_type, :error_message, :error_class,
                         # Deterministic-path observability (benchmark plan Fase 7/8).
                         # nil on the generative path.
                         :generation_mode, :model_invoked,
                         :parsed_record_ids, :rendered_record_ids,
                         :record_counts_by_type, :record_ledger_sha256,
                         :retrieved_chunk_sha256s, :deterministic_validation,
                         :quick_replies,
                         # :answered / :abstained when the route computed it structurally
                         # (currently only Rag::StructuredEvidenceRoute); nil elsewhere,
                         # meaning the caller must fall back to the text-based heuristic.
                         :route_outcome,
                         :pending_question,
                         keyword_init: true)

  # Circled numerals for ① ② ③ lists in table conversion and WA legacy callers.
  CIRCLED_NUMERALS = %w[① ② ③ ④ ⑤ ⑥ ⑦ ⑧ ⑨ ⑩].freeze

  RetrievalScope = Struct.new(:uris, :auto_scope_filter, :force_entity_filter, :reason, keyword_init: true)

  private

  def ignore_shadow_analysis(_analysis)
    nil
  end

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
                        output_channel: nil, force_entity_filter: nil, account: nil, user_id: nil,
                        correlation_id: nil, field_photo_id: nil, conversation_session_id: nil,
                        episode_turn: nil, conversational_turn_analysis: nil)
    question  = question.to_s.strip
    images    = Array(images).compact
    documents = Array(documents).compact
    # P1 shadow perception is observational. Effective query stays v4.
    ignore_shadow_analysis(conversational_turn_analysis)

    if question.blank? && images.empty? && documents.empty?
      return RagResult.new(success?: false, error_type: :blank_question)
    end

    resolved_response_locale = resolve_response_locale(question, conv_session, override: response_locale)
    resolved_output_channel = output_channel&.to_sym || :web

    resolved_account = account || current_account
    # `question` stays the raw turn for locale, pin labels, and episode exclude.
    # Only retrieval/generation sees `effective_question`.
    followup = nil
    effective_question = question
    if images.empty? && documents.empty? && conv_session
      if episode_turn_owns_thread?(episode_turn)
        # `question` stays the raw turn. Composition never reassigns it.
        effective_question = episode_turn.composed.presence || question
      else
        followup = Rag::FollowupQueryRewriter.call(
          question: question,
          conversation_session: conv_session,
          account: resolved_account,
          correlation_id: correlation_id
        )
        effective_question = followup.applied ? followup.question : question
        log_rag_followup(followup, question, correlation_id)

        if thread_menu_applicable?(followup, conv_session, resolved_output_channel) &&
           !selection_turn?(question, conv_session)
          thread = Rag::EpisodeThreadResolver.call(
            question: question,
            conversation_session: conv_session,
            correlation_id: correlation_id,
            locale: resolved_response_locale,
            now: Time.current
          )
          effective_question = thread.composed if thread.outcome == :join
        end
      end
    end

    resolver_matches = if followup&.applied
      followup.catalog_matches
    else
      KbDocumentResolver.resolve_scoped(effective_question, account: resolved_account)
    end
    pinned_uris            = Array(entity_s3_uris).compact
    pinned_uris            = resolve_pinned_scope(question, conv_session, pinned_uris)

    # A question does not pin a document, and neither does a previous turn.
    # Auto-scope and episode inheritance were the WhatsApp stand-in for a pin
    # control and for carrying that pin across the chat. Catalog matches of
    # this question stay in Query Resolution. Only a technician pin narrows
    # retrieval.
    scope = resolve_retrieval_scope(pinned_uris: pinned_uris)
    merged_session_context = merge_resolver_context(
      session_context, Array(resolver_matches), in_scope_uris: scope.uris
    )
    merged_session_context = merge_selection_intent(
      merged_session_context, question, conv_session
    )

    if pinned_uris.any?
      Rails.logger.info(
        "RagQueryConcern: scope reason=#{scope.reason} pinned=#{pinned_uris.size} " \
        "retrieval=#{scope.uris.size}"
      )
    end

    # Turno de selección puro: el texto es el nombre del pin que el toggle de
    # documentos autocompleta (rag_chat_controller#_updateTextareaWithDocName),
    # así que no lleva intención escrita. Con top_k 3 sobre documentos pinneados
    # la ventana de generación sería la identidad del documento y Bedrock
    # devolvería el resumen que nadie pidió (corrida 20260916T170508Z). Se
    # pregunta en vez de adivinar, sin llamar al modelo.
    # selection_gate? encapsula flag de episodio, selection_turn? y mensaje
    # previo presente. CG-D19 #G: la pregunta va en prosa, sin chips.
    gate = resolved_output_channel == :web && images.empty? && documents.empty? &&
      selection_gate?(question, conv_session)

    if gate
      Rails.logger.info(
        "RagQueryConcern: selection_gate uris=#{scope.uris.size} bedrock=0"
      )
      return RagResult.new(
        success?:        true,
        answer:          I18n.t("rag.selection_turn_prompt", locale: resolved_response_locale),
        citations:       [],
        session_id:      nil,
        response_locale: resolved_response_locale.to_s,
        generation_mode: "deterministic_selection_gate",
        model_invoked:   false,
        correlation_id:  correlation_id
      )
    end

    resolved_force_filter   = force_entity_filter.nil? ? scope.force_entity_filter : force_entity_filter
    document_uids           = documents.map { SecureRandom.uuid }

    result = QueryOrchestratorService.new(
      effective_question,
      images:              images,
      documents:           documents,
      document_uids:       document_uids,
      account:             resolved_account,
      session_id:          session_id,
      response_locale:     resolved_response_locale,
      session_context:     merged_session_context,
      conv_session:        conv_session,
      entity_s3_uris:      scope.uris,
      auto_scope_filter:   scope.auto_scope_filter,
      output_channel:      resolved_output_channel,
      force_entity_filter: resolved_force_filter,
      user_id:             user_id,
      conversation_session_id: conversation_session_id || (conv_session.id if conv_session.respond_to?(:id)),
      correlation_id:      correlation_id,
      field_photo_id:      field_photo_id
    ).execute

    # AnswerSafetyProcessor already runs once inside BedrockRagService#query with
    # the full evidence context (native citations or the fallback_retrieve chunks).
    # Re-running it here would degrade correct answers a second time, so the
    # concern only applies presentation sanitization.
    sanitized_answer = sanitize_answer(result[:answer], channel: resolved_output_channel)
    quick_replies    = result[:quick_replies]

    RagResult.new(
      success?:            true,
      answer:              sanitized_answer,
      citations:           result[:citations],
      retrieved_citations: result[:retrieved_citations],
      doc_refs:            result[:doc_refs],
      retrieval_trace:     result[:retrieval_trace],
      session_id:          result[:session_id],
      documents_uploaded:  result[:documents_uploaded],
      images_uploaded:     result[:images_uploaded],
      correlation_id:      result[:correlation_id],
      response_locale:     resolved_response_locale.to_s,
      generation_mode:     result[:generation_mode],
      model_invoked:       result.key?(:model_invoked) ? result[:model_invoked] : nil,
      parsed_record_ids:   result[:parsed_record_ids],
      rendered_record_ids: result[:rendered_record_ids],
      record_counts_by_type:    result[:record_counts_by_type],
      record_ledger_sha256:     result[:record_ledger_sha256],
      retrieved_chunk_sha256s:  result[:retrieved_chunk_sha256s],
      deterministic_validation: result[:deterministic_validation],
      quick_replies:             quick_replies,
      route_outcome:            result[:route_outcome],
      pending_question:         result[:pending_question]
    )
  rescue ImageCompressionService::CompressionError => e
    log_rag_error("Image compression", e)
    RagResult.new(success?: false, error_type: :image_compression, error_message: e.message, error_class: e.class.name)
  rescue BedrockRagService::MissingKnowledgeBaseError => e
    log_rag_error("RAG config error", e)
    RagResult.new(success?: false, error_type: :config_error, error_message: e.message, error_class: e.class.name)
  rescue BedrockRagService::BedrockServiceError => e
    log_rag_error("RAG AWS error", e)
    RagResult.new(success?: false, error_type: :service_error, error_message: e.message, error_class: e.class.name)
  rescue SqlGenerationService::SqlExecutionError => e
    log_rag_error("SQL execution error", e)
    RagResult.new(success?: false, error_type: :service_error, error_message: e.message, error_class: e.class.name)
  rescue StandardError => e
    log_rag_error("Query unexpected error", e, include_backtrace: true)
    RagResult.new(success?: false, error_type: :unexpected_error, error_message: e.message, error_class: e.class.name)
  end

  # An episode decision is the only thread reading while the turn flag is on.
  # The rewriter and the thread menu stay for :no_episode, :skipped, and no result.
  def episode_turn_owns_thread?(episode_turn)
    return false unless Rag::FieldCompanionTurnFlag.enabled?
    return false if episode_turn.nil?

    decision = episode_turn.decision&.to_sym
    decision.present? && decision != :no_episode && decision != :skipped
  end

  def thread_menu_applicable?(followup, conv_session, output_channel)
    return false unless Rag::ThreadMenuFlag.enabled?
    return false if followup.nil? || followup.applied
    return false if %w[no_session non_web_channel account_mismatch].include?(followup.reason)
    return false if output_channel == :whatsapp
    return false unless conv_session.respond_to?(:channel)

    (output_channel == :web && conv_session.channel == "web") ||
      (SharedSession::ENABLED && conv_session.channel == SharedSession::CHANNEL && output_channel != :whatsapp)
  end

  def log_rag_followup(followup, original, correlation_id)
    effective = followup.applied ? followup.question : original
    catalog_ids = Array(followup.catalog_matches).filter_map { |match| match.document&.id }
    Rails.logger.info(
      "[RAG_FOLLOWUP] applied=#{followup.applied} reason=#{followup.reason} " \
      "correlation_id=#{correlation_id} " \
      "previous_correlation_id=#{followup.previous_correlation_id} " \
      "original_sha256=#{Digest::SHA256.hexdigest(original.to_s)} " \
      "effective_sha256=#{Digest::SHA256.hexdigest(effective.to_s)} " \
      "original_chars=#{original.to_s.length} effective_chars=#{effective.to_s.length} " \
      "catalog_ids=#{catalog_ids.join(',')}"
    )
  end

  # Defensive sanitizer applied to model answers before delivery.
  # Strips markdown headers, converts pipe-tables to ① ② ③ lists, collapses blank lines.
  # @param channel [Symbol] reserved for future per-channel rules
  def sanitize_answer(text, channel: :web) # rubocop:disable Lint/UnusedMethodArgument
    return "" if text.blank?

    out = text.dup
    out = strip_markdown_headers(out)
    out = strip_markdown_labels(out)
    out = convert_markdown_tables(out)
    out = collapse_blank_lines(out)
    out.strip
  end

  # CG-D19: a markdown heading the model writes ("# Respuesta", "## Dato
  # faltante") is a label, not prose. The whole line goes, not just the hashes.
  def strip_markdown_headers(text)
    text.gsub(/^[ \t]*\#{1,6}\s+[^\n]*\n?/, '')
  end

  # CG-D19 (medición 10): a line that is only a bold label («**Datos
  # faltantes:**», «**Recomendación:**»), a horizontal rule, or an empty bold
  # left behind is form, not prose. The sentences under it stay.
  def strip_markdown_labels(text)
    text
      .gsub(/^[ \t]*\*\*[^*\n]{1,80}\*\*:?[ \t]*\n?/, '')
      .gsub(/^[ \t]*(?:-{3,}|\*{3,}|_{3,})[ \t]*\n?/, '')
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

  # Resolves the generation locale with conversation continuity.
  # Field technicians type short, accent-less follow-ups (e.g. "Instalar") that
  # the question-only detector classifies as :en. To prevent the assistant from
  # switching languages mid-thread, we bias toward :es when any recent turn was
  # confidently Spanish.
  #
  # Precedence:
  #   1. Explicit override (response_locale: ...)
  #   2. Confident current question language (:es by detector, or :en with >=4 tokens)
  #   3. Recent conversation language (last ~6 turns)
  #   4. App default (I18n.locale, currently :es)
  HISTORY_LOCALE_LOOKBACK = 6
  HISTORY_MIN_CONTENT_LEN = 8
  CURRENT_QUERY_LOCALE_MIN_TOKENS = 4

  def resolve_response_locale(question, conv_session, override: nil)
    return override.to_sym if override.present?

    detected = BedrockRagService.detect_language_from_question(question)
    return detected if current_question_locale_confident?(question, detected)

    history_locale = detect_locale_from_history(conv_session)
    return history_locale if history_locale.present?

    detected
  end

  def current_question_locale_confident?(question, detected)
    return true if detected == :es && BedrockRagService.strong_spanish_evidence?(question)

    tokens = question.to_s.downcase.scan(/\b[a-z]+\b/)
    detected == :en && tokens.size >= CURRENT_QUERY_LOCALE_MIN_TOKENS
  end

  def detect_locale_from_history(conv_session)
    return nil unless conv_session.respond_to?(:conversation_history)

    history = Array(conv_session.conversation_history).last(HISTORY_LOCALE_LOOKBACK)
    history.reverse_each do |msg|
      content = msg["content"].to_s
      next if content.length < HISTORY_MIN_CONTENT_LEN

      return :es if BedrockRagService.strong_spanish_evidence?(content)
      return :en if BedrockRagService.strong_english_evidence?(content)
    end
    nil
  end

  def merge_resolver_context(session_context, resolver_matches, in_scope_uris: nil)
    matches = Array(resolver_matches).compact
    return session_context if matches.empty?

    matches = matches.uniq { |match| match.document.display_s3_uri(KbDocument::KB_BUCKET) }
    scoped_uris = Array(in_scope_uris).compact

    if scoped_uris.empty?
      in_scope     = matches
      out_of_scope = []
    else
      in_scope     = matches.select { |match| scoped_uris.include?(match.document.display_s3_uri(KbDocument::KB_BUCKET)) }
      out_of_scope = matches - in_scope
    end

    return session_context if in_scope.empty? && out_of_scope.empty?

    lines = in_scope.map { |match| format_resolver_match_line(match) }
    block = <<~BLOCK.strip
      ## Query Resolution
      The user's query mentions documents that exist in the catalog. Treat the names below and any of their aliases as references to the SAME physical document. Do NOT claim the document is not found.
      #{lines.join("\n")}
    BLOCK

    if out_of_scope.any?
      out_lines = out_of_scope.map { |match| format_resolver_match_line(match) }
      block = [
        block,
        "Also in catalog but NOT consulted this turn (do not cite, do not describe their content):",
        out_lines.join("\n")
      ].join("\n")
    end

    [ session_context.presence, block ].compact.join("\n\n")
  end

  def format_resolver_match_line(match)
    doc        = match.document
    aliases    = Array(doc.aliases).map(&:to_s).compact_blank.first(5)
    alias_note = aliases.any? ? " (aka: #{aliases.join(', ')})" : ""
    "- \"#{doc.display_name}\" → #{doc.s3_key}#{alias_note}"
  end

  # Retired with auto-scope. Prior WhatsApp turns no longer choose a manual
  # or carry one into this retrieve.
  def inherit_episode_scope(_question, _conv_session, _account)
    [ [], [] ]
  end

  def auto_scope_uris_from(_resolver_matches)
    []
  end

  def mentioned_uris_from(resolver_matches)
    Array(resolver_matches).filter_map { |match| match.document.display_s3_uri(KbDocument::KB_BUCKET) }.uniq
  end

  # Catalog matches are not a pin. Only the technician's document pin
  # narrows retrieval; an unpinned question searches the shared corpus.
  def resolve_retrieval_scope(pinned_uris:, **)
    if pinned_uris.empty?
      RetrievalScope.new(
        uris: [],
        auto_scope_filter: false,
        force_entity_filter: false,
        reason: "open"
      )
    else
      RetrievalScope.new(
        uris: pinned_uris,
        auto_scope_filter: false,
        force_entity_filter: true,
        reason: "pin_only"
      )
    end
  end

  # Bounded instruction for a pin-name selection turn with a live episode.
  # Jesús T3 (Fase 5 replay) treated the pin name as a request for a general
  # Elemont summary. Keep the user question literal; do not add procedures.
  def merge_selection_intent(session_context, question, conv_session)
    return session_context unless Rag::EpisodeScopeFlag.enabled?
    return session_context unless selection_turn?(question, conv_session)
    return session_context unless conv_session.respond_to?(:episode_user_messages)

    previous = conv_session.episode_user_messages(exclude: question).last
    return session_context if previous.blank?

    selected = question.to_s.strip
    block = <<~BLOCK.strip
      ## Selection Turn
      The technician named "#{selected}" to select that pinned document, not to request a general summary.
      Active problem from the previous user turn: "#{previous}"
      Continue that problem. Do not write a general document summary unless the user explicitly asked for one. Do not invent procedures or values.
    BLOCK

    [ session_context.presence, block ].compact.join("\n\n")
  end

  def selection_gate?(question, conv_session)
    return false unless Rag::EpisodeScopeFlag.enabled?
    return false unless selection_turn?(question, conv_session)
    return false unless conv_session.respond_to?(:episode_user_messages)

    conv_session.episode_user_messages(exclude: question).last.present?
  end

  def selection_turn?(question, conv_session)
    return false unless conv_session.respond_to?(:active_entities)

    normalized = normalize_entity_label(question)
    return false if normalized.blank?

    conv_session.active_entities.any? do |key, meta|
      [ key, meta["canonical_name"], *Array(meta["aliases"]) ]
        .compact
        .any? { |label| normalize_entity_label(label) == normalized }
    end
  end

  # Misma normalización que Rag::PinnedEntityScopeResolver#normalize.
  def normalize_entity_label(value)
    value.to_s
         .unicode_normalize(:nfkd)
         .gsub(/\p{Mn}/, "")
         .downcase
         .gsub(/[^\p{L}\d]+/, " ")
         .squish
  end

  def resolve_pinned_scope(question, conv_session, pinned_uris)
    return pinned_uris unless pinned_uris.many?
    return pinned_uris unless conv_session.respond_to?(:active_entities)

    result = Rag::PinnedEntityScopeResolver.new(
      question: question,
      active_entities: conv_session.active_entities,
      allowed_uris: pinned_uris
    ).resolve

    if result.narrowed
      Rails.logger.info(
        "RagQueryConcern: narrowed pinned retrieval to #{result.matched_keys.join(', ')}"
      )
    end

    result.uris
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
