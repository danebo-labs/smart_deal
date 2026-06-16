# frozen_string_literal: true

# Orchestrates the web custom chunking path for all attachments in one request:
#   1. Upload each file to S3 (creates KbDocument).
#   2. Route and parse each file:
#      - Images + Office → SingleFileChunkingService (sync).
#      - Short PDFs (page_count <= sync threshold) → sync.
#      - Long PDFs → SubmitManualBatchJob (async Batch).
#   3. Trigger BulkKbSyncService + BedrockIngestionJob only for files with chunks
#      ready now. Long PDFs sync after Batch results are parsed.
#
# On error: propagates to the calling job (UploadAndSyncAttachmentsJob), which broadcasts
# KbSyncBroadcaster.failed and lets Solid Queue retry. No legacy OWRPGSX6XK fallback.
class CustomChunkingPipeline
  OFFICE_EXTENSIONS = FileMultimodalRouter::OFFICE_EXTENSIONS
  PDF_CONTENT_TYPE  = "application/pdf"

  # Short PDFs (≤ SYNC_PAGES by default) parse sync; longer PDFs route to Batch.
  # Override with WEB_SYNC_PDF_PAGE_THRESHOLD for controlled rollout.
  SYNC_PAGES = 2

  # @param images       [Array<Hash>] same shape as QOS @images
  # @param documents    [Array<Hash>] same shape as QOS @documents
  # @param conv_session [ConversationSession, nil]
  # @param tenant       [Tenant, nil]
  # @param locale       [String, nil] ISO 639-1 — forwarded to SingleFileChunkingService for image summary
  # @param urgent       [Boolean] retained for caller compatibility. Long manual
  #                     routing is automatic; emergency triage is handled separately.
  def initialize(images:, documents:, conv_session: nil, tenant: nil, locale: nil, urgent: false)
    @images         = Array(images)
    @documents      = Array(documents)
    @conv_session   = conv_session
    @tenant         = tenant
    @locale         = locale
    @urgent         = urgent
    @uploaded_filenames   = []
    @ready_filenames      = []
    @ready_kb_document_ids = []
    @ready_web_v1_metadata = []
  end

  # @return [Array<String>] successfully uploaded original filenames
  def run!
    s3 = S3DocumentsService.new
    upload_and_chunk_all(s3)
    return [] if @uploaded_filenames.empty?

    return @uploaded_filenames if @ready_filenames.empty?

    result = BulkKbSyncService.new.sync!(uploaded_filenames: @ready_filenames, locale: @locale)
    if result.present?
      BedrockIngestionJob.perform_later(
        result[:job_id],
        @ready_filenames,
        kb_id:           result[:kb_id],
        data_source_id:  result[:data_source_id],
        conv_session_id: @conv_session&.id,
        kb_document_ids: @ready_kb_document_ids,
        web_v1_metadata: @ready_web_v1_metadata,
        locale:          @locale
      )
    end

    @uploaded_filenames
  end

  private

  def upload_and_chunk_all(s3)
    all_files = image_file_attrs + document_file_attrs

    all_files.each_with_index do |attrs, idx|
      upload_and_chunk_one(attrs, s3, idx)
    end
  end

  def image_file_attrs
    @images.each_with_index.map do |img, idx|
      ext          = img[:media_type]&.split("/")&.last || "jpeg"
      raw_filename = (img[:filename] || img["filename"]).presence
      raw_filename = File.basename(raw_filename) if raw_filename.present?
      filename     = raw_filename || "chat_#{Time.current.strftime('%Y%m%d_%H%M%S')}_#{idx}.#{ext}"
      binary       = img[:binary] || img["binary"] || Base64.decode64(img[:data] || img["data"])
      {
        filename:               filename,
        binary:                 binary,
        content_type:           img[:media_type] || img["media_type"] || "image/jpeg",
        thumbnail_binary:       img[:thumbnail_binary]       || img["thumbnail_binary"],
        thumbnail_content_type: img[:thumbnail_content_type] || img["thumbnail_content_type"],
        thumbnail_width:        img[:thumbnail_width]        || img["thumbnail_width"],
        thumbnail_height:       img[:thumbnail_height]       || img["thumbnail_height"]
      }
    end
  end

  def document_file_attrs
    @documents.each_with_index.map do |doc, idx|
      filename = (doc[:filename] || doc["filename"]).presence || "doc_#{Time.current.strftime('%Y%m%d_%H%M%S')}_#{idx}.txt"
      filename = File.basename(filename)
      binary   = Base64.decode64(doc[:data] || doc["data"])
      {
        filename:     filename,
        binary:       binary,
        content_type: doc[:media_type] || doc["media_type"] || "text/plain"
      }
    end
  end

  def upload_and_chunk_one(attrs, s3, _idx)
    filename     = attrs[:filename]
    binary       = attrs[:binary]
    content_type = attrs[:content_type]

    s3_key = s3.upload_file(filename, binary, content_type)
    return if s3_key.blank?

    sha256 = Digest::SHA256.hexdigest(binary)
    kb_doc = ensure_kb_document_for(s3_key)
    KbDocumentThumbnailPersister.call(kb_doc: kb_doc, img: attrs) if attrs[:thumbnail_binary].present?
    @uploaded_filenames << filename

    # SHA dedup: skip parse when identical binary was already indexed under the
    # SAME ingestion contract. Images declare the field-photo contract; documents
    # the field_records contract — a version mismatch is always a miss.
    contract_version = if attrs[:content_type].to_s.start_with?("image/")
      FieldPhotoPrompt::INGESTION_CONTRACT_VERSION
    else
      BatchChunkingPrompt::INGESTION_CONTRACT_VERSION
    end
    dedup = ContentDedupService.find_completed(sha256: sha256, contract_version: contract_version)
    if dedup.hit
      mark_ready(
        filename: filename,
        kb_doc_id: kb_doc.id,
        metadata: {
          "filename"        => filename,
          "canonical_name"  => dedup.canonical_name.to_s,
          "aliases"         => Array(dedup.aliases),
          "summary"         => nil,
          "companion_offer" => nil
        }
      )
      return
    end

    if long_pdf_for_batch?(content_type: content_type, filename: filename, binary: binary)
      SubmitManualBatchJob.perform_later(
        s3_key:          s3_key,
        filename:        filename,
        sha256:          sha256,
        kb_doc_id:       kb_doc.id,
        locale:          @locale,
        conv_session_id: @conv_session&.id
      )
      return
    end

    begin
      chunk_asset = SingleFileChunkingService.new(
        binary:       binary,
        content_type: content_type,
        filename:     filename,
        s3_key:       s3_key,
        sha256:       sha256,
        locale:       @locale
      ).call
    rescue ClaudeChunkingClient::CreditBalanceError
      @uploaded_filenames.delete(filename)
      kb_doc.destroy
      KbSyncBroadcaster.failed(
        filenames: [ filename ],
        reason:    "credit_balance_low",
        message:   I18n.t("rag.service_unavailable_credits")
      )
      return
    rescue StandardError => e
      if office?(filename)
        Rails.logger.error("CustomChunking: Office parse failed for #{filename} — #{e.class}: #{e.message}")
        Rails.logger.error(e.backtrace.first(10).join("\n"))
        @uploaded_filenames.delete(filename)
        KbSyncBroadcaster.failed(
          filenames: [ filename ],
          reason:    "office_parse_error",
          message:   I18n.t("rag.office_parse_failed")
        )
        return
      end
      raise
    end

    mark_ready(
      filename: filename,
      kb_doc_id: kb_doc.id,
      metadata: {
        "filename"         => filename,
        "canonical_name"   => chunk_asset.canonical_name.to_s.strip.presence || "",
        "aliases"          => Array(chunk_asset.aliases),
        "summary"          => chunk_asset.summary.to_s.presence,
        "companion_offer"  => chunk_asset.companion_offer.to_s.presence,
        "chunks_s3_prefix" => chunk_asset.chunks_s3_prefix.to_s.presence,
        "partial_pages"    => Array(chunk_asset.degraded_pages)
      }
    )
  end

  def mark_ready(filename:, kb_doc_id:, metadata:)
    @ready_filenames << filename
    @ready_kb_document_ids << kb_doc_id
    @ready_web_v1_metadata << metadata
  end

  def ensure_kb_document_for(s3_key)
    KbDocument.find_or_create_by!(s3_key: s3_key) do |d|
      d.display_name = File.basename(s3_key, ".*").tr("_-", " ").strip.presence
      d.aliases      = []
    end
  rescue ActiveRecord::RecordNotUnique
    KbDocument.find_by!(s3_key: s3_key)
  end

  def office?(filename)
    OFFICE_EXTENSIONS.include?(File.extname(filename.to_s).downcase)
  end

  def long_pdf_for_batch?(content_type:, filename:, binary:)
    return false unless content_type.to_s == PDF_CONTENT_TYPE
    return false if office?(filename)

    pdf_page_count(binary) > sync_pdf_page_threshold
  rescue StandardError => e
    Rails.logger.warn("CustomChunking: PDF page count failed for #{filename} — #{e.class}: #{e.message}; using sync path")
    false
  end

  def sync_pdf_page_threshold
    value = ENV.fetch("WEB_SYNC_PDF_PAGE_THRESHOLD", SYNC_PAGES).to_i
    value.positive? ? value : SYNC_PAGES
  end

  def pdf_page_count(binary)
    PdfPageSplitterService.new(binary).page_count
  end
end
