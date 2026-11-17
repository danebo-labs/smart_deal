# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class Rag::GuardedPhotoVisionTest < ActiveSupport::TestCase
  setup do
    @directory = Dir.mktmpdir
    @path = File.join(@directory, "vision.json")
    @guard = Rag::GuardedPhotoVision
    ledger = Rag::LocalPassLedger
    @config = {
      ledger::GUARD_ENV => "1", ledger::ATTEMPTS_ENV => "1", ledger::CALL_CAP_ENV => "9",
      ledger::COST_CAP_ENV => "0.1", ledger::ALLOWED_CALLS_ENV => "#{@guard::OPERATION}@#{@guard::TRACKING_MODEL}",
      @guard::PATH_ENV => @path
    }
    @previous = @config.keys.index_with { |key| ENV[key] }
    @config.each { |key, value| ENV[key] = value }
    ledger.reset_local_process!
    @book = @guard.assignment(@path)
    jpeg = Vips::Image.black(@guard::WIDTH, @guard::HEIGHT).jpegsave_buffer
    @content = FieldPhotoPrompt.user_content(binary: jpeg, content_type: "image/jpeg", filename: "test.jpg", locale: "es")
  end

  teardown do
    @previous.each { |key, value| ENV[key] = value }
    Rag::LocalPassLedger.reset_local_process!
    FileUtils.remove_entry(@directory)
  end

  test "without the admitted vision grant the SDK is never called" do
    @book.snapshot
    assert_raises(Rag::LocalPassLedger::Stop) { call_vision { flunk "no provider call" } }
    assert_equal 0, @book.snapshot.fetch("attempts")
  end

  test "one attempted stream remains charged at its ceiling when the provider fails and the worker retries" do
    @book.admit_execution!(id: @guard::GRANT_ID, calls: 1, cost_usd: @guard.ceiling)
    transport = Object.new
    transport.define_singleton_method(:messages) { self }
    attempts = []
    transport.define_singleton_method(:stream) do |**request|
      attempts << request.fetch(:request_options)
      raise Anthropic::Errors::APIStatusError.new(url: URI("https://api.anthropic.com/v1/messages"),
        status: 529, body: { error: { message: "overloaded" } })
    end
    client = ClaudeChunkingClient.new(model: @guard::MODEL_ID, system: FieldPhotoPrompt::SYSTEM_BLOCKS, client: transport)
    assert_raises(ClaudeChunkingClient::ApiError) { dispatch(client) }
    assert_raises(Rag::LocalPassLedger::Stop) { dispatch(client) }
    assert_equal [ { max_retries: 0 } ], attempts
    snapshot = @book.snapshot
    assert_equal 1, snapshot.fetch("attempts")
    assert_equal @guard.ceiling, BigDecimal(snapshot.fetch("unknown_usd"))
  end

  test "the grant refuses a different model or a larger input before reserving" do
    @book.admit_execution!(id: @guard::GRANT_ID, calls: 1, cost_usd: @guard.ceiling)
    assert_raises(Rag::LocalPassLedger::Stop) { call_vision(model: "claude-opus-5-5") { flunk "no provider call" } }
    @content << { type: "text", text: "x" * @guard::TEXT_BYTES }
    assert_raises(Rag::LocalPassLedger::Stop) { call_vision { flunk "no provider call" } }
    assert_equal 0, @book.snapshot.fetch("attempts")
  end

  private

  def call_vision(model: @guard::MODEL_ID, &block)
    @guard.call(model: model, system: FieldPhotoPrompt::SYSTEM_BLOCKS, user_content: @content,
      output_tokens: @guard::OUTPUT_TOKENS, &block)
  end

  def dispatch(client)
    client.call(user_content: @content, filename: "test.jpg", route: "visual_query", max_tokens: @guard::OUTPUT_TOKENS)
  end
end
