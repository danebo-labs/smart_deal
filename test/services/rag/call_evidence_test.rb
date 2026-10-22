# frozen_string_literal: true

require "test_helper"

class Rag::CallEvidenceTest < ActiveSupport::TestCase
  MODEL = "global.anthropic.claude-haiku-4-5-20251001-v1:0"

  test "a fake client stores each call linked by correlation" do
    dir = Dir.mktmpdir
    client = FakeClient.new
    calls = [
      call("query:aaa-111", "PROMPT del turno 1", "ep-1", "historial 1"),
      call("query:bbb-222", "PROMPT del turno 4", "ep-4", "historial 4")
    ]

    folders = calls.map { |spec|
      Rag::CallEvidence.capture_call(
        directory: dir,
        client: client,
        correlation_id: spec[:correlation_id],
        prompt: spec[:prompt],
        state: spec[:state],
        history: spec[:history],
        sources: spec[:sources],
        presenter: ->(raw) { "presentado: #{raw}" },
        model_id: MODEL,
        max_tokens: 30,
        temperature: 0.1
      )
    }
    folders.flatten!

    assert_equal 2, folders.size
    assert_equal calls.pluck(:prompt), client.prompts
    calls.each_with_index do |spec, index|
      folder = folders[index]
      linkage = JSON.parse(folder.join("linkage.json").read)
      assert_equal spec[:correlation_id], linkage["correlation_id"]
      assert_equal "generate_text", linkage["operation"]
      assert_equal 1, linkage["attempt"]
      assert_equal false, linkage["request_absent"]
      assert_equal false, linkage["raw_absent"]
      assert_equal false, linkage["presented_absent"]
      assert_equal spec[:prompt], folder.join("request.txt").read
      assert_equal "RAW #{spec[:correlation_id]}", folder.join("raw_response.txt").read
      assert_equal "presentado: RAW #{spec[:correlation_id]}", folder.join("presented_response.txt").read
      assert_equal Digest::SHA256.hexdigest(spec[:prompt]), linkage["request_sha256"]

      %w[state history sources consumption].each do |name|
        payload = JSON.parse(folder.join("#{name}.json").read)
        assert_equal spec[:correlation_id], payload["correlation_id"]
        assert_equal "generate_text", payload["operation"]
      end
      state = JSON.parse(folder.join("state.json").read)
      history = JSON.parse(folder.join("history.json").read)
      sources = JSON.parse(folder.join("sources.json").read)
      consumption = JSON.parse(folder.join("consumption.json").read)
      assert_equal "observed", state["provenance"]
      assert_equal spec[:state]["episode_id"], state.dig("state", "episode_id")
      assert_equal spec[:history].first["content"], history.dig("history", 0, "content")
      assert_equal spec[:sources].first["sha256"], sources.dig("sources", 0, "sha256")
      assert_equal "manual #{spec[:correlation_id]}", sources.dig("sources", 0, "content")
      assert_equal 20, consumption["input_tokens"]
      assert_equal 5, consumption["output_tokens"]
      assert_equal "calculated", consumption["cost_kind"]
      assert_equal format("%.6f", Rag::LocalPassLedger.price(MODEL, 20, 5)), consumption["cost_usd"]
    end
    assert_not_equal folders[0].join("request.txt").read, folders[1].join("request.txt").read
    assert_not_includes folders[0].join("state.json").read, "ep-4"
    assert_not_includes folders[1].join("history.json").read, "historial 1"
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  test "a capture with both calls keeps interpreter and generation under one correlation" do
    dir = Dir.mktmpdir
    correlation = "query:same-turn"
    events = [
      {
        "kind" => "interpreter_request",
        "result" => "prepared",
        "correlation_id" => correlation,
        "attempt" => 1,
        "message_text" => "clasifica el turno",
        "model_id" => MODEL
      },
      {
        "kind" => "interpreter_raw",
        "result" => "tool_input",
        "correlation_id" => correlation,
        "attempt" => 1,
        "tool_input" => { "move" => "continue" },
        "input_tokens" => 100,
        "output_tokens" => 40
      },
      {
        "kind" => "generate_text",
        "result" => "prepared",
        "correlation_id" => correlation,
        "attempt" => 1,
        "prompt" => "prompt documental",
        "model_id" => MODEL
      },
      {
        "kind" => "generation_result",
        "result" => "returned",
        "correlation_id" => correlation,
        "attempt" => 1,
        "answer" => "respuesta cruda",
        "input_tokens" => 50,
        "output_tokens" => 10
      }
    ]

    folders = Rag::CallEvidence.materialize(
      dir,
      events,
      contexts: {
        "interpreter" => {
          presenter: ->(raw) { raw },
          state: { "episode_id" => "antes" },
          history: [],
          sources: []
        },
        "generate_text" => {
          presented: "respuesta presentada",
          state: { "episode_id" => "despues" },
          history: [ { "role" => "user", "content" => "¿qué sigue?" } ],
          sources: [ { "sha256" => "abc", "content" => "cuerpo" } ]
        }
      }
    )

    assert_equal %w[interpreter generate_text], folders.map { |folder|
      JSON.parse(folder.join("linkage.json").read)["operation"]
    }
    folders.each do |folder|
      assert_equal correlation, JSON.parse(folder.join("linkage.json").read)["correlation_id"]
    end
    assert_equal "clasifica el turno", folders[0].join("request.txt").read
    assert_equal "{\"move\":\"continue\"}", folders[0].join("raw_response.txt").read
    assert_equal "{\"move\":\"continue\"}", folders[0].join("presented_response.txt").read
    assert_equal "prompt documental", folders[1].join("request.txt").read
    assert_equal "respuesta cruda", folders[1].join("raw_response.txt").read
    assert_equal "respuesta presentada", folders[1].join("presented_response.txt").read
    assert_equal "despues", JSON.parse(folders[1].join("state.json").read).dig("state", "episode_id")
    assert_equal "cuerpo", JSON.parse(folders[1].join("sources.json").read).dig("sources", 0, "content")
    assert_equal "observed", JSON.parse(folders[0].join("sources.json").read)["provenance"]
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  test "missing token usage stays unavailable and is not stored as zero" do
    dir = Dir.mktmpdir
    events = [
      {
        "kind" => "generate_text",
        "result" => "prepared",
        "correlation_id" => "query:err",
        "prompt" => "prompt",
        "model_id" => MODEL
      },
      {
        "kind" => "generation_result",
        "result" => "error",
        "correlation_id" => "query:err",
        "answer" => nil,
        "error_class" => "ServiceUnavailableException"
      }
    ]

    folder = Rag::CallEvidence.materialize(dir, events, contexts: {}).sole
    consumption = JSON.parse(folder.join("consumption.json").read)

    assert_equal "unavailable", consumption["cost_kind"]
    assert_nil consumption["cost_usd"]
    assert_nil consumption["input_tokens"]
    assert_equal true, JSON.parse(folder.join("linkage.json").read)["raw_absent"]
    assert_equal "uncaptured", JSON.parse(folder.join("state.json").read)["provenance"]
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  test "a fake client writes the companion capture before any paid call" do
    dir = Dir.mktmpdir
    client = FakeClient.new
    validation = {
      "accepted" => true,
      "reasons" => [],
      "signals" => [ { "code" => "S2", "questions" => 1 } ],
      "quotes" => [ { "text" => "cuando el cierre es normal", "source" => 1, "position" => 12 } ]
    }
    sources = [
      { "index" => 1, "sha256" => Digest::SHA256.hexdigest("cuerpo uno"), "content" => "cuerpo uno" },
      { "index" => 2, "sha256" => Digest::SHA256.hexdigest("cuerpo dos"), "content" => "cuerpo dos" }
    ]

    folder = Rag::CallEvidence.capture_call(
      directory: dir,
      client: client,
      correlation_id: "query:companion",
      prompt: "Mensaje del técnico:\n¿qué sigue?",
      system: "Responde en castellano, en una sola respuesta integrada.",
      state: { "episode_id" => "ep-after" },
      history: [ { "role" => "user", "content" => "turno previo" } ],
      sources: sources,
      presenter: ->(raw) { "presentado: #{raw}" },
      model_id: MODEL,
      max_tokens: 3000,
      temperature: 0.1,
      validation: validation,
      prompt_reply: "presentado: RAW query:companion",
      prompt_reply_truncated: false,
      state_before: { "episode_id" => "ep-before" },
      state_after: { "episode_id" => "ep-after" },
      raw_message: "¿qué sigue?",
      retrieval_query: "consulta compuesta"
    ).sole

    assert_equal "Responde en castellano, en una sola respuesta integrada.", folder.join("system.txt").read
    assert_equal "Mensaje del técnico:\n¿qué sigue?", folder.join("request.txt").read
    parameters = JSON.parse(folder.join("parameters.json").read)
    assert_equal MODEL, parameters["model_id"]
    assert_equal 3000, parameters["max_tokens"]
    assert_in_delta 0.1, parameters["temperature"]
    assert_equal "bedrock-2023-05-31", parameters["anthropic_version"]
    provider = JSON.parse(folder.join("provider_response.json").read)
    assert_equal "end_turn", provider["stop_reason"]
    assert_equal "RAW query:companion", folder.join("extracted_text.txt").read
    assert_equal "RAW query:companion", folder.join("raw_response.txt").read
    assert_equal validation, JSON.parse(folder.join("validation.json").read)
    assert_equal "presentado: RAW query:companion", folder.join("presented_response.txt").read
    reply = JSON.parse(folder.join("prompt_reply.json").read)
    assert_equal "presentado: RAW query:companion", reply["prompt_reply"]
    assert_equal false, reply["prompt_reply_truncated"]
    assert_equal "ep-before", JSON.parse(folder.join("state_before.json").read)["episode_id"]
    assert_equal "ep-after", JSON.parse(folder.join("state_after.json").read)["episode_id"]
    assert_equal "turno previo", JSON.parse(folder.join("history.json").read).dig("history", 0, "content")
    stored_sources = JSON.parse(folder.join("sources.json").read).fetch("sources")
    assert_equal [ "cuerpo uno", "cuerpo dos" ], stored_sources.pluck("content")
    assert_equal sources.pluck("sha256"), stored_sources.pluck("sha256")
    assert_equal "¿qué sigue?", folder.join("message.txt").read
    assert_equal "consulta compuesta", folder.join("query.txt").read
    consumption = JSON.parse(folder.join("consumption.json").read)
    assert_equal "end_turn", consumption["stop_reason"]
    assert_equal 12, consumption["latency_ms"]
    assert_equal 20, consumption["input_tokens"]
    assert_equal 5, consumption["output_tokens"]
    assert_equal "calculated", consumption["cost_kind"]
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  private

  def call(correlation_id, prompt, episode_id, history)
    {
      correlation_id: correlation_id,
      prompt: prompt,
      state: { "episode_id" => episode_id },
      history: [ { "role" => "user", "content" => history } ],
      sources: [ { "sha256" => Digest::SHA256.hexdigest(correlation_id), "content" => "manual #{correlation_id}" } ]
    }
  end

  class FakeClient
    attr_reader :prompts

    def initialize
      @prompts = []
    end

    def generate_text(prompt, model_id: nil, max_tokens: nil, temperature: nil, tracking: nil, system: nil)
      correlation_id = tracking[:correlation_id]
      @prompts << prompt
      Rag::ValidationCapture.attempt = 1
      prepared = {
        "stage" => "generate",
        "result" => "prepared",
        "operation" => "generate_text",
        "prompt" => prompt,
        "model_id" => model_id,
        "max_tokens" => max_tokens,
        "temperature" => temperature,
        "anthropic_version" => "bedrock-2023-05-31",
        "correlation_id" => correlation_id
      }
      prepared["system"] = system if system.present?
      Rag::ValidationCapture.record("generate_text", prepared)
      text = "RAW #{correlation_id}"
      Rag::ValidationCapture.record(
        "generation_result",
        "stage" => "generate",
        "result" => "returned",
        "operation" => "generate_text",
        "answer" => text,
        "input_tokens" => 20,
        "output_tokens" => 5,
        "stop_reason" => "end_turn",
        "latency_ms" => 12,
        "provider_response" => { "stop_reason" => "end_turn", "content" => [ { "text" => text } ] },
        "model_id" => model_id,
        "max_tokens" => max_tokens,
        "temperature" => temperature,
        "correlation_id" => correlation_id
      )
      text
    end
  end
end
