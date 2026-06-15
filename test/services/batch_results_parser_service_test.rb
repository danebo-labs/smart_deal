# frozen_string_literal: true

require "test_helper"
require "ostruct"

class BatchResultsParserServiceTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  # Suppress Turbo broadcast — the _asset partial isn't created until step 15.
  setup do
    @_orig_broadcast = BulkUploadAsset.instance_method(:broadcast_replace!)
    BulkUploadAsset.define_method(:broadcast_replace!) { }
  end

  teardown do
    BulkUploadAsset.define_method(:broadcast_replace!, @_orig_broadcast)
  end

  # ---------------------------------------------------------------------------
  # Fake S3 service — records upload_text calls
  # ---------------------------------------------------------------------------

  class FakeS3Service
    attr_reader :uploads

    def initialize
      @uploads = {}
    end

    def upload_text(key, content)
      @uploads[key] = content
      key
    end
  end

  # ---------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------

  DOC_NAME = "Hydraulic Pump Manual"
  ALIASES  = [ "HPM-400", "pump manual" ]

  def chunk0_text
    "# S0 — DOCUMENT IDENTIFICATION\nHydraulic pressure: 3000 PSI max."
  end

  def chunk1_text
    "# S6 — ELECTRICAL\nOil viscosity: ISO 46."
  end

  def golden_parsed
    {
      "document_name" => DOC_NAME,
      "aliases"        => ALIASES,
      "chunks"         => [
        { "text" => chunk0_text, "page" => 1, "field_records" => [] },
        { "text" => chunk1_text, "page" => 2, "field_records" => [] }
      ]
    }
  end

  def field_record(overrides = {})
    {
      "k" => "FUNCTIONAL_TEST",
      "h" => "Section 2.4",
      "a" => "Press the horn button.",
      "r" => "The horn sounds.",
      "ev" => "Pulse el botón de la bocina.",
      "x" => "role=operator; scope=lift platform; precondition=platform controller selected"
    }.merge(overrides)
  end

  def make_result(json_text: golden_parsed.to_json, result_type: "succeeded")
    message = OpenStruct.new(
      content: [
        OpenStruct.new(type: "text", text: json_text)
      ]
    )
    inner = OpenStruct.new(type: result_type, message: message)
    OpenStruct.new(result: inner)
  end

  def make_asset(status: "in_batch")
    upload = BulkUpload.create!(
      sha256:            SecureRandom.hex(16),
      original_filename: "test.zip",
      status:            "processing",
      asset_count:       0
    )
    BulkUploadAsset.create!(
      bulk_upload: upload,
      custom_id:   SecureRandom.hex(16),
      sha256:      SecureRandom.hex(32),
      filename:    "pump_photo.jpg",
      s3_key:      "bulk_uploads/2026-05-07/pump_photo.jpg",
      status:      status
    )
  end

  def build_parser
    @fake_s3 = FakeS3Service.new
    BatchResultsParserService.new(s3_service: @fake_s3)
  end

  # ---------------------------------------------------------------------------
  # Happy path
  # ---------------------------------------------------------------------------

  test "transitions asset to parsed and persists canonical_name and aliases" do
    asset  = make_asset
    parser = build_parser

    parser.call(asset: asset, result: make_result)

    asset.reload
    assert_equal "parsed",  asset.status
    assert_equal DOC_NAME,  asset.canonical_name
    assert_equal ALIASES,   asset.aliases
    assert_equal 2,         asset.chunks_count
    assert_not_nil          asset.chunks_s3_prefix
  end

  test "writes a .txt and a .metadata.json sidecar per chunk" do
    asset  = make_asset
    parser = build_parser

    parser.call(asset: asset, result: make_result)

    prefix = asset.reload.chunks_s3_prefix
    assert_equal 4, @fake_s3.uploads.size
    %w[chunk_0.txt chunk_0.txt.metadata.json chunk_1.txt chunk_1.txt.metadata.json].each do |suffix|
      assert @fake_s3.uploads.key?("#{prefix}/#{suffix}"), "missing #{suffix}"
    end
  end

  test "chunk text is prefixed with the legacy identity header (DOCUMENT/SOURCE_URI/SEARCH_ALIASES)" do
    ENV["KNOWLEDGE_BASE_S3_BUCKET"] = "multimodal-source-destination"
    asset  = make_asset
    parser = build_parser

    parser.call(asset: asset, result: make_result)

    prefix  = asset.reload.chunks_s3_prefix
    chunk_0 = @fake_s3.uploads["#{prefix}/chunk_0.txt"]
    chunk_1 = @fake_s3.uploads["#{prefix}/chunk_1.txt"]

    assert chunk_0.start_with?("[DOCUMENT: pump_photo.jpg]\n")
    assert_includes chunk_0,
      "[SOURCE_URI: s3://multimodal-source-destination/bulk_uploads/2026-05-07/pump_photo.jpg]\n"
    assert_includes chunk_0, "[SEARCH_ALIASES: HPM-400, pump manual]\n\n"
    assert_includes chunk_0, chunk0_text

    assert chunk_1.start_with?("[DOCUMENT: pump_photo.jpg]\n")
    assert_includes chunk_1, chunk1_text
  ensure
    ENV.delete("KNOWLEDGE_BASE_S3_BUCKET")
  end

  test "uses chunk aliases for each SEARCH_ALIASES header" do
    payload = golden_parsed.deep_dup
    payload["chunks"][0]["aliases"] = [ "P41", "platform pressure" ]
    payload["chunks"][1]["aliases"] = [ "BRK", "brake circuit" ]
    asset = make_asset
    parser = build_parser

    parser.call(asset: asset, result: make_result(json_text: payload.to_json))

    prefix = asset.reload.chunks_s3_prefix
    assert_includes @fake_s3.uploads["#{prefix}/chunk_0.txt"],
                    "[SEARCH_ALIASES: P41, platform pressure]"
    assert_includes @fake_s3.uploads["#{prefix}/chunk_1.txt"],
                    "[SEARCH_ALIASES: BRK, brake circuit]"
  end

  test "renders field records into a canonical retrieval block" do
    payload = golden_parsed.deep_dup
    payload["chunks"][1]["field_records"] = [
      field_record(
        "h" => "2.4.2 Prueba por controlador de plataforma",
      )
    ]
    asset = make_asset
    parser = build_parser

    parser.call(asset: asset, result: make_result(json_text: payload.to_json))

    chunk = @fake_s3.uploads["#{asset.reload.chunks_s3_prefix}/chunk_1.txt"]
    assert_includes chunk, "# FIELD-SAFETY EVIDENCE RECORDS"
    assert_match(/RECORD_ID: FR-[0-9A-F]{16}/, chunk)
    assert_includes chunk, "RECORD_TYPE: FUNCTIONAL_TEST"
    assert_includes chunk, "ACTION: Press the horn button."
    assert_includes chunk, "EXPECTED_RESULT: The horn sounds."
    assert_includes chunk, "DETAILS: role=operator; scope=lift platform"
    assert_includes chunk, "EVIDENCE: Pulse el botón de la bocina."
    assert_includes chunk, "END_FIELD_RECORD"
  end

  test "generates deterministic field record identifiers" do
    payload = golden_parsed.deep_dup
    payload["chunks"][0]["field_records"] = [
      field_record(
        "h" => "Section 2",
        "k" => "INSPECTION_CHECK",
        "a" => "Inspect the cable.",
        "r" => "DATA_NOT_AVAILABLE",
        "ev" => "Inspect the cable."
      )
    ]
    parser = build_parser
    first_asset = make_asset
    second_asset = make_asset

    parser.call(asset: first_asset, result: make_result(json_text: payload.to_json))
    first_chunk = @fake_s3.uploads["#{first_asset.reload.chunks_s3_prefix}/chunk_0.txt"]
    first_id = first_chunk[/RECORD_ID: (FR-[0-9A-F]{16})/, 1]

    parser.call(asset: second_asset, result: make_result(json_text: payload.to_json))
    second_chunk = @fake_s3.uploads["#{second_asset.reload.chunks_s3_prefix}/chunk_0.txt"]
    second_id = second_chunk[/RECORD_ID: (FR-[0-9A-F]{16})/, 1]

    assert_not_nil first_id
    assert_equal first_id, second_id
  end

  test "rejects stop-work records without a complete evidence pair" do
    payload = golden_parsed.deep_dup
    payload["chunks"][0]["field_records"] = [
      field_record(
        "h" => "Inspection",
        "k" => "STOP_WORK_CONDITION",
        "a" => "Check for oil leaks.",
        "r" => "No leak observed.",
        "sw" => [ "Oil leak", "DATA_NOT_AVAILABLE" ],
        "ev" => "Check for oil leaks."
      )
    ]
    asset = make_asset
    parser = build_parser

    error = assert_raises(BatchResultsParserService::ParseError) do
      parser.call(asset: asset, result: make_result(json_text: payload.to_json))
    end

    assert_includes error.message, "Incomplete stop-work evidence pair"
    assert_equal "failed", asset.reload.status
  end

  test "renders a complete stop-work evidence pair" do
    payload = golden_parsed.deep_dup
    payload["chunks"][0]["field_records"] = [
      field_record(
        "h" => "Inspection",
        "k" => "STOP_WORK_CONDITION",
        "a" => "Inspect the hydraulic line.",
        "r" => "No oil leak is visible.",
        "sw" => [ "Oil leak is visible.", "Mark the platform out of service." ],
        "ra" => "Qualified service technician",
        "ev" => "If leakage is visible, mark out of service."
      )
    ]
    asset = make_asset
    parser = build_parser

    parser.call(asset: asset, result: make_result(json_text: payload.to_json))

    chunk = @fake_s3.uploads["#{asset.reload.chunks_s3_prefix}/chunk_0.txt"]
    assert_includes chunk, "STOP_WORK_TRIGGER: Oil leak is visible."
    assert_includes chunk, "STOP_WORK_REQUIRED_ACTION: Mark the platform out of service."
    assert_includes chunk, "REPAIR_AUTHORITY: Qualified service technician"
  end

  test "caps document aliases at 15 and chunk aliases at 8" do
    aliases = 20.times.map { |index| "alias #{index}" }
    payload = golden_parsed.merge(
      "aliases" => aliases,
      "chunks" => [
        { "text" => chunk0_text, "page" => 1, "aliases" => aliases, "field_records" => [] }
      ]
    )
    asset = make_asset
    parser = build_parser

    parser.call(asset: asset, result: make_result(json_text: payload.to_json))

    prefix = asset.reload.chunks_s3_prefix
    chunk = @fake_s3.uploads["#{prefix}/chunk_0.txt"]
    sidecar = JSON.parse(@fake_s3.uploads["#{prefix}/chunk_0.txt.metadata.json"])

    alias_line = chunk.lines.find { |line| line.start_with?("[SEARCH_ALIASES:") }
    assert_equal 8, alias_line.delete_prefix("[SEARCH_ALIASES: ").delete_suffix("]\n").split(", ").size
    assert_equal 15, asset.reload.aliases.size
    assert_equal 15, sidecar.dig("metadataAttributes", "aliases").size
  end

  test "metadata.json sidecar carries original_source_uri and canonical_name for retrieval filtering" do
    ENV["KNOWLEDGE_BASE_S3_BUCKET"] = "multimodal-source-destination"
    asset  = make_asset
    parser = build_parser

    parser.call(asset: asset, result: make_result)

    prefix = asset.reload.chunks_s3_prefix
    meta   = JSON.parse(@fake_s3.uploads["#{prefix}/chunk_0.txt.metadata.json"])

    attrs = meta["metadataAttributes"]
    assert_equal "s3://multimodal-source-destination/bulk_uploads/2026-05-07/pump_photo.jpg",
                 attrs["original_source_uri"]
    assert_equal "pump_photo.jpg",        attrs["original_filename"]
    assert_equal DOC_NAME,                attrs["canonical_name"]
    assert_equal asset.sha256,            attrs["doc_sha256"]
    assert_equal "batch_v1",              attrs["ingestion_path"]
    assert_equal ALIASES,                 attrs["aliases"]
    assert_equal BatchChunkingPrompt::INGESTION_CONTRACT_VERSION, attrs["ingestion_contract_version"]
    assert_equal BatchChunkingPrompt.prompt_fingerprint_sha256,   attrs["prompt_fingerprint_sha256"]
  ensure
    ENV.delete("KNOWLEDGE_BASE_S3_BUCKET")
  end

  test "field_photo_v1 sidecar declares the photo contract version and fingerprint" do
    asset  = make_asset
    parser = build_parser

    envelope = {
      "document_name" => DOC_NAME,
      "aliases"       => ALIASES,
      "chunks"        => [ { "text" => "photo identity chunk", "page" => nil } ]
    }
    parser.call(asset: asset, raw_json: envelope.to_json, ingestion_path: "field_photo_v1")

    prefix = asset.reload.chunks_s3_prefix
    attrs  = JSON.parse(@fake_s3.uploads["#{prefix}/chunk_0.txt.metadata.json"]).fetch("metadataAttributes")

    assert_equal "field_photo_v1", attrs["ingestion_path"]
    assert_equal FieldPhotoPrompt::INGESTION_CONTRACT_VERSION, attrs["ingestion_contract_version"]
    assert_equal FieldPhotoPrompt.prompt_fingerprint_sha256,   attrs["prompt_fingerprint_sha256"]
    assert_not_equal BatchChunkingPrompt.prompt_fingerprint_sha256, attrs["prompt_fingerprint_sha256"]
  end

  test "chunks_s3_prefix uses bulk_chunks/<date>/<sha256> pattern" do
    asset  = make_asset
    parser = build_parser

    parser.call(asset: asset, result: make_result)

    prefix = asset.reload.chunks_s3_prefix
    assert_match(%r{\Abulk_chunks/\d{4}-\d{2}-\d{2}/[a-f0-9]+\z}, prefix)
    assert_includes prefix, asset.sha256
  end

  # ---------------------------------------------------------------------------
  # Validation failures
  # ---------------------------------------------------------------------------

  test "raises ParseError and marks asset failed when result type is not succeeded" do
    asset  = make_asset
    parser = build_parser

    assert_raises(BatchResultsParserService::ParseError) do
      parser.call(asset: asset, result: make_result(result_type: "errored"))
    end

    assert_equal "failed", asset.reload.status
  end

  test "raises ParseError when JSON is invalid" do
    asset  = make_asset
    parser = build_parser

    assert_raises(BatchResultsParserService::ParseError) do
      parser.call(asset: asset, result: make_result(json_text: "not json {{"))
    end

    assert_equal "failed", asset.reload.status
  end

  test "raises ParseError when chunk[0] missing Document header" do
    skip "Marker validation removed — identity is 100% Rails-injected (identity_header + sidecar)"
  end

  test "raises ParseError when chunk[0] missing DOCUMENT_ALIASES header" do
    skip "Marker validation removed — identity is 100% Rails-injected (identity_header + sidecar)"
  end

  test "parses chunks without **Document:**/**DOCUMENT_ALIASES:** body markers" do
    plain_chunks = {
      "document_name" => DOC_NAME,
      "aliases"        => ALIASES,
      "chunks"         => [
        { "text" => "# S0 — DOCUMENT IDENTIFICATION\nContent here.", "page" => 1, "field_records" => [] },
        { "text" => "# S4 — SAFETY SYSTEM\nEmergency stop details.", "page" => 1, "field_records" => [] }
      ]
    }
    asset  = make_asset
    parser = build_parser

    parser.call(asset: asset, result: make_result(json_text: plain_chunks.to_json))

    asset.reload
    assert_equal "parsed",  asset.status
    assert_equal DOC_NAME,  asset.canonical_name
    assert_equal ALIASES,   asset.aliases
    assert_equal 2,         asset.chunks_count
  end

  test "raises ParseError when required keys are missing" do
    asset  = make_asset
    parser = build_parser

    assert_raises(BatchResultsParserService::ParseError) do
      parser.call(asset: asset, result: make_result(json_text: '{"foo":"bar"}'))
    end
  end

  test "raises ParseError when chunks array is empty" do
    empty = golden_parsed.merge("chunks" => [])
    asset  = make_asset
    parser = build_parser

    assert_raises(BatchResultsParserService::ParseError) do
      parser.call(asset: asset, result: make_result(json_text: empty.to_json))
    end
  end

  test "raises ParseError when a manual chunk omits field_records" do
    payload = golden_parsed.deep_dup
    payload["chunks"][0].delete("field_records")
    asset = make_asset
    parser = build_parser

    error = assert_raises(BatchResultsParserService::ParseError) do
      parser.call(asset: asset, result: make_result(json_text: payload.to_json))
    end

    assert_includes error.message, "Missing field_records array in chunk 0"
  end

  # ---------------------------------------------------------------------------
  # Fenced JSON (Fix 1) — bulk path via result, web path via raw_json
  # ---------------------------------------------------------------------------

  test "parses fenced JSON in bulk path (```json fence)" do
    fenced = "```json\n#{golden_parsed.to_json}\n```"
    asset  = make_asset
    parser = build_parser

    parser.call(asset: asset, result: make_result(json_text: fenced))

    asset.reload
    assert_equal "parsed", asset.status
    assert_equal DOC_NAME, asset.canonical_name
    assert_equal 2,        asset.chunks_count
  end

  test "parses fenced JSON in bulk path (plain ``` fence)" do
    fenced = "```\n#{golden_parsed.to_json}\n```"
    asset  = make_asset
    parser = build_parser

    parser.call(asset: asset, result: make_result(json_text: fenced))

    asset.reload
    assert_equal "parsed", asset.status
  end

  test "parses fenced JSON in web path via raw_json" do
    fenced = "```json\n#{golden_parsed.to_json}\n```"
    sha256 = SecureRandom.hex(32)
    chunk_asset = ChunkAsset.new(
      filename:     "manual.pdf",
      sha256:       sha256,
      s3_key:       "uploads/manual.pdf",
      content_type: "application/pdf"
    )
    parser = build_parser

    parser.call(asset: chunk_asset, raw_json: fenced, ingestion_path: "web_v1")

    assert_equal DOC_NAME, chunk_asset.canonical_name
    assert_equal ALIASES,  chunk_asset.aliases
    assert_equal 2,        chunk_asset.chunks_count
    assert_not_nil         chunk_asset.chunks_s3_prefix
  end

  # ---------------------------------------------------------------------------
  # Web path: summary field
  # ---------------------------------------------------------------------------

  test "web path: persists summary on ChunkAsset when present" do
    payload = golden_parsed.merge("summary" => "Foto de un controlador Schindler 5500. Muestra los conectores J1 y J2.")
    chunk_asset = ChunkAsset.new(
      filename: "controller.jpg", sha256: SecureRandom.hex(32),
      s3_key:   "uploads/controller.jpg", content_type: "image/jpeg"
    )
    parser = build_parser

    parser.call(asset: chunk_asset, raw_json: payload.to_json, ingestion_path: "web_v1")

    assert_match(/Schindler 5500/, chunk_asset.summary)
  end

  test "web path: summary nil when omitted by Claude (PDF/text path)" do
    chunk_asset = ChunkAsset.new(
      filename: "manual.pdf", sha256: SecureRandom.hex(32),
      s3_key:   "uploads/manual.pdf", content_type: "application/pdf"
    )
    parser = build_parser

    parser.call(asset: chunk_asset, raw_json: golden_parsed.to_json, ingestion_path: "web_v1")

    assert_nil chunk_asset.summary
  end

  test "bulk path: summary not required and not crashed by extra field" do
    asset   = make_asset
    parser  = build_parser
    payload = golden_parsed.merge("summary" => "ignored on bulk path")

    parser.call(asset: asset, result: make_result(json_text: payload.to_json))

    assert_equal "parsed", asset.reload.status
  end

  # ---------------------------------------------------------------------------
  # Web path: companion_offer field
  # ---------------------------------------------------------------------------

  test "web path: persists companion_offer on ChunkAsset when present" do
    payload = golden_parsed.merge(
      "summary"         => "Parece el cuadro de un Schindler.",
      "companion_offer" => "Pregúntame lo que necesites, aunque sea con pocas palabras."
    )
    chunk_asset = ChunkAsset.new(
      filename: "controller.jpg", sha256: SecureRandom.hex(32),
      s3_key:   "uploads/controller.jpg", content_type: "image/jpeg"
    )
    parser = build_parser

    parser.call(asset: chunk_asset, raw_json: payload.to_json, ingestion_path: "web_v1")

    assert_match(/Pregúntame/, chunk_asset.companion_offer)
  end

  test "web path: companion_offer nil when omitted by Claude" do
    chunk_asset = ChunkAsset.new(
      filename: "manual.pdf", sha256: SecureRandom.hex(32),
      s3_key:   "uploads/manual.pdf", content_type: "application/pdf"
    )
    parser = build_parser

    parser.call(asset: chunk_asset, raw_json: golden_parsed.to_json, ingestion_path: "web_v1")

    assert_nil chunk_asset.companion_offer
  end

  test "bulk path: companion_offer not required and does not crash" do
    asset   = make_asset
    parser  = build_parser
    payload = golden_parsed.merge("companion_offer" => "ignored on bulk path")

    parser.call(asset: asset, result: make_result(json_text: payload.to_json))

    assert_equal "parsed", asset.reload.status
  end

  # ---------------------------------------------------------------------------
  # B.2 — safety-record context: STOP_WORK_CONDITION RECORD_ID includes sw
  # ---------------------------------------------------------------------------

  test "stop-work records that share action/evidence but differ in stop_trigger get distinct RECORD_IDs" do
    ground = field_record(
      "k"  => "STOP_WORK_CONDITION",
      "h"  => "Controles de tierra",
      "a"  => "Presione el botón de parada de emergencia a su posición apagado",
      "r"  => "Se detienen todas las funciones",
      "ev" => "para detener todas las funciones",
      "sw" => [ "emergencia desde controles de tierra", "presionar botón rojo a posición apagado" ]
    )
    platform = field_record(
      "k"  => "STOP_WORK_CONDITION",
      "h"  => "Controles de tierra",
      "a"  => "Presione el botón de parada de emergencia a su posición apagado",
      "r"  => "Se detienen todas las funciones",
      "ev" => "para detener todas las funciones",
      "sw" => [ "emergencia desde control de plataforma", "presionar botón rojo a posición apagado" ]
    )

    parser = build_parser
    id_ground = parser.send(:render_field_record, ground, page: 3)[/RECORD_ID: (FR-[0-9A-F]{16})/, 1]
    id_platform = parser.send(:render_field_record, platform, page: 3)[/RECORD_ID: (FR-[0-9A-F]{16})/, 1]

    assert_not_nil id_ground
    assert_not_nil id_platform
    assert_not_equal id_ground, id_platform,
      "ground-control and platform-control stop-work records must not share a RECORD_ID"
  end

  test "stop-work records that are physically identical get the same RECORD_ID and deduplicate" do
    record = field_record(
      "k"  => "STOP_WORK_CONDITION",
      "h"  => "Prueba de velocidad",
      "a"  => "Verificar velocidad con plataforma elevada",
      "r"  => "No supera 20 cm/s",
      "ev" => "marque la máquina inmediatamente y deje de funcionar",
      "sw" => [ "velocidad supera 20 cm/s", "marcar y detener la máquina" ]
    )

    parser = build_parser
    id_first  = parser.send(:render_field_record, record, page: 7)[/RECORD_ID: (FR-[0-9A-F]{16})/, 1]
    id_second = parser.send(:render_field_record, record, page: 7)[/RECORD_ID: (FR-[0-9A-F]{16})/, 1]

    assert_not_nil id_first
    assert_equal id_first, id_second,
      "physically identical stop-work records must produce the same RECORD_ID for deduplication"
  end

  test "records without stop-work context retain the historical RECORD_ID" do
    parser = build_parser
    values = {
      page: 3,
      source: "Section 2.4",
      record_type: "FUNCTIONAL_TEST",
      action: "Press the horn button.",
      expected_result: "The horn sounds.",
      evidence: "Pulse el botón de la bocina."
    }
    legacy_fingerprint = values.values.join("\u001F")
    expected_id = "FR-#{Digest::SHA256.hexdigest(legacy_fingerprint).first(16).upcase}"

    assert_equal expected_id, parser.send(:field_record_id, **values)
  end

  test "ground and platform stop-work records survive as distinct entries through the full render-parse cycle" do
    shared_chunk_text = "# S4 — SAFETY SYSTEM\nPrueba de parada de emergencia."
    ground_rec = field_record(
      "k"  => "STOP_WORK_CONDITION",
      "h"  => "Controles de tierra — Parada de emergencia",
      "a"  => "Presione el botón rojo de parada de emergencia a posición apagado",
      "r"  => "Se detienen todas las funciones",
      "ev" => "para detener todas las funciones",
      "sw" => [ "emergencia desde controles de tierra", "presionar botón a posición apagado" ]
    )
    platform_rec = field_record(
      "k"  => "STOP_WORK_CONDITION",
      "h"  => "Control de plataforma — Parada de emergencia",
      "a"  => "Presione el botón rojo de parada de emergencia a posición apagado",
      "r"  => "Se detienen todas las funciones",
      "ev" => "para detener todas las funciones",
      "sw" => [ "emergencia desde control de plataforma", "presionar botón a posición apagado" ]
    )

    payload = golden_parsed.deep_dup
    payload["chunks"][0] = {
      "text"         => shared_chunk_text,
      "page"         => 3,
      "aliases"      => [],
      "field_records" => [ ground_rec, platform_rec ]
    }

    asset  = make_asset
    parser = build_parser
    parser.call(asset: asset, result: make_result(json_text: payload.to_json))

    chunk_text = @fake_s3.uploads["#{asset.reload.chunks_s3_prefix}/chunk_0.txt"]
    parsed = Rag::FieldRecordParser.parse_text(chunk_text)
    stop_work_records = parsed[:records].select(&:stop_work?)

    assert_equal 2, stop_work_records.size,
      "both ground-control and platform-control stop-work records must survive the render-parse cycle"
    assert_equal 2, stop_work_records.map(&:record_id).uniq.size,
      "ground and platform stop-work records must have distinct RECORD_IDs after rendering"
  end
end
