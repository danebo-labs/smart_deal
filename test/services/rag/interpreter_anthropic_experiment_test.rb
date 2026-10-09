# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class Rag::InterpreterAnthropicExperimentTest < ActiveSupport::TestCase
  SECRET = "sk-ant-api03-TESTONLYNOTAREALKEY"
  HAIKU_55 = Rag::InterpreterAnthropicAdapter::HAIKU_55
  HAIKU_45 = Rag::InterpreterAnthropicAdapter::HAIKU_45

  test "matrix size, models, and closed budget match the proposal" do
    matrix = Rag::InterpreterAnthropicExperiment.matrix

    assert_equal 24, matrix.size
    assert_equal 48, Rag::InterpreterAnthropicExperiment::Budget.attempt_cap
    assert_equal "0.135984", format("%.6f", Rag::InterpreterAnthropicExperiment::Budget.money_cap)
    assert_equal [ HAIKU_55, HAIKU_45 ], Rag::InterpreterAnthropicExperiment::MODELS
    assert_equal 512, Rag::TurnInterpreter::MAX_TOKENS
    assert_equal 0, Rag::Stage2RunBudget::PASS_CALL_CAP
    assert_equal false, Rag::InterpreterAnthropicExperiment::LIVE_CALLS_ENABLED
    assert_equal "absent", Rag::InterpreterAnthropicExperiment.credential_status(nil)
    assert_equal "present", Rag::InterpreterAnthropicExperiment.credential_status(SECRET)
  end

  test "translation keeps the prompt, the message, the schema, and the output limit" do
    row = matrix_row("phase1")
    params = converse_params(row)
    haiku55 = Rag::InterpreterAnthropicAdapter.translate(params, model_id: HAIKU_55)
    haiku45 = Rag::InterpreterAnthropicAdapter.translate(params, model_id: HAIKU_45)

    assert_equal Rag::TurnInterpreter::PROMPT, haiku55.dig("body", "system", 0, "text")
    assert_equal message_text(params), haiku55.dig("body", "messages", 0, "content", 0, "text")
    assert_equal 512, haiku55.dig("body", "max_tokens")
    assert_equal 512, haiku45.dig("body", "max_tokens")
    assert_equal params.dig(:tool_config, :tools, 0, :tool_spec, :input_schema, :json),
      haiku55.dig("body", "tools", 0, "input_schema")
    assert_equal({ "type" => "tool", "name" => "turn_perception" }, haiku55.dig("body", "tool_choice"))
    assert_nil haiku55.dig("body", "temperature")
    assert_nil haiku55.dig("body", "thinking")
    assert_nil haiku55.dig("body", "output_config")
    assert_equal 0, haiku45.dig("body", "temperature")
    assert_equal 0, params.dig(:inference_config, :temperature)
    assert_equal "omit", haiku55.dig("adjustments", 0, "action")
    assert_equal false, haiku55.dig("headers", "x-api-key", "present")
  end

  test "bedrock and alias model ids are rejected without substitution" do
    params = converse_params(matrix_row("variador"))

    [
      "anthropic.claude-haiku-5-5",
      "us.anthropic.claude-haiku-5-5",
      "global.anthropic.claude-haiku-5-5",
      "claude-haiku-4-5",
      "global.anthropic.claude-haiku-4-5-20251001-v1:0"
    ].each do |model_id|
      error = assert_raises(Rag::InterpreterAnthropicAdapter::Error) {
        Rag::InterpreterAnthropicAdapter.translate(params, model_id: model_id)
      }
      assert_includes %w[bedrock_model_rejected model_rejected], error.code
      assert_not_equal HAIKU_55, model_id
    end
  end

  test "normalization keeps native and normalized payloads and does not invent tool input" do
    native = message_payload(
      perception("report"),
      extra: [
        { "type" => "thinking", "thinking" => "", "signature" => "sig" },
        { "type" => "text", "text" => "nota #{SECRET}" },
        { "type" => "redacted_thinking", "data" => "opaque" },
        { "type" => "server_tool_use", "id" => "srv", "name" => "other", "input" => { "x" => 1 } }
      ]
    )
    native["x-api-key"] = SECRET
    observed = Rag::InterpreterAnthropicAdapter.normalize(native)
    extracted = Rag::InterpreterAnthropicAdapter.tool_input(observed.output.message.content)

    assert_equal perception("report"), extracted
    assert_equal "", observed.native.dig("content", 0, "thinking")
    assert_equal "nota [redacted]", observed.normalized.dig("content", 1, "text")
    assert_equal "server_tool_use", observed.normalized.dig("content", 3, "unmodeled_block", "type")
    assert_nil observed.native["x-api-key"]
    assert_not_includes observed.native.to_json, SECRET

    empty = Rag::InterpreterAnthropicAdapter.normalize("content" => [])
    assert_nil Rag::InterpreterAnthropicAdapter.tool_input(empty.output.message.content)
    assert_nil empty.usage

    text_only = Rag::InterpreterAnthropicAdapter.normalize(
      "content" => [ { "type" => "text", "text" => "solo texto" } ], "stop_reason" => "end_turn"
    )
    assert_nil Rag::InterpreterAnthropicAdapter.tool_input(text_only.output.message.content)
    assert_equal "solo texto", text_only.normalized.dig("content", 0, "text")

    missing_usage = Rag::InterpreterAnthropicAdapter.normalize(
      "type" => "message", "content" => [ tool_block(perception("report")) ], "stop_reason" => "tool_use"
    )
    assert_nil missing_usage.usage
    priced = Rag::InterpreterAnthropicAdapter.price(HAIKU_55, nil)
    assert_nil priced["cost_usd"]
    assert_equal "usage_absent", priced["cost_status"]
  end

  test "tool input extraction matches with capture on and off" do
    observed = Rag::InterpreterAnthropicAdapter.normalize(message_payload(perception("meta")))
    content = observed.output.message.content
    off = Rag::InterpreterAnthropicAdapter.tool_input(content)
    on = nil
    events = Rag::ValidationCapture.capture do
      on = Rag::InterpreterAnthropicAdapter.tool_input(content)
    end

    assert_equal off, on
    assert_equal perception("meta"), on
    assert_empty events
  end

  test "provider errors and unknown usage do not invent tokens or cost" do
    error = assert_raises(Rag::InterpreterAnthropicAdapter::ProviderError) {
      Rag::InterpreterAnthropicAdapter.normalize(
        "type" => "error",
        "error" => { "type" => "invalid_request_error", "message" => "temperature #{SECRET}" }
      )
    }
    assert_equal "invalid_request_error", error.error_type
    assert_not_includes error.message, SECRET

    priced = Rag::InterpreterAnthropicAdapter.price(
      HAIKU_55, { "input_tokens" => 12, "output_tokens" => 4, "server_tool_use" => { "web_search_requests" => 1 } }
    )
    assert_nil priced["cost_usd"]
    assert_equal "unpriced_usage_field", priced["cost_status"]

    known = Rag::InterpreterAnthropicAdapter.price(HAIKU_45, { "input_tokens" => 2174, "output_tokens" => 106 })
    assert_equal "0.002704", known["cost_usd"]
    assert_equal "https://platform.claude.com/docs/en/about-claude/pricing", known["source"]
  end

  test "a higher max token limit is rejected" do
    params = converse_params(matrix_row("variador"))
    params[:inference_config] = params[:inference_config].merge(max_tokens: 513)

    error = assert_raises(Rag::InterpreterAnthropicAdapter::Error) {
      Rag::InterpreterAnthropicAdapter.translate(params, model_id: HAIKU_55)
    }
    assert_equal "max_tokens_above_interpreter", error.code
  end

  test "prepare blocks before a call and writes no run artifacts" do
    poster = Called.new
    Dir.mktmpdir do |dir|
      assert_no_queries do
        summary = Rag::InterpreterAnthropicExperiment.prepare(evidence_root: dir, run_id: "local")
        assert_equal 0, summary["calls"]
        assert_equal 48, summary["cases"]
      end
      root = Pathname(dir)
      assert root.join("prepared", "local", "capture.json").file?
      assert_not root.join("runs").exist?
      assert_not root.join("stubs").exist?
      case_dir = root.join("prepared", "local", "phase1", HAIKU_55)
      native = JSON.parse(case_dir.join("native_response.json").read)
      judgment = JSON.parse(case_dir.join("judgment.json").read)
      usage = JSON.parse(case_dir.join("usage.json").read)
      client = JSON.parse(case_dir.join("client_input.json").read)
      payload = JSON.parse(case_dir.join("case.json").read)

      assert_equal "not_executed", native["provenance"]
      assert_equal "not_judged", judgment["judgment"]
      assert_equal "not_called", usage["cost_status"]
      assert_nil usage["cost_usd"]
      assert_nil usage["latency_ms"]
      assert_equal false, payload["provider_call"]
      assert_equal false, payload.dig("context", "persisted")
      assert_equal({}, payload.dig("context", "work_context"))
      assert_equal 512, client.dig("body", "max_tokens")
      assert_nil client.dig("body", "temperature")
      capture = JSON.parse(root.join("prepared", "local", "capture.json").read)
      assert_equal "danebo.audit.v1", capture["schema_version"]
      results = capture["events"].map { |event| event["result"] }
      assert_includes results, "prepared"
      assert_includes results, "blocked"
      assert_not_includes results, "attempt_started"
      assert_not_includes results, "returned"
      assert_equal false, poster.called
    end
  end

  test "active context is explicit and is not a persisted episode" do
    Dir.mktmpdir do |dir|
      Rag::InterpreterAnthropicExperiment.prepare(evidence_root: dir, run_id: "local")
      payload = JSON.parse(Pathname(dir).join("prepared", "local", "phase1_active", HAIKU_45, "case.json").read)

      assert_equal false, payload.dig("context", "persisted")
      assert_equal "ep_experiment_active", payload.dig("context", "episode_id")
      assert_equal "problema de puerta en el nivel 2", payload.dig("context", "work_context", "goal")
      assert_equal [ "problema de puerta en el nivel 2" ], payload.dig("context", "work_context", "observations")
      assert_equal 0, client_temperature(dir, "phase1_active")
    end
  end

  test "stub rehearsal judges the raw tool input and stays out of runs" do
    called = false
    original = Rag::TurnPerception.method(:build)
    Rag::TurnPerception.define_singleton_method(:build) { |*, **| called = true }
    Dir.mktmpdir do |dir|
      native = message_payload(perception("meta"), usage: nil)
      native["content"].unshift("type" => "text", "text" => "clave #{SECRET}")
      Rag::InterpreterAnthropicExperiment.rehearse(
        evidence_root: dir, run_id: "stub-1", scenario_id: "phase1", model_id: HAIKU_55, native: native
      )
      root = Pathname(dir)
      assert_not root.join("runs").exist?
      assert_not root.join("prepared").exist?
      case_dir = root.join("stubs", "stub-1", "phase1", HAIKU_55)
      judgment = JSON.parse(case_dir.join("judgment.json").read)
      usage = JSON.parse(case_dir.join("usage.json").read)
      native_file = case_dir.join("native_response.json").read
      normalized = JSON.parse(case_dir.join("normalized.json").read)
      capture = JSON.parse(root.join("stubs", "stub-1", "capture.json").read)
      results = capture["events"].map { |event| event["result"] }

      assert_equal "fail", judgment["judgment"]
      assert_equal "forbidden_move", judgment["reason"]
      assert_equal "returned", judgment["provider_result"]
      assert_equal false, judgment["provider_call"]
      assert_equal "meta", judgment.dig("observed", "move")
      assert_nil usage["cost_usd"]
      assert_equal "usage_absent", usage["cost_status"]
      assert_not_includes native_file, SECRET
      assert_includes normalized.to_json, "[redacted]"
      assert_includes results, "prepared"
      assert_includes results, "returned"
      assert_not_includes results, "attempt_started"
      assert_equal false, called
    end
  ensure
    if original
      Rag::TurnPerception.define_singleton_method(:build) { |*args, **kwargs, &block|
        original.call(*args, **kwargs, &block)
      }
    end
  end

  test "administrative and ambiguous judgments stay on the contract" do
    experiment = Rag::InterpreterAnthropicExperiment
    assert_equal "pass", experiment.judge(matrix_row("buenas_tardes"), perception("meta"))["judgment"]
    greeting = experiment.judge(matrix_row("buenas_tardes"), perception("meta", observations: [ "Buenas tardes" ]))
    assert_equal "fail", greeting["judgment"]
    assert_equal "observation_on_non_symptom", greeting["reason"]
    assert_equal "pass", experiment.judge(matrix_row("phase1"), perception("report"))["judgment"]
    assert_equal "fail", experiment.judge(matrix_row("necesitas_motor"), perception("meta"))["judgment"]
    assert_equal "review", experiment.judge(matrix_row("perfecto"), perception("meta"))["judgment"]
    assert_equal "review", experiment.judge(matrix_row("donde_veo_plano"), perception("report"))["judgment"]
    drawing = experiment.judge(matrix_row("donde_veo_plano"), perception("report", observations: [ "plano" ]))
    assert_equal "fail", drawing["judgment"]
    assert_equal "observation_on_non_symptom", drawing["reason"]
    assert_equal "review", experiment.judge(matrix_row("variador_active"), perception("new_work"))["judgment"]
    assert_equal "fail", experiment.judge(matrix_row("variador_active"), perception("meta"))["judgment"]
    assert_equal "not_judged", experiment.judge(matrix_row("phase1"), nil)["judgment"]
  end

  test "budget blocks at the attempt cap and the money cap before a call" do
    budget = Rag::InterpreterAnthropicExperiment::Budget
    cap = budget.money_cap
    reservation = budget.reservation_usd(HAIKU_45)

    assert_equal "live_calls_closed", budget.gate(HAIKU_55, attempts: 0, spent_usd: 0, live: false, credential_present: true)
    assert_equal "credential_absent", budget.gate(HAIKU_55, attempts: 0, spent_usd: 0, live: true, credential_present: false)
    assert_nil budget.gate(HAIKU_55, attempts: 0, spent_usd: 0, live: true, credential_present: true)
    assert_equal "attempt_cap", budget.gate(HAIKU_55, attempts: 48, spent_usd: 0, live: true, credential_present: true)
    assert_nil budget.gate(HAIKU_45, attempts: 47, spent_usd: cap - reservation, live: true, credential_present: true)
    assert_equal "money_cap", budget.gate(
      HAIKU_45, attempts: 47, spent_usd: cap - reservation + BigDecimal("0.000001"),
      live: true, credential_present: true
    )
    assert_equal false, budget.continue_after?("error")
    assert_equal true, budget.continue_after?("returned")
    assert_equal false, budget.continue_after?("returned", cost_status: "usage_absent")
    assert_equal false, budget.continue_after?("returned", cost_status: "unpriced_usage_field")
  end

  test "live execution stays closed and the default provider is untouched" do
    called = false
    error = assert_raises(Rag::InterpreterAnthropicExperiment::Error) {
      Rag::InterpreterAnthropicExperiment.execute { called = true }
    }
    assert_equal "live_calls_closed", error.code
    assert_equal false, called
    assert_equal "global.anthropic.claude-haiku-4-5-20251001-v1:0", Rag::TurnInterpreter::MODEL_ID

    root = Rails.root
    interpreter = root.join("app/services/rag/turn_interpreter.rb").read
    provider = root.join("app/services/ai_provider.rb").read
    bedrock = root.join("app/services/bedrock_client.rb").read
    session = root.join("app/models/conversation_session.rb").read
    adapter = root.join("app/services/rag/interpreter_anthropic_adapter.rb").read
    experiment = root.join("app/services/rag/interpreter_anthropic_experiment.rb").read
    script = root.join("script/field_companion/interpreter_haiku55_experiment.rb").read

    assert_not_includes interpreter, "InterpreterAnthropic"
    assert_not_includes interpreter, "claude-haiku-5-5"
    assert_includes provider, "bedrock"
    assert_not_includes bedrock, "InterpreterAnthropic"
    assert_not_includes session, "InterpreterAnthropic"
    assert_not_includes adapter, "ANTHROPIC_API_KEY"
    assert_not_includes adapter, "Net::HTTP"
    assert_not_includes experiment, "ANTHROPIC_API_KEY"
    assert_not_includes experiment, "Net::HTTP"
    assert_not_includes experiment, "TurnPerception.build"
    assert_not_includes experiment, "PHASE1_PINNED_TURN_AUTHORIZED"
    assert_nil script[/ENV\["ANTHROPIC_API_KEY"\]/]
    assert_not_includes script, "Net::HTTP"
  end

  private

  def matrix_row(id)
    Rag::InterpreterAnthropicExperiment.matrix.find { |row| row["id"] == id }
  end

  def converse_params(row)
    Rag::InterpreterAnthropicExperiment.new(
      evidence_root: ".", run_id: "params", lane: "prepared"
    ).send(:converse_params, row)
  end

  def message_text(params)
    params.dig(:messages, 0, :content, 0, :text)
  end

  def perception(move, observations: [], assertions: [], target: nil)
    {
      "move" => move,
      "assertions" => assertions,
      "observations" => observations,
      "pending_resolution" => nil,
      "clarification_target" => target
    }
  end

  def tool_block(input)
    { "type" => "tool_use", "id" => "toolu_stub", "name" => "turn_perception", "input" => input }
  end

  def message_payload(input, extra: [], usage: { "input_tokens" => 11, "output_tokens" => 7 })
    payload = {
      "id" => "msg_stub",
      "type" => "message",
      "role" => "assistant",
      "model" => HAIKU_55,
      "stop_reason" => "tool_use",
      "content" => extra + [ tool_block(input) ]
    }
    payload["usage"] = usage unless usage.nil?
    payload
  end

  def client_temperature(dir, scenario_id)
    JSON.parse(Pathname(dir).join("prepared", "local", scenario_id, HAIKU_45, "client_input.json").read)
      .dig("body", "temperature")
  end

  class Called
    attr_reader :called

    def initialize
      @called = false
    end

    def call(*)
      @called = true
    end
  end
end
