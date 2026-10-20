# frozen_string_literal: true

require "test_helper"

class Rag::LocalPassLedgerTest < ActiveSupport::TestCase
  ENV_KEYS = %w[
    RAG_LOCAL_PASS_GUARD
    RAG_LOCAL_PASS_CALL_CAP
    RAG_LOCAL_PASS_COST_CAP_USD
    AWS_MAX_ATTEMPTS
    RAG_VALIDATION_CAPTURE_RUN
  ].freeze

  setup do
    @previous = ENV_KEYS.index_with { |key| ENV[key] }
    Rag::LocalPassLedger.reset!
    Rag::LocalPassLedger.reset_local_process!
  end

  teardown do
    @previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    Rag::LocalPassLedger.reset!
    Rag::LocalPassLedger.reset_local_process!
    Thread.current[:rag_validation_capture] = nil
  end

  test "a disarmed ledger does not count or block" do
    calls = 0
    Rag::LocalPassLedger.protect!(
      operation: "generate_text", model_id: model_id, input_tokens: 10_000, output_tokens: 3_000
    ) { calls += 1 }

    assert_equal 1, calls
    assert_equal 0, Rag::LocalPassLedger.snapshot["attempts"]
    assert_not Rag::LocalPassLedger.armed?
  end

  test "the ceiling uses the bedrock query price and refuses before the call" do
    arm!(call_cap: 2, cost_cap: "0.001")
    expected = BedrockQuery.new(model_id: model_id, input_tokens: 1_000, output_tokens: 100).cost
    assert_equal BigDecimal(expected.to_s), Rag::LocalPassLedger.price(model_id, 1_000, 100)

    calls = 0
    error = assert_raises(Rag::LocalPassLedger::Stop) do
      Rag::LocalPassLedger.protect!(
        operation: "generate_text", model_id: model_id, input_tokens: 100_000, output_tokens: 3_000
      ) { calls += 1 }
    end

    assert_equal "generate_text", error.message
    assert_equal 0, calls
    assert_equal 0, Rag::LocalPassLedger.snapshot["attempts"]
    assert_equal 1, Rag::LocalPassLedger.snapshot["blocked"]
  end

  test "provider usage replaces the ceiling and another thread does not settle it" do
    arm!(call_cap: 2, cost_cap: "1")
    response = { "usage" => { "input_tokens" => 1_000, "output_tokens" => 100 } }
    Rag::LocalPassLedger.protect!(
      operation: "converse", model_id: model_id, input_tokens: 50_000, output_tokens: 512
    ) do
      other = Thread.new { Rag::LocalPassLedger.settle_usage!(response, model_id: model_id) }
      other.join
      Rag::LocalPassLedger.settle_usage!(response, model_id: model_id)
    end

    expected = BedrockQuery.new(model_id: model_id, input_tokens: 1_000, output_tokens: 100).cost
    assert_equal format("%.6f", expected), Rag::LocalPassLedger.snapshot["committed_usd"]
    assert_equal "0.000000", Rag::LocalPassLedger.snapshot["held_usd"]
    assert_equal 1, Rag::LocalPassLedger.snapshot["priced"]
  end

  test "the second generate_text does not reach the client" do
    arm!(call_cap: 1, cost_cap: "1")
    client = BedrockClient.new
    calls = 0
    runtime = Object.new
    runtime.define_singleton_method(:config) { Struct.new(:max_attempts).new(1) }
    runtime.define_singleton_method(:invoke_model) do |_params|
      calls += 1
      body = { "content" => [ { "text" => "ok" } ], "usage" => { "input_tokens" => 20, "output_tokens" => 2 } }
      Struct.new(:body).new(StringIO.new(body.to_json))
    end
    client.instance_variable_set(:@client, runtime)

    assert_equal "ok", client.generate_text("primera", max_tokens: 30, temperature: 0)
    assert_equal 1, calls

    assert_raises(Rag::LocalPassLedger::Stop) do
      client.generate_text("segunda", max_tokens: 30, temperature: 0)
    end
    assert_equal 1, calls
    assert_equal 1, Rag::LocalPassLedger.snapshot["attempts"]
    assert_equal 1, Rag::LocalPassLedger.snapshot["blocked"]
  end

  test "a client that would retry inside the sdk is refused before invoke" do
    arm!(call_cap: 4, cost_cap: "1")
    client = BedrockClient.new
    calls = 0
    runtime = Object.new
    runtime.define_singleton_method(:config) { Struct.new(:max_attempts).new(3) }
    runtime.define_singleton_method(:invoke_model) { |_params| calls += 1 }
    client.instance_variable_set(:@client, runtime)

    assert_raises(Rag::LocalPassLedger::Stop) do
      client.generate_text("no sale", max_tokens: 30, temperature: 0)
    end
    assert_equal 0, calls
    assert_equal 0, Rag::LocalPassLedger.snapshot["attempts"]
  end

  private

  def model_id
    "global.anthropic.claude-haiku-4-5-20251001-v1:0"
  end

  def arm!(call_cap:, cost_cap:)
    ENV["RAG_LOCAL_PASS_GUARD"] = "1"
    ENV["RAG_LOCAL_PASS_CALL_CAP"] = call_cap.to_s
    ENV["RAG_LOCAL_PASS_COST_CAP_USD"] = cost_cap
    ENV["AWS_MAX_ATTEMPTS"] = "1"
    assert Rag::LocalPassLedger.local_process?
    assert Rag::LocalPassLedger.armed?
  end
end
