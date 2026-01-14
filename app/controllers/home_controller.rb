class HomeController < ApplicationController
  include MetricsHelper

  def index
    @current_metrics = current_metrics
    @monthly_totals = monthly_totals
    @s3_documents_list = S3DocumentsService.new.list_documents
  end
end

