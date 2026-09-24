# frozen_string_literal: true

require "test_helper"

ENV["RAG_BENCHMARK_EVALUATOR_LIBRARY_ONLY"] = "1"
require Rails.root.join("script/evaluate_rag_quality_benchmark")
ENV.delete("RAG_BENCHMARK_EVALUATOR_LIBRARY_ONLY")

class RagQualityBenchmarkEvaluatorTest < ActiveSupport::TestCase
  test "accepts a complete valid benchmark payload" do
    report = evaluate(valid_payload)

    assert report[:passed], report[:failures].inspect
  end

  test "rejects a missing case and a duplicate case" do
    missing = valid_payload
    missing["results"].pop
    missing["query_count"] = 15
    assert_failure(missing, "matrix")

    duplicate = valid_payload
    duplicate["results"][-1] = duplicate["results"].first.deep_dup
    assert_failure(duplicate, "matrix")
  end

  test "rejects failed and empty results independently" do
    failed = valid_payload
    failed["results"].first["success"] = false
    assert_failure(failed, "execution", "success must be true")

    empty = valid_payload
    empty["results"].first["answer"] = ""
    assert_failure(empty, "execution", "answer must be non-empty")
  end

  test "rejects source scope filter and observed evidence independently" do
    empty = valid_payload
    result_for(empty, "source_isolation", 1)["retrieved_source_uris"] = []
    assert_failure(empty, "source_isolation", "retrieved_source_uris is empty")

    wrong_scope = valid_payload
    result_for(wrong_scope, "source_isolation", 2)["resolved_scope_s3_uris"] =
      [ "s3://benchmark/photo.jpg" ]
    assert_failure(wrong_scope, "source_isolation", "resolved scope differs")

    wrong_filter = valid_payload
    result_for(wrong_filter, "source_isolation", 3)["applied_filter_s3_uris"] =
      [ "s3://benchmark/manual.pdf" ]
    assert_failure(wrong_filter, "source_isolation", "applied filter differs")

    excluded = valid_payload
    result_for(excluded, "source_isolation", 2)["retrieved_source_uris"] =
      [ "s3://benchmark/photo.jpg" ]
    assert_failure(excluded, "source_isolation", "unexpected source URIs")
  end

  # CG-D19: a paragraph is valid only when it follows the renderer's prose
  # template. The old three-line grammar is rejected as a whole.
  test "rejects malformed exhaustive prose" do
    old_grammar = valid_payload
    result_for(old_grammar, "isolated", 5)["answer"] = <<~ANSWER
      Prueba: Bocina del control de plataforma
      Acción: Pulsar el botón de bocina.
      Resultado esperado: Suena la bocina.
    ANSWER
    assert_failure(old_grammar, "exhaustive_grammar")

    missing_result_sentence = valid_payload
    result_for(missing_result_sentence, "isolated", 5)["answer"] =
      exhaustive_answer.sub(" El manual documenta como resultado: La máquina gira en la dirección indicada.", "")
    assert_failure(missing_result_sentence, "exhaustive_grammar")

    title_line = valid_payload
    result_for(title_line, "isolated", 5)["answer"] =
      "Lista completa:\n\n#{exhaustive_answer}"
    assert_failure(title_line, "exhaustive_grammar")
  end

  test "rejects result borrowed from a neighboring exhaustive entry" do
    payload = valid_payload
    payload_answer = exhaustive_answer.sub(
      "Dirección izquierda: Mover el control a la izquierda. El manual documenta como resultado: La máquina gira en la dirección indicada.",
      "Dirección izquierda: Mover el control a la izquierda. El manual documenta como resultado: Sin resultado documentado."
    )
    result_for(payload, "isolated", 5)["answer"] = payload_answer

    assert_failure(payload, "exhaustive", "not rendered verbatim")
  end

  test "a record without a documented result is accepted when the prose says so" do
    payload = valid_payload
    manifest = records_manifest
    manifest["functional_test_cases"]["records"][1]["expected_result"] = "DATA_NOT_AVAILABLE"
    payload_answer = exhaustive_answer.sub(
      "Bocina del control de plataforma: Pulsar el botón de bocina. El manual documenta como resultado: Suena la bocina.",
      "Bocina del control de plataforma: Pulsar el botón de bocina. El manual no documenta el resultado esperado de esta prueba."
    )
    result_for(payload, "isolated", 5)["answer"] = payload_answer
    result_for(payload, "conversation", 5)["answer"] = payload_answer

    report = RagQualityBenchmarkEvaluator.new(payload, source: "test.json", records_manifest: manifest).evaluate

    assert report[:passed], report[:failures].inspect
    assert_not_includes payload_answer, "DATA_NOT_AVAILABLE"
  end

  test "rejects rendered ids that differ from the manifest" do
    payload = valid_payload
    result_for(payload, "isolated", 5)["rendered_record_ids"] = FT_IDS.first(3)

    assert_failure(payload, "deterministic", "rendered ids differ from manifest")
  end

  test "rejects a deterministic case that invoked the model" do
    payload = valid_payload
    result_for(payload, "conversation", 3)["model_invoked"] = true

    assert_failure(payload, "deterministic", "model_invoked must be false")
  end

  test "rejects wrong model invocation accounting" do
    payload = valid_payload
    payload["tracked_query_count"] = 16

    assert_failure(payload, "execution", "tracked_query_count must equal 12")
  end

  test "rejects missing functional unit when its record is not rendered" do
    payload = valid_payload
    result = result_for(payload, "conversation", 5)
    result["rendered_record_ids"] = (FT_IDS - [ FT_IDS[1] ]).sort
    result["answer"] = exhaustive_answer.sub(/Bocina del control de plataforma: .*?Suena la bocina\.\n\n/m, "")

    assert_failure(payload, "exhaustive", "missing functional unit platform-horn")
  end

  test "rejects mandatory item without action and promoted precaution" do
    missing_action = valid_payload
    result_for(missing_action, "isolated", 3)["answer"] = <<~ANSWER
      #{PRECAUTIONS_INTRO}
      Revisar el área.

      #{MANDATORY_INTRO}
      Ante «Mal funcionamiento», el manual dice algo más.
    ANSWER
    assert_failure(missing_action, "stop_work_grammar")

    old_grammar = valid_payload
    result_for(old_grammar, "isolated", 3)["answer"] = <<~ANSWER
      Precauciones e inspecciones
      Revisar el área.

      Detención obligatoria con evidencia explícita
      Disparador: Mal funcionamiento documentado.
      Acción obligatoria: Marcar y detener la máquina.
    ANSWER
    assert_failure(old_grammar, "stop_work", "opening sentence")

    promoted = valid_payload
    result_for(promoted, "conversation", 3)["answer"] = <<~ANSWER
      #{PRECAUTIONS_INTRO}
      Revisar el área.

      #{MANDATORY_INTRO}
      Ante «Personal no autorizado», el manual obliga a lo siguiente: Marcar y detener la máquina.
    ANSWER
    assert_failure(promoted, "stop_work", "inspection precaution")
  end

  test "rejects invented visual classifications and global unavailable marker" do
    inferred = valid_payload
    result_for(inferred, "source_isolation", 3)["answer"] =
      "Válvulas de solenoide: SV1, SV2, SV3 y SV4."
    assert_failure(inferred, "visual_isolation")

    global = valid_payload
    result_for(global, "visual_fidelity", 1)["answer"] =
      "FRRV1, P41, P42, ORF1 y BRK: DATA_NOT_AVAILABLE."
    assert_failure(global, "visual_primary", "lacks its own DATA_NOT_AVAILABLE")
  end

  test "rejects missing qualified repair authority" do
    payload = valid_payload
    result_for(payload, "isolated", 6)["answer"] =
      "Debes marcar la máquina y detener su uso. Cualquier operador puede repararla."

    assert_failure(payload, "repair", "qualified service personnel")
  end

  test "rejects noncanonical mode dirty state and corpus hash mismatch" do
    mode = valid_payload
    mode["benchmark_mode"] = "diagnostic"
    assert_failure(mode, "certification", "benchmark_mode")

    dirty = valid_payload
    dirty["git_dirty"] = true
    assert_failure(dirty, "certification", "git_dirty")

    corpus = valid_payload
    corpus["corpus"]["manual"]["source_sha256"] = "b" * 64
    assert_failure(corpus, "certification", "manual corpus")
  end

  test "cohort rejects mismatched fingerprints and revisions" do
    first = valid_payload
    second = valid_payload
    third = valid_payload
    second["code_fingerprint_sha256"] = "b" * 64
    third["git_revision"] = "different"

    cohort = RagQualityBenchmarkEvaluator.evaluate_cohort(
      [ [ "one.json", first ], [ "two.json", second ], [ "three.json", third ] ]
    )

    assert_not cohort[:passed]
    assert cohort[:failures].any? { |failure| failure[:message].include?("code_fingerprint") }
    assert cohort[:failures].any? { |failure| failure[:message].include?("git_revision") }
  end

  private

  def evaluate(payload)
    RagQualityBenchmarkEvaluator.new(
      payload,
      source: "test.json",
      records_manifest: records_manifest
    ).evaluate
  end

  def assert_failure(payload, rule, message = nil)
    report = evaluate(payload)
    failure = report[:failures].find do |candidate|
      candidate[:rule] == rule && (message.nil? || candidate[:message].include?(message))
    end

    assert_not report[:passed]
    assert failure, report[:failures].inspect
  end

  def valid_payload
    results = RagQualityBenchmarkEvaluator::EXPECTED_KEYS.map do |phase, index|
      allowed_uri = source_uri_for(phase, index)
      {
        "phase" => phase,
        "index" => index,
        "success" => true,
        "answer" => answer_for_case(phase, index),
        "error_type" => nil,
        "error_message" => nil,
        "expected_entity_s3_uris" => allowed_uri ? [ allowed_uri ] : [],
        "resolved_scope_s3_uris" => allowed_uri ? [ allowed_uri ] : [],
        "applied_filter_s3_uris" => allowed_uri ? [ allowed_uri ] : [],
        "force_entity_filter" => true,
        "retrieved_source_uris" => allowed_uri ? [ allowed_uri ] : []
      }.merge(deterministic_fields_for(phase, index))
    end

    {
      "benchmark_version" => RagQualityBenchmarkEvaluator::BENCHMARK_VERSION,
      "benchmark_mode" => "certification",
      "git_revision" => "abc123",
      "git_dirty" => false,
      "code_fingerprint_sha256" => "a" * 64,
      "model_id" => "us.anthropic.claude-haiku-4-5-20251001-v1:0",
      "aws_region" => "us-east-1",
      "knowledge_base_id" => "QGVYLPTEGT",
      "configuration" => { "reranking_enabled" => false },
      "target_case_keys" => RagQualityBenchmarkEvaluator::EXPECTED_KEY_STRINGS,
      "executed_case_keys" => RagQualityBenchmarkEvaluator::EXPECTED_KEY_STRINGS,
      "expected_call_count" => 16,
      "query_count" => 16,
      "tracked_query_count" => 12,
      "deterministic_query_count" => 4,
      "model_invocation_count" => 12,
      "run_error" => nil,
      "corpus" => {
        "manual" => {
          "source_uri" => "s3://benchmark/manual.pdf",
          "source_sha256" => "1" * 64,
          "expected_source_sha256" => "1" * 64
        },
        "image" => {
          "source_uri" => "s3://benchmark/photo.jpg",
          "source_sha256" => "2" * 64,
          "expected_source_sha256" => "2" * 64
        }
      },
      "results" => results
    }
  end

  FT_IDS = %w[FR-AAAAAAAAAAAAAAA1 FR-AAAAAAAAAAAAAAA2 FR-AAAAAAAAAAAAAAA3 FR-AAAAAAAAAAAAAAA4].freeze
  PRECAUTIONS_INTRO = I18n.t("rag.deterministic.precautions_intro", locale: :es)
  MANDATORY_INTRO = I18n.t("rag.deterministic.mandatory_intro", locale: :es)
  SW_MANDATORY_IDS = %w[FR-BBBBBBBBBBBBBBB1].freeze
  SW_ALL_IDS = (SW_MANDATORY_IDS + %w[FR-BBBBBBBBBBBBBBB2]).freeze

  def records_manifest
    {
      "version" => "test-manifest",
      "functional_test_cases" => {
        "case_keys" => [ "isolated:5", "conversation:5" ],
        "expected_record_ids" => FT_IDS.sort,
        "records" => [
          { "record_id" => FT_IDS[0], "action" => "Empujar el botón de parada de emergencia.",
            "expected_result" => "No se ejecuta ninguna función." },
          { "record_id" => FT_IDS[1], "action" => "Pulsar el botón de bocina.",
            "expected_result" => "Suena la bocina." },
          { "record_id" => FT_IDS[2], "action" => "Mover el control a la izquierda.",
            "expected_result" => "La máquina gira en la dirección indicada." },
          { "record_id" => FT_IDS[3], "action" => "Mover el control a la derecha.",
            "expected_result" => "La máquina gira en la dirección indicada." }
        ]
      },
      "stop_work_cases" => {
        "case_keys" => [ "isolated:3", "conversation:3" ],
        "expected_record_ids" => SW_ALL_IDS.sort,
        "expected_mandatory_record_ids" => SW_MANDATORY_IDS,
        "mandatory_records" => [
          { "record_id" => SW_MANDATORY_IDS[0],
            "stop_trigger" => "Mal funcionamiento documentado.",
            "stop_action" => "Marcar y detener la máquina." }
        ],
        "precaution_sentinels" => { "dizziness-stays-precaution" => [ "FR-BBBBBBBBBBBBBBB2" ] }
      },
      "functional_units" => {
        "ground-emergency-stop" => { "record_ids" => [ FT_IDS[0] ] },
        "platform-horn" => { "record_ids" => [ FT_IDS[1] ] },
        "steering-left" => { "record_ids" => [ FT_IDS[2] ] },
        "steering-right" => { "record_ids" => [ FT_IDS[3] ] }
      }
    }
  end

  def deterministic_fields_for(phase, index)
    return {} unless %w[isolated conversation].include?(phase)

    if index == 5
      { "generation_mode" => "deterministic_functional_tests", "model_invoked" => false,
        "deterministic_validation" => "ok",
        "rendered_record_ids" => FT_IDS.sort, "parsed_record_ids" => FT_IDS.sort }
    elsif index == 3
      { "generation_mode" => "deterministic_stop_work", "model_invoked" => false,
        "deterministic_validation" => "ok",
        "rendered_record_ids" => SW_ALL_IDS.sort, "parsed_record_ids" => SW_ALL_IDS.sort }
    else
      { "generation_mode" => "bedrock_retrieve_and_generate", "model_invoked" => true }
    end
  end

  def answer_for_case(phase, index)
    return exhaustive_answer if index == 5 && %w[isolated conversation].include?(phase)
    return stop_work_answer if index == 3 && %w[isolated conversation].include?(phase)
    return repair_answer if index == 6 && %w[isolated conversation].include?(phase)
    return visual_answer if phase == "visual_fidelity"
    return source_visual_answer if phase == "source_isolation" && [ 1, 3 ].include?(index)

    "Respuesta documentada."
  end

  def source_uri_for(phase, index)
    return unless phase == "source_isolation"
    return "s3://benchmark/manual.pdf" if index == 2

    "s3://benchmark/photo.jpg"
  end

  # Same prose the deterministic renderers emit (rag.deterministic.*, CG-D19).
  def exhaustive_answer
    <<~ANSWER
      Parada de emergencia del control de tierra: Empujar el botón de parada de emergencia. El manual documenta como resultado: No se ejecuta ninguna función.

      Bocina del control de plataforma: Pulsar el botón de bocina. El manual documenta como resultado: Suena la bocina.

      Dirección izquierda: Mover el control a la izquierda. El manual documenta como resultado: La máquina gira en la dirección indicada.

      Dirección derecha: Mover el control a la derecha. El manual documenta como resultado: La máquina gira en la dirección indicada.
    ANSWER
  end

  def stop_work_answer
    <<~ANSWER
      #{PRECAUTIONS_INTRO}
      Verifica mareos, personal no autorizado e interferencias antes de operar.

      #{MANDATORY_INTRO}
      Ante «Mal funcionamiento documentado.», el manual obliga a lo siguiente: Marcar y detener la máquina.
    ANSWER
  end

  def repair_answer
    "Si falla, debes marcar la máquina y detener o prohibir su uso. Solo técnicos de servicio calificados pueden repararla."
  end

  def source_visual_answer
    <<~ANSWER
      SV1: identificador visible; categoría y función: DATA_NOT_AVAILABLE.
      RV1: identificador visible; categoría y función: DATA_NOT_AVAILABLE.
      CV1: identificador visible; categoría y función: DATA_NOT_AVAILABLE.
      ORF1: identificador visible; categoría y función: DATA_NOT_AVAILABLE.
      FRRV1: identificador visible; categoría y función: DATA_NOT_AVAILABLE.
      BRK: identificador visible; categoría y función: DATA_NOT_AVAILABLE.
      P41: identificador visible; categoría y función: DATA_NOT_AVAILABLE.
      P42: identificador visible; categoría y función: DATA_NOT_AVAILABLE.
      Hoisting Cylinder y Platform Overload son texto visible.
    ANSWER
  end

  def visual_answer
    <<~ANSWER
      FRRV1: identificador visible; función: DATA_NOT_AVAILABLE.
      P41: identificador visible; función: DATA_NOT_AVAILABLE.
      P42: identificador visible; función: DATA_NOT_AVAILABLE.
      ORF1: identificador visible; función: DATA_NOT_AVAILABLE.
      BRK: identificador visible; función: DATA_NOT_AVAILABLE.
    ANSWER
  end

  def result_for(payload, phase, index)
    payload["results"].find { |result| result["phase"] == phase && result["index"] == index }
  end
end
