# frozen_string_literal: true

# Replaces the bare `Thread.new { upload_and_sync_attachments }` previously
# spawned from QueryOrchestratorService#execute. The thread:
#   * checked out an AR connection but never released it explicitly;
#   * could be killed by Puma graceful-shutdown mid-S3-upload;
#   * had no retry, no observability, no metrics lane.
#
# As a Solid Queue job, the upload + KB sync runs on the `default` lane with
# a clean AR connection lifecycle and is visible in Mission Control.
#
# Idempotency: KbDocument creation uses find_or_create_by!(s3_key) and the
# downstream BedrockIngestionJob is itself idempotent (rescues RecordNotUnique
# and re-finds), so a retried job never double-pins or double-creates.
#
# Payload safety: the controller MUST pre-process attachments through
# `prepare_for_async!` (see below) — raw binary fields are stripped/base64
# wrapped so the JSONB `solid_queue_jobs.arguments` column accepts them.
class UploadAndSyncAttachmentsJob < ApplicationJob
  queue_as :default

  # Suppress argument logging: images_payload contains base64-encoded image bytes
  # which produce 75-150 KB log lines per upload (in development.log AND in
  # solid_queue_jobs.arguments). Drowns real signal during regression testing.
  self.log_arguments = false

  # @param images_payload    [Array<Hash>] sanitized image payloads (see prepare_for_async!)
  # @param documents_payload [Array<Hash>] sanitized document payloads
  # @param conv_session_id   [Integer, nil] ConversationSession#id for entity registration
  # @param tenant_id         [Integer, nil] Tenant#id for KB selection
  def perform(images_payload:, documents_payload:, conv_session_id: nil, tenant_id: nil)
    images    = restore_images(Array(images_payload))
    documents = Array(documents_payload).map { |d| d.transform_keys(&:to_sym) }
    tenant    = tenant_id ? Tenant.find_by(id: tenant_id) : nil
    session   = conv_session_id ? ConversationSession.find_by(id: conv_session_id) : nil

    QueryOrchestratorService
      .new("", images: images, documents: documents, tenant: tenant, conv_session: session)
      .send(:upload_and_sync_attachments)
  rescue StandardError => e
    Rails.logger.error("UploadAndSyncAttachmentsJob failed: #{e.message}")
    Rails.logger.error(e.backtrace.first(10).join("\n"))
  end

  # Strips/wraps raw binary fields so the payload is JSON-safe AND smaller.
  # Removes :binary (the orchestrator falls back to Base64.decode64(:data));
  # base64-wraps :thumbnail_binary so the thumbnail still survives the trip.
  #
  # Round-trip invariants tested in test/jobs/upload_and_sync_attachments_job_test.rb.
  #
  # @param images [Array<Hash>] same shape RagController#compress_images produces
  # @return [Array<Hash>] mutated copies safe for ActiveJob serialization
  def self.prepare_images_for_async(images)
    Array(images).map do |img|
      h = img.dup
      h.delete(:binary)
      h.delete("binary")
      thumb = h.delete(:thumbnail_binary) || h.delete("thumbnail_binary")
      h[:thumbnail_data] = Base64.strict_encode64(thumb) if thumb.is_a?(String) && thumb.bytesize.positive?
      h.deep_symbolize_keys
    end
  end

  private

  def restore_images(payloads)
    payloads.map do |raw|
      img = raw.transform_keys(&:to_sym)
      if img[:thumbnail_data].present?
        img[:thumbnail_binary] = Base64.decode64(img[:thumbnail_data])
        img.delete(:thumbnail_data)
      end
      img
    end
  end
end
