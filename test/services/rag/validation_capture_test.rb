# frozen_string_literal: true

require "test_helper"

class Rag::ValidationCaptureTest < ActiveSupport::TestCase
  test "an inactive capture records nothing" do
    Rag::ValidationCapture.record("retrieve", { "retrieval_query" => { "text" => "consulta" } })

    assert_nil Thread.current[:rag_validation_capture]
  end

  test "a retrieve request keeps the filter and drops a secret" do
    service = BedrockRagService.new(account: accounts(:legacy))
    client = Object.new
    client.define_singleton_method(:retrieve) { |_params| Struct.new(:retrieval_results).new([]) }
    service.instance_variable_set(:@client, client)
    filter = { "equals" => { "key" => "account_id", "value" => "1" } }

    events = Rag::ValidationCapture.capture do
      Rag::ValidationCapture.correlation = "stage2:a:t01:query"
      service.send(:retrieve_with_retry, {
        retrieval_query: { text: "consulta de prueba" },
        retrieval_configuration: {
          vector_search_configuration: { number_of_results: 8, filter: filter }
        },
        access_key_id: "AKIATESTKEY12"
      })
    end

    event = events.find { |row| row["kind"] == "retrieve" }
    assert_equal "stage2:a:t01:query", event["correlation_id"]
    assert_equal "consulta de prueba", event.dig("retrieval_query", "text")
    assert_equal 8, event.dig("retrieval_configuration", "vector_search_configuration", "number_of_results")
    assert_equal "1", event.dig("retrieval_configuration", "vector_search_configuration", "filter", "equals", "value")
    assert_nil event["access_key_id"]
    assert_not_includes event.to_s, "AKIATESTKEY12"
  end

  test "max_tokens stays and a session token does not" do
    payload = Rag::ValidationCapture.sanitize(
      "max_tokens" => 3000,
      "input_tokens" => 12,
      "token_source" => "provider_usage",
      "session_token" => "secret-session",
      "access_key_id" => "AKIATESTKEY12",
      "prompt" => "consulta AKIASECRETKEY1"
    )

    assert_equal 3000, payload["max_tokens"]
    assert_equal 12, payload["input_tokens"]
    assert_equal "provider_usage", payload["token_source"]
    assert_nil payload["session_token"]
    assert_nil payload["access_key_id"]
    assert_equal "consulta [redacted]", payload["prompt"]
  end

  test "direct generation records the prompt and max_tokens only inside a capture" do
    client = BedrockClient.new
    calls = 0
    runtime = Object.new
    runtime.define_singleton_method(:invoke_model) do |_params|
      calls += 1
      Struct.new(:body).new(StringIO.new({ "content" => [ { "text" => "ok" } ], "usage" => { "input_tokens" => 0 } }.to_json))
    end
    runtime.define_singleton_method(:converse) { |params| params }
    client.instance_variable_set(:@client, runtime)

    client.generate_text("fuera de captura", max_tokens: 3000, temperature: 0)
    assert_nil Thread.current[:rag_validation_capture]
    assert_equal 1, calls

    events = Rag::ValidationCapture.capture do
      Rag::ValidationCapture.correlation = "stage2:a:t01:query"
      client.generate_text("prompt de guidance", max_tokens: 3000, temperature: 0)
      client.converse_message(
        "model_id" => "global.anthropic.claude-haiku-4-5",
        "inference_config" => { "max_tokens" => 3000, "temperature" => 0 },
        "messages" => [ { "role" => "user", "content" => [ { "text" => "contrato de publicacion" } ] } ],
        "session_token" => "secret-session"
      )
    end

    generated = events.find { |row| row["kind"] == "generate_text" }
    converse = events.find { |row| row["kind"] == "converse" }
    assert_equal 2, calls
    assert_equal "prompt de guidance", generated["prompt"]
    assert_equal 3000, generated["max_tokens"]
    assert_equal "stage2:a:t01:query", generated["correlation_id"]
    assert_equal 3000, converse.dig("inference_config", "max_tokens")
    assert_equal "contrato de publicacion", converse.dig("messages", 0, "content", 0, "text")
    assert_nil converse["session_token"]
  end

  test "the interpreter tool input is stored before perception changes it" do
    turn = "Era código 18, no 8. La guía no tiene obstrucción."
    client = Struct.new(:responses) do
      def converse(_params)
        tool = Struct.new(:name, :input).new("turn_perception", {
          "move" => "unclear",
          "assertions" => [],
          "observations" => [],
          "pending_resolution" => nil,
          "clarification_target" => "correction_target"
        })
        block = Struct.new(:tool_use).new(tool)
        message = Struct.new(:content).new([ block ])
        output = Struct.new(:message).new(message)
        usage = Struct.new(:input_tokens, :output_tokens).new(0, 0)
        Struct.new(:output, :usage).new(output, usage)
      end
    end.new

    result = nil
    events = Rag::ValidationCapture.capture do
      Rag::ValidationCapture.correlation = "stage2:a:t05"
      result = Rag::TurnInterpreter.call(
        turn: turn,
        episode: Rag::ActiveEpisode.new,
        viewer_account: nil,
        correlation_id: "stage2:a:t05",
        client: client
      )
    end

    raw = events.find { |row| row["kind"] == "interpreter_raw" }
    assert_equal [], raw.dig("tool_input", "observations")
    assert_equal "unclear", raw.dig("tool_input", "move")
    assert_equal "stage2:a:t05", raw["correlation_id"]
    assert_includes result.perception.observations, "La guía no tiene obstrucción"
  end

  test "scope labels are generic and a nested capture does not leak them" do
    inner = nil
    outer = Rag::ValidationCapture.capture do
      Rag::ValidationCapture.bind(sha: "abc", session_id: 7, episode_id: "ep-1", correlation_root: "root", fixture: "journey-a")
      Rag::ValidationCapture.record("outer", { "correlation_id" => "root:query" })
      inner = Rag::ValidationCapture.capture do
        Rag::ValidationCapture.record("inner", {})
      end
      Rag::ValidationCapture.record("after", {})
    end

    stamped = outer.find { |row| row["kind"] == "outer" }
    assert_equal "abc", stamped["sha"]
    assert_equal 7, stamped["session_id"]
    assert_equal "ep-1", stamped["episode_id"]
    assert_equal "root", stamped["correlation_root"]
    assert_equal "root:query", stamped["correlation_id"]
    assert_nil stamped["fixture"]
    assert_nil outer.find { |row| row["kind"] == "inner" }
    assert_nil inner.first["episode_id"]
    assert_equal "inner", inner.first["kind"]
    assert_equal "ep-1", outer.find { |row| row["kind"] == "after" }["episode_id"]
    assert_nil Thread.current[:rag_validation_capture]
  end

  test "a signed url is reduced to its path and max_tokens stays" do
    payload = Rag::ValidationCapture.sanitize(
      "uri" => "https://bucket.s3.amazonaws.com/manuals/sheet.pdf?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIATESTKEY12",
      "max_tokens" => 3000
    )

    assert_equal "https://bucket.s3.amazonaws.com/manuals/sheet.pdf", payload["uri"]
    assert_equal 3000, payload["max_tokens"]
    assert_not_includes payload.to_s, "AKIATESTKEY12"
  end

  test "inactive perception stores nothing and stays equal to a second pass" do
    first = build_correction_perception
    second = build_correction_perception

    assert_equal first, second
    assert_nil Thread.current[:rag_validation_capture]
  end

  test "an open capture records the rule that rewrites a stated fault code" do
    events = Rag::ValidationCapture.capture do
      Rag::ValidationCapture.correlation = "turn-1"
      build_correction_perception
    end

    applied = events.find { |row| row["kind"] == "perception_applied" }
    assert_equal "interpreter_raw", applied["links"]
    assert_equal "turn-1", applied["correlation_id"]
    assert_equal "correct", applied["move"]
    assert applied["adjustments"].any? { |row| row["reason"] == "explicit_fault_codes" && row["datum"] == "fault_code" }
    assert_nil applied["tool_input"]
    assert_nil Thread.current[:rag_validation_capture]
  end

  test "a route decision names its condition and an internal finish does not" do
    perception = perception_result("meta")
    idle = Rag::RoutePolicy.call(previous: Rag::ActiveEpisode.new, perception: perception, focus_count: 0)
    events = Rag::ValidationCapture.capture do
      active = Rag::RoutePolicy.call(previous: Rag::ActiveEpisode.new, perception: perception, focus_count: 0)
      assert_equal idle, active
      policy = Rag::RoutePolicy.new(
        previous: Rag::ActiveEpisode.new, perception: nil, focus_count: 0,
        focus_document_ids: [], focus_uris: [], locale: :es
      )
      policy.send(:fallback_query, "la puerta no cierra", nil, nil)
    end

    decision = events.find { |row| row["kind"] == "route_decision" }
    assert_equal "meta", decision["route"]
    assert_equal "move_meta", decision["condition"]
    assert_equal false, decision["retrieval"]
    assert_equal 1, events.count { |row| row["kind"] == "route_decision" }
  end

  test "a meta understanding returns before any retrieve" do
    understanding = Rag::RoutePolicy.call(
      previous: Rag::ActiveEpisode.new,
      perception: perception_result("meta"),
      focus_count: 0
    )
    episode_turn = Struct.new(:understanding).new(understanding)
    result = nil
    events = Rag::ValidationCapture.capture do
      result = RagValidationCaptureHost.new(accounts(:legacy)).send(
        :execute_rag_query,
        "hola",
        episode_turn: episode_turn,
        correlation_id: "cid-meta",
        response_locale: :es
      )
    end

    exit_event = events.find { |row| row["kind"] == "route_exit" && row["exit"] == "meta" }
    assert_equal "move_meta", exit_event["condition"]
    assert_equal "cid-meta", exit_event["correlation_id"]
    assert_equal "meta", result.generation_mode
    assert_equal false, result.model_invoked
    assert_nil events.find { |row| row["kind"] == "retrieve" }
  end

  test "retrieval rows keep accepted text and mark a missing score unavailable" do
    service = BedrockRagService.new(account: accounts(:legacy))
    account_id = accounts(:legacy).id.to_s
    chunks = [
      {
        content: "Seguridad Puerta nivel 1",
        score: 0.42,
        location_uri: "s3://bucket/bulk_chunks/1/abc/chunk_p5_1.txt",
        metadata: {
          "account_id" => account_id,
          "canonical_name" => "Elemont MH",
          "page_number" => "5",
          "document_id" => "doc-5"
        }
      },
      { content: "sin metadata", score: nil, location_uri: "s3://bucket/a.txt", metadata: nil }
    ]

    kept, rejected = service.send(:select_publishable_chunks, chunks, probe: { query: "puerta", stage: "publication_gate" })
    assert_equal 1, kept.size
    assert_equal 1, rejected
    assert_nil Thread.current[:rag_validation_capture]

    events = Rag::ValidationCapture.capture do
      service.send(:select_publishable_chunks, chunks, probe: { query: "puerta", correlation_id: "cid-r", stage: "publication_gate" })
    end
    result = events.find { |row| row["kind"] == "retrieval_results" }
    accepted = result["rows"].find { |row| row["decision"] == "accepted" }
    refused = result["rows"].find { |row| row["decision"] == "rejected" }
    assert_equal "retrieved", result["role"]
    assert_equal "puerta", result["query"]
    assert_equal "cid-r", result["correlation_id"]
    assert_equal "Elemont MH", accepted["document"]
    assert_equal "5", accepted["page"]
    assert_equal "doc-5", accepted["document_id"]
    assert_equal 0.42, accepted["score"]
    assert_equal "Seguridad Puerta nivel 1", accepted["text"]
    assert_equal "viewer_account", accepted["reason"]
    assert_equal "metadata_unreadable", refused["reason"]
    assert_equal "unavailable", refused["score"]
    assert_equal "unavailable", refused["document"]
  end

  test "an aurora retry is identified and does not add a retrieve" do
    service = BedrockRagService.new(account: accounts(:legacy))
    calls = 0
    client = Object.new
    client.define_singleton_method(:retrieve) do |_params|
      calls += 1
      if calls.odd?
        raise Aws::BedrockAgentRuntime::Errors::ServiceError.new(
          nil,
          "The Aurora DB instance db-X is resuming after being auto-paused."
        )
      end
      Struct.new(:retrieval_results).new([])
    end
    service.instance_variable_set(:@client, client)
    original = Bedrock::AuroraColdStartRetry.method(:sleep_for)
    Bedrock::AuroraColdStartRetry.define_singleton_method(:sleep_for) { |_seconds| }

    service.send(:retrieve_with_retry, { retrieval_query: { text: "consulta" } })
    assert_nil Thread.current[:rag_validation_capture]
    assert_equal 2, calls

    events = Rag::ValidationCapture.capture do
      service.send(:retrieve_with_retry, { retrieval_query: { text: "consulta" } })
    end
    retry_event = events.find { |row| row["kind"] == "retry" }
    assert_equal "aurora_cold_start", retry_event["reason"]
    assert_equal 1, retry_event["attempt"]
    assert_equal 15, retry_event["delay_seconds"]
    assert_equal 4, calls
  ensure
    Bedrock::AuroraColdStartRetry.define_singleton_method(:sleep_for, original) if original
  end

  test "retrieve and generate records the template without sending that label" do
    service = BedrockRagService.new(account: accounts(:legacy))
    received = nil
    calls = 0
    client = Object.new
    client.define_singleton_method(:retrieve_and_generate) do |params|
      calls += 1
      received = params
      Struct.new(:citations, :output).new(nil, nil)
    end
    service.instance_variable_set(:@client, client)
    params = { input: { text: "q $search_results$" }, max_tokens: 200 }

    events = Rag::ValidationCapture.capture do
      service.send(:retrieve_and_generate_with_retry, params)
    end

    request = events.find { |row| row["kind"] == "retrieve_and_generate" }
    result = events.find { |row| row["kind"] == "generation_result" }
    assert_equal 1, calls
    assert_nil received[:documentary_context]
    assert_nil received["documentary_context"]
    assert_equal 200, received[:max_tokens]
    assert_equal "template", request["documentary_context"]
    assert_equal "placeholders_are_not_resolved_chunks", request["documentary_context_note"]
    assert_equal "unavailable", result["full_result_set"]
    assert_equal "unavailable", result["answer"]
  end

  test "generation marks a template prompt and a resolved prompt without another invoke" do
    client = BedrockClient.new
    calls = 0
    runtime = Object.new
    runtime.define_singleton_method(:invoke_model) do |_params|
      calls += 1
      Struct.new(:body).new(StringIO.new({ "content" => [ { "text" => "respuesta" } ], "usage" => { "input_tokens" => 4 } }.to_json))
    end
    client.instance_variable_set(:@client, runtime)

    events = Rag::ValidationCapture.capture do
      client.generate_text("prompt con $search_results$", max_tokens: 300, temperature: 0, tracking: { attempt: 2, correlation_id: "cid-g" })
      client.generate_text("prompt resuelto", max_tokens: 300, temperature: 0)
    end

    generated = events.select { |row| row["kind"] == "generate_text" }
    results = events.select { |row| row["kind"] == "generation_result" }
    assert_equal 2, calls
    assert_equal "template", generated[0]["documentary_context"]
    assert_equal "resolved", generated[1]["documentary_context"]
    assert_equal 300, generated[0]["max_tokens"]
    assert_equal "respuesta", results[0]["answer"]
    assert_equal 4, results[0]["input_tokens"]
    assert_equal "unavailable", results[0]["output_tokens"]
    assert_nil results[0]["error_class"]
    assert_equal 2, results[0]["attempt"]
    assert_equal "cid-g", results[0]["correlation_id"]
    assert_equal "resolved", results[1]["documentary_context"]
  end

  test "a problem that exceeds the cap records the omitted observation" do
    trace = { truncated: false }
    text = nil
    events = Rag::ValidationCapture.capture do
      text = SessionContextBuilder.send(:fit_problem, "", [], [], [ "x" * 700 ], [], trace)
    end
    idle_trace = { truncated: false }
    idle = SessionContextBuilder.send(:fit_problem, "", [], [], [ "x" * 700 ], [], idle_trace)

    fit = events.find { |row| row["kind"] == "context_fit" }
    assert_equal text, idle
    assert_equal "problem", fit["part"]
    assert_equal true, fit["truncated"]
    assert fit["omitted"].any? { |row| row["part"] == "observation" }
    assert_nil idle_trace[:omitted]
    assert_operator text.length, :<=, SessionContextBuilder::MAX_PROBLEM_CHARS
  end

  test "guidance truncation records each omitted unit and returns the same text" do
    context = "## Active Field Problem\nGoal: #{'x' * 3000}\n"
    args = { question: "la puerta no cierra", identity: nil, session_context: context, labels: [], locale: :es }
    idle = Rag::CompanionGuidanceContext.new(**args).to_s
    events = Rag::ValidationCapture.capture do
      active = Rag::CompanionGuidanceContext.new(**args).to_s
      assert_equal idle, active
    end

    fit = events.find { |row| row["kind"] == "context_fit" }
    goal = fit["omitted"].find { |row| row["part"] == "problem" }
    assert_equal "guidance", fit["part"]
    assert_equal true, fit["truncated"]
    assert_equal idle.length, fit["chars"]
    assert_operator fit["chars"], :<=, Rag::CompanionGuidanceContext::MAX_CHARS
    assert_equal "Active problem: #{'x' * 3000}", goal["text"]
    assert_not_includes idle, "Active problem:"
    assert_not fit["omitted"].any? { |row| row["part"] == "tail" }
  end

  test "episode delta records changed fields and skips an unchanged episode" do
    before = Rag::ActiveEpisode.new
    before.episode_id = "ep-1"
    before.goal = { "text" => "puerta" }
    before.facts = { "fault_code" => { "status" => "known", "value" => "8" } }
    before.observations = [ { "text" => "no cierra" } ]
    before.rejected = [ { "slot" => "fault_code", "value" => "8" } ]
    before.pending_question = { "type" => "controller" }
    after = before.fork
    after.goal = { "text" => "imán" }
    after.facts = { "fault_code" => { "status" => "known", "value" => "18" } }
    after.observations = [ { "text" => "no magnetiza" } ]
    after.rejected = []
    after.pending_question = { "type" => "fault_code" }

    events = Rag::ValidationCapture.capture do
      Rag::EpisodeDelta.record(before, after, correlation_id: "cid-e")
      Rag::EpisodeDelta.record(after, after.fork, correlation_id: "cid-e")
    end
    changed = events.find { |row| row["changed"] == true }
    unchanged = events.find { |row| row["changed"] == false }

    assert_equal "imán", changed.dig("goal", "after")
    assert_equal [ "fault_code:known:18" ], changed.dig("facts", "added")
    assert_equal [ "fault_code:known:8" ], changed.dig("facts", "removed")
    assert_equal [ "no magnetiza" ], changed.dig("observations", "added")
    assert_equal [ "no cierra" ], changed.dig("observations", "removed")
    assert_equal [ "fault_code:8" ], changed.dig("rejected", "removed")
    assert changed["pending_question"]["before"] != changed["pending_question"]["after"]
    assert_nil changed["state"]
    assert_nil changed["v"]
    assert_equal "cid-e", changed["correlation_id"]
    assert_equal false, unchanged["changed"]
    assert_nil unchanged["goal"]
    assert_nil unchanged["observations"]
    Rag::EpisodeDelta.record(before, after)
    assert_nil Thread.current[:rag_validation_capture]
  end

  test "two turns in one capture keep their correlation and do not leak attempt" do
    events = Rag::ValidationCapture.capture do
      Rag::ValidationCapture.bind(correlation_root: "root", session_id: 3)
      Rag::ValidationCapture.correlation = "outer"
      Rag::ValidationCapture.attempt = 9
      Rag::ValidationCapture.with_turn("turn-a") do
        Rag::TurnInterpreter.call(
          turn: "hola",
          episode: Rag::ActiveEpisode.new,
          viewer_account: nil,
          correlation_id: "turn-a",
          client: meta_perception_client(attempt: 1)
        )
        Rag::ValidationCapture.record("later-a", {})
      end
      Rag::ValidationCapture.record("between", {})
      assert_raises(RuntimeError) do
        Rag::ValidationCapture.with_turn("turn-lost") do
          Rag::ValidationCapture.attempt = 4
          raise "corte"
        end
      end
      Rag::ValidationCapture.with_turn("turn-b") do
        Rag::TurnInterpreter.call(
          turn: "sigo",
          episode: Rag::ActiveEpisode.new,
          viewer_account: nil,
          correlation_id: "turn-b",
          client: meta_perception_client
        )
        Rag::ValidationCapture.record("later-b", {})
      end
      Rag::ValidationCapture.record("after", {})
    end

    raw_a = events.find { |row| row["kind"] == "interpreter_raw" && row["correlation_id"] == "turn-a" }
    applied_a = events.find { |row| row["kind"] == "perception_applied" && row["correlation_id"] == "turn-a" }
    raw_b = events.find { |row| row["kind"] == "interpreter_raw" && row["correlation_id"] == "turn-b" }
    applied_b = events.find { |row| row["kind"] == "perception_applied" && row["correlation_id"] == "turn-b" }
    assert_equal "meta", raw_a.dig("tool_input", "move")
    assert_equal "meta", applied_a["move"]
    assert_equal 1, applied_a["attempt"]
    assert_equal "root", applied_a["correlation_root"]
    assert_equal 3, applied_a["session_id"]
    assert_equal "turn-a", events.find { |row| row["kind"] == "later-a" }["correlation_id"]
    assert_nil events.find { |row| row["kind"] == "later-a" }["attempt"]
    assert_equal "meta", applied_b["move"]
    assert_nil applied_b["attempt"]
    assert_nil raw_b["attempt"]
    assert_equal "root", applied_b["correlation_root"]
    assert_equal "turn-b", events.find { |row| row["kind"] == "later-b" }["correlation_id"]
    %w[between after].each do |kind|
      marker = events.find { |row| row["kind"] == kind }
      assert_equal "outer", marker["correlation_id"]
      assert_equal 9, marker["attempt"]
      assert_equal "root", marker["correlation_root"]
    end
    assert_nil events.find { |row| row["correlation_id"] == "turn-lost" }
    assert_nil Thread.current[:rag_validation_correlation]
    assert_nil Thread.current[:rag_validation_attempt]
  end

  test "a remote failure without retry records the terminal error and keeps the exception" do
    service = BedrockRagService.new(account: accounts(:legacy))
    calls = 0
    message = "denied https://bucket.s3.amazonaws.com/manual.pdf?X-Amz-Algorithm=AWS4&X-Amz-Credential=AKIATESTKEY12"
    client = Object.new
    client.define_singleton_method(:retrieve) do |_params|
      calls += 1
      raise Aws::BedrockAgentRuntime::Errors::ServiceError.new(nil, message)
    end
    service.instance_variable_set(:@client, client)

    assert_raises(Aws::BedrockAgentRuntime::Errors::ServiceError) do
      service.send(:retrieve_with_retry, { retrieval_query: { text: "consulta" } })
    end
    assert_equal 1, calls
    assert_nil Thread.current[:rag_validation_capture]

    error = nil
    events = Rag::ValidationCapture.capture do
      Rag::ValidationCapture.correlation = "cid-fail"
      Rag::ValidationCapture.attempt = 2
      error = assert_raises(Aws::BedrockAgentRuntime::Errors::ServiceError) do
        service.send(:retrieve_with_retry, { retrieval_query: { text: "consulta" } })
      end
    end

    terminal = events.find { |row| row["kind"] == "terminal_error" }
    assert_equal 2, calls
    assert_equal Aws::BedrockAgentRuntime::Errors::ServiceError, error.class
    assert_equal message, error.message
    assert_includes error.backtrace.first, "validation_capture_test"
    assert_equal "retrieve", terminal["operation"]
    assert_equal "cid-fail", terminal["correlation_id"]
    assert_equal 2, terminal["attempt"]
    assert_equal 1, terminal["transport_attempt"]
    assert_equal error.class.name, terminal["error_class"]
    assert_not_includes terminal["reason"], "AKIA"
    assert_not_includes terminal["reason"], "X-Amz-"
    assert_nil Thread.current[:rag_validation_capture]
  end

  test "exhausted aurora retries record the terminal transport attempt without extra calls" do
    service = BedrockRagService.new(account: accounts(:legacy))
    calls = 0
    message = "The Aurora DB instance db-X is resuming after being auto-paused."
    client = Object.new
    client.define_singleton_method(:retrieve_and_generate) do |_params|
      calls += 1
      raise Aws::BedrockAgentRuntime::Errors::ServiceError.new(nil, message)
    end
    service.instance_variable_set(:@client, client)
    original = Bedrock::AuroraColdStartRetry.method(:sleep_for)
    Bedrock::AuroraColdStartRetry.define_singleton_method(:sleep_for) { |_seconds| }

    assert_raises(Aws::BedrockAgentRuntime::Errors::ServiceError) do
      service.send(:retrieve_and_generate_with_retry, { input: { text: "q" }, max_tokens: 20 })
    end
    assert_equal 4, calls
    assert_nil Thread.current[:rag_validation_capture]

    error = nil
    events = Rag::ValidationCapture.capture do
      Rag::ValidationCapture.correlation = "cid-aurora"
      Rag::ValidationCapture.attempt = 1
      error = assert_raises(Aws::BedrockAgentRuntime::Errors::ServiceError) do
        service.send(:retrieve_and_generate_with_retry, { input: { text: "q" }, max_tokens: 20 })
      end
    end

    terminal = events.find { |row| row["kind"] == "terminal_error" }
    assert_equal 8, calls
    assert_equal Aws::BedrockAgentRuntime::Errors::ServiceError, error.class
    assert_equal message, error.message
    assert_includes error.backtrace.first, "validation_capture_test"
    assert_equal "retrieve_and_generate", terminal["operation"]
    assert_equal "cid-aurora", terminal["correlation_id"]
    assert_equal 1, terminal["attempt"]
    assert_equal 4, terminal["transport_attempt"]
    assert_equal 3, events.count { |row| row["kind"] == "retry" }
    assert_nil Thread.current[:rag_validation_capture]
  ensure
    Bedrock::AuroraColdStartRetry.define_singleton_method(:sleep_for, original) if original
  end

  private

  def meta_perception_client(attempt: nil)
    Struct.new(:marked_attempt) do
      def converse(_params)
        Rag::ValidationCapture.attempt = marked_attempt if marked_attempt
        tool = Struct.new(:name, :input).new("turn_perception", {
          "move" => "meta",
          "assertions" => [],
          "observations" => [],
          "pending_resolution" => nil,
          "clarification_target" => nil
        })
        block = Struct.new(:tool_use).new(tool)
        message = Struct.new(:content).new([ block ])
        output = Struct.new(:message).new(message)
        usage = Struct.new(:input_tokens, :output_tokens).new(0, 0)
        Struct.new(:output, :usage).new(output, usage)
      end
    end.new(attempt)
  end

  def perception_result(move)
    Rag::TurnPerception::Result.new(
      valid: true, move: move, observations: [], pending_resolution: nil, clarification_target: nil,
      identities: [], ambiguities: [], field_rejections: [], catalog_disagreements: [], invalid_reason: nil
    )
  end

  def build_correction_perception
    Rag::TurnPerception.build(
      {
        "move" => "report",
        "assertions" => [],
        "observations" => [ "La puerta no cierra" ],
        "pending_resolution" => nil,
        "clarification_target" => nil
      },
      turn: "Era código 18, no 8. La puerta no cierra.",
      episode: Rag::ActiveEpisode.new,
      catalog: nil,
      viewer_account: accounts(:legacy)
    )
  end
end

class RagValidationCaptureHost
  include RagQueryConcern

  def initialize(account)
    @current_account = account
  end

  attr_reader :current_account
end
