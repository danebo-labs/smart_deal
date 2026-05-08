# frozen_string_literal: true

require "test_helper"
require "ostruct"

class BatchResultsParserServiceTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  # Suppress Turbo broadcast — the _asset partial isn't created until step 15.
  setup do
    @_orig_broadcast = BulkUploadAsset.instance_method(:broadcast_replace!)
    BulkUploadAsset.define_method(:broadcast_replace!) { }
  end

  teardown do
    BulkUploadAsset.define_method(:broadcast_replace!, @_orig_broadcast)
  end

  # ---------------------------------------------------------------------------
  # Fake S3 service — records upload_text calls
  # ---------------------------------------------------------------------------

  class FakeS3Service
    attr_reader :uploads

    def initialize
      @uploads = {}
    end

    def upload_text(key, content)
      @uploads[key] = content
      key
    end
  end

  # ---------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------

  DOC_NAME = "Hydraulic Pump Manual"
  ALIASES  = [ "HPM-400", "pump manual" ]

  def chunk0_text
    "**Document: #{DOC_NAME}**\n**DOCUMENT_ALIASES:**\n- #{ALIASES[0]}\n- #{ALIASES[1]}\n\nHydraulic pressure: 3000 PSI max."
  end

  def chunk1_text
    "**Document: #{DOC_NAME}**\n\nOil viscosity: ISO 46."
  end

  def golden_parsed
    {
      "document_name" => DOC_NAME,
      "aliases"        => ALIASES,
      "chunks"         => [
        { "text" => chunk0_text, "page" => 1 },
        { "text" => chunk1_text, "page" => 2 }
      ]
    }
  end

  def make_result(json_text: golden_parsed.to_json, result_type: "succeeded")
    message = OpenStruct.new(
      content: [
        OpenStruct.new(type: "text", text: json_text)
      ]
    )
    inner = OpenStruct.new(type: result_type, message: message)
    OpenStruct.new(result: inner)
  end

  def make_asset(status: "in_batch")
    upload = BulkUpload.create!(
      sha256:            SecureRandom.hex(16),
      original_filename: "test.zip",
      status:            "processing",
      asset_count:       0
    )
    BulkUploadAsset.create!(
      bulk_upload: upload,
      custom_id:   SecureRandom.hex(16),
      sha256:      SecureRandom.hex(32),
      filename:    "pump_photo.jpg",
      s3_key:      "bulk_uploads/2026-05-07/pump_photo.jpg",
      status:      status
    )
  end

  def build_parser
    @fake_s3 = FakeS3Service.new
    BatchResultsParserService.new(s3_service: @fake_s3)
  end

  # ---------------------------------------------------------------------------
  # Happy path
  # ---------------------------------------------------------------------------

  test "transitions asset to parsed and persists canonical_name and aliases" do
    asset  = make_asset
    parser = build_parser

    parser.call(asset: asset, result: make_result)

    asset.reload
    assert_equal "parsed",  asset.status
    assert_equal DOC_NAME,  asset.canonical_name
    assert_equal ALIASES,   asset.aliases
    assert_equal 2,         asset.chunks_count
    assert_not_nil          asset.chunks_s3_prefix
  end

  test "writes a .txt and a .metadata.json sidecar per chunk" do
    asset  = make_asset
    parser = build_parser

    parser.call(asset: asset, result: make_result)

    prefix = asset.reload.chunks_s3_prefix
    assert_equal 4, @fake_s3.uploads.size
    %w[chunk_0.txt chunk_0.txt.metadata.json chunk_1.txt chunk_1.txt.metadata.json].each do |suffix|
      assert @fake_s3.uploads.key?("#{prefix}/#{suffix}"), "missing #{suffix}"
    end
  end

  test "chunk text is prefixed with the legacy identity header (DOCUMENT/SOURCE_URI/SEARCH_ALIASES)" do
    ENV["KNOWLEDGE_BASE_S3_BUCKET"] = "multimodal-source-destination"
    asset  = make_asset
    parser = build_parser

    parser.call(asset: asset, result: make_result)

    prefix  = asset.reload.chunks_s3_prefix
    chunk_0 = @fake_s3.uploads["#{prefix}/chunk_0.txt"]
    chunk_1 = @fake_s3.uploads["#{prefix}/chunk_1.txt"]

    assert chunk_0.start_with?("[DOCUMENT: pump_photo.jpg]\n")
    assert_includes chunk_0,
      "[SOURCE_URI: s3://multimodal-source-destination/bulk_uploads/2026-05-07/pump_photo.jpg]\n"
    assert_includes chunk_0, "[SEARCH_ALIASES: HPM-400, pump manual]\n\n"
    assert_includes chunk_0, chunk0_text

    assert chunk_1.start_with?("[DOCUMENT: pump_photo.jpg]\n")
    assert_includes chunk_1, chunk1_text
  ensure
    ENV.delete("KNOWLEDGE_BASE_S3_BUCKET")
  end

  test "metadata.json sidecar carries original_source_uri and canonical_name for retrieval filtering" do
    ENV["KNOWLEDGE_BASE_S3_BUCKET"] = "multimodal-source-destination"
    asset  = make_asset
    parser = build_parser

    parser.call(asset: asset, result: make_result)

    prefix = asset.reload.chunks_s3_prefix
    meta   = JSON.parse(@fake_s3.uploads["#{prefix}/chunk_0.txt.metadata.json"])

    attrs = meta["metadataAttributes"]
    assert_equal "s3://multimodal-source-destination/bulk_uploads/2026-05-07/pump_photo.jpg",
                 attrs["original_source_uri"]
    assert_equal "pump_photo.jpg",        attrs["original_filename"]
    assert_equal DOC_NAME,                attrs["canonical_name"]
    assert_equal asset.sha256,            attrs["doc_sha256"]
    assert_equal "batch_v1",              attrs["ingestion_path"]
    assert_equal ALIASES,                 attrs["aliases"]
  ensure
    ENV.delete("KNOWLEDGE_BASE_S3_BUCKET")
  end

  test "chunks_s3_prefix uses bulk_chunks/<date>/<sha256> pattern" do
    asset  = make_asset
    parser = build_parser

    parser.call(asset: asset, result: make_result)

    prefix = asset.reload.chunks_s3_prefix
    assert_match(%r{\Abulk_chunks/\d{4}-\d{2}-\d{2}/[a-f0-9]+\z}, prefix)
    assert_includes prefix, asset.sha256
  end

  # ---------------------------------------------------------------------------
  # Validation failures
  # ---------------------------------------------------------------------------

  test "raises ParseError and marks asset failed when result type is not succeeded" do
    asset  = make_asset
    parser = build_parser

    assert_raises(BatchResultsParserService::ParseError) do
      parser.call(asset: asset, result: make_result(result_type: "errored"))
    end

    assert_equal "failed", asset.reload.status
  end

  test "raises ParseError when JSON is invalid" do
    asset  = make_asset
    parser = build_parser

    assert_raises(BatchResultsParserService::ParseError) do
      parser.call(asset: asset, result: make_result(json_text: "not json {{"))
    end

    assert_equal "failed", asset.reload.status
  end

  test "raises ParseError when chunk[0] missing Document header" do
    bad_chunks = golden_parsed.merge(
      "chunks" => [
        { "text" => "Missing headers. Some content.", "page" => 1 }
      ]
    )
    asset  = make_asset
    parser = build_parser

    assert_raises(BatchResultsParserService::ParseError) do
      parser.call(asset: asset, result: make_result(json_text: bad_chunks.to_json))
    end

    assert_equal "failed", asset.reload.status
  end

  test "raises ParseError when chunk[0] missing DOCUMENT_ALIASES header" do
    bad_chunks = golden_parsed.merge(
      "chunks" => [
        { "text" => "**Document: #{DOC_NAME}**\n\nNo aliases block.", "page" => 1 }
      ]
    )
    asset  = make_asset
    parser = build_parser

    assert_raises(BatchResultsParserService::ParseError) do
      parser.call(asset: asset, result: make_result(json_text: bad_chunks.to_json))
    end
  end

  test "raises ParseError when required keys are missing" do
    asset  = make_asset
    parser = build_parser

    assert_raises(BatchResultsParserService::ParseError) do
      parser.call(asset: asset, result: make_result(json_text: '{"foo":"bar"}'))
    end
  end

  test "raises ParseError when chunks array is empty" do
    empty = golden_parsed.merge("chunks" => [])
    asset  = make_asset
    parser = build_parser

    assert_raises(BatchResultsParserService::ParseError) do
      parser.call(asset: asset, result: make_result(json_text: empty.to_json))
    end
  end
end
