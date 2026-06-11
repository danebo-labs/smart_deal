# frozen_string_literal: true

require "fileutils"
require "json"

class RagQualityBenchmarkEvaluator
  BENCHMARK_VERSION = "2026-06-11-v3"
  RUBRIC_PATH = Rails.root.join("script/fixtures/rag_quality_benchmark_atomic_rubric.json")
  FIELD_RECORDS_PATH = Rails.root.join("script/fixtures/rag_quality_benchmark_field_records.json")
  # The four deterministic cases never invoke the model: 16 cases - 4 = 12.
  EXPECTED_DETERMINISTIC_COUNT = 4
  EXPECTED_MODEL_INVOCATIONS = 12
  CANONICAL = {
    "benchmark_version" => BENCHMARK_VERSION,
    "benchmark_mode" => "certification",
    "model_id" => "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "aws_region" => "us-east-1",
    "knowledge_base_id" => "QGVYLPTEGT"
  }.freeze
  EXPECTED_KEYS = (
    (1..6).map { |index| [ "isolated", index ] } +
    (1..6).map { |index| [ "conversation", index ] } +
    (1..3).map { |index| [ "source_isolation", index ] } +
    [ [ "visual_fidelity", 1 ] ]
  ).freeze
  EXPECTED_KEY_STRINGS = EXPECTED_KEYS.map { |phase, index| "#{phase}:#{index}" }.freeze
  EXHAUSTIVE_KEYS = [ [ "isolated", 5 ], [ "conversation", 5 ] ].freeze
  STOP_WORK_KEYS = [ [ "isolated", 3 ], [ "conversation", 3 ] ].freeze
  REPAIR_KEYS = [ [ "isolated", 6 ], [ "conversation", 6 ] ].freeze
  VISUAL_CODES = %w[SV1 SV2 SV3 SV4 RV1 RV2 RV3 CV1 CV2 ORF1 ORF3 ORF4 FRRV1 BRK P41 P42].freeze
  PRIMARY_VISUAL_CODES = %w[FRRV1 P41 P42 ORF1 BRK].freeze
  COHORT_FIELDS = %w[
    benchmark_version benchmark_mode git_revision git_dirty
    code_fingerprint_sha256 model_id aws_region knowledge_base_id
    configuration corpus target_case_keys executed_case_keys expected_call_count
  ].freeze

  attr_reader :report

  def initialize(payload, source: nil, rubric: nil, records_manifest: nil, canonical: CANONICAL)
    @payload = payload.deep_stringify_keys
    @source = source
    @rubric = rubric&.deep_stringify_keys
    @records_manifest = (records_manifest || self.class.load_records_manifest).deep_stringify_keys
    @canonical = canonical.deep_stringify_keys
    @failures = []
  end

  def evaluate
    validate_certification_metadata
    validate_matrix
    validate_execution
    validate_exhaustive_cases
    validate_stop_work_cases
    validate_visual_cases
    validate_source_isolation
    validate_repair_cases

    @report = {
      source: @source,
      passed: @failures.empty?,
      failure_count: @failures.size,
      failures: @failures
    }
  end

  def self.load_rubric
    JSON.parse(File.read(RUBRIC_PATH))
  rescue JSON::ParserError, Errno::ENOENT => e
    raise ArgumentError, "Atomic rubric unavailable: #{e.message}"
  end

  # Fase 4 manifest: expected RECORD_IDs per deterministic case plus the
  # 24-functional-unit → record_id mapping, signed against the source PDF.
  def self.load_records_manifest
    JSON.parse(File.read(FIELD_RECORDS_PATH))
  rescue JSON::ParserError, Errno::ENOENT => e
    raise ArgumentError, "Field records manifest unavailable: #{e.message}"
  end

  def self.evaluate_files(paths, rubric: nil, canonical: CANONICAL)
    payloads = []
    reports = paths.map do |path|
      payload = JSON.parse(File.read(path))
      payloads << [ path, payload ]
      new(payload, source: path, rubric: rubric, canonical: canonical).evaluate
    rescue JSON::ParserError, Errno::ENOENT, ArgumentError => e
      {
        source: path,
        passed: false,
        failure_count: 1,
        failures: [ { rule: "file", message: e.message } ]
      }
    end

    cohort = evaluate_cohort(payloads)
    { reports: reports, cohort: cohort }
  end

  def self.evaluate_cohort(payloads)
    failures = []
    failures << { rule: "cohort", message: "expected exactly 3 certification files" } unless payloads.size == 3

    if payloads.any?
      baseline_path, baseline = payloads.first
      COHORT_FIELDS.each do |field|
        payloads.drop(1).each do |path, payload|
          next if payload[field] == baseline[field]

          failures << {
            rule: "cohort",
            message: "#{field} differs between #{baseline_path} and #{path}"
          }
        end
      end
    end

    {
      passed: failures.empty?,
      failure_count: failures.size,
      failures: failures
    }
  end

  private

  def validate_certification_metadata
    @canonical.each do |field, expected|
      fail_rule("certification", "#{field} must equal #{expected.inspect}") unless @payload[field] == expected
    end
    fail_rule("certification", "git_dirty must be false") unless @payload["git_dirty"] == false
    fail_rule("certification", "git_revision is missing") if @payload["git_revision"].blank?
    unless @payload["code_fingerprint_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
      fail_rule("certification", "code_fingerprint_sha256 is invalid")
    end
    unless @payload["target_case_keys"] == EXPECTED_KEY_STRINGS
      fail_rule("certification", "target_case_keys must contain the canonical 16 cases")
    end
    unless @payload["executed_case_keys"] == EXPECTED_KEY_STRINGS
      fail_rule("certification", "executed_case_keys must contain the canonical 16 cases")
    end
    fail_rule("certification", "expected_call_count must equal 16") unless @payload["expected_call_count"] == 16

    %w[manual image].each do |name|
      descriptor = @payload.dig("corpus", name) || {}
      actual = descriptor["source_sha256"]
      expected = descriptor["expected_source_sha256"]
      unless actual.to_s.match?(/\A[0-9a-f]{64}\z/) && actual == expected
        fail_rule("certification", "#{name} corpus SHA-256 is missing or differs from manifest")
      end
    end
  end

  def validate_matrix
    keys = results.map { |result| case_key(result) }
    duplicates = keys.tally.select { |_key, count| count > 1 }.keys
    missing = EXPECTED_KEYS - keys
    extras = keys - EXPECTED_KEYS

    fail_rule("matrix", "expected exactly 16 results, got #{results.size}") unless results.size == 16
    fail_rule("matrix", "missing cases: #{format_keys(missing)}") if missing.any?
    fail_rule("matrix", "duplicate cases: #{format_keys(duplicates)}") if duplicates.any?
    fail_rule("matrix", "unexpected cases: #{format_keys(extras)}") if extras.any?
  end

  def validate_execution
    fail_rule("execution", "query_count must equal 16") unless @payload["query_count"] == 16
    unless @payload["tracked_query_count"] == EXPECTED_MODEL_INVOCATIONS
      fail_rule("execution", "tracked_query_count must equal #{EXPECTED_MODEL_INVOCATIONS} (4 deterministic answers do not invoke the model)")
    end
    unless @payload["deterministic_query_count"] == EXPECTED_DETERMINISTIC_COUNT
      fail_rule("execution", "deterministic_query_count must equal #{EXPECTED_DETERMINISTIC_COUNT}")
    end
    unless @payload["model_invocation_count"] == EXPECTED_MODEL_INVOCATIONS
      fail_rule("execution", "model_invocation_count must equal #{EXPECTED_MODEL_INVOCATIONS}")
    end
    fail_rule("execution", "run_error must be nil") if @payload["run_error"].present?

    results.each do |result|
      key = case_key(result)
      fail_case("execution", key, "success must be true") unless result["success"] == true
      fail_case("execution", key, "answer must be non-empty") if result["answer"].to_s.strip.empty?
      if result["error_type"].present? || result["error_message"].present?
        fail_case("execution", key, "error_type and error_message must be nil")
      end
    end
  end

  # Deterministic exhaustive cases (Fase 9): the coverage ledger is a set
  # equality against the PDF-reviewed manifest, not a pattern estimate.
  def validate_exhaustive_cases
    expected_ids = Array(@records_manifest.dig("functional_test_cases", "expected_record_ids")).sort
    units = @records_manifest["functional_units"] || {}

    EXHAUSTIVE_KEYS.each do |key|
      result = result_for(key)
      next unless result

      validate_deterministic_result(key, result, "deterministic_functional_tests", expected_ids)

      rendered = Array(result["rendered_record_ids"])
      units.each do |unit_id, unit|
        next if Array(unit["record_ids"]).intersect?(rendered)

        fail_case("exhaustive", key, "missing functional unit #{unit_id}")
      end

      raw = result["answer"].to_s
      entries = parse_exhaustive_entries(raw, key)
      unless entries.size == rendered.size
        fail_case("exhaustive", key, "visible entries (#{entries.size}) != rendered records (#{rendered.size})")
      end
      if raw.match?(/\bFR-[0-9A-F]{16}\b/)
        fail_case("exhaustive", key, "internal RECORD_IDs are visible to the technician")
      end

      # Every manifest record must appear verbatim (action + expected result) —
      # an entry that borrows a neighbor's result or paraphrases fails here.
      entry_pairs = entries.map { |e| [ normalize(e["accion"]), normalize(e["resultado"]) ] }
      Array(@records_manifest.dig("functional_test_cases", "records")).each do |record|
        pair = [ normalize(record["action"]), normalize(record["expected_result"]) ]
        unless entry_pairs.include?(pair)
          fail_case("exhaustive", key, "record #{record['record_id']} is not rendered verbatim")
        end
      end
    end
  end

  def validate_deterministic_result(key, result, expected_mode, expected_ids)
    unless result["generation_mode"] == expected_mode
      fail_case("deterministic", key, "generation_mode must be #{expected_mode}, got #{result['generation_mode'].inspect}")
    end
    unless result["model_invoked"] == false
      fail_case("deterministic", key, "model_invoked must be false")
    end
    unless result["deterministic_validation"] == "ok"
      fail_case("deterministic", key, "deterministic_validation is #{result['deterministic_validation'].inspect}")
    end

    rendered = Array(result["rendered_record_ids"]).sort
    parsed   = Array(result["parsed_record_ids"]).sort

    if expected_ids.empty?
      fail_case("deterministic", key, "manifest has no expected record ids for this case")
    elsif rendered != expected_ids
      missing = expected_ids - rendered
      extras  = rendered - expected_ids
      fail_case("deterministic", key, "rendered ids differ from manifest (missing: #{missing.size}, extras: #{extras.size})")
    end

    unrendered_unparsed = rendered - parsed
    if unrendered_unparsed.any?
      fail_case("deterministic", key, "rendered ids not present in parsed ledger: #{unrendered_unparsed.size}")
    end
  end

  def rubric_units_for(key)
    case_manifest = @rubric.dig("cases", key_string(key)) || {}
    return Array(case_manifest["units"]) if case_manifest["units"].present?

    Array(case_manifest["unit_ids"]).filter_map do |unit_id|
      unit = @rubric.dig("units", unit_id)
      unit&.merge("id" => unit_id)
    end
  end

  def parse_exhaustive_entries(raw, key)
    blocks = raw.to_s.strip.split(/\n[ \t]*\n+/)
    entries = []

    blocks.each_with_index do |block, index|
      lines = block.lines.map(&:strip).reject(&:empty?)
      fields = {}
      valid = lines.size == 3

      lines.each do |line|
        match = line.match(/\A(Prueba|Acción|Resultado esperado):\s*(.+)\z/i)
        valid = false unless match
        next unless match

        label = normalize(match[1])
        valid = false if fields.key?(label)
        fields[label] = match[2].strip
      end

      expected = [ "prueba", "accion", "resultado esperado" ]
      valid &&= fields.keys.sort == expected.sort && fields.values.none?(&:blank?)
      unless valid
        fail_case("exhaustive_grammar", key, "invalid entry #{index + 1}; expected exactly Prueba/Acción/Resultado esperado")
        next
      end

      entries << {
        "prueba" => fields["prueba"],
        "accion" => fields["accion"],
        "resultado" => fields["resultado esperado"]
      }
    end

    entries
  end

  def entry_matches_unit?(entry, unit)
    pattern_groups = {
      "prueba" => Array(unit["test_patterns"]),
      "accion" => Array(unit["action_patterns"]),
      "resultado" => Array(unit["result_patterns"])
    }

    pattern_groups.all? do |field, patterns|
      text = normalize(entry.fetch(field))
      patterns.present? && patterns.all? { |pattern| text.match?(Regexp.new(pattern)) }
    end
  rescue RegexpError
    false
  end

  def maximum_assignment(candidates)
    entry_to_unit = {}
    unit_to_entry = {}

    candidates.each_key do |unit_id|
      visited = {}
      assign_unit(unit_id, candidates, entry_to_unit, unit_to_entry, visited)
    end
    unit_to_entry
  end

  def assign_unit(unit_id, candidates, entry_to_unit, unit_to_entry, visited)
    candidates.fetch(unit_id, []).each do |entry_index|
      next if visited[entry_index]

      visited[entry_index] = true
      current_unit = entry_to_unit[entry_index]
      next if current_unit && !assign_unit(
        current_unit, candidates, entry_to_unit, unit_to_entry, visited
      )

      entry_to_unit[entry_index] = unit_id
      unit_to_entry.delete(current_unit) if current_unit
      unit_to_entry[unit_id] = entry_index
      return true
    end
    false
  end

  def validate_stop_work_cases
    expected_ids = Array(@records_manifest.dig("stop_work_cases", "expected_record_ids")).sort
    expected_mandatory = Array(@records_manifest.dig("stop_work_cases", "expected_mandatory_record_ids"))

    STOP_WORK_KEYS.each do |key|
      result = result_for(key)
      raw = answer_for(key)
      next if raw.nil?

      validate_deterministic_result(key, result, "deterministic_stop_work", expected_ids) if result

      lines = raw.lines.map(&:rstrip)
      normalized_lines = lines.map { |line| normalize(line) }
      precautions_index = normalized_lines.index("precauciones e inspecciones")
      mandatory_index = normalized_lines.index("detencion obligatoria con evidencia explicita")
      fail_case("stop_work", key, "missing `Precauciones e inspecciones` label") unless precautions_index
      fail_case("stop_work", key, "missing `Detención obligatoria con evidencia explícita` label") unless mandatory_index
      next unless mandatory_index

      section_end = [ precautions_index ].compact.select { |index| index > mandatory_index }.min || lines.size
      section = lines[(mandatory_index + 1)...section_end].join("\n").strip
      items = section.split(/\n[ \t]*\n+/)
      fail_case("stop_work", key, "mandatory section has no delimited items") if items.empty?
      if expected_mandatory.any? && items.size != expected_mandatory.size
        fail_case("stop_work", key, "mandatory items (#{items.size}) != manifest stop-work records (#{expected_mandatory.size})")
      end
      if raw.match?(/\bFR-[0-9A-F]{16}\b/)
        fail_case("stop_work", key, "internal RECORD_IDs are visible to the technician")
      end

      item_pairs = []
      items.each_with_index do |item, index|
        item_lines = item.lines.map(&:strip).reject(&:empty?)
        trigger = item_lines.first&.match(/\ADisparador:\s*(.+)\z/i)&.captures&.first
        action = item_lines.second&.match(/\AAcción obligatoria:\s*(.+)\z/i)&.captures&.first
        item_pairs << [ normalize(trigger), normalize(action) ] if trigger && action
        unless item_lines.size == 2 && trigger.present? && action.present?
          fail_case("stop_work_grammar", key, "invalid mandatory item #{index + 1}")
          next
        end

        normalized_trigger = normalize(trigger)
        normalized_action = normalize(action)
        unless normalized_action.match?(/\bmarc|\bdeten|\bprohib|\bfuera de servicio/)
          fail_case("stop_work", key, "mandatory item #{index + 1} lacks explicit action")
        end
        if normalized_trigger.match?(/\bmareo|\bpersonal no autorizado|\bpersonas no autorizadas|\binterfier/)
          fail_case("stop_work", key, "inspection precaution appears in mandatory stop-work section")
        end
      end

      # Every manifest stop-work record must appear verbatim as a mandatory item.
      Array(@records_manifest.dig("stop_work_cases", "mandatory_records")).each do |record|
        pair = [ normalize(record["stop_trigger"]), normalize(record["stop_action"]) ]
        unless item_pairs.include?(pair)
          fail_case("stop_work", key, "stop-work record #{record['record_id']} is not rendered verbatim")
        end
      end
    end
  end

  def validate_visual_cases
    validate_primary_visual_case

    [ [ "source_isolation", 1 ], [ "source_isolation", 3 ] ].each do |key|
      answer = answer_for(key)
      next if answer.nil?

      inferred_visual_classifications(answer).each do |classification|
        fail_case("visual_isolation", key, "inferred visual classification: #{classification.truncate(180)}")
      end
    end
  end

  def validate_primary_visual_case
    key = [ "visual_fidelity", 1 ]
    raw = answer_for(key)
    return if raw.nil?

    lines = raw.lines.map { |line| normalize(line) }.compact_blank
    PRIMARY_VISUAL_CODES.each do |code|
      code_pattern = /\b#{Regexp.escape(code.downcase)}\b/
      own_line = lines.find do |line|
        mentioned_codes = PRIMARY_VISUAL_CODES.count do |candidate|
          line.match?(/\b#{Regexp.escape(candidate.downcase)}\b/)
        end
        line.match?(code_pattern) && line.include?("data_not_available") && mentioned_codes == 1
      end
      fail_case("visual_primary", key, "#{code} lacks its own DATA_NOT_AVAILABLE marker") unless own_line
    end

    inferred_visual_classifications(raw).each do |classification|
      fail_case("visual_primary", key, "assigned undocumented function/category: #{classification.truncate(180)}")
    end
  end

  def inferred_visual_classifications(text)
    category = /valvul|solenoid|alivio|control|orific|restric|presion|freno|puerto|componente especializado|punto de presion|elemento funcional|funcion de seguridad/
    code = VISUAL_CODES.map(&:downcase).map { |value| Regexp.escape(value) }.join("|")
    normalized_lines = text.lines.map { |line| normalize(line) }.compact_blank
    snippets = normalized_lines.each_cons(2).map { |pair| pair.join(" ") } + normalized_lines

    snippets.filter_map do |snippet|
      normalized = snippet.squish
      next unless normalized.match?(category) && normalized.match?(/\b(?:#{code})\b/)
      # Explicit negations are the OPPOSITE of assigning a function — a snippet
      # that says the legend/function is absent is honest, not an inference.
      next if normalized.include?("data_not_available") &&
        normalized.match?(/sin (?:leyenda|descripcion)|no (?:incluye|contiene|documenta)|funcion.*data_not_available/)
      next if normalized.match?(
        /funcion (?:exacta )?no (?:esta|est[aá]) documentada|sin (?:leyenda|funcion documentada|descripcion funcional)|no (?:incluye|contiene|documenta|proporciona|describe|hay) (?:una )?(?:leyenda|descripcion|documentacion|funcion)|no se documenta/
      )
      # "con puerto(s) [numerados] N" describes printed digit markings next to a
      # symbol — visible text, not a category/function assignment. Strip that
      # phrase; flag only if a category word remains.
      stripped = normalized.gsub(/con puertos? (?:numerad\w+ )?\d[\d, y]*/, " ")
      next unless stripped.match?(category)

      normalized
    end.uniq
  end

  def validate_source_isolation
    corpus = @payload.fetch("corpus", {})
    allowlists = {
      [ "source_isolation", 1 ] => corpus.dig("image", "source_uri"),
      [ "source_isolation", 2 ] => corpus.dig("manual", "source_uri"),
      [ "source_isolation", 3 ] => corpus.dig("image", "source_uri")
    }

    allowlists.each do |key, allowed_uri|
      result = result_for(key)
      next unless result

      allowlist = [ allowed_uri ].compact
      expected = Array(result["expected_entity_s3_uris"]).map(&:to_s).sort
      resolved = Array(result["resolved_scope_s3_uris"]).map(&:to_s).sort
      applied = Array(result["applied_filter_s3_uris"]).map(&:to_s).sort
      observed = Array(result["retrieved_source_uris"]).map(&:to_s).compact_blank.uniq

      fail_case("source_isolation", key, "corpus allowlist URI is missing") if allowed_uri.blank?
      fail_case("source_isolation", key, "expected scope differs from allowlist") unless expected == allowlist
      fail_case("source_isolation", key, "resolved scope differs from allowlist") unless resolved == allowlist
      fail_case("source_isolation", key, "applied filter differs from allowlist") unless applied == allowlist
      fail_case("source_isolation", key, "force_entity_filter must be true") unless result["force_entity_filter"] == true
      fail_case("source_isolation", key, "retrieved_source_uris is empty") if observed.empty?
      unexpected = observed - allowlist
      if unexpected.any?
        fail_case("source_isolation", key, "unexpected source URIs: #{unexpected.join(', ')}")
      end
    end
  end

  def validate_repair_cases
    REPAIR_KEYS.each do |key|
      answer = normalized_answer(key)
      next if answer.nil?

      fail_case("repair", key, "missing mark action") unless answer.match?(/\bmarc(?:ar|a|ada|ado|arla|arlo)/)
      unless answer.match?(/\bdeten|\bprohib|\bfuera de servicio|no (?:operar|usar|utilizar)/)
        fail_case("repair", key, "missing stop/prohibit action")
      end
      unless answer.match?(/tecnic[oa]s? de servicio calificad[oa]s?|personal de servicio calificad[oa]/)
        fail_case("repair", key, "repair authority is not limited to qualified service personnel")
      end
    end
  end

  def answer_for(key)
    result = result_for(key)
    return nil unless result

    result["answer"].to_s
  end

  def normalized_answer(key)
    answer = answer_for(key)
    return nil unless answer

    normalize(answer)
  end

  def normalize(text)
    text.to_s.unicode_normalize(:nfkd)
      .gsub(/\p{Mn}/, "")
      .downcase
      .gsub(/[[:space:]]+/, " ")
      .strip
  end

  def results
    @results ||= Array(@payload["results"]).map(&:deep_stringify_keys)
  end

  def result_for(key)
    results.find { |result| case_key(result) == key }
  end

  def case_key(result)
    [ result["phase"].to_s, result["index"].to_i ]
  end

  def key_string(key)
    "#{key[0]}:#{key[1]}"
  end

  def format_keys(keys)
    keys.map { |phase, index| "#{phase}:#{index}" }.join(", ")
  end

  def fail_rule(rule, message)
    @failures << { rule: rule, message: message }
  end

  def fail_case(rule, key, message)
    @failures << { rule: rule, phase: key[0], index: key[1], message: message }
  end
end

unless ENV["RAG_BENCHMARK_EVALUATOR_LIBRARY_ONLY"] == "1"
  paths = ARGV
  abort "Usage: bin/rails runner script/evaluate_rag_quality_benchmark.rb FILE FILE FILE" if paths.empty?

  evaluation = RagQualityBenchmarkEvaluator.evaluate_files(paths)
  reports = evaluation[:reports]
  output = {
    generated_at: Time.current.utc.iso8601(6),
    passed: reports.all? { |report| report[:passed] } && evaluation.dig(:cohort, :passed),
    cohort: evaluation[:cohort],
    files: reports
  }
  if ENV["RAG_BENCHMARK_EVALUATION_OUTPUT"].present?
    path = ENV["RAG_BENCHMARK_EVALUATION_OUTPUT"]
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(output))
  end
  puts JSON.pretty_generate(output)
  exit(output[:passed] ? 0 : 1)
end
