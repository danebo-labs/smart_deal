# frozen_string_literal: true

require "aws-sdk-s3"
require "digest"
require "fileutils"
require "json"
require "open3"

class RagQualityBenchmark
  include AwsClientInitializer

  BENCHMARK_VERSION = "2026-06-11-v3"
  CORPUS_MANIFEST_PATH = "script/fixtures/rag_quality_benchmark_corpus.json"
  RUBRIC_MANIFEST_PATH = "script/fixtures/rag_quality_benchmark_atomic_rubric.json"
  FIELD_RECORDS_MANIFEST_PATH = "script/fixtures/rag_quality_benchmark_field_records.json"
  # Cases answered without any model invocation (deterministic renderers).
  DETERMINISTIC_CASE_KEYS = %w[isolated:3 isolated:5 conversation:3 conversation:5].freeze
  EXPECTED_MODEL_INVOCATION_COUNT = 12
  MODES = %w[retrieval_preflight diagnostic certification].freeze
  CANONICAL = {
    model_id: "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    aws_region: "us-east-1",
    knowledge_base_id: "QGVYLPTEGT",
    session_identifier: "mvp-shared",
    session_channel: "shared",
    manual_key: "uploads/2026-06-10/manual_plataforma_tijera_24_paginas.pdf",
    image_key: "uploads/2026-06-10/pagina_16_esquema_hidraulico.png"
  }.freeze
  FINGERPRINT_PATHS = %w[
    app/controllers/concerns/rag_query_concern.rb
    app/models/conversation_session.rb
    app/models/kb_document.rb
    app/prompts/bedrock/generation.txt
    app/services/bedrock/citation_processor.rb
    app/services/bedrock_client.rb
    app/services/bedrock_rag_service.rb
    app/services/query_orchestrator_service.rb
    app/prompts/batch_chunking_prompt.rb
    app/prompts/field_photo_prompt.rb
    app/services/batch_results_parser_service.rb
    app/services/rag/deterministic_intent.rb
    app/services/rag/deterministic_renderer.rb
    app/services/rag/field_record_parser.rb
    app/services/rag/functional_test_renderer.rb
    app/services/rag/pinned_entity_scope_resolver.rb
    app/services/rag/stop_work_renderer.rb
    app/services/rag_retrieval_profile.rb
    app/services/session_context_builder.rb
    script/evaluate_rag_quality_benchmark.rb
    script/fixtures/rag_quality_benchmark_atomic_rubric.json
    script/fixtures/rag_quality_benchmark_corpus.json
    script/fixtures/rag_quality_benchmark_field_records.json
    script/rag_quality_benchmark.rb
  ].freeze

  ISOLATED_QUERIES = [
    "Usando únicamente el manual de la plataforma tijera, explica cuál es su propósito y cuáles son sus componentes principales. No utilices el esquema hidráulico.",
    "Estoy frente a esta plataforma tijera. ¿Cuáles son sus partes principales, qué función cumple cada una y desde dónde puede operarlas el técnico?",
    "Antes de operar este equipo, ¿qué comprobaciones debo realizar y en qué condiciones debo detener el trabajo?",
    "¿Qué condiciones del lugar de trabajo debo inspeccionar antes de mover y operar esta plataforma?",
    "¿Qué pruebas funcionales previas al uso indica el manual y qué resultado esperado tiene cada una?",
    "Si alguna prueba funcional falla, ¿qué acciones indica expresamente el manual y quién puede reparar la máquina?"
  ].freeze
  CONVERSATION_QUERIES = [
    "¿Cuál es el propósito de este equipo y cuáles son sus cinco partes principales?",
    "De esas partes, ¿qué función cumplen los controles de tierra y los controles de plataforma?",
    "Antes de operarlo, ¿qué comprobaciones debo realizar y cuándo debo detener el trabajo?",
    "¿Y qué debo revisar en el lugar donde voy a utilizarlo?",
    "Después de esas inspecciones, ¿qué pruebas funcionales debo ejecutar y qué resultados debo obtener?",
    "Si alguna de esas pruebas falla, ¿qué debo hacer y quién está autorizado para repararlo?"
  ].freeze
  SOURCE_QUERIES = [
    "¿Qué componentes y etiquetas identifica la documentación disponible en este esquema hidráulico-electrohidráulico? No inventes valores ni procedimientos.",
    "Según el manual de la plataforma elevadora, ¿qué inspección estructural debo realizar antes de operar? No uses el esquema hidráulico.",
    "Según el esquema hidráulico-electrohidráulico, ¿qué componentes identificables aparecen? No uses el manual de la plataforma."
  ].freeze
  VISUAL_QUERY = "En el esquema aparecen FRRV1, P41, P42, ORF1 y BRK. Indica su función exacta únicamente si está documentada; si no, dilo explícitamente."

  EXPECTED_CASE_KEYS = (
    (1..6).map { |index| "isolated:#{index}" } +
    (1..6).map { |index| "conversation:#{index}" } +
    (1..3).map { |index| "source_isolation:#{index}" } +
    [ "visual_fidelity:1" ]
  ).freeze
  RETRIEVAL_PREFLIGHT_KEYS = %w[isolated:3 isolated:5 conversation:3 conversation:5].freeze

  class PreflightError < StandardError; end

  def initialize(env: ENV, aws_identity_loader: nil, s3_client: nil, canonical: CANONICAL)
    @env = env
    @aws_identity_loader = aws_identity_loader || method(:load_aws_identity)
    @s3_client = s3_client
    @canonical = canonical.deep_symbolize_keys
    @results = []
  end

  def run!
    ActiveJob::Base.queue_adapter = :inline
    load_records
    @benchmark_mode = resolve_benchmark_mode
    @target_case_keys = resolve_target_case_keys
    @executed_case_keys = resolve_executed_case_keys
    @preflight = preflight!

    if truthy?("RAG_BENCHMARK_PREFLIGHT_ONLY")
      puts JSON.pretty_generate(
        benchmark_version: BENCHMARK_VERSION,
        benchmark_mode: @benchmark_mode,
        preflight: @preflight
      )
      return @preflight
    end

    @original_state = {
      active_entities: @session.active_entities.deep_dup,
      conversation_history: @session.conversation_history.deep_dup
    }
    @start_query_id = BedrockQuery.maximum(:id).to_i
    @started_at = Time.current
    run_error = nil

    begin
      prepare_session
      @benchmark_mode == "retrieval_preflight" ? run_retrieval_preflight : run_matrix
    rescue StandardError => e
      run_error = e
    ensure
      restore_session
      write_payload(run_error)
    end

    raise run_error if run_error

    puts JSON.pretty_generate(summary_payload.merge(output_path: @output_path))
  end

  def preflight!
    errors = []
    errors << "BEDROCK_RERANKER_ENABLED must be false" if reranking_enabled?
    errors << "QUERY_ROUTING_ENABLED must be false" if query_routing_enabled?
    errors << "Bedrock query model is missing" if BedrockClient::QUERY_MODEL_ID.blank?
    errors << "Knowledge Base ID is missing" if knowledge_base_id.blank?

    manual_uri = @manual.display_s3_uri(KbDocument::KB_BUCKET)
    image_uri = @image.display_s3_uri(KbDocument::KB_BUCKET)
    errors << "Manual source URI is missing" if manual_uri.blank?
    errors << "Image source URI is missing" if image_uri.blank?
    errors << "Benchmark sources resolve to the same URI" if manual_uri.present? && manual_uri == image_uri

    validate_canonical_configuration(errors)
    identity = @aws_identity_loader.call
    errors << "AWS caller identity is unavailable" if identity.blank?

    corpus = build_corpus(manual_uri, image_uri, errors)
    code = code_fingerprint
    if @benchmark_mode == "certification" && code[:git_dirty]
      errors << "Certification requires git_dirty=false"
    end

    raise PreflightError, errors.join("; ") if errors.any?

    {
      aws_identity: identity,
      reranking_enabled: false,
      query_routing_enabled: false,
      model_id: BedrockClient::QUERY_MODEL_ID,
      aws_region: aws_region,
      knowledge_base_id: knowledge_base_id,
      session_identifier: @session.identifier,
      session_channel: @session.channel,
      corpus: corpus,
      retrieval: effective_retrieval_configuration,
      code: code
    }
  end

  def self.retrieved_source_uris(retrieved_citations)
    Array(retrieved_citations).filter_map do |citation|
      metadata = (citation[:metadata] || citation["metadata"] || {}).to_h
      location = (citation[:location] || citation["location"] || {}).to_h

      metadata["original_source_uri"] ||
        metadata[:original_source_uri] ||
        metadata["x-amz-bedrock-kb-source-uri"] ||
        metadata[:"x-amz-bedrock-kb-source-uri"] ||
        location[:uri] ||
        location["uri"]
    end.map { |uri| uri.to_s.strip }.reject(&:empty?).uniq.sort
  end

  private

  def load_records
    @output_path = @env.fetch(
      "RAG_BENCHMARK_OUTPUT",
      Rails.root.join("tmp/rag_quality_benchmark.json").to_s
    )
    @session = ConversationSession.find_by!(
      identifier: @env.fetch("RAG_BENCHMARK_SESSION", @canonical[:session_identifier]),
      channel: @env.fetch("RAG_BENCHMARK_CHANNEL", @canonical[:session_channel])
    )
    @manual = KbDocument.find_by!(
      s3_key: @env.fetch("RAG_BENCHMARK_MANUAL_KEY", @canonical[:manual_key])
    )
    @image = KbDocument.find_by!(
      s3_key: @env.fetch("RAG_BENCHMARK_IMAGE_KEY", @canonical[:image_key])
    )
  end

  def resolve_benchmark_mode
    explicit = @env["RAG_BENCHMARK_MODE"].to_s.presence
    mode = explicit || (@env["RAG_BENCHMARK_TARGETS"].present? ? "diagnostic" : "certification")
    raise PreflightError, "Unknown RAG_BENCHMARK_MODE=#{mode}" unless MODES.include?(mode)

    mode
  end

  def resolve_target_case_keys
    return RETRIEVAL_PREFLIGHT_KEYS if @benchmark_mode == "retrieval_preflight"
    return EXPECTED_CASE_KEYS if @benchmark_mode == "certification"

    raw = @env["RAG_BENCHMARK_TARGETS"].to_s
    keys = raw.split(",").map(&:strip).reject(&:empty?)
    raise PreflightError, "Diagnostic mode requires RAG_BENCHMARK_TARGETS" if keys.empty?

    duplicates = keys.tally.select { |_key, count| count > 1 }.keys
    unknown = keys - EXPECTED_CASE_KEYS
    raise PreflightError, "Duplicate benchmark targets: #{duplicates.join(', ')}" if duplicates.any?
    raise PreflightError, "Unknown benchmark targets: #{unknown.join(', ')}" if unknown.any?

    keys
  end

  def resolve_executed_case_keys
    return RETRIEVAL_PREFLIGHT_KEYS if @benchmark_mode == "retrieval_preflight"

    expanded = @target_case_keys.flat_map do |key|
      phase, index = key.split(":")
      if phase == "conversation"
        (1..index.to_i).map { |dependency| "conversation:#{dependency}" }
      else
        [ key ]
      end
    end.uniq

    EXPECTED_CASE_KEYS.select { |key| expanded.include?(key) }
  end

  def prepare_session
    @session.update!(active_entities: {}, conversation_history: [])
    raise PreflightError, "Could not pin benchmark manual" unless @session.pin_kb_document!(@manual)
    raise PreflightError, "Could not pin benchmark image" unless @session.pin_kb_document!(@image)
  end

  def run_matrix
    conversation_started = false
    @executed_case_keys.each do |key|
      phase, index = key.split(":")
      index = index.to_i

      if phase == "conversation" && !conversation_started
        @session.update!(conversation_history: [])
        conversation_started = true
      end

      run_query(phase, index, question_for(phase, index), phase == "conversation")
    end
  end

  def run_query(phase, index, question, conversational)
    @session.reload
    @session.update!(conversation_history: []) unless conversational
    @session.add_to_history_and_refresh("user", question)
    @session.reload

    entity_uris = scoped_entity_uris(question)
    profile = retrieval_profile(question, entity_uris)
    began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = executor.send(
      :execute_rag_query,
      question,
      session_context: SessionContextBuilder.build(@session),
      conv_session: @session,
      entity_s3_uris: SessionContextBuilder.entity_s3_uris(@session),
      output_channel: :web
    )
    elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - began) * 1000).round
    @session.add_to_history("assistant", result.answer.to_s) if conversational && result.success?
    trace = result.retrieval_trace.to_h.deep_symbolize_keys
    key = "#{phase}:#{index}"

    @results << {
      phase: phase,
      index: index,
      target: @target_case_keys.include?(key),
      preparation_only: @target_case_keys.exclude?(key),
      question: question,
      success: result.success?,
      answer: result.answer,
      citations: result.citations,
      doc_refs: result.doc_refs,
      retrieved_source_uris: self.class.retrieved_source_uris(result.retrieved_citations),
      expected_entity_s3_uris: entity_uris.sort,
      resolved_scope_s3_uris: trace[:resolved_scope_s3_uris],
      applied_filter_s3_uris: trace[:applied_filter_s3_uris],
      force_entity_filter: trace[:force_entity_filter],
      vector_search_configuration_sha256: trace[:vector_search_configuration_sha256],
      vector_search_configuration: trace[:vector_search_configuration],
      requested_result_count: profile.number_of_results,
      exhaustive_query: profile.exhaustive_query?,
      safety_critical_query: profile.safety_critical_query?,
      generation_mode: result.generation_mode || "bedrock_retrieve_and_generate",
      model_invoked: result.model_invoked.nil? ? true : result.model_invoked,
      parsed_record_ids: result.parsed_record_ids,
      rendered_record_ids: result.rendered_record_ids,
      record_counts_by_type: result.record_counts_by_type,
      record_ledger_sha256: result.record_ledger_sha256,
      retrieved_chunk_sha256s: result.retrieved_chunk_sha256s,
      deterministic_validation: result.deterministic_validation,
      elapsed_ms: elapsed_ms,
      error_type: result.error_type,
      error_message: result.error_message
    }
  end

  # Fase 5 — preflight de los cuatro casos deterministas: misma recuperacion
  # full-scope que usan los renderers, parseo FIELD_RECORD y comparacion exacta
  # contra el manifest de evidencia. Sin generacion.
  def run_retrieval_preflight
    manifest = load_json_manifest(FIELD_RECORDS_MANIFEST_PATH) || {}

    @results = RETRIEVAL_PREFLIGHT_KEYS.map do |key|
      phase, index = key.split(":")
      question = question_for(phase, index.to_i)
      entity_uris = scoped_entity_uris(question)
      result = retrieval_service.retrieve_chunks(
        question,
        entity_s3_uris: entity_uris,
        entity_sources: entity_sources_for(entity_uris),
        force_entity_filter: true,
        number_of_results: Rag::DeterministicRenderer::FULL_SCOPE_CANDIDATES
      )

      ledger = Rag::FieldRecordParser.parse_chunks(result[:chunks])
      expected_ids =
        if index.to_i == 5
          Array(manifest.dig("functional_test_cases", "expected_record_ids"))
        else
          Array(manifest.dig("stop_work_cases", "expected_record_ids"))
        end
      retrieved_ids = ledger.record_ids.sort
      missing = expected_ids - retrieved_ids

      {
        phase: phase,
        index: index.to_i,
        question: question,
        resolved_scope_s3_uris: result.dig(:retrieval_trace, :resolved_scope_s3_uris),
        applied_filter_s3_uris: result.dig(:retrieval_trace, :applied_filter_s3_uris),
        force_entity_filter: result.dig(:retrieval_trace, :force_entity_filter),
        vector_search_configuration: result.dig(:retrieval_trace, :vector_search_configuration),
        vector_search_configuration_sha256: result.dig(
          :retrieval_trace,
          :vector_search_configuration_sha256
        ),
        ledger_valid: ledger.valid?,
        parsed_record_ids: retrieved_ids,
        expected_record_ids: expected_ids,
        missing_expected_record_ids: missing,
        record_coverage_complete: missing.empty? && expected_ids.any?,
        chunks: result[:chunks]
      }
    end

    incomplete = @results.reject { |r| r[:record_coverage_complete] && r[:ledger_valid] }
    if incomplete.any?
      keys = incomplete.map { |r| "#{r[:phase]}:#{r[:index]}" }.join(", ")
      raise PreflightError, "Retrieval preflight incomplete for #{keys} — see payload"
    end
  end

  def question_for(phase, index)
    case phase
    when "isolated" then ISOLATED_QUERIES.fetch(index - 1)
    when "conversation" then CONVERSATION_QUERIES.fetch(index - 1)
    when "source_isolation" then SOURCE_QUERIES.fetch(index - 1)
    when "visual_fidelity" then VISUAL_QUERY
    else raise PreflightError, "Unknown benchmark phase #{phase}"
    end
  end

  def executor
    @executor ||= Class.new do
      include RagQueryConcern
    end.new
  end

  def retrieval_service
    @retrieval_service ||= BedrockRagService.new(knowledge_base_id: knowledge_base_id)
  end

  def scoped_entity_uris(question)
    all_uris = SessionContextBuilder.entity_s3_uris(@session)
    executor.send(:resolve_pinned_scope, question, @session, all_uris)
  end

  def retrieval_profile(question, entity_uris)
    RagRetrievalProfile.new(entity_sources: entity_sources_for(entity_uris), question: question)
  end

  def entity_sources_for(entity_uris)
    allowed = entity_uris.to_set
    @session.active_entities.values.filter_map do |meta|
      next unless allowed.include?(meta["source_uri"].to_s)

      entity_type = meta["entity_type"].presence || meta["source"]
      entity_type == "image_upload" ? "image_upload" : "document"
    end
  end

  def restore_session
    return unless @session && @original_state

    @session.update!(
      active_entities: @original_state[:active_entities],
      conversation_history: @original_state[:conversation_history]
    )
  rescue StandardError => e
    Rails.logger.error("RAG benchmark failed to restore session: #{e.class}: #{e.message}")
  end

  def write_payload(run_error)
    @finished_at = Time.current
    FileUtils.mkdir_p(File.dirname(@output_path))
    File.write(@output_path, JSON.pretty_generate(full_payload(run_error)))
  end

  def full_payload(run_error)
    tracked = tracked_queries
    summary_payload.merge(
      benchmark_version: BENCHMARK_VERSION,
      benchmark_mode: @benchmark_mode,
      target_case_keys: @target_case_keys,
      executed_case_keys: @executed_case_keys,
      expected_call_count: @executed_case_keys.size,
      git_revision: @preflight.dig(:code, :git_revision),
      git_dirty: @preflight.dig(:code, :git_dirty),
      code_fingerprint_sha256: @preflight.dig(:code, :sha256),
      aws_region: @preflight[:aws_region],
      knowledge_base_id: @preflight[:knowledge_base_id],
      configuration: @preflight.except(:aws_identity, :corpus, :code),
      aws_identity: @preflight[:aws_identity],
      corpus: @preflight[:corpus],
      run_error: run_error && { type: run_error.class.name, message: run_error.message },
      local_estimate: {
        input_tokens: tracked.sum(:input_tokens),
        output_tokens: tracked.sum(:output_tokens),
        cost: tracked.to_a.sum(&:cost).round(6),
        latency_ms: tracked.pluck(:latency_ms)
      },
      results: @results
    )
  end

  def summary_payload
    deterministic = @results.count { |r| r[:model_invoked] == false }
    field_records_manifest = load_json_manifest(FIELD_RECORDS_MANIFEST_PATH)

    {
      started_at: @started_at&.utc&.iso8601(6),
      finished_at: @finished_at&.utc&.iso8601(6),
      model_id: BedrockClient::QUERY_MODEL_ID,
      query_count: @results.size,
      tracked_query_count: tracked_queries.count,
      deterministic_query_count: deterministic,
      model_invocation_count: @results.size - deterministic,
      expected_model_invocation_count: EXPECTED_MODEL_INVOCATION_COUNT,
      ingestion_contract_version: BatchChunkingPrompt::INGESTION_CONTRACT_VERSION,
      ingestion_prompt_fingerprint_sha256: BatchChunkingPrompt.prompt_fingerprint_sha256,
      field_records_manifest_version: field_records_manifest && field_records_manifest["version"],
      field_records_manifest_sha256: begin
        Digest::SHA256.hexdigest(File.read(FIELD_RECORDS_MANIFEST_PATH))
      rescue Errno::ENOENT
        nil
      end
    }
  end

  def tracked_queries
    return BedrockQuery.none unless @start_query_id
    return BedrockQuery.none if @benchmark_mode == "retrieval_preflight"

    BedrockQuery.where("id > ?", @start_query_id).where(source: :query).order(:id)
  end

  def validate_canonical_configuration(errors)
    actual = {
      model_id: BedrockClient::QUERY_MODEL_ID,
      aws_region: aws_region,
      knowledge_base_id: knowledge_base_id,
      session_identifier: @session.identifier,
      session_channel: @session.channel,
      manual_key: @manual.s3_key,
      image_key: @image.s3_key
    }

    @canonical.each do |key, expected|
      errors << "#{key} must equal #{expected.inspect}, got #{actual[key].inspect}" unless actual[key] == expected
    end
  end

  def build_corpus(manual_uri, image_uri, errors)
    manifest = load_json_manifest(CORPUS_MANIFEST_PATH)
    if manifest.blank? && @benchmark_mode != "retrieval_preflight"
      errors << "Corpus manifest is missing: #{CORPUS_MANIFEST_PATH}"
    end

    {
      manual: corpus_descriptor(@manual, manual_uri, "manual", manifest, errors),
      image: corpus_descriptor(@image, image_uri, "image", manifest, errors),
      manifest_version: manifest && manifest["version"]
    }
  end

  def corpus_descriptor(document, source_uri, name, manifest, errors)
    actual_sha256 = source_sha256(source_uri)
    expected = manifest&.dig("objects", name)
    if expected
      errors << "#{name} corpus key differs from manifest" unless expected["s3_key"] == document.s3_key
      errors << "#{name} corpus SHA-256 differs from manifest" unless expected["sha256"] == actual_sha256
    end

    {
      id: document.id,
      s3_key: document.s3_key,
      source_uri: source_uri,
      source_sha256: actual_sha256,
      expected_source_sha256: expected && expected["sha256"],
      display_name: document.display_name,
      aliases: Array(document.aliases)
    }
  rescue Aws::S3::Errors::ServiceError => e
    errors << "#{name} corpus digest failed: #{e.message}"
    {
      id: document.id,
      s3_key: document.s3_key,
      source_uri: source_uri,
      source_sha256: nil,
      expected_source_sha256: manifest&.dig("objects", name, "sha256"),
      display_name: document.display_name,
      aliases: Array(document.aliases)
    }
  end

  def source_sha256(source_uri)
    bucket, key = parse_s3_uri(source_uri)
    response = s3_client.get_object(bucket: bucket, key: key)
    digest = Digest::SHA256.new
    digest << response.body.read(1_048_576) until response.body.eof?
    digest.hexdigest
  end

  def parse_s3_uri(uri)
    match = uri.to_s.match(%r{\As3://([^/]+)/(.+)\z})
    raise PreflightError, "Invalid S3 URI: #{uri}" unless match

    [ match[1], match[2] ]
  end

  def s3_client
    @s3_client ||= Aws::S3::Client.new(build_aws_client_options(region: aws_region))
  end

  def load_json_manifest(path)
    absolute = Rails.root.join(path)
    return unless File.file?(absolute)

    JSON.parse(File.read(absolute))
  rescue JSON::ParserError => e
    raise PreflightError, "Invalid manifest #{path}: #{e.message}"
  end

  def reranking_enabled?
    @env.fetch("BEDROCK_RERANKER_ENABLED", "false").casecmp?("true")
  end

  def query_routing_enabled?
    @env.fetch("QUERY_ROUTING_ENABLED", "false").casecmp?("true")
  end

  def truthy?(key)
    @env.fetch(key, "false").casecmp?("true")
  end

  def aws_region
    @env.fetch("AWS_REGION", nil).presence ||
      Rails.application.credentials.dig(:aws, :region) ||
      "us-east-1"
  end

  def knowledge_base_id
    @env.fetch("BEDROCK_KNOWLEDGE_BASE_ID", nil).presence ||
      Rails.application.credentials.dig(:bedrock, :knowledge_base_id)
  end

  def load_aws_identity
    stdout, stderr, status = Open3.capture3(
      "aws", "sts", "get-caller-identity",
      "--region", aws_region,
      "--output", "json"
    )
    raise PreflightError, "AWS STS preflight failed: #{stderr.strip}" unless status.success?

    JSON.parse(stdout).slice("Account", "Arn", "UserId")
  rescue Errno::ENOENT, JSON::ParserError => e
    raise PreflightError, "AWS STS preflight failed: #{e.message}"
  end

  def effective_retrieval_configuration
    {
      search_type: effective_rag_config[:search_type],
      generation_temperature: effective_rag_config[:generation_temperature],
      generation_max_tokens: effective_rag_config[:generation_max_tokens],
      focused_document_results: RagRetrievalProfile::PINNED_DOCUMENT_RESULTS,
      photo_results: RagRetrievalProfile::PHOTO_RESULTS,
      safety_critical_results: RagRetrievalProfile::SAFETY_CRITICAL_RESULTS,
      exhaustive_candidates: RagRetrievalProfile::EXHAUSTIVE_CANDIDATES
    }
  end

  def effective_rag_config
    @effective_rag_config ||= BedrockRagService.allocate.send(:resolve_rag_config)
  end

  def code_fingerprint
    contents = FINGERPRINT_PATHS.filter_map do |path|
      absolute = Rails.root.join(path)
      next unless File.file?(absolute)

      "#{path}\0#{File.binread(absolute)}"
    end.join("\0")
    revision, = Open3.capture2("git", "rev-parse", "HEAD", chdir: Rails.root.to_s)
    dirty_output, = Open3.capture2(
      "git", "status", "--porcelain", "--untracked-files=all",
      chdir: Rails.root.to_s
    )

    {
      git_revision: revision.strip,
      git_dirty: dirty_output.present?,
      sha256: Digest::SHA256.hexdigest(contents),
      paths: FINGERPRINT_PATHS
    }
  end
end

RagQualityBenchmark.new.run! unless ENV["RAG_BENCHMARK_LIBRARY_ONLY"] == "1"
