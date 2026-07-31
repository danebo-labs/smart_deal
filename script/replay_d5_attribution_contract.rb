# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"

class D5AttributionContractReplay
  SOURCE_DIR = Rails.root.join("tmp/d5_abstention_contract")
  OUTPUT_DIR = Rails.root.join("tmp/replay_attribution")
  REPORT_PATH = OUTPUT_DIR.join("replay_report.json")
  EXPECTED_SHA256 = {
    "d5_rag_seguridades_rubric_run1.json" =>
      "a408b5df2d2ecbc586b0fca3d0815ec74a0a7b493f44d44687c534adef8f0ffd",
    "d5_rag_seguridades_pilot_10q_run1.json" =>
      "6fc848f79ec6e79b8c4ab4a02cd1473e98a0889e33710dade7af6a34a0e1929d",
    "d5_rag_seguridades_pilot_10q_v2_run1.json" =>
      "4d621519c38142d5c4d1689b687e7ad347a3754a1050249daf29958cccacae07"
  }.freeze
  RUBRIC_PATHS = {
    "seguridades-v3.2" => Rails.root.join("script/fixtures/rag_seguridades_rubric.json"),
    "seguridades-pilot-v1.2" =>
      Rails.root.join("script/fixtures/rag_seguridades_pilot_10q.json"),
    "seguridades-pilot-v2.1" =>
      Rails.root.join("script/fixtures/rag_seguridades_pilot_10q_v2.json")
  }.freeze
  EXPECTED_CHANGED_IDS = %w[thyssen_e_led edel_k3_leds].freeze
  STRUCTURED_MODE = Rag::StructuredEvidenceRoute::GENERATION_MODE

  AccountIdentity = Data.define(:id)

  class FakeRagService
    attr_reader :calls

    def initialize(chunks, retrieval_trace)
      @chunks = chunks
      @retrieval_trace = retrieval_trace
      @calls = []
    end

    def retrieve_chunks(question, **kwargs)
      @calls << { question: question, **kwargs }
      { chunks: @chunks, retrieval_trace: @retrieval_trace }
    end
  end

  class FakeGenerator
    def initialize(answer)
      @answer = answer
    end

    def query(*)
      @answer
    end
  end

  class FakeExpander
    def neighbor_chunk(**)
      nil
    end
  end

  def initialize(locale: :es)
    @locale = locale
    @processor = Rag::AnswerSafetyProcessor.new(locale:)
    @citation_processor = Bedrock::CitationProcessor.new
  end

  def call
    integrity = verify_source_integrity!
    FileUtils.mkdir_p(OUTPUT_DIR)

    rows = []
    artifact_reports = EXPECTED_SHA256.keys.map do |filename|
      payload = JSON.parse(SOURCE_DIR.join(filename).read)
      transformed = payload.deep_dup
      artifact_rows = transformed.fetch("results").map do |result|
        transform_result(result, filename:)
      end
      rows.concat(artifact_rows)

      rubric = load_rubric(payload.fetch("rubric_version"))
      evaluation = Rag::BenchmarkRubricEvaluator.new(
        rubric: rubric,
        payload: transformed
      ).evaluate
      transformed["evaluation"] = evaluation
      attach_evaluation!(artifact_rows, payload["evaluation"], evaluation)

      output_path = OUTPUT_DIR.join(filename)
      File.write(output_path, JSON.pretty_generate(transformed))
      {
        "filename" => filename,
        "rubric_version" => payload.fetch("rubric_version"),
        "results" => artifact_rows.size,
        "output_path" => output_path.to_s,
        "evaluation_passed" => evaluation.fetch("passed"),
        "evaluation_summary" => evaluation.fetch("summary")
      }
    end

    changed = rows.select { |row| row.fetch("changed") }.pluck("id")
    changed_ids = EXPECTED_CHANGED_IDS.select { |id| changed.include?(id) } +
      (changed - EXPECTED_CHANGED_IDS).sort
    report = {
      "source_integrity" => integrity,
      "artifacts" => artifact_reports,
      "fidelity_matches" => rows.count { |row| row.fetch("fidelity_matched") },
      "fidelity_total" => rows.size,
      "flag_off_matches" => rows.count { |row| row.fetch("flag_off_matched") },
      "changed_ids" => changed_ids,
      "unchanged_results" => rows.count { |row| !row.fetch("changed") },
      "structured_turns" => rows.count { |row| row.fetch("generation_mode") == STRUCTURED_MODE },
      "new_citation_failures" => rows.filter_map do |row|
        row.fetch("id") if row.fetch("citations_before").positive? &&
          row.fetch("citations_after").zero?
      end,
      "regressions" => rows.count { |row| row["before_passed"] && !row["after_passed"] },
      "rows" => rows
    }
    validate_report!(report)
    File.write(REPORT_PATH, JSON.pretty_generate(report))
    report
  end

  private

  def verify_source_integrity!
    EXPECTED_SHA256.map do |filename, expected|
      path = SOURCE_DIR.join(filename)
      raise ArgumentError, "Missing paid artifact: #{path}" unless path.file?

      actual = Digest::SHA256.file(path).hexdigest
      raise ArgumentError, "SHA-256 mismatch for #{filename}: #{actual}" unless actual == expected

      { "filename" => filename, "sha256" => actual, "matched" => true }
    end
  end

  def transform_result(result, filename:)
    archived_answer = result.fetch("answer")
    citations_before = Array(result["citations"])
    rendered_baseline = render_internal_answer(result)
    terminal_replay = nil
    fidelity_strategy = "answer_safety"
    if rendered_baseline != archived_answer && structured?(result)
      terminal_replay = replay_structured(result, flag_enabled: false)
      rendered_baseline = terminal_replay.fetch(:result).fetch(:answer)
      fidelity_strategy = "structured_terminal_gate"
    end

    transformed =
      if structured_replay_required?(result)
        replay = replay_structured(result, flag_enabled: true)
        {
          answer: replay.fetch(:result).fetch(:answer),
          citations: replay.fetch(:result).fetch(:citations),
          attribution: nil,
          replay: replay
        }
      else
        attribution = with_contract_flag("true") do
          Rag::CitationAttributionGuard.new(
            question: result.fetch("question"),
            citations: citations_before
          ).call(archived_answer)
        end
        {
          answer: attribution.answer,
          citations: attribution.dropped_any? ?
            rebuilt_citations(citations_before, attribution.answer, result.fetch("question")) :
            citations_before,
          attribution: attribution,
          replay: nil
        }
      end

    result["answer"] = transformed.fetch(:answer)
    result["citations"] = transformed.fetch(:citations)
    off_answer = terminal_replay&.fetch(:result)&.fetch(:answer) || archived_answer
    replay = transformed.fetch(:replay)
    attribution = transformed.fetch(:attribution)

    {
      "artifact" => filename,
      "id" => result.fetch("id"),
      "generation_mode" => result["generation_mode"],
      "fidelity_strategy" => fidelity_strategy,
      "fidelity_matched" => rendered_baseline == archived_answer,
      "flag_off_matched" => off_answer == archived_answer,
      "changed" => result.fetch("answer") != archived_answer,
      "answer_sha256" => {
        "before" => Digest::SHA256.hexdigest(archived_answer),
        "fidelity" => Digest::SHA256.hexdigest(rendered_baseline),
        "flag_off" => Digest::SHA256.hexdigest(off_answer),
        "after" => Digest::SHA256.hexdigest(result.fetch("answer"))
      },
      "citations_before" => citations_before.size,
      "citations_after" => Array(result["citations"]).size,
      "dropped_segments" => Array(attribution&.dropped_segments),
      "outcome_status" => replay&.fetch(:outcome_status, nil),
      "outcome_reason" => replay&.dig(:result, :diagnostics, :outcome_reason),
      "retrieve_invocations" => replay&.fetch(:retrieve_invocations, nil),
      "generation_chunks" =>
        replay&.dig(:result, :retrieval_trace, :structured_route, :generation_chunks),
      "expansion_count" =>
        replay&.dig(:result, :retrieval_trace, :structured_route, :expansion_count)
    }
  end

  def render_internal_answer(result)
    internal_answer = result["internal_answer"]
    return result.fetch("answer") if internal_answer.nil?

    @processor.call(
      internal_answer,
      evidence: result.fetch("chunks", []),
      require_cited_evidence: true
    )
  end

  def structured?(result)
    result["generation_mode"] == STRUCTURED_MODE
  end

  def structured_replay_required?(result)
    return false unless structured?(result)

    chunk_count = result.dig("retrieval_trace", "structured_route", "generation_chunks").to_i
    markers = result.fetch("raw_answer", "").scan(/\[(\d+)\]/).flatten.map(&:to_i)
    chunk_count.positive? && markers.any? { |number| !number.between?(1, chunk_count) }
  end

  def replay_structured(result, flag_enabled:)
    chunks = result.fetch("chunks").map(&:deep_symbolize_keys)
    retrieval_trace = result.fetch("retrieval_trace", {}).deep_symbolize_keys
    rag_service = FakeRagService.new(chunks, retrieval_trace)
    source_uris = Array(retrieval_trace[:resolved_scope_s3_uris])
    account_id = chunks.filter_map { |chunk| chunk.dig(:metadata, :account_id) }.first.to_i
    account_id = 1 unless account_id.positive?
    route = Rag::StructuredEvidenceRoute.new(
      question: result.fetch("question"),
      account: AccountIdentity.new(id: account_id),
      entity_s3_uris: source_uris,
      entity_sources: [ "document" ],
      force_entity_filter: true,
      response_locale: @locale,
      account_id: account_id,
      correlation_id: "replay:#{result.fetch('id')}",
      rag_service: rag_service,
      generator: FakeGenerator.new(result.fetch("raw_answer")),
      expander: FakeExpander.new
    )

    outcome = with_contract_flag(flag_enabled ? "true" : "false") do
      with_partial_contract_flag("true") { route.execute }
    end
    {
      outcome_status: outcome.status,
      result: outcome.result,
      retrieve_invocations: rag_service.calls.size
    }
  end

  def rebuilt_citations(citations, answer, question)
    shaped = Array(citations).map(&:deep_symbolize_keys)
    @citation_processor.build_numbered_references(shaped, answer, question:)
  end

  def load_rubric(version)
    path = RUBRIC_PATHS.fetch(version) do
      raise ArgumentError, "No rubric fixture for #{version.inspect}"
    end
    JSON.parse(path.read)
  end

  def attach_evaluation!(rows, before_evaluation, after_evaluation)
    before = Array(before_evaluation&.fetch("cases", nil)).index_by { |item| item.fetch("id") }
    after = after_evaluation.fetch("cases").index_by { |item| item.fetch("id") }
    rows.each do |row|
      row["before_passed"] = before.dig(row.fetch("id"), "passed")
      row["after_passed"] = after.dig(row.fetch("id"), "passed")
      row["after_score"] = after.dig(row.fetch("id"), "score")
      row["after_max_score"] = after.dig(row.fetch("id"), "max_score")
    end
  end

  def validate_report!(report)
    failures = []
    failures << "fidelity #{report['fidelity_matches']}/#{report['fidelity_total']}" unless
      report["fidelity_matches"] == report["fidelity_total"]
    failures << "flag off #{report['flag_off_matches']}/#{report['fidelity_total']}" unless
      report["flag_off_matches"] == report["fidelity_total"]
    failures << "changed_ids=#{report['changed_ids'].inspect}" unless
      report["changed_ids"] == EXPECTED_CHANGED_IDS
    failures << "new citation failures=#{report['new_citation_failures'].inspect}" unless
      report["new_citation_failures"].empty?
    failures << "regressions=#{report['regressions']}" unless report["regressions"].zero?
    raise ArgumentError, "Replay gate failed: #{failures.join('; ')}" if failures.any?
  end

  def with_contract_flag(value)
    with_env("RAG_CITATION_ATTRIBUTION_CONTRACT_ENABLED", value) { yield }
  end

  def with_partial_contract_flag(value)
    with_env("RAG_PARTIAL_ABSTENTION_CONTRACT_ENABLED", value) { yield }
  end

  def with_env(key, value)
    previous = ENV.fetch(key, nil)
    ENV[key] = value
    yield
  ensure
    previous.nil? ? ENV.delete(key) : ENV[key] = previous
  end
end

report = D5AttributionContractReplay.new.call
puts JSON.pretty_generate(
  report.slice(
    "fidelity_matches",
    "fidelity_total",
    "flag_off_matches",
    "changed_ids",
    "unchanged_results",
    "new_citation_failures",
    "regressions"
  )
)
