# frozen_string_literal: true

require "test_helper"
require Rails.root.join("script/field_companion/f1_grok_generation")

class FieldCompanionF1GrokGenerationTest < ActiveSupport::TestCase
  Gen = FieldCompanion::F1GrokGeneration

  Usage = Struct.new(:input_tokens, :output_tokens, :total_tokens, :cache_read_input_tokens, :cache_write_input_tokens)
  Block = Struct.new(:text, :reasoning_content, :citations_content)
  Reasoning = Struct.new(:reasoning_text, :redacted_content)
  ReasoningText = Struct.new(:text, :signature)
  Message = Struct.new(:content)
  Output = Struct.new(:message)
  Response = Struct.new(:output, :stop_reason, :usage, :additional_model_response_fields)

  test "request pins the global model and low reasoning effort" do
    body = Gen.request(prompt: Gen::PREFLIGHT_PROMPT, max_tokens: 512, temperature: 0.1)

    assert_equal "global.xai.grok-4.7", body[:model_id]
    assert_equal "low", body.dig(:additional_model_request_fields, :reasoning_effort)
    assert_equal 0.1, body.dig(:inference_config, :temperature)
    assert_nil body[:service_tier]
    assert_equal({ input: 0.002, output: 0.006, cache_read: 0.0005 }, Gen::PRICING)
    assert_equal BedrockQuery::BEDROCK_PRICING.fetch("global.xai.grok-4.7"), Gen::PRICING
  end

  test "answer text skips a leading reasoning block" do
    content = [
      Block.new(nil, Reasoning.new(ReasoningText.new("SECRET_REASONING", "sig"), nil), nil),
      Block.new("PREFLIGHT_OK", nil, nil)
    ]

    assert_equal "PREFLIGHT_OK", Gen.answer_text(content)
    assert_equal "SECRET_REASONING".length, Gen.reasoning_chars(content)
    assert_not_includes Gen.answer_text(content), "SECRET_REASONING"
  end

  test "converse records provider tokens and a non-zero price" do
    response = Response.new(
      Output.new(Message.new([
        Block.new(nil, Reasoning.new(ReasoningText.new("think", "sig"), nil), nil),
        Block.new("PREFLIGHT_OK", nil, nil)
      ])),
      "end_turn",
      Usage.new(20, 8, 28, 0, 0),
      { "reasoning_tokens" => 5 }
    )
    client = Object.new
    client.define_singleton_method(:converse) { |**| response }
    enqueued = []
    TrackBedrockQueryJob.singleton_class.alias_method(:f1_grok_test_perform_later, :perform_later)
    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**kwargs| enqueued << kwargs }
    begin
      result = Gen.converse(client: client, prompt: Gen::PREFLIGHT_PROMPT, max_tokens: 512, temperature: 0)

      assert_equal "PREFLIGHT_OK", result[:text]
      assert_equal "global.xai.grok-4.7", enqueued.first[:model_id]
      assert_equal 20, enqueued.first[:input_tokens]
      assert_equal 8, enqueued.first[:output_tokens]
      assert_equal 5, result[:reasoning_tokens]
      assert_operator result[:cost_usd], :>, 0
      assert_in_delta 0.000088, result[:cost_usd], 0.0000001
    ensure
      TrackBedrockQueryJob.singleton_class.alias_method(:perform_later, :f1_grok_test_perform_later)
    end
  end

  test "a blank answer is a visible failure" do
    response = Response.new(
      Output.new(Message.new([ Block.new(nil, Reasoning.new(ReasoningText.new("only thinking", "sig"), nil), nil) ])),
      "max_tokens",
      Usage.new(12, 40, 52, 0, 0),
      nil
    )
    client = Object.new
    client.define_singleton_method(:converse) { |**| response }

    error = assert_raises(Gen::Error) do
      Gen.converse(client: client, prompt: Gen::PREFLIGHT_PROMPT, max_tokens: 64, temperature: 0)
    end
    assert_match "blank Grok answer", error.message
  end
end
