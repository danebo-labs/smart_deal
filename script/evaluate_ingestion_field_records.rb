# frozen_string_literal: true

# Fase 2 — Evaluador de ingesta FIELD_RECORD (sin llamadas pagadas).
#
# Audita los chunks producidos por la ingesta ANTES de probar RAG:
#   - inventario de chunks con SHA-256;
#   - todos los FIELD_RECORD con sus campos;
#   - records invalidos (gramatica estricta de Rag::FieldRecordParser);
#   - IDs en conflicto (mismo RECORD_ID, contenido distinto);
#   - duplicados fisicos exactos;
#   - records sin evidencia utilizable (EVIDENCE=DATA_NOT_AVAILABLE);
#   - STOP_WORK_CONDITION sin par completo trigger/accion;
#   - paginas degradadas (placeholder "EXTRACCION PARCIAL") — fallo duro;
#   - sidecars: contrato y fingerprint uniformes y esperados;
#   - conteos por tipo.
#
# Uso (S3, prefijo de chunks de un documento):
#   RAG_INGESTION_CHUNKS_PREFIX=bulk_chunks/2026-06-10/<sha>/ \
#   RAG_INGESTION_REPORT=tmp/ingestion_field_records_report.json \
#   bin/rails runner script/evaluate_ingestion_field_records.rb
#
# Uso (directorio local con chunk_*.txt y *.metadata.json):
#   RAG_INGESTION_CHUNKS_DIR=tmp/v2_chunks bin/rails runner script/evaluate_ingestion_field_records.rb
#
# Exit code 0 = PASS, 1 = FAIL. El gate funcional 24/24 del manual es una
# revision documental separada (manifest Fase 4); este script valida la
# integridad estructural del output de ingesta.

require "digest"
require "json"

