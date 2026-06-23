# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "pathname"
require "set"

# Gate 9R — Final manual onboarding run harness.
#
# Executes the one-shot paid Batch-API parse of a real ≤200-page PDF manual
# and produces a verifiable cost + quality artefact (output.json).
#
# Phases (controlled by ENV switches):
#   I   $0   Implementation + tests.                   HALT-1 after commit.
#   II  $0   Preflight: manifest + modeled estimate.   HALT-2 before any spend.
#   III paid One Batch run: submit → poll → retry → parse → measure.
#            Idempotent resume via state.json; NEVER resubmit.
#   IV  $0   Human stamps GATE9_FINAL_VERDICT=pass|fail.
#
# Primitives consumed: PdfPageSplitterService, PageRelevanceFilter,
#   BatchChunkingPrompt, ClaudeBatchClient, ClaudeChunkingClient,
#   ChunkMergerService, BatchResultsParserService, ContentDedupService,
#   ChunkAsset, Gate9CostMatrix, BatchPageRetryService, LlmJsonParser.
#
# NO production state is mutated: output goes to MemoryS3 (in-memory),
# KB sync is PROHIBITED. S3 input PDF is purged on exit.
class Gate9FinalManual
  class PreflightError < StandardError; end
  class GateFailure    < StandardError; end
  class AbortError     < StandardError; end

  # ─── MemoryS3 stub ────────────────────────────────────────────────────
  class MemoryS3
    attr_reader :objects

    def initialize
      @objects = {}
    end

    def upload_text(key, content)
      @objects[key] = content
      key
    end

    def delete_prefix(prefix)
      @objects.delete_if { |k, _| k.start_with?(prefix) }
    end
  end

  PageProxy = Struct.new(:number, :binary)
  private_constant :PageProxy

  # ─── Constants ────────────────────────────────────────────────────────
  VERSION         = "gate9-final-3"
  MAX_PAGES = ContractualLimits::MANUAL.fetch(:max_pages_included)
  # Mirror of BedrockQuery::BEDROCK_PRICING for ingestion keys.
  # Test #13 asserts these rates equal BEDROCK_PRICING entries exactly.
  PRICING         = Gate9CostMatrix::PRICING.freeze
  PRICING_VERSION = Gate9CostMatrix::PRICING_VERSION

  DEFAULT_BATCH_TIMEOUT_SECONDS         = 7200
  DEFAULT_BATCH_POLL_SECONDS            = 20
  DEFAULT_SONNET_SAMPLE_STRIDE          = 10
  DEFAULT_SCANNED_PREDOMINANT_THRESHOLD = 0.50
  DEFAULT_MAX_RETRY_PAGES               = 1

  def self.contractual_max
    @contractual_max ||= Gate9CostMatrix.new.report.dig(:contractual_max, :manual_200pp)
  end

  # @param env          [Hash]         ENV or injectable stub
  # @param batch_client [Object, nil]  injectable ClaudeBatchClient (tests)
  # @param s3_client    [Object, nil]  injectable Aws::S3::Client (tests)
  def initialize(env: ENV, batch_client: nil, s3_client: nil)
    @env            = env
    @injected_batch = batch_client
    @injected_s3    = s3_client
    @page_results   = []
    @failed_results = []
    @degraded_pages = []
  end

  # ─── Public entry point ───────────────────────────────────────────────

  def run!
    if @env["GATE9_FINAL_VERDICT"].present?
      return run_verdict!
    end

    run_preflight!

    unless execute?
      emit_halt_2!
      return build_output_json
    end

    original_adapter          = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :inline
    @started_at = Time.current.iso8601

    begin
      resume_execution!
    ensure
      ActiveJob::Base.queue_adapter = original_adapter
      purge_s3_input! if execution_complete?
    end

    if load_state["status"] == "waiting"
      emit_waiting!
      return build_output_json
    end

    @finished_at = Time.current.iso8601
    update_state!({ finished_at: @finished_at })
    emit_halt_3!
    build_output_json
  end

  private

  # ─── ENV accessors ────────────────────────────────────────────────────

  def execute?
    truthy?("GATE9_FINAL_EXECUTE")
  end

  def budget_usd
    @env["GATE9_FINAL_BUDGET_USD"].to_f
  end

  def max_retry_pages
    @env.fetch("GATE9_FINAL_MAX_RETRY_PAGES", DEFAULT_MAX_RETRY_PAGES).to_i
  end

  def batch_timeout_seconds
    @env.fetch("GATE9_FINAL_BATCH_TIMEOUT_SECONDS", DEFAULT_BATCH_TIMEOUT_SECONDS).to_i
  end

  def batch_poll_seconds
    @env.fetch("GATE9_FINAL_BATCH_POLL_SECONDS", DEFAULT_BATCH_POLL_SECONDS).to_i
  end

  def sonnet_sample_stride
    @env.fetch("GATE9_FINAL_SONNET_SAMPLE_STRIDE", DEFAULT_SONNET_SAMPLE_STRIDE).to_i
  end

  def scanned_threshold
    @env.fetch(
      "GATE9_FINAL_SCANNED_PREDOMINANT_THRESHOLD",
      DEFAULT_SCANNED_PREDOMINANT_THRESHOLD
    ).to_f
  end

  def manual_path
    @env["GATE9_FINAL_MANUAL"].to_s
  end

  def truthy?(key)
    %w[true 1 yes].include?(@env[key].to_s.downcase.strip)
  end

  # ─── Path helpers ─────────────────────────────────────────────────────

  def base_dir
    @base_dir ||= if verdict? && !File.file?(manual_path)
      verdict_base_dir
    else
      File.join("tmp", "gate9_final", current_sha256)
    end
  end

  def state_path;         File.join(base_dir, "state.json"); end
  def manifest_path;      File.join(base_dir, "manifest.json"); end
  def requests_path;      File.join(base_dir, "requests_manifest.json"); end
  def results_jsonl_path; File.join(base_dir, "results.jsonl"); end
  def retries_jsonl_path; File.join(base_dir, "retries.jsonl"); end
  def output_path;        File.join(base_dir, "output.json"); end

  def current_sha256
    @current_sha256 ||= if verdict? && !File.file?(manual_path)
      File.basename(base_dir)
    else
      raise PreflightError, "GATE9_FINAL_MANUAL is missing or not a file" unless File.file?(manual_path)
      Digest::SHA256.hexdigest(File.binread(manual_path))
    end
  end

  def verdict?
    @env["GATE9_FINAL_VERDICT"].present?
  end

  def verdict_base_dir
    candidates = Dir.glob(File.join("tmp", "gate9_final", "*", "state.json")).filter_map do |path|
      state = JSON.parse(File.read(path))
      File.dirname(path) if state["status"] == "awaiting_human_review"
    rescue JSON::ParserError
      nil
    end

    raise AbortError, "No awaiting_human_review Gate 9R artifact found" if candidates.empty?
    if candidates.many?
      raise AbortError,
        "Multiple awaiting_human_review artifacts found; set GATE9_FINAL_MANUAL to select one"
    end

    candidates.first
  end

  def current_commit
    @current_commit ||= begin
      result = `git rev-parse HEAD 2>/dev/null`.strip
      result.empty? ? "unknown" : result
    end
  end

  def current_contract_version
    BatchChunkingPrompt::INGESTION_CONTRACT_VERSION
  end

  def current_prompt_fingerprint
    BatchChunkingPrompt.prompt_fingerprint_sha256
  end

  # ─── Phase I/II: Preflight ────────────────────────────────────────────

  def run_preflight!
    errors = []
    errors << "git working tree must be clean"                         if git_status.present?
    errors << "git HEAD must be known"                                 if current_commit == "unknown"
    errors << "BEDROCK_RERANKER_ENABLED must be false"                 if truthy?("BEDROCK_RERANKER_ENABLED")
    errors << "QUERY_ROUTING_ENABLED must be false"                    if truthy?("QUERY_ROUTING_ENABLED")
    errors << "BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS must be 8000" unless BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS == 8000
    errors << "GATE9_FINAL_MANUAL is missing or not a file"           unless File.file?(manual_path)
    errors << "GATE9_FINAL_MANUAL must be an absolute path"            unless Pathname.new(manual_path).absolute?
    raise PreflightError, errors.join("; ") if errors.any?

    binary     = File.binread(manual_path)
    sha256     = current_sha256
    filename   = File.basename(manual_path)
    page_count = PdfPageSplitterService.new(binary).page_count
    errors << "manual PDF has no readable pages" unless page_count.positive?
    if page_count > MAX_PAGES
      errors << "manual has #{page_count} pages; included L2 maximum is #{MAX_PAGES}"
    end

    dedup = ContentDedupService.find_completed(
      sha256:           sha256,
      contract_version: current_contract_version
    )
    errors << "dedup hit — manual already indexed at contract_version=#{current_contract_version}; use a fresh file" if dedup.hit

    scanned_count    = count_scanned_dense_local(binary)
    scanned_fraction = page_count > 0 ? scanned_count.to_f / page_count : 0.0

    if scanned_fraction >= scanned_threshold
      errors << "scanned_fraction_local=#{scanned_fraction.round(2)} >= threshold=#{scanned_threshold}: " \
                "predominantemente escaneado — fuera del L2 incluido (otro SKU)"
    end
    raise PreflightError, errors.join("; ") if errors.any?

    @manifest = {
      path:                       manual_path,
      filename:                   filename,
      bytes:                      binary.bytesize,
      sha256:                     sha256,
      page_count:                 page_count,
      scanned_dense_pages_local:  scanned_count,
      scanned_fraction_local:     scanned_fraction.round(4),
      kept_estimate_conservative: page_count,
      opus_estimate_local:        scanned_count,
      dedup_hit:                  false,
      s3_input_key:               "gate9-final/input/#{sha256}/#{filename}"
    }

    @estimate = compute_estimate(page_count, scanned_count)

    if execute?
      validate_execution_env!(errors)
      if budget_usd.positive? && @estimate[:modeled_estimate_usd] > budget_usd
        errors << "modeled estimate $#{@estimate[:modeled_estimate_usd]} exceeds budget $#{budget_usd}"
      end
    end
    raise PreflightError, errors.join("; ") if errors.any?

    FileUtils.mkdir_p(base_dir)
    write_json_file(manifest_path, @manifest)

    @preflight = {
      execute:              execute?,
      budget_usd:           budget_usd,
      max_retry_pages:      max_retry_pages,
      routing: {
        reranker_enabled:      false,
        query_routing_enabled: false,
        web_page_max_tokens:   BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS
      },
      modeled_estimate_usd: @estimate[:modeled_estimate_usd],
      estimate_breakdown:   @estimate[:breakdown]
    }
  end

  def count_scanned_dense_local(binary)
    count = 0
    @local_text_layer_chars = {}
    PdfPageSplitterService.new(binary).each_page do |num, page_bin|
      density = PageImageDensityAnalyzer.analyze(page_bin)
      @local_text_layer_chars[num.to_s] = density[:text_layer_chars].to_i
      count += 1 if density[:text_layer_chars].to_i < 100 && density[:image_area_ratio].to_f > 0.7
    end
    count
  rescue StandardError => e
    Rails.logger.warn("Gate9FinalManual: scanned_dense local estimate failed — #{e.message}")
    0
  end

  def validate_execution_env!(errors)
    errors << "GATE9_FINAL_BUDGET_USD must be a positive number" unless budget_usd.positive?
    errors << "ANTHROPIC_API_KEY must be set explicitly for the dedicated workspace" if @env["ANTHROPIC_API_KEY"].blank?
    if @env["KNOWLEDGE_BASE_S3_BUCKET"].blank?
      errors << "KNOWLEDGE_BASE_S3_BUCKET must be set explicitly for the isolated input"
    end
  end

  def compute_estimate(page_count, opus_estimate)
    sonnet_estimate = [ page_count - opus_estimate, 0 ].max
    windows         = page_count > 0 ? (page_count.to_f / PageRelevanceFilter::BATCH_WINDOW_SIZE).ceil : 0

    haiku_rates = PRICING["haiku_direct"]
    filter_in   = ContractualLimits::MANUAL[:max_filter_context_tokens] -
                  ContractualLimits::MANUAL[:max_filter_output_tokens_per_window]
    filter_out  = ContractualLimits::MANUAL[:max_filter_output_tokens_per_window]
    unit_haiku  = (filter_in * haiku_rates[:input] + filter_out * haiku_rates[:output]) / 1000.0

    ctx     = ContractualLimits::INGESTION_CONTEXT_TOKENS
    max_out = BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS
    max_in  = ctx - max_out

    unit_sonnet = (max_in * PRICING["sonnet_batch"][:input] + max_out * PRICING["sonnet_batch"][:output]) / 1000.0
    unit_opus   = (max_in * PRICING["opus_batch"][:input]   + max_out * PRICING["opus_batch"][:output])   / 1000.0

    page_filter  = (windows * unit_haiku).round(4)
    sonnet_parse = (sonnet_estimate * unit_sonnet).round(4)
    opus_parse   = (opus_estimate * unit_opus).round(4)
    embeddings   = (ContractualLimits::MANUAL[:max_embedding_tokens] *
                    PRICING["titan_v2"][:input] / 1000.0).round(4)
    total        = (page_filter + sonnet_parse + opus_parse + embeddings).round(4)

    {
      modeled_estimate_usd: total,
      breakdown: {
        page_filter:          page_filter,
        sonnet_parse:         sonnet_parse,
        opus_parse:           opus_parse,
        embeddings_estimated: embeddings
      }
    }
  end

  # ─── Phase III: Resume dispatch ───────────────────────────────────────

  def resume_execution!
    state = load_state

    if state["status"] == "submitting" && state["batch_id"].blank?
      raise AbortError,
        "State is 'submitting' without batch_id — " \
        "reconciliar manualmente contra el workspace; NO resubmitir."
    end

    if state["status"].present? && state["status"] != "preflight"
      check_state_consistency!(state)
    end

    case state["status"].to_s
    when "", "preflight"
      write_state_atomic!({
        status:             "preflight",
        sha256:             current_sha256,
        commit:             current_commit,
        contract_version:   current_contract_version,
        prompt_fingerprint: current_prompt_fingerprint,
        started_at:         @started_at
      })
      do_submit!
    when "submitting"
      do_poll!
    when "submitted", "polling"
      do_poll!
    when "waiting"
      do_poll!
    when "ended"
      do_stream!
      do_retry!
      do_merge_parse!
      do_measure!
    when "retried"
      load_page_results_from_jsonl!
      do_merge_parse!
      do_measure!
    when "parsed"
      load_page_results_from_jsonl!
      @degraded_pages = state["degraded_pages"] || []
      do_measure!
    when "measured", "awaiting_human_review", "passed", "failed"
      load_metrics_from_output!
    end
  end

  def check_state_consistency!(state)
    if state["sha256"] != current_sha256
      raise AbortError,
        "state.sha256 (#{state['sha256']&.first(12)}) != current sha256 (#{current_sha256.first(12)}) — " \
        "estado de otro manual"
    end

    mismatches = []
    mismatches << "commit"             if state["commit"] != current_commit
    mismatches << "contract_version"   if state["contract_version"] != current_contract_version
    mismatches << "prompt_fingerprint" if state["prompt_fingerprint"] != current_prompt_fingerprint
    return if mismatches.empty?

    raise AbortError,
      "state has mismatched #{mismatches.join(', ')} — deploy between runs; reconcile offline"
  end

  # ─── Submit ───────────────────────────────────────────────────────────

  def do_submit!
    binary   = File.binread(manual_path)
    sha256   = current_sha256
    filename = File.basename(manual_path)
    s3_key   = (@manifest || {}).fetch(:s3_input_key, "gate9-final/input/#{sha256}/#{filename}")

    # ATOMIC: write "submitting" with identity fields BEFORE any network call
    write_state_atomic!({
      status:             "submitting",
      sha256:             sha256,
      commit:             current_commit,
      contract_version:   current_contract_version,
      prompt_fingerprint: current_prompt_fingerprint,
      s3_input_key:       s3_key,
      started_at:         @started_at,
      retried_pages:      {}
    })

    upload_to_s3!(binary, s3_key)

    splitter    = PdfPageSplitterService.new(binary)
    total_pages = splitter.page_count
    pages       = []
    splitter.each_page { |num, bin| pages << { number: num, binary: bin, force_opus: false, model: BatchChunkingPrompt::MODEL_TEXT } }

    proxies = pages.map { |p| PageProxy.new(p[:number], p[:binary]) }

    correlation_id   = "ingest:#{sha256[0, 12]}"
    filter_bq_before = BedrockQuery.maximum(:id).to_i
    filter_results   = PageRelevanceFilter.filter_pages(
      pages:          proxies,
      filename:       filename,
      correlation_id: correlation_id
    )
    filter_bq_after  = BedrockQuery.maximum(:id).to_i
    filter_usage_rows = serialize_filter_usage_rows(
      start_id: filter_bq_before,
      end_id: filter_bq_after,
      correlation_id: correlation_id
    )

    pages.each do |page|
      fr = filter_results[page[:number]]
      next unless fr&.fetch(:force_opus, false) && fr[:keep]

      page[:model]      = BatchChunkingPrompt::MODEL_MULTIMODAL
      page[:force_opus] = true
    end

    kept_pages = pages.select { |p| filter_results[p[:number]]&.fetch(:keep, true) }
    total_kept = kept_pages.size

    system_fp = Digest::SHA256.hexdigest(JSON.generate(BatchChunkingPrompt::SYSTEM_BLOCKS))

    requests      = []
    requests_meta = []

    kept_pages.each_with_index do |page, idx|
      anchor = idx.zero?
      uc     = BatchChunkingPrompt.page_user_content(
        binary:      page[:binary],
        page_number: page[:number],
        total_pages: total_kept,
        filename:    filename,
        locale:      nil,
        anchor:      anchor
      )
      custom_id      = "#{sha256[0..15]}_p#{page[:number]}"
      content_digest = Digest::SHA256.hexdigest(JSON.generate(uc))

      requests << {
        custom_id: custom_id,
        params: {
          model:      page[:model],
          max_tokens: BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS,
          system:     BatchChunkingPrompt::SYSTEM_BLOCKS,
          messages:   [ { role: "user", content: uc } ]
        }
      }

      requests_meta << {
        custom_id:          custom_id,
        page_number:        page[:number],
        model:              page[:model],
        max_tokens:         BatchChunkingPrompt::WEB_PAGE_MAX_TOKENS,
        anchor:             anchor,
        locale:             nil,
        system_fingerprint: system_fp,
        content_digest:     content_digest
      }
    end

    write_json_file(requests_path, requests_meta)

    batch = batch_client_instance.submit_batch(requests: requests)

    page_customs = kept_pages.each_with_object({}) { |p, h| h[p[:number].to_s] = "#{sha256[0..15]}_p#{p[:number]}" }
    filter_full  = filter_results.each_with_object({}) do |(num, v), h|
      h[num.to_s] = {
        keep:       v[:keep],
        reason:     v[:reason].to_s,
        source:     v[:source].to_s,
        force_opus: v.fetch(:force_opus, false)
      }
    end

    update_state!({
      status:          "submitted",
      batch_id:        batch.id,
      page_customs:    page_customs,
      kept_pages:      kept_pages.pluck(:number),
      total_pages:     total_pages,
      filter_results:  filter_full,
      filter_bq_window: { start: filter_bq_before, end: filter_bq_after },
      filter_usage_rows: filter_usage_rows,
      local_text_layer_chars: @local_text_layer_chars || {}
    })

    do_poll!
  end

  # ─── Poll ─────────────────────────────────────────────────────────────

  def do_poll!
    state    = load_state
    batch_id = state["batch_id"]
    deadline = Time.zone.now + batch_timeout_seconds

    update_state!({ status: "polling" })

    loop do
      batch  = batch_client_instance.retrieve(batch_id: batch_id)
      status = batch.processing_status.to_s

      if status == "ended"
        update_state!({ status: "ended", processing_status: "ended" })
        break
      end

      if Time.zone.now >= deadline
        update_state!({ status: "waiting", processing_status: status })
        return
      end

      sleep batch_poll_seconds
    end

    do_stream!
    do_retry!
    do_merge_parse!
    do_measure!
  end

  # ─── Stream results ───────────────────────────────────────────────────

  def do_stream!
    state       = load_state
    customs_inv = (state["page_customs"] || {}).invert

    File.write(results_jsonl_path, "")
    @page_results   = []
    @failed_results = []

    batch_client_instance.results_each(batch_id: state["batch_id"]) do |r|
      page_num_str = customs_inv[r.custom_id]
      next unless page_num_str

      page_num = page_num_str.to_i

      if r.result.type.to_s == "succeeded"
        msg       = r.result.message
        text      = extract_text_from_message(msg)
        model_str = msg.respond_to?(:model) ? msg.model.to_s : ""
        stop_r    = msg.respond_to?(:stop_reason) ? msg.stop_reason.to_s.presence : nil
        usage     = usage_as_hash(msg.respond_to?(:usage) ? msg.usage : nil)

        pr = { page_number: page_num, text: text, model: model_str, stop_reason: stop_r, usage: usage }
        @page_results << pr

        append_jsonl!(results_jsonl_path, {
          custom_id: r.custom_id, result_type: "succeeded",
          model: model_str, stop_reason: stop_r, usage: usage, text: text
        })
      else
        failed = { page: page_num, type: r.result.type.to_s }
        @failed_results << failed
        append_jsonl!(results_jsonl_path, {
          custom_id: r.custom_id, result_type: failed[:type],
          model: nil, stop_reason: nil, usage: normalize_usage(nil), text: nil
        })
      end
    end

    update_state!({
      succeeded_pages: @page_results.pluck(:page_number),
      failed_pages:    @failed_results.pluck(:page),
      failed_results:  @failed_results
    })
  end

  # ─── Retry ────────────────────────────────────────────────────────────

  def do_retry!
    state         = load_state
    retried_pages = (state["retried_pages"] || {}).dup

    # Idempotency: substitute already-retried pages with their persisted text
    retried_pages.each do |page_str, saved_text|
      pr = @page_results.find { |r| r[:page_number] == page_str.to_i }
      next unless pr

      pr[:text]        = saved_text
      pr[:stop_reason] = nil
    end

    candidates = @page_results.select { |pr| BatchPageRetryService.needs_retry?(pr) }

    if candidates.size > max_retry_pages
      raise GateFailure,
        "#{candidates.size} pages need retry but GATE9_FINAL_MAX_RETRY_PAGES=#{max_retry_pages}"
    end

    if candidates.any?
      binary   = File.binread(manual_path)
      filename = File.basename(manual_path)
      sha256   = current_sha256

      page_binaries = {}
      PdfPageSplitterService.new(binary).each_page { |num, bin| page_binaries[num] = bin }

      # anchor and total_kept from the COMPLETE kept set, not the subset
      complete_kept = Array(state["kept_pages"]).map(&:to_i)
      total_kept    = complete_kept.size
      anchor_page   = complete_kept.min

      ladder = [ BatchChunkingPrompt::WEB_PAGE_RETRY_MAX_TOKENS, BatchChunkingPrompt::MAX_TOKENS ]

      candidates.each do |pr|
        page_num = pr[:page_number]
        page_bin = page_binaries[page_num]
        raise GateFailure, "missing local page binary for retry page #{page_num}" unless page_bin

        retry_reason = pr[:stop_reason] == "max_tokens" ? "max_tokens" : "invalid_json"

        model  = pr[:model].to_s.delete_suffix("-batch").presence || BatchChunkingPrompt::MODEL_TEXT
        client = ClaudeChunkingClient.new(model: model)
        uc     = BatchChunkingPrompt.page_user_content(
          binary:      page_bin,
          page_number: page_num,
          total_pages: total_kept,
          filename:    filename,
          anchor:      page_num == anchor_page
        )

        ladder.each_with_index do |cap, idx|
          res = client.call(
            user_content:    uc,
            filename:        filename,
            page_number:     page_num,
            total_pages:     total_kept,
            max_tokens:      cap,
            tracking_prefix: "gate9_final_retry",
            route:           "bulk_retry",
            attempt:         idx + 2,
            correlation_id:  "ingest:#{sha256[0, 12]}:p#{page_num}"
          )

          pr[:text]        = res[:text]
          pr[:stop_reason] = res[:stop_reason]

          append_jsonl!(retries_jsonl_path, {
            page:        page_num,
            rung:        cap,
            attempt:     idx + 2,
            stop_reason: res[:stop_reason],
            usage:       usage_as_hash(res[:usage]),
            text:        res[:text],
            reason:      retry_reason
          })

          break if res[:stop_reason] != "max_tokens" && BatchPageRetryService.parseable_json?(res[:text])
        end

        retried_pages[page_num.to_s] = pr[:text]
        update_state!({ retried_pages: retried_pages })
      end
    end

    update_state!({ status: "retried" })
  end

  # ─── Merge / parse ────────────────────────────────────────────────────

  def do_merge_parse!
    filename = File.basename(manual_path)
    sha256   = current_sha256
    s3_key   = load_state["s3_input_key"] || "gate9-final/input/#{sha256}/#{filename}"

    report = ChunkMergerService.merge_with_report(@page_results)
    asset  = ChunkAsset.new(
      filename:     filename,
      sha256:       sha256,
      s3_key:       s3_key,
      content_type: "application/pdf"
    )
    memory = MemoryS3.new

    @parsed_asset   = BatchResultsParserService.new(s3_service: memory).call(
      asset:          asset,
      raw_json:       report[:json],
      ingestion_path: "manual_batch_v1",
      account_id:     "gate9",
      document_uid:   sha256[0, 36]
    )
    @degraded_pages = report[:degraded_pages]

    update_state!({ status: "parsed", degraded_pages: @degraded_pages })
  end

  # ─── Measure ──────────────────────────────────────────────────────────

  def do_measure! # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
    state = load_state
    @failed_results = Array(state["failed_results"]).map(&:symbolize_keys) if @failed_results.empty?
    @degraded_pages = Array(state["degraded_pages"]) if @degraded_pages.empty?

    parse_cost = 0.0
    input_t = output_t = cache_read_t = cache_create_t = 0
    sonnet_n = opus_n = end_turn_n = max_tokens_n = 0
    by_page = []
    sonnet_prs = []
    opus_prs   = []

    @page_results.each do |pr|
      u   = normalize_usage(pr[:usage])
      key = pr[:model].to_s.include?("opus") ? "opus_batch" : "sonnet_batch"
      parse_cost += token_cost(u, key)

      input_t       += u["input_tokens"]
      output_t      += u["output_tokens"]
      cache_read_t  += u["cache_read_input_tokens"]
      cache_create_t += u["cache_creation_input_tokens"]

      if pr[:model].to_s.include?("opus")
        opus_n += 1
        opus_prs << pr
      else
        sonnet_n += 1
        sonnet_prs << pr
      end

      if pr[:stop_reason] == "max_tokens"
        max_tokens_n += 1
      elsif pr[:stop_reason].blank? || pr[:stop_reason] == "end_turn"
        end_turn_n += 1
      end

      by_page << {
        page: pr[:page_number], model: pr[:model], route: "batch", attempt: 1,
        input: u["input_tokens"], output: u["output_tokens"],
        cache_read: u["cache_read_input_tokens"], cache_creation: u["cache_creation_input_tokens"],
        stop_reason: pr[:stop_reason].to_s
      }
    end

    retry_rows   = read_jsonl(retries_jsonl_path)
    retry_cost   = compute_retry_cost(retry_rows)
    retry_pages  = retry_rows.map { |r| r["page"].to_i }.uniq
    retry_attmps = retry_rows.map { |r| r["attempt"].to_i }

    filter_cost    = compute_filter_cost_from_state(state)
    filter_cost_nc = compute_filter_no_cache_cost_from_state(state)
    embeds_usd  = (@estimate || compute_estimate(state["total_pages"].to_i, 0))[:breakdown][:embeddings_estimated]

    l2_cache    = (parse_cost + retry_cost + filter_cost + embeds_usd).round(6)
    l2_no_cache = (recompute_no_cache(@page_results, retry_rows) + filter_cost_nc + embeds_usd).round(6)

    unit_sonnet = sonnet_prs.any? ?
      (sonnet_prs.sum { |pr| token_cost(normalize_usage(pr[:usage]), "sonnet_batch") } / sonnet_prs.size).round(6) : nil
    unit_opus   = opus_prs.any?   ?
      (opus_prs.sum   { |pr| token_cost(normalize_usage(pr[:usage]), "opus_batch")   } / opus_prs.size).round(6)   : nil

    all_page_nums = (1..state["total_pages"].to_i).to_a
    kept_set      = Set.new(Array(state["kept_pages"]).map(&:to_i))
    result_pages  = Set.new(@page_results.pluck(:page_number) + @failed_results.pluck(:page))
    requested_opus_n = kept_set.count { |page| state.dig("filter_results", page.to_s, "force_opus") }
    requested_sonnet_n = kept_set.size - requested_opus_n
    cost_gate     = l2_cache <= 10.0 && l2_no_cache <= 12.0
    count4k       = compute_counterfactual_4k(retry_rows)
    count4k_total = count4k[:total] + filter_cost + embeds_usd

    @metrics = {
      pages_total:          state["total_pages"].to_i,
      pages_kept:           kept_set.size,
      pages_dropped:        all_page_nums.size - kept_set.size,
      model_split:          { sonnet: requested_sonnet_n, opus: requested_opus_n },
      opus_fraction_of_kept: kept_set.any? ? (requested_opus_n.to_f / kept_set.size).round(4) : 0.0,
      first_attempts_batch: kept_set.size,
      retries_direct:       { count: retry_rows.size, pages: retry_pages, attempts: retry_attmps },
      stop_reasons:         { end_turn: end_turn_n, max_tokens: max_tokens_n },
      tokens: {
        input_total: input_t, output_total: output_t,
        cache_read_total: cache_read_t, cache_creation_total: cache_create_t,
        by_page: by_page
      },
      unit_cost_usd: { sonnet_per_page: unit_sonnet, n_sonnet: sonnet_n, opus_per_page: unit_opus, n_opus: opus_n }
    }

    @cost = {
      pricing_version: PRICING_VERSION,
      harness_computed_usd: {
        parse: parse_cost.round(6), page_filter: filter_cost.round(6),
        retries_direct: retry_cost.round(6), embeddings_estimated: embeds_usd,
        l2_total_observed_cache: l2_cache, l2_total_projected_no_cache: l2_no_cache
      },
      anthropic_billed_usd: nil, reconciliation_delta_pct: nil,
      reconciliation_status: "pending", authoritative_source: "anthropic_usage_cost_api"
    }

    @quality = {
      structural_gates: {
        no_truncation:        max_tokens_n == 0,
        manual_complete:      @failed_results.empty? && @degraded_pages.empty? && result_pages == kept_set &&
                              @page_results.size == kept_set.size,
        json_all_valid:       @page_results.all? { |pr| BatchPageRetryService.parseable_json?(pr[:text]) },
        evidence_contract_ok: evidence_contract_ok?,
        retries_within_limit: retry_pages.uniq.size <= max_retry_pages
      },
      qc_review_lists: {
        dropped_pages: build_dropped_pages(all_page_nums, kept_set, state),
        opus_pages:    build_opus_pages(state),
        retried_pages: retry_rows.group_by { |r| r["page"].to_i }.map { |p, rows|
          { page: p, rung: rows.last["rung"], stop_reason: rows.last["stop_reason"] }
        },
        degraded_pages: @degraded_pages || [],
        sonnet_sample:  build_sonnet_sample(sonnet_prs)
      },
      human_review_verdict: nil
    }

    @commercial = {
      before_after: {
        counterfactual_4k_modeled_usd: count4k_total.round(6),
        retries_4k_truncation_usd:     count4k[:truncation].round(6),
        retries_4k_invalid_json_usd:   count4k[:invalid_json].round(6),
        observed_8k_usd:               l2_cache,
        savings_abs_usd:               (count4k_total - l2_cache).round(6),
        savings_pct: count4k_total.positive? ?
          ((count4k_total - l2_cache) / count4k_total * 100).round(2) : 0.0,
        note: "4k modelado sobre las mismas páginas; no vs $9.05-10.45 de otro manual"
      },
      projection: {
        L2: { expected_observed_n1: l2_cache, conservative_no_cache: l2_no_cache,
              contractual_max: self.class.contractual_max },
        L1: { status: "provisional" },
        L3: { status: "provisional" }
      },
      opus_sensitivity: {
        slope_usd_per_opus_point: opus_slope(unit_sonnet, unit_opus, kept_set.size),
        n_opus_pages_this_run:    opus_n,
        note: opus_n.zero? ? "si 0 Opus, pendiente apoyada en n=2 históricas; no fabricar Opus" : nil
      },
      embeddings: "estimated",
      verdict: {
        cost_gate_pass: cost_gate, quality_gate_pass: nil,
        gate9R_l2_publishable: nil, next_optimization_if_fail: nil
      }
    }

    update_state!({ status: "measured" })
    update_state!({ status: "awaiting_human_review" })
  end

  # ─── Phase IV: Verdict ────────────────────────────────────────────────

  def run_verdict!
    verdict = @env["GATE9_FINAL_VERDICT"].to_s.downcase
    raise PreflightError, "GATE9_FINAL_VERDICT must be 'pass' or 'fail'" unless %w[pass fail].include?(verdict)

    state = load_state
    unless state["status"] == "awaiting_human_review"
      raise AbortError,
        "Phase IV requires state awaiting_human_review; current status=#{state['status'].presence || 'missing'}"
    end

    output = load_output_json
    raise AbortError, "No output.json at #{output_path}; run Phase III first" unless output

    output["quality"]["human_review_verdict"] = verdict
    gates        = output.dig("quality", "structural_gates") || {}
    quality_pass = verdict == "pass" && gates.values.all? { |v| v == true }
    cost_pass    = output.dig("commercial", "verdict", "cost_gate_pass")
    publishable  = quality_pass && cost_pass == true

    output["commercial"]["verdict"]["quality_gate_pass"]       = quality_pass
    output["commercial"]["verdict"]["gate9R_l2_publishable"]   = publishable
    output["commercial"]["verdict"]["next_optimization_if_fail"] = publishable ? nil : next_opt(output)
    output["status"] = publishable ? "passed" : "failed"

    write_json_file(output_path, output)
    update_state!({ status: output["status"], human_review_verdict: verdict })
    emit_verdict!(output)
    output
  end

  def next_opt(output)
    opus_frac    = output.dig("metrics", "opus_fraction_of_kept").to_f
    max_t_count  = output.dig("metrics", "stop_reasons", "max_tokens").to_i
    scanned_frac = output.dig("manifest", "scanned_fraction_local").to_f

    return "O5-manuales" if opus_frac > 0.1 || scanned_frac > 0.1
    return "O2"          if max_t_count > 0

    "fix offline + replay"
  end

  # ─── Cost helpers ─────────────────────────────────────────────────────

  def token_cost(usage_hash, pricing_key)
    rates = PRICING[pricing_key] || PRICING["sonnet_batch"]
    u     = normalize_usage(usage_hash)
    (u["input_tokens"]               * rates[:input] +
     u["output_tokens"]              * rates[:output] +
     u["cache_read_input_tokens"]    * rates.fetch(:cache_read, 0) +
     u["cache_creation_input_tokens"] * rates.fetch(:cache_creation, 0)) / 1000.0
  end

  def normalize_usage(usage)
    return { "input_tokens" => 0, "output_tokens" => 0, "cache_read_input_tokens" => 0, "cache_creation_input_tokens" => 0 } unless usage
    u = usage.is_a?(Hash) ? usage.transform_keys(&:to_s) : {}
    {
      "input_tokens"                => u.fetch("input_tokens", 0).to_i,
      "output_tokens"               => u.fetch("output_tokens", 0).to_i,
      "cache_read_input_tokens"     => u.fetch("cache_read_input_tokens", 0).to_i,
      "cache_creation_input_tokens" => u.fetch("cache_creation_input_tokens", 0).to_i
    }
  end

  def compute_retry_cost(retry_rows)
    retry_rows.sum do |row|
      u  = normalize_usage(row["usage"])
      pr = @page_results.find { |r| r[:page_number] == row["page"].to_i }
      key = pr&.dig(:model).to_s.include?("opus") ? "opus_direct" : "sonnet_direct"
      token_cost(u, key)
    end
  end

  def compute_filter_cost_from_state(state)
    persisted_rows = Array(state["filter_usage_rows"])
    return persisted_rows.sum { |row| row["cost_usd"].to_f } if persisted_rows.any?

    window = state["filter_bq_window"]
    return 0.0 unless window

    start_id = window["start"].to_i
    end_id   = window["end"].to_i
    return 0.0 if end_id <= start_id

    BedrockQuery.where(
      id: (start_id + 1)..end_id,
      route: "page_filter",
      correlation_id: "ingest:#{state['sha256'].to_s[0, 12]}"
    ).sum(&:cost)
  end

  def compute_filter_no_cache_cost_from_state(state)
    persisted_rows = Array(state["filter_usage_rows"])
    if persisted_rows.any?
      return persisted_rows.sum { |row| row.fetch("no_cache_cost_usd", row["cost_usd"]).to_f }
    end

    window = state["filter_bq_window"]
    return 0.0 unless window

    start_id = window["start"].to_i
    end_id   = window["end"].to_i
    return 0.0 if end_id <= start_id

    BedrockQuery.where(
      id: (start_id + 1)..end_id,
      route: "page_filter",
      correlation_id: "ingest:#{state['sha256'].to_s[0, 12]}"
    ).sum do |row|
      filter_row_no_cache_cost(row)
    end
  end

  def recompute_no_cache(page_results, retry_rows)
    parse_nc = page_results.sum do |pr|
      u    = normalize_usage(pr[:usage])
      key  = pr[:model].to_s.include?("opus") ? "opus_batch" : "sonnet_batch"
      r    = PRICING[key]
      all_in = u["input_tokens"] + u["cache_read_input_tokens"] + u["cache_creation_input_tokens"]
      (all_in * r[:input] + u["output_tokens"] * r[:output]) / 1000.0
    end

    retry_nc = retry_rows.sum do |row|
      u  = normalize_usage(row["usage"])
      pr = page_results.find { |r| r[:page_number] == row["page"].to_i }
      key = (pr&.dig(:model).to_s.include?("opus") ? "opus" : "sonnet") + "_direct"
      r   = PRICING[key] || PRICING["sonnet_direct"]
      all_in = u["input_tokens"] + u["cache_read_input_tokens"] + u["cache_creation_input_tokens"]
      (all_in * r[:input] + u["output_tokens"] * r[:output]) / 1000.0
    end

    parse_nc + retry_nc
  end

  def compute_counterfactual_4k(retry_rows)
    base = trunc = json_inv = 0.0

    @page_results.each do |pr|
      u   = normalize_usage(pr[:usage])
      key = pr[:model].to_s.include?("opus") ? "opus_batch" : "sonnet_batch"
      r   = PRICING[key]
      out_4k = [ u["output_tokens"], 4000 ].min
      base += (u["input_tokens"] * r[:input] + out_4k * r[:output] +
               u["cache_read_input_tokens"] * r.fetch(:cache_read, 0) +
               u["cache_creation_input_tokens"] * r.fetch(:cache_creation, 0)) / 1000.0

      if u["output_tokens"] > 4000
        dk = pr[:model].to_s.include?("opus") ? "opus_direct" : "sonnet_direct"
        dr = PRICING[dk] || PRICING["sonnet_direct"]
        ctx = ContractualLimits::INGESTION_CONTEXT_TOKENS
        trunc += ((ctx - 8000) * dr[:input] + 8000 * dr[:output]) / 1000.0
      end
    end

    retry_rows.each do |row|
      next if row["reason"] == "max_tokens"

      pr  = @page_results.find { |r| r[:page_number] == row["page"].to_i }
      dk  = pr&.dig(:model).to_s.include?("opus") ? "opus_direct" : "sonnet_direct"
      dr  = PRICING[dk] || PRICING["sonnet_direct"]
      ctx = ContractualLimits::INGESTION_CONTEXT_TOKENS
      json_inv += ((ctx - 8000) * dr[:input] + 8000 * dr[:output]) / 1000.0
    end

    { total: base + trunc + json_inv, truncation: trunc, invalid_json: json_inv }
  end

  # ─── QC helpers ───────────────────────────────────────────────────────

  def build_dropped_pages(all_page_nums, kept_set, state)
    all_page_nums.reject { |p| kept_set.include?(p) }.map do |p|
      fr = (state["filter_results"] || {})[p.to_s] || {}
      text_chars = (state["local_text_layer_chars"] || {})[p.to_s]
      { page: p, reason: fr["reason"].to_s, text_layer_chars: text_chars&.to_i }
    end
  end

  def build_sonnet_sample(sonnet_prs)
    stride = sonnet_sample_stride
    sonnet_prs
      .sort_by { |pr| pr[:page_number] }
      .each_with_index
      .select { |_, idx| ((idx + 1) % stride).zero? }
      .map { |pr, _| { page: pr[:page_number], model: pr[:model], chunks: chunks_for_page(pr) } }
  end

  def build_opus_pages(state)
    Array(state["kept_pages"]).filter_map do |page|
      fr = (state["filter_results"] || {})[page.to_s] || {}
      next unless fr["force_opus"]

      pr = @page_results.find { |result| result[:page_number] == page.to_i }
      { page: page.to_i, model: pr&.dig(:model) || BatchChunkingPrompt::MODEL_MULTIMODAL,
        chunks: pr ? chunks_for_page(pr) : [] }
    end
  end

  def chunks_for_page(page_result)
    parsed = LlmJsonParser.parse(page_result[:text].to_s)
    Array(parsed["chunks"])
  rescue JSON::ParserError
    []
  end

  def evidence_contract_ok?
    @page_results.all? do |page_result|
      chunks = chunks_for_page(page_result)
      chunks.any? && chunks.all? { |chunk| valid_evidence_chunk?(chunk) }
    end
  end

  def valid_evidence_chunk?(chunk)
    return false unless chunk.is_a?(Hash) && chunk["text"].to_s.present? && chunk["field_records"].is_a?(Array)

    chunk["field_records"].all? do |record|
      record.is_a?(Hash) &&
        BatchResultsParserService::FIELD_RECORD_REQUIRED_KEYS.all? { |key| record[key].to_s.present? } &&
        BatchResultsParserService::FIELD_RECORD_TYPES.include?(record["k"].to_s) &&
        (record.keys - BatchResultsParserService::FIELD_RECORD_ALLOWED_KEYS).empty?
    end
  end

  def opus_slope(unit_sonnet, unit_opus, kept_count)
    return nil unless unit_sonnet && unit_opus && kept_count.positive?

    ((unit_opus - unit_sonnet) * kept_count / 100.0).round(6)
  end

  def serialize_filter_usage_rows(start_id:, end_id:, correlation_id:)
    return [] if end_id <= start_id

    BedrockQuery.where(
      id: (start_id + 1)..end_id,
      route: "page_filter",
      correlation_id: correlation_id
    ).order(:id).map.with_index do |row, index|
      {
        window: index + 1,
        input: row.input_tokens.to_i,
        output: row.output_tokens.to_i,
        cache_read: row.cache_read_tokens.to_i,
        cache_creation: row.cache_creation_tokens.to_i,
        cost_usd: row.cost,
        no_cache_cost_usd: filter_row_no_cache_cost(row)
      }
    end
  end

  def filter_row_no_cache_cost(row)
    rates = PRICING.fetch("haiku_direct")
    all_input = row.input_tokens.to_i + row.cache_read_tokens.to_i + row.cache_creation_tokens.to_i
    (all_input * rates[:input] + row.output_tokens.to_i * rates[:output]) / 1000.0
  end

  # ─── Resume loaders ───────────────────────────────────────────────────

  def load_page_results_from_jsonl!
    @page_results   = []
    state           = load_state
    @failed_results = Array(state["failed_results"]).map(&:symbolize_keys)
    @degraded_pages = Array(state["degraded_pages"])
    retried_texts   = (state["retried_pages"] || {}).transform_keys(&:to_i)

    read_jsonl(results_jsonl_path).each do |row|
      page_num = row["custom_id"]&.then { |id| id.split("_p").last&.to_i }
      next unless page_num

      unless row["result_type"] == "succeeded"
        failed = { page: page_num, type: row["result_type"].to_s }
        @failed_results << failed unless @failed_results.include?(failed)
        next
      end

      text = retried_texts.key?(page_num) ? retried_texts[page_num] : row["text"].to_s
      u    = normalize_usage(row["usage"])

      @page_results << {
        page_number: page_num,
        text:        text,
        model:       row["model"].to_s,
        stop_reason: row["stop_reason"],
        usage:       u
      }
    end
  end

  def load_metrics_from_output!
    output = load_output_json
    return unless output

    @metrics    = output["metrics"]
    @cost       = output["cost"]
    @quality    = output["quality"]
    @commercial = output["commercial"]
    @manifest   = output["manifest"]
    @preflight  = output["preflight"]
    @failed_results = Array(output.dig("batch", "failed_results")).map(&:symbolize_keys)
    @degraded_pages = Array(output.dig("batch", "degraded_pages"))
  end

  # ─── Output builders ──────────────────────────────────────────────────

  def build_output_json
    state = load_state

    output = {
      "version"            => VERSION,
      "status"             => state["status"] || "preflight",
      "error"              => nil,
      "git_revision"       => current_commit,
      "contract_version"   => current_contract_version,
      "prompt_fingerprint" => current_prompt_fingerprint,
      "started_at"         => state["started_at"],
      "finished_at"        => state["finished_at"],
      "preflight"          => preflight_out,
      "manifest"           => manifest_out,
      "batch"              => batch_out(state),
      "filter"             => filter_out(state),
      "metrics"            => metrics_out,
      "cost"               => cost_out,
      "quality"            => quality_out,
      "commercial"         => commercial_out,
      "artifacts" => {
        "base_dir"          => "tmp/gate9_final/#{current_sha256}/",
        "state"             => "state.json",
        "manifest"          => "manifest.json",
        "requests_manifest" => "requests_manifest.json",
        "raw_results"       => "results.jsonl",
        "raw_retries"       => "retries.jsonl",
        "output"            => "output.json"
      }
    }

    write_json_file(output_path, output)
    output
  end

  def preflight_out
    return ds(@preflight) if @preflight
    {
      "execute" => false, "budget_usd" => 0.0, "max_retry_pages" => 1,
      "routing" => { "reranker_enabled" => false, "query_routing_enabled" => false, "web_page_max_tokens" => 8000 },
      "modeled_estimate_usd" => 0.0,
      "estimate_breakdown" => { "page_filter" => 0.0, "sonnet_parse" => 0.0, "opus_parse" => 0.0, "embeddings_estimated" => 0.0 }
    }
  end

  def manifest_out;    @manifest ? ds(@manifest) : {}; end

  def batch_out(state)
    kept  = state["kept_pages"] || []
    total = state["total_pages"].to_i
    failed_results = @failed_results.presence || Array(state["failed_results"])
    degraded_pages = @degraded_pages.presence || Array(state["degraded_pages"])
    {
      "batch_id"          => state["batch_id"] || "",
      "processing_status" => state["processing_status"] || "",
      "total_pages"       => total,
      "kept_pages"        => kept,
      "dropped_pages"     => (1..total).to_a - kept,
      "succeeded_pages"   => state["succeeded_pages"] || [],
      "failed_results"    => failed_results,
      "degraded_pages"    => degraded_pages
    }
  end

  def filter_out(state)
    fr = state["filter_results"] || {}
    {
      "results" => fr.transform_values { |v|
        { "keep" => v["keep"], "reason" => v["reason"], "source" => v["source"], "force_opus" => v["force_opus"] }
      },
      "haiku_usage_rows" => Array(state["filter_usage_rows"]).map { |row|
        {
          "window" => row["window"], "input" => row["input"],
          "output" => row["output"], "cost_usd" => row["cost_usd"]
        }
      }
    }
  end

  def metrics_out
    return ds(@metrics) if @metrics
    {
      "pages_total" => 0, "pages_kept" => 0, "pages_dropped" => 0,
      "model_split" => { "sonnet" => 0, "opus" => 0 }, "opus_fraction_of_kept" => 0.0,
      "first_attempts_batch" => 0, "retries_direct" => { "count" => 0, "pages" => [], "attempts" => [] },
      "stop_reasons" => { "end_turn" => 0, "max_tokens" => 0 },
      "tokens" => { "input_total" => 0, "output_total" => 0, "cache_read_total" => 0, "cache_creation_total" => 0, "by_page" => [] },
      "unit_cost_usd" => { "sonnet_per_page" => nil, "n_sonnet" => 0, "opus_per_page" => nil, "n_opus" => 0 }
    }
  end

  def cost_out
    return ds(@cost) if @cost
    {
      "pricing_version" => PRICING_VERSION,
      "harness_computed_usd" => {
        "parse" => 0.0, "page_filter" => 0.0, "retries_direct" => 0.0, "embeddings_estimated" => 0.0,
        "l2_total_observed_cache" => 0.0, "l2_total_projected_no_cache" => 0.0
      },
      "anthropic_billed_usd" => nil, "reconciliation_delta_pct" => nil,
      "reconciliation_status" => "pending", "authoritative_source" => "anthropic_usage_cost_api"
    }
  end

  def quality_out
    return ds(@quality) if @quality
    {
      "structural_gates" => {
        "no_truncation" => nil, "manual_complete" => nil, "json_all_valid" => nil,
        "evidence_contract_ok" => nil, "retries_within_limit" => nil
      },
      "qc_review_lists" => {
        "dropped_pages" => [], "opus_pages" => [], "retried_pages" => [], "degraded_pages" => [], "sonnet_sample" => []
      },
      "human_review_verdict" => nil
    }
  end

  def commercial_out
    return ds(@commercial) if @commercial
    {
      "before_after" => {
        "counterfactual_4k_modeled_usd" => 0.0, "retries_4k_truncation_usd" => 0.0,
        "retries_4k_invalid_json_usd" => 0.0, "observed_8k_usd" => 0.0,
        "savings_abs_usd" => 0.0, "savings_pct" => 0.0,
        "note" => "4k modelado sobre las mismas páginas; no vs $9.05-10.45 de otro manual"
      },
      "projection" => {
        "L2" => { "expected_observed_n1" => 0.0, "conservative_no_cache" => 0.0,
                  "contractual_max" => self.class.contractual_max },
        "L1" => { "status" => "provisional" }, "L3" => { "status" => "provisional" }
      },
      "opus_sensitivity" => {
        "slope_usd_per_opus_point" => nil, "n_opus_pages_this_run" => 0,
        "note" => "si 0 Opus, pendiente apoyada en n=2 históricas; no fabricar Opus"
      },
      "embeddings" => "estimated",
      "verdict" => { "cost_gate_pass" => nil, "quality_gate_pass" => nil, "gate9R_l2_publishable" => nil, "next_optimization_if_fail" => nil }
    }
  end

  # Deep-stringify all hash keys to String (symbol keys → string keys for JSON)
  def ds(obj)
    case obj
    when Hash  then obj.transform_keys(&:to_s).transform_values { |v| ds(v) }
    when Array then obj.map { |v| ds(v) }
    else            obj
    end
  end

  # ─── State I/O ────────────────────────────────────────────────────────

  def load_state
    return {} unless File.exist?(state_path)
    JSON.parse(File.read(state_path))
  rescue JSON::ParserError => e
    raise AbortError, "Corrupt state.json at #{state_path}; reconcile manually and DO NOT resubmit: #{e.message}"
  end

  def write_state_atomic!(data)
    FileUtils.mkdir_p(base_dir)
    tmp = "#{state_path}.#{Process.pid}.tmp"
    File.write(tmp, JSON.generate(data.transform_keys(&:to_s)))
    File.rename(tmp, state_path)
  end

  def update_state!(updates)
    state = load_state
    write_state_atomic!(state.merge(updates.transform_keys(&:to_s)))
  end

  def append_jsonl!(path, data)
    File.open(path, "a") { |f| f.puts(JSON.generate(data)) }
  end

  def read_jsonl(path)
    return [] unless File.exist?(path)
    File.readlines(path).filter_map do |line|
      next if line.strip.empty?
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end
  end

  def write_json_file(path, data)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(data))
  end

  def load_output_json
    return nil unless File.exist?(output_path)
    JSON.parse(File.read(output_path))
  rescue JSON::ParserError
    nil
  end

  # ─── S3 / client helpers ──────────────────────────────────────────────

  def batch_client_instance
    @batch_client_instance ||= @injected_batch || ClaudeBatchClient.new(
      api_key: @env["ANTHROPIC_API_KEY"]
    )
  end

  def s3_client_instance
    @s3_client_instance ||= @injected_s3 || Aws::S3::Client.new
  end

  def s3_bucket
    @s3_bucket ||=
      @env["KNOWLEDGE_BASE_S3_BUCKET"].presence ||
      Rails.application.credentials.dig(:bedrock, :knowledge_base_s3_bucket) ||
      Rails.application.credentials.dig(:aws, :knowledge_base_s3_bucket)
  end

  def upload_to_s3!(binary, s3_key)
    raise AbortError, "KNOWLEDGE_BASE_S3_BUCKET not configured" unless s3_bucket

    @s3_input_key_to_purge = s3_key
    s3_client_instance.put_object(bucket: s3_bucket, key: s3_key, body: binary)
  end

  def purge_s3_input!
    key = @s3_input_key_to_purge || load_state["s3_input_key"]
    return unless s3_bucket && key

    s3_client_instance.delete_object(bucket: s3_bucket, key: key)
  rescue StandardError => e
    Rails.logger.warn("Gate9FinalManual: S3 purge failed — #{e.message}")
  end

  def execution_complete?
    load_state["status"].in?(%w[awaiting_human_review passed failed])
  rescue AbortError
    false
  end

  # ─── Misc helpers ─────────────────────────────────────────────────────

  def git_status
    `git status --porcelain 2>/dev/null`.strip
  rescue StandardError
    ""
  end

  def extract_text_from_message(msg)
    content = msg.respond_to?(:content) ? msg.content : []
    content.each do |block|
      type = block.respond_to?(:type) ? block.type.to_s : block.to_h["type"].to_s
      return (block.respond_to?(:text) ? block.text : block.to_h["text"]).to_s if type == "text"
    end
    ""
  end

  def usage_as_hash(usage)
    return normalize_usage(nil) unless usage
    return normalize_usage(usage) if usage.is_a?(Hash)

    normalize_usage({
      "input_tokens"                => (usage.respond_to?(:input_tokens)               ? usage.input_tokens.to_i               : 0),
      "output_tokens"               => (usage.respond_to?(:output_tokens)              ? usage.output_tokens.to_i              : 0),
      "cache_read_input_tokens"     => (usage.respond_to?(:cache_read_input_tokens)    ? usage.cache_read_input_tokens.to_i    : 0),
      "cache_creation_input_tokens" => (usage.respond_to?(:cache_creation_input_tokens) ? usage.cache_creation_input_tokens.to_i : 0)
    })
  end

  # ─── Emit helpers ─────────────────────────────────────────────────────

  def emit_halt_2!
    Rails.logger.debug "=" * 70
    Rails.logger.debug "HALT-2: Preflight OK. Set GATE9_FINAL_EXECUTE=true to proceed."
    Rails.logger.debug ""
    Rails.logger.debug { "Manifest: #{manifest_path}" }
    Rails.logger.debug JSON.pretty_generate(ds(@manifest))
    Rails.logger.debug ""
    Rails.logger.debug { "Modeled estimate (no-cache): $#{@estimate[:modeled_estimate_usd]}" }
    Rails.logger.debug JSON.pretty_generate(ds(@estimate[:breakdown]))
    Rails.logger.debug ""
    Rails.logger.debug "Confirm spend limit of workspace == GATE9_FINAL_BUDGET_USD before proceeding."
    Rails.logger.debug "=" * 70
  end

  def emit_halt_3!
    Rails.logger.debug "=" * 70
    Rails.logger.debug "HALT-3: Execution complete. Status: awaiting_human_review"
    Rails.logger.debug { "Output: #{output_path}" }
    Rails.logger.debug "Run: GATE9_FINAL_VERDICT=pass|fail bin/rails runner script/gate9_final_manual.rb"
    Rails.logger.debug "=" * 70
  end

  def emit_waiting!
    state = load_state
    Rails.logger.debug "=" * 70
    Rails.logger.debug { "WAITING: Anthropic batch remains #{state['processing_status']}. No resubmit occurred." }
    Rails.logger.debug { "Batch: #{state['batch_id']}" }
    Rails.logger.debug "Re-run the identical Phase III command to resume polling."
    Rails.logger.debug "=" * 70
  end

  def emit_verdict!(output)
    pub = output.dig("commercial", "verdict", "gate9R_l2_publishable")
    Rails.logger.debug "=" * 70
    Rails.logger.debug { "GATE 9R L2: #{pub ? 'PASS — publicable: costo observado, n=1' : 'FAIL'}" }
    Rails.logger.debug { "Human review : #{output.dig('quality', 'human_review_verdict')}" }
    Rails.logger.debug { "Cost gate    : #{output.dig('commercial', 'verdict', 'cost_gate_pass')}" }
    Rails.logger.debug { "Quality gate : #{output.dig('commercial', 'verdict', 'quality_gate_pass')}" }
    Rails.logger.debug "=" * 70
  end
end
