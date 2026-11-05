# frozen_string_literal: true

# Compares the session 269 direct requests after the prompt correction.
# The default is preflight and does not call Bedrock. GUION2_PROMPT_COMPARE_EXECUTE=1
# sends the three captured generations with the new system text, and at most
# one 503 retry for the whole run.
# HAIKU55_PROMPT_COMPARE_EXECUTE=1 sends the same three requests to
# claude-haiku-5-5 on the Anthropic Messages API.

require Rails.root.join("test/support/companion_direct_capture_replay")
require Rails.root.join("test/support/companion_haiku55_compare")

if ENV["GUION2_PROMPT_COMPARE_REQUIRE"] == "1"
  # Loaded by a test. Nothing runs.
elsif ENV["HAIKU55_PROMPT_COMPARE_EXECUTE"] == "1"
  exit Rag::CompanionHaiku55Compare.execute(live: true)
elsif ENV["GUION2_PROMPT_COMPARE_EXECUTE"] == "1"
  exit Rag::CompanionDirectCaptureReplay.execute
else
  exit Rag::CompanionDirectCaptureReplay.preflight
end
