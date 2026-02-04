class TwilioController < ApplicationController
    skip_before_action :verify_authenticity_token

    def webhook
      # Obtener mensaje de WhatsApp
      message_body = params['Body']
      from_number = params['From']

      # Llamar a tu RagController logic
      rag_response = call_rag_service(message_body)

      # Responder via Twilio
      response = Twilio::TwiML::MessagingResponse.new
      response.message do |m|
        m.body(rag_response)
      end

      render xml: response.to_s
    end

    private

    def call_rag_service(question)
      question = question.to_s.strip
      return "Por favor envía una pregunta (el mensaje no puede estar vacío)." if question.blank?

      rag_service = BedrockRagService.new
      result = rag_service.query(question)

      text = result[:answer].to_s
      text += "\n\nFuentes: #{result[:citations].join(', ')}" if result[:citations].present?
      text.presence || "No encontré una respuesta."
    rescue BedrockRagService::MissingKnowledgeBaseError => e
      Rails.logger.error("RAG config error: #{e.message}")
      "El servicio de consultas no está configurado correctamente."
    rescue BedrockRagService::BedrockServiceError => e
      Rails.logger.error("RAG AWS error: #{e.message}")
      "Error al consultar la base de conocimiento. Intenta más tarde."
    rescue StandardError => e
      Rails.logger.error("Twilio RAG error: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
      "Lo siento, ocurrió un error: #{e.message}"
    end
end
