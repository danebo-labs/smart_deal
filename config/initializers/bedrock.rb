# frozen_string_literal: true

require 'aws-sdk-bedrockruntime'

DEFAULT_BEDROCK_REGION = ENV.fetch('AWS_REGION', nil).presence ||
                         Rails.application.credentials.dig(:aws, :region) ||
                         'us-east-1'
Aws.use_bundled_cert!

# Resolve AWS credentials: ENV takes priority (loaded from .env in dev),
# then Rails encrypted credentials as fallback (used in production).
aws_access_key = ENV.fetch('AWS_ACCESS_KEY_ID', nil).presence ||
                 Rails.application.credentials.dig(:aws, :access_key_id)
aws_secret_key = ENV.fetch('AWS_SECRET_ACCESS_KEY', nil).presence ||
                 Rails.application.credentials.dig(:aws, :secret_access_key)

if aws_access_key.present? && aws_secret_key.present?
  Aws.config.update(
    region: DEFAULT_BEDROCK_REGION,
    credentials: Aws::Credentials.new(aws_access_key, aws_secret_key)
  )
else
  Aws.config.update(region: DEFAULT_BEDROCK_REGION)
end

module BedrockProfiles
  CLAUDE_35_HAIKU = ENV.fetch('BEDROCK_PROFILE_CLAUDE35_HAIKU', 'us.anthropic.claude-3-5-haiku-20241022-v1:0')
end
