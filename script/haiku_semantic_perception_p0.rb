# frozen_string_literal: true

# Effects: offline eval. One synchronous Bedrock Converse call per corpus line.
# Writes tmp/haiku_semantic_perception_p0_report.json only. No database writes.
# Network runs only when this file is executed and HAIKU_SEMANTIC_P0_LIBRARY_ONLY is unset.

require "digest"
require "json"
require "time"

module HaikuSemanticPerceptionP0
  MODEL_ID = "global.anthropic.claude-haiku-4-5-20251001-v1:0"
  INPUT_USD_PER_MTOKEN = 1
  OUTPUT_USD_PER_MTOKEN = 5
  TOOL_NAME = "semantic_perception"
  MAX_TOKENS = 300
  TEMPERATURE = 0

  CLIENT_OPTIONS = {
    retry_limit: 0,
    max_attempts: 1,
    http_open_timeout: 2,
    http_read_timeout: 8
  }.freeze

  # Copied from Rag::ActiveEpisodeTurn. Seed-only parsers below do not use ABSENT_CODE_RE.
  MODEL_VALUE_RE = /\b(?:modelo|model)\s*(?:es\s*)?:?\s*([A-Za-z0-9][A-Za-z0-9\-]{1,20})\b/
  ABSENT_CODE_RE = /\bno (muestra|marca|aparece|hay|tiene)\b.*\bcodigo\b|\bsin codigo\b|\bningun codigo\b|\bno code\b/
  KNOWN_CODE_RE = /\b(codigo|error|code)\s+(n\s+)?([a-z]?\d{1,4}[a-z]?)\b/

  RELATIONS = %w[continue answer_pending correct switch new unclear].freeze
  ROLES = %w[equipment component other].freeze
  INHERIT_RELATIONS = %w[continue answer_pending].freeze
  DROP_RELATIONS = %w[correct switch new].freeze
  REQUIRED_KEYS = %w[relation mentions refers_to ambiguous].freeze

  CORPUS_PATH = File.expand_path("fixtures/haiku_semantic_perception_p0.jsonl", __dir__)
  REPORT_PATH = File.expand_path("../tmp/haiku_semantic_perception_p0_report.json", __dir__)

  PROMPT = <<~PROMPT.freeze
    You return semantic perception for one technician turn. You are not a technical authority. You do not answer the procedure, invent measurements, or decide safety.

    relation definitions:
    continue
    = mismo equipo y misma tarea/problema; continúa el estado existente.

    answer_pending
    = el turno responde directamente a state.pending_question.

    correct
    = corrige un fact o identidad expresada previamente.
      El fact corregido no se hereda.

    switch
    = cambia a otro equipo, pero puede conservar el marco/tarea técnica.

    new
    = nueva tarea/problema.
      No se hereda contexto semántico previo.

    unclear
    = no existe evidencia suficiente para decidir de forma segura.
      Se comporta fail-closed igual que ambiguous=true.

    ambiguous=true implies fail-closed. relation=unclear also implies fail-closed.

    Span normalization for comparison:
    1. Unicode NFC
    2. Unicode lowercase/downcase
    3. collapse internal whitespace to one space
    4. trim whitespace
    5. trim punctuation only at the edges of the candidate span
    6. DO NOT fold accents

    Every span must be a literal substring of the turn after that normalization. No invented strings. No paraphrases. No canonicalization that leaves the input.

    refers_to.slot must be one of the slots in the user message. Do not invent a slot id.

    Output schema, returned only as the semantic_perception tool input:
    {"relation":"continue|answer_pending|correct|switch|new|unclear","mentions":[{"span":"MonoSpace","role":"equipment|component|other"}],"refers_to":[{"span":"el otro","slot":"obs_2"}],"ambiguous":false}
  PROMPT

  module_function

  def normalize_label(value)
    value.to_s
         .unicode_normalize(:nfkd)
         .gsub(/\p{Mn}/, "")
         .downcase
         .gsub(/[^\p{L}\d]+/, " ")
         .gsub(/[[:space:]]+/, " ")
         .strip
  end

  def normalize_turn(value)
    value.to_s.unicode_normalize(:nfc).downcase.gsub(/[[:space:]]+/, " ").strip
  end

  def normalize_candidate_span(value)
    normalize_turn(value).sub(/\A\p{P}+/u, "").sub(/\p{P}+\z/u, "")
  end

  def literal_span?(span, turn)
    candidate = normalize_candidate_span(span)
    return false if candidate.empty?

    normalize_turn(turn).include?(candidate)
  end

  def derived_slots(state)
    state = {} unless state.is_a?(Hash)
    slots = []
    slots << "pending_question" unless state["pending_question"].nil?
    slots << "active_referent" unless state["active_referent"].nil?
    Array(state["observations"]).each do |observation|
      next unless observation.is_a?(Hash)

      id = observation["id"].to_s
      slots << id unless id.empty?
    end
    slots
  end

  def user_message(turn, state)
    JSON.generate({ "turn" => turn.to_s, "state" => state || {}, "slots" => derived_slots(state) })
  end

  def tool_config
    {
      tools: [
        {
          tool_spec: {
            name: TOOL_NAME,
            description: "Return semantic perception for one technician turn.",
            input_schema: {
              json: {
                type: "object",
                properties: {
                  relation: { type: "string", enum: RELATIONS },
                  mentions: {
                    type: "array",
                    items: {
                      type: "object",
                      properties: {
                        span: { type: "string" },
                        role: { type: "string", enum: ROLES }
                      },
                      required: %w[span role]
                    }
                  },
                  refers_to: {
                    type: "array",
                    items: {
                      type: "object",
                      properties: {
                        span: { type: "string" },
                        slot: { type: "string" }
                      },
                      required: %w[span slot]
                    }
                  },
                  ambiguous: { type: "boolean" }
                },
                required: REQUIRED_KEYS
              }
            }
          }
        }
      ],
      tool_choice: { tool: { name: TOOL_NAME } }
    }
  end

  def converse_params(turn:, state:)
    {
      model_id: MODEL_ID,
      system: [ { text: PROMPT } ],
      messages: [ { role: "user", content: [ { text: user_message(turn, state) } ] } ],
      inference_config: { temperature: TEMPERATURE, max_tokens: MAX_TOKENS },
      tool_config: tool_config
    }
  end

  def client_options
    CLIENT_OPTIONS
  end

  def cost_usd(input_tokens, output_tokens)
    (input_tokens.to_f / 1_000_000.0) * INPUT_USD_PER_MTOKEN +
      (output_tokens.to_f / 1_000_000.0) * OUTPUT_USD_PER_MTOKEN
  end

  def closed_parse(turn, pending_question)
    raw = turn.to_s
    token = raw.match(MODEL_VALUE_RE)&.[](1)
    return { "kind" => "model", "value" => token } if token

    code = normalize_label(raw).match(KNOWN_CODE_RE)&.[](3)
    return { "kind" => "fault_code", "value" => code } if code

    pending_type = pending_question.is_a?(Hash) ? pending_question["type"].to_s : ""
    if raw.strip.casecmp?("ninguno") && pending_type == "fault_code"
      return { "kind" => "fault_code", "status" => "absent" }
    end

    options = pending_question.is_a?(Hash) ? Array(pending_question["options"]) : []
    if raw.strip.casecmp?("al abrir") && pending_type == "choice" && options == %w[opening closing]
      return { "kind" => "choice", "value" => "opening" }
    end

    if raw.strip == "24 V en X7"
      return { "value" => 24, "unit" => "V", "location" => "X7" }
    end

    nil
  end

  def load_corpus(path = CORPUS_PATH)
    File.readlines(path, chomp: true).reject(&:empty?).map { |line| JSON.parse(line) }
  end

  def extract_tool_input(content)
    block = Array(content).find do |item|
      tool = item.respond_to?(:tool_use) ? item.tool_use : item["tool_use"] || item[:tool_use]
      name = tool.respond_to?(:name) ? tool.name : tool && (tool["name"] || tool[:name])
      name == TOOL_NAME
    end
    return nil unless block

    tool = block.respond_to?(:tool_use) ? block.tool_use : block["tool_use"] || block[:tool_use]
    input = tool.respond_to?(:input) ? tool.input : tool["input"] || tool[:input]
    return input if input.is_a?(Hash)

    nil
  end

  def validate_output(output, turn:, slots:)
    return :invalid_schema unless output.is_a?(Hash)

    output = output.transform_keys(&:to_s)
    return :invalid_schema if REQUIRED_KEYS.any? { |key| !output.key?(key) }
    return :invalid_schema unless RELATIONS.include?(output["relation"])
    return :invalid_schema unless output["ambiguous"] == true || output["ambiguous"] == false
    return :invalid_schema unless output["mentions"].is_a?(Array) && output["refers_to"].is_a?(Array)

    output["mentions"].each do |mention|
      return :invalid_schema unless mention.is_a?(Hash)

      mention = mention.transform_keys(&:to_s)
      return :invalid_schema unless mention.key?("span") && ROLES.include?(mention["role"])
      return :hallucinated_spans unless literal_span?(mention["span"], turn)
    end

    output["refers_to"].each do |ref|
      return :invalid_schema unless ref.is_a?(Hash)

      ref = ref.transform_keys(&:to_s)
      return :invalid_schema unless ref.key?("span") && ref.key?("slot")
      return :invalid_schema unless slots.include?(ref["slot"].to_s)
      return :hallucinated_spans unless literal_span?(ref["span"], turn)
    end

    nil
  end

  def validated_slots(output)
    Array(output["refers_to"]).map { |ref| ref.transform_keys(&:to_s)["slot"].to_s }.uniq.sort
  end

  def project(error:, output:)
    empty = { "inherits_equipment" => false, "slots" => [] }
    return empty if error
    return empty if output["ambiguous"] == true
    return empty if output["relation"] == "unclear"

    inherits = INHERIT_RELATIONS.include?(output["relation"])
    inherits = false if DROP_RELATIONS.include?(output["relation"])
    { "inherits_equipment" => inherits, "slots" => validated_slots(output) }
  end

  def project_expected(expected, turn:, slots:)
    error = validate_output(expected, turn: turn, slots: slots)
    project(error: error, output: expected.is_a?(Hash) ? expected.transform_keys(&:to_s) : expected)
  end

  def unsafe_contamination?(projection, safety)
    safety = {} unless safety.is_a?(Hash)
    forbidden_inheritance = safety["equipment_inheritance"] == "forbidden" && projection["inherits_equipment"] == true
    forbidden_slots = Array(safety["forbidden_slots"]).map(&:to_s)
    slot_hit = Array(projection["slots"]).map(&:to_s).intersect?(forbidden_slots)
    forbidden_inheritance || slot_hit
  end

  def mention_match?(output_mention, expected_mention)
    output_mention = output_mention.transform_keys(&:to_s)
    expected_mention = expected_mention.transform_keys(&:to_s)
    return false unless output_mention["role"] == expected_mention["role"]

    accepted = [ expected_mention["span"], *Array(expected_mention["acceptable_spans"]) ]
    candidate = normalize_candidate_span(output_mention["span"])
    accepted.any? { |span| normalize_candidate_span(span) == candidate }
  end

  def recommendation(metrics)
    rate = metrics.fetch(:transport_error_rate)
    haiku = metrics[:projection_accuracy_haiku_open_world]
    v4 = metrics[:projection_accuracy_v4_open_world]
    proceed = metrics[:unsafe_contamination] == 0 &&
              haiku.is_a?(Numeric) && v4.is_a?(Numeric) && haiku > v4 &&
              rate <= 0.05
    proceed ? "PROCEED_RECOMMENDED" : "STOP_RECOMMENDED"
  end

  def aggregate(rows)
    total = rows.length
    open = rows.select { |row| row["family"] == "OPEN_WORLD" }
    closed = rows.select { |row| row["family"] == "CLOSED_CONTRACT" }
    ambiguous = rows.select { |row| row["expected_ambiguous"] == true }
    transport = rows.count { |row| row["error"] == "transport_error" }
    rate = total.zero? ? 1.0 : transport.to_f / total
    durations = rows.filter_map { |row| row["semantic_analysis_ms"] }

    {
      unsafe_contamination: rows.count { |row| row["unsafe_contamination"] },
      projection_accuracy_haiku_open_world: ratio(open.count { |row| row["projection_match"] }, open.length),
      projection_accuracy_v4_open_world: ratio(open.count { |row| row["v4_projection_match"] }, open.length),
      relation_accuracy: ratio(open.count { |row| row["relation_match"] }, open.length),
      slot_accuracy: ratio(open.count { |row| row["slot_match"] }, open.length),
      ambiguous_surfaced: ratio(ambiguous.count { |row| row["ambiguous_hit"] }, ambiguous.length),
      closed_relation_agreement: ratio(closed.count { |row| row["relation_match"] }, closed.length),
      invalid_schema: rows.count { |row| row["error"] == "invalid_schema" },
      hallucinated_spans: rows.count { |row| row["error"] == "hallucinated_spans" },
      transport_error: transport,
      transport_error_rate: rate,
      input_tokens: rows.sum { |row| row["input_tokens"].to_i },
      output_tokens: rows.sum { |row| row["output_tokens"].to_i },
      cost_usd: rows.sum { |row| row["cost_usd"].to_f },
      semantic_analysis_ms_p50: percentile(durations, 50),
      semantic_analysis_ms_p95: percentile(durations, 95)
    }
  end

  def ratio(numerator, denominator)
    return nil if denominator.zero?

    numerator.to_f / denominator
  end

  def percentile(values, percentile_rank)
    sorted = values.compact.sort
    return nil if sorted.empty?

    rank = (percentile_rank / 100.0) * (sorted.length - 1)
    low = sorted[rank.floor]
    high = sorted[rank.ceil]
    low + (high - low) * (rank - rank.floor)
  end

  def score_case(corpus_row, output:, error:)
    turn = corpus_row["turn"]
    slots = derived_slots(corpus_row["state"])
    expected = corpus_row["expected"] || {}
    schema_error = error || validate_output(output, turn: turn, slots: slots)
    schema_error = schema_error.to_s if schema_error
    parsed = output.is_a?(Hash) ? output.transform_keys(&:to_s) : {}
    projection = project(error: schema_error, output: parsed)
    gold = project_expected(expected, turn: turn, slots: slots)
    expected_slots = Array(expected["refers_to"]).map { |ref| ref["slot"].to_s }.uniq.sort
    output_slots = schema_error ? [] : validated_slots(parsed)
    relation_match = !schema_error && parsed["relation"] == expected["relation"]
    v4 = corpus_row["v4_expectation"] || {}
    v4_projection = {
      "inherits_equipment" => v4["inherits_equipment"],
      "slots" => Array(v4["slots"]).map(&:to_s).uniq.sort
    }
    {
      "id" => corpus_row["id"],
      "family" => corpus_row["family"],
      "error" => schema_error,
      "projection" => projection,
      "gold" => gold,
      "projection_match" => projection == gold,
      "v4_projection_match" => v4_projection == gold,
      "relation_match" => relation_match,
      "slot_match" => !schema_error && output_slots == expected_slots,
      "expected_ambiguous" => expected["ambiguous"] == true,
      "ambiguous_hit" => !schema_error && expected["ambiguous"] == true && parsed["ambiguous"] == true,
      "unsafe_contamination" => unsafe_contamination?(projection, corpus_row["safety"])
    }
  end

  class Runner
    def self.call
      new.call
    end

    def call
      cases = HaikuSemanticPerceptionP0.load_corpus
      client = Aws::BedrockRuntime::Client.new(HaikuSemanticPerceptionP0.client_options)
      rows = []
      stop = nil

      cases.each_with_index do |corpus_row, index|
        outcome = converse_case(client, corpus_row)
        if outcome[:fatal]
          stop = { "status" => "blocked", "case_id" => corpus_row["id"], "error_class" => outcome[:error_class], "message" => outcome[:message] }
          break
        end

        rows << outcome[:row]
        transport = rows.count { |row| row["error"] == "transport_error" }
        rate = transport.to_f / cases.length
        next unless rate > 0.05 && (index + 1) < cases.length

        stop = { "status" => "infrastructure_failure", "transport_error_rate" => rate }
        break
      end

      metrics = HaikuSemanticPerceptionP0.aggregate(rows)
      report = {
        "decision" => "PENDING_HUMAN",
        "recommendation" => stop ? "STOP_RECOMMENDED" : HaikuSemanticPerceptionP0.recommendation(metrics),
        "status" => stop ? stop["status"] : "complete",
        "stop" => stop,
        "model_id" => HaikuSemanticPerceptionP0::MODEL_ID,
        "corpus_sha256" => Digest::SHA256.hexdigest(File.binread(HaikuSemanticPerceptionP0::CORPUS_PATH)),
        "prompt_sha256" => Digest::SHA256.hexdigest(HaikuSemanticPerceptionP0::PROMPT),
        "cases_scored" => rows.length,
        "metrics" => metrics,
        "cases" => rows
      }
      FileUtils.mkdir_p(File.dirname(HaikuSemanticPerceptionP0::REPORT_PATH))
      File.write(HaikuSemanticPerceptionP0::REPORT_PATH, JSON.pretty_generate(report))
      warn(JSON.generate(stop)) if stop
      exit(stop ? 1 : 0)
    end

    private

    def converse_case(client, corpus_row)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = client.converse(
        HaikuSemanticPerceptionP0.converse_params(turn: corpus_row["turn"], state: corpus_row["state"])
      )
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      input_tokens = response.usage&.input_tokens.to_i
      output_tokens = response.usage&.output_tokens.to_i
      content = response.output&.message&.content
      tool_input = HaikuSemanticPerceptionP0.extract_tool_input(content)
      error = tool_input.nil? ? :invalid_schema : nil
      scored = HaikuSemanticPerceptionP0.score_case(corpus_row, output: tool_input || {}, error: error)
      scored = scored.merge(
        "stop_reason" => response.stop_reason,
        "aws_latency_ms" => response.metrics&.latency_ms,
        "semantic_analysis_ms" => elapsed_ms,
        "input_tokens" => input_tokens,
        "output_tokens" => output_tokens,
        "cost_usd" => HaikuSemanticPerceptionP0.cost_usd(input_tokens, output_tokens)
      )
      { fatal: false, row: scored }
    rescue StandardError => error
      if fatal_client_error?(error)
        { fatal: true, error_class: error.class.name, message: error.message }
      elsif transport_error?(error)
        elapsed_ms = 0
        scored = HaikuSemanticPerceptionP0.score_case(corpus_row, output: {}, error: :transport_error)
        scored.merge!(
          "stop_reason" => nil,
          "aws_latency_ms" => nil,
          "semantic_analysis_ms" => elapsed_ms,
          "input_tokens" => 0,
          "output_tokens" => 0,
          "cost_usd" => 0.0
        )
        { fatal: false, row: scored }
      else
        { fatal: true, error_class: error.class.name, message: error.message }
      end
    end

    def fatal_client_error?(error)
      name = error.class.name.to_s
      message = error.message.to_s
      return true if name.include?("ValidationException")
      return true if name.include?("AccessDenied")
      return true if name.include?("MissingCredentials")
      return true if name.include?("UnrecognizedClient")
      return true if name.include?("ResourceNotFound")
      return true if message.match?(/tool_choice|tool_config|inference profile|model identifier is invalid|on-demand throughput/i)

      false
    end

    def transport_error?(error)
      name = error.class.name.to_s
      return true if name.include?("NetworkingError")
      return true if error.is_a?(Timeout::Error)
      return true if name.include?("Throttl") || name.include?("TooManyRequests")
      return true if name.include?("InternalServer") || name.include?("ServiceUnavailable") || name.include?("ModelTimeout")

      status = error.respond_to?(:context) ? error.context&.http_response&.status_code : nil
      status.to_i >= 500
    end
  end
end

if ENV["HAIKU_SEMANTIC_P0_LIBRARY_ONLY"] != "1" && __FILE__ == $PROGRAM_NAME
  require "aws-sdk-bedrockruntime"
  require "fileutils"
  HaikuSemanticPerceptionP0::Runner.call
end
