# frozen_string_literal: true

require "test_helper"
require "ostruct"

class FieldCompanionF2LetterBTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  FINGERPRINT = "4f62491874c8fea82d78632657e9adc93da80c69e40157eee98b5cfe972715d1"
  SONNET_55_DIRECT = {
    input: 0.002,
    output: 0.01,
    cache_read: 0.0002,
    cache_creation: 0.0025
  }.freeze
  ARTIFACTS = {
    "tmp/field_companion/f1_extended/aggregate.json" => "fe283538ceceaf8d90a3b9a4444868abf0886e1745584eb09cb67d35c6e3fa84",
    "tmp/field_companion/f1_extended/cost_report.json" => "72e13f1c32b7f9172301a206970df2a13707b0770dd4d14cb500a44affbdcc5b",
    "tmp/field_companion/f1_extended/gold_manifest.json" => "2329d9d8d4cedc4309a6f608e82a398ff6c5e0cd942e376e0b9b9a1098411fbc",
    "tmp/field_companion/f1_extended/manifest.json" => "62a639b54e17ae211d61407bdbb716844ce0d4e8480986dcaac12cfe2df0e477",
    "tmp/field_companion/f1_extended/SHA256SUMS.txt" => "c5987e91750648649ba743cf94f4a598d5920ba7f088e6b79ca6821aedf5a4b9",
    "tmp/field_companion/f1_visual.json" => "9244f1b5dca642ba72e45a938492a4036f548c9600047aafb0d7631a871868c4",
    "tmp/field_companion/outputs/spring_assembly_misread.claude-sonnet-5-5.txt" => "0806d1c5f6ad98c50b74a4bb409ef1d5aa57ebf161ff72700bd8482fa422066b",
    "tmp/field_companion/outputs/spring_assembly_misread.claude-opus-5-5.txt" => "f53745565e39091c5f622315e18d3e98d54c44cc4a64931a84d1211bdd452e3a",
    "tmp/field_companion/visual_manifest.json" => "7a17aad222d0be44bf961b7119226fef54632a3789aa11e4cd985b95431a05f1",
    "tmp/field_companion/images/spring_assembly_misread.png" => "202fbc9bee1f079914dfcb7dc5334ff1e9a776cb44b1c867c12a11ea04156ebd"
  }.freeze
  VALID_JSON = JSON.generate(
    "canonical_component" => "panel",
    "manufacturer" => "UNKNOWN",
    "model" => "UNKNOWN",
    "subsystem" => "UNKNOWN",
    "condition" => "UNKNOWN",
    "aliases" => [],
    "summary" => "Panel.",
    "visible_text" => [],
    "documented_functions" => [],
    "documented_connections" => [],
    "documented_values" => [],
    "documented_warnings" => [],
    "anti_hallucination_notes" => "Sin placa legible."
  ).freeze

  test "field photo default branch uses claude-sonnet-5-5" do
    result = analyze(binary: "jpeg")

    assert_equal "claude-sonnet-5-5", FieldPhotoAnalysisService::DEFAULT_MODEL
    assert_equal "claude-sonnet-5-5", result[:model]
    assert_equal "claude-sonnet-5", BatchChunkingPrompt::MODEL_TEXT
    assert_not_equal BatchChunkingPrompt::MODEL_TEXT, result[:model]
    assert_equal :sonnet, FieldPhotoDensityGate.decide(binary: "jpeg", content_type: "image/jpeg", filename: "door.jpg")
  end

  test "field photo opus branch keeps claude-opus-5-5" do
    binary = "x" * FieldPhotoDensityGate::LARGE_PHOTO_THRESHOLD
    result = analyze(binary: binary)

    assert_equal 1_500_000, FieldPhotoDensityGate::LARGE_PHOTO_THRESHOLD
    assert_equal "claude-opus-5-5", BatchChunkingPrompt::MODEL_MULTIMODAL
    assert_equal "claude-opus-5-5", result[:model]
    assert_equal :opus, FieldPhotoDensityGate.decide(binary: binary, content_type: "image/jpeg", filename: "door.jpg")
  end

  test "claude-sonnet-5-5-direct uses the cited rates and not default pricing" do
    rates = BedrockQuery::BEDROCK_PRICING.fetch("claude-sonnet-5-5-direct")
    query = BedrockQuery.new(
      model_id: "claude-sonnet-5-5-direct",
      input_tokens: 1_000,
      output_tokens: 1_000,
      cache_read_tokens: 1_000,
      cache_creation_tokens: 1_000
    )

    assert_equal SONNET_55_DIRECT, rates
    assert_same rates, query.pricing_for
    assert_not_equal BedrockQuery::BEDROCK_PRICING.fetch("default"), query.pricing_for
    assert_equal 0.0147, query.cost
    assert_equal SONNET_55_DIRECT, BedrockQuery::BEDROCK_PRICING.fetch("claude-sonnet-5-direct")
    assert_not_same rates, BedrockQuery::BEDROCK_PRICING.fetch("claude-sonnet-5-direct")
    assert_not BedrockQuery::BEDROCK_PRICING.key?("claude-sonnet-5-5-batch")
  end

  test "document ingestion text model stays claude-sonnet-5" do
    assert_equal "claude-sonnet-5", BatchChunkingPrompt::MODEL_TEXT
    assert_equal "claude-opus-5-5", BatchChunkingPrompt::MODEL_MULTIMODAL

    captured = []
    original = ClaudeChunkingClient.method(:new)
    ClaudeChunkingClient.define_singleton_method(:new) do |model:, **|
      captured << model
      client = Object.new
      client.define_singleton_method(:call) do |**|
        { text: "{}", usage: OpenStruct.new(input_tokens: 1, output_tokens: 1), stop_reason: "end_turn" }
      end
      client
    end

    page_result = { page_number: 1, model: "", text: "", stop_reason: "max_tokens" }
    BatchPageRetryService.new.send(
      :retry_one_page!,
      page_result,
      "%PDF-1.4",
      1,
      filename: "manual.pdf",
      sha256: "a" * 64,
      tracking_prefix: "bulk_retry",
      on_usage: ->(_) { },
      anchor_page_number: nil
    )

    assert_equal [ "claude-sonnet-5" ], captured.uniq
    assert_predicate captured, :any?
  ensure
    ClaudeChunkingClient.define_singleton_method(:new) { |*args, **kwargs| original.call(*args, **kwargs) } if original
  end

  test "field photo prompt fingerprint and ingestion contract versions stay put" do
    assert_equal FINGERPRINT, FieldPhotoPrompt.prompt_fingerprint_sha256
    assert_equal "field_photo_records_v3", FieldPhotoPrompt::INGESTION_CONTRACT_VERSION
    assert_equal "field_records_v8", BatchChunkingPrompt::INGESTION_CONTRACT_VERSION
  end

  test "recorded visual benchmark artifacts keep their hashes" do
    missing = ARTIFACTS.keys.reject { |relative| Rails.root.join(relative).file? }
    skip "visual benchmark artifacts are local: #{missing.join(', ')}" if missing.any?

    ARTIFACTS.each do |relative, expected|
      actual = Digest::SHA256.file(Rails.root.join(relative)).hexdigest
      assert_equal expected, actual, relative
    end
  end

  private

  def analyze(binary:)
    FieldPhotoAnalysisService.new(
      binary: binary,
      content_type: "image/jpeg",
      filename: "door.jpg",
      locale: :es,
      account_id: accounts(:legacy).id,
      user_id: users(:one).id,
      conv_session_id: nil,
      correlation_id: "photo:f2-letter-b",
      client: FakeClient.new(VALID_JSON)
    ).call
  end

  class FakeClient
    def initialize(text)
      @text = text
    end

    def call(**_kwargs)
      {
        text: @text,
        usage: OpenStruct.new(input_tokens: 10, output_tokens: 4),
        model: "ignored"
      }
    end
  end
end
