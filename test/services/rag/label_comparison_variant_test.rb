# frozen_string_literal: true

require "test_helper"
require "stringio"

class Rag::LabelComparisonVariantTest < ActiveSupport::TestCase
  PHASE5 = Rails.root.join("test/fixtures/files/field_companion/phase5_generation_20261014")
  PHASE3 = Rails.root.join("test/fixtures/files/field_companion/phase3_summary_20261014T194442Z/turn_3")
  REQUEST_SHA = "2f8e64afef98363ca5590f531d8741ee3f8d240eeecc21679cb475cbb29c9011"
  INVOKE_BODY_SHA = "9b0d8861a4da67c97fbe7c019238fafa3207bdd5fcaa867932699f5c7678d9c6"
  PROMPT_SHA = "8a771ae3aedee0ddda50dec7c347e843e5daee3c95060dbaa2d00ce6dae33b6a"
  SYSTEM_SHA = "81a7dfd85e2415d2527a6537b35b540aa03a5a69b2bd06f643c8479ff0031024"
  USER_SHA = "e9d4ba63418d15e4820c4197bdfd17aa4dae7a81cf68527eab0d61c69a6d12b2"
  MODEL_ID = "global.anthropic.claude-haiku-4-5-20251001-v1:0"
  HISTORICAL = Rag::LabelComparisonVariant::HISTORICAL_PARAGRAPH
  CANDIDATE = Rag::LabelComparisonVariant::CANDIDATE_PARAGRAPH

  setup { disarm_budgets }
  teardown { disarm_budgets }

  test "construction substitutes one paragraph and does not score an answer" do
    original = "before\n#{HISTORICAL}\nafter"
    once = Rag::LabelComparisonVariant.substitute(original)

    assert_equal 1, once.occurrences
    assert_nil once.problem
    assert_equal "before\n#{CANDIDATE}\nafter", once.text
    assert_equal original, once.text.sub(CANDIDATE, HISTORICAL)
    assert_equal 0, once.text.scan(HISTORICAL).size
    assert_equal 1, once.text.scan(CANDIDATE).size

    twice = Rag::LabelComparisonVariant.substitute("#{original}\n#{HISTORICAL}")
    assert_nil twice.text
    assert_equal 2, twice.occurrences
    assert_equal "occurrences", twice.problem

    missing = Rag::LabelComparisonVariant.substitute("sin el parrafo")
    assert_nil missing.text
    assert_equal 0, missing.occurrences

    present = Rag::LabelComparisonVariant.substitute(once.text)
    assert_equal "candidate_already_present", present.problem
    assert_nil Rag::LabelComparisonVariant.production_problem(BedrockRagService::DOCUMENT_IDENTITY_ATTRIBUTION_CONTRACT)
    assert_equal({ "problem" => "candidate_adopted" }, Rag::LabelComparisonVariant.production_problem(CANDIDATE))

    contract = BedrockRagService::DOCUMENT_IDENTITY_ATTRIBUTION_CONTRACT
    assert contract.end_with?(HISTORICAL)
    assert_equal 1, contract.scan(HISTORICAL).size
    assert_not_includes contract, CANDIDATE
    assert_not_includes CANDIDATE, "\n"
    %w[Chapa Elemont salida 24V].each { |term| assert_not_includes CANDIDATE.downcase, term.downcase }
    assert_not_equal HISTORICAL, CANDIDATE

    attribution = Rails.root.join("test/services/rag/attribution_generation_replay_test.rb").read
    assert_includes attribution, "09bf470335afbb3d526356034a2fa410642262f3d764d4f35675ff09329c9fa6"
    assert_includes attribution, "8b40b274a9eac2597bd0e9afbce7d60afde3c16b38122477a33c521e9303947a"
    scope = Rails.root.join("test/services/rag/document_identity_scope_test.rb").read
    assert_includes scope, "When distinguishing two labels, explain their documented sections and locations first"
    assert_not_includes scope, "When the question compares two labels"
    source = Rails.root.join("app/services/rag/label_comparison_variant.rb").read
    assert_not_includes source, "generate_text"
    assert_not_includes source, "TrackBedrockQueryJob"
    assert_not_includes source, "sanitize_answer"
    assert_equal 0, Rag::Stage2RunBudget::PASS_CALL_CAP
  end

  test "preview keeps the captured hashes and records one substitution" do
    preview = Rag::LabelComparisonVariant.preview(
      phase5_capture: PHASE5, phase3_capture: PHASE3, output_dir: Rails.root.join("tmp/label-comparison-preview-absent")
    )

    assert_equal "preview", preview.status
    assert_equal false, preview.to_h["sent"]
    assert_equal "b1", preview.step
    assert_equal false, preview.partial
    assert_equal "not_authorized", preview.to_h["adoption"]
    assert_equal false, preview.to_h["partial_authorizes_adoption"]
    assert_equal false, preview.to_h["partial_closes_phases"]
    assert_equal "not_accepted", preview.to_h["phase3_acceptance"]
    assert_equal "not_accepted", preview.to_h["phase5_acceptance"]
    assert_equal "unchanged", preview.to_h["phase4_status"]
    assert_equal "not_validated", preview.to_h["episode"]
    assert_equal false, preview.to_h["production_constant_adopted"]
    assert_equal 3, preview.to_h["attempt_cap"]
    assert_equal false, preview.to_h["retries"]
    request = preview.request
    assert_equal MODEL_ID, request["model_id"]
    assert_equal 0.1, request["temperature"]
    assert_equal 3000, request["max_tokens"]
    assert_equal "bedrock-2023-05-31", request["anthropic_version"]
    assert_equal false, request["stream"]
    assert_equal 1, request["paragraph_occurrences"]
    assert_equal [ "phase5:replay:b:v2:1", "phase5:replay:b:v2:2", "phase3:summary:v2:1" ], request["correlations"]
    assert_empty request["correlations"] & request["historical_correlations_not_reused"]
    assert_equal "b/sample_1", request.dig("directories", "b_sample_1")
    assert_equal "b/sample_2", request.dig("directories", "b_sample_2")
    assert_equal "a/sample_1", request.dig("directories", "a_sample_1")

    b_prompt = File.binread(PHASE5.join("prompt_single_user.txt"))
    b_variant = Rag::LabelComparisonVariant.substitute(b_prompt)
    assert_equal b_prompt.sub(HISTORICAL, CANDIDATE), b_variant.text
    b = request["b"]
    assert_equal false, b["system"]
    assert_equal REQUEST_SHA, b["log_request_sha256"]
    assert_equal 47_221, b["log_request_bytes"]
    assert_equal PROMPT_SHA, b["original_prompt_sha256"]
    assert_equal 46_068, b["original_prompt_bytes"]
    assert_equal sha(b_variant.text), b["candidate_prompt_sha256"]
    assert_equal "66a0314a9b777ef584cdb1c5ffba42b60a2e49ecddf7d51b00067738bca93a34", b["candidate_prompt_sha256"]
    assert_equal 46_855, b["candidate_prompt_bytes"]
    assert_not_equal PROMPT_SHA, b["candidate_prompt_sha256"]
    assert_equal INVOKE_BODY_SHA, b["original_invoke_body_sha256"]
    assert_equal 47_331, b["original_invoke_body_bytes"]
    assert_equal "d722373585fb302b9d18f971c32d142d3f5ff6f0248004bff62069303a6f4bed", b["candidate_invoke_body_sha256"]
    assert_equal 48_118, b["candidate_invoke_body_bytes"]
    assert_operator b["candidate_prompt_bytes"], :>, b["original_prompt_bytes"]

    system = File.binread(PHASE3.join("bodies/b0007.txt"))
    user = File.binread(PHASE3.join("bodies/b0008.txt"))
    a_variant = Rag::LabelComparisonVariant.substitute(system)
    assert_equal system.sub(HISTORICAL, CANDIDATE), a_variant.text
    assert_not_includes user, HISTORICAL
    a = request["a"]
    assert_equal true, a["system"]
    assert_equal true, a["user_intact"]
    assert_equal SYSTEM_SHA, a["original_system_sha256"]
    assert_equal 13_668, a["original_system_bytes"]
    assert_equal "81f8e8a18c714e8f5b545ab5561e27d54e6199c0a3a708869b7c5e724d74be22", a["candidate_system_sha256"]
    assert_equal 14_455, a["candidate_system_bytes"]
    assert_not_equal SYSTEM_SHA, a["candidate_system_sha256"]
    assert_equal USER_SHA, a["user_sha256"]
    assert_equal 23_415, a["user_bytes"]
    assert_equal "reconstructed_from_captured_system_and_user", a["original_invoke_body_provenance"]
    assert_equal 64, a["original_invoke_body_sha256"].length
    assert_equal 64, a["candidate_invoke_body_sha256"].length
    assert_not_equal a["original_invoke_body_sha256"], a["candidate_invoke_body_sha256"]
    assert_equal "phase3:summary:v2:1", a["correlation"]
    assert_equal "378c633f9f425b915ce46f12fb0118b9c73ba98ee115feaeead4b9a27c9e2a11", request.dig("paragraph", "historical_sha256")
    assert_equal 526, request.dig("paragraph", "historical_bytes")
    assert_equal "4efaa3060c7b1f025505908a9c4d596759005615056f519de717351622d29696", request.dig("paragraph", "candidate_sha256")
    assert_equal 1313, request.dig("paragraph", "candidate_bytes")
    assert_equal "5f4b6623921ca7c501ab095ce2c9b37228cb93f667f6b63be017f418724cbd1b", a["original_invoke_body_sha256"]
    assert_equal 38_114, a["original_invoke_body_bytes"]
    assert_equal "6f777a5e9d9c2338151661e3307f4ebefb44ff20f1e09ebe1f9d90d8c75b9566", a["candidate_invoke_body_sha256"]
    assert_equal 38_901, a["candidate_invoke_body_bytes"]
    assert_operator request.dig("paragraph", "delta_bytes"), :>, 0

    quota = preview.quota
    assert_equal 0, quota["calls_recorded"]
    assert_equal 1, quota["calls_the_next_authorized_process_would_send"]
    assert_equal "b1", quota["next_step"]
    assert_equal "0.018221", quota["estimated_usd_b_reference"]
    assert_equal "0.014653", quota["estimated_usd_a_reference"]
    assert_equal "0.051095", quota["estimated_usd_cap_reference"]
    assert_equal false, quota["estimate_is_ceiling"]
    assert_equal false, quota["retries"]
    assert_equal "not_authorized", quota["adoption"]
    assert_equal REQUEST_SHA, Digest::SHA256.file(PHASE5.join("request_body.json")).hexdigest
    assert_equal PROMPT_SHA, Digest::SHA256.file(PHASE5.join("prompt_single_user.txt")).hexdigest
    assert_equal SYSTEM_SHA, Digest::SHA256.file(PHASE3.join("bodies/b0007.txt")).hexdigest
    assert_equal USER_SHA, Digest::SHA256.file(PHASE3.join("bodies/b0008.txt")).hexdigest
  end

  test "the built bodies differ only by that paragraph and keep the same parameters" do
    preview = Rag::LabelComparisonVariant.preview(phase5_capture: PHASE5, phase3_capture: PHASE3)
    b_prompt = File.binread(PHASE5.join("prompt_single_user.txt")).force_encoding(Encoding::UTF_8)
    candidate_prompt = b_prompt.sub(HISTORICAL, CANDIDATE)
    original_b = JSON.parse(Rag::Phase5GenerationReplay.invoke_body_for(
      anthropic_version: "bedrock-2023-05-31", max_tokens: 3000, temperature: 0.1, content: b_prompt
    ))
    variant_b = JSON.parse(Rag::Phase5GenerationReplay.invoke_body_for(
      anthropic_version: "bedrock-2023-05-31", max_tokens: 3000, temperature: 0.1, content: candidate_prompt
    ))

    assert_equal %w[anthropic_version max_tokens temperature messages], original_b.keys
    assert_equal original_b.keys, variant_b.keys
    assert_equal false, variant_b.key?("system")
    assert_equal false, variant_b.key?("model")
    assert_equal original_b.except("messages"), variant_b.except("messages")
    assert_equal candidate_prompt.b, variant_b.dig("messages", 0, "content").b
    assert_equal sha(candidate_prompt), preview.request.dig("b", "candidate_prompt_sha256")
    assert_equal INVOKE_BODY_SHA, preview.request.dig("b", "original_invoke_body_sha256")

    system = File.binread(PHASE3.join("bodies/b0007.txt")).force_encoding(Encoding::UTF_8)
    user = File.binread(PHASE3.join("bodies/b0008.txt")).force_encoding(Encoding::UTF_8)
    candidate_system = system.sub(HISTORICAL, CANDIDATE)
    original_a = JSON.parse(phase3_body(system, user))
    variant_a = JSON.parse(phase3_body(candidate_system, user))
    assert_equal %w[anthropic_version max_tokens temperature messages system], variant_a.keys
    assert_equal original_a.except("system"), variant_a.except("system")
    assert_equal user.b, variant_a.dig("messages", 0, "content").b
    assert_equal USER_SHA, sha(variant_a.dig("messages", 0, "content"))
    assert_equal candidate_system.b, variant_a["system"].b
    assert_equal sha(candidate_system), preview.request.dig("a", "candidate_system_sha256")
    assert_equal sha(phase3_body(system, user)), preview.request.dig("a", "original_invoke_body_sha256")
    assert_equal sha(phase3_body(candidate_system, user)), preview.request.dig("a", "candidate_invoke_body_sha256")
  end

  test "a changed capture or a different parameter is blocked before the client" do
    client = recording_client
    authorized do
      with_phase5 do |root|
        path = root.join("request_body.json")
        bytes = path.binread
        bytes.setbyte(20, (bytes.getbyte(20) + 1) % 256)
        path.binwrite(bytes)
        refused = run_in(root, PHASE3, client)

        assert_equal "blocked", refused.status
        assert_equal "sha256", refused.reason
        assert_equal "request_body.json", refused.detail["field"]
        assert_equal REQUEST_SHA, refused.detail["expected_sha256"]
        assert_not_equal REQUEST_SHA, refused.detail["actual_sha256"]
        assert_empty client.calls
      end

      with_phase3 do |root|
        capture = JSON.parse(root.join("capture.json").read)
        prepared = capture["events"].find { |event| event["kind"] == "generate_text" && event["result"] == "prepared" }
        prepared["temperature"] = 0.2
        root.join("capture.json").write(JSON.generate(capture))
        refused = run_in(PHASE5, root, client)

        assert_equal "blocked", refused.status
        assert_equal "parameter_mismatch", refused.reason
        assert_equal 0.2, refused.detail.dig("a", "temperature")
        assert_equal 0.1, refused.detail.dig("b", "temperature")
        assert_empty client.calls
      end
    end
  end

  test "the first call sends only the variant body and leaves the captures unchanged" do
    before = {
      PHASE5.join("prompt_single_user.txt") => sha_file(PHASE5.join("prompt_single_user.txt")),
      PHASE3.join("bodies/b0007.txt") => sha_file(PHASE3.join("bodies/b0007.txt")),
      PHASE3.join("bodies/b0008.txt") => sha_file(PHASE3.join("bodies/b0008.txt"))
    }
    client = recording_client
    authorized do
      Dir.mktmpdir("label-comparison") do |dir|
        result = Rag::LabelComparisonVariant.run(
          phase5_capture: PHASE5, phase3_capture: PHASE3, output_dir: dir, client: client
        )

        assert_equal "recorded", result.status
        assert_equal 1, client.calls.size
        call = client.calls.first
        assert_equal MODEL_ID, call[:model_id]
        parsed = JSON.parse(call[:body])
        assert_equal %w[anthropic_version max_tokens temperature messages], parsed.keys
        assert_equal 0.1, parsed["temperature"]
        assert_equal 3000, parsed["max_tokens"]
        assert_equal sha(File.binread(PHASE5.join("prompt_single_user.txt")).sub(HISTORICAL, CANDIDATE)),
          sha(parsed.dig("messages", 0, "content"))
        assert_equal 0, parsed.dig("messages", 0, "content").scan(HISTORICAL).size
        sample = Pathname(dir).join("b/sample_1")
        assert_equal call[:body].b, File.binread(sample.join("request_body.json"))
        request = JSON.parse(sample.join("request.json").read)
        assert_equal "phase5:replay:b:v2:1", request["correlation_id"]
        assert_equal true, request["sent"]
        events = JSON.parse(sample.join("events.json").read)
        assert_equal %w[prepared attempt_started returned], events.map { |event| event["result"] }
        assert_equal false, events.first.dig("request", "sent")
        template = JSON.parse(sample.join("reading.template.json").read)
        assert_nil template["identity_passed"]
        assert_nil template["partial"]
        assert_includes template["note"], "no autoriza adopción"
        assert_includes template["note"], "no lee la respuesta"
        assert_includes template["note"], "evidencia gráfica"
        assert_includes template["note"], "inferencia fundada"
        assert_includes template["note"], "por significado"
        assert_includes template["note"], "Chapa nivel 3 en la Botonera"
        assert_not sample.join("reading.json").exist?
        assert_not Pathname(dir).join("b/sample_2").exist?
        assert_not Pathname(dir).join("a/sample_1").exist?
        assert_equal "reading_absent", result.quota["dispatch"]
        assert_equal 0, result.quota["calls_the_next_authorized_process_would_send"]
      end
    end
    before.each { |path, digest| assert_equal digest, sha_file(path) }
  end

  test "identity gates the next call and a partial result does not authorize adoption" do
    authorized do
      Dir.mktmpdir("label-comparison") do |dir|
        Rag::LabelComparisonVariant.run(
          phase5_capture: PHASE5, phase3_capture: PHASE3, output_dir: dir, client: recording_client
        )
        waiting = recording_client
        absent = run_dir(dir, waiting)
        assert_equal "refused", absent.status
        assert_equal "reading_absent", absent.reason
        assert_empty waiting.calls

        write_reading(dir, "b", 1, identity_passed: "false", partial: false)
        invalid = run_dir(dir, waiting)
        assert_equal "refused", invalid.status
        assert_equal "reading_invalid", invalid.reason
        assert_empty waiting.calls

        write_reading(dir, "b", 1, identity_passed: false, partial: true)
        mixed = run_dir(dir, waiting)
        assert_equal "refused", mixed.status
        assert_equal "reading_invalid", mixed.reason
        assert_empty waiting.calls

        write_reading(dir, "b", 1, identity_passed: false, partial: false)
        repeated = run_dir(dir, waiting)
        assert_equal "refused", repeated.status
        assert_equal "identity_repeated", repeated.reason
        assert_equal false, repeated.to_h["partial_authorizes_adoption"]
        assert_empty waiting.calls
        assert_not Pathname(dir).join("b/sample_2").exist?

        write_reading(dir, "b", 1, identity_passed: true, partial: true)
        second = recording_client(text: "muestra b2")
        recorded = run_dir(dir, second)
        assert_equal "recorded", recorded.status
        assert_equal true, recorded.partial
        assert_equal "not_authorized", recorded.to_h["adoption"]
        assert_equal false, recorded.to_h["partial_closes_phases"]
        assert_equal 1, second.calls.size
        assert_equal "phase5:replay:b:v2:2", JSON.parse(Pathname(dir).join("b/sample_2/request.json").read)["correlation_id"]
        assert_equal REQUEST_SHA, sha_file(PHASE5.join("request_body.json"))

        write_reading(dir, "b", 2, identity_passed: false, partial: false)
        stopped = run_dir(dir, waiting)
        assert_equal "refused", stopped.status
        assert_equal "identity_repeated", stopped.reason
        assert_not Pathname(dir).join("a").exist?
      end
    end
  end

  test "A is sent only after both B samples pass identity and the user bytes stay intact" do
    authorized do
      Dir.mktmpdir("label-comparison") do |dir|
        run_dir(dir, recording_client(text: "b1"))
        write_reading(dir, "b", 1, identity_passed: true, partial: false)
        run_dir(dir, recording_client(text: "b2"))
        write_reading(dir, "b", 2, identity_passed: true, partial: true)
        user_before = File.binread(PHASE3.join("bodies/b0008.txt"))
        client = recording_client(text: "a1")
        result = run_dir(dir, client)

        assert_equal "recorded", result.status
        assert_equal true, result.partial
        assert_equal "not_authorized", result.to_h["adoption"]
        assert_equal "not_accepted", result.to_h["phase3_acceptance"]
        assert_equal "not_accepted", result.to_h["phase5_acceptance"]
        assert_equal 1, client.calls.size
        parsed = JSON.parse(client.calls.first[:body])
        assert_equal %w[anthropic_version max_tokens temperature messages system], parsed.keys
        assert_equal user_before.b, parsed.dig("messages", 0, "content").b
        assert_equal USER_SHA, sha(parsed.dig("messages", 0, "content"))
        assert_equal File.binread(PHASE3.join("bodies/b0007.txt")).sub(HISTORICAL, CANDIDATE).b, parsed["system"].b
        assert_equal 0.1, parsed["temperature"]
        assert_equal 3000, parsed["max_tokens"]
        assert_equal MODEL_ID, client.calls.first[:model_id]
        sample = Pathname(dir).join("a/sample_1")
        assert_equal user_before.b, File.binread(sample.join("user.txt"))
        assert_equal "phase3:summary:v2:1", JSON.parse(sample.join("request.json").read)["correlation_id"]
        assert_includes File.read(sample.join("reading.template.json")), "nivel 3"
        assert_not Pathname(dir).join("a/sample_2").exist?
        assert_not Pathname(dir).join("b/sample_3").exist?

        capped = run_dir(dir, recording_client)
        assert_equal "blocked", capped.status
        assert_equal "cap_reached", capped.reason
        assert_equal 0, capped.quota["calls_the_next_authorized_process_would_send"]
      end
    end
  end

  test "an error stops the sequence and is not replaced by the next call" do
    authorized do
      Dir.mktmpdir("label-comparison") do |dir|
        failed = recording_client(error: "variant boom")
        result = run_dir(dir, failed)

        assert_equal "recorded", result.status
        assert_equal true, result.detail["sequence_stopped"]
        assert_equal false, result.to_h["substitution_of_failed_call"]
        assert_equal 1, failed.calls.size
        events = JSON.parse(Pathname(dir).join("b/sample_1/events.json").read)
        assert_equal %w[prepared attempt_started error], events.map { |event| event["result"] }
        assert_not Pathname(dir).join("b/sample_1/response.txt").exist?
        again = recording_client
        second = run_dir(dir, again)
        assert_equal "refused", second.status
        assert_equal "sample_error", second.reason
        assert_empty again.calls
        assert_not Pathname(dir).join("b/sample_2").exist?
        assert_not Pathname(dir).join("a").exist?
      end

      Dir.mktmpdir("label-comparison") do |dir|
        run_dir(dir, recording_client)
        write_reading(dir, "b", 1, identity_passed: true, partial: false)
        failed = recording_client(error: "b2 boom")
        run_dir(dir, failed)
        trailing = recording_client
        refused = run_dir(dir, trailing)

        assert_equal "refused", refused.status
        assert_equal "sample_error", refused.reason
        assert_empty trailing.calls
        assert_not Pathname(dir).join("a").exist?
        assert_equal 1, failed.calls.size
      end
    end
  end

  test "authorization, retries, budgets, and the historical output directory block the client" do
    client = recording_client
    isolate_env(Rag::LabelComparisonVariant::AUTHORIZED_ENV, nil) do
      isolate_env("PHASE5_GENERATION_REPLAY_AUTHORIZED", "1") do
        isolate_env("AWS_MAX_ATTEMPTS", "1") do
          Dir.mktmpdir("label-comparison") do |dir|
            refused = run_dir(dir, client)
            assert_equal "refused", refused.status
            assert_equal "authorization_absent", refused.reason
            assert_empty client.calls
          end
        end
      end
    end

    limited = recording_client(retry_limit: 3)
    authorized do
      Dir.mktmpdir("label-comparison") do |dir|
        refused = run_dir(dir, limited)
        assert_equal "refused", refused.status
        assert_equal "retry_limit", refused.reason
        assert_empty limited.calls
        assert_not Pathname(dir).join("b").exist?
      end
    end

    Rag::Phase3PinnedTurn
    Rag::Phase3ModelBudget.arm!
    authorized do
      Dir.mktmpdir("label-comparison") do |dir|
        refused = run_dir(dir, client)
        assert_equal "refused", refused.status
        assert_equal "budget_armed", refused.reason
        assert_empty client.calls
        assert_equal 0, Rag::Phase3ModelBudget.attempts
      end
    end
    Rag::Phase3ModelBudget.disarm!

    historical_root = Rails.root.join("tmp/phase5_generation_replay/case_b")
    FileUtils.mkdir_p(historical_root)
    historical = historical_root.join("variant_must_not_write")
    before = historical_root.children.map(&:to_s).sort
    authorized do
      refused = Rag::LabelComparisonVariant.gate(
        phase5_capture: PHASE5, phase3_capture: PHASE3, output_dir: historical
      )
      assert_equal "blocked", refused.status
      assert_equal "evidence_overlaps_source", refused.reason
      assert_empty client.calls
    end
    assert_equal before, Rails.root.join("tmp/phase5_generation_replay/case_b").children.map(&:to_s).sort
    assert_not historical.exist?
  ensure
    FileUtils.rm_rf(historical) if historical&.exist?
  end

  test "the script preview does not construct a runtime client" do
    isolate_env("LABEL_COMPARISON_VARIANT_REQUIRE", "1") do
      isolate_env("LABEL_COMPARISON_VARIANT_PHASE5_CAPTURE", PHASE5.to_s) do
        isolate_env("LABEL_COMPARISON_VARIANT_PHASE3_CAPTURE", PHASE3.to_s) do
          load Rails.root.join("script/field_companion/label_comparison_variant.rb")
          isolate_env(Rag::LabelComparisonVariant::AUTHORIZED_ENV, nil) do
            Dir.mktmpdir("label-comparison") do |dir|
              isolate_env("LABEL_COMPARISON_VARIANT_OUTPUT", dir) do
                built = track_runtime_client_new do
                  stdout, = capture_io { assert_equal 2, label_comparison_variant_main }
                  preview = JSON.parse(stdout)
                  assert_equal "preview", preview["status"]
                  assert_equal false, preview["sent"]
                  assert_equal PROMPT_SHA, preview.dig("request", "b", "original_prompt_sha256")
                  assert_equal USER_SHA, preview.dig("request", "a", "user_sha256")
                  assert_equal "0.018221", preview.dig("quota", "estimated_usd_b_reference")
                end
                assert_equal false, built
              end
            end
          end
        end
      end
    end
  end

  private

  def authorized
    isolate_env(Rag::LabelComparisonVariant::AUTHORIZED_ENV, "1") do
      isolate_env("AWS_MAX_ATTEMPTS", "1") { yield }
    end
  end

  def run_dir(dir, client)
    Rag::LabelComparisonVariant.run(
      phase5_capture: PHASE5, phase3_capture: PHASE3, output_dir: dir, client: client
    )
  end

  def run_in(phase5, phase3, client)
    Dir.mktmpdir("label-comparison") do |dir|
      return Rag::LabelComparisonVariant.run(
        phase5_capture: phase5, phase3_capture: phase3, output_dir: dir, client: client
      )
    end
  end

  def with_phase5
    Dir.mktmpdir("phase5-capture") do |dir|
      destination = Pathname(dir)
      FileUtils.cp_r("#{PHASE5}/.", destination)
      yield destination
    end
  end

  def with_phase3
    Dir.mktmpdir("phase3-capture") do |dir|
      destination = Pathname(dir).join("turn_3")
      FileUtils.cp_r(PHASE3, destination)
      yield destination
    end
  end

  def phase3_body(system, user)
    Rag::Phase3SummaryGenerationReplay.invoke_body_for(
      anthropic_version: "bedrock-2023-05-31",
      max_tokens: 3000,
      temperature: 0.1,
      content: user,
      system: system
    )
  end

  def write_reading(dir, case_name, attempt, identity_passed:, partial:)
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
    File.write(Pathname(dir).join(case_name, format("sample_%d", attempt), "reading.json"), "#{JSON.generate(payload)}\n")
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
