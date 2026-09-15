# frozen_string_literal: true

# Thin broadcast wrapper for kb_sync ActionCable channel events.
# Centralises the broadcast contract so BedrockIngestionJob, CustomChunkingPipeline,
# and UploadAndSyncAttachmentsJob all emit identical payloads.
class KbSyncBroadcaster
  CHANNEL = "kb_sync"

  def self.channel_for(account_id)
    account_id ? "account:#{account_id}:kb_sync" : CHANNEL
  end

  def self.failed(filenames:, account_id: nil, reason: "error", message: nil, locale: nil, correlation_id: nil)
    resolved_message = message.presence || I18n.with_locale(locale || :es) { I18n.t("rag.document_indexing_failed_message") }
    ActionCable.server.broadcast(channel_for(account_id), {
      status:    "failed",
      filenames: Array(filenames).compact,
      reason:    reason,
      message:   resolved_message,
      correlation_id: correlation_id
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

  # @param pending_question [Boolean] true when a photo-question RAG turn will
  #   follow on the same correlation_id (see .photo_question_answered) — the
  #   client keeps its pending state instead of clearing it on this broadcast.
  #   Omitted from the payload when false, so the photo-only route (the common
  #   case) does not carry an extra key over Cable.
  def self.photo_analyzed(filenames:, analysis:, canonical_name:, aliases:, account_id: nil, correlation_id: nil,
                          field_photo_id: nil, thumbnail_url: nil, response_locale: nil, pending_question: false)
    payload = {
      status: "photo_analyzed",
      filenames: Array(filenames).compact,
      summary: analysis,
      canonical_name: canonical_name,
      aliases: Array(aliases).compact,
      correlation_id: correlation_id,
      field_photo_id: field_photo_id,
      thumbnail_url: thumbnail_url,
      response_locale: response_locale
    }
    payload[:pending_question] = true if pending_question
    ActionCable.server.broadcast(channel_for(account_id), payload)
  end

  # Second half of a photo + question turn: the vision bubble already went out
  # with pending_question: true, this fills the placeholder the client kept.
  def self.photo_question_answered(answer:, citations:, account_id: nil, correlation_id: nil, response_locale: nil)
    ActionCable.server.broadcast(channel_for(account_id), {
      status: "photo_question_answered",
      correlation_id: correlation_id,
      answer: answer,
      citations: Array(citations),
      response_locale: response_locale
    })
  end
end
