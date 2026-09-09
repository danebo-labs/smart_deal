# frozen_string_literal: true

require "test_helper"

# The adapter is the only place in the module that knows Transcribe exists, so
# these tests pin the two things a provider swap must not silently change: the
# shape of the request (bucket, media URI, output prefix, language code) and the
# mapping from every provider outcome to the module's own error hierarchy.
#
# Fakes are injected rather than stubbed over the SDK — the repo does not use
# WebMock, and a fake lets the test read the exact parameters that would have
# gone on the wire.
class SpeechToText::AmazonTranscribeAdapterTest < ActiveSupport::TestCase
  Job     = Struct.new(:transcription_job_status, :failure_reason)
  JobView = Struct.new(:transcription_job)

  class FakeTranscribe
    attr_reader :started, :polls

    # @param statuses [Array<String>] consumed one per poll; the last one
    #   repeats, so ["IN_PROGRESS", "COMPLETED"] is a job that needed two polls
    def initialize(statuses: [ "COMPLETED" ], failure_reason: nil, error: nil)
      @statuses = statuses.dup
      @failure_reason = failure_reason
      @error   = error
      @started = []
      @polls   = 0
    end

    def start_transcription_job(**params)
      raise @error if @error

      @started << params
      nil
    end

    def get_transcription_job(transcription_job_name:)
      @polls += 1
      status = @statuses.size > 1 ? @statuses.shift : @statuses.first
      JobView.new(Job.new(status, @failure_reason))
    end
  end

  class FakeS3
    attr_reader :bucket_name, :downloaded

    def initialize(payload: nil, bucket_name: "danebo-test-bucket")
      @payload     = payload
      @bucket_name = bucket_name
      @downloaded  = []
    end

    def download(key)
      @downloaded << key
      @payload
    end
  end

  # The documented batch output: one transcripts entry plus per-word items
  # carrying end_time, which is where the billed length comes from.
  def payload(text: "La puerta de cabina roza al cerrar.", last_end_time: "12.5")
    {
      "jobName" => "danebo-x",
      "results" => {
        "transcripts" => [ { "transcript" => text } ],
        "items" => [
          { "start_time" => "0.0", "end_time" => "0.7", "type" => "pronunciation" },
          { "type" => "punctuation" },
          { "start_time" => "11.9", "end_time" => last_end_time, "type" => "pronunciation" }
        ]
      },
      "status" => "COMPLETED"
    }.to_json
  end

  def adapter(client:, s3:)
    SpeechToText::AmazonTranscribeAdapter.new(client: client, s3: s3, sleeper: ->(_s) { })
  end

  def transcribe(client:, s3:, **kwargs)
    adapter(client: client, s3: s3).transcribe(s3_key: "voice_dictations/1/abc/audio.webm", **kwargs)
  end

  # --- happy path ---

  test "returns the transcript, the billed duration and the provider identity" do
    client = FakeTranscribe.new
    result = transcribe(client: client, s3: FakeS3.new(payload: payload))

    assert_equal "La puerta de cabina roza al cerrar.", result.text
    # Rounded up, because a partial second is a billed second.
    assert_equal 13, result.duration_seconds
    assert_equal "amazon_transcribe", result.provider
    assert_equal SpeechToText::AmazonTranscribeAdapter::MODEL_NAME, result.model
  end

  test "sends the audio from our own bucket and writes the result beside it" do
    client = FakeTranscribe.new
    s3     = FakeS3.new(payload: payload)
    transcribe(client: client, s3: s3)

    params = client.started.sole
    assert_equal "s3://danebo-test-bucket/voice_dictations/1/abc/audio.webm",
                 params.dig(:media, :media_file_uri)
    assert_equal "danebo-test-bucket", params[:output_bucket_name]
    assert params[:output_key].start_with?("voice_dictations/transcripts/"),
           "the transcript must land under the module's own prefix"
    assert_equal [ params[:output_key] ], s3.downloaded
  end

  # A dictation reaching the Knowledge Base would leak one customer's field
  # notes into retrieval for everyone (fixed rule 7 / bulk_chunks is
  # ingestion-only).
  test "nothing it writes goes under the prefix the Knowledge Base ingests" do
    client = FakeTranscribe.new
    transcribe(client: client, s3: FakeS3.new(payload: payload))

    assert_not_includes client.started.sole[:output_key], "bulk_chunks"
  end

  test "the job name is unique per attempt and uses only the charset AWS accepts" do
    client = FakeTranscribe.new
    s3     = FakeS3.new(payload: payload)
    2.times { transcribe(client: client, s3: s3) }

    names = client.started.pluck(:transcription_job_name)
    assert_equal 2, names.uniq.size,
                 "a second legitimate attempt must not collide with the first job's name"
    names.each { |name| assert_match(/\A[0-9a-zA-Z._-]+\z/, name) }
  end

  # --- language narrowing (correction to the plan: Transcribe has no es-CL) ---

  test "the canonical es-CL is narrowed to es-US, the only Spanish variant with custom language models" do
    client = FakeTranscribe.new
    transcribe(client: client, s3: FakeS3.new(payload: payload), language: "es-CL")

    assert_equal "es-US", client.started.sole[:language_code]
  end

  test "a Spanish variant Transcribe supports is passed through, so the Fase 6 benchmark can ask for it" do
    SpeechToText::AmazonTranscribeAdapter::SUPPORTED_SPANISH.each do |code|
      client = FakeTranscribe.new
      transcribe(client: client, s3: FakeS3.new(payload: payload), language: code)

      assert_equal code, client.started.sole[:language_code]
    end
  end

  test "an explicit supported variant wins over the ops-level override" do
    ENV["STT_AMAZON_LANGUAGE_CODE"] = "es-MX"
    client = FakeTranscribe.new
    transcribe(client: client, s3: FakeS3.new(payload: payload), language: "es-ES")

    assert_equal "es-ES", client.started.sole[:language_code]
  ensure
    ENV.delete("STT_AMAZON_LANGUAGE_CODE")
  end

  test "the override decides for any other Spanish tag" do
    ENV["STT_AMAZON_LANGUAGE_CODE"] = "es-MX"
    client = FakeTranscribe.new
    transcribe(client: client, s3: FakeS3.new(payload: payload), language: "es-CL")

    assert_equal "es-MX", client.started.sole[:language_code]
  ensure
    ENV.delete("STT_AMAZON_LANGUAGE_CODE")
  end

  test "a non-Spanish tag is left untouched" do
    client = FakeTranscribe.new
    transcribe(client: client, s3: FakeS3.new(payload: payload), language: "en-US")

    assert_equal "en-US", client.started.sole[:language_code]
  end

  # --- polling ---

  test "polls until the job completes" do
    client = FakeTranscribe.new(statuses: [ "QUEUED", "IN_PROGRESS", "COMPLETED" ])
    slept  = []
    result = SpeechToText::AmazonTranscribeAdapter
               .new(client: client, s3: FakeS3.new(payload: payload), sleeper: ->(s) { slept << s })
               .transcribe(s3_key: "voice_dictations/1/abc/audio.webm")

    assert_equal 3, client.polls
    assert_equal [ 3, 3 ], slept, "it must wait between polls rather than spin"
    assert_equal "La puerta de cabina roza al cerrar.", result.text
  end

  # Better a dictation in `failed`, which the certifier can retry, than a worker
  # thread held forever.
  test "exhausting the poll budget fails instead of blocking the worker" do
    ENV["STT_POLL_TIMEOUT_SECONDS"] = "0"
    client = FakeTranscribe.new(statuses: [ "IN_PROGRESS" ])

    error = assert_raises SpeechToText::ProviderError do
      transcribe(client: client, s3: FakeS3.new(payload: payload))
    end
    assert_match(/still IN_PROGRESS/, error.message)
  ensure
    ENV.delete("STT_POLL_TIMEOUT_SECONDS")
  end

  # --- every failure mode lands in the module's own hierarchy ---

  test "a job Transcribe reports as FAILED carries its reason forward" do
    client = FakeTranscribe.new(statuses: [ "FAILED" ], failure_reason: "Unsupported media format")

    error = assert_raises SpeechToText::ProviderError do
      transcribe(client: client, s3: FakeS3.new(payload: payload))
    end
    assert_match(/Unsupported media format/, error.message)
  end

  test "an SDK error becomes a ProviderError, never an Aws exception in the caller" do
    client = FakeTranscribe.new(
      error: Aws::TranscribeService::Errors::ServiceError.new(nil, "quota exceeded")
    )

    error = assert_raises SpeechToText::ProviderError do
      transcribe(client: client, s3: FakeS3.new(payload: payload))
    end
    assert_match(/quota exceeded/, error.message)
  end

  # ConfigurationError and not ProviderError: nothing was sent, so nothing was
  # billed, and the job's telemetry says so.
  test "a missing audio key or bucket is a configuration error, before any call" do
    client = FakeTranscribe.new

    assert_raises SpeechToText::ConfigurationError do
      adapter(client: client, s3: FakeS3.new(payload: payload)).transcribe(s3_key: "")
    end
    assert_raises SpeechToText::ConfigurationError do
      transcribe(client: client, s3: FakeS3.new(payload: payload, bucket_name: nil))
    end
    assert_empty client.started, "a configuration error must cost nothing"
  end

  test "a result that is missing, unparseable, or has no transcript block is a provider error" do
    [ nil, "", "not json at all", { "results" => { "items" => [] } }.to_json ].each do |body|
      assert_raises SpeechToText::ProviderError, "body #{body.inspect} must not pass" do
        transcribe(client: FakeTranscribe.new, s3: FakeS3.new(payload: body))
      end
    end
  end

  test "a transcript with no timed items falls back to the duration measured at recording time" do
    body   = { "results" => { "transcripts" => [ { "transcript" => "corto" } ], "items" => [] } }.to_json
    result = transcribe(client: FakeTranscribe.new, s3: FakeS3.new(payload: body),
                        duration_hint_seconds: 9)

    assert_equal 9, result.duration_seconds
  end

  # The contract's central constraint: state, cost and delivery belong to the
  # job, so an adapter that wrote a row would break the swap-a-provider promise.
  test "the adapter writes nothing to the database" do
    assert_no_difference [ -> { VoiceDictation.count }, -> { BedrockQuery.count } ] do
      transcribe(client: FakeTranscribe.new, s3: FakeS3.new(payload: payload))
    end
  end
end
