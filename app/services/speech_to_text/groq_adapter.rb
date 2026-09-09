# frozen_string_literal: true

module SpeechToText
  # Groq's audio endpoint is OpenAI-compatible, so the third provider is four
  # constants rather than a new client. The plan listed this adapter as
  # optional for Fase 4 precisely because it was expected to be cheap if the
  # contract came out right; it is included as the proof that it did, and so
  # the benchmark of Fase 6 has three providers on day one.
  #
  # Cheapest hosted option surveyed by an order of magnitude (plan section 4),
  # which makes it the interesting contender against Amazon Transcribe once
  # jargon error rate is actually measured.
  class GroqAdapter < OpenAiAdapter
    PROVIDER_NAME    = "groq"
    ENDPOINT         = "https://api.groq.com/openai/v1/audio/transcriptions"
    DEFAULT_MODEL    = "whisper-large-v3-turbo"
    MODEL_ENV        = "STT_GROQ_MODEL"
    API_KEY_ENV      = "GROQ_API_KEY"
    CREDENTIALS_PATH = %i[groq api_key].freeze
  end
end
