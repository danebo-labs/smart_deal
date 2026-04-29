# frozen_string_literal: true

# Performs the actual Bedrock RAG query and delivers the answer to a WhatsApp
# recipient via the Twilio REST API.
#
# R3 — Structured dynamic-section follow-up cache:
#   1. Read cached structured answer for this recipient.
#   2. Classify incoming message via the closed-allowlist policy (see
#      Rag::WhatsappFollowupClassifier docstring — safety-first: anything
#      outside the navigation allowlist is treated as a content query).
#   3. Route to :section_hit / :show_doc_list / :user_reset /
#      :reset_ack_with_picker / :no_context_help (all 0 Bedrock tokens), or
#      :new_query (retrieve_and_generate + write cache).
# Feature-flagged via `WA_FACETED_OUTPUT_ENABLED` (default true) → rollback to
# perform_legacy is one env flip away.
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
      when :section_hit
        structured = Rag::FacetedAnswer.from_cache(cached[:structured])
        msg        = structured.to_section_message(decision.section_key, locale: cached[:locale] || locale)
        if msg.blank?
          msg = structured.to_whatsapp_first_message(locale: cached[:locale] || locale)
        end
        log_facet_delivery(to: to, facet_key: decision.section_key, length: msg.length)
        TrackWhatsappCacheHitJob.perform_later(recipient: to, route: "section_hit")
        [ msg, msg.truncate(200) ]
      when :show_doc_list
        msg = render_doc_list_and_arm_picker(
          to: to, source: decision.source, locale: locale, conv_session: conv_session
        )
        TrackWhatsappCacheHitJob.perform_later(recipient: to, route: "show_doc_list")
        [ msg, msg.truncate(200) ]
      when :reset_ack_with_picker
        Rag::WhatsappAnswerCache.invalidate(to)
        Rag::WhatsappPostResetState.write(
          to,
          phase:  Rag::WhatsappPostResetState::PHASE_PICKING_SOURCE,
          origin: Rag::WhatsappPostResetState::ORIGIN_RESET_PICKER
        )
        msg = reset_ack_message(locale: locale)
        TrackWhatsappCacheHitJob.perform_later(recipient: to, route: "reset_ack_with_picker")
        [ msg, msg ]
      when :user_reset
        Rag::WhatsappAnswerCache.invalidate(to)
        msg = new_query_ack_message(locale: locale)
        [ msg, msg ]
      when :no_context_help
        TrackWhatsappCacheHitJob.perform_later(recipient: to, route: "no_context_help")
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
  #
  # @param entity_s3_uris_override [Array<String>, nil] When provided (non-empty),
  #   replaces the URIs derived from the session's active_entities. Required when
  #   the caller has bound the query to a doc that isn't (yet) in the session
  #   working set — e.g. a fresh KbDocument pick from the post-reset picker.
  # @param force_entity_filter [Boolean] When true, BedrockRagService bypasses its
  #   "query names a different document" heuristic — the seeded query for a
  #   picked doc contains many capitalized words that would otherwise trip it.
  def run_rag_and_cache(body:, to:, conv_session:, entity_s3_uris_override: nil, force_entity_filter: false)
    session_context = conv_session ? SessionContextBuilder.build(conv_session) : nil
    derived_uris    = SessionContextBuilder.entity_s3_uris(conv_session)
    entity_s3_uris  = (entity_s3_uris_override.presence || derived_uris)

    result = execute_rag_query(
      body,
      whatsapp_to:         to,
      session_context:     session_context,
      conv_session:        conv_session,
      entity_s3_uris:      entity_s3_uris,
      force_entity_filter: force_entity_filter
    )

    unless result.success?
      msg = format_rag_response_for_whatsapp(result)
      return [ msg, msg.truncate(500) ]
    end

    structured = result.faceted
    locale     = whatsapp_response_locale(result)

    first_message =
      if structured && !structured.legacy?
        # No "Documents consulted" header anymore: the structured answer
        # already carries per-section source attribution + a multi-doc banner
        # inside `to_whatsapp_first_message`. Adding a citations header on top
        # was the source of the stale-doc-label UX bug (it mixed old entities
        # with fresh answer content).
        structured.to_whatsapp_first_message(locale: locale)
      else
        # Model didn't emit labels at all; preserve the legacy formatter.
        format_rag_response_for_whatsapp(result)
      end

    first_message = prepend_fresh_upload_banner(first_message, conv_session: conv_session, locale: locale)

    log_whatsapp_safety_coverage(first_message, to: to)
    persist_entities(conv_session, result, body)
    write_cache(to: to, body: body, result: result, structured: structured,
                locale: locale, conv_session: conv_session)

    [ first_message, first_message.truncate(500) ]
  end

  # Prepends a one-line "📸 Recién subido: <name>" banner to the first
  # message of the new-query branch when the session carries a fresh image
  # upload (≤ FRESH_UPLOAD_WINDOW old, no first_answer_summary yet). The
  # multi-doc retrieval contract is intentionally preserved — this is purely
  # a visibility cue so the technician confirms the just-uploaded photo is
  # part of the answer set.
  def prepend_fresh_upload_banner(message, conv_session:, locale:)
    return message if conv_session.nil?

    fresh = SessionContextBuilder.fresh_upload_entity(conv_session)
    return message if fresh.nil?

    name   = fresh[:canonical_name].to_s.strip
    return message if name.empty?

    banner = I18n.with_locale(locale) do
      I18n.t("rag.wa_fresh_upload_banner", name: name.truncate(120),
             default: "📸 *Recién subido:* #{name.truncate(120)}")
    end
    "#{banner}\n\n#{message}"
  end

  def write_cache(to:, body:, result:, structured:, locale:, conv_session:)
    return if structured.nil? || structured.legacy?

    Rag::WhatsappAnswerCache.write(to, {
      question:         body.to_s,
      question_hash:    Rag::WhatsappAnswerCache.question_hash(body),
      structured:       structured.to_cache_hash,
      citations:        Array(result.citations),
      doc_refs:         Array(result.doc_refs),
      locale:           locale,
      entity_signature: Rag::WhatsappAnswerCache.entity_signature_for(conv_session),
      intent:           structured.intent
    })
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

  def new_query_ack_message(locale:)
    I18n.with_locale(locale) { I18n.t("rag.wa_new_query_ack") }
  end

  def log_facet_delivery(to:, facet_key:, length:)
    Rails.logger.info("[WA_FACET_DELIVERY] to=#{to} facet_key=#{facet_key} length=#{length}")
  end

  # Renders the recent / all docs list (reusing WhatsappDocumentPicker) and
  # arms PHASE_PICKING_FROM_LIST so the user's next digit picks a document.
  # Once a doc is picked, handle_post_reset_pick_doc seeds a query and routes
  # through run_rag_and_cache — the standard cache logic applies to that
  # follow-up answer.
  #
  # Always opens at page 1; pagination across the catalog is driven by the
  # `+`/`-` tokens handled in handle_post_reset_pick_doc.
  #
  # Origin = :faceted_cached → "0/back" from the list MUST restore the prior
  # cached faceted answer (technician was just peeking at recent files), not
  # show "contexto reiniciado". The cache itself is preserved here so the
  # restore branch in handle_post_reset_pick_doc can read it.
  def render_doc_list_and_arm_picker(to:, source:, locale:, conv_session:)
    page_obj = Rag::WhatsappDocumentPicker.list(source: source, conv_session: conv_session, page: 1)
    msg      = Rag::WhatsappDocumentPicker.render(
      page: page_obj, source: source, locale: locale,
      origin: Rag::WhatsappPostResetState::ORIGIN_FACETED_CACHED
    )

    if page_obj.items.any?
      Rag::WhatsappPostResetState.write(
        to,
        phase:   Rag::WhatsappPostResetState::PHASE_PICKING_FROM_LIST,
        source:  source,
        doc_ids: page_obj.items.map(&:id),
        origin:  Rag::WhatsappPostResetState::ORIGIN_FACETED_CACHED,
        page:    page_obj.page
      )
      Rails.logger.info(
        "[WA_FACET_DELIVERY] to=#{to} facet_key=__list_#{source}__ " \
        "count=#{page_obj.items.size} page=#{page_obj.page}/#{page_obj.total_pages} total=#{page_obj.total_count}"
      )
    else
      Rails.logger.info("[WA_FACET_DELIVERY] to=#{to} facet_key=__list_#{source}__ count=0")
    end
    msg
  end

  # "Back one step" — these mean "return to where I came from" (the cached
  # faceted answer if we got here via menu __list_*__, otherwise the source
  # picker). Checked BEFORE POST_RESET_HOME_TOKENS so the natural-language
  # back words don't get treated as a full reset.
  POST_RESET_BACK_ONE_STEP_TOKENS = %w[0 regresar volver atras atrás back].freeze
  # "Home / full reset" — always returns to PHASE_PICKING_SOURCE +
  # reset_ack_message. WORD-ONLY by design: any digit token here would
  # collide with a list-pick (paginated lists can carry up to PAGE_SIZE=20
  # rows). The picker renders the typed-word shortcut (e.g. "inicio")
  # instead of a numeric one for the same reason.
  POST_RESET_HOME_TOKENS = %w[inicio start home reset nuevo nueva new menu].freeze
  # Union — used in PHASE_PICKING_SOURCE where "back" and "home" are the same
  # action (re-render the source picker prompt).
  POST_RESET_BACK_TOKENS = (POST_RESET_HOME_TOKENS + POST_RESET_BACK_ONE_STEP_TOKENS).uniq.freeze
  # Page navigation inside PHASE_PICKING_FROM_LIST. Single-char `+`/`-`
  # tokens are the canonical UX (1 keystroke with gloves); the word aliases
  # exist so a verbose technician isn't punished. `mas` covers "más" because
  # WhatsappFollowupClassifier.normalize strips accents before matching.
  POST_RESET_NEXT_PAGE_TOKENS = %w[+ mas siguiente next].freeze
  POST_RESET_PREV_PAGE_TOKENS = %w[- prev anterior previous].freeze

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

    page_obj = Rag::WhatsappDocumentPicker.list(source: source, conv_session: conv_session, page: 1)
    msg      = Rag::WhatsappDocumentPicker.render(
      page: page_obj, source: source, locale: locale,
      origin: Rag::WhatsappPostResetState::ORIGIN_RESET_PICKER
    )

    if page_obj.items.empty?
      Rails.logger.info("[WA_POST_RESET] to=#{to} op=empty_list source=#{source}")
    else
      Rag::WhatsappPostResetState.write(
        to,
        phase:   Rag::WhatsappPostResetState::PHASE_PICKING_FROM_LIST,
        source:  source,
        doc_ids: page_obj.items.map(&:id),
        origin:  Rag::WhatsappPostResetState::ORIGIN_RESET_PICKER,
        page:    page_obj.page
      )
    end

    deliver_whatsapp(msg, to: to, from: from)
    conv_session&.add_to_history("assistant", msg.to_s.truncate(500))
    true
  end

  def handle_post_reset_pick_doc(norm:, state:, to:, from:, locale:, conv_session:)
    # Page navigation (`+`/`-` and aliases) re-renders the neighbour page in
    # the same picker phase. Checked BEFORE back/home so a stray `+` never
    # collapses the picker. No-op (re-render same page) at the boundaries
    # so the technician's misstep is harmless.
    if POST_RESET_NEXT_PAGE_TOKENS.include?(norm) || POST_RESET_PREV_PAGE_TOKENS.include?(norm)
      direction = POST_RESET_NEXT_PAGE_TOKENS.include?(norm) ? :next : :prev
      return handle_post_reset_page_nav(
        direction: direction, state: state, to: to, from: from,
        locale: locale, conv_session: conv_session
      )
    end

    # "Back one step": when we got here from a live faceted answer, restore
    # it; otherwise behave like the legacy back-to-source-picker.
    if POST_RESET_BACK_ONE_STEP_TOKENS.include?(norm)
      return true if try_back_to_cached_answer(to: to, from: from, locale: locale, conv_session: conv_session, state: state)

      Rag::WhatsappPostResetState.write(
        to,
        phase:  Rag::WhatsappPostResetState::PHASE_PICKING_SOURCE,
        origin: Rag::WhatsappPostResetState::ORIGIN_RESET_PICKER
      )
      msg = reset_ack_message(locale: locale)
      deliver_whatsapp(msg, to: to, from: from)
      conv_session&.add_to_history("assistant", msg)
      return true
    end

    if POST_RESET_HOME_TOKENS.include?(norm)
      Rag::WhatsappAnswerCache.invalidate(to)
      Rag::WhatsappPostResetState.write(
        to,
        phase:  Rag::WhatsappPostResetState::PHASE_PICKING_SOURCE,
        origin: Rag::WhatsappPostResetState::ORIGIN_RESET_PICKER
      )
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

    source       = Rag::WhatsappPostResetState.source_of(state) || :recent
    picked_doc   = Rag::WhatsappDocumentPicker.fetch(source: source, id: doc_ids[idx])
    seed         = Rag::WhatsappDocumentPicker.seed_query(source: source, id: doc_ids[idx], locale: locale)
    if picked_doc.nil? || seed.blank?
      Rails.logger.warn("[WA_POST_RESET] to=#{to} op=seed_miss idx=#{idx} id=#{doc_ids[idx]} source=#{source}")
      Rag::WhatsappPostResetState.clear(to)
      return false
    end

    Rag::WhatsappPostResetState.clear(to)

    # Bind the seeded query to the picked document BEFORE running RAG:
    #   1. seed it into active_entities so SessionContextBuilder emits a
    #      "Session Focus" block telling Haiku exactly which file to use.
    #   2. compute its S3 URI and pass it as entity_s3_uris_override +
    #      force_entity_filter so retrieval is strictly scoped to that doc
    #      (the seed query "Describe <Long Name>" otherwise trips
    #      query_names_different_document? and disables the filter).
    picked_uri = picked_doc_s3_uri(picked_doc)
    seed_picked_entity!(conv_session, picked_doc, picked_uri)
    Rails.logger.info(
      "[WA_POST_RESET] to=#{to} op=pick_doc source=#{source} id=#{doc_ids[idx]} " \
      "uri=#{picked_uri ? 'set' : 'missing'}"
    )

    deliver_processing_ack(to: to, from: from, locale: locale) if processing_ack_enabled?
    reply, history_entry = run_rag_and_cache(
      body:                    seed,
      to:                      to,
      conv_session:            conv_session,
      entity_s3_uris_override: picked_uri ? [ picked_uri ] : nil,
      force_entity_filter:     picked_uri.present?
    )
    deliver_whatsapp(reply, to: to, from: from)
    conv_session&.add_to_history("assistant", history_entry || reply.to_s.truncate(500))
    true
  end

  # Re-renders the neighbour page in PHASE_PICKING_FROM_LIST and overwrites
  # the persisted page + doc_ids. Bounded by [1..total_pages] — a `+` on the
  # last page (or `-` on page 1) re-renders the same page so the technician
  # never gets a confusing "no-op" silence. Always returns true so the
  # caller treats the message as absorbed.
  def handle_post_reset_page_nav(direction:, state:, to:, from:, locale:, conv_session:)
    source        = Rag::WhatsappPostResetState.source_of(state) || :all
    current_page  = Rag::WhatsappPostResetState.page_of(state)
    requested     = direction == :next ? current_page + 1 : current_page - 1
    page_obj      = Rag::WhatsappDocumentPicker.list(
      source: source, conv_session: conv_session, page: requested
    )
    msg = Rag::WhatsappDocumentPicker.render(
      page: page_obj, source: source, locale: locale,
      origin: Rag::WhatsappPostResetState.origin_of(state)
    )

    if page_obj.items.any?
      Rag::WhatsappPostResetState.write(
        to,
        phase:   Rag::WhatsappPostResetState::PHASE_PICKING_FROM_LIST,
        source:  source,
        doc_ids: page_obj.items.map(&:id),
        origin:  Rag::WhatsappPostResetState.origin_of(state),
        page:    page_obj.page
      )
      Rails.logger.info(
        "[WA_POST_RESET] to=#{to} op=page_nav direction=#{direction} " \
        "from=#{current_page} to=#{page_obj.page}/#{page_obj.total_pages}"
      )
    else
      Rails.logger.info("[WA_POST_RESET] to=#{to} op=page_nav direction=#{direction} empty=true")
    end

    deliver_whatsapp(msg, to: to, from: from)
    conv_session&.add_to_history("assistant", msg.to_s.truncate(500))
    true
  end

  # Resolves the canonical S3 URI of a doc selected from the post-reset picker.
  # KbDocument rows are catalog-only and need a bucket; TechnicianDocument carries
  # source_uri inline. Returns nil when no URI can be derived (caller falls back
  # to the unfiltered RAG path).
  def picked_doc_s3_uri(picked_doc)
    case picked_doc
    when KbDocument
      bucket = ENV.fetch("KNOWLEDGE_BASE_S3_BUCKET", "multimodal-source-destination")
      picked_doc.display_s3_uri(bucket)
    when TechnicianDocument
      picked_doc.source_uri.presence
    end
  end

  # Adds the picked document to the session working set so:
  #   * SessionContextBuilder.build emits a "Session Focus" block (Haiku knows
  #     which file the answer is about).
  #   * SessionContextBuilder.entity_s3_uris later picks it up for free-text
  #     follow-ups in the same session (the "(fuente)" continuity contract).
  # Tolerant: any failure is logged + swallowed because the immediate call
  # already passes the URI via entity_s3_uris_override.
  def seed_picked_entity!(conv_session, picked_doc, picked_uri)
    return unless conv_session && picked_doc

    canonical, aliases =
      case picked_doc
      when KbDocument
        [ picked_doc.display_name.presence || picked_doc.stem_from_s3_key, Array(picked_doc.aliases) ]
      when TechnicianDocument
        [ picked_doc.canonical_name, Array(picked_doc.aliases) ]
      else
        [ nil, [] ]
      end
    return if canonical.blank?

    metadata = {
      "source"     => "wa_post_reset_pick",
      "source_uri" => picked_uri,
      "doc_type"   => picked_doc.respond_to?(:doc_type) ? picked_doc.doc_type : nil
    }.compact

    conv_session.add_entity_with_aliases(canonical, aliases, metadata)
  rescue StandardError => e
    Rails.logger.warn("[WA_POST_RESET] seed_picked_entity failed: #{e.class} #{e.message}")
  end

  # Restores the cached faceted answer when "0/back" is tapped from a list
  # the user opened via __list_recent__ / __list_all__ (origin
  # :faceted_cached) AND the cache is still alive. Returns false otherwise so
  # the caller can fall back to the legacy back-to-source-picker behavior.
  def try_back_to_cached_answer(to:, from:, locale:, conv_session:, state:)
    return false unless Rag::WhatsappPostResetState.origin_of(state) ==
                        Rag::WhatsappPostResetState::ORIGIN_FACETED_CACHED

    cached = Rag::WhatsappAnswerCache.read(to, conv_session: conv_session)
    return false if cached.blank?

    structured = Rag::FacetedAnswer.from_cache(cached[:structured])
    return false if structured.nil? || structured.legacy?

    msg = structured.to_whatsapp_first_message(locale: cached[:locale] || locale)
    return false if msg.to_s.strip.empty?

    Rag::WhatsappPostResetState.clear(to)
    Rails.logger.info("[WA_POST_RESET] to=#{to} op=back_to_cached_answer")
    deliver_whatsapp(msg, to: to, from: from)
    conv_session&.add_to_history("assistant", msg.to_s.truncate(500))
    true
  end
end
