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
    assert_equal "prompt", prepared["prompt"]
    assert_equal Digest::SHA256.hexdigest("prompt"), prepared["user_sha256"]
    assert_equal [ { "role" => "user" } ], prepared["messages"]
    assert_nil returned["system"]
    assert_nil returned["system_sha256"]
    assert_nil returned["prompt"]
    assert_equal prepared["user_sha256"], returned["user_sha256"]
    assert_equal "respuesta", returned["answer"]
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
    assert_equal Digest::SHA256.hexdigest("prompt"), prepared["user_sha256"]
    assert_equal prepared["user_sha256"], returned["user_sha256"]
    assert_not_equal "#{prepared['system']}\n\n#{prepared['prompt']}", prepared["prompt"]
  end

  test "prepared attempt_started and returned share correlation attempt and the user sha" do
    calls = stub_invoke(@client)
    events = Rag::ValidationCapture.capture do
      @client.generate_text(
        "prompt",
        system: "rol",
        model_id: "model-x",
        max_tokens: 30,
        temperature: 0.1,
        tracking: { correlation_id: "phase2:attr:gen:system:1", attempt: 1 }
      )
    end

    prepared = events.find { |event| event["kind"] == "generate_text" && event["result"] == "prepared" }
    started = events.find { |event| event["kind"] == "model_call" && event["result"] == "attempt_started" }
    returned = events.find { |event| event["kind"] == "generation_result" && event["result"] == "returned" }
    user_sha = Digest::SHA256.hexdigest("prompt")

    assert_equal 1, calls.size
    assert_equal "observed", prepared["provenance"]
    assert_equal "phase2:attr:gen:system:1", prepared["correlation_id"]
    assert_equal "phase2:attr:gen:system:1", started["correlation_id"]
    assert_equal "phase2:attr:gen:system:1", returned["correlation_id"]
    assert_equal 1, prepared["attempt"]
    assert_equal 1, started["attempt"]
    assert_equal 1, returned["attempt"]
    assert_equal "model-x", prepared["model_id"]
    assert_equal "model-x", returned["model_id"]
    assert_equal 30, prepared["max_tokens"]
    assert_equal 30, returned["max_tokens"]
    assert_in_delta 0.1, prepared["temperature"]
    assert_in_delta 0.1, returned["temperature"]
    assert_equal "bedrock-2023-05-31", prepared["anthropic_version"]
    assert_equal [ { "role" => "user" } ], prepared["messages"]
    assert_equal "prompt", prepared["prompt"]
    assert_equal user_sha, prepared["user_sha256"]
    assert_equal user_sha, returned["user_sha256"]
    assert_equal "respuesta", returned["answer"]
    assert_nil returned["error_class"]
    assert_nil prepared["access_key_id"]
    assert_nil prepared["authorization"]
    assert events.none? { |event| event["result"] == "blocked" }
    assert events.none? { |event| event["result"] == "error" }
  end

  test "a client exception is an error and keeps the same correlation" do
    aws = Object.new
    aws.define_singleton_method(:invoke_model) { |*| raise RuntimeError, "model down" }
    @client.instance_variable_set(:@client, aws)

    events = Rag::ValidationCapture.capture do
      assert_nil @client.generate_text(
        "prompt",
        system: "rol",
        model_id: "model-x",
        max_tokens: 30,
        temperature: 0.1,
        tracking: { correlation_id: "phase2:attr:gen:system:2", attempt: 2 }
      )
    end

    prepared = events.find { |event| event["result"] == "prepared" }
    started = events.find { |event| event["result"] == "attempt_started" }
    error = events.find { |event| event["result"] == "error" }

    assert_equal "phase2:attr:gen:system:2", prepared["correlation_id"]
    assert_equal "phase2:attr:gen:system:2", started["correlation_id"]
    assert_equal "phase2:attr:gen:system:2", error["correlation_id"]
    assert_equal 2, prepared["attempt"]
    assert_equal 2, error["attempt"]
    assert_equal "RuntimeError", error["error_class"]
    assert_nil error["answer"]
    assert_equal Digest::SHA256.hexdigest("prompt"), error["user_sha256"]
    assert_equal Digest::SHA256.hexdigest("rol"), error["system_sha256"]
    assert events.none? { |event| event["result"] == "returned" }
    assert events.none? { |event| event["result"] == "blocked" }
    assert_equal "model down", error["error_message"]
    assert_nil prepared["error_message"]
    assert_not_includes prepared.fetch("prompt"), "model down"
  end

  test "a long system and user export to relative files that keep every byte" do
    user = "consulta #{'u' * 2_100}"
    system_text = "rol #{'s' * 2_100}"
    stub_invoke(@client)
    events = Rag::ValidationCapture.capture do
      @client.generate_text(user, system: system_text, model_id: "model-x", max_tokens: 30, temperature: 0.1)
    end
    directory = Rails.root.join("tmp/bedrock_client_capture_test")
    FileUtils.rm_rf(directory)
    document = Rag::ValidationCapture.export_capture(events, directory)
    prepared = document["events"].find { |event| event["kind"] == "generate_text" && event["result"] == "prepared" }
    returned = document["events"].find { |event| event["kind"] == "generation_result" && event["result"] == "returned" }

    assert_equal Digest::SHA256.hexdigest(user), prepared["user_sha256"]
    assert_equal Digest::SHA256.hexdigest(system_text), prepared["system_sha256"]
    assert_equal prepared["user_sha256"], returned["user_sha256"]
    assert_equal prepared["system_sha256"], returned["system_sha256"]
    {
      prepared["prompt"] => user,
      prepared["system"] => system_text,
      returned["system"] => system_text
    }.each do |reference, original|
      assert_equal "external", reference["evidence"]
      assert_equal false, reference["truncated"]
      assert reference["path"].start_with?("bodies/")
      stored = File.binread(directory.join(reference["path"]))
      assert_equal original, stored
      assert_equal Digest::SHA256.hexdigest(original), reference["sha256"]
    end
    assert_nil returned["prompt"]
  ensure
    FileUtils.rm_rf(Rails.root.join("tmp/bedrock_client_capture_test"))
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
