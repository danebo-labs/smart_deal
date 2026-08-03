# frozen_string_literal: true

require "test_helper"
require "ostruct"
require "stringio"

ENV["SHADOW_INGEST_LIBRARY_ONLY"] = "1"
require Rails.root.join("script/shadow_ingest_v8")
ENV.delete("SHADOW_INGEST_LIBRARY_ONLY")

class ShadowIngestV8Test < ActiveSupport::TestCase
  parallelize(workers: 1)

  SOURCE = Rails.root.join("script/shadow_ingest_v8.rb").read.freeze

  FakeBatchStatus = Struct.new(:processing_status, keyword_init: true)

  class FakeBatchClient
    attr_reader :submitted_requests, :retrieve_calls

    def initialize(status: "ended", results: [])
      @submitted_requests = []
      @retrieve_calls = []
      @status = status
      @results = results
      @batch_id_counter = 0
    end

    def submit_batch(requests:)
      @submitted_requests.concat(requests)
      @batch_id_counter += 1
      OpenStruct.new(id: "msgbatch_shadow_#{@batch_id_counter}")
    end

    def retrieve(batch_id:)
      @retrieve_calls << batch_id
      FakeBatchStatus.new(processing_status: @status)
    end

    def results_each(batch_id:)
      @results.each { |result| yield result }
    end
  end

  class FakeS3
    attr_reader :uploads, :put_objects, :bucket_name

    def initialize
      @uploads = {}
      @put_objects = []
      @bucket_name = "test-bucket"
    end

    def upload_file(filename, binary, content_type, account_id: nil, document_uid: nil)
      key = "uploads/#{account_id}/#{document_uid}/original.pdf"
      @put_objects << { key: key, body: binary, content_type: content_type, filename: filename }
      key
    end

    def upload_text(key, content)
      @uploads[key] = content
      key
    end
  end

  test "source never calls S3 delete APIs" do
    %w[delete_object delete_prefix delete_objects].each do |method_name|
      assert_nil SOURCE.match(/\b#{Regexp.escape(method_name)}\b/),
                 "shadow_ingest_v8.rb must not reference #{method_name}"
    end
  end

  test "WriteOnlyS3 does not respond to delete_prefix so the parser cannot clear" do
    inner = FakeS3.new
    wrapper = ShadowIngestV8::WriteOnlyS3.new(inner)

    assert_not wrapper.respond_to?(:delete_prefix)
    assert_not wrapper.respond_to?(:delete_object)
    assert_not wrapper.respond_to?(:delete_objects)
    assert wrapper.respond_to?(:upload_text)
  end

  test "ACCOUNT_ID is read from ENV and is not a hardcoded assignment" do
    assert_nil SOURCE.match(/^\s*ACCOUNT_ID\s*=\s*1\b/),
               "do not copy ACCOUNT_ID = 1 from legacy scripts"

    ingest = ShadowIngestV8.new(env: { "ACCOUNT_ID" => "42" })
    assert_equal 42, ingest.account_id_from_env!

    error = assert_raises(ShadowIngestV8::ConfigError) do
      ShadowIngestV8.new(env: {}).account_id_from_env!
    end
    assert_match(/ACCOUNT_ID/, error.message)
  end

  test "confirm gate rejects runs without SHADOW_INGEST_CONFIRM=1" do
    error = assert_raises(ShadowIngestV8::ConfirmError) do
      ShadowIngestV8.new(env: {
        "ACCOUNT_ID" => "1",
        "INGESTION_VISION_TIER_ENABLED" => "true"
      }).run!
    end
    assert_match(/SHADOW_INGEST_CONFIRM=1/, error.message)
  end

  test "vision flag is required; relations and zoom tiles are not forced on" do
    error = assert_raises(ShadowIngestV8::ConfigError) do
      ShadowIngestV8.new(env: {
        "SHADOW_INGEST_CONFIRM" => "1",
        "ACCOUNT_ID" => "1"
      }).run!
    end
    assert_match(/INGESTION_VISION_TIER_ENABLED=true/, error.message)

    assert_no_match(/INGESTION_VISION_TIER_RELATIONS_ENABLED\s*=\s*["']?true/, SOURCE)
    assert_no_match(/INGESTION_VISION_TIER_ZOOM_TILES\s*=\s*["']?true/, SOURCE)
  end

  test "header documents the I-31 close via page_topology_edges persistence" do
    assert_match(/I-31/, SOURCE)
    assert_match(/page_topology_edges/, SOURCE)
    assert_match(/web_manual_batches/, SOURCE)
    assert_match(/ManualBatchIngestionService/, SOURCE)
  end

  test "uses manual_batch_v1 not web_v1" do
    assert_equal "manual_batch_v1", ShadowIngestV8::INGESTION_PATH
    assert_includes SOURCE, 'manual_batch_v1'
    assert_nil SOURCE.match(/ingestion_path:\s*["']web_v1["']/)
  end

  test "parse_pages_env accepts a comma-separated allow-list" do
    ingest = ShadowIngestV8.new(env: { "SHADOW_INGEST_PAGES" => "3,17,63,78,93,97" })
    assert_equal [ 3, 17, 63, 78, 93, 97 ], ingest.parse_pages_env

    assert_nil ShadowIngestV8.new(env: {}).parse_pages_env
  end

  test "predict_chunk_plan explains a page subset delta against baseline 97 before any write" do
    pdf = build_fake_pdf_binary(5)
    stdout = StringIO.new
    ingest = ShadowIngestV8.new(stdout: stdout)
    edge_counter = ->(_binary, page_number) { page_number == 3 ? 2 : 0 }

    plan = ingest.predict_chunk_plan(pdf, page_allowlist: [ 1, 3, 5 ], edge_counter: edge_counter)
    ingest.send(:print_chunk_plan, plan)

    assert_equal 3, plan[:predicted_chunks]
    assert_equal(-94, plan[:delta_vs_baseline])
    assert_equal 0, plan[:overflow_siblings]
    assert_equal 2, plan[:edge_counts][3]
    assert(plan[:reasons].any? { |r| r.include?("SHADOW_INGEST_PAGES") })
    assert_includes stdout.string, "BEFORE any write"
    assert_includes stdout.string, "predicted chunks to create: 3"
    assert_includes stdout.string, "delta vs baseline 97"
  end

  test "the plan declares the one-chunk-per-page floor instead of implying an equality" do
    pdf = build_fake_pdf_binary(3)
    stdout = StringIO.new
    ingest = ShadowIngestV8.new(stdout: stdout)

    plan = ingest.predict_chunk_plan(pdf, page_allowlist: [ 1 ], edge_counter: ->(*) { 0 })
    ingest.send(:print_chunk_plan, plan)

    assert(plan[:reasons].any? { |r| r.include?("FLOOR") },
           "the prediction must declare that it is a floor, not an equality")
    assert(plan[:reasons].any? { |r| r.include?("PageRelevanceFilter") },
           "the page-subset branch must also declare the filter assumption")
    assert_includes stdout.string, "floor"
  end

  test "the plan names the pages that should carry a TOPOLOGY_EDGE and says the rest are empty" do
    pdf = build_fake_pdf_binary(3)
    stdout = StringIO.new
    ingest = ShadowIngestV8.new(stdout: stdout)
    edge_counter = ->(_binary, page_number) { page_number == 2 ? 2 : 0 }

    plan = ingest.predict_chunk_plan(pdf, page_allowlist: [ 1, 2, 3 ], edge_counter: edge_counter)
    ingest.send(:print_chunk_plan, plan)

    assert_includes stdout.string, "p2=2"
    assert_includes stdout.string, "no TOPOLOGY_EDGE"
  end

  test "an explicit KB target in the environment is honoured, not clobbered, and is flagged" do
    stdout = StringIO.new
    ingest = ShadowIngestV8.new(
      env: { "KNOWLEDGE_BASE_S3_BUCKET" => "some-staging-bucket" },
      stdout: stdout
    )

    with_env(
      "KNOWLEDGE_BASE_S3_BUCKET" => nil,
      "BEDROCK_KNOWLEDGE_BASE_ID" => nil,
      "BEDROCK_BULK_DATA_SOURCE_ID" => nil,
      "BEDROCK_DATA_SOURCE_ID" => nil
    ) do
      ingest.send(:point_at_production_kb!)

      assert_equal "some-staging-bucket", ENV["KNOWLEDGE_BASE_S3_BUCKET"]
      assert_equal "Y7RZWMFJSR", ENV["BEDROCK_KNOWLEDGE_BASE_ID"]
      assert_equal [ "KNOWLEDGE_BASE_S3_BUCKET" ], ingest.send(:off_target_keys)

      ingest.send(:print_targets)
      assert_includes stdout.string, "NOT the Fase 7 target"
    end
  end

  test "no global queue adapter flip; the ingestion job is run with perform_now" do
    assert_nil SOURCE.match(/queue_adapter\s*=/),
               "flipping ActiveJob::Base.queue_adapter also makes BedrockIngestionJob's " \
               "set(wait:) re-enqueue recurse immediately"
    assert_match(/BedrockIngestionJob\.perform_now/, SOURCE)
    assert_nil SOURCE.match(/BedrockIngestionJob\.perform_later/)
  end

  test "web_v1_metadata carries web_manual_batch_id so the shadow row reaches complete" do
    assert_match(/"web_manual_batch_id"\s*=>\s*batch\.id/, SOURCE)
  end

  test "preflight refuses a database that is not the one the pilot reads" do
    ingest = ShadowIngestV8.new(stdout: StringIO.new)
    account = accounts(:legacy)
    assert_nil KbDocument.find_by(document_uid: ShadowIngestV8::PRODUCTION_DOCUMENT_UID)

    error = assert_raises(ShadowIngestV8::ConfigError) do
      ingest.send(:check_database!, account.id)
    end
    assert_match(/NOT the database the pilot reads/, error.message)
  end

  test "preflight rejects an ACCOUNT_ID that does not exist" do
    ingest = ShadowIngestV8.new(stdout: StringIO.new)

    error = assert_raises(ShadowIngestV8::ConfigError) do
      ingest.send(:check_database!, 999_999_999)
    end
    assert_match(/does not exist/, error.message)
  end

  test "preflight runs before anything is created" do
    body = SOURCE[/def run!.*?\n  end\n/m]
    assert body, "run! not found"
    assert body.index("preflight!") < body.index("upload_original!"),
           "preflight must precede the first S3 write"
    assert body.index("preflight!") < body.index("create_kb_document!"),
           "preflight must precede the first row created"
  end

  test "predict_chunk_plan counts topology overflow siblings above the chunk cap" do
    pdf = build_fake_pdf_binary(1)
    ingest = ShadowIngestV8.new
    limit = ShadowIngestV8::TOPOLOGY_EDGE_CHUNK_LIMIT
    edge_counter = ->(*) { limit + 3 }

    plan = ingest.predict_chunk_plan(pdf, page_allowlist: [ 1 ], edge_counter: edge_counter)

    assert_equal 2, plan[:predicted_chunks]
    assert_equal 1, plan[:overflow_siblings]
    assert(plan[:reasons].any? { |r| r.include?("overflow") })
  end

  test "refuses to reuse the production document_uid" do
    ingest = ShadowIngestV8.new(
      document_uid_generator: -> { ShadowIngestV8::PRODUCTION_DOCUMENT_UID }
    )
    error = assert_raises(ShadowIngestV8::ConfigError) do
      ingest.send(:fresh_document_uid!)
    end
    assert_match(/refusing to reuse production document_uid/, error.message)
  end

  test "PageFilteredManualBatchIngestion keeps only allow-listed pages and still returns edges" do
    t1 = {
      from: "LIMITADOR", to: "CONECTOR AI", method: :leader_line,
      evidence: "polilínea une LIMITADOR con CONECTOR AI"
    }
    fake_client = FakeBatchClient.new
    pdf = build_fake_pdf_binary(3)
    result = nil

    stub_filter_and_topology(t1_edge: t1) do
      with_env(
        "INGESTION_LAYOUT_DIGEST_ENABLED" => "true",
        "INGESTION_VISION_TIER_ENABLED" => "true"
      ) do
        result = ShadowIngestV8::PageFilteredManualBatchIngestion.new(
          only_pages: [ 2 ],
          batch_client: fake_client
        ).submit!(
          binary: pdf,
          filename: "m.pdf",
          sha256: "a" * 64,
          s3_key: "uploads/m.pdf",
          locale: "es"
        )
      end
    end

    assert_equal [ 2 ], result[:kept_pages]
    assert_equal 1, fake_client.submitted_requests.size
    assert_equal [ t1 ], result[:page_topology_edges][2]
  end

  test "run! writes under a new uid via manual_batch_v1 and persists page_topology_edges" do
    account = accounts(:legacy)
    pdf = build_fake_pdf_binary(2)
    sha = Digest::SHA256.hexdigest(pdf)
    # Pin EXPECTED_SHA for this run by writing a temp file and stubbing the constant check
    # via a custom pdf_path + overriding load through a subclass-less stub on Digest match.
    path = Rails.root.join("tmp/shadow_ingest_v8_test.pdf")
    FileUtils.mkdir_p(path.dirname)
    File.binwrite(path, pdf)

    page_json = JSON.generate(
      "document_name" => "SEGURIDADES shadow",
      "aliases" => [ "SEGURIDADES" ],
      "chunks" => [ { "text" => "contenido página 2", "page" => 2, "field_records" => [] } ]
    )
    message = OpenStruct.new(
      model: "claude-sonnet-4-6",
      content: [ OpenStruct.new(type: "text", text: page_json) ],
      stop_reason: "end_turn"
    )
    # ManualBatchIngestionService#custom_id_for uses sha256[0..15]
    batch_result = OpenStruct.new(
      custom_id: "#{sha[0..15]}_p2",
      result: OpenStruct.new(type: "succeeded", message: message)
    )

    fake_s3 = FakeS3.new
    fake_batch = FakeBatchClient.new(status: "ended", results: [ batch_result ])
    stdout = StringIO.new
    new_uid = SecureRandom.uuid
    t1 = {
      from: "LIMITADOR", to: "CONECTOR AI", method: :leader_line,
      evidence: "polilínea une LIMITADOR con CONECTOR AI"
    }

    ingest = ShadowIngestV8.new(
      env: {
        "SHADOW_INGEST_CONFIRM" => "1",
        "ACCOUNT_ID" => account.id.to_s,
        "INGESTION_VISION_TIER_ENABLED" => "true",
        "SHADOW_INGEST_PAGES" => "2",
        "SHADOW_INGEST_PDF" => path.to_s
      },
      s3: fake_s3,
      batch_client: fake_batch,
      sleeper: ->(_) { },
      stdout: stdout,
      pdf_path: path,
      document_uid_generator: -> { new_uid }
    )
    ingest.define_singleton_method(:load_and_verify_pdf!) { pdf }
    ingest.define_singleton_method(:preflight!) { |**| nil }
    ingest.define_singleton_method(:sync_knowledge_base!) { |*| nil }
    ingest.define_singleton_method(:predict_chunk_plan) do |binary, page_allowlist: nil, **|
      {
        total_pages: 2,
        target_pages: page_allowlist || [ 1, 2 ],
        edge_counts: { 2 => 1 },
        chunks_per_page: { 2 => 1 },
        predicted_chunks: 1,
        overflow_siblings: 0,
        baseline_chunks: 97,
        delta_vs_baseline: -96,
        reasons: [ "SHADOW_INGEST_PAGES selects 1 of 2 pages" ]
      }
    end

    result = nil
    prior_kb_bucket = ENV["KNOWLEDGE_BASE_S3_BUCKET"]
    prior_kb_id = ENV["BEDROCK_KNOWLEDGE_BASE_ID"]
    prior_bulk_ds = ENV["BEDROCK_BULK_DATA_SOURCE_ID"]
    prior_ds = ENV["BEDROCK_DATA_SOURCE_ID"]
    prior_region = ENV["AWS_REGION"]
    prior_layout = ENV["INGESTION_LAYOUT_DIGEST_ENABLED"]

    stub_filter_and_topology(t1_edge: t1) do
      with_env("INGESTION_VISION_TIER_ENABLED" => "true") do
        result = ingest.run!
      end
    end

    assert_equal new_uid, result[:document_uid]
    assert_not_equal ShadowIngestV8::PRODUCTION_DOCUMENT_UID, result[:document_uid]
    assert_equal "bulk_chunks/#{account.id}/#{new_uid}", result[:chunks_s3_prefix]
    assert result[:page_topology_edges][2].present?

    body_key = fake_s3.uploads.keys.find { |key| key.end_with?("chunk_p2_1.txt") }
    assert body_key, "expected manual_batch_v1 page key, got #{fake_s3.uploads.keys.inspect}"
    assert_includes fake_s3.uploads.fetch(body_key), "RECORD_TYPE: TOPOLOGY_EDGE"
    assert_includes fake_s3.uploads.fetch(body_key), "DERIVATION: leader_line"

    sidecar = JSON.parse(fake_s3.uploads.fetch("#{body_key}.metadata.json"))
    assert_equal "manual_batch_v1", sidecar.dig("metadataAttributes", "ingestion_path")
    assert_equal 2, sidecar.dig("metadataAttributes", "page_number")

    batch = WebManualBatch.order(:id).last
    assert_equal new_uid, batch.kb_document.document_uid
    assert batch.page_topology_edges.present?

    assert_includes stdout.string, "BEFORE any write"
  ensure
    FileUtils.rm_f(path) if defined?(path) && path
    restore_env_key("KNOWLEDGE_BASE_S3_BUCKET", prior_kb_bucket) if defined?(prior_kb_bucket)
    restore_env_key("BEDROCK_KNOWLEDGE_BASE_ID", prior_kb_id) if defined?(prior_kb_id)
    restore_env_key("BEDROCK_BULK_DATA_SOURCE_ID", prior_bulk_ds) if defined?(prior_bulk_ds)
    restore_env_key("BEDROCK_DATA_SOURCE_ID", prior_ds) if defined?(prior_ds)
    restore_env_key("AWS_REGION", prior_region) if defined?(prior_region)
    restore_env_key("INGESTION_LAYOUT_DIGEST_ENABLED", prior_layout) if defined?(prior_layout)
  end

  private

  def build_fake_pdf_binary(page_count)
    doc = HexaPDF::Document.new
    page_count.times { doc.pages.add.canvas.move_to(0, 0).line_to(100, 100).stroke }
    io = StringIO.new("".b)
    doc.write(io, validate: false)
    io.string
  end

  def with_env(overrides)
    prior = {}
    overrides.each do |key, value|
      prior[key] = ENV.key?(key) ? ENV[key] : :__absent__
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
    yield
  ensure
    prior.each { |key, value| restore_env_key(key, value) }
  end

  def restore_env_key(key, value)
    if value.nil? || value == :__absent__
      ENV.delete(key)
    else
      ENV[key] = value
    end
  end

  def stub_filter_and_topology(t1_edge:)
    orig_cb = PageRelevanceFilter.method(:call_batch)
    orig_track = TrackBedrockQueryJob.method(:perform_later)
    orig_extract = PdfLayoutExtractor.method(:extract)
    orig_derive = TopologyEdgeDeriver.method(:derive)
    orig_vision = VisionTopologyExtractor.method(:derive)

    TrackBedrockQueryJob.define_singleton_method(:perform_later) { |**| nil }
    PageRelevanceFilter.define_singleton_method(:call_batch) do |pages:, **|
      pages.each_with_object({}) do |page, hash|
        hash[page.number] = {
          keep: true, reason: :test, source: :haiku_batch, force_opus: false,
          visual_complexity: :high, has_visual_relations: true, component_count: 1
        }
      end
    end
    PdfLayoutExtractor.define_singleton_method(:extract) do |_binary, page_number:|
      {
        page_number: page_number, media_box: [ 0, 0, 960, 540 ],
        words: [], lines: [], rects: [], images: [],
        text_layer_chars: 0, image_area_ratio: 0.0
      }
    end
    TopologyEdgeDeriver.define_singleton_method(:derive) { |_layout| t1_edge ? [ t1_edge ] : [] }
    VisionTopologyExtractor.define_singleton_method(:derive) do |_binary, **|
      VisionTopologyExtractor::Result.empty
    end

    yield
  ensure
    PageRelevanceFilter.define_singleton_method(:call_batch, orig_cb)
    TrackBedrockQueryJob.define_singleton_method(:perform_later, orig_track)
    PdfLayoutExtractor.define_singleton_method(:extract, orig_extract)
    TopologyEdgeDeriver.define_singleton_method(:derive, orig_derive)
    VisionTopologyExtractor.define_singleton_method(:derive, orig_vision)
  end
end
