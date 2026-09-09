# frozen_string_literal: true

require "aws-sdk-s3"

# Short-lived presigned URL for a company's report logo, following the same
# shape as FieldPhotoUrlService: memoized presigner, hour-bucketed cache entry
# so the same signed URL survives ~50 minutes and the browser caches the image.
#
# The trusted-host check is FieldPhotoUrlService's own class method, reused
# as-is: there is one definition of "this URL really points at our bucket" in
# the app, and no open redirect can be introduced by a second copy of it.
class CertifierLogoUrlService
  include AwsClientInitializer

  URL_TTL_SECONDS   = 3600
  CACHE_TTL_SECONDS = 50.minutes

  def initialize(account:, bucket: nil)
    raise ArgumentError, "account is required" unless account

    @account   = account
    @bucket    = bucket.presence || S3DocumentsService.new.bucket_name
    @presigner = nil
  end

  # @return [String, nil] presigned URL, or nil when the account has no logo
  def call
    key = @account.certifier_logo_s3_key
    return nil if key.blank?

    cache_key = "certifier_logo_url/v1/#{@bucket}/#{key}/#{Time.current.utc.strftime('%Y%m%d%H')}"
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
    Rails.logger.warn("CertifierLogoUrlService: failed for account=#{@account.id} — #{e.message}")
    nil
  end

  def trusted_redirect_url?(url)
    FieldPhotoUrlService.trusted_redirect_url?(url, bucket: @bucket)
  end

  private

  def presigner
    @presigner ||= Aws::S3::Presigner.new(client: Aws::S3::Client.new(build_aws_client_options))
  end
end
