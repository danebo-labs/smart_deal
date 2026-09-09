# frozen_string_literal: true

module SpeechToText
  # The single entry point to the transcription layer:
  #
  #   SpeechToText::Client.for.transcribe(s3_key: key, language: "es-CL")
  #
  # Provider resolution is explicit argument → ENV["STT_PROVIDER"] → default.
  # The per-call argument is not decoration: the benchmark of Fase 6 runs one
  # set of audios through every adapter inside a single process, which a
  # process-wide environment variable cannot express.
  class Client
    # Amazon Transcribe is the baseline because it adds no vendor: same AWS
    # account, same IAM, same bucket. Fase 6 decides the permanent default by
    # measuring error rate on technical jargon, which is the real driver — at
    # these prices the cost difference per report is noise (plan section 4).
    DEFAULT_PROVIDER = "amazon_transcribe"

    ADAPTERS = {
      "amazon_transcribe" => AmazonTranscribeAdapter,
      "openai"            => OpenAiAdapter,
      "groq"              => GroqAdapter
    }.freeze

    # @param provider [String, Symbol, nil] registry name; falls back to
    #   ENV["STT_PROVIDER"], then DEFAULT_PROVIDER
    # @param client [Object, nil] the provider transport, injected by tests and
    #   by nothing else. Its shape is the provider's own: an
    #   Aws::TranscribeService::Client for Amazon, a Net::HTTP-like object
    #   responding to #request for the OpenAI-compatible adapters.
    # @raise [UnknownProviderError]
    def self.for(provider = nil, client: nil)
      name = resolve_provider(provider)
      adapter = ADAPTERS[name]
      if adapter.nil?
        raise UnknownProviderError,
              "unknown STT provider #{name.inspect}; known providers: #{providers.join(', ')}"
      end

      adapter.new(provider: name, client: client)
    end

    def self.resolve_provider(provider = nil)
      (provider.presence || ENV["STT_PROVIDER"].presence || DEFAULT_PROVIDER).to_s
    end

    def self.providers
      ADAPTERS.keys
    end

    # Whether this process can authenticate that provider. Wire-compatible
    # APIs (OpenAI and Groq) still need their own key: an OPENAI_API_KEY
    # does not authenticate api.groq.com.
    def self.configured?(provider = nil)
      name = resolve_provider(provider)
      adapter = ADAPTERS[name]
      if adapter.nil?
        raise UnknownProviderError,
              "unknown STT provider #{name.inspect}; known providers: #{providers.join(', ')}"
      end

      adapter.configured?
    end

    def self.available_providers
      providers.select { |name| ADAPTERS[name].configured? }
    end
  end
end
