# frozen_string_literal: true

require 'open-uri'
require 'base64'

# Downloads Twilio media attachments in the background, compresses them,
# uploads to S3, and triggers a Bedrock KB ingestion.
# BedrockIngestionJob notifies the WhatsApp user when indexing completes.
class ProcessWhatsappMediaJob < ApplicationJob
  queue_as :whatsapp_media

  MAX_ATTEMPTS = 3

  retry_on StandardError, wait: :polynomially_longer, attempts: MAX_ATTEMPTS do |job, _error|
    args        = job.arguments.first || {}
    whatsapp_to = args[:from] || args['from']   # "From" = the user who sent the image
    twilio_from = args[:to]   || args['to']      # "To"   = our Twilio number
    next unless whatsapp_to && twilio_from

    begin
      Twilio::REST::Client
        .new(ENV.fetch('TWILIO_ACCOUNT_SID'), ENV.fetch('TWILIO_AUTH_TOKEN'))
        .messages.create(
          from: twilio_from,
          to:   whatsapp_to,
          body: I18n.t('rag.whatsapp_indexing_failed')
        )
    rescue StandardError => send_err
      Rails.logger.error("ProcessWhatsappMediaJob: failed to notify user — #{send_err.message}")
    end
  end

  def perform(from:, to:, body:, media:, message_sid: nil, conv_session_id: nil)
    images = download_and_compress(media)

    if images.empty?
      Rails.logger.warn("ProcessWhatsappMediaJob: no usable images for MessageSid=#{message_sid}")
      send_message(from: to, to: from, body: I18n.t('rag.whatsapp_indexing_failed'))
      return
    end

    upload_and_sync(images, whatsapp_from: to, whatsapp_to: from, conv_session_id: conv_session_id)
  end

  private

  SUPPORTED_IMAGE_TYPES = %w[image/png image/jpeg image/jpg image/gif image/webp].freeze

  def download_and_compress(media)
    account_sid = ENV.fetch('TWILIO_ACCOUNT_SID')
    auth_token  = ENV.fetch('TWILIO_AUTH_TOKEN')
    images      = []

    Array(media).each do |item|
      url          = item.is_a?(Hash) ? (item[:url]          || item['url'])          : nil
      content_type = item.is_a?(Hash) ? (item[:content_type] || item['content_type']) : nil
      next unless url.present? && SUPPORTED_IMAGE_TYPES.include?(content_type)

      raw        = URI.parse(url).open(http_basic_authentication: [ account_sid, auth_token ]).read
      b64        = Base64.strict_encode64(raw)
      compressed = ImageCompressionService.compress(b64, content_type)
      images << { data: compressed[:data], media_type: compressed[:media_type] }
    rescue StandardError => e
      Rails.logger.error("ProcessWhatsappMediaJob: download failed for #{url} — #{e.message}")
    end

    images
  end

  # @return [Array<String>] basenames successfully uploaded to S3
  def upload_and_sync(images, whatsapp_from:, whatsapp_to:, conv_session_id: nil)
    s3        = S3DocumentsService.new
    uploaded  = []

    images.each_with_index do |img, idx|
      ext      = img[:media_type]&.split('/')&.last || 'png'
      filename = "wa_#{Time.current.strftime('%Y%m%d_%H%M%S')}_#{idx}.#{ext}"
      binary   = Base64.decode64(img[:data])
      key      = s3.upload_file(filename, binary, img[:media_type])
      uploaded << filename if key.present?
    end

    return [] unless uploaded.any?

    result = KbSyncService.new.sync!(uploaded_filenames: uploaded)
    return uploaded if result.blank?

    BedrockIngestionJob.perform_later(
      result[:job_id],
      uploaded,
      kb_id:            result[:kb_id],
      data_source_id:   result[:data_source_id],
      whatsapp_from:    whatsapp_from,
      whatsapp_to:      whatsapp_to,
      conv_session_id:  conv_session_id
    )

    uploaded
  end

  def send_message(from:, to:, body:)
    Twilio::REST::Client
      .new(ENV.fetch('TWILIO_ACCOUNT_SID'), ENV.fetch('TWILIO_AUTH_TOKEN'))
      .messages.create(from: from, to: to, body: body)
  rescue StandardError => e
    Rails.logger.error("ProcessWhatsappMediaJob: Twilio send failed — #{e.message}")
  end
end
