# frozen_string_literal: true

require "test_helper"

class BulkUploadArchiveServiceTest < ActiveSupport::TestCase
  class FakeS3Client
    attr_reader :puts, :gets, :deletes

    def initialize(binary: "zip-data")
      @binary = binary
      @puts = []
      @gets = []
      @deletes = []
    end

    def put_object(**params)
      @puts << params.merge(body: params[:body].read)
    end

    def get_object(bucket:, key:, response_target:)
      @gets << { bucket: bucket, key: key, response_target: response_target }
      File.binwrite(response_target, @binary)
    end

    def delete_object(bucket:, key:)
      @deletes << { bucket: bucket, key: key }
    end
  end

  test "uploads ZIP under deterministic archive key" do
    s3 = FakeS3Client.new
    service = BulkUploadArchiveService.new(s3: s3, bucket: "test-bucket")

    Tempfile.create([ "archive", ".zip" ]) do |file|
      file.binmode
      file.write("zip-data")
      file.flush

      key = service.upload(local_path: file.path, sha256: "abc123")

      assert_equal "bulk_upload_archives/abc123.zip", key
      assert_equal 1, s3.puts.size
      assert_equal "zip-data", s3.puts.first[:body]
      assert_equal "application/zip", s3.puts.first[:content_type]
    end
  end

  test "downloads to a temporary file and deletes the remote archive" do
    s3 = FakeS3Client.new(binary: "downloaded-zip")
    service = BulkUploadArchiveService.new(s3: s3, bucket: "test-bucket")
    downloaded_path = nil

    service.with_downloaded("bulk_upload_archives/abc123.zip") do |path|
      downloaded_path = path
      assert_equal "downloaded-zip", File.binread(path)
    end
    service.delete("bulk_upload_archives/abc123.zip")

    assert_not File.exist?(downloaded_path)
    assert_equal 1, s3.deletes.size
    assert_equal({ bucket: "test-bucket", key: "bulk_upload_archives/abc123.zip" }, s3.deletes.first)
  end
end
