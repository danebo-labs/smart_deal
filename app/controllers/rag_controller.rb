# frozen_string_literal: true

# app/controllers/rag_controller.rb

class RagController < ApplicationController
  include AuthenticationConcern
  include RagQueryConcern

  def ask
    images = extract_images_from_params
    documents = extract_documents_from_params

    model_id = resolve_model_id(params[:model])
    result = execute_rag_query(params[:question], images: images, documents: documents, model_id: model_id)

    unless result.success?
      render_rag_json_error(result)
      return
    end

    json = {
      answer: result.answer,
      citations: result.citations,
      session_id: result.session_id,
      status: 'success'
    }
    json[:documents_uploaded] = result.documents_uploaded if result.documents_uploaded.present?
    render json: json
  end

  private

  def resolve_model_id(requested)
    return nil if requested.blank?

    if BedrockClient::ALLOWED_MODEL_IDS.include?(requested)
      requested
    else
      Rails.logger.warn("RagController: Unknown model_id '#{requested}', falling back to default")
      nil
    end
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
  rescue StandardError => e
    Rails.logger.error("RagController: Failed to extract/compress images: #{e.message}")
    []
  end

  def compress_images(images)
    images.map do |img|
      result = ImageCompressionService.compress(img[:data], img[:media_type])
      { data: result[:data], media_type: result[:media_type] }
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
end
