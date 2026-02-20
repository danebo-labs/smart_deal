# frozen_string_literal: true

require 'open-uri'
require 'base64'

class TwilioController < ApplicationController
  include RagQueryConcern

  skip_before_action :verify_authenticity_token

  SUPPORTED_IMAGE_TYPES = %w[image/png image/jpeg image/jpg image/gif image/webp].freeze

  def webhook
    message_body = params['Body']
    images = extract_media_from_params

    if images.any?
      Rails.logger.info("TwilioController: Received #{images.size} image(s) from WhatsApp")
    end

    result = execute_rag_query(message_body, images: images)
    rag_response = format_rag_response_for_whatsapp(result)

    response = Twilio::TwiML::MessagingResponse.new
    response.message { |m| m.body(rag_response) }

    render xml: response.to_s
  end

  private

  def extract_media_from_params
    num_media = params['NumMedia'].to_i
    return [] unless num_media.positive?

    images = []

    num_media.times do |i|
      media_url = params["MediaUrl#{i}"]
      media_type = params["MediaContentType#{i}"]

      next unless media_url.present? && SUPPORTED_IMAGE_TYPES.include?(media_type)

      image_data = download_twilio_media(media_url)
      next unless image_data

      images << { data: Base64.strict_encode64(image_data), media_type: media_type }
    end

    images
  rescue StandardError => e
    Rails.logger.error("TwilioController: Failed to extract media — #{e.message}")
    []
  end

  def download_twilio_media(url)
    account_sid = ENV.fetch('TWILIO_ACCOUNT_SID', nil)
    auth_token = ENV.fetch('TWILIO_AUTH_TOKEN', nil)

    unless account_sid && auth_token
      Rails.logger.warn("TwilioController: TWILIO_ACCOUNT_SID/AUTH_TOKEN not set, cannot download media")
      return nil
    end

    URI.parse(url).open(http_basic_authentication: [ account_sid, auth_token ]).read
  rescue StandardError => e
    Rails.logger.error("TwilioController: Failed to download media from #{url} — #{e.message}")
    nil
  end
end
