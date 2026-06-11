# frozen_string_literal: true

require "test_helper"
require "ostruct"
require "stringio"

ENV["RAG_BENCHMARK_LIBRARY_ONLY"] = "1"
require Rails.root.join("script/rag_quality_benchmark")
ENV.delete("RAG_BENCHMARK_LIBRARY_ONLY")

class RagQualityBenchmarkTest < ActiveSupport::TestCase
  FakeS3 = Struct.new(:objects) do
    def get_object(bucket:, key:)
      OpenStruct.new(body: StringIO.new(objects.fetch([ bucket, key ])))
    end
  end

  test "preflight rejects enabled reranking before benchmark queries" do
    benchmark = build_benchmark("BEDROCK_RERANKER_ENABLED" => "true")

    error = assert_raises(RagQualityBenchmark::PreflightError) do
      benchmark.preflight!
    end

    assert_includes error.message, "BEDROCK_RERANKER_ENABLED must be false"
  end

  test "preflight rejects enabled query routing" do
    benchmark = build_benchmark("QUERY_ROUTING_ENABLED" => "true")

    error = assert_raises(RagQualityBenchmark::PreflightError) do
      benchmark.preflight!
    end

    assert_includes error.message, "QUERY_ROUTING_ENABLED must be false"
  end

  test "retrieval preflight records effective configuration corpus hashes and allowlists" do
    preflight = build_benchmark.preflight!

    assert_equal false, preflight[:reranking_enabled]
    assert_equal false, preflight[:query_routing_enabled]
    assert_equal "test-kb", preflight[:knowledge_base_id]
    assert_equal "s3://benchmark/manual.pdf", preflight.dig(:corpus, :manual, :source_uri)
    assert_equal Digest::SHA256.hexdigest("manual bytes"),
                 preflight.dig(:corpus, :manual, :source_sha256)
    assert_equal Digest::SHA256.hexdigest("photo bytes"),
                 preflight.dig(:corpus, :image, :source_sha256)
    assert_equal RagRetrievalProfile::EXHAUSTIVE_CANDIDATES,
                 preflight.dig(:retrieval, :exhaustive_candidates)
    assert_match(/\A[0-9a-f]{64}\z/, preflight.dig(:code, :sha256))
  end

  test "certification rejects dirty git state" do
    benchmark = build_benchmark("RAG_BENCHMARK_MODE" => "certification")

    error = assert_raises(RagQualityBenchmark::PreflightError) do
      benchmark.preflight!
    end

    assert_includes error.message, "Certification requires git_dirty=false"
  end

  test "diagnostic targets expand conversational dependencies in matrix order" do
    benchmark = build_benchmark(
      "RAG_BENCHMARK_MODE" => "diagnostic",
      "RAG_BENCHMARK_TARGETS" =>
        "isolated:3,isolated:5,conversation:3,conversation:5"
    )

    mode = benchmark.send(:resolve_benchmark_mode)
    benchmark.instance_variable_set(:@benchmark_mode, mode)
    targets = benchmark.send(:resolve_target_case_keys)
    benchmark.instance_variable_set(:@target_case_keys, targets)

    assert_equal(
      %w[
        isolated:3 isolated:5
        conversation:1 conversation:2 conversation:3 conversation:4 conversation:5
      ],
      benchmark.send(:resolve_executed_case_keys)
    )
  end

  test "diagnostic rejects unknown and duplicate targets" do
    unknown = build_benchmark(
      "RAG_BENCHMARK_MODE" => "diagnostic",
      "RAG_BENCHMARK_TARGETS" => "isolated:3,unknown:1"
    )
    unknown.instance_variable_set(:@benchmark_mode, "diagnostic")
    assert_raises(RagQualityBenchmark::PreflightError) do
      unknown.send(:resolve_target_case_keys)
    end

    duplicate = build_benchmark(
      "RAG_BENCHMARK_MODE" => "diagnostic",
      "RAG_BENCHMARK_TARGETS" => "isolated:3,isolated:3"
    )
    duplicate.instance_variable_set(:@benchmark_mode, "diagnostic")
    assert_raises(RagQualityBenchmark::PreflightError) do
      duplicate.send(:resolve_target_case_keys)
    end
  end

  test "fingerprint includes evaluator corpus and rubric manifests" do
    assert_includes RagQualityBenchmark::FINGERPRINT_PATHS,
                    "script/evaluate_rag_quality_benchmark.rb"
    assert_includes RagQualityBenchmark::FINGERPRINT_PATHS,
                    "script/fixtures/rag_quality_benchmark_atomic_rubric.json"
    assert_includes RagQualityBenchmark::FINGERPRINT_PATHS,
                    "script/fixtures/rag_quality_benchmark_corpus.json"
  end

  test "retrieved source uris prefer original metadata and fall back safely" do
    citations = [
      {
        metadata: { "original_source_uri" => "s3://benchmark/manual.pdf" },
        location: { uri: "s3://benchmark/chunks/manual-1.txt" }
      },
      {
        metadata: { "x-amz-bedrock-kb-source-uri" => "s3://benchmark/photo.jpg" },
        location: { "uri" => "s3://benchmark/chunks/photo.txt" }
      },
      {
        metadata: { original_source_uri: "s3://benchmark/manual.pdf" },
        location: nil
      }
    ]

    assert_equal(
      [ "s3://benchmark/manual.pdf", "s3://benchmark/photo.jpg" ],
      RagQualityBenchmark.retrieved_source_uris(citations)
    )
  end

  private

  def build_benchmark(overrides = {})
    env = {
      "AWS_REGION" => "us-east-1",
      "BEDROCK_KNOWLEDGE_BASE_ID" => "test-kb",
      "BEDROCK_RERANKER_ENABLED" => "false",
      "QUERY_ROUTING_ENABLED" => "false",
      "RAG_BENCHMARK_MODE" => "retrieval_preflight"
    }.merge(overrides)
    canonical = {
      model_id: BedrockClient::QUERY_MODEL_ID,
      aws_region: "us-east-1",
      knowledge_base_id: "test-kb",
      session_identifier: "benchmark",
      session_channel: "shared",
      manual_key: "manual.pdf",
      image_key: "photo.jpg"
    }
    s3 = FakeS3.new(
      {
        [ "benchmark", "manual.pdf" ] => "manual bytes",
        [ "benchmark", "photo.jpg" ] => "photo bytes"
      }
    )
    benchmark = RagQualityBenchmark.new(
      env: env,
      canonical: canonical,
      s3_client: s3,
      aws_identity_loader: -> { { "Account" => "123", "Arn" => "arn:test", "UserId" => "user" } }
    )
    benchmark.define_singleton_method(:load_json_manifest) { |_path| nil }
    benchmark.instance_variable_set(:@benchmark_mode, env.fetch("RAG_BENCHMARK_MODE"))
    benchmark.instance_variable_set(
      :@session,
      OpenStruct.new(identifier: "benchmark", channel: "shared")
    )
    benchmark.instance_variable_set(
      :@manual,
      fake_document(1, "manual.pdf", "s3://benchmark/manual.pdf")
    )
    benchmark.instance_variable_set(
      :@image,
      fake_document(2, "photo.jpg", "s3://benchmark/photo.jpg")
    )
    benchmark
  end

  def fake_document(id, key, uri)
    document = OpenStruct.new(
      id: id,
      s3_key: key,
      display_name: key,
      aliases: []
    )
    document.define_singleton_method(:display_s3_uri) { |_bucket| uri }
    document
  end
end
