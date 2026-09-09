# frozen_string_literal: true

require "aws-sdk-transcribeservice"

module SpeechToText
  # Amazon Transcribe, batch mode — the baseline provider. It adds no vendor to
  # onboard: the audio is already in our bucket and the IAM role already exists.
  #
  # Transcribe batch is start-a-job-then-poll, but #transcribe blocks until the
  # transcript is in hand. The alternative — a second job plus a table of
  # in-flight provider jobs — buys nothing here: TranscriptionJob runs on Solid
  # Queue, never on a request path, so the only cost of blocking is one held
  # worker thread, against a whole parallel state machine avoided. The poll is
  # bounded; exhausting the budget raises ProviderError so the dictation lands
  # in `failed` rather than hanging (plan section 5, Fase 4 Diseño).
  #
  # Operational note: Transcribe requires the media bucket to live in the same
  # region as the job, which is satisfied by reusing the app's own bucket and
  # AWS_REGION.
  class AmazonTranscribeAdapter
    include AwsClientInitializer

    PROVIDER_NAME = "amazon_transcribe"
    MODEL_NAME    = "amazon-transcribe-standard"

    # Transcribe writes its result JSON into our own bucket rather than handing
    # back a presigned URL on an Amazon-owned bucket, so the transcript is
    # readable with the S3 client we already have. Outside bulk_chunks/, so the
    # Knowledge Base never ingests a certifier's dictation.
    OUTPUT_PREFIX = "voice_dictations/transcripts"

    # Transcribe has no es-CL: its Spanish variants are exactly these three, so
    # the contract's canonical tag has to be narrowed before the job starts or
    # the API rejects it outright.
    SUPPORTED_SPANISH = %w[es-US es-ES es-MX].freeze

    # es-US, and not the peninsular es-ES, because of what the supported-language
    # table grants each one on the batch path we use: es-US is the only Spanish
    # variant that accepts custom language models — the lever for elevator jargon
    # (NCh 2840 terms, fault codes, brands) once Fase 6 has a corpus — and it is
    # lexically closer to Chilean Spanish. es-MX is the weakest of the three
    # here despite being Latin American: it transcribes numbers in streaming
    # only, and an inspection dictation is dense with them ("embarque 3", "450
    # kilos", "código A32.4").
    DEFAULT_PROVIDER_LANGUAGE = "es-US"
    LANGUAGE_ENV              = "STT_AMAZON_LANGUAGE_CODE"

    DEFAULT_POLL_TIMEOUT_SECONDS = 900
    POLL_INTERVAL_SECONDS        = 3

    # @param client [Aws::TranscribeService::Client, nil] injected in tests
    # @param s3 [S3DocumentsService, nil] injected in tests
    # @param sleeper [Proc, nil] injected in tests so the poll loop costs no
    #   wall-clock time
    def initialize(provider: PROVIDER_NAME, client: nil, s3: nil, sleeper: nil)
      @provider = provider.to_s
      @client   = client
      @s3       = s3
      @sleeper  = sleeper || ->(seconds) { sleep(seconds) }
    end

    # @return [SpeechToText::Result]
    # @raise [SpeechToText::ConfigurationError, SpeechToText::ProviderError]
    def transcribe(s3_key:, language: SpeechToText::DEFAULT_LANGUAGE, duration_hint_seconds: nil)
      raise ConfigurationError, "no audio S3 key given to #{@provider}" if s3_key.blank?

      bucket = s3.bucket_name
      raise ConfigurationError, "no S3 bucket configured for #{@provider}" if bucket.blank?

      job_name   = job_name_for(s3_key)
      output_key = "#{OUTPUT_PREFIX}/#{job_name}.json"

      start_job(job_name: job_name, bucket: bucket, s3_key: s3_key, language: language,
                output_key: output_key)
      poll_until_finished(job_name)
      payload = fetch_payload(output_key, job_name)

      text = payload.dig("results", "transcripts", 0, "transcript")
      if text.nil?
        raise ProviderError, "#{@provider} job #{job_name} returned no transcript block"
      end

      Result.new(
        text: text,
        duration_seconds: audio_seconds(payload) || duration_hint_seconds,
        provider: @provider,
        model: MODEL_NAME,
        raw: { job_name: job_name, output_key: output_key }
      )
    rescue Aws::TranscribeService::Errors::ServiceError => e
      raise ProviderError, "#{@provider} rejected the job: #{e.class.name.demodulize}: #{e.message}"
    end

    private

    def start_job(job_name:, bucket:, s3_key:, language:, output_key:)
      client.start_transcription_job(
        transcription_job_name: job_name,
        language_code: provider_language(language),
        media: { media_file_uri: "s3://#{bucket}/#{s3_key}" },
        output_bucket_name: bucket,
        output_key: output_key
      )
    end

    # Precedence: a caller asking for a variant Transcribe knows (the Fase 6
    # side-by-side) wins; then the ops-level override; then es-US. Any other
    # Spanish tag — the contract's es-CL included — collapses to the default,
    # and a non-Spanish tag passes through untouched.
    def provider_language(language)
      tag = language.to_s.presence || SpeechToText::DEFAULT_LANGUAGE
      return tag if SUPPORTED_SPANISH.include?(tag)
      return tag unless tag.split("-").first.casecmp?("es")

      ENV.fetch(LANGUAGE_ENV, DEFAULT_PROVIDER_LANGUAGE).presence || DEFAULT_PROVIDER_LANGUAGE
    end

    def poll_until_finished(job_name)
      deadline = monotonic_now + poll_timeout_seconds

      loop do
        job    = client.get_transcription_job(transcription_job_name: job_name).transcription_job
        status = job.transcription_job_status.to_s

        return job if status == "COMPLETED"

        if status == "FAILED"
          raise ProviderError, "#{@provider} job #{job_name} failed: #{job.failure_reason}"
        end

        if monotonic_now >= deadline
          raise ProviderError,
                "#{@provider} job #{job_name} still #{status} after #{poll_timeout_seconds}s"
        end

        @sleeper.call(POLL_INTERVAL_SECONDS)
      end
    end

    def fetch_payload(output_key, job_name)
      body = s3.download(output_key)
      raise ProviderError, "#{@provider} job #{job_name} left no result at #{output_key}" if body.blank?

      JSON.parse(body)
    rescue JSON::ParserError => e
      raise ProviderError, "#{@provider} job #{job_name} wrote unparseable JSON: #{e.message}"
    end

    # Transcribe reports no audio duration on the job itself, but its items
    # carry end times; the last one is the length that was billed. Preferred
    # over the duration measured in the browser because it is what AWS saw.
    def audio_seconds(payload)
      items = Array(payload.dig("results", "items"))
      last  = items.reverse.find { |item| item["end_time"].present? }
      return nil if last.nil?

      last["end_time"].to_f.ceil
    end

    # Job names must be unique per AWS account and accept only
    # [0-9a-zA-Z._-]. The random suffix is what keeps a legitimate second
    # attempt (an explicit human retry, or a stale re-claim) from colliding
    # with the first job's name; one billed call per attempt is already
    # guaranteed upstream by the claim, not by this name.
    def job_name_for(s3_key)
      digest = Digest::SHA256.hexdigest(s3_key.to_s).first(16)
      "danebo-#{digest}-#{SecureRandom.hex(4)}"
    end

    def poll_timeout_seconds
      ENV.fetch("STT_POLL_TIMEOUT_SECONDS", DEFAULT_POLL_TIMEOUT_SECONDS).to_i
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def client
      @client ||= Aws::TranscribeService::Client.new(build_aws_client_options)
    end

    def s3
      @s3 ||= S3DocumentsService.new
    end
  end
end
