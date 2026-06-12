# frozen_string_literal: true

# Builds Anthropic Batch API request hashes for the cost_v2 bulk path.
#
# Images → FieldPhotoDensityGate decides Sonnet vs Opus; uses FieldPhotoPrompt.
# PDFs   → PdfPageSplitterService + PageRelevanceFilter per page; Sonnet default, Opus for force_opus.
#
# Returns:
#   { requests: [Array<Hash>], meta: { asset_id => [custom_id, ...] } }
# The meta hash lets BatchIngestionService#submit! persist batch_custom_ids per asset.
class BulkCostV2RequestBuilder
  # custom_id for PDF pages: sha256_prefix(16) + "_p" + page_number
  PAGE_ID_PATTERN = "%s_p%d"

  IMAGE_MIME_TYPES = %w[image/jpeg image/png image/webp image/gif].freeze

  PageProxy = Struct.new(:number, :binary)
  private_constant :PageProxy

  def build_all!(assets)
    requests = []
    meta     = {}  # asset.id => [custom_id, ...]

    assets.each do |asset|
      binary = asset.instance_variable_get(:@_cached_binary) ||
               download_binary_for(asset)

      if IMAGE_MIME_TYPES.include?(asset.content_type)
        req = build_for_image(asset, binary)
        requests << req
        meta[asset.id] = [ asset.custom_id ]

      elsif asset.content_type == "application/pdf"
        pdf_requests, page_ids = build_for_pdf(asset, binary)
        requests.concat(pdf_requests)
        meta[asset.id] = page_ids
      end
    end

    [ requests, meta ]
  end

  private

  def build_for_image(asset, binary)
    route = FieldPhotoDensityGate.decide(
      binary:       binary,
      content_type: asset.content_type,
      filename:     asset.filename
    )

    model         = route == :opus ? BatchChunkingPrompt::MODEL_MULTIMODAL : BatchChunkingPrompt::MODEL_TEXT
    system_blocks = route == :opus ? BatchChunkingPrompt::SYSTEM_BLOCKS    : FieldPhotoPrompt::SYSTEM_BLOCKS

    {
      custom_id: asset.custom_id,
      params: {
        model:      model,
        max_tokens: BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS,
        system:     system_blocks,
        messages: [ {
          role:    "user",
          content: FieldPhotoPrompt.user_content(
            binary:       binary,
            content_type: asset.content_type,
            filename:     asset.filename
          )
        } ]
      }
    }
  end

  def build_for_pdf(asset, binary)
    splitter    = PdfPageSplitterService.new(binary)
    total_pages = splitter.page_count
    return [ [], [ asset.custom_id ] ] if total_pages.zero?

    pages = collect_pages(splitter)
    return [ [], [ asset.custom_id ] ] if pages.empty?

    filter_results = build_filter_results(pages, asset.filename, asset.sha256)
    kept_pages     = apply_filters(pages, filter_results, asset.filename)
    # When all pages filtered → return empty page_ids (distinguishes from valid asset)
    # BatchIngestionService will mark asset as failed rather than in_batch.
    return [ [], [] ] if kept_pages.empty?

    requests = build_page_requests(kept_pages, asset)
    page_ids = kept_pages.map { |p| page_custom_id(asset.sha256, p[:number]) }

    [ requests, page_ids ]
  end

  def collect_pages(splitter)
    pages = []
    splitter.each_page do |num, page_binary|
      pages << { number: num, binary: page_binary, model: BatchChunkingPrompt::MODEL_TEXT, force_opus: false }
    end
    pages
  end

  def build_filter_results(pages, filename, sha256 = nil)
    proxies = pages.map { |p| PageProxy.new(p[:number], p[:binary]) }
    PageRelevanceFilter.filter_pages(
      pages:          proxies,
      filename:       filename,
      correlation_id: sha256.present? ? "ingest:#{sha256.to_s[0, 12]}" : nil
    )
  end

  def apply_filters(pages, filter_results, filename)
    pages.select do |page|
      result = filter_results[page[:number]] || { keep: true, reason: :missing, source: :fallback }

      if result[:force_opus] && result[:keep]
        page[:model]      = BatchChunkingPrompt::MODEL_MULTIMODAL
        page[:force_opus] = true
      end

      Rails.logger.info(
        "BulkCostV2RequestBuilder filter: #{filename} p#{page[:number]} " \
        "#{result[:keep] ? 'keep' : 'drop'} (#{result[:reason]}, #{result[:source]})"
      )

      result[:keep]
    end
  end

  def build_page_requests(kept_pages, asset)
    total = kept_pages.size

    kept_pages.each_with_index.map do |page, idx|
      {
        custom_id: page_custom_id(asset.sha256, page[:number]),
        params: {
          model:      page[:model],
          max_tokens: BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS,
          system:     BatchChunkingPrompt::SYSTEM_BLOCKS,
          messages: [ {
            role:    "user",
            content: BatchChunkingPrompt.page_user_content(
              binary:      page[:binary],
              page_number: page[:number],
              total_pages: total,
              filename:    asset.filename,
              locale:      idx.zero? ? nil : nil
            )
          } ]
        }
      }
    end
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
