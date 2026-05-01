# frozen_string_literal: true

# app/services/concerns/aws_client_initializer.rb
module AwsClientInitializer
  extend ActiveSupport::Concern

  private

  # Builds AWS client options from ENV (loaded from .env in dev) or Rails credentials.
  # ENV takes priority so .env "just works" in development.
  # In production (no .env file), Rails encrypted credentials are used.
  # Supports both bearer token and access_key/secret_key authentication.
  #
  # @param region [String, nil] AWS region (defaults to us-east-1)
  # @return [Hash] Options hash for AWS client initialization
  def build_aws_client_options(region: nil)
    region ||= ENV.fetch('AWS_REGION', nil).presence ||
               Rails.application.credentials.dig(:aws, :region) ||
               'us-east-1'

    access_key_id = ENV.fetch('AWS_ACCESS_KEY_ID', nil).presence ||
                    Rails.application.credentials.dig(:aws, :access_key_id)
    secret_access_key = ENV.fetch('AWS_SECRET_ACCESS_KEY', nil).presence ||
                        Rails.application.credentials.dig(:aws, :secret_access_key)
    bearer_token = ENV['AWS_BEARER_TOKEN_BEDROCK'].presence ||
                   ENV.fetch('AWS_BEDROCK_BEARER_TOKEN', nil).presence ||
                   Rails.application.credentials.dig(:aws, :bedrock_bearer_token) ||
                   Rails.application.credentials.dig(:aws, :bedrock_api_key)

    ca_bundle_path = ENV['AWS_CA_BUNDLE'].presence || ENV['SSL_CERT_FILE'].presence

    client_options = { region: region }

    if bearer_token.present?
      client_options[:token_provider] = Aws::StaticTokenProvider.new(bearer_token)
    elsif access_key_id.present? && secret_access_key.present?
      client_options[:access_key_id] = access_key_id
      client_options[:secret_access_key] = secret_access_key
    end

    client_options[:ssl_ca_bundle] = ca_bundle_path if ca_bundle_path.present? && File.exist?(ca_bundle_path)

    # Explicit HTTP timeouts. Without these, slow/dead AWS endpoints can hang
    # Puma threads indefinitely (default open_timeout in Net::HTTP is 60s but
    # read_timeout has historically been "no limit" → unbounded blocking).
    # AWS_HTTP_READ_TIMEOUT must comfortably exceed Aurora Serverless cold-start
    # (≤ 60s) plus generation time → 90s default keeps RAG responses safe.
    client_options[:http_open_timeout] = (ENV.fetch('AWS_HTTP_OPEN_TIMEOUT', 5)).to_i
    client_options[:http_read_timeout] = (ENV.fetch('AWS_HTTP_READ_TIMEOUT', 90)).to_i
    client_options[:http_idle_timeout] = (ENV.fetch('AWS_HTTP_IDLE_TIMEOUT', 5)).to_i

    client_options
  end
end
