# frozen_string_literal: true

module Rag
  # One application retry policy for a transient Bedrock error. The SDK client
  # stays at one HTTP attempt. Waits grow from BASE_SECONDS and stop at
  # CAP_SECONDS. Jitter is at most a quarter of the step, so the sequence
  # still increases until the cap.
  class TransientBackoff
    DEFAULT_LIMIT = 3
    BASE_SECONDS = 0.4
    CAP_SECONDS = 8.0
    LIMIT_ENV = "RAG_TRANSIENT_ATTEMPT_LIMIT"
    RECOVERY_ENV = "RAG_TRANSIENT_RECOVERY_PAUSE"
    DEFAULT_RECOVERY_PAUSE = 20.0

    def self.limit
      raw = ENV[LIMIT_ENV].to_s
      return DEFAULT_LIMIT unless raw.match?(/\A[1-9]\d*\z/)

      raw.to_i
    end

    def self.recovery_pause
      raw = ENV[RECOVERY_ENV].to_s
      return DEFAULT_RECOVERY_PAUSE if raw.empty?
      return DEFAULT_RECOVERY_PAUSE unless raw.match?(/\A\d+(?:\.\d+)?\z/)

      raw.to_f
    end

    def self.wait_seconds(index, rng: Random.new)
      growth = BASE_SECONDS * (2**index)
      bounded = [ growth, CAP_SECONDS ].min
      jitter = rng.rand * bounded * 0.25
      [ bounded + jitter, CAP_SECONDS ].min.round(3)
    end
  end
end
