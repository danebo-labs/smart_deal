# frozen_string_literal: true

require "test_helper"
require "stringio"

class Rag::CapturedGenerationReplayTest < ActiveSupport::TestCase
  class ServiceUnavailableException < StandardError; end
  class AccessDeniedException < StandardError; end
  class ResourceNotFoundException < StandardError; end

  setup do
    @dir = Dir.mktmpdir("captured-generation")
    @previous = %w[RAG_LOCAL_PASS_GUARD RAG_LOCAL_PASS_CALL_CAP RAG_LOCAL_PASS_COST_CAP_USD AWS_MAX_ATTEMPTS].index_with { |key| ENV[key] }
    @previous.each_key { |key| ENV.delete(key) }
    Rag::LocalPassLedger.reset!
  end

  teardown do
    @previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    Rag::LocalPassLedger.reset!
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  test "a captured user message keeps its parameters and omits a missing system" do
    prepared = Rag::CapturedGenerationReplay.prepare(**capture(prompt: "texto del técnico"))

    assert_nil prepared.system
    assert_equal 0.1, prepared.temperature
    assert_equal 3000, prepared.max_tokens
    assert_equal "bedrock-2023-05-31", prepared.anthropic_version
    assert_equal [ { "role" => "user" } ], prepared.messages
    parsed = JSON.parse(prepared.body_json)
    assert_equal %w[anthropic_version max_tokens messages temperature], parsed.keys.sort
    assert_equal "texto del técnico", parsed.dig("messages", 0, "content")
    assert_not parsed.key?("system")
    assert_not parsed.key?("model")
  end

  test "the invoke body matches BedrockClient and the model id stays outside it" do
    prepared = Rag::CapturedGenerationReplay.prepare(**capture(prompt: "mismo cuerpo"))
    client, calls = fake_client([ ok_response("respuesta") ])
    spend = spend_book

    sample = Rag::CapturedGenerationReplay.run_sample(
      prepared: prepared,
      model_id: Rag::CapturedGenerationReplay::SONNET_45_GLOBAL,
      client: client,
      spend: spend,
      output_dir: File.join(@dir, "out"),
      run_id: "replay-test"
    )

    assert_equal "returned", sample.status
    assert_equal Rag::CapturedGenerationReplay::SONNET_45_GLOBAL, calls.first[:model_id]
    assert_equal prepared.body_json, calls.first[:body]
    assert_equal prepared.body_sha256, sample.body_sha256
    assert_equal "respuesta", File.read(File.join(@dir, "out", "attempt-1", "answer.txt"))
  end

  test "two model ids keep one body hash" do
    prepared = Rag::CapturedGenerationReplay.prepare(**capture(prompt: "entrada común"))
    haiku = body_for(prepared, Rag::CapturedGenerationReplay::HAIKU_45)
    sonnet = body_for(prepared, Rag::CapturedGenerationReplay::SONNET_45_GLOBAL)

    assert_equal haiku, sonnet
    assert_equal prepared.body_sha256, Digest::SHA256.hexdigest(haiku)
  end

  test "a transient error is retried and a configuration error is not" do
    prepared = Rag::CapturedGenerationReplay.prepare(**capture(prompt: "reintento"))
    client, calls = fake_client([
      ServiceUnavailableException.new("Bedrock is unable to process your request."),
      ok_response("segunda")
    ])

    sample = replay_sample(prepared, client)
    assert_equal "returned", sample.status
    assert_equal 2, sample.attempts
    assert_equal 2, calls.size
    assert_equal "segunda", sample.text

    denied, denied_calls = fake_client([ AccessDeniedException.new("denied") ])
    denied_sample = replay_sample(prepared, denied, output: "denied")
    assert_equal "error", denied_sample.status
    assert_equal 1, denied_sample.attempts
    assert_equal 1, denied_calls.size
    assert_equal "configuration", Rag::CapturedGenerationReplay.error_kind(denied_sample.error_class)
  end

  test "the assignment ceiling stops the call before the client" do
    prepared = Rag::CapturedGenerationReplay.prepare(**capture(prompt: "x" * 20_000))
    client, calls = fake_client([ ok_response("no") ])
    book = spend_book(cost_cap: "0.001")

    assert_raises(Rag::AssignmentSpend::Stop) do
      Rag::CapturedGenerationReplay.run_sample(
        prepared: prepared,
        model_id: Rag::CapturedGenerationReplay::SONNET_45_GLOBAL,
        client: client,
        spend: book,
        output_dir: File.join(@dir, "blocked"),
        run_id: "replay-test"
      )
    end

    assert_empty calls
    assert_equal 0, book.snapshot["attempts"]
    assert_equal 1, book.snapshot["blocked"]
  end

  test "a missing sonnet profile can move to the next id once" do
    prepared = Rag::CapturedGenerationReplay.prepare(**capture(prompt: "perfil"))
    client, calls = fake_client([
      ResourceNotFoundException.new("missing profile"),
      ok_response("con el perfil us")
    ])
    book = spend_book

    outcome = Rag::CapturedGenerationReplay.execute_benchmark(
      turns: [ prepared ],
      models: [ { key: "sonnet", ids: [
        Rag::CapturedGenerationReplay::SONNET_45_GLOBAL,
        Rag::CapturedGenerationReplay::SONNET_45_US
      ] } ],
      client: client,
      spend: book,
      output_root: File.join(@dir, "benchmark"),
      run_id: "replay-test"
    )

    assert_nil outcome["stop"]
    assert_equal 2, outcome["results"].size
    assert_equal Rag::CapturedGenerationReplay::SONNET_45_US, calls.last[:model_id]
    assert_equal "returned", outcome["results"].last["sample"].status
  end

  test "the vf5 captures are the three generation prompts" do
    root = Rails.root.join("tmp/field_companion/validation_captures/vf5-bound-20261020T1728Z")
    skip "local vf5 capture is not in this tree" unless root.join(Rag::CapturedGenerationReplay::VF5_TURNS.first[:request_id], "capture.json").file?

    expected = {
      1 => "5dc531b35ab27d69df989d0d09de57e247108bab07b3ce14652d01e029fda306",
      2 => "2c284b7070cd536ed28a4dc04ce98322eaa430a9edec4b28479bcc93cb32a607",
      3 => "1e2f454821246041d4a3f4624b9e257ccd3fe460865059c394fa6324ee1155b8"
    }
    hashes = Rag::CapturedGenerationReplay::VF5_TURNS.map { |row|
      prepared = Rag::CapturedGenerationReplay.prepare(
        capture_dir: root.join(row[:request_id]),
        body_path: row[:body],
        turn: row[:turn],
        request_id: row[:request_id]
      )
      assert_nil prepared.system
      assert_equal 0.1, prepared.temperature
      assert_equal 3000, prepared.max_tokens
      assert_equal Rag::CapturedGenerationReplay::HAIKU_45, prepared.captured_model_id
      [ prepared.turn, prepared.prompt_sha256, prepared.body_sha256 ]
    }

    assert_equal expected.values, hashes.pluck(1)
    assert_equal 3, hashes.map(&:last).uniq.size
  end

  private

  def capture(prompt:)
    request = File.join(@dir, "request")
    FileUtils.mkdir_p(File.join(request, "bodies"))
    File.binwrite(File.join(request, "bodies/b0005.txt"), prompt)
    digest = Digest::SHA256.hexdigest(prompt)
    document = {
      "events" => [
        {
          "kind" => "generate_text",
          "result" => "prepared",
          "model_id" => Rag::CapturedGenerationReplay::HAIKU_45,
          "max_tokens" => 3000,
          "temperature" => 0.1,
          "anthropic_version" => "bedrock-2023-05-31",
          "messages" => [ { "role" => "user" } ],
          "user_sha256" => digest,
          "prompt" => {
            "path" => "bodies/b0005.txt",
            "sha256" => digest,
            "bytes" => prompt.bytesize,
            "truncated" => false,
            "absent" => false
          }
        }
      ]
    }
    File.write(File.join(request, "capture.json"), JSON.generate(document))
    { capture_dir: request, body_path: "bodies/b0005.txt", turn: 1, request_id: "request" }
  end

  def fake_client(responses)
    calls = []
    runtime = Object.new
    runtime.define_singleton_method(:config) { Struct.new(:max_attempts).new(1) }
    runtime.define_singleton_method(:invoke_model) do |**params|
      calls << params
      response = responses.shift
      raise response if response.is_a?(Exception)

      response
    end
    client = BedrockClient.allocate
    client.instance_variable_set(:@client, runtime)
    [ client, calls ]
  end

  def ok_response(text)
    payload = {
      "content" => [ { "text" => text } ],
      "usage" => { "input_tokens" => 100, "output_tokens" => 20 },
      "stop_reason" => "end_turn"
    }
    Struct.new(:body).new(StringIO.new(JSON.generate(payload)))
  end

  def spend_book(cost_cap: "4")
    Rag::AssignmentSpend.new(path: File.join(@dir, "spend.json"), call_cap: 48, cost_cap_usd: cost_cap)
  end

  def replay_sample(prepared, client, output: "out")
    Rag::CapturedGenerationReplay.run_sample(
      prepared: prepared,
      model_id: Rag::CapturedGenerationReplay::HAIKU_45,
      client: client,
      spend: spend_book,
      output_dir: File.join(@dir, output),
      run_id: "replay-test"
    )
  end

  def body_for(prepared, model_id)
    client, calls = fake_client([ ok_response("ok") ])
    Rag::CapturedGenerationReplay.run_sample(
      prepared: prepared,
      model_id: model_id,
      client: client,
      spend: spend_book,
      output_dir: File.join(@dir, model_id.gsub(/[^\w]+/, "-")),
      run_id: "replay-test"
    )
    calls.first[:body]
  end
end
