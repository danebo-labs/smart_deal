# frozen_string_literal: true

# One-paragraph variant of the phase 5 and phase 3 generation captures.
# Refuses unless LABEL_COMPARISON_VARIANT_AUTHORIZED=1 and AWS_MAX_ATTEMPTS=1.
# LABEL_COMPARISON_VARIANT_REQUIRE=1 loads without running.
# Does not construct a runtime client unless the gate has already passed.
# One call per process. Does not search, open a session, or score the answer.
# The runtime client is built with retry_limit 0 and max_attempts 1.

def label_comparison_variant_main
  phase5 = ENV["LABEL_COMPARISON_VARIANT_PHASE5_CAPTURE"].presence ||
    Rag::Phase5GenerationReplay.default_capture_dir.to_s
  phase3 = ENV["LABEL_COMPARISON_VARIANT_PHASE3_CAPTURE"].presence ||
    Rag::Phase3SummaryGenerationReplay.default_capture_dir.to_s
  output = ENV["LABEL_COMPARISON_VARIANT_OUTPUT"].presence ||
    Rag::LabelComparisonVariant.default_output_dir.to_s
  replay = Rag::LabelComparisonVariant
  unless ENV[replay::AUTHORIZED_ENV] == "1"
    puts replay.preview(phase5_capture: phase5, phase3_capture: phase3, output_dir: output).to_h.to_json
    return 2
  end

  gated = replay.gate(phase5_capture: phase5, phase3_capture: phase3, output_dir: output)
  unless gated.sendable?
    puts gated.to_h.to_json
    return 2
  end

  result = replay.run(
    phase5_capture: phase5,
    phase3_capture: phase3,
    output_dir: output,
    client: label_comparison_invoke_client
  )
  puts result.to_h.to_json
  result.status == "recorded" ? 0 : 2
end

def label_comparison_invoke_client
  probe = Class.new { include AwsClientInitializer }.new
  options = probe.send(:build_aws_client_options).merge(retry_limit: 0, max_attempts: 1)
  sdk = Aws::BedrockRuntime::Client.new(options)
  LabelComparisonInvokeClient.new(sdk)
end

# Thin view over the runtime client. The service checks the view and then
# calls invoke_model once. This class does not retry.
class LabelComparisonInvokeClient
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

unless ENV["LABEL_COMPARISON_VARIANT_REQUIRE"] == "1"
  code = label_comparison_variant_main
  exit code unless code.zero?
end
