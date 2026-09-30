# frozen_string_literal: true

# Pin/unpin KbDocuments into the active ConversationSession.
# Pins drive the entity_s3_uris filter (force_entity_filter: true) for RAG retrieval.
# Sessions persist 30 days sliding; pins survive across days for the same user.
class PinnedDocumentsController < ApplicationController
  include AuthenticationConcern

  rescue_from ActiveRecord::RecordNotFound, with: :not_found

  def create
    kb_doc  = authorized_kb_document!(create_params[:kb_document_id])
    session = current_conv_session
    if session.pin_kb_document!(kb_doc)
      DocumentOverviewWarmJob.perform_later(account_id: current_account.id, kb_document_id: kb_doc.id)
      head :no_content
    else
      render json: { error: "Could not pin document" }, status: :unprocessable_entity
    end
  end

  def destroy
    kb_doc = session_pin_document
    return head :not_found unless kb_doc

    current_conv_session.unpin_kb_document!(kb_doc)
    head :no_content
  end

  private

  def create_params
    params.permit(:kb_document_id)
  end

  # The id is not authority. A foreign tenant_private row stays a 404.
  # A danebo_general row is the same physical document, pinnable here.
  # Removing focus does not grant a read. The pin is identified by this
  # session's kb_document_id, including after the document was revoked.
  def session_pin_document
    id = params[:id].to_i
    return if id.zero?

    session = current_conv_session
    pinned = session.active_entities.any? { |_key, meta|
      meta.is_a?(Hash) && meta["kb_document_id"].to_i == id
    }
    return unless pinned

    KbDocument.find_by(id: id)
  end

  def authorized_kb_document!(id)
    kb_doc = KbDocument.find(id)
    return kb_doc if Rag::KnowledgeScopePolicy.authorized?(kb_doc, viewer_account: current_account)

    raise ActiveRecord::RecordNotFound
  end

  def current_conv_session
    ConversationSession.find_or_create_for(
      identifier:  current_user.id.to_s,
      channel:     "web",
      user_id:     current_user.id,
      account_id:  current_user.account_id
    ).tap(&:refresh!)
  end

  def not_found
    render json: { error: "Document not found" }, status: :not_found
  end
end
