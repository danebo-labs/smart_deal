# frozen_string_literal: true

# Fire-and-forget warmup for the Aurora Serverless vector store backing the
# Bedrock Knowledge Base. Aurora goes to standby after ~5 min idle to save
# cost in MVO; the first query after standby pays a 30–60s cold-start.
#
# Enqueued from web entry points (login, home reload) so Aurora is warm by
# the time the technician asks a real question. Throttled via Rails.cache
# to one ping per 4 minutes per KB.
class WarmBedrockKbJob < ApplicationJob
  queue_as :default

  THROTTLE_TTL = 4.minutes
  THROTTLE_KEY = "bedrock_kb_warm:last_ping"

  discard_on StandardError do |_job, error|
    Rails.logger.warn("[KB_WARM] discarded: #{error.class}: #{error.message}")
  end

  def perform
    return if throttled?

    knowledge_base_id = ENV["BEDROCK_KNOWLEDGE_BASE_ID"].presence ||
                        Rails.application.credentials.dig(:bedrock, :knowledge_base_id)
    return unless knowledge_base_id

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    client  = Aws::BedrockAgentRuntime::Client.new(aws_options)

    client.retrieve(
      knowledge_base_id: knowledge_base_id,
      retrieval_query:   { text: "warm" },
      retrieval_configuration: {
        vector_search_configuration: { number_of_results: 1 }
      }
    )

    elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    Rails.cache.write(THROTTLE_KEY, Time.current.to_i, expires_in: THROTTLE_TTL)
    Rails.logger.info("[KB_WARM] ok ms=#{elapsed_ms} kb=#{knowledge_base_id}")
  end

  private

  def throttled?
    Rails.cache.exist?(THROTTLE_KEY)
  end

  # Inline copy of the AWS client option resolution. Kept tiny on purpose:
  # a warmup job must not depend on the full BedrockRagService boot path.
  def aws_options
    region = ENV.fetch("AWS_REGION", nil).presence ||
             Rails.application.credentials.dig(:aws, :region) ||
             "us-east-1"

    opts = { region: region }

    bearer = ENV["AWS_BEARER_TOKEN_BEDROCK"].presence ||
             ENV["AWS_BEDROCK_BEARER_TOKEN"].presence ||
             Rails.application.credentials.dig(:aws, :bedrock_bearer_token)
    if bearer
      opts[:token_provider] = Aws::StaticTokenProvider.new(bearer)
    elsif (k = ENV["AWS_ACCESS_KEY_ID"].presence) && (s = ENV["AWS_SECRET_ACCESS_KEY"].presence)
      opts[:access_key_id]     = k
      opts[:secret_access_key] = s
    end

    opts[:http_open_timeout] = ENV.fetch("AWS_HTTP_OPEN_TIMEOUT", 5).to_i
    opts[:http_read_timeout] = ENV.fetch("AWS_HTTP_READ_TIMEOUT", 90).to_i
    opts[:http_idle_timeout] = ENV.fetch("AWS_HTTP_IDLE_TIMEOUT", 5).to_i
    opts
  end
end