class IngestionFieldRecordsEvaluator
  DEGRADATION_MARKER = "EXTRACCION PARCIAL"

  def initialize(env: ENV)
    @env = env
  end

  def run
    chunks = load_chunks
    abort("No chunks found — set RAG_INGESTION_CHUNKS_PREFIX or RAG_INGESTION_CHUNKS_DIR") if chunks.empty?

    ledger = Rag::FieldRecordParser.parse_chunks(
      chunks.map { |c| { content: c[:content], uri: c[:key], rank: nil, chunk_sha256: c[:sha256] } }
    )

    degraded = chunks.select { |c| c[:content].include?(DEGRADATION_MARKER) }
    no_evidence = ledger.records.select { |r| r.evidence == "DATA_NOT_AVAILABLE" }
    incomplete_stop_work = ledger.records.select do |r|
      r.stop_work? && (r.stop_trigger.to_s.empty? || r.stop_action.to_s.empty?)
    end
    physical_duplicates = ledger.records.select { |r| r.provenances.size > 1 }

    sidecar_report = audit_sidecars(chunks)

    failures = []
    failures << "#{ledger.invalid_records.size} invalid record(s)" if ledger.invalid_records.any?
    failures << "conflicting RECORD_IDs: #{ledger.conflicting_ids.join(', ')}" if ledger.conflicting_ids.any?
    failures << "#{degraded.size} degraded page placeholder(s): #{degraded.pluck(:key).join(', ')}" if degraded.any?
    failures << "#{incomplete_stop_work.size} STOP_WORK_CONDITION without complete pair" if incomplete_stop_work.any?
    failures.concat(sidecar_report[:failures])

    report = {
      generated_by: "script/evaluate_ingestion_field_records.rb",
      source: @env["RAG_INGESTION_CHUNKS_PREFIX"] || @env["RAG_INGESTION_CHUNKS_DIR"],
      chunk_count: chunks.size,
      chunks: chunks.map { |c| { key: c[:key], sha256: c[:sha256], bytes: c[:content].bytesize } },
      record_count: ledger.records.size,
      records_by_type: ledger.records.group_by(&:type).transform_values(&:size).sort.to_h,
      records: ledger.records.map { |r| record_payload(r) },
      invalid_records: ledger.invalid_records.map { |r| { reason: r.reason, chunk: r.uri, lines: r.lines } },
      conflicting_record_ids: ledger.conflicting_ids,
      physical_duplicates: physical_duplicates.map { |r| { record_id: r.record_id, chunks: r.provenances.map { |p| p[:uri] } } },
      records_without_evidence: no_evidence.map(&:record_id),
      degraded_pages: degraded.pluck(:key),
      sidecars: sidecar_report.except(:failures),
      passed: failures.empty?,
      failures: failures
    }

    output_path = @env["RAG_INGESTION_REPORT"].presence || "tmp/ingestion_field_records_report.json"
    File.write(output_path, JSON.pretty_generate(report))

    puts "Chunks: #{report[:chunk_count]}  Records: #{report[:record_count]}"
    report[:records_by_type].each { |type, count| puts format("  %-28s %d", type, count) }
    puts "Invalid: #{ledger.invalid_records.size}  Conflicts: #{ledger.conflicting_ids.size}  " \
         "Degraded pages: #{degraded.size}  No-evidence: #{no_evidence.size}"
    puts "Report: #{output_path}"
    if report[:passed]
      puts "RESULT: PASS"
    else
      puts "RESULT: FAIL"
      failures.each { |f| puts "  - #{f}" }
      exit 1
    end
  end

  private

  def record_payload(record)
    {
      record_id: record.record_id,
      type: record.type,
      source: record.source,
      action: record.action,
      expected_result: record.expected_result,
      details: record.details,
      stop_trigger: record.stop_trigger,
      stop_action: record.stop_action,
      repair_authority: record.repair_authority,
      uncertainty: record.uncertainty,
      evidence: record.evidence,
      chunks: record.provenances.pluck(:uri)
    }.compact
  end

  # @return [Array<Hash>] { key:, content:, sha256:, sidecar: Hash|nil }
  def load_chunks
    if (dir = @env["RAG_INGESTION_CHUNKS_DIR"].presence)
      Dir[File.join(dir, "chunk_*.txt")].sort_by { |p| p[/chunk_(\d+)/, 1].to_i }.map do |path|
        content = File.read(path)
        sidecar_path = "#{path}.metadata.json"
        {
          key: File.basename(path),
          content: content,
          sha256: Digest::SHA256.hexdigest(content),
          sidecar: File.exist?(sidecar_path) ? JSON.parse(File.read(sidecar_path)) : nil
        }
      end
    elsif (prefix = @env["RAG_INGESTION_CHUNKS_PREFIX"].presence)
      bucket = KbDocument::KB_BUCKET
      s3 = Aws::S3::Client.new(region: @env.fetch("AWS_REGION", "us-east-1"))
      keys = []
      s3.list_objects_v2(bucket: bucket, prefix: prefix).each do |page|
        keys.concat(page.contents.map(&:key))
      end
      chunk_keys = keys.grep(/chunk_\d+\.txt\z/).sort_by { |k| k[/chunk_(\d+)/, 1].to_i }
      chunk_keys.map do |key|
        content = s3.get_object(bucket: bucket, key: key).body.read
        sidecar = begin
          JSON.parse(s3.get_object(bucket: bucket, key: "#{key}.metadata.json").body.read)
        rescue Aws::S3::Errors::NoSuchKey
          nil
        end
        {
          key: key,
          content: content,
          sha256: Digest::SHA256.hexdigest(content),
          sidecar: sidecar
        }
      end
    else
      []
    end
  end

  def audit_sidecars(chunks)
    failures = []
    missing = chunks.select { |c| c[:sidecar].nil? }.pluck(:key)
    failures << "#{missing.size} chunk(s) without sidecar" if missing.any?

    attributes = chunks.filter_map { |c| c[:sidecar]&.dig("metadataAttributes") }
    versions = attributes.pluck("ingestion_contract_version").uniq
    fingerprints = attributes.pluck("prompt_fingerprint_sha256").uniq
    doc_shas = attributes.pluck("doc_sha256").uniq

    failures << "missing/heterogeneous ingestion_contract_version: #{versions.inspect}" unless versions.size == 1 && versions.first.present?
    failures << "missing/heterogeneous prompt_fingerprint_sha256" unless fingerprints.size == 1 && fingerprints.first.present?
    failures << "heterogeneous doc_sha256 in sidecars: #{doc_shas.inspect}" unless doc_shas.size <= 1

    if (expected = @env["RAG_EXPECTED_CONTRACT_VERSION"].presence) && versions != [ expected ]
      failures << "contract version #{versions.inspect} != expected #{expected}"
    end

    {
      missing: missing,
      ingestion_contract_version: versions,
      prompt_fingerprint_sha256: fingerprints,
      doc_sha256: doc_shas,
      failures: failures
    }
  end
end

IngestionFieldRecordsEvaluator.new.run
