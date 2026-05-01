# frozen_string_literal: true

# Monitors a Bedrock Knowledge Base ingestion job until completion, then broadcasts
# the result via ActionCable so the UI can update spinners to check marks.
#
# Two execution modes (gated by INGESTION_REENQUEUE):
#   * legacy (default): one perform call blocks on `loop { sleep POLL_INTERVAL }`
#     until terminal status. Simple but holds a Solid Queue worker thread for up
#     to TIMEOUT minutes.
#   * re-enqueue: one perform call does a single status check and, when the job
#     is still pending, re-enqueues itself with `wait: POLL_INTERVAL`. Frees the
#     worker thread between polls so concurrent uploads + tracking jobs share
#     the lane fairly.
#
# Activate in production by setting INGESTION_REENQUEUE=true AFTER draining the
# queue (or accept that any in-flight legacy jobs keep blocking until they hit a
# terminal status).
class BedrockIngestionJob < ApplicationJob
  # Dedicated lane (see config/queue.yml). Isolates long-running poll jobs from
  # the default lane that hosts TrackBedrockQueryJob → metrics-footer broadcast.
  queue_as :ingestion

  # Args are small (ids + filenames), but `kb_document_ids` and friends still
  # generate noisy lines for every poll re-enqueue. Disable for log clarity.
  self.log_arguments = false

  retry_on Timeout::Error, wait: :polynomially_longer, attempts: 2
  discard_on ActiveJob::DeserializationError

  POLL_INTERVAL = 5.seconds
  TIMEOUT = 15.minutes

  # @param conv_session_id [Integer, nil] ConversationSession#id — for alias registration
  # @param started_at_iso [String, nil] ISO8601 timestamp of the FIRST perform; only used
  #   in re-enqueue mode to enforce TIMEOUT across re-enqueues.
  # whatsapp_from / whatsapp_to accepted but ignored — WA channel disabled for MVP.
  # Kept in signature so any serialized jobs still in Solid Queue deserialize cleanly.
  def perform(ingestion_job_id, uploaded_filenames, kb_id: nil, data_source_id: nil,
              whatsapp_from: nil, whatsapp_to: nil, conv_session_id: nil,
              kb_document_ids: nil, started_at_iso: nil) # rubocop:disable Lint/UnusedMethodArgument
    return if ingestion_job_id.blank?

    if reenqueue_mode?
      perform_reenqueue(ingestion_job_id, uploaded_filenames,
                        kb_id: kb_id, data_source_id: data_source_id,
                        conv_session_id: conv_session_id, kb_document_ids: kb_document_ids,
                        started_at_iso: started_at_iso)
    else
      perform_legacy(ingestion_job_id, uploaded_filenames,
                     kb_id: kb_id, data_source_id: data_source_id,
                     conv_session_id: conv_session_id, kb_document_ids: kb_document_ids)
    end
  rescue StandardError => e
    Rails.logger.error("BedrockIngestionJob failed: #{e.message}")
    broadcast_failed(uploaded_filenames, "error", e.message)
  end

  private

  def reenqueue_mode?
    ENV.fetch('INGESTION_REENQUEUE', 'false').to_s.downcase == 'true'
  end

  # Single status check + finalize-or-reenqueue. Frees the worker thread between
  # polls so other queued jobs (TrackBedrockQueryJob, TrackIngestionUsageJob, a
  # second concurrent upload) make progress while Bedrock is still indexing.
  def perform_reenqueue(ingestion_job_id, uploaded_filenames, kb_id:, data_source_id:, conv_session_id:, kb_document_ids:, started_at_iso:)
    started_at = parse_started_at(started_at_iso)
    raise Timeout::Error, "Ingestion #{ingestion_job_id} timed out" if Time.current - started_at > TIMEOUT

    service = IngestionStatusService.new(kb_id: kb_id, data_source_id: data_source_id)
    status  = service.job_status(ingestion_job_id)

    if status.in?(%w[COMPLETE FAILED STOPPED])
      finalize(ingestion_job_id, status, uploaded_filenames, service,
               kb_id: kb_id, data_source_id: data_source_id,
               conv_session_id: conv_session_id, kb_document_ids: kb_document_ids)
    else
      self.class.set(wait: POLL_INTERVAL).perform_later(
        ingestion_job_id, uploaded_filenames,
        kb_id:           kb_id,
        data_source_id:  data_source_id,
        conv_session_id: conv_session_id,
        kb_document_ids: kb_document_ids,
        started_at_iso:  started_at.iso8601
      )
    end
  end

  # Legacy path: one perform call blocks until terminal status (or TIMEOUT).
  def perform_legacy(ingestion_job_id, uploaded_filenames, kb_id:, data_source_id:, conv_session_id:, kb_document_ids:)
    service = IngestionStatusService.new(kb_id: kb_id, data_source_id: data_source_id)
    started_at = Time.current

    loop do
      raise Timeout::Error, "Ingestion job #{ingestion_job_id} timed out" if Time.current - started_at > TIMEOUT

      status = service.job_status(ingestion_job_id)
      break if status.in?(%w[COMPLETE FAILED STOPPED])

      sleep POLL_INTERVAL
    end

    status = service.job_status(ingestion_job_id)
    finalize(ingestion_job_id, status, uploaded_filenames, service,
             kb_id: kb_id, data_source_id: data_source_id,
             conv_session_id: conv_session_id, kb_document_ids: kb_document_ids)
  end

  # Shared completion path for both legacy and re-enqueue modes.
  def finalize(ingestion_job_id, status, uploaded_filenames, service, kb_id:, data_source_id:, conv_session_id:, kb_document_ids:)
    service.clear_when_complete(ingestion_job_id)

    if status == "COMPLETE"
      notify_indexed(uploaded_filenames, kb_id: kb_id, conv_session_id: conv_session_id, kb_document_ids: kb_document_ids)
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
    end
  end

  def parse_started_at(iso)
    iso.present? ? Time.zone.parse(iso) : Time.current
  end

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

  def notify_indexed(uploaded_filenames, kb_id:, conv_session_id:, kb_document_ids: nil)
    session = conv_session_id ? ConversationSession.find_by(id: conv_session_id) : nil
    ids     = Array(kb_document_ids)

    Array(uploaded_filenames).each_with_index do |filename, idx|
      result = session ? extract_aliases(filename, kb_id) : nil
      kb_doc = ids[idx] ? KbDocument.find_by(id: ids[idx]) : nil
      if ids.any? && kb_doc.nil?
        Rails.logger.warn("BedrockIngestionJob: kb_document_id=#{ids[idx]} not found; falling back to filename lookup")
      end
      enrich_kb_document(filename, result, kb_doc: kb_doc)
      register_entity(session, filename, result, kb_doc: kb_doc) if session
      broadcast_indexed(filename, result)
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

  def register_entity(session, wa_filename, result, kb_doc:)
    if kb_doc.nil?
      Rails.logger.warn("BedrockIngestionJob: register_entity skipped — no KbDocument for #{wa_filename}")
      return
    end

    if session.pin_kb_document!(kb_doc)
      Rails.logger.info("BedrockIngestionJob: auto-pinned KbDocument #{kb_doc.id} (#{wa_filename}) to session #{session.id}")
    end

    persist_to_technician_documents(session, wa_filename, result, kb_doc.display_s3_uri(KbDocument::KB_BUCKET))
  end

  # Enriches the pre-created KbDocument row with the Opus canonical name + aliases.
  # Policy: canonical always wins over the stored stem (web + WhatsApp gallery +
  # chat uploads). The original filename stem (and machine-generated stems) are
  # preserved as aliases so the resolver still matches either.
  def enrich_kb_document(wa_filename, result, kb_doc: nil)
    kb_doc ||= legacy_lookup_or_initialize(wa_filename)
    return if kb_doc.nil?

    stem      = File.basename(wa_filename, ".*").tr("_-", " ").strip
    canonical = result&.dig(:canonical_name).to_s.strip.presence
    machine   = KbDocument.machine_generated_filename?(wa_filename)

    kb_doc.display_name = canonical || kb_doc.display_name.presence || stem

    alias_candidates = Array(kb_doc.aliases) + Array(result&.dig(:aliases))
    alias_candidates << stem unless machine  # never surface wa_*/chat_* stems to users

    kb_doc.aliases = alias_candidates
                       .map { |a| a.to_s.strip }
                       .compact_blank
                       .reject { |a| a.casecmp?(kb_doc.display_name.to_s) }
                       .uniq
                       .first(15)
    kb_doc.save!
    Rails.logger.info("BedrockIngestionJob: enriched KbDocument #{kb_doc.s3_key} → '#{kb_doc.display_name}' (machine=#{machine}, aliases=#{kb_doc.aliases.size})")
  rescue StandardError => e
    Rails.logger.warn("BedrockIngestionJob: failed to enrich KbDocument for #{wa_filename} — #{e.message}")
  end

  # Used only for jobs already serialised in Solid Queue before this change.
  def legacy_lookup_or_initialize(wa_filename)
    m    = wa_filename.match(/\A(?:wa|chat)_(\d{4})(\d{2})(\d{2})_/)
    date = m ? "#{m[1]}-#{m[2]}-#{m[3]}" : Date.current.iso8601
    KbDocument.find_or_initialize_by(s3_key: "uploads/#{date}/#{wa_filename}")
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

  def broadcast_failed(filenames, reason, message = nil)
    ActionCable.server.broadcast("kb_sync", {
      status: "failed",
      filenames: Array(filenames).compact,
      reason: reason,
      message: message.presence || I18n.t("rag.document_indexing_failed_message")
    })
  end
end
