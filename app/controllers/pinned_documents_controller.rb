# frozen_string_literal: true

# Pin/unpin KbDocuments on the ConversationSession workspace.
# Pins drive the entity_s3_uris filter (force_entity_filter: true) for RAG retrieval.
# The workspace row lasts 30 sliding days. Web pins live in document_focus.
# A case boundary does not write that column. Re-pin renews added_at.
#
# A suggestion card sends kb_document_id and document_uid. The id is the row.
# The uid only confirms that row. knowledge_scope from the browser is ignored.
# A library pin omits document_uid and keeps the previous contract.
class PinnedDocumentsController < ApplicationController
  include AuthenticationConcern

  rescue_from ActiveRecord::RecordNotFound, with: :not_found

  def create
    kb_doc = focus_document
    return if performed?

    session = current_conv_session
    before_ids = session.focus_document_ids.sort
    already = already_focused?(session, kb_doc)

    unless write_focus!(session, kb_doc)
      return render_focus_failure(:invalid) if card_confirmation?

      render json: { error: "Could not pin document" }, status: :unprocessable_entity
      return
    end

    changed = session.reload.focus_document_ids.sort != before_ids
    if card_confirmation? && !changed
      render_existing_focus(kb_doc, session)
      return
    end

    DocumentOverviewWarmJob.perform_later(account_id: current_account.id, kb_document_id: kb_doc.id) unless already
    record_focus_confirmed(session, kb_doc) if card_confirmation? && changed
    render_focus_result(kb_doc, session, changed)
  end

  def destroy
    id = params[:id].to_i
    session = current_conv_session
    return head :not_found if id.zero? || session.find_entity_by_kb_document_id(id).nil?

    kb_doc = KbDocument.find_by(id: id)
    return head :not_found unless session.unpin_kb_document_id!(id)

    return head :no_content unless card_confirmation?

    record_focus_dismissed(session, kb_doc)
    render json: {
      status: "unfocused",
      message: I18n.t("rag.manual_focus_removed"),
      kb_document_id: id
    }
  end

  private

  def create_params
    params.permit(:kb_document_id, :document_uid, :correlation_id, :focus_mode)
  end

  def replace_focus?
    create_params[:focus_mode].to_s == "replace"
  end

  def write_focus!(session, kb_doc)
    if replace_focus?
      session.replace_document_focus!(kb_doc)
    else
      session.pin_kb_document!(kb_doc)
    end
  end

  def card_confirmation?
    params[:document_uid].present?
  end

  # The id is the physical row. document_uid is a confirmation, not a lookup.
  # A foreign tenant_private row stays unavailable. A danebo_general row is
  # the same physical document. Removing focus does not grant a read.
  def focus_document
    candidates = KbDocument.where(account_id: current_account.id).or(KbDocument.danebo_general)
    kb_doc = candidates.find_by(id: create_params[:kb_document_id])
    unless kb_doc && Rag::KnowledgeScopePolicy.authorized?(kb_doc, viewer_account: current_account)
      render_focus_failure(:unavailable)
      return
    end
    if card_confirmation? && kb_doc.document_uid.to_s != create_params[:document_uid].to_s
      render_focus_failure(:invalid)
      return
    end

    kb_doc
  end

  def already_focused?(session, kb_doc)
    session.find_entity_by_kb_document_id(kb_doc.id).present?
  end

  def render_existing_focus(kb_doc, session)
    render json: focus_body("already_focused", I18n.t("rag.manual_focus_already"), kb_doc, session, false)
  end

  def render_focus_result(kb_doc, session, changed)
    return head :no_content unless card_confirmation?

    render json: focus_body("focused", I18n.t("rag.manual_focus_confirmed"), kb_doc, session, changed)
  end

  def focus_body(status, message, kb_doc, session, changed)
    {
      status: status,
      message: message,
      kb_document_id: kb_doc.id,
      focus_ids: session.focus_document_ids,
      replay: changed && create_params[:correlation_id].present?
    }
  end

  def render_focus_failure(code)
    record_focus_denied(code) if card_confirmation?
    if card_confirmation? && code == :invalid
      render json: { error: I18n.t("rag.manual_focus_invalid") }, status: :unprocessable_entity
    elsif card_confirmation?
      render json: { error: I18n.t("rag.manual_focus_unavailable") }, status: :not_found
    else
      render json: { error: "Document not found" }, status: :not_found
    end
  end

  def record_focus_confirmed(session, kb_doc)
    PilotUsageLog.log(
      "manual_focus_confirmed",
      account_id: current_account.id,
      user_id: current_user.id,
      conversation_session_id: session.id,
      correlation_id: create_params[:correlation_id].presence,
      document_id: kb_doc.document_uid,
      source_uri: kb_doc.display_s3_uri(KbDocument::KB_BUCKET),
      knowledge_scope: Rag::KnowledgeScopePolicy.scope_for(kb_doc, viewer_account: current_account)
    )
  end

  def record_focus_denied(code)
    PilotUsageLog.log(
      "manual_focus_denied",
      account_id: current_account.id,
      user_id: current_user.id,
      conversation_session_id: existing_session_id,
      correlation_id: create_params[:correlation_id].presence,
      outcome_reason: code.to_s
    )
  end

  def record_focus_dismissed(session, kb_doc)
    document_id = kb_doc&.document_uid.presence || params[:document_uid].to_s
    PilotUsageLog.log(
      "manual_suggestion_dismissed",
      account_id: current_account.id,
      user_id: current_user.id,
      conversation_session_id: session.id,
      correlation_id: params[:correlation_id].presence,
      document_id: document_id,
      outcome: "unpinned"
    )
  end

  def existing_session_id
    ConversationSession.find_by(
      identifier: current_user.id.to_s,
      channel: "web",
      account_id: current_account.id
    )&.id
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
