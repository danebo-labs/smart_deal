# frozen_string_literal: true

require "aws-sdk-s3"
require "aws-sdk-sts"
require "digest"
require "json"
require "set"

# Executes the paid Gate 9R V1 validation cohort without mutating S3 or the
# Knowledge Base. Preflight is the default; paid calls require the explicit
# GATE9_V1_EXECUTE=true switch.
class Gate9V1Validation
  include AwsClientInitializer

  class PreflightError < StandardError; end
  class BudgetExceeded < StandardError; end
  class GateFailure < StandardError; end

  VERSION = "2026-06-12-v2"
  DEFAULT_BUDGET_USD = 1.50
  FULL_EXPECTED_STAGE_COSTS = {
    manual_batch: 0.85,
    sync_pdf: 0.16,
    photos: 0.30,
    queries: 0.05
  }.freeze
  MANUAL_ONLY_EXPECTED_STAGE_COSTS = { manual_batch: 1.20 }.freeze
  MODES = %w[full manual_only].freeze
  DEFAULT_MAX_RETRY_PAGES = 1
  DEFAULT_RETRY_RESERVE_USD = 0.30
  MANUAL_SOURCE_KEY = "uploads/2026-06-10/manual_plataforma_tijera_24_paginas.pdf"
  MANUAL_BASELINE_PREFIX =
    "bulk_chunks/2026-06-11/852f508da648aa7f06dcbaeb49a28ab714ae361d1591f9b4dadb3dd36652c064/"
  EVIDENCE_ATTRIBUTES = %w[type source action expected_result stop_trigger stop_action evidence].freeze
  STOP_WORK_SIMILARITY_WEIGHTS = {
    "source" => 0.05,
    "action" => 0.10,
    "expected_result" => 0.10,
    "stop_trigger" => 0.25,
    "stop_action" => 0.25,
    "evidence" => 0.25
  }.freeze
  STOP_WORK_SOURCE_MATCH_BONUS = 0.20
  STOP_WORK_STATION_MISMATCH_CAP = 0.55
  CONTROL_STATION_TOKENS = {
    platform: %w[plataforma platform superior upper],
    ground: %w[tierra suelo ground lower]
  }.freeze
  SEMANTIC_TOKEN_NORMALIZATIONS = {
    "detenida" => "detener",
    "detenido" => "detener",
    "detenidas" => "detener",
    "detenidos" => "detener"
  }.freeze

  QUERY_CASES = [
    {
      key: "pinned_document",
      question: "¿Cuál es el propósito principal de este equipo?",
      entity_sources: [ "document" ],
      scope: :manual,
      expected_top_k: 3
    },
    {
      key: "safety_document",
      question: "Si una prueba falla, ¿qué debo hacer y quién puede reparar la máquina?",
      entity_sources: [ "document" ],
      scope: :manual,
      expected_top_k: 5
    },
    {
      key: "open_catalog",
      question: "¿Qué documentación técnica está disponible sobre plataformas elevadoras?",
      entity_sources: [],
      scope: :global,
      expected_top_k: 8
    },
    {
      key: "pinned_photo",
      question: "¿Qué etiquetas visibles aparecen en este esquema?",
      entity_sources: [ "image_upload" ],
      scope: :image,
      expected_top_k: 10
    },
    {
      key: "exhaustive",
      question: "Enumera todas las pruebas funcionales previas al uso.",
      entity_sources: [],
      scope: :global,
      expected_top_k: 15
    },
    {
      key: "filtered_fallback",
      question: "¿Qué contiene este documento?",
      entity_sources: [ "document" ],
      scope: :missing,
      expected_top_k: 3,
      expected_attempts: 2
    }
  ].freeze

  class MemoryS3
    attr_reader :objects

    def initialize
      @objects = {}
    end

    def upload_text(key, content)
      @objects[key] = content
      key
    end

    def text_chunks
      @objects
        .select { |key, _value| key.end_with?(".txt") }
        .sort_by { |key, _value| key[/chunk_(\d+)\.txt\z/, 1].to_i }
        .to_h
    end
  end

  def initialize(env: ENV, identity_loader: nil, git_status_loader: nil, retry_service: nil)
    @env = env
    @identity_loader = identity_loader || method(:load_aws_identity)
    @git_status_loader = git_status_loader || method(:git_status)
    @retry_service = retry_service || BatchPageRetryService.new
    @stages = {}
    @memory_outputs = {}
  end

  def run!
    @preflight = preflight!
    return emit(preflight_payload) unless execute?

    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :inline
    @start_query_id = BedrockQuery.maximum(:id).to_i
    @started_at = Time.current
    run_error = nil

    begin
      @stages[:manual_batch] = run_manual_batch
      enforce_budget!("manual_batch")
      if full_mode?
        @stages[:sync_pdf] = run_sync_pdf
        enforce_budget!("sync_pdf")
        @stages[:photos] = run_photos
        enforce_budget!("photos")
        @stages[:queries] = run_queries
        enforce_budget!("queries")
      end
      @gates = evaluate_gates
      failed = @gates.select { |_name, gate| gate[:passed] == false }
      raise GateFailure, failed.keys.join(", ") if failed.any?
    rescue StandardError => e
      run_error = e
    ensure
      @finished_at = Time.current
      @payload = result_payload(run_error)
      write_payload(@payload)
      ActiveJob::Base.queue_adapter = original_adapter
    end

    raise run_error if run_error

    emit(@payload)
  end

  def preflight!
    errors = []
    load_inputs(errors)

    errors << "GATE9_V1_MODE must be one of: #{MODES.join(', ')}" unless MODES.include?(mode)
    errors << "git working tree must be clean" if @git_status_loader.call.to_s.present?
    errors << "BEDROCK_RERANKER_ENABLED must be false" if truthy?("BEDROCK_RERANKER_ENABLED")
    errors << "QUERY_ROUTING_ENABLED must be false" if truthy?("QUERY_ROUTING_ENABLED")
    errors << "estimated cohort cost exceeds budget" if expected_total_cost > budget_usd
    errors << "Knowledge Base ID is missing" if knowledge_base_id.blank?
    errors << "S3 bucket is missing" if bucket_name.blank?
    errors << "Anthropic API key is missing" if anthropic_api_key.blank?

    identity = @identity_loader.call
    errors << "AWS caller identity is unavailable" if identity.blank?
    raise PreflightError, errors.join("; ") if errors.any?

    {
      version: VERSION,
      mode: mode,
      execute: execute?,
      budget_usd: budget_usd,
      expected_stage_costs: expected_stage_costs,
      expected_total_cost_usd: expected_total_cost,
      aws_identity: identity,
      knowledge_base_id: knowledge_base_id,
      bucket_name: bucket_name,
      model_id: BedrockClient::QUERY_MODEL_ID,
      inputs: input_manifest,
      routing: {
        reranker_enabled: false,
        query_routing_enabled: false,
        photo_routes: Array(@photos).map { |photo| [ photo[:filename], photo[:route] ] }.to_h
      },
      git_revision: `git rev-parse HEAD`.strip
    }
  end

  private

  def load_inputs(errors)
    @manual_path = @env["GATE9_V1_MANUAL"].to_s
    @sync_pdf_path = @env["GATE9_V1_SYNC_PDF"].to_s
    @photo_paths = @env["GATE9_V1_PHOTOS"].to_s.split(",").map(&:strip).compact_blank

    errors << "GATE9_V1_MANUAL is missing" unless File.file?(@manual_path)
    if full_mode?
      errors << "GATE9_V1_SYNC_PDF is missing" unless File.file?(@sync_pdf_path)
      missing_photos = @photo_paths.reject { |path| File.file?(path) }
      errors << "missing photo files: #{missing_photos.join(', ')}" if missing_photos.any?
    end
    return if errors.any?

    @manual_binary = File.binread(@manual_path)
    manual_pages = PdfPageSplitterService.new(@manual_binary).page_count
    errors << "manual must have exactly 24 pages (got #{manual_pages})" unless manual_pages == 24

    return unless full_mode?

    @sync_pdf_binary = File.binread(@sync_pdf_path)
    @photos = @photo_paths.map { |path| photo_manifest(path) }
    sync_pages = PdfPageSplitterService.new(@sync_pdf_binary).page_count
    errors << "sync PDF must have 2-3 pages (got #{sync_pages})" unless (2..3).cover?(sync_pages)
    errors << "photo cohort must contain 8-10 files" unless (8..10).cover?(@photos.size)
    errors << "photo cohort must contain unique binaries" unless @photos.pluck(:sha256).uniq.size == @photos.size
    errors << "photo cohort must include at least one Opus route" unless @photos.any? { |photo| photo[:route] == :opus }
  end

  def photo_manifest(path)
    binary = File.binread(path)
    content_type = content_type_for(path)
    dimensions = image_dimensions(binary)
    {
      path: path,
      filename: File.basename(path),
      binary: binary,
      bytes: binary.bytesize,
      sha256: Digest::SHA256.hexdigest(binary),
      content_type: content_type,
      width: dimensions[:width],
      height: dimensions[:height],
      format: dimensions[:format],
      route: FieldPhotoDensityGate.decide(
        binary: binary,
        content_type: content_type,
        filename: File.basename(path)
      )
    }
  end

  def input_manifest
    manifest = {
      manual: file_manifest(@manual_path, @manual_binary).merge(pages: 24)
    }
    if full_mode?
      manifest.merge!(
      sync_pdf: file_manifest(@sync_pdf_path, @sync_pdf_binary).merge(
        pages: PdfPageSplitterService.new(@sync_pdf_binary).page_count
      ),
      photos: @photos.map { |photo| photo.except(:binary, :path) }
      )
    end
    manifest
  end

  def file_manifest(path, binary)
    {
      path: path,
      filename: File.basename(path),
      bytes: binary.bytesize,
      sha256: Digest::SHA256.hexdigest(binary)
    }
  end

  def run_manual_batch
    sha256 = Digest::SHA256.hexdigest(@manual_binary)
    filename = File.basename(@manual_path)
    client = ClaudeBatchClient.new
    submission = ManualBatchIngestionService.new(batch_client: client).submit!(
      binary: @manual_binary,
      filename: filename,
      sha256: sha256,
      s3_key: MANUAL_SOURCE_KEY,
      locale: "es"
    )
    raise GateFailure, "manual batch submitted no pages" if submission[:batch_id].blank?

    status = wait_for_batch(client, submission[:batch_id])
    customs_to_page = submission[:page_customs].invert
    page_results = []
    failures = []
    tracker = IngestManualBatchResultsJob.new

    client.results_each(batch_id: submission[:batch_id]) do |result|
      page_number = customs_to_page[result.custom_id]
      unless page_number
        failures << { custom_id: result.custom_id, type: "unknown_custom_id" }
        next
      end

      unless result.result.type.to_s == "succeeded"
        failures << { page: page_number, type: result.result.type.to_s }
        next
      end

      message = result.result.message
      stop_reason = message.respond_to?(:stop_reason) ? message.stop_reason.to_s.presence : nil
      tracker.send(
        :track_page_usage,
        message,
        filename,
        page_number,
        submission[:kept_pages].size,
        sha256: sha256,
        stop_reason: stop_reason
      )
      page_results << {
        page_number: page_number,
        text: extract_message_text(message),
        model: message.model.to_s,
        stop_reason: stop_reason
      }
    end

    retry_summary = retry_manual_pages!(
      page_results,
      s3_key: MANUAL_SOURCE_KEY,
      filename: filename,
      sha256: sha256
    )
    report = ChunkMergerService.merge_with_report(page_results)
    memory = MemoryS3.new
    asset = ChunkAsset.new(
      filename: filename,
      sha256: sha256,
      s3_key: MANUAL_SOURCE_KEY,
      content_type: "application/pdf"
    )
    parsed = BatchResultsParserService.new(s3_service: memory).call(
      asset: asset,
      raw_json: report[:json],
      ingestion_path: "manual_batch_v1"
    )
    @memory_outputs[:manual] = memory

    {
      batch_id: submission[:batch_id],
      processing_status: status.processing_status.to_s,
      total_pages: submission[:total_pages],
      kept_pages: submission[:kept_pages],
      succeeded_pages: page_results.pluck(:page_number).sort,
      failed_results: failures,
      degraded_pages: report[:degraded_pages],
      retry: retry_summary,
      chunks_count: parsed.chunks_count,
      canonical_name: parsed.canonical_name,
      stop_reasons: page_results.pluck(:stop_reason).compact.tally,
      quality: compare_manual_quality(memory)
    }
  end

  def retry_manual_pages!(page_results, s3_key:, filename:, sha256:)
    candidates = page_results.select { |page| BatchPageRetryService.needs_retry?(page) }
    candidate_details = candidates.map do |page|
      {
        page: page[:page_number],
        reason: page[:stop_reason] == "max_tokens" ? "max_tokens" : "invalid_json"
      }
    end
    if candidates.size > max_retry_pages
      raise GateFailure, "manual batch has #{candidates.size} retry pages; limit is #{max_retry_pages}"
    end

    projected_cost = actual_cost_usd + candidates.size * retry_reserve_usd
    if projected_cost > budget_usd
      raise BudgetExceeded,
        "manual retry reserve: $#{format('%.4f', projected_cost)} > $#{format('%.2f', budget_usd)}"
    end

    before_id = BedrockQuery.maximum(:id).to_i
    @retry_service.retry_failed_pages!(
      page_results: page_results,
      s3_key: s3_key,
      filename: filename,
      sha256: sha256,
      tracking_prefix: "web_batch_retry"
    )
    retry_rows = BedrockQuery.where("id > ?", before_id).where(route: "bulk_retry").order(:id)

    {
      candidates: candidate_details,
      calls: retry_rows.size,
      attempts: retry_rows.pluck(:attempt),
      final_failed_pages: page_results
        .select { |page| BatchPageRetryService.needs_retry?(page) }
        .pluck(:page_number)
    }
  end

  def wait_for_batch(client, batch_id)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + batch_timeout_seconds

    loop do
      status = client.retrieve(batch_id: batch_id)
      return status if status.processing_status.to_s == "ended"
      raise GateFailure, "unexpected batch status #{status.processing_status}" unless status.processing_status.to_s == "in_progress"
      raise GateFailure, "batch timeout after #{batch_timeout_seconds}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep batch_poll_seconds
    end
  end

  def run_sync_pdf
    memory = MemoryS3.new
    sha256 = Digest::SHA256.hexdigest(@sync_pdf_binary)
    asset = SingleFileChunkingService.new(
      binary: @sync_pdf_binary,
      content_type: "application/pdf",
      filename: File.basename(@sync_pdf_path),
      s3_key: "gate9-v1/#{File.basename(@sync_pdf_path)}",
      sha256: sha256,
      s3_service: memory,
      locale: "es"
    ).call
    @memory_outputs[:sync_pdf] = memory

    {
      sha256: sha256,
      chunks_count: asset.chunks_count,
      canonical_name: asset.canonical_name,
      degraded_pages: Array(asset.degraded_pages),
      writes: memory.objects.size
    }
  end

  def run_photos
    results = @photos.map do |photo|
      memory = MemoryS3.new
      asset = SingleFileChunkingService.new(
        binary: photo[:binary],
        content_type: photo[:content_type],
        filename: photo[:filename],
        s3_key: "gate9-v1/#{photo[:filename]}",
        sha256: photo[:sha256],
        s3_service: memory,
        locale: "es"
      ).call
      @memory_outputs[:"photo_#{photo[:sha256][0, 12]}"] = memory

      photo.except(:binary, :path).merge(
        chunks_count: asset.chunks_count,
        canonical_name: asset.canonical_name,
        writes: memory.objects.size
      )
    end

    {
      count: results.size,
      unique_sha256_count: results.pluck(:sha256).uniq.size,
      routes: results.pluck(:route).tally,
      items: results
    }
  end

  def run_queries
    manual_uri = "s3://#{bucket_name}/#{MANUAL_SOURCE_KEY}"
    image_uri = "s3://#{bucket_name}/uploads/2026-06-10/pagina_16_esquema_hidraulico.png"
    missing_uri = "s3://#{bucket_name}/gate9-v1/missing-#{SecureRandom.hex(8)}.pdf"
    service = BedrockRagService.new(knowledge_base_id: knowledge_base_id)

    results = QUERY_CASES.map do |query_case|
      uris = case query_case[:scope]
      when :manual then [ manual_uri ]
      when :image then [ image_uri ]
      when :missing then [ missing_uri ]
      else []
      end

      before_id = BedrockQuery.maximum(:id).to_i
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = service.query(
        query_case[:question],
        response_locale: :es,
        entity_s3_uris: uris,
        entity_sources: query_case[:entity_sources],
        output_channel: :web
      )
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      rows = BedrockQuery.where("id > ?", before_id).order(:id)

      {
        key: query_case[:key],
        question: query_case[:question],
        expected_top_k: query_case[:expected_top_k],
        actual_top_k: result.dig(:retrieval_trace, :vector_search_configuration, "number_of_results") ||
          result.dig(:retrieval_trace, :vector_search_configuration, :number_of_results),
        expected_attempts: query_case[:expected_attempts] || 1,
        model_calls: rows.size,
        routes: rows.pluck(:route),
        correlation_ids: rows.pluck(:correlation_id).uniq,
        citations_count: Array(result[:citations]).size,
        answer_chars: result[:answer].to_s.length,
        elapsed_ms: elapsed_ms
      }
    end

    { count: results.size, cases: results }
  end

  def compare_manual_quality(memory)
    current_chunks = memory.text_chunks.values
    baseline_chunks = baseline_chunk_texts
    current_ledger = evidence_ledger(current_chunks)
    baseline_ledger = evidence_ledger(baseline_chunks)
    matches = semantic_matches(critical_evidence_records, current_ledger.records)
    mandatory_ids = critical_evidence_manifest.dig("stop_work_cases", "expected_mandatory_record_ids") || []
    mandatory_matches = matches.select { |match| mandatory_ids.include?(match[:expected_id]) }
    critical_recall = matches.count { |match| match[:score] >= 0.5 }.fdiv(matches.size).round(4)
    current_ids = current_ledger.record_ids.sort
    baseline_ids = baseline_ledger.record_ids.sort
    chunk_ratio = current_chunks.size.fdiv(baseline_chunks.size).round(4)
    record_ratio = current_ledger.records.size.fdiv(baseline_ledger.records.size).round(4)
    material_evidence_retained =
      current_ledger.valid? &&
      chunk_ratio >= 0.8 &&
      record_ratio >= 0.8 &&
      critical_recall >= 0.8 &&
      mandatory_matches.all? { |match| match[:score] >= 0.6 }

    {
      material_evidence_retained: material_evidence_retained,
      baseline_chunks: baseline_chunks.size,
      current_chunks: current_chunks.size,
      chunk_ratio: chunk_ratio,
      baseline_records: baseline_ledger.records.size,
      current_records: current_ledger.records.size,
      record_ratio: record_ratio,
      current_records_by_type: current_ledger.records.group_by(&:type).transform_values(&:size),
      invalid_current_records: current_ledger.invalid_records.size,
      conflicting_current_record_ids: current_ledger.conflicting_ids,
      critical_cases: matches.size,
      critical_semantic_recall_at_0_5: critical_recall,
      mandatory_semantic_matches: mandatory_matches,
      exact_record_id_overlap: (baseline_ids & current_ids).size,
      exact_record_id_recall_diagnostic: baseline_ids.empty? ? nil :
        ((baseline_ids & current_ids).size.to_f / baseline_ids.size).round(4)
    }
  end

  def evidence_ledger(text_chunks)
    chunks = text_chunks.map.with_index do |text, index|
      {
        content: text,
        rank: index + 1,
        chunk_sha256: Digest::SHA256.hexdigest(text)
      }
    end
    Rag::FieldRecordParser.parse_chunks(chunks)
  end

  def semantic_matches(expected_records, actual_records)
    candidates = expected_records.each_with_index.flat_map do |expected, expected_index|
      actual_records.each_with_index.filter_map do |actual, actual_index|
        next unless actual.type == expected["type"]

        {
          expected_index: expected_index,
          actual_index: actual_index,
          score: evidence_similarity(expected, actual)
        }
      end
    end.sort_by { |candidate| -candidate[:score] }

    used_expected = Set.new
    used_actual = Set.new
    assigned = {}
    candidates.each do |candidate|
      next if used_expected.include?(candidate[:expected_index])
      next if used_actual.include?(candidate[:actual_index])

      used_expected << candidate[:expected_index]
      used_actual << candidate[:actual_index]
      assigned[candidate[:expected_index]] = candidate
    end

    expected_records.map.with_index do |expected, index|
      candidate = assigned[index]
      {
        expected_id: expected["record_id"],
        type: expected["type"],
        score: candidate ? candidate[:score].round(4) : 0.0,
        matched_id: candidate && actual_records[candidate[:actual_index]].record_id
      }
    end
  end

  def evidence_similarity(expected, actual)
    return stop_work_similarity(expected, actual) if stop_work_condition?(expected, actual)

    expected_tokens = evidence_tokens(expected)
    actual_tokens = evidence_tokens(actual)
    token_jaccard(expected_tokens, actual_tokens)
  end

  def stop_work_similarity(expected, actual)
    total_weight = STOP_WORK_SIMILARITY_WEIGHTS.values.sum
    weighted_score = STOP_WORK_SIMILARITY_WEIGHTS.sum do |attribute, weight|
      weight * field_similarity(expected, actual, attribute)
    end

    score = weighted_score / total_weight
    score += STOP_WORK_SOURCE_MATCH_BONUS if field_similarity(expected, actual, "source") == 1.0
    score = [ score, STOP_WORK_STATION_MISMATCH_CAP ].min if control_station_mismatch?(expected, actual)
    [ score, 1.0 ].min
  end

  def control_station_mismatch?(expected, actual)
    expected_tags = control_station_tags(record_value(expected, "source"))
    actual_tags = control_station_tags(record_value(actual, "source"))
    return false if expected_tags.empty? || actual_tags.empty?

    (expected_tags & actual_tags).empty?
  end

  def control_station_tags(value)
    tokens = semantic_tokens(value)

    CONTROL_STATION_TOKENS.each_with_object(Set.new) do |(station, station_tokens), tags|
      tags << station if station_tokens.any? { |token| tokens.include?(token) }
    end
  end

  def field_similarity(expected, actual, attribute)
    expected_tokens = semantic_tokens(record_value(expected, attribute))
    actual_tokens = semantic_tokens(record_value(actual, attribute))
    token_jaccard(expected_tokens, actual_tokens)
  end

  def token_jaccard(expected_tokens, actual_tokens)
    union = expected_tokens | actual_tokens
    return 0.0 if union.empty?

    (expected_tokens & actual_tokens).size.to_f / union.size
  end

  def evidence_tokens(record)
    values = EVIDENCE_ATTRIBUTES.map { |attribute| record_value(record, attribute) }

    semantic_tokens(values.compact.join(" "))
  end

  def semantic_tokens(value)
    I18n.transliterate(value.to_s.downcase)
      .scan(/[a-z0-9]{3,}/)
      .map { |token| normalize_semantic_token(token) }
      .to_set
  end

  def normalize_semantic_token(token)
    return SEMANTIC_TOKEN_NORMALIZATIONS[token] if SEMANTIC_TOKEN_NORMALIZATIONS.key?(token)

    uncliticized = normalize_spanish_clitic(token)
    return uncliticized if uncliticized

    participle = normalize_spanish_participle(token)
    return participle if participle

    token
  end

  def normalize_spanish_clitic(token)
    %w[se la lo las los].each do |suffix|
      next unless token.end_with?(suffix)

      stem = token.delete_suffix(suffix)
      return stem if stem.match?(/[aei]r\z/)
    end

    nil
  end

  def normalize_spanish_participle(token)
    return "#{token.delete_suffix('ado')}ar" if token.length > 6 && token.end_with?("ado")
    return "#{token.delete_suffix('ada')}ar" if token.length > 6 && token.end_with?("ada")

    nil
  end

  def stop_work_condition?(expected, actual)
    record_value(expected, "type") == "STOP_WORK_CONDITION" &&
      record_value(actual, "type") == "STOP_WORK_CONDITION"
  end

  def record_value(record, attribute)
    if record.respond_to?(attribute)
      record.public_send(attribute)
    else
      record[attribute.to_s]
    end
  end

  def critical_evidence_records
    manifest = critical_evidence_manifest
    Array(manifest.dig("functional_test_cases", "records")) +
      Array(manifest.dig("stop_work_cases", "mandatory_records"))
  end

  def critical_evidence_manifest
    @critical_evidence_manifest ||= JSON.parse(
      Rails.root.join("script/fixtures/rag_quality_benchmark_field_records.json").read
    )
  end

  def baseline_chunk_texts
    return @baseline_chunk_texts if defined?(@baseline_chunk_texts)

    client = Aws::S3::Client.new(build_aws_client_options)
    keys = []
    token = nil
    loop do
      response = client.list_objects_v2(
        bucket: bucket_name,
        prefix: baseline_prefix,
        continuation_token: token
      )
      keys.concat(
        Array(response.contents).map(&:key).select { |key| key.end_with?(".txt") }
      )
      break unless response.is_truncated

      token = response.next_continuation_token
    end
    @baseline_chunk_texts = keys.sort.map do |key|
      client.get_object(bucket: bucket_name, key: key).body.read.force_encoding("UTF-8").scrub
    end
  end

  def evaluate_gates
    rows = cohort_rows
    telemetry_complete = rows.all? do |row|
      row.route.present? && row.attempt.present? && row.max_tokens.present? && row.correlation_id.present?
    end
    signatures = rows.map do |row|
      [ row.model_id, row.route, row.attempt, row.correlation_id, row.user_query ]
    end
    query_cases = @stages.dig(:queries, :cases) || []
    fallback = query_cases.find { |item| item[:key] == "filtered_fallback" }
    quality = @stages.dig(:manual_batch, :quality) || {}

    gates = {
      budget: gate(actual_cost_usd <= budget_usd, actual: actual_cost_usd, limit: budget_usd),
      telemetry_complete: gate(telemetry_complete, incomplete_ids: rows.reject { |row|
        row.route.present? && row.attempt.present? && row.max_tokens.present? && row.correlation_id.present?
      }.pluck(:id)),
      no_duplicate_invocations: gate(signatures.uniq.size == signatures.size),
      batch_not_truncated: gate(
        @stages.dig(:manual_batch, :stop_reasons).to_h["max_tokens"].to_i.zero?
      ),
      manual_complete: gate(
        @stages.dig(:manual_batch, :failed_results).empty? &&
          @stages.dig(:manual_batch, :degraded_pages).empty?
      ),
      manual_quality: gate(
        quality[:material_evidence_retained] == true,
        quality: quality
      )
    }
    return gates unless full_mode?

    gates.merge(
      photo_cohort: gate(
        @stages.dig(:photos, :count).to_i.between?(8, 10) &&
          @stages.dig(:photos, :unique_sha256_count) == @stages.dig(:photos, :count) &&
          @stages.dig(:photos, :routes, :opus).to_i.positive? &&
          Array(@stages.dig(:photos, :items)).all? do |photo|
            photo[:width].to_i.positive? && photo[:height].to_i.positive?
          end
      ),
      query_profiles: gate(
        query_cases.all? { |item| item[:actual_top_k].to_i == item[:expected_top_k] }
      ),
      filtered_global_fallback: gate(
        fallback.present? &&
          fallback[:model_calls] == 2 &&
          fallback[:routes] == %w[rag_filtered rag_global] &&
          fallback[:correlation_ids].size == 1
      )
    )
  end

  def gate(passed, details = {})
    { passed: passed }.merge(details)
  end

  def enforce_budget!(stage)
    cost = actual_cost_usd
    raise BudgetExceeded, "#{stage}: $#{format('%.4f', cost)} > $#{format('%.2f', budget_usd)}" if cost > budget_usd
  end

  def cohort_rows
    BedrockQuery.where("id > ?", @start_query_id.to_i).order(:id)
  end

  def telemetry_summary
    rows = cohort_rows
    {
      row_count: rows.size,
      actual_cost_usd: rows.sum(&:cost).round(6),
      by_route: rows.group_by(&:route).transform_values do |route_rows|
        {
          calls: route_rows.size,
          input_tokens: route_rows.sum(&:input_tokens),
          output_tokens: route_rows.sum(&:output_tokens),
          cache_read_tokens: route_rows.sum { |row| row.cache_read_tokens.to_i },
          cache_creation_tokens: route_rows.sum { |row| row.cache_creation_tokens.to_i },
          cost_usd: route_rows.sum(&:cost).round(6)
        }
      end,
      by_model: rows.group_by(&:model_id).transform_values do |model_rows|
        { calls: model_rows.size, cost_usd: model_rows.sum(&:cost).round(6) }
      end,
      stop_reasons: rows.pluck(:stop_reason).compact.tally,
      rows: rows.map do |row|
        row.attributes.slice(
          "id", "model_id", "input_tokens", "output_tokens", "cache_read_tokens",
          "cache_creation_tokens", "route", "attempt", "max_tokens",
          "stop_reason", "correlation_id", "source", "user_query", "created_at"
        ).merge("cost_usd" => row.cost)
      end
    }
  end

  def actual_cost_usd
    cohort_rows.sum(&:cost).round(6)
  end

  def result_payload(error)
    {
      version: VERSION,
      status: error ? "failed" : "passed",
      error: error && { class: error.class.name, message: error.message },
      started_at: @started_at&.iso8601(6),
      finished_at: @finished_at&.iso8601(6),
      preflight: @preflight,
      stages: @stages,
      telemetry: telemetry_summary,
      gates: @gates || {}
    }
  end

  def preflight_payload
    { version: VERSION, status: "preflight_passed", preflight: @preflight }
  end

  def write_payload(payload)
    File.write(output_path, JSON.pretty_generate(payload))
  end

  def emit(payload)
    payload.merge(output_path: output_path)
  end

  def extract_message_text(message)
    block = Array(message.content).find { |content| content.type.to_s == "text" }
    raise GateFailure, "batch result has no text block" unless block

    block.text.to_s
  end

  def content_type_for(path)
    case File.extname(path).downcase
    when ".png" then "image/png"
    when ".webp" then "image/webp"
    when ".gif" then "image/gif"
    else "image/jpeg"
    end
  end

  def image_dimensions(binary)
    image = Vips::Image.new_from_buffer(binary, "")
    {
      width: image.width,
      height: image.height,
      format: image.get("vips-loader")
    }
  rescue StandardError
    { width: nil, height: nil, format: nil }
  end

  def load_aws_identity
    Aws::STS::Client.new(build_aws_client_options).get_caller_identity.to_h
  rescue StandardError
    nil
  end

  def git_status
    `git status --porcelain`
  end

  def execute?
    truthy?("GATE9_V1_EXECUTE")
  end

  def truthy?(key)
    @env[key].to_s.casecmp?("true")
  end

  def expected_total_cost
    expected_stage_costs.values.sum.round(2)
  end

  def expected_stage_costs
    full_mode? ? FULL_EXPECTED_STAGE_COSTS : MANUAL_ONLY_EXPECTED_STAGE_COSTS
  end

  def mode
    @env.fetch("GATE9_V1_MODE", "full")
  end

  def full_mode?
    mode == "full"
  end

  def max_retry_pages
    @env.fetch("GATE9_V1_MAX_RETRY_PAGES", DEFAULT_MAX_RETRY_PAGES).to_i
  end

  def retry_reserve_usd
    @env.fetch("GATE9_V1_RETRY_RESERVE_USD", DEFAULT_RETRY_RESERVE_USD).to_f
  end

  def budget_usd
    @env.fetch("GATE9_V1_BUDGET_USD", DEFAULT_BUDGET_USD).to_f
  end

  def batch_timeout_seconds
    @env.fetch("GATE9_V1_BATCH_TIMEOUT_SECONDS", 7_200).to_i
  end

  def batch_poll_seconds
    @env.fetch("GATE9_V1_BATCH_POLL_SECONDS", 20).to_i
  end

  def output_path
    @env.fetch("GATE9_V1_OUTPUT", Rails.root.join("tmp/gate9_v1_result.json").to_s)
  end

  def knowledge_base_id
    @env["BEDROCK_KNOWLEDGE_BASE_ID"].presence ||
      Rails.application.credentials.dig(:bedrock, :knowledge_base_id)
  end

  def bucket_name
    @env["KNOWLEDGE_BASE_S3_BUCKET"].presence ||
      Rails.application.credentials.dig(:bedrock, :knowledge_base_s3_bucket) ||
      Rails.application.credentials.dig(:aws, :knowledge_base_s3_bucket)
  end

  def anthropic_api_key
    @env["ANTHROPIC_API_KEY"].presence ||
      Rails.application.credentials.dig(:anthropic, :api_key)
  end

  def baseline_prefix
    @env.fetch("GATE9_V1_BASELINE_PREFIX", MANUAL_BASELINE_PREFIX)
  end
end
