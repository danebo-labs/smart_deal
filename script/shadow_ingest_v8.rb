# frozen_string_literal: true

# Shadow ingest A/B for contract v8 (docs/rag/plan_conocimiento_visual.md, Fase 7).
#
# Writes a SECOND KbDocument under bulk_chunks/<account>/<uid_nuevo>/ via
# ingestion_path "manual_batch_v1". The production prefix
# bulk_chunks/1/b61f5d54-ff42-414a-97b7-01682d16f4b5/ (97 chunks) is never
# touched.
#
# ── I-31 gap — how this script closes it ─────────────────────────────────────
# Fase 4 recorded that ManualBatchIngestionService did not thread topology
# edges across the Anthropic Batch API boundary, so a naïve reuse would index
# zero TOPOLOGY_EDGE records even with the layout flag on. I-34/I-37 already
# built the persistence layer: submit! derives edges while page binaries are
# still on disk and returns them as page_topology_edges; SubmitManualBatchJob
# stores that hash on the web_manual_batches row; IngestManualBatchResultsJob
# reads it back into BatchResultsParserService. This script reuses that path
# (ManualBatchIngestionService → WebManualBatch#page_topology_edges → parse).
# It does NOT re-derive edges in the script body and does NOT rebuild the
# persistence layer.
#
# ── Hard contract ────────────────────────────────────────────────────────────
# - NEVER deletes. No S3 object/prefix removal calls of any kind, and the
#   S3 adapter passed to BatchResultsParserService does not expose the
#   parser's retry-clear entry point (which would otherwise fire on the new
#   prefix).
# - ACCOUNT_ID from ENV (never a hardcoded account literal).
# - SHADOW_INGEST_CONFIRM=1 required.
# - INGESTION_LAYOUT_DIGEST_ENABLED is forced on (T1 edges). Vision is required
#   on by the caller; RELATIONS and ZOOM_TILES are left untouched (default off).
# - SHADOW_INGEST_PAGES=3,17,… limits the submit to those 1-indexed pages.
# - The KB target comes from ENV when the operator set it; the production
#   constants below are only the fallback. Whatever wins is printed BEFORE the
#   first write, with a warning when it is not the expected production target.
#
# ── Known limits of this run, printed at runtime so nobody rediscovers them ──
# - T2 (vision) contributes NOTHING to the written chunks while
#   INGESTION_VISION_TIER_RELATIONS_ENABLED is off. `drop_relations` returns []
#   (vision_topology_extractor.rb:323-326) and `topology_for_page` discards
#   `Result#components` (manual_batch_ingestion_service.rb:194-198) — the only
#   reader of `.components` in the repo is script/gate_b/run.rb. So the vision
#   spend buys measurement, not indexed content. Registered as a finding, NOT
#   fixed here: threading components into the chunk is Fase 5 code, not Fase 7.
#   The honest alternative is already written in the plan (Fase 7, :1456-1457):
#   run with INGESTION_VISION_TIER_ENABLED off and skip the call.
# - The chunk prediction assumes ONE model chunk per page. The pipeline allows
#   N per page (chunk_merger_service.rb:96, chunk_p<page>_<ordinal> keys), so
#   `predicted_chunks` is a floor, not an equality. Read the delta as a floor.
#
# Usage:
#   SHADOW_INGEST_CONFIRM=1 ACCOUNT_ID=1 SHADOW_INGEST_PAGES=3,17,63,78,93,97 \
#     INGESTION_VISION_TIER_ENABLED=true \
#     bin/rails runner script/shadow_ingest_v8.rb
#
# ACCOUNT_ID is mandatory and has no default — the runbook commands in
# docs/rag/plan_conocimiento_visual.md omitted it and would abort here.

require "digest"
require "securerandom"
require "set"

