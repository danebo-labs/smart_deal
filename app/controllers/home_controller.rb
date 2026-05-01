# frozen_string_literal: true

class HomeController < ApplicationController
  include MetricsHelper

  PAGE_SIZE = 20

  before_action :authenticate_user!

  def index
    @current_metrics   = current_metrics
    @kb_documents, @kb_docs_has_more = RecentKbDocumentsQuery.page(0, per_page: PAGE_SIZE)
    @pinned_uris       = pinned_uris_for_current_session
    @image_url_service = KbDocumentImageUrlService.new
  end

  def metrics
    render turbo_stream: turbo_stream.update(
      "chat-usage-metrics-container",
      partial: "home/chat_usage_footer_metrics",
      locals: { current_metrics: current_metrics }
    )
  end

  # Refreshes BOTH the desktop and mobile KB doc lists after an indexing event.
  # Called by rag_chat_controller#refreshDocuments after KbSyncChannel "indexed".
  def documents
    kb_docs, has_more = RecentKbDocumentsQuery.page(0, per_page: PAGE_SIZE)
    pinned_uris       = pinned_uris_for_current_session
    image_url_service = KbDocumentImageUrlService.new

    render turbo_stream: [
      turbo_stream.update("kb-docs-desktop-items",
        partial: "home/kb_docs_card_rows",
        locals: { kb_documents: kb_docs, pinned_uris: pinned_uris, image_url_service: image_url_service }),
      turbo_stream.update("kb-docs-mobile-items",
        partial: "home/kb_docs_card_rows",
        locals: { kb_documents: kb_docs, pinned_uris: pinned_uris, image_url_service: image_url_service }),
      sentinel_stream(:desktop, has_more: has_more, page: 1),
      sentinel_stream(:mobile,  has_more: has_more, page: 1)
    ]
  end

  # Infinite-scroll page fetch (page param is 0-indexed; first scroll fetches page=1).
  def documents_page
    page              = [ params[:page].to_i, 1 ].max
    kb_docs, has_more = RecentKbDocumentsQuery.page(page, per_page: PAGE_SIZE)
    pinned_uris       = pinned_uris_for_current_session
    image_url_service = KbDocumentImageUrlService.new

    streams = [
      turbo_stream.append("kb-docs-desktop-items",
        partial: "home/kb_docs_card_rows",
        locals: { kb_documents: kb_docs, pinned_uris: pinned_uris, image_url_service: image_url_service }),
      turbo_stream.append("kb-docs-mobile-items",
        partial: "home/kb_docs_card_rows",
        locals: { kb_documents: kb_docs, pinned_uris: pinned_uris, image_url_service: image_url_service }),
      sentinel_stream(:desktop, has_more: has_more, page: page + 1),
      sentinel_stream(:mobile,  has_more: has_more, page: page + 1)
    ]
    render turbo_stream: streams
  end

  private

  # Returns Set<String> of s3_uris currently pinned in the user's web ConversationSession.
  # Mirrors find_or_create_for: resolves to the SharedSession row when ENABLED, so
  # checkboxes survive a page refresh in shared-workspace mode.
  # Empty Set when no session exists yet (first-ever visit before any interaction).
  def pinned_uris_for_current_session
    identifier = SharedSession::ENABLED ? SharedSession::IDENTIFIER : current_user.id.to_s
    channel    = SharedSession::ENABLED ? SharedSession::CHANNEL    : "web"
    session    = ConversationSession.find_by(identifier: identifier, channel: channel)
    return Set.new if session.nil?
    Set.new(SessionContextBuilder.entity_s3_uris(session))
  end

  # Replaces the old sentinel with a fresh one bumped to the next page,
  # OR removes it when no more pages exist.
  def sentinel_stream(variant, has_more:, page:)
    sentinel_id = "kb-docs-#{variant}-sentinel"
    if has_more
      turbo_stream.replace(sentinel_id,
        partial: "home/kb_docs_card_sentinel",
        locals: { sentinel_id: sentinel_id, page: page })
    else
      turbo_stream.remove(sentinel_id)
    end
  end
end
