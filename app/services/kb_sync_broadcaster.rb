# frozen_string_literal: true

# Thin broadcast wrapper for kb_sync ActionCable channel events.
# Centralises the broadcast contract so BedrockIngestionJob, CustomChunkingPipeline,
# and UploadAndSyncAttachmentsJob all emit identical payloads.
class KbSyncBroadcaster
  CHANNEL = "kb_sync"

  def self.channel_for(account_id)
    account_id ? "account:#{account_id}:kb_sync" : CHANNEL
  end

  def self.failed(filenames:, account_id: nil, reason: "error", message: nil, locale: nil)
    resolved_message = message.presence || I18n.with_locale(locale || :es) { I18n.t("rag.document_indexing_failed_message") }
    ActionCable.server.broadcast(channel_for(account_id), {
      status:    "failed",
      filenames: Array(filenames).compact,
      reason:    reason,
      message:   resolved_message
    })
  end

  def self.retrying(filenames:, attempt:, delay:, account_id: nil, locale: nil)
    ActionCable.server.broadcast(channel_for(account_id), {
      status:    "retrying",
      filenames: Array(filenames).compact,
      attempt:   attempt,
      delay:     delay,
      message:   I18n.with_locale(locale || :es) { I18n.t("rag.upload_retrying_aurora") }
    })
  end

  def self.partial_failed(filenames:, message:, account_id: nil, reason: "manual_urgent_triage_failed")
    ActionCable.server.broadcast(channel_for(account_id), {
      status:    "partial_failed",
      filenames: Array(filenames).compact,
      reason:    reason,
      message:   message
    })
  end
end
