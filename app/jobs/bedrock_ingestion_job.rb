# frozen_string_literal: true

# Monitors a Bedrock Knowledge Base ingestion job until completion, then broadcasts
# the result via ActionCable so the UI can update spinners to check marks.
#
# @see Amazon Q recommendation: Use jobs in background with wait_for_completion
class BedrockIngestionJob < ApplicationJob
  queue_as :default

  retry_on Timeout::Error, wait: :polynomially_longer, attempts: 2
  discard_on ActiveJob::DeserializationError

  POLL_INTERVAL = 5.seconds
  TIMEOUT = 15.minutes

  def perform(ingestion_job_id, uploaded_filenames, kb_id: nil, data_source_id: nil)
    return if ingestion_job_id.blank?

    service = IngestionStatusService.new(kb_id: kb_id, data_source_id: data_source_id)
    started_at = Time.current

    loop do
      raise Timeout::Error, "Ingestion job #{ingestion_job_id} timed out" if Time.current - started_at > TIMEOUT

      status = service.job_status(ingestion_job_id)
      break if status.in?(%w[COMPLETE FAILED STOPPED])

      sleep POLL_INTERVAL
    end

    status = service.job_status(ingestion_job_id)
    service.clear_when_complete(ingestion_job_id)

    if status == "COMPLETE"
      broadcast_indexed(uploaded_filenames)
    else
      reasons = status == "FAILED" ? service.failure_reasons(ingestion_job_id) : []
      message = ingestion_failure_message(reasons)
      broadcast_failed(uploaded_filenames, status, message)
    end
  rescue StandardError => e
    Rails.logger.error("BedrockIngestionJob failed: #{e.message}")
    broadcast_failed(uploaded_filenames, "error", e.message)
  end

  private

  def ingestion_failure_message(failure_reasons)
    reasons_text = failure_reasons.join(" ").downcase
    if reasons_text.include?("maximumfilesizesupported") || reasons_text.include?("52428800")
      I18n.t("rag.ingestion_failed_file_too_large")
    elsif reasons_text.include?("format") && (reasons_text.include?("not supported") || reasons_text.include?("unsupported"))
      I18n.t("rag.ingestion_failed_format_not_supported")
    else
      I18n.t("rag.document_indexing_failed_message")
    end
  end

  def broadcast_indexed(filenames)
    ActionCable.server.broadcast("kb_sync", {
      status: "indexed",
      filenames: Array(filenames).compact,
      message: I18n.t("rag.document_indexed_message")
    })
  end

  def broadcast_failed(filenames, reason, message = nil)
    ActionCable.server.broadcast("kb_sync", {
      status: "failed",
      filenames: Array(filenames).compact,
      reason: reason,
      message: message.presence || I18n.t("rag.document_indexing_failed_message")
    })
  end
end
