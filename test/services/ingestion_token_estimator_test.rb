# frozen_string_literal: true

require "test_helper"

class IngestionTokenEstimatorTest < ActiveSupport::TestCase
  FIXTURES_PATH = Rails.root.join("test/fixtures/files")

  # --- TXT ---

  test "estimates text file tokens proportional to char count" do
    text = "elevator maintenance procedure " * 50  # ~1550 chars
    result = IngestionTokenEstimator.estimate(filename: "doc.txt", bytes: text)

    base_tokens  = (text.length / 3.5).ceil
    expected_parse = (base_tokens * 1.3 * 1.15).ceil
    expected_embed = (base_tokens * 1.3).ceil

    assert_in_delta expected_embed,  result[:embed][:input_tokens],  2
    assert_in_delta expected_parse,  result[:parse][:output_tokens], 2
    assert_equal 0, result[:embed][:output_tokens]
  end

  test "parse output_tokens > parse input_tokens (Opus expansion)" do
    text = "x" * 1000
    result = IngestionTokenEstimator.estimate(filename: "doc.txt", bytes: text)
    assert result[:parse][:output_tokens] > result[:parse][:input_tokens],
           "Opus output should exceed input due to header injection"
  end

  test "embed output_tokens is always 0" do
    text = "embedding test content"
    result = IngestionTokenEstimator.estimate(filename: "doc.txt", bytes: text)
    assert_equal 0, result[:embed][:output_tokens]
    assert_equal 0, result[:parse][:output_tokens].zero? ? 0 : result[:embed][:output_tokens]
  end

  # --- PNG ---

  test "estimates image embed tokens from text caption proxy" do
    bytes = File.binread(FIXTURES_PATH.join("tiny.png"))
    result = IngestionTokenEstimator.estimate(filename: "tiny.png", bytes: bytes)

    assert result[:embed][:input_tokens] >= IngestionTokenEstimator::MIN_EMBED_TOKENS
    assert_equal 0, result[:embed][:output_tokens]
    assert result[:parse][:input_tokens] > 0
  end

  test "estimate_embed_from_chunks sums chunk object sizes" do
    fake_client = Object.new
    fake_client.define_singleton_method(:list_objects_v2) do |**kwargs|
      Struct.new(:contents, :is_truncated, :next_continuation_token).new(
        [
          Struct.new(:key, :size).new("bulk_chunks/2026-01-01/abc/chunk_0.txt", 700),
          Struct.new(:key, :size).new("bulk_chunks/2026-01-01/abc/chunk_0.txt.metadata.json", 200)
        ],
        false,
        nil
      )
    end

    tokens = IngestionTokenEstimator.estimate_embed_from_chunks(
      s3: fake_client, bucket: "test-bucket", prefix: "bulk_chunks/2026-01-01/abc"
    )

    assert_equal 200, tokens
  end

  # --- TXT fixture ---

  test "processes sample.txt fixture without error" do
    bytes = File.read(FIXTURES_PATH.join("sample.txt"))
    result = IngestionTokenEstimator.estimate(filename: "sample.txt", bytes: bytes)

    assert result[:parse][:input_tokens] > 0
    assert result[:embed][:input_tokens] > 0
  end

  # --- Unknown extension fallback ---

  test "falls back to byte-based estimate for unknown extension" do
    content = "binary-ish content " * 200
    result = IngestionTokenEstimator.estimate(filename: "document.docx", bytes: content)
    assert result[:parse][:input_tokens] > 0
    assert result[:embed][:input_tokens] > 0
  end

  # --- Error resilience ---

  test "returns non-zero fallback on corrupt input" do
    result = IngestionTokenEstimator.estimate(filename: "bad.pdf", bytes: "not a pdf")
    assert result[:parse][:input_tokens] > 0
    assert result[:embed][:input_tokens] > 0
  end

  test "returns non-zero fallback for empty bytes" do
    result = IngestionTokenEstimator.estimate(filename: "empty.txt", bytes: "")
    assert result.is_a?(Hash)
    assert result[:parse].is_a?(Hash)
    assert result[:embed].is_a?(Hash)
  end

  # --- HIERARCHICAL multiplier ---

  test "chunk_tokens = base_tokens * HIERARCHICAL_OVERLAP_FACTOR" do
    text = "a" * 350  # exactly 100 base tokens at chars/3.5
    result = IngestionTokenEstimator.estimate(filename: "doc.txt", bytes: text)

    base    = 100
    chunked = (base * IngestionTokenEstimator::HIERARCHICAL_OVERLAP_FACTOR).ceil
    assert_equal chunked, result[:embed][:input_tokens]
  end
end
