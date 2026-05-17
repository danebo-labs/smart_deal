# frozen_string_literal: true

# TEMPORARY dev/staging switch — remove this file + call sites when bulk path is validated.
#
# CUSTOM_CHUNKING_NO_FALLBACK=true in .env:
#   - CustomChunkingPipeline does NOT call fallback_to_legacy (no OWRPGSX6XK / FM ingest cost).
#   - UploadAndSyncAttachmentsJob re-raises so the job fails once (no silent success).
#
# Requires CUSTOM_CHUNKING_WEB_ENABLED=true for the new path to run at all.
module CustomChunkingNoFallbackTest
  ENV_KEY = "CUSTOM_CHUNKING_NO_FALLBACK"

  def self.active?
    ENV.fetch(ENV_KEY, "false").casecmp?("true")
  end

  def self.log_failure(error, uploaded_filenames:, kb_document_ids:)
    Rails.logger.error(
      "CustomChunkingNoFallbackTest: ABORT (no legacy fallback) " \
      "files=#{Array(uploaded_filenames).inspect} " \
      "kb_doc_ids=#{Array(kb_document_ids).inspect} " \
      "— #{error.class}: #{error.message}"
    )
    Rails.logger.error(error.backtrace.first(15).join("\n"))
  end
end
