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

  # @param whatsapp_from   [String, nil] Twilio sender number (our number) — for WhatsApp notify
  # @param whatsapp_to     [String, nil] Recipient (end user) — for WhatsApp notify
  # @param conv_session_id [Integer, nil] ConversationSession#id — for alias registration
  def perform(ingestion_job_id, uploaded_filenames, kb_id: nil, data_source_id: nil,
              whatsapp_from: nil, whatsapp_to: nil, conv_session_id: nil)
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
      notify_indexed(uploaded_filenames, kb_id: kb_id, whatsapp_from: whatsapp_from,
                     whatsapp_to: whatsapp_to, conv_session_id: conv_session_id)
    else
      reasons = status == "FAILED" ? service.failure_reasons(ingestion_job_id) : []
      message = ingestion_failure_message(reasons)
      broadcast_failed(uploaded_filenames, status, message)
      notify_whatsapp(whatsapp_from, whatsapp_to, I18n.t('rag.whatsapp_indexing_failed'))
    end
  rescue StandardError => e
    Rails.logger.error("BedrockIngestionJob failed: #{e.message}")
    broadcast_failed(uploaded_filenames, "error", e.message)
    notify_whatsapp(whatsapp_from, whatsapp_to, I18n.t('rag.whatsapp_indexing_failed'))
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
    filenames = Array(filenames).compact
    message = if filenames.size == 1
      I18n.t("rag.document_indexed_message", filename: filenames.first)
    else
      I18n.t("rag.documents_indexed_message", count: filenames.size)
    end

    ActionCable.server.broadcast("kb_sync", {
      status: "indexed",
      filenames: filenames,
      message: message
    })
  end

  def notify_indexed(uploaded_filenames, kb_id:, whatsapp_from:, whatsapp_to:, conv_session_id:)
    session = conv_session_id ? ConversationSession.find_by(id: conv_session_id) : nil

    Array(uploaded_filenames).each do |wa_filename|
      result = extract_aliases(wa_filename, kb_id) if session
      register_entity(session, wa_filename, result) if session
      body = build_indexed_notification(wa_filename, result)
      notify_whatsapp(whatsapp_from, whatsapp_to, body)
    end
  end

  def extract_aliases(wa_filename, kb_id)
    effective_kb_id = kb_id.presence ||
                      ENV.fetch('BEDROCK_KNOWLEDGE_BASE_ID', nil).presence ||
                      Rails.application.credentials.dig(:bedrock, :knowledge_base_id)
    return nil unless effective_kb_id

    ChunkAliasExtractor.new(kb_id: effective_kb_id).call(wa_filename)
  rescue StandardError => e
    Rails.logger.error("BedrockIngestionJob: alias extraction failed for #{wa_filename} — #{e.message}")
    nil
  end

  def register_entity(session, wa_filename, result)
    stem   = wa_filename.sub(/\.[^.]+\z/, '')
    s3_uri = build_s3_uri_for_filename(wa_filename)

    if result
      key = result[:canonical_name]
      all_aliases = [ wa_filename, stem ] + result[:aliases]
      session.add_entity_with_aliases(
        key,
        all_aliases,
        "source"            => "image_upload",
        "doc_type"          => "field_image",
        "wa_filename"       => wa_filename,
        "source_uri"        => s3_uri,
        "extraction_method" => "chunk_aliases"
      )
      Rails.logger.info("BedrockIngestionJob: registered entity '#{key}' with #{all_aliases.size} aliases for #{wa_filename}")
    else
      session.add_entity_with_aliases(
        stem,
        [ wa_filename ],
        "source"            => "image_upload",
        "doc_type"          => "field_image",
        "wa_filename"       => wa_filename,
        "source_uri"        => s3_uri,
        "extraction_method" => "pending_first_query"
      )
      Rails.logger.info("BedrockIngestionJob: registered placeholder entity '#{stem}' for #{wa_filename}")
    end
  end

  def build_s3_uri_for_filename(filename)
    m      = filename.match(/\A(?:wa|chat)_(\d{4})(\d{2})(\d{2})_/)
    date   = m ? "#{m[1]}-#{m[2]}-#{m[3]}" : Date.current.iso8601
    bucket = ENV.fetch('KNOWLEDGE_BASE_S3_BUCKET', 'multimodal-source-destination')
    "s3://#{bucket}/uploads/#{date}/#{filename}"
  end

  MAX_WHATSAPP_BODY = 1500

  def build_indexed_notification(wa_filename, result)
    body = if result
      name    = result[:canonical_name]
      aliases = result[:aliases].first(5).map { |a| a.truncate(60) }.join(", ")
      I18n.t('rag.whatsapp_indexed_with_aliases',
             name: name, aliases: aliases,
             default: "✅ #{name}\nConsúltame por: #{aliases}")
    else
      I18n.t('rag.whatsapp_indexed_generic',
             filename: wa_filename,
             default: "✅ Documento procesado.\nArchivo: #{wa_filename}\nPregúntame sobre este documento.")
    end
    body.truncate(MAX_WHATSAPP_BODY)
  end

  def notify_whatsapp(from, to, body)
    return unless from.present? && to.present?

    Twilio::REST::Client
      .new(ENV.fetch('TWILIO_ACCOUNT_SID'), ENV.fetch('TWILIO_AUTH_TOKEN'))
      .messages.create(from: from, to: to, body: body)
  rescue StandardError => e
    Rails.logger.error("BedrockIngestionJob: WhatsApp notify failed — #{e.message}")
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
