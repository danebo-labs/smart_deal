# frozen_string_literal: true

# Orchestrates the web custom chunking path for all attachments in one request:
#   1. Upload each file to S3 (creates KbDocument).
#   2. Route and parse each file:
#      - Images + Office → SingleFileChunkingService (sync).
#      - PDF urgent or short (page_count <= SYNC_PAGES) → sync.
#      - PDF long and non-urgent → SubmitManualBatchJob (dormant for web/chat;
#        QueryOrchestratorService passes urgent=true, bulk_uploads uses its own path).
#   3. Trigger BulkKbSyncService + BedrockIngestionJob to index via BEDROCK_BULK_DATA_SOURCE_ID.
#
# On error: propagates to the calling job (UploadAndSyncAttachmentsJob), which broadcasts
# KbSyncBroadcaster.failed and lets Solid Queue retry. No legacy OWRPGSX6XK fallback.
class CustomChunkingPipeline
  OFFICE_EXTENSIONS = FileMultimodalRouter::OFFICE_EXTENSIONS
  PDF_CONTENT_TYPE  = "application/pdf"

  # Short PDFs (≤ SYNC_PAGES) parse sync when this pipeline is called with urgent=false.
  # Web/chat callers pass urgent=true, so long manuals also stay on sync Messages.
  SYNC_PAGES = 2

  # @param images       [Array<Hash>] same shape as QOS @images
  # @param documents    [Array<Hash>] same shape as QOS @documents
  # @param conv_session [ConversationSession, nil]
  # @param tenant       [Tenant, nil]
  # @param locale       [String, nil] ISO 639-1 — forwarded to SingleFileChunkingService for image summary
  # @param urgent       [Boolean] when true, PDFs always parse sync. Web/chat
  #                     always passes true; bulk_uploads does not use this pipeline.
  def initialize(images:, documents:, conv_session: nil, tenant: nil, locale: nil, urgent: false)
    @images         = Array(images)
    @documents      = Array(documents)
    @conv_session   = conv_session
    @tenant         = tenant
    @locale         = locale
    @urgent         = urgent
    @uploaded_filenames = []
    @kb_document_ids    = []
    @web_v1_metadata    = []
  end

  # @return [Array<String>] successfully uploaded original filenames
  def run!
    s3 = S3DocumentsService.new
    upload_and_chunk_all(s3)
    return [] if @uploaded_filenames.empty?

    result = BulkKbSyncService.new.sync!(uploaded_filenames: @uploaded_filenames)
    if result.present?
      BedrockIngestionJob.perform_later(
        result[:job_id],
        @uploaded_filenames,
        kb_id:           result[:kb_id],
        data_source_id:  result[:data_source_id],
        conv_session_id: @conv_session&.id,
        kb_document_ids: @kb_document_ids,
        web_v1_metadata: @web_v1_metadata
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
    @kb_document_ids    << kb_doc.id
    @uploaded_filenames << filename

    # SHA dedup: skip parse when identical binary was already indexed.
    dedup = ContentDedupService.find_completed(sha256: sha256)
    if dedup.hit
      @web_v1_metadata << {
        "filename"        => filename,
        "canonical_name"  => dedup.canonical_name.to_s,
        "aliases"         => Array(dedup.aliases),
        "summary"         => nil,
        "companion_offer" => nil
      }
      return
    end

    # Long non-urgent PDFs can still use the dormant async Batch branch.
    # Web/chat sets urgent=true in QueryOrchestratorService; bulk_uploads uses its own pipeline.
    if content_type.to_s == PDF_CONTENT_TYPE && !office?(filename) && !@urgent &&
        pdf_page_count(binary) > SYNC_PAGES
      SubmitManualBatchJob.perform_later(
        s3_key:          s3_key,
        filename:        filename,
        sha256:          sha256,
        kb_doc_id:       kb_doc.id,
        locale:          @locale,
        conv_session_id: @conv_session&.id
      )
      # ACK fast: add to uploaded list without web_v1_metadata (parsed async)
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
    rescue StandardError => e
      if office?(filename)
        Rails.logger.error("CustomChunking: Office parse failed for #{filename} — #{e.class}: #{e.message}")
        Rails.logger.error(e.backtrace.first(10).join("\n"))
        @uploaded_filenames.delete(filename)
        @kb_document_ids.delete(kb_doc.id)
        KbSyncBroadcaster.failed(
          filenames: [ filename ],
          reason:    "office_parse_error",
          message:   I18n.t("rag.office_parse_failed")
        )
        return
      end
      raise
    end

    @web_v1_metadata << {
      "filename"         => filename,
      "canonical_name"   => chunk_asset.canonical_name.to_s,
      "aliases"          => Array(chunk_asset.aliases),
      "summary"          => chunk_asset.summary.to_s.presence,
      "companion_offer"  => chunk_asset.companion_offer.to_s.presence,
      "chunks_s3_prefix" => chunk_asset.chunks_s3_prefix.to_s.presence,
      "partial_pages"    => Array(chunk_asset.degraded_pages)
    }
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

  def pdf_page_count(binary)
    PdfPageSplitterService.new(binary).page_count
  end
end
