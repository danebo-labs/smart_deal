# frozen_string_literal: true

require "test_helper"
require "stringio"
require Rails.root.join("script/field_companion/visual_benchmark")

class FieldCompanionVisualBenchmarkTest < ActiveSupport::TestCase
  Bench = FieldCompanion::VisualBenchmark

  SPRING_GOLD = {
    "manufacturer" => { "status" => "NOT_SCORED" },
    "model" => { "status" => "NOT_SCORED" },
    "component" => {
      "status" => "VERIFIED",
      "allowed" => %w[resorte resortes muelle muelles],
      "fail_if" => %w[resistenc bobinad]
    },
    "visible_text" => { "status" => "NOT_SCORED" }
  }.freeze

  test "verified component passes a whole word and ignores accents" do
    scored = Bench.score_verified("Fijación de resortes.", allowed: %w[resorte resortes muelle muelles], fail_if: %w[resistenc bobinad])

    assert_equal "PASS", scored["result"]
    assert_equal "fijacion de resortes.", scored["normalized_text"]
  end

  test "fail_if is a substring and wins over an allowed word" do
    scored = Bench.score_verified(
      "banco de resistencias y resortes",
      allowed: %w[resorte resortes],
      fail_if: %w[resistenc bobinad]
    )

    assert_equal "FAIL", scored["result"]
  end

  test "verified fails when no allowed word is present" do
    scored = Bench.score_verified("banco de contactores", allowed: %w[resorte resortes], fail_if: %w[resistenc])

    assert_equal "FAIL", scored["result"]
  end

  test "an allowed token does not match inside a longer alphanumeric word" do
    scored = Bench.score_verified("preresorte", allowed: %w[resorte], fail_if: [])

    assert_equal "FAIL", scored["result"]
  end

  test "must be unknown passes only empty or unknown" do
    assert_equal "PASS", Bench.score_unknown("")["result"]
    assert_equal "PASS", Bench.score_unknown("  UNKNOWN  ")["result"]
    assert_equal "FAIL", Bench.score_unknown("Otis")["result"]
  end

  test "not scored fields are omitted from pass and fail" do
    parsed = { "canonical_component" => "conjunto de resortes", "summary" => "banco de resistencias" }
    fields = Bench.ordered_fields(Bench.score_gold(SPRING_GOLD, parsed))

    assert_equal "PASS", fields.dig("component", "result")
    assert_equal({ "status" => "NOT_SCORED" }, fields["manufacturer"])
    assert_equal({ "status" => "NOT_SCORED" }, fields["model"])
    assert_equal({ "status" => "NOT_SCORED" }, fields["visible_text"])
    assert_equal %w[component manufacturer model visible_text], fields.keys
    assert_equal 0, Bench.by_model([ case_from(fields, fields) ]).dig("claude-sonnet-5-5", "identity_invention_count")
  end

  test "component is read from canonical_component" do
    parsed = { "canonical_component" => "conjunto de muelles", "summary" => "parece un bobinado" }
    fields = Bench.score_gold(SPRING_GOLD, parsed)

    assert_equal "PASS", fields.dig("component", "result")
    assert_equal "conjunto de muelles", fields.dig("component", "normalized_text")
  end

  test "spring split and opus only wins follow the component results" do
    split = Bench.counters([
      case_row("spring_assembly_misread", component_result("FAIL"), component_result("PASS"))
    ])
    assert_equal "opus_pass_sonnet_fail", split["spring_split"]
    assert_equal 1, split["opus_only_wins"]
    assert_equal 0, split["shared_component_fail"]
    assert_equal 0, split["shared_identity_fail"]

    reverse = Bench.counters([
      case_row("spring_assembly_misread", component_result("PASS"), component_result("FAIL"))
    ])
    assert_equal "sonnet_pass_opus_fail", reverse["spring_split"]
    assert_equal 0, reverse["opus_only_wins"]

    both = Bench.counters([
      case_row("spring_assembly_misread", component_result("PASS"), component_result("PASS"))
    ])
    assert_nil both["spring_split"]
    assert_equal 0, both["opus_only_wins"]
  end

  test "shared component fail is one when both models fail the verified component" do
    counters = Bench.counters([
      case_row("spring_assembly_misread", component_result("FAIL"), component_result("FAIL"))
    ])

    assert_nil counters["spring_split"]
    assert_equal 1, counters["shared_component_fail"]
    assert_equal 0, counters["opus_only_wins"]
    assert_equal 1, Bench.by_model([
      case_row("spring_assembly_misread", component_result("FAIL"), component_result("FAIL"))
    ]).dig("claude-opus-5-5", "component_fail_count")
  end

  test "shared identity fail counts a row only when both miss the same unknown field" do
    invented = unknown_result("FAIL", "otis")
    clean = component_result("PASS")
    row = case_row(
      "other",
      clean.merge("manufacturer" => invented),
      clean.merge("manufacturer" => invented)
    )

    assert_equal 1, Bench.counters([ row ])["shared_identity_fail"]
    assert_equal 1, Bench.by_model([ row ]).dig("claude-sonnet-5-5", "identity_invention_count")

    both_component = case_row(
      "spring_assembly_misread",
      component_result("FAIL").merge("manufacturer" => invented),
      component_result("FAIL").merge("manufacturer" => invented)
    )
    assert_equal 0, Bench.counters([ both_component ])["shared_identity_fail"]

    spring = case_row("spring_assembly_misread", component_result("PASS"), component_result("PASS"))
    assert_equal 0, Bench.counters([ spring ])["shared_identity_fail"]
  end

  test "sonnet 5.5 cost uses the cited pricing page when the returned id matches" do
    cost, source = Bench.cost_for(
      requested_model_id: "claude-sonnet-5-5",
      returned_model_id: "claude-sonnet-5-5",
      input_tokens: 1_000,
      output_tokens: 1_000
    )

    assert_equal "0.012000", cost
    assert_equal "https://platform.claude.com/docs/en/about-claude/pricing", source
  end

  test "sonnet 5.5 cost is unknown when the returned id is a different model" do
    cost, source = Bench.cost_for(
      requested_model_id: "claude-sonnet-5-5",
      returned_model_id: "claude-sonnet-5",
      input_tokens: 1_000,
      output_tokens: 1_000
    )

    assert_equal "UNKNOWN", cost
    assert_nil source
  end

  test "opus cost uses the written direct tariff only when the returned id matches" do
    cost, source = Bench.cost_for(
      requested_model_id: "claude-opus-5-5",
      returned_model_id: "claude-opus-5-5-20260601",
      input_tokens: 2_000,
      output_tokens: 500
    )

    assert_equal "0.018000", cost
    assert_equal "app/models/bedrock_query.rb#BEDROCK_PRICING[claude-opus-5-5-direct]", source
    written = BedrockQuery::BEDROCK_PRICING.fetch("claude-opus-5-5-direct")
    assert_equal BigDecimal("0.004"), BigDecimal(written[:input].to_s)
    assert_equal BigDecimal("0.02"), BigDecimal(written[:output].to_s)
  end

  test "opus cost is unknown when the returned id does not match and missing tokens stay unknown" do
    mismatched, source = Bench.cost_for(
      requested_model_id: "claude-opus-5-5",
      returned_model_id: "claude-opus-4-8",
      input_tokens: 10,
      output_tokens: 10
    )
    missing, missing_source = Bench.cost_for(
      requested_model_id: "claude-opus-5-5",
      returned_model_id: "claude-opus-5-5",
      input_tokens: nil,
      output_tokens: 10
    )

    assert_equal "UNKNOWN", mismatched
    assert_nil source
    assert_equal "UNKNOWN", missing
    assert_nil missing_source
  end

  test "both models receive the same request except the model id" do
    binary = "png-bytes".b
    left = Bench.request_params(
      model_id: "claude-sonnet-5-5",
      binary: binary,
      media_type: "image/png",
      filename: "spring_assembly_misread.png"
    )
    right = Bench.request_params(
      model_id: "claude-opus-5-5",
      binary: binary,
      media_type: "image/png",
      filename: "spring_assembly_misread.png"
    )

    assert_equal "claude-sonnet-5-5", left[:model]
    assert_equal "claude-opus-5-5", right[:model]
    assert_equal left.except(:model), right.except(:model)
    assert_equal Bench.request_sha256(left), Bench.request_sha256(right)
    assert_equal 8_000, left[:max_tokens]
    assert_equal FieldPhotoPrompt::SYSTEM_BLOCKS, left[:system]
    assert_equal binary, Base64.strict_decode64(left[:messages][0][:content][0][:source][:data])
    assert_equal Digest::SHA256.hexdigest(binary), Bench.bytes_sha_from_params(left)
    texts = left[:messages][0][:content].select { |block| block[:type] == "text" }.pluck(:text)
    assert_includes texts.join("\n"), "Summary language: es."
    assert_includes texts.join("\n"), "spring_assembly_misread.png"
    assert texts.none? { |text| text.include?("Photo intent") }
  end

  test "a diverging byte hash aborts the row before the second model" do
    first = Bench.remember_pair!(nil, bytes_sha: "aaa", request_sha: "same", file_sha: "aaa")
    calls = [ first ]
    error = assert_raises(Bench::Stop) do
      calls << Bench.remember_pair!(first, bytes_sha: "bbb", request_sha: "same", file_sha: "aaa")
    end

    assert_equal [ first ], calls
    assert_match(/sha256/, error.message)
  end

  test "execute_case calls both models once on the same bytes" do
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      binary = "same-image".b
      path = root.join("image.png")
      File.binwrite(path, binary)
      sha = Digest::SHA256.hexdigest(binary)
      client = FakeClient.new(lambda { |params|
        FakeMessage.new(
          params[:model],
          "{\"canonical_component\":\"conjunto de resortes\"}",
          input_tokens: 11,
          output_tokens: 7
        )
      })
      row = {
        "case_id" => "spring_assembly_misread",
        "filename" => "spring_assembly_misread.png",
        "media_type" => "image/png",
        "sha256" => sha,
        "gold" => SPRING_GOLD
      }

      scored = Bench.execute_case(row, client, root: root, image_path: path)

      assert_equal Bench::MODELS, client.messages.creates.map { |params| params[:model] }
      assert_equal sha, scored.dig("models", "claude-sonnet-5-5", "bytes_sha256")
      assert_equal sha, scored.dig("models", "claude-opus-5-5", "bytes_sha256")
      assert_equal scored.dig("models", "claude-sonnet-5-5", "request_sha256"),
        scored.dig("models", "claude-opus-5-5", "request_sha256")
      assert_equal "PASS", scored.dig("models", "claude-sonnet-5-5", "fields", "component", "result")
      assert_equal "0.000092", scored.dig("models", "claude-sonnet-5-5", "cost")
      assert_equal "0.000184", scored.dig("models", "claude-opus-5-5", "cost")
    end
  end

  test "more than 16 eligible images stops before a call" do
    rows = Array.new(17) { |index| { "case_id" => index.to_s } }

    assert_raises(Bench::Stop) { Bench.ensure_budget!(rows) }
  end

  test "the production prompt fingerprint is the frozen digest" do
    assert_equal Bench::FINGERPRINT, FieldPhotoPrompt.prompt_fingerprint_sha256
    assert_equal 8_000, BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS
    assert_equal 8_000, Bench::MAX_TOKENS
  end

  test "the harness source does not consult production model routing" do
    source = Rails.root.join("script/field_companion/visual_benchmark.rb").read
    ids = source.scan(/claude-[a-z0-9.-]+/).uniq.sort

    assert_equal %w[claude-opus-5-5 claude-opus-5-5-direct claude-sonnet-5-5], ids
    assert_not_includes source, "MODEL_TEXT"
    assert_not_includes source, "MODEL_MULTIMODAL"
    assert_not_includes source, "FieldPhotoDensityGate"
    assert_not_includes source, "pricing_for"
    assert_not_includes source, "TrackBedrockQueryJob"
    assert_not_includes source, "ClaudeChunkingClient"
    assert_not_includes source, "multimodal_availability_probe"
  end

  test "a saved successful call is not repeated" do
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      params = Bench.request_params(
        model_id: "claude-sonnet-5-5",
        binary: "same-bytes",
        media_type: "image/png",
        filename: "spring_assembly_misread.png"
      )
      record = {
        "requested_model_id" => "claude-sonnet-5-5",
        "returned_model_id" => "claude-sonnet-5-5",
        "bytes_sha256" => Bench.bytes_sha_from_params(params),
        "request_sha256" => Bench.request_sha256(params),
        "system_prompt_fingerprint_sha256" => Bench::FINGERPRINT,
        "max_tokens" => 8_000,
        "success" => true,
        "error_class" => nil,
        "output_text" => "{\"canonical_component\":\"resortes\"}",
        "input_tokens" => 3,
        "output_tokens" => 4,
        "cache_read_tokens" => 0,
        "cache_creation_tokens" => 1,
        "latency_ms" => 9,
        "timestamp" => "2026-09-29T00:00:00Z"
      }
      Bench.write_json(root.join("f1_calls/claude-sonnet-5-5.json"), record)
      client = FakeClient.new(->(_params) { flunk "client was called" })

      fetched = Bench.fetch_call(
        model_id: "claude-sonnet-5-5",
        params: params,
        bytes_sha: record["bytes_sha256"],
        request_sha: record["request_sha256"],
        client: client,
        case_id: "spring_assembly_misread",
        root: root
      )

      assert_equal record["output_text"], fetched["output_text"]
      assert_equal 0, client.messages.creates.size
      assert_equal Digest::SHA256.file(root.join("outputs/spring_assembly_misread.claude-sonnet-5-5.txt")).hexdigest,
        fetched["output_sha256"]
    end
  end

  test "a manifest hash mismatch blocks before any call" do
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      manifest = root.join("visual_manifest.json")
      File.write(manifest, "{}\n")
      client = FakeClient.new(->(_params) { flunk "client was called" })
      io = StringIO.new

      status = Bench.run(client: client, root: root, manifest_path: manifest, image_path: root.join("missing.png"), io: io)

      assert_equal 2, status
      assert_includes io.string, "F1_STATUS=BLOCKED"
      assert_empty client.messages.creates
    end
  end

  private

  def component_result(result)
    {
      "component" => { "status" => "VERIFIED", "result" => result, "normalized_text" => "x" },
      "manufacturer" => { "status" => "NOT_SCORED" },
      "model" => { "status" => "NOT_SCORED" },
      "visible_text" => { "status" => "NOT_SCORED" }
    }
  end

  def unknown_result(result, text)
    { "status" => "MUST_BE_UNKNOWN", "result" => result, "normalized_text" => text }
  end

  def case_row(case_id, sonnet_fields, opus_fields)
    {
      "case_id" => case_id,
      "models" => {
        "claude-sonnet-5-5" => { "fields" => sonnet_fields },
        "claude-opus-5-5" => { "fields" => opus_fields }
      }
    }
  end

  def case_from(sonnet_fields, opus_fields)
    case_row("spring_assembly_misread", sonnet_fields, opus_fields)
  end

  class FakeMessages
    attr_reader :creates

    def initialize(handler)
      @handler = handler
      @creates = []
    end

    def create(params)
      @creates << params
      @handler.call(params)
    end
  end

  class FakeClient
    attr_reader :messages

    def initialize(handler)
      @messages = FakeMessages.new(handler)
    end
  end

  class FakeMessage
    attr_reader :model, :content, :usage

    def initialize(model, text, input_tokens:, output_tokens:)
      @model = model
      @content = [ FakeBlock.new("text", text) ]
      @usage = FakeUsage.new(input_tokens, output_tokens, 0, 0)
    end
  end

  FakeBlock = Struct.new(:type, :text)
  FakeUsage = Struct.new(:input_tokens, :output_tokens, :cache_read_input_tokens, :cache_creation_input_tokens)
end
