# frozen_string_literal: true

require "test_helper"
require "stringio"

class Rag::Phase5GenerationReplayTest < ActiveSupport::TestCase
  FIXTURE = Rails.root.join("test/fixtures/files/field_companion/phase5_generation_20261014")
  REQUEST_SHA = "2f8e64afef98363ca5590f531d8741ee3f8d240eeecc21679cb475cbb29c9011"
  INVOKE_BODY_SHA = "9b0d8861a4da67c97fbe7c019238fafa3207bdd5fcaa867932699f5c7678d9c6"
  PROMPT_SHA = "8a771ae3aedee0ddda50dec7c347e843e5daee3c95060dbaa2d00ce6dae33b6a"
  RAW_ANSWER_SHA = "bc9c12b1a6865a3e7024d3ce1b9473a3a57d9e3add9693ba197307ba5a354284"
  MODEL_ID = "global.anthropic.claude-haiku-4-5-20251001-v1:0"
  HISTORICAL_CORRELATION = "query:c80668ea-f7e8-4448-bb2d-ddd842fe7524"

  setup { disarm_budgets }
  teardown { disarm_budgets }

  test "preview reads the captured bytes and the full hashes without sending" do
    preview = Rag::Phase5GenerationReplay.preview(capture_dir: FIXTURE, output_dir: Rails.root.join("tmp/phase5-preview-absent"))

    assert_equal "preview", preview.status
    assert_equal false, preview.to_h["sent"]
    assert_equal "not_accepted", preview.to_h["phase3_acceptance"]
    assert_equal "not_accepted", preview.to_h["phase5_acceptance"]
    assert_equal true, preview.to_h["historical_failures_retained"]
    assert_equal "not_claimed", preview.to_h["determinism"]
    assert_equal false, preview.to_h["question_required"]
    assert_equal 2, preview.to_h["attempt_cap"]
    assert_equal false, preview.to_h["retries"]
    request = preview.request
    assert_equal MODEL_ID, request["model_id"]
    assert_equal 0.1, request["temperature"]
    assert_equal 3000, request["max_tokens"]
    assert_equal "bedrock-2023-05-31", request["anthropic_version"]
    assert_equal false, request["stream"]
    assert_equal false, request["system"]
    assert_equal [ { "role" => "user" } ], request["messages"]
    assert_equal 47221, request["log_request_bytes"]
    assert_equal 47331, request["invoke_body_bytes"]
    assert_equal 46068, request["prompt_bytes"]
    assert_equal 1410, request["raw_answer_bytes"]
    assert_equal REQUEST_SHA, request["log_request_sha256"]
    assert_equal INVOKE_BODY_SHA, request["invoke_body_sha256"]
    assert_equal false, request["body_includes_model_and_stream"]
    assert_equal %w[model stream], request["log_only_keys_removed"]
    assert_equal PROMPT_SHA, request["prompt_sha256"]
    assert_equal RAW_ANSWER_SHA, request["raw_answer_sha256"]
    assert_equal 64, REQUEST_SHA.length
    assert_equal REQUEST_SHA, Digest::SHA256.file(FIXTURE.join("request_body.json")).hexdigest
    assert_equal PROMPT_SHA, Digest::SHA256.file(FIXTURE.join("prompt_single_user.txt")).hexdigest
    assert_equal RAW_ANSWER_SHA, Digest::SHA256.file(FIXTURE.join("raw_answer.txt")).hexdigest
    assert_not_equal HISTORICAL_CORRELATION, "phase5:replay:b:1"
    quota = preview.quota
    assert_equal 0, quota["calls_recorded"]
    assert_equal 1, quota["calls_the_next_authorized_process_would_send"]
    assert_equal 1, quota["calls_remaining_after_that_process"]
    assert_equal 1, quota["next_sample"]
    assert_equal "0.018221", quota["estimated_usd_one_call"]
    assert_equal "0.018221", quota["estimated_usd_if_the_next_authorized_process_sends"]
    assert_equal "0.036442", quota["estimated_usd_cap_reference"]
    assert_equal false, quota["estimate_is_ceiling"]
    assert_equal 15881, quota["reference_input_tokens"]
    assert_equal 468, quota["reference_output_tokens"]
    assert_equal false, quota["retries"]
    source = Rails.root.join("app/services/rag/phase5_generation_replay.rb").read
    assert_not_includes source, "generate_text("
    assert_not_includes source, ".generate_text"
    assert_not_includes source, "TrackBedrockQueryJob"
    assert_not_includes source, "sanitize_answer"
    assert_not_includes source, "Stage2RunBudget"
    script = Rails.root.join("script/field_companion/phase5_generation_replay.rb").read
    assert_includes script, "retry_limit: 0"
    assert_includes script, "max_attempts: 1"
    assert_not_includes script, "generate_text"
    assert_equal 0, Rag::Stage2RunBudget::PASS_CALL_CAP
    assert_equal 188, Rag::Stage2RunBudget::HISTORICAL_CALLS
  end

  test "a run sends the captured body once and records the sample" do
    client = recording_client
    authorized do
      Dir.mktmpdir("phase5-replay") do |dir|
        result = Rag::Phase5GenerationReplay.run(capture_dir: FIXTURE, output_dir: dir, client: client)

        assert_equal "recorded", result.status
        assert_equal true, result.to_h["sent"]
        assert_equal 1, client.calls.size
        call = client.calls.first
        sent = call[:body].b
        assert_equal INVOKE_BODY_SHA, Digest::SHA256.hexdigest(sent)
        assert_equal 47331, sent.bytesize
        assert_not_equal File.binread(FIXTURE.join("request_body.json")), sent
        parsed = JSON.parse(sent)
        assert_equal %w[anthropic_version max_tokens temperature messages], parsed.keys
        assert_equal false, parsed.key?("model")
        assert_equal false, parsed.key?("stream")
        assert_equal false, parsed.key?("system")
        assert_equal MODEL_ID, call[:model_id]
        assert_equal 0.1, parsed["temperature"]
        assert_equal 3000, parsed["max_tokens"]
        assert_equal PROMPT_SHA, Digest::SHA256.hexdigest(parsed.dig("messages", 0, "content"))
        sample = Pathname(dir).join("sample_1")
        assert_equal sent, File.binread(sample.join("request_body.json"))
        transform = JSON.parse(sample.join("body_transform.json").read)
        assert_equal %w[model stream], transform["removed_keys"]
        assert_equal "muestra 1", File.binread(sample.join("response.txt"))
        request = JSON.parse(sample.join("request.json").read)
        assert_equal true, request["sent"]
        assert_equal "phase5:replay:b:1", request["correlation_id"]
        assert_not_equal HISTORICAL_CORRELATION, request["correlation_id"]
        events = JSON.parse(sample.join("events.json").read)
        assert_equal %w[prepared attempt_started returned], events.map { |event| event["result"] }
        assert_equal false, events.first.dig("request", "sent")
        usage = JSON.parse(sample.join("usage.json").read)
        assert_equal 15881, usage["input_tokens"]
        assert_equal 120, usage["output_tokens"]
        retry_record = JSON.parse(sample.join("client_retry.json").read)
        assert_equal 1, retry_record["max_attempts"]
        assert_equal 0, retry_record["retry_limit"]
        template = JSON.parse(sample.join("reading.template.json").read)
        assert_nil template["meets_case_b"]
        assert_equal "", template["dp_category"]
        assert_not sample.join("reading.json").exist?
        assert_not Pathname(dir).join("sample_2").exist?
        assert_equal 0, result.quota["calls_the_next_authorized_process_would_send"]
        assert_equal "reading_absent", result.quota["dispatch"]
      end
    end
  end

  test "a different hash is blocked before the client" do
    client = recording_client
    authorized do
      with_capture do |root|
        path = root.join("request_body.json")
        bytes = path.binread
        bytes.setbyte(20, (bytes.getbyte(20) + 1) % 256)
        path.binwrite(bytes)
        refused = run_in(root, client)

        assert_equal "blocked", refused.status
        assert_equal "sha256", refused.reason
        assert_equal "request_body.json", refused.detail["field"]
        assert_equal REQUEST_SHA, refused.detail["expected_sha256"]
        assert_equal 64, refused.detail["actual_sha256"].length
        assert_not_equal REQUEST_SHA, refused.detail["actual_sha256"]
        assert_empty client.calls
      end
    end
  end

  test "a missing prompt or a retry limit does not call the client" do
    client = recording_client(retry_limit: 0)
    authorized do
      with_capture do |root|
        File.delete(root.join("prompt_single_user.txt"))
        refused = run_in(root, client)

        assert_equal "refused", refused.status
        assert_equal "absent", refused.reason
        assert_includes refused.detail, "prompt_single_user.txt"
        assert_empty client.calls
      end
    end

    limited = recording_client(retry_limit: 3)
    authorized do
      Dir.mktmpdir("phase5-replay") do |dir|
        refused = Rag::Phase5GenerationReplay.run(capture_dir: FIXTURE, output_dir: dir, client: limited)

        assert_equal "refused", refused.status
        assert_equal "retry_limit", refused.reason
        assert_equal 3, refused.detail["retry_limit"]
        assert_empty limited.calls
        assert_not Pathname(dir).join("sample_1").exist?
      end
    end
  end

  test "missing authorization or aws attempts does not call or construct a client" do
    client = recording_client
    isolate_env(Rag::Phase5GenerationReplay::AUTHORIZED_ENV, nil) do
      isolate_env("AWS_MAX_ATTEMPTS", "1") do
        Dir.mktmpdir("phase5-replay") do |dir|
          refused = Rag::Phase5GenerationReplay.run(capture_dir: FIXTURE, output_dir: dir, client: client)
          assert_equal "refused", refused.status
          assert_equal "authorization_absent", refused.reason
          assert_empty client.calls
        end
      end
    end

    isolate_env("PHASE5_GENERATION_REPLAY_REQUIRE", "1") do
      isolate_env("PHASE5_GENERATION_REPLAY_CAPTURE", FIXTURE.to_s) do
        load Rails.root.join("script/field_companion/phase5_generation_replay.rb")
        isolate_env(Rag::Phase5GenerationReplay::AUTHORIZED_ENV, nil) do
          Dir.mktmpdir("phase5-replay") do |dir|
            isolate_env("PHASE5_GENERATION_REPLAY_OUTPUT", dir) do
              built = track_runtime_client_new do
                stdout, = capture_io { assert_equal 2, phase5_generation_replay_main }
                preview = JSON.parse(stdout)
                assert_equal "preview", preview["status"]
                assert_equal false, preview["sent"]
                assert_equal REQUEST_SHA, preview.dig("request", "log_request_sha256")
                assert_equal INVOKE_BODY_SHA, preview.dig("request", "invoke_body_sha256")
                assert_equal "0.018221", preview.dig("quota", "estimated_usd_one_call")
              end
              assert_equal false, built
            end
          end
        end

        isolate_env(Rag::Phase5GenerationReplay::AUTHORIZED_ENV, "1") do
          isolate_env("AWS_MAX_ATTEMPTS", nil) do
            Dir.mktmpdir("phase5-replay") do |dir|
              isolate_env("PHASE5_GENERATION_REPLAY_OUTPUT", dir) do
                built = track_runtime_client_new do
                  stdout, = capture_io { assert_equal 2, phase5_generation_replay_main }
                  assert_equal "aws_max_attempts", JSON.parse(stdout)["reason"]
                end
                assert_equal false, built
              end
            end
          end
        end
      end
    end
  end

  test "an error is not repeated and does not open the second sample" do
    client = recording_client(error: "phase5 boom")
    authorized do
      Dir.mktmpdir("phase5-replay") do |dir|
        result = Rag::Phase5GenerationReplay.run(capture_dir: FIXTURE, output_dir: dir, client: client)

        assert_equal "recorded", result.status
        assert_equal 1, client.calls.size
        events = JSON.parse(Pathname(dir).join("sample_1/events.json").read)
        assert_equal %w[prepared attempt_started error], events.map { |event| event["result"] }
        assert_equal 1, events.count { |event| event["result"] == "error" }
        assert_equal "RuntimeError", events.last["error_class"]
        assert_not Pathname(dir).join("sample_1/response.txt").exist?
        again = recording_client
        second = Rag::Phase5GenerationReplay.run(capture_dir: FIXTURE, output_dir: dir, client: again)
        assert_equal "refused", second.status
        assert_equal "first_sample_error", second.reason
        assert_empty again.calls
        assert_not Pathname(dir).join("sample_2").exist?
      end
    end
  end

  test "the second sample waits for a human reading and sends only when that reading records a failure" do
    authorized do
      Dir.mktmpdir("phase5-replay") do |dir|
        first = recording_client(text: "muestra 1")
        Rag::Phase5GenerationReplay.run(capture_dir: FIXTURE, output_dir: dir, client: first)
        before = File.binread(Pathname(dir).join("sample_1/response.txt"))

        waiting = recording_client(text: "no debe enviarse")
        absent = Rag::Phase5GenerationReplay.run(capture_dir: FIXTURE, output_dir: dir, client: waiting)
        assert_equal "refused", absent.status
        assert_equal "reading_absent", absent.reason
        assert_equal 0, absent.quota["calls_the_next_authorized_process_would_send"]
        assert_empty waiting.calls

        write_reading(dir, meets_case_b: true)
        met = Rag::Phase5GenerationReplay.run(capture_dir: FIXTURE, output_dir: dir, client: waiting)
        assert_equal "refused", met.status
        assert_equal "first_sample_met", met.reason
        assert_empty waiting.calls

        write_reading(dir, meets_case_b: "false")
        invalid = Rag::Phase5GenerationReplay.run(capture_dir: FIXTURE, output_dir: dir, client: waiting)
        assert_equal "refused", invalid.status
        assert_equal "reading_invalid", invalid.reason
        assert_empty waiting.calls

        write_reading(dir, meets_case_b: false)
        second_client = recording_client(text: "muestra 2")
        second = Rag::Phase5GenerationReplay.run(capture_dir: FIXTURE, output_dir: dir, client: second_client)
        assert_equal "recorded", second.status
        assert_equal 1, second_client.calls.size
        assert_equal INVOKE_BODY_SHA, Digest::SHA256.hexdigest(second_client.calls.first[:body])
        assert_equal "phase5:replay:b:2", JSON.parse(Pathname(dir).join("sample_2/request.json").read)["correlation_id"]
        assert_equal before, File.binread(Pathname(dir).join("sample_1/response.txt"))
        assert_equal "muestra 2", File.binread(Pathname(dir).join("sample_2/response.txt"))
        assert_equal 0, second.quota["calls_the_next_authorized_process_would_send"]
        assert_equal "cap_reached", second.quota["dispatch"]
        third = recording_client
        capped = Rag::Phase5GenerationReplay.run(capture_dir: FIXTURE, output_dir: dir, client: third)
        assert_equal "blocked", capped.status
        assert_equal "cap_reached", capped.reason
        assert_empty third.calls
      end
    end
  end

  test "an armed phase budget is refused before the client and the closed caps stay closed" do
    client = recording_client
    Rag::Phase3PinnedTurn
    Rag::Phase3ModelBudget.arm!
    authorized do
      Dir.mktmpdir("phase5-replay") do |dir|
        refused = Rag::Phase5GenerationReplay.run(capture_dir: FIXTURE, output_dir: dir, client: client)
        assert_equal "refused", refused.status
        assert_equal "budget_armed", refused.reason
        assert_empty client.calls
        assert_equal 0, Rag::Phase3ModelBudget.attempts
      end
    end
    assert_equal 0, Rag::Stage2RunBudget::PASS_CALL_CAP
  end

  private

  def authorized
    isolate_env(Rag::Phase5GenerationReplay::AUTHORIZED_ENV, "1") do
      isolate_env("AWS_MAX_ATTEMPTS", "1") { yield }
    end
  end

  def run_in(root, client)
    Dir.mktmpdir("phase5-replay") do |dir|
      return Rag::Phase5GenerationReplay.run(capture_dir: root, output_dir: dir, client: client)
    end
  end

  def with_capture
    Dir.mktmpdir("phase5-capture") do |dir|
      destination = Pathname(dir)
      FileUtils.cp_r("#{FIXTURE}/.", destination)
      yield destination
    end
  end

  def write_reading(dir, meets_case_b:)
    payload = {
      "identity" => "anotada",
      "function" => "anotada",
      "dp_category" => "anotada",
      "prescribed_check" => "anotada",
      "usefulness" => "anotada",
      "meets_case_b" => meets_case_b
    }
    File.write(Pathname(dir).join("sample_1/reading.json"), "#{JSON.generate(payload)}\n")
  end

  def recording_client(text: "muestra 1", error: nil, retry_limit: 0)
    view = Rag::Phase5GenerationReplay::RetryView.new(max_attempts: 1, retry_limit: retry_limit, retry_mode: "legacy")
    raised = error && RuntimeError.new(error)
    Class.new do
      attr_reader :calls

      define_method(:initialize) do
        @calls = []
        @view = view
        @text = text
        @raised = raised
      end

      define_method(:retry_view) { @view }

      define_method(:invoke_model) do |model_id:, body:|
        @calls << { model_id: model_id, body: body }
        raise @raised if @raised

        raw = {
          "content" => [ { "text" => @text } ],
          "usage" => { "input_tokens" => 15_881, "output_tokens" => 120 },
          "stop_reason" => "end_turn"
        }.to_json
        Struct.new(:body).new(StringIO.new(raw))
      end
    end.new
  end

  def track_runtime_client_new
    original = Aws::BedrockRuntime::Client.method(:new)
    built = false
    Aws::BedrockRuntime::Client.define_singleton_method(:new) do |*args, **kwargs, &block|
      built = true
      original.call(*args, **kwargs, &block)
    end
    yield
    built
  ensure
    Aws::BedrockRuntime::Client.define_singleton_method(:new, original) if original
  end

  def disarm_budgets
    Rag::Phase1ModelBudget.disarm! if defined?(Rag::Phase1ModelBudget)
    Rag::Phase2ModelBudget.disarm! if defined?(Rag::Phase2ModelBudget)
    Rag::Phase3ModelBudget.disarm! if defined?(Rag::Phase3ModelBudget)
  end
end
