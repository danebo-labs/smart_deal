# frozen_string_literal: true

class TwilioController < ApplicationController
  skip_before_action :verify_authenticity_token

  IDEMPOTENCY_TTL         = 24.hours
  SUPPORTED_CONTENT_TYPES = %w[image/png image/jpeg image/jpg image/gif image/webp].freeze

  def webhook
    message_sid = params['MessageSid']
    from        = params['From']
    to          = params['To']
    body        = params['Body'].to_s.strip
    num_media   = params['NumMedia'].to_i

    # Twilio retries webhooks on timeout — deduplicate by MessageSid
    if message_sid.present? && Rails.cache.exist?("twilio_msg:#{message_sid}")
      render xml: Twilio::TwiML::MessagingResponse.new.to_s and return
    end
    Rails.cache.write("twilio_msg:#{message_sid}", 1, expires_in: IDEMPOTENCY_TTL) if message_sid.present?

    conv_session = ConversationSession.find_or_create_for(identifier: from, channel: "whatsapp")
    conv_session.add_to_history("user", body.presence || "[media]")
    conv_session.refresh!

    if num_media.positive?
      media = (0...num_media).filter_map do |i|
        url  = params["MediaUrl#{i}"]
        type = params["MediaContentType#{i}"]
        { url: url, content_type: type } if url.present? && SUPPORTED_CONTENT_TYPES.include?(type)
      end

      ProcessWhatsappMediaJob.perform_later(
        from: from, to: to, body: body,
        media: media, message_sid: message_sid,
        conv_session_id: conv_session.id
      )

      twiml = Twilio::TwiML::MessagingResponse.new
      twiml.message { |m| m.body(I18n.t('rag.whatsapp_image_received')) }
      render xml: twiml.to_s
    else
      SendWhatsappReplyJob.perform_later(to: from, from: to, body: body, conv_session_id: conv_session.id)
      render xml: Twilio::TwiML::MessagingResponse.new.to_s
    end
  end
end
