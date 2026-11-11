# frozen_string_literal: true

require "test_helper"

class Rag::Haiku55DirectCutTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "the interpreter sends haiku 5.5 with effort high and a forced tool" do
    params = {
      model_id: Rag::TurnInterpreter::MODEL_ID,
      system: [ { text: "prompt" } ],
      messages: [ { role: "user", content: [ { text: "turno" } ] } ],
      inference_config: { temperature: 0, max_tokens: 512 },
      tool_config: {
        tools: [ { tool_spec: { name: "turn_perception", description: "Classify", input_schema: { json: { type: "object" } } } } ],
        tool_choice: { tool: { name: "turn_perception" } }
      }
    }
    body = Rag::InterpreterAnthropicClient.body_for(params)

    assert_equal "claude-haiku-5-5", body["model"]
    assert_equal 512, body["max_tokens"]
    assert_equal({ "effort" => "high" }, body["output_config"])
    assert_equal({ "type" => "tool", "name" => "turn_perception" }, body["tool_choice"])
    assert_not body.key?("temperature")
    assert_not body.key?("thinking")
    assert_not_includes body.to_json, "sk-ant-"
  end

  test "a native tool use does not instantiate bedrock" do
    original = BedrockClient.method(:new)
    BedrockClient.define_singleton_method(:new) { |*| raise "bedrock instantiated" }
    sent = nil
    tool = valid_tool
    messages = Object.new
    messages.define_singleton_method(:create) do |**body|
      sent = body
      Anthropic::Models::Message.new(
        id: "msg-1", type: :message, role: :assistant, model: "claude-haiku-5-5",
        stop_reason: :tool_use, stop_sequence: nil,
        content: [ { type: :tool_use, id: "tool-1", name: "turn_perception", input: tool } ],
        usage: { input_tokens: 11, output_tokens: 7 }
      )
    end
    client = Rag::InterpreterAnthropicClient.new(client: Object.new.tap { |api|
      api.define_singleton_method(:messages) { messages }
    })
    result = nil
    events = Rag::ValidationCapture.capture do
      result = interpret("la puerta no cierra", client: client)
    end
    request = events.find { |event| event["kind"] == "interpreter_request" }

    assert_equal "report", result.perception&.move, [ result.status, result.error_class, result.error_reason, result.stage ].inspect
    assert_equal false, result.fallback
    assert_equal "claude-haiku-5-5", sent[:model]
    assert_equal({ effort: "high" }, sent[:output_config])
    assert_equal 512, sent[:max_tokens]
    assert_nil sent[:temperature]
    assert_nil sent[:thinking]
    assert_equal "high", request["effort"]
    assert_equal "absent", request["temperature"]
    assert_equal "absent", request["thinking"]
  ensure
    BedrockClient.define_singleton_method(:new) { |*args, **kwargs, &block| original.call(*args, **kwargs, &block) } if original
  end

  test "the referral note starts at turn 4 and keeps discarded conditions out of what is missing" do
    assert_nil Rag::CompanionDirectAnswer.send(:referral_note, 3)
    note = Rag::CompanionDirectAnswer.send(:referral_note, 4)

    assert_includes note, "resumen para derivar"
    assert_includes note, "Lo que falta no incluye un componente, ajuste o modo cuya condición o ejemplo documentado depende de algo que el técnico ya descartó."
  end

  test "a truncated interpreter response and a missing tool fail closed" do
    truncated = interpret("la puerta no cierra", client: response_client(stop_reason: "max_tokens", tool: valid_tool))
    missing = interpret("la puerta no cierra", client: response_client(stop_reason: "end_turn", tool: nil))

    assert_equal "service_failure", truncated.status, [ truncated.error_class, truncated.error_reason, truncated.stage ].inspect
    assert_equal "max_tokens", truncated.error_reason
    assert_equal "service_failure", missing.status, [ missing.error_class, missing.error_reason, missing.stage ].inspect
    assert_equal "tool_use_missing", missing.error_reason
  end

  test "anthropic failures classify and a service failure uses the interpreter message" do
    rows = {
      "timeout" => named_error("Anthropic::Errors::APITimeoutError"),
      "transport" => named_error("Anthropic::Errors::APIConnectionError"),
      "service" => named_error("Anthropic::Errors::APIStatusError", status: 529),
      "validation" => named_error("Anthropic::Errors::BadRequestError"),
      "throttle" => named_error("Anthropic::Errors::RateLimitError", status: 429)
    }
    interpreter = Rag::TurnInterpreter.allocate
    rows.each do |kind, error|
      assert_equal kind, interpreter.send(:converse_failure_kind, error), kind
    end

    assert_equal "service_failure", I18n.t("rag.interpreter_service_failure", locale: :es).present? && "service_failure"
    assert_includes I18n.t("rag.interpreter_service_failure", locale: :es), "servicio de interpretación"
  end

  test "haiku 4.5 direct is rejected and an unpinned close says the service is unavailable" do
    previous = ENV["COMPANION_DIRECT_MODEL_ID"]
    ENV.delete("COMPANION_DIRECT_MODEL_ID")
    assert_equal "claude-haiku-5-5", Rag::CompanionDirectAnswer.configured_model_id
    assert_equal 4_000, Rag::CompanionDirectAnswer.generation_max_tokens
    assert_equal "adaptive", Rag::CompanionDirectAnswer.thinking_mode
    assert_nil Rag::CompanionDirectAnswer.effort
    [
      "claude-haiku-4-5-20251001",
      "global.anthropic.claude-haiku-4-5-20251001-v1:0",
      "anthropic.claude-haiku-5-5"
    ].each do |model_id|
      ENV["COMPANION_DIRECT_MODEL_ID"] = model_id
      assert_raises(BedrockRagService::BedrockServiceError) { Rag::CompanionDirectAnswer.configured_model_id }
    end

    service = BedrockRagService.allocate
    result = service.send(:identity_closed_result,
      status: :unavailable, reason: :retrieval_timeout, question: "¿qué reviso?", response_locale: :es
    )
    assert_equal :unavailable, result[:route_outcome]
    assert_equal I18n.t("rag.service_unavailable", locale: :es), result[:answer]
    assert_not_includes result[:answer], "no aparece"
    %i[plan field_records episode identity system_role provider_blocked].each do |reason|
      closed = service.send(:identity_closed_result,
        status: :unavailable, reason: reason, question: "¿qué reviso?", response_locale: :es
      )
      assert_equal I18n.t("rag.service_unavailable", locale: :es), closed[:answer], reason.to_s
    end
  ensure
    previous.nil? ? ENV.delete("COMPANION_DIRECT_MODEL_ID") : ENV["COMPANION_DIRECT_MODEL_ID"] = previous
  end

  test "blocked bedrock inference stops generation and leaves retrieve and rerank" do
    previous = ENV["BEDROCK_INFERENCE"]
    ENV["BEDROCK_INFERENCE"] = "blocked"
    client = BedrockClient.new
    assert_raises(Rag::InferencePolicy::BedrockInferenceBlocked) { client.generate_text("hola") }
    assert_raises(Rag::InferencePolicy::BedrockInferenceBlocked) { client.converse(model_id: "x", messages: []) }
    assert_raises(Rag::InferencePolicy::BedrockInferenceBlocked) { client.converse_message(model_id: "x", messages: []) }
    assert_raises(Rag::InferencePolicy::BedrockInferenceBlocked) { AiProvider.new.query("hola") }
    assert_raises(Rag::InferencePolicy::BedrockInferenceBlocked) { AiProvider.new.converse(model_id: "x", messages: []) }

    service = BedrockRagService.allocate
    service.instance_variable_set(:@client, Object.new)
    service.instance_variable_set(:@model_ref, "m")
    assert_raises(Rag::InferencePolicy::BedrockInferenceBlocked) { service.send(:local_retrieve_and_generate, {}) }

    retrieved = false
    retriever = Object.new
    retriever.define_singleton_method(:retrieve) { |_params| retrieved = true; { "ok" => true } }
    service.instance_variable_set(:@client, retriever)
    assert_equal({ "ok" => true }, service.send(:retrieve_with_retry, {}))
    assert retrieved

    reranked = false
    ranker = Object.new
    ranker.define_singleton_method(:rerank) do |_payload|
      reranked = true
      Struct.new(:results).new([ Struct.new(:index, :relevance_score).new(0, 0.9) ])
    end
    ordered = Rag::CompanionCandidateOrder.call(
      [ { content: "uno" }, { content: "dos" } ],
      question: "pregunta", client: ranker, region: "us-east-1"
    )
    assert reranked
    assert_equal 2, ordered.size
  ensure
    previous.nil? ? ENV.delete("BEDROCK_INFERENCE") : ENV["BEDROCK_INFERENCE"] = previous
  end

  test "production boot requires the blocked direct cut" do
    assert_nil Rag::DirectInferenceBoot.check!({})
    assert_raises(RuntimeError) { Rag::DirectInferenceBoot.check!("BEDROCK_INFERENCE" => "enabled") }
    assert_raises(RuntimeError) { Rag::DirectInferenceBoot.check!("RAG_COMPANION_GENERATION" => "plan") }
    assert_nil Rag::DirectInferenceBoot.check!("BEDROCK_INFERENCE" => "blocked", "RAG_COMPANION_GENERATION" => "direct")
    source = Rails.root.join("config/initializers/direct_inference_boot.rb").read
    assert_includes source, "Rails.env.production?"
  end

  test "the 2.29 grant at attempt 326 admits new spend after the 229 window and stops at its dollars" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "spend.json")
      entries = []
      add = ->(id, usd) { entries << { "id" => id, "status" => "settled", "ceiling_usd" => usd, "actual_usd" => usd } }
      (135..229).each { |id| add.call(id, "0.006000") }
      (230..326).each { |id| add.call(id, "0.006500") }
      add.call(327, "0.004093")
      add.call(328, "0.001998")
      File.write(path, JSON.generate(
        "call_cap" => 328, "cost_cap_usd" => "4.0", "attempts" => 326, "blocked" => 0, "priced" => 194,
        "seq" => 328, "committed" => "2.351603", "unknown" => "0.383074", "open" => {}, "entries" => entries,
        "authorization" => { "id" => "f2f3-joint-after-134", "after_attempt" => 134, "cost_usd" => "0.750000", "call_cap" => 328 },
        "executions" => [
          { "id" => "sonnet", "after_attempt" => 229, "cost_usd" => "1.170000", "calls" => 18 },
          { "id" => "a", "after_attempt" => 245, "cost_usd" => "0.650000", "calls" => 52 },
          { "id" => "b", "after_attempt" => 293, "cost_usd" => "0.250000", "calls" => 20 },
          { "id" => "c", "after_attempt" => 304, "cost_usd" => "0.200000", "calls" => 18 },
          { "id" => "d", "after_attempt" => 318, "cost_usd" => "0.100000", "calls" => 10 }
        ]
      ))
      book = Rag::AssignmentSpend.new(path: path, call_cap: 1000, cost_cap_usd: Rag::LocalPassLedger::ASSIGNMENT_COST_CAP_USD)
      assert_raises(Rag::AssignmentSpend::Stop) { book.reserve!(ceiling_usd: "0.010000", model_id: "claude-haiku-5-5-direct") }

      granted = book.admit_execution!(id: "haiku55-http", cost_usd: "2.296091", calls: 676,
        bump_call_cap_to: 1000, bump_only_if_attempts: 326)
      assert_equal 326, granted["after_attempt"]
      assert_equal 1000, book.snapshot["call_cap"]
      id = book.reserve!(ceiling_usd: "0.010000", model_id: "claude-haiku-5-5-direct")
      book.settle!(id, actual_usd: "2.285000")
      assert_raises(Rag::AssignmentSpend::Stop) { book.reserve!(ceiling_usd: "0.010000", model_id: "claude-haiku-5-5-direct") }
      assert book.reserve!(ceiling_usd: "0.005000", model_id: "claude-haiku-5-5-direct")
    end
  end

  private

  def interpret(turn, client:)
    Rag::TurnInterpreter.call(
      turn: turn,
      episode: Rag::ActiveEpisode.new,
      viewer_account: nil,
      correlation_id: "haiku55-direct",
      attribution: {},
      client: client
    )
  end

  def valid_tool
    {
      "move" => "report",
      "assertions" => [],
      "observations" => [ "la puerta no cierra" ],
      "pending_resolution" => nil,
      "clarification_target" => nil
    }
  end

  def response_client(stop_reason:, tool:)
    client = Object.new
    client.define_singleton_method(:converse) do |_params|
      content = if tool
        [ { "tool_use" => { "name" => "turn_perception", "input" => tool } } ]
      else
        [ { "text" => "sin herramienta" } ]
      end
      message = Struct.new(:content).new(content)
      output = Struct.new(:message).new(message)
      usage = Struct.new(:input_tokens, :output_tokens).new(4, 2)
      Struct.new(:output, :usage, :stop_reason).new(output, usage, stop_reason)
    end
    client
  end

  def named_error(name, status: nil)
    klass = Class.new(StandardError)
    klass.define_singleton_method(:name) { name }
    error = klass.new(name)
    error.define_singleton_method(:status) { status } if status
    error
  end
end
