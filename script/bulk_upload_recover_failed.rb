# frozen_string_literal: true

# Recovers assets that failed at parse time, without paying for their pages again:
# returns them to `in_batch` and re-runs IngestBatchResultsJob, which re-reads the
# batch results Anthropic still holds (~29 days, not billed on re-read).
#
# Use it when an asset failed *after* its results came back — a parse or merge
# defect. An asset that never produced results (`all_pages_filtered`, "No batch
# result returned") will simply fail again with the same message.
#
# The deployed image does not carry script/, so pass it on stdin, and always
# against the web container: kamal app exec without --roles=web runs on worker too.
#
#   CID=$(ssh -i ~/.ssh/smart-deal-deploy.pem ubuntu@54.163.248.39 \
#     "docker ps --filter label=service=smart-deal --filter label=role=web \
#      --filter status=running --format '{{.Names}}' | head -1")
#   ssh -i ~/.ssh/smart-deal-deploy.pem ubuntu@54.163.248.39 \
#     "docker exec -i -e BULK_UPLOAD_ID=6 -e ASSET_FILENAMES='CMC3 SCM Synergy.pdf' \
#      $CID bin/rails runner -" < script/bulk_upload_recover_failed.rb
#
# Env:
#   BULK_UPLOAD_ID   required
#   ASSET_FILENAMES  optional, comma-separated; omit to recover every failure

upload    = BulkUpload.find(Integer(ENV.fetch("BULK_UPLOAD_ID")))
filenames = ENV["ASSET_FILENAMES"].to_s.split(",").map(&:strip).reject(&:empty?)

report = BulkUploadStatusReport.new(upload).call
puts report
report.failures.each { |failure| puts "  FAILED #{failure.filename}: #{failure.error_message}" }

begin
  puts BulkUploadAssetRecovery.new(upload, filenames: filenames).call!
rescue BulkUploadAssetRecovery::Error => e
  abort("recovery refused: #{e.message}")
end
