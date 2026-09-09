# frozen_string_literal: true

require "test_helper"

# The registry and the price table: the two pieces of the layer that decide,
# respectively, who gets called and what the call is recorded as costing.
class SpeechToTextTest < ActiveSupport::TestCase
  def teardown
    ENV.delete("STT_PROVIDER")
  end

  # --- registry ---

  test "every registered provider resolves to its adapter" do
    assert_equal %w[amazon_transcribe openai groq], SpeechToText::Client.providers
    assert_instance_of SpeechToText::AmazonTranscribeAdapter,
                       SpeechToText::Client.for("amazon_transcribe")
    assert_instance_of SpeechToText::OpenAiAdapter, SpeechToText::Client.for("openai")
    assert_instance_of SpeechToText::GroqAdapter, SpeechToText::Client.for("groq")
  end

  test "resolution runs explicit argument, then ENV, then the default" do
    assert_equal "amazon_transcribe", SpeechToText::Client.resolve_provider

    ENV["STT_PROVIDER"] = "groq"
    assert_equal "groq", SpeechToText::Client.resolve_provider
    # The per-call override is not decoration: Fase 6 runs one set of audios
    # through every adapter inside a single process.
    assert_equal "openai", SpeechToText::Client.resolve_provider("openai")
  end

  test "a blank provider name falls through instead of resolving to an empty adapter" do
    assert_equal "amazon_transcribe", SpeechToText::Client.resolve_provider("")
    assert_equal "amazon_transcribe", SpeechToText::Client.resolve_provider(nil)
  end

  test "an unregistered provider fails loudly and names the ones that exist" do
    ENV["STT_PROVIDER"] = "deepgram"

    error = assert_raises(SpeechToText::UnknownProviderError) { SpeechToText::Client.for }
    assert_match(/deepgram/, error.message)
    assert_match(/amazon_transcribe/, error.message)
  end

  test "the adapter is told which registry name it is serving, so Result costs correctly" do
    assert_equal "groq",
                 SpeechToText::Client.for("groq")
                                     .instance_variable_get(:@provider)
  end

  test "an OpenAI key does not configure Groq" do
    previous_openai = ENV["OPENAI_API_KEY"]
    previous_groq   = ENV["GROQ_API_KEY"]
    ENV["OPENAI_API_KEY"] = "sk-test"
    ENV.delete("GROQ_API_KEY")

    assert SpeechToText::Client.configured?("openai")
    assert_not SpeechToText::Client.configured?("groq")
    assert SpeechToText::Client.configured?("amazon_transcribe")
    assert_equal %w[amazon_transcribe openai], SpeechToText::Client.available_providers
  ensure
    restore_env "OPENAI_API_KEY", previous_openai
    restore_env "GROQ_API_KEY", previous_groq
  end

  def restore_env(key, value)
    if value.nil?
      ENV.delete(key)
    else
      ENV[key] = value
    end
  end

  # --- contract vocabulary ---

  test "every error the layer raises is catchable as a single class" do
    [ SpeechToText::ConfigurationError,
      SpeechToText::ProviderError,
      SpeechToText::UnknownProviderError ].each do |klass|
      assert_operator klass, :<, SpeechToText::Error
    end
  end

  test "Result is immutable, so a transcript cannot be edited in flight" do
    result = SpeechToText::Result.new(text: "texto", duration_seconds: 12,
                                      provider: "openai", model: "m", raw: {})

    assert_raises(NoMethodError) { result.text = "otro" }
    assert_equal "texto", result.text
  end

  # --- pricing ---

  test "cost is duration times the published rate" do
    assert_equal 0.024,
                 SpeechToText::Pricing.estimate_usd(provider: "amazon_transcribe",
                                                    duration_seconds: 60)
    assert_equal 0.048,
                 SpeechToText::Pricing.estimate_usd(provider: "amazon_transcribe",
                                                    duration_seconds: 120)
  end

  # The expected shape of use is short single-finding dictations, which is
  # exactly where a per-request minimum dominates the bill.
  test "Amazon's 15 second minimum is applied, so a five second dictation is not undercounted" do
    five    = SpeechToText::Pricing.estimate_usd(provider: "amazon_transcribe", duration_seconds: 5)
    fifteen = SpeechToText::Pricing.estimate_usd(provider: "amazon_transcribe", duration_seconds: 15)

    assert_equal fifteen, five
    assert_equal 0.006, five
    assert_equal 15, SpeechToText::Pricing.billed_seconds(provider: "amazon_transcribe",
                                                          duration_seconds: 5)
    assert_equal 5, SpeechToText::Pricing.billed_seconds(provider: "openai", duration_seconds: 5)
  end

  test "no minimum is invented for providers that do not charge one" do
    expected = ((5 / 60.0) * 0.003).round(6)

    assert_equal expected,
                 SpeechToText::Pricing.estimate_usd(provider: "openai", duration_seconds: 5)
  end

  # Once a provider offers more than one model, the model is what sets the rate;
  # pricing the whole provider at one number would misreport the COGS.
  test "a model rate overrides the provider rate" do
    assert_equal 0.006,
                 SpeechToText::Pricing.estimate_usd(provider: "openai", duration_seconds: 60,
                                                    model: "gpt-4o-transcribe")
    assert_equal 0.003,
                 SpeechToText::Pricing.estimate_usd(provider: "openai", duration_seconds: 60,
                                                    model: "gpt-4o-mini-transcribe")
  end

  test "an unknown model falls back to the provider rate rather than to nil" do
    assert_equal 0.003,
                 SpeechToText::Pricing.estimate_usd(provider: "openai", duration_seconds: 60,
                                                    model: "gpt-5-transcribe-unreleased")
  end

  # A wrong number is worse than an absent one here: this feeds the price
  # hypothesis per report, not a dashboard.
  test "an unpriceable call estimates nothing instead of guessing zero" do
    assert_nil SpeechToText::Pricing.estimate_usd(provider: "deepgram", duration_seconds: 60)
    assert_nil SpeechToText::Pricing.estimate_usd(provider: "openai", duration_seconds: 0)
    assert_nil SpeechToText::Pricing.estimate_usd(provider: "openai", duration_seconds: nil)
  end

  # Guards the next adapter: registering a provider without pricing it would
  # make its dictations look free in the Fase 6 COGS table.
  test "every registered provider has a rate" do
    SpeechToText::Client.providers.each do |provider|
      assert_not_nil SpeechToText::Pricing.estimate_usd(provider: provider, duration_seconds: 60),
                     "#{provider} is callable but unpriced"
    end
  end

  test "the rate table is versioned, so a recorded estimate stays interpretable" do
    assert_match(/\A\d{4}-\d{2}-\d{2}\z/, SpeechToText::Pricing::VERSION)
  end
end
