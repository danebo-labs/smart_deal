# frozen_string_literal: true

class HomeController < ApplicationController
  include MetricsHelper

  before_action :authenticate_user!

  def index
    @current_metrics = current_metrics
    @kb_documents = KbDocument.order(created_at: :desc)
    @technician_documents_recent = TechnicianDocument.recent.to_a
    @session_entity_keys = session_entity_keys_for_home
  end

  def metrics
    render turbo_stream: turbo_stream.update(
      "chat-usage-metrics-container",
      partial: "home/chat_usage_footer_metrics",
      locals: { current_metrics: current_metrics }
    )
  end

  def documents
    render turbo_stream: turbo_stream.update(
      "documents-list-container",
      partial: "home/documents_list",
      locals: { kb_documents: KbDocument.order(created_at: :desc) }
    )
  end

  private

  # Read-only: do not find_or_create (avoids side effects on every home load).
  #
  # MVP (SharedSession::ENABLED): una sola fila para web + WhatsApp; el home usa esa
  # sesión para verificar active_entities sin exigir login.
  def conversation_session_for_home_dashboard
    if SharedSession::ENABLED
      ConversationSession.active.find_by(
        identifier: SharedSession::IDENTIFIER,
        channel: SharedSession::CHANNEL
      )
    elsif user_signed_in?
      ConversationSession.active.find_by(identifier: current_user.id.to_s, channel: "web")
    end
  end

  # Entidades: sesión acotada arriba; si vacío, primera fila (p. ej. una sola sesión en BD en pruebas).
  def session_entity_keys_for_home
    keys = entity_keys_array(conversation_session_for_home_dashboard)
    return keys if keys.any?

    entity_keys_array(ConversationSession.order(:id).first)
  end

  def entity_keys_array(session)
    session&.active_entities&.presence&.keys&.map(&:to_s) || []
  end
end
