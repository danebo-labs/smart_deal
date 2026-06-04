# frozen_string_literal: true

require "test_helper"

class IngestBatchResultsJobTest < ActiveJob::TestCase
  parallelize(workers: 1)

  # ── Fakes ─────────────────────────────────────────────────────────────────────

  FakeUsage = Struct.new(:input_tokens, :output_tokens,
                          :cache_read_input_tokens, :cache_creation_input_tokens,
                          keyword_init: true)

  FakeMessage = Struct.new(:model, :content, :usage, keyword_init: true)
  FakeResult  = Struct.new(:type, :message, keyword_init: true)
  FakeBatchResult = Struct.new(:custom_id, :result, keyword_init: true)

  class FakeBatchClient
    attr_accessor :results

    def initialize(results = [])
      @results = results
    end

    def results_each(batch_id:)
      @results.each { |r| yield r }
    end
  end

  # ── Constants ─────────────────────────────────────────────────────────────────

  PHOTO_JSON = JSON.generate({
    "canonical_component" => "Motor Drive Unit",
    "manufacturer" => "Orona",
    "model" => "MDU-3000",
    "subsystem" => "MOTOR_DRIVE",
    "condition" => "GOOD",
    "aliases" => [ "MDU-3000", "Orona motor" ],
    "summary" => "Motor drive unit in good condition.",
    "anti_hallucination_notes" => "Manufacturer visible."
  })

  PAGE1_JSON = JSON.generate({
    "document_name" => "Orona ARCA II Manual",
    "aliases" => [ "ARCA II" ],
    "summary" => "Manual.",
    "companion_offer" => "Pregunta.",
    "chunks" => [ { "text" => "S0 page 1 content", "page" => 1 } ]
  })

  PAGE2_JSON = JSON.generate({
    "document_name" => "Orona ARCA II Manual",
    "aliases" => [ "ARCA II", "installation" ],
    "summary" => "Parte 2.",
    "companion_offer" => "Cualquier duda.",
    "chunks" => [ { "text" => "S16 page 2 content", "page" => 2 } ]
  })

  def make_usage(input: 100, output: 50, cache_read: 10, cache_creation: 5)
    FakeUsage.new(
      input_tokens: input,
      output_tokens: output,
      cache_read_input_tokens: cache_read,
      cache_creation_input_tokens: cache_creation
    )
  end

  def make_message(json, model: "claude-sonnet-4-6", usage: nil)
    FakeMessage.new(
      model:   model,
      content: [ OpenStruct.new(type: "text", text: json) ],
      usage:   usage || make_usage
    )
  end

  # ── Setup / Teardown ──────────────────────────────────────────────────────────

  setup do
    @orig_upload_text  = S3DocumentsService.instance_method(:upload_text)
    @orig_sync         = BulkKbSyncService.instance_method(:sync!)
    @orig_client_new   = ClaudeBatchClient.method(:new)

    S3DocumentsService.define_method(:upload_text) { |_key, _body| nil }
    BulkKbSyncService.define_method(:sync!) { |**| { job_id: "test-job-123" } }

    @fake_client = FakeBatchClient.new
    _fc = @fake_client  # captured by closure; not resolved via receiver
    ClaudeBatchClient.define_singleton_method(:new) { _fc }

    # Suppress PollBulkBedrockIngestionJob (OpenStruct.perform_later: nil is not callable)
    @orig_poll_set = PollBulkBedrockIngestionJob.method(:set)
    noop_poll = Class.new do
      def self.perform_later(*); end
    end
    PollBulkBedrockIngestionJob.define_singleton_method(:set) { |**| noop_poll }
  end

  teardown do
    S3DocumentsService.define_method(:upload_text, @orig_upload_text)
    BulkKbSyncService.define_method(:sync!, @orig_sync)
    ClaudeBatchClient.singleton_class.remove_method(:new) rescue nil
    PollBulkBedrockIngestionJob.define_singleton_method(:set, @orig_poll_set)
  end

  # ── Helper ─────────────────────────────────────────────────────────────────────

  def create_bulk_with_assets
    bulk = BulkUpload.create!(
      sha256: Digest::SHA256.hexdigest("bulk_#{SecureRandom.hex(8)}"),
      original_filename: "mixed.zip",
      status: "processing",
      claude_batch_id: "msgbatch_test_001"
    )

    sha_photo = Digest::SHA256.hexdigest("photo_binary")
    sha_pdf   = Digest::SHA256.hexdigest("pdf_binary")

    photo_asset = BulkUploadAsset.create!(
      bulk_upload:    bulk,
      custom_id:      sha_photo[0, 32],
      sha256:         sha_photo,
      s3_key:         "bulk_uploads/photo.jpg",
      filename:       "photo.jpg",
      content_type:   "image/jpeg",
      status:         "in_batch",
      ingestion_path: "field_photo_v1"
    )

    pdf_sha_prefix = sha_pdf[0, 16]
    pdf_asset = BulkUploadAsset.create!(
      bulk_upload:      bulk,
      custom_id:        sha_pdf[0, 32],
      sha256:           sha_pdf,
      s3_key:           "bulk_uploads/manual.pdf",
      filename:         "manual.pdf",
      content_type:     "application/pdf",
      status:           "in_batch",
      ingestion_path:   "manual_batch_v1",
      batch_custom_ids: [ "#{pdf_sha_prefix}_p1", "#{pdf_sha_prefix}_p2" ]
    )

    [ bulk, photo_asset, pdf_asset, pdf_sha_prefix ]
  end

  # ── Tests ─────────────────────────────────────────────────────────────────────

  test "track_asset_usage skips when message has no usage" do
    assert_no_enqueued_jobs only: TrackBedrockQueryJob do
      job   = IngestBatchResultsJob.new
      asset = Object.new
      asset.define_singleton_method(:update_columns) { |_| flunk("should not update") }
      msg = Struct.new(:content).new([])
      job.send(:track_asset_usage, asset, msg, user_query: "test", ingestion_path: "batch_v1")
    end
  end

  test "photo → field_photo_v1 parsed; PDF pages merged → manual_batch_v1 parsed" do
    bulk, photo_asset, pdf_asset, pdf_sha_prefix = create_bulk_with_assets

    @fake_client.results = [
      FakeBatchResult.new(
        custom_id: photo_asset.custom_id,
        result:    FakeResult.new(type: "succeeded", message: make_message(PHOTO_JSON))
      ),
      FakeBatchResult.new(
        custom_id: "#{pdf_sha_prefix}_p1",
        result:    FakeResult.new(type: "succeeded", message: make_message(PAGE1_JSON))
      ),
      FakeBatchResult.new(
        custom_id: "#{pdf_sha_prefix}_p2",
        result:    FakeResult.new(type: "succeeded",
                                 message: make_message(PAGE2_JSON, usage: make_usage(input: 200, output: 80)))
      )
    ]

    IngestBatchResultsJob.perform_now(bulk.id)

    photo_asset.reload
    pdf_asset.reload

    assert_equal "syncing",          photo_asset.status
    assert_equal "Motor Drive Unit", photo_asset.canonical_name

    assert_equal "syncing",               pdf_asset.status
    assert_equal "Orona ARCA II Manual",  pdf_asset.canonical_name

    # PDF tokens: accumulate page1 (100+10+5=115) + page2 (200+10+5=215) = 330
    assert_equal 115 + 215, pdf_asset.claude_input_tokens
    assert_equal 50  + 80,  pdf_asset.claude_output_tokens
  ensure
    bulk&.bulk_upload_assets&.destroy_all
    bulk&.destroy
  end

  test "TrackBedrockQueryJob emitted with -batch suffix for PDF pages" do
    bulk, _photo_asset, pdf_asset, pdf_sha_prefix = create_bulk_with_assets

    # Only PDF pages — skip photo for this assertion
    @fake_client.results = [
      FakeBatchResult.new(
        custom_id: "#{pdf_sha_prefix}_p1",
        result:    FakeResult.new(type: "succeeded", message: make_message(PAGE1_JSON))
      ),
      FakeBatchResult.new(
        custom_id: "#{pdf_sha_prefix}_p2",
        result:    FakeResult.new(type: "succeeded", message: make_message(PAGE2_JSON))
      )
    ]

    IngestBatchResultsJob.perform_now(bulk.id)

    tracking = enqueued_jobs
      .select { |j| j[:job] == TrackBedrockQueryJob }
      .map { |j| j[:args].first }

    assert tracking.any? { |a| a["model_id"]&.end_with?("-batch") },
           "Expected at least one TrackBedrockQueryJob with -batch model_id"
    assert tracking.any? { |a| a["user_query"]&.start_with?("bulk_batch:") },
           "Expected user_query to start with 'bulk_batch:'"
  ensure
    bulk&.bulk_upload_assets&.destroy_all
    bulk&.destroy
  end
end
