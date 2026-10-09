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
    assert_equal "prepared", request["result"]
    assert_equal "interpreter", request["operation"]
    started = events.find { |event| event["kind"] == "interpreter_attempt" }
    assert_equal "attempt_started", started["result"]
    assert_equal "interpreter", started["operation"]
    assert_equal request["correlation_id"], started["correlation_id"]
    assert_equal request["attempt"], started["attempt"]
    assert_operator request["sequence"], :<, started["sequence"]
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
    assert_operator started["sequence"], :<, response["sequence"]
    assert_equal "returned", response["result"]
    assert_equal "interpreter", response["operation"]
    assert_equal "turn_perception", response.dig("response", "output", "message", "content", 0, "tool_use", "name")
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
    assert_equal "prepared", request["result"]
    assert_equal "attempt_started", events.find { |event| event["kind"] == "interpreter_attempt" }["result"]
    assert_equal "error", failure["result"]
    assert_equal "interpreter", failure["operation"]
    assert_equal request["correlation_id"], failure["correlation_id"]
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
    assert_equal outside.fallback, inside.fallback
    assert_equal outside.perception.valid, inside.perception.valid
    assert_equal outside.perception.invalid_reason, inside.perception.invalid_reason
    assert events.any? { |event| event["kind"] == "interpreter_request" }
  end

  test "a text-only response is kept and does not invent a tool" do
    events, result = interpret_response(converse_response([ content_block(text: "sin herramienta") ]))
    content = response_content(events)

    assert result.fallback
    assert_equal [ { "text" => "sin herramienta" } ], content
    assert content.none? { |block| block.key?("tool_use") }
    assert_nil events.find { |event| event["kind"] == "interpreter_raw" }&.dig("tool_input")
    assert_equal "end_turn", events.find { |event| event["kind"] == "interpreter_response" }.dig("response", "stop_reason")
    assert_equal 3, events.find { |event| event["kind"] == "interpreter_response" }.dig("response", "usage", "input_tokens")
  end

  test "text and tool stay in order with usage and stop reason" do
    note = "Veo la serie. AKIASECRETKEY1 #{'x' * 2_100}"
    tool = meta_tool
    events, _result = interpret_response(
      converse_response(
        [
          content_block(text: note),
          content_block(tool_use: tool_use_block("turn_perception", tool))
        ],
        stop_reason: "tool_use",
        input_tokens: 11,
        output_tokens: 4
      )
    )
    response = events.find { |event| event["kind"] == "interpreter_response" }
    content = response.dig("response", "output", "message", "content")
    directory = Rails.root.join("tmp/phase1_pinned_turn_test/audit-response")
    FileUtils.rm_rf(directory)
    document = Rag::ValidationCapture.export_capture(events, directory, run_id: "audit-response")

    assert_equal "returned", response["result"]
    assert_includes content[0]["text"], "Veo la serie."
    assert_equal "meta", events.find { |event| event["kind"] == "interpreter_raw" }.dig("tool_input", "move")
    assert_equal "tool_use", response.dig("response", "stop_reason")
    assert_equal 11, response.dig("response", "usage", "input_tokens")
    assert_equal 4, response.dig("response", "usage", "output_tokens")
    assert_equal "turn_perception", content[1].dig("tool_use", "name")
    assert_equal "meta", content[1].dig("tool_use", "input", "move")
    assert_equal true, response["redacted"]
    assert_not_includes response.to_s, "AKIA"
    body = document["events"].find { |event| event["kind"] == "interpreter_response" }
    spilled = find_external(body)
    stored = File.binread(directory.join(spilled["path"]))
    assert_equal spilled["sha256"], Digest::SHA256.hexdigest(stored)
    assert_equal false, spilled["truncated"]
    assert_not_includes stored, "AKIA"
    assert_includes stored, "[redacted]"
    assert_includes stored, "Veo la serie."
  end

  test "an unexpected tool and empty content stay visible when interpretation fails" do
    unexpected, unexpected_result = interpret_response(
      converse_response([ content_block(tool_use: tool_use_block("other_tool", { "x" => 1 })) ])
    )
    empty, empty_result = interpret_response(converse_response([]))

    assert unexpected_result.fallback
    assert_equal "other_tool", response_content(unexpected).dig(0, "tool_use", "name")
    assert_nil unexpected.find { |event| event["kind"] == "interpreter_raw" }["tool_input"]
    assert_equal "returned", unexpected.find { |event| event["kind"] == "interpreter_response" }["result"]
    assert empty_result.fallback
    assert_equal [], response_content(empty)
    assert_nil empty.find { |event| event["kind"] == "interpreter_raw" }["tool_input"]
    assert empty.none? { |event| event.to_s.include?("turn_perception") && event["kind"] == "interpreter_response" }
  end

  test "an unknown block keeps its type and the response remains when extraction fails" do
    text = content_block(text: "nota previa")
    message = Struct.new(:content).new([ text, Object.new ])
    output = Struct.new(:message).new(message)
    usage = Struct.new(:input_tokens, :output_tokens).new(2, 1)
    response = Struct.new(:output, :usage, :stop_reason).new(output, usage, "end_turn")
    result = nil
    events = Rag::ValidationCapture.capture do
      result = Rag::TurnInterpreter.call(
        turn: TURN,
        episode: Rag::ActiveEpisode.new,
        viewer_account: nil,
        correlation_id: "phase1:unknown",
        client: response_client(response)
      )
    end
    content = response_content(events)

    assert_equal "local_error", result.status
    assert_equal "extract", result.stage
    assert_equal "nota previa", content[0]["text"]
    assert_equal "Object", content[1]["unmodeled_type"]
    assert_equal 2, content.size
    assert_nil content[1]["text"]
    assert_nil content[1]["tool_use"]
    assert_equal "extract", events.find { |event| event["kind"] == "interpreter_failure" }["stage"]
    assert_equal "returned", events.find { |event| event["kind"] == "interpreter_response" }["result"]
  end

  test "a seahorse response serializes its data and not the transport context" do
    spec = Gem.loaded_specs.fetch("aws-sdk-core")
    assert_equal "3.254.1", spec.version.to_s
    assert_equal "1.63.0", Gem.loaded_specs.fetch("aws-sdk-bedrockruntime").version.to_s
    assert Seahorse::Client::Response < Delegator

    tool = meta_tool
    response = seahorse_converse(
      [
        content_block(text: "Veo la serie. AKIASEAHORSE1"),
        content_block(tool_use: tool_use_block("turn_perception", tool))
      ],
      stop_reason: "tool_use",
      input_tokens: 11,
      output_tokens: 4
    )
    before_data = response.data.to_h
    before_header = response.context.http_request.headers["authorization"]
    outside = interpret_quietly("hola", response)
    events, inside = interpret_response(response, turn: "hola")
    body = events.find { |event| event["kind"] == "interpreter_response" }
    content = body.dig("response", "output", "message", "content")

    assert_equal Seahorse::Client::Response, response.class
    assert_equal before_data, response.data.to_h
    assert_equal before_header, response.context.http_request.headers["authorization"]
    assert_equal outside.perception.move, inside.perception.move
    assert_equal outside.fallback, inside.fallback
    assert_equal outside.status, inside.status
    assert_equal "meta", inside.perception.move
    assert_equal false, inside.fallback
    assert_equal "returned", body["result"]
    assert_equal "Veo la serie. [redacted]", content[0]["text"]
    assert_equal "turn_perception", content[1].dig("tool_use", "name")
    assert_equal "meta", content[1].dig("tool_use", "input", "move")
    assert_equal [ "text", "tool_use" ], content.map { |block| block.key?("text") ? "text" : "tool_use" }
    assert_equal "tool_use", body.dig("response", "stop_reason")
    assert_equal 11, body.dig("response", "usage", "input_tokens")
    assert_equal 4, body.dig("response", "usage", "output_tokens")
    assert_equal 17, body.dig("response", "metrics", "latency_ms")
    assert_not body["response"].key?("trace")
    assert_equal "meta", events.find { |event| event["kind"] == "interpreter_raw" }.dig("tool_input", "move")
    assert_not_includes events.to_s, "HEADER-SECRET-9f3a"
    assert_not_includes events.to_s, "CREDENTIAL-MATERIAL-9f3a"
    assert_not_includes events.to_s, "Seahorse::Client::Response"
    assert_not_includes events.to_s, "unmodeled_type"
  end

  test "a seahorse text response does not invent a tool" do
    response = seahorse_converse([ content_block(text: "sin herramienta") ])
    outside = interpret_quietly("hola", response)
    events, inside = interpret_response(response, turn: "hola")
    content = response_content(events)

    assert_equal outside.fallback, inside.fallback
    assert_equal outside.status, inside.status
    assert inside.fallback
    assert_equal [ { "text" => "sin herramienta" } ], content
    assert content.none? { |block| block.key?("tool_use") }
    assert_nil events.find { |event| event["kind"] == "interpreter_raw" }["tool_input"]
    assert_equal "end_turn", events.find { |event| event["kind"] == "interpreter_response" }.dig("response", "stop_reason")
    assert_equal 3, events.find { |event| event["kind"] == "interpreter_response" }.dig("response", "usage", "input_tokens")
    assert_not_includes events.to_s, "HEADER-SECRET-9f3a"
    assert_not_includes events.to_s, "CREDENTIAL-MATERIAL-9f3a"
  end

  test "an empty seahorse payload stays empty" do
    response = seahorse_converse([])
    outside = interpret_quietly("hola", response)
    events, inside = interpret_response(response, turn: "hola")

    assert_equal outside.fallback, inside.fallback
    assert_equal outside.status, inside.status
    assert_equal [], response_content(events)
    assert_nil events.find { |event| event["kind"] == "interpreter_raw" }["tool_input"]
    assert_equal "end_turn", events.find { |event| event["kind"] == "interpreter_response" }.dig("response", "stop_reason")
    assert events.none? { |event| event.to_s.include?("turn_perception") && event["kind"] == "interpreter_response" }
    assert_not_includes events.to_s, "HEADER-SECRET-9f3a"
    assert_not_includes events.to_s, "unmodeled_type"
  end

  test "a seahorse error payload does not invent output or copy credentials" do
    response = seahorse_error("boom CREDENTIAL-MATERIAL-9f3a")
    outside = interpret_quietly("hola", response)
    events, inside = interpret_response(response, turn: "hola")
    failure = events.find { |event| event["kind"] == "interpreter_failure" }

    assert_equal outside.fallback, inside.fallback
    assert_equal outside.status, inside.status
    assert_equal outside.stage, inside.stage
    assert_nil outside.perception
    assert_nil inside.perception
    assert_equal "local_error", inside.status
    assert_equal "extract", inside.stage
    assert_nil events.find { |event| event["kind"] == "interpreter_response" }
    assert_equal "extract", failure["stage"]
    assert_not_includes events.to_s, "HEADER-SECRET-9f3a"
    assert_not_includes events.to_s, "CREDENTIAL-MATERIAL-9f3a"
    assert_not_includes events.to_s, "unmodeled_type"
    assert_equal response.context.http_request.headers["authorization"], "HEADER-SECRET-9f3a"

    loaded = seahorse_converse([ content_block(text: "sin herramienta") ])
    loaded.error = RuntimeError.new("boom CREDENTIAL-MATERIAL-9f3a")
    loaded_events, loaded_result = interpret_response(loaded, turn: "hola")
    loaded_body = loaded_events.find { |event| event["kind"] == "interpreter_response" }

    assert loaded_result.fallback
    assert_equal [ { "text" => "sin herramienta" } ], response_content(loaded_events)
    assert_equal "end_turn", loaded_body.dig("response", "stop_reason")
    assert_not loaded_body["response"].key?("error")
    assert_not_includes loaded_events.to_s, "HEADER-SECRET-9f3a"
    assert_not_includes loaded_events.to_s, "CREDENTIAL-MATERIAL-9f3a"
    assert_not_includes loaded_events.to_s, "boom"
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

  def interpret_response(response, turn: TURN)
    result = nil
    events = Rag::ValidationCapture.capture do
      result = Rag::TurnInterpreter.call(
        turn: turn,
        episode: Rag::ActiveEpisode.new,
        viewer_account: nil,
        correlation_id: "phase1:response",
        client: response_client(response)
      )
    end
    [ events, result ]
  end

  def interpret_quietly(turn, response)
    Rag::TurnInterpreter.call(
      turn: turn,
      episode: Rag::ActiveEpisode.new,
      viewer_account: nil,
      correlation_id: "phase1:quiet",
      client: response_client(response)
    )
  end

  def seahorse_converse(content, stop_reason: "end_turn", input_tokens: 3, output_tokens: 2)
    message = Aws::Structure.new(:role, :content).new(role: "assistant", content: content)
    output = Aws::Structure.new(:message).new(message: message)
    usage = Aws::Structure.new(:input_tokens, :output_tokens).new(
      input_tokens: input_tokens, output_tokens: output_tokens
    )
    metrics = Aws::Structure.new(:latency_ms).new(latency_ms: 17)
    data = Aws::Structure.new(:output, :stop_reason, :usage, :metrics, :trace).new(
      output: output, stop_reason: stop_reason, usage: usage, metrics: metrics, trace: nil
    )
    seahorse_wrapper(data)
  end

  def seahorse_error(message)
    seahorse_wrapper(nil, error: RuntimeError.new(message))
  end

  def seahorse_wrapper(data, error: nil)
    request = Seahorse::Client::Http::Request.new
    request.headers["authorization"] = "HEADER-SECRET-9f3a"
    request.headers["x-amz-security-token"] = "CREDENTIAL-MATERIAL-9f3a"
    config = Object.new
    config.define_singleton_method(:secret_access_key) { "CREDENTIAL-MATERIAL-9f3a" }
    context = Seahorse::Client::RequestContext.new(http_request: request, config: config)
    Seahorse::Client::Response.new(context: context, data: data, error: error)
  end

  def response_content(events)
    events.find { |event| event["kind"] == "interpreter_response" }.dig("response", "output", "message", "content")
  end

  def find_external(value)
    case value
    when Hash
      return value if value["evidence"] == "external"

      value.each_value do |child|
        found = find_external(child)
        return found if found
      end
    when Array
      value.each do |child|
        found = find_external(child)
        return found if found
      end
    end
    nil
  end

  def response_client(response)
    Object.new.tap do |client|
      client.define_singleton_method(:converse) { |_params| response }
    end
  end

  def content_block(text: nil, tool_use: nil)
    Aws::Structure.new(:text, :tool_use).new(text: text, tool_use: tool_use)
  end

  def tool_use_block(name, input)
    Aws::Structure.new(:name, :input, :tool_use_id).new(name: name, input: input, tool_use_id: "tool-1")
  end

  def converse_response(content, stop_reason: "end_turn", input_tokens: 3, output_tokens: 2)
    message = Aws::Structure.new(:role, :content).new(role: "assistant", content: content)
    output = Aws::Structure.new(:message).new(message: message)
    usage = Aws::Structure.new(:input_tokens, :output_tokens).new(
      input_tokens: input_tokens, output_tokens: output_tokens
    )
    Aws::Structure.new(:output, :stop_reason, :usage).new(
      output: output, stop_reason: stop_reason, usage: usage
    )
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
