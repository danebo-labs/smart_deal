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
    # Set by the Fase 6 benchmark (2026-09-09), which expected cost to be noise
    # and the jargon error rate to decide. It did decide — for the cheapest
    # provider, which is not the outcome section 4 anticipated. Groq won all
    # three axes at once: 34× cheaper than Transcribe, 12× lower p50 latency
    # (0.87 s vs 10–14 s, with a 912 s p95 on Amazon's batch poll), and the only
    # lane whose single content error was a homophone a certifier reads past
    # ("rosa" for "roza") instead of a destroyed word ("Hura" for "holgura") or
    # a changed number ("dos separadas" for "doce paradas", OpenAI).
    #
    # Amazon Transcribe stays registered as the escape hatch, not as a fallback:
    # it is the lane to switch to if a certifier ever requires the audio to
    # never leave AWS. Switching is STT_PROVIDER, no deploy — which is also how
    # OpenAI is reached if Groq degrades. Nothing fails over automatically,
    # because a second provider call is a second invoice (fixed rule 13).
    DEFAULT_PROVIDER = "groq"

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
