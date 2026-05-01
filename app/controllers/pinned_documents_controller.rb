# frozen_string_literal: true

# Pin/unpin KbDocuments into the active ConversationSession.
# Pins drive the entity_s3_uris filter (force_entity_filter: true) for RAG retrieval.
# Sessions persist 30 days sliding; pins survive across days for the same user.
class PinnedDocumentsController < ApplicationController
  include AuthenticationConcern

  rescue_from ActiveRecord::RecordNotFound, with: :not_found

  def create
    kb_doc  = KbDocument.find(create_params[:kb_document_id])
    session = current_conv_session
    if session.pin_kb_document!(kb_doc)
      head :no_content
    else
      render json: { error: "Could not pin document" }, status: :unprocessable_entity
    end
  end

  def destroy
    kb_doc  = KbDocument.find(params[:id])
    session = current_conv_session
    session.unpin_kb_document!(kb_doc)
    head :no_content
  end

  private

  def create_params
    params.permit(:kb_document_id)
  end

  def current_conv_session
    effective_user_id = SharedSession::ENABLED ? nil : current_user.id
    ConversationSession.find_or_create_for(
      identifier: current_user.id.to_s, channel: "web", user_id: effective_user_id
    ).tap(&:refresh!)
  end

  def not_found
    render json: { error: "Document not found" }, status: :not_found
  end
end
