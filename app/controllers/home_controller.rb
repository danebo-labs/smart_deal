# frozen_string_literal: true

class HomeController < ApplicationController
  include MetricsHelper

  def index
    @current_metrics = current_metrics
    @s3_documents_list = S3DocumentsService.new.list_documents
    @indexing_document_names = IngestionStatusService.new.indexing_document_names
  end

  def metrics
    render turbo_stream: turbo_stream.update("metrics-container", partial: "home/metrics", locals: { current_metrics: current_metrics })
  end

  def documents
    documents = S3DocumentsService.new.list_documents
    indexing_docs = IngestionStatusService.new.indexing_document_names
    render turbo_stream: turbo_stream.update(
      "documents-list-container",
      partial: "home/documents_list",
      locals: { documents: documents, indexing_document_names: indexing_docs }
    )
  end
end
