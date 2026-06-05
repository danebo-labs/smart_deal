# frozen_string_literal: true

# Thin broadcast wrapper for kb_sync ActionCable channel events.
# Centralises the broadcast contract so BedrockIngestionJob, CustomChunkingPipeline,
# and UploadAndSyncAttachmentsJob all emit identical payloads.
class KbSyncBroadcaster
  CHANNEL = "kb_sync"

  def self.failed(filenames:, reason: "error", message: nil, locale: nil)
    resolved_message = message.presence || I18n.with_locale(locale || :es) { I18n.t("rag.document_indexing_failed_message") }
    ActionCable.server.broadcast(CHANNEL, {
      status:    "failed",
      filenames: Array(filenames).compact,
      reason:    reason,
      message:   resolved_message
    })
  end

  def self.retrying(filenames:, attempt:, delay:, locale: nil)
    ActionCable.server.broadcast(CHANNEL, {
      status:    "retrying",
      filenames: Array(filenames).compact,
      attempt:   attempt,
      delay:     delay,
      message:   I18n.with_locale(locale || :es) { I18n.t("rag.upload_retrying_aurora") }
    })
  end
end
