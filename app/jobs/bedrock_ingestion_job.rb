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

  # @param conv_session_id   [Integer, nil] ConversationSession#id — for entity registration
  # @param web_v1_metadata   [Array<Hash>, nil] canonical_name + aliases per filename,
  #   built by CustomChunkingPipeline. When present, KbDocument enrichment uses this
  #   directly — no Bedrock retrieve call needed.
  # **_legacy_kwargs captures whatsapp_from/whatsapp_to from jobs already serialised
  # in Solid Queue before this deploy; they are silently ignored.
  def perform(ingestion_job_id, uploaded_filenames, kb_id: nil, data_source_id: nil,
              conv_session_id: nil, kb_document_ids: nil, started_at_iso: nil,
              web_v1_metadata: nil, locale: nil, account_id: nil, **_legacy_kwargs)
    @locale     = locale&.to_sym || :es
    @account_id = account_id
    return if ingestion_job_id.blank?

    I18n.with_locale(@locale) do
      if reenqueue_mode?
        perform_reenqueue(ingestion_job_id, uploaded_filenames,
                          kb_id: kb_id, data_source_id: data_source_id,
                          conv_session_id: conv_session_id, kb_document_ids: kb_document_ids,
                          started_at_iso: started_at_iso, web_v1_metadata: web_v1_metadata)
      else
        perform_legacy(ingestion_job_id, uploaded_filenames,
                       kb_id: kb_id, data_source_id: data_source_id,
                       conv_session_id: conv_session_id, kb_document_ids: kb_document_ids,
                       web_v1_metadata: web_v1_metadata)
      end
    end
  rescue StandardError => e
    Rails.logger.error("BedrockIngestionJob failed: #{e.class}: #{e.message}")
    Rails.logger.error(e.backtrace.first(10).join("\n"))
    I18n.with_locale(@locale || :es) { broadcast_failed(uploaded_filenames, "error", e.message) }
  end

  private

  def reenqueue_mode?
    ENV.fetch('INGESTION_REENQUEUE', 'false').to_s.downcase == 'true'
  end

  # Single status check + finalize-or-reenqueue. Frees the worker thread between
  # polls so other queued jobs (TrackBedrockQueryJob, TrackIngestionUsageJob, a
  # second concurrent upload) make progress while Bedrock is still indexing.
  def perform_reenqueue(ingestion_job_id, uploaded_filenames, kb_id:, data_source_id:, conv_session_id:, kb_document_ids:, started_at_iso:, web_v1_metadata:)
    started_at = parse_started_at(started_at_iso)
    raise Timeout::Error, "Ingestion #{ingestion_job_id} timed out" if Time.current - started_at > TIMEOUT

    service = IngestionStatusService.new(kb_id: kb_id, data_source_id: data_source_id)
    status  = service.job_status(ingestion_job_id)

    if status.in?(%w[COMPLETE FAILED STOPPED])
      finalize(ingestion_job_id, status, uploaded_filenames, service,
               kb_id: kb_id, data_source_id: data_source_id,
               conv_session_id: conv_session_id, kb_document_ids: kb_document_ids,
               web_v1_metadata: web_v1_metadata)
    else
      self.class.set(wait: POLL_INTERVAL).perform_later(
        ingestion_job_id, uploaded_filenames,
        kb_id:            kb_id,
        data_source_id:   data_source_id,
        conv_session_id:  conv_session_id,
        kb_document_ids:  kb_document_ids,
        started_at_iso:   started_at.iso8601,
        web_v1_metadata:  web_v1_metadata,
        locale:           @locale&.to_s,
        account_id:       @account_id
      )
    end
  end

  # Legacy path: one perform call blocks until terminal status (or TIMEOUT).
  def perform_legacy(ingestion_job_id, uploaded_filenames, kb_id:, data_source_id:, conv_session_id:, kb_document_ids:, web_v1_metadata:)
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
             conv_session_id: conv_session_id, kb_document_ids: kb_document_ids,
             web_v1_metadata: web_v1_metadata)
  end

  # Shared completion path for both legacy and re-enqueue modes.
  def finalize(ingestion_job_id, status, uploaded_filenames, service, kb_id:, data_source_id:, conv_session_id:, kb_document_ids:, web_v1_metadata:)
    service.clear_when_complete(ingestion_job_id)

    if status == "COMPLETE"
      notify_indexed(uploaded_filenames, kb_id: kb_id, conv_session_id: conv_session_id,
                     kb_document_ids: kb_document_ids, web_v1_metadata: web_v1_metadata)
      TrackIngestionUsageJob.perform_later(
        uploaded_filenames: Array(uploaded_filenames),
        ingestion_job_id:   ingestion_job_id,
        kb_id:              kb_id,
        data_source_id:     data_source_id,
        web_v1_metadata:    web_v1_metadata
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

  def broadcast_indexed(filename, result = nil)
    canonical       = result&.dig(:canonical_name).to_s.strip.presence || File.basename(filename, ".*").tr("_-", " ").strip
    aliases         = Array(result&.dig(:aliases)).first(5).map(&:to_s).compact_blank
    summary         = result&.dig(:summary).to_s.presence
    companion_offer = result&.dig(:companion_offer).to_s.presence
    partial_pages   = Array(result&.dig(:partial_pages)).compact
    processing_scope = result&.dig(:processing_scope).to_s.presence
    selected_pages   = Array(result&.dig(:selected_pages)).compact
    total_pages      = result&.dig(:total_pages)

    message = if processing_scope == ManualUrgentTriageService::PROCESSING_SCOPE
      pages_label = selected_pages.join(", ")
      I18n.t(
        "rag.manual_urgent_pages_indexed",
        name: canonical,
        pages: pages_label,
        total: total_pages,
        default: "✅ #{canonical}\nPáginas urgentes listas: #{pages_label}. El manual completo sigue procesándose."
      )
    elsif aliases.any?
      I18n.t("rag.whatsapp_indexed_with_aliases",
             name: canonical, aliases: aliases.join(", "),
             default: "✅ #{canonical}\n#{I18n.t('rag.indexed_ask_me_about', default: 'Consúltame por')}: #{aliases.join(', ')}")
    else
      I18n.t("rag.whatsapp_indexed_canonical_only",
             name: canonical,
             default: "✅ #{canonical}")
    end

    if partial_pages.any?
      message = "#{message}\n#{I18n.t('rag.partial_pages_warning', pages: partial_pages.join(', '))}"
    end

    ActionCable.server.broadcast(KbSyncBroadcaster.channel_for(@account_id), {
      status:          "indexed",
      filenames:       [ filename ],
      canonical_name:  canonical,
      aliases:         aliases,
      summary:         summary,
      companion_offer: companion_offer,
      partial_pages:   partial_pages,
      processing_scope: processing_scope,
      selected_pages:   selected_pages,
      total_pages:      total_pages,
      message:         message
    })
  end

  # Enriches KbDocuments and registers session entities for each uploaded file.
  # Identity (canonical_name + aliases) comes from web_v1_metadata when present —
  # no Bedrock retrieve call required. Falls back to filename stem when metadata
  # is absent (e.g. jobs serialised before a deploy, or async batch uploads still parsing).
  def notify_indexed(uploaded_filenames, kb_id:, conv_session_id:, kb_document_ids: nil, web_v1_metadata: nil)
    session = conv_session_id ? ConversationSession.find_by(id: conv_session_id) : nil
    ids     = Array(kb_document_ids)
    lookup  = Array(web_v1_metadata).index_by { |m| m["filename"] }

    Array(uploaded_filenames).each_with_index do |filename, idx|
      result = lookup[filename]&.then do |m|
        {
          canonical_name:  m["canonical_name"],
          aliases:         Array(m["aliases"]),
          summary:         m["summary"].to_s.presence,
          companion_offer: m["companion_offer"].to_s.presence,
          partial_pages:   Array(m["partial_pages"]),
          processing_scope: m["processing_scope"].to_s.presence,
          selected_pages:   Array(m["selected_pages"]),
          total_pages:      m["total_pages"],
          web_manual_batch_id: m["web_manual_batch_id"]
        }
      end
      kb_doc = ids[idx] ? KbDocument.find_by(id: ids[idx]) : nil
      Rails.logger.warn("BedrockIngestionJob: kb_document_id=#{ids[idx]} not found") if ids.any? && kb_doc.nil?
      enrich_kb_document(filename, result, kb_doc: kb_doc)
      register_entity(session, filename, result, kb_doc: kb_doc) if session
      mark_web_manual_batch_complete(result)
      broadcast_indexed(filename, result)
    end
  end

  def mark_web_manual_batch_complete(result)
    id = result&.dig(:web_manual_batch_id)
    return if id.blank?

    attrs = if result[:processing_scope] == ManualUrgentTriageService::PROCESSING_SCOPE
      {
        urgent_status: "complete",
        urgent_completed_at: Time.current,
        urgent_error_message: nil
      }
    else
      {
        status: "complete",
        completed_at: Time.current,
        error_message: nil
      }
    end

    WebManualBatch.where(id: id).update_all(attrs)
  rescue StandardError => e
    Rails.logger.warn("BedrockIngestionJob: failed to mark WebManualBatch complete — #{e.message}")
  end

  def register_entity(session, filename, result, kb_doc:)
    if kb_doc.nil?
      Rails.logger.warn("BedrockIngestionJob: register_entity skipped — no KbDocument for #{filename}")
      return
    end

    if session.pin_kb_document!(kb_doc)
      Rails.logger.info("BedrockIngestionJob: auto-pinned KbDocument #{kb_doc.id} (#{filename}) to session #{session.id}")
    end

    persist_to_technician_documents(session, filename, result, kb_doc.display_s3_uri(KbDocument::KB_BUCKET))
  end

  # Enriches the pre-created KbDocument row with the canonical name + aliases from
  # web_v1_metadata. If no kb_doc is provided, skips enrichment gracefully.
  def enrich_kb_document(filename, result, kb_doc: nil)
    return if kb_doc.nil?

    stem      = File.basename(filename, ".*").tr("_-", " ").strip
    canonical = result&.dig(:canonical_name).to_s.strip.presence

    if canonical.blank?
      Rails.logger.warn("BedrockIngestionJob: canonical_name blank for #{filename} — falling back to display_name or stem")
    end

    kb_doc.display_name = canonical || kb_doc.display_name.presence || stem

    alias_candidates = Array(kb_doc.aliases) + Array(result&.dig(:aliases)) + [ stem ]
    kb_doc.aliases = alias_candidates
                       .map { |a| a.to_s.strip }
                       .compact_blank
                       .reject { |a| a.casecmp?(kb_doc.display_name.to_s) }
                       .uniq
                       .first(15)
    kb_doc.save!
    Rails.logger.info("BedrockIngestionJob: enriched KbDocument #{kb_doc.s3_key} → '#{kb_doc.display_name}' (aliases=#{kb_doc.aliases.size})")
  rescue StandardError => e
    Rails.logger.warn("BedrockIngestionJob: failed to enrich KbDocument for #{filename} — #{e.message}")
  end

  def persist_to_technician_documents(session, filename, result, s3_uri)
    return unless session

    canonical = result ? result[:canonical_name] : filename.sub(/\.[^.]+\z/, '')
    TechnicianDocument.upsert_from_entity(
      identifier:     session.identifier,
      channel:        session.channel,
      canonical_name: canonical,
      metadata: {
        "aliases"     => result ? result[:aliases] : [],
        "wa_filename" => filename,
        "source_uri"  => s3_uri,
        "doc_type"    => "field_image"
      }
    )
    Rails.logger.info("BedrockIngestionJob: persisted TechnicianDocument '#{canonical}' for #{session.identifier}")
  rescue StandardError => e
    Rails.logger.warn("BedrockIngestionJob: failed to persist TechnicianDocument for #{filename} — #{e.message}")
  end

  def broadcast_failed(filenames, reason, message = nil)
    KbSyncBroadcaster.failed(filenames: filenames, reason: reason, message: message, account_id: @account_id)
  end
end
