# frozen_string_literal: true

# Rewrites legacy bulk_chunks/**/*.metadata.json sidecars to inject
# account_id + document_id (document_uid) into metadataAttributes.
#
# Resolution order:
#   1. KbDocument.find_by(s3_key: original_source_uri)
#   2. BulkUploadAsset.find_by(s3_key: original_source_uri)&.kb_document
#
# Unmapped sidecars (no resolvable KbDocument) are logged and the task
# exits 1 — operator must resolve them before Gate A.
#
# Safe to re-run: already-correct sidecars are skipped (already_correct counter).
desc "Rewrite legacy sidecar metadata to add account_id + document_id. Exits 1 if any sidecars are unmapped."
task rewrite_legacy_sidecars: :environment do
  resolve_doc = lambda do |original_uri|
    return nil if original_uri.blank?

    doc = KbDocument.find_by(s3_key: original_uri)
    doc ||= BulkUploadAsset.find_by(s3_key: original_uri)&.kb_document
    return doc if doc

    key = KbDocument.object_key_for_match(original_uri)
    return nil if key.blank?

    doc = KbDocument.find_by(s3_key: key)
    doc ||= KbDocument.where("s3_key LIKE ?", "s3://%/#{key}")
                      .detect { |d| KbDocument.object_key_for_match(d.s3_key) == key }
    doc ||= BulkUploadAsset.find_by(s3_key: key)&.kb_document
    doc
  end

  svc    = S3DocumentsService.new
  bucket = svc.bucket_name
  s3     = svc.instance_variable_get(:@s3)

  found           = 0
  updated         = 0
  already_correct = 0
  unmapped        = 0
  unmapped_keys   = []

  s3.list_objects_v2(bucket: bucket, prefix: "bulk_chunks/").each do |page|
    Array(page.contents).each do |obj|
      next unless obj.key.end_with?(".metadata.json")

      raw = svc.download(obj.key)
      next if raw.nil?

      data = begin
        JSON.parse(raw)
      rescue JSON::ParserError
        Rails.logger.warn("rewrite_legacy_sidecars: invalid JSON at #{obj.key}")
        next
      end

      attrs        = data["metadataAttributes"] || {}
      original_uri = attrs["original_source_uri"].to_s.strip

      doc = resolve_doc.call(original_uri)

      if doc.nil? || doc.account_id.nil? || doc.document_uid.nil?
        puts "UNMAPPED: #{obj.key} (original_source_uri=#{original_uri.presence || 'blank'})"
        unmapped      += 1
        unmapped_keys << obj.key
        next
      end

      found += 1

      if attrs["account_id"].to_s == doc.account_id.to_s &&
         attrs["document_id"].to_s == doc.document_uid.to_s
        already_correct += 1
        next
      end

      attrs["account_id"]  = doc.account_id.to_s
      attrs["document_id"] = doc.document_uid.to_s
      data["metadataAttributes"] = attrs

      svc.upload_text(obj.key, JSON.generate(data))
      updated += 1
    end
  end

  puts "\nResults: found=#{found} updated=#{updated} already_correct=#{already_correct} unmapped=#{unmapped}"

  if unmapped > 0
    puts "\nUnmapped sidecars (#{unmapped}):"
    unmapped_keys.each { |k| puts "  #{k}" }
    puts "\nResolve all unmapped sidecars before Gate A."
    exit 1
  end
end
