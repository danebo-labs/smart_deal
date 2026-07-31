# frozen_string_literal: true

# app/controllers/rag_controller.rb

class RagController < ApplicationController
  include AuthenticationConcern
  include RagQueryConcern

  def ask
    images    = extract_images_from_params
    documents = extract_documents_from_params
    question  = params[:question].to_s.strip
    correlation_id = "photo:#{SecureRandom.uuid}" if images.any?

    # In shared-session mode, omit user_id to avoid storing "last web user" as owner of the shared row.
    effective_user_id = SharedSession::ENABLED ? nil : current_user.id
    conv_session = ConversationSession.find_or_create_for(
      identifier:  current_user.id.to_s,
      channel:     "web",
      user_id:     effective_user_id,
      account_id:  current_account.id
    )
    if question.present?
      # Single UPDATE instead of refresh! + add_to_history (2 UPDATEs).
      conv_session.add_to_history_and_refresh(
        "user",
        question,
        user_id: current_user.id,
        correlation_id: correlation_id
      )
    else
      conv_session.refresh!
    end

    session_context  = SessionContextBuilder.build(conv_session)
    entity_s3_uris   = SessionContextBuilder.entity_s3_uris(conv_session)

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
      field_photo_id:  params[:field_photo_id].presence
    )

    unless result.success?
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

    if result.images_uploaded.blank?
      conv_session.add_to_history(
        "assistant",
        result.answer.to_s,
        user_id: current_user.id,
        correlation_id: result.correlation_id
      )
    end

    raw_citations   = citation_processor.transport_references(result.citations)
    sources_visible = Rag::SourcesVisibility.enabled?
    marker_free_answer = citation_processor.strip_resolved_markers(result.answer, raw_citations)
    answer_text = sources_visible ? result.answer : marker_free_answer
    resolution = build_resolution(
      question: question,
      answer: marker_free_answer,
      result: result,
      conv_session: conv_session,
      entity_s3_uris: entity_s3_uris,
      sources_visible: sources_visible
    )

    json = {
      answer:     answer_text,
      citations:  sources_visible ? raw_citations : [],
      session_id: result.session_id,
      status:     'success',
      resolution: resolution
    }
    json[:documents_uploaded] = result.documents_uploaded if result.documents_uploaded.present?
    json[:images_uploaded]    = result.images_uploaded    if result.images_uploaded.present?
    json[:correlation_id]     = result.correlation_id     if result.correlation_id.present?
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
    render json: { status: 'error', message: I18n.t('rag.image_compression_failed') }, status: :bad_request
  end

  private

  def citation_processor
    @citation_processor ||= Bedrock::CitationProcessor.new
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
