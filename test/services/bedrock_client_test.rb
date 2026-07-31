# frozen_string_literal: true

require "test_helper"

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
end
