# frozen_string_literal: true

require "test_helper"

# Fixed rule 13 lives here: one dictation is one billed call and one finding.
# The job is the only component that spends money, so these tests are written
# against the fake provider's call count rather than against the resulting rows
# — a passing state machine with a double provider call would still be a bug on
# the invoice.
class TranscriptionJobTest < ActiveJob::TestCase
  include ActionCable::TestHelper

  # Stands in for a whole adapter. `during` runs *inside* the provider call,
  # which is what lets a test reproduce an interleaving deterministically
  # instead of with threads.
  class FakeProvider
    attr_reader :calls

    def initialize(text: "La puerta de cabina roza al cerrar.", duration_seconds: 42,
                   provider: "amazon_transcribe", model: "amazon-transcribe-standard",
                   error: nil, during: nil)
      @text     = text
      @duration = duration_seconds
      @provider = provider
      @model    = model
      @error    = error
      @during   = during
      @calls    = []
    end

    def transcribe(s3_key:, language: nil, duration_hint_seconds: nil)
      @calls << { s3_key: s3_key, language: language, duration_hint_seconds: duration_hint_seconds }
      @during&.call
      raise @error if @error

      SpeechToText::Result.new(text: @text, duration_seconds: @duration,
                               provider: @provider, model: @model, raw: {})
    end
  end

  def with_provider(fake)
    original = SpeechToText::Client.method(:for)
    SpeechToText::Client.define_singleton_method(:for) { |*_args, **_kwargs| fake }
    yield
  ensure
    SpeechToText::Client.define_singleton_method(:for) { |*a, **kw| original.call(*a, **kw) }
  end

  def with_captured_log
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)
    yield
    output.string
  ensure
    Rails.logger.stop_broadcasting_to(logger)
  end

  def setup
    @account = accounts(:legacy)
    @user    = users(:one)
    @report  = certification_reports(:torre_amunategui)
  end

  # Fase 5: the provider poll runs inside the job, so it gets its own Solid
  # Queue lane rather than sharing `default` with the chat's latency-sensitive
  # jobs. The lane must exist in config/queue.yml or nothing would consume it.
  test "runs on its own transcription lane, which has a worker configured" do
    assert_equal "transcription", TranscriptionJob.new(voice_dictation_id: 1).queue_name

    workers = YAML.load_file(Rails.root.join("config/queue.yml"), aliases: true).fetch("production").fetch("workers")
    assert workers.any? { |w| Array(w["queues"]).include?("transcription") },
           "config/queue.yml has no worker for the transcription queue"
  end

  def dictation(**attrs)
    sha = SecureRandom.hex(32)
    VoiceDictation.create!(
      { account: @account, user: @user, certification_report: @report, sha256: sha,
        content_type: "audio/webm", duration_seconds: 42,
        s3_key_audio: "voice_dictations/#{@account.id}/#{sha}/audio.webm" }.merge(attrs)
    )
  end

  def perform(record)
    TranscriptionJob.perform_now(voice_dictation_id: record.id)
  end

  # --- the happy path, end to end through the job ---

  test "transcribes the claimed dictation and records text, duration and cost" do
    record = dictation
    fake   = FakeProvider.new

    with_provider(fake) { perform(record) }

    assert_equal 1, fake.calls.size
    assert_equal record.s3_key_audio, fake.calls.first[:s3_key]
    assert_equal 42, fake.calls.first[:duration_hint_seconds]

    record.reload
    assert_equal "transcribed", record.status
    assert_equal "La puerta de cabina roza al cerrar.", record.transcript_raw
    assert_equal 42, record.duration_seconds
    assert_equal "amazon_transcribe", record.provider
    assert_equal 0.0168, record.cost_estimate_usd.to_f
  end

  test "the provider is asked for the canonical language, which each adapter narrows itself" do
    fake = FakeProvider.new
    with_provider(fake) { perform(dictation) }

    assert_equal SpeechToText::DEFAULT_LANGUAGE, fake.calls.first[:language]
  end

  test "a duration the provider reports replaces the one measured in the browser" do
    record = dictation(duration_seconds: 40)
    with_provider(FakeProvider.new(duration_seconds: 63)) { perform(record) }

    assert_equal 63, record.reload.duration_seconds
  end

  test "a provider that reports no duration leaves the measured one in place" do
    record = dictation(duration_seconds: 40)
    with_provider(FakeProvider.new(duration_seconds: nil)) { perform(record) }

    record.reload
    assert_equal 40, record.duration_seconds
    assert_equal 0.016, record.cost_estimate_usd.to_f
  end

  # --- one billed call (fixed rule 13) ---

  # The duplicate-enqueue case: a Solid Queue retry, or the same job pushed
  # twice by a flaky client.
  test "a second perform of the same dictation makes no provider call" do
    record = dictation
    fake   = FakeProvider.new

    with_provider(fake) do
      perform(record)
      perform(record)
    end

    assert_equal 1, fake.calls.size, "the second perform must not reach the provider"
  end

  # The concurrent case, which is the one that actually costs money: a second
  # perform arrives while the first is still inside the provider call. Driven
  # from inside the fake so the interleaving is exact and the test deterministic
  # — no threads, no sleeps, no shared-connection problems.
  test "two performs racing on the same dictation produce exactly one billed call" do
    record = dictation
    fake   = FakeProvider.new(during: -> { perform(record) })

    with_provider(fake) { perform(record) }

    assert_equal 1, fake.calls.size,
                 "the claim must be taken before the provider call, not after"
    assert_equal "transcribed", record.reload.status
  end

  test "the losing perform says so in the log instead of failing silently" do
    record = dictation
    VoiceDictation.claim_for_transcription!(id: record.id, provider: "amazon_transcribe")
    fake = FakeProvider.new

    log = with_captured_log { with_provider(fake) { perform(record) } }

    assert_empty fake.calls
    assert_match(/already claimed/, log)
  end

  test "a dictation whose audio is gone is never sent to a provider" do
    purged = dictation(status: :confirmed, s3_key_audio: nil, audio_purged_at: Time.current)
    fake   = FakeProvider.new

    with_provider(fake) { perform(purged) }

    assert_empty fake.calls
  end

  test "a dictation that no longer exists is a no-op, not an error" do
    fake = FakeProvider.new
    with_provider(fake) do
      assert_nothing_raised { TranscriptionJob.perform_now(voice_dictation_id: -1) }
    end

    assert_empty fake.calls
  end

  # --- late results (fixed rule 13) ---

  # The scenario the rule names: the certifier confirmed and corrected the text
  # while the provider was still working.
  test "a result arriving after confirmation is discarded and the correction survives" do
    record = dictation
    confirm_meanwhile = lambda do
      VoiceDictation.where(id: record.id).update_all(
        status: "confirmed", transcript_raw: "cruda",
        transcript_edited: "corregida por el certificador", confirmed_at: Time.current
      )
    end
    fake = FakeProvider.new(text: "resultado tardío", during: confirm_meanwhile)

    log = with_captured_log { with_provider(fake) { perform(record) } }

    record.reload
    assert_equal "confirmed", record.status
    assert_equal "corregida por el certificador", record.transcript_edited
    assert_equal "cruda", record.transcript_raw
    assert_match(/late result/, log)
  end

  # Money was spent on a transcript nobody received; Fase 6 has to be able to
  # see it, so it is logged with its cost rather than dropped in silence.
  test "the discarded result is still logged with its cost" do
    record = dictation
    discard = -> { VoiceDictation.where(id: record.id).update_all(transcription_claim_id: "gone") }

    log = with_captured_log do
      with_provider(FakeProvider.new(during: discard)) { perform(record) }
    end

    payload = stt_usage_payloads(log).sole
    assert_equal "discarded_late_result", payload["outcome"]
    assert_equal 0.0168, payload["cost_estimate_usd"]
  end

  test "a late result does not broadcast, so the certifier is not shown a stale transcript" do
    record  = dictation
    discard = -> { VoiceDictation.where(id: record.id).update_all(transcription_claim_id: "gone") }
    channel = VoiceDictationBroadcaster.channel_for(@user.id)

    assert_no_broadcasts(channel) do
      with_provider(FakeProvider.new(during: discard)) { perform(record) }
    end
  end

  # --- failures ---

  test "a provider error moves the dictation to failed with a readable reason" do
    record = dictation
    error  = SpeechToText::ProviderError.new("amazon_transcribe job danebo-x failed: bad media")

    with_provider(FakeProvider.new(error: error)) { perform(record) }

    record.reload
    assert_equal "failed", record.status
    assert_match(/ProviderError: .*bad media/, record.failure_reason)
    assert_nil record.transcript_raw
  end

  test "a configuration error fails the dictation too, and is logged as unbilled" do
    record = dictation
    error  = SpeechToText::ConfigurationError.new("no API key for openai")

    log = with_captured_log do
      with_provider(FakeProvider.new(error: error)) { perform(record) }
    end

    assert_equal "failed", record.reload.status
    payload = stt_usage_payloads(log).sole
    assert_equal "failed", payload["outcome"]
    assert_equal "SpeechToText::ConfigurationError", payload["error_class"]
    assert_nil payload["cost_estimate_usd"], "nothing was sent, so nothing may be reported as spent"
  end

  # Without retry_on, a failed transcription is visible immediately and a second
  # billed call is an explicit human decision (T5) rather than a background one.
  test "the job does not retry a provider failure behind the certifier's back" do
    record = dictation
    error  = SpeechToText::ProviderError.new("boom")

    assert_no_enqueued_jobs only: TranscriptionJob do
      with_provider(FakeProvider.new(error: error)) { perform(record) }
    end
    assert_equal "failed", record.reload.status
  end

  # An unexpected error is not swallowed into `failed`: it must reach the queue
  # so it is visible as an exception, not misreported as a provider problem.
  test "an error from outside the layer is not disguised as a transcription failure" do
    record = dictation

    assert_raises RuntimeError do
      with_provider(FakeProvider.new(error: RuntimeError.new("bug"))) { perform(record) }
    end
    assert_equal "transcribing", record.reload.status
  end

  # --- delivery ---

  test "the result is broadcast only to the certifier who recorded it" do
    record       = dictation
    colleague    = User.create!(email: "tj-#{SecureRandom.hex(4)}@example.com",
                                password: "password123", account: @account)
    their_stream = VoiceDictationBroadcaster.channel_for(colleague.id)

    assert_no_broadcasts(their_stream) do
      messages = capture_broadcasts(VoiceDictationBroadcaster.channel_for(@user.id)) do
        with_provider(FakeProvider.new) { perform(record) }
      end

      assert_equal "transcribed", messages.sole["status"]
      assert_equal record.id, messages.sole["voice_dictation_id"]
      assert_equal "La puerta de cabina roza al cerrar.", messages.sole["transcript"]
    end
  end

  test "a failure is broadcast to the same private stream" do
    record = dictation

    messages = capture_broadcasts(VoiceDictationBroadcaster.channel_for(@user.id)) do
      with_provider(FakeProvider.new(error: SpeechToText::ProviderError.new("boom"))) do
        perform(record)
      end
    end

    assert_equal "failed", messages.sole["status"]
    assert_match(/boom/, messages.sole["reason"])
  end

  # --- telemetry (fixed rule 7) ---

  test "a transcription never becomes a bedrock_queries row" do
    assert_no_difference [ -> { BedrockQuery.count }, -> { CostMetric.count } ] do
      with_provider(FakeProvider.new) { perform(dictation) }
    end
  end

  test "the usage line carries everything Fase 6 needs to reconcile a dictation" do
    record = dictation

    log = with_captured_log { with_provider(FakeProvider.new) { perform(record) } }

    payload = stt_usage_payloads(log).sole
    assert_equal "stt_transcription", payload["event"]
    assert_equal record.id, payload["voice_dictation_id"]
    assert_equal @account.id, payload["account_id"]
    assert_equal @user.id, payload["user_id"]
    assert_equal "amazon_transcribe", payload["provider"]
    assert_equal "amazon-transcribe-standard", payload["model"]
    assert_equal 42, payload["duration_seconds"]
    assert_equal 0.0168, payload["cost_estimate_usd"]
    assert_equal SpeechToText::Pricing::VERSION, payload["pricing_version"]
    assert_equal "transcribed", payload["outcome"]
    assert payload["latency_ms"].is_a?(Integer)
  end

  private

  def stt_usage_payloads(log)
    log.lines.filter_map do |line|
      next unless line.include?("[STT_USAGE]")

      JSON.parse(line.split("[STT_USAGE] ", 2).last)
    end
  end
end
