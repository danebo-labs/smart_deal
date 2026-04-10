# frozen_string_literal: true

class HomeController < ApplicationController
  include MetricsHelper

  def index
    @current_metrics = current_metrics
    @kb_documents = KbDocument.order(created_at: :desc)
  end

  def metrics
    render turbo_stream: turbo_stream.update("metrics-container", partial: "home/metrics", locals: { current_metrics: current_metrics })
  end

  def documents
    render turbo_stream: turbo_stream.update(
      "documents-list-container",
      partial: "home/documents_list",
      locals: { kb_documents: KbDocument.order(created_at: :desc) }
    )
  end
end
