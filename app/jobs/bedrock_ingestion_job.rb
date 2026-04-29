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
      notify_indexed(uploaded_filenames, kb_id: kb_id, whatsapp_from: whatsapp_from,
                     whatsapp_to: whatsapp_to, conv_session_id: conv_session_id)
      TrackIngestionUsageJob.perform_later(
        uploaded_filenames: Array(uploaded_filenames),
        ingestion_job_id:   ingestion_job_id,
        kb_id:              kb_id,
        data_source_id:     data_source_id
      )
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

  # Broadcasts per-file indexing completion to web clients via ActionCable.
  # Called after canonical name / alias extraction so the UI can display
  # the human-readable name and known aliases — same richness as WhatsApp.
  def broadcast_indexed(filename, result = nil)
    canonical = result&.dig(:canonical_name).to_s.strip.presence || File.basename(filename, ".*").tr("_-", " ").strip
    aliases   = Array(result&.dig(:aliases)).first(5).map(&:to_s).compact_blank

    message = if aliases.any?
      I18n.t("rag.whatsapp_indexed_with_aliases",
             name: canonical, aliases: aliases.join(", "),
             default: "✅ #{canonical}\n#{I18n.t('rag.indexed_ask_me_about', default: 'Consúltame por')}: #{aliases.join(', ')}")
    else
      I18n.t("rag.whatsapp_indexed_canonical_only",
             name: canonical,
             default: "✅ #{canonical}")
    end

    ActionCable.server.broadcast("kb_sync", {
      status:         "indexed",
      filenames:      [ filename ],
      canonical_name: canonical,
      aliases:        aliases,
      message:        message
    })
  end

  def notify_indexed(uploaded_filenames, kb_id:, whatsapp_from:, whatsapp_to:, conv_session_id:)
    session = conv_session_id ? ConversationSession.find_by(id: conv_session_id) : nil

    Array(uploaded_filenames).each do |wa_filename|
      # Alias extraction requires a session (guards against unnecessary KB queries on sessionless calls).
      result = session ? extract_aliases(wa_filename, kb_id) : nil
      upsert_kb_document(wa_filename, result)
      register_entity(session, wa_filename, result) if session
      body = build_indexed_notification(wa_filename, result)
      broadcast_indexed(wa_filename, result)
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

    persist_to_technician_documents(session, wa_filename, result, s3_uri)
  end

  # Creates the KbDocument row only after Bedrock confirms COMPLETE.
  # Uses find_or_initialize_by so re-runs are idempotent (e.g. manual retries).
  #
  # Naming rules (see KbDocument#display_name_promotable? for the full criterion):
  #   - Web uploads (human-chosen filename): the stem is the display_name and
  #     is NEVER overwritten. Opus canonical is stored as an alias.
  #   - WhatsApp/chat uploads (machine-generated filename): the Opus canonical
  #     replaces the machine stem on first extraction; stem is NOT aliased
  #     (no human searches for "wa 20260410 ...").
  def upsert_kb_document(wa_filename, result)
    m      = wa_filename.match(/\A(?:wa|chat)_(\d{4})(\d{2})(\d{2})_/)
    date   = m ? "#{m[1]}-#{m[2]}-#{m[3]}" : Date.current.iso8601
    s3_key = "uploads/#{date}/#{wa_filename}"
    stem   = File.basename(wa_filename, ".*").tr("_-", " ").strip
    canonical = result&.dig(:canonical_name).to_s.strip.presence
    machine_name = KbDocument.machine_generated_filename?(wa_filename)

    kb_doc = KbDocument.find_or_initialize_by(s3_key: s3_key)

    if machine_name
      # wa_/chat_: promote Opus canonical while display_name is the placeholder stem.
      kb_doc.display_name = canonical if canonical.present? && kb_doc.display_name_promotable?
      kb_doc.display_name ||= stem
    else
      # Human-chosen filename: preserve it as display_name; canonical becomes an alias.
      kb_doc.display_name ||= stem
    end

    extra_aliases = [ canonical ]
    extra_aliases << stem unless machine_name
    kb_doc.aliases = (Array(kb_doc.aliases) + extra_aliases + Array(result&.dig(:aliases)))
                       .map { |a| a.to_s.strip }
                       .compact_blank
                       .uniq
                       .first(15)
    kb_doc.save!
    Rails.logger.info("BedrockIngestionJob: upserted KbDocument #{s3_key} → '#{kb_doc.display_name}' (machine_name=#{machine_name}, aliases=#{kb_doc.aliases.size})")
  rescue StandardError => e
    Rails.logger.warn("BedrockIngestionJob: failed to upsert KbDocument for #{wa_filename} — #{e.message}")
  end

  def persist_to_technician_documents(session, wa_filename, result, s3_uri)
    return unless session

    canonical = result ? result[:canonical_name] : wa_filename.sub(/\.[^.]+\z/, '')
    TechnicianDocument.upsert_from_entity(
      identifier:     session.identifier,
      channel:        session.channel,
      canonical_name: canonical,
      metadata: {
        "aliases"     => result ? result[:aliases] : [],
        "wa_filename" => wa_filename,
        "source_uri"  => s3_uri,
        "doc_type"    => "field_image"
      }
    )
    Rails.logger.info("BedrockIngestionJob: persisted TechnicianDocument '#{canonical}' for #{session.identifier}")
  rescue StandardError => e
    Rails.logger.warn("BedrockIngestionJob: failed to persist TechnicianDocument for #{wa_filename} — #{e.message}")
  end

  def build_s3_uri_for_filename(filename)
    m      = filename.match(/\A(?:wa|chat)_(\d{4})(\d{2})(\d{2})_/)
    date   = m ? "#{m[1]}-#{m[2]}-#{m[3]}" : Date.current.iso8601
    bucket = ENV.fetch('KNOWLEDGE_BASE_S3_BUCKET', 'multimodal-source-destination')
    "s3://#{bucket}/uploads/#{date}/#{filename}"
  end

  MAX_WHATSAPP_BODY = 1500

  def build_indexed_notification(wa_filename, result)
    body = if result && result[:canonical_name].present?
      name    = result[:canonical_name]
      aliases = Array(result[:aliases]).first(5).map { |a| a.truncate(60) }
      if aliases.any?
        I18n.t('rag.whatsapp_indexed_with_aliases',
               name: name, aliases: aliases.join(", "),
               default: "✅ #{name}\nConsúltame por: #{aliases.join(', ')}")
      else
        I18n.t('rag.whatsapp_indexed_canonical_only',
               name: name,
               default: "✅ #{name}\nPregúntame sobre este documento.")
      end
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
