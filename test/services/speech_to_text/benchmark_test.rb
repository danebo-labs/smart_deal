# frozen_string_literal: true

require "test_helper"

class SpeechToText::BenchmarkTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class FakeAdapter
    attr_reader :calls

    def initialize(text:, provider:, model: "fake-model")
      @text     = text
      @provider = provider
      @model    = model
      @calls    = []
    end

    def transcribe(**kwargs)
      @calls << kwargs
      SpeechToText::Result.new(
        text: @text,
        duration_seconds: kwargs[:duration_hint_seconds],
        provider: @provider,
        model: @model,
        raw: {}
      )
    end
  end

  class FakeS3
    attr_reader :uploads, :deleted

    def initialize
      @uploads = []
      @deleted = []
    end

    def upload_binary(key, _binary, _content_type)
      @uploads << key
      key
    end

    def delete_prefix(prefix)
      @deleted << prefix
      1
    end
  end

  setup do
    @tmp = Pathname(Dir.mktmpdir("stt-benchmark"))
    @fixture = @tmp.join("corpus.yml")
    File.write(@fixture, <<~YAML)
      version: test
      voice: Paulina
      phrases:
        - id: p01
          text: roza en el marco
        - id: p02
          text: código de falla A32.4
      clips:
        - id: silence_2s
          kind: silence
          label: Silencio
          duration_seconds: 2
        - id: noise_2s
          kind: noise
          label: Ruido
          duration_seconds: 2
    YAML
  end

  teardown do
    FileUtils.remove_entry(@tmp) if @tmp&.exist?
  end

  test "the same clip is sent to every configured adapter and does not create a dictation" do
    amazon = FakeAdapter.new(text: "amazon", provider: "amazon_transcribe")
    openai = FakeAdapter.new(text: "openai", provider: "openai")
    groq   = FakeAdapter.new(text: "groq", provider: "groq")
    s3     = FakeS3.new

    report = run_benchmark(
      adapters: { "amazon_transcribe" => amazon, "openai" => openai, "groq" => groq },
      s3: s3
    )

    assert_equal 2, s3.uploads.size, "each clip is uploaded once, not once per provider"
    assert_equal 6, amazon.calls.size, "two clips × three Transcribe language variants"
    assert_equal 2, openai.calls.size
    assert_equal 2, groq.calls.size
    assert_equal amazon.calls.pluck(:s3_key).uniq.sort,
                 openai.calls.pluck(:s3_key).uniq.sort
    assert_equal amazon.calls.pluck(:s3_key).uniq.sort,
                 groq.calls.pluck(:s3_key).uniq.sort

    assert_includes amazon.calls.pluck(:language), "es-US"
    assert_includes amazon.calls.pluck(:language), "es-ES"
    assert_includes amazon.calls.pluck(:language), "es-MX"

    assert_no_difference -> { VoiceDictation.count } do
      run_benchmark(
        adapters: { "openai" => FakeAdapter.new(text: "x", provider: "openai") },
        s3: FakeS3.new,
        providers: [ "openai" ]
      )
    end
    assert_no_enqueued_jobs only: TranscriptionJob
    assert_empty s3.deleted, "S3 cleanup is opt-in so a second run cannot 404 a live Transcribe job"
  end

  test "S3 prefix is deleted only when STT_BENCHMARK_CLEANUP_S3 is set" do
    s3 = FakeS3.new
    run_benchmark(
      adapters: { "openai" => FakeAdapter.new(text: "x", provider: "openai") },
      s3: s3,
      providers: [ "openai" ],
      env: { "STT_BENCHMARK_CLEANUP_S3" => "1", "STT_BENCHMARK_RUN_ID" => "cleanup" }
    )

    assert_equal [ "voice_dictations/benchmark/cleanup/" ], s3.deleted
  end

  test "an OpenAI key alone does not open a Groq lane" do
    previous_openai = ENV["OPENAI_API_KEY"]
    previous_groq   = ENV["GROQ_API_KEY"]
    ENV["OPENAI_API_KEY"] = "sk-test"
    ENV.delete("GROQ_API_KEY")

    openai = FakeAdapter.new(text: "openai", provider: "openai")
    report = run_benchmark(
      adapters: { "openai" => openai },
      s3: FakeS3.new,
      providers: %w[openai groq]
    )

    assert_equal [ "openai" ], report.fetch("lanes").pluck("provider").uniq
    assert_empty report.fetch("results").select { |row| row["provider"] == "groq" }
  ensure
    if previous_openai.nil?
      ENV.delete("OPENAI_API_KEY")
    else
      ENV["OPENAI_API_KEY"] = previous_openai
    end
    if previous_groq.nil?
      ENV.delete("GROQ_API_KEY")
    else
      ENV["GROQ_API_KEY"] = previous_groq
    end
  end

  test "Amazon's 15 second minimum is what the cost-per-minute column uses" do
    amazon = FakeAdapter.new(text: "a", provider: "amazon_transcribe", model: "amazon-transcribe-standard")
    report = run_benchmark(
      adapters: { "amazon_transcribe" => amazon },
      s3: FakeS3.new,
      providers: [ "amazon_transcribe" ],
      env: { "STT_BENCHMARK_SKIP_TRANSCRIBE_VARIANTS" => "1", "STT_BENCHMARK_RUN_ID" => "t" }
    )

    silence = report.fetch("results").find { |row| row["clip_id"] == "silence_2s" }
    assert_equal 2, silence["duration_seconds"]
    assert_equal 15, silence["billed_seconds"]
    assert_equal 0.006, silence["cost_usd"]
    assert_equal 0.024, report.fetch("lanes").sole["cost_per_billed_minute_usd"]
  end

  test "the markdown table has side-by-side transcripts and an empty founder scorecard" do
    report = run_benchmark(
      adapters: {
        "openai" => FakeAdapter.new(text: "texto openai", provider: "openai"),
        "groq" => FakeAdapter.new(text: "texto groq", provider: "groq")
      },
      s3: FakeS3.new,
      providers: %w[openai groq]
    )

    markdown = File.read(report.fetch("output_md"))
    assert_includes markdown, "texto openai"
    assert_includes markdown, "texto groq"
    assert_includes markdown, "p01: roza en el marco"
    assert_includes markdown, "p02: código de falla A32.4"
    assert_includes markdown, "Error counts on the 20 technical phrases are for the founder"
    # Which default and whether the jargon hint was on both change what the
    # numbers mean, so a saved table has to carry them or it is unreadable later.
    assert_includes markdown, "Default `STT_PROVIDER` is `groq`"
    assert_includes markdown, "Jargon hint: on"
    assert_includes markdown, "Silencio"
    assert report.fetch("total_cost_under_2_usd")
    assert report.fetch("error_count_deferred_to_founder")
  end

  test "a provider error is recorded on that lane and does not abort the run" do
    failing = Object.new
    def failing.transcribe(**)
      raise SpeechToText::ProviderError, "boom"
    end
    ok = FakeAdapter.new(text: "ok", provider: "openai")

    report = run_benchmark(
      adapters: { "groq" => failing, "openai" => ok },
      s3: FakeS3.new,
      providers: %w[groq openai]
    )

    groq = report.fetch("results").select { |row| row["provider"] == "groq" }
    assert groq.all? { |row| row["error"].include?("boom") }
    assert report.fetch("results").select { |row| row["provider"] == "openai" }.all? { |row| row["error"].nil? }
  end

  test "silence and noise clips are written as WAV without calling say" do
    clips = SpeechToText::Benchmark.new(
      dir: @tmp.join("run"),
      fixture_path: @fixture
    ).prepare_audio!

    assert_equal %w[silence_2s noise_2s], clips.pluck("id")
    clips.each do |clip|
      bytes = File.binread(clip["path"])
      assert bytes.start_with?("RIFF"), "#{clip['id']} must be a WAV"
      assert_equal 2, clip["duration_seconds"]
    end
  end

  private

  def run_benchmark(adapters:, s3:, providers: nil, env: {})
    SpeechToText::Benchmark.run!(
      dir: @tmp.join("run-#{SecureRandom.hex(4)}"),
      fixture_path: @fixture,
      s3: s3,
      adapters: adapters,
      providers: providers,
      env: env
    )
  end
end
