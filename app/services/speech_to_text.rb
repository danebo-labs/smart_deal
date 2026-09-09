# frozen_string_literal: true

# The vocabulary of the transcription contract (Fase 4 of
# docs/PLAN_IMPLEMENTACION_CERTIFICADOR_2026-08-09.md).
#
# Audio-to-text is one of the two independently swappable layers of the module —
# the other is text-to-findings (Fase 7, conditional). Everything a provider is
# allowed to know lives here: an S3 key in, a Result out. Adapters never touch
# the database, never write telemetry and never broadcast; state, cost and
# delivery belong to TranscriptionJob. That separation is what makes changing
# provider a configuration change instead of an architectural one.
module SpeechToText
  # Canonical BCP-47 tag for the dialect actually being spoken. No provider
  # takes it verbatim, and that is the point: each adapter narrows it to its own
  # vocabulary — Amazon Transcribe to one of its three Spanish variants
  # (es-US by default), the OpenAI-compatible APIs to the ISO-639-1 primary
  # subtag. Keeping the canonical tag here means a provider's list of supported
  # codes never leaks into the callers.
  DEFAULT_LANGUAGE = "es-CL"

  # What every adapter returns.
  #
  # @!attribute text
  #   the transcript, verbatim from the provider
  # @!attribute duration_seconds
  #   audio length the provider reported, or nil when it reports none — the
  #   caller falls back to the duration measured at recording time
  # @!attribute provider
  #   registry name, so a Result can be costed without knowing who asked
  # @!attribute model
  #   the concrete model billed, which is what actually sets the rate
  # @!attribute raw
  #   provider payload, kept for the side-by-side comparison of Fase 6
  Result = Data.define(:text, :duration_seconds, :provider, :model, :raw)

  # Base of the hierarchy. The three subclasses exist because the job needs to
  # tell apart failures that cost money from failures that could not have.
  class Error < StandardError; end

  # Nothing was sent to the provider: a credential, bucket or audio object was
  # missing. Nothing was billed, and retrying changes nothing until the
  # configuration does.
  class ConfigurationError < Error; end

  # The provider was reached and refused, failed, or outlived the poll budget.
  # It may well have billed for the attempt, which is why the job records a
  # failure instead of quietly trying again.
  class ProviderError < Error; end

  # A provider name that is not in the registry — a typo in STT_PROVIDER, or a
  # benchmark asking for an adapter that was never written.
  class UnknownProviderError < Error; end
end
