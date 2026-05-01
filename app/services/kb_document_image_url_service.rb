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

  IMAGE_EXTENSIONS = %w[.png .jpg .jpeg .webp .gif].freeze
  URL_TTL_SECONDS  = 3600 # 1h — aligned with response_cache_control below

  def initialize(bucket: nil)
    @bucket    = bucket.presence || KbDocument::KB_BUCKET
    @presigner = nil # built lazily on first call
  end

  # @param kb_document [KbDocument]
  # @return [String, nil] presigned URL, or nil if not an image / on error
  def call(kb_document)
    return nil if kb_document.nil?
    return nil if kb_document.s3_key.blank?
    return nil unless image?(kb_document.s3_key)

    key = KbDocument.object_key_for_match(kb_document.s3_key)
    return nil if key.blank?

    presigner.presigned_url(
      :get_object,
      bucket:                       @bucket,
      key:                          key,
      expires_in:                   URL_TTL_SECONDS,
      response_content_disposition: "inline",
      response_cache_control:       "public, max-age=#{URL_TTL_SECONDS}"
    )
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
