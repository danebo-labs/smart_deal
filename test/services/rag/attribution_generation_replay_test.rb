# frozen_string_literal: true

require "test_helper"
require "stringio"

class Rag::AttributionGenerationReplayTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:legacy)
    @output = Rails.root.join("tmp/attribution_generation_replay_test/#{SecureRandom.hex(4)}")
  end

  teardown do
    FileUtils.rm_rf(@output)
  end

  test "invalid bytes refuse instead of raising" do
    preview = Rag::AttributionGenerationReplay.preview(captured_prompt: "\xFF\xFE".b, account: @account)

    assert_equal "refused", preview.status
    assert_equal "encoding", preview.reason
  end

  test "a binary capture with the same bytes still passes the gate" do
    captured = fabricated_capture.dup.force_encoding(Encoding::ASCII_8BIT)
    preview = Rag::AttributionGenerationReplay.preview(captured_prompt: captured, account: @account)

    assert preview.allowed?, preview.reason
    assert_equal Encoding::UTF_8, preview.prompt.encoding
  end

  test "preview accepts only the three lines, the contract, and the two inference clauses" do
    captured = fabricated_capture
    calls = []
    preview = Rag::AttributionGenerationReplay.preview(captured_prompt: captured, account: @account)

    assert preview.allowed?, preview.reason
    assert_equal 3, Rag::AttributionGenerationReplay.field_guidance_lines.size
    assert_includes captured, "Reason, infer, and conclude from chunks"
    assert_includes captured, "Como verificación de campo"
    assert_not_includes preview.prompt, "Reason, infer, and conclude from chunks"
    assert_not_includes preview.prompt, "Como verificación de campo"
    assert_includes preview.prompt, "relating compatible fragments of the same document is allowed"
    assert_includes preview.prompt, "Do not invent a torque, distance, time, crew size, tool size, brand, model, part code, terminal, or setting"
    assert_includes preview.prompt, "Según el manual"
    assert_not_includes preview.prompt, "what is obvious for that kind of component and function"
    assert_not_includes preview.prompt, "Open with what the technician can check or do next"
    assert_not_includes preview.prompt, "layer-3 observations"
    assert_includes preview.prompt, "Keep documented statements, optional interpretations, and missing information distinct"
    assert_includes preview.prompt, "ACTION and EXPECTED_RESULT lines in FIELD_RECORD are extraction annotations"
    assert_not_includes preview.prompt, "When the passages state only a label and its location"
    assert_includes preview.prompt, "Do not replace a procedure the retrieved text already documents."
    assert_includes preview.prompt, "Etiqueta visible en el bus."
    run_without_authorization(captured, calls)
    assert_empty calls
  end

  test "an extra sentence in the captured results refuses the call" do
    captured = fabricated_capture.sub("</search_result>\n", "</search_result>\nNota que no estaba en la captura.\n")
    calls = []

    result = Rag::AttributionGenerationReplay.run(
      captured_prompt: captured,
      account: @account,
      client: failing_client(calls),
      output_dir: @output
    )

    assert_equal "refused", result.status
    assert_equal "search_results_changed", result.reason
    assert_empty calls
    assert_not @output.exist?
  end

  test "changing a kept restriction refuses the call" do
    captured = fabricated_capture.sub("Do not invent a torque", "Do not invent a torque value")
    calls = []

    result = Rag::AttributionGenerationReplay.run(
      captured_prompt: captured,
      account: @account,
      client: failing_client(calls),
      output_dir: @output
    )

    assert_equal "refused", result.status
    assert_equal "prompt_delta", result.reason
    assert_empty calls
    assert_not @output.exist?
  end

  test "an extra instruction refuses the call" do
    captured = fabricated_capture.sub("# FORMAT\n", "# FORMAT\n- Extra instruction that the captured prompt did not have.\n")
    calls = []

    result = Rag::AttributionGenerationReplay.run(
      captured_prompt: captured,
      account: @account,
      client: failing_client(calls),
      output_dir: @output
    )

    assert_equal "refused", result.status
    assert_equal "prompt_delta", result.reason
    assert_empty calls
    assert_not @output.exist?
  end

  test "authorization and a passing gate call twice and export request response and usage" do
    captured = fabricated_capture
    calls = []
    client = generation_client(calls)

    result = isolate_env(Rag::AttributionGenerationReplay::AUTHORIZED_ENV, "1") do
      isolate_env(Rag::AttributionGenerationReplay::CORRELATION_TAG_ENV, nil) do
        Rag::AttributionGenerationReplay.run(
          captured_prompt: captured,
          account: @account,
          client: client,
          output_dir: @output
        )
      end
    end

    assert_equal "recorded", result.status
    assert_equal 2, calls.size
    assert_equal %w[phase2:attr:gen:voices:1 phase2:attr:gen:voices:2], result.generations.pluck("correlation_id")
    calls.each_with_index do |params, index|
      body = JSON.parse(params.fetch(:body))
      assert_equal Rag::AttributionGenerationReplay::MODEL_ID, params.fetch(:model_id)
      assert_equal 3000, body.fetch("max_tokens")
      assert_in_delta 0.1, body.fetch("temperature")
      assert_equal result.prompt, body.dig("messages", 0, "content")
      generation = result.generations[index]
      assert_equal params.fetch(:model_id), generation.dig("request", "model_id")
      assert_equal 3000, generation.dig("request", "max_tokens")
      assert_in_delta 0.1, generation.dig("request", "temperature")
      assert_equal "respuesta #{index + 1}", generation.dig("response", "text")
      assert_equal 11, generation.dig("usage", "input_tokens")
      assert_equal 7, generation.dig("usage", "output_tokens")
      folder = @output.join(format("gen_%d", index + 1))
      assert_equal generation.dig("response", "text"), File.read(folder.join("response.txt"), encoding: "UTF-8")
      assert_equal result.prompt, File.read(folder.join("prompt.txt"), encoding: "UTF-8")
      assert_equal generation["request"], JSON.parse(File.read(folder.join("request.json")))
      assert_equal generation["usage"], JSON.parse(File.read(folder.join("usage.json")))
    end
  end

  test "correlation tags default to voices and reject a malformed or historical id" do
    replay = Rag::AttributionGenerationReplay

    assert_equal "voices", replay.correlation_tag(nil)
    assert_equal "voices", replay.correlation_tag("  ")
    assert_equal %w[phase2:attr:gen:voices:1 phase2:attr:gen:voices:2], replay.correlations_for(nil)
    assert_equal %w[phase2:attr:gen:lane:1 phase2:attr:gen:lane:2], replay.correlations_for("lane")
    assert_nil replay.correlation_tag("voices:1")
    assert_nil replay.correlation_tag("1")
    assert_nil replay.correlations_for("VOICES")
    assert_empty replay.correlations_for("voices") & replay::HISTORICAL_CORRELATIONS
  end

  test "an invalid correlation tag refuses before the model" do
    calls = []

    result = isolate_env(Rag::AttributionGenerationReplay::AUTHORIZED_ENV, "1") do
      Rag::AttributionGenerationReplay.run(
        captured_prompt: fabricated_capture,
        account: @account,
        client: failing_client(calls),
        output_dir: @output,
        correlation_tag: "voices:1"
      )
    end

    assert_equal "refused", result.status
    assert_equal "correlation_tag", result.reason
    assert_empty calls
    assert_not @output.exist?
  end

  test "an explicit tag names both generations and ignores a historical env value" do
    calls = []

    result = isolate_env(Rag::AttributionGenerationReplay::AUTHORIZED_ENV, "1") do
      isolate_env(Rag::AttributionGenerationReplay::CORRELATION_TAG_ENV, "phase2:attr:gen:1") do
        Rag::AttributionGenerationReplay.run(
          captured_prompt: fabricated_capture,
          account: @account,
          client: generation_client(calls),
          output_dir: @output,
          correlation_tag: "lane"
        )
      end
    end

    assert_equal "recorded", result.status
    assert_equal %w[phase2:attr:gen:lane:1 phase2:attr:gen:lane:2], result.generations.pluck("correlation_id")
    assert_equal 2, calls.size
  end

  test "the script refuses before constructing a generation client when authorization is absent" do
    previous = ENV["PHASE2_ATTRIBUTION_GENERATION_REQUIRE"]
    authorized = ENV[Rag::AttributionGenerationReplay::AUTHORIZED_ENV]
    ENV["PHASE2_ATTRIBUTION_GENERATION_REQUIRE"] = "1"
    ENV.delete(Rag::AttributionGenerationReplay::AUTHORIZED_ENV)
    load Rails.root.join("script/field_companion/phase2_attribution_generation.rb")

    assert_equal 2, phase2_attribution_generation_main
  ensure
    restore_env("PHASE2_ATTRIBUTION_GENERATION_REQUIRE", previous)
    restore_env(Rag::AttributionGenerationReplay::AUTHORIZED_ENV, authorized)
  end

  test "the script refuses an invalid correlation tag before constructing a generation client" do
    previous_require = ENV["PHASE2_ATTRIBUTION_GENERATION_REQUIRE"]
    previous_auth = ENV[Rag::AttributionGenerationReplay::AUTHORIZED_ENV]
    previous_tag = ENV[Rag::AttributionGenerationReplay::CORRELATION_TAG_ENV]
    ENV["PHASE2_ATTRIBUTION_GENERATION_REQUIRE"] = "1"
    ENV[Rag::AttributionGenerationReplay::AUTHORIZED_ENV] = "1"
    ENV[Rag::AttributionGenerationReplay::CORRELATION_TAG_ENV] = "voices:1"
    load Rails.root.join("script/field_companion/phase2_attribution_generation.rb")
    constructed = false
    singleton = BedrockClient.singleton_class
    singleton.define_method(:new) do |*|
      constructed = true
      flunk "the script constructed a generation client"
    end

    assert_equal 2, phase2_attribution_generation_main
    assert_equal false, constructed
  ensure
    singleton&.remove_method(:new) if singleton&.method_defined?(:new, false)
    restore_env("PHASE2_ATTRIBUTION_GENERATION_REQUIRE", previous_require)
    restore_env(Rag::AttributionGenerationReplay::AUTHORIZED_ENV, previous_auth)
    restore_env(Rag::AttributionGenerationReplay::CORRELATION_TAG_ENV, previous_tag)
  end

  private

  def restore_env(key, value)
    value.nil? ? ENV.delete(key) : ENV[key] = value
  end

  def fabricated_capture
    candidate = nil
    isolate_env("RAG_GROUNDED_SYNTHESIS_ENABLED", "true") do
      isolate_env("RAG_GROUNDED_SYNTHESIS_ACCOUNT_IDS", nil) do
        isolate_env("RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED", nil) do
          service = BedrockRagService.new(account: @account, knowledge_base_id: "test-kb")
          candidate = service.send(
            :document_identity_generation_prompt,
            "etiqueta del plano",
            [ { content: "Etiqueta visible en el bus." } ],
            labels: [ "THIS JOB'S EQUIPMENT: Plano" ],
            response_locale: :es,
            session_context: session_context,
            output_channel: :web
          )
        end
      end
    end
    captured = candidate.sub(
      BedrockRagService::DOCUMENT_IDENTITY_ATTRIBUTION_CONTRACT,
      Rag::AttributionGenerationReplay::CAPTURED_CONTRACT
    )
    Rag::AttributionGenerationReplay.field_guidance_lines.each do |line|
      captured = captured.sub("# FORMAT\n", "#{line}# FORMAT\n")
    end
    restore_inference_clauses(captured)
  end

  def restore_inference_clauses(prompt)
    clauses = BedrockRagService::DOCUMENT_IDENTITY_INFERENCE_CLAUSES
    prompt = prompt.sub(
      "in running prose. Use facts",
      "in running prose. #{clauses[0]}Use facts"
    )
    prompt.sub(
      '("Según el manual …").',
      "(\"Según el manual …\").#{clauses[1]}"
    )
  end

  def session_context
    <<~TEXT.strip
      ## Active Field Problem
      Goal: ubicar una etiqueta

      ## Session Focus
      - [document] Plano

      ## Recent Conversation
      User: etiqueta del plano

      ## Session Discipline
      Keep the pin.

      ## Query Resolution
      - "Plano" -> plano.pdf
    TEXT
  end

  def run_without_authorization(captured, calls)
    isolate_env(Rag::AttributionGenerationReplay::AUTHORIZED_ENV, nil) do
      result = Rag::AttributionGenerationReplay.run(
        captured_prompt: captured,
        account: @account,
        client: failing_client(calls),
        output_dir: @output
      )
      assert_equal "refused", result.status
      assert_equal "authorization_absent", result.reason
    end
  end

  def failing_client(calls)
    client = Object.new
    client.define_singleton_method(:generate_text) do |*|
      calls << :called
      flunk "the replay called the model"
    end
    client
  end

  def generation_client(calls)
    client = BedrockClient.allocate
    aws = Object.new
    aws.define_singleton_method(:invoke_model) do |params|
      calls << params
      payload = {
        "content" => [ { "text" => "respuesta #{calls.size}" } ],
        "usage" => { "input_tokens" => 11, "output_tokens" => 7 },
        "stop_reason" => "end_turn"
      }
      Struct.new(:body).new(StringIO.new(payload.to_json))
    end
    client.instance_variable_set(:@client, aws)
    client
  end
end
