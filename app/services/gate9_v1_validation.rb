# frozen_string_literal: true

require "aws-sdk-s3"
require "aws-sdk-sts"
require "digest"
require "json"

# Executes the paid Gate 9R V1 validation cohort without mutating S3 or the
# Knowledge Base. Preflight is the default; paid calls require the explicit
# GATE9_V1_EXECUTE=true switch.
class Gate9V1Validation
  include AwsClientInitializer

  class PreflightError < StandardError; end
  class BudgetExceeded < StandardError; end
  class GateFailure < StandardError; end

  VERSION = "2026-06-12-v1"
  DEFAULT_BUDGET_USD = 1.50
  EXPECTED_STAGE_COSTS = {
    manual_batch: 0.85,
    sync_pdf: 0.16,
    photos: 0.30,
    queries: 0.05
  }.freeze
  MANUAL_SOURCE_KEY = "uploads/2026-06-10/manual_plataforma_tijera_24_paginas.pdf"
  MANUAL_BASELINE_PREFIX =
    "bulk_chunks/2026-06-11/852f508da648aa7f06dcbaeb49a28ab714ae361d1591f9b4dadb3dd36652c064/"

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

  def initialize(env: ENV, identity_loader: nil, git_status_loader: nil)
    @env = env
    @identity_loader = identity_loader || method(:load_aws_identity)
    @git_status_loader = git_status_loader || method(:git_status)
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
      @stages[:sync_pdf] = run_sync_pdf
      enforce_budget!("sync_pdf")
      @stages[:photos] = run_photos
      enforce_budget!("photos")
      @stages[:queries] = run_queries
      enforce_budget!("queries")
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
      execute: execute?,
      budget_usd: budget_usd,
      expected_stage_costs: EXPECTED_STAGE_COSTS,
      expected_total_cost_usd: expected_total_cost,
      aws_identity: identity,
      knowledge_base_id: knowledge_base_id,
      bucket_name: bucket_name,
      model_id: BedrockClient::QUERY_MODEL_ID,
      inputs: input_manifest,
      routing: {
        reranker_enabled: false,
        query_routing_enabled: false,
        photo_routes: @photos.map { |photo| [ photo[:filename], photo[:route] ] }.to_h
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
    errors << "GATE9_V1_SYNC_PDF is missing" unless File.file?(@sync_pdf_path)
    missing_photos = @photo_paths.reject { |path| File.file?(path) }
    errors << "missing photo files: #{missing_photos.join(', ')}" if missing_photos.any?
    return if errors.any?

    @manual_binary = File.binread(@manual_path)
    @sync_pdf_binary = File.binread(@sync_pdf_path)
    @photos = @photo_paths.map { |path| photo_manifest(path) }

    manual_pages = PdfPageSplitterService.new(@manual_binary).page_count
    sync_pages = PdfPageSplitterService.new(@sync_pdf_binary).page_count
    errors << "manual must have exactly 24 pages (got #{manual_pages})" unless manual_pages == 24
    errors << "sync PDF must have 2-3 pages (got #{sync_pages})" unless (2..3).cover?(sync_pages)
    errors << "photo cohort must contain 8-10 files" unless (8..10).cover?(@photos.size)
    errors << "photo cohort must contain unique binaries" unless @photos.pluck(:sha256).uniq.size == @photos.size
    errors << "photo cohort must include at least one Opus route" unless @photos.any? { |photo| photo[:route] == :opus }
  end

  def photo_manifest(path)
    binary = File.binread(path)
    content_type = content_type_for(path)
    {
      path: path,
      filename: File.basename(path),
      binary: binary,
      bytes: binary.bytesize,
      sha256: Digest::SHA256.hexdigest(binary),
      content_type: content_type,
      route: FieldPhotoDensityGate.decide(
        binary: binary,
        content_type: content_type,
        filename: File.basename(path)
      )
    }
  end

  def input_manifest
    {
      manual: file_manifest(@manual_path, @manual_binary).merge(pages: 24),
      sync_pdf: file_manifest(@sync_pdf_path, @sync_pdf_binary).merge(
        pages: PdfPageSplitterService.new(@sync_pdf_binary).page_count
      ),
      photos: @photos.map { |photo| photo.except(:binary, :path) }
    }
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
      chunks_count: parsed.chunks_count,
      canonical_name: parsed.canonical_name,
      stop_reasons: page_results.pluck(:stop_reason).compact.tally,
      quality: compare_manual_quality(memory)
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
    current_text = memory.text_chunks.values.join("\n")
    baseline_text = baseline_chunk_texts.join("\n")
    current_ids = current_text.scan(/RECORD_ID:\s*(FR-[A-F0-9]+)/).flatten.uniq.sort
    baseline_ids = baseline_text.scan(/RECORD_ID:\s*(FR-[A-F0-9]+)/).flatten.uniq.sort
    retained = baseline_ids & current_ids

    {
      baseline_chunks: baseline_chunk_texts.size,
      current_chunks: memory.text_chunks.size,
      baseline_record_ids: baseline_ids.size,
      current_record_ids: current_ids.size,
      retained_record_ids: retained.size,
      record_id_recall: baseline_ids.empty? ? nil : (retained.size.to_f / baseline_ids.size).round(4),
      missing_record_ids: baseline_ids - current_ids
    }
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

    {
      budget: gate(actual_cost_usd <= budget_usd, actual: actual_cost_usd, limit: budget_usd),
      telemetry_complete: gate(telemetry_complete, incomplete_ids: rows.reject { |row|
        row.route.present? && row.attempt.present? && row.max_tokens.present? && row.correlation_id.present?
      }.pluck(:id)),
      no_duplicate_invocations: gate(signatures.uniq.size == signatures.size),
      batch_not_truncated: gate(rows.where(route: "batch", stop_reason: "max_tokens").none?),
      manual_complete: gate(
        @stages.dig(:manual_batch, :failed_results).empty? &&
          @stages.dig(:manual_batch, :degraded_pages).empty?
      ),
      manual_quality: gate(
        quality[:baseline_record_ids].to_i.positive? &&
          quality[:record_id_recall].to_f >= 0.95,
        quality: quality
      ),
      photo_cohort: gate(
        @stages.dig(:photos, :count).to_i.between?(8, 10) &&
          @stages.dig(:photos, :unique_sha256_count) == @stages.dig(:photos, :count) &&
          @stages.dig(:photos, :routes, :opus).to_i.positive?
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
    }
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
    EXPECTED_STAGE_COSTS.values.sum.round(2)
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
