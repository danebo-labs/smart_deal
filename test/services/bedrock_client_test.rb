# frozen_string_literal: true

require "test_helper"
require "stringio"

class BedrockClientTest < ActiveJob::TestCase
  setup do
    @client = BedrockClient.new
    @result = { "usage" => { "input_tokens" => 120, "output_tokens" => 40 }, "stop_reason" => "end_turn" }
  end

  test "track_usage enqueues TrackBedrockQueryJob without attribution when tracking is omitted" do
    assert_enqueued_with(job: TrackBedrockQueryJob) do
      @client.send(:track_usage, @result, "model-x", "prompt text", Time.current, max_tokens: 500)
    end

    args = enqueued_jobs.find { |j| j[:job] == TrackBedrockQueryJob }[:args].first
    assert_equal "model-x", args["model_id"]
    assert_equal 120, args["input_tokens"]
    assert_equal 40, args["output_tokens"]
    assert_nil args["account_id"]
    assert_nil args["user_id"]
    assert_nil args["conversation_session_id"]
    assert_nil args["correlation_id"]
  end

  test "track_usage forwards the tracking hash so the BedrockQuery row can be joined to its request" do
    tracking = { account_id: 1, user_id: 2, conversation_session_id: 3, correlation_id: "corr-9" }

    assert_enqueued_with(job: TrackBedrockQueryJob) do
      @client.send(:track_usage, @result, "model-x", "prompt text", Time.current, max_tokens: 500, tracking: tracking)
    end

    args = enqueued_jobs.find { |j| j[:job] == TrackBedrockQueryJob }[:args].first
    assert_equal 1, args["account_id"]
    assert_equal 2, args["user_id"]
    assert_equal 3, args["conversation_session_id"]
    assert_equal "corr-9", args["correlation_id"]
  end

  test "generate_text omits system and keeps the current request body" do
    calls = stub_invoke(@client)
    events = Rag::ValidationCapture.capture do
      assert_equal "respuesta", @client.generate_text("prompt", model_id: "model-x", max_tokens: 30, temperature: 0.1)
    end
    body = JSON.parse(calls.sole.fetch(:body))

    assert_equal expected_body, body
    assert_nil body["system"]
    prepared = events.find { |event| event["kind"] == "generate_text" && event["result"] == "prepared" }
    returned = events.find { |event| event["kind"] == "generation_result" && event["result"] == "returned" }
    assert_nil prepared["system"]
    assert_nil prepared["system_sha256"]
    assert_nil returned["system"]
    assert_nil returned["system_sha256"]
  end

  test "generate_text sends system and records its sha on prepared and returned" do
    calls = stub_invoke(@client)
    events = Rag::ValidationCapture.capture do
      @client.generate_text("prompt", system: "rol", model_id: "model-x", max_tokens: 30, temperature: 0.1)
    end
    body = JSON.parse(calls.sole.fetch(:body))
    sha = Digest::SHA256.hexdigest("rol")

    assert_equal expected_body.merge("system" => "rol"), body
    prepared = events.find { |event| event["kind"] == "generate_text" && event["result"] == "prepared" }
    returned = events.find { |event| event["kind"] == "generation_result" && event["result"] == "returned" }
    assert_equal "rol", prepared["system"]
    assert_equal sha, prepared["system_sha256"]
    assert_equal "rol", returned["system"]
    assert_equal sha, returned["system_sha256"]
  end

  private

  def expected_body
    {
      "anthropic_version" => "bedrock-2023-05-31",
      "max_tokens" => 30,
      "temperature" => 0.1,
      "messages" => [ { "role" => "user", "content" => "prompt" } ]
    }
  end

  def stub_invoke(client)
    calls = []
    aws = Object.new
    aws.define_singleton_method(:invoke_model) do |params|
      calls << params
      payload = {
        "content" => [ { "text" => "respuesta" } ],
        "usage" => { "input_tokens" => 3, "output_tokens" => 2 },
        "stop_reason" => "end_turn"
      }
      Struct.new(:body).new(StringIO.new(payload.to_json))
    end
    client.instance_variable_set(:@client, aws)
    calls
  end
end
