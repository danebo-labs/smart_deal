# frozen_string_literal: true

# Shared retry wrapper for Aurora Serverless cold-start errors.
# Used by KbSyncService (BedrockAgent) and BedrockRagService (BedrockAgentRuntime).
#
# Bedrock may surface the auto-paused cluster as Aws::BedrockAgent::Errors::ValidationException
# (subclass of ServiceError) — still matched by error_classes: [ServiceError] when the message
# matches AURORA_RESUME_PATTERN.
#
# Usage:
#   Bedrock::AuroraColdStartRetry.with_retry(
#     error_classes: [Aws::BedrockAgent::Errors::ServiceError],
#     on_retry: ->(attempt, delay) { ... }
#   ) { @client.start_ingestion_job(...) }
module Bedrock
  module AuroraColdStartRetry
    AURORA_RESUME_PATTERN = /aurora.*auto-paused|resuming after being auto-paused/i.freeze
    RETRY_DELAYS = [ 15, 30, 45 ].freeze

    module_function

    def sleep_for(seconds) = sleep(seconds)

    # @param error_classes [Array<Class>] exception classes to intercept
    # @param on_retry      [Proc, nil]    called with (attempt, delay) before each sleep
    # @yield block to execute with retry
    def with_retry(error_classes:, on_retry: nil)
      attempts = 0
      begin
        attempts += 1
        yield
      rescue *error_classes => e
        delay = RETRY_DELAYS[attempts - 1]
        raise unless delay && e.message.match?(AURORA_RESUME_PATTERN)

        Rails.logger.warn("[Aurora] cold start (attempt #{attempts}), waiting #{delay}s… (#{e.class}: #{e.message})")
        on_retry&.call(attempts, delay)
        sleep_for(delay)
        retry
      end
    end
  end
end
