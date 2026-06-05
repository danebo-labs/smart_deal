# frozen_string_literal: true

require "test_helper"
require "zip"

class ProcessBulkUploadJobTest < ActiveJob::TestCase
  parallelize(workers: 1)

  JPEG_BINARY = ("\xFF\xD8\xFF\xE0" + ("x" * 100)).b
  PDF_BINARY  = ("%PDF-1.4\n" + ("x" * 100)).b

  def build_zip(entries:)
    tempfile = Tempfile.new([ "test_zip", ".zip" ])
    @zip_tempfiles << tempfile
    path = tempfile.path
    Zip::OutputStream.open(path) do |zos|
      entries.each do |name, content|
        zos.put_next_entry(name)
        zos.write(content)
      end
    end
    path
  end

  class FakeS3Client
    def put_object(**); end
    def get_object(bucket:, key:)
      OpenStruct.new(body: StringIO.new("data"))
    end
  end

  class FakeArchiveService
    attr_reader :deleted_keys

    def initialize
      @deleted_keys = []
    end

    def with_downloaded(key)
      yield key
    end

    def delete(key)
      @deleted_keys << key
    end
  end

  def make_bulk(sha_suffix: SecureRandom.hex(8))
    BulkUpload.create!(
      sha256:            Digest::SHA256.hexdigest("process_job_#{sha_suffix}"),
      original_filename: "test.zip",
      status:            "pending"
    )
  end

  setup do
    @zip_tempfiles = []
    @bulk   = make_bulk
    @fake_s3 = FakeS3Client.new
    @fake_archive = FakeArchiveService.new
    @orig_archive_new = BulkUploadArchiveService.method(:new)
    fake_archive = @fake_archive
    BulkUploadArchiveService.define_singleton_method(:new) { |**| fake_archive }
    orig_new = BatchIngestionService.method(:new)
    @orig_batch_new = orig_new
    BatchIngestionService.define_singleton_method(:new) do
      svc = orig_new.call
      svc.instance_variable_set(:@s3, FakeS3Client.new)
      svc.instance_variable_set(:@bucket, "test-bucket")
      svc
    end
  end

  teardown do
    BatchIngestionService.define_singleton_method(:new, @orig_batch_new) if defined?(@orig_batch_new)
    BulkUploadArchiveService.define_singleton_method(:new, @orig_archive_new)
    BulkUploadAsset.where(bulk_upload: @bulk).destroy_all
    @bulk.destroy
    @zip_tempfiles&.each(&:close!)
  end

  test "enqueues SubmitClaudeBatchJob when valid assets exist" do
    zip = build_zip(entries: { "photo.jpg" => JPEG_BINARY })

    assert_enqueued_with(job: SubmitClaudeBatchJob) do
      ProcessBulkUploadJob.perform_now(@bulk.id, zip, "es")
    end

    assert @bulk.reload.bulk_upload_assets.exists?(status: "uploaded_s3")
    assert_includes @fake_archive.deleted_keys, zip
  end

  test "does not enqueue SubmitClaudeBatchJob when all entries are skipped" do
    avif_binary = ("AVIF" + ("x" * 100)).b
    zip = build_zip(entries: { "bad.avif" => avif_binary })

    assert_no_enqueued_jobs(only: SubmitClaudeBatchJob) do
      ProcessBulkUploadJob.perform_now(@bulk.id, zip, "es")
    end

    @bulk.reload
    assert_equal "failed", @bulk.status
    assert_match(/Ningún archivo|No files/, @bulk.error_message)
  end

  test "valid entries are not marked failed when one entry is skipped" do
    avif_binary = ("AVIF" + ("x" * 100)).b
    zip = build_zip(entries: {
      "good.jpg" => JPEG_BINARY,
      "bad.avif" => avif_binary
    })

    ProcessBulkUploadJob.perform_now(@bulk.id, zip, "es")

    assets = BulkUploadAsset.where(bulk_upload: @bulk)
    valid   = assets.find { |a| a.filename == "good.jpg" }
    skipped = assets.find { |a| a.filename == "bad.avif" }

    assert_equal "uploaded_s3", valid.status
    assert_equal "failed",      skipped.status
    assert_nil valid.error_message
  end

  test "marks bulk failed on global ZIP error (bomb/size) without enqueueing submit" do
    orig_each = ZipExtractionService.instance_method(:each_entry)
    ZipExtractionService.define_method(:each_entry) do |&_block|
      raise ZipExtractionService::Error, "ZIP bomb detected: ratio 200x"
    end

    zip = build_zip(entries: { "photo.jpg" => JPEG_BINARY })

    assert_no_enqueued_jobs(only: SubmitClaudeBatchJob) do
      ProcessBulkUploadJob.perform_now(@bulk.id, zip, "es")
    end

    @bulk.reload
    assert_equal "failed", @bulk.status
    assert_match(/ZIP bomb/, @bulk.error_message)
    assert_includes @fake_archive.deleted_keys, zip
  ensure
    ZipExtractionService.define_method(:each_entry, orig_each)
  end

  test "marks bulk failed and deletes archive on unexpected error without re-raising" do
    BatchIngestionService.define_singleton_method(:new) do
      svc = Object.new
      def svc.process!(*) = raise(StandardError, "boom")
      svc
    end
    zip = build_zip(entries: { "photo.jpg" => JPEG_BINARY })

    assert_no_enqueued_jobs(only: SubmitClaudeBatchJob) do
      assert_nothing_raised { ProcessBulkUploadJob.perform_now(@bulk.id, zip, "es") }
    end

    @bulk.reload
    assert_equal "failed", @bulk.status
    assert_match(/boom/, @bulk.error_message)
    assert_includes @fake_archive.deleted_keys, zip
  end
end
