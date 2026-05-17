# frozen_string_literal: true

# Thin broadcast wrapper for kb_sync ActionCable channel events.
# Centralises the broadcast contract so BedrockIngestionJob, CustomChunkingPipeline,
# and UploadAndSyncAttachmentsJob all emit identical payloads.
class KbSyncBroadcaster
  CHANNEL = "kb_sync"

  def self.failed(filenames:, reason: "error", message: nil)
    ActionCable.server.broadcast(CHANNEL, {
      status:    "failed",
      filenames: Array(filenames).compact,
      reason:    reason,
      message:   message.presence || I18n.t("rag.document_indexing_failed_message")
    })
  end

  def self.retrying(filenames:, attempt:, delay:)
    ActionCable.server.broadcast(CHANNEL, {
      status:    "retrying",
      filenames: Array(filenames).compact,
      attempt:   attempt,
      delay:     delay,
      message:   I18n.t("rag.upload_retrying_aurora")
    })
  end
end
