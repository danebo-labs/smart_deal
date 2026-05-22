# frozen_string_literal: true

require "test_helper"
require "ostruct"

# Tests for CUSTOM_CHUNKING_COST_V2_ENABLED routing in CustomChunkingPipeline.
class CustomChunkingPipelineCostV2Test < ActiveSupport::TestCase
  parallelize(workers: 1)

  setup do
    @orig_s3_new  = S3DocumentsService.method(:new)
    @orig_sfc_new = SingleFileChunkingService.method(:new)
    @orig_bulk    = BulkKbSyncService.instance_method(:sync!)
    @orig_track   = TrackBedrockQueryJob.method(:perform_later)
    @orig_smb     = SubmitManualBatchJob.method(:perform_later)
    @orig_dedup   = ContentDedupService.method(:find_completed)

    fake_s3 = Object.new
    fake_s3.define_singleton_method(:upload_file) { |fn, _bin, _ct| "uploads/#{fn}" }
    fake_s3.define_singleton_method(:upload_text) { |key, _content| key }
    S3DocumentsService.define_singleton_method(:new) { |*| fake_s3 }

    BulkKbSyncService.define_method(:sync!) { |**| nil }
    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**| nil }

    # Default dedup: no hit
    ContentDedupService.define_singleton_method(:find_completed) do |sha256:|
      ContentDedupService::Result.new(hit: false, asset: nil, canonical_name: nil, aliases: [])
    end

    # Default SubmitManualBatchJob: track calls
    @batch_job_calls = []
    batch_job_calls  = @batch_job_calls
    SubmitManualBatchJob.define_singleton_method(:perform_later) do |**kwargs|
      batch_job_calls << kwargs
    end

    # Default SingleFileChunkingService: returns a simple ChunkAsset
    SingleFileChunkingService.define_singleton_method(:new) do |**kwargs|
      asset = ChunkAsset.new(
        filename: kwargs[:filename], sha256: "abc",
        s3_key: "uploads/#{kwargs[:filename]}", content_type: kwargs[:content_type]
      )
      asset.canonical_name = "Test Doc"
      asset.aliases        = []
      OpenStruct.new(call: asset)
    end

    @orig_env_v2   = ENV["CUSTOM_CHUNKING_COST_V2_ENABLED"]
    @orig_env_sync = ENV["MANUAL_FORCE_SYNC"]
  end

  teardown do
    S3DocumentsService.define_singleton_method(:new, @orig_s3_new)
    SingleFileChunkingService.define_singleton_method(:new, @orig_sfc_new)
    BulkKbSyncService.define_method(:sync!, @orig_bulk)
    TrackBedrockQueryJob.define_singleton_method(:perform_later, @orig_track)
    SubmitManualBatchJob.define_singleton_method(:perform_later, @orig_smb)
    ContentDedupService.define_singleton_method(:find_completed, @orig_dedup)
    ENV["CUSTOM_CHUNKING_COST_V2_ENABLED"] = @orig_env_v2
    ENV["MANUAL_FORCE_SYNC"]               = @orig_env_sync
  end

  test "PDF routes to batch when cost_v2 enabled and no force_sync" do
    ENV["CUSTOM_CHUNKING_COST_V2_ENABLED"] = "true"

    doc = { data: Base64.strict_encode64("pdf"), media_type: "application/pdf", filename: "manual.pdf" }
    CustomChunkingPipeline.new(images: [], documents: [ doc ], conv_session: nil).run!

    assert_equal 1, @batch_job_calls.size, "expected SubmitManualBatchJob.perform_later for PDF"
    assert_equal "manual.pdf", @batch_job_calls.first[:filename]
  end

  test "PDF routes to sync when cost_v2 enabled but force_sync=true" do
    ENV["CUSTOM_CHUNKING_COST_V2_ENABLED"] = "true"

    doc = { data: Base64.strict_encode64("pdf"), media_type: "application/pdf", filename: "manual.pdf" }
    sfc_calls = 0
    SingleFileChunkingService.define_singleton_method(:new) do |**kwargs|
      sfc_calls += 1
      asset = ChunkAsset.new(
        filename: kwargs[:filename], sha256: "abc",
        s3_key: "uploads/#{kwargs[:filename]}", content_type: kwargs[:content_type]
      )
      asset.canonical_name = "Test Doc"
      asset.aliases        = []
      OpenStruct.new(call: asset)
    end

    CustomChunkingPipeline.new(images: [], documents: [ doc ], conv_session: nil, force_sync: true).run!

    assert_equal 0, @batch_job_calls.size, "batch job should NOT fire with force_sync=true"
    assert_equal 1, sfc_calls, "SingleFileChunkingService should be called for sync path"
  end

  test "PDF routes to sync when MANUAL_FORCE_SYNC env set" do
    ENV["CUSTOM_CHUNKING_COST_V2_ENABLED"] = "true"
    ENV["MANUAL_FORCE_SYNC"]               = "true"

    doc      = { data: Base64.strict_encode64("pdf"), media_type: "application/pdf", filename: "manual.pdf" }
    pipeline = CustomChunkingPipeline.new(images: [], documents: [ doc ], conv_session: nil)
    pipeline.run!

    assert_equal 0, @batch_job_calls.size, "batch job should NOT fire when MANUAL_FORCE_SYNC=true"
  end

  test "PDF routes to sync (not batch) when cost_v2 flag is OFF" do
    ENV["CUSTOM_CHUNKING_COST_V2_ENABLED"] = nil

    doc      = { data: Base64.strict_encode64("pdf"), media_type: "application/pdf", filename: "manual.pdf" }
    sfc_calls = 0
    SingleFileChunkingService.define_singleton_method(:new) do |**kwargs|
      sfc_calls += 1
      asset = ChunkAsset.new(
        filename: kwargs[:filename], sha256: "def",
        s3_key: "uploads/#{kwargs[:filename]}", content_type: kwargs[:content_type]
      )
      asset.canonical_name = "Test Doc"
      asset.aliases        = []
      OpenStruct.new(call: asset)
    end

    CustomChunkingPipeline.new(images: [], documents: [ doc ], conv_session: nil).run!

    assert_equal 0, @batch_job_calls.size
    assert_equal 1, sfc_calls
  end

  test "images always use sync path regardless of cost_v2 flag" do
    ENV["CUSTOM_CHUNKING_COST_V2_ENABLED"] = "true"

    image     = { data: Base64.strict_encode64("img"), media_type: "image/jpeg", filename: "photo.jpg" }
    sfc_calls = 0
    SingleFileChunkingService.define_singleton_method(:new) do |**kwargs|
      sfc_calls += 1
      asset = ChunkAsset.new(
        filename: kwargs[:filename], sha256: "ghi",
        s3_key: "uploads/#{kwargs[:filename]}", content_type: kwargs[:content_type]
      )
      asset.canonical_name = "Photo Doc"
      asset.aliases        = []
      OpenStruct.new(call: asset)
    end

    CustomChunkingPipeline.new(images: [ image ], documents: [], conv_session: nil).run!

    assert_equal 0, @batch_job_calls.size, "images should NOT go through batch"
    assert_equal 1, sfc_calls, "images should always use SingleFileChunkingService"
  end
end
