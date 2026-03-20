# frozen_string_literal: true

# Performs the actual Bedrock RAG query and delivers the answer to a WhatsApp
# recipient via the Twilio REST API.
#
# Decoupled from TwilioController#webhook so the webhook can respond with
# empty TwiML immediately (within Twilio's 15-second timeout window) while
# this job handles the arbitrarily long Bedrock round-trip in the background.
class SendWhatsappReplyJob < ApplicationJob
  include RagQueryConcern

  queue_as :default

  # @param to   [String] Recipient WhatsApp number, e.g. "whatsapp:+5491122334455"
  # @param from [String] Twilio WhatsApp number, e.g. "whatsapp:+14155238886"
  # @param body [String] The user's message text
  def perform(to:, from:, body:)
    result = execute_rag_query(body, whatsapp_to: to)
    reply  = format_rag_response_for_whatsapp(result)
    chunks = split_for_whatsapp(reply)

    account_sid = ENV.fetch('TWILIO_ACCOUNT_SID') { raise "TWILIO_ACCOUNT_SID not set in environment" }
    auth_token  = ENV.fetch('TWILIO_AUTH_TOKEN')  { raise "TWILIO_AUTH_TOKEN not set in environment" }
    client      = Twilio::REST::Client.new(account_sid, auth_token)

    chunks.each_with_index do |chunk, i|
      prefix  = chunks.size > 1 ? "(#{i + 1}/#{chunks.size}) " : ""
      client.messages.create(from: from, to: to, body: "#{prefix}#{chunk}")
      sleep(0.5) if i < chunks.size - 1
    end

    Rails.logger.info("SendWhatsappReplyJob: delivered #{chunks.size} message(s) (#{reply.length} chars) to #{to}")
  rescue Twilio::REST::RestError => e
    Rails.logger.error("SendWhatsappReplyJob: Twilio delivery failed — #{e.message}")
    raise
  rescue StandardError => e
    Rails.logger.error("SendWhatsappReplyJob: unexpected error — #{e.message}")
    raise
  end
end
