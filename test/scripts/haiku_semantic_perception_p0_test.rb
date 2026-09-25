# frozen_string_literal: true

require "test_helper"

ENV["HAIKU_SEMANTIC_P0_LIBRARY_ONLY"] = "1"
require Rails.root.join("script/haiku_semantic_perception_p0.rb")

class HaikuSemanticPerceptionP0Test < ActiveSupport::TestCase
  FIXED_TIME = Time.utc(2026, 9, 25, 15, 0, 0)
  H = HaikuSemanticPerceptionP0

  setup do
    @cases = H.load_corpus
  end

  test "jsonl rows carry the fixture contract and no manual slots list" do
    assert_includes 60..90, @cases.length
    assert_equal 70, @cases.length
    assert_equal 10, @cases.count { |row| row["family"] == "CLOSED_CONTRACT" }
    assert_equal 16, @cases.count { |row| row["id"].start_with?("open-") }
    assert_equal 22, @cases.count { |row| row["id"].start_with?("lex-") }
    assert_equal 18, @cases.count { |row| row["id"].start_with?("var-") }
    assert_equal 4, @cases.count { |row| row["id"].start_with?("ctrl-") }
    assert_equal @cases.length, @cases.pluck("id").uniq.length

    controls = @cases.select { |row| Array(row["tags"]).include?("no_inherited_state") }
    assert_equal 4, controls.length
    controls.each do |row|
      assert_nil row.dig("state", "equipment"), row["id"]
      assert_nil row.dig("state", "goal"), row["id"]
    end

    critical = @cases.count { |row| safety_critical?(row["safety"]) }
    assert_operator critical, :>=, 25

    @cases.each do |row|
      assert row.key?("state"), row["id"]
      assert row.key?("expected"), row["id"]
      assert row.key?("safety"), row["id"]
      assert row.key?("v4_expectation"), row["id"]
      assert_not row.key?("slots"), row["id"]
      assert_not row["state"].key?("slots"), row["id"]
      assert_includes %w[CLOSED_CONTRACT OPEN_WORLD], row["family"]
      assert_includes %w[allowed forbidden n/a], row.dig("safety", "equipment_inheritance")
      assert_kind_of Array, row.dig("safety", "forbidden_slots")
      assert_includes H::RELATIONS, row.dig("expected", "relation")
      assert_includes [ true, false ], row.dig("expected", "ambiguous")
      Array(row.dig("expected", "mentions")).each do |mention|
        assert_includes H::ROLES, mention["role"], row["id"]
        assert H.literal_span?(mention["span"], row["turn"]), "#{row["id"]} #{mention["span"]}"
        Array(mention["acceptable_spans"]).each do |span|
          assert H.literal_span?(span, row["turn"]), row["id"]
        end
      end
      slots = H.derived_slots(row["state"])
      Array(row.dig("expected", "refers_to")).each do |ref|
        assert_includes slots, ref["slot"], row["id"]
        assert H.literal_span?(ref["span"], row["turn"]), row["id"]
      end
      assert_nil H.validate_output(row["expected"], turn: row["turn"], slots: slots), row["id"]
    end
  end

  test "derived slots follow state and an unknown slot is invalid_schema" do
    state = {
      "pending_question" => { "type" => "fault_code" },
      "active_referent" => "variador",
      "observations" => [ { "id" => "obs_1", "summary" => "ruido" }, { "id" => "obs_2", "summary" => "freno" } ]
    }
    assert_equal %w[pending_question active_referent obs_1 obs_2], H.derived_slots(state)
    assert_equal [], H.derived_slots("pending_question" => nil, "active_referent" => nil, "observations" => [])

    output = perception("continue", refers_to: [ { "span" => "el otro", "slot" => "obs_9" } ])
    assert_equal :invalid_schema, H.validate_output(output, turn: "el otro", slots: [ "obs_1" ])
  end

  test "a non-literal span is hallucinated and accents are not folded" do
    assert_equal :hallucinated_spans, H.validate_output(
      perception("continue", mentions: [ { "span" => "relé", "role" => "component" } ]),
      turn: "rele",
      slots: []
    )
    assert_nil H.validate_output(
      perception("continue", mentions: [ { "span" => "relé", "role" => "component" } ]),
      turn: "el relé no conmuta",
      slots: []
    )
    assert_not H.literal_span?("relé", "rele")
  end

  test "unknown enum, missing key, and missing tool input are invalid_schema" do
    assert_equal :invalid_schema, H.validate_output(
      perception("maybe"),
      turn: "el otro",
      slots: []
    )
    missing = perception("continue")
    missing.delete("ambiguous")
    assert_equal :invalid_schema, H.validate_output(missing, turn: "el otro", slots: [])
    assert_nil H.extract_tool_input([ { "text" => "no tool" } ])
    assert_equal :invalid_schema, H.validate_output(nil, turn: "el otro", slots: [])
  end

  test "invalid output does not inherit equipment or slots" do
    projection = H.project(error: :invalid_schema, output: perception("continue", refers_to: [ { "span" => "el otro", "slot" => "obs_1" } ]))
    assert_equal false, projection["inherits_equipment"]
    assert_equal [], projection["slots"]

    transport = H.project(error: :transport_error, output: {})
    assert_equal({ "inherits_equipment" => false, "slots" => [] }, transport)
  end

  test "unsafe contamination uses only the registered formula" do
    forbidden = { "equipment_inheritance" => "forbidden", "forbidden_slots" => [] }
    allowed = { "equipment_inheritance" => "allowed", "forbidden_slots" => [ "obs_1" ] }
    blank = { "equipment_inheritance" => "n/a", "forbidden_slots" => [] }

    assert H.unsafe_contamination?({ "inherits_equipment" => true, "slots" => [] }, forbidden)
    assert_not H.unsafe_contamination?({ "inherits_equipment" => false, "slots" => [] }, forbidden)
    assert_not H.unsafe_contamination?({ "inherits_equipment" => true, "slots" => [] }, allowed)
    assert H.unsafe_contamination?({ "inherits_equipment" => false, "slots" => [ "obs_1" ] }, allowed)
    assert_not H.unsafe_contamination?({ "inherits_equipment" => false, "slots" => [ "obs_2" ] }, allowed)
    assert_not H.unsafe_contamination?({ "inherits_equipment" => true, "slots" => [] }, blank)

    unclear = H.project(error: nil, output: perception("unclear", ambiguous: false))
    ambiguous = H.project(error: nil, output: perception("continue", ambiguous: true, refers_to: [ { "span" => "el otro", "slot" => "obs_1" } ]))
    assert_equal false, unclear["inherits_equipment"]
    assert_equal [], unclear["slots"]
    assert_equal [], ambiguous["slots"]
    assert_not H.unsafe_contamination?(unclear, forbidden)
  end

  test "closed parsers match the five seeds and the copied v4 contracts" do
    assert_equal "MonoSpace", H.closed_parse("modelo es MonoSpace", nil)["value"]
    assert_equal "8", H.closed_parse("código 8", nil)["value"]
    assert_equal "absent", H.closed_parse("ninguno", { "type" => "fault_code" })["status"]
    assert_equal "opening", H.closed_parse("al abrir", { "type" => "choice", "options" => %w[opening closing] })["value"]
    measurement = H.closed_parse("24 V en X7", nil)
    assert_equal 24, measurement["value"]
    assert_equal "V", measurement["unit"]
    assert_equal "X7", measurement["location"]

    assert_nil H.closed_parse("ninguno", nil)
    assert_nil H.closed_parse("al abrir", { "type" => "choice", "options" => %w[opening] })
    assert_nil H.closed_parse("24 V on X7", nil)
    assert_not H::ABSENT_CODE_RE.match?(H.normalize_label("ninguno"))
    assert_not Rag::ActiveEpisodeTurn::ABSENT_CODE_RE.match?(Rag::FollowupQueryRewriter.normalize_label("ninguno"))

    assert_equal Rag::ActiveEpisodeTurn::MODEL_VALUE_RE, H::MODEL_VALUE_RE
    assert_equal Rag::ActiveEpisodeTurn::KNOWN_CODE_RE, H::KNOWN_CODE_RE
    assert_equal Rag::ActiveEpisodeTurn::ABSENT_CODE_RE, H::ABSENT_CODE_RE
    [ "código 8", "¿Y en el Nova?", "  Modelo   es  MonoSpace ", "relé", "ninguno", "24 V en X7", "al abrir" ].each do |sample|
      assert_equal Rag::FollowupQueryRewriter.normalize_label(sample), H.normalize_label(sample), sample
    end

    @cases.each do |row|
      parsed = H.closed_parse(row["turn"], row.dig("state", "pending_question"))
      if row["family"] == "CLOSED_CONTRACT"
        assert_equal parsed, row.dig("expected", "closed_parse"), row["id"]
      else
        assert_nil row.dig("expected", "closed_parse"), row["id"]
      end
    end
  end

  test "handwritten v4 expectation matches ActiveEpisodeTurn" do
    @cases.each do |row|
      assert_equal [], row.dig("v4_expectation", "slots"), row["id"]
      assert_equal v4_inherits?(row), row.dig("v4_expectation", "inherits_equipment"), row["id"]
    end
    assert_not_includes Rails.root.join("script/haiku_semantic_perception_p0.rb").read, "record_user_turn!"
  end

  test "prompt, model, client, price, and tool config stay on the frozen contract" do
    prompt = H::PROMPT
    [
      "mismo equipo y misma tarea/problema",
      "el turno responde directamente a state.pending_question",
      "corrige un fact o identidad expresada previamente",
      "cambia a otro equipo, pero puede conservar el marco/tarea técnica",
      "nueva tarea/problema",
      "no existe evidencia suficiente para decidir de forma segura",
      "Unicode NFC",
      "DO NOT fold accents",
      "No invented strings",
      "ambiguous=true implies fail-closed",
      "relation=unclear also implies fail-closed",
      "semantic_perception"
    ].each { |fragment| assert_includes prompt, fragment }

    @cases.each do |row|
      next if row["turn"].length < 12

      assert_not_includes prompt, row["turn"], row["id"]
    end

    assert_equal "global.anthropic.claude-haiku-4-5-20251001-v1:0", H::MODEL_ID
    assert_equal(
      { retry_limit: 0, max_attempts: 1, http_open_timeout: 2, http_read_timeout: 8 },
      H.client_options
    )
    pricing = BedrockQuery::BEDROCK_PRICING.fetch(H::MODEL_ID)
    assert_equal 1, pricing[:input] * 1000
    assert_equal 5, pricing[:output] * 1000
    assert_equal 1, H::INPUT_USD_PER_MTOKEN
    assert_equal 5, H::OUTPUT_USD_PER_MTOKEN
    assert_in_delta 0.0035, H.cost_usd(2500, 200), 0.000_000_1

    source = Rails.root.join("script/haiku_semantic_perception_p0.rb").read
    assert_not_includes source, "BedrockQuery"
    assert_not_includes source, "bulk_chunks"
    assert_not_includes source, "KbDocumentResolver"

    config = H.tool_config
    assert_equal 1, config[:tools].length
    assert_equal "semantic_perception", config.dig(:tools, 0, :tool_spec, :name)
    assert_equal({ name: "semantic_perception" }, config.dig(:tool_choice, :tool))
    assert_nil config.dig(:tool_choice, :auto)
    assert_nil config.dig(:tool_choice, :any)

    params = H.converse_params(turn: "el otro", state: { "equipment" => nil })
    assert_equal H::MODEL_ID, params[:model_id]
    assert_equal 0, params.dig(:inference_config, :temperature)
    assert_equal 300, params.dig(:inference_config, :max_tokens)
    message = JSON.parse(params.dig(:messages, 0, :content, 0, :text))
    assert_equal %w[turn state slots], message.keys
    assert_equal [ "turn", "state", "slots" ].sort, message.keys.sort
  end

  test "recommendation rule is the pre-registered comparison" do
    base = {
      unsafe_contamination: 0,
      projection_accuracy_haiku_open_world: 0.8,
      projection_accuracy_v4_open_world: 0.4,
      transport_error_rate: 0.05
    }
    assert_equal "PROCEED_RECOMMENDED", H.recommendation(base)
    assert_equal "STOP_RECOMMENDED", H.recommendation(base.merge(unsafe_contamination: 1))
    assert_equal "STOP_RECOMMENDED", H.recommendation(base.merge(projection_accuracy_haiku_open_world: 0.4))
    assert_equal "STOP_RECOMMENDED", H.recommendation(base.merge(transport_error_rate: 0.051))
  end

  private

  def perception(relation, mentions: [], refers_to: [], ambiguous: false)
    {
      "relation" => relation,
      "mentions" => mentions,
      "refers_to" => refers_to,
      "ambiguous" => ambiguous
    }
  end

  def safety_critical?(safety)
    safety["equipment_inheritance"] == "forbidden" || Array(safety["forbidden_slots"]).any?
  end

  def v4_inherits?(row)
    result = Rag::ActiveEpisodeTurn.call(
      state: episode_hash(row["state"]),
      text: row["turn"],
      enabled: true,
      shared: false,
      now: FIXED_TIME
    )
    equipment = row.dig("state", "equipment")
    equipment = {} unless equipment.is_a?(Hash)
    keys = %w[manufacturer model].select { |key| !equipment[key].nil? }
    return false if keys.empty?

    keys.all? do |key|
      fact = result.state.dig("facts", key)
      fact.is_a?(Hash) && fact["status"] == "known" && fact["value"] == equipment[key]
    end
  end

  def episode_hash(state)
    equipment = state["equipment"].is_a?(Hash) ? state["equipment"] : {}
    facts = {}
    %w[manufacturer model].each do |key|
      value = equipment[key]
      next if value.nil?

      facts[key] = {
        "status" => "known",
        "source" => "user",
        "value" => value,
        "correlation_id" => "",
        "at" => FIXED_TIME.iso8601
      }
    end
    hash = {
      "v" => 1,
      "episode_id" => "ep_p0",
      "opened_at" => FIXED_TIME.iso8601,
      "updated_at" => FIXED_TIME.iso8601,
      "facts" => facts
    }
    if state["goal"]
      hash["goal"] = { "text" => state["goal"].to_s, "correlation_id" => "", "truncated" => false }
    end
    pending = state["pending_question"]
    if pending.is_a?(Hash) && %w[manufacturer model fault_code].include?(pending["type"].to_s)
      hash["pending_fact"] = { "subject" => pending["type"].to_s, "correlation_id" => "" }
    end
    hash
  end
end
