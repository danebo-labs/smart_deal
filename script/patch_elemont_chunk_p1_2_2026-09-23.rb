# frozen_string_literal: true

# Surgical patch of one indexed chunk: sheet 1 of Elemont MH
# (bulk_chunks/.../chunk_p1_2.txt). Sheet 2's designation table says T1 and T2
# are timer relays. This chunk called them transformers. Bornera rows are left
# untouched: the drawing was not confirmed.
#
# Cost: zero Claude calls. PutObject on the same key + one KB ingestion job.
# Rollback: re-upload tmp/elemont_patch_2026-09-23/chunk_p1_2_current.txt
# (the bucket has no versioning).
#
# Usage:
#   RAG_CHUNK_PATCH_CONFIRM=1 bin/rails runner script/patch_elemont_chunk_p1_2_2026-09-23.rb

abort("Set RAG_CHUNK_PATCH_CONFIRM=1 to run (mutates the production KB)") unless ENV["RAG_CHUNK_PATCH_CONFIRM"] == "1"

ENV["KNOWLEDGE_BASE_S3_BUCKET"]    = "multimodal-source-destination"
ENV["BEDROCK_KNOWLEDGE_BASE_ID"]   = "Y7RZWMFJSR"
ENV["BEDROCK_BULK_DATA_SOURCE_ID"] = "PJ0N58DMHG"
ENV["BEDROCK_DATA_SOURCE_ID"]      = "PJ0N58DMHG"
ENV["AWS_REGION"]                  = "us-east-1"

ActiveJob::Base.queue_adapter = :inline

KEY           = "bulk_chunks/1/121bfffe0827f6bc681ba9bdc91050390055/chunk_p1_2.txt"
OUT_DIR       = Rails.root.join("tmp/elemont_patch_2026-09-23")
EXPECTED_LIVE = "79300034c8252dc21f31e579211ce7fc2141f6d3a61d1f76ea92d0be68b2e8b5"

REPLACEMENTS = [
  [
    "[SEARCH_ALIASES: K1, K2, K3, K4, K5, K6, K7, Q1]",
    "[SEARCH_ALIASES: K1, K2, K3, K4, K5, K6, K7, Q1, Elemont, Modelo MH, T1 T2 relé temporizador]"
  ],
  [
    "- T1: Transformador 220VAC/18VCD — alimenta circuito de 18VCD. Rectificador adicional etiquetado \"Rectificador 24VAC/24VCD\" presente, generando +24VCD y Com 24VDC.",
    "- T1: Relé temporizador (Modo E, t < 3 minutos) — ver tabla de designaciones, hoja 2. Rectificador adicional etiquetado \"Rectificador 24VAC/24VCD\" presente, generando +24VCD y Com 24VDC."
  ],
  [
    "- T2: Transformador 220VAC/24VAC — alimenta circuito de 24VAC (L 24vac / N 24vac).",
    "- T2: Relé temporizador (Modo Wu, t < 1 segundo) — ver tabla de designaciones, hoja 2."
  ],
  [
    "ACTION: T1 — transformador 220VAC/18VCD; Rectificador 24VAC/24VCD presente en mismo circuito",
    "ACTION: T1 — relé temporizador (Modo E, t < 3 minutos); ver tabla de designaciones, hoja 2. Rectificador 24VAC/24VCD etiquetado en el dibujo"
  ],
  [
    "EVIDENCE: 220VAC/18VCD — Rectificador 24VAC/24VCD",
    "EVIDENCE: Relé temporizador Modo E, t < 3 minutos — hoja 2. Rectificador 24VAC/24VCD visible en el dibujo"
  ],
  [
    "ACTION: T2 — transformador 220VAC/24VAC, alimenta L 24vac / N 24vac",
    "ACTION: T2 — relé temporizador (Modo Wu, t < 1 segundo); ver tabla de designaciones, hoja 2"
  ],
  [
    "EVIDENCE: 220VAC/24VAC T2 A1A2 L 24vac",
    "EVIDENCE: Relé temporizador Modo Wu, t < 1 segundo — hoja 2"
  ]
].freeze

s3 = S3DocumentsService.new
live = s3.download(KEY)
abort("Could not download #{KEY}") if live.nil?

live_sha = Digest::SHA256.hexdigest(live)
abort("Live object SHA mismatch (#{live_sha}) — re-verify before patching") unless live_sha == EXPECTED_LIVE

live = live.dup.force_encoding(Encoding::UTF_8)
abort("Live object is not valid UTF-8") unless live.valid_encoding?

patched = live.dup
REPLACEMENTS.each do |from, to|
  count = patched.scan(from).size
  abort("Expected 1 occurrence of #{from[0, 60].inspect}, found #{count}") unless count == 1
  patched.sub!(from, to)
end
abort("Patched content is identical to live") if patched == live

FileUtils.mkdir_p(OUT_DIR)
File.binwrite(OUT_DIR.join("chunk_p1_2_current.txt"), live)
File.binwrite(OUT_DIR.join("chunk_p1_2_corrected.txt"), patched)

puts "=" * 80
puts "Elemont chunk_p1_2 T1/T2 patch"
puts "  key:     #{KEY}"
puts "  live:    #{live.bytesize} bytes (sha #{live_sha[0, 12]})"
puts "  patched: #{patched.bytesize} bytes (sha #{Digest::SHA256.hexdigest(patched)[0, 12]})"
puts "=" * 80

abort("Upload failed") unless s3.upload_text(KEY, patched)

roundtrip = s3.download(KEY)
abort("Round-trip verification failed") unless roundtrip == patched.dup.force_encoding(Encoding::BINARY)
puts "Uploaded and verified."

sync_result = BulkKbSyncService.new.sync!(
  uploaded_filenames: [ "Montacargas 2N Temporizado-1 (1).pdf" ],
  locale: "es"
)
abort("KB sync did not start") unless sync_result
puts "  job_id:         #{sync_result[:job_id]}"
puts "  kb_id:          #{sync_result[:kb_id]}"
puts "  data_source_id: #{sync_result[:data_source_id]}"

require "aws-sdk-bedrockagent"
agent = Aws::BedrockAgent::Client.new(region: ENV.fetch("AWS_REGION", "us-east-1"))
status = "STARTING"
print "Polling ingestion job: "
90.times do
  status = agent.get_ingestion_job(
    knowledge_base_id: sync_result[:kb_id],
    data_source_id:    sync_result[:data_source_id],
    ingestion_job_id:  sync_result[:job_id]
  ).ingestion_job.status
  print "#{status} "
  break unless %w[STARTING IN_PROGRESS].include?(status)

  sleep 10
end
puts

abort("KB ingestion job ended with status #{status}") unless status == "COMPLETE"
puts "\nRESULT: OK — chunk_p1_2 patched and KB sync COMPLETE"
