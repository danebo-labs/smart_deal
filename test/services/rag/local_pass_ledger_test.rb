# frozen_string_literal: true

require "test_helper"

class Rag::LocalPassLedgerTest < ActiveSupport::TestCase
  ENV_KEYS = %w[
    RAG_LOCAL_PASS_GUARD
    RAG_LOCAL_PASS_CALL_CAP
    RAG_LOCAL_PASS_COST_CAP_USD
    AWS_MAX_ATTEMPTS
    RAG_VALIDATION_CAPTURE_RUN
    RAG_ASSIGNMENT_SPEND_PATH
  ].freeze

  setup do
    @previous = ENV_KEYS.index_with { |key| ENV[key] }
    ENV_KEYS.each { |key| ENV.delete(key) }
    Rag::LocalPassLedger.reset!
    Rag::LocalPassLedger.reset_local_process!
  end

  teardown do
    @previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    Rag::LocalPassLedger.reset!
    Rag::LocalPassLedger.reset_local_process!
    Thread.current[:rag_validation_capture] = nil
  end

  test "a recorded call cap of 152 is read and a higher one is not" do
    path = File.join(Dir.mktmpdir("ledger-cap"), "spend.json")
    File.write(path, JSON.generate("authorization" => { "call_cap" => 152 }))
    ENV["RAG_ASSIGNMENT_SPEND_PATH"] = path
    assert_equal 152, Rag::LocalPassLedger.send(:assignment_call_cap)

    File.write(path, JSON.generate("authorization" => { "call_cap" => 400 }))
    assert_equal Rag::LocalPassLedger::ASSIGNMENT_CALL_CAP, Rag::LocalPassLedger.send(:assignment_call_cap)
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

  test "a requested guard with a missing or malformed requirement does not call the provider" do
    {
      "RAG_LOCAL_PASS_CALL_CAP" => [ nil, "", "0", "abc", "1.5" ],
      "RAG_LOCAL_PASS_COST_CAP_USD" => [ nil, "", "abc", "1.2.3" ],
      "AWS_MAX_ATTEMPTS" => [ nil, "", "0", "2" ]
    }.each do |key, values|
      values.each do |value|
        isolate_guard!(key, value)
        calls = 0
        error = assert_raises(Rag::LocalPassLedger::Stop) do
          guarded_client { calls += 1 }
        end

        assert_equal 0, calls, "#{key}=#{value.inspect} reached the provider"
        assert_includes error.message, "guard_requested missing"
        assert_includes error.message, key
        assert_equal 0, Rag::LocalPassLedger.snapshot["attempts"]
        assert_not Rag::LocalPassLedger.armed?
        assert Rag::LocalPassLedger.guard_requested?
      end
    end
  end

  test "a requested guard on a non-local process does not call the provider" do
    arm!(call_cap: 4, cost_cap: "1")
    Rag::LocalPassLedger.instance_variable_set(:@local_process, false)
    calls = 0

    error = assert_raises(Rag::LocalPassLedger::Stop) do
      guarded_client { calls += 1 }
    end

    assert_equal 0, calls
    assert_includes error.message, "local_process"
    assert_equal 0, Rag::LocalPassLedger.snapshot["attempts"]
  end

  test "an unrequested guard still yields when the caps are malformed" do
    ENV["RAG_LOCAL_PASS_CALL_CAP"] = "abc"
    ENV["RAG_LOCAL_PASS_COST_CAP_USD"] = "nope"
    ENV["AWS_MAX_ATTEMPTS"] = "4"
    calls = 0

    Rag::LocalPassLedger.protect!(
      operation: "generate_text", model_id: model_id, input_tokens: 10, output_tokens: 2
    ) { calls += 1 }

    assert_equal 1, calls
    assert_not Rag::LocalPassLedger.guard_requested?
    assert_equal 0, Rag::LocalPassLedger.snapshot["attempts"]
  end

  test "a zero local estimate leaves the contractual hold" do
    arm!(call_cap: 2, cost_cap: "1")
    Rag::LocalPassLedger.protect!(
      operation: "retrieve_and_generate", model_id: model_id, input_tokens: 1_000, output_tokens: 100
    ) { "called" }

    assert_not Rag::LocalPassLedger.settle_estimate!(model_id: model_id, input_tokens: 0, output_tokens: 0)
    assert_equal "0.000000", Rag::LocalPassLedger.snapshot["committed_usd"]
    assert_operator BigDecimal(Rag::LocalPassLedger.snapshot["held_usd"]), :>, 0
  end

  test "a response without provider usage keeps the hold when citations are empty or partial" do
    ceiling = Rag::LocalPassLedger.price(
      model_id,
      ContractualLimits::QUERY[:max_input_tokens],
      ContractualLimits::QUERY[:max_output_tokens]
    )
    arm!(call_cap: 2, cost_cap: format("%.6f", ceiling + BigDecimal("0.01")))
    service = BedrockRagService.allocate
    service.instance_variable_set(:@model_ref, model_id)
    [ [], [ Struct.new(:retrieved_references).new([ Struct.new(:content).new(Struct.new(:text).new("fotocelula")) ]) ] ].each do |citations|
      Rag::LocalPassLedger.reset!
      calls = 0
      response = Struct.new(:output, :citations).new(Struct.new(:text).new("tres comprobaciones"), citations)
      runtime = Object.new
      runtime.define_singleton_method(:config) { Struct.new(:max_attempts).new(1) }
      runtime.define_singleton_method(:retrieve_and_generate) do |_params|
        calls += 1
        response
      end
      service.instance_variable_set(:@client, runtime)

      service.send(:local_retrieve_and_generate, { input: { text: "pregunta VF5+" } })
      held = BigDecimal(Rag::LocalPassLedger.snapshot["held_usd"])
      partial = BigDecimal(Rag::LocalPassLedger.snapshot["partial_estimate_usd"])

      assert_equal 1, calls
      assert_equal "0.000000", Rag::LocalPassLedger.snapshot["committed_usd"]
      assert_equal format("%.6f", ceiling), Rag::LocalPassLedger.snapshot["held_usd"]
      assert_operator partial, :>, 0
      assert_operator partial, :<, held
      assert_equal 0, Rag::LocalPassLedger.snapshot["priced"]
      error = assert_raises(Rag::LocalPassLedger::Stop) do
        service.send(:local_retrieve_and_generate, { input: { text: "segunda" } })
      end
      assert_equal "retrieve_and_generate", error.message
    end
  end

  test "provider usage on retrieve and generate replaces the hold" do
    arm!(call_cap: 2, cost_cap: "1")
    service = BedrockRagService.allocate
    usage = { input_tokens: 100, output_tokens: 20 }
    response = Struct.new(:output, :citations, :usage).new(Struct.new(:text).new("respuesta"), [], usage)
    runtime = Object.new
    runtime.define_singleton_method(:config) { Struct.new(:max_attempts).new(1) }
    runtime.define_singleton_method(:retrieve_and_generate) { |_params| response }
    service.instance_variable_set(:@client, runtime)
    service.instance_variable_set(:@model_ref, model_id)

    service.send(:local_retrieve_and_generate, { input: { text: "pregunta" } })

    assert_equal format("%.6f", Rag::LocalPassLedger.price(model_id, 100, 20)), Rag::LocalPassLedger.snapshot["committed_usd"]
    assert_equal "0.000000", Rag::LocalPassLedger.snapshot["held_usd"]
    assert_equal "0.000000", Rag::LocalPassLedger.snapshot["partial_estimate_usd"]
    assert_equal 1, Rag::LocalPassLedger.snapshot["priced"]
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

  test "an armed call settles the shared assignment file" do
    dir = Dir.mktmpdir
    path = File.join(dir, "spend.json")
    ENV["RAG_ASSIGNMENT_SPEND_PATH"] = path
    arm!(call_cap: 4, cost_cap: "1")
    response = { "usage" => { "input_tokens" => 1_000, "output_tokens" => 100 } }
    Rag::LocalPassLedger.protect!(
      operation: "generate_text", model_id: model_id, input_tokens: 1_000, output_tokens: 100
    ) { Rag::LocalPassLedger.settle_usage!(response, model_id: model_id) }

    spend = Rag::AssignmentSpend.new(path: path, call_cap: 48, cost_cap_usd: "4")
    expected = Rag::LocalPassLedger.price(model_id, 1_000, 100)
    assert_equal 1, spend.snapshot["attempts"]
    assert_equal format("%.6f", expected), spend.snapshot["committed_usd"]
    assert_equal "0.000000", spend.snapshot["held_usd"]
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  test "a provider error keeps the assignment ceiling and a full file blocks the next call" do
    dir = Dir.mktmpdir
    path = File.join(dir, "spend.json")
    ENV["RAG_ASSIGNMENT_SPEND_PATH"] = path
    arm!(call_cap: 4, cost_cap: "1")
    assert_raises(RuntimeError) do
      Rag::LocalPassLedger.protect!(
        operation: "generate_text", model_id: model_id, input_tokens: 1_000, output_tokens: 100
      ) { raise "boom" }
    end
    spend = Rag::AssignmentSpend.new(path: path, call_cap: 48, cost_cap_usd: "4")
    assert_equal 1, spend.snapshot["attempts"]
    assert_equal 0, spend.snapshot["priced"]
    assert_equal "0.000000", spend.snapshot["committed_usd"]
    assert_operator BigDecimal(spend.snapshot["unknown_usd"]), :>, 0
    assert_equal "0.000000", spend.snapshot["held_usd"]

    cap = Rag::LocalPassLedger::ASSIGNMENT_CALL_CAP
    File.write(path, JSON.generate(
      "attempts" => cap, "blocked" => 0, "priced" => cap, "seq" => cap,
      "committed" => "1.000000", "unknown" => "0.000000", "open" => {}, "entries" => []
    ))
    calls = 0
    assert_raises(Rag::LocalPassLedger::Stop) do
      Rag::LocalPassLedger.protect!(
        operation: "converse", model_id: model_id, input_tokens: 10, output_tokens: 10
      ) { calls += 1 }
    end
    assert_equal 0, calls
    assert_equal 1, Rag::LocalPassLedger.snapshot["attempts"]
  ensure
    FileUtils.remove_entry(dir) if dir
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
    Rag::LocalPassLedger.reset!
    assert Rag::LocalPassLedger.local_process?
    assert Rag::LocalPassLedger.armed?
  end

  def isolate_guard!(key, value)
    arm!(call_cap: 4, cost_cap: "1")
    value.nil? ? ENV.delete(key) : ENV[key] = value
    Rag::LocalPassLedger.reset!
  end

  def guarded_client
    client = BedrockClient.allocate
    runtime = Object.new
    runtime.define_singleton_method(:config) { Struct.new(:max_attempts).new(1) }
    runtime.define_singleton_method(:invoke_model) { |_params| yield }
    client.instance_variable_set(:@client, runtime)
    client.generate_text("no sale", max_tokens: 30, temperature: 0)
  end
end
