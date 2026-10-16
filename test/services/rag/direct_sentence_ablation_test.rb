# frozen_string_literal: true

require "test_helper"
require "stringio"

class Rag::DirectSentenceAblationTest < ActiveSupport::TestCase
  PHASE5 = Rails.root.join("test/fixtures/files/field_companion/phase5_generation_20261014")
  PROMPT_SHA = "8a771ae3aedee0ddda50dec7c347e843e5daee3c95060dbaa2d00ce6dae33b6a"
  REQUEST_SHA = "2f8e64afef98363ca5590f531d8741ee3f8d240eeecc21679cb475cbb29c9011"
  INVOKE_BODY_SHA = "9b0d8861a4da67c97fbe7c019238fafa3207bdd5fcaa867932699f5c7678d9c6"
  MODEL_ID = "global.anthropic.claude-haiku-4-5-20251001-v1:0"
  HISTORICAL = Rag::DirectSentenceAblation::HISTORICAL_SENTENCE
  CANDIDATE = Rag::DirectSentenceAblation::CANDIDATE_SENTENCE
  REMOVED = Rag::DirectSentenceAblation::REMOVED

  setup { disarm_budgets }
  teardown { disarm_budgets }

  test "substitution removes the sentence once and rejects any other difference" do
    original = "before\n- #{HISTORICAL}\nafter"
    once = Rag::DirectSentenceAblation.substitute(original)

    assert_equal 1, once.occurrences
    assert_nil once.problem
    assert_equal "before\n- #{CANDIDATE}\nafter", once.text
    assert Rag::DirectSentenceAblation.single_removal?(original, once.text, REMOVED)
    assert_equal 0, once.text.scan(HISTORICAL).size
    assert_equal original.scan(CANDIDATE).size, once.text.scan(CANDIDATE).size
    assert_not_includes once.text, Rag::LabelComparisonVariant::CANDIDATE_PARAGRAPH

    missing = Rag::DirectSentenceAblation.substitute("sin la frase")
    assert_nil missing.text
    assert_equal 0, missing.occurrences
    assert_equal "occurrences", missing.problem

    twice = Rag::DirectSentenceAblation.substitute("#{original}\n#{HISTORICAL}")
    assert_nil twice.text
    assert_equal 2, twice.occurrences
    assert_equal "occurrences", twice.problem

    assert_equal false, Rag::DirectSentenceAblation.single_removal?(original, "#{once.text}x", REMOVED)
    assert_equal 1, Rag::DirectSentenceAblation.production_sentence_count
    source = Rails.root.join("app/services/bedrock_rag_service.rb").read
    assert_includes source, "- #{HISTORICAL}"
    service = Rails.root.join("app/services/rag/direct_sentence_ablation.rb").read
    assert_not_includes service, "generate_text"
    assert_not_includes service, "TrackBedrockQueryJob"
    assert_equal 0, Rag::Stage2RunBudget::PASS_CALL_CAP
  end

  test "preview keeps the original body and records the single removal" do
    preview = Rag::DirectSentenceAblation.preview(capture_dir: PHASE5)

    assert_equal "preview", preview.status
    assert_equal false, preview.to_h["sent"]
    assert_equal 1, preview.step
    assert_equal false, preview.to_h["production_directive_adopted"]
    assert_equal false, preview.to_h["b_prime_paragraph_adopted"]
    assert_equal "not_accepted", preview.to_h["phase3_acceptance"]
    assert_equal "not_accepted", preview.to_h["phase5_acceptance"]
    assert_equal "unchanged", preview.to_h["phase4_status"]
    assert_equal "not_validated", preview.to_h["episode"]
    assert_equal 2, preview.to_h["attempt_cap"]
    assert_equal false, preview.to_h["retries"]
    request = preview.request
    assert_equal MODEL_ID, request["model_id"]
    assert_equal 0.1, request["temperature"]
    assert_equal 3000, request["max_tokens"]
    assert_equal "bedrock-2023-05-31", request["anthropic_version"]
    assert_equal false, request["stream"]
    assert_equal false, request["system"]
    assert_equal 1, request["sentence_occurrences"]
    assert_equal [ "phase5:replay:b:direct:1", "phase5:replay:b:direct:2" ], request["correlations"]
    assert_empty request["correlations"] & request["historical_correlations_not_reused"]
    assert_equal "sample_1", request.dig("directories", "sample_1")
    assert_equal "tmp/direct_sentence_ablation", request.dig("directories", "output")
    assert_equal PROMPT_SHA, request["original_prompt_sha256"]
    assert_equal 46_068, request["original_prompt_bytes"]
    assert_equal INVOKE_BODY_SHA, request["original_invoke_body_sha256"]
    assert_equal 47_331, request["original_invoke_body_bytes"]
    assert_equal 46_036, request["candidate_prompt_bytes"]
    assert_equal 47_299, request["candidate_invoke_body_bytes"]
    assert_equal 32, request.dig("sentence", "removed_bytes")
    assert_not_equal PROMPT_SHA, request["candidate_prompt_sha256"]
    assert_not_equal INVOKE_BODY_SHA, request["candidate_invoke_body_sha256"]

    prompt = File.binread(PHASE5.join("prompt_single_user.txt"))
    candidate = prompt.sub(HISTORICAL, CANDIDATE)
    assert_equal sha(candidate), request["candidate_prompt_sha256"]
    assert Rag::DirectSentenceAblation.single_removal?(prompt, candidate, REMOVED)
    assert_equal 1, prompt.scan(Rag::LabelComparisonVariant::HISTORICAL_PARAGRAPH).size
    assert_equal 1, candidate.scan(Rag::LabelComparisonVariant::HISTORICAL_PARAGRAPH).size
    assert_not_includes candidate, Rag::LabelComparisonVariant::CANDIDATE_PARAGRAPH

    quota = preview.quota
    assert_equal 0, quota["calls_recorded"]
    assert_equal 1, quota["calls_the_next_authorized_process_would_send"]
    assert_equal 1, quota["next_step"]
    assert_equal "0.018221", quota["estimated_usd_reference"]
    assert_equal false, quota["estimate_is_ceiling"]
    assert_equal "not_authorized", quota["adoption"]
  end

  test "the built body differs only by that sentence and keeps the same parameters" do
    preview = Rag::DirectSentenceAblation.preview(capture_dir: PHASE5)
    prompt = File.binread(PHASE5.join("prompt_single_user.txt")).force_encoding(Encoding::UTF_8)
    candidate_prompt = prompt.sub(HISTORICAL, CANDIDATE)
    original = JSON.parse(Rag::Phase5GenerationReplay.invoke_body_for(
      anthropic_version: "bedrock-2023-05-31", max_tokens: 3000, temperature: 0.1, content: prompt
    ))
    variant = JSON.parse(Rag::Phase5GenerationReplay.invoke_body_for(
      anthropic_version: "bedrock-2023-05-31", max_tokens: 3000, temperature: 0.1, content: candidate_prompt
    ))

    assert_equal %w[anthropic_version max_tokens temperature messages], variant.keys
    assert_equal false, variant.key?("system")
    assert_equal false, variant.key?("model")
    assert_equal false, variant.key?("stream")
    assert_equal original.except("messages"), variant.except("messages")
    assert_equal "user", variant.dig("messages", 0, "role")
    assert_equal candidate_prompt.b, variant.dig("messages", 0, "content").b
    assert_equal sha(candidate_prompt), preview.request["candidate_prompt_sha256"]
    assert_equal INVOKE_BODY_SHA, preview.request["original_invoke_body_sha256"]
    original_body = Rag::Phase5GenerationReplay.invoke_body_for(
      anthropic_version: "bedrock-2023-05-31", max_tokens: 3000, temperature: 0.1, content: prompt
    )
    candidate_body = Rag::Phase5GenerationReplay.invoke_body_for(
      anthropic_version: "bedrock-2023-05-31", max_tokens: 3000, temperature: 0.1, content: candidate_prompt
    )
    assert_equal candidate_body, original_body.sub(HISTORICAL, CANDIDATE)
    assert Rag::DirectSentenceAblation.single_removal?(original_body, candidate_body, REMOVED)
    assert_equal 1, original_body.scan(HISTORICAL).size
    assert_equal 0, candidate_body.scan(HISTORICAL).size
  end

  test "a missing sentence, another difference, or a changed capture does not call" do
    client = recording_client
    authorized do
      with_single_removal(->(*) { false }) do
        refused = run_in(PHASE5, client)
        assert_equal "blocked", refused.status
        assert_equal "sentence", refused.reason
        assert_equal "other_difference", refused.detail["problem"]
        assert_empty client.calls
      end

      with_single_removal(->(original, _candidate, _removed) { original.bytesize < 47_000 }) do
        refused = run_in(PHASE5, client)
        assert_equal "blocked", refused.status
        assert_equal "other_difference", refused.reason
        assert_equal "invoke_body", refused.detail["field"]
        assert_empty client.calls
      end

      with_phase5 do |root|
        path = root.join("prompt_single_user.txt")
        text = path.binread.sub(HISTORICAL, HISTORICAL + HISTORICAL)
        path.binwrite(text)
        refused = run_in(root, client)
        assert_equal "blocked", refused.status
        assert_equal "sha256", refused.reason
        assert_empty client.calls
      end
    end
  end

  test "the first call sends only the candidate body and leaves the capture unchanged" do
    before = sha_file(PHASE5.join("prompt_single_user.txt"))
    client = recording_client
    authorized do
      Dir.mktmpdir("direct-sentence") do |dir|
        result = Rag::DirectSentenceAblation.run(capture_dir: PHASE5, output_dir: dir, client: client)

        assert_equal "recorded", result.status
        assert_equal 1, client.calls.size
        call = client.calls.first
        assert_equal MODEL_ID, call[:model_id]
        parsed = JSON.parse(call[:body])
        assert_equal %w[anthropic_version max_tokens temperature messages], parsed.keys
        assert_equal 0.1, parsed["temperature"]
        assert_equal 3000, parsed["max_tokens"]
        assert_equal false, parsed.key?("system")
        prompt = File.binread(PHASE5.join("prompt_single_user.txt")).force_encoding(Encoding::UTF_8)
        assert_equal sha(prompt.sub(HISTORICAL, CANDIDATE)), sha(parsed.dig("messages", 0, "content"))
        assert_equal 0, parsed.dig("messages", 0, "content").scan(HISTORICAL).size
        original_body = Rag::Phase5GenerationReplay.invoke_body_for(
          anthropic_version: "bedrock-2023-05-31", max_tokens: 3000, temperature: 0.1, content: prompt
        )
        assert_equal INVOKE_BODY_SHA, sha(original_body)
        sample = Pathname(dir).join("sample_1")
        assert_equal call[:body].b, File.binread(sample.join("request_body.json"))
        request = JSON.parse(sample.join("request.json").read)
        assert_equal "phase5:replay:b:direct:1", request["correlation_id"]
        assert_equal true, request["sent"]
        assert_equal false, request["b_prime_paragraph_adopted"]
        events = JSON.parse(sample.join("events.json").read)
        assert_equal %w[prepared attempt_started returned], events.map { |event| event["result"] }
        assert_equal false, events.first.dig("request", "sent")
        diff = File.read(sample.join("diff.txt"))
        assert_includes diff, "-- Start with one direct sentence. Do not restate the question."
        assert_includes diff, "+- Do not restate the question."
        sentence = JSON.parse(sample.join("sentence.json").read)
        assert_equal 1, sentence["occurrences"]
        assert_equal false, sentence["other_difference"]
        assert_equal INVOKE_BODY_SHA, sentence["original_invoke_body_sha256"]
        template = JSON.parse(sample.join("reading.template.json").read)
        assert_nil template["identity_passed"]
        assert_includes template["note"], "toda la respuesta"
        assert_includes template["note"], "no es un fallo"
        assert_includes template["note"], "inferencia fundada"
        assert_not sample.join("reading.json").exist?
        assert_not Pathname(dir).join("sample_2").exist?
        client_retry = JSON.parse(sample.join("client_retry.json").read)
        assert_equal 1, client_retry["max_attempts"]
        assert_equal 0, client_retry["retry_limit"]
        assert_equal "reading_absent", result.quota["dispatch"]
        assert_equal 0, result.quota["calls_the_next_authorized_process_would_send"]
      end
    end
    assert_equal before, sha_file(PHASE5.join("prompt_single_user.txt"))
    assert_equal REQUEST_SHA, sha_file(PHASE5.join("request_body.json"))
  end

  test "identity failure stops the second call and a pass would open it" do
    authorized do
      Dir.mktmpdir("direct-sentence") do |dir|
        Rag::DirectSentenceAblation.run(capture_dir: PHASE5, output_dir: dir, client: recording_client)
        waiting = recording_client
        absent = run_dir(dir, waiting)
        assert_equal "refused", absent.status
        assert_equal "reading_absent", absent.reason
        assert_empty waiting.calls

        write_reading(dir, 1, identity_passed: false, partial: true)
        invalid = run_dir(dir, waiting)
        assert_equal "refused", invalid.status
        assert_equal "reading_invalid", invalid.reason
        assert_empty waiting.calls

        write_reading(dir, 1, identity_passed: false, partial: false)
        repeated = run_dir(dir, waiting)
        assert_equal "refused", repeated.status
        assert_equal "identity_repeated", repeated.reason
        assert_equal 0, repeated.quota["calls_the_next_authorized_process_would_send"]
        assert_empty waiting.calls
        assert_not Pathname(dir).join("sample_2").exist?

        write_reading(dir, 1, identity_passed: true, partial: true)
        second = recording_client(text: "muestra 2")
        recorded = run_dir(dir, second)
        assert_equal "recorded", recorded.status
        assert_equal 1, second.calls.size
        assert_equal "phase5:replay:b:direct:2", JSON.parse(Pathname(dir).join("sample_2/request.json").read)["correlation_id"]
        assert_equal REQUEST_SHA, sha_file(PHASE5.join("request_body.json"))

        capped = run_dir(dir, waiting)
        assert_equal "blocked", capped.status
        assert_equal "cap_reached", capped.reason
        assert_equal 0, capped.quota["calls_the_next_authorized_process_would_send"]
      end
    end
  end

  test "an error stops the sequence and is not replaced by the next call" do
    authorized do
      Dir.mktmpdir("direct-sentence") do |dir|
        failed = recording_client(error: "ablation boom")
        result = run_dir(dir, failed)

        assert_equal "recorded", result.status
        assert_equal true, result.detail["sequence_stopped"]
        assert_equal false, result.to_h["substitution_of_failed_call"]
        assert_equal 1, failed.calls.size
        events = JSON.parse(Pathname(dir).join("sample_1/events.json").read)
        assert_equal %w[prepared attempt_started error], events.map { |event| event["result"] }
        assert_not Pathname(dir).join("sample_1/response.txt").exist?
        again = recording_client
        second = run_dir(dir, again)
        assert_equal "refused", second.status
        assert_equal "sample_error", second.reason
        assert_empty again.calls
        assert_not Pathname(dir).join("sample_2").exist?
      end
    end
  end

  test "authorization, retries, budgets, and reserved directories block the client" do
    client = recording_client
    isolate_env(Rag::DirectSentenceAblation::AUTHORIZED_ENV, nil) do
      isolate_env("LABEL_COMPARISON_VARIANT_AUTHORIZED", "1") do
        isolate_env("PHASE5_GENERATION_REPLAY_AUTHORIZED", "1") do
          isolate_env("AWS_MAX_ATTEMPTS", "1") do
            Dir.mktmpdir("direct-sentence") do |dir|
              refused = run_dir(dir, client)
              assert_equal "refused", refused.status
              assert_equal "authorization_absent", refused.reason
              assert_empty client.calls
            end
          end
        end
      end
    end

    limited = recording_client(retry_limit: 3)
    authorized do
      Dir.mktmpdir("direct-sentence") do |dir|
        refused = run_dir(dir, limited)
        assert_equal "refused", refused.status
        assert_equal "retry_limit", refused.reason
        assert_empty limited.calls
        assert_not Pathname(dir).join("sample_1").exist?
      end

      [ "tmp/label_comparison_variant/direct_must_not_write", "tmp/phase5_generation_replay/case_b/direct_must_not_write" ].each do |relative|
        target = Rails.root.join(relative)
        refused = Rag::DirectSentenceAblation.gate(capture_dir: PHASE5, output_dir: target)
        assert_equal "blocked", refused.status
        assert_equal "evidence_overlaps_source", refused.reason
        assert_not target.exist?
      end
    end

    Rag::Phase3PinnedTurn
    Rag::Phase3ModelBudget.arm!
    authorized do
      Dir.mktmpdir("direct-sentence") do |dir|
        refused = run_dir(dir, client)
        assert_equal "refused", refused.status
        assert_equal "budget_armed", refused.reason
        assert_empty client.calls
      end
    end
  ensure
    Rag::Phase3ModelBudget.disarm! if defined?(Rag::Phase3ModelBudget)
  end

  test "the script preview does not construct a runtime client" do
    isolate_env("DIRECT_SENTENCE_ABLATION_REQUIRE", "1") do
      isolate_env("DIRECT_SENTENCE_ABLATION_CAPTURE", PHASE5.to_s) do
        load Rails.root.join("script/field_companion/direct_sentence_ablation.rb")
        isolate_env(Rag::DirectSentenceAblation::AUTHORIZED_ENV, nil) do
          Dir.mktmpdir("direct-sentence") do |dir|
            isolate_env("DIRECT_SENTENCE_ABLATION_OUTPUT", dir) do
              built = track_runtime_client_new do
                stdout, = capture_io { assert_equal 2, direct_sentence_ablation_main }
                preview = JSON.parse(stdout)
                assert_equal "preview", preview["status"]
                assert_equal false, preview["sent"]
                assert_equal PROMPT_SHA, preview["request"]["original_prompt_sha256"]
                assert_equal INVOKE_BODY_SHA, preview["request"]["original_invoke_body_sha256"]
              end
              assert_equal false, built
            end
          end
        end
      end
    end
  end

  private

  def authorized
    isolate_env(Rag::DirectSentenceAblation::AUTHORIZED_ENV, "1") do
      isolate_env("AWS_MAX_ATTEMPTS", "1") { yield }
    end
  end

  def run_dir(dir, client)
    Rag::DirectSentenceAblation.run(capture_dir: PHASE5, output_dir: dir, client: client)
  end

  def run_in(capture, client)
    Dir.mktmpdir("direct-sentence") do |dir|
      return Rag::DirectSentenceAblation.run(capture_dir: capture, output_dir: dir, client: client)
    end
  end

  def with_phase5
    Dir.mktmpdir("phase5-capture") do |dir|
      destination = Pathname(dir)
      FileUtils.cp_r("#{PHASE5}/.", destination)
      yield destination
    end
  end

  def write_reading(dir, attempt, identity_passed:, partial:)
    payload = {
      "identity" => "anotada",
      "function" => "anotada",
      "voltage" => "anotada",
      "dp_category" => "anotada",
      "prescribed_check" => "anotada",
      "location_path" => "anotada",
      "usefulness" => "anotada",
      "identity_passed" => identity_passed,
      "partial" => partial
    }
    File.write(Pathname(dir).join(format("sample_%d", attempt), "reading.json"), "#{JSON.generate(payload)}\n")
  end

  def recording_client(text: "muestra", error: nil, retry_limit: 0)
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
          "id" => "msg_test",
          "model" => "anthropic.claude-haiku-4-5-20251001-v1:0",
          "content" => [ { "text" => @text } ],
          "usage" => { "input_tokens" => 100, "output_tokens" => 20 },
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

  def with_single_removal(implementation)
    klass = Rag::DirectSentenceAblation
    original = klass.method(:single_removal?)
    klass.define_singleton_method(:single_removal?, implementation)
    yield
  ensure
    klass.define_singleton_method(:single_removal?, original)
  end

  def disarm_budgets
    Rag::Phase1ModelBudget.disarm! if defined?(Rag::Phase1ModelBudget)
    Rag::Phase2ModelBudget.disarm! if defined?(Rag::Phase2ModelBudget)
    Rag::Phase3ModelBudget.disarm! if defined?(Rag::Phase3ModelBudget)
  end

  def sha(text)
    Digest::SHA256.hexdigest(text.b)
  end

  def sha_file(path)
    Digest::SHA256.file(path).hexdigest
  end
end
