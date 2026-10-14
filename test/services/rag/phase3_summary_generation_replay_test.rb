# frozen_string_literal: true

require "test_helper"

class Rag::Phase3SummaryGenerationReplayTest < ActiveSupport::TestCase
  FIXTURE = Rails.root.join("test/fixtures/files/field_companion/phase3_summary_20261014T194442Z/turn_3")
  SYSTEM_SHA = "81a7dfd85e2415d2527a6537b35b540aa03a5a69b2bd06f643c8479ff0031024"
  USER_SHA = "e9d4ba63418d15e4820c4197bdfd17aa4dae7a81cf68527eab0d61c69a6d12b2"
  ANSWER_SHA = "927e3d87fe788e7284768fa2081a3496c51f6110777607022cb11860c71016b6"
  RUN_ID = "20261015T120000Z"
  MODEL_ID = "global.anthropic.claude-haiku-4-5-20251001-v1:0"

  setup do
    disarm_budgets
  end

  teardown do
    disarm_budgets
  end

  test "preview reads the captured parameters and the full hashes without sending" do
    preview = Rag::Phase3SummaryGenerationReplay.preview(capture_dir: FIXTURE)

    assert_equal "preview", preview.status
    assert_equal false, preview.to_h["sent"]
    assert_equal "not_accepted", preview.to_h["phase3_acceptance"]
    assert_equal 3, preview.to_h["attempt_cap"]
    assert_equal false, preview.to_h["retries"]
    request = preview.request
    assert_equal MODEL_ID, request["model_id"]
    assert_equal 0.1, request["temperature"]
    assert_equal 3000, request["max_tokens"]
    assert_equal "bedrock-2023-05-31", request["anthropic_version"]
    assert_equal [ { "role" => "user" } ], request["messages"]
    assert_equal "bodies/b0007.txt", request["system_path"]
    assert_equal "bodies/b0008.txt", request["user_path"]
    assert_equal 13668, request["system_bytes"]
    assert_equal 23415, request["user_bytes"]
    assert_equal SYSTEM_SHA, request["system_sha256"]
    assert_equal USER_SHA, request["user_sha256"]
    assert_equal 64, request["system_sha256"].length
    assert_equal 64, request["user_sha256"].length
    assert_equal SYSTEM_SHA, Digest::SHA256.file(FIXTURE.join("bodies/b0007.txt")).hexdigest
    assert_equal USER_SHA, Digest::SHA256.file(FIXTURE.join("bodies/b0008.txt")).hexdigest
    historical = request["historical_generation_result"]
    assert_equal "returned", historical["result"]
    assert_equal 23, historical["sequence"]
    assert_equal 11928, historical["input_tokens"]
    assert_equal 545, historical["output_tokens"]
    assert_equal 1665, historical["answer_bytes"]
    assert_equal ANSWER_SHA, historical["answer_sha256"]
    assert_not_equal ANSWER_SHA, request["user_sha256"]
    assert_equal "tmp/phase3_pinned_turn/runs/20261014T194442Z/turn_3",
      Rag::Phase3SummaryGenerationReplay::DEFAULT_CAPTURE
    source = Rails.root.join("app/services/rag/phase3_summary_generation_replay.rb").read
    assert_not_includes source, "Stage2RunBudget"
    assert_not_includes source, "PASS_CALL_CAP"
    assert_equal 0, Rag::Stage2RunBudget::PASS_CALL_CAP
    assert_equal 188, Rag::Stage2RunBudget::HISTORICAL_CALLS
    assert_equal BigDecimal("0.423114"), Rag::Stage2RunBudget::HISTORICAL_COST_USD
  end

  test "a run sends the captured bytes and the captured parameters" do
    client = recording_client
    authorized do
      isolate_env("BEDROCK_MODEL_ID", "us.anthropic.claude-haiku-4-5-20251001-v1:0") do
        Dir.mktmpdir("phase3-summary") do |dir|
          result = Rag::Phase3SummaryGenerationReplay.run(
            capture_dir: FIXTURE, output_dir: dir, run_id: RUN_ID, client: client
          )

          assert_equal "recorded", result.status
          assert_equal true, result.to_h["sent"]
          assert_equal 3, client.calls.size
          client.calls.each_with_index do |call, index|
            assert_equal File.binread(FIXTURE.join("bodies/b0008.txt")), call[:prompt].b
            assert_equal File.binread(FIXTURE.join("bodies/b0007.txt")), call[:system].b
            assert_equal MODEL_ID, call[:model_id]
            assert_equal 0.1, call[:temperature]
            assert_equal 3000, call[:max_tokens]
            assert_equal "phase3:summary:#{RUN_ID}:#{index + 1}", call[:tracking][:correlation_id]
            assert_equal index + 1, call[:tracking][:attempt]
            assert_not_equal ANSWER_SHA, Digest::SHA256.hexdigest(call[:prompt])
          end
          assert_equal Rag::Phase3SummaryGenerationReplay::HISTORICAL_CORRELATIONS & client.calls.map { |call|
            call[:tracking][:correlation_id]
          }, []
          (1..3).each do |attempt|
            sample = Pathname(dir).join("sample_#{attempt}")
            assert_equal File.binread(FIXTURE.join("bodies/b0007.txt")), File.binread(sample.join("system.txt"))
            assert_equal File.binread(FIXTURE.join("bodies/b0008.txt")), File.binread(sample.join("user.txt"))
            assert_equal "muestra #{attempt}", File.binread(sample.join("response.txt"))
            request = JSON.parse(sample.join("request.json").read)
            assert_equal true, request["sent"]
            assert_equal MODEL_ID, request["model_id"]
            assert_equal 0.1, request["temperature"]
            assert_equal 3000, request["max_tokens"]
            events = JSON.parse(sample.join("events.json").read)
            assert_equal %w[prepared attempt_started returned], events.map { |event| event["result"] }
            assert_equal false, events.first.dig("request", "sent")
            usage = JSON.parse(sample.join("usage.json").read)
            assert_equal "unavailable", usage["input_tokens"]
            assert_equal "unavailable", usage["output_tokens"]
          end
          assert_not Pathname(dir).join("sample_4").exist?
        end
      end
    end
  end

  test "a different hash is blocked before the client and a prefix is not a match" do
    client = recording_client
    authorized do
      with_capture do |root|
        path = root.join("bodies/b0008.txt")
        bytes = path.binread
        bytes.setbyte(10, (bytes.getbyte(10) + 1) % 256)
        path.binwrite(bytes)
        refused = run_in(root, client)

        assert_equal "blocked", refused.status
        assert_equal "sha256", refused.reason
        assert_equal "prompt", refused.detail["field"]
        assert_equal USER_SHA, refused.detail["expected_sha256"]
        assert_equal 64, refused.detail["actual_sha256"].length
        assert_equal Digest::SHA256.file(path).hexdigest, refused.detail["actual_sha256"]
        assert_not refused.detail["actual_sha256"].start_with?(USER_SHA)
        assert_empty client.calls
      end

      with_capture do |root|
        capture = JSON.parse(root.join("capture.json").read)
        prepared = capture["events"].find { |event| event["kind"] == "generate_text" && event["result"] == "prepared" }
        prefix = USER_SHA[0, 16]
        prepared["prompt"]["sha256"] = prefix
        prepared["user_sha256"] = prefix
        root.join("capture.json").write(JSON.generate(capture))
        refused = run_in(root, client)

        assert_equal "blocked", refused.status
        assert_equal "sha256", refused.reason
        assert_equal prefix, refused.detail["sha256"]
        assert_equal 16, refused.detail["sha256"].length
        assert_empty client.calls
      end
    end
  end

  test "a changed role, version, missing body, or missing parameter does not call the client" do
    client = recording_client
    authorized do
      with_capture do |root|
        rewrite_prepared(root) { |event| event["messages"] = [ { "role" => "assistant" } ] }
        refused = run_in(root, client)
        assert_equal "blocked", refused.status
        assert_equal "role", refused.reason
        assert_empty client.calls
      end

      with_capture do |root|
        rewrite_prepared(root) { |event| event["anthropic_version"] = "bedrock-other" }
        refused = run_in(root, client)
        assert_equal "blocked", refused.status
        assert_equal "anthropic_version", refused.reason
        assert_equal "bedrock-other", refused.detail["captured"]
        assert_nil refused.request
        assert_empty client.calls
      end

      with_capture do |root|
        FileUtils.cp(root.join("bodies/b0007.txt"), root.join("bodies/b0009.txt"))
        rewrite_prepared(root) { |event| event["system"]["path"] = "bodies/b0009.txt" }
        refused = run_in(root, client)
        assert_equal "blocked", refused.status
        assert_equal "reference", refused.reason
        assert_equal "bodies/b0007.txt", refused.detail["expected_path"]
        assert_equal "bodies/b0009.txt", refused.detail["actual_path"]
        assert_empty client.calls
      end

      with_capture do |root|
        File.delete(root.join("bodies/b0008.txt"))
        refused = run_in(root, client)
        assert_equal "refused", refused.status
        assert_equal "absent", refused.reason
        assert_includes refused.detail, "bodies/b0008.txt"
        assert_nil refused.request
        assert_empty client.calls
      end

      with_capture do |root|
        rewrite_prepared(root) { |event| event.delete("temperature") }
        refused = run_in(root, client)
        assert_equal "refused", refused.status
        assert_equal "absent", refused.reason
        assert_includes refused.detail, "temperature"
        assert_nil refused.request
        assert_empty client.calls
      end
    end
  end

  test "missing authorization does not call or construct a client" do
    client = recording_client
    isolate_env(Rag::Phase3SummaryGenerationReplay::AUTHORIZED_ENV, nil) do
      isolate_env("AWS_MAX_ATTEMPTS", "1") do
        Dir.mktmpdir("phase3-summary") do |dir|
          refused = Rag::Phase3SummaryGenerationReplay.run(
            capture_dir: FIXTURE, output_dir: dir, run_id: RUN_ID, client: client
          )
          assert_equal "refused", refused.status
          assert_equal "authorization_absent", refused.reason
          assert_empty client.calls
          assert_not Pathname(dir).join("sample_1").exist?
        end
      end
    end

    isolate_env("PHASE3_SUMMARY_GENERATION_REQUIRE", "1") do
      isolate_env("PHASE3_SUMMARY_GENERATION_CAPTURE", FIXTURE.to_s) do
        isolate_env(Rag::Phase3SummaryGenerationReplay::AUTHORIZED_ENV, nil) do
          load Rails.root.join("script/field_companion/phase3_summary_generation_replay.rb")
          built = track_bedrock_client_new do
            stdout, = capture_io { assert_equal 2, phase3_summary_generation_replay_main }
            preview = JSON.parse(stdout)
            assert_equal "preview", preview["status"]
            assert_equal false, preview["sent"]
            assert_equal USER_SHA, preview.dig("request", "user_sha256")
            assert_equal SYSTEM_SHA, preview.dig("request", "system_sha256")
          end
          assert_equal false, built
        end

        isolate_env(Rag::Phase3SummaryGenerationReplay::AUTHORIZED_ENV, "1") do
          isolate_env("AWS_MAX_ATTEMPTS", nil) do
            isolate_env("PHASE3_SUMMARY_GENERATION_RUN_ID", RUN_ID) do
              built = track_bedrock_client_new do
                stdout, = capture_io { assert_equal 2, phase3_summary_generation_replay_main }
                assert_equal "aws_max_attempts", JSON.parse(stdout)["reason"]
              end
              assert_equal false, built
            end
          end
        end
      end
    end
  end

  test "three attempts record one error each and a second run does not overwrite" do
    client = raising_client
    authorized do
      Dir.mktmpdir("phase3-summary") do |dir|
        result = Rag::Phase3SummaryGenerationReplay.run(
          capture_dir: FIXTURE, output_dir: dir, run_id: RUN_ID, client: client
        )

        assert_equal "recorded", result.status
        assert_equal 3, client.calls.size
        assert_equal [ 1, 2, 3 ], client.calls.map { |call| call[:tracking][:attempt] }
        (1..3).each do |attempt|
          sample = Pathname(dir).join("sample_#{attempt}")
          events = JSON.parse(sample.join("events.json").read)
          assert_equal %w[prepared attempt_started error], events.map { |event| event["result"] }
          assert_equal 1, events.count { |event| event["result"] == "error" }
          assert_equal "RuntimeError", events.last["error_class"]
          assert_not sample.join("response.txt").exist?
          assert_not sample.join("usage.json").exist?
        end
        assert_not Pathname(dir).join("sample_4").exist?
        before = File.binread(Pathname(dir).join("sample_1/events.json"))
        again = recording_client
        second = Rag::Phase3SummaryGenerationReplay.run(
          capture_dir: FIXTURE, output_dir: dir, run_id: "20261015T130000Z", client: again
        )
        assert_equal "blocked", second.status
        assert_equal "evidence_exists", second.reason
        assert_empty again.calls
        assert_equal before, File.binread(Pathname(dir).join("sample_1/events.json"))
        assert_equal 3, client.calls.size
      end
    end
  end

  test "an armed phase budget is refused before the client and the closed caps stay closed" do
    client = recording_client
    Rag::Phase3PinnedTurn
    Rag::Phase3ModelBudget.arm!
    authorized do
      Dir.mktmpdir("phase3-summary") do |dir|
        refused = Rag::Phase3SummaryGenerationReplay.run(
          capture_dir: FIXTURE, output_dir: dir, run_id: RUN_ID, client: client
        )
        assert_equal "refused", refused.status
        assert_equal "budget_armed", refused.reason
        assert_empty client.calls
        assert_equal 0, Rag::Phase3ModelBudget.attempts
      end
    end
    assert_equal 0, Rag::Stage2RunBudget::PASS_CALL_CAP
    assert_equal 188, Rag::Stage2RunBudget::HISTORICAL_CALLS
  end

  private

  def authorized
    isolate_env(Rag::Phase3SummaryGenerationReplay::AUTHORIZED_ENV, "1") do
      isolate_env("AWS_MAX_ATTEMPTS", "1") { yield }
    end
  end

  def run_in(root, client)
    Dir.mktmpdir("phase3-summary") do |dir|
      return Rag::Phase3SummaryGenerationReplay.run(
        capture_dir: root, output_dir: dir, run_id: RUN_ID, client: client
      )
    end
  end

  def with_capture
    Dir.mktmpdir("phase3-capture") do |dir|
      destination = Pathname(dir).join("turn_3")
      FileUtils.cp_r(FIXTURE, destination)
      yield destination
    end
  end

  def rewrite_prepared(root)
    capture = JSON.parse(root.join("capture.json").read)
    event = capture["events"].find { |row| row["kind"] == "generate_text" && row["result"] == "prepared" }
    yield event
    root.join("capture.json").write(JSON.generate(capture))
  end

  def recording_client
    Class.new do
      attr_reader :calls

      def initialize
        @calls = []
      end

      def generate_text(prompt, system:, model_id:, max_tokens:, temperature:, tracking:)
        @calls << {
          prompt: prompt, system: system, model_id: model_id,
          max_tokens: max_tokens, temperature: temperature, tracking: tracking
        }
        "muestra #{tracking.fetch(:attempt)}"
      end
    end.new
  end

  def raising_client
    Class.new do
      attr_reader :calls

      def initialize
        @calls = []
      end

      def generate_text(prompt, system:, model_id:, max_tokens:, temperature:, tracking:)
        @calls << { prompt: prompt, system: system, model_id: model_id, max_tokens: max_tokens, temperature: temperature, tracking: tracking }
        raise "phase3 summary boom"
      end
    end.new
  end

  def track_bedrock_client_new
    original = BedrockClient.method(:new)
    built = false
    BedrockClient.define_singleton_method(:new) do |*args, **kwargs, &block|
      built = true
      original.call(*args, **kwargs, &block)
    end
    yield
    built
  ensure
    BedrockClient.define_singleton_method(:new, original) if original
  end

  def disarm_budgets
    Rag::Phase1ModelBudget.disarm! if defined?(Rag::Phase1ModelBudget)
    Rag::Phase2ModelBudget.disarm! if defined?(Rag::Phase2ModelBudget)
    Rag::Phase3ModelBudget.disarm! if defined?(Rag::Phase3ModelBudget)
  end
end
