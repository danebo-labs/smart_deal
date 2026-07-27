# frozen_string_literal: true

require "aws-sdk-s3"

# Generates short-lived S3 presigned URLs for a technician's own field photos.
# Modeled on KbDocumentImageUrlService: memoized presigner, hour-bucketed
# Solid Cache entry so the same signed URL survives ~50 minutes and the
# browser can cache the image across renders.
class FieldPhotoUrlService
  include AwsClientInitializer

  URL_TTL_SECONDS   = 3600
  CACHE_TTL_SECONDS = 50.minutes

  def initialize(bucket: nil, account:)
    raise ArgumentError, "account is required" unless account

    @bucket    = bucket.presence || S3DocumentsService.new.bucket_name
    @account   = account
    @presigner = nil
  end

  # @param field_photo [FieldPhoto]
  # @return [String, nil] presigned URL, or nil if not the account's photo / on error
  def call(field_photo)
    return nil if field_photo.nil?
    scoped_photo = @account.field_photos.find_by(id: field_photo.id)
    return nil unless scoped_photo
    return nil if scoped_photo.s3_key_original.blank?

    cache_key = "field_photo_url/v1/#{@bucket}/#{scoped_photo.s3_key_original}/#{Time.current.utc.strftime('%Y%m%d%H')}"
    Rails.cache.fetch(cache_key, expires_in: CACHE_TTL_SECONDS) do
      presigner.presigned_url(
        :get_object,
        bucket:                       @bucket,
        key:                          scoped_photo.s3_key_original,
        expires_in:                   URL_TTL_SECONDS,
        response_content_disposition: "inline",
        response_cache_control:       "public, max-age=#{URL_TTL_SECONDS}"
      )
    end
  rescue StandardError => e
    Rails.logger.warn("FieldPhotoUrlService: failed for field_photo=#{field_photo.id} — #{e.message}")
    nil
  end

  private

  def presigner
    @presigner ||= Aws::S3::Presigner.new(client: Aws::S3::Client.new(build_aws_client_options))
  end
end
