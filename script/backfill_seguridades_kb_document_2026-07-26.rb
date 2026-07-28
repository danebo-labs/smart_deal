# frozen_string_literal: true

# Backfills the missing `KbDocument` catalog row for SEGURIDADES 1.1-1.
#
# Why the gap exists: `script/reingest_seguridades_2026-07-25.rb` wrote chunks to
# S3 and synced the Knowledge Base, but never upserted the catalog row. The
# document is therefore retrievable by Bedrock yet invisible to the technician UI
# (`RecentKbDocumentsQuery`), cannot be pinned, and the benchmark runner had to
# fall back to its `external_document` path (`document.id` recorded as `null`).
#
# Same identity contract as `CustomChunkingPipeline#ensure_kb_document_for`:
# uniqueness is (account_id, document_uid) and (account_id, s3_key). `account_id`
# is NOT NULL in the database and the model only autofills it under Rails.env.test,
# so it is passed explicitly here.
#
# Idempotent: re-running verifies the row instead of creating a second one, and
# aborts if an existing row disagrees on s3_key rather than silently repointing it.
#
# Database-only: no S3 and no Bedrock calls. `size_bytes` is left null, exactly
# as `CustomChunkingPipeline` leaves it on the normal ingestion path.
#
# `account_id` is not a free choice. Every indexed chunk sidecar carries
# `account_id: "1"`, and `BedrockRagService#account_filter` hard-filters retrieval
# on `@account.id`, so only a session whose account **is** id 1 can retrieve this
# document at all. A catalog row under any other account would list the PDF in the
# UI and then return nothing when pinned. If the pilot account is not id 1, the
# fix is on the ingestion metadata side, not here.
#
# Run once per environment whose database serves the pilot.
#
# Usage:
#   bin/rails runner script/backfill_seguridades_kb_document_2026-07-26.rb

ENV["KNOWLEDGE_BASE_S3_BUCKET"] ||= "multimodal-source-destination"

ACCOUNT_ID   = 1
DOCUMENT_UID = "b61f5d54-ff42-414a-97b7-01682d16f4b5"
S3_KEY       = "uploads/1/b61f5d54-ff42-414a-97b7-01682d16f4b5/original.pdf"
DISPLAY_NAME = "SEGURIDADES 1.1-1"
ALIASES      = [ "SEGURIDADES" ].freeze

unless Account.exists?(id: ACCOUNT_ID)
  abort(<<~MSG)
    Account #{ACCOUNT_ID} does not exist in #{Rails.env} (present: #{Account.pluck(:id).inspect}).
    The indexed chunks are scoped to account_id=#{ACCOUNT_ID} and retrieval filters on it,
    so this backfill only belongs in a database where account #{ACCOUNT_ID} is the pilot account.
    Do not repoint the row at another account: the document would appear in the UI and
    retrieve nothing.
  MSG
end

existing = KbDocument.find_by(account_id: ACCOUNT_ID, document_uid: DOCUMENT_UID) ||
  KbDocument.find_by(account_id: ACCOUNT_ID, s3_key: S3_KEY)

if existing
  if existing.s3_key != S3_KEY
    abort("KbDocument #{existing.id} has s3_key=#{existing.s3_key.inspect}, expected #{S3_KEY.inspect} — resolve manually")
  end
  if existing.document_uid != DOCUMENT_UID
    abort("KbDocument #{existing.id} has document_uid=#{existing.document_uid}, expected #{DOCUMENT_UID} — resolve manually")
  end

  # KbDocumentEnrichmentService previously overwrote display_name unconditionally
  # from query-time Haiku output (fixed separately); repair here restores the
  # canonical name and drops any contaminating aliases the overwrite left behind.
  if existing.display_name != DISPLAY_NAME
    cleaned = (Array(existing.aliases) + ALIASES + [ existing.display_name ])
      .map(&:to_s).map(&:strip).compact_blank
      .reject { |a| a.casecmp?(DISPLAY_NAME) || a.match?(/\A(ALJO|Control Level)/i) }
      .uniq
    existing.update!(display_name: DISPLAY_NAME, aliases: cleaned)
    puts "Repaired display_name → #{DISPLAY_NAME}"
  end

  puts "Already present: KbDocument #{existing.id} (#{existing.display_name.inspect}, aliases=#{Array(existing.aliases).inspect})"
  record = existing
else
  record = KbDocument.create!(
    account_id:   ACCOUNT_ID,
    document_uid: DOCUMENT_UID,
    s3_key:       S3_KEY,
    display_name: DISPLAY_NAME,
    aliases:      ALIASES.dup
  )
  puts "Created KbDocument #{record.id}"
end

account = Account.find(ACCOUNT_ID)
docs, = RecentKbDocumentsQuery.page(0, per_page: 25, account: account)
listed = docs.any? { |doc| doc.id == record.id }

puts "=" * 80
puts "env:            #{Rails.env}"
puts "kb_document_id: #{record.id}"
puts "s3_key:         #{record.s3_key}"
puts "display_name:   #{record.display_name.inspect}"
puts "aliases:        #{Array(record.aliases).inspect}"
puts "source_uri:     #{record.display_s3_uri(KbDocument::KB_BUCKET)}"
puts "in home list:   #{listed}"
puts "=" * 80

abort("Row created but not returned by RecentKbDocumentsQuery — check account scoping") unless listed
puts "RESULT: OK"
