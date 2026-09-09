# frozen_string_literal: true

module SpeechToText
  # OpenAI's /v1/audio/transcriptions, synchronous — one multipart POST, no
  # polling, unlike the Amazon batch path.
  #
  # Hand-rolled Net::HTTP rather than the ruby-openai gem already in the
  # Gemfile: the whole request is one multipart form, and doing it directly
  # keeps the HTTP surface identical to AnthropicTokenCounter, the repo's other
  # direct API client. It also means the injected transport is a plain
  # Net::HTTP-shaped object, so tests inspect the actual bytes on the wire
  # instead of a gem's internal call.
  #
  # GroqAdapter subclasses this: the Groq audio API is OpenAI-compatible, so
  # only the endpoint, model and credential differ. That the second provider
  # cost fifteen lines is the evidence that the contract holds.
  class OpenAiAdapter
    PROVIDER_NAME    = "openai"
    ENDPOINT         = "https://api.openai.com/v1/audio/transcriptions"
    DEFAULT_MODEL    = "gpt-4o-mini-transcribe"
    MODEL_ENV        = "STT_OPENAI_MODEL"
    API_KEY_ENV      = "OPENAI_API_KEY"
    CREDENTIALS_PATH = %i[openai api_key].freeze

    # The API's own limit. A 20 minute Opus dictation is a few megabytes, so
    # this should never fire — but a clear error beats a 413 from the provider.
    MAX_UPLOAD_BYTES = 25 * 1024 * 1024
    TIMEOUT_SECONDS  = 300

    # @param client [Object, nil] Net::HTTP-shaped transport responding to
    #   #request; injected by tests
    # @param s3 [S3DocumentsService, nil] injected by tests
    # Each OpenAI-compatible vendor reads its own credential. GroqAdapter
    # inherits this and checks GROQ_API_KEY — an OpenAI key is not a Groq key.
    def self.configured?
      ENV[self::API_KEY_ENV].present? ||
        Rails.application.credentials.dig(*self::CREDENTIALS_PATH).present?
    end

    # @param prompt [String, nil] jargon hint sent to the endpoint. nil means
    #   "whatever JargonPrompt is configured to"; an empty string means "send
    #   none", which is how the benchmark measures the lever against itself.
    def initialize(provider: nil, client: nil, model: nil, s3: nil, prompt: nil)
      @provider = (provider.presence || self.class::PROVIDER_NAME).to_s
      @client   = client
      @model    = model.presence || ENV.fetch(self.class::MODEL_ENV, self.class::DEFAULT_MODEL)
      @s3       = s3
      @prompt   = (prompt.nil? ? JargonPrompt.text : prompt).to_s
    end

    # @return [SpeechToText::Result]
    # @raise [SpeechToText::ConfigurationError, SpeechToText::ProviderError]
    def transcribe(s3_key:, language: SpeechToText::DEFAULT_LANGUAGE, duration_hint_seconds: nil)
      raise ConfigurationError, "no audio S3 key given to #{@provider}" if s3_key.blank?

      audio = s3.download(s3_key)
      raise ConfigurationError, "no audio found at #{s3_key} for #{@provider}" if audio.blank?

      if audio.bytesize > MAX_UPLOAD_BYTES
        raise ProviderError,
              "#{@provider} rejects uploads over #{MAX_UPLOAD_BYTES / 1.megabyte} MB " \
              "(audio is #{(audio.bytesize / 1.megabyte.to_f).round(1)} MB)"
      end

      payload = post_audio(
        audio: audio,
        filename: File.basename(s3_key.to_s),
        language: primary_subtag(language)
      )
      text = payload["text"]
      raise ProviderError, "#{@provider} returned no text field" if text.nil?

      Result.new(
        text: text,
        # Neither OpenAI nor Groq report audio length on this endpoint, so the
        # duration measured at recording time is the only figure available —
        # and it is what the cost estimate is built on.
        duration_seconds: duration_hint_seconds,
        provider: @provider,
        model: @model,
        raw: payload
      )
    end

    private

    def post_audio(audio:, filename:, language:)
      boundary = "----DaneboSTT#{SecureRandom.hex(12)}"
      uri      = URI(self.class::ENDPOINT)

      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{api_key}"
      request["Content-Type"]  = "multipart/form-data; boundary=#{boundary}"
      request.body = multipart_body(boundary, audio, filename, language, @prompt)

      response = transport(uri).request(request)
      unless response.code.to_i == 200
        raise ProviderError,
              "#{@provider} responded #{response.code}: #{response.body.to_s.first(300)}"
      end

      JSON.parse(response.body)
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise ProviderError, "#{@provider} timed out after #{TIMEOUT_SECONDS}s: #{e.class}"
    rescue JSON::ParserError => e
      raise ProviderError, "#{@provider} returned unparseable JSON: #{e.message}"
    end

    def multipart_body(boundary, audio, filename, language, prompt)
      body = +""
      body << text_part(boundary, "model", @model)
      body << text_part(boundary, "response_format", "json")
      body << text_part(boundary, "language", language) if language.present?
      body << text_part(boundary, "prompt", prompt) if prompt.present?
      body << "--#{boundary}\r\n" \
              "Content-Disposition: form-data; name=\"file\"; filename=\"#{filename}\"\r\n" \
              "Content-Type: application/octet-stream\r\n\r\n"
      body.force_encoding(Encoding::BINARY)
      body << audio.dup.force_encoding(Encoding::BINARY)
      body << "\r\n--#{boundary}--\r\n".b
      body
    end

    def text_part(boundary, name, value)
      "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"\r\n\r\n#{value}\r\n"
    end

    # The contract speaks canonical BCP-47 ("es-CL"); this endpoint only
    # accepts ISO-639-1 and rejects the region subtag.
    def primary_subtag(language)
      language.to_s.split("-").first.presence
    end

    def api_key
      key = ENV[self.class::API_KEY_ENV].presence ||
            Rails.application.credentials.dig(*self.class::CREDENTIALS_PATH).presence
      return key if key

      raise ConfigurationError,
            "no API key for #{@provider}: set #{self.class::API_KEY_ENV} " \
            "or credentials #{self.class::CREDENTIALS_PATH.join('.')}"
    end

    def transport(uri)
      @client ||= begin
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl      = true
        http.open_timeout = 10
        http.read_timeout = TIMEOUT_SECONDS
        http
      end
    end

    def s3
      @s3 ||= S3DocumentsService.new
    end
  end
end
