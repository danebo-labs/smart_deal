# frozen_string_literal: true

# app/services/bedrock_client.rb

require 'aws-sdk-bedrockruntime'
require 'aws-sdk-core/token_provider'
require 'aws-sdk-core/static_token_provider'
require 'json'

class BedrockClient
  include AwsClientInitializer

  CLAUDE_35_HAIKU = ENV.fetch('BEDROCK_PROFILE_CLAUDE35_HAIKU', 'us.anthropic.claude-3-5-haiku-20241022-v1:0')

  MODELS_MAP = {
    # Inference Profiles Globales (máximo throughput, recomendados)
    'Anthropic Claude Sonnet 4.5 (Global)' => 'global.anthropic.claude-sonnet-4-5-20250929-v1:0',
    'Anthropic Claude Haiku 4.5 (Global)'  => 'global.anthropic.claude-haiku-4-5-20251001-v1:0',
    'Anthropic Claude Opus 4.5 (Global)'   => 'global.anthropic.claude-opus-4-5-20251101-v1:0',
    # Inference Profiles Regionales US (residencia de datos)
    'Anthropic Claude Sonnet 4.5 (US)'     => 'us.anthropic.claude-sonnet-4-5-20250929-v1:0',
    'Anthropic Claude Haiku 4.5 (US)'      => 'us.anthropic.claude-haiku-4-5-20251001-v1:0',
    'Anthropic Claude Opus 4.5 (US)'       => 'us.anthropic.claude-opus-4-5-20251101-v1:0',
    # Modelos directos Claude 3.x
    'Anthropic Claude 3.7 Sonnet'          => 'anthropic.claude-3-7-sonnet-20250219-v1:0',
    'Anthropic Claude 3.5 Sonnet v2'       => 'anthropic.claude-3-5-sonnet-20241022-v2:0'
  }.freeze

  ALLOWED_MODEL_IDS = MODELS_MAP.values.freeze

  DEFAULT_MODEL_ID = ENV.fetch('BEDROCK_MODEL_ID', CLAUDE_35_HAIKU)
  VISION_MODEL_ID = ENV.fetch('BEDROCK_VISION_MODEL_ID', 'us.anthropic.claude-3-5-sonnet-20241022-v2:0')

  def initialize(region: nil)
    client_options = build_aws_client_options(region: region)
    @client = Aws::BedrockRuntime::Client.new(client_options)
  end

  def generate_text(prompt, model_id: DEFAULT_MODEL_ID, max_tokens: 2000, temperature: 0.7, images: [])
    model_id ||= DEFAULT_MODEL_ID
    content = build_message_content(prompt, images)

    # Haiku on Bedrock does not support image input — auto-switch to Sonnet for vision
    effective_model = if images.present? && model_id == DEFAULT_MODEL_ID
                        Rails.logger.info("BedrockClient: Switching to vision model #{VISION_MODEL_ID} for image input")
                        VISION_MODEL_ID
    else
                        model_id
    end

    body = {
      anthropic_version: 'bedrock-2023-05-31',
      max_tokens: max_tokens,
      temperature: temperature,
      messages: [{ role: 'user', content: content }]
    }

    response = @client.invoke_model(
      model_id: effective_model,
      content_type: 'application/json',
      body: body.to_json
    )

    result = JSON.parse(response.body.read)
    result.dig('content', 0, 'text') || result.to_s
  rescue StandardError => e
    Rails.logger.error("Bedrock error: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    nil
  end

  # Compatibility method for AiProvider
  def query(prompt, **)
    generate_text(prompt, **)
  end

  private

  # Builds the content field for the Anthropic Messages API.
  # With images: returns an array of image + text blocks (multimodal).
  # Without images: returns the prompt string (text-only, backward compatible).
  def build_message_content(prompt, images)
    return prompt if images.blank?

    image_blocks = images.map do |img|
      {
        type: 'image',
        source: {
          type: 'base64',
          media_type: img[:media_type] || img['media_type'],
          data: img[:data] || img['data']
        }
      }
    end

    image_blocks + [{ type: 'text', text: prompt }]
  end
end
