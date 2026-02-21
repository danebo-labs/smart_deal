# frozen_string_literal: true

# app/controllers/rag_controller.rb

class RagController < ApplicationController
  include AuthenticationConcern
  include RagQueryConcern

  def ask
    images = extract_images_from_params

    result = execute_rag_query(params[:question], images: images)

    unless result.success?
      render_rag_json_error(result)
      return
    end

    render json: {
      answer: result.answer,
      citations: result.citations,
      session_id: result.session_id,
      status: 'success'
    }
  end

  private

  def extract_images_from_params
    image_param = params[:image]
    return [] if image_param.blank?

    if image_param.is_a?(Array)
      image_param.select { |img| img[:data].present? && img[:media_type].present? }
    elsif image_param[:data].present? && image_param[:media_type].present?
      [ image_param.to_unsafe_h ]
    else
      []
    end
  rescue StandardError
    []
  end
end
