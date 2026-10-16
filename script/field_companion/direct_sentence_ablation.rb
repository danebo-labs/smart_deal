# frozen_string_literal: true

# One-sentence ablation of the original phase 5 question.
# Refuses unless DIRECT_SENTENCE_ABLATION_AUTHORIZED=1 and AWS_MAX_ATTEMPTS=1.
# DIRECT_SENTENCE_ABLATION_REQUIRE=1 loads without running.
# Does not construct a runtime client unless the gate has already passed.
# One call per process. Does not search, open a session, or score the answer.
# The runtime client is built with retry_limit 0 and max_attempts 1.

def direct_sentence_ablation_main
  capture = ENV["DIRECT_SENTENCE_ABLATION_CAPTURE"].presence ||
    Rag::Phase5GenerationReplay.default_capture_dir.to_s
  output = ENV["DIRECT_SENTENCE_ABLATION_OUTPUT"].presence ||
    Rag::DirectSentenceAblation.default_output_dir.to_s
  ablation = Rag::DirectSentenceAblation
  unless ENV[ablation::AUTHORIZED_ENV] == "1"
    puts ablation.preview(capture_dir: capture, output_dir: output).to_h.to_json
    return 2
  end

  gated = ablation.gate(capture_dir: capture, output_dir: output)
  unless gated.sendable?
    puts gated.to_h.to_json
    return 2
  end

  result = ablation.run(
    capture_dir: capture,
    output_dir: output,
    client: direct_sentence_invoke_client
  )
  direct_sentence_write_operations(output, result)
  puts result.to_h.to_json
  result.status == "recorded" ? 0 : 2
end

def direct_sentence_invoke_client
  direct_sentence_watch_operations!
  probe = Class.new { include AwsClientInitializer }.new
  options = probe.send(:build_aws_client_options).merge(retry_limit: 0, max_attempts: 1)
  sdk = Aws::BedrockRuntime::Client.new(options)
  DirectSentenceInvokeClient.new(sdk)
end

def direct_sentence_watch_operations!
  DirectSentenceOperationCounter.watch!(Aws::BedrockRuntime::Client, %i[invoke_model converse])
  if defined?(Aws::BedrockAgentRuntime::Client)
    DirectSentenceOperationCounter.watch!(Aws::BedrockAgentRuntime::Client, %i[retrieve])
  end
  return unless defined?(Aws::S3::Client)

  DirectSentenceOperationCounter.watch!(Aws::S3::Client, %i[get_object put_object])
end

def direct_sentence_write_operations(output, result)
  attempt = result.step
  return unless attempt.is_a?(Integer)

  directory = Pathname(output).join(format("sample_%d", attempt))
  return unless directory.directory?

  File.write(directory.join("operations.json"), "#{JSON.pretty_generate(DirectSentenceOperationCounter.to_h)}\n")
end

# Counts SDK operations for this process. Does not call them.
module DirectSentenceOperationCounter
  module_function

  def calls
    @calls ||= []
  end

  def watched
    @watched ||= []
  end

  def watch!(klass, names)
    existing = names.select { |name| klass.method_defined?(name) || klass.private_method_defined?(name) }
    existing.each { |name| watched << "#{klass.name}##{name}" }
    return if existing.empty?

    counter = self
    klass.prepend(Module.new do
      existing.each do |name|
        define_method(name) do |*args, **kwargs, &block|
          counter.calls << "#{klass.name}##{name}"
          super(*args, **kwargs, &block)
        end
      end
    end)
  end

  def to_h
    { "calls" => calls.dup, "watched" => watched.uniq }
  end
end

# Thin view over the runtime client. The service checks the view and then
# calls invoke_model once. This class does not retry.
class DirectSentenceInvokeClient
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

unless ENV["DIRECT_SENTENCE_ABLATION_REQUIRE"] == "1"
  code = direct_sentence_ablation_main
  exit code unless code.zero?
end
