# frozen_string_literal: true

# Performs the actual Bedrock RAG query and delivers the answer to a WhatsApp
# recipient via the Twilio REST API.
#
# R2 — Faceted follow-up cache:
#   1. Read cached faceted answer for this recipient.
#   2. Classify incoming message via the closed-allowlist policy (see
#      Rag::WhatsappFollowupClassifier docstring — safety-first: anything
#      outside the navigation allowlist is treated as a content query).
#   3. Route to :facet_hit / :show_menu / :reset_ack / :no_context_help
#      (all 0 Bedrock tokens), or :new_query (retrieve_and_generate +
#      write cache).
# Feature-flagged via `WA_FACETED_OUTPUT_ENABLED` (default true) → rollback is
# one env flip away.
class SendWhatsappReplyJob < ApplicationJob
  include RagQueryConcern

  queue_as :whatsapp_rag

  # @param to              [String]  Recipient WhatsApp number, e.g. "whatsapp:+5491122334455"
  # @param from            [String]  Twilio WhatsApp number
  # @param body            [String]  The user's message text
  # @param conv_session_id [Integer] ConversationSession#id for history tracking
  def perform(to:, from:, body:, conv_session_id: nil)
    conv_session = conv_session_id ? ConversationSession.find_by(id: conv_session_id) : nil

    if faceted_enabled?
      perform_faceted(to: to, from: from, body: body, conv_session: conv_session)
    else
      perform_legacy(to: to, from: from, body: body, conv_session: conv_session)
    end
  rescue Twilio::REST::RestError => e
    Rails.logger.error("SendWhatsappReplyJob: Twilio delivery failed — #{e.message}")
    raise
  rescue StandardError => e
    Rails.logger.error("SendWhatsappReplyJob: unexpected error — #{e.message}")
    raise
  end

  private

  def faceted_enabled?
    ENV.fetch("WA_FACETED_OUTPUT_ENABLED", "true") == "true"
  end

  def processing_ack_enabled?
    ENV.fetch("WA_PROCESSING_ACK_ENABLED", "true") == "true"
  end

  # Sends a short "🛠 Consultando…" bubble before the real RAG reply is
  # generated. Fires ONLY on the :new_query branch so cache hits / resets
  # stay silent. Any Twilio failure is swallowed: the ack is a UX nicety,
  # not something that should abort the real answer.
  def deliver_processing_ack(to:, from:, locale:)
    msg = I18n.with_locale(locale) { I18n.t("rag.wa_processing_ack") }
    deliver_whatsapp(msg, to: to, from: from)
    Rails.logger.info("[WA_ACK] to=#{to} reason=new_query_before_rag")
  rescue StandardError => e
    Rails.logger.warn("[WA_ACK] to=#{to} error=#{e.class} msg=#{e.message}")
  end

  # R2 faceted path — cache + classifier.
  def perform_faceted(to:, from:, body:, conv_session:)
    # Post-reset picker state (inicio → 1/2 → list → pick doc) short-circuits
    # the normal classifier path so the two-step sub-menu stays deterministic.
    return if try_handle_post_reset_state(to: to, from: from, body: body, conv_session: conv_session)

    cached   = Rag::WhatsappAnswerCache.read(to, conv_session: conv_session)
    locale   = infer_locale(body, cached, conv_session: conv_session, whatsapp_to: to)
    decision = Rag::WhatsappFollowupClassifier.classify(
      message: body, cached: cached, conv_session: conv_session, locale: locale
    )
    Rails.logger.info(
      "[WA_CLASSIFIER] to=#{to} route=#{decision.route} reason=#{decision.reason} " \
      "confidence=#{format('%.2f', decision.confidence || 0)}"
    )

    reply, history_entry =
      case decision.route
      when :facet_hit
        faceted = Rag::FacetedAnswer.from_cache(cached[:faceted])
        msg     = faceted.to_facet_message(
          decision.facet_key,
          locale:         cached[:locale] || locale,
          document_label: cached[:document_label]
        )
        if msg.blank?
          # Defensive: classifier guards against empty facets (:empty_facet_reconsult),
          # but if the renderer still produces a blank body, fall back to a notice
          # rather than emit an empty Twilio body.
          msg = empty_facet_notice_message(cached: cached, requested_key: decision.facet_key, locale: cached[:locale] || locale)
        end
        log_facet_delivery(to: to, facet_key: decision.facet_key, length: msg.length)
        [ msg, msg.truncate(200) ]
      when :show_menu
        faceted = Rag::FacetedAnswer.from_cache(cached[:faceted])
        msg     = faceted.to_whatsapp_first_message(
          locale:         cached[:locale] || locale,
          document_label: cached[:document_label]
        )
        log_facet_delivery(to: to, facet_key: :__menu__, length: msg.length)
        [ msg, msg.truncate(200) ]
      when :reset_ack
        Rag::WhatsappAnswerCache.invalidate(to)
        Rag::WhatsappPostResetState.write(to, phase: Rag::WhatsappPostResetState::PHASE_PICKING_SOURCE)
        msg = reset_ack_message(locale: locale)
        [ msg, msg ]
      when :no_context_help
        [ no_context_help_message(locale: locale), nil ]
      else
        Rag::WhatsappAnswerCache.invalidate(to)
        deliver_processing_ack(to: to, from: from, locale: locale) if processing_ack_enabled?
        run_rag_and_cache(body: body, to: to, conv_session: conv_session)
      end

    deliver_whatsapp(reply, to: to, from: from)
    conv_session&.add_to_history("assistant", history_entry || reply.to_s.truncate(500))
  end

  # Legacy pre-R2 path — kept for feature-flag rollback.
  def perform_legacy(to:, from:, body:, conv_session:)
    session_context = conv_session ? SessionContextBuilder.build(conv_session) : nil
    entity_s3_uris  = SessionContextBuilder.entity_s3_uris(conv_session)

    # Legacy path always hits Bedrock — ack for consistency with faceted :new_query.
    if processing_ack_enabled?
      legacy_locale = infer_locale(body, nil, conv_session: conv_session, whatsapp_to: to)
      deliver_processing_ack(to: to, from: from, locale: legacy_locale)
    end

    result = execute_rag_query(body, whatsapp_to: to, session_context: session_context, conv_session: conv_session, entity_s3_uris: entity_s3_uris)
    reply  = format_rag_response_for_whatsapp(result)
    log_whatsapp_safety_coverage(reply, to: to) if result.success?

    deliver_whatsapp(reply, to: to, from: from)
    persist_entities(conv_session, result, body)
    conv_session&.add_to_history("assistant", reply)
  end

  # Runs Bedrock, parses facets, writes cache (unless EMERGENCY), returns
  # [first_message, history_entry].
  def run_rag_and_cache(body:, to:, conv_session:)
    session_context = conv_session ? SessionContextBuilder.build(conv_session) : nil
    entity_s3_uris  = SessionContextBuilder.entity_s3_uris(conv_session)

    result = execute_rag_query(
      body,
      whatsapp_to:     to,
      session_context: session_context,
      conv_session:    conv_session,
      entity_s3_uris:  entity_s3_uris
    )

    unless result.success?
      msg = format_rag_response_for_whatsapp(result)
      return [ msg, msg.truncate(500) ]
    end

    faceted = result.faceted
    locale  = whatsapp_response_locale(result)

    document_label = derive_document_label(conv_session: conv_session, result: result)

    first_message =
      if faceted && !faceted.legacy?
        header   = result.citations.present? ? build_documents_consulted_header(result) : ""
        body_msg = faceted.to_whatsapp_first_message(locale: locale, document_label: document_label)
        [ header, body_msg ].reject(&:empty?).join("\n\n")
      else
        # Model didn't emit labels; preserve the existing formatter.
        format_rag_response_for_whatsapp(result)
      end

    log_whatsapp_safety_coverage(first_message, to: to)
    persist_entities(conv_session, result, body)
    write_cache(to: to, body: body, result: result, faceted: faceted,
                locale: locale, conv_session: conv_session,
                document_label: document_label)

    [ first_message, first_message.truncate(500) ]
  end

  def write_cache(to:, body:, result:, faceted:, locale:, conv_session:, document_label: nil)
    return if faceted.nil? || faceted.legacy?

    entities = conv_session ? conv_session.active_entities.keys.map(&:to_s) : []
    Rag::WhatsappAnswerCache.write(to, {
      question:         body.to_s,
      question_hash:    Rag::WhatsappAnswerCache.question_hash(body),
      faceted:          faceted.to_cache_hash.merge(entities: entities),
      citations:        Array(result.citations),
      doc_refs:         Array(result.doc_refs),
      locale:           locale,
      entity_signature: Rag::WhatsappAnswerCache.entity_signature_for(conv_session),
      intent:           faceted.intent,
      document_label:   document_label
    })
  end

  # Short human-readable document label for facet headers. Priority:
  #   1. First entity in conv_session.active_entities (display form)
  #   2. First doc_ref short_name / title / filename from the RAG result
  # Truncated to 40 chars so it never blows up the compact "*Riesgos · <doc>*" header.
  def derive_document_label(conv_session:, result:)
    label = nil
    if conv_session && conv_session.active_entities.any?
      raw = conv_session.active_entities.keys.first.to_s
      label = raw.tr("_-", " ").squeeze(" ").strip
    end
    if label.blank?
      ref  = Array(result&.doc_refs).first
      if ref.is_a?(Hash)
        label = (ref[:short_name] || ref[:title] || ref[:filename] || ref["short_name"] || ref["title"] || ref["filename"]).to_s
      end
    end
    return nil if label.blank?
    label.strip[0, 40].strip.presence
  end

  def deliver_whatsapp(reply, to:, from:)
    chunks = split_for_whatsapp(reply.to_s)

    account_sid = ENV.fetch('TWILIO_ACCOUNT_SID') { raise "TWILIO_ACCOUNT_SID not set in environment" }
    auth_token  = ENV.fetch('TWILIO_AUTH_TOKEN')  { raise "TWILIO_AUTH_TOKEN not set in environment" }
    client      = Twilio::REST::Client.new(account_sid, auth_token)

    chunks.each_with_index do |chunk, i|
      prefix = chunks.size > 1 ? "(#{i + 1}/#{chunks.size}) " : ""
      client.messages.create(from: from, to: to, body: "#{prefix}#{chunk}")
      sleep(0.5) if i < chunks.size - 1
    end

    Rails.logger.info("SendWhatsappReplyJob: delivered #{chunks.size} message(s) (#{reply.to_s.length} chars) to #{to}")
  end

  def persist_entities(conv_session, result, body)
    return unless conv_session && result.success?
    EntityExtractorService.new(conv_session).extract_and_update(
      Array(result.citations),
      user_message:  body,
      answer:        result.answer,
      all_retrieved: Array(result.retrieved_citations),
      doc_refs:      result[:doc_refs]
    )
  end

  # Locale resolution order (first non-nil wins):
  #   1. Cached faceted answer's locale (same thread, same topic)
  #   2. Sticky WA thread locale written by RagQueryConcern#execute_rag_query
  #      under "rag_whatsapp_conv/v1/<to>" (TTL ≈ 7 days) — survives cache miss
  #      after the 30-min faceted TTL has expired.
  #   3. Language heuristic over the last 3 user turns of conv_session history
  #      (only when there's enough text to classify reliably).
  #   4. Language heuristic on the current body.
  #   5. I18n.default_locale.
  def infer_locale(body, cached, conv_session: nil, whatsapp_to: nil)
    cached_locale = cached && (cached[:locale] || cached["locale"])
    return cached_locale.to_sym if cached_locale.present?

    if whatsapp_to.present?
      sticky = Rails.cache.read("rag_whatsapp_conv/v1/#{whatsapp_to}")
      raw    = sticky.is_a?(Hash) ? sticky["locale"] : sticky
      return raw.to_sym if raw.present?
    end

    if conv_session
      user_snippets = conv_session.recent_history_for_prompt(turns: 6)
                                  .select { |h| h[:role].to_s == "user" }
                                  .map { |h| h[:content].to_s }.last(3).join(" ")
      detected = BedrockRagService.detect_language_from_question(user_snippets) if user_snippets.length >= 6
      return detected if detected
    end

    BedrockRagService.detect_language_from_question(body.to_s) || I18n.default_locale
  end

  def no_context_help_message(locale:)
    I18n.with_locale(locale) { I18n.t("rag.wa_no_context_help") }
  end

  def reset_ack_message(locale:)
    I18n.with_locale(locale) { I18n.t("rag.wa_reset_ack") }
  end

  def empty_facet_notice_message(cached:, requested_key:, locale:)
    faceted = Rag::FacetedAnswer.from_cache(cached[:faceted])
    alternatives = faceted.menu
                          .reject { |m| m[:facet_key].to_sym == requested_key.to_sym }
                          .reject { |m| faceted.facet_empty?(m[:facet_key]) }
                          .map { |m| "#{m[:n]} #{m[:label]}" }
                          .join(" · ")

    I18n.with_locale(locale) do
      facet_name = I18n.t("rag.wa_facet_names.#{requested_key}", default: requested_key.to_s)
      I18n.t("rag.wa_empty_facet_notice", facet: facet_name, alternatives: alternatives.presence || "menu")
    end
  end

  def log_facet_delivery(to:, facet_key:, length:)
    Rails.logger.info("[WA_FACET_DELIVERY] to=#{to} facet_key=#{facet_key} length=#{length}")
  end

  # Reset-like tokens that work from ANY post-reset sub-phase (back to
  # picking_source / home). Kept here (not inside the classifier) because the
  # post-reset state lives outside the faceted cache contract.
  POST_RESET_BACK_TOKENS  = %w[6 inicio start home reset nuevo nueva new 5 regresar volver menu back atras atrás].freeze

  # Handles 1/2 picks after reset + digit picks after a list was shown.
  # Returns true when the message was absorbed by the post-reset flow
  # (caller must skip the normal classifier path).
  def try_handle_post_reset_state(to:, from:, body:, conv_session:)
    state = Rag::WhatsappPostResetState.read(to)
    return false if state.blank?

    norm   = Rag::WhatsappFollowupClassifier.normalize(body)
    locale = infer_locale(body, nil, conv_session: conv_session, whatsapp_to: to)

    case Rag::WhatsappPostResetState.phase_of(state)
    when Rag::WhatsappPostResetState::PHASE_PICKING_SOURCE
      handle_post_reset_pick_source(norm: norm, to: to, from: from, locale: locale, conv_session: conv_session)
    when Rag::WhatsappPostResetState::PHASE_PICKING_FROM_LIST
      handle_post_reset_pick_doc(norm: norm, state: state, to: to, from: from, locale: locale, conv_session: conv_session)
    else
      false
    end
  end

  def handle_post_reset_pick_source(norm:, to:, from:, locale:, conv_session:)
    # Back/home from picking_source is idempotent — re-render the same prompt.
    if POST_RESET_BACK_TOKENS.include?(norm)
      msg = reset_ack_message(locale: locale)
      deliver_whatsapp(msg, to: to, from: from)
      conv_session&.add_to_history("assistant", msg)
      return true
    end

    source =
      case norm
      when "1" then :recent
      when "2" then :all
      end
    # Natural-language query while sitting in picking_source → abandon the
    # picker (user moved on) so a stale "1" later doesn't re-trigger the list.
    if source.nil?
      Rag::WhatsappPostResetState.clear(to)
      return false
    end

    items = Rag::WhatsappDocumentPicker.list(source: source, conv_session: conv_session)
    msg   = Rag::WhatsappDocumentPicker.render(items: items, source: source, locale: locale)

    if items.empty?
      # Stay in picking_source so the user can try the other list or a free query.
      Rails.logger.info("[WA_POST_RESET] to=#{to} op=empty_list source=#{source}")
    else
      Rag::WhatsappPostResetState.write(
        to,
        phase:   Rag::WhatsappPostResetState::PHASE_PICKING_FROM_LIST,
        source:  source,
        doc_ids: items.map(&:id)
      )
    end

    deliver_whatsapp(msg, to: to, from: from)
    conv_session&.add_to_history("assistant", msg.to_s.truncate(500))
    true
  end

  def handle_post_reset_pick_doc(norm:, state:, to:, from:, locale:, conv_session:)
    if norm == "0"
      Rag::WhatsappPostResetState.write(to, phase: Rag::WhatsappPostResetState::PHASE_PICKING_SOURCE)
      msg = reset_ack_message(locale: locale)
      deliver_whatsapp(msg, to: to, from: from)
      conv_session&.add_to_history("assistant", msg)
      return true
    end

    if POST_RESET_BACK_TOKENS.include?(norm)
      Rag::WhatsappPostResetState.write(to, phase: Rag::WhatsappPostResetState::PHASE_PICKING_SOURCE)
      msg = reset_ack_message(locale: locale)
      deliver_whatsapp(msg, to: to, from: from)
      conv_session&.add_to_history("assistant", msg)
      return true
    end

    unless norm.match?(/\A\d+\z/)
      # Non-digit, non-back input → the tech is asking something else. Drop the
      # picker so the classifier handles it cleanly on the next turn.
      Rag::WhatsappPostResetState.clear(to)
      return false
    end

    idx     = norm.to_i - 1
    doc_ids = Rag::WhatsappPostResetState.doc_ids_of(state)
    if idx < 0 || idx >= doc_ids.length
      Rag::WhatsappPostResetState.clear(to)
      return false
    end

    source = Rag::WhatsappPostResetState.source_of(state) || :recent
    seed   = Rag::WhatsappDocumentPicker.seed_query(source: source, id: doc_ids[idx], locale: locale)
    if seed.blank?
      Rails.logger.warn("[WA_POST_RESET] to=#{to} op=seed_miss idx=#{idx} id=#{doc_ids[idx]} source=#{source}")
      Rag::WhatsappPostResetState.clear(to)
      return false
    end

    Rag::WhatsappPostResetState.clear(to)
    Rails.logger.info("[WA_POST_RESET] to=#{to} op=pick_doc source=#{source} id=#{doc_ids[idx]}")

    deliver_processing_ack(to: to, from: from, locale: locale) if processing_ack_enabled?
    reply, history_entry = run_rag_and_cache(body: seed, to: to, conv_session: conv_session)
    deliver_whatsapp(reply, to: to, from: from)
    conv_session&.add_to_history("assistant", history_entry || reply.to_s.truncate(500))
    true
  end
end
