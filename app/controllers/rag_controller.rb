# frozen_string_literal: true

# app/controllers/rag_controller.rb

class RagController < ApplicationController
  include AuthenticationConcern
  include RagQueryConcern

  def ask
    images    = extract_images_from_params
    documents = extract_documents_from_params
    question  = params[:question].to_s.strip

    # In shared-session mode, omit user_id to avoid storing "last web user" as owner of the shared row.
    effective_user_id = SharedSession::ENABLED ? nil : current_user.id
    conv_session = ConversationSession.find_or_create_for(
      identifier: current_user.id.to_s,
      channel:    "web",
      user_id:    effective_user_id
    )
    if question.present?
      # Single UPDATE instead of refresh! + add_to_history (2 UPDATEs).
      conv_session.add_to_history_and_refresh("user", question)
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
      entity_s3_uris:  entity_s3_uris
    )

    unless result.success?
      render_rag_json_error(result)
      return
    end

    if result[:doc_refs].present?
      KbDocumentEnrichmentJob.perform_later(
        doc_refs:       result[:doc_refs],
        retrieved_meta: minimal_retrieved_for_enrichment(Array(result.retrieved_citations))
      )
    end

    conv_session.add_to_history("assistant", result.answer.to_s)

    json = {
      answer:     result.answer,
      citations:  Array(result.citations),
      session_id: result.session_id,
      status:     'success'
    }
    json[:documents_uploaded] = result.documents_uploaded if result.documents_uploaded.present?
    json[:images_uploaded]    = result.images_uploaded    if result.images_uploaded.present?
    render json: json
  rescue ImageCompressionService::CompressionError
    render json: { status: 'error', message: I18n.t('rag.image_compression_failed') }, status: :bad_request
  end

  private

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
      result = ImageCompressionService.compress_with_thumbnail(img[:data], img[:media_type])
      {
        data:              result[:data],
        media_type:        result[:media_type],
        binary:            result[:binary],
        filename:          img[:filename].presence || img['filename'].presence,
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
