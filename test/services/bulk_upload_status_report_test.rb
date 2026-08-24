# frozen_string_literal: true

require "test_helper"

class BulkUploadStatusReportTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  def create_upload(status: "processing", **attrs)
    BulkUpload.create!(
      sha256:            Digest::SHA256.hexdigest("status_report_#{SecureRandom.hex(8)}"),
      original_filename: "06_ingesta.zip",
      status:            status,
      user:              users(:one),
      **attrs
    )
  end

  def add_asset(upload, status:, filename: "file_#{SecureRandom.hex(4)}.pdf", **attrs)
    upload.bulk_upload_assets.create!(
      custom_id:    SecureRandom.hex(16),
      sha256:       Digest::SHA256.hexdigest("asset_#{SecureRandom.hex(8)}"),
      filename:     filename,
      content_type: "application/pdf",
      status:       status,
      **attrs
    )
  end

  test "counts assets by status and reports the batch count" do
    upload = create_upload(claude_batch_ids: %w[msgbatch_a msgbatch_b])
    2.times { add_asset(upload, status: "complete") }
    add_asset(upload, status: "in_batch")

    snapshot = BulkUploadStatusReport.new(upload).call

    assert_equal upload.id, snapshot.upload_id
    assert_equal({ "complete" => 2, "in_batch" => 1 }, snapshot.asset_counts)
    assert_equal 2, snapshot.batches
    assert_not snapshot.terminal?
  end

  test "surfaces the error behind each failed asset" do
    upload = create_upload(claude_batch_ids: %w[msgbatch_a])
    add_asset(upload, status: "complete")
    add_asset(
      upload,
      status:        "failed",
      filename:      "CMC3 SCM Synergy.pdf",
      error_message: "Invalid k in chunk 47 field_record 11"
    )

    snapshot = BulkUploadStatusReport.new(upload).call

    assert_equal 1, snapshot.failures.size
    assert_equal "CMC3 SCM Synergy.pdf", snapshot.failures.first.filename
    assert_match(/Invalid k in chunk 47/, snapshot.failures.first.error_message)
  end

  test "tallies discarded field_records by reason" do
    upload = create_upload(claude_batch_ids: %w[msgbatch_a])
    add_asset(upload, status: "complete", filename: "clean.pdf")
    add_asset(
      upload,
      status:                "complete",
      filename:              "kone minispace.pdf",
      dropped_field_records: [
        { "chunk" => 1, "reason" => "no evidence" },
        { "chunk" => 4, "reason" => "sw outside STOP_WORK_CONDITION (k=SAFETY_WARNING)" },
        { "chunk" => 9, "reason" => "sw outside STOP_WORK_CONDITION (k=SAFETY_WARNING)" }
      ]
    )

    snapshot = BulkUploadStatusReport.new(upload).call

    assert_equal 1, snapshot.discards.size, "assets without discards must not be listed"
    discard = snapshot.discards.first
    assert_equal "kone minispace.pdf", discard.filename
    assert_equal 3, discard.count
    assert_equal 2, discard.reasons["sw outside STOP_WORK_CONDITION (k=SAFETY_WARNING)"]
    assert_equal 1, discard.reasons["no evidence"]
  end

  test "is terminal on complete and on failed" do
    %w[complete failed].each do |status|
      upload = create_upload(status: status, claude_batch_ids: %w[msgbatch_a])
      add_asset(upload, status: "complete")

      assert BulkUploadStatusReport.new(upload).call.terminal?, "#{status} should be terminal"
    end
  end

  test "renders a one-line summary with the upload error when there is one" do
    upload = create_upload(status: "complete", error_message: "11 procesados, 1 omitidos.")
    add_asset(upload, status: "complete")

    line = BulkUploadStatusReport.new(upload).call.to_s

    assert_match(/BU#{upload.id} 06_ingesta\.zip status=complete/, line)
    assert_match(/assets=\[complete:1\]/, line)
    assert_match(/error=11 procesados/, line)
  end
end
