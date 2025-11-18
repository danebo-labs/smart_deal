# app/controllers/rag_controller.rb

class RagController < ApplicationController
  before_action :authenticate_user!

  def ask
    question = params[:question]&.strip

    unless question.present?
      render json: { 
        message: "La pregunta no puede estar vacía",
        status: "error"
      }, status: :bad_request
      return
    end

    begin
      rag_service = BedrockRagService.new
      
      # Use the simpler retrieve_and_generate method for direct RAG
      result = rag_service.query(question)
      
      render json: {
        answer: result[:answer],
        citations: result[:citations],
        session_id: result[:session_id],
        status: "success"
      }
    rescue => e
      Rails.logger.error("RAG query error: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      
      render json: {
        message: "Error al procesar la pregunta: #{e.message}",
        status: "error"
      }, status: :unprocessable_entity
    end
  end
end

