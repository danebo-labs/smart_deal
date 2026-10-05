# frozen_string_literal: true

require "test_helper"
require Rails.root.join("script/field_companion/f1_sonnet_generation")

class FieldCompanionF1SonnetGenerationTest < ActiveSupport::TestCase
  Gen = FieldCompanion::F1SonnetGeneration

  test "request keeps the haiku invoke body and turns up-front thinking off" do
    body = Gen.request_body(prompt: Gen::PREFLIGHT_PROMPT, max_tokens: 3000, temperature: 0.1)

    assert_equal "bedrock-2023-05-31", body[:anthropic_version]
    assert_equal 3000, body[:max_tokens]
    assert_equal 0.1, body[:temperature]
    assert_equal "between_tools", body.dig(:thinking, :type)
    assert_nil body[:tools]
    assert_nil body[:output_config]
    assert_equal({ input: 0.002, output: 0.01, cache_read: 0.0002, cache_creation: 0.0025 }, Gen::PRICING)
    assert_equal BedrockQuery::BEDROCK_PRICING.fetch("global.anthropic.claude-sonnet-5-5"), Gen::PRICING
    assert_not_equal(
      BedrockQuery::BEDROCK_PRICING.fetch("global.anthropic.claude-haiku-4-5-20251001-v1:0"),
      Gen::PRICING.slice(:input, :output)
    )
  end

  test "answer text skips a leading thinking block" do
    content = [
      { "type" => "thinking", "thinking" => "SECRET_THINKING" },
      { "type" => "text", "text" => "PREFLIGHT_OK" }
    ]

    assert_equal "PREFLIGHT_OK", Gen.answer_text(content)
    assert_not_includes Gen.answer_text(content), "SECRET_THINKING"
  end

  test "invoke records the returned sonnet model and a non-zero price" do
    payload = {
      "model" => "claude-sonnet-5-5",
      "stop_reason" => "end_turn",
      "content" => [
        { "type" => "thinking", "thinking" => "hidden" },
        { "type" => "text", "text" => "PREFLIGHT_OK" }
      ],
      "usage" => { "input_tokens" => 20, "output_tokens" => 8, "cache_read_input_tokens" => 0, "cache_creation_input_tokens" => 0 }
    }
    response = Struct.new(:body).new(StringIO.new(payload.to_json))
    client = Object.new
    client.define_singleton_method(:invoke_model) { |**| response }
    enqueued = []
    TrackBedrockQueryJob.singleton_class.alias_method(:f1_sonnet_test_perform_later, :perform_later)
    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**kwargs| enqueued << kwargs }

    begin
      result = Gen.invoke(client: client, prompt: Gen::PREFLIGHT_PROMPT, max_tokens: 64, temperature: 0)

      assert_equal "PREFLIGHT_OK", result[:text]
      assert_equal "claude-sonnet-5-5", result[:returned_model]
      assert_equal "global.anthropic.claude-sonnet-5-5", enqueued.first[:model_id]
      assert_equal 20, enqueued.first[:input_tokens]
      assert_equal 8, enqueued.first[:output_tokens]
      assert_operator result[:cost_usd], :>, 0
      assert_in_delta 0.00012, result[:cost_usd], 0.0000001
    ensure
      TrackBedrockQueryJob.singleton_class.alias_method(:perform_later, :f1_sonnet_test_perform_later)
    end
  end

  test "a haiku model id in the response is a fallback failure" do
    payload = {
      "model" => "claude-haiku-4-5",
      "content" => [ { "type" => "text", "text" => "PREFLIGHT_OK" } ],
      "usage" => { "input_tokens" => 10, "output_tokens" => 4 }
    }
    response = Struct.new(:body).new(StringIO.new(payload.to_json))
    client = Object.new
    client.define_singleton_method(:invoke_model) { |**| response }

    error = assert_raises(Gen::Error) do
      Gen.invoke(client: client, prompt: Gen::PREFLIGHT_PROMPT, max_tokens: 64, temperature: 0)
    end
    assert_match "haiku", error.message
  end
end
