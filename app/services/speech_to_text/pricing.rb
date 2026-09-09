# frozen_string_literal: true

module SpeechToText
  # Published list prices per minute of audio, batch tier, as surveyed in
  # section 4 of docs/PLAN_IMPLEMENTACION_CERTIFICADOR_2026-08-09.md.
  #
  # Versioned deliberately: a recorded cost_estimate_usd is only interpretable
  # if you know which table produced it, and Fase 6 compares estimates against
  # what the providers actually billed. Bumping VERSION alongside a rate change
  # is what keeps that comparison honest.
  #
  # This is an estimate, not invoice truth. Fase 6 reconciles against real
  # billing the same way BedrockInvocationLogReconciler does for Bedrock.
  module Pricing
    VERSION = "2026-08-09"

    RATES_USD_PER_MINUTE = {
      "amazon_transcribe" => 0.024,
      "openai"            => 0.003,
      "groq"              => 0.0007
    }.freeze

    # The model, not the provider, is what sets the rate once a provider offers
    # more than one. Takes precedence over the per-provider rate above.
    MODEL_RATES_USD_PER_MINUTE = {
      "gpt-4o-transcribe"      => 0.006,
      "gpt-4o-mini-transcribe" => 0.003,
      "whisper-large-v3-turbo" => 0.0007,
      "whisper-large-v3"       => 0.00185
    }.freeze

    # Amazon Transcribe bills a 15 second minimum per request, so a five-second
    # "the door scrapes" costs the same as fifteen. Relevant precisely because
    # short single-finding dictations are the expected shape of use.
    MINIMUM_BILLED_SECONDS = { "amazon_transcribe" => 15 }.freeze

    module_function

    # @return [Float, nil] nil when the provider is unpriced or the duration is
    #   unknown — a wrong number would be worse than an absent one, since this
    #   feeds the COGS hypothesis of the pricing model.
    def estimate_usd(provider:, duration_seconds:, model: nil)
      rate = MODEL_RATES_USD_PER_MINUTE[model.to_s] || RATES_USD_PER_MINUTE[provider.to_s]
      seconds = billed_seconds(provider: provider, duration_seconds: duration_seconds)
      return nil if rate.nil? || seconds.nil?

      ((seconds / 60.0) * rate).round(6)
    end

    # Seconds the invoice will charge, after the per-request minimum. Distinct
    # from wall-clock audio length: a 5 s Amazon clip is billed as 15 s, and
    # that is the number the Fase 6 "cost per minute" column has to use.
    def billed_seconds(provider:, duration_seconds:)
      return nil if duration_seconds.to_i <= 0

      [ duration_seconds.to_i, MINIMUM_BILLED_SECONDS.fetch(provider.to_s, 0) ].max
    end
  end
end
