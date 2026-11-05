# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"

require Rails.root.join("test/support/companion_haiku55_compare")

class Rag::CompanionHaiku55CompareTest < ActiveSupport::TestCase
  Compare = Rag::CompanionHaiku55Compare

  setup do
    @require = ENV["GUION2_PROMPT_COMPARE_REQUIRE"]
    ENV["GUION2_PROMPT_COMPARE_REQUIRE"] = "1"
    load Rails.root.join("script/field_companion/replay_direct_prompt_compare.rb")
  end

  teardown do
    @require.nil? ? ENV.delete("GUION2_PROMPT_COMPARE_REQUIRE") : ENV["GUION2_PROMPT_COMPARE_REQUIRE"] = @require
  end

  test "translation keeps the captured text and applies the haiku 5.5 request" do
    canonical = {
      "system" => [ { "text" => "sistema" } ],
      "messages" => [
        { "role" => "user", "content" => [ { "text" => "primero" } ] },
        { "role" => "assistant", "content" => [ { "text" => "respuesta fija" } ] },
        { "role" => "user", "content" => [ { "text" => "segundo" } ] }
      ],
      "inference_config" => { "temperature" => 0, "max_tokens" => 700 }
    }
    translated = Compare.translate(canonical, max_tokens: 16_000)
    body = translated["body"]

    assert_equal "claude-haiku-5-5", body["model"]
    assert_equal 16_000, body["max_tokens"]
    assert_equal({ "type" => "adaptive", "display" => "summarized" }, body["thinking"])
    assert_equal({ "effort" => "max" }, body["output_config"])
    assert_nil body["temperature"]
    assert_nil body["top_p"]
    assert_equal [ "user", "assistant", "user" ], body["messages"].pluck("role")
    assert_equal [ "primero", "respuesta fija", "segundo" ], body["messages"].map { |message| message.dig("content", 0, "text") }
    assert_equal "sistema", body.dig("system", 0, "text")
    assert_equal 0, translated["http_max_retries"]
    assert translated["adjustments"].any? { |row| row["parameter"] == "temperature" && row["action"] == "omit" }
  end

  test "the authorized ceiling is 0.30 because the max effort matrix does not fit in 0.15" do
    inputs = [ 17_553, 18_168, 18_988 ]
    primary = Compare.affordable_max_tokens(inputs, Compare::PRIMARY_BUDGET)
    authorized = Compare.affordable_max_tokens(inputs, Compare::AUTHORIZED_BUDGET)
    selected = Compare.matrix_ceiling(inputs, authorized)

    assert primary > 700
    assert authorized > primary
    assert Compare.matrix_ceiling(inputs, primary) <= Compare::PRIMARY_BUDGET
    assert selected <= Compare::AUTHORIZED_BUDGET
    assert selected > Compare::PRIMARY_BUDGET
  end

  test "preflight accepts the canonical requests and does not call anthropic" do
    calls = 0
    trace = TracePoint.new(:call) do |event|
      calls += 1 if event.defined_class == Net::HTTP && event.method_id == :new
    end
    report = trace.enable { Compare.prepare(output_root: Dir.mktmpdir) }

    assert_equal true, report["ok"], report["blockers"].inspect
    assert_equal 0, calls
    assert_equal "claude-haiku-5-5", report["model_id"]
    assert_equal "max", report["effort"]
    assert_equal "adaptive", report.dig("thinking", "type")
    assert report["max_tokens"] > 700
    assert_equal false, report["ceiling_fits_primary"]
    assert BigDecimal(report["ceiling_usd"]) <= Compare::AUTHORIZED_BUDGET
    assert_equal Compare::PROMPT_SHA, report["prompt_sha256"] if Compare.const_defined?(:PROMPT_SHA)
    assert_equal Rag::CompanionDirectCaptureReplay::PROMPT_SHA, report["prompt_sha256"]
    assert_equal [ true, true, true ], report["turns"].pluck("sources_joined")
    assert_empty report["prior_runs"]
  end

  test "a stream becomes one message and the visible text excludes thinking" do
    raw = <<~SSE
      event: message_start
      data: {"type":"message_start","message":{"id":"msg_1","model":"claude-haiku-5-5","role":"assistant","usage":{"input_tokens":5,"output_tokens":1}}}

      event: content_block_start
      data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"razon"}}

      event: content_block_start
      data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"visible"}}

      event: message_delta
      data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":12}}

      event: message_stop
      data: {"type":"message_stop"}
    SSE
    message = Compare::Assembler.new.tap { |assembler| assembler << raw }.finish
    compare = Compare.new
    visible = compare.send(:visible_response, message)

    assert_equal "end_turn", message["stop_reason"]
    assert_equal 5, message.dig("usage", "input_tokens")
    assert_equal 12, message.dig("usage", "output_tokens")
    assert_equal "razon", message.dig("content", 0, "thinking")
    assert_equal "visible", visible["text"]
    assert_equal "razon", compare.send(:thinking_text, message)
  end

  test "net http retries are disabled" do
    http = RecordingHTTP.new
    result = Compare::Transport.new(http: http).post(body: { "model" => "claude-haiku-5-5", "max_tokens" => 20, "messages" => [] }, api_key: "test-key")

    assert_equal 0, http.session.max_retries
    assert_equal 200, result.http_status
    assert_nil result.payload.to_s.index("test-key")
  end

  test "429 uses retry-after and a timeout keeps its reservation" do
    Dir.mktmpdir do |dir|
      sleeps = []
      transport = ScriptTransport.new([
        Compare::Result.new(http_status: 429, payload: { "error" => { "type" => "rate_limit_error", "message" => "slow" } }, retry_after: "4", error_code: "http_429", error_message: "slow", partial: false),
        success_result
      ])
      compare = Compare.new(transport: transport, credential: "test-key", sleeper: ->(seconds) { sleeps << seconds }, output_root: dir, io: StringIO.new)
      ledger = Compare::Ledger.new(File.join(dir, "attempts.jsonl"))
      compare.instance_variable_set(:@ledger, ledger)
      compare.instance_variable_set(:@version, Compare::ANTHROPIC_VERSION)
      compare.instance_variable_set(:@budget, Compare::AUTHORIZED_BUDGET)
      FileUtils.mkdir_p(dir)

      outcome = compare.send(:call_with_retries, 1, { "max_tokens" => 100, "model" => "claude-haiku-5-5" }, 100, "test-key", Pathname(dir))

      assert_equal "returned", outcome["status"], outcome.inspect
      assert_equal [ 4 ], sleeps
      assert_equal 2, transport.calls
      assert_equal "test-key", transport.api_key
      assert_equal 0, ledger.reserved_total
      assert ledger.spent.positive?
    end
  end

  test "a timeout keeps the reservation and blocks the retry once the ceiling is full" do
    Dir.mktmpdir do |dir|
      transport = ScriptTransport.new([
        Compare::Result.new(http_status: nil, payload: nil, retry_after: nil, error_code: "timeout", error_message: "timeout", partial: true)
      ])
      reservation = Compare.reservation_usd(100, 100)
      compare = Compare.new(transport: transport, credential: "test-key", sleeper: ->(_) { flunk "should not sleep" }, output_root: dir, io: StringIO.new, budget: reservation)
      ledger = Compare::Ledger.new(File.join(dir, "attempts.jsonl"))
      compare.instance_variable_set(:@ledger, ledger)
      compare.instance_variable_set(:@version, Compare::ANTHROPIC_VERSION)
      FileUtils.mkdir_p(dir)

      outcome = compare.send(:call_with_retries, 1, { "max_tokens" => 100 }, 100, "test-key", Pathname(dir))

      assert_equal "budget", outcome["status"]
      assert_equal 1, transport.calls
      assert_equal reservation, ledger.exposure
      assert_equal 1, ledger.events.count { |event| event["event"] == "kept" }
    end
  end

  test "a server error without usage keeps the reservation and still retries" do
    Dir.mktmpdir do |dir|
      transport = ScriptTransport.new([
        Compare::Result.new(http_status: 503, payload: { "error" => { "type" => "api_error", "message" => "down" } }, retry_after: nil, error_code: "http_503", error_message: "down", partial: false),
        success_result
      ])
      compare = Compare.new(transport: transport, credential: "test-key", sleeper: ->(_) { }, output_root: dir, io: StringIO.new)
      ledger = Compare::Ledger.new(File.join(dir, "attempts.jsonl"))
      compare.instance_variable_set(:@ledger, ledger)
      compare.instance_variable_set(:@version, Compare::ANTHROPIC_VERSION)
      compare.instance_variable_set(:@budget, Compare::AUTHORIZED_BUDGET)
      FileUtils.mkdir_p(dir)

      outcome = compare.send(:call_with_retries, 1, { "max_tokens" => 80 }, 80, "test-key", Pathname(dir))

      assert_equal "returned", outcome["status"]
      assert_equal 2, transport.calls
      assert ledger.reserved_total.positive?
      assert ledger.spent.positive?
    end
  end

  test "markers without an extracted quote are recorded as accepted without verification" do
    report = Compare.marker_report(
      "Dato [1]. Otro [9].",
      reasons: [ { "rule" => "R1", "detail" => "missing:9" } ],
      quotes: []
    )

    first, ninth = report
    assert_equal true, first["accepted_without_quote_verification"]
    assert_equal false, first["claim_verified_by_quote"]
    assert_equal false, ninth["gate_checked_source_exists"]
    assert_equal false, ninth["accepted_without_quote_verification"]
  end

  test "the saved haiku 4.5 answer still passes the same publication gate" do
    raw = Rails.root.join("tmp/field_companion/vf5_direct_prompt_compare/turn-1/raw.txt").read
    published = Compare.new.publish_turn(1, raw, "end_turn")

    assert_equal true, published["accepted"]
    assert_includes published["publishable"], "lentamente"
    assert published["quotes"].any? { |quote| quote["text"].include?("lentamente") }
    assert_equal false, published["visible_markers"].fetch(0)["accepted_without_quote_verification"]
  end

  class RecordingHTTP
    attr_reader :session

    def new(*)
      @session = Session.new
    end

    class Session
      attr_accessor :use_ssl, :open_timeout, :read_timeout, :max_retries

      def request(_request)
        body = {
          "id" => "msg_test",
          "stop_reason" => "end_turn",
          "content" => [ { "type" => "text", "text" => "ok" } ],
          "usage" => { "input_tokens" => 3, "output_tokens" => 2 }
        }
        yield Response.new("200", { "content-type" => "application/json" }, JSON.generate(body))
      end
    end

    class Response
      def initialize(code, headers, body)
        @code = code
        @headers = headers
        @body = body
      end

      def code
        @code
      end

      delegate :[], to: :@headers

      def read_body
        yield @body
      end
    end
  end

  class ScriptTransport
    attr_reader :calls, :api_key

    def initialize(results)
      @results = results
      @calls = 0
    end

    def post(body:, api_key:, version:)
      @calls += 1
      @api_key = api_key
      @version = version
      @body = body
      @results.shift
    end
  end

  private

  def success_result
    Compare::Result.new(
      http_status: 200,
      payload: {
        "id" => "msg_ok",
        "model" => "claude-haiku-5-5",
        "stop_reason" => "end_turn",
        "content" => [ { "type" => "text", "text" => "respuesta" } ],
        "usage" => { "input_tokens" => 10, "output_tokens" => 4 }
      },
      retry_after: nil,
      error_code: nil,
      error_message: nil,
      partial: false
    )
  end
end
