# frozen_string_literal: true

require "aws-sdk-s3"

class BulkUploadArchiveService
  include AwsClientInitializer

  PREFIX = "bulk_upload_archives"

  def initialize(s3: nil, bucket: nil)
    @s3 = s3 || Aws::S3::Client.new(build_aws_client_options)
    @bucket = bucket || bucket_name
  end

  def upload(local_path:, sha256:)
    key = "#{PREFIX}/#{sha256}.zip"
    File.open(local_path, "rb") do |file|
      @s3.put_object(
        bucket: @bucket,
        key: key,
        body: file,
        content_type: "application/zip"
      )
    end
    key
  end

  def with_downloaded(key)
    tempfile = Tempfile.new([ "bulk_upload", ".zip" ])
    tempfile.binmode
    tempfile.close

    @s3.get_object(bucket: @bucket, key: key, response_target: tempfile.path)
    yield tempfile.path
  ensure
    tempfile&.close!
  end

  def delete(key)
    @s3.delete_object(bucket: @bucket, key: key)
  rescue Aws::S3::Errors::ServiceError => e
    Rails.logger.warn("BulkUploadArchiveService: failed to delete #{key} — #{e.message}")
  end

  private

  def bucket_name
    ENV["KNOWLEDGE_BASE_S3_BUCKET"].presence ||
      Rails.application.credentials.dig(:bedrock, :knowledge_base_s3_bucket) ||
      Rails.application.credentials.dig(:aws, :knowledge_base_s3_bucket) ||
      "document-chatbot-generic-tech-info"
  end
end
