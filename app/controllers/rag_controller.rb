# frozen_string_literal: true

# app/controllers/rag_controller.rb

class RagController < ApplicationController
  include AuthenticationConcern
  include RagQueryConcern

  def ask
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    # Previous request on this Puma thread can leave semantic state behind.
    # Reset before image compression or any other path that emits TurnEvidence.
    Thread.current[:haiku_semantic_analysis_ms] = nil
    Rag::SemanticQueryAnalyzer.clear_observation!
    question  = params[:question].to_s.strip
    question_sha256 = question.present? ? Digest::SHA256.hexdigest(question) : nil
    # Coined before extraction so an interaction that fails during image
    # compression (i.e. before Bedrock is ever reached) still carries an id —
    # H3/Fase 1. Corrected to the query: scheme once we know images is empty.
    correlation_id = "photo:#{SecureRandom.uuid}"
    images    = extract_images_from_params
    correlation_id = "query:#{SecureRandom.uuid}" if images.empty?
    documents = extract_documents_from_params

    # In shared-session mode, omit user_id to avoid storing "last web user" as owner of the shared row.
    effective_user_id = SharedSession::ENABLED ? nil : current_user.id
    conv_session = ConversationSession.find_or_create_for(
      identifier:  current_user.id.to_s,
      channel:     "web",
      user_id:     effective_user_id,
      account_id:  current_account.id
    )
    if params[:replay_correlation_id].present?
      replay_focused_question(started_at, conv_session)
      return
    end
    episode_turn = nil
    expected_episode_id = nil
    semantic_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    shadow_analysis = observe_semantic_shadow(question, images, documents, conv_session, correlation_id)
    semantic_analysis_ms = elapsed_ms(semantic_started)
    state_ms = 0
    if question.present?
      # Single UPDATE instead of refresh! + add_to_history (2 UPDATEs).
      state_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      episode_turn = conv_session.record_user_turn!(
        question,
        user_id: current_user.id,
        correlation_id: correlation_id,
        locale: resolve_response_locale(question, conv_session),
        selection_turn: selection_turn?(question, conv_session) ||
          Rag::ThreadMenuSelection.call(question: question, conversation_history: conv_session.conversation_history)
      )
      expected_episode_id = conv_session.live_episode_id
      state_ms = elapsed_ms(state_started)
    else
      conv_session.refresh!
      expected_episode_id = conv_session.live_episode_id
    end
    haiku_ms = Thread.current[:haiku_semantic_analysis_ms]
    unless haiku_ms.nil?
      semantic_analysis_ms = haiku_ms
      state_ms = [ state_ms - haiku_ms, 0 ].max if Rag::HaikuQueryAnalysisFlag.conditional?
    end

    session_context  = SessionContextBuilder.build(conv_session)
    entity_s3_uris   = locked_focus_uris(episode_turn) || SessionContextBuilder.entity_s3_uris(conv_session)

    result = execute_rag_query(
      question,
      images:          images,
      documents:       documents,
      session_id:      params[:session_id].presence,
      session_context: session_context,
      conv_session:    conv_session,
      entity_s3_uris:  entity_s3_uris,
      account:         current_account,
      user_id:         current_user.id,
      correlation_id:  correlation_id,
      field_photo_id:  params[:field_photo_id].presence,
      episode_turn:    episode_turn,
      conversational_turn_analysis: shadow_analysis
    )

    unless result.success?
      emit_interaction_completed(
        correlation_id:  correlation_id,
        conv_session:    conv_session,
        question_sha256: question_sha256,
        outcome:         "failed",
        stage:           result.error_type.to_s,
        error_class:     result.error_class,
        route:           interaction_route(correlation_id),
        latency_ms:      elapsed_ms(started_at),
        phase_ms:        phase_ms(result, semantic_analysis_ms, state_ms, started_at),
        original_query:  question,
        effective_query: result.effective_question || question,
        answer:          result.answer
      )
      render_rag_json_error(result)
      return
    end

    if result[:doc_refs].present?
      KbDocumentEnrichmentJob.perform_later(
        doc_refs:       result[:doc_refs],
        retrieved_meta: minimal_retrieved_for_enrichment(Array(result.retrieved_citations)),
        account_id:     current_account.id
      )
    end

    raw_citations   = citation_processor.transport_references(result.citations)
    sources_visible = Rag::SourcesVisibility.enabled?
    # Classify while [n] still resolves against this turn's citations. The
    # segments travel even when the browser receives citations: [].
    provenance_segments = provenance_segments_for(result, raw_citations)
    marker_free_answer = citation_processor.strip_resolved_markers(result.answer, raw_citations)
    answer_text = sources_visible ? result.answer : marker_free_answer

    if result.images_uploaded.blank?
      conv_session.stamp_user_retrieval_query!(correlation_id, result.effective_question || question)
      conv_session.record_assistant_turn!(
        result.answer.to_s,
        user_id: current_user.id,
        correlation_id: result.correlation_id,
        pending_question: result.pending_question,
        expected_episode_id: expected_episode_id,
        focus_ids: conv_session.focus_document_ids
      )
      # The photo route's images_uploaded branch terminates asynchronously in
      # FieldPhotoAnalysisJob (which emits its own interaction_completed) — the
      # controller never observes that outcome, so it must not double-emit here.
      emit_interaction_completed(
        correlation_id:  correlation_id,
        conv_session:    conv_session,
        question_sha256: question_sha256,
        outcome:         interaction_outcome(result),
        route:           interaction_route(correlation_id),
        latency_ms:      elapsed_ms(started_at),
        phase_ms:        phase_ms(result, semantic_analysis_ms, state_ms, started_at),
        original_query:  question,
        effective_query: result.effective_question || question,
        answer:          answer_text,
        citations:       result.retrieved_citations
      )
    end

    resolution = build_resolution(
      question: question,
      answer: marker_free_answer,
      result: result,
      conv_session: conv_session,
      entity_s3_uris: entity_s3_uris,
      sources_visible: sources_visible
    )

    json = {
      answer:         answer_text,
      citations:      sources_visible ? raw_citations : [],
      session_id:     result.session_id,
      status:         'success',
      resolution:     resolution,
      response_locale: result.response_locale
    }
    json[:provenance_segments] = provenance_segments
    json[:documents_uploaded] = result.documents_uploaded if result.documents_uploaded.present?
    json[:images_uploaded]    = result.images_uploaded    if result.images_uploaded.present?
    json[:correlation_id]     = result.correlation_id     if result.correlation_id.present?
    attach_manual_suggestion(json, question, correlation_id, conv_session, result)
    json[:quick_replies]      = result.quick_replies      if result.quick_replies.present?
    if json[:quick_replies].blank? && resolution[:needs_selection]
      json[:quick_replies] = resolution[:evidence_cards].first(3).filter_map do |card|
        next if card[:select_query].blank?

        { label: card[:label], query: card[:select_query] }
      end
    end
    # V8: the document overview path already names each document as a
    # "Documento: ..." heading inside the answer itself — showing the same
    # names again in "Documentos consultados" would duplicate attribution.
    if raw_citations.empty? && result.generation_mode != "deterministic_document_overview"
      fallback_names = consulted_documents_fallback(result.doc_refs)
      json[:consulted_documents] = fallback_names if fallback_names.present?
    end
    render json: json
  rescue ImageCompressionService::CompressionError
    emit_interaction_completed(
      correlation_id:  correlation_id,
      question_sha256: question_sha256,
      outcome:         "failed",
      stage:           "image_compression",
      error_class:     ImageCompressionService::CompressionError.name,
      route:           interaction_route(correlation_id),
      latency_ms:      elapsed_ms(started_at),
      original_query:  question,
      effective_query: question
    )
    render json: { status: 'error', message: I18n.t('rag.image_compression_failed') }, status: :bad_request
  end

  private

  # Focus ids captured under the episode lock. A later reread can see a
  # different selection than the one RoutePolicy used.
  def locked_focus_uris(episode_turn)
    understanding = episode_turn.respond_to?(:understanding) ? episode_turn.understanding : nil
    return nil unless understanding.respond_to?(:focus_uris)
    return nil if understanding.focus_uris.nil?

    understanding.focus_uris
  end

  # The technician already asked this. The stored retrieval string is reused.
  # The episode is not reinterpreted and Haiku is not called.
  def replay_focused_question(started_at, conv_session)
    replay_id = params[:replay_correlation_id].to_s
    turn = conv_session.user_message_for(replay_id)
    unless turn
      render json: { status: "error", message: I18n.t("rag.manual_replay_failed") }, status: :unprocessable_entity
      return
    end

    focus_ids = conv_session.focus_document_ids
    cached = conv_session.assistant_for_focus(replay_id, focus_ids)
    if cached
      render json: {
        status: "success",
        reused: true,
        replayed: true,
        answer: cached["content"],
        citations: [],
        correlation_id: replay_id,
        message: I18n.t("rag.manual_replay_reused")
      }
      return
    end

    question = turn["content"].to_s
    retrieval_question = turn["retrieval_query"].presence || question
    result = execute_rag_query(
      question,
      session_context: SessionContextBuilder.build(conv_session),
      conv_session: conv_session,
      entity_s3_uris: SessionContextBuilder.entity_s3_uris(conv_session),
      account: current_account,
      user_id: current_user.id,
      correlation_id: replay_id,
      retrieval_question: retrieval_question
    )
    unless result.success?
      render json: { status: "error", message: I18n.t("rag.manual_replay_failed") }, status: :unprocessable_entity
      return
    end

    conv_session.record_assistant_turn!(
      result.answer.to_s,
      user_id: current_user.id,
      correlation_id: replay_id,
      pending_question: result.pending_question,
      expected_episode_id: conv_session.live_episode_id,
      focus_ids: focus_ids
    )
    raw_citations = citation_processor.transport_references(result.citations)
    sources_visible = Rag::SourcesVisibility.enabled?
    marker_free_answer = citation_processor.strip_resolved_markers(result.answer, raw_citations)
    answer_text = sources_visible ? result.answer : marker_free_answer
    json = {
      answer: answer_text,
      citations: sources_visible ? raw_citations : [],
      session_id: result.session_id,
      status: "success",
      replayed: true,
      reused: false,
      correlation_id: replay_id,
      response_locale: result.response_locale
    }
    attach_manual_suggestion(json, question, replay_id, conv_session, result)
    emit_interaction_completed(
      correlation_id: replay_id,
      conv_session: conv_session,
      question_sha256: Digest::SHA256.hexdigest(question),
      outcome: interaction_outcome(result),
      route: "text",
      latency_ms: elapsed_ms(started_at),
      original_query: question,
      effective_query: result.effective_question || retrieval_question,
      answer: answer_text,
      citations: result.retrieved_citations
    )
    render json: json
  end

  # Single point of emission for the terminal state of a text/photo-submission
  # interaction (restriction 1). The async photo route's actual completion is
  # observed and emitted by FieldPhotoAnalysisJob instead — see the two call
  # sites above.
  def emit_interaction_completed(correlation_id:, question_sha256:, outcome:, route:, latency_ms:,
                                 stage: nil, error_class: nil, conv_session: nil, phase_ms: {},
                                 original_query: nil, effective_query: nil, answer: nil, citations: nil)
    PilotUsageLog.log(
      "interaction_completed",
      correlation_id: correlation_id,
      user_id: current_user&.id,
      account_id: current_account&.id,
      conversation_session_id: (conv_session.id if conv_session.respond_to?(:id)),
      question_sha256: question_sha256,
      outcome: outcome,
      stage: stage,
      error_class: error_class,
      route: route,
      latency_ms: latency_ms,
      **phase_ms
    )
    chunk_ids, sources = Rag::TurnEvidence.evidence_from(citations)
    Rag::TurnEvidence.log(
      correlation_id: correlation_id,
      route: route,
      outcome: outcome,
      original_query: original_query,
      effective_query: effective_query.nil? ? original_query : effective_query,
      answer: answer,
      semantic: Rag::SemanticQueryAnalyzer.current_observation,
      chunk_ids: chunk_ids,
      sources: sources
    )
  end

  def phase_ms(result, semantic_analysis_ms, state_ms, started_at)
    {
      semantic_analysis_ms: semantic_analysis_ms,
      state_ms: state_ms,
      retrieve_ms: result&.retrieve_ms,
      generation_ms: result&.generation_ms,
      rag_ms: result&.rag_ms,
      total_ms: elapsed_ms(started_at)
    }.compact
  end

  def interaction_route(correlation_id)
    correlation_id.to_s.start_with?("photo:") ? "photo" : "text"
  end

  def elapsed_ms(started_at)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
  end

  # Prefers the route's own structural outcome (currently only
  # Rag::StructuredEvidenceRoute sets result.route_outcome) over the text
  # heuristic below. ABSTENTION_PATTERN matches per-field uncertainty markers
  # (e.g. "El documento no incluye este dato" about one cited terminal) that a
  # fully-answered, fully-cited response can legitimately contain — routes
  # without a structural signal keep the old heuristic rather than block on a
  # broader rewrite.
  def interaction_outcome(result)
    return result.route_outcome.to_s if result.route_outcome.present?

    abstained_answer?(result.answer) ? "abstained" : "answered"
  end

  # Reuses the abstention pattern already established for evidence-selection
  # telemetry (restriction 2) — no new regex.
  def abstained_answer?(answer)
    answer.to_s.match?(Rag::EvidenceSelectionTelemetry::ABSTENTION_PATTERN)
  end

  # Suggest-only. The ranker does not retrieve and does not write active_entities.
  # Eligibility is the physical KbDocument through Rag::KnowledgeScopePolicy.
  # A catalog classification is not an approval. A card tap is a later request.
  def attach_manual_suggestion(json, question, correlation_id, conv_session, result)
    return if question.blank? || current_account.nil?
    return if result&.generation_mode.to_s == "clarify_first"

    understanding = result.respond_to?(:turn_understanding) ? result.turn_understanding : nil
    discovery = Rag::DocumentDiscovery.call(
      question: question,
      viewer_account: current_account,
      session: conv_session,
      doc_refs: result&.doc_refs,
      abstained: result.present? && interaction_outcome(result) == "abstained",
      discovery_query: understanding&.retrieval_query.presence || result&.effective_question.presence || question,
      allow_outside: understanding.nil? || understanding.outside_discovery,
      retriever: lambda { |text, top_k|
        BedrockRagService.new(account: current_account).retrieve_chunks(
          text,
          number_of_results: top_k,
          account_id: current_account.id,
          correlation_id: correlation_id,
          route_taken: "document_discovery"
        )
      }
    )
    payload = discovery.payload
    if payload
      mark_focused_cards!(payload, conv_session)
      payload[:correlation_id] = correlation_id
      payload[:focus_action] ||= I18n.t("rag.manual_focus_action")
      payload[:focus_clear] = I18n.t("rag.manual_focus_clear")
      payload[:focus_status] = I18n.t("rag.manual_focus_confirmed")
      payload[:focus_invalid] = I18n.t("rag.manual_focus_invalid")
      payload[:replay_failed] = I18n.t("rag.manual_replay_failed")
      payload[:replay_reused] = I18n.t("rag.manual_replay_reused")
      json[:manual_suggestion] = payload
      PilotUsageLog.log(
        "manual_suggestion_shown",
        account_id: current_account.id,
        user_id: current_user&.id,
        conversation_session_id: (conv_session.id if conv_session.respond_to?(:id)),
        correlation_id: correlation_id,
        suggestion_document_uids: payload[:cards].pluck(:document_uid),
        suggestion_scopes: payload[:cards].pluck(:knowledge_scope)
      )
    end
    attach_focus_notices(json, conv_session, discovery, correlation_id)
  end

  def mark_focused_cards!(payload, conv_session)
    ids = focused_kb_document_ids(conv_session)
    payload[:cards].each do |card|
      card[:focused] = ids.include?(card[:kb_document_id].to_i)
    end
  end

  def focused_kb_document_ids(conv_session)
    return [] unless conv_session.respond_to?(:document_focus_entries)
    return [] if conv_session.respond_to?(:uses_document_focus?) && !conv_session.uses_document_focus?

    conv_session.document_focus_entries.map { |entry| entry["kb_document_id"].to_i }
  end

  def attach_focus_notices(json, conv_session, discovery, correlation_id)
    suggestion = Struct.new(:manufacturer, :model_tokens).new(discovery.manufacturer, [])
    pin = Rag::FocusNotice.pin_conflict(session: conv_session, suggestion: suggestion)
    if pin
      json[:pin_conflict] = { message: pin.message }
      PilotUsageLog.log(
        "equipment_switch_prompted",
        account_id: current_account.id,
        user_id: current_user&.id,
        conversation_session_id: (conv_session.id if conv_session.respond_to?(:id)),
        correlation_id: correlation_id,
        manufacturer: pin.manufacturer,
        outcome_reason: "pin_conflict"
      )
    end

    identity = Rag::FocusNotice.identity_conflict(session: conv_session)
    json[:identity_conflict] = { message: identity.message } if identity
  end

  def citation_processor
    @citation_processor ||= Bedrock::CitationProcessor.new
  end

  def provenance_segments_for(result, citations)
    Rag::ProvenanceSegmenter.call(
      answer: result.answer,
      citations: citations,
      visual_observation: turn_visual_observation(result)
    )
  end

  # The ack that only says the photo is being read is not this turn's answer.
  # A valid observation on an owned photo is classified later, from the column,
  # when PhotoQuestionAnswerService builds the answer. active_photo is not read.
  def turn_visual_observation(result)
    return nil if result.images_uploaded.present?
    return nil if current_account.nil?

    photo_id = params[:field_photo_id].presence
    return nil if photo_id.blank?

    photo = FieldPhoto.where(account_id: current_account.id).find_by(id: photo_id)
    photo&.visual_observation
  end

  # docs/RAG_RESOLUTION_MODE_CONTRACT_FASE3_2026-07-29.md §2.1/§2.3.
  # run_evidence_selector_shadow below runs the selector for measurement only
  # behind its own feature flag. Evidence cards have a second flag: with
  # selector=true/cards=false the run remains invisible; enabling both exposes
  # the selector's contract without replacing the technical answer.
  def build_resolution(question:, answer:, result:, conv_session:, entity_s3_uris:, sources_visible:)
    shadow =
      unless result.generation_mode == Rag::StructuredEvidenceRoute::GENERATION_MODE
        run_evidence_selector_shadow(question: question, entity_s3_uris: entity_s3_uris)
      end
    if shadow
      selection = shadow.fetch(:selection)
      Rag::EvidenceSelectionTelemetry.log(
        selection: selection,
        question: question,
        answer: answer,
        generation_mode: result.generation_mode || "generative",
        account_id: current_account.id,
        user_id: current_user.id,
        conversation_session_id: conv_session.id,
        correlation_id: result.correlation_id,
        sources_visible: sources_visible
      )
      if Rag::EvidenceCardsFlag.enabled?
        return Rag::ResolutionPresenter.new(
          selection: selection,
          analysis: shadow.fetch(:analysis),
          question: question,
          sources_visible: sources_visible
        ).call
      end
    end
    Rag::ResolutionPresenter.not_applicable
  end

  # Shadow-mode measurement (docs/RAG_PRECISION_V2_PLAN_2026-07-29.md §7 "selector
  # de evidencia" flag, docs/RAG_EVIDENCE_SELECTOR_FASE1_DESIGN_2026-07-29.md §10
  # "selector en sombra comparando contra el camino actual"). Off by default —
  # AGENTS.md's "avoid repeated retrieval calls within the same user turn" is
  # deliberately relaxed only while this flag is explicitly turned on for the
  # target account's shadow benchmark; it never substitutes the live answer or
  # changes `resolution.mode`. Any failure here must never break the response.
  def run_evidence_selector_shadow(question:, entity_s3_uris:)
    return if question.blank? || !Rag::EvidenceSelectorFlag.enabled?

    analysis = Rag::QueryEntities.analyze(question)
    retrieval = BedrockRagService.new(account: current_account).retrieve_chunks(
      question,
      entity_s3_uris: entity_s3_uris,
      number_of_results: Rag::EvidenceCandidateSelector::DISCOVERY_RESULTS,
      account_id: current_account.id
    )
    expander = Rag::SectionNeighborExpander.new if Rag::EvidenceExpansionFlag.enabled?
    selection = Rag::EvidenceCandidateSelector.new(
      analysis: analysis,
      chunks: retrieval[:chunks],
      expander: expander
    ).select

    Rails.logger.info(
      "[EVIDENCE_SELECTOR_SHADOW] account_id=#{current_account.id} " \
      "selector_version=#{selection.selector_version} mode=#{selection.mode} " \
      "contexts=#{selection.contexts.size} answered=#{selection.answered_relations.to_a} " \
      "abstained=#{selection.abstained_relations.to_a} rejections=#{selection.rejections.size} " \
      "expansions=#{selection.expansions.size}"
    )
    { analysis: analysis, selection: selection }
  rescue StandardError => e
    Rails.logger.warn("Rag::EvidenceCandidateSelector shadow run failed: #{e.message}")
    nil
  end

  def observe_semantic_shadow(question, images, documents, conv_session, correlation_id)
    return nil if question.blank? || images.present? || documents.present?

    Rag::SemanticQueryAnalyzer.observe(
      turn: question,
      episode: conv_session.active_episode,
      correlation_id: correlation_id,
      attribution: {
        account_id: current_account&.id,
        user_id: current_user&.id,
        conversation_session_id: conv_session&.id
      }
    )
  end

  def extract_images_from_params
    image_param = params[:image]
    return [] if image_param.blank?

    images = if image_param.is_a?(Array)
      image_param.select { |img| img[:data].present? && img[:media_type].present? }
    elsif image_param[:data].present? && image_param[:media_type].present?
      [ image_param.to_unsafe_h ]
    else
      []
    end

    compress_images(images)
  rescue ImageCompressionService::CompressionError => e
    Rails.logger.error("RagController: Image compression failed: #{e.message}")
    raise
  rescue StandardError => e
    Rails.logger.error("RagController: Failed to extract/compress images: #{e.message}")
    []
  end

  def compress_images(images)
    images.map do |img|
      fname  = img[:filename].presence || img["filename"].presence
      result = ImageCompressionService.compress_with_thumbnail(img[:data], img[:media_type], filename: fname)
      {
        data:                   result[:data],
        media_type:             result[:media_type],
        binary:                 result[:binary],
        filename:               fname,
        thumbnail_binary:       result[:thumbnail_binary],
        thumbnail_content_type: result[:thumbnail_content_type],
        thumbnail_width:        result[:thumbnail_width],
        thumbnail_height:       result[:thumbnail_height]
      }
    end
  rescue ImageCompressionService::CompressionError => e
    Rails.logger.error("RagController: Image compression failed: #{e.message}")
    raise
  end

  def extract_documents_from_params
    doc_param = params[:document]
    return [] if doc_param.blank?

    docs = doc_param.is_a?(Array) ? doc_param : [ doc_param ]
    docs.select do |d|
      d[:data].present? && (d[:media_type].present? || d[:filename].present?)
    end.map { |d| d.to_unsafe_h.symbolize_keys }
  rescue StandardError
    []
  end

  # Fallback for the UI's "Documentos consultados" block when Haiku emitted
  # <DOC_REFS> but no inline [n] citations (so no numbered references exist).
  # Names only — no extra queries, doc_refs are already in memory.
  def consulted_documents_fallback(doc_refs)
    Array(doc_refs)
      .filter_map { |ref| (ref["canonical_name"] || ref[:canonical_name]).presence }
      .uniq
      .first(5)
  end

  # Strip chunk :content from citations before sending to the enrichment job.
  # KbDocumentEnrichmentService only reads metadata + location.uri; the chunk
  # text is the heaviest part of the citation (~10–50 KB each) and serializing
  # it into solid_queue_jobs.arguments wastes DB space and Cable payload size.
  def minimal_retrieved_for_enrichment(citations)
    Array(citations).map do |c|
      {
        metadata: c[:metadata] || c["metadata"] || {},
        location: c[:location] || c["location"]
      }
    end
  end
end
