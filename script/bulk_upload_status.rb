# frozen_string_literal: true

# Snapshot — or follow — a bulk ingestion run: asset states, the error behind each
# failure and the field_records the parser discarded. Read-only, no API calls.
#
# The deployed image does not carry script/, so pass it on stdin:
#
#   CID=$(ssh -i ~/.ssh/smart-deal-deploy.pem ubuntu@54.163.248.39 \
#     "docker ps --filter label=service=smart-deal --filter label=role=web \
#      --filter status=running --format '{{.Names}}' | head -1")
#   ssh -i ~/.ssh/smart-deal-deploy.pem ubuntu@54.163.248.39 \
#     "docker exec -i -e BULK_UPLOAD_ID=7 -e FOLLOW=true $CID bin/rails runner -" \
#     < script/bulk_upload_status.rb
#
# Use `--roles=web` (or docker exec on the web container) for anything with
# effects: kamal app exec without it runs on web *and* worker.
#
# Env:
#   BULK_UPLOAD_ID  required
#   FOLLOW          poll until the upload reaches complete/failed
#   POLL_SECONDS    seconds between rounds while following (default 45)
#   POLL_ROUNDS     cap on rounds, so a forgotten follower cannot run forever
#                   (default 240 ≈ 3h at the default sleep)

upload = BulkUpload.find(Integer(ENV.fetch("BULK_UPLOAD_ID")))
report = BulkUploadStatusReport.new(upload)
follow = ActiveModel::Type::Boolean.new.cast(ENV["FOLLOW"]).present?
sleep_s = Integer(ENV.fetch("POLL_SECONDS", "45"))
rounds  = follow ? Integer(ENV.fetch("POLL_ROUNDS", "240")) : 1

def render(snapshot)
  lines = [ snapshot.to_s ]
  snapshot.failures.each { |failure| lines << "  FAILED #{failure.filename}: #{failure.error_message}" }
  snapshot.discards.each { |discard| lines << "  dropped #{discard.count} in #{discard.filename}: #{discard.reasons}" }
  lines.join("\n")
end

# Printing only on change is what keeps hours of following readable; the
# timestamp is added at print time so it never counts as a change.
last = nil

rounds.times do
  snapshot = report.call
  body     = render(snapshot)

  if body != last
    puts "[#{Time.current.strftime('%H:%M:%S %Z')}] #{body}"
    $stdout.flush
    last = body
  end

  if snapshot.terminal?
    puts "TERMINAL status=#{snapshot.status}"
    $stdout.flush
    break
  end

  sleep sleep_s if follow
end
