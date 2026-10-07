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
end
