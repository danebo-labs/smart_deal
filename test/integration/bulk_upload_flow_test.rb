# frozen_string_literal: true

require "test_helper"
require "ostruct"

# E2E smoke: verifies the controller end of the pipeline (HTTP → BulkUpload created →
# ProcessBulkUploadJob enqueued) and a direct job pipeline run with all external I/O
# faked (S3, Anthropic Batch, Bedrock).
class BulkUploadFlowTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  parallelize(workers: 1)

  FAKE_BATCH_ID    = "msgbatch_flow_test"
  FAKE_BEDROCK_JOB = "bedrock-job-flow"

  # ---------------------------------------------------------------------------
  # Fakes
  # ---------------------------------------------------------------------------

  class FakeS3Service
    def upload_file(filename, _binary, _ct)
      "bulk_uploads/2026-05-07/#{filename}"
    end

    def upload_text(key, _content) = key
    def bucket_name = "test-bucket"
  end

  class FakeBatchClient
    attr_writer :custom_id

    CHUNK_JSON = JSON.generate(
      document_name: "Manual de Prueba",
      aliases:       [ "manual prueba" ],
      chunks:        [
        { text: "**Document: Manual de Prueba**\n**DOCUMENT_ALIASES:**\n- manual prueba\nContenido.", page: 1 }
      ]
    )

    def submit_batch(requests:) = OpenStruct.new(id: FAKE_BATCH_ID)

    def retrieve(batch_id:)
      OpenStruct.new(processing_status: "ended")
    end

    def results_each(batch_id:)
      message = OpenStruct.new(
        content: [ OpenStruct.new(type: "text", text: CHUNK_JSON) ],
        model:   "claude-3-5-haiku-20241022",
        usage:   OpenStruct.new(input_tokens: 10, output_tokens: 20)
      )
      yield OpenStruct.new(
        custom_id: @custom_id || "unknown",
        result:    OpenStruct.new(type: "succeeded", message: message)
      )
    end
  end

  class FakeBatchIngestionService
    attr_writer :custom_id

    def initialize(batch_client: nil); end

    def process!(bulk_upload, _zip_path)
      bulk_upload.update!(status: "processing")
    end

    def submit!(bulk_upload)
      assets = bulk_upload.bulk_upload_assets.where(status: "uploaded_s3")
      batch  = OpenStruct.new(id: FAKE_BATCH_ID)
      bulk_upload.update!(claude_batch_id: batch.id)
      assets.each do |asset|
        page_id = "#{asset.sha256[0, 16]}_p1"
        asset.update_columns(
          batch_custom_ids: [ page_id ],
          ingestion_path:   "manual_batch_v1",
          status:           "in_batch"
        )
      end
      batch
    end
  end

  class FakeKbSync
    def sync!(uploaded_filenames: [], locale: nil)
      { job_id: FAKE_BEDROCK_JOB, kb_id: "kb-test", data_source_id: "ds-bulk" }
    end
  end

  class FakeIngestionSvc
    def job_status(_job_id)      = "COMPLETE"
    def clear_when_complete(_id) = true
  end

  # ---------------------------------------------------------------------------
  # Controller smoke: POST → redirect → show
  # ---------------------------------------------------------------------------

  test "POST create enqueues ProcessBulkUploadJob and show page renders" do
    sign_in users(:one)

    assert_enqueued_with(job: ProcessBulkUploadJob) do
      post bulk_uploads_path, params: { zip_file: empty_zip_upload }
    end

    upload = BulkUpload.order(:created_at).last
    assert_equal "pending", upload.status
    assert_redirected_to bulk_upload_path(upload)

    get bulk_upload_path(upload)
    assert_response :success
    assert_match upload.original_filename, response.body
  end

  # ---------------------------------------------------------------------------
  # Job pipeline: BulkUpload → SubmitClaudeBatchJob → Poll → Ingest → Poll → complete
  # ---------------------------------------------------------------------------

  test "job pipeline completes assets and creates KbDocuments" do
    fake_batch = FakeBatchClient.new

    with_stubs(fake_batch: fake_batch) do
      upload = BulkUpload.create!(
        sha256:            SecureRandom.hex(16),
        original_filename: "demo.zip",
        status:            "processing",
        asset_count:       1
      )
      asset = BulkUploadAsset.create!(
        bulk_upload:    upload,
        custom_id:      SecureRandom.hex(16),
        sha256:         SecureRandom.hex(32),
        filename:       "photo.jpg",
        status:         "uploaded_s3",
        s3_key:         "bulk_uploads/2026-05-07/photo.jpg"
      )
      fake_batch.custom_id = "#{asset.sha256[0, 16]}_p1"

      # SubmitClaudeBatchJob → stores batch id, transitions assets to in_batch
      SubmitClaudeBatchJob.perform_now(upload.id)
      assert_equal FAKE_BATCH_ID, upload.reload.claude_batch_id

      # PollClaudeBatchJob (batch ended immediately) → enqueues IngestBatchResultsJob
      assert_enqueued_with(job: IngestBatchResultsJob) do
        PollClaudeBatchJob.perform_now(upload.id, started_at_iso: 1.minute.ago.iso8601)
      end

      # IngestBatchResultsJob → parses chunks, starts Bedrock sync, enqueues Poll job
      assert_enqueued_with(job: PollBulkBedrockIngestionJob) do
        IngestBatchResultsJob.perform_now(upload.id)
      end
      assert_equal FAKE_BEDROCK_JOB, upload.reload.bedrock_ingestion_job_id

      # PollBulkBedrockIngestionJob → COMPLETE → assets done + KbDocument created
      PollBulkBedrockIngestionJob.perform_now(upload.id, started_at_iso: 1.minute.ago.iso8601)

      asset.reload
      assert_equal "complete", asset.status

      kb_doc = KbDocument.find_by(id: asset.kb_document_id)
      assert_not_nil kb_doc
      assert_equal "Manual de Prueba", kb_doc.display_name
    end
  end

  private

  def empty_zip_upload
    require "zip"
    buf = StringIO.new("".b)
    Zip::OutputStream.write_buffer(buf) { |_z| }
    Rack::Test::UploadedFile.new(
      StringIO.new(buf.string), "application/zip", true,
      original_filename: "empty.zip"
    )
  end

  def with_stubs(fake_batch:, &block)
    orig_batch_svc = BatchIngestionService.method(:new)
    orig_batch_cli = ClaudeBatchClient.method(:new)
    orig_kb        = KbSyncService.method(:new)
    orig_iss       = IngestionStatusService.method(:new)

    captured_batch = fake_batch
    BatchIngestionService.define_singleton_method(:new)  { |**_kw| FakeBatchIngestionService.new }
    ClaudeBatchClient.define_singleton_method(:new)      { |**_kw| captured_batch }
    KbSyncService.define_singleton_method(:new)          { |**_kw| FakeKbSync.new }
    IngestionStatusService.define_singleton_method(:new) { |**_kw| FakeIngestionSvc.new }

    block.call
  ensure
    BatchIngestionService.define_singleton_method(:new)  { |*a, **kw| orig_batch_svc.call(*a, **kw) }
    ClaudeBatchClient.define_singleton_method(:new)      { |*a, **kw| orig_batch_cli.call(*a, **kw) }
    KbSyncService.define_singleton_method(:new)          { |*a, **kw| orig_kb.call(*a, **kw) }
    IngestionStatusService.define_singleton_method(:new) { |*a, **kw| orig_iss.call(*a, **kw) }
  end
end
