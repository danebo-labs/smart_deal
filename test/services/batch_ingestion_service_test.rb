# frozen_string_literal: true

require "test_helper"
require "zip"
require "tmpdir"

class BatchIngestionServiceTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  JPEG_BINARY = ("\xFF\xD8\xFF\xE0" + ("x" * 100)).b
  PDF_BINARY  = ("%PDF-1.4\n" + ("x" * 100)).b

  def build_zip(entries:)
    path = Tempfile.new([ "test_zip", ".zip" ]).path
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

  setup do
    @bulk_upload = BulkUpload.create!(
      sha256: Digest::SHA256.hexdigest("test_#{SecureRandom.hex(8)}"),
      original_filename: "test.zip",
      status: "pending"
    )
    @fake_s3 = FakeS3Client.new
  end

  teardown do
    BulkUploadAsset.where(bulk_upload: @bulk_upload).destroy_all
    @bulk_upload.destroy
  end

  # ── ContentDedup skip ─────────────────────────────────────────────────────────

  test "process! marks asset complete and skips batch when dedup hit" do
    sha256    = Digest::SHA256.hexdigest(PDF_BINARY)
    custom_id = sha256[0, 32]

    zip_path = build_zip(entries: { "manual.pdf" => PDF_BINARY })

    # Seed a completed asset so dedup finds it
    prior_asset = BulkUploadAsset.create!(
      bulk_upload:    @bulk_upload,
      custom_id:      custom_id,
      sha256:         sha256,
      s3_key:         "bulk_uploads/prior/manual.pdf",
      filename:       "manual.pdf",
      content_type:   "application/pdf",
      status:         "complete",
      canonical_name: "Prior Elevator Manual",
      aliases:        [ "PRIOR-001" ]
    )

    service = BatchIngestionService.new
    service.instance_variable_set(:@s3, @fake_s3)
    service.instance_variable_set(:@bucket, "test-bucket")

    # A second bulk_upload to avoid unique custom_id collision on prior_asset
    bulk2 = BulkUpload.create!(
      sha256: Digest::SHA256.hexdigest("bulk2_#{SecureRandom.hex(8)}"),
      original_filename: "test2.zip",
      status: "pending"
    )

    service.process!(bulk2, zip_path)

    deduped = BulkUploadAsset.find_by(bulk_upload: bulk2, sha256: sha256)
    assert_not_nil deduped
    assert_equal "complete",            deduped.status
    assert_equal "Prior Elevator Manual", deduped.canonical_name
    assert_equal BulkUploadAsset::INGESTION_CONTENT_DEDUP, deduped.ingestion_path
    assert deduped.content_deduped?
  ensure
    bulk2&.bulk_upload_assets&.destroy_all
    bulk2&.destroy
    prior_asset&.destroy
  end

  test "process! sets status uploaded_s3 when no dedup hit" do
    sha256   = Digest::SHA256.hexdigest(JPEG_BINARY)
    zip_path = build_zip(entries: { "photo.jpg" => JPEG_BINARY })

    service = BatchIngestionService.new
    service.instance_variable_set(:@s3, @fake_s3)
    service.instance_variable_set(:@bucket, "test-bucket")

    service.process!(@bulk_upload, zip_path)

    asset = BulkUploadAsset.find_by(bulk_upload: @bulk_upload)
    assert_not_nil asset
    assert_equal "uploaded_s3", asset.status
  end

  # ── Per-file skip via ZipExtractionService#skipped_entries ───────────────────

  test "process! creates failed asset for skipped MIME entry, valid entry stays uploaded_s3" do
    avif_binary = ("AVIF" + ("x" * 100)).b
    zip_path    = build_zip(entries: {
      "photo.jpg"  => JPEG_BINARY,
      "photo.avif" => avif_binary
    })

    service = BatchIngestionService.new
    service.instance_variable_set(:@s3, @fake_s3)
    service.instance_variable_set(:@bucket, "test-bucket")

    service.process!(@bulk_upload, zip_path)

    assets = BulkUploadAsset.where(bulk_upload: @bulk_upload).order(:filename)
    assert_equal 2, assets.size

    valid   = assets.find { |a| a.filename == "photo.jpg" }
    skipped = assets.find { |a| a.filename == "photo.avif" }

    assert_not_nil valid
    assert_equal "uploaded_s3", valid.status
    assert_nil valid.error_message

    assert_not_nil skipped
    assert_equal "failed", skipped.status
    assert_match(/Tipo de archivo no compatible/, BulkUploadAssetErrorMessage.display(skipped.error_message))
    assert_nil skipped.s3_key
  end

  test "process! creates failed asset without s3_key for skipped entry" do
    avif_binary = ("AVIF" + ("x" * 100)).b
    zip_path    = build_zip(entries: { "bad.avif" => avif_binary })

    service = BatchIngestionService.new
    service.instance_variable_set(:@s3, @fake_s3)
    service.instance_variable_set(:@bucket, "test-bucket")

    service.process!(@bulk_upload, zip_path)

    asset = BulkUploadAsset.find_by(bulk_upload: @bulk_upload)
    assert_not_nil asset
    assert_equal "failed",  asset.status
    assert_nil asset.s3_key
    assert_match(/Tipo de archivo no compatible/, BulkUploadAssetErrorMessage.display(asset.error_message))
  end

  test "submit! returns nil when no uploaded_s3 assets exist" do
    service = BatchIngestionService.new
    service.instance_variable_set(:@s3, @fake_s3)
    service.instance_variable_set(:@bucket, "test-bucket")

    result = service.submit!(@bulk_upload)
    assert_nil result
  end

  test "persist_batch_custom_ids! marks asset failed when page_ids is empty (all pages filtered)" do
    asset = BulkUploadAsset.create!(
      bulk_upload:   @bulk_upload,
      custom_id:     "abc123",
      sha256:        "a" * 64,
      s3_key:        "bulk_uploads/filtered.pdf",
      filename:      "filtered.pdf",
      content_type:  "application/pdf",
      status:        "uploaded_s3"
    )

    service = BatchIngestionService.new
    service.instance_variable_set(:@s3, @fake_s3)
    service.instance_variable_set(:@bucket, "test-bucket")

    # Simulate BulkCostV2RequestBuilder returning empty page_ids for this asset
    meta = { asset.id => [] }

    service.send(:persist_batch_custom_ids!, [ asset ], meta)

    asset.reload
    assert_equal "failed", asset.status
    assert_match(/Todas las páginas se filtraron/, BulkUploadAssetErrorMessage.display(asset.error_message))
    assert_nil asset.ingestion_path
  ensure
    asset&.destroy
  end
end
