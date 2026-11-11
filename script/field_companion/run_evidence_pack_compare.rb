# frozen_string_literal: true

# A/B evidence packaging. EVIDENCE_PACK_EXECUTE=1 sends the isolated calls
# and, only if the frozen gate passes, the chained scripts. The default
# writes the ceiling and does not call a model.

require Rails.root.join("test/support/companion_evidence_pack_compare")

if ENV["EVIDENCE_PACK_REQUIRE"] == "1"
  # Loaded by a test. Nothing runs.
elsif ENV["EVIDENCE_PACK_EXECUTE"] == "1"
  exit Rag::CompanionEvidencePackCompare::Runner.execute
else
  exit Rag::CompanionEvidencePackCompare::Runner.prepare
end
