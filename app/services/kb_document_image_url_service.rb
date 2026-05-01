# frozen_string_literal: true

require 'aws-sdk-s3'

# Generates short-lived S3 presigned URLs so the browser can fetch full-size
# images directly (bypassing Rails). Embedded in HTML at render time so the
# lightbox click triggers ZERO server round-trip.
#
# Designed to be instantiated once per HTTP request — the AWS Presigner is
# memoized so rendering N rows uses a single client.
class KbDocumentImageUrlService
  include AwsClientInitializer

  IMAGE_EXTENSIONS  = %w[.png .jpg .jpeg .webp .gif].freeze
  URL_TTL_SECONDS   = 3600 # 1h — aligned with response_cache_control below
  CACHE_TTL_SECONDS = 50.minutes # presigner gets 60min — write expires earlier so we always rotate ahead of S3

  def initialize(bucket: nil)
    @bucket    = bucket.presence || KbDocument::KB_BUCKET
    @presigner = nil # built lazily on first call
  end

  # @param kb_document [KbDocument]
  # @return [String, nil] presigned URL, or nil if not an image / on error
  #
  # The URL is cached in Solid Cache and re-used for ~50 minutes. Within an
  # hour-bucket the SAME signed URL is returned on every render — that lets
  # the BROWSER cache the image (it caches by URL, so a fresh URL on every
  # render guaranteed a miss on every reload). The cache key embeds the
  # current UTC hour so URLs naturally rotate before they expire.
  def call(kb_document)
    return nil if kb_document.nil?
    return nil if kb_document.s3_key.blank?
    return nil unless image?(kb_document.s3_key)

    key = KbDocument.object_key_for_match(kb_document.s3_key)
    return nil if key.blank?

    cache_key = "kb_url/v1/#{@bucket}/#{key}/#{Time.current.utc.strftime('%Y%m%d%H')}"
    Rails.cache.fetch(cache_key, expires_in: CACHE_TTL_SECONDS) do
      presigner.presigned_url(
        :get_object,
        bucket:                       @bucket,
        key:                          key,
        expires_in:                   URL_TTL_SECONDS,
        response_content_disposition: "inline",
        response_cache_control:       "public, max-age=#{URL_TTL_SECONDS}"
      )
    end
  rescue StandardError => e
    Rails.logger.warn("KbDocumentImageUrlService: failed for kb_doc=#{kb_document.id} — #{e.message}")
    nil
  end

  # Convenience for partials: { kb_document => url_or_nil }
  def call_many(kb_documents)
    kb_documents.index_with { |doc| call(doc) }
  end

  private

  def presigner
    @presigner ||= Aws::S3::Presigner.new(client: Aws::S3::Client.new(build_aws_client_options))
  end

  def image?(s3_key)
    IMAGE_EXTENSIONS.include?(File.extname(s3_key.to_s).downcase)
  end
end
