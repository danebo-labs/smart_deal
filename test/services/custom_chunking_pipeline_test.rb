# frozen_string_literal: true

require "test_helper"
require "ostruct"

class CustomChunkingPipelineTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  setup do
    @orig_s3_new  = S3DocumentsService.method(:new)
    @orig_sfc_new = SingleFileChunkingService.method(:new)
    @orig_bulk    = BulkKbSyncService.instance_method(:sync!)
    @orig_track   = TrackBedrockQueryJob.method(:perform_later)

    fake_s3 = Object.new
    fake_s3.define_singleton_method(:upload_file) { |fn, _bin, _ct| "uploads/#{fn}" }
    fake_s3.define_singleton_method(:upload_text) { |key, _content| key }
    S3DocumentsService.define_singleton_method(:new) { |*| fake_s3 }

    BulkKbSyncService.define_method(:sync!) { |**| nil }
    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**| nil }
  end

  teardown do
    S3DocumentsService.define_singleton_method(:new, @orig_s3_new)
    SingleFileChunkingService.define_singleton_method(:new, @orig_sfc_new)
    BulkKbSyncService.define_method(:sync!, @orig_bulk)
    TrackBedrockQueryJob.define_singleton_method(:perform_later, @orig_track)
  end

  def fake_sfc(canonical_name:, aliases:, summary:, filename:)
    asset = ChunkAsset.new(
      filename: filename, sha256: "abc123",
      s3_key: "uploads/#{filename}", content_type: "image/jpeg"
    )
    asset.canonical_name = canonical_name
    asset.aliases        = aliases
    asset.summary        = summary
    OpenStruct.new(call: asset)
  end

  test "web_v1_metadata includes summary for images" do
    SingleFileChunkingService.define_singleton_method(:new) do |**kwargs|
      asset = ChunkAsset.new(
        filename: kwargs[:filename], sha256: "abc123",
        s3_key: "uploads/#{kwargs[:filename]}", content_type: kwargs[:content_type]
      )
      asset.canonical_name  = "Schindler controller"
      asset.aliases         = [ "5500" ]
      asset.summary         = "Imagen del cuadro Schindler."
      asset.companion_offer = "Pregúntame lo que necesites."
      OpenStruct.new(call: asset)
    end

    image = { data: Base64.strict_encode64("xx"), media_type: "image/jpeg", filename: "photo.jpg" }

    pipeline = CustomChunkingPipeline.new(
      images: [ image ], documents: [], conv_session: nil, tenant: nil, locale: "es"
    )
    pipeline.run!

    metadata = pipeline.instance_variable_get(:@web_v1_metadata).first
    assert_equal "Schindler controller",          metadata["canonical_name"]
    assert_equal "Imagen del cuadro Schindler.",  metadata["summary"]
    assert_equal "Pregúntame lo que necesites.",  metadata["companion_offer"]
  end

  test "web_v1_metadata includes companion_offer for images" do
    SingleFileChunkingService.define_singleton_method(:new) do |**kwargs|
      asset = ChunkAsset.new(
        filename: kwargs[:filename], sha256: "abc123",
        s3_key: "uploads/#{kwargs[:filename]}", content_type: kwargs[:content_type]
      )
      asset.canonical_name  = "Schindler controller"
      asset.aliases         = [ "5500" ]
      asset.summary         = "Parece el cuadro de un Schindler."
      asset.companion_offer = "Dime qué quieres saber."
      OpenStruct.new(call: asset)
    end

    image = { data: Base64.strict_encode64("xx"), media_type: "image/jpeg", filename: "photo.jpg" }

    pipeline = CustomChunkingPipeline.new(
      images: [ image ], documents: [], conv_session: nil, tenant: nil, locale: "es"
    )
    pipeline.run!

    metadata = pipeline.instance_variable_get(:@web_v1_metadata).first
    assert_equal "Dime qué quieres saber.", metadata["companion_offer"]
  end

  test "web_v1_metadata summary is nil when ChunkAsset.summary is nil (PDF path)" do
    SingleFileChunkingService.define_singleton_method(:new) do |**kwargs|
      asset = ChunkAsset.new(
        filename: kwargs[:filename], sha256: "def456",
        s3_key: "uploads/#{kwargs[:filename]}", content_type: kwargs[:content_type]
      )
      asset.canonical_name = "Elevator Manual"
      asset.aliases        = [ "manual" ]
      asset.summary        = nil
      OpenStruct.new(call: asset)
    end

    doc = { data: Base64.strict_encode64("pdf"), media_type: "application/pdf", filename: "manual.pdf" }

    pipeline = CustomChunkingPipeline.new(
      images: [], documents: [ doc ], conv_session: nil, tenant: nil, locale: "es"
    )
    pipeline.run!

    metadata = pipeline.instance_variable_get(:@web_v1_metadata).first
    assert_nil metadata["summary"]
  end

  test "locale is forwarded to SingleFileChunkingService" do
    captured_locale = nil

    SingleFileChunkingService.define_singleton_method(:new) do |**kwargs|
      captured_locale = kwargs[:locale]
      asset = ChunkAsset.new(
        filename: kwargs[:filename], sha256: "ghi789",
        s3_key: "uploads/#{kwargs[:filename]}", content_type: kwargs[:content_type]
      )
      asset.canonical_name = "Test Doc"
      asset.aliases        = []
      OpenStruct.new(call: asset)
    end

    image = { data: Base64.strict_encode64("xx"), media_type: "image/jpeg", filename: "photo.jpg" }

    CustomChunkingPipeline.new(
      images: [ image ], documents: [], conv_session: nil, tenant: nil, locale: "en"
    ).run!

    assert_equal "en", captured_locale
  end
end
