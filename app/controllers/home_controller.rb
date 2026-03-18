# frozen_string_literal: true

class HomeController < ApplicationController
  include MetricsHelper

  def index
    @current_metrics = current_metrics
    @documents = fetch_documents
  end

  def metrics
    render turbo_stream: turbo_stream.update("metrics-container", partial: "home/metrics", locals: { current_metrics: current_metrics })
  end

  def documents
    render turbo_stream: turbo_stream.update(
      "documents-list-container",
      partial: "home/documents_list",
      locals: { documents: fetch_documents }
    )
  end

  private

  # Merges KB-indexed documents with any currently-processing documents from IngestionStatusService.
  # KB API is source of truth; IngestionStatusService overlays docs not yet visible in the KB API.
  def fetch_documents
    indexed = S3DocumentsService.new.list_indexed_documents
    processing_names = IngestionStatusService.new.indexing_document_names

    indexed_names = indexed.pluck(:name).to_set
    processing_overlay = processing_names
      .reject { |name| indexed_names.include?(name) }
      .map { |name| { name: name, status: :indexing, updated_at: nil } }

    (processing_overlay + indexed).sort_by { |d| [ status_sort_order(d[:status]), d[:name] ] }
  end

  def status_sort_order(status)
    { indexed: 0, indexing: 1, failed: 2 }.fetch(status, 3)
  end
end
