# frozen_string_literal: true

# Literal generation replay of the captured phase 5 InvokeModel body.
# Refuses unless PHASE5_GENERATION_REPLAY_AUTHORIZED=1 and AWS_MAX_ATTEMPTS=1.
# PHASE5_GENERATION_REPLAY_REQUIRE=1 loads without running.
# Does not construct a runtime client unless the gate has already passed.
# One call per process. Does not search, open a session, or score the answer.
# The runtime client is built with retry_limit 0 and max_attempts 1.

def phase5_generation_replay_main
  capture = ENV["PHASE5_GENERATION_REPLAY_CAPTURE"].presence ||
    Rag::Phase5GenerationReplay.default_capture_dir.to_s
  output = ENV["PHASE5_GENERATION_REPLAY_OUTPUT"].presence ||
    Rag::Phase5GenerationReplay.default_output_dir.to_s
  replay = Rag::Phase5GenerationReplay
  unless ENV[replay::AUTHORIZED_ENV] == "1"
    puts replay.preview(capture_dir: capture, output_dir: output).to_h.to_json
    return 2
  end

  gated = replay.gate(capture_dir: capture, output_dir: output)
  unless gated.sendable?
    puts gated.to_h.to_json
    return 2
  end

  result = replay.run(capture_dir: capture, output_dir: output, client: phase5_invoke_client)
  puts result.to_h.to_json
  result.status == "recorded" ? 0 : 2
end

def phase5_invoke_client
  probe = Class.new { include AwsClientInitializer }.new
  options = probe.send(:build_aws_client_options).merge(retry_limit: 0, max_attempts: 1)
  sdk = Aws::BedrockRuntime::Client.new(options)
  Phase5InvokeClient.new(sdk)
end

# Thin view over the runtime client. The service checks the view and then
# calls invoke_model once. This class does not retry.
class Phase5InvokeClient
  def initialize(sdk)
    @sdk = sdk
  end

  def retry_view
    Rag::Phase5GenerationReplay::RetryView.new(
      max_attempts: @sdk.config.max_attempts,
      retry_limit: @sdk.config.retry_limit,
      retry_mode: @sdk.config.retry_mode
    )
  end

  def invoke_model(model_id:, body:)
    @sdk.invoke_model(
      model_id: model_id,
      content_type: "application/json",
      accept: "application/json",
      body: body
    )
  end
end

unless ENV["PHASE5_GENERATION_REPLAY_REQUIRE"] == "1"
  code = phase5_generation_replay_main
  exit code unless code.zero?
end
