# frozen_string_literal: true

# Phase 1 of the dormant web manual batch ingestion path:
#   Downloads PDF from S3, applies PageRelevanceFilter, submits Anthropic Batch,
#   stores batch context in Solid Cache, then schedules polling.
#
# Active web/chat uploads pass urgent=true and parse sync. This job is only
# reached if a caller explicitly invokes CustomChunkingPipeline with urgent=false.
# Falls back to direct sync parse if submission fails.
class SubmitManualBatchJob < ApplicationJob
  queue_as :default

  # @param s3_key         [String]       S3 key for the uploaded PDF
  # @param filename       [String]       original filename
  # @param sha256         [String]       full SHA-256 hex of the binary
  # @param kb_doc_id      [Integer]      KbDocument id
  # @param locale         [String, nil]  ISO 639-1
  # @param conv_session_id [Integer, nil]
  def perform(s3_key:, filename:, sha256:, kb_doc_id:, locale: nil, conv_session_id: nil)
    binary = S3DocumentsService.new.download(s3_key)
    if binary.blank?
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
      Rails.logger.warn("SubmitManualBatchJob: no pages kept for #{filename} — skipping batch")
      return
    end

    cache_key = "web_manual_batch:#{result[:batch_id]}"
    Rails.cache.write(cache_key, result.merge(kb_doc_id: kb_doc_id, conv_session_id: conv_session_id), expires_in: 72.hours)

    IngestManualBatchResultsJob.set(wait: 5.minutes).perform_later(
      batch_id:        result[:batch_id],
      cache_key:       cache_key,
      attempt:         1
    )

    Rails.logger.info(
      "SubmitManualBatchJob: #{filename} → batch_id=#{result[:batch_id]} " \
      "kept=#{result[:kept_pages].size}/#{result[:total_pages]}"
    )
  rescue StandardError => e
    Rails.logger.error("SubmitManualBatchJob[#{filename}]: #{e.class}: #{e.message}")
    raise
  end
end
