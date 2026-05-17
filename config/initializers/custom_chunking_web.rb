# frozen_string_literal: true

# Feature flag: custom chunking pipeline for web uploads.
# When enabled, POST /rag/ask file attachments bypass OWRPGSX6XK (FM-parsing + Lambda)
# and use the Anthropic Messages API directly with model routing (Opus 4.7 vs Sonnet 4.6),
# writing pre-processed chunks to the bulk data source (chunking=NONE).
#
# Default: off. Enable in staging/production via Kamal env:
#   CUSTOM_CHUNKING_WEB_ENABLED=true kamal env push && kamal deploy
Rails.application.config.x.custom_chunking_web_enabled =
  ENV.fetch("CUSTOM_CHUNKING_WEB_ENABLED", "false").casecmp?("true")
