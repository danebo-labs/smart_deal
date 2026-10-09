# frozen_string_literal: true

require "test_helper"

class Rag::AuditCaptureTest < ActiveSupport::TestCase
  TURN = "Estoy revisando un Elemont MH por un problema de puerta en el nivel 2."
  SECRET_URL = "https://bucket.s3.amazonaws.com/manual.pdf?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIATESTKEY12/20261009/us-east-1/s3/aws4_request"

  test "the captured interpreter request is the object the stub received" do
    client = recording_client
    episode = episode_with_goal
    photo = photo_context("LED encendido")
    events = Rag::ValidationCapture.capture do
      Rag::ValidationCapture.bind(run_id: "audit-interpreter", session_id: 4, correlation_root: "phase1:4")
      Rag::ValidationCapture.correlation = "phase1:4"
      Rag::ValidationCapture.attempt = 1
      Rag::TurnInterpreter.call(
        turn: TURN,
        episode: episode,
        viewer_account: nil,
        correlation_id: "phase1:4",
        client: client,
        active_photo_context: photo
      )
      Rag::ValidationCapture.bind(episode_id: "ep_later")
      Rag::ValidationCapture.record("after_episode", "stage" => "episode")
    end

    request = events.find { |event| event["kind"] == "interpreter_request" }
    assert_equal 1, client.calls
    assert client.received.key?(:model_id)
    assert_equal Rag::ValidationCapture.sanitize(client.received), request["request"]
    assert_equal Rag::TurnInterpreter::MODEL_ID, request["model_id"]
    assert_includes request["system"], "You classify one technician turn"
    assert_equal Digest::SHA256.hexdigest(request["system"]), request["prompt_version"]
    structured = JSON.parse(request["message_text"])
    assert_equal TURN, structured["turn"]
    assert_equal "puerta en el nivel 2", structured.dig("work_context", "goal")
    assert_equal "LED encendido", structured.dig("work_context", "active_photo_context")
    assert_equal true, request.dig("visual_context", "included")
    assert_equal "LED encendido", request.dig("visual_context", "value")
    assert_equal "turn_perception", request.dig("tool_config", "tools", 0, "tool_spec", "name")
    assert_equal 0, request.dig("inference_config", "temperature")
    assert_equal Rag::TurnInterpreter::MAX_TOKENS, request.dig("inference_config", "max_tokens")
    assert_equal "sent", request["result"]
    assert_equal "converse", request["stage"]
    assert_equal "observed", request["provenance"]
    assert_equal "audit-interpreter", request["run_id"]
    assert_equal 4, request["session_id"]
    assert_equal "phase1:4", request["correlation_root"]
    assert_equal "phase1:4", request["correlation_id"]
    assert_nil request["episode_id"]
    assert_nil request["turn"]
    later = events.find { |event| event["kind"] == "after_episode" }
    assert_equal "ep_later", later["episode_id"]
    assert_operator request["sequence"], :<, later["sequence"]
    assert_equal events.pluck("sequence"), (1..events.size).to_a
    assert events.none? { |event| %w[retrieve generate_text retrieval_results retrieve_and_generate].include?(event["kind"]) }
    response = events.find { |event| event["kind"] == "interpreter_response" }
    raw = events.find { |event| event["kind"] == "interpreter_raw" }
    assert_operator request["sequence"], :<, response["sequence"]
    assert_operator response["sequence"], :<, raw["sequence"]
    assert_equal "meta", raw.dig("tool_input", "move")
  end

  test "a turn above the summary limit stays complete in the exported body" do
    original = "Puerta #{'nivel ' * 800}2"
    assert_operator original.length, :>, Rag::ValidationCapture::SUMMARY_CHARS
    client = recording_client
    events = Rag::ValidationCapture.capture do
      Rag::TurnInterpreter.call(
        turn: original,
        episode: Rag::ActiveEpisode.new,
        viewer_account: nil,
        correlation_id: "phase1:9",
        client: client
      )
    end
    directory = Rails.root.join("tmp/phase1_pinned_turn_test/audit-interpreter")
    FileUtils.rm_rf(directory)
    document = Rag::ValidationCapture.export_capture(events, directory, run_id: "audit-interpreter")
    FileUtils.mkdir_p(directory)
    File.write(directory.join("capture.json"), JSON.pretty_generate(document))

    request = events.find { |event| event["kind"] == "interpreter_request" }
    assert_equal original, request.dig("turn_transform", "original")
    assert_equal client.received.dig(:messages, 0, :content, 0, :text), request["message_text"]
    assert_includes request["message_text"], request.dig("turn_transform", "sent")
    assert_not_includes request["message_text"], original
    exported = document["events"].find { |event| event["kind"] == "interpreter_request" }
    body = exported.dig("turn_transform", "original")
    assert_equal "external", body["evidence"]
    assert_equal false, body["truncated"]
    assert_equal true, body["summary_truncated"]
    assert_equal false, body["absent"]
    stored = File.read(directory.join(body["path"]), encoding: "UTF-8")
    assert_equal original, stored
    assert_equal Digest::SHA256.hexdigest(stored), body["sha256"]
    assert_operator body["summary"].length, :<, original.length
    system = exported["system"]
    if system.is_a?(Hash) && system["evidence"] == "external"
      prompt = File.read(directory.join(system["path"]), encoding: "UTF-8")
      assert_equal request["system"], prompt
      assert_equal false, system["truncated"]
    end
  end

  test "secrets are removed from the exported body and the stub still receives them" do
    turn = "Revisa #{SECRET_URL} y el token AKIASECRETKEY1"
    client = recording_client
    events = Rag::ValidationCapture.capture do
      Rag::TurnInterpreter.call(
        turn: turn,
        episode: Rag::ActiveEpisode.new,
        viewer_account: nil,
        correlation_id: "phase1:9",
        client: client
      )
    end
    directory = Rails.root.join("tmp/phase1_pinned_turn_test/audit-secrets")
    FileUtils.rm_rf(directory)
    document = Rag::ValidationCapture.export_capture(events, directory, run_id: "audit-secrets")
    FileUtils.mkdir_p(directory)
    File.write(directory.join("capture.json"), JSON.pretty_generate(document))
    exported = Dir.glob(directory.join("**/*").to_s).select { |path| File.file?(path) }.map { |path| File.binread(path) }.join
    assert_includes client.received.dig(:messages, 0, :content, 0, :text), "AKIASECRETKEY1"
    assert_includes client.received.dig(:messages, 0, :content, 0, :text), "X-Amz-Credential"
    assert_not_includes exported, "AKIA"
    assert_not_includes exported, "X-Amz-Credential"
    request = events.find { |event| event["kind"] == "interpreter_request" }
    assert_equal true, request["redacted"]
    assert_includes request["message_text"], "[redacted]"
    assert_includes request["message_text"], "https://bucket.s3.amazonaws.com/manual.pdf"
  end

  test "a converse error keeps the request and does not record a response or a retrieve" do
    message = "fallo #{'detalle ' * 80} AKIASECRETKEY1"
    client = raising_client(Timeout::Error.new(message))
    result = nil
    events = Rag::ValidationCapture.capture do
      Rag::ValidationCapture.correlation = "phase1:9"
      result = Rag::TurnInterpreter.call(
        turn: TURN,
        episode: Rag::ActiveEpisode.new,
        viewer_account: nil,
        correlation_id: "phase1:9",
        client: client
      )
    end

    assert_equal "timeout", result.status
    assert_equal 1, client.calls
    assert_operator result.error_reason.length, :<=, 180
    failure = events.find { |event| event["kind"] == "interpreter_failure" }
    request = events.find { |event| event["kind"] == "interpreter_request" }
    assert_equal "error", failure["result"]
    assert_equal "converse", failure["stage"]
    assert_includes failure["reason"], "detalle"
    assert_not_includes failure["reason"], "AKIA"
    assert_equal true, failure["reason_summary_truncated"]
    assert_equal result.error_reason, failure["reason_summary"]
    assert_operator request["sequence"], :<, failure["sequence"]
    assert_nil events.find { |event| event["kind"] == "interpreter_response" }
    assert_nil events.find { |event| event["kind"] == "retrieve" }
    assert_nil events.find { |event| event["kind"] == "generate_text" }
  end

  test "an inactive capture does not record and does not change the request" do
    first = recording_client
    second = recording_client
    outside = Rag::TurnInterpreter.call(
      turn: TURN,
      episode: episode_with_goal,
      viewer_account: nil,
      correlation_id: "phase1:9",
      client: first
    )
    assert_nil Thread.current[:rag_validation_capture]
    inside = nil
    events = Rag::ValidationCapture.capture do
      inside = Rag::TurnInterpreter.call(
        turn: TURN,
        episode: episode_with_goal,
        viewer_account: nil,
        correlation_id: "phase1:9",
        client: second
      )
    end

    assert_equal 1, first.calls
    assert_equal 1, second.calls
    assert_equal first.received[:model_id], second.received[:model_id]
    assert_equal first.received[:system], second.received[:system]
    assert_equal first.received[:messages], second.received[:messages]
    assert_equal first.received[:inference_config], second.received[:inference_config]
    assert_equal first.received[:tool_config], second.received[:tool_config]
    assert_equal outside.status, inside.status
    assert_equal outside.perception.move, inside.perception.move
    assert_equal outside.fallback, inside.fallback
    assert events.any? { |event| event["kind"] == "interpreter_request" }
  end

  private

  def episode_with_goal
    episode = Rag::ActiveEpisode.new
    episode.episode_id = "ep-audit"
    episode.goal = { "text" => "puerta en el nivel 2" }
    episode
  end

  def photo_context(text)
    Object.new.tap { |photo| photo.define_singleton_method(:to_prompt) { text } }
  end

  def meta_tool
    {
      "move" => "meta",
      "assertions" => [],
      "observations" => [],
      "pending_resolution" => nil,
      "clarification_target" => nil
    }
  end

  def recording_client
    tool = meta_tool
    Object.new.tap do |client|
      calls = 0
      received = nil
      client.define_singleton_method(:calls) { calls }
      client.define_singleton_method(:received) { received }
      client.define_singleton_method(:converse) do |params|
        calls += 1
        received = params
        tool_use = Struct.new(:name, :input).new("turn_perception", tool)
        block = Struct.new(:tool_use).new(tool_use)
        message = Struct.new(:content).new([ block ])
        output = Struct.new(:message).new(message)
        usage = Struct.new(:input_tokens, :output_tokens).new(0, 0)
        Struct.new(:output, :usage).new(output, usage)
      end
    end
  end

  def raising_client(error)
    Object.new.tap do |client|
      calls = 0
      client.define_singleton_method(:calls) { calls }
      client.define_singleton_method(:converse) do |_params|
        calls += 1
        raise error
      end
    end
  end
end
