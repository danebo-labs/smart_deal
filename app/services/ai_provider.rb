# frozen_string_literal: true

# app/services/ai_provider.rb

class AiProvider
  def initialize(provider: nil)
    # Only Bedrock is supported. Other providers were removed as they were never used.
    @provider = (provider || ENV.fetch('AI_PROVIDER', 'bedrock')).downcase

    raise "Unknown AI provider: #{@provider}. Only 'bedrock' is supported." unless @provider == 'bedrock'

    @client = BedrockClient.new
  end

  def query(prompt, **)
    @client.query(prompt, **)
  rescue StandardError => e
    Rails.logger.error("AiProvider error with #{@provider}: #{e.message}")
    raise e
  end
end
