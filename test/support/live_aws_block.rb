# frozen_string_literal: true

# Test processes refuse live Bedrock calls. Unsetting an environment variable
# does not provide this: a leaked owner mode still constructs the real client.
# A stub that replaces Client.new, or a singleton stub on one instance, never
# reaches these methods.
module LiveAwsBlock
  class Refused < StandardError; end

  OPERATIONS = {
    "Aws::BedrockRuntime::Client" => %i[
      converse converse_stream invoke_model invoke_model_with_response_stream
    ],
    "Aws::BedrockAgentRuntime::Client" => %i[
      retrieve retrieve_and_generate
    ]
  }.freeze

  module_function

  def install!
    OPERATIONS.each do |class_name, operations|
      klass = class_name.safe_constantize
      next unless klass

      operations.each do |operation|
        next unless klass.method_defined?(operation) || klass.private_method_defined?(operation)

        klass.prepend(refusal(class_name, operation))
      end
    end
  end

  def refusal(class_name, operation)
    Module.new do
      define_method(operation) do |*_args, **_kwargs, &_block|
        raise LiveAwsBlock::Refused, "#{class_name}##{operation} is blocked in test"
      end
    end
  end
end
