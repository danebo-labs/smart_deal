# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class Rag::InterpreterAnthropicExperimentTest < ActiveSupport::TestCase
  SECRET = "sk-ant-api03-TESTONLYNOTAREALKEY"
  HAIKU_55 = Rag::InterpreterAnthropicAdapter::HAIKU_55
  HAIKU_45 = Rag::InterpreterAnthropicAdapter::HAIKU_45

  test "matrix size, models, and closed budget match the proposal" do
    matrix = Rag::InterpreterAnthropicExperiment.matrix

    assert_equal 25, matrix.size
    assert_equal 50, Rag::InterpreterAnthropicExperiment::Budget.attempt_cap
    assert_equal "0.141650", format("%.6f", Rag::InterpreterAnthropicExperiment::Budget.money_cap)
    assert_equal Rag::InterpreterAnthropicExperiment::Budget.money_cap,
      Rag::InterpreterAnthropicExperiment::Budget.estimate_usd
    assert_equal Rag::InterpreterAnthropicExperiment.matrix_sha256,
      Rag::InterpreterAnthropicExperiment::APPROVED_MATRIX_SHA256
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
    assert_equal "nota #{SECRET}", observed.normalized.dig("content", 1, "text")
    assert_equal "normalized", observed.normalized["provenance"]
    assert_equal "server_tool_use", observed.normalized.dig("content", 3, "unmodeled_block", "type")
    assert_equal SECRET, observed.native["x-api-key"]
    exported = Rag::InterpreterAnthropicAdapter.scrub(observed.native)
    assert_nil exported["x-api-key"]
    assert_not_includes exported.to_json, SECRET
    assert_includes Rag::InterpreterAnthropicAdapter.scrub(observed.normalized).to_json, "[redacted]"

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
        assert_equal 50, summary["cases"]
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
    absent = experiment.judge(matrix_row("phase1"), nil, provider_result: "not_called")
    assert_equal "not_judged", absent["judgment"]
    missing = experiment.judge(matrix_row("phase1"), nil)
    assert_equal "incomplete", missing["judgment"]
    assert_equal "tool_absent", missing["reason"]
  end

  test "budget blocks at the attempt cap and the money cap before a call" do
    budget = Rag::InterpreterAnthropicExperiment::Budget
    cap = budget.money_cap
    reservation = budget.reservation_usd(HAIKU_45)

    assert_equal "live_calls_closed", budget.gate(HAIKU_55, attempts: 0, spent_usd: 0, live: false, credential_present: true)
    assert_equal "credential_absent", budget.gate(HAIKU_55, attempts: 0, spent_usd: 0, live: true, credential_present: false)
    assert_nil budget.gate(HAIKU_55, attempts: 0, spent_usd: 0, live: true, credential_present: true)
    assert_equal "attempt_cap", budget.gate(HAIKU_55, attempts: 50, spent_usd: 0, live: true, credential_present: true)
    assert_nil budget.gate(HAIKU_45, attempts: 49, spent_usd: cap - reservation, live: true, credential_present: true)
    assert_equal "money_cap", budget.gate(
      HAIKU_45, attempts: 49, spent_usd: cap - reservation + BigDecimal("0.000001"),
      live: true, credential_present: true
    )
    assert_equal false, budget.continue_after?(
      "returned", cost_usd: "1.000000", reservation_usd: reservation
    )
    assert_equal false, budget.continue_after?("error")
    assert_equal true, budget.continue_after?("returned")
    assert_equal false, budget.continue_after?("returned", cost_status: "usage_absent")
    assert_equal false, budget.continue_after?("returned", cost_status: "unpriced_usage_field")
  end

  test "live execution stays closed and the default provider is untouched" do
    called = false
    source = -> { called = true; SECRET }
    error = assert_raises(Rag::InterpreterAnthropicExperiment::Error) {
      Rag::InterpreterAnthropicExperiment.execute(
        evidence_root: Dir.mktmpdir, run_id: "closed", credential_source: source, transport: StubTransport.new
      )
    }
    assert_equal "execution_not_approved", error.code
    assert_equal false, called
    assert_equal false, Rag::InterpreterAnthropicExperiment::LIVE_CALLS_ENABLED
    assert_equal "execution_not_approved", Rag::InterpreterAnthropicExperiment.approval_refusal(
      Rag::InterpreterAnthropicExperiment.approval.merge("live_calls_enabled" => true)
    )
    assert_equal "global.anthropic.claude-haiku-4-5-20251001-v1:0", Rag::TurnInterpreter::MODEL_ID

    root = Rails.root
    interpreter = root.join("app/services/rag/turn_interpreter.rb").read
    provider = root.join("app/services/ai_provider.rb").read
    bedrock = root.join("app/services/bedrock_client.rb").read
    session = root.join("app/models/conversation_session.rb").read
    adapter = root.join("app/services/rag/interpreter_anthropic_adapter.rb").read
    experiment = root.join("app/services/rag/interpreter_anthropic_experiment.rb").read
    transport = root.join("app/services/rag/interpreter_anthropic_transport.rb").read
    script = root.join("script/field_companion/interpreter_haiku55_experiment.rb").read

    assert_not_includes interpreter, "InterpreterAnthropic"
    assert_not_includes interpreter, "claude-haiku-5-5"
    assert_includes provider, "bedrock"
    assert_not_includes bedrock, "InterpreterAnthropic"
    assert_not_includes bedrock, "claude-haiku-5-5"
    assert_not_includes session, "InterpreterAnthropic"
    assert_not_includes adapter, "ANTHROPIC_API_KEY"
    assert_not_includes adapter, "Net::HTTP"
    assert_not_includes adapter, "InvokeModel"
    assert_equal 1, experiment.scan("ANTHROPIC_API_KEY").size
    assert_includes experiment, "def self.env_credential"
    assert_not_includes experiment, "Net::HTTP"
    assert_not_includes experiment, "TurnPerception.build"
    assert_not_includes experiment, "PHASE1_PINNED_TURN_AUTHORIZED"
    assert_not_includes experiment, "bedrock"
    assert_includes transport, "Net::HTTP"
    assert_includes transport, "api.anthropic.com"
    assert_not_includes transport, "ANTHROPIC_API_KEY"
    assert_not_includes transport, "bedrock"
    assert_not_includes transport, "InvokeModel"
    assert_nil script[/ENV\["ANTHROPIC_API_KEY"\]/]
    assert_not_includes script, "Net::HTTP"
    assert_not_includes script, "bedrock"
  end

  test "a valid move fails when the raw payload breaks the contract" do
    experiment = Rag::InterpreterAnthropicExperiment
    phase1 = matrix_row("phase1")
    variador = matrix_row("variador")
    literal = perception("report", observations: [ "problema de puerta en el nivel 2" ])
    paraphrase = perception("report", observations: [ "problema en la puerta del segundo piso" ])
    invented = perception(
      "report",
      assertions: [ { "span" => "motor quemado", "act" => "assert" } ]
    )
    malformed = perception(
      "report",
      assertions: [ { "span" => "El variador no arranca", "act" => "guess" } ]
    )
    invalid_move = perception("report").merge("move" => "sideways")
    pending = perception("report").merge("pending_resolution" => "value")
    unclear = perception("unclear")
    huge = perception("report", observations: [ "x" * (Rag::ActiveEpisode::MAX_OBSERVATION_CHARS + 1) ])
    too_many = perception(
      "report",
      assertions: Array.new(Rag::TurnPerception::MAX_ASSERTIONS + 1) { { "span" => "puerta", "act" => "mention" } }
    )

    assert_equal "pass", experiment.judge(phase1, perception("report"))["judgment"]
    assert_equal "pass", experiment.judge(phase1, literal)["judgment"]
    assert_equal "pass", experiment.judge(matrix_row("circuito"), perception("report"))["judgment"]
    assert_equal "pass", experiment.judge(matrix_row("kse"), perception("report"))["judgment"]
    meta = experiment.judge(phase1, perception("meta"))
    assert_equal "fail", meta["judgment"]
    assert_equal "interpretation_failure", meta["classification"]
    assert_equal "forbidden_move", meta["reason"]

    invented_judgment = experiment.judge(variador, invented)
    assert_equal "contract_failure", invented_judgment["classification"]
    assert_equal "span_not_literal", invented_judgment["reason"]
    paraphrased = experiment.judge(variador, paraphrase)
    assert_equal "contract_failure", paraphrased["classification"]
    assert_equal "observation_not_literal", paraphrased["reason"]
    assert_equal "malformed_assertion", experiment.judge(variador, malformed)["reason"]
    assert_equal "invalid_move", experiment.judge(phase1, invalid_move)["reason"]
    assert_equal "invalid_pending_resolution", experiment.judge(
      phase1, perception("report").merge("pending_resolution" => "referent")
    )["reason"]
    assert_equal "pending_incompatible", experiment.judge(phase1, pending)["reason"]
    assert_equal "unclear_without_target", experiment.judge(matrix_row("perfecto"), unclear)["reason"]
    assert_equal "over_length", experiment.judge(phase1, huge)["reason"]
    assert_equal "too_many_assertions", experiment.judge(variador, too_many)["reason"]
    assert_equal "review", experiment.judge(matrix_row("foto_fallas"), perception("meta"))["judgment"]
    assert_equal "review", experiment.judge(matrix_row("foto_fallas"), perception("report"))["judgment"]
    assert_equal "pending_review", experiment.judge(matrix_row("foto_fallas"), perception("report"))["classification"]
    assert_equal "pass", experiment.judge(matrix_row("foto_resumen"), perception("meta"))["judgment"]
    assert_equal "pass", experiment.judge(matrix_row("resumen_pedido_active"), perception("follow_up"))["judgment"]
    assert_equal "fail", experiment.judge(matrix_row("resumen_pedido_active"), perception("meta"))["judgment"]
  end

  test "max tokens and missing tools do not pass and still keep priced usage" do
    row = matrix_row("variador")
    payload = perception("report", observations: [ "El variador no arranca" ])
    stopped = Rag::InterpreterAnthropicExperiment.judge(row, payload, stop_reason: "max_tokens")

    assert_equal "incomplete", stopped["judgment"]
    assert_equal "incomplete_response", stopped["classification"]
    assert_equal "max_tokens", stopped["reason"]
    assert_nil stopped["validation"]

    Dir.mktmpdir do |dir|
      native = message_payload(payload, usage: { "input_tokens" => 20, "output_tokens" => 4 })
      native["stop_reason"] = "max_tokens"
      Rag::InterpreterAnthropicExperiment.rehearse(
        evidence_root: dir, run_id: "cap", scenario_id: "variador", model_id: HAIKU_45, native: native
      )
      usage = JSON.parse(Pathname(dir).join("stubs", "cap", "variador", HAIKU_45, "usage.json").read)
      judgment = JSON.parse(Pathname(dir).join("stubs", "cap", "variador", HAIKU_45, "judgment.json").read)

      assert_equal "incomplete", judgment["judgment"]
      assert_equal "priced", usage["cost_status"]
      assert_equal "0.000040", usage["cost_usd"]
    end
  end

  test "normalization keeps original tool input in memory and exports a scrubbed copy" do
    secret_observation = "El variador no arranca #{SECRET}"
    observed = Rag::InterpreterAnthropicAdapter.normalize(
      message_payload(perception("report", observations: [ secret_observation ]))
    )
    content = observed.output.message.content
    extracted = Rag::InterpreterAnthropicAdapter.tool_input(content)
    captured = nil
    events = Rag::ValidationCapture.capture do
      captured = Rag::InterpreterAnthropicAdapter.tool_input(content)
    end

    assert_equal secret_observation, extracted.dig("observations", 0)
    assert_equal extracted, captured
    assert_empty events
    assert_not_includes Rag::InterpreterAnthropicAdapter.scrub(extracted).to_json, SECRET
  end

  test "product perception still drops a bad span instead of rejecting the move" do
    turn = "El variador no arranca"
    raw = perception(
      "report",
      assertions: [ { "span" => "motor inventado", "act" => "assert", "slot_hint" => "voltage" } ]
    )
    product = Rag::TurnPerception.build(
      raw, turn: turn, episode: Rag::ActiveEpisode.new, catalog: nil, viewer_account: nil
    )
    contract = Rag::InterpreterPayloadContract.evaluate(raw, sent_turn: turn)

    assert_equal true, product.valid
    assert_equal "report", product.move
    assert_equal false, contract["valid"]
    assert_includes %w[invalid_slot_hint span_not_literal], contract["reason"]
  end

  test "anthropic transport posts once and does not echo the credential" do
    behavior = lambda { |session, request|
      assert_equal SECRET, request["x-api-key"]
      assert_equal 0, session.max_retries
      assert_equal 5, session.open_timeout
      assert_equal 30, session.read_timeout
      raise Net::ReadTimeout
    }
    http = FakeHTTP.new(behavior)
    result = Rag::InterpreterAnthropicTransport.new(http: http).post(
      endpoint: Rag::InterpreterAnthropicAdapter::ENDPOINT,
      headers: { "x-api-key" => SECRET, "content-type" => "application/json" },
      body: { "model" => HAIKU_55 },
      open_timeout: 5,
      read_timeout: 30
    )

    assert_equal 1, http.sessions.size
    assert_equal "timeout", result.error_code
    assert_not_includes result.error_message.to_s, SECRET
    assert_equal false, Rag::InterpreterAnthropicTransport.new.live?
    assert_equal true, Rag::InterpreterAnthropicTransport.live.live?
  end

  test "http errors are not retried and do not keep the credential" do
    body = {
      "type" => "error",
      "error" => { "type" => "authentication_error", "message" => "bad #{SECRET}" }
    }.to_json
    http = FakeHTTP.new(->(*) { FakeResponse.new("401", body) })
    result = Rag::InterpreterAnthropicTransport.new(http: http).post(
      endpoint: Rag::InterpreterAnthropicAdapter::ENDPOINT,
      headers: { "x-api-key" => SECRET },
      body: { "model" => HAIKU_45 },
      open_timeout: 5,
      read_timeout: 30
    )

    assert_equal 1, http.sessions.size
    assert_equal "http_401", result.error_code
    assert_equal "authentication_error", result.payload.dig("error", "type")
    assert_not_includes result.error_message, SECRET
  end

  test "stub transport runs only inside an approved quota" do
    experiment = Rag::InterpreterAnthropicExperiment
    approval = experiment.approval.merge("enabled" => true)
    reads = 0
    source = -> { reads += 1; SECRET }
    transport = StubTransport.new { |count, body|
      assert_includes [ HAIKU_55, HAIKU_45 ], body["model"]
      assert_not_includes body["model"], "anthropic.claude"
      usage = { "input_tokens" => 11, "output_tokens" => 7 }
      Rag::InterpreterAnthropicTransport::Result.new(
        http_status: 200,
        payload: message_payload(perception("meta"), usage: usage).merge("model" => body["model"]),
        error_code: nil,
        error_message: nil
      )
    }

    Dir.mktmpdir do |dir|
      summary = experiment.execute(
        evidence_root: dir, run_id: "allowed", approval: approval, transport: transport,
        credential_source: source, only: [ "buenas_tardes" ]
      )
      root = Pathname(dir).join("runs", "allowed")
      judgment = JSON.parse(root.join("buenas_tardes", HAIKU_55, "judgment.json").read)
      capture = JSON.parse(root.join("capture.json").read)
      results = capture["events"].map { |event| event["result"] }
      tree = root.to_s.then { |path| Dir.glob(File.join(path, "**", "*")).select { |file| File.file?(file) } }

      assert_equal 2, summary["calls"]
      assert_equal false, summary["provider_call"]
      assert_equal true, summary["evidence_complete"]
      assert_equal 1, reads
      assert_equal "pass", judgment["judgment"]
      assert_equal "tool_use", judgment["stop_reason"]
      assert_equal [ HAIKU_55, HAIKU_45 ], transport.calls.map { |call| call[:body]["model"] }
      assert_equal Rag::InterpreterAnthropicAdapter::ENDPOINT, transport.calls.first[:endpoint]
      assert_equal SECRET, transport.calls.first[:headers]["x-api-key"]
      assert_equal 5, transport.calls.first[:open_timeout]
      assert_equal 30, transport.calls.first[:read_timeout]
      assert_includes results, "prepared"
      assert_includes results, "attempt_started"
      assert_includes results, "returned"
      assert_includes results, "pass"
      tree.each { |file| assert_not_includes File.read(file), SECRET, file }
    end
  end

  test "quota blocks attempts, money, errors, missing usage, and a closed run" do
    experiment = Rag::InterpreterAnthropicExperiment
    approval = experiment.approval.merge("enabled" => true)
    source = -> { "present" }

    Dir.mktmpdir do |dir|
      capped = StubTransport.new
      summary = experiment.execute(
        evidence_root: dir, run_id: "capped", approval: approval, transport: capped,
        credential_source: source, only: [ "buenas_tardes" ],
        budget_state: { "attempts" => 50, "spent_usd" => "0", "closed" => false }
      )
      assert_equal 0, summary["calls"]
      assert_empty capped.calls
      assert_equal "attempt_cap", summary["close_reason"]

      poor = StubTransport.new
      almost = experiment::Budget.money_cap - BigDecimal("0.000001")
      summary = experiment.execute(
        evidence_root: dir, run_id: "poor", approval: approval, transport: poor,
        credential_source: source, only: [ "buenas_tardes" ],
        budget_state: { "attempts" => 0, "spent_usd" => format("%.6f", almost), "closed" => false }
      )
      assert_equal 0, summary["calls"]
      assert_empty poor.calls

      failed = StubTransport.new { |_count, body|
        Rag::InterpreterAnthropicTransport::Result.new(
          http_status: 500,
          payload: { "type" => "error", "error" => { "type" => "api_error", "message" => "down #{SECRET}" },
                     "usage" => { "input_tokens" => 9, "output_tokens" => 0 } },
          error_code: "http_500",
          error_message: "down [redacted]"
        )
      }
      summary = experiment.execute(
        evidence_root: dir, run_id: "failed", approval: approval, transport: failed,
        credential_source: source, only: [ "buenas_tardes", "variador" ]
      )
      usage = JSON.parse(Pathname(dir).join("runs", "failed", "buenas_tardes", HAIKU_55, "usage.json").read)
      assert_equal 1, summary["calls"]
      assert_equal 1, failed.calls.size
      assert_equal true, summary["closed"]
      assert_equal "priced", usage["cost_status"]
      assert_not_includes File.read(Pathname(dir).join("runs", "failed", "capture.json")), SECRET

      blind = StubTransport.new {
        Rag::InterpreterAnthropicTransport::Result.new(
          http_status: 200,
          payload: message_payload(perception("meta"), usage: nil),
          error_code: nil,
          error_message: nil
        )
      }
      summary = experiment.execute(
        evidence_root: dir, run_id: "blind", approval: approval, transport: blind,
        credential_source: source, only: [ "buenas_tardes", "variador" ]
      )
      assert_equal 1, summary["calls"]
      assert_equal "usage_absent", summary["close_reason"]

      over = StubTransport.new { |_count, body|
        Rag::InterpreterAnthropicTransport::Result.new(
          http_status: 200,
          payload: message_payload(
            perception("meta"),
            usage: { "input_tokens" => 20_000, "output_tokens" => 10 }
          ).merge("model" => body["model"]),
          error_code: nil,
          error_message: nil
        )
      }
      summary = experiment.execute(
        evidence_root: dir, run_id: "over", approval: approval, transport: over,
        credential_source: source, only: [ "buenas_tardes", "variador" ]
      )
      assert_equal 1, summary["calls"]
      assert_equal "reservation_exceeded", summary["close_reason"]
      assert Pathname(dir).join("runs", "over", "execution_state.json").file?

      again = StubTransport.new
      error = assert_raises(Rag::InterpreterAnthropicExperiment::Error) {
        experiment.execute(
          evidence_root: dir, run_id: "over", approval: approval, transport: again, credential_source: source
        )
      }
      assert_equal "run_exists", error.code
      assert_empty again.calls
    end
  end

  test "prepare does not read a credential and authorization alone does not call" do
    experiment = Rag::InterpreterAnthropicExperiment
    original = experiment.method(:env_credential)
    experiment.define_singleton_method(:env_credential) { flunk("credential read") }
    Dir.mktmpdir do |dir|
      prepared = experiment.command(
        prepare: true, authorized: false, evidence_root: dir, run_id: "script-prepare"
      )
      refused = experiment.command(prepare: false, authorized: false, evidence_root: dir, run_id: "nope")
      flagged = experiment.command(prepare: false, authorized: true, evidence_root: dir, run_id: "flag")

      assert_equal 0, prepared["exit_code"]
      assert_equal 0, prepared.dig("output", "calls")
      assert_equal false, prepared.dig("output", "credential_read")
      assert Pathname(dir).join("prepared", "script-prepare", "capture.json").file?
      assert_not Pathname(dir).join("runs").exist?
      assert_equal "authorization_absent", refused.dig("output", "reason")
      assert_equal "execution_not_approved", flagged.dig("output", "reason")
      assert_equal false, flagged.dig("output", "credential_read")
    end
  ensure
    if original
      experiment.define_singleton_method(:env_credential) { original.call }
    end
  end

  test "one approval flag does not open the call" do
    experiment = Rag::InterpreterAnthropicExperiment
    partial = { "enabled" => true, "live_calls_enabled" => true }
    reason = experiment.approval_refusal(partial)
    source = -> { flunk("credential read") }

    assert_includes %w[provider_unapproved models_unapproved endpoint_unapproved], reason
    error = assert_raises(Rag::InterpreterAnthropicExperiment::Error) {
      experiment.execute(
        evidence_root: Dir.mktmpdir, run_id: "partial", approval: partial,
        credential_source: source, transport: StubTransport.new
      )
    }
    assert_equal reason, error.code
  end

  test "an export failure does not report complete evidence" do
    experiment = Rag::InterpreterAnthropicExperiment
    approval = experiment.approval.merge("enabled" => true)
    transport = StubTransport.new {
      Rag::InterpreterAnthropicTransport::Result.new(
        http_status: 200, payload: message_payload(perception("meta")), error_code: nil, error_message: nil
      )
    }
    original = Rag::ValidationCapture.method(:export_capture)
    Rag::ValidationCapture.define_singleton_method(:export_capture) { |*, **| raise IOError, "disk" }
    Dir.mktmpdir do |dir|
      error = assert_raises(Rag::InterpreterAnthropicExperiment::Error) {
        experiment.execute(
          evidence_root: dir, run_id: "export", approval: approval, transport: transport,
          credential_source: -> { "present" }, only: [ "buenas_tardes" ]
        )
      }
      assert_equal "export_failed", error.code
      marker = JSON.parse(Pathname(dir).join("runs", "export", "export_failed.json").read)
      assert_equal false, marker["evidence_complete"]
      assert_not Pathname(dir).join("runs", "export", "capture.json").file?
    end
  ensure
    if original
      Rag::ValidationCapture.define_singleton_method(:export_capture) { |*args, **kwargs|
        original.call(*args, **kwargs)
      }
    end
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

  class StubTransport
    attr_reader :calls

    def initialize(&handler)
      @handler = handler
      @calls = []
    end

    def live?
      false
    end

    def post(endpoint:, headers:, body:, open_timeout:, read_timeout:)
      @calls << {
        endpoint: endpoint, headers: headers, body: body,
        open_timeout: open_timeout, read_timeout: read_timeout
      }
      @handler&.call(@calls.size, body)
    end
  end

  class FakeResponse
    attr_reader :code, :body

    def initialize(code, body)
      @code = code
      @body = body
    end
  end

  class FakeSession
    attr_accessor :use_ssl, :open_timeout, :read_timeout, :max_retries
    attr_reader :request

    def initialize(behavior)
      @behavior = behavior
    end

    def request(req)
      @request = req
      @behavior.call(self, req)
    end
  end

  class FakeHTTP
    attr_reader :sessions

    def initialize(behavior)
      @behavior = behavior
      @sessions = []
    end

    def new(_host, _port)
      session = FakeSession.new(@behavior)
      @sessions << session
      session
    end
  end
end
