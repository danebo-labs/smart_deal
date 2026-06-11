# frozen_string_literal: true

require "test_helper"

# Verifies that BatchResultsParserService#identity_header produces output
# byte-for-byte identical to the legacy Lambda `inject_identity` function.
#
# Reference: lambda_function.py → inject_identity (lines 69–82).
# Format: "[DOCUMENT: <filename>]\n[SOURCE_URI: <s3_uri>]\n[SEARCH_ALIASES: <a1>, <a2>, ...]\n\n"
#
# The golden fixture (test/fixtures/files/lambda_chunk_golden.json) contains
# an actual chunk shape from the OWRPGSX6XK data source for verification.
class LambdaParityTest < ActiveSupport::TestCase
  FIXTURE_PATH = File.join(File.dirname(__FILE__), "../fixtures/files/lambda_chunk_golden.json")

  class FakeS3Service
    attr_reader :uploads

    def initialize = (@uploads = {})
    def upload_text(key, content) = (@uploads[key] = content; key)
  end

  setup do
    @fixture     = JSON.parse(File.read(FIXTURE_PATH))
    @fake_s3     = FakeS3Service.new
    @parser      = BatchResultsParserService.new(s3_service: @fake_s3)
    ENV["KNOWLEDGE_BASE_S3_BUCKET"] = @fixture["s3_bucket"]
  end

  teardown do
    ENV.delete("KNOWLEDGE_BASE_S3_BUCKET")
  end

  # ---------------------------------------------------------------------------
  # Identity header byte-for-byte parity
  # ---------------------------------------------------------------------------

  test "identity_header matches Lambda inject_identity output byte-for-byte" do
    filename = @fixture["filename"]
    s3_key   = @fixture["s3_key"]
    aliases  = @fixture["aliases"]
    s3_bucket = @fixture["s3_bucket"]

    asset = ChunkAsset.new(filename: filename, sha256: "abc123", s3_key: s3_key)

    # Compute the header via the private method (accessible via send for tests)
    original_uri = "s3://#{s3_bucket}/#{s3_key}"
    computed_header = @parser.send(:identity_header, asset: asset, aliases: aliases, original_uri: original_uri)

    expected_header = @fixture["lambda_injected_header"]

    assert_equal expected_header, computed_header,
      "identity_header does not match Lambda output byte-for-byte.\n" \
      "Expected: #{expected_header.inspect}\n" \
      "Got:      #{computed_header.inspect}"
  end

  # ---------------------------------------------------------------------------
  # Header format validation
  # ---------------------------------------------------------------------------

  test "identity_header starts with [DOCUMENT: <filename>]" do
    asset = ChunkAsset.new(
      filename: @fixture["filename"],
      sha256:   "abc",
      s3_key:   @fixture["s3_key"]
    )
    uri    = "s3://#{@fixture['s3_bucket']}/#{@fixture['s3_key']}"
    header = @parser.send(:identity_header, asset: asset, aliases: @fixture["aliases"], original_uri: uri)

    assert header.start_with?("[DOCUMENT: #{@fixture['filename']}]\n"),
      "header should start with [DOCUMENT: <filename>]\\n"
  end

  test "identity_header contains [SOURCE_URI: ...]" do
    asset  = ChunkAsset.new(filename: @fixture["filename"], sha256: "abc", s3_key: @fixture["s3_key"])
    uri    = "s3://#{@fixture['s3_bucket']}/#{@fixture['s3_key']}"
    header = @parser.send(:identity_header, asset: asset, aliases: @fixture["aliases"], original_uri: uri)

    assert_includes header, "[SOURCE_URI: #{uri}]\n"
  end

  test "identity_header terminates with double newline after SEARCH_ALIASES" do
    asset  = ChunkAsset.new(filename: @fixture["filename"], sha256: "abc", s3_key: @fixture["s3_key"])
    uri    = "s3://#{@fixture['s3_bucket']}/#{@fixture['s3_key']}"
    header = @parser.send(:identity_header, asset: asset, aliases: @fixture["aliases"], original_uri: uri)

    assert header.end_with?("\n\n"),
      "header must end with \\n\\n so chunk body starts cleanly"
  end

  test "identity_header with empty aliases still compiles without empty SEARCH_ALIASES" do
    asset  = ChunkAsset.new(filename: "test.pdf", sha256: "abc", s3_key: "uploads/test.pdf")
    uri    = "s3://bucket/uploads/test.pdf"
    header = @parser.send(:identity_header, asset: asset, aliases: [], original_uri: uri)

    assert_includes header, "[SEARCH_ALIASES: ]\n\n"
  end

  # ---------------------------------------------------------------------------
  # Full parse cycle with ChunkAsset
  # ---------------------------------------------------------------------------

  test "BatchResultsParserService with ChunkAsset writes chunks and sets fields" do
    chunk_text = @fixture["chunks"].first["contentBody"]
    aliases    = @fixture["aliases"]
    doc_name   = @fixture["document_name"]

    raw_json = JSON.generate({
      "document_name" => doc_name,
      "aliases"       => aliases,
      "chunks"        => [ { "text" => chunk_text, "page" => 1, "field_records" => [] } ]
    })

    asset = ChunkAsset.new(
      filename:     @fixture["filename"],
      sha256:       "deadbeef" * 8,
      s3_key:       @fixture["s3_key"],
      content_type: "application/pdf"
    )

    result = @parser.call(asset: asset, raw_json: raw_json, ingestion_path: "web_v1")

    assert_equal doc_name, result.canonical_name
    assert_equal aliases,  result.aliases
    assert_equal 1,        result.chunks_count
    assert_not_nil result.chunks_s3_prefix

    chunk_0_key = "#{result.chunks_s3_prefix}/chunk_0.txt"
    assert @fake_s3.uploads.key?(chunk_0_key), "chunk_0.txt not written"
    assert @fake_s3.uploads[chunk_0_key].start_with?("[DOCUMENT: #{@fixture['filename']}]\n")
  end
end
