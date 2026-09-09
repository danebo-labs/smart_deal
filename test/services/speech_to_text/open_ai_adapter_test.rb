# frozen_string_literal: true

require "test_helper"

# Two things are worth pinning here. One: the bytes that go on the wire, since
# the multipart body is hand-rolled and a malformed boundary fails at the
# provider rather than in CI. Two: that GroqAdapter really is nothing but four
# constants on top of this class — that is the evidence the provider-agnostic
# contract of Fase 4 holds, and the reason Fase 6 has three providers to compare
# instead of two.
class SpeechToText::OpenAiAdapterTest < ActiveSupport::TestCase
  Response = Struct.new(:code, :body)

  class FakeHttp
    attr_reader :requests

    def initialize(code: "200", body: { text: "El foso tiene filtración." }.to_json, error: nil)
      @code     = code
      @body     = body
      @error    = error
      @requests = []
    end

    def request(request)
      @requests << request
      raise @error if @error

      Response.new(@code, @body)
    end
  end

  class FakeS3
    def initialize(audio: "OggS\x00\x02binary-audio".b)
      @audio = audio
    end

    def download(_key)
      @audio
    end
  end

  def setup
    ENV["OPENAI_API_KEY"] = "sk-test-key"
    ENV["GROQ_API_KEY"]   = "gsk-test-key"
  end

  def teardown
    ENV.delete("OPENAI_API_KEY")
    ENV.delete("GROQ_API_KEY")
  end

  def transcribe(http, s3: FakeS3.new, klass: SpeechToText::OpenAiAdapter, **kwargs)
    klass.new(client: http, s3: s3)
         .transcribe(s3_key: "voice_dictations/1/abc/audio.webm", **kwargs)
  end

  # --- happy path ---

  test "returns the text with the model that was actually billed" do
    result = transcribe(FakeHttp.new, duration_hint_seconds: 42)

    assert_equal "El foso tiene filtración.", result.text
    assert_equal "openai", result.provider
    assert_equal "gpt-4o-mini-transcribe", result.model
  end

  # This endpoint reports no audio length, so the figure measured in the browser
  # is the only one the cost estimate can use — and dropping it would silently
  # zero out the COGS of a whole provider.
  test "carries the duration measured at recording time through untouched" do
    assert_equal 42, transcribe(FakeHttp.new, duration_hint_seconds: 42).duration_seconds
    assert_nil transcribe(FakeHttp.new).duration_seconds
  end

  test "posts one multipart request to the provider endpoint with the key as a bearer token" do
    http = FakeHttp.new
    transcribe(http)

    request = http.requests.sole
    assert_equal "Bearer sk-test-key", request["Authorization"]
    assert_match(%r{\Amultipart/form-data; boundary=----DaneboSTT}, request["Content-Type"])
    assert_equal "api.openai.com", request.uri.host
    assert_equal "/v1/audio/transcriptions", request.uri.path
  end

  test "the body carries the model, the json response format and the audio bytes verbatim" do
    http = FakeHttp.new
    audio = "OggS\x00\x02binary-audio".b
    transcribe(http, s3: FakeS3.new(audio: audio))

    body = http.requests.sole.body
    assert_includes body, "name=\"model\""
    assert_includes body, "gpt-4o-mini-transcribe"
    assert_includes body, "name=\"response_format\""
    assert_includes body, "name=\"file\"; filename=\"audio.webm\""
    assert_includes body, audio, "the audio must survive the multipart assembly byte for byte"
    assert body.end_with?("--\r\n"), "an unterminated multipart body is rejected by the provider"
  end

  # The contract speaks canonical BCP-47; this endpoint rejects the region
  # subtag, so the adapter is where the narrowing has to happen.
  test "the canonical es-CL is reduced to the primary subtag" do
    http = FakeHttp.new
    transcribe(http, language: "es-CL")

    assert_includes http.requests.sole.body, "name=\"language\"\r\n\r\nes\r\n"
  end

  test "no language part is sent when no language is given" do
    http = FakeHttp.new
    transcribe(http, language: nil)

    assert_not_includes http.requests.sole.body, "name=\"language\""
  end

  # --- failure modes ---

  test "a non-200 response becomes a ProviderError quoting the status" do
    error = assert_raises SpeechToText::ProviderError do
      transcribe(FakeHttp.new(code: "429", body: "rate limit reached"))
    end

    assert_match(/429/, error.message)
    assert_match(/rate limit reached/, error.message)
  end

  test "a timeout and unparseable JSON both surface as ProviderError" do
    assert_raises SpeechToText::ProviderError do
      transcribe(FakeHttp.new(error: Net::ReadTimeout.new))
    end
    assert_raises SpeechToText::ProviderError do
      transcribe(FakeHttp.new(body: "<html>gateway timeout</html>"))
    end
  end

  test "a 200 with no text field is a provider error rather than an empty transcript" do
    assert_raises SpeechToText::ProviderError do
      transcribe(FakeHttp.new(body: { usage: { seconds: 12 } }.to_json))
    end
  end

  # Configuration errors must happen before the request, because the job's
  # telemetry distinguishes "could not have been billed" from "may have been".
  test "a missing credential or missing audio costs nothing" do
    ENV.delete("OPENAI_API_KEY")
    http = FakeHttp.new

    error = assert_raises(SpeechToText::ConfigurationError) { transcribe(http) }
    assert_match(/OPENAI_API_KEY/, error.message)

    ENV["OPENAI_API_KEY"] = "sk-test-key"
    assert_raises SpeechToText::ConfigurationError do
      SpeechToText::OpenAiAdapter.new(client: http, s3: FakeS3.new).transcribe(s3_key: "")
    end
    assert_raises SpeechToText::ConfigurationError do
      transcribe(http, s3: FakeS3.new(audio: nil))
    end

    assert_empty http.requests
  end

  test "audio over the upload limit is refused locally instead of by a 413" do
    oversized = "x" * (SpeechToText::OpenAiAdapter::MAX_UPLOAD_BYTES + 1)
    http = FakeHttp.new

    error = assert_raises SpeechToText::ProviderError do
      transcribe(http, s3: FakeS3.new(audio: oversized))
    end

    assert_match(/25 MB/, error.message)
    assert_empty http.requests
  end

  # --- the contract, proven by the third provider ---

  test "GroqAdapter reuses the whole request path and only changes vendor identity" do
    http   = FakeHttp.new
    result = transcribe(http, klass: SpeechToText::GroqAdapter, duration_hint_seconds: 42)

    assert_equal "groq", result.provider
    assert_equal "whisper-large-v3-turbo", result.model
    assert_equal "El foso tiene filtración.", result.text

    request = http.requests.sole
    assert_equal "api.groq.com", request.uri.host
    assert_equal "Bearer gsk-test-key", request["Authorization"]
    assert_includes request.body, "whisper-large-v3-turbo"
  end

  test "each OpenAI-compatible provider reads its own credential" do
    ENV.delete("GROQ_API_KEY")

    error = assert_raises SpeechToText::ConfigurationError do
      transcribe(FakeHttp.new, klass: SpeechToText::GroqAdapter)
    end
    assert_match(/GROQ_API_KEY/, error.message)
  end

  test "the model is overridable per call, which is what the Fase 6 benchmark needs" do
    http = FakeHttp.new
    SpeechToText::OpenAiAdapter.new(client: http, s3: FakeS3.new, model: "gpt-4o-transcribe")
                               .transcribe(s3_key: "voice_dictations/1/abc/audio.webm")

    assert_includes http.requests.sole.body, "gpt-4o-transcribe"
  end

  test "the adapter writes nothing to the database" do
    assert_no_difference [ -> { VoiceDictation.count }, -> { BedrockQuery.count } ] do
      transcribe(FakeHttp.new)
    end
  end
end
