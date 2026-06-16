# frozen_string_literal: true

# E3b: parse a few automatically selected urgent pages from a long web/chat PDF
# while the complete manual continues through Batch.
class ProcessManualUrgentTriageJob < ApplicationJob
  queue_as :bulk_ingestion

  RECENT_PROCESSING_WINDOW = 30.minutes

  # @param query [String] original technician question attached to the upload
  def perform(s3_key:, filename:, sha256:, kb_doc_id:, query:, locale: nil, conv_session_id: nil)
    return if query.blank?

    batch = find_or_initialize_batch!(
      s3_key: s3_key,
      filename: filename,
      sha256: sha256,
      kb_doc_id: kb_doc_id,
      locale: locale,
      conv_session_id: conv_session_id
    )
    return if full_batch_ready?(batch) || urgent_triage_already_running_or_done?(batch)

    batch.update!(
      urgent_status: "processing",
      urgent_started_at: Time.current,
      urgent_error_message: nil
    )

    binary = S3DocumentsService.new.download(s3_key)
    raise "S3 download failed for #{s3_key}" if binary.blank?

    result = ManualUrgentTriageService.new.call(
      binary: binary,
      filename: filename,
      sha256: sha256,
      s3_key: s3_key,
      query: query,
      kb_doc_id: kb_doc_id,
      conv_session_id: conv_session_id,
      locale: locale,
      web_manual_batch_id: batch.id
    )

    batch.update!(
      urgent_status: "syncing",
      urgent_pages: Array(result["selected_pages"]),
      urgent_chunks_s3_prefix: result["chunks_s3_prefix"],
      urgent_error_message: nil
    )
  rescue ManualUrgentTriageService::NoPagesSelected => e
    batch&.update_columns(urgent_status: "skipped", urgent_error_message: e.message)
    Rails.logger.info("ProcessManualUrgentTriageJob: #{e.message}")
  rescue StandardError => e
    batch&.update_columns(urgent_status: "failed", urgent_error_message: e.message)
    Rails.logger.error("ProcessManualUrgentTriageJob[#{filename}]: #{e.class}: #{e.message}")
    Rails.logger.error(e.backtrace.first(10).join("\n"))
    KbSyncBroadcaster.partial_failed(
      filenames: [ filename ],
      message: I18n.with_locale(locale || :es) { I18n.t("rag.manual_urgent_triage_failed") }
    )
  end

  private

  def find_or_initialize_batch!(s3_key:, filename:, sha256:, kb_doc_id:, locale:, conv_session_id:)
    WebManualBatch.find_or_initialize_by(
      sha256: sha256,
      s3_key: s3_key,
      ingestion_contract_version: BatchChunkingPrompt::INGESTION_CONTRACT_VERSION
    ).tap do |batch|
      batch.assign_attributes(
        filename: filename,
        content_type: "application/pdf",
        kb_document_id: kb_doc_id,
        conv_session_id: conv_session_id,
        locale: locale
      )
      batch.save!
    end
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def full_batch_ready?(batch)
    batch.status.in?(%w[parsed syncing complete])
  end

  def urgent_triage_already_running_or_done?(batch)
    return true if batch.urgent_status.in?(%w[syncing complete])

    batch.urgent_status == "processing" &&
      batch.urgent_started_at.present? &&
      batch.urgent_started_at > RECENT_PROCESSING_WINDOW.ago
  end
end
