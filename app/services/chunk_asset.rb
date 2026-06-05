# frozen_string_literal: true

# Lightweight value object representing a file asset for BatchResultsParserService
# when the caller is NOT a BulkUploadAsset ActiveRecord model (e.g. the web
# custom chunking path).
#
# Provides the same duck-type interface BatchResultsParserService reads from assets:
#   filename, sha256, s3_key, content_type
# Plus settable fields that the parser fills in after writing chunks:
#   canonical_name, aliases, chunks_count, chunks_s3_prefix
#
# Does NOT implement update! or broadcast_replace! — the parser skips those for
# ChunkAsset instances, avoiding any AR dependency in the web chunking path.
ChunkAsset = Struct.new(
  :filename, :sha256, :s3_key, :content_type,
  :canonical_name, :aliases, :summary, :companion_offer, :chunks_count, :chunks_s3_prefix,
  :degraded_pages,
  keyword_init: true
)
