# frozen_string_literal: true

# D18 — quita el duplicado de la nota rev. 0 en cuenta 3.
# No genera. Retrieve de verificación no escribe bedrock_queries.
# Borrar S3 no saca el índice: hay que sync del data source y poll COMPLETE.
#
# Conserva 7cd6d699… (kb 216, corrida C). Borra ce1e04be… (mismo sha de fuente).
# Prod 6ee694b: delete_prefix no invalida el expansor; esta corrida llama
# invalidate! a mano. El hook en S3DocumentsService cubre deploys posteriores.

require "json"

$stdout.sync = true
$stderr.sync = true

KEEP_UID = "7cd6d699-e519-492f-aa35-4fb2dcfb53c9".freeze
DROP_UID = "ce1e04be-fb0e-4801-bebb-bee7bc9111b3".freeze
KEEP_KB_ID = 216
ACCOUNT_ID = Integer(ENV.fetch("REGRESSION_ACCOUNT_ID", "3"))
QUESTION = "Cómo se ajustan los resortes de la fijación de cables".freeze
POLL_EVERY = 10
POLL_TIMEOUT = 15 * 60

def abort_with(msg)
  puts "ABORT: #{msg}"
  exit 1
end

def list_txt(s3, prefix)
  list_prefix = prefix.end_with?("/") ? prefix : "#{prefix}/"
  s3.list_keys(prefix: list_prefix).select { |k| k.end_with?(".txt") && k.exclude?(".metadata.json") }
end

def uris_of(chunk)
  [
    chunk[:location_uri],
    chunk[:original_source_uri],
    chunk[:bedrock_source_uri]
  ].map { |u| u.to_s }
end

account = Account.find_by(id: ACCOUNT_ID)
abort_with("cuenta no encontrada") unless account

keep = KbDocument.find_by(account_id: account.id, document_uid: KEEP_UID)
abort_with("KEEP #{KEEP_UID} no está en kb_documents") unless keep
abort_with("KEEP kb_document_id=#{keep.id} != #{KEEP_KB_ID}") unless keep.id == KEEP_KB_ID

drop = KbDocument.find_by(account_id: account.id, document_uid: DROP_UID)
abort_with("DROP #{DROP_UID} no está en kb_documents") unless drop

extras = KbDocument.where(account_id: account.id).where.not(id: [ keep.id, drop.id ]).select do |row|
  row.document_uid.to_s.in?([ KEEP_UID, DROP_UID ]) ||
    row.s3_key.to_s.include?(DROP_UID) ||
    row.display_name.to_s.match?(/nota t[eé]cnica interna amarre/i)
end
abort_with("filas extra no contempladas: #{extras.map { |r| "#{r.id}:#{r.document_uid}" }.join(",")}") if extras.any?

keep_prefix = "bulk_chunks/#{account.id}/#{KEEP_UID}"
drop_prefix = "bulk_chunks/#{account.id}/#{DROP_UID}"
drop_upload = "uploads/#{account.id}/#{DROP_UID}"

s3 = S3DocumentsService.new
keep_txt = list_txt(s3, keep_prefix)
drop_txt = list_txt(s3, drop_prefix)
abort_with("KEEP sin chunks bajo #{keep_prefix}") if keep_txt.empty?
abort_with("DROP sin chunks bajo #{drop_prefix}") if drop_txt.empty?

puts "cuenta=#{account.id} keep_id=#{keep.id} drop_id=#{drop.id}"
puts "keep_chunks=#{keep_txt.size} drop_chunks=#{drop_txt.size}"
puts "keep_name=#{keep.display_name.inspect} drop_name=#{drop.display_name.inspect}"

query_max_before = ActiveRecord::Base.uncached { BedrockQuery.maximum(:id) }.to_i

deleted_chunks = s3.delete_prefix(drop_prefix.end_with?("/") ? drop_prefix : "#{drop_prefix}/")
# Prod 6ee694b no dispara el hook de delete_prefix. H1/H2: mutación bajo
# bulk_chunks/ que no pasa por el upload_text desplegado.
Rag::SectionNeighborExpander.invalidate!(drop_prefix)
deleted_upload = s3.delete_prefix(drop_upload.end_with?("/") ? drop_upload : "#{drop_upload}/")
Rag::DocumentOverviewCache.invalidate(account_id: account.id, kb_document_id: drop.id)

left = list_txt(s3, drop_prefix)
abort_with("DROP sigue en S3: #{left.join(",")}") if left.any?
abort_with("KEEP desapareció de S3") if list_txt(s3, keep_prefix).empty?

drop.destroy!
abort_with("DROP fila sigue en kb_documents") if KbDocument.exists?(drop.id)
abort_with("KEEP fila perdida") unless KbDocument.exists?(keep.id)

puts "=== S3 drop_chunks=#{deleted_chunks} drop_upload=#{deleted_upload} expander_invalidated=#{drop_prefix}"
puts "=== kb_documents drop_id=#{drop.id} destroyed keep_id=#{keep.id} intact"

sync = BulkKbSyncService.new.sync!(uploaded_filenames: [ "d18-drop-#{DROP_UID}" ], locale: "es")
abort_with("BulkKbSyncService no devolvió job_id") if sync.blank? || sync[:job_id].blank?
puts "=== SYNC job=#{sync[:job_id]} kb=#{sync[:kb_id]} ds=#{sync[:data_source_id]}"

status_svc = IngestionStatusService.new(kb_id: sync[:kb_id], data_source_id: sync[:data_source_id])
started = Time.current
status = status_svc.job_status(sync[:job_id]).to_s
puts "=== POLL job=#{sync[:job_id]} status=#{status}"
until %w[COMPLETE FAILED STOPPED].include?(status)
  abort_with("poll timeout #{POLL_TIMEOUT}s status=#{status}") if Time.current - started > POLL_TIMEOUT
  sleep POLL_EVERY
  status = status_svc.job_status(sync[:job_id]).to_s
  puts "=== POLL job=#{sync[:job_id]} status=#{status} t=#{(Time.current - started).round}s"
end
abort_with("ingesta no COMPLETE: #{status}") unless status == "COMPLETE"
puts "=== INGESTA status=#{status} wait=#{(Time.current - started).round}s"

retrieval = BedrockRagService.new(account: account).retrieve_chunks(
  QUESTION,
  number_of_results: 8,
  account_id: account.id,
  correlation_id: "fase-c:d18:retrieve"
)
chunks = Array(retrieval[:chunks])
hits_drop = chunks.select { |c| uris_of(c).any? { |u| u.include?(DROP_UID) } }
hits_keep = chunks.select { |c| uris_of(c).any? { |u| u.include?(KEEP_UID) } }

chunks.each do |chunk|
  uri = (chunk[:location_uri] || chunk[:bedrock_source_uri] || chunk[:original_source_uri]).to_s
  puts "  rank=#{chunk[:rank]} uri=#{uri.split('/').last(3).join('/')}"
end

abort_with("Retrieve sigue trayendo DROP #{DROP_UID} (#{hits_drop.size} hits)") if hits_drop.any?

query_max_after = ActiveRecord::Base.uncached { BedrockQuery.maximum(:id) }.to_i
abort_with("se crearon filas bedrock_queries (#{query_max_before}→#{query_max_after})") if query_max_after > query_max_before

puts "=== RETRIEVE n=#{chunks.size} keep_hits=#{hits_keep.size} drop_hits=0"
puts "=== D18 DEDUP OK keep=#{KEEP_UID} job=#{sync[:job_id]}"
