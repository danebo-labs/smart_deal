# frozen_string_literal: true

require "tempfile"

# Builds Anthropic Batch API request hashes for the cost_v2 bulk path.
#
# Images → FieldPhotoDensityGate decides Sonnet vs Opus; uses FieldPhotoPrompt.
# PDFs   → PdfPageSplitterService + PageRelevanceFilter per page; Sonnet default, Opus for force_opus.
#
# Production uses #build_items! so request payloads are built lazily per bounded
# submission group. #build_all! remains as a compatibility helper for tests.
class BulkCostV2RequestBuilder
  # custom_id for PDF pages: sha256_prefix(16) + "_p" + page_number
  PAGE_ID_PATTERN = "%s_p%d"

  IMAGE_MIME_TYPES = %w[image/jpeg image/png image/webp image/gif].freeze

  def build_all!(assets)
    items, meta = build_items!(assets)
    [ items.map(&:build), meta ]
  ensure
    Array(items).each(&:cleanup)
  end

  def build_items!(assets)
    items = []
    meta  = {} # asset.id => [custom_id, ...]

    assets.each do |asset|
      binary = asset.instance_variable_get(:@_cached_binary) ||
               download_binary_for(asset)

      if IMAGE_MIME_TYPES.include?(asset.content_type)
        items << build_item_for_image(asset, binary)
        meta[asset.id] = [ asset.custom_id ]

      elsif asset.content_type == "application/pdf"
        pdf_items, page_ids = build_for_pdf(asset, binary)
        items.concat(pdf_items)
        meta[asset.id] = page_ids
      end
    end

    [ items, meta ]
  rescue StandardError
    items.each(&:cleanup)
    raise
  end

  private

  def build_item_for_image(asset, binary)
    route = FieldPhotoDensityGate.decide(
      binary:         binary,
      content_type:   asset.content_type,
      filename:       asset.filename,
      correlation_id: "ingest:#{asset.sha256[0, 12]}"
    )

    model         = route == :opus ? BatchChunkingPrompt::MODEL_MULTIMODAL : BatchChunkingPrompt::MODEL_TEXT
    system_blocks = route == :opus ? BatchChunkingPrompt::SYSTEM_BLOCKS    : FieldPhotoPrompt::SYSTEM_BLOCKS
    path          = write_temp_binary(binary, suffix: File.extname(asset.filename))
    byte_size     = File.size(path)

    ClaudeBatchRequestItem.new(
      custom_id: asset.custom_id,
      byte_size: byte_size,
      cleanup:   -> { unlink(path) },
      build:     lambda {
        {
          custom_id: asset.custom_id,
          params: {
            model:      model,
            max_tokens: BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS,
            system:     system_blocks,
            messages: [ {
              role:    "user",
              content: FieldPhotoPrompt.user_content(
                binary:       File.binread(path),
                content_type: asset.content_type,
                filename:     asset.filename
              )
            } ]
          }
        }
      }
    )
  end

  def build_for_pdf(asset, binary)
    splitter    = PdfPageSplitterService.new(binary)
    total_pages = splitter.page_count
    return [ [], [] ] if total_pages.zero?

    pages = collect_pages(splitter)
    return [ [], [] ] if pages.empty?

    filter_results = build_filter_results(pages, asset.filename, asset.sha256)
    kept_pages     = apply_filters(pages, filter_results, asset.filename)

    # When all pages filtered → return empty page_ids (distinguishes from valid asset)
    # BatchIngestionService will mark asset as failed rather than in_batch.
    return [ [], [] ] if kept_pages.empty?

    items    = build_page_request_items(kept_pages, asset)
    page_ids = kept_pages.map { |page| page_custom_id(asset.sha256, page.number) }

    [ items, page_ids ]
  rescue StandardError
    Array(pages).each(&:cleanup)
    raise
  end

  def collect_pages(splitter)
    pages = []
    splitter.each_split_page { |page| pages << page }
    pages
  rescue StandardError
    pages.each(&:cleanup)
    raise
  end

  def build_filter_results(pages, filename, sha256 = nil)
    PageRelevanceFilter.filter_pages(
      pages:          pages,
      filename:       filename,
      correlation_id: sha256.present? ? "ingest:#{sha256.to_s[0, 12]}" : nil
    )
  end

  def apply_filters(pages, filter_results, filename)
    pages.filter_map do |page|
      result = filter_results[page.number] || { keep: true, reason: :missing, source: :fallback }

      if result[:force_opus] && result[:keep]
        page.model      = BatchChunkingPrompt::MODEL_MULTIMODAL
        page.force_opus = true
      end

      Rails.logger.info(
        "BulkCostV2RequestBuilder filter: #{filename} p#{page.number} " \
        "#{result[:keep] ? 'keep' : 'drop'} (#{result[:reason]}, #{result[:source]})"
      )

      if result[:keep]
        page
      else
        page.cleanup
        nil
      end
    end
  end

  def build_page_request_items(kept_pages, asset)
    total = kept_pages.size

    kept_pages.each_with_index.map do |page, idx|
      custom_id = page_custom_id(asset.sha256, page.number)
      anchor    = idx.zero?

      ClaudeBatchRequestItem.new(
        custom_id: custom_id,
        byte_size: page.byte_size,
        cleanup:   -> { page.cleanup },
        build:     lambda {
          content = BatchChunkingPrompt.page_user_content(
            binary:      page.binary,
            page_number: page.number,
            total_pages: total,
            filename:    asset.filename,
            locale:      nil,
            anchor:      anchor
          )

          {
            custom_id: custom_id,
            params: {
              model:      page.model,
              max_tokens: BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS,
              system:     BatchChunkingPrompt::SYSTEM_BLOCKS,
              messages: [ { role: "user", content: content } ]
            }
          }
        }
      )
    end
  end

  def write_temp_binary(binary, suffix:)
    tempfile = Tempfile.create([ "danebo-batch-asset-", suffix.presence || ".bin" ])
    tempfile.binmode
    tempfile.write(binary)
    path = tempfile.path
    tempfile.close
    path
  rescue StandardError
    tempfile&.close
    unlink(path)
    raise
  end

  def unlink(path)
    File.unlink(path) if path.present? && File.exist?(path)
  rescue Errno::ENOENT
    nil
  end

  def page_custom_id(sha256, page_number)
    format(PAGE_ID_PATTERN, sha256[0, 16], page_number)
  end

  def download_binary_for(asset)
    s3 = Aws::S3::Client.new(build_aws_client_options)
    s3.get_object(bucket: bucket_name, key: asset.s3_key).body.read
  end

  include AwsClientInitializer

  def bucket_name
    ENV["KNOWLEDGE_BASE_S3_BUCKET"].presence ||
      Rails.application.credentials.dig(:bedrock, :knowledge_base_s3_bucket) ||
      Rails.application.credentials.dig(:aws, :knowledge_base_s3_bucket) ||
      "document-chatbot-generic-tech-info"
  end
end
