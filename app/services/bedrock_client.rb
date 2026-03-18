# frozen_string_literal: true

# app/services/bedrock_client.rb

require 'aws-sdk-bedrockruntime'
require 'aws-sdk-core/token_provider'
require 'aws-sdk-core/static_token_provider'
require 'json'

class BedrockClient
  include AwsClientInitializer

  # Fixed query model: Claude Haiku 4.5 (cost-effective, fast). Override via BEDROCK_MODEL_ID env var.
  QUERY_MODEL_ID = (ENV.fetch('BEDROCK_MODEL_ID', nil).presence ||
                    Rails.application.credentials.dig(:bedrock, :model_id) ||
                    'global.anthropic.claude-haiku-4-5-20251001-v1:0').freeze

  DEFAULT_MODEL_ID = QUERY_MODEL_ID

  def initialize(region: nil)
    client_options = build_aws_client_options(region: region)
    @client = Aws::BedrockRuntime::Client.new(client_options)
  end

  def generate_text(prompt, model_id: DEFAULT_MODEL_ID, max_tokens: 2000, temperature: 0.7)
    model_id ||= DEFAULT_MODEL_ID

    body = {
      anthropic_version: 'bedrock-2023-05-31',
      max_tokens: max_tokens,
      temperature: temperature,
      messages: [{ role: 'user', content: prompt }]
    }

    start_time = Time.current
    response = @client.invoke_model(
      model_id: model_id,
      content_type: 'application/json',
      body: body.to_json
    )

    result = JSON.parse(response.body.read)
    text = result.dig('content', 0, 'text') || result.to_s

    track_usage(result, model_id, prompt, start_time)

    text
  rescue StandardError => e
    Rails.logger.error("Bedrock error: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    nil
  end

  # Compatibility method for AiProvider
  def query(prompt, **opts)
    opts.delete(:images)
    generate_text(prompt, **opts)
  end

  private

  def track_usage(result, model_id, prompt, start_time)
    usage = result['usage'] || {}
    input_tokens = (usage['input_tokens'] || usage['inputTokens']).to_i
    output_tokens = (usage['output_tokens'] || usage['outputTokens']).to_i

    return if input_tokens <= 0

    latency_ms = ((Time.current - start_time) * 1000).to_i
    BedrockQuery.create!(
      model_id: model_id,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      user_query: prompt.to_s.truncate(500),
      latency_ms: latency_ms,
      created_at: Time.current
    )
    SimpleMetricsService.update_database_metrics_only
    Rails.logger.info("BedrockClient: tracked #{input_tokens} in + #{output_tokens} out tokens")
  rescue StandardError => e
    Rails.logger.error("BedrockClient: failed to track usage: #{e.message}")
  end
end
