# frozen_string_literal: true

class HomeController < ApplicationController
  include MetricsHelper

  PAGE_SIZE = 20

  before_action :authenticate_user!

  def index
    @current_metrics  = current_metrics
    @kb_documents     = KbDocument.includes(:thumbnail).order(created_at: :desc).limit(PAGE_SIZE)
    @kb_docs_has_more = KbDocument.count > PAGE_SIZE
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
    kb_docs  = KbDocument.includes(:thumbnail).order(created_at: :desc).limit(PAGE_SIZE)
    has_more = KbDocument.count > PAGE_SIZE

    render turbo_stream: [
      turbo_stream.update("kb-docs-desktop-items",
        partial: "home/kb_docs_card_rows", locals: { kb_documents: kb_docs }),
      turbo_stream.update("kb-docs-mobile-items",
        partial: "home/kb_docs_card_rows", locals: { kb_documents: kb_docs }),
      sentinel_stream(:desktop, has_more: has_more, page: 1),
      sentinel_stream(:mobile,  has_more: has_more, page: 1)
    ]
  end

  # Infinite-scroll page fetch (page param is 0-indexed; first scroll fetches page=1).
  def documents_page
    page     = [ params[:page].to_i, 1 ].max
    docs     = KbDocument.includes(:thumbnail)
                         .order(created_at: :desc)
                         .offset(page * PAGE_SIZE)
                         .limit(PAGE_SIZE + 1)
    has_more = docs.size > PAGE_SIZE
    kb_docs  = docs.first(PAGE_SIZE)

    streams = [
      turbo_stream.append("kb-docs-desktop-items",
        partial: "home/kb_docs_card_rows", locals: { kb_documents: kb_docs }),
      turbo_stream.append("kb-docs-mobile-items",
        partial: "home/kb_docs_card_rows", locals: { kb_documents: kb_docs }),
      sentinel_stream(:desktop, has_more: has_more, page: page + 1),
      sentinel_stream(:mobile,  has_more: has_more, page: page + 1)
    ]
    render turbo_stream: streams
  end

  private

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
