# frozen_string_literal: true

require 'open-uri'
require 'base64'

class TwilioController < ApplicationController
  include RagQueryConcern

  skip_before_action :verify_authenticity_token

  SUPPORTED_IMAGE_TYPES = %w[image/png image/jpeg image/jpg image/gif image/webp].freeze

  def webhook
    message_body = params['Body']
    from         = params['From']
    to           = params['To']
    images       = extract_media_from_params

    if images.any?
      Rails.logger.info("TwilioController: Received #{images.size} image(s) from WhatsApp")
    end

    if images.any?
      # Image path still handled synchronously (download + compress already done above)
      result = execute_rag_query(message_body, images: images)
      rag_response = format_rag_response_for_whatsapp(result)

      twiml = Twilio::TwiML::MessagingResponse.new
      twiml.message { |m| m.body(rag_response) }
      render xml: twiml.to_s
    else
      # Text-only: enqueue job so we respond to Twilio within the 15-second timeout.
      SendWhatsappReplyJob.perform_later(to: from, from: to, body: message_body)

      render xml: Twilio::TwiML::MessagingResponse.new.to_s
    end
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

      base64_data = Base64.strict_encode64(image_data)
      compressed = ImageCompressionService.compress(base64_data, media_type)
      images << { data: compressed[:data], media_type: compressed[:media_type] }
    rescue ImageCompressionService::CompressionError => e
      Rails.logger.error("TwilioController: Image compression failed — #{e.message}")
      # Skip this image; others may still succeed
      next
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
