# frozen_string_literal: true

require "test_helper"
require Rails.root.join("script/field_companion/f1_sonnet_direct_generation")

class FieldCompanionF1SonnetDirectGenerationTest < ActiveSupport::TestCase
  Gen = FieldCompanion::F1SonnetDirectGeneration

  test "request keeps the composed user message and turns up-front thinking off" do
    body = Gen.request_body(prompt: "same field companion prompt", max_tokens: 3000, temperature: 0.1)

    assert_equal "claude-sonnet-5-5", body[:model]
    assert_equal 3000, body[:max_tokens]
    assert_nil body[:temperature]
    assert_equal "between_tools", body.dig(:thinking, :type)
    assert_equal [ { role: "user", content: "same field companion prompt" } ], body[:messages]
    assert_nil body[:system]
    assert_nil body[:tools]
    assert_equal BedrockQuery::BEDROCK_PRICING.fetch("claude-sonnet-5-5-direct"), Gen::PRICING
    assert_not_equal(
      BedrockQuery::BEDROCK_PRICING.fetch("global.anthropic.claude-haiku-4-5-20251001-v1:0"),
      Gen::PRICING.slice(:input, :output)
    )
    assert Gen.generation_call?(max_tokens: 3000, temperature: 0.1)
    assert_not Gen.generation_call?(max_tokens: 300, temperature: 0)
    assert_not_includes Rails.root.join("script/field_companion/f1_sonnet_direct_generation.rb").read, "DEFAULT_MODEL_ID"
  end

  test "answer text skips a leading thinking block" do
    content = [
      { "type" => "thinking", "thinking" => "SECRET_THINKING" },
      { "type" => "text", "text" => "PREFLIGHT_OK" }
    ]

    assert_equal "PREFLIGHT_OK", Gen.answer_text(content)
  end

  test "complete records sonnet usage and a non-zero direct price" do
    payload = {
      "model" => "claude-sonnet-5-5",
      "stop_reason" => "end_turn",
      "content" => [
        { "type" => "thinking", "thinking" => "hidden" },
        { "type" => "text", "text" => "PREFLIGHT_OK" }
      ],
      "usage" => { "input_tokens" => 20, "output_tokens" => 8 }
    }
    enqueued = []
    TrackBedrockQueryJob.singleton_class.alias_method(:f1_sonnet_direct_test_perform_later, :perform_later)
    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**kwargs| enqueued << kwargs }

    begin
      result = Gen.complete(
        prompt: Gen::PREFLIGHT_PROMPT,
        max_tokens: 64,
        temperature: 0,
        poster: ->(_body) { payload }
      )

      assert_equal "PREFLIGHT_OK", result[:text]
      assert_equal "claude-sonnet-5-5", result[:returned_model]
      assert_equal "anthropic_messages", result[:transport]
      assert_equal "claude-sonnet-5-5-direct", enqueued.first[:model_id]
      assert_equal 20, enqueued.first[:input_tokens]
      assert_operator result[:cost_usd], :>, 0
      assert_in_delta 0.00012, result[:cost_usd], 0.0000001
    ensure
      TrackBedrockQueryJob.singleton_class.alias_method(:perform_later, :f1_sonnet_direct_test_perform_later)
    end
  end

  test "the adapter is not referenced from application runtime" do
    app = Rails.root.join("app").to_s
    hits = Dir.glob(File.join(app, "**", "*.rb")).select { |path| File.read(path).include?("F1SonnetDirectGeneration") }

    assert_empty hits
  end
end
