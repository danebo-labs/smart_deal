# app/services/bedrock_client.rb

require "aws-sdk-bedrockruntime"
require "aws-sdk-core/token_provider"
require "aws-sdk-core/static_token_provider"
require "json"

class BedrockClient
  DEFAULT_MODEL_ID = ENV.fetch("BEDROCK_MODEL_ID", BedrockProfiles::CLAUDE_35_HAIKU)

  def initialize(region: nil)
    region ||= ENV.fetch("AWS_REGION", "us-east-1")
    
    # Get credentials from Rails credentials or environment variables
    access_key_id = Rails.application.credentials.dig(:aws, :access_key_id) || ENV["AWS_ACCESS_KEY_ID"]
    secret_access_key = Rails.application.credentials.dig(:aws, :secret_access_key) || ENV["AWS_SECRET_ACCESS_KEY"]
    bearer_token = Rails.application.credentials.dig(:aws, :bedrock_bearer_token) ||
                   Rails.application.credentials.dig(:aws, :bedrock_api_key) ||
                   ENV["AWS_BEARER_TOKEN_BEDROCK"] ||
                   ENV["AWS_BEDROCK_BEARER_TOKEN"]
    
    ca_bundle_path = ENV["AWS_CA_BUNDLE"].presence || ENV["SSL_CERT_FILE"].presence

    # Prefer bearer token when provided; otherwise fall back to access/secret keys or default profile
    client_options = { region: region }
    if bearer_token.present?
      client_options[:token_provider] = Aws::StaticTokenProvider.new(bearer_token)
    elsif access_key_id.present? && secret_access_key.present?
      client_options[:access_key_id] = access_key_id
      client_options[:secret_access_key] = secret_access_key
    end

    client_options[:ssl_ca_bundle] = ca_bundle_path if ca_bundle_path.present? && File.exist?(ca_bundle_path)
    
    @client = Aws::BedrockRuntime::Client.new(client_options)
  end

  def generate_text(prompt, model_id: DEFAULT_MODEL_ID, max_tokens: 2000, temperature: 0.7)
    body = {
      "anthropic_version": "bedrock-2023-05-31",
      "max_tokens": max_tokens,
      "temperature": temperature,
      "messages": [{ "role": "user", "content": prompt }]
    }

    response = @client.invoke_model(
      model_id: model_id,
      content_type: "application/json",
      body: body.to_json
    )

    result = JSON.parse(response.body.read)
    result.dig("content", 0, "text") || result.to_s
  rescue => e
    Rails.logger.error("Bedrock error: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    nil
  end

  # Compatibility method for AiProvider
  def query(prompt, **options)
    generate_text(prompt, **options)
  end
end

