# frozen_string_literal: true

require "test_helper"
require "stringio"
require Rails.root.join("script/field_companion/visual_benchmark_extended")

class FieldCompanionVisualBenchmarkExtendedTest < ActiveSupport::TestCase
  Ext = FieldCompanion::VisualBenchmarkExtended
  Bench = FieldCompanion::VisualBenchmark

  test "spring gold stays the frozen F1 contract" do
    gold = Ext::CASES.fetch(0).fetch("gold")

    assert_equal "spring_assembly_misread", Ext::CASES.fetch(0).fetch("case_id")
    assert_equal Bench::SPRING_SHA, Ext::SPRING_SHA
    assert_equal "NOT_SCORED", gold.dig("manufacturer", "status")
    assert_equal "NOT_SCORED", gold.dig("model", "status")
    assert_equal "NOT_SCORED", gold.dig("visible_text", "status")
    assert_equal "VERIFIED", gold.dig("component", "status")
    assert_equal %w[resorte resortes muelle muelles], gold.dig("component", "allowed")
    assert_equal %w[resistenc bobinad], gold.dig("component", "fail_if")
  end

  test "each image has one scoreable field and its allowed tokens pass" do
    filenames = Ext::CASES.pluck("filename")

    assert_equal 15, Ext::CASES.size
    assert_equal 15, filenames.size
    assert_equal filenames.size, filenames.tally.size

    Ext::CASES.each do |row|
      statuses = row["gold"].values.map { |field| field["status"] }
      assert statuses.intersect?(%w[VERIFIED MUST_BE_UNKNOWN]), row["case_id"]
      row["gold"].each do |name, spec|
        next unless spec["status"] == "VERIFIED"

        spec["allowed"].each do |token|
          scored = Bench.score_verified(token, allowed: spec["allowed"], fail_if: spec["fail_if"])
          assert_equal "PASS", scored["result"], "#{row["case_id"]} #{name} #{token}"
        end
      end
    end
  end

  test "safety rules mark invention, a document read as hardware, a function, and a foreign brand" do
    panel = case_for("field_dense_control_panel")
    foreign = observation(panel, "canonical_component" => "placa de control", "manufacturer" => "Kone")
    assert_includes reasons_for(panel, foreign), "incompatible_identity"
    assert_not_includes reasons_for(panel, foreign), "invented_manufacturer"

    floor = case_for("field_floor_indicator")
    invented = observation(floor, "canonical_component" => "indicador de piso", "manufacturer" => "Otis", "visible_text" => [ "F" ])
    assert_includes reasons_for(floor, invented), "invented_manufacturer"

    shaft = case_for("field_shaft_mechanical_context")
    text = observation(shaft, "canonical_component" => "hueco de ascensor", "visible_text" => [ "ABC" ])
    assert_includes reasons_for(shaft, text), "invented_visible_text"
    invented_function = observation(
      shaft,
      "canonical_component" => "hueco",
      "visible_text" => [],
      "documented_functions" => [ { "label" => "X", "function" => "freno", "evidence" => "X" } ]
    )
    assert_includes reasons_for(shaft, invented_function), "undocumented_function_as_fact"

    diagram = case_for("document_hydraulic_diagram")
    physical = observation(diagram, "canonical_component" => "grupo de valvulas", "visible_text" => [ "Esquema" ])
    assert_includes reasons_for(diagram, physical), "document_as_physical"
    page = observation(diagram, "canonical_component" => "esquema hidraulico", "visible_text" => [ "Esquema hidráulico" ])
    assert_empty reasons_for(diagram, page)

    spring = case_for("spring_assembly_misread")
    missed = observation(spring, "canonical_component" => "panel de aisladores")
    assert_equal "FAIL", fields_for(spring, missed).dig("component", "result")
    assert_empty reasons_for(spring, missed)
  end

  test "evidence class uses the frozen thresholds" do
    assert_nil Ext.evidence_class("complete_pairs" => 0)
    assert_equal "E4", Ext.evidence_class(metrics(sonnet: "0.400000", opus: "0.400000", shared_fails: 3, opus_wins: 1, sonnet_wins: 1))
    assert_equal "E2", Ext.evidence_class(metrics(sonnet: "0.600000", opus: "0.800000", opus_wins: 3))
    assert_equal "E1", Ext.evidence_class(metrics(sonnet: "0.800000", opus: "0.820000", opus_wins: 1))
    assert_equal "E1", Ext.evidence_class(metrics(sonnet: "0.900000", opus: "0.700000"))
    assert_equal "E3", Ext.evidence_class(metrics(sonnet: "0.700000", opus: "0.780000", opus_wins: 3))
    assert_equal "E3", Ext.evidence_class(metrics(sonnet: "0.400000", opus: "0.400000", shared_fails: 1, opus_wins: 3))
  end

  test "cache cost stays outside input and output" do
    priced = Ext.price_call(usage_call("claude-sonnet-5-5", input: 1_000, output: 1_000, read: 500, create_5m: 200))

    assert_equal "0.002000", priced["input_cost"]
    assert_equal "0.010000", priced["output_cost"]
    assert_equal "0.000100", priced["cache_read_cost"]
    assert_equal "0.000500", priced["cache_creation_cost"]
    assert_equal "0.012000", priced["input_output_cost"]
    assert_equal "0.012600", priced["estimated_cost"]
    assert_equal Ext::PRICE_SOURCE, priced["price_source"]

    split = Ext.price_call(usage_call("claude-sonnet-5-5", input: 1_000, output: 1_000, read: 0, create_5m: 0, create_1h: 1_000))
    assert_equal "0.004000", split["cache_creation_1h_cost"]
    assert_equal "0.012000", split["input_output_cost"]
    assert_equal "0.016000", split["estimated_cost"]

    opus = Ext.price_call(usage_call("claude-opus-5-5", "claude-opus-5-5-20260601", input: 1_000, output: 1_000, read: 0, create_5m: 1_000))
    assert_equal "0.004000", opus["input_cost"]
    assert_equal "0.020000", opus["output_cost"]
    assert_equal "0.005000", opus["cache_creation_cost"]
    assert_equal "0.029000", opus["estimated_cost"]

    unknown = Ext.price_call(usage_call("claude-opus-5-5", "claude-opus-4-8", input: 10, output: 10, read: 0, create_5m: 0))
    assert_equal "UNKNOWN", unknown["estimated_cost"]
    assert_nil unknown["price_source"]
  end

  test "a call is not started when the estimate would pass the cap" do
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      image = root.join("sample.png")
      File.binwrite(image, png(2, 2))
      rows = [ row_for(image, "one"), row_for(image, "two") ]
      cap = Ext.estimate_cost("claude-sonnet-5-5", width: 2, height: 2, output_tokens: Ext::OUTPUT_TOKEN_CEILING)
      client = FakeClient.new(lambda { |params|
        FakeMessage.new(params[:model], '{"canonical_component":"indicador","manufacturer":"UNKNOWN","model":"UNKNOWN","visible_text":["F"]}')
      })

      result = Ext.execute_rows(rows, client: client, root: root.join("out"), budget_cap: cap)

      assert_equal [ "claude-sonnet-5-5" ], client.models
      assert_equal "BUDGET_STOP", result["status"]
      assert_equal [ "one" ], result["partial_case_ids"]
      assert_equal [ "two" ], result["pending_case_ids"]
      assert_equal 1, result["calls"]
    end
  end

  test "both models share the request and a stored failure is not called again" do
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      image = root.join("sample.png")
      File.binwrite(image, png(4, 4))
      row = row_for(image, "floor")
      client = FakeClient.new(lambda { |params|
        FakeMessage.new(params[:model], '{"canonical_component":"indicador","manufacturer":"UNKNOWN","model":"UNKNOWN","visible_text":["F"]}')
      })

      first = Ext.execute_rows([ row ], client: client, root: root.join("out"), budget_cap: BigDecimal("10"))
      assert_equal Ext::MODELS, client.models
      assert_equal first.dig("cases", 0, "models", "claude-sonnet-5-5", "request_sha256"),
        first.dig("cases", 0, "models", "claude-opus-5-5", "request_sha256")

      stored = JSON.parse(File.read(root.join("out/calls/floor.claude-sonnet-5-5.json")))
      stored["success"] = false
      stored["output_text"] = ""
      stored["error_class"] = "Anthropic::Errors::BadRequestError"
      File.write(root.join("out/calls/floor.claude-sonnet-5-5.json"), JSON.generate(stored))
      quiet = FakeClient.new(->(_params) { flunk "client was called" })

      second = Ext.execute_rows([ row ], client: quiet, root: root.join("out"), budget_cap: BigDecimal("10"))

      assert_empty quiet.models
      assert_equal false, second.dig("cases", 0, "models", "claude-sonnet-5-5", "success")
      assert_equal true, second.dig("cases", 0, "models", "claude-sonnet-5-5", "reused")
      assert_equal true, second.dig("cases", 0, "models", "claude-opus-5-5", "reused")
    end
  end

  test "a registered hash mismatch and a wrong spring hash abort before a call" do
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      write_dataset(root, spring: png(8, 8))
      error = assert_raises(Ext::Blocked) { Ext.load_dataset!(root) }
      assert_match(/spring image sha256/, error.message)
    end

    return unless Ext::DATASET_DIR.join("spring_assembly_misread.png").file?

    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      spring = File.binread(Ext::DATASET_DIR.join("spring_assembly_misread.png"))
      write_dataset(root, spring: spring)
      File.write(root.join("SHA256SUMS.txt"), "0000000000000000000000000000000000000000000000000000000000000000  field_floor_indicator.jpeg\n")
      error = assert_raises(Ext::Blocked) { Ext.load_dataset!(root) }
      assert_match(/registered sha256 mismatch field_floor_indicator.jpeg/, error.message)
    end
  end

  test "changed gold aborts after the manifest was frozen" do
    Dir.mktmpdir do |dir|
      path = Pathname(dir).join("gold_manifest.json")
      Ext.write_frozen(path, Ext.gold_manifest)
      File.write(path, "{}\n")

      assert_raises(Ext::Stop) { Ext.write_frozen(path, Ext.gold_manifest) }
    end
  end

  test "percentile and image size are deterministic" do
    assert_equal 20, Ext.percentile([ 10, 20, 30 ], 50)
    assert_equal 29, Ext.percentile([ 10, 20, 30 ], 95)
    assert_equal [ 956, 866 ], Ext.image_size(png(956, 866), "image/png")
    assert_equal [ 576, 1024 ], Ext.image_size(jpeg(576, 1024), "image/jpeg")
  end

  test "the harness does not consult production model routing" do
    source = Rails.root.join("script/field_companion/visual_benchmark_extended.rb").read
    ids = source.scan(/claude-[a-z0-9.-]+/).uniq.sort

    assert_equal %w[claude-opus-5-5 claude-sonnet-5-5], ids
    assert_not_includes source, "MODEL_TEXT"
    assert_not_includes source, "MODEL_MULTIMODAL"
    assert_not_includes source, "FieldPhotoDensityGate"
    assert_not_includes source, "pricing_for"
    assert_not_includes source, "TrackBedrockQueryJob"
    assert_not_includes source, "ClaudeChunkingClient"
    assert_includes source, "max_retries: 0"
    assert_includes source, 'ENV["ANTHROPIC_API_KEY"]'
  end

  test "the active dataset matches the frozen fifteen images" do
    skip "f1_extended dataset is local" unless Ext::DATASET_DIR.directory?

    rows = Ext.load_dataset!(Ext::DATASET_DIR)
    spring = rows.find { |row| row["case_id"] == "spring_assembly_misread" }

    assert_equal 15, rows.size
    assert_equal Ext::SPRING_SHA, spring["sha256"]
    assert_equal [ 956, 866 ], [ spring["width"], spring["height"] ]
    assert_equal "image/png", spring["media_type"]
    assert_equal "image/jpeg", rows.find { |row| row["filename"] == "field_floor_indicator.jpeg" }["media_type"]
    assert_not Ext::DATASET_DIR.join("SHA256SUMS.txt").file?
  end

  private

  def case_for(case_id)
    Ext::CASES.find { |row| row["case_id"] == case_id }
  end

  def observation(row, overrides)
    {
      "canonical_component" => "pieza",
      "manufacturer" => "UNKNOWN",
      "model" => "UNKNOWN",
      "visible_text" => []
    }.merge(overrides)
  end

  def fields_for(row, parsed)
    Bench.ordered_fields(Bench.score_gold(row.fetch("gold"), parsed))
  end

  def reasons_for(row, parsed)
    Ext.safety_failures(row, parsed, fields_for(row, parsed))
  end

  def metrics(sonnet:, opus:, opus_wins: 0, sonnet_wins: 0, shared_fails: 0, sonnet_safety: 0, opus_safety: 0)
    {
      "complete_pairs" => 4,
      "sonnet_pass_rate" => sonnet,
      "opus_pass_rate" => opus,
      "opus_only_wins" => opus_wins,
      "sonnet_only_wins" => sonnet_wins,
      "shared_fails" => shared_fails,
      "safety_fail_count" => {
        "claude-sonnet-5-5" => sonnet_safety,
        "claude-opus-5-5" => opus_safety
      }
    }
  end

  def usage_call(model, returned = model, input:, output:, read:, create_5m:, create_1h: 0)
    {
      "requested_model_id" => model,
      "returned_model_id" => returned,
      "success" => true,
      "input_tokens" => input,
      "output_tokens" => output,
      "cache_read_tokens" => read,
      "cache_creation_5m_tokens" => create_5m,
      "cache_creation_1h_tokens" => create_1h
    }
  end

  def row_for(path, case_id)
    binary = File.binread(path)
    case_for("field_floor_indicator").merge(
      "case_id" => case_id,
      "filename" => "#{case_id}.png",
      "path" => path.to_s,
      "bytes" => binary.bytesize,
      "sha256" => Digest::SHA256.hexdigest(binary),
      "media_type" => "image/png",
      "width" => 2,
      "height" => 2
    )
  end

  def write_dataset(dir, spring:)
    Ext::CASES.each do |row|
      body = if row["case_id"] == "spring_assembly_misread"
        spring
      elsif row["filename"].end_with?(".jpeg")
        jpeg(8, 8)
      else
        png(8, 8)
      end
      File.binwrite(dir.join(row["filename"]), body)
    end
  end

  def png(width, height)
    "\x89PNG\r\n\x1a\n".b + [ 13 ].pack("N") + "IHDR" + [ width, height ].pack("NN")
  end

  def jpeg(width, height)
    segment = [ 8, 8, height, width, 1 ].pack("nCnnC")
    "\xFF\xD8\xFF\xC0".b + segment + "\xFF\xD9".b
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

    def models
      messages.creates.pluck(:model)
    end
  end

  class FakeMessage
    attr_reader :model, :content, :usage

    def initialize(model, text)
      @model = model
      @content = [ Struct.new(:type, :text).new("text", text) ]
      @usage = Struct.new(
        :input_tokens,
        :output_tokens,
        :cache_read_input_tokens,
        :cache_creation_input_tokens,
        :cache_creation
      ).new(20, 10, 0, 5, nil)
    end
  end
end