class ShadowIngestV8
  include AwsClientInitializer

  FILENAME = "SEGURIDADES 1.1-1.pdf"
  EXPECTED_SHA = "1843b13d81ae8756fef7dcbda72d287790a79e656472b6716e9752d9474496d1"
  # Production identity — read-only reference. Never written, never deleted.
  PRODUCTION_DOCUMENT_UID = "b61f5d54-ff42-414a-97b7-01682d16f4b5"
  BASELINE_CHUNK_COUNT = 97
  TOPOLOGY_EDGE_CHUNK_LIMIT = BatchResultsParserService::TOPOLOGY_EDGE_CHUNK_LIMIT
  INGESTION_PATH = BatchResultsParserService::MANUAL_BATCH_INGESTION_PATH
  DEFAULT_PDF_PATH = Rails.root.join("tmp/seguridades_reingest_2026-07-25/original.pdf")
  POLL_INTERVAL_SECONDS = 30
  MAX_BATCH_POLLS = 240 # ~2h at 30s
  KB_POLL_INTERVAL_SECONDS = 10
  MAX_KB_POLLS = 90 # ~15m at 10s, matching BedrockIngestionJob::TIMEOUT
  # Cheapest direct-API model, used only to prove the key works and the account
  # has credit before anything is created. One token, ~$0.000002.
  PREFLIGHT_MODEL = "claude-haiku-4-5-20251001"

  # Where Fase 7 is meant to land. Used as a FALLBACK when the operator's
  # environment says nothing, and as the expectation the resolved target is
  # compared against — never as a silent override of an explicit ENV.
  EXPECTED_TARGETS = {
    "KNOWLEDGE_BASE_S3_BUCKET"    => "multimodal-source-destination",
    "BEDROCK_KNOWLEDGE_BASE_ID"   => "Y7RZWMFJSR",
    "BEDROCK_BULK_DATA_SOURCE_ID" => "PJ0N58DMHG",
    "BEDROCK_DATA_SOURCE_ID"      => "PJ0N58DMHG"
  }.freeze

  class Error < StandardError; end
  class ConfirmError < Error; end
  class ConfigError < Error; end

  # S3 façade that can only upload. BatchResultsParserService clears a prefix
  # before rewrite when that clearing method exists on the client — we omit it
  # so the shadow path cannot remove anything, empty prefix or not.
  class WriteOnlyS3
    def initialize(inner)
      @inner = inner
    end

    delegate :upload_text, :bucket_name, to: :@inner
  end

  # Same submit! path as production, with an optional page allow-list so the
  # 6-page rehearsal does not bill vision for the other 92 pages. Topology
  # derivation still runs inside ManualBatchIngestionService#topology_for_page
  # and still returns page_topology_edges.
  class PageFilteredManualBatchIngestion < ManualBatchIngestionService
    def initialize(only_pages: nil, batch_client: nil)
      @only_pages = only_pages&.map(&:to_i)&.to_set
      super(batch_client: batch_client)
    end

    private

    def apply_filters(pages, filter_results)
      kept = super
      return kept if @only_pages.nil?

      kept.filter_map do |page|
        if @only_pages.include?(page.number)
          page
        else
          page.cleanup
          nil
        end
      end
    end
  end

  def initialize(
    env: ENV,
    s3: nil,
    batch_client: nil,
    ingestion_service: nil,
    sleeper: nil,
    stdout: $stdout,
    pdf_path: nil,
    document_uid_generator: nil
  )
    @env = env
    @s3 = s3
    @batch_client = batch_client
    @ingestion_service = ingestion_service
    @sleeper = sleeper || ->(seconds) { sleep(seconds) }
    @stdout = stdout
    @pdf_path = pdf_path
    @document_uid_generator = document_uid_generator || -> { SecureRandom.uuid }
  end

  def run!
    assert_confirm!
    account_id = account_id_from_env!
    assert_vision_flag!
    enable_layout_digest!
    point_at_production_kb!

    binary = load_and_verify_pdf!
    preflight!(account_id: account_id, binary: binary)
    page_allowlist = parse_pages_env

    plan = predict_chunk_plan(binary, page_allowlist: page_allowlist)
    print_chunk_plan(plan)

    document_uid = fresh_document_uid!
    s3_key = upload_original!(binary, account_id: account_id, document_uid: document_uid)
    kb_doc = create_kb_document!(account_id: account_id, document_uid: document_uid, s3_key: s3_key)

    sha256 = Digest::SHA256.hexdigest(binary)
    batch = create_web_manual_batch!(
      account_id: account_id,
      kb_doc: kb_doc,
      s3_key: s3_key,
      sha256: sha256
    )

    submit_result = submit_batch!(
      binary: binary,
      sha256: sha256,
      s3_key: s3_key,
      page_allowlist: page_allowlist
    )
    persist_batch_submission!(batch, submit_result)

    wait_for_batches!(submit_result.fetch(:batch_ids))
    chunk_asset = parse_and_write_chunks!(batch, submit_result)

    sync_knowledge_base!(
      chunk_asset,
      batch: batch,
      account_id: account_id,
      document_uid: document_uid,
      kb_doc_id: kb_doc.id
    )

    print_summary(
      account_id: account_id,
      document_uid: document_uid,
      chunk_asset: chunk_asset,
      plan: plan,
      page_topology_edges: submit_result[:page_topology_edges]
    )

    {
      account_id: account_id,
      document_uid: document_uid,
      chunks_count: chunk_asset.chunks_count,
      chunks_s3_prefix: chunk_asset.chunks_s3_prefix,
      page_topology_edges: submit_result[:page_topology_edges],
      plan: plan
    }
  end

  # Pure prediction used before any S3/KB write. Counts T1 edges only — vision
  # relations stay off, so they cannot change the chunk tally (I-39/I-41):
  # `drop_relations` returns [] outright (vision_topology_extractor.rb:323-326).
  #
  # This is a FLOOR, not an equality. `chunks_for_edge_count` assumes one model
  # chunk per page; the pipeline allows several, and PageRelevanceFilter may
  # still drop a target page. Both assumptions are printed with the plan so the
  # go/no-go step reads a mismatch as "explain it", not as "the script lied".
  def predict_chunk_plan(binary, page_allowlist: nil, edge_counter: nil)
    splitter = PdfPageSplitterService.new(binary)
    total_pages = splitter.page_count
    raise ConfigError, "PDF has zero pages" if total_pages.zero?

    targets = page_allowlist.presence || (1..total_pages).to_a
    unknown = targets.reject { |n| n.between?(1, total_pages) }
    raise ConfigError, "SHADOW_INGEST_PAGES out of range #{unknown.inspect} (doc has #{total_pages})" if unknown.any?

    edge_counts = {}
    counter = edge_counter || method(:count_t1_edges)

    splitter.each_page do |page_number, page_binary|
      next unless targets.include?(page_number)

      edge_counts[page_number] = counter.call(page_binary, page_number)
    end

    chunks_per_page = edge_counts.transform_values { |n| chunks_for_edge_count(n) }
    predicted = chunks_per_page.values.sum
    overflow = predicted - chunks_per_page.size

    reasons = []
    if page_allowlist.present?
      reasons << "SHADOW_INGEST_PAGES selects #{targets.size} of #{total_pages} pages " \
                 "(baseline #{BASELINE_CHUNK_COUNT} is the full filtered document)"
    else
      reasons << "full document has #{total_pages} pages; production kept " \
                 "#{BASELINE_CHUNK_COUNT} after PageRelevanceFilter"
    end
    reasons << "FLOOR, not equality — assumes 1 model chunk per page. The pipeline " \
               "allows several (chunk_p<page>_<ordinal> keys), so the written count may " \
               "be higher without anything being wrong"
    reasons << "assumes every target page survives PageRelevanceFilter; a dropped page " \
               "lowers the written count"
    reasons << if overflow.positive?
      "topology overflow adds #{overflow} sibling chunk(s) " \
        "(cap #{TOPOLOGY_EDGE_CHUNK_LIMIT} edges/chunk)"
    else
      "topology overflow inactive (max edges/page in this plan: " \
        "#{edge_counts.values.max.to_i}; cap #{TOPOLOGY_EDGE_CHUNK_LIMIT})"
    end

    {
      total_pages: total_pages,
      target_pages: targets,
      edge_counts: edge_counts,
      chunks_per_page: chunks_per_page,
      predicted_chunks: predicted,
      overflow_siblings: overflow,
      baseline_chunks: BASELINE_CHUNK_COUNT,
      delta_vs_baseline: predicted - BASELINE_CHUNK_COUNT,
      reasons: reasons
    }
  end

  def chunks_for_edge_count(edge_count)
    [ (edge_count.to_f / TOPOLOGY_EDGE_CHUNK_LIMIT).ceil, 1 ].max
  end

  def parse_pages_env
    raw = @env["SHADOW_INGEST_PAGES"].to_s.strip
    return nil if raw.empty?

    pages = raw.split(",").map { |part| Integer(part.strip) }
    raise ConfigError, "SHADOW_INGEST_PAGES is empty after parsing" if pages.empty?

    pages.uniq.sort
  rescue ArgumentError
    raise ConfigError, "SHADOW_INGEST_PAGES must be comma-separated integers (got #{raw.inspect})"
  end

  def account_id_from_env!
    raw = @env["ACCOUNT_ID"].to_s.strip
    raise ConfigError, "Set ACCOUNT_ID to the owning account (integer). Do not hardcode it." if raw.empty?

    Integer(raw)
  rescue ArgumentError
    raise ConfigError, "ACCOUNT_ID must be an integer (got #{raw.inspect})"
  end

  private

  def assert_confirm!
    return if @env["SHADOW_INGEST_CONFIRM"] == "1"

    raise ConfirmError,
          "Set SHADOW_INGEST_CONFIRM=1 to run (paid Anthropic calls + writes a new KbDocument)"
  end

  def assert_vision_flag!
    return if @env["INGESTION_VISION_TIER_ENABLED"] == "true"

    raise ConfigError,
          "Set INGESTION_VISION_TIER_ENABLED=true (decision #6 option a). " \
          "Leave INGESTION_VISION_TIER_RELATIONS_ENABLED and " \
          "INGESTION_VISION_TIER_ZOOM_TILES untouched (off)."
  end

  def enable_layout_digest!
    # T1 edges only derive when the layout flag is on (ManualBatchIngestionService
    # #topology_for_page). Decision #6 authorises those 19 edges; the runbook
    # only exports the vision flag, so this script turns layout on explicitly.
    # Write through to process ENV: IngestionLayoutFlag reads ENV, not @env.
    set_env!("INGESTION_LAYOUT_DIGEST_ENABLED", "true")
  end

  # Resolves where this run writes. An explicit ENV wins — clobbering it would
  # silently redirect a staging shell at production. The Fase 7 constants are
  # the fallback, and any divergence is recorded so #print_chunk_plan can shout
  # about it before the first byte is written.
  def point_at_production_kb!
    @targets = EXPECTED_TARGETS.to_h do |key, expected|
      resolved = @env[key].presence || expected
      set_env!(key, resolved)
      [ key, { resolved: resolved, expected: expected } ]
    end
    set_env!("AWS_REGION", @env["AWS_REGION"].presence || "us-east-1")
    @targets["AWS_REGION"] = { resolved: @env["AWS_REGION"], expected: @env["AWS_REGION"] }
  end

  def target(key)
    @targets&.dig(key, :resolved)
  end

  def off_target_keys
    (@targets || {}).select { |_key, pair| pair[:resolved] != pair[:expected] }.keys
  end

  def set_env!(key, value)
    @env[key] = value
    # IngestionLayoutFlag / AWS clients read process ENV, not the injectable hash.
    ENV[key] = value
  end

  # Everything that can be wrong is checked HERE, before the first row or byte
  # is created. A failure at this point costs nothing and leaves no orphan
  # KbDocument, no 36 MB upload and no paid batch. Each message says what to do.
  def preflight!(account_id:, binary:)
    @stdout.puts "=" * 80
    @stdout.puts "Preflight — nothing is created until every check below passes"
    check_pdf!(binary)
    check_database!(account_id)
    check_s3_baseline!(account_id)
    check_bedrock!
    check_anthropic!
    @stdout.puts "  ✓ preflight passed — no web server or Solid Queue worker is needed for this run"
    @stdout.puts "=" * 80
  end

  def check_pdf!(binary)
    @stdout.puts "  ✓ PDF        #{(binary.bytesize / 1_048_576.0).round(1)} MB, sha256 #{EXPECTED_SHA[0, 12]}…"
  end

  # The decisive check that RAILS_ENV alone cannot make: this database must be
  # the one the pilot reads. If the production SEGURIDADES KbDocument is not
  # here, the shadow document would be written to S3 and Bedrock but be
  # invisible to the app and to the PASO 5 rubrics.
  def check_database!(account_id)
    config = ActiveRecord::Base.connection_db_config
    where = "#{config.database} @ #{config.configuration_hash[:host] || 'localhost'}"
    ActiveRecord::Base.connection.execute("SELECT 1")
    @stdout.puts "  ✓ database   #{where} (RAILS_ENV=#{Rails.env})"

    unless Account.exists?(id: account_id)
      raise ConfigError, "ACCOUNT_ID=#{account_id} does not exist in #{where}. " \
                         "Wrong account, or wrong database."
    end

    prod = KbDocument.find_by(account_id: account_id, document_uid: PRODUCTION_DOCUMENT_UID)
    if prod.nil?
      raise ConfigError, <<~MSG.strip
        This database has no KbDocument #{PRODUCTION_DOCUMENT_UID} for account #{account_id},
        so it is NOT the database the pilot reads (#{where}).
        Writing here would put the chunks in production S3/Bedrock while the KbDocument row
        stays in a database nobody queries — the shadow document would be invisible to the app
        and unscorable in PASO 5.
        Fix: run with the pilot's RAILS_ENV and DB_HOST/DB_NAME/DB_USERNAME/DB_PASSWORD, or run
        this on the host where the application lives.
      MSG
    end
    @stdout.puts "  ✓ pilot DB   production KbDocument ##{prod.id} is here, so this is the right database"
  end

  # Proves S3 credentials, the bucket, AND that the 97 chunks this run must not
  # disturb are present right now. The number is the honest before-picture for
  # the report.
  def check_s3_baseline!(account_id)
    prefix = format("bulk_chunks/%s/%s", account_id, PRODUCTION_DOCUMENT_UID)
    keys = s3_service.list_keys(prefix: prefix)
    if keys.empty?
      raise ConfigError, <<~MSG.strip
        Nothing found at s3://#{target('KNOWLEDGE_BASE_S3_BUCKET')}/#{prefix}.
        Either the AWS credentials cannot read the bucket, or this is not the bucket that
        holds the 97 production chunks. Check AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (or the
        bedrock bearer token) and KNOWLEDGE_BASE_S3_BUCKET.
      MSG
    end

    chunks = keys.count { |key| key.end_with?(".txt") }
    @stdout.puts "  ✓ S3         #{chunks} production chunks at #{prefix} (baseline #{BASELINE_CHUNK_COUNT})"
    return if chunks == BASELINE_CHUNK_COUNT

    @stdout.puts "    ⚠️  that is not #{BASELINE_CHUNK_COUNT}. Nothing here deletes, so this predates " \
                 "the run — but note it in the report before continuing."
  end

  def check_bedrock!
    require "aws-sdk-bedrockagent"
    client = Aws::BedrockAgent::Client.new(build_aws_client_options)
    kb_id = target("BEDROCK_KNOWLEDGE_BASE_ID")
    ds_id = target("BEDROCK_BULK_DATA_SOURCE_ID")
    kb = client.get_knowledge_base(knowledge_base_id: kb_id).knowledge_base
    ds = client.get_data_source(knowledge_base_id: kb_id, data_source_id: ds_id).data_source
    @stdout.puts "  ✓ Bedrock    KB #{kb.name} (#{kb.status}) · data source #{ds.name} (#{ds.status})"
  rescue ConfigError
    raise
  rescue StandardError => e
    raise ConfigError, "Bedrock is unreachable: #{e.class}: #{e.message}. " \
                       "Check the AWS credentials and BEDROCK_KNOWLEDGE_BASE_ID / " \
                       "BEDROCK_BULK_DATA_SOURCE_ID."
  end

  # The one failure this script used to hit late and expensively: the Anthropic
  # account running out of credit. A one-token probe surfaces it now, for
  # ~$0.000002, instead of after the KbDocument exists and the PDF is uploaded.
  def check_anthropic!
    key = @env["ANTHROPIC_API_KEY"].presence || Rails.application.credentials.dig(:anthropic, :api_key)
    raise ConfigError, "ANTHROPIC_API_KEY is not set (nor in credentials)." if key.blank?

    Anthropic::Client.new(api_key: key).messages.create(
      model: PREFLIGHT_MODEL,
      max_tokens: 1,
      messages: [ { role: "user", content: "." } ]
    )
    @stdout.puts "  ✓ Anthropic  key valid and the account has credit (1-token probe)"
  rescue ConfigError
    raise
  rescue StandardError => e
    if e.message.to_s.downcase.include?("credit balance")
      raise ConfigError, <<~MSG.strip
        The Anthropic account has no credit, so the chunking batch would fail after this script
        had already created the KbDocument and uploaded the PDF. Top up and re-run.
        Original error: #{e.message}
      MSG
    end
    raise ConfigError, "Anthropic preflight failed: #{e.class}: #{e.message}"
  end

  def load_and_verify_pdf!
    path = Pathname(@pdf_path || @env["SHADOW_INGEST_PDF"].presence || DEFAULT_PDF_PATH)
    raise ConfigError, "Local PDF not found at #{path}" unless path.exist?

    binary = path.binread
    sha = Digest::SHA256.hexdigest(binary)
    raise ConfigError, "SHA-256 mismatch: expected #{EXPECTED_SHA}, got #{sha}" unless sha == EXPECTED_SHA

    binary
  end

  def count_t1_edges(page_binary, page_number)
    layout = PdfLayoutExtractor.extract(page_binary, page_number: page_number)
    TopologyEdgeDeriver.derive(layout).size
  end

  def print_chunk_plan(plan)
    @stdout.puts "=" * 80
    @stdout.puts "Shadow ingest v8 — chunk plan (BEFORE any write)"
    @stdout.puts "  baseline production chunks: #{plan[:baseline_chunks]}"
    @stdout.puts "  document pages:             #{plan[:total_pages]}"
    @stdout.puts "  target pages this run:      #{plan[:target_pages].size} → #{plan[:target_pages].inspect}"
    @stdout.puts "  predicted chunks to create: #{plan[:predicted_chunks]} (floor — see assumptions)"
    @stdout.puts "  overflow sibling chunks:    #{plan[:overflow_siblings]}"
    @stdout.puts "  delta vs baseline 97:       #{plan[:delta_vs_baseline]}"
    @stdout.puts "  why it differs from 97, and what the number assumes:"
    plan[:reasons].each { |reason| @stdout.puts "    - #{reason}" }
    @stdout.puts "  ingestion_path:             #{INGESTION_PATH}"
    @stdout.puts "  topology via:               web_manual_batches.page_topology_edges (I-37)"
    print_expected_edges(plan)
    print_targets
    print_vision_notice
    @stdout.puts "=" * 80
  end

  # PASO 4 reads chunk bodies looking for TOPOLOGY_EDGE. Only 18 of the 98 pages
  # carry a T1 edge, so an empty body is expected on the rest — print which
  # pages should have one so absence is not misread as failure.
  def print_expected_edges(plan)
    counts = (plan[:edge_counts] || {}).select { |_page, n| n.to_i.positive? }
    @stdout.puts "  T1 edges predicted per page (TOPOLOGY_EDGE should appear ONLY here):"
    if counts.empty?
      @stdout.puts "    - none: no target page carries a T1 edge, so no chunk body will " \
                   "contain TOPOLOGY_EDGE. That is not a failure."
    else
      @stdout.puts "    - #{counts.map { |page, n| "p#{page}=#{n}" }.join(', ')} " \
                   "(#{counts.values.sum} edges over #{counts.size} pages)"
      @stdout.puts "    - every other target page will have no TOPOLOGY_EDGE. Expected."
    end
  end

  def print_targets
    return if @targets.blank?

    @stdout.puts "  writing to:"
    @targets.each { |key, pair| @stdout.puts "    #{key} = #{pair[:resolved]}" }
    stray = off_target_keys
    return if stray.empty?

    @stdout.puts "  ⚠️  NOT the Fase 7 target — your environment overrides #{stray.join(', ')}."
    @stdout.puts "      Expected: #{stray.map { |k| "#{k}=#{EXPECTED_TARGETS[k]}" }.join(', ')}"
    @stdout.puts "      Ctrl-C now if this shell is not pointing where you think it is."
  end

  def print_vision_notice
    return unless @env["INGESTION_VISION_TIER_ENABLED"] == "true"
    return if IngestionVisionFlag.relations_enabled?

    @stdout.puts "  ⚠️  vision (T2) is ON and will be billed, but contributes ZERO records:"
    @stdout.puts "      relations are dropped wholesale (drop_relations → []), and " \
                 "documented_components is discarded by ManualBatchIngestionService."
    @stdout.puts "      The chunks written here are T1-only. Cost buys measurement, not content."
    @stdout.puts "      To skip the spend: unset INGESTION_VISION_TIER_ENABLED (plan Fase 7, :1456)."
  end

  def fresh_document_uid!
    uid = @document_uid_generator.call.to_s
    raise ConfigError, "document_uid generator returned blank" if uid.blank?
    if uid == PRODUCTION_DOCUMENT_UID
      raise ConfigError, "refusing to reuse production document_uid #{PRODUCTION_DOCUMENT_UID}"
    end

    uid
  end

  def s3_service
    @s3 ||= S3DocumentsService.new
  end

  def batch_client
    @batch_client ||= ClaudeBatchClient.new
  end

  def upload_original!(binary, account_id:, document_uid:)
    key = s3_service.upload_file(
      FILENAME,
      binary,
      "application/pdf",
      account_id: account_id,
      document_uid: document_uid
    )
    raise Error, "S3 upload of original PDF failed" if key.blank?

    key
  end

  def create_kb_document!(account_id:, document_uid:, s3_key:)
    KbDocument.create!(
      account_id: account_id,
      document_uid: document_uid,
      s3_key: s3_key,
      display_name: FILENAME.delete_suffix(".pdf"),
      aliases: []
    )
  end

  def create_web_manual_batch!(account_id:, kb_doc:, s3_key:, sha256:)
    WebManualBatch.create!(
      account_id: account_id,
      kb_document_id: kb_doc.id,
      s3_key: s3_key,
      filename: FILENAME,
      sha256: sha256,
      content_type: "application/pdf",
      ingestion_contract_version: BatchChunkingPrompt::INGESTION_CONTRACT_VERSION,
      status: "pending",
      locale: "es"
    )
  end

  def submit_batch!(binary:, sha256:, s3_key:, page_allowlist:)
    service = @ingestion_service || PageFilteredManualBatchIngestion.new(
      only_pages: page_allowlist,
      batch_client: batch_client
    )
    result = service.submit!(
      binary: binary,
      filename: FILENAME,
      sha256: sha256,
      s3_key: s3_key,
      locale: "es"
    )
    if result[:batch_id].blank?
      raise Error, "No pages kept after filter/allow-list — nothing to ingest"
    end

    result
  end

  def persist_batch_submission!(batch, result)
    batch.update!(
      claude_batch_id: result[:batch_id],
      claude_batch_ids: Array(result[:batch_ids]).presence || Array(result[:batch_id]).compact,
      status: "submitted",
      page_customs: result[:page_customs] || {},
      kept_pages: result[:kept_pages] || [],
      total_pages: result[:total_pages],
      # I-37 transport: edges survive the Batch round trip on this row.
      page_topology_edges: result[:page_topology_edges] || {},
      submitted_at: Time.current,
      error_message: nil
    )
  end

  def wait_for_batches!(batch_ids)
    ids = Array(batch_ids).compact
    raise Error, "No batch ids to poll" if ids.empty?

    MAX_BATCH_POLLS.times do
      statuses = ids.index_with { |id| batch_client.retrieve(batch_id: id).processing_status.to_s }
      return if statuses.values.all? { |status| status == "ended" }

      unexpected = statuses.reject { |_id, status| status.in?(%w[in_progress ended]) }
      if unexpected.any?
        raise Error, "Unexpected batch status: #{unexpected.map { |id, s| "#{id}=#{s}" }.join(', ')}"
      end

      @sleeper.call(POLL_INTERVAL_SECONDS)
    end

    raise Error, "Batches still in_progress after #{MAX_BATCH_POLLS} polls"
  end

  def parse_and_write_chunks!(batch, submit_result)
    page_customs = (submit_result[:page_customs] || {}).transform_keys(&:to_i)
    customs_to_page = page_customs.invert
    page_edges = batch.page_topology_edges.to_h.transform_keys(&:to_i)

    page_results = []
    Array(submit_result[:batch_ids]).each do |batch_id|
      batch_client.results_each(batch_id: batch_id) do |result|
        page_num = customs_to_page[result.custom_id]
        next unless page_num
        next unless result.result.type.to_s == "succeeded"

        message = result.result.message
        page_results << {
          page_number: page_num.to_i,
          text: extract_text(message),
          model: message.model.to_s,
          stop_reason: (message.stop_reason.to_s if message.respond_to?(:stop_reason)),
          topology_edges: Array(page_edges[page_num.to_i])
        }
      end
    end
    raise Error, "No succeeded batch results" if page_results.empty?

    page_results.sort_by! { |row| row[:page_number] }
    merged_json = ChunkMergerService.merge(page_results)

    asset = ChunkAsset.new(
      filename: FILENAME,
      sha256: batch.sha256,
      s3_key: batch.s3_key,
      content_type: "application/pdf"
    )
    chunk_asset = BatchResultsParserService.new(s3_service: WriteOnlyS3.new(s3_service)).call(
      asset: asset,
      raw_json: merged_json,
      ingestion_path: INGESTION_PATH,
      account_id: batch.account_id,
      document_uid: batch.kb_document.document_uid
    )

    batch.update!(
      status: "parsed",
      canonical_name: chunk_asset.canonical_name.to_s,
      aliases: Array(chunk_asset.aliases),
      chunks_count: chunk_asset.chunks_count,
      chunks_s3_prefix: chunk_asset.chunks_s3_prefix,
      error_message: nil
    )

    chunk_asset
  end

  def extract_text(message)
    content = message.respond_to?(:content) ? message.content : Array(message["content"])
    content.each do |block|
      type = block.respond_to?(:type) ? block.type : block["type"]
      return (block.respond_to?(:text) ? block.text : block["text"]) if type.to_s == "text"
    end
    raise Error, "No text block in batch result message"
  end

  def sync_knowledge_base!(chunk_asset, batch:, account_id:, document_uid:, kb_doc_id:)
    sync_result = BulkKbSyncService.new.sync!(
      uploaded_filenames: [ FILENAME ],
      locale: "es"
    )
    raise Error, "Bedrock sync did not start" if sync_result.blank?

    batch.update!(status: "syncing")
    status = poll_ingestion_job!(sync_result)
    raise Error, "KB ingestion job ended with status #{status.inspect}" unless status == "COMPLETE"

    # perform_now, NOT perform_later behind a process-wide inline adapter.
    # Flipping the adapter for the whole process also turns
    # BedrockIngestionJob's `set(wait:).perform_later` re-enqueue into an
    # immediate recursive call, and would silently swallow every other job the
    # process might enqueue. This runs exactly the one job we want, here.
    #
    # `web_manual_batch_id` is what flips the row to "complete" via
    # #mark_web_manual_batch_complete; without it the shadow batch stays at
    # "parsed" forever. Metadata mirrors IngestManualBatchResultsJob:174-184.
    BedrockIngestionJob.perform_now(
      sync_result[:job_id],
      [ FILENAME ],
      kb_id: sync_result[:kb_id],
      data_source_id: sync_result[:data_source_id],
      account_id: account_id,
      document_uid: document_uid,
      kb_document_ids: [ kb_doc_id ],
      web_v1_metadata: [ {
        "filename"            => FILENAME,
        "canonical_name"      => chunk_asset.canonical_name.to_s,
        "aliases"             => Array(chunk_asset.aliases),
        "summary"             => chunk_asset.summary.to_s.presence,
        "companion_offer"     => chunk_asset.companion_offer.to_s.presence,
        "chunks_s3_prefix"    => chunk_asset.chunks_s3_prefix.to_s,
        "partial_pages"       => Array(chunk_asset.degraded_pages),
        "processing_scope"    => "full_manual",
        "web_manual_batch_id" => batch.id
      } ],
      locale: "es"
    )

    batch.reload
    status
  end

  # Same client construction as every other Bedrock caller in the app
  # (AwsClientInitializer: bearer token or key pair, from ENV or credentials).
  # A bare Aws::BedrockAgent::Client.new(region:) only works when credentials
  # happen to be in the default chain — a bad way to discover an auth problem
  # right after paying for the batch.
  def poll_ingestion_job!(sync_result)
    poller = IngestionStatusService.new(
      kb_id: sync_result[:kb_id],
      data_source_id: sync_result[:data_source_id]
    )
    status = nil
    @stdout.print "Polling ingestion job #{sync_result[:job_id]}: "
    MAX_KB_POLLS.times do
      status = poller.job_status(sync_result[:job_id])
      @stdout.print "#{status || 'UNKNOWN'} "
      break unless status.nil? || status.in?(%w[STARTING IN_PROGRESS])

      @sleeper.call(KB_POLL_INTERVAL_SECONDS)
    end
    @stdout.puts
    status
  end

  def print_summary(account_id:, document_uid:, chunk_asset:, plan:, page_topology_edges:)
    edge_pages = page_topology_edges.to_h.count { |_page, edges| Array(edges).any? }
    edge_total = page_topology_edges.to_h.sum { |_page, edges| Array(edges).size }

    @stdout.puts
    @stdout.puts "RESULT: shadow document written (production #{PRODUCTION_DOCUMENT_UID} untouched)"
    @stdout.puts "  account_id:          #{account_id}"
    @stdout.puts "  document_uid:        #{document_uid}"
    @stdout.puts "  chunks_s3_prefix:    #{chunk_asset.chunks_s3_prefix}"
    @stdout.puts "  chunks_written:      #{chunk_asset.chunks_count} " \
                 "(predicted floor #{plan[:predicted_chunks]})"
    if chunk_asset.chunks_count.to_i > plan[:predicted_chunks].to_i
      @stdout.puts "                       ↑ above the floor: at least one page produced " \
                   "more than one model chunk. Expected, not a mismatch."
    end
    @stdout.puts "  pages with edges:    #{edge_pages}"
    @stdout.puts "  topology edges:      #{edge_total}"
    per_page = page_topology_edges.to_h.filter_map do |page, edges|
      "p#{page}=#{Array(edges).size}" if Array(edges).any?
    end
    @stdout.puts "  edges per page:      #{per_page.presence&.join(', ') || 'none'}"
    @stdout.puts "  ingestion_path:      #{INGESTION_PATH}"
    @stdout.puts
    @stdout.puts "  NEXT (PASO 4): read the bodies, do not trust this log."
    @stdout.puts "    aws s3 ls s3://#{target('KNOWLEDGE_BASE_S3_BUCKET')}/#{chunk_asset.chunks_s3_prefix}/"
    @stdout.puts "    TOPOLOGY_EDGE must appear in the chunks of #{per_page.presence&.join(', ') || '(no page)'} " \
                 "and in no other."
  end
end

unless ENV["SHADOW_INGEST_LIBRARY_ONLY"] == "1"
  # The process-wide ActiveJob adapter is deliberately left alone. Forcing it
  # inline would also turn BedrockIngestionJob's `set(wait:)` re-enqueue into an
  # immediate recursive call. The only job this script needs is that one, and
  # #sync_knowledge_base! runs it with perform_now. TrackIngestionUsageJob,
  # enqueued from inside it, goes to Solid Queue as it does in production — it
  # is metrics, it can wait for a worker.
  begin
    ShadowIngestV8.new.run!
  rescue ShadowIngestV8::ConfirmError, ShadowIngestV8::ConfigError => e
    abort(e.message)
  end
end
