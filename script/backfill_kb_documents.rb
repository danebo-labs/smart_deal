# frozen_string_literal: true

#
# Backfill KbDocument records for files already in S3 that were uploaded
# before the fix to KbDocument.ensure_for_s3_key! (size_bytes= error).
#
# Usage:
#   bin/rails runner script/backfill_kb_documents.rb
#
s3   = S3DocumentsService.new
docs = s3.list_documents

tech_by_filename = TechnicianDocument.all.index_by(&:wa_filename)

puts "Bucket : #{s3.bucket_name}"
puts "Objects: #{docs.size}"
puts "-" * 70

created  = 0
enriched = 0
skipped  = 0
errors   = 0

docs.each do |doc|
  existing = KbDocument.find_by(s3_key: doc[:full_path])

  if existing
    puts "SKIP    #{doc[:full_path]}"
    skipped += 1
    next
  end

  begin
    kb = KbDocument.ensure_for_s3_key!(doc[:full_path], size_bytes: doc[:size_bytes])
    created += 1
    puts "CREATE  #{doc[:full_path]} → display_name: #{kb.display_name.inspect}"
  rescue StandardError => e
    puts "ERROR   #{doc[:full_path]} — #{e.message}"
    errors += 1
    next
  end

  tech = tech_by_filename[doc[:name]]
  next unless tech

  kb.display_name = tech.canonical_name.presence || kb.display_name
  kb.aliases      = (Array(kb.aliases) + Array(tech.aliases)).uniq.compact_blank
  if kb.changed?
    kb.save!
    enriched += 1
    puts "ENRICH  #{doc[:name]}"
    puts "        canonical : #{tech.canonical_name.inspect}"
    puts "        aliases   : #{tech.aliases.inspect}"
  end
end

puts "-" * 70
puts "created: #{created}  enriched: #{enriched}  skipped: #{skipped}  errors: #{errors}"
