# frozen_string_literal: true

# Phase 1 of the web long-manual batch ingestion path:
#   Downloads PDF from S3, applies PageRelevanceFilter, submits Anthropic Batch,
#   stores durable batch context, then schedules polling.
class SubmitManualBatchJob < ApplicationJob
  queue_as :bulk_ingestion

  # @param s3_key         [String]       S3 key for the uploaded PDF
  # @param filename       [String]       original filename
  # @param sha256         [String]       full SHA-256 hex of the binary
  # @param kb_doc_id      [Integer]      KbDocument id
  # @param account_id     [Integer]      Account id owning the session/document
  # @param document_uid   [String]       Stable KbDocument UUID
  # @param locale         [String, nil]  ISO 639-1
  # @param conv_session_id [Integer, nil]
  def perform(s3_key:, filename:, sha256:, kb_doc_id:, account_id:, document_uid:, locale: nil, conv_session_id: nil)
    assert_owned!(account_id: account_id, document_uid: document_uid, kb_doc_id: kb_doc_id, conv_session_id: conv_session_id)

    batch = find_or_initialize_batch!(
      s3_key: s3_key,
      filename: filename,
      sha256: sha256,
      kb_doc_id: kb_doc_id,
      account_id: account_id,
      locale: locale,
      conv_session_id: conv_session_id
    )

    unless batch.status == "pending"
      Rails.logger.info("SubmitManualBatchJob: skipped #{filename}; status=#{batch.status}")
      return
    end

    locked = WebManualBatch.where(id: batch.id, status: "pending").update_all(status: "submitting", updated_at: Time.current)
    return unless locked == 1

    batch.reload

    binary = S3DocumentsService.new.download(s3_key)
    if binary.blank?
      batch.update!(status: "failed", error_message: "S3 download failed for #{s3_key}")
      Rails.logger.error("SubmitManualBatchJob: could not download s3_key=#{s3_key} — skipping")
      return
    end

    result = ManualBatchIngestionService.new.submit!(
      binary:   binary,
      filename: filename,
      sha256:   sha256,
      s3_key:   s3_key,
      locale:   locale
    )

    if result[:batch_id].blank?
      batch.update!(
        status:        "failed",
        page_customs:  result[:page_customs] || {},
        kept_pages:    result[:kept_pages] || [],
        total_pages:   result[:total_pages],
        error_message: "No pages kept by relevance filter"
      )
      KbSyncBroadcaster.failed(
        filenames: [ filename ],
        reason:    "manual_batch_no_relevant_pages",
        locale:    locale
      )
      Rails.logger.warn("SubmitManualBatchJob: no pages kept for #{filename} — skipping batch")
      return
    end

    batch.update!(
      claude_batch_id: result[:batch_id],
      status:          "submitted",
      page_customs:    result[:page_customs] || {},
      kept_pages:      result[:kept_pages] || [],
      total_pages:     result[:total_pages],
      submitted_at:    Time.current,
      error_message:   nil
    )

    enqueue_poll(batch, wait: 5.minutes)

    Rails.logger.info(
      "SubmitManualBatchJob: #{filename} → batch_id=#{result[:batch_id]} " \
      "kept=#{result[:kept_pages].size}/#{result[:total_pages]}"
    )
  rescue StandardError => e
    Rails.logger.error("SubmitManualBatchJob[#{filename}]: #{e.class}: #{e.message}")
    raise
  end

  private

  def find_or_initialize_batch!(s3_key:, filename:, sha256:, kb_doc_id:, account_id:, locale:, conv_session_id:)
    WebManualBatch.find_or_initialize_by(
      account_id: account_id,
      kb_document_id: kb_doc_id,
      sha256: sha256,
      s3_key: s3_key,
      ingestion_contract_version: BatchChunkingPrompt::INGESTION_CONTRACT_VERSION
    ).tap do |batch|
      batch.assign_attributes(
        filename: filename,
        content_type: "application/pdf",
        conv_session_id: conv_session_id,
        locale: locale
      )
      batch.save!
    end
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def enqueue_poll(batch, wait:)
    IngestManualBatchResultsJob.set(wait: wait).perform_later(
      web_manual_batch_id: batch.id,
      attempt:             1
    )
  end

  def assert_owned!(account_id:, document_uid:, kb_doc_id:, conv_session_id:)
    kb_doc = KbDocument.find(kb_doc_id)
    unless kb_doc.account_id == account_id && kb_doc.document_uid == document_uid
      raise UploadAndSyncAttachmentsJob::AccountOwnershipError,
        "KbDocument #{kb_doc_id} is not owned by account/document #{account_id}/#{document_uid}"
    end

    return if conv_session_id.blank?

    session = ConversationSession.find(conv_session_id)
    return if session.account_id == account_id

    raise UploadAndSyncAttachmentsJob::AccountOwnershipError,
      "ConversationSession #{conv_session_id} is not owned by account #{account_id}"
  end
end
