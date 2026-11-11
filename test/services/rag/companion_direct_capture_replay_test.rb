# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tempfile"

class Rag::CompanionDirectCaptureReplayTest < ActiveSupport::TestCase
  NOTICE = "Esto no está en la documentación cargada en este turno."

  DIRECT_ENV = %w[
    RAG_COMPANION_GENERATION COMPANION_DIRECT_PROVIDER COMPANION_DIRECT_MODEL_ID
    COMPANION_DIRECT_MAX_TOKENS COMPANION_DIRECT_EFFORT COMPANION_DIRECT_THINKING
  ].freeze

  setup do
    @direct_env = DIRECT_ENV.index_with { |key| ENV[key] }
    DIRECT_ENV.each { |key| ENV.delete(key) }
    @require = ENV["GUION2_PROMPT_COMPARE_REQUIRE"]
    ENV["GUION2_PROMPT_COMPARE_REQUIRE"] = "1"
    load Rails.root.join("script/field_companion/replay_direct_prompt_compare.rb")
    @ledger = Tempfile.new("direct-capture-ledger")
    @ledger.write(JSON.generate(
      "call_cap" => 4,
      "attempts" => 0,
      "authorization" => { "after_attempt" => 0, "cost_usd" => "1.0" },
      "entries" => []
    ))
    @ledger.flush
  end

  teardown do
    @ledger&.close!
    @direct_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    @require.nil? ? ENV.delete("GUION2_PROMPT_COMPARE_REQUIRE") : ENV["GUION2_PROMPT_COMPARE_REQUIRE"] = @require
  end

  test "the prompt states the three generic limits and keeps the unloaded sentence" do
    text = Rails.root.join("app/prompts/bedrock/companion_direct.txt").read

    assert_equal 1, text.scan(NOTICE).size
    assert_includes text, "Lo que atribuyes a una fuente va como cita literal entre «»"
    assert_includes text, "Antes de publicar se elimina toda oración con [n] que no tenga una cita literal de esa fuente."
    assert_includes text, "Da los pasos de un procedimiento solo si consta que se cumple su condición documentada. Si falta confirmarla, cita la condición y omite los pasos."
    assert_includes text, "limítala a lo que el técnico negó"
    assert_includes text, "Distingue lo observado por el técnico, lo que dice la fuente y tu inferencia."
    assert_includes text, "no digas que el caso está resuelto ni que el equipo está bien."
    %w[VF5 Fermator fotocélula fotocelula autoajuste S1.9].each do |token|
      assert_not_includes text.downcase, token.downcase
    end
    assert BedrockRagService.allocate.send(:companion_generation_direct?)
  end

  test "session 269 requests match except the system text and the saved answers keep their rubric" do
    require_historical_capture("tmp/field_companion/vf5_direct_guiones/guion2/turn-1/capture.json")
    before = File.binread(@ledger.path)
    io = StringIO.new
    calls = []
    trace = TracePoint.new(:call) do |event|
      bedrock_new = event.method_id == :new && event.defined_class.to_s.include?("Bedrock")
      next unless bedrock_new || event.method_id == :converse || event.method_id == :converse_message

      calls << [ event.defined_class.to_s, event.method_id ]
    end
    code = trace.enable { Rag::CompanionDirectCaptureReplay.preflight(io: io, ledger_path: Pathname.new(@ledger.path)) }
    report = JSON.parse(io.string)

    assert_equal 0, code, io.string
    assert_equal true, report["ready"], io.string
    assert_equal true, report["stopped_before_model"]
    assert_equal "not_executed", report["paid_run"]
    assert_equal Rag::CompanionDirectCaptureReplay::SESSION_SYSTEM_SHA, report["captured_system_sha256"]
    assert_equal true, report["system_changed"]
    assert_empty report["missing"]
    assert_equal [ "user" ], report.dig("turns", 0, "roles")
    assert_equal [ "user", "assistant", "user" ], report.dig("turns", 1, "roles")
    assert_equal [ "user", "assistant", "user", "assistant", "user" ], report.dig("turns", 2, "roles")
    report["turns"].each do |turn|
      assert_equal "global.anthropic.claude-haiku-4-5-20251001-v1:0", turn["model_id"]
      assert_equal({ "temperature" => 0, "max_tokens" => 700 }, turn["inference_config"])
      assert_equal false, turn["tool_config"]
      assert_equal true, turn["request_equivalent"]
      assert_equal [ "system" ], turn["changed_fields"]
      assert_equal Rag::CompanionDirectCaptureReplay::SESSION_SYSTEM_SHA, turn["system_sha256"]
    end
    assert report["publication"].all? { |row| row["matches"] }, report["publication"].to_json
    quotes = report.fetch("publication").map { |row| row.fetch("publication").fetch("quotes").sole }
    assert_equal [ 1, 1, 1 ], quotes.pluck("source")
    assert_includes quotes[1].fetch("text"), quotes[0].fetch("text")
    assert_includes quotes[1].fetch("text"), quotes[2].fetch("text")
    assert_equal [ false, true, false ], report["rubric"].pluck("pass")
    assert_equal true, report.dig("rubric", 0, "documented_slow_opening")
    assert_equal true, report.dig("rubric", 0, "prescribes_autoajuste")
    assert_equal true, report.dig("rubric", 0, "assumes_intervention")
    assert_equal true, report.dig("rubric", 1, "uses_first_opening")
    assert_equal false, report.dig("rubric", 1, "reasks")
    assert_equal true, report.dig("rubric", 2, "referencia_valida")
    assert_equal false, report.dig("rubric", 2, "conclusion_respaldada")
    assert_equal "captured_tokens_plus_system_character_delta", report.dig("price", "method")
    assert_equal "three generation calls plus one retry of the dearest call, output capped at 700", report.dig("price", "ceiling_includes")
    assert_equal before, File.binread(@ledger.path)
    assert_equal Digest::SHA256.hexdigest(before), report.dig("ledger", "sha256")
    remaining = report.dig("ledger", "remaining_calls")
    assert_equal remaining >= 4 ? 1 : 0, report.dig("call_plan", "retry_budget")
    assert_equal 3, report.dig("call_plan", "generation_calls")
    room = BigDecimal(report.dig("ledger", "authorization_room_usd"))
    ceiling = BigDecimal(report.dig("price", "ceiling_usd"))
    assert_equal room >= ceiling && report.dig("ledger", "remaining_calls") >= 3, report.dig("call_plan", "start")
    assert_empty calls
  end

  test "a sonnet override keeps the captured messages and changes the model id" do
    require_historical_capture("tmp/field_companion/vf5_direct_guiones/guion2/turn-1/capture.json")
    prepared = Rag::CompanionDirectCaptureReplay.effective_requests(
      "global.anthropic.claude-sonnet-4-5-20250929-v1:0", ledger_path: Pathname.new(@ledger.path)
    )

    assert_empty prepared["mismatches"]
    assert_not_includes prepared["blockers"], "model_not_authorized"
    assert_not_includes prepared["blockers"], "request_mismatch"
    assert_not_includes prepared["blockers"], "ceiling_exceeds_room"
    assert_equal 0, prepared["retries"]
    prepared["requests"].each_with_index do |request, index|
      turn = Rag::CompanionDirectCaptureReplay.load_turn(index + 1)
      assert_equal Rag::CompanionDirectCaptureReplay::SONNET_45_GLOBAL, request[:model_id]
      assert_equal({ temperature: 0, max_tokens: 700 }, request[:inference_config])
      assert_nil request[:tool_config]
      assert_equal turn.dig("resolved", "messages").map { |message| message["text"] },
        request[:messages].map { |message| message[:content][0][:text] }
    end
  end
end
